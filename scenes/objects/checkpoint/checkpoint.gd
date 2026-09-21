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
## 节点原点 = 底边中心（贴地），带心 -Player.COLLISION_HALF_HEIGHT 沿用地面传感契约：
## 蹲着也能存（D29 与 D27 交叉核对：蹲伏盒占 0-15，带子跨那条线）。
## 摆图硬数（D38 知情后果，进手册 §8）：离任何危险物留一个盒宽加视觉余量 ——
## 按着方向键死亡会在重载当帧再冻结，存档点自己必须是冻结中也安全的位置。
##
## @tool：编辑器里画 idle 态（摆图定位用）。

signal checkpoint_reached(position: Vector2)

## 本条命内已存过：一次性，再踩同一个点无事可做。换点由另一个 Checkpoint 发它自己的信号。
var is_saved: bool = false

const TEX_IDLE: Texture2D = preload("res://assets/props/terminal_idle.png")
const TEX_SAVED: Texture2D = preload("res://assets/props/terminal_saved.png")
## 踩踏带：终端 32 宽，带子同宽；高度沿用按钮那条带的量。
const BAND_W: float = 32.0
const BAND_H: float = 24.0

@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	if is_saved:
		return
	is_saved = true
	queue_redraw()
	# 存的是「玩家该在哪里重生」：玩家原点在碰撞盒中心，地面点要抬半个盒高才是它。
	checkpoint_reached.emit(global_position + Vector2(0.0, -Player.COLLISION_HALF_HEIGHT))


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
	var tex := TEX_SAVED if is_saved else TEX_IDLE
	draw_texture_rect_region(tex, Rect2(-16.0, -12.0, 32.0, 12.0), Rect2(0.0, 0.0, 32.0, 12.0))
