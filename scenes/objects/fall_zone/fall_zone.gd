@tool
class_name FallZone
extends HazardBase
## 坠落带（D52）：接住"掉出世界"这条没有兜底的路。
##
## 判死与重载全走现成那条链，本构件只发 `touched_player`：
## `LevelBase._bind_hazards()` 按信号名自动接线 → `_on_hazard_touched()` → `Player.die(death_time)`
## → `death_finished` → `Main.reload_level()`。**只有死亡重载保留 `run_state`**，
## 所以掉进坑里回的是最近那台存档点、祭坛仍摆成已耗；主动重开（R / 终点收尾）走的是
## `restart_level()`，那条按设计清空进度，两件事别混。
##
## 节点原点 = **顶边中心**，与其余贴地构件那个"底边中心"反过来。理由：这张网唯一需要
## 摆的量是"顶边线压在哪条 y 上"，原点落在线上才拖得走；深度由 `depth` 往下给，
## 摆图的人不必再算半个高度。
##
## 带子只认玩家（mask 2）、自己不被探测（monitorable=false）、不上任何实体层（layer 0）
## —— 与 HazardBase 家族同口径，`verify_kit` 按信号名扫危险物时自动收到它。
##
## 为什么默认深 2048 px 而不是"算到位"：无底洞里的下落速度不设上限，带子薄了就会在一拍
## 物理里整段穿过去（`HazardBase` 逐帧扫重叠而不是靠 entered，穿的仍是这条带子的体积）。
## 两屏多的深度比量一个临界速度便宜，也免得多摆几层。
##
## @tool：改 width/depth 立刻重画。带子默认只在编辑器里画出来，运行时是隐形的（同
## SensorZone 那条口径）—— 世界底部的辅助线不该进画面。

## 带的横向宽度（px）。必须盖过整关所有"能走出去"的边缘，漏一段就等于那段没兜底。
@export var width: float = 1024.0:
	set(value):
		width = value
		_rebuild()

## 从顶边线往下延多深（px）。默认两屏多，见文件头那条"为什么不算临界速度"。
@export var depth: float = 2048.0:
	set(value):
		depth = value
		_rebuild()

## 打开时运行时也画出来（默认关）。调试"人到底从哪一格开始算掉出去"时用。
@export var visible_in_game: bool = false:
	set(value):
		visible_in_game = value
		_rebuild()

## 辅助线颜色：顶边那条实线 + 下面极淡的体积。刻意不导出 —— 这不是玩法旋钮，
## 也不是要进 props.json 对账的构件色。
const COLOR_EDGE := Color(0.95, 0.35, 0.3, 0.85)
const COLOR_BAND := Color(0.95, 0.35, 0.3, 0.07)

@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(width, depth):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(width, depth)
		_collision.shape = shape
	# 原点是顶边，所以盒心在原点正下方半个深度。
	var band_center := Vector2(0.0, depth * 0.5)
	if _collision.position != band_center:
		_collision.position = band_center
	queue_redraw()


func _draw() -> void:
	if not (visible_in_game or Engine.is_editor_hint()):
		return
	draw_rect(Rect2(-width * 0.5, 0.0, width, depth), COLOR_BAND)
	draw_rect(Rect2(-width * 0.5, -1.0, width, 2.0), COLOR_EDGE)
