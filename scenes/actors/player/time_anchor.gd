class_name TimeAnchor
extends Node2D
## D68 时间锚点（强回收）。一根物理锚、四种状态：
##   IDLE      在手上。按住 `anchor` 瞄准（方向 = 胸口指向鼠标），松开即发射。
##   OUTBOUND  飞行中。每物理帧扫一条射线，首撞定生死；中途按 E 收回。
##   ATTACHED  贴着目标。E 回收，Q 不再发第二根、也不画瞄准线。
##   RETURNING 回程。不理会碰撞，直线追胸口，吃真实 delta；到手上回 IDLE。
##
## 时间源（D66①）只有一条式子：**锚点物跟的是玩家的动作，不是世界钟**。
##   source 活着 && 没被移动锁掐住 && 锚点能力已开 && 手上有方向
## 四条全真 → 真实物理/处理 delta；否则 → 0。刻意不读世界钟的全局账本、
## 不吃 0.08 s 的松手缓冲、不认死亡/授予那一拍的钉住 —— 那三道闸管的是世界，
## 而锚点物只听玩家的手。松手当帧就停：玩家看见的因果必须是一对一的。
## 第三条那道闸读的是 `is_anchor_enabled`（D73）—— 锚点从此是**独立一项能力**，
## 与"世界冻不冻"那一项互不蕴含：两项可以任意组合，只开锚点时世界照样流动，
## 那时能测到的是"我按着它才走"，测不到"世界停了它还在走"那层对照。
##
## 回收（强回收）：一次只有一根锚。吸附中再按发射键什么也不发生；要换目标，
## 先 E 收回来。回收**当帧断链**，目标立刻回到世界钟（世界若冻着它就停）；
## 回程只演视觉，不再挡发射之外的事。死亡/重载把锚收回手上，不进存档 ——
## 它是这一条命里的物件，不是进度。吸附与回收都不碰目标自己的相位。
##
## 回执（D59 词汇）：吸附后锚上方一条 12 格走带，调色板直接取 `WorldClock` 的在册色。
## 亮格是 `_wound` 的纯函数，而 `_wound` 只在「供时」那一拍累加 —— 于是走带停住
## 就等于「锚点物这一拍没在动」。纯装饰：时间源从不回头读它，它也不发信号。
##
## 节点原点 = 锚的几何中心。`top_level`：飞行/吸附用世界坐标，且画在身体之上；
## 它不挂 Visual 底下，死亡那一拍的收缩不该把锚一起缩掉。

enum State { IDLE, OUTBOUND, ATTACHED, RETURNING }

## 最大射程（世界 px，从胸口算）。取景 640x360 的一半：站定能打到镜头边缘。
const RANGE: float = 320.0
## 飞行速度（世界 px/s）。吃真实 delta —— 世界冻着它照飞。
const FLY_SPEED: float = 900.0
## 只认实体：terrain(1) + time_solid(4)。传感器/玩家不在这条射线上。
const HIT_MASK: int = 1 | 4
## 回收基准速度与时长夹取：近处不闪回、远处不拖沓。
const RETURN_SPEED: float = 1400.0
const RETURN_MIN: float = 0.08
const RETURN_MAX: float = 0.30
## 未命中 / 撞墙的回程：短促收团，不演长途。
const MISS_RETURN: float = 0.12
## 回执走带：格数、周期（秒/圈）、格边长与间隙（世界 px）、悬浮高度。
const RECEIPT_TICKS: int = 12
const RECEIPT_PERIOD: float = 1.2
const RECEIPT_CELL: float = 3.0
const RECEIPT_GAP: float = 1.0
const RECEIPT_RISE: float = 30.0

## 锚的主人。由 `Player._ready()` 在 add_child 之前赋值。
var source: Player

var _state: State = State.IDLE
var _aiming: bool = false
## 飞行方向与已飞距离（距离从胸口起算）。
var _dir: Vector2 = Vector2.RIGHT
var _traveled: float = 0.0
## 吸附目标与「吸附点相对目标原点」的偏移：目标动，锚跟着走。
var _target: Node2D
var _receiver: TimeReceiver
var _socket_offset: Vector2 = Vector2.ZERO
## 回执的相位。只在供时那一拍累加，见文件头。
var _wound: float = 0.0
## 回程速度：吸附回收时按距离夹出时长，未命中回程按 MISS_RETURN 现算。
var _return_speed: float = 0.0
## 瞄准预览：落点与「那里能不能吸」。每帧一条射线，开销只有一个查询。
var _preview_point: Vector2 = Vector2.ZERO
var _preview_hit: bool = false
var _preview_anchorable: bool = false
## 射线排除玩家自己。建造一次，不每帧重排。
var _exclude: Array[RID] = []


