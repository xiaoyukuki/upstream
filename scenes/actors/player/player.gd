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
## 按住 move_down 的瞬时输入状态。只喂给 PlayerVisual 播压扁剪辑：
## 不改碰撞盒、不减速，也绝不进 notify_movement_intent —— 蹲着不该冻结世界。
var is_crouch_held: bool = false
## 主动推墙的方向（0 = 没推，±1 = 推向哪一侧的墙）。同样只喂给 PlayerVisual 播压平剪辑，
## 纯表现读数：碰撞盒、速度、冻结判定一概不碰。
var wall_press_dir: int = 0

var _coyote_remaining: float = 0.0
var _buffer_remaining: float = 0.0
var _was_on_floor: bool = false

@onready var _visual: Node2D = $Visual


func _ready() -> void:
	spawn_point = global_position
	add_to_group(&"player")


func _physics_process(delta: float) -> void:
	_coyote_remaining = maxf(0.0, _coyote_remaining - delta)
	_buffer_remaining = maxf(0.0, _buffer_remaining - delta)

	if Input.is_action_just_pressed(&"jump"):
		_buffer_remaining = jump_buffer_time
	is_crouch_held = Input.is_action_pressed(&"move_down")

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


func _try_jump() -> void:
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
