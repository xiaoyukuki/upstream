"""残影踏板（D47 选型图）：一种「流动期无形、冻结期整条可踩」的下落构件。

主题已定 = CRT 余辉 / 残影体素：冻结态的视觉符号是 CRT（D46），那「画面被钉住的
那一刻，一直在落的东西被钉在半空，成一串能踩的台阶」就是同一套设定的推论，不是新设定。

这一版把上一版的错误前提改掉了。上一版画成「一格实心 + 两格鬼影」，好像只有最新那一格
硬。那条区分不存在：世界冻结时整条链一起停，每一格同时变实体——要让它只硬一格，就得
额外加一条"只有最后生成的那格算"，而那条跟"冻结 = 万物停"直接矛盾。所以图上的"尾迹"
其实不是某个格子的残影，它就是链上相邻的下一格。

于是真正要选的轴只剩一条：**同一条链，冻结态已经定死（实心青 + 亮白顶唇 = 和瓦片同一套
"能踩"），流动态用什么话说"穿得过去"。** 四行候选的冻结列几乎一样不是省事，是这条轴的
诚实结果——你只需要选一件事。

  A 薄壳      有轮廓没肉：最直接的"这是虚的"
  B 扫描线    条纹 = 没被钉住，跟 D46 那层滤镜共用一套语言
  C 导光带    整条链连成一束落下的光，冻结时断成一串台阶（两态差别最大）
  D 拖影      最虚：只剩一条竖直运动拖影，实体感最低
  E 换冻结皮  A 的流动壳 + **地皮**的冻结壳。想用它修前四条 1.7 的 body/door，结果量出来
              更糟（body/wall 2.2）：地皮色本来就贴着背景墙。留在图上是记账，别再试

算式与口径：
  底图 = assets/ui/frames/spot2_raw.png（真关卡帧，无玩家，1280x720）
  比例尺 = assets/player/slime 真帧 x2（世界像素 -> 设备像素）
  冻结列整帧过 gen_freeze_filter_preview.crt()，参数 = D46 裁定那一组
  对比度用 gen_tiles._cr，与瓦片/立绘守门同一条算式

局限：冻结列是**离线同算式**。构件真要上线前还得用 tools/frame_grab.tscn 实拍一次，
别拿这张图当实机验收。

—— 以上是 D47 那一版选型图的口径。D48 换的是**同一个问题的下一轮**：用户看实拍图后判
「没变实体时边框太明显」，A 那圈亮青描边退役（保留在图上当对照行），换三档更软的说法。
D48 同时给这个构件加了判死——冻结那一刻落脚点还压在格子里就算被埋——所以流动态这一版
要同时满足两件相反的事：**读得出「这是虚的、能穿过去」**，又**量得准「脚会落在哪一格」**。
描边一去掉，第二件就全靠身体那一坨渐变的边界：F/G 各留一条踩面线（差别只给多少墨），
H 连这条都不给 —— 那一行就是"完全不直线"的代价长什么样。
"""
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G
from gen_freeze_filter_preview import crt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = os.path.join(ROOT, "assets", "ui", "frames")
SLIME = os.path.join(ROOT, "assets", "player", "slime")
OUT = os.path.join(ROOT, "assets", "props", "preview_afterimage_flow.png")

W, H = 1280, 720
PAL = G.STYLES["g"]
CYAN = PAL["accent"]          # (110,230,240) 光与电
LIP = PAL["lip"]              # (206,222,250) 亮白
SURFACE = PAL["surface"]      # (104,120,164) 地皮
LIP_SHADE = PAL["lip_shade"]  # (150,168,210) 地皮点阵
GROUT = PAL["grout"]          # (80,94,134)  地皮缝
EDGE = PAL["edge"]

SHIPPED = dict(linear_fac=1.3, scan_fac=0.10, scan_width=0.25, aberration=0.001)

# 构件尺寸与间距全部用**世界像素**写，再 x2 变设备像素。
# 依据 docs/m2_level_01_layout.md：-400 档峰值 82 px、滞空 0.97 s、玩家盒 20x30。
BLOCK_W = 32
SPACING = 80                  # 台阶节距 = fall_speed x emit_interval = 400 x 0.20。
                              # 上限来自"至少两格同屏才读得出是一串在落的东西"：
                              # 屏上寿命 = 空气高 / V = 171 / 400 = 0.43 s，T > 0.21 就只剩一格
