@tool
class_name Checkpoint
extends Area2D
## P2 地台存档点（D31 / D35 第 7 条）：与按钮/祭坛同族的纯传感器 ——
## layer 8、mask 2、monitorable false，不做实体、不做台阶，主角踩在格线上终端脸朝上。
##
## 踩上即存（没有确认窗口），「存了」的全部反馈 = 终端纹理 idle → saved 的一次性换装
##（D31 第 4 条：反馈必须显式，否则玩家不知道自己存了）。
## 信号带的位置而非本体：LevelBase 接住写进 Main.run_state —— 跨重载的粘性状态
## 只住 Main（关卡场景每死一次就整个换掉，D31 第 1/2 条）。
##
## D51：哪一台是「当前存档点」不再由本构件自己记，改由 LevelBase 回 claim()/release()。
## 各台自存自亮的后果是同一条命踩过几台就几台常亮，而重载后新实例的标记全 false ——
## 重生位是对的、皮在撒谎。本构件仍然不认识别的存档点（D49 口径：协调归 LevelBase），
## 只被动挨点亮与熄灭，唯一的自判是「已经亮着的那台再踩不重复发信号」。
##
## 节点原点 = 底边中心（贴地），带心 -Player.COLLISION_HALF_HEIGHT 沿用地面传感契约：
## 蹲着也能存（D29 与 D27 交叉核对：蹲伏盒占 0-15，带子跨那条线）。
## 摆图硬数（D38 知情后果，进手册 §8）：离任何危险物留一个盒宽加视觉余量 ——
## 按着方向键死亡会在重载当帧再冻结，存档点自己必须是冻结中也安全的位置。
##
## @tool：编辑器里画 idle 态（摆图定位用）。

signal checkpoint_reached(position: Vector2)

## 此刻是不是「当前存档点」：只有这一台亮 saved 皮，也只有它才是重生位。
## 由 LevelBase 经 claim()/release() 维护（D51），本构件自己只在已亮着时不重复发信号。
var is_active: bool = false

const TEX_IDLE: Texture2D = preload("res://assets/props/terminal_idle.png")
const TEX_SAVED: Texture2D = preload("res://assets/props/terminal_saved.png")
## 踩踏带 32 宽 = idle 态终端的宽。已存态零件宽到 44 是 D45 故意的，带子不跟着长：
## 判定与零件尺寸无关（D38），换皮不该挪动玩家能存到档的位置。
const BAND_W: float = 32.0
const BAND_H: float = 24.0

@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	if is_active:
		return
	# 点亮由 LevelBase 回过来的 claim() 做（D51）：谁亮谁灭是关卡编排，不归构件。
	# 存的是「玩家该在哪里重生」：玩家原点在碰撞盒中心，地面点要抬半个盒高才是它。
	checkpoint_reached.emit(global_position + Vector2(0.0, -Player.COLLISION_HALF_HEIGHT))


## 点亮：成为当前存档点。只换皮、不发信号 —— 发信号的是踩上来的那一拍。
func claim() -> void:
	if is_active:
		return
	is_active = true
	queue_redraw()


## 熄灭：让位给更新的存档点，**或**让位给祭坛那一格（D62 —— 那条路上全场一台都不亮，
## 且不会有人来补点亮它，这是裁定不是漏做）。回 idle 皮不是坏了，是它在说实话（D51）。
func release() -> void:
	if not is_active:
		return
	is_active = false
	queue_redraw()


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(BAND_W, BAND_H):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(BAND_W, BAND_H)
		_collision.shape = shape
	var band := Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	if _collision.position != band:
		_collision.position = band
	queue_redraw()


func _draw() -> void:
	var tex := TEX_SAVED if is_active else TEX_IDLE
	# 两张零件**尺寸刻意不同**（idle 32×12 / saved 44×16）：D45 的读法全靠"已存"多出来的
	# 那 15 px 顶灯与两侧 6 px 青边，统一成一张的尺寸就等于把这条反馈裁掉。
	# 底边中心对齐 = 与节点原点同一套约定，于是换装时脚不会跳。
	draw_texture(tex, Vector2(-tex.get_width() * 0.5, -tex.get_height()))
