extends RefCounted
## 无头重建 .tres 时保住资源 uid 的那两手（build_tileset.gd 与 build_slime_frames.gd 共用）。
##
## 为什么要保：`ResourceSaver.save()` 从一个新建的内存资源写盘时，
## ① 头一行不会带上原文件里的 `uid="..."`。编辑器下次扫到它便另发一个 uid，场景里凡是按
##    uid 写的 ext_resource 当场退化成按路径找 —— 同一个资源在两份场景里各指一处
##    （2026-09-24 的 lab_tileset.tres 正是这么烂掉的，被它带歪的还有用户自己那份 level1.tscn）；
## ② 子资源（那些 PNG）的 ext_resource 行只剩 `path=`，编辑器存盘时会连 id 一起重排，
##    一份"只加了一段剪辑"的改动在 diff 里看成整份重写。
##
## 为什么走文本而不是 set_resource_uid()：4.6 实测 SpriteFrames 只有 get_resource_uid()，
## set_resource_uid() 对它根本不存在（探针：has_method 返回 false，调用即 SCRIPT ERROR）。
## 与其逐类赌引擎给不给，不如在落盘之后按原样补回头一行与 ext_resource 那几行 ——
## 这些行本来就是引擎自己写的，格式稳。

## 读头一行里的资源 uid；文件不在或没有 uid 都回 ""。
static func read(path: String) -> String:
	var header := _first_line(path)
	if header == "":
		return ""
	var found: RegExMatch = RegEx.create_from_string('uid="([^"]*)"').search(header)
	return "" if found == null else found.get_string(1)


## 把 uid 写回头一行：已有别的 uid 就替换，一个都没有就在收尾的 ] 前插一段。
## 回来再读一遍确认，返回的是"文件里现在真是这个 uid"，不是"我以为我写进去了"。
static func restore(path: String, uid: String) -> bool:
	if uid == "":
		return true
	var text := FileAccess.get_file_as_string(path)
	var nl := text.find("\n")
	if nl < 0:
		return false
	var header := text.substr(0, nl)
	if not header.contains('uid="%s"' % uid):
		var found: RegExMatch = RegEx.create_from_string('uid="[^"]*"').search(header)
		var close := header.rfind("]")
		if found != null:
			header = header.substr(0, found.start) + ('uid="%s"' % uid) + header.substr(found.end)
		elif close > 0:
			header = header.substr(0, close) + (' uid="%s"' % uid) + header.substr(close)
		else:
			return false
	return _write(path, header + text.substr(nl)) and read(path) == uid


## 存盘前拍一份「子资源路径 -> uid」的账（save() 之后原文件已经没这些数了）。
static func read_ext_uids(path: String) -> Dictionary:
	var out := {}
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return out
	while not fh.eof_reached():
		var line := fh.get_line()
		if not line.begins_with("[ext_resource"):
			continue
		var sub := _quoted(line, "path=")
		var uid := _quoted(line, "uid=")
		if sub != "" and uid != "":
			out[sub] = uid
	fh.close()
	return out


## 按那份账把 uid 补回各 ext_resource 行（插在 type= 后面，与编辑器写的顺序一致）。
## 只补"账里有、这一行没有"的；一个 uid 都对不上不报错 —— 全新资源本来就没有旧账。
static func restore_ext_uids(path: String, by_path: Dictionary) -> bool:
	if by_path.is_empty():
		return true
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if not line.begins_with("[ext_resource") or line.contains("uid="):
			continue
		var sub := _quoted(line, "path=")
		var type := _quoted(line, "type=")
		if not by_path.has(sub) or type == "":
			continue
		lines[i] = line.replace('type="%s"' % type,
			'type="%s" uid="%s"' % [type, by_path[sub]])
	return _write(path, "\n".join(lines))


static func _first_line(path: String) -> String:
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return ""
	var line := fh.get_line()
	fh.close()
	return line


static func _write(path: String, text: String) -> bool:
	var fh := FileAccess.open(path, FileAccess.WRITE)
	if fh == null:
		return false
	fh.store_string(text)
	fh.close()
	return true


## 取出 `key="值"` 里的值。
static func _quoted(line: String, key: String) -> String:
	var at := line.find(key + '"')
	if at < 0:
		return ""
	var from := at + key.length() + 1
	var end := line.find('"', from)
	return "" if end < 0 else line.substr(from, end - from)
