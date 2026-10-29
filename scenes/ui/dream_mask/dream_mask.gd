class_name DreamMask
extends CanvasLayer
## D78 开场遮罩：苏醒之前看不清周围 —— 一圈"还没醒"的眼睛。
##
## **它是第四件纯表现件，走 D76/D77 那一条时基**：不读 `TimeManager.elapsed_world_time`、
## 不挂 `TimeReceiver`、不进 `anchorable`、不认 `run_state`、**一根信号都不发**（与 D59/D75
## 那两件同族，与 D77 那件梦泡相反 —— 梦泡有 `completed`，这一件没有要通知任何人）。
## 呼吸那一条计时吃**引擎固定物理步长**：这一拍整段掐着输入 ⇒ `get_axis()` 恒 0 ⇒ 世界照常
## 流动，所以走世界钟数值上没错，但语义错 —— 遮罩说的是"他的意识"，与 D77 那句
## "梦在他脑子里"是同一句话。
##
## 它唯一的事实来源是 `Player.wake_progress()`（0..1，钉住期间给 0，窗口不在给 −1）：
## **半径是进度的纯函数**，所以它不需要谁通知、不需要边缘信号、也不给唯一事实另发一条
## 信号（D62 那条口径）。进度回到 −1 那一拍它自己收摊。
##
## 皮：**只画 `assets/props/dream_mask.png` 那一张，一格像素都不自己算**。那张 PNG 与
## 他批过的选型图①卡由 `tools/gen_dream_mask_preview.py` 里**同一个 `mask_layer()` 调用**
## 生成（D56/D58/D77 那条单一写手），几何（亮区半径、软边比例、外圈黑度、张到哪、呼吸幅度
## 与周期、圆心偏移）全读 `assets/props/dream_mask.json` —— 源码里出现第二份数就红。
##
## **张开 = 整张放大**，不是重画：所以那张图按"圆心到屏最远那角"做成正方形，
## 任何一档半径都还盖得住整屏（按 `r_in` 做的话张到一半，屏幕四角就露出没遮罩的空隙）。
##
## 圆心跟的是**玩家在屏幕上的位置**（`get_viewport().get_canvas_transform()` 换算），
## 不是"屏幕正中"那个常量：`level_1` 今天限位没开、相机正中以玩家为条件成立，
## 但换一关开了限位、或出生点贴着边界，那个常量就会把亮区挪到别人身上 —— 而这条不报错，
## 只在画面上"人躲在暗处、亮圈空着"。
##
## 层：`layer = 90` —— 必须在冻结滤镜（`TimeFreezeFilter`，100）**之下**（滤镜吃的是屏幕，
## 遮罩要被滤镜一起扫进去才对），又必须在 HUD/调试面板（300）之下、在世界之上。
## 结构上这两层在这一拍不会同框（掐着输入 ⇒ 世界不冻结 ⇒ CRT 不上屏），但顺序仍要钉住：
## 哪天有人把遮罩挪到 100 之上，冻结那一拍就会把"还没醒"的暗角一起提亮，那是说谎。

const MANIFEST_PATH := "res://assets/props/dream_mask.json"

@onready var _sprite: Sprite2D = $Mask

var _m: Dictionary = {}
var _breath: float = 0.0


func _ready() -> void:
	layer = 90
	var fh := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if fh == null:
		push_error("[dream-mask] 读不到 %s —— 先跑 py tools/gen_dream_mask_preview.py" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(fh.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[dream-mask] %s 解析失败" % MANIFEST_PATH)
		return
	_m = parsed
	var tex := load(String(_m["texture"]["file"])) as Texture2D
	if tex == null:
		push_error("[dream-mask] 皮不在: %s（先跑 --import）" % String(_m["texture"]["file"]))
		return
	_sprite.texture = tex
	# 皮的尺度：1 世界像素 = `tex_px_per_world_px`(=2) 个纹理像素 ⇒ 皮上亮区半径 =80×2=160
	# 个纹理像素。Sprite2D 的 scale 是"画布单位/纹理像素"，而这一层画布就是屏幕，
	# 所以基准档要 `zoom/2`（实机 zoom 2 ⇒ 1.0，屏上半径正好 160 设备像素 = 选型图那一档）。
	# 换算式写在 `_physics_process` 里，三个数（清单半径、烘法、取景）各有出处。
	# 呼吸会让半径在基准上下 ±6，缩的那半档最小只到 0.925 倍；没开 mipmap 但被缩的是一条
	# 平滑 alpha 坡，不会有可见锯齿。
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	visible = false


func _physics_process(delta: float) -> void:
	if _m.is_empty():
		return
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		visible = false
		return
	var p: float = player.wake_progress()
	if p < 0.0:
		# 不在苏醒窗口里 = 这一关没有这一拍（死亡重载、按 R、`dream_intro=false`、F6 直跑）
		visible = false
		return
	visible = true
	_breath += delta
	var base := lerpf(float(_m["radius"]), float(_m["open_radius"]), p)
	# 呼吸幅度随进度收掉：钉住期间（p==0）是满幅，张开的路上自己平下来 ——
	# 否则"最后一发按破"那一拍会从当前呼吸相位跳回基值，看得见一次弹。
	var amp := float(_m["breath_amplitude"]) * (1.0 - p)
	var radius := base + amp * sin(TAU * _breath / float(_m["breath_period"]))
	var at: Vector2 = player.global_position + Vector2(0.0, float(_m["arc_origin_y"]))
	var xform := get_viewport().get_canvas_transform()
	_sprite.position = xform * at
	# CanvasLayer 的那张画布**不吃相机的 zoom**（它自己就是屏幕空间），所以光有"世界半径"
	# 不够：这一拍的屏幕上 1 世界单位占几个像素，得从同一个变换的基向量里问出来 ——
	# 用变换自己的 x 轴长度（`xform.x.length()`）而不是 `_camera.zoom.x`，是为了让位置与大小
	# **永远来自同一个取景**：换相机、开 content_scale、哪天加个分屏都不会一个跟得上一个跟不上。
	var px_per_world := xform.x.length()
	_sprite.scale = Vector2.ONE * (px_per_world * radius \
		/ (float(_m["radius"]) * float(_m["tex_px_per_world_px"])))
