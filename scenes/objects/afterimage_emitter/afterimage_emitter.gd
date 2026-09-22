@tool
class_name AfterimageEmitter
extends Node2D
## 残影踏板（D47）：一只喷嘴定时生成一串匀速下坠的体素，流动期穿得过去、世界冻结时整条变实体。
##
## 节点原点 = **喷嘴口 = 第一格的顶边**，链朝 +y 落。刻意不守「底边中心」那条约定：
## 这东西是从天上往下掉的，摆图时唯一要定的就是"口子在哪、往下活多长"。拿底边当原点的话
## `reach` 得往负方向填，而且节点一挪整条链跟着跳。
##
## 主题 = CRT 余辉，是 D46 那条符号的推论而不是新设定：画面被钉住的那一刻，一直在落的
## 东西被钉在半空、成一串能踩的实体。所以"无形"与"有形"不是两个开关，是同一件事的两面 ——
## **它移动时无形、有形时不动**，所以它永远不会把人推着走。
## 但它**会**杀人（D47 那条"永远压不到人"已被 D48 订正）：世界转冻结那一帧，谁的身体还压在
## 格子里面，谁就被钉在里面 —— 判死走 HazardBase 同一个 `touched_player` 契约。
##
## 皮肤按 D48：流动 = 一坨竖向渐变的余辉 + 往上溶的尾迹 + 踩面一道暗线（没有描边），
## 冻结 = 实心青 + 顶唇一道亮白（和实体瓦片同一套话）。
##
## 位置是 `_clock` 的纯函数：第 k 格顶边在 `y = fmod(clock, T)·V + k·(V·T)`。不累加逐帧位移、
## 不实例化不销毁，于是按 R 重开、存档回灌、冻结期间天然停在原处三件事一起免费。
## 链是**预填**的（k=0 那格从装载第一帧就在射程里），机器不是从关卡装载那一刻才开始转。
##
## 单列不能沿列往上爬（D47：脚要升高一个节距，头先撞上上一格的底边，恒不成立）。它的动词是
## "跳起来、趁某一格落到脚下时冻结"，只能从外面跳进去。摆位三条硬约束见关卡手册 §5。

## 挡路层 = time_solid：玩家 `mask = 5` 天然读它，与 MovingBlock / Door / KeyDoor 同一层。
const SOLID_LAYER: int = 4
## 皮肤色 = 风格 g 的 accent / lip，与 tools/gen_afterimage_preview.py 同源，改一处要改两处。
const STEP_SOLID: Color = Color8(110, 230, 240)
const STEP_LIP: Color = Color8(206, 222, 250)
const STEP_EDGE: Color = Color8(61, 127, 132)
## 流动态（D48）：一坨正在溶的余辉，不给描边。身体上暗下亮（下面那侧是运动的先锋），
## 尾迹在身体**上方**往上溶到零 —— 余辉落在身后，这条方向顺便说清"它在往下落"。
const GHOST_TOP: Color = Color8(110, 230, 240, 26)
const GHOST_BOTTOM: Color = Color8(110, 230, 240, 72)
const TAIL_NEAR: Color = Color8(110, 230, 240, 34)
## 唯一保留的一条直线 = 踩面预告（格子的顶边）。暗到不足以被读成"实的"，
## 但判死带就压在这一格里，"哪儿算 inside"得看得见。
const TREAD_LINE: Color = Color8(206, 222, 250, 110)
## 只给编辑器的摆位辅助线用，比游戏内的残影清楚一档才不碍事。
const GUIDE: Color = Color8(110, 230, 240, 150)
const GUIDE_LIP: Color = Color8(206, 222, 250, 90)
const HOUSING: Color = Color8(124, 136, 176)
const HOUSING_DARK: Color = Color8(22, 26, 42)
## 喷嘴外壳占的那一块（原点以上），摆图时看得见的"这里在生成东西"。
const HOUSING_W: float = 24.0
const HOUSING_H: float = 12.0

