class_name Player
extends CharacterBody2D
## 平台跳跃角色控制器。
##
## 永久豁免时停：本脚本所有计时一律使用真实物理 delta，绝不查询 TimeManager。
## 玩家是「时间旅行者」，世界静止时他照常行动 —— 这是整个机制成立的前提。
##
## 唯一例外是死亡那一拍（D42）：`is_dead` 之后整条物理停摆，尸体钉在死亡点上，
## 只有「收缩 + 淡出」这一个演出还在引擎自己的固定步长上跑 —— 与 D41 同一口径，
## 世界被钉在冻结态，演出在冻结的这一拍里跑完。判死与「什么时候重载」都不归这里。

signal jumped
signal landed(fall_speed: float)
## 死亡那一拍演完了。LevelBase 接它去委托重载 —— 时长只有一个来源（它的 death_time），
## 本脚本不数第二道表，于是两边不存在「谁先结束」的问题。
signal death_finished

## 贴地时玩家碰撞盒中心在地面以上 15 px（碰撞盒 20×30）。Area2D 判的是碰撞盒是否重叠，
## 不是画出来的多边形，所以地面传感器的触发带必须跨过这条线。构件一律用本常量算带心：
## 改 player.tscn 的碰撞盒尺寸时，这里跟着改。
const COLLISION_HALF_HEIGHT: float = 15.0

## 站立与蹲伏的碰撞盒高度。蹲伏值按美术同比例缩：站姿美术 25 对盒 30（×1.2），
## 蹲伏循环帧高 12.5 → 盒 15（也正好是站姿的一半）。脚底永远钉在原点下方
## COLLISION_HALF_HEIGHT，盒子只从**顶部**往下缩 —— 这条是 D22 的脚底契约，破了会陷地/悬空。
const STAND_HEIGHT: float = COLLISION_HALF_HEIGHT * 2.0
const CROUCH_HEIGHT: float = 15.0

## 头顶净空查询的余量。D21 实测过 intersect_shape 对「恰好相切」不可靠，宁可过度阻塞。
const HEADROOM_MARGIN: float = 1.0
## 只认实体：terrain(1) + time_solid(4)。传感器层是 monitorable=false 的 Area2D，不该挡人。
const HEADROOM_MASK: int = 1 | 4
const MAX_HEADROOM_HITS: int = 4

## 死亡那一拍的收缩终点（D42）：身体等比缩到 12% 而不是 0 —— 留一个「缩没了」的落点，
## 比让它凭空消失读得清楚，而这一刻透明度已经掉到 0，实际看不见这个残核。
const DEATH_SHRINK_MIN: float = 0.12
## 收缩的同时往上飘 12 px（约半个身位的一半）：只缩不飘读作「被压扁」，飘起来才读作「散了」。
const DEATH_RISE: float = 12.0
## 前 55% 满不透明，之后线性淡到 0。收缩比淡出先完成，两条错开才不像「一起消失」。
const DEATH_FADE_FROM: float = 0.55
## 收缩在 60% 处就到位，剩下的 40% 只留给淡出。
const DEATH_SHRINK_SPAN: float = 0.6
## 能力入体那一拍的身体提亮（D44）。`modulate` 是乘性的，要"更亮"只能让分量 > 1；
## g/b 抬得比 r 多，于是那一下读作泛起祭坛核心的青色，而不是整只变白。
const GRANT_GLOW: Color = Color(1.0, 1.22, 1.35, 1.0)

## 开局苏醒那一拍多长（D57）。wake 剪辑 8 帧 / 7fps = 1.143 s，取 1.15 覆盖到状态机
## 换回 idle 的那一帧 —— 与 LAND_CLIP_SECONDS 同一口径：窗口比剪辑略长，交接处才不露接缝。
const WAKE_SECONDS: float = 1.15

@export_group("Horizontal")
@export var move_speed: float = 260.0
@export var ground_acceleration: float = 2600.0
@export var ground_friction: float = 3200.0
@export var air_acceleration: float = 1700.0
@export var air_friction: float = 900.0

@export_group("Vertical")
@export var jump_velocity: float = -520.0
## 提前松开跳跃键时对上抬速度的削减比例，越小跳得越矮。
@export_range(0.0, 1.0, 0.01) var jump_cut_multiplier: float = 0.45
@export var max_fall_speed: float = 900.0
## 接近跳跃顶点时降低重力，制造滞空感。
@export_range(0.0, 1.0, 0.01) var apex_gravity_multiplier: float = 0.55
@export var apex_speed_threshold: float = 90.0

