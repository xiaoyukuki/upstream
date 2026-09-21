"""死亡演出候选对照图（D42，待裁定）。

用法：py tools/gen_death_preview.py    ->  assets/player/preview_death_candidates.png

现状（D31/D38）：危险物发出 touched_player，LevelBase 下一拍直接 reload_level 换整张场景。
所以「碰到尖刺什么都没发生」= 少了一具尸体，位置一帧之间从尖刺上跳到存档点。

这一张图把候选演出按**同一条时间轴**铺开（每格 = 这一拍里的一瞬），
用的量与引擎里会写的量一一对应，图上的位置就是实机的位置：

  - 主角帧 44x44、FEET_ROW=37：脚底基线。缩放全部钉在脚底（D22 脚底契约），
    所以 y = FLOOR - FEET_ROW*sy —— 引擎里就是 Visual.position.y 补那条偏移。
  - 液滴是 1~2 世界像素的方块，颜色取 g2 的 player_rim（主角身上本来就有的那道亮边），
    不引入新调色板。
  - 时长基准一拍 = 0.55 s（A/B/D 只吃这一拍，C 还留着物理）。

四行候选：
  A  压扁 + 四溅   body 压到 0.28 倍（脚底不离地）后淡掉，同时 10 滴液飞溅出去
  B  塌陷吸收      只有缩放 + 透明度两个数，人往牙缝里沉下去，什么都不溅
  C  弹开（保物理） 第一帧整体亮闪一下，随后给一个上抛 + 后推，尸体照旧受重力
  D  均匀收缩 + 爆裂 身体等比缩成一个点（不压扁、不用补脚底偏移），周围 14 滴液滴径向炸开
"""

import math
import os
from PIL import Image, ImageDraw

import gen_tiles as G
import gen_props as P

Z = 4                        # 1 世界像素 = 4 屏幕像素
CELL_W, CELL_H = 66, 54      # 世界像素：右边留出液滴的飞行带
FLOOR = 46                   # 地面线在单元格内的行（= 牙根所在）
BEAT = 0.55                  # 一拍时长（秒），只是画图的标尺
TIMES = (0.00, 0.12, 0.26, 0.42, 0.62, 0.85)   # 每格取这一拍的几成
RIM = G.STYLES["g2"]["player_rim"]
BODY = (10, 12, 12)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAL = G.STYLES[G.SHIPPED]

# 液滴的发射参数：角度（度，0 = 正右，逆时针为负）、初速（世界像素/秒）、大小。
# 与引擎里同一条算式：p = p0 + v*t + 0.5*g*t^2，g = 900 px/s^2，落回地面即收。
DRIP_G = 900.0
SPLASH_A = [(-162, 96, 3), (-134, 132, 2), (-108, 158, 4), (-84, 176, 3),
            (-58, 160, 2), (-32, 132, 3), (-8, 104, 4), (16, 78, 2),
            (152, 100, 3), (190, 82, 2)]
SPLASH_D = [(-178, 112, 3), (-156, 138, 2), (-134, 162, 4), (-112, 180, 3),
            (-90, 190, 2), (-68, 176, 4), (-46, 156, 3), (-24, 132, 2),
            (-2, 106, 3), (20, 82, 4), (40, 62, 2), (156, 116, 3),
            (186, 96, 2), (214, 74, 3)]


def ease_out(t):
    return 1.0 - (1.0 - t) * (1.0 - t)


def fade(frame, alpha):
    """乘一道整体透明度：只动 alpha 通道，不改颜色。"""
    if alpha >= 0.999:
        return frame
    a = frame.split()[-1].point(lambda v: int(v * alpha))
    frame.putalpha(a)
    return frame


def tint_silhouette(frame, color):
    """整块刷成一个颜色（C 行第一帧的亮闪）：留 alpha，换 RGB。"""
    solid = Image.new("RGBA", frame.size, color + (0,))
    solid.putalpha(frame.split()[-1])
    return solid


