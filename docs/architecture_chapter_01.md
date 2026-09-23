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

**订正（D46，2026-09-21）**：第 2 条建议（M3 升级为 **shader 去饱和版**）已被取代 —— 落地的是 CRT 版，而且它**一点都不去饱和**（不碰饱和度，只做扫描线晶格 + 1.3 提亮 + 红蓝色散）。第 3 条「两版对外接口一致、升级只换内部实现、不动关卡」原样兑现：`state_changed` 订阅、`LAYER_INDEX = 100`、真实 delta 的指数平滑淡入都还在老位置，关卡一行没改。当年挂着的那句「`hint_screen_texture` 在 Compatibility 渲染器下需实测确认」现在有答案：**能编译**（4.6.1 stable / GLES3 Compatibility / RTX 5070 Laptop，见 D46 验证段）。

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
| `player.gd` | `class_name Player extends CharacterBody2D` | 平台跳跃手感 | `respawn()`、`landed`、`jumped`、`movement_locked`（D41）、`@export` 手感参数组 | 不查 `TimeManager`（永久豁免）；不管能力解锁；`movement_locked` 只掐水平输入与起跳，不掐冻结意图 |
| `player_camera.gd` | `class_name PlayerCamera extends Camera2D` | 跟随 + 平滑 + 前瞻 + limits | `@export` 平滑/前瞻/limits | 不查 `TimeManager` |
| `main.gd` | `class_name Main extends Node` | 关卡换入换出、R 键重开、死亡重载、`run_state` 持有（D31 同关内粘性状态）、暂停协调 | `load_level(path)`、`restart_level()`、`reload_level()`、`get_run_state()` | 不含谜题逻辑 |
| `level_base.gd` | `class_name LevelBase extends Node2D` | 关卡基类：编排下沉（D28 祭坛/终点）+ 危险物/存档点自动接线（D38）+ `run_state` 回灌与死亡重载（D31） | `restart_level()`、`_begin_ability_sequence()` / `_on_ability_enabled()` 覆写钩子 | 不含谜题逻辑 |
| `button_plate.gd` | `class_name ButtonPlate extends Area2D` | 踩踏检测 + FROZEN 期间延迟松开 | `pressed_changed(bool)`、`pending_unpress` | 不直接操作门（发信号，关卡/门自己连） |
| `door.gd` | `class_name Door extends StaticBody2D` | 升降 + 时停冻结动画帧 | `set_open(bool)`、`speed_scale` 门控 | 不用 Tween（原文明令禁止）；不用 `seek()` |
| `pendulum.gd` | `class_name Pendulum extends Node2D` | 正弦摆动，累加相位 | `@export period/amplitude` | 无碰撞体（D7） |
| `moving_block.gd` | `class_name MovingBlock extends CharacterBody2D` | 双点巡逻 + 冻结时零速并跳过 `move_and_slide()` | `@export path_a/path_b/speed` | 不推挤玩家 |
| `ability_altar.gd` | `class_name AbilityAltar extends Area2D` | 一次性触发能力授予演出 | `ability_granted` | 不直接改 `TimeManager`（发信号由关卡编排） |
| `time_freeze_filter.gd` | `class_name ... extends CanvasLayer` | 灰度反馈视觉 | 订阅 `state_changed` | 不判定状态；`mouse_filter = IGNORE` |
| `debug_overlay.gd` | `class_name ... extends CanvasLayer` | 开发期诊断 | 枚举 `time_receiver` 分组 | 仅 `OS.is_debug_build()` 可见 |
| `hazard_base.gd` | `class_name HazardBase extends Area2D` | 危险物基类：每物理帧扫描重叠、接触即判 | `touched_player(player)`、`is_live()` | 接触判定不吃世界 delta（D38）；不决定「死」（发信号，LevelBase 接）；不做视觉 |
| `spikes.gd` | `class_name Spikes extends HazardBase` | 常开尖刺地形，判死盒只罩画出来的牙 | `length` | 无相位、不挡路；贴顶倒刺 = rotation 180，不吃代码 |
| `electric_bar.gd` | `class_name ElectricBar extends HazardBase` | 周期通断电棒，相位为世界时间的纯函数 | `length`、`period`、`duty`、`phase`、`blocks_when_live` | 相位钟走 TimeReceiver（D35）；不做来回滑动的电（§8） |
| `key_pickup.gd` | `class_name KeyPickup extends Area2D` | 一次性能量卡，拾取后画成含在玩家体内（D39）；被门取走时向上飞出并淡化（D41） | `held`、`is_held()`、`consume(fly_time)`、`fly_progress()` | 不 re-parent 到玩家（跟随走豁免通道，D30 第 4 条）；飞出**计时**走固定物理步长与门同一条钟（D41）；不进 run_state |
| `key_door.gd` | `class_name KeyDoor extends StaticBody2D` | 刷卡门：读卡 → 锁住玩家移动 → 光幕自上而下逐行熄灭一拍 → 演完才让行并解锁（D41） | `key`、`swipe_time`、`is_latched`、`curtain_rect()` | 不复用 `Door`（D36 结构差）；无关门方向，挤压类 bug 结构性消失；演出与扫描都不吃世界 delta（D40），不挂 `TimeReceiver` |
| `checkpoint.gd` | `class_name Checkpoint extends Area2D` | 一次性存档点，踩上即存 | `checkpoint_reached(position)` | 不持有跨重载状态（run_state 住 Main，D31） |
| `tile_draw.gd` | `class_name TileDraw extends RefCounted` | 零件 PNG 无缝平铺的公共画法 | 静态 `TileDraw.tile()` | 无状态、不进场景树 |

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

M5 危险与推进构件（全部 @tool；受时停的只有电棒与刷卡门，其余三个无时间驱动过程，不挂 TimeReceiver）：

```
spikes.tscn
Spikes (Area2D, layer 0 / mask 2)              spikes.gd
└── CollisionShape2D (length × 14, 带心 -7)     ← 判死盒只罩画出来的牙

electric_bar.tscn
ElectricBar (Area2D, layer 0 / mask 2)         electric_bar.gd
├── CollisionShape2D (length × 10, 带心 0)      ← 判死盒只罩光束带，极柱不咬人
├── TimeReceiver (Node)                         ← 相位钟的门控 delta
└── Blocker (StaticBody2D, layer 4 ↔ 0)        ← blocks_when_live 且通电才上层
    └── BlockerShape ((length+20) × 18)

key_pickup.tscn / checkpoint.tscn
KeyPickup / Checkpoint (Area2D, layer 8 / mask 2)   ← 纯传感器，与按钮同族
└── CollisionShape2D (32 × 24, 带心 -15)

key_door.tscn
KeyDoor (StaticBody2D, layer 4 / mask 0)       key_door.gd
├── CollisionShape2D (width × height·(1-p))     ← 只缩不涨，初始全高
├── TimeReceiver (Node)                         ← 消散进度的门控 delta
└── Reader (Area2D, layer 0 / mask 2)           ← 读卡感应带 (width+2·reach × 40, 带心 -15)
    └── ReaderShape
```

---

## 6. 物理层、分组、约定

**碰撞层**（第一章够用即可，不过度预留；与手册 §4 同一张表，数值为位值）：

| 位值 | 名称 | 使用者 |
|---|---|---|
| 1 | `terrain` | Platform、静态墙体、`Tiles` 层（TileSet 物理层 0） |
| 2 | `player` | Player |
| 4 | `time_solid` | MovingBlock、Door、KeyDoor、ElectricBar 的 Blocker（通电且 `blocks_when_live` 时） |
| 8 | `sensor` | ButtonPlate、AbilityAltar、SensorZone、KeyPickup、Checkpoint（`monitoring` mask 2） |

危险物判死区（Spikes / ElectricBar / KeyDoor 的 Reader）**不在任何层上**：`layer = 0`、`mask = 2`、`monitorable = false` —— 上 sensor 层会被玩家的起身净空查询读漏（D29 与 D27 交叉核对）。Player `mask = 5`（terrain + time_solid）。

**分组**：
- `time_receiver` — 所有 `TimeReceiver` 在 `_ready()` 自注册，`DebugOverlay` 枚举它
- `player` — 相机区域、机关查找玩家用

**节点/文件命名**：目录与文件 snake_case，`class_name` PascalCase，autoload 单例不写 `class_name`（D10）。

**视觉**：地形走瓦片图集（D26 风格 `g`），机关立绘走 `assets/props/` 零件 PNG 平铺（D25，`tools/gen_props.py` 出）；世界空间以左上角为原点、按 **32px 网格**摆放，便于灰盒阶段直接换算「5~6 个身位」这类布局要求（原文 3.3）。

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

### M5 · 危险与推进（D32 立项，2026-09-20 实装）
**交付**：`hazard_base.gd`、`spikes/`、`electric_bar/`、`key_pickup/`、`key_door/`、`checkpoint/`（5 个 tscn、6 个脚本，D36 范围订正后）、`components/tile_draw.gd`、`Main.run_state` + `LevelBase` 回灌与死亡重载、`tools/gen_props.py` 危险物/钥匙/存档点零件（选型图 `preview_m5.png`）、`verify_kit` / `kit_selftest` 扩充
**验收挂钩**：
- 「冻住的通电棒仍伤人」→ D38 接触即判：kit_selftest 冻结中把玩家传进恒通电棒，`touched_player` 恰发一次
- 「玩家移动期间相位一分不动」→ D35：相位钟走 TimeReceiver 门控 delta，冻结即钉住
- 「复活失去并重置钥匙」→ D30/D31：钥匙状态住在 KeyPickup 实例上，重载即归位，`run_state` 不存钥匙条目
- 「重生后能力不丢、用过的祭坛不复活」→ run_state 回灌组断言：出生点换到存档点、`is_ability_enabled` 为真、祭坛 `mark_spent()` 只换装不重播演出
**实现与 D31 的一处偏差**：`run_state` 实存两条 `{respawn_position, altar_spent}`，粘性表里的 `ability_granted` 不单独存 —— 能力开启由 `altar_spent` 推导。两个布尔若各自存一份，漂移（一真一假）会直接软锁，一份真相没有这个问题。
**状态（2026-09-20）**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。另有一条实测订正：`--script` 模式下 autoload 在首帧 `_process` 已就位（旧注释「autoload 不一定在」是错的），电棒与刷卡门因此得以进 `verify_kit` 第二阶段的真树验派生几何。

---

## 8. 明确不在本次范围

- 锚点同步系统（1.2，第二章）——仅保留 `TimeReceiver.set_time_source()` 空接口，全章无任何调用方
- 敌人、追逐战、任何动态压力源（3.8）
- 教程弹窗、按键提示图等文字 UI（3.8）
- 持久存档（写盘的存档系统）、关卡选择、主菜单 —— D32 只引入**关卡内重生点**（内存内，`run_state` 挂在 Main），`user://` 仍然零引用
- ~~死亡与重生：第一章可能根本没有致死要素~~ → **D32 改范围**：致死要素由危险物构件引入（见 D38、D29~D31），新立 M5 承载。原句里「不引入**动态**压力源」的判据仍然有效：尖刺与电流棒都是静物或定周期物，不追人、不因玩家改变行为；敌人与追逐战继续排除
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

> **2026-09-19 订正**：「start/stop 窗口、跑动全部压过它」已被 **D27 第 10 条**改成反过来 —— 蹲伏压过跑动与甩动。其余（腾空、land 压过蹲伏）不变。
4. **`move_down` 只喂动画。** 新动作（S/↓/十字键下/左摇杆下）镜像成 `Player.is_crouch_held`：不改碰撞盒、不减速、**绝不进 `notify_movement_intent`** —— 蹲着不该冻结世界（自测第 7 组专断：按住下键世界不冻、世界时间照走、位移为零）。`movement_input_handler` 照旧只听水平轴，一行没动。

> **2026-09-19 半条作废**：「不改碰撞盒」由 **D27** 推翻 —— 碰撞盒现在跟着缩到 15 px。「不减速」与「不冻结世界」两条不变。

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
7. **优先级**：`land` > `wall_press_in/wall_press` > `wall_press_out` > `start` > `stop` > `run` > 蹲伏 > `idle`。（2026-09-19 订正：**D27 之后蹲伏升到 `wall_press_out` 之下、`start` 之上**，压过跑动与甩动。压平与蹲伏的先后不变 —— 压平仍然优先。）压平必须压过 `stop`：接触瞬间 `velocity.x` 被 `move_and_slide()` 削成 ~0，`_track_slosh()` 判定「跑动→停」并放 0.19 s 的 `stop`，而 `stop` 前伸 19 是最脏的一帧。松手那侧不用额外压制：释放时玩家从 0 加速，触发的是 `start`（后仰，后侧伸 18），由 `wall_press_out` 盖过它。
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
9. **构件皮肤延后（D25+）**：门 / 按钮 / 祭坛 / 移动方块仍是占位色。已知两处弱对比记入待办、不阻塞瓦片：钢灰移动方块在钢板地面上发闷、赭红门在白墙上偏沉。（订正：这条已由 D25 结清；而「白墙」这个前提被 D26 换掉了，那两条对比数的参照物已不存在，别照着它去调门色。）
10. **冻结滤镜（M3）的附带收益**：AB 的身份靠明度结构撑，去饱和后仍可读；C 那套靠暖色相撑的会塌成米灰 —— 这是没选 C 的第二条理由（第一条是用户没选它）。

**验证计划**：新增 `tools/tileset_selftest.gd` —— 图集边长是 16 的倍数、16 张地形 tile 各带一个整格物理多边形、装饰 tile 零物理、模板里三层的 layer/mask/z 序、第 6 条的 4 px 契约、装饰图集 alpha 非空。三条现有守门不变。

**结果**：`tileset_selftest` 284 条断言 `failures=0`（16 格各 1 块整格碰撞、64 条 peering bit、4 px 契约逐格量图集像素、装饰零碰撞且 alpha 非空、模板三层 z 序与共用 TileSet，外加一组「让 Godot 自己的 terrain 求解器刷一块 5×3 实心、读回每格选中的图集坐标」—— 预览图用的是生成器自己的掩码逻辑，验不到 peering bit 方向接反，这一组才验得到）。三条旧守门照旧：`verify_kit` `doors=2 failures=0`、`kit_selftest` `done failures=0`、`sprite_selftest` 84 条 `failures=0`。管线实测：`py tools/gen_tiles.py` → `--import` → `build_tileset.gd` 打印 `terrain: 16 格 / decor: 12 块 / saved ... err=0 failures=0`。两处实现期订正：装饰矩形的宽高必须是 16 的整数倍（TileMapLayer 只能整格放，4.6 也没有单独设取图区域的接口），灯与管道因此从 10 px 厚改成「16 px 格内画、其余留透明」；第 4 条的 layer/mask 在 TileSet 物理层上而非节点上（节点只有 `collision_enabled`）。预览图改由图集逐格拼出（`render_room` 与引擎同一条 RGBA 合成路径），选型图里那套按整块 mass 画的画法已删。

## 美术决策补录（2026-09-18）· 门与按钮的立绘

### D25 · 门 / 按钮换成立绘：无缝平铺零件 + 固定调色板，删掉逐实例调色

**动因**：D24 第 9 条挂的账 —— 门和按钮还是检查器里手填的占位色块。选型图 `assets/props/preview_props.png`（`py tools/gen_props.py`）由门的两套候选（M1 中钢卷帘 / M2 深钢卷帘）× 按钮两套候选（B1 琥珀面 / B2 青面）拼成，都叠在**真瓦片图集**的房子剖面上看，不看色卡。用户定 **M2 + B1**：明度上和白墙、钢地都拉开了，M3 去饱和后仍靠明度读得出来；琥珀归「机器 / 危险」一家、青归「灯 / 玻璃」一家，与 D24 第 1 条的点缀色分工一致。

**结论**：

1. **立绘拆成 8 个小零件，不是一整张纹理**：卷帘板 16×8、底边警示条 16×8、门柱 4×16、门楣 16×12、门楣端帽 4×12 一对、按钮踩面 16×8、按钮钢座 16×8。理由和 D24 的装饰同源但更硬：门扇可见高度 = `height * (1 - 开度)` 是**逐帧在变**的量，而 `width` / `height` / 按钮 `width` 都是导出项、摆图的人一定会改；整张纹理要么拉伸变形要么尺寸写死。构件 `_draw()` 按当前开度与尺寸平铺这些零件。
2. **16 px 自洽规矩从瓦片搬到构件**：横向零件的图案周期整除 16、纵向同理，平铺时缝、铆钉、斜条都对得上。这条不是审美约定，是有守门断言的契约（见第 6 条）。
3. **调色板固定成一套，删掉 `Door.panel_color` 与 `ButtonPlate.plate_color` 两个导出项**。这是本决策唯一减少摆图自由度的地方，理由：门与按钮的明度对比是**对着白墙和钢地量出来的**，不是偏好 —— 逐实例调色等于把「这扇门看不看得见」交给摆图时的一次拖动。代价知情：想让玩家手里那扇门换个颜色，第一章只能改代码里的调色板。其余构件（`platform.color`、`moving_block.block_color`、`ability_altar.active_color`、`pendulum` 两个色、`sensor_zone.zone_color`）的调色旋钮都还在。
4. **状态用灯表达，不新增动画**：门楣青 LED 亮 = 开，按钮前唇中央青灯亮 = 踩下。门的开合本身已经是读得动的动画，按钮的「沉进凹槽」由第 5 条的几何给出，不需要第三个通道。
5. **按钮凹槽只有 8 px 深**，`press_depth` 超过 8 的部分画面夹住（`_draw` 里钳制），不是无限下沉。
6. **管线与同源契约**：`py tools/gen_props.py` 出选型图 → 定稿后 `py tools/gen_props.py --emit` 落 8 张 PNG + `assets/props/props.json`（零件尺寸清单 + 四个灯色）→ 构件 `preload` 那些路径 → `verify_kit` 复核。**`verify_kit` 新增 `_verify_props()` 三类断言**：零件实际像素尺寸与清单一致（漏跑 `--emit` 直接 FAIL）；三条平铺自洽契约 —— `door_slat` 缝行必须比高光明（否则卷帘平铺出亮带）、`door_bottom` 必须是琥珀且斜条有明暗（否则门底读不出）、`button_base` 前唇必须比凹槽亮（否则「踩下」读不出）；四个灯色与构件脚本常量一对一 —— `Door.LED_SOCKET/LED_LIT`、`ButtonPlate.END_SHADE/SOCKET/LED_LIT` 各自等于 `props.json` 里那一项，**谁单独改谁在这里响**。取常量用 `get_script_constant_map()`，避免 `verify_kit` 在编译期依赖引用了 autoload 的构件脚本。
7. **`props.json` 里两类字段性质不同**（踩过的坑，写下来）：`door_body: "deep"` 与 `button_face: "accent2"` 是**指向调色板的别名**（字符串，不是颜色），实测时直接拿它当 RGB 三元组会 `TypeError`；`led_socket` / `led_lit` / `button_socket` / `end_shade` 才是**落盘的字面色**。前者随 `STYLES["ab"]` 走，后者是 `--emit` 当刻算出来的常量。

**要知情的后果**：

- **构件停在 AB 那一套配色，而地图在 D26 之后换成了暗底**。门板、移动方块、按钮钢座对现在的墙对比只有 1.06 ~ 1.39（数字见 D26）。这组数字我给过用户并提议换皮，用户判「画风已融合，不用修改」—— 所以这是**被接受的状态，不是待修 bug**，别拿它再劝一轮。真要动，改的是 `gen_props.py` 里 `p = G.STYLES["ab"]` 那一处（两处），加上把别名改成逐风格字面色。
- 移动方块与祭坛**没**走 D25 的零件管线，仍是 `_draw()` 画的色块。

**结果**：`verify_kit` 加 `_verify_props()` 后 `doors=2 failures=0`；`kit_selftest` `done failures=0`、`sprite_selftest` `failures=0`、`tileset_selftest` `failures=0`。门与按钮在编辑器里改 `height` / `width` / `press_depth` 仍立刻重画（`@tool` 未破）。

## 美术决策补录（2026-09-19）· 地图从「金属倒角」换成「贴纸语言」

### D26 · 风格开关 `soft` + 实装风格改 G（暗底夜光）；`d` 留后关

**动因**：用户判断「现在的整体风格有点太写实了，和主角的可爱风格不搭」。诊断出根因不在配色而在**描边方向**：主角（`tools/gen_player_frames.py` 的 `PAL`）是 `outline = (4,4,4)` —— 深色描边在**最外一圈**、高光在里面；而已实装的 `ab` 地形正好相反，第 0 行是 `lip`（最亮）、第 3 行才是暗线 —— 那是金属倒角的读法。两套美术语言方向相反，换配色不会让它们变一致。所以解法是一个**形状语言开关**（`soft`），而不是重画一套色。

**结论**：

1. **`soft` 分支加在四个面语言函数里**（`cap_top` / `face_left` / `face_right` / `underside`）：描边挪到第 0 行/列，亮面收进第 1 格，其下 2 px 次亮带 + 1 px 收釉暗线；左右互为镜像。`ab` 分支一行未动、像素级可复现，两套语言并存，靠 `p["soft"]` 选。
2. **外凸角 1 px 切角**（`soft_corners`，屏幕上 2 px @ zoom 2），贴纸才不方。**切角只动 (1,1) / (14,1) / (1,14) (14,14) 四个像素，第 0 与第 15 行整行不透明这条不许破** —— 碰撞是整格矩形，角上漏一个透明像素就是「踩在空气上」，D24 第 5 条的构造性保证会因此失效。
3. **重复 / 平铺的装饰一律不切角**（`DECOR_NO_ROUND = {wall_fill, shade, pipe_h, pipe_v}`）：它们是整层铺满或按周期重复的，圆一个角就在每个接缝上刻一个缺口。
4. **非平铺装饰统一补 1 px `edge` 贴纸外框再切角**。这条是通用解而不是逐配色打补丁：E 那套的装饰（金属色）和它的墙面对比只有 1.3，等于刷上去看不见 —— 加外框之后所有风格一起解决，不用逐套调。
5. **新增 6 个 16 px 自洽纹样**：`quilt` 软包菱格、`dot` 波点、`brick_round` 圆角地铁砖、`wood` 玩具木、`gummy` 果冻、`grid` 圆角软面板。两条踩过的坑值得记：**`lighter()` 在浅底上等于没画**（它往白插值，奶白底看不出），所以波点改成「暗环 + 亮心」、菱格补右下投影；**圆团高光按 16 px 重复会读成壁纸圆点**，所以 `gummy` 重构成横向柔光带 + 收釉线 + 一颗偏轴气泡。
6. **4 px 契约翻向（守门跟着语言走，不跟着颜色走）**：`tileset_selftest` 锁的是**描边方向**。顶 / 左 / 右三组改成「第 0 行不透明 + 第 0 行比第 1 行暗 + 第 1 行比主体亮」；**底面那一组两种语言都成立，一字未改**。取样行列刻意避开 `soft_corners` 动过的那四个像素。断言 284 → 308（新增 3 条 × 8 个掩码 × 3 个开放面）。换下一套配色时这条守门照样成立，因为它量的是图集像素。
7. **选型一次出 6 套同构图**（`d` 糖果贴纸 / `e` 玩具房 / `f` 果冻 / `g` 夜光，加原有 `abc`），全部由真图集逐格拼出，预览 == 引擎。实装开关是一个常量 `SHIPPED`（配套 `ORDER` 决定出哪几张图、`tiles.json` 里落 `style` 与 `surface_language`）。**用户选 G 先做、`d` 留后面的关卡**：`d` 的 STYLES 条目与预览图都在档，换实装风格改一个常量重跑管线。
8. **可读性改成量 WCAG 相对亮度比**（`_rlum` / `_cr`，1.0 ~ 21.0），不再用加权灰度平均 —— 主角正好落在感知亮度曲线最底端，平均会把「近黑 0.4」和「暗蓝 6」糊成一个数，于是旧报表在暗底上系统性地高估可读性。生成器每次跑都打印九套风格的对比表，低于阈值那行直接标出来。**阈值 4.5 只当提示，不当否决**（见后果一）。
9. **`g2` 是只为出图加的风格**：与 `g` 同配色，多一个 `player_rim` 键，用来把「给主角补一圈亮边」这个解法**画出来**而不是描述（rim 对墙 5.48，过阈值）。加亮边在缩放前做，一圈才是 1 世界像素。未实装。

