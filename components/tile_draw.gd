class_name TileDraw
extends RefCounted
## 无缝平铺零件的公共画法：横向纵向都按零件自身周期平铺，右缘底缘裁余料，
## 所以导出项不保证是 16 的倍数也对得齐 —— D25 给门/按钮立的「零件必须自洽」规矩。
##
## 门与按钮各自留了私有的 `_tile`（守门已覆盖它们，迁移是纯噪音）；
## Spikes / ElectricBar / KeyDoor 三处要用时抽的这份公共版，调用方是 `TileDraw.tile(self, ...)`。


static func tile(canvas: CanvasItem, tex: Texture2D, x: float, y: float, w: float, h: float) -> void:
	var cw: float = tex.get_width()
	var ch: float = tex.get_height()
	var cx: float = x
	while cx < x + w - 0.001:
		var tw: float = minf(cw, x + w - cx)
		var cy: float = y
		while cy < y + h - 0.001:
			var th: float = minf(ch, y + h - cy)
			canvas.draw_texture_rect_region(tex, Rect2(cx, cy, tw, th), Rect2(0.0, 0.0, tw, th))
			cy += th
		cx += tw
