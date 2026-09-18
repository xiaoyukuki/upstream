# 第一章原型 · 技术架构设计

> 依据：《游戏设计指导文档：移动时停解谜（第一章原型）》
> 目标工程：`D:/Godot/Ups/upstream`（Godot 4.6 stable，GL Compatibility）
> 文档状态：**已确认**。D1~D12 全部按建议执行（2026-09-16），设计文档 4.2 的代码仅作参考。

### D12 · `Time.get_process_delta_time()` 这个 API 不存在

**原文**：4.2 两处写 `Time.get_process_delta_time()`。

**问题**：Godot 4 的 `Time` 单例只提供系统时钟查询（`get_ticks_msec()`、`get_ticks_usec()`、`get_unix_time_from_system()`、`get_datetime_string_from_system()` 等），**没有任何 delta 相关方法**。原文代码直接照抄会报 `Invalid call. Nonexistent function 'get_process_delta_time' in base 'Time'`。

**正确 API**：delta 挂在 `Node` 上，不在 `Time` 上。

| 写法 | 可用性 |
|---|---|
| `_process(delta)` / `_physics_process(delta)` 的参数 | ✅ 首选，回调内直接用 |
| `Node.get_process_delta_time()` | ✅ 在任意 Node 脚本内取当前渲染帧 delta |
| `Node.get_physics_process_delta_time()` | ✅ 在任意 Node 脚本内取当前物理帧 delta（恒为 `1/physics_ticks_per_second`） |
| `Time.get_process_delta_time()` | ❌ 不存在 |

`TimeReceiver` 需要跨节点提供 delta，因此走 `TimeManager`（它本身是 Node）上的 `get_physics_process_delta_time()`。

---

## 1. 必须先拍板的技术决策

原文档的设计意图是清晰且自洽的，但 4.2 节的两段参考实现和若干技术前提存在会导致 **M1 验收失败** 的问题。下面每条给出「原文写法 → 问题 → 建议」。

### D1 · 时停判定挂在 `_process` 还是 `_physics_process`（影响最大）

**原文**：「内部使用 `Time.get_process_delta_time()` 而非 `get_physics_process_delta_time()`，以避免物理帧率波动影响时停判定」。

**问题**：这个理由基于一个误解。Godot 的物理步长是**固定的** `1/physics_ticks_per_second`（默认 1/60），`Time.get_physics_process_delta_time()` 永远是这个常量，不会波动。真正波动的是**每帧执行几次物理步**（0、1、2 次），而这恰恰是问题所在：

- `Time.get_process_delta_time()` 在 `_physics_process` 里被调用时，返回的是**最近一次渲染帧**的 delta。
- 一个渲染帧内跑 2 次物理步 → 两次都拿到同一个 process delta → **世界时间流速翻倍**。
- 渲染帧率高于物理帧率（144Hz 显示器）→ 部分 process delta 被跳过 → **世界时间流速变慢**。
- 结果：M1 验收标准「30fps 与 60fps 下判定一致」无法满足，移动方块速度会随显示器刷新率漂移。

**建议**：拆成两条通道，各司其职。

| 通道 | 驱动 | 用途 | 帧率无关性 |
|---|---|---|---|
| `get_physics_delta()` | `_physics_process` 内读取 | 所有参与物理/位移的受时停对象（MovingBlock、Door 碰撞体、Pendulum 角度累加） | 固定步长，天然无关 |
| `get_process_delta()` | `_process` 内读取 | 纯视觉过渡（灰滤镜 alpha 插值、DebugOverlay 刷新） | 用真实 process delta 累加，无关 |

**状态机本身**（FROZEN/FLOWING 切换 + 0.08s 缓冲）建议放在 `_physics_process`，理由见 D2、D3。

> 备注：Godot 4 主循环单帧顺序为「输入事件派发 → 物理步 ×N → `_process` ×1 → 渲染」。这一顺序我会在 M1 用一个探针脚本实测确认，不凭记忆下结论。

---

### D2 · 解冻缓冲的触发时机（原文参考实现有 bug）

**原文参考实现**：

```gdscript
func set_frozen() -> void:
    frozen_to_flowing_buffer = BUFFER_DURATION   # ← 计时器在进入 FROZEN 时启动
    _set_state(TimeState.FROZEN)

func _process(delta) -> void:
    if current_state == TimeState.FROZEN:
        frozen_to_flowing_buffer -= raw_delta
        if frozen_to_flowing_buffer <= 0.0:
            _set_state(TimeState.FLOWING)        # ← 0.08s 后无条件解冻
```

**问题**：缓冲计时器在**进入 FROZEN 的瞬间**启动并自行倒数。玩家持续按住方向键时，只要 `MovementInputHandler` 发的是边沿信号（`movement_started` 仅在开始移动时发一次），世界就会在 **0.08 秒后自动解冻**——玩家还在移动，门却关上了，方块又动了。核心谜题直接失效。

若改成「每帧都调 `set_frozen()`」来续命，则 `set_frozen()` 里的 `_set_state()` 虽然做了同态判断不会重复发信号，但语义已经变成心跳而非边沿，`movement_started`/`movement_stopped` 这对信号失去意义。

**原文正文其实是对的**：「缓冲仅作用于 FROZEN→FLOWING 方向（停止移动时延迟恢复时间）」——错的是代码。

**建议**：改成显式的双边沿驱动。

```
movement_started (raw axis 越过死区)  → 立即 FROZEN，取消任何进行中的解冻倒数
movement_stopped (raw axis 回到死区内) → 启动 0.08s 倒数；倒数归零才 FLOWING
倒数期间若再次 movement_started        → 取消倒数，保持 FROZEN（这就是「防抖」的本意）
```

同时暴露 `is_releasing() -> bool` 供 DebugOverlay 显示黄色「缓冲中」，**不要**往 `TimeState` 枚举里加第三态——`TimeFreezeFilter` 的 `match` 只认两态，加第三态会污染所有消费方。

---

### D3 · 冻结触发读原始输入还是平滑输入

**原文**：`MovementInputHandler` 用「`Input.get_axis()` + `lerp()` 做输入平滑」，并「输出 `movement_started` / `movement_stopped` 信号」。

**问题**：与同一段的「FLOWING→FROZEN 应立即触发（开始移动瞬间冻结），避免输入延迟感」**自相矛盾**。`lerp()` 平滑意味着轴值需要若干帧才能爬过死区，冻结必然延迟触发。144Hz 下延迟小、30fps 下延迟大，又是一处帧率依赖。

**建议**：**两条独立通路，不要混用同一个值。**

- **冻结判定** → 读**原始** `Input.get_axis("move_left", "move_right")`，直接和死区比较，同帧生效，零延迟。
- **角色加速度平滑** → 在 `Player` 内部对 `velocity.x` 做 `move_toward()` / `lerp()`，这属于手感调校，与时停无关。

`MovementInputHandler` 只负责第一条，因此它不需要输出「平滑后的水平速度信号」，只输出边沿信号 + 原始轴值（供 DebugOverlay 显示）。

---

### D4 · InputMap 动作死区会吃掉模拟摇杆精度

**现状**：我在上一轮已把 `move_left` 等动作的 `deadzone` 写成了 **0.5**（Godot 默认值）。

**问题**：`Input.get_axis()` 内部会用这个 deadzone 做归一化——摇杆推到 0.3 会直接返回 **0**。原文要求的 0.15~0.2 冻结死区**永远无法生效**，手柄摇杆的渐进推量全部丢失，M1「手柄与键盘死区手感一致」无法验收。

**建议**：InputMap 的 `deadzone` 降到 **0.1**（只用来滤掉摇杆静置漂移），0.15~0.2 的**冻结死区**放在 `MovementInputHandler` 的 `@export var freeze_deadzone` 里，由 M1 实测微调。这条我会在开工时直接改掉已写入的配置。

---

### D5 · 能力解锁的门控放在哪一层

**原文**：3.1 要求玩家先无能力、在祭坛获得能力；但 4.2 的 `TimeManager` 参考实现里**没有任何能力开关**。

**建议**：门控放在 `TimeManager`，而不是 `MovementInputHandler`。

```gdscript
var is_ability_enabled: bool = false     # 第一章由祭坛置 true
func notify_movement_intent(moving: bool) -> void:
    if not is_ability_enabled:
        return                            # 未解锁：意图被忽略，世界恒 FLOWING
    ...
```

理由：`TimeFreezeFilter`、所有 `TimeReceiver`、`DebugOverlay` 都只订阅 `TimeManager`，门控在源头一处生效，下游零改动。若门控放在 `MovementInputHandler`，一旦后续有多个输入源（回放、脚本驱动）就会漏。

配套需要 `reset_state()`（场景切换 / 重开关卡时清 `is_releasing`、回 FLOWING），以及 `LevelBase._ready()` 强制调用它——对应风险表「场景切换状态残留」。

---

### D6 · 受时停动画的驱动方式（原文两种方案不等价）

**原文**给了两种：门用 `AnimationPlayer.speed_scale = 0/1`，`TimeReceiver` 用 `get_delta()` 累加。

**问题**：两者语义不同，混用会导致行为不一致。

- `speed_scale = 0.0` → 动画**冻结在当前帧**，恢复后从该帧继续。符合原文「确保恢复时从冻结帧继续」，✅ 正确。
- 但 `speed_scale` 是**乘法**，只能整体启停，无法做「时停期间以 0.5 倍速播放」这类后续需求；且它走的是 `_process`，与 D1 的 physics 通道不同步。

**建议**：按对象性质分工，写进规范：

| 对象 | 驱动方式 | 冻结手段 |
|---|---|---|
| Door（开关动画） | `AnimationPlayer` + `speed_scale` | `speed_scale = 0.0`（不用 `seek()`，避免跳帧） |
| Pendulum（摆动角度） | 脚本累加 `_elapsed += time_receiver.get_physics_delta()`，`rotation = sin(_elapsed * w) * amp` | delta 为 0 → `_elapsed` 停增 → 角度自然保持 |
| MovingBlock（巡逻位移） | 脚本累加 `_travel`，配合 `move_and_slide()` | `velocity = ZERO` 且**跳过** `move_and_slide()` 调用 |

钟摆**不要**用 `AnimationPlayer`：正弦累加能让 M1 的「旋转冻结、恢复后无跳变」变成可数学证明的性质，而动画轨道的插值在冻结/恢复边界上难以肉眼验证。

---

### D7 · 「`move_and_slide()` 在 deltaTime=0 时不会执行位移」是错的

**原文**：4.2 与风险表两处这样写。

**问题**：Godot 4 的 `move_and_slide()` **不接受 delta 参数**，它内部固定使用物理步长。把自定义 delta 设成 0 对它毫无影响——方块照样按 `velocity` 移动。

