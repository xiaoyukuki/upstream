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

**✅ 已决策（2026-09-16）**：这两类谜题**整体延后到第二章**，待时间锚点系统解锁后再做。第一章 M4 只做不依赖「专属时间源」的纯时停谜题（垂直移动不触发时停、时停期间观察环境线索、时停期间碰撞体仍有效、组合运用）。`TimeReceiver.set_time_source()` 保持空接口、**全章零调用方**，与 1.2「本章隔离」一致。**D68 订正（2026-10-26）**：锚点系统已落地，`set_time_source()` 不再零调用方 —— 设计与实装见文末 D68；本段保留当日收手时的范围记录。

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
                  set_time_source(Callable)   ← 第一章留空接口；D68 起由锚点接手 (D11)
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
| `time_receiver.gd` | `class_name TimeReceiver extends Node` | 单个对象的时间源代理 | `get_physics_delta()`、`get_process_delta()`、`set_time_source(Callable, Callable)`、`clear_time_source()`、`time_source_changed`（D68 起有调用方） | 不含任何游戏逻辑；`_ready()` 加入 `time_receiver` 分组 |
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
| `debug_overlay.gd` | `class_name ... extends CanvasLayer` | 开发期诊断 | 枚举 `time_receiver` 分组 | 仅 `OS.is_debug_build()` 存在；**默认隐藏，按 T 开关**（2026-09-29 用户裁定：常驻左上角会挡住摆图要看的格线） |
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

- 锚点同步系统（1.2，第二章）——仅保留 `TimeReceiver.set_time_source()` 空接口，全章无任何调用方（**D68 订正**：已落地，见文末；本行保留当日的范围记录）
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

> **订正（D61，2026-09-27 —— 本条第 4 条整块推翻；第 2 条一字未动；第 6 条仍然成立）**：他把这一拍重做成了"人自己被卷进去"的那一拍（16 帧 / 5.0 s，见 D61）：现在**锁移动**（复用 D41/D57 那把 `movement_locked`，不另起第二套掐法），并且**在爆发那一帧用 `TimeManager` 真的钉住约 1.25 s**。当年被否的那条路（`set_frozen_override()` 钉住 + 补一行 `notify_movement_intent()` 收尾）后来走通了前半、**后半走不通** —— 那行收尾在"能力还没开"这个恰好第一次拿到能力的当口被整条静音，于是世界永久冻住，所以 D61 为它加了显式带意图的第二条入口 `release_frozen_override(moving)`。而第 2 条「时钟只有一条：真实物理 delta」在新增的钉住窗口里**依然成立**（`kit_selftest` 第 20 组专门钉这一条：钉着冻结，那一拍照样推进、世界时间一字不涨）；「这一拍不改变任何世界事实，所以它是纯装饰」那句代价随之作废 —— 它现在改的正是世界事实本身。
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

**"一组"= 一个按钮接多块，接线写在块上**（同门的口径）。多对一**刻意不查重**，那正是"一组"的写法 —— 与钥匙那套"一卡一门"相反。构件之间没有 group、没有互相引用，所以"一组"这个词在代码里不存在，它只是同一个 `trigger` 被写了 N 次。（订正：D60 起这个字段叫 `triggers`，是**一列** —— 反方向的"一块接多台"也合法了，合成口径 OR。见 D60。）

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

### D55 · 能量卡坐进公共底座：「可拾取」这条提示改由**形状**说话，而不是由转说话

**起因（2026-09-23，用户先提「为钥匙卡也添加类似的旋转动画，提示玩家这是可拾取的道具」，随后自己给出解法「我想到解决方式了，加一个和鸭子一样的底座表示可拾取」）**：D54 那只鸭子转起来之后，"能拿"这件事第一次在画面里有了形状语言；而能量卡（D36 落地）是**一张直接压在地格线上的 14×10 贴片**，跟门底、尖刺那些平铺件一样"只是场景里的一块东西"。

**为什么底座比转便宜 —— 这条是整个决定的承重墙，不是顺手一提**：转要解决的是「玩家朝它走的时候世界必然处于冻结态」（D40/D41 那条地基）。鸭子用「冻结时也暂停」没问题：它是房间里的摆件，人到了站才看它。能量卡的提示**必须在他走过去的整段路上有效**，把 D54 那条通道原样搬过来，等于恰好在最需要它的时刻把提示关掉；要让转在冻结里也跑，就得为它单开一条真实时间豁免 —— 为一个"提示"付一笔时序复杂度。底座是**静态形状语言**，不吃任何时钟。于是这张卡**不转、不挂 `TimeReceiver`、一个导出项都不加**（`verify_kit` 把这三条钉成源码形状检查，见下）。

**裁定**：

1. **复用零件，一颗像素都不新画**：直接 `preload` D54 落盘的 `perch_idle.png` / `perch_taken.png`（14×5）。这是「复用在零件与基类、不在行为不同的场景之间」那条口径的标准案例 —— 那两张皮的语义本来就是"有物 / 已拿走"，与"这里放过一张卡"同构，所以不需要第三张。`props.json` 不新增条目（仍 27 件），`--emit` 之后原有零件 PNG 逐位不变（改前改后 md5 一字不动：`perch_idle 6a28c5f6…` / `perch_taken 31c70531…` / `key_card 76d07b20…`）。
2. **卡底边抬到座面**：座子占 y ∈ [−5, 0]，卡占 [−15, −5]，整块外接框从 14×10 长到 14×15。**原点契约（贴着地面的那一点）一字未动** —— 他已经在 `level_1` 里摆好的那张卡不必挪，这是这条改动便宜得起的另一半。
3. **判定带不跟着长**：32×24 @ (0, −15) 那条脚带是 D30 定的；D54 给彩蛋定的是另一套（外接框 + `PICKUP_MARGIN`）。"座子把外接框抬高了 5 px"不构成把前者改成后者的理由 —— 两套各管各的构件。`verify_kit` 那条既有断言就是这一钉，所以这里不新写数字。
4. **空座皮跟着状态走**：判据收成 `seat_occupied()` 一个只读函数（`not held and not consumed and _fly_elapsed < 0.0`），`_draw()` 与守门都只读它 —— 两态判定写两份迟早只改一边，而"卡走了座子还画成满的"正是那种不响的错。卡一进身体、或被门吐掉，座子当场换成 `perch_taken` 那道压痕；飞出那半拍里座子也已经是空的。
5. **同一种皮、两种账**：彩蛋的空座是**永久收据**（`run_state.collectibles_taken`，死一次不复生），卡座的空是**这条命的状态**（重载即归位，D30 第 3 条）。差别不在皮上，在"它是不是机制素材"上 —— 卡是开门素材，复生是玩法契约的一部分；彩蛋不是，不复生才是对"你发现过"这件事的尊重。这正是 D54 结尾"分两族"那句的第一个实例。

**选型（`tools/gen_keyperch_preview.py` → `assets/props/preview_keyperch.png`）**：底片、算式、量法全部沿用 D54 那张（同一块 spot0 空地板、同一条 `crt()`、同一份 footprint 判据），所以两张图的读数可比。五行：N 现状 / A 复用 14 座（与卡同宽、两侧**齐边**）/ B 16 座（每侧露 1 px = 鸭子自己的露边比例）/ C 20 座（每侧 3 px）/ D 参照 = 鸭子在 14 座上（这把尺子的原稿）。读数一律 CRT 后：

| 行 | 本体对墙 | 本体对地 | 座子对墙 | 座子对地 | 座子 vs 头顶那只 |
|---|---|---|---|---|---|
| N 无座 | 3.38 | 1.71 | — | — | — |
| A 14 座 | 3.35 | 1.70 | **1.04** | 1.90 | 3.23 |
| B 16 座 | 3.35 | 1.70 | 1.01 | 1.95 | 3.32 |
| C 20 座 | 3.35 | 1.70 | 1.02 | 2.01 | 3.41 |
| D 鸭子 | 2.93 | 1.48 | 1.04 | 1.90 | 2.82 |

三条读数各回答一件事：**座子对墙 1.0** —— 它在墙前面等于隐形，"底座"整条读出来靠的是**对头顶那只 3.2** 与**对地 1.9**，也就是"轮廓分成了两截"而不是"看见一块石头"；**本体三行读数一字不动**（3.35 / 1.70）—— 加座子没有拖累卡自己，这条是防我画错的，不为审美服务；**A/B/C 三档彼此只差 0.2 上下** —— 数字上分不出胜负，齐边读不读得出两截只能看图（D46/D53 那条老规矩：数字只陈述，形与色由眼睛裁）。落盘走 **A**（用户点名的"和鸭子一样的底座"），B/C 的旋钮留在 `part_perch(..., w=)` 里。

**顺手给 `gen_props.part_perch` 加了宽度参数**（默认 14 = 落盘那张）：选型图要画 B/C 两档就得能改宽度，而把座子在预览脚本里再抄一份就是"同一张皮两处书写"。默认值下逐位不变，`--emit` 与 md5 已验。

**一条记账**：`preview_m5_shipped.png` / `preview_keydoor.png` / `preview_keyheld.png` 三张旧图里那张卡还是"躺在地上"的样子 —— 那是 D55 之前的现场，不重出。**落地态的权威图从 `preview_keyperch.png` 起算**。

**契约变更**：无。原点、判定带、`consume(fly_time)`、飞出链、`held` / `consumed` 全部一字未动；新增的只有 `KeyPickup.seat_occupied()` 一个只读探针（与 `is_held()` / `fly_progress()` 同族：为守门而存在）。

**守门**：`verify_kit` 三条 —— 两个 `TEX_PERCH_*` 常量必须指向落盘那两张 PNG（谁复制一份副本，换风格时只会有一半跟着换）、`key_pickup.tscn` 不许挂 `TimeReceiver`、`key_pickup.gd` 里不许出现 `@export`（有人把它改回了转，这里当场响）。`kit_selftest` 第 8 组加三钉（复用同一段 fixture，不新建 rig）：开场卡坐在座上、进身体即换空座、飞完不会自己装回满的 —— 第一条必须在放人**之前**读，人一生成就压在卡上。四条守门全绿（`VERIFY DONE doors=3 pistons=2 fallzones=0 failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=308`）。像素照旧不归无头管（D46 同规矩）。

**How to apply**：以后要加"这是个能拿的东西"这类提示，先看**有没有一块已经在册的零件能承担形状**，再考虑动时序 —— 时序每多一条豁免通道，"什么在冻结里停"这张表就多一行要背，而形状是免费的。以及：**复用零件不等于复用账本**，皮可以同一种、状态语义可以相反（D54 不复生 vs D55 复生），把差别写在构件记账那一侧，不要写到皮上。

### D56 · 两块无字告示牌：不许出现字，那两句话只能由**形状 / 颜色 / 挂在哪**说

**起因（2026-09-23，用户：「我需要两个告示牌，一个提示前方有钥匙卡，一个提示这个门需要钥匙卡打开，但我不希望告示牌上有字出现」；选型图第一版后裁「A，我觉得应该要一个向右的箭头＋钥匙卡，同时显得比较像告示牌」；第二版定 **A5 + B3**，路线走装饰格）**

**没有字，词汇表就只剩三样**，三样全部从已在册的语汇里取：琥珀 `accent2` = 可拾取（D29；D36 那颗 LED 与卡同色是刻意的「这把开那扇」一对）、卡形 = 落盘那只 14×10 的剪影、亮白 `lip` 描边 = 夜光风格（g）里唯一拉得开暗墙的东西。**为什么「前方有卡」这句值得单独一块牌**：D53 那颗红灯只覆盖 0.09 s 的行程，它是即时回执、不是路标 —— 远处预告「前面有卡」这件事今天没人管（手册 §11 那个洞）。

**裁定**：

1. **两句 = 两块牌、两种轮廓**，不是一块牌两种屏。**A5** 32×16 横牌（卡 + 亮白右箭头）= 走廊指路；**B3** 16×16 方块（实心卡）= 门前就地说明。分工落在**有没有箭头**上，宽 / 方是第二道区分 —— 于是「往前看」与「就是这扇门」不会读成同一句。
2. **方向与物件分色**（他从 A4/A5 里挑了 A5）：箭头走牌框那圈亮白，琥珀只留给「能捡的东西」。A4 那种同色箭头整块更"一"，但方向与物件在语义上没分家 —— 白箭头不会被读成第二只卡，卡也不会被读成那颗 LED。
3. **不吃时钟、不进契约**：静态形状语言，无状态、无导出项、无原点契约，与 D55 同一判。
4. **落 `Terrain/Decor` 装饰格，不新建构件场景**。三条理由：零行为（「行为不同就拆场景」在这儿两边行为都等于无）；`tileset_selftest` 的装饰段是**清单驱动**的，新增两格自动被「在 / 占几格 / 零碰撞 / alpha 非空」四条覆盖，守门一行未改；图集里 `monitor` 48×32、`cabinet` 64×48、`vent` 32×16 已是多格先例，`build_tileset.gd` 走的就是 `create_tile(coords, size)`。继承的三条约束（都在手册 §12 在册）：必须 16 对齐且整格倍数（32×16 = 2×1 ✓）、必须刷在**空格子**里（叠在实心地形格上会被盖掉）、Decor 层 z=-20 → 牌永远在那面墙上、主角身后，不会挡人。
5. **只出右向**。`TileMapLayer` 不能逐格翻转，左向要再占一格图集；今天没有一关需要左向 —— 真要时 `SIGN_SIZE` / `sign_plate` 加一个 kind、`DECOR` 加一行，不预先占格。
6. **画法只一份**：`gen_tiles.sign_plate(d, p, x, y, kind)` 同时是落盘图集与选型图的来源（`gen_sign_preview.sign_plate` 对定案那两档直接委派）。逐字节核过：图集里 `(0,160,16,16)` / `(16,160,32,16)` 两格与选型图上那两张皮 `tobytes()` 全等 —— 预览与出货两套书写必然走偏（D25/D26 那条老坑）。
7. **两块牌进 `DECOR_NO_ROUND`**，理由与管子相反、同一条名单管得住：soft 那圈贴纸暗框是沿格子边界画的，而牌体对墙只有 1.11 —— 唯一能把它从暗墙里拎出来的就是自己那圈亮边，暗框正好盖在亮边上。

**选型（`tools/gen_sign_preview.py` → `assets/props/preview_sign.png`，1820×5772）**：A 块底片 = spot0 那块空地板（与 D54/D55 同一把尺子、同一条 `crt()`，读数可比），B 块底片 = spot2 那道**真刷卡门**（D53 那颗 LED 就在画面里）。每行三格：裸帧 / 套 CRT / 1:1 真机。读数一律 CRT 后：

| 行 | 牌 | 牌体对墙 | 亮部对屏 | 亮部对墙 | 削顶 |
|---|---|---|---|---|---|
| A1 | 16×16 实心卡 | 1.60 | 6.33 | 4.47 | 94/200 |
| A2 | 卡 + 两截底座（D55 轮廓） | 1.89 | 4.01 | 4.01 | 132/324 |
| A3 | 16×32 立式牌 | 1.78 | 6.33 | 4.47 | 94/200 |
| A4 | 32×16 卡 + 琥珀箭头 | 1.11 | 7.03 | 4.38 | 134/308 |
| **A5** | **32×16 卡 + 亮白箭头 ← 定案** | 1.12 | **7.21** | 4.49 | 148/308 |
| A6 | 整块牌就是一个右箭头 | 1.48 | 6.81 | 4.44 | 92/200 |
| A7 | A4 插柱、立在地面 | 1.29 | 7.03 | 4.38 | 134/308 |
| B1 | 16×16 空心槽 | 1.13 | 6.14 | 4.55 | 40/80 |
| B2 | 槽 + 一枚小实心卡 | 1.29 | 4.14 | 4.55 | 72/152 |
| **B3** | **16×16 实心卡 ← 定案** | 1.65 | 6.33 | 4.61 | 94/200 |
| B4 | 卡 + 两缕青色光幕 | 1.60 | 3.90 | 3.95 | 87/224 |
| B5 | 横牌空心槽（连带项，非候选） | 1.30 | 9.22 | 4.30 | 40/80 |

三条读数各回答一件事：**牌体对墙 1.1~1.9** —— 夜光风格里"牌"这块钢本身是隐形的（与 D55 那只座子 cr=1.04 同一个发现），所以画法从第一版起就是「亮边 + 近黑屏 + 发光图形」而不是钢板；**横牌三档的亮部对屏 6.8~7.2 是全表最高**（高于 A1 的 6.33），因为箭头是纯亮部、没有磁条那种暗像素稀释；**满 vs 空 在数字上分不开**（A1 6.33 对 B1 6.14）—— 这条命门只能由 1:1 那一列的眼睛裁（D46 那条：读数只陈述，没有否决权）。落盘走 A5 + B3（用户点名），其余留在选型图上，旋钮在 `SIGN_SIZE` 与 `sign_plate` 的 `kind` 里。

**顺手记两条坑（都在这张选型图上真踩过）**：① 量「图形对屏」必须把图形拆成**亮部 / 暗部**两批点分别量 —— 空心槽那句全靠一圈 1 px 亮轮廓（真机 2 px），整块均值会把它冲成 1.08 的假死信；② 家族图那一排要按**设备像素**排间距，一块 32 世界宽的牌贴进帧是 64 设备宽，中心距 40 会直接叠在一起；且底片只有 1280 宽而 `SPOT_X=1150`，往右贴 176 px 就出帧（PIL 裁掉 = 那块东西从选型图上无声蒸发）。

**契约变更**：无。关卡、场景、脚本一个都没动 —— 落地的只有 `tilesheet_decor.png` 多出的两格、`tiles.json` 的两条清单、`lab_tileset.tres` 的 decor 12 → 14 块。摆哪一格归用户（手册口径：布局与摆位是关卡作者的事）。

**守门**：`tileset_selftest` 装饰段清单驱动，新增两格自动过那四条（checks 308 → 316，**守门代码一行未改**）；`gen_tiles.build_decor_atlas` 里加一条生成期断言 —— `DECOR` 那两格的宽高必须等于 `SIGN_SIZE`，写宽了画法会渗进邻格、图集里看不出来、刷进关卡才现形。四条无头守门全绿（`VERIFY DONE doors=3 pistons=2 fallzones=0 failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`）。像素照旧不归无头管（D46 同规矩）。

**补记（D56 提交之后当天踩到）**：无头跑 `build_tileset.gd` 会把它自己写出来的那份 `uid="..."` 丢掉（引擎只在编辑器保存资源时填这一行），于是 `lab_tileset.tres` 的资源身份每次重建都归零 —— 编辑器下一拍另发一个新 uid，而所有 `.tscn` 里 `[ext_resource type="TileSet" uid="..."]` 记的还是旧的，引用退化成按路径找，且**用户那份 `level1.tscn` 已被编辑器顺手改写成了新 uid**（我没碰他的文件）。现在生成器在 `ResourceSaver.save()` 之前先读回头里的旧 uid 再 `set_resource_uid()` 回填，uid 从此跨生成稳定。**口径：凡会被场景按 uid 引用的资源，都不许在无头生成脚本里"从零 write"。**

> **订正（D57 当天，同一个补记里第二次踩它）**：上面那句「先 `set_resource_uid()` 回填」**从来没生效过**。4.6 实测 `SpriteFrames` 只有 `get_resource_uid()`，`set_resource_uid()` 对它根本不存在（探针：`has_method` 返回 false，调用即 `SCRIPT ERROR: Invalid call`），而那次"重建之后 git 无 diff"是**假绿** —— 脚本在 `save()` 之前那一行就崩了，文件压根没被重写，当然没差。**幂等要跑一次看进程退出码和文件字节，不能只看"没有 diff"。** 现在两份生成脚本共用 `tools/keep_uid.gd`：存盘前拍一份账（头行的资源 uid + 每个 `ext_resource` 的 `path → uid`），存盘后按文本补回去。补 `ext_resource` 那一层是顺带治的第二样病 —— 无头 `save()` 只写 `path=`，编辑器写的是 `path` + `uid` 两份，少一份解析仍成立（按路径找），但下次编辑器存盘会连 `id=` 一起重排，"只加了一段剪辑"的改动在 diff 里看成整份重写。核对：`lab_tileset.tres` 现在**真的**逐字节零差异（`build_tileset.gd` 退出码 0、`uid_kept=true`），`slime_frames.tres` 重建后 46 条旧 ext uid 全部原位保回。

**How to apply**：以后"要加一句提示"，先问**这句话能不能由已在册的形状 / 颜色承担**（琥珀 = 可拾取、卡形 = 那只卡、亮边 = 暗墙上唯一可见的东西，三样都是现成的），能就不新建语义；纯静态的提示一律走装饰格 —— 一条清单 + 一个画法函数就够，不进契约、不加场景、守门还是现成那四条。以及：**同一块牌不许两处书写**，落盘画法与选型图画法必须是同一个函数，"逐字节相同"不是应当如此，是当场 `tobytes()` 比过。


### D57 · 开局苏醒：第一次进游戏那一拍，人从睡梦里醒过来（掐输入、只演一次）

**起因（2026-09-24，用户：「在玩家第一次游戏时，我希望开局有一个小动画，表现玩家从睡梦中苏醒，要可爱一点」；四条菜单裁定 **A1 + B2 + D2**，C 取默认那档）**

四样东西全部是从册的，这一条没有发明任何新机制：**掐输入**用 D41 那把 `movement_locked`、**一次性演出走引擎固定步长**走 D54 那条通道、**皮读状态而不是读输入**沿用 D27 的口径、**嘴**是生成器里现成的 `mouth="open"` 那档 2×2 口。

**裁定**：

1. **A1「每次进程启动演一次」，不落盘**。项目今天没有跨进程存档（`run_state` 只在内存，M6 未开工），为一个 bool 开第一条写盘路径不值 —— 那条路一要配的是版本、损坏、清档三件事，全都不属于这一拍。代价挑明：这不是严格意义的"第一次游戏"，试玩时每次 F5 都会看一遍。
2. **标志住在 `Main`，而且做成"取走"而不是"读"**：`Main.take_intro() -> bool` —— 第一次 `true` 并就地翻标志，之后一律 `false`。设计成 consume 而不是给关卡一个布尔让它自己写回，是为了**不给关卡"读到了但忘了写回"的机会**：那种漏法在画面上的表现是每关开局都躺一遍，正是 D51「有读没人写」那条的镜像。它也不进 `run_state`（换关 / 按 R 会清进度，苏醒不该跟着清）更不写盘。
3. **谁问：`LevelBase._maybe_intro()` 排在 `_apply_run_state()` 之后**。顺序是有内容的 —— 存档点回灌可能改写出生位，演之前得先站对地方。F6 直跑关卡场景时 `_world_root()` 返回 null，整条不问也不演：**摆图的人不该被这一拍挡路**，代价是他要看这一拍就得 F5 从 `Main` 进。
4. **B2 整段掐输入**（他没选我推荐的 B1「按下即提前结束」）：`begin_wake()` 挂 `movement_locked`，窗口到点自己落下。掐的是 D41 那一处收口（`_horizontal_axis()` 与 `_try_jump()`），不另起第二套掐法；**重力不掐**（出生位那几像素的下落照落），**蹲伏另补一条读法** `and not is_waking()` —— 因为 `is_crouch_held` 不走那把轴，不补就是"画面在伸懒腰、碰撞盒缩成蹲的"。
5. **皮不许说谎**：`PlayerVisual._pick()` 第一条就是 `if _player.is_waking(): return &"wake"`，压在腾空那条判据**之上**。理由是这一拍里唯一还会发生的事就是落地，而"落地换 fall、两帧后又换回 wake"就是谎（D42/D55 同一条口径）。
6. **D2 的动作语汇**：摊平睡着（含一次几乎看不出的呼吸）→ 眼皮抬一半 → 张嘴哈欠 → 弹过头 → 压回来收拾。**零新零件**，可爱全压在数值上；最后一条是**收帧参数与 `idle` 第 0 帧一字不差** —— 这段不循环，停在哪一帧就是玩家看见的第一眼，接缝不比对焦更重要。
7. **窗口长度 = 剪辑账 + 接缝余量**：`WAKE_SECONDS = 1.15`（8 帧 / 7 fps = 1.143 s），与 `LAND_CLIP_SECONDS` 同一条写法：常量抄的是 `CLIPS` 里的 fps 与帧数，注释留算式。时长旋钮只有 `CLIPS` 的 fps 与帧数两处，不留第二份语义。
8. **复活不重演**：`respawn()` 里清 `_wake_remaining`。醒过一次就是醒着的人，回存档点不该再躺一遍 —— 顺手把锁也清了，免得死在窗口里的人带着一把没人收的锁复活。

**契约变更**：`Main` 多一个**按名字读**的入口 `take_intro`（`LevelBase` 走 `root.call()`，与 `get_run_state` 同一条通道）；`Player` 多 `begin_wake()` / `is_waking()` / `WAKE_SECONDS`。不吃门控 delta、不加存档键、不动层契约。

**守门**：`sprite_selftest` 第 1 组帧表加 `"wake": [8, false]`（顺带被第 3 组那条「全剪辑最宽 ≤36 px」扫到），新增第 11 组钉窗口内皮 = wake、方向/下/跳三键一律不生效、窗口过后自动交还移动锁、`respawn` 不留窗口不留锁；`kit_selftest` 的 `Main` 替身加 `intro_enabled` 开关（默认关 —— 其余 17 组的人在等落体与回灌，凭空被锁 1.15 秒是埋雷），新增第 18 组钉接线（第一次进关演、消耗记在常驻根身上、同进程第二张关卡实例不演且不带锁）；`verify_kit` 新增 `METHODS` 名单，把 `Main` 那四个按名字读的入口逐个点名 —— **改名即静默不演，这类"没人报错只是动画再也没有"正是这条守门存在的理由**。四条全绿（`VERIFY DONE doors=3 pistons=2 fallzones=0 failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`）。

**踩到两条**：① 第一版 wake 最宽帧 40 px，被第 3 组当场拦下 —— 改的是 `w` / `flare` 的数值（扫到 34/1.04 那档），**没有去松那道门**；门管形状上限，不管这坨好不好看。② 皮比状态慢一帧：`begin_wake()` 同帧断言 `_sprite.animation` 会读到 `idle`，那是 `PlayerVisual` 在自己那一拍里换剪辑的正常结果，不是 bug —— 断言要先走两帧。

**How to apply**：以后"开局 / 过场 / 一次性"的演出，先查现成那三样：**掐输入有没有现成的锁**（D41）、**时钟走哪条**（一次性 = 固定步长，循环 = 门控 delta，D54）、**皮有没有第二处读数**（有就得像蹲伏那样单独补一条，不然就是谎）。而"这件事只发生一次"的记账一律做成 **take（取走即消耗）**、住在比场景活得久的那个节点上 —— 凡是"让读的人自己记得写回"的设计，早晚会漏成一局演一次。

> **订正（D58，2026-09-24，本条的接线全部原样保留、皮整块换掉）**：他试玩之后的两句是「动画太快了」「和向下压扁的动画几乎一模一样」。**结构第 1~6、8 条一字未动**（`Main.take_intro` / `_maybe_intro` 的顺序 / B2 整段掐输入 / 皮不许说谎 / 复活不重演，全都在原地工作），推翻的是**第 7 条的那份帧表**与它对应的时长：8 帧 / 7 fps = 1.143 s 那一档换成了 12 帧 / 5 fps = 2.40 s、`WAKE_SECONDS` 跟着从 1.15 → **2.45**。下面第 6 条写的动作语汇（摊平睡着→眼皮抬一半→张嘴哈欠→弹过头→压回来）作为**意图**仍然成立，但"摊平"这一步的具体画法是错的，错在哪、量出来多少，全记在 D58。

