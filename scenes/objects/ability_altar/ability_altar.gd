@tool
class_name AbilityAltar
extends Area2D
## 能力祭坛：踩上即一次性发 `ability_granted`，本体变暗但不消失。
##
## 不自己碰 `TimeManager`。发信号是本构件的全部职责，"何时真正开启能力"
## 属于关卡编排（D16 的静止即启），换关卡时不需要改这里。
## 触发后不消失：消失会被读成"我弄丢了什么"。
##
## 节点原点 = 台座底边中心（贴地），与门/按钮同一套约定。
## 触发带由 `width`/`sensor_height` 自动算，带心固定在玩家碰撞盒中心那条线（地面以上 15 px）。
##
## @tool：改尺寸/颜色立刻重画台座与触发带。

signal ability_granted

## 台座宽度，同时也是触发带宽度。
@export var width: float = 64.0:
	set(value):
		width = value
		_rebuild()

## 台座画出来的高度（纯装饰，不参与碰撞）。
@export var altar_height: float = 56.0:
	set(value):
		altar_height = value
		_rebuild()

## 触发带高度。带心固定在 -Player.COLLISION_HALF_HEIGHT，所以只要 > 0 就踩得到。
@export var sensor_height: float = 64.0:
	set(value):
		sensor_height = value
		_rebuild()

@export var active_color: Color = Color(0.98, 0.82, 0.42):
	set(value):
		active_color = value
		_rebuild()

@export var spent_color: Color = Color(0.3, 0.28, 0.24)

var is_granted: bool = false

@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if is_granted or not body.is_in_group(&"player"):
		return
	mark_spent()
	ability_granted.emit()


## 关卡复活回灌用：把祭坛摆成「已授予」的样子但不发信号 —— 信号属于玩家第一次
## 踩上去的演出，重载后的世界里那次演出已经发生过了（D31：run_state 只存
## altar_spent 一个布尔，能力是否开启由它推导，不另记第二份真相）。
func mark_spent() -> void:
	is_granted = true
	_visual.color = spent_color


func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(width, sensor_height):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(width, sensor_height)
		_collision.shape = shape
	var band_center := Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	if _collision.position != band_center:
		_collision.position = band_center
	# 等腰梯形台座：底边贴地，顶面内缩 12 px。
	var polygon := PackedVector2Array([
		Vector2(-width * 0.5, 0.0),
		Vector2(width * 0.5, 0.0),
		Vector2(width * 0.5 - 12.0, -altar_height),
		Vector2(-width * 0.5 + 12.0, -altar_height),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	var target_color: Color = spent_color if is_granted else active_color
	if _visual.color != target_color:
		_visual.color = target_color
