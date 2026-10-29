#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""D78 候选 · 开场遮罩的选型图 —— 底片是**真帧**，不是重画的场景。

底片由 `tools/dream_mask_shot.tscn` 在真窗口里抓：走 `main.tscn` 那条链（苏醒那一拍由常驻根
`take_intro()` 决定演不演，F6 直跑整条不在场），一枚键都不按 ⇒ 停在"四只泡挂着、人钉在睡姿"
那一拍。尺度 = 实机：1 世界像素 = 2 设备像素（相机 zoom 2、窗口 1280×720）。

为什么底片必须是抓的而不是画的：这一张要裁的是"暗下去之后还剩下多少读得出来"，
而读得出来的东西正是那面墙的砖、那四只泡与那张能量卡 —— 重画一遍就等于拿另一张图裁这一张图。

**遮罩的形状只有一条算式，住在这个文件里**：`ramp_alpha(d, r_in, w)`。落盘时那张 PNG 遮罩
由同一个函数生成（与 D77 梦泡那条"批过的图 == 出货的皮"同一手法），所以这里画的软边
就是进引擎的软边，不是它的近似。

用法：  py tools/gen_dream_mask_preview.py
产物：  assets/props/preview_dream_mask.png（静图：四档亮区 + 两档软边 + 遮罩色对照）
        assets/props/preview_dream_mask.gif（动图：睡着时呼吸两相 → 最后一发泡破后张开）
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G          # 调色板与字体的唯一来源

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "assets", "ui", "frames", "dream_mask_base.png")
OUT_PNG = os.path.join(ROOT, "assets", "props", "preview_dream_mask.png")
OUT_GIF = os.path.join(ROOT, "assets", "props", "preview_dream_mask.gif")
CARD_PNG = os.path.join(ROOT, "assets", "props", "dream_mask_card_01.png")

SCALE = 2                      # 1 世界像素 = 2 设备像素（实机 zoom 2）
PAGE_W = 1280
GAP = 10
CARD_H = 720
# 圆心 = 屏幕中心 + 弧心偏移（清单里 arc_origin_y = -5 世界像素 ⇒ 向上 10 设备像素）。
CX, CY = PAGE_W // 2, CARD_H // 2 - 10
# 一屏对角的一半：r 到这儿整屏就没有暗角了（√(320² + 180²) ≈ 366 世界像素）。
FULL_R = 366
# 四只梦泡离弧心最远的一格 = 76 世界像素（space 那只的右上角，从 dream_bubble.json 现算）。
BUBBLE_FAR = 76

MASK_RGB = G.STYLES["g"]["screen"][:3]      # (18, 24, 40) 在册近黑蓝
BLACK_RGB = (0, 0, 0)

## 弧心到屏幕最远那角的距离（世界像素）：遮罩必须一路涂到这里，不然**外圈又是亮的**
## —— 第一版就把环画到 r_out 为止，结果整张图变成"人周围一圈黑环、远处照旧清楚"，
## 与要的效果正相反。环的下界是 0，上界必须是这个数。
CORNER_R = int(math.ceil(math.hypot(max(CX, PAGE_W - CX), max(CY, CARD_H - CY)) / SCALE))

## —— 落盘那一档（他 2026-10-29 看图后一句「开始落盘」批的 = ① 卡）——
## 这些数**只住在这里**：皮 PNG 与清单都由它们生成，构件运行时只读清单。
R_IN = 80.0                    # 钉住阶段的亮区半径（世界像素）：四只泡外沿 76 px 全在里面
EDGE_W = 0.45                  # 软边占半径的比例（⑤ w=0.15 与⑥ w=0.90 之间那一档）
CAP = 1.0                      # 外圈抹黑（⑦ 那一档 0.86 是他看图后没挑的备选）
BREATH_AMP = 6.0               # 睡着时半径 ±6 世界像素
BREATH_PERIOD = 3.2            # 一圈 3.2 s ≈ 一次呼吸
OPEN_R = float(FULL_R)         # 苏醒窗口走完要张到这儿
ARC_ORIGIN_Y = -5              # 圆心 = 玩家原点上方 5 px（与 dream_bubble.json 同一个数，
                               # 两份清单各写一次 ⇒ verify_kit 钉"两个值必须相同"）
