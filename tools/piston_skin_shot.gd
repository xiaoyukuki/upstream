extends Node
## 一次性实拍器：把 `piston_block` 的皮（D49 选型图 B 档「青光踏板」）在**真关卡帧**上拍出来。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/piston_skin_shot.tscn
##
## 为什么还要再拍一次：选型图（`tools/gen_piston_preview.py`）是 PIL 离线画的，它证明的是
## **"这些数字好不好看"**；这块皮上线走的是脚本 `_draw()`，两边算式不同源。于是定档之后必须用
## 引擎自己画的那一帧再看一次 —— 同一台相机、同一个洞口，四态并排，横向对比才成立。
## 皮画在构件自己身上（不是 PNG），所以这里不需要任何额外贴图：instantiate 真场景 = 真外观。
##
## 每行四列，从左到右（同一格、同一洞口，只有伸出量与冻结状态不同）：
##   0 收回     伸出量 0，画面里只有洞口那圈鞘与缝 —— 玩家必须看得出"这儿有个洞"
##   1 伸出中   半路 + 世界在流：缝上两枚青色短线（运动线索）亮着
##   2 钉住     同样半路，整帧过冻结滤镜（真 shader，不是离线复现）：线索该消失，青色停在原地
##   3 满行程   64 px（两格）到位，线索灭
##
## 两行是两个行程方向：上排竖直从地里长出，下排水平沿地面滑出。分开拍不是凑数 ——
## 皮的全部数字都写成"沿行程轴多远 / 离中轴多远"（`_skin_point` / `_skin_rect`），横竖共用同一份，
## 所以两个方向都得实拍一次才算验过那份数字。只拍一个方向等于把"另一条轴上换子接错了"这类事
## 留在暗处。下排顺带钉住一条摆图事实：横着伸时原点在前缘**中点**，所以要它底边贴着地面，
## 原点得放在地面上方半个方块（默认 64 的方块 → 32 px = 一格，即 `feet - 32`）。
##
## 落点自己找：从出生点往右按格试，取第一个"脚下确实有地形"的位置 —— 拍在虚空里就看不出它
## 是从地里出来的。相机靠 `Camera2D.offset` 平移过去，人不动：搬他会摔进坑里或踩上尖刺，
## 一死就 reload_level 把钉住的冻结态清掉，第 2 列就废了。

const OUT_DIR: String = "res://assets/ui/frames"
const OUT_FILE: String = "piston_skin_b.png"

## 每格取景框的尺寸（设备像素）。视口 1280x720、相机 zoom=2 → 方块 64 世界 px = 128 设备 px，
## 280x200 刚好把它和洞口留在中心，不必把整间教学房一起拍进来。
## 框的**位置**不按"视口中心"摆，而是把"洞口线到满行程前缘的中点"投影到屏幕上对准格子（见 `_frame_origin`）。
const CROP: Vector2i = Vector2i(280, 200)
const SCALE_UP: int = 3
const GAP: int = 8
const COLS: int = 4
const SHEET_BACK: Color = Color8(16, 18, 24)

const SETTLE_FRAMES: int = 30
const FADE_GUARD: int = 240
const MID_STOP: float = 0.45
const POLL_GUARD: int = 600

