extends SceneTree
## 生成 assets/tiles/ 下的 TileSet（一套 manifest 一份 .tres）。
##
## 不手写 .tres 文本：TileSet 的序列化格式跟着引擎版本走，让引擎自己写最稳。
## 图集布局一律读清单（`tiles.json` / `tiles_d.json`），那份文件由 tools/gen_tiles.py 产出，
## 是地形掩码与装饰矩形的唯一来源 —— 预览图和引擎吃的是同一份清单。
##
## 两份产物（D67）：
##   `tiles.json` → `lab_tileset.tres`   落盘的夜光风格 g，现有关与模板都指它，文件名不许动；
##   `tiles_d.json` → `lab_tileset_d.tres`  软糖贴纸 d，给换美术风格的新关用。
##   两套的**瓦片索引逐格同源**（同一批 painters，只换调色板），所以旧关的摆图层可以整层复制。
##
## 结构（D24）：
##   source 0 = 地形图集，16 个单格瓦片，每格一块整格碰撞多边形，
##              并挂到 terrain set 0（TERRAIN_MODE_MATCH_SIDES）做四侧自动拼贴；
##   source 1 = 装饰图集，整份装饰清单（含 wall_fill / shade 与两块无字告示牌），无碰撞。
## 物理层 0：collision_layer=1（terrain）、mask=0 —— 和 platform.tscn 同一层。
##
## 两张图集的文件名从清单里读（`terrain.file` / `decor.file`），不在这里写死 ——
## 第二套风格的名字带后缀，硬编码的话它会把 g 的图集挂进 d 的 tileset，
## 而那不报错、不崩，只是新关刷出来是旧配色。
##
## 用法（PNG 必须先被导入，否则 load() 拿不到纹理）：
##   Godot_console.exe --headless --path . --import
##   Godot_console.exe --headless --path . --script res://tools/build_tileset.gd

const PAIRS := [
	{
		"manifest": "res://assets/tiles/tiles.json",
		"out": "res://assets/tiles/lab_tileset.tres",
	},
	{
		"manifest": "res://assets/tiles/tiles_d.json",
		"out": "res://assets/tiles/lab_tileset_d.tres",
	},
]

const UIDS := preload("res://tools/keep_uid.gd")

var _failures := 0


func _initialize() -> void:
	for pair in PAIRS:
		_build(str(pair["manifest"]), str(pair["out"]))
	quit(1 if _failures > 0 else 0)


