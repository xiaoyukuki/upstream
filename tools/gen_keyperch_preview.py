"""能量卡的「底座」选型图（D55）：可拾取这件事能不能靠形状说话，而不是靠转。

用法：py tools/gen_keyperch_preview.py   ->  assets/props/preview_keyperch.png

起因：用户先要「给钥匙卡也加一段像鸭子那样的旋转动画，提示这是可拾取的道具」，
自己想到了解法：「加一个和鸭子一样的底座表示可拾取」。这条比转便宜得起，因为承重墙换了 ——
转要解决「玩家朝它走的时候世界必然处于冻结态」（D40/D41 那条地基），提示恰好在最需要它的
那一刻关掉；底座是**静态形状语言**，冻着也照样在画面里说话。

要量的不是「好不好看」，是三条账：
  1. **座子自己在暗底夜光的墙上读不读得出来**（D26 下限 4.5）。D 行是这把尺子的原稿：
     同一只座子、同一块地板，鸭子那行的座子读数就是「这座子本来有多显眼」。
     座子的填充色是 `deep`，跟墙是同一档东西 —— 这一条最可能整个塌掉，塌了就没有
     「形状语言」这回事，得回到「换色 / 加描边 / 让它转」。
  2. **卡坐上去之后本体有没有被座子拖累**（对墙 / 对地）。本体那条量的是不含座子的像元，
     预期与 N 行一字不差；它不为好看服务，只为「我有没有画错」服务。
  3. **宽度**：鸭子 12 宽坐在 14 座上、两侧各露 1 px；能量卡 14 宽，坐同一只座子就
     **齐边**，轮廓成一整块 14×15。齐边读不读得出「下面那是另一个东西」，是这张图唯一
     真正要他眼睛裁的一格。B/C 两档是把座子加宽（两侧各 1 / 3 px），代价是新落零件。

底片、算式、量法全部沿用 D54 那张（同一块 spot0 真帧地板、同一条 `crt()`、同一份 footprint
判据）—— 换任何一份都会让两张图的读数不可比。每行最右那格是 1:1 真机，读数一律量这一份；
有底座的行左半「在位」、右半「已拿走」（空座）。
"""

import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                      # _cr / _font
import gen_freeze_filter_preview as F      # crt()：D46 已验过它与实机 shader 对得上
import gen_props as P                      # part_perch / duck_perched：落盘的单一来源
import gen_gate_alert_preview as A         # _mean / _zoom / _wrap：与 D53 同一量法
import gen_collectible_preview as C        # 与 D54 同一块地板、同一份算式、同一条 footprint 量法

OUT = os.path.join(ROOT, "assets", "props", "preview_keyperch.png")
CARD = Image.open(C.CARD_PNG).convert("RGBA")
PAL = C.PAL
CRT = C.CRT
SOCK_H = P.PERCH_H


# ------------------------------------------------------------------ 组合（世界像素）

