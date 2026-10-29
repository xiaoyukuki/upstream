extends Node
## D78 开场遮罩的开窗实拍器：遮罩画在屏幕上到底有多大、多黑、跟不跟着苏醒张开 ——
## 这几件事无头那份守门看不见（它只看得到清单与磁盘上的像素文件）。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/dream_mask_shot.tscn
## 退出码 = 有没有 FAIL，所以它兼任一条开窗守门。
## 素材：`assets/ui/frames/dream_mask_shot.png`（七行：无遮罩参照 / 空对照 / 钉住 /
## 呼吸另一相 / 张开中 / 醒完 / 同源差值放大图）。
##
## 六条读数，每条都能被一次撒坏弄红：
##   ① 钉住那一拍遮罩真的在：与无遮罩底片的差格数过下限（`MIN_PAINT`，暗关里这条才是真的），
##      屏角 == 清单那档色，亮区中心逐字节不动，圆心 == 玩家的屏上位＋清单那个弧心偏移；
##   ② **屏上半径 == 清单算出来的半径**：沿 +x 找"开始变暗"与"暗到底"两档，
##      期望值 = `lerp(radius, open_radius, progress)` 再叠**这一拍实际的呼吸相位**；
##   ③ 呼吸真的在呼吸：相位 0 与 1/4 圈两档的实测差 == 按两拍实际相位算出来的差（≈6 px），
##      并要求那个算出来的差本身 ≥ 3 px —— 否则"实测差 ≈ 期望差"可以是两条都等于 0 的假绿；
##   ④ 张开跟着进度：实测半径 == 同拍 progress 算出来的半径，且比钉住那一拍**真的长大了**；
##   ⑤ 醒完自己收摊：窗口一走遮罩隐形，且整屏与参照逐字节相同（不留一层"忘了关"的暗角）；
##   ⑥ 同源（真帧 == 批过的图）：①那一帧与 `assets/props/dream_mask_card_01.png`（选型图①
##      那一档的单卡）逐像素比，超差格数应为 0 —— 这条把"单一写手"收到屏幕上。
## 另有一条空对照：连拍两张"无遮罩"，差值必须为 0，否则上面那些逐字节判据全都不成立。
##
## 摆场子走**干净世界根**（`MaskShotRoot` + `level_01_tutorial.tscn`），不跑 Main：
## Main 带 `run_state` 回灌，实测把玩家放到一片几乎全是底色的空处 —— 那样 ① 的
## "屏角已是遮罩色"会假绿（暗关里不画遮罩也是那个色），所以另加一条 `MIN_PAINT`：
## 钉住那一帧与无遮罩底片的差格数必须过下限，证明这一层真的往屏上抹了东西。

const OUT_DIR: String = "res://assets/ui/frames"
const OUT_FILE: String = "dream_mask_shot.png"
const MANIFEST_PATH := "res://assets/props/dream_mask.json"
const LEVEL := "res://scenes/levels/level_01_tutorial.tscn"
const MASK_SCENE := "res://scenes/ui/dream_mask/dream_mask.tscn"
## ⑥ 比的是生成器另外吐的那张**单卡**（选型图①那一档，1280×720 不带标题条）：
## 拿多行选型图比要钉一个"第几行开始"的魔数，那个数一改就悄悄全红/全绿。
const CARD := "res://assets/props/dream_mask_card_01.png"
const BASE_FILE := "res://assets/ui/frames/dream_mask_base.png"
const ZOOM := 2.0
const SETTLE: int = 6
const TOL: int = 8                       # 逐像素比的容差（每通道，8 bit）
const MIN_SPAN := 24.0 / 255.0           # 反解 alpha 要求"底片与遮罩色"至少差这么多
const MIN_PAINT := 5000                  # ① 遮罩"画上去了"的最低差格数（2 格一跳，共 230400 格）
const ROWS: int = 7

