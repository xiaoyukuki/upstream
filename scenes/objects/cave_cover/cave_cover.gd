class_name CaveCover
extends TileMapLayer
## D76 假墙盖：把暗室 / 隐藏通道用**它背靠的那面墙自己的实心瓦片**盖起来，玩家走到洞口
## 跟前才整块隐去。项目里第一个由"玩家站位"驱动的纯表现件（前三件装饰都是钟 / 屏那类
## 自己会动的，只有它是被看的人推着走）。
##
## 为什么不是半透明帘子：把路盖成"半暗"盖不住 —— 叠一层 65% 的 `shade` 只把对比度
## 从 2.62 压到 2.28，路的轮廓还读得出来，而这条美术线早就判过 2.63 不足以读暗形体
## （g2 那圈边光就是为这个加的）。所以遮挡必须接近不透明，而**不透明的假墙**只有一种
## 诚实的做法：用墙自己那块瓦片。盖上去与旁边一格接缝都看不出来，才有"这里本来没门"。
##
## 为什么不用光照：项目里 Light2D / CanvasModulate / Occluder 全是 0 条，2D 光照这条路
## 要从零开；而一块半径 3 格的亮圈在 315 px（≈20 格）的满跳射程面前等于没有 —— 跳过去
## 那一瞬什么都看不到，只能靠背图。
##
## 时基：**没有时基**。这一件的全部输入是玩家身体中心到洞口点的距离（`alpha_for()` 是
## 位置纯函数：同一站位永远同一不透明度）。这不是省事：本作横按方向键即冻世界
## （`player.gd` 的 `set_frozen_override`），任何"按世界钟推进"的揭幕都会在**玩家正朝它
## 走的时候**停住 —— 走十步它一格不动，一松手整段跳完。D75 那条"装饰只读世界钟"在这里
## 反过来：装饰不许读世界钟。
##
## 三档（`reveal_near` / `reveal_far`，默认 3 格 / 10 格）：
##   距离 ≤ near   → 0（全隐，路连同里面的东西一起露出来）
##   距离 ≥ far    → 1（全挡，与真墙逐格同色，接缝看不出来）
##   中间          → 线性
## **站进盖子自己的格子里一律 0**：只按到洞口的距离算，人走进屋里超过 far 那一下会被
## 重新盖住 —— 那是这件东西最容易写错、而且只在"走到最里面"才露馅的一条。
##
## 多块（2026-10-28 补）：一个节点里可以刷好几块互不相连的盖子（TileMap 的正常用法），
## **每一块独立判定**。`modulate` 是节点级的 —— 只要格子还全画在根上，它们就共用一个
## 不透明度：人站在两块**之间**（在整片外接框里、但不在任何一块上）会让整片一起透明，而
## 靠近 A 的口子也会顺带把 B 变淡（`Mouth` 只有一个参照点）。所以第一拍之前把格子按 8 邻接
## 连通块拆进各自的子层（`Patch1` / `Patch2` …），根只当作者刷格子的画布、拆完清空。
## 8 邻接而不是 4 邻接：刷得不太规整的墙块斜着搭一格仍是"一块墙"，不该在视觉上裂开。
## 洞口点：`Mouth` / `Mouth2` / `Mouth3` … 可以放任意多个，**每个按"离哪块最近"归属一块**；
## 没分到 Mouth 的块退回它自己的包围盒中心。单块单口的情形与拆分前逐像素一致。
##
## 层：`z_index = 1`。必须高于 z=0 的 `Terrain/Tiles` / 玩家 / 屋里摆的东西，否则盖不住
## 内容物（`Terrain/Decor` 是 −20、背景 `WallFill` 是 −30，都在下面）。CRT 滤镜在
## CanvasLayer 100，仍然压在最上面。拆出来的子层 z_index 留 0（相对父级 ⇒ 仍是 1）。
##
## `collision_enabled = false`：它画的正是地形图集里那块**带碰撞多边形**的实心格（source 0
## 的 mask 15），碰撞由层开关关掉 —— 与背景 `WallFill` 用同一手（那层也是 source 0 + 关碰撞）。
## 忘了关，玩家会撞在自己看不见的空中墙上：这类死法不报错，只在试玩时"这里怎么走不过去"。
##
## 摆法：盖子的格子由作者刷（场景出厂是空层），要求**每一格都是实心格**（verify_kit 逐格
## 读 tiles.json 核对，含一条负对照证明它会红）；`tile_set` 必须与关卡 `Terrain/Tiles` 同一份。
## 洞口点由作者放一个名为 `Mouth` 的 Marker2D 决定；没有就退回盖子用格包围盒的中心。
## 它只是距离量的参照点而不是碰撞体 —— 放在"玩家会走过来的那一侧、紧贴墙面"。
## 一块盖子里刷了几处洞口，就给它放几个 `Mouth`（名字都以 `Mouth` 开头即可），
## 每个会自动归给离它最近的那一块。
##
## 刻意不是 @tool：编辑器里一跑 `_physics_process` 就会把当时的 `modulate.a` 写进 .tscn，
## 那份值会在检查器里看起来像"作者调过的透明度"，然后下次开门时没人记得它是被谁写的。
## 摆图时用层的眼睛开关看穿检查布局。
##
## 不做的事（都不属于这一件）：屋里暗不暗交给作者铺 `shade` 瓦片；没有碰撞体、不发
## signal、不认存档、不进 `anchorable` 族、不挂时间接收器 —— 与 D59 / D75 同一族
## 的零契约表现件。

