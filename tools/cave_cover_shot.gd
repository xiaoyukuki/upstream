extends Node
## 一次性实拍器：在**真关卡帧**上拍一个节点里两块互不相连的假墙盖，并当场验像素事实。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/cave_cover_shot.tscn
## 退出码 = 有没有 FAIL，所以它兼任一条开窗守门。
##
## 为什么要两块（2026-10-28 订正）：老实现拿**全部格子的外接框**判"站进屋里"、拿**一个
## `Mouth`** 判远近，而 `modulate` 是节点级的 —— 一个人在两块之间（外接框里、不在任何
## 一块上）会让整片一起透明，靠近 A 的口子也顺带把 B 变淡。这一跑专拍"两块各判各的"。
##
## 五条，每条都能被一次撒坏弄红：
##   ① 接缝：远态两块都与同一面墙的参照块**逐字节相同**；把盖子整体挪 1 px 后必须
##      **不相同**（顺带证明这条判据本身会响）；
##   ② 藏住：远态两块屋里那块洋红都一个像素看不见；
##   ③ 露出来：站 A 口前，A 的内容在、整块与参照块不同，而 **B 仍全挡**（接缝仍为 0、
##      洋红仍看不见）；再站进 A 里，A 照样全隐、B 照旧全挡；
##   ④ 半透：A 的中间档既不等于墙、也没有一个像素是纯洋红；同一站位 B 仍是全挡；
##   ⑤ 位置纯函数：同一站位、世界流着 30 拍，两块的面板逐字节相同且 alpha 一字不动。
## 另有一条回归钉：站在两块**之间**（老实现会整片全隐的那个点）两块都全挡。
##
## 摆位：模板场景这一片区没有地形，所以自建一面 16×6 的墙，抠两个 3×3 的洞，两块洞
## 都画在**同一个** CaveCover 节点里（不相连 ⇒ 运行时拆成 Patch1 / Patch2）；洞里各放
## 一块洋红方块当"里面的路"。墙背后照着模板 `Terrain/WallFill` 那格铺一层背景。
## 两个洞口点 `Mouth` / `Mouth2` 分别贴在 A 左侧、B 右侧。
## 相机靠 `Camera2D.offset` 平移到墙心 —— 人不动（他动起来会触发相机跟随）。
##
## 素材：`res://assets/ui/frames/cave_cover_shot.png`
## （横排四组、每组两块：远 / 两块之间 / A 中间档 / A 口前；每组左 A 右 B）。

const OUT_DIR: String = "res://assets/ui/frames"
const OUT_FILE: String = "cave_cover_shot.png"
const LEVEL: String = "res://scenes/levels/level_template.tscn"
const TILESET: String = "res://assets/tiles/lab_tileset.tres"
const MANIFEST: String = "res://assets/tiles/tiles.json"
const MAGENTA := Color8(255, 0, 255)     # 墙里没有的颜色（读得出来、也不会被色板误判）

## 墙的左上角（世界像素）。整块在模板的相机限位里：限位 Rect2(0,-352,1280,480)。
const AT := Vector2(400.0, -320.0)
const WALL_CELLS := Vector2i(16, 6)
## 两个洞（暗室）与参照块在墙里的格坐标：三块一样大、都在同一行上。
const HOLE_A_CELL := Rect2i(2, 2, 3, 3)
const HOLE_B_CELL := Rect2i(11, 2, 3, 3)
const REF_CELL := Rect2i(6, 2, 3, 3)

## 两档距离（世界像素）。两块之间宽 6 格（96 px），所以 32 / 64 能让"站在中间"两块都全挡。
const NEAR: float = 32.0
const FAR: float = 64.0

const SETTLE_FRAMES: int = 20
const SCALE_UP: int = 2
const GAP: int = 10
const STATES: int = 4