**要知情的后果**：

- **主角 silhouette 对暗墙 2.63，低于 4.5**。这是暗底风格的固有代价，我拿数字劝过一轮，用户看过 `g` 与 `g2` 后判「现在的画风很融合了，不用修改了」。**这条以后别再拿数字重开**；真觉得人物发闷，解法是第 9 条的亮边（`gen_player_frames.py` 烘进帧里，或在 `PlayerVisual` 运行时加），已量过可行。
- 预览渲染里的标注文字在暗底自动换亮色（`render_room` 按背景亮度选 `ink`），所以暗风格的选择图不会糊成一片黑 —— 这是看图判风格的前提。
- 冻结滤镜（M3）那条附带收益要重估：`g` 的身份有一半靠青/琥珀发光撑，去饱和后可能塌。D24 第 10 条的判据（「靠明度结构撑的能过、靠色相撑的会塌」）仍然对，只是现在得对 `g` 单独量一次。

**验证**：`py tools/gen_tiles.py` 重跑产物与上一轮**字节一致**（md5 核对 `tilesheet_terrain.png` / `tilesheet_decor.png` / `tiles.json`），说明文档里这些数字对着的就是当前资产、生成器无隐藏随机性。`--import` → `build_tileset.gd` 打印 `terrain: 16 格 / decor: 12 块 / saved ... err=0 failures=0`。四条守门全绿：`verify_kit` `doors=2 failures=0`、`kit_selftest` `done failures=0`、`sprite_selftest` `failures=0`、`tileset_selftest` `failures=0 checks=308`。实测对比表（wall / floor = 相对亮度，p = 主角，o = 门板，r = 亮边）：

| 风格 | soft | wall | floor | p/wall | p/floor | o/wall | o/floor | r/wall |
|---|---|---|---|---|---|---|---|---|
| ab | no | 77.6 | 32.5 | 15.42 | 7.01 | 6.46 | 2.94 | — |
| d | yes | 79.1 | 58.1 | 15.70 | 11.79 | 10.52 | 7.90 | — |
| e | yes | 84.8 | 42.7 | 16.77 | 8.92 | 9.09 | 4.83 | — |
| f | yes | 82.9 | 45.2 | 16.42 | 9.37 | 10.50 | 5.99 | — |
| **g（实装）** | yes | 9.1 | 19.1 | 2.63 | 4.49 | 2.32 | 3.96 | — |
| g2（仅预览） | yes | 9.1 | 19.1 | 2.63 | 4.49 | 2.32 | 3.96 | 5.48 |

## 设计决策补录（2026-09-19）· 危险物、钥匙门与存档点（M5）

### D38 · 「接触即判」是冻结语义的一般化：危险物相位是世界时间的纯函数，冻住的电仍然伤人
（**编号订正**：本条原记为 D28，与 2026-09-20 另一会话的「祭坛 / 终点编排下沉」撞号。那条已进手册与 context_brief，保留 D28；本条是纯设计、引用点少，改号为 D38。）

**动因**：要引入致死要素，必须先回答一个问题 —— **冻结能不能让人无敌**。当前游戏里没有任何东西能惩罚玩家，所以冻结没有代价，机制的分量出不来。

**统一法则（本决策的全部实质）**：**「接触即判」的机关不吃世界时间；「需要时间走完」的过程才吃。** 伤害判定、钥匙拾取、逻辑锁触发属于前者；门移动、危险物相位、移动方块行程属于后者。

**结论**：

1. **危险物的通断电相位是 `elapsed_world_time` 的纯函数**：`is_live = fmod(t + phase * period, period) < duty * period`，**不存实例状态**。理由与 D21 门的 `_progress` 完全同源 —— 冻结即冻相位、解冻即续走、恢复瞬间不跳帧，三条老结论直接复用，且 `kit_selftest` 不需要每个构件提供 `reset()` 就能断言。
2. **冻在「通」相位的电流棒仍然伤人**。这是支点：**一旦「冻住就无敌」，冻结变成万能钥匙，所有危险物退化成「等你按方向键」的空壳**。反向也成立 —— 冻在「断」相位就能走过去，**这才是谜题**（在正确的瞬间冻结）。
3. **周期型危险物天生不是单向门**：没有冻结能力的玩家靠走位 timing 过，有能力的玩家可以永久按住「断」相位，**它挡不住回头**。要单向只能靠 always-on 的几何（尖刺坑、深井落差）。**这条喂给单向机制那一轮**（当时口头留的编号是 D27，但该号已被「蹲伏缩盒」占用，那一轮改录 **D33**，至今仍未拍）：A1 深井比 B4 钟摆可靠得多。
4. **冻结期间也能拾钥匙、也能触发逻辑锁**（同一条「接触即判」）。附带收益：消耗式钥匙锁只发一次 `true`、从不发 `false`，因此**天然免疫按钮那个「面板弹起、门还开着」的不自洽**（按钮的延迟松开是为了画面自洽，这里根本没有松开这回事）。

**要知情的后果**：

- **按着方向键死亡 → 重载后当帧又冻结**（输入仍按住，`reset_state()` 只能把状态设回 FLOWING 一帧）。自洽且无害，但**要求存档点摆在「冻结中也安全」的位置** —— 离任何危险物留出一个盒宽加视觉余量。这条是实现时进手册的摆图约束。

### D29 · 尖刺与电流棒＝同一个 `hazard` 构件的两种参数；实体走 `time_solid` 层，不新发明层

**结论**：

1. **一个构件两种参数**：`period = 0` 即常开 = 尖刺，`period > 0` 即周期通断 = 电流棒。**不拆成两个类** —— 冻结语义、判死、摆图约束三件事完全共享，拆开就是三份守门。（**订正：本条已由 D34 推翻**，用户要求电棒可浮空、任意朝向且与尖刺功能分开，实装是 `Spikes` + `ElectricBar` 两个构件 + 共同基类 `HazardBase`。第 2~6 条仍然成立。）
2. **做成构件不做瓦片**：`TileMapLayer` 没有 `body_entered`，伤害判定得另找路（玩家侧反查脚下格，或给整层加 Area2D —— 两条都比构件脏）。走 D25 刚立的套路：`length` 导出项 + `_draw()` 平铺 16 px 自洽零件，一个实例就是一片尖刺，摆图和摆门一样。
3. **`blocks_when_live` 一个导出项解决两种手感**：电流棒 = `true`（挡住 = 明确读作「一堵电墙」，不会是偷袭），**`collision_layer = 4` 复用 `time_solid`** —— Player 的 `mask = 5` 已经读 terrain + time_solid，**不用改玩家、不用新发明层**（手册 §4「照抄别新发明」守住）。地面尖刺 = `false`（可以掉进去死，纯 Area2D 判定）。实体与伤害是两条通道，但由同一个 `is_live` 驱动，所以「挡住它」和「被它伤」永不矛盾。
4. **电流棒形态：两个极柱之间拉一道光束**（一个构件带 `length`，极柱用 `assets/props/` 的零件套路出 16 px 自洽件），不是固定短棒 —— 只有「一道要等的电闸」读得出时机。**来回滑动的电流＝动态压力源，§8 排除，不做**。
5. **判死归属**：`Hazard` 只发信号（玩家进来了），`LevelBase` 接住并决定「死」，`Main` 决定「怎么回」。构件不引用 `Player` 内部，`Player` 也不长出 `hp` / `inventory` 字段。
6. **摆图约束（实现时进手册 §8）**：断相位 ≥ 0.35 s 才允许靠跑动穿过（穿一根 8 px 棒实测只需 0.11 s，0.35 是给起步加速留的量，**待实测校正**）；任何危险物**第一次出现**必须摆在「死了能立刻看懂为什么死」的位置。

**与 D27（蹲伏缩盒）的三条交叉核对**：

- **实体电流棒会被头顶净空判定读到，这是对的。** D27 第 4 条的净空掩码是 `1|4`（terrain + time_solid），而第 3 条把电流棒放在 `layer = 4` —— 于是「蹲下能不能起身」会自动把通电的棒当障碍，断电时碰撞体收起、又自动放行，不用为此写一行新代码。但由此得一条硬约束：**危险物绝不能放 sensor 层**（`monitorable = false`，净空查询看不见它，会出现「站在电棒里却认为头顶是空的」）。
- **⚠ 挂在高处的棒子会多出「蹲下钻过去」这条绕过路线。** 蹲伏盒只占地面以上 0–15 px，一根底部离地 ≥ 15 px 的实体棒，蹲着就能从下面走过去，时机谜题直接作废。所以摆图规则要写死：**要么棒的碰撞体一直铺到地面（钻不过去），要么"要蹲"是关卡明确设计的第二解**。摆图的人不知道这条，就会摆出看似挡路、其实形同虚设的电闸。
- **传感器与蹲伏已经量过，新构件白拿。** D27 核算过：按钮带子跨「地面以上 3–27 px」、蹲伏盒占 0–15 px，重叠 12 px，`Player.COLLISION_HALF_HEIGHT` 契约未动。`KeyLock` 与 `Checkpoint` 沿用同一条带心算法，于是**蹲着也能开锁、也能存档**，不必重做判定，也不必在手册里写"必须站着存档"这种废话。

### D30 · 钥匙门：`KeyPickup` + `KeyLock` 两件套，钥匙是消耗品，门永久闩开

**用户裁定（2026-09-19，原话）**：「钥匙只能开一次门，开门后门保持打开状态，钥匙会被消耗，玩家复活时失去身上的钥匙并重置钥匙。」

**这条裁定推翻了我原先的方案**（原方案：钥匙 = 一把粘性标记，拾取后那扇门的锁永久解锁）。改成消耗式之后有一个意外收益，见第 3 条。

**结论**：

1. **三段链条 `KeyPickup` → `KeyLock` → `Door.trigger`**。（**订正：本条已由 D36 推翻** —— 用户裁定刷卡门不与按钮门共用场景，`KeyLock` 并进独立的 `KeyDoor`，`Door.trigger` 这条路不走。第 2~8 条仍然成立，其中第 2 条「一生只发一次、从不发 false」的闩锁语义原样搬进 `KeyDoor`。）锁的逻辑全部集中在 `KeyLock`，~~**门保持笨、`trigger` 契约一字不改**~~（D20「门只认信号不认类型」在这里兑现；`verify_kit` 已经在验 `trigger` 指向的节点真的发 `pressed_changed`，接进去自带守门）。`KeyLock` 自身 = `SensorZone` 的感应带语义（同原点约定、带心 −15）+ 一个「持有钥匙才放行」的门控。
2. **闩锁语义**：`KeyLock` 一生只发一次 `pressed_changed(true)`，**从不发 false**。门收到 true 之后不需要任何新语义 —— 开到头就停在那儿。
3. **钥匙状态住在 `KeyPickup` 实例上（`held: bool`），不是 `Player` 的字段**。两个理由：其一，`Player` 不该长出背包；其二（更重要）——**实例状态在 D31 的重载模型里免费归位，正好就是用户要的「复活失去并重置钥匙」**，于是 `run_state` 里**不需要钥匙条目**，粘性状态从四条缩到三条。
4. **身上那把钥匙 = `KeyPickup` 每帧把自己的可视位置跟到玩家~~头顶~~**（**订正：位置已由 D39 改到体内** —— 半透明的卡钉在脚底上方 3 px 的常量偏移上），不 re-parent（`PlayerVisual` 带 `facing` 镜像，子节点会跟着翻）。跟随用 **real-time 而不是世界 delta**：冻结期间玩家会动，钥匙必须跟着动 —— 与「世界冻结时主角动画照常推进」同一条表现层规则。
5. **复活 = 全部归位**：门重新关上、钥匙重新出现在原处。这是裁定的直接推论，代价要说清 —— **钥匙门是死亡惩罚最重的关卡节点**（白跑一段去重取钥匙）。
6. **死锁风险写进守门**：两个 `KeyLock` 指向同一把 `KeyPickup` → 第二扇门永久开不了。虽然死亡 / R 键重开能救，但正确处置是让 `verify_kit` **直接 FAIL**：一把 `KeyPickup` 最多被一个 `KeyLock` 引用。
7. **可读性**：锁着的时候门楣 LED 用锁色、被钥匙解锁后转青。要碰 `props.json`（新增 `led_locked`）与 `verify_kit._verify_props()` 的同源比对（加一条），D25 第 6 条的契约因此扩一项。
8. **它不是单向门**：拿到钥匙即永久可开（本条命内），能原路返回。D33（单向机制，至今未录）若要单向，只能靠几何而不是靠锁。另记一条 D27 带出来的事实：门底让位留下的那条约 30 px 缝**现在蹲得过去**，所以"留一条缝挡住他"这类设想在蹲伏缩盒之后已经不可靠了。

### D31 · 存档点＝重载 + `run_state` 回灌；粘性状态只有三条；磁盘存档不做

**结论**：

1. **走「重载场景 + 回灌」，不走「原地瞬移 + 逐构件 `reset()`」**。后者要每个构件新加一条「我哪些状态该回」的语义并为它写守门（按钮的 `_pending_unpress`、祭坛的一次性、玩家的冻结意图各是一套），前者复用**唯一已被验证的重置路径**：`Main.load_level()` → `LevelBase._ready()` → `TimeManager.reset_state()`。
2. `Main`（常驻 World 根）持 `run_state = {respawn_position, ability_granted, altar_spent}`；`LevelBase._ready()` 照旧把玩家放到 `PlayerSpawn`，**之后若 Main 有 `run_state` 就用它覆盖**；`load_level(新场景)` 时清掉。这是本项目唯一新增的跨节点状态，且不违反「关卡之间不互相穿帮」的原意（它只在同一关内有效）。
3. **粘性清单**（钥匙按 D30 不在表内 —— 它是非粘性的）：

| 状态 | 重生后 | 说明 |
|---|---|---|
| **冻结能力已授予** | **保持** | ⚠ 不处理就是真 bug：引导关 `start_with_ability = false`，`_ready()` 会照此关掉能力，**玩家重生后失去冻结、卡死在存档点** |
| 祭坛 | 保持已消耗 | 否则会出现「用过的祭坛还站在那儿」 |
| 钥匙（持有 / 闩锁 / 门开度） | **全部归位** | D30 裁定的免费推论 |
| 机关相位、门开度、玩家速度 | 归零 | 纯函数 + 世界时钟归零，自动成立 |
| 玩家位置 | 最近存档点 | 唯一真正需要跨重载传递的东西 |

4. **踩上即存**，不设确认窗口（存档是便利不是仪式），但反馈必须显式（灯 + 一次性色变），否则玩家不知道自己存了。

   **订正（D51，2026-09-22）**：「一次性色变」换成了**可让位的灯** —— 亮 = 此刻它是当前存档点，被更新的顶掉就回 idle，再踩回来又亮。本条要的"显式反馈"没打折，反而更准：任何时候场上只有一台亮，皮说的就是重生位。同条第 2 点那份键清单也校准过：`ability_granted` 从来不需要存（它由 `altar_spent` 推导，见 D31 自己在 `main.gd` 里留下的订正），D51 起 `run_state` 实际是 `{respawn_position, respawn_marker, altar_spent}` 三个键，并且 `altar_spent` **第一次真的有人写**。
5. 重生后全体机关相位归零 = **可以背板**。对时机谜题这是特性不是漏洞。
6. **死亡不加演出、不复用灰滤镜** —— 去饱和是「冻结」的视觉语言，挪用成「死」会混淆两条语义。

   **订正（D42，2026-09-21）**：两半都推翻了 —— 死亡现在有 0.55 s 的收缩 + 爆裂，且那一拍世界**确实**钉在冻结里，灰滤镜跟着上。但本条担心的"混淆两条语义"没有落空：滤镜不是被**借用**去表示"死"，它读到的是此刻**真的没有世界时间在走**（`TimeManager` 里仍然只有一个是真的 `current_state`）。本条真正在防的是"拿一套视觉符号演两件不相干的事"，D42 走的是另一头 —— 让两件事共享同一个物理事实。仍成立的半边：**不新增第三种全屏色调**，死亡不配独立的滤镜。

### D32 · 范围变更：新立 M5「危险与推进」

M5 交付：`hazard.tscn`（尖刺 / 电流棒两种参数）、`key_pickup.tscn`、`key_lock.tscn`、`checkpoint.tscn`、`Main.run_state` 与 `LevelBase` 回灌、`gen_props.py` 的危险物与钥匙零件、`verify_kit` 三条新守门（`led_locked` 同源、`KeyPickup` 单引用、存档点/危险物摆位约束中能静态检查的部分）、`kit_selftest` 一组新断言（冻结中通断相位不变、冻住的通电话仍伤人、闩锁只发一次 true、重生后能力不丢）。**M1~M4 的验收一项不动**。§8 已相应改写：持久存档 / 关卡选择 / 主菜单仍在范围外，敌人和动态压力源仍在范围外。

**实现顺序**：先扩 `tools/gen_props.py` 出危险物 / 钥匙 / 锁 / 存档点的**选型图**（看图定风格，不看参数），用户过图之后再动构件代码；手册 §4 / §5 / §8 / §10 等构件真的存在了再同步，不提前写不存在的导出项。

---

## 设计决策补录（2026-09-19）· 蹲伏真的改变碰撞盒

### D27 · 蹲下时碰撞盒同比例缩到 15，头顶没净空就保持蹲伏且不许起跳

**动因**：用户报「在玩家按住下时，虽然画面变扁了但是碰撞框没变，应该也同步变小，并且在头顶被门等物体压住时不能自动恢复待机状态」。这是**推翻 D22 第 4 条**（"只影响动画，不影响碰撞"）的主动变更，用户已确认。用户拍板：高度取美术同比例、蹲着不减速、被压住时禁止跳跃、手册 §8 常数照第 3 条建议改。

**结论**：

1. **两件事是同一件事。** 只要盒子会缩，就**必须**有头顶净空判定 —— 否则松手起身时碰撞盒会长进门板里。`Door` 是 `StaticBody2D`，D21 的让位只在**关门方向**夹 `_progress`，门静止时根本不查，于是玩家会站在门板内部，`move_and_slide()` 下一帧的脱困求解把他弹飞或卡死。所以"被压住不许起身"不是独立需求，是"缩盒"的必要配套。
2. **高度取美术同比例（Q1）。** 站姿美术 25 对盒 30（×1.2），蹲伏循环帧实测高 `12 / 12.5 / 13 / 12.5` 取 12.5 → **碰撞盒 15**（也正好是站姿的一半）。**脚底永远钉在原点下方 `COLLISION_HALF_HEIGHT`，盒子只从顶部往下缩** —— 这条是 D22 花力气守住的脚底契约，破了就会陷地/悬空，自测里单列一条断言钉死。**不减速**：用户明确不做速度系统，代价见后果一。
3. **被压住时禁止起跳（Q2）。** 在 `_try_jump()` 开头拦，且**一并清掉 jump buffer** —— 留着的话等头顶一空出来人会莫名其妙自己弹一下。
4. **净空判定只查"站起来会新占的那条竖带"，不查整盒。** 带子 = 站姿盒顶到蹲伏盒顶那一段（15 px），两端各扩 `HEADROOM_MARGIN = 1 px`。理由：脚底那一段本来就占着，查它毫无意义；而 D21 实测过 `intersect_shape` 对**恰好相切**不可靠，手动留余量才能把"绝不漏判"变成硬保证。掩码 `1|4`（terrain + time_solid），传感器层是 `monitorable=false` 的 Area2D，不挡人。无状态查询、每帧重问一次，与 D21 的让位同一套理由：不维护重叠计数，`respawn()` 被瞬移走、世界冻结、解冻续走都不用补账。
5. **动画必须读实际状态而不是按键。** `PlayerVisual` 原来读 `is_crouch_held`（输入）。被压住时输入早已松开，读输入会播 `crouch_out` → `idle`，画面站着而碰撞盒还蹲着 —— 正是"画面变扁碰撞不变"的**镜像**错误。新增 `Player.is_crouching`（实际状态，碰撞权威）与 `is_head_blocked`（读数），`_track_crouch()` 与 `_pick()` 一起改读前者，边沿判定跟着实际状态走。
6. **腾空一律不蹲**（沿用 D22）：`is_on_floor()` 为假时净空判定不拦人，直接还原站姿盒。从低矮处走下台阶会被放行 —— 落下去的过程本来就在远离天花板，不需要特判。
7. **形状资源运行期独占一份。** `player.tscn` 里那份是 sub_resource，直接改尺寸会波及同场景其它实例（门踩过同一个坑，见 D21），所以 `_ready()` 里 `duplicate()` 一份再用。
8. **`respawn()` 清蹲伏。** 否则重生时可能带着 15 px 的盒子出现在需要 30 px 的场合。
9. **`_update_crouch()` 必须排在 `_try_jump()` 之前。** 能不能起跳取决于这一帧的净空结果，顺序反了就会漏拦一帧。
10. **剪辑优先级必须跟着改：蹲伏压过 `start` / `stop` / `run`。** D22 第 3 条原本写"跑动全部压过蹲伏"，那时蹲伏是纯表现，按着下键还能全速跑、播站姿 `run` 也说得通；碰撞盒真蹲下之后，再播站姿剪辑就是"画面起立、碰撞还蹲着"，用户报的"蹲着移动突然穿模起立再蹲回去"正是这一条。新序：`land` > `wall_press_in/wall_press` > `wall_press_out` > **`crouch_in/crouch/crouch_out`** > `start` > `stop` > `run` > `idle`。配套两处：`_track_slosh()` 的 `running` 加上 `not is_crouching`（否则"蹲着走→停→起身"会在起身那刻补播一段 0.19 s 的 `stop`，而 `stop` 前伸 19 px 是所有剪辑里越界最狠的一帧，D23 同款理由）；进蹲伏时清掉 `_start_remaining` / `_stop_remaining`（跑动中按下会同时触发"跑动→停"的刹车窗口，那 0.19 s 会一直留着）。
11. **没有蹲走剪辑。** 蹲着移动播的是静止的压扁循环，不是滑行动画。要蹲走得再出一帧一套，第一章不做 —— 记入待办。

**核算过、结论是"不是问题"的三条**：

- **蹲着踩按钮不会失灵。** 按钮带子跨「地面以上 3–27 px」，蹲伏盒占「地面以上 0–15 px」，重叠 12 px。`Player.COLLISION_HALF_HEIGHT` 那条契约一个字没动，传感器构件零改动。
- **门的让位不受影响。** `_clamp_squeeze` 用 `SQUEEZE_MASK = 2` 查"有没有玩家"，与盒高无关；玩家变矮只是让门能落得更低。
- **蹲下仍不冻结世界。** `move_down` 不进 `notify_movement_intent` 这条没动，自测第 7 组三条断言原样成立。

**要你知情的两条后果**：

- **一：蹲伏成了真实通行能力，手册 §8 加了一条常数（Q3）。** 站立最小缝 40 px（30+10），蹲伏变成 **25 px**（15+10）。瓦片世界最小缝是 48 px（16 px 格刷不出更小），所以实际受影响的只有一处：**D21 那条"门底停在头顶留下的缝约 30 px"** —— 原本注明"小于 40 所以不算可通行"，现在蹲下就能钻过去。等于给"拿头顶住门"多开了一个解法。
- **二：蹲在门正下方会被锁在蹲姿。** 门落到蹲姿头顶停住 → 站不起来 → 松手世界照常流动 → 门还是压着。解锁只有两条路：水平移动（冻结世界，门不动）横着挪出门下方后起身；或按钮再次按下让门上行。**不会永久卡死**，但"蹲在门下起不来"是新观感，摆图时要知道低矮处 + 门可以做出这种锁定。

