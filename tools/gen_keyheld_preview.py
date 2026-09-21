"""钥匙卡「含在体内」跟随画法对照选型图（D39）。

用法：py tools/gen_keyheld_preview.py    →  assets/props/preview_keyheld.png

用户 2026-09-20 裁定：**不动立绘**。卡不裁、不遮罩、不把身体盖回卡上面 ——
就是一张半透明的卡跟着玩家画，画在主角之上
（Objects 在场景树里排在 Player 之后，本来就压在上面，连 z_index 都不用加）。
移动时有一部分露在体外算合理。

那唯一要定的就是「贴在哪」。位置只能钉在**脚底**：
  原点在脚底，D22 的脚底契约说它永不动；盒顶会随蹲伏 / 落地压扁上下跳，
  钉在盒顶会跟着跳，钉在脚底则一个常量就够。
按 idle 帧量出主角各部位的世界高度（y 向上为负，脚底 = 0）：
  身体顶 -24，眼睛 -14..-10，舌头 -8..-6，底部波纹 -4..-1。
  → 卡的**底边离脚底 3 px**，整块落在眼睛下方、波纹上方。
  → 蹲伏时身体只有 13 px 高（顶 -13），卡占 -10..-3 仍在体内。
引擎坐标：Player 的原点在碰撞盒中心，脚底在原点下方 Player.COLLISION_HALF_HEIGHT=15 px，
而脚底是 D22 钉死不动的那条线 —— 所以「卡底离脚底 3 px」= 一个常量偏移，
不读轮廓、不问蹲伏、不看朝向，所有帧所有姿势都是同一组数。
卡尺寸 10x6 / 10x7（原卡 14x10 的 0.7 倍）：14x10 会盖住整双眼睛，
半透明之后眼睛泛成两块琥珀斑 —— 比露在外面更糟。10x6 是顶行刚好不碰眼睛的那一档。

六行只差两个数：尺寸两档、alpha 三档，外加一档原尺寸对照。
"""

import os
from PIL import Image, ImageDraw

import gen_tiles as G
import gen_props as P

Z = 4                      # 1 世界像素 = 4 屏幕像素
CELL_W, CELL_H = 56, 52    # 世界像素
FLOOR = 44                 # 地面线在单元格内的行
HEAD_PAD = 14              # V0 的卡浮在轮廓之上，画布要往上留 14 行才不会被裁
CARD_W, CARD_H = 14, 10
FOOT_GAP = 3               # 卡底离脚底
POSES = [("idle", 2), ("run", 1), ("crouch", 1), ("jump_straight", 0), ("land", 1)]

