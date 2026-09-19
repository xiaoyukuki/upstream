extends LevelBase
## 关卡模板。开新关：复制 level_template.tscn 与同名 .gd，改场景根脚本指向，其余照填。
##
## D28 之后以下三件事都不用写代码了：
## - 祭坛授予能力（D16 静止即启 + 2.5 s 兜底）→ 摆一个 `Objects/AbilityAltar` 即可；
## - 终点区收尾（D18 停手 → 等待 → 重开）→ 摆一个 `Triggers/GoalZone` 即可；
## - 按钮开哪扇门 → 把按钮拖到门的 `trigger` 上（D20）。
## 节点挪了位置或改了名，在检查器里改 `altar_path` / `goal_path`，别回来改代码。
##
## 本脚本因此只剩日志。只有这一关特有的判断才写在这里（需要时照抄
## level_01_tutorial.gd 的观测打点）。

const LOG_PREFIX: String = "[level]"


func _ready() -> void:
	super._ready()
	print(LOG_PREFIX, " level_start ability=%s limits=%s" % [
		str(TimeManager.is_ability_enabled), str(camera_limits)])