var _camera: Camera2D
var _player: Player
var _level: Node
var _cover: CaveCover
var _wall: TileMapLayer
var _hole_a: Rect2
var _hole_b: Rect2
var _ref: Rect2
var _mouth_a: Vector2
var _mouth_b: Vector2
var _between: Vector2
var _focus: Vector2
var _panel := Vector2i.ZERO
var _strip: Image
var _last_a := PackedByteArray()
var _last_b := PackedByteArray()
var _fails := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
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
		push_error("[cave-shot] 等不到玩家（模板里没有？）")
		get_tree().quit(1)
		return
	# 进树后立刻钉住：模板这一片区没有地板，不钉就一路往下掉，`reload_level` 会把这一跑的
	# 节点连带拆掉。钉 physics 必须在**进树之后**调（进树前那一档会被 _ready 重新登记掉）。
	_player.set_physics_process(false)
	var visual := _player.get_node_or_null("Visual/Sprite") as AnimatedSprite2D
	if visual != null:
		visual.set_process(false)
		visual.pause()
	_camera.position_smoothing_enabled = false

	_build_fixture()
	_panel = Vector2i(int(_hole_a.size.x * _camera.zoom.x * float(SCALE_UP)),
		int(_hole_a.size.y * _camera.zoom.y * float(SCALE_UP)))
	_strip = Image.create(_panel.x * STATES * 2 + GAP * (STATES * 2 + 1),
		_panel.y + GAP * 2, false, Image.FORMAT_RGB8)
	_strip.fill(Color8(10, 11, 16))

	print("[cave-shot] 拆成 %d 块；根上剩 %d 格；Mouth→%s、Mouth2→%s"
		% [_cover.patch_count(), _cover.get_used_cells().size(),
			str(_cover.mouth_point(0)), str(_cover.mouth_point(1))])
	_check("两块不相连的地块拆成 2 块（patch_count=%d）、根层清空（剩 %d 格）"
		% [_cover.patch_count(), _cover.get_used_cells().size()],
		_cover.patch_count() == 2 and _cover.get_used_cells().is_empty())
	_check("Mouth 归给 A、Mouth2 归给 B（%s / %s）"
		% [str(_cover.mouth_point(0)), str(_cover.mouth_point(1))],
		_cover.mouth_point(0).distance_to(_mouth_a) < 0.01
		and _cover.mouth_point(1).distance_to(_mouth_b) < 0.01)

	# —— ① 接缝 / ② 藏住（两块都验） ——
	await _place(_mouth_a + Vector2(-300.0, 0.0))
	await _settle()
	var far := await _grab("far")
	_check("远态两块都 alpha=1（A %.2f / B %.2f）" % [_alpha(0), _alpha(1)],
		_alpha(0) == 1.0 and _alpha(1) == 1.0)
	_check("① 远态：A 与同一面墙的参照块逐字节相同（差 %d 字节）" % int(far["seam_a"]),
		int(far["seam_a"]) == 0)
	_check("① 远态：B 与同一面墙的参照块逐字节相同（差 %d 字节）" % int(far["seam_b"]),
		int(far["seam_b"]) == 0)
	_check("② 远态：A 屋里洋红一个像素都看不见（%d）" % int(far["magenta_a"]),
		int(far["magenta_a"]) == 0)
	_check("② 远态：B 屋里洋红一个像素都看不见（%d）" % int(far["magenta_b"]),
		int(far["magenta_b"]) == 0)
	_stamp(far, 0)

	# —— ① 的撒坏：整体挪 1 px，两块接缝必须同时裂开 ——
	_cover.position.x += 1.0
	await _settle()
	var broken := await _grab("shift-1px")
	_check("① 撒坏：盖子挪 1 px 后 A 接缝差 %d 字节（应 > 0）" % int(broken["seam_a"]),
		int(broken["seam_a"]) > 0)
	_check("① 撒坏：盖子挪 1 px 后 B 接缝差 %d 字节（应 > 0）" % int(broken["seam_b"]),
		int(broken["seam_b"]) > 0)
	_cover.position.x -= 1.0
	await _settle()
	var restored := await _grab("restored")
	_check("① 挪回来：两块接缝重新为 0（A %d / B %d 字节）"
		% [int(restored["seam_a"]), int(restored["seam_b"])],
		int(restored["seam_a"]) == 0 and int(restored["seam_b"]) == 0)

	# —— 回归钉：站在两块之间（老实现整片全隐的那个点） ——
	await _place(_between)
	await _settle()
	var gap := await _grab("between")
	_check("两块之间：两块都全挡（A %.2f / B %.2f）—— 老实现这一拍整片全隐"
		% [_alpha(0), _alpha(1)], _alpha(0) == 1.0 and _alpha(1) == 1.0)
	_check("两块之间：A 接缝仍为 0（%d 字节）" % int(gap["seam_a"]), int(gap["seam_a"]) == 0)
	_check("两块之间：B 接缝仍为 0（%d 字节）" % int(gap["seam_b"]), int(gap["seam_b"]) == 0)
	_check("两块之间：两块屋里都看不见洋红（A %d / B %d）"
		% [int(gap["magenta_a"]), int(gap["magenta_b"])],
		int(gap["magenta_a"]) == 0 and int(gap["magenta_b"]) == 0)
	_stamp(gap, 1)

	# —— ④ 半透：只有 A 变淡，B 仍是墙 ——
	var mid_d: float = (NEAR + FAR) * 0.5
	await _place(_mouth_a + Vector2(-mid_d, 0.0))
	await _settle()
	var mid := await _grab("mid-A")
	var want_mid: float = (FAR - mid_d) / (FAR - NEAR)
	_check("④ 中间档 A alpha=%.2f（按两档应为 %.2f）" % [_alpha(0), want_mid],
		absf(_alpha(0) - want_mid) < 0.02)
	_check("④ 中间档：A 与墙不同（差 %d 字节）" % int(mid["seam_a"]), int(mid["seam_a"]) > 0)
	_check("④ 中间档：A 没有一个像素是纯洋红（%d）——是混合，不是硬切" % int(mid["magenta_a"]),
		int(mid["magenta_a"]) == 0)
	_check("④ 中间档：B 仍全挡（a=%.2f，接缝 %d 字节）" % [_alpha(1), int(mid["seam_b"])],
		_alpha(1) == 1.0 and int(mid["seam_b"]) == 0)
	_stamp(mid, 2)

	# —— ⑤ 位置纯函数：同一站位，世界流着 30 拍 ——
	var t0: float = TimeManager.elapsed_world_time
	await _frame(30)
	var mid2 := await _grab("mid-A-again")
	_check("前提：这 30 拍世界真的在流（%.3f → %.3f）" % [t0, TimeManager.elapsed_world_time],
		TimeManager.elapsed_world_time > t0 + 0.1)
	_check("⑤ 同一站位 30 拍后两块 alpha 一字不动（A %.3f / B %.3f）"
		% [_alpha(0), _alpha(1)],
		absf(_alpha(0) - mid["alpha_a"]) < 0.0001 and absf(_alpha(1) - mid["alpha_b"]) < 0.0001)
	_check("⑤ 逐字节也相同（A 差 %d / B 差 %d 字节）"
		% [int(mid2["same_a"]), int(mid2["same_b"])],
		int(mid2["same_a"]) == 0 and int(mid2["same_b"]) == 0)

	# —— ③ 露出来：站 A 口前，A 开、B 不许跟着开 ——
	await _place(_mouth_a)
	await _settle()
	var near := await _grab("near-A")
	_check("③ 近态：A alpha=0（%.2f）、B 仍 1（%.2f）" % [_alpha(0), _alpha(1)],
		_alpha(0) == 0.0 and _alpha(1) == 1.0)
	_check("③ 近态：A 的内容露出来（洋红 %d 像素）" % int(near["magenta_a"]),
		int(near["magenta_a"]) > 0)
	_check("③ 近态：A 整块与参照块不同（差 %d 字节）" % int(near["seam_a"]),
		int(near["seam_a"]) > 0)
	_check("③ 近态：B 没被顺带打开（接缝 %d 字节、洋红 %d）"
		% [int(near["seam_b"]), int(near["magenta_b"])],
		int(near["seam_b"]) == 0 and int(near["magenta_b"]) == 0)
	_stamp(near, 3)

	# —— 站进 A 里：A 全隐，B 仍全挡（"站进自家格子"按块算） ——
	await _place(_hole_a.get_center())
	await _settle()
	var inside := await _grab("inside-A")
	_check("人在 A 屋里：A alpha=0 且洋红可见（%d），B 仍全挡（接缝 %d 字节）"
		% [int(inside["magenta_a"]), int(inside["seam_b"])],
		_alpha(0) == 0.0 and int(inside["magenta_a"]) > 0
		and _alpha(1) == 1.0 and int(inside["seam_b"]) == 0)

	var err := _strip.save_png("%s/%s" % [OUT_DIR, OUT_FILE])
	print("[cave-shot] saved=%d fails=%d -> %s/%s" % [err, _fails, OUT_DIR, OUT_FILE])
	get_tree().quit(_fails > 0)