## 露出距离（世界像素）：玩家身体中心到洞口点 ≤ 它时整块隐去。默认 3 格。
@export var reveal_near: float = 48.0
## 全挡距离：≥ 它时不透明。中间线性。默认 10 格 —— 比满跳射程（315 px）短，
## 于是"跳过去那一瞬"被子遮住而不是先看见再跳。
@export var reveal_far: float = 160.0

const MOUTH_PREFIX := "Mouth"

## 拆出来的每一块（8 邻接连通的一坨格子）。空 = 还没拆（根上就是全部格子）。
var _patches: Array[TileMapLayer] = []
var _split := false
## 每块上一次写进去的值，只用来省重写，不是状态（键是层实例）。
var _applied := {}


func _ready() -> void:
	_split_patches()


func _physics_process(_delta: float) -> void:
	_split_patches()
	var layers := all_patches()
	var hero := get_tree().get_first_node_in_group(&"player") as Node2D
	var have := hero != null
	var centre := Vector2.ZERO
	if have:
		centre = hero.global_position + Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	for i in layers.size():
		var a := 1.0
		if have:
			a = alpha_for(centre, i)
		var map := layers[i]
		if is_equal_approx(float(_applied.get(map, -1.0)), a):
			continue
		_applied[map] = a
		map.modulate.a = a


## 这一节点现在真正在画的层：拆过就是各块子层，没拆就是自己（出厂态 / 守门合成 fixture）。
func all_patches() -> Array[TileMapLayer]:
	var out: Array[TileMapLayer] = []
	if _patches.is_empty():
		out.append(self)
		return out
	return _patches


func patch_count() -> int:
	return all_patches().size()


## 这一块当前写在屏上的不透明度（还没跑过物理拍的块是 1）。
func current_alpha(patch: int = 0) -> float:
	var layers := all_patches()
	if patch < 0 or patch >= layers.size():
		return 1.0
	return layers[patch].modulate.a


## 给定玩家身体中心的世界坐标，返回第 `patch` 块这一拍该有的不透明度。
## 纯位置函数：不读时钟、不读帧数、不累加 —— 守门钉的就是"同一站位永远同一值"。
func alpha_for(player_centre: Vector2, patch: int = 0) -> float:
	var layers := all_patches()
	if patch < 0 or patch >= layers.size():
		return 1.0
	if _inside_cells(layers[patch], player_centre):
		return 0.0
	var d := mouth_point(patch).distance_to(player_centre)
	if d <= reveal_near:
		return 0.0
	if d >= reveal_far:
		return 1.0
	return (d - reveal_near) / (reveal_far - reveal_near)


