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
                          （d 已被 D67 选作第二套，落在带 _d 后缀的文件里，见下。）
  preview_tiles.png       图集放大图 + 现有构件占位色落在新地砖上的兼容性条
  —— D67 起 EXTRA_SHIPPED 里每一套也各落一份，文件名带 _<key> 后缀：
     tilesheet_terrain_d.png / tilesheet_decor_d.png / tiles_d.json / preview_tiles_d.png。
     几何与 SHIPPED 逐格同源（同一批 painters，只换调色板），所以瓦片索引一一对应、
     旧关的摆图层能整层复制进用 d 的关；SHIPPED 那一套的文件名与内容一字未动。

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
import math
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

# 在册的「可拾取」琥珀。`gen_props.py` 烤 `key_card.png` 用的就是落盘那套（g）的 accent2，
# 而告示牌上那只卡的形状说的正是「这扇门要的是这张卡」—— 所以牌上那个色必须跟着**卡**走，
# 不能跟着本套的 accent2 走：d 的 accent2 是粉，跟着走这块牌就指错了东西（D70）。
PICKUP_AMBER = (250, 190, 74)

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
        # decor_set / pickup 是 D70 那两条：装饰从「实验室词汇」换成「树丛词汇」
        # （几何与占格一格不动，只换 painters 表），并把可拾取琥珀从 accent2 里单拎出来跟着卡走。
        decor_set="grove", pickup=PICKUP_AMBER,
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

# 除 SHIPPED 之外还要落盘的风格（D67）：几何、掩码、装饰矩形与 SHIPPED 逐格同源，
# 只换调色板，所以产物一律带 `_d` 后缀而不是覆盖 `tilesheet_*.png` —— 现有关照旧指 g。
# 瓦片索引与 g 一一对应，因此旧关的摆图层可以整层复制进用 d 的关。
# 代价写在明面上：d 是亮底（墙相对亮度 79.1，g 是 9.1），主角轮廓因此从 2.63 涨到 15.70
# 且不再需要 g2 那圈亮边，但在册构件的皮是照 g 那套夜光语言烤的，落在这面墙上会糊
# （祭坛琥珀对 d 墙 1.17、按钮 1.74、青 LED 1.18；只有门反而从 1.73 涨到 3.45）。
# 这条不是漏改，是 D67 明知故犯的那一半：构件换色归下一条决定，不在这次换皮里。
EXTRA_SHIPPED = ("d",)

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
    # D56 两块无字告示牌。占格必须等于 SIGN_SIZE（16 对齐、整格倍数），选型图与图集同源。
    "sign_card":      (0, 160, 16, 16),
    "sign_card_arrow": (16, 160, 32, 16),
}
DECOR_SIZE = (256, 256)

# 房间里的装饰摆放：(名字, x, y, 重复次数[, 轴向])。坐标全是 16 的倍数，可以直接抄进 TileMapLayer。
# 轴向缺省沿用老规矩（只有横着铺的那条走 h），新增的苔带要横着连成一整条，所以带上第五格。
DECOR_LAYOUT = [
    ("pipe_h", 32, 112, 9),        # 9 x 64 = 576，正好从左墙铺到右墙
    ("pipe_v", 560, 128, 3),       # 3 x 64 = 192，接到地面
    ("light", 80, CEIL_H, 1),
    ("light", 352, CEIL_H, 1),
    ("window", 176, 32, 1),
    ("monitor", 432, 64, 1),
    ("vent", 96, 128, 1),
    ("led_panel", 96, 176, 1),
    ("cabinet", 240, 272, 1),
    ("cabinet_small", 496, 288, 1),
]
# 那两块斜条在 g 里是**钉在墙上的警示牌**（离地 33 px 是故意的）；换成树丛词汇以后它是
# 一丛从地里长出来的荆棘，同一句话只能落到地面上。所以按套分列，而不是硬凑一张通用表。
DECOR_LAYOUT_LAB = [
    ("hazard", 304, 272, 1),
    ("hazard", 448, 272, 1),
]
DECOR_LAYOUT_GROVE = [
    ("hazard", 304, 304, 1),
    ("hazard", 448, 304, 1),
    ("moss_edge", 32, 304, 21, "h"),      # 整条地面踏口长满苔（32..367，坑沿前收手）
    ("moss_edge", 432, 304, 11, "h"),     # 坑右侧那一截
    ("moss_edge", 176, 208, 6, "h"),      # 下平台台面
    ("moss_edge", 320, 128, 6, "h"),      # 上平台台面
    ("leaf_cluster", 144, 304, 1),
    ("leaf_cluster", 512, 304, 1),
    ("mushroom", 208, 304, 1),
    ("flower", 240, 304, 1),
    ("bones", 464, 304, 1),
    ("crate_wood", 48, 288, 1),
    ("barrel", 88, 288, 1),
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
    # PIL 自带的位图默认字体没有 CJK 字形，中文标注会整排糊成方块。
    for path in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
                 "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
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


# ---------------------------------------------------------- 无字告示牌（D56）

#: kind -> 这块牌占的格数（世界像素）。DECOR 里那两个矩形必须与之一致。
SIGN_SIZE = {"card": (16, 16), "arrow": (32, 16)}


def sign_plate(d, p, x, y, kind):
    """一块夜光标牌：暗钢体 + 一圈亮边 + 近黑的屏 + 屏上那个图形。返回 (screen, glyph) 两块闭区间。
    **画法只这一份** —— 装饰图集与选型图 `tools/gen_sign_preview.py` 吃的是同一个函数，
    出货的皮与定案时看见的那张皮逐字节相同（D25/D26 那条老坑：预览与落盘两套画法必然走偏）。

    屏为什么要近黑、边为什么要亮：夜光风格（g）里牌体 `deep` 对墙只有 1.11 —— 整块钢在暗墙上是
    隐形的，能把牌从墙里拎出来的只有那圈 `lip`（选型图 A4/A5 行实测，与 D55 那只座子 cr=1.04 同源）。
    所以这两块牌进 DECOR_NO_ROUND：soft 那圈贴纸暗框画在格子边界上，正好盖掉唯一可见的亮边。

    kind="card"  实心琥珀卡（16x16 一格）= 「这扇门要的是这个」：门前就地说明。
    kind="arrow" 琥珀卡 + 亮白右箭头（32x16 两格）= 「往那边走，那里有一张」：走廊指路。
    方向与物件**分色**是定案要点：琥珀自 D29 起专指可拾取，白只说「往这边走」—— 于是白箭头
    不会被读成第二只卡，卡也不会被读成那颗 LED。TileMapLayer 不能逐格翻转，要左向就再出一格。

    那只卡的颜色读 `p["pickup"]`（缺省回落到 `accent2`），**不直接读 accent2**（D70）：
    「这块牌指的就是那张卡」全靠两色相同，而 `key_card.png` 是照落盘那套的 accent2 烤的，
    从此不随新配色漂移。d 的 accent2 是粉 —— 跟着本套走，牌就在指一个场上根本不存在的粉卡。
    """
    w, h = SIGN_SIZE[kind]
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=p["deep"])
    d.rectangle([x, y, x + w - 1, y + h - 1], outline=p["lip"])
    d.rectangle([x, y, x + w - 1, y], fill=lighter(p["metal"], 0.20))
    d.rectangle([x, y + h - 1, x + w - 1, y + h - 1], fill=darker(p["metal"], 0.45))
    sx0, sy0, sx1, sy1 = x + 2, y + 3, x + w - 3, y + h - 3
    d.rectangle([sx0, sy0, sx1, sy1], fill=p["screen"])
    d.rectangle([sx0, sy0, sx1, sy1], outline=darker(p["lip"], 0.62))
    a = p.get("pickup", p["accent2"])
    if kind == "card":                                  # 落盘那只 14x10 的剪影压扁进屏里
        cw, ch = 10, 7
        cx = sx0 + ((sx1 - sx0 + 1) - cw) // 2
        cy = sy0 + ((sy1 - sy0 + 1) - ch) // 2
    else:                                               # 卡靠左、箭头靠右：一句话的两个半
        cx, cy = sx0 + 1, sy0 + ((sy1 - sy0 + 1) - 7) // 2
    d.rectangle([cx, cy, cx + 9, cy + 6], fill=a)
    d.rectangle([cx, cy, cx + 9, cy], fill=lighter(a, 0.44))
    d.rectangle([cx, cy + 4, cx + 9, cy + 5], fill=darker(a, 0.52))
    d.rectangle([cx + 1, cy + 1, cx + 2, cy + 2], fill=p["accent"])
    if kind == "card":
        glyph = (cx, cy, cx + 9, cy + 6)
    else:
        ax, ymid = sx1 - 7, (sy0 + sy1) // 2
        for bx, lo, hi in ((ax, -1, 1), (ax + 1, -1, 1), (ax + 2, -1, 1), (ax + 3, -1, 1),
                           (ax + 4, -3, 3), (ax + 5, -2, 2), (ax + 6, -1, 1)):
            d.rectangle([bx, ymid + lo, bx, ymid + hi], fill=p["lip"])
        glyph = (cx, min(cy, ymid - 3), cx + 9, max(cy + 6, ymid + 3))
    return (sx0, sy0, sx1, sy1), glyph


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
    "sign_card": lambda d, p, x, y: sign_plate(d, p, x, y, "card"),
    "sign_card_arrow": lambda d, p, x, y: sign_plate(d, p, x, y, "arrow"),
}

