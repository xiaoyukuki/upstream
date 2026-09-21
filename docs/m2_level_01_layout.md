# M2 · 引导关（level_01_tutorial）设计结构

配套 `architecture_chapter_01.md`。本文只解决一件事：**把「初始房间 → 旁路 → 教学走廊 → 祭坛 → 返程 → 按钮门」落成可执行的几何、构件规格与接线**。

视觉引导（暖光/chevron）按 **B 方案：additive 假光斑**处理，白模阶段只求"方向能看出来"，不投入优化。

---

## 0. 布局用的实测常数

来源：`player.gd` 的导出参数 + `physics/2d/default_gravity=980`，用 1/60 步长数值积分得出（编辑器内算术，非游戏运行实测）。

**2026-09-21 换档（用户裁定）**：`level1.tscn` 里 `Player` 节点的 `jump_velocity` 覆盖成 **−400**；`player.gd` 的默认**仍是 −520**，所以这是一处**逐关覆盖**，引导关 / `m1_sandbox` / `kit_selftest` 未跟着变。下表已按 −400 重算，括号里保留 −520 的旧值：同一条积分在 −520 下逐项复现旧表（136.2 px / 1.20 s / 294 px），故重算可信。

| 量 | 值 | 换算成 32px 格 |
|---|---|---|
| 地面跑速 | 260 px/s | 8.1 格/s |
| 起跳峰值高度 | **82 px**（−520 时 136 px） | 2.55 格（旧 4.26） |
| 起跳→回到同层滞空 | **0.97 s**（−520 时 1.20 s） | — |
| 同层最大水平跳距（从静止起步加速） | **234 px**（−520 时 294 px） | 7.3 格（旧 9.2） |
| 玩家碰撞盒 | 20 × 30 px | 不足 1 格 |
| 摄像机可见区域（1280×720 @ zoom 2） | **640 × 360 px** | 20 × 11.25 格 |

由此得到四条**硬布局约束**，下面所有几何都满足它们：

1. **台阶高差 ≤ 32 px**（4 格留白太宽裕，反而不像路）。
2. **水平缺口 ≤ 160 px（5 格）**。极限 234 px（−520 时 294），但引导关不能考验跳距。
3. **坑深 ≤ 64 px（2 格）**。玩家豁免时停、冻结中仍受重力，所以"跳着跳着松手"会掉坑；坑必须能原地跳出（需 64 ≤ 82 ✓）。**旧上限 96 px 在 −400 下已不成立**（96 > 82）：坑底没有尖刺就不判死，掉进三格坑等于软锁，只能靠按 R 或踩存档点回灌脱身。
4. **可通行缝隙 ≥ 40 px**（玩家 30 px 高 + 10 px 余量）。门洞、门半关时的下方缝隙都按这条卡。

---

## 1. 关卡节拍

```
阶段一 初始房间 · 无能力          阶段二 旁路            阶段三 教学走廊 · 无能力
┌─────────────────────┐         ┌──────────┐          ┌──────────────────────┐
│ 按钮→门开→走过去→门已关 │   3 台阶  │ 门上方地台  │  掉落  │ 钟摆/移动方块正常运动   │
│ 反复 2~5 次，无路可走  │ ───────▶ │ 向右通达  │ ─────▶ │ 唯一去路：继续向右      │
└─────────────────────┘         └──────────┘          └──────────┬───────────┘
                                                                 │
                       阶段四 祭坛                          阶段五 返程 + 按钮门
                    ┌──────────────────────┐              ┌─────────────────────────┐
                    │ 踩上 → ability_granted │   原路返回    │ 踩按钮→门开→持续移动穿过    │
                    │ 静止即启 + 首次冻结     │ ───────────▶ │ 中途停步=门在 0.58s 内关闭 │
                    │ 钟摆/方块在你移动时定住  │              │ 出门 → GOAL             │
                    └──────────────────────┘              └─────────────────────────┘
```

**教学责任分配（每个阶段只教一件事）**

