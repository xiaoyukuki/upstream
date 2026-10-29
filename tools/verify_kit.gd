extends SceneTree

const SCRIPTS := [
	"res://scenes/actors/player/player.gd",
	"res://scenes/actors/player/time_anchor.gd",
	"res://scenes/objects/platform/platform.gd",
	"res://scenes/objects/door/door.gd",
	"res://scenes/objects/button_plate/button_plate.gd",
	"res://scenes/objects/pendulum/pendulum.gd",
	"res://scenes/objects/moving_block/moving_block.gd",
	"res://scenes/objects/piston_block/piston_block.gd",
	"res://scenes/objects/ability_altar/ability_altar.gd",
	"res://scenes/objects/sensor_zone/sensor_zone.gd",
	"res://scenes/objects/spikes/spikes.gd",
	"res://scenes/objects/electric_bar/electric_bar.gd",
	"res://scenes/objects/key_pickup/key_pickup.gd",
	"res://scenes/objects/key_door/key_door.gd",
	"res://scenes/objects/checkpoint/checkpoint.gd",
	"res://scenes/objects/collectible/collectible.gd",
	"res://scenes/objects/afterimage_emitter/afterimage_emitter.gd",
	"res://scenes/objects/fall_zone/fall_zone.gd",
	"res://scenes/objects/clock/clock.gd",
	"res://scenes/objects/ecg_monitor/ecg_monitor.gd",
	"res://scenes/objects/cave_cover/cave_cover.gd",
	"res://scenes/objects/dream_bubbles/dream_bubbles.gd",
	"res://scenes/ui/dream_mask/dream_mask.gd",
	"res://components/clock_device.gd",
	"res://scenes/objects/phase_panel/phase_panel.gd",
	"res://scenes/objects/phase_shuttle/phase_shuttle.gd",
	"res://components/time_receiver.gd",
	"res://components/hazard_base.gd",
	"res://scenes/levels/level_base.gd",
	"res://scenes/levels/level_01_tutorial.gd",
	"res://scenes/levels/level_template.gd",
	"res://scenes/levels/main.gd",
]
# audio_director.gd 刻意不在：它是 autoload，进程里活着一个实例，`script.reload()` 会报
# "Cannot reload script while instances exist"（引擎 ERROR 就算红）。它编译不出来的话
# 那条 autoload 根本起不来，下面 `_verify_audio()` 那些**读启动后真实状态**的判据会当场响。
# tile_draw.gd 刻意不在：它 extends RefCounted，下面的 instance.free() 对它不成立，
# 且它没有状态可验 —— 作为 Spikes/ElectricBar/KeyDoor 的 preload 已被连带编译。

## 这些构件必须 @tool，否则检查器里改导出项不会即时重画，摆图时看到的是过时的多边形。
const TOOL_SCRIPTS := [
	"res://scenes/objects/platform/platform.gd",
	"res://scenes/objects/door/door.gd",
	"res://scenes/objects/button_plate/button_plate.gd",
	"res://scenes/objects/pendulum/pendulum.gd",
	"res://scenes/objects/moving_block/moving_block.gd",
	"res://scenes/objects/piston_block/piston_block.gd",
	"res://scenes/objects/ability_altar/ability_altar.gd",
	"res://scenes/objects/sensor_zone/sensor_zone.gd",
	"res://scenes/objects/spikes/spikes.gd",
	"res://scenes/objects/electric_bar/electric_bar.gd",
	"res://scenes/objects/key_pickup/key_pickup.gd",
	"res://scenes/objects/key_door/key_door.gd",
	"res://scenes/objects/checkpoint/checkpoint.gd",
	"res://scenes/objects/collectible/collectible.gd",
	"res://scenes/objects/afterimage_emitter/afterimage_emitter.gd",
	"res://scenes/objects/fall_zone/fall_zone.gd",
	"res://scenes/objects/clock/clock.gd",
	"res://scenes/objects/ecg_monitor/ecg_monitor.gd",
	"res://components/clock_device.gd",
	"res://scenes/objects/phase_panel/phase_panel.gd",
	"res://scenes/objects/phase_shuttle/phase_shuttle.gd",
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
	"res://scenes/objects/piston_block/piston_block.tscn",
	"res://scenes/objects/ability_altar/ability_altar.tscn",
	"res://scenes/objects/sensor_zone/sensor_zone.tscn",
	"res://scenes/objects/spikes/spikes.tscn",
	"res://scenes/objects/electric_bar/electric_bar.tscn",
	"res://scenes/objects/key_pickup/key_pickup.tscn",
	"res://scenes/objects/key_door/key_door.tscn",
	"res://scenes/objects/checkpoint/checkpoint.tscn",
	"res://scenes/objects/collectible/collectible.tscn",
	"res://scenes/objects/afterimage_emitter/afterimage_emitter.tscn",
	"res://scenes/objects/fall_zone/fall_zone.tscn",
	"res://scenes/objects/clock/clock.tscn",
	"res://scenes/objects/cave_cover/cave_cover.tscn",
	"res://scenes/objects/dream_bubbles/dream_bubbles.tscn",
	"res://scenes/ui/dream_mask/dream_mask.tscn",
	"res://scenes/objects/phase_panel/phase_panel.tscn",
	"res://scenes/objects/phase_shuttle/phase_shuttle.tscn",
	"res://scenes/levels/rooms/initial_room.tscn",
	"res://scenes/levels/rooms/teaching_corridor.tscn",
	"res://scenes/levels/main.tscn",
]

## 按名字读入口的地方 = 改一个名字就静默失效的地方。LevelBase 问常驻根要这一拍时走的是
## `root.call(&"take_intro")`（D57），那道 `_world_root()` 的闸只认 get_run_state、拦不住改名，
## 所以这里按同一份名单逐个点名：少一个就是 FAIL，而不是"开局动画再也没有、也没人说什么"。
const METHODS := {
	"res://scenes/levels/main.gd": ["get_run_state", "take_intro", "reload_level", "restart_level"],
	## 梦泡那一拍的三只闩（D77）：关卡根只问 Player 要这三发，少一发就是"钉不住"或"交不回"。
	## `wake_progress`（D78）：遮罩唯一的事实来源，改名就等于遮罩静默不张嘴。
	"res://scenes/actors/player/player.gd": ["begin_wake_hold", "is_wake_held", "release_wake",
		"wake_progress"],
	"res://scenes/objects/dream_bubbles/dream_bubbles.gd": ["popped_count"],
}

const EXPORTS := {
	"res://scenes/objects/door/door.gd": ["height", "width", "open_time", "trigger"],
	"res://scenes/objects/button_plate/button_plate.gd": ["width", "sensor_height", "press_depth"],
	"res://scenes/objects/pendulum/pendulum.gd": ["amplitude_degrees", "period", "phase", "rod_length"],
	"res://scenes/objects/moving_block/moving_block.gd": ["travel_offset", "block_size", "travel_speed", "block_color"],
	"res://scenes/objects/piston_block/piston_block.gd": ["travel_offset", "block_size",
		"extend_speed", "retract_speed", "rest_out", "triggers"],
	"res://scenes/objects/ability_altar/ability_altar.gd": ["width", "altar_height", "sensor_height", "grant_time"],
	"res://scenes/objects/sensor_zone/sensor_zone.gd": ["width", "height", "band_centre_y", "visible_in_game"],
	"res://scenes/objects/spikes/spikes.gd": ["length"],
	"res://scenes/objects/electric_bar/electric_bar.gd": ["length", "period", "duty", "phase", "blocks_when_live"],
	"res://scenes/objects/key_door/key_door.gd": ["height", "width", "sensor_reach", "sensor_height", "key", "swipe_time"],
	"res://scenes/objects/collectible/collectible.gd": ["skin", "spin_period"],
	"res://scenes/objects/afterimage_emitter/afterimage_emitter.gd": ["fall_speed", "emit_interval", "step_width", "step_length", "reach", "max_steps"],
	"res://scenes/objects/fall_zone/fall_zone.gd": ["width", "depth", "visible_in_game"],
	"res://scenes/objects/clock/clock.gd": ["period"],
	"res://scenes/objects/ecg_monitor/ecg_monitor.gd": ["beat_period"],
	"res://scenes/objects/cave_cover/cave_cover.gd": ["reveal_near", "reveal_far"],
	"res://scenes/objects/dream_bubbles/dream_bubbles.gd": ["pop_frame_seconds", "follow_player"],
	"res://components/clock_device.gd": ["period", "duty", "phase"],
	"res://scenes/objects/phase_panel/phase_panel.gd": ["panel_size"],
	"res://scenes/objects/phase_shuttle/phase_shuttle.gd": ["step_size", "offset"],
	"res://scenes/levels/level_base.gd": ["start_with_ability", "start_with_anchor", "camera_limits",
		"death_time", "dream_intro"],
	"res://scenes/levels/main.gd": ["level_scene"],
}

const NODE_PATHS := {
	"res://scenes/levels/main.tscn": [
		"DreamMask", "TimeFreezeFilter", "DebugOverlay", "LevelContainer",
	],
	"res://scenes/levels/level_01_tutorial.tscn": [
		"Objects/ButtonPlate", "Objects/Door", "Objects/PendulumA", "Objects/PendulumB",
		"Objects/MovingBlock", "Objects/AbilityAltar", "Triggers/GoalZone", "Triggers/BypassZone",
		"Player", "PlayerSpawn",
	],
	"res://scenes/levels/level_template.tscn": [
		"Terrain/WallFill", "Terrain/Decor", "Terrain/Tiles",
		"Objects/Door/Door", "Objects/Door/ButtonPlate", "Objects/PistonBlock/PistonBlock",
		"Objects/Checkpoint/Checkpoint", "Objects/KeyDoor/KeyDoor", "Objects/Spikes/Spikes",
		"Objects/Collectible/Collectible", "Objects/AfterimageEmitter/AfterimageEmitter",
		"Objects/AbilityAltar", "Triggers/GoalZone", "Triggers/FallZone",
		"Player", "PlayerSpawn",
	],
}

## 只按路径认门：静态写 `as Door` / `is LevelBase` 会让本脚本在编译期依赖那些脚本，
## 而它们引用 autoload TimeManager —— --script 模式下没有 autoload，verify_kit 自己就编译不过。
const DOOR_SCRIPT := "res://scenes/objects/door/door.gd"
const BUTTON_SCRIPT := "res://scenes/objects/button_plate/button_plate.gd"
const ALTAR_SCRIPT := "res://scenes/objects/ability_altar/ability_altar.gd"
const AFTERIMAGE_SCRIPT := "res://scenes/objects/afterimage_emitter/afterimage_emitter.gd"
const PISTON_SCRIPT := "res://scenes/objects/piston_block/piston_block.gd"
const SENSOR_SCRIPT := "res://scenes/objects/sensor_zone/sensor_zone.gd"
const KEYDOOR_SCRIPT := "res://scenes/objects/key_door/key_door.gd"
const KEY_SCRIPT := "res://scenes/objects/key_pickup/key_pickup.gd"
const FALLZONE_SCRIPT := "res://scenes/objects/fall_zone/fall_zone.gd"
const COLLECTIBLE_SCRIPT := "res://scenes/objects/collectible/collectible.gd"
const CLOCK_SCRIPT := "res://scenes/objects/clock/clock.gd"
const ECG_SCRIPT := "res://scenes/objects/ecg_monitor/ecg_monitor.gd"
const ECG_SCENE := "res://scenes/objects/ecg_monitor/ecg_monitor.tscn"
const CAVE_COVER_SCRIPT := "res://scenes/objects/cave_cover/cave_cover.gd"
const CAVE_COVER_SCENE := "res://scenes/objects/cave_cover/cave_cover.tscn"
## 梦泡（D77）：皮住在清单 + 磁盘 PNG 里，所以三方（清单 / InputMap / PNG）必须逐条对得上。
const DREAM_SCRIPT := "res://scenes/objects/dream_bubbles/dream_bubbles.gd"
const DREAM_SCENE := "res://scenes/objects/dream_bubbles/dream_bubbles.tscn"
const DREAM_MANIFEST := "res://assets/props/dream_bubble.json"
## 开场遮罩（D78）：与梦泡同一族"皮住在清单 + 磁盘 PNG"的构件，三方对得上是它的命根子。
const MASK_SCRIPT := "res://scenes/ui/dream_mask/dream_mask.gd"
const MASK_SCENE := "res://scenes/ui/dream_mask/dream_mask.tscn"
const MASK_MANIFEST := "res://assets/props/dream_mask.json"
const MASK_PNG := "res://assets/props/dream_mask.png"
const FILTER_SCRIPT := "res://scenes/ui/time_freeze_filter.tscn"
## 盖子逐格核的是"实心格"，那份坐标来自 tiles.json；合成用的空层也挂这一份图集。
const LAB_TILESET := "res://assets/tiles/lab_tileset.tres"
const TILES_MANIFEST := "res://assets/tiles/tiles.json"
const TIME_ANCHOR_SCRIPT := "res://scenes/actors/player/time_anchor.gd"
const MOVING_BLOCK_SCENE := "res://scenes/objects/moving_block/moving_block.tscn"
const CLOCK_DEVICE_SCRIPT := "res://components/clock_device.gd"
const PHASE_PANEL_SCRIPT := "res://scenes/objects/phase_panel/phase_panel.gd"
const PHASE_PANEL_SCENE := "res://scenes/objects/phase_panel/phase_panel.tscn"
const PHASE_SHUTTLE_SCRIPT := "res://scenes/objects/phase_shuttle/phase_shuttle.gd"
const PHASE_SHUTTLE_SCENE := "res://scenes/objects/phase_shuttle/phase_shuttle.tscn"
## 锚点物不许是危险物（D66②）。HazardBase 是这一章"会杀人"的形状，按继承链认它，
## 不按具体构件点名 —— 将来新加的危险物也逃不过。
const HAZARD_BASE_SCRIPT := "res://components/hazard_base.gd"
const ANCHOR_GROUP: StringName = &"anchorable"
## 关卡脚本的共同祖先，用来「这是不是一个真关卡」而不是靠文件名猜。
const LEVEL_BASE_SCRIPT := "res://scenes/levels/level_base.gd"
## 冻结时压掉 BGM 高频的那条低通（D79）。它是 autoload，所以下面那一节的判据
## 有一半读的是**启动之后**的真实状态，而不是 .tscn 里存了什么。
const AUDIO_DIRECTOR_SCRIPT := "res://autoloads/audio_director.gd"

const BAND_CENTRE := -15.0

var _failures: int = 0
var _doors_checked: int = 0
## 活塞是可选构件，所以这里只记账不设门槛：扫到几块报几块，一块没有也不算配置错误。
var _pistons_checked: int = 0
## 坠落带同理只报计数（D52）：哪一关需要、要铺多宽都是摆图的决定，守门钉死它只会
## 把「这关根本没有坑」也判成 FAIL。
var _fallzones_checked: int = 0
## 锚点族（D68）：扫到几块挂了 anchorable 的实体。扫描空转比漏检更糟，所以设了下限。
var _anchorables_checked: int = 0
## 假墙盖（D76）：现在还没有关卡摆过，所以只记账不设门槛。
var _covers_checked: int = 0
## 梦泡（D77）：清单里核对过几只就报几只。四只是定死的，所以这里设下限当"扫描没空转"的闸。
var _dreams_checked: int = 0
## 遮罩这一拍核了几档（清单↔皮算式那几处交叉）：空转守卫，同 `_dreams_checked` 的口径。
var _masks_checked: int = 0


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
		if METHODS.has(path):
			for method in METHODS[path]:
				if not instance.has_method(method):
					_fail("missing method %s on %s" % [method, path])
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
		_check_group_containers(level, path)
		_doors_checked += _check_trigger_wiring(level, path, DOOR_SCRIPT, "门", "trigger")
		_pistons_checked += _check_trigger_wiring(level, path, PISTON_SCRIPT, "活塞", "triggers")
		_fallzones_checked += _count_by_script(level, FALLZONE_SCRIPT)
		_check_level_hazards(level, path)
		_check_key_wiring(level, path)
		_check_cave_covers(level, path)
		level.free()