### D58 · 苏醒那一拍的皮重做：「睡」不能走在压扁那根轴上（诊断量到像素级，选型先看图）

**起因（2026-09-24，用户反馈两句：「1.动画太快了 2.和向下压扁的动画几乎一模一样」；四条菜单裁定 **A3 + B1 + C1**）**

**先量，再猜。** 他那第二句是感官判断，但感官判断可以被量化成一张图：把 wake 的睡帧与 `crouch` 第 0 帧各自的 alpha 剪影拿出来，逐像素做对称差、除以并集，得到的就是"两帧有多像"的数。**V0（D57 落地那版）= 4.2% 差异**，也就是**九成六的像素重叠** —— 他的眼睛没有报错，那两帧几乎就是同一张图。**根因不是"细节不够"，是走错了轴**：`crouch` 是沿**压扁轴**（高↓宽↑、下摆外翻）的形变，而 D57 那版"摊平睡着"走的也是这根轴，于是两件事在画面上是同一条曲线上的两个采样点。
顺着这条又量了候选 **V1「侧倒瘫睡」= 2.6%**（**更差**）—— 我以为不对称能救它，但量下来救不了：侧倒与蹲伏仍然占据同一条高度带（h≈9~12）、仍然下摆外翻、剪影仍然左右大致对称，连"闭着的眼睛"都只差 1 px。**结论：差别必须出现在轴上，不是出现在细节上。** 于是换成**收缩轴**（身体收窄变圆、`flare < 1` 让下摆往里收、脚趾那对 nubs 全收起）→ **V2 / V3 = 10.4%**，是 V0 的两倍半。

**裁定**：

1. **A3 = V3「收团而睡 + 点头打盹」，12 帧**。语汇：缩成一团睡着（4 帧，只靠 `wave_offset` 与 1 px 的高度起伏做呼吸）→ **点头三下**（`dome_lean` 在 +4.5 / −1.5 之间摆，头颈错位而不是整只倾斜 —— 这是"睡"最可读的形状信号，且不碰高度带）→ 眼皮抬一半 → 张嘴哈欠 → 弹起过头 → 压回来收拾。最后一帧**与 `idle` 第 0 帧一字不差**（`dict(w=31, h=25)`），这条沿用 D57 第 6 条：不循环的剪辑，停在哪一帧就是玩家看见的第一眼。
2. **B1 = 5 fps**（他嫌快的直接修法：帧数 8→12、fps 7→5，总时长 1.143 s → **2.40 s**，一倍出头的节奏放慢全在 `CLIPS` 那一处，状态机零改动）。
3. **C1 = 整段掐输入**（我推荐过"落地即撒手"，他没选）：`WAKE_SECONDS = 2.45` 这 2.45 秒里方向键 / 跳跃 / 下蹲**全不响应**，窗口到点自己撒手。代价摊开说清楚：这是一段玩家不能动手的时间，而它每次进程启动都要演（D57 第 1 条）—— 他认了这条代价，那就按他认的做，别偷偷加个"提前结束"的后门。
4. **36 px 那道门不许松**。V1 候选最宽帧 41 px（侧倒把整团质量甩向一侧），会被 `sprite_selftest` 第 3 组「全剪辑最宽 ≤ 36 px」当场拦下 —— 那是 40 px 最小门洞的护栏。改的是**画的数值**（收窄到 35 px），与 D57 踩到同一道门时的处理方式一致。V3 最宽 34 px，天然在门内。

**选型工具（新增 `tools/gen_wake_preview.py`）**：菜单不再是文字选项，是**一张图 + 一段会动的图**。落盘做法：候选帧表在运行时注册进 `gen_player_frames` 的 `FRAMES` / `CLIPS`，然后**直接调 `g.render()`** —— 选型图与游戏内帧走的是同一个函数，不存在"图里好看、进游戏两样"（D56 那条"同一块牌不许两处书写"在这里的延伸）。两样产物：`assets/player/preview_wake_sheet.png`（V0/V1/V2/V3 + `crouch` 参照共五行逐帧摊开，2 倍红框画出 20×30 碰撞盒，让他一眼看见"睡帧的高度带正好压在蹲伏的位置上"）与 `assets/player/preview_wake_anim.gif`（五行**原地各自动**，tick 集合取各行切换时刻的并集，候选行播完停在末帧、`crouch` 参照行循环 —— 对照关系不用眼睛在两行之间来回跳）。两个坑记一下：① 每格宽度必须按放大后的实际像素算（第一版把 288 px 的格图按 120 px 的间距贴，邻居互相涂掉，出来是一条条碎片）；② PIL 默认字体画不出中日韩，标签全是方框 —— 用项目里现成的 `gen_props._font(15)`。GIF 那侧用 `GIF_ZOOM = 2`，与引擎内的 zoom 同档，"图里的节奏"就是"游戏里的节奏"。

**契约变更**：无。改动全在帧表、一个常量的数值、以及一处守门写法。`begin_wake()` / `is_waking()` / `take_intro()` / `PlayerVisual._pick()` 的语义一字未动 —— 这正是 D57 那次接线做对了的证明：**换皮不需要动骨架**。

**守门**：`sprite_selftest` 第 1 组帧表 `"wake": [8, false]` → `[12, false]`；第 11 组那条**等窗口结束**的写法从 `_step(70)` 改成**轮询到点为止（带上限 400 帧防死等）**。这是这一条里唯一的技术性教训：D58 只改了时长，而上一版的写法把"1.15 s 换算成多少物理帧"钉进了断言里 —— 帧表一变（1.15→2.45 就是 +78 帧）它就会**假红**，而假红的守门比没有守门更坏，因为它教会人忽略红。改成轮询之后断言的是行为（"窗口会自己走完并把锁还回来"），不是常数。同一组里 `respawn` 那条与两处"皮慢一帧"的 `await _step(2)` 口径不变。四条无头守门全绿（`SPRITE SELFTEST DONE failures=0` / `[kit-selftest] done failures=0` / `VERIFY DONE doors=3 pistons=2 fallzones=0 failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`）。像素归他看，无头管不着（D46）。

**过程教训（比这条内容更该记住）**：D57 的裁定信里我写了「先出图再落盘」，然后**没有出图就落地了**，只在最后一次口头复述里附了帧表。他这次的两句反馈，本质就是那次欠的账 —— **在皮这件事上，他给的字母选项裁定的是"文本"（语汇、时长档位、掐不掐输入），皮肤本身只有看见才算数**。所以这一条从第一步就是先出选型图、等他指认，再碰 `gen_player_frames.py`。

**交付**：`tools/gen_wake_preview.py`（新增）、`tools/gen_player_frames.py`（`wake` 帧表 + fps）、`assets/player/slime/wake_{0..11}.png`（8 帧改、4 帧新增，含 `.png.import`）、`clips.json` / `slime_frames.tres`（重建，`uid_kept=true`）、`player.gd`（`WAKE_SECONDS`）、`sprite_selftest.gd`、`assets/player/preview_wake_sheet.png` / `preview_wake_anim.gif`。

**How to apply**：以后凡是"新动作要和某个已有动作并存"（睡/蹲、跑/走、轻推/重撞），**先量剪影重叠再讨论好不好看**：alpha 对称差是一个不需要审美的数，它能把"看着很像"变成"96% 重叠"，也能证明"我以为的差别（侧倒 vs 摊平）其实不存在"。而量出来重叠高时，修法是**换形变轴**（压扁轴 ↔ 收缩轴 ↔ 倾斜轴），不是往同一根轴上加细节。选型一律以图交付，且图必须由**落盘的那个渲染函数**直接生成。


### D59 · 世界钟：让「停下来的不是我、是世界」这件事有一处可看（全项目第一个纯装饰构件）

**起因（2026-09-27，用户：「制作一个新的时钟场景，方便玩家在第一次获得能力时判断自己得到了什么能力，符合前面的画风」；七档选型图 + 走 / 停动图，裁定 **形状 = 4 号（12 段走带）**，其余五条全按推荐：D1① 纯函数 / D4① 只有亮格停 / D5 纯装饰构件 / D6 三钉 / D7 摆位归他）**

**问题的准确形状**：能力没有 HUD、不许有字，而"冻结"今天唯一的符号是全屏那层 CRT（D46）。那层滤镜说的是**画面变了**，但玩家要判断的是**我得到了什么** —— 那条判断需要一个"本来在动、现在不动"的东西做对照。仓库里查过一遍：没有任何钟；`scenes/ui/debug_overlay.gd:41-59` 有 `world_time`，但那是开发面板且带字。一只钟是这里唯一一个**动的理由就是世界时间在走**的物件，所以它天生就是那条对照 —— 它教的不是"钟"，是"停的是世界"。

**七档读数**（`tools/gen_clock_preview.py`，底片 = spot0 那块空地板、与 D54/D55/D56 同一条尺子；一律量 1:1 真机那一份、按点集不按外接盒）：

| 档 | 亮部/盘 | 亮部/墙 | 壳/墙 | 亮部世界 px | CRT 削顶 |
|---|---|---|---|---|---|
| A 圆盘 18×18 青针 | 11.83 | 4.33 | 3.06 | 6 | 12 |
| B 同形亮白针 | 13.49 | 4.93 | 3.06 | 6 | 12 |
| C 方壳圆窗 18×22 + 运行灯 | 11.40 | 4.26 | 2.03 | 14 | 28 |
| **D 12 段走带（选定）** | 5.21 | **1.94** | 3.69 | 24 | 21 |
| E 沙漏 14×18 | 4.98 | 4.33 | 3.04 | 52 | 104 |
| F 齿轮 18×18 八齿 | 10.79 | 4.22 | 2.94 | 4 | 8 |
| G 摆钟 18×24 | 10.89 | 4.20 | 1.61 | 12 | 24 |

**4 号的代价摊开说清楚**（D46：数字只陈述，不替他否决审美，但欠账要写在账上）：它的「亮部对墙」1.94 是七档里最低的一档，因为三段青色余辉把均值拖到了墙那一档；未点亮的槽是 (160,163,169) 的灰亮，1:1 下整圈读起来是"一圈灰点 + 一颗青"。他看图挑了它，那就按图落地。

**时基（D1①）**：`segment_index() = int(fmod(elapsed_world_time / period, 1.0) * 12) % 12`，**世界时钟的纯函数**。为什么不用 `TimeReceiver` 自带累加：两者数值上等价（冻结那一拍两边都加 0、都与帧率无关），唯一区别是**起点** —— 自带累加的那只钟在新关卡装载、存档回灌后会带着一个偏移重新起跑，而 `elapsed_world_time` 是 `reset_state()` 归零的那一个。守门 ① 钉的正是这条：fixture 在世界时钟已经走了一段之后才进树，两条实现当场差出好几格。顺带一条 D54 的时钟通道规矩仍然成立：**循环 / 环境性的动吃门控量，一次性的演出吃原始 delta** —— 这只钟属于前者，但它连"门控 delta"都不吃，它吃的是那个更上游的事实。

**D2 这条选择被形状自动消掉了**：走带没有连续量，"扫动 vs 步进"不存在可选，一格 = `period/12`（8 s 档下 0.67 s）。而且真机 2 px 宽的指针在 4×4 设备像素里只剩一条（A/B 亮部实测只有 **6 世界 px**），走带的最小单元是 3×3 = 9 世界 px —— 同一档尺寸里最抗 CRT 削顶的画法就是它。

**皮同源（量到了像素级）**：`clock.gd::_paint()/_paint_rim()` 与 `gen_clock_preview.py::cand_segments` 逐格比对，三档相位（idx 0 / 3 / 7）**972 格 0 差**。这条比对不需要渲染器（无头没有光栅化），比的是**网格**不是像素输出 —— 所以它今天真跑过、明天也能进守门。GDScript 里那个 `_r()` 是为了对上 Python `round()` 的"四舍六入五取偶"：`8.5` 那三处（上下两格与轴心）Python 落 8、GDScript 的 `round` 落 9，不处理就是整只钟偏一像素 —— 偏出来还是一只钟，但**就不是他批过的那张图**。

**三个真错，全是出图 / 落盘路上抓出来的，比这条决定本身更该记**：

1. **量法在骗人**：预览的 `Cv` 把"一个点被画过几次"重复记进同一类点集，于是 D 那圈未点亮的槽同时留在分母里。我把槽调亮之后「亮部对盘」从 6.10 塌到 **1.43**，看着像画坏了，其实是分母被自己刚调亮的点污染。修法是后画的说了算 + 点集去重 + 空集报 `n/a`（空集时 `_mean_pts` 返回纯黑的假分母，能把读数推到 20 或压到 1，两种都够骗人）。
2. **图在骗人**：预览画布初始化成 `(0,0,0,255)` 不透明黑，于是**七只钟各自背着一块 18×18 的黑盒子**贴进真帧 —— 而他据此挑了 4 号。黑盒子对那面墙的比是 3.7 上下，跟亮白环一样显眼，但读数里根本没有它（分母取点集、不取 alpha）。修完重出图，读数只差 0.08（3.61→3.69）：**数字一直是对的，错的是那张图**。这是 D46「数字只陈述」的反面教训 —— 图错了，数字对也没用，因为他裁的是图。所以重出图之后要主动告诉他图变了。
3. **同一个根因在引擎里复发**：`Array[Color].resize()` 填的是**不透明黑**、不是透明。忘了 `fill(COL_BLANK)` 就是拿一块黑盒子糊在墙上，而且描边那一圈会因为"四邻都有人"整块消失。所以 `_verify_clock()` 里加了网格三条：四角必须透明、占格率 0.4~0.95（圆盘 r=8 实测 ~0.62）、描边像素必须 > 0 —— 三条都不需要渲染器，都在当场复现那两种死法。

**契约面（D5）**：`scenes/objects/clock/clock.gd` + `.tscn`，`@tool`、根是**纯 Node2D**（零碰撞体、零子节点，连 `TimeReceiver` 都不挂）、视觉全在 `_draw()`、零 PNG 零件、原点 = 底边中心（**不加第五个例外**）、不发 signal、不进 `run_state`、`LevelBase` 不认识它。导出项只有一个 `period`（手感旋钮，守门不绑它的默认值）。守门里钉了一条"脚本里不许出现 `signal `"：它一旦开始有契约面，「纯表现走零契约」这条（D56）就烂在这儿，而且没人会想起来删。

**为什么不是装饰图集格**：`TileMapLayer` 不能逐格动画（D56 那条），而这只钟的全部意义就是动。于是它是全项目第一个**不改任何机制的构件** —— 现有构件每一个都有契约面，这一个的契约面是"没有"，这本身就是需要被守门钉住的那件事。

**冻结那一拍不多给收据（D4①）**：不加运行灯、不变暗、不闪。备选 ②（针停 + 一颗运行灯灭，即 C 档实物）留在这儿没否掉 —— 如果以后想让"这台机器在运行"讲给还不知道规则的人，那是唯一值得回头加的一档。

**摆位与教学时机（D7，图归他摆）**：建议**祭坛之前先摆一只** —— 他先习惯"它在走"，第一次按住方向键时它停了，对比最强；只在祭坛之后摆，"停"就没有基线。场景可以直接拖进关卡的 `Objects/` 下，不需要接线。

**守门**：`verify_kit` 四表齐全（`SCRIPTS` / `TOOL_SCRIPTS` / `SCENES` / `EXPORTS` 白名单 `period`）+ `_verify_clock()`（源码形状三条 + 网格三条）；`kit_selftest` **第 19 组**三钉：亮格 == 当场独立重算的 f(世界时钟) / 冻结 20 拍一格不走**且世界时钟本身也没涨**（后者把"停"的归因钉在表上而不是钟上）/ 解冻后接着走且不漂。四条无头守门全绿（`VERIFY DONE ... failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`）。

**跑法上有个假绿的坑**：`--quit-after` 的帧数上限给小了（4000）会把自测**拦腰截断** —— 它不打印 `done failures=` 那一行、退出码还是 0。第一次跑就是这么"绿"的。截断的自测比红了的更坏，因为它看起来像跑过了。这条按 60000 重跑才算数。

**交付**：`scenes/objects/clock/{clock.gd, clock.tscn, clock.gd.uid}`（新增）、`tools/gen_clock_preview.py`（新增）、`assets/props/preview_clock.png`（含 `.png.import`）与 `preview_clock_anim.gif`（评审件，不入库）、`tools/verify_kit.gd`、`tools/kit_selftest.gd`。

**How to apply**：以后凡是"要让玩家看懂一条没有文字的规则"，先找一个**动因就是那条规则**的物件，而不是加一层 UI 或一条提示 —— 一只钟之所以够用，是因为它动的理由恰好就是世界时间在走，规则被证伪的那一刻（它停了而玩家还在动）就是能力被看见的那一刻。第二，**图和数必须同源到像素级**：这次的比对是 972 格 0 差，而它抓出来的三个错里有两个是"图自己错了、数是对的"，也就是说 —— 拿图当裁定依据的流程，前提是那张图真的等于出货的皮。

> **订正（D61 期间，2026-09-27 —— 本条的接线与语汇全部原样，只有 B1 那一档的 fps 变了）**：他在编辑器里把 `wake` 拧成 **4.0 fps + 首帧 duration 2.0**（总长 2.40 s → **3.00 s**，人醒得更慢）。这两格今天已经**写进 `gen_player_frames.CLIPS`**，`tools/build_slime_frames.gd` 也支持逐帧时长回写 —— 不写进去的话，`.tres` 是从 `clips.json` 重建的，**任何一次重生成都会把手调好的手感抹回帧表旧值**（这条属于 D27 那条"两处书写"的家谱，只是这次第二处写在生成器里）。**还有一笔没还的账，交给他定**：`Player.WAKE_SECONDS` 仍是 **2.45 s**（D58 当初与 2.40 s 的剪辑对齐），现在皮比窗口长 0.55 s —— 苏醒窗口到点撒手时剪辑才走到第 9.8 帧，**最后那两帧永远看不见**。改哪一边都行（常量提到 3.0，或把 fps 调回 5.0），守门不会红：它钉的是"窗口会自己走完并把锁还回来"，不是常数。

---

### D60 · 一块活塞被多台按钮驱动：合成口径选 OR，字段换成一列（一次明码标价的破坏性改动）

**用户原话**：「修改pistionblock的代码，我希望一个blocl可以被多个button控制」。裁定：**①=A（OR 合成）+ ②=a（干净断：`trigger` 换成 `triggers: Array[NodePath]`，不做兼容）**。

**为什么是 OR 而不是 AND**：他要的是"多个按钮都能控制这块"，那就是任一即可。AND（"全踩着才伸"）是另一种摆法，本-kit 不提供 —— 那需要关卡脚本自己读两台的 `is_pressed` 再调 `set_out()`，而"脚本驱动"这条路一直是留空 `triggers` 那一档在管的。

**核心决定：合成的是"当前状态"，不是"事件流"**。最容易写出来的版本是把信号参数直接抄进 `is_out`（`func _on_pressed_changed(v): is_out = v`）—— 它在全场只有一台触发源时是对的，多台的瞬间就成了能杀人的写法：**A 还踩着、B 一松，人脚下的落脚点被抽干**。所以每台触发源各记一格 `_state[source]`，`is_out` 由 `_refresh_out()` 把所有在册的格子做 OR 得到；信号回调只写自己那一格再重算。读当前值还白送第二条：**一台触发源被 free 掉，它就从合成里退出去了**（`is_instance_valid` 那一道），不需要谁去通知活塞。

**契约从"发信号"扩到"发信号 + 暴露 `is_pressed`"**：连接那一刻读一次 `source.get(&"is_pressed")` 兜种。不读的话，"活塞进树之前按钮就已经被人踩着"这一种起手会读成没踩（信号是变化沿，不是电平）—— 而按钮是场景里摆好的、活塞也是，谁先进树完全取决于节点顺序，这种坑不该由摆图的人负责。`ButtonPlate` 与 `SensorZone` 两个触发源本来就都有 `is_pressed`，所以扩的是契约文档而不是任何构件的代码。

**破坏性改动是当着他的面选定的**：`.tscn` 里旧的 `trigger = NodePath(...)` 那一行在新脚本上不存在对应导出项，于是**关卡里已接好线的三块活塞全部变成未接线**，`verify_kit` 各报一条 FAIL（"活塞 X 的 triggers 是空的"）。他选的正是这一档（"a"），代价在菜单里写明了。迁移是**逐格重拖**（一列数组没有文件夹按钮，从场景树拖进格子里），我没有改他的关卡文件，也不打算改。

**门那头一字未动**（还是单值 `trigger`）：一条检查函数吃两种形状（`_check_trigger_wiring(..., prop)`，单值当成长度 1 的列看），而不是给活塞另写一条 —— 两种形状的差异属于构件，"接线必须指到真的发 `pressed_changed` 的节点"这条属于守门。

**摆图侧新增的一条约束（同 D49 口径，写进手册 §5）**：多台触发源指同一块是合法的，但**它们必须说的是同一件事**。OR 之下"两台开关隔着两个房间"意味着任何一台被踩都会把另一台那边的落脚点抽走 —— 那是设计而不是 bug，可是它只有在摆的人知道的时候才是。

**守门**：`kit_selftest` 第 13 组从四档 20 钉变**五档 34 钉**，新增的 e 档全部对着"多对一合成"这一件事：A 松 B 还踩着不许缩（杀事件流写法）、同一台填两格只算一台、换列时按**当前值**重算（出列那台即使还踩着也不参与）、触发源在进树前就踩着 → 起手就是伸出态。`verify_kit` 的接线检查改成吃列并**逐格点名**（整列空、某格空、某格指不到、指到的那台不发信号，四种各一条 FAIL）。四条无头守门：`kit-selftest done failures=0`、`SPRITE failures=0`、`TILESET failures=0 checks=316` 全绿；`VERIFY` 剩三条 FAIL，**全在用户未提交的 `level1.tscn` 的那三块活塞上**（就是上面那笔明码标价的账，不由我修）。**订正（2026-09-27，D61 当天跑守门时看到的）**：那三格已由他自己重拖完（`triggers` 现在是 `[ButtonPlate3, ButtonPlate4]` / `[ButtonPlate2]` / `[ButtonPlate2]`），`verify_kit` 现报 `pistons=3 failures=0` —— 这笔账结清，"D60 有一条已知例外"不再是当前状态。

**交付**：`scenes/objects/piston_block/piston_block.gd`（导出项、`_state`/`_bound`/`_link_ends` 三件套、`_reconnect_triggers`/`_unbind`/`_sources`/`_refresh_out`、编辑器里"每个触发源各一条橙线"）、`tools/verify_kit.gd`（接线检查吃列 + `EXPORTS` 白名单改名）、`tools/kit_selftest.gd`（fixture 的 `sources` 参数 + e 档十二钉）、`docs/level_authoring_guide.md`（§0 第 5 步、§5 活塞行、§10 一条、§12 两条）。

**How to apply**：一，**凡是"多对一"的合成，先问合成的是电平还是事件**。事件流写法在单源时永远测不出错，多源的第一天就红，而且红在玩家身上 —— 这次它是被一条断言（"A 松开而 B 还踩着时不许缩"）挡住的，不是被 review 挡住的。以后再加"多个传感器共同决定一件事"的构件（同一盏灯被多个感应区点亮、一个机关被多把钥匙解锁），照这个 `_state` + 重算的骨架来，别照信号回调来。

---

### D61 · 能力获取那一拍重做：从「祭坛演一拍」改成「人被这一拍卷进去」（16 帧 / 5.0 s、程序化光柱 W12、爆发那一帧钉住世界 1.25 s）

**起因（2026-09-27）**：五轮选型图（`tools/gen_grant_preview.py`，底片是 spot2 真帧）之后的裁定是 **①=A3**（爆发那一帧把世界钉住约 1.25 s）、**②=B2**（运动学举升，撞到天花板就停）、**③=C2**（每眼独立旋钮 + 一条 `grant` 剪辑）、**④=D2+D3**（青环放大 + CRT 压紧，**不做全屏白闪**）、**⑤ 演出归 Player、`grant_time` 1.05→5.0**；光柱形状 **W12**（12 束、全摊角 9°、行程 480 世界 px），亮度 **45%**，消失 **散三帧**，青环与光束**同帧并存**。他要的那一句是：「三角形白色光柱应该和现在的反过来，尖端朝内，然后无限延长铺满屏幕，其实表示的是光线从中射出」，以及「我希望光束从动画一开始时就逐渐出现，从细变粗并围绕主角旋转，最后在爆炸时填满屏幕并消失」。

**问题的准确形状**：D44 那一拍是**祭坛自己演的** —— 核心浮起、飞进胸口、三枚环散开，全程 1.05 s，人站着不动、照常能跑能跳。D59 那只钟教的是"停的是世界"，可**第一次拿到能力**这一下玩家身体没有参与，所以那 1.05 s 说的不是"我得到了什么"。要做成"人自己动"，D44 那两条便宜话（不锁移动、不碰 `TimeManager`）都必须推翻：被举起来就得锁移动（否则方向键把人从演出里拽走），要"爆发的一瞬全世界停一下"就得碰 `TimeManager`。**所以这一条不是加细节，是把演出的所有权从构件搬到玩家身上。**

**⑤ 所有权（这一条的根）**：`Player.begin_grant(duration)` / `is_granting()` / `grant_progress()`。`AbilityAltar` 只剩两件事：发 `ability_granted`（契约一字未动）+ 把时长递给玩家（`_courier.begin_grant(grant_time)`）。`grant_progress()` 是这一拍的**唯一进度事实**，祭坛的环、身体的发光、玩家自己的举升、光柱的长度全读它。

**时长同源（这一条的核心纪律，`kit_selftest` 第 20 组前七钉全在这里）**：`grant_time` 不是手感数值，它是**剪辑长度** —— 16 帧 / 3.2 fps = 5.0 s 整。于是钉下去的一串等式：`Player.GRANT_FRAMES == 剪辑帧数`、`GRANT_LIFT.size() == 帧数`、`AbilityAltar.FLY_END == 9/16`（核心进胸那一帧**就是**爆发那一帧）、~~`RING_END == (9+3)/16`~~（**2026-09-29 随那三枚环一起删**，见本节末的订正）、`CHEST_Y` 只有一处定义（祭坛 `const CHEST_Y = Player.CHEST_Y`）、`GRANT_PIN_FRAMES/16 × 5.0 == 1.25`。**为什么值得钉这么多条**：抄错不崩、不报错，只是皮与曲线在某一帧悄悄错开半拍，而那只有逐帧回放才看得见。

**② B2 举升为什么按帧标**：`GRANT_LIFT` 是 16 个"脚底离祭坛帽顶的世界 px"，帧时刻之间线性插值。不选"速度 + 重力积分"，是因为他要的是**图里那一帧的高度 == 游戏里那一帧的高度**（D53「图赢过口头裁定」的延续 —— 前提是图真的等于游戏）。

