#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""D77 梦泡（新手引导）的选型图 —— 第二版。

**第一轮的裁定（2026-10-29，他看图点的）**：皮 = **F 暗底白边白字**；**装饰泡整条砍掉**，
只画四只气泡把主角围住（原话「不要有周围多余的气泡」）；「空格」不画长条键、**写成 `space`**。
第二版因此只回答两件事：**`space` 这五个字母怎么画才读得出来**，以及**四只泡怎么围**。

尺度：**1 世界像素 = 2 设备像素**，与实机 `zoom = 2`（可见 640x360 世界像素）一致。
底 = `level_template.tscn` 里 `Terrain/WallFill` 实际用的那格地形瓦（atlas (0,2)），
地面 = 实心那格 (3,3)（D76 定的"墙就是这一格"），都是从落盘图集上**裁**下来平铺的、不是重画。
人 = 落盘的 `assets/player/slime/wake_0.png` 第 0 帧（睡姿），按 alpha 外接框底边贴地。
色 / 亮度 / 字体 / 对比度全部 import `gen_tiles`，读数与 `contrast_report` 同一杆秤。

**这一拍不跑 CRT**：整段掐输入 → `get_axis()` 恒 0 → 不算"他在移动" → 世界不冻结、滤镜不上屏
（player.gd:486 那把锁 + D46 那层 CanvasLayer 100）。所以这张图**不该**有扫描线 ——
D74 那条"卡片先拼成一整页再跑一次 crt"在这里前提不成立，跑了反而是一张谎话图。

第一轮那四处"自己看图退回"的账（破帧串色 / 下方那只埋进地里 / 散梦档不够"很多个" /
空心亮边在这面墙上半隐形）里，第三条随装饰泡一起作废，其余三条的实现口径仍带进落盘。

用法：  py tools/gen_dream_bubble_preview.py
产物：  assets/props/preview_dream_bubbles.png
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "assets", "tiles", "tiles.json")
OUT = os.path.join(ROOT, "assets", "props", "preview_dream_bubbles.png")

PAGE_W = 1280
S = 2
GAP = 16
PANEL_W, PANEL_H = 214, 160              # 真尺度面板（世界像素）：横向要放 96 半径 + 半只泡
RING_Y = PANEL_H - 40                    # 环心放在靠下：上方要留够 96 + 泡半径，下方只留脚边那一档
PAL = G.STYLES["g"]
RING = 96
FLOOR_Y = 15                             # 脚底线相对碰撞盒中心（+y 向下），泡底不许越过

# 第一轮六档留表在册（要回看另一档就把 SHIPPED 换过去），本轮只出 F。
SKINS = {
    "A 青边黑心": dict(line=PAL["accent"], fill=PAL["screen"], glyph=PAL["accent"],
                       hi=PAL["lip"], rim2=False),
    "B 金属贴纸": dict(line=PAL["edge"], fill=PAL["metal"], glyph=PAL["edge"],
                       hi=PAL["lip"], rim2=False),
    "C 亮白空心": dict(line=PAL["lip"], fill=None, glyph=PAL["lip"], hi=None, rim2=False),
    "D 白边青字": dict(line=PAL["lip"], fill=None, glyph=PAL["accent"], hi=None, rim2=False),
    "E 暗底白边青字": dict(line=PAL["lip"], fill=PAL["screen"], glyph=PAL["accent"],
                         hi=PAL["glass"], rim2=True),
    "F 暗底白边白字": dict(line=PAL["lip"], fill=PAL["screen"], glyph=PAL["lip"],
                         hi=PAL["glass"], rim2=True),
}
SHIPPED = "F 暗底白边白字"

