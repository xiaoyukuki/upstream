"""转台小黄鸭选型图（D54 追加）：一只 2D 的鸭子在底座上"伪 3D 自转"要怎么转。

用法：py tools/gen_collectible_spin_preview.py  ->  assets/props/preview_duck_spin.png

用户挑了 E4 小黄鸭，并要它**一直在底座上转**。"伪 3D"在这个项目里只有一条便宜路：
不建 3D、不上 shader，拿几张正视图按角度换 + 横向挤压。所以真正要选的是**用几张皮、
挤不挤压**，四档候选：
  A 单张正脸 + 纯挤压（最省，但侧过去那一帧会塌成一条线 —— 鸭子会"消失"）
  B 三视图（正/侧/背）+ 挤压换视图（DOOM 转台：最扁只到 70%，代价是一圈里换 4 次皮）
  C 三视图硬切、零形变（像素最硬，但换皮那一下最跳）
  D 五视图八向硬切（最接近真 3D，皮最多）

要量的三条，全是"改了不响、要到试玩才露馅"那种：
  1. **最差那一帧它还在不在** —— 一圈里像元最少的那一帧，本体还剩多少设备像素、对墙拉不拉得开。
     这条不只是审美：世界冻结时这只鸭子会**钉在当前角度上**（它走 TimeReceiver 那条门控 delta，
     跟世界一起停），所以"最差帧"就是玩家按着方向键时看到的那一帧，它得还读得出是个东西。
  2. **一圈里换几次皮**（跳）与**有没有塌成 ≤2 px 的帧**（消失）。
  3. 两条都在**透过 D46 那层 CRT 之后**再量一遍 —— 色散会把"扁成一条线"的那几像素抹开，
     挤压档在裸帧下看着还行、过了滤镜可能就糊了。

底片与另一张图同源：`assets/ui/frames/spot0_raw.png` 真帧，鸭子坐在 E4 那只公共底座上，
1 世界 px = 2 设备 px（相机 zoom=2），每帧整帧过 `gen_freeze_filter_preview.crt()`。
每行两条带：上 = 2× 真机（看皮），下 = 1:1 真机（看它屏幕上真正的样子）。
"""

import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G
import gen_freeze_filter_preview as F
import gen_props as P
import gen_gate_alert_preview as A
import gen_collectible_preview as C     # 复用同一只底座、同一套贴帧/量法，两张图必须同源

FRAME = C.FRAME
OUT = os.path.join(ROOT, "assets", "props", "preview_duck_spin.png")
PAL = C.PAL
SPOT_X = C.SPOT_X
CRT = C.CRT
SOCK_H = C.SOCK_H
PHASES = 12                 # 一圈采 12 帧（每 30 度）
FRAME_W = 40                # 每帧的裁剪盒（设备像素）
ZOOM_STRIP = 2


# ------------------------------------------------------------------ 鸭子的几张视图

# 三张视图就是落盘的那三张（gen_props 单一来源，D54）：选型图与资产同图，这里只转发。
view_front = P.part_duck_front
view_side = P.part_duck_side
view_back = P.part_duck_back


def view_front_side(p):
    """斜前 12x11：脸偏右、一只眼被转过去的喙挡住一半 —— 只给 D 档用。"""
    img = C._cv(12, 11)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 4, 11, 10], fill=a)
    d.ellipse([3, 0, 11, 6], fill=G.lighter(a, 0.18))
    d.rectangle([5, 2, 5, 3], fill=p["edge"])
    d.rectangle([9, 2, 10, 4], fill=G.darker(a, 0.42))
    d.rectangle([2, 7, 8, 8], fill=G.darker(a, 0.20))
    return P._rim(img, p)


def view_back_side(p):
    """斜后 12x11：背缝偏右、尾羽只剩左簇。只给 D 档用。"""
    img = C._cv(12, 11)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 4, 11, 10], fill=G.darker(a, 0.10))
    d.ellipse([1, 0, 9, 6], fill=a)
    d.rectangle([6, 0, 7, 9], fill=G.darker(a, 0.30))
    d.rectangle([2, 8, 4, 10], fill=G.lighter(a, 0.24))
    return P._rim(img, p)