**订正（2026-09-27，他看完实装提的一句「我希望玩家被渐渐举起，与光束的动画同时进行」）**：出货第一版前 3 帧就冲到 48、3..8 悬在半空、9 爆发那一下再顶一次；而光柱的行程铺在 0..9 整段 —— 也就是**人先到位、光束还在长**，两条各走各的时间，"被这一拍卷进去"读成了"先站上去看戏"。现在举升与光柱**共用同一段 0..9**，缓入缓出（0 / 2 / 6 / 12 / 20 / 28 / 36 / 42 / 46 / **48**），峰值 48 px = 整三格瓦片，**正好落在爆发那一帧**（"到顶之后再窜一次"那一笔随之消失 —— 它本来想说的就是"和光柱一起到位"，现在由曲线自己说）；10..13 落回地面（脚底在帧 13 触地 = 钉住窗口 [9,13) 结束的那一拍），14 开心得又弹 8 px、15 收住。**契约零变更**：帧数、峰值 48、爆发帧 9、钉住 4 帧这四个数一字未动，所以 `kit_selftest` 第 20 组那串对表与 `sprite_selftest` 第 12 组那句「爆发那一帧人被举到 48.0 px」原样全绿 —— 改的只是中间那 14 个数。**这条曲线能按帧兑现的前提顺手记一句**：这一拍里 `_physics_process` 在 `_advance_grant()` 之后**直接 return**，重力与 `move_and_slide()` 全程不参与，所以头几帧"每帧只升 2 px"不会被下坠速度吃掉；若当初写成"曲线 + 重力积分"，这条缓入根本走不出来。**图必然同步**：`tools/gen_grant_preview.py` 的 `_shipped_lift()` 是**从 `player.gd` 把这段数组读回来的**（不是第二份抄写），所以只重跑了选定那一行 —— `preview_grant_w12.png` / `.gif` 与 `preview_grant_final.gif` 三张跟着新曲线重出。
"撞到天花板就停"**刻意没有上限状态**：举升是逐帧 `move_and_collide()`，撞了就把那一步的 `get_remainder()` 从位移里减掉 —— **被挡住的那段位移不被记录**。于是"停在接触面"、"顶住期间不攒高度"、"曲线下来时他照样下来、不粘在天花板上"三件事是同一条式子的三个推论，不是三段代码。挡没挡住读的是 `move_and_collide` 的返回值，**不是** `_head_blocked()` 那套现成判定 —— 那套是给"站在地上的自由形变"用的，读它会多出一个"头顶被挡"的迟滞状态，而举升根本不需要状态。

**① A3 的松手是全条唯一有技术风险的地方（也是 `TimeManager` 破例加第二条入口的原因）**：新增 **`release_frozen_override(moving: bool)`**。现有那两条为什么都不行：
- `set_frozen_override(false)` **只清开关**，把解冻交给意图通道 —— 那是给死亡那一拍用的（演完紧接着重载，新关卡 `reset_state()` 收尾）。能力这一拍演完人**留在原地**，于是"世界停在 FROZEN、再没人负责解开"就是这么来的。
- 事后补一次 `notify_movement_intent()` 也不行：那条通道在 `not is_ability_enabled` 时**整条静音**，而这恰好是玩家**第一次**拿到能力的当口（`_tick_ability` 可能还没开）—— 一静音就永久冻住；而且 handler 只在**边沿**上报，此刻它认为自己已经报过了。
所以松手必须把**当前意图**原样带进来、直接落状态：`_set_state(FROZEN if (is_ability_enabled and moving) else FLOWING)`。`kit_selftest` 第 20 组把三种组合各钉一次：**开×按 → 冻**、**关×按 → 流**（这一档正是上面那条静音陷阱；只清开关的实现在这里红）、**开×不按 → 流**（"永远退回 FROZEN"的写法在这里红）。钉住期间另钉两条：那一拍自己仍在推进（吃原始 delta，D44 第 2 条在钉住窗口里依然成立）而 `elapsed_world_time` 一字不涨。

**光柱构件 `GrantBeams`（形状 W12）**：12 束、全摊角 9°、行程 480 世界 px、**尖端朝内**、从第 0 帧就出现并**由细变粗 + 整圈转半圈**（`ease = 1-(1-k)²`、`spread = 4.5°×(0.12+0.88k)`、`spin = 0.5 圈`），爆发那帧铺满屏幕后**散三帧**（`alpha = 0.45 × min(1, k/0.15) × clamp(1-(tf-9)/3, 0, 1)`），亮度 45%，与青环同帧并存。
- 它是**代码建的子节点**（`_ready()` 里 `add_child` + `move_child` 排到 `Visual` 之前 = 画在身体背后），**我这一侧不碰 `player.tscn`**（他手上那份未提交的调校照原样留着）。守门钉两枚：身上有这件、且它排在 `Visual` 之前。
- 它是**零契约的纯表现构件**（D56 那条路）：不发信号、不进 `run_state`、不认识别的构件、`_process` 里只**轮询** `source.grant_progress()` 并"值变了才 `queue_redraw()`"。为什么轮询而不是信号：给一条已经是唯一事实的进度另发一个 `grant_progressed(float)`，就是同一处进度两处书写。
- **W12 在图上那条"频闪"警告在落地时自然消失了**：预览是**逐渲染帧**采样（离散步采才看得见跳），游戏里每帧按连续的 `progress` 现算，转过的角度约 **1.07°/帧**而不是 30°/帧 —— 没有可 aliasing 的离散相位，所以那档"分帧消频闪"的处理不需要写。

**③ C2 皮**：`grant` 走 A 档那 16 帧（疑惑靠"一只眼收"、开心靠四像素上翘的 grin —— 为此给 `gen_player_frames.draw_slime()` 加了 `eye_open_lr` 与 `mouth="flat"|"grin"` 两个旋钮）。`PlayerVisual._pick()` 把 `is_granting()` 排在 **`is_waking()` 之上、且排在所有空中姿态判断之前**：他被人举起来那几帧 `velocity.y` 是负的，不拦就是 `jump` —— 皮会说谎。`sprite_selftest` 第 12 组钉的是行为：窗口里按着方向键也不切 `start`/`run`、按下键不偷蹲、末帧交回后回 `idle`。

**顺手补的一处机制账（不是 D61 的内容，但它是 D61 的前置）**：他在编辑器里把 `wake` 手调成 **4.0 fps + 首帧 duration 2.0**，而 `.tres` 是从 `clips.json` 重建的 —— 只要帧表还写着 5.0，**任何一次重生成都会把他的手感抹回旧值**。所以本次把这两格**提升进 `gen_player_frames.CLIPS`**（`{"fps": 4.0, "durations": {0: 2.0}}`），并给 `tools/build_slime_frames.gd` 加了逐帧时长回写（时长存在 `SpriteFrames` 的**剪辑帧表**上，不在纹理上）。见下面的订正。

**没落地的两档（欠账写在明面上）**：
- **④ D3 的 CRT"压紧"（强度 >1 的外推）没做**。那层滤镜是 Main 级 `CanvasLayer`、今天只被驱动到 0/1 两档，要让强度按这一拍的进度爬就得给 Main 加一条新输入；而 A3 的钉住窗口**已经白送**灰态 + 扫描线（强度 1.0 那一整档）。所以出货件看到的是"钉住 = 全 CRT"，图上那种"对比再压紧一点"的 Punch 不在里面 —— `preview_grant_burst.png` 里那几格是**目标**，不是现状。
- 环的**线宽**保持出货件的 2.0 世界 px（预览在 2× 超采样下画的是 1 世界 px），所以图里的环比游戏里的粗一档。要图上的观感就改 `draw_polyline` 那一个数。
- `GLOW_TIME` 从 0.45 提到 **0.95 s**：那正是选型图里 9/10/11 三帧的亮度阶梯（1.0 / 0.55 / 0.2 各 0.3125 s），不改就等于图上的亮三拍被压成一拍半。

**契约变更**：`Player` 多三个公开方法与几个常量（`GRANT_FRAMES` / `GRANT_BURST_FRAME` / `GRANT_PIN_FRAMES` / `GRANT_LIFT` / `CHEST_Y`）；`TimeManager` 多一条松手入口；`AbilityAltar.grant_time` 默认 1.05 → 5.0（**没有任何 `.tscn` 存过这一项**，所以 level_1 与 m1_sandbox 不改就跟上新默认值）；新增 `scenes/actors/player/grant_beams.gd`（`class_name`、无场景、无 PNG 零件）。关卡侧、存档侧、危险物侧零改动；`mark_spent()` 回灌那一档不变（复活的人不重播这一拍），`respawn()` 多清三个举升相关状态（**刻意不在此解世界钉** —— 那条属于 D42 的死亡路径 + 新关卡的 `reset_state()`）。

**踩到的两条**：① 新建 `class_name` 之后守门读不到类型（`Parse Error: Could not find type "GrantBeams"`）—— `.godot/global_script_class_cache.cfg` 要靠**再跑一次 `--headless --import`** 才更新，改脚本不会让它自己刷新。② `Player` ↔ `GrantBeams` 互为类型（构件读 `source: Player`、玩家持有 `GrantBeams`）在 GDScript 里编译得过、跑得也对，不需要为破除循环而退回字符串路径 —— 这一条以前默认"要避免"，实际是**不需要避免**。

**守门**：`sprite_selftest` 第 1 组帧表加 `"grant": [16, false]`（自动吃下"全剪辑最宽 ≤36 px"那道门，实测 36 px **顶格**）、新增 **第 12 组**（窗口 / 皮 / 掐输入 / 举升峰值 / 顶棚停住 / 不粘顶 / 松手回流 / `respawn` 不留窗口不留锁 —— 全程**轮询到点**，不掐常数帧，D58 那条口径）；`kit_selftest` **第 20 组**（对表七钉 + 真接线：踩祭坛即交给玩家、两边进度同源、钉住期间自己推进而世界时间不涨、钉住宽度 == 4/16、松手三组合）；`verify_kit` 与 `tileset_selftest` 这一条**没有新面** —— `GrantBeams` 不是场景、没有导出项，把它塞进 `SCENES` 白名单等于给它一个假身份。四条无头守门全绿：`VERIFY DONE doors=3 pistons=3 fallzones=0 failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`。

**交付**：`tools/gen_player_frames.py`（两个旋钮 + `FRAMES["grant"]` 16 帧 + `CLIPS` 的 fps/逐帧时长）、`assets/player/slime/grant_{0..15}.png`（含 `.png.import`）与重出的 `wake_*.png`、`clips.json` / `slime_frames.tres`（重建，`uid_kept=true`，他那格 `"duration": 2.0` 原样在位）、`tools/build_slime_frames.gd`（逐帧时长回写）、`scenes/actors/player/{player.gd, player_visual.gd, grant_beams.gd}`、`autoloads/time_manager.gd`、`scenes/objects/ability_altar/ability_altar.gd`、`tools/{sprite_selftest.gd, kit_selftest.gd, gen_grant_preview.py}`、评审件 `assets/player/preview_grant_{w12,sheet,burst,beams,timeline}.png` 与 `preview_grant_{w12,anim,final,beams,spin}.gif`。

**How to apply**：一，**演出要么归构件，要么归被演的那个人，别留第三态**。D44 把"人得到能力"这一拍放在祭坛身上，代价就是人不能动 —— 构件动不了别人的身体。以后凡是"这个角色身上发生了什么事"的演出（被举起、被推开、被点亮），入口都放在被演者身上，构件只**叫一声 + 递时长**，而"这一拍走到哪"的唯一读数由被演者持有。第二，**新增任何"钉住世界"的窗口，必须同时回答"松手时世界该停在哪个状态"** —— 这个陷阱没有编译期症状，红的是手感；本-kit 的意图通道有两条静音条件（能力未开、已被钉住），所以"清开关"与"再报一次意图"**都不等于**"接回现实"。第三，**图与游戏同源到"图反过来读代码"这一档才算真同源**：`gen_grant_preview.py` 现在读 `FRAMES["grant"]` 与 `player.gd::GRANT_LIFT`，重出的已批选型图与旧件**逐字节相同**（md5 对过）—— 这比"我照着抄了一遍"强，因为它把"改了游戏忘了图"这条路直接封死。第二，**破坏性改名可以选，但要当着用户的面选**：把"你已摆好的 N 处要重做"这条代价写进菜单，让他自己称一次；他点头之后再由他把那一处一处改回来 —— 我替他改关卡文件等于把他手上正在进行的摆图和我的迁移脚本混成一坨。

**订正（2026-09-29，用户实机看完这一拍之后的一句话）**：「关于获得能力时的动画，我希望去掉动画过程中角色中间的蓝色空心四边形」—— **胸口那三枚青色菱形环整块删掉**（`ability_altar.gd` 的 `_draw_ring()`、`RING_END` / `RING_STEP` / `RING_R0` / `RING_R1` / `RING_ALPHA` 五个常量、`_draw_flight()` 里那一段循环）。散开那一档从此**只由 `GrantBeams` 那十二根光柱承担**，核心飞行、举升曲线、爆发那一帧钉住世界、身体亮那一档**一律未动**，`grant_time` 与皮的对表账照旧成立。三条连带记账：① `kit_selftest` 第 20 组那条 **`RING_END` == 光柱散帧最后一帧的对表钉随之删除** —— 不是放松，是**没有第二处可对照了**（"散完"现在只有 `GRANT_BURST_FRAME + DISOLVE_FRAMES` 一个书写者），钉的位置留了一行注释，将来谁再为"散完"立第二个常量就该重新钉；② `CORE_COLOR` 这个常量**保留**，虽然删掉环之后代码里再没人读它 —— 它是"祭坛那团青 == `props.json` 的 `altar_core`"这条同源账在构件侧的落点（`verify_kit:899` 逐色比对、`gen_props.py` 的注释指回这里），删了等于把一条账弄丢；③ 本节上面「环的线宽保持 2.0 世界 px」那条、以及 D44 / D54 里提到「三枚环」的句子**从此都是历史**（D54 那条"彩蛋不复用祭坛那套语言"的裁定本身不受影响，那套语言的核心是"飞入体内"）。**契约变更：零**（无新信号、无新导出项、无新常量、关卡文件不用动）。

### D62 · 第一次获得能力时在祭坛那一格自动存一次档（只写重生位、不给灯）

**起因（2026-09-27）**：他的原话「接下来，一处代码修改，第一次获得能力时，我希望在能力祭坛处进行一次自动存档」。

**两条裁定（我摆菜单、他点的两格）**：
- **① 不给灯**：祭坛**不**并入存档点那一族 —— 不发 `checkpoint_reached`、不实现 `claim()/release()`、不长"亮着"那副皮。重生位换成他脚下那一格，代价是**这一刻起全关卡无灯**，玩家手上没有任何"这儿是回家处"的收据。
- **② 落点**：写在**那一拍演完**（`is_granting()` 的下降沿）而不是踩上那一帧，位置取**玩家自己的落脚点**。

**为什么 ① 值得单独记：它是"白送的架构"，而他选了另一头。** `LevelBase._bind_checkpoints()` 是**按信号名全子树扫**的（D28 那条"摆进场景树即生效，零接线"）。所以只要祭坛多发一条 `checkpoint_reached(position)`，整条存档链 —— 写两键、全关卡唯一激活、重载后点亮 —— **一字不改就自动接上**，`_relative_path()` 还能指回它自己。这是本-kit 少见的"加契约反而省代码"。他否掉之后，这一发**完全住在关卡编排里**：`AbilityAltar` 一行未动、`Player` 一行未动、`.tscn`/`.tres` 零改动，改的全在 `LevelBase`（外加 `main.gd` 那份键的文档）。

**② 的两个非显然处**：
- **下降沿靠轮询，不靠新信号。** D61 刚立过"进度只留一条事实，不给唯一事实另发一条信号"，而"演完了"本来就在那条事实里（`is_granting()` 由真变假）。`LevelBase._process` 里的 `_tick_grant_save()` 认这个边沿 —— 与 D16 那条"松手了没"的轮询同族。**多一根信号就是给同一处事实第二个书写者。**
- **不用祭坛原点当重生位，而且"站着还是跳着"必须在上升沿判。** 触发带宽 64 px、带心在地板以上，所以「踩上触发带」那一格**完全可以是空气**（跳进去的）。于是重生位取 `player.global_position`，并由 `_grant_stood` 记住上升沿那一刻的 `is_on_floor()`：那一刻它还是常规物理 `move_and_slide()` 留下的读数，说的是实话；**演完那一刻再读就不算数** —— 整段举升走的是 `move_and_collide`，而"那个标记在这条路上归谁更新"不该由我来猜（两种可能的语义下，"下降沿读它"都会得出错误结论，且错法是**静默不存**）。跳着撞进来的那一次不存：写进去的是一格空气，摔落点下方有什么正好是 D52 那一族「回到一个会立刻死的地方」。

**旧那台的灯必须灭（这不是一个选项，是 ① 的推论）**：D51 立的规则是「亮 = 现在死会回到这儿」。重生位被祭坛接走之后一台继续亮着就是说谎，所以 `_save_at_grant()` 顺手 `_set_active_checkpoint(null)` 并 `state.erase("respawn_marker")`。**抹掉而不是留个空路径**的理由：回灌那条链是 `if state.has("respawn_marker")` 才点一台，留着旧路径等于下一次重载把一台已经不成立的存档点重新点亮。为此 `_set_active_checkpoint()` 的形状改了一处 —— **null 从"直接返回"改成"全灭"**，并把释放抽成唯一的 `_clear_active_checkpoint()`（于是"谁亮着"这件事实全项目只剩一个释放书写者，`verify_kit` 把这个"1"钉住了）。

**顺带收的一种新谎（记在 D51 那本账旁边）**：`respawn_position` 现在有两个书写者，而 `respawn_marker` 可能**整条不在**。D51 那条"有读必须有写"在这里要反过来读一遍 —— 本次新增的不是键，是**一个合法的缺键状态**；`_apply_run_state()` 与 `main.gd` 的键文档各补了这一格，免得下一个会话把它当 bug 补回去。

**当前关里的实际收益（量过，别按动机想象）**：按 2026-09-27 那份摆图，祭坛在 `(-1750, 303)`、`PlayerSpawn` 在 `(-1692, 256)`，而四台存档点全在更右边（最近的 `Checkpoint2` 在 x=-1112）—— 所以这一发在 `level_1` 今天省下的**只有一小段**，它的价值在结构（"第一次拿到能力"这一刻从此是一个合法的回档点，第二章的关不再需要为此专门摆一台台子）。另有一条今天**根本不会上演**的：祭坛在所有台子之前，所以"踩过一台再回祭坛"这个顶灯场景在当前关走不到 —— 想验它得把祭坛挪到某台存档点之后。

**摆图硬约束的转移（已进手册 §8）**：存档点之所以要求「离任何危险物留一个盒宽 + 视觉余量」，理由是按着方向键死亡会在重载当帧再冻结 —— 重生那一格必须是**冻结中也安全的位置**。祭坛接管重生位之后这条**跟着转移到祭坛头上**：祭坛左右各一格内不许摆尖刺 / 电棒 / 残影杀区 / 活塞行程。再加一条它自己带来的：**别把祭坛摆在只能跳进去才够到的台子上** —— 跳着进来的那一次按裁定不存。

**契约变更**：零。构件侧、Player 侧、`TimeManager` 侧、`.tscn`、`.tres`、瓦片与零件全部未动。`run_state` 那四个键的**集合**没变，变的只是 `respawn_marker` 现在允许缺席。

**守门**：`kit_selftest` 新增 **第 21 组**（九钉，全走生产链，复用第 14 组那套 `_make_world_root()` + `_build_mini_level()` fixture）：先踩一台存档点拿到"旧的家"（否则"旧台被顶灭"那句断言是空的），再站上祭坛、**轮询**到那一拍演完 —— 重生位换成他落脚那一格（x≈3000 而不是 3100，且不等于旧值）、存的正是他此刻那一点、旧台熄灭、`respawn_marker` 不在；第二张 rig 里把人从 y=-160 掉进触发带，钉住"空中也会触发"这条前提，再钉那一发不写、以及他随后落回地面也不补写。`verify_kit` 新增 `_verify_altar_save()` 四条源码形状：祭坛脚本里不许出现 `checkpoint_reached` / `func claim` / `func release`（它一旦发了就会被 `_bind_checkpoints` 自动算成一台存档点，"不给灯"这条裁定会在**没人改存档点代码**的情况下被推翻）；`respawn_position` 的赋值点 == 2；`erase("respawn_marker")` 在位；`call(&"release")` == 1。四条无头守门全绿：`VERIFY DONE doors=3 pistons=3 fallzones=0 failures=0` / `[kit-selftest] done failures=0`（现 21 组）/ `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`。

**留给人眼的一条**：死了回到祭坛那一格、而**周身一台都不亮** —— 这读起来是"这游戏在这儿给我留了个位置"，还是"存档点坏了"？后者是 D51 那轮已经花过一次一次的信任。若他读不出，正解**不是**回去给祭坛加灯（那是他明确否掉的一档），要么就认这条代价，要么重开一轮选型图谈"祭坛那圈烧灼青印能不能同时承担回家处"这层新语义。

**How to apply**：一，**"不给反馈"是一条要被守门钉住的裁定，不是一个"没做"**。本次它有三枚钉子：祭坛脚本里不许出现那三个词、`respawn_marker` 必须被抹掉、`release` 只有一个书写者 —— 缺了它们，下一个会话看到"重生位没有对应的灯"会本能地当成 D51 的漏网之鱼去补，而那一补恰好推翻用户的决定。二，**凡是让一个已有事实"允许缺席"的改动，必须同时改那个事实的文档**（`main.gd` 的键清单 + `_apply_run_state()` 的注释），缺席状态没有代码症状，只有下一个人会把它当 bug。三，**判"他当时是什么姿态"要挑那个标记还归常规物理管的那一帧**：本例是上升沿。这不是通用规矩（上升沿 vs 下降沿哪个对，取决于中间那段代码走的是哪条运动通路），要问的是「**我读的这个引擎标记，在我读的这一刻，是谁写的**」。

### D63 · 活塞的反向档（没人踩着时停在满行程、踩下才收回）

**起因（2026-09-28）**：他的原话「一处代码修改：我希望 piston 有两种模式，一种与现在相同，另一种默认伸出，在按钮踩下时收回」。

**三条裁定（我摆菜单，他点的三格全是推荐档）**：
- **① 同场景 + 一个导出项 `rest_out`**，不拆第二个场景。
- **② 两档速度绑几何**：往洞口那一头一律 `retract_speed`(240)，往满行程那一头一律 `extend_speed`(60) —— 反向档只换"**谁**触发它们"，不换速度表。
- **③ 瞬落**：反向块进树当帧就落在满行程，不从洞里爬出来。

**① 要先回答的是他自己立过的规矩**：在册那条「行为不同就拆场景」（D49 前后立的，源于他否决"复用现成场景 + 加开关"）。这次我没有直接套现成的口子就往下写，而是把两条路摆成菜单让他称。**判据我按"几套触发 + 几套皮"来量，不是"几个方向"**：D49 那句射的是刷卡门 vs 按钮门那种**两套触发逻辑 + 两套动画**；这里翻的是"哪一头是常态"这一格 —— 触发源契约（发 `pressed_changed` **且** 暴露 `is_pressed`）、多台 OR 合成、积分器、`_draw` 那套皮、原点=收回态前缘、`_resolve` 挤开口径，**六样全不动**。在册的先例是 `travel_offset` 的符号：往左伸和往右伸也是"行为不同"，项目口径那是**值**不是场景。他点头选了①，代价我当场付在编辑器里（见下）。

**代码量是那一行**：`_refresh_out()` 尾部 `is_out = _level != rest_out`（电平与常态那一头的异或）。D60 那半（多台 OR）**一个字没改** —— 反向档下同一句话换成"任一台按下就收回、全部松开才伸回去"，因为合成算的是**有没有人踩着**，不是**在哪一头**。

**`_level` 与 `is_out` 分两格写是承重的，不是洁癖**：这次新增的开关如果直接放在 `_level` 上（"按下 = false"那种把输入翻个符号的写法），代码更短，但会把两处**必须读姿态**的地方一起带错：
- `_resolve()` 那条「只在往外走时才把人让开」——反向档下**踩着按钮的那块正在往洞里退**，那时候把人往墙里推才是错的。
- 两档速度的选择（②）——按裁定必须按"往哪一头"选，不是按"踩没踩"选。
所以 `set_out(bool)` 的语义也跟着钉清楚：**它说的是"哪一头"（位），不是"踩没踩"（电平）**，符号**不**套在这条路上；否则同一份文档里同一个入口有两种意思。下一次有任何源报状态时 `_refresh_out()` 会把它盖掉 —— 脚本驱动与接源驱动仍是互斥的两种用法（D49 原样）。

**③ 的两个非显然处**：
- **认的是 `rest_out`，不是 `is_out`**。第一版我写的是 `if is_out:`，自己改掉了：常态是**这块自己的属性**，不该取决于这一刻有没有源把电平翻过去 —— 源在 `_ready` 那一拍就已经踩着，说明那块**本来正被踩着**，那就不是它的常态位，瞬落到"满行程"反而替玩家把脚下的东西抽走。
- **刻意不走 `_resolve()`**。那一拍关卡刚搭好，"把人让开"这件事留给真在走的那一拍（`_physics_process`）去做。
③ 的理由不是省一秒动画：**"回档落在一个正在动的落脚点"是不可读的那种重载**，而普通档的重载本来就是瞬落（D34 那条链），两档必须同一个口径。

**原点约定一条没挪**（这是①能成立的前提）：摆的仍然是洞口那一点，`_anchor` 仍然是**收回态**的前缘，变的只是静止时身子停在对岸。于是手册 §5 那条「收回态那一截身子必须整块埋进地形」在两种模式下**同一句话** —— 它说的本来就是"埋起来的那一头"，不指输入。同理②让「站得住的时长 = 伸出长度 ÷ `retract_speed`」也不用分档讲两遍。

**整列 `triggers` 留空时白送一种正确行为**：普通块静止是个静物地面，反向块静止是一座桥。两档都由同一行映射算出，不需要为"没人驱动"补第三条分支。

**代价付在明面上**：同场景加开关的账是**光看块看不出常态是哪一头**，而"没人踩着时它停在哪儿"恰好是摆图唯一要知道的一件事。所以 `_draw_editor_guides()` 把**常态那一头涂成半透明实心**、另一头仍留空心框 —— 摆图时一眼分得出，不需要读检查器。

**摆图硬约束跟着变（已进手册 §5 / §8a）**：反向块的**常态就是满行程**，于是它天生挡在路上。两条新账：① 若它挡的是**唯一通路**而按钮在路的另一侧 = **软锁**（踩不到按钮 = 抽不掉它）。② **别把 `PlayerSpawn` / 存档点 / D62 那个祭坛落脚点摆在反向块的常态伸出位** —— 它是 `layer = 4` 的实体，重载当帧瞬落到人身上会把他弹开（② 那条挤开口径在进树那一拍是刻意不跑的）。

**契约变更**：**一个新增导出项 `rest_out`（默认 false = 现状），其余零**。`.tscn`/`.tres`/瓦片/零件、`Player`、`TimeManager`、`LevelBase`、触发源侧全部未动；今天没有任何一份摆图写过这一项，所以现有关卡与 sandbox 跟默认值原样一致。

