class_name Player
extends CharacterBody2D
## 平台跳跃角色控制器。
##
## 永久豁免时停：本脚本所有计时一律使用真实物理 delta，绝不查询 TimeManager。
## 玩家是「时间旅行者」，世界静止时他照常行动 —— 这是整个机制成立的前提。

signal jumped
signal landed(fall_speed: float)

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

var _coyote_remaining: float = 0.0
var _buffer_remaining: float = 0.0
var _was_on_floor: bool = false

@onready var _visual: Node2D = $Visual
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
	_coyote_remaining = maxf(0.0, _coyote_remaining - delta)
	_buffer_remaining = maxf(0.0, _buffer_remaining - delta)

	if Input.is_action_just_pressed(&"jump"):
		_buffer_remaining = jump_buffer_time
	is_crouch_held = Input.is_action_pressed(&"move_down")
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


func respawn() -> void:
	global_position = spawn_point
	velocity = Vector2.ZERO
	_coyote_remaining = 0.0
	_buffer_remaining = 0.0
	is_crouching = false
	is_head_blocked = false
	_apply_body_height(STAND_HEIGHT)


func _try_jump() -> void:
	# Q2：头顶被压住时不许起跳。缓冲区也一并清掉 —— 留着的话等头顶一空出来
	# 人会莫名其妙自己弹一下。
	if is_head_blocked:
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


func _apply_horizontal(delta: float) -> void:
	var axis: float = Input.get_axis(&"move_left", &"move_right")
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
	var side: int = int(signf(Input.get_axis(&"move_left", &"move_right")))
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
