class_name GrantBeams
extends Node2D
## 能力获取那一拍的光柱（D61）：十二根白色楔形，顶点钉在胸口、往外张开顶出屏幕，
## 整段一边变粗一边绕主角转半圈，到爆发那一帧正好铺满，再用三帧把亮度散干净。
##
## 全部是 `_draw` 出来的，没有一颗贴图：这张图的正确尺寸取决于取景框（视口半对角 367 世界 px），
## 烤成 PNG 就要按最大档画一张再缩放 —— 与"构件保持 ab 配色、尺寸是活旋钮"那条口径同一路。
## 也因此它不需要 .import、不进清单、没有摆图旋钮，所以由 `Player._ready()` 造出来排在 Visual
## 之前（画在身体背后），本文件里没有一处 @export。
##
## 时间轴只有一个来源：`source.grant_progress()`（0..1）。帧号 = 进度 × `Player.GRANT_FRAMES`，
## 与 `grant` 剪辑（16 帧 / 3.2 fps）、`Player.GRANT_LIFT`、祭坛那三枚环读的是同一格。
## 刻意每渲染帧都重画一遍、不按皮那 3.2 fps 跳着走 —— 转速的频闪上限是「根与根间隔的一半」
## （12 根 = 15 度），只有逐渲染帧推进才走得到半圈不抖；选型图里那条 20 度/皮帧 的担心
## 在实机不成立，收据见 docs/architecture_chapter_01.md 的 D61。
##
## 世界被钉住的那一拍（爆发窗口）它照样长：读的是玩家自己的时钟，不是 `TimeReceiver`。

var source: Player

## 上一帧画到哪儿。只为"没变化就不重画"存在 —— 这一拍之外它恒为 -1，节点于是完全静止。
var _shown: float = -1.0

## 根数与张角：选型图 W12 那一行（12 根细、整根 9 度 = 半张角 4.5）。
const RAYS: int = 12
const HALF_SPREAD: float = 4.5
## 顶到最远那一档的长度（世界 px）。视口 640×360 的半对角是 367，480 是"一定顶出画面"的下限。
const REACH: float = 480.0
## 整段行程绕主角转的圈数（用户第三轮原话"围绕主角旋转"）：半圈。
const SPIN_TURNS: float = 0.5
## 起步时张角只有终值的 12% —— "从细变粗"的起点不是零宽度（那是一条看不见的线，等于没有）。
const WIDEN0: float = 0.12
## 不透明度在行程前 15% 从 0 拉到满，之后不再淡："消失"那一拍交给下面的散三帧。
const FADE_IN: float = 0.15
## 全局亮度 45%（定案）。满 100% 时那十二根白楔会把主角整个冲没，图里量过。
const BRIGHTNESS: float = 0.45
## 散三帧：从爆发那一帧起线性收到零，几何长度已经到位就不动了 —— 铺满的光再往回缩
## 读作"往里吸"，不是散去。
const DISOLVE_FRAMES: float = 3.0
## 在册亮白（全 kit 没有纯白）：与 `gen_grant_preview.FLASH_COLOR` 同一个数。
const BEAM_COLOR: Color = Color(236.0 / 255.0, 246.0 / 255.0, 252.0 / 255.0)


func _process(_delta: float) -> void:
	var next: float = -1.0 if source == null else source.grant_progress()
	if next == _shown:
		return
	_shown = next
	queue_redraw()


func _draw() -> void:
	if _shown < 0.0:
		return
	var tf: float = _shown * float(Player.GRANT_FRAMES)
	# 行程：到爆发那一帧正好铺满（k=1），之后长度不再动。
	var k: float = clampf(tf / float(Player.GRANT_BURST_FRAME), 0.0, 1.0)
	var alpha: float = BRIGHTNESS * minf(1.0, k / FADE_IN) \
		* clampf(1.0 - (tf - float(Player.GRANT_BURST_FRAME)) / DISOLVE_FRAMES, 0.0, 1.0)
	var ease: float = 1.0 - (1.0 - k) * (1.0 - k)
	var r1: float = ease * REACH
	var spread: float = HALF_SPREAD * (WIDEN0 + (1.0 - WIDEN0) * k)
	if alpha <= 0.0 or r1 <= 1.0 or spread <= 0.05:
		return
	var half: float = tan(deg_to_rad(spread)) * r1
	var spin: float = SPIN_TURNS * 360.0 * k
	var apex := Vector2(0.0, Player.CHEST_Y)
	for j in RAYS:
		var dir := Vector2.RIGHT.rotated(deg_to_rad(-90.0 + 360.0 * float(j) / float(RAYS) + spin))
		var perp := Vector2(-dir.y, dir.x)
		var tip := apex + dir * r1
		draw_colored_polygon(PackedVector2Array([apex, tip + perp * half, tip - perp * half]),
			Color(BEAM_COLOR.r, BEAM_COLOR.g, BEAM_COLOR.b, alpha))