## 第二阶段必须等到第一帧：--script 模式下 _initialize() 跑在 root 就绪之前，
## 那时 add_child 的子节点 _ready() 会被推迟，读到的全是 .tscn 里的存量值。
func _process(_delta: float) -> bool:
	_verify_ready_geometry()
	_verify_props()
	_verify_collectible()
	_verify_afterimage()
	_verify_piston()
	_verify_fall_zone()
	_verify_clock()
	_verify_ecg_monitor()
	_verify_cave_cover()
	_verify_dream_bubbles()
	_verify_dream_mask()
	_verify_clock_devices()
	_verify_altar_save()
	_verify_time_anchor()
	_verify_audio()
	# 检查空转比检查失败更糟：门数一旦对不上，说明上面的递归没走到门。
	if _doors_checked < 2:
		_fail("只查到 %d 扇门配了接线（期望至少 2：引导关 + 模板）" % _doors_checked)
	# 同一条口径管梦泡：清单要是被清空、或那只泡从没被扫到，上面那一整段会全绿着空转。
	if _dreams_checked < 4:
		_fail("只核对到 %d 只梦泡（应为 4：A / S / space / D）—— 清单扫描空转了（D77）" % _dreams_checked)
	# 同一条口径管遮罩：清单↔皮那几处交叉一旦没走到（清单读不到、皮没 import），
	# 整段会全绿着空转 —— 那是最坏的一种绿。
	if _masks_checked < 5:
		_fail("遮罩只核了 %d 档（皮尺寸 / 剖面 / 软边 / 弧心 / 层，至少 5）—— D78 那段扫描空转了" % _masks_checked)
	print("VERIFY DONE doors=%d pistons=%d fallzones=%d anchorables=%d covers=%d dreams=%d masks=%d failures=%d"
		% [_doors_checked, _pistons_checked, _fallzones_checked, _anchorables_checked,
			_covers_checked, _dreams_checked, _masks_checked, _failures])
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
	# 带子尺寸钉的是**派生式**而不是某个字面量：`width` 是手感旋钮（2026-09-29 他从 64 拧到 48，
	# 旧写法当场红一条），抄第二份数等于把默认值当契约 —— 同 D48 的 `KILL_INSET`、D53 的 `denied_time`。
	# 这一钉真正要挡的是"改了 `width`/`sensor_height` 而带子没跟着重算"。
	if button_shape.shape.size != Vector2(button.width, button.sensor_height):
		_fail("ButtonPlate band size=%s，不是 width×sensor_height=%s（派生几何没跟上）"
			% [str(button_shape.shape.size), str(Vector2(button.width, button.sensor_height))])
	# D25：立绘改由 _draw() 平铺零件，占位 Polygon2D 留着就会画在立绘上面。
	for reskinned in [door_a, button]:
		if reskinned.get_node_or_null("Visual") != null:
			_fail("%s 还带着占位 Visual 节点（D25 已改 _draw 平铺零件）" % reskinned.name)

	var altar = _enter("res://scenes/objects/ability_altar/ability_altar.tscn")
	var altar_shape = altar.get_node("CollisionShape2D")
	if altar_shape.position != Vector2(0, BAND_CENTRE):
		_fail("AbilityAltar band centre=%s" % str(altar_shape.position))
	# D44：台座改由 _draw() 平铺零件画，占位 Polygon2D 留着就会画在立绘上面（同 D25 那条）。
	if altar.get_node_or_null("Visual") != null:
		_fail("AbilityAltar 还带着占位 Visual 节点（D44 已改 _draw 平铺零件）")

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
	# D55：卡坐在**与彩蛋同一张**公共底座上（用户自己提的解法，替代「像鸭子那样转」）。
	# 这条只钉三件事，全属"改了不响"那类：① 那两张零件常量确实指向落盘的那两张 —— 复制一份
	# 副本的话换风格只会有一半跟着换；② 判定带**不跟着长高**（上面那条 32x24 @ (0,-15) 就是它，
	# 座子把外接框从 10 抬到 15 也不许顺手改成贴外接框，那是 D54 的规矩不是这里的）；
	# ③ 这张卡**不吃时钟**：没有 TimeReceiver 子节点、一个 @export 都没有 —— 提示压在形状上，
	# 形状本来就不需要走时间，加了旋钮就说明有人把它改回了转。
	var card_cs: Dictionary = (load(KEY_SCRIPT) as GDScript).get_script_constant_map()
	for pair in [["TEX_PERCH_IDLE", "perch_idle"], ["TEX_PERCH_TAKEN", "perch_taken"]]:
		var tex: Texture2D = card_cs.get(pair[0])
		if tex == null or tex.resource_path != "res://assets/props/%s.png" % pair[1]:
			_fail("KeyPickup 的 %s 不指向落盘的 %s.png（D55 是复用零件，不是新画一张）"
				% [pair[0], pair[1]])
	if card.get_node_or_null("TimeReceiver") != null:
		_fail("KeyPickup 挂了 TimeReceiver：那张卡不该有属于自己的世界时间（D55 定的是形状语言，不转）")
	if FileAccess.get_file_as_string(KEY_SCRIPT).contains("@export"):
		_fail("KeyPickup 出现了 @export：D55 明确不给它加旋钮（要转就回到 D54 那条通道重新裁定）")

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


## D47 残影踏板。静态这一遍钉四件，全都属于"改了不响、要到试玩才露馅"那类：
## ① 实体切换只能走物理通道 —— 脚本里根本不该出现 `_process`（这台机器上 process 是
##    物理的 2.4 倍，照它切换等于碰撞层随帧率抖）；② 碰撞盒跟着导出项走；
## ③ 每格独占一份形状资源（D27 第 7 条那个"一扇门拽小另一扇"的坑）；
## ④ 碰撞体 == 画出来的那几格：池子按 `max_steps` 建、链按 `reach / 节距` 画，默认就是
##    8 vs 5，多余那三格两态都必须不在层上，否则冻住时是"看不见却能踩"。
## 位置纯函数与冻结不动身由 kit_selftest 第 12 组在真帧下验。
func _verify_afterimage() -> void:
	var path := AFTERIMAGE_SCRIPT
	var src := FileAccess.get_file_as_string(path)
	if src.contains("func _process("):
		_fail("AfterimageEmitter 里出现了 _process：实体切换只能走物理通道（D47）")
	# 旧旋钮名的迁移哨（D47 订正）：引擎会**静默丢掉** .tscn 里认不出的属性 —— 不报错、
	# 不警告，那台机器直接退回默认 32×32。旧场景里那行 `step_size = 40.0` 只能靠文本找回来。
	for level_path in _discover_level_scenes():
		var text := FileAccess.get_file_as_string(level_path)
		for chunk in text.split("[node "):
			if not chunk.split("\n")[0].begins_with("name=\"AfterimageEmitter\""):
				continue
			if chunk.contains("step_size ="):
				_fail("%s 的 AfterimageEmitter 还写着 step_size：这个旋钮已拆成 step_width / step_length，引擎把那一行静默丢掉了（这台现在悄悄退回 32×32）" % level_path)
	# 只按名字捞 autoload，不写 `TimeManager.`：静态引用会让本脚本编译期依赖 autoload，
	# 而 --script 模式下的 autoload 本来就是个"实测在、契约上不保证在"的东西。
	var tm = root.get_node_or_null("/root/TimeManager")
	if tm == null:
		_fail("拿不到 /root/TimeManager，残影踏板的冻结态那条检查没法做")
		return

	var emitter = _enter("res://scenes/objects/afterimage_emitter/afterimage_emitter.tscn")
	# 默认档只验结构，不验数值：这几个数归摆图的人随时调（D47 落档后用户已把默认从
	# 400×0.20 改成 800×0.40），照默认值断言"节距必等于 80"等于把守门绑在他的手感上。
	if emitter.active_steps() < 1 or emitter.active_steps() > emitter.max_steps:
		_fail("默认档的链上 %d 格，落在 [1, max_steps=%d] 之外"
			% [emitter.active_steps(), emitter.max_steps])
	if emitter.pitch() <= emitter.step_length:
		_fail("默认节距 %s 比格长 %s 还小：相邻两格互相穿模，链会糊成一坨"
			% [str(emitter.pitch()), str(emitter.step_length)])
	# 下面所有数值断言都跑在这一档显式参数上（= D47 表里那一档），与脚本默认值脱钩。
	emitter.fall_speed = 400.0
	emitter.emit_interval = 0.20
	emitter.step_width = 32.0
	emitter.step_length = 32.0
	emitter.reach = 320.0
	emitter.max_steps = 8
	if not is_equal_approx(emitter.pitch(), 80.0):
		_fail("参照节距 %s（应 80 = 400×0.20，正好落在 16 px 网格上）" % str(emitter.pitch()))
	if emitter.active_steps() != 5:
		_fail("参照档链上 %d 格（reach 320 / 节距 80 + 1 = 5）" % emitter.active_steps())
	var bodies := _pool_bodies(emitter)
	if bodies.size() != emitter.max_steps:
		_fail("池子里 %d 格，max_steps=%d 对不上" % [bodies.size(), emitter.max_steps])
	var shapes: Array = []
	for body in bodies:
		if body.collision_mask != 0:
			_fail("格子 %s mask=%d（挡路块只被玩家读，不该去探任何东西）"
				% [str(body.name), body.collision_mask])
		var rect := _body_rect(body)
		if rect == null:
			_fail("格子 %s 没有 RectangleShape2D 子节点" % str(body.name))
			continue
		if rect.size != Vector2(32.0, 32.0):
			_fail("格子碰撞盒 %s（应 32x32 = 2 个瓦片格）" % str(rect.size))
		for other in shapes:
			if rect == other:
				_fail("两格共用同一份形状资源：改一格会把另一格也拽小（D27 第 7 条）")
		shapes.append(rect)

	# 流动一拍：整条链都得不在层上（穿透），且位置 == 公式值。
	emitter._physics_process(1.0 / 60.0)
	var clock: float = emitter.world_clock()
	if clock <= 0.0:
		_fail("世界在流、喂了一拍物理，世界时钟还在 %s" % str(clock))
	for i in bodies.size():
		if bodies[i].collision_layer != 0:
			_fail("流动中第 %d 格还在层 %d（穿透契约破了）" % [i, bodies[i].collision_layer])
	var n: int = emitter.active_steps()
	for k in n:
		if not is_equal_approx(bodies[k].position.y, emitter.step_top_y(k) + emitter.step_length * 0.5):
			_fail("第 %d 格在 y=%s，公式要 %s（位置必须是时钟的纯函数）"
				% [k, str(bodies[k].position.y), str(emitter.step_top_y(k) + emitter.step_length * 0.5)])
		if not is_equal_approx(emitter.step_top_y(k + 1) - emitter.step_top_y(k), emitter.pitch()):
			_fail("相邻两格不等距（节距 %s）" % str(emitter.pitch()))
	if emitter.step_top_y(0) < 0.0 or emitter.step_top_y(0) >= emitter.pitch():
		_fail("最新那格跑出出生窗口：step_top_y(0)=%s 不在 [0, 节距) 内" % str(emitter.step_top_y(0)))

	# 钉住这一拍：链立刻全上 time_solid，多余格例外，且一格都不许动。
	tm.set_frozen_override(true)
	var before_y: Array = []
	for body in bodies:
		before_y.append(body.position.y)
	emitter._physics_process(1.0 / 60.0)
	if not is_equal_approx(emitter.world_clock(), clock):
		_fail("冻结那一拍时钟还在走：%s → %s" % [str(clock), str(emitter.world_clock())])
	for i in bodies.size():
		var want: int = 4 if i < n else 0
		if bodies[i].collision_layer != want:
			_fail("冻结中第 %d 格 layer=%d（链上应 4= time_solid，链外多余格应 0）"
				% [i, bodies[i].collision_layer])
		if not is_equal_approx(bodies[i].position.y, before_y[i]):
			_fail("冻结中第 %d 格还在动（有形时不动，这条是承载安全的柱子）" % i)

	tm.reset_state()
	emitter._physics_process(1.0 / 60.0)
	for i in bodies.size():
		if bodies[i].collision_layer != 0:
			_fail("解冻后第 %d 格还压在层 %d" % [i, bodies[i].collision_layer])

	# 改导出项的 setter 链路：盒子和格数都得跟着重算，摆图时才能一眼看清占多大。
	# 两轴分两次只改一维：改长度不许把宽度也拽走（D47 订正，这一格不再是正方形）。
	emitter.step_length = 48.0
	for rect in _collect_rects(emitter):
		if rect.size != Vector2(32.0, 48.0):
			_fail("只改 step_length 后碰撞盒是 %s（应 32x48：长度与宽度各归各的）" % str(rect.size))
	emitter.step_width = 24.0
	for rect in _collect_rects(emitter):
		if rect.size != Vector2(24.0, 48.0):
			_fail("改 step_width=24 后碰撞盒是 %s（应 24x48：改宽度也不许带走长度）" % str(rect.size))
	# 宽长不等时再核一次对中：拿宽度当高度算在这档之前看不出来（32×32 时两种写法同值），
	# 而它会让踩面错开半个差、判死带跟着偏移。
	for k in emitter.active_steps():
		if not is_equal_approx(bodies[k].position.y, emitter.step_top_y(k) + emitter.step_length * 0.5):
			_fail("宽长不等时第 %d 格没按格长对中：y=%s，要 %s"
				% [k, str(bodies[k].position.y), str(emitter.step_top_y(k) + emitter.step_length * 0.5)])
	emitter.reach = 480.0
	if emitter.active_steps() != 7:
		_fail("reach 480 / 节距 80 应要 7 格，实际 %d" % emitter.active_steps())

	_verify_afterimage_kill(emitter, bodies)
	root.remove_child(emitter)
	emitter.free()


## D48 的判死契约，全部是结构与几何，跑在真物理里的那几条归 kit_selftest 第 12 组。
func _verify_afterimage_kill(emitter, bodies: Array) -> void:
	if not emitter.has_signal("touched_player"):
		_fail("AfterimageEmitter 不发 touched_player：判死靠 LevelBase 按信号名自动接线，改名即静默失效")
		return
	# 它不是 Area2D，所以关卡侧那条"判死区一律 layer 0 / mask 2"的扫描跳得过它。
	# 真有人往它身上加了探测区，这条就会响——加完之后它必须回去受层契约管。
	if _count_areas(emitter) > 0:
		_fail("AfterimageEmitter 子树里出现了 Area2D：它得回去受危险物层契约管（改 _check_level_hazards）")
	var inset: float = (load(AFTERIMAGE_SCRIPT) as GDScript).get_script_constant_map()["KILL_INSET"]
	var cell := emitter.step_rect(0) as Rect2
	if not is_equal_approx(cell.size.x, emitter.step_width) or not is_equal_approx(cell.size.y, emitter.step_length):
		_fail("判死方块 %s 与格 %s 不等：判死的不是画出来、撞到的那一格"
			% [str(cell.size), str(Vector2(emitter.step_width, emitter.step_length))])
	if not is_equal_approx(cell.get_center().x, (bodies[0] as Node2D).global_position.x) \
			or not is_equal_approx(cell.get_center().y, (bodies[0] as Node2D).global_position.y):
		_fail("判死方块没对准第 0 格的碰撞体：索引或偏移接错了")
	var band := cell.grow(-inset)
	if band.size.x <= 0.0 or band.size.y <= 0.0:
		_fail("内缩 %s px 之后判死带塌了（格子 %s）：这么小的格根本没法分辨踩住与陷进去"
			% [str(inset), str(cell.size)])
	# 踩面 = 格子顶边。它必须落在带子外面，否则"站上去"就等于"陷进去"，构件直接没法用。
	if band.position.y <= cell.position.y:
		_fail("判死带上沿 %s 没压在格子顶边 %s 之下：站在踩面上会被判死"
			% [str(band.position.y), str(cell.position.y)])