N_RUNGS = 2                   # 这帧的空气只有喷嘴（设备 44）到地面线（设备 ≈390）= 171 世界 px：
                              # 80 节距装两格（占 192 设备 px），三格要 192 世界 px 的房间
COL_X = 420                   # 世界像素 -> 设备 840..904：spot2 里最干净的一段背景墙
HEAD_Y = 156                  # 最低一格的顶边（世界像素）：底边 188 -> 设备 376，离地面线留 14
SCALE = 2

CELL_W, CELL_H = 640, 360
LABEL_W = 340
GAP = 8
CROP = (388, 232)             # 放大列只装"能不能爬"这一问：两格台阶 + 站在下面那格上的玩家
                              # 388x232 按高铺满 640x360，不出现黑边
CROP_AT = (678, 146)          # 格心 = 设备 x 872；纵向 146..378 装下两格 + 玩家 + 地面线


def px(v):
    return v * SCALE


def _wall(img, at=(500, 300)):
    return img.getpixel(at)


def block_rect(i):
    """第 i 格（0 = 最低那格）的设备像素矩形。i 越大越高。"""
    y = px(HEAD_Y - i * SPACING)
    x = px(COL_X)
    return [x, y, x + px(BLOCK_W), y + px(BLOCK_W)]


def draw_source(d, top_y_dev):
    """源头：天花板上一只喷嘴，告诉玩家"这东西一直在被生成"。只有 44 设备 px 的位置。"""
    x = px(COL_X) + px(BLOCK_W) // 2
    d.rectangle([x - 26, 0, x + 26, 6], fill=EDGE)
    d.polygon([(x - 22, 6), (x + 22, 6), (x + 8, 22), (x - 8, 22)],
              fill=(46, 56, 84), outline=LIP)
    d.rectangle([x - 8, 22, x + 8, 30], fill=CYAN)
    d.line([(x, 30), (x, top_y_dev - 4)], fill=(110, 130, 170), width=1)


def head_solid(d, r):
    """冻结皮肤：跟实体瓦片同一套话——实心青 + 顶唇亮白（踩的就是这条）。"""
    d.rectangle(r, fill=CYAN)
    d.line([(r[0], r[1]), (r[2], r[1])], fill=LIP, width=2)
    d.rectangle(r, outline=G.darker(CYAN, 0.45))


def terrain_solid(d, r):
    """E 的冻结皮肤：借**地皮**不借光。冻结 = 它成了地面的一部分，
    于是和那扇青门（accent 家族）天然分开——量出来 body/door 只有 1.7 就是这条要修的。"""
    d.rectangle(r, fill=SURFACE)
    for yy in range(r[1] + 8, r[3] - 4, 12):         # gummy 点阵，和地面同一密度
        for xx in range(r[0] + 6, r[2] - 4, 12):
            d.point((xx, yy), fill=LIP_SHADE)
    d.line([(r[0], r[1]), (r[2], r[1])], fill=LIP, width=2)
    d.rectangle(r, outline=GROUT)


def _vgrad(d, r, top, bottom):
    """竖向渐变的半透明填充，一行一行插值 alpha。
    叠两三层矩形会在暗底上看出台阶，逐行画才溶得开。"""
    h = r[3] - r[1]
    for i in range(h):
        k = i / float(max(h - 1, 1))
        col = tuple(int(round(top[c] + (bottom[c] - top[c]) * k)) for c in range(4))
        d.line([(r[0], r[1] + i), (r[2], r[1] + i)], fill=col)


def tail_rect(r):
    """尾迹落在身体**上方**：余辉在物体身后，它往下落、尾巴就朝上。
    左右各窄一档（5 世界 px），免得整列连成一根柱子、读不出格的边界。"""
    return [r[0] + 10, r[1] - (r[3] - r[1]), r[2] - 10, r[1]]


def flow_ghost(d, r):
    """F = D48 实装那一版：整圈描边去掉（那条 1 px 直线被读成"没填色的砖"），
    换成身体上暗下亮 + 往上溶到零的尾迹 + 踩面一道暗线。直线只剩"踩这条"一处。"""
    _vgrad(d, r, G.rgba(CYAN, 26), G.rgba(CYAN, 72))
    _vgrad(d, tail_rect(r), G.rgba(CYAN, 0), G.rgba(CYAN, 34))
    d.line([(r[0], r[1]), (r[2], r[1])], fill=G.rgba(LIP, 110))


