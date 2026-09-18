extends Node
## 时停状态机。Autoload 单例，注册名 TimeManager。
##
## 第一章唯一的时间权威：所有受时停影响的对象一律通过 TimeReceiver 读取本单例的门控 delta。
## 刻意不写 class_name —— 会与 autoload 注册名冲突，Godot 4 报 "hides an autoload singleton"。
## 严禁使用 Engine.time_scale：全局缩放会把玩家、相机、UI 一起拖进去，而玩家必须豁免时停。
##
## 判定挂在 _physics_process 而非 _process：物理步长恒为 1/60，天然帧率无关；
## 若在 _physics_process 里读 process delta，一帧跑两次物理步会拿到同一个值，世界时间流速翻倍。

signal state_changed(new_state: TimeState)
signal ability_enabled_changed(enabled: bool)

enum TimeState { FLOWING, FROZEN }

## FROZEN → FLOWING 的防抖窗口。只作用于解冻方向，冻结是立即的。
const RELEASE_BUFFER_DURATION: float = 0.08

var current_state: TimeState = TimeState.FLOWING
var is_ability_enabled: bool = false

## 已模拟的世界时间，仅在 FLOWING 累加。用于客观验证帧率无关性：
## 同样墙钟时长下，30fps 与 60fps 的该值必须一致。
var elapsed_world_time: float = 0.0

var _release_remaining: float = 0.0
var _is_releasing: bool = false


func _ready() -> void:
	process_physics_priority = -100


func _physics_process(delta: float) -> void:
	_advance_release_buffer(delta)
	if current_state == TimeState.FLOWING:
		elapsed_world_time += delta


## 由 MovementInputHandler 在边沿处调用。未解锁能力时意图被完全忽略，世界恒 FLOWING。
func notify_movement_intent(moving: bool) -> void:
	if not is_ability_enabled:
		return
	if moving:
		_is_releasing = false
		_release_remaining = 0.0
		_set_state(TimeState.FROZEN)
		return
	if current_state != TimeState.FROZEN or _is_releasing:
		return
	_is_releasing = true
	_release_remaining = RELEASE_BUFFER_DURATION


func is_time_frozen() -> bool:
	return current_state == TimeState.FROZEN


## 缓冲中：已停止移动但世界尚未解冻。供 DebugOverlay 显示黄色态，
## 刻意不塞进 TimeState 枚举 —— 加第三态会污染所有只认两态的消费方。
func is_releasing() -> bool:
	return _is_releasing


## 供 _physics_process 中驱动的受时停对象使用。
func get_physics_delta() -> float:
	if current_state == TimeState.FROZEN:
		return 0.0
	return get_physics_process_delta_time()


## 供 _process 中驱动的纯视觉逻辑使用。
func get_process_delta() -> float:
	if current_state == TimeState.FROZEN:
		return 0.0
	return get_process_delta_time()


func get_time_scale() -> float:
	return 0.0 if current_state == TimeState.FROZEN else 1.0


func set_ability_enabled(enabled: bool) -> void:
	if is_ability_enabled == enabled:
		return
	is_ability_enabled = enabled
	ability_enabled_changed.emit(enabled)
	if not enabled:
		reset_state()


## 关卡级重置。清掉缓冲、能力门控残留与世界计时，对应风险表「场景切换状态残留」。
func reset_state() -> void:
	_is_releasing = false
	_release_remaining = 0.0
	elapsed_world_time = 0.0
	_set_state(TimeState.FLOWING)


func _advance_release_buffer(delta: float) -> void:
	if not _is_releasing:
		return
	_release_remaining -= delta
	if _release_remaining > 0.0:
		return
	_is_releasing = false
	_set_state(TimeState.FLOWING)


func _set_state(new_state: TimeState) -> void:
	if current_state == new_state:
		return
	current_state = new_state
	state_changed.emit(new_state)
