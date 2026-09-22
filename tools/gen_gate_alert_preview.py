"""刷卡门「拒绝提示」选型图（D53）：无钥匙靠近时那颗 2×2 灯换成什么色。

用法：py tools/gen_gate_alert_preview.py   ->  assets/props/preview_gate_alert.png

要量的不是"红好不好看"，是四条账：
  1. 红对**它自己那颗底座**（LED_SOCKET 8×8）读不读得见 —— 灯是坐在暗座里的，
     这一对才是"亮没亮"的判据（D26 那条 4.5 下限算的就是这类对底座的读数）。
  2. 红对**琥珀**分不分得开 —— 常态"锁着"就是琥珀，拒绝态是同一颗灯换色，
     所以状态切换的可读性 = cr(拒绝色, 琥珀色)。琥珀与红是**相邻色相**，这条最容易塌。
  3. 红对**它钉上去的那块门楣钢**读不读得见 —— 灯不是悬空的，画面上它永远贴着 ab 钢，
     对钢拉不开就没有一个可比的邻居（这一条按 D45 的教训只算"灯 vs 钢"，不指望 1 px 描边）。
  4. 上面三条在**透过 D46 那层 CRT 之后**还剩多少 —— 玩家看到它的那一刻必然按着
     方向键 = 世界必然冻着 = 必然套着这层滤镜，所以这一条才是真账，前三条裸帧读数只是留档。

底片不是画的：`assets/ui/frames/spot2_raw.png` 是 `tools/frame_grab.tscn` 抓的真帧，
里面那道刷卡门的 LED 恰好就在画面上（实测核心 4×4 = fabe4a、底座 8×8 = 151e25；
1280×720 设备像素，相机 zoom=2 ⇒ 世界 2×2 灯 = 设备 4×4）。
「对门楣」这一条的分母取灯左侧一块**实测**门楣钢（≈8e98a4 一档），不取 props 的落盘色
5e6c7d：真帧那一块比常量亮一档，拿常量算等于给自己放水。
候选色是把那块 4×4 核心**原地替换**进真帧，再整帧过一遍 `gen_freeze_filter_preview.crt()`
（同一条算式：linearFac 1.3 / scanLineFac 0.10 / 色散 0.001），然后把同一批设备像素量回来。
所以色散把一颗 4 px 的灯糊成什么样、扫描线把哪一行压暗，全都是实机那份形状。
"""

import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tiles as G                    # 复用 _cr / _font，别另写一份对比度算式
import gen_freeze_filter_preview as F    # 复用 crt()：D46 已验过它与实机 shader 对得上

FRAME = os.path.join(ROOT, "assets", "ui", "frames", "spot2_raw.png")
OUT = os.path.join(ROOT, "assets", "props", "preview_gate_alert.png")

# 真帧里那颗灯的实测位置（设备像素，闭区间）。跑之前会先把这几个坐标的颜色打出来。
CORE = (994, 236, 997, 239)
SOCKET = (992, 234, 999, 241)
CROP = (986, 228, 1002, 244)             # 16×16 设备像素，把门楣与底座都框进来
ZOOM = 8
CONTEXT = (930, 190, 1060, 270)          # 顶部那条方位参考带
CONTEXT_ZOOM = 3

AMBER = (250, 190, 74)                   # 常态「锁着」= props.json gate_led_locked
SOCKET_RGB = (21, 30, 37)                # LED_SOCKET
HEADER_RGB = (94, 108, 125)              # 门楣零件落盘色（5e6c7d），只作自检对照
## 灯左侧一块纯门楣钢（闭区间，避开底座与色散外溢的那 2 px）。对门楣这条判据用它，
## 不用 HEADER_RGB：真帧那一块实测比常量亮一档（≈8e98a4），拿常量算等于给自己放水。
STEEL = (970, 234, 986, 242)

LABEL_W = 396                            # 左侧说明列；说明按像素宽换行，列宽不够就被放大图压住

## 七行候选。第 3 个字段是**底座**要不要跟着换（None = 沿用真帧那份暗座）——
## 「整颗灯罩发红」那一行必须换，因为它赌的是面积而不是明度。
## E 行不是颜色，是「不新增色相」那条路线：核心画成底座色 = 灯灭，用「断电」而不是
## 「变红」表达拒绝。放进来是因为它是唯一不动 D29 色语言的做法。
ROWS = (
    ("A 现状·琥珀（基线）", AMBER, None, "锁着 = 与钥匙同色，这条是 D29/D36 的既有语义"),
    ("B 纯红", (255, 64, 58), None, "最直的「不通」；红是全项目第一处红像素"),
    ("C 深红", (222, 52, 52), None, "压暗一档，让它在 CRT 削顶之后仍然偏暗、不跟烫黄撞"),
    ("D 亮珊瑚", (255, 116, 96), None, "提亮偏橙；离琥珀最近，也最容易被琥珀吃掉"),
    ("E 熄灯（不是换色）", SOCKET_RGB, None, "零新色相：灯灭读作断电，代价是它不再是一个「亮着的提示」"),
    ("F 玫红", (255, 96, 160), None, "仍是红，但色相远离琥珀、亮度高一档（赌明度救得回来）"),
    ("G 整颗灯罩发红", (255, 86, 74), (66, 14, 18), "暗座也换成暗红 = 亮的面积从 16 px 涨到 64 px"),
)


