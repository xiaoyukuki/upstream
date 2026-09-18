@tool
class_name Platform
extends StaticBody2D
## 占位静态地形。原点为左上角，size 取 32px 的整数倍，
## 灰盒期可直接把设计文档里的「5~6 个身位」换算成网格数。
##
## @tool 让检查器里改 size 立即同步碰撞体与多边形，白模阶段摆地形不用运行游戏。

const GRID: int = 32

@export var size: Vector2 = Vector2(GRID * 10, GRID):
	set(value):
		size = value
		_apply()

@export var color: Color = Color(0.32, 0.35, 0.42):
	set(value):
		color = value
		_apply()

@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual


func _ready() -> void:
	_apply()


func _apply() -> void:
	if not is_node_ready():
		return
	# 逐项比对后再写：@tool 下每次装载场景都会跑 _ready()，无条件赋值会把
	# 所有含地形的场景标成「未保存修改」，摆图时反复弹保存提示。
	var current := _collision.shape as RectangleShape2D
	if current == null or current.size != size:
		var shape := RectangleShape2D.new()
		shape.size = size
		_collision.shape = shape
	var center: Vector2 = size * 0.5
	if _collision.position != center:
		_collision.position = center
	var polygon := PackedVector2Array([
		Vector2.ZERO,
		Vector2(size.x, 0.0),
		size,
		Vector2(0.0, size.y),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	if _visual.color != color:
		_visual.color = color
