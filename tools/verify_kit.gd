extends SceneTree

const SCRIPTS := [
	"res://scenes/actors/player/player.gd",
	"res://scenes/objects/platform/platform.gd",
	"res://scenes/objects/door/door.gd",
	"res://scenes/objects/button_plate/button_plate.gd",
	"res://scenes/objects/pendulum/pendulum.gd",
	"res://scenes/objects/moving_block/moving_block.gd",
	"res://scenes/objects/ability_altar/ability_altar.gd",
	"res://scenes/objects/sensor_zone/sensor_zone.gd",
	"res://components/time_receiver.gd",
	"res://scenes/levels/level_base.gd",
	"res://scenes/levels/level_01_tutorial.gd",
	"res://scenes/levels/level_template.gd",
	"res://scenes/levels/main.gd",
]

## 这些构件必须 @tool，否则检查器里改导出项不会即时重画，摆图时看到的是过时的多边形。
const TOOL_SCRIPTS := [
	"res://scenes/objects/platform/platform.gd",
	"res://scenes/objects/door/door.gd",
	"res://scenes/objects/button_plate/button_plate.gd",
	"res://scenes/objects/pendulum/pendulum.gd",
	"res://scenes/objects/moving_block/moving_block.gd",
	"res://scenes/objects/ability_altar/ability_altar.gd",
	"res://scenes/objects/sensor_zone/sensor_zone.gd",
]

const SCENES := [
	"res://scenes/objects/platform/platform.tscn",
	"res://scenes/objects/door/door.tscn",
	"res://scenes/objects/button_plate/button_plate.tscn",
	"res://scenes/objects/pendulum/pendulum.tscn",
	"res://scenes/objects/moving_block/moving_block.tscn",
	"res://scenes/objects/ability_altar/ability_altar.tscn",
	"res://scenes/objects/sensor_zone/sensor_zone.tscn",
	"res://scenes/levels/rooms/initial_room.tscn",
	"res://scenes/levels/rooms/teaching_corridor.tscn",
	"res://scenes/levels/level_01_tutorial.tscn",
	"res://scenes/levels/level_template.tscn",
	"res://scenes/levels/main.tscn",
]

const EXPORTS := {
	"res://scenes/objects/door/door.gd": ["height", "width", "open_time", "trigger", "panel_color"],
	"res://scenes/objects/button_plate/button_plate.gd": ["width", "sensor_height", "press_depth", "plate_color"],
	"res://scenes/objects/pendulum/pendulum.gd": ["amplitude_degrees", "period", "phase", "rod_length"],
	"res://scenes/objects/moving_block/moving_block.gd": ["travel_offset", "block_size", "travel_speed", "block_color"],
	"res://scenes/objects/ability_altar/ability_altar.gd": ["width", "altar_height", "sensor_height", "active_color"],
	"res://scenes/objects/sensor_zone/sensor_zone.gd": ["width", "height", "band_centre_y", "visible_in_game"],
	"res://scenes/levels/level_base.gd": ["start_with_ability", "camera_limits"],
	"res://scenes/levels/main.gd": ["level_scene"],
}

const NODE_PATHS := {
	"res://scenes/levels/level_01_tutorial.tscn": [
		"Objects/ButtonPlate", "Objects/Door", "Objects/PendulumA", "Objects/PendulumB",
		"Objects/MovingBlock", "Objects/AbilityAltar", "Triggers/GoalZone", "Triggers/BypassZone",
		"Player", "PlayerSpawn",
	],
	"res://scenes/levels/level_template.tscn": [
		"Terrain/Floor", "Objects", "Triggers/GoalZone", "Player", "PlayerSpawn",
	],
}

const LEVEL_SCENES := [
	"res://scenes/levels/level_01_tutorial.tscn",
	"res://scenes/levels/level_template.tscn",
]

## 只按路径认门：静态写 `as Door` / `is LevelBase` 会让本脚本在编译期依赖那些脚本，
## 而它们引用 autoload TimeManager —— --script 模式下没有 autoload，verify_kit 自己就编译不过。
const DOOR_SCRIPT := "res://scenes/objects/door/door.gd"

const BAND_CENTRE := -15.0

var _failures: int = 0
var _doors_checked: int = 0


func _fail(msg: String) -> void:
	_failures += 1
	print("VERIFY FAIL: ", msg)