**验证**：`sprite_selftest` 新增第 10 组 21 条断言（蹲下盒高 15 且脚底仍在 +15、动画进 `crouch`、**蹲着移动仍播 `crouch` 不被 `run` 覆盖**、停下与起身前不补播刹车甩动、被压时 `is_head_blocked` 挂上且保持蹲伏、被压时不播起身剪辑、被压时跳跃无效且 `vy=0`、挪出低矮处后自动起身且盒高还原 30、起身后回 idle），`failures=0`。另三条守门照旧：`kit_selftest` `done failures=0`、`verify_kit` `doors=2 failures=0`、`tileset_selftest` 308 条 `failures=0`。

**修掉的 bug（2026-09-19 当天）**：用户报「蹲伏状态下移动会突然穿模起立再蹲伏回去」。根因就是第 10 条那条旧优先级 —— `_pick()` 里 `run` 排在 `crouch` 之前，蹲着走会播站姿 `run`。用户自己的猜测（"移动的动画覆盖了蹲伏动画"）方向完全正确。修法见第 10 条，新增 5 条断言钉住。

---

## 设计决策补录（2026-09-20）· 关卡编排下沉与守门数据驱动

### D28 · 祭坛 / 终点编排下沉到 `LevelBase`；守门改自动发现、不再钉摆位坐标

**动因**：用户问「有哪些是写在 level01 里写死的、怎么改方便后续地图搭建」。盘点出两类硬编码，第二类其实更痛 —— 它不是代码味道，而是**每天都在挡摆图**。

**结论**：

1. **两块编排下沉到 `LevelBase`（原来每关抄一遍）。** D16 祭坛静止即启、D18 终点停手重开，此前 `level_01_tutorial.gd` 与 `level_template.gd` 各一份且实现不一致（引导关写死 `const`、模板用 `@export`）。现在基类提供：
   - `@export_node_path altar_path`（默认 `^"Objects/AbilityAltar"`）
   - `@export_node_path goal_path`（默认 `^"Triggers/GoalZone"`）
   - `@export goal_restart_delay = 1.5`、`@export ability_enable_timeout = 2.5`
   
   **约定优于配置**：按模板约定摆好这两个节点就自动生效，新关零代码；路径解析不到就**静默跳过**（"本关没有祭坛"是合法配置），指到了却不发契约信号才 `push_warning`。与 D20 给门定下的规矩同一套口径。
2. **接线一律 `@export_node_path`，不写死 `$Objects/xxx`。** 引导关的按钮与旁路打点区也改成导出项 + 自己解析。改名或挪层级在检查器里重指即可。
3. **`Player.input_handler`。** `get_node("MovementInputHandler")` 这个字符串曾在三个关卡脚本里各写一遍，收敛成玩家暴露的只读属性。
4. **守门不再钉摆位坐标。** 删掉 `_check_scene()` 里四个硬编码（祭坛必须在 `(1808,-128)`、相机必须是 `Rect2(-96,-416,2080,512)`、方块必须 `(1376,-208)` + `travel_offset(0,-72)`）。守门该守的是**构件契约与结构完整性**，不是美术摆位 —— 摆图的人挪一下祭坛就 FAIL 是最糟糕的一类守门。
5. **关卡自动发现取代白名单。** `_discover_level_scenes()` 扫 `res://scenes/levels` 整棵子树，凡根节点脚本是 `level_base.gd` 或其子类的场景都算关卡，新关摆完自动进守门（本次实测 `doors` 从 2 变 3，正是自动发现了 `level1`）。判"是不是关卡"靠 `_is_level_root()` 顺脚本继承链找 `level_base.gd`，**不能写 `is LevelBase`** —— 那会让守门在编译期依赖它，而它引用 autoload。
6. **新增的关卡级契约**：必须有 `Player` + `PlayerSpawn`（手册 §11 的已知坑升成了守门）；`AbilityAltar` 最多一个（两个就有一个永远不响应）；`GoalZone` 必须是 `SensorZone` 且 `band_centre_y == -15`。
7. **子类钩子**：`_begin_ability_sequence()` 与 `_on_ability_enabled(reason, wait)` 可覆写，引导关靠它们保留原有的 `[m2]` 试玩日志；基类本身不打日志。

**踩到的一个坑（值得记）**：GDScript 方法**默认虚调用**。引导关最初的日志方法也叫 `_on_goal_body_entered`，直接**覆盖**了基类的同名方法 —— 基类连的就是这个名字，于是 `_goal_reached` 永远不置位、自动重开静默失效。引导关的日志方法改名 `_log_goal_reached`。以后给基类加被 `connect` 的方法，子类要用不同名字。

**顺手修掉**：`level_template.tscn` 引用的瓦片集 UID 是过期的（`uid://by316oq77sf70`，真值 `uid://c7q30ygg6lk5r`，因 `build_tileset.gd` 重出过 `.tres`）。引擎会回退到文本路径所以不致命，但每次跑守门都刷一条 WARNING，会淹没真问题。

**验证**：四条守门全绿且**零 WARNING/ERROR** —— `verify_kit doors=3 failures=0`（doors 从 2 涨到 3 正是自动发现的证据）、`kit_selftest done failures=0`、`sprite_selftest failures=0`、`tileset_selftest failures=0 checks=308`。两关实际装载零报错并各自打印 `level_start ability=false`（`level1` 与引导关都走无能力开局）。

---

## 选型定稿 + 危险构件拆分（2026-09-20）

### D34 · 尖刺与电棒**拆成两个构件**（订正 D29 第 1 条）；分界是「有没有相位」，不是「会不会咬人」

**选型（用户看 `assets/props/preview_m5.png` 定）**：尖刺 = **S3**（一格一颗大牙，16×16 单元、牙高 14）；钥匙 = **K2**（能量卡 14×10）；存档点 = **P2**（地台终端 32×14）。电棒沿用选型图那套（极柱 10×18 + 电弧，`length` 沿自身 X 轴），但要求：**可浮空、可横可竖，和尖刺的功能区分开**。

**结论**：

1. **拆成 `Spikes` 与 `ElectricBar`，共同基类 `HazardBase`。** D29 第 1 条「不拆成两个类」作废 —— 那条的理由是「拆开就是三份守门」，而共享的四件事（相位纯函数、判死信号、`_draw()` 平铺框架、摆图契约）放进基类就仍然只有一份，拆与不拆在守门成本上打平。**拆的真正收益是导出项不再互相装死**：`period` / `duty` / `phase` / `blocks_when_live` 对尖刺全是死项，尖刺除了 `length` 什么都不该有。摆图的人在编辑器里看见四个拧了没反应的旋钮，比看见两份守门更糟。
2. **功能分界线**：尖刺 = **地形**（常开、贴地或贴顶、不挡路，可以掉进去死）；电棒 = **空间**（有相位，可以钉在任意高度、任意朝向）。判死方式两者相同（接触即判，D38），差别全在「它占的那块空间会不会周期变化」。
3. **朝向不吃代码**：两者都是 `Node2D` + 子碰撞形状，编辑器里转 `rotation` 即可，碰撞盒与判死区跟着转。竖电闸 = 横着画的同一张纹理转 90°，预览与引擎走同一条合成路径（选型图 E3 就是这么出的，不是两套画法）。
4. **`blocks_when_live` 把电棒分成两种用法**：`true` = 门形态（一堵会周期消失的墙，实体走 `collision_layer = 4` 复用 `time_solid`，Player `mask = 5` 已经读它，不新发明层）；`false` = 浮空形态（不挡路，纯危险区，一条要挑时机穿过去的电）。尖刺恒 `false`。
5. **电棒独有的谜题动词 = 冻结钉住相位**（D38 的直接后果，也是它和尖刺真正分开的地方）：相位是世界时间的纯函数，冻结时世界时间不推进 → 棒子钉在按下那一瞬。冻在 LIVE = 一堵又硬又伤人的墙，能当永久掩体用；冻在 OFF = 白送一条通道，解冻立刻恢复。**尖刺没有相位可冻，所以它永远只是地形** —— 想要「用冻结改变可通过性」的谜题，只有电棒给得了。
6. **摆图硬数（实现时进手册 §8）**：
   - 门形态必须**一端贴地、另一端贴天花板，或 `length ≥ 144`**（跳跃峰高 136 + 余量）。选型图 E3 那根 68 px 的竖闸**跳得过去**，那是示意尺寸不是可摆尺寸，别照它摆。
   - 横棒下沿离地 **< 25 px** 才不至于被蹲伏白送（手册 §8 蹲伏最小缝 = 15 + 10，D27 第 4 条）。
   - 断相位 ≥ 0.35 s（D29 第 6 条，仍待实测校正）。
   - 危险物一律不放 sensor 层（D29 与 D27 交叉核对那条硬约束，随拆分一起生效，写在 `HazardBase` 里，两个子类都受它管）。
   - 任何危险物第一次出现必须摆在「死了能立刻看懂为什么死」的位置。

**选型图顺带查出来的两条既有事实要改**：

- **极柱与存档点钢座在暗底 `g` 上原本隐形**（对墙 2.13 / 对地 1.25）。已按 D26 给主角的那招补一圈 `lip` 亮边（对墙 5.48）—— 这条**必须落进构件**，不然实机还是看不见。构件的 `_draw()` 只认落盘的零件 PNG，所以亮边是画在零件里的，不是运行时加的。
- **门底那条黄黑警示条和 K2 能量卡同属琥珀家族**，「琥珀 = 可拾取物」这条色彩律被 D25 已落盘的 `door_bottom.png` 撞了。改哪一边、怎么改，单独决策（D35 候选），**不在本条里顺手改** —— 那会连带翻 `verify_kit` 的调色板同源断言。

---

## 电棒的相位与「移动即冻结」（2026-09-20）

### D35 · 电棒**只在玩家站着不动时推进相位**；这既是它和尖刺的真分界，也作废了 D29 第 6 条那条 0.35 s

**查出来的事实**（`autoloads/time_manager.gd`）：`notify_movement_intent(true)` 是**立即**置 `FROZEN` 的，`RELEASE_BUFFER_DURATION = 0.08` 只作用于解冻方向；而 `elapsed_world_time` 只在 `FLOWING` 累加。玩家按住左右 = 移动 = 冻结。于是任何以世界时间为自变量的相位（D38 那条 `is_live = fmod(elapsed_world_time + phase * period, period) < duty * period`），**在玩家移动期间一分一毫都不走**。

**结论**：

1. **电棒 = 「你不动，它才动」**。要等它断开就必须站着不动；一旦看清断开、按下方向冲过去，**整个穿越过程相位被钉在起步那一瞬**，绝对安全。难度全在「读清相位 + 下决心起步」，不在走位精度 —— 这正好是第一章要教的那个动词。
2. **D29 第 6 条的 0.35 s 作废**：那条的理由是「穿一根 8 px 棒实测只需 0.11 s」，可那段位移发生在冻结期内，世界时间增量为 0，所以穿越耗时和相位长度根本不挂钩。**替换判据：断相位持续的世界时长 ≥ 玩家的反应窗口**（他得看清「现在是断的」再起步），建议 **≥ 0.4 s**，量级与旧数字巧合但理由完全不同，仍待实测校正。
3. **真惩罚是中途松手**：穿出之前松开方向键 → 0.08 s 缓冲后世界流动 → 棒子可能在他身体还在洞里时通电，接触即判（D38）直接死。所以摆图要么给「一步跨得完」的长度，要么明确接受「松手 = 死」这条读法。
4. **浮空横棒给实体 = 一块「撒手才掉」的踏板**：站上去后按住方向 → 冻结 → 脚下永远通、永远不掉；一松手让时间走 → 脚下可能消失。它**不是** §8 排除的动态压力源（压力来自玩家自己的静止，不是自主运动的物体），而且把「移动即冻结」这条隐形规则变得看得见 —— 第一章值得留这一手。`blocks_when_live` 逐实例设即可，构件不用改。
5. **解锁前后是两种东西，摆图顺序有硬要求**：`is_ability_enabled == false` 时世界恒 `FLOWING`，电棒就是一个普通计时陷阱；解锁之后它才变成「你不动它才动」。**所以电棒第一次出现应在祭坛之前**（教「等时机」），过了祭坛之后再出现一次（教「冻结能钉住时机」）。这条进手册 §8。
6. **尖刺没有相位可冻** → 它是纯地形，任何时候都咬人，与冻结无关。D34 第 2 条那条功能分界到这里才闭合：**分界不是「会不会咬人」，是「它的存在是否取决于你动不动」**。
7. **存档点 P2 沿用按钮那套地面构件语法**：纯 `Area2D` 传感器（`layer = 8, mask = 2, monitorable = false`），不做实体、不做台阶，主角踩在格线上、终端脸朝上。与 `ButtonPlate` / `AbilityAltar` 同族，零新发明 —— 手册 §4 那条守住。

---

## 刷卡门独立成场景（2026-09-20）

### D36 · 刷卡门**不复用 `Door` 场景**，`KeyLock` 并进门里；分界是「能不能倒着走」，动画因此必须不同

**用户裁定（2026-09-20，原话）**：「刷卡门和按钮门不要共用一个场景，因为他们的触发逻辑不同，动画也不应该一样」

**这条推翻的是 D30 第 1 条**（三段链条的最后一跳：`KeyLock` → `Door.trigger`）。D30 剩下的 7 条我逐条核过，**全部原样成立**，尤其第 2 条那条闩锁语义（一生只发一次、从不发 false）只是从 `KeyLock` 搬进了 `KeyDoor`，语义一个字没改。

**结论**：

1. **M5 的钥匙两件套变两个节点而不是三个**：`KeyPickup` + `KeyDoor`（`scenes/objects/key_door/`）。**感应带就是门本身**，读者与闩锁同处一个节点，摆图时只放一个东西，`key` 这个 `@export_node_path` 也终于有一个明确的宿主 —— 谁引用钥匙，就在谁身上。
2. **`Door` / `door.tscn` / `trigger` 契约一字不改，且一个新导出项都不加。** D30 当初不动门的理由是「别让门变聪明」；现在的理由更强 —— **刷卡门根本是另一扇门**，聪明与否都不必过它。D30 第 1 条那句「接进 `trigger` 自带守门」的好处随之作废，第 8 条换一种守门（见第 6 条）。
3. **触发逻辑的差是结构差，不是口味差。** 照 `door.gd` 数：`Door` 的核心是 `set_open(pressed)` → `_direction ∈ {−1, 0, +1}`，`open_time` 是**全行程**用时，`_physics_process` 里双向走；`_clamp_squeeze` 那条链（`intersect_shape` 零位移探针 + `cast_motion` + `HOLD_MARGIN` + `CONTACT_SLACK`）**只在 `_direction < 0` 时才被调用**。`KeyDoor` 的判据是「持有钥匙 ∧ 进入感应带」，输出是一次性闩锁，**没有关门方向** —— 上面那一整块在它是纯死代码。要塞回同一个场景只有两条路：留着死代码，或者给 `Door` 加一个 `one_shot` 开关。后者正是 D30 想躲的事，而且它一进去，D27 那条「蹲在门下起不来」的锁定语义就跟着进了一扇根本不该挤压人的门。
4. **动画定稿：卷帘 vs 光幕。**
   - `Door`（保持现状）= 机械卷帘，从门楣**往下挂**、往上收，实体钢板 + 琥珀警示底边。
   - `KeyDoor` = **能量闸**，青色光场贴着地面**往上长**；刷卡之后**自上而下逐行熄灭**，最后死的是脚底那一行。它不移动、不缩回门楣，它是**失去供电**。
   取带方向刻意相反：卷帘留出的缝在**下面**（等着把人挤住），光幕留出的缝在**上面**（只会越让越开）。**订正（D40，2026-09-20）：这条行程整块取消 —— 刷卡之后光幕当帧消失，不再有「逐行熄灭」那 0.5 s。幕体的画法（第 7 条）一字未改，改的是它有没有中间态。**
5. **纯函数架构原样搬，只换一条算式。** `Door` 值钱的地方是「位置与碰撞体都是 `_progress` 的纯函数」，所以冻结即停在当前值、解冻即续走、且碰撞体永远 == 画出来的那截。`KeyDoor` 沿用同一套：`_progress` 由 `TimeReceiver.get_physics_delta()` 推进，卷帘取**上带** `Rect2(-w/2, -H, w, H·(1−p))`，光幕取**下带** `Rect2(-w/2, -H·(1−p), w, H·(1−p))`。碰撞随进度走，**不做「先失效、再播动画」** —— 那是「穿过去一道看得见的光」这种破绽的来源。**订正（D40，2026-09-20）：`KeyDoor` 身上已经没有 `_progress`，也没有 `TimeReceiver` 子节点，取带算式塌成 `height / OPEN_H` 两态（唯一真值来源 `_curtain_height()`）。这条真正留下的两条约束反而更硬：碰撞体 == 画出来的（都从同一个高度派生），以及「不做先失效再播动画」（压根没有动画）。卷帘那条上带算式仍归 `Door`，一字未动。**
6. **守门重排三条**：(a) D30 第 6 条那条死锁检查改指 `KeyDoor` —— 一把 `KeyPickup` 最多被一个 `KeyDoor` 引用，多引直接 FAIL；(b) 现在 `verify_kit` 只按路径认 `door.gd` 来验「碰撞体 == 画出来的」，`KeyDoor` 得进同一个检查，否则将来谁改一边不会响；(c) `led_locked` 那条调色板同源比对照 D30 第 7 条留在 `props.json`，宿主从 `Door` 换成 `KeyDoor`。
7. **零件是复用的，场景不是。** 门柱 / 门楣 / 端帽三件照用 `assets/props/` 现有零件（同一套 `ab` 钢框，读作「这是一道门洞」），卷帘板与警示底边**不用**。**幕体本身是纯色半透明青，不画纹路** —— 第一版复用了 D34 电棒那支折线波动（竖直光丝 + 暗描边），用户看过图原话：「门里的纹路好丑，我觉得单纯蓝色光幕就可以了」。半透明是这条反馈的必要配套：背后的墙透得出来才读成「光」，平涂不透明就又成了一块门板。定稿画法 = 一层 `accent` 半透明幕 + 左右两条亮收边 + 外侧一像素光晕 + 顶端一条「断电前沿」亮行（**这条反馈也说明：`paint_beam` 那套纹路只属于电棒，别顺手挪到别处**）。净新增 = **零张新零件 + 一个 `led_locked` 色**。D34 记的那条「门楣警示条与 K2 琥珀同色」的顾虑，在刷卡门上反过来是加分项：锁着的 LED 用琥珀 = 与钥匙同色 = 「这把开那扇」是一对，同色在这里是语义而不是撞车。
8. **不抽 `DoorBase`。** 这与 D34 给危险物抽 `HazardBase` 相反，理由是实的：两个危险物共享**状态与规则**（受击判定、`is_live` 相位、同一套死亡路径），两个门共享的只有**画法常量和一条原点约定**。为后者建基类，等于把用户要求分开的两样东西在「同一棵树」这个层面又合回去，而且将来 `Door` 任何行程特性（半开、保持开、挤压）都会落到基类里让光幕白背一份。**门框平铺那 6 行复制一份，第三处用到再抽。**
9. **消散用世界时间推进，代价要认。** 与 D35 同一条性质：他边走边看，`_progress` 就被钉在当前值。但这里钉住**不是失败状态** —— 闩锁不会倒回去，最多是他停一步让它灭完，或者先走开再回来。所以不必为它开「表现层走 real-time」的特例（`KeyPickup` 那把跟身的钥匙才需要，D30 第 4 条 / D39）。**订正（D40，2026-09-20，本条整条作废）：错在把「停一步让它灭完」当成玩家愿意付的代价。感应带探在门洞前约 46 px，玩家朝门走 = 必然按着方向键 = 世界必然冻结，所以那次钉住不是偶发而是「每次都会发生」，试玩反馈就是这句：「钥匙门的触发好像有点问题，似乎不是立刻触发的」。详见 D40。**
10. **挤压这一整类 bug 在刷卡门上结构性消失。** `KeyDoor` 的碰撞体只会**变小，永远不会变大**，而它初始是全高实心的 —— 玩家不可能已经在光场里，因此不可能被它罩住、卡住或压扁。D21 花力气守的「只许停不许顶」、D27 后果二那条「蹲在门下起不来」，在这里都不存在，也不需要 `SQUEEZE_MASK` 那套探针。**这是拆场景换来的最大一项**，比「触发逻辑更清楚」实在得多。

**范围订正（D32 的 M5 交付清单）**：`key_lock.tscn` **取消**，改为 `key_door.tscn` + `key_door.gd`。构件从 4 个 tscn 缩到 3 个（`hazard.tscn` 拆成 `spikes.tscn` + `electric_bar.tscn` 按 D34，所以实际是 5 个 tscn、6 个脚本：`HazardBase` / `Spikes` / `ElectricBar` / `KeyPickup` / `KeyDoor` / `Checkpoint`），守门条数一条没少。D31 粘性表那行「钥匙（持有 / 闩锁 / 门开度）→ 全部归位」原样成立，而 D40 之后它更简单：光幕只剩两态、没有开度可回灌，重载即回到「锁着」。

**要你知情的一条**：第一次出现刷卡门时，玩家必须**先捡到钥匙、再走到门前** —— 光幕没有卷帘那种「一块钢板会落下来」的实体威胁感，可读性全靠「琥珀的锁 + 琥珀的钥匙」这一对颜色配对撑着。这条进手册 §8 的摆图顺序。

---

## 原地起跳的剪辑（2026-09-20）

### D37 · 原地跳**新增独立的 `jump_straight` 两帧**；判据是「起跳那一帧的实际水平速度」，闩锁到落地

**用户报告（2026-09-20，原话）**：「在角色原地跳跃时也会默认调用倾斜的跳跃动画，我认为应该绘制一个原地跳跃的动画」

**结论**：

1. **根因不是帧画错了，是挑剪辑那一层根本没有水平判据。** `PlayerVisual._pick()` 的腾空分支只有 `return &"jump"`，而 `jump` 那两帧自带前扑（`lean 0.5→1.0`、`dome_lean 1.0→1.5`）。原地跳当然看着在横移。
2. **新帧的 `lean` / `dome_lean` 归零，不留「一点点」。** 这一本作里「有没有横移」恰好等于「世界冻没冻」（D1/D13 的冻结判据就是水平移动意图），原地跳看得出倾斜，等于用美术谎报他在横移。拉伸改由**更窄 + 底裙更收**承担（`w 25/23 → 24/22`、`flare 0.86/0.80 → 0.84/0.76`），`h` 上限仍取 30 = 站姿盒顶（D23 那条「腾空美术不高出碰撞盒」）。`fps 12` 与非循环照抄 `jump`，两段起跳节奏一致。
3. **判据 = 起跳那一帧的 `velocity.x`，阈值复用现成的 `RUN_SPEED = 15`（不新增常数），在 `_on_jumped()` 闩一次，整个腾空期不改判。** 逐帧读会翻车：空中有 `air_acceleration 1700` / `air_friction 900`，跑跳途中松方向键约 0.27 s 后速度就掉到阈值以下，一次跳跃会中途换剪辑。也不用 `MovementInputHandler.is_moving` —— 与 D27 第 5 条同一条教训：**表现钉在实际状态上，不是钉在按键上**。
4. **`_on_landed()` 开头清闩锁，且必须走在 `fall_speed < MIN_LAND_IMPACT` 早退之前。** 轻落地不清的话，之后「走下台阶」会沿用上一跳的剪辑。走下台阶（没跳）保持现状播倾斜版 —— 刻意划的边界，不顺手改。
5. **顺带成立、但不当契约也不写断言的一条读法**：倾斜版只可能出现在世界冻结期间，直上直下只可能出现在世界流动期间。差一帧的缝有两处 —— `jumped` 在 `_apply_horizontal()` **之前**发（读到的 `velocity.x` 是上一帧的），以及松手后那 0.08 s 解冻缓冲里人还在减速。都不到 5 帧，肉眼分不出，写成断言只会变成 flaky。
6. **没做的一半**：`fall` 仍只有一套（带后仰 `dome_lean −1.0..−1.5`）。下落段比上升段长得多，「空中推方向键该不该改判」的窗口也随之变长，值不值得再来一套要看实机观感 —— 留给试玩定。