| 阶段 | 玩家学到 | 靠什么教（零文字） |
|---|---|---|
| 一 | 「踩按钮会开门」+「走过去来不及」 | 门在 0.5s 内关闭；按钮中心到门中心 432 px，跑步要 1.66 s，必然来不及 |
| 二 | 「门不是唯一出路」 | 门正上方 32 px 处就是 T7 地台（走廊地面），它的入口是房间右侧一眼可见的三级 32 px 台阶 —— 房间里唯一没被门封住的方向 |
| 三 | 「这个世界有东西在自己动」 | 钟摆、巡逻方块在走，构成阶段五的对照组 |
| 四 | 「我获得了一个能力」+「我动的时候世界会停」 | 能力开启强制在**静止时刻**（见 D16），所以第一次冻结必然是玩家自己主动按下方向键造成的；灰滤镜同帧首次出现 |
| 五 | 「冻结期门会停在当前开度，所以我能穿过」 | 返程无新分支，唯一变化就是"一动就停" |

**关键设计性质（值得记住）**：阶段五的难度**与距离无关，只与停顿有关**。玩家在冻结期可以任意长距离移动而门纹丝不动；唯一失败方式是"松手超过 0.08 s"。所以 432 px 的按钮-门间距不是考验手速，而是保证门关闭过程**在视野内可见**。

---

## 2. 几何布局

坐标系：`(0,0)` = 初始房间地面左上角，地面表面 `y=0`，**向上为负 y**。全部落在 32 px 网格上。地形一律 `collision_layer=1 (terrain)`、`collision_mask=0`。

### 2.1 初始房间 x ∈ [-32, 768]

| id | 名称 | 位置 (x, y) | 尺寸 w×h | 作用 |
|---|---|---|---|---|
| T1 | Floor | (0, 0) | 640×32 | 房间地面 |
| T2 | LeftWall | (-32, -256) | 32×256 | 左墙 |
| T3 | Ceiling | (0, -256) | 480×32 | 天花板，**只铺到 x=480**，右侧留开放（旁路上方） |
| T4 | Step1 | (448, -32) | 32×32 | 台阶，高差 32 |
| T5 | Step2 | (480, -64) | 32×32 | |
| T6 | Step3 | (512, -96) | 32×32 | 从 T6 顶跳 32 px 上 T7 |
| T7 | LintelSlab | (544, -128) | 224×32 | **一石三鸟**：门楣 + 旁路桥 + 走廊地面起点。表面 y=-128，正压在门洞上方 |
| T8 | PorchFloor | (640, 0) | 96×32 | 门后廊，表面 y=0 |
| T9 | PorchEndWall | (736, -96) | 32×96 | 门后死路。T7 底(-96) 到 T8 顶(0) 只有 96 px 隧道 → 出门后**无法回头跳上地台**，单向 |

机关与触发器：

| id | 名称 | 位置 | 备注 |
|---|---|---|---|
| D1 | Door | 门洞 x 608..640，开口 y **-96..0**（96 px 高 = 3 格）。实例 position=(624, 0)＝门洞底边中心 | 位于 T1 右端与 T7 正下方 |
| B1 | ButtonPlate | 实例 position=(192, 0)＝面板底边中心；触发带由构件自动算 → x 160..224、y -27..-3（64×24，带心钉在 -15） | 中心到中心 432 px = 13.5 身位（验收要求 ≥5 身位 ✓） |
| G1 | GoalZone | `sensor_zone.tscn` 实例，position=(688, 0)＝底边中心，`width=96 height=80` → 触发带 x 640..736、y -55..25（**整条门后廊**） | 覆盖整条廊而不是末端 48 px：门后是单向死路，玩家进门后若停在触发区之前，就被自己关在里头且没有任何线索叫他按 R —— "穿过门"这件事本身就等于通关 |
| Bz1 | BypassZone | `sensor_zone.tscn` 实例，position=(704, -144)，`width=128 height=96`、`band_centre_y=0`（空中带，带子以原点对称）→ x 640..768、y -192..-96 | 不参与玩法，只打试玩日志：玩家首次踏上旁路地台 |
| Spawn | PlayerSpawn | (64, -15) | 脚贴地面 |
| Hint1 | 假光斑 | — | **本里程碑不做**。视觉引导按用户指示整体推迟，白模阶段靠几何高低差引路 |

