@tool
class_name PhaseShuttle
extends "res://components/clock_device.gd"
## 相位穿梭块（D69）：一块 48×16 的实心踏板，在两个停靠点之间**整块瞬移**。
## 世界钟走着的时候它自己来回跳；被时间锚吸住时跳的节奏跟着玩家的手走（D66/D68）。
##
## 原点 = 当前所在停靠点的**块心**（场景里摆的那一点就是 A 点），B 点 = A + `offset`。
## 与移动方块的分工线：那块是连续 pingpong、能托着人走；这块只有两个位置、
## 中途不扫人（瞬移不经过中间，所以不存在"被推着横移"这件事）。站稳靠时机，不靠载人。
## 编辑器里画两个停靠点 + 行程线：实心框 = 开局那一格，淡框 = 另一头。
##
## 安全底线与相位面板同一条：跳过去之前先问目标位置，玩家或另一件 time_solid 占着就
## 停在原地 —— 下一拍接着试。玩家站在当前这一头时它跳走，人留在空中往下掉（这是
## "会抽走落脚点"的踏板，不是电梯；D69 裁定 D3）。

## 踏板尺寸。改它，碰撞体与两个停靠点的画法一起重算。
@export var step_size: Vector2 = Vector2(48.0, 16.0):
	set(value):
		step_size = Vector2(maxf(value.x, 8.0), maxf(value.y, 8.0))
		if is_inside_tree():
			_sync_geometry()
			queue_redraw()

## B 点相对 A 点的位移（场景里摆的那一点是 A）。竖直行程最常见，但任意方向都行。
@export var offset: Vector2 = Vector2(0.0, -64.0):
	set(value):
		offset = value
		if is_inside_tree():
			queue_redraw()

var _step_rect: RectangleShape2D
var _have_home: bool = false
var _home_global: Vector2
var _home_rotation: float


func _sync_geometry() -> void:
	var col := get_node_or_null("StepShape") as CollisionShape2D
	if col == null:
		return
	# 运行期独占一份形状资源（D21：sub_resource 会被同场景的其它实例共用）。
	if _step_rect == null:
		var src := col.shape as RectangleShape2D
		_step_rect = src.duplicate() as RectangleShape2D if src != null \
			else RectangleShape2D.new()
		col.shape = _step_rect
	_step_rect.size = step_size
	col.position = Vector2.ZERO


func _target_shape() -> Shape2D:
	return _step_rect


func _target_xform() -> Transform2D:
	if not _have_home:
		_capture_home()
	var t := global_transform
	# 目标 = 另一头；`_target_blocked()` 只在"想变过去"的那一帧被问，所以就是 !`_applied_on`。
	t.origin = _stop_global(not _applied_on)
	return t


func _apply_state(on: bool) -> void:
	if not _have_home:
		_capture_home()
	global_position = _stop_global(on)


## A 点是场景里摆下去那一点；B 点 = A + `offset`（跟着节点的旋转走）。
func _capture_home() -> void:
	_home_global = global_position
	_home_rotation = global_rotation
	_have_home = true


func _stop_global(on: bool) -> Vector2:
	if on:
		return _home_global
	return _home_global + offset.rotated(_home_rotation)


func _draw() -> void:
	var on := shown_on()
	var solid_at := Vector2.ZERO
	var ghost_at := Vector2.ZERO
	if Engine.is_editor_hint():
		# 编辑器里节点不动：按"场景里摆的是 A 点"画两个停靠点。
		solid_at = Vector2.ZERO if on else offset
		ghost_at = offset if on else Vector2.ZERO
	else:
		# 运行时节点已经挪到当前停靠点，另一头相对它就是反向的位移。
		ghost_at = offset if on else -offset
	draw_line(ghost_at, solid_at, WorldClock.COL_TRAIL_2, 1.0)
	var ghost := Rect2(ghost_at - step_size * 0.5, step_size)
	var fill := WorldClock.COL_TRAIL_2
	fill.a = 0.22
	draw_rect(ghost, fill)
	var frame := WorldClock.COL_TRAIL_1
	frame.a = 0.35
	draw_rect(ghost, frame, false, 1.0)
	var solid := Rect2(solid_at - step_size * 0.5, step_size)
	draw_rect(solid, WorldClock.COL_TRAIL_1)
	draw_rect(Rect2(solid.position, Vector2(solid.size.x, 2.0)), WorldClock.COL_LIT)
	draw_rect(solid, WorldClock.COL_EDGE, false, 1.0)
	draw_rect(Rect2(solid.position + Vector2(4.0, solid.size.y - 5.0), Vector2(3.0, 3.0)),
		WorldClock.COL_LIT if on else WorldClock.COL_UNLIT)
