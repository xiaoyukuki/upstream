@tool
class_name KeyDoor
extends StaticBody2D
## 刷卡门（D36）：钢框 + 能量光幕，独立于按钮门（`Door`）的另一个场景。
## 分界的真正理由是**结构差**：`Door` 的核心是双向行程 + 关门接触让位
##（`_clamp_squeeze` 只在关门方向跑），而这里是一次性闩锁 + 一次性撤幕，没有关门方向
## —— 那一整块探针在它是死代码，塞回同一个场景要么留死代码要么给 `Door` 加开关，
## 而开关一进去，蹲伏锁定语义就跟着进了一扇根本不该挤压人的门。
##
## 节点原点 = 门洞底边中心（与 `Door` 同一约定，摆图的人不用换脑子）。
## 碰撞体就是整个门洞（`Rect2(-w/2, -H, w, H)`），闩锁后整块撤掉。
##
## 退场是一拍**演出**而不是硬切（D41，取代 D40 的「当帧消失」）：感应带认卡 → 玩家水平输入
## 与起跳被临时锁住 → 卡从体内向上飞出并淡化、光幕同时自上而下逐行熄灭 → 两边都跑完才解锁。
## 幕体永远坐在地板上，玩家要过去只能等它归零，中途任何一点残留都等于一堵墙 ——
## 所以这一拍**必须**配合移动锁：没有锁，演出期间玩家正走进一堵正在消失的墙里，
## 那才是 D40 当初否掉中间态的真正理由。锁把「露馅的那 0.45 秒」整个删掉，动画才便宜得起。
## 挤压也无从发生：闩锁时玩家前沿离幕面还有 40 px（感应带 46 - 盒半宽 10 - 幕半宽 16），
## 锁期间靠摩擦最多再飘 ~10 px，而幕只缩不涨（D36 第 10 条同一论证）。
##
## 判据：玩家进入感应带（Reader 子节点，带心 -15）∧ 钥匙被持有 → 一次性闩锁 → 演出 → 门常开。
## 扫描与演出**都不吃世界 delta**（D40 留下来的那半条结论，如今是演出的地基）。理由不是省事：
## 玩家朝门走 = 必然按着方向键 = 必然处于冻结态，所以 D36 第 9 条那句「冻结即钉住，最多停一步
## 让它灭完」**每次都会撞上**。演出因此跑在引擎自己的固定物理步长上 —— 那道闸只截
## `TimeReceiver` 拿到的世界 delta，截不到 `_physics_process(delta)`，钥匙卡飞出的计时同理
##（D30 第 4 条的豁免）；玩家在这一拍里按着方向键，世界继续停着，解冻由他松手决定，不由门决定。
##
## 立绘复用门框零件（jamb/header/caps 同一套 ab 钢框，读作「这是一道门洞」），
## 幕体 = 纯色半透明青 + 左右亮收边 + 外侧一像素光晕 + 顶端断电前沿，**不画纹路**
##（带光丝那版被用户否了）。颜色与 props.json 的 gate_curtain / gate_led_locked /
## gate_led_lit 同源，verify_kit 比对（D36 第 6/7 条）。LED 锁着 = 琥珀 —— 与钥匙同色，
##「这把开那扇」是一对，同色在这里是语义而不是撞车。演出**开始**的那一帧 LED 就转青：
## 它是「认卡了、别硬走」的即时回执，等演完才变色等于把回执延后到玩家已经开始按键之后。
##
## 拒绝态（D53）：没有卡却走进感应带时，这颗灯**连底座一起**发红（选型图 G 行：亮面积从
## 2×2 涨到 4×4，赌的是面积而不是明度 —— 4×4 设备像素上任何纯色相对琥珀都拉不开，实测见
## `tools/gen_gate_alert_preview.py`）。它是一条**只读旁路**：不锁移动、不消耗卡、不碰闩锁链
## 的任何一句，认卡之后青仍然盖住红。边沿触发一次、离开感应带才重新上弦，所以站着不动只会
## 闪一次而不是持续眨。时长与演出同理**不吃世界 delta**（走近 = 按着方向键 = 世界冻着，
## 吃世界 delta 的脉冲永远走不完），跑在引擎自己的固定物理步长上。
##
## @tool：改 height/width/sensor_* 立刻重画；编辑器里画一条到钥匙的辅助连线（运行时不画）。

## 门洞高度，也是光幕完全供着电时的高度。
@export var height: float = 96.0:
	set(value):
		height = value
		_refresh()

