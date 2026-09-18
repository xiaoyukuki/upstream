extends Node2D
## 玩家像素动画的无头自测。跑法：
##   Godot_console.exe --headless --path . res://tools/sprite_selftest.tscn
##
## 六件事必须成立，缺一不可：
## 1. 帧资源齐全（剪辑名、帧数、循环标记与 clips.json 一致）；
## 2. 剪辑按真实物理状态切换 idle/start/run/stop/jump/fall/land；
## 3. 世界冻结时玩家动画照常推进 —— 玩家豁免时停这条铁律现在多了一层视觉表达，
##    动画一旦被时停拖住，机制可读性就反过来了；
## 4. 按住下键贴地压扁是纯表现：不改碰撞、不冻结世界，腾空/落地/跑动都压过它；
## 5. 底边是波浪不是直线，且任何一列都不越过脚底基线（脚底对齐是美术与碰撞的契约）；
## 6. 推墙时贴墙一侧压平到碰撞盒边界（D23：墙侧越界 = 0），且同样是纯表现。
## 另外第 3 组守两条几何底线：站姿轮廓宽 > 高（要的是「扁」），最宽帧不挤 40 px 最小门洞。
##
## 落地相关的断言一律「等到 is_on_floor 再往后 1~2 帧」而不是数固定帧数：
## land 剪辑窗口只有 0.2s，靠估时间会漂。

const FLOOR_TOP := 0.0
## gen_player_frames.py 的 int(BOTTOM)：底边基线所在的行，旧版一刀切平的就是这一行。
const WAVE_BASELINE := 36
## 第 9 组那面墙的左墙面 x。刻意离起跑点很远：第 4 组从 x=100 往右只跑到约 x=260。
const WALL_FACE := 600.0

var _failures := 0
var _player: Player
var _sprite: AnimatedSprite2D


func _ready() -> void:
	_build_world()
	_run()


