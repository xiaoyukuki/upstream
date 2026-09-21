@tool
class_name AbilityAltar
extends Area2D
## 能力祭坛（D44）：踩上即一次性发 `ability_granted`，石头留在原地，凹槽里只剩一圈烧灼青印。
##
## 美术是选型图批过的 A1「阶梯石台 + 悬浮核心」：三张平铺件（base / shaft / cap）加三张居中件
## （groove / burn / core），全部来自 `py tools/gen_props.py --emit`，与
## `assets/props/preview_altar.png` 的 A1 行同一批像素（D34 那条纪律）。
## 之所以不烤成一张整图：`width` / `altar_height` 是摆图时正在用的活旋钮
## （`level_1` 用的就是 47×38），整图会让这两个值失效、加载时还报未知属性 —— 与 `Door` 同一条理由。
##
## 授予那一拍：核心浮起 → 飞进玩家胸口 → 三枚青色菱形环向外扩散淡出，总长 `grant_time`。
## **整段跑真实物理 delta**，刻意不查 `TimeReceiver`：踩上祭坛那一刻玩家通常在跑，而能力 arm
## 的时机按 D16「静止即启」要等到他停下 —— 这两条通道里世界随时可能是 FROZEN，演出若吃世界
## delta 就会卡在半途，而这一拍最需要的是"不管世界怎样都一定演完"。
## 不锁移动、不碰 `TimeManager`（用户裁定）：这一拍不改变任何世界事实，纯表现。
##
## 节点原点 = 底边中心（贴地），与门/按钮/终端同一套约定。
## 触发带由 `width`/`sensor_height` 算，带心固定在玩家碰撞盒中心那条线。
##
## @tool：编辑器里改尺寸立刻重拼石台（摆图定位用）。

signal ability_granted

## 台座宽度，同时也是触发带宽度。
@export var width: float = 64.0:
	set(value):
		width = value
		_rebuild()

## 台座高度（石帽顶所在那条线）。核心悬在它上方。
@export var altar_height: float = 56.0:
	set(value):
		altar_height = value
		_rebuild()

## 触发带高度。带心固定在 -Player.COLLISION_HALF_HEIGHT，所以只要 > 0 就踩得到。
@export var sensor_height: float = 64.0:
	set(value):
		sensor_height = value
		_rebuild()

## 授予那一拍的总长。三段的比例写死在下面 FLY_END / RING_END 两个分数里，
## 这个旋钮整体缩放节奏 —— 快慢留给实机手感调，不用回来改比例。
@export var grant_time: float = 1.05

const TEX_BASE: Texture2D = preload("res://assets/props/altar_base.png")
const TEX_SHAFT: Texture2D = preload("res://assets/props/altar_shaft.png")
const TEX_CAP: Texture2D = preload("res://assets/props/altar_cap.png")
const TEX_GROOVE: Texture2D = preload("res://assets/props/altar_groove.png")
const TEX_BURN: Texture2D = preload("res://assets/props/altar_burn.png")
const TEX_CORE: Texture2D = preload("res://assets/props/altar_core.png")

## 环与核心的青色：与 props.json 的 altar_core 同源（verify_kit 比对）。
## 旧版这里是构件自己的一串琥珀字面量、从来不在清单里 —— D44 订正掉的就是它。
const CORE_COLOR: Color = Color(0.431373, 0.901961, 0.941176)

## 石台各件的摆位 —— 必须与 tools/gen_props.py 的 `paint_altar_steps` 逐像素一致。
const BASE_H: float = 16.0
const CAP_H: float = 8.0
const SHAFT_INSET: float = 8.0
const SLOT_AT: Vector2 = Vector2(-9.0, 3.0)        # 居中件左上角 = (cx-9, top_y+3)
const CORE_AT: Vector2 = Vector2(-14.0, -17.0)     # 核心件左上角 = (cx-14, top_y-17)
const CORE_CENTER: Vector2 = Vector2(14.0, 8.0)    # 28×16 那张里菱形的中心

## 节拍：核心在 33% 处到位，环在 57% 处散完。
const FLY_END: float = 0.33
const RING_END: float = 0.57
const CORE_LIFT: float = 7.0     # 飞出去前先往上浮这么多（一条 sin 弧，不设中间关键点）
const CHEST_Y: float = -3.0      # 胸口 = 玩家原点（碰撞盒中心）上方 3 px
const GLOW_TIME: float = 0.45    # 身体亮那一档，时长交给 Player 自己收
const RING_STEP: float = 0.18    # 三枚环彼此错开这么多