## D49 活塞踏板。这一遍钉的全是"改了不响、要到试玩才露馅"那五件，D63 起再加一组反向档检查
## （源码形状三条：电平→位只许一处映射、两档速度必须绑 `is_out`、不许出现 `if _level`；
## 外加一次实测：反向块**进树当帧就落在满行程**，锚点仍是摆下去那一点）：
## ① 脚本里根本不该出现 `_process`（这台机器上 process 是物理的 2.4 倍，照它走位等于伸出量
##    随帧率抖，而且冻结那道闸根本拦不住 process）；② 碰撞层契约 —— 尤其是 mask 必须是 0，
##    带上 terrain(1) 就正好撞上"收回态整块埋在墙里 = 起点重叠，`move_and_collide` 把整段位移
##    原样退回"那条死路，活塞一辈子钻不出洞口；③ 原点=前缘这条摆放约定（`_resolve` 的让位
##    算式少一项全靠它，横竖两轴各钉一次）；④ 改 travel_offset / block_size 后派生几何整组重算，
##    斜行程只认主轴；⑤ 伸出量与跨度同源 —— `progress()` 读不到 1.0 就是两端算得不是一条式子。
## 真物理下的行为（按住伸出、冻结停住、收回抽干落脚点、挤开与"背后有墙就推不动"）归
## kit_selftest 第 13 组。
func _verify_piston() -> void:
	var path := PISTON_SCRIPT
	var src := FileAccess.get_file_as_string(path)
	if src.contains("func _process("):
		_fail("PistonBlock 里出现了 _process：伸出量只能走物理通道（D49）")
	var piston = _enter("res://scenes/objects/piston_block/piston_block.tscn")
	var twin = _enter("res://scenes/objects/piston_block/piston_block.tscn")
	var col: CollisionShape2D = piston.get_node("CollisionShape2D")
	var col_twin: CollisionShape2D = twin.get_node("CollisionShape2D")
	if piston.collision_layer != 4 or piston.collision_mask != 0:
		_fail("PistonBlock layer=%d mask=%d（应 4/0：只被玩家读，绝不去探地形）"
			% [piston.collision_layer, piston.collision_mask])
	# 默认档 travel_offset=(64,0) / block_size=64² → 轴 +x、半长 32 → 身子整块在洞口内侧。
	if col.shape.size != Vector2(64.0, 64.0) or col.position != Vector2(-32.0, 0.0):
		_fail("收回态碰撞盒 %s @ %s（默认档应 64x64 @ (-32,0)）"
			% [str(col.shape.size), str(col.position)])
	var at := Vector2(100.0, 50.0)
	var box: Rect2 = piston.rect_at(at)
	if not is_equal_approx(box.end.x, at.x):
		_fail("前缘不在节点原点上：右缘 %s vs 原点 %s（洞口约定是让位算式的地基）"
			% [str(box.end.x), str(at.x)])
	# 换成竖直行程：轴翻到 -y、半长仍按 block_size 那一维算，所以身子挪到原点下方。
	piston.travel_offset = Vector2(0.0, -96.0)
	if col.position != Vector2(0.0, 32.0):
		_fail("改竖直行程后碰撞盒中心 %s（应 (0,32)：轴与半长没跟着重算）" % str(col.position))
	var up: Rect2 = piston.rect_at(at)
	if not is_equal_approx(up.position.y, at.y):
		_fail("竖直行程的前缘不在原点上：上缘 %s vs 原点 %s" % [str(up.position.y), str(at.y)])
	# 改边长：半长跟着变，碰撞盒中心必须跟着挪（原点约定的另一半住在这里）。
	piston.block_size = Vector2(32.0, 32.0)
	if col.position != Vector2(0.0, 16.0) or col.shape.size != Vector2(32.0, 32.0):
		_fail("改 block_size 后没整组重算：%s @ %s（应 32x32 @ (0,16)）"
			% [str(col.shape.size), str(col.position)])
	# 同一场景里两块默认共用 .tscn 那份 sub_resource —— 谁都不改它时无害，所以判据写在"改之后"：
	# _rebuild 一旦改成就地改尺寸，另一块会被一起拽小（门踩过这个坑，见 D21）。
	if col_twin.shape.size != Vector2(64.0, 64.0):
		_fail("改一块的 block_size 波及另一块：%s（应还是 64x64，两块共用了同一份形状资源）"
			% str(col_twin.shape.size))
	# 斜行程只认主轴：竖直那 30 px 被忽略，前缘仍落在原点那一侧。
	piston.travel_offset = Vector2(48.0, 30.0)
	if col.position != Vector2(-16.0, 0.0):
		_fail("斜 travel_offset 没夹到主轴：碰撞盒中心 %s（应 (-16,0)）" % str(col.position))
	# 满行程端点必须真读得出 1.0：progress() 是「位置÷跨度」，读不到就是两端不是一条式子。
	piston.block_size = Vector2(64.0, 64.0)
	piston.travel_offset = Vector2(0.0, -64.0)
	piston.global_position = piston.get("_anchor") + Vector2(0.0, -64.0)
	if not is_equal_approx(piston.progress(), 1.0):
		_fail("满行程处 progress()=%s（应 1.0）" % str(piston.progress()))
	# —— D63 反向档。这里钉的是"形状 + 进树那一拍"，行为那半边（踩下才收 / 松开慢慢回 /
	# 反向档下 OR 仍成立）归 kit_selftest 第 13 组 f 档，在无头物理里跑帧才验得出来。
	if src.count("is_out = _level != rest_out") != 1:
		_fail("电平→位的映射出现 %d 次（应恰好 1：住在 _refresh_out 那一行；在 set_out 或 "
			+ "_physics_process 里再补一次符号就有两份真值）"
			% src.count("is_out = _level != rest_out"))
	if not src.contains("var speed: float = extend_speed if is_out else retract_speed"):
		_fail("两档速度不再按 is_out（在哪一头）选：D63② 那条「绑几何不绑输入」被改源了")
	if src.contains("if _level"):
		_fail("出现了 `if _level`：电平被拿去选速度或决定让位 —— 那两处读的必须是 is_out（D63）")
	var flipped = load("res://scenes/objects/piston_block/piston_block.tscn").instantiate()
	flipped.position = Vector2(300.0, 60.0)
	flipped.rest_out = true
	root.add_child(flipped)	# _ready 在这一刻跑：常态那一头必须**当帧瞬落**，不是从洞里爬出去
	if not is_equal_approx(flipped.progress(), 1.0):
		_fail("反向块进树后 progress()=%s（应 1.0：D63③ 瞬落）" % str(flipped.progress()))
	if not flipped.is_out or flipped._level:
		_fail("反向块空接线时 is_out=%s / _level=%s（应 真 / 假：没人踩着就停在满行程，"
			+ "整列留空自然退化成一座静态桥）" % [str(flipped.is_out), str(flipped._level)])
	if flipped.global_position != Vector2(364.0, 60.0):
		_fail("瞬落落点 %s（应 (364,60) = 锚点 + 单位 × 跨度：摆下去那一点仍然是收回态的前缘，"
			+ "反向档不许挪原点契约）" % str(flipped.global_position))
	root.remove_child(flipped)
	flipped.free()
	root.remove_child(piston)
	root.remove_child(twin)
	piston.free()
	twin.free()


## D52 坠落带。钉的三件全是「改了不响、要到试玩才露馅」：① **原点=顶边中心**这条约定，
## 家族里只有它反过来（别的构件都是底边中心），摆歪半格就是"人还能继续掉"或者
## "正常落地被误判死"；② 层契约与 `touched_player` —— 上了 sensor 层或改成可被探测，
## 玩家的头顶净空查询会把这条带子读成实体，而少发那个信号则整关自动接线收不到它，
## 坠落即死静默不生效；③ 改 width/depth 后盒子跟着重算，否则编辑期画的带子和真判死的
## 带子是两截。掉进带子后真的回存档点那条归 kit_selftest 第 15 组在真物理里验。
func _verify_fall_zone() -> void:
	var zone = _enter("res://scenes/objects/fall_zone/fall_zone.tscn")
	_check_area_layers(zone, "FallZone", 0)
	if not zone.has_signal("touched_player"):
		_fail("FallZone 不发 touched_player：LevelBase 按信号名接线收不到它，坠落即死整条不生效")
	var col: CollisionShape2D = zone.get_node("CollisionShape2D")
	var want := Vector2(zone.width, zone.depth)
	if col.shape.size != want:
		_fail("FallZone 默认盒 %s（应 %s = width x depth）" % [str(col.shape.size), str(want)])
	if col.position != Vector2(0.0, zone.depth * 0.5):
		_fail("FallZone 盒心 %s（应 (0,%s)：原点不再是顶边中心，带子整体偏了半深）"
			% [str(col.position), str(zone.depth * 0.5)])
	zone.depth = 512.0
	zone.width = 64.0
	if col.shape.size != Vector2(64.0, 512.0) or col.position != Vector2(0.0, 256.0):
		_fail("改 width/depth 后没整组重算：%s @ %s（应 64x512 @ (0,256)）"
			% [str(col.shape.size), str(col.position)])
	root.remove_child(zone)
	zone.free()


## D59 世界钟（4 号样式：12 段走带）。它是全项目第一个**纯装饰构件**，所以这里钉的
## 全是"它悄悄不再是装饰、或者悄悄不再跟世界走"那两类：
## ① 时基只能是世界时钟的纯函数：脚本里不许出现 `_process`，且必须真的读
##    `TimeManager.elapsed_world_time` —— 换成自带累加，读数是同一只钟在走，
##    但死亡重载后它会自己漂（D59 裁定 D1① 的全部理由）；
## ② 契约面必须为零：不发 signal、不认 run_state。它一旦开始改机制，"装饰层零契约"
##    这条就烂在这里，而且没人会想起来删；
## ③ 三档青色色阶的次序不许倒过来（亮格 > 一段余辉 > 二段余辉），未亮的槽必须仍比表盘亮 ——
##    倒过来就是"哪一格亮"读不出来，而这只钟剩下的全部价值就是这一格；
## ④ 段数与周期对得上：一格 = period/TICKS，TICKS 必须整除进一圈。
## 把注释行剥掉再扫。**禁令与"必须读某个量"这两类判据都不该被一句注释满足或触发**：
## D75 落盘当天两头都踩过 —— 文件头里提了一次那个存档字段的原名就把自己判红（假红），
## 而反过来把 `elapsed_world_time` 只写在注释里、代码里换成墙上时钟，"必须读它"那条就全绿（假绿）。
func _code_only(src: String) -> String:
	var kept: Array[String] = []
	for line in src.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		kept.append(line)
	return "\n".join(kept)


func _verify_clock() -> void:
	var src := _code_only(FileAccess.get_file_as_string(CLOCK_SCRIPT))
	if src.contains("func _process("):
		_fail("WorldClock 里出现了 _process：亮格只能走世界时钟，照帧率走会变成冻结里它还在走（D59）")
	if not src.contains("TimeManager.elapsed_world_time"):
		_fail("WorldClock 没读 TimeManager.elapsed_world_time：它不再是世界时钟的纯函数，" +
			"死亡重载后会自己漂（D59 裁定 D1①）")
	if src.contains("\nsignal "):
		_fail("WorldClock 发出了 signal：它是纯装饰构件，一旦有契约面就得进 LevelBase 与 run_state（D59）")
	var cs: Dictionary = (load(CLOCK_SCRIPT) as GDScript).get_script_constant_map()
	var ticks: int = cs["TICKS"]
	if ticks <= 3:
		_fail("WorldClock 的 TICKS=%d：一段亮格 + 两段余辉就把整圈占满，没有「未亮」这一档，" % ticks +
			"「带在走」就读不出来了（D59）")
	var lit: Color = cs["COL_LIT"]
	var t1: Color = cs["COL_TRAIL_1"]
	var t2: Color = cs["COL_TRAIL_2"]
	var unlit: Color = cs["COL_UNLIT"]
	var screen: Color = cs["COL_SCREEN"]
	if not (_clum(lit) > _clum(t1) and _clum(t1) > _clum(t2) and _clum(t2) > _clum(screen)):
		_fail("走带那三档青色的亮度次序倒了（%s / %s / %s 对表盘 %s）：「哪一格亮」读不出来（D59）"
			% [_clum(lit), _clum(t1), _clum(t2), _clum(screen)])
	if _clum(unlit) <= _clum(screen):
		_fail("未点亮的槽不比表盘亮：整圈塌成一块黑斑，「这是一只钟」读不出来（D59）")
	var clock = _enter("res://scenes/objects/clock/clock.tscn")
	if clock.get_class() != "Node2D":
		_fail("WorldClock 的根是 %s，不是纯 Node2D：装饰件不该带任何碰撞体（D59）" % clock.get_class())
	if clock.get_child_count() != 0:
		_fail("WorldClock 带了 %d 个子节点：它只需要自己画（TimeReceiver 也不用，时基是世界时钟现读的）"
			% clock.get_child_count())
	if clock.segment_index() < 0 or clock.segment_index() >= ticks:
		_fail("segment_index() 越界：%d（应在 0..%d）" % [clock.segment_index(), ticks - 1])
	# 网格这一头是 D59 落盘当天真踩过的坑：typed array 的 resize() 填的是不透明黑，
	# 忘了 fill 就是一块 18x18 的黑盒子糊在墙上，而且描边会因为"四邻都有人"整块消失。
	# 这三条都在当场复现那两种死法，且都不需要渲染器。
	var box: int = cs["BOX"]
	var grid: Array[Color] = clock.pixel_grid(0)
	var opaque := 0
	var rim := 0
	for c in grid:
		if c.a > 0.0:
			opaque += 1
		if c == cs["COL_EDGE"]:
			rim += 1
	for corner in [0, box - 1, (box - 1) * box, box * box - 1]:
		if grid[corner].a > 0.0:
			_fail("WorldClock 网格的四角是不透明的：整块会当成一块黑盒子糊在墙上（D59）")
			break
	var fill_ratio := float(opaque) / float(box * box)
	if fill_ratio < 0.4 or fill_ratio > 0.95:
		_fail("WorldClock 的占格率 %.2f 不在 0.4~0.95（圆盘 r=8 应是 ~0.62）：形状不是批过的那只（D59）"
			% fill_ratio)
	if rim == 0:
		_fail("WorldClock 一圈描边都没有（D26 第 1 条）：非平铺件在夜光墙上会跟墙糊在一起")
	root.remove_child(clock)
	clock.free()


## D75 心电监护屏：第二件纯装饰构件，与 D59 那只钟同一族，所以静态这一遍钉的也是那五类
## "改了不响、要到试玩才露馅"的东西：
## ① 时基只有 `elapsed_world_time` 一条：出现 `TimeReceiver` / `get_physics_delta` 就是把它
##    接到了锚点上 —— 装饰被锚走会改皮不改进度，而 D59 定的是"装饰只读世界钟"；出现
##    `func _process(` 就是照帧率走，冻结里波形还在推（皮说谎，画面不报错）；
## ② 契约面必须为零：不发 signal、不认 run_state、根必须是纯 Node2D、不带子节点、不进 anchorable 族；
## ③ 读得出来的两条几何前提：波形那档青色必须比表盘亮（否则"有条线"都读不出来），
##    屏宽必须是周期列数的整数倍（42 = 6×7，否则横推到接缝处会断一笔）；
## ④ 相位是纯函数：推满一整圈回到同一张（否则那不是周期滚动是在攒状态），推一格必须换图
##    （否则它根本没在动），`beat_period <= 0` 钉在相位 0；
## ⑤ headline：把落盘图集上那块 `monitor` 裁下来，与 `pixel_grid(0)` **逐格比字节**，差一格就红。
##    矩形是从 `tiles.json` 读的、不是这里写死的 —— 图集里挪一块会红在这里，而不是比错地方还全绿。
func _verify_ecg_monitor() -> void:
	var src := _code_only(FileAccess.get_file_as_string(ECG_SCRIPT))
	if src.is_empty():
		_fail("读不到 %s" % ECG_SCRIPT)
		return
	if src.contains("func _process("):
		_fail("EcgMonitor 里出现了 _process：波形只能走世界时钟，照帧率走就是冻结里它还在推（D75）")
	if not src.contains("TimeManager.elapsed_world_time"):
		_fail("EcgMonitor 没读 TimeManager.elapsed_world_time：相位不再是世界时钟的纯函数，" +
			"死亡重载后会自己漂（D75 照 D59 裁定 D1①）")
	for banned in ["Engine.time_scale", "TimeReceiver", "get_physics_delta", "run_state", "\nsignal "]:
		if src.contains(banned):
			_fail("EcgMonitor 里出现了 %s：纯装饰构件不许有契约面，也不许换时基（D75 照 D59 裁定 D2）" % banned)
	var cs: Dictionary = (load(ECG_SCRIPT) as GDScript).get_script_constant_map()
	var bx: int = cs["BOX_X"]
	var by: int = cs["BOX_Y"]
	var sx0: int = cs["SX0"]
	var sy0: int = cs["SY0"]
	var sx1: int = cs["SX1"]
	var sy1: int = cs["SY1"]
	var pattern: Array = cs["PATTERN"]
	var cols: int = sx1 - sx0 + 1
	if cols % pattern.size() != 0:
		_fail("屏宽 %d 列不是周期 %d 列的整数倍：横推到接缝处会断一笔（D75）" % [cols, pattern.size()])
	if not (_clum(cs["COL_TRACE"]) > _clum(cs["COL_SCREEN"]) + 0.2):
		_fail("波形不比表盘亮（%s vs %s）：「屏上有条线」都读不出来（D75）"
			% [_clum(cs["COL_TRACE"]), _clum(cs["COL_SCREEN"])])
	# 逐格比字节这一条：纹理是 lossless 导入，`get_data()` 拿到的是原始 RGBA8 字节，
	# 不经过 get_pixel() 的 sRGB→线性转换 —— 比的是 PNG 里那串数，不是比两个近似的浮点色。
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(TILES_MANIFEST))
	if manifest == null:
		_fail("读不到 %s，皮同源这一条没法验" % TILES_MANIFEST)
		return
	var decor: Dictionary = manifest["decor"]
	var item: Array = decor["items"]["monitor"]
	var tex := load("res://assets/tiles/%s" % str(decor["file"])) as Texture2D
	if tex == null:
		_fail("装饰图集纹理不在: %s" % str(decor["file"]))
		return
	var img := tex.get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		_fail("装饰图集是格式号 %d，不是 RGBA8：逐格比字节那条前提没了（得先决定怎么读）"
			% img.get_format())
		return
	if item[2] != bx or item[3] != by:
		_fail("图集里 monitor 那块是 %dx%d，构件盒子是 %dx%d：瓦片与构件对不上尺寸（D75）"
			% [item[2], item[3], bx, by])
		return
	var data: PackedByteArray = img.get_data()
	var stride: int = img.get_width() * 4
	var ecg = _enter(ECG_SCENE)
	var grid: Array[Color] = ecg.pixel_grid(0)
	# 比的是 **alpha 逐格相等 + 不透明格的 RGB 逐格相等**。透明格的 RGB 故意不比：导入参数
	# `process/fix_alpha_border=true` 会把邻居色扩进全透明像素里（防黑边），所以图集上那 12 个
	# 抠角格的 RGB 是管线填的、不是画师画的 —— 比它会红得莫名其妙。
	var diffs := 0
	var first := ""
	for y in by:
		for x in bx:
			var off: int = (int(item[1]) + y) * stride + (int(item[0]) + x) * 4
			var want: Color = grid[y * bx + x]
			var want_a: int = int(round(want.a * 255.0))
			var bad := int(data[off + 3]) != want_a
			if not bad and want_a > 0:
				for k in 3:
					var exp: int = int(round((want.r if k == 0 else want.g if k == 1 else want.b) * 255.0))
					if int(data[off + k]) != exp:
						bad = true
						break
			if bad:
				diffs += 1
				if first.is_empty():
					first = "(%d,%d) 图集 %s vs 构件 %s" % [x, y,
						str(_rgba(data, off)), str(_rgba8(want))]
	if diffs > 0:
		_fail("构件的相位 0 与落盘图集上那块 monitor 有 %d 格对不上：%s —— 这条瓦片和这台构件"
			% [diffs, first] + "从此是两张皮，摆上去会看见墙上并排两种监护屏（D75）")
	# 抠角：四角必须透明，否则整块当成实心盒子糊在墙上（D59 那条环境坑：typed array 的
	# resize() 填的是不透明黑）。这一条独立于上面那条比色 —— 比色那几道前提（格式、尺寸）
	# 一旦不成立会提前 return，那时它是这块盒子唯一的闸。
	for corner in [[0, 0], [bx - 1, 0], [0, by - 1], [bx - 1, by - 1]]:
		if grid[int(corner[1]) * bx + int(corner[0])].a > 0.0:
			_fail("EcgMonitor 网格的角 %s 不透明：圆角没了，方块会当成实心盒子糊在墙上（D75）"
				% str(corner))
	if ecg.get_class() != "Node2D":
		_fail("EcgMonitor 的根是 %s，不是纯 Node2D：装饰件不该带任何碰撞体（D75 照 D59）"
			% ecg.get_class())
	if ecg.get_child_count() != 0:
		_fail("EcgMonitor 带了 %d 个子节点：它只需要自己画（时基是世界钟现读的，TimeReceiver 也不用）"
			% ecg.get_child_count())
	if ecg.is_in_group(ANCHOR_GROUP):
		_fail("EcgMonitor 在 anchorable 组里：它是装饰，被锚走只会改皮、不会改任何机制（D75）")
	if not (ecg.beat_period > 0.0):
		_fail("EcgMonitor 默认 beat_period=%s：一挂上去就是台不走的屏（D75）" % str(ecg.beat_period))
	var p0: int = ecg.phase()
	if p0 < 0 or p0 >= pattern.size():
		_fail("phase() 越界：%d（应在 0..%d）" % [p0, pattern.size() - 1])
	ecg.beat_period = 0.0
	if ecg.phase() != 0:
		_fail("beat_period=0 时 phase() 给了 %d：填 0 应当是「不走、钉在瓦片原样」，不是随机一相（D75）"
			% ecg.phase())
	root.remove_child(ecg)
	ecg.free()


