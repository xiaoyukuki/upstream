"""冻结滤镜选型图（D46，已裁定：A 取代灰）。

用法：py tools/gen_freeze_filter_preview.py   ->  assets/ui/preview_freeze_filter.png

底片不是画的，是 `tools/frame_grab.tscn` 跑真关卡抓的真帧（assets/ui/frames/）：
屏幕空间的滤镜只有套在真帧上才看得出它吃了谁。spot2 那一帧地标最密（青门 / 琥珀钥匙 /
白钢尖刺 / 钢柜 / 夜光墙），spot0 那一帧有主角本体。
A~E 五格走的都是用户给的那段 fragment 的同一条算式（离线复现），逐行对应关系：

    fy = fract(UV * 180).y            ->  _scanline_overlay()，按行算晶格
    if fy < w or fy > 1-w: scan = fac ->  暗带 = 黑底 alpha = scanLineFac
    COLOR.r = linear(UV - off)        ->  _shift()，分数像素平移 = 双线性重采样
    COLOR.g = linear(UV)                    off 是 UV 单位，换成像素要乘屏宽
    COLOR.b = linear(UV + off)
    COLOR = mix(COLOR * linearFac, 黑, scan) ->  先按通道乘，再 alpha_composite 一层黑
    COLOR += nearest(UV) * nearestFac        ->  ImageChops.add（本图里 nearestFac 恒 0）

三条必须说清的近似，图上数字与实机的差别就出在这些地方：
  1. 全程在 8 位 sRGB 整数值上算，跟 Compatibility 渲染器把屏幕纹理原样交给 shader
     那条一致（uniform 没写 source_color）。真接上 shader 后若整体偏暗，差的是这一条。
  2. `texture(viewportLinear, UV)` 在 1:1 屏幕纹理上取的就是像素中心，等于没糊 ——
     所以「linear / nearest 双通道」真正起作用的只有那对色散抽头：linear 给软边、
     nearest 给硬边。想看到整幅糊成 CRT 必须降内部分辨率，那是 E 行。
  3. E 行用「BOX 下采样到 320×180 再线性放大」近似一场真的低分辨率渲染。贴图场景下
     这条近似是准的（2D 本来就是一张纹理），代价在别处：真做要一道 SubViewport，
     而 D8 定的路线是无旁路的 hint_screen_texture。

裁定之后加的 F 行不是算式，是把 A 那组参数真编进 GL、由 `frame_grab.tscn` 抓回来的实拍。
所以 A 与 F 两格并排 = 上面那三条近似到底成不成立的当场检验；两行的差值（逐通道平均、
最大、以及差 >=3 的样本数）连同同一批探针的 RGB 打在 stdout 里，图上不写。

色数一栏是硬的：D26 那张 WCAG 表是这游戏的可读性底座，D29 的分工又靠青与琥珀分
「光与电」和「可拾取物」。所以每行都量同一批探针，提亮把谁削平了直接写在图上，
并把取到的 RGB 打到 stdout —— 探针落歪了当场能看出来。
主角的位置不写死坐标：在底片里找近黑像素质心（身体是这帧里唯一一片近黑），
探针与放大框都跟着它走。
"""

import os
import sys

from PIL import Image, ImageDraw, ImageChops

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G          # 复用 _cr / _rlum / _font，别另写一份对比度算式

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = os.path.join(ROOT, "assets", "ui", "frames")
OUT = os.path.join(ROOT, "assets", "ui", "preview_freeze_filter.png")

W, H = 1280, 720               # 抓帧就是窗口尺寸，晶格按这一张算
VRES = 180.0                   # shader 里 const RESOLUTION 的纵向格数
CELL_W = 640
CELL_H = 360
CROP = 128, 72                 # 放大区取样框，×5 整数放大不引入重采样伪影
CROP_DOOR = (940, 240)         # spot2：青门 + 门上琥珀指示灯 + 钢框 + 夜光墙
GAP = 8
LABEL_W = 300

