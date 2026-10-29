class_name DreamBubbles
extends Node2D
## D77 梦泡（新手引导）：开局那一拍钉在睡姿上，等玩家把四只泡按破才醒。
##
## **它不是 D59/D75 那一族纯装饰**：它掐输入、发 `completed`、被关卡根连着 —— 有契约面。
## 但它也**不是** D69 那族器件：不挂 `TimeReceiver`、不进 `anchorable`、锚点劫持不到它。
## 时基（第三条路，与那两族都不同，理由硬）：漂移与破的三帧都吃**引擎固定物理步长**，
## 既不读 `TimeManager.elapsed_world_time` 也不读门控 delta ——
## ① 这一拍整段掐输入 ⇒ `get_axis()` 恒 0 ⇒ 不算"他在移动" ⇒ 世界照常流动，
##    所以走世界钟数值上没错，但语义上错：**梦在他脑子里，不归世界钟管**；
## ② 更要紧的是这一拍教的就是"按下去会发生什么"，任何"你按了 A 所以它停了"的读法
##    都会把教学打成 bug（D76 那条"照时钟揭幕会在人正朝它走的时候停住"是同一个形状）。
##
## 皮：**只画 `assets/props/dream_bubble/*.png`，一格像素都不自己算** —— 那些 PNG 由
## `tools/gen_dream_bubble_parts.py` import 选型图那个写手（`gen_dream_bubble_preview.bubble_of`）
## 落盘，所以"他批的那张图"与"进关的那只泡"是同一段代码的两次调用（D56/D58 那条单一写手）。
##
## 几何（弧心、四只的角度、默认半径、动作映射、零件尺寸）全部**读清单**
## `assets/props/dream_bubble.json`：源码里不许出现第二份半径或角度 —— 那是"断言不许抄第二份数"
## 那条老账在皮这一侧的对应物。清单与 InputMap 由 `verify_kit` 逐条核对（动作名改不到就红）。
##
## 四只泡 = 四个动作（`move_left` / `move_down` / `jump` / `move_right`），**按动作判、不按 keycode**：
## 无头守门注入输入用的就是 `Input.action_press`，而且方向键 / Z / K / 手柄那几条后备顺带也算命中。
## W 不做（InputMap 里没有"向上"这个动作，按下去不操控任何东西）；Q 也撤（这一拍
## `movement_locked` 为真，锚点那三道闸发不出也供不了时 ⇒ 那只泡永远破不了 = 直接软锁）。
##
## 节点原点 = **弧心**（清单里 `arc_origin_y` 说的就是它相对玩家原点的偏移），
## 走"块心"那一族；四只泡在弧上，一只都不压睡脸、一只都不进砖里。

signal completed

const MANIFEST_PATH := "res://assets/props/dream_bubble.json"
## 破的那一拍每帧多久（三帧，不循环）。填 0 = 一按就没，不留"它破了"这一眼。
@export var pop_frame_seconds: float = 0.06
## 跟着人走：钉住的是控制、不是位置，出生位那几像素的下落不该让泡停在半空。
@export var follow_player: bool = true

var _items: Array = []
var _manifest_ready := false
var _done := false


func _ready() -> void:
	_build()


func _physics_process(delta: float) -> void:
	if not _manifest_ready or _done:
		return
	if follow_player:
		var player := get_tree().get_first_node_in_group(&"player") as Node2D
		if player != null:
			global_position = player.global_position \
				+ Vector2(0.0, float(_manifest()["arc_origin_y"]))
	# DEBUG-KEY：F9 一次破完四只。打包删这一句就整条断开（开发期每次启动都要按四下才动）。
	if OS.is_debug_build() and Input.is_action_just_pressed(&"dev_skip_dream"):
		for item in _items:
			_pop(item)
	for item in _items:
		if item["popped"]:
			item["t"] += delta
			if int(item["t"] / maxf(pop_frame_seconds, 0.0001)) + 1 >= int(item["states"]):
				item["visible"] = false
			if item["state"] != _pop_state(item):
				item["state"] = _pop_state(item)
				queue_redraw()
		elif Input.is_action_just_pressed(item["action"]):
			_pop(item)
	if not _done and _all_broken():
		_done = true
		completed.emit()


func _pop(item: Dictionary) -> void:
	if item["popped"]:
		return
	item["popped"] = true
	item["t"] = 0.0
	item["state"] = 1
	queue_redraw()


func _pop_state(item: Dictionary) -> int:
	if not item["popped"]:
		return 0
	return mini(int(item["t"] / maxf(pop_frame_seconds, 0.0001)) + 1,
		int(item["states"]) - 1)


func _all_broken() -> bool:
	for item in _items:
		if not item["popped"]:
			return false
		if item["visible"]:
			return false
	return true


## 已经按过几只（守门读它，不是读 `_done`：重复按同一只不许双计）。
func popped_count() -> int:
	var n := 0
	for item in _items:
		if item["popped"]:
			n += 1
	return n


func _draw() -> void:
	if not _manifest_ready:
		return
	for item in _items:
		if not item["visible"]:
			continue
		var tex: Texture2D = item["textures"][item["state"]]
		var size: Vector2 = Vector2(item["size"][0], item["size"][1])
		draw_texture(tex, item["pos"] - size * 0.5)


func _manifest() -> Dictionary:
	var fh := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if fh == null:
		push_error("[dream] 读不到 %s —— 先跑 py tools/gen_dream_bubble_parts.py" % MANIFEST_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(fh.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[dream] %s 解析失败" % MANIFEST_PATH)
		return {}
	return parsed


func _build() -> void:
	var manifest := _manifest()
	if manifest.is_empty():
		return
	var states := int(manifest["states"])
	var radius := float(manifest["radius"])
	_items.clear()
	for entry in manifest["bubbles"]:
		var part := str(entry["part"])
		var size: Array = manifest["parts"][part]
		var textures: Array[Texture2D] = []
		for state in states:
			var path := "res://assets/props/dream_bubble/%s_%d.png" % [part, state]
			var tex := load(path) as Texture2D
			if tex == null:
				push_error("[dream] 纹理不在: %s（先跑 --import）" % path)
				return
			textures.append(tex)
		var deg := float(entry["deg"])
		# 角度按数学惯例（逆时针、0 度朝右），而 Godot 的 +y 朝下 —— 所以 y 取负。
		var pos := Vector2(radius * cos(deg_to_rad(deg)), -radius * sin(deg_to_rad(deg)))
		_items.append({
			"action": StringName(entry["action"]),
			"part": part,
			"pos": pos,
			"size": size,
			"textures": textures,
			"states": states,
			"popped": false,
			"visible": true,
			"t": 0.0,
			"state": 0,
		})
	_manifest_ready = true
	queue_redraw()
