class_name LevelBase
extends Node2D
## 关卡基类（D28）。四件事：
##
## 1. 把全局时间系统拉回已知状态（风险表「场景切换状态残留」）；
## 2. 把相机取景框交给关卡（D15）；
## 3. 承接两块**所有关卡都一样**的编排：祭坛授予能力（D16 静止即启）与终点区收尾（D18）。
## 4. 死亡与存档（D31/D38/D42）：全子树扫描危险物（发 `touched_player` 即死）与存档点
##    （发 `checkpoint_reached` 记位）；死亡走「保留 run_state 的重载」，`_ready()` 末尾
##    回灌重生位与祭坛已耗。与祭坛/终点同一口径：构件摆进场景树就生效，零接线。
##    D42 起死亡不当帧换场景：先叫 `player.die(death_time)` 演一拍，等它发回 `death_finished`
##    才去委托重载 —— 时长只住在本类这一个导出项上，Player 与液滴都不另存一份。
##    D51 补上这条链上两处「有读、没人写」的洞：祭坛已耗由踩上它的那一刻真的记进
##    run_state（此前游戏代码里没有任何地方写这个键，回灌是死路，只有守门脚本手写）；
##    存档点改为**全关卡只一台激活** —— 新台顶掉旧台（旧台回 idle 皮），它的身份（相对
##    本关卡根的 NodePath）与重生位一起进 run_state，于是重载后亮着的还是那一台。
##    D54 加第三族传感器：彩蛋收集物（发 `collectible_taken` + 认 `mark_taken()`）。
##    它与钥匙卡分道扬镳 —— 钥匙死了掉回去（D30 第 3 条），彩蛋拿过就永久空座：
##    前者是机制素材、重来正是解谜的一部分，后者是对"发现"的收据。
##
## 第 3 条原来每关抄一遍：`level_01_tutorial.gd` 与 `level_template.gd` 各一份，实现还不一致
## （引导关写死 const、模板用导出项）。现在下沉到基类，新关只要按模板约定摆好
## `Objects/AbilityAltar` 与 `Triggers/GoalZone` 就自动生效，零代码。
##
## 接线一律走 NodePath，不写死 `$Objects/xxx` —— 与 D20 给门定下的规矩一致：
## 节点改名或挪层级，在检查器里重指即可，不用回来改脚本。路径解析不到就静默跳过，
## 这样「本关没有祭坛」是一个合法配置而不是报错。

## M1 沙盒置 true 以便直接测试时停手感；M2 引导关必须置 false，能力在祭坛处才授予。
@export var start_with_ability: bool = true

## 取景框：position=左上角世界坐标，size=可见范围。留空（size 为 0）则沿用
## player.tscn 里的兜底 limits。相机归关卡管，换关才不会互相穿帮（D15）。
@export var camera_limits: Rect2 = Rect2()

@export_group("Altar")
## 祭坛路径。留空 = 本关不授予能力（一开局就有能力的纯解谜关）。
## 默认按模板约定找 Objects/AbilityAltar；挪了位置就在检查器里重指。
@export_node_path var altar_path: NodePath = ^"Objects/AbilityAltar"
## D16：踩上祭坛后要等玩家停手才开能力，这个数是兜底上限（秒，真实时间）。
@export var ability_enable_timeout: float = 2.5

@export_group("Goal")
## 终点区路径。留空 = 本关不自动收尾，由关卡脚本自己处理。
@export_node_path var goal_path: NodePath = ^"Triggers/GoalZone"
## 玩家在终点停手后隔多久重开本关（秒，真实时间）。填 0 表示不自动重开，自己收尾。
@export var goal_restart_delay: float = 1.5

@export_group("Death")
## 死亡那一拍多长（秒，D42）。判死当帧掐物理、把世界钉在冻结里、演「收缩 + 爆裂」，
## 演完才重载回存档点。想更快就拧小，别指望填 0 能跳过这一拍 —— 跳过就又回到
## 「碰到尖刺什么都没发生」，而这一拍的存在理由恰恰是「你死了，得让你看见」。
@export var death_time: float = 0.55

@onready var player_spawn: Marker2D = get_node_or_null("PlayerSpawn")

