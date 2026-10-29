extends Node
## D77 梦泡的开窗实拍器：皮只能看见才算数。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/dream_bubble_shot.tscn
## 退出码 = 有没有 FAIL，所以它兼任一条开窗守门。
## 素材：`res://assets/ui/frames/dream_bubble_shot.png`（9 行 × 4 列，列序 = A、S、space、D，
## 就是头顶弧上从左到右；行序 = 底图 / 钉住 / 撒坏 / 还原 / 按下去 / 底图空对照 / 那只演完 /
## 平移后 / 全破收场）。
##
## 为什么还要再跑一遍：`verify_kit` 那份静态核对的是"清单 ↔ InputMap ↔ 磁盘 PNG"三方对得上，
## `kit_selftest` 第 26 组钉的是节点与数值行为（谁被按破、什么时候发 completed、皮钉在第 0 帧）。
## 两边都**看不见屏幕**。这里钉的六条全是"只有渲染出来才知道"的：
##   ① 上屏：钉住那一拍，四只各自的面板与"把泡藏掉"的底图不同，且差异像素 ≥ 面板面积的三成五
##      —— 只"不同"不够，一条发丝也不同；
##   ② 按下去真的变了：按 A 之后两三拍 A 那块与出厂态不同，而其余三块逐字节不动（不误伤）；
##   ③ 演完真的没了：破的那三帧走完后 A 回到**底图**，其余三块仍是出厂态；
##   ④ 跟人走：把玩家平移 40 px，没破的泡在新位置与原位置**逐字节相同** —— 世界像素下的摆位，
##      不是屏幕像素（这条那两份守门都测不到）；
##   ⑤ 收场：四只全破后节点从场上消失、四块都回到底图、皮交回现成的苏醒剪辑（又在播了）；
##   ⑥ 同源（皮 == 出货）：出厂态面板里"落在源 PNG 调色板内"的像素占比远高于同一块位置藏掉泡
##      之后的墙 —— 证明上屏的就是批过那张图，而不是另一套代码现算的形状。
## ① 自带一次撒坏对照：把 A 从构件的 `_items` 里藏掉，那条读数必须转成"与底图相同"；
## 否则"差异像素 ≥ 三成五"可能是永远为真的假绿。

const LEVEL := "res://scenes/levels/level_template.tscn"
const MANIFEST_PATH := "res://assets/props/dream_bubble.json"
const PART_DIR := "res://assets/props/dream_bubble/"
const OUT_DIR := "res://assets/ui/frames"
const OUT_FILE := "dream_bubble_shot.png"

const ZOOM := 2.0
const SCALE_UP := 2                    # 面板再放大一档，好让人肉眼看得清那 5×7 的字
const GAP := 10
const MIN_INK := 0.35                  # ① 差异像素占面板面积的最低比例
const MIN_PALETTE := 0.6               # ⑥ 出厂态那块命中源色调色板的比例下限
const PALETTE_MARGIN := 0.25           # ⑥ 与"藏掉泡之后同一块位置"的差距下限
const TOL := 24                        # ⑥ 与源色调色板的容差（每通道，8 bit）
const SETTLE := 4
const MOVE_X := 40.0

## 常驻根的替身：这一拍要演，所以 `take_intro()` 第一次必须给 true；重载两条口留着，
## 免得模板里哪一发意外把人杀死时基类找不到委托对象而是报错。
class DreamShotRoot extends Node:
	var _taken := false
	var reloads := 0
	func get_run_state() -> Dictionary:
		return {}
	func take_intro() -> bool:
		if _taken:
			return false
		_taken = true
		return true
	func reload_level() -> void:
		reloads += 1
	func restart_level() -> void:
		reloads += 1

