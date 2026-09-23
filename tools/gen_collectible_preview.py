"""彩蛋收集物选型图（D54）：藏进隐藏房间的那只小东西长什么样，以及"拿走了"留什么。

用法：py tools/gen_collectible_preview.py   ->  assets/props/preview_collectible.png

要量的不是"哪只可爱"，是四条账：
  1. 它在**暗底夜光的墙上**读不读得出来（D26 那条 4.5 下限）—— 它是摆在房间里的东西，
     背景就是那面墙，所以对墙这条是"它在不在"的判据；对地那条是它坐在地板上时的另一半。
  2. 它跟**能量卡**分不分得开 —— D29 把琥珀判给了"可拾取"，而那个语义的既有住户就是卡。
     撞色不等于错（都是能捡的），但撞得看不出差别，玩家就会以为这只彩蛋是开门素材。
  3. **拿走了**这件事读不读得出来 —— 用户已拍"留空座"，所以每行同时画"在"与"空座"，
     量的是同一个盒子在两个状态之间的差（cr 越高 = 收据越强）。R 行是没有底座的那一族。
  4. 上面三条在**透过 D46 那层 CRT 之后**还剩多少 —— 玩家看到它的那一刻必然按着方向键，
     所以滤镜后才是真账，裸帧那一格只是留档。

底片不是画的：`assets/ui/frames/spot0_raw.png` 是 `tools/frame_grab.tscn` 抓的真帧。
候选皮是把世界像素的贴图 **×2 放大**（相机 zoom=2 ⇒ 1 世界 px = 2 设备 px）原地贴进真帧，
再整帧过一遍 `gen_freeze_filter_preview.crt()`（同一条算式：linearFac 1.3 / scanLineFac 0.10
/ 色散 0.001）。每行最右那格是 **1:1 真机**：那就是屏幕上它真正的尺寸，读数一律量这一份
（D53 那条教训 —— 别拿放大图的分母给自己放水）。
"""

import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                     # 复用 _cr / _font / lighter / darker / mix
import gen_freeze_filter_preview as F     # 复用 crt()：D46 已验过它与实机 shader 对得上
import gen_props as P                     # 复用 _rim：非平铺件那圈朝外描边（D26 第 1 条）
import gen_gate_alert_preview as A        # 复用 _mean / _zoom / _wrap / _clip_count（与 D53 同一量法）

FRAME = os.path.join(ROOT, "assets", "ui", "frames", "spot0_raw.png")
CARD_PNG = os.path.join(ROOT, "assets", "props", "key_card.png")
OUT = os.path.join(ROOT, "assets", "props", "preview_collectible.png")

PAL = G.STYLES["g"]                # 这批构件走 m5_style=g（props.json），只有门那几件留在 ab
GREEN = G.STYLES["a"]["accent2"]   # (104,201,102)：E6 引进的唯一一条新色相

ZOOM = 4
SPOT_X = 1150                      # 设备像素；spot0 里存档点终端右侧那段空地板
FLOOR_SEARCH = (300, 500)          # 找地面亮线的扫描区间
CROP_W, CROP_H = 64, 48            # 每格放大的设备像素盒
REAL_W, REAL_H = 150, 192          # 1:1 真机那格的暗底面板
LABEL_W = 400
CRT = (1.3, 0.10, 0.25, 0.0, 0.001)


# ------------------------------------------------------------------ 零件（世界像素）

def _cv(w, h):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def part_fuse(p):
    """E1 熔丝管 6x12：两端钢帽 + 琥珀玻璃体 + 中间一根细丝。关卡腔调，一眼是元件。"""
    img = _cv(6, 12)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.rectangle([0, 0, 5, 1], fill=G.lighter(p["metal"], 0.20))
    d.rectangle([0, 10, 5, 11], fill=p["metal"])
    d.rectangle([1, 2, 4, 9], fill=G.mix(a, p["glass"], 0.25))
    d.rectangle([1, 2, 1, 9], fill=G.lighter(a, 0.55))
    d.rectangle([3, 2, 3, 9], fill=G.darker(a, 0.45))
    d.rectangle([2, 5, 3, 6], fill=G.lighter(a, 0.70))
    return P._rim(img, p)