@export_group("Forgiveness")
## 离开地面后仍可起跳的宽限窗口。
@export var coyote_time: float = 0.10
## 落地前提前按跳跃仍会被消化的窗口。
@export var jump_buffer_time: float = 0.12

var facing: int = 1
var spawn_point: Vector2
## 按住 move_down 的瞬时输入状态。只喂给蹲伏意图，
## 也绝不进 notify_movement_intent —— 蹲着不该冻结世界。
var is_crouch_held: bool = false
## 实际蹲伏状态（D26）。碰撞盒尺寸以它为准，动画也必须读它而不是读 is_crouch_held：
## 头顶被门/天花板压住时输入已经松开，人却还蹲着，读输入会播出身动画而碰撞盒仍是蹲的。
var is_crouching: bool = false
## 想站起来但头顶没有净空。此时保持蹲伏，且禁止起跳（Q2）。
var is_head_blocked: bool = false
## 主动推墙的方向（0 = 没推，±1 = 推向哪一侧的墙）。同样只喂给 PlayerVisual 播压平剪辑，
## 纯表现读数：碰撞盒、速度、冻结判定一概不碰。
var wall_press_dir: int = 0
## 临时移动锁（D41）：刷卡门吞卡那 0.45 秒里掐掉水平输入与起跳，让「卡从体内飞出去」
## 有一拍不会被人走出去打断。只掐输入，不掐重力（腾空时被锁会照常落地），
## 也不碰 notify_movement_intent —— 按着的方向键仍然把世界冻着，演出正是在这一拍里跑。
var movement_locked: bool = false
## 已被杀死（D42）：整条物理停摆，只跑那一拍的演出。压过 movement_locked ——
## 死在刷卡演出里时门照样会把移动还回来，但那具尸体不该因此站起来走路。
var is_dead: bool = false
## 演出进度：-1 表示不在演出中（与 KeyPickup.fly_progress() 同一口径）。
var _death_elapsed: float = -1.0
## 这一拍多长，由 die() 的调用方（LevelBase.death_time）给 —— 时长只住一处才谈得上同拍重载。
var _death_time: float = 0.0

var _coyote_remaining: float = 0.0
var _buffer_remaining: float = 0.0
## 开局苏醒那一拍还剩多久（D57）。0 = 不在苏醒里。与 `_death_elapsed` 同一口径：
## 一次性演出走引擎固定步长（玩家本就豁免时停，这里的 delta 就是物理步），
## 不吃门控 delta —— 否则"演到一半被按方向键冻住"正是玩家看见的第一个 bug。
var _wake_remaining: float = 0.0
var _was_on_floor: bool = false
## 能力入体那一拍的提亮还剩多久（D44）。总长单独存一份是为了把亮度归一化到 0~1 再衰减。
var _grant_glow: float = 0.0
var _grant_glow_total: float = 1.0

@onready var _visual: Node2D = $Visual
## 死亡那一拍的液滴（D42）。排在 Visual 之后 = 画在身体之上；挂在 Player 而不是 Visual
## 之下，是因为 Visual 正被演出缩着，液滴不该跟着一起缩。
@onready var _death_burst: DeathBurst = $DeathBurst
@onready var _collision: CollisionShape2D = $CollisionShape2D
## 关卡要判断「玩家松手了没」（能力开启、终点收尾都靠它）时读这个属性，
## 不要自己 get_node("MovementInputHandler") —— 那个字符串以前在三个关卡脚本里各写一遍。
@onready var input_handler: MovementInputHandler = $MovementInputHandler

## 运行期独占一份形状资源：player.tscn 里那份是 sub_resource，
## 直接改尺寸会波及同一场景的其它实例（门踩过同一个坑，见 D21）。
var _body_rect: RectangleShape2D
var _probe: PhysicsShapeQueryParameters2D
var _probe_rect: RectangleShape2D


func _ready() -> void:
	spawn_point = global_position
	add_to_group(&"player")
	var base := _collision.shape as RectangleShape2D
	if base != null:
		_body_rect = base.duplicate() as RectangleShape2D
	else:
		_body_rect = RectangleShape2D.new()
		_body_rect.size = Vector2(20.0, STAND_HEIGHT)
	_collision.shape = _body_rect
	_probe = PhysicsShapeQueryParameters2D.new()
	_probe_rect = RectangleShape2D.new()
	_probe.shape = _probe_rect
	_probe.collision_mask = HEADROOM_MASK
	_probe.collide_with_bodies = true
	_probe.collide_with_areas = false
	_probe.motion = Vector2.ZERO
	# 查询矩形压在玩家自己身上，不排除自己必然自撞。
	var self_rid: Array[RID] = []
	self_rid.append(get_rid())
	_probe.exclude = self_rid


