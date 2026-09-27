"""世界钟选型图（D59）：把「世界时间在走」这件事变成一个可以盯着看的东西。

用法：py tools/gen_clock_preview.py        ->  assets/props/preview_clock.png
      py tools/gen_clock_preview.py --gif  ->  assets/props/preview_clock_anim.gif

要解决的问题很具体：能力是「按住水平方向 = 世界停」（D1 起就是这一条），而它**看不见** ——
玩家能看见的只有 D46 那层全屏 CRT，以及「附近那些构件恰好都不动了」。祭坛演完那一拍之后，
没有任何东西告诉他「你现在能让时间停了」。一只钟的价值就在这里：**它是唯一一个「动的理由
就是世界时间在走」的东西** —— 它停了 = 时间停了，不需要先认识门、活塞、电棒各自怎么停。

七档候选全部只用已在册的语言（`STYLES["g"]` 那套暗底夜光 + 亮白描边 + 青=灯/运行 + 近黑屏），
**一颗琥珀像素都不放**（琥珀 = 可拾取，D29），**一个数字都不写**（全项目零文字，D56 同规矩 ——
表盘上只有刻度，没有 12 3 6 9）。

静图量四条账（每一档都过一遍真帧 + CRT，量的是 1:1 那一份）：
  1. 壳对墙：预期 1.x（`deep` 56,66,100 对 `bg` 74,84,118）—— 钢壳在夜光墙上本来就隐形，
     整只钟的可见度必须由亮白环与屏上图形承担（D55 座子 1.04、D56 牌框 1.1 同一个发现）。
  2. 热行部对表盘：读不读得出「那根在动的东西」。热行部 = 每档里那个**随世界时间换位置**的
     部件（针 / 亮段 / 沙 / 齿上那道青标 / 摆锤），它是唯一会说谎也会说真话的部分。
  3. 热行部对墙：假如壳隐形、针又比墙暗，那这只钟在远处就是一个洞。
  4. 刻度对表盘：刻度是「停在哪一格」的参照物，没有它「停」就只能靠上一帧的记忆。

动图答的才是这一条真正要判的事：走 → 他按住方向键（世界停 + CRT 上）→ 松手（走）。
静图挑形状，动图挑「那一下停不停得住眼睛」。
"""

import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                      # _cr / lighter / darker / mix
import gen_freeze_filter_preview as F      # crt()：D46 已验过它与实机 shader 对得上
import gen_props as P                      # _rim：非平铺件那圈朝外描边
import gen_gate_alert_preview as A         # _mean / _zoom / _wrap：与 D53 同一量法
import gen_collectible_preview as C        # 与 D54/D55/D56 同一块地板、同一条算式、同一批分母盒

PAL = C.PAL
CRT = C.CRT
OUT = os.path.join(ROOT, "assets", "props", "preview_clock.png")
OUT_GIF = os.path.join(ROOT, "assets", "props", "preview_clock_anim.gif")

PERIOD = 8.0        # 参照档：一圈 8 s（12 道刻度 => 一格 0.67 s）。选型图与动图都吃这一个数
TICKS = 12
TAU = math.pi * 2


# ------------------------------------------------------------------ 画布（世界像素）

class Cv:
    """逐像素画 + 顺手把每类像素的世界坐标记下来。

    为什么记坐标而不是量外接盒：一只 18x18 的钟里真正有像素的只有四成，剩下全是墙 ——
    拿盒均值量，七行读数会一起塌到 1.2 上下，因为分母是同一面墙（D54 那条 footprint 的理）。
    """

    def __init__(self, w, h):
        # 透明底：非平铺件的语汇就是"只有零件自己那圈像素"（gen_props 那批零件全这样）。
        # 这一版一开始误填成不透明黑，于是七只钟各自背着一块 18x18 的黑盒子贴进真帧 ——
        # 黑盒子对那面墙的比 3.6 上下，跟亮白环一样显眼，而读数里根本没有它。
        self.img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        self.own = {}

    def px(self, x, y, col, key=None):
        if 0 <= x < self.img.width and 0 <= y < self.img.height:
            self.img.putpixel((x, y), col)
            # 后画的说了算：一个点只能属于一类。不这么记，D 那圈「未亮点亮的槽」会同时留在
            # dial 集里 —— 分母被自己刚调亮的点污染，读数一路从 6.10 塌到 1.43（这一版的现场）。
            self.own[(x, y)] = key or self.own.get((x, y))

    def box(self, x0, y0, x1, y1, col, key=None):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, y, col, key)

    def done(self):
        sets = {"case": [], "dial": [], "hot": [], "mark": []}
        for (x, y), k in self.own.items():
            if k in sets:
                sets[k].append((x, y))
        return P._rim(self.img, PAL), sets