**正确做法**：冻结 = **把 `velocity` 缓存后置零，并直接 `return` 不调用 `move_and_slide()`**。不调用才是真冻结（连碰撞求解都不做），且其 `CollisionShape2D` 仍在物理空间中，玩家照常撞得上。恢复时从缓存还原速度方向。这恰好就是原文风险表里写的方案，只是 4.2 的表述需要纠正。

**物理体类型选择**（对应风险表「穿模/卡死」「物理碰撞滑动」）：

| 对象 | 建议类型 | 理由 |
|---|---|---|
| MovingBlock | `CharacterBody2D` | 不会主动推挤玩家（kinematic 撞 kinematic 只会停下），从根上消除挤压/穿模；`sync_to_physics` 无关 |
| Pendulum | `Node2D`（纯视觉，无碰撞体） | 原文 3.4 明确它是「普通场景装饰」，3.8 禁区又要求无动态压力源；给它碰撞体只会引入不必要的挤压风险 |
| Door | `StaticBody2D`，`AnimationPlayer` 驱动子节点 `CollisionShape2D` 与视觉多边形的 `position` | 静态体不参与速度求解，门升降时绝不会把玩家推走；不共享 shape 资源（动画改的是节点 position，不是 `shape.size`） |
| 可推箱子（M4 谜题 3） | **暂不定**，见 D11 | 与全局时停规则冲突 |

原文 4.1 把 Pendulum 写成 `AnimatableBody2D`、MovingBlock 写成 `CharacterBody2D`。我建议 Pendulum 降级为 `Node2D`，MovingBlock 保持。

---

### D8 · 灰滤镜的切分与 `SCREEN_TEXTURE` 写法

**问题 1**：原文 2.3 的 `ColorRect` 实现只做了**灰色叠加**，没有做「去饱和 30%~50%」。`Color(0.5, 0.5, 0.5, 0.2)` 盖上去是发灰，不是降饱和度。2.2 的表格与 2.3 的代码不是一回事。

**问题 2**：2.3 末尾提到的 `SCREEN_TEXTURE` 是 Godot 3 / Godot 4.0~4.2 的写法，**4.3+ 已移除**。Godot 4.6 必须用 shader uniform：

```glsl
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
```

**问题 3（排期冲突）**：3.5 要求灰滤镜在**祭坛获得能力的瞬间首次出现**，那是 M2 引导关的必经演出；但滤镜被排在 **M3**。M2 验收「全程无文字 + 玩家自主领悟移动=时停」在没有任何视觉反馈的前提下几乎不可能达标。

**建议**：
- **M2 就落地 `ColorRect` 灰叠加版**（约 30 行，原文代码可直接用），作为可读性下限；
- **M3 升级为 shader 去饱和版**（`hint_screen_texture`，Compatibility 渲染器支持，M3 需实测确认），并补齐音效与「边缘蓝色偏移 / 解冻亮度脉冲」可选项；
- `TimeFreezeFilter` 的对外接口两版保持一致（订阅 `TimeManager.state_changed`），升级只换内部实现，不动关卡。
- `layer` 定值：`TimeFreezeFilter = 100`，`PauseMenu = 200`，`DebugOverlay = 300`（原文要求滤镜低于 DebugOverlay、暂停菜单在滤镜之上）。

---

### D9 · 相机方案

**原文**：4.1 只写了 `CameraRig (可选)`，没有任何规格。但引导关是「初始房间 → 右侧旁路 → 教学走廊 → 祭坛 → 原路返回 → 初始房间 → 出门」的**非线性往返**布局，相机直接决定「旁路发现时间 < 60 秒」这条 M2 验收指标能否达成。

三个选项：

| 方案 | 说明 | 代价 |
|---|---|---|
| **A. 跟随 + 关卡级 limits**（建议 M2 起点） | `Camera2D` 挂玩家，位置平滑 + 水平前瞻，limits 取整个关卡包围盒 | 房间狭小时会看到隔壁房间，可能提前泄露旁路 |
| **B. 跟随 + `CameraZone` 动态 limits** | 每个房间放一个 `Area2D`，玩家进入时改写相机 limits，可做房间间硬切/淡入 | 多一套区域节点，白模阶段调位置费时 |
| **C. 每房间固定机位** | 房间即一屏，玩家进出时切机位 | 最可控、最利于「零文字引导」编排，但牺牲连贯感，且走廊长度受限 |

**建议**：M2 白模先用 **A**（一个 `PlayerCamera` 脚本 + `@export` limits，最快验证布局）；等灰盒布局定稿、发现泄露问题时再升级到 **B**。`PlayerCamera` 的接口两版通用。

---

### D10 · 命名规范冲突

原文档写 `Assets/Chapter_02_Reserved/`、`TimeManager.gd`、`TimeFreezeFilter.gd`（目录首字母大写、脚本 PascalCase），而 Godot 官方与本工程采用的规范是**目录/文件 snake_case、`class_name` PascalCase**。

**建议**：统一走 snake_case。

```
assets/chapter_02_reserved/.gdignore
autoloads/time_manager.gd          →  class_name 不写，autoload 注册名 TimeManager
scenes/ui/time_freeze_filter.gd    →  class_name TimeFreezeFilter
```

⚠️ **一个必须避开的坑**：autoload 单例**不能**同时在脚本里写 `class_name TimeManager`，Godot 4 会报 `Class "TimeManager" hides an autoload singleton`。`TimeManager` / `GameManager` 这类单例只靠 autoload 注册名访问，脚本内**不声明 `class_name`**。而 `TimeReceiver`、`TimeFreezeFilter`、`Player` 等非单例照常声明。

---

### D11 · M4 两处内部矛盾（不阻塞 M1~M3，但需提前知道）

**矛盾 1：推箱子（M4 谜题 3）与全局时停规则冲突。**
「时停期间可推动物体（物体也冻结）→ 推动箱子到按钮上」——玩家**必须水平移动**才能推箱子，而水平移动**必然触发时停**，被时停的箱子 delta 为 0，推不动。逻辑闭环断裂。
三种解法，需你选：
1. 箱子**豁免**全局时停（始终用自己的 delta）→ 最简单，但破坏「移动=万物静止」的心智模型；
2. 箱子的时间源改为「玩家推挤驱动的专属 delta」→ 正是 `TimeReceiver.set_time_source()` 的用武之地，但这**已经是第二章锚点系统的雏形**，与 1.2「本章隔离」冲突；
3. 重新设计该谜题：箱子只在**玩家静止时被推动**（例如靠另一个机关），时停用于锁定它到位后的状态。

**矛盾 2：移动平台。**
3.8 禁区写「不出现可交互的移动平台（属后续章节内容）」，而 M4 谜题 4 恰恰是「时停时跳过移动平台，平台冻结在空中形成路径」——M4 属于第一章。两条直接对立。
需确认：谜题 4 是否延后到第二章，或 3.8 的禁区仅约束 M1~M3。

**✅ 已决策（2026-09-16）**：这两类谜题**整体延后到第二章**，待时间锚点系统解锁后再做。第一章 M4 只做不依赖「专属时间源」的纯时停谜题（垂直移动不触发时停、时停期间观察环境线索、时停期间碰撞体仍有效、组合运用）。`TimeReceiver.set_time_source()` 保持空接口、**全章零调用方**，与 1.2「本章隔离」一致。

---

## 2. 目录结构

```
upstream/
├── docs/
│   └── architecture_chapter_01.md        # 本文档
├── autoloads/
│   └── time_manager.gd                   # 唯一单例（第一章）
├── components/
│   └── time_receiver.gd                  # 通用时间源组件
├── scenes/
│   ├── actors/
│   │   └── player/
│   │       ├── player.tscn
│   │       ├── player.gd                 # class_name Player
│   │       ├── movement_input_handler.gd # class_name MovementInputHandler
│   │       └── player_camera.gd          # class_name PlayerCamera
│   ├── levels/
│   │   ├── main.tscn                     # 常驻 World 根（原文 4.1 的 World）
│   │   ├── main.gd
│   │   ├── level_base.gd                 # class_name LevelBase
│   │   ├── m1_sandbox.tscn               # M1 时间手感试验场
│   │   ├── level_01_tutorial.tscn        # M2 引导关
│   │   ├── level_01_tutorial.gd
│   │   └── rooms/
│   │       ├── initial_room.tscn         # 阶段一 + 阶段五
│   │       └── teaching_corridor.tscn    # 阶段二（去程/返程共用同一实例）
│   ├── objects/
│   │   ├── platform/                     # 占位静态地形构件
│   │   ├── button_plate/                 # Area2D + pending_unpress
│   │   ├── door/                         # StaticBody2D + AnimationPlayer
│   │   ├── pendulum/                     # Node2D 正弦累加
│   │   ├── moving_block/                 # CharacterBody2D 巡逻
│   │   ├── ability_altar/                # Area2D，一次性触发
│   │   └── test_cube/                    # M1 专用：位移+旋转+动画三合一冻结验证体
│   └── ui/
│       ├── time_freeze_filter.tscn/.gd   # CanvasLayer 100
│       ├── debug_overlay.tscn/.gd        # CanvasLayer 300，仅 debug build
│       └── pause_menu.tscn/.gd           # CanvasLayer 200
├── shaders/
│   └── time_freeze_desaturate.gdshader   # M3 才写
├── assets/
│   ├── chapter_02_reserved/
│   │   └── .gdignore                     # 物理隔离第二章资产
│   └── audio/sfx/                        # M3 冻结音效
└── project.godot
```

**为什么需要 `main.tscn`**：原文 4.1 把 `TimeFreezeFilter`、`DebugOverlay` 与 `Level_01_Tutorial` 并列为 `World` 的子节点，意味着它们是**跨关卡常驻**的。用一个常驻根场景承载 overlay，关卡只在 `LevelContainer` 下换入换出，滤镜与调试层不会被关卡切换打断，也不需要在每个关卡里重复实例化。第一章只有一个关卡，但 M4 会有 3~5 个谜题关，此时这个结构直接受益。

---

## 3. 时间系统数据流

```
[输入设备]
    │  Input.get_axis("move_left","move_right")   ← InputMap deadzone = 0.1 (D4)
    ▼
MovementInputHandler        _physics_process, priority = -200
    │  abs(raw) > freeze_deadzone(0.18) ?
    │  边沿检测 → movement_started / movement_stopped
    ▼
TimeManager (autoload)      _physics_process, priority = -100
    │  is_ability_enabled 门控 (D5)
    │  started → 立即 FROZEN，取消解冻倒数
    │  stopped → 启动 0.08s 倒数（用固定物理步长累加）
    │  倒数中再 started → 取消倒数
    │  暴露：current_state / is_releasing() / get_physics_delta() / get_process_delta() / get_time_scale()
    ├──────────────► state_changed(TimeState)  ──► TimeFreezeFilter (_process 插值 alpha)
    ├──────────────► state_changed(TimeState)  ──► DebugOverlay
    └──────────────► 被 TimeReceiver 轮询
                          │
                          ▼
              TimeReceiver (每个受时停对象挂一个子节点)
                  get_physics_delta() / get_process_delta()
                  set_time_source(Callable)   ← 第一章留空接口，无调用方 (D11)
                          │
        ┌─────────────────┼──────────────────┬─────────────────┐
        ▼                 ▼                  ▼                 ▼
    Door            Pendulum           MovingBlock        ButtonPlate
  speed_scale=0/1   _elapsed += d      d<=0 → return     pending_unpress
```