func _physics_process(delta: float) -> void:
	# 授予那一拍的提亮（D44）。排在死亡分支**之前**：人死在演出里时，这一档亮度也要继续走完，
	# 不然会永久停在半亮。只改 rgb、把 .a 原样带走 —— D42 的淡出写的正是同一个 Color 的 .a。
	if _grant_glow > 0.0:
		_grant_glow = maxf(0.0, _grant_glow - delta)
		var k := _grant_glow / _grant_glow_total
		var a := _visual.modulate.a
		_visual.modulate = Color(lerpf(1.0, GRANT_GLOW.r, k), lerpf(1.0, GRANT_GLOW.g, k),
			lerpf(1.0, GRANT_GLOW.b, k), a)
	# 死亡那一拍：输入、重力、碰撞全停，只让演出往前走。放在最顶上是因为下面每一段
	# 都默认「这是一个还活着的人在动」，逐条加 `if is_dead` 早晚会漏一条。
	if is_dead:
		_advance_death(delta)
		return
	# 开局苏醒那一拍（D57）。放在所有输入读取之前：窗口结束那一帧就该把控制权交回去，
	# 而不是让那一帧的方向键照样生效。
	if _wake_remaining > 0.0:
		_wake_remaining = maxf(0.0, _wake_remaining - delta)
		if _wake_remaining == 0.0:
			movement_locked = false
	_coyote_remaining = maxf(0.0, _coyote_remaining - delta)
	_buffer_remaining = maxf(0.0, _buffer_remaining - delta)

	if Input.is_action_just_pressed(&"jump"):
		_buffer_remaining = jump_buffer_time
	is_crouch_held = Input.is_action_pressed(&"move_down") and not is_waking()
	# 必须在 _try_jump() 之前：被压住时能不能起跳取决于这一帧的判定结果。
	_update_crouch()

	_try_jump()
	_apply_jump_cut()
	_apply_gravity(delta)
	_apply_horizontal(delta)

	var fall_speed: float = velocity.y
	move_and_slide()
	_update_floor_state(fall_speed)
	_update_wall_press()


## 开局苏醒那一拍（D57）：由关卡根在**本次进程第一次进关**时叫一次。演的是"从睡梦里醒"，
## 所以整段掐输入（用户裁 B2）—— 掐的是 D41 那把现成的移动锁，不另起第二套掐法。
## 只有水平与跳跃走那把锁；蹲伏走 `is_crouch_held` 那一条读法（皮不许在 wake 里偷蹲）。
func begin_wake() -> void:
	_wake_remaining = WAKE_SECONDS
	movement_locked = true


## 皮读它决定播不播 wake 剪辑，守门也读它。苏醒期间人不移动，所以世界照常流动 ——
## 这一拍与"冻结"无关，只与"他还没醒"有关。
func is_waking() -> bool:
	return _wake_remaining > 0.0


func respawn() -> void:
	global_position = spawn_point
	velocity = Vector2.ZERO
	_coyote_remaining = 0.0
	_buffer_remaining = 0.0
	_wake_remaining = 0.0
	is_crouching = false
	is_head_blocked = false
	movement_locked = false
	is_dead = false
	_death_elapsed = -1.0
	_reset_visual_transform()
	_apply_body_height(STAND_HEIGHT)


## 被杀死（D42）。判死归 HazardBase 发信号、编排归 LevelBase，这里只回答
## 「死了之后这一具身体长成什么样」：钉在死亡点 + 演一拍 + 把世界钉住。
## duration 由调用方给，本脚本刻意不留第二个时长常量。
func die(duration: float) -> void:
	if is_dead:
		return
	is_dead = true
	_death_time = maxf(duration, 0.001)
	_death_elapsed = 0.0
	velocity = Vector2.ZERO
	TimeManager.set_frozen_override(true)
	_death_burst.launch(_death_time)
	_apply_death_transform(0.0)


## 能力入体那一拍（D44）：身体提亮一档青色再熄。这是祭坛对玩家做的**唯一**一件事 ——
## 演出本体（核心飞行、三枚环）全在 `AbilityAltar` 里画，这里只留身体那一档。
## 归 Player 而不塞进 `PlayerVisual`：`_visual.modulate` 这条通道由 Player 独占
## （D42 的淡出写它的 .a），而 PlayerVisual 只负责挑剪辑，两边不该抢同一个属性。
## duration 由调用方给，与 `die()` 同一条规矩：一个数只住一处。
func flash_granted(duration: float) -> void:
	_grant_glow_total = maxf(duration, 0.001)
	_grant_glow = _grant_glow_total


