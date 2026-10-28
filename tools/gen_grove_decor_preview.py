#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
第二关（`d` / 树丛词汇）装饰候选件选型图 —— **D74 的选型收据**。

**现状**：这十件里已落盘八件（`tree` / `ivy_patch` / `vine_curtain` / `log` / `fern` /
`moss_side` / `scree` / `web_corner`，画法已搬进 `gen_tiles.py`）；砍掉两件 ——
`puddle`（`glass` 对墙 1.03，静止态就看不见）与 `leaf_litter`（与 `moss_edge` 抢同一条踏口带）。
所以本脚本现在跑起来会把那八件**再临时喂一遍**（同名同矩形，落盘的表被覆盖成同样的值），
图仍然与出货一致；它的作用是"当时为什么是这八件、那两件为什么没进"的收据。

为什么这张图必须由落盘那两条函数现画（D58 立的规矩）：
  图集 = tools/gen_tiles.py 的 build_decor_atlas()，候选件只是**临时喂进去**的几张画法，
         连「亮底先补描边再擦角」那一趟后处理都走的是同一段代码；
  房间 = 同一个 render_room()，所以图里的占格、层级、接缝与实机一致；
  冻结 = tools/gen_freeze_filter_preview.crt()，就是出货那段 fragment 的离线复现。
**卡片必须先拼成一整页 1280x720 跑一次 crt 再逐格裁**：扫描线与色散的周期是按屏幕像素定的。
本脚本**一个字都不改落盘产物**：产物只有 preview_grove_decor.png。

每行两格：左 = 静止（世界流动），右 = 冻结（按住方向键那一拍）。
控制台读数用 ASCII（cp936 会把中文列名糊掉），图上的标注才用中文。

