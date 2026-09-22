"""活塞踏板（D49 选型图）：按钮踩下时从洞口里伸出来当落脚点、松开快速抽回去的一块方块。

构件的**行为**已经钉死（一组接同一个按钮 / 伸出慢收回快 / 冻结停在当前伸出量 / 行程上有人就
挤开他）。这一张图只回答一件事：**这块从地里伸出来的东西，用什么话说"踩我"。**

要看的四个状态是同一格的四个瞬间，不是四种皮肤：
  收回    只有洞口 —— 玩家必须看得出"这儿有个洞，会有东西出来"
  伸出中  半路（32 px）+ 运动线索
  钉住    同样半路，整帧过 D46 那套 CRT —— 冻结里它是什么样子
  满行程  64 px（两格）到位，旁边站个人给比例

于是真正要选的轴是**皮肤家族**，三档：
  A 钢鞘滑块  机械话：钢色身体 + 亮白前缘 + 螺栓孔的洞口鞘。和地皮、和那扇青门都拉开距离
  B 青光踏板  光的家族（accent 青）：和前缘亮唇 = 跟残影踏板的冻结格、跟那扇青门同一套话
              —— 好处是"能踩"这层意思已经教会了，代价是屏幕上一共三个青的东西
  C 地皮同款  最便宜也最直白：身体就是瓦片那块地皮（点阵 + 缝），只在顶面给一道亮唇。
              读起来是"多出来一截地面"，代价是身体对背景墙的对比度天然低

算式与口径：
  底图 = assets/ui/frames/spot2_raw.png（真关卡帧，无玩家，1280x720）
  比例尺 = assets/player/slime 真帧 x2（世界像素 -> 设备像素）
  钉住列整帧过 gen_freeze_filter_preview.crt()，参数 = D46 裁定那一组
  对比度用 gen_tiles._cr，与瓦片/立绘守门同一条算式；墨量（ink）与**未改动的底图**逐像素比，
  因为取样框会跨背景墙与地皮两种底色，拿单点当参照会读出假数

局限：钉住列是**离线同算式**。皮肤真要上线得走 tools/gen_props.py 出 PNG + 实机
tools/frame_grab.tscn 实拍一次，别拿这张图当实机验收。洞口线（设备 y=390）是底图实测来的，
图上那一圈"鞘"是画在真地皮上的，不是把地皮擦掉重画 —— 摆图时洞口落在整格线上，不会有这层缝。
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
OUT = os.path.join(ROOT, "assets", "props", "preview_piston.png")

W, H = 1280, 720
PAL = G.STYLES["g"]
CYAN = PAL["accent"]          # (110,230,240) 光与电
LIP = PAL["lip"]              # (206,222,250) 亮白
SURFACE = PAL["surface"]      # (104,120,164) 地皮
LIP_SHADE = PAL["lip_shade"]  # (150,168,210) 地皮点阵
GROUT = PAL["grout"]          # (80,94,134)  地皮缝
METAL = PAL["metal"]          # (124,136,176) 构件钢
EDGE = PAL["edge"]            # (22,26,42)  描边/洞底

SHIPPED = dict(linear_fac=1.3, scan_fac=0.10, scan_width=0.25, aberration=0.001)

# 世界像素 -> 设备像素 x2。洞口线取底图实测：设备 y=390（那两行是地皮亮唇）。
SCALE = 2
GROUND = 195
X0 = 380                      # 洞口左边缘：设备 760..888，离那扇青门（964 起）留 38 设备 px
BLK = 64                      # 方块边长 = 两格，站得下一个人
MID = 32                      # 伸出中/钉住两列的伸出量


def px(v):
    return v * SCALE


CELL_W, CELL_H = 640, 360
LABEL_W = 340
GAP = 8
CROP_AT = (px(X0 + BLK // 2) - CELL_W // 2, 146)   # 满行程顶（262）与地线（390）都装在里面
CROP = (CELL_W, CELL_H)                             # 1:1，不重采样，看得清晶格

DOOR_AT = (1000, 340)         # 青门门板：离这列 38 设备 px，青对青的合并风险就在这儿


def block_rect(e):
    """伸出量 e（世界像素）时**露出地面那一截**的设备矩形。埋在洞里的部分不画：
    底图的地皮已经在那儿，画上去等于把地皮擦穿，量出来的墨量也就不是皮肤的墨量。"""
    return [px(X0), px(GROUND) - px(e), px(X0 + BLK), px(GROUND)]


def _band(e):
    """取样框：露出那一截往里收一点，别把左右描边和地线那一行算进身体。"""
    r = block_rect(e)
    return (r[0] + 6, r[1] + 2, r[2] - 6, r[3] - 6)


def _peak(img, box, ref):
    """框内**最亮那个像素**对背景墙的对比度。眼睛抓的是峰值，取 max。"""
    return max(G._cr(p, ref) for p in img.crop(box).getdata())


def _ink(img, ref_img, box, eps=12):
    """这一格里有多少像素真的**不是底图原本的样子**。跟未改动的底图逐像素比，
    不跟某个参照色比：取样框会跨背景墙与地皮。"""
    a = img.crop(box).getdata()
    b = ref_img.crop(box).getdata()
    n = sum(1 for p, q in zip(a, b)
            if max(abs(p[0] - q[0]), abs(p[1] - q[1]), abs(p[2] - q[2])) > eps)
    return 100 * n // ((box[2] - box[0]) * (box[3] - box[1]))


def socket_mouth(d, w):
    """洞口本身：一条黑缝 + 地线两侧各一行暗。三档共用，差别在各自的鞘。"""
    x0, x1, y = px(X0) - 4, px(X0 + BLK) + 4, px(GROUND)
    d.rectangle([x0, y - 3, x1, y + 3], fill=EDGE)
    for xx in range(x0 + 6, x1 - 4, 12):
        d.point((xx, y), fill=G.rgba(LIP, 70))
    d.line([(x0, y + 5), (x1, y + 5)], fill=G.rgba(EDGE, 150))
    if w:
        d.rectangle([x0, y - 3, x1, y + 3], outline=G.rgba(LIP, 40))


def skin_steel(d, r):
    """A 钢鞘滑块：钢色身体 + 斜切亮边 + 前缘一道亮白 + 侧面铆钉。洞口配一圈钢鞘。"""
    d.rectangle(r, fill=METAL)
    d.rectangle(r, outline=G.darker(METAL, 0.55))
    for i in range(4):                                   # 左上斜切，给体积
        d.line([(r[0] + 2 + i, r[1] + 2), (r[0] + 2, r[1] + 2 + i)],
               fill=G.lighter(METAL, 0.25))
    for yy in range(r[1] + 14, r[3] - 8, 18):            # 侧面横纹：读得出是一截一截抽出来
        d.line([(r[0] + 8, yy), (r[2] - 8, yy)], fill=G.darker(METAL, 0.35))
    for yy in (r[1] + 24, r[3] - 20):                   # 铆钉
        for xx in (r[0] + 14, r[2] - 14):
            d.rectangle([xx - 3, yy - 3, xx + 3, yy + 3], fill=G.darker(METAL, 0.5))
            d.point((xx - 1, yy - 1), fill=G.lighter(METAL, 0.4))
    d.line([(r[0] - 2, r[1]), (r[2] + 2, r[1])], fill=LIP, width=3)   # 前缘 = 踩面


def skin_steel_socket(d):
    x0, x1, y = px(X0) - 10, px(X0 + BLK) + 10, px(GROUND)
    d.rectangle([x0, y - 10, x1, y - 3], fill=G.darker(METAL, 0.45))
    d.line([(x0, y - 10), (x1, y - 10)], fill=G.lighter(METAL, 0.2), width=1)
    for xx in (x0 + 8, x1 - 8):
        d.rectangle([xx - 3, y - 9, xx + 3, y - 4], fill=EDGE)


def skin_cyan(d, r):
    """B 青光踏板：暗身 + 青色内光 + 顶面实心青（和残影踏板的冻结格、那扇青门同一套话）。"""
    d.rectangle(r, fill=PAL["screen"])
    d.rectangle(r, outline=G.darker(CYAN, 0.5))
    for i in range(3):                                   # 从顶面往下退的青色渐暗
        d.line([(r[0] + 3, r[1] + 8 + i * 5), (r[2] - 3, r[1] + 8 + i * 5)],
               fill=G.rgba(CYAN, 150 - i * 60))
    d.rectangle([r[0] + 10, r[1] + 26, r[2] - 10, r[3] - 8], fill=G.rgba(CYAN, 34))
    d.line([(r[0], r[1] + 2), (r[2], r[1] + 2)], fill=CYAN, width=3)
    d.line([(r[0], r[1]), (r[2], r[1])], fill=LIP, width=2)


def skin_cyan_socket(d):
    x0, x1, y = px(X0) - 8, px(X0 + BLK) + 8, px(GROUND)
    d.rectangle([x0, y - 8, x1, y - 3], fill=G.darker(CYAN, 0.62))
    d.line([(x0 + 4, y - 8), (x1 - 4, y - 8)], fill=G.rgba(CYAN, 160))


def skin_terrain(d, r):
    """C 地皮同款：身体 = 瓦片那块地皮（点阵 + 缝），只在顶面给一道地唇。"""
    d.rectangle(r, fill=SURFACE)
    for yy in range(r[1] + 8, r[3] - 4, 12):             # gummy 点阵，和地面同一密度
        for xx in range(r[0] + 6, r[2] - 4, 12):
            d.point((xx, yy), fill=LIP_SHADE)
    d.line([(r[0], r[3] - 1), (r[2], r[3] - 1)], fill=GROUT)      # 底缝：它是**多出来的一格**
    d.line([(r[0], r[1]), (r[2], r[1])], fill=LIP, width=2)       # 地皮亮唇 = 踩面


def skin_terrain_socket(d):
    x0, x1, y = px(X0) - 2, px(X0 + BLK) + 2, px(GROUND)
    d.line([(x0, y - 4), (x1, y - 4)], fill=G.rgba(GROUT, 200))
    d.line([(x0, y + 8), (x1, y + 8)], fill=G.rgba(GROUT, 160))


def seam_ticks(d, r, col):
    """伸出中的运动线索：洞口那条缝上两枚短竖线。身子下面没有"露出的洞"可画
    （方块底边正好落在地线上），所以线索只能压在缝上 —— 也顺便指出它从哪儿出来。"""
    y0, y1 = px(GROUND) - 7, px(GROUND) + 7
    for xx in (r[0] + 22, r[2] - 22):
        d.line([(xx, y0), (xx, y1)], fill=col, width=2)


SKINS = {
    "A": (skin_steel, skin_steel_socket, G.rgba(LIP, 120)),
    "B": (skin_cyan, skin_cyan_socket, G.rgba(CYAN, 150)),
    "C": (skin_terrain, skin_terrain_socket, G.rgba(LIP_SHADE, 120)),
}


def draw_variant(base, sprite, kind, e, frozen, with_hero):
    img = base.copy()
    d = ImageDraw.Draw(img, "RGBA")
    body, sock, cue = SKINS[kind]
    if e > 0:
        body(d, block_rect(e))
    sock(d)
    socket_mouth(d, frozen)
    # 运动线索只在"伸出中且世界在流"那一列：收回中该说的是脚下那道口正在空掉，不是方向。
    if 0 < e < BLK and not frozen:
        seam_ticks(d, block_rect(e), cue)
    if with_hero:
        r = block_rect(e)
        bb = sprite.getbbox()                             # 立绘底部有透明留白，按可见像对齐才踩得住
        img.paste(sprite, ((r[0] + r[2]) // 2 - (bb[0] + bb[2]) // 2, r[1] - bb[3]), sprite)
    return img


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

    spr = Image.open(os.path.join(SLIME, "idle_0.png")).convert("RGBA")
    spr = spr.resize((spr.width * SCALE, spr.height * SCALE), Image.NEAREST)

    font, small = G._font(15), G._font(12)
    names = (
        ("A  steel + collar", "A",
         "机械话：钢色身体 + 铆钉 + 前缘一道亮白，洞口配钢鞘。与地皮、与那扇青门都拉开距离；"
         "代价是这块「不属于地形」的说法要和玩家的教育成本一起付"),
        ("B  cyan plate", "B",
         "光的家族：暗身 + 顶面实心青。和残影踏板的冻结格、那扇青门共用一套「能踩/带电」的话，"
         "教会一次就够；代价是屏幕上一共三个青的东西，且它跟危险物同族"),
        ("C  terrain + lip", "C",
         "最便宜也最直白：身体就是那块地皮（点阵 + 缝），顶面给一道地唇。读起来是"
         "「多出来一截地面」，不收学费；代价是身体对背景墙的对比度天然低，全靠顶唇那两像素"),
    )
    heads = ("full frame @ full travel", "retracted (only the socket)",
             "mid-travel (flows)", "PINNED mid-travel (thru CRT)", "full travel + hero")

    head_h = 58
    row_h = CELL_H + 44
    sheet = Image.new("RGB", (LABEL_W + (CELL_W + GAP) * 5 + GAP,
                              head_h + row_h * (len(names) + 1) + 18), (16, 18, 24))
    d = ImageDraw.Draw(sheet)
    d.text((12, 8), "PISTON STEP / skin v1 (D49)   base = real level_1 frame spot2_raw   "
                    "pinned column = same-formula CRT (linearFac 1.3 / scan 0.10 / chroma)   "
                    "block 64 world px = 2 cells, mid column 32 px   socket mouth = device y 390",
           fill=LIP, font=G._font(17))
    xs = tuple(LABEL_W + (CELL_W + GAP) * i for i in range(5))
    for x, label in zip(xs, heads):
        d.text((x + 6, 36), label, fill=(124, 136, 176), font=small)
    d.line([(0, head_h - 4), (sheet.width, head_h - 4)], fill=(40, 46, 62))

    d.text((12, head_h + 6), "0  reference: nothing here today", fill=LIP, font=font)
    d.text((12, head_h + 26), "wall %s / 这列位置本来只有空墙与地皮" % (base.getpixel((900, 300)),),
           fill=(124, 136, 176), font=small)
    for x in xs:
        sheet.paste(tile(base, W, H) if x == xs[0] else tile(crop_of(base), CROP[0], CROP[1]), (x, head_h))

    for i, (label, kind, note) in enumerate(names):
        y0 = head_h + (i + 1) * row_h
        d.line([(0, y0 - 4), (sheet.width, y0 - 4)], fill=(40, 46, 62))
        cols = []
        for e, frozen, hero in ((BLK, False, False), (0, False, False),
                                (MID, False, False), (MID, True, False), (BLK, False, True)):
            img = draw_variant(base, spr, kind, e, frozen, hero)
            if frozen:
                img = crt(img, **SHIPPED)
            cols.append(img)
        sheet.paste(tile(cols[0], W, H), (xs[0], y0))
        for j in range(1, 5):
            sheet.paste(tile(crop_of(cols[j]), CROP[0], CROP[1]), (xs[j], y0))
        d.text((12, y0 + 6), label, fill=LIP, font=font)
        for j, ln in enumerate(_wrap(d, note, small, LABEL_W - 24)):
            d.text((12, y0 + 26 + j * 16), ln, fill=(124, 136, 176), font=small)

        wall = cols[2].getpixel((900, 300))
        box = _band(MID)
        lip = (box[0], block_rect(MID)[1], box[2], block_rect(MID)[1] + 4)
        pinned = cols[3]
        txt = ("mid peak/wall %.1f -> pinned %.1f   body/wall %.1f   lip/door %.1f   "
               "ink mid %d%%   socket ink %d%%" % (
                   _peak(cols[2], box, wall), _peak(pinned, box, pinned.getpixel((900, 300))),
                   G._cr(pinned.getpixel(((box[0] + box[2]) // 2, box[1] + 22)), wall),
                   _peak(pinned, lip, pinned.getpixel(DOOR_AT)),
                   _ink(cols[2], base, box),
                   _ink(cols[1], base, (px(X0) - 12, px(GROUND) - 12, px(X0 + BLK) + 12,
                                        px(GROUND) + 12))))
        d.text((xs[0] + 6, y0 + CELL_H + 16), txt, fill=(150, 168, 210), font=small)
        print("%-22s %s" % (label, txt))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT)
    print("wrote %s  %dx%d" % (OUT, sheet.width, sheet.height))


if __name__ == "__main__":
    main()