**触发带通用约定（这条是踩过一次才写下来的）**：Area2D 判的是"重叠"，而玩家碰撞盒 20×30 的**中心在地面以上 15 px**（`player.tscn` 里 Body 多边形是 `-15..15`，节点原点是身体中心而不是脚）。所以贴地触发带必须跨过 `表面 y − 15` 这个中心，而不是贴住地面线 —— 按地面线画带子会时灵时不灵。

这条已经从"记住它"降级成构件行为：`Player.COLLISION_HALF_HEIGHT = 15.0` 是唯一来源，`ButtonPlate` / `AbilityAltar` / `SensorZone` 装载时按它把带心写到 `-15`，摆图的人只填宽高。空中带（Bz1）显式把 `band_centre_y` 填 0。细节见 `docs/level_authoring_guide.md`。

俯视示意（纵向不按比例）：

```
y=-256 ╔═══ 天花板 T3 (0..480) ═══════╗
       ║  ● 钟摆(房间外, 见走廊)        ║            ← x>480 上方开放
       ║                              ║
y=-128 ║                     ╔════════╩═════════════  T7 → 走廊地面 (544..768→1792)
y=-96  ║                 ┌S3─┘  ║  ▲门楣            ║
       ║             ┌S2─┘      ║  ║ D1 门          ║  T9 ┃
y=-32  ║         ┌S1─┘          ║  ▓▓▓▓▓▓▓▓▓▓▓  死路 ║  ▓▓▓┃  ← 96px 隧道，出去回不来
y=0    ╚═T2══════╩═══════════════╩══ G1 ══════════╝
       x=-32   160(B1)        448  608 640      736 768
```

### 2.2 教学走廊 x ∈ [768, 1920]，地面表面 y = -128

| id | 名称 | 位置 | 尺寸 | 作用 |
|---|---|---|---|---|
| C1 | CorridorFloorA | (768, -128) | 320×32 | 地面 768..1088 |
| Pt1 | Pit1Floor | (1088, -32) | 96×32 | **坑 1 宽 96 px**，深 96 px |
| C2 | CorridorFloorB | (1184, -128) | 352×32 | 地面 1184..1536 |
| Pt2 | Pit2Floor | (1536, -32) | 128×32 | **坑 2 宽 128 px**，深 96 px |
| C3 | AltarFloor | (1664, -128) | 256×32 | 祭坛间地面 1664..1920 |
| C4 | RightWall | (1920, -384) | 32×256 | 世界右边界 |
| C5 | CorridorCeiling | (544, -352) | 1376×32 | 走廊顶，跨 544..1920。**地面 -128 到顶 -320 = 192 px 净高**，136 px 跳跃不碰顶 ✓ |

两个坑都是 3 格深（96 px），跳出来需要 96 ≤ 136 ✓ **绝不会把玩家困死**。宽度 96 与 128 都远低于 294 px 的极限跳距，也低于 160 px 的布局上限 —— 它们的存在**不是为了考验跳跃**，而是为了制造下面这个必然事件：

> 玩家在坑上空按着方向键飞行 → 中途松手（想停一下看看） → 世界冻结，**但玩家照常下坠** → 掉进坑里。

这是"玩家豁免时停"唯一能被身体记住的一次教学：世界停了，不包括你自己。设计文档 3.8 不引入致死要素，所以坑只花 1 秒时间，代价约等于零。

演示体（**按 D17：全部永不封路**，x 区间已避开两个坑）：

| id | 名称 | 位置 | 规格 | 与地面的净空 |
|---|---|---|---|---|
| Pd1 | Pendulum | 挂点 (896, -256)，杆长 112，振幅 ±50°，周期 2.4 s | 无碰撞体（D7） | 摆锤最低点正好扫到地面，视觉最凶但不碰玩家 |
| Pd2 | Pendulum | 挂点 (1248, -256)，同上，相位偏半周期 | 无碰撞体 | 同上 |
| Mb1 | MovingBlock | 实例 position=(1376, -208)＝**行程起点**（方块几何中心）、`travel_offset=(0,-72)`（打包时把原来的 `path_a`/`path_b` 合成这一项：节点摆在哪就从哪开始走），速度 60 px/s。方块 64×64 → x 1344..1408，在 C2 上方 | CharacterBody2D，`collision_layer=4`（time_solid 位） | **底边最低 -176，离地面 -128 还有 48 px**，玩家（30 px）永远能走过去；顶边最高 -312，距走廊顶 -320 留 8 px —— 行程原本写 -80，那会让方块每个周期都顶到天花板白抖一下 |

