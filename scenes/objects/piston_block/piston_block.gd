@tool
class_name PistonBlock
extends StaticBody2D
## 活塞踏板：按钮踩下时从墙/地里伸出来当落脚点，松开后快速收回。
## **反向档（`rest_out`，D63）** 是同一块反过来摆：没人踩着时停在满行程，踩下才收回。
##
## 反向档为什么是导出项而不是第二个场景（用户裁 D63①「同场景 + 一个开关」）：这块的行为差异
## 只有"哪一头是常态"这一格 —— 触发逻辑（多台 OR 电平合成）、积分器、皮、原点契约、
## `_resolve` 那条挤开口径全都不动。在册的先例是 `travel_offset` 的符号：往左伸和往右伸也是
## "行为不同"，项目的口径那是值不是场景。D49 那句「行为不同就拆场景」射的是刷卡门 vs 按钮门
## 那种**两套触发 + 两套动画**，翻一个符号翻不出第二套。
##
## 代价写在明面上：编辑器里光看块看不出常态是哪一头，所以 `_draw_editor_guides()` 把**常态那一头
## 画成实心**、另一头仍是空心框（摆图时一眼分得出，不需要读检查器）。
##
## 与 `moving_block` 的分工：那块自己有时序（往返摆），这块**没有自己的时序**，只有一个被按钮
## 布尔量驱动的积分器 —— 按住就朝"伸出"走、松开就朝"收回"走，两个方向速度不同（伸出慢到踩在
## 按钮上的人跟得上，收回快到站不住）。**两档速度绑的是几何不是输入（用户裁 D63②）**：往洞口走
## 一律 `retract_speed`、往满行程走一律 `extend_speed`，反向档只换"谁触发它们"，所以手册 §5 那条
## 「站得住的时长 = 伸出长度 ÷ retract_speed」在两种模式下同一句话，不用分档讲两遍。冻结时不吃门控 delta，所以停在当前伸出量上，解冻续走。
## 位置是伸出量的纯函数这一条与门同源；差别只在于这里的伸出量由人踩着什么决定。
##
## 为什么是积分器而不是两段动画：被人顶住走不满行程是这块的**常态**（`_resolve` 那条夹前缘），
## 而"停在半路"必须是任何一块的合法状态 —— 动画那套要么跳到下一关键帧、要么倒放不干净。
## 积分器只解决"被谁挡住"里的人这一头：**活塞之间互不解算**（mask 0，`_resolve` 只读玩家）。
## 两块行程对穿时它们会互相穿过，所以那是一条摆放约束而不是一个 bug，见手册 §5。
##
## 节点原点 = **收回态的前表面中心**，也就是洞口线在中轴上的那一点。这条约定白送三件便宜事：
## 1) 摆图时把原点对准墙面/地面那条线，伸多远由 `travel_offset` 说，不用再对半个方块；
## 2) 收回态整块身子在洞口**里面**（埋在墙里），露在外面的只有"伸出量"那一截 —— 于是皮只画露出的
## 一截就行，不需要遮罩或裁边。（别写成"被地形盖住"：Objects 排在 TileMapLayer 之上，盖是盖不住的。）
## 3) 前缘的投影坐标恰好等于原点的投影坐标 —— "把人让到前缘之外"那条算式里少一项。
## 这是"原点=底边中心"通则之外的第三个特例（前两个：电棒 = 光束中心、残影踏板 = 喷嘴口）。
## **反向档不挪这条约定**：摆的仍然是洞口那一点，`_anchor` 仍然是收回态的前缘，变的只是静止时
## 身子停在对岸 —— 于是"收回态那截必须整块埋进地形"那条摆图硬数在两种模式下都成立（它说的
## 本来就是"埋起来的那一头"，不指输入）。
##
## 行程只认主轴：`travel_offset` 取 |x| 与 |y| 大的那一维，另一维忽略（斜着伸出的 AABB 构件
## 没有唯一的"前缘"，让位量就算不出来）。两维都写了值且差出一像素以上时进树打一次警告。
##
## 挤压不可能出现（"挤开"的口径）：伸出时先让**玩家自己的身体**去解算 —— 他 `move_and_collide`
## 撞上背后的墙就停在那儿，我们随后按他停住的位置夹住自己的前缘。于是"他推不动"和"我走不动"
## 是同一件事，不需要第二条挤压判定，也不需要门那套 `cast_motion` + `intersect_shape` 双探针
## （那套是门改尺寸推不动人逼出来的；这块推得动人，靠的是 `_resolve` 里那一发 `push_by`，
## 不是靠基类会推 —— 见下面 `StaticBody2D` 那条）。
##
## 基类是 **StaticBody2D（D64）**，不是 `moving_block` 那样的 CharacterBody2D。这条是承重的：
## CharacterBody2D 每帧自己走 `move_and_slide`，就会成为"平台"，而 Godot 给骑在上面的人**附加
## 平台速度** —— 即使这一帧我们只是写 `global_position`、即使人自己的 `velocity.y` 是零。实测
## 签名是「收回时人以 8.53 px/拍（= `retract_speed` 512 px/s）匀速下沉，同时 `vy = 0.00`、
## `is_on_floor() = true`」：D64③ 把 `vy` 归零之后，`is_on_floor()` 一真就开了这条通道，于是收回
## 途中的活塞把脚下的人**拽着往下走**，直接废掉 D49 那条「收回时整个跳过：前缘正从他脚下退开」
## 与守门里那根「收回走完时人还在半空」的钉。这块从来不用 `velocity` / `move_and_slide` /
## `move_and_collide`，只写位置 —— 换成 StaticBody2D 就是关掉这条**文档没写的第二条运动通道**，
## 让"人怎么动"重新只有他自己那一票。Player 那侧 `platform_floor_layers` 也试过（能治，但会连带
## 让 `level_01_tutorial` 里骑 MovingBlock 的人不再被带着走，改成他把那块顶住），所以治在构件这头。
##
## collision_mask 写死 0：这块的位移不由物理解算，是从伸出量直接落位置。若照 `moving_block`
## 那样带上 terrain(1)，收回态那截身子整块埋在墙里 = 起点就重叠，而 `move_and_collide` 从重叠
## 状态起步会把整段位移原样退回来 —— 活塞一辈子钻不出洞口。代价是一条摆放约束（手册 §5）：
## 行程扫过的那条带子里，除了洞口那一截，不许有地形。
##
## 接线写在块上（同门的口径）：把按钮拖进 `triggers` 就完了。**两个方向的多对一都合法**：
## 多块指同一个按钮（D49，那正是"一组"的写法），一块指多台按钮（D60）。与"一卡一门"那条
## 相反，这里两头都刻意不查重 —— 查重等于把"一组"和"多台都能推"两种摆法都判死。
##
## 多台的合成口径是 **OR**：任一台按下就伸出，**全部**松开才收回（裁定 D60①A；反向档下同一句
## 话换成"任一台按下就收回、全部松开才伸回去"，合成那一半一个字没改）。这条不是
## 顺手写的：接第二台的时候如果沿用"信号里直接写 `is_out`"那种最后一条说了算的写法，
## A 踩着、B 松开的那一瞬间这块会当着人的面缩回去。所以聚合只有一个来源（`_refresh_out()`），
## 它读各源**当前的** `is_pressed` 而不是事件历史 —— 一台被拆走（`queue_free` 之后不再有信号）
## 时它会自己从聚合里掉出去，而事件历史版会永远停在"按下"那一档。
## 代价是触发源的契约从"发 `pressed_changed`"变成"发信号 **且** 暴露 `is_pressed`"
## （`ButtonPlate` / `SensorZone` 两条都本来就满足；缺后一条的源在进树时打警告，不静默当没踩着）。
##
## 多台合成的是**电平**（`_level`：有没有人踩着），电平映射到哪一头由 `rest_out` 决定
## （`is_out` = 电平与常态那一头的异或，D63 的全部代码量就那一行）。**这两个量分两格写是承重的**：
## `_resolve` 那条「只在往外走时才把人让开」读的必须是"在哪一头"，不是"有没有人踩着" ——
## 反向档下踩着按钮的那块正在往洞里退，那时候把人往墙里推才是错的。
##
## 皮肤是 `_draw()` 画出来的，不是贴图：`block_size` 是导出量，固定尺寸的 PNG 在改边长时会糊；
## 而过程化绘制里所有数字都按"沿行程轴那一边 / 垂直那一边"走，改边长等于整张皮跟着缩放。
## 配色与 `_ticks` 那条线索照 D49 选型图的 B 档（青光踏板）搬过来，"能踩"这层话与残影踏板的
## 冻结格、那扇青门共用一套青与亮白 —— 见下面那组常量。
##
## @tool：编辑器里不跑位移（跑了会把 position 写进场景，下次装载就漂了），改为画出满行程的
## 方块轮廓、行程线，以及**每个触发源各一条**连过去的线 —— 摆图时一眼看出哪块没接头。

