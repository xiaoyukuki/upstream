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
	"res://scenes/objects/spikes/spikes.gd",
	"res://scenes/objects/electric_bar/electric_bar.gd",
	"res://scenes/objects/key_pickup/key_pickup.gd",
	"res://scenes/objects/key_door/key_door.gd",
	"res://scenes/objects/checkpoint/checkpoint.gd",
	"res://components/time_receiver.gd",
	"res://components/hazard_base.gd",
	"res://scenes/levels/level_base.gd",
	"res://scenes/levels/level_01_tutorial.gd",
	"res://scenes/levels/level_template.gd",
	"res://scenes/levels/main.gd",
]
# tile_draw.gd 刻意不在：它 extends RefCounted，下面的 instance.free() 对它不成立，
# 且它没有状态可验 —— 作为 Spikes/ElectricBar/KeyDoor 的 preload 已被连带编译。

## 这些构件必须 @tool，否则检查器里改导出项不会即时重画，摆图时看到的是过时的多边形。
const TOOL_SCRIPTS := [
	"res://scenes/objects/platform/platform.gd",
	"res://scenes/objects/door/door.gd",
	"res://scenes/objects/button_plate/button_plate.gd",
	"res://scenes/objects/pendulum/pendulum.gd",
	"res://scenes/objects/moving_block/moving_block.gd",
	"res://scenes/objects/ability_altar/ability_altar.gd",
	"res://scenes/objects/sensor_zone/sensor_zone.gd",
	"res://scenes/objects/spikes/spikes.gd",
	"res://scenes/objects/electric_bar/electric_bar.gd",
	"res://scenes/objects/key_pickup/key_pickup.gd",
	"res://scenes/objects/key_door/key_door.gd",
	"res://scenes/objects/checkpoint/checkpoint.gd",
	"res://components/hazard_base.gd",
]

## 关卡场景不再手写白名单 —— 见 _discover_level_scenes()：扫 scenes/levels 整棵子树，
## 新关自动进守门。这里只留构件、房间与常驻根的可实例化冒烟。
const SCENES := [
	"res://scenes/objects/platform/platform.tscn",
	"res://scenes/objects/door/door.tscn",
	"res://scenes/objects/button_plate/button_plate.tscn",
	"res://scenes/objects/pendulum/pendulum.tscn",
	"res://scenes/objects/moving_block/moving_block.tscn",
	"res://scenes/objects/ability_altar/ability_altar.tscn",
	"res://scenes/objects/sensor_zone/sensor_zone.tscn",
	"res://scenes/objects/spikes/spikes.tscn",
	"res://scenes/objects/electric_bar/electric_bar.tscn",
	"res://scenes/objects/key_pickup/key_pickup.tscn",
	"res://scenes/objects/key_door/key_door.tscn",
	"res://scenes/objects/checkpoint/checkpoint.tscn",
	"res://scenes/levels/rooms/initial_room.tscn",
	"res://scenes/levels/rooms/teaching_corridor.tscn",
	"res://scenes/levels/main.tscn",
]