# ============================================================ 树丛词汇表（D70）
#
# 为什么另开一张表、而不是改上面那批 painters：两套共用同一张 DECOR 矩形表，而 g 是落盘的那一套 ——
# 改 `decor_pipe_h` 的画法等于把所有已摆好的关的墙皮换掉，那正是 D67 算过、明确没花的那笔钱。
# 所以这里换的是**词汇**，不是几何：条目名与占格一格不动，旧关的 Decor 层照样整层复制过来，
# 只是复制过去之后墙上那根管子长成了根。
#
# 配色只用这套在册的那 12 个键，一个新色都不加：
#   木/石 = metal，叶与苔 = grout + deep + surface，洞与缝 = screen，亮面 = lip / lip_shade，
#   轮廓 = edge，花与菌盖 = accent2；`pickup` 那块琥珀专指可拾取（D29 起的硬语义），装饰不许借。
#
# 亮底有一条与暗底相反的物理事实，整套画法都是围着它排的：d 里 metal 对墙只有 1.66、glass 只有
# 1.03 —— **填充色在这套里几乎不承载信息，承载信息的是轮廓（edge 对墙 10.52）**。于是凡不填满
# 整格的（苔、叶、菌、花、骨堆、荆棘、墙缝、地衣、吊灯）一律进 DECOR_NO_ROUND_GROVE，绕开那圈
# 沿格子边界画的矩形描边，改由画法自己把轮廓描在剪影上。会平铺的那几件（横根、垂藤、苔带）
# 的轮廓必须周期闭合，否则接缝处会啃出豁口 —— 与旧那套「管子一段段断开」是同一条坑。

MOSS_W = (1, 0, 0, 1, 2, 3, 3, 2)      # 逐列苔顶抖动，周期 8 | 16、32、64
ROOT_W = (0, 0, 1, 1, 2, 2, 1, 0, -1, -1, 0, 0, 1, 1, 0, 0)   # 横根半厚抖动，周期 16 | 64
VINE_W = (0, 0, 1, 1, 0, -1, -1, 0)    # 垂藤左右摆，周期 8 | 96


def _moss_top(base, i):
    return base + MOSS_W[i % len(MOSS_W)]


def _ellipse(d, cx, cy, rx, ry, fill):
    """像素椭圆：逐列按半轴求高。rx/ry 是半径，画出来宽 2rx+1、高 2ry+1。"""
    for k in range(-rx, rx + 1):
        t = 1.0 - (k / float(rx)) ** 2 if rx else 1.0
        hh = int(round(ry * math.sqrt(max(t, 0.0))))
        d.rectangle([cx + k, cy - hh, cx + k, cy + hh], fill=fill)