def _hand(c, cx, cy, ang, r0, r1, col, step=0.30):
    """一根从 r0 走到 r1 的针：沿角度按 step 世界像素采样，整数化落点（全是整像素，无插值）。"""
    r = r0
    while r <= r1:
        c.px(int(round(cx + r * math.sin(ang))), int(round(cy - r * math.cos(ang))), col, "hot")
        r += step


def _ticks(c, cx, cy, r, col):
    for k in range(TICKS):
        a = k * TAU / TICKS
        c.px(int(round(cx + r * math.sin(a))), int(round(cy - r * math.cos(a))), col, "mark")


def _dial(c, cx, cy, r_in, r_ring, p):
    """一块圆盘：外圈亮白钢环 + 环下那道暗唇（给环一点厚度）+ 近黑表盘。"""
    for y in range(int(cy - r_ring) - 1, int(cy + r_ring) + 2):
        for x in range(int(cx - r_ring) - 1, int(cx + r_ring) + 2):
            r = math.hypot(x - cx, y - cy)
            if r > r_ring:
                continue
            if r > r_ring - 1.0:
                c.px(x, y, p["lip"], "case")
            elif r > r_ring - 1.7:
                c.px(x, y, G.darker(p["lip"], 0.50), "case")
            elif r <= r_in:
                c.px(x, y, p["screen"], "dial")


def _plate(c, w, h, p):
    """钢壳：deep 底 + 一圈亮白描边 + 顶边那道亮唇（与 decor_cabinet 同一档厚度）。"""
    c.box(1, 1, w - 2, h - 2, p["deep"], "case")
    for x in range(1, w - 1):
        c.px(x, 1, p["lip"], "case")
        c.px(x, 2, G.lighter(p["metal"], 0.18), "case")
        c.px(x, h - 2, G.darker(p["lip"], 0.55), "case")
    for y in range(1, h - 1):
        c.px(1, y, p["lip"], "case")
        c.px(w - 2, y, p["lip"], "case")


# ------------------------------------------------------------------ 七档候选（t = 世界秒）

def cand_round_cyan(t, p):
    """A 圆盘挂钟 · 青针：最字面的一只钟。针走青 = D29 之后「灯 / 运行」那一档（D44 三枚环同色）。"""
    w = 18
    c = Cv(w, w)
    cx = cy = (w - 1) / 2.0
    _dial(c, cx, cy, 6.6, 8.0, p)
    _ticks(c, cx, cy, 5.6, p["lip_shade"])
    _hand(c, cx, cy, (t / PERIOD) * TAU, 0.6, 5.2, p["accent"])
    c.px(int(round(cx)), int(round(cy)), p["lip"], "case")
    return c.done()


def cand_round_white(t, p):
    """B 圆盘挂钟 · 亮白针：与 A 逐像素同形，只换针色。亮白 = 全项目唯一能把东西从暗墙上
    摘出来的颜色（D26），代价是针与钢环同色，「在动的那根」只能靠长度读。"""
    w = 18
    c = Cv(w, w)
    cx = cy = (w - 1) / 2.0
    _dial(c, cx, cy, 6.6, 8.0, p)
    _ticks(c, cx, cy, 5.6, p["lip_shade"])
    _hand(c, cx, cy, (t / PERIOD) * TAU, 0.6, 5.2, p["lip"])
    c.px(int(round(cx)), int(round(cy)), G.darker(p["lip"], 0.35), "case")
    return c.done()