func _ready() -> void:
	# 飞行与吸附都要世界坐标；若跟着 Player 的变换走，人一转身锚也跟着翻。
	top_level = true
	z_as_relative = false
	z_index = 5
	if source != null:
		var rids: Array[RID] = []
		rids.append(source.get_rid())
		_exclude = rids
		global_position = _chest()


## 锚被移出树（关卡重载、玩家被释放）时必须把目标的时间源还回去，
## 否则那个 Callable 指向一具尸体，目标会在下一帧静默退回世界钟 —— 没人在那之后
## 负责解释「为什么我拿不到它了」。
func _exit_tree() -> void:
	_drop_link()


func _physics_process(delta: float) -> void:
	if source == null:
		return
	if not TimeManager.is_anchor_enabled:
		if _state != State.IDLE or _target != null:
			reset_state()
		else:
			global_position = _chest()
		return
	if source.is_dead:
		if _state != State.IDLE or _target != null:
			cancel_for_death()
		return
	match _state:
		State.IDLE:
			_tick_idle()
		State.OUTBOUND:
			_tick_outbound(delta)
		State.ATTACHED:
			_tick_attached(delta)
		State.RETURNING:
			_tick_returning(delta)


func _tick_idle() -> void:
	global_position = _chest()
	if source.movement_locked:
		# 苏醒/授予那一拍里 Q 也按不出东西：锁是「这一拍不归他控制」的现成读法。
		if _aiming:
			_aiming = false
			_clear_preview()
			queue_redraw()
		return
	if Input.is_action_just_pressed(&"anchor"):
		_aiming = true
	if _aiming and not Input.is_action_pressed(&"anchor"):
		_aiming = false
		var shot: Vector2 = aim_direction()
		_clear_preview()
		fire_toward(shot)
		return
	if _aiming:
		_refresh_preview()
		queue_redraw()


func _tick_outbound(delta: float) -> void:
	if Input.is_action_just_pressed(&"interact"):
		recall()
		return
	# 射程按「已飞距离」封顶，不按帧数：改速度档时最后一步不会越界。
	var step: float = minf(FLY_SPEED * delta, RANGE - _traveled)
	if step <= 0.0:
		_begin_return(MISS_RETURN)
		return
	var from: Vector2 = global_position
	var to: Vector2 = from + _dir * step
	var hit: Dictionary = _ray(from, to)
	if not hit.is_empty():
		global_position = hit.get("position", to)
		var receiver := _anchorable_receiver(hit.get("collider"))
		if receiver != null:
			_attach(hit.get("collider") as Node2D, receiver)
		else:
			_begin_return(MISS_RETURN)
		return
	global_position = to
	_traveled += step
	if _traveled >= RANGE - 0.001:
		_begin_return(MISS_RETURN)


func _tick_attached(delta: float) -> void:
	if not is_instance_valid(_target):
		# 目标被释放：从最后一格插槽往回收，不留在原地当一根野锚。
		_target = null
		_receiver = null
		_begin_return()
		return
	global_position = _target.global_position + _socket_offset
	if Input.is_action_just_pressed(&"interact"):
		recall()
		return
	if _pump_enabled():
		_wound += delta
	queue_redraw()


func _tick_returning(delta: float) -> void:
	var home: Vector2 = _chest()
	var step: float = maxf(_return_speed, 1.0) * delta
	if global_position.distance_squared_to(home) <= step * step:
		global_position = home
		_return_speed = 0.0
		_state = State.IDLE
		queue_redraw()
		return
	global_position = global_position.move_toward(home, step)


## 生产入口：IDLE 才能发。方向由鼠标算，守门走同一个入口给一个确定方向。
func fire_toward(direction: Vector2) -> bool:
	if _state != State.IDLE or source == null:
		return false
	if not TimeManager.is_anchor_enabled or source.is_dead or source.movement_locked:
		return false
	var dir: Vector2 = direction
	if dir.length_squared() < 0.000001:
		dir = Vector2(float(source.facing), 0.0)
	_dir = dir.normalized()
	_traveled = 0.0
	_aiming = false
	_clear_preview()
	global_position = _chest()
	_state = State.OUTBOUND
	queue_redraw()
	return true


## E 的唯一入口。只在 OUTBOUND / ATTACHED 有反应；回收键在回程里按了等于没按。
func recall() -> bool:
	if _state == State.ATTACHED:
		_drop_link()
		_aiming = false
		_begin_return()
		return true
	if _state == State.OUTBOUND:
		_aiming = false
		_begin_return()
		return true
	return false