def body_frame(t, sx, sy, alpha, sink=0.0, lift=0.0):
    """把主角帧按「脚底钉死」缩放：脚底行落在 FLOOR - lift + sink 上（lift 向上为正）。
    引擎里的同一件事 = Visual.scale + Visual.position.y 补一条常量偏移。"""
    frame = G.add_rim(_raw_frame("idle", 2), RIM)
    w = max(1, int(round(G.FRAME * sx)))
    h = max(1, int(round(G.FRAME * sy)))
    scaled = frame.resize((w, h), Image.NEAREST)
    scaled = fade(scaled, alpha)
    x = (CELL_W - G.FRAME) // 2 + (G.FRAME - w) // 2
    y = FLOOR - int(round(G.FEET_ROW * sy)) + int(round(sink)) - int(round(lift))
    return scaled, (x, y)


def _raw_frame(clip, i):
    path = os.path.join(ROOT, "assets", "player", "slime", "%s_%d.png" % (clip, i))
    if not os.path.exists(path):
        raise SystemExit("缺主角帧 %s —— 先跑 py tools/gen_player_frames.py" % path)
    return Image.open(path).convert("RGBA")


_BLOBS = {}


def blob(size):
    """一滴「小史莱姆」：身体色方块 + 一圈 player_rim 亮边，与主角本身同一套配色。
    描边画在方块外面，所以画布要比方块大一圈，否则边会被裁掉。"""
    if size not in _BLOBS:
        img = Image.new("RGBA", (size + 2, size + 2), (0, 0, 0, 0))
        ImageDraw.Draw(img).rectangle([1, 1, size, size], fill=BODY + (255,))
        _BLOBS[size] = G.add_rim(img, RIM)
    return _BLOBS[size]


def splash(cell, t, spec, origin_y, spread=1.0):
    """液滴弹道：从脚底上方 origin_y 世界像素射出，画在身体之前（身体压在上面）。
    p = p0 + v*t + 0.5*g*t^2，落回牙根线即收 —— 与引擎里会写的那条算式同源。
    画在一张独立层上再合成，淡出才是真的淡，而不是把像素直接抠掉。"""
    layer = Image.new("RGBA", cell.size, (0, 0, 0, 0))
    ox, oy = CELL_W / 2.0, FLOOR - origin_y
    for ang, v0, size in spec:
        rad = math.radians(ang)
        vx, vy = math.cos(rad) * v0 * spread, math.sin(rad) * v0 * spread
        x = round(ox + vx * t)
        y = round(oy + vy * t + 0.5 * DRIP_G * t * t)
        if y > FLOOR - size or x < 0 or x > CELL_W - size - 2:   # 落回地面 / 出画就收
            continue
        a = 1.0 if t < 0.55 else max(0.0, 1.0 - (t - 0.55) / 0.45)
        layer.alpha_composite(fade(blob(size).copy(), a), (x, y))
    cell.alpha_composite(layer)


def squash_of(t):
    k = ease_out(min(t / 0.45, 1.0))
    return 1.0 + 0.55 * k, 1.0 - 0.66 * k