def cand_instrument(t, p):
    """C 方壳圆窗 + 一颗运行灯：实验室仪器的做法 —— 钢壳里开一块圆窗，针在窗里，壳底那颗
    2x2 的灯 = 「这台机器在运行」。冻结那一拍灯灭（D4 那条「要不要多给一条收据」的实物）。"""
    w, h = 18, 22
    c = Cv(w, h)
    _plate(c, w, h, p)
    cx = (w - 1) / 2.0
    _dial(c, cx, 8.0, 5.6, 6.8, p)
    _ticks(c, cx, 8.0, 4.6, p["lip_shade"])
    _hand(c, cx, 8.0, (t / PERIOD) * TAU, 0.5, 4.2, p["accent"])
    c.px(int(round(cx)), int(round(8.0)), p["lip"], "case")
    c.box(6, h - 7, 8, h - 5, p["accent"], "hot")
    c.px(7, h - 6, G.lighter(p["accent"], 0.5), "hot")
    return c.done()


def cand_segments(t, p):
    """D 12 段走带（围成一圈）：没有针 —— 现在这一格亮着，往后拖两段青色余辉。赌的是
    「哪一格亮」比「针指在哪」更好读：真机 2 px 宽的针在 4x4 设备像素下只剩一条。"""
    w = 18
    c = Cv(w, w)
    cx = cy = (w - 1) / 2.0
    _dial(c, cx, cy, 7.4, 8.0, p)
    idx = int((t / PERIOD) * TICKS) % TICKS
    for k in range(TICKS):
        a = k * TAU / TICKS
        x = int(round(cx + 5.4 * math.sin(a)))
        y = int(round(cy - 5.4 * math.cos(a)))
        d = (idx - k) % TICKS
        col = (p["accent"] if d == 0 else G.darker(p["accent"], 0.45) if d == 1
               else G.darker(p["accent"], 0.72) if d == 2 else G.lighter(p["screen"], 0.60))
        c.box(x - 1, y - 1, x + 1, y + 1, col, "hot" if d <= 2 else "mark")
    c.px(int(round(cx)), int(round(cy)), p["lip"], "case")
    return c.done()


def cand_hourglass(t, p):
    """E 沙漏：钢顶底 + 两根立柱 + 两只玻璃斗，沙走青（不是琥珀 —— 琥珀=可拾取）。中间那一粒
    的位置是世界时间的函数 —— 冻结那一拍它就挂在半空，全表最直白的一笔。"""
    w, h = 14, 18
    c = Cv(w, h)
    ph = (t % PERIOD) / PERIOD
    cx = (w - 1) / 2.0
    c.box(1, 0, w - 2, 1, p["metal"], "case")
    c.box(1, h - 2, w - 2, h - 1, p["metal"], "case")
    for y in range(h):
        c.px(0, y, p["lip"], "case")
        c.px(w - 1, y, p["lip"], "case")
    for y in range(2, h - 2):
        # 两只斗都从中间那道颈往外张：上斗最宽在顶、下斗最宽在底（写反了就成了一个菱形色块）
        half = int(round(5.0 * abs(y - 8.5) / 6.5))
        if half <= 0:
            continue
        for x in range(int(cx) - half, int(cx) + half + 1):
            if y < 8:
                sand = y >= 2 + int(round(ph * 5.5))
            else:
                sand = y >= h - 3 - int(round(ph * 5.0))
            c.px(x, y, G.lighter(p["accent"], 0.15) if sand else G.darker(p["glass"], 0.55),
                 "hot" if sand else "dial")
    if ph < 0.97:
        c.px(int(round(cx)), 9, G.darker(p["accent"], 0.55), "hot")
        c.px(int(round(cx)), 9 + int((t * 2.0) % 4), p["accent"], "hot")
    return c.done()


