extends LevelBase
## 关卡模板。开新关：复制 level_template.tscn 与同名 .gd，改场景根脚本指向，其余照填。
##
## 本脚本是这份「结构约定」的单一书写者（D65），逐条抄自 level1 的实际摆法：
##
## 1. 地形只有三层瓦片：`Terrain/WallFill`(z −30，关碰撞) → `Terrain/Decor`(z −20，关碰撞)
##    → `Terrain/Tiles`(开碰撞)。灰盒 platform 那块已经删了 —— 地形从第一笔就是瓦片，
##    不再有「先摆盒子后来换成砖」这一道返工。
## 2. `Objects` 下按族开文件夹，文件夹名 == 这一族里被驱动的那件构件场景名
##    （`Spikes` / `PistonBlock` / `Door` / `KeyDoor`）。给「一关要摆好几个」的构件开；
##    摆一个的就别开，多套一层只在拖引用时多绕一步。
## 3. 一关只出现一次的构件直接挂 `Objects`，不套文件夹。这不是洁癖：
##    `LevelBase.altar_path` 的默认值是 `Objects/AbilityAltar`，套了文件夹而忘了改导出项，
##    每关都会静默地没有祭坛。同理终点区固定叫 `Triggers/GoalZone`（`goal_path` 默认值）。
## 4. 触发源与它驱动的那件同文件夹，接线因此永远是一跳 `../ButtonPlate`。
##    一列按钮指多台活塞也算这一条（D60），照抄 `Objects/PistonBlock`。
## 5. 零契约的纯装饰挂在场景根下（`WorldClock`），不进 `Objects`：它既不受关卡管，
##    也不该在摆图的人数构件时混进来。
## 6. 分组容器用 `type="Node"`（不是 Node2D）—— 裸 Node 没有 position，位移这条错误
##    在类型上就不成立。根容器 `Terrain`/`Objects`/`Triggers` 是 Node2D，必须停在 (0,0)，
##    verify_kit 对全部关卡钉这一条。
##
## 模板里的构件是**接线样品**：它们排成一行、压在或悬在各自的约定原点上，好让人一眼看清
## 每族怎么接。它们不是合法摆位 —— 复制完就把每一族挪到自己关卡该在的地方，
## 或者照样品再复制出若干实例。危险物、存档点、彩蛋收集物都不用接线，摆进树即生效
## （按契约信号全子树扫描，D31 / D51 / D54）；D28 之后这三件事也不用写代码：
## 祭坛授予能力（D16）→ 摆一个 `Objects/AbilityAltar`；终点区收尾（D18）→ 摆一个
## `Triggers/GoalZone`；按钮开哪扇门 → 把按钮拖到门的 `trigger` 上（D20）。
## 节点挪了位置或改了名，在检查器里改 `altar_path` / `goal_path`，别回来改代码。
##
## 本脚本因此只剩日志。只有这一关特有的判断才写在这里（需要时照抄
## level_01_tutorial.gd 的观测打点）。

const LOG_PREFIX: String = "[level]"


func _ready() -> void:
	super._ready()
	print(LOG_PREFIX, " level_start ability=%s limits=%s" % [
		str(TimeManager.is_ability_enabled), str(camera_limits)])