### 2.3 祭坛

`AbilityAltar`：Area2D，`collision_layer=8 (sensor)`、`collision_mask=2`、`monitorable=false`。踩上即 `ability_granted` 一次性发信号，随后本体变暗（视觉），**不消失**（消失会被读成"我弄丢了什么"）。

打包时把它的原点从"触发带中心"改成与门/按钮一致的**台座底边中心**：实例 `position=(1808, -128)` 就是 C3 的地面线，台座向上长 56 px。触发带 `width=64 height=64`，带心由构件自动写到 `-15` → 世界 y −175..−111，正好跨过站在 C3 上的玩家碰撞盒中心（−143）；x 仍是 1776..1840，落在 C3 中段。

### 2.4 摄像机 limits（D15）

关卡总跨度 x ∈ [-32, 1952]（含 C4 右墙）、y ∈ [-384, 96]。`player.tscn` 现在硬编码了 `limit_right=2496` 等一组 M1 沙盒用的值，会直接穿帮。

**提案 D15**：`LevelBase` 增加 `@export var camera_limits: Rect2`，`_ready()` 里写入玩家的 `PlayerCamera`；`player.tscn` 里的 limits 降级为"关卡未提供时的兜底"。关卡各自决定自己的取景框，这是 `main.tscn` + `LevelContainer` 换关结构的自然延伸。

本关取值：`Rect2(-96, -416, 2080, 512)`，即 x ∈ [-96, 1984]、y ∈ [-416, 96]。

---

## 3. 新构件规格

全部遵循既有约定：受时停对象挂一个 `TimeReceiver` 子节点、只读 `get_physics_delta()`、不用 `Engine.time_scale`、不用 Tween、不用 `AnimationPlayer.seek()`。

### 3.1 `button_plate.gd` / `.tscn` — `class_name ButtonPlate extends Area2D`

| 项 | 规格 |
|---|---|
| 接口 | `signal pressed_changed(pressed: bool)`、`var is_pressed: bool` |
| 碰撞 | `layer=4 (sensor)`，`monitorable=false`，`monitoring` 层 2 |
| 按下 | `body_entered` 且 body 属 `player` 组 → `is_pressed=true` 并发信号 |
| **冻结期延迟松开** | `body_exited` 时若 `TimeManager.is_time_frozen()` → 只置 `_pending_unpress=true`；每物理帧检查 `_pending_unpress and not frozen` 才补发 `pressed_changed(false)` |
| 视觉 | 踩下时面板下沉 8 px（`_process` 里用**真实 delta** 插值，按钮自身状态属于输入反馈，不参与时停） |

`pending_unpress` 的真实价值不是逻辑正确性（0.08 s 缓冲已经覆盖了），而是**可读性**：冻结期间按钮保持按下状，与门保持开的状态一致；否则会出现"按钮弹起了、门还开着"的矛盾画面。

### 3.2 `door.gd` / `.tscn` — `class_name Door extends StaticBody2D`

| 项 | 规格 |
|---|---|
| 接口 | `set_open(open: bool)`、`var is_open: bool`、`@export_node_path var trigger: NodePath`（D20：把按钮/触发区拖进来，门自己连它的 `pressed_changed`，摆图零代码；留空才归关卡脚本驱动） |
| 行程 | **卷帘式：顶边钉在 y=-96，底边从 0 升到 -96**。开度 `progress ∈ [0,1]`，门扇占 `y -96 .. -96·progress` |
| 时间 | `open_time=0.5 s`，`progress += d / open_time`（d 来自 TimeReceiver）→ 冻结即停在当前开度、恢复即从当前开度续走，连续性是算术性质不靠肉眼判断 |
| 碰撞 | `layer=3 (time_solid)`，玩家 mask=5 已包含 ✓。碰撞体每帧等于**画出来的那截门扇**（`size.y = 96·(1-progress)`），不是整门洞 |
| 不用动画播放器 | 没有 `AnimationPlayer`，也没有 `CollisionShape2D.disabled` 布尔轨道 |