def _patch(frame, core_rgb, socket_rgb=None):
    """把 LED 核心原地换成候选色（可选连底座一起换），其余像素一个不动。"""
    im = frame.copy()
    d = ImageDraw.Draw(im)
    if socket_rgb is not None:
        d.rectangle(SOCKET, fill=socket_rgb)
    d.rectangle(CORE, fill=core_rgb)
    return im


def _mean(im, box):
    x0, y0, x1, y1 = box
    px = im.load()
    n = 0
    acc = [0, 0, 0]
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            c = px[x, y]
            acc[0] += c[0]
            acc[1] += c[1]
            acc[2] += c[2]
            n += 1
    return tuple(round(v / n) for v in acc)


def _clip_count(im, box):
    """box 内至少一个通道被推到 255 的像素数（D46 那条「削顶」的计数口径）。"""
    x0, y0, x1, y1 = box
    px = im.load()
    return sum(1 for y in range(y0, y1 + 1) for x in range(x0, x1 + 1) if 255 in px[x, y][:3])


def _zoom(im, box, z):
    """box 是闭区间（含右下角），crop 要右开式，这里统一转一次。"""
    w = (box[2] - box[0] + 1) * z
    h = (box[3] - box[1] + 1) * z
    return im.crop((box[0], box[1], box[2] + 1, box[3] + 1)).resize((w, h), Image.NEAREST)


def _ring_mean(im, box):
    """底座那一圈 = 8×8 减去 4×4 核心，16 个像素。灯坐在它里面，它才是「亮没亮」的另一半。"""
    x0, y0, x1, y1 = box
    cx0, cy0, cx1, cy1 = CORE
    px = im.load()
    acc = [0, 0, 0]
    n = 0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if cx0 <= x <= cx1 and cy0 <= y <= cy1:
                continue
            c = px[x, y]
            acc[0] += c[0]
            acc[1] += c[1]
            acc[2] += c[2]
            n += 1
    return tuple(round(v / n) for v in acc)


def _wrap(d, text, font, max_w, lines=2):
    """按像素宽切行（CJK 没有空格可断，只能按宽度累加）。超出 lines 行就把末行截断加省略号。"""
    out, cur = [], ""
    for ch in text:
        if d.textlength(cur + ch, font=font) <= max_w:
            cur += ch
            continue
        out.append(cur)
        cur = ch
    if cur:
        out.append(cur)
    if len(out) > lines:
        out = out[:lines]
        trimmed = ""
        for ch in out[lines - 1]:
            if d.textlength(trimmed + ch + "…", font=font) > max_w:
                break
            trimmed += ch
        out[lines - 1] = trimmed + "…"
    return out


