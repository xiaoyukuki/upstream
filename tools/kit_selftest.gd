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
##    D55 起再加三钉：卡坐在公共底座上（在位态）、进身体即换空座、飞完不会自己装回满的。
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
##     上走不满行程 —— 于是挤压不发生，且顶住期间不攒位移。D63 起再加一档 f：反向档 rest_out
##     （进树即在满行程、踩下才收回、松开慢慢回，两档速度仍绑几何；冻结无旁路；多台 OR 原样）。
##     D64 起再加两档：**g 顶棚**（托举途中的三个过程读数：`is_standing()` 不逐帧翻、皮只挑一种
##     剪辑、`velocity.y` 恒 0；顶到棚后块走不满且贴脚底；他能蹲走自救），**h 借力跳**（被托着
##     时给起跳，前提那一钉先证明测的确实是"被托着"而不是地面）。
## 14) 粘性进度（D51）：祭坛「已耗」由游戏代码真的写进 run_state（不是守门替它写），
##     存档点全关卡只一台激活，且死亡重载后亮的还是死前那一台。
## 15) 坠落带（D52）：掉出世界这条路从无兜底改成有一根线 —— 带子只认玩家且一条命只发一次；
##     走的是**保留进度**的死亡重载而不是清空进度的主动重开，于是掉下去回的是最近那台存档点；
##     判据不吃世界 delta，冻着往下落照样被接住。
## 16) 刷卡门的拒绝提示（D53）：无卡走进感应带只闪**一次**（边沿触发，站着不动不叠发）；
##     它是只读旁路 —— 不锁移动、不消耗卡、幕一格不塌；有卡则直接进闩锁链，红色不许插队；
##     脉冲全程在世界冻结里跑得完（接成世界 delta 就永远红着）；尸体不触发；时长只有
##     `denied_time` 一个来源；闩了之后不再闪。
## 17) 彩蛋收集物（D54）：转的时钟只吃门控 delta（冻结即钉在当前角度），而捡起那一下与
##     飘起演出吃的是**原始** delta —— 冻着照样捡得到、捡了不会卡在半空。判定带不随姿态
##     缩（转扁的那一瞬间它不许变成捡不到的东西）；一圈换皮 4 次的序列与最扁那档 0.707
##     对着选型图核对 —— GDScript 与 Python 那份是同一道算式的两处书写，只改一边必须当场响。
##     本条命只发一次信号；回灌走 mark_taken（空座、不重播演出、不再发），且 run_state 记的
##     是身份（相对关卡根的 NodePath）而不是位置 —— 换关后鸭子挪了格子也还得是空的。
## 18) 开局苏醒的接线（D57）：整个进程只演一次 —— 关卡根在 _ready 里问常驻根要这一拍，
##     常驻根"取走即消耗"，第二张关卡实例（= 同进程里再进关，含死亡重载）就不再演，
##     进场的人身上也不该留着窗口里那把移动锁。窗口本身归 sprite_selftest 第 11 组。
## 19) 世界钟（D59）：全项目第一个纯装饰构件，所以只钉一条"改坏了不会响"的东西 ——
##     亮格必须是世界时钟的纯函数。当场独立重算比一次、冻结 20 拍一格不走（且世界时钟本身
##     也没涨，把"停"的归因钉在表上不是钟上）、解冻后接着走且不漂。
## 20) 能力获取那一拍（D61）：一张表抄在三处（帧表 / 祭坛 / 玩家），先对表 —— 时长、帧数、
##     举升曲线长度、核心进胸 == 爆发帧、青环散完 == 光柱散帧末、胸口一个定义、钉住窗口
##     折算 1.25 s。再走真接线：踩祭坛即把这一拍交给玩家（两边进度同源）、爆发那一帧钉住
##     世界而那一拍自己照推进（D44 时钟法在钉住窗口里仍成立）、钉住宽度 == 4/16。最后撒手
##     落点三种组合各钉一次（能力开×按、能力关×按、能力开×不按）—— 只清开关不接状态机的
##     写法不报错也不红，只有"醒完发现世界永久冻着"这一种手感。
## 21) 祭坛那次自动存档（D62，裁定「只写重生位、不给灯」）：走生产链钉四条 —— 第一次获得能力
##     那一拍演完时重生位换成**他落脚那一格**（不是存档点那一格，也不是祭坛原点）；
##     之前那台存档点被顶灭、`respawn_marker` 整个抹掉（留着下次重载会点亮一台已经不成立的台）；
##     跳着撞进触发带的那一次**不存**（写进去的是一格空气），而且落地之后也不补写。
##     这一组故意不给祭坛灯：它不发 `checkpoint_reached`，所以"没台亮着"这条要能被钉住。
## 22) 时间锚点（D68）：一次一根、E 强回收、目标的时间源跟玩家的手而不是世界钟 ——
##     发射键的瞄准/出膛链通着；出膛只认实体、非锚点族撞上即收；吸附中第二发无效；
##     按着方向键时世界冻着目标照走，人站着时世界流着目标照停；撒手当帧就停、不等
##     世界那道 0.08 s 缓冲；E 当帧断链、目标立刻回世界钟且相位不被清；回执亮格是 wound
##     的纯函数（纯装饰）；回程不理碰撞，目标被释放从最后一格收回；死亡断链、复活回手上，
##     全程不进 run_state。
## 23) 相位器件（D69）：这一族的行为矩阵一共六行，把「平时受世界钟、被锚吸住时跟手」
##     这条分界整个钉住 —— 未吸附时世界流着它自己开合、世界冻着它停；吸附后人站着
##     世界流着它照停、按着方向键世界冻着它照走；移动中回收当帧停衰、站着回收立刻
##     回世界钟且相位不清零。另钉四件"改坏了不响"的：幽灵态也打得到（底座常实）、
##     变实前问占位（玩家/层 4 挡住就停在旧状态）、相切不误判（探针内缩 1 px）、
##     period 0 与 duty 0/1 两个极端。
## 24) 心电监护屏（D75）：第二件纯装饰构件，时序那三条照第 19 那只钟的口径 —— 相位 == 当场
##     独立重算的 f(世界时钟)（fixture 晚进树，自带累加器的写法在这里露馅）、冻结 20 拍相位
##     不动且世界时钟本身也没涨（连 `_shown` 也不漂）、解冻后接着推且不漂。另钉皮两条：
##     推一格就换图、推满一圈回到同一张（1536 格与落盘瓦片逐格比色那半边在 verify_kit，
##     只有它读得到纹理），以及 `beat_period=0` 时世界在流也钉在相位 0。
## 25) 假墙盖（D76）：第三件零契约表现件，时基却与前两件**相反** —— 它不许读世界钟（横按方向键
##     即冻世界，照时钟揭幕会在人正朝它走的时候停住）。这一组在真帧上钉六条：开局人就在屋里 →
##     第一拍就是全隐（不是先亮一下再淡）；远/中/近三档按 near/far 落位；同一站位世界流着 20 拍
##     不动（位置纯函数）；世界冻着也一样；人走进自家格子中间那一下不许被重新盖住；场上没有
##     玩家时盖回全挡。静态那一半（z 层 / 碰撞开关 / 逐格实心格 / 源码禁令）在 verify_kit。
## 26) 梦泡新手引导（D77）：开局那一拍钉在睡姿上、**不按就不醒**（用户裁定，没有超时后门）。
##     四只各认一个动作、各破一次（重复按不双计）、三只破完不发 completed、四只破完且最后一发
##     的三帧演完才发一次；completed 之后交回的是**现成**那条 2.45 s 苏醒路径，不是第二套"醒"。
##     另钉两条只有叠上去才看得出的：这一拍里踩上刺不判死（引导不许演到一半人没了 —— 而
##     `take_intro()` 早已消费，死了也不重演），以及对照组"撤掉之后同一把刺真的会杀"。
##
## 跑法：Godot --headless --path <项目根> res://tools/kit_selftest.tscn

