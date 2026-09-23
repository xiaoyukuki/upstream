"""门 / 按钮 / M5 构件（尖刺、电棒、钥匙、存档点）的立绘零件 —— 选型出图，定稿后 `--emit` 落资产。

用法：py tools/gen_props.py            只出选型图 assets/props/preview_props.png
      py tools/gen_props.py --emit     落 16 张零件 PNG + assets/props/props.json
                                       （门/按钮 8 张走 ab，M5 的尖刺/电棒/钥匙/终端 8 张走实装风格 g；
                                        构件 preload 的就是这些文件，改名要一起改）
      py tools/gen_props.py --m5       出 M5（危险物 / 钥匙 / 存档点）选型图
                                       assets/props/preview_m5.png。底图走**实装风格 g**。
                                       定稿的那几件已由 --emit 落盘（见 make_m5_parts）。
      py tools/gen_props.py --m5final  出 M5 定稿图 assets/props/preview_m5_shipped.png
      py tools/gen_props.py --m5door   出 D36 刷卡门对照图（卷帘 vs 光幕）
                                       assets/props/preview_keydoor.png

为什么立绘是「小零件 + 代码平铺」而不是一整张图：
  门扇的可见高度 = height * (1 - 开度)，逐帧在变；width / height / 按钮 width 都是导出项，
  摆图的人会改。整张纹理要么拉伸变形要么尺寸写死，都不行。所以立绘拆成能无缝平铺的
  小零件（卷帘板 16x8、底边警示条 16x8、门柱 4x16、门楣 16x12、按钮面/座 16x8、端帽 4x12），
  构件里用 _draw() 按当前尺寸平铺 —— 和瓦片同一套「零件必须自洽于 16px 周期」的规矩。

选型两组候选，用户已定 **M2 深钢卷帘 + B1 琥珀面板**（门楣青状态灯亮=开、按钮踩下时面板
沉进凹槽、前唇青灯亮）：明度上和白墙、钢地都拉开（M3 去饱和后靠明度仍然读得出来），
琥珀归「机器/危险」一家、青归「灯/玻璃」一家，和 D24 的点缀色分工一致。

**调色板钉在 `G.STYLES["ab"]`，而地图在 D26 之后实装的是暗底 `g`。** 这是知道的偏差、不是漏改：
门板对暗墙 1.39、按钮钢座 1.19，数字给过用户，判定「画风已融合，不用修改」。要换皮改
`STYLES["ab"]` 那两处即可，但 props.json 里 `door_body` / `button_face` 是**指向调色板的别名**
（字符串），另外四个灯色才是落盘的字面色 —— 拿别名当 RGB 三元组会 TypeError。
改完跑 `verify_kit`，它比对 json 与构件常量的同源关系。
"""

import math
import os
from PIL import Image, ImageDraw, ImageFont

import gen_tiles as G

TILE = G.TILE
ZOOM = 2

# 候选用的主体色（都取自 AB 调色板，不新发明颜色）
DOOR_BODIES = {
    "M1": None,   # 占位，main 里填 p["surface"]
    "M2": None,   # 填 p["deep"]
}


def _font(size):
    return G._font(size)


# ---------------------------------------------------------------- 零件画法
# 每个零件都画在「自己的周期」里：横向零件的图案周期整除 16，纵向的整除 16，
# 平铺时缝、铆钉、斜条都对得上。

def part_door_slat(p, body):
    img = Image.new("RGBA", (16, 8), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 15, 7], fill=body)
    d.rectangle([0, 0, 15, 0], fill=G.lighter(body, 0.20))
    d.rectangle([0, 1, 15, 1], fill=G.lighter(body, 0.07))
    d.rectangle([0, 3, 15, 3], fill=G.darker(body, 0.04))
    d.rectangle([0, 6, 15, 6], fill=G.darker(body, 0.22))
    d.rectangle([0, 7, 15, 7], fill=G.darker(body, 0.42))
    for rx in (2, 13):                                  # 铆钉：周期 16，平铺不跳
        d.rectangle([rx, 4, rx, 4], fill=G.darker(body, 0.38))
        d.rectangle([rx, 5, rx, 5], fill=G.lighter(body, 0.30))
    return img


def part_door_bottom(p):
    img = Image.new("RGBA", (16, 8), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    a = p["accent2"]
    d.rectangle([0, 0, 15, 7], fill=a)
    for py in range(8):                                 # 45 度斜条，周期 8，平铺连续
        for px in range(16):
            if ((px + py) // 4) % 2 == 0:
                d.rectangle([px, py, px, py], fill=G.darker(a, 0.55))
    d.rectangle([0, 0, 15, 0], fill=G.lighter(a, 0.40))
    d.rectangle([0, 7, 15, 7], fill=p["edge"])
    return img


def part_door_jamb(p, body):
    img = Image.new("RGBA", (4, 16), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 0, 15], fill=G.darker(body, 0.38))
    d.rectangle([1, 0, 1, 15], fill=G.lighter(body, 0.25))
    d.rectangle([2, 0, 2, 15], fill=body)
    d.rectangle([3, 0, 3, 15], fill=G.darker(body, 0.20))
    d.rectangle([1, 7, 2, 8], fill=G.darker(body, 0.45))   # 螺栓：周期 16
    return img


def part_door_header(p, body):
    img = Image.new("RGBA", (16, 12), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 15, 11], fill=body)
    d.rectangle([0, 0, 15, 1], fill=G.lighter(body, 0.30))
    d.rectangle([0, 2, 15, 2], fill=G.darker(body, 0.25))
    for vx in (3, 10):                                  # 散热槽：周期 16 内两处
        d.rectangle([vx, 5, vx + 1, 8], fill=G.darker(body, 0.50))
    d.rectangle([0, 10, 15, 11], fill=G.darker(body, 0.35))
    return img


def part_door_header_cap(p, body, right):
    img = Image.new("RGBA", (4, 12), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 3, 11], fill=body)
    d.rectangle([0, 0, 3, 1], fill=G.lighter(body, 0.30))
    col = 3 if right else 0
    d.rectangle([col, 0, col, 11], fill=G.darker(body, 0.45))
    d.rectangle([0, 10, 3, 11], fill=G.darker(body, 0.35))
    return img


def part_button_top(p, face):
    img = Image.new("RGBA", (16, 8), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 15, 7], fill=face)
    d.rectangle([0, 0, 15, 0], fill=G.lighter(face, 0.45))
    d.rectangle([0, 1, 15, 2], fill=G.lighter(face, 0.14))
    d.rectangle([0, 4, 15, 4], fill=G.darker(face, 0.07))
    d.rectangle([0, 6, 15, 6], fill=G.darker(face, 0.28))
    d.rectangle([0, 7, 15, 7], fill=G.darker(face, 0.48))
    for rx in (2, 13):
        d.rectangle([rx, 3, rx, 3], fill=G.darker(face, 0.40))
    return img


def part_button_base(p, body):
    """前唇（行 0-2）+ 凹槽内壁（行 3-7）。paint_button 分两遍画：
    凹槽在面板后、前唇在面板前，踩下时面板就「沉进」座里而不是把座盖掉。"""
    img = Image.new("RGBA", (16, 8), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, 15, 2], fill=body)
    d.rectangle([0, 0, 15, 0], fill=G.lighter(body, 0.25))
    d.rectangle([0, 2, 15, 2], fill=G.darker(body, 0.40))
    d.rectangle([0, 3, 15, 6], fill=G.darker(body, 0.55))
    d.rectangle([0, 7, 15, 7], fill=G.darker(body, 0.70))
    return img


# ---------------------------------------------------------------- 平铺小工具

def tile_h(img, unit, cap_l, cap_r, x, y, w):
    img.paste(cap_l, (x, y))
    cx = x + cap_l.width
    end = x + w - cap_r.width
    while cx < end:
        take = min(unit.width, end - cx)
        img.paste(unit.crop((0, 0, take, unit.height)), (cx, y))
        cx += take
    img.paste(cap_r, (end, y))


def tile_h_plain(img, unit, x, y, w):
    """无端帽的横向平铺，右缘按余宽裁切。按钮这类「两端影由实例画」的零件用它。"""
    cx = x
    while cx < x + w:
        take = min(unit.width, x + w - cx)
        img.paste(unit.crop((0, 0, take, unit.height)), (cx, y))
        cx += take


def tile_v(img, unit, x, y, h):
    cy = y
    while cy + unit.height <= y + h:
        img.paste(unit, (x, cy))
        cy += unit.height
    rest = y + h - cy
    if rest > 0:
        img.paste(unit.crop((0, 0, unit.width, rest)), (x, cy))


def tile_h_clip(img, unit, x, y, w, h):
    """横向平铺、纵向只露 h 像素（卷帘被门楣吃掉一截时用）。"""
    cx = x
    while cx < x + w:
        cw = min(unit.width, x + w - cx)
        cy = y
        while cy < y + h:
            ch = min(unit.height, y + h - cy)
            img.paste(unit.crop((0, 0, cw, ch)), (cx, cy))
            cy += ch
        cx += cw


# ---------------------------------------------------------------- 构件立绘