## 全行程用时与终点相对原点的偏移。只认主轴那一维，见文件头。
@export var travel_offset: Vector2 = Vector2(64.0, 0.0):
	set(value):
		travel_offset = value
		_refresh()

## 方块边长（宽高各向）。64 是一个身位，能站上去。
@export var block_size: Vector2 = Vector2(64.0, 64.0):
	set(value):
		block_size = value
		_refresh()

## 伸出速度（px/s，世界时间）。
@export var extend_speed: float = 60.0

## 收回速度（px/s，世界时间）。站得住的时长就是"伸出长度 ÷ 这个数"。
@export var retract_speed: float = 240.0

## 常态在哪一头（D63）。false = 没人踩着时埋在洞里、踩下才伸出（D49 现状，出厂档）；
## true = 没人踩着时停在满行程、**踩下才收回**。它只是把触发源的电平映射到另一头，
## 积分器 / 两档速度 / 皮 / 原点契约全不动。
## 整列 `triggers` 留空时这条白送一种正确行为：普通块静止是个静物地面，反向块静止是一座桥。
@export var rest_out: bool = false:
	set(value):
		rest_out = value
		_refresh_out()

## 驱动这块的触发源：任意带 `pressed_changed(pressed: bool)` 信号的节点（ButtonPlate、
## SensorZone 都行），填多少台都可以，合成的口径是 OR（任一台按下就伸出，全松开才收回，D60）。
## 用 NodePath 而不是 `export(Array[Node])` 的理由与门同条：实测 .tscn 里给 Node 槽写路径，
## 游戏进程 instantiate 后读回来是 null。整列留空 = 由关卡脚本调 `set_out()` 驱动。
@export var triggers: Array[NodePath] = []:
	set(value):
		triggers = value
		_reconnect_triggers()