SHIPPED_PNG = os.path.join(ROOT, "assets", "props", "dream_mask.png")
SHIPPED_JSON = os.path.join(ROOT, "assets", "props", "dream_mask.json")
## 出货那张是**一张正方形的屏空间贴图**：运行时它 1:1 铺在 CanvasLayer 上、张开 = 整张放大，
## 所以边长按"圆心到屏最远那角"算（CORNER_R 世界像素 × 2 设备像素 × 2 半径方向），
## 不是按 r_in 算 —— 按 r_in 做的话张到一半屏幕四角就露出没遮罩的空隙。
TEX_SIDE = 2 * CORNER_R * SCALE
TEX_CENTRE = (TEX_SIDE // 2, TEX_SIDE // 2)


def ramp_alpha(d_world, r_in, w, cap=1.0):
    """d 世界像素处该压多黑（0..cap）。r_in 以内全亮，往外 w 比例的半径里做 smoothstep。
    `cap` 是那一档"压暗 vs 抹黑"的旋钮：1.0 = 外面什么都不剩；0.86 = 还剩一层轮廓可读。"""
    r_out = r_in * (1.0 + w)
    if d_world <= r_in:
        return 0.0
    if d_world >= r_out:
        return cap
    t = (d_world - r_in) / (r_out - r_in)
    return cap * t * t * (3.0 - 2.0 * t)


def mask_layer(r_in, w, rgb, cap=1.0, size=(PAGE_W, CARD_H), centre=None, top=None):
    """按环画一张 RGBA 遮罩：从外圈往内圈逐世界像素一圈，后画的盖前画的 ⇒
    任一像素最终拿到的就是它自己那一圈的 alpha。一圈 = 2 设备像素 = 实机的最小台阶。
    `top` 只给自检里的"故意画错"那一跑用（复刻第一版的错法），正常调用一律留空。"""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    r_out = r_in * (1.0 + w)
    cx, cy = centre if centre is not None else (CX, CY)
    k = max(int(math.ceil(r_out)), CORNER_R) if top is None else top
    while k >= 0:
        a = int(round(ramp_alpha(k + 0.5, r_in, w, cap) * 255))
        rr = (k + 1) * SCALE
        draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=rgb + (a,))
        k -= 1
    return layer


def card(base, r_in, w, rgb=MASK_RGB, cap=1.0):
    out = base.convert("RGBA")
    out = Image.alpha_composite(out, mask_layer(r_in, w, rgb, cap, out.size))
    return out.convert("RGB")


def _text(dd, pos, text, fill, font, max_w=PAGE_W - 2 * GAP):
    """按宽度折行（本机 msyh 画长句会顶出画布，D77 那轮踩过）。"""
    x, y = pos
    line = ""
    for ch in text:
        if dd.textlength(line + ch, font=font) > max_w:
            dd.text((x, y), line, fill=fill, font=font)
            y += font.size + 4
            line = ch
        else:
            line += ch
    if line:
        dd.text((x, y), line, fill=fill, font=font)
        y += font.size + 4
    return y


def _lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def check_card(base, img, r_in, w, cap):
    """读数自检：亮区不许被压、外圈必须真的按算式压到底。
    第二档跑在弧心到屏角那一格 —— 第一版就是漏了它：环只画到 `r_out` 为止，
    整张图其实是一圈黑环、远处照旧清楚，而我看着缩略图把它读成了"暗下来了"。
    比的是"画出来的像素 == 这条算式算出来的混合"，逐档核，与底片内容无关
    （拿"最终亮度单调"当判据是错的：底片自己在变，混完当然上下跳 —— 那条假红挡过一次正例）。"""
    b, p = base.load(), img.load()
    problems = []
    for d in (20, 40, r_in - 2):
        x = int(round(CX + d * SCALE))
        if b[x, CY] != p[x, CY]:
            problems.append("亮区内 d=%d 被压暗了：%s -> %s" % (d, b[x, CY], p[x, CY]))
    for d in (r_in + 2, r_in + 8, r_in + 14, CORNER_R - 3):
        x = int(round(CX + d * SCALE))
        y = int(round(CY + d * SCALE * 0.6))
        x, y = min(max(x, 0), PAGE_W - 1), min(max(y, 0), CARD_H - 1)
        a = ramp_alpha(math.floor(math.hypot(x - CX, y - CY) / SCALE) + 0.5, r_in, w, cap)
        want = tuple(b[x, y][i] * (1 - a) + MASK_RGB[i] * a for i in range(3))
        got = p[x, y]
        if max(abs(got[i] - want[i]) for i in range(3)) > 10:
            problems.append("d=%.0f 处画出来的是 %s，按算式（alpha=%.2f）应为 %s" % (d, got, a, want))
    return problems


