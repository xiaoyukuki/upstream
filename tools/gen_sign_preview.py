"""无字告示牌选型图（D56）：不许出现字，那「前方有卡」与「此门需卡」这两句靠什么说。

用法：py tools/gen_sign_preview.py   ->  assets/props/preview_sign.png

牌面只有三样可用：**形状 / 颜色 / 挂在哪儿**。三样都拿已经在册的语汇：
琥珀 = 可拾取（D29，且 D36 那颗 LED 与卡同色是「这把开那扇」的一对）、卡形 = 14x10 那只、
两截轮廓 = D55 刚落盘的「卡 + 公共底座」、亮边描边 = 夜光风格（g）里唯一拉得开暗墙的东西。

两块底片都不是画的：A 块 = `spot0_raw.png`（D54/D55 用过的那块空地板，分母盒照抄，
三张图的读数才可比）；B 块 = `spot2_raw.png`（D53 用过的那道**真刷卡门**，LED 就在画面里）。
每行三格：裸帧 / 套 CRT（真账 —— 玩家看见它的任何一刻都必然按着方向键、必然套着这层）/ 1:1 真机。

要量的四条账：
  1. **牌框对那面墙**：预期只有 1.1 上下（`deep` 56,66,100 对 `bg` 74,84,118）。若真如此，
     「牌」这块东西在夜光风格里是隐形的，能说话的只剩那圈亮边与屏上的图形 —— 整张图的画法
     就得围着这条改（D55 那只座子 cr=1.04 是同一个发现）。
  2. **屏上的图形对屏**（琥珀对 `screen` 18,24,40）—— 这一条才是「读不读得出画的是什么」。
  3. **满 vs 空 分不分得开**：实心琥珀卡 = 「那里有一只」，只有亮轮廓的空槽 = 「这里该有一只、
     现在没有」。两句共用一块牌，所以这条是整个方案的命门；底部家族图就是它的当场检验。
  4. **牌上那张卡 vs 真的那只**（D55 坐在底座上的实物）同框差多少 —— 分不清就是「走过去想抠一块墙皮」。
"""

import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                      # _cr / _font / lighter / darker / mix
import gen_freeze_filter_preview as F      # crt()：D46 已验过它与实机 shader 对得上
import gen_props as P                      # _rim / part_perch：落盘零件的单一来源
import gen_gate_alert_preview as A         # _mean / _zoom / _wrap：与 D53 同一量法
import gen_collectible_preview as C        # 与 D54/D55 同一块地板、同一条算式、同一批分母盒

FRAME_B = os.path.join(ROOT, "assets", "ui", "frames", "spot2_raw.png")
OUT = os.path.join(ROOT, "assets", "props", "preview_sign.png")

PAL = C.PAL
CRT = C.CRT
CARD = Image.open(C.CARD_PNG).convert("RGBA")
Z = 3                                     # 放大格 3 倍：牌 16 见方，4 倍会把整张图撑爆
POST_H = 32                               # 立式牌多占的那一格（世界像素）

# B 块：牌贴在真门左侧那块暗墙上，与那颗 LED 同高（LED 核心实测 994..997 / 236..239 设备像素）。
PLATE_CX, PLATE_BY = 934, 260             # 设备：牌水平中心 / 底边
B_WALL = (880, 224, 910, 264)             # 牌左侧一块纯墙（分母）
B_CROP = (PLATE_CX - 56, 206, PLATE_CX + 92, 300)   # 把牌与那颗 LED 都框进来


# ------------------------------------------------------------------ 零件（世界像素）

def _cv(w, h):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def g_card(d, p, scr):
    """实心琥珀卡（图章）：卡体 + 一条暗磁条 + 一颗青芯片 —— 与落盘那只 14x10 同一套部件，
    只是压扁进屏里。这是「那里有一只」那一句。"""
    x0, y0, x1, y1 = scr
    cw, ch = 10, 7
    cx = x0 + ((x1 - x0 + 1) - cw) // 2
    cy = y0 + ((y1 - y0 + 1) - ch) // 2
    a = p["accent2"]
    d.rectangle([cx, cy, cx + cw - 1, cy + ch - 1], fill=a)
    d.rectangle([cx, cy, cx + cw - 1, cy], fill=G.lighter(a, 0.44))
    d.rectangle([cx, cy + 4, cx + cw - 1, cy + 5], fill=G.darker(a, 0.52))
    d.rectangle([cx + 1, cy + 1, cx + 2, cy + 2], fill=p["accent"])
    return (cx, cy, cx + cw - 1, cy + ch - 1)