**不受时停影响（必须明确豁免）**：`Player` 的移动/重力/土狼时间/跳跃缓冲、`PlayerCamera`、所有 UI、音效播放。玩家是「时间旅行者」，自身动画与位移永远走真实 delta。

**执行顺序保障**：靠 `process_physics_priority` 显式排序（-200 → -100 → 0），不依赖场景树节点顺序。这是 Godot 里唯一可靠的同级回调排序手段。

---

## 4. 脚本清单与职责边界

| 文件 | 类型 | 职责 | 对外接口 | 明确**不做** |
|---|---|---|---|---|
| `time_manager.gd` | Autoload（无 `class_name`） | 时停状态机 + 缓冲 + 门控 + 双通道 delta | `state_changed`、`current_state`、`is_releasing()`、`get_physics_delta()`、`get_process_delta()`、`get_time_scale()`、`notify_movement_intent(bool)`、`set_ability_enabled(bool)`、`reset_state()` | 不读输入（交给 Handler）；不碰 `Engine.time_scale`；不管视觉 |
| `time_receiver.gd` | `class_name TimeReceiver extends Node` | 单个对象的时间源代理 | `get_physics_delta()`、`get_process_delta()`、`set_time_source(Callable)`、`time_source_changed` | 不含任何游戏逻辑；`_ready()` 加入 `time_receiver` 分组 |
| `movement_input_handler.gd` | `class_name ... extends Node` | 读原始水平轴、死区、边沿检测 | `movement_started`、`movement_stopped`、`raw_axis`、`@export freeze_deadzone` | 不做加速度平滑（D3）；不监听垂直输入；不改玩家速度 |
| `player.gd` | `class_name Player extends CharacterBody2D` | 平台跳跃手感 | `respawn()`、`landed`、`jumped`、`@export` 手感参数组 | 不查 `TimeManager`（永久豁免）；不管能力解锁 |
| `player_camera.gd` | `class_name PlayerCamera extends Camera2D` | 跟随 + 平滑 + 前瞻 + limits | `@export` 平滑/前瞻/limits | 不查 `TimeManager` |
| `main.gd` | `class_name Main extends Node` | 关卡换入换出、R 键重开关卡、暂停协调 | `load_level(path)`、`restart_level()` | 不含谜题逻辑 |
| `level_base.gd` | `class_name LevelBase extends Node2D` | 关卡基类 | `_ready()` 调 `TimeManager.reset_state()`、记录出生点 | — |
| `button_plate.gd` | `class_name ButtonPlate extends Area2D` | 踩踏检测 + FROZEN 期间延迟松开 | `pressed_changed(bool)`、`pending_unpress` | 不直接操作门（发信号，关卡/门自己连） |
| `door.gd` | `class_name Door extends StaticBody2D` | 升降 + 时停冻结动画帧 | `set_open(bool)`、`speed_scale` 门控 | 不用 Tween（原文明令禁止）；不用 `seek()` |
| `pendulum.gd` | `class_name Pendulum extends Node2D` | 正弦摆动，累加相位 | `@export period/amplitude` | 无碰撞体（D7） |
| `moving_block.gd` | `class_name MovingBlock extends CharacterBody2D` | 双点巡逻 + 冻结时零速并跳过 `move_and_slide()` | `@export path_a/path_b/speed` | 不推挤玩家 |
| `ability_altar.gd` | `class_name AbilityAltar extends Area2D` | 一次性触发能力授予演出 | `ability_granted` | 不直接改 `TimeManager`（发信号由关卡编排） |
| `time_freeze_filter.gd` | `class_name ... extends CanvasLayer` | 灰度反馈视觉 | 订阅 `state_changed` | 不判定状态；`mouse_filter = IGNORE` |
| `debug_overlay.gd` | `class_name ... extends CanvasLayer` | 开发期诊断 | 枚举 `time_receiver` 分组 | 仅 `OS.is_debug_build()` 可见 |

---

## 5. 场景与节点树

```
main.tscn
Main (Node)                                    main.gd
├── LevelContainer (Node2D)                    ← 关卡在此换入
├── TimeFreezeFilter (CanvasLayer, layer=100)
│   └── ColorRect (full rect, mouse_filter=IGNORE)
├── PauseMenu (CanvasLayer, layer=200, process_mode=ALWAYS)
└── DebugOverlay (CanvasLayer, layer=300)

level_01_tutorial.tscn
Level_01_Tutorial (Node2D)                     level_01_tutorial.gd (extends LevelBase)
├── Environment (Node2D)                       ← 占位地形、CanvasModulate（若采纳 D9 光照引导）
├── InitialRoom (instanced rooms/initial_room.tscn)
│   ├── Geometry (platform × N)
│   ├── ButtonPlate
│   ├── Door
│   └── BypassHint (旁路入口暖光/纹理差异)
├── TeachingCorridor (instanced rooms/teaching_corridor.tscn)
│   ├── Geometry
│   ├── Pendulum
│   ├── MovingBlock
│   ├── DirectionalFloor (箭头状占位纹理)
│   └── AbilityAltar
└── PlayerSpawn (Marker2D)

player.tscn
Player (CharacterBody2D)                       player.gd
├── CollisionShape2D (RectangleShape2D)
├── Visual (Polygon2D)                         ← 纯色占位
├── MovementInputHandler (Node)                movement_input_handler.gd
├── PlayerCamera (Camera2D)                    player_camera.gd
└── CoyoteTimer / BufferTimer 用脚本内 float 累加，不建 Timer 节点

每个受时停对象统一追加一个子节点：
└── TimeReceiver (Node)                        time_receiver.gd
```

---

## 6. 物理层、分组、约定

**碰撞层**（第一章够用即可，不过度预留）：

| 层 | 名称 | 使用者 |
|---|---|---|
| 1 | `terrain` | Platform、静态墙体 |
| 2 | `player` | Player |
| 3 | `time_solid` | MovingBlock、Door（受时停的实体） |
| 4 | `sensor` | ButtonPlate、AbilityAltar 等 Area2D（`monitoring` 层 2） |

**分组**：
- `time_receiver` — 所有 `TimeReceiver` 在 `_ready()` 自注册，`DebugOverlay` 枚举它
- `player` — 相机区域、机关查找玩家用

**节点/文件命名**：目录与文件 snake_case，`class_name` PascalCase，autoload 单例不写 `class_name`（D10）。

**占位视觉**：全部 `Polygon2D` + 纯色，世界空间以左上角为原点、按 **32px 网格**摆放，便于灰盒阶段直接换算「5~6 个身位」这类布局要求（原文 3.3）。

---

## 7. 里程碑 → 交付文件映射

### M1 · 时间手感
**交付**：`time_manager.gd`、`time_receiver.gd`、`movement_input_handler.gd`、`player.gd`、`player_camera.gd`、`platform/`、`test_cube/`、`main.tscn`、`m1_sandbox.tscn`、`debug_overlay.gd`
**验收挂钩**：
- 「移动/停止切换顺滑无闪烁」→ D2 双边沿 + 0.08s 缓冲 + D3 原始输入零延迟
- 「Cube 位置/旋转/动画帧均冻结，恢复后无跳变」→ `test_cube` 一个节点同时挂三种驱动（位移累加 / 旋转累加 / `AnimationPlayer`），一次看全
- 「30fps 与 60fps 判定一致」→ D1 physics 通道；实测方式：`Engine.max_fps` 限 30 与不限，各跑一次，比对 `_travel` 累计值
- 「手柄与键盘死区手感一致」→ D4 InputMap deadzone 0.1 + Handler 内 0.18

> **排期调整建议**：原文把 `DebugOverlay` 放在 M3，但 M1 的「恢复后无跳变」没有数值面板根本无法客观验证。建议 **DebugOverlay 提前到 M1**，M3 只补着色与性能优化。

### M2 · 引导关白模
**交付**：`level_base.gd`、`level_01_tutorial.tscn`、`rooms/initial_room.tscn`、`rooms/teaching_corridor.tscn`、`button_plate/`、`door/`、`pendulum/`、`moving_block/`、`ability_altar/`、`time_freeze_filter`（ColorRect 版，见 D8）
**验收挂钩**：
- 「无能力阶段尝试次数 2~5 次」→ 按钮与门间距 ≥5 身位（160px+）、门关闭动画 0.5s
- 「旁路发现时间 < 60s」→ D9 相机方案 + 旁路入口视觉引导（需确认是否引入 `CanvasModulate` 暗场 + `PointLight2D`，见下）
- 「获得能力到通过按钮门 < 90s」→ 祭坛后 2~3s 强制静止观察窗
- 「全程无文字」→ 工程内不建任何教程 UI 场景

> **占位美术与光照引导的冲突**：原文 3.3/3.4 大量依赖「微弱暖光」「地面方向性纹理」做零文字引导。纯色 `Polygon2D` 在默认材质下**能**受 `Light2D` 影响，但需要 `CanvasModulate` 把场景压暗才能看出光斑——这会把整体视觉基调变成暗场。
> 两个选项，需你定：
> - **A. 引入 `CanvasModulate` 暗场 + `PointLight2D`**：引导表现力强，贴近原文意图，但占位阶段调试地形会偏暗。
> - **B. 假光斑**：additive 混合的暖色 `Polygon2D` 直接叠在地面，方向纹理用 chevron 多边形阵列。零光照系统依赖，白模阶段更直观，M3 再换真光照。
> 我建议 **B 起步**，因为它不阻塞任何系统开发，且换真光照时只是替换视觉节点。

**状态（2026-09-16）**：引导关已由你实机试玩验收，"机制都没问题"。逐文件清单、几何依据与试玩读数见 `docs/m2_level_01_layout.md`。

紧随其后的 **M2.5 打包轮**：分工改成"地图由你摆，构件只负责好用"。交付 `sensor_zone` 构件、`level_template` 关卡模板、`docs/level_authoring_guide.md`（摆图只读这一页）与两条无头守门命令；构件全部 `@tool` 化、地面构件统一底边中心原点、触发带带心改由 `Player.COLLISION_HALF_HEIGHT` 算出。**时停内核与玩家手感未改动**，`tools/kit_selftest` 复核冻结语义仍成立。