## 一面 16×6 的墙 + 两个洞 + 洞上的两块盖子（同一个节点）+ 屋里的内容物。全部按清单里的
## 实心格刷 —— 这就是摆图时作者要做的那三件事（刷墙、刷盖子、放 Mouth），只是这里由脚本代笔。
func _build_fixture() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var bits: Dictionary = manifest["terrain"]["mask_bits"]
	var full := 0
	for key in bits:
		full |= int(bits[key])
	var solid := Vector2i(-1, -1)
	for entry in manifest["terrain"]["tiles"]:
		if int(entry["mask"]) == full:
			solid = Vector2i(int(entry["x"]) / int(manifest["tile"]),
				int(entry["y"]) / int(manifest["tile"]))
	var ts: TileSet = load(TILESET)
	var cell := Vector2(ts.tile_size)

	_paint_backdrop(ts, cell)

	_wall = TileMapLayer.new()
	_wall.name = "FixtureWall"
	_wall.tile_set = ts
	_wall.collision_enabled = false
	_wall.position = AT
	for x in WALL_CELLS.x:
		for y in WALL_CELLS.y:
			var at := Vector2i(x, y)
			if HOLE_A_CELL.has_point(at) or HOLE_B_CELL.has_point(at):
				continue
			_wall.set_cell(at, 0, solid)
	add_child(_wall)

	_cover = load("res://scenes/objects/cave_cover/cave_cover.tscn").instantiate() as CaveCover
	_cover.name = "FixtureCover"
	_cover.tile_set = ts
	_cover.position = AT
	for rect in [HOLE_A_CELL, HOLE_B_CELL]:
		for x in range(rect.position.x, rect.end.x):
			for y in range(rect.position.y, rect.end.y):
				_cover.set_cell(Vector2i(x, y), 0, solid)
	var mouth_a := Marker2D.new()
	mouth_a.name = "Mouth"
	mouth_a.position = Vector2(HOLE_A_CELL.position.x - 1, HOLE_A_CELL.position.y + 1.5) * cell
	_cover.add_child(mouth_a)
	var mouth_b := Marker2D.new()
	mouth_b.name = "Mouth2"
	mouth_b.position = Vector2(HOLE_B_CELL.end.x + 1, HOLE_B_CELL.position.y + 1.5) * cell
	_cover.add_child(mouth_b)
	_cover.reveal_near = NEAR
	_cover.reveal_far = FAR
	add_child(_cover)

	for rect in [HOLE_A_CELL, HOLE_B_CELL]:
		var img := Image.create(int(cell.x * 2.0), int(cell.y * 2.0), false, Image.FORMAT_RGBA8)
		img.fill(MAGENTA)
		var content := Sprite2D.new()
		content.name = "Content%d" % rect.position.x
		content.texture = ImageTexture.create_from_image(img)
		content.position = AT + Vector2(rect.position) * cell + Vector2(rect.size) * cell * 0.5
		content.z_index = 0
		add_child(content)

	_hole_a = Rect2(AT + Vector2(HOLE_A_CELL.position) * cell, Vector2(HOLE_A_CELL.size) * cell)
	_hole_b = Rect2(AT + Vector2(HOLE_B_CELL.position) * cell, Vector2(HOLE_B_CELL.size) * cell)
	_ref = Rect2(AT + Vector2(REF_CELL.position) * cell, Vector2(REF_CELL.size) * cell)
	_mouth_a = mouth_a.global_position
	_mouth_b = mouth_b.global_position
	_between = Vector2(AT.x + WALL_CELLS.x * 0.5 * cell.x, _hole_a.get_center().y)
	_focus = Vector2(_between.x, _hole_a.get_center().y)