**验证**：`sprite_selftest` 第 1 段帧表加 `jump_straight`；第 5 段原地跳改断 `jump_straight`；**新增 5b 段**（跑起来跳断 `jump`，随后把 `velocity.x` 强行抹成 0 再断一次 `jump` —— 这条专门堵死将来改成「逐帧读速度」的实现）；第 7 段蹲姿起跳改断 `jump_straight`。四条守门全绿：`SPRITE SELFTEST DONE failures=0`、`[kit-selftest] done failures=0`、`VERIFY DONE doors=3 failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。

---

## 钥匙卡的持有表现（2026-09-20）

### D39 · 卡**含在体内**：钉在脚底的常量偏移 + 60% 半透明，不动立绘、不裁不遮罩

**用户提出（2026-09-20，原话）**：「我希望修改钥匙的持有方式，改为被小史莱姆吞在身体里」。选型问答定下「含在体内透出一点亮」。看完第一版对照图后追加裁定：**「可以不修改立绘，直接让钥匙卡跟随玩家，渲染在玩家图层上并半透明，就算移动时有部分在玩家体外也合理」**。

**结论**：

1. **只改画法，D30 的契约一条不动。** `held` 仍住在 `KeyPickup` 实例上、`consume()` 语义不变、拾取带仍是带心 −15 的 32×24、跟随仍走 real-time（D30 第 4 条后半句正是这条改动的地基：冻结期间玩家会动，卡必须跟着动）。节点**照样不 re-parent** —— `PlayerVisual` 带 `facing` 镜像，子节点会跟着翻。
2. **摆位钉在脚底，不钉在盒顶、也不钉在当前轮廓上。** 卡底 = 玩家原点 + `Player.COLLISION_HALF_HEIGHT` − `FOOT_GAP(3)`。理由是 D22 的脚底契约：脚底那条线永不动，而盒顶会随蹲伏（30→15）与落地压扁上下跳 —— 钉在顶上就得跟着状态机走，钉在脚底则**一个常量就够，不读帧、不问蹲伏、不看朝向**。
3. **卡缩到 10×6（原卡 14×10 的 0.7 倍）。** 按 idle 帧量：脚底上方 10–14 px 是那双眼睛，14×10 的卡贴上去正好整块盖住，半透明之后眼睛泛成两块琥珀斑 —— **比露在体外更糟**。10×6 的顶行刚好不碰眼睛，读起来是「吞下去的卡在肚子里」。
4. **alpha 取 0.6。** 对照图实测的「卡区亮度 vs 身体其余亮度」差：0.45 档在 `jump_straight` 上只剩 0.116（糊进黑身体里，看不出持有），0.6 档 0.199–0.257，0.75 档 0.281–0.305 但顶行开始啃眼睛。0.6 是「在体内」与「还认得出是那张卡」的分界。
5. **不遮罩、不裁边，露出体外算合理 —— 而这条正是方案便宜的原因。** 实测五档身形里只有 `crouch` 漏 3 px（蹲姿身体只有 13 px 高，卡占 6 + 离地 3），其余四档 `outside=0`。所以那条裁定几乎没被用上，但它换掉了整套机器：不用运行时读每帧 alpha、不用 shader、不用第二套帧图。
6. **层级是隐式依赖，记在这里。** 卡能压在主角之上，只因为 `Objects` 在场景树里排在 `Player` 之后（`level_template.tscn` 与 `level1.tscn` 都是 Triggers → Player → Objects），构件本身没有 `z_index`。**将来谁把 Player 挪到 Objects 后面，卡就会跑到身体背后**，那时要显式给 `z_index`。
7. **被否掉的另一半留个名字。** 选型第一版实现过「按当前帧的**实心带**摆卡 + 把同一帧按 62%/48% 盖回卡上面」：每帧的不透明行连续无孔到底部波纹才断，卡底坐在那条带上、横向取所选行跨度交集，于是卡**整块必然落在轮廓内**（30 格实测 `leaks=0`，本可写成 `sprite_selftest` 的硬不变式），且眼睛与舌头浮在卡前 = 真「在体内」。它更好看，但要在运行时读每帧 alpha 图，用户以「不动立绘」否掉。要回头做，`tools/gen_keyheld_preview.py` 的历史版本就是那条算式的参照。

**验证**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。**没加新断言**：这条改动是画面上三个常量（`FOOT_GAP` / `HELD_W×HELD_H` / `HELD_ALPHA`），唯一可静态检查的是「`FOOT_GAP + HELD_H ≤ 蹲姿美术高 13`」，一条编译期就能看出来的算术，不值得占守门的位置。像素级核对由 `py tools/gen_keyheld_preview.py` 出的对照图承担 —— 它用的就是引擎里同一条摆位算式（卡底 = `G.FEET_ROW - FOOT_GAP`，水平取 44 宽画布中心），所以图上看到的位置就是引擎里的位置。

---

## 刷卡门的开幕不吃时间（2026-09-20）

### D40 · 闩锁**当帧**撤幕：光幕只剩「满 / 无」两态，开幕不消费任何 delta（推翻 D36 第 9 条）

**订正（D41，2026-09-20）**：本条第 2 条「两态取代行程」与第 4 条「不保留那 0.5 s 动画」已被取代 —— 光幕改回**一拍自上而下逐行熄灭的演出**，同时把玩家的移动锁住。**诊断部分（尤其第 3、5 点）与「刷卡门不消费世界 delta」这条结论一字未动**，而后者正是 D41 敢把动画加回来的地基：演出跑在固定物理步长上，世界冻着也照跑。

**触发这条改动的反馈（2026-09-20，原话）**：「钥匙门的触发好像有点问题，似乎不是立刻触发的」。看完诊断后的裁定：**「门立刻打开，光幕直接消失」**。

**诊断（先把「哪里没坏」记清楚，免得下次重查一遍）**：

1. **闩锁本身一直是立刻的。** `_scan_reader()` 在 `_physics_process` 里跑、不吃世界 delta（D38 第 4 条），`Reader` 是门自己的 `Area2D`（layer 0 / mask 2，只认玩家）。玩家进带 → `pickup.consume()` → `is_latched = true` 同一帧完成。层值、带几何、轮询频率、`_physics_process` 与 Player 的先后顺序，逐条查过，都没问题。
2. **延迟全部在开幕那一段。** 旧实现的 `_progress` 由 `TimeReceiver.get_physics_delta()` 推进，而那个函数在 FROZEN 时恒返回 0 —— 于是 `if d <= 0.0: return` 直接把行程钉死。
3. **而且它必然发生，不是偶发。** 感应带外沿在门洞前 `width/2 + sensor_reach`（level1 实测 16 + 30 = 46 px），玩家**朝门走 = 必然按着方向键 = 世界必然冻结**。所以「带卡触发闩锁」这个事件 **100% 落在冻结态里**，而冻结态里光幕一步都不走。D36 第 9 条把钉住当成"最多停一步"的偶发代价，判断就在这里错了。
4. **玩家的体感账**：LED 当帧变青（唯一即时的反馈）→ 约 0.09 s 后（再走 23 px ÷ `move_speed` 260）撞在一堵**满高、实心、仍然亮着**的光幕上 → 必须松开方向键 → 再吃 `RELEASE_BUFFER_DURATION` 0.08 s 防抖 + `open_time` 0.5 s。最好情况 ≈0.58 s；中途再按一下方向键就原地钉住，于是读起来是"刷卡没反应"而不是"门在慢慢开"。
5. **同一条规则为什么没在按钮门身上暴露**：差别在**自然终态**。按钮的自然终态是「站上去、停手」= 已经解冻，门自己走完；刷卡门的自然终态是「进门」= 还在按方向键。所以那 6 行门控 delta 在一扇门上几乎不显形，在另一扇门上每次都显形。

**结论**：

1. **判据与契约一条不动。** 感应带仍是门的子节点、仍是带心 −15、`key` 仍是 `@export_node_path`、闩锁仍是一次性（true 只发一次、永不倒回）、`consume()` 语义不变、D38「接触即判不吃 delta」不变。**变的只有闩锁之后光幕怎么退场。**
2. **两态取代行程。**（**D41 已取代本条**，`_curtain_height()` 现在是三档） `_curtain_height()` 是唯一真值来源：锁着 = `height`，撤掉 = `OPEN_H(0.001)`。绘制侧先 `floorf()`，0.001 读成 0 → 整块不画；碰撞侧同一个来源 → D36 第 6 条 b 那条「画出来的 == 挡得住的」继续成立，只是中间态不再可达。留 0.001 而不是 0 与 `Door._apply` 同源：Godot 不接受零尺寸的碰撞形状。`height` 是小数时（level1 上摆的是 72.095）"往收的方向舍"那条理由仍然成立，所以取整没被顺手删。
3. **删干净**：`open_time` 导出项、`_progress` 字段、`_apply()`、`_physics_process` 里那 6 行门控 delta 累计、以及 `key_door.tscn` 的 `TimeReceiver` 子节点（连带 `load_steps` 5→4）。这张门从此**完全不消费世界时间**，是 M5 构件里唯一不挂 `TimeReceiver` 的一个，`DebugOverlay` 的 `time_receivers` 计数因此少 1（它只打印，不断言）。
4. **没走「保留行程但改吃 real-time」那条更便宜的路**（**D41 恰恰走了这条路**，但把「人在幕还亮着时往前走」那段窗口用移动锁堵上，而不是用「没有中间态」堵上），虽然它当时确实是选型时的首选方案、改动只有两行。理由：那样会留下一个「画出来还亮着的光幕挡不住人」的窗口（冻结中幕在灭、人还按着方向键往前走），而那正是 D36 第 5 条点名的破绽来源。两态**结构上不存在**这段窗口。代价是丢掉那 0.5 s 的逐行熄灭节奏 —— 用户选了代价小的那条。
5. **幕体的画法一行没改。** 残辉三行 / 半透明幕体 / 外侧光晕 / 左右亮收边 / 顶端断电前沿 / 底部接地行，全都在"满幕"那一帧画得出来，D36 第 7 条的定稿与 `tools/gen_props.py` 的 `paint_gate` 合成路径继续同源。改的是它有没有中间态，不是它长什么样。
6. **摆图后果**：刷卡门不再有「开多慢」这个可调量（**D41 把它以 `swipe_time` 的名义加了回来，但那是演出的长度、不是门"走世界时间"的速度**）。对一个**开了就永远开着**的一次性构件来说，那 0.5 s 唯一的作用就是让玩家多等，不构成谜题 —— 想要时间压力请用 `electric_bar.tscn`，它的相位本来就是为世界时间设计的（D35）。

**验证**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`（`EXPORTS` 白名单同步去掉 `open_time`，其余断言一字未改）、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。第 8 组按两态重写：锁着那一态断言「碰撞体挡满 32×96 且与 `curtain_rect()` 同一截」，然后**在闩锁断言与撤幕断言之间不放任何 `await`**，中间再插一条 `TimeManager.is_time_frozen()` —— 也就是"世界此刻仍然冻着，而幕已经没了"。这条正是旧代码会当场挂掉的断言，D40 的回归由它守；旧的「冻结钉住进度」三条按两态删掉。手感本身（松手不再必要、撞上去不再反馈矛盾）仍归试玩判定。**订正（D41）：这套「闩锁与撤幕之间不放 `await`」的断言结构随两态一起退役**，第 8 组改成按演出三拍采样。

---

## 刷卡门改成一拍演出（2026-09-20）

### D41 · 认卡后**先锁移动再演一拍**：卡从体内飞出并淡化、光幕同时自上而下熄灭，两头都跑完才把移动还回去（取代 D40 第 2/4 条）

**方案由用户提出（2026-09-20，原话）**：「我想到更好的实现方式了：在检测到玩家有钥匙时，玩家先禁止移动，钥匙从体内向上飞出并逐渐淡化消失，光幕同时逐渐消失，动画都结束后玩家恢复移动」。追问后两条裁定：**世界状态 = 「世界停着，演出在冻结的一拍里跑」**；**光幕退场 = 「自上而下逐行熄灭」**。

**为什么 D40 的顾虑这次不成立**：D40 否掉中间态，真正的理由不是"动画贵"，而是那句「会留下一个『画出来还亮着的光幕挡不住人』的窗口（冻结中幕在灭、人还按着方向键往前走）」（D40 第 4 条）。**移动锁把那段窗口整个删掉**：演出期间玩家走不动，所以"亮着的幕挡不住人"这件事根本没有观测者。D40 留下来的地基 —— 刷卡门一行都不消费世界 delta —— 正是这次能把动画加回来的前提：动画跑的那条钟本来就没人拦。这也正是本项目的取舍顺序里那条判断式的正例：**先问"露馅的窗口还在不在"，窗口没了才轮得到更好看的那半。**

**结论**：

1. **锁是 Player 上的一个布尔，不是一套状态机。** `Player.movement_locked` 只掐两件事：水平输入与起跳。水平轴收成唯一读点 `_horizontal_axis()`（`_apply_horizontal` 与 `_update_wall_press` 以前各读一遍 `Input.get_axis`，散在两处的锁迟早漏一处），锁住时返回 0 —— 于是走的是**既有摩擦分支**，人照物理减速停住，比把 `velocity.x` 钉死更不像撞到一堵看不见的墙；`_update_wall_press` 因此白捡同一效果（`side == 0` 直接返回）。起跳沿用 `is_head_blocked` 那条既有的「输入照读、动作抑制」写法，且**连缓冲区一起清**，否则锁一松人会自己弹一下。重力不掐：腾空时被锁照常落地。`respawn()` 归零。
2. **锁绝不碰 `notify_movement_intent`。** 玩家按着方向键 = 世界继续冻着，这一拍里世界**停着**（用户裁定的第一条），解冻时机仍然只由他松手决定。锁管的是"人别往前走"，不是"世界往前走"。
3. **门的钟 = `_physics_process(delta)` 的固定步长。** 这道闸只截 `TimeReceiver.get_physics_delta()`，截不到引擎自己传进来的 delta，所以 `_swipe_elapsed += delta` 在冻结中照样累计（沿用 D40 的"不吃世界时间"）。`_curtain_height()` 从两档改三档：满高 / `height * (1 - progress)` / `OPEN_H`，塌到底仍兜在 `OPEN_H` 而不是 0（Godot 不收零尺寸形状）。**幕体的绘制算式一个字没改**：底边永远接地、只有 `live` 变小 —— 所谓"自上而下逐行熄灭"就是既有算式在中间态下的自然读法，也是 D36 第 7 条与 `paint_gate` 同源那条没被破坏的原因。
4. **时长只有一个来源，两处共用。** `swipe_time` 只住在门上（默认 0.45 s），`KeyPickup.consume(fly_time)` 以参数收下它，卡这一侧刻意不留第二个常量。**卡的计时放在 `_physics_process`、绘制留在 `_process`**：画要跟着玩家此刻的位置（D39/D30 第 4 条的豁免通道），可钟要是也骑在帧率相关的真实 delta 上，掉一帧就会让卡先飞完、幕还在塌，那一拍当场散架。两条都吃固定步长 ⇒ 同一条钟 ⇒ 同拍结束。
5. **两条曲线刻意不同。** 卡用二次缓出（先窜后飘）读作「被吐出来」，同时尺寸从含着的 10×6 长回贴图原样、alpha 线性掉到 0；幕用**线性**塌，匀速下落读作「机器断电」。两个主语各走各的，都套同一条曲线反而糊成一团。没引 `easef()` 是它的 `curve` 方向反直觉（>1 是缓入），写算式比查语义便宜。
6. **LED 在演出开始的那一帧转青**（不是等 `is_latched`）。它是「认卡了、别硬走」的即时回执；等演完才变色，等于把回执延后到玩家已经开始按键之后 —— 那正是 D40 诊断里"只有 LED 是即时反馈"剩下的唯一一根，别砍掉。
7. **收尾顺序：先 `is_latched` + 碰撞归零，后解锁。** 反过来会有一帧"玩家已经能行动、门却还没让行"，就是 D40 要消灭的那个体感。
8. **挤压与卡死都无从发生。** 闩锁瞬间玩家前沿离幕面还有约 40 px（感应带 46 − 盒半宽 10 − 幕半宽 16），锁期间靠摩擦最多再飘 ~10 px（260 → 0 ÷ 3200），而幕**只缩不涨**（D36 第 10 条同一论证）；即使腾空被锁落下也在幕面之外。演出中途死亡 → `Main.reload_level()` 重建整棵场景，门与玩家都是新实例，`respawn()` 另外再兜一层 `movement_locked = false`。
9. **摆图后果**：多回一个可调量 `swipe_time`（真实秒数，与谜题无关，纯节奏），填 0 退化成 D40 那种一帧硬切。`key_door.tscn` 结构不变（**仍然不挂 `TimeReceiver`**，M5 里唯一不挂的那个），场景文件零改动。
10. **不做的事**：不给 Player 加通用「演出中 / 过场」状态机（这一拍只需要一个布尔）；不改 D31 粘性表 —— 回灌的仍是 `held` / `is_latched` 两条，飞卡与演出进度都是纯表现，重载即归位。