**守门**：`verify_kit` 的 `EXPORTS` 名单加 `rest_out`（漏了就等于新增一个没人守的旋钮）；`_verify_piston()` 末尾加**三条源码形状 + 一次实测** —— 形状：`is_out = _level != rest_out` **恰好出现 1 次**（在 `set_out` 或 `_physics_process` 里再补一次符号就有两份真值）、两档速度仍按 `is_out` 选、**不许出现 `if _level`**（那两处读的必须是位）；实测：`rest_out = true` 的块进树后 `progress() == 1.0`、`is_out` 真而 `_level` 假、落点正是 `(364, 60)` = 锚点 + 单位 × 跨度（摆下去那一点仍然是收回态的前缘）。`kit_selftest` **第 13 组从五档加到六档**，新 f 档在 x=5900 的 rig 上跑**行为**（形状钉在无头里跑不出这些）：进树即满行程 → 踩下即转入收回 → 收到 0 → 松开转回常态 → **收回明显快过伸回（实测 8 拍 vs 31 拍，钉的就是②"绑几何不绑输入"）** → 冻结中踩下只改朝向不改伸出量（反向档不许自带旁路）→ 两台 OR 在反向档下仍成立（松开时停在伸出态、一台还踩着不许伸回来、全松开才伸回去 —— **伸回来的那一头正是人脚下的落脚点**）。四条无头守门全绿：`VERIFY DONE doors=3 pistons=3 fallzones=0 failures=0` / `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=316`。

**踩到的四条**：
- **GDScript 没有相邻字符串字面量拼接**。`"a"\n "b" % x` 在 C 系里习惯了会直接写出解析错误（`verify_kit` 3 处、`kit_selftest` 2 处），必须用 `+`。
- **`%` 的优先级高于 `+`** —— 这条最阴：`"…%d 拍 vs %d 拍…" + "…）" % [a, b]` 编译得过、跑得过、**那一组还判 ok**，但 `%` 只贴到了第二个字面量上，打出来的消息里 `%d` 是裸的，并且**带一条脚本错误堆栈**。修法是先 `var beat := "…" % [a, b]` 再拼。**口径补一句：`failures=0` 不够，还要看输出里有没有 `ERROR:` / 堆栈行。**
- **形状钉会把注释也数进去**。`src.count("is_out = _level != rest_out") != 1` 这条差点被我自己的类头注释触发（文件头写了同一行代码）—— 把注释措辞换成"`is_out` = 电平与常态那一头的异或"才让它数的是代码。**落形状钉之前先读一遍自己写的注释。**
- **Edit 前先 Read 自己上一轮的措辞**（两次 0 occurrences：我以为写的是「抽掉」，文件里是「抽」）。

**留给人眼的一条**：反向档那句"踩下即抽干落脚点"读不读得清 —— 默认档 64 px ÷ 240 px/s ≈ **0.27 s** 就把人脚下的东西撤掉，而这是这一档的**主要动词**（不是副作用）。普通档那条"站着不动的人会跟着落脚点一起被抽干"他早就判过可接受（第 13 组 c 档），而反向档**不是新机制** —— 它把这一发从"伸出那一下的副作用"升格成**常态那一头的默认拆除**：没人碰按钮时那儿就是一座桥，玩家会把它当地形站上去，撤掉它的开关在另一头。实机验收归他。

**How to apply**：一，**「行为不同就拆场景」的判据是"几套触发 + 几套皮"，不是"几个方向"**。要拆的是两套输入语义；一格映射（一个符号、一个值）留在同场景，但要**把看不见的那一维涂进编辑器**（实心 = 常态停这儿），否则代价由摆图的人付。二，**加"档位"时先找那个量的唯一书写者，把开关放在映射那一层，不要放在每个读它的地方**。本例 `_level`（谁踩着）与 `is_out`（在哪一头）分家之后，两处必须读姿态的代码（`_resolve` 的让位守卫、速度选择）**一行未动** —— 反过来做就要在那两处各加一个 `if rest_out`，而那就是两份真值。三，**"两种模式共用的那句话"要逐个检查是不是真的共用**：原点约定、埋进地形、站得住的时长、OR 合成四条都必须在**换了主语之后仍然成立**，这条检查是免费的（不用改代码），但漏了会写出"只在一档下对"的文档。四，**新增导出项默认值 = 现状**，并且**先确认没有任何 `.tscn` 存过这一项**（D61 的 `grant_time` 也是这么过的这道门），才能声称"现有关卡零改动"。

### D64 · 「被托着」这条事实归 Player：`is_standing()` 收成"脚有着落"唯一读法，活塞因此换基类 `StaticBody2D`

**起因（2026-09-29）**：他的实机报告原话 ——「当 piston 将玩家向上推时有两个问题：1. 推动时玩家动画在跳跃和待机切换，频繁闪烁。2. 当玩家被 piston 推到顶体头时卡住了」。两条都是 D49 那台构件的账，不是新机制。

**四条裁定（我摆菜单，他点的四格全是推荐档）**：
- **① 这条事实归 `Player`**：`push_by()` 在"从下往上推"那一拍顺手续 `_carried_remaining = CARRIED_GRACE_SECONDS`(0.08 s ≈ 5 拍)，对外给两个只读入口 `is_carried()` 与 **`is_standing() = is_on_floor() or is_carried()`**。**重力、蹲伏、起跳、皮四处一律读 `is_standing()`**，不再各判各的。
- **② 顶棚净空 < 站高那一档 = 保住 D49 + 让人能蹲自救**：块照样挤到位就走不满（构件侧**一条新判定都不加**），自救那条路开在 Player 那侧。
- **③ 托举期间 `velocity.y` 归零**（不攒重力）。
- **④ 被托着时给起跳** —— 等于关卡里多发一处"借力跳"。

**根因只有一条，两条症状是它的两次收费**：`move_and_collide` **不更新地面状态**，而被托着上升时他相对脚下的块几乎没有向下运动，`move_and_slide()` 认不出那是地面。实测整段上升途中 `is_on_floor()` 一路为假，出厂速度档下每 ~12 帧真闪一次（`floor_snap_length` 默认 1 px，块每帧升 1~2 px 正好卡在"认得出/认不出"那条边界上）。皮那条腾空判据读裸 `is_on_floor()` → **症状一（jump/idle 一闪）**；蹲伏判据也读它 → 被顶住时他既不算站着、又蹲不下去 → **症状二（卡死）**。所以①把这条事实收成一格、四处共用，是**同一处修两处**。

**故意没收成 `is_standing()` 的两处，写死在注释里**：`_update_floor_state()`（`landed` 的边沿必须来自真落地，不能是"松了托"）与 `_update_wall_press()`（压平读的是**脚蹬地的反作用**，被块顶着上升时蹬不出这一支力）。同理 `is_standing()` **不含土狼时间** —— 那是一条会自己过期的窗口，混进来等于给"被托着"开一条隐式续命。

**②为什么不在构件侧加"头顶有棚就别推了"**：D49 立过的口径是"他推不动"和"我走不动"是同一件事，靠**他自己的 `move_and_collide` 撞停**表达。再加第二条判定就有两份真值（构件以为推开了、物理没推开），而那一档正是当初门踩过的位置（门的 `cast_motion` + `intersect_shape` 双探针是它自己改尺寸推不动人逼出来的，跟这里不是一回事）。

**③ 把这条修出了个更狠的回归 —— 本次全部账目都在这里**：`vy` 归零之后，上升途中 `is_on_floor()` 变真了，于是踩中 **Godot 的骑手平台速度继承**：一个 `CharacterBody2D` 只要每帧走 `move_and_slide()`，它就是"平台"，**平台速度会被加到骑在它身上的人身上，即使人自己的 `velocity` 是零、即使这一帧那块只是被写 `global_position` 传送过去的**。实测签名：收回途中人以**正好 8.53 px/拍**（= `retract_speed` 512 px/s ÷ 60）匀速下沉，同时 `vy = 0.00`、`floor = true` —— ③ 想杀死的"被带着沉"换了个通道原样回来，并且**直接废掉 D49 那条「收回时整个跳过：那时前缘正从他脚下退开」与守门里那根"收回走完时人还在半空"的钉**。这条通道**不在任何文档里**（`ClassDB` + 官方文档双向核对过），它只由**骑手侧**的 `platform_floor_layers` / `platform_on_leave` 控制；顺带排掉一条弯路：4.6 的 `motion_mode` 只有 Grounded/Floating，管的是"墙还是地怎么报"，**与承载无关**。

**两条治法摆开，选了构件侧**：
- **骑手侧** `hero.platform_floor_layers &= ~4`：实测有效（`failures=0`），但它同时会让 `level_01_tutorial.tscn` 里骑 `MovingBlock` 的人**也不再被带着走** —— 那块是真在 `move_and_slide` 的平台，改掉之后变成"他把那块顶住"，等于为了活塞拆了另一台构件的机制。
- **构件侧**：`PistonBlock` 从 `CharacterBody2D` 换成 **`StaticBody2D`**。这块**从来不用** `velocity` / `move_and_slide` / `move_and_collide`，只写 `global_position` —— 换成静体就是关掉那条第二通道，让"人怎么动"重新只有他自己那一票。**皮、接线、积分器、`_resolve`、原点契约一行未改**，`collision_layer = 4` / `collision_mask = 0` 两条 `verify_kit` 断言照旧绿。
**这条是超出四条裁定之外的一处改动**，所以写明白：它不是新决策，是 ③ 的必要收尾 —— 不换了它，③ 就把 D49 打穿。

**换基类带来的账：相切那一档从"物理不管"变成"物理会松弛"**。`_resolve` 把人夹到与前缘**相切**，而 StaticBody2D 与玩家长期相切时引擎做小幅分离松弛，实测沿行程轴在 **±0.13 px** 内来回、约 **25 拍收敛**（5560.04 → 峰值 5560.11 → 5559.9517，方块 `end` 与人 `back` 全程相等 = 矩形模型上从不重叠）。于是第 13 组 d 档那根"顶住 30 拍不攒位移"的钉，容差从 0.001 px 改成 `SQUEEZE_DRIFT_PX = 0.25`（约松弛量的两倍）。口径与 D48 那根「实测 −5e-6 px，是浮点残差不是"陷进去"」同族：**钉的是"攒位移 / 吃进身体"那两类真错，不钉那 0.1 px 的抖**。

**试了又整块退回的一处（下次别再试）**：`const PUSH_SEPARATION = 0.1`（让位时多留一缝）。它确实把松弛抖压到 ±0.006 px，但**静默废掉 ② 的自救**：有缝则 `is_on_floor()` 永不成立，站着这件事全靠 0.08 s 的宽限窗兜着；满行程 + 窗一过期那一拍，`_update_crouch` 判定"腾空"就把他**放起来顶进天花板**（实测 is_crouching=false、身高 30.0、头在棚里、clip=jump、走不开）。**相切那一档正是引擎把脚判成地面的唯一一档，不能拿"读数更干净"换掉它。** 这条与 D64① 的 `CONTACT_TOLERANCE`（前缘多探一格才判接触）是同一条教训的两面：夹到位之后两者长期相切，**判据必须承认相切，几何必须保持相切**。

**摆图账（进手册 §8a 两条）**：④ 白送一发借力跳 —— **"上升中的活塞上能起跳"，凡是要卡高度的竖井要按这一档复核**；② 让"净空低于站高的通道 + 一台上升活塞"不再是软锁（他能蹲着自救），但**别把它当通路来摆** —— 自救要玩家知道按下蹲键。

**契约变更**：`Player` 新增两个只读入口（`is_carried()` / `is_standing()`）+ `push_by` 里续期那一行；`PistonBlock` **基类换 `StaticBody2D`**，导出项零增删。`level1.tscn` 里那四块只存过 `position/travel_offset/block_size/extend_speed/retract_speed/triggers/rest_out`，全是脚本上的 `@export` ⇒ 换基类不丢任何一格，摆图零改动。

**守门**：`kit_selftest` **第 13 组从六档 44 钉加到八档 55 钉（+11）**。**g 档 = 顶棚（9 钉）**（x=6200，棚底 y=-80：站高 30 时块走到 0.78 他就顶到，蹲高 15 时 65>64 顶不到）——三根**过程读数**钉直接对应用户那两条报告：整段托举 120 拍 `is_standing()` **一次都没翻**、`_pick()` 全程**只挑出一种剪辑**、被托着的每一拍 `velocity.y` 恒为 0；再加两根状态钉：顶到棚后块停在 0.783 走不满（保住 D49）、前缘仍贴脚底不吃进身体；四根自救钉：按下蹲蹲得下来 → 蹲下去块就能走完（人变矮这条白送）→ 松手而站着会顶进棚时**保持蹲着不硬起身** → 蹲着从他脚下走开、35 拍到 x=6323 掉回地面自己站起来。**h 档 = 借力跳（2 钉）**（x=6800，没有棚的那一段：顶棚那一档起跳会被棚拦掉，测不到"给不给跳"），先钉**前提**「起跳前他正被托着」—— 前提不成立下面那条就是拿地面跳冒充；实测 1 发、`vy=-487.3`。四条无头守门全绿：`VERIFY DONE doors=3 pistons=4 fallzones=0 failures=0` / `[kit-selftest] done failures=0`（283 钉）/ `SPRITE failures=0` / `TILESET failures=0 checks=316`。

**踩到的四条**：
- **GDScript 的 lambda 按**值**捕获局部变量** —— `climber.jumped.connect(func(): jumps += 1)` 里那个 `jumps` 是副本，计数器永远停在 0，判据看着像"信号没发"。项目里那几条计数（`grants.append(1)` / `hits.append(body)`）**都是往数组里塞，同一个理由**；这次是我第一次亲手撞上它，之前只沿用了写法。
- **`Input.action_press()` 排进去的事件要等下一次主循环 flush 才成为 `just_pressed`**：按下之后只 `await physics_frame` 一拍，等于在"他按下之前"那一拍里读输入，跳跃 buffer 根本没置位。`sprite_selftest` 那几条按 4 拍不是随手写的余量。
- **`.tscn` 先改 `type` 而脚本 `extends` 还没改** → 装载期 `Script inherits from native type 'CharacterBody2D'` + 一片 `Nil` 堆栈，**而那一跑照样打了 `done failures=0`**（fixture 全在 Nil 上静默空跑）。**"绿"必须连着 `ERROR:` 行一起读** —— D63 那条口径这次是**以新形态**复现的。
- **`Player._visual` 是 `Visual` 那层 `Node2D` 壳，皮在 `Visual/Sprite`**；要读剪辑得 `get_node("Visual/Sprite") as PlayerVisual`，而且**读 `_pick()` 比读 `animation` 稳** —— 后者要等 `_process` 过一遍，而守门等的是物理帧。

**留给人眼的一条**：这两条我只能钉到"读数不翻 / 剪辑只一种 / 他能蹲能走开"这一层。**上升途中皮的观感、以及"头一顶住就该想到按下蹲"这条读不读得懂，只有实机能判**（④那发借力跳的高度感同一处）。实机验收归他。

**How to apply**：一，**"某处读数在抖"先问这个读数是谁写的**。`is_on_floor()` 抖不是引擎错，是它压根不知道该认识那块 —— 于是这条事实得由**推他的那一方**说出口，而且要落在他身上（谁都能读、不新增契约），不是落在构件里（那要每个触发构件各报一遍）。二，**给物理量"归零"之前先查这个量还被谁读着**：③ 只看着"别攒落速"，没看到 `vy` 同时是"骑手身份"的开关，于是一发 8.53 px/拍的偷带。凡是"我明明没动他却动了"，**第一嫌疑是引擎在两条通道之外偷偷传了速度**，先读签名（这里 `vy=0` + `floor=true` + 位移正好等于平台速度的每拍量 = 铁证）再动手。三，**同一个 bug 有两条修法时，选不伤及第三方的那条，哪怕要多改一个基类**：骑手侧一行改动更"局部"，但它把另一台构件（`MovingBlock`）的行为一起改了 —— **局部的形状不等于局部的影响面**。四，**换基类要按"这条构件从来不用哪些能力"来论证，不是按"看起来更简单"**：活塞从不用 `velocity`/`move_and_slide`，所以那次继承对它只是风险没有收益；这句论证要写进文件头，否则下一个人会把它"改回去统一"。五，**遇到"看起来在稳定"的改动（那 0.1 px 缝），必须跑一遍它**相邻**那档裁定的钉**，不能只跑它自己那一档 —— 它杀的是 D64②。

### D65 · 关卡模板照 `level1` 的实际摆法重构：按族开文件夹、触发源与它驱动的那件同层、地形只留三层瓦片

**起因（2026-09-29）**：他的原话 ——「接下来是一个方便以后开发的修改，我在目前的 level1 里做了很多事情，请你读取我的项目目录结构，并根据我的项目管理方式修改关卡模板。在动手之前先告诉我你要怎么做」。所以这一条**不是新机制**，是把 M2~M6 期间他在 `level1.tscn` 里长出来的一套私人组织法**反向提取成模板**，让第二关开始就不必重学一遍。做法：先只读他的场景，把"他实际怎么摆"抽成规则，再拿规则去对模板差集，差集摆成菜单让他裁。

**从 `level1.tscn` 里读出来的五条（不是我发明的，是抄他的）**：
1. **地形只有三层瓦片**：`Terrain/WallFill`(z −30，无碰撞) → `Decor`(z −20，无碰撞) → `Tiles`(有碰撞)。他那一关**一块 `platform` 灰盒都没有**。
2. **`Objects` 下按族开文件夹**，而且**只给"一关要摆好几个"的那一族开**：`Checkpoint`×7、`Keys and Doors`×8、`emitter`×4、`Spikes`×11、`Ducks`×2、`PistonBlock`×4+5 台按钮 —— 摆一个的（祭坛）他没套。
3. **一关只出现一次的构件直接挂 `Objects`**（`Objects/AbilityAltar`）。这条一开始我当成审美，读 `level_base.gd:41` 才看清它**不是审美是契约**：`altar_path` 的默认值就是 `^"Objects/AbilityAltar"`（`goal_path = ^"Triggers/GoalZone"` 同理）。套了文件夹而没人改导出项，**每关静默地没有祭坛** —— 不报错、不警告，只是踩上去没反应。
4. **触发源与它驱动的那件同文件夹**，于是接线永远是一跳：他那台活塞写的是 `triggers = Array[NodePath]([NodePath("../ButtonPlate3"), NodePath("../ButtonPlate4")])`。
5. **零契约的纯装饰挂在场景根**（`WorldClock` 在根下，不在 `Objects` 里）—— D59 那台钟本来就不受关卡管。

**四条裁定（我摆菜单，他点的四格全是推荐档）**：
- **① 文件夹命名口径 = 跟构件名**：文件夹名 == 这一族里**被驱动的那件**构件场景名（`Spikes` / `PistonBlock` / `Door` / `KeyDoor`），PascalCase。不跟他 `level1` 里那几种自然语言写法（`Keys and Doors` / `emitter` / `Ducks`）—— 那三处是三种口径混着长出来的，`Ducks` 甚至不是构件名而是内容物名。
- **② 模板内容 = 空文件夹 + 每族一个接线样品**（门+按钮、活塞+按钮、存档点、钥匙卡+刷卡门、尖刺、鸭子、残影踏板、祭坛、世界钟、`Triggers/GoalZone`+`FallZone`）。样品**排成一行**只为把每族接法与原点读法一眼摆清，**不是合法关卡布局** —— 这句写进模板脚本头，也写进手册 §0，免得下一个人照抄那一行坐标。
- **③ 模板那三块 `platform` 灰盒（`Floor`/`LeftWall`/`RightWall`）删掉**：留着等于在推荐"先摆盒子后来换成砖"那道返工，而他自己的关卡里已经没有盒子了。`platform.tscn` 这件构件**保留**（旧关与临时挡块在用），只是不再出现在模板里。
- **④「分组容器必须零位移」钉到所有关卡**（FAIL 级），不只钉模板。

**④ 为什么值得钉**：§2 那张表的读数全写成"节点原点 = 贴着地面那一点"，而参照物是地格线。容器一带 `position`，它下面整块构件被平移，编辑器里那个压住 `y=0` 的按钮运行时沉在别处 —— 这种偏差**在编辑器里根本看不出来**，而用来核对摆位的那套读数已经不可信了。这是一个"错了不会有症状、只会有手感对不上"的洞，只能由守门响。

**实现上三处值得一提的**：
- **族文件夹用 `type="Node"` 而不是 Node2D**（照他）。这一下把 ④ 的打击面收窄成"结构上就犯不了"：裸 `Node` 压根没有 `position`。于是守门真正能数值检查的只剩三个根容器 —— **认「无脚本、还挂着东西的 Node2D」**（组件实例都挂脚本；`PlayerSpawn` 那种 `Marker2D` 落点是空的），所以这条既不会误伤构件，也不会漏掉他未来手滑加的那个 `Node2D` 分组。
- **深嵌套对现有守门是安全的**，核过而不是赌的：`LevelBase._collect_contract_nodes()` 按**信号名**递归整棵子树（危险物/存档点/收集物三族都是这么接的，D28/D31/D51/D54），`verify_kit` 那边 `_collect_paths()` 递归收路径、`_fold_rel_path()` 会把 `../` 折回关卡根视角 —— 所以套一层文件夹不动任何一条接线检查。**唯一的例外就是第 3 条那两个默认 NodePath**，而它恰好是他本来就是这么摆的。
- **`tileset_selftest` 从来没读过 `Terrain/Floor`**（它只断言三层 `TileMapLayer` 存在、z 序 −30/−20/0、`WallFill`+`Decor` 关碰撞、三层共用 `lab_tileset.tres`），所以 ③ 那一删对它零代价；要改的是 `verify_kit` 的 `NODE_PATHS` 模板那一行（旧值 `Terrain/Floor` 现在没人住了）。

**当天就收到两条账 —— 全在 `level1.tscn`，都是他未提交的中间态，按约定不由我修**：
- `Objects position = Vector2(-2, 1)`：**全仓库唯一一个带位移的容器**（我把每一关的三个根容器都扫了一遍才敢钉），第一条红就是它。
- **一卡二门**：`Objects/Keys and Doors/KeyDoor` 与 `KeyDoor4` 的 `key` 都指着 `../KeyPickup`。这条**不是新钉**，是 D30 第 6 条早就在的"一卡一门"检查，被这一批新摆的门撞出来的 —— 也就是说这条红跟 D65 无关，他 duplic 门的时候漏改了指向。
- 三条 selftest 当场绿（`tileset 316 条` / `sprite` / `kit`，均 `failures=0` 且无 `ERROR:` 行）。

**顺手记一笔工程侧的坑**：手写 `.tscn` 时把场景根 uid 从 `uid://do7gohrr3uwig` 错敲成 `...3w5ih`（改文件内容不需要新 uid，改错了就是给同一份资源起了第二个名字）。**重写整个场景文件时 uid 与 `unique_id=` 属于"不该动的部分"** —— 前者是资源身份，后者编辑器不写就不写（全仓库无一行 GDScript 读它，只有 `addons/godot_mcp/ui/mcp_panel_native.tscn` 含这个字符串），但**已存在的要原样保留**，否则 diff 里全是无意义 churn。

**How to apply**：一，**"照我的方式改模板"这类要求，先把用户场景读成规则再去对模板**，不要凭手感重排。他的五条里有一条（祭坛不套文件夹）看着像审美、实际是 `@export_node_path` 的默认值在撑着 —— **看代码之前它会伪装成风格**。二，**把私人约定升格成模板之前，先确认它在守门里是安全的**：递归按信号名接线的那几族天然免疫嵌套，而按路径接线的两处（`altar_path`/`goal_path`）免疫不了 —— 差集就是"哪里不能套文件夹"的答案，不用另立一条禁令。三，**钉一条"错了没有症状"的规则，收益要在钉的当天验证**：④ 落下去立刻红两处，其中一处（一卡二门）连不是我新加的检查都顺手照出来了 —— 这比"这条规则理论上能防什么"有力得多。四，**菜单里给"删掉"这一档时把零件本身留着**：`platform.tscn` 不是被 D65 废掉的构件，只是不再是新关的起手式；手册里那条"旧关与临时挡块仍在用"要写清楚，否则下一个人会去删一件还在服役的东西。

### 暂缓 · 死亡那一拍的重排（2026-09-29，四行候选已出图，他看完说「效果都不太好，暂时先不修改了」）

**这一条不是裁定，是一次收手的记账**：D42 那版「等比收缩 + 14 滴爆裂」原样保留，`player.gd` 与 `death_burst.gd` 一字未动。候选图留在 `assets/player/preview_death_shatter.png` / `.gif`（生成器 `tools/gen_death_shatter_preview.py`，五行 = 现状复算 / 只补脚底 / 塌 / 碎 / 塌+碎；底片与液滴算式 `import gen_death_preview`，不另画第二张地面）。**要重开就从那张图接着挑，不用重新出。**

**出图过程中查出两条客观偏离（与审美无关，谁将来动这一拍都得先知道）**：
1. **实装偏离了 D42 当年批的那张图。** 图里 D 行的脚底是钉死的（`y = FLOOR − 37·sy`），而 `_apply_death_transform()` 缩的是 `Visual` 壳 —— 壳原点 = 身体中心、脚底在下方 15 px，等比缩放于是把**底边一起往上收**：整拍多飘 `15×(1−s)`，t=0.26 那一格实算 17.1 px（图上是 8.2 px）、收缩走完那一格 25.2 px（图上 12 px）。所以实机读作"一颗球悬在半空越缩越小"，而图上那是"缩着往地上塌"。**修法是一条补偿项**（`position.y` 加 `15.0 * (1.0 - s)`），不是审美。
2. **2 px 那几滴液滴在实机里压根没有身体色。** `death_burst.gd` 先 `draw_rect(亮边)` 再 `draw_rect(rect.grow(-1.0), 身体色)`，而 `grow(-1.0)` 把 2×2 收成 0×0 —— 那 14 滴里 **5 滴是 2 px（纯白方块）、6 滴是 3 px（只剩中心 1 px 暗）**，所以爆裂在实机上是一蓬白点（火星/气泡）而不是"崩出几块"。**"不像破碎"缺的就是这一格。**

**顺带一条同源账**：`gen_death_preview.py` 里那四个收缩数（0.6 / 0.12 / 12 / 0.55）提成了具名常量并注明对应 `player.gd` 的四个 `DEATH_*`；`splash()` 多一个 `alpha_t`（默认沿用 `t`，所以旧图输出逐字节不变 —— 这条是**跑旧脚本比 md5 验过的**，不是推定：同一份输入两边 md5 相同，而仓库里那张 `preview_death_candidates.png` 与今日重跑的结果不同，说明**它是在 D26 换 `g` 风格之前生成的、已经过期**）。重跑出来的那张没有提交，工作区已回滚。

### D66 · 时间锚点：锚点物的时间源裁定为「玩家的动作」——他动它动、他停它停（**已裁定，本轮不实现**）

**起因（2026-09-29）**：他说「我打算接下来开始实现我们之前说过的，发射时间锚点的功能」，但**在册记录里这件事只有一句**（D11 那句「这种谜题可以等到我们解锁了时间锚点再出现」，上一轮会话全文查过，没有更细的定义）。所以他先抛了一个真正卡住的问题：「**当玩家不移动时，被附着的物体是否应该被冻结**」。这一条把语义定死了，其余部分才有得谈。

**四行推演（"附着"这个概念成不成立，全看这张表）**：

| 锚点的时间源 | 他站着（世界流动） | 他移动（世界冻结） | 结论 |
|---|---|---|---|
| 世界（同相） | 动 | 停 | **不成立** —— 挂不挂锚点一模一样，"附着"白造 |
| **玩家的动作（反相）** | **冻** | 动 | **成立**，且与在册语汇同形（见下） |
| 它自己（常动） | 动 | 动 | 半成立：与"根本不挂锚点"的唯一区别只剩"冻结时它照样动"，那就不需要"附着"这个概念，只需要一个"冻结期仍活动"的标记 —— 概念更贵、收益一样 |
| 接触/推挤才动 | 只有被推着才动 | 同 | 成立，但它是 D11 原案（"箱子的时间源 = 玩家推挤驱动的专属 delta"）的局部版，可以并进第二行 |