## 第 `patch` 块用格在世界坐标下的包围盒。那一块没有格子时是空矩形。
func reveal_rect(patch: int = 0) -> Rect2:
	var layers := all_patches()
	if patch < 0 or patch >= layers.size():
		return Rect2(global_position, Vector2.ZERO)
	var map := layers[patch]
	var used := map.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0 or map.tile_set == null:
		return Rect2(map.global_position, Vector2.ZERO)
	var cell := Vector2(map.tile_set.tile_size)
	var top_left := map.to_global(map.map_to_local(used.position)) - cell * 0.5
	var bottom_right := map.to_global(map.map_to_local(used.end - Vector2i.ONE)) + cell * 0.5
	return Rect2(top_left, bottom_right - top_left)


## 第 `patch` 块的洞口点：归给它、离它最近的那个 `Mouth`；一个都没归过来就取自己的包围盒中心。
func mouth_point(patch: int = 0) -> Vector2:
	var layers := all_patches()
	if patch < 0 or patch >= layers.size():
		return global_position
	var mouth := _assigned_mouths(layers)[patch] as Node2D
	if mouth != null:
		return mouth.global_position
	return reveal_rect(patch).get_center()


## "站进盖子自己的格子里"按**这一块**的格子算，不是整片的外接框 ——
## 多块的情形下，人站在 A 里不该顺手把 B 也打开。
func _inside_cells(map: TileMapLayer, point: Vector2) -> bool:
	if map.get_used_cells().is_empty():
		return false
	return map.get_cell_source_id(map.local_to_map(map.to_local(point))) != -1


## 把根上的格子按 8 邻接连通块拆进子层。只在第一拍做一次；格子归作者在编辑器里刷，
## 运行期再往根上刷不会被拆（拆分之后根就是空的画布了）。
func _split_patches() -> void:
	if _split:
		return
	if tile_set == null or get_used_cells().is_empty():
		return
	_split = true
	var groups := _connected_groups(get_used_cells())
	for i in groups.size():
		var layer := TileMapLayer.new()
		layer.name = "Patch%d" % (i + 1)
		layer.tile_set = tile_set
		layer.collision_enabled = false
		add_child(layer)
		for cell in groups[i]:
			layer.set_cell(cell, get_cell_source_id(cell), get_cell_atlas_coords(cell),
				get_cell_alternative_tile(cell))
		_patches.append(layer)
	clear()
	# 拆之前那一拍根上可能已经写过 0（人进门时），子层会继承父级的 alpha —— 必须还回去。
	modulate.a = 1.0
	_applied.clear()


func _connected_groups(cells: Array[Vector2i]) -> Array:
	var sorted := cells.duplicate()
	sorted.sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
	var members := {}
	for cell in sorted:
		members[cell] = true
	var seen := {}
	var groups := []
	for cell in sorted:
		if seen.has(cell):
			continue
		var group: Array[Vector2i] = []
		var queue: Array[Vector2i] = [cell]
		seen[cell] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			group.append(cur)
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var next := cur + Vector2i(dx, dy)
					if not members.has(next) or seen.has(next):
						continue
					seen[next] = true
					queue.append(next)
		groups.append(group)
	return groups


func _mouth_nodes() -> Array[Node2D]:
	var out: Array[Node2D] = []
	for child in get_children():
		if not String(child.name).begins_with(MOUTH_PREFIX):
			continue
		var node := child as Node2D
		if node != null:
			out.append(node)
	return out


## 每个 Mouth 只归给离它最近的那一块（一块拿到多个时取更近的那个）—— 一块一个参照点，
## 才是"每块自己判断自己".
func _assigned_mouths(layers: Array[TileMapLayer]) -> Array:
	var best: Array = []
	var best_d: Array = []
	best.resize(layers.size())
	best_d.resize(layers.size())
	best_d.fill(INF)
	for node in _mouth_nodes():
		var winner := -1
		var winner_d := INF
		for i in layers.size():
			var d := _rect_distance(reveal_rect(i), node.global_position)
			if d < winner_d:
				winner_d = d
				winner = i
		if winner >= 0 and winner_d < float(best_d[winner]):
			best_d[winner] = winner_d
			best[winner] = node
	return best


func _rect_distance(rect: Rect2, point: Vector2) -> float:
	var dx := maxf(maxf(rect.position.x - point.x, point.x - rect.end.x), 0.0)
	var dy := maxf(maxf(rect.position.y - point.y, point.y - rect.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)
