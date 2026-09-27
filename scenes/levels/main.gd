class_name Main
extends Node
## 常驻 World 根（设计文档 4.1 的 World）。
##
## 灰滤镜与调试面板挂在这里而不是关卡里：关卡只在 LevelContainer 下换入换出，
## 切换不会打断滤镜过渡，也不必每个关卡重复实例化 overlay。
## 第一章只有一个关卡，但 M4 会有 3~5 个谜题关，届时这个结构直接受益。

## 没指路时跑这一张：引导关。当前 demo 阶段的正式入口由 `main.tscn` 的 `level_scene`
## 指向 `scenes/levels/level_1/`，本常量退为兜底。M1 沙盒仍由「打开其场景 + F6」单独运行。
const INITIAL_LEVEL: PackedScene = preload("res://scenes/levels/level_01_tutorial.tscn")
const FPS_CAP: int = 30

## 把这一项指向要跑的关卡场景（当前 demo = level_1/level1.tscn），留空即走上面的兜底关。
## 为什么不用 F6 直接跑关卡场景：F6 跑的是当前打开的场景，绕过了 main.tscn，
## 于是灰滤镜与调试面板都看不到（它们挂在 Main 下），更要紧的是 `run_state` 不在场 ——
## 存档点不记位置、死亡直接回出生点（`LevelBase._warn_no_world_root()` 会在开局警告一次）。
## 需要这条链为真时，指这里而不是 F6。
@export var level_scene: PackedScene

var _current_scene: PackedScene
var _current_level: Node

## 跨重载的粘性进度（D31）：关卡场景每死一次就整个换掉，本条命攒下的进度只能住在这个
## 常驻根上，LevelBase 在 _ready() 里回灌。只存四个键，语义由 LevelBase 定义：
## - respawn_position: Vector2 —— 现在死会回到哪儿。写它的一共有两处：踩上存档点、
##   以及第一次获得能力那一拍演完（D62）。没有则从 PlayerSpawn 开局。
## - respawn_marker: NodePath —— 那个重生位相对关卡根的**存档点**路径（D51）。位置只说"回哪儿"，
##   这个键说"是哪一台"：新实例里按它把那一台点亮，否则重生位对了、皮却全灭。
##   **它可以整个不在**（D62）：祭坛那一发存的是玩家落脚点、不属于任何一台，
##   于是那一发会把本键抹掉 —— 留着旧路径等于让下次重载点亮一台已经不成立的存档点。
## - altar_spent: bool —— 祭坛已耗。既决定祭坛重载后的样子，也推导能力是否开启
##   （D31 订正：不另存 ability_granted，两个布尔各自漂移就是软锁）。
## - collectibles_taken: Array[NodePath] —— 这一关里已经被拿走的彩蛋（D54）。存身份不存
##   位置：彩蛋不挪窝，"拿没拿过"就是这一个事实；死一次不许复生是用户裁定，
##   而主动重开（R / 终点）走上面的 run_state.clear()，彩蛋因此复位 —— 那条路是"重开这一关"，
##   不是"重活一次"。
var run_state: Dictionary = {}

## 开局苏醒演过了没（D57，用户裁 A1 档 = 每次**进程启动**演一次）。刻意不住在
## `run_state` 里：那个字典在换关与 R 重开时被清空，而苏醒不该跟着重来一次 ——
## 它记的是"这个进程有没有开场过"，与进度无关。也不落盘：项目目前没有跨进程的存档（M6 未开工），
## 为一个 bool 开第一条写盘路径不值得，等 M6 的存档真来了再把它搬进去。
var _intro_played: bool = false

@onready var _level_container: Node2D = $LevelContainer


func _ready() -> void:
	add_to_group(&"world_root")
	load_level(level_scene if level_scene != null else INITIAL_LEVEL)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"restart"):
		restart_level()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"dev_fps_cap"):
		_toggle_fps_cap()
		get_viewport().set_input_as_handled()


func load_level(scene: PackedScene) -> void:
	# 只有真正换关才清进度：死亡重载的是同一张场景，存档点必须活过这一跳。
	if scene != _current_scene:
		run_state.clear()
	_current_scene = scene
	if is_instance_valid(_current_level):
		_level_container.remove_child(_current_level)
		_current_level.queue_free()
	_current_level = scene.instantiate()
	_level_container.add_child(_current_level)


func restart_level() -> void:
	if _current_scene == null:
		return
	# R / 终点收尾的主动重开 = 从头开始本关，进度一并作废；死亡重载走 reload_level。
	run_state.clear()
	load_level(_current_scene)


## 死亡重载：换一个新场景实例但保留 run_state —— 存档点就是为这一跳而活的。
## 与 restart_level 是仅有的两个重载入口，「清不清进度」就是它们的全部区别。
func reload_level() -> void:
	if _current_scene == null:
		return
	load_level(_current_scene)


func get_run_state() -> Dictionary:
	return run_state


## 一次性取用"这个进程还没演过开场"这个事实：第一个进关的关卡根把它拿走，之后一律 false。
## 设计成 take 而不是 let 关卡读布尔再自己写，是为了不给关卡"读到了但忘了写回"的机会 ——
## 那种漏法在画面上的表现是每关开局都演一遍，正是 D51 那条"有读没人写"的镜像。
func take_intro() -> bool:
	if _intro_played:
		return false
	_intro_played = true
	return true


## M1 验收「30fps 与 60fps 下判定一致」的开关：F1 在不限帧与 30fps 之间切换。
## 限帧后每渲染帧会跑约 2 次物理步，正是 process delta 方案会翻倍计时的场景。
func _toggle_fps_cap() -> void:
	Engine.max_fps = FPS_CAP if Engine.max_fps == 0 else 0
