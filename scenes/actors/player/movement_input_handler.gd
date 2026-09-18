class_name MovementInputHandler
extends Node
## 读取原始水平输入轴，做死区与边沿检测，向 TimeManager 报告移动意图。
##
## 刻意不做任何平滑：平滑会让轴值需要若干帧才爬过死区，冻结随之延迟触发，
## 且延迟量随帧率变化 —— 与「开始移动瞬间冻结」直接冲突。
## 角色加速度平滑属于手感调校，在 Player 内部独立完成，与本组件无关。
##
## 只监听水平位移。垂直输入（跳跃/下落）不参与时停判定。

signal movement_started
signal movement_stopped

## 冻结死区。必须显著大于 InputMap 的 deadzone(0.1)，否则模拟摇杆精度已被上游吃掉。
@export_range(0.0, 1.0, 0.01) var freeze_deadzone: float = 0.18

var raw_axis: float = 0.0
var is_moving: bool = false


func _ready() -> void:
	process_physics_priority = -200


func _physics_process(_delta: float) -> void:
	raw_axis = Input.get_axis(&"move_left", &"move_right")
	var moving: bool = absf(raw_axis) > freeze_deadzone
	if moving == is_moving:
		return
	is_moving = moving
	if moving:
		movement_started.emit()
	else:
		movement_stopped.emit()
	TimeManager.notify_movement_intent(moving)