def flow_streak(d, r):
    """G：身体几乎不给，墨迹全押在尾迹上。最贴"残影"两个字，
    代价是格的上下边界最含糊 —— 而 D48 之后判死带就压在那一格里。"""
    _vgrad(d, r, G.rgba(CYAN, 8), G.rgba(CYAN, 26))
    _vgrad(d, tail_rect(r), G.rgba(CYAN, 0), G.rgba(CYAN, 64))
    d.line([(r[0], r[1]), (r[2], r[1])], fill=G.rgba(LIP, 80))


def flow_bloom(d, r):
    """H：中心一团辉光，四条边一条直线都不给。最像"没被钉住的光"，
    也最容易让人误判落脚点到底在不在它里面。"""
    _vgrad(d, r, G.rgba(CYAN, 14), G.rgba(CYAN, 20))
    inset = (r[2] - r[0]) // 8
    d.rectangle([r[0] + inset, r[1] + inset, r[2] - inset, r[3] - inset],
                fill=G.rgba(CYAN, 30))
    core = (r[2] - r[0]) // 4
    d.rectangle([r[0] + core, r[1] + core, r[2] - core, r[3] - core],
                fill=G.rgba(CYAN, 44))


def draw_rung(d, r, kind, frozen):
    if frozen:
        if kind == "E":
            terrain_solid(d, r)
            return
        head_solid(d, r)
        # 冻结 = 这一格此刻是硬的：顶唇再压一道白，和流动态彻底拉开
        d.line([(r[0], r[1] - 1), (r[2], r[1] - 1)], fill=LIP, width=2)
        return
    if kind == "F":
        flow_ghost(d, r)
    elif kind == "G":
        flow_streak(d, r)
    elif kind == "H":
        flow_bloom(d, r)
    elif kind in ("A", "E"):                                # 薄壳：有轮廓没肉
        d.rectangle(r, fill=G.rgba(CYAN, 46))
        d.rectangle(r, outline=G.rgba(CYAN, 210))
        d.line([(r[0] + 4, r[1] + 4), (r[0] + 4, r[3] - 4)], fill=G.rgba(LIP, 120))
        d.line([(r[2] - 4, r[1] + 4), (r[2] - 4, r[3] - 4)], fill=G.rgba(LIP, 120))
    elif kind == "B":                                   # 扫描线：条纹 = 没被钉住
        for band in range(0, r[3] - r[1], 8):           # 8 设备 px = 2 晶格
            yy = r[1] + band
            d.rectangle([r[0] + 2, yy, r[2] - 2, yy + 3], fill=G.rgba(CYAN, 120))
        d.rectangle(r, outline=G.rgba(CYAN, 40))
    elif kind == "C":                                   # 导光带：珠子串在光束上
        d.rectangle(r, fill=G.rgba(CYAN, 74))
        d.rectangle(r, outline=G.rgba(CYAN, 150))
    else:                                               # D 拖影：实体感最低
        x = (r[0] + r[2]) // 2
        d.rectangle([x - 2, r[1] - 26, x + 2, r[3]], fill=G.rgba(CYAN, 150))
        d.rectangle(r, outline=G.rgba(CYAN, 56))


