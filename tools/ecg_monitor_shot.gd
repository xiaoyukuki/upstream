extends Node
## 一次性实拍器：把 `ecg_monitor`（D75）那条波形在**真关卡帧**上拍出来。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/ecg_monitor_shot.tscn
## 退出码 = 有没有 FAIL，所以它兼任一条开窗守门。
##
## 为什么选型图不够、还要再拍一次（`tools/piston_skin_shot.gd` 同一条口径）：
## `gen_ecg_monitor_preview.py` 是 PIL 离线画的，它证明的是"这些相位好不好看"；这台构件上线走的是
## GDScript 的 `_draw()`，两边算式不同源（皮同源那条由 `verify_kit` 逐格比字节钉着，但
## **"画到屏幕上到底有没有东西"没有任何无头守门钉得着**）。所以这里拍引擎自己画的那几帧。
##
## 三件事各自要一个数，缺一个就是假绿：
##   ① 屏上真有像素 —— 那块矩形里青色像素 > 0（`_draw()` 没跑、位置在镜头外、忘了 `fill` 透明
##      这三种死法都会让它变 0，而画面一声不响）；
##   ② 世界在流 → 同一块矩形两次抓取**字节不同**、相位也换了格；
##   ③ 世界冻着 → 同一块矩形两次抓取**字节完全相同**（中间隔 30 物理拍）—— 这一条才是他要的
##      "更能体现时间的冻结"：停的不是画面帧率，是那条波形自己。
## 解冻后再抓一次复测：它要重新开始推（停过之后不漂那条的行为半边）。
##
## 摆位用 `level_template.tscn`（D75 起模板挂着这台构件，与那只世界钟同一族、都在场景根上）；
## 相机靠 `Camera2D.offset` 平移到构件上，人不动 —— 搬他会踩到样品那一行的机关。

const OUT_DIR: String = "res://assets/ui/frames"
const OUT_FILE: String = "ecg_monitor_shot.png"
const LEVEL: String = "res://scenes/levels/level_template.tscn"
const NODE_NAME: String = "EcgMonitor"
const CYAN := Color8(110, 230, 240)      # 与 `EcgMonitor.COL_TRACE` 同一档（这里比的是屏上像素）

const SETTLE_FRAMES: int = 30
const SCALE_UP: int = 2
const GAP: int = 10

var _camera: Camera2D
var _player: Player
var _monitor: Node2D
var _box := Vector2i.ZERO
var _cell := Vector2i.ZERO
var _strip: Image
var _col := 0
var _last_raw := PackedByteArray()
var _last_phase := -1
var _fails := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	add_child(load(LEVEL).instantiate())

	var guard := 0
	while _monitor == null and guard < 180:
		guard += 1
		await get_tree().process_frame
		var player := get_tree().get_first_node_in_group(&"player") as Player
		if player == null:
			continue
		_camera = player.get_node_or_null("PlayerCamera") as Camera2D
		if _camera == null:
			continue
		_camera.position_smoothing_enabled = false
		_player = player
		_monitor = _find(get_tree().root, NODE_NAME)
	if _monitor == null:
		push_error("[ecg-shot] 等不到 %s（模板里没挂上？）" % NODE_NAME)
		get_tree().quit(1)
		return
	# 把他钉在出生那一拍：不落地就没有"相机一路往下跟"，也不会失足触发 `reload_level`
	# 把这一跑的节点连带拆掉（第一次跑就是这么变成两遍 flow-1 的）。
	_player.set_physics_process(false)
	var visual := _player.get_node_or_null("Visual/Sprite") as AnimatedSprite2D
	if visual != null:
		visual.set_process(false)
		visual.pause()

	var cs: Dictionary = _monitor.get_script().get_script_constant_map()
	_box = Vector2i(int(cs["BOX_X"]), int(cs["BOX_Y"]))
	_aim()
	# 相机 zoom=2，所以那块 48×32 的盒子在屏幕上本来就占 96×64 设备像素；横条按屏幕尺寸排，
	# `SCALE_UP` 只用来再放大一档看像素块。
	_cell = Vector2i(int(float(_box.x) * _camera.zoom.x), int(float(_box.y) * _camera.zoom.y))
	_strip = Image.create(_cell.x * SCALE_UP * 4 + GAP * 5, _cell.y * SCALE_UP + 30,
			false, Image.FORMAT_RGB8)
	_strip.fill(Color8(10, 11, 16))

	# —— ① 屏上真有像素 + ② 流着逐帧不同 ——
	await _settle()
	var a := await _grab("flow-1")
	await _settle()
	var b := await _grab("flow-2")
	_check("① 那块矩形里青色像素 > 0（%d）" % int(a["cyan"]), int(a["cyan"]) > 0)
	_check("② 世界在流：同一块矩形两次抓取差 %d 字节" % int(b["diff"]), int(b["diff"]) > 0)
	_check("② 相位也换了格（%d → %d）" % [int(a["phase"]), int(b["phase"])],
			int(a["phase"]) != int(b["phase"]))

	# —— ③ 冻着字节相同 ——
	TimeManager.notify_movement_intent(true)
	await _settle()
	var c := await _grab("frozen-1")
	await _settle()
	var d := await _grab("frozen-2")
	_check("前提：此刻世界冻着", TimeManager.is_time_frozen())
	_check("③ 世界冻着：同一块矩形两次抓取差 %d 字节（应为 0）" % int(d["diff"]), int(d["diff"]) == 0)
	_check("③ 相位也钉在原地（%d → %d）" % [int(c["phase"]), int(d["phase"])],
			int(c["phase"]) == int(d["phase"]))

	# —— 解冻复测 ——
	TimeManager.notify_movement_intent(false)
	await _settle()
	var e := await _grab("flow-3")
	_check("解冻后又开始推（相位 %d → %d）" % [int(d["phase"]), int(e["phase"])],
			int(e["phase"]) != int(d["phase"]))

	var err := _strip.save_png("%s/%s" % [OUT_DIR, OUT_FILE])
	print("[ecg-shot] saved=%d fails=%d -> %s/%s" % [err, _fails, OUT_DIR, OUT_FILE])
	get_tree().quit(_fails > 0)


