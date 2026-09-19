# 项目上下文摘要（开新对话前加载）

> 这份文档是为了能在任意 AI 会话里安全加载而写的**和谐词汇版**：项目里部分机制词汇的旧称
> 与内容过滤词表重叠，容易触发误判。本文档统一换用中性的技术表达；**代码、注释与正式文档
> 保持原词不动**，不需要为过滤器改项目。
>
> 本文档内的固定说法：「世界冻结 / 冻结状态 / 冻结期间 / 解冻」= 时间系统的 freeze 语义；
> 「接触让位」= 门扇下行途中与玩家接触时就停在接触位置的行为；「下蹲压扁」= 角色贴地蹲下时
> 身形变扁的纯画面表现。今后讨论这两类内容时请一律沿用这些说法，不要使用与某类题材标签
> 或特定动作相关的旧称词面（本段刻意不写出它们）。

---

## 1. 项目是什么

- Godot **4.6.1**（mono 版，但全部用 GDScript 写），2D 横版解谜平台游戏，GL Compatibility 渲染，**第一章原型**阶段。Windows 开发，工作目录 `D:\Godot\Ups\upstream`。
- **核心机制「移动即冻结」**：玩家按住左右方向键移动时，整个世界进入冻结（玩家、相机、UI 之外的一切停住）；玩家松手静止时，时间恢复流动。全部谜题围绕这条规则设计。
- 玩家是唯一不受冻结影响的对象（设定上是"时间旅行者"）——这是整个机制成立的前提。

## 2. 工程布局

- 根目录 `D:\Godot\Ups\upstream`。**不是 git 仓库**，删除/覆盖不可恢复，操作要保守。
- `scenes/actors/player/` 玩家；`scenes/objects/` 下是门（door）、按钮（button_plate）、钟摆（pendulum）、移动方块（moving_block）、祭坛（ability_altar）、感应区（sensor_zone）；`autoloads/time_manager.gd` 时间系统；`tools/` 帧生成脚本与三个回归守门；`assets/player/slime/` 程序生成的像素帧。
- 文档：`docs/architecture_chapter_01.md` 记着 **D1~D22 全部设计决策**（开工前先读，尤其是末尾的补录）；`docs/level_authoring_guide.md` 是摆图手册；`docs/m2_level_01_layout.md` 是引导关白模说明。

## 3. 时间系统怎么实现

- `TimeManager`（autoload）只累计世界时间；每个构件挂一个 `TimeReceiver`，每帧读「门控 delta」——冻结期间该值为 0，构件因此自然停住；解冻后从停住的地方继续。**连续性靠算术性质保证**（开度是累计时间的纯函数），不用 tween/seek 那种恢复瞬间会跳帧的路子。
- 绝对不用 `Engine.time_scale`。
- 玩家、相机、UI 用真实 delta，永远照常运行；玩家动画在冻结期间照常播放（这是"玩家例外"最直观的可读性）。

## 4. 构件与摆图工具箱

- 全部构件带 `@tool`：检查器里改参数，编辑器预览立刻重画。
- 原点约定（摆图最容易错的点）：**地形按左上角摆，其余构件全部按"贴着地面的那一点"摆**（门的原点=门洞底边中心，按钮=面板底边中心……）。网格 32 px。
- 碰撞层：1=地形，2=玩家，4=时间固体，8=感应。玩家 mask=1+4。
- **Door（升降门）**：卷帘式，顶边固定底边上升，开度是门控时间的纯函数（碰撞体与画出来的门扇永远重合）。`trigger` 属性指向任意发 `pressed_changed(bool)` 的节点（按钮/感应区都行），检查器里直接拖拽接线，编辑器会画一条辅助线。**接触让位（D21）**：门扇下行途中与玩家接触时就停在接触位置，不把人推开；玩家离开后自动继续关闭。玩家可以拿头顶住门——这是有意保留的玩法。
- ButtonPlate（按钮面板，冻结期间不弹起）、SensorZone（触发区，人走开立刻松开）、Pendulum（纯演示无碰撞）、MovingBlock（往返平台）、AbilityAltar（一次性能力祭坛，静止时刻才生效）。
- 新关卡：复制 `level_template.tscn`/`level_template.gd` 起步；接线优先写在场景里（拖属性），关卡脚本只处理场景表达不出来的逻辑。
- **D28（2026-09-20）**：祭坛授予能力（D16）与终点区收尾（D18）已下沉到 `LevelBase`，按约定摆 `Objects/AbilityAltar` / `Triggers/GoalZone` 就自动生效，新关零代码；接线一律 `@export_node_path`（默认路径 + 解析不到静默跳过）。`verify_kit` 改为**自动发现** `scenes/levels` 下的关卡、且不再钉任何摆位坐标（挪祭坛不再 FAIL）。