var _camera: Camera2D
var _player: Player
var _level: Node
var _dream: Node
var _visual: PlayerVisual
var _rects: Array[Rect2] = []
var _names: Array[String] = []
var _panels := Vector2i.ZERO
var _strip: Image
var _cell := 0
var _fails := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var world_root := DreamShotRoot.new()
	world_root.name = "DreamShotRoot"
	world_root.add_to_group(&"world_root")
	add_child(world_root)

	_level = load(LEVEL).instantiate()
	add_child(_level)

	var guard := 0
	while _player == null and guard < 180:
		guard += 1
		await get_tree().process_frame
		var p := get_tree().get_first_node_in_group(&"player") as Player
		if p == null:
			continue
		var cam := p.get_node_or_null("PlayerCamera") as Camera2D
		if cam == null:
			continue
		_player = p
		_camera = cam
	if _player == null:
		push_error("[dream-shot] 等不到玩家（模板里没有？）")
		get_tree().quit(1)
		return

	_dream = _level.get_node_or_null("DreamBubbles")
	_visual = _player.get_node_or_null("Visual/Sprite") as PlayerVisual
	_check("进模板那一拍就把四只泡挂上来了（关卡根 `_maybe_intro()` 拉起）", _dream != null)
	_check("拿得到那张皮（⑤ 要看它有没有开始播）", _visual != null)
	if _dream == null or _visual == null:
		get_tree().quit(1)
		return

	# 人钉住不动：泡跟着他算位置，他要是往下掉，每一行拍的都是不同的地方。
	_player.set_physics_process(false)
	_player.velocity = Vector2.ZERO
	_camera.position_smoothing_enabled = false
	_camera.zoom = Vector2(ZOOM, ZOOM)
	_aim(_player.global_position + Vector2(0.0, -24.0))

	_build_rects()
	var pw := 0
	var ph := 0
	for rect in _rects:
		pw = maxi(pw, int(rect.size.x * ZOOM * float(SCALE_UP)))
		ph = maxi(ph, int(rect.size.y * ZOOM * float(SCALE_UP)))
	_panels = Vector2i(pw, ph)
	_strip = Image.create(_panels.x * 4 + GAP * 5, (_panels.y + GAP) * 9 + GAP,
		false, Image.FORMAT_RGB8)
	_strip.fill(Color8(10, 11, 16))

	# —— 底图：把整个泡节点藏掉拍一张，后面每一行都跟它比 ——
	var base := await _row("0 base（泡藏掉）", true)

	# —— ① 上屏 ——
	var hold := await _row("1 hold（钉住，四只出厂态）", false)
	for i in 4:
		var area := float(base[i].get_width() * base[i].get_height())
		var ink := float(_diff(base[i], hold[i])) / area
		_check("① %s 上屏：与底图差 %d 像素（占整块 %.0f%%，门槛 %.0f%%）"
			% [_names[i], _diff(base[i], hold[i]), ink * 100.0, MIN_INK * 100.0], ink >= MIN_INK)
	var palette := _palette_of("a")
	var ink_hits := _palette_ratio(hold[0], palette)
	var base_hits := _palette_ratio(base[0], palette)
	print("[dream-shot] ⑥ 调色板命中：泡 %.3f / 同一块位置藏掉泡 %.3f（tol=%d，色数=%d）"
		% [ink_hits, base_hits, TOL, palette.size()])
	_check("⑥ A 那块有 %.0f%% 的像素落在 a_0.png 的调色板内（门槛 %.0f%%）：上屏的就是批过那张图"
		% [ink_hits * 100.0, MIN_PALETTE * 100.0], ink_hits >= MIN_PALETTE)
	_check("⑥ 同一块位置藏掉泡后只剩 %.0f%% 命中：这条读数在区分，不是恒真（差 %.0f%%，门槛 %.0f%%）"
		% [base_hits * 100.0, (ink_hits - base_hits) * 100.0, PALETTE_MARGIN * 100.0],
		ink_hits - base_hits >= PALETTE_MARGIN)

	# —— ① 的撒坏对照：把 A 藏进构件的 `_items`，那条差异读数必须转成 0 ——
	var items: Array = _dream.get("_items")
	items[0]["visible"] = false
	_dream.queue_redraw()
	var sabotage := await _row("2 sabotage（A 被藏掉）", false)
	_check("撒坏：藏掉 A 之后 A 与底图差 %d 像素（应为 0）—— 证明上面那条差异读数会响"
		% _diff(base[0], sabotage[0]), _diff(base[0], sabotage[0]) == 0)
	_check("撒坏时其余三只照旧在（最小差 %d 像素）" % _min_diff(base, sabotage, 1),
		_min_diff(base, sabotage, 1) > 0)
	items[0]["visible"] = true
	_dream.queue_redraw()
	var back := await _row("3 back（A 还原）", false)
	_check("还原后 A 重新逐字节等于出厂态（差 %d 字节）" % _byte_diff(hold[0], back[0]),
		_byte_diff(hold[0], back[0]) == 0)

	# —— ② 按下去真的变了，且不误伤其余 ——
	Input.action_press(&"move_left")
	await _frame(2)
	Input.action_release(&"move_left")
	var pressing := await _row("4 press（A 正在破）", false)
	_check("② 按过 A：A 那块与出厂态不同（差 %d 字节）" % _byte_diff(hold[0], pressing[0]),
		_byte_diff(hold[0], pressing[0]) > 0)
	_check("② 按过 A：其余三块逐字节不动（最大差 %d 字节）" % _max_diff(hold, pressing, 1),
		_max_diff(hold, pressing, 1) == 0)

	# —— ③ 那三帧演完：回到**底图**，不是停在半路 ——
	await _frame(20)
	# 先做一次"底图 vs 底图"的空对照：模板里要是还有别的东西在动（走带的钟、余辉、落灰…），
	# 跨时刻的逐字节比较就不成立，得先看这条读数自己稳不稳。
	var base2 := await _row("5 base again（泡再藏一次，空对照）", true)
	print("[dream-shot] ③ 空对照：底图 vs 底图 差 %d 字节（A %s / B %s）"
		% [_max_diff(base, base2, 0), str(_diff_bbox(base[0], base2[0])),
			str(_diff_bbox(base[1], base2[1]))])
	var gone := await _row("6 gone（A 演完）", false)
	print("[dream-shot] ③ 诊断：A 这块残留 %d 字节，差异包围盒 %s（面板 %s）"
		% [_byte_diff(base[0], gone[0]), str(_diff_bbox(base[0], gone[0])),
			str(base[0].get_size())])
	_check("③ A 演完 = 与底图逐字节相同（差 %d 字节）" % _byte_diff(base[0], gone[0]),
		_byte_diff(base[0], gone[0]) == 0)
	_check("③ A 演完时其余三块仍是出厂态（最大差 %d 字节）" % _max_diff(hold, gone, 1),
		_max_diff(hold, gone, 1) == 0)

	# —— ④ 跟人走：世界像素平移 40，摆位跟着走 ——
	_player.global_position += Vector2(MOVE_X, 0.0)
	await _frame(3)
	# 取景框跟着重算：这一条要比的是"同一张皮搬了 40 个世界像素"，框要是还钉在老地方，
	# 裁到的是空墙，测的就不是跟随而是取景器自己。
	_build_rects()
	var moved := await _row("7 moved（人平移 %.0f px）" % MOVE_X, false)
	_check("前提：这一发真的把泡带着走了（泡节点 = 玩家位置 + 弧心偏移，x 已跟到 %.1f）"
		% _dream.global_position.x,
		absf(_dream.global_position.x - _player.global_position.x) < 0.01)
	_check("④ 人挪了 %.0f px 后，三只没破的泡在新位置与原来逐字节相同（最大差 %d 字节）"
		% [MOVE_X, _max_diff(hold, moved, 1)], _max_diff(hold, moved, 1) == 0)
	_player.global_position -= Vector2(MOVE_X, 0.0)
	await _frame(3)
	_build_rects()

	# —— ⑤ 全破收场：三只一次按完，再等节点消失（每按一只就等一次会永远等不到）——
	for action in [&"move_down", &"jump", &"move_right"]:
		if _level.get_node_or_null("DreamBubbles") == null:
			break
		Input.action_press(action)
		await _frame(3)
		Input.action_release(action)
		await _frame(3)
		print("[dream-shot] ⑤ 按过 %s：已破 %d 只" % [str(action), _dream.call("popped_count")])
	var waited := 0
	while _level.get_node_or_null("DreamBubbles") != null and waited < 180:
		waited += 1
		await get_tree().physics_frame
	print("[dream-shot] ⑤ 等了 %d 拍；节点还在=%s"
		% [waited, str(_level.get_node_or_null("DreamBubbles") != null)])
	var done := await _row("8 done（四只全破、引导撤掉）", false)
	_check("⑤ 演完就把整个泡节点从场上撤掉（留下 = 还能再按的假象）",
		_level.get_node_or_null("DreamBubbles") == null)
	_check("⑤ 四块都回到底图（最大差 %d 字节）" % _max_diff(base, done, 0),
		_max_diff(base, done, 0) == 0)
	_check("⑤ 交回的是现成的苏醒剪辑：皮又在播了（animation=%s playing=%s）"
		% [str(_visual.animation), str(_visual.is_playing())],
		_visual.animation == &"wake" and _visual.is_playing())

	var err := _strip.save_png("%s/%s" % [OUT_DIR, OUT_FILE])
	print("[dream-shot] saved=%d fails=%d -> %s/%s" % [err, _fails, OUT_DIR, OUT_FILE])
	get_tree().quit(_fails > 0)


