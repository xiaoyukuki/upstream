class_name PlayerVisual
extends AnimatedSprite2D
## 史莱姆动画驱动器。挂在 Player/Visual/Sprite 上，只读玩家状态挑剪辑，不参与任何物理。
##
## 永久豁免时停：AnimatedSprite2D 用场景树的 process delta 推进，而项目从不碰 Engine.time_scale，
## 所以世界冻住时史莱姆照样呼吸、照样眨眼睛 —— 这是「玩家不在时停范围内」最直观的一层可读性。

## 超过这个水平速度算跑动。远低于 move_speed(260)，只是为了把「减速到停」的尾巴算作跑。
const RUN_SPEED: float = 15.0
## 下落速度超过这个值才算 fall 剪辑；之间是上升段与顶点滞空，停在 jump 的最后一帧。
const FALL_SPEED: float = 140.0
## 低于这个落地冲击速度的小跳不播落地剪辑，否则每走一步都在拍地板。
const MIN_LAND_IMPACT: float = 260.0
## land 剪辑 4 帧 / 22fps = 0.18 s，留点余量覆盖剪辑播完到状态机换回 idle 的那一帧。
const LAND_CLIP_SECONDS: float = 0.2
## 起步/刹车甩动各 3 帧 / 16fps = 0.19 s。窗口一过就交还给 run 或 idle。
const SLOSH_CLIP_SECONDS: float = 0.19
## 蹲下入 3 帧 / 16fps、起身 2 帧 / 16fps。蹲着循环本身没有窗口 —— 按住多久蹲多久。
const CROUCH_IN_CLIP_SECONDS: float = 0.2
const CROUCH_OUT_CLIP_SECONDS: float = 0.13
## 压平入 2 帧 / 18fps、回弹 2 帧 / 16fps。压平循环同样没有窗口 —— 推多久贴多久。
const WALL_PRESS_IN_CLIP_SECONDS: float = 0.12
const WALL_PRESS_OUT_CLIP_SECONDS: float = 0.13
const MAX_FALL_SPEED: float = 900.0

var _player: Player
var _land_remaining: float = 0.0
var _land_scale: float = 1.0
var _start_remaining: float = 0.0
var _stop_remaining: float = 0.0
var _crouch_in_remaining: float = 0.0
var _crouch_out_remaining: float = 0.0
var _press_in_remaining: float = 0.0
var _press_out_remaining: float = 0.0
var _was_running: bool = false
var _was_crouching: bool = false
var _was_pressing: bool = false
## 这一跳是直上直下。起跳那一帧闩一次，整个腾空期不改判 —— 见 `_pick()` 里那条注释。
var _straight_flight: bool = false


func _ready() -> void:
	_player = get_parent().get_parent() as Player
	_player.jumped.connect(_on_jumped)
	_player.landed.connect(_on_landed)


func _process(delta: float) -> void:
	_land_remaining = maxf(0.0, _land_remaining - delta)
	_start_remaining = maxf(0.0, _start_remaining - delta)
	_stop_remaining = maxf(0.0, _stop_remaining - delta)
	_crouch_in_remaining = maxf(0.0, _crouch_in_remaining - delta)
	_crouch_out_remaining = maxf(0.0, _crouch_out_remaining - delta)
	_press_in_remaining = maxf(0.0, _press_in_remaining - delta)
	_press_out_remaining = maxf(0.0, _press_out_remaining - delta)
	_track_slosh()
	_track_crouch()
	_track_wall_press()
	_play(_pick())


## 流体的惯性读法：起步时上身往后甩，刹车时往前扑。只看「地面跑动」这个状态的进出。
## 蹲伏时不算跑动：否则「蹲着走 → 停下 → 起身」会在起身那一刻补播一段刹车甩动，
## 而那段 0.19 s 的 stop 前伸 19 px，是所有剪辑里越界最狠的一帧（D23 同款理由）。
func _track_slosh() -> void:
	var running: bool = (_player.is_on_floor()
		and absf(_player.velocity.x) > RUN_SPEED
		and not _player.is_crouching)
	if running == _was_running:
		return
	_was_running = running
	if running:
		_start_remaining = SLOSH_CLIP_SECONDS
		_stop_remaining = 0.0
	elif _player.is_on_floor():
		_stop_remaining = SLOSH_CLIP_SECONDS
		_start_remaining = 0.0