### M3 · 反馈层
**交付**：`shaders/time_freeze_desaturate.gdshader`、滤镜升级、冻结音效、DebugOverlay 着色
**验收挂钩**：滤镜 0.1s 达目标透明度 / 0.08~0.15s 消退；性能开销 <5%（Compatibility 渲染器下 `hint_screen_texture` 需实测）

### M4 · 第一章扩展
**交付**：3~5 个谜题关 + `GameManager` autoload（关卡进度/能力持久化）——**此单例在第一章前三个里程碑都不需要**，避免过早抽象。
**阻塞项**：D11 两处矛盾需先解决。

---

## 8. 明确不在本次范围

- 锚点同步系统（1.2，第二章）——仅保留 `TimeReceiver.set_time_source()` 空接口，全章无任何调用方
- 敌人、追逐战、任何动态压力源（3.8）
- 教程弹窗、按键提示图等文字 UI（3.8）
- 存档系统、关卡选择、主菜单
- 死亡与重生：原文 3.8 不引入压力源，第一章**可能根本没有致死要素**。建议 `Player.respawn()` 与 R 键重开关卡照做（开发期必需），但 `KillZone` 等灰盒布局确定后按需再加
- 输入重绑定（`InputRemapper`）

---

## 附：需要你回复的清单

| 编号 | 一句话问题 | 我的建议 |
|---|---|---|
| D1 | 时停判定走 physics 还是 process 通道？ | physics（否则 M1 帧率一致性过不了） |
| D2 | 缓冲计时改为「停止移动时启动」？ | 是（原文代码会让世界在移动中自动解冻） |
| D3 | 冻结判定用原始轴值，平滑只用于角色加速度？ | 是 |
| D4 | InputMap deadzone 由 0.5 改 0.1？ | 是（否则手柄摇杆精度全丢） |
| D5 | 能力门控放 `TimeManager`？ | 是 |
| D6 | 钟摆用正弦累加而非 AnimationPlayer？ | 是 |
| D7 | Pendulum 降为 `Node2D` 无碰撞、Door 用 `StaticBody2D`？ | 是 |
| D8 | 灰滤镜 ColorRect 版提前到 M2、shader 版留 M3？ | 是 |
| D9 | 相机 A / B / C？ | M2 先 A，布局定稿后视情况升 B |
| D10 | 目录文件统一 snake_case？ | 是 |
| D11 | M4 推箱子与移动平台两处矛盾怎么解？ | 可暂缓，但需知道会反向影响 `set_time_source()` 是否在第一章打通 |
| 光照 | 占位阶段用暗场真光照(A) 还是假光斑(B)？ | B |
| DebugOverlay | 提前到 M1？ | 是 |

---

## M1 交付与验证记录（2026-09-16）

### 已交付文件

脚本 11 个：

```
autoloads/time_manager.gd
components/time_receiver.gd
scenes/actors/player/player.gd
scenes/actors/player/movement_input_handler.gd
scenes/actors/player/player_camera.gd
scenes/levels/main.gd
scenes/levels/level_base.gd
scenes/objects/platform/platform.gd
scenes/objects/test_cube/test_cube.gd
scenes/ui/debug_overlay.gd
scenes/ui/time_freeze_filter.gd
```

场景 7 个：

```
scenes/levels/main.tscn            主场景（已设为 run/main_scene）
scenes/levels/m1_sandbox.tscn      M1 沙盒：4 个验证体 + 阶梯地形
scenes/actors/player/player.tscn
scenes/objects/platform/platform.tscn
scenes/objects/test_cube/test_cube.tscn
scenes/ui/time_freeze_filter.tscn
scenes/ui/debug_overlay.tscn
```

隔离目录：`assets/chapter_02_reserved/.gdignore`（第二章锚点资源物理隔离，设计文档 1.2 / 3.8）

### 客观实测：TimeManager 状态机 31 项断言

做法：MCP 无法内省运行中的游戏进程，因此在编辑器内 `load("res://autoloads/time_manager.gd").new()` 取独立实例，手动喂 `_physics_process(1/60)` 驱动状态机。**26 项直接通过，5 项失败经复测确认全部是测试脚本自身缺陷，产品行为正确。**

核心结论：

| 验证项 | 实测结果 | 意义 |
|---|---|---|
| **D2 修复** | 按住方向键连喂 120 个物理帧（2 秒），状态恒为 FROZEN，`elapsed_world_time` 恒为 0.0 | 设计文档原版会在 0.08s 后自动解冻，按钮门谜题根本无解 |
| 冻结即时性 | `notify_movement_intent(true)` 后**不喂任何帧**即为 FROZEN | 无输入延迟感 |
| 防抖窗口 | 缓冲 0.08s = 4.8 帧；第 1~4 帧 FROZEN，第 5 帧转 FLOWING | 与设计值一致 |
| 帧不丢失 | 转换那一帧（第 5 帧）世界时间即 +1 步（1667e-5 = 1/60） | 先 `_advance_release_buffer` 再累加的顺序是对的 |
| 重按取消缓冲 | 缓冲中重新按键 → 立即清除 `_is_releasing`，再喂 120 帧仍 FROZEN | 抖动输入不会误解冻 |
| **无闪烁** | 一次完整「冻结→保持→释放」循环，`state_changed` 精确发射 2 次（`[1, 0]`），120 个保持帧内 0 次多余发射 | 灰滤镜不会抖动 |
| 能力门控 | `is_ability_enabled = false` 时移动意图被完全忽略；关闭能力强制回 FLOWING | 初始房间「无能力」阶段成立 |
| 门控 delta | FROZEN 时 `get_physics_delta()` / `get_process_delta()` / `get_time_scale()` 全为 0.0 | 受时停对象正确停摆 |
| 关卡重置 | `reset_state()` 清空状态、缓冲、世界计时 | 对应风险表「场景切换状态残留」 |

### D1 的意外实证

同一节点在树内测得：

```
get_physics_process_delta_time() = 0.01666666666667   (恒等于 1/60)
get_process_delta_time()         = 0.00694444444444   (= 1/144，当前显示器刷新率)
```

两者相差 **2.4 倍**。设计文档 1.1 要求在 `_physics_process` 里读 `Time.get_process_delta_time()`——若照做，在这台机器上世界时间会以 2.4 倍速流动，且倍率随显示器刷新率变化（144Hz / 165Hz / 60Hz 各不相同）。这正是 D1 建议改走 physics 通道的原因，现已用实测数字坐实。

顺带确认：`Time.get_process_delta_time()` 这个静态方法在 Godot 4.6 **不存在**（`ClassDB.class_has_method("Time", "get_process_delta_time") == false`），只有 `Node.get_process_delta_time()`。设计文档 4.2 的参考代码此处无法编译。

### 5 项失败的归因（均为测试脚本问题）

1. 3 项信号计数失败 —— GDScript lambda **按值捕获**局部 `int`，`emissions += 1` 改的是副本。改用按引用捕获的 `Array` 复测，得到 `[1, 0]`，正确。
2. 1 项世界时间失败 —— 期望值算错。第 6 节的 2 帧也已转入 FLOWING 并计时，实际共 8 帧 × 1/60 = 0.1333，产品正确。
3. 1 项 `physics_delta > 0` 失败 —— 节点**不在场景树内**时 `get_physics_process_delta_time()` 返回 0.0。加入树后返回 1/60。实际运行时 TimeManager 是 autoload，必然在树内。

### 运行验证：main.tscn 全栈零报错

实测两处日志，均只有引擎版本与 OpenGL 初始化两行，**零 Error、零 Warning、零脚本报错**：

- `user://logs/godot.log`（185 字节）
- 编辑器输出面板（`get_editor_logs(source="editor_panel")`，`total_available=2`，全是 Info）

覆盖链路：`main.tscn` → `main.gd` preload 并实例化 `m1_sandbox.tscn` → `level_base.gd` 调用 `TimeManager.reset_state()` / `set_ability_enabled(true)` → 4 个 TestCube 各自挂 TimeReceiver → Player + MovementInputHandler + PlayerCamera → TimeFreezeFilter 连接 `state_changed` → DebugOverlay 每帧刷新。

这条尤其重要：编辑器内那 5 个脚本报 `err=36` 无法编译，但**游戏进程里全部编译通过并正常运行**——否则输出面板必然出现脚本错误。

### 踩到的坑：Play 会启动「编辑器当前打开的场景」

MCP `run_project`（等价于编辑器 **F6**）跑的是**当前打开的场景**，不是 `run/main_scene`。

第一次实测时编辑器里开着 `m1_sandbox.tscn`，于是游戏直接跑了沙盒本体——`TimeFreezeFilter` 和 `DebugOverlay` 都挂在 `main.tscn` 下，**灰滤镜与调试面板根本不会出现**，看起来就像时停没有视觉反馈。

处理方式：

- 已把编辑器当前场景切到 `main.tscn`
- 验证时请用 **F5**（运行主场景），或确认编辑器打开的是 `main.tscn` 再按 F6

### 尚未验证 —— 需要实机手感确认

MCP 暴露的 30 个工具**全部是编辑器作用域**，够不到运行中的游戏进程。实测证据：游戏运行期间 `list_nodes("/root")` 只返回 1 个子节点 `M1Sandbox`（编辑器里的场景实例），查不到 `/root/Main`、`/root/TimeManager`；`get_node_properties` 读到的 CubeFloor 是 `motion_mode=0`、`position.x=520`，而 `test_cube.gd` 的 `_ready()` 会把它们改成 `FLOATING` 和 `360`——说明读到的是从未运行过 `_ready()` 的编辑器实例。

运行时探针 `mcp_runtime_probe.gd` 本身支持 `simulate_input_action`、`call_node_method`、`get_runtime_screenshot`，但这些能力**没有作为 MCP 工具暴露出来**，所以无法自动注入输入或截图比对。

因此以下 M1 验收项必须人工试玩：

- 移动/停止切换**手感**是否顺滑（状态机层面已证明无闪烁，但加速度曲线、死区体感需实测）
- Cube 的位移 / 自转 / 缩放脉冲三者冻结与恢复是否**视觉上**无跳变
- 30fps（F1）与不限帧下世界时间流速是否一致（机制上已成立：累加的恒为 1/60）
- 手柄摇杆与键盘的死区手感是否一致

#### 试过但走不通的路：在编辑器进程内驱动整条链路

曾设想用 `Engine.register_singleton("TimeManager", instance)` 把 autoload 注进编辑器进程，再手动喂 `_physics_process(1/60)` 做确定性断言。**实测否定**：

- `Engine.register_singleton()` 会被 GDScript 的 autoload 解析绕过。GDScript 里的 `TimeManager` 标识符解析到的是**编辑器为其生成的 placeholder 实例**，不是 Engine 单例表里的那个对象。判据：注册成功后 `TimeManager == instance` 仍为 `false`，且任何方法调用报 `Attempt to call a method on a placeholder instance. Check if the script is in tool mode.`
- `Engine.register_singleton("TimeManager", ...)` 本身还会先撞上 `ERROR: Singleton already registered: 'TimeManager'`——编辑器启动时已注册过同名 placeholder。
- 结论：**凡引用 autoload 标识符的脚本，都无法在编辑器进程内做行为测试**。要让它们在编辑器里跑，唯一办法是给 `time_manager.gd` 加 `@tool`，但那会让状态机在编辑器里持续 tick，属于为测试污染产品代码，不做。