## 演出进度 0..1；-1 表示不在演出中。守门读它核对「收缩与爆裂同拍结束」。
func death_progress() -> float:
	if _death_elapsed < 0.0:
		return -1.0
	return clampf(_death_elapsed / maxf(_death_time, 0.001), 0.0, 1.0)


## 与 `_advance_swipe()` 同一形状的计时：吃引擎自己的固定物理步长，世界那道闸截不到它，
## 所以世界停在冻结那一拍里、演出照跑完。跑完只发一个信号，重载不归这里。
func _advance_death(delta: float) -> void:
	if _death_elapsed < 0.0:
		return
	_death_elapsed += delta
	if _death_elapsed < _death_time:
		_apply_death_transform(death_progress())
		return
	_death_elapsed = -1.0
	_apply_death_transform(1.0)
	death_finished.emit()


## 收缩 + 上飘 + 淡出，三个数都写成显式的二次缓出（先窜后飘），与匀速的区别见 D41 第 6 条。
## 算式与 tools/gen_death_preview.py 的 D 行逐字同源 —— 选型图上的位置就是实机的位置。
func _apply_death_transform(t: float) -> void:
	var u: float = minf(t / DEATH_SHRINK_SPAN, 1.0)
	var k: float = 1.0 - (1.0 - u) * (1.0 - u)
	var s: float = maxf(DEATH_SHRINK_MIN, 1.0 - (1.0 - DEATH_SHRINK_MIN) * k)
	_visual.scale = Vector2(float(facing) * s, s)
	_visual.position.y = -DEATH_RISE * k
	_visual.modulate.a = 1.0 if t < DEATH_FADE_FROM \
		else maxf(0.0, 1.0 - (t - DEATH_FADE_FROM) / (1.0 - DEATH_FADE_FROM))


func _reset_visual_transform() -> void:
	_visual.scale = Vector2(float(facing), 1.0)
	_visual.position = Vector2.ZERO
	_visual.modulate.a = 1.0


func _try_jump() -> void:
	# Q2：头顶被压住时不许起跳。缓冲区也一并清掉 —— 留着的话等头顶一空出来
	# 人会莫名其妙自己弹一下。移动锁（D41）同一处理：锁期间按跳跃等于没按。
	if is_head_blocked or movement_locked:
		_buffer_remaining = 0.0
		return
	if _buffer_remaining <= 0.0:
		return
	if not (is_on_floor() or _coyote_remaining > 0.0):
		return
	_buffer_remaining = 0.0
	_coyote_remaining = 0.0
	velocity.y = jump_velocity
	jumped.emit()


func _apply_jump_cut() -> void:
	if not Input.is_action_just_released(&"jump"):
		return
	if velocity.y < 0.0:
		velocity.y *= jump_cut_multiplier


func _apply_gravity(delta: float) -> void:
	if is_on_floor() and velocity.y > 0.0:
		velocity.y = 0.0
		return
	var gravity_scale: float = 1.0
	if absf(velocity.y) < apex_speed_threshold:
		gravity_scale = apex_gravity_multiplier
	velocity.y = minf(velocity.y + get_gravity().y * gravity_scale * delta, max_fall_speed)


## 水平输入轴唯一的读法。收成一处是因为移动锁必须一处不落：以前这个轴在
## `_apply_horizontal` 与 `_update_wall_press` 各读一遍，锁散在两处迟早会漏一处。
func _horizontal_axis() -> float:
	return 0.0 if movement_locked else Input.get_axis(&"move_left", &"move_right")


func _apply_horizontal(delta: float) -> void:
	# 轴为 0 时走下面那条摩擦分支：被锁住的人是照物理减速停住，
	# 比把 velocity.x 钉死更不像「撞到一堵看不见的墙」。
	var axis: float = _horizontal_axis()
	var on_floor: bool = is_on_floor()
	if axis != 0.0:
		facing = 1 if axis > 0.0 else -1
		var accel: float = ground_acceleration if on_floor else air_acceleration
		velocity.x = move_toward(velocity.x, axis * move_speed, accel * delta)
	else:
		var fric: float = ground_friction if on_floor else air_friction
		velocity.x = move_toward(velocity.x, 0.0, fric * delta)
	_visual.scale.x = float(facing)


func _update_floor_state(fall_speed: float) -> void:
	var on_floor: bool = is_on_floor()
	if on_floor:
		_coyote_remaining = coyote_time
		if not _was_on_floor and fall_speed > 0.0:
			landed.emit(fall_speed)
	_was_on_floor = on_floor