func _initialize() -> void:
	for path in SCRIPTS:
		var script := load(path) as GDScript
		if script == null:
			_fail("load script %s" % path)
			continue
		if script.reload() != OK:
			_fail("reload != OK %s" % path)
			continue
		var instance = script.new()
		if instance == null:
			_fail("new() == null %s" % path)
			continue
		if EXPORTS.has(path):
			for property in EXPORTS[path]:
				if not (property in instance):
					_fail("missing export %s on %s" % [property, path])
		instance.free()
	for path in TOOL_SCRIPTS:
		if not FileAccess.get_file_as_string(path).begins_with("@tool"):
			_fail("not @tool: %s" % path)
	for path in SCENES:
		var packed := load(path) as PackedScene
		if packed == null:
			_fail("load scene %s" % path)
			continue
		var node = packed.instantiate()
		if node == null:
			_fail("instantiate %s" % path)
			continue
		if NODE_PATHS.has(path):
			for child_path in NODE_PATHS[path]:
				if node.get_node_or_null(NodePath(child_path)) == null:
					_fail("missing node %s/%s" % [path, child_path])
		if path == "res://scenes/levels/level_01_tutorial.tscn":
			_check_scene(node)
		if path in LEVEL_SCENES:
			_check_door_triggers(node)
		node.free()


## 第二阶段必须等到第一帧：--script 模式下 _initialize() 跑在 root 就绪之前，
## 那时 add_child 的子节点 _ready() 会被推迟，读到的全是 .tscn 里的存量值。
func _process(_delta: float) -> bool:
	_verify_ready_geometry()
	# 检查空转比检查失败更糟：门数一旦对不上，说明上面的递归没走到门。
	if _doors_checked < 2:
		_fail("只查到 %d 扇门配了接线（期望至少 2：引导关 + 模板）" % _doors_checked)
	print("VERIFY DONE doors=%d failures=%d" % [_doors_checked, _failures])
	quit(_failures > 0)
	return false


## 进树 -> _ready() 真的执行。返回未定型值，后面才能按动态成员访问。
func _enter(path: String):
	var node = load(path).instantiate()
	root.add_child(node)
	return node


## 第二阶段：真的进树，让 _ready() -> _rebuild() 跑一遍，验派生几何。
## 只挑不碰 TimeReceiver 的构件：门与按钮在第一帧就早退，pendulum / moving_block
## 会无条件向 TimeManager 要 delta，而 --script 模式下 autoload 不一定在。
func _verify_ready_geometry() -> void:
	var door_a = _enter("res://scenes/objects/door/door.tscn")
	var door_b = _enter("res://scenes/objects/door/door.tscn")
	var shape_a = door_a.get_node("CollisionShape2D")
	var shape_b = door_b.get_node("CollisionShape2D")
	if shape_a.shape == null:
		_fail("Door shape not created")
	elif shape_a.shape.size != Vector2(32, 96):
		_fail("Door closed shape=%s" % str(shape_a.shape.size))
	if shape_a.position != Vector2(0, -48):
		_fail("Door closed shape position=%s" % str(shape_a.position))
	if shape_a.shape == shape_b.shape:
		_fail("两扇门共用同一份形状资源：一扇门关门会把另一扇也拽小")
	var door_visual = door_a.get_node("Visual")
	if door_visual.polygon.size() != 4:
		_fail("Door visual polygon not rebuilt")

	var button = _enter("res://scenes/objects/button_plate/button_plate.tscn")
	var button_shape = button.get_node("CollisionShape2D")
	if button_shape.position != Vector2(0, BAND_CENTRE):
		_fail("ButtonPlate band centre=%s (expect %s)" % [str(button_shape.position), str(BAND_CENTRE)])
	if button_shape.shape.size != Vector2(64, 24):
		_fail("ButtonPlate band size=%s" % str(button_shape.shape.size))

	var altar = _enter("res://scenes/objects/ability_altar/ability_altar.tscn")
	var altar_shape = altar.get_node("CollisionShape2D")
	if altar_shape.position != Vector2(0, BAND_CENTRE):
		_fail("AbilityAltar band centre=%s" % str(altar_shape.position))
	var altar_visual = altar.get_node("Visual")
	if altar_visual.polygon[0].y > 0.0 or altar_visual.polygon[2].y > 0.0:
		_fail("AbilityAltar 台座向地面下方生长，底边中心原点没改过来")

	var zone = _enter("res://scenes/objects/sensor_zone/sensor_zone.tscn")
	var zone_shape = zone.get_node("CollisionShape2D")
	if zone_shape.position != Vector2(0, BAND_CENTRE):
		_fail("SensorZone band centre=%s" % str(zone_shape.position))
	var zone_visual = zone.get_node("Visual")
	if zone_visual.visible:
		_fail("SensorZone 辅助多边形在运行进程里不该可见")
	# 门的 trigger 判的是信号名，不是类型：这两条一改名，所有拖出来的接线会静默失效。
	for source in [button, zone]:
		if not source.has_signal("pressed_changed"):
			_fail("%s 缺 pressed_changed，接不上门的 trigger" % source.name)

	for node in [door_a, door_b, button, altar, zone]:
		root.remove_child(node)
		node.free()


