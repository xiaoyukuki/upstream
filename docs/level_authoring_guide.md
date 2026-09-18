# 关卡搭建手册（瓦片地形 + 灰盒构件）

面向"我来摆图"的工作流。读完这一页就能开新关，不需要再翻 `m2_level_01_layout.md`。
所有数值都是**实测**常数，不是估的。

---

## 0. 开一关的最短路径

1. 复制 `scenes/levels/level_template.tscn` → 改名 `level_02_xxx.tscn`；复制 `level_template.gd` → 同名。
2. 场景根选中 → 脚本指向新的 `.gd`。
3. 地形两条路：在 `Terrain/Tiles` 层**刷瓦片**（新关推荐，见 §12），或在 `Terrain` 下摆 `platform.tscn` 实例（旧关与快速原型仍可用，两者同在地形碰撞层）。`Terrain/WallFill` 与 `Terrain/Decor` 两层刷背景贴面与装饰，都无碰撞。
4. 在 `Objects` 下摆构件（门/按钮/钟摆/移动方块/祭坛/触发区）。
5. 配接线：把按钮拖到门的 `trigger` 属性上（模板里那扇示例门已经接好了，改指向即可）。摆图期间**不需要写关卡脚本**；只有场景表达不出来的逻辑（比如门由开关组合控制）才回到 `.gd` 里写，并把那扇门的 `trigger` 留空。
6. 填根节点的 `camera_limits`。
7. 跑：`main.tscn` 的根节点上把 `level_scene` 指过来（保留灰滤镜与调试面板），或直接 F5。

模板自带一块 1280×32 的地面、两面侧墙、玩家、`PlayerSpawn` 和一个终点 `GoalZone`（踩到 → 停手 1.5 s → 自动重开）。

---

## 1. 坐标系：只有两条要记

- **y 轴向下为正**，所以"往上跳"是 y 变小。地面线用 `y = 0`，往上的平台写负值（`-128` 表示地面以上 4 格）。
- **网格 32 px**。地形尺寸填 32 的整数倍，位置也尽量落在格线上，相机与高低差才不会被半个格子毁掉。瓦片本身是 16 px，但**设计网格仍是 32 px = 2 格**：本节与 §8 的所有约束照旧，32 的边界落在偶数格线上。

## 2. 原点约定（摆错就是穿模或悬空，这一张表最要紧）

| 构件 | 节点原点在哪 | 生成方向 |
|---|---|---|
| `platform.tscn` | **左上角** | 向右下生长 |
| `door.tscn` | **门洞底边中心**（贴地） | 向 `-y` 生长 |
| `button_plate.tscn` | **面板底边中心**（贴地） | 向 `-y` 生长 |
| `ability_altar.tscn` | **台座底边中心**（贴地） | 向 `-y` 生长 |
| `sensor_zone.tscn` | **触发区底边中心** | 带心由 `band_centre_y` 决定（默认在原点上方 15 px） |
| `pendulum.tscn` | **悬挂点** | 摆锤在 `rod_length` 处 |
| `moving_block.tscn` | **方块几何中心 = 行程起点** | 行程终点 = 原点 + `travel_offset` |
| `player.tscn` | **身体中心**（脚底在原点下方 15 px） | — |
| `Tiles` / `Decor` / `WallFill`（TileMapLayer） | **cell (0,0) 的左上角 = 层节点原点** | 向 +x / +y 逐格生长 |

一句话记法：**地形按左上角摆，其余全部按"贴着地面的那一点"摆。** 瓦片层同理按左上角：cell (0,0) 的左上角就是世界 (0,0)，所以地面线 `y = 0` 正好是第 0 行的上边，往上一格是 `y = -16`。

## 3. 触发带为什么以前会坑人

`Area2D` 判的是**玩家碰撞盒**是否重叠，而玩家贴地站着时碰撞盒中心在地面以上 **15 px**（碰撞盒 20×30）。手写 `CollisionShape2D` 贴着地面画，玩家走过去就"没反应"。

现在这个偏移除掉了人肉记忆：`Player.COLLISION_HALF_HEIGHT = 15.0` 是唯一来源，所有传感器的带心默认就是 `-15`。改玩家碰撞盒尺寸时只改这一个常量，构件会跟着重算。

空中触发带（比如要判"玩家跳过了某条高度线"）把 `band_centre_y` 填 `0`，带子就以节点原点对称展开。

## 4. 碰撞层（照抄，别新发明）