var _main: Node
var _filter: TimeFreezeFilter
var _camera: Camera2D
var _player: Player
var _piston: PistonBlock
var _strip: Image
var _origin := Vector2i(-1, -1)
var _row := 0
var _col := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_main = preload("res://scenes/levels/main.tscn").instantiate()
	add_child(_main)

	var guard := 0
	while _player == null and guard < 180:
		guard += 1
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		push_error("[piston-shot] 等不到 player，放弃")
		get_tree().quit()
		return
	_filter = _main.get_node("TimeFreezeFilter") as TimeFreezeFilter
	_main.get_node("DebugOverlay").visible = false
	_camera = _player.get_node("PlayerCamera") as Camera2D
	_camera.position_smoothing_enabled = false

	_strip = Image.create(CROP.x * SCALE_UP * COLS + GAP * (COLS - 1),
		(CROP.y * SCALE_UP + GAP) * 2, false, Image.FORMAT_RGBA8)
	_strip.fill(SHEET_BACK)

	var feet: float = _player.collision_rect().end.y
	var x0: float = _find_ground(feet)
	print("[piston-shot] hero=%s feet=%.1f x0=%.1f" % [
		str(_player.global_position), feet, x0])

	# 上排：从地面竖直长出，原点落在地面线上。
	await _run(_make_piston(Vector2(0.0, -64.0), Vector2(x0, feet)))
	_col = 0
	_row = 1
	# 下排：沿地面水平滑出，原点抬半格好让底边贴住地面。往右再挪 5 格，免得两排互相入镜。
	await _run(_make_piston(Vector2(64.0, 0.0), Vector2(x0 + 160.0, feet - 32.0)))

	var path := "%s/%s" % [OUT_DIR, OUT_FILE]
	var err := _strip.save_png(path)
	print("[piston-shot] saved=%d -> %s" % [err, path])
	get_tree().quit()


## 落位 + 走一遍四态。落位必须走在 add_child 之前 —— 构件在 `_ready` 里把锚点取成当时的位置，
## 进树之后再挪就等于把锚点留在原地，progress() 一上来就读成满行程。
func _make_piston(travel: Vector2, at: Vector2) -> PistonBlock:
	var holder: Node2D = _main.get_node("LevelContainer") as Node2D
	var piston := preload("res://scenes/objects/piston_block/piston_block.tscn") \
		.instantiate() as PistonBlock
	piston.travel_offset = travel
	piston.extend_speed = 64.0
	# LevelContainer 没有偏移，所以本地坐标就是世界坐标。
	piston.position = at
	holder.add_child(piston)		# 挂在最后 = 排在 TileMapLayer 之上，与真关卡里的 Objects 同一条
	_piston = piston
	_origin = Vector2i(-1, -1)
	_camera.offset = (at + travel * 0.5) - _camera.global_position
	return piston


func _run(piston: PistonBlock) -> void:
	await _settle()
	await _shot(false)					# 0 收回
	piston.set_out(true)
	await _poll(piston, MID_STOP)
	await _shot(false)					# 1 伸出中（世界在流）
	TimeManager.set_frozen_override(true)
	var waited := 0
	while _filter.strength() < 0.999 and waited < FADE_GUARD:
		waited += 1
		await get_tree().process_frame
	await _settle()
	await _shot(true)					# 2 钉住（真 shader）
	# 不能用 set_frozen_override(false)：那一下只清标志，状态仍是 FROZEN，而放回流动靠的是
	# 玩家移动意图的边沿 —— 开场能力未解锁，那条通道整条静音（level_start ability=false）。
	# reset_state() 是死亡重载用的那条，一并把状态与滤镜的淡出都摆回来。
	TimeManager.reset_state()
	await _poll(piston, 0.999)
	await _settle()
	await _shot(false)					# 3 满行程


## 等伸出量走到 `until`。走不到也要收场，不然一跑就挂死在这里。
func _poll(piston: PistonBlock, until: float) -> void:
	var guard := 0
	while guard < POLL_GUARD and piston.progress() < until:
		guard += 1
		await get_tree().physics_frame
	if piston.progress() < until:
		push_warning("[piston-shot] 没等到伸出量 %s（停在 %s）" % [str(until), str(piston.progress())])


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().physics_frame


## 出生点往右按格找第一个脚下有地形（layer 1）的落点。探的是脚底以下 2~10 px 那一档，
## 只碰得着地形：构件是 layer 4、玩家是 layer 2，都不在 mask 里。
func _find_ground(feet: float) -> float:
	var space: PhysicsDirectSpaceState2D = _player.get_world_2d().direct_space_state
	var rect := RectangleShape2D.new()
	rect.size = Vector2(8.0, 8.0)
	var probe := PhysicsShapeQueryParameters2D.new()
	probe.shape = rect
	probe.collision_mask = 1
	for step in range(7, 26):
		var x: float = _player.global_position.x + step * 32.0
		probe.transform = Transform2D(0.0, Vector2(x, feet + 6.0))
		if not space.intersect_shape(probe, 1).is_empty():
			return x
	return _player.global_position.x + 224.0


