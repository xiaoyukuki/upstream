#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
心电监护屏的 7 个相位选型图 —— **D75 的视觉收据**（构件本体已落盘，这张图只回答"看起来对不对"）。

**这里没有第三份算式**。图上的七张卡不是重画一遍波形，而是把落盘图集上那块 `monitor`
瓦片的屏幕带**按列横滚** k 格得到的：
    新列 i 的纵条 = 原列 (i + k) % 42
这与构件 `scenes/objects/ecg_monitor/ecg_monitor.gd` 里 `PATTERN[(i + idx) % 7]` 是同一件事，
因为屏宽 42 列正好是周期 14 列的 3 倍（`verify_kit` 钉着这条整除），滚够一圈就回原样。
所以这张图与实机之间不存在"预览自己漂走"的空间：瓦片是出货的，滚法就是那七帧。

同源链条（D58 立的规矩）：
  瓦片   = tools/gen_tiles.py 的 build_decor_atlas()，连 soft 套的补描边与擦角都走同一段代码；
  矩形   = assets/tiles/tiles.json 里 decor.items.monitor（不写死坐标）；
  底     = 同一张图集里的 wall_fill 平铺，所以卡是贴在那面墙上的；
  冻结   = tools/gen_freeze_filter_preview.crt()，就是出货那段 fragment 的离线复现。
**卡片必须先拼成一整页 1280x720 跑一次 crt 再裁**：扫描线与色散的周期是按屏幕像素定的
（720/180 = 4 px、色散 0.001×1280 = 1.28 px），在小图上跑会得到另一套周期。
本脚本**一个字都不改落盘产物**：产物只有 preview_ecg_monitor.png。

用法：  py tools/gen_ecg_monitor_preview.py
产物：  assets/tiles/preview_ecg_monitor.png
"""
import json
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                     # 落盘的画师
import gen_freeze_filter_preview as F     # 出货 shader 的同一条算式

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "assets", "tiles", "tiles.json")
OUT = os.path.join(ROOT, "assets", "tiles", "preview_ecg_monitor.png")

SCALE = 5                                  # 48x32 → 240x160：一屏能看完七帧，又还看得见像素块
GAP = 30
COLS = 4


def monitor_crop():
    """从落盘图集上裁那块瓦片（矩形读 manifest，不写死）。"""
    with open(MANIFEST, encoding="utf-8") as fh:
        man = json.load(fh)
    decor = man["decor"]
    rx, ry, rw, rh = decor["items"]["monitor"]
    sheet = Image.open(os.path.join(ROOT, "assets", "tiles", decor["file"])).convert("RGBA")
    return sheet.crop((rx, ry, rx + rw, ry + rh)), (rw, rh)


def phase_frame(base, idx, w, h):
    """把屏幕带按列横滚 idx 格。列 3..(w-4) 是屏内沿（与生成器同一句），行 3..(h-9) 是屏面，
    最底下两行走的是屏底暗条、不参与滚 —— 生成器就是这么画的。"""
    img = base.copy()
    sx0, sx1 = 3, w - 4
    sy0, sy1_top = 3, h - 8          # 闭区间上沿：h-8 是屏底暗条之前最后一行屏面
    band = sx1 - sx0 + 1
    for i in range(band):
        src = sx0 + (i + idx) % band
        dst = sx0 + i
        for y in range(sy0, sy1_top + 1):
            img.putpixel((dst, y), base.getpixel((src, y)))
    return img


def build_page(tiles, wall):
    """静止（世界流动）那一页：1280x720，八格四列两行。"""
    page = Image.new("RGB", (F.W, F.H), (12, 12, 16))
    for cy in range(0, F.H, 16):
        for cx in range(0, F.W, 16):
            page.paste(wall.resize((16, 16), Image.NEAREST).convert("RGB"), (cx, cy))
    d = ImageDraw.Draw(page)
    d.text((GAP, 14), "D75 心电监护屏 —— 十四个相位（每格 = 落盘那块瓦片横滚一列；相位 0 就是它本身）",
           fill=(232, 236, 248), font=G._font(22))
    cw, ch = 48 * SCALE, 32 * SCALE
    for i, (img, label, note) in enumerate(tiles):
        col, row = i % COLS, i // COLS
        x = GAP + col * (cw + GAP)
        y = 62 + row * (ch + 54)
        page.paste(img.resize((cw, ch), Image.NEAREST), (x, y))
        d.text((x, y + ch + 4), label, fill=(236, 240, 252), font=G._font(19))
        d.text((x, y + ch + 26), note, fill=(150, 196, 236), font=G._font(15))
    return page


def main():
    base, (w, h) = monitor_crop()
    p = dict(G.STYLES["g"])
    atlas = G.build_decor_atlas(p)
    wall = G.decor_tile(atlas, "wall_fill", p)

    steps = len(G.ECG_PATTERN)
    frames = [phase_frame(base, idx, w, h) for idx in range(steps + 1)]
    tiles = []
    for idx, img in enumerate(frames):
        if idx == 0:
            label, note = "图集瓦片 = 相位 0", "beat_period 填 0 就一直是这张"
        elif idx == steps:
            label, note = "相位 %d = 回到相位 0" % idx, "42 列 = 3 个整周期，接缝不断"
        else:
            label, note = "相位 %d（横滚 %d 列）" % (idx, idx), "0.84 s 推完 14 列 ≈ 每分钟 71 跳"
        tiles.append((img.convert("RGB"), label, note))

    flow = build_page(tiles, wall)
    frozen = F.crt(flow.convert("RGB"), linear_fac=1.3, scan_fac=0.10)

    page = Image.new("RGB", (F.W, F.H * 2 + 40), (8, 8, 12))
    d = ImageDraw.Draw(page)
    d.text((GAP, 6), "上 = 世界流动（波形自己推）    下 = 世界冻结那一拍（同一页过 CRT，波形停在同一形状）",
           fill=(232, 236, 248), font=G._font(20))
    page.paste(flow, (0, 34))
    page.paste(frozen, (0, F.H + 40))
    page.save(OUT)

    # 控制台收据（ASCII：cp936 会把中文列名糊掉）
    accent = p["accent"]
    print("tile %dx%d  pattern=%d cols  screen band=%d cols"
          % (w, h, steps, len(G.ECG_PATTERN) * (42 // steps)))
    print("%-6s %8s %8s %10s" % ("phase", "opaque", "cyan", "changed"))
    prev_rgba = None
    for idx, img in enumerate(frames):
        rgba = img.getdata()
        opaque = sum(1 for c in rgba if c[3] > 0)
        cyan = sum(1 for c in rgba if c[:3] == accent)
        changed = -1 if prev_rgba is None else sum(1 for a, b in zip(rgba, prev_rgba) if a != b)
        print("%-6d %8d %8d %10s" % (idx, opaque, cyan, "?" if changed < 0 else changed))
        prev_rgba = rgba
    wrap = frames[steps].tobytes() == base.tobytes()
    print("phase %d == tile: %s (expect True)" % (steps, wrap))
    print("distinct frames: %d of %d" % (len({f.tobytes() for f in frames}), len(frames)))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