## 门洞宽度。
@export var width: float = 32.0:
	set(value):
		width = value
		_refresh()

## 感应带在门框两侧各探出的距离（px）。「玩家接近」从这条线开始算。
@export var sensor_reach: float = 24.0:
	set(value):
		sensor_reach = value
		_refresh()

## 感应带高度。默认 40：贴地玩家与低跳都接得住，高跳掠过头顶不算「接近」。
@export var sensor_height: float = 40.0:
	set(value):
		sensor_height = value
		_refresh()

## 这扇门吃哪张卡（KeyPickup）。编辑器里从场景树拖进来或点属性右侧的文件夹按钮选；
## 换 Path 而不是 export(Node)：NodePath 进树之后解析才可靠（与 Door.trigger 同一条实测）。
## 一张卡最多被一扇门引用，多引会在守门里直接 FAIL（D30 第 6 条 / D36 第 6 条）。
@export_node_path var key: NodePath

## 整拍演出的时长（秒，跑在固定物理步长上、不吃世界 delta）：卡飞出与光幕逐行熄灭共用这一个数，
## 玩家移动被锁住这么久。填 0 会被兜到 0.001，等于退化回 D40 那种一帧硬切。
@export var swipe_time: float = 0.45

## 拒绝脉冲的时长（秒，同样跑在固定物理步长上、不吃世界 delta）：无钥匙走进感应带时
## 那颗灯连底座发红这么久，然后自己回到琥珀。填 0 = 下一帧就结束（一帧硬闪）；这条计时
## 只有累加与比较、没有除法，所以不需要 `swipe_time` 那句 maxf 兜底。
@export var denied_time: float = 0.5

## 已完全打开（钥匙已消耗、演出已跑完，光幕与它的碰撞体一起撤掉）。闩了不会倒回去。
## 注意与「正在演出」是两件事：演出中卡已经没了、LED 已经青了，但门还没让行。
var is_latched: bool = false

## 演出进行中：-1 表示不在演出，否则是已经演了多少秒（真实时间，不吃世界 delta）。
var _swipe_elapsed: float = -1.0
## 被本扇门临时锁住移动的玩家，演出收尾时把移动还回去。
var _locked_player: Player

## 拒绝脉冲进行中：-1 表示不在脉冲，否则已经演了多少秒（真实时间，不吃世界 delta）。
var _denied_elapsed: float = -1.0
## 本次停留是否还能触发脉冲。人还在带里就不重新上弦，所以站着不动只闪一次而不是持续眨；
## 离开感应带才回到待命，下一次闯进来照样闪。
var _denied_armed: bool = true

## 编辑器连线的终点（门本地坐标），用来发现钥匙被挪了位置。
var _link_end: Vector2 = Vector2.INF

const TEX_JAMB: Texture2D = preload("res://assets/props/door_jamb.png")
const TEX_HEADER: Texture2D = preload("res://assets/props/door_header.png")
const TEX_HEADER_L: Texture2D = preload("res://assets/props/door_header_cap_l.png")
const TEX_HEADER_R: Texture2D = preload("res://assets/props/door_header_cap_r.png")
const LINK_COLOR: Color = Color(1.0, 0.62, 0.2, 0.6)
## 与 props.json 的 gate_led_locked / gate_led_lit / gate_curtain / gate_led_denied /
## gate_led_denied_socket 同源，verify_kit 逐条比对；
## LED_SOCKET 与 props.json 的 led_socket 同源（门楣底座与按钮门共用同一个钢框家族）。
## 拒绝态那一对是选型图 G 行的字面值（`tools/gen_gate_alert_preview.py` 在真帧 + CRT 上量过）：
## 底座跟着换暗红，亮的面积从 2×2 涨到整颗 4×4，赌面积不说明度。
const LED_SOCKET: Color = Color8(21, 30, 37)
const LED_LOCKED: Color = Color8(250, 190, 74)
const LED_LIT: Color = Color8(182, 242, 248)
const LED_DENIED: Color = Color8(255, 86, 74)
const LED_DENIED_SOCKET: Color = Color8(66, 14, 18)
const CURTAIN: Color = Color8(110, 230, 240)
## 光幕底部那行接地钢色 = 实装调色板 g 的 metal（124,136,176），选型图同源。
const GROUND_ROW: Color = Color8(124, 136, 176)
## 残辉三行 / 幕体 / 外侧光晕的 alpha（选型图定稿的数值）。
const AFTERGLOW_A := [120.0, 66.0, 30.0]
const BODY_A: float = 150.0
const GLOW_A: float = 48.0