var _handler: MovementInputHandler
var _awaiting_ability: bool = false
var _ability_wait: float = 0.0
var _goal_reached: bool = false
var _goal_wait: float = 0.0
## 死亡那一拍正在演（D42）：演完之前不换场景，也不让祭坛/终点那两段编排继续插话。
var _dying: bool = false
## 演出已结束、重载还没落地的那一帧。
var _death_pending: bool = false
## 当前激活的那一台存档点（D51）：亮灭只有这一处说了算，存档点之间不互认。
var _active_checkpoint: Node


func _ready() -> void:
	_warn_no_world_root()
	TimeManager.reset_state()
	TimeManager.set_ability_enabled(start_with_ability)
	_place_player()
	_apply_run_state()
	_maybe_intro()
	_apply_camera_limits()
	_grab_handler()
	_bind_altar()
	_bind_goal()
	_bind_hazards()
	_bind_checkpoints()
	_bind_collectibles()


## 两段等待都走 _process 的真实 delta：它们判的是"玩家什么时候松手"，
## 而玩家豁免时停；用门控 delta 会变成"没松手所以世界停所以计时也停"的死结。
func _process(delta: float) -> void:
	# 死亡优先：都死了一帧了，别的编排没意义。危险物信号从 _physics_process 发出，
	# 直接在信号里换场景等于在物理回调里 free 整棵关卡 —— 缓一帧到 _process 再动手。
	# D42 起这一帧之后还有一整拍演出：重载等 player 的 death_finished 来点名。
	if _death_pending:
		_death_pending = false
		_reload_level()
		return
	if _dying:
		return
	_tick_ability(delta)
	_tick_goal(delta)


## 子节点的 _ready() 先于父节点执行，因此 Player 已把 spawn_point 记成自己的编辑期位置，
## 这里用 PlayerSpawn 标记覆盖掉，保证重生点由关卡布局说了算。
func _place_player() -> void:
	if player_spawn == null:
		return
	_set_player_start(player_spawn.global_position)


func _set_player_start(pos: Vector2) -> void:
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	player.global_position = pos
	player.spawn_point = pos
	player.velocity = Vector2.ZERO


## 开局苏醒那一拍（D57）。**演不演由关卡根决定**：Player 不知道自己是不是"这个进程的第一次"，
## 常驻根才晓得（它比关卡活得久），而"要不要现在掐住玩家的输入"是编排、归关卡根（D49 口径）。
## 取走即消耗 —— 死亡重载与 R 重开都发生在同一个进程里，因此都不再演。
## F6 直跑关卡场景时这里整条不在场（`_world_root()` 返回 null），演不演都不问：摆图的人不该被这一拍挡路。
## 与 `_apply_run_state()` 同一条口径：能力由 `_world_root()` 那道闸认过，这里就直接 call，
## 不另补一遍 has_method —— 那条按名字读的契约由 verify_kit 的 METHODS 钉住。
func _maybe_intro() -> void:
	var root := _world_root()
	if root == null:
		return
	if not bool(root.call(&"take_intro")):
		return
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player != null:
		player.begin_wake()


## 回灌 run_state（D31）：存档点覆盖出生位；祭坛已耗则能力直接开启、祭坛摆成已耗的样子；
## 彩蛋清单（D54）里那几只一律摆成空座。
## 能力不重播「静止即启」的演出 —— 那是第一次踩祭坛的事，复活的人早就拥有它了。
func _apply_run_state() -> void:
	var root := _world_root()
	if root == null:
		return
	var state: Dictionary = root.call(&"get_run_state")
	if state.has("respawn_position"):
		_set_player_start(state["respawn_position"])
	# 身份跟着位置一起回灌（D51）：重载后亮的还是死前那一台，不是全灭、也不是全亮。
	# 路径解析不到（摆图时改了名或挪了层级）就当没这回事 —— 重生位本身仍然有效。
	if state.has("respawn_marker"):
		_set_active_checkpoint(get_node_or_null(state["respawn_marker"]))
	if state.get("altar_spent", false):
		TimeManager.set_ability_enabled(true)
		var altar: Node = _resolve(altar_path, &"ability_granted", "altar_path")
		if altar != null and altar.has_method(&"mark_spent"):
			altar.call(&"mark_spent")
	# 彩蛋（D54 裁定②）：拿过的复生不了。逐个路径按 `mark_taken()` 摆成空座，
	# 认不出这个方法的节点直接跳过 —— 名字撞车的非彩蛋节点不该被这条链碰到。
	for path: NodePath in state.get("collectibles_taken", []):
		var node: Node = get_node_or_null(path)
		if node != null and node.has_method(&"mark_taken"):
			node.call(&"mark_taken")


