@tool
class_name Spikes
extends HazardBase
## 尖刺（D34 选型 S3）：常开地形，咬人但不挡路 —— `blocks_when_live` 恒 false，
## 连导出项都不给（摆了没反应的旋钮比多一个零件糟，D34 第 1 条）。
##
## 节点原点 = 底边中心，与其他贴地构件同一约定。天花板倒刺 = 同一场景 rotation 180，
## 不另出零件（选型图就是这么画的）；碰撞盒跟着转，朝向不吃代码（D34 第 3 条）。
##
## 立绘 = spike_unit.png 16x16 无缝平铺（一格一颗大牙、牙高 14），任意 length 都对得齐。
## 判死盒只罩画出来的牙（14 px 高），不罩上面的空行 —— 「碰撞体 == 画出来的」到像素。
## @tool：改 length 立刻重画 + 重配判死盒。

## 尖刺带总长度（px）。16 的倍数最齐，别的值右缘裁余料。
@export var length: float = 48.0:
	set(value):
		length = value
		_rebuild()

const TEX_SPIKE: Texture2D = preload("res://assets/props/spike_unit.png")
## 判死盒高度 = 牙高（纹理里牙占第 2..15 行，顶上两行是空行不判死）。
const KILL_HEIGHT: float = 14.0

@onready var _collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	_rebuild()


## 只在值真的变了时才写，避免 @tool 每次装载场景都把编辑器标成「未保存修改」。
func _rebuild() -> void:
	if not is_node_ready():
		return
	var rect := _collision.shape as RectangleShape2D
	if rect == null or rect.size != Vector2(length, KILL_HEIGHT):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(length, KILL_HEIGHT)
		_collision.shape = shape
	var band := Vector2(0.0, -KILL_HEIGHT * 0.5)
	if _collision.position != band:
		_collision.position = band
	queue_redraw()


func _draw() -> void:
	TileDraw.tile(self, TEX_SPIKE, -length * 0.5, -KILL_HEIGHT - 2.0, length, KILL_HEIGHT + 2.0)
