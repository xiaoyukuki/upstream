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
## 10) 祭坛授予那一拍（D44）：时钟只有真实 delta 一条 —— 世界被钉在冻结里也照样从头演到完，
##     玩家身体那一档亮完自己退回原色，演出半路人死亡即收摊。
## 11) 冻结态的视觉符号（D46）：灰叠加退役、换 CRT shader。无头不编译着色器，所以这一组
##     不验像素（验像素归 tools/frame_grab.tscn 开窗那条路），只钉材质上那组裁定参数，
##     和那条最容易静默弄死的通路 —— 强度还在一帧一帧爬与溶，不是硬开硬关。
## 12) 残影踏板（D47）：冻结那一拍整条链上 time_solid 且一格不挪，松手 0.08 s 缓冲里照旧
##     踩着，解冻即回无形；位置只是世界时钟的纯函数（新实例同拍数重跑必与首跑同相）；
##     最后一条是真玩家站上去的承载判据 —— 冻着接得住、解冻穿得过。
## 13) 活塞踏板（D49）：一组活塞接同一个按钮（多对一合法）；伸出/收回只跟按钮布尔量走，
##     冻结即停在当前伸出量、松开只记意图；收回快过伸出且把落脚点从脚下抽干（人掉下去不是
##     被带着沉进地里）；行程上有人时**挤开**他，他背后有墙则他自己被挡住、方块跟着停在接触面
##     上走不满行程 —— 于是挤压不发生，且顶住期间不攒位移。
## 14) 粘性进度（D51）：祭坛「已耗」由游戏代码真的写进 run_state（不是守门替它写），
##     存档点全关卡只一台激活，且死亡重载后亮的还是死前那一台。
## 15) 坠落带（D52）：掉出世界这条路从无兜底改成有一根线 —— 带子只认玩家且一条命只发一次；
##     走的是**保留进度**的死亡重载而不是清空进度的主动重开，于是掉下去回的是最近那台存档点；
##     判据不吃世界 delta，冻着往下落照样被接住。
## 16) 刷卡门的拒绝提示（D53）：无卡走进感应带只闪**一次**（边沿触发，站着不动不叠发）；
##     它是只读旁路 —— 不锁移动、不消耗卡、幕一格不塌；有卡则直接进闩锁链，红色不许插队；
##     脉冲全程在世界冻结里跑得完（接成世界 delta 就永远红着）；尸体不触发；时长只有
##     `denied_time` 一个来源；闩了之后不再闪。
##
## 跑法：Godot --headless --path <项目根> res://tools/kit_selftest.tscn

const TAG := "[kit-selftest]"
const BLOCK_ANCHOR := Vector2(500, -200)
## 第 15 组生产链用：把整个关卡实例抬到半空，脚下才算真的没有底。
## 不抬不行 —— 第 5 节那块地面的顶边正好落在 y=0、铺满 x -800..3200，存档点那一排（x 650~900）
## 就摆在它上面，人在那儿是"站着"，坠不出东西给网接。
const OVER_VOID := Vector2(0.0, -600.0)

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
	await _test_grant_beat()
	await _test_freeze_filter()
	await _test_afterimage()
	await _test_piston()
	await _test_sticky_progress()
	await _test_fall_zone()
	await _test_gate_denial()

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
	var stub = _make_world_root()

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
	# 这里手写这个键是因为本组测的是**读路径**；写路径由第 14 组钉 —— 以前两边都没人钉，
	# 于是游戏代码里压根没人写的这条链被本组的手写值盖了很久。
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
	_check("回灌只摆样子不重播那一拍", altar2.grant_progress() < 0.0)
	stub.queue_free()


## 第 10 组：祭坛授予那一拍（D44）。要钉的只有一件事 —— 这一拍的时钟是真实 delta，
## 不是世界 delta：踩上去之前把世界钉在冻结（能力没开 + `set_frozen_override`，
## 也就是「世界一定不流」的最狠组合），演出仍要从头走到尾。顺带钉两条便宜的边界：
## 玩家身体那一档亮完自己退回原色（不留在半亮），以及半路死了当场收摊。
func _test_grant_beat() -> void:
	# 先等第 9 组的旧人真的离树：那些 rig 与本组共用 x=3000 那条线，还挂在树上的旧玩家
	# 会替新人把这一祭坛的一次性授予吃掉（body_entered 只认第一个撞进来的身体）。
	await _frame(2)
	# 本组的替身根用完要拆：它挂在 world_root 组里，留着就会占住「第一个」的位置，
	# 让后面任何一组把自己的 run_state 写到别人身上。
	var world_root = _make_world_root()
	var rig := _build_mini_level(self)
	var walker: Player = rig["walker"]
	var altar := rig["altar"] as AbilityAltar
	await _frame(2)
	altar.grant_time = 0.5 # 缩短总长：守门不为等演出白耗一秒，比例仍按脚本里那三个分数走

	TimeManager.set_frozen_override(true)
	var pinned_world_time: float = TimeManager.elapsed_world_time
	walker.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	var frames := 0
	while altar.grant_progress() < 0.0 and frames < 40:
		frames += 1
		await get_tree().physics_frame
	_check("世界钉在冻结里那一拍照样起来", altar.grant_progress() >= 0.0)
	_check("钉住期间世界时间不涨", TimeManager.elapsed_world_time == pinned_world_time)
	var before := altar.grant_progress()
	await _frame(6)
	_check("钉着冻结也在往后推进（吃的不是世界 delta）", altar.grant_progress() > before)
	_check("钉住期间世界仍是冻结态", TimeManager.is_time_frozen() and TimeManager.is_frozen_overridden())

	var visual := walker.get_node("Visual") as Node2D
	frames = 0
	while visual.modulate.g <= 1.0 and frames < 40:
		frames += 1
		await get_tree().physics_frame
	_check("核心到位那一帧身体被提亮（modulate 分量 >1 才叫亮）", visual.modulate.g > 1.0)

	var guard := 0
	while (altar.grant_progress() >= 0.0 or visual.modulate.g > 1.0) and guard < 120:
		guard += 1
		await get_tree().physics_frame
	_check("那一拍演完自己收摊", altar.grant_progress() < 0.0)
	_check("亮完退回原色，alpha 一字没动（.a 归 D42 的淡出）", visual.modulate == Color(1, 1, 1, 1))
	_check("整拍 + 那一档亮加起来真的持续了一段", guard >= 15 and guard <= 90)
	(rig["level"] as Node).queue_free()
	await _frame(2)

	# 半路死了：核心不该飞进一具正在缩没的身体，当场收摊。
	# 上一段那次踩祭坛已经把「已耗」记进替身根了（D51 起这是游戏代码的生产行为，不是 fixture 手写），
	# 而本组这一段要验的是"第一次踩"，所以进度得擦干净 —— 生产里这一下由 Main.load_level 换关时做。
	world_root.run_state.clear()
	TimeManager.reset_state()
	var rig2 := _build_mini_level(self)
	var walker2: Player = rig2["walker"]
	var altar2 := rig2["altar"] as AbilityAltar
	await _frame(2)
	walker2.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	guard = 0
	while altar2.grant_progress() < 0.0 and guard < 20:
		guard += 1
		await get_tree().physics_frame
	_check("换一具新身体踩上照样起那一拍（不钉冻结的最小组合）",
		altar2.grant_progress() >= 0.0)
	walker2.die(0.5)
	await _frame(2)
	_check("演出半路人死了当场收摊", altar2.grant_progress() < 0.0)
	(rig2["level"] as Node).queue_free()
	world_root.queue_free()
	TimeManager.reset_state()
	await _frame(2)