**原方案「门扇向下收入地下 + 动画播到 35% 才关碰撞」被推翻，三条理由，第一条是硬伤**：

1. **向下收的门永远开不出可钻的缝**。门扇下沉，露出的缝在**门洞上方**，而玩家行走线在 y=0：开度 42% 时门扇占 `y -56..40`，正压着玩家的身体。于是"冻结在半路的门"变成"玩家穿过一块实心门板"，而那恰恰是阶段五唯一的教学瞬间。缝必须长在脚下 → 门扇只能向上收。
2. 但**平移上升**的门扇要穿过 T7（走廊地面）：要么在地面开槽（门关着时那是个洞，走旁路的玩家会掉进门洞），要么给足 158 px 净空（门扇底边得高过走廊行走线以上 30 px 才不撞头），那个位置悬在半空、难看。**卷帘式两头都躲开了**：门扇始终留在门洞那一列 x 608..640 内，只在竖直方向变短，永不越界。原方案为遮住下沉门扇引入的 `Backdrop` / `z_index=-10` 层级约定随之作废，本关不再需要背景遮罩节点。
3. 碰撞体贴着画出来的门扇走，"物理上能过"与"看着能过"是同一瞬间，不需要再手算 `disabled` 阈值（35%/42% 那串数字整体作废）：开度 ≥31%（门底高过站姿玩家头顶 30 px）就能走过去，更小则撞上门扇。关门压到站在门下的玩家时**门停在他的头顶**（D21；旧口径"会被水平推出"已作废）。

**为什么不用 AnimationPlayer（实测结论，不是风格偏好）**：`test_cube` 只验证过 `speed_scale=0` 的冻结，"非循环动画播完之后把 `speed_scale` 翻负能否倒放"没验证过，而在编辑器进程里验不了 —— `AnimationPlayer.advance()` 不提交数值轨道（实测：正向推进到 `anim_pos=0.5` 后，被驱动的 `position_y` 仍是 0.0），既不能证实也不能证伪"门收到一半再也打不开"。既然存在一个不依赖任何播放器语义的等价写法，就用它。

### 3.3 `pendulum.gd` / `.tscn` — `class_name Pendulum extends Node2D`

```gdscript
_elapsed += d                                  # d 来自 TimeReceiver，冻结时为 0
angle = amplitude * sin(2π * _elapsed / period + phase_offset)
_rod.rotation = angle
```

**用相位累加而不是 `AnimationPlayer`**（D6 的既定理由）：`_elapsed` 在冻结期完全不走，所以恢复时角度必然从冻结值连续变化 —— "无跳变"是数学性质，不是肉眼判断。无碰撞体。

### 3.4 `moving_block.gd` / `.tscn` — `class_name MovingBlock extends CharacterBody2D`

直接复用 `test_cube.gd` 已跑通的那套：`d <= 0` → `velocity=ZERO` 并 **跳过 `move_and_slide()`**（D7：`move_and_slide()` 不吃自定义 delta）；`d > 0` → `elapsed += d * speed`、`pingpong` 求目标点、`velocity = (target-pos)/d` 限速。与 `test_cube` 的差异只有两点：不驱动子节点旋转、不挂 `AnimationPlayer`。

考虑过让 `test_cube` 与 `moving_block` 合成一个类，但它们职责不同（验证体 vs 关卡构件），且 `test_cube` 完成 M1 使命后可能退役，**先保持两份**。

### 3.5 `ability_altar.gd` / `.tscn` — `class_name AbilityAltar extends Area2D`

`body_entered`（`player` 组）且未触发过 → `ability_granted.emit()` + `_granted = true` + 视觉转暗。不自己碰 `TimeManager`（表格里的职责边界）。

---

## 4. 关卡编排 `level_01_tutorial.gd`

