@tool
class_name HazardBase
extends Area2D
## 危险物基类（D34/D38）：只拥有「接触即判」这条死亡规则，其余全归子类。
##
## 判定走每物理帧的 get_overlapping_bodies() 扫描，而不是 body_entered：
## entered 只在「进来那一刻」发，接不住「玩家先站进断电的棒、棒随后在他身体里通电」
## —— 那正是 D35 第 3 条的真惩罚场景。扫描本身不吃任何 delta，所以世界冻结期间
## 照样执行：冻在通相位的电仍然伤人（D38 第 2 条），这是整类谜题的支点。
##
## 碰撞层约定写在每个子类的 .tscn 里（layer = 0、mask = 2、monitorable = false）：
## 危险物绝不能上 sensor 层 —— 玩家的头顶净空查询会把一根通电的棒读成
## 「头顶是空的」（D29 与 D27 交叉核对那条硬约束）。要挡路的形态由子类自挂
## StaticBody2D 子节点上 time_solid 层，见 ElectricBar.Blocker。
##
## 判死不归这里：本类只发 touched_player，「死」由 LevelBase 接住，「怎么回」
## 由 Main 决定（D29 第 5 条）。构件不引用 Player 内部，Player 也不长 hp 字段。

signal touched_player(player: Node2D)

## 一次性闩锁：本条命内只发一次。真正的重置路径是关卡重载（D31），构件不提供 reset()。
var _fired: bool = false


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _fired or not is_live():
		return
	for body in get_overlapping_bodies():
		if body.is_in_group(&"player"):
			_fired = true
			touched_player.emit(body)
			return


## 此刻有没有杀伤。基类恒 true（尖刺永远咬人）；ElectricBar 用世界时钟覆写成周期通断。
## 放在基类是为了让上面的扫描对「常开」与「周期」两种危险物走同一条代码路径。
func is_live() -> bool:
	return true