## 模板 `Terrain/WallFill` 铺的那一层背景，照着它的**同一格瓦片**在整面墙背后刷一遍。
## 只借瓦片身份（source + atlas），不借位置：模板那四格在关卡别处，这里要的是"墙里抠开
## 一个洞以后，洞后面还是墙的底色"。模板没铺过背景（那层是空的）时静默跳过 —— 这一跑只
## 用来拍照，不替关卡补内容。
func _paint_backdrop(ts: TileSet, cell: Vector2) -> void:
	var src := _level.get_node_or_null("Terrain/WallFill") as TileMapLayer
	if src == null or src.tile_set == null or src.get_used_cells().size() == 0:
		print("[cave-shot] 模板 WallFill 是空的，这一跑不铺背景")
		return
	var first := src.get_used_cells()[0]
	var source_id := src.get_cell_source_id(first)
	var atlas := src.get_cell_atlas_coords(first)
	var back := TileMapLayer.new()
	back.name = "FixtureBackdrop"
	back.tile_set = ts
	back.z_index = -30
	back.collision_enabled = false
	back.position = AT
	for x in WALL_CELLS.x:
		for y in WALL_CELLS.y:
			back.set_cell(Vector2i(x, y), source_id, atlas)
	add_child(back)
	print("[cave-shot] 背景铺好：source=%d atlas=%s" % [source_id, str(atlas)])


