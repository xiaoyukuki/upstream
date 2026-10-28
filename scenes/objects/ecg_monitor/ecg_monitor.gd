@tool
class_name EcgMonitor
extends Node2D
## D75 心电监护屏（会波动的那块实验室墙屏）：第二件**纯装饰构件**，与 D59 那只世界钟同一族 ——
## 不改任何机制、不发信号、不进 `run_state`、零碰撞体、也不进 `anchorable` 族。
## 注：`verify_kit` 那份禁令扫的是**剥掉注释之后的源码文本**（D75 当天先按"整份文件"扫，被自己文件头里的一次提及判红；反过来只把那句写进注释又能骗过禁令 —— 两头都是假收据，已改成只看代码行）。
##
## 它存在的理由与世界钟是同一条，但教的正好是反方向那一面：钟说"本来在动的东西停了"，
## 而这块屏上那条波形**一直在推**，冻住那一拍它停在同一个形状上 —— 于是"停的是世界"
## 在同一面墙上有了第二个读数，而且它比钟更像"仪器"：钟可以读成"没人上弦"，
## 一条走到一半停住的波形只有一种解释。
##
## 为什么不是装饰图集格：`TileMapLayer` 的图集动画没有门控入口（本机探针：`TileMapLayer`
## 的属性与方法里 `anim` 相关 0 条，只有 `TileSetAtlasSource` 那套声明式 `set_tile_animation_*`，
## 走引擎自己的时钟）。用它 = 世界冻住屏还在跳 = 皮说谎。与 D59「为什么不是装饰图集格」同一条，
## D56 早就记过。
##
## 时基（照 D59 裁定 D1①，一字不改）：相位 = `f(TimeManager.elapsed_world_time)` 的纯函数。
## 不累加 delta、不订阅 `state_changed`、不自带时钟 —— 于是冻结即停、死亡重载自动归位、
## 换关不漂，而守门能当场断言"相位 == f(世界时钟)"。唯一那份 `_shown` 是重画缓存不是状态。
##
## 皮：**与图集里那块 `monitor` 瓦片逐像素同源** —— `tools/gen_tiles.py::decor_monitor` 与这里
## 的 `_paint()` 是同一道算式的两处书写（同一批矩形、同一串 `PATTERN` 偏移、同一批在册色）。
## 钉它的不是"我记得两边一样"，是 `verify_kit._verify_ecg_monitor()`：它把落盘的
## `tilesheet_decor.png` 上那块 48×32 裁下来，与 `pixel_grid(0)` **逐格比色**，
## 差一格就红。所以相位 0 = 那块瓦片原样，而 1~13 是它横向推过一格的样子。
## 波形因此不能再用 `d.line` 画（Bresenham 在 dx=1、dy 最大 7 的段上每列只落一个点，
## GDScript 那半边抄不动）—— 两边都改成"逐列画从上一列 y 到这一列 y 的竖条"。
##
## 冻结那一拍不多给收据（照 D59 裁定 D4①）：不变暗、不闪、不加"待机灯"。
## CRT 那层已经把"冻结"铺满全屏，这块屏只负责"波形停了"这一条对照。
##
## 节点原点 = **盒子中心**（走"块心"那一族，与移动方块 / 两件相位器件同一读法，不新增例外）。
## 整块 48×32 世界像素，所以本体在 `x ∈ [-24, 23]`、`y ∈ [-16, 15]`。
## 它是**挂在墙上**的仪器，没有"压住地格线"那一点 —— 拿底边当原点会谎报它有一双脚。
## @tool：编辑器里画相位 0（就是瓦片原样），摆图定位用。

## 波形推过一整个尖峰组（14 列 = 一拍）要多少秒世界时间。默认 0.84 s ≈ 每分钟 71 跳，
## 一列 = 60 ms —— 静息心率那一档，读起来是"仪器在量一个人"而不是"屏幕在闪"。
## 填 0 或负数 = 不走，钉在相位 0（= 与那块瓦片一模一样）。与 `WorldClock.period` 同性质。
@export var beat_period: float = 1

const BOX_X: int = 48
const BOX_Y: int = 32
## 屏幕内沿（生成器那句 `sx0, sy0, sx1, sy1 = x+3, y+3, x+w-4, y+h-6`）。42 列宽 = 3 个整周期，
## 所以横向滚动时接缝处不断。
const SX0: int = 3
const SY0: int = 3
const SX1: int = 44
const SY1: int = 26
const MID: int = (SY0 + SY1) / 2
## 那串纵向偏移，周期 14 列（一拍：P 波 → QRS 尖 → T 波）—— 与 `gen_tiles.ECG_PATTERN` 同一份。
const PATTERN: Array[int] = [0, 0, -1, -2, -1, 0, 0, 0, -6, 7, -3, 0, 1, 0]
## 四角抠掉的格数（`gen_tiles.CHAMFER[3]`：第 0 行抠 2 格宽、第 1 行抠 1 格，四角镜像）。
const CHAMFER: Array[int] = [2, 1]