**验证**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`（`EXPORTS` 白名单加回 `swipe_time`）、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。第 8 组改成按三拍采样：**认卡帧**（卡已消耗、移动已锁、门**还**没让行、幕基本满、世界冻着）→ **演出中**（按住 `move_right` 位移严格为零、幕比上一帧矮、碰撞体 ≥ 画出来的且差不到 1 px、底边始终接地、卡与幕都在半路、世界仍冻着）→ **收尾**（有限帧内跑完、碰撞归零、不再画幕、卡同时飞完、移动已解锁、**解锁后按住右真的能走**——这条守的是"锁不会变成永久状态"）。`Input.action_press` 在无头自测里可用（`sprite_selftest` 已经在用），所以这是真输入路径而不是伪造读数。手感与节奏（0.45 s 是否偏长）仍归试玩判定。

---

## 死亡不再是一帧换场景（2026-09-21）

### D42 · 危险物点名后先演**收缩 + 爆裂**那一拍（0.55 s），世界被**强制冻结**钉住，演完才重载；D31 的「点名 → 关卡 → 常驻根」这条委托链一字未动

**触发这条改动的反馈（2026-09-21，原话）**：「玩家在碰到尖刺的时候什么都没有发生，我觉得应该播放死亡动画，然后回到存档点或者出生点」。选型后的三条裁定：**演出形态 = 「D 收缩 + 爆裂」**；**世界状态 = 「强制冻结定帧」**（钉住，与移动意图无关）；**时长 = 「0.55 秒」**（做成导出项，节奏留给用户在实机里调）。

**诊断（先记清楚"没坏在哪"）**：判死一直是好的 —— `HazardBase` 发 `touched_player`、`LevelBase._bind_hazards()` 全子树按信号名自动接线、D38「接触即判不吃世界 delta」在冻结里照样咬人。**"什么都没有发生"是"死得太快"**：旧实现里点名之后，`_death_pending` 只缓一帧（为了不在物理回调里 free 整棵关卡），下一拍 `_process` 就 `reload_level()`。于是玩家看到的是**同一帧里人没了 + 画面重画 + 自己出现在存档点**，视线找不到落点，读不出「我死了」这件事，只读得出「刚才是不是卡了一下」。

**选型（四套候选，一张图：`assets/player/preview_death_candidates.png`，算式与 `tools/gen_death_preview.py` 逐字同源）**：

1. **A 压扁 + 溅开** —— 否决：压扁这条形变通道已经被蹲伏（D26）与压墙（D21/D24 的 `wall_press`）各占一份，同一帧上再叠第三种压法，三条曲线迟早互相踩；且需要新的挤压帧。
2. **B 纯塌缩** —— 否决：只有缩放没有"散了"的证据，读作「被吸进去」而不是「被打穿」。
3. **C 击退 + 闪白** —— 否决：闪白要么占全屏（`CanvasLayer` 又多一个）要么占身体（`modulate` 已经被淡出用着），而击退要动速度，跟"死亡停摆"这件事本身矛盾。
4. **D 收缩 + 爆裂（选定）** —— 身体等比缩到一个点、同时上飘，14 滴同材质的液滴从胸口径向溅出、走抛物线落回脚底那条线就收。**零新帧、零粒子系统、零 `AnimationPlayer`**：液滴是两笔 `draw_rect`（先亮边后身体色，用的就是主角那道 `player_rim`），位置是解析式。收缩给「这条命没了」一个明确落点，液滴把它读回「小史莱姆散了」—— 与 D39 卡含在体内那套身体语言同一材质。

**结论**：

1. **时长只住一处。** `LevelBase.death_time`（默认 0.55 s）→ `Player.die(duration)` 收下 → `DeathBurst.launch(duration)` 再转一次。Player 与 DeathBurst 两侧都不留第二个常量，同 D41 第 4 条「两头共用一条钟才谈得上同拍收尾」。
2. **重载改由信号驱动，不再数帧。** `Player.death_finished` → `_death_pending = true` → 下一拍 `_process` 走 `_reload_level()`。**刻意不在 `LevelBase._process` 里数真实 delta 来判"演出该完了"**：那样"动画"走固定物理步长、"重载"走帧率相关的真实时间，掉一帧就会让重载抢在最后一帧前面，那一拍当场散架（D41 第 4 条同一个坑）。`LevelBase._process` 里 `_dying` 为真时直接 `return`，能力启用与终点收尾两段等待都让位给死亡。
3. **钉住走状态机本身，不走意图通道。** `TimeManager.set_frozen_override(true)` 写的是同一个 `current_state`，于是灰滤镜（`TimeFreezeFilter` 订阅 `state_changed`）、`TimeReceiver.get_physics_delta()`、`DebugOverlay` 计数全都自动读到同一个事实，不需要任何一处为死亡开旁路。**为什么不复用现成的 `notify_movement_intent(true)`**：它在 `is_ability_enabled == false` 时是**空操作**，而"能力还没拿到就撞上尖刺"是合法配置（引导关之前摆危险物是允许的）—— 用户裁定的「强制冻结」必须是"与能力开没开都无关"，那就不该借一条会被能力门控掉的通道。
4. **钉住期间意图整条通道静音。** `notify_movement_intent()` 顶上多一个 `or _frozen_override` 就返回。不加这一条会出这种画面：玩家死前按着方向键、看见尖刺那一刻松手 → 那一下松开启动 0.08 s 解冻防抖 → 世界在演出进行到一半时放回流动。锁归零只有一条路径：`reset_state()`（新关卡实例的 `_ready()` 必然调它，D31 的关卡级重置顺手承担了这件事）。
5. **尸体的停摆放在 `_physics_process` 最顶上。** `if is_dead: _advance_death(delta); return` —— 因为下面每一段都默认"这是一个还活着的人在动"，逐条加 `if is_dead` 早晚会漏一条（D41 的 `movement_locked` 只掐两件事，因为那是"暂时不能动"；死亡是"不再动"，口径不同）。`is_dead` 压过 `movement_locked`：死在刷卡演出里时门照样会把移动还回来，但那具尸体不该因此站起来走路。
6. **三处接缝按同一条口径堵：尸体不是玩家。** `key_door._scan_reader()` 里 `body as Player` 且 `is_dead` 就直接返回（不然能"刷卡带着尸体进门"）；`key_pickup._draw()` 里 `is_dead` 不画（不然卡会悬浮在缩没的位置上，正是 D39 那条"含在体内"的反面）；`player_visual._process()` 顶上 `is_dead` 时 `pause()` 后返回（不然刹车水花/落地挤压的剪辑会和收缩抢同一条 `_visual.scale`，两条曲线互相覆盖）。
7. **收缩算式**：等比缩到 `DEATH_SHRINK_MIN = 0.12`（留一个"缩没了"的落点，比凭空消失读得清楚，而这一刻透明度已经掉到 0），同时上飘 12 px（只缩不飘读作"被压扁"），收缩在 60% 处到位、淡出从 55% 起 —— **收缩比淡出先完成**，两条错开才不像"一起消失"。
8. **`DeathBurst` 挂在 Player 下、`Visual` 之后。** 之后 = 画在身体之上；挂 Player 而不是 Visual 之下，是因为 Visual 正被演出缩着，液滴不该跟着一起缩。出射点在胸口（脚底上方 12 px，从脚底溅读作"脚下打滑"），回收线就是脚底那条 `FEET_Y` —— **D22 脚底契约在演出期间不再是硬约束（人都散了），但爆裂的位置账仍然按它算**，所以读起来是"在地上被打穿"而不是"半空里爆了个气球"。液滴位置是解析式（`p = p₀ + v·t + ½g·t²`），没有状态要维护，重载即归零。
9. **一个数换一条注释，别拿循环解析去换。** `DeathBurst.FEET_Y` 刻意写死 `15.0` 而不引用 `Player.COLLISION_HALF_HEIGHT`：Player 已经按类型引用 `DeathBurst`（`@onready var _death_burst: DeathBurst`），反向引用常量就成了 GDScript 的循环解析。改那条常量时记得回来改这里（注释已写明）。
10. **F6 直跑要兜底。** `_reload_level()` 拿不到常驻根（`world_root` 组里没有）时改走 `get_tree().reload_current_scene()`。以前这里静默 no-op 无所谓（单关直跑看不出差别），现在不加就是"尸体永久钉在冻结里"—— 演出把这条老路径的代价从"看不见"抬成了"卡死"。
11. **不做的事**：不上 `GPUParticles2D`（14 滴定长定轨的液滴用 `draw_rect` 更便宜，而且和选型图逐像素同源）；不上 `AnimationPlayer`（正式构件与关卡里没有一处用它，只有 M1 的验证体 `test_cube` 挂着它 —— 为什么不用见 `door.gd` 第 10 行与 D6 给 pendulum 记的那条"无跳变要靠肉眼判断"）；不给"复活淡入""无敌帧""尸体留存"留钩子 —— D31 那条「回存档点而不是原地复活」的裁定把它们全废了。

**验证**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。`verify_kit` 侧：`EXPORTS` 白名单加 `death_time`，关卡契约新增一条「Player 下必须有 `DeathBurst`」（`player.gd` 用 `@onready $DeathBurst` 拿它，少了这个节点要到人真的撞上尖刺才露馅）。第 9 组按死亡那一拍重写：**刚死时不重载** → **能力没开也钉得住冻结**（`not is_ability_enabled and is_time_frozen() and is_frozen_overridden()` —— 这条正是"借意图通道"那版方案会当场挂掉的地方）→ 进度落在开区间、`Visual.scale.y < 1`、液滴已挂上 → **按住 `move_right` 的尸体位移恒等为 0** 且 `elapsed_world_time` 一字不涨 → 轮询到重载**恰好一次**、液滴自己收摊 → 整个演出实测占 20~60 物理帧（下限守的是"别又换回一帧重载"，上限守的是"别卡在半途"）→ 原有的「死亡重载不清 `run_state`」与回灌四条一字未动。**一个踩到的坑记下来**：`Area2D` 的 `body_entered` 不会在改 `global_position` 的同一帧出现（要等物理服务器把移动后的形状冲一次），所以判死那一拍在测试里是**轮询"什么时候死"**，不是赌固定帧数 —— 第 7 组那条既有的「人站进光束照样被判死」也是同一条理由才成立的。手感（0.55 s 是长是短、收缩读不读得出"死"）仍归试玩判定。

## demo 的范围就是 level_1（2026-09-21）

### D43 · demo 只做 `level_1` 一张：不选关、不接关卡链、终点不触发演出、音频延后；入口改用**已有的** `Main.level_scene` 指过去，F6 直跑的代价从"少个滤镜"升级为"存档点静默失效，开局响一次"

**裁定原话（2026-09-21）**：「我正在搭建 level1，目前的 demo 只需要先完成 level1，不需要选关，所以终点也没有必要触发什么。音频系统可以预留位置，但目前不是主要工作，可以等到搭建完之后修缮游玩体验时添加。」

**被砍掉的一半（留名，别当新发现再提一遍）**：M5 收口后我做了一次全项目体检，把「F5 进的是引导关、`level_1` 不被任何场景引用」与「终点没有完成反馈」列成两条 P0，建议加关卡链与收尾那一拍。**两条都被这张裁定废掉**：单关 demo 不需要关卡链，也不需要"通关"这件事。M4「第一章 3~5 个谜题关」照旧排在后面，本条只是把 demo 阶段的边界钉住，**不是取消 M4**。

**顺带纠出的事实（这条才是本条的实体）**：`LevelBase` 拿 `run_state` 走 `world_root` 组（`_world_root()`），而 F6 跑的是当前打开的场景、不经过 `main.tscn` —— 于是**踩存档点不记位置、死了直接回出生点，且一声不吭**。手册 §9 那条 F6 代价清单还停在"没有灰滤镜、没有调试面板、R 键无效"，那是 D31/D42 之前写的：**同一句"已知沙盒限制"，代价已经变了**。一个摆图的人如果在 `level_1` 里死一次发现没回到存档点，第一反应会是"存档点坏了"，而实际是"这条链根本没在场"。

**决定**：

1. **入口用已有的旋钮，不加新代码。** `Main.level_scene` 本来就在（手册 §9 推荐的跑法写的就是它，D28 那条讲的是关卡自动发现取代白名单，两回事），只是从没在场景里被填过：现在 `main.tscn` 把它指向 `res://scenes/levels/level_1/level1.tscn`；`INITIAL_LEVEL` 退为"没指路时的兜底关"，注释已改成这个口径。留空即回引导关 —— 这条语义一字未动。
2. **静默失效改成响一次。** `LevelBase._warn_no_world_root()` 在 `_ready()` 最开头判 `_world_root()`，拿不到就 `push_warning` 一次（不放 `_world_root()` 里：它被 `_apply_run_state()` 与存档点写入反复调，会变成每帧刷屏）。警告文案直接给出两条出路（用 F5，或指 `level_scene`），因为它面向的是正在摆图的人，不是修 bug 的人。
3. **终点"什么都不触发"已经能做，不用改代码**：`goal_restart_delay` 填 0。要提醒的是**默认值不是"没行为"** —— 1.5 s 之后走 `restart_level()`，而那个函数 `run_state.clear()`，等于「走完终点 = 存档点与进度全归零」。摆图期若不想每次试跑都被清空，把这一项填 0。
4. **不做的事**：不写关卡队列、不做通关结算、不接音频（全项目至今零 `AudioStreamPlayer`，M3「反馈层」照旧包含它，只是排到地图搭完之后）；不给 `level_scene` 加"多关数组"的扩展钩子 —— 那正是本条砍掉的东西。

**验证**：`verify_kit` 的关卡白名单是**按根节点脚本类自动发现**的（`_discover_level_scenes()` 递归扫 `scenes/levels`，不看目录名也不看白名单），所以 `level_1` 早在门禁覆盖内，摆错原点、缺 `PlayerSpawn`、刷卡门没配对钥匙、危险物上了 sensor 层都会当场 FAIL —— 本次没有扩任何守门。四条仍全绿；`doors=3` 就是它扫到引导关与 `level_1` 两关的结果。F6 那条警告只在无常驻根时出现，`kit_selftest` 不受影响。

## 祭坛与存档点的美术与演出（2026-09-21）

### D44 · 祭坛换 A1「阶梯石台 + 悬浮核心」，授予那一拍 = 核心浮起 → 飞入玩家体内 → 三枚青色菱形环向外扩散；整段跑**真实 delta**，**不吃世界 delta、不碰 `TimeManager`、不锁移动**

**裁定原话（2026-09-21）**：「B2，祭坛用 A1，不过我希望获得能力的时候有一段酷炫的动画，表现玩家获得了能力」。随后两条旋钮他也裁了：**不要**真的把世界钉住那 0.45 s（选「纯视觉环 + 核心入体」）、主角身上**不留**常驻核心（选「只在演出那 1 秒里亮」）。

**选型图**：`assets/props/preview_altar.png`（`py tools/gen_props.py --altar`，与实装同一个绘制调用）。四套候选都按 `width`/`altar_height` 的真实尺寸画未耗 / 已耗两态，主角站在中间作尺度参照，最后一条 496 px 全景带用来判"隔多远还认不认得出"。

1. **A0 现状（实心梯形）** —— 否决，且它连"候选"都不算：未耗是一坨琥珀、已耗是一块比夜光墙还暗的灰，换装幅度全在颜色上，轮廓一字没动。
2. **A1 阶梯石台 + 悬浮核心（选定）** —— 唯一把"那份能力"画成一个**离开石头悬在半空的东西**的方案。于是"踩上去 = 把东西从石头上取走"这件事不需要任何动画就已经读得出来，授予那一拍只是把这个既有事实演一遍。已耗态凹槽里留一圈烧灼青印，"东西被拿走了"要留在石头上。
3. **A2 图腾柱 + 灯罩** —— 否决：横向只占 28 px、靠高度取胜，确实适合窄位，但灯罩和门/终端的顶灯是同一个形状语言，摆在一起会读成"又一盏灯"而不是"一台给东西的机器"。
4. **A3 光井 + 上升光柱** —— 否决：零件最少、最便宜，但**已耗态几乎什么都不剩**（一圈井口 + 一道淡印），"我来过这里、我已经拿过了"这条常读事实直接消失。

**诊断（先记清楚为什么不能烤成一张贴图）**：`level1.tscn:55-58` 里用户把祭坛设成了 `width = 46.955` / `altar_height = 37.92` —— 两个尺寸都是**活旋钮**，摆图时正在用。所以 A1 不能像终端那样 `--emit` 成一张固定 PNG（那会让他的摆图作废、加载时还报未知属性），必须走 `Door` 那条路：**16 px 零件双向平铺，中心件用常量偏移居中**（`door.gd` 第 254 行那句"width / height 填任意值都对得齐，导出项不保证是 16 的倍数"就是本条的依据）。

**订正（一条一直没被发现的游离）**：`ability_altar.gd` 原来那串琥珀 `Color(0.98, 0.82, 0.42)` **从来不在 `props.json` 里**，是构件自己的字面量 —— 也就是说它是全项目最后一个没跟着风格 g 走的构件，`verify_kit` 的颜色同源检查一直查不到它。本条把它并进零件，顺带删掉 `active_color` / `spent_color` 两个 export（三个关卡场景零引用，已核）。`width` / `altar_height` / `sensor_height` 三个保留。

**结论**：

1. **零件清单**（`--emit` 落 PNG + 进 `props.json.parts`，`verify_kit` 比尺寸与颜色）：平铺件 `altar_base` 16×16、`altar_shaft` 16×16、`altar_cap` 16×8；居中件 `altar_groove` 18×6、`altar_burn` 18×6、`altar_core` **28×16**。柱面缝保持 16 周期，与瓦片同一套规矩 —— 石台和墙放一起时缝要对得上。（订正：核心件本条初稿写 16×16。实现时把光晕**烤进零件的真实 alpha** —— 选型图那版"柔光"是 PIL 直接往 RGBA 上写不混色的色块，引擎侧根本不需要第二张图，16×16 装不下那圈晕，故 28×16。）
2. **时钟只有一条：真实物理 delta。** `AbilityAltar` 新写的 `_physics_process(delta)` 用的是 Godot 传进来的那个常量步长，**刻意不查 `TimeReceiver`**。理由与 D40/D41 同源但方向相反：踩上祭坛那一刻玩家通常在跑，能力 arm 的时机又要等到他停下（D16 静止即启），这两条通道里世界状态随时可能是 FROZEN —— 演出若吃世界 delta，就会在"世界冻着、玩家还站着看"这种合法组合里**卡在半途**，而这一拍恰恰最需要"不管世界怎样都一定演完"。
3. **三段节拍，总长 `grant_time = 1.05 s`（导出项，节奏留给实机调）**：0.00 核心从帽顶浮起、石台**同帧**换成已耗态；0.00~0.35 核心飞向玩家胸口（追 `_courier.global_position` 加常量偏移，玩家照常能跑能跳）；0.35 入体 —— 三枚由小到大的青色菱形框从玩家身上向外扩散淡出（0.25 s），同时主角那层青色亮 0.45 s 后熄。菱形是 A1 核心本来的形状，环是它的放大版，所以"从身体里散出来"和"这颗核心"是同一个图形语言，不需要新造型。
4. **不锁移动、不碰 `TimeManager`（用户裁定）。** 代价记下来免得以后当新发现再提：这一拍**不改变任何世界事实**，所以它是纯装饰 —— 玩家看完动画并不会因此知道"按住方向键世界会停"，机制教学仍然只有 D16「静止即启」那一条。放弃的那条路（用 D42 已有的 `set_frozen_override()` 真的钉住 0.45 s、让灰滤镜当场亮一次）技术上完全现成，收尾只需补一行 `notify_movement_intent(handler.is_moving)` 重算状态；它被否是因为**用户不想要一段"我按不了"的演出**，这个理由足够，不需要再翻。
5. **主角标记只在演出内亮（用户裁定）。** 代价同样记下来：能力"是否已持有"没有常读痕迹，玩家要确认只能按方向键看世界停不停。实现上这条比常驻版更便宜 —— 亮的那 0.45 s 不新增节点、不动图集像素。（订正：初稿写"走 `PlayerVisual` 已有的 modulate 通道"，实现时改挂 `Player.flash_granted()`。理由与 D42 同一条：`_visual.modulate` 这条通道由 Player 独占（淡出写的正是同一个 Color 的 `.a`），而 `PlayerVisual` 的职责只是挑剪辑，两边不该抢同一个属性 —— 所以提亮写进 `player.gd` 的 `_physics_process` 顶部，且排在 `is_dead` 早退**之前**，人死在演出里时这一档也要走完，不能停在半亮。）
6. **复活不重播。** `mark_spent()` 的原语义（摆成已耗、不发信号、不进演出）一字不动，`_apply_run_state()` 那条路径因此天然绕开这一拍 —— 第一次踩上去的演出属于"当帧发生的事"，重载后的世界里它已经发生过了。
7. **`is_granted` 仍然在 `body_entered` 当帧置位**，早于演出结束。玩家在这一拍里再踩同一格无事发生；`checkpoint` 与 `hazard` 都是这个口径，不特殊化。

**验证**：`verify_kit` 换了祭坛那行的导出项名单（`width` / `altar_height` / `sensor_height` / `grant_time`，两个已删的颜色 export 顺带钉住"不许回来"）、断言占位 `Visual` 节点已删、`CORE_COLOR` 与 `props.json.altar_core` 同源、`altar_shaft` 缝行比别处暗、`altar_cap` 首行比第 5 行亮、`altar_core` 的 (14,12) 是青色（挑在中心那条近白亮带之外，免得检查被亮带糊过去）。`kit_selftest` 加第 10 组，正面钉本条第 2 条：踩上去**之前**就用 `set_frozen_override(true)` 把世界钉死（能力没开 + 钉住 = 世界一定不流的最狠组合），断言那一拍照样起来、进度继续推进、世界时间一字不涨、演完自己收摊；外加身体那一档亮起后逐位回到 `Color(1,1,1,1)`（`.a` 没被碰过），以及半路 `die()` 当场收摊。第 9 组补一条「回灌只摆样子不重播那一拍」。四条守门全绿：`VERIFY DONE doors=3 failures=0`、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。**这些守门钉不住的两件事**：演出来酷不酷、`grant_time = 1.05 s` 这个长度合不合手 —— 前者只在 `assets/props/preview_altar.png` 的 A1 行与 A1b 行（47×38 = `level_1` 正在用的尺寸，对位检查摆图会不会错位）上看图，后者留给实机手感，旋钮已留在检查器里不用回来改比例。

### D45 · 存档点已存态换 B2「加一档常亮」：`terminal_saved` 从 32×12 长到 **44×16**（整块屏更亮 + 顶上一盏灯 + 地面两侧各一条青边），一次性换装、**不做动画**

**裁定**：同一张选型图 `assets/props/preview_altar.png` 的 B 行，用户拍板 **B2**，否决 B1（一次性向上脉冲）与 B3（终端背后立信标）。原话是「存档点的动画反馈不是很明显」。

**诊断**：现状两张零件图 `terminal_idle` / `terminal_saved` 都是 32×12，唯一差别是屏内那条 1 px 横线在不在 —— 换装幅度全在**一块 24×6 的区域里少了一个像素级元素**。2x 摆图视角下分不出，实机 1080p 更分不出，所以"不明显"不是配色问题，是**差别没有加在轮廓上**。

**结论**：

1. **三处差别全部加在竖向与横向尺寸上**：屏整块提亮、顶灯比原台顶再多 **3 px**、地面两侧各 6 px 青边。三条都是"换了个形状"而不是"换了个色"，扫一眼就能和没存过的终端区分开。（对件核对：`terminal_saved` 画布 44×16，实画内容只占第 1~15 行 —— 顶灯顶到 15 px 高，而未存态整张就是 12 px 高，所以**竖向增量是 3 px 不是 15**。这条读法的主力是那 12 px 宽出来的青边和整块屏提亮，竖向只补一刀。）
2. **不做一次性动画，是被 B1 的否决顺带裁掉的**：存档点的职责是把"我在这儿存过"留成一条**常读事实**，而 B1 那一闪过后什么都不留 —— 玩家回头看不出这台到底存没存。所以本条只强化状态，不加时间轴；这与 D44 恰好相反（祭坛是一次性事件、演完就完，存档点是长期状态），两条不是同一件事的两种做法。
3. **同一构件两张不同尺寸的零件**：`terminal_idle` 32×12、`terminal_saved` 44×16，都按**底边中心**对齐（节点原点仍是贴地的底边中心，与门/按钮/祭坛同一套约定），`_draw()` 一次 `draw_texture`、偏移按各张自己的尺寸算 `(-w/2, -h)`。刻意不给 idle 也补一圈透明边把两张凑成同尺寸 —— 那会让未存态的可见轮廓不变而零件白胖一圈，`props.json` 的尺寸同源检查就查不出"少画了东西"。
4. **摆图后果（进手册 §8）**：已存态比未存态**高 3 px、宽 12 px（两侧各 6 px）**。终端正上方 3 px 内如果有低矮天花板或悬挂物，会被顶灯压住（差 1 px 就会看着像长进天花板里，别拿这个当余量）；地面两侧那 6 px 是纯装饰、不参与碰撞，但会盖住紧邻的地板接缝。
5. **传感器带不动**：`BAND_W 32` / `BAND_H 24`、带心 `-Player.COLLISION_HALF_HEIGHT` 全部原样 —— 本条是表现层，不碰判定（D38 接触即判那条契约与零件尺寸无关）。

**验证**：`verify_kit` 钉两条 —— `terminal_saved` 必须**严格比 `terminal_idle` 又宽又高**（两张尺寸都从 `props.json` 现读，不是抄进检查里的字面量，所以以后谁把零件改回同尺寸会当场红），以及已存态 (21,2) 那一格必须是亮色（顶灯灯芯）。传感器带那条既有断言（`BAND_H 24` / 带心那条线）原样通过。`kit_selftest` **刻意没加新组**：本条零新行为，唯一的行为面"踩上把重生位写进常驻根"第 9 组早就钉着，为一张贴图编断言只会多一条会跟着像素改动的假红。选型图那条坑记在这里免得下次再踩：D45 之后落盘的 `terminal_saved` **本身就是 B2**，所以 B0/B1/B3 三行必须拿一张 `legacy`（32×12 的改前已存态）去演示，否则这张图会变成"用已批的方案演被否的方案"。**守门钉不住的**：三处差别到底够不够"一眼分得出存没存" —— 只有 `assets/props/preview_altar.png` 的 B 行与用户的眼睛判得了。

### D46 · 冻结态的视觉符号**从「灰」换成「CRT」**：`freeze_crt.gdshader` 挂进既有 `ColorRect`，参数一字未改（linearFac 1.3 / scanLineFac 0.10 / 色散开），淡入淡出从顶点 alpha 迁到 `strength` uniform

**裁定**：用户贴来一段现成 CRT fragment 代码并提出「冻结的时候用这个 shader 渲染屏幕」。我按项目那条老规矩（表现层先出图、图用真帧）先做两件事：`tools/frame_grab.tscn` 开窗抓 `level_1` 真帧，`tools/gen_freeze_filter_preview.py` 把那段算式离线复现到这些真帧上，出 A~E 五格选型图 + 同一批探针的对比度读数。用户回：**「A，取代」** —— A = 他给的那组参数原样（`linearFac 1.3` / `scanLineFac 0.10` / 色散开），"取代" = 确认冻结的符号从灰改成 CRT，明知选型图上标出的青门芯发白与削顶（离线那版 24 855 像素，实拍这版更多：31 682）仍然要它。

**诊断（灰版不是一个安全基线，这条是量出来的）**：现状那层 `Color(0.5,0.5,0.5)` × alpha 0.20 把语义色**全部削暗**：`cyan/wall 2.69 → 2.18`、`amber/wall 4.44 → 3.33`、`steel/wall 3.13 → 2.49`、主角白边对墙 `9.51 → 6.36`。也就是说"换掉灰"这件事本身不亏可读性，问题全在换过去之后那 1.3 倍提亮会不会把亮部顶穿。

**结论**：

