@tool
class_name WorldClock
extends Node2D
## D59 世界钟（4 号样式：12 段走带）：全项目第一个**纯装饰构件** —— 它不改任何机制、
## 不发任何信号、不进 `run_state`，存在的理由只有一条：
## 「世界冻结」今天唯一的符号是全屏那层 CRT（D46），它说的是"画面变了"，
## 但没有一处东西在证明**本来该动的东西停了**。一只钟是这里唯一一个
## 动的理由就是世界时间在走的物件，所以它就是那条对照。
##
## 为什么不是装饰图集格：`TileMapLayer` 不能逐格动画（D56 那条），而这只钟的全部意义就是动。
##
## 时基（D59 裁定 D1①）：亮格序号 = `f(TimeManager.elapsed_world_time)` 的纯函数。
## 不累加 delta、不订阅 `state_changed`、不自带时钟 —— 于是三件事一起免费：
## 冻结即停（世界时钟本来就不涨）、死亡重载自动归位（`reset_state()` 把世界时钟清回 0）、
## 守门能当场断言"亮格 == f(世界时钟)"。与 D35 电棒的相位、D47 残影的位置同族。
## 唯一那份 `_shown` 是**重画缓存**不是状态：它只决定要不要 `queue_redraw()`，
## 画出来的是什么永远由世界时钟说了算，所以它错了也不会画错，只会多画一帧。
##
## 冻结那一拍不多给收据（D59 裁定 D4①）：不加运行灯、不变暗、不闪。
## CRT 已经把"冻结"铺满全屏，钟只负责"停的是世界、不是我"这一条对照；
## 再加一条是在跟全屏滤镜抢同一句话。
##
## 皮（D59 裁定 D3 = 选型图 4 号）：`assets/props/preview_clock.png` 里 D 那一行，用户看图批的。
## 下面 `_paint()` 逐像素照抄 `tools/gen_clock_preview.py::cand_segments` 的同一条算式
## （同一批半径、同一批色阶、同一圈描边），改一处要改两处。
## 零 PNG 零件，全部 1x1 矩形 —— 与全项目其余构件同一套语言。
##
## 节点原点 = 底边中心（与 Checkpoint / Collectible 同一套约定，不加第五个例外）。
## 整块 18x18 世界像素，所以本体在 `x ∈ [-9, 9]`、`y ∈ [-18, 0]`。
## @tool：编辑器里画 0 圈那一格（亮格在正上方），摆图定位用。

## 转一圈多少秒（世界时间）。12 段 ⇒ 一格 = period/12。填 0 = 不走，钉在第 0 格。
## 这一档与 `ElectricBar.period`、`Collectible.spin_period` 同性质：世界流动才走。
@export var period: float = 8.0

const BOX: int = 18
const TICKS: int = 12
## 圆心在**像素索引空间**里的位置（18x18 的正中是 8.5，不是 9）。
const CX: float = 8.5
const CY: float = 8.5
## 钢环外沿半径 / 环厚 / 环下那道暗唇 —— 与生成器 `_dial(c, cx, cy, 7.4, 8.0)` 同一条尺子。
const R_RING: float = 8.0
## 十二段走带所在的那一圈，和每段的半边长（3x3 方块）。
const R_BAND: float = 5.4
const SLOT_HALF: int = 1

## 风格 g 的在册色，与 tools/gen_clock_preview.py 同源，改一处要改两处。
const COL_LIP: Color = Color8(206, 222, 250)
const COL_LIP_DARK: Color = Color8(103, 111, 125)
const COL_SCREEN: Color = Color8(18, 24, 40)
const COL_LIT: Color = Color8(110, 230, 240)
const COL_TRAIL_1: Color = Color8(61, 127, 132)
const COL_TRAIL_2: Color = Color8(31, 64, 67)
## 未点亮的槽：比表盘亮一档，但要留在"这块东西"那一档，不能亮到跟那颗亮的抢语义。
const COL_UNLIT: Color = Color8(160, 163, 169)
## 贴纸语言那圈朝外的描边（D26 第 1 条）。
const COL_EDGE: Color = Color8(22, 26, 42)
## 网格里"这一格没有东西"那一档。
const COL_BLANK: Color = Color(0, 0, 0, 0)

## 上一次画出去的那一格。只是重画缓存，见文件头。
var _shown: int = -1