func _apply_camera_limits() -> void:
	if camera_limits.size == Vector2.ZERO:
		return
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	var camera: Camera2D = player.get_node_or_null("PlayerCamera")
	if camera == null:
		return
	camera.limit_left = int(camera_limits.position.x)
	camera.limit_top = int(camera_limits.position.y)
	camera.limit_right = int(camera_limits.position.x + camera_limits.size.x)
	camera.limit_bottom = int(camera_limits.position.y + camera_limits.size.y)


## 拿玩家的输入处理器：判断「玩家松手了没」要靠它。读 Player 暴露的属性而不是
## get_node("MovementInputHandler") —— 那个字符串曾经在三个关卡脚本里各写一遍。
func _grab_handler() -> void:
	var player: Player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	_handler = player.input_handler


## 祭坛只发 ability_granted，何时真正开能力属于关卡编排（D16），不归构件。
func _bind_altar() -> void:
	var altar: Node = _resolve(altar_path, &"ability_granted", "altar_path")
	if altar == null:
		return
	altar.connect(&"ability_granted", _on_altar_granted)


## 接在信号上的不是演出本身，而是「先记账、再开演」。拆两步是因为
## `_begin_ability_sequence` 是给子类覆写的钩子（引导关就在覆写）——
## 覆写时漏一句 super 就会把进度也一起漏掉，而记账不该依赖别人的自觉。
func _on_altar_granted() -> void:
	_mark_altar_spent()
	_begin_ability_sequence()


## 「祭坛已耗」与「能力已开」是两拍（D16 还要等松手），但记进 run_state 的只能是前者：
## 踩上祭坛那一刻石头就烧了，重载回来不该复生。能力开关由它推导，不另存一份（D31 订正）。
func _mark_altar_spent() -> void:
	var root := _world_root()
	if root == null:
		return
	var state: Dictionary = root.call(&"get_run_state")
	state["altar_spent"] = true


func _bind_goal() -> void:
	var goal: Node = _resolve(goal_path, &"body_entered", "goal_path")
	if goal == null:
		return
	goal.connect(&"body_entered", _on_goal_body_entered)


## 危险物、存档点与彩蛋收集物（D31 / D51 / D54）都不走 NodePath 接线：一关里它们是
## 「摆几个就有几个」的东西，逐个拖引用摆图时漏接一个就是静默不死 / 静默不记。
## 改按契约信号全子树扫描 —— 与 D28 的目标一致：摆进场景树即生效，摆图的人不需要知道这里有代码契约。
func _bind_hazards() -> void:
	for node: Node in _find_contract_nodes(&"touched_player"):
		node.connect(&"touched_player", _on_hazard_touched)


## 存档点还要 claim()/release()（D51）：只发信号、不认这两个方法的构件亮不起来也灭不下去，
## 会退化成「踩过几台亮几台、重载后集体复位」。这条在接线当刻就能判，所以当场响一次。
func _bind_checkpoints() -> void:
	for node: Node in _find_contract_nodes(&"checkpoint_reached"):
		if not node.has_method(&"claim") or not node.has_method(&"release"):
			push_warning("存档点 %s 发 checkpoint_reached 却没有 claim/release，本关会出现多台同亮"
				% node.name)
		node.connect(&"checkpoint_reached", _on_checkpoint_reached.bind(node))


## 彩蛋收集物（D54 裁定②）：契约与存档点同族，但**不要求 claim/release** ——
## "哪一只已被拿走"不存在全关卡唯一性，各记各的就对了，所以本构件只发信号 + `mark_taken()`。
func _bind_collectibles() -> void:
	for node: Node in _find_contract_nodes(&"collectible_taken"):
		node.connect(&"collectible_taken", _on_collectible_taken.bind(node))


