@tool
class_name KeyPickup
extends Area2D
## K2 能量卡（D30/D36）：一次性拾取。`held` 住在实例自己身上 —— 不是 Player 的字段
##（玩家不该长背包），也不是 run_state 的条目：重载即归位，正好就是用户裁定的
##「复活时失去身上的钥匙并重置钥匙」（D30 第 3 条），粘性清单因此少一条。
##
## 拾取后节点**留在原地、不 re-parent 到玩家**：PlayerVisual 带 facing 镜像，子节点会跟着翻。
## 改为 _draw() 把一张半透明的卡画在玩家体内的常量偏移上（D39）：Objects 在场景树里排在
## Player 之后，画出来天然压在主角之上，连 z_index 都不用加。跟随走真实时间 ——
## 冻结期间玩家照样动，钥匙必须跟着动（D30 第 4 条，与主角动画豁免同一层规则），
## 所以 _process 里 held 期间每帧 queue_redraw，画的位置永远是玩家此刻的位置。
##
## 卡不裁、不遮罩、不把身体盖回卡上面（用户 2026-09-20 裁定：不动立绘）。
## 移动时有一部分露在体外算合理 —— 实测只有蹲伏那一档漏 3 px。
##
## 拾取判定与按钮同族（带心 -Player.COLLISION_HALF_HEIGHT 的地面传感带）：
## 接触即拾、没有确认窗口，冻结期间照样拾（Area2D 的 entered 不吃世界 delta，D38 第 4 条）。
## 消耗由 KeyDoor 调 consume(fly_time)：卡不当场消失，而是**从体内向上飞出去并淡化**（D41）。
## 两条通道分工明确：画仍然骑在跟随那条豁免通道上（永远画在玩家此刻的位置，D30 第 4 条），
## 计时却放在固定物理步长上 —— 世界那道闸只截 `TimeReceiver` 的门控 delta，截不到它，
## 所以世界停在冻结那一拍里、卡照样飞完，且与门的光幕同一条钟、同拍结束。
## 时长只住在门的 swipe_time 上，卡这一侧不另存一份常量，靠 consume() 的参数拿。
##
## D55：卡坐在**公共底座**上（与 D54 那只彩蛋同一张零件）。这一条替代了「像鸭子那样转」的
## 原方案 —— 转要解决的正是「玩家朝它走时世界必然冻着」（D40/D41 那条地基），提示会在最
## 需要它的那一刻关掉；底座是静态形状语言，冻着也照样说话。所以这张卡**不转、不挂
## TimeReceiver、一个导出项都不加**（旋钮留给人眼的那几条里没它）。座子只在"在位"那一态
## 是 idle，卡一进身体或已被门吐掉就换 taken 那道压痕；重载时实例整体归位、座子跟着回到
## idle（D30 第 3 条），与彩蛋那条"永久空座"是同一种皮、两种账（彩蛋不是机制素材，不复生）。
##
## @tool：编辑器里在原位画卡（摆图定位用）。

## 已被玩家持有（含在体内，画在玩家脚底上方）。
var held: bool = false
## 已被某扇 KeyDoor 消耗（飞完之后就什么都不画了）。held 与 consumed 不会同时为真。
var consumed: bool = false
## 飞出进行中：-1 表示不在飞行，否则是已经飞了多少秒（固定物理步长，与门共用同一条钟）。
var _fly_elapsed: float = -1.0
## 这一次飞行该飞多久，由 consume() 的调用方（KeyDoor）给 —— 门的光幕退场与卡必须同拍结束。
var _fly_time: float = 0.0

const TEX_CARD: Texture2D = preload("res://assets/props/key_card.png")
## 公共底座（D55）：与 `Collectible` 用的是同一张落盘零件，不新画、不进 `props.json` 对账的
## 新增项 —— 它已经在册（D54 那一批）。尺寸一律从贴图读，不写第二份数。
const TEX_PERCH_IDLE: Texture2D = preload("res://assets/props/perch_idle.png")
const TEX_PERCH_TAKEN: Texture2D = preload("res://assets/props/perch_taken.png")
## 拾取带：卡 14 宽，带子放宽到 32 让「擦过去也能捡到」；高度沿用按钮那条带心契约。
const BAND_W: float = 32.0
const BAND_H: float = 24.0
## 含在体内时卡的底边离脚底 3 px。脚底 = 玩家原点下方 Player.COLLISION_HALF_HEIGHT，
## 而 D22 把那条线钉死不动 —— 所以这一个常量就够，不读轮廓、不问蹲伏、不看朝向。
const FOOT_GAP: float = 3.0
## 含在体内时画的尺寸。原卡 14x10 贴上去会盖住整双眼睛，半透明之后眼睛泛成两块琥珀斑
## —— 比露在外面更糟。10x6 是顶行刚好不碰眼睛（脚底上方 10 px）的那一档。
const HELD_W: float = 10.0
const HELD_H: float = 6.0
## 60% 是「在体内」与「还认得出是那张卡」的分界：45% 以下卡就糊进黑身体里了。
const HELD_ALPHA: float = 0.6
## 飞出时卡的底边从体内锚点再往上走 30 px（约一个身位的一半），同时边长放大回贴图原尺寸
## ——「从体内吐出来」要有一个离开身体的距离，缩在原位淡掉读起来只是「闪了一下」。
const FLY_RISE: float = 30.0