## 压扁的边沿来自**实际**蹲伏状态而不是按键（D27）：头顶被压住时按键早已松开，
## 但人还蹲着，读按键会播出身动画，而碰撞盒仍是蹲的 —— 正是「画面与碰撞不一致」的镜像。
## 腾空时一个窗口都不留，否则从蹲姿起跳再落地会补播一段莫名其妙的起身。
func _track_crouch() -> void:
	var crouching: bool = _player.is_crouching
	if crouching == _was_crouching:
		return
	_was_crouching = crouching
	if crouching:
		_crouch_in_remaining = CROUCH_IN_CLIP_SECONDS
		_crouch_out_remaining = 0.0
		# 跑动中按下会同时触发「跑动→停」的 stop 窗口。蹲伏现在压过它，但那 0.19 s
		# 会一直留着，等起身时补播一段莫名的刹车。进蹲就清掉，与 _on_jumped 同一套路。
		_start_remaining = 0.0
		_stop_remaining = 0.0
	elif _player.is_on_floor():
		_crouch_out_remaining = CROUCH_OUT_CLIP_SECONDS
		_crouch_in_remaining = 0.0


## 压平同样是纯表现，边沿上进/出。wall_press_dir 本身已经含「贴地」判据（离地即归零），
## 所以这里不再重复查 is_on_floor()；但 out 窗口仍要那一条守卫 —— 与蹲伏同理，
## 否则跳到墙边再落地会补播一段莫名的回弹。
func _track_wall_press() -> void:
	var pressing: bool = _player.wall_press_dir != 0
	if pressing == _was_pressing:
		return
	_was_pressing = pressing
	if pressing:
		_press_in_remaining = WALL_PRESS_IN_CLIP_SECONDS
		_press_out_remaining = 0.0
	elif _player.is_on_floor():
		_press_out_remaining = WALL_PRESS_OUT_CLIP_SECONDS
		_press_in_remaining = 0.0


func _pick() -> StringName:
	if not _player.is_on_floor():
		if _player.velocity.y > FALL_SPEED:
			return &"fall"
		# 直上直下与倾斜是两套帧，判据是**起跳那一帧**的水平速度，整个腾空期不改判：
		# 空中有 air_acceleration / air_friction，逐帧读会让一次跳跃中途换剪辑（跑跳途中松
		# 方向键、原地跳途中推方向键都会触发）。闩锁说的是一件永真的事 ——「这一跳是竖直
		# 起跳的」。与 D27 第 5 条同一条教训：表现钉在实际状态上，而不是钉在按键上。
		return &"jump_straight" if _straight_flight else &"jump"
	if _land_remaining > 0.0:
		return &"land"
	# 压平必须压过 start/stop：接触瞬间 velocity.x 被 move_and_slide() 削成 ~0，
	# _track_slosh() 会判定「跑动→停」并放 0.19 s 的 stop，而 stop 前伸 19 px
	# 是所有剪辑里越界最狠的一帧 —— 不压过它，压平会被刹车甩动整个盖掉。
	if _player.wall_press_dir != 0:
		return &"wall_press_in" if _press_in_remaining > 0.0 else &"wall_press"
	if _press_out_remaining > 0.0:
		return &"wall_press_out"
	# D27：蹲伏压过跑动与甩动。这条优先级在 D22 时代是反的（"跑动全部压过蹲伏"），
	# 那时蹲伏是纯表现，按着下键还能全速跑就播 run 也说得通；现在碰撞盒真蹲下了，
	# 再播站姿的 run / start / stop 就是「画面起立、碰撞还蹲着」—— 看起来正是穿模。
	if _crouch_in_remaining > 0.0:
		return &"crouch_in"
	if _player.is_crouching:
		return &"crouch"
	if _crouch_out_remaining > 0.0:
		return &"crouch_out"
	if _start_remaining > 0.0:
		return &"start"
	if _stop_remaining > 0.0:
		return &"stop"
	if absf(_player.velocity.x) > RUN_SPEED:
		return &"run"
	return &"idle"


func _play(next: StringName) -> void:
	if animation == next:
		return
	speed_scale = _land_scale if next == &"land" else 1.0
	play(next)


func _on_jumped() -> void:
	_land_remaining = 0.0
	_start_remaining = 0.0
	_stop_remaining = 0.0
	_crouch_in_remaining = 0.0
	_crouch_out_remaining = 0.0
	_press_in_remaining = 0.0
	_press_out_remaining = 0.0
	_straight_flight = absf(_player.velocity.x) <= RUN_SPEED


func _on_landed(fall_speed: float) -> void:
	# 走在早退之前：轻落地也要清闩锁，否则之后「走下台阶」会沿用上一跳的剪辑。
	_straight_flight = false
	if fall_speed < MIN_LAND_IMPACT:
		return
	var t: float = (fall_speed - MIN_LAND_IMPACT) / (MAX_FALL_SPEED - MIN_LAND_IMPACT)
	_land_scale = clampf(0.85 + t * 0.75, 0.85, 1.6)
	_land_remaining = LAND_CLIP_SECONDS
