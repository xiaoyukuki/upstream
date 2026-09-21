class_name DeathBurst
extends Node2D
## 死亡那一拍的爆裂液滴（D42 选型 D「收缩 + 爆裂」）。
##
## 14 滴「小史莱姆」从胸口高度径向射出，走一条抛物线，落回脚底那条线就收。
## 每一滴两笔 draw_rect：先一圈亮边、再往里填身体色 —— 与主角本身同一套配色，
## 不出新帧、不上粒子系统。位置是解析式（p = p0 + v·t + ½g·t²），没有状态要维护，
## 重载即归零。算式与 tools/gen_death_preview.py 的 D 行逐字同源：图上的位置 = 实机的位置。
##
## 计时与 `Player._advance_death()` 同一条固定物理步长、同一个时长（`launch()` 由 die() 传进来），
## 所以「身体缩没」与「液滴溅完」同拍结束。世界那道闸只截 `TimeReceiver` 的门控 delta，
## 截不到固定步长（D41 第 4 条），于是世界钉在冻结里、液滴照样飞完这一拍。
##
## 节点挂在 Player 下、Visual 之后：画在身体之上，且不吃 Visual 那份正在缩的缩放。

const DROP_GRAVITY: float = 900.0
## 脚底在本节点原点下方 15 px。刻意不写 `Player.COLLISION_HALF_HEIGHT` ——
## Player 已经按类型引用本类，本类再反向引用 Player 就成了 GDScript 的循环解析，
## 一个数换一条注释更便宜。改那条常量时记得回来改这里。
const FEET_Y: float = 15.0
## 出射点在脚底上方 12 px（≈胸口）：从脚底溅读作「脚下打滑」，从胸口溅才读作「被咬穿了」。
const ORIGIN_Y: float = FEET_Y - 12.0
## 身体色与主角那道亮边（gen_tiles 的 g2.player_rim）。
const COLOR_BODY := Color(0.039, 0.047, 0.047)
const COLOR_RIM := Color(0.808, 0.871, 0.980)
## 淡出起点：前 55% 满不透明，之后线性掉到 0，与身体的淡出同一档。
const FADE_FROM: float = 0.55

## (出射角 度、0 = 正右、逆时针为负 / 初速 世界像素每秒 / 边长 世界像素)。
const DROPS: Array = [
	[-178.0, 112.0, 3.0], [-156.0, 138.0, 2.0], [-134.0, 162.0, 4.0], [-112.0, 180.0, 3.0],
	[-90.0, 190.0, 2.0], [-68.0, 176.0, 4.0], [-46.0, 156.0, 3.0], [-24.0, 132.0, 2.0],
	[-2.0, 106.0, 3.0], [20.0, 82.0, 4.0], [40.0, 62.0, 2.0], [156.0, 116.0, 3.0],
	[186.0, 96.0, 2.0], [214.0, 74.0, 3.0],
]

## -1 = 不在演出中，否则是已经飞了多少秒（固定物理步长）。
var _elapsed: float = -1.0
var _time: float = 0.0


## 由 `Player.die()` 调用，时长与身体那一拍共用一个来源。
func launch(duration: float) -> void:
	_time = maxf(duration, 0.001)
	_elapsed = 0.0
	queue_redraw()


## 这一拍还在飞吗。守门用，避免外部翻 `_elapsed` 这个私有读数。
func is_active() -> bool:
	return _elapsed >= 0.0


func _physics_process(delta: float) -> void:
	if _elapsed < 0.0:
		return
	_elapsed += delta
	if _elapsed >= _time:
		_elapsed = -1.0
	queue_redraw()


func _draw() -> void:
	if _elapsed < 0.0:
		return
	var t: float = _elapsed
	var progress: float = clampf(t / maxf(_time, 0.001), 0.0, 1.0)
	var alpha: float = 1.0 if progress < FADE_FROM \
		else maxf(0.0, 1.0 - (progress - FADE_FROM) / (1.0 - FADE_FROM))
	if alpha <= 0.0:
		return
	for drop: Array in DROPS:
		var rad: float = deg_to_rad(drop[0])
		var x: float = cos(rad) * drop[1] * t
		var y: float = ORIGIN_Y + sin(rad) * drop[1] * t + 0.5 * DROP_GRAVITY * t * t
		var size: float = drop[2]
		if y > FEET_Y - size:
			continue
		var rect := Rect2(x - size * 0.5, y - size * 0.5, size, size)
		draw_rect(rect, Color(COLOR_RIM.r, COLOR_RIM.g, COLOR_RIM.b, alpha))
		draw_rect(rect.grow(-1.0), Color(COLOR_BODY.r, COLOR_BODY.g, COLOR_BODY.b, alpha))