## 只认「主动推墙」：贴地 + 撞到墙 + 水平输入指向墙那一侧。站在墙边不推不算，
## 所以不需要侧向探测 —— 探测常开会让贴墙站着的默认观感变成窄身形（D23 后果一）。
## 每帧重算：is_on_wall() 报的是上一次 move_and_slide() 的结果，而顶着墙时 velocity.x
## 每帧被碰撞削成 ~0、又被 _apply_horizontal 重新加速，所以这个读数天然逐帧刷新、不会粘住。
func _update_wall_press() -> void:
	wall_press_dir = 0
	if not is_on_floor() or not is_on_wall():
		return
	var side: int = int(signf(_horizontal_axis()))
	if side == 0:
		return
	for i in get_slide_collision_count():
		# 法线背离墙面，取负号才是「墙在哪一侧」
		if int(signf(-get_slide_collision(i).get_normal().x)) == side:
			wall_press_dir = side
			return


## 蹲伏状态机（D26）。碰撞盒随它一起缩，所以「能不能站起来」必须先问物理世界。
## 腾空一律不蹲（D22 的既有规则）：离地后 want 为 false，且下面的净空判定只在
## is_on_floor() 时才拦人 —— 从低矮处走下台阶会被放行，落下去的过程本来就在远离天花板。
func _update_crouch() -> void:
	var want: bool = is_crouch_held and is_on_floor()
	is_head_blocked = false
	if is_crouching and not want and is_on_floor() and _head_blocked():
		is_head_blocked = true
		want = true
	if want == is_crouching:
		return
	is_crouching = want
	_apply_body_height(CROUCH_HEIGHT if is_crouching else STAND_HEIGHT)


## 只查「站起来会新占的那条竖带」，不查整盒：脚底那一段本来就占着，查它毫无意义，
## 而相切误判只会发生在新增的这条带的上边界。无状态查询，每帧重问一次 —— 与 D21 的
## 让位同一个理由：不维护重叠计数，玩家 respawn 被瞬移走、世界冻结、解冻续走都不用补账。
func _head_blocked() -> bool:
	if _body_rect == null:
		return false
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var span: float = STAND_HEIGHT - CROUCH_HEIGHT
	_probe_rect.size = Vector2(_body_rect.size.x, span + HEADROOM_MARGIN * 2.0)
	# 带心与余量无关：带子两端各扩 MARGIN，中心不动。
	_probe.transform = Transform2D(0.0,
		global_position + Vector2(0.0, -COLLISION_HALF_HEIGHT + span * 0.5))
	return not space.intersect_shape(_probe, MAX_HEADROOM_HITS).is_empty()


## 脚底钉死在原点下方 COLLISION_HALF_HEIGHT，盒子只从顶部往下缩。
func _apply_body_height(h: float) -> void:
	if _body_rect == null:
		return
	var size := Vector2(_body_rect.size.x, h)
	if _body_rect.size != size:
		_body_rect.size = size
	var center := Vector2(0.0, COLLISION_HALF_HEIGHT - h * 0.5)
	if _collision.position != center:
		_collision.position = center


## 世界坐标下此刻的身体矩形。给"需要知道人在哪一格里"的构件用（D48 残影踏板的判死带）。
## 读的是真的那块 shape 而不是按常量重算：蹲伏真的缩盒（D27），重算的版本会跟物理对不上。
## 有了它，构件就不必去摸 `_collision` / `_body_rect` —— 与 HazardBase 那条
## 「判死不引用 Player 内部」同一口径。
func collision_rect() -> Rect2:
	if _body_rect == null:
		return Rect2(global_position, Vector2.ZERO)
	var half := _body_rect.size * 0.5
	var center := global_position + _collision.position
	return Rect2(center - half, _body_rect.size)


## 让**玩家自己的身体**去吃这一段位移（D49 活塞踏板的「挤开」）。走 `move_and_collide` 而不是
## 改 `global_position`：他要照常撞地形，背后有墙就停在那儿 —— 构件据此夹住自己，
## 于是"把人夹进墙里"在这个结构里不发生，构件不必写第二条挤压判定。
## 只改位置、绝不碰 `velocity`：他的水平速度每帧都被 `_apply_horizontal` 的加速与摩擦重写，
## 掺进去等于两方抢同一个数，推人的一方就再也不知道人被推走了多少。
func push_by(motion: Vector2) -> void:
	if is_dead or motion == Vector2.ZERO:
		return
	move_and_collide(motion)