1. **路线不动 D8 那条**：一块全屏 `ColorRect` + `hint_screen_texture`，**不加 SubViewport、不建渲染目标、不加第二道 pass**。两条抽头（nearest / linear）指向同一张屏幕纹理，差别只在采样器 —— 想整幅糊成低分辨率必须降内部分辨率，那是被否的 E 行的代价。
2. **淡入淡出换通道**：旧版把强度挂在 `_rect.color.a` 上，而 canvas_item 的 `fragment()` 一写 `COLOR` 就把顶点色丢了 —— 直接接上 shader 会让滤镜**硬开硬关**，画面照样"对"，只有逐帧看曲线才发现。所以强度改成 uniform `strength`，算式末尾 `mix(原图, CRT, strength)`；`strength == 0` 时整段分支跳过 = 逐位拷回屏幕。`transition_speed = 12` 与那条指数平滑一字未动（收敛约 0.58 s）。
3. **参数就是用户那组，没有"顺手调优"**：`linearFac 1.3` / `scanLineFac 0.10` / `scanLineWidth 0.25` / `nearestFac 0.0` / 色散 `0.001` 开。他原代码里那个 `crt_enabled` 布尔总开关**没保留** —— 这一层的开关已经由 `TimeFreezeFilter` 的 `visible` 决定，材质里再放一个总开关等于同一件事两个真值来源。
4. **接口与层序原样**（D8 第 3 条兑现）：仍然只订阅 `state_changed`，仍然 `LAYER_INDEX = 100`，仍然只读不写任何冻结判定；关卡与 `TimeManager` 一行没改。今天 `Main` 下没有 HUD，所以被滤镜吃进去的只有关卡本身；**将来 HUD 必须落在 ≥ 200**，否则会被扫描线和 1.3 提亮一起改动。
5. **代价（实拍读数，4×4 平均，spot2/spot0 真帧）**：五对里四对**高于不冻结的原帧** —— `cyan/wall 2.69 → 3.02`、`amber/wall 4.44 → 4.53`、`steel/wall 3.13 → 3.20`、主角身体对墙 `2.14 → 2.81`；唯一降的是主角白边 `9.51 → 7.23`（仍远在 D26 那条 4.5 下限之上）。真正付的是**余量不是对比度**：31 682 个像素至少一个通道削到 255（全帧 3.4%）。具体两处：亮白钢 `(206,222,250)×1.3` 三通道全削平 → 冷白变中性白；琥珀 `(250,190,74)` 的 R、G 双通道削顶 → 指示灯发"烫黄"。**后果记死**：D29 那套「青 = 光与电 / 琥珀 = 可拾取 / 亮白钢 = 会咬人」从此**只靠色相分、不靠明度分**（实拍 amber `(255,235,91)` vs steel `(188,198,219)` 还分得开）；以后想在同一格里用"再亮一档"表达"可拾取"，在这套滤镜下走不通。
6. **晶格 `const vec2 RESOLUTION = 320×180` 是写死的**：只在 1280×720 窗口下正好一格 = 4 设备像素 = 2 世界像素（相机 zoom 2）。窗口拉成非整数倍时这道格会跟 16 px 网格打摩尔纹。D43 已把 demo 钉成单关 + 固定窗口，这条代价今天付得起；真要支持任意窗口尺寸，改法是拿 `1.0 / SCREEN_PIXEL_SIZE` 推格数，不是把 320×180 调大调小。
7. **死亡那一拍（D42）共用这一层** → 定帧现在也是 CRT，不再是灰。D33 那条「不新增第三种全屏色调、死亡不配独立滤镜」因此更吃重：两种状态**共用同一套符号**，区分只剩 D42 的收缩 + 爆裂与"世界本来就停着"这件事本身。这是用户"取代"二字明确接受的口径，不是实现遗漏。

**实测踩到的四条**（都便宜，但都会静默咬人，写在这里免得下次重新发现一遍）：

- `fragment()` 里**不许 `return`** —— Godot 着色器语言直接 `SHADER ERROR: Using 'return' in the 'fragment' processor function is incorrect`。原代码那个 `if (!crt_enabled) { COLOR = ...; return; }` 必须改成"局部变量算完、末尾一次写 COLOR"。
- 屏幕纹理采样要用 **`SCREEN_UV`** 不是 `UV`。`UV` 是"本像素在这块 ColorRect 里的位置"，恰好铺满时两者重合，所以这条错了也不当场红 —— 一旦那块矩形挪动或不满屏就整体错位。
- 新建 `.gdshader` 的 uid 还没被运行中的编辑器扫进缓存时，`.tscn` 里写 `uid=` 会报 `invalid UID ... using text path instead` 并回落到路径。**只写路径**，编辑器下次保存会自己补上。
- **无头不编译着色器**（Compatibility + dummy renderer），语法错了也一声不响。所以 `tools/frame_grab.tscn` 从此兼任 shader 的编译检查：开窗跑一次、stderr 干净才算过。

**验证**：四条守门全绿 —— `VERIFY DONE doors=3 failures=0`、`[kit-selftest] done failures=0`、`SPRITE SELFTEST DONE failures=0`、`TILESET SELFTEST DONE failures=0 checks=308`。`kit_selftest` 加**第 11 组**：无头不验像素，只钉材质挂着裁定那组参数、层序仍是 100，以及那条最容易静默弄死的通路 —— 强度**一帧一帧爬**（第一格非零必须 < 0.9，淡入死了就是 1.0）、单调涨到满、解冻后往下溶而不是硬关、溶到底那块矩形不让画。这一组刻意**按值等而不按帧数等**：淡入是真实 delta 的指数平滑，而无头的 process 帧不是每秒 60 拍，按帧给预算等于掷硬币（第一版就是这么红的）。开窗那条：stderr 零 shader error；同算式离线复现与实拍两帧逐通道平均差 ≤ 1.0、最大 26、`|d| ≥ 3` 只占 0.4~1.1% 的通道样本 —— 那三条近似当真帧过了一遍 GL。选型图 `assets/ui/preview_freeze_filter.png` 加 **F 行（实拍）**，与 A 行并排就是那三条近似的当场检验；灰版旧底片 `spot{0,2}_gray.png` 留在盘上当"换之前长这样"，抓帧脚本不再覆写它。另有一条抓帧器自己的坑值得记：主角的剪辑跑在**真实 delta** 上（他是时间的载体，世界冻着照旧呼吸），raw 与 filter 两张帧隔一拍 → 他的轮廓自己动了，第一次读到的 `maxdelta=250` 全是这个、不是滤镜炸了；现在开场 `set_process(false)` + `pause()` 把他钉住（与 D42 死亡那一拍同一个机关）。**守门钉不住的**：这套扫描线 + 色散好不好看（已由用户看图裁定）、窗口尺寸一变摩尔纹长什么样、以及 0.58 s 这条淡入时长实机合不合手 —— `transition_speed` 是导出项，拧它不用回来改比例。

### D47 · 新构件「残影踏板」：一只喷嘴定时生成一串下坠体素，流动期穿得过去、世界冻结时整条变实体

**裁定**：用户提出一种"像 Minecraft 里的沙子、一直下坠、没有实体，但世界冻结时能当踏板踩"的方块，并问有什么东西既满足这套机制又贴实验室主题。主题走**候选 2 = CRT 余辉 / 残影体素**。理由不是它好看，是它**不新增设定**：D46 已经把"冻结"这个状态的视觉符号定成 CRT，那么"画面被钉住的那一刻，一直在落的东西被钉在半空、成一串能踩的实体"就是同一套符号的推论。源头 = **天花板上一只喷嘴定时连续生成**（不是玩家触发、不是离散脉冲），解冻时**穿透**（用户原话"解冻应该是穿透的"），并且用户明确判定**这个方块不算违 D11**。

**一条被推翻的旧前提（选型图第一版就是照它画的，必须留字）**：第一版把构件画成"最下面一格实心 + 上面两格鬼影尾迹"，好像只有最新那一格硬。**这条区分不存在。** 世界冻结时整条链一起停，每一格同时变实体；要让它只硬一格，就得额外加一条"只有最后生成的那格算"，而那条跟"冻结 = 万物停"正面矛盾。所以图上的"尾迹"根本不是某一格的残影，它就是链上相邻的下一格。改过来之后，真正要选的轴只剩一条：**冻结态已经定死（实心青 + 亮白顶唇 = 和实体瓦片同一套话），流动态用什么话说"穿得过去"。** 选型图上 A~D 四行的冻结列几乎一模一样，不是省事，是这条轴的诚实结果。

**一条新发现的机制后果：单列不可能是梯子，它是"抓时机"。** 站在第 i 格顶唇上，两脚要升高 `P` 才能落到上一格；头在脚上方 30 px，而上一格的**底边**在脚上方 `P − 32`，于是头先撞上的条件是升高 `P − 62` —— 想在脚到位之前不撞头需要 `P − 62 ≥ P`，恒不成立。往旁边挪也不行：格宽 32（±16）、玩家盒宽 20（±10），头要完全避开上一格得横偏 ≥ 26，可那样脚就离开这一格了。**结论：这一列只能从外面跳进去，不能沿列往上爬。** 于是它的动词从"爬梯"变成"**跳起来、趁某一格落到脚下时冻结**"——正好是本游戏的核心动词，比梯子更值钱。副作用要说清：**它永远不会压到人**，因为它移动时无形、有形时不动（"冻结 = 它也不动"这条是承载安全的那根柱子）。**（订正：这句已被 D48 收窄。"不推人、不顶人"仍然成立，但"永远不伤人"不成立 —— 冻结那一刻脚还在格子里 = 判死。**）

**数值（全部导出项，改数不改结构）**：

| 项 | 值 | 怎么来的 |
| --- | --- | --- |
| `fall_speed` | **400 px/s 常量** | 玩家 −400 起跳落回同高的落地速度对称地正好 400，所以"和玩家下坠同速"这条**肉眼判据**在常量 400 上成立 |
| `emit_interval` | **0.20 s** | 见下面那条上限公式 |
| 节距 `P = V × T` | **80 世界 px = 5 个瓦片格** | 落在 16 px 网格上，编辑器里对齐 |
| 格尺寸 | **32 × 32 世界 px = 2 格** | 与 `BLOCK_W` 选型图一致 |
| 同屏格数 | **房间净高 ÷ P** | spot2 这帧空气 171 px → 2.1 格 |
| 一次跳跃期间链下降 | **0.97 × 400 = 388 px** | 滞空 0.97 s（`m2_level_01_layout.md` §0 的 −400 档） |

**"间隔大点"的上限在哪**：要读得出"这是一串一直在落的东西"，屏上至少得同时有 **2 格**，即 `T ≤ 房间净高 / (2V)`。这帧的空气给出 T ≤ 0.21 s，所以 0.20 已经**贴在这条线上**——再大就变成"偶尔掉一块"，那已经不是这个构件了。这条上限是**每间房各自算**的：房间越高，允许的 T 越大。用户要的"大间隔"已经给到这条边界，代价是同屏只剩两格，图上看得见。

**机关：一条都不新增。**
- 碰撞走既有约定：冻结时 `collision_layer = time_solid(4)`（`MovingBlock` / `Door` / `KeyDoor` / `ElectricBar.Blocker` 全在这一层，玩家 `mask = 5` 读得到），解冻时 `collision_layer = 0` 且 `mask = 0`。切换只在**物理通道**上做，走 D1/D13 那条与输入意图绑定的判定，不吃 process delta（这台机器上 process 是物理的 2.4 倍）。
- 极性是 `hazard_base.gd:39 is_live()` 的**反面**：危险物是"世界停我就不咬人"，这个构件是"世界停我才存在"。两者都每物理帧扫一次、都不吃 delta，所以照抄那个形状，不新建第三个时钟。
- **位置是 `elapsed_world_time` 的纯函数**：第 n 格在 `y = y0 + V × (elapsed − n·T)`。不存状态、不累加 delta，于是按 R 重开、存档回灌、冻结期间天然停在原处，三件事一起免费。发射器只管"当前时刻链上有哪些 n"，落出房间下沿的 n 直接不画不碰。

**视觉选型与读数**（`tools/gen_afterimage_preview.py` → `assets/props/preview_afterimage.png`，底图 = 真关卡帧 `spot2_raw.png`，冻结列整帧过 D46 那组同算式 CRT，比例尺 = 真立绘 ×2）：

| 行 | 流动态 | 冻结 peak/墙 | 流动 peak/墙 | 判定 |
| --- | --- | --- | --- | --- |
| **A** | 薄壳：亮青描边 + 极淡填充 | 5.1 | 3.4 | **选定**（= 用户先前批的"D 的骨架 + A 的尾迹"在新前提下的落点） |
| B | 扫描线横条（8 设备 px = 2 晶格） | 5.1 | 2.9 | 留档：跟 D46 同一套语言，但墨迹只有 76%，细看像"没加载完" |
| C | 整条链连成一束光，冻结时断成台阶 | 5.1 | 3.6 | 留档：两态反差最大、"这里有东西在落"最强，代价是流动期读不出格的边界 |
| D | 只剩一条竖直拖影 | 5.1 | 3.3 | 留档：墨迹 66%，"穿得过去"给到了，但格子到底在哪儿看不清 |
| E | 冻结态改借**地皮**色（`surface` + gummy 点阵） | 3.0 | 3.4 | **死路，记账**：想修 A~D 共用的那条 `body/door 1.7`，结果 `body/wall` 从 5.1 掉到 2.2 —— 地皮色本来就贴着背景墙，借它等于把自己抹掉 |

**遗留的一条读数要说白**：A~D 的冻结格对背景墙 **5.1**（D26 的 4.5 下限之上，达标），但对紧挨着的那扇青门只有 **1.7** —— 两者同属 accent 家族。E 已经证明换填充色救不回来，所以这条**只能靠形状和摆位**：门有边框 + 竖板条 + 通高，格是 32 见方 + 顶唇一道亮白，实拍图上分得开；真正的约束是**别把喷嘴摆在离 `KeyDoor` 一格以内的地方**（写进关卡手册 §5 的摆位条目）。

**被否的备选**：
1. **主题候选 1（培养液滴落 / 冷凝水）** —— 满足机制但和"冻结 = 画面被钉住"没有因果关系，是另一套设定，D46 刚把符号收敛到 CRT，不该同时存在第二套。
2. **加速下坠（照抄玩家的重力 980）** —— 相邻两格的间隔是 `g·t·T + ½gT²`，随下落时间线性涨：新生那两格只隔 19.6 px（**比格宽 32 还小，等于互相穿模**），落到 0.5 s 时已经涨到 118 px。也就是说"整条都是台阶"只在一条窄带里成立，而这正是这个构件的立身之本。常量速度换掉的正是这条。
3. **只有最新一格硬** —— 见上面"被推翻的旧前提"，与"冻结 = 万物停"矛盾。
4. **玩家触发式发射（踩按钮掉一块）** —— 退化成 `MovingBlock` 的换皮，丢掉"它一直在落、你只能挑一个瞬间"这个核心。
5. **让节距 < 32 好"密成一根柱子"** —— 玩家盒 30 高钻不进格间净空，且读不出是一串离散的东西。

**关卡侧硬约束**：① 喷嘴正下方这条列**必须是净空**，否则格在出生帧就埋进地形；② 构件不能跨在 `HazardBase` 的杀区上（杀区 `layer = 0, mask = 2`，格无形时玩家会直接穿进杀区，等于一个"只有冻结时才存在的坑"，太阴）；③ 摆位离 `KeyDoor` ≥ 1 格（理由见上）。**它不解决"跨沟"**：单一源头 + 恒定节距意味着任何沟都能靠"等一格落到对岸"过掉，真要卡跨沟得给发射器加门（`Switch` 控制它开不停），那是关卡的事，不是构件的事。

**验证口径（实装时补）**：`verify_kit` 加一条"冻结时该格在 `time_solid` 上、解冻时 `layer == 0 && mask == 0`"；`kit_selftest` 钉三件最容易静默弄死的事——**位置纯函数**（同一 `elapsed` 两次求值逐位相同）、**切换只在物理通道**（喂 process delta 不该动碰撞层）、**重开无残留**（回灌后链与首次运行同相）。着色器那条老规矩照旧：无头不编译像素，最终好不好看得开窗看。

**实装补记（2026-09-21）+ 一条订正**

**订正**：上面「机关」第 3 条写的是"位置是 `elapsed_world_time` 的纯函数"。**实装不是直读那个全局量**，而是构件自己存一份 `_clock`、每物理帧加 `TimeReceiver.get_physics_delta()`（抄 `ElectricBar` 的写法）。理由：`elapsed_world_time` 是 `TimeManager` 的全局账，第二章锚点系统走 `set_time_source()` 劫持的是**每个消费方自己的那条 delta**——直读全局量的东西劫持不到，等于白丢第二章的免费通道。公式形状一字未改，只是自变量换成了这份本地 `_clock`。

- **落点**：`scenes/objects/afterimage_emitter/{.gd,.tscn}`。两态皮是 `_draw()` 里现画的矩形（流动 = 亮青描边 + `alpha 46/255` 淡填充 + 两道内侧竖线；冻结 = 实心青 + 1 px 描边 + 顶唇两道亮白），**没走 `gen_props.py` 的零件 PNG 管线**：这皮的形状就是"格"，尺寸两个旋钮（`step_size`/`reach`）连续可变，烤成图反而要为每个尺寸重出一次。代价是那串色（`110,230,240` / `206,222,250` / `61,127,132`）与 `tools/gen_afterimage_preview.py` **各写一份、改一处要改两处**，与 `key_door.gd` 的 `Color8(110,230,240)` 同一族游离色。**（订正：流动那一支已被 D48 换掉 —— 用户判定亮青描边太硬、读不出"虚"，改成渐变余辉；冻结那一支一字未动。）**
- **实装才发现的一个坑（已在两条守门里钉住）**：池子按 `max_steps` 建、链按 `reach / P` 画，默认就是 **8 vs 5**。第一版 `_apply_layers()` 遍历整池，于是冻住的那一刻多出来那 3 格带着**最后待过的位置**上了 `time_solid` —— 看不见却能踩的隐形平台，正是 D36 第 6 条"碰撞体 == 画出来的"要拦的东西，而它在选型图与静态代码审查上都看不出来。已改成只有链上那几格上层。顺手把 `reach` 的 setter 从"只重画"改成"重算"（`active_steps()` 是它的函数，不然加长了链的新格子会带过期位置被上层）。
- **松手那 0.08 s 链多踩得住**（`RELEASE_BUFFER_DURATION`）：解冻防抖期间 `TimeManager` 的状态仍是 `FROZEN`，本构件只看门控 delta，所以**跟着缓冲一起多存 0.08 s**。这不是漏洞，是这个构件在解冻方向上唯一的"余味"，写关卡节奏时当一条已知量用（门的节奏账 §8 里那条 0.58 s 是同一件事）。
- **冻结那一刻人可能正好和某一格重叠**（流动期他刚穿过去）。当前**不做特判**：`CharacterBody2D` 会被 `move_and_slide` 从重叠里恢复出来（与 `MovingBlock` 顶到人同一类，那边已有"限速避免脱困瞬间弹射"的先例）。留给试玩判定是不是难受，不在构件里加逻辑。**（订正：这条已被 D48 推翻 —— 用户判定"脚还在格子里时冻结"应当判死，构件现在确实为此加了一条逻辑，见 D48。）**
- **两条守门实际钉了什么**：`verify_kit._verify_afterimage()` 静态一遍 = 脚本里不许出现 `func _process(`（"切换只在物理通道"最直白的写法）、默认参数（节距 80 / 链上 5 格 / 池 8 格）、每格独占一份形状资源、每拍后位置 == 公式值、相邻格恒差一个节距、最新一格不出出生窗口、冻结/解冻两侧的层值与"不许挪"、改 `step_size`/`reach` 后盒子与格数跟着重算。`kit_selftest` 第 12 组跑真帧 = 冻结 12 拍时钟不走链不挪、**松手 2 拍仍在缓冲里链照旧踩着**、**真玩家脚底对准第 3 格的踩面：冻着 20 拍不下沉、解冻 40 拍掉到踩面以下一个身位**、新实例同拍数重跑与首跑同相（最大偏差 0.0 px）。四条守门 `failures=0`（`kit_selftest` 现为 12 组）。**（订正：D48 改了这两条守门钉的东西 —— "节距 80 / 链上 5 格 / 池 8 格"那档不再从脚本导出默认值读，改由守门自己显式设一份**参照档**，脚本默认值只受结构检查（`1 ≤ 链上格数 ≤ 池`、`P > 格宽`）。原因：`fall_speed`/`emit_interval` 是用户拿手感调的旋钮，守门绑在上面就等于拿试玩参数当契约，他一拧两条守门一起红。）**

### D48 · 残影踏板订正两条：流动态换"渐变余辉"软皮；冻结那一刻脚还在格子里 = 判死，而站在踩面上绝不伤人

**裁定**：用户看了 D47 的实装提两条。① "在没变实体时，边框太过明显，改成更像残影的美术风格"。② "玩家在没实体的踏板内部时如果冻结世界玩家也应该死亡"，并补一条硬的（记作 ③）："还有玩家站在冻结的踏板上时，踏板不应该伤人"。**②③ 合起来才是这次的真活**：判死必须在"脚在格子里"和"脚在格子上"之间切出一条缝，而这条缝的宽度不是拍脑袋定的（见"缝有多窄"）。

**② 不是新增机制，是补 D47 欠的那一条**：D47 只说了"流动期穿得过去、冻结时整条变实体"，把"冻结那一刻人正好和某一格重叠"留给试玩。用户这次把它定死成规则：**你只能挑"一格刚好落到脚下"的瞬间，挑错了就死**。这和 D47 那条"单列不可能是梯子、它是抓时机"是同一件事的两面 —— 没有代价的时机不叫时机。它不违 D11（用户先前已判定这个方块不算违）。

**判死的形状：脚底探针，不是整身盒子。** 三个候选里选了最窄的那种：
1. **（否）整身盒子与任一格相交就杀** —— 与③正面矛盾，而且是量出来的矛盾：站在冻结的踩面上，上一格的**底边**在脚上方 `P − 32 = 48`、头在脚上方 30，净空 18 px；可一解冻链重新下坠，上一格在约 0.02 s 内就把这 18 px 吃掉、把头吞进格子里。此后他**只要再按一次冻结就被自己刚踩过的格子点名**，"站在踏板上绝不伤人"直接破。要让候选 1 和指令 ③ 同时成立，就得给"头被蹭到"单开一条豁免 —— 那等于绕回候选 3。
2. **（否）挂一个 Area2D 传感区** —— 判死区一律 `layer 0 / mask 2`（D29 的层契约、手册 §5 那条扫描），而本构件是 `Node2D`，为一条瞬时判定改型不划算；更实的问题是传感区靠物理帧异步刷新，"冻结那一刻"要点名的人得等下一帧才点得到，而这条判定的语义就是**那一刻**。
3. **（选）脚底 2 px 高的横带 × 格子内缩 2 px**：`step_rect(i).grow(-KILL_INSET)` 与"脚底 `FEET_PROBE = 2 px`"求交，只在**冻结上升沿**（`solid` 由 `false` 变 `true` 那一拍）判一次，命中即 `touched_player.emit(hero)` 然后 `return`（一次冻结最多杀一次，不给下游重复点名）。头蹭一律不算。

**缝有多窄（这条是实测出来的，不是挑出来的）**：人稳稳站在踩面上时，`move_and_slide` 把接触解算到浮点残差 —— 实测穿透 **−5.1e-6 px**（`kit_selftest` 第 12 组把这个数打出来了）。也就是说"站着的脚"几乎不嵌进格子里，离内缩后的判定边界还有整整 2 px 余量；往下，陷进格子不到 2 px 时冻结不算死，读起来是"脚刚沾上、差一点点"放过了，这条留给试玩手感，真嫌宽就把 `KILL_INSET` 往 0 收 —— 但收之前得先把候选 1 那条 18 px 的头部问题想清楚，它就是死在那里的。**代价写明白**：这是一条"按宽松方向偏"的判定，偏 2 px，而 2 px 在 32 的格子上是 6%。

**订正（2026-09-23，用户试玩后一句"把 emitter 的 2px 判定改为 5px，降低难度"）**：`KILL_INSET` 从 2.0 拧到 **5.0**。方向先说清，因为这一条容易读反：**内缩变 = 杀区变 = 更宽松** —— 脚底要陷进可见踩面以下 **5 px**（原来 2 px）才算"被钉在里面"。上一条把它留给试玩的那个旋钮，第一次被拧的就是这一头，而且拧的是它原本就偏的那一侧。**代价写明白（这次换了一边）**：D48 美术那条 1 px 踩面亮线的职责是"让人看清脚落在哪一道"，而规则现在说的是"落进这一道以下 5 px 才杀"，两者之间多出一截**看着陷进去了却没死**的窗口 —— 表现比规则凶，偏的是不杀人的那一侧，用户认了。三条没动：`FEET_PROBE` 仍是 2 px（那是"只问落脚点、头蹭不算"那条口径，不是难度旋钮）；上限由 `verify_kit` 那条"内缩带不许塌"钉着（`inset < step_size / 2`，默认 32 的格子内缩后 22×22，`level_1` 那台没覆盖 `step_size` 所以还有 11 px 余量）；判死仍然只在**冻结上升沿**判一次。守门顺带修掉一处抄第二份数：第 12 组那条"实测穿透留在内缩带里"以前硬写 `< 2.0`，等于把常量复制进了断言，拧到 5 之后它会变成一个假紧的界；现在它从脚本读 `KILL_INSET` 并把数字打进消息里（与 D53 那条"时长只有一个来源"同一个教训）。"把脚按进格子 20 px 必须点名"那一档相对新带子的边际从 18 px 缩到 15 px，仍然稳。

