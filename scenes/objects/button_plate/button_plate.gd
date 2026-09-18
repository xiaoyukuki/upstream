@tool
class_name ButtonPlate
extends Area2D
## 踩踏式按钮。冻结期间玩家离开不松开，直到时间恢复流动的当帧才补发 unpress。
##
## 延迟松开不是逻辑必需 —— 0.08s 解冻缓冲已经覆盖了那个窗口。它是画面自洽必需：
## 按钮弹起、门却还开着，会被读成"门坏了"而不是"时间停了"。
##
## 节点原点 = 面板底边中心（贴地）。触发带由 `sensor_height` 自动生成，
## 带心固定在 -Player.COLLISION_HALF_HEIGHT：Area2D 判的是碰撞盒重叠，
## 而玩家碰撞盒中心在地面以上 15 px，带子跨过那条线才踩得动。摆的时候不用管这个数。
##
## @tool：改 width/sensor_height/press_depth 立刻重画面板与触发带。

signal pressed_changed(pressed: bool)

## 面板宽度，同时也是触发带宽度。
@export var width: float = 64.0:
	set(value):
		width = value
		_rebuild()

## 触发带高度。带心固定在玩家碰撞盒中心那条线上，所以只要 > 0 就一定踩得到；
## 调大是为了让跳着擦过的玩家也能触发，调小是为了精确一点。
@export var sensor_height: float = 24.0:
	set(value):
		sensor_height = value
		_rebuild()

## 面板踩下时下沉的像素数。
@export var press_depth: float = 8.0:
	set(value):
		press_depth = value
		_rebuild()

@export var plate_color: Color = Color(0.85, 0.66, 0.28):
	set(value):
		plate_color = value
		_rebuild()

var is_pressed: bool = false

var _pending_unpress: bool = false

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 用真实 delta：按钮面板是玩家身体的直接反馈，玩家豁免时停。
	var target: float = press_depth if is_pressed else 0.0
	_visual.position.y = lerpf(_visual.position.y, target, 1.0 - exp(-24.0 * delta))


func _physics_process(_delta: float) -> void:
	# 编辑器里 TimeReceiver 不会 _ready()，走它会碰到 TimeManager 的 placeholder 实例。
	if Engine.is_editor_hint():
		return
	if not _pending_unpress:
		return
	if _receiver.is_time_frozen():
		return
	_pending_unpress = false
	_set_pressed(false)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	_pending_unpress = false
	_set_pressed(true)


func _on_body_exited(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	if not is_pressed:
		return
	if _receiver.is_time_frozen():
		_pending_unpress = true
		return
	_set_pressed(false)


func _set_pressed(value: bool) -> void:
	if is_pressed == value:
		return
	is_pressed = value
	pressed_changed.emit(value)


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
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
	var polygon := PackedVector2Array([
		Vector2(-width * 0.5, -16.0),
		Vector2(width * 0.5, -16.0),
		Vector2(width * 0.5, 0.0),
		Vector2(-width * 0.5, 0.0),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	if _visual.color != plate_color:
		_visual.color = plate_color