## 撤幕后碰撞体留的高度而不是 0：Godot 不接受零尺寸的碰撞形状，这条 epsilon 与
## `Door._apply` 同源。绘制侧一律先 `floorf()`，0.001 因此正好读成「没有幕」。
const OPEN_H: float = 0.001

@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _reader: Area2D = $Reader
@onready var _reader_shape: CollisionShape2D = $Reader/ReaderShape


func _ready() -> void:
	# 形状资源运行期独占一份（D27 第 7 条）：两扇门共用 tscn 里那份 sub_resource 的话，
	# 一扇收幕会把另一扇也拽小。编辑器里不跑动画，尺寸相符时沿用原资源避免标脏场景。
	var rect := _collision.shape as RectangleShape2D
	if Engine.is_editor_hint() and rect != null and rect.size == Vector2(width, height):
		_refresh()
		return
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width, height)
	_collision.shape = shape
	_refresh()
	if not Engine.is_editor_hint() and _key_pickup() == null:
		push_warning("刷卡门 %s 的 key 没接（或接的不是 KeyPickup），这扇门永远开不了" % name)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		_poll_key_link()
		return
	if _swipe_elapsed >= 0.0:
		# 这里的 delta 是引擎自己的物理步长，与 TimeManager 那道闸无关 —— 世界冻着也照走，
		# 这正是「演出在冻结的那一拍里跑」（D41）。
		_advance_swipe(delta)
		return
	_advance_denied(delta)
	_scan_denied()
	_scan_reader()


## 感应带扫描不吃世界 delta：玩家朝门走 = 世界冻结，检测必须照常。取卡失败/未持有
## 就直接不扫 —— 没卡的人靠不近门，光幕纹丝不动，这正是「先捡卡再进门」的读法（D36 末条）。
## 认卡不再当场开幕（D41）：改成把移动锁挂到玩家身上、演一整拍，演完才算真开了。
## 时长只有一个来源 —— 传给 consume()，卡与幕共用它。
func _scan_reader() -> void:
	if is_latched:
		return
	var pickup := _key_pickup()
	if pickup == null or not pickup.is_held():
		return
	# 尸体不刷卡（D42）：死在感应带里那一拍，卡不该飞、幕不该灭 —— 两层演出叠在
	# 一起只会互相盖住，而这一关马上就要重载，闩上的门也留不到下一世。
	var courier := _live_courier()
	if courier == null:
		return
	if pickup.consume(swipe_time):
		_locked_player = courier
		courier.movement_locked = true
		_swipe_elapsed = 0.0
		# 认卡盖过拒绝。不取消的话演出期间 `_advance_denied` 不再被调用，这个计时会永远
		# 停在「正在闪」，`is_denial_showing()` 就成了谎 —— 绘制侧本来有优先级兜着，
		# 但状态本身不该留一个永远不会自己结束的真值。
		_denied_elapsed = -1.0
		queue_redraw()


## 拒绝脉冲（D53）：**只读旁路** —— 不锁移动、不消耗卡、不碰上面那条闩锁链的任何一句。
## 与 `_scan_reader` 各跑各的，同一帧里两者互斥（没卡才可能红，有卡才可能闩）。
## 边沿触发：`_denied_armed` 只在人离开感应带之后重新上弦，所以站着不动只闪一次。
## 没接钥匙的门（`pickup == null`）照样闪：从玩家的立场「你进不去」是真的，
## 那条接线错误已经由 `_ready` 的 push_warning 负责响。
func _scan_denied() -> void:
	if is_latched or _denied_elapsed >= 0.0:
		return
	var pickup := _key_pickup()
	if pickup != null and pickup.is_held():
		return
	if _live_courier() == null:
		_denied_armed = true
		return
	if not _denied_armed:
		return
	_denied_armed = false
	_denied_elapsed = 0.0
	queue_redraw()


## 拒绝脉冲的计时。与演出同一条理由跑固定物理步长：走近 = 按着方向键 = 世界冻着，
## 吃世界 delta 的脉冲永远走不完。到点自己收回，不需要 `_finish_swipe` 那种收尾顺序 ——
## 它不锁任何东西，早一帧晚一帧都只是那颗灯的颜色。
func _advance_denied(delta: float) -> void:
	if _denied_elapsed < 0.0:
		return
	_denied_elapsed += delta
	if _denied_elapsed >= denied_time:
		_denied_elapsed = -1.0
	queue_redraw()