def paint_door(img, p, parts, cx, floor_y, progress, open_led):
    w, h = 32, 96
    x0 = cx - w // 2
    top = floor_y - h
    tile_v(img, parts["jamb"], x0 - 4, top - 12, h + 12)
    tile_v(img, parts["jamb"], x0 + w, top - 12, h + 12)
    tile_h(img, parts["header"], parts["header_l"], parts["header_r"], x0 - 4, top - 12, w + 8)
    d = ImageDraw.Draw(img, "RGBA")
    led = (x0 + w // 2 - 1, top - 7)
    d.rectangle([led[0] - 1, led[1] - 1, led[0] + 2, led[1] + 2], fill=G.darker(p["screen"], 0.2))
    if open_led:
        d.rectangle([led[0], led[1], led[0] + 1, led[1] + 1], fill=G.mix(p["accent"], (255, 255, 255), 0.5))
    vis = int(round(h * (1.0 - progress)))
    if vis <= 0:
        return
    if vis > 8:
        tile_h_clip(img, parts["slat"], x0, top, w, vis - 8)
    band = min(8, vis)
    tile_h_clip(img, parts["bottom"], x0, top + vis - band, w, band)


def paint_button(img, p, parts, cx, floor_y, pressed):
    w = 64
    x0 = cx - w // 2
    depth = 8 if pressed else 0
    top_y = floor_y - 16 + depth
    tile_h_plain(img, parts["base_well"], x0, floor_y - 5, w)
    tile_h_plain(img, parts["top"], x0, top_y, w)
    tile_h_plain(img, parts["base_lip"], x0, floor_y - 8, w)
    d = ImageDraw.Draw(img, "RGBA")
    end = G.darker(p["metal"], 0.45)
    d.rectangle([x0, top_y, x0, floor_y - 1], fill=end)
    d.rectangle([x0 + w - 1, top_y, x0 + w - 1, floor_y - 1], fill=end)
    d.rectangle([cx - 1, floor_y - 8, cx, floor_y - 7], fill=p["screen"])
    if pressed:
        d.rectangle([cx - 1, floor_y - 8, cx, floor_y - 7], fill=G.mix(p["accent"], (255, 255, 255), 0.5))


def make_parts(p, body, face):
    base = part_button_base(p, p["metal"])
    return {
        "slat": part_door_slat(p, body),
        "bottom": part_door_bottom(p),
        "jamb": part_door_jamb(p, body),
        "header": part_door_header(p, body),
        "header_l": part_door_header_cap(p, body, False),
        "header_r": part_door_header_cap(p, body, True),
        "top": part_button_top(p, face),
        "base": base,
        "base_lip": base.crop((0, 0, 16, 3)),
        "base_well": base.crop((0, 3, 16, 8)),
    }


# ---------------------------------------------------------------- 预览图

def context_strip(p, terrain, decor, w, h, floor_y):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    wf = G.decor_tile(decor, "wall_fill")
    for cy in range(0, h, TILE):
        for cx in range(0, w, TILE):
            img.paste(wf, (cx, cy))
    body = terrain.crop((2 * TILE, 3 * TILE, 3 * TILE, 4 * TILE))     # mask 14：上开
    inner = terrain.crop((3 * TILE, 3 * TILE, 4 * TILE, 4 * TILE))    # mask 15：四邻全在
    for cx in range(0, w, TILE):
        img.paste(body, (cx, floor_y))
        for cy in range(floor_y + TILE, h, TILE):
            img.paste(inner, (cx, cy))
    return img


def door_row(p, terrain, decor, root):
    w, h, floor_y = 248, 140, 124
    strips = []
    for key, body in (("M1  mid-steel shutter", p["surface"]), ("M2  dark-steel shutter", p["deep"])):
        img = context_strip(p, terrain, decor, w, h, floor_y)
        parts = make_parts(p, body, p["accent2"])
        paint_door(img, p, parts, 48, floor_y, 0.0, False)
        paint_door(img, p, parts, 128, floor_y, 0.5, False)
        paint_door(img, p, parts, 208, floor_y, 1.0, True)
        G.paste_slime(img, "idle", 2, 88, floor_y, False, 1, root)
        strips.append((img, key + "   closed / half / open (led lit = open)"))
    return strips


def button_row(p, terrain, decor, root):
    w, h, floor_y = 248, 72, 56
    strips = []
    for key, face in (("B1  amber face", p["accent2"]), ("B2  cyan face", p["accent"])):
        img = context_strip(p, terrain, decor, w, h, floor_y)
        parts = make_parts(p, p["deep"], face)
        paint_button(img, p, parts, 64, floor_y, False)
        paint_button(img, p, parts, 176, floor_y, True)
        G.paste_slime(img, "idle", 2, 176, floor_y - 8, False, 1, root)
        strips.append((img, key + "   idle / pressed (slime stands on it)"))
    return strips


def parts_row(p):
    parts = make_parts(p, p["deep"], p["accent2"])
    order = ["slat", "bottom", "jamb", "header", "top", "base"]
    sc = 6
    pad = 12
    widths = [parts[k].width * sc + 26 for k in order]
    w = pad * 2 + sum(widths)
    h = pad * 2 + 12 * sc + 16
    img = Image.new("RGB", (w, h), (196, 203, 213))
    d = ImageDraw.Draw(img)
    cx = pad
    for k in order:
        u = parts[k]
        up = u.resize((u.width * sc, u.height * sc), Image.NEAREST)
        bg = Image.new("RGB", up.size)
        bc = ImageDraw.Draw(bg)
        for yy in range(0, up.size[1], 8):
            for xx in range(0, up.size[0], 8):
                bc.rectangle([xx, yy, xx + 7, yy + 7],
                             fill=(206, 211, 218) if (xx + yy) // 8 % 2 else (238, 241, 245))
        bg.paste(up, (0, 0), up)
        img.paste(bg, (cx, pad))
        d.text((cx, pad + up.size[1] + 3), "%s %dx%d" % (k, u.width, u.height),
               fill=(24, 28, 34), font=_font(12))
        cx += u.width * sc + 26
    return img


# ---------------------------------------------------------------- M5 选型（危险物 / 钥匙 / 存档点）
# 这一节**只出图**：零件不落 PART_FILES、不走 --emit，等肉眼定完型再落盘。
#
# 看图前先记这条色彩分工（D29 / D30 的结论）：
#   亮白钢 = 会咬人的固体（尖刺）    青 = 光与电（电流棒、存档点激活态）
#   琥珀   = 可拾取物（钥匙）        钢灰 = 未激活的静物
# 底图一律用**实装风格 g** 的真图集而不是 ab —— 新零件在夜光墙上读不出来就白画。
# 门那件仍按 D25 的既有事实用 ab 调色板画，好让"新旧混着看"这件事在图上了结。

def _rim(img, p):
    """贴纸语言：非平铺件补一圈朝外的描边（D26 第 1 条）。"""
    return G.add_rim(img, p["edge"]) if p.get("soft") else img


def part_spikes(p, teeth=4, height=10):
    """16x16 一格、周期 16 平铺连续的尖刺单元。牙尖最亮、根部收暗，牙才读得出是长在地上。"""
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    step = 16 // teeth
    top = 16 - height
    span = max(1, step // 2 - 1)
    for i in range(teeth):
        ax = i * step + step // 2
        for r in range(height):
            y = top + r
            hw = int(round(span * (r / max(1, height - 1))))
            if r < 2:
                body = G.lighter(p["lip"], 0.12)
            elif r >= height - 3:
                body = G.darker(p["metal"], 0.16)
            else:
                body = p["lip"]
            d.rectangle([ax - hw, y, ax + hw, y], fill=body)
            if hw > 0:                                  # 左上受光、右侧投影
                d.rectangle([ax - hw, y, ax - hw, y], fill=G.lighter(body, 0.34))
                d.rectangle([ax + hw, y, ax + hw, y], fill=G.darker(body, 0.30))
    return _rim(img, p)


def part_pole(p, right):
    """极柱 10x18：外圈一圈 lip 亮边、里面才是钢。right = 光束在这一柱的右侧。

    为什么描边是亮的：g 的 edge 比墙还暗两档，拿它描边等于不描（实测极柱对墙 2.13、
    对地 1.25，落进暗关直接隐形）。D26 给主角解决同一个问题用的就是补亮边，这里照抄。
    """
    img = Image.new("RGBA", (10, 18), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 9, 17], fill=p["lip"])
    d.rectangle([1, 1, 8, 16], fill=p["deep"])
    d.rectangle([1, 1, 8, 1], fill=G.lighter(p["metal"], 0.10))
    d.rectangle([1, 1, 1, 16], fill=G.lighter(p["deep"], 0.22))
    d.rectangle([8, 1, 8, 16], fill=G.darker(p["deep"], 0.40))
    col = 7 if right else 2
    other = col + (1 if right else -1)
    d.rectangle([col, 5, col, 12], fill=p["accent"])
    d.rectangle([other, 6, other, 11], fill=G.lighter(p["accent"], 0.60))
    d.rectangle([4, 13, 6, 14], fill=G.darker(p["deep"], 0.55))   # 检修窗，相位记号
    return img


def paint_beam(img, p, x0, y, w, thick, live):
    """两极柱之间的电。通 = 描边朝外的三段弧 + 一点 alpha 光晕；断 = 只留一条虚线预告位置。
    折线周期 16，与瓦片同一套自洽规矩；光晕走 alpha 叠而不是平涂混色（D24 第 7 条）。

    断相位那条虚线用 `glass` 不用钢灰：它是**唯一的**「这里有一根棒、此刻没电」的记号，
    暗底 g 上钢灰那档实测对墙 1.18（和 D34 记的极柱隐形同一类病），看不见就读不出时机。
    glass 对墙 3.28 —— 够读，又比 LIVE 暗一档，两个状态不会抢注意力。
    """
    d = ImageDraw.Draw(img, "RGBA")
    mid = y + thick // 2
    if not live:
        for xx in range(x0, x0 + w, 8):
            d.rectangle([xx, mid, min(xx + 3, x0 + w - 1), mid], fill=p["glass"])
        return
    glow = p["accent"] + (70,)
    for xx in range(x0, x0 + w):
        oy = int(round(1.5 * math.sin((xx - x0) % 16 * math.pi / 8.0)))
        d.rectangle([xx, mid - thick // 2 - 1 + oy, xx, mid + thick // 2 + 1 + oy], fill=glow)
        d.rectangle([xx, mid - thick // 2 + oy, xx, mid + thick // 2 + oy], fill=p["edge"])
        d.rectangle([xx, mid - thick // 2 + 1 + oy, xx, mid + thick // 2 - 1 + oy], fill=p["accent"])
        d.rectangle([xx, mid + oy, xx, mid + oy], fill=G.lighter(p["accent"], 0.74))


def bar_unit(p, length, thick, live):
    """一根电棒的整体：左右极柱 + 中间的光束。**横着画**，竖电闸 = 同一张图转 90 度 ——
    构件里也是这一张纹理平铺 + 实例 rotation，所以预览和引擎走的是一条合成路径。"""
    img = Image.new("RGBA", (10 + length + 10, 18), (0, 0, 0, 0))
    left = part_pole(p, True)
    img.paste(left, (0, 0), left)
    right = part_pole(p, False)
    img.paste(right, (10 + length, 0), right)
    paint_beam(img, p, 10, 9 - thick // 2, length, thick, live)
    return img


def part_key_ring(p):
    """K1 齿钥匙 14x12：圆环 + 杆 + 两颗齿。琥珀 = 可拾取物。"""
    img = Image.new("RGBA", (14, 12), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 1, 7, 8], fill=G.darker(a, 0.10))
    d.ellipse([2, 3, 5, 6], fill=(0, 0, 0, 0))
    d.rectangle([6, 4, 13, 6], fill=a)
    d.rectangle([6, 4, 13, 4], fill=G.lighter(a, 0.42))
    for tx in (10, 12):
        d.rectangle([tx, 7, tx, 9], fill=a)
    return _rim(img, p)


def part_key_card(p):
    """K2 能量卡 14x10：卡体 + 深色磁条 + 一颗青色芯片。"""
    img = Image.new("RGBA", (14, 10), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.rectangle([0, 0, 13, 9], fill=a)
    d.rectangle([0, 0, 13, 0], fill=G.lighter(a, 0.44))
    d.rectangle([0, 6, 13, 7], fill=G.darker(a, 0.52))
    d.rectangle([0, 9, 13, 9], fill=G.darker(a, 0.30))
    d.rectangle([2, 2, 4, 4], fill=p["accent"])
    return _rim(img, p)


def paint_beacon(img, p, cx, floor_y, state):
    """P1 灯柱 16x36：钢柱 + 灯头。state = off / idle / saved —— 存档点不是危险物，
    所以它激活走青白而不是琥珀，免得玩家以为是能拣的东西。"""
    d = ImageDraw.Draw(img, "RGBA")
    x0 = cx - 8
    d.rectangle([x0, floor_y - 8, x0 + 15, floor_y - 1], fill=p["deep"])
    d.rectangle([x0, floor_y - 8, x0 + 15, floor_y - 1], outline=p["lip"])
    d.rectangle([x0, floor_y - 8, x0 + 15, floor_y - 7], fill=G.lighter(p["metal"], 0.16))
    d.rectangle([x0 + 5, floor_y - 28, x0 + 10, floor_y - 8], fill=p["metal"])
    d.rectangle([x0 + 5, floor_y - 28, x0 + 5, floor_y - 8], fill=G.lighter(p["metal"], 0.22))
    d.rectangle([x0 + 2, floor_y - 36, x0 + 13, floor_y - 28], fill=G.darker(p["metal"], 0.20))
    d.rectangle([x0 + 2, floor_y - 36, x0 + 13, floor_y - 28], outline=p["lip"])
    lit = {"off": G.darker(p["metal"], 0.55),
           "idle": p["glass"],
           "saved": G.lighter(p["accent"], 0.55)}[state]
    d.rectangle([x0 + 4, floor_y - 34, x0 + 11, floor_y - 30], fill=lit)
    if state != "off":
        d.rectangle([x0 + 2, floor_y - 36, x0 + 13, floor_y - 36],
                    fill=G.mix(p["accent"], (255, 255, 255), 0.7) + (90,))


def paint_terminal(img, p, cx, floor_y, state):
    """P2 地台终端 32x14：矮台 + 斜面屏。屏上内容 = 已存档的读法全靠那条横线在不在。"""
    d = ImageDraw.Draw(img, "RGBA")
    x0 = cx - 16
    d.rectangle([x0, floor_y - 12, x0 + 31, floor_y - 1], fill=p["deep"])
    d.rectangle([x0, floor_y - 12, x0 + 31, floor_y - 1], outline=p["lip"])
    d.rectangle([x0, floor_y - 12, x0 + 31, floor_y - 11], fill=G.lighter(p["metal"], 0.18))
    d.rectangle([x0, floor_y - 1, x0 + 31, floor_y - 1], fill=p["edge"])
    d.rectangle([x0 + 4, floor_y - 9, x0 + 27, floor_y - 3], fill=p["screen"])
    if state == "off":
        d.rectangle([x0 + 6, floor_y - 7, x0 + 11, floor_y - 6], fill=G.darker(p["metal"], 0.30))
    elif state == "idle":
        d.rectangle([x0 + 6, floor_y - 7, x0 + 24, floor_y - 6], fill=p["glass"])
    else:
        d.rectangle([x0 + 6, floor_y - 7, x0 + 24, floor_y - 6], fill=G.lighter(p["accent"], 0.50))
        d.rectangle([x0 + 6, floor_y - 5, x0 + 16, floor_y - 4], fill=p["accent"])


def paint_spikes(img, unit, x0, floor_y, w):
    cx = x0
    while cx < x0 + w:
        take = min(unit.width, x0 + w - cx)
        img.paste(unit.crop((0, 0, take, unit.height)), (cx, floor_y - unit.height),
                  unit.crop((0, 0, take, unit.height)))
        cx += take


def m5_rows(p, terrain, decor, root):
    """一屏一个候选：S 尖刺 / E 电棒（横棒 + 竖电闸）/ K 钥匙 / P 存档点。"""
    rim = G.STYLES["g2"]["player_rim"]
    ink = G.lighter(p["lip"], 0.10)
    W, H, FY = 248, 140, 124
    strips = []

    for teeth, height, label in ((4, 10, "S1  spikes  dense  teeth 4/16"),
                                 (2, 12, "S2  spikes  sparse teeth 2/16"),
                                 (1, 14, "S3  spikes  one tooth / cell")):
        img = context_strip(p, terrain, decor, W, H, FY)
        u = part_spikes(p, teeth, height)
        paint_spikes(img, u, 24, FY, 96)
        paint_spikes(img, u, 152, FY, 40)      # 断口另起一段，看平铺接缝会不会跳
        G.paste_slime(img, "idle", 2, 224, FY, False, 1, root, rim)
        strips.append((img, label + "   run / gap / scale"))

    img = context_strip(p, terrain, decor, W, H, FY)
    lo = bar_unit(p, 96, 8, True)
    img.paste(lo, (16, FY - 18), lo)
    G.paste_slime(img, "idle", 2, 196, FY, False, 1, root, rim)
    strips.append((img, "E1  bar on the floor (live)   blocks both ways"))

    img = context_strip(p, terrain, decor, W, H, FY)
    hi = bar_unit(p, 96, 8, True)
    img.paste(hi, (16, FY - 48), hi)
    G.paste_slime(img, "crouch", 2, 64, FY, False, 1, root, rim)
    G.paste_slime(img, "idle", 2, 196, FY, False, 1, root, rim)
    d = ImageDraw.Draw(img)
    d.text((16, FY - 66), "crouch under it", fill=ink, font=_font(12))
    strips.append((img, "E2  same bar raised 30   D27: crouching walks past it for free"))

    for kind, label in ((part_key_ring(p), "K1  ring key  14x12"),
                        (part_key_card(p), "K2  energy card  14x10")):
        img = context_strip(p, terrain, decor, W, 72, 56)
        img.paste(kind, (56, 56 - kind.height - 1), kind)
        d = ImageDraw.Draw(img)
        d.text((44, 12), "floor", fill=ink, font=_font(12))
        G.paste_slime(img, "idle", 2, 168, 56, False, 1, root, rim)
        img.paste(kind, (168 - kind.width // 2, 56 - 30 - kind.height), kind)
        d.text((192, 16), "held", fill=ink, font=_font(12))
        strips.append((img, label))

    for which in ("beacon", "terminal"):
        img = context_strip(p, terrain, decor, W, 72, 56)
        for i, state in enumerate(("off", "idle", "saved")):
            cx = 48 + i * 80
            if which == "beacon":
                paint_beacon(img, p, cx, 56, state)
            else:
                paint_terminal(img, p, cx, 56, state)
            d = ImageDraw.Draw(img)
            d.text((cx - 16, 6), state, fill=ink, font=_font(12))
        strips.append((img, "P1  beacon  16x36" if which == "beacon"
                       else "P2  floor terminal  32x14"))

    img = context_strip(p, terrain, decor, W, H, FY)
    d = ImageDraw.Draw(img)
    for i, live in enumerate((False, True)):
        gate = bar_unit(p, 48, 8, live).transpose(Image.ROTATE_90)
        x = 44 + i * 124
        img.paste(gate, (x, FY - gate.height), gate)
        G.paste_slime(img, "idle" if not live else "run", 1 + i, x - 26, FY, False, 1, root, rim)
        d.text((x - 8, FY - gate.height - 20), "OFF" if not live else "LIVE",
               fill=ink, font=_font(12))
    strips.append((img, "E3  same bar rotated 90 = gate   OFF walk / LIVE solid + deadly"))
    return strips


def m5_context(p, terrain, decor, root):
    """把新零件和现有的 ab 门放进同一间 g 房里。这张才是真正要肉眼判的一张：
    混着看到底协不协调，只有画在一起才看得出来。"""
    w, h, floor_y = 496, 168, 152
    img = context_strip(p, terrain, decor, w, h, floor_y)
    ab = G.STYLES["ab"]
    parts_ab = make_parts(ab, ab["deep"], ab["accent2"])
    paint_door(img, ab, parts_ab, 300, floor_y, 0.0, False)
    d = ImageDraw.Draw(img)
    d.rectangle([298, floor_y - 103, 301, floor_y - 102], fill=p["accent2"])   # 锁着的 LED
    u = part_spikes(p, 4, 10)
    paint_spikes(img, u, 24, floor_y, 72)
    paint_spikes(img, u, 360, floor_y, 56)
    gate = bar_unit(p, 48, 8, True).transpose(Image.ROTATE_90)
    img.paste(gate, (152, floor_y - gate.height), gate)
    key = part_key_ring(p)
    img.paste(key, (60, floor_y - key.height - 1), key)
    paint_beacon(img, p, 424, floor_y, "saved")
    G.paste_slime(img, "run", 3, 96, floor_y, False, 1, root,
                  G.STYLES["g2"]["player_rim"])
    return img


def m5_contrast(p):
    """选型图的自我核对：新零件主色对墙 / 对地面的对比度。低于 4.5 只是提示，不当否决（D26 第 8 条）。"""
    rows = [("spike tip", p["lip"]), ("beam core", G.lighter(p["accent"], 0.74)),
            ("beam body", p["accent"]), ("bar OFF dash", p["glass"]),
            ("key amber", p["accent2"]),
            ("beacon lit", G.lighter(p["accent"], 0.55)), ("beacon body", p["deep"]),
            ("pole body", p["metal"]), ("metal rim (lip)", p["lip"]),
            ("door slat (ab, as shipped)", G.STYLES["ab"]["deep"])]
    print("\nM5 part                    lum    vs wall  vs floor")
    for name, c in rows:
        l = G._rlum(c if len(c) == 4 else c + (255,))
        flag = "" if G._cr(c, p["bg"]) >= 4.5 else "   <- below 4.5"
        print("%-26s %5.1f %7.2f %8.2f%s" % (name, l * 100, G._cr(c, p["bg"] + (255,)),
                                             G._cr(c, p["surface"] + (255,)), flag))


def m5_sheet():
    """M5 选型图。底图用**实装风格 g** 的真图集而不是 ab —— 新零件在夜光墙上读不出来就白画。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES[G.SHIPPED]
    terrain = G.build_terrain_atlas(p)
    decor = G.build_decor_atlas(p)
    rows = m5_rows(p, terrain, decor, root)
    wide = m5_context(p, terrain, decor, root)

    gap, pad, cap = 20, 16, 22
    strip_w = rows[0][0].width * ZOOM
    W = pad * 2 + strip_w * 2 + gap
    pairs = [rows[i:i + 2] for i in range(0, len(rows), 2)]
    cells, y = [], pad + cap
    for pr in pairs:
        hh = max(im.height for im, _ in pr) * ZOOM
        cells.append((y, hh))
        y += hh + 26 + gap
    H = y + wide.height * ZOOM + 26 + pad
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 6), "M5  HAZARD / KEY / CHECKPOINT   parts drawn on shipped style %s   "
                     "bottom picture = mixed with the shipped ab door" % G.SHIPPED,
           fill=ink, font=_font(14))
    for (y0, hh), pr in zip(cells, pairs):
        for col, (img, label) in enumerate(pr):
            up = img.convert("RGB").resize((img.width * ZOOM, img.height * ZOOM), Image.NEAREST)
            x = pad + col * (strip_w + gap)
            canvas.paste(up, (x, y0))
            d.text((x, y0 + hh + 4), label, fill=ink, font=_font(12))
    y0 = cells[-1][0] + cells[-1][1] + 26 + gap
    up = wide.convert("RGB").resize((wide.width * ZOOM, wide.height * ZOOM), Image.NEAREST)
    canvas.paste(up, (pad, y0))
    d.text((pad, y0 + up.height + 4), "all of them in one room at once  <- judge this one",
           fill=ink, font=_font(12))
    out = os.path.join(out_dir, "preview_m5.png")
    canvas.save(out)
    print("saved", out, canvas.size)
    m5_contrast(p)


def ceil_band(img, terrain, w, y):
    """预览手搭一层天花板：把「上开」那格竖翻就是「下开」。引擎里 terrain 笔刷自动出，不用手管。"""
    t = terrain.crop((2 * TILE, 3 * TILE, 3 * TILE, 4 * TILE)).transpose(Image.FLIP_TOP_BOTTOM)
    for cx in range(0, w, TILE):
        img.paste(t, (cx, y))


def hang_spikes(img, unit, x0, ceil_bottom, w):
    """倒挂尖刺 = 同一格零件竖翻。构件里就是 rotation = 180，不另出零件。"""
    u = unit.transpose(Image.FLIP_TOP_BOTTOM)
    paint_spikes(img, u, x0, ceil_bottom + u.height, w)


def m5_final_rows(p, terrain, decor, root):
    """定稿图三张：只画选中的件，而且按**真尺寸**画 —— 选型图里那根 68 px 的竖闸跳得过去，是示意尺寸。"""
    rim = G.STYLES["g2"]["player_rim"]
    W, H, FY = 496, 188, 172
    strips = []

    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    u = part_spikes(p, 1, 14)
    paint_spikes(img, u, 24, FY, 128)
    hang_spikes(img, u, 200, 16, 128)
    G.paste_slime(img, "idle", 2, 424, FY, False, 1, root, rim)
    strips.append((img, "S3  floor spikes  /  ceiling spikes  (same part, rotation 180)"))

    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    for i, live in enumerate((False, True)):
        b = bar_unit(p, 128, 8, live)
        x = 40 + i * 240
        img.paste(b, (x, FY - 92), b)          # 钉在半空 83 px 高，正卡在跳跃路线上
        G.paste_slime(img, "jump", 0, x + 64, FY - 44, False, 1, root, rim)
    strips.append((img, "F1  floating bar  OFF / LIVE   nothing holds it up, either orientation"))

    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    gate = bar_unit(p, 120, 10, True).transpose(Image.ROTATE_90)
    img.paste(gate, (248, FY - gate.height), gate)
    G.paste_slime(img, "run", 2, 176, FY, False, 1, root, rim)
    strips.append((img, "F2  gate  floor to ceiling   120 px span, no jump-over route"))
    return strips


def m5_room(p, terrain, decor, root):
    """定稿混排间：选中的四件 + 现存的 ab 门，全按真尺寸摆进同一间房。"""
    W, H, FY = 496, 188, 172
    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    ab = G.STYLES["ab"]
    paint_door(img, ab, make_parts(ab, ab["deep"], ab["accent2"]), 400, FY, 0.0, False)
    ImageDraw.Draw(img).rectangle([398, FY - 103, 401, FY - 102], fill=p["accent2"])
    u = part_spikes(p, 1, 14)
    paint_spikes(img, u, 24, FY, 64)
    hang_spikes(img, u, 24, 16, 64)
    b = bar_unit(p, 96, 8, True)
    img.paste(b, (104, FY - 92), b)
    gate = bar_unit(p, 120, 10, False).transpose(Image.ROTATE_90)
    img.paste(gate, (232, FY - gate.height), gate)
    card = part_key_card(p)
    img.paste(card, (200, FY - card.height - 1), card)
    paint_terminal(img, p, 320, FY, "saved")
    G.paste_slime(img, "run", 3, 80, FY, False, 1, root, G.STYLES["g2"]["player_rim"])
    return img


def m5_final():
    """定稿图（单列，一张一条），输出 assets/props/preview_m5_shipped.png。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES[G.SHIPPED]
    terrain = G.build_terrain_atlas(p)
    decor = G.build_decor_atlas(p)
    strips = m5_final_rows(p, terrain, decor, root) + [
        (m5_room(p, terrain, decor, root),
         "ROOM  S3 + floating bar + gate(OFF) + K2 + P2, next to the shipped ab door")]

    pad, gap = 16, 22
    W = pad * 2 + strips[0][0].width * ZOOM
    H = pad + 22 + sum(im.height * ZOOM + 26 + gap for im, _ in strips) + pad
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 6), "M5 SHIPPED SET  spikes S3 / key K2 / checkpoint P2 / bar (floating, "
                     "any orientation)   style %s" % G.SHIPPED, fill=ink, font=_font(14))
    y = pad + 22
    for img, label in strips:
        up = img.convert("RGB").resize((img.width * ZOOM, img.height * ZOOM), Image.NEAREST)
        canvas.paste(up, (pad, y))
        d.text((pad, y + up.height + 4), label, fill=ink, font=_font(12))
        y += up.height + 26 + gap
    out = os.path.join(out_dir, "preview_m5_shipped.png")
    canvas.save(out)
    print("saved", out, canvas.size)


# ---------------------------------------------------------------- D36 刷卡门

## D53 拒绝态那一对 = 选型图 `tools/gen_gate_alert_preview.py` 的 G 行字面值，**不从调色板推导**：
## 那颗灯在 1280×720 里只有 4×4 设备像素，还要透过 D46 那层 CRT，任何纯色相对琥珀都拉不开
## （实测对底座 2.3~4.4、对琥珀 2.1~4.0，全在 D26 的 4.5 下限之下）。用户看图挑了 G ——
## 赌的是面积：底座一起换成暗红，亮的部分从 2×2 涨到整颗 4×4。
## 三处同源：本文件、`key_door.gd` 的 LED_DENIED / LED_DENIED_SOCKET、props.json 的
## gate_led_denied / gate_led_denied_socket，verify_kit 比对后两处。
GATE_LED_DENIED = (255, 86, 74)
GATE_LED_DENIED_SOCKET = (66, 14, 18)


def paint_gate(img, p, ab, parts, cx, floor_y, progress, latched, w=32, h=96, denied=False):
    """刷卡门（D36）：同一副钢框里是一道**能量闸**，不是钢板。

    通带取下部 h*(1-progress)，与卷帘取上部方向相反 —— 卷帘的缝在下面等着挤人，
    光幕的缝在上面只会越让越开。顶端那三行残辉是断电的尾巴，碰撞只到亮带为止，
    预览与构件走同一条算式。LED 锁着 = 琥珀（与钥匙同色，成对），闩开 = 青，
    无卡靠近 = 红且**连底座一起**红（D53）。
    幕体**纯色半透明、不画纹路** —— 带光丝的那版用户看过直接否了：纹路丑，单纯一块蓝光幕就够。
    半透明是必要的，背后的墙透得出来才读成「光」，平涂不透明就成了一块门板。

    三处和构件逐像素对齐的写法，改这里要一起改构件：
    - 锁着的 LED 取 **p（实装风格 g）的 amber**，不是门框那套 ab 的 —— 「与钥匙同色」判的是
      `key_card.png` 落盘的那个色，用 ab 的琥珀差着一档亮度，成对这条就读不出来。
    - 门楣下面那道亮脊**复用 header 零件自己的前两行**，不是平涂一块 metal：构件里这样写
      就少一个要进 props.json 比对的色，预览与构件因此仍然是同一张纹理的同一截。
    - 拒绝态那一对（`GATE_LED_DENIED` / `GATE_LED_DENIED_SOCKET`）是**字面常量**，不从调色板
      推导：构件里是同名 `Color8`、清单里是 `gate_led_denied` / `gate_led_denied_socket`，
      三处任改其一 verify_kit 就在这里响（D53）。
    """
    x0 = cx - w // 2
    top = floor_y - h
    tile_v(img, parts["jamb"], x0 - 4, top - 12, h + 12)
    tile_v(img, parts["jamb"], x0 + w, top - 12, h + 12)
    tile_h(img, parts["header"], parts["header_l"], parts["header_r"], x0 - 4, top - 12, w + 8)
    tile_h_plain(img, parts["header"].crop((0, 0, 16, 2)), x0, top, w)
    d = ImageDraw.Draw(img, "RGBA")
    led = (x0 + w // 2 - 1, top - 7)
    d.rectangle([led[0] - 1, led[1] - 1, led[0] + 2, led[1] + 2],
                fill=GATE_LED_DENIED_SOCKET if denied else G.darker(ab["screen"], 0.2))
    d.rectangle([led[0], led[1], led[0] + 1, led[1] + 1],
                fill=GATE_LED_DENIED if denied
                     else (G.mix(p["accent"], (255, 255, 255), 0.5) if latched else p["accent2"]))
    live = int(round(h * (1.0 - progress)))
    if live <= 0:
        return
    band_top = floor_y - live
    for i, a in enumerate((120, 66, 30)):
        d.rectangle([x0, band_top - 1 - i, x0 + w - 1, band_top - 1 - i], fill=p["accent"] + (a,))
    d.rectangle([x0, band_top + 1, x0 + w - 1, floor_y - 1], fill=p["accent"] + (150,))
    d.rectangle([x0 - 1, band_top, x0 - 1, floor_y - 1], fill=p["accent"] + (48,))
    d.rectangle([x0 + w, band_top, x0 + w, floor_y - 1], fill=p["accent"] + (48,))
    rim = G.lighter(p["accent"], 0.45)
    d.rectangle([x0, band_top, x0, floor_y - 1], fill=rim)
    d.rectangle([x0 + w - 1, band_top, x0 + w - 1, floor_y - 1], fill=rim)
    d.rectangle([x0, band_top, x0 + w - 1, band_top], fill=G.lighter(p["accent"], 0.74))
    d.rectangle([x0, floor_y - 1, x0 + w - 1, floor_y - 1], fill=p["metal"])


def gate_anim_row(p, terrain, decor, root):
    """对照行：同样四个进度，左边卷帘、右边光幕。要看的不是好不好看，是「谁在动、往哪儿动」。"""
    W, H, FY = 496, 188, 172
    ab = G.STYLES["ab"]
    parts_ab = make_parts(ab, ab["deep"], ab["accent2"])
    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    d = ImageDraw.Draw(img)
    for i in range(4):
        prog = i / 3.0
        cx = 56 + i * 112
        paint_door(img, ab, parts_ab, cx, FY, prog, prog >= 1.0)
        paint_gate(img, p, ab, parts_ab, cx + 56, FY, prog, prog > 0.0)
        d.text((cx + 14, 44), "%.2f" % prog, fill=(214, 224, 240), font=_font(11))
    d.text((42, 20), "shutter", fill=(214, 224, 240), font=_font(11))
    d.text((104, 20), "gate", fill=(214, 224, 240), font=_font(11))
    G.paste_slime(img, "run", 3, 452, FY, False, 1, root, G.STYLES["g2"]["player_rim"])
    return img


def gate_lock_row(p, terrain, decor, root):
    """可读性行：锁着的光闸 + 头顶带着钥匙的主角。琥珀对琥珀能不能读成「这把开那扇」，看图就知道。
    右边多画一扇 D53 的拒绝态（无卡靠近，连底座发红）—— 同一行现在同时回答两件事：
    琥珀对琥珀读不读得成「一把开一扇」，红对琥珀读不读得出「这颗灯换了状态」。"""
    W, H, FY = 496, 188, 172
    ab = G.STYLES["ab"]
    parts_ab = make_parts(ab, ab["deep"], ab["accent2"])
    img = context_strip(p, terrain, decor, W, H, FY)
    ceil_band(img, terrain, W, 0)
    paint_gate(img, p, ab, parts_ab, 300, FY, 0.0, False)
    paint_gate(img, p, ab, parts_ab, 420, FY, 0.0, False, denied=True)
    paint_door(img, ab, parts_ab, 120, FY, 0.0, False)
    card = part_key_card(p)
    G.paste_slime(img, "run", 2, 216, FY, False, 1, root, G.STYLES["g2"]["player_rim"])
    img.paste(card, (216 - card.width // 2, FY - 30), card)
    img.paste(card, (176, FY - card.height - 1), card)
    d = ImageDraw.Draw(img)
    d.text((86, 20), "button door (shutter)", fill=(214, 224, 240), font=_font(11))
    d.text((258, 20), "key door, locked", fill=(214, 224, 240), font=_font(11))
    d.text((386, 20), "key door, denied", fill=(214, 224, 240), font=_font(11))
    d.text((196, FY - 48), "held key", fill=(214, 224, 240), font=_font(11))
    return img


def m5_door():
    """D36 选型图（单列），输出 assets/props/preview_keydoor.png。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES[G.SHIPPED]
    terrain = G.build_terrain_atlas(p)
    decor = G.build_decor_atlas(p)
    strips = [
        (gate_anim_row(p, terrain, decor, root),
         "D36  four pairs, same progress 0 -> 1; LEFT of each pair is the button door, RIGHT is "
         "the key door.  Shutter hangs from the header and rises (gap opens BELOW, it can stop "
         "on a head).  Gate is a field from the floor, dying TOP DOWN (gap opens ABOVE, it can "
         "never squeeze anyone)."),
        (gate_lock_row(p, terrain, decor, root),
         "legibility: locked reader LED = same amber as the key.  Denied LED (no key, player in "
         "the sensor band) = the whole lamp goes red, socket included.  Nothing moves in this "
         "door's frame, the frame is the only solid part."),
    ]

    pad, gap, line = 16, 22, 15
    blocks = [(_wrap(label, 108), im) for im, label in strips]
    W = pad * 2 + strips[0][0].width * ZOOM
    H = pad + 22 + sum(im.height * ZOOM + 4 + len(ls) * line + gap for ls, im in blocks) + pad
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 6), "KEY DOOR  separate scene, separate animation (D36)   style %s" % G.SHIPPED,
           fill=ink, font=_font(14))
    y = pad + 22
    for lines, im in blocks:
        up = im.convert("RGB").resize((im.width * ZOOM, im.height * ZOOM), Image.NEAREST)
        canvas.paste(up, (pad, y))
        for i, text in enumerate(lines):
            d.text((pad, y + up.height + 4 + i * line), text, fill=ink, font=_font(12))
        y += up.height + 4 + len(lines) * line + gap
    out = os.path.join(out_dir, "preview_keydoor.png")
    canvas.save(out)
    print("saved", out, canvas.size)


def _wrap(text, width):
    lines, cur = [], ""
    for word in text.split():
        if cur and len(cur) + 1 + len(word) > width:
            lines.append(cur)
            cur = word
        else:
            cur = word if not cur else cur + " " + word
    if cur:
        lines.append(cur)
    return lines


# ---------------------------------------------------------------- 落盘（选型定稿后）
# 零件文件名 -> make_parts 的键。构件脚本 preload 的就是这些路径，改名要一起改。
PART_FILES = {
    "door_slat": "slat",
    "door_bottom": "bottom",
    "door_jamb": "jamb",
    "door_header": "header",
    "door_header_cap_l": "header_l",
    "door_header_cap_r": "header_r",
    "button_top": "top",
    "button_base": "base",
}


def make_m5_parts(p):
    """M5 落盘零件（D34 选型的 S3 / K2 / P2 + 电棒那套）。

    每张都由**选型图用过的同一个调用**产出，不是「重新画一遍长得像的」：
    定稿是用户看像素批的，落盘的像素必须和他批的那张逐位相同。
    束厚写死在 `bar_live.png` 里（8 px → 可见带 9 行 + 摆动 ±2 = 13 行）而**不做导出项**，
    理由是 D34 第 1 条那条：摆了没反应的旋钮比多一个零件糟。竖电闸 = 同一张纹理转 90°。
    极柱出**左右两张**而不是一张运行时镜像：bar_unit 的原画里两根柱子都是左亮右暗
    （同一盏灯照着），镜像会把右柱照成右亮左暗，和用户批过的像素对不上。
    """
    parts = {}
    parts["spike_unit"] = part_spikes(p, 1, 14)
    parts["bar_pole_l"] = part_pole(p, True)
    parts["bar_pole_r"] = part_pole(p, False)
    for name, live in (("bar_live", True), ("bar_off", False)):
        img = Image.new("RGBA", (16, 18), (0, 0, 0, 0))
        # y=5 / mid=9：与 bar_unit 同一处，构件按同样位置平铺。
        paint_beam(img, p, 0, 5, 16, 8, live)
        parts[name] = img
    parts["key_card"] = part_key_card(p)
    idle = Image.new("RGBA", (32, 12), (0, 0, 0, 0))
    paint_terminal(idle, p, 16, 12, "idle")
    parts["terminal_idle"] = idle
    # D45：已存态比未存态高 15 px、宽 12 px —— 差别全加在轮廓上，
    # 因为旧的两张 32×12 只差屏里一条 1 px 横线，摆图视角下根本分不出"存过没存过"。
    saved = Image.new("RGBA", (44, 16), (0, 0, 0, 0))
    paint_terminal(saved, p, 22, 16, "saved")
    paint_cp_saved_glow(saved, p, 22, 16)
    parts["terminal_saved"] = saved
    return parts


def emit_parts():
    """把选定配色的零件写成 PNG + props.json。构件的 _draw() 只认这些文件。"""
    import json
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES["ab"]
    g = G.STYLES[G.SHIPPED]
    parts = make_parts(p, p["deep"], p["accent2"])
    manifest = {
        "style": "ab",
        "door_body": "deep",
        "button_face": "accent2",
        "led_socket": list(G.darker(p["screen"], 0.2)),
        "led_lit": list(G.mix(p["accent"], (255, 255, 255), 0.5)),
        "button_socket": list(p["screen"]),
        "end_shade": list(G.darker(p["metal"], 0.45)),
        # M5（D29~D36）：一个 manifest 里两个 style 是**有意为之**。门/按钮钉在 ab 是 D25/D26
        # 的定案（用户看过对比数字后接受），而 M5 那批零件是他在 g 底的选型图里定稿的，
        # 落盘必须与 --m5final 出的预览逐像素相同，否则「看图定稿」这条链就断了。
        "m5_style": G.SHIPPED,
        "gate_led_locked": list(g["accent2"]),
        "gate_led_lit": list(G.mix(g["accent"], (255, 255, 255), 0.5)),
        # D53：拒绝态那一对是字面值、不从调色板推导（缘由见 paint_gate 上方那段）。
        # 构件里是同名 Color8 常量，verify_kit 逐条比对。
        "gate_led_denied": list(GATE_LED_DENIED),
        "gate_led_denied_socket": list(GATE_LED_DENIED_SOCKET),
        "gate_curtain": list(g["accent"]),
        # D44：祭坛环与核心的青色。构件里那份 CORE_COLOR 常量必须等于这个 ——
        # 旧版祭坛把一串琥珀写死在自己脚本里、从来不在清单上，本条把这条路堵上。
        "altar_core": list(g["accent"]),
        "parts": {},
    }
    for fname, key in PART_FILES.items():
        img = parts[key].convert("RGBA")
        img.save(os.path.join(out_dir, fname + ".png"))
        manifest["parts"][fname] = [img.width, img.height]
    for fname, img in make_m5_parts(g).items():
        img.save(os.path.join(out_dir, fname + ".png"))
        manifest["parts"][fname] = [img.width, img.height]
    # D44：祭坛和 M5 那批同属 g 风格，同一个 manifest 里两个 style 的缘由见上面那条注释。
    for fname, img in make_altar_parts(g).items():
        img.save(os.path.join(out_dir, fname + ".png"))
        manifest["parts"][fname] = [img.width, img.height]
    # D54：彩蛋收集物（小黄鸭三视图 + 底座两态），同样走 g。
    for fname, img in make_collectible_parts(g).items():
        img.save(os.path.join(out_dir, fname + ".png"))
        manifest["parts"][fname] = [img.width, img.height]
    with open(os.path.join(out_dir, "props.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
    print("emitted %d parts + props.json to %s" % (len(manifest["parts"]), out_dir))


# ------------------------------------------------- 祭坛美术与存档点反馈选型（D44 / D45）
# 定稿的两套已经落盘：祭坛走 `make_altar_parts()`（--emit 写 PNG + props.json），
# 已存终端在 `make_m5_parts()` 里长到 44×16。这一节剩下的职责是**出选型图**与被否掉的
# 候选（A2 / A3 / B1 / B3）—— 沿用 D34 那条纪律：用户是看像素批的，
# A1 与 B2 这两行画的必须就是落盘那一份，不许另画一套长得像的。
# 色彩分工照 D29 那张表读：青 = 光与电、琥珀 = 可拾取物、亮白钢 = 会咬人的固体、
# 钢灰 = 未激活的静物。祭坛是"把东西交给你的机器"，卡在青与琥珀之间，三套候选各偏一头。
# 存档点那四套不是四种画法，是四种**"如何让一次性的事件留成常读的状态"**。

def blend_rect(img, box, color, alpha):
    """把颜色**真的混进**不透明底图。ImageDraw 在 RGBA 图上是直写像素不做混合，
    `fill=accent + (34,)` 会把那块底冲成青色；画布最后 convert("RGB") 又把 alpha 丢了，
    于是"柔光"在选型图上全画成实心亮块。落盘的零件 PNG 不用它 —— 那里 alpha 就是产物。"""
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1), color[:3] + (int(alpha),))
    base = img.crop((x0, y0, x1 + 1, y1 + 1)).convert("RGBA")
    img.paste(Image.alpha_composite(base, layer), (x0, y0))


def _paste_ground(img, part, cx, fy):
    """按**底边中心**贴一张零件 —— 与构件的节点原点同一套约定，
    于是 32×12 的未存态和 44×16 的已存态（D45）脚在同一条线上，选型图不会骗人。"""
    img.paste(part, (cx - part.width // 2, fy - part.height), part)


def make_altar_parts(p):
    """D44 祭坛 A1 的六张零件：平铺件 base / shaft / cap，居中件 groove / burn / core。
    选型图 `--altar` 的 A1 行与构件 `_draw()` 用的就是这一份 —— 用户是看像素批的（D34），
    所以两边都不许另画一套。柱缝 16 周期，与瓦片同一套规矩，石台和墙摆一起缝要对得上。
    """
    def blank(w, h):
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        return img, ImageDraw.Draw(img)

    base, db = blank(16, 16)
    db.rectangle([0, 0, 15, 0], fill=G.lighter(p["metal"], 0.16))
    db.rectangle([0, 1, 15, 14], fill=p["deep"])
    db.rectangle([0, 15, 15, 15], fill=p["edge"])

    shaft, ds = blank(16, 16)
    ds.rectangle([0, 0, 15, 15], fill=p["metal"])
    ds.rectangle([0, 8, 15, 8], fill=G.darker(p["metal"], 0.42))
    ds.rectangle([0, 0, 0, 15], fill=G.lighter(p["metal"], 0.24))
    ds.rectangle([15, 0, 15, 15], fill=G.darker(p["metal"], 0.35))

    cap, dc = blank(16, 8)
    dc.rectangle([0, 0, 15, 0], fill=p["lip"])
    dc.rectangle([0, 1, 15, 7], fill=G.lighter(p["metal"], 0.26))

    groove, dg = blank(18, 6)
    dg.rectangle([0, 0, 17, 5], fill=p["screen"])

    burn, dn = blank(18, 6)
    dn.rectangle([1, 1, 16, 4], fill=G.mix(p["glass"], p["screen"], 0.45))

    # 核心：柔光靠零件自带的 alpha，运行时贴在墙上由引擎混色 —— 与选型图同一条路径。
    core, dk = blank(28, 16)
    dk.rectangle([1, 2, 26, 14], fill=p["accent"] + (34,))
    dk.polygon([(14, 1), (20, 8), (14, 15), (8, 8)],
               fill=p["accent"], outline=G.lighter(p["accent"], 0.55))
    dk.rectangle([13, 5, 15, 11], fill=G.lighter(p["accent"], 0.72))
    return {"altar_base": base, "altar_shaft": shaft, "altar_cap": cap,
            "altar_groove": groove, "altar_burn": burn, "altar_core": core}


def _blit_tile(img, part, x, y, w, h):
    """与 `components/tile_draw.gd` 的 `TileDraw.tile` 逐像素同构：从目标矩形左上角起铺，
    右缘底缘裁余料（余料取零件**左**上那块，不是右下一块）。改了这边必须改那边。"""
    pw, ph = part.size
    cy = y
    while cy < y + h:
        th = min(ph, y + h - cy)
        cx2 = x
        while cx2 < x + w:
            tw = min(pw, x + w - cx2)
            tile = part.crop((0, 0, tw, th))
            img.paste(tile, (cx2, cy), tile)
            cx2 += tw
        cy += th


def paint_altar_steps(img, p, cx, fy, w, h, spent, parts=None):
    """A1 阶梯石台 + 悬浮核心：底座一整条、内缩 8 px 的柱身、齐宽的石帽，
    帽上居中一枚凹槽，槽正上方悬着青色核心 —— 那份能力本来就**不在石头上**。
    已耗态核心没了、槽里只剩一圈烧灼青印。全部由 `make_altar_parts()` 那六张拼出。"""
    parts = parts or make_altar_parts(p)
    top_y = fy - h
    x0 = cx - w // 2
    _blit_tile(img, parts["altar_base"], x0, fy - 16, w, 16)
    _blit_tile(img, parts["altar_cap"], x0, top_y, w, 8)
    _blit_tile(img, parts["altar_shaft"], x0 + 8, top_y + 8, w - 16, fy - 16 - top_y - 8)
    slot = parts["altar_burn"] if spent else parts["altar_groove"]
    img.paste(slot, (cx - 9, top_y + 3), slot)
    if spent:
        return
    core = parts["altar_core"]
    img.paste(core, (cx - 14, top_y - 17), core)


def paint_altar_totem(img, p, cx, fy, w, h, spent):
    """A2 图腾柱 + 灯罩：细柱贴地、顶端一盏灯。高度靠柱子争取，横向只占 28 px，
    适合摆在窄台或通道顶上；灯 = 那份能力，已耗就熄成玻璃色。"""
    d = ImageDraw.Draw(img, "RGBA")
    head_y = fy - h
    lit = p["glass"] if spent else p["accent"]
    if not spent:
        blend_rect(img, (cx - 16, head_y - 5, cx + 15, head_y + 16), p["accent"], 26)
    bw = 28
    d.rectangle([cx - bw // 2, fy - 10, cx + bw // 2 - 1, fy - 1], fill=p["deep"])
    d.rectangle([cx - bw // 2, fy - 10, cx + bw // 2 - 1, fy - 9],
                fill=G.lighter(p["metal"], 0.16))
    d.rectangle([cx - bw // 2, fy - 1, cx + bw // 2 - 1, fy - 1], fill=p["edge"])
    px0, px1 = cx - 7, cx + 6
    d.rectangle([px0, head_y + 12, px1, fy - 11], fill=p["metal"])
    d.rectangle([px0, head_y + 12, px0, fy - 11], fill=G.lighter(p["metal"], 0.24))
    d.rectangle([px1, head_y + 12, px1, fy - 11], fill=G.darker(p["metal"], 0.35))
    for sy in range(fy - 26, head_y + 12, -16):
        d.rectangle([px0 + 1, sy, px1 - 1, sy], fill=G.darker(p["metal"], 0.45))
    d.rectangle([cx - 11, head_y, cx + 10, head_y + 12], fill=G.darker(p["metal"], 0.30))
    d.rectangle([cx - 11, head_y, cx + 10, head_y], fill=p["lip"])
    d.rectangle([cx - 8, head_y + 3, cx + 7, head_y + 10], fill=lit)
    d.rectangle([cx - 8, head_y + 3, cx + 7, head_y + 3], fill=G.lighter(lit, 0.40))


def paint_altar_well(img, p, cx, fy, w, h, spent):
    """A3 光井：地上只有一圈井口，能力是一道从井里升起来的光柱。
    三套里零件最少的一套（两块石沿 + 一道光），也是体积最小、亮度最高的一种读法。"""
    d = ImageDraw.Draw(img, "RGBA")
    jw = w // 2
    for sx in (cx - jw, cx + jw - 8):
        d.rectangle([sx, fy - 12, sx + 7, fy - 1], fill=p["metal"])
        d.rectangle([sx, fy - 12, sx + 7, fy - 12], fill=p["lip"])
        d.rectangle([sx, fy - 1, sx + 7, fy - 1], fill=p["edge"])
    d.rectangle([cx - jw + 8, fy - 3, cx + jw - 9, fy - 2], fill=G.darker(p["deep"], 0.30))
    d.rectangle([cx - jw, fy - 1, cx + jw - 1, fy - 1], fill=p["edge"])
    if spent:
        d.rectangle([cx - jw + 8, fy - 5, cx + jw - 9, fy - 4],
                    fill=G.mix(p["glass"], p["screen"], 0.60))
        return
    for i in range(h - 2):
        y = fy - 3 - i
        k = i / float(h - 2)
        half = max(1, int(6 * (1.0 - k * 0.6)))
        alpha = int(205 * (1.0 - k) ** 1.5)
        blend_rect(img, (cx - half, y, cx + half, y),
                   G.mix(p["accent"], (255, 255, 255), 0.35 * k), alpha)


def paint_altar_plain(img, p, cx, fy, w, h, spent):
    """A0 现状对照：`ability_altar.gd` 现在真实画出来的东西 —— 一块实心梯形。
    未耗 0.98/0.82/0.42 的琥珀（注意它**不在 props.json 里**，是构件自己的字面量），
    已耗 0.3/0.28/0.24 —— 在夜光墙上基本等于消失。"""
    d = ImageDraw.Draw(img, "RGBA")
    body = (77, 71, 61) if spent else (250, 209, 107)
    d.polygon([(cx - w // 2, fy - 1), (cx + w // 2 - 1, fy - 1),
               (cx + w // 2 - 13, fy - h), (cx - w // 2 + 13, fy - h)], fill=body)


def paint_cp_pulse(img, p, cx, fy, rise, alpha):
    """B1 的一次性脉冲：终端上方一枚向上的青色箭头，`rise` 是它在 0.4 s 里的高度。
    基准高度抬到玩家头顶（本体 26 px）：踩上终端那一刻玩家就挡在终端正上方，
    脉冲画在身体高度上等于没画。"""
    y = fy - 32 - rise
    a = int(alpha)
    head = G.lighter(p["accent"], 0.45)
    for i in range(5):
        wdt = 12 - i * 2
        if wdt <= 0:
            break
        blend_rect(img, (cx - wdt // 2, y - 4 + i, cx + wdt // 2, y - 4 + i), head, a)
    blend_rect(img, (cx - 1, y + 1, cx + 1, y + 6), G.lighter(p["accent"], 0.72), a)


def paint_cp_saved_glow(img, p, cx, fy):
    """B2 的"常亮差一档"：屏整块亮 + 顶上一盏灯 + 地面两侧各一条青边。
    三条都是**加了高度**的差别，不靠屏上那条 1 px 的线。"""
    d = ImageDraw.Draw(img, "RGBA")
    x0 = cx - 16
    d.rectangle([x0 - 6, fy - 1, x0 - 1, fy - 1], fill=p["accent"])
    d.rectangle([x0 + 32, fy - 1, x0 + 37, fy - 1], fill=p["accent"])
    d.rectangle([x0 + 4, fy - 9, x0 + 27, fy - 3], fill=G.lighter(p["accent"], 0.42))
    d.rectangle([x0 + 6, fy - 7, x0 + 25, fy - 5], fill=p["screen"])
    d.rectangle([x0 + 13, fy - 15, x0 + 18, fy - 12], fill=G.darker(p["metal"], 0.20))
    d.rectangle([x0 + 14, fy - 14, x0 + 17, fy - 13], fill=G.lighter(p["accent"], 0.70))


def altar_sheet():
    """祭坛与存档点反馈的选型图。底图仍是实装风格 g 的真图集 —— 在夜光墙上读不出来就白画。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES[G.SHIPPED]
    terrain = G.build_terrain_atlas(p)
    decor = G.build_decor_atlas(p)
    term = make_m5_parts(p)
    rim = G.STYLES["g2"]["player_rim"]
    ink = G.lighter(p["lip"], 0.10)
    W, H, FY = 248, 140, 124
    AW, AH = 64, 56                       # = AbilityAltar 的 width / altar_height 默认值
    strips = []

    for painter, label in (
            (paint_altar_plain, "A0  CURRENT  flat trapezoid, amber / spent-grey"),
            (paint_altar_steps, "A1  SHIPPED  stepped plinth + floating core"),
            (paint_altar_totem, "A2  totem pole + lamp head (28 wide, reads by height)"),
            (paint_altar_well, "A3  light well + rising column (fewest parts)")):
        img = context_strip(p, terrain, decor, W, H, FY)
        painter(img, p, 56, FY, AW, AH, False)
        painter(img, p, 176, FY, AW, AH, True)
        G.paste_slime(img, "idle", 2, 116, FY, False, 1, root, rim)
        d = ImageDraw.Draw(img)
        d.text((44, 8), "unspent", fill=ink, font=_font(12))
        d.text((164, 8), "spent", fill=ink, font=_font(12))
        strips.append((img, label))

    # A1b：按 level1.tscn 里真实设定的尺寸（width=46.955 / altar_height=37.92）再画一遍。
    # 平铺件必须在非 16 倍数上也对得齐 —— 这一格才是用户实际会看到的那个尺寸。
    img = context_strip(p, terrain, decor, W, H, FY)
    paint_altar_steps(img, p, 56, FY, 47, 38, False)
    paint_altar_steps(img, p, 176, FY, 47, 38, True)
    G.paste_slime(img, "idle", 2, 116, FY, False, 1, root, rim)
    d = ImageDraw.Draw(img)
    d.text((44, 8), "unspent", fill=ink, font=_font(12))
    d.text((164, 8), "spent", fill=ink, font=_font(12))
    strips.append((img, "A1b  at level_1's real 47x38 (off the 16 grid) <- what you ship"))

    # D45 之后落盘的 terminal_saved **本身就是 B2**。所以被否的三行必须拿"改之前那张"来演，
    # 否则等于用选定方案去演示被否方案。
    legacy = Image.new("RGBA", (32, 12), (0, 0, 0, 0))
    paint_terminal(legacy, p, 16, 12, "saved")
    for cid, label in (("B0", "B0  CURRENT  before / swap frame / after"),
                       ("B1", "B1  current + one-shot rising pulse"),
                       ("B2", "B2  SHIPPED  after = extra always-on tier (part is 44x16)"),
                       ("B3", "B3  after = beacon behind the terminal, reads at distance")):
        img = context_strip(p, terrain, decor, W, H, FY)
        d = ImageDraw.Draw(img)
        for i, cx in enumerate((44, 124, 204)):
            if i == 0:
                _paste_ground(img, term["terminal_idle"], cx, FY)
            else:
                _paste_ground(img, term["terminal_saved"] if cid == "B2" else legacy, cx, FY)
            if cid == "B1" and i == 1:
                paint_cp_pulse(img, p, cx, FY, 2, 235)
            if cid == "B1" and i == 2:
                paint_cp_pulse(img, p, cx, FY, 16, 70)
            if cid == "B3" and i == 2:
                paint_beacon(img, p, cx, FY, "saved")
                _paste_ground(img, legacy, cx, FY)
            d.text((cx - 3, FY + 6), str(i + 1), fill=ink, font=_font(14))
        G.paste_slime(img, "idle", 2, 124, FY, False, 1, root, rim)
        strips.append((img, label))

    wide = context_strip(p, terrain, decor, 496, 188, 172)
    dw = ImageDraw.Draw(wide)
    paint_altar_steps(wide, p, 96, 172, AW, AH, False)
    _paste_ground(wide, term["terminal_idle"], 196, 172)
    _paste_ground(wide, term["terminal_saved"], 300, 172)
    G.paste_slime(wide, "run", 1, 240, 172, False, 1, root, rim)
    dw.text((182, 6), "not saved", fill=ink, font=_font(12))
    dw.text((276, 6), "saved (B2)", fill=ink, font=_font(12))
    dw.text((60, 6), "altar unspent", fill=ink, font=_font(12))

    gap, pad, cap = 20, 16, 22
    strip_w = strips[0][0].width * ZOOM
    cw = pad * 2 + strip_w * 2 + gap
    pairs = [strips[i:i + 2] for i in range(0, len(strips), 2)]
    cells, y = [], pad + cap
    for pr in pairs:
        hh = max(im.height for im, _ in pr) * ZOOM
        cells.append((y, hh))
        y += hh + 26 + gap
    ch = y + wide.height * ZOOM + 26 + pad
    canvas = Image.new("RGB", (cw, ch), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    d.text((pad, 6), "ALTAR ART (A0..A3)  /  CHECKPOINT FEEDBACK (B0..B3)   shipped style %s"
           "   B rows = 1 before / 2 that frame / 3 after" % G.SHIPPED,
           fill=ink, font=_font(14))
    for (y0, hh), pr in zip(cells, pairs):
        for col, (img, label) in enumerate(pr):
            up = img.convert("RGB").resize((img.width * ZOOM, img.height * ZOOM), Image.NEAREST)
            x = pad + col * (strip_w + gap)
            canvas.paste(up, (x, y0))
            d.text((x, y0 + hh + 4), label, fill=ink, font=_font(12))
    y0 = cells[-1][0] + cells[-1][1] + 26 + gap
    up = wide.convert("RGB").resize((wide.width * ZOOM, wide.height * ZOOM), Image.NEAREST)
    canvas.paste(up, (pad, y0))
    d.text((pad, y0 + up.height + 4), "panorama: can you still tell them apart at distance"
           " <- judge this one", fill=ink, font=_font(12))
    out = os.path.join(out_dir, "preview_altar.png")
    canvas.save(out)
    print("saved", out, canvas.size)


# ---------------------------------------------------------------- 彩蛋收集物（D54）
# 用户在两张选型图（tools/gen_collectible_preview.py 的皮、gen_collectible_spin_preview.py
# 的转台档位）上批了：**小黄鸭 + B 档三视图挤压换视图 + 拿走了留空座**。
# 和 M5 / 祭坛同一套纪律（D34）：下面这几个函数就是那两张图里跑过的**同一个调用**，
# 逐字搬过来，不许"重新画一遍长得像的"—— 落盘像素必须和他批的那张逐位相同。
# `--emit` 会校验两个预览脚本重跑后输出 md5 不变（人工做，见 D54）。
#
# 三视图而不是两张：B 档的算式是"最近轴 + |cos(与轴心夹角)| 横向挤压"，四轴向里
# front/back 对称、side 靠镜像，所以真正需要的原画只有正/侧/背三张。三张**必须同尺寸**
# （12x11）—— 换视图时盒子一缩，鸭子会在底座上跳上跳下。
# 配色全从 g 调色板推导（主体 accent2 = 琥珀那档，D29 的"可拾取"），没有字面色，
# 所以 props.json 只登记尺寸、不登记颜色。撞色（对能量卡 cr=1.14）是用户看过数字后
# 明确接受的（"撞色问题不大"）—— 记在这儿，别下次看到又当新问题重提。

DUCK_W = 12
DUCK_H = 11
PERCH_W = 14
PERCH_H = 5


def _cv(w, h):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def part_duck_front(p):
    """正脸 12x11：两只眼 + 居中的喙。玩家认得出来的那一面。"""
    img = _cv(DUCK_W, DUCK_H)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 4, 11, 10], fill=a)
    d.ellipse([2, 0, 9, 6], fill=G.lighter(a, 0.18))
    d.rectangle([3, 2, 3, 3], fill=p["edge"])
    d.rectangle([8, 2, 8, 3], fill=p["edge"])
    d.rectangle([5, 3, 6, 4], fill=G.darker(a, 0.42))
    d.rectangle([2, 7, 9, 8], fill=G.darker(a, 0.20))
    return _rim(img, p)


def part_duck_side(p):
    """侧脸 12x11：喙朝右、尾在左、只留一只眼、身上一块翅。"""
    img = _cv(DUCK_W, DUCK_H)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([1, 4, 11, 10], fill=a)
    d.ellipse([4, 0, 10, 6], fill=G.lighter(a, 0.18))
    d.rectangle([10, 2, 11, 3], fill=G.darker(a, 0.42))
    d.rectangle([7, 1, 8, 2], fill=p["edge"])
    d.rectangle([0, 3, 2, 6], fill=a)
    d.rectangle([3, 6, 7, 8], fill=G.darker(a, 0.22))
    return _rim(img, p)


def part_duck_back(p):
    """背面 12x11：没有脸 —— 两簇尾羽 + 一道背缝。这条读不读得出来是"转过去了"。"""
    img = _cv(DUCK_W, DUCK_H)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 4, 11, 10], fill=G.darker(a, 0.10))
    d.ellipse([2, 0, 9, 6], fill=a)
    d.rectangle([5, 0, 6, 9], fill=G.darker(a, 0.30))
    d.rectangle([2, 8, 4, 10], fill=G.lighter(a, 0.24))
    d.rectangle([7, 8, 9, 10], fill=G.lighter(a, 0.24))
    return _rim(img, p)


def part_perch(p, taken, dim=False):
    """公共底座 14x5：所有候选共用同一只，选型时比的是"上面那只"而不是座子。
    taken=True 时顶面多一道压痕（比座子更暗的一档）—— 这就是"拿走了"的收据（D54 裁定⑤）。
    dim=True 是收据的**加强档**：连顶面那条亮线一起灭掉。选型时放进来是因为留痕那条读数
    实测只有"整只消失"的四到六成（座子占 footprint 两成像素、两态一字不差），用户取了
    默认档，所以落盘走 dim=False —— 旋钮留着是给下次换主意的人，不是废码。"""
    img = _cv(PERCH_W, PERCH_H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 13, 4], fill=p["deep"])
    d.rectangle([0, 0, 13, 4], outline=p["lip"] if not dim else G.darker(p["lip"], 0.62))
    d.rectangle([0, 0, 13, 0], fill=p["edge"] if dim else G.lighter(p["metal"], 0.16))
    d.rectangle([0, 4, 13, 4], fill=p["edge"])
    if taken:
        d.rectangle([2, 1, 11, 2], fill=G.mix(p["screen"], p["deep"], 0.35))
        d.rectangle([2, 1, 11, 1], fill=p["screen"])
    return img


def duck_perched(p, view, taken, dim=False):
    """零件坐在底座上：宽对齐 14、水平居中、鸭子底边贴底座顶边。
    两态共用同一个盒子尺寸（`taken` 只决定顶不顶那只、座子上有没有压痕），
    否则"留痕"那条 cr 的分母会跟着盒子大小一起漂。选型图与构件都走这一份算式。
    `dim` 是底座那个收据加强档的旋钮，构件不用它（落盘走默认档），选型图要它才能画出对照。"""
    img = _cv(PERCH_W, view.height + PERCH_H)
    if not taken:
        img.paste(view, ((PERCH_W - view.width) // 2, 0), view)
    sock = part_perch(p, taken, dim)
    img.paste(sock, (0, view.height), sock)
    return img


def make_collectible_parts(p):
    """D54 落盘五张：三视图 + 底座两态。构件按角度换前三种、按 spent 换后两种。"""
    return {
        "duck_front": part_duck_front(p),
        "duck_side": part_duck_side(p),
        "duck_back": part_duck_back(p),
        "perch_idle": part_perch(p, False),
        "perch_taken": part_perch(p, True),
    }


def main():
    import sys
    if "--emit" in sys.argv:
        emit_parts()
        return
    if "--m5" in sys.argv:
        m5_sheet()
        return
    if "--m5final" in sys.argv:
        m5_final()
        return
    if "--m5door" in sys.argv:
        m5_door()
        return
    if "--altar" in sys.argv:
        altar_sheet()
        return
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "props")
    os.makedirs(out_dir, exist_ok=True)
    p = G.STYLES["ab"]
    terrain = G.build_terrain_atlas(p)
    decor = G.build_decor_atlas(p)

    rows = door_row(p, terrain, decor, root) + button_row(p, terrain, decor, root)
    pr = parts_row(p)
    gap, pad = 24, 16
    strip_w = rows[0][0].width * ZOOM
    W = pad * 2 + strip_w * 2 + gap
    H = pad + 22 + (rows[0][0].height * ZOOM + 18 + gap) + (rows[2][0].height * ZOOM + 18 + gap) + pr.height + pad
    canvas = Image.new("RGB", (W, H), (188, 195, 205))
    d = ImageDraw.Draw(canvas)
    d.text((pad, 6), "DOOR / BUTTON PLATE  lab-style art (shipped: M2 dark steel + B1 amber)  "
                     "/  bottom row = tiling parts x6",
           fill=(24, 28, 34), font=_font(14))
    y_door = pad + 22
    y_button = y_door + rows[0][0].height * ZOOM + 18 + gap
    for i, (img, label) in enumerate(rows):
        col, row = i % 2, i // 2
        x = pad + col * (strip_w + gap)
        y = y_door if row == 0 else y_button
        up = img.convert("RGB").resize((img.width * ZOOM, img.height * ZOOM), Image.NEAREST)
        canvas.paste(up, (x, y))
        d.text((x, y + up.height + 3), label, fill=(24, 28, 34), font=_font(12))
    y = y_button + rows[2][0].height * ZOOM + 18 + gap
    canvas.paste(pr, (pad, y))
    out = os.path.join(out_dir, "preview_props.png")
    canvas.save(out)
    print("saved", out)


if __name__ == "__main__":
    main()