## D76 假墙盖：第三件零契约表现件，时基却与钟/屏那两件**相反** —— 前两件钉"只读世界钟"，
## 这一件钉"不读世界钟"：本作横按方向键即冻世界，照时钟揭幕会在玩家正朝它走的时候停住。
## 静态这一遍钉的是那几类"改了不响"的东西：
## ① 时基只有位置：源码里出现 `elapsed_world_time` / `TimeReceiver` / `_process` 就是换了时基；
## ② 零契约：不发 signal、不认 run_state；
## ③ 层的两把开关：z_index 必须压过 z=0（墙/玩家/屋里摆的东西），collision_enabled 必须关
##    （它画的是带碰撞多边形的实心格，不关就是一面看不见的墙）；
## ④ 距离三档 + 两条边界：站进自己的格子里一律 0（只按到洞口的距离算，走进屋走到底会被
##    重新盖住 —— 这条只在"走到最里面"才露馅）；far <= near 时不许出 NaN；
## ⑤ 逐格核"盖的必须是墙的实心格"（坐标从 tiles.json 里 mask 全满那格来，不写死），
##    并当场跑两条对照：刷对的一层必须**没有**问题、错一格必须**报**问题 —— 否则这条
##    本身就是假绿。
func _verify_cave_cover() -> void:
	var src := _code_only(FileAccess.get_file_as_string(CAVE_COVER_SCRIPT))
	if src.is_empty():
		_fail("读不到 %s" % CAVE_COVER_SCRIPT)
		return
	for banned in ["elapsed_world_time", "TimeReceiver", "run_state", "\nsignal "]:
		if src.contains(banned):
			_fail("CaveCover 里出现了 %s：它是位置纯表现件，不许换时基，也不许有契约面（D76）" % banned)
	if src.contains("func _process("):
		_fail("CaveCover 里出现了 _process：不透明度只走物理通道（D76 同 D69）")
	if not src.contains("func _physics_process("):
		_fail("CaveCover 没有 _physics_process：它不会自己更新，盖子永远停在出厂值（D76）")

	var cover = _enter(CAVE_COVER_SCENE)
	if cover.get_class() != "TileMapLayer":
		_fail("CaveCover 的根是 %s，不是 TileMapLayer（D76）" % cover.get_class())
	if cover.z_index != 1:
		_fail("cave_cover.tscn 的 z_index=%d（应为 1：要压过 z=0 的墙、玩家与屋里摆的东西）"
			% cover.z_index)
	if cover.collision_enabled:
		_fail("cave_cover.tscn 开着碰撞：它画的是带碰撞多边形的实心格，玩家会撞在看不见的墙上（D76）")
	if not cover.get_used_cells().is_empty():
		_fail("cave_cover.tscn 自带 %d 格：出厂必须是空层，格子归作者刷（D76）"
			% cover.get_used_cells().size())

	var manifest := _tiles_manifest()
	var solid := _solid_atlas_coords(manifest)
	if solid.x < 0:
		_fail("tiles.json 里找不到 mask 全满的那一格，逐格核没法做（D76）")
		root.remove_child(cover)
		cover.free()
		return

	# 合成 3×2 格的一间"暗室"，全部刷成实心格。
	cover.tile_set = load(LAB_TILESET)
	cover.global_position = Vector2(2000.0, -600.0)
	for x in 3:
		for y in 2:
			cover.set_cell(Vector2i(x, y), 0, solid)
	cover.reveal_near = 32.0
	cover.reveal_far = 96.0
	var cell := Vector2(cover.tile_set.tile_size)
	var want_rect := Rect2(Vector2(2000.0, -600.0), cell * Vector2(3, 2))
	var rect: Rect2 = cover.reveal_rect()
	if rect.position.distance_to(want_rect.position) > 0.01 or rect.size != want_rect.size:
		_fail("reveal_rect()=%s，3×2 格应得 %s：包围盒算错，站进屋里那条规则会跟着失准（D76）"
			% [str(rect), str(want_rect)])
	if cover.mouth_point().distance_to(rect.get_center()) > 0.01:
		_fail("没有 Mouth 时 mouth_point() 没退回包围盒中心：%s 对 %s（D76）"
			% [str(cover.mouth_point()), str(rect.get_center())])

	# 洞口放到左外侧一格：于是包围盒中心离它 40 px，落在 near/far 中间。
	var mouth := Marker2D.new()
	mouth.name = "Mouth"
	cover.add_child(mouth)
	mouth.global_position = rect.position + Vector2(-cell.x, cell.y)
	var mouth_at: Vector2 = mouth.global_position
	if cover.mouth_point().distance_to(mouth_at) > 0.01:
		_fail("放了 Mouth 之后 mouth_point() 没用那个点：%s 对 %s（D76）"
			% [str(cover.mouth_point()), str(mouth_at)])
	if cover.alpha_for(mouth_at + Vector2(cover.reveal_far + 100.0, 0.0)) != 1.0:
		_fail("远于 reveal_far 的位置 alpha=%s（应为 1）：盖不住（D76）"
			% str(cover.alpha_for(mouth_at + Vector2(cover.reveal_far + 100.0, 0.0))))
	if cover.alpha_for(mouth_at + Vector2(cover.reveal_near * 0.5, 0.0)) != 0.0:
		_fail("近于 reveal_near 的位置 alpha=%s（应为 0）：露不出来（D76）"
			% str(cover.alpha_for(mouth_at + Vector2(cover.reveal_near * 0.5, 0.0))))
	var mid_d: float = (cover.reveal_near + cover.reveal_far) * 0.5
	var got: float = cover.alpha_for(mouth_at + Vector2(mid_d, 0.0))
	var want_mid: float = (mid_d - cover.reveal_near) / (cover.reveal_far - cover.reveal_near)
	if absf(got - want_mid) > 0.0001:
		_fail("中间档不是线性的：%s px 处得到 %.3f，按 near/far 重算应为 %.3f（D76）"
			% [str(mid_d), got, want_mid])
	# 包围盒中心离洞口 40 px（near/far 之间，不在屋里的算法会给 0.125）。
	if cover.alpha_for(rect.get_center()) != 0.0:
		_fail("玩家中心落在盖子自己的格子里时 alpha=%.3f（应为 0）：走进屋走到底会被重新盖住（D76）"
			% cover.alpha_for(rect.get_center()))
	cover.reveal_near = 50.0
	cover.reveal_far = 10.0
	var degenerate: float = cover.alpha_for(mouth_at + Vector2(-60.0, 0.0))
	if degenerate != 1.0:
		_fail("reveal_far <= reveal_near 时 alpha_for 给了 %s（应为 1，且不许是 NaN）（D76）"
			% str(degenerate))
	cover.reveal_near = 32.0
	cover.reveal_far = 96.0

	# —— 逐格核：正对照 + 两条负对照 ——
	var problems := _cover_cell_problems(cover)
	if not problems.is_empty():
		_fail("刷对实心格的盖子被逐格核判红：%s（D76 假红）" % problems[0])
	var full := _full_mask(manifest)
	var wrong := Vector2i(-1, -1)
	for entry in manifest["terrain"]["tiles"]:
		if int(entry["mask"]) != full:
			wrong = Vector2i(int(entry["x"]) / int(manifest["tile"]),
				int(entry["y"]) / int(manifest["tile"]))
			break
	if wrong.x < 0:
		_fail("tiles.json 里找不到非实心格，逐格核的负对照造不出来（D76）")
	else:
		cover.set_cell(Vector2i(2, 1), 0, wrong)
		if _cover_cell_problems(cover).is_empty():
			_fail("逐格核对一格错瓦片（%s）没报红：这条「每格都得是实心格」是假绿（D76）"
				% str(wrong))
		cover.set_cell(Vector2i(2, 1), 0, solid)
	var empty = load(CAVE_COVER_SCENE).instantiate()
	root.add_child(empty)
	empty.tile_set = load(LAB_TILESET)
	if _cover_cell_problems(empty).is_empty():
		_fail("逐格核对一格没刷的盖子没报红：摆上去等于没盖（D76）")
	root.remove_child(empty)
	empty.free()

	# 运行态正面控制（D76 订正 2026-10-28）：进树前刷好格子的盖子会在 _ready 里拆进
	# `Patch1…` 子层、根层清空。逐格核只看根层的话，这一种会被误判成"一格都没刷" ——
	# 所以这里真造一个拆过的，先证明它确实拆了，再证明逐格核扫得到。扫关那一步是
	# `free()` 掉不进树的实例，走不到这条路径，只能在这里钉。
	var split_cover = load(CAVE_COVER_SCENE).instantiate()
	split_cover.tile_set = load(LAB_TILESET)
	for x in 2:
		for y in 2:
			split_cover.set_cell(Vector2i(x, y), 0, solid)
	root.add_child(split_cover)
	if split_cover.patch_count() != 1 or not split_cover.get_used_cells().is_empty():
		_fail("进树后没拆成 Patch1（patch_count=%d，根上剩 %d 格）：下面这条正面控制是空转的"
			% [split_cover.patch_count(), split_cover.get_used_cells().size()])
	var split_problems := _cover_cell_problems(split_cover)
	if not split_problems.is_empty():
		_fail("拆过的盖子被逐格核判红（根层已清空，格子都在子层）：%s（D76 订正）"
			% split_problems[0])
	root.remove_child(split_cover)
	split_cover.free()

	root.remove_child(cover)
	cover.free()


## 盖子逐格核（D76）：它盖的必须是**这面墙本来会长成的那一格** —— mask 四边全满的实心格。
## 用背景 `WallFill` 那格（atlas (0,2)）或任意边缘格都会在接缝处露馅：那是一套另一个材质
## （实测与实心格逐字节差 768/1024），而盖子的全部价值就是"接缝看不出来"。
## 多块（2026-10-28）：运行中的盖子会把格子搬进 `Patch1…` 子层（每块独立判定），根层随即
## 被清空 —— 所以这里按 `all_patches()` 汇总扫，只看根层会把一块正常的盖子判成"一格都没刷"。
func _cover_cell_problems(cover: TileMapLayer) -> PackedStringArray:
	var out := PackedStringArray()
	if cover.tile_set == null:
		out.append("没挂 tile_set：空层读不出材质，也没法确认它盖的是这面墙")
		return out
	var layers: Array = [cover]
	if cover.has_method(&"all_patches"):
		var patches: Array = cover.call(&"all_patches")
		if not patches.is_empty():
			layers = patches
	var solid := _solid_atlas_coords(_tiles_manifest())
	if solid.x < 0:
		out.append("tiles.json 里找不到实心格的坐标")
		return out
	var total := 0
	var bad := 0
	var first := Vector2i.ZERO
	var first_src := -1
	var first_atlas := Vector2i.ZERO
	var first_alt := 0
	for layer in layers:
		var map := layer as TileMapLayer
		if map == null or map.tile_set == null:
			out.append("有一块 Patch 没挂 tile_set：那块读不出材质，画出来是空的")
			continue
		for cell in map.get_used_cells():
			total += 1
			var src := map.get_cell_source_id(cell)
			var atlas := map.get_cell_atlas_coords(cell)
			var alt := map.get_cell_alternative_tile(cell)
			if src == 0 and atlas == solid and alt == 0:
				continue
			bad += 1
			if bad == 1:
				first = cell
				first_src = src
				first_atlas = atlas
				first_alt = alt
	if total == 0:
		out.append("一格都没刷：它盖不住任何东西")
		return out
	if bad > 0:
		out.append(("%d/%d 格不是墙的实心格（第一格 %s 是 src=%d atlas=%s alt=%d，"
			+ "应为 src=0 atlas=%s alt=0）：接缝会露馅")
			% [bad, total, str(first), first_src, str(first_atlas), first_alt, str(solid)])
	return out


