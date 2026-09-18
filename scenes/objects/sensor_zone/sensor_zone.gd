@tool
class_name SensorZone
extends Area2D
## 通用触发区：一块只认玩家的矩形，用来做终点区、旁路区、剧情触发点。
##
## 为什么单独有它而不直接在关卡里摆 Area2D：Area2D 判的是碰撞盒重叠，
## 贴地站的玩家碰撞盒中心在地面以上 15 px，手写 shape 的 position 很容易贴着地面画，
## 于是"玩家明明踩过去了却没触发"。这里默认把带心钉在那条线上，摆的人只填宽高。
##
## 节点原点 = 触发区**底边中心**。放在地面上（y = 地面 y）即可，不用算偏移。
## 需要放在空中时改 `band_centre_y`：它是带心相对节点原点的偏移。
##
## 触发带默认只在编辑器里画出来（半透明），运行时不可见 —— 灰盒期的辅助线不该进画面。
## 需要玩家真的看见（例如终点光柱）时把 `visible_in_game` 打开，或直接删掉 Visual 节点。
##
## 与按钮同一契约：区域被玩家占住时发 `pressed_changed(true/false)`，
## 所以它也能直接填进门上的 `trigger`（"走进这块区域门就开"不用写关卡脚本）。
## 刻意不学按钮那套"冻结期间不松开"：按钮延迟松开是为了面板别在时停里弹起来，
## 而这块带子运行时根本不可见；门收到关闭意图也只是停住不动，画面同样自洽。
##
## @tool：改 width/height/band_centre_y 立刻重画。

signal pressed_changed(pressed: bool)

@export var width: float = 96.0:
	set(value):
		width = value
		_rebuild()

## 触发带高度。要覆盖到的竖直范围，比如"从地面到天花板"就填房间净高。
@export var height: float = 80.0:
	set(value):
		height = value
		_rebuild()

## 带心相对节点原点（底边中心）的偏移。默认 -15 正好对准贴地玩家的碰撞盒中心。
## 空中触发带把它改成想要的带心高度（例如底边在原点上方 100 px 的带子填 -100）。
@export var band_centre_y: float = -Player.COLLISION_HALF_HEIGHT:
	set(value):
		band_centre_y = value
		_rebuild()

@export var zone_color: Color = Color(0.4, 1.0, 0.7, 0.15):
	set(value):
		zone_color = value
		_rebuild()

@export var visible_in_game: bool = false:
	set(value):
		visible_in_game = value
		_rebuild()

@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual

## 与 ButtonPlate 同名，方便摆图时对照：玩家此刻是否占着这块区域。
var is_pressed: bool = false

## 计数而不是布尔：Area2D 的 entered/exited 是逐体的，用 bool 会被第二个进入者的 exited 打断。
var _player_count: int = 0


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	_player_count += 1
	_set_pressed(true)


func _on_body_exited(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	_player_count = maxi(_player_count - 1, 0)
	if _player_count == 0:
		_set_pressed(false)


func _set_pressed(value: bool) -> void:
	if is_pressed == value:
		return
	is_pressed = value
	pressed_changed.emit(value)


func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(width, height):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(width, height)
		_collision.shape = shape
	var band_center := Vector2(0.0, band_centre_y)
	if _collision.position != band_center:
		_collision.position = band_center
	var half := Vector2(width, height) * 0.5
	var polygon := PackedVector2Array([
		band_center - half,
		Vector2(band_center.x + half.x, band_center.y - half.y),
		band_center + half,
		Vector2(band_center.x - half.x, band_center.y + half.y),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	if _visual.color != zone_color:
		_visual.color = zone_color
	var should_show: bool = visible_in_game or Engine.is_editor_hint()
	if _visual.visible != should_show:
		_visual.visible = should_show