# 探针落在 spot2 那一帧，位置用 1280×720 设备像素写死，取到的颜色每次运行都打出来。
PROBES = (
    ("cyan door", (1000, 320)),
    ("amber key", (625, 225)),
    ("white steel", (620, 386)),
    ("night wall", (300, 300)),
)
WALL = "night wall"
## spot0 那一帧的墙，离主角远到不会被他挡住（实测 (60,68,98) = g 的 bg2）。
## 两帧的墙差一档，所以主角那一对不能借 spot2 的 WALL。
WALL0 = (300, 300)


def _shift(img, dx):
    """texture(UV + dx/W)：分数像素平移，双线性 = shader 里那个 linear 采样。

    PIL 的 `resize(box=)` 不许负偏移，所以先把首末列复制出去再走 AFFINE ——
    这一圈不是为了好看，是为了对上 GL 里 `repeat_disable` 的边缘钳位：
    直接留黑会在屏幕左右沿各糊出一条黑边，而实机不会。
    """
    p = int(abs(dx)) + 2
    pad = Image.new("RGB", (W + 2 * p, H), (0, 0, 0))
    pad.paste(img, (p, 0))
    pad.paste(img.crop((0, 0, 1, H)).resize((p, H), Image.NEAREST), (0, 0))
    pad.paste(img.crop((W - 1, 0, W, H)).resize((p, H), Image.NEAREST), (p + W, 0))
    return pad.transform((W, H), Image.AFFINE, (1, 0, p + dx, 0, 1, 0),
                         resample=Image.BILINEAR)


def _scanline_overlay(fac, width):
    """fract(UV*180).y 落在 [0,width) 或 (1-width,1] 的行，盖一层黑 alpha=fac。"""
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    a = int(round(fac * 255))
    for y in range(H):
        fy = ((y + 0.5) / H * VRES) % 1.0
        if fy < width or fy > 1.0 - width:
            d.line([(0, y), (W, y)], fill=(0, 0, 0, a))
    return ov


def _mul(img, f):
    """COLOR * linearFac：逐通道乘并夹回 255（削平就发生在这里，clip 计数盯它）。"""
    return Image.merge(img.mode,
                       [b.point(lambda v: min(255, int(v * f + 0.5))) for b in img.split()])


def crt(raw, linear_fac=1.0, scan_fac=0.10, scan_width=0.25,
        nearest_fac=0.0, aberration=0.001, internal=None):
    """用户那段 fragment 的离线复现。输入输出都是 1280×720 的 RGB。"""
    src = raw
    if internal is not None:
        src = raw.resize(internal, Image.BOX).resize((W, H), Image.BILINEAR)
    s = aberration * W
    r = _shift(src, -s).getchannel("R")
    g = src.getchannel("G")
    b = _shift(src, s).getchannel("B")
    out = Image.merge("RGB", (r, g, b))
    if linear_fac != 1.0:
        out = _mul(out, linear_fac)
    if scan_fac > 0.0:
        out = Image.alpha_composite(out.convert("RGBA"),
                                    _scanline_overlay(scan_fac, scan_width)).convert("RGB")
    if nearest_fac > 0.0:
        out = ImageChops.add(out, _mul(raw, nearest_fac))
    return out


def diff_stats(a, b):
    """离线算式 vs 实机抓帧的差：逐通道平均、最大、以及差 >=3 的通道样本数。

    走直方图不逐像素循环，一张 1280x720 也是瞬时。>=3 这个门槛是把 8 位
    舍入与 GL 的 float 中间量那点抖动算作「一样」，超出才是真的对不上 ——
    晶格相位错一行会直接把这个数顶到全图三分之一，藏不住。
    """
    d = ImageChops.difference(a, b)
    h = d.histogram()
    n = a.width * a.height
    means = []
    big = 0
    for ch in range(3):
        bins = h[ch * 256:(ch + 1) * 256]
        means.append(sum(v * bins[v] for v in range(256)) / float(n))
        big += sum(bins[3:])
    return means, max(v[1] for v in d.getextrema()), big


def probe(img, at):
    """4×4 平均：晶格一周期正好 4 行，取平均才不偏袒某一行。"""
    x, y = at
    px = img.load()
    acc = [0, 0, 0]
    for dy in range(4):
        for dx in range(4):
            p = px[min(x + dx, W - 1), min(y + dy, H - 1)]
            acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]
    return tuple(v / 16.0 for v in acc)


