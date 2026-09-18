class_name LevelBase
extends Node2D
## 关卡基类。两件事：把全局时间系统拉回已知状态（风险表「场景切换状态残留」），
## 以及把相机取景框交给关卡（D15）。

## M1 沙盒置 true 以便直接测试时停手感；M2 引导关必须置 false，能力在祭坛处才授予。
@export var start_with_ability: bool = true

## 取景框：position=左上角世界坐标，size=可见范围。留空（size 为 0）则沿用
## player.tscn 里的兜底 limits。相机归关卡管，换关才不会互相穿帮（D15）。
@export var camera_limits: Rect2 = Rect2()

@onready var player_spawn: Marker2D = get_node_or_null("PlayerSpawn")


func _ready() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(start_with_ability)
	_place_player()
	_apply_camera_limits()


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


## 重开本关：沿父链找到 World 根（第一个有 restart_level 方法的祖先）委托它做。
## 刻意不写 `node is Main` —— main.gd 预加载了关卡，关卡脚本继承本类，
## 基类再引 Main 就成了类解析环；晚绑定一次调用的代价可以忽略。
func restart_level() -> void:
	var node: Node = get_parent()
	while node != null and not node.has_method(&"restart_level"):
		node = node.get_parent()
	if node != null:
		node.call(&"restart_level")