用法：  py tools/gen_grove_decor_preview.py
产物：  assets/tiles/preview_grove_decor.png
"""
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                     # 落盘的画师
import gen_freeze_filter_preview as F     # 出货 shader 的同一条算式

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets/tiles", "preview_grove_decor.png")
CLIP_LINE = 255 / 1.3                     # 增益 1.3 的削顶线：任何通道过线都会在冻结时撞天花板

# ---------------------------------------------------------------- 候选画法
# 十件全进 no-round 名单：`d` 是 soft 套，整格矩形的后处理描边会把不规则剪影框成一块砖，
# 所以轮廓由画法自己画（与 moss_edge / mushroom / bones 同一档）。


def cand_tree(d, p, x, y):
    """树（48x80）。这套叫「树丛」却没有一棵树：现在最高的垂直件是 96 px 的垂藤，而它是贴墙的。
    树干走 metal（与木箱/木桶同族，说的是「木质」），冠走 grout/surface（与叶簇同族），
    果用 accent2 两粒 —— 一颗琥珀都不能沾（pickup 的专属色，D29 起玩家看见琥珀就伸手）。"""
    wood = p["metal"]
    lite, dark = G.lighter(wood, 0.4), G.darker(wood, 0.3)
    tx = x + 21
    for r in range(30, 80):
        flare = 2 if r >= 76 else (1 if r >= 72 else 0)
        d.rectangle([tx - flare, y + r, tx + 5 + flare, y + r], fill=wood)
        d.rectangle([tx - flare, y + r, tx - flare, y + r], fill=lite)
        d.rectangle([tx + 5 + flare, y + r, tx + 5 + flare, y + r], fill=dark)
    for r in (36, 45, 54, 63, 71):
        d.rectangle([x + 23, y + r, x + 23, y + r + 3], fill=dark)
    d.rectangle([x + 16, y + 40, x + 20, y + 41], fill=wood)
    d.rectangle([x + 27, y + 52, x + 31, y + 53], fill=dark)
    for cx, cy, rx, ry in ((24, 18, 22, 15), (11, 27, 11, 8), (36, 27, 11, 8)):
        G._ellipse(d, x + cx, y + cy, rx, ry, p["edge"])
        G._ellipse(d, x + cx, y + cy, rx - 1, ry - 1, p["grout"])
    for cx, cy, rx, ry in ((18, 14, 7, 5), (30, 20, 8, 4), (11, 26, 5, 3)):
        G._ellipse(d, x + cx, y + cy, rx, ry, p["surface"])
    for bx, by in ((15, 30), (33, 32)):
        d.rectangle([x + bx, y + by, x + bx, y + by], fill=p["accent2"])


def cand_ivy(d, p, x, y):
    """爬墙苔垫（48x32）。墙上现在只挂得出实验室件的换皮（巢箱/壁龛/裂缝/地衣），
    缺一块「墙自己活起来了」的面。
    第一版画成了三排等大等高的叶 —— 在实机比例下读成「墙上一排排插座」，所以这一版
    把节奏打散：叶大小 2~4 交替、每列另加一道正弦起伏、每隔一列省一片。
    顶边那道深色横条也删了，它读成一块搁板；改由几根须说明「它是从上面长下来的」。"""
    G._ellipse(d, x + 24, y + 17, 21, 13, G.rgba(p["grout"], 46))   # 半透明底：把散叶绑成"一块"
    for i in range(11):
        cx = x + 4 + i * 4
        d.rectangle([cx, y, cx, y + 1 + (i % 3)], fill=p["deep"])
    for row, cy in enumerate((11, 20, 26)):
        for i in range(5):
            if (row + i) % 5 == 3:
                continue                                  # 每隔一两列留个缺口，破掉网格
            G._leaf(d, p, x + 7 + i * 8 + (4 if row == 1 else 0),
                    y + cy + ((-2, 1, 0, 1, -1)[i % 5]), (3, 2, 3, 3, 2)[i % 5], 2)
    for hx in (12, 26, 39):
        d.rectangle([x + hx, y + 30, x + hx + 1, y + 30], fill=p["deep"])


def cand_vine_curtain(d, p, x, y):
    """藤帘（32x48）。垂藤（替 pipe_v 那件）是 96 高、能三段竖着接的「柱子」；
    这一件说的是另一头：短、三股、下沿不齐，挂在天花板上当视线遮挡。
    第一版每股只有 1 像素宽、叶每 8 行才一颗，实机比例下读成三条虚线；
    这一版股身 2 像素、每 5 行一簇四像素的叶，末端收口，整件的"占住这条带子"才说得出。"""
    stem, lite, dark = p["metal"], G.lighter(p["metal"], 0.4), G.darker(p["metal"], 0.3)
    d.rectangle([x, y, x + 31, y + 1], fill=dark)
    d.rectangle([x, y, x + 31, y], fill=stem)
    for sx, ln, side in ((4, 44, 1), (15, 48, -1), (25, 40, 1)):
        for r in range(2, ln):
            col = x + sx + G.VINE_W[(r // 4) % 8]
            d.rectangle([col, y + r, col + 1, y + r], fill=stem)
            d.rectangle([col, y + r, col, y + r], fill=lite if side > 0 else dark)
            if r % 5 == 3:
                for k, hh in enumerate((1, 2, 2, 1)):
                    for s in (1, -1):
                        lx = col + s * side * (2 + k)
                        if not (x <= lx < x + 32):
                            continue                      # 出格不报错、只会盖掉邻格（D70 那个坑）
                        d.rectangle([lx, y + r - hh, lx, y + r + hh], fill=p["grout"])
                if 0 <= col + side * 5 - x < 32:
                    d.rectangle([col + side * 5, y + r, col + side * 5, y + r], fill=p["surface"])
        d.rectangle([x + sx, y + ln - 1, x + sx + 1, y + ln - 1], fill=p["deep"])
    d.rectangle([x + 15, y + 30, x + 16, y + 30], fill=p["accent2"])


def cand_log(d, p, x, y):
    """倒木（64x32）。与横根（替 pipe_h）分得很开：那件说的是「贴墙的根」，这一件是
    落在地上的整根树干，左端带断面年轮，顶上趴一撮苔。
    第一版是一圈矩形描边 + 顶上竖着的苔簇，读成「带绿齿的木板」，所以这一版剪影走椭圆
    （两头收口），苔改成**贴着顶线趴下**的两像素。"""
    wood, lite, dark = p["metal"], G.lighter(p["metal"], 0.4), G.darker(p["metal"], 0.32)

    def hh(c):
        return int(round(13.0 * math.sqrt(max(0.0, 1.0 - ((c - 31.5) / 32.5) ** 2))))

    for c in range(64):
        h = hh(c)
        if h < 2:
            continue
        top, bot = y + 16 - h, y + 16 + h
        d.rectangle([x + c, top, x + c, bot], fill=wood)
        d.rectangle([x + c, top, x + c, top], fill=p["edge"])
        d.rectangle([x + c, bot, x + c, bot], fill=p["edge"])
        d.rectangle([x + c, top + 1, x + c, top + 1], fill=lite)
        d.rectangle([x + c, bot - 1, x + c, bot - 1], fill=dark)
        if c % 9 == 4:
            d.rectangle([x + c, top + 3, x + c, bot - 2], fill=dark)
    G._ellipse(d, x + 9, y + 16, 6, 8, p["edge"])
    G._ellipse(d, x + 9, y + 16, 5, 7, G.mix(wood, p["lip_shade"], 0.35))
    G._ellipse(d, x + 9, y + 16, 3, 4, p["edge"])
    G._ellipse(d, x + 9, y + 16, 2, 3, G.mix(wood, p["lip_shade"], 0.35))
    G._ellipse(d, x + 9, y + 16, 1, 1, p["deep"])
    for c in range(20, 58, 2):                             # 顶线上趴着的苔
        h = hh(c)
        top = y + 16 - h
        d.rectangle([x + c, top - 2, x + c + 1, top - 1], fill=p["grout"])
        d.rectangle([x + c, top - 2, x + c + 1, top - 2], fill=p["surface"])
    d.rectangle([x + 30, y + 2, x + 31, y + 3], fill=p["accent2"])


def cand_fern(d, p, x, y):
    """蕨（32x32）。叶簇说的是「落下的叶子」，这一件说的是「站着展开的羽叶」。
    第一版只长到半格高，读成半个篮子；这一版六片撑满 32 格高，卷尖留 surface。"""
    cx0, cy0 = x + 16, y + 31
    for ang in (-72, -44, -16, 16, 44, 72):
        a = math.radians(ang - 90)
        n = 24 - abs(ang) // 6                             # 越斜的片越短，才出不了这一格
        for t in range(1, n):
            fx = int(round(cx0 + math.cos(a) * t * 1.15))
            fy = int(round(cy0 + math.sin(a) * t * 1.15 + 0.012 * t * t))
            if not (x <= fx < x + 32 and y <= fy < y + 32):
                continue
            d.rectangle([fx, fy, fx, fy], fill=p["deep"])
            if t % 2 == 0 and t < n - 2:
                px, py = int(round(math.sin(a) * 2)), int(round(-math.cos(a) * 2))
                for s in (-1, 1):
                    nx, ny = fx + px * s, fy + py * s
                    if x <= nx < x + 32 and y <= ny < y + 32:
                        d.rectangle([nx, ny, nx, ny], fill=p["grout"])
            if t == n - 2:
                d.rectangle([fx - 1, fy, fx + 1, fy], fill=p["surface"])
    d.rectangle([cx0 - 1, y + 30, cx0 + 2, y + 31], fill=p["deep"])


def cand_moss_side(d, p, x, y):
    """崖面侧苔（16x32）。moss_edge 只管「踏口那一条」，坑壁/崖面现在还是赤裸的砖；
    这一件是它的竖直版：从贴着的那一侧往外长，厚度逐行抖（同一张 MOSS_W 表），
    外沿留一列 surface 当"毛边"，再垂几根须 —— 第一版只有一根光条，读成藤不是苔。"""
    for r in range(32):
        depth = 3 + G._moss_top(4, r)
        d.rectangle([x, y + r, x + depth, y + r], fill=p["grout"])
        d.rectangle([x + depth, y + r, x + depth, y + r], fill=p["surface"])
        if r % 3 == 1:
            d.rectangle([x + depth + 1, y + r, x + depth + 1, y + r],
                        fill=G.rgba(p["surface"], 150))
        if r % 7 == 3:
            d.rectangle([x, y + r, x + 1, y + r], fill=p["deep"])
    for r in (6, 15, 24):
        d.rectangle([x + 9, y + r, x + 9, y + r + 3], fill=G.rgba(p["deep"], 120))


def cand_leaf_litter(d, p, x, y):
    """碎叶带（32x16）。比叶簇薄一档：能长排铺在台面与踏口，把「一整条都铺满」降成
    「这儿落了一些」。第一版每片都带一道顶边，连起来读成一条虚线；这一版顶边只留叶尖
    一个像素，高度 2~5 交替，间隔也不等分。"""
    for cx, hh, w in ((2, 3, 5), (9, 2, 4), (14, 5, 6), (21, 3, 4), (26, 2, 4)):
        d.rectangle([x + cx, y + 15 - hh, x + cx + w, y + 15], fill=p["grout"])
        d.rectangle([x + cx + 1, y + 15 - hh, x + cx + w - 1, y + 16 - hh], fill=p["surface"])
        d.rectangle([x + cx + w, y + 15 - hh, x + cx + w, y + 15 - hh], fill=p["edge"])
        d.rectangle([x + cx, y + 15, x + cx + w, y + 15], fill=p["deep"])


def cand_scree(d, p, x, y):
    """碎石（16x16）。这套里石头的词汇只有大块（rock 替 cabinet_small），地面缺
    「小的、散落的」那一档。第一版用 lip_shade，对墙正好 1.00 = 只剩一圈描边；
    这一版石头走 mix(edge, bg, 0.35)（比墙暗一档的冷灰），左上角点 lip_shade 当受光。"""
    stone = G.mix(p["edge"], p["bg"], 0.35)
    for cx, cy, rx, ry in ((4, 11, 2, 2), (10, 13, 3, 1), (12, 8, 2, 2)):
        G._ellipse(d, x + cx, y + cy, rx + 1, ry + 1, p["edge"])
        G._ellipse(d, x + cx, y + cy, rx, ry, stone)
        d.rectangle([x + cx - 1, y + cy - ry + 1, x + cx, y + cy - ry + 1], fill=p["lip_shade"])
        d.rectangle([x + cx - rx, y + cy + ry + 1, x + cx + rx, y + cy + ry + 1],
                    fill=G.rgba(p["edge"], 80))
    d.rectangle([x + 1, y + 15, x + 2, y + 15], fill=p["deep"])


def cand_puddle(d, p, x, y):
    """积水（16x16）。这件是**故意放进来当对照的**：glass 对墙只有 1.03（全套最贴墙的一色），
    亮部又用 lip —— 也就是它在冻结那一拍最容易整块糊成白。选不选它，看这一格糊成什么样。"""
    G._ellipse(d, x + 8, y + 11, 7, 3, p["edge"])
    G._ellipse(d, x + 8, y + 11, 6, 2, p["glass"])
    d.rectangle([x + 4, y + 10, x + 9, y + 10], fill=p["lip"])
    d.rectangle([x + 11, y + 12, x + 13, y + 12], fill=G.lighter(p["glass"], 0.35))
    d.rectangle([x + 2, y + 14, x + 13, y + 14], fill=G.rgba(p["edge"], 90))


def cand_web(d, p, x, y):
    """墙角网（32x32）。「这里很久没人来」那句：crate/barrel 说的是「来过」，
    还缺「走了很久」。挂左上角，五根放射 + 三道弦，全走半透明 edge ——
    亮底上丝网是**暗**的，不是白的（用 lip 就是 1.03，等于没画）。"""
    ox, oy = x + 1, y + 1
    for rad in (9, 18, 28):
        for t in range(31):
            a = math.radians(6 + t * 2.7)
            px = int(round(ox + rad * math.cos(a)))
            py = int(round(oy + rad * 0.62 * math.sin(a) + rad * 0.30))
            if x <= px < x + 32 and y <= py < y + 32:
                d.rectangle([px, py, px, py], fill=G.rgba(p["edge"], 150))
    for ang in (8, 30, 52, 74, 96):
        a = math.radians(ang)
        for rad in range(2, 30):
            px = int(round(ox + rad * math.cos(a)))
            py = int(round(oy + rad * 0.62 * math.sin(a) + rad * 0.30))
            if x <= px < x + 32 and y <= py < y + 32:
                d.rectangle([px, py, px, py], fill=G.rgba(p["edge"], 70))
    d.rectangle([ox, oy, ox + 2, oy + 1], fill=p["edge"])


CANDIDATES = [
    ("tree", (0, 176, 48, 80), cand_tree,
     "这套叫「树丛」却没有树；最高的垂直件是贴墙的垂藤", "ground"),
    ("ivy_patch", (48, 176, 48, 32), cand_ivy,
     "墙上只挂得出实验室件的换皮，缺「墙自己活起来了」那一块面", "wall"),
    ("vine_curtain", (96, 176, 32, 48), cand_vine_curtain,
     "短、三股、下沿不齐：天花板遮挡（垂藤是柱子，这句不一样）", "ceiling"),
    ("log", (128, 176, 64, 32), cand_log,
     "落在地上的整根树干：断面年轮 + 顶上趴一撮苔", "ground"),
    ("fern", (192, 176, 32, 32), cand_fern,
     "站着展开的羽叶 —— 与「落下的叶子」是两种剪影", "ground"),
    ("scree", (224, 176, 16, 16), cand_scree,
     "石头只有大块，缺「小的、散落的」那一档", "ground"),
    ("puddle", (240, 176, 16, 16), cand_puddle,
     "对照件：glass 对墙 1.03，看它在冻结那一拍糊不糊", "ground"),
    ("moss_side", (48, 208, 16, 32), cand_moss_side,
     "moss_edge 的竖直版：坑壁与崖面现在还是赤裸的砖", "wall"),
    ("web_corner", (64, 208, 32, 32), cand_web,
     "crate 说的是「来过」，还缺「走了很久」那句", "ceiling"),
    ("leaf_litter", (96, 224, 32, 16), cand_leaf_litter,
     "比叶簇薄一档，能长排铺成「这儿落了一些」", "ground"),
]

# 演示房间里的摆法：(名字, x, y, 重复[, 轴向])，坐标全是 16 的倍数。
DEMO_LAYOUT = [
    ("tree", 112, 240, 1),
    ("tree", 192, 144, 1),
    ("log", 544, 288, 1),
    ("fern", 176, 288, 1),
    ("ivy_patch", 32, 48, 1),
    ("ivy_patch", 512, 48, 1),
    ("moss_side", 384, 336, 1),
    ("moss_side", 416, 320, 1),
    ("vine_curtain", 288, 16, 1),
    ("vine_curtain", 464, 16, 1),
    ("web_corner", 32, 16, 1),
    ("web_corner", 576, 16, 1),
    ("leaf_litter", 104, 304, 1),
    ("leaf_litter", 336, 304, 1),
    ("leaf_litter", 432, 304, 3, "h"),
    ("scree", 224, 304, 1),
    ("puddle", 128, 304, 1),
]

# 每件画法的主力调色板键（手工点出来，免得拿图像猜）：读数与一句说明。
BODY_KEYS = {
    "tree": (("metal", "grout", "surface"), "干 metal / 冠 grout+surface"),
    "ivy_patch": (("grout", "surface"), "叶 grout+surface"),
    "vine_curtain": (("metal", "grout"), "茎 metal / 叶 grout"),
    "log": (("metal", "grout"), "木 metal / 苔 grout"),
    "fern": (("deep", "grout"), "茎 deep / 羽叶 grout"),
    "scree": (("stone_mix",), "石 mix(edge,bg,.35)"),
    "puddle": (("glass", "lip"), "水 glass + 高光 lip"),
    "moss_side": (("grout", "surface"), "苔 grout + 尖 surface"),
    "web_corner": (("edge",), "半透明 edge"),
    "leaf_litter": (("grout", "surface"), "躺平的叶 grout+surface"),
}


def install():
    """把候选件临时接进落盘那两张表 —— 不改文件，只改这份进程里的模块状态。"""
    for name, rect, fn, _note, _anchor in CANDIDATES:
        G.DECOR_GROVE_EXTRA[name] = rect
        G.PAINTERS_GROVE[name] = lambda d, p, x, y, fn=fn: fn(d, p, x, y)
        G.DECOR_NO_ROUND_GROVE.add(name)
    G.DECOR_LAYOUT_GROVE.extend(DEMO_LAYOUT)


def occupancy(items):
    grid = [[0] * 16 for _ in range(16)]
    for _n, (rx, ry, rw, rh) in items.items():
        for cy in range(ry // 16, (ry + rh) // 16):
            for cx in range(rx // 16, (rx + rw) // 16):
                grid[cy][cx] = 1
    return sum(r.count(1) for r in grid)


def resolve(p, k):
    return G.mix(p["edge"], p["bg"], 0.35) if k == "stone_mix" else tuple(p[k][:3])


def bleed_pixels(name, fn, rect):
    """这一件有没有画到自己那一格外面去。D70 踩过的坑在这里会静默复发：
    图集摆重叠不报错，后画的那件把前一件盖掉，清单里还是两块。所以每张卡单独画一次量。"""
    rx, ry, rw, rh = rect
    solo = Image.new("RGBA", G.DECOR_SIZE, (0, 0, 0, 0))
    fn(ImageDraw.Draw(solo, "RGBA"), dict(G.STYLES["d"]), rx, ry)
    out = 0
    for yy in range(G.DECOR_SIZE[1]):
        for xx in range(G.DECOR_SIZE[0]):
            if solo.getpixel((xx, yy))[3] < 8:
                continue
            if not (rx <= xx < rx + rw and ry <= yy < ry + rh):
                out += 1
    return out


def tile_metrics(atlas, name, p):
    """这一件自身的读数：占格 / 描边信道 / 冻结前的过线像素比例 / 撞没撞语义色。"""
    rx, ry, rw, rh = G.decor_items(p)[name]
    tile = atlas.crop((rx, ry, rx + rw, ry + rh)).convert("RGBA")
    opaque = over = amber = cyan = edge_px = 0
    for yy in range(rh):
        for xx in range(rw):
            r, g, b, a = tile.getpixel((xx, yy))
            if a < 8:
                continue
            opaque += 1
            if max(r, g, b) >= CLIP_LINE:
                over += 1
            if (r, g, b) == tuple(G.PICKUP_AMBER):
                amber += 1
            if (r, g, b) == tuple(p["accent"][:3]):
                cyan += 1
            if (r, g, b) == tuple(p["edge"][:3]):
                edge_px += 1
    keys = BODY_KEYS[name][0]
    body_cr = min(G._cr(resolve(p, k), p["bg"][:3]) for k in keys)
    floor_cr = min(G._cr(resolve(p, k), p["surface"][:3]) for k in keys)
    return dict(cells=(rw // 16) * (rh // 16), opaque=opaque, edge=edge_px,
                over=100.0 * over / max(opaque, 1), amber=amber, cyan=cyan,
                body_cr=body_cr, floor_cr=floor_cr)


def _tiles(img, zoom):
    """把一张 16px 瓦片的图集放大成瓦片卡。NEAREST：晶格必须等大，不许插值糊边。"""
    out = Image.new("RGB", (img.width * zoom, img.height * zoom), img.getpixel((0, 0)))
    out.paste(img, (0, 0))
    return out.resize((img.width * zoom, img.height * zoom), Image.NEAREST)


def card_image(name, atlas, p, anchor, zoom=2):
    """一件东西回到它该在的背景里：墙贴面 + 一条地形，按锚法摆。
    zoom=2 是**游戏里的屏幕比例**（PlayerCamera.zoom=2 ⇒ 1 世界像素 = 2 屏幕像素）。"""
    rx, ry, rw, rh = G.decor_items(p)[name]
    tile = atlas.crop((rx, ry, rx + rw, ry + rh)).resize((rw * zoom, rh * zoom),
                                                         Image.NEAREST)   # 留 alpha
    wall_tile = _tiles(atlas.crop((0, 0, 16, 16)).convert("RGB"), zoom)
    solid_tile = _tiles(G.build_terrain_atlas(p).crop((48, 48, 64, 64)).convert("RGB"), zoom)
    cw = 96 * zoom
    img = Image.new("RGB", (cw, cw), p["bg"][:3])
    for cy in range(0, cw, 16 * zoom):
        for cx in range(0, cw, 16 * zoom):
            img.paste(wall_tile, (cx, cy))
    band_h = cw - 16 * zoom if anchor == "ground" else 16 * zoom
    if anchor != "wall":
        for cx in range(0, cw, 16 * zoom):
            img.paste(solid_tile, (cx, band_h))
    y = (cw - (rh + 16) * zoom) if anchor == "ground" else (16 * zoom if anchor == "ceiling"
           else cw // 2 - rh * zoom // 2)
    img.paste(tile, (cw // 2 - rw * zoom // 2, y), tile)
    return img


def cards_both(atlas, p):
    """十张卡拼成一整页 1280x720，静止/冻结**同源一次算完**再逐格裁回来。
    必须在整页上跑 F.crt：扫描线与色散的周期是按屏幕像素定的（720/180 = 4 px、
    色散 0.001×1280 = 1.28 px），在小图上跑会得到另一套周期，图就成了谎话。"""
    gap = 30
    cell = 96 * 2
    page = Image.new("RGB", (F.W, F.H), (12, 12, 16))
    pos = {}
    for i, (name, _r, _f, _s, anchor) in enumerate(CANDIDATES):
        col, row = i % 5, i // 5
        x, y = gap + col * (cell + gap), gap + row * (cell + gap)
        page.paste(card_image(name, atlas, p, anchor), (x, y))
        pos[name] = (x, y)
    frozen = F.crt(page, linear_fac=1.3, scan_fac=0.10)
    return {n: (page.crop((x, y, x + cell, y + cell)),
                frozen.crop((x, y, x + cell, y + cell))) for n, (x, y) in pos.items()}


def room_pair(img):
    stat = img.convert("RGB").resize((F.W, F.H), Image.NEAREST)
    return stat, F.crt(stat, linear_fac=1.3, scan_fac=0.10)


def atlas_map(atlas):
    """图集实拍：已落盘那 21 件灰框、这 10 件红框 —— 回答「还塞得下吗」。"""
    z = 2
    aw, ah = G.DECOR_SIZE
    sheet = Image.new("RGB", (aw * z, ah * z + 28), (16, 16, 20))
    sheet.paste(atlas.resize((aw * z, ah * z), Image.NEAREST), (0, 28))
    d = ImageDraw.Draw(sheet)
    for items, hot in ((G.DECOR, False), ({n: r for n, r, _f, _s, _a in CANDIDATES}, True)):
        for _n, (rx, ry, rw, rh) in items.items():
            d.rectangle([rx * z, 28 + ry * z, (rx + rw) * z - 1, 28 + (ry + rh) * z - 1],
                        outline=(226, 62, 62) if hot else (120, 128, 150))
    d.text((4, 8), "atlas 256x256  |  RED = the 10 candidates, grey = the 21 already shipped",
           fill=(232, 236, 248), font=G._font(13))
    return sheet


def main():
    p = dict(G.STYLES["d"])
    cells_before = occupancy(G.decor_items(p))
    stat0, frozen0 = room_pair(G.render_room(p, ROOT))     # 现状，同一个渲染器

    install()
    G.check_decor_rects("d")        # 落盘前那三条：16 对齐 / 不出界 / 两两不重叠
    cells_after = occupancy(G.decor_items(p))
    atlas = G.build_decor_atlas(p)
    stat1, frozen1 = room_pair(G.render_room(p, ROOT))     # 加入之后

    print("atlas cells: shipped=%d  with_candidates=%d  free_left=%d  (of 256)" % (
        cells_before, cells_after, 256 - cells_after))
    print("\nname           size    cells  opaque  body/wall  body/floor  edge_px  "
          "over_clip%  amber  cyan  bleed_px")
    rows = []
    for name, rect, fn, note, anchor in CANDIDATES:
        m = tile_metrics(atlas, name, p)
        m["bleed"] = bleed_pixels(name, fn, rect)
        rows.append((name, rect, note, anchor, m))
        print("%-14s %6s %7d %6d %10.2f %11.2f %8d %10.1f %6d %5d %8d" % (
            name, "%dx%d" % (rect[2], rect[3]), m["cells"], m["opaque"],
            m["body_cr"], m["floor_cr"], m["edge"], m["over"], m["amber"], m["cyan"],
            m["bleed"]))
    bled = [n for n, _r, _s, _a, m in rows if m["bleed"]]
    print("bleed check: %s" % ("CLEAN（没有一件画到自己那一格外）" if not bled
                               else "OUT OF CELL -> " + ", ".join(bled)))

    LW = 380
    RW, RH = 640, 360
    CW = CH = 192                                          # 1 世界像素 = 2 屏幕像素，与实机同比例
    W = LW + 2 * (RW + 20)
    H = 120 + 2 * (RH + 78) + len(rows) * (CH + 96) + 600
    cells = cards_both(atlas, p)
    sheet = Image.new("RGB", (W, H), (12, 12, 16))
    d = ImageDraw.Draw(sheet)
    d.text((20, 22), "第二关装饰候选 · 全部由落盘那两条函数现画（build_decor_atlas + render_room）",
           fill=(232, 236, 248), font=G._font(30))
    d.text((20, 62), "右格 = 冻结那一拍，用出货同一条算式（linear_fac 1.3 / scan 0.10 / 色散）· "
                     "本图不改任何产物，候选只活在这份脚本里",
           fill=(178, 186, 206), font=G._font(18))

    y0 = 120
    for label, stat, frozen in (("现状（21 件）", stat0, frozen0),
                                ("加入这 10 件之后", stat1, frozen1)):
        d.text((20, y0 + 6), label, fill=(236, 240, 252), font=G._font(24))
        d.text((20, y0 + 38), "整间演示房 · 1280x720（render_room 现拼）",
               fill=(150, 196, 236), font=G._font(17))
        for j, img in enumerate((stat, frozen)):
            cell = img.resize((RW, RH), Image.BOX)
            x = LW + 10 + j * (RW + 20)
            sheet.paste(cell, (x, y0))
            d.rectangle([x, y0, x + RW, y0 + RH], outline=(70, 78, 100))
            d.text((x + 8, y0 + 4), "静止（世界流动）" if j == 0 else "冻结（按住方向键那一拍）",
                   fill=(240, 244, 255), font=G._font(16))
        y0 += RH + 78

    for name, rect, note, anchor, m in rows:
        big, froz = cells[name]
        d.rectangle([0, y0 - 8, W - 1, y0 + CH + 84], outline=(52, 58, 76))
        d.text((20, y0 + 4), "%s  %dx%d px（占 %d 格）" % (name, rect[2], rect[3], m["cells"]),
               fill=(236, 240, 252), font=G._font(21))
        d.text((20, y0 + 32), note, fill=(186, 196, 220), font=G._font(16))
        d.text((20, y0 + 56), "主体 %s · 对墙 %.2f · 对地 %.2f · 描边 %d px" % (
            BODY_KEYS[name][1], m["body_cr"], m["floor_cr"], m["edge"]),
            fill=(228, 196, 120), font=G._font(16))
        d.text((20, y0 + 78), "冻结前已过削顶线 196 的像素 %.1f%% · 琥珀 %d px · 青 %d px" % (
            m["over"], m["amber"], m["cyan"]), fill=(150, 214, 176), font=G._font(16))
        for j, img in enumerate((big, froz)):
            cell = img.resize((CW, CH), Image.BOX)
            x = LW + 10 + j * (CW + 20)
            sheet.paste(cell, (x, y0))
            d.rectangle([x, y0, x + CW, y0 + CH], outline=(70, 78, 100))
        y0 += CH + 96

    sheet.paste(atlas_map(atlas), (LW + 10, y0 + 10))
    d.text((20, y0 + 16), "图集余量", fill=(236, 240, 252), font=G._font(22))
    d.text((20, y0 + 46), "256x256 = 256 格：已落盘 21 件占 %d 格，这 10 件占 %d 格，还剩 %d 格"
           % (cells_before, cells_after - cells_before, 256 - cells_after),
           fill=(186, 196, 220), font=G._font(16))
    d.text((20, y0 + 70), "候选全摆在 y>=176 那片空区：与 g 共用的 14 件矩形一格不挪，",
           fill=(150, 196, 236), font=G._font(16))
    d.text((20, y0 + 92), "所以「g 的 Decor 层整层复制过来」这条仍然成立（tileset_selftest 钉着它）",
           fill=(150, 196, 236), font=G._font(16))

    sheet.save(OUT)
    print("\nsaved", OUT, sheet.size)


if __name__ == "__main__":
    main()