## D77 梦泡（新手引导）的静态一遍。第 26 组钉的是帧上的行为，这里钉的是"改了不响、
## 要到开局那一拍才露馅"的那六类：
## ① 时基只有**引擎固定物理步长**一条：读世界钟 / 挂 TimeReceiver / 写 run_state / `_process`
##    全禁 —— 这一拍整段掐输入，"你按了 A 所以它停了"这种读法会把教学打成 bug（D76 那条
##    "照时钟揭幕会在人正朝它走的时候停住"是同一个形状），`_process` 则让漂移照帧率走；
## ② 几何、角度、动作映射只许有一份：全读 `assets/props/dream_bubble.json`。清单里那个半径值
##    与四个角度值不许在构件源码里再出现一次（"断言不许抄第二份数"在皮这一侧的对应物），
##    四个动作名也不许写死在构件里 —— 否则改清单改不动代码，两边静默分叉；
## ③ 清单 ↔ InputMap ↔ 磁盘 PNG 三方逐条核对：动作改名、零件少一帧、纹理尺寸与清单不符、
##    出厂态是张白纸，都在这里红，而不是等开局那只泡是空白；
## ④ 摆位两条硬前提：四只都在弧心以上（选型图第一轮真把 S 糊在睡脸上过），且每只泡离弧心
##    最近的边仍比玩家碰撞盒半高远（值从 player.gd 的常量读，不抄第二份）；
## ⑤ 接线在关卡根那侧：`begin_wake_hold()` / `release_wake()` 各恰好一处、危险物豁免真在
##    `_on_hazard_touched` 的函数体里、皮那侧的钉睡分支必须排在 `if not is_playing()` 之前
##    （wake 剪辑不循环，顺序倒了就停在"已经醒完"那张脸上）；
## ⑥ F9 跳键必须绑在 F9、被 `OS.is_debug_build()` 挡着、且带 DEBUG-KEY 标记（打包按这一句删）。
func _verify_dream_bubbles() -> void:
	var src := _code_only(FileAccess.get_file_as_string(DREAM_SCRIPT))
	if src.is_empty():
		_fail("读不到 %s" % DREAM_SCRIPT)
		return
	for banned in ["elapsed_world_time", "TimeReceiver", "get_physics_delta", "run_state",
			"Engine.time_scale", "anchorable"]:
		if src.contains(banned):
			_fail("DreamBubbles 里出现了 %s：这一拍的时基只有引擎物理步长一条，也不许有第二张契约面（D77）"
				% banned)
	if src.contains("func _process("):
		_fail("DreamBubbles 里出现了 _process：漂移与破帧照帧率走，掉帧时引导自己变快（D77）")
	if not src.contains("func _physics_process("):
		_fail("DreamBubbles 没有 _physics_process：四只泡停在出厂态 = 永不苏醒（不按就不醒这条会静默变成「怎么按都不醒」）")
	var reads := src.count("Input.is_action_just_pressed(")
	if reads < 2:
		_fail("DreamBubbles 里 `is_action_just_pressed` 只有 %d 发（要 2：跳键一发 + 四只泡按动作那一发）：" % reads +
			"后一发没了就是键盘检验这条静默失效（D77）")
	if not src.contains("OS.is_debug_build()"):
		_fail("DreamBubbles 的跳键没被 OS.is_debug_build() 挡着：发布版里 F9 白拿一段引导（D77）")
	# 标记按规矩打在代码行本身或它上一行 —— 只扫全文会被文件头那段说明喂绿（那不是删得掉的行）。
	var raw_lines := FileAccess.get_file_as_string(DREAM_SCRIPT).split("\n")
	var marked := false
	for i in raw_lines.size():
		if not str(raw_lines[i]).contains("dev_skip_dream"):
			continue
		if str(raw_lines[i]).contains("DEBUG-KEY") \
				or (i > 0 and str(raw_lines[i - 1]).contains("DEBUG-KEY")):
			marked = true
	if not marked:
		_fail("DreamBubbles 里读 dev_skip_dream 那一行没有 DEBUG-KEY 标记：打包时找不到该删哪一句（D77）")

	var manifest = JSON.parse_string(FileAccess.get_file_as_string(DREAM_MANIFEST))
	if manifest == null:
		_fail("读不到 %s —— 先跑 py tools/gen_dream_bubble_parts.py（D77）" % DREAM_MANIFEST)
		return
	for key in ["radius", "arc_origin_y", "bubbles", "parts", "states"]:
		if not manifest.has(key):
			_fail("清单缺键 %s（构件全靠它，源码里不许有第二份）（D77）" % key)
	if manifest.has("radius") and src.contains(str(int(manifest["radius"]))):
		_fail("构件源码里出现了第二份半径 %s：几何只许读清单（D77）" % str(int(manifest["radius"])))
	for entry in manifest["bubbles"]:
		if src.contains(str(int(entry["deg"]))):
			_fail("构件源码里出现了第二份角度 %s：摆位只许读清单（D77）" % str(int(entry["deg"])))
	for action in ["move_left", "move_down", "move_right", "jump"]:
		if src.contains("\"%s\"" % action) or src.contains("&\"%s\"" % action):
			_fail("构件源码里写死了动作名 %s：映射只许住在清单里，否则改清单改不动代码（D77）" % action)

	var states: int = int(manifest.get("states", 0))
	var radius: float = float(manifest.get("radius", 0.0))
	var bubbles: Array = manifest.get("bubbles", [])
	var parts: Dictionary = manifest.get("parts", {})
	if states < 2:
		_fail("清单 states=%d：破的那一拍至少要留两帧，否则「按下去会发生什么」教不出来（D77）" % states)
	if bubbles.size() != 4:
		_fail("清单里是 %d 只泡（D77 定死四只：A / S / space / D；要加第五只先回来落档再改这条）"
			% bubbles.size())
	# 集合核对：D77 裁的是"四只 = 左 / 下 / 跳 / 右"，W（InputMap 里没有向上这个动作）与 Q
	#（这一拍 movement_locked 为真，那只泡永远破不了 = 直接软锁）都不许悄悄回来。
	var seen := {}
	for entry in bubbles:
		seen[str(entry.get("action", ""))] = true
	for want in ["move_left", "move_down", "move_right", "jump"]:
		if not seen.has(want):
			_fail(("清单里没有 %s 这只泡：这一拍教的是移动与跳四件事，"
				+ "少一只就有一个人按了没反应还以为是键盘坏了（D77）") % want)
	if seen.has("move_up") or seen.has("anchor"):
		_fail("清单里出现了 W 向或 Q（anchor）那一只：D77 明确撤过 —— 向上没有动作可绑，" +
			"而这一拍锁着移动，锚点泡永远破不了会直接软锁（D77）")

	var arc_y: float = float(manifest.get("arc_origin_y", 0.0))
	var player_cs: Dictionary = (load("res://scenes/actors/player/player.gd") as GDScript) \
		.get_script_constant_map()
	var box_half: float = float(player_cs.get("COLLISION_HALF_HEIGHT", 15.0))
	var prev_x := -1.0e20
	for entry in bubbles:
		var action := str(entry.get("action", ""))
		var part := str(entry.get("part", ""))
		if not InputMap.has_action(StringName(action)):
			_fail("清单里的动作 %s 不在 InputMap：那只泡没人按得破，引导变成死锁（D77）" % action)
		var deg := float(entry.get("deg", 0.0))
		var pos := Vector2(radius * cos(deg_to_rad(deg)), -radius * sin(deg_to_rad(deg)))
		if pos.x <= prev_x:
			_fail("清单的摆位不是从左到右（%s 落在 x=%.1f，前一只 x=%.1f）：阅读顺序 A→S→space→D 要按图走（D77）"
				% [part, pos.x, prev_x])
		prev_x = pos.x
		if pos.y >= 0.0:
			_fail("泡 %s 落在弧心下方（y=%.1f）：会糊在睡脸/脚上，第一轮选型图真踩过（D77）" % [part, pos.y])
		var size: Array = parts.get(part, [])
		if size.size() != 2:
			_fail("清单 parts 里没有 %s 的尺寸（D77）" % part)
			continue
		var hw: float = float(size[0]) * 0.5
		var hh: float = float(size[1]) * 0.5
		var unit := pos.normalized()
		var support: float = hw * absf(unit.x) + hh * absf(unit.y)
		if radius - support < box_half:
			_fail("泡 %s 最近边到弧心只有 %.1f px（< 玩家碰撞盒半高 %.1f）：那只泡压在人身上（D77）"
				% [part, radius - support, box_half])
		# 磁盘上的零件：一帧都不许缺，尺寸必须与清单一致（构件按"块心"画，尺寸对不上就错位）。
		var base_opaque := -1
		for state in states:
			var path := "res://assets/props/dream_bubble/%s_%d.png" % [part, state]
			if not FileAccess.file_exists(path):
				_fail("零件不在: %s（先跑 py tools/gen_dream_bubble_parts.py，再 --import）（D77）" % path)
				continue
			var tex := load(path) as Texture2D
			if tex == null:
				_fail("纹理加载失败: %s（多半是没 --import）（D77）" % path)
				continue
			if tex.get_width() != int(size[0]) or tex.get_height() != int(size[1]):
				_fail("%s 是 %dx%d，清单写的 %dx%d：构件按清单尺寸对齐，对不上就错位（D77）"
					% [path, tex.get_width(), tex.get_height(), int(size[0]), int(size[1])])
			var img := tex.get_image()
			img.convert(Image.FORMAT_RGBA8)
			var opaque := 0
			for y in img.get_height():
				for x in img.get_width():
					if img.get_pixel(x, y).a > 0.0:
						opaque += 1
			var total := img.get_width() * img.get_height()
			if state == 0:
				base_opaque = opaque
				if opaque * 2 < total:
					_fail("%s 出厂态只占了 %d/%d 格：那只泡在夜光墙上等于不存在（D77）"
						% [path, opaque, total])
			elif base_opaque > 0 and opaque >= base_opaque:
				_fail("%s 不比出厂态稀疏：破的那三帧没在散，按下去看不出「它破了」（D77）" % path)
	_dreams_checked += bubbles.size()

	var scene = load(DREAM_SCENE).instantiate()
	root.add_child(scene)
	if scene.get_class() != "Node2D":
		_fail("dream_bubbles.tscn 的根是 %s，不是纯 Node2D：引导件不许带碰撞体——它会自己挡在人和地之间（D77）"
			% scene.get_class())
	if scene.get_child_count() != 0:
		_fail("dream_bubbles.tscn 带了 %d 个子节点：它只需要自己画纹理（D77）" % scene.get_child_count())
	var cover = load(CAVE_COVER_SCENE).instantiate()
	if scene.z_index <= cover.z_index:
		_fail("梦泡的 z=%d 没高过假墙盖的 z=%d：开局要是站在盖子底下，四只泡会被糊掉（D77）"
			% [scene.z_index, cover.z_index])
	if scene.z_index <= 0:
		_fail("梦泡的 z=%d 没高过玩家（z=0）：那一拍要看的是泡，不是后脑勺（D77）" % scene.z_index)
	cover.free()
	root.remove_child(scene)
	scene.free()

	var base := _code_only(FileAccess.get_file_as_string(LEVEL_BASE_SCRIPT))
	var holds := base.count("begin_wake_hold()")
	if holds != 1:
		_fail("LevelBase 里 begin_wake_hold() 的调用点 = %d（应为 1）：钉住只许一个书写者（D77）" % holds)
	var wakes := base.count("release_wake()")
	if wakes != 1:
		_fail("LevelBase 里 release_wake() 的调用点 = %d（应为 1）：交回只许一个书写者，" % wakes +
			"多一处就是第二条并行的「醒」路径（D77）")
	if not base.contains("player.begin_wake()"):
		_fail("LevelBase 的 `dream_intro=false` 那一支没走现成的 begin_wake()：「这关不做引导」" +
			"该是合法配置而不是人永远睡着（D77）")
	var hazard_body := _func_body(base, "func _on_hazard_touched(")
	if not hazard_body.contains("_dream != null"):
		_fail("_on_hazard_touched 的函数体里没有 _dream 豁免：引导演到一半人被刺死，" +
			"而 take_intro 早就消费掉了 —— 这一世不再重演（D77）")
	var visual := _code_only(FileAccess.get_file_as_string("res://scenes/actors/player/player_visual.gd"))
	var hold_at := visual.find("is_wake_held()")
	var play_at := visual.find("if not is_playing()")
	if hold_at < 0:
		_fail("PlayerVisual 没有钉睡分支：held 只锁移动不锁皮，wake 剪辑会自己走完（D77）")
	elif play_at >= 0 and hold_at > play_at:
		_fail("钉睡分支排在了 `if not is_playing()` 之后：剪辑不循环，走完就停在「已经醒完」那张脸上（D77）")

	if not InputMap.has_action(&"dev_skip_dream"):
		_fail("InputMap 里没有 dev_skip_dream：开发期每次启动都要按四下才动（D77）")
	else:
		var on_f9 := false
		for event in InputMap.action_get_events(&"dev_skip_dream"):
			if event is InputEventKey and int((event as InputEventKey).physical_keycode) == int(KEY_F9):
				on_f9 = true
		if not on_f9:
			_fail("dev_skip_dream 没绑 F9 physical_keycode：跳键找不到，打包时也就不知道该删哪条（D77）")


## D78 开场遮罩：皮 = 清单 + 一张 PNG，行为 = `Player.wake_progress()` 的纯函数。
## 这里核"三方对得上 + 不许有第二份数"；屏上到底长什么样归 tools/dream_mask_shot.tscn
## （无头看不到渲染，那一份才是"皮只能看见才算数"）。
func _verify_dream_mask() -> void:
	var src := _code_only(FileAccess.get_file_as_string(MASK_SCRIPT))
	if src.is_empty():
		_fail("读不到 %s" % MASK_SCRIPT)
		return
	for banned in ["elapsed_world_time", "TimeReceiver", "run_state", "Engine.time_scale",
			"anchorable", "func _process(", "signal "]:
		if src.contains(banned):
			_fail("DreamMask 里出现了 %s：这一拍的时基只有引擎物理步长一条、契约面只有 " % banned +
				"`wake_progress` 一条，也不许通知任何人（D78）")
	if not src.contains("func _physics_process("):
		_fail("DreamMask 没有 _physics_process：取景每拍都要重算（人会动、相机会动、zoom 会变），" +
			"摆好一次等于把它钉死在第一帧的屏幕上（D78）")
	if not src.contains("wake_progress("):
		_fail("DreamMask 没读 wake_progress()：那它跟的是别的进度，遮罩与苏醒窗口会各走各的（D78）")

	var manifest = JSON.parse_string(FileAccess.get_file_as_string(MASK_MANIFEST))
	if manifest == null:
		_fail("读不到 %s —— 先跑 py tools/gen_dream_mask_preview.py（D78）" % MASK_MANIFEST)
		return
	for key in ["radius", "edge_width", "cap", "open_radius", "breath_amplitude", "breath_period",
			"arc_origin_y", "corner_radius", "tex_px_per_world_px", "texture", "colour"]:
		if not manifest.has(key):
			_fail("遮罩清单缺键 %s：构件全靠它，源码里不许有第二份（D78）" % key)
	# `cap` 不在这一列里：它的值就是 1.0，而源码合法地写着 `1.0 - p`。
	var nums := _src_numbers(src)
	for key in ["radius", "edge_width", "open_radius", "breath_amplitude", "breath_period",
			"arc_origin_y", "corner_radius", "tex_px_per_world_px"]:
		var v := float(manifest.get(key, 0.0))
		if nums.has(v):
			_fail("DreamMask 源码里有第二份 %s（=%s）：改清单改不动屏幕（D78）" % [key, str(v)])

	var r_in := float(manifest.get("radius", 0.0))
	var ramp_w := float(manifest.get("edge_width", 0.0))
	var cap := float(manifest.get("cap", 0.0))
	var corner := int(manifest.get("corner_radius", 0))
	var per_world := float(manifest.get("tex_px_per_world_px", 0.0))
	var col: Array = manifest.get("colour", [])
	var want_full := int(round(cap * 255.0))
	if cap <= 0.0 or cap > 1.0:
		_fail("清单 cap=%s：外圈压暗的档位必须在 (0,1]，0 等于这一层白画（D78）" % str(cap))
	if per_world <= 0.0:
		_fail("清单 tex_px_per_world_px=%s：皮的烘法比例没了，屏上半径就没法换算（D78）" % str(per_world))

	if not FileAccess.file_exists(MASK_PNG):
		_fail("遮罩皮不在 %s —— 先跑 py tools/gen_dream_mask_preview.py，再 --import（D78）" % MASK_PNG)
		return
	var tex := load(MASK_PNG) as Texture2D
	if tex == null:
		_fail("遮罩皮加载失败: %s（多半是没 --import）（D78）" % MASK_PNG)
		return
	var img := tex.get_image()
	img.convert(Image.FORMAT_RGBA8)
	var side := img.get_width()
	if img.get_height() != side:
		_fail("遮罩皮是 %dx%d 不是正方形：张开靠整张放大，非正方会在某一边先露底（D78）"
			% [side, img.get_height()])
	var tex_c: Dictionary = manifest.get("texture", {})
	if int(tex_c.get("side", -1)) != side:
		_fail("清单 texture.side=%s 而皮是 %d 宽：两边不是同一次生成的（D78）"
			% [str(tex_c.get("side", "<无>")), side])
	_masks_checked += 1
	var centre := Vector2i(side / 2, img.get_height() / 2)
	var c_list: Array = tex_c.get("centre", [])
	if c_list.size() == 2 and (int(c_list[0]) != centre.x or int(c_list[1]) != centre.y):
		_fail("清单 texture.centre=%s 与皮的几何中心 (%d,%d) 不符：构件按清单那个点取景（D78）"
			% [str(c_list), centre.x, centre.y])
	if side / 2 < int(ceil(float(corner) * per_world)):
		_fail("皮只有 %d 宽（半径 %d 纹理像素），装不下 corner_radius=%d 世界像素：张到最大时" % [side, side / 2, corner] +
			"屏幕四角会先露出没遮罩的空隙（D78）")
	# alpha 剖面：亮区不许被压、软边必须一路单调到底、外圈必须真的按 `cap` 压住。
	# 这一条是 D78 自己踩出来的：第一版环只画到 r_out 为止，屏上是一圈黑环、远处照旧清楚。
	var ramp_lo := -1
	var ramp_hi := -1
	var prev_a := -1
	var outer_bad := false		# 外圈只报第一处：那是同一次生成出的同一个毛病，逐格刷屏没人看
	var inner_bad := false		# 亮区同理
	for d in range(0, corner + 3):
		var x := centre.x + int(round(float(d) * per_world))
		if x >= side:
			break
		var p := img.get_pixel(x, centre.y)
		var a := int(round(p.a * 255.0))
		if d <= int(r_in) - 1 and a != 0 and not inner_bad:
			inner_bad = true
			_fail("皮在亮区内 d=%d 处 alpha=%d（应为 0）：人的脸会被自己那层遮罩糊掉（D78）" % [d, a])
		if d >= int(r_in) + 1 and d <= int(r_in * (1.0 + ramp_w)):
			if ramp_lo < 0:
				ramp_lo = d
			ramp_hi = d
			if prev_a > a:
				_fail("软边在 d=%d 处回弹（%d -> %d）：环不是逐圈单调涂出来的（D78）" % [d, prev_a, a])
			prev_a = a
		if d > int(r_in * (1.0 + ramp_w)) + 1 and a != want_full and not outer_bad:
			outer_bad = true
			_fail("皮在外圈 d=%d 处 alpha=%d（清单 cap 要 %d）：遮罩外圈没压住 = 那圈还是亮的（D78）"
				% [d, a, want_full])
		# 透明那半边也得涂成遮罩色：LINEAR 采样跨过硬边时会把黑色混进来，屏上出现一圈灰边。
		if col.size() == 3 and absi(int(round(p.r * 255.0)) - int(col[0])) > 2:
			_fail("皮在 d=%d 处 RGB 是 %s，清单遮罩色是 %s：底色不是遮罩色的话，软边会被采样糊成灰圈（D78）"
				% [d, str(p), str(col)])
			break
	if ramp_lo < 0:
		_fail("皮上找不到软边（r_in=%s w=%s）：那条过渡带没画出来 = 硬边一圈，看着像贴了个洞（D78）"
			% [str(r_in), str(ramp_w)])
	else:
		var lo := centre.x + int(round(float(ramp_lo) * per_world))
		var hi := centre.x + int(round(float(ramp_hi) * per_world))
		var rise: int = int(round(img.get_pixel(hi, centre.y).a * 255.0)) \
			- int(round(img.get_pixel(lo, centre.y).a * 255.0))
		if rise < 120:
			_fail("软边从 d=%d 到 d=%d 只走了 %d/255 档：那条过渡带在屏上根本看不出来（D78）"
				% [ramp_lo, ramp_hi, rise])
	_masks_checked += 2

	# 张到底那一拍必须真的放开整屏：屏角在 progress=1 时的压暗量要接近 0。
	var open_r := float(manifest.get("open_radius", 0.0))
	var corner_alpha := _smooth_alpha(float(corner), open_r, ramp_w)
	if corner_alpha > 0.05:
		_fail("progress=1 时屏角还压着 %.1f%%（open_radius=%s 对 corner_radius=%d）：醒完了四角还是黑的（D78）"
			% [corner_alpha * 100.0, str(open_r), corner])

	# 与梦泡同一只弧心 + 亮区必须把四只泡整个包住（不然遮罩把要教的那几只键糊掉）。
	var dream = JSON.parse_string(FileAccess.get_file_as_string(DREAM_MANIFEST))
	if dream == null:
		_fail("读不到 %s：遮罩没法核对亮区包不包得住四只泡（D78）" % DREAM_MANIFEST)
	else:
		if float(dream.get("arc_origin_y", 0.0)) != float(manifest.get("arc_origin_y", 0.0)):
			_fail("遮罩的弧心偏移 %s 与梦泡的 %s 不是同一个：亮区与四只泡不同心，看着像有人把泡挪歪了（D78）"
				% [str(manifest.get("arc_origin_y", "<无>")), str(dream.get("arc_origin_y", "<无>"))])
		var arc_r := float(dream.get("radius", 0.0))
		var parts: Dictionary = dream.get("parts", {})
		var far := 0.0
		for entry in dream.get("bubbles", []):
			var deg := float(entry.get("deg", 0.0))
			var pos := Vector2(arc_r * cos(deg_to_rad(deg)), -arc_r * sin(deg_to_rad(deg)))
			var size: Array = parts.get(str(entry.get("part", "")), [])
			if size.size() != 2:
				continue
			var unit := pos.normalized()
			var support := float(size[0]) * 0.5 * absf(unit.x) + float(size[1]) * 0.5 * absf(unit.y)
			far = maxf(far, arc_r + support)
		if r_in < far + 2.0:
			_fail("亮区半径 %s 包不住四只泡最远的那一角（%.1f px 再加 2 余量）：遮罩会把要教的键糊掉（D78）"
				% [str(r_in), far])
		_masks_checked += 2

	var scene = load(MASK_SCENE).instantiate()
	# 进树才读得到 `layer`：那一档是 `_ready()` 里写的（.tscn 里没存），不进树读到的永远是默认 1，
	# 那两条判据就成了永远不响的假绿（第一版正是这样绿过去的）。
	root.add_child(scene)
	if scene.get_class() != "CanvasLayer":
		_fail("dream_mask.tscn 的根是 %s，不是 CanvasLayer：遮罩要盖住整个世界，" % scene.get_class() +
			"用 Node2D 就得靠 z_index 跟所有层抢（D78）")
	elif scene.layer <= 0:
		_fail("遮罩的 layer=%d 不在世界之上：世界自己那几层会把它盖掉（D78）" % scene.layer)
	if scene.get_child_count() != 1 or not (scene.get_node_or_null("Mask") is Sprite2D):
		_fail("dream_mask.tscn 里那一个子节点不是叫 Mask 的 Sprite2D：构件与实拍器都按这个名字取（D78）")
	var filter = load(FILTER_SCRIPT).instantiate()
	if scene.layer >= filter.layer:
		_fail("遮罩的 layer=%d 没低过冻结滤镜的 %d：滤镜吃的是屏幕，遮罩要被它一起扫进去才对（D78）"
			% [scene.layer, filter.layer])
	filter.free()
	root.remove_child(scene)
	scene.free()
	_masks_checked += 1

	var music_tscn := FileAccess.get_file_as_string("res://autoloads/Musicplayer.tscn")
	if music_tscn.contains("autoplay = true"):
		_fail("Musicplayer 还挂着 autoplay = true：他还没睁眼 BGM 就在放，D78 那条白做")
	elif not music_tscn.contains("autoplay = false"):
		_fail("Musicplayer 里找不到 autoplay = false：起播点不在代码里，谁改都改不动（D78）")
	var base := _code_only(FileAccess.get_file_as_string(LEVEL_BASE_SCRIPT))
	var starts := base.count("_start_music()")
	if starts != 3:
		_fail("LevelBase 里 `_start_music()` 出现 %d 次（定义 1 + 出口 2 = 3）：" % starts +
			"多一处就多一个起播点，少一处就有一条路永远不响（D78）")
	var body := _func_body(base, "func _start_music(")
	if body.is_empty():
		_fail("LevelBase 没有 _start_music()：BGM 的起点散在了调用点上（D78）")
	else:
		if not body.contains("music.get(&\"playing\")"):
			_fail("_start_music 没先问 playing：死亡重载与按 R 会把已经在放的那首从头再来一遍（D78）")
		if body.count("call(&\"play\")") != 1:
			_fail("_start_music 体里 `call(&\"play\")` = %d（应为 1）（D78）" % body.count("call(&\"play\")"))
	if base.count("call(&\"play\")") != 1:
		_fail("LevelBase 全文有 %d 发 `call(&\"play\")`（只许 _start_music 里那一发）：" % base.count("call(&\"play\")") +
			"BGM 的起点必须只有一个，否则「什么时候响」没人说得清（D78）")
	var completed := _func_body(base, "func _on_dream_completed(")
	if not completed.contains("_start_music()"):
		_fail("_on_dream_completed 没叫 _start_music()：四只泡全破完之后音乐永远不来（D78）")


