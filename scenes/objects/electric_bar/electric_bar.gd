@tool
class_name ElectricBar
extends HazardBase
## 电流棒（D34/D35）：两个极柱之间一道周期通断的光束，可浮空、可横可竖原地转。
##
## 节点原点 = **光束中心** —— 刻意的例外，不守「底边中心」那条约定：这根棒要原地
## 旋转（竖电闸 = 同一张横纹理 rotation 90，预览与引擎同一条合成路径），底边中心
## 对一根浮空棒没有意义，拿它当轴心转起来还甩。
##
## 相位（D38）：is_live = fmod(时钟 + phase*period, period) < duty*period。时钟只在
## 世界流动时走（TimeReceiver 的门控 delta），与 elapsed_world_time 同性质、同帧起步，
## 但走 TimeReceiver 契约 —— 第二章锚点时间流接进来时这根棒免费跟着走。
## 推论照抄 D35：玩家移动期间相位一分一毫不动（穿越绝对安全），真惩罚是中途松手；
## 断相位 ≥ 0.4 s 才读得清（摆图硬数，手册 §8）。
##
## 伤害与挡路是两条通道，由同一个 is_live() 驱动，永不矛盾（D29 第 3 条）：
## - 伤害 = 本类 Area2D 的判死盒，只罩光束那一带（高 10 = 束带 8 + 上下描边各 1），
##   极柱是钢不咬人；
## - 挡路 = Blocker 子节点（StaticBody2D，layer 4 = time_solid），只在 live 且
##   blocks_when_live 时上碰撞层，层清 0 即整根（含极柱）从物理上消失。极柱不常驻
##   实体是必须的：竖电闸断电要能走过去，底下一根实心柱就把谜题堵死了。
##   Blocker 高度取整条 18 px 纹带（比判死盒高）：站上通电棒当踏板的人（D35 第 4 条）
##   脚在极柱顶上，落不进判死带 —— 「踩着电走」才成立。
##
## 立绘 = bar_pole_l/r.png 10x18（两柱受光同侧，不是镜像）+ bar_live/off.png 16x18
## 平铺。OFF 那条虚线是「这里有一根棒、此刻没电」的唯一记号，必须原样平铺。
## @tool：改 length 立刻重画 + 重配两个盒；编辑器里恒画 LIVE —— 摆图要看到的是
## 最坏情形占的空间，不是某个随机相位。

## 光束净长（两柱之间的距离，px）。门形态的摆图硬数（D34 第 6 条）：
## 要么一端贴地另一端顶天花板，要么 ≥ 144（跳跃峰高 136 + 余量）。
@export var length: float = 128.0:
	set(value):
		length = value
		_rebuild()

## 通断周期（秒，世界时间）。≤ 0 视为常通电（没有相位可冻，退化成常开电墙）。
@export var period: float = 2.0

## 一个周期里通电的占比（0..1]。断相位的世界时长 = (1-duty)*period，≥ 0.4 s 才读得清。
@export var duty: float = 0.5

## 相位（0..1）。多根棒要错开节奏时调它；同相位同周期的棒会同步闪。
@export var phase: float = 0.0

## 通电时是否挡路。true = 门形态（一堵会周期消失的墙）；false = 浮空形态
## （不挡路、一条要挑时机穿过去的电，也是「撒手才掉的踏板」，D35 第 4 条）。
@export var blocks_when_live: bool = false

const TEX_POLE_L: Texture2D = preload("res://assets/props/bar_pole_l.png")
const TEX_POLE_R: Texture2D = preload("res://assets/props/bar_pole_r.png")
const TEX_LIVE: Texture2D = preload("res://assets/props/bar_live.png")
const TEX_OFF: Texture2D = preload("res://assets/props/bar_off.png")
const POLE_W: float = 10.0
const STRIP_H: float = 18.0
## 判死带高度：束带 8 px + 上下描边各 1，正好罩住画出来的可见带。
const KILL_H: float = 10.0
## 挡路层 = time_solid（D29 第 3 条）：玩家 mask=5 天然读它，不新发明层。
const BLOCK_LAYER: int = 4

## 世界时钟（秒）。重载即归零 —— 与机关相位归零那条粘性规则同一来源（D31 第 3 条）。
var _clock: float = 0.0
## 上一帧的通断，只为「变了才重画、才碰 Blocker」。
var _was_live: bool = true

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _kill: CollisionShape2D = $CollisionShape2D
@onready var _blocker: StaticBody2D = $Blocker
@onready var _blocker_shape: CollisionShape2D = $Blocker/BlockerShape


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	var live := is_live()
	_was_live = live
	_apply_blocker(live)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_clock += _receiver.get_physics_delta()
	var live := is_live()
	if live != _was_live:
		_was_live = live
		queue_redraw()
		_apply_blocker(live)
	# 先走完这一帧的时钟再让基类扫描，判死看到的才是新相位。
	super(delta)


func is_live() -> bool:
	if Engine.is_editor_hint():
		return true
	if period <= 0.0:
		return true
	var d := clampf(duty, 0.01, 1.0)
	return fmod(_clock + clampf(phase, 0.0, 1.0) * period, period) < d * period


## 判死盒罩光束（含极柱也行不通：柱子不伤人）；Blocker 罩整根棒（含极柱）。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var kill_rect := _kill.shape as RectangleShape2D
	if kill_rect == null or kill_rect.size != Vector2(length, KILL_H):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(length, KILL_H)
		_kill.shape = shape
	var block_rect := _blocker_shape.shape as RectangleShape2D
	var block_size := Vector2(length + POLE_W * 2.0, STRIP_H)
	if block_rect == null or block_rect.size != block_size:
		var shape := RectangleShape2D.new()
		shape.size = block_size
		_blocker_shape.shape = shape
	queue_redraw()


## 层清 0 = 不在任何层上 = 什么都撞不到它。不动 shape、不动 monitorable：
## 形状资源运行期独占一份（D27 第 7 条的坑），少一次写就少一份风险。
func _apply_blocker(live: bool) -> void:
	var want: int = BLOCK_LAYER if (live and blocks_when_live) else 0
	if _blocker.collision_layer != want:
		_blocker.collision_layer = want


func _draw() -> void:
	var x0: float = -(length + POLE_W * 2.0) * 0.5
	var pole_rect := Rect2(0.0, 0.0, POLE_W, STRIP_H)
	draw_texture_rect_region(TEX_POLE_L, Rect2(x0, -STRIP_H * 0.5, POLE_W, STRIP_H), pole_rect)
	draw_texture_rect_region(TEX_POLE_R,
		Rect2(x0 + POLE_W + length, -STRIP_H * 0.5, POLE_W, STRIP_H), pole_rect)
	TileDraw.tile(self, TEX_LIVE if is_live() else TEX_OFF,
		x0 + POLE_W, -STRIP_H * 0.5, length, STRIP_H)
