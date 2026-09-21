extends LevelBase
## 关卡 1。**没有玩法逻辑** —— 祭坛授予能力（D16）与终点区收尾（D18）都由
## `LevelBase` 承接，按钮开哪扇门写在场景的 `Door.trigger` 上（D20）。
##
## 本脚本只剩一个日志前缀。这就是 D28 想要的效果：开新关复制模板后，
## 只要按约定摆好 `Objects/AbilityAltar` 与 `Triggers/GoalZone`，一行代码都不用写。
## 需要这一关特有的判断时再往这里加。

const LOG_PREFIX: String = "[level1]"


func _ready() -> void:
	super._ready()
	print(LOG_PREFIX, " level_start ability=%s limits=%s" % [
		str(TimeManager.is_ability_enabled), str(camera_limits)])
