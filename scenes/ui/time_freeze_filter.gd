class_name TimeFreezeFilter
extends CanvasLayer
## 时停视觉反馈：全屏灰色叠加。M1/M2 用 ColorRect 版，M3 升级为 shader 去饱和版。
## 对外接口两版一致（订阅 state_changed），升级只换内部实现，不动关卡。
##
## 本层只做视觉，绝不参与时停判定。alpha 插值走真实 process delta，
## 用指数平滑而非 lerpf(a, b, delta * speed) —— 后者帧率相关。

const LAYER_INDEX: int = 100
const VISIBLE_THRESHOLD: float = 0.01
const GRAY: Color = Color(0.5, 0.5, 0.5)

@export_range(0.0, 1.0, 0.01) var gray_alpha: float = 0.20
@export var transition_speed: float = 12.0

var _current: float = 0.0
var _target: float = 0.0

@onready var _rect: ColorRect = $ColorRect


func _ready() -> void:
	layer = LAYER_INDEX
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.color = Color(GRAY, 0.0)
	_rect.visible = false
	TimeManager.state_changed.connect(_on_time_state_changed)


func _process(delta: float) -> void:
	_current = lerpf(_current, _target, 1.0 - exp(-transition_speed * delta))
	if absf(_current - _target) < 0.001:
		_current = _target
	_rect.visible = _current > VISIBLE_THRESHOLD
	if not _rect.visible:
		return
	_rect.color = Color(GRAY, gray_alpha * _current)


func _on_time_state_changed(_new_state: int) -> void:
	_target = 1.0 if TimeManager.is_time_frozen() else 0.0
