extends Node
## 无头回归自测：只盯这次打包改动碰过的五条路径，不替代玩家的试玩。
##
## 1) 门的时间仍然只从 TimeReceiver 的门控 delta 累计 —— 冻结期间 `_progress` 一字不动；
## 2) `_apply()` 新加的"只在值变了才写"比较不能把该写的赋值挡掉（全开时碰撞体必须收零）；
## 3) MovingBlock 换成 travel_offset 之后，行程仍然锁在 [anchor, anchor+offset] 区间内；
## 4) 门的 trigger 接线：按下即开、冻结中松开只记意图不位移、解冻后续收、换源断旧连接；
## 5) 关门压到玩家头顶时停在头顶：不越界、不把人挤开、人让开后照常收严。
##
## 跑法：Godot --headless --path <项目根> res://tools/kit_selftest.tscn

const TAG := "[kit-selftest]"
const BLOCK_ANCHOR := Vector2(500, -200)

var _fails: int = 0


func _ready() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)

	var door := load("res://scenes/objects/door/door.tscn").instantiate() as Door
	add_child(door)
	var block := load("res://scenes/objects/moving_block/moving_block.tscn").instantiate() as MovingBlock
	block.position = BLOCK_ANCHOR
	block.travel_offset = Vector2(0, -72)
	add_child(block)

	var receiver: TimeReceiver = door.get_node("TimeReceiver") as TimeReceiver
	await _frame()
	_check("门初始关严", door._progress == 0.0)
	_check("无输入时时间正常流动", receiver.get_physics_delta() > 0.0)

	door.set_open(true)
	await _frame(6)
	var partial: float = door._progress
	_check("流动的时间里门在开", partial > 0.0 and partial < 1.0)

	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("有移动意图即冻结", receiver.is_time_frozen())
	var block_at_freeze: Vector2 = block.global_position
	await _frame(20)
	_check("冻结期间门开度不动", door._progress == partial)
	_check("冻结期间方块不位移", block.global_position == block_at_freeze)
	_check("冻结被方块计数", block.frozen_frames > 0)

	TimeManager.notify_movement_intent(false)
	await _frame(20)
	_check("解冻后门继续走（不是从头开）", door._progress > partial)
	await _frame(90)
	_check("门能走完全程", door._progress == 1.0)
	var door_collision = door.get_node("CollisionShape2D")
	var rect := door_collision.shape as RectangleShape2D
	_check("全开时碰撞体收零", rect.size.y < 0.01)
	var sr: Rect2 = door.shutter_rect()
	_check("画出来的门扇与碰撞体同宽同高（同一截）",
		absf(sr.size.y - rect.size.y) < 0.01 and absf(sr.size.x - rect.size.x) < 0.01)

	block.elapsed_path_time = 0.0
	block.global_position = BLOCK_ANCHOR
	await _frame(30)
	_check("方块向上离开锚点", block.global_position.y < BLOCK_ANCHOR.y)
	_check("方块不越过行程终点", block.global_position.y > BLOCK_ANCHOR.y - 73.0)
	await _frame(120)
	_check("方块始终留在行程内", absf(block.global_position.y - BLOCK_ANCHOR.y) < 73.0)

	# —— 接线搬到门上：门自己吃触发源的 pressed_changed，关卡脚本不参与 ——
	# 相对路径是 .tscn 里实际存的写法（trigger = NodePath("../ButtonPlate")），照搬。
	var rig := Node2D.new()
	rig.name = "Rig"
	add_child(rig)
	var plate := load("res://scenes/objects/button_plate/button_plate.tscn").instantiate() as ButtonPlate
	plate.name = "Plate"
	var wired := load("res://scenes/objects/door/door.tscn").instantiate() as Door
	rig.add_child(plate)
	rig.add_child(wired)
	wired.trigger = NodePath("../Plate")
	await _frame()
	_check("门按相对路径解析到触发源", wired._bound == plate)
	plate._set_pressed(true)
	_check("按钮填上门的 trigger 就接通，按下即开门", wired.is_open)
	await _frame(6)
	_check("触发源驱动的门在流动时间里真的在开", wired._progress > 0.0 and wired._progress < 1.0)

	# 冻结中走出触发带（SensorZone 没有延迟松开）：意图翻成关，门只能原地停住。
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var frozen_at: float = wired._progress
	plate._set_pressed(false)
	_check("冻结中触发源松开，门只记下关闭意图", not wired.is_open)
	await _frame(20)
	_check("冻结中门不为松开让路", wired._progress == frozen_at)
	TimeManager.notify_movement_intent(false)
	await _frame(20)
	_check("解冻后门从停住处接着收", wired._progress < frozen_at)

	# 换触发源必须解掉旧连接：否则老按钮照样能开这扇门，而场景里已经看不出接在哪儿。
	var second := load("res://scenes/objects/button_plate/button_plate.tscn").instantiate() as ButtonPlate
	second.name = "Plate2"
	rig.add_child(second)
	wired.trigger = NodePath("../Plate2")
	await _frame()
	plate._set_pressed(true)
	_check("换 trigger 后旧按钮不再驱动门", not wired.is_open)
	second._set_pressed(true)
	_check("新按钮驱动同一扇门", wired.is_open)
	second._set_pressed(false)
	_check("新按钮松开后门转入关闭", not wired.is_open)

	# 契约判的是信号不是类型：区域触发带也接得上，这是本次真正新增的能力。
	var zone := load("res://scenes/objects/sensor_zone/sensor_zone.tscn").instantiate() as SensorZone
	zone.name = "Zone"
	rig.add_child(zone)
	wired.trigger = NodePath("../Zone")
	await _frame()
	zone._set_pressed(true)
	_check("SensorZone 当触发源也能开门", wired.is_open)
	zone._set_pressed(false)
	_check("玩家离开区域后门转入关闭", not wired.is_open)

	# —— 挤压：门落下来压在玩家头顶要停住，不是把人横弹出去（StaticBody2D 改尺寸推不动人）
	# 玩家用 player.tscn 原件：这一组判的是物理世界的真实重叠，替身查不到。
	var squeeze_x := 1200.0
	var ground := StaticBody2D.new()
	var ground_shape := CollisionShape2D.new()
	var ground_rect := RectangleShape2D.new()
	ground_rect.size = Vector2(4000.0, 40.0)
	ground_shape.shape = ground_rect
	ground_shape.position = Vector2(squeeze_x, 20.0) # 地面顶边落在 y=0
	ground.add_child(ground_shape)
	add_child(ground)

	var squeezer := load("res://scenes/objects/door/door.tscn").instantiate() as Door
	squeezer.position = Vector2(squeeze_x, 0.0)
	add_child(squeezer)
	squeezer.set_open(true)
	await _frame(40)
	_check("示范门已全开", squeezer._progress == 1.0)

	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.position = Vector2(squeeze_x, -Player.COLLISION_HALF_HEIGHT)
	add_child(hero)
	await _frame(3)
	squeezer.set_open(false)
	await _frame(40)

	var head_top: float = hero.global_position.y - Player.COLLISION_HALF_HEIGHT
	var panel_bottom: float = squeezer.global_position.y + _panel_bottom_local(squeezer)
	_check("门底没有压过玩家头顶（%.2f vs %.2f）" % [panel_bottom, head_top],
		panel_bottom <= head_top + 0.01)
	_check("门是贴着头停住而不是悬着一帧行程（差 %.2f px）" % (head_top - panel_bottom),
		head_top - panel_bottom < 0.3)
	_check("挡住时挂着 is_blocked", squeezer.is_blocked)
	_check("玩家没有被挤开", absf(hero.global_position.x - squeeze_x) < 0.05)
	_check("玩家也没有被顶离地面", absf(hero.global_position.y + Player.COLLISION_HALF_HEIGHT) < 0.05)
	var sr2: Rect2 = squeezer.shutter_rect()
	var bottom_gap: float = _panel_bottom_local(squeezer) - (sr2.position.y + sr2.size.y)
	_check("压住时画出来的门底不低于碰撞体底、至多差一行像素（差 %.2f）" % bottom_gap,
		bottom_gap >= -0.001 and bottom_gap < 1.0)

	var held: float = squeezer._progress
	await _frame(30)
	_check("挡住之后不硬收", squeezer._progress == held)
	TimeManager.notify_movement_intent(true)
	await _frame(20)
	_check("冻结中被头顶住的门照样不动", squeezer._progress == held)
	TimeManager.notify_movement_intent(false)

	hero.global_position = Vector2(squeeze_x + 300.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(60)
	_check("玩家让开后门收到关严", squeezer._progress == 0.0)
	_check("关严后不再算被挡", not squeezer.is_blocked)

	print(TAG, " done failures=%d" % _fails)
	get_tree().quit(_fails > 0)


## 门扇底边在门本地坐标下的高度（原点 = 门洞底边中心，向上为负）。
func _panel_bottom_local(door: Door) -> float:
	var col: CollisionShape2D = door.get_node("CollisionShape2D")
	var rect: RectangleShape2D = col.shape
	return col.position.y + rect.size.y * 0.5


func _frame(count: int = 1) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(label: String, passed: bool) -> void:
	print(TAG, " %s %s" % ["ok  " if passed else "FAIL", label])
	if not passed:
		_fails += 1