**机关仍然一条都不新增**：
- 判死走 D29/D42 已有的 `touched_player` 契约：`LevelBase._bind_hazards()` 是按**信号名**在子树里扫的，摆进场景树即生效、不连 NodePath；`_on_hazard_touched` 里那对 `_dying or _death_pending` 守卫正好覆盖"死亡那一拍里又冻了一次"这种自问自答，不需要新加守卫。构件因此**不是** `HazardBase` 的子类（它没有 `is_live()` 那套极性），只借这一条信号名。
- 几何从每格自己的 `global_transform` 现算（新加 `step_rect(i)`），不查物理、不靠 `area_entered`：于是旋转/缩放天然正确、零帧延迟，而且**无头跑得动**。
- 只在 `solid != _was_solid` 的上升沿跑，流动期一条信号都不发 —— 与 D47"流动期穿得过去"一字未改地共存。
- 读玩家盒子走新加的 `Player.collision_rect()` **只读**访问器。立场与 `HazardBase` 那条"判死不引用 Player 内部"一致，只是方向相反：这次是构件要读玩家，那就给一个公开的，不让它去伸手进 `_body_rect`。

**美术：流动态从"描边壳"换成"渐变余辉"。** D47 的 A 行（亮青描边 + 淡填充 + 两道内侧竖线）在实机比例下读起来是"一个空框"，不是"没被钉住的东西"。换法：整格改成上→下 `alpha 26 → 72` 的竖向渐变（`draw_polygon` 顶点色，**不打描边**），格子上方再拖一段"上一格刚待过的位置"的 `0 → 34` 渐隐尾，然后只在**踩面**留一条 `alpha 110` 的 1 px 亮线。最后那条不是装饰 —— ②③ 一落地，"脚落在哪一道"从审美问题变成生死读数，皮再虚也必须让人看清踩面。选型图（`tools/gen_afterimage_preview.py` → `assets/props/preview_afterimage_flow.png`，底图仍是真关卡帧 `spot2_raw.png`，冻结列整帧过 D46 那组同算式 CRT；D47 那张 `preview_afterimage.png` 留档不覆盖）：

| 行 | 流动态 | 流动 peak/墙 | 墨迹 流动/冻结 | 判定 |
| --- | --- | --- | --- | --- |
| A | D47 旧皮（对照） | 3.4 | 100% | 被本次推翻：边框太硬，读不出"虚" |
| **F** | **竖向渐变 + 上拖尾 + 一条踩面线** | **2.2** | **99%** | **选定 = 实装** |
| G | 只留尾，格体几乎空（peak 8 → 26） | 1.8 | 60% | 留档：最虚，但墨迹掉到 60% 后格子的边界读不出来 |
| H | 格心发光、一根线都没有 | 2.4 | 73% | 留档：没有任何线，脚落点最难读 |

三行的**冻结**列读数一字不差（peak/墙 **5.1**、body/墙 5.1、body/门 **1.7**），因为冻结那一支没动；D47 遗留那条"喷嘴离 `KeyDoor` ≥ 1 格"的摆位约束照旧有效。流动 peak/墙 从 3.4 → **2.2** 是这次唯一实质变低的读数，但 D26 的 4.5 下限管的是"要读得出它在不在"，而流动态要传达的语义恰恰是"它是虚的、穿得过去"，往低走是这条语义要的方向；真正的可读性底线由那 1 px 踩面线兜（`LIP` 色对墙仍约 5 档）。

**守门钉了什么**：`verify_kit._verify_afterimage_kill()` 静态一遍 = `touched_player` 信号还在（改名即**静默失效**，因为 LevelBase 按信号名接线）、身上不许长出 Area2D（长出来就绕过了"判死区一律 layer 0 / mask 2"那条扫描）、`step_rect(0)` 宽高 == `step_size` 且中心 == 那格的 `global_position`（画的、踩的、杀的必须是同一个矩形）、内缩带没塌、且**内缩带的上沿必须在格子自身上沿之下**（这一条直接钉住③：谁把 `KILL_INSET` 改成往外扩，站在踩面上立刻变判死，守门先红）。`kit_selftest` 第 12 组加五钉：站在冻结的踩面上 20 拍**零信号**、把实测穿透量打进 2 px 带里、解冻 10 拍后再冻结"上一格已压到他身上（`true`）但脚底是虚的 → 不判死"（这条同时证明那条豁免**真的被走到过**，否则整钉是空跑）、把脚按进格子 20 px → **恰好一次**信号且点名的就是他、流动期整条链穿身而过**零信号**。四条守门 `failures=0`。

**记账（用户自己的旋钮，不擅自改回）**：他把脚本默认值拧成 `fall_speed 800` / `emit_interval 0.40`（未提交）。合起来节距 `P = 320`，配 `reach 320` 时**同屏只剩 2 格**，正好压在 D47 那条"至少 2 格"的上限线上（净高 171 px 的房连 2 格都不够）；且 800 px/s 不再满足"和玩家下坠同速 = 400"那条肉眼判据。这是手感决定，守门也已经解绑（见 D47 那条订正），但**写关卡节奏时按 800×0.40 算，别再按 400×0.20 那档**。

### D49 · 新构件「活塞踏板」：一只被按钮布尔量驱动的积分器（**没有自己的时序**）；原点钉在收回态的前缘，"挤开"是让玩家自己的身体去撞墙

**裁定**：用户三条口径（原话）——"控制一组方块。1. 挤开 2. 掉下去没问题"、"按这个方案实现，名字用 piston_block"、"选 B 青光踏板，生成最终纹理"。**第 1 条是他否掉我的推荐**：我原来推荐"穿过"（伸出路上撞到人就不推），他定成活塞推得动人；第 2 条把"从正在收回的方块上掉下去"判为可接受，于是这块不需要任何"人站在方块上被带走"以外的保护逻辑。

**这块没有自己的时序**，是与 `moving_block` 的分工线：那块自带往返摆（有自己的相位），这块只有一个被按钮布尔量驱动的积分器 —— 按住就朝"伸出"走、松开就朝"收回"走，两个方向速度不同（伸出慢到踩着按钮的人跟得上，收回快到站不住）。位置是伸出量的纯函数这一条与门同源，差别只在"伸出量由什么决定"。冻结时只吃门控 delta，所以停在当前伸出量上、解冻续走。

**为什么是积分器而不是两段动画**：被人顶住、走不满行程是这块的**常态**（见下面那条夹前缘），而"停在半路"必须是合法状态而不是动画的中间帧。动画那套要么跳到下一关键帧、要么倒放不干净。

**节点原点 = 收回态的前表面中心**（洞口线在中轴上那一点），这是"原点 = 底边中心"通则之外的第三个特例，前两个是电棒 = 光束中心、残影踏板 = 喷嘴口。这条约定白送三件便宜事：① 摆图时把原点对准墙面/地面那条线就行，伸多远由 `travel_offset` 说，不用再对半个方块；② 收回态整块身子在洞口**里面**，露在外面的只有"伸出量"那一截，于是皮只画露出的那一截，不需要遮罩也不需要裁边；③ 前缘的投影坐标恰好等于原点的投影坐标 —— 让位算式里少一项。**顺带证伪了一条旧注释**：文件头曾写"收回态那截身子被地形盖住"，而 Objects 排在 TileMapLayer 之上，盖是盖不住的；成立的是②那条"干脆不画"。

**"挤开"这条算式的顺序是承重的**：伸出时先让**玩家自己的身体**去解算（新加的 `Player.push_by`，里面走 `move_and_collide`、只改位置绝不碰 `velocity`），他照常撞地形，背后有墙就停在那儿；我们随后按他**停住之后**的后缘夹住自己的前缘，一寸都不许多走。于是"他推不动"和"我走不动"是同一件事，不需要第二条挤压判定，也不需要门那套 `cast_motion` + `intersect_shape` 双探针（那套是 StaticBody2D 改尺寸推不动人逼出来的，活塞推得动人）。收回时整个跳过：那时前缘正从他脚下退开，把他往墙里推才是错的。

**`collision_mask` 写死 0**：这块的位移不由物理解算，是从伸出量直接落位置。若照 `moving_block` 那样带上 terrain(1)，收回态那截身子整块埋在墙里 = 起点就重叠，而 `move_and_collide` 从重叠状态起步会把整段位移原样退回来 —— 活塞一辈子钻不出洞口。代价是一条摆放约束（手册 §5）：行程扫过的那条带子里，除了洞口那一截，不许有地形。

**"一组"= 一个按钮接多块，接线写在块上**（同门的口径）。多对一**刻意不查重**，那正是"一组"的写法 —— 与钥匙那套"一卡一门"相反。构件之间没有 group、没有互相引用，所以"一组"这个词在代码里不存在，它只是同一个 `trigger` 被写了 N 次。

**伸出量从实际位置回读**（`progress()` 读的是 `global_position`，不是累计量）：被玩家顶住时这个数自己就不涨，于是脱困那一帧不会把欠下的行程攒成一发弹射 —— `moving_block` 得靠速度封顶做同一件事，这里靠读回来。

**行程只认主轴**：`travel_offset` 取 |x| 与 |y| 大的那一维，另一维忽略（斜着伸出的 AABB 构件没有唯一的"前缘"，让位量就算不出来）。两维都写了值且差出一像素以上时进树打一次警告。

**皮：B 档「青光踏板」，`_draw()` 现算，不是贴图**。选型图（`tools/gen_piston_preview.py` → `assets/props/preview_piston.png`，底图仍是真关卡帧 `spot2_raw.png`，钉住那一列整帧过 D46 那组同算式 CRT）：

| 行 | 皮 | 流动 peak/墙 → 钉住 | body/墙 | lip/门 | 中列墨迹 | 洞口墨迹 | 判定 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | steel + collar：钢身 + 铆钉 + 前缘亮白 + 钢鞘 | 3.8 → 4.0 | 3.5 | 1.9 | 96% | 38% | 否：与地皮、与那扇青门都拉开距离，代价是"这块不属于地形"要和玩家的教育成本一起付 |
| **B** | **cyan plate：暗身 + 顶面实心青** | **5.0 → 5.1** | **2.2** | **1.9** | **100%** | **42%** | **选定 = 实装** |
| C | terrain + lip：身体就是那块地皮 + 一道地唇 | 3.1 → 3.7 | 2.7 | 1.9 | 100% | 29% | 否：免学费，但身体对背景墙的对比度天然低，全靠顶唇那两像素 |

B 的代价在选型图那行字里就写明了：**屏幕上一共三个青的东西，且它跟危险物同族**（残影踏板的冻结格、那扇青门、电棒）。用户认了这条，换的是"能踩/带电"这套话教会一次就够 —— 青与亮白两个色值与 `afterimage_emitter.gd` 的 `STEP_SOLID` / `STEP_LIP` 同源，描边那一档 `darker(青, 0.45)` 就是那边的 `STEP_EDGE`。过程化绘制的理由与残影踏板同条：`block_size` 是导出量，固定尺寸的 PNG 在改边长时会糊，而 `_draw_skin` 里所有数字都写成"沿行程轴多远 / 离中轴多远"（`_skin_point` / `_skin_rect` 两个换子），改边长等于整张皮跟着缩放。**代价也照旧**：那串色与 `gen_piston_preview.py` 各写一份、改一处要改两处（D47 记过的那族游离色又多一处）。不提供逐实例调色（第一版有个 `block_color` 导出旋钮，随定档一并删）。

**实拍器 `tools/piston_skin_shot.{gd,tscn}`** → `assets/ui/frames/piston_skin_b.png`：两行四列 = 竖直/水平两个行程方向 × 收回 / 半路流动 / 半路钉住（真 shader）/ 满行程。必须有窗口（headless 下渲染是空的）。它抓出两条，一条真错、一条假错：

- **真错：运动线索在满行程后永远亮着。** 线索的门禁是"半路且世界在流"，而 `progress()` 读的是实际位置经父级变换一个来回，满行程处读回来是 `0.9999999` —— 裸比 `now < 1.0` 永远不成立。选型图看不出来，因为离线那张的 `e` 是自己喂进去的精确值。已改成两端都走 `is_equal_approx`，理由写进 `_physics_process` 的注释。这条与 D48 那条"实测穿透 −5.1e-6 px"是同一族：**凡是拿浮点位置判端点，就得带容差**。
- **假错，更值得记的一条：量皮的尺错了。** 第一版量出"整张皮落在前缘外面 30 px"，横排也指着同一方向，推理链每一步都有数 —— 错在取景框按"视口中心 = 相机位置"反推，而 `Camera2D.anchor_mode` 默认是 top-left（节点位置其实是屏幕左上角）且关卡相机 `zoom = 2`；探针又挑了身体色 `Color8(18, 24, 40)`，而那正是图集的 `screen` 色，于是量到的包围盒是墙。现在框的位置由 `get_canvas_transform()` 把"洞口线→满行程前缘的中点"投影对准，每列把前缘/洞口线的**格内设备像素**打进日志，量色带位置才有基准；重测三档（描边框、实心青带、亮白唇）与算式逐像素对上。教训：**量渲染结果之前先量自己的尺**。这与 D46 那条"屏幕空间的层必须用真帧 + 同算式 + 实拍出图"同族但方向相反 —— 那次错在复现算式不同源，这次错在测量基准不同源。**这条假错当时已经被写进 `_draw_skin` 的注释，当成"不转画布"的理由**（"实拍第 1 列量出来皮顶比真实前缘还高 30 px"），一并改回实话：换成 axial/lateral 两个换子仍然要做，但理由是"少一个能接错的角度参数"，不是"那一版画错过"。

**守门钉了什么**：`verify_kit._verify_piston()` 静态一遍 = 脚本里不许出现 `func _process(`（这台机器上 process 是物理的 2.4 倍，照它走位等于伸出量随帧率抖）、layer/mask 必须 4/0、默认档碰撞盒 64×64 @ (-32,0)、**横竖两轴各钉一次"前缘落在原点那一侧"**（洞口约定是让位算式的地基）、改 `block_size` 后派生几何整组重算且**不波及同场景另一块**（D21 那个共用 sub_resource 的坑）、斜 `travel_offset` 夹到主轴、满行程处 `progress()` 读得出 1.0。`kit_selftest` 第 13 组 20 钉，四档各一条"改坏了不会响、只有试玩才露馅"：a) 两块接同一个按钮 + 冻结 12 拍一格不挪 + 冻结中松开只记意图 + 解冻一起收；b) 收回拍数不到伸出的一半（只断言量级，不赌整数拍）；c) 竖着伸出那块把人带到骑上踩面且前缘贴脚底不吃进身体、收回走完时人还在半空（是他自己在落，不是被带着沉）、掉回地面脚底顶在 y=0；d) 背后没墙时人被他自己的身体让出行程且满行程前缘仍贴着他后缘一寸不多走、背后立墙时他自己撞停 + 这块走不满行程 + 顶住期间前缘始终贴着他后缘（挤压在这个结构里不发生）。四条守门 `failures=0`（`kit_selftest` 现为 13 组）。**唯一那条红的是 `level_1/level1.tscn` 里 `Objects/KeyDoor` 没接 key —— 那是用户未提交的关卡编辑，不属于本构件，也不由我修。**

**参照档（钉在测试里，不是脚本默认值）**：行程 1~6 格；伸出 60 px/s；收回 240 px/s；站得住的时长 = 伸出长度 ÷ 240（64 px 那一档 = 0.27 s）。摆图与手感判定归用户，`extend_speed` / `retract_speed` 是他的旋钮，守门只钉"收回明显快过伸出"这一条量级关系。

**砍掉/延后（落档，不当缺口重提）**：
- **活塞之间互不解算**：`_resolve` 只读玩家、mask 写死 0，两块行程对穿时它们会互相穿过。要做就得给同组块按轴投影夹一次，而第一版没有这种关卡。落档成摆放约束（手册 §5），不当 bug。文件头原来那句"一组活塞要能互相挡住对方的满行程"是**没实现的说法**，已改成实话。
- **逐实例调色**：不提供，理由同上（与按钮/门/残影同一条口径）。
- **把活塞摆进 `level_1`**：摆图归用户，本构件目前只活在 `tools/piston_skin_shot.tscn` 这一张实拍里。
- **"人站在收回中的方块上被带着沉"的保护逻辑**：用户那条"掉下去没问题"直接把它划掉，且 c) 那三钉量出来本来就不会发生。

### D50 · `level1.tscn` 的"大文本场景"警告：**暂存不修**，但测量结果与四条候选方案先落档

**裁定（2026-09-22，用户原话）**："暂存这个警告但不修复，目前加载速度没有问题，等到出问题了再修改。" 触发的是编辑器对 `res://scenes/levels/level_1/level1.tscn` 的提示：基于文本的场景占 956.7 KiB，疑似含嵌入二进制。**动它的前提是真出现加载/保存卡手，不做预防性重构。**

**测量（省得下次重做一遍）**：956.7 KiB 里约 99% 是两行超长 base64（整个文件只有 107 行）。

| 层 | 格数 | 文本量 | 是什么 |
| --- | --- | --- | --- |
| `Terrain/WallFill` | **47 256** | **738 KiB（全文 77%）** | 背景填充，铺满一个 **264×179 的完全实心矩形、全用同一格图**（这一档解码自洽：264×179 恰好等于格数，零空隙、零重复） |
| `Terrain/Tiles` | 13 676 | 214 KiB | 真正手摆的地形（bbox 填充率约 61%，压不出更小的表示） |
| `Terrain/Decor` | 11 | 0.2 KiB | 基本是空的 |

**一条诚实的限制**：`tile_map_data` 的字节布局我**没有真的确认**。按"每格 12 字节 / 6 个 int16"解 `WallFill` 干净得挑不出毛病，解 `Tiles` 时有一列冒出 0x3000 / 0x5000 / 0x6000 这类标志位样式 —— 要么对齐漂了，要么那层的记录更宽。**将来真要修，别把这份解码当规格用**，先按 `TileMapLayer` 的运行时 API（`get_used_cells()` / `get_cell_*`）读，不要手解字节。

**代价现在落在哪里**：不是运行时（装载几十毫秒级，用户实测没感觉），而是① 编辑器每次保存全量重序列化，② **git diff 彻底不可读** —— 这条已经在实际影响协作：对 `level1.tscn` 一律只看 `--stat`、不跑正文 diff。

**四条候选（真要修时从这里起步，不必重新论证）**：

1. **只关警告**：编辑器设置 `filesystem/save_on_write/warn_about_large_binary_resources`。零风险、什么都不修，代价是以后真塞进别的大二进制也没人提醒。
2. **`WallFill` 换成"存矩形 + 装载时填充"**：文件直接掉到约 220 KiB。**要先查的那件事已经有答案：`WallFill` 无碰撞**（手册 §12 那张表），所以它是纯背景，填充时机只要早于第一次绘制。代价是编辑器里不能再手擦这块墙的局部（今天它没有任何手擦痕迹，所以这条现在不花钱）—— 真要保留"可擦"，得再加一份排除清单，明显更贵。
3. **拆 `wall_fill.tscn` 子场景**：主场景同样降到约 220 KiB，仍然全文本、仍可整层 paint。代价是编辑时多开一个子场景，且 `verify_kit` 的"三层 TileMapLayer"发现口径要跟着挪。
4. **转二进制 `.scn`**：最省事也最不划算 —— 只把 956 KiB 变成约 600 KiB，却废掉文本 `.tscn` 这条工具箱依赖（手写场景文本绕开 MCP、守门里 `load()` 路径、diff 可读性）。

**How to apply**：别再主动把"关卡文件太大 / 那条警告"当缺口提；他报加载或保存卡手时才回到这一条，并且从候选 2 起步（先确认那面墙有没有被手擦过）。

### D51 · 粘性进度补两处「有读、没人写」：祭坛已耗真的记账，存档点全关卡唯一激活

**起因（2026-09-22，用户提的两条代码层面问题）**：① 死亡复活后能力应保持已获得、祭坛不该刷新；② 存档点只能有一台处于激活状态。两条的根因不是逻辑写错，而是**读路径在、写路径整条不在**。

**根因 ①**：`LevelBase._apply_run_state()` 从 D31 起就在读 `state.get("altar_spent", false)`，读到就把能力直接开启并叫祭坛 `mark_spent()` —— 但**游戏代码里没有任何地方写这个键**。踩祭坛那条链只走到 `_begin_ability_sequence()`（置 `_awaiting_ability`）。全项目唯一写它的一行在 `tools/kit_selftest.gd`（第 9 组为测回灌手搓的），所以四条守门一直全绿而实机是死路：`level1.tscn` 的 `start_with_ability = false` 是真的，死一次能力就没了，祭坛也随新实例的 `is_granted = false` 复生成没踩过的样子。

**根因 ②**：`Checkpoint.is_saved` 是实例私有布尔、只有踩下时置真、**没有任何反悔路径**；`run_state` 只存位置不存「是哪一台」。后果两笔：同一条命踩过几台就几台常亮（`level_1` 现摆 3 台），以及重载后新实例集体复位 —— **重生位是对的、皮在撒谎**。

**裁定**：

1. **「已耗」记在踩上那一刻，不记在能力开启那一刻。** 这两个时刻本来就分两拍（D16 要等松手），能进进度的只能是前者：石头已经烧了，重载回来不该复生。写点选在信号回调 `_on_altar_granted()`，**不是**钩子 `_begin_ability_sequence()` 里面 —— 后者是子类覆写点（`level_01_tutorial.gd:43` 就在覆写），记账不该依赖别人记得 `super`。
2. **谁亮谁灭归 `LevelBase`，构件只挨打。** `is_saved` → `is_active`（语义从"本条命存过"变成"此刻它是当前存档点"），新增 `claim()` / `release()` 一对**只换皮、不发信号**的方法；`LevelBase` 持 `_active_checkpoint` 做唯一激活。沿用 D49 的口径：构件之间不互认、不用组、不拖引用，协调只在关卡根。
3. **身份存「相对关卡根的 NodePath」而不是节点引用** —— `run_state` 的第三个键 `respawn_marker`。引用跟着旧关卡实例一起没，路径却能在新的那份里指回同一台；相对而非绝对，是为了 Main 把关卡挂在哪个容器下、叫什么名字都不影响这条链。（实现上沿父链走到关卡根倒拼 —— **Godot 4.6 的 `NodePath` 没有 `get_subpath`**，那是 3.x 的 API，守门当场把它打成解析错。）
4. **亮灭排在记账之前**：无常驻根（F6 直跑关卡场景）时进度确实没地方存，但"只有一台亮"这条视觉规则不该跟着失效 —— 它是玩家判断存没存的唯一依据。**同一台再踩直接返回**：重生时人正站在自己那条带上，`body_entered` 会再点一次名，不该因此把同一台顶掉又装回来。
5. **旧台可以被踩回来（用户拍板）**：给了两个选项 —— 会（规则只有一句"踩上即存，被踩的那台就是当前台"，皮永远说实话，不多存一份名单，代价是往回走几步会把重生点搬回去）/ 不会（每台一条命内只吃一次，要多存一份"已耗名单"，并制造"踩上去没反应"的窗口）。选**会**。

**契约变更（摆图与以后写同类构件要知道的）**：`checkpoint_reached` 仍是全子树扫描的契约信号，但接线时**多要两个方法** `claim()` / `release()`。给了信号不给方法 = 退化成多台同亮，`_bind_checkpoints()` 当场 `push_warning` 一次（与 `_resolve()` 那条一次性警告同口径），不静默。

