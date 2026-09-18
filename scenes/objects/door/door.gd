@tool
class_name Door
extends StaticBody2D
## 升降门：门扇**顶边固定、底边上升**（卷帘式），开度由累计的门控时间直接算出。
##
## 位置、碰撞体尺寸都是 `_progress` 的纯函数，所以三件事同时成立：
## 冻结即停在当前开度、恢复即从当前开度续走（连续性是算术性质，不靠肉眼判断）、
## 且碰撞体永远和画出来的那截门扇严丝合缝 —— 玩家能过的瞬间恰好是门底越过他头顶的瞬间。
##
## 为什么不用 AnimationPlayer：`test_cube` 只验证过 `speed_scale=0` 的冻结，
## "非循环动画播完后再把 speed_scale 翻负能否倒放"在编辑器进程里验不出来
## （`advance()` 不提交数值轨道），而"门收到一半再也打不开"是不可接受的失败。
## 同理也不用 `seek()` 与 Tween —— 那两条是恢复瞬间会跳帧的路径。
##
## 节点原点 = 门洞底边中心（x 居中、y 贴地），门扇向 -y 方向生长。
## 刻意不采用地形那套"原点=左上角"：门洞位置要按地面标注，底边中心写起来最不容易错。
##
## 接线写在门上，不写在关卡脚本里：把按钮拖进 `trigger` 就完了。
## 编辑器里会从门底画一条线连到触发源，摆图时一眼能看出哪扇门没接头；运行时无这条线。
##
## 关门压到玩家头顶时**停住**，不是把人挤开：StaticBody2D 改尺寸推不动任何 body，
## 旧版那一下横弹是玩家下一帧 `move_and_slide()` 发现自己陷进门板后的脱困副产物。
## 夹的仍然只是 `_progress`，所以"碰撞体 == 画出来的门扇"与纯函数位置模型都不破。
##
## @tool：检查器里改 height/width 立刻反映到门扇与碰撞体，摆门不用先运行游戏。

signal open_changed(is_open: bool)

## 门洞高度，也是门扇完全关闭时的高度。
@export var height: float = 96.0:
	set(value):
		height = value
		_apply(_progress)

## 门扇宽度，与门洞等宽。
@export var width: float = 32.0:
	set(value):
		width = value
		_apply(_progress)

## 全行程用时（秒，世界时间）。
@export var open_time: float = 0.5

## 开这扇门的触发源：指向任意带 `pressed_changed(pressed: bool)` 信号的节点
## （ButtonPlate、SensorZone 都算）。检查器里点属性右侧的文件夹按钮选，或直接从场景树拖进来。
## 留空表示这扇门由关卡脚本调 `set_open()` 驱动。
## 用 NodePath 而不是 `export(Node)`：实测 .tscn 里给 Node 类型的槽写
## `trigger = NodePath("../ButtonPlate")`，游戏进程 instantiate 后读回来是 null，
## 引用不会被还原成节点；NodePath 自己进树后解析才可靠。
## 判据是信号而不是类型：门只认"有人告诉我开还是关"，不认识按钮长什么样。
@export_node_path var trigger: NodePath:
	set(value):
		trigger = value
		_reconnect_trigger()

@export var panel_color: Color = Color(0.66, 0.42, 0.3):
	set(value):
		panel_color = value
		_apply(_progress)

var is_open: bool = false
## 关门时撞上了玩家头顶、正停在他的头骨上。给日志与自测读，不参与任何判定。
var is_blocked: bool = false

## 0=关严，1=全开。
var _progress: float = 0.0
## -1=正在关，0=不动，1=正在开。
var _direction: int = 0
## 当前真正连上了信号的触发源。改 trigger 时要先解掉它的旧连接。
var _bound: Node
## 编辑器连线的终点（门本地坐标），用来发现按钮被挪了位置。
var _link_end: Vector2 = Vector2.INF
## 复用一份查询参数，避免每帧造资源。矩形单独留一份强类型引用：`Shape2D` 上没有 size。
var _probe: PhysicsShapeQueryParameters2D
var _probe_rect: RectangleShape2D