def part_chip(p):
    """E2 旧芯片 12x9：暗体 + 亮描边 + 每侧三条腿 + 一块琥珀标记。"""
    img = _cv(12, 9)
    d = ImageDraw.Draw(img)
    for row in (1, 4, 7):
        d.rectangle([0, row, 1, row], fill=p["metal"])
        d.rectangle([10, row, 11, row], fill=p["metal"])
    d.rectangle([2, 0, 9, 8], fill=p["deep"])
    d.rectangle([2, 0, 9, 8], outline=p["lip"])
    d.rectangle([2, 0, 9, 0], fill=G.lighter(p["metal"], 0.16))
    d.rectangle([4, 3, 6, 5], fill=p["accent2"])
    return P._rim(img, p)


def part_vial(p):
    """E3 样本瓶 8x12：钢盖 + 玻璃颈 + 下半截琥珀液。放进来是赌"玻璃那一档"离墙色多远。"""
    img = _cv(8, 12)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.rectangle([2, 0, 5, 1], fill=G.lighter(p["metal"], 0.20))
    d.rectangle([3, 2, 4, 3], fill=G.darker(p["glass"], 0.30))
    d.rectangle([1, 4, 6, 11], fill=G.darker(p["glass"], 0.10))
    d.rectangle([2, 7, 5, 10], fill=a)
    d.rectangle([2, 7, 5, 7], fill=G.lighter(a, 0.40))
    d.rectangle([1, 5, 1, 10], fill=G.lighter(p["glass"], 0.55))
    return P._rim(img, p)


def part_duck(p):
    """E4 小黄鸭 12x11：与世界观毫不相干的那一族，颜色正好就是琥珀那一档 —— 撞色风险最高。"""
    img = _cv(12, 11)
    d = ImageDraw.Draw(img)
    a = p["accent2"]
    d.ellipse([0, 4, 11, 10], fill=a)
    d.ellipse([5, 0, 11, 6], fill=G.lighter(a, 0.18))
    d.rectangle([11, 2, 11, 3], fill=G.darker(a, 0.42))
    d.rectangle([8, 1, 9, 2], fill=p["edge"])
    d.rectangle([2, 6, 6, 8], fill=G.darker(a, 0.22))
    d.rectangle([0, 3, 1, 5], fill=a)
    return P._rim(img, p)


def part_cup(p):
    """E5 纸杯咖啡 9x11：白杯身撞的是「亮白钢=会咬人」那条，量它会不会被读成尖刺。"""
    img = _cv(9, 11)
    d = ImageDraw.Draw(img)
    d.rectangle([1, 0, 7, 1], fill=p["edge"])
    d.polygon([(1, 2), (7, 2), (6, 10), (2, 10)], fill=p["lip"])
    d.rectangle([2, 4, 6, 6], fill=p["metal"])
    d.rectangle([2, 2, 2, 10], fill=G.lighter(p["lip"], 0.30))
    return P._rim(img, p)


def part_cactus(p):
    """E6 一截仙人掌 10x13：全项目唯一一条绿。它违 D29 的色语言，所以读数必须替它说话。"""
    img = _cv(10, 13)
    d = ImageDraw.Draw(img)
    d.rectangle([4, 1, 6, 12], fill=GREEN)
    d.rectangle([4, 1, 4, 12], fill=G.lighter(GREEN, 0.30))
    d.rectangle([1, 4, 2, 8], fill=GREEN)
    d.rectangle([1, 8, 4, 9], fill=GREEN)
    d.rectangle([7, 2, 8, 6], fill=GREEN)
    d.rectangle([6, 6, 8, 7], fill=GREEN)
    for x, y in ((5, 3), (5, 7), (1, 6), (8, 4)):
        d.rectangle([x, y, x, y], fill=G.darker(GREEN, 0.55))
    d.rectangle([3, 12, 6, 12], fill=G.darker(GREEN, 0.35))
    return P._rim(img, p)


def part_shard(p):
    """E7 亮青菱形 10x10：违例对照 —— 青在这个项目里是"光与电/能力"，D44 那三枚环就是它。"""
    img = _cv(10, 10)
    d = ImageDraw.Draw(img)
    d.polygon([(5, 0), (9, 5), (5, 9), (1, 5)], fill=G.lighter(p["accent"], 0.30))
    d.polygon([(5, 2), (7, 5), (5, 8), (3, 5)], fill=p["accent"])
    d.rectangle([4, 4, 5, 5], fill=G.lighter(p["accent"], 0.75))
    return P._rim(img, p)


