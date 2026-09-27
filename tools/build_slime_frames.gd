extends SceneTree
## 生成 assets/player/slime_frames.tres（SpriteFrames）。
##
## 不手写 .tres 文本：SpriteFrames 的序列化格式跟着引擎版本走，让引擎自己写最稳。
## 剪辑的 fps / 是否循环 / 帧数一律读 assets/player/slime/clips.json，那份文件由
## tools/gen_player_frames.py 产出，是唯一的帧表来源。清单里可选的 `durations`
## （帧号 -> 该帧时长倍数）也来自那张表 —— wake 的首帧 2.0 是用户在编辑器里手调的，
## 记回帧表是为了让"重建 .tres"不再等于"把手调冲掉"。
##
## 用法（PNG 必须先被导入，否则 load() 拿不到纹理）：
##   Godot_console.exe --headless --path . --import
##   Godot_console.exe --headless --path . --script res://tools/build_slime_frames.gd

const DIR := "res://assets/player/slime"
const OUT := "res://assets/player/slime_frames.tres"
const UIDS := preload("res://tools/keep_uid.gd")


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
			# 逐帧时长存在剪辑的帧表里（不是存在纹理上），所以直接 set_frame 写回即可。
			var holds: Dictionary = spec.get("durations", {})
			if holds.has(str(i)):
				frames.set_frame(clip, frames.get_frame_count(clip) - 1, tex,
					float(holds[str(i)]))
		print("clip %-5s %d 帧 / %s fps / loop=%s" % [
			clip, frames.get_frame_count(clip), spec.fps, spec.loop])

	# uid 必须跨次生成不变：player.tscn 的 ext_resource 记着 uid="..."，从新建资源 save()
	# 出来的 .tres 会丢掉这个头，引擎下次编辑时另发一个，引用就退化成按路径找。
	# 账要在 save() 之前拍 —— 存盘之后原文件里那些数就没了。
	var old_uid: String = UIDS.read(OUT)
	var old_ext: Dictionary = UIDS.read_ext_uids(OUT)
	var err := ResourceSaver.save(frames, OUT)
	var uid_kept: bool = UIDS.restore(OUT, old_uid) and UIDS.restore_ext_uids(OUT, old_ext)
	print("saved ", OUT, " uid=", old_uid, " uid_kept=", uid_kept, " err=", err,
		" failures=", failures)
	quit(1 if (failures > 0 or err != OK or not uid_kept) else 0)