## 第 11 组：冻结态的视觉符号换成 CRT（D46）。无头下 Compatibility 不编译着色器，
## 所以这里一格像素都不验（验像素是 `tools/frame_grab.tscn` 开窗那条路），只钉两件
## 纯数据的事：材质真的挂上且参数是裁定那一组；以及**淡入淡出还活着**。
## 后者是这次改动唯一会静默死掉的通路 —— 旧版靠 ColorRect 顶点色的 alpha 溶解，
## 而 canvas_item 的 fragment() 一写 COLOR 就把顶点色丢了。接错的话滤镜变成硬开硬关，
## 画面照样"对"，只有逐帧看强度曲线才发现，所以把它钉在这里。
func _test_freeze_filter() -> void:
	var filter := load("res://scenes/ui/time_freeze_filter.tscn").instantiate() as TimeFreezeFilter
	add_child(filter)
	await _frame(2)

	var rect := filter.get_node("ColorRect") as ColorRect
	var mat := rect.material as ShaderMaterial
	_check("滤镜仍压在 layer 100（暂停菜单与调试面板在它之上，D8 的层序没动）",
		filter.layer == TimeFreezeFilter.LAYER_INDEX)
	_check("ColorRect 挂的是 ShaderMaterial（灰叠加版已退役）", mat != null)
	if mat == null:
		return
	_check("材质连着 shader 文件", mat.shader != null)
	_check("裁定那组参数在材质上：linearFac 1.3",
		is_equal_approx(mat.get_shader_parameter("linear_fac"), 1.3))
	_check("裁定那组参数在材质上：scanLineFac 0.10 / 宽 0.25",
		is_equal_approx(mat.get_shader_parameter("scan_line_fac"), 0.1)
		and is_equal_approx(mat.get_shader_parameter("scan_line_width"), 0.25))
	_check("色散开着", bool(mat.get_shader_parameter("aberration_enabled")))

	# 强度曲线：先确认在流的时间里是干净的 0，再钉住冻结看它一帧一帧爬上去。
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	TimeManager.notify_movement_intent(false)
	await _frame(4)
	_check("流着的时间里强度归零、那块矩形不让画",
		filter.strength() == 0.0 and not rect.visible)

	TimeManager.notify_movement_intent(true)
	# 意图到 state_changed 之间可能隔一拍（TimeManager 在自己的处理步里改状态），
	# 所以等的是「第一格非零」而不是「第 N 拍」。淡入死了的话这一格直接是 1.0。
	var waited := 0
	while filter.strength() <= 0.0 and waited < 30:
		waited += 1
		await get_tree().process_frame
	_check("冻结那一刻强度在爬，不是直接顶满（淡入没死）",
		filter.strength() > 0.0 and filter.strength() < 0.9)
	var rising := true
	var prev := filter.strength()
	# 等的是值不是拍数：这条淡入是真实 delta 的指数平滑（收敛约 0.58 s），
	# 而无头跑起来的 process 帧不是每秒 60 拍，按帧给预算等于掷硬币。
	var climb := 0
	while filter.strength() < 0.999 and climb < 2000:
		climb += 1
		await get_tree().process_frame
		var now := filter.strength()
		rising = rising and now >= prev
		prev = now
	_check("整条曲线单调不回头地涨到满", rising and filter.strength() > 0.999)
	_check("爬满真的花了几拍（不是一帧顶满）", climb >= 5)
	_check("满强度时矩形在画", rect.visible)

	TimeManager.notify_movement_intent(false)
	waited = 0
	while filter.strength() >= 0.999 and waited < 30:
		waited += 1
		await get_tree().process_frame
	_check("解冻后往下溶，不是硬关到零",
		filter.strength() < 0.999 and filter.strength() > 0.0)
	var sink := 0
	while filter.strength() > 0.0 and sink < 2000:
		sink += 1
		await get_tree().process_frame
	_check("溶到底后不让画（屏幕纹理那一遍整个跳过）",
		filter.strength() == 0.0 and not rect.visible)

	filter.queue_free()
	TimeManager.reset_state()
	await _frame(2)