## 弧的几何一律读清单，与构件同一份数 —— 这里抄一份半径就等于允许两边分叉。
func _build_rects() -> void:
	_rects.clear()
	_names.clear()
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	var radius := float(manifest["radius"])
	for entry in manifest["bubbles"]:
		var deg := float(entry["deg"])
		var size: Array = manifest["parts"][str(entry["part"])]
		var at: Vector2 = _dream.global_position \
			+ Vector2(radius * cos(deg_to_rad(deg)), -radius * sin(deg_to_rad(deg)))
		var half := Vector2(size[0], size[1]) * 0.5
		_rects.append(Rect2(at - half, Vector2(size[0], size[1])))
		_names.append(str(entry["part"]))


## 把取景框移到目标 —— 按"当前屏幕中心在世界里的位置"反推 offset，不用"目标 − 相机坐标"
## 那一手（相机位置被关卡限位夹过，那一手会算歪，D76 实测偏 188 px）。
func _aim(target: Vector2) -> void:
	var size := get_viewport().get_visible_rect().size
	var tf := get_viewport().get_canvas_transform()
	var seen: Vector2 = tf.affine_inverse() * (size * 0.5)
	_camera.offset += target - seen


func _row(tag: String, hide_dream: bool) -> Array:
	if hide_dream:
		_dream.visible = false
	for _i in SETTLE:
		await get_tree().physics_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var full: Image = get_viewport().get_texture().get_image()
	var crops: Array = []
	for rect in _rects:
		crops.append(_crop(full, rect))
	if hide_dream:
		_dream.visible = true
	_stamp_row(crops, tag)
	return crops


