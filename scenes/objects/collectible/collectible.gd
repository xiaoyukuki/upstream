@tool
class_name Collectible
extends Area2D
## D54 彩蛋收集物（小黄鸭转台）：藏在隐藏房间里、给"发现"这件事本身的奖励。
##
## 与按钮/存档点/祭坛同族的纯传感器：layer 8、mask 2、monitorable false，
## 不做实体、不做台阶，也不挡任何一条路 —— 它不该改变解谜。
##
## 三条刻意的"不给"（D54 裁定①）：不给机制回报（不加盒高、不开门、不解锁）、
## 不做计数 UI 与全收集奖励、不与别的构件互认。演出也**不复用** D44 祭坛那套
## 「飞入体内 + 三枚环」—— 那套语言在玩家眼里已经是"我获得了能力"，彩蛋借用它
## 就是在撒谎。这里的演出只有一件事：鸭子从底座上**向上飘起来并淡掉**，
## 底座留在原地变成空座（裁定⑤）。
##
## 死一次不许复生（裁定②）：契约三件套照抄祭坛 —— 本构件发 `collectible_taken`、
## 暴露 `mark_taken()`，谁来记、记在哪，归 LevelBase 与 Main.run_state，不归自己。
## 回灌走 `mark_taken()`：空座是"结果"，不再重播飘起演出。
##
## 节点原点 = 底边中心（底座压在格线上），与 Checkpoint/KeyPickup 同一套约定。
## @tool：编辑器里画 idle 态（摆图定位用），停在正脸、不转。

signal collectible_taken()

## 选皮（裁定④）：多种彩蛋皮**共用这一张场景**，因为它们的行为一模一样 ——
## 「行为不同就拆场景」的反面就是行为相同不拆。加第二只彩蛋 = 添三张视图 + 往 `SkinKind`
## 与 `_views()` 添一臂，不新建场景、不新建脚本。
## 枚举不叫 `Skin`：Godot 有个 3D 资源类就叫这个名，用它整个脚本编译不过。
enum SkinKind { DUCK }
@export var skin: SkinKind = SkinKind.DUCK

## 转一圈多少秒（世界时间）。摆图的人可以按房间大小调快慢；填 0 = 不转，钉在正脸。
## 这一档和 `ElectricBar.period` 同性质：**世界流动才走**，冻结时整只钉在当前角度上 ——
## 它是"机器在转"的假象，不是演给玩家看的一次性动作，所以该跟世界一起停（D54 追加裁定）。
@export var spin_period: float = 3.0

const TEX_DUCK_FRONT: Texture2D = preload("res://assets/props/duck_front.png")
const TEX_DUCK_SIDE: Texture2D = preload("res://assets/props/duck_side.png")
const TEX_DUCK_BACK: Texture2D = preload("res://assets/props/duck_back.png")
const TEX_PERCH_IDLE: Texture2D = preload("res://assets/props/perch_idle.png")
const TEX_PERCH_TAKEN: Texture2D = preload("res://assets/props/perch_taken.png")

## B 档转台（用户看 `preview_duck_spin.png` 批的那一档）：四个轴向、三张皮、侧脸靠镜像。
## 轴心表升序，front/back 镜像了也看不出来，只有 side 这一族非对称才需要镜像。
const AXES: Array[float] = [0.0, PI * 0.5, PI, PI * 1.5]
const AXIS_VIEW: Array[int] = [0, 1, 2, 1]
const ASYM_VIEWS: Array[int] = [1]
## 飘起的演出时长与高度。时长不做成导出项：它跟房间大小无关，而且摆图的人没有反馈可调。
const FLY_TIME: float = 0.5
const FLY_RISE: float = 26.0
## 拾取带（裁定③）：**不用**按钮/存档点那条"带心抬半个盒高"的地面传感带 ——
## 那套规矩是给"必须站在它上面"的地面道具的，而鸭子摆在台子上，玩家该是走过去擦到就拿到。
## 于是带子取贴图外接框外扩 `PICKUP_MARGIN`。姿态在换、图在挤，**带子不跟着缩**：
## 判定与零件尺寸无关（D38），不然转扁的那一瞬间它就成了捡不到的东西。
const PICKUP_MARGIN: float = 4.0

## 是否已被拿走（空座态）。由踩上来的那一拍或由 LevelBase 回灌置真，不会再回假。
var spent: bool = false

## 世界时钟（秒）：只累加 `_receiver.get_physics_delta()`，冻结即停 ⇒ 角度钉住。
var _clock: float = 0.0
## 飘起进行中：-1 表示不在飘，否则是已经飘了多少秒（**原始**固定步长，冻结不吃它，D41 同口径）。
var _fly_elapsed: float = -1.0

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 两条时钟通道**刻意**不同，读代码时别把它们当成笔误：
	# 转是环境的一部分 ⇒ 门控 delta（冻结=0，角度钉住）；
	# 飘起是一次性演出 ⇒ 原始 delta（冻结不吃，否则按着方向键捡它就变成半截动画）。
	_clock += _receiver.get_physics_delta()
	if _fly_elapsed >= 0.0:
		_fly_elapsed += delta
		if _fly_elapsed >= FLY_TIME:
			_fly_elapsed = -1.0
	queue_redraw()


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	if spent:
		return
	spent = true
	_fly_elapsed = 0.0
	queue_redraw()
	collectible_taken.emit()


## 回灌（D54 裁定②）：重载之后"这只已经拿过了"。直接空座，不重播演出、不发信号。
func mark_taken() -> void:
	if spent:
		return
	spent = true
	_fly_elapsed = -1.0
	queue_redraw()


func is_spent() -> bool:
	return spent