| 层 | 号 | 谁在这层 | 谁的 mask 读它 |
|---|---|---|---|
| `terrain` | 1 | Platform、`Tiles` 层（TileSet 物理层 0） | Player |
| `player` | 2 | Player | Door、MovingBlock、所有传感器 |
| `time_solid` | 4 | Door、MovingBlock | Player |
| `sensor` | 8 | 所有 Area2D | —（`monitorable = false`，纯观察者） |

Player `mask = 5`（terrain + time_solid）。传感器一律 `layer = 8, mask = 2, monitorable = false`。

## 5. 构件速查

| 构件 | 关键导出项 | 对外信号 | 摆的时候注意 |
|---|---|---|---|
| `platform.tscn` | `size`、`color` | — | 尺寸改了碰撞体自动跟上 |
| `door.tscn` | `height`（门洞净高）、`width`、`open_time`、`trigger`、`panel_color` | `open_changed` | 卷帘式：顶边固定、底边上升。`height ≥ 40` 才过得了人。**`trigger` 里填谁，这扇门就被谁开**：点属性右侧的文件夹按钮选，或从场景树直接拖一个带 `pressed_changed(bool)` 的节点进来（按钮、触发区都行）。留空 = 归关卡脚本用 `set_open(bool)` 驱动。编辑器里会从门底画一条橙色线连到触发源，运行时不画 |
| `button_plate.tscn` | `width`、`sensor_height`、`press_depth`、`plate_color` | `pressed_changed(bool)` | 冻结期间玩家走开**不会**松开，解冻当帧才弹起（画面自洽） |
| `pendulum.gd` | `amplitude_degrees`、`period`、`phase`、`rod_length`、两个颜色 | — | **无碰撞体**，纯演示。`phase` 单位是周期不是角度 |
| `moving_block.tscn` | `travel_offset`、`block_size`、`travel_speed`、`block_color` | — | 行程是 `anchor ↔ anchor+offset` 的 pingpong；`layer = 4`，玩家能站上去 |
| `ability_altar.tscn` | `width`、`altar_height`、`sensor_height`、`active_color`、`spent_color` | `ability_granted` | **只发信号，不开能力**。开启时机归关卡（见 §6） |
| `sensor_zone.tscn` | `width`、`height`、`band_centre_y`、`zone_color`、`visible_in_game` | `pressed_changed(bool)`、`body_entered` / `body_exited` | 终点区、旁路打点、剧情触发都用它；也能直接填进门的 `trigger`（"走进这块区域门就开"不用写代码）。和按钮相反：玩家走开**立刻**发 false，不做延迟松开。辅助多边形默认只在编辑器可见 |

编辑器里改这些导出项，门扇/摆杆/面板/触发带会**立刻重画**（全部构件都是 `@tool`）。移动方块在编辑器里不跑位移，只画行程线、两端圆点和终点轮廓；钟摆只画到 `phase` 对应的那一帧加一条扫掠弧。

## 6. 关卡脚本能碰什么、不能碰什么

- **玩法连线优先写在场景里**（D20）：按钮开哪扇门 = 把按钮拖到门的 `trigger` 上，不用来关卡脚本写。编辑器里门会画一条橙线连到触发源，没接线的门就是光秃秃的。关卡脚本只负责"这扇门由别的条件管"这类场景里表达不出来的逻辑 —— 那种时候把 `trigger` 留空，脚本来调 `set_open()`。
- 可以：构件信号、`TimeManager.set_ability_enabled(bool)`、`TimeManager.reset_state()`、`TimeManager.elapsed_world_time`、`LevelBase.restart_level()`。
- 不可以：直接改构件内部、用 `Engine.time_scale`、绕过 `TimeReceiver` 自己计时。构件的 `_process/_physics_process` 一律读 `TimeReceiver.get_physics_delta()`，冻结时那个值是 0。
- **D16 静止即启**：踩上祭坛不要当帧 `set_ability_enabled(true)`，要等玩家松手（或 2.5 s 兜底）。抄 `level_01_tutorial.gd` 的 `_tick_ability`。这条保证玩家第一次冻结一定是"我按了方向键"造成的。
- 关卡自己的等待/节奏计时用 `_process` 的真实 delta，不要用门控 delta —— 否则"没松手 → 世界停 → 计时也停"是个死结。

## 7. `camera_limits` 怎么填

视口 1280×720 @ zoom 2 → **一屏可见世界 640 × 360 px**。

`camera_limits = Rect2(左上角 x, 左上角 y, 宽, 高)`，且 **宽 ≥ 640、高 ≥ 360**，否则相机在里面顶来顶去。
留空（`size` 为 0）= 沿用 `player.tscn` 里的兜底 limits。