## 干净世界根的替身（与 D77 那份实拍器同一个写法）：`get_run_state()` 给空 ⇒ 不回灌出生位，
## `take_intro()` 第一次给 true ⇒ 这一拍真的演。
class MaskShotRoot extends Node:
	var _taken := false
	func get_run_state() -> Dictionary:
		return {}
	func take_intro() -> bool:
		if _taken:
			return false
		_taken = true
		return true
	func reload_level() -> void:
		pass
	func restart_level() -> void:
		pass

var _player: Player
var _camera: Camera2D
var _mask: CanvasLayer
var _sprite: Sprite2D
var _m: Dictionary
var _centre := Vector2.ZERO
var _last_progress := -2.0
var _last_phase := 0.0
var _fails := 0
var _strip: Image
var _cell := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var fh := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if fh == null:
		push_error("[mask-shot] 读不到 %s —— 先跑 py tools/gen_dream_mask_preview.py" % MANIFEST_PATH)
		get_tree().quit(1)
		return
	_m = JSON.parse_string(fh.get_as_text())

	# **不跑 Main**：Main 会带 `run_state` 回灌（实测把玩家放到 (1827,1073) 那片几乎全是
	# 底色的空处，而且要先坠 80 拍才静），底片就不可复现。这里自己搭一个干净世界根
	# （`get_run_state()` 给空、`take_intro()` 给一次），直接摆开场子那一关。
	var world_root := MaskShotRoot.new()
	world_root.name = "MaskShotRoot"
	world_root.add_to_group(&"world_root")
	add_child(world_root)
	add_child(load(LEVEL).instantiate())
	_mask = load(MASK_SCENE).instantiate() as CanvasLayer
	add_child(_mask)

	var guard := 0
	while _player == null and guard < 240:
		guard += 1
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group(&"player") as Player
		if _player == null:
			continue
		_camera = _player.get_node_or_null("PlayerCamera") as Camera2D
		if _camera == null:
			_player = null
			continue
	if _player == null:
		push_error("[mask-shot] 等不到玩家或遮罩层（%s 里没有 Player？)" % LEVEL)
		get_tree().quit(1)
		return
	_sprite = _mask.get_node("Mask") as Sprite2D
	_camera.position_smoothing_enabled = false
	_camera.zoom = Vector2(ZOOM, ZOOM)
	_strip = Image.create(1280, (720 + 10) * ROWS + 10, false, Image.FORMAT_RGB8)
	_strip.fill(Color8(10, 11, 16))

	# 取景先要静下来才允许抓：出生点有一段下坠、相机自己也要几拍才贴上，
	# 不等它落定，两张"无遮罩参照"就是同一个场景的两个取景（实测差 37665 格），
	# 底片也不可复现 ⇒ ⑥ 与逐字节那几条判据全成空话。
	var still := 0
	var guard2 := 0
	var prev_pos := Vector2.INF
	var prev_xform := Transform2D()
	while still < 12 and guard2 < 600:
		guard2 += 1
		await get_tree().physics_frame
		var here: Vector2 = _player.global_position
		var xform := get_viewport().get_canvas_transform()
		still = still + 1 if here == prev_pos and xform == prev_xform else 0
		prev_pos = here
		prev_xform = xform
	print("[mask-shot] 取景静置：用了 %d 拍（still=%d，player=%s 路径=%s 场景=%s）"
		% [guard2, still, str(prev_pos), str(_player.get_path()), str(get_tree().current_scene.scene_file_path)])

	_check("进关那一拍遮罩层就在场上、构件脚本挂上了、皮也画上了（layer=%d script=%s visible=%s）"
		% [_mask.layer, str(_mask.get_script() != null), str(_mask.visible)],
		_sprite.texture != null and _mask.visible and _mask.get_script() != null)
	print("[mask-shot] 取景：viewport=%s zoom=%s cam=%s xform=%s" % [
		str(get_viewport().get_visible_rect().size), str(_camera.zoom),
		str(_camera.global_position), str(get_viewport().get_canvas_transform())])

	# —— 空对照：连拍两张"把遮罩藏掉"，差值必须为 0 ——
	var ref := await _grab("0 无遮罩参照", true, 0.0)
	# 底片每次都重写：选型图与实机帧用的是同一张出生点一帧，比对才不是拿旧摆图对新场。
	var base_err := ref.save_png(ProjectSettings.globalize_path(BASE_FILE))
	print("[mask-shot] base=%d -> %s（改过场就重跑 gen_dream_mask_preview.py，再跑本器验⑥）"
		% [base_err, BASE_FILE])
	var ref2 := await _grab("1 无遮罩再拍一张（空对照）", true, 0.0)
	_check("空对照：出生点这一屏是静的（两张无遮罩帧差 %d 格）—— 不然下面那些逐字节判据都是空的"
		% _diff_count(ref, ref2), _diff_count(ref, ref2) == 0)

	# —— ① + ② 钉住那一拍 ——
	var held := await _grab("2 held（钉住，相位 0）", false, 0.0)
	# 圆心这条要在**走完 SETTLE 拍之后**判：头几拍视口还没有当前相机，`get_canvas_transform()`
	# 拿到的是没有相机的变换，那时候比什么都是假的。
	# 期望值带清单那个弧心偏移（−5 世界像素 = 屏上 10 格），不是"屏心"那个常量。
	var want_centre := _screen_of(_player.global_position
		+ Vector2(0.0, float(_m["arc_origin_y"])))
	_check("圆心跟的是玩家在屏幕上的位置＋弧心偏移（实测 %s 对 %s）"
		% [str(_sprite.position), str(want_centre)], _sprite.position.distance_to(want_centre) < 2.0)
	_centre = _sprite.position
	# **这一层真的往屏上画了东西吗**：`held` 与无遮罩底片的差格数。暗关里屏角本来就是遮罩色，
	# 只比"角上是不是那档色"会假绿（实测过：整屏 83% 都是 `screen` 那一色，遮罩没画也"通过"）。
	var painted := _diff_count(held, ref)
	_check("① 遮罩真的改变了这一屏（与无遮罩底片差 %d 格，判据下限 %d 格）" % [painted, MIN_PAINT],
		painted >= MIN_PAINT)
	_check("① 屏角被压到清单那档色（实测 %s，应≈%s）" % [str(held.get_pixel(4, 4)), str(_want_colour())],
		_near(held.get_pixel(4, 4), _want_colour()))
	_check("① 亮区中心一字未改（%s 对 %s）"
		% [str(held.get_pixel(int(_centre.x), int(_centre.y))),
			str(ref.get_pixel(int(_centre.x), int(_centre.y)))],
		held.get_pixel(int(_centre.x), int(_centre.y)) \
		== ref.get_pixel(int(_centre.x), int(_centre.y)))
	var mid_held := _mid_radius(held, ref)
	var want_r := _want_radius(_last_progress, _last_phase)
	# 量的是**软边中点**（alpha 过 0.5 那一档），不是"第一处不同"也不是"到了遮罩色"：
	# 前者被对比度与 8 bit 取整牵着走（实测 76 灰底上 80.2 的亮区报成 83），后者被容差牵着走
	# （TOL=8 时 108 就算"暗到底"，按算式要到 116）。smoothstep 是对称的 ⇒ 中点恒在
	# `r × (1 + w/2)`，与底片是什么颜色无关。
	var want_mid := want_r * (1.0 + float(_m["edge_width"]) / 2.0)
	_check(("② 屏上软边中点 %.1f 世界像素（按算式 %.1f = (清单 %.0f + 这一拍相位 %.2f 的呼吸 %.1f) × 1.225）")
		% [mid_held, want_mid, float(_m["radius"]), _last_phase, want_r - float(_m["radius"])],
		absf(mid_held - want_mid) <= 1.5)

	# —— ⑥ 同源：这一帧与批过的那张单卡逐像素比 ——
	# 从磁盘读原始 PNG，不走 `load()`：导入后的纹理要经过一次解码，比对的两个坐标系
	# 得是"生成器写出去的那张图"与"引擎画出来的那一帧"，中间不该再夹一个环节。
	var card := Image.new()
	var card_bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(CARD))
	if card_bytes.is_empty() or card.load_png_from_buffer(card_bytes) != OK:
		push_error("[mask-shot] 读不到 %s —— 先跑 py tools/gen_dream_mask_preview.py" % CARD)
		_fails += 1
	else:
		var bad := 0
		var worst := 0
		var first := Vector2i.ZERO
		for y in range(0, 720, 3):
			for x in range(0, 1280, 3):
				var pv := _delta3(held.get_pixel(x, y), card.get_pixel(x, y))
				worst = maxi(worst, pv)
				if pv > TOL:
					if bad == 0:
						first = Vector2i(x, y)
					bad += 1
		_check("⑥ 真帧 == 批过那张卡：抽样 %d 格，超差 %d 格（第一处 (%d,%d)，单格最大差 %d/255）"
			% [int(720 / 3) * int(1280 / 3), bad, first.x, first.y, worst], bad == 0)
		_stamp(_diff_image(held, card), 6)

	# —— ③ 呼吸另一相 ——
	var breath := await _grab("3 breath（相位 1/4 圈）", false, float(_m["breath_period"]) / 4.0)
	var mid_breath := _mid_radius(breath, ref)
	var want_shift := (_want_radius(_last_progress, _last_phase) - want_r) \
		* (1.0 + float(_m["edge_width"]) / 2.0)
	_check("③ 呼吸实测中点位移 %.1f 世界像素（按两拍实际相位应为 %.1f，清单满幅 %.0f）"
		% [mid_breath - mid_held, want_shift, float(_m["breath_amplitude"])],
		absf((mid_breath - mid_held) - want_shift) <= 1.5 and absf(want_shift) >= 3.0)

	# —— ④ 破完四只 → 张开跟着进度 ——
	for action in [&"move_left", &"move_down", &"jump", &"move_right"]:
		Input.action_press(action)
		await _frame(3)
		Input.action_release(action)
		await _frame(3)
	var waited := 0
	while _player.wake_progress() <= 0.0 and waited < 120:
		waited += 1
		await get_tree().physics_frame
	var opening := await _grab("4 opening（张开中）", false, 0.0)
	var p := _last_progress
	var want_open_mid := _want_radius(p, _last_phase) * (1.0 + float(_m["edge_width"]) / 2.0)
	var mid_open := _mid_radius(opening, ref)
	_check("前提：真的进了苏醒窗口（抓帧那一拍 progress=%.2f）" % p, p > 0.02)
	_check("④ progress=%.2f 时屏上中点 %.1f，按算式应为 %.1f（钉住那拍 %.1f；亮区基值 %.0f 张向 %.0f）"
		% [p, mid_open, want_open_mid, mid_held, float(_m["radius"]), float(_m["open_radius"])],
		absf(mid_open - want_open_mid) <= 3.0 and mid_open > mid_held + 3.0)

	# —— ⑤ 醒完收摊 ——
	waited = 0
	while _player.wake_progress() >= 0.0 and waited < 400:
		waited += 1
		await get_tree().physics_frame
	var done := await _grab("5 done（窗口走完）", false, 0.0)
	_check("前提：窗口真的走完了（等了 %d 拍，progress=%.1f）" % [waited, _player.wake_progress()],
		_player.wake_progress() < 0.0)
	_check("⑤ 醒完遮罩自己隐形（visible=%s）" % str(_mask.visible), not _mask.visible)
	# 这一条**不**拿整屏逐字节比底片：泡没了、人换了帧，那一屏本来就变了（实测差 2436 格），
	# 那种判据会把"正常收场"报成"留了一层忘了关的暗角"。要问的只有"外圈还压着吗" ⇒
	# 只量外圈（半径 130..300 世界像素八条射线），并拿钉住那一拍的同一批采样当正对照。
	var outer_done := _outer_diff(done, ref)
	var outer_held := _outer_diff(held, ref)
	_check("⑤ 醒完外圈 %d 格采样与底片一致（差 %d 格）；钉住那一拍同一批采样差 %d/%d 格（正对照）"
		% [outer_done[1], outer_done[0], outer_held[0], outer_held[1]],
		outer_done[0] == 0 and outer_held[1] > 0 and outer_held[0] >= outer_held[1] * 0.5)

	var err := _strip.save_png("%s/%s" % [OUT_DIR, OUT_FILE])
	print("[mask-shot] saved=%d fails=%d -> %s/%s" % [err, _fails, OUT_DIR, OUT_FILE])
	get_tree().quit(_fails > 0)


