@tool
class_name Pendulum
extends Node2D
## 钟摆：相位累加驱动，冻结期 `_elapsed` 不走，恢复时角度必然从冻结值连续变化。
##
## 刻意不用 AnimationPlayer（D6）：动画方案的"无跳变"要靠肉眼判断，
## 而 sin(累加相位) 的连续性是数学性质 —— 时间变量停了，函数值就不会跳。
## 无碰撞体（D17）：走廊里的演示机关只负责被观察，永不封路。
##
## 节点原点 = 摆的悬挂点（Pivot 底边中点）。摆锤最低点在 rod_length 处，
## 关卡里按「悬挂点离地 ≥ rod_length + 摆锤半径」摆，玩家才不会被摆锤穿过去。
##
## @tool：改 rod_length/amplitude_degrees/phase 立刻重画摆杆与扫掠弧
## （弧线只在编辑器里画，运行时不出现）。

@export var amplitude_degrees: float = 50.0:
	set(value):
		amplitude_degrees = value
		_rebuild()

@export var period: float = 2.4

## 初始相位（周期单位，不是角度）。0 与 0.25 摆出的两把摆不同步。
@export var phase: float = 0.0:
	set(value):
		phase = value
		_rebuild()

@export var rod_length: float = 112.0:
	set(value):
		rod_length = value
		_rebuild()

@export var rod_color: Color = Color(0.55, 0.58, 0.66):
	set(value):
		rod_color = value
		_rebuild()

@export var bob_color: Color = Color(0.72, 0.75, 0.82):
	set(value):
		bob_color = value
		_rebuild()

var _elapsed: float = 0.0

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _rod: Node2D = $Rod
@onready var _rod_visual: Polygon2D = $Rod/RodVisual
@onready var _bob_visual: Polygon2D = $Rod/Bob
@onready var _pivot_visual: Polygon2D = $Pivot


func _ready() -> void:
	_rebuild()


func _physics_process(_delta: float) -> void:
	# 编辑器里 TimeReceiver 不会 _ready()，走它会碰到 TimeManager 的 placeholder 实例。
	if Engine.is_editor_hint():
		return
	var d: float = _receiver.get_physics_delta()
	if d <= 0.0:
		return
	_elapsed += d
	_set_angle()


func _set_angle() -> void:
	var t: float = TAU * (_elapsed / period + phase)
	_rod.rotation = deg_to_rad(amplitude_degrees) * sin(t)


## 只在编辑器里画：摆锤的扫掠弧，用来一眼看出摆能伸到多高多宽。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var radius: float = rod_length
	var center: float = PI * 0.5
	var spread: float = deg_to_rad(amplitude_degrees)
	draw_arc(Vector2.ZERO, radius, center - spread, center + spread, 32,
		Color(1.0, 1.0, 1.0, 0.18), 1.0)


func _rebuild() -> void:
	if not is_node_ready():
		return
	var rod_polygon := PackedVector2Array([
		Vector2(-3, 0),
		Vector2(3, 0),
		Vector2(3, rod_length),
		Vector2(-3, rod_length),
	])
	if _rod_visual.polygon != rod_polygon:
		_rod_visual.polygon = rod_polygon
	if _rod_visual.color != rod_color:
		_rod_visual.color = rod_color
	if _pivot_visual.color != rod_color:
		_pivot_visual.color = rod_color
	var bob_position := Vector2(0, rod_length)
	if _bob_visual.position != bob_position:
		_bob_visual.position = bob_position
	if _bob_visual.color != bob_color:
		_bob_visual.color = bob_color
	_set_angle()
	queue_redraw()
