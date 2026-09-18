@tool
class_name MovingBlock
extends CharacterBody2D
## 往复移动的方块。冻结时 velocity 归零并跳过 `move_and_slide()`。
##
## 与 `test_cube.gd` 的位移通道同源，但职责不同：test_cube 是 M1 的三合一验证体，
## 本脚本是关卡构件（不带旋转与动画）。合成一个类会让验证体失去"退役自由"，先保持两份。
##
## 节点原点 = 方块**几何中心**（也是行程起点），`travel_offset` 是行程终点相对原点的偏移。
## 也就是说摆的时候把方块放在哪里，它就是从哪里开始走；不需要再填一个 path_a。
##
## @tool：编辑器里不跑位移（跑了会把 position 写进场景，下次装载就漂了），
## 改为画出行程线与两端标记 + 方块的矩形轮廓，一眼看清会挡到哪、会露出多高。

@export var travel_offset: Vector2 = Vector2(0.0, -80.0):
	set(value):
		travel_offset = value
		_span = maxf(value.length(), 0.001)
		queue_redraw()

## 方块边长（宽高各向）。64 是一个身位，能站上去。
@export var block_size: Vector2 = Vector2(64, 64):
	set(value):
		block_size = value
		_rebuild()

## 匀速速度（px/s，世界时间）。
@export var travel_speed: float = 60.0

@export var block_color: Color = Color(0.62, 0.66, 0.74):
	set(value):
		block_color = value
		_rebuild()

var elapsed_path_time: float = 0.0
var frozen_frames: int = 0

var _anchor: Vector2
var _span: float = 1.0

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	# 取全局锚点：方块经常放在带偏移的房间节点下，本地坐标配全局坐标算速度会整体偏一个父级偏移。
	_anchor = global_position
	_span = maxf(travel_offset.length(), 0.001)
	_rebuild()


func _physics_process(_delta: float) -> void:
	# 编辑器里 TimeReceiver 不会 _ready()，走它会碰到 TimeManager 的 placeholder 实例。
	if Engine.is_editor_hint():
		return
	var d: float = _receiver.get_physics_delta()
	if d <= 0.0:
		velocity = Vector2.ZERO
		frozen_frames += 1
		return

	elapsed_path_time += d * travel_speed
	var t: float = pingpong(elapsed_path_time / _span, 1.0)
	var target: Vector2 = _anchor + travel_offset * t
	# 被玩家挡住时 target 仍会前进，限速避免脱困瞬间弹射出去。
	velocity = ((target - global_position) / d).limit_length(travel_speed * 2.0)
	move_and_slide()


## 只在编辑器里画：行程线 + 两端圆点 + 方块在起点/终点的轮廓。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var line_color := Color(0.4, 1.0, 0.6, 0.6)
	draw_line(Vector2.ZERO, travel_offset, line_color, 2.0)
	draw_circle(Vector2.ZERO, 5.0, line_color)
	draw_circle(travel_offset, 5.0, line_color)
	var half := block_size * 0.5
	var end_rect := Rect2(travel_offset - half, block_size)
	draw_rect(end_rect, line_color, false, 1.0)


func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != block_size:
		var shape := RectangleShape2D.new()
		shape.size = block_size
		_collision.shape = shape
	var half := block_size * 0.5
	var polygon := PackedVector2Array([
		-half,
		Vector2(half.x, -half.y),
		half,
		Vector2(-half.x, half.y),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	if _visual.color != block_color:
		_visual.color = block_color
	queue_redraw()