def main():
    raw = Image.open(FRAME).convert("RGB")
    assert raw.size == (F.W, F.H), "底片尺寸与 crt() 假设的 1280×720 不符：%s" % (raw.size,)
    probe = raw.load()
    print("探针自检（不该是这些值就说明坐标落歪了）")
    print("  核心 %s = %s   期望 fabe4a" % (CORE, probe[CORE[0], CORE[1]]))
    print("  底座 %s = %s   期望 151e25" % (SOCKET, probe[SOCKET[0], SOCKET[1]]))
    print("  门楣 (%d,%d) = %s" % (CROP[0] + 1, CROP[1] + 1, probe[CROP[0] + 1, CROP[1] + 1]))

    # 基线那一行过一遍滤镜：拒绝态要跟「滤镜后的琥珀」比，不是跟裸色比。
    amber_filtered = F.crt(_patch(raw, AMBER), 1.3, 0.10, 0.25, 0.0, 0.001)
    amber_core_f = _mean(amber_filtered, CORE)
    print("  CRT 后琥珀核心均值 = %s（D46 记的是 (255,235,91) 那一档烫黄）" % (amber_core_f,))
    # 灯左侧那块钢离 LED 有色散外溢的安全距离，换任何候选色都不动它，所以只量一次。
    steel_raw = _mean(raw, STEEL)
    steel_f = _mean(amber_filtered, STEEL)
    print("  门楣钢 %s 裸 %s -> CRT后 %s（对门楣的分母，对照常量 %s）"
          % (STEEL, steel_raw, steel_f, HEADER_RGB))

    small = _font(12)
    big = _font(19)

    cell = (CROP[2] - CROP[0] + 1) * ZOOM
    pad = 10
    head_h = (CONTEXT[3] - CONTEXT[1] + 1) * CONTEXT_ZOOM + 92
    row_h = cell + 2 * pad + 44
    W = LABEL_W + cell * 2 + 460 + pad * 4
    H = head_h + len(ROWS) * row_h + pad
    out = Image.new("RGB", (W, H), (12, 15, 23))
    d = ImageDraw.Draw(out)

    # 顶部方位带：同一块真帧，左裸右滤镜，红框标出下面逐行放大的就是那颗灯。
    cw = (CONTEXT[2] - CONTEXT[0] + 1) * CONTEXT_ZOOM
    ch = (CONTEXT[3] - CONTEXT[1] + 1) * CONTEXT_ZOOM
    ctx_raw = _zoom(raw, CONTEXT, CONTEXT_ZOOM)
    ctx_crt = _zoom(F.crt(_patch(raw, AMBER), 1.3, 0.10, 0.25, 0.0, 0.001), CONTEXT, CONTEXT_ZOOM)
    out.paste(ctx_raw, (pad, 40))
    out.paste(ctx_crt, (pad + cw + 16, 40))
    for i in range(2):
        x0 = pad + i * (cw + 16) + (CROP[0] - CONTEXT[0]) * CONTEXT_ZOOM
        y0 = 40 + (CROP[1] - CONTEXT[1]) * CONTEXT_ZOOM
        d.rectangle([x0 - 1, y0 - 1,
                     x0 + (CROP[2] - CROP[0] + 1) * CONTEXT_ZOOM,
                     y0 + (CROP[3] - CROP[1] + 1) * CONTEXT_ZOOM], outline=(255, 64, 58), width=2)
    d.text((pad, 12), "方位参考：spot2 真帧里那道刷卡门（左 = 裸帧，右 = 套 CRT），红框=下面放大的那一格",
           fill=(214, 224, 240), font=small)

    y = head_h
    for name, rgb, socket_rgb, note in ROWS:
        patched = _patch(raw, rgb, socket_rgb)
        filtered = F.crt(patched, 1.3, 0.10, 0.25, 0.0, 0.001)
        # 裸帧读数
        ring = _ring_mean(filtered, SOCKET)
        core_raw = _mean(patched, CORE)
        core_f = _mean(filtered, CORE)
        cr_socket = G._cr(core_f, ring)
        cr_amber = G._cr(core_f, amber_core_f)
        cr_header = G._cr(core_f, steel_f)
        clip = _clip_count(filtered, CORE)
        d.text((pad, y + 2), name, fill=(228, 236, 248), font=big)
        for i, t in enumerate(_wrap(d, note, small, LABEL_W - pad - 40)):
            d.text((pad, y + 30 + i * 16), t, fill=(150, 164, 186), font=small)
        out.paste(_zoom(patched, CROP, ZOOM), (LABEL_W, y + pad))
        out.paste(_zoom(filtered, CROP, ZOOM), (LABEL_W + cell + pad, y + pad))
        x = LABEL_W + cell * 2 + pad * 3
        ring_label = "对底座（暗座）" if socket_rgb is None else "对底座（已换暗红）"
        lines = (
            "裸帧核心 %s" % (core_raw,),
            "CRT 后核心 %s   削顶 %d/16 px" % (core_f, clip),
            "%s %s  %s" % (ring_label, ring, "cr=%.2f" % cr_socket),
            "对门楣（实测） %s  cr=%.2f" % (steel_f, cr_header),
            "对 CRT 后琥珀 %s  cr=%.2f" % (amber_core_f, cr_amber),
            "D26 下限 4.5；状态切换这条 < 3 就是「换了等于没换」",
        )
        for i, t in enumerate(lines):
            d.text((x, y + pad + 4 + i * 19), t,
                   fill=(190, 205, 226) if i < 5 else (250, 190, 74), font=small)
        d.text((LABEL_W, y + pad + cell + 2), "裸帧（留档）", fill=(150, 164, 186), font=small)
        d.text((LABEL_W + cell + pad, y + pad + cell + 2), "套 CRT（真账）", fill=(150, 164, 186), font=small)
        print("%-22s 裸%s -> CRT后%s | 对底座%s %.2f  对琥珀 %.2f  对门楣 %.2f  削顶 %d/16"
              % (name, core_raw, core_f, ring, cr_socket, cr_amber, cr_header, clip))
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