def cand_gear(t, p):
    """F 齿轮：八齿、一圈一转。它说的不是「几点」，是「世界这台机器在转」—— 与残影踏板 / 活塞
    同族（纯 _draw()、零 PNG 零件）。齿上那道青标是给眼睛追的参照物。"""
    w = 18
    c = Cv(w, w)
    cx = cy = (w - 1) / 2.0
    rot = (t / PERIOD) * TAU
    for y in range(w):
        for x in range(w):
            dx, dy = x - cx, y - cy
            r = math.hypot(dx, dy)
            if r > 8.0:
                continue
            a = math.atan2(dx, -dy) - rot
            tooth = (a % (TAU / 8)) < (TAU / 16)
            if r > 6.6:
                if tooth:
                    c.px(x, y, G.lighter(p["metal"], 0.30), "case")
            elif r > 5.8:
                c.px(x, y, p["lip"], "case")
            elif r > 1.6:
                c.px(x, y, p["metal"], "case")
            else:
                c.px(x, y, p["screen"], "dial")
    _hand(c, cx, cy, rot, 2.2, 5.2, p["accent"])
    return c.done()


def cand_pendulum(t, p):
    """G 摆钟：上面一块小表盘、下面一只摆，摆的周期用现成 Pendulum 那条 sin 相位（D35 同族）。
    代价：Pendulum 在手册 §5 里的语义是「会咬人的东西在走」，同一只摆两种意思。"""
    w, h = 18, 24
    c = Cv(w, h)
    _plate(c, w, h, p)
    cx = (w - 1) / 2.0
    _dial(c, cx, 7.0, 4.2, 5.4, p)
    _ticks(c, cx, 7.0, 3.4, p["lip_shade"])
    _hand(c, cx, 7.0, (t / PERIOD) * TAU, 0.4, 3.0, p["accent"])
    ang = math.sin((t / PERIOD) * TAU) * 0.42
    px0, py0, ln = cx, 12.0, 8.0
    r = 0.3
    while r <= ln:
        c.px(int(round(px0 + r * math.sin(ang))), int(round(py0 + r * math.cos(ang))),
             G.lighter(p["metal"], 0.25), "mark")
        r += 0.35
    bx = int(round(px0 + ln * math.sin(ang)))
    by = int(round(py0 + ln * math.cos(ang)))
    c.box(bx - 1, by, bx + 1, by + 2, p["lip"], "hot")
    c.px(bx, by, G.lighter(p["metal"], 0.55), "hot")
    c.px(bx, by + 2, G.darker(p["lip"], 0.45), "hot")
    return c.done()


CANDS = (
    ("A 圆盘挂钟 18x18 · 青针｜12 道刻度", cand_round_cyan,
     "最字面的一只钟：亮白钢环 + 近黑表盘 + 12 道刻度 + 一根青针。针走青是 D29 之后"
     "「灯 / 运行」那一档（D44 那三枚环同色），一颗琥珀都不放。一圈 8 s => 一格 0.67 s"),
    ("B 圆盘挂钟 18x18 · 亮白针", cand_round_white,
     "与 A 逐像素同形，只换针色：亮白是全项目唯一能把东西从暗墙上摘出来的颜色（D26）。"
     "代价：针与钢环同色，「在动的那根」只能靠长度读，不靠颜色"),
    ("C 方壳圆窗 18x22 + 一颗运行灯", cand_instrument,
     "实验室仪器的做法：钢壳里开一块圆窗，针在窗里，壳底那颗 2x2 的灯 = 「这台机器在运行」。"
     "冻结那一拍灯灭 —— 这是 D4「要不要多给一条收据」那一档的实物，代价是多一颗会变的灯"),
    ("D 12 段走带 18x18（围成一圈）", cand_segments,
     "没有针：现在这一格亮着，往后拖两段青色余辉。赌的是「哪一格亮」比「针指在哪」更好读 —— "
     "真机 2 px 宽的针在 4x4 设备像素下只剩一条。代价：它读起来更像仪表而不像钟"),
    ("E 沙漏 14x18", cand_hourglass,
     "钢顶底 + 两根立柱 + 两只玻璃斗，沙走青。中间那一粒的位置是世界时间的函数 —— 冻结那一拍"
     "它就挂在半空，全表最直白的一笔。代价：14 px 宽里沙流只有 1 px，且「沙漏」离实验室腔调最远"),
    ("F 齿轮 18x18 · 八齿", cand_gear,
     "它说的不是「几点」，是「世界这台机器在转」。与残影踏板 / 活塞同族（纯 _draw()、零 PNG 零件）。"
     "代价两条：没有刻度，「停在哪一格」无从比对；一圈八齿 = 八次视觉重复，慢速时会读成抖动"),
    ("G 摆钟 18x24（小表盘 + 摆）", cand_pendulum,
     "上面一块小表盘、下面一只摆，摆用现成 Pendulum 那条 sin 相位。代价两条：同一只摆在"
     "手册 §5 里已经有一个意思了（「会咬人的东西在走」），而摆锤要看得见就得走亮白 —— 正好"
     "撞 D54 记过的那一档「亮白钢=会咬人」"),
)