## 死亡那一拍把锚收掉：断链、回手上、不出演回程（尸体旁边的飞行动画只会抢死亡那一拍）。
func cancel_for_death() -> void:
	reset_state()


## 关卡级重置（复活、能力被关）。清掉一切与这一条命绑定的东西；
## 目标自己的相位不在这里，也不在任何地方被复位。
func reset_state() -> void:
	_drop_link()
	_state = State.IDLE
	_aiming = false
	_traveled = 0.0
	_return_speed = 0.0
	_wound = 0.0
	_clear_preview()
	if source != null:
		global_position = _chest()
	queue_redraw()


func current_state() -> State:
	return _state


func is_aiming() -> bool:
	return _aiming


func has_link() -> bool:
	return _target != null


func attached_target() -> Node2D:
	return _target


## 瞄准方向 = 胸口指向鼠标；鼠标压在胸口上时退回朝向，避免归一化出零向量。
func aim_direction() -> Vector2:
	if source == null:
		return Vector2.RIGHT
	var to_mouse: Vector2 = get_global_mouse_position() - _chest()
	if to_mouse.length() < 4.0:
		return Vector2(float(source.facing), 0.0)
	return to_mouse.normalized()


## 回执当前亮第几格。`_wound` 的纯函数 —— 守门会把它与独立重算比一次。
func receipt_index() -> int:
	return int(fmod(_wound / RECEIPT_PERIOD, 1.0) * float(RECEIPT_TICKS)) % RECEIPT_TICKS


## 回执相位（秒）。只在供时那一拍累加；`TimeReceiver` 的时间源从不读它。
func receipt_wound() -> float:
	return _wound


## 时间源物理通道。`TimeReceiver` 在有 Callable 时走这里，否则直连 `TimeManager`。
func _pump_physics_delta() -> float:
	return get_physics_process_delta_time() if _pump_enabled() else 0.0


## 时间源处理通道。与物理通道同一个闸，只给纯视觉的消费方用。
func _pump_process_delta() -> float:
	return get_process_delta_time() if _pump_enabled() else 0.0


## 锚点物「这一拍在动」的唯一判据。四条缺一不可；刻意不读松手缓冲与世界状态。
func _pump_enabled() -> bool:
	if source == null or source.is_dead or source.movement_locked:
		return false
	if _target == null or _receiver == null or not is_instance_valid(_target) \
			or not is_instance_valid(_receiver):
		return false
	if not TimeManager.is_anchor_enabled:
		return false
	return source.input_handler.is_moving


func _attach(body: Node2D, receiver: TimeReceiver) -> void:
	_target = body
	_receiver = receiver
	_socket_offset = global_position - body.global_position
	_wound = 0.0
	_state = State.ATTACHED
	# 唯一一处接手：目标从此只认这条式子，世界钟与松开缓冲都到不了它。
	_receiver.set_time_source(_pump_physics_delta, _pump_process_delta)
	queue_redraw()


func _drop_link() -> void:
	if _receiver != null and is_instance_valid(_receiver):
		_receiver.clear_time_source()
	_receiver = null
	_target = null


func _begin_return(fixed_duration: float = -1.0) -> void:
	var distance: float = global_position.distance_to(_chest())
	var duration: float = fixed_duration if fixed_duration > 0.0 \
		else clampf(distance / RETURN_SPEED, RETURN_MIN, RETURN_MAX)
	_return_speed = distance / maxf(duration, 0.001)
	_state = State.RETURNING
	_traveled = 0.0
	queue_redraw()


func _refresh_preview() -> void:
	_dir = aim_direction()
	var from: Vector2 = _chest()
	var hit: Dictionary = _ray(from, from + _dir * RANGE)
	if hit.is_empty():
		_preview_hit = false
		_preview_anchorable = false
		_preview_point = from + _dir * RANGE
		return
	_preview_hit = true
	_preview_point = hit.get("position", from)
	_preview_anchorable = _anchorable_receiver(hit.get("collider")) != null


## 锚点族的运行时判据：根在 `anchorable` 分组里，且自己挂着 TimeReceiver。
## 层与危险物那两条归守门（摆图时就能红），这里只认玩家真瞄上的那一个。
func _anchorable_receiver(collider: Variant) -> TimeReceiver:
	if not (collider is Node2D):
		return null
	var node := collider as Node2D
	if not node.is_in_group(&"anchorable"):
		return null
	return node.get_node_or_null("TimeReceiver") as TimeReceiver


func _ray(from: Vector2, to: Vector2) -> Dictionary:
	var space := get_world_2d().direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters2D.create(from, to, HIT_MASK, _exclude)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space.intersect_ray(query)