## 各源 OR 出来的**电平**：有没有人踩着。它与 `is_out` 分两格写（理由见文件头：反向档下这两者
## 不同值，而 `_resolve` 与两档速度读的是"在哪一头"）。它只有一个合成来源（`_refresh_out()`）。
var _level: bool = false

## 当前该伸出还是该缩回（= 满行程那一头还是洞里那一头）。接了源的块由 `_refresh_out()` 从各源
## 状态与 `rest_out` 一起算出来，这里只是它落地的地方；位置只跟它走。
var is_out: bool = false

var _anchor: Vector2
## 行程轴的单位向量（带符号 = 伸出方向），与它的绝对值版 `_axis`：方向与长度分家，
## 所有"沿轴多长"都用 _axis 点，所有"往哪走"都乘 _unit。
var _unit: Vector2 = Vector2.RIGHT
var _axis: Vector2 = Vector2.ONE
var _span: float = 64.0
## 方块沿行程轴的半长。原点在前缘，所以身子整块在 -_unit 方向上。
var _half: float = 32.0
## 当前接上的那些源（已去重，顺序照 `triggers`）。聚合只读这一列，于是"接了几条信号"与
## "一次按下算几家"用的是同一份名单，不会出现两台之间的隐形差别。
var _bound: Array[Node] = []
## 每台源最后一次报上来的布尔量。**存的是各源各自的状态而不是一个总开关**：OR 要能在
## "A 踩着、B 松开"那一瞬仍然伸出，就必须知道 A 还踩着。
var _state := {}
var _link_ends: Array[Vector2] = []
## 运动线索（洞口那两枚短线）当前画不画。缓存成字段而不是在 `_draw` 里读 delta：
## 冻结那一拍 `_physics_process` 整条早退，不在早退前过一遍这个判断，线索就会留在一张已经钉住的画面上。
var _ticks: bool = false