const TRIGGER_SIGNAL: StringName = &"pressed_changed"
const LINK_COLOR: Color = Color(1.0, 0.62, 0.2, 0.6)
## 只让位给玩家层（2d_physics/layer_2）。用碰撞层而不是 `is_in_group("player")`：
## 掩码本来就是这门已经认得的语法，不必再认一个组名。
const SQUEEZE_MASK: int = 2
const MAX_SQUEEZE_HITS: int = 8
## 零位移接触的探针余量。必须大于 `cast_motion` 自己的接触边距（实测约 0.08 px），
## 又远小于门一帧的行程（0.5 s / 96 px ≈ 3.2 px），才不会提前半格把门停住。
const HOLD_MARGIN: float = 0.5
## 停在头顶时留的手动余量，见 `_clamp_squeeze`。
const CONTACT_SLACK: float = 0.1

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _visual: Polygon2D = $Visual


func _ready() -> void:
	_probe = PhysicsShapeQueryParameters2D.new()
	_probe_rect = RectangleShape2D.new()
	_probe.shape = _probe_rect
	_probe.collision_mask = SQUEEZE_MASK
	_probe.collide_with_bodies = true
	_probe.collide_with_areas = false
	# 运行期每次都换一份独立的形状资源：门扇尺寸是逐帧改的，
	# 若两个门共用 door.tscn 里那份 sub_resource，一个关门会把另一个也拽小。
	# 编辑器里不跑动画，所以只在尺寸不符时替换，避免白白标脏场景。
	var rect := _collision.shape as RectangleShape2D
	if Engine.is_editor_hint() and rect != null and rect.size == Vector2(width, height):
		_apply(_progress)
		return
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width, height)
	_collision.shape = shape
	_apply(_progress)
	# 再连一次：.tscn 里指向同场景其它节点的引用，可能在属性 setter 之后才解析出来。
	_reconnect_trigger()


func _physics_process(_delta: float) -> void:
	# 编辑器守卫：TimeReceiver 在编辑器里不会 _ready()，走它会碰到 TimeManager 的
	# placeholder 实例并刷一屏错误。全项目所有 @tool 构件的守卫理由都在这条注释里。
	if Engine.is_editor_hint():
		_poll_link_line()
		return
	if _direction == 0:
		return
	var d: float = _receiver.get_physics_delta()
	if d <= 0.0:
		return
	var next: float = clampf(_progress + d * float(_direction) / open_time, 0.0, 1.0)
	is_blocked = false
	if _direction < 0:
		next = _clamp_squeeze(next)
	_progress = next
	_apply(_progress)
	if _progress == 0.0 or _progress == 1.0:
		_direction = 0


## 关门专用：本帧门底要从当前处降到 target，中间如果有玩家，就把开度夹到
## "门底正好贴着他的碰撞盒顶"。夹的仍然只是 `_progress`。
##
## 两条查询各管一段，都是实测出来的必要：
## - 4.6 的 `intersect_shape` 只回 `rid/collider_id/collider/shape`（`shape` 还是索引 int），
##   拿不到被撞形状的世界矩形，所以问不出"他的头在哪"；`cast_motion` 才问得出"我还能走多少"。
## - 但 `cast_motion` 对**恰好相切**和**已经重叠**都回报无碰撞（实测都返回 1.0），
##   只用它的话门会先贴住头、下一帧照样越过去。所以先拿一条往下多探 HOLD_MARGIN 的
##   静止矩形查询把这种零位移接触按住，走不动就不动。
## 走形状查询而不是给门加 Area2D 子节点，为的是**不留重叠计数状态**：玩家 respawn 被瞬移走、
## 门在冻结中、解冻续走这几条路径都得靠 entered/exited 补账，漏一次就永久卡在"被挡"上。
## 冻结时 `get_physics_delta()` 为 0 已经先 return，所以挤压只可能发生在玩家站着不动、
## 世界时间在走的那一瞬 —— 他一走动门就悬住了，本来就不会追着他压。
func _clamp_squeeze(target: float) -> float:
	var h_now: float = height * (1.0 - _progress)
	var descent: float = height * (1.0 - target) - h_now
	if descent <= 0.001:
		return target
	var top: float = global_position.y - height
	var space := get_world_2d().direct_space_state
	_probe.transform = Transform2D(0.0, Vector2(global_position.x, top + (h_now + HOLD_MARGIN) * 0.5))
	_probe_rect.size = Vector2(width, h_now + HOLD_MARGIN)
	_probe.motion = Vector2.ZERO
	if not space.intersect_shape(_probe, MAX_SQUEEZE_HITS).is_empty():
		is_blocked = true
		return _progress
	_probe_rect.size = Vector2(width, h_now)
	_probe.transform = Transform2D(0.0, Vector2(global_position.x, top + h_now * 0.5))
	_probe.motion = Vector2(0.0, descent)
	var fraction: float = space.cast_motion(_probe)[0]
	if fraction >= 1.0:
		return target
	is_blocked = true
	# 只许停不许顶：万一玩家已经站进了门板（重生落位之类），门停住而不是被他举起来。
	# 关门是 `_progress` 变小的方向，所以"不许顶开"要夹上界，夹下界会把门停在接触点之前。
	# `CONTACT_SLACK`：引擎自己的接触边距实测只有 0.08 px 且不保证保守（曾越过头顶 0.03 px），
	# 所以自己再留一档，把"绝不压过头"变成硬保证；2 倍取景下 0.1 px 只值 0.2 屏幕像素。
	var safe: float = maxf(h_now + descent * clampf(fraction, 0.0, 1.0) - CONTACT_SLACK, 0.0)
	return clampf(1.0 - safe / height, 0.0, _progress)