# (label, card_w, card_h, alpha)
VARIANTS = [
    ("V0  head-top (today, D30) - reference only", None),
    ("A  10x6  @ 60%   top row clears the eyes", (10, 6, 153)),
    ("B  10x7  @ 60%", (10, 7, 153)),
    ("C  10x7  @ 45%", (10, 7, 115)),
    ("D  10x7  @ 75%", (10, 7, 191)),
    ("E  14x10 @ 60%  (native size)", (14, 10, 153)),
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAL = G.STYLES[G.SHIPPED]


def _frame(clip, i):
    path = os.path.join(ROOT, "assets", "player", "slime", "%s_%d.png" % (clip, i))
    if not os.path.exists(path):
        raise SystemExit("缺主角帧 %s —— 先跑 py tools/gen_player_frames.py" % path)
    return Image.open(path).convert("RGBA")


def _card():
    return Image.open(os.path.join(ROOT, "assets", "props", "key_card.png")).convert("RGBA")


def card_rect(cw, ch):
    """脚底锚点，与引擎里同一条：卡底边在脚底上方 FOOT_GAP px，水平取画布中心。
    主角帧是 44x44、脚底在第 37 行，而 Player 的原点在盒中心 = 脚底上方 15 px，
    所以这个矩形对所有帧、所有姿势都是同一组数 —— 不读轮廓、不问蹲伏。"""
    bottom = G.FEET_ROW - FOOT_GAP
    return G.FRAME // 2 - cw // 2, bottom - ch, cw, ch


def draw_head(frame):
    """V0：卡浮在头顶上方 3 px，不跟身形 —— 只作对照。"""
    actor = Image.new("RGBA", (frame.width, frame.height + HEAD_PAD), (0, 0, 0, 0))
    actor.alpha_composite(frame, (0, HEAD_PAD))
    card = _card().resize((CARD_W, CARD_H), Image.NEAREST)
    bb = frame.split()[-1].getbbox()
    actor.alpha_composite(card, (bb[0] + (bb[2] - bb[0]) // 2 - CARD_W // 2,
                                 bb[1] + HEAD_PAD - 3 - CARD_H))
    return actor


def draw_overlay(frame, cw, ch, alpha):
    """半透明卡直接画在主角之上，不裁不遮罩 —— 露出体外是裁定允许的。"""
    rx, ry, _, _ = card_rect(cw, ch)
    card = _card().resize((cw, ch), Image.NEAREST)
    card.putalpha(alpha)
    actor = frame.copy()
    actor.alpha_composite(card, (rx, ry))
    return actor


def base_cell(terrain, decor):
    return P.context_strip(PAL, terrain, decor, CELL_W, CELL_H, FLOOR)


def lum(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def read_delta(cell, off, rx, ry, rw, rh, frame):
    """卡区平均亮度 对 身体其余部分。"""
    ox, oy = off
    comp = cell.convert("RGB").crop((ox, oy, ox + frame.width, oy + frame.height))
    inside, n = 0.0, 0
    for y in range(ry + 1, ry + rh - 1):
        for x in range(rx + 1, rx + rw - 1):
            if frame.getpixel((x, y))[3] > 200:
                inside += lum(comp.getpixel((x, y)))
                n += 1
    body = frame.load()
    ring = [lum(body[x, y][:3]) for y in range(frame.height) for x in range(frame.width)
            if body[x, y][3] > 200 and not (rx - 1 <= x <= rx + rw and ry - 1 <= y <= ry + rh)]
    if not n or not ring:
        return 0.0
    return abs(inside / n - sum(ring) / len(ring)) / 255.0


def outside_body(frame, rx, ry, rw, rh):
    """卡有多少像素落在身体轮廓之外 —— 裁定允许，但这个数要看得见。"""
    a = frame.split()[-1].load()
    return sum(1 for y in range(ry, ry + rh) for x in range(rx, rx + rw)
               if not (0 <= x < frame.width and 0 <= y < frame.height) or a[x, y] <= 200)


def main():
    terrain = G.build_terrain_atlas(PAL)
    decor = G.build_decor_atlas(PAL)

    gap, pad, cap = 8, 16, 26
    cw, ch = CELL_W * Z, CELL_H * Z
    W = pad * 2 + cw * len(POSES) + gap * (len(POSES) - 1)
    H = cap + pad + (ch + 20) * len(VARIANTS) + 34
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 6), "KEY CARD FOLLOWING THE PLAYER, TRANSLUCENT - foot-anchored, no mask, "
                     "no re-cut art.  card bottom sits 3px above the feet baseline",
           fill=ink, font=G._font(13))

    report = []
    for r, (label, spec) in enumerate(VARIANTS):
        y0 = cap + pad + r * (ch + 20)
        for c, (clip, i) in enumerate(POSES):
            frame = _frame(clip, i)
            cell = base_cell(terrain, decor)
            x0 = (CELL_W - G.FRAME) // 2
            dy = FLOOR - G.FEET_ROW - (HEAD_PAD if spec is None else 0)
            act = draw_head(frame) if spec is None else draw_overlay(frame, *spec)
            cell.alpha_composite(act, (x0, dy))
            x = pad + c * (cw + gap)
            canvas.paste(cell.resize((cw, ch), Image.NEAREST), (x, y0))
            bb = frame.split()[-1].getbbox()
            bw, bh = bb[2] - bb[0], bb[3] - bb[1]
            if spec is None:
                d.text((x, y0 + ch + 2), "%s_%d  body %dx%d  card above head" % (clip, i, bw, bh),
                       fill=(150, 168, 210), font=G._font(9))
                report.append(("head", clip, CARD_W, CARD_H, -1.0, -1))
            else:
                rx, ry, rw, rh = card_rect(spec[0], spec[1])
                out = outside_body(frame, rx, ry, rw, rh)
                d.text((x, y0 + ch + 2), "%s_%d  body %dx%d  card %dx%d  outside %dpx"
                       % (clip, i, bw, bh, rw, rh, out),
                       fill=(150, 168, 210), font=G._font(9))
                report.append((label.split()[0], clip, rw, rh,
                               round(read_delta(cell, (x0, dy), rx, ry, rw, rh, frame), 3), out))
        d.text((4, y0 + ch // 2), label, fill=ink, font=G._font(11))

    d.text((pad, H - 26), "read delta = |card luminance - rest of body| / 255     "
                          "outside = card pixels off the silhouette (allowed by the ruling)",
           fill=(150, 168, 210), font=G._font(10))
    path = os.path.join(ROOT, "assets", "props", "preview_keyheld.png")
    canvas.save(path)
    print("saved", path, canvas.size)
    for row in report:
        print("  %-5s %-14s card %2dx%-2d  read=%-6s outside=%s"
              % (row[0], row[1], row[2], row[3], "n/a" if row[4] < 0 else "%.3f" % row[4],
                 "n/a" if row[5] < 0 else "%dpx" % row[5]))


if __name__ == "__main__":
    main()