const TRIGGER_SIGNAL: StringName = &"pressed_changed"
const LINK_COLOR: Color = Color(1.0, 0.62, 0.2, 0.6)
## 接触判定沿行程轴给的容差（D64）。`Rect2.intersects` 不算相切，而"挤到位、一寸也走不动"
## 那一档长期就是相切 —— 容差补掉它，理由见 `_resolve()` 里那段。
const CONTACT_TOLERANCE: float = 1.0

## —— 皮肤（选型图 B 青光踏板，D49 定档）。调色板固定、不提供逐实例调色，与按钮/门/残影同一条口径。
## 每个值都是 `tools/gen_piston_preview.py` 里那一项的 Color8 版：`darker(青,t)` = 乘 (1-t)，
## `rgba(青,a)` = 把 a 直接写进 alpha。青与亮白两个值与 `afterimage_emitter.gd` 的
## STEP_SOLID / STEP_LIP 同源（同一套"能踩"的话），描边那一档取 `darker(青, 0.45)` = 那边的 STEP_EDGE。
const PLATE: Color = Color8(18, 24, 40)		# 身体 = screen：暗到只留轮廓，全靠顶面那两像素说话
const PLATE_EDGE: Color = Color8(61, 127, 132)	# darker(青, 0.45)
const PLATE_LIT: Color = Color8(110, 230, 240)	# accent 青：实心，画在前缘往下那 2 px
const PLATE_GLOW: Color = Color8(110, 230, 240, 34)
const TREAD: Color = Color8(206, 222, 250)	# lip 亮白：踩面就是这一像素
const SOCKET: Color = Color8(42, 87, 91)		# darker(青, 0.62)：洞口那圈鞘
const SOCKET_LIP: Color = Color8(110, 230, 240, 160)
const MOUTH: Color = Color8(22, 26, 42)		# edge：洞口的缝
const MOUTH_DOTS: Color = Color8(206, 222, 250, 70)
## 顶面往下退的三道青光（alpha 150/90/30）。最亮那道同时是洞口那两枚运动线索的颜色 ——
## 同一档青，选型图里就是这么共用的，别再抄一个常量。
const BEAMS: Array[Color] = [Color8(110, 230, 240, 150), Color8(110, 230, 240, 90),
	Color8(110, 230, 240, 30)]

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_refresh()
	# 取全局锚点：方块经常放在带偏移的房间节点下，本地坐标配全局坐标会整体偏一个父级偏移。
	# 这一行必须走在任何挪动之前 —— `_anchor` 定义的正是"摆在编辑器里的那一头"（收回态的前缘）。
	_anchor = global_position
	_reconnect_triggers()
	if Engine.is_editor_hint():
		return
	# 反向块的常态就是满行程：进树**瞬落**到那一头（用户裁 D63③），否则开局它得从洞里爬一秒
	# 才到位，而"回档落在一个正在动的落脚点"是不可读的那种重载（普通档的重载也是瞬落）。
	# 认的是 `rest_out` 而不是 `is_out`：常态是这块自己的属性，不该取决于这一刻有没有源把电平
	# 翻过去 —— 源在 `_ready` 时就踩着，说明那块本来就正被踩着，那就不是它的常态位。
	# 刻意不走 `_resolve()`：那一拍关卡刚搭好，把人让开这件事留给真在走的那一拍。
	if rest_out:
		global_position = _anchor + _unit * _span
	var ignored: float = maxf(absf(travel_offset.x) + absf(travel_offset.y) - _span, 0.0)
	if ignored > 1.0:
		push_warning("PistonBlock %s 的 travel_offset=%s 有两维分量：只认主轴 %s px，另一维 %s px 被忽略"
			% [name, str(travel_offset), str(_span), str(ignored)])