## 风格 g 的在册色，与 `tools/gen_tiles.py::decor_monitor` 同源，改一处要改两处（守门逐格核）。
## 两份都照**落盘图集**那一份，不照生成器的半成品：`build_decor_atlas` 的 soft 补笔会在瓦片外沿
## 再压一圈 `edge`，于是生成器画的那 1px 外壳环与压在底行的底舌在成品里全都看不见 ——
## 这里对外壳直接描边、不画底舌，才与那块瓦片逐格相等。
const COL_EDGE: Color = Color8(22, 26, 42)          # edge 描边（非平铺件必须有，D26 第 1 条）
const COL_BEZEL: Color = Color8(97, 106, 137)       # darker(metal, .22) 内框
const COL_SCREEN: Color = Color8(18, 24, 40)        # screen 近黑表盘
const COL_TRACE: Color = Color8(110, 230, 240)      # accent 那条波形（青 = 光与电，D29）
const COL_FOOT: Color = Color8(11, 14, 24)          # darker(screen, .4) 屏底暗条
const COL_LED_AMBER: Color = Color8(250, 190, 74)
const COL_LED_CYAN: Color = Color8(110, 230, 240)
const COL_LED_WHITE: Color = Color8(240, 240, 240)
const COL_BLANK: Color = Color(0, 0, 0, 0)

## 上一次画出去的相位。只是重画缓存，见文件头。
var _shown: int = -1


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var i := phase()
	if i != _shown:
		_shown = i
		queue_redraw()


## 当前推到第几列。**世界时钟的纯函数**，与"这一帧有没有重画"无关 —— 守门钉的就是这条。
func phase() -> int:
	if beat_period <= 0.0:
		return 0
	var t: float = 0.0 if Engine.is_editor_hint() else TimeManager.elapsed_world_time
	return int(fmod(t / beat_period, 1.0) * float(PATTERN.size())) % PATTERN.size()


func _draw() -> void:
	var grid := pixel_grid(phase())
	for y in BOX_Y:
		for x in BOX_X:
			var c: Color = grid[y * BOX_X + x]
			if c.a > 0.0:
				draw_rect(Rect2(float(x) - float(BOX_X) * 0.5,
						float(y) - float(BOX_Y) * 0.5, 1.0, 1.0), c)


## 整块 48x32 的像素网格（`y*BOX_X+x`）。守门拿它与落盘图集上那块瓦片逐格比对 ——
## 无头没有渲染器，但"画的是哪些像素"这件事不需要画出来才验得着。
func pixel_grid(idx: int) -> Array[Color]:
	var grid: Array[Color] = []
	grid.resize(BOX_X * BOX_Y)
	# typed array 的 resize() 填的是**不透明黑**、不是透明：不 fill 就是一块 48×32 的黑盒子
	# 糊在墙上（D59 那条环境坑，这里照防）。
	grid.fill(COL_BLANK)
	_paint(grid, idx)
	return grid


## 逐像素照抄生成器的**成品**：描边 → 内框 → 表盘 → 波形（逐列竖条）→ 屏底暗条 → 三颗灯 → 抠角。
func _paint(grid: Array[Color], idx: int) -> void:
	_rect(grid, 0, 0, BOX_X - 1, BOX_Y - 1, COL_EDGE)
	_rect(grid, 1, 1, BOX_X - 2, BOX_Y - 2, COL_BEZEL)
	_rect(grid, SX0, SY0, SX1, SY1, COL_SCREEN)
	for i in range(SX1 - SX0 + 1):
		var a: int = MID + PATTERN[posmod(i - 1 + idx, PATTERN.size())]
		var b: int = MID + PATTERN[posmod(i + idx, PATTERN.size())]
		_rect(grid, SX0 + i, mini(a, b), SX0 + i, maxi(a, b), COL_TRACE)
	_rect(grid, SX0, SY1 - 1, SX1, SY1, COL_FOOT)
	for k in 3:
		var c: Color = COL_LED_AMBER if k == 0 else COL_LED_CYAN if k == 1 else COL_LED_WHITE
		_rect(grid, 4 + k * 4, BOX_Y - 3, 5 + k * 4, BOX_Y - 3, c)
	for k in CHAMFER.size():
		for i in CHAMFER[k]:
			for cx in [i, BOX_X - 1 - i]:
				for cy in [k, BOX_Y - 1 - k]:
					grid[cy * BOX_X + cx] = COL_BLANK


func _rect(grid: Array[Color], x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x >= 0 and x < BOX_X and y >= 0 and y < BOX_Y:
				grid[y * BOX_X + x] = c