## `frozen` 只决定滤镜层开不开 —— 冻不冻是上面用 override 真钉住的，这里不假扮。
## 开关之后必须等一帧再存：同一帧内改 `visible` 渲染器还不知道。
func _shot(frozen: bool) -> void:
	_filter.visible = frozen
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	var origin := _frame_origin(frame.get_size())
	var cell := frame.get_region(Rect2i(origin, CROP))
	cell.convert(_strip.get_format())	# blit_rect 要求两侧格式一致，视口帧未必是 RGB8
	cell.resize(cell.get_width() * SCALE_UP, cell.get_height() * SCALE_UP, Image.INTERPOLATE_NEAREST)
	_strip.blit_rect(cell, Rect2i(Vector2i.ZERO, cell.get_size()),
		Vector2i(_col * (CROP.x * SCALE_UP + GAP), _row * (CROP.y * SCALE_UP + GAP)))
	print("[piston-shot] r%d c%d frozen=%s progress=%.3f ticks=%s" % [
		_row, _col, frozen, _piston.progress(), _piston.get("_ticks")])
	_diag(frame.get_size())
	_col += 1


## 取景框左上角（设备像素，**每行只算一次**）：把"洞口线与满行程前缘的中点"摆到格子正中。
## 不靠"视口中心 = 相机位置"那条假设 —— `Camera2D.anchor_mode` 默认是 top-left，节点位置其实是
## 屏幕左上角，量出来差半张屏幕。夹在帧内：贴边时宁可取景框偏一点，也别让 `get_region` 裁到帧外。
## 一行四列共用同一个框是刻意的：框每列重算的话，"伸出多少"这件事就被相机一起搬走了，
## 横向对比当场作废 —— 这张图要卖的就是四列同框。
func _frame_origin(frame_size: Vector2i) -> Vector2i:
	if _origin.x >= 0:
		return _origin
	var focus: Vector2 = _to_frame_px(
		(_piston.get("_anchor") as Vector2) + _piston.get("_unit") * (_piston.get("_span") * 0.5),
		frame_size)
	_origin = Vector2i(
		clampi(floori(focus.x - CROP.x * 0.5), 0, maxi(frame_size.x - CROP.x, 0)),
		clampi(floori(focus.y - CROP.y * 0.5), 0, maxi(frame_size.y - CROP.y, 0)))
	return _origin


func _to_frame_px(world: Vector2, frame_size: Vector2i) -> Vector2:
	var vp := get_viewport()
	var px: Vector2 = vp.get_canvas_transform() * world
	# 窗口拉伸下纹理尺寸 != 视口尺寸，差一个整数倍，不补这一步量出来的全是错的。
	var vs: Vector2 = vp.get_visible_rect().size
	return px * Vector2(float(frame_size.x) / vs.x, float(frame_size.y) / vs.y)


## 每列打一行"前缘与洞口线落在格内哪个设备像素"。这一条留着是因为量皮必须有个基准：
## 第一版按"视口中心 = 相机位置"反推取景框，量出来一份完全成立的假错（皮在前缘外面），
## 而画出来的皮其实是对的 —— 错的是尺。有引擎报的这两个数，任何人重跑一遍就能对色带位置。
func _diag(frame_size: Vector2i) -> void:
	var face := _to_frame_px(_piston.global_position, frame_size) - Vector2(_origin)
	# 洞口线在世界里纹丝不动，就是收回态的原点 —— 皮挂在会跑的节点上却钉在它身上。
	var mouth := _to_frame_px(_piston.get("_anchor") as Vector2, frame_size) - Vector2(_origin)
	print("[piston-shot]   unit=%s face_cell=(%.0f,%.0f) mouth_cell=(%.0f,%.0f) 1 世界 px=%.0f 设备 px" % [
		str(_piston.get("_unit")), face.x * SCALE_UP, face.y * SCALE_UP,
		mouth.x * SCALE_UP, mouth.y * SCALE_UP, _camera.zoom.x * SCALE_UP])
