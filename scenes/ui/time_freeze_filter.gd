class_name TimeFreezeFilter
extends CanvasLayer
## 冻结态的视觉符号：全屏 CRT（D46 取代了 D8 的灰叠加版）。
##
## 本层只做视觉，绝不参与世界冻结判定 —— 这条从 D8 一路继承下来没变，
## 对外接口也没变（仍然只订阅 state_changed），换掉的只是 ColorRect 里面那块材质。
##
## 强度插值走真实 process delta，用指数平滑而非 lerpf(a, b, delta * speed) —— 后者帧率相关。
## 注意强度是喂给 shader 的 uniform，不再挂在 ColorRect 的 alpha 上：
## canvas_item 的 fragment() 一覆盖 COLOR，顶点色就丢了，靠 alpha 淡入会变成硬开硬关。

const LAYER_INDEX: int = 100
const VISIBLE_THRESHOLD: float = 0.01

@export var transition_speed: float = 12.0

var _current: float = 0.0
var _target: float = 0.0

@onready var _rect: ColorRect = $ColorRect
@onready var _material: ShaderMaterial = _rect.material as ShaderMaterial


func _ready() -> void:
	layer = LAYER_INDEX
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false
	_set_strength(0.0)
	TimeManager.state_changed.connect(_on_time_state_changed)


func _process(delta: float) -> void:
	_current = lerpf(_current, _target, 1.0 - exp(-transition_speed * delta))
	if absf(_current - _target) < 0.001:
		_current = _target
	_rect.visible = _current > VISIBLE_THRESHOLD
	if not _rect.visible:
		return
	_set_strength(_current)


func strength() -> float:
	return _current


func _set_strength(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("strength", v)


func _on_time_state_changed(_new_state: int) -> void:
	_target = 1.0 if TimeManager.is_time_frozen() else 0.0