def find_player(img):
    """近中性黑像素质心 = 主角。只按「够暗」筛不够：背景显示器那团深蓝 (11,14,24)
    面积比主角还大，会把质心拽到右上角。主角身体是中性黑，蓝不高于红。"""
    px = img.load()
    sx = sy = n = 0
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            p = px[x, y]
            if p[0] < 24 and p[1] < 24 and p[2] < 30 and p[2] <= p[0] + 6:
                sx += x; sy += y; n += 1
    if n == 0:
        raise RuntimeError("底片里找不到近中性黑像素，主角没在画面内")
    return sx // n, sy // n


def extremes(img, at, half=14):
    """主角框内取最亮（白边/眼）与最暗（身体）：轮廓对墙要的就是这两个极值。"""
    x, y = at
    px = img.load()
    lo, hi = None, None
    for dy in range(-half, half + 1):
        for dx in range(-half, half + 1):
            p = px[max(0, min(x + dx, W - 1)), max(0, min(y + dy, H - 1))]
            if lo is None or G._rlum(p) < G._rlum(lo):
                lo = p
            if hi is None or G._rlum(p) > G._rlum(hi):
                hi = p
    return hi, lo


def readouts(spot2, player_img, player_at, base_clips):
    """一行候选的客观账：三对语义色对 spot2 的墙，主角轮廓对 spot0 自己的墙。
    主角那一对不能拿他周围一圈当墙 —— 2× 缩放下他有 100×80 设备像素，
    任何贴身的环都还穿在身上。写死一个离他足够远的墙点。"""
    vals = {name: probe(spot2, at) for name, at in PROBES}
    wall = vals[WALL]
    wall0 = probe(player_img, WALL0)
    rim, body = extremes(player_img, player_at)
    parts = ["cyan/wall %.2f" % G._cr(vals["cyan door"], wall),
             "amber/wall %.2f" % G._cr(vals["amber key"], wall),
             "steel/wall %.2f" % G._cr(vals["white steel"], wall),
             "rim/wall %.2f" % G._cr(rim, wall0),
             "body/wall %.2f" % G._cr(body, wall0)]
    parts.append("full-channel px %+d"
                 % (sum(1 for p in spot2.getdata() if 255 in p) - base_clips))
    return "  ".join(parts)


