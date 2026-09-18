extends SceneTree
## 生成 assets/player/slime_frames.tres（SpriteFrames）。
##
## 不手写 .tres 文本：SpriteFrames 的序列化格式跟着引擎版本走，让引擎自己写最稳。
## 剪辑的 fps / 是否循环 / 帧数一律读 assets/player/slime/clips.json，那份文件由
## tools/gen_player_frames.py 产出，是唯一的帧表来源。
##
## 用法（PNG 必须先被导入，否则 load() 拿不到纹理）：
##   Godot_console.exe --headless --path . --import
##   Godot_console.exe --headless --path . --script res://tools/build_slime_frames.gd

const DIR := "res://assets/player/slime"
const OUT := "res://assets/player/slime_frames.tres"


func _initialize() -> void:
	var fh := FileAccess.open(DIR + "/clips.json", FileAccess.READ)
	if fh == null:
		print("FAIL 读不到 clips.json —— 先跑 py tools/gen_player_frames.py")
		quit(1)
		return
	var manifest: Variant = JSON.parse_string(fh.get_as_text())
	if typeof(manifest) != TYPE_DICTIONARY:
		print("FAIL clips.json 解析失败")
		quit(1)
		return

	var frames := SpriteFrames.new()
	var failures := 0
	var names: Array = manifest.keys()
	names.sort()
	for clip in names:
		var spec: Dictionary = manifest[clip]
		frames.add_animation(clip)
		frames.set_animation_loop(clip, spec.loop)
		frames.set_animation_speed(clip, spec.fps)
		for i in range(int(spec.frames)):
			var path: String = "%s/%s_%d.png" % [DIR, clip, i]
			var tex: Texture2D = load(path)
			if tex == null:
				print("FAIL 缺帧 ", path)
				failures += 1
				continue
			frames.add_frame(clip, tex)
		print("clip %-5s %d 帧 / %s fps / loop=%s" % [
			clip, frames.get_frame_count(clip), spec.fps, spec.loop])

	var err := ResourceSaver.save(frames, OUT)
	print("saved ", OUT, " err=", err, " failures=", failures)
	quit(1 if (failures > 0 or err != OK) else 0)