def g_card_perched(d, p, scr):
    """卡 + 两截底座轮廓（D55 落地那一只的剪影）：读的是「台阶」，不是「一块琥珀」。"""
    x0, y0, x1, y1 = scr
    cw, ch, pw = 9, 6, 12
    cx = x0 + ((x1 - x0 + 1) - cw) // 2
    px0 = x0 + ((x1 - x0 + 1) - pw) // 2
    cy = y0 + 1
    a = p["accent2"]
    d.rectangle([cx, cy, cx + cw - 1, cy + ch - 1], fill=a)
    d.rectangle([cx, cy, cx + cw - 1, cy], fill=G.lighter(a, 0.44))
    d.rectangle([cx, cy + 3, cx + cw - 1, cy + 3], fill=G.darker(a, 0.52))
    py = cy + ch + 1
    d.rectangle([px0, py, px0 + pw - 1, py + 2], fill=p["metal"])
    d.rectangle([px0, py, px0 + pw - 1, py], fill=G.lighter(p["metal"], 0.30))
    d.rectangle([px0, py + 2, px0 + pw - 1, py + 2], fill=p["lip"])
    return (min(cx, px0), cy, max(cx + cw - 1, px0 + pw - 1), py + 2)


def _socket_at(d, p, cx, cy, cw, ch):
    """卡形**空心槽**：里面比屏还暗一档 + 一圈亮轮廓 + 槽口那道亮唇。
    「这里该有一张，现在没有」——牌面上一颗琥珀像素都没有，所以它不跟那颗琥珀灯抢「能捡」那一档。"""
    d.rectangle([cx, cy, cx + cw - 1, cy + ch - 1], fill=G.darker(p["screen"], 0.45))
    d.rectangle([cx, cy, cx + cw - 1, cy + ch - 1], outline=p["lip"])
    d.rectangle([cx, cy, cx + cw - 1, cy], fill=G.darker(p["lip"], 0.60))
    d.rectangle([cx + 1, cy + ch - 1, cx + cw - 2, cy + ch - 1], fill=G.lighter(p["lip"], 0.05))


def g_socket(d, p, scr):
    x0, y0, x1, y1 = scr
    cw, ch = 10, 7
    cx = x0 + ((x1 - x0 + 1) - cw) // 2
    cy = y0 + ((y1 - y0 + 1) - ch) // 2
    _socket_at(d, p, cx, cy, cw, ch)
    return (cx, cy, cx + cw - 1, cy + ch - 1)


def g_socket_plus(d, p, scr):
    """空槽 + 槽上方一枚小实心卡：两句合一句 ——「把这个塞进这里」。"""
    x0, y0, x1, y1 = scr
    cw, ch = 10, 7
    cx = x0 + ((x1 - x0 + 1) - cw) // 2
    cy = y0 + 4
    a = p["accent2"]
    d.rectangle([cx + 2, y0, cx + 7, y0 + 2], fill=a)
    d.rectangle([cx + 2, y0, cx + 7, y0], fill=G.lighter(a, 0.44))
    _socket_at(d, p, cx, cy, cw, ch)
    return (cx, y0, cx + cw - 1, cy + ch - 1)


def g_card_curtain(d, p, scr):
    """卡 + 两缕青色光幕竖条并排：最字面的「这张开这扇门」。代价是牌面上出现第二种色相，
    而青在 D29 之后是「灯 / 运行」那一档。"""
    x0, y0, x1, y1 = scr
    a = p["accent2"]
    d.rectangle([x0 + 1, y0 + 3, x0 + 6, y0 + 9], fill=a)
    d.rectangle([x0 + 1, y0 + 3, x0 + 6, y0 + 3], fill=G.lighter(a, 0.44))
    d.rectangle([x0 + 1, y0 + 7, x0 + 6, y0 + 7], fill=G.darker(a, 0.52))
    for i, bx in enumerate((x1 - 3, x1 - 1)):
        d.rectangle([bx, y0, bx, y1 - 1],
                    fill=p["accent"] if i == 0 else G.darker(p["accent"], 0.30))
    return (x0 + 1, y0, x1 - 1, y1 - 1)