## 抓一帧。呼吸相位是构件自己攒的时间，不钉住的话每张帧都是不同相位，②③④那些半径
## 读数就没法比。钉法是：走完 SETTLE 拍让位置收敛 → 写 `_breath` → **再走恰好一拍**
## （半径是 `_physics_process` 算的，写完不当场出图就用不上），出图前把这一拍的
## `_breath` 与 progress 一起记下 —— 判据算的是"画出来的那一拍实际是什么相位"，
## 而不是"我以为钉到了 0"（物理拍一走，`_breath` 必然多一个步长）。
func _grab(tag: String, hide_mask: bool, breath: float) -> Image:
	# 藏的是**精灵自己**，不是那层：构件每拍都按苏醒进度写 `_mask.visible`，
	# 工具写 `visible=false` 下一拍就被它改回 true —— 那样"无遮罩参照"其实带着遮罩，
	# 空对照与 ① 全都在比两张同样的图（第一版就是这么 0 格差、把"没画"读成"画了"）。
	_sprite.visible = not hide_mask
	for _i in SETTLE:
		await get_tree().physics_frame
	_mask.set("_breath", breath)
	await get_tree().physics_frame
	_last_phase = float(_mask.get("_breath"))
	_last_progress = _player.wake_progress()
	print("[mask-shot]   %s player=%s cur_cam=%s cam_of_player=%s xform=%s sprite_pos=%s scale=%s" % [
		tag, str(_player.global_position),
		str(get_viewport().get_camera_2d().global_position) if get_viewport().get_camera_2d() != null else "<none>",
		str(_camera.global_position), str(get_viewport().get_canvas_transform()),
		str(_sprite.position), str(_sprite.scale)])
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var full: Image = get_viewport().get_texture().get_image()
	var copy := Image.create(full.get_width(), full.get_height(), false, full.get_format())
	copy.blit_rect(full, Rect2i(0, 0, full.get_width(), full.get_height()), Vector2i.ZERO)
	copy.convert(Image.FORMAT_RGB8)
	_stamp(copy, _cell)
	print("[mask-shot] row %d = %s" % [_cell, tag])
	_cell += 1
	return copy