## 未进场景树 => 构件的 _ready()/_rebuild() 没跑，CollisionShape2D 的 position 还是
## .tscn 里存的旧值（BypassZone 把 band_centre_y 改成 0，shape 位置不会跟着写回）。
## 所以这里只验导出项——那才是摆图的人会动手改、_rebuild 会据此重算的输入。
func _check_scene(level) -> void:
	var button = level.get_node("Objects/ButtonPlate")
	if button.sensor_height <= 0.0 or button.width <= 0.0:
		_fail("ButtonPlate band size is degenerate")
	var altar = level.get_node("Objects/AbilityAltar")
	if altar.position != Vector2(1808, -128):
		_fail("AbilityAltar position=%s (bottom-centre origin expected)" % str(altar.position))
	if altar.altar_height <= 0.0:
		_fail("AbilityAltar altar_height <= 0")
	var goal = level.get_node("Triggers/GoalZone")
	if not (goal is SensorZone):
		_fail("GoalZone is not a SensorZone")
	if goal.band_centre_y != BAND_CENTRE:
		_fail("GoalZone band_centre_y=%s (expect %s)" % [str(goal.band_centre_y), str(BAND_CENTRE)])
	var bypass = level.get_node("Triggers/BypassZone")
	if bypass.band_centre_y != 0.0:
		_fail("BypassZone band_centre_y=%s (floating band expects 0)" % str(bypass.band_centre_y))
	if level.camera_limits != Rect2(-96, -416, 2080, 512):
		_fail("camera_limits changed: %s" % str(level.camera_limits))
	var block = level.get_node("Objects/MovingBlock")
	if block.travel_offset != Vector2(0, -72):
		_fail("MovingBlock travel_offset=%s" % str(block.travel_offset))
	if block.position != Vector2(1376, -208):
		_fail("MovingBlock position=%s" % str(block.position))


## 关卡脚本不再持有门：门开不开只取决于场景里这条 trigger 路径。
## 所以漏配 / 配了个不发信号的节点，必须在无头守门里就炸出来，不能等试玩时"门怎么不开"。
## 刻意不走 get_node：实测未进树的实例里 `get_node("Objects/Door")` 这种两段路径会返回
## null（同层单段却正常），所以自己把 path→node 收成字典，用同一套拼法查。
func _check_door_triggers(root: Node) -> void:
	var by_path := {}
	_collect_paths(root, "", by_path)
	for path in by_path:
		var script: Script = by_path[path].get_script()
		if script == null or script.resource_path != DOOR_SCRIPT:
			continue
		_doors_checked += 1
		var target := _resolve_door_path(path, by_path[path].get("trigger"))
		if target == "":
			_fail("门 %s 的 trigger 是空的" % path)
		elif not by_path.has(target):
			_fail("门 %s 的 trigger 指向不存在的节点 %s" % [path, target])
		elif not by_path[target].has_signal("pressed_changed"):
			_fail("门 %s 的 trigger %s 不发 pressed_changed" % [path, target])


func _collect_paths(node: Node, prefix: String, out: Dictionary) -> void:
	for child in node.get_children():
		var name := String(child.name)
		var path := name if prefix == "" else prefix + "/" + name
		out[path] = child
		_collect_paths(child, path, out)


## 把门看到的相对路径（../ButtonPlate）折成关卡根视角的绝对路径。
func _resolve_door_path(door_path: String, rel: NodePath) -> String:
	if rel.is_empty():
		return ""
	var steps := PackedStringArray()
	for i in rel.get_name_count():
		steps.append(String(rel.get_name(i)))
	var base := PackedStringArray(door_path.split("/"))
	while steps.size() > 0 and steps[0] == "..":
		steps.remove_at(0)
		if base.size() > 0:
			base.remove_at(base.size() - 1)
	if steps.size() == 0:
		return ""
	if rel.is_absolute():
		return "/".join(steps)
	base.append_array(steps)
	return "/".join(base)
