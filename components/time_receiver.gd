class_name TimeReceiver
extends Node
## 通用时间源组件。作为子节点挂到任意受时停影响的对象下，代理 TimeManager 的门控 delta。
##
## 默认路径直连 TimeManager，不缓存 Callable —— 这样组件在 _ready() 之前就可用，
## 也不依赖 autoload 的初始化顺序。
## set_time_source() 是第二章锚点系统的时间流劫持入口；第一章零调用方，仅保留接口。

signal time_source_changed

const GROUP_NAME: StringName = &"time_receiver"

var _physics_source: Callable
var _process_source: Callable


func _ready() -> void:
	add_to_group(GROUP_NAME)


func get_physics_delta() -> float:
	if _physics_source.is_valid():
		return _physics_source.call()
	return TimeManager.get_physics_delta()


func get_process_delta() -> float:
	if _process_source.is_valid():
		return _process_source.call()
	return TimeManager.get_process_delta()


func is_time_frozen() -> bool:
	return get_physics_delta() <= 0.0


## 第二章锚点系统将用专属 delta 替换全局时间源。第一章不调用。
func set_time_source(physics_source: Callable, process_source: Callable) -> void:
	_physics_source = physics_source
	_process_source = process_source
	time_source_changed.emit()


func clear_time_source() -> void:
	_physics_source = Callable()
	_process_source = Callable()
	time_source_changed.emit()