func _stamp(img: Image, slot: int) -> void:
	img.convert(Image.FORMAT_RGB8)
	_strip.blend_rect(img, Rect2i(0, 0, mini(img.get_width(), 1280), mini(img.get_height(), 720)),
		Vector2i(0, 10 + slot * 730))


func _screen_of(at: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * at


## 亮区半径 = 进度的纯函数（+ 呼吸）。数全从清单来，与 `dream_mask.gd` 里那条同式 ——
## 这条判据比的是"屏上量出来的 == 清单算出来的"，所以它测的是构件到底有没有读清单、
## 有没有把进度接上去，不是第二份调参（改清单，期望值自己跟着走）。
func _want_radius(progress: float, phase: float) -> float:
	var p := clampf(progress, 0.0, 1.0)
	var base := lerpf(float(_m["radius"]), float(_m["open_radius"]), p)
	var amp := float(_m["breath_amplitude"]) * (1.0 - p)
	return base + amp * sin(TAU * phase / float(_m["breath_period"]))


func _want_colour() -> Color:
	var c: Array = _m["colour"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func _near(a: Color, b: Color) -> bool:
	return _delta3(a, b) <= TOL


## 两色的最大单通道差（8 bit 档），所有像素级判据都走这一条。
func _delta3(a: Color, b: Color) -> int:
	return maxi(maxi(absi(int(a.r8) - int(b.r8)), absi(int(a.g8) - int(b.g8))),
		absi(int(a.b8) - int(b.b8)))


## 沿八条射线各量一次"软边中点"（反解出的 alpha 过 0.5 那一档），取中位数。
## 为什么不是"第一处不同"或"到了遮罩色"：前者被 8 bit 取整与对比度牵着走（76 灰底上
## 80.2 的亮区实测报成 83），后者被容差牵着走（TOL=8 时 108 就算暗到底，按算式要到 116）。
## smoothstep 是对称的 ⇒ 中点恒在 `r × (1 + w/2)`，与底片什么颜色无关；alpha 从像素反解，
## 只在"该通道底片与遮罩色差得开"的格子上解，所以空场与内容上都能量。
func _mid_radius(img: Image, ref: Image) -> float:
	var found: Array[float] = []
	for ray in 8:
		var ang := TAU * float(ray) / 8.0
		var prev_a := -1.0
		var prev_d := 0.0
		var hit := -1.0
		var d := 2.0
		while d < float(_m["corner_radius"]):
			var x := int(round(_centre.x + cos(ang) * d * ZOOM))
			var y := int(round(_centre.y + sin(ang) * d * ZOOM))
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				var a := _alpha_at(img, ref, x, y)
				if a >= 0.0:
					if a >= 0.5 and (prev_a < 0.0 or prev_a >= 0.5):
						hit = d
						break
					if a >= 0.5:
						hit = prev_d + (d - prev_d) * (0.5 - prev_a) / maxf(a - prev_a, 0.0001)
						break
					prev_a = a
					prev_d = d
			d += 0.5
		if hit >= 0.0:
			found.append(hit)
	if found.is_empty():
		return -1.0
	found.sort()
	return found[found.size() / 2]


## 反解这一格的遮罩 alpha（0..1）；底片与遮罩色太接近 ⇒ 给 −1（这一格量不动）。
func _alpha_at(img: Image, ref: Image, x: int, y: int) -> float:
	var b := ref.get_pixel(x, y)
	var o := img.get_pixel(x, y)
	var m := _want_colour()
	var best := -1.0
	var best_span := MIN_SPAN
	var bv := [b.r, b.g, b.b]
	var ov := [o.r, o.g, o.b]
	var mv := [m.r, m.g, m.b]
	for i in range(3):
		var span: float = absf(float(bv[i]) - float(mv[i]))
		if span < best_span:
			continue
		best_span = span
		best = clampf((float(bv[i]) - float(ov[i])) / (float(bv[i]) - float(mv[i])), 0.0, 1.0)
	return best


## 外圈（半径 130..300 世界像素，八条射线）与底片不同的格数 —— 返回 [不同, 有效采样数]。
## 出屏的格子不算有效（屏角那几格在斜射线上会掉出去）。
func _outer_diff(img: Image, ref: Image) -> Array:
	var bad := 0
	var total := 0
	for ray in 8:
		var ang := TAU * float(ray) / 8.0
		for d in range(130, 301, 10):
			var x := int(round(_centre.x + cos(ang) * float(d) * ZOOM))
			var y := int(round(_centre.y + sin(ang) * float(d) * ZOOM))
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			total += 1
			if not _same(img.get_pixel(x, y), ref.get_pixel(x, y)):
				bad += 1
	return [bad, total]


func _same(a: Color, b: Color) -> bool:
	return a.r8 == b.r8 and a.g8 == b.g8 and a.b8 == b.b8


func _diff_count(a: Image, b: Image) -> int:
	if a.get_size() != b.get_size():
		return -1
	var n := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			if not _same(a.get_pixel(x, y), b.get_pixel(x, y)):
				n += 1
	return n


## 同源比对那张：差值 ×8 放大成可见的图（全黑 = 逐像素相同）。
func _diff_image(a: Image, card: Image) -> Image:
	var out := Image.create(1280, 720, false, Image.FORMAT_RGB8)
	for y in range(720):
		for x in range(1280):
			var v: int = mini(_delta3(a.get_pixel(x, y), card.get_pixel(x, y)) * 8, 255)
			out.set_pixel(x, y, Color8(v, v, v))
	return out


func _frame(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _check(label: String, passed: bool) -> void:
	print("[mask-shot] %s %s" % ["ok  " if passed else "FAIL", label])
	if not passed:
		_fails += 1