例：世界 x ∈ [-96, 1984]、y ∈ [-416, 96] → `Rect2(-96, -416, 2080, 512)`。
经验：左右各比世界边界多留 96 px，底部比地面线多留 32~96 px（掉下来时不至于看到世界外）。

## 8. 摆图前先记住的玩家能力边界

| 量 | 值 |
|---|---|
| 地面跑速 | 260 px/s |
| 起跳峰值高度 | **136 px** |
| 起跳→回同层滞空 | 1.20 s |
| 同层最大水平跳距 | 294 px（极限，别拿它设计） |
| 玩家碰撞盒 | 20 × 30 px |
| 玩家美术轮廓 | 32 × 25 px（史莱姆序列帧，底边是波浪不是直线，脚底贴碰撞盒底边；拍扁帧最宽 34） |

四条硬约束：

1. **台阶高差 ≤ 32 px** —— 再高就不像"顺路"，像"考验"。
2. **水平缺口 ≤ 160 px** —— 极限 294，但引导期不该考跳距。
3. **坑深 ≤ 96 px** —— 玩家豁免时停，冻结中仍受重力；掉进跳不出来的坑 = 死局（96 ≤ 136 ✓）。
4. **可通行缝隙 ≥ 40 px** —— 30 px 身高 + 10 px 余量。门洞、门半开时下方的缝都按这条卡。

美术比碰撞盒**宽 12 px**（左右各 6）且**矮 5 px**。宽是故意的：40 px 的缝看上去比实际更紧，玩家会以为过不去而实际过得去。矮那 5 px 是「扁」造型的代价 —— 盒顶会露在美术之外，但第一章最小可通行开口 40 px，这 5 px 在任何真实通道里都碰不到。摆窄缝时按**视觉**留余量，别按 20 px 的碰撞盒算；跑动与压扁帧最宽到 34 px，40 px 的门洞在动起来只剩 3 px 余量。

门的时间账：`open_time = 0.5` + 解冻缓冲 `0.08` → 松手后 **0.58 s 关严**。想让玩家"来不及"，只要让"跑过去的时间 > 0.58 s"，即按钮到门 **> 151 px**；引导关用了 432 px（1.66 s）。
门落下来压到站在门洞里的玩家时会**停在他的头顶**（D21），不把他横弹出去，人一走开就续收到关严。摆图侧两条推论：一是玩家可以拿头顶住门，这条不打算禁；二是被顶住时留下的缝约 30 px，小于上面第 4 条的 40 px —— 不冲突，因为他离开那条缝的过程必然在移动、时间必然冻着。

## 9. 跑起来与看日志

| 怎么跑 | 结果 |
|---|---|
| F5 | 跑 `main.tscn` → 装载 `INITIAL_LEVEL`（引导关）。有灰滤镜与调试面板 |
| 选中 Main 根 → `level_scene` 指向你的关 | F5 跑你的关，overlay 齐全。**推荐** |
| F6 | 只跑当前打开的场景，绕过 Main → 没有灰滤镜、没有调试面板、按 R 重开无效。适合快速验几何 |

日志：`C:\Users\28401\AppData\Roaming\Godot\app_userdata\upstream\logs\godot.log`（每次启动覆写，上一份归档成带时间戳的同名文件）。
关卡前缀 `[m2]` / `[level]`，字段含义：`plate=true presses=3 world=12.4` 里 `world` 是**世界时间**（冻结期间不走），正是"玩家花了多久"的度量。

## 10. 四条回归命令（改构件、改帧或改图集后跑一下，各 2 秒）

```
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream --script res://tools/verify_kit.gd
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream res://tools/kit_selftest.tscn
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream res://tools/sprite_selftest.tscn
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream res://tools/tileset_selftest.tscn
```

`verify_kit` 验编译、场景可实例化、导出项齐、`@tool` 在位、派生几何（带心 −15、两扇门不共用形状资源），以及**引导关与模板里每扇门的 `trigger` 都指向一个真的发 `pressed_changed` 的节点**（漏配、指向空、指错类型都会 FAIL）。
`kit_selftest` 验冻结语义没被改坏：门在冻结期开度一字不动、解冻后续走、全开时碰撞体收零、移动方块始终留在行程内；外加接线那一条 —— 按下即开、冻结中松开只记意图不位移、换 `trigger` 后旧按钮立即失效、`SensorZone` 当触发源也一样。
`sprite_selftest` 验主角动画：帧资源与 `clips.json` 一致、脚底贴碰撞盒底边、idle/run/jump/fall/land 按真实物理状态切换、**世界冻结时玩家动画照常推进**、按住下键的压扁剪辑是纯表现（不冻结世界、不产生位移、腾空不播）、底边波浪不越过脚底基线行。
`tileset_selftest` 验瓦片：16 张地形 tile 各带**且仅带**一块整格碰撞多边形、64 条 peering bit 与清单一致、装饰 tile 零碰撞且 alpha 非空、模板三层 z 序与共用 TileSet、以及「踏面暗线落在碰撞边 4 px 内」的美术-碰撞契约 —— 这条量的是图集像素而不是调色板常量，换配色照样成立。
四条都打印 `failures=0` 才算过。