const EXPORTS := {
	"res://scenes/objects/door/door.gd": ["height", "width", "open_time", "trigger"],
	"res://scenes/objects/button_plate/button_plate.gd": ["width", "sensor_height", "press_depth"],
	"res://scenes/objects/pendulum/pendulum.gd": ["amplitude_degrees", "period", "phase", "rod_length"],
	"res://scenes/objects/moving_block/moving_block.gd": ["travel_offset", "block_size", "travel_speed", "block_color"],
	"res://scenes/objects/ability_altar/ability_altar.gd": ["width", "altar_height", "sensor_height", "active_color"],
	"res://scenes/objects/sensor_zone/sensor_zone.gd": ["width", "height", "band_centre_y", "visible_in_game"],
	"res://scenes/objects/spikes/spikes.gd": ["length"],
	"res://scenes/objects/electric_bar/electric_bar.gd": ["length", "period", "duty", "phase", "blocks_when_live"],
	"res://scenes/objects/key_door/key_door.gd": ["height", "width", "sensor_reach", "sensor_height", "key", "swipe_time"],
	"res://scenes/levels/level_base.gd": ["start_with_ability", "camera_limits", "death_time"],
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

## 只按路径认门：静态写 `as Door` / `is LevelBase` 会让本脚本在编译期依赖那些脚本，
## 而它们引用 autoload TimeManager —— --script 模式下没有 autoload，verify_kit 自己就编译不过。
const DOOR_SCRIPT := "res://scenes/objects/door/door.gd"
const BUTTON_SCRIPT := "res://scenes/objects/button_plate/button_plate.gd"
const ALTAR_SCRIPT := "res://scenes/objects/ability_altar/ability_altar.gd"
const SENSOR_SCRIPT := "res://scenes/objects/sensor_zone/sensor_zone.gd"
const KEYDOOR_SCRIPT := "res://scenes/objects/key_door/key_door.gd"
const KEY_SCRIPT := "res://scenes/objects/key_pickup/key_pickup.gd"
## 关卡脚本的共同祖先，用来「这是不是一个真关卡」而不是靠文件名猜。
const LEVEL_BASE_SCRIPT := "res://scenes/levels/level_base.gd"

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
		node.free()

	# 关卡走自动发现，不靠手写白名单：新关摆完就自动进守门，忘了登记也不至于裸奔。
	for path in _discover_level_scenes():
		var level = load(path).instantiate()
		if level == null:
			_fail("instantiate %s" % path)
			continue
		if NODE_PATHS.has(path):
			for child_path in NODE_PATHS[path]:
				if level.get_node_or_null(NodePath(child_path)) == null:
					_fail("missing node %s/%s" % [path, child_path])
		_check_level_contract(level, path)
		_check_door_triggers(level)
		_check_level_hazards(level, path)
		_check_key_wiring(level, path)
		level.free()


## 第二阶段必须等到第一帧：--script 模式下 _initialize() 跑在 root 就绪之前，
## 那时 add_child 的子节点 _ready() 会被推迟，读到的全是 .tscn 里的存量值。
func _process(_delta: float) -> bool:
	_verify_ready_geometry()
	_verify_props()
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
## --script 模式下 autoload 实测**在场**（2026-09-20 探针：/root/TimeManager 存在、
## 电棒时钟照走），所以每帧要门控 delta 的 ElectricBar/KeyDoor 也能进树；
## pendulum / moving_block 仍只验实例化 —— 它们验的是行程时序，静态几何没东西可比。
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

	var button = _enter("res://scenes/objects/button_plate/button_plate.tscn")
	var button_shape = button.get_node("CollisionShape2D")
	if button_shape.position != Vector2(0, BAND_CENTRE):
		_fail("ButtonPlate band centre=%s (expect %s)" % [str(button_shape.position), str(BAND_CENTRE)])
	if button_shape.shape.size != Vector2(64, 24):
		_fail("ButtonPlate band size=%s" % str(button_shape.shape.size))
	# D25：立绘改由 _draw() 平铺零件，占位 Polygon2D 留着就会画在立绘上面。
	for reskinned in [door_a, button]:
		if reskinned.get_node_or_null("Visual") != null:
			_fail("%s 还带着占位 Visual 节点（D25 已改 _draw 平铺零件）" % reskinned.name)

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

	_verify_m5_geometry()


## M5 零件（D29~D38）：进树让 _rebuild() 跑完，验判死/拾取/存档带的派生几何、
## 碰撞层契约（层值住在 .tscn 里，运行时谁翻过都会在这里露馅）、以及改导出项后
## 盒子跟着重算的 setter 链路。
func _verify_m5_geometry() -> void:
	var spikes = _enter("res://scenes/objects/spikes/spikes.tscn")
	_check_area_layers(spikes, "Spikes", 0)
	var spike_shape: CollisionShape2D = spikes.get_node("CollisionShape2D")
	if spike_shape.shape.size != Vector2(48.0, 14.0):
		_fail("Spikes 判死盒 %s（应 48x14，只罩画出来的牙）" % str(spike_shape.shape.size))
	if spike_shape.position != Vector2(0.0, -7.0):
		_fail("Spikes 判死盒带心 %s（应 (0,-7)，底边中心原点）" % str(spike_shape.position))

	var bar = _enter("res://scenes/objects/electric_bar/electric_bar.tscn")
	_check_area_layers(bar, "ElectricBar", 0)
	var bar_kill: CollisionShape2D = bar.get_node("CollisionShape2D")
	if bar_kill.shape.size != Vector2(128.0, 10.0) or bar_kill.position != Vector2.ZERO:
		_fail("ElectricBar 判死盒 %s @ %s（应 128x10 居中：原点是光束中心）"
			% [str(bar_kill.shape.size), str(bar_kill.position)])
	var blocker: StaticBody2D = bar.get_node("Blocker")
	var blocker_shape: CollisionShape2D = bar.get_node("Blocker/BlockerShape")
	if blocker_shape.shape.size != Vector2(148.0, 18.0):
		_fail("ElectricBar 挡路盒 %s（应 148x18 罩整条纹带：站极柱顶的人不算踩电）"
			% str(blocker_shape.shape.size))
	if blocker.collision_layer != 0:
		_fail("ElectricBar 默认 blocks_when_live=false，挡路盒该退层（layer 0），却在 %d"
			% blocker.collision_layer)
	bar.length = 64.0
	if bar_kill.shape.size != Vector2(64.0, 10.0) or blocker_shape.shape.size != Vector2(84.0, 18.0):
		_fail("ElectricBar 改 length 后两个盒没跟着重算")

	var bar_wall = load("res://scenes/objects/electric_bar/electric_bar.tscn").instantiate()
	bar_wall.blocks_when_live = true
	root.add_child(bar_wall)
	if bar_wall.get_node("Blocker").collision_layer != 4:
		_fail("ElectricBar blocks_when_live=true 且初始通电，挡路盒该上 time_solid 层（4）")
	root.remove_child(bar_wall)
	bar_wall.free()

	var card = _enter("res://scenes/objects/key_pickup/key_pickup.tscn")
	_check_area_layers(card, "KeyPickup", 8)
	var card_shape: CollisionShape2D = card.get_node("CollisionShape2D")
	if card_shape.shape.size != Vector2(32.0, 24.0) or card_shape.position != Vector2(0.0, BAND_CENTRE):
		_fail("KeyPickup 拾取带 %s @ %s（应 32x24 @ (0,-15)）"
			% [str(card_shape.shape.size), str(card_shape.position)])

	var save_point = _enter("res://scenes/objects/checkpoint/checkpoint.tscn")
	_check_area_layers(save_point, "Checkpoint", 8)
	var save_shape: CollisionShape2D = save_point.get_node("CollisionShape2D")
	if save_shape.shape.size != Vector2(32.0, 24.0) or save_shape.position != Vector2(0.0, BAND_CENTRE):
		_fail("Checkpoint 存档带 %s @ %s（应 32x24 @ (0,-15)）"
			% [str(save_shape.shape.size), str(save_shape.position)])

	# 刷卡门带卡进树：key 空着进树会打「永远开不了」的运行时警告，裸构件不是错误配置，别制造噪音。
	var rig := Node2D.new()
	root.add_child(rig)
	var gate_card = load("res://scenes/objects/key_pickup/key_pickup.tscn").instantiate()
	gate_card.name = "Card"
	var gate = load("res://scenes/objects/key_door/key_door.tscn").instantiate()
	gate.name = "Gate"
	gate.key = NodePath("../Card")
	rig.add_child(gate_card)
	rig.add_child(gate)
	if gate.collision_layer != 4 or gate.collision_mask != 0:
		_fail("KeyDoor 本体 layer=%d mask=%d（实体门应 4/0）"
			% [gate.collision_layer, gate.collision_mask])
	var gate_col: CollisionShape2D = gate.get_node("CollisionShape2D")
	var gate_rect: RectangleShape2D = gate_col.shape
	if gate_rect.size != Vector2(32.0, 96.0) or gate_col.position != Vector2(0.0, -48.0):
		_fail("KeyDoor 关态光幕碰撞体 %s @ %s（应 32x96 @ (0,-48)）"
			% [str(gate_rect.size), str(gate_col.position)])
	var curtain: Rect2 = gate.curtain_rect()
	if curtain != Rect2(-16.0, -96.0, 32.0, 96.0):
		_fail("KeyDoor curtain_rect %s（关态应 (-16,-96,32,96)）" % str(curtain))
	# 「碰撞体 == 画出来的」同一截判定（D36 第 6 条 b）：上下沿与宽度都必须重合，
	# 差一格就是「看着能过实际过不去」。行程中段由 kit_selftest 在真进度下再验。
	if absf((gate_col.position.y - gate_rect.size.y * 0.5) - curtain.position.y) > 0.01 \
			or absf((gate_col.position.y + gate_rect.size.y * 0.5)
				- (curtain.position.y + curtain.size.y)) > 0.01 \
			or absf(gate_rect.size.x - curtain.size.x) > 0.01:
		_fail("KeyDoor 光幕碰撞体与 curtain_rect 不是同一截")
	_check_area_layers(gate.get_node("Reader"), "KeyDoor.Reader", 0)
	var reader_shape: CollisionShape2D = gate.get_node("Reader/ReaderShape")
	if reader_shape.shape.size != Vector2(80.0, 40.0) or reader_shape.position != Vector2(0.0, BAND_CENTRE):
		_fail("KeyDoor 感应带 %s @ %s（应 80x40 @ (0,-15)）"
			% [str(reader_shape.shape.size), str(reader_shape.position)])

	for node in [spikes, bar, card, save_point, rig]:
		root.remove_child(node)
		node.free()


## 危险物（与 KeyDoor 的查询 Reader）共用层值：layer 0（绝不上 sensor 层 —— 玩家的
## 头顶净空查询会把上了 sensor 层的通电棒读成「头顶是空的」，D29/D27 交叉核对的硬约束）
## + mask 2（只认玩家）+ 不可被探测。传感器族（拾取带/存档带）则住 sensor 层 8。
func _check_area_layers(area: Area2D, label: String, want_layer: int) -> void:
	if area.collision_layer != want_layer or area.collision_mask != 2 or area.monitorable:
		_fail("%s 层契约破了：layer=%d mask=%d monitorable=%s（应 %d/2/false）"
			% [label, area.collision_layer, area.collision_mask, str(area.monitorable), want_layer])


## 关卡实例里的危险物层契约。发现判据与 LevelBase._bind_hazards 同一个信号名 ——
## 关卡里摆的每个危险物在这里按同一套规则再过一遍。
func _check_level_hazards(node: Node, path: String) -> void:
	if node.has_signal("touched_player"):
		_check_area_layers(node, "%s/%s" % [path, str(node.name)], 0)
	for child in node.get_children():
		_check_level_hazards(child, path)


## 刷卡门接线（D30 第 6 条 / D36 第 6 条）：门必须接卡、接的必须是 KeyPickup、
## 一张卡最多被一扇门引用 —— 两扇门共享一张卡时，先闩的那扇把卡耗掉，另一扇永远开不了。
func _check_key_wiring(level: Node, path: String) -> void:
	var by_path := {}
	_collect_paths(level, "", by_path)
	var card_users := {}
	for node_path in by_path:
		var node: Node = by_path[node_path]
		var script: Script = node.get_script()
		if script == null or script.resource_path != KEYDOOR_SCRIPT:
			continue
		var rel: NodePath = node.get("key")
		if rel.is_empty():
			_fail("%s 的 %s 没接 key，这扇门永远开不了" % [path, node_path])
			continue
		var target := _fold_rel_path(node_path, rel)
		if not by_path.has(target):
			_fail("%s 的 %s key 指向不存在的节点 %s" % [path, node_path, target])
			continue
		var tscript: Script = by_path[target].get_script()
		if tscript == null or tscript.resource_path != KEY_SCRIPT:
			_fail("%s 的 %s key 指向的不是 KeyPickup（%s）" % [path, node_path, target])
			continue
		if card_users.has(target):
			_fail("%s 的 %s 与 %s 共用一张卡（%s）：一扇消耗后另一扇永远闩不上"
				% [path, card_users[target], node_path, target])
		card_users[target] = node_path


## D25 立绘零件：尺寸照 props.json，像素契约照「平铺必须自洽」那套思路 ——
## 缝行不暗则卷帘平铺出亮带、底边不琥珀则门底读不出、前唇不比凹槽亮则「踩下」读不出。
## 灯色常量生成器与构件各写一份，谁单独改谁在这里响；用 get_script_constant_map 取，
## 避免本脚本在编译期依赖引用 autoload 的构件脚本（见 DOOR_SCRIPT 那条注释）。
func _verify_props() -> void:
	var f := FileAccess.open("res://assets/props/props.json", FileAccess.READ)
	if f == null:
		_fail("props.json 不在（跑 py tools/gen_props.py --emit）")
		return
	var m: Dictionary = JSON.parse_string(f.get_as_text())
	var parts: Dictionary = m["parts"]
	for pname in parts:
		var tex := load("res://assets/props/%s.png" % pname) as Texture2D
		if tex == null:
			_fail("零件纹理不在: %s" % pname)
			continue
		var want: Array = parts[pname]
		if tex.get_width() != int(want[0]) or tex.get_height() != int(want[1]):
			_fail("零件 %s 尺寸 %s 与清单 %s 不一致" % [pname, str(tex.get_size()), str(want)])
	var slat := _img("door_slat")
	if slat != null and _lum(slat, 8, 7) >= _lum(slat, 8, 0):
		_fail("door_slat 缝行不比高光行暗：卷帘平铺会出亮带")
	var bottom := _img("door_bottom")
	if bottom != null:
		var amber := bottom.get_pixel(4, 2)
		var stripe := bottom.get_pixel(0, 2)
		if not (amber.r > 0.8 and amber.g > 0.5 and amber.b < 0.4):
			_fail("door_bottom 不是琥珀警示条: %s" % str(amber))
		if _lum(bottom, 0, 2) >= _lum(bottom, 4, 2):
			_fail("door_bottom 斜条没有明暗对比: %s vs %s" % [str(stripe), str(amber)])
	var base := _img("button_base")
	if base != null and _lum(base, 8, 0) <= _lum(base, 8, 5):
		_fail("button_base 前唇不比凹槽亮：踩下状态读不出")
	var dc: Dictionary = (load(DOOR_SCRIPT) as GDScript).get_script_constant_map()
	var bc: Dictionary = (load(BUTTON_SCRIPT) as GDScript).get_script_constant_map()
	_check_color("Door.LED_SOCKET", dc["LED_SOCKET"], m["led_socket"])
	_check_color("Door.LED_LIT", dc["LED_LIT"], m["led_lit"])
	_check_color("ButtonPlate.END_SHADE", bc["END_SHADE"], m["end_shade"])
	_check_color("ButtonPlate.SOCKET", bc["SOCKET"], m["button_socket"])
	_check_color("ButtonPlate.LED_LIT", bc["LED_LIT"], m["led_lit"])
	# M5（D36 第 6/7 条）：光幕三色与门楣底座各自同源 —— LED 锁色 = 钥匙卡同色是语义不是巧合。
	var kc: Dictionary = (load(KEYDOOR_SCRIPT) as GDScript).get_script_constant_map()
	_check_color("KeyDoor.LED_SOCKET", kc["LED_SOCKET"], m["led_socket"])
	_check_color("KeyDoor.LED_LOCKED", kc["LED_LOCKED"], m["gate_led_locked"])
	_check_color("KeyDoor.LED_LIT", kc["LED_LIT"], m["gate_led_lit"])
	_check_color("KeyDoor.CURTAIN", kc["CURTAIN"], m["gate_curtain"])


func _img(pname: String) -> Image:
	var tex := load("res://assets/props/%s.png" % pname) as Texture2D
	if tex == null:
		_fail("零件纹理不在: %s" % pname)
		return null
	return tex.get_image()


func _lum(img: Image, x: int, y: int) -> float:
	var c := img.get_pixel(x, y)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _check_color(what: String, c: Color, rgb: Array) -> void:
	var want := Color8(int(rgb[0]), int(rgb[1]), int(rgb[2]))
	if absf(c.r - want.r) > 0.004 or absf(c.g - want.g) > 0.004 or absf(c.b - want.b) > 0.004:
		_fail("%s = %s 与 props.json %s 不同源" % [what, str(c), str(rgb)])


## 扫 scenes/levels 整棵子树，凡是根节点挂着 LevelBase（含子类）的场景都是关卡。
## 好处：新关摆完自动进守门，不用回来往白名单里加一行；副作用是 rooms/ 与 main.tscn
## 也会被扫到，但它们不是 LevelBase，_check_level_contract() 会自己跳过。
func _discover_level_scenes() -> PackedStringArray:
	var found := PackedStringArray()
	# 用 Array 而不是 PackedStringArray 当待办栈：后者没有 pop_back。
	var pending: Array = ["res://scenes/levels"]
	while not pending.is_empty():
		var dir = pending.pop_back() as String
		var da := DirAccess.open(dir)
		if da == null:
			_fail("打不开目录 %s" % dir)
			continue
		for sub in da.get_directories():
			pending.append(dir.path_join(sub))
		for file in da.get_files():
			if not file.ends_with(".tscn"):
				continue
			var path := dir.path_join(file)
			var packed := load(path) as PackedScene
			if packed == null:
				continue
			var root = packed.instantiate()
			if root == null:
				continue
			# 只认「根节点脚本 == level_base.gd 或它的子类」的场景。
			if _is_level_root(root):
				found.append(path)
			root.free()
	found.sort()
	return found


## 关卡脚本都是 extends LevelBase，但脚本继承链要顺着 resource_path 走一遍才判得出来
## （不能写 `is LevelBase`，那会让本脚本编译期依赖它，而它引用 autoload）。
func _is_level_root(node) -> bool:
	var script: Script = node.get_script()
	var guard := 0
	while script != null and guard < 8:
		if script.resource_path == LEVEL_BASE_SCRIPT:
			return true
		script = script.get_base_script()
		guard += 1
	return false


## 关卡级契约。刻意**不验任何摆位坐标**（祭坛在哪、相机取景框多大、方块行程多长）——
## 那些是摆图的人每天都在动的东西，钉死在守门里只会让「挪一下祭坛」变成 FAIL。
## 守门该守的是构件契约与结构完整性。
func _check_level_contract(level, path: String) -> void:
	var player = level.get_node_or_null("Player")
	if player == null:
		_fail("%s 缺 Player（相机与重生都拿不到人）" % path)
	elif player.get_node_or_null("DeathBurst") == null:
		# D42：player.gd 用 @onready $DeathBurst 拿那一拍的液滴节点，少了它要到人真的
		# 撞上尖刺才露馅 —— 正是守门该提前响的地方。
		_fail("%s 的 Player 缺 DeathBurst（死亡那一拍会踩空）" % path)
	if level.get_node_or_null("PlayerSpawn") == null:
		_fail("%s 缺 PlayerSpawn（玩家会停在编辑期位置）" % path)
	# 祭坛是一次性的，放两个就有一个永远不响应（手册 §11 已知坑）。
	var altars := _count_by_script(level, ALTAR_SCRIPT)
	if altars > 1:
		_fail("%s 有 %d 个 AbilityAltar（一个关卡只放一个）" % [path, altars])
	# 终点区：必须是 SensorZone，且带心对准贴地玩家的碰撞盒中心（带心契约）。
	# 未进树时 _rebuild() 没跑，所以验导出项而不是 shape.position。
	var goal = level.get_node_or_null("Triggers/GoalZone")
	if goal == null:
		return
	var goal_script: Script = goal.get_script()
	if goal_script == null or goal_script.resource_path != SENSOR_SCRIPT:
		_fail("%s 的 GoalZone 不是 SensorZone" % path)
		return
	if goal.get("band_centre_y") != BAND_CENTRE:
		_fail("%s GoalZone band_centre_y=%s（贴地带应为 %s）"
			% [path, str(goal.get("band_centre_y")), str(BAND_CENTRE)])


func _count_by_script(node: Node, target: String) -> int:
	var total := 0
	var script: Script = node.get_script()
	if script != null and script.resource_path == target:
		total += 1
	for child in node.get_children():
		total += _count_by_script(child, target)
	return total


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
		var target := _fold_rel_path(path, by_path[path].get("trigger"))
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


## 把节点看到的相对路径（../ButtonPlate、../Card）折成关卡根视角的绝对路径。
## 门与刷卡门的接线检查共用这一条。
func _fold_rel_path(node_path: String, rel: NodePath) -> String:
	if rel.is_empty():
		return ""
	var steps := PackedStringArray()
	for i in rel.get_name_count():
		steps.append(String(rel.get_name(i)))
	var base := PackedStringArray(node_path.split("/"))
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