**裁定三条（他一句"同意，按你说的方案"整体放行）**：
1. **锚点的时间源 = 玩家**：他按住方向键（世界冻结）→ 锚点物在自己的账上走；他站着（世界流动）→ **锚点物被冻住**。手算一遍形状：一块 3 s 周期的锚点平台，他走 1.2 s，平台走 1.2 s（周期的 40%）；他站着看 5 s，平台一秒都不走。谜题动词因此是"**用你的移动给它上发条**"。
2. **锚点物一律不上危险层**（可以 `layer = 4` 载人、推人、当落脚点，但不带伤害）。这条是**必须付的代价**：它破了 D35 那条地基 ——「移动期间一切机关相位钉死 = 穿越绝对安全」。玩家按着方向键时以为全世界都停着，这时候有什么东西在他脚下动并且能杀他，就是"看不见的力"。要惩罚请用全局时间那一头的电棒/尖刺。
3. **"它凭什么在跟着我动"要有一处收据**，否则读作 bug。最便宜的现成形状是 D59 那只世界钟的语汇（挂一只小亮格槽：他动它跳格、他停它钉住），纯装饰、零契约。

**为什么这一档不需要教新规则**：D47/D48 那台残影踏板已经说过同一句话 ——「我一动，它才从虚变实；我停下，它反而不变」。玩家第一次摸到锚点物时读的是他已经会的那套。

**在册预留（这次核过，接口是干净的）**：`components/time_receiver.gd:38` 的 `set_time_source(physics, process)` / `clear_time_source()` / `time_source_changed` 三条**全在**（当日零调用方；D68 起由 `TimeAnchor` 接上）；两条 delta 读点在有 Callable 时走它、否则直连 `TimeManager`。所以接上它只要**一个 Callable**：按着方向键时返回真实 delta，否则返回 0（读点现成 —— `_horizontal_axis()` 是水平轴唯一读点，`MovementInputHandler.is_moving` 已经在对外给）。另有一条 D59 的订正在替这条路保命：**构件一律不自读 `TimeManager.elapsed_world_time`，而是本地 `_clock` 累加 `get_physics_delta()`** —— 直读全局量的东西，锚点劫持不到，等于白丢这条免费通道。D11 那笔"推箱子 / 移动平台延后到第二章"的账，到这一步才算有了正主。

**本轮明确不落地**：`set_time_source()` 仍然零调用方，`assets/chapter_02_reserved/` 仍然只有 `.gdignore`。**D68 已落地（2026-10-26）**：下面这份"下一次开工先交设计结构"的清单已经逐条回答，设计与实装见文末 D68；本段保留当日收手时的原样。**下一次开工先交"设计结构"再写代码**，要回答的是这些（当天一条都没定）：谁发射（新输入键？还是像祭坛那样"踩上即获得"的一个新能力？）、一次能挂几个锚、锚点能不能被玩家带着走、附着物在锚点消失/死亡重载时怎么复位（`run_state` 要不要记它）、`clear_time_source()` 由谁在什么时候调、以及四条守门各钉哪一格。**"发射"这个词的三种读法（玩家放置锚点 / 抛射体自带锚 / 把残影发射器改成按时间戳实体化）当时没排除干净，只锁定了"时间源 = 玩家"这一条**，开工第一件事是把这句话变成一个物件与一条输入。（编号记账：这一条本轮不落地，所以 D66 之后第一个被用掉的空号是下面这条 D67；**锚点系统的设计结构改用 D68**。）

### D67 · 第二套落盘配色：`d 软糖贴纸` 出成一份能指的 TileSet，给换美术风格的新关用（几何与 g 逐格同源，现有关一字不动）

**起因（2026-10-26）**：他要做新的一关，并且「希望换一种地图美术风格，即之前提交在 assets 里的 d 风格」。`d` 不是新画的东西 —— 它是 `tools/gen_tiles.py::STYLES["d"]`（`D CANDY STICKER`：quilt 软包墙 + dot 波点地 + plum 描边，`soft=True` 那套贴纸语言），整套房间预览一直在 `assets/tiles/preview_room_d.png`；`SHIPPED` 上面那行注释本来就写着「d = 软糖贴纸，留给后面的关卡（同一套 soft 语言，换配色即可）」。**这次就是那句"留给后面"到期。**

**三条裁定（我摆菜单，他一句"按推荐档执行"整体放行）**：

1. **新增一套，不换掉 g**。产物是 `lab_tileset_d.tres`，`SHIPPED` 仍是 `g`：现有关、模板、`level1.tscn` 的 `ext_resource` 全按 `lab_tileset.tres` 写死，改那一行等于把所有已摆好的图换配色，不是他要的事。新关只把 `Terrain` 三层的 `tile_set` 指过去。
2. **装饰图集一起出**（14 块，含 `wall_fill` / `shade` / 两块无字告示牌）。只出地形 = 地基那一层还是夜光配色，等于没换风格。
3. **构件这一轮不动，只把代价算清楚交给他**（见下面那笔账）。构件换色是另一条决定：要重烤 `gen_props.py` 那批 PNG、动 `props.json` 的别名、逐件验读法，不该塞在一次换皮里。

**这条决定几乎不花钱的原因**：`build_terrain_atlas(p)` / `build_decor_atlas(p)` 从 D24 起就是**吃调色板的函数**，`STYLES[key]` 里那十几个键名就是全部参数。所以 d 这一套不需要画任何东西，只需要把同一批 painters 用 d 的 `p` 再跑一遍并落第二份文件。**于是两套的瓦片索引逐格同源**：同一张 16 格掩码表、同一批装饰矩形、同一个 terrain 求解器结果集 —— 旧关的摆图层可以整层复制进用 d 的关，坐标一格不动。

**代价算清楚了（这一条才是 D67 真正的内容）**。第一轮报数用的是 `props_strip` 里那四个 `@export` 占位色，第二轮换成 `props.json` 里的**在册真色**，两处不同数，**以第二轮为准**（`_cr()` = WCAG 对比度，4.5 是平台跳跃里"读得出来"的下限）：

| 在册色 | 对 g 墙 | 对 d 墙 | 对 d 地 |
|---|---|---|---|
| 主角身体 (10,12,12) | **2.63**（靠 g2 亮边救） | **15.70** | 11.79 |
| 主角那圈 g2 亮边 (206,222,250) | 5.48 | **1.09** | 1.22 |
| 祭坛核心 / 门光幕 青 (110,230,240) | 5.05 | **1.18** | 1.13 |
| 门 LED 亮态 (182,242,248) | 6.04 | **1.01** | 1.35 |
| 门 LED 锁定琥珀 (250,190,74) | 4.44 | **1.34** | 1.01 |
| 按钮面板 ab 琥珀 (240,180,41) | 3.99 | 1.49 | 1.12 |
| 门体 ab deep (94,108,125) | 1.39 | **4.29** ↑ | 3.22 |

读法：**d 把主角那一半问题整个解决了**（亮底 + 近黑身体 = 15.70，不再需要 g2 那圈补边，而那圈补边在 d 上反而成了一条 1.09 的没用的淡边）；**但它把"青 = 灯 / 运行"这套夜光语言整个压平** —— 祭坛核心、光幕、LED 亮态全落到 1.0~1.2，也就是"能亮的那一系都不亮"。唯一变好的一头是深色门体（1.39 → 4.29）。**这笔账现在不还**：用 d 摆关之前要先裁构件换色，否则玩家在那一关里看不出"哪盏灯亮着"。数字只陈述，不替他否决审美（D46），但他做那一关的构图时这七个数会真的摆在画面里。

**三条非显然处（都是这次当场踩到或当场避开的）**：

1. **图集文件名一律从清单读，不许在生成器里写死。** `build_tileset.gd` 以前写死 `tilesheet_terrain.png`；两套并存之后那条硬编码的后果是**d 的 TileSet 挂着 g 的图** —— 不报错、不崩、peering bit 全对，只是新关刷出来是旧配色，而没人会去查一份 json。所以路径改成从 `manifest["terrain"]["file"]` / `["decor"]["file"]` 拼，并且守门为此多钉三条（见下）。
2. **全新资源必须自己发 uid**。`ResourceUID.generate()` 在 4.6 **不存在**（探针：`has_method("generate") == false`，`create_id` 为真），能用的只有 `create_id()` + `id_to_text()`。不发这一行就等于把"这个资源没有身份"留给编辑器去补，而它补之前任何场景按 `uid=` 引用都落空。g 那一套走原路（读到旧 uid 原样补回），所以它的 `.tres` 逐字节零变化。
3. **`ext_resource` 的账也要补，只是全新文件没有旧账可读**（`keep_uid.read_ext_uids()` 回空表，而那句"全新资源本来就没有旧账"是有意的）。但两张 PNG 已经先一步被导入、uid 就写在各自的 `.import` 里，所以按那份账把 `uid="..."` 补进资源行 —— 产物就跟编辑器自己写的一模一样，否则编辑器下次存这份资源会连 `id=` 一起重排，"只换了配色"在 diff 里看成整份重写（D56/D57 为同一个坑补过两次账）。这条兜底**只在旧账为空时**走，g 那一套一个字节都没动。

**契约变更：零。** 关卡、构件、脚本、玩家、存档一字未动；`SHIPPED` 仍是 `g`；模板那三层仍指 `lab_tileset.tres`。落地的只有：`gen_tiles.py` 多一条 `EXTRA_SHIPPED = ("d",)` 与按套落盘的循环（`write_manifest` / `atlas_sheet` 参数化）、`build_tileset.gd` 从"一份 manifest"改成"一对清单"、`tileset_selftest.gd` 把同一套断言对每套各跑一遍。新资源：`tilesheet_terrain_d.png` / `tilesheet_decor_d.png` / `tiles_d.json` / `preview_tiles_d.png` / `lab_tileset_d.tres`（+ 三张 `.import`）。

**摆图侧的用法（已写进手册）**：复制模板 → 选中 `Terrain/WallFill`、`Terrain/Decor`、`Terrain/Tiles` 三层 → `tile_set` 都指到 `lab_tileset_d.tres`。三层必须指同一套，混指会出现地基是夜光、地形是软糖。已摆好的层可以从用 g 的关里整层复制过来（索引同源），刷出来自动是 d 的配色。

**守门**：`tileset_selftest` 从"读一份清单 + 一份资源"改成**对 `SETS` 里每一对各跑一遍**，`checks` 从 316 涨到 **634**，`failures=0`；FAIL 行前缀 `[g]` / `[d]`，混跑时知道回去查哪份产物。这次新增的钉子全部只为"两套并存"这一件事服务：**① 清单声明的 `style` 必须等于这一对应该的风格**（清单自己声明错 = 后面所有断言都在验一套不存在的东西）；**② 源上实际挂的纹理必须以清单里那个文件名结尾**（把 d 的清单配给 g 的资源当场响）；**③ 两套的两张源图不许是同一张**（钉的是这次唯一那种静默失败）。四条无头守门：`VERIFY DONE doors=3 pistons=5 fallzones=1 failures=1`（**那一条 FAIL 是用户未提交的 `level1.tscn` 里 `Objects` 容器带位移 (-2,1)，按约定不由我修**）/ `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=634`。
**新钉子先证明它会响**：临时往 `SETS` 里加第三条 `PROBE`（`manifest` 用 `tiles_d.json`、`tileset` 用 `lab_tileset.tres`、`style` 声明成 `nope`）—— 一条记录同时构成三种误配，跑出来 **5 条 FAIL、退出码 1**：`[PROBE] 清单声明 style == nope，实测 d` / `[PROBE] 地形源挂的是清单里那张（tilesheet_terrain_d.png）` / `[PROBE] 装饰源挂的是清单里那张` / `[g/PROBE] source 0 与 source 1 两张图不能是同一张（都是 res://assets/tiles/tilesheet_terrain.png / tilesheet_decor.png）`。删掉 PROBE 复跑照绿。**没有这次实验，那三条新钉只是"我以为会响"。**

**顺带一笔（同源账的另一种烂法）**：`preview_room_*.png` 那 9 张在 HEAD 上是**陈的** —— 重出后逐张比对，差异只落在四个"文字行带"上（标题两行与 `dims()` 那几处标注），图元本身一格没变；也就是说有人改过标注文案而没人重出图。本次连它们一起重出，与当前工具对齐。幂等性核过：`lab_tileset.tres` md5 与提交前一致；`lab_tileset_d.tres` 连跑三次 md5 不变；四张 SHIPPED 产物（两张图集 + `tiles.json` + `preview_tiles.png`）md5 全部与提交前一致。

**How to apply**：一，**"给同一套几何出第二套配色"这件事，便宜的前提是当年的 painters 就把调色板当参数**。D24 那版把 `p` 一路传到底，今天加一套风格就是数组里多一行；那时若写成读全局常量，今天就得先做一次解耦。以后凡是"资源会长出第二套"的地方，先问一句"参数化了吗"，没有就先参数化，别在产物层面复制粘贴。第二，**两套并存的唯一静默失败是"新的挂着旧的"**，而它不报错、不崩、连几何断言都照绿 —— 所以守门必须钉"两套不是同一张图"这种**关系**，只钉每套自己的性质不够。第三，**无头生成的新资源要自己发 uid，且 `ext_resource` 的账从 `.import` 里补**：4.6 没有 `ResourceUID.generate()`，只有 `create_id()` + `id_to_text()`；把身份留给编辑器去补，等于让第一批引用者按路径找。第四，**换地图风格不等于换构件**：这一轮只换地形，代价算成表交出去，让它成为下一条看得见的决定，而不是悄悄把七件构件的皮顺手改了。

---

### D68 · 时间锚点：玩家自己瞄准发射的一根锚，吸住目标后它的时间源改成「玩家的手」——强回收（一次一根、E 当帧断链）

**起因（2026-10-26）**：D66 已把锚点物的时间源钉成「玩家的动作」，但把设计结构留到下一次开工；他随后把交互形态说死了：「我不希望用“目标选择”的方式选择物体，我更希望玩家可以自己瞄准发射锚点，自由决定自己要控制什么物体，类似于发射的锚点覆盖机关或者箱子」。接着补了一句「锚点回收还没有设计」——回收因此按**强回收**定（E 随时收回，目标当帧回世界钟），不是「等锚自己飞回来」或「目标永占一个槽」。他一句「开写」整体放行。

**五条裁定（都是这次新定的）**：

1. **发射不是选目标**。Q（另绑鼠标左键）按住进入瞄准，方向 = 胸口指向鼠标（鼠标压在胸口上时退回朝向），松开即发射；射程 320 px 从胸口算。瞄准期间画虚线 + 准星：可锚物亮色（`COL_LIT`）、不可锚物暗色（`COL_UNLIT`）、没命中用拖尾色。`fire_toward(direction)` 是唯一生产入口，守门走它给确定方向，不摆鼠标。
2. **一次只有一根锚，四态**：IDLE → OUTBOUND → ATTACHED → RETURNING → IDLE。吸附中按 Q 什么也不发生（不射第二根、不画瞄准线）；要换目标先 E。
3. **时间源 = 玩家的手**（D66① 的落法）：目标的时间源在吸附那一刻被换成 `TimeAnchor._pump_physics_delta` / `_pump_process_delta`。四条全真才供时：主人活着、没被移动锁掐住、能力已开、手上有方向（`MovementInputHandler.is_moving`），外加目标与接收器仍在树上。给的是**真实 delta**，不是世界钟的门控 delta —— 世界冻着、人按着方向走，目标照走；世界流着、人站着，目标停。刻意不读 `elapsed_world_time`、不吃 0.08 s 松手缓冲、不认死亡/授予那一拍的强制冻结：那三道闸管的是世界，锚点物只听手。松手当帧归零。
4. **强回收**：E（复用 `interact`，没新增按键）只在 OUTBOUND / ATTACHED 有反应。吸附中按 E **当帧** `clear_time_source()`，目标立刻回世界钟；回程只演视觉，不再拖住任何东西。回程不吃碰撞，直线追胸口，时长按 `distance / 1400` 夹 `[0.08, 0.30]` s；半路按 E 同样收；未命中 / 打到非锚点物 / 射程尽头给 0.12 s 短收团。
5. **不碰目标相位、不进存档**。吸附与回收都不写目标的 `elapsed_path_time` —— 相位是目标自己的，锚只借它的时间源。锚不写 `run_state`：死亡当帧 `cancel_for_death()` 收回手上；关卡重载由 `_exit_tree()` 断链，新场景里是一根新锚。它是这一条命的物件，不是进度。目标被 `queue_free()` 时，锚从最后一格插槽回程，不在半空留一根野锚。

**锚点族（可扩展的判据，不是白名单）**：根节点进 `anchorable` 组、自己挂着 `TimeReceiver` 子节点、碰撞层含 terrain(1) 或 time_solid(4)、不是危险物（`HazardBase` 继承链 / `touched_player` 信号）。射线 `HIT_MASK = 1 | 4`，传感器与玩家不在射线上（玩家 RID 另从查询排除）。移动方块第一个接入；门、地面、墙都不在族里，打上去只演「撞到但吸不住」的短回程。

**回执（D59 词汇，纯装饰）**：吸附后锚上方一条 12 格走带（`RECEIPT_TICKS` 必须等于 `WorldClock.TICKS`），周期 1.2 s，3 px 格 + 1 px 间隙，悬浮 30 px；调色板全取 `WorldClock.COL_*` 的在册色。亮格是 `_wound` 的纯函数（`int(fmod(_wound / 1.2, 1.0) * 12) % 12`），`_wound` 只在「供时」那一拍累加 —— **走带停住 = 这个物件这一拍没在动**。时间源从不回头读 `_wound`，回执也不发信号。

**实现里四个非显然处**：

1. **锚在代码里造，不进 `player.tscn`**。`Player._ready()` 里 `TimeAnchor.new()`、命名、赋 `source` 再 `add_child`。理由不是图省事：锚要 `top_level = true`、`z_as_relative = false`、`z_index = 5` —— 飞行/吸附都在世界坐标里算，跟着 Player 的变换走会在人转身时一起翻；它也不该挂在 `Visual` 底下，死亡那一拍的收缩不能把锚一起缩掉。这几条写在脚本 `_ready()` 里，场景文件零改动。
2. **`set_time_source` / `clear_time_source` 各只有一个书写点**，守门按出现次数钉死。多一处书写点，就会出现「这条路径吸上了、那条路径没撒手」的半截链接，而实机只表现为「某个构件偶尔还能动」。
3. **`_exit_tree()` 必须断链**。锚被移出树（关卡重载、玩家释放）时，目标手里的 Callable 指向一具尸体；不断链的话它下一帧会静默退回世界钟，而没人在那之后解释「为什么我拿不到它了」。死亡走 `cancel_for_death()`、复活走 `reset_state()`，两条都在 `Player` 侧接上。
4. **目标消失那条分支不走 `_drop_link()`**：`TimeReceiver` 自己也随目标没了，`is_instance_valid` 已经为假；直接把 `_target` / `_receiver` 清空、从最后插槽 `_begin_return()`，比对着一个已释放对象调 `clear_time_source()` 稳。

**守门**：

- `verify_kit` 新增静态一遍，钉五类：①两个调用各恰好一次；②禁读 `elapsed_world_time` / `TimeManager.get_*_delta` / `Engine.time_scale` / `run_state` / `func _process(`；③四个闸字符串必须在；④`_pump_enabled()` 函数体不许出现 `_wound`、回执必须取全部六只在册色、`RECEIPT_TICKS == WorldClock.TICKS`；⑤`Player` 只造一根锚且名字/死亡/复活三处接上、`anchor` 动作真有 Q + 左键、扫 `scenes/objects` 下每个 `anchorable`（实体、层 1|4、有 TimeReceiver、非危险物），移动方块必须在族里且族不能空转。收据里多了 `anchorables=1`。
- `kit_selftest` 第 22 组 **46 条**，全走真实 `player.tscn` + `moving_block.tscn` + 真实 Input 事件（`Input.action_press` 排的事件要过约 3 个物理帧才成为 `just_pressed`，所以按键类断言都等 3 拍）。覆盖的不只是「能吸上」：世界冻着按方向 → 目标拿到 delta；世界流着站着 → 目标不动（这条是否定式，专钉「跟的是手不是世界钟」）；松手当帧归零；移动锁 → 立刻停、解锁 → 接着供；瞄准/发射输入链；第二发无效；吸附中 Q 无效；回执相位四档（0 / 半圈 / 整圈 / 1.25 圈）；拧回执相位不停时间源；E 当帧断链且目标相位不回 0；半路 E；撞墙 / 门 / 地面 / 射程尽头；回程穿墙；死亡断链 + 复活回手；目标被释放从最后插槽回程。
- **新钉子先证明会响**（两条破坏性对照）：①删掉 `_pump_enabled()` 里的 `source.input_handler.is_moving` → `VERIFY FAIL: 时间源的闸缺了 source.input_handler.is_moving…（D68）`；②把 `moving_block.tscn` 的 `anchorable` 组去掉 → `VERIFY FAIL: 移动方块没进 anchorable 组…` + `VERIFY FAIL: 一个 anchorable 都没扫到…`，`anchorables=0`。两条都复原后复跑照绿。
- **四条无头守门**：`VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=1 failures=1`（那一条 FAIL 仍是用户未提交的 `level1.tscn` 里 `Objects` 容器带位移 (-2,1)，按约定不由我修）/ `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=634`。
- **一条既有噪声**：`kit_selftest` 退出时打了 `WARNING: ObjectDB instances leaked at exit` + `ERROR: 1 resources still in use at exit`。把第 22 组的调用临时注释掉复跑，同两条照样出现，`tileset_selftest` 也有 —— 是基线，不是 D68 引入的；没有顺手处理。

**How to apply**：一，**「时间源」不是「世界状态」的同义词**。锚点物的四条闸故意绕开 `TimeManager` 的状态机、松手缓冲和强制冻结 —— 因为玩家看见的因果必须是「我按着，它在动；我松手，它当帧停」，而世界钟那几道闸是为世界本身服务的。以后再接第二种「跟动作走」的物件（第二章锚点系统），先问它跟的是谁的手，再决定读哪个 delta，别顺手拿 `get_physics_delta()`。二，**强回收的价值在「当帧断链」**：回程只是视觉，目标从按 E 那一拍起就归世界钟。若让回程再拖住目标，玩家会看到一个「已经松手却还在走」的窗口，而这正是这套机制最不能有的手感。三，**可锚族要用判据扫描、不要维护白名单**：组 + TimeReceiver + 层 + 非危险物，新构件挂上组就自动进守门；空转（扫到 0 个）必须报错，否则「族检查全绿」可能只是一次空跑。四，**纯装饰的回执只许读时间源，不许喂时间源**；把 `_wound` 塞进 `_pump_enabled()` 会让回执变成第二个时间权威，而画面不会报错。五，**进度的归进度、这一条命的归这一条命**：锚不写 `run_state`，目标相位不因锚复位 —— 这两条如果反过来，死一次就会把谜题状态一起带走。

---

### D70 · 装饰按套分列词汇表：`d` 从实验室换成「树丛」（几何与占格一格不动），可拾取琥珀从 `accent2` 里单拎出来

**编号订正**：本节先落笔时误标成 D69，与「相位器件」那节撞号。相位器件先落地（2026-10-26），本节改号 D70；代码注释与手册里的引用已一并改过，**下一个空号 D71**（写作当日；同日 D71 已落给「第二关混合图集搬进独立资源」，现行口径见文末，**下一个空号 D72**）。

**起因（2026-10-27）**：他看了 D67 落盘的 d 装集之后说「第二套风格的配色更类似于森林一类的，但我们的 decor 里面依然是实验室风格的物体，这不太协调。分析之后告诉我你觉得有什么装饰比较好」。我交的是三条**量出来的**事实 + 一份逐件清单（十件换剪影 + 六件新增，占格全不动），他一句「按你推荐的做，我觉得很合理」整体放行。

**三条事实是这次的全部依据，不是感觉**。前两条来自把 `STYLES["d"]` 的数按 WCAG 手算一遍（与 `gen_tiles.py` 每次跑打印的那张表同源）：

1. **d 里唯一有饱和度的颜色全在地形上** —— `surface`(168,210,190) / `grout` / `deep` 三档鼠尾草绿，而墙是不饱和的 lilac(236,227,240)。眼睛只能把"有颜色的那一层"读成地面=草/苔。所以森林感是**配色**给的，不是 `quilt` 软包 motif 给的（这条很重要：它决定了要动的是装饰，不是 motif）。
2. **在这套里装饰靠描边活着、填充一律隐形**：`metal` 对墙 **1.66**、`glass` 对墙 **1.03**（那块 96×64 的窗玻璃与墙是同一个颜色，看见的只是它的框），而 `edge` 对墙 **10.52**。g 恰好相反 —— g 的装饰靠发光填充读。于是同一批剪影在 d 里的信息量只剩轮廓，而**轮廓 100% 是直角钢箱**。这才是"不协调"被放大的机制：不是装饰选错了，是这套配色把装饰唯一的信道交给了最不擅长的那件事。
3. 唯一还在 d 里读得出来的三件（`monitor` / `led_panel` / 两块告示牌）恰好都吃 `screen` 近黑（11.56）—— **这套里"能看见的"恰好是最像机件的那几件**。

**四条裁定**：

1. **走「温室 / 废弃园区」，不走纯森林**。理由三条，最硬的一条是账：在册构件（卷帘门、按钮、终端、钥匙卡、电棒、活塞）全是机件，纯森林等于要重烤第二套构件皮，而那正是 D67 明码标价「留给下一条决定」的那笔钱，不许由装饰层顺手花掉。次要的两条：游戏本体的虚构就是一个时间实验室；而"长满苔的废弃园区"是唯一让机件和植物同框而不撒谎的档 —— 苔吃绿、灯吃青，玩家会自动读成「这里只剩这几台还在转」，反而把夜光语言救回来一半。
2. **换的是词汇，不是几何**。新增 `decor_set` 参数（`PAINTERS` / `PAINTERS_GROVE` 两张表，条目名与占格逐格相同），g 走原路。所以「旧关的 Decor 层整层复制过来」这条仍然成立，只是复制过去之后墙上那根管子长成了根。
3. **一个新色都不加**，只用这套在册的 12 个键：木/石 = `metal`，叶与苔 = `grout + deep + surface`，洞与缝 = `screen`，亮面 = `lip / lip_shade`，轮廓 = `edge`，花与菌盖 = `accent2`。
4. **可拾取琥珀单拎成 `pickup` 键**（缺省回落 `accent2`，所以 g 逐字节不变）。`sign_plate` 上那只卡的形状说的是「这扇门要的是这张卡」，全靠两色相同；而 `key_card.png` 是照落盘那套的 `accent2` 烤的、从此不随新配色漂移。d 的 `accent2` 是粉 —— 跟着本套走，**这块牌就在指一张场上根本不存在的粉卡**（牌与卡 cr 1.47）。这是这次顺手还上的一笔债，与森林那条无关。