func _physics_process(_delta: float) -> void:
	# 编辑器守卫的理由见 door.gd 那条注释（全项目 @tool 构件共用）。
	if Engine.is_editor_hint():
		_poll_link_line()
		return
	var d: float = _receiver.get_physics_delta()
	var now: float = progress()
	# 线索只在"还没到位且世界在流"时画。这一条必须走在两个早退之前：冻结那一拍世界 delta
	# 归零，正是它该从画面上消失的一帧，而早退之后就没有第二个能把这个标志翻回去的机会了。
	# 判两端必须带容差、不能裸比 `now < 1.0`：`global_position` 经父级变换一个来回，满行程处
	# 读回来是 0.9999999，裸比等于让线索在到位之后永远亮着（实拍第 3 列抓出来的就是它）。
	var next_ticks: bool = d > 0.0 and not (is_equal_approx(now, 0.0) or is_equal_approx(now, 1.0))
	if next_ticks != _ticks:
		_ticks = next_ticks
		queue_redraw()
	if d <= 0.0 or _span <= 0.5:
		return
	var wanted: float = 1.0 if is_out else 0.0
	if is_equal_approx(now, wanted):
		return
	var speed: float = extend_speed if is_out else retract_speed
	var next: float = move_toward(now, wanted, speed * d / _span)
	global_position = _resolve(_anchor + _unit * _span * next)
	queue_redraw()


## 该伸出还是该缩回。留这个入口是给关卡脚本用的；接了 trigger 的活塞不需要它。
## **它说的是"哪一头"（位），不是"踩没踩"（电平）**：所以 `set_out(true)` 在反向档下同样是"伸到满
## 行程"，符号不套在这条路上（套了就成了同一份文档里两种意思）。下一次有任何源报状态时，
## `_refresh_out()` 会把这里写的值盖掉 —— 脚本驱动与接源驱动是互斥的两种用法，与接源时同理。
func set_out(value: bool) -> void:
	is_out = value


## 当前伸出量：0 = 埋在洞里，1 = 满行程。读的是**实际位置**而不是累计量 —— 被玩家顶住时这个数
## 自己就不涨，于是脱困那一帧不会把欠下的行程攒成一发弹射（moving_block 得靠速度封顶做同一件事）。
func progress() -> float:
	return clampf((global_position - _anchor).dot(_unit) / _span, 0.0, 1.0)


## 世界坐标下此刻方块占的那一截。守门拿它比对碰撞体（"碰撞体 == 画出来的"同一条判定，D36 第 6 条 b）。
func block_rect() -> Rect2:
	return rect_at(global_position)


## "节点落在 at 时方块占的那一截"。全局、本地两个帧都用它：传 `global_position` 得世界矩形，
## 传 `Vector2.ZERO` 得本地矩形（`_draw` 与 `_rebuild` 就这么用）。
func rect_at(at: Vector2) -> Rect2:
	return Rect2(at - _unit * _half - block_size * 0.5, block_size)