func _find_contract_nodes(signal_name: StringName) -> Array[Node]:
	var found: Array[Node] = []
	_collect_contract_nodes(self, signal_name, found)
	return found


func _collect_contract_nodes(node: Node, signal_name: StringName, found: Array[Node]) -> void:
	for child in node.get_children():
		if child.has_signal(signal_name):
			found.append(child)
		_collect_contract_nodes(child, signal_name, found)


## 路径为空 / 指向不存在的节点 → 静默跳过（本关没有这个构件是合法配置）；
## 指到了但不发契约信号 → 一次性警告。与 Door.trigger 同一套口径。
func _resolve(path: NodePath, signal_name: StringName, label: String) -> Node:
	if path.is_empty():
		return null
	var target: Node = get_node_or_null(path)
	if target == null:
		return null
	if not target.has_signal(signal_name):
		push_warning("关卡 %s 的 %s（%s）不发 %s，这段编排不会生效"
			% [name, label, str(path), signal_name])
		return null
	return target


## D16：静止即启。第一次冻结因此必然是"我按了方向键"造成的，而不是能力生效的既成事实。
## 子类可以覆写它来挂自己的日志或演出（GDScript 方法默认虚调用）。
func _begin_ability_sequence() -> void:
	_awaiting_ability = true
	_ability_wait = 0.0


func _tick_ability(delta: float) -> void:
	if not _awaiting_ability or _handler == null:
		return
	_ability_wait += delta
	if _handler.is_moving and _ability_wait < ability_enable_timeout:
		return
	_awaiting_ability = false
	TimeManager.set_ability_enabled(true)
	# 子类可覆写以加日志/演出。默认什么都不做。
	_on_ability_enabled("timeout" if _handler.is_moving else "still", _ability_wait)


func _tick_goal(delta: float) -> void:
	if not _goal_reached or goal_restart_delay <= 0.0 or _handler == null:
		return
	# 松手之前不计时：0.08 s 缓冲后世界才流动，门才有空在身后关完。
	if _handler.is_moving:
		return
	_goal_wait += delta
	if _goal_wait < goal_restart_delay:
		return
	_goal_reached = false
	restart_level()


func _on_goal_body_entered(_body: Node2D) -> void:
	if _goal_reached:
		return
	_goal_reached = true


## 判死当帧不再换场景（D42）：把这一拍交给玩家去演，重载等 death_finished 来点名。
## 同一拍里第二根危险物再点一次名也被 `_dying` 挡下 —— 死亡不叠加，只演一遍。
func _on_hazard_touched(target: Node2D) -> void:
	if _dying or _death_pending:
		return
	var player: Player = target as Player
	if player == null:
		return
	_dying = true
	player.death_finished.connect(_on_death_finished, CONNECT_ONE_SHOT)
	player.die(death_time)


func _on_death_finished() -> void:
	_death_pending = true


## 存的是「玩家该在哪里重生」而不是存档点原点 —— Checkpoint 发来的已经是抬过
## 半个盒高的玩家位。写进常驻根的 run_state：关卡马上要整个换掉，进度不能住在里面。
## 亮灭排在记账之前：无常驻根（F6 直跑关卡场景）时进度确实没地方存，但「全关卡只一台
## 亮」这条视觉规则不该跟着失效 —— 它是玩家判断存没存的唯一依据。
func _on_checkpoint_reached(position: Vector2, source: Node) -> void:
	_set_active_checkpoint(source)
	var root := _world_root()
	if root == null:
		return
	var state: Dictionary = root.call(&"get_run_state")
	state["respawn_position"] = position
	state["respawn_marker"] = _relative_path(source)


## 唯一激活（D51）：新台点亮、上一台回 idle。同一台再踩直接返回 —— 重生时人正站在
## 自己那条带上，body_entered 会再点一次名，不该因此把同一台顶掉又装回来。
func _set_active_checkpoint(node: Node) -> void:
	if node == null or node == _active_checkpoint:
		return
	if is_instance_valid(_active_checkpoint) and _active_checkpoint.has_method(&"release"):
		_active_checkpoint.call(&"release")
	_active_checkpoint = node
	if node.has_method(&"claim"):
		node.call(&"claim")


