"""生成瓦片图集 + 同源预览 —— D24 资产管线的第一段。

用法：py tools/gen_tiles.py
产物（assets/tiles/）：
  tilesheet_terrain.png   64x64，16 格，按「四邻是否实心」的掩码排布（掩码定义见 tiles.json）
  tilesheet_decor.png     256x256 RGBA，装饰图集（含 wall_fill / shade 两块功能性瓦片）
  tiles.json              图集清单；tools/build_tileset.gd 照它建 TileSet
  preview_room_ab.png     从上面两张图集逐格拼出来的房间 —— 和引擎同一条合成路径
  preview_room_a/b/c.png  同一间房的另外几套配色，只作对比，不进引擎
  preview_room_d/e/f/g.png 同上，但带 soft=True：暗描边朝外 + 角上斜切成圆角 + 装饰补贴纸边。
                          落盘那套 ab 是「亮边朝外」的金属语言，和主角 (4,4,4) 粗轮廓不同源；
                          这四套是给换风格准备的候选，选定前不动 tilesheet_*.png。
  preview_tiles.png       图集放大图 + 现有构件占位色落在新地砖上的兼容性条

和早期选型预览的三点不同，全是为了「预览 == 引擎」：
1. 地形按 16px 单格画，不再按整块 mass 画。32px 板缝在 16px 瓦片上无法连续，主体
   改成周期 4 的拉丝纹（4 整除 16，平铺不跳），板感交给踏面/竖面那套四像素语言；
   坑的暗度也不再是逐行渐变（每格独立画，渐变必然在格与格之间断层），改成装饰层
   的一块 shade 半透明瓦片。
2. 装饰画在 RGBA 上，光晕用真 alpha，不再往背景色里掺色 —— 引擎里没有「背景色」可掺，
   装饰层下面可能是墙、可能是坑、可能是别的装饰。
3. 房间预览是从图集里裁格子拼的，邻居掩码的取法和 build_tileset.gd 写进 TileSet 的
   完全一致，所以这张图上看到的接缝就是 F5 里会看到的接缝。

美术与碰撞的契约（tools/tileset_selftest.gd 会逐条断言）：
  上开的格子第 0 行必须不透明，暗分隔线在第 3 行；左/右开的格子同理转 90 度，
  取样行/列固定取 8（避开角上踏面覆盖竖面的那 4 像素）。16 格的碰撞形状全是整格矩形，
  所以「美术亮边和碰撞面差几像素」这种 bug 在构造上就不可能出现。
"""

import json
import os
from PIL import Image, ImageDraw, ImageFont

TILE = 16
ZOOM = 2                      # PlayerCamera.zoom = 2 -> 1 世界像素 = 2 屏幕像素
FRAME = 44                    # 主角帧画布
FEET_ROW = FRAME // 2 + 15    # = 37：帧内这一行的上边界就是脚底基线

W_WORLD, H_WORLD = 640, 400
CEIL_H = 16
WALL_W = 32
FLOOR_Y = 320
PIT_X, PIT_W, PIT_DEPTH = 384, 48, 64
LEDGES = [(176, 224, 96), (320, 144, 96)]   # x, y, 宽（厚 16）

# 邻居掩码：某位为 1 表示那一侧「还有实心地形」，该侧就不画踏面/竖面
UP, RIGHT, DOWN, LEFT = 1, 2, 4, 8

SHADE = (38, 46, 56, 150)     # 坑道压暗：叠在 wall_fill 上，比地面暗一档、比墙面暗两档

# 现有构件的占位色（照抄各 .gd 的 @export 默认值），用来验「地砖一亮，构件还读不读得出来」
DOOR = (168, 107, 77)        # door.gd panel_color = Color(0.66,0.42,0.3)
BUTTON = (217, 168, 71)      # button_plate.gd plate_color = Color(0.85,0.66,0.28)
ALTAR = (250, 209, 107)      # ability_altar.gd active_color = Color(0.98,0.82,0.42)
BLOCK = (158, 168, 189)      # moving_block.gd block_color = Color(0.62,0.66,0.74)
OLD_TERRAIN = (82, 89, 107)  # platform.gd color = Color(0.32,0.35,0.42)