def _arrow(d, x, ymid, col):
    """一枚 7 px 宽的右箭头：杆 4x3 + 三列阶梯的头。全用矩形拼 —— 这项目的零件没有一处
    斜线是抗锯齿画出来的（尖刺、卡齿、门底警示条都是矩形阶梯），箭头不能例外。"""
    d.rectangle([x, ymid - 1, x + 3, ymid + 1], fill=col)
    d.rectangle([x + 4, ymid - 3, x + 4, ymid + 3], fill=col)
    d.rectangle([x + 5, ymid - 2, x + 5, ymid + 2], fill=col)
    d.rectangle([x + 6, ymid - 1, x + 6, ymid + 1], fill=col)
    return (x, ymid - 3, x + 6, ymid + 3)


def g_card_arrow_amber(d, p, scr):
    """卡 + 右箭头，**同一种琥珀**：读成一句完整的话「这张卡 → 在这边」。
    代价：箭头与卡同色，方向与物件在语义上没分家（分不清哪半是"要拿的东西"）。"""
    x0, y0, x1, y1 = scr
    cx, cy = x0 + 1, y0 + ((y1 - y0 + 1) - 7) // 2
    a = p["accent2"]
    d.rectangle([cx, cy, cx + 9, cy + 6], fill=a)
    d.rectangle([cx, cy, cx + 9, cy], fill=G.lighter(a, 0.44))
    d.rectangle([cx, cy + 4, cx + 9, cy + 5], fill=G.darker(a, 0.52))
    d.rectangle([cx + 1, cy + 1, cx + 2, cy + 2], fill=p["accent"])
    ax, ay, axr, ayr = _arrow(d, x1 - 7, (y0 + y1) // 2, a)
    return (cx, min(cy, ay), max(cx + 9, axr), max(cy + 6, ayr))


def g_card_arrow_white(d, p, scr):
    """卡 + 右箭头，**箭头走牌框那圈亮白**：物件是琥珀、方向是白 —— 与"能捡"那一档分开。"""
    x0, y0, x1, y1 = scr
    cx, cy = x0 + 1, y0 + ((y1 - y0 + 1) - 7) // 2
    a = p["accent2"]
    d.rectangle([cx, cy, cx + 9, cy + 6], fill=a)
    d.rectangle([cx, cy, cx + 9, cy], fill=G.lighter(a, 0.44))
    d.rectangle([cx, cy + 4, cx + 9, cy + 5], fill=G.darker(a, 0.52))
    d.rectangle([cx + 1, cy + 1, cx + 2, cy + 2], fill=p["accent"])
    ax, ay, axr, ayr = _arrow(d, x1 - 7, (y0 + y1) // 2, p["lip"])
    return (cx, min(cy, ay), max(cx + 9, axr), max(cy + 6, ayr))


GLYPHS = {"card": g_card, "perched": g_card_perched, "socket": g_socket,
          "socket_plus": g_socket_plus, "card_curtain": g_card_curtain,
          "card_arrow_amber": g_card_arrow_amber, "card_arrow_white": g_card_arrow_white}


def _arrow_body(d, x0, x1, y0, y1, hw, col):
    """箭头形牌的外轮廓：左半是杆（y0..y1），右半 hw 列是阶梯头（撑满整块牌的高）。
    画两遍（先亮白、再往里缩 1 px 填暗色）就是那圈描边 —— 与 rect 那档同一个套路。
    阶差的上限取 h//2-1 而不是 h//2：取后者时最末一列会算出 lo > h-1-lo，矩形反过来、
    箭头的尖直接消失（16 高的牌上正好踩中）。"""
    h = y1 - y0 + 1
    lim = max(1, h // 2 - 1)
    d.rectangle([x0, y0, x1 - hw, y1], fill=col)
    for k in range(hw):
        lo = (k * lim) // (hw - 1)
        d.rectangle([x1 - hw + 1 + k, y0 + lo, x1 - hw + 1 + k, y1 - lo], fill=col)


#: 定案要落盘的两块牌（D56：A5 + B3）。选型图这里只当搬运工 —— 画法在 gen_tiles.sign_plate，
#: 图集与这张选型图吃的是同一个函数，定案时看见的皮与出货的皮逐字节相同。
SHIP = {"card": "card", "card_arrow_white": "arrow"}


def sign_plate(p, glyph, w=16, h=16, post=0, shape="rect"):
    """一块夜光标牌：钢框 + 一圈亮边 + 一块近黑的屏 + 屏上那个图形。
    返回 (art, rects)。rects 是 frame / screen / glyph 三块在 **art 本地世界像素**里的闭区间 ——
    贴进真帧后换算成设备盒再量，量的必须是同一批点而不是外接盒（D54 那条）。
    post>0 时下面多一格立柱（4 px 粗 + 一小块底座），立式牌那档走这条；
    shape="arrow" 时整块牌本身就是一个右箭头（现实里的指路牌），屏只开在杆上。"""
    if not post and shape == "rect" and glyph in SHIP:
        img = _cv(w, h)
        scr, gly = G.sign_plate(ImageDraw.Draw(img, "RGBA"), p, 0, 0, SHIP[glyph])
        return img, {"frame": (0, 0, w - 1, h - 1), "screen": scr, "glyph": gly}
    img = _cv(w, h + post)
    d = ImageDraw.Draw(img, "RGBA")
    if post:
        px0 = (w - 4) // 2
        d.rectangle([px0, h, px0 + 3, h + post - 2], fill=p["metal"])
        d.rectangle([px0, h, px0, h + post - 2], fill=G.lighter(p["metal"], 0.28))
        d.rectangle([px0 + 3, h, px0 + 3, h + post - 2], fill=G.darker(p["metal"], 0.35))
        d.rectangle([px0 - 2, h + post - 2, px0 + 5, h + post - 1], fill=p["deep"])
        d.rectangle([px0 - 2, h + post - 2, px0 + 5, h + post - 2], fill=p["lip"])
    hw = 12
    if shape == "arrow":
        _arrow_body(d, 0, w - 1, 0, h - 1, hw, p["lip"])
        _arrow_body(d, 1, w - 2, 1, h - 2, hw - 1, p["deep"])
        d.rectangle([1, 2, w - hw - 2, 2], fill=G.lighter(p["metal"], 0.20))
        sx0, sy0, sx1, sy1 = 3, 4, w - hw - 2, h - 5
        d.rectangle([sx0, sy0, sx1, sy1], fill=p["screen"])
        d.rectangle([sx0, sy0, sx1, sy1], outline=G.darker(p["lip"], 0.62))
    else:
        d.rectangle([0, 0, w - 1, h - 1], fill=p["deep"])
        d.rectangle([0, 0, w - 1, h - 1], outline=p["lip"])
        d.rectangle([0, 0, w - 1, 0], fill=G.lighter(p["metal"], 0.20))
        d.rectangle([0, h - 1, w - 1, h - 1], fill=G.darker(p["metal"], 0.45))
        sx0, sy0, sx1, sy1 = 2, 3, w - 3, h - 3
        d.rectangle([sx0, sy0, sx1, sy1], fill=p["screen"])
        d.rectangle([sx0, sy0, sx1, sy1], outline=G.darker(p["lip"], 0.62))
    rects = {"frame": (0, 0, w - 1, h - 1), "screen": (sx0, sy0, sx1, sy1)}
    rects["glyph"] = GLYPHS[glyph](d, p, (sx0, sy0, sx1, sy1))
    return P._rim(img, p), rects


# ------------------------------------------------------------------ 贴帧与量取

def _paste_at(frame, art, cx, bottom):
    """按真机比例贴进真帧：水平中心在 cx、底边在 bottom（都是设备像素）。"""
    dev = art.resize((art.width * 2, art.height * 2), Image.NEAREST)
    out = frame.copy()
    out.paste(dev, (cx - dev.width // 2, bottom - dev.height), dev)
    return out


def _dev_box(rect, ox, oy):
    """art 本地世界像素闭区间 -> 设备坐标闭区间（ox,oy = art 左上角落在设备上的位置）。"""
    return (ox + rect[0] * 2, oy + rect[1] * 2, ox + rect[2] * 2 + 1, oy + rect[3] * 2 + 1)


def _pts(box):
    x0, y0, x1, y1 = box
    return [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]


def _alpha_pts(art, ox, oy, skip=None):
    """art 自己的**不透明像素**换成设备点。为什么「牌体对墙」这一列必须走它而不是外接盒：
    异形箭头牌的外接盒里有 1/4 是空气（两块被切掉的角），那空气在帧上就是墙本身 ——
    拿外接盒量等于把分母混进分子，读出来的 cr 永远偏向 1，正好把这条要回答的问题抹平。
    skip 用来把那圈 _rim 的贴纸描边剔掉：它是全项目统一的一档暗边（不是牌的一部分，
    每块非平铺件都带），留着会让所有行的分母同源地变暗，掩盖牌体本身够不够亮。"""
    px = art.load()
    out = []
    for wy in range(art.height):
        for wx in range(art.width):
            c = px[wx, wy]
            if c[3] < 200 or (skip is not None and c[:3] == skip):
                continue
            out.extend(((ox + wx * 2, oy + wy * 2), (ox + wx * 2 + 1, oy + wy * 2),
                        (ox + wx * 2, oy + wy * 2 + 1), (ox + wx * 2 + 1, oy + wy * 2 + 1)))
    return out


def _split_glyph(art, rect, ox, oy):
    """把屏上那个图形拆成**亮部 / 暗部**两批设备像素。
    为什么必须拆：空心槽那一句全靠一圈 1 px 亮轮廓说话（真机 2 px），整块均值会把它冲掉
    —— 上一版量出「槽对屏 1.08」就是这么来的假死信。判据取自 art 自己的颜色（不是量完帧再猜），
    所以图上画得亮不亮，与读数说的是同一件事。"""
    px = art.load()
    lit, dark = [], []
    for wy in range(rect[1], rect[3] + 1):
        for wx in range(rect[0], rect[2] + 1):
            c = px[wx, wy]
            if c[3] < 200:
                continue
            box = ((ox + wx * 2, oy + wy * 2), (ox + wx * 2 + 1, oy + wy * 2),
                   (ox + wx * 2, oy + wy * 2 + 1), (ox + wx * 2 + 1, oy + wy * 2 + 1))
            (lit if (c[0] + c[1] + c[2]) / 3.0 > 110.0 else dark).extend(box)
    return lit, dark


def measure(raw, art, rects, cx, bottom, bg_box, note, real_box=None):
    ox = cx - (art.width * 2) // 2
    oy = bottom - art.height * 2
    full = _paste_at(raw, art, cx, bottom)
    f = F.crt(full, *CRT)
    gly_rect = rects["glyph"]
    gly_dev = set(_pts(_dev_box(gly_rect, ox, oy)))
    scr_pts = [p for p in _pts(_dev_box(rects["screen"], ox, oy)) if p not in gly_dev]
    frame_m = C._mean_pts(f, _alpha_pts(art, ox, oy, PAL["edge"]))
    scr_m = C._mean_pts(f, scr_pts)
    lit, dark = _split_glyph(art, gly_rect, ox, oy)
    lit_m = C._mean_pts(f, lit)
    dark_m = C._mean_pts(f, dark)
    bg = A._mean(f, bg_box)
    m = dict(full=full, f=f, ox=ox, oy=oy, cx=cx, bottom=bottom, art=art, note=note,
             scr=scr_m, gly=lit_m, bg=bg, real_box=real_box,
             cr_frame=G._cr(frame_m, bg), cr_scr=G._cr(lit_m, scr_m), cr_bg=G._cr(lit_m, bg),
             cr_dark=(G._cr(dark_m, scr_m) if dark else 0.0),
             clip=C._clip_pts(f, lit), n=len(lit), n_dark=len(dark),
             dark_mean=dark_m, lit_mean=lit_m)
    print("%-40s 牌体对墙 %.2f | 亮部对屏 %.2f 对墙 %.2f | 暗部对屏 %.2f | 屏%s 亮%s 墙%s 削顶 %d/%d"
          % (note[:38], m["cr_frame"], m["cr_scr"], m["cr_bg"], m["cr_dark"],
             scr_m, lit_m, bg, m["clip"], m["n"]))
    return m


def blank(raw, note):
    """基线行：什么都不贴，只把底片过一遍 CRT —— 它给后面每一行当分母。"""
    f = F.crt(raw, *CRT)
    return dict(full=raw, f=f, ox=0, oy=0, art=None, note=note)


def sheet_row(out, y, small, big, m, crop, label, lines):
    """一行 = 说明列 + 裸帧 + 套 CRT + 1:1 真机 + 读数列。"""
    d = ImageDraw.Draw(out)
    cw, ch = (crop[2] - crop[0] + 1) * Z, (crop[3] - crop[1] + 1) * Z
    d.text((10, y + 2), label, fill=(228, 236, 248), font=big)
    for i, t in enumerate(A._wrap(d, m["note"], small, 384, 6)):
        d.text((10, y + 30 + i * 16), t, fill=(150, 164, 186), font=small)
    if m["art"] is not None:
        out.paste(A._zoom(m["full"], crop, Z), (400, y + 10))
        out.paste(A._zoom(m["f"], crop, Z), (400 + cw + 10, y + 10))
        rb = m["real_box"] or (m["ox"] - 44, m["oy"] - 8, m["ox"] + 76, m["oy"] + 96)
        real = m["f"].crop(rb)
        rx = 400 + cw * 2 + 24
        out.paste(real, (rx, y + 10))
        d.rectangle([rx, y + 10, rx + real.width - 1, y + 9 + real.height], outline=(40, 50, 66))
        x = rx + real.width + 24
        h = max(ch, real.height)
    else:
        out.paste(A._zoom(m["f"], crop, Z), (400, y + 10))
        x = 400 + cw + 20
        h = ch
    for i, t in enumerate(lines):
        d.text((x, y + 14 + i * 19), t,
               fill=(250, 190, 74) if i == len(lines) - 1 else (190, 205, 226), font=small)
    d.text((400, y + 12 + ch), "裸帧（留档）", fill=(150, 164, 186), font=small)
    if m["art"] is not None:
        d.text((400 + cw + 10, y + 12 + ch), "套 CRT（真账）", fill=(150, 164, 186), font=small)
        d.text((400 + cw * 2 + 24, y + 12 + ch), "1:1 真机", fill=(150, 164, 186), font=small)
    return 10 + h + 46


def main():
    raw_a = Image.open(C.FRAME).convert("RGB")
    pxa = raw_a.load()
    floor_y, best = 0, -1
    for y in range(*C.FLOOR_SEARCH):
        t = 0
        for x in range(C.SPOT_X - 60, C.SPOT_X + 60):
            c = pxa[x, y]
            t += c[0] + c[1] + c[2]
        if t > best:
            best, floor_y = t, y
    wall_box = (C.SPOT_X - 96, floor_y - 56, C.SPOT_X - 64, floor_y - 24)
    raw_b = Image.open(FRAME_B).convert("RGB")
    print("自检：spot0 地面亮线 y=%d（与 D54/D55 同一块地板）" % floor_y)

    small, big = C._font(12), C._font(19)
    crop_a = (C.SPOT_X - 96, floor_y - 112, C.SPOT_X + 48, floor_y + 8)
    real_a = (C.SPOT_X - 72, floor_y - 112, C.SPOT_X + 72, floor_y + 8)
    real_b = (PLATE_CX - 60, B_CROP[1], PLATE_CX + 60, B_CROP[3])
    ch_a = crop_a[3] - crop_a[1] + 1
    out = Image.new("RGB", (1820, 70 + 16 * (ch_a * Z + 110) + 700), (12, 15, 23))
    d = ImageDraw.Draw(out)
    y = 12
    d.text((10, y), "无字告示牌（D56）  A 块底片 = spot0 那块空地板（与 D54/D55 同一条尺子）  "
                    "B 块底片 = spot2 那道真刷卡门", fill=(214, 224, 240), font=small)
    y += 34
    d.text((10, y), "A 块 「前方有钥匙卡」：挂在走廊侧的墙上。它补的正是 D53 那颗灯当不了远处"
                    "路标那个洞（发红只持续 0.09 s 的行程）", fill=(250, 190, 74), font=big)
    y += 26
    d.text((10, y), "箭头那一档的代价先摆在这：TileMapLayer 不能逐格翻转，左指右指各要一格图集",
           fill=(250, 190, 74), font=big)
    y += 30

    m = blank(raw_a, "对照行：那块墙上什么都没有。后面每一行的「对墙」分母都从这块墙上取，"
                     "所以这一行不量图形，只给你看今天的现场。")
    y += sheet_row(out, y, small, big, m, crop_a, "A0 现状 · 什么都没有（基线）",
                  ("墙 mean = 后面各行的分母",
                   "牌框（deep）对墙预期只有 1.1 上下：那块钢本身是隐形的",
                   "所以整块牌的可见度必须由那圈亮边 + 屏上图形承担",
                   "—— D55 那只座子 cr=1.04 就是这个发现",
                   "本列改动：「牌体对墙」现在按 art 自己的不透明像素量",
                   "（异形牌的外接盒含空气，会把读数拉向 1），数字与上一版不可直接比"))

    for label, glyph, post, kw, note in (
        ("A1 一格 16x16 · 实心琥珀卡（图章）｜你选中的那张", "card", 0, {},
         "牌 = 钢框 + 一圈亮边 + 一块近黑的屏；屏上那只卡是落盘那只 14x10 的剪影压扁一档，"
         "磁条与青芯片都留着 —— 它是「画着一只卡」，不是「一只卡」。挂在离地 16 px 的墙上"),
        ("A2 一格 16x16 · 卡 + 两截底座（D55 轮廓）", "perched", 0, {},
         "把 D55 刚落盘那条形状语言搬上屏：卡下面那道台阶就是「坐在座上」。赌的是牌子与实物"
         "共用同一张剪影，玩家一眼认得出「就是那玩意儿」"),
        ("A3 两格 16x32 · 立在地上的牌", "card", POST_H, {},
         "同一块牌，下面多一格柱子 —— A1~A3 里唯一「站」在地面上的一档。代价：它占两格"
         "图集，柱脚必须落在空格子里（装饰叠在地形格上会消失，手册 §12）"),
        ("A4 两格 32x16 横牌 · 卡 + 琥珀右箭头", "card_arrow_amber", 0, dict(w=32),
         "你要的那句话的直译：「这张卡 → 在这边」。横牌比方块更像告示牌，因为卡与箭头终于"
         "各占一半而不是叠在一处。代价：箭头与卡同一种琥珀，方向与物件在语义上没分家"),
        ("A5 两格 32x16 横牌 · 卡 + 亮白右箭头", "card_arrow_white", 0, dict(w=32),
         "同样的话，把箭头换成牌框那圈亮白：琥珀只留给「能捡的东西」，白只管「往这边走」。"
         "语义最干净的一档；赌的是白色箭头不会被读成「又一块牌框」而丢掉方向"),
        ("A6 两格 32x16 · 整块牌就是一个右箭头", "card", 0, dict(w=32, shape="arrow"),
         "现实里指路牌的做法：轮廓即方向，屏只开在杆上。最「像告示牌」的一档 —— 远处先读到"
         "的是朝向，走近才读出屏里那只卡。代价：屏被压到 16x8，那只卡只剩 A1 的七成"),
        ("A7 32x48 立式横牌 · 卡 + 琥珀右箭头 + 柱", "card_arrow_amber", POST_H, dict(w=32),
         "A4 那块横牌插在一格柱子上，站在地面上 —— 轮廓给方向、柱子给「这是一块牌子」。"
         "四档横牌里最像实体告示牌，也最贵：占 3 格图集（32 宽 x 3 高）"),
    ):
        art, rcs = sign_plate(PAL, glyph, post=post, **kw)
        m = measure(raw_a, art, rcs, C.SPOT_X, floor_y if post else floor_y - 32,
                    wall_box, note, real_a)
        y += sheet_row(out, y, small, big, m, crop_a, label,
                      ("牌体对墙 cr=%.2f（钢本身隐形 = 预期）" % m["cr_frame"],
                       "图形亮部：对屏 cr=%.2f   对墙 cr=%.2f" % (m["cr_scr"], m["cr_bg"]),
                       "图形暗部：对屏 cr=%.2f" % m["cr_dark"],
                       "屏 %s | 亮部 %s | 墙 %s" % (m["scr"], m["lit_mean"], m["bg"]),
                       "亮部 %d px，被 CRT 削顶 %d px" % (m["n"], m["clip"]),
                       "「亮部对屏」= 读不读得出画的是什么；最后一行才是真机尺寸"))

    d.text((10, y + 4), "B 块 「这个门需要钥匙卡」：牌贴在门左侧那块墙上，与那颗琥珀 LED 同高。"
                        "满 / 空 用的是同一块牌、同一个卡形 —— 两句只差「那张卡在不在」",
           fill=(250, 190, 74), font=big)
    y += 32

    m = blank(raw_b, "对照行：今天那道门，只有 D53 那颗灯。它是**即时回执**（「你马上就要撞上"
                     "一扇不认你的门」），不是「这扇门要什么」的说明书 —— 这正是 B 块要补的那句话。")
    y += sheet_row(out, y, small, big, m, B_CROP, "B0 现状 · 只有那颗 LED（基线）",
                  ("那颗 LED 核心实测 (250,190,74)",
                   "灯与卡同属琥珀一家：D36「这把开那扇」是刻意的",
                   "B 块的牌不许把它顶掉，也不许读成「第二颗灯」",
                   "—— 所以 B1 起牌面上一颗琥珀像素都不放（见 B3/B4 的代价）"))

    for label, glyph, kw, note in (
        ("B1 一格牌 · 卡形空心槽", "socket", {},
         "里面比屏再暗一档 + 一圈亮轮廓 + 槽口那道亮唇 = 「这里该有一张，现在没有」。牌面上一颗"
         "琥珀都没有，所以它不跟那颗灯抢语义；它说的也不是「能捡」"),
        ("B2 空心槽 + 槽上一枚小实心卡", "socket_plus", {},
         "两句合一句：把这只塞进这里。代价是牌面上同时出现「满」与「空」，与 A 块那块实心卡"
         "撞在同一格上 —— 玩家得先分清这两块牌谁是谁"),
        ("B3 一格牌 · 实心卡（与 A1 同一枚）", "card", {},
         "把 A 块那句话原封贴到门侧：读的是「这扇门 ↔ 卡」。但它与 A 块是同一句话，两句会不会混，"
         "只能靠底部家族图裁"),
        ("B4 实心卡 + 两缕青色光幕", "card_curtain", {},
         "最字面的「这张开这扇门」。代价：牌面上多了第二种色相，而青在 D29 之后是「灯 / 运行」"
         "那一档 —— 这是全项目第一次让琥珀与青并排出现在同一块 16x16 里"),
        ("B5 横牌 · 空心槽（与 A4~A6 同轮廓）", "socket", dict(w=32),
         "如果 A 块最终选了横牌，门侧这块也得换成横牌 —— 两句是同一块牌子的两种屏，轮廓一换"
         "就串不成一句话。这一行是那个连带决定长什么样，不是第五个候选"),
    ):
        art, rcs = sign_plate(PAL, glyph, **kw)
        m = measure(raw_b, art, rcs, PLATE_CX, PLATE_BY, B_WALL, note, real_b)
        y += sheet_row(out, y, small, big, m, B_CROP, label,
                      ("牌框对墙 cr=%.2f" % m["cr_frame"],
                       "图形亮部：对屏 cr=%.2f   对墙 cr=%.2f" % (m["cr_scr"], m["cr_bg"]),
                       "图形暗部（槽底）：对屏 cr=%.2f" % m["cr_dark"],
                       "屏 %s | 亮部 %s | 墙 %s" % (m["scr"], m["lit_mean"], m["bg"]),
                       "亮部 %d px（另有暗部 %d px），削顶 %d" % (m["n"], m["n_dark"], m["clip"]),
                       "读数只陈述：1:1 那一格才是屏幕上真正的尺寸"))

    # 家族图：1:1 真机一排牌 + 真的那只卡坐在 D55 底座上。命门要在这一格才判得完。
    d.text((10, y + 4), "家族图（1:1 真机，只放大 2 倍）：从左到右 = 横牌·琥珀箭头 / 横牌·亮白箭头 / "
                        "异形箭头牌 / 实心卡 16 / 空心槽 / 卡+座 / **真的那只卡坐在 D55 底座上**",
           fill=(214, 224, 240), font=small)
    d.text((10, y + 20), "这一格裁三件事：① 满 vs 空 分不分得开 ② 墙上的画 vs 能捡的东西 分不分得开 "
                         "③ 三块横牌与 A1 那块方块放一条走廊里会不会混成「同一块牌的不同尺寸」",
           fill=(214, 224, 240), font=small)
    fam = raw_a.copy()
    # 家族图排在 SPOT_X **左边**：底片是 1280 宽而 SPOT_X=1150 —— 右边只剩 130 px，
    # 一排牌放得出去、裁不回来（超出帧的部分 PIL 补黑，贴出帧外的部分直接消失，
    # 上一版那只真卡就是这么从家族图上蒸发掉的）。间距按设备像素：32 世界宽的牌 = 64 设备宽。
    for glyph, cx, kw in (
        ("card_arrow_amber", 100, dict(w=32)),
        ("card_arrow_white", 200, dict(w=32)),
        ("card", 300, dict(w=32, shape="arrow")),
        ("card", 380, {}),
        ("socket", 440, {}),
        ("perched", 500, {}),
    ):
        a, _ = sign_plate(PAL, glyph, **kw)
        fam = _paste_at(fam, a, cx, floor_y - 32)
    real = _cv(14, 15)
    real.paste(CARD, (0, 0), CARD)
    real.paste(P.part_perch(PAL, False, False, 14), (0, CARD.height))
    fam = C._paste_state(fam, real, 580, floor_y)
    fam = F.crt(fam, *CRT)
    strip = A._zoom(fam, (36, floor_y - 72, 636, floor_y + 8), 2)
    out.paste(strip, (10, y + 42))
    ImageDraw.Draw(out).rectangle([10, y + 42, 10 + strip.width - 1, y + 41 + strip.height],
                                  outline=(40, 50, 66))
    final = out.crop((0, 0, out.width, min(out.height, y + 78 + strip.height)))
    final.save(OUT)
    print("WROTE %s  %dx%d" % (OUT, final.width, final.height))


if __name__ == "__main__":
    main()