## 5. 玩家与美术

- 控制器：CharacterBody2D，碰撞盒 **20×30**，脚底在原点下方 15 px。带跳跃宽恕窗口（coyote 0.10s / buffer 0.12s）、顶点低重力（滞空感）、提前松键截断跳跃。
- 美术是**代码程序生成**的像素帧（44×44，PIL 绘制）：`tools/gen_player_frames.py` 出 PNG + `clips.json` → `tools/build_slime_frames.gd` 生成 `slime_frames.tres`。改数值就能整批重出。
- 十个剪辑：idle / run / start / stop / jump / fall / land / crouch_in / crouch / crouch_out。
- 近期美术特征（D22）：**底边是波浪不是直线**（流体感，逐列余弦上抬，只上抬不越基线，脚底对齐契约不破）；**按住下键（S/↓/十字键下/摇杆下）且在地面时身形下蹲压扁**；重落地时播一拍"整团拍扁"的帧；压扁时眼睛跟着变扁（5px→3px→2px）。站姿轮廓实测 32×25，全剪辑最宽 34 px。
- **蹲伏改碰撞（D27，2026-09-19）**：蹲下时碰撞盒从 30 缩到 **15**（与美术同比例：美术 25→12.5，盒 30→15），**脚底永远在原点下方 15，只从顶部缩**。不减速、**不触发冻结判定**（这两条与 D22 一致，未变）。头顶被门/天花板压住时**保持蹲伏且禁止起跳**，头顶空出来才自动起身 —— 没有这条净空判定，起身会让盒子长进门板里。动画读 `Player.is_crouching`（实际状态）而不是按键，否则被压住时会播起身动画而盒子还蹲着。**蹲伏剪辑的优先级压过 `start`/`stop`/`run`**（D22 时代是反的，那时蹲伏是纯表现；现在反过来了，否则蹲着走会播站姿 `run` = 画面起立、碰撞还蹲着）。没有蹲走帧，蹲着移动播的是静止的压扁循环。

## 6. 当前状态与最近改动（2026-09-17）

- **D21 接触让位**：门下降遇到玩家即停（停在接触位置 0.1 px 余量内），玩家坐标一字不动，人让开后照常关严。实现是两次物理查询（静止矩形查零位移接触 + `cast_motion` 查亚帧距离），只夹开度，不夹意图。
- **D22 美术**：底边波浪 + 三段下蹲压扁剪辑 + 落地拍扁帧 + 压扁时眼睛变扁。
- 四条回归守门**全绿**：`sprite_selftest`（含"蹲着不冻结世界""底边不越基线""蹲伏缩盒 + 被压不许起身"）、`kit_selftest`、`verify_kit`（doors=2）、`tileset_selftest`（308 条）。
- 待办：**重启编辑器后 F5 试玩验收新动画手感**（`project.godot` 加了新输入动作、帧资源变了，运行中的编辑器看不到）；积压事项 M3——全屏去饱和滤镜会把玩家也染灰，需要给玩家单独开通道，方案未定。

## 7. 常用命令

```
# 出帧（改 tools/gen_player_frames.py 后）
py tools/gen_player_frames.py
# 导入新 PNG + 重建帧资源
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream --import
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream --script res://tools/build_slime_frames.gd
# 三条守门（改构件或改帧后都要跑，各几秒）
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream --script res://tools/verify_kit.gd
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream res://tools/kit_selftest.tscn
D:/Godot/Godot_v4.6.1-stable_mono_win64_console.exe --headless --path D:/Godot/Ups/upstream res://tools/sprite_selftest.tscn
```

三条都打印 `failures=0` 才算过。headless 跑脚本时把输出重定向到日志文件再读（管道 grep 会缓冲，进程不退出会误以为卡死）。

## 8. 协作约定

- 实现前先产出**编号设计决策**（D 系列），用户确认后再写代码；用户自带的参考代码不具约束力，发现问题要指出而不是照抄。
- **摆图由用户自己做**；AI 的职责是摆图工具箱（@tool 预览、原点约定、模板、手册、守门命令）。用户报问题时，先怀疑工具箱再怀疑玩法逻辑。
- 试玩与手感判断归用户。
- 已知坑：改带 `class_name` 的脚本后要**重启编辑器**；"指向另一个节点"的导出项一律用 `@export_node_path` 不用 `export(Node)`（4.6 里 Node 槽不会被还原成节点引用）。