# ------------------------------------------------------------------ 贴帧与量取

def _floor_y(raw):
    pxa = raw.load()
    best, out = -1, 0
    for y in range(*C.FLOOR_SEARCH):
        s = sum(sum(pxa[x, y]) for x in range(C.SPOT_X - 60, C.SPOT_X + 60))
        if s > best:
            best, out = s, y
    return out


def _dev(pts, ox, oy):
    """世界像素坐标 -> 设备像素（相机 zoom=2，1 世界 px = 2x2 设备 px）。"""
    out = []
    for x, y in pts:
        out.extend(((ox + x * 2, oy + y * 2), (ox + x * 2 + 1, oy + y * 2),
                    (ox + x * 2, oy + y * 2 + 1), (ox + x * 2 + 1, oy + y * 2 + 1)))
    return out


def _paste(frame, art, cx, bottom):
    """按真机比例贴进真帧：水平中心 cx、底边 bottom（都是设备像素）。返回 (图, 左上角)。"""
    dev = art.resize((art.width * 2, art.height * 2), Image.NEAREST)
    out = frame.copy()
    ox, oy = cx - dev.width // 2, bottom - dev.height
    out.paste(dev, (ox, oy), dev)
    return out, ox, oy


def _cr(a, b):
    """G._cr 的两个点集都必须非空才有意义 —— 空集时 C._mean_pts 返回 (0,0,0)，
    那是一个纯黑的假分母，会把读数推到 20 或压到 1，两种都够骗人。所以缺就报 n/a。"""
    return None if (a is None or b is None) else G._cr(a, b)