**换的十件（占格一格不动）**：`pipe_h`→横卧的根（节瘤仍每 32 一格，所以照样能横向 9 连铺满一面墙）、`pipe_v`→垂藤（三簇叶在 16/48/80 行，第 0 与 95 行留纯茎才接得上）、`window`→石拱洞口（把 1.03 那片隐形玻璃换成 11.56 的洞 + 三丛远叶）、`light`→吊光盖菌、`monitor`→木巢箱、`led_panel`→贴壁地衣、`vent`→墙缝、`cabinet`→树桩、`cabinet_small`→岩石、`hazard`→荆棘带。**新增七件**：`moss_edge` / `leaf_cluster` / `mushroom` / `flower` / `bones` / `crate_wood` / `barrel`（d 的装饰块数 14 → **21**）。

**实现里八条非显然处（每一条都是当场看图改出来的）**：

1. **图集矩形会撞车，而且不报错**（这次真踩到）。我按「x≥224 整列是空的」摆新增件，忘了 `vent` 是 `(208,0,32,16)` —— 它的右半正好压在 224 那一列第一行上。后果不是崩，是**后画的那件把前一件盖掉**：图集里看是一块、清单里是两块，刷进关卡才现形。所以生成器现在落盘前先跑 `check_decor_rects()`（16 对齐、不出界、两两不重叠、painters 与条目对得上），红在命令行而不是红在眼里。
2. **亮底与暗底是两套不同的可读性物理**。`light` 那四行真 alpha 光晕在 g 里说的是「这一带是亮的」；在 d 里光晕无处可叠（`lip` 对白墙只有 1.22），所以那句改由菌盖的粉 + 一圈描边 + 盖下三行**影**来说 —— 亮不亮不再由亮度报，由形状报。
3. **`moss_edge` 画在格子的下半截**。Decor 在地形后面，所以「草长在台面上」= 刷在台面上方那一格、画在那格的底部；整格填满就成了一块悬空的砖。这是全-kit 唯一一件原点约定在**格子外**的装饰，摆位口径写进手册。
4. **危险改由剪影说**。45 度斜条是工业语言的「危险」，森林里没人这么说话；换成荆棘之后颜色也帮不上忙（`accent2` 对墙 1.98 喊不动），只能靠 `edge` 的实心尖。第一版六根尖连成一整条黑梳子，读出来是「地上有一道阴影」—— 尖与尖之间必须留缝、高矮要参差。
5. **一块圆得没有第二斑的斑会读成一只气球**：地衣第一版是一整颗圆，实拍像浮在墙前。四块大小不一、彼此压住的叶状斑才对。
6. **树桩与木箱撞脸**（都是方块加几道线）。桩子的身份全押在顶面那圈年轮 + 侧面两朵侧耳上，木箱押在 X 斜撑上。
7. **墙缝逐列抖 ±4 直接糊成一条黑泥**。缝要读成缝靠的是上下两道整齐的唇，抖只许抖一格。
8. **骨堆这一档尺寸上「一具」比「一堆」读得清楚**：三根骨头在 2 倍取景下糊成一团黑点，留一只头骨加一根肋反而一眼认得出。

**守门**：

- 生成器侧 `check_decor_rects()`（上面第 1 条）。**先证明它会响**：把 `moss_edge` 挪回 `(224,0)` —— `[d] moss_edge (224, 0, 16, 16) 与 vent (208, 0, 32, 16) 重叠 —— 后画的那件会盖掉前一件`，当场退出。
- `tileset_selftest` 新增 `_check_sets_share_rects()`：**落盘那套的条目必须在每一套里都有、且共有条目的矩形逐格相同**。这条是 D67 那句「旧关的摆图层可以整层复制过来」第一次被补上的钉子 —— 两套条目数相等时它顺带成立，D70 让两套第一次不对称（14 vs 21），它第一次可以被破坏而没人报错。**会响的收据**：手改 `tiles_d.json` 把 `monitor` 的矩形挪一格 → `FAIL [g/d] 共有条目 monitor 的矩形两套必须相同：[128.0, 0.0, 48.0, 32.0] vs [128.0, 32.0, 48.0, 32.0]`（旧的那条「装饰 monitor 在 (8,2)」也同时响），复跑生成器照绿。
- 四条无头守门：`TILESET SELFTEST DONE failures=0 checks=677`（634 → 677：d 多出的七件各带四条性质断言，加共有条目那 14 条与条目数那条）/ `VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=3 failures=1`（那一条 FAIL 仍是用户未提交的 `level1.tscn` 里 `Objects` 容器带位移 (-2,1)，按约定不由我修）/ `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0`。
- **g 那一侧一笔没动，可核**：`git diff` 对 `lab_tileset.tres` / `tiles.json` / 两张 `tilesheet_*.png` / `preview_tiles.png` 全为空，九张 `preview_room_*.png` 里只有 `d` 那张变了。**要说清的一条**：会话开始时 `lab_tileset.tres` 上带着一份**未提交**的异常改动（往 g 的资源里塞了 `sources/3`、`sources/4` 挂 d 的两张图集 —— 正是 D67 警告的「新的挂着旧的」那个形状），本次 `build_tileset.gd` 重建把它覆盖回了 HEAD。它不是被改坏，是被生成器写回了它唯一该有的样子；但它是别人的未提交内容，所以记在这儿。**订正（同日，见 D71）**：那份不是异常 —— 用户在给第二关做混合图集并自己画物理层，我按形状把它认成了事故、还建议撤掉，是他追问一句才拦下来。内容现已搬进 `assets/tiles/level_02_tileset.tres`（四个源与手画的 22 条整格碰撞都在）。**「产物文件由生成器独占」这条结论不变，变的是执行方式：不让它住在产物里，而是给它一份自己的资源。**

**How to apply**：一，**"不协调"要先塌缩成可测量的数再动手**。这次如果直接开画，我会去改 `quilt` motif（因为"森林感"听起来像纹理问题），而真正的病灶是 `metal` 1.66 / `edge` 10.52 这一对 —— 它说的是"这套配色下装饰只剩轮廓这一条信道"，于是该动的是剪影表，不是 motif、也不是构件。二，**参数化的收益永远在第二次才兑现**：D67 因为 painters 吃 `p` 而只花了数组里的一行；这次因为 painters 表本来就是"一张表"，加一套词汇表就只是多一张表 + 一个 `decor_set` 键。以后判断"要不要把某个常量提成参数"，问的不是"现在有几套"，而是"会长出第二套吗"。三，**换风格时先问哪句话是语义、哪句话是风格**。`accent2` 是风格（这套的强调色），"琥珀 = 可拾取"是语义 —— 两者共用一个键的时候，换风格就把语义一起换掉了，而那不报错、只是牌从此指错东西。凡是跟着别的实例走的颜色，都得有自己的名字。四，**同源契约在第一次不对称时就要补钉子**：两套条目数相等时"复制图层能对上"是顺带成立的，一旦允许一套多东西，它就成了一个需要被钉住的命题。五，**亮底不是暗底取反**。同一套画法搬到亮底上，光晕、玻璃、金属填充三样会同时失效，只有描边和近黑填充活下来 —— 所以换底色的代价是重排"什么承载信息"，不是重算颜色。

---

### D69 · 相位器件：平时受世界钟、被锚吸住时反过来跟手 —— 面板与穿梭块（「默认世界钟」这条不许绕开）

**起因（2026-10-26）**：D68 把锚做成"玩家自己瞄准发射"的一根线，但手上没有值得吸的东西 —— 移动方块被吸住只是"停/走"，不改变任何谜题状态。他开的需求是「接下来我们需要一些可以被附着并改变实际状态的物体」。我的第一版把新物件写成"只有被锚着时才动"（给 `TimeReceiver` 加一道"有没有被接管"的休眠闸），被他当场否掉：「这些物体在平时也应该受到世界钟的调控，只不过在被锚点附着时会反过来调控，而不是完全独立于其他物体」。**那道休眠闸一行都没写**，整条设计改成"默认世界钟、被锚时换源"——这正好也是 D68 已经铺好的路：锚只换 `TimeReceiver` 的时间源，器件根本不需要知道自己在被谁喂时。

**四件东西**：

1. **`components/clock_device.gd`（`ClockDevice`）** —— 这一族的共同地基：`_clock` 按 `TimeReceiver.get_physics_delta()` 一格一格攒，子类只回答三件事（目标形状 / 它落在哪 / 状态变了怎么落地）。
2. **`phase_panel.tscn` 相位面板** —— 中间 32×16 的底座**永远实**，两侧 96×16 的桥面按窗口现形（切 `PanelShape.disabled`）。底座常实的第二重理由：桥面虚着时射线打在壳上，吸附不会因为相位正好在关窗口而落空 —— 守门把"幽灵态也能吸"当独立一条钉着。
3. **`phase_shuttle.tscn` 相位穿梭块** —— 48×16 的实心踏板在两个停靠点之间**整块瞬移**：A = 场景里摆下去那一点，B = A + `offset`（跟着节点旋转走）。不存在中间位置，所以没有"被推着横移"或"半路扫到人"这两种情况。
4. **导出项**：`period` / `duty` / `phase` 住基类（`period ≤ 0` = 恒开，`duty` 0/1 = 恒关/恒开，都是合法配置）；`panel_size` 与 `step_size` / `offset` 住子类。编辑器里 `_clock` 钉在 0、按 `phase` 预览开局那一格 —— 摆图看到的就是进游戏第一眼的形状。

**三条裁定**：

1. **底座常实、只切桥面（D1）**。它**不判断**玩家在不在桥面上：站上去永远踩得到东西，"会不会掉下去"由桥面自己的相位说。这条同时给锚留了一个恒定的靶子。
2. **变实/换头之前问一次占位（D2）**。`_target_blocked()` 用目标矩形（四周内缩 `PROBE_INSET = 1 px`）做一次 `intersect_shape`，`CLEAR_MASK = 2 | 4` 只认玩家与别的 time_solid，**刻意不认地形**：摆歪到墙里是摆图错误，不该让器件在运行时永远变不实；而贴着地面那条相切边界会被误判（D21 的实测）。被占着就**停在旧状态**：`_applied_on` 不动、画出来的也不动、只立 `_blocked` 旗，下一帧接着问 —— 于是永远不会出现"画着虚、其实是实体"或"把玩家挤开"的那一拍。变回虚体/收回永远放行（收小不会挤人）。
3. **穿梭块是"会抽走落脚点的踏板"，不是电梯（D3）**。玩家站在 A 点、它跳到 B，人留在空中往下掉。不做载人、不做推送 —— 载人是移动方块与活塞的分工，这块的动词是"站稳靠时机"。

**行为矩阵（六行，kit_selftest 第 23 组逐行钉住）**：

| 世界 | 手 | 锚 | 器件 |
|---|---|---|---|
| 流着 | — | 未吸附 | 按世界钟自己开合 / 自己跳 |
| 冻着 | — | 未吸附 | 停（门控 delta = 0） |
| 流着 | 站着 | 吸附中 | **停**（跟手不跟世界钟） |
| 冻着 | 按着方向键 | 吸附中 | **走**（锚给的是真实 delta） |
| 冻着 | 按着 → 松开 | 吸附中 | 当帧停（不等世界那道 0.08 s 缓冲） |
| 流着 / 冻着 | 任意 | 按 E 回收 | 当帧回世界钟；相位**不清零** |

第 3 行是最容易被"顺理成章"写错的一格：既然"被吸住时跟手"，那人站着、世界流着的时候它当然也不该动 —— 可若实现成"吸附 = 接管 = 永远供时"，这一格就变成"一直走"，而画面不会报错。第 5 行同理：**锚不吃松手缓冲**，否则按一下松手，器件还会多走 0.08 s。

**两条非显然处**：

1. **两个子类都写 `extends "res://components/clock_device.gd"`，不写 `extends ClockDevice`**。`class_name` 在编辑器里有，但无头跑时 `.godot/global_script_class_cache.cfg` 里不一定有这一条 —— 用路径 extends 才不依赖那份缓存；`class_name` 留着给编辑器与类型标注。
2. **形状资源要在运行期独占一份（D21 那笔账）**。`.tscn` 里的 `RectangleShape2D` 是同一场景所有实例**共用**的：两块面板改 `panel_size` 会一起改。`_sync_geometry()` 第一次就 `duplicate()` 成自有资源，守门用"改一块、孪生那块必须不动"钉着。

**摆图侧的账（摇表成本）**：`period 2.0 / duty 0.5` 这一档下，**最坏要摇满 1.0 s 才翻面**（刚错过边界那一瞬）。地面跑速 260 px/s → 手按着走 1 s = 260 px < 320 px 射程，所以"吸住 → 跑着摇 → 等它翻面"在射程内做得完。这是本族的硬账：**摇一次 = 至少一次窗口穿越的时间，锚不缩短它，只决定"世界冻着也能摇"**。

**守门**：