func _chest() -> Vector2:
	return source.global_position + Vector2(0.0, Player.CHEST_Y)


func _clear_preview() -> void:
	_preview_hit = false
	_preview_anchorable = false
	_preview_point = Vector2.ZERO


func _draw() -> void:
	if source == null or source.is_dead or not TimeManager.is_anchor_enabled:
		return
	if _aiming:
		_draw_aim()
	if _state == State.ATTACHED:
		_draw_tether()
		_draw_receipt()
	_draw_shard()


func _draw_aim() -> void:
	var from: Vector2 = _chest() - global_position
	var to: Vector2 = _preview_point - global_position
	_dashed(from, to, _with_alpha(WorldClock.COL_LIP, 0.38), 6.0, 5.0)
	var tint: Color = WorldClock.COL_TRAIL_1
	if _preview_hit:
		tint = WorldClock.COL_LIT if _preview_anchorable else WorldClock.COL_UNLIT
	_draw_reticle(to, tint)


func _draw_reticle(at: Vector2, tint: Color) -> void:
	var r: float = 5.0
	for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(at + dir * 2.0, at + dir * r, tint, 1.0, false)
	draw_rect(Rect2(at - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), tint)
	if _preview_anchorable:
		draw_arc(at, r + 2.0, 0.0, TAU, 16, _with_alpha(tint, 0.6), 1.0, false)


func _draw_tether() -> void:
	_dashed(_chest() - global_position, Vector2.ZERO,
		_with_alpha(WorldClock.COL_TRAIL_1, 0.6), 3.0, 5.0)


func _draw_receipt() -> void:
	var width: float = float(RECEIPT_TICKS) * RECEIPT_CELL \
		+ float(RECEIPT_TICKS - 1) * RECEIPT_GAP
	var origin := Vector2(-width * 0.5, -RECEIPT_RISE)
	draw_rect(Rect2(origin - Vector2(1.0, 1.0), Vector2(width + 2.0, RECEIPT_CELL + 2.0)),
		WorldClock.COL_EDGE)
	draw_rect(Rect2(origin, Vector2(width, RECEIPT_CELL)), WorldClock.COL_SCREEN)
	var idx: int = receipt_index()
	for i in RECEIPT_TICKS:
		var back: int = posmod(idx - i, RECEIPT_TICKS)
		var c: Color = WorldClock.COL_LIT if back == 0 else WorldClock.COL_TRAIL_1 \
			if back == 1 else WorldClock.COL_TRAIL_2 if back == 2 else WorldClock.COL_UNLIT
		draw_rect(Rect2(origin + Vector2(float(i) * (RECEIPT_CELL + RECEIPT_GAP), 0.0),
			Vector2(RECEIPT_CELL, RECEIPT_CELL)), c)


func _draw_shard() -> void:
	var body := PackedVector2Array([
		Vector2(0.0, -8.0), Vector2(6.0, 0.0), Vector2(0.0, 8.0), Vector2(-6.0, 0.0),
	])
	draw_colored_polygon(body, WorldClock.COL_LIT)
	draw_polyline(PackedVector2Array([body[0], body[1], body[2], body[3], body[0]]),
		WorldClock.COL_EDGE, 1.0, false)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, -4.0), Vector2(3.0, 0.0), Vector2(0.0, 4.0), Vector2(-3.0, 0.0),
	]), WorldClock.COL_LIP)
	if _aiming:
		draw_polyline(PackedVector2Array([
			Vector2(0.0, -11.0), Vector2(9.0, 0.0), Vector2(0.0, 11.0), Vector2(-9.0, 0.0),
			Vector2(0.0, -11.0),
		]), _with_alpha(WorldClock.COL_LIP, 0.55), 1.0, false)
	if _state == State.ATTACHED:
		draw_arc(Vector2.ZERO, 10.0, 0.0, TAU, 20,
			_with_alpha(WorldClock.COL_LIP, 0.5), 1.0, false)
	elif _state == State.OUTBOUND:
		draw_line(Vector2.ZERO, -_dir * 12.0,
			_with_alpha(WorldClock.COL_TRAIL_1, 0.7), 2.0, false)


func _dashed(from: Vector2, to: Vector2, color: Color, on: float, off: float) -> void:
	var span: float = from.distance_to(to)
	if span < 0.5:
		return
	var dir: Vector2 = (to - from) / span
	var t: float = 0.0
	while t < span:
		var end: float = minf(t + on, span)
		draw_line(from + dir * t, from + dir * end, color, 1.0, false)
		t += on + off


func _with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)