func set_open(value: bool) -> void:
	if is_open == value:
		return
	is_open = value
	_direction = 1 if value else -1
	open_changed.emit(value)


## 换触发源必须先解掉旧连接：在检查器里改一次属性就重连一次，
## 留着旧连接的话老按钮照样能开这扇门，而场景里已经看不出来它接在哪儿。
func _reconnect_trigger() -> void:
	if Engine.is_editor_hint():
		queue_redraw() # 编辑器里只需要重画那条辅助线，不接信号
		return
	var next: Node = _trigger_source()
	if _bound != null and is_instance_valid(_bound):
		_bound.disconnect(TRIGGER_SIGNAL, _on_trigger_pressed_changed)
	_bound = null
	if next == null:
		return
	if not next.has_signal(TRIGGER_SIGNAL):
		push_warning("门 %s 的 trigger %s 不发 %s，这扇门不会被打开" % [
			name, str(trigger), TRIGGER_SIGNAL])
		return
	next.connect(TRIGGER_SIGNAL, _on_trigger_pressed_changed)
	_bound = next


## 路径是相对本节点的，所以必须进树之后才解析得动。
func _trigger_source() -> Node:
	if trigger.is_empty() or not is_inside_tree():
		return null
	return get_node_or_null(trigger)


func _on_trigger_pressed_changed(pressed: bool) -> void:
	set_open(pressed)


func _poll_link_line() -> void:
	var source: Node = _trigger_source()
	if source == null:
		return
	var point := to_local(source.global_position)
	if point != _link_end:
		_link_end = point
		queue_redraw()


## 辅助线只给摆图的人看，运行时不该出现在画面里 —— 与触发带同一原则。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var source: Node = _trigger_source()
	if source == null:
		return
	var point := to_local(source.global_position)
	_link_end = point
	draw_line(Vector2.ZERO, point, LINK_COLOR, 2.0)
	draw_circle(point, 5.0, LINK_COLOR)


## 冻结时不调用，因此停在当前开度；开度到几就画几，没有中间态。
func _apply(progress: float) -> void:
	if not is_node_ready():
		return
	var h: float = maxf(height * (1.0 - progress), 0.001)
	var rect := _collision.shape as RectangleShape2D
	if rect != null and rect.size != Vector2(width, h):
		rect.size = Vector2(width, h)
	var shape_position := Vector2(0.0, -height + h * 0.5)
	if _collision.position != shape_position:
		_collision.position = shape_position
	var polygon := PackedVector2Array([
		Vector2(-width * 0.5, -height),
		Vector2(width * 0.5, -height),
		Vector2(width * 0.5, -height + h),
		Vector2(-width * 0.5, -height + h),
	])
	if _visual.polygon != polygon:
		_visual.polygon = polygon
	if _visual.color != panel_color:
		_visual.color = panel_color
