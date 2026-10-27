#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
第二关（d 亮底）太亮 / 冻结那一拍更亮 —— 降亮档选型图。

两条同源口径（D58 立的规矩：选型图必须由落盘那个渲染函数直接生成）：
  房间 = tools/gen_tiles.py 的 render_room()，换的只是 STYLES["d"] 调色板里的数值；
  冻结那一拍 = tools/gen_freeze_filter_preview.py 的 crt()，就是出货那段 fragment 的离线复现
              （linear_fac 1.3 / scan_fac 0.10 / 色散开），所以图里的"更亮"和游戏里是同一道算式。

每档出两格：左 = 静止（世界流动），右 = 冻结（按住方向键那一拍）。
控制台读数值用 ASCII（cp936 会把中文列名糊掉），图上的标注才用中文。

用法：  py tools/gen_d_dim_preview.py
产物：  assets/tiles/preview_d_dim.png
"""
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                     # 落盘的画师
import gen_freeze_filter_preview as F     # 出货 shader 的同一条算式

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "tiles", "preview_d_dim.png")

# 增益 1.3 的削顶线：任何通道 >= 255/1.3 = 196.2 都会撞天花板。
CLIP_LINE = 255 / 1.3

FACTORS = (
    (1.00, "现况 d"),
    (0.90, "A ×0.90"),
    (0.80, "B ×0.80"),
    (0.72, "C ×0.72"),
    (0.64, "D ×0.64"),
)

CELL_W, CELL_H = 640, 360
LABEL_W = 470
ROW_H = CELL_H + 96


PIN_KEYS = ("pickup",)     # 可拾取琥珀不跟着本套缩：`key_card.png` 是照落盘那套烤的实物零件，
                           # 告示牌上那只卡全靠与它同色才说得出「这张开这扇」（D70 第 4 条）。


def scale_palette(p, f):
    """整条调色板按同一个系数缩（含 alpha 的那些只缩 RGB）。
    同系数 = 每一对颜色之间的相对关系一起缩，所以不会在缩的过程中改坏对比结构。
    PIN_KEYS 里的那几个例外 —— 它们跟着别的实例走，不是本套的风格量。"""
    out = {}
    for k, v in p.items():
        if k in PIN_KEYS or not isinstance(v, tuple) or len(v) < 3 \
                or not all(isinstance(x, (int, float)) for x in v):
            out[k] = v
            continue
        rgb = tuple(G._c(x * f) for x in v[:3])
        out[k] = rgb if len(v) == 3 else rgb + (v[3],)
    return out


def room_pair(p):
    """同一间房的静止帧与冻结帧，都回到窗口的 1280x720（NEAREST 放大，别糊晶格）。"""
    img = G.render_room(p, ROOT).convert("RGB").resize((F.W, F.H), Image.NEAREST)
    return img, F.crt(img, linear_fac=1.3, scan_fac=0.10)


def readings(img):
    n = 0
    s = 0.0
    clip = 0
    for y in range(0, img.height, 3):
        for x in range(0, img.width, 3):
            r, g, b = img.getpixel((x, y))[:3]
            s += 0.2126 * r + 0.7152 * g + 0.0722 * b
            if r >= 255 or g >= 255 or b >= 255:
                clip += 1
            n += 1
    return s / n, 100.0 * clip / n


def palette_ceiling(p):
    return max(max(v[:3]) for k, v in p.items() if k not in PIN_KEYS
               and isinstance(v, tuple) and len(v) >= 3 and all(isinstance(x, (int, float)) for x in v))


def main():
    base = G.STYLES["d"]
    body = (10, 12, 12)                      # 主角那团黑，与 contrast_report 同一个抄法
    rows = []
    print("factor  label     mean_stat mean_freeze  clip_freeze%  ceiling  keys_over_clip  "
          "wall  p/wall o/wall metal/wall glass/wall lip/wall")
    for f, label in FACTORS:
        p = scale_palette(base, f)
        stat, frozen = room_pair(p)
        ms, _ = readings(stat)
        mf, cf = readings(frozen)
        over = sum(1 for k, v in p.items() if k not in PIN_KEYS
                   and isinstance(v, tuple) and len(v) >= 3
                   and all(isinstance(x, (int, float)) for x in v) and max(v[:3]) >= CLIP_LINE)
        r = dict(ms=ms, mf=mf, cf=cf, ceil=palette_ceiling(p), over=over,
                 wall=G._rlum(p["bg"]) * 100, pwall=G._cr(body, p["bg"]),
                 owall=G._cr(p["edge"], p["bg"]), metal=G._cr(p["metal"], p["bg"]),
                 glass=G._cr(p["glass"], p["bg"]), lip=G._cr(p["lip"], p["bg"]))
        rows.append((f, label, stat, frozen, r))
        print("%5.2f  %-9s %8.1f %10.1f %13.1f %9d %14d  %6.1f %6.2f %6.2f %10.2f %9.2f %8.2f" % (
            f, label, r["ms"], r["mf"], r["cf"], r["ceil"], r["over"],
            r["wall"], r["pwall"], r["owall"], r["metal"], r["glass"], r["lip"]))

    W = LABEL_W + 2 * CELL_W + 40
    H = ROW_H * len(rows) + 120
    sheet = Image.new("RGB", (W, H), (12, 12, 16))
    d = ImageDraw.Draw(sheet)
    title = G._font(30)
    f1 = G._font(24)
    f2 = G._font(18)
    d.text((20, 24), "第二关（d 亮底）降亮档选型 · 右格 = 冻结那一拍，用出货同一条算式（linear_fac 1.3 / scan 0.10 / 色散）",
           font=title, fill=(232, 236, 248))
    d.text((20, 62), "削顶线 = 255/1.3 = 196：调色板里任何通道过线，那一格在冻结时都会糊成纯白（失去色相与细节）· 全部读数由这两条同源函数当场量出",
           font=f2, fill=(178, 186, 206))

    y0 = 120
    for i, (f, label, stat, frozen, r) in enumerate(rows):
        d.rectangle([0, y0 - 8, W - 1, y0 + ROW_H - 10], outline=(52, 58, 76))
        d.text((20, y0 + 6), label, font=f1, fill=(236, 240, 252))
        d.text((20, y0 + 38), "静止均值 %.1f → 冻结 %.1f（+%.1f）" % (r["ms"], r["mf"], r["mf"] - r["ms"]),
               font=f2, fill=(186, 196, 220))
        d.text((20, y0 + 62), "冻结削顶 %.1f%% · 最高通道 %d · 过削顶线的键 %d 个"
               % (r["cf"], r["ceil"], r["over"]), font=f2, fill=(150, 196, 236))
        d.text((20, y0 + 84), "轮廓/墙 %.2f · 金属/墙 %.2f · 玻璃/墙 %.2f · 亮边/墙 %.2f · 主角/墙 %.2f"
               % (r["owall"], r["metal"], r["glass"], r["lip"], r["pwall"]),
               font=f2, fill=(228, 196, 120))
        d.text((20, y0 + 106), "墙相对亮度 %.1f（g 那套是 9.1）" % r["wall"], font=f2, fill=(150, 214, 176))
        for j, img in enumerate((stat, frozen)):
            cell = img.resize((CELL_W, CELL_H), Image.BOX)
            x = LABEL_W + 10 + j * (CELL_W + 20)
            sheet.paste(cell, (x, y0))
            d.rectangle([x, y0, x + CELL_W, y0 + CELL_H], outline=(70, 78, 100))
            d.text((x + 10, y0 + 6), "静止（世界流动）" if j == 0 else "冻结（按住方向键那一拍）",
                   font=f2, fill=(240, 244, 255))
        y0 += ROW_H

    sheet.save(OUT)
    print("\nsaved", OUT, sheet.size)


if __name__ == "__main__":
    main()