## 当前转角（弧度，0..2π）。守门拿它核对「冻结时角度不推进」。
func spin_angle() -> float:
	if spin_period <= 0.0:
		return 0.0
	return fmod(_clock * TAU / spin_period, TAU)


## 飘起进度 0..1，不在飘时返回 -1。守门拿它核对「冻结不吃演出」。
func fly_progress() -> float:
	if _fly_elapsed < 0.0:
		return -1.0
	return clampf(_fly_elapsed / FLY_TIME, 0.0, 1.0)


## 这一帧用第几张视图：取角距最近的轴。算式与选型图那边（Python 的
## `gen_collectible_spin_preview.pick()`）是**同一份的两处书写**，不是共享代码 ——
## 所以改轴心表要两边一起改，而下面第 17 组守门拿一圈的视图序列对着图核对，
## 就是为了让"只改了一边"这件事当场响，而不是等玩家看出鸭子转得跟批过的不一样。
static func pick_view(theta: float) -> int:
	return AXIS_VIEW[_nearest_axis(theta)]


## 这一帧横向挤到多宽。B 档与 C 档的差别只有这一个因子（C 档恒为 1）：
## |cos(与最近轴心的夹角)| 在 ±45° 处最低 = 0.707，所以它**永远不会塌成一条线** ——
## A 档露馅就露在那儿。刻意不加下限兜底：兜底会把"哪天有人改轴心表把最扁改小了"
## 这件事一并吞掉，而那条 0.70 的账是用户批 B 档时看到的数字（守门里盯着它）。
static func pick_factor(theta: float) -> float:
	return absf(cos(_wrap_pi(theta - AXES[_nearest_axis(theta)])))


static func pick_mirror(theta: float) -> bool:
	return sin(theta) < 0.0 and ASYM_VIEWS.has(pick_view(theta))


static func _nearest_axis(theta: float) -> int:
	var best := 0
	var best_d := TAU
	for i in AXES.size():
		var d := absf(_wrap_pi(theta - AXES[i]))
		if d < best_d:
			best_d = d
			best = i
	return best


static func _wrap_pi(a: float) -> float:
	var v := a
	while v > PI:
		v -= TAU
	while v < -PI:
		v += TAU
	return v


## 这一档皮的那三张视图。全脚本只有这一处认得具体是哪几张图，`_draw()` 与守门都走它。
## 今天只有一臂：`Skin` 只有一个值，所以这个旋钮现在**拧不动东西** —— 它存在的理由是
## "下一次加皮时选择权住在这里"，而不是让摆图的人今天就有事可做（对照 D34 那条
## "摆了没反应的旋钮比多一个零件糟"：那说的是**有反馈差别**的旋钮，枚举只有一项时
## 检查器里连选错的可能都没有）。
func _views() -> Array[Texture2D]:
	match skin:
		SkinKind.DUCK:
			return [TEX_DUCK_FRONT, TEX_DUCK_SIDE, TEX_DUCK_BACK]
	return [TEX_DUCK_FRONT, TEX_DUCK_SIDE, TEX_DUCK_BACK]


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var size := _band_size()
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != size:
		var shape := RectangleShape2D.new()
		shape.size = size
		_collision.shape = shape
	var center := Vector2(0.0, -float(_sprite_height()) * 0.5)
	if _collision.position != center:
		_collision.position = center
	queue_redraw()


static func _band_size() -> Vector2:
	return Vector2(float(TEX_PERCH_IDLE.get_width()) + PICKUP_MARGIN * 2.0,
		float(_sprite_height()) + PICKUP_MARGIN * 2.0)


static func _sprite_height() -> int:
	return TEX_DUCK_FRONT.get_height() + TEX_PERCH_IDLE.get_height()


func _draw() -> void:
	var perch_w := float(TEX_PERCH_IDLE.get_width())
	var duck_h := float(TEX_DUCK_FRONT.get_height())
	var perch_h := float(TEX_PERCH_IDLE.get_height())
	# 底座的"在/空"两态**同尺寸**（不像 Checkpoint 那样故意差一档）：这张的收据是
	# 顶面那道压痕，选型时量过它对空座 cr=2.07，够了；鸭子不在座子上才是主要的差。
	draw_texture(TEX_PERCH_TAKEN if spent else TEX_PERCH_IDLE,
		Vector2(-perch_w * 0.5, -perch_h))
	if spent and _fly_elapsed < 0.0:
		return
	var theta := spin_angle() if not Engine.is_editor_hint() else 0.0
	var tex: Texture2D = _views()[pick_view(theta)]
	var w := maxf(1.0, roundf(float(tex.get_width()) * pick_factor(theta)))
	var dest := Rect2(-w * 0.5, -perch_h - duck_h, w, duck_h)
	var src := Rect2(0.0, 0.0, float(tex.get_width()), duck_h)
	var modulate := Color.WHITE
	if _fly_elapsed >= 0.0:
		# 飘起：向上走 + 淡掉，姿态照旧跟着转角走（它本来就在转，起飞那一刻钉住反而会跳一下）。
		var t := clampf(_fly_elapsed / FLY_TIME, 0.0, 1.0)
		var rise := FLY_RISE * (1.0 - (1.0 - t) * (1.0 - t))
		dest = Rect2(dest.position.x, dest.position.y - rise, dest.size.x, dest.size.y)
		modulate = Color(1.0, 1.0, 1.0, 1.0 - t)
	if pick_mirror(theta):
		# 镜像只对非对称视图发生（`pick_mirror` 自己判），而 side 那张贴画的是喙朝右，
		# 转到背面去的那半圈里它该朝左 —— 少这一句鸭子会倒着游。
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect_region(tex, dest, src, modulate)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	draw_texture_rect_region(tex, dest, src, modulate)