**砍掉 / 不做**：不做"每台一次、之后踩上去没反应"的第二态；不给祭坛另存能力布尔（`altar_spent` 一个布尔继续推导，D31 订正不变）；`respawn_marker` 解析不到时既不警告也不回退成"点亮第一台" —— 那是摆图改了名或挪了层级的中间态，重生位本身仍然有效。

**守门（`kit_selftest` 第 14 组，9 钉）**：写路径必须由生产代码走一遍，这是这次真正的收获；第 9 组那行手搓保留但注明它只测读路径。另有两处 fixture 被动到，都不是装饰：① 第 10 组的常驻根替身**从来不释放**，会一直占住 `world_root` 组首位，让后面任何一组把自己的 `run_state` 写到别人身上（现在收尾拆掉）；② 第 10 组第二段前加 `run_state.clear()` —— D51 后第一段那次踩祭坛真的会记账，生产里对应的正是 `Main.load_level` 换关时清。

**How to apply**：以后再加"跨重载的进度"，一律按这套三段走：键写在常驻根、语义写在 `LevelBase`、**并且同时钉一条走生产写路径的守门**。只测回灌（读侧）的守门会把"根本没人写"这种错盖很久 —— 这次盖到 D51 才露出来。判绿的口径仍然要看有没有 `SCRIPT ERROR`：解析错会让整个函数一格不跳地假绿。

### D52 · 坠落带 `FallZone`：「掉出世界回的不是存档点」根因是这条路上压根没有判死

**起因（2026-09-22，用户报"掉出世界时复活代码似乎有问题，没有回到存档点"）**：症状是**掉下去之后回到的是出生点**，看起来像 D31/D42 那条回档链写坏了。查下来复活代码一字未错，错的是**这条路上根本没有判死**：关卡没有底，人一直落，先撞上的却是终点区 `GoalZone` 的 `body_entered` —— 那条走的是 `_tick_goal()` → `restart_level()`，而 `Main.restart_level()` **按设计清空 `run_state`**（与 R 键、终点收尾同一条路）。于是重生位回退成场景里的 `PlayerSpawn`。一句话：**误诊的来源不是回档写坏，而是"没有底"与"路过终点即算"两条凑在一起，把一次坠落记成了一次主动重开。**

**裁定**：

1. **形状 = 新构件 `scenes/objects/fall_zone/fall_zone.tscn`，`extends HazardBase`**（用户从三个选项里点的这一条，另两条是"关卡根加 `bottom_y` 导出项"与"在 `LevelBase` 里加一条全局 y 阈值"）。理由：判死与重载那条链**已经是现成的**（`LevelBase._bind_hazards()` 按 `touched_player` 全子树扫描 → `_on_hazard_touched()` → `Player.die(death_time)` → `death_finished` → `Main.reload_level()`），新构件只需要发那一个信号，**零新编排、零接线**。继承来的还有 `HazardBase` 那两条要紧的语义：逐物理帧扫重叠而不是靠 `body_entered`（所以下落再快也接得住），以及**判据不吃世界 delta**（世界冻着往下掉照样死，与 D38「接触即判」同一条口径）。摆在 `Objects` 下的哪一层都行，甚至不必起名叫 `FallZone`。
2. **节点原点 = 顶边中心**，与全家族"贴着地面那一点"**反过来** —— 是 §2 那张表的第四个例外。理由：这张网唯一需要摆的量就是"顶边线压在哪条 y 上"，原点落在线上才拖得走；深度由 `depth` 往下给，摆图的人不必再算半个高度。
3. **`depth` 默认 2048 px（两屏多），不去"算到位"**。无底洞里的下落速度不设上限，带子薄了会在**一拍物理里整段穿过去**；两屏多比量临界速度便宜，也免得多摆几层。导出的只有 `width`（默认 1024）、`depth`、`visible_in_game`（默认关 —— 运行时隐形，世界底部的辅助线不该进画面，同 `SensorZone`）。两个色常量刻意**不导出**：不是玩法旋钮，也不是要进 `props.json` 对账的构件色。
4. **`width` 的硬账：必须盖过整关所有"能走出去"的边缘**，漏一段等于那段没兜底。

**已知限制（用户当场裁定，不是 bug，别再当缺口提）**：**终点区「路过即算」保持现状**，代码不改，摆位由用户自己挪。后果是这张网与终点区**共享同一条判据家族但走两条不同的重载入口**（网 → `reload_level` 保留进度；终点 → `restart_level` 清空进度），所以**网顶线与终点区带子不许重叠**：重叠那一格里谁先接住取决于 `Area2D` 的扫描顺序，而两条路的进度后果不同。摆位口径由此而来 —— 网顶线摆在**最低那块能踩的地方下方至少一个跳峰**（默认档 136 px；`level_1` 是 −400 档，按 82 px 量），终点区摆在玩家"到站"而不是"路过"的位置。

**一条物理服务器的坑（本次实测踩到，写 fixture 时必守）**：**关卡根进了场景树之后再改它的 `position`，同一拍里 `Area2D` 的变换会跟着走、玩家刚体的变换还留在旧位置**，那一帧读到的重叠是假的 —— 人凭空被判死。守门里把整个关卡实例抬到半空（脚下必须真的没有底，前面几组留下的地面顶边就在 y=0）时，`level.position` 必须在 `parent.add_child(level)` **之前**就位。生产侧同一条约束的 softer 版本：编辑器里挪关卡根不会触发（下一拍就同步好了），但**别把"事后搬父节点"当便宜手段用**。

**守门（`kit_selftest` 第 15 组）**：① 玩家进带恰好一次 `touched_player` 且点名的就是他，人继续待在带里不叠发（闩锁的重置只属于关卡重载）；② 换个**非玩家** `StaticBody2D` 故意上到玩家那一层（layer 2）、形状与玩家同尺寸，一个信号都不许发（认的是 `player` 组，不是 mask）；③ 世界冻着时往下落照样接得住；④ **生产链**：踩住 B → 掉进带子 → 演完死亡那一拍 → 委托的是 `reload_level` 而**不是** `restart_level`（替身根因此多了 `restart_calls` 计数器 —— 这两条入口以前分不出来），换新的关卡实例后重生位仍指回那一台、且仍只那一台亮。`verify_kit` 侧 `FallZone` 进的是**家族清单**：编译、`@tool` 在位、导出项齐、场景可实例化，以及那条"凡发 `touched_player` 的判死区一律 layer 0 / mask 2 / monitorable false"按信号名扫到它就自动管；计数行新增 `fallzones=%d`，**只数不查**（摆几个是关卡的事，一关零张也是合法配置）。

**How to apply**：以后再有"某条路走错了重载入口"这类误诊，先问**那条路上有没有判据**，再怀疑判据之后的代码 —— 这次两条守门全绿而实机是死路，缺的从来不是逻辑而是那条路没人走。加新判死构件一律照 `HazardBase` 家族：`layer = 0 / mask = 2 / monitorable = false` 写在自己的 `.tscn` 里、只发 `touched_player`、不上任何实体层（上了 sensor 层就会被玩家的起身净空查询读成"头顶是空的"，§4 那条硬约束）。

### D53 · 刷卡门的拒绝提示：没有卡走进感应带时，那颗灯**连底座**发红（全项目第一处红像素）

**起因（2026-09-22，用户："玩家在没有钥匙靠近钥匙门时，门的指示灯会暂时变红来提示"）**：现状是**零信号** —— `_scan_reader()` 第一句就是 `if pickup == null or not pickup.is_held(): return`，没卡的人靠不近门、门也从不理他（D36 末条"先捡卡再进门"的读法）。要加的是"你进不去"的回执，不是新的门状态。

**裁定**：

1. **形状 = 一条只读旁路**（`_scan_denied()` 排在 `_scan_reader()` 之前，两者同一帧互斥：没卡才可能红、有卡才可能闩）。**不锁移动、不消耗卡、不碰闩锁链的任何一句**，也不新增状态机 —— 闩锁链那条链已经有 D40/D41 两次裁定压在上面，任何"顺手改一下"都要重跑那一条链的守门。
2. **几何复用现有感应带**（用户裁定，不新增"靠近"的定义）。后果要记牢：感应带只比幕面多探出 `sensor_reach = 24 px`，跑步 260 px/s 下就是 **0.09 s** —— 这颗红是"撞上去之前那一刻"的回执，**不是提前量**。要做成预警得单独加一条更宽的带子，那是另一个构件的事。
3. **时钟 = 引擎固定物理步长，不吃世界 delta**（与 D40/D41 同一条豁免）。理由一字未变：朝门走 = 按着方向键 = 必然处于冻结态，吃世界 delta 的脉冲**永远不会走完**。
4. **边沿触发一次**（用户裁定）：`_denied_armed` 只在人**离开**感应带后重新上弦，所以站着不动只闪一次而不是持续眨。时长 `denied_time` 默认 0.5 s，是唯一来源。
5. **尸体不触发红** —— 这是"尸体不算玩家"（D42）在刷卡门上的**第四个缝**（前三个：不刷卡、不产生冻结意图、不推进吃世界时间的过程）。顺手把那条判据收成一个来源：`_live_courier()` 同时供 `_scan_reader()` 与 `_scan_denied()`，两份各写一遍迟早只改一边。
6. **三态优先级在绘制侧**：认卡（青）> 拒绝（红）> 锁着（琥珀）。红与青的互斥由扫描侧保证，绘制侧只判一次 `lit`。**闩锁那一帧顺手把 `_denied_elapsed` 取消**：演出期间 `_physics_process` 早退到 `_advance_swipe`，不取消的话那个计时会永远停在"正在闪"，`is_denial_showing()` 就成了谎（画面上青本来会盖住红，所以这是只有守门才会露馅的那一类）。

**颜色选型（`tools/gen_gate_alert_preview.py` → `assets/props/preview_gate_alert.png`）**：候选色不是画出来的，是把 `assets/ui/frames/spot2_raw.png` 里那颗灯的 4×4 设备像素**原地替换**进真帧，再整帧过一遍 D46 那条 `crt()` 算式 —— 因为玩家看到它的瞬间必然隔着那层滤镜。四条账（分母全部实测，门楣那一块钢取灯左侧一块纯钢的均值，不用 `props.json` 的落盘色：真帧比常量亮一档，拿常量算是放水）：

| 候选（裸色） | 对底座（亮不亮） | 对 CRT 后琥珀（换没换） | 对门楣钢 |
|---|---|---|---|
| A 现状琥珀 `fa be 4a` | 9.24 | 1.00（定义） | 3.55 |
| B 纯红 `255,64,58` | 2.65 | 3.49 | 1.02 |
| C 深红 `222,52,52` | 2.29 | **4.04** | 1.14 |
| D 亮珊瑚 `255,116,96` | 4.44 | 2.06 | 1.72 |
| E 熄灯（=底座色） | 1.08 | **11.06** | 3.11 |
| F 玫红 `255,96,160` | 3.69 | 2.44 | 1.46 |
| G 整颗灯罩发红 `255,86,74` + 座 `66,14,18` | 3.21 | 2.64 | 1.35 |

**这张表真正的信息是前两列对红色反着走**：把红提亮到读得出"亮着"（D 行 4.44），它对琥珀就塌到 2.06 —— 琥珀本来就占着这个色相附近的亮端，4×4 设备像素上没有"既更亮又更不同"的位置。数字上唯一同时过两条线的是 E 熄灯（走开关轴而不是色相轴，且不新增色相）。**用户看了图挑 G**（"很帅"），赌的是面积：底座一起换暗红，亮的部分从 2×2 世界像素涨到整颗 4×4。这条按 D46 的口径记账 —— 数字只陈述，色由眼睛裁。
另一条顺手量出来的：**D46 记的烫黄 `(255,235,91)` 在这颗灯上不成立**，4×4 尺寸下色散把 R 通道从暗座里抽走，滤镜后核心均值只有 `(184,234,76)`（偏黄绿）。以后任何"小面积极亮色"的可读性账都要按这一档重量。

**同源契约**：`gate_led_denied` / `gate_led_denied_socket` 进 `props.json`，`verify_kit` 的灯色比对从十处涨到**十二处**。这两个是**全项目第一处不从调色板推导的构件色**（`gen_props.py` 里的字面常量 `GATE_LED_DENIED` / `GATE_LED_DENIED_SOCKET`）—— 旧版祭坛那串琥珀就是"写死在构件里、不在清单上"才漂走的，所以字面值可以，不进清单不行。定稿样本进 `preview_keydoor.png` 的可读性行：那一行现在左半锁着（琥珀）、右半拒绝（红），与构件 `_draw_frame()` 同一条算式。

**红从此在 D29 那张色语言表上占一格**：**红 = 这道门不认你**，只用在刷卡门的 LED 上。它紧邻琥珀（"可拾取物"那一格），所以这条分工只在**同一颗灯换色**这个语境里成立 —— 别处再出现红像素，要么先改这条，要么先想清楚它跟琥珀撞不撞。

**守门（`kit_selftest` 第 16 组，14 钉）**：① 无卡进带闪红，且**它是只读的** —— 不锁移动、不消耗卡、`curtain_rect()` 一格不塌、门没闩；② 世界全程冻着而脉冲自己收回去了（接成世界 delta 就在这里响）；③ 人还站在带里也不叠发（边沿计数，不是抽样读数 —— "闪一次"与"一直红着"在 `is_denial_showing()` 的抽样上长得一样）；④ 出去再进来重新触发一次；⑤ `denied_time` 是唯一时长来源（改成 2 s 后 1 s 时还在闪，写死 0.5 就在这里红）；⑥ 死在带里那一拍不闪红；⑦ 带卡进带不闪红、直接认卡，且移动确实被锁进演出；⑧ 闩了之后再走进感应带不再闪红（没有 `is_latched` 早退的话，卡已消耗 = `is_held()` 假 = 一扇开着的门常亮"你别过来"）。像素照旧不归无头管（D46 同规矩），颜色那一对归 `verify_kit` 与 `props.json` 比对。

**How to apply**：给已有构件加"提示 / 反馈"这类东西时，先确认它是不是**只读旁路**——只读就不必进状态机、不必抢时序、也不必在守门里替被它盖住的那条链重跑一遍。以及：**小面积极亮色的可读性账必须透过屏幕空间的滤镜量**，调色板上的对比度数字在 4×4 设备像素 + 色散面前不作数（这次五档红全部落在 D26 的 4.5 下限之下，是看图之前就能算出来的，只是没人算）。

### D54 · 彩蛋收集物 `Collectible`：小黄鸭转台 —— 奖励是"发现"这件事本身，所以它一颗像素都不换机制

**起因（2026-09-23，用户："接下来我想设计一些收集物，可以作为彩蛋放在隐藏房间作为对玩家发现隐藏的奖励"）**：现状是**收集物只有钥匙卡一种**，而它是机制素材（D30：死了掉回去、一卡一门），承担不了"奖励"这个角色 —— 奖励若同时是解谜素材，玩家就不是在为发现而发现。要加的是**第二类拾取物：不参与任何解谜、纯对"你找到了"的收据**。

**边界（先划掉不归这条的）**：隐藏房间本身不归这条 —— 摆位与墙体是关卡布局，用户的地盘（真要一种"看着是墙"的构件，另立 D55）。不做计数 UI（"3/7"那种读数）、不做全收集奖励、收集物之间不互认、不与别的构件互认。音频不重提（D34 的口径）。

**裁定**：

1. **不给机制回报**（用户裁："作为对玩家发现隐藏的奖励"本身就够了）。不开门、不加盒高、不解锁、不进任何一条解谜链。由此带出**演出的禁忌**：**不许复用 D44 祭坛那套「飞入体内 + 三枚环」** —— 那套语言在玩家眼里已经等于"我获得了能力"，彩蛋借它就是在撒谎。改成只做一件事：鸭子从底座上**向上飘起并淡掉**（`FLY_TIME = 0.5 s`、`FLY_RISE = 26 px`、减速曲线 `1-(1-t)²`），底座留在原地变空座。飘起时姿态**照旧跟着转角走**：它本来就在转，起飞那一刻钉回正脸反而会跳一下。
2. **死一次不许复生**：契约三件套照抄祭坛 —— 构件发 `collectible_taken`、暴露 `mark_taken()`，谁来记、记在哪不归自己。`run_state` 因此多了**第四个键** `collectibles_taken: Array[NodePath]`（相对关卡根，复用 D51 的 `_relative_path()`），`LevelBase._bind_collectibles()` 按**信号名**全子树扫描接线，回灌在 `_apply_run_state()`。**存身份不存位置**：与 D51 第 3 条同一条理由 —— 节点引用跟着旧关卡实例一起没，路径能在新的那份里指回同一只。主动重开（R / 终点收尾）清 `run_state` ⇒ 彩蛋复位，这是**对的行为**：从头开始本关，隐藏房间当然又是隐藏的。无常驻根（F6 直跑关卡场景）时静默不记，与 D45 那台存档点同口径。
3. **拾取带不用脚底那条带**：按钮 / 存档点那条"带心抬半个盒高"的规矩是给**必须站在上面**的地面道具的，而鸭子摆在台子上，玩家该是**走过去擦到就拿到**。改成贴图外接框外扩 `PICKUP_MARGIN = 4` ⇒ 带 22×24。姿态在换、图在挤，**带子一格不跟着缩**（D38「判定与零件尺寸无关」在转台上再验一次：否则转扁那一瞬间它变成捡不到的东西）。
   **订正（本条原写"带心在节点原点"，实现按外接框中心 = `(0, -8)`）**：居中原点的带子会伸到地板下 12 px，而节距 16 px —— 楼下那间房的人隔着地板就能把鸭子捡走。带子下沿因此只探出地面 4 px（= margin），守门钉的就是这个数。
4. **一张场景 + 选皮导出项**（`skin`，枚举今天只有 `DUCK` 一臂），**不拆场景**：「行为不同就拆场景」的反面就是行为相同不拆。加第二只彩蛋 = 添三张视图 + 往 `SkinKind` 与 `_views()` 添一臂。**枚举不叫 `Skin`** —— Godot 有个 3D 资源类同名，用了整个脚本编译不过（`The member "Skin" shadows a native class`）。
5. **留空座**（用户裁："留空座，出预览"）：`perch_taken` 与 `perch_idle` **同尺寸**（不像 D45 存档点那样故意差一档），差别只在顶面那道压痕上 —— 收据实测对空座 `cr = 2.07`，够；加强档 2.62 的旋钮留在生成器里，**未落盘**。
6. **追加裁定（转台）**：用户看了静图后提"我希望在底座上时小黄鸭会一直旋转，做成类似伪 3D 的效果"，选型四档里挑 **B 档**、并裁「**冻结时也暂停**」。于是：三张视图（正 / 侧 / 背）+ 四个轴向 + `|cos(与最近轴心的夹角)|` 横向挤压，侧脸靠镜像凑第四张；`spin_period` 导出项默认 3.0 s（填 0 = 不转、钉正脸，是合法配置）。**两条时钟通道刻意不同**，这是本条最容易被读成笔误的地方：
   - **转**是环境的一部分 ⇒ 吃 `TimeReceiver.get_physics_delta()`，冻结即钉在当前角度上；
   - **飘起**是一次性演出 ⇒ 吃**原始** delta（D41 同一条豁免）。按着方向键去捡它 = 必然处于冻结态，吃世界 delta 的演出永远演不完，而"捡到了却卡在半空不淡掉"比转得不像更糟。

**选型（两张图，都按 D46/D53 的规矩：数字只陈述，色与形由眼睛裁）**：`assets/props/preview_collectible.png`（哪只彩蛋 × 底座两态的收据读数）→ 用户挑小黄鸭（"撞色问题不大，选小黄鸭"）；`assets/props/preview_duck_spin.png`（A/B/C/D 四档转台 + 一圈的视图序列与最扁读数）→ 用户挑 B 档。**一张留痕**：他先挑中的是 E4 行那张 3/4 视角的 `part_duck`，而**落盘的正脸是转台算式里那张左右对称的 `duck_front`** —— 转台要求正脸与背面镜像后看不出差别，3/4 那张转到背面会露出喙朝错边。以后有人拿"批过的图"逐像素对账，对的是转台那三张，不是 E4。

**皮只有一个来源**：三视图与底座两态进 `gen_props.py`（`make_collectible_parts()`），两个预览脚本改为 import / 两行别名 —— 落盘像素必须与批过的逐位相同（§同 `make_m5_parts` 那条纪律）。重跑证据：两张预览 md5 不变（`f781a22d94ccc2eb94cb4d2b7871c312` / `bf16dab9990ce8b35e8a05668fe4c436`），`--emit` 后原有 21 张零件 PNG 逐位不变，只有 `props.json`（现 27 件）与 5 张新 PNG 动。视图**选择**那道算式在 GDScript 与 Python 里是**同一份的两处书写**（不是共享代码），所以改轴心表必须两边一起改 —— 第 17 组那圈序列就是为了让"只改了一边"当场响。

**契约变更（摆图与以后写同类构件要知道的）**：传感器族（`layer = 8 / mask = 2 / monitorable = false`）第三个信号名，前两个是 `pressed_changed`（触发源）与 `checkpoint_reached` / `collectible_taken` 之外的收据类。与危险物那条 `layer = 0` 的硬约束**不冲突也不通用**：彩蛋不是判死区，它上 sensor 层无害，且它本来就不挡路 —— 上任何实体层都会把"鸭子站在台子上"变成一块台阶，那等于偷偷给了机制回报。节点原点 = **底边中心**（底座压格线），与 Checkpoint / KeyPickup 同表；`@tool` 只画 idle 态、停在正脸不转（摆图定位用）。

**守门**：`kit_selftest` **第 17 组**（21 钉）—— ① 冻结里角度一分一毫不动、解冻后重新推进；② 带子在转大半圈的 60 拍里一格没缩，且期望值从零件纹理现算（不在断言里抄第二份数）、下沿只探出地面 4 px；③ 冻着走进带里照样捡到手，飘起演出在冻结里自己走完（第 29 拍收），而**同一段冻结里角度仍然钉着** —— 这一钉同时管住两根通道接反的两种露馅样子；④ 本条命只发一次（出去再进来不叠发）、再踩空座不重播演出；⑤ `mark_taken()` 即空座且不发信号；⑥ 一圈换皮 4 次、顺序正→侧→背→侧，最扁 0.7071（±45° 那档，用户批 B 档时看到的数字）、对准轴心不挤、镜像只在下半圈的侧脸；⑦ **生产链**：踩一次由**游戏代码**写进 `run_state`、记的是 `NodePath("Duck")`，换个新关卡实例后**那只挪了格子仍被回灌成空座**、走过拿不到、清单也不叠一条。`verify_kit` 侧：脚本进家族清单（编译、`@tool`、`skin`/`spin_period` 在导出项白名单、场景可实例化、layer 契约），加上像素级对账 —— 五张零件在 `props.json` 上、三视图同尺寸、正脸≠背面（只换一张就在这里响）、每张底行至少一颗实心像素、正脸左下那颗必须是琥珀、`perch_taken` 的压痕必须比 idle **暗**、带尺寸与位置从纹理 + `PICKUP_MARGIN` 现算，以及一条"脚本里不许出现 `func _process(`、必须出现 `_receiver.get_physics_delta()`"（D47 同一条：该走物理通道的东西走了绘制通道，就会在帧率变化时漂）。

**How to apply**：以后再加"对玩家某行为的收据"类构件，按这三条走：① 它**只读**，所以不进状态机、不上实体层、不给机制回报；② 一次性的**演出**吃原始 delta、环境的**循环**吃门控 delta —— 这两根线接反的两种病都不在试玩里一眼看得出，所以钉守门时**必须把"冻着"这个条件叠上去测**；③ 跨重载要复活的与不许复生的分两族（钥匙卡回场、彩蛋与祭坛不留），别为了少写一个键把它们塞进同一份清单。
