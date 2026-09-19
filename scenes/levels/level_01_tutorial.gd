extends LevelBase
## M2 引导关编排。D28 之后祭坛授予能力（D16）与终点区收尾（D18）都已下沉到
## `LevelBase`，本脚本只剩**这一关特有的观测**：按钮踩踏次数、旁路首次抵达、终点完成。
## 全是试玩对照材料，删掉不影响玩法。
##
## 接线用 @export_node_path + 自己解析，不写死 $Objects/xxx：节点改名或挪层级，
## 在检查器里重指即可。

const LOG_PREFIX: String = "[m2]"

## 按钮只用来打读数，不碰门 —— 门开不开写在场景的 Door.trigger 上（D20）。
@export_node_path var button_path: NodePath = ^"Objects/ButtonPlate"
## 旁路打点区：不参与玩法，只用来量"玩家多久发现旁路"（M2 验收项）。
@export_node_path var bypass_path: NodePath = ^"Triggers/BypassZone"

var _button: ButtonPlate
var _bypass: SensorZone

var _plate_presses: int = 0
var _bypass_seen: bool = false
var _goal_logged: bool = false


func _ready() -> void:
	super._ready()
	_button = get_node_or_null(button_path) as ButtonPlate
	if _button != null:
		_button.pressed_changed.connect(_on_plate_pressed_changed)
	_bypass = get_node_or_null(bypass_path) as SensorZone
	if _bypass != null:
		_bypass.body_entered.connect(_on_bypass_body_entered)
	# 基类已经连过终点（负责重开），这里再连一次只为了打日志。
	# 不能把自己的日志方法也叫 _on_goal_body_entered —— GDScript 方法默认虚调用，
	# 同名会覆盖基类的那个，_goal_reached 就永远不会置位，自动重开直接失效。
	var goal: Node = get_node_or_null(goal_path)
	if goal != null:
		goal.body_entered.connect(_log_goal_reached)
	print(LOG_PREFIX, " level_start ability=%s limits=%s" % [
		str(TimeManager.is_ability_enabled), str(camera_limits)])


## 踩上祭坛：基类负责「等停手再开」，这里只补一行日志。
func _begin_ability_sequence() -> void:
	super._begin_ability_sequence()
	print(LOG_PREFIX, " ability_granted world=%.2f" % TimeManager.elapsed_world_time)


func _on_ability_enabled(reason: String, wait: float) -> void:
	print(LOG_PREFIX, " ability_enabled by=%s wait=%.2f" % [reason, wait])


## 阶段一的核心观测量：玩家被门关在外面多少次才去找别的路。
func _on_plate_pressed_changed(pressed: bool) -> void:
	if pressed:
		_plate_presses += 1
	print(LOG_PREFIX, " plate=%s presses=%d world=%.2f" % [
		str(pressed), _plate_presses, TimeManager.elapsed_world_time])


func _on_bypass_body_entered(_body: Node2D) -> void:
	if _bypass_seen:
		return
	_bypass_seen = true
	print(LOG_PREFIX, " bypass_reached presses=%d world=%.2f" % [
		_plate_presses, TimeManager.elapsed_world_time])


func _log_goal_reached(_body: Node2D) -> void:
	if _goal_logged:
		return
	_goal_logged = true
	print(LOG_PREFIX, " goal_reached presses=%d world=%.2f" % [
		_plate_presses, TimeManager.elapsed_world_time])
