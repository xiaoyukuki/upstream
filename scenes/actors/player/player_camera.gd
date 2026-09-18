class_name PlayerCamera
extends Camera2D
## 跟随相机的水平前瞻。永久豁免时停。
##
## 位置平滑、zoom、limit_left/top/right/bottom 全部用 Camera2D 原生属性在检查器里配，
## 这里不重复导出一遍 —— 原生属性已经够用且更好调。

@export var lookahead_distance: float = 48.0
@export var lookahead_speed: float = 6.0
@export var lookahead_velocity_factor: float = 0.18

var _lookahead: float = 0.0
var _player: Player


func _ready() -> void:
	_player = get_parent() as Player


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var target: float = clampf(
		_player.velocity.x * lookahead_velocity_factor,
		-lookahead_distance,
		lookahead_distance
	)
	# 指数平滑而非 lerpf(a, b, delta * speed)：后者帧率相关，前者帧率无关。
	_lookahead = lerpf(_lookahead, target, 1.0 - exp(-lookahead_speed * delta))
	position.x = _lookahead