def tile(img, src_w, src_h):
    """等比塞进 CELL 格；放大区用 NEAREST，别拿平滑把晶格糊掉。"""
    cell = Image.new("RGB", (CELL_W, CELL_H), (12, 12, 16))
    sc = min(CELL_W / src_w, CELL_H / src_h)
    w, h = int(src_w * sc), int(src_h * sc)
    mode = Image.NEAREST if sc > 2 else Image.BILINEAR
    cell.paste(img.resize((w, h), mode), ((CELL_W - w) // 2, (CELL_H - h) // 2))
    ImageDraw.Draw(cell).rectangle([0, 0, CELL_W - 1, CELL_H - 1], outline=(60, 66, 84))
    return cell


def crop_of(img, at):
    x, y = at
    return img.crop((x, y, x + CROP[0], y + CROP[1]))


CANDIDATES = (
    ("A  your shader, as-is", dict(linear_fac=1.3, scan_fac=0.10),
     "linearFac 1.3 / scan 0.10 / chroma on"),
    ("B  no brightness boost", dict(linear_fac=1.0, scan_fac=0.10),
     "same lattice, only the RGB taps"),
    ("C  readable scanlines", dict(linear_fac=1.0, scan_fac=0.45),
     "scanLineFac 0.10 -> 0.45"),
    ("D  scanlines, no chroma", dict(linear_fac=1.0, scan_fac=0.45, aberration=0.0),
     "isolate what the RGB split costs"),
    ("E  internal 320x180", dict(linear_fac=1.0, scan_fac=0.30, internal=(320, 180)),
     "needs one SubViewport (D8 route has none)"),
)


def main():
    base = Image.open(os.path.join(FRAMES, "spot2_raw.png")).convert("RGB")
    player = Image.open(os.path.join(FRAMES, "spot0_raw.png")).convert("RGB")
    gray2 = Image.open(os.path.join(FRAMES, "spot2_gray.png")).convert("RGB")
    gray0 = Image.open(os.path.join(FRAMES, "spot0_gray.png")).convert("RGB")
    real2 = Image.open(os.path.join(FRAMES, "spot2_filter.png")).convert("RGB")
    real0 = Image.open(os.path.join(FRAMES, "spot0_filter.png")).convert("RGB")

    at = find_player(player)
    crop_player = (at[0] - CROP[0] // 2, at[1] - CROP[1] // 2)
    print("player centroid %s -> crop %s" % (at, crop_player))
    for name, xy in PROBES:
        print("  probe %-12s %-12s %s" % (name, xy, base.getpixel(xy)))
    print("  probe %-12s %-12s %s" % ("player wall", WALL0, player.getpixel(WALL0)))

    print("\n-- 算式(A) vs 实机（同一批真帧、同一条算式，差多少）--")
    for tag, raw, real in (("spot2", base, real2), ("spot0", player, real0)):
        calc = crt(raw, **CANDIDATES[0][1])
        means, worst, big = diff_stats(calc, real)
        print("  %s  mean=%s worst=%d  |d|>=3: %d / %d" % (
            tag, ["%.2f" % m for m in means], worst, big, raw.width * raw.height * 3))
        for name, xy in PROBES:
            print("     %-12s calc %-22s real %s" % (name, probe(calc, xy), probe(real, xy)))

    rows = [("source (not frozen)", None, "filter layer off", base, player, at),
            ("today: gray overlay", "shot", "0.5 grey x alpha 0.20, real capture",
             gray2, gray0, at)]
    for name, kw, note in CANDIDATES:
        rows.append((name, kw, note, None, None, at))
    rows.append(("F  IN GAME (real shader)", "shot",
                 "A's params compiled by GL, real capture", real2, real0, at))

    font, small = G._font(15), G._font(12)
    head_h = 56
    row_h = CELL_H + 34
    xs = (LABEL_W, LABEL_W + CELL_W + GAP, LABEL_W + (CELL_W + GAP) * 2)
    sheet = Image.new("RGB", (LABEL_W + (CELL_W + GAP) * 3 + GAP, head_h + row_h * len(rows) + 16),
                      (16, 18, 24))
    d = ImageDraw.Draw(sheet)
    d.text((12, 8), "FREEZE FILTER (D46: A chosen, replaces grey)   base = real level_1 frames "
                    "1280x720   lattice 180 rows = 4 device px per cell   F = in-game",
           fill=(206, 222, 250), font=G._font(17))
    for x, label in zip(xs, ("spot2 full (cyan door at right)",
                             "spot2 zoom x5: door / amber LED / steel",
                             "spot0 zoom x5: player vs wall")):
        d.text((x + 6, 34), label, fill=(124, 136, 176), font=small)

    base_clips = sum(1 for p in base.getdata() if 255 in p)
    for i, (name, kw, note, bimg, pimg, pat) in enumerate(rows):
        y0 = head_h + i * row_h
        d.line([(0, y0 - 4), (sheet.width, y0 - 4)], fill=(40, 46, 62))
        if isinstance(kw, str) or kw is None:
            out, pout = bimg, pimg
        else:
            out = crt(base, **kw)
            pout = crt(player, **kw)
        d.text((12, y0 + 6), name, fill=(206, 222, 250), font=font)
        d.text((12, y0 + 26), note, fill=(124, 136, 176), font=small)
        d.text((xs[0] + 6, y0 + CELL_H + 14), readouts(out, pout, pat, base_clips),
               fill=(150, 168, 210), font=small)
        sheet.paste(tile(out, W, H), (xs[0], y0))
        sheet.paste(tile(crop_of(out, CROP_DOOR), CROP[0], CROP[1]), (xs[1], y0))
        sheet.paste(tile(crop_of(pout, crop_player), CROP[0], CROP[1]), (xs[2], y0))

    sheet.save(OUT)
    print("emitted %s (%dx%d)" % (OUT, sheet.width, sheet.height))


if __name__ == "__main__":
    main()