顺带查到的两个编辑器进程事实（都可复用）：

1. **Godot 4.6 编辑器启动时不会把项目的 `[input]` 动作灌进 `InputMap`。** 刚启动时 `InputMap.get_actions()` 只有 88 个引擎内置 `ui_*` + 编辑器自加的 `spatial_editor/*`，`InputMap.has_action(&"move_right")` 为 `false`，尽管 `ProjectSettings.has_setting("input/move_right")` 为 `true`。需要显式调 `InputMap.load_from_project_settings()`（**零参数**，带参数是编译错误），调用后 `get_actions()` 变 98、7 个项目动作齐全且 deadzone 正确（移动类 0.1、`dev_fps_cap` 0.5）。
2. **`Input.action_press(action, strength)` 的 strength 不受 InputMap deadzone 缩放**：按 0.15 进去 `Input.get_axis()` 就读到 0.15。所以「deadzone 0.1 是否会先吃掉摇杆精度」这条**无法用 action_press 验证**，只能在真手柄上实测；能验证的是 handler 自身 0.18 阈值这一层。

因此改走**在游戏进程内跑自测场景**：`tests/` 下建一个自测场景，运行时用 `Input.action_press/release` 注入输入、逐物理帧采样 `TimeManager` 与各 `TimeReceiver` 对象的累计量、把断言结果打进日志后 `quit()`；跑完由 `user://logs/godot.log` 取回结果。这条路同时覆盖编辑器路径够不到的 `move_and_slide()`、`AnimationPlayer` 轨道求值与真实帧率，代价是一个仅测试用的脚本与场景，不碰 M1 产品代码。

> 上面的 `register_singleton` 结论来自我一次误判：最初那次「注入成功」的探针里输入根本没按下（`is_moving=false`），状态没变化被当成了「调用生效」。教训同 D1：判据必须能证伪。

### 已知问题（已解决）

编辑器进程在 `TimeManager` 写入 `project.godot` **之前**就已启动，因此编辑器内的 GDScript 分析器无法解析该标识符，5 个引用它的脚本报 `err=36 (ERR_METHOD_NOT_FOUND)`，无法实例化。

**这不影响运行**：游戏进程启动时才注册 autoload，实测运行 `main.tscn` 的日志零报错零警告。

**2026-09-16 复验：重启编辑器后已清除。** 11 个脚本 `reload()` 全部返回 `OK`、`new()` 全部成功。

> **坑位：`can_instantiate()` 不是可靠探针。** 刚 `load()` 完的脚本即使完全正确也会返回 `false`（Godot 4 延迟编译，首次实例化才真正编译）。要判断脚本是否真有问题，用 `s.reload() == OK` 且 `s.new() != null`。用 `can_instantiate()` 会把 11 个健康脚本误判成 10 个坏掉。

---

## 设计决策补录（2026-09-16）

### D13：贴墙推动仍触发冻结 —— 保持不变

**现象**：角色贴墙、朝墙推方向键时，时间冻结但角色不产生位移。

**结论：不修。冻结判定绑定「输入意图」，不绑定「实际位移」。**

若改成位移判定（velocity-based），会引入三个直接违反 M1 验收项的问题：

1. **抖回闪烁**。速度归零的场景远不止撞墙：落地那一帧、被移动方块顶住、贴墙滑动。每一处都可能让时间在 1 帧内 FROZEN/FLOWING 反复横跳，砸掉「移动/停止切换顺滑无闪烁」。
2. **输入延迟**。冻结会比按键晚至少一帧生效，违反设计文档 1.1「FLOWING→FROZEN 应立即触发，避免输入延迟感」。
3. **按钮门谜题变脆**。第一章高潮是「踩按钮→保持水平移动→门冻结在开启态→穿门」。位移判定下任何一帧速度恰好为 0，门就开始关，玩家会莫名失败。

「白嫖冻结」在当前设计下没有收益：冻结的价值来自**穿过被冻住的世界**，贴墙站着什么都穿不过去；且 3.8 禁区保证第一章无时限压力，不存在用墙白嫖观察时间的漏洞。

反馈本身已自洽：灰滤镜绑定**时间状态**而非位移，贴墙时滤镜照样出现，玩家看到画面变灰即知「世界停了，哪怕我没动」，无需文字解释。附带收益是新手误撞墙时能在零风险下第一次看到钟摆停住——一个免费的教学时刻。

### D14：「持续静止绕行」谜题 —— 评估后暂不做

**设想**：必须全程保持时间静止，流畅绕过各种障碍物抵达终点。

**否决理由：按字面实现会退化。** 全程 100% 静止 ⇒ 所有 TimeReceiver 也 100% 静止 ⇒ 障碍物根本不动。玩家等于在静态关卡里多按住一个键走完全程，时停不产生任何决策，谜题消失。

若要保住「必须一直静止」的原意，需要一个**只在时间流动时推进**的威胁（蔓延的结晶、上涨的潮水、缓慢逼近的静滞场），使持续静止成为有代价的约束而非免费默认状态。但这属于动态压力源，与 3.8 禁区「不引入敌人、追逐战等动态压力源」冲突，需另行定夺。

**附带收益（若将来重启此谜题）**：D13 的贴墙推动会从「无害」升级为**设计资源**——在不能断的静止链里，墙是玩家唯一能停下来读路况而不破坏冻结的**安全港**，这类点位应刻意摆放。

### 附：两个已识别的输入边界（暂不实施）

以下两项都是 D14 那类「静止链不能断」的谜题才会真正暴露的问题。当前设计下 0.08s 释放缓冲已能吸收绝大多数情况，且修改自带回归风险，故**记录但不实施**。

**(a) 键盘「搓招」瞬间断链。** `Input.get_axis(&"move_left", &"move_right")` 返回 右 − 左。快速变向时若先按新方向再松旧方向（手指滚动），两键同时按下 ⇒ axis = 0 ⇒ `absf(0) > 0.18` 为 false ⇒ 发 `movement_stopped`。手越熟越容易触发。

- 当前影响：0.08s 缓冲通常已吸收，仅当滚动耗时超过 0.08s 才会真断。
- 若将来要修：把冻结意图与净轴解耦，改用 `Input.is_action_pressed(&"move_left") or Input.is_action_pressed(&"move_right")` 判定冻结，位移向量仍用 `get_axis()`（重叠 = 不动是标准手感）。
- **回归风险**：`is_action_pressed` 用的是 InputMap deadzone(0.1) 而非 `freeze_deadzone`(0.18)，摇杆灵敏度会变，直接冲击 M1 验收项「手柄与键盘死区手感一致」。要改就必须同时改成读原始轴强度自行比 0.18，否则得不偿失。

**(b) 摇杆过零必然断链。** 模拟摇杆从最左打到最右必须物理穿过 ±0.18 死区带，快速一甩在死区内停留时长**估计** 60~150ms 量级（**未实测**），正压在 0.08s 缓冲边界上，导致变向能否保住冻结取决于甩动力度——不确定手感，是最差的一类。

- 若将来要修：**不要动全局缓冲**（会让按钮门的「穿门→停止→门关」变黏，那是 M1/M2 核心手感）。把 `RELEASE_BUFFER_DURATION` 从 `const` 改为带 setter 的 `var`，让持续静止关卡单独设 0.20~0.25s。该关卡里玩家本就不打算停，长缓冲几乎无副作用，纯粹用于宽恕变向。

---

## 美术决策补录（2026-09-16）· 主角像素动画

参考图 `assets/player/preview.png`：黑色光泽流体小史莱姆，白眼睛 + 一点粉嘴。调色板直接从这张图取（`#040404 / #0a0c0c / #1a1c21 / #2d3138 / #676d7b / #c1d3df`）。

### A1 · 序列帧用代码画，不用生成式图像

需要的是**逐帧对齐同一条脚底基线、带真 alpha、调色板一致**的定尺寸帧。图像模型给的是高分辨率、无透明通道、每个姿势轮廓尺寸都不一样的图，切片后逐帧抖动，还得人工修。代码画的帧由一组参数（宽、高、挤压、剪切、眨眼）驱动，改数值就能重出；将来像素画师逐帧替换 PNG 文件，接线一行都不用动。

生成器：`tools/gen_player_frames.py`。

### A2 · 帧规格 44×44，脚底落在 local y=+15

- 画布 44×44：最宽帧 33 px，但前倾剪切会把整团质量甩向一侧，两侧都要留余量。脚本里 `check_fit()` 是硬守门：任何一帧有不透明像素压到画布边缘就直接失败退出。
- 原点 = 画布中心 = 碰撞盒中心。`BOTTOM = FRAME/2 + 14` 由画布尺寸推导，脚趾行的下缘恒等于 local +15 —— 改画布不会悄悄挪走脚底。这条由 `sprite_selftest` 第 3 组实测守住（偏差 −0.03 px）。
- 站立轮廓 **32×26**（首版 26×28）。用户反馈「细长」，但**扁只由高度承担**：碰撞盒高 30，美术高 26 时盒顶已经露出 4 px，再往下砍就是在骗玩家头顶还有空间。
- 宽度上限由关卡定：第一章最小可通行开口 40 px，全剪辑最宽 33 px（起步/刹车的挤压帧），两侧各留 3.5 px。`sprite_selftest` 里 `widest <= 36` 是硬线。
- 首版加宽是靠把穹顶撑方（`DOME_RX 0.45→0.52`），结果底边变平、左右下摆角消失，用户认不出是水母了。**正解是反过来收穹顶**（`DOME_RX=0.42 / DOME_CY=0.68`，底盘短轴 0.34→0.38）：最宽处落在下三分之一、底边往里收，两个下摆角重新外翻成圆弧 —— 扁和钟形不冲突，冲突的是「方」和「钟形」。

### A3 · 剪辑集只做控制器今天就能驱动的状态

| 剪辑 | 帧数 | fps | 循环 | 触发条件 |
|---|---|---|---|---|
| `idle` | 8 | 6 | 是 | 在地面、水平速度 ≤15。第 6~7 帧是眨眼 |
| `start` | 3 | 16 | 否 | 地面跑动状态的**进入**边沿，保持 0.19 s。流体滞后，上身往后甩 |
| `run` | 6 | 14 | 是 | 在地面、水平速度 >15。接触挤压→蹬地拉伸，全程带剪切式前倾 |
| `stop` | 3 | 16 | 否 | 地面跑动状态的**离开**边沿（仍在地上），保持 0.19 s。流体前涌，压扁往前扑 |
| `jump` | 2 | 12 | 否 | 离地且下落速度 ≤140。非循环 ⇒ 顶点滞空自动停在最后一帧 |
| `fall` | 3 | 8 | 是 | 下落速度 >140。伞状摊平 |
| `land` | 4 | 22 | 否 | `Player.landed` 且冲击速度 >260 |