## 11. 已知坑

- **改过带 `class_name` 的脚本之后要重启编辑器。** 运行中的编辑器不会刷新 `class_name` 缓存（`scan()` / `reload()` 都不管用），依赖它的场景会报"标识符找不到"，而且这时候保存场景可能把新增的导出项写丢。游戏进程不受影响。
- 保存场景时，`@tool` 运行期生成的 `CollisionShape2D` 会被烘进 `.tscn` 成为 sub_resource。**无害** —— 装载时构件按导出项重算，导出项才是唯一真相。
- 关卡场景里**必须**有 `Player`（在 `player` 组）与 `PlayerSpawn`，否则 `LevelBase` 拿不到相机、玩家停在场景里的编辑期位置。
- 一个关卡只放一个 `AbilityAltar`：它是一次性的，第二次踩不发信号。
- 钟摆没有碰撞体，别指望它挡路；要挡路用 `MovingBlock` 或地形。
- **TileMapLayer 没有 `collision_layer` / `collision_mask` 节点属性（4.6 实测）**。碰撞层写在 TileSet 的物理层上（`lab_tileset.tres` 物理层 0 = layer 1 / mask 0），节点上只有 `collision_enabled` 能整层关。所以「哪层有碰撞」由「哪个源带碰撞多边形」决定：只有地形源带。
- **装饰刷在地形格上会消失**：`Decor` 的 z 在 `Tiles` 下面。要贴在地形表面的东西（警示条之类）刷在紧邻的**空格子**里，别叠在地形格上。
- **"指向另一个节点"的导出项必须用 `@export_node_path`，不能用 `export(Node)`。** 实测 4.6：`.tscn` 里给 `Node` 类型的槽写 `trigger = NodePath("../ButtonPlate")`，游戏进程 `instantiate()` 之后读回来是 `null`（`get("trigger")` 的 `typeof` 是 19 = NodePath，引用根本没被还原成节点）；而 `^NodePath(...)` 这种写法不是合法的文本语法，场景直接实例化失败。所以构件侧一律存 `NodePath`，**进树之后**再用 `get_node_or_null()` 解析 —— 相对路径在树外解析不了。以后再加同类槽位（比如"这个开关控制哪个机关"）照这条来，别再试 `export(Node)`。

## 12. 瓦片地形（新关推荐）

模板 `Terrain` 下有三层 `TileMapLayer`，共用 `assets/tiles/lab_tileset.tres`：

| 层 | z | 碰撞 | 刷什么 |
|---|---|---|---|
| `WallFill` | -30 | 无 | `wall_fill` 一格瓷面，铺满所有空格子（背景墙） |
| `Decor` | -20 | 无 | 装饰大图（窗 6×4 格、灯 6×1 格、柜子 4×3 格……）与坑道 `shade` |
| `Tiles` | 0 | 有（TileSet 物理层 0） | 地形，terrain set 名 `solid` |

- 地形用 **terrain 笔刷**（不是单格笔刷）刷 `solid`：踏面 / 竖面 / 底面按邻居自动出，角部自动包边。碰撞永远是整格矩形，美术亮边只是画，不用为它对位。
- **坑**：坑的格子不刷地形；`WallFill` 照常铺满，再在 `Decor` 层给坑的格子刷 `shade`（半透明压暗）—— 坑读作「比地面暗一档的洞」。坑底那格刷地形，踏面自动出。
- **最小可通行缝隙在瓦片世界 = 48 px（3 格）**：16 的格刷不出 40，§8 第 4 条按 48 执行。其余 §8 约束（台阶 ≤32、缺口 ≤160、坑深 ≤96）不变。
- 悬空平台刷一行格子即可：上下左右四面会自动收边（踏面 + 底面 + 两端竖面）。
- 改图集的管线（一般用不到，改风格才碰）：`py tools/gen_tiles.py` → `--import` → `--script res://tools/build_tileset.gd` → `tileset_selftest`。预览图 `assets/tiles/preview_room_ab.png` 是从图集逐格拼的，和引擎同一条合成路径，所见即所得。
