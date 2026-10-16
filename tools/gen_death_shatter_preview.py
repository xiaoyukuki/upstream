"""死亡那一拍的重排候选（D66，待裁定）。

用法：py tools/gen_death_shatter_preview.py
  ->  assets/player/preview_death_shatter.png   （静图：每行一个候选，每列一个瞬间）
  ->  assets/player/preview_death_shatter.gif   （五行同时播，运动本身才是判据）

D42 当时批的是那张图里的 D 行（等比收缩 + 14 滴爆裂）。今天他实机看完说
「死亡后的缩小看起来很奇怪，不像是受伤后破碎」，所以这里摆四档重排候选。
**全部复用 D42 那张图的底片、液滴算式与配色**（`import gen_death_preview`），
不新画第二张地面、不引入新零件 —— 行与行之间唯一的差别就是演出本身。

关键的一条是 V0 与 S1 的差别：**当年图上那版脚底是钉死的，引擎里那版没有。**
`_apply_death_transform()` 缩的是 `Visual` 壳，而壳的原点 = 身体中心、脚底在下方 15 px，
所以等比缩放会把**底边一起往上收**，实装比图外多飘 15×(1−s)。下面每行的 `lift`
就是"脚底离地几像素"，V0 那一行是照引擎的式子原样复算的，不是我的想象。
"""

import os

from PIL import Image, ImageDraw

import gen_death_preview as D
import gen_tiles as G
import gen_props as P

Z = 4
BEAT = D.BEAT
TIMES = D.TIMES
# 引擎里脚底到 Visual 原点的距离：从那张图自己的常量推，不落第二个数。
HALF = D.G.FEET_ROW - D.G.FRAME / 2.0

# 大号碎块：比液滴少而重，初速压到液滴的六成 —— 读作"崩出几块"而不是"喷一片"。
CHUNKS = [(-163, 70, 7), (-128, 96, 6), (-92, 108, 8), (-56, 98, 6),
          (-20, 78, 7), (14, 62, 5), (152, 82, 6), (194, 68, 5)]

ROWS = [
    ("V0  today in engine", "V0"),
    ("S1  pin the feet only", "S1"),
    ("S2  collapse on the ground", "S2"),
    ("S3  shatter, no shrink", "S3"),
    ("S4  collapse + shatter", "S4"),
]

FLASH_END = 0.10   # S3 那一下提亮占整拍的几成（0.10 × 0.55 s ≈ 3 物理拍）


def uniform(t):
    """引擎现在的收缩：u=t/0.6、k=1-(1-u)^2、s=max(0.12, 1-0.88k)。
    四个数全从 gen_death_preview 里那组常量读，而它们与 player.gd 的 DEATH_* 一字对应。"""
    u = min(t / D.SHRINK_SPAN, 1.0)
    k = 1.0 - (1.0 - u) * (1.0 - u)
    return k, max(D.SHRINK_MIN, 1.0 - (1.0 - D.SHRINK_MIN) * k)


def alpha_of(t, from_t):
    return 1.0 if t < from_t else max(0.0, 1.0 - (t - from_t) / (1.0 - from_t))


def splash(cell, progress, spec, origin_y, spread=1.0):
    """把整拍的成数换成秒再交给那条弹道（引擎里 `_elapsed` 是秒、淡出读的是 progress）。"""
    D.splash(cell, progress * BEAT, spec, origin_y, spread, alpha_t=progress)


def draw_body(cell, t, sx, sy, lift, alpha):
    if alpha <= 0.0:
        return
    frame, pos = D.body_frame(t, sx, sy, alpha, lift=lift)
    cell.alpha_composite(frame, pos)


