extends Node
## 一次性抓帧器：给「世界冻结的滤镜」出选型图当真帧底片。
##
## 跑法（必须有窗口，headless 下渲染是空的）：
##   Godot_v4.6.1-stable_mono_win64_console.exe --path D:/Godot/Ups/upstream \
##     res://tools/frame_grab.tscn
##
## 这一跑还兼任 shader 的编译检查：Compatibility 渲染器在无头模式下不真编译着色器，
## 语法错了也一声不响。开窗跑起来、stderr 里没有 shader error，才算过。
##
## 为什么挂 `main.tscn` 而不是光挂一张关卡：滤镜与调试面板都住在 Main 下，
## 只有走这一条链，抓到的才是玩家真会看到的那一帧。
##
## 取景靠 `Camera2D.offset` 平移，玩家本人一直站在出生点：搬他会摔进坑里或踩上尖刺，
## 一死就 `reload_level` → `TimeManager.reset_state()` 把钉住的冻结态清掉，抓到的帧就废了。
##
## 每个位置存两张：
##   _raw.png    = 整个滤镜 CanvasLayer 关掉 = shader 的输入原图
##   _filter.png = 当前实现的滤镜淡入到底 = 实拍那一行
## 灰滤镜的旧底片（_gray.png）留在盘上当「换之前长这样」的对照，本脚本不再覆写它。
## 两张都关掉调试面板：它在 layer 300，在滤镜（layer 100）之上，实机不会被滤镜吃到，
## 留在底片里反而会让离线复现把 HUD 一起加亮。
##
## 冻结态是用 `TimeManager.set_frozen_override(true)` 真钉住的：于是淡入走的是
## `_on_time_state_changed` 那条真路径，抓到的强度是引擎自己插出来的。
## 每次开关滤镜层之后必须等一帧再存 —— 同一帧内改 `visible` 渲染器还不知道。

const OUT_DIR: String = "res://assets/ui/frames"
const SETTLE_FRAMES: int = 30
const FADE_GUARD: int = 240

## 出生点在 x=51，这些是相机相对出生点的平移量（世界像素）。
## 只取选型图真消费的两个地标：按钮与门（spot0）/ 尖刺与钥匙（spot2）。
## 取点名与 tools/gen_freeze_filter_preview.py 里的文件前缀一一对应。
const SPOTS: Array[String] = ["spot0", "spot2"]
const PANS: Array[Vector2] = [Vector2(-90, 0), Vector2(510, 0)]

var _main: Node
var _filter: TimeFreezeFilter
var _overlay: CanvasLayer
var _camera: Camera2D
var _player: Player


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
		push_error("[frame-grab] 等不到 player，放弃")
		get_tree().quit()
		return
	_filter = _main.get_node("TimeFreezeFilter") as TimeFreezeFilter
	_overlay = _main.get_node("DebugOverlay") as CanvasLayer
	_overlay.visible = false
	_camera = _player.get_node("PlayerCamera") as Camera2D
	_camera.position_smoothing_enabled = false
	# 主角的剪辑跑在真实 process delta 上：世界冻着他照旧呼吸（他就是时间的载体）。
	# 抓帧要比的是「同一份内容过没过滤镜」，所以先把他钉住 —— 机关与 D42 死亡那一拍
	# 是同一条：`set_process(false)` 让 PlayerVisual 不再挑剪辑，`pause()` 停在当前帧。
	# 不钉的话两张帧会差一帧动画，差值全砸在他那条黑→墙的高对比轮廓上（实测 250）。
	var visual := _player.get_node("Visual/Sprite") as AnimatedSprite2D
	visual.set_process(false)
	visual.pause()
	TimeManager.set_frozen_override(true)

	for i in SPOTS.size():
		await _settle()
		await _grab(SPOTS[i], PANS[i])
	print("[frame-grab] done -> %s" % OUT_DIR)
	get_tree().quit()


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await get_tree().physics_frame


func _grab(tag: String, pan: Vector2) -> void:
	_camera.offset = pan
	_filter.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var raw_img := get_viewport().get_texture().get_image()
	var raw_err := raw_img.save_png("%s/%s_raw.png" % [OUT_DIR, tag])

	_filter.visible = true
	var waited := 0
	while _filter.strength() < 0.999 and waited < FADE_GUARD:
		waited += 1
		await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out_img := get_viewport().get_texture().get_image()
	var out_err := out_img.save_png("%s/%s_filter.png" % [OUT_DIR, tag])
	print("[frame-grab] %s raw=%d filter=%d fade=%d frozen=%s strength=%.3f maxdelta=%d" % [
		tag, raw_err, out_err, waited, TimeManager.is_time_frozen(),
		_filter.strength(), _max_delta(raw_img, out_img)])


## 每 8 px 抽一点看两帧差多少。上次踩过的坑是 raw 与滤镜帧一模一样（同一帧内改
## visible 没等帧就存图），这个数就是用来当场识破那种「滤镜其实是空转」的。
func _max_delta(a: Image, b: Image) -> int:
	if a == null or b == null or a.get_size() != b.get_size():
		return -1
	var worst := 0
	for y in range(0, a.get_height(), 8):
		for x in range(0, a.get_width(), 8):
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			for ch in 3:
				worst = maxi(worst, absi(int(pa[ch] * 255.0) - int(pb[ch] * 255.0)))
	return worst