def _leaf(d, p, cx, cy, rx, ry):
    """一片叶：描边一圈 + 中间一道脉。亮底上只有 edge 说得出形状，所以每片叶自带轮廓。"""
    _ellipse(d, cx, cy, rx + 1, ry + 1, p["edge"])
    _ellipse(d, cx, cy, rx, ry, p["grout"])
    d.line([cx - rx + 1, cy, cx + rx - 1, cy], fill=p["deep"])
    d.rectangle([cx - rx + 1, cy - ry, cx - rx + 3, cy - ry], fill=p["lip_shade"])


def grove_root_h(d, p, x, y):
    """横卧的根（替 pipe_h）。半厚按周期 16 抖，节瘤每 32 一格 —— 与旧法兰同节奏，
    所以这一条照样能横向无缝接下去（关卡里它是 9 连铺到整面墙）。"""
    wood = p["metal"]
    lite, dark = lighter(wood, 0.45), darker(wood, 0.30)
    prof = [2 + ROOT_W[i % 16] for i in range(64)]
    for k in (0, 32):
        for j in (-1, 0, 1):
            prof[(k + j) % 64] += 1
    for i in range(64):
        top, bot = 8 - prof[i], 8 + prof[i]
        d.rectangle([x + i, y + top, x + i, y + bot], fill=wood)
        d.rectangle([x + i, y + top, x + i, y + top], fill=lite)
        d.rectangle([x + i, y + bot, x + i, y + bot], fill=dark)
    for k in (0, 32):                                  # 节瘤：两道暗环 + 一丁点疤
        d.rectangle([x + (k - 1) % 64, y + 5, x + (k - 1) % 64, y + 11], fill=darker(wood, 0.16))
        d.rectangle([x + (k + 1) % 64, y + 5, x + (k + 1) % 64, y + 11], fill=darker(wood, 0.16))
        d.rectangle([x + k, y + 7, x + k, y + 9], fill=darker(wood, 0.5))
    for i in (5, 6, 21, 37, 38, 53):                   # 上沿几簇苔
        d.rectangle([x + i, y + 7 - prof[i], x + i, y + 8 - prof[i]], fill=p["grout"])
    for i in (6, 38):
        d.rectangle([x + i, y + 7 - prof[i], x + i, y + 7 - prof[i]], fill=p["surface"])