def cell_for(kind, t):
    cell = D.backdrop()
    k, s = uniform(t)
    a = alpha_of(t, D.FADE_FROM)

    if kind == "V0":
        # 引擎真几何：等比缩 + 上浮 12，底边因此被一起收上来 15×(1-s)
        splash(cell, t, D.SPLASH_D, 12.0, spread=1.15)
        draw_body(cell, t, s, s, HALF * (1.0 - s) + D.SHRINK_RISE * k, a)
        return cell

    if kind == "S1":
        # 只补那一条脚底补偿（= D42 图上那版 D 行）
        splash(cell, t, D.SPLASH_D, 12.0, spread=1.15)
        draw_body(cell, t, s, s, D.SHRINK_RISE * k, a)
        return cell

    if kind == "S2":
        # 塌：横向不变宽反而胀一点、纵向抽干到 0.28，脚底不离地，不上浮
        kk = D.ease_out(min(t / 0.5, 1.0))
        splash(cell, t, D.SPLASH_D, 12.0, spread=1.15)
        draw_body(cell, t, 1.0 + 0.20 * kk, max(0.28, 1.0 - 0.72 * kk),
                  0.0, alpha_of(t, 0.45))
        return cell

    if kind == "S3":
        # 碎：身体一寸不缩。开头一提亮（被咬穿那一下）就整块撤掉，体积全交给碎块
        splash(cell, t, CHUNKS, 8.0)
        splash(cell, t, D.SPLASH_D, 12.0)
        if t < FLASH_END:
            frame = D.tint_silhouette(G.add_rim(D._raw_frame("idle", 2), D.RIM),
                                      G.mix(D.BODY, D.RIM, 0.62))
            cell.alpha_composite(frame, ((D.CELL_W - G.FRAME) // 2, D.FLOOR - G.FEET_ROW))
        return cell

    # S4：塌与碎同拍 —— 纵向抽干的同时大块就离开，身体淡得早
    kk = D.ease_out(min(t / 0.35, 1.0))
    splash(cell, t, CHUNKS, 8.0)
    splash(cell, t, D.SPLASH_D, 12.0, spread=1.15)
    draw_body(cell, t, 1.0 + 0.20 * kk, max(0.42, 1.0 - 0.58 * kk),
              0.0, alpha_of(t, 0.35))
    return cell


def strip(path):
    gap, pad, cap, gut = 6, 16, 30, 236
    cw, ch = D.CELL_W * Z, D.CELL_H * Z
    cols = len(TIMES) + 1
    W = pad * 2 + gut + cw * cols + gap * (cols - 1)
    H = cap + pad + (ch + 20) * len(ROWS) + 44
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 8), "DEATH BEAT - SHATTER CANDIDATES (D66). columns are t = "
                     + " ".join("%.2f" % t for t in TIMES)
                     + " of a %.2fs beat. ground line = spike root." % BEAT,
           fill=ink, font=G._font(13))
    for r, (label, kind) in enumerate(ROWS):
        y0 = cap + pad + r * (ch + 20)
        d.text((pad, y0 + ch // 2 - 7), label, fill=ink, font=G._font(12))
        for c in range(cols):
            cell = cell_for(kind, 0.0 if c == len(TIMES) else TIMES[c]) \
                if c < len(TIMES) else D.cell_for("now", 0.0)
            x = pad + gut + c * (cw + gap)
            canvas.paste(cell.resize((cw, ch), Image.NEAREST), (x, y0))
            tag = ("t = %.2f" % TIMES[c]) if c < len(TIMES) else "now (full body)"
            d.text((x + 2, y0 + ch + 3), tag, fill=(150, 168, 210), font=G._font(9))
    d.text((pad, H - 34),
           "V0 lifts the bottom edge by 15x(1-s) because Visual scales about the body centre;"
           "  S1 deletes exactly that term.  chunks = same blob colour + rim, no new palette."
           "   last column = the body after the reload (reference).",
           fill=(150, 168, 210), font=G._font(10))
    canvas.save(path)
    print("saved", path, canvas.size)


def gif(path):
    ticks = sorted({BEAT * i / 22.0 for i in range(23)} | {BEAT + 0.30})
    tracks = {}
    for _, kind in ROWS:
        tracks[kind] = [(cell_for(kind, min(t / BEAT, 1.0)), t) for t in ticks]
    cw, ch = D.CELL_W * Z, D.CELL_H * Z
    gap = 8
    W = pad_left = 168
    H = (ch + gap) * len(ROWS) - gap + 12
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = Image.new("RGB", (W + cw, H), (16, 20, 30))
        d = ImageDraw.Draw(canvas)
        for r, (label, kind) in enumerate(ROWS):
            cell, _ = tracks[kind][n]
            y = 6 + r * (ch + gap)
            canvas.paste(cell.convert("RGB").resize((cw, ch), Image.NEAREST), (W, y))
            d.text((6, y + ch // 2 - 6), label.split("  ")[0], fill=(214, 224, 240),
                   font=G._font(11))
        d.text((W + 4, 0), "t = %.2f s" % min(t, BEAT), fill=(150, 168, 210), font=G._font(10))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.5
        durs.append(max(20, int((nxt - t) * 1000)))
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=durs, loop=0, optimize=False)
    print("wrote", os.path.basename(path), "ticks=%d" % len(frames))


def main():
    out = os.path.join(D.ROOT, "assets", "player")
    strip(os.path.join(out, "preview_death_shatter.png"))
    gif(os.path.join(out, "preview_death_shatter.gif"))


if __name__ == "__main__":
    main()
