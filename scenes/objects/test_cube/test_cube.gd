class_name TestCube
extends CharacterBody2D
## M1 三合一冻结验证体：同时驱动位移、子节点旋转、AnimationPlayer 三条时停敏感通道，
## 一次看清「位置 / 旋转 / 动画帧均冻结，恢复后无跳变」。
##
## 冻结手段是 velocity 归零并跳过 move_and_slide()，不是把 delta 设 0 ——
## move_and_slide() 不接受 delta 参数，内部固定使用物理步长，自定义 delta 对它毫无影响。
## 这套写法同时就是 M2 MovingBlock 的原型。

@export var path_a: Vector2 = Vector2(-160.0, 0.0)
@export var path_b: Vector2 = Vector2(160.0, 0.0)
@export var travel_speed: float = 80.0
@export var spin_speed: float = 2.0
@export var cube_color: Color = Color(0.85, 0.55, 0.20)

## 累计被冻结的物理帧数，供验收时与 elapsed_path_time 交叉比对。
var frozen_frames: int = 0
var elapsed_path_time: float = 0.0
var spin_angle: float = 0.0

var _origin: Vector2
var _span: float = 1.0

@onready var _receiver: TimeReceiver = $TimeReceiver
@onready var _spinner: Node2D = $Spinner
@onready var _visual: Polygon2D = $Visual
@onready var _anim: AnimationPlayer = $AnimationPlayer


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	_origin = global_position
	_span = maxf((path_b - path_a).length(), 0.001)
	_visual.color = cube_color
	global_position = _origin + path_a
	_anim.speed_scale = 0.0


func _physics_process(_delta: float) -> void:
	var d: float = _receiver.get_physics_delta()
	if d <= 0.0:
		velocity = Vector2.ZERO
		_anim.speed_scale = 0.0
		frozen_frames += 1
		return

	_anim.speed_scale = 1.0

	spin_angle += d * spin_speed
	_spinner.rotation = spin_angle

	elapsed_path_time += d * travel_speed
	var t: float = pingpong(elapsed_path_time / _span, 1.0)
	var target: Vector2 = _origin + path_a.lerp(path_b, t)
	# 被玩家挡住时 target 仍会前进，限速避免脱困瞬间弹射出去。
	velocity = ((target - global_position) / d).limit_length(travel_speed * 2.0)
	move_and_slide()