## 第 12 组：残影踏板（D47）。钉的全是"改了不响、要到试玩才露馅"那几件：冻结那一拍整条
## 链上 time_solid 且一格不挪（有形时不动 = 承载安全那根柱子）；松手那 0.08 s 缓冲里照旧
## 踩着（这条玩家直接摸得到，且它证明实体只跟状态机走、不跟帧走）；解冻即回无形。
## 位置纯函数那一条用"新实例同拍数重跑必与首跑同相"来验 —— 只钉公式相等是拿代码验代码，
## 验不出相位里混进了出生时刻这类旁路状态。最后一档是真玩家站上去：上面全绿也证明不了
## "能踩"，而能踩是这个构件的立身之本。像素照旧不归无头管（D46 同规矩）。
func _test_afterimage() -> void:
	var rig := Node2D.new()
	rig.name = "AfterimageRig"
	add_child(rig)
	var nozzle := Vector2(2000.0, -400.0)
	var emitter := _afterimage_instance(rig, nozzle)
	TimeManager.reset_state()
	await _frame(30)
	var rungs := _afterimage_rungs(emitter)
	var active := emitter.active_steps()
	_check("参照档（400×0.20 → 节距 80）：链上 5 格、池子里 8 格（多出来那 3 格永远不该成平台）",
		active == 5 and rungs.size() == 8)
	var tops30: Array = []
	for k in active:
		tops30.append(emitter.step_top_y(k))
	var drift := 0.0
	for k in active:
		drift = maxf(drift, absf(rungs[k].position.y - (tops30[k] + emitter.step_size * 0.5)))
	_check("流 30 拍后逐格位置仍等于公式值（最大偏差 %s px）" % str(drift), drift < 0.01)

	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var clock_frozen := emitter.world_clock()
	var still: Array = []
	for k in active:
		still.append(rungs[k].position.y)
	await _frame(12)
	var slid := 0.0
	for k in active:
		slid = maxf(slid, absf(rungs[k].position.y - still[k]))
	_check("冻结 12 拍：世界时钟一格没走", emitter.world_clock() == clock_frozen)
	_check("冻结 12 拍：整条链没挪（最大 %s px）" % str(slid), slid == 0.0)
	_check("冻结：链上 5 格都在 time_solid(4)、池里多余 3 格都不在",
		_afterimage_layers(rungs, active, true))

	TimeManager.notify_movement_intent(false)
	await _frame(2)
	_check("松手 2 拍还在缓冲里、链照旧踩着（解冻不是立即的）",
		TimeManager.is_releasing() and emitter.is_solid())
	await _frame(10)
	_check("缓冲走完：链回无形、时钟重新走",
		not emitter.is_solid() and emitter.world_clock() > clock_frozen)
	_check("无形时处处不在层上（这才叫穿得过去）", _afterimage_layers(rungs, 0, false))

	# 承载：脚底对准第 3 格的踩面。30 高的盒顶不到上一格的底边（差 18 px，D47 那条几何）。
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var stand_y: float = emitter.global_position.y + emitter.step_top_y(2)
	var column_x := emitter.global_position.x
	var walker := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker.position = Vector2(column_x, stand_y - Player.COLLISION_HALF_HEIGHT)
	rig.add_child(walker)
	# D48 的四条判死断言都从这一个计数器读。它同时是"信号名没被改坏"的活证：
	# 改名之后 LevelBase 那套按信号名的自动接线会静默不接，这里当场点不出来。
	var poked: Array[Node2D] = []
	emitter.touched_player.connect(func(p: Node2D) -> void: poked.append(p))
	await _frame(20)
	_check("冻住的格接得住一个玩家（20 拍没下沉）",
		absf(walker.position.y - (stand_y - Player.COLLISION_HALF_HEIGHT)) < 1.0)
	var sink: float = (walker.position.y + Player.COLLISION_HALF_HEIGHT) - stand_y
	_check("站在冻结的踏面上 20 拍：一个判死信号都没有（踩住了不算 inside）", poked.is_empty())
	var inset: float = emitter.get_script().get_script_constant_map()["KILL_INSET"]
	_check("物理把人停在踩面上的穿透实测 %s px，留在内缩带 %s px 里" % [str(sink), str(inset)], absf(sink) < inset)

	# 松手 → 格子从脚底下走掉（它 400 px/s，人从零速起落）→ 再冻结。这几拍上一格一定会
	# 压到头顶（站在踩面上时头顶离上一格只有 18 px），但**落脚点还是虚的**：按 D48 只问
	# 脚底的口径，这里必须一句都不响。拿身体重叠判死的话这一档当场就是死刑。
	poked.clear()
	TimeManager.notify_movement_intent(false)
	await _frame(10)
	var grazed := false
	for k in emitter.active_steps():
		if emitter.step_rect(k).intersects(walker.collision_rect()):
			grazed = true
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("解冻 10 拍后再冻结：上一格已压到他身上（%s），但落脚点是虚的 → 不判死"
		% str(grazed), grazed and poked.is_empty())

	# 反过来：把他钉在格子身体里（脚底在踩面以下 20 px）再冻结 —— 必须点名，且点的是他。
	# 流动那几拍逐帧跟着格子挪：这一档验的是"冻结那一刻他压在格子里"，不是他会掉到哪儿。
	poked.clear()
	TimeManager.notify_movement_intent(false)
	for i in 8:
		await _frame(1)
		if not emitter.is_solid():
			walker.position = Vector2(column_x,
				emitter.global_position.y + emitter.step_top_y(2) + 20.0 - Player.COLLISION_HALF_HEIGHT)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("人在格子里时冻结 → 判死信号恰好发一次，且点名的就是他",
		poked.size() == 1 and poked[0] == walker)

	# 同一个位置、世界继续流着：链从他身上穿过去不算账 —— 判死只属于"刚刚变实体"那一帧。
	poked.clear()
	TimeManager.notify_movement_intent(false)
	await _frame(16)
	_check("流动期整条链从他身上穿过去：一个信号都不发", poked.is_empty())

	TimeManager.reset_state()
	# 40 拍而不是 20：无头这一跑物理拍不是整整 1/60，20 拍只落下一个身位的大半，
	# 差的那几像素是自由落体的时间不够，不是"没穿过去"。
	await _frame(40)
	_check("解冻后同一格穿得过去（人已掉到踩面以下一个身位）",
		walker.position.y > stand_y + Player.STAND_HEIGHT)

	# 回灌同相：整机换掉（重载就是一个新实例），同样 30 拍必须回到首跑那一模一样的相位。
	emitter.queue_free()
	walker.queue_free()
	await _frame(2)
	var second := _afterimage_instance(rig, nozzle)
	TimeManager.reset_state()
	await _frame(30)
	var resync := 0.0
	for k in second.active_steps():
		resync = maxf(resync, absf(second.step_top_y(k) - tops30[k]))
	_check("新实例同拍数重跑，链与首跑同相（最大 %s px）" % str(resync), resync < 4.0)

	rig.queue_free()
	TimeManager.reset_state()
	await _frame(2)