优先级：`land > start > stop > run > idle`。起跳时三个保持窗一起清零，否则「刚起步就跳」会把 start 的窗口留到落地之后再放一次。

没做的：贴墙、游泳、被抓取（第二章内容，D11 已隔离）。

### A4 · 玩家动画豁免时停（实测）

`AnimatedSprite2D` 走场景树的 process delta，而项目从不碰 `Engine.time_scale`，所以世界冻住时史莱姆照样呼吸、照样眨眼 —— 这是「玩家不在时停范围内」最直观的一层可读性，反过来会变成机制说明。

实测证据（`sprite_selftest` 第 4 组）：按住方向键 ⇒ `TimeManager.is_time_frozen()` 为真、`elapsed_world_time` 逐帧不变，同时 `Sprite.frame` 从 0 走到 5。

### A5 · 接线不动 `player.gd`

`Sprite`（`AnimatedSprite2D` + `player_visual.gd`）挂在既有的 `$Visual` 节点下，`player.gd:_apply_horizontal()` 里那行 `_visual.scale.x = facing` 原样生效，M1 验过的手感代码零改动。状态选择全在 `player_visual.gd`，它只读 `is_on_floor()` / `velocity` 和 `jumped` / `landed` 两个信号，不参与任何物理。

### A6 · 落地强度驱动播放速度

`landed(fall_speed)` 的强度映射到 `speed_scale`（260→0.85，900→1.6），重砸更快更狠；冲击低于 260 px/s 的小跳**不播** land，否则每走一步都在拍地板。

### A7 · 行进方向用剪切，不用平移，也不用运行时变换

用户要「左右移动时体现流体向左右倾向」。两条实现结论：

- **`dome_lean` 是整条轮廓按高度做剪切**（脚底位移 0、头顶位移 `dome_lean`，按 k² 分布让下半身粘地），不是把上半身椭圆整体平移。平移会在腰侧顶出一个尖角，读起来像长了嘴；剪切才是「整团往下倒」。眼睛、嘴、高光都取各自高度上的同一个剪切位移，否则身体斜了脸还是正的，成了戴面具。
- **甩动全部烘进帧里**，靠既有的 `$Visual.scale.x = facing` 一翻就跟着翻，零运行时镜像逻辑。刻意没走运行时变换：Godot 4 的 `Node2D` 只暴露 position/rotation/scale，剪切（shear）拿不到属性入口，硬做要上 shader 或每帧改顶点，代价远超收益。
- 起步/刹车两段各 0.19 s 保持窗，是因为玩家从 0 加速到 260 只要 81 ms（`ground_friction 3200`），纯按速度挑剪辑的话甩动会在两三帧内被 run 抢走，等于没有。

### 已知缺口：会冲击 M3

M3 的时停灰滤镜是**读 screen texture 的全屏 ColorRect**（D8）。像素主角一旦上屏，会被连着一起去饱和 —— 而玩家恰恰是唯一不该变灰的东西。M3 动工时必须先解决这条（候选：把玩家放到独立 canvas layer，滤镜只采样世界层）。

### 复现与验收命令

```
py tools/gen_player_frames.py                       # 出帧 + clips.json + 三张预览（检视图 / 合成图 / GIF）
Godot_console.exe --headless --path . --import      # 让引擎导入新 PNG
Godot_console.exe --headless --path . --script res://tools/build_slime_frames.gd
Godot_console.exe --headless --path . res://tools/sprite_selftest.tscn   # 84 项断言，failures=0 才算过
```

坑记一笔：帧资源类在 4.x 里叫 **`SpriteFrames`**（文档标题写作 AnimatedSpriteFrames，ClassDB 里查不到那个名字），`AnimatedSprite2D` 的属性名是 **`sprite_frames`** 而不是 3.x 的 `frames`。

---

## 设计决策补录（2026-09-17）· 门控连线搬到构件上

### D20 · 按钮→门的连线写在门上（`Door.trigger`），不写在关卡脚本里

**动因**：用户报「按钮和门之间的连接建立在写死的场景代码上」。原来每个关卡都要抄一遍
`_button.pressed_changed.connect(...)` + `_door.set_open(pressed)`，摆图的人改个节点名就得回去改代码。

**结论：门持有触发源。** `Door` 上加 `trigger`，检查器里从场景树拖进去即可，编辑器同时画一条门→触发源的橙色辅助线（运行时不画，与触发带同一原则）。

四条理由与两条让步：

1. **方向选门持有源，不选按钮持有目标门列表。** 门是"我被谁开"这个问题的所有者；按钮保持纯感知件，不认识门。一个按钮开 N 扇门 = N 扇门上各填一次。
   - **让步一**：配漏一扇门不会报错。补偿是 `verify_kit` 现在会遍历关卡里每一扇门，要求它的 `trigger` 指得到一个发 `pressed_changed(bool)` 的节点，并且断言查到的门数 ≥ 2（防止这条检查哪天变成空转）。
2. **契约是信号，不是类型。** 导出项若写成 `ButtonPlate`，检查器更严，但 `SensorZone` 就永远接不上。所以 `Door` 只要求目标节点 `has_signal(&"pressed_changed")`，不满足时一次性 `push_warning` 并保持门严。
   - 顺带补上了 `SensorZone.pressed_changed(bool)`（按玩家进出计数，归零才发 false）。"走进一块区域门就开"以前必须写关卡脚本，今天拖属性就行 —— 这是这次真正新增的能力，不只是把代码挪个地方。
   - `AbilityAltar` 不发这个信号，因此不充当门的触发源：它的语义是"一次性给能力"，不是持续的开/关状态。
3. **SensorZone 刻意不学按钮的延迟松开。** 按钮 `_pending_unpress` 是为了面板别在时停里弹起来（画面自洽）；区域带子运行时不可见，而门收到关闭意图也只是停住不动，两者都不需要等时间恢复。实测覆盖在 `kit_selftest`：冻结中松开 → `is_open` 已翻 false 但 `_progress` 一帧不动 → 解冻后从停住处继续收。
4. **`trigger` 的类型必须是 `NodePath`，不能是 `Node`。** 实测（Godot 4.6.1）：给 `export(Node)` 的槽位在 `.tscn` 里写 `trigger = NodePath("../ButtonPlate")`，游戏进程 `instantiate()` 之后读回来仍是那个 NodePath（`typeof == 19`），**不会**被还原成节点引用；同一份文件在编辑器进程里也是原样挂着。改用 `@export_node_path var trigger: NodePath`，门自己在 `_ready()` 之后 `get_node_or_null()` 解析（相对路径要进树才解析得动）。
   - **这是摆图工具箱级的结论**：以后任何构件加"拖一个节点进来"的属性，都走 `@export_node_path` + 自己解析，别用 `export(Node)`。检查器照样给节点选择器、照样支持从场景树拖。

**让步二（需要你知情的那条）**：`level_template.gd` 原来明写「构件之间互不认识，全部靠关卡脚本连信号」。D20 是对它的有意让步 —— 构件之间第一次出现直接引用。换来的是摆图时零代码，代价是"这扇门被谁开"从脚本挪进了场景文件，而这正是编辑器里那条辅助线能看见的东西。旧的接线示例注释已同步改掉。

**验证**：`verify_kit` `doors=2 failures=0`；`kit_selftest` 新增 10 条断言（相对路径解析、按下即开、冻结中只记意图、解冻续收、换源断旧连接、SensorZone 当触发源）全部通过，`done failures=0`。

**同步改动**：`level_01_tutorial.gd` 删掉 `_door` 引用与 `set_open` 调用，只留 `[m2] plate=... presses=...` 读数（日志字段 `door_open` 随之去掉，两份文档里的日志说明已改）；引导关与模板的 `.tscn` 各写上一条 `trigger = NodePath("../ButtonPlate")`，所以复制模板开新关时示范接线是活的。

## 设计决策补录（2026-09-17）· 门不再挤人 + 主角流体感

### D21 · 关门压到玩家时**停在头顶**，不把他横弹出去

**现象**：站在门洞里不松手等门，门落下来会先把玩家往侧面弹一格。

**根因（不是手感问题，是引擎语义）**：门扇是 `StaticBody2D` 的矩形在逐帧变长。Godot 里 **StaticBody2D 改尺寸推不动任何 body** —— 那一下横弹是玩家自己下一帧 `move_and_slide()` 发现已经陷进门板后的脱困副产物。所以旧行为实际上是"先夹进板子里，再被吐出来"。

**结论**：门让位，而不是门推人。`_physics_process` 里算出本帧目标开度后，关门方向先过一道夹取：`_progress` 只允许走到"门底正好贴着玩家碰撞盒顶"那一格。

1. **不选"让门真能推人"那条路。** 要把门改成 `KinematicBody2D` 走位移平台那套也推不动 `CharacterBody2D`（角色之间的横推要靠对方自己的运动求解），换来的只是把 `_progress` 这个纯函数位置模型换成位移模型 —— 冻结即停、解冻续走就不再是算术性质。让位是唯一可靠解，且正是想要的表现。
2. **判据用形状查询，不给门加 `Area2D` 子节点。** 理由是不留重叠计数状态：玩家 `respawn()` 被瞬移走、门在冻结中、解冻续走这几条路径 Area2D 都要靠 entered/exited 补账，漏一次就永久卡在"被挡"标记上；查询无状态，每帧重新问一次物理世界。让位对象用碰撞掩码（`SQUEEZE_MASK = 2` 玩家层）表达，不引用 `Player` 类也不认组名。
3. **实测出来的两条引擎事实（Godot 4.6.1），这两条决定了为什么是一个方法里两次查询：**
   - `intersect_shape` 的命中字典只有 `rid/collider_id/collider/shape` 四个键，`shape` 还是**索引 int**；没有 `position`，`CollisionShape2D.get_global_rect()` 也不存在，`shape_find_owner()` 返回 owner id 而不是节点。**从命中里反推"被撞形状的顶在哪"这条路在 4.6 走不通。**
   - `cast_motion()` 返回 `PackedFloat32Array`（`[安全分数, 精确分数]`），问得出"我还能往下走多少"；但它对**恰好相切**和**已经重叠**都回报无碰撞（实测两种都返回 `1.0`），只用它的话门会先贴住头、下一帧照样越过去。
   - 所以：先用一条往下多探 `HOLD_MARGIN = 0.5 px` 的静止矩形查询把零位移接触按住（走不动就不动），再用 `cast_motion` 拿到亚帧级的贴头距离。引擎自带的接触边距实测只有约 0.08 px 且不保证保守（曾越过头顶 0.03 px），于是再手动留 `CONTACT_SLACK = 0.1 px`，把"绝不压过头"变成硬保证 —— 2 倍取景下这只值 0.2 屏幕像素。