## 本条命内已授予过：一次性。复活回灌走 `mark_spent()`，不重播那一拍。
var is_granted: bool = false

@onready var _collision: CollisionShape2D = $CollisionShape2D

var _grant_elapsed: float = -1.0
var _courier: Player
var _glow_fired: bool = false


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if is_granted or not body.is_in_group(&"player"):
		return
	is_granted = true
	_grant_elapsed = 0.0
	_glow_fired = false
	_courier = body as Player
	ability_granted.emit()
	queue_redraw()


## 关卡复活回灌用：把祭坛摆成「已授予」的样子但不发信号、也不演那一拍 ——
## 那次演出属于玩家第一次踩上去的当帧，重载后的世界里它已经发生过了（D44 第 6 条）。
func mark_spent() -> void:
	is_granted = true
	queue_redraw()


## 时钟：Godot 传进来的那个固定步长，**不是** `TimeReceiver.get_physics_delta()`。见文件头。
func _physics_process(delta: float) -> void:
	if _grant_elapsed < 0.0:
		return
	# 尸体不是玩家（D42 第 6 条那条口径）：死了就当场收摊，核心不该飞进一具正在缩没的身体。
	if _courier == null or not is_instance_valid(_courier) or _courier.is_dead:
		_end_grant()
		return
	_grant_elapsed += delta
	if not _glow_fired and _grant_elapsed >= grant_time * FLY_END:
		_glow_fired = true
		_courier.flash_granted(GLOW_TIME)
	if _grant_elapsed >= grant_time:
		_end_grant()
		return
	queue_redraw()


func _end_grant() -> void:
	_grant_elapsed = -1.0
	_courier = null
	queue_redraw()


## 那一拍的进度 0..1；-1 表示不在演出中。守门读它核对「世界钉住时也在推进」，
## 与 `Player.death_progress()` 同一条口径。
func grant_progress() -> float:
	if _grant_elapsed < 0.0:
		return -1.0
	return clampf(_grant_elapsed / maxf(grant_time, 0.001), 0.0, 1.0)


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(width, sensor_height):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(width, sensor_height)
		_collision.shape = shape
	var band_center := Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	if _collision.position != band_center:
		_collision.position = band_center
	queue_redraw()


func _draw() -> void:
	var h := altar_height
	var w := width
	TileDraw.tile(self, TEX_BASE, -w * 0.5, -BASE_H, w, BASE_H)
	TileDraw.tile(self, TEX_CAP, -w * 0.5, -h, w, CAP_H)
	TileDraw.tile(self, TEX_SHAFT, -w * 0.5 + SHAFT_INSET, -h + CAP_H,
		w - SHAFT_INSET * 2.0, h - BASE_H - CAP_H)
	draw_texture(TEX_BURN if is_granted else TEX_GROOVE, Vector2(SLOT_AT.x, -h + SLOT_AT.y))
	if _grant_elapsed >= 0.0:
		_draw_flight(h)
	elif not is_granted:
		draw_texture(TEX_CORE, Vector2(CORE_AT.x, -h + CORE_AT.y))


func _draw_flight(h: float) -> void:
	var total := maxf(grant_time, 0.001)
	var t := clampf(_grant_elapsed / total, 0.0, 1.0)
	var chest := to_local(_courier.global_position + Vector2(0.0, CHEST_Y))
	if t < FLY_END:
		var k := t / FLY_END
		var pos := Vector2(CORE_AT.x, -h + CORE_AT.y).lerp(chest - CORE_CENTER,
			k * k * (3.0 - 2.0 * k))
		pos.y -= sin(k * PI) * CORE_LIFT
		draw_texture(TEX_CORE, pos)
	if t < RING_END:
		# 三枚同形状的环错开出发：菱形就是核心本来的形状，"从身体里散出来"和"这颗核心"
		# 因此是同一个图形语言，不需要为新演出另立造型。
		for i in 3:
			var k := clampf((t - FLY_END) / (RING_END - FLY_END) + float(i) * RING_STEP,
				0.0, 1.0)
			_draw_ring(chest, 6.0 + k * 26.0, (1.0 - k) * 0.9)


func _draw_ring(center: Vector2, r: float, alpha: float) -> void:
	var pts := PackedVector2Array([
		center + Vector2(0.0, -r), center + Vector2(r * 0.7, 0.0),
		center + Vector2(0.0, r), center + Vector2(-r * 0.7, 0.0),
		center + Vector2(0.0, -r)])
	draw_polyline(pts, Color(CORE_COLOR.r, CORE_COLOR.g, CORE_COLOR.b, alpha), 2.0)
