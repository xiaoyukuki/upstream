class_name LevelBase
extends Node2D
## 关卡基类（D28）。三件事：
##
## 1. 把全局时间系统拉回已知状态（风险表「场景切换状态残留」）；
## 2. 把相机取景框交给关卡（D15）；
## 3. 承接两块**所有关卡都一样**的编排：祭坛授予能力（D16 静止即启）与终点区收尾（D18）。
##
## 第 3 条原来每关抄一遍：`level_01_tutorial.gd` 与 `level_template.gd` 各一份，实现还不一致
## （引导关写死 const、模板用导出项）。现在下沉到基类，新关只要按模板约定摆好
## `Objects/AbilityAltar` 与 `Triggers/GoalZone` 就自动生效，零代码。
##
## 接线一律走 NodePath，不写死 `$Objects/xxx` —— 与 D20 给门定下的规矩一致：
## 节点改名或挪层级，在检查器里重指即可，不用回来改脚本。路径解析不到就静默跳过，
## 这样「本关没有祭坛」是一个合法配置而不是报错。

## M1 沙盒置 true 以便直接测试时停手感；M2 引导关必须置 false，能力在祭坛处才授予。
@export var start_with_ability: bool = true

## 取景框：position=左上角世界坐标，size=可见范围。留空（size 为 0）则沿用
## player.tscn 里的兜底 limits。相机归关卡管，换关才不会互相穿帮（D15）。
@export var camera_limits: Rect2 = Rect2()

@export_group("Altar")
## 祭坛路径。留空 = 本关不授予能力（一开局就有能力的纯解谜关）。
## 默认按模板约定找 Objects/AbilityAltar；挪了位置就在检查器里重指。
@export_node_path var altar_path: NodePath = ^"Objects/AbilityAltar"
## D16：踩上祭坛后要等玩家停手才开能力，这个数是兜底上限（秒，真实时间）。
@export var ability_enable_timeout: float = 2.5

@export_group("Goal")
## 终点区路径。留空 = 本关不自动收尾，由关卡脚本自己处理。
@export_node_path var goal_path: NodePath = ^"Triggers/GoalZone"
## 玩家在终点停手后隔多久重开本关（秒，真实时间）。填 0 表示不自动重开，自己收尾。
@export var goal_restart_delay: float = 1.5

@onready var player_spawn: Marker2D = get_node_or_null("PlayerSpawn")

var _handler: MovementInputHandler
var _awaiting_ability: bool = false
var _ability_wait: float = 0.0
var _goal_reached: bool = false
var _goal_wait: float = 0.0


func _ready() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(start_with_ability)
	_place_player()
	_apply_camera_limits()
	_grab_handler()
	_bind_altar()
	_bind_goal()


## 两段等待都走 _process 的真实 delta：它们判的是"玩家什么时候松手"，
## 而玩家豁免时停；用门控 delta 会变成"没松手所以世界停所以计时也停"的死结。
func _process(delta: float) -> void:
	_tick_ability(delta)
	_tick_goal(delta)


## 子节点的 _ready() 先于父节点执行，因此 Player 已把 spawn_point 记成自己的编辑期位置，
## 这里用 PlayerSpawn 标记覆盖掉，保证重生点由关卡布局说了算。
func _place_player() -> void:
	if player_spawn == null:
		return
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	player.global_position = player_spawn.global_position
	player.spawn_point = player_spawn.global_position
	player.velocity = Vector2.ZERO


func _apply_camera_limits() -> void:
	if camera_limits.size == Vector2.ZERO:
		return
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	var camera: Camera2D = player.get_node_or_null("PlayerCamera")
	if camera == null:
		return
	camera.limit_left = int(camera_limits.position.x)
	camera.limit_top = int(camera_limits.position.y)
	camera.limit_right = int(camera_limits.position.x + camera_limits.size.x)
	camera.limit_bottom = int(camera_limits.position.y + camera_limits.size.y)


## 拿玩家的输入处理器：判断「玩家松手了没」要靠它。读 Player 暴露的属性而不是
## get_node("MovementInputHandler") —— 那个字符串曾经在三个关卡脚本里各写一遍。
func _grab_handler() -> void:
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	_handler = player.input_handler


## 祭坛只发 ability_granted，何时真正开能力属于关卡编排（D16），不归构件。
func _bind_altar() -> void:
	var altar: Node = _resolve(altar_path, &"ability_granted", "altar_path")
	if altar == null:
		return
	altar.connect(&"ability_granted", _begin_ability_sequence)


func _bind_goal() -> void:
	var goal: Node = _resolve(goal_path, &"body_entered", "goal_path")
	if goal == null:
		return
	goal.connect(&"body_entered", _on_goal_body_entered)


## 路径为空 / 指向不存在的节点 → 静默跳过（本关没有这个构件是合法配置）；
## 指到了但不发契约信号 → 一次性警告。与 Door.trigger 同一套口径。
func _resolve(path: NodePath, signal_name: StringName, label: String) -> Node:
	if path.is_empty():
		return null
	var target: Node = get_node_or_null(path)
	if target == null:
		return null
	if not target.has_signal(signal_name):
		push_warning("关卡 %s 的 %s（%s）不发 %s，这段编排不会生效"
			% [name, label, str(path), signal_name])
		return null
	return target


## D16：静止即启。第一次冻结因此必然是"我按了方向键"造成的，而不是能力生效的既成事实。
## 子类可以覆写它来挂自己的日志或演出（GDScript 方法默认虚调用）。
func _begin_ability_sequence() -> void:
	_awaiting_ability = true
	_ability_wait = 0.0


func _tick_ability(delta: float) -> void:
	if not _awaiting_ability or _handler == null:
		return
	_ability_wait += delta
	if _handler.is_moving and _ability_wait < ability_enable_timeout:
		return
	_awaiting_ability = false
	TimeManager.set_ability_enabled(true)
	# 子类可覆写以加日志/演出。默认什么都不做。
	_on_ability_enabled("timeout" if _handler.is_moving else "still", _ability_wait)


func _tick_goal(delta: float) -> void:
	if not _goal_reached or goal_restart_delay <= 0.0 or _handler == null:
		return
	# 松手之前不计时：0.08 s 缓冲后世界才流动，门才有空在身后关完。
	if _handler.is_moving:
		return
	_goal_wait += delta
	if _goal_wait < goal_restart_delay:
		return
	_goal_reached = false
	restart_level()


func _on_goal_body_entered(_body: Node2D) -> void:
	if _goal_reached:
		return
	_goal_reached = true


## 钩子：能力真正开启的那一刻。默认什么都不做，留给子类打日志或放演出。
func _on_ability_enabled(_reason: String, _wait: float) -> void:
	pass


## 重开本关：沿父链找到 World 根（第一个有 restart_level 方法的祖先）委托它做。
## 刻意不写 `node is Main` —— main.gd 预加载了关卡，关卡脚本继承本类，
## 基类再引 Main 就成了类解析环；晚绑定一次调用的代价可以忽略。
func restart_level() -> void:
	var node: Node = get_parent()
	while node != null and not node.has_method(&"restart_level"):
		node = node.get_parent()
	if node != null:
		node.call(&"restart_level")
