extends Node
## 冻结时把 BGM 的高频压下去（D79）。一条低通挂在专属的 `Music` 总线上，切点在世界
## 开始/停止流动的那一拍起步爬坡 —— 听觉那一半补的正是画面那一半已经在说的事。
##
## 五条边界，每一条写歪了都**不会报错**：
## ① **斜坡吃真实时间。** 不能用 `TimeManager.get_process_delta()`：那个量冻结时返回 0，
##    斜坡会永远停在起点（声音一点没闷），而无头全绿。`_process(delta)` 拿到的就是真实
##    delta —— 项目从不碰 `Engine.time_scale`，也从不 paused 整棵树。
## ② **走 `/root` 路径取节点，不写 `TimeManager` / `Musicplayer` 标识符。** `--script` 模式下
##    autoload 的**节点**在 /root 上、**标识符却编译不过**（与 `level_base.gd` 同一条坑），
##    而 `verify_kit` 就是 --script 跑的，它会 load 本脚本。
## ③ **总线先落地，路由才跟得上。** 给一个还不存在的总线名赋值不报错，读回来是 `Master`；
##    等总线建出来，同一个 player 又会自己跟上。所以建总线必须排在写 `bus` 前面，
##    守门读的也是 `player.bus` 的**读回值**，不是"我写过那一行"。
## ④ **专属总线，不压 Master。** Master 将来要走音效；闷掉整条 master 等于连死亡声一起闷。
## ⑤ **不区分冻结来源。** 死亡那一拍、能力授予那一拍也走 `state_changed`，跟着一起闷。
##    要分开得读 `is_frozen_overridden()`，而架构文档明写玩法代码不该读它。
##
## 数值是导出项：运行时在 Remote 检查器里改立刻生效（下一拍就是新目标），不用重启。

const MUSIC_BUS: StringName = &"Music"

## 世界流着时的切点。20500 Hz 在 44.1 kHz 采样率下贴着奈奎斯特频率，等于全开 ——
## 平时听不见这条效果，所以它一直挂着，不需要开开关关。
@export_range(200.0, 20500.0, 10.0) var open_cutoff_hz: float = 20500.0
## 世界冻着时的切点。**这是手感旋钮**：越低越闷；低到 400 上下曲子会同时变小声、变糊。
@export_range(100.0, 20500.0, 10.0) var frozen_cutoff_hz: float = 1000.0
## 从一头走到另一头要多久（秒，真实时间）。0 = 硬切 —— 硬切在低频上会听出一声"咚"，
## 所以默认给一拍半。
@export_range(0.0, 2.0, 0.01) var ramp_seconds: float = 0.3

var _bus: int = -1
var _effect: AudioEffectLowPassFilter = null
var _time_manager: Node = null
var _cutoff: float = 0.0
var _frozen: bool = false


func _ready() -> void:
	_build_bus()
	var player := get_node_or_null("/root/Musicplayer") as AudioStreamPlayer
	if player != null and _bus >= 0:
		player.bus = MUSIC_BUS
	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager != null:
		_frozen = _read_frozen()
		_time_manager.connect(&"state_changed", _on_state_changed)
	_cutoff = _target()
	if _effect != null:
		_effect.cutoff_hz = _cutoff


func _process(delta: float) -> void:
	var target := _target()
	if is_equal_approx(_cutoff, target):
		return
	# `ramp_seconds` 允许为 0，所以分母不能直接用它；这一步一步跳到位，正好就是"硬切"。
	var rate := absf(open_cutoff_hz - frozen_cutoff_hz) / maxf(ramp_seconds, 0.0001)
	_cutoff = move_toward(_cutoff, target, rate * delta)
	if _effect != null:
		_effect.cutoff_hz = _cutoff


## 只记"冻没冻"，不按 `TimeState` 的枚举值硬解 —— 枚举哪天重排，"闷/不闷"会整个反掉，
## 而那种反不会有任何报错。
func _on_state_changed(_new_state: int) -> void:
	_frozen = _read_frozen()


func _read_frozen() -> bool:
	return _time_manager != null and bool(_time_manager.call(&"is_time_frozen"))


func _target() -> float:
	return frozen_cutoff_hz if _frozen else open_cutoff_hz


## 幂等：总线已经在了就只认领它，不会建出第二条；总线上已经有一条低通就复用它，
## 不会每启动一次叠一条（叠起来是 -24 dB/oct 而不是 -12，听感对不上任何一次试听）。
func _build_bus() -> void:
	_bus = AudioServer.get_bus_index(MUSIC_BUS)
	if _bus < 0:
		AudioServer.add_bus()
		_bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bus, MUSIC_BUS)
		AudioServer.set_bus_send(_bus, &"Master")
	for i in AudioServer.get_bus_effect_count(_bus):
		var existing := AudioServer.get_bus_effect(_bus, i)
		if existing is AudioEffectLowPassFilter:
			_effect = existing
			return
	AudioServer.add_bus_effect(_bus, AudioEffectLowPassFilter.new())
	# 读回总线里那一份再改，不假设它和我们刚 new 出来的是同一个对象。
	_effect = AudioServer.get_bus_effect(_bus, AudioServer.get_bus_effect_count(_bus) - 1)