func _crop(full: Image, world: Rect2) -> Image:
	var tf := _camera.get_canvas_transform()
	var tl: Vector2 = tf * world.position
	var px := Vector2i(int(round(world.size.x * _camera.zoom.x)),
		int(round(world.size.y * _camera.zoom.y)))
	var want := Rect2i(Vector2i(roundi(tl.x), roundi(tl.y)), px)
	want = want.intersection(Rect2i(0, 0, full.get_width(), full.get_height()))
	if want.size != px:
		push_error("[dream-shot] 取景框出屏了：%s 只裁到 %s" % [str(world), str(want)])
		_fails += 1
	return full.get_region(want)


## 面板尺寸统一（space 那只比另外三只宽），所以贴进横条前先居中垫一块同宽的画布。
func _stamp_row(crops: Array, tag: String) -> void:
	var canvas := Image.create(_panels.x, _panels.y, false, Image.FORMAT_RGB8)
	for i in crops.size():
		var crop: Image = crops[i]
		crop.resize(int(round(crop.get_width() * float(SCALE_UP))),
			int(round(crop.get_height() * float(SCALE_UP))), Image.INTERPOLATE_NEAREST)
		crop.convert(Image.FORMAT_RGB8)
		canvas.fill(Color8(10, 11, 16))
		canvas.blend_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
			Vector2i((_panels.x - crop.get_width()) / 2, (_panels.y - crop.get_height()) / 2))
		_strip.blend_rect(canvas, Rect2i(Vector2i.ZERO, canvas.get_size()),
			Vector2i(GAP + i * (_panels.x + GAP), GAP + _cell * (_panels.y + GAP)))
	_cell += 1
	print("[dream-shot] row %d = %s" % [_cell - 1, tag])


