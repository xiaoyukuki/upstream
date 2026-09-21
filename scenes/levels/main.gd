class_name Main
extends Node
## 常驻 World 根（设计文档 4.1 的 World）。
##
## 灰滤镜与调试面板挂在这里而不是关卡里：关卡只在 LevelContainer 下换入换出，
## 切换不会打断滤镜过渡，也不必每个关卡重复实例化 overlay。
## 第一章只有一个关卡，但 M4 会有 3~5 个谜题关，届时这个结构直接受益。

## 引导关是正式入口。M1 沙盒改由「打开其场景 + F6」单独运行，仍是手感调试场。
const INITIAL_LEVEL: PackedScene = preload("res://scenes/levels/level_01_tutorial.tscn")
const FPS_CAP: int = 30

## 调试自己新搭的关卡时把这一项指向那张场景，留空即走引导关。
## 为什么不用 F6 直接跑关卡场景：F6 跑的是当前打开的场景，绕过了 main.tscn，
## 灰滤镜与调试面板都挂在 Main 下，于是运行时什么都看不到，像是功能没生效。
@export var level_scene: PackedScene

var _current_scene: PackedScene
var _current_level: Node

## 跨重载的粘性进度（D31）：关卡场景每死一次就整个换掉，本条命攒下的进度只能住在这个
## 常驻根上，LevelBase 在 _ready() 里回灌。只存两个键，语义由 LevelBase 定义：
## - respawn_position: Vector2 —— 最近存档点；没有则从 PlayerSpawn 开局。
## - altar_spent: bool —— 祭坛已耗。既决定祭坛重载后的样子，也推导能力是否开启
##   （D31 订正：不另存 ability_granted，两个布尔各自漂移就是软锁）。
var run_state: Dictionary = {}

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


## M1 验收「30fps 与 60fps 下判定一致」的开关：F1 在不限帧与 30fps 之间切换。
## 限帧后每渲染帧会跑约 2 次物理步，正是 process delta 方案会翻倍计时的场景。
func _toggle_fps_cap() -> void:
	Engine.max_fps = FPS_CAP if Engine.max_fps == 0 else 0