## 伸出途中把挡在行程上的人让开，返回这一帧真正允许落到的位置。
## 顺序是承重的：先让他自己的身体去撞地形（`Player.push_by`），他让开多少我们就能走多少；
## 他背后有墙 → 他自己停在墙上 → 再按他**停住之后**的后缘夹住我们的前缘，一寸都不许多走。
## 收回时整个跳过：那时前缘正从他脚下退开，把他往墙里推才是错的。
func _resolve(target: Vector2) -> Vector2:
	var hero := get_tree().get_first_node_in_group(&"player") as Player
	if hero == null or not is_out:
		return target
	var body: Rect2 = hero.collision_rect()
	# 前缘多探一格再判接触（D64）。人头顶着天花板、块每帧想走 1 px 又被 `_resolve` 夹回 0 px
	# 的那一档，两者长期**相切** —— 裸 intersects 一路报"没碰上"，push_by 就不再被叫，
	# Player 那侧的「被托着」每两帧翻一次，蹲伏判据跟着抖：卡住换了个形式回来。
	# 这一格容差不能改成"只比投影"：那会把 500 px 之外站着的人也一并推走，横向偏移得靠盒判定拦。
	# 也不能改成"留条缝"（试过 0.1 px 的分离量）：相切正是引擎把脚判成地面的唯一一档，
	# 拉开缝之后 `is_on_floor()` 永不成立，而 D64③ 对被托着的人钉住 `vy = 0` —— 满行程 + 宽限窗
	# 过期那一拍他会**自己站起来顶进天花板**，连蹲走自救都做不到。相切那一档物理引擎会做小幅
	# 分离松弛（实测沿行程轴 ±0.13 px、约 12 拍收敛），所以守门里那根"顶住不攒位移"的钉量的是
	# 容差而不是零。
	if not rect_at(target + _unit * CONTACT_TOLERANCE).intersects(body):
		return target
	# 洞口约定白送的那一项：原点的投影就是前缘，不用再补半个方块。
	var lead: float = target.dot(_unit)
	var back: float = _player_back(body)
	if lead > back:
		hero.push_by(_unit * (lead - back))
		body = hero.collision_rect()
		back = _player_back(body)
	if lead > back:
		return target - _unit * (lead - back)
	return target


## 玩家沿行程轴那一侧**后缘**的投影坐标。蹲着的人矮一档，所以读他的真矩形而不是套常量。
func _player_back(body: Rect2) -> float:
	return body.get_center().dot(_unit) - body.size.dot(_axis) * 0.5


## 轴、跨度、半长三样都从 travel_offset/block_size 派生，改任一个都要整组重算：
## `_half` 漏算会让碰撞体与前缘脱钩（原点约定就是靠它成立的）。
func _refresh() -> void:
	if absf(travel_offset.x) >= absf(travel_offset.y):
		_unit = Vector2(signf(travel_offset.x), 0.0)
	else:
		_unit = Vector2(0.0, signf(travel_offset.y))
	if _unit == Vector2.ZERO:
		# 零行程：哪儿也不去。给个单位向量免得下面除零，_span 已经小到推不出位移。
		_unit = Vector2.RIGHT
	_axis = _unit.abs()
	_span = maxf(absf(travel_offset.dot(_axis)), 0.001)
	_half = block_size.dot(_axis) * 0.5
	_rebuild()


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
## 运行期每次换一份独立的形状资源：多个活塞共用 .tscn 里那份 sub_resource 时，
## 改一块的 block_size 会把别块的碰撞盒也拽大（门踩过同一个坑，见 D21）。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != block_size:
		var shape := RectangleShape2D.new()
		shape.size = block_size
		_collision.shape = shape
	if _collision.position != -_unit * _half:
		_collision.position = -_unit * _half
	queue_redraw()


## 皮肤 + 编辑器辅助线。
func _draw() -> void:
	var editor := Engine.is_editor_hint()
	_draw_skin(1.0 if editor else progress(), editor)
	if editor:
		_draw_editor_guides()