func _place(centre: Vector2) -> void:
	_player.global_position = centre + Vector2(0.0, Player.COLLISION_HALF_HEIGHT)
	await _frame(3)


func _alpha(patch: int) -> float:
	return _cover.current_alpha(patch)


## 把取景框移到墙心。**不能用"目标 − 相机坐标"那一手**：相机位置被关卡限位夹过，
## 而 `offset` 是夹完才加的 —— 人在限位边缘时那一手会把整块取景算歪（实测模板左边界
## 附近偏 188 px）。这里按"当前屏幕中心在世界里的位置"反推，一步就准。
func _aim(target: Vector2) -> void:
	var size := get_viewport().get_visible_rect().size
	var tf := get_viewport().get_canvas_transform()
	var seen: Vector2 = tf.affine_inverse() * (size * 0.5)
	_camera.offset += target - seen


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().physics_frame


func _frame(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


## 抓一次：两个洞口、同一面墙的参照块（逐字节比）与两块放大后的面板（贴进横条）。
func _grab(tag: String) -> Dictionary:
	_aim(_focus)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var full: Image = get_viewport().get_texture().get_image()
	var a := _crop(full, _hole_a)
	var b := _crop(full, _hole_b)
	var ref := _crop(full, _ref)
	var seam_a := _byte_diff(a.get_data(), ref.get_data())
	var seam_b := _byte_diff(b.get_data(), ref.get_data())
	var mag_a := _count(a, MAGENTA)
	var mag_b := _count(b, MAGENTA)
	var same_a := _byte_diff(_last_a, a.get_data()) if _last_a.size() > 0 else -1
	var same_b := _byte_diff(_last_b, b.get_data()) if _last_b.size() > 0 else -1
	_last_a = a.get_data()
	_last_b = b.get_data()
	print("[cave-shot] %s alphaA=%.3f alphaB=%.3f seamA=%d seamB=%d magA=%d magB=%d sameA=%d sameB=%d"
		% [tag, _alpha(0), _alpha(1), seam_a, seam_b, mag_a, mag_b, same_a, same_b])
	return {"alpha_a": _alpha(0), "alpha_b": _alpha(1), "seam_a": seam_a, "seam_b": seam_b,
		"magenta_a": mag_a, "magenta_b": mag_b, "same_a": same_a, "same_b": same_b,
		"img_a": a, "img_b": b}


func _crop(full: Image, world: Rect2) -> Image:
	var tf := _camera.get_canvas_transform()
	var tl: Vector2 = tf * world.position
	var px := Vector2i(int(round(world.size.x * _camera.zoom.x)),
		int(round(world.size.y * _camera.zoom.y)))
	var rect := Rect2i(Vector2i(roundi(tl.x), roundi(tl.y)), px)
	rect = rect.intersection(Rect2i(0, 0, full.get_width(), full.get_height()))
	if rect.size != px:
		push_error("[cave-shot] 取景框出屏了：%s 只裁到 %s（窗口比 %s 小？）"
			% [str(world), str(rect), str(px)])
		_fails += 1
	return full.get_region(rect)


func _count(img: Image, want: Color) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if absf(c.r - want.r) < 0.02 and absf(c.g - want.g) < 0.02 and absf(c.b - want.b) < 0.02:
				n += 1
	return n


## 一组（同一站位）两块：左 A、右 B。
func _stamp(grab: Dictionary, slot: int) -> void:
	_stamp_one(grab["img_a"], slot * 2)
	_stamp_one(grab["img_b"], slot * 2 + 1)


func _stamp_one(crop: Image, index: int) -> void:
	crop.resize(_panel.x, _panel.y, Image.INTERPOLATE_NEAREST)
	# `blend_rect` 要求两边同格式：视口图是 RGBA8，横条是 RGB8。
	crop.convert(Image.FORMAT_RGB8)
	_strip.blend_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
		Vector2i(GAP + index * (_panel.x + GAP), GAP))


func _byte_diff(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return -1
	var n := 0
	for i in a.size():
		if a[i] != b[i]:
			n += 1
	return n


func _check(label: String, passed: bool) -> void:
	print("[cave-shot] %s %s" % ["ok  " if passed else "FAIL", label])
	if not passed:
		_fails += 1