# ---- 像素字形：项目零文字管线（唯一的 Label 是调试面板），所以字是一格一格点的 ----
CAPS = {
    "A": (".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
    "D": ("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),
    "S": (".####", "#....", "#....", ".###.", "....#", "....#", "####."),
}
LOW5 = {                                 # 5x7 小写：x 高落在第 2..6 行，p 带下伸
    "s": (".....", ".####", "#....", ".###.", "....#", "####.", "....."),
    "p": (".....", "#####", "#...#", "#####", "#....", "#....", "#...."),
    "a": (".....", ".####", "....#", ".####", "#...#", ".####", "....."),
    "c": (".....", ".####", "#....", "#....", "#....", ".####", "....."),
    "e": (".....", ".###.", "#...#", "#####", "#....", ".###.", "....."),
}
LOW4 = {                                 # 4x6 小写
    "s": ("....", ".###", "#...", ".##.", "...#", "###."),
    "p": ("....", "###.", "#..#", "###.", "#...", "#..."),
    "a": ("....", ".###", "..##", ".###", "#..#", ".###"),
    "c": ("....", ".###", "#...", "#...", "#...", ".###"),
    "e": ("....", "####", "#...", "###.", "#...", "####"),
}
LOW3 = {                                 # 3x5 小写：22~26 px 圆泡里塞得下，但一个字母只有 3 宽
    "s": (".##", "#..", ".#.", "..#", "##."),
    "p": ("##.", "#.#", "##.", "#..", "#.."),
    "a": (".##", "..#", ".##", "#.#", ".##"),
    "c": (".##", "#..", "#..", "#..", ".##"),
    "e": ("###", "#..", "##.", "#..", "###"),
}

# 「space」的三种画法：key -> (形状, 尺寸, 字表, 字间距)
SPACE_KINDS = {
    "space 3x5 圆泡 26": ("bubble", 26, LOW3, 1),
    "space 4x6 胶囊 32x20": ("pill", (32, 20), LOW4, 1),
    "space 5x7 胶囊 38x22": ("pill", (38, 22), LOW5, 1),
}
BEST_SPACE = "space 5x7 胶囊 38x22"


def tiles():
    """从落盘图集裁两块真瓦。atlas 坐标 (0,2)/(3,3) 抄自 level_template 的 WallFill 格子。"""
    with open(MANIFEST, encoding="utf-8") as fh:
        man = json.load(fh)
    sheet = Image.open(os.path.join(ROOT, "assets", "tiles",
                                    man["terrain"]["file"])).convert("RGBA")
    return sheet.crop((0, 32, 16, 48)), sheet.crop((48, 48, 64, 64))


def _squircle(size):
    r = size / 2.0
    cx = cy = (size - 1) / 2.0
    return {(x, y) for y in range(size) for x in range(size)
            if (abs(x - cx) / r) ** 3.2 + (abs(y - cy) / r) ** 3.2 <= 1.0}


def _rounded_box(w, h, rad=4):
    inside = set()
    for y in range(h):
        for x in range(w):
            dx = max(0, rad - 0.5 - x, x - (w - 1 - rad))
            dy = max(0, rad - 0.5 - y, y - (h - 1 - rad))
            if dx * dx + dy * dy <= (rad - 0.5) ** 2 + 0.5:
                inside.add((x, y))
    return inside


def _shell(inside, skin, frame, w, h):
    """描边（rim2 = 两圈）+ 暗底。1 px 描边会被墙的亮线吃掉，所以 F 那档画两圈。"""
    out = {}
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    for (x, y) in sorted(inside):
        on_edge = any((nx, ny) not in inside for nx, ny in
                      ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
        depth = min(abs(x - cx), abs(x - (w - 1 - cx)), abs(y - cy), abs(y - (h - 1 - cy)))
        rimmed = on_edge or (skin["rim2"] and depth > min(w, h) / 2.0 - 2.6)
        if rimmed and frame <= 2:
            out[(x, y)] = skin["line"]
        elif skin["fill"] is not None and frame == 0:
            out[(x, y)] = skin["fill"]
    if frame == 2:
        return {p: c for p, c in out.items() if p[1] < h // 2}      # 只剩上半圈弧
    return out


def _stamp(out, inside, skin, text, table, gap, w, h):
    """把一串字形居中盖进像素表（只许盖在自己那块底上）。"""
    rows = max(len(v) for v in table.values())
    widths = [max(len(r) for r in table[ch]) for ch in text]
    cols = sum(widths) + gap * (len(text) - 1)
    x0 = (w - cols) // 2
    y0 = (h - rows) // 2
    for ch, cw in zip(text, widths):
        for ry, row in enumerate(table[ch]):
            for rx, c in enumerate(row):
                p = (x0 + rx, y0 + ry)
                if c == "#" and p in inside:
                    out[p] = skin["glyph"]
        x0 += cw + gap


def bubble_of(key, skin, frame=0):
    """key -> (像素表, 宽, 高)。四只泡里只有 `space` 那一只会换形状与字号。"""
    if key in CAPS:
        size = 22
        inside = _squircle(size)
        out = _shell(inside, skin, frame, size, size)
        out = _dots(out, frame, size, size)
        if frame == 0:
            _highlight(out, inside, skin, 4, 3)
            _stamp(out, inside, skin, key, CAPS, 0, size, size)
        return out, size, size
    shape, size, table, gap = SPACE_KINDS[key]
    w, h = (size, size) if shape == "bubble" else size
    inside = _squircle(w) if shape == "bubble" else _rounded_box(w, h)
    out = _shell(inside, skin, frame, w, h)
    out = _dots(out, frame, w, h)
    if frame == 0:
        _highlight(out, inside, skin, 4, 3)
        _stamp(out, inside, skin, "space", table, gap, w, h)
    return out, w, h


def _dots(out, frame, w, h):
    """破第三帧：只剩四角残点。"""
    if frame != 3:
        return out
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    qx, qy = max(1, w // 2 - 3), max(1, h // 2 - 2)
    return {(int(cx) + sx * qx, int(cy) + sy * qy): PAL["lip"]
            for sx in (-1, 1) for sy in (-1, 1)}


def _highlight(out, inside, skin, hx, hy):
    if skin["hi"] is None:
        return
    for dy in range(2):
        for dx in range(2):
            p = (hx + dx, hy + dy)
            if all(q in inside for q in (p, (p[0] + 1, p[1]),
                                         (p[0], p[1] + 1), (p[0] + 1, p[1] + 1))):
                out[p] = skin["hi"]


def ring_layout(mode):
    """四只泡把主角围住。坐标相对**碰撞盒中心**（feet + (0,-15)），+y 向下。
    两条硬约束：泡底不许埋进地里（脚底线以下就是实心砖）；正下方那一格被人自己占着
    （睡姿外接框 22x20，压上去就把这张图的情绪核心 —— 那张睡脸 —— 整个盖掉）。
    第三轮裁定（2026-10-29）：**围法改成头顶那一段圆弧** —— 弧心落在头顶（中心 -5），
    四只按读序 A / S / space / D 从左端排到右端：左右两端仍把"左键在左、右键在右"教着，
    而整串都在肩线以上，一只都不压睡脸、一只都不进砖里。"""
    if mode == "arc_order":                    # 同一张弧，只换读序：A / space / S / D
        rr = 64
        head = -5
        return [(k, (int(round(rr * math.cos(math.radians(a)))),
                     head - int(round(rr * math.sin(math.radians(a))))))
                for k, a in zip(("A", "space", "S", "D"), (160, 120, 60, 20))]
    if mode.startswith("arc:"):
        rr = int(mode.split(":")[1])
        head = -5
        return [(k, (int(round(rr * math.cos(math.radians(a)))),
                     head - int(round(rr * math.sin(math.radians(a))))))
                for k, a in zip(("A", "S", "space", "D"), (160, 120, 60, 20))]
    if mode == "cross":
        return [("A", (-RING, -6)), ("D", (RING, -6)), ("S", (44, FLOOR_Y - 11)),
                ("space", (0, -RING))]
    return [("A", (-72, -44)), ("D", (72, -44)), ("S", (-72, FLOOR_Y - 11)),
            ("space", (72, FLOOR_Y - 11))]


def render_panel(world_w, world_h, mode, space_key, spawn_x=64.0, limit_x=0.0):
    """一整块真尺度视图：墙 + 地面 + 睡姿人 + 四只泡（贴边时按关卡左边界 clamp）。"""
    wall, solid = tiles()
    skin = SKINS[SHIPPED]
    img = Image.new("RGBA", (world_w, world_h), (0, 0, 0, 0))
    centre = (world_w // 2, RING_Y)
    feet = (centre[0], centre[1] + FLOOR_Y)
    for ty in range(0, world_h, 16):
        for tx in range(0, world_w, 16):
            img.paste(wall, (tx, ty))
    for ty in range(feet[1], world_h, 16):
        for tx in range(0, world_w, 16):
            img.paste(solid, (tx, ty))
    spr = Image.open(os.path.join(ROOT, "assets", "player", "slime", "wake_0.png")).convert("RGBA")
    bb = spr.getbbox()
    img.paste(spr, (feet[0] - (bb[0] + bb[2]) // 2, feet[1] - bb[3]), spr)
    items = [(space_key if k == "space" else k, (px, py)) for (k, (px, py)) in ring_layout(mode)]
    clamped = 0
    for (key, (px, py)) in items:
        pixels, w, h = bubble_of(key, skin)
        x0, y0 = centre[0] + px - w / 2.0, centre[1] + py - h / 2.0
        assert x0 >= 0 and y0 >= 0 and x0 + w <= world_w and y0 + h <= world_h, \
            "面板容不下 %s：盒子 (%d, %d) %dx%d，面板 %dx%d" % (
                key, x0, y0, w, h, world_w, world_h)
        if spawn_x + px - w / 2.0 < limit_x:                 # 贴边重生时挪进可见区
            px = int(limit_x + w / 2.0 + 1 - spawn_x)
            clamped += 1
        paste_pixels(img, pixels, int(centre[0] + px - w / 2.0), int(centre[1] + py - h / 2.0))
    big = img.resize((world_w * S, world_h * S), Image.NEAREST).convert("RGB")
    d = ImageDraw.Draw(big)
    ex = int((limit_x - (spawn_x - world_w / 2.0)) * S)
    if 0 < ex < big.width - 2:
        d.line([(ex, 0), (ex, big.height)], fill=(200, 90, 120), width=2)
    return big, clamped


def paste_pixels(img, pixels, ox, oy):
    for (x, y), c in pixels.items():
        if 0 <= ox + x < img.width and 0 <= oy + y < img.height:
            img.putpixel((ox + x, oy + y), tuple(c) + (255,))


def card(pixels, w, h, scale=6, pad=6):
    out = Image.new("RGBA", (w * scale + 2 * pad, h * scale + 2 * pad), PAL["bg"] + (255,))
    for (x, y), c in pixels.items():
        for dy in range(scale):
            for dx in range(scale):
                out.putpixel((pad + x * scale + dx, pad + y * scale + dy), tuple(c) + (255,))
    return out


def _split_mean(img):
    """把一块背景按自身亮度切成亮部/暗部两堆、各取均值（D74 那条：整块平均会把一条 1 px
    亮线直接抹平，而"亮线"正是描边会隐形的那一处）。"""
    px = list(img.convert("RGB").getdata())
    lum = [G._rlum(c) for c in px]
    m = sum(lum) / len(lum)
    hi = [c for c, l in zip(px, lum) if l >= m]
    lo = [c for c, l in zip(px, lum) if l < m]

    def mean(set_):
        if not set_:
            return None
        return tuple(sum(c[i] for c in set_) // len(set_) for i in range(3))
    return mean(hi), mean(lo)


def _text(dd, pos, text, fill, font, max_w=PAGE_W - 2 * GAP):
    """按宽度折行（超长的一律自动换行，不在 1280 那一列上把话说一半剪掉）。返回下一行的 y。"""
    x, y = pos
    line = ""
    for ch in text:
        if dd.textlength(line + ch, font=font) > max_w:
            dd.text((x, y), line, fill=fill, font=font)
            y += font.size + 7
            line = ch
        else:
            line += ch
    if line:
        dd.text((x, y), line, fill=fill, font=font)
        y += font.size + 7
    return y


def main():
    f_title, f_head, f_cap = G._font(22), G._font(18), G._font(15)
    skin = SKINS[SHIPPED]
    wall, solid = tiles()
    wall_hi, wall_lo = _split_mean(wall)
    space_panels = [(k, render_panel(PANEL_W, PANEL_H, "cross", k)[0]) for k in SPACE_KINDS]
    layout_panels = []
    for mode, label in (("arc:56", "头顶弧 r=56（贴着人）"),
                        ("arc:64", "头顶弧 r=64（推荐档）"),
                        ("arc:80", "头顶弧 r=80（更开）"),
                        ("arc_order", "同一张弧换读序：A / space / S / D")):
        img, clamped = render_panel(PANEL_W, PANEL_H, mode, BEST_SPACE)
        layout_panels.append((label, img, clamped))
    detail = []
    for key in ("A", "D", "S", BEST_SPACE):
        pixels, w, h = bubble_of(key, skin)
        detail.append((key.replace("space ", "space "), card(pixels, w, h)))
    for frame in (1, 2, 3):
        pixels, w, h = bubble_of("A", skin, frame)
        detail.append(("破 %d 帧" % frame, card(pixels, w, h)))

    def worst(col):
        a, b = G._cr(col, wall_hi), G._cr(col, wall_lo)
        return "%.2f/%.2f→%.2f" % (a, b, min(a, b))
    read_lines = [
        "皮 = %s（第一轮定的）。读数格式 = 对墙亮部 / 对墙暗部 → 取最差（D26 下限 4.5）：" % SHIPPED,
        "  描边 %s ／ 填充 %s ／ 字对底 %.2f ／ 边对底 %.2f"
        % (worst(skin["line"]), worst(skin["fill"]),
           G._cr(skin["glyph"], skin["fill"]), G._cr(skin["line"], skin["fill"])),
        "  两条信道各兜一半：暗底对墙亮线 8.78 交代整圈、亮白描边对墙暗格 4.95 交代压在暗格上那几段，"
        "字读在自己那块底上。",
        "space 三档的字高（世界像素 → 设备像素）：3x5 = 5 → 10 px ／ 4x6 = 6 → 12 px ／ 5x7 = 7 → 14 px；"
        "A / D / S 那三个大写字母是 7 → 14 px。",
        "3x5 那一档一个字母只有 3 宽：s / c / e 在这个宽度上是同一个形状（都是「上一横 + 左下一横」），"
        "而 space 里同时有 c 和 e —— 所以那一档不是「小一点」，是「读不出是哪两个字母」。",
        "4x6 那档 c 与 e 只差右下角那一格；5x7 那档才分得开。代价是那只泡要横向涨到 38 px（比另三只宽 16 px）。",
    ]

    row_h = PANEL_H * S + 40
    page = Image.new("RGB", (PAGE_W, 4200), (12, 12, 16))
    d = ImageDraw.Draw(page)
    y = _text(d, (GAP, 18), "D77 梦泡第二版 —— 皮定 F、装饰泡砍掉、只留四只；本轮只裁"
              "「space 怎么画」与「四只怎么围」"
              "（1 世界像素 = 2 设备像素 = 实机 zoom 2；这一拍掐输入 → 不跑 CRT）",
              (232, 236, 248), f_title) + 6
    y = _text(d, (GAP, y), "space 三档画法 —— 同一套摆位（十字），只换最上面那一只；"
              "粉红竖线 = 关卡左边界 x=0（出生点 x=64 → 左边那只必须 clamp）",
              (180, 190, 210), f_head) + 6
    for pair in (space_panels[:2], space_panels[2:]):
        x = GAP
        for label, img in pair:
            page.paste(img, (x, y))
            _text(d, (x + 2, y + img.height + 4), label, (232, 236, 248), f_cap,
                  max_w=img.width + 30)
            x += img.width + 60
        y += row_h
    y = _text(d, (GAP, y), "头顶圆弧四档 —— 弧心在头顶（碰撞盒中心 -5），四只按读序从左端排到右端；"
              "粉红竖线 = 关卡左边界 x=0（出生点 x=64 → 左端那只会被 clamp）",
              (180, 190, 210), f_head) + 6
    for pair in (layout_panels[:2], layout_panels[2:]):
        x = GAP
        for label, img, clamped in pair:
            page.paste(img, (x, y))
            d.text((x + 2, y + img.height + 4), "%s ｜ clamp %d 只" % (label, clamped),
                   fill=(232, 236, 248), font=f_cap)
            x += img.width + 60
        y += row_h
    y = _text(d, (GAP, y), "6x 细节带 —— 四只泡（皮 F）与破的那一拍三帧（不循环）",
              (180, 190, 210), f_head) + 6
    x = GAP
    for label, img in detail:
        if x + img.width > PAGE_W - GAP:
            y += 40
            x = GAP
        page.paste(img.convert("RGB"), (x, y))
        d.text((x + 2, y + img.height + 2), label, fill=(160, 172, 196), font=f_cap)
        x += img.width + 14
    y += 40 + 150
    for line in read_lines:
        y = _text(d, (GAP, y), line, (232, 236, 248), f_cap)
    y += 6
    for extra in ("砍掉的：12 只装饰泡，以及「装饰泡第 i 只在 3.2 + 0.7i 秒自破」那条计时 —— "
                  "构件因此没有随机种子、没有自破计时器，只剩四只各自的一次破（三帧）。",
                  "W 不做（InputMap 里没有「向上」这个动作）；Q 也撤（这一拍 movement_locked 为真，"
                  "锚点那三道闸 time_anchor.gd:120/198/295 发不出也供不了时 → 那只泡永远破不了 = 软锁）。",
                  "定了 space 那档之后落盘走 gen_props 那一族（PNG 零件 + 清单），构件只画纹理 → "
                  "「图 == 出货」由单一写手保证，不需要第三条算式。"):
        y = _text(d, (GAP, y), extra, (160, 172, 196), f_cap)
    page = page.crop((0, 0, PAGE_W, y + 20))
    page.save(OUT)
    print("saved", OUT, page.size)
    for line in read_lines:
        print("  ", line)


if __name__ == "__main__":
    main()