4. **被挡时意图不变**：`_direction` 留在 `-1`，`is_blocked` 只是读数；玩家让开后下一帧自动续收到关严。期间按钮重新按下照常上行（上行不侵占空间，不查）。夹的仍然只是 `_progress`，所以"碰撞体 == 画出来的门扇"这条不变量在压住状态下也成立（自测里单独一条断言）。

**要你知情的两条后果**：

- 门现在**可以被玩家头顶住停在半开**，等于第一章多了一个天然门撑。不打算禁止："我头一顶门就停"本身就在教"移动=时停"（顶住要求站着不动，而站着不动时谜题时间在走），且不破坏任何通关路径。真要禁只有一条路：被挡 N 秒后硬收 —— 那就回到现在这个挤开的表现。
- 门底停在头顶留下的缝约 30 px，**小于**手册 §8 的"可通行缝隙 ≥ 40 px"。但玩家离开这条缝必然处在"移动中=时间冻结"，门不会追下来，所以 30 px 只是瞬时观感，不是可通行性要求。**§8 那个常数不改。**

**验证**：`kit_selftest` 第 5 组，11 条新断言 —— 门底不压过头顶、且停在头顶 0.3 px 内（证明不是悬着一帧行程）、`is_blocked` 挂上、玩家 x/y 一字未动、压住时门扇底边仍等于碰撞体底边、挡住之后不硬收、冻结中被头顶住的门照样不动、玩家让开后收到关严且 `is_blocked` 落下。`36 checks done failures=0`，另两条守门仍 `doors=2 failures=0` / `failures=0`。

**顺手记下但没动**：`MovingBlock` 是 `CharacterBody2D`，撞玩家时是**它自己停下**，所以不会挤人，但可能卡在玩家身上让行程对不上 —— 那是另一条死局风险，等真在关卡里用它挡路时再立决策。

### D22 · 主角底边切成波浪 + 按住下键贴地压扁（纯表现）

**动因**：用户报「最下面一长条横线看起来太棱角分明，或许有一点波浪状更像流体」；以及「按住下键且在地板上时，主角应该可以变得更扁……这个纯粹是为了加强画面表现」。确认口径：**只影响动画，不影响碰撞**；「落下的时候也会触发一次（压扁）也很合理」。

**结论**：

1. **波浪逐列切，不一刀切平。** 底边每列按 `lift(x) = amp/2·(1−cos(2π(x−offset)/λ))` 往上抬（λ=11 px，amp 1.6~3.0 按身高自动：站姿 1.9，越扁越凶，腾空拉长时收平）。**只上抬、绝不越过基线**，所以脚底对齐这条美术与碰撞的契约、以及轮廓高度，都不受波动影响 —— 自测第 8 组把这两条钉死（任何帧任何列不越基线行；idle 循环里至少一帧仍碰到基线行）。相位步长取 `λ/帧数`：一个循环正好走完一个波长，接缝处不跳波。亮边/底裙/脚趾全部改挂「逐列最低行」，底边涨落它们跟着涨落（旧版亮边用固定 dy 阈值，波浪一来就悬空了）。
2. **脸是无视轮廓直接盖章的，深压帧必须把脸收上去。** 眼/嘴画的时候不查 mask；h ≤ 15 的帧波浪会把 33 行往下全裁掉，所以这些帧 `eye_dy` 取负，让脸挂在永远裁不到的 32 行以上。`land[0]` 从 h=16 加深到 **h=12**：重落地（含蹲着落地）读作整团拍扁 —— 这就是"落下时也会触发一次"的载体，不需要给蹲伏再加空中分支。**压扁时眼睛跟着变扁**：新增独立参数 `eye_scale`（与眨眼用的 `eye_open` 分开），眼高 = `round(5·eye_open·eye_scale)` 下限 1 px —— 蹲伏进程 5px→3px→2px，蹲伏循环与 `land[0]` 都是 2px，起身回到 3px→5px。
3. **蹲伏三段剪辑：`crouch_in`(3f/16fps) → `crouch`(4f/6fps 循环) → `crouch_out`(2f/16fps)。** 状态机上蹲严格待在 idle 分支里：腾空、land、start/stop 窗口、跑动全部压过它；从蹲姿起跳清掉全部蹲伏窗口（不留残段）；按住下落地时 land 窗口压过蹲伏（先拍一帧扁的，再进蹲）。
4. **`move_down` 只喂动画。** 新动作（S/↓/十字键下/左摇杆下）镜像成 `Player.is_crouch_held`：不改碰撞盒、不减速、**绝不进 `notify_movement_intent`** —— 蹲着不该冻结世界（自测第 7 组专断：按住下键世界不冻、世界时间照走、位移为零）。`movement_input_handler` 照旧只听水平轴，一行没动。

**数字变化**：站姿轮廓实测 32×25（波浪削掉了固定的脚趾行，原 32×26）；全剪辑最宽 34 px（`land_0` 拍扁帧，原 33）—— 距 40 px 最小门洞还有 6 px，手册 §8 常数不动。

**验证**：`sprite_selftest` 37 → 51 条断言（三段蹲伏剪辑的帧数/循环、压扁进出、空中不蹲、蹲姿起跳、落地先 land 后蹲、不冻结、波形与基线），`failures=0`；另两条守门不变（kit `done failures=0`、verify `doors=2 failures=0`）。

## 设计决策补录（2026-09-17）· 贴墙一侧压平

### D23 · 推墙时把贴墙一侧压平到碰撞盒边界（`wall_press` 三段剪辑）

**动因**：用户报「玩家的左或者右边是墙的时候会有点穿模」，并提议此时自动播 `jump` 剪辑。

**根因（不是物理错位，是美术本来就比碰撞盒宽）**：碰撞盒 20 宽（半宽 10），帧原点 = 画布中心 = 盒中心。逐帧量 38 张 PNG 的不透明像素极值，轮廓从中心往外伸的距离（后侧 / 前侧，前 = `facing` 方向）：

| 剪辑 | 后侧 | 前侧 | 墙侧越界 |
|---|---|---|---|
| idle | 16 | 16 | 6 |
| run | 14 | **19** | **9** |
| start | **18** | 17 | 8（后侧） |
| stop | 15 | **19** | **9** |
| jump | **10** | **12** | 0 / 2 |
| fall | 16 | 16 | 6 |
| land | 17 | 17 | 7 |
| crouch_in / crouch / crouch_out | 16~17 | 16~17 | 6~7 |

所以站着贴墙越界 6 px，而**推墙跑与松手刹车那 0.19 s 越界 9 px** —— `lean=2.0 + dome_lean=5.0` 把整团往前甩，正好甩进墙里。`jump` 是唯一塞得进盒内的剪辑。

**为什么不直接复用 `jump`**（用户原案，方向对，但四处不合算）：

1. **脚底浮 1 px。** jump 两帧下缘在中心下方 14，所有贴地剪辑都是 15。站地上播它脚底与地面之间有一条缝，破的正是 D22 花力气守住的「只上抬、绝不越过基线」契约（自测第 8 组会红）。
2. **头顶超盒顶 1 px。** jump 上缘伸到中心上方 16，盒顶是 15。3.x 里那条原则是「美术高不能超盒高，否则在骗玩家头顶还有空间」，这里是反向骗：显得比实际高。
3. **读起来像蹬墙爬。** jump 是腾空拉伸姿，贴墙播会被当成能力预告 —— 第一章没有蹬墙跳，D11 明确不给第二章机制留视觉暗示。
4. **没归零。** facing 朝墙那一侧 jump 仍伸 12，越界 6 → 2。

**结论：新增 `wall_press` 三段剪辑，只把贴墙一侧压平到盒边界，体积往背面与上方挤。**

1. **只切一侧，不收窄整体。** 两侧都收到 ±10 会得到 20×28 的柱子 —— 正是用户否决过的「细长」。单侧切 + 背面外鼓才保住钟形：自由侧的穹顶弧线与外翻下摆一个像素都不动，读作「流体贴面铺开」而不是「变瘦了」。
2. **新参数 `wall_clip`，切线钉在画布上而不是钉在 `cx` 上。** 切在 `FRAME/2 + wall_clip` 这一列（正 = 前/右侧，`wall_clip=0` 表示关闭）。与 `lean` 解耦：`lean` 负责把整团往墙里送或往背面拽，切线始终等于碰撞盒边界，一个参数只管一件事。`wall_clip=10` 时墙侧最外不透明列恰为 31，越界 = 0。帧一律按「朝右、墙在右侧」作画，镜像沿用现成的 `_visual.scale.x = facing`，不需要第二套帧。
3. **接触面不是刀切直线，上下两端各让开约 1 px（`taper`）。** 竖切椭圆得到两个直角，读作「被遮罩切掉一块」；按身高比例 `k=(BOTTOM-y)/L` 做 `taper*(1-sin(πk))`，中段最贴、两端收，才是液面贴壁的弯月面。
4. **体积守恒靠 h 与背面 w 补。** 切掉 6 px 宽约损失两成面积，补偿是 h 25 → 26/27（沿墙往上爬一点）+ w 31 → 33/34（背面外鼓）。h 的硬上限是 30（= 盒高），且最高点不得超过中心上方 15。脚趾挂在「逐列最低行」上，被切掉的列自动不画，无需特判。
5. **三段结构与蹲伏同构**：`wall_press_in`(2f/18fps) → `wall_press`(2f/6fps 循环，缓慢往上爬) → `wall_press_out`(2f/16fps)。`PlayerVisual` 里照 `_track_crouch()` 抄一份 `_track_wall_press()`，**含同一条守卫：离地即释放且不设 out 窗口**（`elif is_on_floor()` 那一支），否则跳到墙边落地会补播一段莫名的压平。
6. **触发源：`Player` 新增只读 `wall_press_dir`（0 / ±1），在 `move_and_slide()` 之后算。** 判据 = `is_on_floor()` 且 `is_on_wall()` 且**墙侧与输入轴同号**；墙侧取 `-sign(get_slide_collision(i).get_normal().x)`。只认「主动推墙」，不做「站在墙边」的侧向探测 —— 理由见后果一。`PlayerVisual` 照旧只读不碰物理。
7. **优先级**：`land` > `wall_press_in/wall_press` > `wall_press_out` > `start` > `stop` > `run` > 蹲伏 > `idle`。压平必须压过 `stop`：接触瞬间 `velocity.x` 被 `move_and_slide()` 削成 ~0，`_track_slosh()` 判定「跑动→停」并放 0.19 s 的 `stop`，而 `stop` 前伸 19 是最脏的一帧。松手那侧不用额外压制：释放时玩家从 0 加速，触发的是 `start`（后仰，后侧伸 18），由 `wall_press_out` 盖过它。
8. **不与蹲伏叠加。** 同时按下 + 推墙时压平优先，蹲伏窗口照旧计时但不出画。要做「蹲着贴墙」得再出一套帧，第一章不做。