func _check(ok: bool, label: String) -> void:
	print("  %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1


func _build_world() -> void:
	var floor_body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(4000.0, 40.0)
	shape.shape = rect
	shape.position = Vector2(2000.0, FLOOR_TOP + 20.0)
	floor_body.add_child(shape)
	add_child(floor_body)

	var wall_body := StaticBody2D.new()
	var wall_shape := CollisionShape2D.new()
	var wall_rect := RectangleShape2D.new()
	wall_rect.size = Vector2(40.0, 400.0)
	wall_shape.shape = wall_rect
	wall_shape.position = Vector2(WALL_FACE + 20.0, -180.0)
	wall_body.add_child(wall_shape)
	add_child(wall_body)

	var packed: PackedScene = load("res://scenes/actors/player/player.tscn")
	_player = packed.instantiate()
	_player.position = Vector2(100.0, -140.0)
	add_child(_player)
	_sprite = _player.get_node("Visual/Sprite")


func _step(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


## 等到落地（或超时），再补几帧让 _process 里的状态机跟上。
## 开头先走两帧：is_on_floor() 存的是上一次 move_and_slide() 的结果，刚把玩家瞬移到空中时它还是 true。
func _wait_until_landed(pad: int) -> void:
	await _step(2)
	var guard := 0
	while not _player.is_on_floor() and guard < 180:
		await get_tree().physics_frame
		guard += 1
	await _step(pad)


func _run() -> void:
	print("[sprite_selftest] 1. 帧资源")
	_check(_sprite.animation == &"idle", "场景 autoplay 落在 idle")
	var frames: SpriteFrames = _sprite.sprite_frames
	var expected := {
		"idle": [8, true], "run": [6, true], "start": [3, false], "stop": [3, false],
		"jump": [2, false], "fall": [3, true], "land": [4, false],
		"crouch_in": [3, false], "crouch": [4, true], "crouch_out": [2, false],
		"wall_press_in": [2, false], "wall_press": [2, true], "wall_press_out": [2, false],
	}
	for clip in expected.keys():
		var want: Array = expected[clip]
		_check(frames.get_frame_count(clip) == want[0], "%s 帧数=%d" % [clip, want[0]])
		_check(frames.get_animation_loop(clip) == want[1], "%s loop=%s" % [clip, want[1]])

	print("[sprite_selftest] 2. 落地剪辑")
	# 从 -140 掉到地面：末速 sqrt(2*980*125)≈495 > MIN_LAND_IMPACT(260)，必须播 land
	await _wait_until_landed(2)
	_check(_sprite.animation == &"land", "高空落地播 land（实际 %s）" % _sprite.animation)
	await _step(20)
	_check(_sprite.animation == &"idle", "落地剪辑结束后回 idle（实际 %s）" % _sprite.animation)
	_check(_player.is_on_floor(), "玩家已站在地面")

	print("[sprite_selftest] 3. 美术与碰撞的脚底对齐")
	# 精灵原点 = 碰撞盒中心，帧内脚底在 local +15，所以静止时脚底应当正好贴住地面。
	var foot_error: float = _sprite.global_position.y + Player.COLLISION_HALF_HEIGHT - FLOOR_TOP
	_check(absf(foot_error) < 0.6, "脚底贴地（偏差 %.2f px）" % foot_error)
	var standing: Rect2i = frames.get_frame_texture(&"idle", 0).get_image().get_used_rect()
	_check(standing.size.x > standing.size.y,
		"站姿轮廓是扁的（%d x %d）" % [standing.size.x, standing.size.y])
	var widest := 0
	for clip in expected.keys():
		for i in frames.get_frame_count(clip):
			widest = maxi(widest, frames.get_frame_texture(clip, i).get_image().get_used_rect().size.x)
	_check(widest <= 36, "全剪辑最宽 %d px，不挤 40 px 最小门洞" % widest)

	print("[sprite_selftest] 4. 起步甩动、跑动 + 世界冻结时动画不冻结")
	TimeManager.set_ability_enabled(true)
	Input.action_press(&"move_right")
	await _step(3)
	_check(TimeManager.is_time_frozen(), "按住方向键后世界已冻结")
	_check(_sprite.animation == &"start", "起步瞬间播后仰甩动（实际 %s）" % _sprite.animation)
	await _step(14)
	_check(_sprite.animation == &"run", "甩动窗口过后接上 run（实际 %s）" % _sprite.animation)
	var frame_before: int = _sprite.frame
	var world_before: float = TimeManager.elapsed_world_time
	await _step(20)
	_check(TimeManager.is_time_frozen(), "世界仍处于冻结")
	_check(is_equal_approx(TimeManager.elapsed_world_time, world_before), "世界时间没有前进")
	_check(_sprite.frame != frame_before,
		"玩家动画在冻结中照常推进（frame %d -> %d）" % [frame_before, _sprite.frame])
	Input.action_release(&"move_right")
	await _step(8)
	_check(_sprite.animation == &"stop", "松手刹车播前倾甩动（实际 %s）" % _sprite.animation)
	await _step(20)
	_check(not TimeManager.is_time_frozen(), "松手后世界解冻")
	_check(_sprite.animation == &"idle", "停下后回 idle（实际 %s）" % _sprite.animation)

	print("[sprite_selftest] 5. 起跳与下落")
	Input.action_press(&"jump")
	await _step(4)
	Input.action_release(&"jump")
	_check(_sprite.animation == &"jump", "上升段播 jump（实际 %s）" % _sprite.animation)
	await _step(40)
	_check(not _player.is_on_floor() and _player.velocity.y > 140.0,
		"已进入下落段（vy=%.0f）" % _player.velocity.y)
	_check(_sprite.animation == &"fall", "下落段播 fall（实际 %s）" % _sprite.animation)
	await _wait_until_landed(2)
	_check(_sprite.animation == &"land", "跳落后播 land（实际 %s）" % _sprite.animation)

	print("[sprite_selftest] 6. 轻落地不播 land")
	await _step(20)
	_player.velocity = Vector2.ZERO
	_player.global_position = Vector2(100.0, -(Player.COLLISION_HALF_HEIGHT + 12.0))
	await _wait_until_landed(2)
	_check(_sprite.animation == &"idle", "12px 小落差直接回 idle（实际 %s）" % _sprite.animation)

	print("[sprite_selftest] 7. 按住下键贴地压扁（纯表现，不冻结世界）")
	Input.action_press(&"move_down")
	await _step(3)
	_check(_sprite.animation == &"crouch_in", "按下瞬间播压扁入（实际 %s）" % _sprite.animation)
	await _step(14)
	_check(_sprite.animation == &"crouch", "入剪辑结束后接压扁循环（实际 %s）" % _sprite.animation)
	_check(not TimeManager.is_time_frozen(), "按住下键不冻结世界")
	var crouch_world_before: float = TimeManager.elapsed_world_time
	await _step(10)
	_check(TimeManager.elapsed_world_time > crouch_world_before, "蹲着时世界时间照常前进")
	_check(absf(_player.velocity.x) < 1.0, "蹲着不产生位移（vx=%.1f）" % _player.velocity.x)
	Input.action_press(&"jump")
	await _step(4)
	Input.action_release(&"jump")
	_check(_sprite.animation == &"jump", "蹲姿起跳直接播 jump（实际 %s）" % _sprite.animation)
	await _step(40)
	_check(_sprite.animation == &"fall", "空中不播任何压扁剪辑（实际 %s）" % _sprite.animation)
	# 按住下落地：land 窗口压过 crouch（先拍一帧扁的），窗口过了才进压扁循环
	await _wait_until_landed(2)
	_check(_sprite.animation == &"land", "按住下落地先播 land（实际 %s）" % _sprite.animation)
	await _step(26)
	_check(_sprite.animation == &"crouch", "land 与入剪辑窗口过后进入压扁循环（实际 %s）" % _sprite.animation)
	Input.action_release(&"move_down")
	await _step(3)
	_check(_sprite.animation == &"crouch_out", "松开下键播起身（实际 %s）" % _sprite.animation)
	await _step(14)
	_check(_sprite.animation == &"idle", "起身后回 idle（实际 %s）" % _sprite.animation)

	print("[sprite_selftest] 8. 底边是波不是直线，且不越过脚底基线")
	var probe: Image = frames.get_frame_texture(&"idle", 0).get_image()
	var bottoms := {}
	for c in probe.get_width():
		for r in range(probe.get_height() - 1, -1, -1):
			if probe.get_pixel(c, r).a > 0.5:
				bottoms[c] = r
				break
	var distinct := {}
	for c in bottoms.keys():
		distinct[bottoms[c]] = true
	_check(distinct.size() >= 2, "底边各列最低行有起伏（%d 级，不再是横平一条）" % distinct.size())
	var kisses := false
	var crosses := false
	for i in frames.get_frame_count(&"idle"):
		var img: Image = frames.get_frame_texture(&"idle", i).get_image()
		for c in img.get_width():
			if img.get_pixel(c, WAVE_BASELINE).a > 0.5:
				kisses = true
			for r in range(WAVE_BASELINE + 1, img.get_height()):
				if img.get_pixel(c, r).a > 0.5:
					crosses = true
	_check(kisses, "idle 循环里至少有一帧的底边仍碰到基线行")
	_check(not crosses, "没有任何一帧的像素越过基线行之下")

	print("[sprite_selftest] 9. 推墙压平（D23：墙侧越界 = 0）")
	# 几何。压平段的每一帧都必须收在碰撞盒右边界内；wall_press_out 末帧刻意排除 ——
	# 它的 wall_clip 归零，是「松手回弹到全宽」那一帧，断言它比盒宽反而是在钉住设计意图。
	const BOX_EDGE_COL := 31   # FRAME/2 + 10 - 1：盒右边界所在的最后一列
	const BOX_TOP_ROW := 7     # FRAME/2 - 15：盒顶那一行，上缘不得高于它
	var flush := true
	var over_top := false
	var flush_frames := {&"wall_press_in": 2, &"wall_press": 2, &"wall_press_out": 1}
	for clip in flush_frames.keys():
		for i in range(int(flush_frames[clip])):
			var used: Rect2i = frames.get_frame_texture(clip, i).get_image().get_used_rect()
			if used.position.x + used.size.x - 1 > BOX_EDGE_COL:
				flush = false
			if used.position.y < BOX_TOP_ROW:
				over_top = true
	_check(flush, "压平段每帧墙侧都收在盒边界内（最外列 ≤ %d）" % BOX_EDGE_COL)
	_check(not over_top, "压平段每帧上缘不超盒顶（行 ≥ %d）" % BOX_TOP_ROW)
	var recoil: Rect2i = frames.get_frame_texture(&"wall_press_out", 1).get_image().get_used_rect()
	_check(recoil.position.x + recoil.size.x - 1 > BOX_EDGE_COL,
		"回弹末帧确实比盒宽（墙侧到第 %d 列）" % [recoil.position.x + recoil.size.x - 1])
	# 脚底契约沿用第 8 组：每段至少一帧触基线行，且无一帧越过其下。不能要求每帧都触线 ——
	# 底边最低行在 35/36 间交替是所有贴地剪辑的既有特性（波形相位与脚趾列错位所致）。
	for clip in [&"wall_press_in", &"wall_press", &"wall_press_out"]:
		var touched := false
		var crossed_press := false
		for i in frames.get_frame_count(clip):
			var img: Image = frames.get_frame_texture(clip, i).get_image()
			for c in img.get_width():
				if img.get_pixel(c, WAVE_BASELINE).a > 0.5:
					touched = true
				for r in range(WAVE_BASELINE + 1, img.get_height()):
					if img.get_pixel(c, r).a > 0.5:
						crossed_press = true
		_check(touched, "%s 至少一帧的底边触到基线行" % clip)
		_check(not crossed_press, "%s 没有像素越过基线行之下" % clip)

	# 状态机。把人放到墙左边一点让他自己撞上去，撞上那一刻用轮询等而不是数固定帧数
	# —— 与落地断言同一个理由：接触帧会随帧率漂。
	_player.velocity = Vector2.ZERO
	_player.global_position = Vector2(WALL_FACE - 30.0, -Player.COLLISION_HALF_HEIGHT)
	await _step(2)
	Input.action_press(&"move_right")
	var guard_press := 0
	while _player.wall_press_dir == 0 and guard_press < 90:
		await get_tree().physics_frame
		guard_press += 1
	await _step(2)
	_check(_player.wall_press_dir == 1, "推墙时 wall_press_dir 挂上（实际 %d，%d 帧撞上）"
		% [_player.wall_press_dir, guard_press])
	_check(_sprite.animation == &"wall_press_in", "接触瞬间播压平入（实际 %s）" % _sprite.animation)
	_check(TimeManager.is_time_frozen(), "推墙期间世界仍处于冻结")
	await _step(12)
	_check(_sprite.animation == &"wall_press", "入剪辑窗口过后接压平循环（实际 %s）" % _sprite.animation)
	var press_x: float = _player.global_position.x
	await _step(10)
	_check(_sprite.animation == &"wall_press", "持续推墙停在压平循环（实际 %s）" % _sprite.animation)
	_check(is_equal_approx(_player.global_position.x, press_x),
		"推墙不产生位移（x=%.1f）" % _player.global_position.x)
	Input.action_release(&"move_right")
	await _step(3)
	_check(_player.wall_press_dir == 0, "松手后 wall_press_dir 落下（实际 %d）" % _player.wall_press_dir)
	_check(_sprite.animation == &"wall_press_out", "松手播回弹（实际 %s）" % _sprite.animation)
	await _step(20)
	_check(_sprite.animation == &"idle", "回弹窗口过后回 idle（实际 %s）" % _sprite.animation)
	_check(not TimeManager.is_time_frozen(), "松手后世界解冻")

	# 腾空释放不留回弹窗口（与蹲伏同一条守卫），落地也不补播
	_player.velocity = Vector2.ZERO
	_player.global_position = Vector2(WALL_FACE - 20.0, -Player.COLLISION_HALF_HEIGHT)
	await _step(2)
	Input.action_press(&"move_right")
	await _step(12)
	_check(_player.wall_press_dir == 1, "重新贴上墙（实际 %d）" % _player.wall_press_dir)
	Input.action_press(&"jump")
	await _step(4)
	Input.action_release(&"jump")
	Input.action_release(&"move_right")
	await _step(4)
	_check(not _player.is_on_floor(), "已离地")
	_check(_sprite.animation != &"wall_press_out", "腾空不播回弹（实际 %s）" % _sprite.animation)
	await _wait_until_landed(2)
	_check(_sprite.animation != &"wall_press_out", "落地也不补播回弹（实际 %s）" % _sprite.animation)

	print("SPRITE SELFTEST DONE failures=%d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