## 拒绝脉冲是否正在显示（守门读它；绘制侧自己判，别处不要拿它分支）。
func is_denial_showing() -> bool:
	return _denied_elapsed >= 0.0


## 逐行熄灭的每一帧：碰撞体跟着幕高走，绘制跟着碰撞体走（同一真值来源，D36 第 6 条 b）。
## 只缩不涨，所以「实体不比画出来的短」这条不变量在演出中也成立。
func _advance_swipe(delta: float) -> void:
	_swipe_elapsed += delta
	if _swipe_elapsed >= swipe_time:
		_finish_swipe()
		return
	_sync_collision()
	queue_redraw()


## 收尾顺序有讲究：先把状态摆成「真开了」让幕归零，再把移动还回去。
## 反过来会有一帧玩家已经能行动、门却还没让行 —— 正是 D40 要消灭的那个体感。
func _finish_swipe() -> void:
	_swipe_elapsed = -1.0
	is_latched = true
	_sync_collision()
	queue_redraw()
	if _locked_player != null and is_instance_valid(_locked_player):
		_locked_player.movement_locked = false
	_locked_player = null


## 演出进度 0..1。swipe_time 被填成 0 时兜到 0.001，避免算出 NaN 尺寸的形状。
func _swipe_progress() -> float:
	return clampf(_swipe_elapsed / maxf(swipe_time, 0.001), 0.0, 1.0)


func _key_pickup() -> KeyPickup:
	if key.is_empty() or not is_inside_tree():
		return null
	var node := get_node_or_null(key)
	if node is KeyPickup:
		return node
	return null


## 感应带里那个「算玩家」的活人，没有则 null。尸体不算玩家（D42）这条判据现在只有
## 这一个来源：刷卡与拒绝提示两条路各自都要它，分开写就会有一天只改一边。
func _live_courier() -> Player:
	for body in _reader.get_overlapping_bodies():
		if not body.is_in_group(&"player"):
			continue
		var courier := body as Player
		if courier != null and not courier.is_dead:
			return courier
	return null


func _poll_key_link() -> void:
	var pickup := _key_pickup()
	if pickup == null:
		return
	var point := to_local(pickup.global_position)
	if point != _link_end:
		_link_end = point
		queue_redraw()


## 立绘任何进程都画；到钥匙的辅助线只给摆图的人看（与 Door 的 trigger 连线同一原则）。
func _draw() -> void:
	_draw_frame()
	_draw_curtain()
	if not Engine.is_editor_hint():
		return
	var pickup := _key_pickup()
	if pickup == null:
		return
	_link_end = to_local(pickup.global_position)
	draw_line(Vector2.ZERO, _link_end, LINK_COLOR, 2.0)
	draw_circle(_link_end, 5.0, LINK_COLOR)


## 门框 = 门/按钮同款的 ab 钢框零件；门楣下沿加两行「亮脊」（取 header 零件自己的
## 头两行，不另配色）。选型图 paint_gate 同一条合成路径，预览与实机逐像素一致。
func _draw_frame() -> void:
	var x0: float = -width * 0.5
	var top: float = -height
	TileDraw.tile(self, TEX_JAMB, x0 - 4.0, top - 12.0, 4.0, height + 12.0)
	TileDraw.tile(self, TEX_JAMB, x0 + width, top - 12.0, 4.0, height + 12.0)
	draw_texture_rect_region(TEX_HEADER_L, Rect2(x0 - 4.0, top - 12.0, 4.0, 12.0), Rect2(0.0, 0.0, 4.0, 12.0))
	TileDraw.tile(self, TEX_HEADER, x0, top - 12.0, width, 12.0)
	draw_texture_rect_region(TEX_HEADER_R, Rect2(x0 + width, top - 12.0, 4.0, 12.0), Rect2(0.0, 0.0, 4.0, 12.0))
	TileDraw.tile(self, TEX_HEADER, x0, top, width, 2.0)
	# LED 在演出**开始**的那一帧就转青：它是「认卡了」的即时回执（D41）。
	var lit: bool = is_latched or _swipe_elapsed >= 0.0
	# 三态优先级：认了卡（青）> 正在拒绝（红）> 锁着（琥珀）。红与青在同一帧互斥，
	# 由扫描侧那句 `is_held()` 早退保证，这里不再判一次；`denied` 只可能盖住琥珀。
	var denied: bool = not lit and _denied_elapsed >= 0.0
	draw_rect(Rect2(x0 + width * 0.5 - 2.0, top - 8.0, 4.0, 4.0),
			LED_DENIED_SOCKET if denied else LED_SOCKET)
	draw_rect(Rect2(x0 + width * 0.5 - 1.0, top - 7.0, 2.0, 2.0),
			LED_LIT if lit else (LED_DENIED if denied else LED_LOCKED))