# 底座与"零件坐上去"这两份算式在 gen_props（落盘的单一来源）里 —— 选型图与资产必须同图，
# 所以这里只做转发：写第二份就是等着哪天改一边漏一边。
part_socket = P.part_perch


def sprite(part, taken, dim=False):
    return P.duck_perched(PAL, part, taken, dim)


ROWS = (
    ("R 参照·能量卡（无底座）", None,
     "D29 琥珀=可拾取的既有住户。拾走之后原地什么都不留 —— 这一行是「不留痕」那条路线的对照，不是候选"),
    ("E1 熔丝管", part_fuse, "关卡腔调：钢帽 + 琥珀玻璃 + 细丝。与卡同为琥珀，但形状不撞"),
    ("E2 旧芯片", part_chip, "关卡腔调：暗体 + 琥珀标记。暗体压不压得过低光背景，看第一条读数"),
    ("E3 样本瓶", part_vial, "关卡腔调：玻璃颈 + 下半截琥珀液。玻璃那一档离墙色最近，最容易糊"),
    ("E4 小黄鸭", part_duck, "不搭调彩蛋腔：跟实验室毫不相干。整只都是琥珀那一档，撞色风险最高"),
    ("E5 纸杯咖啡", part_cup, "不搭调彩蛋腔：白杯身撞「亮白钢=会咬人」，量它会不会被读成尖刺"),
    ("E6 一截仙人掌", part_cactus, "不搭调 + 引进全项目唯一一条绿：破 D29 色语言，读数就是它的代价"),
    ("E7 亮青菱形", part_shard, "违例对照：青 = 光与电，D44 那三枚环就是它。让「像能力」这件事被看见"),
)


