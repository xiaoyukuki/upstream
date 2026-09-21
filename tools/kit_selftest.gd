extends Node
## 无头回归自测：只盯这次打包改动碰过的路径，不替代玩家的试玩。
##
## 1) 门的时间仍然只从 TimeReceiver 的门控 delta 累计 —— 冻结期间 `_progress` 一字不动；
## 2) `_apply()` 新加的"只在值变了才写"比较不能把该写的赋值挡掉（全开时碰撞体必须收零）；
## 3) MovingBlock 换成 travel_offset 之后，行程仍然锁在 [anchor, anchor+offset] 区间内；
## 4) 门的 trigger 接线：按下即开、冻结中松开只记意图不位移、解冻后续收、换源断旧连接；
## 5) 关门压到玩家头顶时停在头顶：不越界、不把人挤开、人让开后照常收严。
## 6) M5 电棒：时钟只吃门控 delta，冻结即钉住；相位算式按 phase 偏移，挡路盒随通断上下层。
## 7) M5 判死（D38）：判定不吃世界 delta —— 世界冻着、棒通着电，人站进光束照样被点名，
##    且一次性（本条命只发一次）。
## 8) M5 刷卡门：踩卡即拾、冻结中带卡进感应带照样认卡（D38 第 4 条）、认卡后演一整拍（D41）
##    —— 移动被锁、幕逐行塌而碰撞体始终与画出来的同截、世界全程冻着，演完才让行并解锁。
## 9) M5 存档与回灌（D31）：踩存档点写进常驻根 run_state、危险物点名走「保留进度的重载」、
##    新关卡实例回灌重生位与祭坛已耗（能力直接开，不重播静止即启）。
##    死亡那一拍（D42）：点名当帧只起演出、演完才重载且只重载一次，演出期间世界被钉在
##    冻结（能力没开也钉得住）、尸体不再走路。
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
	await _frame(8)

	hero.global_position = Vector2(squeeze_x + 300.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(60)
	_check("玩家让开后门收到关严", squeezer._progress == 0.0)
	_check("关严后不再算被挡", not squeezer.is_blocked)

	# —— M5 行为组 ——
	# 先清掉上一节的人：第 9 组里 LevelBase._apply_run_state 用 get_first_node_in_group 挑玩家，
	# 留着他会把回灌做在错的人身上。地面留着，后面几组的人都要站得稳。
	hero.queue_free()
	squeezer.queue_free()
	await _frame(2)

	await _test_bar_clock()
	await _test_bar_phase()
	await _test_frozen_kill()
	await _test_key_door()
	await _test_run_state()

	print(TAG, " done failures=%d" % _fails)
	get_tree().quit(_fails > 0)


## 第 6 组 a：电棒时钟只吃门控 delta（D35/D38）。
func _test_bar_clock() -> void:
	var bar := load("res://scenes/objects/electric_bar/electric_bar.tscn").instantiate() as ElectricBar
	bar.position = Vector2(1400.0, -300.0)
	add_child(bar)
	await _frame(8)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var frozen_clock: float = bar._clock
	await _frame(20)
	_check("冻结期间电棒时钟一分一毫不动", bar._clock == frozen_clock)
	TimeManager.notify_movement_intent(false)
	await _frame(20)
	_check("解冻后电棒时钟接着走", bar._clock > frozen_clock)
	bar.queue_free()


## 第 6 组 b：相位算式按 phase 偏移，挡路盒随通断上下层（D35 第 3 条 / D29 第 3 条）。
func _test_bar_phase() -> void:
	var wall := load("res://scenes/objects/electric_bar/electric_bar.tscn").instantiate() as ElectricBar
	wall.period = 1.0
	wall.duty = 0.5
	wall.phase = 0.6 # 0.6..1.0 段断电：开局就是 OFF
	wall.blocks_when_live = true
	wall.position = Vector2(1450.0, -300.0)
	add_child(wall)
	await _frame(2)
	var blocker := wall.get_node("Blocker") as StaticBody2D
	_check("phase=0.6 开局断电", not wall.is_live())
	_check("断电时挡路盒退层（layer 0）", blocker.collision_layer == 0)
	await _frame(30) # 0.5 s > 0.4 s：时钟走进通相位
	_check("时钟走进通相位，棒变致命", wall.is_live())
	_check("通电且 blocks_when_live，挡路盒上 time_solid 层", blocker.collision_layer == 4)
	wall.queue_free()


## 第 7 组：判定不吃世界 delta（D38 第 2 条）—— 世界冻着、棒通着电，人站进光束照样被点名。
func _test_frozen_kill() -> void:
	var killer := load("res://scenes/objects/electric_bar/electric_bar.tscn").instantiate() as ElectricBar
	killer.period = 0.0 # ≤0 视为常通电：冻结中相位没有歧义
	killer.position = Vector2(1500.0, -200.0)
	add_child(killer)
	TimeManager.notify_movement_intent(true)
	await _frame(1)
	var deaths: Array = []
	killer.touched_player.connect(func(body: Node2D) -> void: deaths.append(body))
	var victim := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	victim.position = killer.position # 站进光束中心
	add_child(victim)
	await _frame(3)
	_check("世界冻着、棒通着电，人站进光束照样被判死", deaths.size() == 1)
	await _frame(10)
	_check("判死一次性：本条命只发一次", deaths.size() == 1)
	TimeManager.notify_movement_intent(false)
	victim.queue_free()
	killer.queue_free()
	await _frame(2)


## 第 8 组：刷卡门 —— 拾卡、冻结中带卡进感应带即认卡（D38 第 4 条）、认卡后演一整拍（D41）：
## 移动被锁住、幕逐行塌下去且碰撞体与画出来的同截、世界全程冻着，演完才真开、才把移动还回去。
func _test_key_door() -> void:
	var gate_rig := Node2D.new()
	add_child(gate_rig)
	var card := load("res://scenes/objects/key_pickup/key_pickup.tscn").instantiate() as KeyPickup
	card.name = "Card"
	card.position = Vector2(2500.0, 0.0)
	var gate := load("res://scenes/objects/key_door/key_door.tscn").instantiate() as KeyDoor
	gate.name = "Gate"
	gate.position = Vector2(2600.0, 0.0)
	gate.key = NodePath("../Card")
	gate_rig.add_child(card)
	gate_rig.add_child(gate)

	var gate_col := gate.get_node("CollisionShape2D") as CollisionShape2D
	var gate_rect := gate_col.shape as RectangleShape2D

	var courier := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	courier.position = Vector2(2500.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(courier)
	await _frame(3)
	_check("玩家踩上卡即拾取（接触判定不吃世界 delta）", card.held)

	# 还没认卡的那一态：实体与画出来的同宽同底、且都挡满门洞。
	var locked: Rect2 = gate.curtain_rect()
	_check("锁着的光幕挡满门洞且与碰撞体同一截",
		gate_rect.size == Vector2(32.0, 96.0)
		and locked == Rect2(-16.0, -96.0, 32.0, 96.0)
		and absf(gate_col.position.y + gate_rect.size.y * 0.5
			- (locked.position.y + locked.size.y)) < 0.01)

	# 冻结中带卡进感应带：玩家朝门走 = 世界冻结，检测必须照常（D38 第 4 条）。
	# 认卡**不再当场让行**（D41）：卡被吞、移动被锁，幕要演一整拍才塌完。
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	courier.position = Vector2(2570.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("冻结中带着卡进感应带照样认卡", card.consumed and not card.held)
	_check("认卡那一帧演出才刚开始：门还没让行", not gate.is_latched)
	var beat_start: float = gate.curtain_rect().size.y
	_check("认卡那一帧幕还基本满着（塌下去要花时间，不是一帧）", beat_start > 85.0)
	_check("认卡即锁住玩家移动", courier.movement_locked)
	_check("世界此刻仍然冻结着（演出不是靠解冻走完的）", TimeManager.is_time_frozen())

	# 演出中：按着方向键人也别想往前走 —— 这一拍是被保护起来的。
	var x_at_beat: float = courier.global_position.x
	Input.action_press(&"move_right")
	await _frame(6)
	_check("演出中按着右也不前进（移动锁拦的是输入，不是只拦了世界）",
		absf(courier.global_position.x - x_at_beat) < 0.001 and courier.velocity.x == 0.0)
	var mid: Rect2 = gate.curtain_rect()
	_check("幕正在逐行塌下去（比认卡那一帧矮，但还没塌完）",
		mid.size.y > 0.0 and mid.size.y < beat_start)
	_check("塌的过程中碰撞体仍然不比画出来的短，且底边始终接地",
		gate_rect.size.y >= mid.size.y and gate_rect.size.y - mid.size.y < 1.0
		and absf(gate_col.position.y + gate_rect.size.y * 0.5) < 0.01)
	_check("卡与幕共用同一条钟：此刻两边都在半路",
		card.fly_progress() > 0.0 and card.fly_progress() < 1.0)
	_check("世界全程冻着", TimeManager.is_time_frozen())

	# 演完：幕归零、移动还回来，且卡不会比门活得久。
	var guard := 0
	while not gate.is_latched and guard < 120:
		await _frame(1)
		guard += 1
	Input.action_release(&"move_right")
	_check("演出在有限帧内跑完（没有卡在半途）", gate.is_latched)
	_check("撤幕后碰撞体收零", gate_rect.size.y < 0.01)
	_check("撤幕后不再画光幕", gate.curtain_rect().size.y == 0.0)
	await _frame(2)
	_check("卡与门同拍收尾（门开完时卡也飞完了）", card.fly_progress() < 0.0)
	_check("收尾把移动还回玩家", not courier.movement_locked)
	courier.position = Vector2(courier.global_position.x, -Player.COLLISION_HALF_HEIGHT)
	var x_after: float = courier.global_position.x
	Input.action_press(&"move_right")
	await _frame(6)
	_check("解锁后按右立刻能走（锁不是永久状态）", courier.global_position.x > x_after)
	Input.action_release(&"move_right")

	# 闩锁是一次性的：解冻一圈再冻回去，撤掉的幕也不会装回来。
	TimeManager.notify_movement_intent(false)
	await _frame(20)
	TimeManager.notify_movement_intent(true)
	await _frame(20)
	_check("解冻再冻结都不会把幕装回去", gate.is_latched and gate_rect.size.y < 0.01)
	TimeManager.notify_movement_intent(false)
	courier.queue_free()
	gate_rig.queue_free()
	await _frame(2)


## 第 9 组：存档点 / 死亡 / run_state 回灌（D31 + D42）。给 LevelBase 一个 Main 替身当常驻根
## （world_root 组 + get_run_state + reload_level），重点在「死亡重载不清进度」这条分界，
## 外加死亡那一拍：先演完再重载、演出期间世界被钉住、尸体不再走路。
func _test_run_state() -> void:
	var stub = Node.new()
	var stub_script := GDScript.new()
	stub_script.source_code = """
extends Node
var run_state := {}
var reload_calls := 0
func get_run_state() -> Dictionary:
	return run_state
func reload_level() -> void:
	reload_calls += 1
"""
	stub_script.reload()
	stub.set_script(stub_script)
	stub.add_to_group(&"world_root")
	add_child(stub)

	var rig1 := _build_mini_level(stub)
	var walker1: Player = rig1["walker"]
	await _frame(2)
	_check("开局能力关着（start_with_ability=false）", not TimeManager.is_ability_enabled)

	walker1.global_position = Vector2(3100.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	var saved = stub.run_state.get("respawn_position")
	_check("踩上存档点把重生位写进常驻根", saved is Vector2)
	if saved is Vector2:
		_check("存的是玩家位（抬过半个盒高），不是存档点原点",
			saved == Vector2(3100.0, -Player.COLLISION_HALF_HEIGHT))

	# 死亡那一拍（D42）：点名当帧只起演出，重载要等演完。按着方向键是为了确认
	# 「尸体不再走路」而不是「恰好没人碰键盘」。判死要等物理服务器把移动后的形状冲一次，
	# 所以这里只轮询「什么时候死」，不去赌固定帧数。
	Input.action_press(&"move_right")
	walker1.global_position = Vector2(3200.0, -Player.COLLISION_HALF_HEIGHT)
	var watch := 0
	while not walker1.is_dead and watch < 60:
		watch += 1
		await get_tree().physics_frame
	_check("危险物点名即进入死亡演出", walker1.is_dead)
	_check("刚死时不重载（重载排在演出之后）", stub.reload_calls == 0)
	var beat := 0
	while beat < 6:
		beat += 1
		await get_tree().physics_frame
	_check("能力没开也钉得住冻结（钉住不走移动意图通道）",
		not TimeManager.is_ability_enabled and TimeManager.is_time_frozen()
			and TimeManager.is_frozen_overridden())
	_check("演出中进度落在开区间", walker1.death_progress() > 0.0 and walker1.death_progress() < 1.0)
	var visual := walker1.get_node("Visual") as Node2D
	_check("演出中身体在收缩", visual.scale.y < 1.0)
	var burst := walker1.get_node("DeathBurst") as DeathBurst
	_check("爆裂液滴已挂上", burst.is_active())
	var corpse_pos: Vector2 = walker1.global_position
	var pinned_world_time: float = TimeManager.elapsed_world_time
	for i in 8:
		beat += 1
		await get_tree().physics_frame
	_check("按着方向键的尸体不位移", walker1.global_position == corpse_pos)
	_check("钉住这一拍里世界时间不涨", TimeManager.elapsed_world_time == pinned_world_time)
	Input.action_release(&"move_right")

	# 演完才由 death_finished 转成下一帧的重载；时长只有 LevelBase.death_time 一个来源。
	var guard := 0
	while stub.reload_calls == 0 and guard < 200:
		guard += 1
		beat += 1
		await get_tree().physics_frame
	_check("演完才委托常驻根做死亡重载", stub.reload_calls == 1)
	_check("演完液滴自己收摊", not burst.is_active())
	_check("那一拍真的持续了一段（不是又换回瞬间重载）", beat >= 20 and beat <= 60)
	await _frame(20)
	_check("一次死亡只重载一次（不叠加）", stub.reload_calls == 1)
	_check("死亡重载不清 run_state（存档点要活过这一跳）",
		stub.run_state.has("respawn_position"))
	(rig1["level"] as Node).queue_free()
	await _frame(2)

	# 模拟 Main.reload_level 落一个新关卡实例：回灌重生位与祭坛已耗。
	stub.run_state["altar_spent"] = true
	var rig2 := _build_mini_level(stub)
	var walker2: Player = rig2["walker"]
	var altar2 := rig2["altar"] as AbilityAltar
	await _frame(2)
	_check("回灌：玩家落在存档点（spawn_point 逐位）",
		walker2.spawn_point == Vector2(3100.0, -Player.COLLISION_HALF_HEIGHT))
	_check("回灌：能力直接开启（altar_spent 一个布尔推导，不再另存一份）",
		TimeManager.is_ability_enabled)
	_check("回灌：祭坛摆成已耗", altar2.is_granted)
	var grants: Array = []
	altar2.ability_granted.connect(func() -> void: grants.append(1))
	walker2.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("已耗祭坛再踩不发授予信号", grants.is_empty())
	stub.queue_free()


## 搭一个最小关卡：祭坛 + 尖刺 + 存档点 + 玩家，挂到传入父节点下。
## 节点经字典返回，免得用字符串路径再捞一遍。
func _build_mini_level(parent: Node) -> Dictionary:
	var level := load("res://scenes/levels/level_base.gd").new() as LevelBase
	level.start_with_ability = false
	var objects := Node2D.new()
	objects.name = "Objects"
	level.add_child(objects)
	var altar := load("res://scenes/objects/ability_altar/ability_altar.tscn").instantiate() as AbilityAltar
	altar.name = "AbilityAltar"
	altar.position = Vector2(3000.0, 0.0)
	objects.add_child(altar)
	var spikes := load("res://scenes/objects/spikes/spikes.tscn").instantiate() as Spikes
	spikes.position = Vector2(3200.0, 0.0)
	level.add_child(spikes)
	var checkpoint := load("res://scenes/objects/checkpoint/checkpoint.tscn").instantiate() as Checkpoint
	checkpoint.position = Vector2(3100.0, 0.0)
	level.add_child(checkpoint)
	var walker := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker.position = Vector2(3050.0, -Player.COLLISION_HALF_HEIGHT)
	level.add_child(walker)
	parent.add_child(level)
	return {"level": level, "altar": altar, "spikes": spikes, "checkpoint": checkpoint, "walker": walker}


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
