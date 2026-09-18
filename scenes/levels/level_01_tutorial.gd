extends LevelBase
## M2 引导关编排：把「按钮→门→旁路→走廊→祭坛→返程」接成一条自己会教的链。
##
## 关卡只做节奏与观测，不碰任何时停实现：构件各自读 TimeReceiver，
## 能力开关只走 TimeManager 的公开入口。日志是给试玩的对照材料，删掉不影响玩法。
## 按钮开哪扇门写在场景里（Door 的 trigger 属性指向 ButtonPlate），关卡不认识门。

const LOG_PREFIX: String = "[m2]"

## D16：踩上祭坛不当帧开启能力。等到玩家停手才开，2.5 s（真实时间）是兜底上限。
const ABILITY_ENABLE_TIMEOUT: float = 2.5
## D18：玩家在终点停手后，留 1.5 s 看门在身后关严，再重开本关。
const GOAL_RESTART_DELAY: float = 1.5

@onready var _button: ButtonPlate = $Objects/ButtonPlate
@onready var _altar: AbilityAltar = $Objects/AbilityAltar
@onready var _goal: SensorZone = $Triggers/GoalZone
@onready var _bypass: SensorZone = $Triggers/BypassZone

var _handler: MovementInputHandler

var _awaiting_ability: bool = false
var _ability_wait: float = 0.0
var _goal_reached: bool = false
var _goal_wait: float = 0.0
var _plate_presses: int = 0
var _bypass_seen: bool = false


func _ready() -> void:
	super._ready()
	_button.pressed_changed.connect(_on_plate_pressed_changed)
	_altar.ability_granted.connect(_begin_ability_sequence)
	_goal.body_entered.connect(_on_goal_body_entered)
	_bypass.body_entered.connect(_on_bypass_body_entered)
	var player: Player = get_tree().get_first_node_in_group(&"player")
	_handler = player.get_node("MovementInputHandler")
	print(LOG_PREFIX, " level_start ability=%s limits=%s" % [
		str(TimeManager.is_ability_enabled), str(camera_limits)
	])


## 两段等待都走 _process 的真实 delta：它们判的是"玩家什么时候松手"，
## 而玩家豁免时停；用门控 delta 会变成"没松手所以世界停所以计时也停"的死结。
func _process(delta: float) -> void:
	_tick_ability(delta)
	_tick_goal(delta)


## D16：静止即启。第一次冻结因此必然是"我按了方向键"造成的，而不是能力生效的既成事实。
func _begin_ability_sequence() -> void:
	print(LOG_PREFIX, " ability_granted world=%.2f" % TimeManager.elapsed_world_time)
	_awaiting_ability = true
	_ability_wait = 0.0


func _tick_ability(delta: float) -> void:
	if not _awaiting_ability:
		return
	_ability_wait += delta
	if _handler.is_moving and _ability_wait < ABILITY_ENABLE_TIMEOUT:
		return
	_awaiting_ability = false
	TimeManager.set_ability_enabled(true)
	var reason: String = "timeout" if _handler.is_moving else "still"
	print(LOG_PREFIX, " ability_enabled by=%s wait=%.2f" % [reason, _ability_wait])


## 门由场景里的 trigger 连线驱动，关卡只留读数：plate=false 的时机能看出按钮的延迟松开。
func _on_plate_pressed_changed(pressed: bool) -> void:
	if pressed:
		_plate_presses += 1
	print(LOG_PREFIX, " plate=%s presses=%d world=%.2f" % [
		str(pressed), _plate_presses, TimeManager.elapsed_world_time
	])


## 阶段一的核心观测量：玩家被门关在外面多少次才去找别的路。
func _on_bypass_body_entered(_body: Node2D) -> void:
	if _bypass_seen:
		return
	_bypass_seen = true
	print(LOG_PREFIX, " bypass_reached presses=%d world=%.2f" % [
		_plate_presses, TimeManager.elapsed_world_time
	])


func _on_goal_body_entered(_body: Node2D) -> void:
	if _goal_reached:
		return
	_goal_reached = true
	print(LOG_PREFIX, " goal_reached presses=%d world=%.2f" % [
		_plate_presses, TimeManager.elapsed_world_time
	])


func _tick_goal(delta: float) -> void:
	if not _goal_reached:
		return
	# 松手之前不计时：0.08 s 缓冲后世界才流动，门才有空在身后关完。
	if _handler.is_moving:
		return
	_goal_wait += delta
	if _goal_wait < GOAL_RESTART_DELAY:
		return
	_goal_reached = false
	restart_level()