def _paste_state(frame, art, cx, floor_y):
    """按真机比例（1 世界 px = 2 设备 px）贴进真帧：底边压在地面亮线上方一行。"""
    dev = art.resize((art.width * 2, art.height * 2), Image.NEAREST)
    out = frame.copy()
    out.paste(dev, (cx - dev.width // 2, floor_y - dev.height), dev)
    return out


SOCK_H = 5          # 公共底座的世界像素高度；量"本体"时把它排除掉


def _footprint(art, cx, floor_y, exclude_bottom=0):
    """art 上那些**不透明**像元落到设备坐标上的位置清单。

    为什么不能像 D53 那样量外接盒：那颗灯是 4×4 全不透明，盒就是它；而这里一只 14x17
    的候选里真正有像素的只有三成，剩下全是墙 —— 拿盒均值量，八行读数会一起塌到 1.3 上下，
    因为分母是同一面墙。所以本体这条量 footprint，"留痕"那条量**有物态的同一份 footprint**
    （拿走之后那些点变回墙与座面，这正是回去那一眼看到的东西）。
    """
    x0 = cx - art.width
    y0 = floor_y - art.height * 2
    pts = []
    px = art.load()
    for wy in range(art.height - exclude_bottom):
        for wx in range(art.width):
            if px[wx, wy][3] < 200:
                continue
            dx, dy = x0 + wx * 2, y0 + wy * 2
            pts.extend(((dx, dy), (dx + 1, dy), (dx, dy + 1), (dx + 1, dy + 1)))
    return pts


def _mean_pts(im, pts):
    px = im.load()
    acc = [0, 0, 0]
    for x, y in pts:
        c = px[x, y]
        acc[0] += c[0]
        acc[1] += c[1]
        acc[2] += c[2]
    n = max(1, len(pts))
    return tuple(round(v / n) for v in acc)


def _clip_pts(im, pts):
    px = im.load()
    return sum(1 for x, y in pts if 255 in px[x, y][:3])


def main():
    raw = Image.open(FRAME).convert("RGB")
    assert raw.size == (F.W, F.H), "底片尺寸与 crt() 假设的 1280×720 不符：%s" % (raw.size,)

    # 地面亮线：整幅里最亮的一横条，逐行求和找它 —— 不写死坐标，换底片才不会静默落歪。
    px = raw.load()
    floor_y = max((sum(sum(px[x, y][:3]) for x in range(SPOT_X - 60, SPOT_X + 60)), y)
                  for y in range(*FLOOR_SEARCH))[1]
    wall_box = (SPOT_X - 96, floor_y - 56, SPOT_X - 64, floor_y - 24)
    floor_box = (SPOT_X + 64, floor_y + 16, SPOT_X + 96, floor_y + 40)
    crop = (SPOT_X - CROP_W // 2, floor_y - CROP_H + 8,
            SPOT_X + CROP_W // 2 - 1, floor_y + 7)
    print("自检：地面亮线 y=%d（扫描区间 %s）" % (floor_y, FLOOR_SEARCH))
    print("  墙 %s = %s   地 %s = %s" % (wall_box, A._mean(raw, wall_box),
                                        floor_box, A._mean(raw, floor_box)))

    # 分母一律取"滤镜后的它"：撞色这条要跟玩家真看到的那张卡比，不是跟裸色比（D53 同一口径）。
    card = Image.open(CARD_PNG).convert("RGBA")
    card_f = F.crt(_paste_state(raw, card, SPOT_X, floor_y), *CRT)
    card_mean = _mean_pts(card_f, _footprint(card, SPOT_X, floor_y))
    print("  CRT 后能量卡整块均值 = %s（撞色这条的分母）" % (card_mean,))
    bare_f = F.crt(raw, *CRT)

    small = _font(12)
    big = _font(19)
    cell_w, cell_h = CROP_W * ZOOM, CROP_H * ZOOM
    ctx_box = (SPOT_X - 150, floor_y - 150, SPOT_X + 129, floor_y + 40)
    ctx_z = 2
    cw = (ctx_box[2] - ctx_box[0] + 1) * ctx_z
    ch = (ctx_box[3] - ctx_box[1] + 1) * ctx_z
    head_h = ch + 92
    pad = 10
    row_h = cell_h + 2 * pad + 44
    W = LABEL_W + cell_w * 3 + REAL_W + pad * 5 + 430   # 末尾那 430 是右侧读数列，别把它挤到画布外
    H = head_h + len(ROWS) * row_h + pad
    out = Image.new("RGB", (W, H), (12, 15, 23))
    d = ImageDraw.Draw(out)

    # 顶部方位带：同一块真帧，左裸右滤镜，红框标出下面逐行放大的就是那一格。
    out.paste(A._zoom(raw, ctx_box, ctx_z), (pad, 40))
    out.paste(A._zoom(bare_f, ctx_box, ctx_z), (pad + cw + 16, 40))
    for i in range(2):
        x0 = pad + i * (cw + 16) + (crop[0] - ctx_box[0]) * ctx_z
        y0 = 40 + (crop[1] - ctx_box[1]) * ctx_z
        d.rectangle([x0 - 1, y0 - 1, x0 + CROP_W * ctx_z, y0 + CROP_H * ctx_z],
                    outline=(255, 64, 58), width=2)
    d.text((pad, 12), "方位参考：spot0 真帧里存档点终端右侧那段空地板（左 = 裸帧，右 = 套 CRT），红框 = 下面逐行放大的那一格",
           fill=(214, 224, 240), font=small)

    y = head_h
    for name, fn, note in ROWS:
        art = None if fn is None else fn(PAL)
        full = card if art is None else sprite(art, False)
        empty = None if art is None else sprite(art, True)
        full_raw = _paste_state(raw, full, SPOT_X, floor_y)
        f_full = F.crt(full_raw, *CRT)
        # 本体那条量 footprint（不含底座，座子八行共用一只、留着只会把差压平）；
        # 留痕那条量**有物态的整份 footprint**，两态取同一批点才可比。
        core_pts = _footprint(full, SPOT_X, floor_y, 0 if art is None else SOCK_H)
        foot_pts = _footprint(full, SPOT_X, floor_y)
        core_raw = _mean_pts(full_raw, core_pts)
        core_f = _mean_pts(f_full, core_pts)
        n_px = len(core_pts)
        cr_wall = G._cr(core_f, A._mean(f_full, wall_box))
        cr_floor = G._cr(core_f, A._mean(f_full, floor_box))
        cr_card = G._cr(core_f, card_mean)
        clip = _clip_pts(f_full, core_pts)
        if empty is None:
            empty_f = bare_f
            cr_taken = G._cr(_mean_pts(f_full, foot_pts), _mean_pts(bare_f, foot_pts))
            cr_dim = cr_taken
            taken_note = "对「空地板」cr=%.2f（拾走不留痕：差只能靠本体自己）" % cr_taken
        else:
            empty_f = F.crt(_paste_state(raw, empty, SPOT_X, floor_y), *CRT)
            dim_f = F.crt(_paste_state(raw, sprite(art, True, True), SPOT_X, floor_y), *CRT)
            cr_taken = G._cr(_mean_pts(f_full, foot_pts), _mean_pts(empty_f, foot_pts))
            cr_dim = G._cr(_mean_pts(f_full, foot_pts), _mean_pts(dim_f, foot_pts))
            taken_note = "对「空座」cr=%.2f → 加强档（座面亮线也灭）cr=%.2f" % (cr_taken, cr_dim)

        d.text((pad, y + 2), name, fill=(228, 236, 248), font=big)
        for i, t in enumerate(A._wrap(d, note, small, LABEL_W - pad - 40, 3)):
            d.text((pad, y + 30 + i * 16), t, fill=(150, 164, 186), font=small)
        out.paste(A._zoom(full_raw, crop, ZOOM), (LABEL_W, y + pad))
        out.paste(A._zoom(f_full, crop, ZOOM), (LABEL_W + cell_w + pad, y + pad))
        out.paste(A._zoom(empty_f, crop, ZOOM), (LABEL_W + cell_w * 2 + pad * 2, y + pad))

        # 1:1 真机那一格：左 = 在，右 = 拿走，全按屏幕真实尺寸，一格都不放大。
        panel = _paste_state(raw, full, SPOT_X - 22, floor_y)
        if empty is not None:
            panel = _paste_state(panel, empty, SPOT_X + 22, floor_y)
        panel = F.crt(panel, *CRT).crop((SPOT_X - REAL_W // 2, floor_y - 96,
                                        SPOT_X - REAL_W // 2 + REAL_W, floor_y - 96 + REAL_H))
        out.paste(panel, (LABEL_W + cell_w * 3 + pad * 3, y + pad))
        ImageDraw.Draw(out).rectangle([LABEL_W + cell_w * 3 + pad * 3, y + pad,
                                       LABEL_W + cell_w * 3 + pad * 3 + REAL_W - 1,
                                       y + pad + REAL_H - 1], outline=(40, 50, 66))

        x = LABEL_W + cell_w * 3 + REAL_W + pad * 4
        lines = (
            "占位 %dx%d 世界 px   本体不透明 %d 设备 px" % (full.width, full.height, n_px),
            "裸帧本体 %s -> CRT 后 %s   削顶 %d/%d px" % (core_raw, core_f, clip, n_px),
            "对墙 cr=%.2f   对地 cr=%.2f" % (cr_wall, cr_floor),
            "对 CRT 后能量卡 cr=%.2f" % cr_card,
            taken_note,
            "D26 下限 4.5；对卡 < 2 就是「和开门素材一个颜色」",
        )
        for i, t in enumerate(lines):
            d.text((x, y + pad + 4 + i * 19), t,
                   fill=(190, 205, 226) if i < 5 else (250, 190, 74), font=small)
        d.text((LABEL_W, y + pad + cell_h + 2), "裸帧（留档）", fill=(150, 164, 186), font=small)
        d.text((LABEL_W + cell_w + pad, y + pad + cell_h + 2), "套 CRT（真账）", fill=(150, 164, 186), font=small)
        d.text((LABEL_W + cell_w * 2 + pad * 2, y + pad + cell_h + 2), "套 CRT · 已拿走", fill=(150, 164, 186), font=small)
        d.text((LABEL_W + cell_w * 3 + pad * 3, y + pad + cell_h + 2), "1:1 真机（左在 / 右空）", fill=(150, 164, 186), font=small)
        print("%-22s %2dx%-2d 裸%s -> CRT后%s | 墙 %.2f  地 %.2f  对卡 %.2f  留痕 %.2f/%.2f  削顶 %d/%d"
              % (name, full.width, full.height, core_raw, core_f, cr_wall, cr_floor,
                 cr_card, cr_taken, cr_dim, clip, n_px))
        y += row_h

    d.line([(pad, head_h - 6), (W - pad, head_h - 6)], fill=(40, 50, 66))
    for i in range(1, len(ROWS)):
        yy = head_h + i * row_h - 6
        d.line([(pad, yy), (W - pad, yy)], fill=(30, 38, 52))
    out.save(OUT)
    print("WROTE %s  %dx%d" % (OUT, W, H))


def _font(size):
    return G._font(size)


if __name__ == "__main__":
    main()