func _afterimage_instance(rig: Node, at: Vector2) -> AfterimageEmitter:
	var emitter := load("res://scenes/objects/afterimage_emitter/afterimage_emitter.tscn") \
		.instantiate() as AfterimageEmitter
	emitter.position = at
	# 自己钉一档参照参数，不跟脚本默认值走：这几个数归摆图的人随时调（D47 落档后用户已把
	# 默认改成 800×0.40 → 节距 320），照着默认值断言"链上 5 格"第二天就会红。
	# 进树前赋好，`_ready()` 的 `_rebuild()` 才按这档建池子。
	emitter.fall_speed = 400.0
	emitter.emit_interval = 0.20
	emitter.step_size = 32.0
	emitter.reach = 320.0
	emitter.max_steps = 8
	rig.add_child(emitter)
	return emitter


## 那一池挡路格是运行期 add_child 建的，按创建序就是链上的 k 序。走 get_children 而不是
## 直读 `_bodies`：字段一改名后者是硬报错，后面整段静默跳过而 failures 还是原样。
func _afterimage_rungs(emitter: AfterimageEmitter) -> Array:
	var out: Array = []
	for child in emitter.get_children():
		if child is StaticBody2D:
			out.append(child)
	return out


func _afterimage_layers(rungs: Array, active: int, want_solid: bool) -> bool:
	for i in rungs.size():
		var want: int = 4 if (want_solid and i < active) else 0
		if (rungs[i] as StaticBody2D).collision_layer != want:
			return false
	return true