## 两张同尺寸面板的**字节**差（0 = 逐字节相同）。
func _byte_diff(a: Image, b: Image) -> int:
	if a.get_size() != b.get_size():
		return -1
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	if da.size() != db.size():
		return -1
	var n := 0
	for i in da.size():
		if da[i] != db[i]:
			n += 1
	return n


## 差异**像素**数（一个像素三个通道，任一变就算一个）。
func _diff(a: Image, b: Image) -> int:
	if a.get_size() != b.get_size():
		return -1
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n


## 差异像素的包围盒（只在诊断时用）：残留是"散在整块"还是"缩在一条边"，决定它是皮的问题
## 还是取景/取整的问题 —— 光看一个字节数分不出来。
func _diff_bbox(a: Image, b: Image) -> Rect2i:
	if a.get_size() != b.get_size():
		return Rect2i(0, 0, -1, -1)
	var box := Rect2i(0, 0, -1, -1)
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				var point := Vector2i(x, y)
				if box.size.x < 0:
					box = Rect2i(point, Vector2i.ZERO)
				else:
					box = box.expand(point)
	return box


func _max_diff(rows_a: Array, rows_b: Array, from: int) -> int:
	var worst := 0
	for i in range(from, rows_a.size()):
		worst = maxi(worst, _byte_diff(rows_a[i], rows_b[i]))
	return worst


func _min_diff(rows_a: Array, rows_b: Array, from: int) -> int:
	var best := 1 << 30
	for i in range(from, rows_a.size()):
		best = mini(best, _diff(rows_a[i], rows_b[i]))
	return best


## 源 PNG 的调色板：所有不透明格的颜色。零件是 lossless 导入，拿到的就是画师那批数，
## 所以"上屏的像素落在色板内"这条比的是**出货的皮**，不是选型图里另算的一份。
func _palette_of(part: String) -> Array[Color]:
	var out: Array[Color] = []
	var tex := load("%s%s_0.png" % [PART_DIR, part]) as Texture2D
	if tex == null:
		push_error("[dream-shot] 读不到 %s%s_0.png（先跑 --import）" % [PART_DIR, part])
		_fails += 1
		return out
	var img := tex.get_image()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a8 > 127 and not out.has(c):
				out.append(c)
	return out


func _palette_ratio(img: Image, palette: Array) -> float:
	if palette.is_empty() or img.get_width() == 0 or img.get_height() == 0:
		return 0.0
	var hit := 0
	for y in img.get_height():
		for x in img.get_width():
			if _near_palette(img.get_pixel(x, y), palette):
				hit += 1
	return float(hit) / float(img.get_width() * img.get_height())


func _near_palette(c: Color, palette: Array) -> bool:
	for p in palette:
		var pc: Color = p
		if absf(float(c.r8 - pc.r8)) <= TOL \
				and absf(float(c.g8 - pc.g8)) <= TOL \
				and absf(float(c.b8 - pc.b8)) <= TOL:
			return true
	return false


func _frame(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _check(label: String, passed: bool) -> void:
	print("[dream-shot] %s %s" % ["ok  " if passed else "FAIL", label])
	if not passed:
		_fails += 1