def draw_variant(base, sprites, kind, frozen):
    img = base.copy()
    d = ImageDraw.Draw(img, "RGBA")
    top = block_rect(N_RUNGS - 1)
    draw_source(d, top[1])

    if kind == "C" and not frozen:                      # 流动时整条链是一束连续的光
        x = (px(COL_X) + px(BLOCK_W) // 2)
        d.rectangle([x - 9, top[1] - 16, x + 9, block_rect(0)[3] + 6],
                    fill=G.rgba(CYAN, 30))
        d.rectangle([x - 2, top[1] - 16, x + 2, block_rect(0)[3] + 6],
                    fill=G.rgba(CYAN, 120))

    for i in range(N_RUNGS):
        draw_rung(d, block_rect(i), kind, frozen)

    r = block_rect(0)
    spr = sprites["frozen" if frozen else "flow"]
    bb = spr.getbbox()                                 # 立绘底部有透明留白，按可见像对齐才踩得住
    foot = r[1] if frozen else r[1] + (r[3] - r[1]) // 2   # 冻结站顶唇 / 流动已经沉进去半格
    img.paste(spr, ((r[0] + r[2]) // 2 - (bb[0] + bb[2]) // 2, foot - bb[3]), spr)
    return img


def _peak(img, r, ref):
    """一格内**最亮那个像素**对背景的对比度。条纹/拖影这类皮肤按单点取样会取到缝里，
    读出 1.0 好像"完全看不见"，那是取样假象；眼睛抓的是峰值，所以取 max。"""
    box = (r[0] + 2, r[1] + 2, r[2] - 2, r[3] - 2)
    return max(G._cr(p, ref) for p in img.crop(box).getdata())


def _coverage(img, r, ref, eps=12):
    """这一格里有多少像素真的**不是背景**。别拿"有没有 255 通道"当实心度，
    那数的是 CRT 的溢出高光，会把一块实心像皮读成 64/4096。"""
    return sum(1 for p in img.crop(r).getdata()
               if max(abs(p[0] - ref[0]), abs(p[1] - ref[1]), abs(p[2] - ref[2])) > eps)


DOOR_AT = (1000, 340)         # 青门门板（设备 x 964..1030）：离这列只有 30 世界 px，
                              # 青对青的合并风险就在这儿，必须当场量


def readouts(flow, froz):
    """可读性数字。冻结列已经过 CRT。

    这一版要看的不是"头一格 vs 尾迹"（那条区分不存在），是三件事：
      1) 冻结态够不够"实" —— 对背景墙、以及对紧挨着的那扇青门各量一次；
      2) 流动态是否**明显比墙好一点点、又远不如冻结态** —— 太低看不出有东西，
         太高就被读成"这是实的"；
      3) 冻结那一格是不是**真的实心**（solid 计数），别是描边糊出来的。
    最低那格不取样：流动态玩家正沉在它里面，立绘的白眼会冒充成峰值。
    """
    w_f, w_w = _wall(froz), _wall(flow)
    rc = block_rect(0)
    clean = block_rect(N_RUNGS - 1)
    body_xy = ((rc[0] + rc[2]) // 2, rc[1] + 6 + (rc[3] - rc[1]) // 2)
    area = (rc[2] - rc[0]) * (rc[3] - rc[1])
    return ("frozen peak/wall %.1f  flow peak/wall %.1f  body/wall %.1f  body/door %.1f"
            "  ink frozen %d%% / flow %d%%  wall %s->%s" % (
                _peak(froz, clean, w_f), _peak(flow, clean, w_w),
                G._cr(froz.getpixel(body_xy), w_f),
                G._cr(froz.getpixel(body_xy), froz.getpixel(DOOR_AT)),
                100 * _coverage(froz, rc, w_f) // area,
                100 * _coverage(flow, rc, w_w) // area, w_w, w_f))


def _wrap(d, text, font, max_w):
    """标签列只有 340 px：中文没有空格可断，只能逐字量宽折行。"""
    lines, cur, cur_w = [], "", 0.0
    for ch in text:
        w = d.textlength(ch, font=font)
        if cur and cur_w + w > max_w:
            lines.append(cur)
            cur, cur_w = ch, w
        else:
            cur, cur_w = cur + ch, cur_w + w
    if cur:
        lines.append(cur)
    return lines


def tile(img, src_w, src_h, fill_h=False):
    cell = Image.new("RGB", (CELL_W, CELL_H), (12, 12, 16))
    sc = (CELL_H / float(src_h)) if fill_h else min(CELL_W / float(src_w), CELL_H / float(src_h))
    w, h = int(src_w * sc), int(src_h * sc)
    mode = Image.NEAREST if sc > 2 else Image.BILINEAR
    cell.paste(img.resize((w, h), mode), ((CELL_W - w) // 2, (CELL_H - h) // 2))
    ImageDraw.Draw(cell).rectangle([0, 0, CELL_W - 1, CELL_H - 1], outline=(60, 66, 84))
    return cell


def crop_of(img):
    x, y = CROP_AT
    return img.crop((x, y, x + CROP[0], y + CROP[1]))


def main():
    base = Image.open(os.path.join(FRAMES, "spot2_raw.png")).convert("RGB")
    assert base.size == (W, H), base.size

    def _spr(name):
        s = Image.open(os.path.join(SLIME, name)).convert("RGBA")
        return s.resize((s.width * SCALE, s.height * SCALE), Image.NEAREST)

    sprites = {"frozen": _spr("idle_0.png"), "flow": _spr("fall_1.png")}

    font, small = G._font(15), G._font(12)
    names = (
        ("A  thin shell", "A", "D47 那版，已退役作对照：亮青描边 + 极淡填充。用户判"
                               "「没变实体时边框太明显」——一圈直线读成「没填色的砖」"),
        ("F  ghost + tail", "F", "★ 现在实装这版：描边全去掉，身体上暗下亮 + 往上溶的尾迹 +"
                                 " 踩面一道暗线。直线只剩一处，且它暗到读不出「这是实的」"),
        ("G  tail only", "G", "更狠：身体几乎不给，墨迹全押在尾迹上。最贴「残影」两个字，"
                              "代价是格的上下边界最含糊"),
        ("H  core bloom", "H", "中心一团辉光，四条边一条直线都不给。最像「没被钉住的光」，"
                               "也最难判断落脚点到底在不在它里面"),
    )

    head_h = 58
    row_h = CELL_H + 40
    sheet = Image.new("RGB", (LABEL_W + (CELL_W + GAP) * 4 + GAP,
                              head_h + row_h * (len(names) + 1) + 18), (16, 18, 24))
    d = ImageDraw.Draw(sheet)
    d.text((12, 8), "AFTERIMAGE STEP / flow skin v2 (D48)   base = real level_1 frame spot2_raw   "
                    "frozen column = same-formula CRT (linearFac 1.3 / scan 0.10 / chroma)   "
                    "block 32 world px, rung pitch 80 px (V 400 x T 0.20 s), 2 rungs",
           fill=LIP, font=G._font(17))
    xs = tuple(LABEL_W + (CELL_W + GAP) * i for i in range(4))
    for x, label in zip(xs, ("time flows (passable)", "FROZEN (whole chain steppable, thru CRT)",
                             "flows x2 (pitch read)", "frozen x2 (pitch read)")):
        d.text((x + 6, 36), label, fill=(124, 136, 176), font=small)

    ref = base.copy()
    d.line([(0, head_h - 4), (sheet.width, head_h - 4)], fill=(40, 46, 62))
    d.text((12, head_h + 6), "0  reference: nothing here today", fill=LIP, font=font)
    d.text((12, head_h + 26), "wall %s / 这列位置本来只有空墙" % (_wall(ref),),
           fill=(124, 136, 176), font=small)
    for x, cell in zip(xs, (tile(ref, W, H), tile(ref, W, H),
                            tile(crop_of(ref), CROP[0], CROP[1], True),
                            tile(crop_of(ref), CROP[0], CROP[1], True))):
        sheet.paste(cell, (x, head_h))

    for i, (label, kind, note) in enumerate(names):
        y0 = head_h + (i + 1) * row_h
        d.line([(0, y0 - 4), (sheet.width, y0 - 4)], fill=(40, 46, 62))
        flow = draw_variant(base, sprites, kind, frozen=False)
        froz_raw = draw_variant(base, sprites, kind, frozen=True)
        froz = crt(froz_raw, **SHIPPED)
        d.text((12, y0 + 6), label, fill=LIP, font=font)
        for j, ln in enumerate(_wrap(d, note, small, LABEL_W - 24)):
            d.text((12, y0 + 26 + j * 16), ln, fill=(124, 136, 176), font=small)
        sheet.paste(tile(flow, W, H), (xs[0], y0))
        sheet.paste(tile(froz, W, H), (xs[1], y0))
        sheet.paste(tile(crop_of(flow), CROP[0], CROP[1], True), (xs[2], y0))
        sheet.paste(tile(crop_of(froz), CROP[0], CROP[1], True), (xs[3], y0))
        txt = readouts(flow, froz)
        d.text((xs[0] + 6, y0 + CELL_H + 16), txt, fill=(150, 168, 210), font=small)
        print("%-20s %s" % (label, txt))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT)
    print("wrote %s  %dx%d" % (OUT, sheet.width, sheet.height))


if __name__ == "__main__":
    main()