## 源码里出现过的**数字字面量**（去注释后扫，见 `_code_only`）。
## 为什么不用 `contains("80")`：那条既会把 `0.45` 里的 "45" 当成 45，又会把 `80.0` 这种
## 真字面量漏掉（D78 第一版就是这么假绿过去的 —— 源码里写死 80.0，判据一声不响）。
func _src_numbers(src: String) -> Array:
	var out: Array = []
	var n := src.length()
	var i := 0
	while i < n:
		var ch := src.substr(i, 1)
		var neg := false
		if ch == "-" and i + 1 < n:
			var prev0 := src.substr(maxi(i - 1, 0), 1)
			var nxt := src.substr(i + 1, 1)
			if not _ident_ch(prev0) and nxt >= "0" and nxt <= "9":
				neg = true
				i += 1
				ch = src.substr(i, 1)
		if ch >= "0" and ch <= "9":
			var prev := src.substr(maxi(i - 1, 0), 1) if not neg else src.substr(maxi(i - 2, 0), 1)
			if _ident_ch(prev) or prev == ".":
				i += 1
				continue
			var j := i
			while j < n:
				var cj := src.substr(j, 1)
				if (cj >= "0" and cj <= "9") or cj == ".":
					j += 1
				else:
					break
			var tok := src.substr(i, j - i)
			while tok.ends_with("."):
				tok = tok.substr(0, tok.length() - 1)
			if tok.count(".") > 1:
				i = j
				continue
			var v := tok.to_float()
			if neg:
				v = -v
			if not out.has(v):
				out.append(v)
			i = j
			continue
		i += 1
	return out


func _ident_ch(ch: String) -> bool:
	var code := ch.unicode_at(0)
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
		or code == 95


## 与生成器 `ramp_alpha` 同一条算式（smoothstep）：这里复算的是**形状**，数全从清单来。
func _smooth_alpha(d: float, r_in: float, w: float) -> float:
	if w <= 0.0:
		return 0.0 if d <= r_in else 1.0
	var r_out := r_in * (1.0 + w)
	if d <= r_in:
		return 0.0
	if d >= r_out:
		return 1.0
	var t := (d - r_in) / (r_out - r_in)
	return t * t * (3.0 - 2.0 * t)


## 取某个函数的体（到下一个顶层 `func ` 为止）。豁免这类判据必须钉在**那一个函数里**，## 全文 contains 会被别处的同名变量喂绿（`_dream != null` 在 _on_dream_completed 里也有一句）。
func _func_body(src: String, signature: String) -> String:
	var at := src.find(signature)
	if at < 0:
		return ""
	var next := src.find("\nfunc ", at + signature.length())
	return src.substr(at, next - at) if next > 0 else src.substr(at)


func _tiles_manifest() -> Dictionary:
	var m = JSON.parse_string(FileAccess.get_file_as_string(TILES_MANIFEST))
	return m if m is Dictionary else {}


func _full_mask(manifest: Dictionary) -> int:
	if manifest.is_empty():
		return -1
	var bits: Dictionary = manifest["terrain"]["mask_bits"]
	var full := 0
	for key in bits:
		full |= int(bits[key])
	return full


func _solid_atlas_coords(manifest: Dictionary) -> Vector2i:
	if manifest.is_empty():
		return Vector2i(-1, -1)
	var tile: int = int(manifest["tile"])
	var full := _full_mask(manifest)
	for entry in manifest["terrain"]["tiles"]:
		if int(entry["mask"]) == full:
			return Vector2i(int(entry["x"]) / tile, int(entry["y"]) / tile)
	return Vector2i(-1, -1)


func _rgba(data: PackedByteArray, off: int) -> Array:
	return [int(data[off]), int(data[off + 1]), int(data[off + 2]), int(data[off + 3])]


func _rgba8(c: Color) -> Array:
	return [int(round(c.r * 255.0)), int(round(c.g * 255.0)),
		int(round(c.b * 255.0)), int(round(c.a * 255.0))]


## D69 周期器件：相位面板 + 相位穿梭块。静态这一遍钉的全是"改了不响、要到试玩才露馅"那几类：
## ① 时基只有 `TimeReceiver` 一条 —— 器件里出现 `elapsed_world_time` / `TimeManager.get_*_delta`
##    就是"看着在动、但锚点劫持不到"，而画面不会报错；
## ② 物理世界里只有一条状态通道（无 `_process`）；
## ③ 变实之前必须问占位（`CLEAR_MASK = 2|4` + `intersect_shape`），否则平台会塞进玩家身体里；
## ④ 面板的底座永远实、只有桥面切碰撞体；穿梭块是整块瞬移，不存在中间位置；
## ⑤ 两件都要进 `anchorable` 族、挂 `TimeReceiver`、上 time_solid 层（射线打得到）；
## ⑥ 改导出项后派生几何重算，且同场景的另一个实例不被一起改（D21 那笔账）。
## 真物理下的行为（世界钟/手/占位停住）归 kit_selftest 第 23 组。
func _verify_clock_devices() -> void:
	for path in [CLOCK_DEVICE_SCRIPT, PHASE_PANEL_SCRIPT, PHASE_SHUTTLE_SCRIPT]:
		var src := FileAccess.get_file_as_string(path)
		if src.is_empty():
			_fail("读不到 %s" % path)
			continue
		if src.contains("func _process("):
			_fail("%s 里出现了 _process：周期器件的状态只能走物理通道（D69）" % path)
		for banned in ["elapsed_world_time", "TimeManager.get_physics_delta",
				"TimeManager.get_process_delta", "Engine.time_scale", "run_state"]:
			if src.contains(banned):
				_fail("%s 里出现了 %s：器件的时基只能走 TimeReceiver，直读全局量锚点劫持不到（D69）"
					% [path, banned])
	var base_src := FileAccess.get_file_as_string(CLOCK_DEVICE_SCRIPT)
	if not base_src.contains("_receiver.get_physics_delta()"):
		_fail("ClockDevice 没从 TimeReceiver 读 delta：锚点吸上去也换不掉它的时基（D69）")
	if not base_src.contains("params.collision_mask = CLEAR_MASK") \
			or not base_src.contains("intersect_shape"):
		_fail("ClockDevice 不再问目标位置占不占：把变实的平台塞进玩家身体里不会有人拦（D69）")
	if not FileAccess.get_file_as_string(PHASE_PANEL_SCRIPT).contains("col.disabled = not on"):
		_fail("PhasePanel 不再切换 PanelShape：桥面会一直实或一直虚（D69）")
	if not FileAccess.get_file_as_string(PHASE_SHUTTLE_SCRIPT) \
			.contains("global_position = _stop_global(on)"):
		_fail("PhaseShuttle 不再整块瞬移：中间位置一出现，「离散两态」这条就没了（D69）")

	var panel = load(PHASE_PANEL_SCENE).instantiate()
	panel.position = Vector2(9000.0, 9000.0)
	root.add_child(panel)
	var twin_panel = load(PHASE_PANEL_SCENE).instantiate()
	twin_panel.position = Vector2(9100.0, 9000.0)
	root.add_child(twin_panel)
	if panel.collision_layer != 4 or panel.collision_mask != 0:
		_fail("PhasePanel layer=%d mask=%d（应 4/0：玩家能踩、自己不去探任何东西）"
			% [panel.collision_layer, panel.collision_mask])
	if not panel.is_in_group(ANCHOR_GROUP) \
			or panel.get_node_or_null("TimeReceiver") == null:
		_fail("PhasePanel 不在 anchorable 族或缺 TimeReceiver：锚点射线打上去也吸不住（D69）")
	var base_col: CollisionShape2D = panel.get_node("BaseShape")
	var panel_col: CollisionShape2D = panel.get_node("PanelShape")
	if base_col.shape.size != Vector2(32.0, 16.0) or base_col.position != Vector2.ZERO:
		_fail("PhasePanel 底座 %s @ %s（默认应 32x16 @ (0,0)）"
			% [str(base_col.shape.size), str(base_col.position)])
	if base_col.disabled:
		_fail("PhasePanel 的底座被禁用了：桥面一虚，玩家站的地方就没了（D69 裁定 D1）")
	if panel_col.shape.size != Vector2(96.0, 16.0):
		_fail("PhasePanel 桥面 %s（默认应 96x16）" % str(panel_col.shape.size))
	if not is_equal_approx(base_col.position.y - base_col.shape.size.y * 0.5,
			panel_col.position.y - panel_col.shape.size.y * 0.5):
		_fail("PhasePanel 桥面上沿与底座上沿不齐：踩面会出现一级看不见的台阶")
	if not panel.is_on() or panel.is_blocked():
		_fail("PhasePanel 开局相位 0 应在开窗口里且未被占（is_on=%s is_blocked=%s）"
			% [str(panel.is_on()), str(panel.is_blocked())])

	# 相位映射与"底座永远实、只有桥面切"这两条，直接看两态。
	panel.phase = 1.0
	panel.set("_clock", 0.0)
	panel._refresh_state(panel.cycle_on())
	if panel.is_on() or not panel_col.disabled or base_col.disabled:
		_fail("PhasePanel 关窗口里桥面没退成虚体/底座跟着退了（is_on=%s panel_disabled=%s base_disabled=%s）"
			% [str(panel.is_on()), str(panel_col.disabled), str(base_col.disabled)])
	panel.phase = 0.0
	panel._refresh_state(panel.cycle_on())
	if not panel.is_on() or panel_col.disabled or base_col.disabled:
		_fail("PhasePanel 回开窗口时桥面没变实/底座被牵连（is_on=%s panel_disabled=%s base_disabled=%s）"
			% [str(panel.is_on()), str(panel_col.disabled), str(base_col.disabled)])
	panel.period = 2.0
	panel.duty = 0.5
	panel.phase = 0.0
	var phase_ok := true
	for sample in [[0.5, true], [1.5, false], [2.5, true]]:
		panel.set("_clock", sample[0])
		if panel.cycle_on() != sample[1]:
			phase_ok = false
	if not phase_ok:
		_fail("PhasePanel 的 cycle_on() 映射不对（period 2 / duty 0.5：0.5 开、1.5 关、2.5 开）")
	panel.panel_size = Vector2(64.0, 24.0)
	var twin_panel_col: CollisionShape2D = twin_panel.get_node("PanelShape")
	if panel_col.shape.size != Vector2(64.0, 24.0):
		_fail("PhasePanel 改 panel_size 后桥面盒没重算：%s" % str(panel_col.shape.size))
	if twin_panel_col.shape.size != Vector2(96.0, 16.0):
		_fail("改一块面板的 panel_size 波及另一块：%s（应还是 96x16，两块共用了同一份形状资源）"
			% str(twin_panel_col.shape.size))

	var shuttle = load(PHASE_SHUTTLE_SCENE).instantiate()
	shuttle.position = Vector2(9000.0, 8000.0)
	root.add_child(shuttle)
	var twin_shuttle = load(PHASE_SHUTTLE_SCENE).instantiate()
	twin_shuttle.position = Vector2(9100.0, 8000.0)
	root.add_child(twin_shuttle)
	if shuttle.collision_layer != 4 or shuttle.collision_mask != 0:
		_fail("PhaseShuttle layer=%d mask=%d（应 4/0）"
			% [shuttle.collision_layer, shuttle.collision_mask])
	if not shuttle.is_in_group(ANCHOR_GROUP) \
			or shuttle.get_node_or_null("TimeReceiver") == null:
		_fail("PhaseShuttle 不在 anchorable 族或缺 TimeReceiver（D69）")
	var step_col: CollisionShape2D = shuttle.get_node("StepShape")
	if step_col.shape.size != Vector2(48.0, 16.0) or step_col.position != Vector2.ZERO:
		_fail("PhaseShuttle 踏板盒 %s @ %s（默认应 48x16 @ (0,0)）"
			% [str(step_col.shape.size), str(step_col.position)])
	if step_col.disabled:
		_fail("PhaseShuttle 的踏板被禁用了：两个停靠点之间没有实体可站（D69）")
	if not shuttle.is_on() or shuttle.is_blocked():
		_fail("PhaseShuttle 开局应停在 A 点且未被占（is_on=%s is_blocked=%s）"
			% [str(shuttle.is_on()), str(shuttle.is_blocked())])
	if shuttle.global_position != Vector2(9000.0, 8000.0):
		_fail("PhaseShuttle 开局不在摆下去那一点：%s（应 (9000,8000)）"
			% str(shuttle.global_position))

	shuttle.phase = 1.0
	shuttle.set("_clock", 0.0)
	shuttle._refresh_state(shuttle.cycle_on())
	if shuttle.is_on() or step_col.disabled \
			or shuttle.global_position != Vector2(9000.0, 7936.0):
		_fail("PhaseShuttle 关窗口里没瞬移到 B 点：is_on=%s pos=%s（应 (9000,7936)）"
			% [str(shuttle.is_on()), str(shuttle.global_position)])
	shuttle.phase = 0.0
	shuttle._refresh_state(shuttle.cycle_on())
	if not shuttle.is_on() or shuttle.global_position != Vector2(9000.0, 8000.0):
		_fail("PhaseShuttle 回开窗口时没回 A 点：pos=%s（应 (9000,8000)）"
			% str(shuttle.global_position))
	shuttle.offset = Vector2(64.0, 0.0)
	shuttle.phase = 1.0
	shuttle.set("_clock", 0.0)
	shuttle._refresh_state(shuttle.cycle_on())
	if shuttle.global_position != Vector2(9064.0, 8000.0):
		_fail("PhaseShuttle 改 offset 后 B 点没跟着走：pos=%s（应 (9064,8000)）"
			% str(shuttle.global_position))
	shuttle.step_size = Vector2(32.0, 16.0)
	var twin_step_col: CollisionShape2D = twin_shuttle.get_node("StepShape")
	if step_col.shape.size != Vector2(32.0, 16.0):
		_fail("PhaseShuttle 改 step_size 后踏板盒没重算：%s" % str(step_col.shape.size))
	if twin_step_col.shape.size != Vector2(48.0, 16.0):
		_fail("改一块穿梭块的 step_size 波及另一块：%s（应还是 48x16）"
			% str(twin_step_col.shape.size))

	for node in [panel, twin_panel, shuttle, twin_shuttle]:
		root.remove_child(node)
		node.free()