STYLES = {
    "ab": dict(
        label="AB  PORCELAIN WALL + STEEL PLATE FLOOR  (chosen mix, shipped)",
        motif_bg="ceramic", motif_terrain="plate",
        bg=(222, 229, 235), bg2=(200, 210, 220), bg3=(176, 189, 201),
        surface=(142, 156, 172), grout=(116, 130, 147), deep=(94, 108, 125),
        lip=(238, 243, 248), lip_shade=(198, 209, 221), edge=(66, 80, 98),
        accent=(62, 163, 199), accent2=(240, 180, 41),
        glass=(199, 230, 240), metal=(122, 137, 156), screen=(26, 38, 46),
    ),
    "a": dict(
        label="A  CLINICAL PORCELAIN  (white wall tile + large floor slab)",
        motif_bg="ceramic", motif_terrain="plate",
        bg=(222, 229, 235), bg2=(200, 210, 220), bg3=(176, 189, 201),
        surface=(178, 190, 202), grout=(150, 164, 178), deep=(126, 140, 155),
        lip=(251, 253, 255), lip_shade=(212, 222, 232), edge=(94, 112, 131),
        accent=(62, 163, 199), accent2=(104, 201, 102),
        glass=(199, 230, 240), metal=(163, 178, 192), screen=(26, 38, 46),
    ),
    "b": dict(
        label="B  BRUSHED STEEL BAY  (corrugated wall + riveted plate floor)",
        motif_bg="corrugated", motif_terrain="plate",
        bg=(196, 206, 218), bg2=(170, 182, 197), bg3=(142, 156, 172),
        surface=(142, 156, 172), grout=(116, 130, 147), deep=(94, 108, 125),
        lip=(238, 243, 248), lip_shade=(198, 209, 221), edge=(66, 80, 98),
        accent=(122, 214, 255), accent2=(240, 180, 41),
        glass=(142, 192, 216), metal=(122, 137, 156), screen=(18, 28, 36),
    ),
    "c": dict(
        label="C  WARM RETRO LAB  (subway tile wall + terrazzo floor)",
        motif_bg="brick", motif_terrain="speckle",
        bg=(223, 210, 183), bg2=(203, 187, 154), bg3=(174, 155, 120),
        surface=(188, 170, 136), grout=(160, 142, 110), deep=(134, 116, 86),
        lip=(251, 246, 231), lip_shade=(222, 208, 178), edge=(94, 76, 52),
        accent=(74, 140, 131), accent2=(224, 138, 60),
        glass=(198, 217, 199), metal=(151, 121, 85), screen=(24, 34, 30),
    ),
    # —— 以下四套是「贴纸语言」候选：soft=True 把描边翻到外侧、角上斜切成圆角。
    #    主角是 (4,4,4) 粗轮廓 + 内部高光 + 大白眼，落盘那套 ab 是亮边朝外的金属语言，
    #    两者不同源。这四套先只出预览，选定后才动 tilesheet_*.png 与构件配色。
    "d": dict(
        label="D  CANDY STICKER  (padded lilac wall + polka mint floor, plum outline)",
        motif_bg="quilt", motif_terrain="dot", soft=True,
        bg=(236, 227, 240), bg2=(214, 203, 222), bg3=(192, 180, 202),
        surface=(168, 210, 190), grout=(140, 186, 164), deep=(112, 156, 136),
        lip=(252, 252, 250), lip_shade=(212, 236, 222), edge=(56, 44, 62),
        accent=(96, 196, 214), accent2=(240, 132, 158),
        glass=(210, 238, 244), metal=(186, 176, 202), screen=(46, 38, 58),
        pit_shade=(46, 34, 60, 150),
    ),
    "e": dict(
        label="E  TOY PLAYROOM  (round subway wall + honey wood floor, brown outline)",
        motif_bg="brick_round", motif_terrain="wood", soft=True,
        bg=(247, 236, 217), bg2=(228, 213, 186), bg3=(202, 184, 154),
        surface=(214, 166, 112), grout=(184, 136, 88), deep=(150, 106, 66),
        lip=(255, 246, 227), lip_shade=(236, 206, 162), edge=(84, 56, 42),
        accent=(116, 184, 158), accent2=(242, 162, 62),
        glass=(216, 234, 228), metal=(202, 180, 152), screen=(58, 46, 40),
        pit_shade=(70, 42, 22, 150),
    ),
    "f": dict(
        label="F  GUMMY GOO  (polka cream wall + apricot jelly floor, warm outline)",
        motif_bg="dot", motif_terrain="gummy", soft=True,
        bg=(245, 233, 221), bg2=(226, 210, 196), bg3=(202, 184, 170),
        surface=(236, 162, 126), grout=(210, 134, 104), deep=(176, 106, 84),
        lip=(255, 241, 232), lip_shade=(248, 202, 180), edge=(76, 42, 44),
        accent=(124, 210, 180), accent2=(250, 196, 86),
        glass=(226, 242, 234), metal=(212, 190, 180), screen=(54, 36, 40),
        pit_shade=(72, 34, 30, 150),
    ),
    "g": dict(
        label="G  NIGHT GLOW  (dark control group - read the contrast report below)",
        motif_bg="grid", motif_terrain="gummy", soft=True,
        bg=(74, 84, 118), bg2=(60, 68, 98), bg3=(48, 54, 80),
        surface=(104, 120, 164), grout=(80, 94, 134), deep=(56, 66, 100),
        lip=(206, 222, 250), lip_shade=(150, 168, 210), edge=(22, 26, 42),
        accent=(110, 230, 240), accent2=(250, 190, 74),
        glass=(130, 178, 210), metal=(124, 136, 176), screen=(18, 24, 40),
        pit_shade=(8, 12, 26, 165),
    ),
    # g2 不是第五套候选，也不落盘：调色板逐字节等于 g，只多一个 player_rim。
    # 暗底上近黑身体靠明度分不出来（主角/墙只有 2.63），唯一的解是把描边反过来 ——
    # 给主角补一圈比墙亮的边。这张图就是为了让这个补救措施被看见，而不是被想象。
    "g2": dict(
        label="G2 = G + player rim light  (same tiles, this is what you actually play)",
        player_rim=(206, 222, 250),
    ),
}
STYLES["g2"] = dict(STYLES["g"], **STYLES["g2"])
ORDER = ("ab", "a", "b", "c", "d", "e", "f", "g", "g2")

# 落盘的那一套。tilesheet_*.png / tiles.json / build_tileset 只认这个 key。
#   g  = 夜光（贴纸语言）。主角轮廓对墙的对比度只有 2.63，靠给身体补一圈亮边解决，
#        见 g2 —— 那一张才是实际会玩出来的效果，g 是没补边时的样子。
#   d  = 软糖贴纸，留给后面的关卡（同一套 soft 语言，换配色即可）。
#   ab = D24 那套「亮边朝外」的金属语言，已退役，留在表里只为出对比预览。
SHIPPED = "g"

# 装饰图集：所有矩形都必须 16 对齐且宽高是 16 的整数倍 —— TileMapLayer 只能按整格放，
# 图集格子的取图区域也恒等于 coords*16 + size*16，没有单独设 texture_region 的接口。
DECOR = {
    "wall_fill":     (0, 0, 16, 16),      # 背景墙贴面，铺满整个 WallFill 层
    "shade":         (16, 0, 16, 16),     # 坑道压暗，半透明
    "window":        (32, 0, 96, 64),
    "monitor":       (128, 0, 48, 32),
    "led_panel":     (176, 0, 32, 32),
    "vent":          (208, 0, 32, 16),
    "cabinet":       (0, 64, 64, 48),
    "cabinet_small": (64, 64, 48, 32),
    "hazard":        (112, 64, 32, 16),
    "pipe_v":        (192, 64, 16, 96),
    "light":         (0, 112, 96, 16),
    "pipe_h":        (96, 112, 64, 16),
}
DECOR_SIZE = (256, 256)

# 房间里的装饰摆放：(名字, x, y, 重复次数)。坐标全是 16 的倍数，可以直接抄进 TileMapLayer。
DECOR_LAYOUT = [
    ("pipe_h", 32, 112, 9),        # 9 x 64 = 576，正好从左墙铺到右墙
    ("pipe_v", 560, 128, 3),       # 3 x 64 = 192，接到地面
    ("light", 80, CEIL_H, 1),
    ("light", 352, CEIL_H, 1),
    ("window", 176, 32, 1),
    ("monitor", 432, 64, 1),
    ("vent", 96, 128, 1),
    ("led_panel", 96, 176, 1),
    ("hazard", 304, 272, 1),
    ("hazard", 448, 272, 1),
    ("cabinet", 240, 272, 1),
    ("cabinet_small", 496, 288, 1),
]