- `verify_kit` 新增 `_verify_clock_devices()`：静态 6 类（无 `_process`、禁读五个全局量、必须从 `_receiver.get_physics_delta()` 读、占位查询的 `CLEAR_MASK` 与 `intersect_shape` 必须在、面板必须切 `PanelShape.disabled`、穿梭块必须整块瞬移）；真物理实例化两件 + 各自孪生，钉默认几何 / 层 4 与 mask 0 / `anchorable` 组与 `TimeReceiver` / 相位映射三档 / 底座常实且桥面上沿与底座上沿齐平 / 穿梭块回 A 且 B = A + offset / 改导出项后派生盒重算且**不波及孪生**。收据里 `anchorables` 从 1 涨到 **3**。
- `kit_selftest` 第 23 组 **50 条**，走真实 `player.tscn` + 真实 Input 事件 + 真实 `TimeAnchor`：矩阵六行逐行（含"世界流着人站着照停"这条否定式与"冻着回收后一动不动"）、幽灵态吸附、占位停住（玩家 / 层 4 实体各一次 + 让开后下一拍就变实）、相切不误判（人站在底座上）、穿梭块 A/B 瞬移与锚跟随、`period 0` 与 `duty 0/1`。
- **新钉子先证明会响（两条破坏性对照）**：①把 `ClockDevice` 的读数换成 `TimeManager.get_physics_delta()` → kit 第 23 组 **8 条红**、verify **多 2 条**（`...里出现了 TimeManager.get_physics_delta...` / `ClockDevice 没从 TimeReceiver 读 delta`），`failures=3`；②拆掉 `_refresh_state()` 里那道 `if target and _target_blocked():` → **恰好 3 条红**（玩家占着桥面 / 层 4 实体占着桥面 / 人站在 A 点），多一条都没有。两条都复原后复跑照绿。
- **四条无头守门**：`VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=3 failures=1`（那一条仍是用户未提交的 `level1.tscn` 里 `Objects` 容器带位移 (-2,1)）/ `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / tileset 那边另有 `[d]` 一族红，见下条。
- **一条不属于本条的噪声**：`tileset_selftest` 现在在 `[d]` 装饰层上报一串 FAIL（清单挂 21、图上量到 14），来源是用户未提交的 d 套集 WIP（`tiles_d.json` / `tilesheet_decor_d.png` / `lab_tileset_d.tres` / `gen_tiles.py` 都在工作区里改着），按约定不由我修。**订正（D70 落地当天）**：那条噪声已随 D70 把 d 的装饰补到 21 件消失，现 `TILESET SELFTEST DONE failures=0 checks=677` —— 这行保留原文是为了记住"两套并存时，d 那一侧在半成品状态下会从装饰段先红"。

**How to apply**：一，**"被锚吸住时控制它"不等于"它平时不动"**。这一族只有一条读数（`TimeReceiver`），默认世界钟、被锚时换源；任何"给器件加一道'有没有被吸住'判断"的写法，都会把 D66 那条分界做成第二个时间权威。二，**离散两态优先于连续位移**：面板切 `disabled`、穿梭块整块瞬移，两者都没有"半路"可言，于是占位查询、冻结停相、重载回灌都没有中间态要补账。三，**占位查询要带内缩**：1 px 把"相切"与"重叠"分开，玩家站在目标顶边上不该让平台永远不敢变实；内缩是难度旋钮（越收越严），别在别处再抄一份数。四，**新增可锚物只做三件事**：根挂 `anchorable` 组、上 time_solid 层、挂 `TimeReceiver`；族检查按判据扫、不维护白名单，空转必须响。五，**成本要算成表交出去**：这一族的摇表是 1.0 s / 260 px，写进手册 —— 让"这块面板摆多远"成为看得见的决定，而不是等试玩才觉出"够不着"。

---

### D71 · 第二关的混合图集搬进独立的手维护资源（`assets/tiles/level_02_tileset.tres`），顺带记一次「把用户的工程认成事故」的错

**起因（2026-10-27）**：他在搭第二关，往 `lab_tileset.tres` 里加了 d 的两张图集（`sources/2` = `tilesheet_decor_d.png`、`sources/3` = `tilesheet_terrain_d.png`）并**自己画了物理层**（那批新增行里有 22 条 `physics_layer_0/polygon_0/points`，是整格 16×16 方块）。我读到的形状恰好是 D67 警告过的「d 的图集挂在 g 的 TileSet 上」，于是先建议 `git restore` 把它撤掉，还提议补一条「TileSet 里不许有清单之外的源」的守门 —— 那条守门禁掉的正是他在做的事。他一句「我在搭建第二关的时候导入了新的 tileset 资源并绘制物理层，为什么要撤掉」把方向改了回来。**撤没撤成：没撤成，一次都没执行。**

**裁定（他一句话定：把第二关的瓦片资源改成独立文件）**：混合图集从此住 `assets/tiles/level_02_tileset.tres`，`lab_tileset.tres` 与 `lab_tileset_d.tres` 交回给生成器独占。

**三条要点**：

1. **搬法是逐字节复制、只换第一行的资源 uid**，别的什么都不改。新 uid 由 Godot 自己生成（无头跑一句 `ResourceUID.id_to_text(ResourceUID.create_id())`），不是我手搓 base36。**源索引 0..3 一字不动**：关卡的 `tile_map_data` 里存的是 `source_id`，重排源 = 已经刷下去的砖集体换图集。除首行外两份文件逐字节相同（`diff <(tail -n +2 …)` 证过）。
2. **产物文件与手维护文件分开，是这条决定的实质**。往产物里手加源 = 下一次 `gen_tiles.py → --import → build_tileset.gd` 时被静默抹掉（D70 当天已经抹掉过一次他这份内容，那次我还把它记成了「异常改动」）。要一份混合图集，就给它一份自己的资源，并承认它**不受管线保护**。
3. **守门盲区要摊开说**：`tileset_selftest` 那 677 条只验清单声明的 `sources/0..1` 挂的是哪张图，**新这份资源一格都不验** —— 于是"手画的碰撞漏了一格"不会红，只能靠眼睛和实机。以后真要为第二关补钉子，正解是把它作为第三条 `SETS` 记录进生成器与清单（碰撞与 peering 从清单来），而不是给手维护文件加一套平行检查。

**这条错本身怎么记**：**形状像事故不等于事故**。对未提交的改动，"它长什么样"永远替代不了"他在做什么"；给 destructive 建议（restore / 覆盖 / 新加一条会红在他手上的守门）之前先问一句意图。这次是靠他追问才没把人家几小时的手画撤掉，而我那份"分析"看起来头头是道 —— 这正是 [[feedback-prove-validation-fires]] 里"数值假设会骗人"在**意图**那一维的对应物。

**核过**：临时脚本（用完已删）无头载入那份新资源：`sources=4`、`physics_layers=1`，四个源分别是 `tilesheet_terrain.png`(16 格) / `tilesheet_decor.png`(14) / `tilesheet_decor_d.png`(90) / `tilesheet_terrain_d.png`(16)。四条无头守门照旧：`VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=3 failures=1`（唯一那条仍是 `level1.tscn` 的 `Objects` 位移 (-2,1)，归他）/ `kit-selftest failures=0` / `SPRITE failures=0` / `TILESET failures=0 checks=677`。

**还没结清的一笔**：`lab_tileset.tres` 上那份未提交的混合图集**仍然在工作区里**（撤掉它需要他逐次授权，这条约束是硬约束）。现在这份内容的副本已经安全落进 `level_02_tileset.tres`，所以那一步随时可以做：先让第二关那三层 `tile_set` 指到新文件并存档，再 `git restore assets/tiles/lab_tileset.tres`。

**编号**：本节点用掉 **D71**（D33 仍是留空号），**下一个空号 D72**（同日 D72 也已用掉 —— 见文末「`d` 整条降亮」；现行下一个空号 **D74**）。

---

### D72 · `d` 那一套整条降亮到 ×0.80（他挑的 B 档）：亮底没有余量给"加辉"，可拾取琥珀是唯一不跟着缩的键 —— **2026-10-28 订正：落盘档已回调到 A ×0.90，见本节末**

**起因（2026-10-27）**：他报「第二关整体风格太亮，在移动加上 shader 之后就更亮了，有点看着不舒服」。量出来的不是"亮了一点"，是**削顶**：`freeze_crt.gdshader` 的 `linear_fac = 1.3` 是等比乘法再硬夹 255，同一道算式跑在两套地图的生成预览上 —— g 只有 **7.9%** 的像素至少一个通道撞天花板，d 是 **45.7%**（含扫描线那一半的 10% 压暗后仍有 45.7%）。灰阶阶梯 20/90/180/**236** 经 ×1.3 变成 26/117/234/**255**：最后两档被压到同一格，也就是**色相与细节一起没了**。d 的墙 (236,227,240) 在冻结那一拍直接变成 (255,255,255)，而 D70 刚量过这套里装饰只剩"轮廓"一条信道 —— 轮廓一爆，那套配色就没有任何东西剩下了。

**他的裁定（两条，第二条把我给的方案否掉一半）**：① 我先给了三条路（每关一个冻结增益导出旋钮 / 把等比增益换成软膝曲线 / 降调色板亮度），他选**降 tile 亮度**；② 理由值得记：**「我之后的每一关都会基于同一个场景拓展而不是使用那种直接选关的设计」** —— 所以"每关一个旋钮"这类**按关分叉**的修法在他这个结构里不成立，会把一条全局视觉规则拆成一堆关卡私有状态。**How to apply:** 给修法之前先问这条修法住在哪一层；这个项目没有选关，就没有"每关一份视觉参数"这个位置。

**选型图**：`tools/gen_d_dim_preview.py` → `assets/tiles/preview_d_dim.png`（五行 × 两格：静止 / 冻结）。两条同源口径按 D58 立的规矩走：房间由**落盘那个画师** `gen_tiles.render_room()` 现画（换的只是调色板数值），冻结那一拍由**出货那段 fragment 的离线复现** `gen_freeze_filter_preview.crt()` 算 —— 所以图里的"更亮"和游戏里是同一道算式，不是第二份抄写。读数（`墙` = 相对亮度 ×100，削顶线 = 255/1.3 = **196**）：

| 档 | 静止均值 | 冻结均值 | 冻结削顶 | 最高通道 | 过线键数 | 主角/墙 | 轮廓/墙 | 金属/墙 | 玻璃/墙 |
|---|---|---|---|---|---|---|---|---|---|
| 现况 | 205.5 | 226.5 | 45.7% | 252 | 10 | 15.70 | 10.52 | 1.66 | 1.03 |
| A ×0.90（**现落盘**，2026-10-28 订正） | 185.2 | 220.8 | 32.0% | 227 | 6 | 12.54 | 8.97 | 1.64 | 1.03 |
| **B ×0.80（当时选，他试完说太暗）** | **165.3** | **203.7** | **3.0%** | **202** | **1** | **9.91** | **7.59** | **1.61** | **1.02** |
| C ×0.72 | 148.8 | 183.4 | 1.8% | 181 | 0 | 7.99 | 6.41 | 1.57 | 1.03 |
| D ×0.64 | 132.8 | 164.0 | 1.0% | 161 | 0 | 6.38 | 5.37 | 1.53 | 1.02 |

他挑 B（**2026-10-28 订正：试玩后改挑 A，见本节末**）。B 的位置是"正好压线还留一格"：`lip` 202 仍过 196，所以残余 3.0% 削顶（那部分是画师里 `lighter()` 混向纯白的高光，到不了零，也不该为零）。C 是"键这一层归零"那一档，我原本倾向 C，**图是他看的，按图走**。

**三条非显然**：

1. **`pickup` 是唯一不跟着缩的键**（`PIN_KEYS`）。可拾取琥珀 `PICKUP_AMBER (250,190,74)` 与 `key_card.png` 那张实物零件必须同色 —— 告示牌上那只卡全靠这件事说得出「这张开这扇」（D70 第 4 条）。**跟着本套走的必须是风格量，不能是语义量**；这条在 D70 记过一次，这次是它第一次真的挡下一处"顺手一起缩"。
2. **降亮没有顺手还掉 D67 那笔"构件在 d 墙上读不出来"的账**（**订正：原记的「青 1.62→1.02」抄错了栏 —— 抄成了 `metal/墙`；下面这行是 2026-10-28 用同一把尺对三档墙重算的，见本节末**）。同一批真色，只换墙：琥珀 1.34→1.18、LED 底座 13.51→8.53、端帽 7.07→4.46。因为 WCAG 那个式子里墙从"比所有构件都亮很多"退到"落在构件亮度中间"，**两侧的距离一起变小**。所以别把这次当成"亮地图的构件问题解决了" —— 那还是要走 D67 裁定③留的那笔"重开构件色"。
3. **这次没动 shader，也没动 `.tres`**。图集矩形与源索引一字不变 ⇒ `build_tileset.gd` 不需要重跑（也就没有覆盖他那份 `lab_tileset.tres` WIP 的风险），而 `level_02_tileset.tres` 引用的是同一批 PNG 路径，**它自己就跟着变暗**，手画的碰撞一格不丢。

**验收**（**这一行的数随下面的订正一起变：现落 A ⇒ `wall 62.1 / p/wall 12.54 / o/wall 8.97`，仍与选型图 A 行逐位相同**）：`py tools/gen_tiles.py` 打印的 `contrast_report` 里 d 那行 = `wall 48.1 / p/wall 9.91 / o/wall 7.59`，与选型图 B 行逐位相同（同源，不是抄的）；**g 侧可核零变化** —— `git diff` 对 `tilesheet_terrain.png` / `tilesheet_decor.png` / `tiles.json` / `preview_tiles.png` 与九张 `preview_room_*.png`（除 `d`）全空。四条无头守门：`TILESET SELFTEST DONE failures=0 checks=677` / `VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=3 failures=1`（唯一那条仍是 `level1.tscn` 的 `Objects` 位移）/ `kit-selftest done failures=0` / `SPRITE SELFTEST DONE failures=0`，无 `SCRIPT ERROR`（`--import` 那两条 `ERROR:` 是 MCP 探针端口被开着的编辑器占了 + 资源泄漏基线，与本条无关）。**留给人眼的一条**：真窗口 + 那层 CRT 之下，B 档的 d 在"按住方向键"那一拍还亮不亮、以及墙降到 48.1 之后那套「树丛」装饰的轮廓读不读得比现在清楚（图里读得出，实机没验）。

**订正（2026-10-28）：他试玩后嫌太暗，落盘档从 B ×0.80 回调到 A ×0.90**。他的原话是「前面我们调整过新的地图的亮度，我觉得有些太暗了，我们回调到当时说的方案 A 的亮度」—— 这是他在**同一杆秤**上重新称了一次（"亮"对"细节"），不是本条决定错了：B 与 A 的差别是削顶 3.0% vs 32.0%，也就是 A 档下冻结那一拍仍有约三分之一像素至少一个通道撞 255，这条代价原样回来，别把它读成"顺手修好了削顶"。

- **改法只有一处**：`STYLES["d"]` 的十四个数值。**关键纪律：乘数作用在 D70 那版原样字面量上，不是在 B 的值上再乘 1.125** —— 后者会引入第二次舍入，落盘值就不再等于选型图里他挑的那一行，而"图与落盘同源"正是本条唯一的验收手段。验收（重跑 `gen_tiles.py` 的 `contrast_report`）：d 行 = `wall 62.1 / p/wall 12.54 / o/wall 8.97`，与选型图 A 行**逐位相同**。
- **选型图的基线因此必须钉死**：`gen_d_dim_preview.py` 原来读 `G.STYLES["d"]` 当基线，而那份现在自带落盘系数 —— 再乘一遍会让五行读数全部相对当前档漂移，改一次档就得到一张自指的假图。现改成字面量 `ORIGINAL_D`（逐键抄自 `git show d00f5c7:tools/gen_tiles.py`，唯一一份没降亮的 `d`）。
- **顺带对出的一个记录误差**：上面那张表的"现况"行两个均值，文档写的是 205.5 / 226.5，用 `ORIGINAL_D` 同源重跑打印的是 **205.6 / 226.6**，同行其余八个读数逐位相同。以重跑为准（本行不改那两个数，改了就没法说明它当时是怎么量的）。
- **上面第 2 条里那两个数对不出来，现在用同一把尺重算**（`G._cr()`，墙取三档 `bg`，色全部是 D67 那张表的在册真色）：

  | 在册色 | 原样墙 (236,227,240) | **A 墙 (212,204,216)** | B 墙 (189,182,192) |
  |---|---|---|---|
  | 主角身体 (10,12,12) | 15.70 | **12.54** | 9.91 |
  | 主角 g2 亮边 (206,222,250) | 1.09 | **1.15** | 1.46 |
  | 祭坛核心 / 光幕 青 (110,230,240) | 1.18 | **1.06** | 1.34 |
  | 门 LED 亮态 (182,242,248) | 1.01 | **1.27** | 1.61 |
  | 门 LED 锁定琥珀 (250,190,74) | 1.34 | **1.07** | 1.18 |
  | 门 LED 底座 `led_socket` (21,30,37) | 13.51 | **10.79** | 8.53 |
  | 端帽 `end_shade` (67,75,86) | 7.07 | **5.64** | 4.46 |
  | 门体 ab deep (94,108,125) | 4.29 | **3.43** | 2.71 |

  两条更正：**①「青 1.62→1.02」抄错了栏**（那对数长得像 `metal/墙`，真正的青 (110,230,240) 对原样墙是 **1.18**、对 B 墙是 **1.34** —— 降亮让**亮构件**变好而不是变差）；琥珀、LED 底座、端帽那三对**原记无误**，只是缺 A 档（琥珀 1.34→1.07、底座 13.51→10.79、端帽 7.07→5.64）。**②「两侧距离一起变小」只说对了一半**：墙往下走时，比墙暗的构件（主角 15.70→9.91、深色门体 4.29→2.71、LED 底座 13.51→8.53）确实一路变差，而比墙亮的构件（LED 亮态 1.01→1.61、青 1.18→1.34、g2 亮边 1.09→1.46）一路变好。**结论不变的那半**：主角轮廓与深色门体这两头，A 档（12.54 / 3.43）比 B 档（9.91 / 2.71）更接近原样，所以这次回调把 D67 那笔账往"少欠一点"的方向退了一步；而"构件在亮底上读不读得清"仍然要靠 D67 裁定③那笔"重开构件色"，不是靠亮度档。
- **影响面与 B 档那次完全一样**：`.tres` 一个字没动（矩形与源索引不变，`build_tileset.gd` 不重跑），`level_02_tileset.tres` 引用的仍是同一批 PNG 路径所以它自己跟着变亮；`git status` 只命中 `tilesheet_terrain_d.png` / `tilesheet_decor_d.png` / `preview_tiles_d.png` / `preview_room_d.png` 四张，g 侧与另外八张 `preview_room_*` 零变化。

**编号**：本节点用掉 **D72**（D33 仍是留空号），**下一个空号 D73**（次日 D73 已用掉 —— 见文末「时间锚点拆成独立一项能力」，现行下一个空号 **D74**；上面那条订正只是改他挑的档，不占新号）。

---

### D73 · 时间锚点拆成独立一项能力（`is_anchor_enabled`），与"世界冻不冻"互不蕴含 —— 暂时是测试功能

**起因（2026-10-28）**：他提「这应该作为一个独立的新的能力，而目前似乎与时间冻结能力绑定在一起了，我希望分离开来，暂时作为一个测试功能」。绑定是事实而且绑得很紧 —— `TimeManager.is_ability_enabled` 一个 bool 同时被两族读：TimeManager 自己两道（冻结状态机 + 意图通道静音），以及 `time_anchor.gd` **四处**（复位 / 发射闸 / 供时闸 / 画瞄准线与回执）。`verify_kit` 还把那个串钉成了"四条闸缺一不可"之一，所以换名要连钉子一起换。

**四条裁定（他一句"没问题，开始写吧"整体放行）**：

1. **`TimeManager` 加第二个旗标** `is_anchor_enabled` + `set_anchor_enabled()` + `anchor_enabled_changed` 信号，默认 `false`。setter **刻意不跟着关 `reset_state()`** —— 这一项不拥有世界状态，关它只该让锚自己收摊，而那本来就是 `TimeAnchor._physics_process()` 那道闸在做的事。
2. **锚点那四处换读新旗标，四条闸的形状一字不动**（活着 / 没被移动锁掐 / ~~能力已开~~ 锚点能力已开 / 手上在动）。
3. **测试入口 = 关卡根导出项 `start_with_anchor: bool = false`**，`LevelBase._ready()` 里写一次 —— 照 `start_with_ability` 现成的形状，所以 F5 与 F6 两种跑法都有效。**不加新调试键**：那会让旗标长出第二个书写者（项目口径"谁亮着只能有一个书写者"）。**不进 `run_state`、祭坛不写它** —— 它是测试开关不是进度，也没有授予路径，直到以后真立"锚点祭坛"那条决策。
4. **守门要钉住"分离"本身**，否则哪天有人把两处读回同一个旗标不会响。

**三条不显然**：

- **分离之后锚点少了什么，要说在前面**：只开锚点、不开冻结时，"世界冻着它照走"那层**对照感消失**（世界不停、CRT 不上屏），能测到的只剩"我按着它才走、我站着它停"和锚上那 12 格回执走带。这不是 bug，是分离的定义 —— 两项互不蕴含、可以任意组合，想连背景一起测就在同一关把 `start_with_ability` 也勾上。
- **`verify_kit` 新增两条反向钉**：① 锚点脚本里**不许再出现** `TimeManager.is_ability_enabled`（回读 = 把两项重新焊成一件事）；② 关卡根必须有 `TimeManager.set_anchor_enabled(start_with_anchor)` 那一句（导出项存在而没人写旗标 = 勾了也没开门）。加上原来那条闸名单换名，一共三条钉在"分离"这件事上。
- **一条本项目踩过两次的输入坑，这次是被自己的新钉子炸出来的**：`Input.action_press/release()` 排的事件要等**下一次主循环 flush** 才成边沿。新那钉"冻结关着 + 按着方向键 → 发得出"里按下又松开，那一下**松手的边沿落到了后面那条"世界冻着起飞"的窗口**，把刚钉住的世界解回流动 → 方块在 0.08 s 缓冲里多走 8.0 个相位单位（`elapsed_path_time += d × travel_speed`，travel_speed 80 ⇒ 0.1 s = 8.0），红的却是**别人那条相位钉**。修法是在断言之后 `await _frame(3)` 把松手边沿就地等掉。**口径：任何在冻结窗口附近按下/松开输入的测试，都要自己先把边沿 flush 干净**，否则症状会漂到下一条断言上，看起来像上一条改动弄坏了玩法。

**契约变更**：`TimeManager` 多一个旗标 + 一个 setter + 一条信号；`LevelBase` 多一个导出项 `start_with_anchor`（已进 `verify_kit` 的导出项白名单）；`run_state` 仍四个键、无新构件、`.tscn` 一字未改。调试面板那一行现在同时显示 `ability=` 与 `anchor=`（两项独立之后必须都看得见）。

**验收**：三条新钉全部先证明会响 —— ①把发射闸改回读 `is_ability_enabled` → `VERIFY … failures=2`（多那条"回读"FAIL）+ `kit-selftest … failures=2`（两条否定式同时红，其中"发得出（false）"正是分离没做到的样子）；②删掉关卡根那一行写入 → `VERIFY … failures=2`（"没有书写者"那条）。两处复原后照绿。四条无头守门：`VERIFY DONE doors=3 pistons=5 fallzones=1 anchorables=3 failures=1`（唯一那条仍是 `level1.tscn` 的 `Objects` 位移，归用户）/ `[kit-selftest] done failures=0` / `SPRITE SELFTEST DONE failures=0` / `TILESET SELFTEST DONE failures=0 checks=677`，无 `SCRIPT ERROR`。**留给人眼**：在沙盒或第二关勾上 `start_with_anchor`（不勾 `start_with_ability`）跑一次，看"世界没冻、只有我按着的那件东西在跟我的手走"读不读得出来 —— 这是这一项能力**第一次脱离祭坛背景**被单独观察。

**编号**：本节点用掉 **D73**（D33 仍是留空号），**下一个空号 D74**（同日 D74 已用掉 —— 见文末「树丛套第二批装饰」，现行下一个空号 **D75**）。

---

### D74 · 树丛套第二批装饰（八件）：选型图抓到四处"画出自己那一格"，而守门里那条「多出条数 ≤ 8」被这次撞红后换成了真约束

**起因（2026-10-28）**：他提「我还想丰富一下第二关的装饰物，分析一下还能加点什么，给我一个预览」。先做的是**缺口分析**而不是直接画 —— `d` 那套（D67 出图、D70 换词汇）在册 21 件，按"它说得出什么、说不出什么"分下来缺六类：

| 缺的那一类 | 这套里最接近的 | 差在哪 |
|---|---|---|
| 一棵**站着的树** | `vine_v`（垂藤，贴墙）、`stump`（cabinet 换皮） | 「树丛」词汇里没有带冠的树，垂直体量全挂在墙上 |
| **墙面**的活物 | `nest_box` / `grotto` / `crevice` / `lichen` | 全是实验室件的换皮，缺一块「墙自己长了东西」的面 |
| **崖面 / 坑壁**过渡 | `moss_edge`（只管踏口那一条） | 坑的两壁还是赤裸的砖 |
| 石头的**小档** | `rock`（48×32 大块） | 没有"小的、散落的"，坡脚与坑底只能靠苔填 |
| **倒木**（落地的横木） | `root_h`（贴墙的根） | 地面缺一个横卧的大体量 |
| **久无人来**那句 | `crate_wood` / `barrel`（说的是「来过」） | 缺一件「走了很久」 |

**选型图**：`tools/gen_grove_decor_preview.py` → `assets/tiles/preview_grove_decor.png`（十件候选，每件两格 = 静止 / 冻结，外加"现状房间 vs 装上新件的房间"两行 + 一张图集余量图）。同源三条按 D58 的规矩：图集由**落盘的** `build_decor_atlas()` 现画（候选只是临时喂进 `DECOR_GROVE_EXTRA` / `PAINTERS_GROVE` / `DECOR_NO_ROUND_GROVE` 三张表，连"亮底先补描边再擦角"那趟后处理都是同一段代码），房间由 `render_room()` 现拼，冻结由 `gen_freeze_filter_preview.crt()` 算。**这一条要记**：卡片必须先拼成**一整页 1280×720 再跑一次 crt**，然后逐格裁回来 —— 扫描线周期（720/180 = 4 屏幕像素）与色散（0.001×1280 = 1.28 像素）都是**按屏幕像素**定的，在 96×96 的小卡上直接跑会得到另一套周期，那张图就是谎话。卡片比例也按实机取 `zoom=2`（1 世界像素 = 2 屏幕像素）。

**十件里落八件，砍两件**（他一句"ok"整体放行按推荐方案）：`tree` `ivy_patch` `vine_curtain` `log` `fern` `moss_side` `scree` `web_corner` 进清单；**砍 `puddle`**（`glass` 对墙 1.03 —— 见下面第 3 条，它的问题不是"怕冻结"而是**静止态就看不见**）与 **`leaf_litter`**（与 `moss_edge` 抢同一条踏口带，价值最低）。

**三条只有量了才知道的**：

1. **这张图自带一条"出格检查"，第一次跑就抓到四处**。每件候选单独画一遍、数落在自己矩形之外的不透明像素 —— 抓出 `ivy_patch` / `vine_curtain` / `scree` / `leaf_litter` 各画出去 3~18 像素。这正是 D70 当场踩过的那坑的形态：图集摆重叠**不报错**，后画的把前一件盖掉，清单里两块、图集里一块。修法是各件收回自己的矩形（叶的椭圆半径、藤帘的叶簇横向伸展、碎石的描边圈），并把"越斜的羽叶越短"写进蕨的算法。现在这一列全 0。
2. **三件第一版读成了别的东西**（图是他看的，所以先按图改再交）：`ivy_patch` 三排等大等高的叶 → 读成「墙上一排排插座」（改：叶大小与行高打散 + 每隔一两列留缺口 + 压一层半透明底把散叶绑成一块，并删掉顶边那道深色横条 —— 它读成一块搁板）；`log` 一圈矩形描边 + 顶上竖着的苔簇 → 读成「带绿齿的木板」（改：剪影走椭圆两头收口，苔贴着顶线趴下）；`scree` 用 `lip_shade` 当石身 → **对墙正好 1.00，只剩一圈描边在说话**（换 `mix(edge, bg, .35)` 这档冷灰，对墙 3.76）。**口径：同一件东西，主体色选错就等于没画 —— 描边只能救轮廓，救不了"看不见"。**
3. **`puddle` 的假设是反的**。我原本把它当"最怕冻结"的对照件放进来（`glass` 1.03 + 高光 `lip`），量出来：冻结前就有 57.0% 的像素过削顶线，但它在**静止态**就已经对墙 1.03 了 —— 也就是根本不用等滤镜，它平时就看不见。**结论：亮底上"反光面"这一类不是 CRT 问题，是选色问题。**

**守门**：`tileset_selftest` 那条 D70 写的「d 比落盘那套多出的条数 ≤ 8」**被这次撞红**（多出 15 条）。它红的原因不是任何一条真实约束被破坏 —— 那是"当前条数 + 1"那种抄第二份数的写法，每加一批装饰都必然撞。已换成真约束：**多出来的每一条条目，矩形都不许与任何一个共有条目重叠**（15 × 14 = 210 条），条数只留一条量级兜底（`≤ 64`，防"清单整个串套"）。**破坏性对照**：手改 `tiles_d.json` 把 `tree` 挪到 `[0,160,48,80]`（压在 `sign_card` / `sign_card_arrow` 上）→ `failures=3`（两条新钉各点一件 + 既有那条「装饰 tree 占几格」同时响），复跑生成器照绿。`checks` 从 677 涨到 **919**。

**管线**：`tools/build_tileset.gd` 多一个 `-- --only=lab_tileset_d` 开关。**理由不是省事**：`lab_tileset.tres` 现在是关卡作者**手改过的工作区文件**（往同一份资源里 graft 了 d 的两张图集 + 手画碰撞多边形），那种改动没有第二份，整跑一遍就连它一起重写掉。所以这次只重建 d 那一份，跑前跑后 `md5sum assets/tiles/lab_tileset.tres` 相同（`58a46ef0…`）；`tiles.json`（g 的清单）与 g 的两张图集、另外八套 `preview_room_*.png` 全部零变化。**How to apply:** 生成器写死的产物只要有一个被人在工作区里手改过，"整跑一遍"就不再是安全操作 —— 要么先问，要么给它一个只跑一半的入口。

**契约变更：零。** 纯皮：无新构件、无脚本、无信号、不进 `run_state`、关卡与玩家一字未改。清单条目 21 → 29（`tiles_d.json`），`lab_tileset_d.tres` 的装饰源跟着 29 块（瓦片号 = 图集坐标，所以**已刷的格子不会重排**）。**他那份手维护的 `level_02_tileset.tres` 不会自动拿到新瓦片** —— 要进第二关得单独点头（要么从 `lab_tileset_d.tres` 重拖，要么由我把这 8 条 tile 追加进 sources 2/3）。

**留给人眼（实机比例，图上看不算）**：① `tree` 的树干只有 6 像素宽，会不会读成一根电线杆；② `ivy_patch` 那层半透明底（alpha 46）在 CRT 那一拍还剩不剩"一块"的形状；③ `web_corner` 的 150/70 alpha 丝网在真机上够不够显眼 —— 它靠的是**暗**，不是亮。

**编号**：本节点用掉 **D74**（D33 仍是留空号），**下一个空号 D75**。

---

### D75 · 心电监护屏做成构件（B 方案）：皮与那块瓦片**逐格比字节**同源，而选型图把第一版那条"波形"打回重画

**起因（2026-10-28）**：他提「我们实验室的 tile 装饰里有一个心电图一样的显示屏，我希望将它做成动画，会不断波动，从而更能体现出时间的冻结与运动」。我先给了三条路（A = 只把瓦片画得更"能停"、B = 独立构件重画那块皮、C = 用图集声明式逐帧动画）+ 我倾向 A。**他直接否掉：「B，直接按照原图做一个新的构件吧」** —— 于是要件是 `scenes/objects/ecg_monitor/`（`EcgMonitor`，第二件纯装饰构件，D59 那只世界钟的同族）。

**C 为什么当场出局（本机探针，不是记忆）**：`TileMapLayer` 的属性与方法里 `anim` 相关 **0 条** —— 瓦片动画只有 `TileSetAtlasSource.set_tile_animation_*` 那一套声明式帧表，走**引擎自己的时钟**。世界冻住、屏还在跳 = 皮说谎。与 D59「世界钟为什么不是装饰图集格」同一条（D56 早就记过：表现层优先走零契约的装饰层，但"零契约"不等于"不受门控")。

**时基（照 D59 裁定 D1①，一字不改）**：`phase() = f(TimeManager.elapsed_world_time)` 的纯函数 —— 不累加 delta、不订阅 `state_changed`、不自带时钟。于是冻结即停、死亡重载自动归位、换关不漂。它**不挂 `TimeReceiver`**：装饰被锚点吸走只会改皮不会改机制，那条通道是给器件的（D69）。

**这条决策真正的形状：皮与图集那块瓦片同源**。`gen_tiles.ECG_PATTERN` 与 `EcgMonitor.PATTERN` 是同一道算式的**两处书写**，`decor_monitor()` 与 `_paint()` 是同一批矩形的两处书写。钉它的不是"我记得两边一样"：

- `verify_kit._verify_ecg_monitor()` 把落盘 `tilesheet_decor.png` 上那块 48×32 裁下来，与 `pixel_grid(0)` **逐格比字节**（1536 格），差一格就红。矩形从 `tiles.json` 读，不在守门里写死 —— 图集里挪一块会红在这里，而不是比错地方还全绿。
- **一个只有跑起来才知道的坑**：比色第一版比 RGBA 四个通道，红了 12 格 —— 全在四角抠掉的那 12 格上。原因不是画错，是导入参数 `process/fix_alpha_border=true` 会把**邻居颜色扩进全透明像素**（防黑边），所以图集上那些格的 RGB 是管线填的。现在比的是 **alpha 逐格相等 + 不透明格的 RGB 逐格相等**，两边都是"看得见的东西"。**口径：无头读纹理比色，比的是导入之后的资源、不是磁盘上那张 PNG。**
- 顺带钉住"落盘成品 ≠ 生成器的半成品"：soft 套那趟后处理会在瓦片外沿再压一圈 `edge`，于是 `decor_monitor` 画的那 1px 外壳环与压在底行的底舌在成品里**全都看不见**。构件照**成品**画（外沿直接描边、不画底舌），照半成品画就差 156 格。

**选型图把第一版打回了**：`tools/gen_ecg_monitor_preview.py` → `assets/tiles/preview_ecg_monitor.png`（14 个相位 × 静止/冻结两页，卡片放大 5 倍贴在真墙上，同源规矩照 D58：瓦片由 `build_decor_atlas()` 现取、矩形读 manifest、冻结跑 `crt()` 且必须先拼整页 1280×720 再算）。图上七帧并排，第一版那条波形（周期 7 列、每列都带 ±3~4 的偏移）**读成一排栅栏噪声，不像心跳**。改成真的那一拍：**周期 14 列 = P 波（0,-1,-2,-1,0）→ QRS 尖（0,0,0,-6,+7,-3）→ T 波（0,1,0）**，屏宽 42 列正好 3 个整周期。默认 `beat_period = 0.84` s（一列 60 ms，≈ 每分钟 71 跳 —— 读起来是"仪器在量一个人"，不是"屏幕在闪"）。**这条是"预览必须放大到看得清细节"的又一次收账**：48×32 在实机 1:1 下本来就看不清，所以静图验收一直在放过这种皮。
**这张图里没有第三份算式**：七个（现在十四个）相位是把落盘瓦片的屏幕带**按列横滚** k 格得到的，而"滚 k 列"与构件的 `PATTERN[(i+k) % 14]` 是同一件事，因为 42 是 14 的整倍 —— 所以预览与实机之间没有"预览自己漂走"的空间。

**守门**：静态 `verify_kit._verify_ecg_monitor()` 钉五类（① 时基只有世界钟一条，出现 `_process` / `Engine.time_scale` / `TimeReceiver` / `get_physics_delta` / 存档字段 / `signal` 就红；② 根必须纯 `Node2D`、零子节点、不进 `anchorable` 族；③ 屏宽必须整除周期、波形必须比表盘亮；④ 相位是纯函数 —— 推一格换图、推满一圈回原样、`beat_period<=0` 钉 0；⑤ 那条逐格比色），行为 `kit_selftest` **第 24 组** 九条（相位 == 当场独立重算的 f(世界时钟)、冻结 20 拍相位不动**且世界时钟本身也没涨**、连 `_shown` 也不漂、解冻后接着推且不漂、推一格换图、推满一圈回原样、`beat_period=0` 时世界在流也钉 0）。**破坏性对照两轮**：把描边色改一档 → 比色红 210 格；**文本型禁令两头都会骗人**（注释里提一次那个存档字段的原名 → 自己判红（假红），"必须读 `elapsed_world_time`"那条更狠 —— 只要把它留在文件头注释里、代码换成 `Time.get_ticks_msec()`，扫描器看不见代码已经换了时基，照样全绿（假绿，当场用破坏性对照抓到）。已加 `_code_only()` 剥掉注释行再扫，`_verify_clock()` 与 `_verify_ecg_monitor()` 两份禁令同时改用它；默认 `beat_period` 填 0 → 红；周期改 5 列 → 整除红；波形压到比表盘暗 → 红；`CHAMFER` 清空 → 四角红 ×4；时基换成 `Time.get_ticks_msec()`（墙上时钟，冻结里照走）→ 第 24 组红三条；`PATTERN` 全 0 → "推一格换图"红。全部复跑照绿。
**顺手换掉一条自红**：`_test_ecg_monitor` 里 `beat_period` 钉死 0.05 s 而不是照脚本默认值 0.84 断言"等 N 拍一定换格"（D58 那个坑）。

**契约变更：零。** 新构件 = 一个 `Node2D` + 一个导出项，不发信号、不进 `run_state`、零碰撞体、不进 `anchorable` 族，玩家与机关链一字未改。**摆了一台样品在 `level_template.tscn` 的场景根上**（与那只世界钟同一族、都不进 `Objects`）—— ① 纯装饰族的"每族一个样品"这条从 D65 起就是模板在守，第二件落地的东西跟着走；② `level1.tscn` 是他在改的文件，**一格没动** —— 真要进实机就把模板里那台拖过去，原点 = 盒子中心，与移动方块 / 两件相位器件同一读法。

**开窗实拍（"画到屏幕上到底有没有东西"这件事，无头守门钉不着）**：`tools/ecg_monitor_shot.tscn` 把模板里那台构件（D75 起模板根上挂着它，与那只世界钟同一族）投影到屏幕上裁出来，六个数各自要成立：① 那块矩形里青色像素 = 632 > 0；② 世界在流 → 相隔 30 物理拍两次抓取差 **2376 字节**、相位换了格；③ 世界冻着 → 相隔 30 拍差 **0 字节**、相位钉在同一格；解冻后再抓 → 又开始推。产物 `assets/ui/frames/ecg_monitor_shot.png`（四帧并排）。**破坏性对照**：时基换成 `Time.get_ticks_msec()`（墙上时钟，冻结里照走）→ ③ 那两条当场红（差 2592 字节）、退出码非 0，所以它兼任一条开窗守门。**两条当场踩到的坑**：① 比"两帧一不一样"**不能拿 `save_png_to_buffer()` 比** —— PNG 编码后的长度随内容变，两帧"不一样"先表现为长度不一样，那条 ③ 永远对不上（实测 diff 恒为 -1）；要用 `Image.get_data()` 那串定长原始像素。② 相机跟着的人必须钉住（`set_physics_process(false)`）—— 否则他落地那一路把取景框拖出屏幕，而 `reload_level` 还会把这个一次性节点连带拆掉、整跑第二遍。

**还留给人眼（实机比例，图上看不算）**：① 0.84 s 那一档在真机上读起来是"在跳"还是"在闪"，以及他想要多快（导出项随时调，不用改代码）；② 14 列周期在 1:1 尺寸下能不能看出是一拍而不是随机抖动；③ 它与同一面墙上那只世界钟摆在一起是不是**两条读数而不是两条噪声**（钟说"没人上弦"，波形说"走到一半"）。

**编号**：本节点用掉 **D75**（D33 仍是留空号），**下一个空号 D76**。

---

### D76 · 隐藏洞室用「假墙盖」：盖的是墙自己那块实心格，不透明度只由玩家到洞口的距离决定

**起因（2026-10-28）**：他提「隐藏通道，只有玩家靠近时才会看到里面的路，类似洞穴这一类的」。三条路摆出来：A = 半透明帘子（在洞口叠一层压暗 / 罩色）、B = 用**墙自己的瓦片**做一块假墙贴在洞口、越近越淡、C = 2D 光照（`Light2D` + `Occluder` 把屋里压黑、给玩家一盏小灯）。**他选 B**，并把顺序一起定了：**先实装脚本、出开窗三态实拍给他看，再谈进关卡摆位**。

**A 当场出局（量过，不是口味）**：把路盖成"半暗"盖不住 —— 叠一层 65% 的 `shade` 只把对比度从 **2.62 压到 2.28**，路的轮廓还读得出来；而这条美术线早就判过 **2.63 不足以读暗形体**（g2 那圈边光就是为它加的）。遮挡要接近不透明，而**不透明的假墙**只有一种诚实的做法：用墙自己那块瓦片，让接缝都看不出来。

**C 出局**：全项目 `Light2D` / `CanvasModulate` / `Occluder` 现在是 **0 条**，2D 光照要从零开；而且一块半径 3 格的亮圈在 **315 px（≈20 格）的满跳射程**面前等于没有 —— 玩家跳过去那一瞬什么都看不到，还是只能靠背图。

**B 的第一条硬事实：盖的必须是墙的实心格，不是背景格。** 背景 `WallFill` 刷的是装饰图集里那张 `wall_fill`（`source 0`、atlas **(0, 2)**、关碰撞），而**地形墙**是地形图集里 mask 四边全满那格（`source 0`、atlas **(3, 3)**、带碰撞多边形）。两格在**同一张图集里是两套材质**：逐字节比 **768/1024 格不同**。拿背景格去盖，近看是"墙里嵌了一块颜色不一样的砖" —— 不报错，只在接缝处露馅。所以 `verify_kit` 的逐格核**从 `tiles.json` 里读 mask 全满那格**，不在守门里写死 `(3,3)`：换图集只换坐标、不换这条判据。

**时基：没有时基。** 这一件的全部输入是玩家身体中心到洞口点的距离 —— `alpha_for()` 是**位置纯函数**，同一站位永远同一不透明度，不读时钟、不读帧数、不累加。这不是省事：本作横按方向键即冻世界（D40/D41 那条地基），任何"按世界钟推进"的揭幕都会在**玩家正朝它走的时候**停住 —— 走十步它一格不动，一松手整段跳完。**D59/D75 那条「装饰只读世界钟」在这里反过来：这一件不许读世界钟。** 它也不挂 `TimeReceiver`、不发 `signal`、不认 `run_state`、不进 `anchorable` 族 —— 与 D59/D75 同族的零契约表现件，只是驱动源换成了**看它的人**。物理通道只跑一次读位置 + 写 `modulate.a`（与 D69「物理世界里只有一条状态通道」同口径）。

**三档（导出项，默认 3 格 / 10 格）**：距离 ≤ `reveal_near`(48 px) → 0（全隐，路连同里面的东西一起露出来）；≥ `reveal_far`(160 px) → 1（全挡，与真墙逐格同色）；中间线性。`reveal_far` 刻意比满跳射程（315 px）短，于是"跳过去那一瞬"被子遮住而不是先看见再跳。**站进盖子自己的格子里一律 0**（`reveal_rect().has_point()` 那一条）：只按到洞口的距离算的话，人走进屋里超过 `reveal_far` 那一下会被重新盖住 —— 那是这件东西最容易写错、而且只在"走到最里面"才露馅的一条。`reveal_far <= reveal_near` 时前面的 `d >= reveal_far` 分支先接手，返回 1 而不是 NaN。

**层与碰撞**：`z_index = 1` —— 要压过 z=0 的 `Terrain/Tiles` / 玩家 / 屋里摆的东西（`Decor` 是 −20、`WallFill` 是 −30，都在下面；CRT 滤镜在 `CanvasLayer 100`，仍压在最上面）。`collision_enabled = false`：它画的正是那块**带碰撞多边形**的实心格，忘了关，玩家会撞在自己看不见的空中墙上 —— 这类死法不报错，只活在试玩里。这一手与背景 `WallFill` 相同（那层也是 `source 0` + 关碰撞）。

**摆法**（`scenes/objects/cave_cover/cave_cover.tscn` 出厂是**空层**，格子归作者刷）：① `tile_set` 必须与关卡 `Terrain/Tiles` **同一份**；② 每一格都刷实心格（照墙抠出洞口的那几格逐格复制即可）；③ 洞口点由作者放一个名为 `Mouth` 的 `Marker2D` 决定，没有就退回盖子用格包围盒的中心；它只是距离量的参照点、不是碰撞体，放在"玩家会走过来的那一侧、紧贴墙面"；④ 建议挂 `Terrain` 下、`position` 留 (0,0)，与三层瓦片同一坐标系。刻意**不是 `@tool`**：编辑器里一跑 `_physics_process` 就会把当时的 `modulate.a` 写进 `.tscn`，那份值会在检查器里看起来像"作者调过的透明度"。

**守门（静态 + 合成几何 + 真跑）**：`verify_kit._verify_cave_cover()` 钉五类 —— ① 时基只有位置（源码里出现 `elapsed_world_time` / `TimeReceiver` / `run_state` / `\nsignal ` / `func _process(` 就红，且必须有 `_physics_process`；扫的是 `_code_only()` 剥过注释的文本，D75 那条假绿已收账）；② 层两把开关（场景 z 必须 1、碰撞必须关、出厂必须 0 格）；③ 合成 3×2 一间暗室 + 一个 `Mouth`：包围盒、Mouth 回退、远/近/中间线性、**站在屋里中心也给 0**（那个点离洞口 40 px，不在屋里的算法会给 0.125）、`far <= near` 不许 NaN；④ 逐格核从 `tiles.json` 读实心格，**并当场跑两条对照**：刷对的一层必须没问题、错一格必须报问题、空层必须报问题（否则这条本身就是假绿）。关卡扫描 `_check_cave_covers()` 对每一关扫每个 CaveCover：z ≤ 0、开碰撞、逐格问题、`tile_set` 与 `Terrain/Tiles` 不是同一份 —— 四条各自点名；`VERIFY DONE` 多一列 `covers=`（没有关卡摆过时只记账不设门槛：哪一关需要暗室是摆图的决定）。`kit_selftest` **第 25 组**九条钉行为：开局人就在屋里第一拍全隐、屋外全挡、near/far 正中半透、**世界流着 20 拍不透明度一字不动**、**世界冻着 20 拍不动且钟也真没涨**、洞口跟前全隐、**把洞口挪到 392 px 外、人站在屋里仍全隐**、场上没有玩家时盖回全挡。

**破坏性对照（本轮逐类注入，全部当场红、复原照绿）**：源码里塞 `elapsed_world_time` + `func _process(` + 把 `_physics_process` 改名 → **3 条 FAIL**；场景改 `z=-1`、开碰撞、塞 1 格 → **3 条 FAIL**；`reveal_rect` 的 `used.end - ONE` 改成 `used.end`、中间档返回常数、`far<=near` 分支加个 `and far > near` → **3 条 FAIL**（包围盒 64×48 对 48×32、中间档给 0.000、退化档给 0.25）；往 `level_template.tscn` 临时塞一个 `z=-5` + 开碰撞 + 没挂 `tile_set` 的假墙盖 → **4 条 FAIL / `covers=1`**（随后模板逐字节复原）；给构件的 `_physics_process` 加一项 `elapsed_world_time × 0.1`、并删掉"站进屋里给 0"那条 → **第 25 组同时红 6 条**（开局、中间档、流动 20 拍、冻结 20 拍、洞口跟前、屋里 392 px 那一条）。

**开窗实拍（"盖上去到底看不看得出接缝"只有像素能回答）**：`tools/cave_cover_shot.tscn` 在模板里自建一面 12×6 的墙、中间抠 4×3 的洞当暗室、洞上盖 `CaveCover`、屋里放一块洋红当"里面的路"，并把模板 `Terrain/WallFill` 那格（`source 0`、atlas (0,2)）在**整面墙背后**再铺一层 —— 暗室是真的开在墙里的，近态看见的是墙背后的底而不是虚空（第一版没铺这层，近态像开进天空）。相机靠 `Camera2D.offset` 平移取景、人钉住不动。五条像素事实：① 远态盖子那块与同一面墙的参照块**逐字节相同（差 0）**，把盖子整体挪 1 px 后必须裂开（实测 **1908 字节**，挪回来后 0 —— 证明这条判据不是"比了两块一样的东西"）；② 远态屋里洋红 0 像素；③ 近态洋红 4096 像素且整块与参照块不同（27360）；④ 中间档 alpha 0.500、与墙不同、且**没有一格是纯洋红**（是混合不是硬切）；⑤ 同一站位、世界流着 30 拍（钟 1.983 → 2.483 s）两次抓取**逐字节相同、alpha 一字不动**。产物 `assets/ui/frames/cave_cover_shot.png`（远/中/近三段横排）；退出码 = 有没有 FAIL，所以它兼任一条开窗守门。

**三条当场踩到的坑**：① **相机的 `offset` 是夹完限位才加的**，用"目标 − 相机坐标"反推会把整块取景算歪（模板左边界附近实测偏 188 px）；正解是按"当前屏幕中心在世界里的位置"（`get_viewport().get_canvas_transform().affine_inverse() * 视口中心`）反推差值再加到 `offset` 上。② **`set_physics_process(false)` 在 `add_child` 之前调，进树那一刻会被重新登记掉**（实测 `phys=true`，人当场往下掉，alpha 从 0.5 漂到 0.88）—— 必须在进树之后调；这条与 D75 那条"相机跟着的人要钉住"是同一套做法。③ 相机跟着的人必须钉住、精灵也要暂停，否则落地那一路把取景框拖出屏幕。

**契约变更：零。** 新构件 = 一个 `TileMapLayer` + 两个导出项；不发信号、不进 `run_state`、零碰撞、不进 `anchorable` 族、玩家与机关链一字未改。**这一轮一个关卡都没摆**（`level_template.tscn` 与他的 `level1.tscn` 都零改动）；暗室摆在哪、开几间，是摆图的事 —— 按他定的顺序，先看这张三态实拍、再谈进关卡。

**留给人眼的三条**：① 3 格 / 10 格这一档在实机上读起来是"走近才看见"还是"突然出现"（两个数都是导出项，随时调）；② 中间那一档的混合在 CRT 滤镜下会不会露出双层纹理的摩尔纹（无头守门只看得到 alpha 与像素差，看不出"好不好看"）；③ 洞口点该放在玩家走过来的哪一侧、离墙面多近 —— 它决定揭幕是"迎面打开"还是"从侧面滑开"。

> **订正（2026-10-28，他报「同时绘制多个 Cover 地块时出现提前消失」）**：**根因**不是阈值，是三个"只有一个"叠在一起 —— 一块 `TileMapLayer` 只有**一个节点级 `modulate`**、`reveal_rect()` 取的是**全部格子的外接框**、`mouth_point()` 只认**一个 `Mouth`**。于是同一个节点里刷了两块互不相连的盖子时：人站在两块**之间**（在外接框里、不在任何一块上）→ 整片一起变透明；人靠近 A 的口子 → B 也一起淡掉。**修法**（`cave_cover.gd`）：第一拍之前把根上的格子按 **8 邻接连通块**拆进各自的子层（`Patch1` / `Patch2` …，`tile_set` 沿用根、关碰撞、`z_index` 留 0 相对父级仍是 1），根层清空并把 `modulate.a` 还回 1（拆之前那一拍根上可能已经写过 0，子层会继承父级）；之后**每块自己算自己的 alpha**。8 邻接而不是 4 邻接：刷得不太规整的墙块斜着搭一格仍算"一块墙"，不该在视觉上裂开。"站进自家格子"改成**按这一块的格子**判（`local_to_map` + `get_cell_source_id != -1`），不再是整片外接框。**洞口点**：`Mouth` / `Mouth2` / `Mouth3` … 可放任意多个，每个按"点到哪块矩形的距离最近"归给**一块**（一块拿到多个时取更近的），没分到的块退回它自己的包围盒中心。**兼容**：`alpha_for` / `reveal_rect` / `mouth_point` 多一个 `patch := 0` 参数、老调用一字不用改；没拆（出厂态 / 守门在进树后才刷格的合成 fixture）时 `all_patches()` 返回 `[self]`，单块路径与拆分前逐像素一致。新增三个只读查询：`all_patches()` / `patch_count()` / `current_alpha(patch)`；导出项、信号、`run_state` **零变更**。
>
> **守门**：`verify_kit._cover_cell_problems()` 改成按 `all_patches()` 汇总（运行态的格子已搬进子层、根层是空的，只看根层会把正常盖子判成"一格都没刷"），并新增一条**拆过的正面控制**（进树前刷 2×2、进树即拆 → 先证明真拆了，再证明逐格核扫得到；撒坏退回只看根层 → 当场红「一格都没刷」）。`kit_selftest` 第 25 组原九条改读 `current_alpha()`，新增**十二条多块独立**：拆成 2 块、根层清空且 alpha 回 1、子层不带碰撞、`Mouth`/`Mouth2` 各归各块、**站在两块之间两块都全挡**（老实现这一拍整片全隐）、**站 A 口前只有 A 开而 B 全挡**、站进 B 里 B 隐而 A 挡。**两轮撒坏**：① 不拆 + 退回外接框判里面（复刻老实现）→ 红 5 条；② 两块共用第 0 块的 alpha → 红 2 条（相邻顺带打开、站进 B 里 B 没隐），复原后 `cmp` 逐字节一致。**开窗实拍**改成"同一个节点、两个洞"（墙 16×6、A/B 各 3×3、参照块 3×3，`Mouth` 在 A 左、`Mouth2` 在 B 右，两档 32/64）：四组 × 两块 = 八格里，远态与"两块之间"两块接缝都是 **0 字节**、挪 1 px 两块同时裂 **1476 字节**；A 的中间档 alpha 0.500 且无纯洋红、同拍 **B 仍全挡（接缝 0）**；A 口前 A 洋红 4096 而 B 接缝仍 0；站进 A 里 B 照旧全挡。产物 `assets/ui/frames/cave_cover_shot.png` 已重出。
>
> **这笔红不属于本条（报给他，不代修）**：`verify_kit` 现在有 5 条 FAIL 全在他**未提交**的 `level1.tscn` —— 一条是早先那笔 `Objects_Level1` 位移 (−2.0, 1.0)，另外四条来自他新摆的两个 `CaveCover` / `CaveCover2`：`tile_set` 挂的是**内联的一份 TileSet 副本**（`SubResource`，不是 `lab_tileset.tres` 本身），且各有 12/63、4/33 格刷成了 `atlas (1,3)`（mask 13 的边格）而不是实心格 `(3,3)` —— 这两条都会在接缝处露馅，逐格核点名的第一格都是 (96,62)。

**编号**：本节点用掉 **D76**（D33 仍是留空号），**下一个空号 D77**。

---

### D77 · 开局那拍改成「梦」：四只气泡按破才醒 —— 检验键盘的引导做成有契约面的第三族表现件

**起因（2026-10-29）**：他提「设计一个新手引导，检验玩家键盘是否可以正常操控并告知怎么操控。方式是在玩家第一次复活、播起床动画前先保持睡觉动画，在玩家周围围很多气泡模拟做梦，气泡里是 WASD 和空格，按下对应键气泡消失，全消失后苏醒开始游戏」。

**四条裁定（都是他一句一句定的，全部落进实装）**：① **W 不做** —— `project.godot` 的 `[input]` 里根本没有"向上"这个动作（`move_left` A/←、`move_right` D/→、`move_down` S/↓、`jump` Space/Z/K），按 W 不操控任何东西，教它是教假的；② **不按就不醒**，不做超时也不做自动完成 ——「如果玩家无法按就无法正常游玩」，这一拍的全部意义就是"这四个键有用"；③ 箭头/手柄那几条后备**不实装、不另做设计** —— 因为判定按**动作名**而不是 keycode，后备顺带就算命中（零成本，见下）；④ 触发点**不是"第一次复活"**，而是**现在播苏醒动画的那个开局槽**（`LevelBase._maybe_intro()` 问 `Main.take_intro()` 的那一发）—— 他自己纠正的措辞，但这一改把三样东西一起省掉了：不需要新旗标、不需要 `run_state` 键、不需要 `METHODS` 新项。

**由此转移过来的两条后果（当场报过，他都接受）**：引导在**开始那一帧就被消费掉**（`take_intro()` 取走即消耗），所以演到一半死掉或按 R 重开都**不再重演**；以及开发期每次启动都要按四下才动 —— 于是一把 `F9` 跳键（`DEBUG-KEY` 标记，打包删那一句就整条断开）。

**皮（选型图两轮才定）**：`tools/gen_dream_bubble_preview.py` → `assets/props/preview_dream_bubbles.png`。第一轮六套皮并排，他挑 **F = 暗底白边白字**（`lip` 2 px 描边 + `screen` 填充 + `lip` 字形）。为什么必须是"暗底 + 亮边"两通道而不是挑一个亮色：实测这面墙（`WallFill` atlas (0,2)）亮部均 (165,183,221)、暗部均 (79,91,125)，**没有任何一个在册色能同时对两头达到 D26 那条 4.5**（最高的"双侧"是 `pit_shade` 2.90，而它是阴影 alpha 色不是描边）；E/F 靠两条独立通道过关 —— 暗底 vs 墙上亮格 **8.78**、亮边 vs 暗格 **4.95**、字压在自己的底上 **13.02**。空格那只能写成单词 **`space`**，可读的那一档是 **5×7 小写装进 38×22 胶囊**（3×5 圆形与 4×6 胶囊都被量出来否掉：3 格宽时 `s`/`c`/`e` 是同一个形状）。第一轮还抓到四处只有看图才看得见的自打脸：破的帧沿用了描边色（`glyph is None` 一值两义）、"向下"那只泡埋在实心砖里后来干脆盖住睡脸、十二只装饰泡在图里读成"几只"、空心亮边在墙的亮格上整圈消失（1.48）。**他随后砍掉装饰泡**：「不要有周围多余的气泡，只花四个气泡把主角围住」，并把围法改成**头顶一圈包围弧**。

**摆位 = 弧，不是四向**：半径 **r=56**（他按选型图三档并排挑的那一档：贴着人、贴边重生时零 clamp），角度 **160° / 120° / 60° / 20°** 按阅读序 A → S → space → D（数学惯例逆时针、Godot 的 +y 朝下所以 y 取负）。弧心在睡姿头顶：`arc_origin_y = -5` —— 这条踩了一次，**玩家节点原点是碰撞盒中心不是脚底**（`player.tscn` 的 `CollisionShape2D` 无 offset，`COLLISION_HALF_HEIGHT = 15` ⇒ 脚底在 +15），第一版按脚底写成 −20，整圈泡低了一整个人。

**时基：第三条路，与 D59/D75 那族装饰和 D69 那族器件都不同**。漂移与破的三帧都吃**引擎固定物理步长**（`_physics_process(delta)` 的原生 delta），既不读 `TimeManager.elapsed_world_time` 也不读 `TimeReceiver.get_physics_delta()`。两条理由：① 这一拍整段掐输入 ⇒ `get_axis()` 恒 0 ⇒ 不算"他在移动" ⇒ 世界照常流动，所以走世界钟**数值上没错但语义上错 —— 梦在他脑子里，不归世界钟管**；② 更要紧的是这一拍教的就是"按下去会发生什么"，任何"你按了 A 所以它停了"的读法都会把教学打成 bug —— **D76 那条"照时钟揭幕会在人正朝它走的时候停住"是同一个形状**。

**它不是纯装饰族，也不是器件族**：有 `signal completed` 一根、被 `LevelBase` 连着 ⇒ 有契约面；不挂 `TimeReceiver`、不进 `anchorable`、不认 `run_state` ⇒ 锚点劫持不到它。所以 `verify_kit` 的禁令与 D76 那条反着来：`clock`/`ecg` 是"必须读世界钟"，`cave_cover`/`dream_bubbles` 是"不许读世界钟"，而 `dream_bubbles` 额外**允许**一根 signal（另两件不许）—— 三条禁令各自点名，抄错族就红。

**"醒"仍然只有一条路径**：`Player` 加三只闩 `begin_wake_hold()` / `is_wake_held()` / `release_wake()`，钉住 = `_wake_remaining = INF`（`maxf(0.0, INF - delta)` 恒 INF，所以 D57 那条倒计时链一字未改），掐输入复用同一把 `movement_locked`，不另起第二套掐法；`completed` 一到就 `release_wake()` 回到现成那 2.45 s 窗口。皮那侧在 `PlayerVisual._process` 的 `if not is_playing()` **之前**早退：钉在 `wake` 第 0 帧 + `pause()` —— wake 剪辑**不循环**，任它自己走完就停在"已经醒完"那张脸上，而这一拍要演的恰恰是没醒。**Q（锚点）那只泡撤掉**：`time_anchor.gd` 三道闸读 `source.movement_locked`（120/198/295 行），这一拍它发不出也供不了时 ⇒ 那只泡永远破不了 = 在"不按就不醒"下面直接软锁。

**单一写手（D56/D58 那条老账在皮这一侧）**：`tools/gen_dream_bubble_parts.py` **import** 选型图那个写手 `gen_dream_bubble_preview.bubble_of()` 落 16 张 PNG（4 只 × 4 态）+ `assets/props/dream_bubble.json`；构件**只画纹理、一格像素都不自己算**，几何（半径、四只的角度、弧心偏移、动作映射、零件尺寸）**全部读清单** —— 源码里出现第二份半径/角度/动作名字符串直接 FAIL（那条"断言不许抄第二份数"的对应物）。

**危险物豁免**：`LevelBase._on_hazard_touched()` 里 `_dream != null` 直接 return —— 引导不许演到一半人没了（`take_intro()` 开局那一帧就消费掉，中途死掉 = 新手引导整个丢掉，而症状长得像"引导坏了"不像"我被刺死了"）。

**守门**：`verify_kit._verify_dream_bubbles()` **38 处**判定钉六类（① 时基与契约面禁令，扫 `_code_only()` 剥过注释的文本；② 几何/角度/动作名只许有一份 + 清单五个键；③ 清单 ↔ InputMap ↔ 磁盘 PNG 三方逐条核对（动作改名、少一帧、尺寸与清单不符、出厂态是张白纸、破的三帧不比出厂态稀疏，各自红）；④ 摆位两条硬前提：四只都在弧心以上、每只最近边到弧心 ≥ 玩家碰撞盒半高（值从 `player.gd` 常量读，不抄第二份）；⑤ 接线在关卡根那侧：`begin_wake_hold()`/`release_wake()` 各恰好一处、豁免必须真在 `_on_hazard_touched` 的**函数体**里（新写 `_func_body()`：全文 `contains` 会被 `_on_dream_completed` 里那句同名判断喂绿）、皮那侧钉睡分支必须排在 `if not is_playing()` 之前；⑥ `dev_skip_dream` 必须绑 F9(4194340)、被 `OS.is_debug_build()` 挡着、且 `DEBUG-KEY` 标记就在读它那一行或上一行）+ `VERIFY DONE` 多一列 `dreams=`（下限 4，防扫描空转）+ `SCRIPTS`/`SCENES`/`EXPORTS`（`pop_frame_seconds`/`follow_player`/`dream_intro`）/`METHODS`（三只闩 + `popped_count`）四处登记。`kit_selftest` **第 26 组** **20 条**在真帧上钉：进关当帧就 held + 锁着移动、`completed` 连到编排、**皮是 wake 且钉在第 0 帧、20 拍后仍不播不释放**、按过 A 人仍然零水平速度、一次破一只、重复按不双计、三只破完不发、第四只演完三帧后发**一次**、交回的是现成窗口、节点当拍撤掉、豁免（把刺挪到脚下六拍不判死）+ **对照关**（再开一关、只是没有引导 ⇒ 同样那把刺判死）。

**破坏性对照（30 条静态钉逐条注入，全部当场红、复原照绿）**：塞 `TimeReceiver` / 加 `func _process(` / 改 `_physics_process` 名 / 去掉 `is_debug_build` / 挪走 `DEBUG-KEY` / 抄第二份半径 56 / 抄第二份角度 160 / 写死 `"move_left"` / 清单删一个键 / `states=1` / 三只泡 / 把 S 换成 `move_up` / 换成不存在的动作 / 角度改成不单调 / 角度改到弧心以下 / 半径 20 / 尺寸对不上 / 藏一张 PNG / `z=1` / 塞一个子节点 / `begin_wake_hold()` 调两次 / `release_wake()` 调两次 / 从 `_on_hazard_touched` 里删豁免 / 把 `begin_wake()` 换成 `queue_free()` / 皮分支短路 / 皮分支排到 `is_playing` 之后 / F9 改 F11 / `popped_count` 改名 → **28 条第一轮直接红**，另两条：① "只认 `is_action_just_pressed` 这个串在不在"会被跳键那一发喂绿（第一轮 NOT-FIRED），改成**数发数 ≥ 2** 后两种撒坏都红；② 把皮那分支短路成 `if false and _player.is_wake_held():` 静态**分不出来**（调用点还在），这条改由第 26 组在帧上证 —— 注入后 `kit_selftest` 当场红「钉住 20 拍后仍是第 0 帧、仍没在播」（`playing=true`）。**两条都是"钉的判据与它声称的东西不是一回事"那一类，不是数值问题。**

**开窗实拍**：`tools/dream_bubble_shot.tscn` → `assets/ui/frames/dream_bubble_shot.png`（9 行 × 4 列，列序 = A、S、space、D 就是弧上从左到右；行序 = 底图 / 钉住 / 撒坏 / 还原 / 按下去 / 底图空对照 / 那只演完 / 平移后 / 全破收场）。**六条只有渲染能回答的**：① 上屏 —— 四只各自与"把泡藏掉"的底图差 **6976 / 6976 / 12176 / 6976** 像素（占面板 90% / 90% / 91% / 90%，门槛三成五：只"不同"不够，一条发丝也不同）；⑥ 同源 —— 出厂态那块有 **90.1%** 的像素落在 `a_0.png` 的调色板内（tol 24，色数 3），同一块位置藏掉泡后 **0%**（这条读数在区分，不是恒真）；② 按过 A → A 那块变 **19296 字节**、其余三块 **0 字节**（不误伤）；③ 那三帧演完 → A 回底图 **0 字节**；④ 人平移 40 px → 三只没破的泡在新位置与原来 **0 字节**（世界像素下的跟随，不是屏幕像素）；⑤ 全破 → 等 7 拍节点消失、四块全回底图、皮又在播（`animation=wake playing=true`）。**两条自带对照**：撒坏那一行把 A 从构件 `_items` 里藏掉，① 的读数必须转成 0（否则"差异 ≥ 三成五"可能永远为真）；底图 vs 底图 **0 字节**这条空对照证明"跨时刻逐字节比"在这个 fixture 里成立。**第一轮它红过 4 条**，三条是工具自己的 bug：④ 的取景框没跟着人重算（测的是取景器不是跟随）、⑤ 每按一只就等一次节点消失（四只没按完当然等不到）、③ 残留 192 字节是按下与松开只隔两拍的采样抢跑；改完 `fails=0`。

**踩到的坑（除上面三条）**：① 对照组**不能复用同一把刺** —— `HazardBase._fired` 是本条命一次性闩锁，豁免段已经把它发掉了，再拿它测"能杀"必然假绿；正解是再开一关、只差"没有引导"这一件事（顺带证明豁免与判死是同一入口的两头）。② 事后挂进关卡树的危险物**没人接线** —— `LevelBase` 在 `_ready()` 全子树扫描时才连 `touched_player`，所以"就地新造一把刺挂到玩家身上"这条对照是空转的。③ `Color.r8/g8/b8/a8` 是**属性不是方法**；`Rect2i` 没有 `expand_to()`（只有 `expand()` 返回新矩形）。

**契约变更**：`Player` 三只闩（`begin_wake_hold` / `is_wake_held` / `release_wake`）、`LevelBase` 一个导出项 `dream_intro`（默认 `true`，填 `false` 走现成那条 `begin_wake()`，"这关不做引导"是合法配置）、一根 `DreamBubbles.completed`、一条 InputMap 动作 `dev_skip_dream`（F9，仅 debug 生效）。**`run_state` 零变更**、存档点/祭坛/终点/危险物/器件链一字未改。**关卡一个都没摆**（引导由关卡根自动拉起，作者不需要摆任何东西；`level_template.tscn` 与他的 `level1.tscn` 都零改动）。

**留给人眼的三条**：① 钉住那一拍在实机上读起来是"教我"还是"卡住我"（四下按完才动，`pop_frame_seconds` 与是否加呼吸漂移都是导出项/清单，随时调）；② r=56 这一档在贴边重生时会不会有一只泡出屏（守门只保证它不压人身）；③ 暗底白边在 CRT 滤镜那一层（`CanvasLayer 100`）下面会不会被扫亮一档 —— 无头守门只看得到像素差，看不出"好不好看"。

**编号**：本节点用掉 **D77**（D33 仍是留空号），**下一个空号 D78**。