## 皮肤的全部数字都写成"沿行程轴多远 / 离中轴多远"，再用下面两个换子换回本地坐标。
## 刻意不转画布：构件只走主轴，`_unit` 与它的垂直向量都是轴对齐的，所以两个换子就覆盖了横竖两档，
## 而 `draw_set_transform` 那一版要多接一个角度参数 —— 少一个能接错的地方，不是因为它错过。
## （第一版实拍曾"量出"竖直那档整张皮甩到前缘外面，那是取景框与探针都选错了，见 D49 那条假错。）
## 洞口线 `mouth` = -伸出量：节点原点就是"收回态的洞口"，所以鞘和缝虽然挂在这个会跑的
## 节点上画，落到屏幕上却是**钉在洞口**不动的（原点落在前缘这条约定的直接推论）。
func _draw_skin(e: float, editor: bool) -> void:
	var mouth: float = -e * _span
	var half: float = (block_size.y if _axis.x > 0.5 else block_size.x) * 0.5	# 横向半长
	# 露在外面的那一截身子。行程长于身子时不能越画越远 —— 块后面没有东西。
	var depth: float = minf(-mouth, _half * 2.0)
	if depth > 0.5:
		var body := _skin_rect(-depth, 0.0, -half, half)
		draw_rect(body, PLATE)
		draw_rect(body, PLATE_EDGE, false, 1.0)
	if depth >= 3.0:
		# 顶面那一组（内光 + 三道青光 + 实心青 + 亮白唇）。薄于 3 px 时它们会互相盖掉，
		# 不如只留轮廓：伸出到第一格的一半以后自然齐了。
		if depth > 18.0:
			draw_rect(_skin_rect(-depth + 4.0, -13.0, -half + 5.0, half - 5.0), PLATE_GLOW)
		for i in BEAMS.size():
			var axial: float = -(4.0 + i * 2.5)
			draw_line(_skin_point(axial, -half + 1.5), _skin_point(axial, half - 1.5), BEAMS[i], 1.0)
		draw_rect(_skin_rect(-3.0, -1.0, -half, half), PLATE_LIT)
		draw_rect(_skin_rect(-1.0, 0.0, -half, half), TREAD)
	# 洞口这一套与伸出量无关：收回态必须看得出"这儿有个洞，会有东西出来"。
	draw_rect(_skin_rect(mouth, mouth + 4.0, -half - 4.0, half + 4.0), SOCKET)
	draw_rect(_skin_rect(mouth + 3.0, mouth + 4.0, -half + 2.0, half - 2.0), SOCKET_LIP)
	draw_rect(_skin_rect(mouth - 2.0, mouth + 2.0, -half - 2.0, half + 2.0), MOUTH)
	for t in range(-half + 3.0, half - 1.0, 6.0):
		draw_rect(_skin_rect(mouth - 0.5, mouth + 0.5, t, t + 1.0), MOUTH_DOTS)
	# 运动线索：缝上两枚短线，指出它从哪儿出来。只在"还没到位且世界在流"时亮（见 `_ticks`）。
	if not editor and _ticks:
		for off in [-half + 11.0, half - 11.0]:
			draw_rect(_skin_rect(mouth - 3.5, mouth + 3.5, off - 0.5, off + 0.5), BEAMS[0])


## 横向单位向量与行程轴永远垂直，且两者都轴对齐 —— 所以"沿轴 a、离轴 b"这个点
## 不需要任何画布旋转就能直接落进本地坐标。
func _skin_point(axial: float, lateral: float) -> Vector2:
	return _unit * axial + Vector2(-_unit.y, _unit.x) * lateral


## 两个对角成一个正矩形。因为上面那条性质，两个对角必然轴对齐，取分量 min/abs 就正。
func _skin_rect(a0: float, a1: float, b0: float, b1: float) -> Rect2:
	var p := _skin_point(a0, b0)
	var q := _skin_point(a1, b1)
	return Rect2(Vector2(minf(p.x, q.x), minf(p.y, q.y)), (q - p).abs())


## 编辑器辅助线：行程线 + 前缘标记 + 满行程处的方块轮廓（**常态停着的那一头涂成实心**），
## 外加一条连到触发源的线。
## 画的是**算出来的**终点 `_unit * _span`，不是原始 travel_offset —— 所见必须等于所得。
func _draw_editor_guides() -> void:
	var line_color := Color(0.4, 1.0, 0.6, 0.6)
	var end: Vector2 = _unit * _span
	draw_line(Vector2.ZERO, end, line_color, 2.0)
	draw_circle(Vector2.ZERO, 5.0, line_color)
	# 常态那一头涂成半透明实心、另一头只留空心框。这是「同场景 + 一个开关」那条裁定欠的账：
	# 光看块分不出正装还是反装，而"没人踩着时它停在哪儿"恰好是摆图唯一要知道的一件事。
	draw_rect(rect_at(end if rest_out else Vector2.ZERO), Color(0.4, 1.0, 0.6, 0.16), true)
	draw_rect(rect_at(end), line_color, false, 1.0)
	for point in _link_points():
		draw_line(Vector2.ZERO, point, LINK_COLOR, 2.0)
		draw_circle(point, 5.0, LINK_COLOR)