## 第 13 组：活塞踏板（D49）。四档各钉一条"改坏了不会响、只有试玩才露馅"的：
## a) 一组两块接同一个按钮（多对一合法），冻结即停在当前伸出量上、松开只记意图；
## b) 收回明显快过伸出 —— 伸得慢到踩按钮的人跟得上，收得快到站不住；
## c) 收回把落脚点从脚下抽干：人自己掉回地面，不是被方块带着沉进地里；
## d) 行程上有人就**挤开**他；他背后有墙则他自己被挡住、方块跟着停在接触面上走不满行程，
##    且顶住期间不攒位移（脱困那一帧不会攒出一发弹射）。
func _test_piston() -> void:
	# 活塞靠 player 组找人推，前面几组留一个人在树上就是替错的人做测试 —— 先点破再往下跑。
	var leftovers := get_tree().get_nodes_in_group(&"player")
	_check("开跑前场上没有残留玩家（%d 个）" % leftovers.size(), leftovers.is_empty())
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	# 地面：顶边落在 y=0，x 覆盖本组三段 fixture（5000 / 5300 / 5500）。
	_solid_box(Vector2(5000.0, 20.0), Vector2(3000.0, 40.0))

	# —— a：一组活塞 + 冻结 ——
	var rig := Node2D.new()
	rig.name = "PistonRig"
	add_child(rig)
	var plate := _plate_instance(rig, "Plate", Vector2(5000.0, -400.0))
	var wall := _piston_instance(rig, plate, "Wall", Vector2(5000.0, -32.0), Vector2(64.0, 0.0))
	var twin := _piston_instance(rig, plate, "Twin", Vector2(5000.0, -200.0), Vector2(64.0, 0.0))
	_check("两块活塞接到同一个按钮（「一组」就是多对一，刻意不查重）",
		wall._bound == plate and twin._bound == plate)
	plate._set_pressed(true)
	_check("按钮一踩两块同时转入伸出", wall.is_out and twin.is_out)
	await _frame(10)
	_check("10 拍后两块都在半路（同一条布尔量驱动的积分器）",
		wall.progress() > 0.0 and wall.progress() < 1.0
		and twin.progress() > 0.0 and twin.progress() < 1.0)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var wall_p: float = wall.progress()
	var twin_p: float = twin.progress()
	var wall_pos: Vector2 = wall.global_position
	await _frame(12)
	_check("冻结 12 拍：两块停在当前伸出量上一格不挪",
		wall.progress() == wall_p and twin.progress() == twin_p
		and wall.global_position == wall_pos)
	plate._set_pressed(false)
	_check("冻结中松开按钮只记下「该收回」，人还站在伸出量上", not wall.is_out)
	await _frame(12)
	_check("冻结中收回照样不推进（两个方向共用世界时钟，没有旁路）", wall.progress() == wall_p)
	TimeManager.notify_movement_intent(false)
	await _frame(6)
	_check("解冻后两块一起往回收", wall.progress() < wall_p and twin.progress() < twin_p)
	var guard := 0
	while (wall.progress() > 0.0 or twin.progress() > 0.0) and guard < 200:
		guard += 1
		await get_tree().physics_frame
	_check("收回走到底（两块都回到伸出量为 0，皮上只剩洞口那一截）",
		wall.progress() == 0.0 and twin.progress() == 0.0)

	# —— b：速度差。伸出 128 / 收回 512 px/s，只断言量级，不赌整数拍。——
	plate._set_pressed(true)
	var extend_frames := 0
	while wall.progress() < 1.0 and extend_frames < 300:
		extend_frames += 1
		await get_tree().physics_frame
	plate._set_pressed(false)
	var retract_frames := 0
	while wall.progress() > 0.0 and retract_frames < 300:
		retract_frames += 1
		await get_tree().physics_frame
	_check("收回明显快过伸出（伸出 %d 拍 / 收回 %d 拍）" % [extend_frames, retract_frames],
		extend_frames > 0 and retract_frames * 2 < extend_frames)
	rig.queue_free()
	await _frame(2)

	# —— c：竖着伸出的一块当落脚点 ——
	var rig2 := Node2D.new()
	rig2.name = "RiserRig"
	add_child(rig2)
	var plate2 := _plate_instance(rig2, "Plate2", Vector2(5300.0, -400.0))
	var riser := _piston_instance(rig2, plate2, "Riser", Vector2(5300.0, 0.0), Vector2(0.0, -64.0))
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.position = Vector2(5300.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(hero)
	await _frame(4)
	_check("人站在洞口线上（收回态顶面与他脚底同一条线，一寸不嵌）",
		absf(riser.block_rect().position.y - (hero.global_position.y + Player.COLLISION_HALF_HEIGHT)) < 1.0
		and not riser.block_rect().intersects(hero.collision_rect()))
	plate2._set_pressed(true)
	guard = 0
	while riser.progress() < 1.0 and guard < 300:
		guard += 1
		await get_tree().physics_frame
	_check("伸到顶时人被带着升到踩面上（骑得上去）",
		absf(hero.global_position.y - (-64.0 - Player.COLLISION_HALF_HEIGHT)) < 2.0)
	_check("骑住时方块前缘就贴在他脚底下：挤到位而不吃进身体",
		absf(riser.block_rect().position.y - (hero.global_position.y + Player.COLLISION_HALF_HEIGHT)) < 2.0
		and not riser.block_rect().intersects(hero.collision_rect()))
	plate2._set_pressed(false)
	guard = 0
	while riser.progress() > 0.0 and guard < 60:
		guard += 1
		await get_tree().physics_frame
	_check("方块收回走完（%d 拍）时人还在半空 —— 是他自己在落，不是被带着沉" % guard,
		riser.progress() == 0.0 and hero.global_position.y < -35.0)
	_check("落脚抽干那一瞬方块与人身体不重叠（没被拽着往下走）",
		not riser.block_rect().intersects(hero.collision_rect()))
	guard = 0
	while absf(hero.global_position.y + Player.COLLISION_HALF_HEIGHT) > 0.5 and guard < 120:
		guard += 1
		await get_tree().physics_frame
	_check("掉回地面停住（脚底顶在 y=0，没有陷进地里）",
		absf(hero.global_position.y + Player.COLLISION_HALF_HEIGHT) < 1.0)
	rig2.queue_free()
	await _frame(2)

	# —— d：行程上有人 → 挤开；他背后有墙 → 停在接触面上 ——
	var rig3 := Node2D.new()
	rig3.name = "PushRig"
	add_child(rig3)
	var plate3 := _plate_instance(rig3, "Plate3", Vector2(5500.0, -400.0))
	var pusher := _piston_instance(rig3, plate3, "Pusher",
		Vector2(5500.0, -32.0), Vector2(64.0, 0.0))
	hero.global_position = Vector2(5545.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	plate3._set_pressed(true)
	guard = 0
	while pusher.progress() < 1.0 and guard < 300:
		guard += 1
		await get_tree().physics_frame
	_check("背后没墙：人被他自己的身体让出行程（推到他右侧 20 px 之外）",
		hero.global_position.x > 5565.0 and pusher.progress() == 1.0)
	_check("满行程时方块前缘仍然贴着他的后缘，一寸都没多走",
		absf(pusher.block_rect().end.x - (hero.global_position.x - 10.0)) < 0.6
		and not pusher.block_rect().intersects(hero.collision_rect()))
	plate3._set_pressed(false)
	guard = 0
	while pusher.progress() > 0.0 and guard < 60:
		guard += 1
		await get_tree().physics_frame
	hero.global_position = Vector2(5545.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	# 人先挪好再立墙：顺序反了就是把人嵌进地里，那是 fixture 的错不是构件的错。
	_solid_box(Vector2(5585.0, -250.0), Vector2(30.0, 500.0)) # 左面 x=5570
	await _frame(2)
	plate3._set_pressed(true)
	await _frame(60)
	_check("背后有墙：他自己撞停在墙上（后缘 5550 贴着前缘，人没被夹进墙）",
		absf(hero.global_position.x - 5560.0) < 1.5
		and absf((hero.global_position.x + 10.0) - 5570.0) < 1.5)
	_check("他被挡住 → 这块走不满行程（挤开不是把行程用完）",
		pusher.progress() > 0.5 and pusher.progress() < 1.0)
	_check("顶住期间方块前缘始终贴着他的后缘：挤压在这个结构里不发生",
		absf(pusher.block_rect().end.x - (hero.global_position.x - 10.0)) < 0.6
		and not pusher.block_rect().intersects(hero.collision_rect()))
	var held: float = pusher.progress()
	var x_held: float = hero.global_position.x
	await _frame(30)
	_check("顶住 30 拍不攒位移（位置读回实际值，脱困那一帧不会攒出一发弹射）",
		absf(pusher.progress() - held) < 0.001 and absf(hero.global_position.x - x_held) < 0.001)

	hero.queue_free()
	rig3.queue_free()
	TimeManager.reset_state()
	# 等这一组的人真的离树：第 14 组要用 get_first_node_in_group 挑玩家，留着他把回灌做在错的人身上。
	await _frame(2)


## 第 14 组：D51 两条粘性进度。钉的都是「代码看着没错、只有实机才露馅」那两件事：
## ① 祭坛「已耗」得由**游戏代码**写进 run_state —— 第 9 组为测回灌一直手写这个键，
##    于是读路径绿着、写路径整条死过；② 存档点全关卡只一台激活，且死亡重载后亮的
##    还是死前那一台（旧的「每台自存自亮」写法是踩过几台亮几台 + 重载集体复位）。
func _test_sticky_progress() -> void:
	await _frame(2)
	# —— ① 写路径：踩上祭坛那一刻就记「已耗」，这一条不接受守门替游戏代码写。 ——
	var stub = _make_world_root()
	var rig := _build_mini_level(stub)
	var walker: Player = rig["walker"]
	await _frame(2)
	_check("踩祭坛之前 run_state 里没有 altar_spent（写的人只有游戏代码）",
		not stub.run_state.has("altar_spent"))
	walker.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("踩上祭坛即由游戏代码把「已耗」写进常驻根",
		stub.run_state.get("altar_spent", false))
	# 已耗 ≠ 能力已开：D16 那一拍还要等松手，所以这里只钉键、不钉 TimeManager。
	(rig["level"] as Node).queue_free()
	stub.queue_free()
	await _frame(3)

	# —— ② 唯一激活：三台存档点挨个踩过去，任何时刻只有一台亮。 ——
	var root = _make_world_root()
	var ring := _build_checkpoint_ring(root)
	var terminals: Array = ring["terminals"]
	var hero: Player = ring["hero"]
	await _frame(3)
	_check("开局没有任何存档点亮着", _active_count(terminals) == 0)
	hero.global_position = Vector2(700.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("踩 A：A 亮，且身份跟着重生位一起进了 run_state",
		terminals[0].is_active and root.run_state.has("respawn_marker"))
	hero.global_position = Vector2(800.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("踩 B：只 B 亮（A 是让位，不是坏了）",
		terminals[1].is_active and _active_count(terminals) == 1)
	hero.global_position = Vector2(700.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("往回踩 A：激活搬回 A（皮永远说实话）",
		terminals[0].is_active and _active_count(terminals) == 1)

	# —— 回灌：换一个新关卡实例、run_state 留着，这才是 Main.reload_level 的语义。 ——
	var marker = root.run_state.get("respawn_marker")
	_check("身份是「相对关卡根的路径」而不是绝对路径（Main 挪容器也不影响）",
		marker is NodePath and str(marker) == "A700")
	(ring["level"] as Node).queue_free()
	await _frame(3)
	var ring2 := _build_checkpoint_ring(root)
	var t2: Array = ring2["terminals"]
	var hero2: Player = ring2["hero"]
	await _frame(3)
	_check("重载后亮的还是死前那一台（不是全灭、也不是全亮）",
		t2[0].is_active and _active_count(t2) == 1)
	_check("重生位仍指回那一台",
		hero2.spawn_point == Vector2(700.0, -Player.COLLISION_HALF_HEIGHT))
	root.queue_free()
	await _frame(2)


## 第 15 组：坠落带（D52）。三条钉 + 一条生产链，全都对着同一次报告：「掉出世界后没回到存档点」。
## 根因不在复活代码写坏了，而在**这条路上压根没有判死**：没有底、人一直落，先撞到的却是终点区
## 的「路过即算」→ 那条走的是主动重开（清空 run_state）→ 于是回的是出生点。所以钉的顺序照抄病历：
## ① 带子只认玩家、一条命内只发一次；② 换个非玩家 body 上到玩家那一层，一个信号都不许发；
## ③ 世界冻着时往下落照样被接住（判据不吃世界 delta，D38 第 2 条同一条口径）；
## ④ 生产链：踩住存档点 → 掉进带子 → 演完死亡那一拍 → 关卡委托的是**保留进度**的 reload_level
##    而不是清空进度的 restart_level → 换新的关卡实例后重生位仍指回那一台、且仍只那一台亮。
func _test_fall_zone() -> void:
	var leftovers := get_tree().get_nodes_in_group(&"player")
	_check("开跑前场上没有残留玩家（%d 个）" % leftovers.size(), leftovers.is_empty())
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)

	# fixture 全摆在 x 8000 之外：前面几组留了两块地面在下头（第 5 节 x -800..3200、
	# 第 13 节 x 3500..6500，顶边都落在 y=0），人摆在那上面是"站得住"，坠不了。
	var rig := Node2D.new()
	rig.name = "FallRig"
	add_child(rig)

	# —— ① 进带即点名，且本条命只发一次 ——
	var net := _fall_zone_instance(rig, Vector2(8000.0, 0.0), 256.0, 512.0)
	await _frame(2)
	var hits: Array = []
	net.touched_player.connect(func(body: Node2D) -> void: hits.append(body))
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.position = Vector2(8000.0, 60.0) # 已经在带子里（顶边 y=0，往下 512）
	rig.add_child(hero)
	await _frame(3)
	_check("玩家进带恰好一次 touched_player，且点名的就是他", hits.size() == 1 and hits[0] == hero)
	await _frame(8)
	_check("人继续待在带里不叠发（一次性闩锁，重置只属于关卡重载）", hits.size() == 1)
	hero.queue_free()
	net.queue_free()
	await _frame(2)

	# —— ② 非玩家 body 不算：故意摆在玩家那一层（2），让带子的 mask 真的捞到它 ——
	var sieve := _fall_zone_instance(rig, Vector2(8100.0, 0.0), 256.0, 512.0)
	var rock_hits: Array = []
	sieve.touched_player.connect(func(body: Node2D) -> void: rock_hits.append(body))
	var rock := StaticBody2D.new()
	rock.collision_layer = 2
	var rock_shape := CollisionShape2D.new()
	var rock_rect := RectangleShape2D.new()
	rock_rect.size = Vector2(20.0, 30.0) # 与玩家同尺寸：层对了、形状也对了，只有身份不对
	rock_shape.shape = rock_rect
	rock.add_child(rock_shape)
	rock.position = Vector2(8100.0, 60.0)
	rig.add_child(rock)
	await _frame(6)
	_check("非玩家 body 就算占了玩家那一层也不发（按 player 组挑人）", rock_hits.is_empty())
	sieve.queue_free()
	rock.queue_free()
	await _frame(2)

	# —— ③ 冻着往下落，带子照样接得住 ——
	var catcher := _fall_zone_instance(rig, Vector2(8200.0, 300.0), 256.0, 512.0)
	var cold_hits: Array = []
	catcher.touched_player.connect(func(body: Node2D) -> void: cold_hits.append(body))
	var dropper := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	dropper.position = Vector2(8200.0, 0.0) # 顶边线上方 285 px（盒底在 15）
	rig.add_child(dropper)
	TimeManager.notify_movement_intent(true)
	await _frame(1)
	var guard := 0
	while cold_hits.is_empty() and guard < 240:
		guard += 1
		await get_tree().physics_frame
	_check("世界冻着时掉进带子照样被判死（第 %d 拍接到人，此时 y=%s）"
		% [guard, str(snappedf(dropper.global_position.y, 0.01))],
		cold_hits.size() == 1 and cold_hits[0] == dropper)
	TimeManager.notify_movement_intent(false)
	dropper.queue_free()
	rig.queue_free()
	TimeManager.reset_state()
	await _frame(3)

	# —— ④ 生产链：这张网要能在真关卡里把死亡送回最近那台存档点 ——
	var root = _make_world_root()
	# 带子必须在关卡进树**之前**就挂进子树：_bind_hazards() 是在 _ready() 里按契约信号扫全树的，
	# 事后 add_child 的网它看不见 —— 这条正是「摆进场景树即生效，零接线」那个口径。
	# 整环摆到半空：存档点那一排只能摆在 x 650~900（fixture 的名字按 x 取），而第 5 节那块
	# 地面的顶边正落在 y=0 —— 不抬起来，人在 B 上是站着而不是在掉，这张网也就没东西可接。
	# 必须在进树之前一次摆好：事后搬关卡根，物理服务器会在同一拍里把 Area2D 搬上去而玩家的
	# 刚体变换还留在旧位置，那一拍读到的重叠是假的 —— 人凭空被判死，本组第一跑就是这么红的。
	var ring := _build_checkpoint_ring(root, 240.0, OVER_VOID)
	var terminals: Array = ring["terminals"]
	var walker: Player = ring["hero"]
	await _frame(2)
	walker.global_position = Vector2(800.0, OVER_VOID.y - Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("掉下去之前先踩住 B", terminals[1].is_active and _active_count(terminals) == 1)
	guard = 0
	while not walker.is_dead and guard < 240:
		guard += 1
		await get_tree().physics_frame
	_check("坠落把这条命判掉（第 %d 拍，落到 y=%s 时接住）"
		% [guard, str(snappedf(walker.global_position.y, 0.01))], walker.is_dead)
	guard = 0
	while root.reload_calls == 0 and guard < 120:
		guard += 1
		await get_tree().physics_frame
	_check("演完死亡那一拍后委托的是 reload_level（保留 run_state 那条）", root.reload_calls == 1)
	_check("全程没有走 restart_level（那条按设计清空进度，是这次误诊的来源）",
		root.restart_calls == 0)
	_check("run_state 两个键都还留着",
		root.run_state.has("respawn_position") and root.run_state.has("respawn_marker"))
	var saved: Vector2 = root.run_state.get("respawn_position")
	_check("存下的那一格就在 B 那一列（不是英雄编辑期站的那一列）",
		absf(saved.x - 800.0) < 0.01 and absf(saved.y - (OVER_VOID.y - Player.COLLISION_HALF_HEIGHT)) < 8.0)

	(ring["level"] as Node).queue_free()
	await _frame(3)
	var ring2 := _build_checkpoint_ring(root, -1.0, OVER_VOID) # 新实例，不带网：这一次只看回灌
	var t2: Array = ring2["terminals"]
	var revived: Player = ring2["hero"]
	await _frame(3)
	_check("换了新的关卡实例，重生位正是 run_state 里记下的那一格（%s）" % str(saved),
		revived.spawn_point == saved)
	_check("重载后亮的还是那一台，且仍然只它一台", t2[1].is_active and _active_count(t2) == 1)
	root.queue_free()
	TimeManager.reset_state()
	await _frame(2)


## 第 16 组：刷卡门的拒绝提示（D53）。钉的全是"旁路写歪了画面不会响、要到试玩才露馅"那几件：
## 只闪一次而不是持续眨、它一个字都不碰闩锁链、脉冲在冻结里走得完、尸体不算玩家这条缝也接上了、
## 时长只有一个来源、门开完了不再报"你别过来"。像素不在这里验（D46 同规矩），
## 颜色那一对归 verify_kit 与 props.json 比对。
func _test_gate_denial() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	var rig := Node2D.new()
	rig.name = "DenialRig"
	add_child(rig)
	# fixture 摆在 x 9000 之外并自带地面：前面几组的地面最远到 6500，人在 9000 是坠着走的。
	var ground := _solid_box(Vector2(9600.0, 40.0), Vector2(1600.0, 80.0))
	var card := load("res://scenes/objects/key_pickup/key_pickup.tscn") \
		.instantiate() as KeyPickup
	card.name = "DenialCard"
	card.position = Vector2(9300.0, 0.0) # 离门远：先让他够不着，第 ⑦ 档才去捡
	var gate := load("res://scenes/objects/key_door/key_door.tscn") \
		.instantiate() as KeyDoor
	gate.name = "DenialGate"
	gate.position = Vector2(9600.0, 0.0)
	gate.key = NodePath("../DenialCard")
	rig.add_child(card)
	rig.add_child(gate)
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	var out_x := 9500.0  # 感应带 9560..9640，人在这里够不着门
	var in_x := 9565.0   # 带内、幕面（9584）之外：不穿墙，只站进感应带
	hero.position = Vector2(out_x, -Player.COLLISION_HALF_HEIGHT)
	add_child(hero)
	await _frame(3)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("开场：世界冻着、人在带外，灯不闪",
		TimeManager.is_time_frozen() and not gate.is_denial_showing())
	_check("人在带外待多久都不会闪", await _count_denial_edges(gate, 20) == 0)

	# —— ① 无卡进带：红起来，且它是**只读**的 ——
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	var settle := 0
	while not gate.is_denial_showing() and settle < 10:
		settle += 1
		await get_tree().physics_frame
	_check("无卡走进感应带即闪红（等的是重叠登记那几帧，不是脉冲本身）",
		gate.is_denial_showing())
	_check("拒绝是只读旁路：不锁移动、不消耗卡、幕一格不塌、门没闩",
		not hero.movement_locked and not card.held and not card.consumed
		and gate.curtain_rect().size.y == 96.0 and not gate.is_latched)

	# —— ② 脉冲在冻结里自己走完（接成世界 delta 的那一档会永远红着）——
	await _frame(45)
	_check("世界全程冻着，脉冲仍然自己收回去了",
		TimeManager.is_time_frozen() and not gate.is_denial_showing())
	# —— ③ 人还站在带里也不叠发：边沿触发，不是持续眨 ——
	_check("站着不动不会二次触发（边沿触发，离开才重新上弦）",
		await _count_denial_edges(gate, 60) == 0)
	# —— ④ 出去再进来：重新上弦，照样闪一次 ——
	hero.position = Vector2(out_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	_check("离开感应带再进来重新触发一次", await _count_denial_edges(gate, 40) == 1)

	# —— ⑤ 时长只有一个来源：把 denied_time 拉长，脉冲就跟着拉长 ——
	gate.denied_time = 2.0
	var step := 1.0 / float(Engine.get_physics_ticks_per_second())
	hero.position = Vector2(out_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(int(ceil(1.0 / step)))
	_check("denied_time 改成 2 s 后，1 s 时还在闪（写死 0.5 就在这里响）",
		gate.is_denial_showing())
	await _frame(int(ceil(1.5 / step)))
	_check("过了 2 s 才收回去", not gate.is_denial_showing())
	gate.denied_time = 0.5

	# —— ⑥ 尸体不触发红：感应带里第四个「尸体不算玩家」的缝 ——
	hero.is_dead = true
	hero.position = Vector2(out_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	_check("死在带里那一拍不闪红（与不刷卡同一条判据）",
		await _count_denial_edges(gate, 20) == 0)
	hero.is_dead = false

	# —— ⑦ 有卡进带：直接进闩锁链，红色不许插队 ——
	hero.position = Vector2(9300.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("先捡卡（后面几档都要它被持有）", card.held)
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_check("带卡进带不闪红，直接认卡", not gate.is_denial_showing() and card.consumed)
	_check("红色插不进闩锁链：移动被锁、演出已经开始", hero.movement_locked)
	var guard := 0
	while not gate.is_latched and guard < 120:
		guard += 1
		await get_tree().physics_frame
	_check("演出照旧跑完（D41 那条链一字未动）", gate.is_latched)

	# —— ⑧ 门开完了不再报"你别过来"：卡已消耗，没有 is_latched 早退就会常亮红 ——
	hero.position = Vector2(out_x, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	hero.position = Vector2(in_x, -Player.COLLISION_HALF_HEIGHT)
	_check("闩了之后再走进感应带不再闪红", await _count_denial_edges(gate, 30) == 0)

	TimeManager.notify_movement_intent(false)
	hero.queue_free()
	rig.queue_free()
	ground.queue_free()
	await _frame(3)


## 数「不在闪 → 在闪」这个上升沿出现了几次，跑满 frames 个物理帧。
## 只数上升沿才分得出"闪一次"与"一直红着"/"每帧重发"—— 后两种在 is_denial_showing()
## 的抽样读数上跟第一种长得一模一样，边沿计数不会。
func _count_denial_edges(gate: KeyDoor, frames: int) -> int:
	var edges := 0
	var was := gate.is_denial_showing()
	for i in frames:
		await get_tree().physics_frame
		var now := gate.is_denial_showing()
		if now and not was:
			edges += 1
		was = now
	return edges


## 坠落带 fixture：导出项在进树前赋好，`_ready()` 里的 `_rebuild()` 才按这一档建盒
## （与 D47 那台同一套时序口径）。宽度给窄一档，免得本组的三张网互相叠到别人身上。
func _fall_zone_instance(parent: Node, at: Vector2, width: float, depth: float) -> FallZone:
	var zone := load("res://scenes/objects/fall_zone/fall_zone.tscn") \
		.instantiate() as FallZone
	zone.position = at
	zone.width = width
	zone.depth = depth
	parent.add_child(zone)
	return zone


## 触发源 fixture：放在人踩不到的高度，本组只手动 `_set_pressed` 驱动，不碰物理重叠。
func _plate_instance(rig: Node, node_name: String, at: Vector2) -> ButtonPlate:
	var plate := load("res://scenes/objects/button_plate/button_plate.tscn") \
		.instantiate() as ButtonPlate
	plate.name = node_name
	plate.position = at
	rig.add_child(plate)
	return plate


## 活塞 fixture。速度与参照档位在这里钉死，不跟脚本默认值走（同 `_afterimage_instance` 的理由：
## 那几个数归摆图的人随时调，照默认值断言"伸出约 36 拍 / 收回约 9 拍"第二天就会红）。
## `trigger` 用相对路径且在进树前赋好：`_ready()` 里那次 `_reconnect_trigger()` 才解析得动。
func _piston_instance(rig: Node, source: ButtonPlate, node_name: String,
		at: Vector2, travel: Vector2) -> PistonBlock:
	var piston := load("res://scenes/objects/piston_block/piston_block.tscn") \
		.instantiate() as PistonBlock
	piston.name = node_name
	piston.position = at
	piston.travel_offset = travel
	piston.extend_speed = 128.0
	piston.retract_speed = 512.0
	piston.trigger = NodePath("../" + String(source.name))
	rig.add_child(piston)
	return piston


## 一块地形（layer 1），`at` = 盒中心。活塞的 collision_mask 写死 0，自己不会撞它；
## 这里的地形只用来给人一个"背后有墙"的停住处和脚下这条线。
func _solid_box(at: Vector2, size: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	var col := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	col.shape = rect
	body.add_child(col)
	body.position = at
	add_child(body)
	return body


## 三个存档点 + 一个玩家，摆在第 5 节那块地面（x 600~1800）上：不放祭坛、不放终点区，
## 第 14 组钉的两条都不该被别的编排掺和。节点名带 x，回灌那条断言才读得出来。
## net_at ≥ 0 时另铺一张坠落带（顶边线落在 y=net_at）；at 决定关卡根摆在哪 —— 第 15 组要用它
## 把整环挪到没有地面的半空。两件都必须在关卡进树**之前**做好：LevelBase._bind_hazards() 是在
## 自己的 _ready() 里按契约信号扫全子树的，事后 add_child 的构件它看不见；而事后搬关卡根，
## 物理服务器会在同一拍里把 Area2D 搬走、玩家的刚体变换还留在旧位置，那一拍读到的重叠是假的。
func _build_checkpoint_ring(parent: Node, net_at: float = -1.0, at: Vector2 = Vector2.ZERO) -> Dictionary:
	var level := load("res://scenes/levels/level_base.gd").new() as LevelBase
	level.start_with_ability = true
	level.position = at
	var terminals: Array = []
	for x in [700.0, 800.0, 900.0]:
		var terminal := load("res://scenes/objects/checkpoint/checkpoint.tscn") \
			.instantiate() as Checkpoint
		terminal.name = "A%d" % int(x)
		terminal.position = Vector2(x, 0.0)
		level.add_child(terminal)
		terminals.append(terminal)
	if net_at >= 0.0:
		var net := load("res://scenes/objects/fall_zone/fall_zone.tscn") \
			.instantiate() as FallZone
		net.name = "FallZone"
		net.position = Vector2(800.0, net_at)
		net.width = 1600.0
		level.add_child(net)
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.position = Vector2(650.0, -Player.COLLISION_HALF_HEIGHT)
	level.add_child(hero)
	parent.add_child(level)
	return {"level": level, "terminals": terminals, "hero": hero}


## 几台存档点当前是激活的 —— 第 14 组拿它钉「全关卡只一台亮」这条不变量。
func _active_count(terminals: Array) -> int:
	var active := 0
	for terminal in terminals:
		if (terminal as Checkpoint).is_active:
			active += 1
	return active


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


## Main 的替身：常驻根（world_root 组）+ get_run_state + 两条重载入口各自计数。
## 第 9、10 组都要一个关卡实例挂在「已经有 Main 在跑」的世界里；第 15 组要分清关卡
## 委托的是哪一条 —— reload_level 保留进度、restart_level 清空进度，只数一个就分不出来。
func _make_world_root():
	var stub = Node.new()
	var stub_script := GDScript.new()
	stub_script.source_code = """
extends Node
var run_state := {}
var reload_calls := 0
var restart_calls := 0
func get_run_state() -> Dictionary:
	return run_state
func reload_level() -> void:
	reload_calls += 1
func restart_level() -> void:
	restart_calls += 1
"""
	stub_script.reload()
	stub.set_script(stub_script)
	stub.add_to_group(&"world_root")
	add_child(stub)
	return stub


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
