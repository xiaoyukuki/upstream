extends Node
## 无头守门：瓦片图集 / TileSet / 模板三层的结构，加上 D24 第 6 条的「美术-碰撞 4 px 契约」。
##
## 量的是图集像素，不是调色板常量 —— 换一套配色这条守门照样成立：
##   顶开的格子，第 0 行必须不透明且是最暗的一格（描边），第 1 行是最亮的一格（内侧受光）；
##   左/右开的格子转 90 度同理，取样行固定取 8（避开角上踏面盖住竖面的那 4 像素）；
##   底开的格子，最后两行必须比主体暗（这条两种语言下都一样）。
## 锁的是「描边朝外」这个方向，不是具体颜色。所以换配色不用动它；哪天换回
## 「亮边朝外」的金属语言（gen_tiles.py 里 soft=False 那几套），才需要把方向翻回来。
## 结构面：16 张地形 tile 各带且仅带一块整格碰撞多边形；装饰 tile 零碰撞；
## 模板里 WallFill/Decor/Tiles 三层的 z 序、碰撞开关、layer/mask、共用同一个 TileSet。
##
## 跑法：Godot --headless --path <项目根> res://tools/tileset_selftest.tscn

const MANIFEST := "res://assets/tiles/tiles.json"
const TILESET := "res://assets/tiles/lab_tileset.tres"
const TEMPLATE := "res://scenes/levels/level_template.tscn"

var _fails := 0
var _checks := 0