def grove_vine_v(d, p, x, y):
    """垂藤（替 pipe_v）。三簇叶在 16 / 48 / 80 行，左右交替；第 0 与第 95 行留纯茎 ——
    关卡里它是 3 段竖着接的，接缝那一行必须没有叶子才接得上。"""
    stem, lite, dark = p["metal"], lighter(p["metal"], 0.4), darker(p["metal"], 0.3)
    for r in range(96):
        off = VINE_W[(r // 2) % 8]
        d.rectangle([x + 6 + off, y + r, x + 9 + off, y + r], fill=stem)
        d.rectangle([x + 6 + off, y + r, x + 6 + off, y + r], fill=lite)
        d.rectangle([x + 9 + off, y + r, x + 9 + off, y + r], fill=dark)
    for cy, side in ((16, 1), (48, -1), (80, 1)):
        for k, hh in enumerate((1, 2, 3, 3, 2, 1)):
            col = x + 8 + side * (2 + k)
            d.rectangle([col, y + cy - hh, col, y + cy + hh], fill=p["grout"])
            d.rectangle([col, y + cy - hh, col, y + cy - hh], fill=p["surface"])
        tip = x + 8 + side * 7
        d.rectangle([tip, y + cy, tip, y + cy], fill=p["deep"])
        d.rectangle([x + 8 - side, y + cy - 4, x + 8 - side, y + cy - 3], fill=p["edge"])
    d.rectangle([x + 11, y + 45, x + 12, y + 46], fill=p["accent2"])   # 一嘟噜果


def grove_grotto(d, p, x, y, w, h):
    """石拱洞口（替 window）。旧的那块 96x64 里最要命的是一整片 glass —— 对墙 1.03，
    等于在墙上开了个「看不见的洞」。这里洞填 screen（11.56，全套最读得出来的填充），
    里面三丛远叶用 grout/deep：说的是「墙后面还有一片活的」，与窗那句一样。"""
    frame = p["metal"]
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=frame)
    d.rectangle([x, y, x + w - 1, y + 1], fill=lighter(frame, 0.42))
    d.rectangle([x, y + h - 2, x + w - 1, y + h - 1], fill=darker(frame, 0.34))
    ix0, ix1, iy0, iy1 = x + 6, x + w - 7, y + 4, y + h - 5
    for cx in range(ix0, ix1 + 1):
        u = (cx - ix0) / float(ix1 - ix0)
        top = iy0 + int(round(5.0 * (1.0 - math.sin(math.pi * u))))
        d.rectangle([cx, top, cx, iy1], fill=p["screen"])
        d.rectangle([cx, top, cx, top], fill=darker(frame, 0.55))
    d.rectangle([ix0 + 2, iy1 - 10, ix1 - 2, iy1 - 8], fill=mix(p["screen"], p["bg3"], 0.22))
    for bx, bw, bh in ((ix0 + 5, 13, 13), (ix0 + 28, 21, 19), (ix1 - 18, 11, 11)):
        for k in range(bw):
            hh = int(round((bh // 2) * math.sin(math.pi * (k + 0.5) / bw)))
            d.rectangle([bx + k, iy1 - hh, bx + k, iy1], fill=p["deep"])
            d.rectangle([bx + k, iy1 - hh, bx + k, iy1 - hh], fill=p["grout"])
        d.rectangle([bx + bw // 2 - 1, iy1 - bh // 2, bx + bw // 2, iy1 - bh // 2 + 1],
                    fill=p["surface"])
    d.rectangle([ix0 + 20, iy0 + 9, ix0 + 20, iy0 + 9], fill=p["accent"])
    d.rectangle([ix1 - 12, iy0 + 15, ix1 - 12, iy0 + 15], fill=p["accent"])


def grove_lantern_row(d, p, x, y):
    """吊下来的光盖菌列（替 light）。暗底那套靠四行真 alpha 光晕说「这一带是亮的」，
    亮底上光晕无处可叠（lip 对白墙只有 1.22），所以那句改由**菌盖自己的粉 + 一圈描边 +
    盖下三行影**来说：亮不亮不再由亮度报，由形状报。导轨那两行留着，它说的是「挂在顶上」。"""
    cap, capdark = p["accent2"], darker(p["accent2"], 0.42)
    d.rectangle([x, y, x + 95, y + 1], fill=p["metal"])
    d.rectangle([x, y + 1, x + 95, y + 1], fill=darker(p["metal"], 0.3))
    for cx in (10, 34, 58, 82):
        d.rectangle([x + cx, y + 2, x + cx, y + 3], fill=p["edge"])
        for k, w in enumerate((3, 5, 5, 4)):
            d.rectangle([x + cx - w, y + 4 + k, x + cx + w, y + 4 + k],
                        fill=cap if k < 2 else capdark)
        d.rectangle([x + cx - 3, y + 4, x + cx + 3, y + 4], fill=p["edge"])
        d.rectangle([x + cx - 5, y + 5, x + cx - 5, y + 7], fill=p["edge"])
        d.rectangle([x + cx + 5, y + 5, x + cx + 5, y + 7], fill=p["edge"])
        d.rectangle([x + cx - 5, y + 7, x + cx + 5, y + 7], fill=p["edge"])
        d.rectangle([x + cx - 2, y + 5, x + cx, y + 5], fill=p["lip"])
        for r0, r1, a in ((8, 9, 44), (10, 11, 26), (12, 13, 13)):
            d.rectangle([x + cx - 4, y + r0, x + cx + 4, y + r1], fill=rgba(p["edge"], a))


def grove_nest_box(d, p, x, y, w, h):
    """墙上的木巢箱（替 monitor）。旧那块的价值是 screen 那一整片近黑（11.56）—— 全套唯一
    靠填充就读得出来的东西，所以新的这块把同样的面积留给洞口，只是从「屏」变成「洞」。"""
    wood = p["metal"]
    d.rectangle([x, y + 4, x + w - 1, y + h - 1], fill=wood)
    for r in (10, 15, 20, 25):
        d.rectangle([x + 1, y + r, x + w - 2, y + r], fill=darker(wood, 0.22))
    d.rectangle([x, y + 4, x, y + h - 1], fill=lighter(wood, 0.35))
    d.rectangle([x + w - 1, y + 4, x + w - 1, y + h - 1], fill=darker(wood, 0.3))
    d.rectangle([x, y, x + w - 1, y + 3], fill=p["bg3"])
    d.rectangle([x, y, x + w - 1, y], fill=lighter(p["bg3"], 0.45))
    d.rectangle([x, y + 3, x + w - 1, y + 3], fill=darker(p["bg3"], 0.35))
    hx, hy = x + w // 2, y + 14
    _ellipse(d, hx, hy, 6, 6, p["edge"])
    _ellipse(d, hx, hy, 5, 5, p["screen"])
    d.rectangle([hx - 1, hy + 9, hx + 4, hy + 9], fill=p["edge"])
    for i in range(w):
        top = _moss_top(27, i)
        d.rectangle([x + i, y + top, x + i, y + h - 1], fill=p["grout"])
    for i in range(1, w, 4):
        d.rectangle([x + i, y + 27, x + i, y + 27], fill=p["surface"])


def grove_lichen(d, p, x, y, w, h):
    """贴壁地衣（替 led_panel）。它顶的是旧那句「这面墙不是平的」。
    第一版画成一整颗圆斑，实拍读出来是**一只浮在墙前的气球** —— 圆得没有第二块就假。
    所以这里画的是四块大小不一、彼此压住的叶状斑：轮廓先整圈铺 edge，再往里填色，
    接缝处自然长出深浅，看着才像长在墙上的东西。"""
    lobes = ((9, 15, 7, 5), (19, 11, 6, 4), (13, 22, 5, 4), (23, 20, 4, 3))
    for cx, cy, rx, ry in lobes:
        _ellipse(d, x + cx, y + cy, rx + 1, ry + 1, p["edge"])
    for cx, cy, rx, ry in lobes:
        _ellipse(d, x + cx, y + cy, rx, ry, p["grout"])
    for cx, cy, rx, ry in lobes:                       # 下半压暗：斑是贴着墙的，不是悬着的
        _ellipse(d, x + cx, y + cy + 1, max(rx - 2, 1), max(ry - 2, 1), p["deep"])
    for cx, cy, rx, ry in lobes:
        _ellipse(d, x + cx - 2, y + cy - 2, max(rx - 4, 1), max(ry - 3, 1), p["surface"])
    for dx, dy in ((7, 12), (17, 9), (24, 18), (12, 24)):
        d.rectangle([x + dx, y + dy, x + dx, y + dy], fill=p["lip_shade"])


def grove_crevice(d, p, x, y, w, h):
    """墙缝（替 vent）。第一版逐列抖 ±4 直接糊成一条黑泥 —— 缝要读成缝，靠的是
    **上下两道整齐的唇**，抖只许抖一格。缝口三根须垂出来：有东西从缝里长出来了，
    这句比格栅值钱。"""
    for i in range(w):
        top = 6 + (1 if i % 8 in (3, 4) else 0)
        d.rectangle([x + i, y + top - 1, x + i, y + top + 4], fill=p["edge"])
        d.rectangle([x + i, y + top, x + i, y + top + 2], fill=p["screen"])
        d.rectangle([x + i, y + top + 5, x + i, y + top + 6], fill=lighter(p["metal"], 0.35))
        d.rectangle([x + i, y + top + 6, x + i, y + top + 6], fill=darker(p["metal"], 0.25))
    for i, ln in ((7, 3), (16, 2), (25, 3)):
        d.rectangle([x + i, y + 11, x + i, y + 10 + ln], fill=p["deep"])
        d.rectangle([x + i + 1, y + 11, x + i + 1, y + 11], fill=p["grout"])


def grove_stump(d, p, x, y, w, h):
    """树桩（替 cabinet）。这块继续吃那圈矩形描边 + 擦角：擦完就是一截圆角木桩，占格与旧柜子
    同为 64x48，所以「落地体块管比例」那句功能一字没改。第一版与木箱撞脸（都是方块加几道线），
    所以这版把身份全押在**顶面那圈年轮**上：上 10 行是锯开的截面，下面才是竖树皮，
    基部只让苔从左下角爬上来 —— 一整条绿边会把桩子读成一只盆。"""
    wood = p["metal"]
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=wood)
    d.rectangle([x + 1, y + 1, x + w - 2, y + 12], fill=lighter(wood, 0.5))
    for r, inset in ((3, 6), (6, 13), (9, 21), (12, 29)):
        d.rectangle([x + inset, y + r, x + w - 1 - inset, y + r], fill=darker(wood, 0.44))
    d.rectangle([x, y + 13, x + w - 1, y + 13], fill=darker(wood, 0.6))
    for bx, hi, lo in ((6, 18, 40), (15, 16, 36), (25, 21, 40), (34, 15, 33), (44, 19, 38),
                       (53, 17, 40)):
        d.rectangle([x + bx, y + hi, x + bx, y + lo], fill=darker(wood, 0.3))
        d.rectangle([x + bx + 1, y + hi + 1, x + bx + 1, y + lo - 1], fill=lighter(wood, 0.28))
    for i in range(w // 2 + 6):
        top = _moss_top(40, i)
        d.rectangle([x + i, y + top, x + i, y + h - 1], fill=p["grout"])
        d.rectangle([x + i, y + top, x + i, y + top], fill=p["surface"])
    for r, tw in ((16, 7), (26, 5)):                   # 侧面两朵侧耳：桩子还活着过
        d.rectangle([x + w - tw, y + r, x + w - 1, y + r + 2], fill=p["lip_shade"])
        d.rectangle([x + w - tw, y + r - 1, x + w - 1, y + r - 1], fill=p["edge"])
        d.rectangle([x + w - tw, y + r + 2, x + w - 1, y + r + 2], fill=darker(p["lip_shade"], 0.45))
        d.rectangle([x + w - tw, y + r, x + w - tw, y + r + 2], fill=p["edge"])


def grove_rock(d, p, x, y, w, h):
    """岩石（替 cabinet_small）。与树桩分两件事：石头用 bg3（墙暗一档的灰紫）+ 棱面，
    木头用 metal + 竖纹 —— 两块放同一张图里不会读成同一件东西。"""
    body = p["bg3"]
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=body)
    for x0, y0, x1, y1 in ((2, 2, 17, 7), (21, 3, 44, 6), (4, 8, 25, 12)):
        d.rectangle([x + x0, y + y0, x + x1, y + y1], fill=lighter(body, 0.42))
    for x0, y0, x1, y1 in ((6, 21, 41, 24), (2, 25, 45, 26)):
        d.rectangle([x + x0, y + y0, x + x1, y + y1], fill=darker(body, 0.34))
    d.line([x + 14, y + 6, x + 22, y + 14, x + 18, y + 22], fill=darker(body, 0.55))
    for i in (30, 34, 38):
        d.rectangle([x + i, y + 27, x + i + 2, y + 28], fill=p["grout"])


def grove_thorn(d, p, x, y, w, h):
    """荆棘带（替 hazard）。旧那块是 45 度斜条 —— 那是工业语言的「危险」，在森林里没人这么说话。
    新的这块把危险交给**剪影**：一丛 grout 灌木上头竖着 edge 的实心尖，两粒酸浆果做饵。
    用 edge 而不是用色：d 里 accent2 对墙只有 1.98，靠颜色喊危险在这套里喊不动。
    第一版六根尖连成一整条黑梳子，读出来是「地上有一道阴影」—— 尖与尖之间必须留缝、高矮要参差。"""
    d.rectangle([x, y + 11, x + w - 1, y + 15], fill=p["deep"])
    d.rectangle([x, y + 11, x + w - 1, y + 11], fill=p["grout"])
    d.rectangle([x, y + 15, x + w - 1, y + 15], fill=p["edge"])
    for bx, hh in ((4, 8), (12, 12), (20, 7), (27, 10)):
        for k in range(hh):
            wid = int(round((k + 1) * 1.6 / hh))
            d.rectangle([x + bx - wid, y + 11 - k, x + bx + wid, y + 11 - k], fill=p["edge"])
    for bx, by in ((8, 9), (16, 10), (24, 8)):
        d.rectangle([x + bx, y + by, x + bx + 1, y + by + 1], fill=p["accent2"])


def grove_moss_tuft(d, p, x, y):
    """苔带（新增 16x16）。要紧的是它画在**格子的下半截**：Decor 在地形后面，
    「草长在台面上」= 刷在台面上方那一格，画在那格的底部。整格填满就成了一块悬空的砖。"""
    for i in range(16):
        top = _moss_top(9, i)
        d.rectangle([x + i, y + top, x + i, y + 15], fill=p["grout"])
        d.rectangle([x + i, y + top, x + i, y + top], fill=p["surface"])
    for i in (2, 6, 11, 14):
        d.rectangle([x + i, y + _moss_top(9, i) - 2, x + i, y + _moss_top(9, i) - 1],
                    fill=p["deep"])
    for i in range(0, 16, 4):
        d.rectangle([x + i, y + 14, x + i + 1, y + 15], fill=p["deep"])


def grove_leaf_cluster(d, p, x, y):
    """叶簇（新增 32x16）：三片叶压在一起，用在台端与洞口两侧。"""
    _leaf(d, p, x + 7, y + 10, 5, 2)
    _leaf(d, p, x + 16, y + 7, 6, 3)
    _leaf(d, p, x + 25, y + 11, 4, 2)


def grove_mushroom(d, p, x, y):
    """菌（新增 16x16）。盖用 accent2 粉，柄用 lip_shade —— 两个理由：粉在这套里对墙 1.98
    是「有颜色但不出手」的那一档，正好给纯摆件；而**琥珀是 pickup 的专属色，一颗菌都不能沾**
    （D29 起玩家看见琥珀就伸手）。"""
    for cx, hh, rw in ((4, 8, 4), (10, 6, 3), (13, 4, 2)):
        d.rectangle([x + cx - 1, y + 15 - hh, x + cx + 1, y + 15], fill=p["lip_shade"])
        d.rectangle([x + cx + 1, y + 15 - hh, x + cx + 1, y + 15], fill=darker(p["lip_shade"], 0.4))
        top = y + 15 - hh - 2
        for k, w in enumerate((rw - 1, rw, rw, rw - 2)):
            d.rectangle([x + cx - w, top + k, x + cx + w, top + k],
                        fill=p["accent2"] if k < 2 else darker(p["accent2"], 0.45))
        d.rectangle([x + cx - rw, top, x + cx + rw, top], fill=p["edge"])
        d.rectangle([x + cx - rw, top + 3, x + cx - rw + 1, top + 3], fill=p["edge"])
        d.rectangle([x + cx + rw - 1, top + 3, x + cx + rw, top + 3], fill=p["edge"])
        d.rectangle([x + cx - 1, top, x + cx + 1, top], fill=lighter(p["accent2"], 0.45))


def grove_flower(d, p, x, y):
    """花（新增 16x16）：「这儿能落脚」的软标记，与荆棘带成对摆。"""
    d.rectangle([x + 7, y + 8, x + 8, y + 15], fill=p["deep"])
    d.rectangle([x + 4, y + 11, x + 6, y + 12], fill=p["grout"])
    d.rectangle([x + 9, y + 13, x + 11, y + 14], fill=p["grout"])
    for dx, dy in ((0, -2), (0, 2), (-2, 0), (2, 0), (0, 0)):
        _ellipse(d, x + 8 + dx, y + 6 + dy, 2, 2, p["edge"])
    for dx, dy in ((0, -2), (0, 2), (-2, 0), (2, 0)):
        _ellipse(d, x + 8 + dx, y + 6 + dy, 1, 1, p["accent2"])
    _ellipse(d, x + 8, y + 6, 1, 1, p["lip"])


def grove_crate(d, p, x, y, w, h):
    """木箱（新增 32x32）：故意留一点人造痕迹 —— 纯森林会把「这里曾经有人」那句一起抹掉。"""
    wood = p["metal"]
    d.rectangle([x, y, x + w - 1, y + h - 1], fill=wood)
    d.rectangle([x + 1, y + 1, x + w - 2, y + 4], fill=lighter(wood, 0.42))
    d.rectangle([x + 1, y + h - 4, x + w - 2, y + h - 1], fill=darker(wood, 0.34))
    for r in (10, 21):
        d.rectangle([x + 1, y + r, x + w - 2, y + r + 1], fill=darker(wood, 0.28))
    d.line([x + 2, y + 6, x + w - 3, y + h - 5], fill=darker(wood, 0.42))
    d.line([x + w - 3, y + 6, x + 2, y + h - 5], fill=darker(wood, 0.42))
    for cx, cy in ((3, 7), (w - 5, 7), (3, h - 6), (w - 5, h - 6)):
        d.rectangle([x + cx, y + cy, x + cx + 1, y + cy + 1], fill=p["edge"])


def grove_barrel(d, p, x, y, w, h):
    """木桶（新增 16x32）：与木箱同族，肚子鼓出来那一档就是它的全部身份。"""
    wood = p["metal"]
    for r in range(h):
        bulge = 1 if 6 <= r < h - 6 else 0
        d.rectangle([x + 1 + (1 - bulge), y + r, x + w - 2 - (1 - bulge), y + r], fill=wood)
        d.rectangle([x + 1 + (1 - bulge), y + r, x + 1 + (1 - bulge), y + r],
                    fill=lighter(wood, 0.35))
        d.rectangle([x + w - 2 - (1 - bulge), y + r, x + w - 2 - (1 - bulge), y + r],
                    fill=darker(wood, 0.3))
    for r0, r1 in ((4, 6), (h - 8, h - 6)):
        d.rectangle([x + 1, y + r0, x + w - 2, y + r1], fill=darker(p["bg3"], 0.2))
    d.rectangle([x + 3, y + 1, x + w - 4, y + 2], fill=lighter(wood, 0.5))


def grove_bones(d, p, x, y, w, h):
    """骨堆（新增 32x16）：荆棘之外的第二种「前面不对劲」。第一版摆了三根骨头，
    在 2 倍取景下糊成一团黑点 —— 这一档尺寸上「一具」比「一堆」读得清楚，所以留一只头骨
    加一根肋，剩下的交给脚边的苔。用 lip 白 + edge 描边：亮底上白本身不显眼（1.22），
    轮廓必须自己描 —— 与 D55 那只座子「靠分两截读出来」同一条。"""
    _ellipse(d, x + 9, y + 8, 6, 5, p["edge"])
    _ellipse(d, x + 9, y + 8, 5, 4, p["lip"])
    _ellipse(d, x + 7, y + 7, 1, 1, p["screen"])
    _ellipse(d, x + 11, y + 7, 1, 1, p["screen"])
    d.rectangle([x + 8, y + 11, x + 10, y + 11], fill=p["edge"])
    d.line([x + 19, y + 12, x + 26, y + 6], fill=p["edge"], width=4)
    d.line([x + 19, y + 12, x + 26, y + 6], fill=p["lip"], width=2)
    for kx, ky in ((18, 13), (27, 5)):
        _ellipse(d, x + kx, y + ky, 2, 2, p["edge"])
        _ellipse(d, x + kx, y + ky, 1, 1, p["lip"])
    for i in (14, 15, 21, 29):
        d.rectangle([x + i, y + 14, x + i, y + 15], fill=p["grout"])


PAINTERS_GROVE = dict(PAINTERS)      # 两块告示牌继续吃同一份画法：牌面说的是语义，不是风格
PAINTERS_GROVE.update({
    "pipe_h": grove_root_h,
    "pipe_v": grove_vine_v,
    "window": lambda d, p, x, y: grove_grotto(d, p, x, y, 96, 64),
    "light": grove_lantern_row,
    "monitor": lambda d, p, x, y: grove_nest_box(d, p, x, y, 48, 32),
    "led_panel": lambda d, p, x, y: grove_lichen(d, p, x, y, 32, 32),
    "vent": lambda d, p, x, y: grove_crevice(d, p, x, y, 32, 16),
    "cabinet": lambda d, p, x, y: grove_stump(d, p, x, y, 64, 48),
    "cabinet_small": lambda d, p, x, y: grove_rock(d, p, x, y, 48, 32),
    "hazard": lambda d, p, x, y: grove_thorn(d, p, x, y, 32, 16),
    "moss_edge": grove_moss_tuft,
    "leaf_cluster": grove_leaf_cluster,
    "mushroom": grove_mushroom,
    "flower": grove_flower,
    "crate_wood": lambda d, p, x, y: grove_crate(d, p, x, y, 32, 32),
    "barrel": lambda d, p, x, y: grove_barrel(d, p, x, y, 16, 32),
    "bones": lambda d, p, x, y: grove_bones(d, p, x, y, 32, 16),
})

# 树丛套多出来的那七件，一律摆在图集 x>=224 的空列上 —— 与 g 那 14 件共用的矩形一格不挪，
# 所以「旧关 Decor 层整层复制过来」这条仍然成立，新关只是多七块可刷。
# 空列从 y=16 起，不是从 y=0：`vent` 是 (208,0,32,16)，它的右半正好压在 x=224 那一列的第一行上
# —— 摆重叠了不报错，只是后画的那件把前一件盖掉，图集里看是一块、清单里却是两块（D70 当场踩到）。
# 所以 check_decor_rects() 现在逐套核一遍重叠，见 main()。
DECOR_GROVE_EXTRA = {
    "moss_edge":     (224, 16, 16, 16),
    "flower":        (240, 16, 16, 16),
    "leaf_cluster":  (224, 32, 32, 16),
    "mushroom":      (224, 48, 16, 16),
    "bones":         (224, 64, 32, 16),
    "crate_wood":    (224, 96, 32, 32),
    "barrel":        (224, 128, 16, 32),
}

# 换成树丛词汇之后不再填满整格的条目：那圈沿格子边界画的矩形描边会把一块斑框成一块砖。
DECOR_NO_ROUND_GROVE = {"light", "hazard", "led_panel", "vent",
                        "moss_edge", "leaf_cluster", "mushroom", "flower", "bones"}


def is_grove(p):
    return p.get("decor_set", "lab") == "grove"


def decor_items(p):
    """这一套实际会画进图集的条目。**清单必须从这儿来**：把 grove 那七件写进 g 的清单，
    build_tileset 就会替 g 建七块指向空格的瓦片，而 g 的图上那七块根本没画。"""
    return dict(DECOR, **DECOR_GROVE_EXTRA) if is_grove(p) else DECOR


def painters_for(p):
    return PAINTERS_GROVE if is_grove(p) else PAINTERS


def no_round_for(p):
    return DECOR_NO_ROUND | DECOR_NO_ROUND_GROVE if is_grove(p) else DECOR_NO_ROUND


# 会重复平铺的必须跳过：擦角等于在每一格接缝处啃掉一个豁口，管子会一段段断开。
# 两块告示牌也在这张名单里，理由相反但同一条规矩管得住：soft 那圈暗框是沿着格子边界画的，
# 而牌体对墙只有 1.11 —— 唯一能把它从暗墙里拎出来的是自己那圈亮边，暗框正好盖在亮边上。
DECOR_NO_ROUND = {"wall_fill", "shade", "pipe_h", "pipe_v", "sign_card", "sign_card_arrow"}
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
    items = decor_items(p)
    paint_body(d, 0, 0, p["bg"], p["bg2"], p["motif_bg"])       # wall_fill
    d.rectangle([16, 0, 31, 15], fill=p.get("pit_shade", SHADE))  # shade
    for name, fn in painters_for(p).items():
        rx, ry, _, _ = items[name]
        fn(d, p, rx, ry)
    for kind, name in (("card", "sign_card"), ("arrow", "sign_card_arrow")):
        if DECOR[name][2:] != SIGN_SIZE[kind]:
            # 画法只画自己那一档的尺寸：DECOR 写宽了不会报错，只会让牌渗进邻格、
            # 与邻格的透明角叠在一起，图集里看不出来、刷进关卡才现形。
            raise SystemExit("DECOR[%s] 与 SIGN_SIZE[%s] 不一致：%s vs %s"
                             % (name, kind, DECOR[name][2:], SIGN_SIZE[kind]))
    if p.get("soft"):
        # 先补描边再擦角：装饰都是整格矩形，描边正好落在格内不会渗到邻格。
        # 没有这圈边，米色墙配米色柜子就糊成一片（E 的 metal/bg 对比只有 1.3）。
        skip = no_round_for(p)
        for name, (rx, ry, rw, rh) in items.items():
            if name in skip:
                continue
            d.rectangle([rx, ry, rx + rw - 1, ry + rh - 1], outline=p["edge"])
            round_corners(img, rx, ry, rx + rw - 1, ry + rh - 1, 3 if rh >= 32 else 2)
    return img


def decor_tile(atlas, name, p):
    rx, ry, rw, rh = decor_items(p)[name]
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

    wall_fill = decor_tile(decor, "wall_fill", p)      # z = -30
    for cy in range(H_WORLD // TILE):
        for cx in range(W_WORLD // TILE):
            img.paste(wall_fill, (cx * TILE, cy * TILE))

    shade = decor_tile(decor, "shade", p)              # z = -20，坑道
    for cy in range(FLOOR_Y // TILE, (FLOOR_Y + PIT_DEPTH) // TILE):
        for cx in range(PIT_X // TILE, (PIT_X + PIT_W) // TILE):
            img.paste(shade, (cx * TILE, cy * TILE), shade)

    items = decor_items(p)
    layout = DECOR_LAYOUT + (DECOR_LAYOUT_GROVE if is_grove(p) else DECOR_LAYOUT_LAB)
    for entry in layout:                               # z = -20，摆件
        name, x, y, rep = entry[:4]
        axis = entry[4] if len(entry) > 4 else ("h" if name == "pipe_h" else "v")
        t = decor_tile(decor, name, p)
        step = items[name][2] if axis == "h" else items[name][3]
        for i in range(rep):
            dx = x + i * step if axis == "h" else x
            dy = y if axis == "h" else y + i * step
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
    wall_fill = decor_tile(build_decor_atlas(p), "wall_fill", p)
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


def atlas_sheet(p, terrain_file="tilesheet_terrain.png", decor_file="tilesheet_decor.png"):
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
    d.text((ox, oy - 18), "%s  (x8)" % terrain_file, fill=(24, 28, 34), font=fs)
    canvas.paste(terrain.resize((tw, th), Image.NEAREST), (ox, oy))
    for mask in range(16):                              # 每格标出掩码：U R D L，有邻居的记实心
        cx = ox + (mask % 4) * TILE * ts
        cy = oy + (mask // 4) * TILE * ts
        d.rectangle([cx, cy, cx + TILE * ts - 1, cy + TILE * ts - 1], outline=(240, 70, 70))
        tag = "".join(ch if mask & bit else "." for ch, bit in (("U", UP), ("R", RIGHT), ("D", DOWN), ("L", LEFT)))
        d.text((cx + 3, cy + 3), "%2d %s" % (mask, tag), fill=(240, 70, 70), font=fs)

    dx = ox + tw + gap
    d.text((dx, oy - 18), "%s  (x2, over checkerboard = real alpha)" % decor_file,
           fill=(24, 28, 34), font=fs)
    check = Image.new("RGB", (dw, dh))
    dc = ImageDraw.Draw(check)
    for cy in range(0, dh, 8):
        for cx in range(0, dw, 8):
            dc.rectangle([cx, cy, cx + 7, cy + 7], fill=(206, 211, 218) if (cx + cy) // 8 % 2 else (238, 241, 245))
    check.paste(decor.resize((dw, dh), Image.NEAREST), (0, 0), decor.resize((dw, dh), Image.NEAREST))
    canvas.paste(check, (dx, oy))
    for name, (rx, ry, rw, rh) in decor_items(p).items():
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

def check_decor_rects(style_key):
    """落盘前先核这张图集摆得下：16 对齐、不出界、**两两不重叠**、painters 与条目对得上。
    重叠这一条是 D70 当场踩到的：vent 的右半正好压在新增件打算摆的那一列上，而它不报错 ——
    后画的那件把前一件盖掉，图集里看是一块、清单里是两块，刷进关卡才发现少一块皮。"""
    p = STYLES[style_key]
    items = decor_items(p)
    rects = []
    for name, (rx, ry, rw, rh) in items.items():
        if rx % TILE or ry % TILE or rw % TILE or rh % TILE:
            raise SystemExit("[%s] %s 不是 16 对齐：%s" % (style_key, name, (rx, ry, rw, rh)))
        if rx + rw > DECOR_SIZE[0] or ry + rh > DECOR_SIZE[1]:
            raise SystemExit("[%s] %s 出了图集 %s：%s" % (style_key, name, DECOR_SIZE, (rx, ry, rw, rh)))
        for other, (ox, oy, ow, oh) in rects:
            if rx < ox + ow and ox < rx + rw and ry < oy + oh and oy < ry + rh:
                raise SystemExit("[%s] %s %s 与 %s %s 重叠 —— 后画的那件会盖掉前一件"
                                 % (style_key, name, (rx, ry, rw, rh), other, (ox, oy, ow, oh)))
        rects.append((name, (rx, ry, rw, rh)))
    missing = [n for n in painters_for(p) if n not in items]
    if missing:
        raise SystemExit("[%s] painters 里有 %s，清单里没有 —— 它会画到未登记的格子上"
                         % (style_key, missing))


def write_manifest(out_dir, style, terrain_file, decor_file, manifest_name):
    manifest = {
        "tile": TILE,
        "style": style,
        "surface_language": "sticker" if STYLES[style].get("soft") else "bevel",
        "terrain": {
            "file": terrain_file,
            "size": [64, 64],
            "mask_bits": {"up": UP, "right": RIGHT, "down": DOWN, "left": LEFT},
            "note": "mask bit set = that side has a solid neighbour, so no cap/face is drawn there",
            "tiles": [{"mask": m, "x": (m % 4) * TILE, "y": (m // 4) * TILE} for m in range(16)],
        },
        "decor": {
            "file": decor_file,
            "size": list(DECOR_SIZE),
            # 条目一律从这一套**实际会画出来**的那张表来。写死 DECOR 的话，grove 多出来的
            # 七件在 g 的清单里也会有一行，build_tileset 就替 g 建七块指向空格的瓦片。
            "items": {k: list(v) for k, v in decor_items(STYLES[style]).items()},
        },
        "layout_hint": {
            "wall_fill": "WallFill layer, every empty cell",
            "shade": "Decor layer, pit shaft cells",
        },
    }
    path = os.path.join(out_dir, manifest_name)
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


def sheet_names(key):
    """每一套落盘风格的四个文件名。SHIPPED 占的是**没有后缀**的那一组旧名字 ——
    `lab_tileset.tres` 里的 ext_resource、`level1.tscn`、四条守门全都按它写死，
    改不动也不该改。额外风格（D67 的 d）一律带 `_<key>` 后缀，新关自己指过去。"""
    if key == SHIPPED:
        return "tilesheet_terrain.png", "tilesheet_decor.png", "tiles.json", "preview_tiles.png"
    return ("tilesheet_terrain_%s.png" % key, "tilesheet_decor_%s.png" % key,
            "tiles_%s.json" % key, "preview_tiles_%s.png" % key)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "assets", "tiles")
    os.makedirs(out_dir, exist_ok=True)

    for key in (SHIPPED,) + tuple(EXTRA_SHIPPED):
        p = STYLES[key]
        check_decor_rects(key)
        terrain_file, decor_file, manifest_name, sheet_name = sheet_names(key)
        build_terrain_atlas(p).save(os.path.join(out_dir, terrain_file))
        build_decor_atlas(p).save(os.path.join(out_dir, decor_file))
        print("saved %s / %s  (style=%s)" % (terrain_file, decor_file, key))
        print("saved", write_manifest(out_dir, key, terrain_file, decor_file, manifest_name))
        # 说明图连那条"现有构件的占位色落在新地砖上"的对照条一起出 ——
        # 换风格要糊的是构件，不是地形，这张图就是那一半代价的收据。
        out = os.path.join(out_dir, sheet_name)
        atlas_sheet(p, terrain_file, decor_file).save(out)
        print("saved", out)

    for key in ORDER:
        out = os.path.join(out_dir, "preview_room_%s.png" % key)
        render_room(STYLES[key], root).save(out)
        print("saved", out)

    contrast_report(root)


if __name__ == "__main__":
    main()