```
extends LevelBase，start_with_ability = false，camera_limits = Rect2(-96,-416,2080,512)

_ready():
  # B1.pressed_changed → D1.set_open 这行已经搬到场景里：D1.trigger = NodePath("../ButtonPlate")（D20）
  A1.ability_granted → _begin_ability_sequence()
  G1.body_entered    → _on_goal_reached()
  B1.pressed_changed → _on_plate_pressed_changed()   # 只打读数，不碰门

_begin_ability_sequence():          # ← D16，本关最需要你拍板的一处
  # 不在踩上祭坛的当帧开启能力。改为：等到玩家停住（或最多 2.5 s）再开。
  # 条件A：_player_is_still()  —— 玩家的 MovementInputHandler.is_moving == false
  # 条件B：2.5 s 超时
  # 先到者 → TimeManager.set_ability_enabled(true)
  # 目的：保证「第一次冻结」一定是玩家自己主动推方向键造成的，而不是能力开启瞬间的既成事实
  # 副产物：这 2.5 s 就是原文要求的「祭坛后强制静止观察窗」，无需锁输入

_on_goal_reached():                 # ← D18
  # 玩家松手 → 0.08 s 后世界自然流动 → 门在身后关严（这段就是终点演出，零额外成本）
  # 记录一次 get_tree().paused = false 的完成日志 → 1.5 s 后 Main.restart_level()
```

**为什么要"静止即启"而不是立刻开启**：如果踩上祭坛的瞬间能力就生效，玩家此时正在向左/向右走，世界会**在他没预期时**突然冻结 —— _first impression 变成"画面卡了一下"。等到静止再开，第一次冻结就是一次干净的因果：**我按了方向 → 世界停了**。

---

## 5. 需要你拍板的 5 条

| # | 决策 | 我的建议 | 不选另一个的代价 |
|---|---|---|---|
| **D15** | 相机 limits 归关卡还是留在 `player.tscn` | 归关卡（`LevelBase.@export camera_limits`） | 留在玩家里 → M4 每加一关都要改玩家场景，且两关共用必然穿帮 |
| **D16** | 能力在"踩祭坛"还是"玩家停住"时开启 | **停住即启 + 2.5 s 超时兜底** | 立刻开 → 第一次冻结是被动发生的，因果不清 |
| **D17** | 走廊的钟摆/方块做不做成障碍 | **不做，全部永不封路**（净空 ≥48 px） | 做成障碍 → 需要"冻结相位"谜题，属 M4；且和按钮门争教学重点，违背"每阶段只教一件事" |
| **D18** | 通关后干什么 | 松手→门在身后关严→1.5 s 后自动重开本关 | 做结算 UI → 违反"全程无文字"；什么都不做 → 玩家卡在死路里不知所措 |
| **D19** | 32×32 单格方块（台阶、墙、门楣共 10+ 个）用内联节点还是建 `platform/block.tscn` | **作废：两者都不做**。`platform.gd` 本来就是 `@tool` + `@export size/color` + 原点左上角，32×32 就是 `size = Vector2(32, 32)` 的一个 `platform.tscn` 实例 | 建 `block.tscn` 只是给 `platform.tscn` 换一个默认尺寸，多一个要维护的场景；而它想避免的"内联要手写 `RectangleShape2D` + `Polygon2D` 子资源"从来就没发生 —— 台阶/墙全部走实例 + 改 `size` |

---

## 6. 交付清单与实施顺序

**新增（14 个文件，全部已落地）**

```
scenes/objects/button_plate/button_plate.gd / .tscn
scenes/objects/door/door.gd / .tscn                    （无 AnimationPlayer，见 3.2）
scenes/objects/pendulum/pendulum.gd / .tscn
scenes/objects/moving_block/moving_block.gd / .tscn
scenes/objects/ability_altar/ability_altar.gd / .tscn
scenes/levels/rooms/initial_room.tscn                  （纯地形，9 块 platform 实例）
scenes/levels/rooms/teaching_corridor.tscn             （纯地形，7 块 platform 实例）
scenes/levels/level_01_tutorial.gd / .tscn
```

D19 作废，未建 `block.tscn`；机关与触发器全部直接摆在关卡场景的 `Objects` / `Triggers` 下，房间场景只装地形 —— 接线看一个文件就够。

**改动（2 个，都不动 M1 已验证的逻辑）**

- `scenes/levels/level_base.gd`：+`camera_limits` 导出与 `_apply_camera_limits()`（D15）。`m1_sandbox.tscn` 未提供该值 → 继续走 `player.tscn` 的兜底 limits，行为不变
- `scenes/levels/main.gd`：`INITIAL_LEVEL` 指向 `level_01_tutorial.tscn`。M1 沙盒仍可通过打开其场景单独运行（F6）保留