func _ok(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL ", msg)


func _lum(img: Image, x: int, y: int) -> float:
	var c := img.get_pixel(x, y)
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _ready() -> void:
	var fh := FileAccess.open(MANIFEST, FileAccess.READ)
	_ok(fh != null, "tiles.json 存在 —— 先跑 py tools/gen_tiles.py")
	if fh == null:
		_finish()
		return
	var m: Dictionary = JSON.parse_string(fh.get_as_text())
	var tile: int = int(m["tile"])

	var ts := load(TILESET) as TileSet
	_ok(ts != null, "lab_tileset.tres 能加载 —— 先跑 build_tileset.gd")
	if ts == null:
		_finish()
		return
	_ok(ts.tile_size == Vector2i(tile, tile), "TileSet.tile_size = %d px" % tile)
	_ok(ts.get_physics_layers_count() == 1, "物理层恰好 1 个")
	_ok(ts.get_physics_layer_collision_layer(0) == 1, "物理层 collision_layer = 1")
	_ok(ts.get_physics_layer_collision_mask(0) == 0, "物理层 collision_mask = 0")
	_ok(ts.get_terrain_sets_count() == 1
			and ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES,
			"terrain set 0 = MATCH_SIDES")

	var terrain := ts.get_source(0) as TileSetAtlasSource
	var decor := ts.get_source(1) as TileSetAtlasSource
	_ok(terrain != null and decor != null, "source 0/1 都在")
	if terrain == null or decor == null:
		_finish()
		return
	var timg: Image = terrain.texture.get_image()
	var dimg: Image = decor.texture.get_image()
	_ok(timg.get_width() % tile == 0 and timg.get_height() % tile == 0, "地形图集边长是 %d 的倍数" % tile)
	var tsize: Array = m["terrain"]["size"]
	_ok(Vector2i(timg.get_width(), timg.get_height()) == Vector2i(int(tsize[0]), int(tsize[1])),
			"地形图集尺寸与清单一致")
	_ok(dimg.get_width() % tile == 0 and dimg.get_height() % tile == 0, "装饰图集边长是 %d 的倍数" % tile)
	var dsize: Array = m["decor"]["size"]
	_ok(Vector2i(dimg.get_width(), dimg.get_height()) == Vector2i(int(dsize[0]), int(dsize[1])),
			"装饰图集尺寸与清单一致")
	_ok(terrain.get_tiles_count() == 16, "地形 16 格，实测 %d" % terrain.get_tiles_count())
	_ok(decor.get_tiles_count() == int(m["decor"]["items"].size()),
			"装饰 %d 块，实测 %d" % [int(m["decor"]["items"].size()), decor.get_tiles_count()])

	# 地形图集必须整张不透明：碰撞是整格矩形，任何一块透明像素都意味着「踩在空气上」
	var opaque := true
	for y in timg.get_height():
		for x in timg.get_width():
			if timg.get_pixel(x, y).a < 0.99:
				opaque = false
	_ok(opaque, "地形图集整张不透明")

	var bits: Dictionary = m["terrain"]["mask_bits"]
	var side_of := {
		"up": TileSet.CELL_NEIGHBOR_TOP_SIDE,
		"right": TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
		"down": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
		"left": TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	}
	var half := float(tile) / 2.0
	for entry in m["terrain"]["tiles"]:
		var mask: int = int(entry["mask"])
		var coords := Vector2i(int(entry["x"]) / tile, int(entry["y"]) / tile)
		var td: TileData = terrain.get_tile_data(coords, 0)
		_ok(td != null, "mask %d 的 tile 在 %s" % [mask, coords])
		if td == null:
			continue
		_ok(td.get_collision_polygons_count(0) == 1, "mask %d 恰好 1 块碰撞多边形" % mask)
		if td.get_collision_polygons_count(0) == 1:
			var pts: PackedVector2Array = td.get_collision_polygon_points(0, 0)
			var want := PackedVector2Array([
				Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
			_ok(pts == want, "mask %d 的碰撞是整格矩形" % mask)
		for key in side_of:
			var want_t: int = 0 if (mask & int(bits[key])) != 0 else -1
			_ok(int(td.get_terrain_peering_bit(side_of[key])) == want_t,
					"mask %d 的 %s peering = %d" % [mask, key, want_t])

		# ---- 4 px 契约（贴纸语言）：描边朝外，亮面收在里面一格
		var ox: int = coords.x * tile
		var oy: int = coords.y * tile
		if mask & int(bits["up"]) == 0:
			_ok(timg.get_pixel(ox + 8, oy).a > 0.8, "mask %d 顶边第 0 行不透明" % mask)
			_ok(_lum(timg, ox + 8, oy) < _lum(timg, ox + 8, oy + 1), "mask %d 顶描边比内侧亮面暗" % mask)
			_ok(_lum(timg, ox + 8, oy) < _lum(timg, ox + 8, oy + 6), "mask %d 顶描边比主体暗" % mask)
			_ok(_lum(timg, ox + 8, oy + 1) > _lum(timg, ox + 8, oy + 6), "mask %d 顶亮面比主体亮" % mask)
		if mask & int(bits["left"]) == 0:
			_ok(timg.get_pixel(ox, oy + 8).a > 0.8, "mask %d 左边第 0 列不透明" % mask)
			_ok(_lum(timg, ox, oy + 8) < _lum(timg, ox + 1, oy + 8), "mask %d 左描边比内侧亮面暗" % mask)
			_ok(_lum(timg, ox, oy + 8) < _lum(timg, ox + 6, oy + 8), "mask %d 左描边比主体暗" % mask)
			_ok(_lum(timg, ox + 1, oy + 8) > _lum(timg, ox + 6, oy + 8), "mask %d 左亮面比主体亮" % mask)
		if mask & int(bits["right"]) == 0:
			_ok(timg.get_pixel(ox + 15, oy + 8).a > 0.8, "mask %d 右边末列不透明" % mask)
			_ok(_lum(timg, ox + 15, oy + 8) < _lum(timg, ox + 14, oy + 8), "mask %d 右描边比内侧亮面暗" % mask)
			_ok(_lum(timg, ox + 15, oy + 8) < _lum(timg, ox + 9, oy + 8), "mask %d 右描边比主体暗" % mask)
			_ok(_lum(timg, ox + 14, oy + 8) > _lum(timg, ox + 9, oy + 8), "mask %d 右亮面比主体亮" % mask)
		if mask & int(bits["down"]) == 0:
			_ok(timg.get_pixel(ox + 8, oy + 15).a > 0.8, "mask %d 底边末行不透明" % mask)
			_ok(_lum(timg, ox + 8, oy + 15) < _lum(timg, ox + 8, oy + 11), "mask %d 底边比主体暗" % mask)
			_ok(_lum(timg, ox + 8, oy + 14) < _lum(timg, ox + 8, oy + 11), "mask %d 底面阴影比主体暗" % mask)

	# ---- 装饰：零碰撞、矩形与清单一致、alpha 非空
	var items: Dictionary = m["decor"]["items"]
	var names: Array = items.keys()
	names.sort()
	for name in names:
		var r: Array = items[name]
		var coords := Vector2i(int(r[0]) / tile, int(r[1]) / tile)
		var size := Vector2i(int(r[2]) / tile, int(r[3]) / tile)
		var td: TileData = decor.get_tile_data(coords, 0)
		_ok(td != null, "装饰 %s 在 %s" % [name, coords])
		if td == null:
			continue
		_ok(decor.get_tile_size_in_atlas(coords) == size, "装饰 %s 占 %s 格" % [name, size])
		_ok(td.get_collision_polygons_count(0) == 0, "装饰 %s 零碰撞" % name)
		var lit := 0
		for y in range(int(r[1]), int(r[1]) + int(r[3])):
			for x in range(int(r[0]), int(r[0]) + int(r[2])):
				if dimg.get_pixel(x, y).a > 0.03:
					lit += 1
		_ok(lit > 0, "装饰 %s 的 alpha 非空（%d px）" % [name, lit])
	var wf_rect: Array = items["wall_fill"]
	var wall_opaque := true
	for y in range(int(wf_rect[1]), int(wf_rect[1]) + int(wf_rect[3])):
		for x in range(int(wf_rect[0]), int(wf_rect[0]) + int(wf_rect[2])):
			if dimg.get_pixel(x, y).a < 0.99:
				wall_opaque = false
	_ok(wall_opaque, "wall_fill 整格不透明（它铺满整层，漏 alpha 就是漏底）")
	var sh_rect: Array = items["shade"]
	var shade_mid := true
	for y in range(int(sh_rect[1]), int(sh_rect[1]) + int(sh_rect[3])):
		for x in range(int(sh_rect[0]), int(sh_rect[0]) + int(sh_rect[2])):
			var a: float = dimg.get_pixel(x, y).a
			if a <= 0.03 or a >= 0.99:
				shade_mid = false
	_ok(shade_mid, "shade 是半透明（全不透明会糊死墙面，全透明等于没画）")

	# ---- 引擎真的会按掩码选图：刷一块 5x3 实心，读回每格选中的图集坐标。
	# 预览图用的是 gen_tiles.py 自己的掩码逻辑，验不到 peering bit 的方向有没有接反；
	# 这一组让 Godot 的 terrain 求解器自己选，选错说明 bit 映射反了。
	var probe := TileMapLayer.new()
	probe.tile_set = ts
	add_child(probe)
	var block: Array = []
	for by in 3:
		for bx in 5:
			block.append(Vector2i(bx, by))
	probe.set_cells_terrain_connect(block, 0, 0)
	var expect := {
		Vector2i(2, 0): Vector2i(2, 3),   # 上开：mask 14
		Vector2i(0, 0): Vector2i(2, 1),   # 上+左开：mask 6
		Vector2i(2, 1): Vector2i(3, 3),   # 四邻全在：mask 15
		Vector2i(4, 2): Vector2i(1, 2),   # 下+右开：mask 9
		Vector2i(0, 2): Vector2i(3, 0),   # 下+左开：mask 3
	}
	for c in expect:
		var got: Vector2i = probe.get_cell_atlas_coords(c)
		_ok(got == expect[c], "terrain 笔刷在 %s 应选 %s，实测 %s" % [str(c), str(expect[c]), str(got)])
	probe.queue_free()

	# ---- 模板三层
	var scene := load(TEMPLATE) as PackedScene
	_ok(scene != null, "level_template.tscn 能加载")
	var root: Node2D = scene.instantiate()
	add_child(root)
	var wf := root.get_node_or_null("Terrain/WallFill") as TileMapLayer
	var dc := root.get_node_or_null("Terrain/Decor") as TileMapLayer
	var tl := root.get_node_or_null("Terrain/Tiles") as TileMapLayer
	_ok(wf != null and dc != null and tl != null, "模板 Terrain 下有 WallFill/Decor/Tiles 三层")
	if wf != null and dc != null and tl != null:
		_ok(wf.z_index == -30 and dc.z_index == -20 and tl.z_index == 0, "三层 z 序 -30 / -20 / 0")
		_ok(not wf.collision_enabled and not dc.collision_enabled, "WallFill / Decor 关掉碰撞")
		_ok(tl.collision_enabled, "Tiles 开着碰撞（layer/mask 在 TileSet 物理层上，上面已断言）")
		_ok(wf.tile_set == ts and dc.tile_set == ts and tl.tile_set == ts, "三层共用 lab_tileset.tres")
	root.queue_free()
	_finish()


func _finish() -> void:
	print("TILESET SELFTEST DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)