## 判死契约（D48）：与 HazardBase 同名同签名。`LevelBase._bind_hazards` 按信号名全子树扫，
## 所以摆进关卡子树即接进死亡流程 —— 不拖引用、不新建第三套时钟；`_dying` 那道闩锁已经把
## "死在死亡那一拍里"挡掉（刷卡门/祭坛那两拍钉住冻结时同理，站着不动本来就不在该判死）。
signal touched_player(player: Node2D)

## 判死带相对整格内缩的余量。物理把人停在踩面上会留一丝穿透（实测 5e-6 px 量级），
## 内缩就把"踩住了"和"被钉在里面"分开。
const KILL_INSET: float = 2.0
## 判死只问**落脚点**：脚底往上这一条薄带。头被上一格蹭到不算 —— 节距 80 时站在踩面上
## 头顶离上一格只有 18 px，一松手链就追上来，拿身体重叠判死等于"松手即死刑"。
const FEET_PROBE: float = 2.0

## 下坠速度（px/s，世界时间）。常量而非加速：加速会让相邻两格的间隔随下落时间线性涨，
## "整条都是台阶"就只在一条窄带里成立（D47 被否的第 2 条）。
@export var fall_speed: float = 800.0:
	set(value):
		fall_speed = value
		queue_redraw()

## 生成间隔（秒，世界时间）。节距 = fall_speed × 它，是算出来的、不是手填的。
## 上限是"屏上至少两格"：T ≤ 房间净高 / (2V)，再大就读不出"一串在落的东西"。
@export var emit_interval: float = 0.40:
	set(value):
		emit_interval = maxf(value, 0.001)
		queue_redraw()

## 一格多大（正方形边长，px）。
@export var step_size: float = 32.0:
	set(value):
		step_size = value
		_rebuild()

## 喷嘴口往下，链活到多远。落出这个距离的格子既不存在也不画。
## 走 `_rebuild()` 而不是只重画：`active_steps()` 是它的函数，光重画会让新冒出来的
## 那几格带着过期位置被上层（冻结时 `_physics_process` 在 `_place()` 之前就 return 了）。
@export var reach: float = 320.0:
	set(value):
		reach = value
		_rebuild()

## 池子大小 = 同时存在的格数上限。要几格是 `reach / 节距 + 1`，超了截到这里并报警一次。
@export var max_steps: int = 8:
	set(value):
		max_steps = clampi(value, 1, 32)
		_rebuild()

## 世界时钟（秒），只在世界流动时累加。重载即归零 —— 与机关相位归零那条同一来源（D31 第 3 条）。
var _clock: float = 0.0
## 上一帧的实体态。只为"变了才重画、才碰碰撞层"。
var _was_solid: bool = false
var _warned_overflow: bool = false

var _bodies: Array[StaticBody2D] = []
var _shapes: Array[CollisionShape2D] = []

@onready var _receiver: TimeReceiver = $TimeReceiver


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	_was_solid = _receiver.get_physics_delta() <= 0.0
	_apply_layers(_was_solid)


func _physics_process(_delta: float) -> void:
	# 编辑器里 TimeReceiver 不会 _ready()，走它会碰到 TimeManager 的 placeholder 实例。
	if Engine.is_editor_hint():
		return
	var d: float = _receiver.get_physics_delta()
	var solid := d <= 0.0
	# 先定层再挪位：解冻那一帧格子紧接着就要动，晚一帧写层就等于拿一根刚出现的实体去顶
	# 已经站在它里面的人。冻结方向不用挪 —— 这一帧时钟没走，位置本来就是对的。
	_apply_layers(solid)
	if solid != _was_solid:
		_was_solid = solid
		queue_redraw()
		if solid:
			# 只在"刚刚变实体"这一帧查。流动期它本来就穿人而过、冻结期它自己又不动，
			# 每帧查是白查，还会在死亡那一拍里对着已经躺下的人反复点名。
			_check_imprisoned()
	if solid:
		return
	_clock += d
	_place()
	queue_redraw()