func _physics_process(_delta: float) -> void:
	# 编辑器里 TimeManager 是 placeholder 实例，读它不如钉在 0 圈那一格（_draw 已经这么画了）。
	if Engine.is_editor_hint():
		return
	var i := segment_index()
	if i != _shown:
		_shown = i
		queue_redraw()


## 当前亮着第几格。**世界时钟的纯函数**，与"这一帧有没有重画"无关 —— 守门钉的就是这条。
func segment_index() -> int:
	if period <= 0.0:
		return 0
	var t: float = 0.0 if Engine.is_editor_hint() else TimeManager.elapsed_world_time
	return int(fmod(t / period, 1.0) * float(TICKS)) % TICKS


func _draw() -> void:
	var grid := pixel_grid(segment_index())
	for y in BOX:
		for x in BOX:
			var c: Color = grid[y * BOX + x]
			if c.a > 0.0:
				draw_rect(Rect2(float(x) - BOX * 0.5, float(y) - float(BOX), 1.0, 1.0), c)


## 整块 18x18 的像素网格（`y*BOX+x`）。守门直接调这一条比对角与占格率 —— 无头没有渲染器，
## 但这两件事不需要画出来才验得着。
func pixel_grid(idx: int) -> Array[Color]:
	var grid: Array[Color] = []
	grid.resize(BOX * BOX)
	# typed array 的 resize() 填的是**不透明黑**、不是透明：不 fill 就是拿一块 18x18 的黑盒子
	# 糊在墙上，而且描边那一圈会因为"四邻都有人"整块消失。D59 落盘当天就是这么抓到的。
	grid.fill(COL_BLANK)
	_paint(grid, idx)
	# 描边那一圈要等整块画完再看 alpha，边才不会往里滚（与生成器 add_rim 同一条规矩）。
	_paint_rim(grid)
	return grid


## 逐像素照抄生成器：先铺圆盘（亮白环 + 暗唇 + 近黑表盘），再压十二段，最后那颗轴心。
func _paint(grid: Array[Color], idx: int) -> void:
	for y in BOX:
		for x in BOX:
			var dx := float(x) - CX
			var dy := float(y) - CY
			var r: float = sqrt(dx * dx + dy * dy)
			if r > R_RING:
				continue
			var c: Color = COL_SCREEN
			if r > R_RING - 1.0:
				c = COL_LIP
			elif r > R_RING - 1.7:
				c = COL_LIP_DARK
			_put(grid, x, y, c)
	for k in TICKS:
		var a: float = float(k) * TAU / float(TICKS)
		var sx := _r(CX + R_BAND * sin(a))
		var sy := _r(CY - R_BAND * cos(a))
		var back: int = posmod(idx - k, TICKS)
		var c: Color = COL_LIT if back == 0 else COL_TRAIL_1 if back == 1 \
			else COL_TRAIL_2 if back == 2 else COL_UNLIT
		for oy in range(-SLOT_HALF, SLOT_HALF + 1):
			for ox in range(-SLOT_HALF, SLOT_HALF + 1):
				_put(grid, sx + ox, sy + oy, c)
	_put(grid, _r(CX), _r(CY), COL_LIP)


## 朝外一圈描边：只在"自己空、四邻有人"的地方落笔，所以永远只有一圈。
func _paint_rim(grid: Array[Color]) -> void:
	var solid: Array[bool] = []
	solid.resize(BOX * BOX)
	for i in BOX * BOX:
		solid[i] = grid[i].a > 0.0
	for y in BOX:
		for x in BOX:
			var i := y * BOX + x
			if solid[i]:
				continue
			if (x > 0 and solid[i - 1]) or (x < BOX - 1 and solid[i + 1]) \
					or (y > 0 and solid[i - BOX]) or (y < BOX - 1 and solid[i + BOX]):
				grid[i] = COL_EDGE


func _put(grid: Array[Color], x: int, y: int, c: Color) -> void:
	if x < 0 or x >= BOX or y < 0 or y >= BOX:
		return
	grid[y * BOX + x] = c


## 生成器那侧的 round 是 Python 的"四舍六入五取偶"：8.5 落到 8。GDScript 的 round 会落到 9，
## 于是上下两格与轴心会整体偏一像素 —— 偏出来的还是一只钟，但就不是他批过的那张图了。
func _r(v: float) -> int:
	return int(ceil(v - 0.5))