def card_perched(w, taken=False):
    """卡坐在宽 `w` 的公共底座上：水平居中、卡的底边贴底座顶边 —— 与 `P.duck_perched`
    同一条对齐契约（那份算式在 gen_props 里，这里只是把「上面那只」换成卡）。
    两态同尺寸：收据是座面那道压痕 + 上面那只不见了，不是盒子大小。"""
    sock = P.part_perch(PAL, taken, False, w)
    img = P._cv(max(w, CARD.width), CARD.height + sock.height)
    if not taken:
        img.paste(CARD, ((img.width - CARD.width) // 2, 0), CARD)
    img.paste(sock, (0, CARD.height), sock)
    return img


def duck_ref():
    """家族参照：鸭子在 14 座上，D54 落盘的那一份，一字未改。"""
    return P.duck_perched(PAL, P.part_duck_front(PAL), False)


def _band_pts(art, cx, floor_y, top, bottom):
    """art 上从**顶边**数第 `top` 行到第 `bottom` 行（不含）那些不透明像元落到设备坐标上的
    位置清单。`C._footprint` 只能「从下往上排除若干行」，而这张图要把座子单独量出来
    （最下面那 5 行），所以要一份能指定区间的 —— 2× 与 alpha 判据照抄，不另立规矩。"""
    x0 = cx - art.width
    y0 = floor_y - art.height * 2
    pts = []
    px = art.load()
    for wy in range(top, min(bottom, art.height)):
        for wx in range(art.width):
            if px[wx, wy][3] < 200:
                continue
            dx, dy = x0 + wx * 2, y0 + wy * 2
            pts.extend(((dx, dy), (dx + 1, dy), (dx, dy + 1), (dx + 1, dy + 1)))
    return pts


# (行名, 上面那只, 座子宽度或 None, 是否画空座那一半, 备注)
ROWS = (
    ("N 现状 · 卡直接落地（无座）", "card", None, False,
     "对照：D36 落地那样子，拾走之后原地什么都不留。这条是「提示从哪来」的起点，不是候选"),
    ("A 复用鸭子那只 14x5（与卡同宽）", "card", 14, True,
     "用户点名的那条：座子一颗像素都不新画，直接拿 D54 落盘的 perch_idle。"
     "卡 14 宽 = 座 14 宽，两侧齐边，轮廓成一整块 14x15"),
    ("B 16x5（两侧各露 1 px）", "card", 16, True,
     "鸭子自己的露边比例（12 坐在 14 上 = 每侧 1 px）。要新落两张零件"),
    ("C 20x5（两侧各露 3 px）", "card", 20, True,
     "座面明显外扩的一档，读「台阶」最省力；代价是零件宽度快赶上鸭子，"
     "视觉上更像一台设备而不是一块石台"),
    ("D 参照 · 鸭子在 14 座上", "duck", 14, False,
     "不是候选，是这把尺子的原稿：D54 批过的那一份。它的座子读数 = 「同一只座子本来就有多显眼」"),
)


def main():
    raw = Image.open(C.FRAME).convert("RGB")
    px = raw.load()
    floor_y = max((sum(sum(px[x, y][:3]) for x in range(C.SPOT_X - 60, C.SPOT_X + 60)), y)
                  for y in range(*C.FLOOR_SEARCH))[1]
    crop = (C.SPOT_X - C.CROP_W // 2, floor_y - C.CROP_H + 8,
            C.SPOT_X + C.CROP_W // 2 - 1, floor_y + 7)
    print("自检：地面亮线 y=%d（与 D54 同一块地板）" % floor_y)

    wall_box = (C.SPOT_X - 96, floor_y - 56, C.SPOT_X - 64, floor_y - 24)
    floor_box = (C.SPOT_X + 64, floor_y + 16, C.SPOT_X + 96, floor_y + 40)

    small = C._font(12)
    big = C._font(19)
    cell_w, cell_h = C.CROP_W * C.ZOOM, C.CROP_H * C.ZOOM
    head_h = 52
    pad = 10
    row_h = cell_h + 2 * pad + 44
    W = C.LABEL_W + cell_w * 2 + C.REAL_W + pad * 4 + 400
    H = head_h + len(ROWS) * row_h + 130 + pad
    out = Image.new("RGB", (W, H), (12, 15, 23))
    d = ImageDraw.Draw(out)
    d.text((pad, 12), "能量卡坐底座（D55）  底片 = spot0 真帧里 D54 用过的那块空地板   "
                      "左列裸帧 / 中列套 CRT（真账）/ 右列 1:1 真机（左在位、右空座）",
           fill=(214, 224, 240), font=small)
    d.line([(pad, head_h - 6), (W - pad, head_h - 6)], fill=(40, 50, 66))

    y = head_h
    for name, body, perch_w, show_empty, note in ROWS:
        if body == "duck":
            art = duck_ref()
        elif perch_w is None:
            art = CARD
        else:
            art = card_perched(perch_w, False)
        seat_h = 0 if perch_w is None else SOCK_H
        full_raw = C._paste_state(raw, art, C.SPOT_X, floor_y)
        f_full = F.crt(full_raw, *CRT)
        body_pts = _band_pts(art, C.SPOT_X, floor_y, 0, art.height - seat_h)
        core_raw = C._mean_pts(full_raw, body_pts)
        core_f = C._mean_pts(f_full, body_pts)
        cr_wall = G._cr(core_f, A._mean(f_full, wall_box))
        cr_floor = G._cr(core_f, A._mean(f_full, floor_box))
        clip = C._clip_pts(f_full, body_pts)
        if perch_w is None:
            seat_note = "无底座，这一行没有座子读数"
        else:
            seat_pts = _band_pts(art, C.SPOT_X, floor_y, art.height - SOCK_H, art.height)
            seat_mean = C._mean_pts(f_full, seat_pts)
            # 三条分母全用 D54 那两张标准盒（与本体同一批尺子，读数才可比）；
            # 最后一条「座子 vs 它上面那只」才是这张图的正题：齐边读不读得出两截。
            seat_note = "座子 %s | 对墙 %.2f 对地 %.2f 对头顶那只 %.2f（%d px）" % (
                str(seat_mean), G._cr(seat_mean, A._mean(f_full, wall_box)),
                G._cr(seat_mean, A._mean(f_full, floor_box)),
                G._cr(seat_mean, core_f), len(seat_pts))

        d.text((pad, y + 2), name, fill=(228, 236, 248), font=big)
        for i, t in enumerate(A._wrap(d, note, small, C.LABEL_W - pad - 40, 3)):
            d.text((pad, y + 30 + i * 16), t, fill=(150, 164, 186), font=small)
        out.paste(A._zoom(full_raw, crop, C.ZOOM), (C.LABEL_W, y + pad))
        out.paste(A._zoom(f_full, crop, C.ZOOM), (C.LABEL_W + cell_w + pad, y + pad))

        panel = C._paste_state(raw, art, C.SPOT_X - 22, floor_y)
        if show_empty:
            panel = C._paste_state(panel, card_perched(perch_w, True), C.SPOT_X + 22, floor_y)
        panel = F.crt(panel, *CRT).crop((C.SPOT_X - C.REAL_W // 2, floor_y - 96,
                                        C.SPOT_X - C.REAL_W // 2 + C.REAL_W, floor_y - 96 + C.REAL_H))
        out.paste(panel, (C.LABEL_W + cell_w * 2 + pad * 2, y + pad))
        d.rectangle([C.LABEL_W + cell_w * 2 + pad * 2, y + pad,
                     C.LABEL_W + cell_w * 2 + pad * 2 + C.REAL_W - 1, y + pad + C.REAL_H - 1],
                    outline=(40, 50, 66))

        x = C.LABEL_W + cell_w * 2 + C.REAL_W + pad * 3
        lines = (
            "整块 %dx%d 世界 px   本体不透明 %d 设备 px" % (art.width, art.height, len(body_pts)),
            "裸帧本体 %s -> CRT 后 %s   削顶 %d/%d px" % (str(core_raw), core_f, clip, len(body_pts)),
            "本体：对墙 cr=%.2f   对地 cr=%.2f" % (cr_wall, cr_floor),
            seat_note,
            "D26 下限 4.5；座子那条才是「底座读不读得出来」的真账",
        )
        for i, t in enumerate(lines):
            d.text((x, y + pad + 4 + i * 19), t,
                   fill=(190, 205, 226) if i < 4 else (250, 190, 74), font=small)
        d.text((C.LABEL_W, y + pad + cell_h + 2), "裸帧（留档）", fill=(150, 164, 186), font=small)
        d.text((C.LABEL_W + cell_w + pad, y + pad + cell_h + 2), "套 CRT（真账）", fill=(150, 164, 186), font=small)
        d.text((C.LABEL_W + cell_w * 2 + pad * 2, y + pad + cell_h + 2), "1:1 真机（左在 / 右空）",
               fill=(150, 164, 186), font=small)
        print("%-32s %2dx%-2d 本体%s | 墙 %.2f 地 %.2f | %s"
              % (name, art.width, art.height, core_f, cr_wall, cr_floor, seat_note))
        y += row_h

    # 底部家族图：真机比例，两只共用一只座子。眼睛只裁一件事 —— 「同一类东西：都能拿」
    # 读不读得通，以及会不会读成「分不清哪个开门」。
    fam_y = y + 6
    d.text((pad, fam_y), "家族图（1:1 真机，不放大）：同一只 14x5 底座，左 = 小黄鸭（D54 已批）、"
                        "右 = 能量卡坐 A 档。这一格裁的是「同一种语言」读不读得通。",
           fill=(214, 224, 240), font=small)
    fam = C._paste_state(raw, duck_ref(), C.SPOT_X - 26, floor_y)
    fam = C._paste_state(fam, card_perched(P.PERCH_W, False), C.SPOT_X + 26, floor_y)
    fam = F.crt(fam, *CRT)
    fam_img = A._zoom(fam, (C.SPOT_X - 90, floor_y - 70, C.SPOT_X + 90, floor_y + 26), 2)
    out.paste(fam_img, (pad, fam_y + 24))
    ImageDraw.Draw(out).rectangle([pad, fam_y + 24, pad + fam_img.width - 1, fam_y + 23 + fam_img.height],
                                  outline=(40, 50, 66))
    out.save(OUT)
    print("WROTE %s  %dx%d" % (OUT, W, H))


if __name__ == "__main__":
    main()