## 把相机 offset 重新对准构件中心：每帧都算一次，屏幕上的取景框就不会随玩家起伏漂走。
func _aim() -> void:
	_camera.offset = _monitor.global_position - _camera.global_position


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().physics_frame


## 抓一块矩形：把构件外接框投影到屏幕上，裁下来放大贴进横条，当场算青色像素数与"与上一次抓取的
## 字节差比的是 `get_data()` 那串原始像素（定长 w*h*4）——**不能**拿 `save_png_to_buffer()` 比：
func _grab(tag: String) -> Dictionary:
	_aim()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var full: Image = get_viewport().get_texture().get_image()
	var top_left: Vector2 = _camera.get_canvas_transform() * (
			_monitor.global_position - Vector2(float(_box.x) * 0.5, float(_box.y) * 0.5))
	# 外接框在屏幕上占的是 `盒子 × zoom`，已在 `_ready()` 里算成 `_cell`。
	var rect := Rect2i(int(top_left.x), int(top_left.y), _cell.x, _cell.y)
	rect = rect.intersection(Rect2i(0, 0, full.get_width(), full.get_height()))
	var crop := full.get_region(rect)
	var cyan := 0
	for y in crop.get_height():
		for x in crop.get_width():
			var c := crop.get_pixel(x, y)
			if absf(c.r - CYAN.r) < 0.02 and absf(c.g - CYAN.g) < 0.02 and absf(c.b - CYAN.b) < 0.02:
				cyan += 1
	var raw: PackedByteArray = crop.get_data()
	var diff := _byte_diff(_last_raw, raw) if _last_raw.size() > 0 else -1
	_last_raw = raw
	crop.resize(crop.get_width() * SCALE_UP, crop.get_height() * SCALE_UP,
			Image.INTERPOLATE_NEAREST)
	# `blend_rect` 要求两边同格式：视口图是 RGBA8，横条是 RGB8。
	crop.convert(Image.FORMAT_RGB8)
	_strip.blend_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
			Vector2i(GAP + _col * (crop.get_width() + GAP), 22))
	_col += 1
	var ph: int = int(_monitor.call(&"phase"))
	print("[ecg-shot] %s rect=%s cyan=%d bytes_vs_prev=%d phase=%d" % [tag, str(rect), cyan, diff, ph])
	return {"cyan": cyan, "diff": diff, "phase": ph}


func _find(node: Node, node_name: String) -> Node2D:
	for child in node.get_children():
		if child.name == node_name and child is Node2D:
			return child as Node2D
		var hit := _find(child, node_name)
		if hit != null:
			return hit
	return null


func _byte_diff(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return -1
	var n := 0
	for i in a.size():
		if a[i] != b[i]:
			n += 1
	return n


func _check(label: String, passed: bool) -> void:
	print("[ecg-shot] %s %s" % ["ok  " if passed else "FAIL", label])
	if not passed:
		_fails += 1