## D62 祭坛那次自动存档（用户裁定「只写重生位、不给灯」）。钉的全是"这一拍悄悄改名换姓"那三类：
## ① 祭坛不许加入存档点那一族 —— 不发 `checkpoint_reached`、不实现 claim/release。它一旦发了，
##    `LevelBase._bind_checkpoints()` 的全子树扫描会**自动**把它算成一台存档点，"不给灯"这条裁定
##    就在没人改存档点代码的情况下被推翻，而且画面不会响（行为不同就拆场景，一个给能力一个记重生位）；
## ② `respawn_position` 必须有两处书写（存档点 + 祭坛）。这条是 D51 那笔账的正身：
##    `respawn_marker` 当初就是"有读、没人写"绿了好几轮；
## ③ 释放只许一个书写者：`call(&"release")` 在 LevelBase 里出现两次，就意味着"谁亮着"这件事实
##    有两个人在管 —— 那条不变量（全关卡只一台亮）会从这里开始漏。
func _verify_altar_save() -> void:
	var altar := FileAccess.get_file_as_string(ALTAR_SCRIPT)
	if altar.contains("checkpoint_reached"):
		_fail("AbilityAltar 发出了 checkpoint_reached：D62 裁定「不给灯」，它一发这条就会被 " +
			"_bind_checkpoints 自动算成一台存档点，重生位与灯两件事悄悄合到了同一个构件上")
	if altar.contains("func claim") or altar.contains("func release"):
		_fail("AbilityAltar 长出了 claim/release：同上，它不是存档点那一族（D62）")
	var base := FileAccess.get_file_as_string(LEVEL_BASE_SCRIPT)
	var writes := base.count("state[\"respawn_position\"] = ")
	if writes != 2:
		_fail("run_state 的 respawn_position 书写点 = %d（应为 2：存档点 + 祭坛那一发，D62）" % writes)
	if not base.contains("erase(\"respawn_marker\")"):
		_fail("祭坛那一发没抹掉 respawn_marker：留着旧路径 = 下次重载点亮一台已经不成立的存档点")
	var releases := base.count("call(&\"release\")")
	if releases != 1:
		_fail("release 的调用点 = %d（应为 1）：谁亮着这件事实只能有一个书写者（D51/D62）" % releases)


## D68 时间锚点。静态这一遍钉的全是"改了不响、要到实机才露馅"那五类：
## ① 时间源只能有一条式子：`set_time_source` / `clear_time_source` 各恰好一处。
##    多一处书写点，就会出现"这条路径吸上了、那条路径没撒手"的半截链接；
## ② 那条式子不许读世界钟/全局缩放/存档 —— D66① 的锚点物跟的是玩家的手，
##    写成 `elapsed_world_time` 会看起来也在动，但世界一冻它就停，整条机制反了；
## ③ 四个闸缺一不可（活着 / 没被移动锁掐 / 锚点能力已开 / 手上在动），少一条就是
##    "某种状态下它会自己走/自己停"，而画面不会报错；第三条自 D73 起读的是独立旗标；
## ④ 回执是 `_wound` 的纯函数且绝不回头喂时间源：没有 `_process`（照帧率卷），
##    `_pump_enabled()` 的函数体里不出现 `_wound`；调色板与世界钟同一批在册色；
## ⑤ 锚点族：移动方块真在组里、每一员都是实体（layer 1|4）、挂 TimeReceiver、
##    不是危险物；扫不到任何一员就是空转，必须响。玩家只造一根锚，anchor 键真有 Q + 左键。
## 行为那半边（吸附/供时/松手即停/强回收/回程穿墙/死亡断链）归 kit_selftest 第 22 组。
func _verify_time_anchor() -> void:
	var src := FileAccess.get_file_as_string(TIME_ANCHOR_SCRIPT)
	if src.is_empty():
		_fail("读不到 %s" % TIME_ANCHOR_SCRIPT)
		return
	var sets := src.count("_receiver.set_time_source(")
	var clears := src.count("_receiver.clear_time_source(")
	if sets != 1:
		_fail("时间锚点里 set_time_source 出现 %d 次（应恰好 1：接手只能有一个书写点，D68）" % sets)
	if clears != 1:
		_fail("时间锚点里 clear_time_source 出现 %d 次（应恰好 1：断链只能有一个书写点，D68）" % clears)
	for banned in ["elapsed_world_time", "TimeManager.get_physics_delta",
			"TimeManager.get_process_delta", "Engine.time_scale", "run_state", "func _process("]:
		if src.contains(banned):
			_fail("时间锚点里出现了 %s：D66① 的时间源只认玩家的动作，不认世界钟/全局缩放/存档（D68）"
				% banned)
	for gate in ["source.is_dead", "source.movement_locked", "TimeManager.is_anchor_enabled",
			"source.input_handler.is_moving"]:
		if not src.contains(gate):
			_fail("时间源的闸缺了 %s：四条缺一条，锚点物就会在某种状态下自己走/自己停（D68）" % gate)
	# D73：锚点是**独立一项能力**，它读的那道闸不许再回读冻结那一项 ——
	# 两处读同一个旗标时"分离"这件事就静默地没了，而画面不会报错（行为那半边归第 22 组）。
	if src.contains("TimeManager.is_ability_enabled"):
		_fail("时间锚点里回读了 TimeManager.is_ability_enabled：锚点的能力闸自 D73 起是独立旗标 "
			+ "is_anchor_enabled，读回去等于把两项能力重新焊成一件事")
	if not FileAccess.get_file_as_string("res://scenes/levels/level_base.gd") \
			.contains("TimeManager.set_anchor_enabled(start_with_anchor)"):
		_fail("关卡根没把 start_with_anchor 写进 TimeManager.set_anchor_enabled()：那一项能力从此没有书写者，"
			+ "勾了导出项也没人开门（D73）")
	var pump_start := src.find("func _pump_enabled")
	var pump_end := src.find("func ", pump_start + 1) if pump_start >= 0 else -1
	if pump_start < 0 or pump_end < 0:
		_fail("找不到 _pump_enabled() 的函数体，回执纯度这一条没法验（D68）")
	elif src.substr(pump_start, pump_end - pump_start).contains("_wound"):
		_fail("_pump_enabled() 读了 _wound：回执反过来喂时间源，纯装饰那条契约没了（D68）")
	for color in ["WorldClock.COL_LIT", "WorldClock.COL_TRAIL_1", "WorldClock.COL_TRAIL_2",
			"WorldClock.COL_UNLIT", "WorldClock.COL_SCREEN", "WorldClock.COL_EDGE"]:
		if not src.contains(color):
			_fail("回执没取 %s：D68 定的是 D59 世界钟那套在册色，不许另起一份" % color)
	var anchor_cs: Dictionary = (load(TIME_ANCHOR_SCRIPT) as GDScript).get_script_constant_map()
	var clock_cs: Dictionary = (load(CLOCK_SCRIPT) as GDScript).get_script_constant_map()
	if int(anchor_cs.get("RECEIPT_TICKS", -1)) != int(clock_cs.get("TICKS", -2)):
		_fail("回执格数 %s 与世界钟 TICKS %s 不是同一只表：两处各写一份就会悄悄分家"
			% [str(anchor_cs.get("RECEIPT_TICKS")), str(clock_cs.get("TICKS"))])

	var player_src := FileAccess.get_file_as_string("res://scenes/actors/player/player.gd")
	if player_src.count("TimeAnchor.new()") != 1:
		_fail("Player 造了 %d 根时间锚（应恰好 1：一次只有一根锚，D68）"
			% player_src.count("TimeAnchor.new()"))
	if not player_src.contains("_time_anchor.name = \"TimeAnchor\""):
		_fail("Player 造的锚没固定名字：关卡/调试按名字找它时会落空")
	if not player_src.contains("_time_anchor.cancel_for_death()"):
		_fail("Player.die() 没有 cancel_for_death()：被锚着的构件会拖着一根指向尸体的 Callable（D68）")
	if not player_src.contains("_time_anchor.reset_state()"):
		_fail("Player.respawn() 没有 reset_state()：上一具身体的链接会跨到复活后的锚上（D68）")

	if not InputMap.has_action(&"anchor"):
		_fail("InputMap 缺 anchor 动作：锚点发不出去（D68）")
	else:
		var has_q := false
		var has_lmb := false
		for event in InputMap.action_get_events(&"anchor"):
			if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_Q:
				has_q = true
			if event is InputEventMouseButton \
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				has_lmb = true
		if not has_q:
			_fail("anchor 动作没绑 Q：D68 的发射键是 Q")
		if not has_lmb:
			_fail("anchor 动作没绑鼠标左键：D68 允许按住左键瞄准/松开发射")

	var moving_ok := false
	var panel_ok := false
	var shuttle_ok := false
	for path in _discover_object_scenes():
		var packed := load(path) as PackedScene
		if packed == null:
			continue
		var node = packed.instantiate()
		if node == null:
			continue
		if node.is_in_group(ANCHOR_GROUP):
			_anchorables_checked += 1
			_check_anchorable(node, path)
			if path == MOVING_BLOCK_SCENE:
				moving_ok = true
			if path == PHASE_PANEL_SCENE:
				panel_ok = true
			if path == PHASE_SHUTTLE_SCENE:
				shuttle_ok = true
		node.free()
	if not moving_ok:
		_fail("移动方块没进 anchorable 组：D68 第一个可锚物件不在族里，本组等于没测")
	if not panel_ok:
		_fail("相位面板没进 anchorable 组：D69 的两件新器件缺了一件")
	if not shuttle_ok:
		_fail("相位穿梭块没进 anchorable 组：D69 的两件新器件缺了一件")
	if _anchorables_checked < 3:
		_fail("只扫到 %d 个 anchorable（移动方块 + 相位面板 + 相位穿梭块至少 3 个）："
			% _anchorables_checked + "族扫描漏了谁")
	if _anchorables_checked < 1:
		_fail("一个 anchorable 都没扫到：族扫描在空转，后面的契约检查都没发生")


func _check_anchorable(node: Node, path: String) -> void:
	if not (node is CollisionObject2D):
		_fail("%s 在 anchorable 组里但不是实体：锚点射线永远打不到它" % path)
		return
	var layer := (node as CollisionObject2D).collision_layer
	if (layer & (1 | 4)) == 0:
		_fail("%s 在 anchorable 组里却不在 terrain(1)/time_solid(4) 层（layer=%d）：射线打不到"
			% [path, layer])
	if node.get_node_or_null("TimeReceiver") == null:
		_fail("%s 在 anchorable 组里却没有 TimeReceiver 子节点：吸上去也没有时间源可劫（D68）" % path)
	if node.has_signal("touched_player"):
		_fail("%s 在 anchorable 组里却发 touched_player：D66② 锚点物不许是危险物" % path)
	var script: Script = node.get_script()
	var guard := 0
	while script != null and guard < 8:
		if script.resource_path == HAZARD_BASE_SCRIPT:
			_fail("%s 在 anchorable 组里却继承 HazardBase：D66② 锚点物不许是危险物" % path)
			break
		script = script.get_base_script()
		guard += 1


## 扫 scenes/objects 整棵子树来找锚点族。新构件挂了 anchorable 就自动进守门，
## 不用回来往白名单里加一行 —— 与关卡自动发现同一条理由。
func _discover_object_scenes() -> PackedStringArray:
	var found := PackedStringArray()
	var pending: Array = ["res://scenes/objects"]
	while not pending.is_empty():
		var dir = pending.pop_back() as String
		var da := DirAccess.open(dir)
		if da == null:
			_fail("打不开目录 %s" % dir)
			continue
		for sub in da.get_directories():
			pending.append(dir.path_join(sub))
		for file in da.get_files():
			if file.ends_with(".tscn"):
				found.append(dir.path_join(file))
	found.sort()
	return found