@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()
	body_entered.connect(_on_body_entered)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 跟随与飞出都在**绘制通道**上重画：卡永远画在玩家此刻的位置上（D39/D30 第 4 条的豁免）。
	if held or _fly_elapsed >= 0.0:
		queue_redraw()


## 计时刻意放在物理通道，不放上面那个 `_process`：门那一侧走的是固定步长，
## 卡要是走帧率相关的真实 delta，卡一慢演出就会比光幕先结束或后结束，那一拍就散架了。
## 冻结不吃固定物理步长（TimeManager 那道闸只截 `get_physics_delta()`），所以演出照跑。
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _fly_elapsed < 0.0:
		return
	_fly_elapsed += delta
	if _fly_elapsed >= _fly_time:
		_fly_elapsed = -1.0
		# 归 -1 的这一帧 `_process` 已经跑过去了，不补一次重画卡会停在最后一帧的残影上。
		queue_redraw()


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	if held or consumed:
		return
	held = true
	queue_redraw()


func is_held() -> bool:
	return held


## 座子上此刻有没有卡（D55）。空座皮只认这一个判据，画的那一侧也读它 ——
## 两态判定写两份迟早只改一边，而"卡走了座子还画成满的"正是那种不响的错。
func seat_occupied() -> bool:
	return not held and not consumed and _fly_elapsed < 0.0


## 飞出进度 0..1，不在飞出时返回 -1。守门读它核对「卡与幕同拍结束」。
func fly_progress() -> float:
	if _fly_elapsed < 0.0:
		return -1.0
	return clampf(_fly_elapsed / maxf(_fly_time, 0.001), 0.0, 1.0)


## KeyDoor 闩锁时来取走钥匙，时长由调用方传进来：swipe_time 只住在门身上，卡这里
## 刻意不留第二个常量，两处才谈得上同拍结束。没持有或已消耗返回 false —— 门那边
## 只会白试一次，不会误闩（一把卡被两扇门引用本身就该被守门拦下，D30 第 6 条）。
func consume(fly_time: float) -> bool:
	if not held or consumed:
		return false
	consumed = true
	held = false
	_fly_time = maxf(fly_time, 0.001)
	_fly_elapsed = 0.0
	queue_redraw()
	return true


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(BAND_W, BAND_H):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(BAND_W, BAND_H)
		_collision.shape = shape
	var band := Vector2(0.0, -Player.COLLISION_HALF_HEIGHT)
	if _collision.position != band:
		_collision.position = band
	queue_redraw()


## 原地画卡 / 含在体内 / 正被门吐出去 / 消耗完只剩空座，四种状态一眼分开。
## 底座永远画在构件原地、不跟玩家走（D55）：它是「这里放过一张卡」的那块地方，不是卡的一部分。
func _draw() -> void:
	var on_seat: bool = seat_occupied()
	var perch_h := float(TEX_PERCH_IDLE.get_height())
	draw_texture(TEX_PERCH_IDLE if on_seat else TEX_PERCH_TAKEN,
		Vector2(-float(TEX_PERCH_IDLE.get_width()) * 0.5, -perch_h))
	if consumed and _fly_elapsed < 0.0:
		return
	var src := Rect2(0.0, 0.0, float(TEX_CARD.get_width()), float(TEX_CARD.get_height()))
	if on_seat:
		draw_texture_rect_region(TEX_CARD,
			Rect2(-TEX_CARD.get_width() * 0.5, -perch_h - float(TEX_CARD.get_height()),
				float(TEX_CARD.get_width()), float(TEX_CARD.get_height())), src)
		return
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		return
	# 尸体不带着卡（D42）：身体正在缩成一个点，卡还钉在脚底会脱开成一张悬空的贴纸。
	# 让它跟人一起消失；重载时卡自己归位（D30 第 3 条），不欠谁一条重置。
	if player.is_dead:
		return
	var lp := to_local(player.global_position)
	var bottom: float = lp.y + Player.COLLISION_HALF_HEIGHT - FOOT_GAP
	if _fly_elapsed < 0.0:
		draw_texture_rect_region(TEX_CARD,
			Rect2(lp.x - HELD_W * 0.5, bottom - HELD_H, HELD_W, HELD_H), src,
			Color(1.0, 1.0, 1.0, HELD_ALPHA))
		return
	# 飞出：底边从体内锚点往上走 FLY_RISE，尺寸长回贴图原样，alpha 线性掉到 0。
	# 位移写成显式的二次缓出（先窜后飘）而不是匀速 —— 匀速读作「飘」，不读作「被吐出来」。
	# 不引 easef() 是因为它的 curve 参数方向反直觉，写算式比查语义便宜。
	var t: float = clampf(_fly_elapsed / maxf(_fly_time, 0.001), 0.0, 1.0)
	var ease_out: float = 1.0 - (1.0 - t) * (1.0 - t)
	var w: float = lerpf(HELD_W, float(TEX_CARD.get_width()), t)
	var h: float = lerpf(HELD_H, float(TEX_CARD.get_height()), t)
	var rise: float = FLY_RISE * ease_out
	draw_texture_rect_region(TEX_CARD,
		Rect2(lp.x - w * 0.5, bottom - h - rise, w, h), src,
		Color(1.0, 1.0, 1.0, HELD_ALPHA * (1.0 - t)))