## 此刻有没有实体。编辑器里恒 true：摆图要看到的是最坏情形占的空间，
## 与 ElectricBar 编辑器里恒画 LIVE 同一个理由。
func is_solid() -> bool:
	if Engine.is_editor_hint():
		return true
	return _was_solid


## 世界时钟。守门用：钉"位置是它的纯函数"这条，运行期不该有人读它改它。
func world_clock() -> float:
	return _clock


## 第 k 格顶边相对喷嘴口的 y。纯函数：只吃 `_clock` 与三个导出项，不读上一帧的自己。
func step_top_y(k: int) -> float:
	return fmod(_clock, emit_interval) * fall_speed + float(k) * pitch()


## 相邻两格的竖直距离 —— 这个构件唯一的那个"间距"。
func pitch() -> float:
	return fall_speed * emit_interval


## 当前链上有几格。
func active_steps() -> int:
	return clampi(int(reach / maxf(pitch(), 0.001)) + 1, 1, max_steps)


func _place() -> void:
	var want := int(reach / maxf(pitch(), 0.001)) + 1
	if want > max_steps and not _warned_overflow:
		_warned_overflow = true
		push_warning("AfterimageEmitter：reach / 节距 要 %d 格，池子只有 %d —— 链被截短了"
			% [want, max_steps])
	var n := active_steps()
	for i in n:
		_bodies[i].position = Vector2(0.0, step_top_y(i) + step_size * 0.5)


## 层清 0 = 不在任何层上 = 什么都撞不到它。不动 shape、不动 position：
## 形状资源运行期独占一份（D27 第 7 条的坑），少一次写就少一份风险。
## 只给链上那几格上层：池子按 `max_steps` 建、链按 `reach / P` 画，两者默认就不等
## （8 vs 5）。整池一起上层的话，冻住时多余那几格会停在最后待过的位置上——
## 看不见却能踩，正是 D36 第 6 条「碰撞体 == 画出来的」那条判定要拦的东西。
func _apply_layers(solid: bool) -> void:
	var n := active_steps()
	for i in _bodies.size():
		var want: int = SOLID_LAYER if (solid and i < n) else 0
		if _bodies[i].collision_layer != want:
			_bodies[i].collision_layer = want


## 第 i 格在世界里的方块。刻意从格子自己的变换算，不按公式重算：
## 画的是它、撞的是它、判死的也是它，三者必须是同一个矩形（D36 第 6 条），
## 而拿全局变换算的话喷嘴被旋转或缩放也不会说谎。
func step_rect(i: int) -> Rect2:
	var half := step_size * 0.5
	var t := _bodies[i].global_transform
	var a := t * Vector2(-half, -half)
	var b := t * Vector2(half, half)
	return Rect2(a, b - a).abs()


## D48：冻结那一刻，谁的**落脚点**还被压在格子里，谁就被钉在里面 = 死。
## 站在踩面上不算、头被上一格蹭到也不算（见 FEET_PROBE）—— 这构件的用法就是站在一格
## 冻住的残影上，把"松手"变成死刑就没法玩了。
func _check_imprisoned() -> void:
	var hero := get_tree().get_first_node_in_group(&"player") as Player
	if hero == null:
		return
	var body := hero.collision_rect()
	var feet := Rect2(body.position.x, body.end.y - FEET_PROBE, body.size.x, FEET_PROBE)
	for i in active_steps():
		if step_rect(i).grow(-KILL_INSET).intersects(feet):
			touched_player.emit(hero)
			return