func _build(manifest_path: String, out_path: String) -> void:
	var fh := FileAccess.open(manifest_path, FileAccess.READ)
	if fh == null:
		print("FAIL 读不到 ", manifest_path, " —— 先跑 py tools/gen_tiles.py")
		_failures += 1
		return
	var manifest: Variant = JSON.parse_string(fh.get_as_text())
	if typeof(manifest) != TYPE_DICTIONARY:
		print("FAIL ", manifest_path, " 解析失败")
		_failures += 1
		return

	var tile: int = int(manifest["tile"])
	var half := float(tile) / 2.0
	var full_cell := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	var atlas_dir := manifest_path.get_base_dir()
	var terrain_file: String = str(manifest["terrain"]["file"])
	var decor_file: String = str(manifest["decor"]["file"])
	var failures := 0

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile, tile)
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_mask(0, 0)

	# ---- 地形：16 格，掩码 -> 四侧 peering bit
	var terrain: TileSetAtlasSource = TileSetAtlasSource.new()
	terrain.texture = load(atlas_dir + "/" + terrain_file)
	terrain.texture_region_size = Vector2i(tile, tile)
	if terrain.texture == null:
		print("FAIL 读不到 ", terrain_file, " —— 先跑 --import")
		_failures += 1
		return
	ts.add_source(terrain, 0)
	ts.add_terrain_set(0)
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_SIDES)
	ts.add_terrain(0, 0)
	ts.set_terrain_name(0, 0, "solid")

	var bits: Dictionary = manifest["terrain"]["mask_bits"]
	var side_of := {
		"up": TileSet.CELL_NEIGHBOR_TOP_SIDE,
		"right": TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
		"down": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
		"left": TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	}
	for entry in manifest["terrain"]["tiles"]:
		var mask: int = int(entry["mask"])
		var coords := Vector2i(int(entry["x"]) / tile, int(entry["y"]) / tile)
		terrain.create_tile(coords)
		var td: TileData = terrain.get_tile_data(coords, 0)
		td.add_collision_polygon(0)
		td.set_collision_polygon_points(0, 0, full_cell)
		td.terrain_set = 0
		td.terrain = 0
		for key in side_of:
			var solid := (mask & int(bits[key])) != 0
			td.set_terrain_peering_bit(side_of[key], 0 if solid else -1)
	print("%s: %d 格 / terrain set 0 = MATCH_SIDES / 每格 1 块整格碰撞"
		% [terrain_file, terrain.get_tiles_count()])

	# ---- 装饰：多格大图，无碰撞、无 terrain
	var decor: TileSetAtlasSource = TileSetAtlasSource.new()
	decor.texture = load(atlas_dir + "/" + decor_file)
	decor.texture_region_size = Vector2i(tile, tile)
	if decor.texture == null:
		print("FAIL 读不到 ", decor_file, " —— 先跑 --import")
		_failures += 1
		return
	ts.add_source(decor, 1)
	var items: Dictionary = manifest["decor"]["items"]
	var names: Array = items.keys()
	names.sort()
	for name in names:
		var r: Array = items[name]
		var coords := Vector2i(int(r[0]) / tile, int(r[1]) / tile)
		var size := Vector2i(int(r[2]) / tile, int(r[3]) / tile)
		decor.create_tile(coords, size)
		if decor.get_tile_data(coords, 0) == null:
			print("FAIL 装饰瓦片建失败 ", name)
			failures += 1
	print("%s: %d 块 / 无碰撞" % [decor_file, decor.get_tiles_count()])

	# uid 必须跨次生成不变：场景里的 ext_resource 记着 uid="..."，把它丢掉引擎就当场
	# 另发一个，所有引用退化成按路径找，level1.tscn 与 level_template.tscn 各指一份。
	# 走文本而不是 set_resource_uid()：4.6 的 SpriteFrames 上根本没那个方法（见 keep_uid.gd），
	# 两份生成脚本从此用同一双手。
	# 全新的那一套（头一次生成，文件里还没有 uid 行）自己发一个：`ResourceUID.generate()`
	# 在 4.6 不存在（实测 has_method 为假），能用的只有 `create_id()` + `id_to_text()`。
	# 不发就等于把"这个资源没有身份"留给编辑器去补，而它补之前任何场景按 uid 引用都落空。
	var old_uid: String = UIDS.read(out_path)
	if old_uid == "":
		old_uid = ResourceUID.id_to_text(ResourceUID.create_id())
	# 已有旧账就照旧账补（g 那一套走这条，字节一字不变）；全新的一套没有旧账，
	# 但它引用的那两张 PNG 已经先一步被导入、uid 就写在各自的 `.import` 里。
	# 不补的话这两行只有 `path=`，编辑器下次存这份资源会连 id= 一起重排 ——
	# "只换了配色"的改动在 diff 里看成整份重写（D56/D57 为这个补过两次账）。
	var old_ext: Dictionary = UIDS.read_ext_uids(out_path)
	if old_ext.is_empty():
		old_ext = _uids_from_import(atlas_dir, [terrain_file, decor_file])
	var err := ResourceSaver.save(ts, out_path)
	var uid_kept: bool = UIDS.restore(out_path, old_uid) and UIDS.restore_ext_uids(out_path, old_ext)
	print("saved ", out_path, " uid=", old_uid, " uid_kept=", uid_kept, " err=", err,
		" failures=", failures)
	if failures > 0 or err != OK or not uid_kept:
		_failures += 1


## 从 `<图集名>.import` 里读那张纹理的资源 uid，凑成 `restore_ext_uids` 要的那份账。
static func _uids_from_import(atlas_dir: String, files: Array) -> Dictionary:
	var out := {}
	var pattern := RegEx.create_from_string('uid="([^"]*)"')
	for file in files:
		var res_path := atlas_dir + "/" + str(file)
		var text := FileAccess.get_file_as_string(res_path + ".import")
		var found: RegExMatch = pattern.search(text)
		if found != null:
			out[res_path] = found.get_string(1)
	return out