## 每台源一条橙线。这一份几何同时是 `_poll_link_line()` 比较的对象 —— 画与"要不要重画"共用
## 一个来源，所以挪按钮时不会出现"线留在旧位置"那种半更新。
func _link_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	for source in _sources():
		points.append(to_local(source.global_position))
	return points


## 换触发源必须先解掉旧连接（同门）：留着老按钮照样能推这块，而场景里已经看不出接在哪儿。
## 多台时这条更要紧 —— 少解一台就是场上多一个隐形开关。
func _reconnect_triggers() -> void:
	if Engine.is_editor_hint():
		queue_redraw() # 编辑器里只需要重画那些辅助线，不接信号
		return
	var next: Array[Node] = []
	for path in triggers:
		var source: Node = _source_at(path)
		if source == null:
			continue
		if not source.has_signal(TRIGGER_SIGNAL):
			push_warning("活塞 %s 的 trigger %s 不发 %s，这台不参与合成" % [
				name, str(path), TRIGGER_SIGNAL])
			continue
		if not next.has(source):
			next.append(source)	# 同一台在列表里写两遍只算一家，否则一次按下会被接两次
	for prev in _bound:
		if not next.has(prev):
			_unbind(prev)
	_bound = next
	for source in next:
		var hooked := _on_source_changed.bind(source)
		if source.is_connected(TRIGGER_SIGNAL, hooked):
			continue	# 同一个源第二次被指到（列表里写了两遍，或改了列表但没换人）：不重复接
		source.connect(TRIGGER_SIGNAL, hooked)
		# 种子读各源当前的布尔量：只吃边沿的话，"进树时就已经踩着"的那台永远不算数。
		# 走 `get()` 而不是 `source.is_pressed`：契约只保证信号，属性名写死会让静态类型这里就编译不过。
		var flag: Variant = source.get(&"is_pressed")
		if flag == null:
			push_warning("活塞 %s 的 trigger %s 不发 %s 但没有 is_pressed：这台只吃边沿，进树时已按下的那一次会读不到" % [
				name, str(source.name), TRIGGER_SIGNAL])
		_state[source] = bool(flag) if flag != null else false
	_refresh_out()


func _unbind(source: Node) -> void:
	if not is_instance_valid(source):
		_state.erase(source)	# 键是已释放的对象，留着它就是一格永远读不到的僵尸状态
		return
	source.disconnect(TRIGGER_SIGNAL, _on_source_changed.bind(source))
	_state.erase(source)


## 列表里所有还解析得动的源。画线与接线都走它，所以"看到几条线"与"合成算几家"必然同源。
## 路径是相对本节点的，所以必须进树之后才解析得动。
func _sources() -> Array[Node]:
	var out: Array[Node] = []
	for path in triggers:
		var source: Node = _source_at(path)
		if source != null and not out.has(source):
			out.append(source)
	return out


func _source_at(path: NodePath) -> Node:
	if path.is_empty() or not is_inside_tree():
		return null
	return get_node_or_null(path)


## OR 合成：任一台按下就伸出，全部松开才收回。信号只负责"有一家的状态变了"，
## 真值一律从 `_state` 现算 —— 所以谁先谁后、同一拍里几台一起变，结果都一样。
func _on_source_changed(pressed: bool, source: Node) -> void:
	_state[source] = pressed
	_refresh_out()


func _refresh_out() -> void:
	var any := false
	for source in _bound:
		if is_instance_valid(source) and bool(_state.get(source, false)):
			any = true
			break
	_level = any
	# D63 的全部代码量就这一行：电平映射到哪一头。反向档不改合成、不改速度、不改皮。
	is_out = _level != rest_out


func _poll_link_line() -> void:
	var points: Array[Vector2] = _link_points()
	if points != _link_ends:
		_link_ends = points
		queue_redraw()