## 身份存的是「相对本关卡根的 NodePath」而不是节点引用：关卡每死一次就整个换掉，
## 引用跟着旧实例一起没，路径却能在新的那份里指回同一台。相对而非绝对，是为了
## Main 那边把关卡挂在哪个容器下、叫什么名字都不影响这条链（父链走到本关卡根倒拼）。
func _relative_path(node: Node) -> NodePath:
	var names: Array = []
	var cursor: Node = node
	while cursor != null and cursor != self:
		names.push_front(cursor.name)
		cursor = cursor.get_parent()
	return NodePath("/".join(names))


## 记的是**身份**而不是位置：彩蛋不会挪动，"拿没拿过"就是这一个布尔，所以清单里存路径。
## 与钥匙卡刻意不同（D30 第 3 条：死了钥匙掉回去）—— 那是机制素材，死了重来正是解谜的一部分；
## 彩蛋是对"发现"的收据，死一次就复生等于把已经拆开的礼物重新包好（D54 裁定②）。
## 无常驻根（F6 直跑关卡场景）时不记，与存档点同一条分界：进度本来就没地方放。
func _on_collectible_taken(source: Node) -> void:
	var root := _world_root()
	if root == null:
		return
	var state: Dictionary = root.call(&"get_run_state")
	if not state.has("collectibles_taken"):
		var fresh: Array[NodePath] = []
		state["collectibles_taken"] = fresh
	var taken: Array = state["collectibles_taken"]
	var path := _relative_path(source)
	if path in taken:
		return
	# 就地 append：Array 是引用类型，写回的仍是 run_state 里那一份带类型的清单。
	taken.append(path)


## 常驻 World 根（main.tscn 的 Main，D31 的进度袋挂在它身上）。F6 直接跑关卡场景时
## 没有它 —— 这条不再只是"少个滤镜"的沙盒限制，见 _warn_no_world_root()。
func _world_root() -> Node:
	var root := get_tree().get_first_node_in_group(&"world_root")
	if root != null and root.has_method(&"get_run_state"):
		return root
	return null


## D31 的进度链整条住在常驻根上，F6 直跑时它不在场：存档点不记位置、死亡直接回出生点，
## 而且一声不吭。光看画面区分不出"存档点坏了"和"根本没走这条链"，所以开局响一次。
func _warn_no_world_root() -> void:
	if _world_root() != null:
		return
	push_warning("无常驻根（F6 直跑关卡场景？）：存档点与死亡回档不生效。要验这两条请用 F5，或把 Main.level_scene 指向本关")


## 钩子：能力真正开启的那一刻。默认什么都不做，留给子类打日志或放演出。
func _on_ability_enabled(_reason: String, _wait: float) -> void:
	pass


## 重开本关：沿父链找到 World 根（第一个有 restart_level 方法的祖先）委托它做。
## 刻意不写 `node is Main` —— main.gd 预加载了关卡，关卡脚本继承本类，
## 基类再引 Main 就成了类解析环；晚绑定一次调用的代价可以忽略。
func restart_level() -> void:
	var node: Node = get_parent()
	while node != null and not node.has_method(&"restart_level"):
		node = node.get_parent()
	if node != null:
		node.call(&"restart_level")


## 死亡重载：委托 World 根的 reload_level（保留 run_state 的那个入口）。
## 同一条父链晚绑定，理由同上。Main 缺席（F6 直跑关卡场景）时退回引擎自带的「重来当前
## 场景」：D42 之前这里静默不动无所谓 —— 死了本来就没画面；现在死了要先钉住世界演一拍，
## 不接住就是一具永久卡在那里的尸体。反正进度本来也不在，重来的语义对得上。
func _reload_level() -> void:
	var node: Node = get_parent()
	while node != null and not node.has_method(&"reload_level"):
		node = node.get_parent()
	if node != null:
		node.call(&"reload_level")
		return
	get_tree().reload_current_scene()