**要你知情的三条后果**：

- **一：站在墙边不推，6 px 越界仍在。** 这是「美术比碰撞盒宽 60%」的固有代价。要彻底消掉只有两条路，都比 6 px 更贵：侧向探测常开（于是贴墙站着的默认观感变成窄身形，而窄身形正是被否决过的「细长」）；或让地形盖住玩家（改全局 z 序，现序是 Terrain → Triggers → Player → Objects 且 `door.z_index=-10`，改完玩家从此不可能出现在地形前面，观感也从「贴住」变成「被切掉一块」）。
- **二：松手瞬间回弹到全宽，而此时人还贴着墙。** 读作弹性流体从墙上弹回来，2 帧 / 0.125 s 内完成，之后落到后果一的静态 6 px。
- **三：腾空推墙不压平。** `wall_press` 只在 `is_on_floor()` 下生效（与蹲伏同一条守卫）。跳起来贴墙滑下来那段仍是 fall 的 6 px。要做需要一套腾空版帧（脚底不触基线、上缘仍不得超盒顶），等有人报再立决策。

**数字变化**：新增 6 帧，PNG 38 → 44 张。`build_slime_frames.gd` **一行不改** —— 它整份读 `clips.json`，剪辑是数据驱动的。出帧后实测（L/R = 轮廓从画布中心往后侧/前侧伸的距离，盒半宽 10）：

| 帧 | L | R | 总宽 | 上缘超盒顶 |
|---|---|---|---|---|
| `wall_press_in_0` | 17 | **10** | 27 | −7 |
| `wall_press_in_1` | 16 | **10** | 26 | −4 |
| `wall_press_0` | 16 | **10** | 26 | −3 |
| `wall_press_1` | 15 | **10** | 25 | −1 |
| `wall_press_out_0` | 18 | **10** | 28 | −4 |
| `wall_press_out_1` | 17 | 14 | 31 | −4 |

墙侧越界 9 → **0**（前 5 帧 R 恰为 10.0，切线钉在盒边界上）；背面外鼓到 15~18，那 5~8 px 甩在没有墙的一侧，无害。总宽 25~28 比站姿 32 窄，但**窄只发生在被切的那一侧**，自由侧的穹顶弧线与外翻下摆没动。全剪辑最宽仍是 34 px（`land_0` / `crouch_in_2` / `crouch_out_0`），手册 §8 常数不动。

**验证**：`sprite_selftest` 第 1 组 `expected` 表加三条（帧数/循环），另新增第 9 组：

- **几何三条**：压平段（`wall_press_in` 全部帧、`wall_press` 全部帧、`wall_press_out` 首帧）墙侧不透明列 ≤ 31，越界 = 0 —— 这是本决策的全部目的；`wall_press_out` **末帧刻意排除**，它的 `wall_clip` 归零、实测 R=14，那就是后果二的回弹帧，断言它比盒宽反而是对的；每段至少一帧的底边触基线行 36 且无一帧越过其下（沿用第 8 组对 idle 的同一条契约 —— 底边最低行在 35/36 间交替是**所有**贴地剪辑的既有特性，波形相位与脚趾列错位所致，`idle` 的 0/1/7 帧同样是 35，所以不能说"每帧都触线"；`jump` 的特殊之处是两帧都为 35、从不触线）；每帧上缘不超盒顶（中心上方 ≤ 15，实测最深 14）。
- **状态机五条**：推墙 → `wall_press_in`；窗口过 → `wall_press`；推墙期间世界仍处于冻结（压平是水平输入的产物，断言冻结判定没被新状态搅动）；松手 → `wall_press_out` → `idle`；离地即释放且落地不补播 out。
- **自测世界要新加一面墙**：现有 `_build_world()` 只有 4000×40 的地板。墙建在 x≈600，且在第 9 组里才把玩家挪过去 —— 不能立在起跑路径上，否则第 4 组的跑动/甩动断言会先撞墙。

**结果**：第 9 组新增 23 条断言，`SPRITE SELFTEST DONE failures=0`（合计 84 条；第 1~8 组 61 条未动）。另两条守门照旧：`kit_selftest` `done failures=0`、`verify_kit` `doors=2 failures=0`。`build_slime_frames.gd` 未改一行，出 13 段剪辑 `failures=0`。接触发生在按住方向键后第 8 帧，推墙期间 x 恒定 590.0（墙面前 10 px = 盒边界），世界全程处于冻结。（订正：D22 记的「37 → 51 条」与开工前实测的 55 条不符 —— 期间有改动没回写文档，条数以实测为准。）

### D24 · 瓦片地图落地：AB 混搭 + 16 px 格 + TileMapLayer 管碰撞

**动因**：灰盒占位块要换成「比较明亮的实验室风格」。`tools/gen_tiles.py` 先出三套同构图预览（A 洁净白瓷 / B 冷调金属舱 / C 暖调复古）供肉眼选型；用户选定 **A 的墙 + B 的地面**，瓦片 **16 px**，地形碰撞归 **TileMapLayer**。

**结论**：

1. **风格 AB**：背景墙 = A 的白瓷小方砖（`ceramic`），地形 / 天花 / 侧墙 = B 的铆钉钢板（`plate`）—— 结构是钢、贴面是瓷，读作「钢壳里的洁净室」。点缀色分两家：A 的青给玻璃 / 灯 / LED，B 的琥珀给警示条（白墙上比 A 原来的绿条更「机器」）；金属件取 B 的深一档钢色，A 的浅钢在白墙上太飘。选型图 `assets/tiles/preview_room_ab.png`。
2. **可读性铁律（改任何配色都要过这三条）**：背景墙亮、地形是中明度固体、踏面 = 1 px 最亮 + 2 px 次亮 + 1 px 暗分隔线 —— 「能不能站」只认那条暗线。装饰层对比度必须低于地形，否则眼睛分不清什么能站。坑道内部比地面再暗一档（那是洞）。第一版预览就是死在第一条上（地形与墙同明度，地面像浮在墙上），返工记录在 `gen_tiles.py` 的调色板注释里。
3. **16 px 瓦片，设计网格 32 px = 2 格不变**：手册 §8 的所有尺寸继续有效；40 px 最小可通行缝隙在瓦片世界 = 3 格 = 48 px。选 32 px 会让最小缝被迫 64 px、主角只有一格高，否。
4. **三层 TileMapLayer 共用一个 TileSet**：`WallFill`（瓷面填充，无碰撞，z=-30）→ `Decor`（带 alpha 的装饰，无碰撞，z=-20）→ `Tiles`（钢板，z=0；名字避开已有的 `Terrain` 容器节点）。碰撞写在 **TileSet 物理层 0**（`collision_layer=1, mask=0`）—— 4.6 的 TileMapLayer 节点上没有 layer/mask 旋钮，只有 `collision_enabled`，所以「哪层有碰撞」实际由「哪个源带碰撞多边形」决定：只有地形源带。旧 `platform.tscn` 实例继续可用（同在 terrain 层），**旧关不迁移**，新关刷瓦片。
5. **地形走 4-side autotiling（`MATCH_SIDES`）**：16 个邻居组合 = 16 张图，cap / 竖面由「哪一侧没有邻居」决定，与预览的 `mass()` 同一套逻辑；角部由「踏面后画盖住竖面」得到。**16 张的物理形状一律是整格矩形** —— 踏面与竖面只是美术，碰撞永远是整格，D23 那类「美术比碰撞宽」的错位在构造上不可能出现。
6. **美术-碰撞契约（新守门）**：顶面开放的 terrain tile，不透明像素必须从第 0 行开始且暗分隔线落在第 3 行（碰撞顶边往下 4 px 内）；侧面开放的同理 4 px 内。`tileset_selftest` 逐张量，和主角的脚底基线契约同一条思路。
7. **装饰是带真 alpha 的大块 tile**（窗 6×4 格、监视器 3×2 格、灯 6×1 格……），光晕用 alpha 叠而不是平涂混色；预览与引擎走同一条 RGBA 合成路径，预览所见即引擎所得。
8. **管线照 `build_slime_frames.gd` 的套路**：`py tools/gen_tiles.py` 出 `tilesheet_terrain.png`（64×64）+ `tilesheet_decor.png`（256×256）+ `tiles.json`（16 个邻居掩码 + 装饰矩形表）+ 四张风格预览 → `--import` → `tools/build_tileset.gd` 读 json 建 TileSet 存 `assets/tiles/lab_tileset.tres`（序列化格式跟引擎版本走，让引擎自己写）。
9. **构件皮肤延后（D25+）**：门 / 按钮 / 祭坛 / 移动方块仍是占位色。已知两处弱对比记入待办、不阻塞瓦片：钢灰移动方块在钢板地面上发闷、赭红门在白墙上偏沉。
10. **冻结滤镜（M3）的附带收益**：AB 的身份靠明度结构撑，去饱和后仍可读；C 那套靠暖色相撑的会塌成米灰 —— 这是没选 C 的第二条理由（第一条是用户没选它）。

**验证计划**：新增 `tools/tileset_selftest.gd` —— 图集边长是 16 的倍数、16 张地形 tile 各带一个整格物理多边形、装饰 tile 零物理、模板里三层的 layer/mask/z 序、第 6 条的 4 px 契约、装饰图集 alpha 非空。三条现有守门不变。

**结果**：`tileset_selftest` 284 条断言 `failures=0`（16 格各 1 块整格碰撞、64 条 peering bit、4 px 契约逐格量图集像素、装饰零碰撞且 alpha 非空、模板三层 z 序与共用 TileSet，外加一组「让 Godot 自己的 terrain 求解器刷一块 5×3 实心、读回每格选中的图集坐标」—— 预览图用的是生成器自己的掩码逻辑，验不到 peering bit 方向接反，这一组才验得到）。三条旧守门照旧：`verify_kit` `doors=2 failures=0`、`kit_selftest` `done failures=0`、`sprite_selftest` 84 条 `failures=0`。管线实测：`py tools/gen_tiles.py` → `--import` → `build_tileset.gd` 打印 `terrain: 16 格 / decor: 12 块 / saved ... err=0 failures=0`。两处实现期订正：装饰矩形的宽高必须是 16 的整数倍（TileMapLayer 只能整格放，4.6 也没有单独设取图区域的接口），灯与管道因此从 10 px 厚改成「16 px 格内画、其余留透明」；第 4 条的 layer/mask 在 TileSet 物理层上而非节点上（节点只有 `collision_enabled`）。预览图改由图集逐格拼出（`render_room` 与引擎同一条 RGBA 合成路径），选型图里那套按整块 mass 画的画法已删。
