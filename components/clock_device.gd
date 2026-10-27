@tool
class_name ClockDevice
extends StaticBody2D
## 周期器件的共同地基（D69）。这一族只有一件事：把 `_clock` 按 `get_physics_delta()`
## 一格一格攒起来，再由子类把某一段窗口翻译成"实体 / 虚体"或"在这一头 / 在那一头"。
##
## 时间源**只有** `TimeReceiver` 一条：默认直连世界钟，被时间锚吸住时由锚换成玩家的手。
## 器件本身不知道自己被锚着，也不写第二套计时 —— 这一条是 D66/D68 的分界：
## 平时受世界钟调控，被锚附着时反过来跟手，撤锚当帧回世界钟。
## 所以这里**不许**出现世界时钟或 TimeManager 的直读：
## 直读全局量会看起来也在动，但世界一冻它就停，锚点劫持不到（D68 那笔账）。
##
## 安全底线：只在"要变成实体 / 要换到那一头"时问一次物理世界。目标位置被玩家或
## 另一件 time_solid 占着就停在旧状态，画出来的也跟着停在旧状态 ——
## 于是永远不会出现"画着虚、其实是实体"或"把玩家挤开"的那一拍（D69 裁定 D2）。
## 查询带内缩 `PROBE_INSET`：玩家站在边界上（踩面与目标顶边相切）不算占用。
##
## 子类只需回答三件事：目标形状是什么、它落在哪、状态变了怎么落地；`_draw` 自己画。
## 编辑器里 `_clock` 钉在 0，用 `phase` 摆出"开局那一格"的样子供摆图核对。

## 一个完整周期多少秒（世界时间）。填 0 = 恒开（`cycle_on()` 永远为真）。
@export var period: float = 2.0:
	set(value):
		period = value
		if is_inside_tree():
			queue_redraw()

## 一个周期里"开"占多少比例。0 = 恒关、1 = 恒开，都是合法配置。
@export_range(0.0, 1.0, 0.01) var duty: float = 0.5:
	set(value):
		duty = clampf(value, 0.0, 1.0)
		if is_inside_tree():
			queue_redraw()

## 相位偏移（秒）。编辑器里用来看"开局落在哪一格"，运行时也照它起手。
@export var phase: float = 0.0:
	set(value):
		phase = value
		if is_inside_tree():
			queue_redraw()

## 占位查询只认玩家(2)与别的 time_solid(4)。地形不在里面：摆歪到墙里是摆图错误，
## 不该让器件在运行时永远变不实；而贴着地面那条相切边界会被误判（D21 的实测）。
const CLEAR_MASK: int = 2 | 4
## 目标矩形四周各收 1 px。玩家站在目标顶边上时脚底与目标上沿相切，不收这一圈
## 就会把"站在旁边"读成"站在里面"，平台永远不敢变实。
const PROBE_INSET: float = 1.0

var _clock: float = 0.0
## 物理世界里此刻到底是哪一头。`_draw` 读它而不是读 `cycle_on()`：
## 被占住而停住的那些帧，画面必须和碰撞体说同一句话。
var _applied_on: bool = true
## 想变过去但目标被占着。留着这面旗是为了"玩家让开的那一帧接着变"，不是第二个状态。
var _blocked: bool = false

@onready var _receiver: TimeReceiver = $TimeReceiver


func _ready() -> void:
	_sync_geometry()
	if Engine.is_editor_hint():
		_applied_on = cycle_on()
		queue_redraw()
		return
	# 先钉成"关"再问一次开：起手落在开窗口里，也要先过那道占位查询。
	_applied_on = false
	_apply_state(false)
	_refresh_state(cycle_on())
	queue_redraw()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 只有这一条读数：世界门控 delta 或被锚换成的手上 delta。冻结时它是 0，
	# 器件就停在当前相位 —— 与 D35 电棒、D47 残影同一口径。
	var d: float = _receiver.get_physics_delta()
	if d > 0.0:
		_clock += d
	var target: bool = cycle_on()
	if target != _applied_on or _blocked:
		_refresh_state(target)


## 当前相位落在"开"窗口里吗。世界时钟的纯函数（`_clock` 是它攒出来的）。
func cycle_on() -> bool:
	if period <= 0.0:
		return true
	return fposmod(_clock + phase, period) < period * duty


## 物理世界里此刻的状态（不是目标状态）。守门与调试读它。
func is_on() -> bool:
	return _applied_on


## 变不过去（目标被占）时为真。
func is_blocked() -> bool:
	return _blocked


## 画图用的状态：运行时与碰撞体同源，编辑器里按 `phase` 预览开局那一格。
func shown_on() -> bool:
	return cycle_on() if Engine.is_editor_hint() else _applied_on


func _refresh_state(target: bool) -> void:
	if target == _applied_on:
		_blocked = false
		return
	# 变成实体/换到另一头才要问；变回虚体永远放行（收小不会挤人）。
	if target and _target_blocked():
		_blocked = true
		return
	_blocked = false
	_applied_on = target
	_apply_state(target)
	queue_redraw()


## 目标位置此刻被玩家或别的 time_solid 占着吗。无状态查询，每帧重问 ——
## 与 Player 的起身净空同一套理由（D21）：不维护重叠计数，瞬移/冻结/重载都不用补账。
func _target_blocked() -> bool:
	var shape: Shape2D = _target_shape()
	if shape is not RectangleShape2D:
		return false
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var src := shape as RectangleShape2D
	var probe := RectangleShape2D.new()
	probe.size = Vector2(maxf(src.size.x - PROBE_INSET * 2.0, 1.0),
		maxf(src.size.y - PROBE_INSET * 2.0, 1.0))
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = probe
	params.transform = _target_xform()
	params.collision_mask = CLEAR_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var exclude: Array[RID] = []
	exclude.append(get_rid())
	params.exclude = exclude
	return not space.intersect_shape(params, 4).is_empty()


## 目标矩形的形状（子类给）。不是矩形就不做占位查询。
func _target_shape() -> Shape2D:
	return null


## 目标矩形落在世界哪里（子类给）。
func _target_xform() -> Transform2D:
	return global_transform


## 几何随导出项重算（子类给）。
func _sync_geometry() -> void:
	pass


## 状态落地：开关碰撞体、挪位置（子类给）。`_draw` 由 `queue_redraw()` 统一触发。
func _apply_state(_on: bool) -> void:
	pass
