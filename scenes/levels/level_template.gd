extends LevelBase
## 关卡模板。开新关：复制 level_template.tscn 与同名 .gd，改场景根脚本指向，其余照填。
##
## 已经接好的：相机取景框（camera_limits）、玩家出生点（PlayerSpawn）、终点区自动重开。
## 玩法连线优先写在场景里：把按钮拖到门的 `trigger` 上就行，不用来这写代码。
## 只有真需要判断的编排（能力何时开启、终点如何收尾）才留在本脚本，见文末。

const LOG_PREFIX: String = "[level]"

## 玩家在终点停手后隔多久重开本关（秒，真实时间）。填 0 表示不自动重开，自己收尾。
@export var goal_restart_delay: float = 1.5

@onready var _goal: SensorZone = $Triggers/GoalZone

var _handler: MovementInputHandler
var _reached: bool = false
var _wait: float = 0.0


func _ready() -> void:
	super._ready()
	_goal.body_entered.connect(_on_goal_body_entered)
	var player: Player = get_tree().get_first_node_in_group(&"player")
	_handler = player.get_node("MovementInputHandler")
	print(LOG_PREFIX, " level_start limits=%s" % str(camera_limits))


## 两段等待都走 _process 的真实 delta：判的是"玩家什么时候松手"，
## 而玩家豁免时停；用门控 delta 会变成"没松手所以世界停所以计时也停"的死结。
func _process(delta: float) -> void:
	if not _reached or goal_restart_delay <= 0.0:
		return
	if _handler.is_moving:
		return
	_wait += delta
	if _wait >= goal_restart_delay:
		_reached = false
		restart_level()


func _on_goal_body_entered(_body: Node2D) -> void:
	if _reached:
		return
	_reached = true
	print(LOG_PREFIX, " goal_reached world=%.2f" % TimeManager.elapsed_world_time)


## 按钮 / 区域开门：不用写代码。选中 Door → 把场景树里的 ButtonPlate（或 SensorZone）
## 拖到 `Trigger` 属性上。编辑器里会画一条门→触发源的橙色连线，运行时不画。
## 判据是"有没有 pressed_changed(bool) 信号"，所以自定义的触发构件也能接。
## 留空 Trigger = 这扇门归关卡脚本管，自己拿引用调 door.set_open(true/false)。
##
## 需要判断的编排仍然留在本脚本。例：能力开关只有一个入口
## TimeManager.set_ability_enabled(true)，且按 D16 要等玩家停手再开
## （照抄 level_01_tutorial.gd 的 _tick_ability）。