def cell_for(kind, t):
    terrain = G.build_terrain_atlas(PAL)
    decor = G.build_decor_atlas(PAL)
    cell = P.context_strip(PAL, terrain, decor, CELL_W, CELL_H, FLOOR)
    unit = P.part_spikes(PAL, 1, 14)
    P.paint_spikes(cell, unit, (CELL_W - 48) // 2, FLOOR, 48)

    if kind == "now":
        frame, pos = body_frame(t, 1.0, 1.0, 1.0)
        cell.alpha_composite(frame, pos)
        return cell

    if kind == "A":
        sx, sy = squash_of(t)
        alpha = 1.0 if t < 0.5 else max(0.0, 1.0 - (t - 0.5) / 0.5)
        splash(cell, t, SPLASH_A, 10.0)
        frame, pos = body_frame(t, sx, sy, alpha)
        cell.alpha_composite(frame, pos)
        return cell

    if kind == "B":
        k = ease_out(t)
        alpha = max(0.0, 1.0 - (t * t * t))
        frame, pos = body_frame(t, 1.0 - 0.18 * k, 1.0 - 0.95 * k, alpha, sink=8.0 * k)
        cell.alpha_composite(frame, pos)
        return cell

    if kind == "C":
        if t <= 0.001:
            # 亮闪只有开头两帧（0.06 s），这里取的就是那一瞬：身体整体提亮，不是换成一块白
            frame = tint_silhouette(_raw_frame("idle", 2),
                                    G.mix(BODY, RIM, 0.62))
            cell.alpha_composite(frame, ((CELL_W - G.FRAME) // 2, FLOOR - G.FEET_ROW))
            return cell
        dt = t - 0.10
        lift = max(0.0, 180.0 * dt - 0.5 * 620.0 * dt * dt)   # 上抛，落回牙尖就不钻地下
        drift = -74.0 * dt                                    # 往后退半步
        alpha = 1.0 if dt < 0.6 else max(0.0, 1.0 - (dt - 0.6) / 0.4)
        frame, pos = body_frame(t, 1.0, 1.0, alpha, lift=lift)
        cell.alpha_composite(frame, (pos[0] + int(round(drift)), pos[1]))
        return cell

    # 最后一列：换场景之后人回到存档点，满状态、无演出（现状）。
    if kind == "respawn":
        frame, pos = body_frame(0.0, 1.0, 1.0, 1.0)
        cell.alpha_composite(frame, pos)
        return cell

    # D：等比缩成一个点 + 一圈爆裂
    k = ease_out(min(t / 0.6, 1.0))
    s = max(0.12, 1.0 - 0.88 * k)
    alpha = 1.0 if t < 0.55 else max(0.0, 1.0 - (t - 0.55) / 0.45)
    splash(cell, t, SPLASH_D, 12.0, spread=1.15)
    frame, pos = body_frame(t, s, s, alpha, lift=12.0 * k)
    cell.alpha_composite(frame, pos)
    return cell


def main():
    gap, pad, cap, gut = 6, 16, 30, 232
    cw, ch = CELL_W * Z, CELL_H * Z
    cols = len(TIMES) + 1                 # +1 列：换场景之后的落点
    W = pad * 2 + gut + cw * cols + gap * (cols - 1)
    rows = [("V0  today: nothing, the scene just swaps (reference)", "now"),
            ("A  squash + splash   feet stay planted, 10 droplets", "A"),
            ("B  collapse          scale + alpha only, sinks between the teeth", "B"),
            ("C  knock-back        keeps physics: flash, pop up, drift back", "C"),
            ("D  shrink + burst    uniform scale to a point, 14 droplets", "D")]
    H = cap + pad + (ch + 20) * len(rows) + 40
    canvas = Image.new("RGB", (W, H), (16, 20, 30))
    d = ImageDraw.Draw(canvas)
    ink = (214, 224, 240)
    d.text((pad, 8), "DEATH BEAT CANDIDATES - one row per effect, columns are t = "
                     + " ".join("%.2f" % t for t in TIMES)
                     + " of a %.2fs beat. feet baseline is pinned (D22)." % BEAT,
           fill=ink, font=G._font(13))

    for r, (label, kind) in enumerate(rows):
        y0 = cap + pad + r * (ch + 20)
        d.text((pad, y0 + ch // 2 - 7), label, fill=ink, font=G._font(12))
        for c in range(cols):
            cell = cell_for("respawn" if c == len(TIMES) else kind,
                            0.0 if c == len(TIMES) else TIMES[c])
            x = pad + gut + c * (cw + gap)
            canvas.paste(cell.resize((cw, ch), Image.NEAREST), (x, y0))
            tag = ("t = %.2f" % TIMES[c]) if c < len(TIMES) else "then: reload"
            d.text((x + 2, y0 + ch + 3), tag, fill=(150, 168, 210), font=G._font(9))

    d.text((pad, H - 30), "droplets = body colour + a player_rim highlight pixel (no new palette);"
                          "  A/D need one _draw() node, B is two transforms on Visual,"
                          "  C keeps move_and_slide running, flash = 2 frames",
           fill=(150, 168, 210), font=G._font(10))
    path = os.path.join(ROOT, "assets", "player", "preview_death_candidates.png")
    canvas.save(path)
    print("saved", path, canvas.size)


if __name__ == "__main__":
    main()
