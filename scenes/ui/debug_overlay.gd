class_name DebugOverlay
extends CanvasLayer
## 开发期诊断面板。仅 debug build 可见，按 REFRESH_INTERVAL 节流刷新以免每帧重建字符串。
##
## world_time 与 physics_frames 是 M1 帧率一致性验收的客观依据：
## 同样墙钟时长下，限帧 30fps 与不限帧跑出的 world_time 必须基本相等。

const REFRESH_INTERVAL: float = 0.1
const LAYER_INDEX: int = 300

const COLOR_FLOWING: Color = Color(0.45, 0.95, 0.50)
const COLOR_FROZEN: Color = Color(1.00, 0.35, 0.35)
const COLOR_BUFFERING: Color = Color(0.98, 0.85, 0.30)

@onready var _label: Label = $Label

var _accum: float = 0.0


func _ready() -> void:
	layer = LAYER_INDEX
	visible = OS.is_debug_build()
	set_process(visible)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	_label.text = _build_report()
	_label.modulate = _state_color()


func _state_color() -> Color:
	if TimeManager.is_releasing():
		return COLOR_BUFFERING
	return COLOR_FROZEN if TimeManager.is_time_frozen() else COLOR_FLOWING


func _build_report() -> String:
	var lines: PackedStringArray = []

	var state: String = "FROZEN" if TimeManager.is_time_frozen() else "FLOWING"
	if TimeManager.is_releasing():
		state += " (buffering)"
	lines.append("TIME %s   ability=%s" % [state, str(TimeManager.is_ability_enabled)])
	lines.append("world_time=%.3f   physics_frames=%d" % [
		TimeManager.elapsed_world_time, Engine.get_physics_frames()])
	lines.append("fps=%.1f   phys_d=%.5f   proc_d=%.5f   max_fps=%d" % [
		Engine.get_frames_per_second(),
		get_physics_process_delta_time(),
		get_process_delta_time(),
		Engine.max_fps])

	var handler: MovementInputHandler = _find_handler()
	if handler != null:
		lines.append("raw_axis=%+.3f   deadzone=%.2f   is_moving=%s" % [
			handler.raw_axis, handler.freeze_deadzone, str(handler.is_moving)])

	var receivers: Array[Node] = get_tree().get_nodes_in_group(TimeReceiver.GROUP_NAME)
	lines.append("--- time_receivers: %d ---" % receivers.size())
	for receiver in receivers:
		var host: Node = receiver.get_parent()
		if host is Node2D:
			var host2d: Node2D = host
			lines.append("  %-14s frozen=%-5s pos=(%.1f, %.1f)" % [
				host.name, str(receiver.is_time_frozen()),
				host2d.global_position.x, host2d.global_position.y])
		else:
			lines.append("  %-14s frozen=%s" % [host.name, str(receiver.is_time_frozen())])

	return "\n".join(lines)


func _find_handler() -> MovementInputHandler:
	var player: Node = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return null
	return player.get_node_or_null("MovementInputHandler") as MovementInputHandler