func _rebuild() -> void:
	if not is_node_ready():
		return
	while _bodies.size() > max_steps:
		# 立刻 free 不用 queue_free：后者要等这一帧结束，编辑器里把 max_steps 拖小再拖回来
		# 就会跟还没删掉的同名节点撞车（引擎默默改名，池子和索引就对不上了）。
		_bodies.back().free()
		_bodies.remove_at(_bodies.size() - 1)
		_shapes.remove_at(_shapes.size() - 1)
	while _bodies.size() < max_steps:
		var i := _bodies.size()
		var body := StaticBody2D.new()
		# 必须命名：不命名的话引擎给的是 `@StaticBody2D@6` 这种临时名，任何按路径捞子节点
		# 的写法（守门、自检、编辑器里手点）都捞不到，运行期建的东西反倒比 .tscn 里的更难查。
		body.name = "Rung%d" % i
		body.collision_mask = 0
		var shape_node := CollisionShape2D.new()
		shape_node.name = "CollisionShape2D"
		body.add_child(shape_node)
		add_child(body)
		_bodies.append(body)
		_shapes.append(shape_node)
	var size := Vector2(step_size, step_size)
	for shape_node in _shapes:
		var current := shape_node.shape as RectangleShape2D
		if current == null or current.size != size:
			var square := RectangleShape2D.new()
			square.size = size
			shape_node.shape = square
	_place()
	queue_redraw()


func _draw() -> void:
	var solid := is_solid()
	var half := step_size * 0.5
	for k in active_steps():
		var r := Rect2(-half, step_top_y(k), step_size, step_size)
		if solid:
			draw_rect(r, STEP_SOLID)
			draw_rect(r, STEP_EDGE, false, 1.0)
			# 顶唇：踩的就是这条。压两道亮白是刻意的，要它比瓦片的唇更"新"一档
			draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 2.0), STEP_LIP)
			draw_rect(Rect2(r.position.x - 1.0, r.position.y - 1.0, r.size.x + 2.0, 1.0), STEP_LIP)
		else:
			# 流动 = 穿得过去的残影。刻意不给整圈描边：一圈 1 px 的直线会被读成
			# "一块只是没填色的实心砖"，那正是 D47 那版 A 皮肤被裁掉的原因（D48）。
			_fade_rect(r.position.x, r.position.y, r.end.x, r.end.y, GHOST_TOP, GHOST_BOTTOM)
			# 尾迹比身体窄一档，免得整列连成一根柱子、读不出格的边界
			_fade_rect(r.position.x + 5.0, r.position.y - step_size, r.end.x - 5.0, r.position.y,
				Color(0.0, 0.0, 0.0, 0.0), TAIL_NEAR)
			draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 1.0), TREAD_LINE)
	_draw_housing()
	if not Engine.is_editor_hint():
		return
	# 摆图辅助：链活多远、每格的踩面在哪
	draw_line(Vector2(0.0, reach), Vector2(0.0, 0.0), GUIDE, 1.0)
	for k in active_steps():
		var y := float(k) * pitch()
		draw_line(Vector2(-half - 6.0, y), Vector2(half + 6.0, y), GUIDE_LIP, 1.0)


## 竖向渐变矩形：上边 `top`、下边 `bottom`，中间按顶点色插值。
## 用 draw_polygon 而不是叠几层 draw_rect：叠出来的台阶在暗底上看得出棱。
func _fade_rect(x0: float, y0: float, x1: float, y1: float, top: Color, bottom: Color) -> void:
	draw_polygon(
		PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]),
		PackedColorArray([top, top, bottom, bottom]))


func _draw_housing() -> void:
	var w := HOUSING_W * 0.5
	var box := Rect2(-w, -HOUSING_H, HOUSING_W, HOUSING_H)
	draw_rect(box, HOUSING)
	draw_rect(box, HOUSING_DARK, false, 1.0)
	draw_rect(Rect2(box.position.x, box.position.y, box.size.x, 2.0), STEP_LIP)
	# 出料口：唯一一处两态都恒亮的青，告诉玩家"口子在这儿、东西正从这里出来"
	draw_rect(Rect2(-4.0, -2.0, 8.0, 2.0), STEP_SOLID)