def _alpha_profile(img, centre):
    """沿 +x 方向取一条 alpha 剖面（世界半径 → 0..255）。比皮只用这一条轴，
    环是各向同性的，比全图是浪费。"""
    px = img.load()
    out = {}
    for d in range(0, CORNER_R + 30):
        x = int(round(centre[0] + d * SCALE))
        y = int(round(centre[1]))
        if 0 <= x < img.size[0]:
            out[d] = px[x, y][3]
    return out


def emit():
    """落盘：出货的遮罩 PNG + 那份清单，**由画选型图那同一个函数生成**（D56/D58/D77 那条
    单一写手）。所以"他批的那张卡"与"进引擎的那张皮"不是两份代码的巧合相同，
    而是同一次调用的两个尺寸。"""
    shipped = mask_layer(R_IN, EDGE_W, MASK_RGB, CAP, (TEX_SIDE, TEX_SIDE), TEX_CENTRE)
    shipped.save(SHIPPED_PNG)
    manifest = {
        "style": "g",
        "radius": R_IN,
        "edge_width": EDGE_W,
        "cap": CAP,
        "open_radius": OPEN_R,
        "breath_amplitude": BREATH_AMP,
        "breath_period": BREATH_PERIOD,
        "arc_origin_y": ARC_ORIGIN_Y,
        "corner_radius": CORNER_R,
        "tex_px_per_world_px": SCALE,
        "texture": {"file": "res://assets/props/dream_mask.png",
                    "side": TEX_SIDE, "centre": list(TEX_CENTRE)},
        "colour": list(MASK_RGB),
    }
    with open(SHIPPED_JSON, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
    # 同源当场自证：出货那张与选型图①卡，在同一条半径剖面上必须逐档相同。
    card_layer = mask_layer(R_IN, EDGE_W, MASK_RGB, CAP)
    a = _alpha_profile(shipped, TEX_CENTRE)
    b = _alpha_profile(card_layer, (CX, CY))
    worst = max((abs(a[d] - b[d]), d) for d in a if d in b)
    print("emit: %s (%d×%d) + dream_mask.json；与选型图①卡剖面最大差 %d/255（d=%d）"
          % (SHIPPED_PNG, TEX_SIDE, TEX_SIDE, worst[0], worst[1]))
    if worst[0] > 3:
        raise SystemExit("出货皮与选型图不是同一次调用的结果（差 %d），先修生成器" % worst[0])


def main():
    if not os.path.exists(BASE):
        raise SystemExit("缺底片 %s —— 先开窗跑 res://tools/dream_mask_shot.tscn" % BASE)
    base = Image.open(BASE).convert("RGB")
    assert base.size == (PAGE_W, CARD_H), "底片不是实机一帧：%s" % (base.size,)

    # —— 自检先跑，并且**当场证明它会响**：故意用第一版那个"环只画到 r_out"的错法再跑一次 ——
    good = check_card(base, card(base, 80, 0.45, MASK_RGB, 1.0), 80, 0.45, 1.0)
    buggy_img = base.convert("RGBA")
    buggy_img = Image.alpha_composite(
        buggy_img, mask_layer(80, 0.45, MASK_RGB, 1.0, buggy_img.size,
                              top=int(math.ceil(80 * 1.45)))).convert("RGB")
    buggy = check_card(base, buggy_img, 80, 0.45, 1.0)
    print("自检：正例 problems=%d，错例 problems=%d" % (len(good), len(buggy)))
    for line in buggy:
        print("      错例报的（这条必须非空，否则自检本身是假绿）: %s" % line)
    if good:
        raise SystemExit("正例没过，图先不出：%s" % good[0])
    if not buggy:
        raise SystemExit("自检抓不到那笔已知的错法 = 自检本身是假绿，先修它")

    f_title, f_head, f_cap = G._font(24), G._font(18), G._font(15)
    rows = [
        ("① 亮区 r=80 世界像素（钉住那一拍：四只泡外沿 76 px 全在亮区内，"
         "144 px 那张能量卡与 264 px 那扇门全在暗处）· 外圈抹黑", 80, 0.45, 1.0),
        ("② 亮区 r=140（能量卡刚够读出来，门还在暗处）", 140, 0.45, 1.0),
        ("③ 亮区 r=240", 240, 0.45, 1.0),
        ("④ 亮区 r=366 = 一屏对角一半 ⇒ 完全张开（苏醒窗口走完就该是这个）", FULL_R, 0.45, 1.0),
        ("⑤ 软边对照 · 硬一档 w=0.15（同样 r=140）", 140, 0.15, 1.0),
        ("⑥ 软边对照 · 软一档 w=0.90（同样 r=140）", 140, 0.90, 1.0),
        ("⑦ 「压暗 vs 抹黑」· 同样 r=80，但外圈只压到 0.86 ⇒ 墙与那扇门的青还剩一层轮廓"
         "（①是同半径抹黑，两张对着看就是要裁的这一格）", 80, 0.45, 0.86),
    ]
    page_h = 40 + sum(CARD_H + 96 for _ in rows) + 96 + 360 + GAP * 3
    page = Image.new("RGB", (PAGE_W, page_h), (10, 11, 16))
    dd = ImageDraw.Draw(page)
    y = 14
    y = _text(dd, (GAP, y), "开场遮罩选型图 · 底片 = 真窗口抓的『睡着那一拍』一帧 · "
                            "尺度 1 世界像素 = 2 设备像素（实机）", (206, 222, 250), f_title)
    y += 12
    for label, r_in, w, cap in rows:
        page.paste(card(base, r_in, w, MASK_RGB, cap), (0, y))
        band = ImageDraw.Draw(page)
        band.rectangle([0, y + CARD_H, PAGE_W, y + CARD_H + 92], fill=(10, 11, 16))
        _text(band, (GAP, y + CARD_H + 6), label, (150, 168, 210), f_cap)
        y += CARD_H + 96

    # —— 遮罩色对照：在册近黑蓝 vs 纯黑，各裁中间 640×360 ——
    band = ImageDraw.Draw(page)
    _text(band, (GAP, y), "⑦ 遮罩色对照（各取画面中间 640×360，r=80 / w=0.45）："
                         "左 = 在册 `screen` (18,24,40)，右 = 纯黑 (0,0,0)",
          (206, 222, 250), f_head)
    y += 34
    box = (CX - 320, CY - 180, CX + 320, CY + 180)
    left = card(base, 80, 0.45, MASK_RGB).crop(box)
    right = card(base, 80, 0.45, BLACK_RGB).crop(box)
    page.paste(left, (0, y))
    page.paste(right, (640, y))
    page.save(OUT_PNG)
    print("saved %s (%dx%d)" % (OUT_PNG, PAGE_W, page_h))
    # ①那一档另存一张**不带标题条的单卡**：实拍器拿真帧与之逐像素比，需要一个不需要
    # "第几行开始"这种魔数的对照物（魔数一改就悄悄全红或全绿）。
    card(base, R_IN, EDGE_W, MASK_RGB, CAP).save(CARD_PNG)
    print("saved %s (%dx%d) ← 实拍器⑥的同源对照" % (CARD_PNG, PAGE_W, CARD_H))

    # —— 动图：睡着时呼吸（r 74↔86，一圈 3.2 s）→ 最后一发泡破后 2.45 s 张到 366 ——
    frames = []
    for i in range(10):                       # 半圈呼吸
        t = i / 20.0
        frames.append(card(base, 80 + 6.0 * math.sin(t * 2 * math.pi), 0.45))
    for i in range(14):                       # 张开那 2.45 s（线性）
        p = i / 13.0
        frames.append(card(base, 80 + (FULL_R - 80) * p, 0.45))
    frames[0].save(OUT_GIF, save_all=True, append_images=frames[1:],
                   duration=[160] * 10 + [175] * 14, loop=0, optimize=True)
    print("saved %s (%d 帧)" % (OUT_GIF, len(frames)))
    print("亮区 80 时：泡外沿 %d px 在亮区内；能量卡 144 px、刷卡门 264 px 在暗处" % BUBBLE_FAR)
    emit()


if __name__ == "__main__":
    main()