def measure(raw, t, fn, cx, bottom, wall_box):
    art, sets = fn(t, PAL)
    full, ox, oy = _paste(raw, art, cx, bottom)
    f = F.crt(full, *CRT)
    hot = _dev(sets["hot"], ox, oy)
    hs = set(hot)
    dial = [q for q in _dev(sets["dial"], ox, oy) if q not in hs]
    case = [q for q in _dev(sets["case"], ox, oy) if q not in hs]
    mark = [q for q in _dev(sets["mark"], ox, oy) if q not in hs]
    hm = C._mean_pts(f, hot) if hot else None
    dm = C._mean_pts(f, dial) if dial else None
    cm = C._mean_pts(f, case) if case else None
    mm = C._mean_pts(f, mark) if mark else None
    wm = A._mean(f, wall_box)
    return dict(art=art, full=full, f=f, ox=ox, oy=oy,
                cr_hot_dial=_cr(hm, dm), cr_hot_wall=_cr(hm, wm),
                cr_case_wall=_cr(cm, wm), cr_mark_dial=_cr(mm, dm),
                hot_mean=hm, dial_mean=dm, wall_mean=wm, n_dial=len(dial) // 4,
                n_hot=len(hot) // 4, n_mark=len(mark) // 4, clip=C._clip_pts(f, hot))


def _f(v):
    return " n/a " if v is None else "%.2f" % v


def strip_row(out, y, small, big, label, note, m, phases, fn, crop, cw, ch):
    d = ImageDraw.Draw(out)
    d.text((10, y + 2), label, fill=(228, 236, 248), font=big)
    for i, s in enumerate(A._wrap(d, note, small, 372, 6)):
        d.text((10, y + 28 + i * 15), s, fill=(150, 164, 186), font=small)
    x = 400
    for ph in phases:
        art, _ = fn(ph * PERIOD, PAL)
        z = art.resize((art.width * 4, art.height * 4), Image.NEAREST)
        out.paste(z, (x, y + 6), z)
        d.rectangle([x, y + 6, x + z.width - 1, y + 5 + z.height], outline=(40, 50, 66))
        d.text((x + 2, y + 12 + z.height), "%.2f 圈" % ph, fill=(150, 164, 186), font=small)
        x += z.width + 10
    out.paste(A._zoom(m["f"], crop, 3), (x, y + 6))
    d.text((x + 2, y + 18 + ch * 3), "套 CRT（真账）", fill=(150, 164, 186), font=small)
    x += cw * 3 + 16
    rb = (m["ox"] - 12, m["oy"] - 12, m["ox"] + m["art"].width * 2 + 12,
          m["oy"] + m["art"].height * 2 + 12)
    real = m["f"].crop(rb)
    out.paste(real, (x, y + 6))
    d.rectangle([x, y + 6, x + real.width - 1, y + 5 + real.height], outline=(40, 50, 66))
    d.text((x + 2, y + 18 + real.height), "1:1 真机", fill=(150, 164, 186), font=small)
    lines = ("亮部对表盘 %s   对墙 %s" % (_f(m["cr_hot_dial"]), _f(m["cr_hot_wall"])),
             "壳对墙 %s（钢在夜光墙上隐形 = 预期）" % _f(m["cr_case_wall"]),
             "刻度对表盘 %s（表盘底 %d px）" % (_f(m["cr_mark_dial"]), m["n_dial"]),
             "亮部 %d 世界 px（%s）| 墙 %s | CRT 削顶 %d"
             % (m["n_hot"], m["hot_mean"], m["wall_mean"], m["clip"]),
             "读数一律量 1:1 那一份（D53 那条：别拿放大图的分母给自己放水）")
    for i, s in enumerate(lines):
        d.text((x + real.width + 26, y + 10 + i * 18), s,
               fill=(250, 190, 74) if i == len(lines) - 1 else (190, 205, 226), font=small)
    return 6 + max(ch * 3, real.height) + 52


def sheet():
    raw = Image.open(C.FRAME).convert("RGB")
    floor_y = _floor_y(raw)
    wall_box = (C.SPOT_X - 96, floor_y - 56, C.SPOT_X - 64, floor_y - 24)
    crop = (C.SPOT_X - 72, floor_y - 128, C.SPOT_X + 72, floor_y + 8)
    cw, ch = crop[2] - crop[0] + 1, crop[3] - crop[1] + 1
    small, big = C._font(12), C._font(19)
    out = Image.new("RGB", (1820, 240 + 8 * (ch * 3 + 140)), (12, 15, 23))
    d = ImageDraw.Draw(out)
    y = 12
    d.text((10, y), "世界钟（D59） 底片 = spot0 那块空地板（与 D54/D55/D56 同一条尺子）  "
                   "参照档：一圈 8 s / 12 道刻度 => 一格 0.67 s  —— 七档候选只用已在册的颜色，"
                   "零琥珀、零数字", fill=(214, 224, 240), font=small)
    y += 26
    d.text((10, y), "要判的不是「哪只好看」，是两件事：① 远处认不认得出「这是一只在走的东西」　"
                    "② 他按住方向键那一拍，它停下来的那一下读不读得出来（动图答第二条）",
           fill=(250, 190, 74), font=big)
    y += 30
    base = F.crt(raw, *CRT)
    out.paste(A._zoom(base, crop, 3), (400, y + 6))
    d.text((10, y + 2), "对照 · 墙上什么都没有（基线）", fill=(228, 236, 248), font=big)
    d.text((10, y + 28), "后面每一行的「对墙」分母都从这块墙上取（同一批点，不是同一片色）",
           fill=(150, 164, 186), font=small)
    d.text((402, y + 18 + ch * 3), "套 CRT（真账）", fill=(150, 164, 186), font=small)
    y += ch * 3 + 56

    for label, fn, note in CANDS:
        m = measure(raw, PERIOD * 0.25, fn, C.SPOT_X, floor_y - 40, wall_box)
        print("%-34s 热/盘 %s 热/墙 %s 壳/墙 %s 刻度/盘 %s 热 %d px %s 墙 %s 削顶 %d"
              % (label[:32], _f(m["cr_hot_dial"]), _f(m["cr_hot_wall"]), _f(m["cr_case_wall"]),
                 _f(m["cr_mark_dial"]), m["n_hot"], m["hot_mean"], m["wall_mean"], m["clip"]))
        y += strip_row(out, y, small, big, label, note, m, (0.0, 0.12, 0.25, 0.5), fn, crop, cw, ch)
    final = out.crop((0, 0, out.width, min(out.height, y + 20)))
    final.save(OUT)
    print("WROTE %s  %dx%d  地面亮线 y=%d" % (OUT, final.width, final.height, floor_y))


# ------------------------------------------------------------------ 走 / 停 动图

def gif():
    """一行七只钟挂在同一面墙上，下面主角走过去（= 世界停）再站住（= 世界走）。

    时间轴按真机比例算：`move_speed 260` 世界 px/s ⇒ 他横穿这 138 世界 px 的取景框要 0.53 s，
    所以「停」那一段取 0.8 s（含起步与停步的缓冲）—— 那就是试玩里一次短按方向键的长度，
    不是我把节奏放慢了。世界时钟 `wt` 在他走的那一段**不推进**，与 `TimeManager` 同一条性质。
    """
    raw = Image.open(C.FRAME).convert("RGB")
    floor_y = _floor_y(raw)
    crop = (C.SPOT_X - 152, floor_y - 150, C.SPOT_X + 76, floor_y + 10)
    cw, ch = crop[2] - crop[0] + 1, crop[3] - crop[1] + 1
    fps, total = 15, 4.0
    n = int(fps * total)
    walk0, walk1 = 1.0, 1.8                      # 这一段他按住方向键：世界停、CRT 上
    x0, x1 = crop[0] + 24, crop[2] - 44          # 设备像素：横穿取景框
    frames = []
    for k in range(n):
        tt = k / float(fps)
        walking = walk0 <= tt < walk1
        wt = tt if tt < walk0 else (walk0 if walking else walk0 + (tt - walk1))
        img = raw.copy()
        for i, (_label, fn, _note) in enumerate(CANDS):
            art, _ = fn(wt, PAL)
            img, _, _ = _paste(img, art, crop[0] + 26 + i * 44, floor_y - 44)
        clip = "run" if walking else "idle"
        ci = int(tt * (14.0 if walking else 6.0)) % (6 if walking else 8)
        sl = Image.open(os.path.join(ROOT, "assets", "player", "slime",
                                     "%s_%d.png" % (clip, ci))).convert("RGBA")
        if walking:
            sl = sl.transpose(Image.FLIP_LEFT_RIGHT)
        sl = sl.resize((88, 88), Image.NEAREST)
        frac = 0.0 if tt < walk0 else (1.0 if tt >= walk1 else (tt - walk0) / (walk1 - walk0))
        img.paste(sl, (int(round(x0 + (x1 - x0) * frac)) - 44, floor_y - 72), sl)
        if walking:
            img = F.crt(img, *CRT)
        frames.append(img.crop(crop).resize((cw * 2, ch * 2), Image.NEAREST))
    frames[0].save(OUT_GIF, save_all=True, append_images=frames[1:],
                   duration=int(1000 / fps), loop=0, disposal=2, optimize=False)
    print("WROTE %s  %d 帧 / %d fps / %.1f s（%.1f-%.1f s 那段 = 他按住方向键，世界停）"
          % (OUT_GIF, n, fps, total, walk0, walk1))


if __name__ == "__main__":
    if "--gif" in sys.argv:
        gif()
    else:
        sheet()