灰滤镜（`time_freeze_filter`，ColorRect 版）M1 已交付，D8 的 M2 项天然满足，不需要新代码。

**验证到哪一步了**

你 2026-09-16 实机试玩过整关并确认"机制都没问题"，上面列的未验证项（台阶能否上、坑能否出、卷帘门冻结开度下能否过、D16 静止即启是否读得通）全部结清；编辑器 `class_name` 缓存那个坑随重启消失。

**M2.5 打包轮（此后地图由你摆，构件只负责好用）**

新增：

```
scenes/objects/sensor_zone/sensor_zone.gd / .tscn       通用触发区（底边原点 + 自动带心）
scenes/levels/level_template.gd / .tscn                 开新关的复制源
docs/level_authoring_guide.md                            摆图手册（原点表/层/limits/常数/日志）
tools/verify_kit.gd                                      无头守门：编译 + 场景 + 导出项 + 派生几何
tools/kit_selftest.gd / .tscn                            无头回归：冻结语义没被改坏
```

改动：

- 5 个构件 + `platform.gd` 全部 `@tool`：检查器里改导出项立即重画碰撞体与多边形，摆图不用运行。`_process/_physics_process` 一律 `Engine.is_editor_hint()` 早退（编辑器里 `TimeReceiver` 不 `_ready()`，走它会撞到 `TimeManager` 的 placeholder）。
- 重建函数都改成"值真变了才写"，否则编辑器每次装载场景都被标成未保存修改。
- `AbilityAltar` 原点改成底边中心（与门/按钮同一套）；`MovingBlock` 的 `path_a`/`path_b` 合成 `travel_offset`（`_ready` 里预应用偏移会在编辑器保存后越滚越偏）。
- `Player.COLLISION_HALF_HEIGHT`、`LevelBase.restart_level()`、`Main.level_scene` 三个新入口。
- `level_01_tutorial.tscn`：G1/Bz1 换成 `SensorZone` 实例，祭坛位置按新原点改成 (1808,-128)，`path_b` → `travel_offset`。几何与试玩时一致。

**改构件后跑这两条守门（各 2 秒）**：

```
Godot --headless --path D:/Godot/Ups/upstream --script res://tools/verify_kit.gd
Godot --headless --path D:/Godot/Ups/upstream res://tools/kit_selftest.tscn
```

---

## 7. 验收对照

| 验收项 | 本设计里的落点 |
|---|---|
| 无文字 | 工程内不建任何教程 UI；本里程碑只靠几何高低差引路（假光斑按用户指示推迟到视觉优化轮） |
| 阶段一尝试 2~5 次 | 按钮中心→门中心 432 px，跑步 1.66 s vs 门关闭 0.5 s，必然失败；失败原因是"来不及"而不是"看不懂" |
| 旁路发现 < 60 s | 门楣 T7 就在门正上方、32 px 三级台阶在房间右侧一眼可见；天花板 T3 只铺到 x=480，右侧物理上是开的 |
| 获得能力→通过按钮门 < 90 s | 返程原路无分支；按钮门是唯一出口 |
| 移动=时停 的领悟 | D16 的"静止即启"保证第一次冻结由玩家主动输入触发；灰滤镜与冻结同帧出现（M1 已接好） |
| 门关闭可见 | 0.5 s 行程 + 0.08 s 缓冲 = 松手后 0.58 s 关严；碰撞体始终等于画出来的门扇，开度 ≥31% 就能过，不会夹死 |
| 试玩读数 | 关卡脚本按事件打 `[m2]` 前缀日志：`level_start`（能力初值与取景框）、`plate=true/false presses=N world=T`、`bypass_reached presses=N`、`ability_granted` → `ability_enabled by=still\|timeout wait=S`、`goal_reached presses=N world=T`。阶段一试图次数直接读 `presses`，旁路发现时间读 `bypass_reached` 的 `world`（那是世界时间，冻结不计时）。门不在这里打点：按钮开哪扇门写在场景的 `Door.trigger` 上（D20），关卡不认识门 |