const TAG := "[kit-selftest]"
const BLOCK_ANCHOR := Vector2(500, -200)
const PHASE_PANEL_SCENE := "res://scenes/objects/phase_panel/phase_panel.tscn"
const PHASE_SHUTTLE_SCENE := "res://scenes/objects/phase_shuttle/phase_shuttle.tscn"
## 第 15 组生产链用：把整个关卡实例抬到半空，脚下才算真的没有底。
## 不抬不行 —— 第 5 节那块地面的顶边正好落在 y=0、铺满 x -800..3200，存档点那一排（x 650~900）
## 就摆在它上面，人在那儿是"站着"，坠不出东西给网接。
const OVER_VOID := Vector2(0.0, -600.0)
## 「贴着他的后缘/脚底」这一类断言的容差（D64）。量的是容差而不是零，因为 `_resolve` 把构件
## 夹到与玩家**相切**，而 StaticBody2D 与玩家长期相切时物理引擎会做小幅分离松弛：
## 实测沿行程轴 5560.04 → 峰值 5560.11 → 5559.9517，约 25 拍收敛（同 D48 那根「−5e-6 px
## 是浮点残差不是陷进去」的口径，只是这次量更大）。这条钉杀的是"攒位移 / 吃进身体"那两类
## 真错，不钉那 0.1 px 的抖。
const SQUEEZE_DRIFT_PX := 0.25

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
	await _test_collectible()
	await _test_wake_intro()
	await _test_world_clock()
	await _test_grant_d61()
	await _test_altar_save()
	await _test_time_anchor()
	await _test_phase_devices()
	await _test_ecg_monitor()
	await _test_cave_cover()
	await _test_dream_bubbles()

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
	# D55：卡坐在公共底座上。这条必须在放人之前读 —— 人一生成就压在卡上，在位态当场就没了。
	_check("开场：卡坐在底座上（D55 的在位态）", card.seat_occupied())

	var gate_col := gate.get_node("CollisionShape2D") as CollisionShape2D
	var gate_rect := gate_col.shape as RectangleShape2D

	var courier := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	courier.position = Vector2(2500.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(courier)
	await _frame(3)
	_check("玩家踩上卡即拾取（接触判定不吃世界 delta）", card.held)
	_check("卡进了身体 → 座子立刻换成空座（D55 的皮跟着状态走）", not card.seat_occupied())

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
	_check("飞完之后原地只剩空座，不会自己装回满的（D55）", card.consumed and not card.seat_occupied())
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


## 第 13 组：活塞踏板（D49）。六档各钉一条"改坏了不会响、只有试玩才露馅"的：
## a) 一组两块接同一个按钮（多对一合法），冻结即停在当前伸出量上、松开只记意图；
## b) 收回明显快过伸出 —— 伸得慢到踩按钮的人跟得上，收得快到站不住；
## c) 收回把落脚点从脚下抽干：人自己掉回地面，不是被方块带着沉进地里；
## d) 行程上有人就**挤开**他；他背后有墙则他自己被挡住、方块跟着停在接触面上走不满行程，
##    且顶住期间不攒位移（脱困那一帧不会攒出一发弹射）。
## e) 一块接两台按钮（D60）：合成是 OR —— 任一台按下就伸出，**全**松开才收回。这一档存在的理由
##    是那条最省事的写法（把信号参数直接抄进 `is_out`）：A 还踩着、B 一松就把人脚下的路抽掉。
## f) 反向档 rest_out（D63）：换的只有"电平映射到哪一头"那一行 —— 进树即在满行程（瞬落）、
##    踩下才收回、松开慢慢回；两档速度仍绑几何（收回快过伸回）、冻结无旁路、多台 OR 原样，
##    只是"任一台按下"说的是收回。
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
	var wall := _piston_instance(rig, [plate], "Wall", Vector2(5000.0, -32.0), Vector2(64.0, 0.0))
	var twin := _piston_instance(rig, [plate], "Twin", Vector2(5000.0, -200.0), Vector2(64.0, 0.0))
	_check("两块活塞接到同一个按钮（「一组」就是多对一，刻意不查重）",
		wall._bound.size() == 1 and wall._bound[0] == plate
		and twin._bound.size() == 1 and twin._bound[0] == plate)
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
	var riser := _piston_instance(rig2, [plate2], "Riser", Vector2(5300.0, 0.0), Vector2(0.0, -64.0))
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
	var pusher := _piston_instance(rig3, [plate3], "Pusher",
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
	var end_held: float = pusher.block_rect().end.x
	var x_held: float = hero.global_position.x
	await _frame(30)
	# 容差而不是零，理由见 `SQUEEZE_DRIFT_PX`。这条钉杀的是"攒位移"：积分器真漏了会走出好几像素、
	# 脱困那一帧弹出一发。
	_check("顶住 30 拍不攒位移（位置读回实际值，脱困那一帧不会攒出一发弹射）",
		absf(pusher.block_rect().end.x - end_held) < SQUEEZE_DRIFT_PX
		and absf(hero.global_position.x - x_held) < SQUEEZE_DRIFT_PX)

	hero.queue_free()
	rig3.queue_free()
	await _frame(2)

	# —— e：一台活塞接两台按钮（D60 多台 OR 合成）。这一档钉的是"最后一个信号说了算"那个
	##    最容易写出来的错版本：A 还踩着、B 一松就缩。——
	var rig4 := Node2D.new()
	rig4.name = "MultiRig"
	add_child(rig4)
	var plate_a := _plate_instance(rig4, "PlateA", Vector2(5700.0, -400.0))
	var plate_b := _plate_instance(rig4, "PlateB", Vector2(5760.0, -400.0))
	var multi := _piston_instance(rig4, [plate_a, plate_b], "Multi",
		Vector2(5700.0, -32.0), Vector2(64.0, 0.0))
	_check("两台按钮都接进来了（_bound 是列表）", multi._bound.size() == 2)
	_check("都没踩 → 不伸出", not multi.is_out)
	plate_a._set_pressed(true)
	_check("A 踩下即伸出", multi.is_out)
	plate_b._set_pressed(true)
	_check("B 也踩下，仍然伸出", multi.is_out)
	plate_a._set_pressed(false)
	_check("A 松开而 B 还踩着 → 不许缩（这一条杀掉「最后一个信号说了算」）", multi.is_out)
	plate_b._set_pressed(false)
	_check("两台全松开才收回", not multi.is_out)
	var dup: Array[NodePath] = [NodePath("../PlateA"), NodePath("../PlateA")]
	multi.triggers = dup
	_check("同一台按钮填两格只算一台（列内查重）", multi._bound.size() == 1)
	plate_a._set_pressed(true)
	_check("查重之后照样驱动得动", multi.is_out)
	var left: Array[NodePath] = [NodePath("../PlateB")]
	multi.triggers = left
	_check("A 还踩着但已出列 → 不再由它伸出（换列时按当前值重算，不留在旧结论上）", not multi.is_out)
	plate_b._set_pressed(true)
	_check("留在列里的那台照样能驱动", multi.is_out)
	plate_b._set_pressed(false)
	_check("A 还踩着却已出列：B 一松就收回（出列的那台不参与合成）", not multi.is_out)
	# 触发源在活塞进树**之前**就已按下：连接时读一次 `is_pressed` 兜种，不该漏成"没踩"。
	plate_a._set_pressed(true)
	var seeded := _piston_instance(rig4, [plate_a], "Seeded",
		Vector2(5800.0, -32.0), Vector2(64.0, 0.0))
	_check("已按下的触发源：起手就是伸出态（读当前值而不是等信号）", seeded.is_out)
	rig4.queue_free()

	# —— f：反向档 `rest_out`（D63：常态停在满行程，踩下才收回）。这一档要钉的是"换一头当常态"
	##    到底换了几格 —— 只该换电平→位那一行映射，积分器、两档速度、OR 合成全都原样跟着走。
	##    所以断言的形状与普通档对称，只是朝向反过来。——
	var rig5 := Node2D.new()
	rig5.name = "RestRig"
	add_child(rig5)
	var plate_r := _plate_instance(rig5, "PlateR", Vector2(5900.0, -400.0))
	var bridge := _piston_instance(rig5, [plate_r], "Bridge",
		Vector2(5900.0, -32.0), Vector2(64.0, 0.0), true)
	_check("反向块进树那一拍就在满行程（瞬落，不是从洞里爬出来）",
		is_equal_approx(bridge.progress(), 1.0))
	_check("没人踩着 = 停在常态那一头：is_out 真而电平假（这两格分得开才叫反向档）",
		bridge.is_out and not bridge._level)
	plate_r._set_pressed(true)
	_check("踩下即转入收回（异或翻面：电平真而 is_out 假）", bridge._level and not bridge.is_out)
	var retract_r := 0
	while bridge.progress() > 0.0 and retract_r < 300:
		retract_r += 1
		await get_tree().physics_frame
	_check("踩下真的收到洞里（反向档的「收回」由按下触发，走完落在伸出量 0）",
		bridge.progress() == 0.0)
	plate_r._set_pressed(false)
	_check("松开转回常态那一头", bridge.is_out)
	var extend_r := 0
	while bridge.progress() < 1.0 and extend_r < 300:
		extend_r += 1
		await get_tree().physics_frame
	# 先格式化再拼接：`%` 比 `+` 结合得紧，写成 "a" + "b" % [...] 只作用于后半截字面量，
	# 前半截那两个 %d 会原样印出来（这一条第一次跑就是这么露馅的）。
	var beat := "%d 拍 vs %d 拍" % [retract_r, extend_r]
	_check("松开慢慢回伸，且收回明显快过伸回（" + beat
		+ "：两档速度绑的是几何，不是「踩下 / 松开」那两档输入）",
		bridge.progress() == 1.0 and retract_r * 2 < extend_r)
	# 冻结里照样钉住：反向档不许自带旁路。
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	plate_r._set_pressed(true)
	await _frame(8)
	_check("冻结中踩下只改朝向、不改伸出量（世界钉住时这块一格不挪）",
		is_equal_approx(bridge.progress(), 1.0) and not bridge.is_out)
	TimeManager.notify_movement_intent(false)
	plate_r._set_pressed(false)
	guard = 0
	while bridge.progress() < 1.0 and guard < 300:
		guard += 1
		await get_tree().physics_frame
	# 反向档下的多台合成：口径仍是 OR，只是"任一台按下"说的是收回。
	var plate_r2 := _plate_instance(rig5, "PlateR2", Vector2(5960.0, -400.0))
	var pair: Array[NodePath] = [NodePath("../PlateR"), NodePath("../PlateR2")]
	bridge.triggers = pair
	_check("反向档换的是映射不是合成：两台都松开时停在伸出态",
		bridge._bound.size() == 2 and bridge.is_out and is_equal_approx(bridge.progress(), 1.0))
	plate_r._set_pressed(true)
	plate_r2._set_pressed(true)
	guard = 0
	while bridge.progress() > 0.0 and guard < 300:
		guard += 1
		await get_tree().physics_frame
	plate_r._set_pressed(false)
	await _frame(6)
	_check("一台松开而另一台还踩着 → 不许伸回来（D60 那条最省事的错写法在反向档下同样致命："
		+ "伸回来的那一头正是人脚下的落脚点）", not bridge.is_out and bridge.progress() == 0.0)
	plate_r2._set_pressed(false)
	_check("两台全松开才转入伸回去", bridge.is_out)

	# —— g：头顶有棚那一档（D64）。用户报的两件事都出在这一档：上升途中皮在 jump/idle 之间
	##    一闪一闪，以及头一碰到棚人就卡死。所以这一档量的不是"最后到没到"，而是**过程中的读数**：
	##    「脚有着落」不许逐帧翻、`_pick()` 挑出的剪辑不许换过、被托着时不攒落速。——
	var rig6 := Node2D.new()
	rig6.name = "CeilingRig"
	add_child(rig6)
	var plate_g := _plate_instance(rig6, "PlateG", Vector2(6200.0, -400.0))
	var lift := _piston_instance(rig6, [plate_g], "Lift", Vector2(6200.0, 0.0), Vector2(0.0, -64.0))
	# 棚底落在 y=-80：站高 30 时块走到 0.78 行程他就顶到，蹲高 15 时顶不到（65 > 64）。
	_solid_box(Vector2(6200.0, -100.0), Vector2(400.0, 40.0))
	# 地面往右再接一段：h 那一档的活塞摆在 6800，原来那块只铺到 6500。
	_solid_box(Vector2(6700.0, 20.0), Vector2(600.0, 40.0))
	var climber := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	climber.position = Vector2(6200.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(climber)
	# 读 `_pick()` 而不是 `animation`：皮真正在放哪一支要等 `_process` 过一遍，而这里等的是
	# 物理帧 —— 读前者是"这一拍该放哪一支"，与调度顺序无关，正是用户报的那一闪本身。
	var skin := climber.get_node("Visual/Sprite") as PlayerVisual
	await _frame(4)
	plate_g._set_pressed(true)
	var flips := 0
	var bad_vy := 0
	var clips := {}
	var was_standing := climber.is_standing()
	var g_frames := 0
	while lift.progress() < 1.0 and g_frames < 120:
		g_frames += 1
		await get_tree().physics_frame
		var st: bool = climber.is_standing()
		if st != was_standing:
			flips += 1
		was_standing = st
		if climber.is_carried() and not is_zero_approx(climber.velocity.y):
			bad_vy += 1
		clips[skin._pick()] = true
	_check("整段托举 %d 拍：「脚有着落」一次都没翻（D64 把它收成唯一读法 is_standing()）" % g_frames,
		flips == 0 and was_standing)
	_check("托举期间剪辑只挑出过一种（%d 种）—— 用户报的那一闪就是它变成两种" % clips.size(),
		clips.size() == 1)
	_check("被托着的每一拍落速都归零（不攒重力：攒下发 0.15 px 下探会被引擎整段弹回来）",
		bad_vy == 0)
	_check("顶到棚之后块走不满行程（%d 拍停在 %.3f）—— 保住 D49：构件侧不加第二条判定"
		% [g_frames, lift.progress()],
		lift.progress() > 0.5 and lift.progress() < 1.0)
	_check("他被棚挡住时前缘仍贴着他的脚底、不吃进身体",
		absf(lift.block_rect().position.y - climber.collision_rect().end.y) < SQUEEZE_DRIFT_PX
		and not lift.block_rect().intersects(climber.collision_rect()))
	Input.action_press(&"move_down")
	await _frame(6)
	_check("顶住那一档他蹲得下来（D64② 的自救入口全在 Player 那侧）",
		climber.is_crouching and not climber.is_head_blocked)
	g_frames = 0
	while lift.progress() < 1.0 and g_frames < 120:
		g_frames += 1
		await get_tree().physics_frame
	_check("蹲下去块就还能走完（人变矮这一条白送，活塞不为此改一行）",
		lift.progress() == 1.0)
	Input.action_release(&"move_down")
	await _frame(6)
	_check("松手而他站着会顶进棚 → 保持蹲着不硬起身",
		climber.is_crouching and climber.is_head_blocked)
	Input.action_press(&"move_right")
	g_frames = 0
	while absf(climber.global_position.y + Player.COLLISION_HALF_HEIGHT) > 1.5 and g_frames < 200:
		g_frames += 1
		await get_tree().physics_frame
	Input.action_release(&"move_right")
	_check("蹲着能从他脚下走开、掉回地面重新站起来（%d 拍到 x=%.0f）—— 自救走的是这一条，"
		% [g_frames, climber.global_position.x]
		+ "构件侧一条判定都没加",
		g_frames < 200 and not climber.is_crouching and not climber.is_head_blocked
		and climber.global_position.x > 6240.0
		and absf(climber.global_position.y + Player.COLLISION_HALF_HEIGHT) < 1.5)

	# —— h：借力跳（D64④）。放在没有棚的一段上：顶棚那一档起跳会被棚拦掉，测不到"给不给跳"。——
	var rig7 := Node2D.new()
	rig7.name = "JumpRig"
	add_child(rig7)
	var plate_h := _plate_instance(rig7, "PlateH", Vector2(6800.0, -400.0))
	var spring := _piston_instance(rig7, [plate_h], "Spring",
		Vector2(6800.0, 0.0), Vector2(0.0, -64.0))
	climber.global_position = Vector2(6800.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	var jumps: Array = []
	# 数信号得往数组里塞：GDScript 的 lambda 按**值**捕获局部变量，`jumps += 1` 改的是副本，
	# 计数器永远停在 0（本组 506 行那几条同样是这个理由）。
	climber.jumped.connect(func() -> void: jumps.append(1))
	plate_h._set_pressed(true)
	g_frames = 0
	while spring.progress() < 0.3 and g_frames < 60:
		g_frames += 1
		await get_tree().physics_frame
	_check("起跳前他正被托着（这条不成立下面那条就是测了个空）",
		climber.is_carried())
	Input.action_press(&"jump")
	# 三拍而不是一拍：`Input.action_press` 排进去的事件要在**下一次**主循环 flush 才成为
	# just_pressed，只等一拍等于在他按下之前的那一拍里读跳跃（sprite_selftest 那几条同理按 4 拍）。
	await _frame(3)
	Input.action_release(&"jump")
	_check("托举途中按跳跃真的起跳（D64④：被托着算站着，所以这一档放行 = 多发借力跳，%d 发 vy=%.1f）"
		% [jumps.size(), climber.velocity.y],
		jumps.size() == 1 and climber.velocity.y < 0.0)
	climber.queue_free()
	rig6.queue_free()
	rig7.queue_free()
	rig5.queue_free()
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


## 第 17 组：彩蛋收集物（D54）。钉的全是"这只鸭子转得不像批过的那张图"和"死一次不许复生"
## 两条最容易静默弄死的通路：
## ① 转只吃门控 delta —— 冻结即钉在当前角度上；
## ② 判定带不随姿态缩、且尺寸只有一个来源（外接框 + `PICKUP_MARGIN`，期望值从零件纹理现算）；
## ③ 冻着也捡得到、飘起那半秒在冻结里自己走完 —— 两条时钟通道**刻意**不同，接错一根的两种
##    露馅样子分别是"按着方向键就捡不到"和"捡了卡在半空不淡掉"；
## ④ 一圈换皮 4 次的序列、最扁 0.707、镜像只在下半圈的侧脸：Python 选型图那道算式的另一处
##    书写，只改一边必须在这里响，而不是等玩家看出鸭子转得跟批过的不一样；
## ⑤ 本条命只发一次信号；`mark_taken()` 是"结果"不是"再演一遍"；生产链里 sticky 的是
##    **身份**（相对关卡根的 NodePath）而不是位置 —— 换关后鸭子挪了格子也还得是空的。
func _test_collectible() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	var rig := Node2D.new()
	rig.name = "DuckRig"
	add_child(rig)
	# fixture 摆在 x 11000 之外：前面几组的地面最远到 9600+800，鸭子不该站在别人的地上。
	var ground := _solid_box(Vector2(11600.0, 40.0), Vector2(1600.0, 80.0))
	var duck := load("res://scenes/objects/collectible/collectible.tscn") \
		.instantiate() as Collectible
	duck.name = "Duck"
	duck.position = Vector2(11200.0, 0.0)
	rig.add_child(duck)
	await _frame(6)
	_check("世界流动时鸭子在转", duck.spin_angle() > 0.0)

	# —— ② 判定带与零件尺寸无关（D38 那条口径在转台上再验一次）——
	var col: CollisionShape2D = duck.get_node("CollisionShape2D")
	var band_size: Vector2 = col.shape.size
	var band_center: Vector2 = col.position
	await _frame(60) # 3 s 的行程走了大半圈：正脸 → 挤扁的侧脸 → 背面
	_check("转的过程中带子一格没缩（转扁那一瞬不许变成捡不到的东西）",
		col.shape.size == band_size and col.position == band_center)
	var sprite_h := float(Collectible.TEX_DUCK_FRONT.get_height() + Collectible.TEX_PERCH_IDLE.get_height())
	var margin := float(Collectible.PICKUP_MARGIN)
	var want_size := Vector2(float(Collectible.TEX_PERCH_IDLE.get_width()) + margin * 2.0,
		sprite_h + margin * 2.0)
	_check("带子 = 底座宽 x (鸭+座) 高各外扩 PICKUP_MARGIN（%s）" % str(want_size),
		band_size == want_size)
	_check("带心在外接框中心、下沿只探出地面 4 px（裁定③ 订正：不是脚底那条带，也不钻到地板下）",
		absf(band_center.y + sprite_h * 0.5) < 0.01
		and absf((band_center.y + band_size.y * 0.5) - margin) < 0.01)

	# —— ① + ③ 冻着：角度钉住，但捡得起、飘得完 ——
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var frozen_angle: float = duck.spin_angle()
	var hits: Array = []
	duck.collectible_taken.connect(func() -> void: hits.append(1))
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.position = Vector2(11140.0, -Player.COLLISION_HALF_HEIGHT)
	rig.add_child(hero)
	await _frame(3)
	_check("开场：世界冻着、人在带外，一个信号都没有",
		hits.is_empty() and TimeManager.is_time_frozen())
	hero.position = Vector2(11200.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(4)
	_check("冻着走进带里照样捡到手（判据不吃世界 delta，D38 第 4 条同口径）",
		hits.size() == 1 and duck.is_spent())
	var guard := 0
	while duck.fly_progress() >= 0.0 and guard < 60:
		guard += 1
		await get_tree().physics_frame
	_check("飘起演出在冻结里自己走完了（第 %d 拍收）" % guard, duck.fly_progress() < 0.0)
	_check("整段冻结里角度一分一毫没动（%.4f vs %.4f）" % [frozen_angle, duck.spin_angle()],
		duck.spin_angle() == frozen_angle)

	# —— ⑤a 本条命只发一次：出去再进来不许复生 ——
	hero.position = Vector2(11140.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	hero.position = Vector2(11200.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(8)
	_check("离开再进来不再发第二次（spent 闩锁，重置只属于关卡重载）", hits.size() == 1)
	_check("再踩空座不重播飘起演出", duck.fly_progress() < 0.0)
	TimeManager.notify_movement_intent(false)
	await _frame(20)
	_check("解冻后鸭子从钉住处接着转（角度重新推进）", duck.spin_angle() != frozen_angle)

	# —— ⑤b 回灌那一头：mark_taken 直接空座，不重播、不发信号 ——
	var ghost := load("res://scenes/objects/collectible/collectible.tscn") \
		.instantiate() as Collectible
	ghost.name = "Ghost"
	ghost.position = Vector2(11400.0, 0.0)
	rig.add_child(ghost)
	await _frame(2)
	var ghost_hits: Array = []
	ghost.collectible_taken.connect(func() -> void: ghost_hits.append(1))
	ghost.mark_taken()
	await _frame(2)
	_check("mark_taken 即空座：spent 置真、不重播演出、不发信号",
		ghost.is_spent() and ghost.fly_progress() < 0.0 and ghost_hits.is_empty())
	hero.position = Vector2(11400.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(6)
	_check("走过这只已回灌的空座也拿不到第二次", ghost_hits.is_empty())

	# —— ④ 转台 B 档那道算式（对着 preview_duck_spin.png 核对，像素本身归 verify_kit）——
	var samples := 360
	var seq: Array[int] = []
	var min_f := 2.0
	var max_f := -2.0
	var mirrored_upper := 0
	for i in samples:
		var theta := float(i) * TAU / float(samples)
		var v := Collectible.pick_view(theta)
		if seq.is_empty() or seq.back() != v:
			seq.append(v)
		var f := Collectible.pick_factor(theta)
		min_f = minf(min_f, f)
		max_f = maxf(max_f, f)
		if Collectible.pick_mirror(theta) and theta < PI:
			mirrored_upper += 1
	_check("一圈换皮 4 次、顺序正脸→侧脸→背面→侧脸", seq == [0, 1, 2, 1, 0])
	_check("四个轴向各对准一张皮（0/90/180/270 度 = 正/侧/背/侧）",
		[Collectible.pick_view(0.0), Collectible.pick_view(PI * 0.5),
			Collectible.pick_view(PI), Collectible.pick_view(PI * 1.5)] == [0, 1, 2, 1])
	_check("最扁 0.707（±45° 那档，用户批 B 档时看到的数字：%.4f）" % min_f,
		min_f >= 0.70 and min_f < 0.71)
	_check("对准轴心时一点都不挤（max=%s）" % str(snappedf(max_f, 0.001)),
		absf(max_f - 1.0) < 0.001)
	_check("镜像只在下半圈的侧脸（少这一句鸭子会倒着游）",
		mirrored_upper == 0 and Collectible.pick_mirror(PI * 1.5)
		and not Collectible.pick_mirror(PI))

	hero.queue_free()
	rig.queue_free()
	await _frame(3)
	var strays := get_tree().get_nodes_in_group(&"player")
	_check("进生产链之前场上清空（%d 个残留玩家）" % strays.size(), strays.is_empty())

	# —— ⑤c 生产链：踩一次即写进常驻根，换关后按路径回灌成空座 ——
	var root = _make_world_root()
	var level := load("res://scenes/levels/level_base.gd").new() as LevelBase
	level.start_with_ability = true
	var duck_a := load("res://scenes/objects/collectible/collectible.tscn") \
		.instantiate() as Collectible
	duck_a.name = "Duck"
	duck_a.position = Vector2(11200.0, 0.0)
	level.add_child(duck_a)
	var walker := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker.position = Vector2(11100.0, -Player.COLLISION_HALF_HEIGHT)
	level.add_child(walker)
	add_child(level)
	await _frame(3)
	walker.position = Vector2(11200.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(4)
	var logged: Array = root.run_state.get("collectibles_taken", [])
	_check("游戏代码真的把它记进了 run_state（不是守门替它写）", logged.size() == 1)
	_check("记的是相对关卡根的身份，不是位置", logged[0] == NodePath("Duck"))
	level.queue_free()
	await _frame(3)
	# 新实例：这只鸭子摆在**另一格**上 —— 认路径不认位置，它照样必须是空的。
	var level2 := load("res://scenes/levels/level_base.gd").new() as LevelBase
	level2.start_with_ability = true
	var duck_b := load("res://scenes/objects/collectible/collectible.tscn") \
		.instantiate() as Collectible
	duck_b.name = "Duck"
	duck_b.position = Vector2(11500.0, 0.0)
	level2.add_child(duck_b)
	var walker2 := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker2.position = Vector2(11400.0, -Player.COLLISION_HALF_HEIGHT)
	level2.add_child(walker2)
	add_child(level2)
	await _frame(3)
	var reborn_hits: Array = []
	duck_b.collectible_taken.connect(func() -> void: reborn_hits.append(1))
	_check("新关卡实例里那只已按 run_state 回灌成空座（挪了格子也认得它）", duck_b.is_spent())
	walker2.position = Vector2(11500.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(6)
	_check("复生之后走过它拿不到（死一次不许复生），清单也不叠一条",
		reborn_hits.is_empty() and logged.size() == 1)
	level2.queue_free()
	root.queue_free()
	ground.queue_free()
	TimeManager.reset_state()
	await _frame(2)


## 第 18 组：开局苏醒的接线（D57 裁定 D2 = 整个进程只演一次）。
## 窗口里那些"掐输入、皮只播 wake、到点自己撒手"归 sprite_selftest 第 11 组，这一组只管
## 三件事：谁问（关卡根 _ready）、谁答（常驻根 take_intro 取走即消耗）、答完之后不许再答。
## ② 那条是 D51「有读没人写」的反面写法：标志翻过去发生在常驻根身上，关卡连"演过了"
##    这个布尔都拿不到，所以它没有忘记写回的机会 —— 表现是每关开局都躺一遍。
func _test_wake_intro() -> void:
	var leftovers := get_tree().get_nodes_in_group(&"player")
	_check("开跑前场上没有残留玩家（%d 个）" % leftovers.size(), leftovers.is_empty())
	var root = _make_world_root()
	root.intro_enabled = true

	var first := _build_mini_level(root)
	var sleeper: Player = first["walker"]
	await _frame(2)
	_check("本次进程第一次进关：人进入苏醒窗口（waking=%s）" % str(sleeper.is_waking()),
		sleeper.is_waking())
	_check("窗口里移动锁挂上（B2「整段掐输入」的落地方式就是 D41 那把锁）",
		sleeper.movement_locked)
	_check("「演过了」记在常驻根身上，不在关卡里", bool(root.intro_played))

	(first["level"] as Node).queue_free()
	await _frame(3)
	var second := _build_mini_level(root)
	var awake: Player = second["walker"]
	await _frame(2)
	_check("同一进程里换第二张关卡实例就不再演（waking=%s）" % str(awake.is_waking()),
		not awake.is_waking())
	_check("第二次进关的人一进场就没有移动锁（别把上一关的演出赖在他身上）",
		not awake.movement_locked)
	root.queue_free()
	await _frame(2)


## 第 19 组：世界钟（D59）。这只构件零契约、零机制，所以"改坏了不会响"的只有一条：
## 它不再是世界时钟的纯函数。三钉全对着这一条，而且都是当场能算的：
## ① 亮格 == 独立重算的 f(elapsed_world_time) —— 这条看着像同义反复，其实钉的是"自带累加器"
##    那条退路：fixture 是在世界时钟已经走了很久之后才进树的，自己从 0 累加的实现在这里
##    就对不上（那条实现数值上确实也跟冻结停、也跟帧率无关，唯一露馅的就是这个起点偏移）；
## ② 冻结 20 拍亮格一字不动，而且世界时钟本身也没涨 —— 后者把"停"的归因钉在表上而不是钟上；
## ③ 解冻后接着走，并且再与 f(世界时钟) 对一次 —— 停过之后不许漂。
## `period` 在这里钉死成 0.4 s（一格 ≈ 2 拍），不跟脚本默认值 8.0 走：默认值归摆图的人随时调，
## 照它断言"等 N 拍就一定换格"第二天就会红（D58 那条同一个坑）。
func _test_world_clock() -> void:
	TimeManager.set_ability_enabled(true)
	var clock := load("res://scenes/objects/clock/clock.tscn").instantiate() as WorldClock
	clock.period = 0.4
	clock.position = Vector2(1400.0, -300.0)
	add_child(clock)
	# 先把世界时钟跑开一段再比。上一组（第 18 组）那张迷你关卡在 `_ready()` 里 `reset_state()`
	# 过，此刻 `elapsed_world_time` 才 0.1 s —— 世界时钟与"节点自己从 0 累加"的起点差就落在
	# 一格（0.4/12 s）以内，①那条就抓不到它。等 40 拍 = 差出 6 格，退路才真的堵死。
	await _frame(40)
	var ticks: int = clock.TICKS
	var want := int(fmod(TimeManager.elapsed_world_time / clock.period, 1.0) * float(ticks)) % ticks
	_check("亮格 == 当场独立重算的 f(世界时钟)（%d 对 %d）" % [clock.segment_index(), want],
		clock.segment_index() == want)

	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var frozen: int = clock.segment_index()
	var t0: float = TimeManager.elapsed_world_time
	await _frame(20)
	_check("冻结 20 拍，亮格一格没走（%d 还是 %d）" % [frozen, clock.segment_index()],
		clock.segment_index() == frozen)
	_check("亮格没走是因为世界时钟没涨（%s → %s）" % [str(t0), str(TimeManager.elapsed_world_time)],
		TimeManager.elapsed_world_time == t0)

	TimeManager.notify_movement_intent(false)
	var waited := 0
	while clock.segment_index() == frozen and waited < 60:
		await _frame(1)
		waited += 1
	_check("解冻后接着走（等了 %d 拍）" % waited, clock.segment_index() != frozen)
	want = int(fmod(TimeManager.elapsed_world_time / clock.period, 1.0) * float(ticks)) % ticks
	_check("停过之后不漂：亮格仍然 == f(世界时钟)（%d 对 %d）" % [clock.segment_index(), want],
		clock.segment_index() == want)
	clock.queue_free()
	await _frame(2)


## 第 20 组：能力获取那一拍（D61）。这一组的主体不是行为，是**一张表抄在三处**：帧表
## （grant 剪辑 16 帧 / 3.2 fps）、祭坛（`grant_time` 与那三个分数）、玩家（`GRANT_FRAMES` /
## `GRANT_BURST_FRAME` / `GRANT_PIN_FRAMES` / `GRANT_LIFT` / `CHEST_Y`）。抄错的地方不崩、
## 不报错，只是皮与举升曲线在某一帧悄悄错开半拍 —— 属于"要逐帧盯着回放才露馅"那类，
## 所以先把表对完（一条帧都不等），再走真接线。
## 真接线钉三条：① 踩上祭坛就是把这一拍交给玩家，两边进度是同一条式子的两处书写；
## ② 世界被钉在冻结里那一拍照样推进（D44 那条时钟法在 D61 的钉住窗口里仍然成立）、
##    钉住宽度就是 `GRANT_PIN_FRAMES` 那 4/16（A3 的 1.25 s 由它折算）；
## ③ 撒手那一刻的落点必须跟着**当时的意图与能力门控**走 —— 三种组合各钉一次（见
##    `_grant_release_case`），因为最容易静默退化的正是这里：`set_frozen_override(false)`
##    只清开关，于是能力没开的人醒完发现世界永久冻着，而它一个字也不报错。
func _test_grant_d61() -> void:
	# —— ① 对表 ——
	var slime := load("res://assets/player/slime_frames.tres") as SpriteFrames
	var clip_frames: int = slime.get_frame_count(&"grant")
	var clip_len: float = float(clip_frames) / slime.get_animation_speed(&"grant")
	var altar := load("res://scenes/objects/ability_altar/ability_altar.tscn") \
		.instantiate() as AbilityAltar
	_check("时长同源：祭坛默认 grant_time == grant 剪辑长度（%.2f 对 %.2f）"
		% [altar.grant_time, clip_len], is_equal_approx(altar.grant_time, clip_len))
	_check("核心进胸那一帧 == 爆发那一帧（%.4f 对 %.4f）" % [AbilityAltar.FLY_END,
		float(Player.GRANT_BURST_FRAME) / float(Player.GRANT_FRAMES)],
		is_equal_approx(AbilityAltar.FLY_END,
			float(Player.GRANT_BURST_FRAME) / float(Player.GRANT_FRAMES)))
	# 「青环散完 == 光柱散帧最后一帧」那条对表钉随那三枚环一起删掉（2026-09-29 用户裁定去掉环）。
	# 散开那一档现在只有 `GrantBeams.DISOLVE_FRAMES` 一个书写者，没有第二处可对照 ——
	# 若哪天又给"散完"立第二个常量（不管叫什么），这条位置就该重新钉一次。
	_check("胸口只有一个定义（祭坛引用玩家那一份，不留第二份）",
		is_equal_approx(AbilityAltar.CHEST_Y, Player.CHEST_Y))
	_check("钉住窗口按默认 grant_time 折算 ≈ 1.25 s（A3）",
		is_equal_approx(float(Player.GRANT_PIN_FRAMES) / float(Player.GRANT_FRAMES) * altar.grant_time,
			1.25))
	altar.free()
	_check("帧数同源：Player.GRANT_FRAMES == 剪辑帧数（%d 对 %d）"
		% [Player.GRANT_FRAMES, clip_frames], Player.GRANT_FRAMES == clip_frames)
	_check("举升曲线有几帧就有几张图（%d 对 %d）" % [Player.GRANT_LIFT.size(), Player.GRANT_FRAMES],
		Player.GRANT_LIFT.size() == Player.GRANT_FRAMES)

	# —— ② 真接线 ——
	var world_root = _make_world_root()
	var rig := _build_mini_level(self)
	var walker: Player = rig["walker"]
	var alt: AbilityAltar = rig["altar"] as AbilityAltar
	# 缩短到 1.6 s：守门不为等演出白耗两秒。窗口边界全按帧比例落，所以下面量的是进度宽度
	# 而不是秒数 —— 换总长不该把这一组改红。
	alt.grant_time = 1.6
	await _frame(2)

	var beams: GrantBeams = null
	for child: Node in walker.get_children():
		if child is GrantBeams:
			beams = child as GrantBeams
	_check("光柱构件挂在玩家身上（代码建的子节点，为的是不动 player.tscn）", beams != null)
	if beams != null:
		var visual := walker.get_node("Visual") as Node2D
		_check("光柱排在 Visual 之前 = 画在他背后（%d 对 %d）" % [beams.get_index(), visual.get_index()],
			beams.get_index() < visual.get_index())

	TimeManager.set_ability_enabled(true)
	walker.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("踩上祭坛即把这一拍交给玩家（窗口在玩家身上，不在构件里）", walker.is_granting())
	# 一帧的错位是节点顺序带来的（祭坛是人之外的先处理方），所以给 0.02 = 两帧的余量：
	# 这条钉的是"两边同一条式子"，不是"两边同一拍"。
	_check("祭坛与玩家进度同源（差 %.3f）" % absf(alt.grant_progress() - walker.grant_progress()),
		absf(alt.grant_progress() - walker.grant_progress()) < 0.02)

	var guard := 0
	while not TimeManager.is_frozen_overridden() and guard < 200:
		guard += 1
		await _frame(1)
	_check("爆发那一帧把世界钉住（等了 %d 拍）" % guard, TimeManager.is_frozen_overridden())
	var pin_from: float = walker.grant_progress()
	var pinned_t: float = TimeManager.elapsed_world_time
	await _frame(6)
	_check("钉住期间那一拍自己仍在推进（吃的不是世界 delta）", walker.grant_progress() > pin_from)
	_check("钉住期间世界时间一字不涨（%s → %s）"
		% [str(pinned_t), str(TimeManager.elapsed_world_time)],
		TimeManager.elapsed_world_time == pinned_t)
	guard = 0
	while TimeManager.is_frozen_overridden() and guard < 200:
		guard += 1
		await _frame(1)
	_check("钉住到点自己撒手（钉了 %d 拍）" % guard, not TimeManager.is_frozen_overridden())
	var pin_width: float = walker.grant_progress() - pin_from
	_check("钉住宽度 == 4/16 整拍（实测 %.3f）" % pin_width, absf(pin_width - 0.25) < 0.05)
	guard = 0
	while walker.is_granting() and guard < 400:
		guard += 1
		await _frame(1)
	_check("整拍演完自己解锁（等了 %d 拍）" % guard, not walker.is_granting())
	_check("窗口过后没把移动锁留在身上", not walker.movement_locked)
	_check("被举起来的人最后回到地面上", walker.is_on_floor())

	# —— ③ 撒手落点的三种组合 ——
	var case_open_key: int = await _grant_release_case(walker, true, true)
	_check("能力开着 + 按着方向键 → 撒手后世界仍冻着（实测 %d）" % case_open_key, case_open_key == 1)
	var case_shut_key: int = await _grant_release_case(walker, false, true)
	_check("能力还没开 + 按着方向键 → 撒手后世界是流的（实测 %d；只清开关的写法在这里会永久冻住）"
		% case_shut_key, case_shut_key == 0)
	var case_open_idle: int = await _grant_release_case(walker, true, false)
	_check("能力开着 + 站着没动 → 撒手后世界是流的（实测 %d）" % case_open_idle, case_open_idle == 0)

	(rig["level"] as Node).queue_free()
	world_root.queue_free()
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	await _frame(2)


## 撒手落点 fixture：起一整拍，在钉住窗口里按需按住方向键，等它自己撒手，回来报撒手那一拍
## 的冻结态（1=冻、0=流、-1=没等到窗口，调用方按 FAIL 读）。三种组合全从这里过：只会退回
## FLOWING 的在「开+按」露馅，只会退回 FROZEN 的在「关+按」露馅，不看意图只看能力的在
## 「开+不按」露馅。整拍走完之前不动输入 —— 窗口还开着就松手，把锁与意图的归因搅在一起。
func _grant_release_case(walker: Player, ability_on: bool, key_held: bool) -> int:
	if key_held:
		Input.action_press(&"move_right")
	# 关能力那一下顺带 `reset_state()`，正好把上一例的残留清掉（能力开着时它是空操作，
	# 所以两种情况都得自己等到窗口走完）。
	TimeManager.set_ability_enabled(ability_on)
	walker.begin_grant(1.6)
	var guard := 0
	while not TimeManager.is_frozen_overridden() and guard < 200:
		guard += 1
		await _frame(1)
	if not TimeManager.is_frozen_overridden():
		if key_held:
			Input.action_release(&"move_right")
		return -1
	guard = 0
	while TimeManager.is_frozen_overridden() and guard < 200:
		guard += 1
		await _frame(1)
	var frozen_now: int = 1 if TimeManager.is_time_frozen() else 0
	guard = 0
	while walker.is_granting() and guard < 400:
		guard += 1
		await _frame(1)
	if key_held:
		Input.action_release(&"move_right")
	await _frame(2)
	return frozen_now


## 第 21 组：祭坛那次自动存档（D62，裁定「只写重生位、不给灯」）。四条钉全走生产链，
## 而且都落在「有读必须有写」那本账上（D51/D52 的教训：守门手写那个键会把"根本没人写"整个盖住）：
## ① 演完那一刻重生位换成**他落脚那一格** —— 不是存档点那一格（3100）、也不是祭坛原点（3000）
##    那个死坐标；② 之前那台被顶灭，`respawn_marker` 整个抹掉；③ 跳着撞进触发带的那一次不存；
## ④ 落地之后也不补写（下降沿已经过去，那一格空气永远进不了账）。
func _test_altar_save() -> void:
	# 先清掉上一组的人：本组要用 get_first_node_in_group 挑玩家（LevelBase 那道闸就是这么认人的）。
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(3)

	var stub = _make_world_root()
	var rig := _build_mini_level(stub)
	var walker: Player = rig["walker"]
	var terminal: Checkpoint = rig["checkpoint"]
	await _frame(3)
	# —— ① 先给这具身体一个"旧的家"，否则「旧台被顶灭」那句断言是空的（本来就没亮过）。 ——
	# Area2D 的重叠登记要几拍（D53 那条坑），所以下面每一处等待都是轮询带上限，不死等帧数。
	var guard := 0
	walker.global_position = Vector2(3100.0, -Player.COLLISION_HALF_HEIGHT)
	guard = 0
	while not terminal.is_active and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：先踩一台存档点，它亮着且身份进了 run_state",
		terminal.is_active and stub.run_state.has("respawn_marker"))
	var old_pos: Vector2 = stub.run_state.get("respawn_position")
	# —— ② 站上祭坛（人是站着的，不是跳进来的）。 ——
	walker.global_position = Vector2(3000.0, -Player.COLLISION_HALF_HEIGHT)
	guard = 0
	while not walker.is_granting() and guard < 30:
		guard += 1
		await _frame(1)
	_check("踩上去即进入授予那一拍", walker.is_granting())
	guard = 0
	while walker.is_granting() and guard < 400:
		guard += 1
		await _frame(1)
	await _frame(3)
	var saved_pos: Vector2 = stub.run_state.get("respawn_position", Vector2.ZERO)
	_check("演完即由游戏代码把重生位换成他落脚那一格（x≈3000，不是存档点那格 3100）",
		not walker.is_granting() and absf(saved_pos.x - 3000.0) < 2.0 and saved_pos != old_pos)
	_check("存的就是他此刻站着的那一点（同一格，不是抄来的坐标）",
		(stub.run_state.get("respawn_position") as Vector2).distance_to(walker.global_position) < 2.0)
	# —— ③ 不给灯的代价：一台都不亮，身份键整条抹掉。 ——
	_check("旧那台被顶灭（亮 = 现在死会回到这儿，而重生位已被祭坛接走）",
		not terminal.is_active and _active_count([terminal]) == 0)
	_check("respawn_marker 抹掉而不是留着（留着 = 下次重载点亮一台已经不成立的台）",
		not stub.run_state.has("respawn_marker"))
	(rig["level"] as Node).queue_free()
	stub.queue_free()
	await _frame(3)

	# —— ④ 跳着撞进触发带的那一次不许存：新 rig（祭坛一次性），从空中掉进带里。 ——
	var stub2 = _make_world_root()
	var rig2 := _build_mini_level(stub2)
	var diver: Player = rig2["walker"]
	diver.global_position = Vector2(3000.0, -160.0)
	guard = 0
	while not diver.is_granting() and guard < 120:
		guard += 1
		await _frame(1)
	_check("前提：空中也会撞上触发带（带心在地板以上，跳着进来照样触发祭坛）",
		diver.is_granting())
	guard = 0
	while diver.is_granting() and guard < 400:
		guard += 1
		await _frame(1)
	await _frame(3)
	_check("跳着撞进来的那一次不写重生位（写进去的是一格空气）",
		not stub2.run_state.has("respawn_position"))
	# 落地之后再看一眼：下降沿已经过去，不该有第二次机会补写。
	guard = 0
	while not diver.is_on_floor() and guard < 240:
		guard += 1
		await _frame(1)
	await _frame(3)
	_check("他随后落回地面也不补写（那一发只认下降沿）",
		diver.is_on_floor() and not stub2.run_state.has("respawn_position"))
	(rig2["level"] as Node).queue_free()
	stub2.queue_free()
	await _frame(2)


## 第 22 组：时间锚点（D68）。只走生产入口 —— 玩家身上那根 `TimeAnchor` + 真实 Input 动作，
## 不直接调 `_attach()`。最容易「改坏了不响」的四件事：① 时间源跟的是玩家的手，不是世界钟；
## ② 吸附/回收不碰目标自己的相位；③ E 当帧断链（目标立刻回世界钟）；④ 回程不理碰撞。
func _test_time_anchor() -> void:
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(3)

	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	# 两项能力自 D73 起各自独立，这一组两样都要开：冻结那一项给"世界停了它还在走"当背景，
	# 锚点那一项才是发射/供时的门。只开一项的组合在下面那两条否定式里各钉一次。
	TimeManager.set_anchor_enabled(true)

	var walker := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker.position = Vector2(100.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(walker)
	var block := load("res://scenes/objects/moving_block/moving_block.tscn").instantiate() as MovingBlock
	block.position = Vector2(300.0, -32.0)
	block.travel_offset = Vector2(0.0, -96.0)
	add_child(block)
	await _frame(3)

	var anchor: TimeAnchor = walker.time_anchor()
	var receiver: TimeReceiver = block.get_node("TimeReceiver") as TimeReceiver
	_check("锚挂在玩家身上、开局在手上；方块在 anchorable 族里且挂着 TimeReceiver",
		anchor != null and anchor.current_state() == TimeAnchor.State.IDLE
		and not anchor.has_link() and block.is_in_group(&"anchorable") and receiver != null)

	# —— ① 发射键的整条链：按住瞄准、松开出膛。落点由鼠标决定，这里只验"真的打出去了"。 ——
	Input.action_press(&"anchor")
	await _frame(3)
	_check("按住发射键进入瞄准", anchor.is_aiming())
	Input.action_release(&"anchor")
	var fired := false
	var guard := 0
	while guard < 40:
		guard += 1
		await _frame(1)
		if anchor.current_state() != TimeAnchor.State.IDLE:
			fired = true
		elif fired:
			break
	_check("松开即发射，飞完/收回之后回到手上", fired
		and anchor.current_state() == TimeAnchor.State.IDLE)

	# —— ② 两道能力闸各钉一次（D73：锚点与冻结是两件事；谁把两处读回同一个旗标就在这里红）。 ——
	TimeManager.set_anchor_enabled(false)
	_check("锚点那一项关着 → 连出膛都不允许（此时冻结那一项仍开着）",
		not anchor.fire_toward(Vector2.RIGHT) and TimeManager.is_ability_enabled)
	TimeManager.set_anchor_enabled(true)
	TimeManager.set_ability_enabled(false)
	# 冻结关着、锚点开着、人正按着方向键：发得出锚，而世界**没有**冻 —— 这一钉是"分离"这件事
	# 本身的钉子。少了它，把两处读回同一个旗标不会响，只会让锚点悄悄退回祭坛的赠品。
	Input.action_press(&"move_right")
	await _frame(3)
	var fired_shut: bool = anchor.fire_toward(Vector2.RIGHT)
	var world_flows: bool = not TimeManager.is_time_frozen()
	Input.action_release(&"move_right")
	# 松手那一下要等一次主循环 flush 才成边沿（本项目踩过两次的那条）。能力关着时它被静音，
	# 所以在这里就等掉 —— 留到下面"世界冻着起飞"那一窗，它会把刚钉住的世界解回去，
	# 于是方块在 0.08 s 缓冲里多走一段，红的是那条相位钉而不是这里。
	await _frame(3)
	_check("锚点开着 + 冻结关着 + 按着方向键 → 发得出（%s）且世界是流的（%s）"
		% [str(fired_shut), str(not world_flows)], fired_shut and world_flows)
	anchor.reset_state()
	TimeManager.set_ability_enabled(true)

	# 世界冻着起飞：飞行只吃真实 delta，目标那一整段没人能推 —— 吸附前后读到同一个相位，
	# 「吸附不碰它自己的相位」才有干净对照。
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_anchor_reset_target(block)
	# 给一个**非零且显眼**的相位：吸附若偷偷把它清回 0，下面那条断言当场红。
	block.elapsed_path_time = 5.0
	var phase_before: float = block.elapsed_path_time
	_check("在射程内出手，锚出膛", anchor.fire_toward(Vector2.RIGHT)
		and anchor.current_state() == TimeAnchor.State.OUTBOUND)
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("飞行段命中锚点族：吸附在方块上", anchor.current_state() == TimeAnchor.State.ATTACHED
		and anchor.attached_target() == block)
	_check("吸附不碰目标自己的相位（没被清回 0；实测 %.3f vs %.3f，世界 %s）" % [
			block.elapsed_path_time, phase_before,
			"FROZEN" if TimeManager.is_time_frozen() else "FLOWING"],
		block.elapsed_path_time == phase_before and phase_before > 0.0)
	_check("锚插在目标身上（跟着目标原点走）",
		anchor.global_position.distance_to(block.global_position) < block.block_size.x)

	# —— ③ 一次一根：吸附中再按发射键什么都不发生（连瞄准线都不该出现）。 ——
	_check("吸附中第二发无效", not anchor.fire_toward(Vector2.RIGHT))
	Input.action_press(&"anchor")
	await _frame(3)
	Input.action_release(&"anchor")
	_check("吸附中按发射键不改状态、不进入瞄准",
		anchor.current_state() == TimeAnchor.State.ATTACHED and not anchor.is_aiming())

	# —— ④ 供时：世界冻着、手上有方向 → 锚点物照走；世界流着、人站着 → 照停。
	#       正反两面合起来才排得掉「其实吃的是世界 delta」这条假绿。
	Input.action_press(&"move_right")
	guard = 0
	while receiver.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	var pos_before: Vector2 = block.global_position
	var phase_pumped: float = block.elapsed_path_time
	var wound_before: float = anchor.receipt_wound()
	_check("世界冻着、按着方向键：锚点物拿到真实 delta",
		TimeManager.is_time_frozen() and receiver.get_physics_delta() > 0.0)
	await _frame(10)
	_check("同一段里方块真的在走、相位与回执一起涨",
		block.global_position.distance_to(pos_before) > 1.0
		and block.elapsed_path_time > phase_pumped and anchor.receipt_wound() > wound_before)

	# 回执是纯装饰：亮格是 wound 的纯函数，改它不反向影响时间源。四个可读档比一份抄来的算式好懂。
	var live_wound: float = anchor.receipt_wound()
	var probe_ok := true
	for sample in [
		[0.0, 0],
		[TimeAnchor.RECEIPT_PERIOD * 0.5, int(float(TimeAnchor.RECEIPT_TICKS) * 0.5)],
		[TimeAnchor.RECEIPT_PERIOD, 0],
		[TimeAnchor.RECEIPT_PERIOD * 1.25, int(float(TimeAnchor.RECEIPT_TICKS) * 0.25)],
	]:
		anchor.set("_wound", sample[0])
		probe_ok = probe_ok and anchor.receipt_index() == sample[1]
	anchor.set("_wound", live_wound)
	_check("回执相位：0 圈 → 0 格、半圈 → 6 格、整圈归零、1.25 圈 → 3 格", probe_ok)
	await _frame(2)
	_check("回执只是装饰：拧它的相位不会停掉时间源",
		receiver.get_physics_delta() > 0.0 and anchor.receipt_wound() > live_wound)

	# —— ⑤ 撒手当帧就停：不等世界那道 0.08 s 缓冲。等世界真的流起来、人还站着，
	#       它照样不动 —— 这一条才把「跟手」与「跟世界」分开。 ——
	Input.action_release(&"move_right")
	await _frame(3)
	_check("撒手后锚点物立刻不再吃 delta", receiver.get_physics_delta() == 0.0)
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：松手缓冲走完，世界重新在流动", TimeManager.get_physics_delta() > 0.0)
	var pos_still: Vector2 = block.global_position
	var phase_still: float = block.elapsed_path_time
	var wound_still: float = anchor.receipt_wound()
	await _frame(10)
	_check("世界流着、人站着：锚点物照旧不动（时间源跟的是手，不是世界钟）",
		receiver.get_physics_delta() == 0.0 and block.global_position == pos_still
		and block.elapsed_path_time == phase_still and anchor.receipt_wound() == wound_still)

	# —— 移动锁（苏醒/授予那一拍的现成读法）：锁一上，手上有方向也不供时。 ——
	Input.action_press(&"move_right")
	guard = 0
	while receiver.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	walker.movement_locked = true
	await _frame(1)
	_check("移动锁掐住手：锚点物立刻停", receiver.get_physics_delta() == 0.0)
	walker.movement_locked = false
	await _frame(1)
	_check("解锁后接着供时（锁不是一次性开关）", receiver.get_physics_delta() > 0.0)
	Input.action_release(&"move_right")
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)

	# —— ⑥ E 强回收：当帧断链，目标立刻回世界钟；回程只是视觉，相位不被清。 ——
	var phase_at_recall: float = block.elapsed_path_time
	Input.action_press(&"interact")
	await _frame(3)
	Input.action_release(&"interact")
	_check("E 回收：状态转回程、链接当帧断开", anchor.current_state() == TimeAnchor.State.RETURNING
		and not anchor.has_link() and anchor.attached_target() == null)
	await _frame(2)
	_check("回收后目标立刻回世界钟（世界流着，它自己接着走）",
		receiver.get_physics_delta() > 0.0 and block.elapsed_path_time > phase_at_recall)
	_check("回收不清目标相位（不是回到 0 重新开始）", block.elapsed_path_time > 0.0)
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("回程到手上：回 IDLE", anchor.current_state() == TimeAnchor.State.IDLE
		and anchor.global_position.distance_to(
			walker.global_position + Vector2(0.0, Player.CHEST_Y)) < 1.0)

	# —— ⑦ 飞行中 E、撞墙、非锚点族的实体、打空：都回手上，且都不产生链接。 ——
	_check("对准天空出膛", anchor.fire_toward(Vector2.UP))
	await _frame(3)
	_check("前提：这一发还在飞", anchor.current_state() == TimeAnchor.State.OUTBOUND)
	Input.action_press(&"interact")
	await _frame(3)
	Input.action_release(&"interact")
	_check("半路 E 收回：没有吸附任何东西", not anchor.has_link()
		and anchor.current_state() != TimeAnchor.State.OUTBOUND)
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("半路收回的锚回到手上", anchor.current_state() == TimeAnchor.State.IDLE
		and not anchor.has_link())

	var wall := _solid_box(Vector2(260.0, -18.0), Vector2(2.0, 40.0))
	await _frame(1)
	_check("射线上立一堵 2 px 的墙", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("撞墙不吸附、自动收回（2 px 也不穿）",
		anchor.current_state() == TimeAnchor.State.IDLE and not anchor.has_link())
	wall.queue_free()
	await _frame(2)

	var door := load("res://scenes/objects/door/door.tscn").instantiate() as Door
	door.position = Vector2(220.0, 0.0)
	add_child(door)
	await _frame(2)
	_check("非锚点族的实体（门）挡在射线上", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("门不当锚点：不吸附、自动收回",
		anchor.current_state() == TimeAnchor.State.IDLE and not anchor.has_link())
	door.queue_free()
	await _frame(2)

	_check("朝脚下发射", anchor.fire_toward(Vector2.DOWN))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("地面不是锚点族：不吸附、自动收回",
		anchor.current_state() == TimeAnchor.State.IDLE and not anchor.has_link())

	# —— ⑧ 回程不理碰撞：吸附后在人跟目标之间立一堵墙，E 回收照样穿过来。 ——
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_anchor_reset_target(block)
	_check("再出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("前提：这一发吸附成功", anchor.current_state() == TimeAnchor.State.ATTACHED)
	var return_wall := _solid_box(Vector2(200.0, -18.0), Vector2(8.0, 40.0))
	await _frame(1)
	Input.action_press(&"interact")
	await _frame(3)
	Input.action_release(&"interact")
	_check("回收转回程（墙拦不住链路断开）", anchor.current_state() != TimeAnchor.State.ATTACHED
		and not anchor.has_link())
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("回程穿过挡在中间的墙回到手上", anchor.current_state() == TimeAnchor.State.IDLE
		and anchor.global_position.distance_to(
			walker.global_position + Vector2(0.0, Player.CHEST_Y)) < 1.0)
	return_wall.queue_free()
	await _frame(2)

	# —— ⑨ 死亡当帧断链：被锚着的构件不能拖着一根指向尸体的 Callable 进重载。 ——
	_anchor_reset_target(block)
	_check("再出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	Input.action_press(&"move_right")
	guard = 0
	while receiver.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：吸附中按着方向键，目标在供时", receiver.get_physics_delta() > 0.0)
	walker.die(0.2)
	await _frame(2)
	_check("死亡当帧清链接：锚回手上、目标回世界钟（世界被死亡钉住）",
		anchor.current_state() == TimeAnchor.State.IDLE and not anchor.has_link()
		and receiver.get_physics_delta() == 0.0 and TimeManager.is_frozen_overridden())
	var phase_death: float = block.elapsed_path_time
	await _frame(6)
	_check("死后目标不再吃锚点的 delta（相位钉住）", block.elapsed_path_time == phase_death)
	Input.action_release(&"move_right")
	await _frame(2)
	walker.respawn()
	TimeManager.reset_state()
	await _frame(2)
	_check("复活后锚在手上、人也不在死亡态", anchor.current_state() == TimeAnchor.State.IDLE
		and not walker.is_dead and not anchor.has_link())

	# —— ⑩ 目标被释放：从最后一格插槽转回程，不留在原地当一根野锚。 ——
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_anchor_reset_target(block)
	_check("再出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("前提：这一发吸附成功", anchor.current_state() == TimeAnchor.State.ATTACHED)
	var socket: Vector2 = anchor.global_position
	block.queue_free()
	guard = 0
	while anchor.current_state() == TimeAnchor.State.ATTACHED and guard < 10:
		guard += 1
		await _frame(1)
	_check("目标没了：锚从最后一格转回程（不报错、不留在半空）",
		anchor.current_state() == TimeAnchor.State.RETURNING and not anchor.has_link()
		and socket.distance_to(anchor.global_position) < 80.0)
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_check("目标没了也照样回到手上", anchor.current_state() == TimeAnchor.State.IDLE
		and not anchor.has_link())

	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(2)
	TimeManager.reset_state()


## 第 23 组：相位器件（D69）。六行行为矩阵 + 四条安全/边界，见文件头第 23 条。
## 全部走生产入口：真实 Input 动作驱动玩家、真实 TimeManager 冻结、真实锚点射线。
## 器件里唯一直接碰的内部量是 `_clock`（与第 22 组碰 `elapsed_path_time` 同一口径：
## 守门要读的是"表走没走"，不是它怎么走的）。
func _test_phase_devices() -> void:
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(3)

	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	# 这一组跑的是"吸附之后跟手"，所以锚点那一项也得单独开（D73 起它不再跟着冻结那一项来）。
	TimeManager.set_anchor_enabled(true)

	_solid_box(Vector2(1500.0, 300.0), Vector2(4000.0, 600.0))
	var walker := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	walker.position = Vector2(1000.0, -Player.COLLISION_HALF_HEIGHT)
	add_child(walker)
	# 两个器件都挂在同一条地面线上方 10 px：16 px 厚的盒子占 y -26..-10，
	# 站着的人的胸高是 -18 —— 平地横打刚好打在盒子里（真关卡里对着脚下的桥面往下瞄）。
	var panel = _phase_instance(PHASE_PANEL_SCENE, "Panel", Vector2(1300.0, -18.0),
		0.5, 0.5, 0.0)
	var shuttle = _phase_instance(PHASE_SHUTTLE_SCENE, "Shuttle", Vector2(1800.0, -18.0),
		0.5, 0.5, 0.0)
	await _frame(3)

	var anchor: TimeAnchor = walker.time_anchor()
	var panel_rx: TimeReceiver = panel.get_node("TimeReceiver") as TimeReceiver
	var shuttle_rx: TimeReceiver = shuttle.get_node("TimeReceiver") as TimeReceiver
	_check("器件进了 anchorable 族、挂着 TimeReceiver，锚在手上",
		panel.is_in_group(&"anchorable") and shuttle.is_in_group(&"anchorable")
		and panel_rx != null and shuttle_rx != null
		and anchor.current_state() == TimeAnchor.State.IDLE)

	# —— ① 未吸附 + 世界流着：自己走表、状态自己翻。 ——
	var clock_flowing: float = panel.get("_clock")
	await _frame(10)
	_check("世界流着：未吸附的面板自己走表",
		panel.get("_clock") > clock_flowing and shuttle.get("_clock") > clock_flowing)
	var saw_on := false
	var saw_off := false
	var guard := 0
	while guard < 40:
		guard += 1
		await _frame(1)
		saw_on = saw_on or panel.is_on()
		saw_off = saw_off or not panel.is_on()
	_check("世界流着：未吸附的面板自己开合（两态都真的到过）", saw_on and saw_off)

	# —— ② 未吸附 + 世界冻着：表不走、状态不翻、位置不动。 ——
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("前提：有移动意图即世界冻结", TimeManager.is_time_frozen())
	var clock_frozen: float = panel.get("_clock")
	var shuttle_clock_frozen: float = shuttle.get("_clock")
	var panel_on_frozen: bool = panel.is_on()
	var shuttle_pos_frozen: Vector2 = shuttle.global_position
	await _frame(20)
	_check("世界冻着：未吸附的器件表不走、状态不翻、块不挪",
		panel.get("_clock") == clock_frozen
		and shuttle.get("_clock") == shuttle_clock_frozen
		and panel.is_on() == panel_on_frozen
		and shuttle.global_position == shuttle_pos_frozen)
	TimeManager.notify_movement_intent(false)
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：松开缓冲走完，世界重新流动", TimeManager.get_physics_delta() > 0.0)

	# —— ③ 幽灵态也打得到：桥面关着，底座那 32x16 还在，锚点射线不会穿过去打空。 ——
	_phase_force(panel, false)
	await _frame(2)
	_check("前提：面板此刻是关的（只有底座实）", not panel.is_on())
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("对准关着的面板出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("桥面虚着也能吸附（底座常实，射线打在壳上）",
		anchor.current_state() == TimeAnchor.State.ATTACHED
		and anchor.attached_target() == panel and not panel.is_on())

	# —— ④ 吸附 + 人站着、世界流着：表不走（时间源跟手，不跟世界钟）。 ——
	TimeManager.notify_movement_intent(false)
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：世界流着、人站着", TimeManager.get_physics_delta() > 0.0)
	var clock_attached_idle: float = panel.get("_clock")
	await _frame(10)
	_check("吸附中、人站着：世界流着但器件不吃世界钟",
		panel_rx.get_physics_delta() == 0.0
		and panel.get("_clock") == clock_attached_idle)

	# —— ⑤ 吸附 + 按着方向键、世界冻着：表照走、状态照翻（手把器件推过边界）。 ——
	panel.period = 0.5
	panel.duty = 0.5
	panel.phase = 0.0
	panel.set("_clock", 0.34)
	panel._refresh_state(panel.cycle_on())
	await _frame(2)
	_check("前提：面板停在关窗口的后半段（再走 0.16 s 才翻）", not panel.is_on())
	Input.action_press(&"move_right")
	guard = 0
	while panel_rx.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("世界冻着、按着方向键：锚着的面板拿到真实 delta",
		TimeManager.is_time_frozen() and panel_rx.get_physics_delta() > 0.0)
	var clock_crank: float = panel.get("_clock")
	await _frame(3)
	_check("手上的 delta 在推进器件的表", panel.get("_clock") > clock_crank)
	guard = 0
	while not panel.is_on() and guard < 30:
		guard += 1
		await _frame(1)
	_check("按着方向键：面板在自己的窗口里变实（手推过了边界）", panel.is_on())

	# —— ⑥ 撒手当帧停；世界那道 0.08 s 缓冲走完之后也不许它偷偷跟世界钟。 ——
	Input.action_release(&"move_right")
	await _frame(3)
	_check("撒手当帧停：锚着时不等世界那道 0.08 s 缓冲",
		panel_rx.get_physics_delta() == 0.0)
	var clock_released: float = panel.get("_clock")
	await _frame(10)
	_check("撒手后器件的表不再走", panel.get("_clock") == clock_released)
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	_check("前提：松手缓冲走完，世界重新在流动", TimeManager.get_physics_delta() > 0.0)
	var clock_idle_again: float = panel.get("_clock")
	await _frame(10)
	_check("世界回来了、人站着：锚着的器件仍然不走表（跟手不跟世界钟）",
		panel_rx.get_physics_delta() == 0.0 and panel.get("_clock") == clock_idle_again)

	# —— ⑦ 站着回收：当帧断链、目标立刻回世界钟、相位不清零。 ——
	var phase_at_recall: float = panel.get("_clock")
	Input.action_press(&"interact")
	await _frame(2)
	Input.action_release(&"interact")
	_check("E 回收：链接当帧断开", not anchor.has_link()
		and anchor.current_state() != TimeAnchor.State.ATTACHED)
	_check("站着回收：目标当帧回世界钟", panel_rx.get_physics_delta() > 0.0)
	await _frame(10)
	_check("回收后目标接着走世界钟，相位不回到 0",
		phase_at_recall > 0.0 and panel.get("_clock") > phase_at_recall)

	# —— ⑧ 移动中回收、世界冻着：当帧停表，回世界钟（此刻世界钟就是 0）。 ——
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	walker.global_position = Vector2(1000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	panel.period = 0.5
	panel.duty = 0.5
	panel.phase = 0.0
	panel.set("_clock", 0.34)
	panel._refresh_state(panel.cycle_on())
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	var phase_before_attach: float = panel.get("_clock")
	_check("再出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("前提：吸附成功，且吸附本身不碰目标的相位",
		anchor.current_state() == TimeAnchor.State.ATTACHED
		and panel.get("_clock") == phase_before_attach)
	Input.action_press(&"move_right")
	guard = 0
	while panel_rx.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	var clock_moving: float = panel.get("_clock")
	await _frame(3)
	_check("移动中吸附：器件表在走", panel.get("_clock") > clock_moving)
	Input.action_press(&"interact")
	await _frame(3)
	Input.action_release(&"interact")
	var clock_after_recall: float = panel.get("_clock")
	_check("移动中 E 回收：链接当帧断开", not anchor.has_link())
	_check("世界冻着时回收：目标当帧停表（回世界钟，世界钟 = 0）",
		panel_rx.get_physics_delta() == 0.0)
	await _frame(10)
	_check("冻着回收后目标一动不动（不是回到 0 重新开始）",
		panel.get("_clock") == clock_after_recall and clock_after_recall > 0.0)
	Input.action_release(&"move_right")
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	var clock_resumed: float = panel.get("_clock")
	await _frame(10)
	_check("松手、世界回来后目标接着走世界钟", panel.get("_clock") > clock_resumed)

	# —— ⑨ 穿梭块：手上 delta 把它整块推到 B，锚跟着瞬移（插座跟着块走）。 ——
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	walker.global_position = Vector2(1650.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	shuttle.period = 0.5
	shuttle.duty = 0.5
	shuttle.phase = 0.0
	shuttle.set("_clock", 0.0)
	shuttle._refresh_state(shuttle.cycle_on())
	await _frame(1)
	_check("前提：穿梭块停在 A 点", shuttle.is_on()
		and shuttle.global_position.distance_to(Vector2(1800.0, -18.0)) < 0.01)
	_check("对准穿梭块出膛", anchor.fire_toward(Vector2.RIGHT))
	guard = 0
	while anchor.current_state() != TimeAnchor.State.ATTACHED and guard < 60:
		guard += 1
		await _frame(1)
	_check("吸附在穿梭块上", anchor.current_state() == TimeAnchor.State.ATTACHED
		and anchor.attached_target() == shuttle)
	Input.action_press(&"move_right")
	guard = 0
	while shuttle.is_on() and guard < 40:
		guard += 1
		await _frame(1)
	_check("按着方向键：窗口走完即整块瞬移到 B，锚还吸着它",
		not shuttle.is_on() and anchor.current_state() == TimeAnchor.State.ATTACHED
		and shuttle.global_position.distance_to(Vector2(1800.0, -82.0)) < 0.01)
	# 锚比块早进树，`_tick_attached` 读的是块**上一拍**的位置 —— 隔一拍再读插座。
	await _frame(2)
	_check("锚插在块上：跟着瞬移到 B 那一格（不是留在半空）",
		anchor.global_position.distance_to(
			shuttle.global_position + Vector2(-24.0, 0.0)) < 1.0)
	Input.action_release(&"move_right")
	guard = 0
	while TimeManager.get_physics_delta() <= 0.0 and guard < 30:
		guard += 1
		await _frame(1)
	var shuttle_clock_attached: float = shuttle.get("_clock")
	await _frame(6)
	_check("世界流着、人站着：锚着的穿梭块照停（跟手不跟世界钟）",
		shuttle.get("_clock") == shuttle_clock_attached)
	Input.action_press(&"interact")
	await _frame(3)
	Input.action_release(&"interact")
	_check("回收后不再吸在穿梭块上", not anchor.has_link())
	var shuttle_clock_free: float = shuttle.get("_clock")
	await _frame(8)
	_check("回收后穿梭块回世界钟，接着自己跳", shuttle.get("_clock") > shuttle_clock_free)

	# —— ⑩ 占位查询（玩家）：人站在桥面要落地的那一小段下面，器件就停在旧状态。 ——
	guard = 0
	while anchor.current_state() != TimeAnchor.State.IDLE and guard < 60:
		guard += 1
		await _frame(1)
	_phase_force(panel, false)
	await _frame(2)
	# 底座两侧各有一截 32 px 宽的桥面悬在离地 10 px 的地方：人站在悬空段下面
	# （x 1250..1270）不与底座（1284..1316）重叠，但占着桥面的目标位置。
	walker.global_position = Vector2(1260.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)
	_phase_force(panel, true)
	await _frame(2)
	_check("玩家占着桥面：停成虚体、报 blocked（不把人挤开）",
		not panel.is_on() and panel.is_blocked())
	walker.global_position = Vector2(1000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(4)
	_check("人让开：下一拍就变实（占位查询每帧重问）",
		panel.is_on() and not panel.is_blocked())

	# —— ⑪ 占位查询（层 4）：另一件 time_solid 占着也算占 —— 两块实体不叠在同一格。 ——
	_phase_force(panel, false)
	await _frame(2)
	var blocker := _solid_box(Vector2(1300.0, -18.0), Vector2(40.0, 12.0))
	blocker.collision_layer = 4
	await _frame(1)
	_phase_force(panel, true)
	await _frame(2)
	_check("层 4 的实体占着桥面：同样停在虚体",
		not panel.is_on() and panel.is_blocked())
	blocker.queue_free()
	await _frame(4)
	_check("实体让开：面板接着变实", panel.is_on() and not panel.is_blocked())

	# —— ⑫ 相切不算占：人站在底座上（脚底与桥面上沿同高），内缩 1 px 让平台敢变实。 ——
	_phase_force(panel, false)
	await _frame(2)
	walker.global_position = Vector2(1300.0, -41.0)
	await _frame(3)
	_check("前提：人站在底座上（脚底与桥面上沿相切）",
		absf(walker.global_position.y - (-41.0)) < 0.5)
	_phase_force(panel, true)
	await _frame(2)
	_check("相切不算占：脚底贴着桥面时照常变实",
		panel.is_on() and not panel.is_blocked())
	walker.global_position = Vector2(1000.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(3)

	# —— ⑬ 穿梭块的占位查询走的是「目标那一头的 transform」：人站在 A 点，块回不去。 ——
	_solid_box(Vector2(2600.0, 166.0), Vector2(120.0, 400.0))
	var blocked_shuttle = _phase_instance(PHASE_SHUTTLE_SCENE, "ShuttleBlocked",
		Vector2(2600.0, -42.0), 0.5, 0.5, 0.0, Vector2(0.0, -48.0))
	await _frame(2)
	_phase_force(blocked_shuttle, false)
	await _frame(2)
	_check("前提：那块先停在 B（空中那一格）", not blocked_shuttle.is_on()
		and blocked_shuttle.global_position.distance_to(Vector2(2600.0, -90.0)) < 0.01)
	walker.global_position = Vector2(2600.0, -49.0)
	await _frame(3)
	_phase_force(blocked_shuttle, true)
	await _frame(3)
	_check("人站在 A 点：穿梭块停在 B（不把人挤开、也不叠进去）",
		not blocked_shuttle.is_on() and blocked_shuttle.is_blocked()
		and blocked_shuttle.global_position.distance_to(Vector2(2600.0, -90.0)) < 0.01)
	walker.global_position = Vector2(2400.0, -Player.COLLISION_HALF_HEIGHT)
	await _frame(4)
	_check("人一让开：下一拍回到 A（每帧重问，不是一次性）",
		blocked_shuttle.is_on()
		and blocked_shuttle.global_position.distance_to(Vector2(2600.0, -42.0)) < 0.01)

	# —— ⑭ period / duty 两个极端（文档里写明的合法配置，别让它们变成"永远不开"）。 ——
	_phase_force(panel, false)
	await _frame(1)
	panel.period = 0.0
	panel.phase = 0.0
	panel.duty = 0.0
	panel._refresh_state(panel.cycle_on())
	await _frame(1)
	_check("period = 0：不看相位，恒开", panel.cycle_on() and panel.is_on())
	panel.period = 0.5
	panel.duty = 0.0
	panel._refresh_state(panel.cycle_on())
	await _frame(1)
	_check("duty = 0：恒关", not panel.cycle_on() and not panel.is_on())
	panel.duty = 1.0
	panel._refresh_state(panel.cycle_on())
	await _frame(1)
	_check("duty = 1：恒开", panel.cycle_on() and panel.is_on())

	for node in [panel, shuttle, blocked_shuttle]:
		node.queue_free()
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(2)
	TimeManager.reset_state()


## 第 24 组：心电监护屏（D75）。它零契约、零机制，所以"改坏了不会响"的只有两条：
## 相位不再是世界时钟的纯函数；以及那块皮不再是"推一格的纯函数"。四钉照第 19 组那只钟的口径，
## 但它是全项目第一件**皮与图集那块瓦片逐格同源**的构件 —— 比色那半边在 verify_kit（只有它读得到
## 落盘纹理），这里钉时序与"会动 / 一圈回来是同一张"。
## ① 相位 == 独立重算的 f(elapsed_world_time)：fixture 晚进树，"自己从 0 累加"那种写法在这里
##    就对不上（那条写法数值上确实也跟冻结停、跟帧率无关，唯一露馅的就是这个起点偏移）；
## ② 冻结 20 拍相位一字不动，而且世界时钟本身也没涨 —— 把"停"的归因钉在表上而不是钟上；
##    连重画缓存 `_shown` 也不许在冻结里漂；
## ③ 解冻后接着推，并再与 f(世界时钟) 对一次（停过之后不许漂）；
## ④ `beat_period <= 0` 时世界在流也钉在相位 0 —— 钉的是"填 0 = 不走"这个约定本身。
## `beat_period` 在这里钉死成 0.05 s（一步 3 拍），不跟脚本默认值 0.7 走：默认值归摆图的人
## 随时调，照它断言"等 N 拍就一定换格"第二天就会红（D58 那条同一个坑）。
func _test_ecg_monitor() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	var monitor := load("res://scenes/objects/ecg_monitor/ecg_monitor.tscn").instantiate() as EcgMonitor
	monitor.beat_period = 0.05
	monitor.position = Vector2(1500.0, -300.0)
	add_child(monitor)
	await _frame(40)
	var steps: int = monitor.PATTERN.size()
	var want := int(fmod(TimeManager.elapsed_world_time / monitor.beat_period, 1.0) * float(steps)) % steps
	_check("相位 == 当场独立重算的 f(世界时钟)（%d 对 %d）" % [monitor.phase(), want],
		monitor.phase() == want)

	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("前提：有移动意图即世界冻结", TimeManager.is_time_frozen())
	var frozen_phase: int = monitor.phase()
	var t0: float = TimeManager.elapsed_world_time
	await _frame(20)
	_check("冻结 20 拍，波形一格没推（%d 还是 %d）" % [frozen_phase, monitor.phase()],
		monitor.phase() == frozen_phase)
	_check("没推是因为世界时钟没涨（%s → %s）" % [str(t0), str(TimeManager.elapsed_world_time)],
		TimeManager.elapsed_world_time == t0)
	_check("冻结里连重画缓存都停在同一相位（_shown=%s）" % str(monitor.get("_shown")),
		int(monitor.get("_shown")) == frozen_phase)

	TimeManager.notify_movement_intent(false)
	var waited := 0
	while monitor.phase() == frozen_phase and waited < 60:
		await _frame(1)
		waited += 1
	_check("解冻后接着推（等了 %d 拍）" % waited, monitor.phase() != frozen_phase)
	want = int(fmod(TimeManager.elapsed_world_time / monitor.beat_period, 1.0) * float(steps)) % steps
	_check("停过之后不漂：相位仍然 == f(世界时钟)（%d 对 %d）" % [monitor.phase(), want],
		monitor.phase() == want)

	_check("推一格就换图（相位 0 与 1 的网格不同）",
		monitor.pixel_grid(0) != monitor.pixel_grid(1))
	_check("推满一整圈回到同一张（相位 0 与 %d 的网格相同）" % steps,
		monitor.pixel_grid(0) == monitor.pixel_grid(steps))

	monitor.beat_period = 0.0
	await _frame(6)
	_check("beat_period=0：世界在流，相位仍钉在 0（%d）" % monitor.phase(), monitor.phase() == 0)

	monitor.queue_free()
	await _frame(2)
	TimeManager.reset_state()


## 第 25 组：假墙盖（D76）。三档距离显式给 32 / 96，不跟脚本默认的 48 / 160 走 ——
## 默认值归摆图的人随时调，照它断言"站在 N px 处该是多少"第二天就会红（D58 同一个坑）。
## 盖子的格子照清单里 mask 四边全满那格刷，不写死 (3,3)：换图集只换坐标不换这条判据。
func _test_cave_cover() -> void:
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(true)
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(2)

	const AT := Vector2(6000.0, -900.0)
	var manifest: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets/tiles/tiles.json"))
	var ts: TileSet = load("res://assets/tiles/lab_tileset.tres")
	var bits: Dictionary = manifest["terrain"]["mask_bits"]
	var full := 0
	for key in bits:
		full |= int(bits[key])
	var solid := Vector2i(-1, -1)
	for entry in manifest["terrain"]["tiles"]:
		if int(entry["mask"]) == full:
			solid = Vector2i(int(entry["x"]) / int(manifest["tile"]),
				int(entry["y"]) / int(manifest["tile"]))
	var cell := Vector2(ts.tile_size)
	var rect := Rect2(AT, cell * Vector2(3, 2))
	var mouth := AT + Vector2(-cell.x, cell.y)

	# 先把人放进屋里再挂盖子：验的是"开局第一拍就全隐"，不是先亮一下再淡下去。
	# `set_physics_process(false)` 必须在**进树之后**调：进树前调的那一档在 _ready 时被
	# 重新登记掉（实测 phys=true，人当场往下掉 60 px，alpha 从 0.5 漂到 0.88）。
	var hero := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	hero.global_position = rect.get_center() + Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	add_child(hero)
	hero.set_physics_process(false)

	var cover := load("res://scenes/objects/cave_cover/cave_cover.tscn").instantiate() as CaveCover
	cover.tile_set = ts
	cover.position = AT
	for x in 3:
		for y in 2:
			cover.set_cell(Vector2i(x, y), 0, solid)
	var marker := Marker2D.new()
	marker.name = "Mouth"
	marker.position = Vector2(-cell.x, cell.y)
	cover.add_child(marker)
	cover.reveal_near = 32.0
	cover.reveal_far = 96.0
	add_child(cover)
	await _frame(2)
	_check("开局人就在屋里：第一拍就是全隐（a=%s）" % str(cover.current_alpha()),
		cover.current_alpha() == 0.0)
	_check("单块也会拆进 Patch1 并清空根层（patch_count=%d，根上剩 %d 格）"
		% [cover.patch_count(), cover.get_used_cells().size()],
		cover.patch_count() == 1 and cover.get_used_cells().is_empty())

	hero.global_position = mouth + Vector2(300.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("站到 reveal_far 之外：全挡（a=%.2f）" % cover.current_alpha(),
		cover.current_alpha() == 1.0)

	hero.global_position = mouth + Vector2(-64.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	var want_mid: float = (64.0 - cover.reveal_near) / (cover.reveal_far - cover.reveal_near)
	_check("站在 near/far 正中：半透（a=%.3f，按两档应为 %.3f）"
		% [cover.current_alpha(), want_mid], absf(cover.current_alpha() - want_mid) < 0.005)
	await _frame(20)
	_check("同一站位世界流着 20 拍：不透明度一字不动（位置纯函数，不读时钟）",
		absf(cover.current_alpha() - want_mid) < 0.005)
	TimeManager.notify_movement_intent(true)
	await _frame(2)
	_check("前提：有移动意图即世界冻结", TimeManager.is_time_frozen())
	var t0: float = TimeManager.elapsed_world_time
	await _frame(20)
	_check("世界冻着 20 拍：不透明度仍不动，时钟也确实没涨（a=%.3f，钟 %s）"
		% [cover.current_alpha(), str(TimeManager.elapsed_world_time == t0)],
		absf(cover.current_alpha() - want_mid) < 0.005 and TimeManager.elapsed_world_time == t0)
	TimeManager.notify_movement_intent(false)

	hero.global_position = mouth + Vector2(-10.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("走到洞口跟前（< reveal_near）：整块隐去（a=%.2f）" % cover.current_alpha(),
		cover.current_alpha() == 0.0)

	# 走进屋最里面：把洞口挪到 392 px 外。按距离算这会儿该全挡，站进自家格子必须仍全隐。
	marker.position = Vector2(400.0, cell.y)
	hero.global_position = rect.position + Vector2(cell.x * 0.5, cell.y) \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("人在屋里、洞口在 392 px 外：仍全隐（走到底不许被重新盖住）",
		cover.current_alpha() == 0.0)
	marker.position = Vector2(-cell.x, cell.y)

	hero.queue_free()
	await _frame(3)
	_check("场上没有玩家：盖回全挡（a=%.2f）" % cover.current_alpha(),
		cover.current_alpha() == 1.0)

	cover.queue_free()
	await _frame(2)

	# —— 多块（2026-10-28 订正）：一个节点里刷两块互不相连的盖子 ——
	# 老实现拿**全部格子的外接框**判"站进屋里"、拿**一个 Mouth** 判远近，而 `modulate` 是
	# 节点级的：站在两块之间（在外接框里、不在任何一块上）会让整片一起透明，靠近 A 的口子
	# 也会顺带把 B 变淡。这里钉的是"每块自己判自己"。
	const AT2 := Vector2(6600.0, -900.0)
	var hero2 := load("res://scenes/actors/player/player.tscn").instantiate() as Player
	add_child(hero2)
	hero2.set_physics_process(false)
	var cover2 := load("res://scenes/objects/cave_cover/cave_cover.tscn").instantiate() as CaveCover
	cover2.tile_set = ts
	cover2.position = AT2
	for at in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
			Vector2i(6, 0), Vector2i(7, 0), Vector2i(6, 1), Vector2i(7, 1)]:
		cover2.set_cell(at, 0, solid)
	var mouth_a := Marker2D.new()
	mouth_a.name = "Mouth"
	mouth_a.position = Vector2(-cell.x, cell.y)
	cover2.add_child(mouth_a)
	var mouth_b := Marker2D.new()
	mouth_b.name = "Mouth2"
	mouth_b.position = Vector2(cell.x * 9.0, cell.y)
	cover2.add_child(mouth_b)
	cover2.reveal_near = 16.0
	cover2.reveal_far = 32.0
	add_child(cover2)
	await _frame(2)

	_check("多块：两坨不相连的格子拆成 2 块（patch_count=%d）" % cover2.patch_count(),
		cover2.patch_count() == 2)
	_check("多块：根层拆完清空（剩 %d 格）、alpha 还回 1（子层会继承父级，拆前那一拍可能写过 0）"
		% cover2.get_used_cells().size(),
		cover2.get_used_cells().is_empty() and is_equal_approx(cover2.modulate.a, 1.0))
	var all_off := true
	for layer in cover2.all_patches():
		all_off = all_off and not (layer as TileMapLayer).collision_enabled
	_check("多块：拆出来的子层都不带碰撞（带碰撞就是两面看不见的墙）", all_off)

	# 归属：A 的 Mouth 在左、B 的 Mouth2 在右，两个口子各归各的块。
	_check("多块：Mouth 归给左边那块（%s）" % str(cover2.mouth_point(0)),
		cover2.mouth_point(0).distance_to(AT2 + Vector2(-cell.x, cell.y)) < 0.01)
	_check("多块：Mouth2 归给右边那块（%s）" % str(cover2.mouth_point(1)),
		cover2.mouth_point(1).distance_to(AT2 + Vector2(cell.x * 9.0, cell.y)) < 0.01)

	# 站到两块之间：在外接框里、不在任何一块上，离两个口子都 80 px —— 两块都该全挡。
	# 老实现的外接框判"里面"，这一拍整片会一起变透明。
	hero2.global_position = AT2 + Vector2(cell.x * 4.0, cell.y) \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("多块：站在两块之间，A 全挡（a=%.2f）" % cover2.current_alpha(0),
		cover2.current_alpha(0) == 1.0)
	_check("多块：站在两块之间，B 全挡（a=%.2f）—— 老实现这里整片全隐" % cover2.current_alpha(1),
		cover2.current_alpha(1) == 1.0)

	# 靠近 A 的口子：只有 A 露，B 仍全挡（老实现里两块的 alpha 是同一个数）。
	hero2.global_position = mouth_a.global_position \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("多块：站 A 口前，A 全隐（a=%.2f）" % cover2.current_alpha(0),
		cover2.current_alpha(0) == 0.0)
	_check("多块：站 A 口前，B 仍全挡（a=%.2f）—— 不许被邻居顺带打开" % cover2.current_alpha(1),
		cover2.current_alpha(1) == 1.0)

	# 站进 B 里：B 全隐，A 全挡（"站进自家格子"也按块算，不是整片外接框）。
	hero2.global_position = AT2 + Vector2(cell.x * 6.5, cell.y) \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(2)
	_check("多块：站进 B 里，B 全隐（a=%.2f）" % cover2.current_alpha(1),
		cover2.current_alpha(1) == 0.0)
	_check("多块：站进 B 里，A 全挡（a=%.2f）" % cover2.current_alpha(0),
		cover2.current_alpha(0) == 1.0)

	hero2.queue_free()
	cover2.queue_free()
	await _frame(2)
	TimeManager.reset_state()


## 第 26 组：梦泡新手引导（D77）。这一组钉的全是"改坏了不响、只在开局那一拍露馅"的东西：
## ① **不按就不醒**（用户裁定）：钉住的窗口 20 拍不释放、皮钉在 wake 第 0 帧
##    （wake 剪辑不循环，任它自己走完就停在"已经醒完"那张脸上，而这一拍要演的恰恰是没醒）、
##    按了方向键人也位移不了（复用 D57 那把锁，不另起第二套掐法）；
## ② 四只各自一次破：重复按同一只不双计、三只破完不发 `completed`、四只破完且最后一发的
##    三帧演完才发**一次**；
## ③ `completed` 之后交回的是**现成的**那条苏醒路径（`release_wake()` → 那 2.45 s 窗口），
##    不是第二套"醒"，且梦泡节点当拍撤掉；
## ④ 这一拍里危险物杀不到人 —— 并且拿"同样的动作、但这一关没有引导"当对照。
##    没有那条对照，这条豁免是真是假分不出来（`take_intro()` 在开局那一帧就消费掉了，
##    演到一半死掉 = 新手引导永久丢失，症状长得像"引导坏了"而不是"我被刺死了"）。
func _test_dream_bubbles() -> void:
	TimeManager.reset_state()
	for stray in get_tree().get_nodes_in_group(&"player"):
		(stray as Node).queue_free()
	await _frame(2)
	var root = _make_world_root()
	root.intro_enabled = true
	var mini := _build_mini_level(root)
	var level: LevelBase = mini["level"]
	var sleeper: Player = mini["walker"]
	var spikes: Node = mini["spikes"]
	var fires: Array = []
	await _frame(2)
	var bubbles := level.get_node_or_null("DreamBubbles") as DreamBubbles
	_check("进关当帧进入钉住的苏醒窗口（waking 且 held）",
		sleeper.is_waking() and sleeper.is_wake_held())
	_check("钉住 = 移动锁挂着（复用 D57 那把）", sleeper.movement_locked)
	_check("关卡根挂上了一串梦泡", bubbles != null)
	if bubbles == null:
		mini["level"].queue_free()
		root.queue_free()
		await _frame(2)
		return
	_check("梦泡连到关卡根的编排上（completed 有人接）",
		bubbles.is_connected(&"completed", Callable(level, "_on_dream_completed")))
	_check("四只都还没破（%d）" % bubbles.popped_count(), bubbles.popped_count() == 0)
	bubbles.connect(&"completed", func() -> void: fires.append(1))

	# —— ① 皮真的被钉住：wake 剪辑**不循环**，任它自己走完就停在"已经醒完"那张脸上，
	#     而这一拍要演的恰恰是没醒。静态那一条只认 `is_wake_held()` 这个调用点在不在，
	#     把分支短路成 `if false and ...` 它分不出来 —— 只能在真帧上证。
	var skin := sleeper.get_node_or_null("Visual/Sprite") as PlayerVisual
	_check("拿得到玩家那张皮（下面三条的前提）", skin != null)
	if skin != null:
		_check("钉住的这一拍皮是 wake 不是 idle/run（%s）" % str(skin.animation),
			skin.animation == &"wake")
		_check("钉住的这一拍停在 wake 第 0 帧（frame=%d）" % skin.frame, skin.frame == 0)
		await _frame(20)
		_check("钉住 20 拍后仍是第 0 帧、仍没在播、仍未释放（frame=%d playing=%s held=%s）"
			% [skin.frame, str(skin.is_playing()), str(sleeper.is_wake_held())],
			skin.frame == 0 and not skin.is_playing() and sleeper.is_wake_held())

	# —— ④ 豁免：把刺搬到他脚下，这一拍里杀不到 ——
	spikes.global_position = sleeper.global_position \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(6)
	_check("梦泡这一拍里踩上刺也不判死（引导不许演到一半人没了）", not sleeper.is_dead)

	# —— ① 按了也不动 + ② 一次破、不双计 ——
	Input.action_press(&"move_left")
	await _frame(3)
	Input.action_release(&"move_left")
	await _frame(3)
	_check("按过 A 之后人仍然没有水平速度（掐的是那把锁，不是新写一套）",
		sleeper.velocity.x == 0.0)
	_check("按一次破一只（%d）" % bubbles.popped_count(), bubbles.popped_count() == 1)
	Input.action_press(&"move_left")
	await _frame(3)
	Input.action_release(&"move_left")
	await _frame(3)
	_check("重复按同一只不双计（%d）" % bubbles.popped_count(), bubbles.popped_count() == 1)
	_check("三只没破完就不发 completed（已发 %d 次）" % fires.size(), fires.is_empty())
	for action in [&"move_down", &"jump"]:
		Input.action_press(action)
		await _frame(3)
		Input.action_release(action)
		await _frame(3)
	_check("破到三只仍不发 completed（%d / 已发 %d 次）" % [bubbles.popped_count(), fires.size()],
		bubbles.popped_count() == 3 and fires.is_empty())
	Input.action_press(&"move_right")
	await _frame(3)
	Input.action_release(&"move_right")
	var waited := 0
	while fires.is_empty() and waited < 60:
		await _frame(1)
		waited += 1
	_check("四只全破、最后一发的三帧演完后发一次 completed（等了 %d 拍）" % waited,
		fires.size() == 1)
	_check("交回的是现成那条苏醒窗口（held 掉了、waking 还在）",
		not sleeper.is_wake_held() and sleeper.is_waking())
	_check("演完就把梦泡从场上撤掉（不留一只还能再按的东西）",
		level.get_node_or_null("DreamBubbles") == null)

	# —— 收尾：把这一关撤干净，再开一关做 ④ 的对照组 ——
	mini["level"].queue_free()
	root.queue_free()
	await _frame(4)
	TimeManager.reset_state()

	# —— ④ 的对照组：**同一个动作（把那把刺挪到他脚下），只是这一关没有引导**。
	#     不能就地新造一把刺挂上去 —— 危险物是关卡根 `_ready()` 时全子树扫描后才连的，
	#     事后挂的没人接 `touched_player`；也不能复用上面那把，它的一次性闩锁已经发过了。
	var control_root = _make_world_root()
	control_root.intro_enabled = false
	var control := _build_mini_level(control_root)
	var c_player: Player = control["walker"]
	var c_spikes: Node = control["spikes"]
	await _frame(2)
	_check("对照关：没有梦泡（引导只由 `take_intro()` 那一发拉起）",
		control["level"].get_node_or_null("DreamBubbles") == null)
	c_spikes.global_position = c_player.global_position \
		+ Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(6)
	_check("对照：同样一把刺压在脚下，引导不在时判死（证明上面那条豁免是真在挡事）",
		c_player.is_dead)

	control["level"].queue_free()
	control_root.queue_free()
	await _frame(2)
	TimeManager.reset_state()


## 相位器件 fixture：`period/duty/phase` 必须在进树前赋好 —— `_ready()` 里那次
## `_apply_state(cycle_on())` 就是按这一档决定开局站在哪一头。
func _phase_instance(path: String, node_name: String, at: Vector2,
		period: float, duty: float, phase: float, offset = null):
	var device = load(path).instantiate()
	device.name = node_name
	device.position = at
	device.period = period
	device.duty = duty
	device.phase = phase
	if offset != null:
		device.offset = offset
	add_child(device)
	return device


## 把器件钉在某一态：`duty` 1/0 是文档里写明的两个极端，正好在这里当夹具有用。
## 同一拍生效，不等下一帧 —— 否则"没走表"会被测成"还没轮到"。
func _phase_force(device: Node, on: bool) -> void:
	device.set("duty", 1.0 if on else 0.0)
	device.set("_clock", 0.0)
	device._refresh_state(device.cycle_on())


## 坠落带 fixture：导出项在进树前赋好，`_ready()` 里的 `_rebuild()` 才按这一档建盒## （与 D47 那台同一套时序口径）。宽度给窄一档，免得本组的三张网互相叠到别人身上。
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
## `sources` 是一列（D60 起一块可以指多台，OR 合成），相对路径且在进树前赋好：
## `_ready()` 里那次 `_reconnect_triggers()` 才解析得动。
func _piston_instance(rig: Node, sources: Array, node_name: String,
		at: Vector2, travel: Vector2, flipped: bool = false) -> PistonBlock:
	var piston := load("res://scenes/objects/piston_block/piston_block.tscn") \
		.instantiate() as PistonBlock
	piston.name = node_name
	piston.position = at
	piston.travel_offset = travel
	piston.extend_speed = 128.0
	piston.retract_speed = 512.0
	# 反向档（D63）必须在 `add_child` 之前写：`_ready()` 里那次"常态那一头瞬落"读的就是它，
	# 进树之后再拧只会让这块停在摆下去的那一头，测到的就不是开局那一拍。
	piston.rest_out = flipped
	var listed: Array[NodePath] = []
	for source in sources:
		listed.append(NodePath("../" + String((source as Node).name)))
	piston.triggers = listed
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


## 第 22 组重挂前的标准摆位：方块回行程起点、相位清零。**只在世界冻着、且锚没吸着它时调用** ——
## 世界流着的话下一拍 `_physics_process` 就会把它推离这条射线，重挂那几条断言测的就不是摆位了。
func _anchor_reset_target(block: MovingBlock) -> void:
	block.global_position = Vector2(300.0, -32.0)
	block.elapsed_path_time = 0.0


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
## take_intro 与 Main 一样是"取走即消耗"，但外面套了一层 intro_enabled：其余各组都要按
## 「不演苏醒」跑（第 14、15 组的人在等落体与回灌，凭空被锁 1.15 秒是埋雷），只有第 18 组打开它。
func _make_world_root():
	var stub = Node.new()
	var stub_script := GDScript.new()
	stub_script.source_code = """
extends Node
var run_state := {}
var reload_calls := 0
var restart_calls := 0
var intro_enabled := false
var intro_played := false
func get_run_state() -> Dictionary:
	return run_state
func reload_level() -> void:
	reload_calls += 1
func restart_level() -> void:
	restart_calls += 1
func take_intro() -> bool:
	if not intro_enabled or intro_played:
		return false
	intro_played = true
	return true
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