def _squash(art, factor, mirror):
    """横向挤压到 factor 倍宽（至少 1 px），必要时镜像。NEAREST 是故意的：
    插值会把硬边糊成半透明，那正好是 CRT 之前不该有的东西。"""
    w = max(1, int(round(art.width * factor)))
    out = art.resize((w, art.height), Image.NEAREST)
    if mirror:
        out = out.transpose(Image.FLIP_LEFT_RIGHT)
    return out


AXES4 = ((0.0, "front"), (math.pi / 2, "side"), (math.pi, "back"), (3 * math.pi / 2, "side"))
AXES8 = ((0.0, "front"), (math.pi / 4, "front_side"), (math.pi / 2, "side"),
         (3 * math.pi / 4, "back_side"), (math.pi, "back"), (5 * math.pi / 4, "back_side"),
         (3 * math.pi / 2, "side"), (7 * math.pi / 4, "front_side"))
ASYM = ("side", "front_side", "back_side")


def _nearest(axes, theta):
    """返回 (视图名, 与最近轴心的夹角)。轴心表升序，取角距最近的那一个。"""
    best = min(axes, key=lambda ax: abs(_wrap_pi(theta - ax[0])))
    return best[1], _wrap_pi(theta - best[0])


def _wrap_pi(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


def pick(mode, theta):
    """这一帧该用哪张皮、挤到多宽、要不要镜像。`switches` 与出图共用这一份算式，
    所以图上的跳数就是引擎里会发生的跳数 —— 不另写第二份。
    镜像只对非对称视图有意义（正脸与背面镜像了也看不出来），但 A 档例外：它赌的就是
    "把正脸镜像当背面"，那是它唯一的一张皮能撑起一圈的办法 —— 也是它最假的地方。"""
    if mode == "A":
        return "front", abs(math.cos(theta)), math.cos(theta) < 0.0
    if mode in ("B", "C"):
        name, delta = _nearest(AXES4, theta)
        return name, (abs(math.cos(delta)) if mode == "B" else 1.0), \
            math.sin(theta) < 0.0 and name in ASYM
    name, delta = _nearest(AXES8, theta)
    return name, 1.0, math.sin(theta) < 0.0 and name in ASYM


MODES = (
    ("A 单张正脸 + 纯挤压", "A", ("front",),
     "最省：一张皮。侧过去塌成一条线，那一帧它就是「不见了」而不是「转过去了」"),
    ("B 三视图 + 挤压换视图", "B", ("front", "side", "back"),
     "DOOM 转台：最扁只到 70%，一圈换 4 次皮。挤压与换皮互相打掩护"),
    ("C 三视图硬切（零形变）", "C", ("front", "side", "back"),
     "像素最硬、最不糊，代价是换皮那一下看得见 —— 一圈 4 次跳"),
    ("D 五视图八向硬切", "D", ("front", "front_side", "side", "back_side", "back"),
     "最接近真 3D：皮最多（5 张 + 镜像 = 8 向），一圈 8 次跳但每次只转 45 度"),
)


def _paste_art(frame, art, cx, floor_y):
    """鸭子 + 公共底座：底座不动，只有上面的鸭子在换姿态。"""
    full = C._cv(14, art.height + SOCK_H)
    full.paste(art, ((14 - art.width) // 2, 0), art)
    full.paste(C.part_socket(PAL, False), (0, art.height), C.part_socket(PAL, False))
    return C._paste_state(frame, full, cx, floor_y), full


def main():
    raw = Image.open(FRAME).convert("RGB")
    px = raw.load()
    floor_y = max((sum(sum(px[x, y][:3]) for x in range(SPOT_X - 60, SPOT_X + 60)), y)
                  for y in range(*C.FLOOR_SEARCH))[1]
    wall_box = (SPOT_X - 96, floor_y - 56, SPOT_X - 64, floor_y - 24)
    views = {"front": view_front(PAL), "side": view_side(PAL), "back": view_back(PAL),
             "front_side": view_front_side(PAL), "back_side": view_back_side(PAL)}
    print("自检：地面亮线 y=%d   视图 %s" % (floor_y, {k: v.size for k, v in views.items()}))

    small = _font(12)
    big = _font(19)
    strip_w = FRAME_W * ZOOM_STRIP * PHASES
    LABEL_W = 400
    READ_W = 430
    pad = 10
    row_h = FRAME_W * ZOOM_STRIP + FRAME_W + 96
    W = LABEL_W + strip_w + READ_W + pad * 4
    H = 150 + len(MODES) * row_h + pad
    out = Image.new("RGB", (W, H), (12, 15, 23))
    d = ImageDraw.Draw(out)
    d.text((pad, 12), "转台四档：每行 12 帧 = 一整圈（每 30 度采一帧）。上带 = 2× 真机看皮，下带 = 1:1 真机看屏幕上的它，全部套 CRT",
           fill=(214, 224, 240), font=small)
    d.text((pad, 32), "鸭子钉在底座上不动、只有上面那只换姿态；冻结期间整只钉在当前角度（走 TimeReceiver 的门控 delta）",
           fill=(150, 164, 186), font=small)

    y = 150
    for name, mode, used, note in MODES:
        min_px, min_cr, worst_theta, collapses, switches = 10 ** 9, 99.0, 0.0, 0, 0
        prev_name = None
        x = LABEL_W
        for i in range(PHASES):
            theta = 2 * math.pi * i / PHASES
            vname, factor, mirror = pick(mode, theta)
            art = _squash(views[vname], factor, mirror)
            pasted, full = _paste_art(raw, art, SPOT_X, floor_y)
            filt = F.crt(pasted, *CRT)
            pts = C._footprint(full, SPOT_X, floor_y, SOCK_H)
            core = C._mean_pts(filt, pts)
            cr = G._cr(core, A._mean(filt, wall_box))
            min_px = min(min_px, len(pts))
            collapses += 1 if art.width <= 2 else 0
            if cr < min_cr:
                min_cr, worst_theta = cr, theta
            # 换皮 = (视图名, 是否镜像) 变了。A 档塌成一条线的那两帧不算"换皮"，
            # 因为镜像在 1 px 宽上没有意义 —— 它露馅的方式是"消失"，图上是另一条读数。
            key = (vname, mirror and art.width > 2)
            if prev_name is not None and prev_name != key:
                switches += 1
            prev_name = key
            box = (SPOT_X - FRAME_W // 2, floor_y - 62, SPOT_X + FRAME_W // 2 - 1, floor_y + 9)
            out.paste(A._zoom(filt, box, ZOOM_STRIP), (x, y + 30))
            out.paste(A._zoom(filt, box, 1), (x, y + 30 + FRAME_W * ZOOM_STRIP + 6))
            x += FRAME_W * ZOOM_STRIP
        d.text((pad, y + 2), name, fill=(228, 236, 248), font=big)
        for i, t in enumerate(A._wrap(d, note, small, LABEL_W - pad - 40, 3)):
            d.text((pad, y + 30 + i * 16), t, fill=(150, 164, 186), font=small)
        lines = (
            "皮：%d 张（%s）" % (len(used), " + ".join(used)),
            "最差帧本体 %d 设备 px" % min_px,
            "最差帧对墙 cr=%.2f（θ=%.0f°）" % (min_cr, math.degrees(worst_theta)),
            "塌成 ≤2 px 宽的帧：%d/%d" % (collapses, PHASES),
            "一圈换皮次数：%d" % switches,
            "对墙那条看第一条下限：钉住那一帧还得是个东西",
        )
        for i, t in enumerate(lines):
            d.text((LABEL_W + strip_w + pad * 2, y + 30 + i * 19), t,
                   fill=(190, 205, 226) if i < 5 else (250, 190, 74), font=small)
        print("%-22s 皮 %d 张 | 最差帧 %d px  对墙 %.2f (θ=%.0f°)  塌成线 %d/%d  换皮 %d 次"
              % (name, len(used), min_px, min_cr, math.degrees(worst_theta), collapses,
                 PHASES, switches))
        y += row_h

    d.line([(pad, 150 - 6), (W - pad, 150 - 6)], fill=(40, 50, 66))
    for i in range(1, len(MODES)):
        yy = 150 + i * row_h - 6
        d.line([(pad, yy), (W - pad, yy)], fill=(30, 38, 52))
    out.save(OUT)
    print("WROTE %s  %dx%d" % (OUT, W, H))


def _font(size):
    return G._font(size)


if __name__ == "__main__":
    main()