func _clum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _count_areas(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is Area2D:
			total += 1
		total += _count_areas(child)
	return total


## 喷嘴建的那池挡路格（运行期 add_child，按创建序 = 链上的 k 序）。TimeReceiver 也是子节点，
## 所以按类型挑，不写死路径。
func _pool_bodies(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is StaticBody2D:
			out.append(child)
	return out


## 一格身上的碰撞盒。按类型捞，不写死路径：这一池是运行期 add_child 建的，
## 名字改一个字就变成"硬报错、后面整段静默跳过、failures 还是 0"的假绿。
func _body_rect(body: Node) -> RectangleShape2D:
	for child in body.get_children():
		if child is CollisionShape2D:
			return (child as CollisionShape2D).shape as RectangleShape2D
	return null


func _collect_rects(node: Node) -> Array:
	var out: Array = []
	for body in _pool_bodies(node):
		var rect := _body_rect(body)
		if rect != null:
			out.append(rect)
	return out


## 危险物（与 KeyDoor 的查询 Reader）共用层值：layer 0（绝不上 sensor 层 —— 玩家的
## 头顶净空查询会把上了 sensor 层的通电棒读成「头顶是空的」，D29/D27 交叉核对的硬约束）
## + mask 2（只认玩家）+ 不可被探测。传感器族（拾取带/存档带）则住 sensor 层 8。
func _check_area_layers(area: Area2D, label: String, want_layer: int) -> void:
	if area.collision_layer != want_layer or area.collision_mask != 2 or area.monitorable:
		_fail("%s 层契约破了：layer=%d mask=%d monitorable=%s（应 %d/2/false）"
			% [label, area.collision_layer, area.collision_mask, str(area.monitorable), want_layer])


## 关卡实例里的危险物层契约。发现判据与 LevelBase._bind_hazards 同一个信号名 ——
## 关卡里摆的每个危险物在这里按同一套规则再过一遍。
## 只查 Area2D：AfterimageEmitter 也发 `touched_player`（D48 判死），但它是 Node2D +
## 几何判定，压根没有 Area2D 可供查层。把形参写成 Area2D 会让这一句在传它时硬报错，
## 而硬报错 = 后面整段静默跳过、failures 照样是 0（那个假绿已记在手册 §10）。
func _check_level_hazards(node: Node, path: String) -> void:
	if node.has_signal("touched_player") and node is Area2D:
		_check_area_layers(node as Area2D, "%s/%s" % [path, str(node.name)], 0)
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


## 关卡里摆好的假墙盖（D76）：无头扫的是"摆上去到底盖不盖得住"那几件事 ——
## 压在墙下面（z）、会撞人（碰撞开关）、刷错瓦片（逐格核），以及跟这关的墙面不是同一份
## 图集（换风格后会盖出另一种砖，不报错、只是在接缝处露馅）。
## 没有关卡摆过时只记账不设门槛：哪一关需要暗室是摆图的决定，不是每关都必须有。
func _check_cave_covers(root: Node, path: String) -> void:
	var by_path := {}
	_collect_paths(root, "", by_path)
	var wall := root.get_node_or_null("Terrain/Tiles") as TileMapLayer
	for node_path in by_path:
		var node: Node = by_path[node_path]
		var script: Script = node.get_script()
		if script == null or script.resource_path != CAVE_COVER_SCRIPT:
			continue
		_covers_checked += 1
		var label := "%s 的 %s" % [path, node_path]
		if node.z_index <= 0:
			_fail("%s z_index=%d：压在 z=0 的墙、玩家与屋里摆的东西下面，盖不住任何东西（D76）"
				% [label, node.z_index])
		if node.collision_enabled:
			_fail("%s 开着碰撞：它画的是带碰撞多边形的实心格，玩家会撞在看不见的墙上（D76）" % label)
		for problem in _cover_cell_problems(node):
			_fail("%s %s（D76）" % [label, problem])
		if wall != null and node.tile_set != wall.tile_set:
			_fail("%s 的 tile_set 与 %s 的 Terrain/Tiles 不是同一份：换风格后会盖出另一种砖（D76）"
				% [label, path])


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
	# M5（D36 第 6/7 条）：光幕那几色与门楣底座各自同源 —— LED 锁色 = 钥匙卡同色是语义不是巧合。
	# D53 起拒绝态那一对也进这张表：它是全项目唯一不从调色板推导的构件色，更容易单独漂走。
	var kc: Dictionary = (load(KEYDOOR_SCRIPT) as GDScript).get_script_constant_map()
	_check_color("KeyDoor.LED_SOCKET", kc["LED_SOCKET"], m["led_socket"])
	_check_color("KeyDoor.LED_LOCKED", kc["LED_LOCKED"], m["gate_led_locked"])
	_check_color("KeyDoor.LED_LIT", kc["LED_LIT"], m["gate_led_lit"])
	_check_color("KeyDoor.LED_DENIED", kc["LED_DENIED"], m["gate_led_denied"])
	_check_color("KeyDoor.LED_DENIED_SOCKET", kc["LED_DENIED_SOCKET"], m["gate_led_denied_socket"])
	_check_color("KeyDoor.CURTAIN", kc["CURTAIN"], m["gate_curtain"])
	# D44：祭坛那串青色从此有清单可对。旧版它写死在构件里、从来不在 props.json 上，
	# 于是风格换了它不换 —— 这条比对就是为了让"游离的构件色"没法再复发。
	var ac: Dictionary = (load(ALTAR_SCRIPT) as GDScript).get_script_constant_map()
	_check_color("AbilityAltar.CORE_COLOR", ac["CORE_COLOR"], m["altar_core"])
	var shaft := _img("altar_shaft")
	if shaft != null and _lum(shaft, 8, 8) >= _lum(shaft, 8, 3):
		_fail("altar_shaft 缝行不比常规行暗：石台平铺会出亮带（同 door_slat 那条）")
	var cap := _img("altar_cap")
	if cap != null and _lum(cap, 8, 0) <= _lum(cap, 8, 4):
		_fail("altar_cap 顶行不比身部亮：石帽读不出被照亮")
	var core := _img("altar_core")
	if core != null:
		# 取 (14,12) 那枚菱形本体，避开中心那道高光亮条 —— 亮条是近白的，判不出色相。
		var cc := core.get_pixel(14, 12)
		if not (cc.b > 0.7 and cc.g > 0.7 and cc.r < 0.7):
			_fail("altar_core 菱形不是青色: %s" % str(cc))
	# D45：已存态比未存态**宽一档也高一档** —— 这条反馈整个读法都压在多出来的尺寸上
	# （顶灯 +15 px、地面两侧各 6 px 青边）。谁把两张零件统一成一个尺寸，这里当场响。
	var idle := _img("terminal_idle")
	var saved := _img("terminal_saved")
	if idle != null and saved != null:
		if saved.get_width() <= idle.get_width() or saved.get_height() <= idle.get_height():
			_fail("terminal_saved 没比 terminal_idle 大一档，D45 的常读状态被裁掉了: %s vs %s"
				% [str(saved.get_size()), str(idle.get_size())])
		var lamp := saved.get_pixel(21, 2)
		if not (lamp.b > 0.8 and lamp.g > 0.8):
			_fail("terminal_saved 顶灯不亮，已存态读不出多出来那一档: %s" % str(lamp))


## D54 彩蛋收集物（小黄鸭转台）。静态这一遍钉五件事，全属"改了不响、要到试玩才露馅"那类：
## ① 契约三件套在场（发 `collectible_taken` + 认 `mark_taken()`）—— 改名会让 LevelBase
##    的全子树扫描静默捞不到它，彩蛋变成"拿了不记、死一次复生"，而且一声不吭；
## ② 转角只能走门控 delta：脚本里不许出现 `_process`，且必须真的读 `_receiver.get_physics_delta()`
##    —— 这条就是用户批的"冻结时也暂停"，写成源码形状的检查比跑一帧更便宜也不会漏；
## ③ 拾取带 == 贴图外接框外扩 `PICKUP_MARGIN`，尺寸**从零件纹理现算**，不在断言里抄第二份数。
##    带子的期望值里没有姿态这一项，正是裁定③"转扁了也不许捡不到"的那声响；
## ④ 三视图同尺寸、且五张零件都在 props.json 清单上（构件私自 preload 一张没登记的图 = 换风格时没人提醒）；
## ⑤ 像素契约：空座顶面那道压痕必须比座面暗（否则"拿走了"读不出来，D54 裁定⑤全靠它）、
##    正脸与背面不能是同一张图（否则"转过去了"读不出来）、每只视图底边必须有像素（否则鸭子悬在座子上方）、
##    本体必须是琥珀那一档（D29：可拾取 = 琥珀；青是"光与电/能力"，染青就成了一次能力演出）。
func _verify_collectible() -> void:
	var src := FileAccess.get_file_as_string(COLLECTIBLE_SCRIPT)
	if src.contains("func _process("):
		_fail("Collectible 里出现了 _process：转角只能走门控 delta，照帧率走会变成冻结里它还在转（D54）")
	if not src.contains("_receiver.get_physics_delta()"):
		_fail("Collectible 没读 _receiver.get_physics_delta()：那只鸭子不跟世界一起停（D54）")
	var f := FileAccess.open("res://assets/props/props.json", FileAccess.READ)
	if f == null:
		_fail("props.json 不在，彩蛋的零件同源无从核对")
		return
	var parts: Dictionary = (JSON.parse_string(f.get_as_text()) as Dictionary)["parts"]

	var cs: Dictionary = (load(COLLECTIBLE_SCRIPT) as GDScript).get_script_constant_map()
	var margin: float = cs["PICKUP_MARGIN"]
	var view_names := ["duck_front", "duck_side", "duck_back"]
	var views: Array[Image] = []
	for i in view_names.size():
		var tex: Texture2D = cs["TEX_%s" % view_names[i].to_upper()]
		if tex == null or tex.resource_path != "res://assets/props/%s.png" % view_names[i]:
			_fail("Collectible 的 TEX_%s 常量不指向 %s.png" % [view_names[i].to_upper(), view_names[i]])
			continue
		if not parts.has(view_names[i]):
			_fail("%s 不在 props.json 清单上（换风格时没人会提醒你它存在）" % view_names[i])
		var img := _img(view_names[i])
		if img == null:
			return
		views.append(img)
	if views.size() != view_names.size():
		return
	for v in range(1, views.size()):
		if views[v].get_size() != views[0].get_size():
			_fail("三视图尺寸不一致（%s vs %s）：换视图那一帧鸭子会在底座上跳"
				% [str(views[0].get_size()), str(views[v].get_size())])
	var front: Image = views[0]
	var back: Image = views[2]
	if _bits(front) == _bits(back):
		_fail("duck_front 与 duck_back 是同一张图：转到背面去读不出「转过去了」")
	for img in views:
		var feet := 0
		for x in img.get_width():
			if img.get_pixel(x, img.get_height() - 1).a > 0.5:
				feet += 1
		if feet == 0:
			_fail("有张鸭视图的底边一个像素都没有：它会悬在底座上方，读不出「坐在上面」")
	# 正脸身体那一档（选型时量过的落盘点）：琥珀 = 可拾取（D29）。
	var body := front.get_pixel(0, 7)
	if not (body.r > 0.9 and body.g > 0.6 and body.g < 0.85 and body.b < 0.4):
		_fail("duck_front 本体不是琥珀那一档: %s" % str(body))

	var idle := _img("perch_idle")
	var taken := _img("perch_taken")
	if idle == null or taken == null:
		return
	if _bits(taken) == _bits(idle):
		_fail("perch_taken 与 perch_idle 一模一样：拿走了没有收据（D54 裁定⑤ 留空座）")
	if _lum(taken, 6, 1) >= _lum(idle, 6, 1):
		_fail("空座顶面那道压痕不比座面亮行暗：留空座读不出「这里有过一只」")

	var col = _enter("res://scenes/objects/collectible/collectible.tscn")
	_check_area_layers(col, "Collectible", 8)
	if not col.has_signal("collectible_taken") or not col.has_method("mark_taken"):
		_fail("Collectible 缺 collectible_taken 或 mark_taken，LevelBase 的粘性清单接不上（D54）")
	var shape: CollisionShape2D = col.get_node("CollisionShape2D")
	var sprite_h := float(front.get_height() + idle.get_height())
	var want := Vector2(float(idle.get_width()) + margin * 2.0, sprite_h + margin * 2.0)
	if shape.shape.size != want:
		_fail("Collectible 拾取带 %s（应 = 外接框 + 边距 %s = %s）"
			% [str(shape.shape.size), str(margin), str(want)])
	if shape.position != Vector2(0.0, -sprite_h * 0.5):
		_fail("Collectible 拾取带心 %s（应贴着外接框中心 (0,%s)，与原点的底边中心约定同一套）"
			% [str(shape.position), str(-sprite_h * 0.5)])
	root.remove_child(col)
	col.free()


## 逐位比两张零件是不是同一张图。`get_data_for_mip()` 在 4.6 的 Image 上没有，
## 编码成 PNG 字节再比既准又不用自己写双层循环。
func _bits(img: Image) -> PackedByteArray:
	return img.save_png_to_buffer()


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


## D65：分组容器必须停在 (0,0)。全-kit 的坐标契约都写成「节点原点 = 贴着地面那一点」，
## 摆图时的读数参照物是地格线；容器一带 position，它下面整块构件被平移，
## 编辑器里看着压住 y=0 的按钮运行时其实沉在别处 —— 这种偏差在编辑器里根本看不出来，
## 而用来核对摆位的读数已经不可信了，所以只能由守门来响。
## 认「无脚本、还挂着东西的 Node2D」：组件实例都挂脚本，族文件夹是 type="Node"
## （结构上就没有 position），Marker2D 那样的落点是空的，所以这条只命中真正在分组的那几个容器。
func _check_group_containers(root: Node, path: String) -> void:
	var by_path := {}
	_collect_paths(root, "", by_path)
	for node_path in by_path:
		var node: Node = by_path[node_path]
		if node.get_script() != null or node.get_child_count() == 0 or not (node is Node2D):
			continue
		var pos: Vector2 = (node as Node2D).position
		if pos != Vector2.ZERO:
			_fail("%s 的分组容器 %s 带位移 %s（容器该停在 (0,0)，否则它下面所有构件一起平移）"
				% [path, node_path, str(pos)])


func _count_by_script(node: Node, target: String) -> int:
	var total := 0
	var script: Script = node.get_script()
	if script != null and script.resource_path == target:
		total += 1
	for child in node.get_children():
		total += _count_by_script(child, target)
	return total


## trigger 接线（门 D21 / 活塞踏板 D49 共用）：构件不吃关卡脚本，只吃场景里这条路径。
## 所以漏配 / 配了个不发信号的节点，必须在无头守门里就炸出来，不能等试玩时"门怎么不开"。
## 判据是信号名不是类型，与构件内部同一口径。
## 与"一卡一门"那条**相反**：这里刻意允许多个构件指同一个触发源 —— 那正是"一组活塞"的写法，
## 查重会把 D49 直接判死，所以这条扫描只查"接没接上"，不查"接了几家"。
## D60 起活塞那一头是**一列**（`triggers`，多台 OR），门还是单值（`trigger`）：两种形状走同一条
## 判据，逐个查"解析得动 + 发 pressed_changed"。整列留空仍算漏接头，与旧的单值同一条口径。
## 刻意不走 get_node：实测未进树的实例里 `get_node("Objects/Door")` 这种两段路径会返回
## null（同层单段却正常），所以自己把 path→node 收成字典，用同一套拼法查。
func _check_trigger_wiring(root: Node, path: String, kit_script: String, label: String,
		prop: String) -> int:
	var by_path := {}
	_collect_paths(root, "", by_path)
	var checked := 0
	for node_path in by_path:
		var node: Node = by_path[node_path]
		var script: Script = node.get_script()
		if script == null or script.resource_path != kit_script:
			continue
		checked += 1
		var raw: Variant = node.get(prop)
		var listed: Array = raw if raw is Array else [raw]
		if listed.is_empty():
			_fail("%s %s 的 %s 是空的" % [label, node_path, prop])
		for rel in listed:
			var target := _fold_rel_path(node_path, rel)
			if target == "":
				_fail("%s %s 的 %s 里有一格是空的（编辑器里画不出线、运行时也不参与合成）"
					% [label, node_path, prop])
			elif not by_path.has(target):
				_fail("%s %s 的 %s 指向不存在的节点 %s" % [label, node_path, prop, target])
			elif not by_path[target].has_signal("pressed_changed"):
				_fail("%s %s 的 %s %s 不发 pressed_changed" % [label, node_path, prop, target])
	return checked


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


## 冻结时压掉 BGM 高频（D79）。这条链上全是"写歪了不报错"的接缝，逐段钉：
## ① 时基 —— 拿世界 delta 做斜坡，冻结那一拍斜坡就永远停在起点（声音一点没闷），无头全绿；
## ② 路由 —— 给一个还不存在的总线名赋值会**静默回退成 Master**，不报错也不警告，
##    于是 BGM 照样在放、滤镜一点没生效，而任何地方都不响；
## ③ autoload 顺序 —— AudioDirector 排在 Musicplayer 前面，它 `_ready` 时那个节点还不存在；
## ④ `--script` 模式下 autoload 标识符编译不过（同 level_base 那条坑），所以脚本体只许走 /root 路径。
## 行为那半边（冻结时真的往下爬、不是硬切、解冻回开放档）归 kit_selftest 第 28 组。
func _verify_audio() -> void:
	var src := _code_only(FileAccess.get_file_as_string(AUDIO_DIRECTOR_SCRIPT))
	if src.is_empty():
		_fail("读不到 %s" % AUDIO_DIRECTOR_SCRIPT)
		return
	for banned in ["elapsed_world_time", "get_physics_delta", "get_process_delta", "Engine.time_scale"]:
		if src.contains(banned):
			_fail("AudioDirector 里出现了 %s：斜坡必须吃真实时间 —— 世界时间在冻结时是 0，" % banned +
				"斜坡会停在起点，声音一点没闷而无头全绿（D79）")
	for banned in ["TimeManager.", "Musicplayer."]:
		if src.contains(banned):
			_fail("AudioDirector 里出现了 %s：--script 模式下 autoload 标识符编译不过，" % banned +
				"而 verify_kit 就是 --script 跑的，只能走 /root 路径（D79）")
	if not src.contains("\"/root/TimeManager\""):
		_fail("AudioDirector 没走 /root/TimeManager 取节点：它读不到冻结状态，低通永远停在开放档（D79）")
	if not src.contains("\"/root/Musicplayer\""):
		_fail("AudioDirector 没走 /root/Musicplayer 取节点：没有人把 BGM 送到 Music 总线上（D79）")
	if not src.contains("func _process("):
		_fail("AudioDirector 没有 _process：斜坡没有地方落地 —— 冻结期间它必须照样往前爬（D79）")

	var project := FileAccess.get_file_as_string("res://project.godot")
	var music_at := project.find("Musicplayer=\"*uid://")
	var audio_at := project.find("AudioDirector=\"*res://autoloads/audio_director.gd\"")
	if audio_at < 0:
		_fail("project.godot 里没有 AudioDirector 这条 autoload：整条低通不进进程（D79）")
	elif music_at < 0:
		_fail("project.godot 里找不到 Musicplayer 那条 autoload：下面那条顺序判据没法验（D79）")
	elif audio_at < music_at:
		_fail("AudioDirector 排在 Musicplayer 前面：它 _ready 时 /root/Musicplayer 还不存在，" +
			"路由那一行静默落空（D79）")

	# 下面这几条读的是**启动之后**的真实状态：无头下 AudioServer 照样有总线表，
	# 所以"建没建、挂没挂、路由到没到"这三件事不用开窗也量得到。
	var bus := AudioServer.get_bus_index("Music")
	if bus < 0:
		_fail("启动之后没有 Music 总线：AudioDirector 建总线那一段没走到 —— 而 BGM 照样在放、" +
			"没有任何报错，这是最坏的一种绿（D79）")
		return
	if AudioServer.get_bus_effect_count(bus) < 1 \
			or not (AudioServer.get_bus_effect(bus, 0) is AudioEffectLowPassFilter):
		_fail("Music 总线上第一条不是低通：整条效果等于不存在（D79）")
	var player := root.get_node_or_null("/root/Musicplayer") as AudioStreamPlayer
	if player == null:
		_fail("拿不到 /root/Musicplayer：路由那一半没法验（D79）")
	elif player.bus != "Music":
		_fail("Musicplayer 读回来挂在 %s 上（应为 Music）：总线不存在时赋名会静默回退 Master，" % str(player.bus) +
			"声音照样放、滤镜一点没生效，而任何地方都不报错（D79）")
