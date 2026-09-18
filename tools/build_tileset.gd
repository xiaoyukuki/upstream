extends SceneTree
## 生成 assets/tiles/lab_tileset.tres（TileSet）。
##
## 不手写 .tres 文本：TileSet 的序列化格式跟着引擎版本走，让引擎自己写最稳。
## 图集布局一律读 assets/tiles/tiles.json，那份文件由 tools/gen_tiles.py 产出，
## 是地形掩码与装饰矩形的唯一来源 —— 预览图和引擎吃的是同一份清单。
##
## 结构（D24）：
##   source 0 = tilesheet_terrain.png，16 个单格瓦片，每格一块整格碰撞多边形，
##              并挂到 terrain set 0（TERRAIN_MODE_MATCH_SIDES）做四侧自动拼贴；
##   source 1 = tilesheet_decor.png，12 块装饰（含 wall_fill / shade），无碰撞。
## 物理层 0：collision_layer=1（terrain）、mask=0 —— 和 platform.tscn 同一层。
##
## 用法（PNG 必须先被导入，否则 load() 拿不到纹理）：
##   Godot_console.exe --headless --path . --import
##   Godot_console.exe --headless --path . --script res://tools/build_tileset.gd

const MANIFEST := "res://assets/tiles/tiles.json"
const OUT := "res://assets/tiles/lab_tileset.tres"


func _initialize() -> void:
	var fh := FileAccess.open(MANIFEST, FileAccess.READ)
	if fh == null:
		print("FAIL 读不到 tiles.json —— 先跑 py tools/gen_tiles.py")
		quit(1)
		return
	var manifest: Variant = JSON.parse_string(fh.get_as_text())
	if typeof(manifest) != TYPE_DICTIONARY:
		print("FAIL tiles.json 解析失败")
		quit(1)
		return

	var tile: int = int(manifest["tile"])
	var half := float(tile) / 2.0
	var full_cell := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	var failures := 0

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile, tile)
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_mask(0, 0)

	# ---- 地形：16 格，掩码 -> 四侧 peering bit
	var terrain: TileSetAtlasSource = TileSetAtlasSource.new()
	terrain.texture = load("res://assets/tiles/tilesheet_terrain.png")
	terrain.texture_region_size = Vector2i(tile, tile)
	if terrain.texture == null:
		print("FAIL 读不到 tilesheet_terrain.png —— 先跑 --import")
		quit(1)
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
	print("terrain: %d 格 / terrain set 0 = MATCH_SIDES / 每格 1 块整格碰撞" % terrain.get_tiles_count())

	# ---- 装饰：多格大图，无碰撞、无 terrain
	var decor: TileSetAtlasSource = TileSetAtlasSource.new()
	decor.texture = load("res://assets/tiles/tilesheet_decor.png")
	decor.texture_region_size = Vector2i(tile, tile)
	if decor.texture == null:
		print("FAIL 读不到 tilesheet_decor.png —— 先跑 --import")
		quit(1)
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
	print("decor: %d 块 / 无碰撞" % decor.get_tiles_count())

	var err := ResourceSaver.save(ts, OUT)
	print("saved ", OUT, " err=", err, " failures=", failures)
	quit(1 if (failures > 0 or err != OK) else 0)