SLIMES = [
    ("idle", 2, 176, FLOOR_Y, False),
    ("run", 3, 336, FLOOR_Y, False),
    ("jump", 1, 408, FLOOR_Y - 56, False),
    ("crouch", 2, 480, FLOOR_Y, False),
    ("wall_press", 1, W_WORLD - WALL_W - 10, FLOOR_Y, False),
]


# ---------------------------------------------------------------- 颜色工具

def _c(v):
    return max(0, min(255, int(round(v))))


def lighter(c, t):
    return tuple(_c(c[i] + (255 - c[i]) * t) for i in range(3))


def darker(c, t):
    return tuple(_c(c[i] * (1.0 - t)) for i in range(3))


def mix(a, b, t):
    return tuple(_c(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rgba(c, a):
    return (c[0], c[1], c[2], a)


def _rlum(c):
    """WCAG 相对亮度。用它而不是简单加权和：人眼对亮度的感知是非线性的，
    灰度平均值会把深色那一端糊成一团，而主角恰好整团都在那一端。"""
    def f(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])


def _cr(a, b):
    """对比度 1.0 ~ 21.0。低于 3 就是「糊在一起」，平台跳跃里主角轮廓至少要 4.5。"""
    la, lb = _rlum(a), _rlum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def _font(size):
    try:
        return ImageFont.load_default(size=size)
    except Exception:
        return ImageFont.load_default()


# ---------------------------------------------------------------- 单格表面语言
# 每种 motif 都必须在 16px 内自洽：平铺时相邻格的缝、肋、错缝都要对得上。
# 原预览里的 32px 钢板缝在这里被换成周期 4 的拉丝纹 —— 32 的图案在 16 的格子上
# 要么断层、要么每格都画一遍变成 16px 网格，两种都比现在这个更糟。

def paint_body(d, x, y, base, seam, motif):
    d.rectangle([x, y, x + 15, y + 15], fill=base)
    if motif == "plate":                                # 拉丝钢板：周期 4，整除 16
        for r in range(16):
            if r % 4 == 1:
                d.rectangle([x, y + r, x + 15, y + r], fill=darker(base, 0.05))
            elif r % 4 == 3:
                d.rectangle([x, y + r, x + 15, y + r], fill=lighter(base, 0.03))
    elif motif == "speckle":                            # 水磨石：斑点位置写死在格内，平铺必对齐
        for i, (sx, sy) in enumerate(((3, 4), (11, 7), (6, 12), (13, 13), (9, 2))):
            d.rectangle([x + sx, y + sy, x + sx, y + sy],
                        fill=darker(base, 0.16) if i % 2 else lighter(base, 0.35))
    elif motif == "brick":                              # 错缝砌：8px 两行为一格，奇数行偏半砖
        for k in range(2):
            ry = y + k * 8
            d.rectangle([x, ry, x + 15, ry], fill=seam)
            d.rectangle([x, ry + 1, x + 15, ry + 1], fill=lighter(base, 0.30))
            vx = x + (8 if k else 0)
            d.rectangle([vx, ry + 1, vx, ry + 7], fill=seam)
    elif motif == "dot":                                # 波点：暗环 + 亮心。全用 lighter 在奶白底上等于没画
        for sx, sy in ((4, 4), (12, 12)):
            d.rectangle([x + sx - 1, y + sy, x + sx + 1, y + sy + 1], fill=darker(base, 0.08))
            d.rectangle([x + sx, y + sy, x + sx, y + sy], fill=lighter(base, 0.34))
    elif motif == "quilt":                              # 软包菱格：每格一个 X，邻格的对角线在角上接成连续网格
        d.line([(x, y), (x + 15, y + 15)], fill=seam)
        d.line([(x, y + 15), (x + 15, y)], fill=seam)
        d.rectangle([x + 6, y + 6, x + 9, y + 9], fill=lighter(base, 0.30))   # 中央鼓包
        d.rectangle([x + 7, y + 7, x + 8, y + 8], fill=lighter(base, 0.46))
        d.rectangle([x + 9, y + 6, x + 9, y + 9], fill=darker(base, 0.07))    # 右下投影，只靠 lighter 在浅墙上看不见
        d.rectangle([x + 6, y + 9, x + 9, y + 9], fill=darker(base, 0.07))
    elif motif == "brick_round":                        # 圆角地铁砖：行 0 竖缝在 x=0、行 1 在 x=8，周期 16
        for k in range(2):
            ry = y + k * 8
            d.rectangle([x + 1, ry + 1, x + 15, ry + 1], fill=lighter(base, 0.26))
            d.rectangle([x + 1, ry + 6, x + 15, ry + 6], fill=darker(base, 0.10))
        for k in range(2):                              # 缝最后画，才能把高光和阴影切断
            ry = y + k * 8
            d.rectangle([x, ry, x + 15, ry], fill=seam)
            vx = x + (8 if k else 0)
            d.rectangle([vx, ry, vx, ry + 7], fill=seam)
    elif motif == "wood":                               # 玩具木：横纹周期不定但都在格内，木节单独一粒
        for r in (2, 6, 11):
            d.rectangle([x, y + r, x + 15, y + r], fill=darker(base, 0.09))
            d.rectangle([x, y + r + 1, x + 15, y + r + 1], fill=lighter(base, 0.12))
        d.ellipse([x + 9, y + 12, x + 13, y + 14], fill=darker(base, 0.16))
        d.ellipse([x + 10, y + 13, x + 12, y + 13], fill=lighter(base, 0.14))
    elif motif == "gummy":                              # 果冻：横向柔光带 + 收釉暗线，圆团 16px 一重复会读成壁纸圆点
        d.rectangle([x + 2, y + 2, x + 11, y + 3], fill=lighter(base, 0.30))
        d.rectangle([x + 2, y + 4, x + 8, y + 4], fill=lighter(base, 0.15))
        d.rectangle([x, y + 12, x + 15, y + 12], fill=darker(base, 0.07))
        d.ellipse([x + 11, y + 8, x + 13, y + 10], fill=lighter(base, 0.22))
    elif motif == "grid":                               # 圆角软面板：整格一圈缝，内侧上亮下暗
        for v in (y, y + 15):
            d.rectangle([x, v, x + 15, v], fill=seam)
        for u in (x, x + 15):
            d.rectangle([u, y, u, y + 15], fill=seam)
        d.rectangle([x + 1, y + 1, x + 14, y + 2], fill=lighter(base, 0.20))
        d.rectangle([x + 1, y + 13, x + 14, y + 14], fill=darker(base, 0.12))
    elif motif == "corrugated":                         # 瓦楞：4px 肋
        for i in range(4):
            cx = x + i * 4
            d.rectangle([cx, y, cx + 3, y + 15], fill=base if i % 2 == 0 else lighter(base, 0.11))
            d.rectangle([cx, y, cx, y + 15], fill=darker(base, 0.11))
        d.rectangle([x, y, x + 15, y], fill=seam)
        d.rectangle([x, y + 1, x + 15, y + 1], fill=darker(seam, 0.14))
    else:                                               # ceramic：细格缝 + 单格倒角
        d.rectangle([x, y, x + 15, y], fill=seam)
        d.rectangle([x, y, x, y + 15], fill=seam)
        d.rectangle([x + 1, y + 1, x + 15, y + 1], fill=lighter(base, 0.42))
        d.rectangle([x + 1, y + 1, x + 1, y + 15], fill=lighter(base, 0.42))
        d.rectangle([x + 2, y + 14, x + 15, y + 14], fill=darker(base, 0.13))
        d.rectangle([x + 14, y + 2, x + 14, y + 14], fill=darker(base, 0.13))


# ---------------------------------------------------------------- 地形图集

def cap_top(d, p, x, y):
    """踏面：1px 最亮 + 2px 次亮 + 1px 暗分隔线。那条暗线是「这里能站」的唯一视觉证据，
    任何一套配色都必须让它和背景拉开足够差 —— 平台跳跃的可读性优先于好看。

    soft 分支把这条契约换了个实现：暗线挪到第 0 行当描边，亮面收进第 1 行。
    「能站」的证据从「一条内嵌暗线」变成「整圈黑描边把这块地形从背景里剪出来」，
    和主角身上那圈 (4,4,4) 轮廓是同一套读法。第 0 行仍然整行不透明。"""
    if p.get("soft"):
        d.rectangle([x, y, x + 15, y], fill=p["edge"])
        d.rectangle([x + 1, y + 1, x + 14, y + 1], fill=p["lip"])
        d.rectangle([x, y + 2, x + 15, y + 3], fill=p["lip_shade"])
        d.rectangle([x, y + 4, x + 15, y + 4], fill=darker(p["lip_shade"], 0.26))
        return
    d.rectangle([x, y + 3, x + 15, y + 3], fill=p["edge"])
    d.rectangle([x, y + 1, x + 15, y + 2], fill=p["lip_shade"])
    d.rectangle([x, y, x + 15, y], fill=p["lip"])


def face_left(d, p, x, y):
    if p.get("soft"):
        d.rectangle([x, y, x, y + 15], fill=p["edge"])
        d.rectangle([x + 1, y + 1, x + 1, y + 14], fill=p["lip"])
        d.rectangle([x + 2, y, x + 3, y + 15], fill=p["lip_shade"])
        return
    d.rectangle([x, y, x, y + 15], fill=p["lip"])
    d.rectangle([x + 1, y, x + 2, y + 15], fill=p["lip_shade"])
    d.rectangle([x + 3, y, x + 3, y + 15], fill=p["edge"])


def face_right(d, p, x, y):
    if p.get("soft"):
        d.rectangle([x + 15, y, x + 15, y + 15], fill=p["edge"])
        d.rectangle([x + 14, y + 1, x + 14, y + 14], fill=p["lip"])
        d.rectangle([x + 12, y, x + 13, y + 15], fill=p["lip_shade"])
        return
    d.rectangle([x + 12, y, x + 12, y + 15], fill=p["edge"])
    d.rectangle([x + 13, y, x + 14, y + 15], fill=p["lip_shade"])
    d.rectangle([x + 15, y, x + 15, y + 15], fill=p["lip"])


def underside(d, p, x, y):
    if p.get("soft"):
        d.rectangle([x, y + 15, x + 15, y + 15], fill=p["edge"])
        d.rectangle([x + 1, y + 13, x + 14, y + 14], fill=p["deep"])
        return
    d.rectangle([x, y + 13, x + 15, y + 14], fill=p["deep"])
    d.rectangle([x, y + 15, x + 15, y + 15], fill=p["edge"])


def soft_corners(d, p, x, y, mask):
    """外凸角上把内圈亮线让开一格：1 像素斜切在 2 倍取景下就是 2 像素圆角。
    只动第 1 行和第 14 行，第 0 / 15 行整行不透明这条不许破 —— 碰撞是整格矩形，
    角上漏一个透明像素就是「踩在空气上」。"""
    if not p.get("soft"):
        return
    hi = darker(p["lip_shade"], 0.34)
    lo = darker(p["deep"], 0.34)
    if not mask & UP:
        if not mask & LEFT:
            d.rectangle([x + 1, y + 1, x + 1, y + 1], fill=hi)
        if not mask & RIGHT:
            d.rectangle([x + 14, y + 1, x + 14, y + 1], fill=hi)
    if not mask & DOWN:
        if not mask & LEFT:
            d.rectangle([x + 1, y + 14, x + 1, y + 14], fill=lo)
        if not mask & RIGHT:
            d.rectangle([x + 14, y + 14, x + 14, y + 14], fill=lo)


def paint_terrain_tile(d, p, x, y, mask):
    """一格地形。绘制顺序是有讲究的：主体 -> 底面 -> 竖面 -> 踏面。
    踏面最后画，所以外角上亮边会绕过去（角像素同时是踏面第 0 行和竖面第 0 列，
    两者都是 lip 色，接缝看不出来）；底面先画，所以悬空平台的左下角/右下角
    由竖面的亮边收尾，而不是被 underside 的暗线切断。"""
    paint_body(d, x, y, p["surface"], p["grout"], p["motif_terrain"])
    if not mask & DOWN:
        underside(d, p, x, y)
    if not mask & LEFT:
        face_left(d, p, x, y)
    if not mask & RIGHT:
        face_right(d, p, x, y)
    if not mask & UP:
        cap_top(d, p, x, y)
    soft_corners(d, p, x, y, mask)


def build_terrain_atlas(p):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 255))
    d = ImageDraw.Draw(img, "RGBA")
    for mask in range(16):
        paint_terrain_tile(d, p, (mask % 4) * TILE, (mask // 4) * TILE, mask)
    return img


# ---------------------------------------------------------------- 装饰图集（RGBA）

def decor_light(d, p, x, y):
    d.rectangle([x, y, x + 95, y + 1], fill=p["metal"])
    d.rectangle([x + 1, y + 2, x + 94, y + 3], fill=mix(p["accent"], (255, 255, 255), 0.78))
    d.rectangle([x, y + 4, x + 95, y + 4], fill=darker(p["metal"], 0.25))
    glow = mix(p["accent"], (255, 255, 255), 0.55)
    for r0, r1, a in ((5, 6, 115), (7, 8, 66), (9, 10, 33), (11, 13, 16)):
        d.rectangle([x, y + r0, x + 95, y + r1], fill=rgba(glow, a))


def decor_pipe_h(d, p, x, y):
    d.rectangle([x, y + 5, x + 63, y + 10], fill=p["metal"])
    d.rectangle([x, y + 6, x + 63, y + 6], fill=lighter(p["metal"], 0.45))
    d.rectangle([x, y + 10, x + 63, y + 10], fill=darker(p["metal"], 0.30))
    for k in range(2):                                  # 法兰：32px 一处，64 宽的格子正好两处
        fx = x + k * 32
        d.rectangle([fx, y + 4, fx + 2, y + 11], fill=darker(p["metal"], 0.18))
        d.rectangle([fx, y + 4, fx, y + 11], fill=lighter(p["metal"], 0.25))


def decor_pipe_v(d, p, x, y):
    d.rectangle([x + 5, y, x + 10, y + 95], fill=p["metal"])
    d.rectangle([x + 6, y, x + 6, y + 95], fill=lighter(p["metal"], 0.45))
    d.rectangle([x + 10, y, x + 10, y + 95], fill=darker(p["metal"], 0.30))
    for k in range(3):
        fy = y + k * 32
        d.rectangle([x + 4, fy, x + 11, fy + 2], fill=darker(p["metal"], 0.18))
        d.rectangle([x + 4, fy, x + 11, fy], fill=lighter(p["metal"], 0.25))


def decor_window(d, p, x, y, w, h):
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=p["metal"])
    d.rectangle([x + 1, y + 1, x + w - 2, y + h - 2], fill=darker(p["metal"], 0.28))
    ix0, iy0, ix1, iy1 = x + 3, y + 3, x + w - 4, y + h - 4
    for k in range(iy1 - iy0 + 1):                      # 玻璃：上亮下暗
        d.rectangle([ix0, iy0 + k, ix1, iy0 + k],
                    fill=mix(p["glass"], (255, 255, 255), 0.22 * (1.0 - k / max(iy1 - iy0, 1))))
    d.rectangle([(x + x + w) // 2 - 1, iy0, (x + x + w) // 2, iy1], fill=p["metal"])
    d.line([ix0 + 4, iy1 - 3, ix0 + 16, iy0 + 3], fill=lighter(p["glass"], 0.55), width=2)
    d.line([ix0 + 20, iy1 - 3, ix0 + 30, iy0 + 5], fill=lighter(p["glass"], 0.40), width=1)
    d.rectangle([ix0, iy0, ix1, iy0], fill=darker(p["glass"], 0.30))
    d.rectangle([ix0, iy0, ix0, iy1], fill=darker(p["glass"], 0.22))


def decor_monitor(d, p, x, y, w, h):
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=lighter(p["metal"], 0.18))
    d.rectangle([x + 1, y + 1, x + w - 2, y + h - 2], fill=darker(p["metal"], 0.22))
    sx0, sy0, sx1, sy1 = x + 3, y + 3, x + w - 4, y + h - 6
    d.rectangle([sx0, sy0, sx1, sy1], fill=p["screen"])
    mid = (sy0 + sy1) // 2
    pts = [(sx0 + i, mid + (0, -3, 3, -1, 1, -4, 2)[i % 7]) for i in range(sx1 - sx0 + 1)]
    d.line(pts, fill=p["accent"], width=1)
    d.rectangle([sx0, sy1 - 1, sx1, sy1], fill=darker(p["screen"], 0.4))
    for i, c in enumerate((p["accent2"], p["accent"], (240, 240, 240))):
        d.rectangle([x + 4 + i * 4, y + h - 3, x + 5 + i * 4, y + h - 3], fill=c)
    d.rectangle([x + w // 2 - 3, y + h - 1, x + w // 2 + 2, y + h - 1], fill=darker(p["metal"], 0.3))


def decor_vent(d, p, x, y, w, h):
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=p["metal"])
    d.rectangle([x + 2, y + 2, x + w - 3, y + h - 3], fill=darker(p["metal"], 0.55))
    for r in range(y + 3, y + h - 3, 3):
        d.rectangle([x + 2, r, x + w - 3, r], fill=lighter(p["metal"], 0.20))


def decor_hazard(d, p, x, y, w, h):
    dark = darker(p["accent2"], 0.55)
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=p["accent2"])
    for py in range(y, y + h):                          # 45 度斜条：逐像素判，边缘天然被裁齐
        for px in range(x, x + w):
            if ((px - x + py - y) // 4) % 2 == 0:
                d.rectangle([px, py, px, py], fill=dark)
    d.rectangle([x, y, x + w - 1, y], fill=darker(p["accent2"], 0.35))
    d.rectangle([x, y + h - 1, x + w - 1, y + h - 1], fill=darker(p["accent2"], 0.35))


def decor_cabinet(d, p, x, y, w, h):
    body = lighter(p["metal"], 0.42)
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=body)
    d.rectangle([x, y, x + w - 1, y + 1], fill=lighter(body, 0.45))
    d.rectangle([x, y + 2, x + w - 1, y + 2], fill=darker(body, 0.20))
    d.rectangle([x + w // 2, y + 3, x + w // 2, y + h - 4], fill=darker(body, 0.28))
    d.rectangle([x, y + 3, x, y + h - 1], fill=darker(body, 0.14))
    d.rectangle([x + w - 1, y + 3, x + w - 1, y + h - 1], fill=darker(body, 0.22))
    for hx in (x + w // 2 - 4, x + w // 2 + 2):         # 拉手
        d.rectangle([hx, y + 8, hx + 2, y + 8], fill=darker(body, 0.45))
    d.rectangle([x + 1, y + h - 3, x + w - 2, y + h - 1], fill=darker(body, 0.50))


def decor_led_panel(d, p, x, y, w, h):
    body = lighter(p["metal"], 0.25)
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=body)
    d.rectangle([x + 1, y + 1, x + w - 2, y + h - 2], fill=darker(body, 0.22))
    d.rectangle([x + 3, y + 3, x + w - 4, y + 10], fill=p["screen"])
    d.line([x + 4, y + 8, x + 8, y + 5, x + 12, y + 9, x + 16, y + 4, x + w - 4, y + 7],
           fill=p["accent"], width=1)
    for i, c in enumerate((p["accent2"], p["accent"], lighter(p["accent2"], 0.5))):
        d.rectangle([x + 4 + i * 6, y + 14, x + 6 + i * 6, y + 16], fill=c)
    d.rectangle([x + 4, y + 20, x + w - 5, y + 22], fill=darker(body, 0.40))


PAINTERS = {
    "light": lambda d, p, x, y: decor_light(d, p, x, y),
    "pipe_h": lambda d, p, x, y: decor_pipe_h(d, p, x, y),
    "pipe_v": lambda d, p, x, y: decor_pipe_v(d, p, x, y),
    "window": lambda d, p, x, y: decor_window(d, p, x, y, 96, 64),
    "monitor": lambda d, p, x, y: decor_monitor(d, p, x, y, 48, 32),
    "led_panel": lambda d, p, x, y: decor_led_panel(d, p, x, y, 32, 32),
    "vent": lambda d, p, x, y: decor_vent(d, p, x, y, 32, 16),
    "cabinet": lambda d, p, x, y: decor_cabinet(d, p, x, y, 64, 48),
    "cabinet_small": lambda d, p, x, y: decor_cabinet(d, p, x, y, 48, 32),
    "hazard": lambda d, p, x, y: decor_hazard(d, p, x, y, 32, 16),
}

# 会重复平铺的必须跳过：擦角等于在每一格接缝处啃掉一个豁口，管子会一段段断开。
DECOR_NO_ROUND = {"wall_fill", "shade", "pipe_h", "pipe_v"}
CHAMFER = {2: (1,), 3: (2, 1), 4: (3, 2, 1)}   # 第 k 行往角外擦掉的像素数


def round_corners(img, x0, y0, x1, y1, r):
    """像素图里的「圆角」就是等腰阶梯。擦成透明而不是填背景色 —— 引擎里装饰层带真
    alpha，擦掉的角露出的是下面那层墙贴面，跟预览里看到的合成结果一致。"""
    for k, w in enumerate(CHAMFER[r]):
        for i in range(w):
            for px, py in ((x0 + i, y0 + k), (x1 - i, y0 + k), (x0 + i, y1 - k), (x1 - i, y1 - k)):
                img.putpixel((px, py), (0, 0, 0, 0))


def build_decor_atlas(p):
    img = Image.new("RGBA", DECOR_SIZE, (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    paint_body(d, 0, 0, p["bg"], p["bg2"], p["motif_bg"])       # wall_fill
    d.rectangle([16, 0, 31, 15], fill=p.get("pit_shade", SHADE))  # shade
    for name, fn in PAINTERS.items():
        rx, ry, _, _ = DECOR[name]
        fn(d, p, rx, ry)
    if p.get("soft"):
        # 先补描边再擦角：装饰都是整格矩形，描边正好落在格内不会渗到邻格。
        # 没有这圈边，米色墙配米色柜子就糊成一片（E 的 metal/bg 对比只有 1.3）。
        for name, (rx, ry, rw, rh) in DECOR.items():
            if name in DECOR_NO_ROUND:
                continue
            d.rectangle([rx, ry, rx + rw - 1, ry + rh - 1], outline=p["edge"])
            round_corners(img, rx, ry, rx + rw - 1, ry + rh - 1, 3 if rh >= 32 else 2)
    return img


def decor_tile(atlas, name):
    rx, ry, rw, rh = DECOR[name]
    return atlas.crop((rx, ry, rx + rw, ry + rh))


# ---------------------------------------------------------------- 房间（从图集拼）

def solid_rects():
    """房间的实心矩形（世界像素，全部 16 对齐）。地形尺寸必须是 32 的倍数这条约束
    在 16px 瓦片下自动满足 —— 关卡手册 §1 的设计网格没变。"""
    rects = [
        (0, 0, W_WORLD, CEIL_H),
        (0, 0, WALL_W, H_WORLD),
        (W_WORLD - WALL_W, 0, WALL_W, H_WORLD),
        (WALL_W, FLOOR_Y, PIT_X - WALL_W, H_WORLD - FLOOR_Y),
        (PIT_X + PIT_W, FLOOR_Y, W_WORLD - WALL_W - PIT_X - PIT_W, H_WORLD - FLOOR_Y),
        (PIT_X, FLOOR_Y + PIT_DEPTH, PIT_W, H_WORLD - FLOOR_Y - PIT_DEPTH),
    ]
    rects += [(lx, ly, lw, TILE) for lx, ly, lw in LEDGES]
    return rects


def cell_set(rects):
    cells = set()
    for x, y, w, h in rects:
        for cy in range(y // TILE, (y + h) // TILE):
            for cx in range(x // TILE, (x + w) // TILE):
                cells.add((cx, cy))
    return cells


def render_room(p, root):
    terrain = build_terrain_atlas(p)
    decor = build_decor_atlas(p)
    solid = cell_set(solid_rects())
    img = Image.new("RGBA", (W_WORLD, H_WORLD), (0, 0, 0, 255))

    wall_fill = decor_tile(decor, "wall_fill")          # z = -30
    for cy in range(H_WORLD // TILE):
        for cx in range(W_WORLD // TILE):
            img.paste(wall_fill, (cx * TILE, cy * TILE))

    shade = decor_tile(decor, "shade")                  # z = -20，坑道
    for cy in range(FLOOR_Y // TILE, (FLOOR_Y + PIT_DEPTH) // TILE):
        for cx in range(PIT_X // TILE, (PIT_X + PIT_W) // TILE):
            img.paste(shade, (cx * TILE, cy * TILE), shade)

    for name, x, y, rep in DECOR_LAYOUT:                # z = -20，摆件
        t = decor_tile(decor, name)
        step = DECOR[name][2] if name == "pipe_h" else DECOR[name][3]
        for i in range(rep):
            dx = x + i * step if name == "pipe_h" else x
            dy = y if name == "pipe_h" else y + i * step
            img.paste(t, (dx, dy), t)

    for (cx, cy) in sorted(solid):                      # z = 0，地形
        mask = ((UP if (cx, cy - 1) in solid else 0) | (RIGHT if (cx + 1, cy) in solid else 0) |
                (DOWN if (cx, cy + 1) in solid else 0) | (LEFT if (cx - 1, cy) in solid else 0))
        t = terrain.crop(((mask % 4) * TILE, (mask // 4) * TILE,
                          (mask % 4) * TILE + TILE, (mask // 4) * TILE + TILE))
        img.paste(t, (cx * TILE, cy * TILE))

    img = img.convert("RGB").resize((W_WORLD * ZOOM, H_WORLD * ZOOM), Image.NEAREST)
    rim = p.get("player_rim")
    for clip, i, cx, feet, flip in SLIMES:
        paste_slime(img, clip, i, cx, feet, flip, ZOOM, root, rim)
    d = ImageDraw.Draw(img)
    dims(d)
    ink = (240, 244, 250) if _rlum(p["bg"]) < 0.35 else (30, 34, 40)
    d.text((8, 6), p["label"], fill=(240, 60, 60), font=_font(14))
    d.text((8, 24), "assembled from the real atlases: 16px cells, 4-side autotile, "
                    "640x400 world @ zoom 2", fill=ink, font=_font(12))
    return img


def add_rim(frame, color):
    """贴一圈 1 像素描边。邻居判定读的是原始 alpha，所以边只会有一圈、不会往里滚。"""
    w, h = frame.size
    a = frame.getchannel("A")
    out = frame.copy()
    for cy in range(h):
        for cx in range(w):
            if a.getpixel((cx, cy)):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < w and 0 <= ny < h and a.getpixel((nx, ny)):
                    out.putpixel((cx, cy), color)
                    break
    return out


def paste_slime(img, clip, i, cx_world, feet_world, flip=False, zoom=ZOOM, root=None, rim=None):
    path = os.path.join(root, "assets", "player", "slime", "%s_%d.png" % (clip, i))
    if not os.path.exists(path):
        raise SystemExit("缺主角帧 %s —— 先跑 py tools/gen_player_frames.py" % path)
    frame = Image.open(path).convert("RGBA")
    if rim:
        # 缩放前加，一圈才是 1 世界像素（2 倍取景后 2 屏幕像素）；缩放后再加就变 1 屏幕像素的细丝
        frame = add_rim(frame, rim)
    if flip:
        frame = frame.transpose(Image.FLIP_LEFT_RIGHT)
    frame = frame.resize((FRAME * zoom, FRAME * zoom), Image.NEAREST)
    img.paste(frame, (cx_world * zoom - FRAME * zoom // 2, feet_world * zoom - FEET_ROW * zoom), frame)


def dims(d):
    """红色标注：量出来的缺口与高差，对关卡手册 §8（可通行缝隙 >= 40、跳跃峰高 136）。"""
    red = (226, 62, 62)
    z = ZOOM
    y = (FLOOR_Y + 32) * z                              # 坑宽
    d.line([PIT_X * z, y, (PIT_X + PIT_W) * z, y], fill=red, width=1)
    for xx in (PIT_X, PIT_X + PIT_W):
        d.line([xx * z, y - 4, xx * z, y + 4], fill=red, width=1)
    d.text(((PIT_X + 8) * z, y - 16), "gap 48", fill=red, font=_font(12))
    x = 160 * z                                         # 地面 -> 下层平台
    d.line([x, LEDGES[0][1] * z, x, FLOOR_Y * z], fill=red, width=1)
    for yy in (LEDGES[0][1], FLOOR_Y):
        d.line([x - 4, yy * z, x + 4, yy * z], fill=red, width=1)
    d.text((x + 6, (LEDGES[0][1] + 36) * z), "rise 96 (jump)", fill=red, font=_font(12))
    y2 = (LEDGES[1][1] + 40) * z                        # 下层平台 -> 上层平台
    d.line([272 * z, y2, 320 * z, y2], fill=red, width=1)
    d.text((276 * z, y2 - 16), "gap 48 / rise 80", fill=red, font=_font(12))


# ---------------------------------------------------------------- 图集放大图

def props_strip(p, terrain):
    """把现有构件的占位色原样摆在新地砖上 —— 地砖一亮，深灰蓝地形与琥珀色构件那套
    明度关系就反过来了，这张是用来判断「构件要不要跟着重画」的（D24 第 9 条，D25+ 处理）。"""
    w, h = 352, 128
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    wall_fill = decor_tile(build_decor_atlas(p), "wall_fill")
    for cy in range(h // TILE):
        for cx in range(w // TILE):
            img.paste(wall_fill, (cx * TILE, cy * TILE))
    body = terrain.crop((2 * TILE, 3 * TILE, 3 * TILE, 4 * TILE))   # mask=14：只有上方开
    for cx in range(w // TILE):
        img.paste(body, (cx * TILE, 112))
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([16, 112 - 96, 16 + 31, 111], fill=DOOR)             # 门 32x96
    for r in range(112 - 96 + 3, 112, 6):
        d.rectangle([16, r, 47, r], fill=darker(DOOR, 0.22))
    d.rectangle([16, 112 - 96, 47, 112 - 96], fill=darker(DOOR, 0.45))
    d.rectangle([64, 102, 127, 111], fill=BUTTON)                   # 按钮面板 64 宽
    d.rectangle([64, 102, 127, 104], fill=lighter(BUTTON, 0.35))
    d.rectangle([144, 112 - 56, 207, 111], fill=ALTAR)              # 祭坛 64x56
    d.rectangle([144, 112 - 56, 207, 112 - 52], fill=lighter(ALTAR, 0.4))
    d.rectangle([224, 112 - 64 - 16, 287, 112 - 16], fill=BLOCK)    # 移动方块 64x64（悬空）
    d.rectangle([224, 112 - 64 - 16, 287, 112 - 64 - 14], fill=lighter(BLOCK, 0.3))
    d.rectangle([304, 80, 335, 111], fill=OLD_TERRAIN)              # 旧 platform 占位色做对照
    return img.convert("RGB").resize((w * ZOOM, h * ZOOM), Image.NEAREST)


def atlas_sheet(p):
    terrain = build_terrain_atlas(p)
    decor = build_decor_atlas(p)
    ts, ds = 8, 2                                       # 地形放大 8 倍、装饰 2 倍
    tw, th = 64 * ts, 64 * ts
    dw, dh = DECOR_SIZE[0] * ds, DECOR_SIZE[1] * ds
    pad, gap = 20, 40
    strip = props_strip(p, terrain)
    W = pad * 2 + tw + gap + dw
    H = pad + 26 + max(th, dh) + 30 + strip.height + 40 + pad
    canvas = Image.new("RGB", (W, H), (188, 195, 205))
    d = ImageDraw.Draw(canvas)
    f = _font(14)
    fs = _font(12)
    d.text((pad, 8), "TILE ATLASES  16px cells  /  terrain 64x64 (16 neighbor masks)  /  "
                     "decor 256x256 RGBA  /  bottom = existing kit placeholders on the new floor (2x)",
           fill=(24, 28, 34), font=f)

    ox, oy = pad, pad + 26
    d.text((ox, oy - 18), "tilesheet_terrain.png  (x8)", fill=(24, 28, 34), font=fs)
    canvas.paste(terrain.resize((tw, th), Image.NEAREST), (ox, oy))
    for mask in range(16):                              # 每格标出掩码：U R D L，有邻居的记实心
        cx = ox + (mask % 4) * TILE * ts
        cy = oy + (mask // 4) * TILE * ts
        d.rectangle([cx, cy, cx + TILE * ts - 1, cy + TILE * ts - 1], outline=(240, 70, 70))
        tag = "".join(ch if mask & bit else "." for ch, bit in (("U", UP), ("R", RIGHT), ("D", DOWN), ("L", LEFT)))
        d.text((cx + 3, cy + 3), "%2d %s" % (mask, tag), fill=(240, 70, 70), font=fs)

    dx = ox + tw + gap
    d.text((dx, oy - 18), "tilesheet_decor.png  (x2, over checkerboard = real alpha)",
           fill=(24, 28, 34), font=fs)
    check = Image.new("RGB", (dw, dh))
    dc = ImageDraw.Draw(check)
    for cy in range(0, dh, 8):
        for cx in range(0, dw, 8):
            dc.rectangle([cx, cy, cx + 7, cy + 7], fill=(206, 211, 218) if (cx + cy) // 8 % 2 else (238, 241, 245))
    check.paste(decor.resize((dw, dh), Image.NEAREST), (0, 0), decor.resize((dw, dh), Image.NEAREST))
    canvas.paste(check, (dx, oy))
    for name, (rx, ry, rw, rh) in DECOR.items():
        d.rectangle([dx + rx * ds, oy + ry * ds, dx + (rx + rw) * ds - 1, oy + (ry + rh) * ds - 1],
                    outline=(240, 70, 70))
        d.text((dx + rx * ds + 2, oy + ry * ds + 2), name, fill=(240, 70, 70), font=fs)

    sy = oy + max(th, dh) + 30
    canvas.paste(strip, (ox, sy))
    d.text((ox, sy + strip.height + 6),
           "door 32x96 / plate 64 / altar 64x56 / block 64x64 / old platform color",
           fill=(24, 28, 34), font=fs)
    return canvas


# ---------------------------------------------------------------- 清单与入口

def write_manifest(out_dir):
    manifest = {
        "tile": TILE,
        "style": SHIPPED,
        "surface_language": "sticker" if STYLES[SHIPPED].get("soft") else "bevel",
        "terrain": {
            "file": "tilesheet_terrain.png",
            "size": [64, 64],
            "mask_bits": {"up": UP, "right": RIGHT, "down": DOWN, "left": LEFT},
            "note": "mask bit set = that side has a solid neighbour, so no cap/face is drawn there",
            "tiles": [{"mask": m, "x": (m % 4) * TILE, "y": (m // 4) * TILE} for m in range(16)],
        },
        "decor": {
            "file": "tilesheet_decor.png",
            "size": list(DECOR_SIZE),
            "items": {k: list(v) for k, v in DECOR.items()},
        },
        "layout_hint": {
            "wall_fill": "WallFill layer, every empty cell",
            "shade": "Decor layer, pit shaft cells",
        },
    }
    path = os.path.join(out_dir, "tiles.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    return path


def contrast_report(root):
    """好看由眼睛判，糊没糊由这几个数判。主角整团都在亮度曲线最低端（body 10,12,12），
    所以墙一旦压暗，掉的不是「氛围」而是轮廓 —— 尤其 G 那套深色对照组。"""
    body = (10, 12, 12)          # gen_player_frames.PAL["body"]，抄过来避免 import 时跑它的生成
    # 表头用 ASCII：控制台默认 cp936，中文列名会糊成乱码。
    # wall / floor = 相对亮度 x100；p=player，o=outline，r=rim；/wall /floor 是对比度
    print("\nSTYLE soft   wall  floor  p/wall p/floor  o/wall o/floor  r/wall")
    for key in ORDER:
        p = STYLES[key]
        rim = p.get("player_rim")
        weak = _cr(body, p["bg"]) < 4.5 and not rim
        print("%-4s %s  %5.1f %5.1f  %5.2f %6.2f   %5.2f %6.2f  %6s%s%s" % (
            key, "yes" if p.get("soft") else "no ",
            _rlum(p["bg"]) * 100, _rlum(p["surface"]) * 100,
            _cr(body, p["bg"]), _cr(body, p["surface"]),
            _cr(p["edge"], p["bg"]), _cr(p["edge"], p["surface"]),
            "%.2f" % _cr(rim, p["bg"]) if rim else "-",
            "  SHIPPED" if key == SHIPPED else "",
            "   <- player silhouette below 4.5" if weak else ""))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "tiles")
    os.makedirs(out_dir, exist_ok=True)

    shipped = STYLES[SHIPPED]
    build_terrain_atlas(shipped).save(os.path.join(out_dir, "tilesheet_terrain.png"))
    build_decor_atlas(shipped).save(os.path.join(out_dir, "tilesheet_decor.png"))
    print("saved tilesheet_terrain.png / tilesheet_decor.png  (style=%s)" % SHIPPED)
    print("saved", write_manifest(out_dir))

    for key in ORDER:
        out = os.path.join(out_dir, "preview_room_%s.png" % key)
        render_room(STYLES[key], root).save(out)
        print("saved", out)

    out = os.path.join(out_dir, "preview_tiles.png")
    atlas_sheet(shipped).save(out)
    print("saved", out)
    contrast_report(root)


if __name__ == "__main__":
    main()