## 光幕（下带）：残辉 → 幕体 → 外侧光晕 → 左右收边 → 断电前沿 → 底部接地行，
## 与选型图 paint_gate 同一顺序同一算式。`height` 允许是小数，行号先取整只许往收的
## 方向舍（与 Door 同一条理由）：实体永远不比画出来的短，玩家撞不进可见光幕。
## 演出中这一整套算式一个字不改，只是 `live` 逐帧变小：底边永远接地，只有顶端在往下压
## ——「自上而下逐行熄灭」因此不需要任何新代码，它是这条既有算式的自然读法（D41）。
## 塌到不足一行时 floorf 给 0、整块不画；闩锁后高度停在 OPEN_H，同样读成「没有幕」。
func _draw_curtain() -> void:
	var x0: float = -width * 0.5
	var live: float = floorf(_curtain_height())
	if live <= 0.0:
		return
	var band_top: float = -live
	var w: float = width
	for i in AFTERGLOW_A.size():
		draw_rect(Rect2(x0, band_top - 1.0 - i, w, 1.0), Color(CURTAIN, AFTERGLOW_A[i] / 255.0))
	draw_rect(Rect2(x0, band_top + 1.0, w, -band_top - 1.0), Color(CURTAIN, BODY_A / 255.0))
	draw_rect(Rect2(x0 - 1.0, band_top, 1.0, -band_top), Color(CURTAIN, GLOW_A / 255.0))
	draw_rect(Rect2(x0 + w, band_top, 1.0, -band_top), Color(CURTAIN, GLOW_A / 255.0))
	var rim := CURTAIN.lightened(0.45)
	draw_rect(Rect2(x0, band_top, 1.0, -band_top), rim)
	draw_rect(Rect2(x0 + w - 1.0, band_top, 1.0, -band_top), rim)
	draw_rect(Rect2(x0, band_top, w, 1.0), CURTAIN.lightened(0.74))
	draw_rect(Rect2(x0, -1.0, w, 1.0), GROUND_ROW)


## 还挡路的光幕高度：绘制与碰撞体唯一的真值来源（D36 第 6 条 b）。
## 三档：开完了没有幕 / 演出中线性塌到零 / 满门洞。线性而不是缓动 —— 匀速下落读作
## 「机器断电」，跟卡的缓出上冲正好是两种主语，两个都用同一条曲线会糊成一团。
func _curtain_height() -> float:
	if is_latched:
		return OPEN_H
	if _swipe_elapsed < 0.0:
		return height
	return maxf(height * (1.0 - _swipe_progress()), OPEN_H)


## 本帧画出来的光幕本地矩形。与碰撞体同一套算式，守门拿它比对碰撞体（D36 第 6 条 b）。
func curtain_rect() -> Rect2:
	var vis: float = floorf(_curtain_height())
	return Rect2(-width * 0.5, -vis, width, vis)


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _refresh() -> void:
	if not is_node_ready():
		return
	_sync_collision()
	var rs := _reader_shape.shape as RectangleShape2D
	var want := Vector2(width + sensor_reach * 2.0, sensor_height)
	if rs == null or rs.size != want:
		var shape := RectangleShape2D.new()
		shape.size = want
		_reader_shape.shape = shape
	var band := Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	if _reader_shape.position != band:
		_reader_shape.position = band
	queue_redraw()


## 碰撞体永远跟着 `_curtain_height()`：演出中每帧重写一次，认卡前与开完后也都严丝合缝。
## 只缩不涨，玩家不可能被夹在中间（D36 第 10 条）。
func _sync_collision() -> void:
	if not is_node_ready():
		return
	var h: float = _curtain_height()
	var rect := _collision.shape as RectangleShape2D
	if rect != null and rect.size != Vector2(width, h):
		rect.size = Vector2(width, h)
	var pos := Vector2(0.0, -h * 0.5)
	if _collision.position != pos:
		_collision.position = pos
