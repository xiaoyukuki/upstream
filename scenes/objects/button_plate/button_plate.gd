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
## 立绘（D25）= 无缝平铺零件（`assets/props/`）：琥珀踩面 16x8 + 钢座 16x8（前唇 3 行、凹槽 5 行）。
## 踩下时踩面沉进凹槽、前唇挡在它前面，前唇中央的青灯亮；调色板固定，不提供逐实例调色。
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

## 面板踩下时下沉的像素数。凹槽只有 8 px 深，超过 8 的部分画面上夹住（见 `_draw`）。
@export var press_depth: float = 8.0:
	set(value):
		press_depth = value
		_rebuild()

var is_pressed: bool = false

var _pending_unpress: bool = false
## 面板当前下沉量（0..8），用真实 delta 缓动，见 `_process`。
var _sink: float = 0.0

const TEX_TOP: Texture2D = preload("res://assets/props/button_top.png")
const TEX_BASE: Texture2D = preload("res://assets/props/button_base.png")
## 数值与 props.json 的 end_shade / button_socket / led_lit 同源，verify_kit 会比对两边。
const END_SHADE: Color = Color8(67, 75, 86)
const SOCKET: Color = Color8(26, 38, 46)
const LED_LIT: Color = Color8(158, 209, 227)

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 用真实 delta：按钮面板是玩家身体的直接反馈，玩家豁免时停。
	var target: float = minf(press_depth, 8.0) if is_pressed else 0.0
	var next: float = lerpf(_sink, target, 1.0 - exp(-24.0 * delta))
	if absf(target - next) < 0.01:
		next = target
	if next != _sink:
		_sink = next
		queue_redraw()


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
	queue_redraw()


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
	queue_redraw()


## 立绘三遍：凹槽内壁在面板后、面板、前唇在面板前。踩下时面板顶落到前唇顶那条线，
## 露出来的只有前唇以下那截 —— 「沉进座里」靠遮挡关系读，不靠整块位移。
## 零件横向平铺、右缘裁余料，width 填任意值都对得齐。
func _draw() -> void:
	var x0: float = -width * 0.5
	var sink: float = clampf(_sink, 0.0, 8.0)
	var top_y: float = -16.0 + sink
	_tile(TEX_BASE, x0, -5.0, width, 5.0, 3.0)
	_tile(TEX_TOP, x0, top_y, width, 8.0)
	_tile(TEX_BASE, x0, -8.0, width, 3.0)
	draw_rect(Rect2(x0, top_y, 1.0, -top_y), END_SHADE)
	draw_rect(Rect2(x0 + width - 1.0, top_y, 1.0, -top_y), END_SHADE)
	draw_rect(Rect2(-1.0, -8.0, 2.0, 2.0), SOCKET)
	if is_pressed:
		draw_rect(Rect2(-1.0, -8.0, 2.0, 2.0), LED_LIT)


func _tile(tex: Texture2D, x: float, y: float, w: float, h: float, src_y: float = 0.0) -> void:
	var cw: float = tex.get_width()
	var ch: float = tex.get_height() - src_y
	var cx: float = x
	while cx < x + w - 0.001:
		var tw: float = minf(cw, x + w - cx)
		var cy: float = y
		while cy < y + h - 0.001:
			var th: float = minf(ch, y + h - cy)
			draw_texture_rect_region(tex, Rect2(cx, cy, tw, th), Rect2(0.0, src_y, tw, th))
			cy += th
		cx += tw
