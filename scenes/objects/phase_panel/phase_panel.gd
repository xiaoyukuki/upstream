@tool
class_name PhasePanel
extends "res://components/clock_device.gd"
## 相位面板（D69）：中间一块永远实的 32×16 底座，两侧的 96×16 桥面按相位现形。
## 世界钟走着的时候它自己开合；被时间锚吸住时开合跟着玩家的手走（D66/D68）。
##
## 摆法：原点 = 底座中心，块底在原点**下方** 8 px。要让底座坐在地面上就填
## `y = 地面线 - 8`（块顶 = 地面线 - 16）；要让站在同一层的玩家**平射**打中，抬到
## `y = 地面线 - 18`（块身跨过胸口线 —— D68 的射线从胸口出，贴地摆平射会从顶上 2 px 擦过）。
## 鼠标瞄准是任意方向，贴地摆也能俯射，抬不抬取决于这一关要不要它先挡路。
## 底座上沿就是踩面（局部 y = -8），桥面与它同高 —— 站在底座上等桥面变实，
## 或把它当一条会断的桥用。桥面是横向对称展开的，底座在正中。
## 编辑器里按 `phase` 画开局那一格：蓝青实心 = 会挡人，淡青虚线框 = 虚体。
##
## 它**不判断**玩家在不在桥面上（底座永远实，玩家站上去不会踩空），
## 也不跟任何触发源接线：驱动它的是时间，不是按钮。

const BASE_SIZE: Vector2 = Vector2(32.0, 16.0)

## 桥面整宽（含压在底座上那一段）。跟着 `panel_size.y` 控制厚度，上沿永远与底座上沿齐。
@export var panel_size: Vector2 = Vector2(96.0, 16.0):
	set(value):
		panel_size = Vector2(maxf(value.x, BASE_SIZE.x), maxf(value.y, 8.0))
		if is_inside_tree():
			_sync_geometry()
			queue_redraw()

var _panel_rect: RectangleShape2D


func _sync_geometry() -> void:
	var col := get_node_or_null("PanelShape") as CollisionShape2D
	if col == null:
		return
	# 运行期独占一份形状：场景里的 sub_resource 被同一场景的其它实例共用（D21 那个坑）。
	if _panel_rect == null:
		var src := col.shape as RectangleShape2D
		_panel_rect = src.duplicate() as RectangleShape2D if src != null \
			else RectangleShape2D.new()
		col.shape = _panel_rect
	_panel_rect.size = panel_size
	# 上沿钉在底座上沿：盒子只往下长。
	col.position = Vector2(0.0, -BASE_SIZE.y * 0.5 + panel_size.y * 0.5)


func _target_shape() -> Shape2D:
	return _panel_rect


func _target_xform() -> Transform2D:
	var col := get_node_or_null("PanelShape") as CollisionShape2D
	return col.global_transform if col != null else global_transform


func _apply_state(on: bool) -> void:
	var col := get_node_or_null("PanelShape") as CollisionShape2D
	if col != null:
		col.disabled = not on


func _draw() -> void:
	var on := shown_on()
	var panel := Rect2(-panel_size.x * 0.5, -BASE_SIZE.y * 0.5, panel_size.x, panel_size.y)
	var base := Rect2(-BASE_SIZE.x * 0.5, -BASE_SIZE.y * 0.5, BASE_SIZE.x, BASE_SIZE.y)
	if on:
		draw_rect(panel, WorldClock.COL_TRAIL_1)
		draw_rect(Rect2(panel.position, Vector2(panel.size.x, 2.0)), WorldClock.COL_LIT)
		draw_rect(panel, WorldClock.COL_EDGE, false, 1.0)
	else:
		var fill := WorldClock.COL_TRAIL_2
		fill.a = 0.24
		draw_rect(panel, fill)
		var edge := WorldClock.COL_TRAIL_1
		edge.a = 0.35
		draw_rect(panel, edge, false, 1.0)
	# 底座最后画：它压在桥面正中，读作"这台机器的壳"。
	draw_rect(base, WorldClock.COL_SCREEN)
	draw_rect(Rect2(base.position, Vector2(base.size.x, 2.0)), WorldClock.COL_LIP)
	draw_rect(base, WorldClock.COL_EDGE, false, 1.0)
	draw_rect(Rect2(-2.0, -2.0, 4.0, 4.0),
		WorldClock.COL_LIT if on else WorldClock.COL_UNLIT)
