"""D61 能力获取那一拍（5 s）的选型图。**只出评审件，一行游戏代码都不动。**

跑法：py tools/gen_grant_preview.py
  -> assets/player/preview_grant_sheet.png   三档情绪画法 × 16 帧胶片（含举升几何与碰撞盒）
  -> assets/player/preview_grant_burst.png   爆发那一档的三档候选，画在真帧上
  -> assets/player/preview_grant_beams.png   爆发用白色三角**楔形**光柱：六候选 × 三进度（整屏）
  -> assets/player/preview_grant_beams.gif   同上六候选各演一遍爆发那一拍（整屏）
  -> assets/player/preview_grant_timeline.png 光柱换成整段构件：六候选 × 五个断面（帧 1/4/7/9/10）
  -> assets/player/preview_grant_spin.gif     同上六候选各演一遍**整段** 5 s（16 帧）
  -> assets/player/preview_grant_<选定行>.png  选定那一行（CHOSEN）单独一张：转速 / 亮度 /
  -> assets/player/preview_grant_<选定行>.gif  消失方式 / 与青环是否同帧，四问一次裁
  -> assets/player/preview_grant_anim.gif     整段 5 s 播一遍 + 现状 1.05 s 版并排当对照

画法只有一个来源：候选帧表临时塞进 gen_player_frames 的 FRAMES / CLIPS，再走同一个
render()（同一个 draw_slime、同一条底边波浪相位算式）。祭坛与核心用**落盘那几张 PNG**，
CRT 用 gen_freeze_filter_preview.crt()（D46 已验它与实机 shader 对得上，本脚本 report()
每次运行再核一次）。胶片与动图共用同一条 paint_stage() 几何 —— 两处各写一份的话，
图上那点收据就不作数了。

三张图各答一件事：
  胶片答「疑惑 / 震惊 / 开心 在 44 px 的史莱姆上读不读得出来」—— A 用新旋钮（单眼收 + grin）、
  B 用新旋钮的另一笔（两眼不同高 = 斜视）、C 完全不碰新旋钮（只用现成参数能走多远）。
  爆发图答「闪光这一档要哪一份」—— D2 只把在册的青菱形环放大、D2+D3 外加那层 CRT 抖一下、
  D1 全屏白闪。三档都画在同一张真帧的同一个时刻上。
  动图答「5 秒长不长、四拍顺不顺」，并且把现状那版并排放进来 —— 短的那版先演完再钉在末帧，
  多出来的 3.95 s 花在哪几拍，看图就能分。

两处已知不严格，先摆出来：
  1. 动图与爆发图的底片是 spot2_raw（真关卡帧、**无玩家**），祭坛与人是按 x2 比例尺贴上去的；
     相机钉死不动。实机相机跟人，举起 48 px 时整幅画面会往下让 —— 这一张看不到那一下。
  2. 胶片那一格只有 72 世界 px 宽，装不下半径 96 px 的爆发环，所以胶片上不画环。
     环的尺寸与三种画法看爆发图，环的时机看动图。
"""

import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_player_frames as G
import gen_freeze_filter_preview as F
import gen_props as GP

OUT_SHEET = os.path.join(ROOT, "assets", "player", "preview_grant_sheet.png")
OUT_BURST = os.path.join(ROOT, "assets", "player", "preview_grant_burst.png")
OUT_GIF = os.path.join(ROOT, "assets", "player", "preview_grant_anim.gif")
OUT_BEAMS = os.path.join(ROOT, "assets", "player", "preview_grant_beams.png")
OUT_BEAMS_GIF = os.path.join(ROOT, "assets", "player", "preview_grant_beams.gif")
OUT_TL = os.path.join(ROOT, "assets", "player", "preview_grant_timeline.png")
OUT_SPIN = os.path.join(ROOT, "assets", "player", "preview_grant_spin.gif")
# 选定行单独那张图/动图按行名落盘（换成别的行就换名，旧的留着当记录）
CHOSEN = "W12"
OUT_CHOSEN = os.path.join(ROOT, "assets", "player", "preview_grant_%s.png" % CHOSEN.lower())
OUT_CHOSEN_GIF = os.path.join(ROOT, "assets", "player", "preview_grant_%s.gif" % CHOSEN.lower())
OUT_FINAL = os.path.join(ROOT, "assets", "player", "preview_grant_final.gif")
REAL_FRAME = os.path.join(ROOT, "assets", "ui", "frames", "spot2_raw.png")
FILTER_FRAME = os.path.join(ROOT, "assets", "ui", "frames", "spot2_filter.png")
REAL_W, REAL_H = Image.open(REAL_FRAME).size      # 1280x720，光柱的收据要按它算

# ---------------------------------------------------------------- 真帧上的舞台锚点
# 这两条不是猜的：spot2_raw 逐列扫过，(60,68,98)/(74,84,118) 的墙在设备 y=390 断成
# (22,26,42) 缝 + (206,222,250) 顶唇 + (104,120,164) 地皮 —— 地面线 = 设备 392 = 世界 196。
# 中轴选 836：左边白色钢柜到 460、右边青门框从 955 起，这一段是干净背景墙（与 D48 同一-spot）。
DEV_SCALE = 2
GROUND_DEV = 392
ALTAR_CX_DEV = 836

# ---------------------------------------------------------------- 节拍表（16 帧 / 5.0 s）
# 这一段没有一个数字是本地常量：帧数与 fps 读 gen_player_frames 的 grant 表（它就是
# slime_frames.tres 的上游），举升曲线读 player.gd 的 GRANT_LIFT（它就是游戏里跑的那条）。
# 抄一份在这里，改过游戏之后图就说谎了 —— 而这张图是他拍 A3/B2/C2/D2 的依据（D53 同一条）。
def _shipped_lift():
    src = open(os.path.join(ROOT, "scenes", "actors", "player", "player.gd"),
               encoding="utf-8").read()
    at = src.index("const GRANT_LIFT")
    body = src[src.index("[", at) + 1:src.index("]", at)]
    return [float(t) for t in body.replace("\n", " ").split(",") if t.strip()]


N = len(G.FRAMES["grant"])
FPS = G.CLIPS["grant"]["fps"]
LIFT = _shipped_lift()                       # 每帧脚底离祭坛帽顶的高度（世界 px）
assert len(LIFT) == N, "举升曲线与帧表不同长：图与游戏已经各走各的"
assert abs(N / FPS - 5.0) < 0.005, "grant 剪辑不再是 5.0 s，AbilityAltar.grant_time 该跟着改"
BEATS = ((0, 3, "LIFT"), (3, 6, "QUIZ"), (6, 9, "SHOCK"), (9, 12, "BURST"), (12, 13, "FALL"),
         (13, 16, "JOY"))
# 核心相对**玩家原点**（= 碰撞盒中心 = 脚底上方 15 px）的摆位；None = 已散进身体。
# 第 0 帧它还在帽顶上方（在册几何：核心中心 = 帽顶上方 9 px，相对原点就是 +6），从第 2 帧起
# 绕到身体右侧才露出来 —— 先画核心再画人，被他自己挡住就是"还没出来"。
# 第 9 帧它已经进胸：那一帧起不再画核心，改由身体发光接手（在册 flash_granted 那一档）。
CORE = [(0.0, 6.0), (7.0, 0.0), (17.0, -6.0), (14.0, -18.0), (6.0, -26.0), (0.0, -30.0),
        (0.0, -30.0), (0.0, -28.0), (0.0, -16.0), None, None, None, None, None,
        None, None]
# 身体发光那一档的强度（k = 在册 modulate 的插值系数，见 _modulate）。
GLOW = [0] * 9 + [1.0, 0.55, 0.2, 0, 0, 0, 0, 0]
# 冻结那层的强度（A3：只在爆发那一档钉住约 1.2 s）。>1 是 mix 的外推 = 对比压紧，不是变白。
STRENGTH = [0.0] * 9 + [1.6, 1.15, 1.0, 0.7, 0.3, 0.0, 0.0, 0.0]
RING_K = 0.30          # 三枚环彼此错开这么多（在册 D44 用的是 0.18）


def _rings_new(i):
    """爆发那一拍：环在 9..12 四帧里散完（现状是 2..4 三帧）。"""
    if i < 9 or i > 12:
        return []
    return [min(1.0, (i - 9) / 3.0 + k * RING_K) for k in range(3)]


def _rings_cur(i):
    """现状那版（D44）：核心 0..2 帧飞进胸口，环 2..4 帧散完，全程不举人。"""
    if i < 2 or i > 4:
        return []
    return [min(1.0, (i - 2) / 2.0 + k * 0.18) for k in range(3)]


CORE_CUR = [(0.0, 6.0), (4.0, -4.0), (0.0, -3.0), None, None, None, None]
GLOW_CUR = [0, 0, 1.0, 0.45, 0, 0, 0]

NEW_SCRIPT = dict(n=N, fps=FPS, lift=LIFT, core=CORE, glow=GLOW, strength=STRENGTH,
                  rings=_rings_new, ring_r=(6.0, 90.0), ring_a=0.95)
CUR_SCRIPT = dict(n=7, fps=7 / 1.05, lift=[0.0] * 7, core=CORE_CUR, glow=GLOW_CUR,
                  strength=[0.0] * 7, rings=_rings_cur, ring_r=(6.0, 26.0), ring_a=0.9)

CORE_COLOR = (110, 230, 240)     # 与 ability_altar.CORE_COLOR / props.json 的 altar_core 同源
FLASH_COLOR = (236, 246, 252)    # 白闪那一档用的近白（全-kit 没有纯白，这条按在册亮白走）
EYE = G.PAL["eye"][:3]
MOUTH = (G.PAL["mouth"][:3], G.PAL["mouth_dark"][:3])

STANCE = dict(w=31, h=25)        # idle 第 0 帧：收帧必须一字不差回到这里（wake 同一条纪律）
TEX_CORE = Image.open(os.path.join(ROOT, "assets", "props", "altar_core.png")).convert("RGBA")
TEX_CAP = Image.open(os.path.join(ROOT, "assets", "props", "altar_cap.png")).convert("RGBA")
TEX_SHAFT = Image.open(os.path.join(ROOT, "assets", "props", "altar_shaft.png")).convert("RGBA")
TEX_BASE = Image.open(os.path.join(ROOT, "assets", "props", "altar_base.png")).convert("RGBA")
TEX_GROOVE = Image.open(os.path.join(ROOT, "assets", "props", "altar_groove.png")).convert("RGBA")
# 在册的危险尖刺：只在选型图顶部的对照条里出现，用来把"白三角在册是危险语言"这件事摆到明面。
TEX_SPIKE = Image.open(os.path.join(ROOT, "assets", "props", "spike_unit.png")).convert("RGBA")


def pose(**kw):
    f = dict(STANCE)
    f.update(kw)
    return f


# 三档候选：只有"疑惑 / 震惊 / 开心"三拍的画法不同，节拍与举升几何完全一致 ——
# 变了什么必须一眼能对上，否则比的就不是画法。
RAISE = [pose(w=31, h=26), pose(w=28, h=30, flare=0.95), pose(w=29, h=28, flare=0.97)]
SHOCK = [pose(w=26, h=32, flare=0.90, eye_open=1.45, mouth="open", nubs=(1, 1)),
         pose(w=25, h=33, flare=0.88, eye_open=1.6, eye_dy=-1.0, mouth="open"),
         pose(w=34, h=19, flare=1.05, eye_open=0.55)]          # 收团蓄力
BURST = [pose(w=34, h=18, flare=1.08, eye_open=0.32, eye_dy=1.0, mouth="open"),
         pose(w=33, h=22, flare=1.04, eye_open=0.4, mouth="open")]
FALL = pose(w=33, h=20, flare=1.06)                            # 现成 land 那一档的身段
JOY = [pose(w=34, h=20, flare=1.06, eye_open=0.42),
       pose(w=27, h=31, flare=0.92, eye_open=0.42),
       pose(w=32, h=23, flare=1.02, eye_open=0.45),
       pose()]                                                 # 收帧 = idle 第 0 帧一字不差

QUIZ_B = [pose(w=30, h=27, dome_lean=3.0, eye_dy_lr=(-1.8, 0.6), mouth="flat"),
          pose(w=30, h=27, dome_lean=-3.0, eye_dy_lr=(0.6, -1.8), mouth="flat"),
          pose(w=30, h=26, dome_lean=1.5, eye_dy_lr=(-1.2, 0.8), mouth="flat", nubs=(1, 0))]
QUIZ_C = [pose(w=30, h=27, dome_lean=4.5, eye_dy=-0.8, nubs=(1, 0)),
          pose(w=30, h=27, dome_lean=-4.5, eye_dy=-0.6, nubs=(0, 1)),
          pose(w=30, h=26, dome_lean=2.5, eye_dy=0.6, nubs=(1, 0), mouth="open")]
JOY_A = [dict(p, mouth="grin") for p in JOY[:3]] + [JOY[3]]
JOY_C = JOY

ROWS = {
    # A：新旋钮的两笔都用 —— 疑惑靠"一只眼收"，开心靠四像素上翘弧。这一行就是**已进生产的
    # 那张帧表**（gen_player_frames.FRAMES["grant"]），拍板之后把它抄进了游戏，所以 A 档不再
    # 由本文件的 pose() 拼装；B/C 两行留着，它们是当时被否掉的画法，不是待办。
    "A": G.FRAMES["grant"],
    # B：新旋钮只用在疑惑那一拍，且换成"两眼不同高"（斜视）而不是收一只；开心同 A
    "B": RAISE + QUIZ_B + SHOCK + BURST + [FALL] + JOY_A,
    # C：完全不碰新旋钮（现有参数能走多远就走多远）—— 用来量"加旋钮买到了什么"
    "C": RAISE + QUIZ_C + SHOCK + BURST + [FALL] + JOY_C,
}

LABELS = {
    "A": "A  新旋钮两笔都用：疑惑=单眼收 + grin",
    "B": "B  新旋钮只用在疑惑：两眼不同高（斜视），开心同 A",
    "C": "C  不加任何旋钮：疑惑只能靠歪头 + 收一只小耳",
}

CUR_ROW = [dict(STANCE) for _ in range(7)]    # 现状：全程站姿，演出靠核心与环，不靠身体


def _register(name, frames):
    G.FRAMES[name] = frames
    G.CLIPS[name] = {"loop": False, "fps": FPS}


def _unregister(name):
    G.FRAMES.pop(name, None)
    G.CLIPS.pop(name, None)


def _used_w(img):
    box = img.getchannel("A").getbbox()
    return 0 if box is None else box[2] - box[0]


def _silhouette(img):
    return [p > 8 for p in img.getchannel("A").getdata()]


def _sym_diff(a, b):
    """两张 44x44 的 alpha 剪影的对称差 / 画布面积（D58 那条量法，一个像素都不换口径）。"""
    sa, sb = _silhouette(a), _silhouette(b)
    return 100.0 * sum(1 for x, y in zip(sa, sb) if x != y) / float(G.FRAME * G.FRAME)


def _ink_diff(a, b):
    """只数「眼睛那一坨」与「嘴那几笔」各自的对称差像素数。

    必须有这一条：剪影只看 alpha，而"疑惑 / 开心"全长在眼睛和嘴上 —— 只用上一条量，
    单眼收与 grin 对度量的贡献恒为 0，量出来的小数字会被误读成"这两拍没做出来"。
    眼 = 那唯一的近白色，嘴 = mouth / mouth_dark 那两色，都是精确匹配，不引入阈值。
    """
    pa, pb = a.load(), b.load()
    e = m = 0
    for y in range(G.FRAME):
        for x in range(G.FRAME):
            qa = pa[x, y][:3] if pa[x, y][3] > 8 else None
            qb = pb[x, y][:3] if pb[x, y][3] > 8 else None
            if (qa == EYE) != (qb == EYE):
                e += 1
            if (qa in MOUTH) != (qb in MOUTH):
                m += 1
    return e, m


def _crt_mixed(scene, strength, full):
    """shader 里那句 out_color = mix(out_color, c, strength) 的离线复现。

    Image.blend 就是 a + (b-a)*t 并且像 GL 一样夹回 0..255，所以 strength>1 得到的是**外推**
    （对比压紧、暗部更暗），不是变白 —— D3 那一档买的就是这个外推。strength<=0 原样拷回。
    """
    if strength <= 0.0:
        return scene.copy()
    return Image.blend(scene, full, strength)


# ------------------------------------------------------------------ 舞台（一张画布通吃）

ALTAR_W, ALTAR_H = 47.0, 38.0     # 用户在 level_1 里正在用的那两个活旋钮
BASE_H, CAP_H, SHAFT_INSET = 16.0, 8.0, 8.0


def _tile(dst, tex, x, y, w, h, zoom):
    """平铺件按世界尺寸铺，再 NEAREST 整数放大 —— 与 TileDraw.tile 同一个走法。"""
    tw, th = tex.size
    ww, wh = max(1, int(round(w))), max(1, int(round(h)))
    tile = Image.new("RGBA", (ww, wh), (0, 0, 0, 0))
    for oy in range(0, wh, th):
        for ox in range(0, ww, tw):
            tile.paste(tex.crop((0, 0, min(tw, ww - ox), min(th, wh - oy))), (ox, oy))
    big = tile.resize((int(round(ww * zoom)), int(round(wh * zoom))), Image.NEAREST)
    dst.paste(big, (int(round(x)), int(round(y))), big)


def _blit(dst, tex, x, y, zoom):
    big = tex.resize((tex.width * zoom, tex.height * zoom), Image.NEAREST)
    dst.paste(big, (int(round(x)), int(round(y))), big)


def _diamond(d, cx, cy, r, alpha, width=2):
    pts = [(cx, cy - r), (cx + r * 0.7, cy), (cx, cy + r), (cx - r * 0.7, cy), (cx, cy - r)]
    d.line(pts, fill=(CORE_COLOR[0], CORE_COLOR[1], CORE_COLOR[2], int(alpha * 255)),
           width=width)


# ---------------------------------------------------------------- 爆发：白色三角光柱
# 用户 2026-09-27 两轮要求：
#   第一轮 "从核心向外射出白色三角状光柱"
#   第二轮 "三角形白色光柱应该和现在的反过来，尖端朝内，然后无限延长铺满屏幕，
#            其实表示的是光线从中射出"
# 所以形状是**楔形**：顶点钉在核心（= 胸口），往外越张越宽，长度顶出画面 —— 是光的透视，
# 不是绕着一圈的小尖刺。上一版那六个「尖端朝外 + 根部离体」的星芒是我对「射出」的误读，
# 它的画法只留在选型图顶部那条「上一版 vs 这一版」对照里，不再当候选。
#
# 楔形的算式（六个候选共用，变的只有根数、张角与长短）：
#   ease = 1 - (1-k)^2      先快后慢 —— 长出去那一下要冲，不要匀速
#   顶点 = 胸口（往外 1 px，只为躲开退化多边形被光栅化吃掉）
#   端点 = ease*ln，半宽 = tan(aw)*端点  —— 张角固定，所以宽度随长度自己放大
#   不透明度：前 55% 行程拉满，之后线性散尽（见 _beam_alpha）
# 中心 = 玩家原点（碰撞盒中心 = 脚底上方 15 px）：第 9 帧核心已经进胸（CORE[9]=None），
# 「从中射出」能落的点就只剩这一处，不是凹槽、也不是帽顶。
#
# ln 为什么给到 480 世界 px：这张底片里相机把祭坛钉在屏幕偏右（胸口在设备 (836,266)），
# 到屏幕左下那角的距离 = 476 世界 px —— 要"铺满"就得按这个数走。实机相机跟人，他居中时到
# 四角 = 367 世界 px（视口 640x360 世界 px 的半对角），所以同一组楔形在游戏里 k≈0.52 铺满，
# 在这张钉死相机的底片上要 k≈0.90。两个数都进收据，别把它们混成一条。
#
# 换成楔形之后，「白三角 = 在册危险尖刺」那层冲突小了很多：尖刺是立在面上的小三角，楔形是
# 从一点张开的光，只有配色同源（spike_unit 主体 206,222,250，光柱 236,246,252 更白）。
# 对照条照旧留着，判读归他。

def _circle(n, ln, hw, off=-90.0, short=None):
    out = []
    for j in range(n):
        odd = short is not None and j % 2 == 1
        out.append((off + 360.0 * j / n, short if odd else ln, hw * (0.68 if odd else 1.0)))
    return out


def _rays(n, aw, ln, off=-90.0):
    """n 根等分楔形：每根的张角一半 = aw 度，长度 = ln 世界 px。"""
    return [(off + 360.0 * j / n, aw, ln) for j in range(n)]


def _rays_alt(n, aw, ln, aw_s, ln_s, off=-90.0):
    """长短交替：偶数位长楔、奇数位短楔（星芒的骨架，但每根都是朝外张开的楔）。"""
    return [(off + 360.0 * j / n, aw_s if j % 2 else aw, ln_s if j % 2 else ln)
            for j in range(n)]


# 六个候选的 ln 一律 480（顶到这张底片的远角），差别只在根数与张角。
BEAM_ROWS = (
    ("W4", "W4   4 根厚楔（十字）\n张角 32 度，一根就吃掉半个屏",
     dict(rays=_rays(4, 16.0, 480.0))),
    ("W6", "W6   6 根\n张角 22 度，根与根的缝还读得出",
     dict(rays=_rays(6, 11.0, 480.0))),
    ("W8", "W8   8 根\n张角 16 度，十字 + 四角都占上",
     dict(rays=_rays(8, 8.0, 480.0))),
    ("W12", "W12  12 根细\n张角 9 度，密成一圈放射线",
     dict(rays=_rays(12, 4.5, 480.0))),
    ("W6A", "W6A  6 长 + 6 短交替\n短楔 200 px / 张角 12 度",
     dict(rays=_rays_alt(12, 11.0, 480.0, 6.0, 200.0), alt=True)),
    ("W6E", "W6E  = W6 白芯 + 在册青边\n青的那圈张角宽 1.6 倍",
     dict(rays=_rays(6, 11.0, 480.0), edge=True)),
)

MOMENTS = (0.15, 0.5, 0.95)      # 一拍之内的三个进度：刚出 / 铺到半屏 / 快散尽

# 第三轮要求（2026-09-27）：
#   "我希望光束从动画一开始时就逐渐出现，从细变粗并围绕主角旋转，最后在爆炸时填满屏幕并消失"
# 于是光束不再是爆发那一拍的专属，而是整段的时间线构件：帧 0..9 各占行程的 i/9（第 9 帧
# = 爆炸那一拍 = k=1 正好铺满），第 10 帧起整族没了。
# 「消失」目前是**硬切**而不是再淡一遍：他要的是"填满并消失"，淡出会把"爆"字泄掉；
# 如果看下来觉得切得太硬，改成散三帧只是一行的事（BK 后面接 0.75/0.45/0.15 即可）。
BK = [i / 9.0 for i in range(10)] + [None] * 6
WIDEN0 = 0.12        # k=0 时张角只有终值的 12%：起步是一条细线，不是断开的空帧
FADE_IN = 0.15       # 不透明度在行程前 15% 从 0 拉到满（≈帧 0 与帧 1 之间），之后不淡
SPIN = 0.5           # 整段绕主角半圈 = 9 步、每步 20 度；各候选的频闪上限见 beam_report
SPIN_SLOW = 12.0 * 9.0 / 360.0     # 每帧 12 度 = 整段 0.3 圈（W12 那行的频闪上限是 15 度/帧）
DIS = {10: 0.66, 11: 0.33}         # "散三帧"那一档：帧 10/11 只收亮度到 66/33%，第 12 帧已经没了
# ---- 定案（用户 2026-09-27 三条裁定）：形状 W12 / 亮度 45% / 消失散三帧 / 青环与光束同帧
# 转速仍按他第一轮要的"整段半圈"（20 度/皮帧）：光柱是程序化构件、每渲染帧 _draw() 一遍，
# 60 fps 下每帧只走 1.07 度 -> 不触发频闪那条限（详见 chosen_anim 的说明与交付记录）。
CHOSEN_FAC = 0.45
CHOSEN_MODE = "dis"
CHOSEN_RINGS = True
TL_FRAMES = (1, 4, 7, 9, 10)     # 静态图取的五个断面：刚出 / 半程 / 快满 / 爆炸 / 消失后一拍


def _chosen_cfg(spin=SPIN):
    """选定那一行（CHOSEN）的形状参数 + 这一轮的三个动作开关，别的都不动。"""
    for key, _label, cfg in BEAM_ROWS:
        if key == CHOSEN:
            return dict(cfg, spin=spin, widen=True, hold=True)
    raise KeyError(CHOSEN)


def _tl_state(i, mode="cut"):
    """第 i 帧光束的状态 = (行程 k, 不透明度系数)；None 表示这一帧没有光束。

    "cut" 是硬切（第 10 帧整族没了）；"dis" 是散三帧 —— 几何已经铺满，只把亮度收干净，
    因为"已经铺满的光"再缩短会读成往里吸，不是散去。
    """
    if i <= 9:
        return (BK[i], 1.0)
    if mode == "cut" or i not in DIS:
        return None
    return (1.0, DIS[i])


def _tl_rows():
    """六个几何候选 + 这一轮的三个动作开关；形状与 ln 一个都不动，只加时间线。"""
    return [(key, label, dict(cfg, spin=SPIN, widen=True, hold=True))
            for key, label, cfg in BEAM_ROWS]


def _spin_step(cfg):
    """每帧转多少度 vs 根与根的间隔：**间隔的一半**是不起频闪的上限。

    等分 n 根的图样每 360/n 度重复一次，所以一步跨过半个重复周期就会读成抖动或倒转。
    这不是审美判断，是采样定理，必须写进收据 —— 否则 W12 那一行"看着不舒服"会被当成画风问题。
    """
    n = len(cfg["rays"])
    if cfg.get("alt"):
        n //= 2                     # 长短交替：重复周期是「一长一短」那一对
    spacing = 360.0 / n
    step = SPIN * 360.0 / 9.0
    return n, spacing, step, step <= spacing / 2.0, spacing / (2.0 * step)


def _beam_polys(cx, cy, k, cfg, zoom, hw_mul=1.0, len_add=0.0):
    """旧那一族（尖端朝外、根部离体）的多边形 —— 只给选型图顶部的「上一版」对照用。"""
    ease = 1.0 - (1.0 - k) ** 2
    r0 = (3.0 + cfg.get("travel", 6.0) * ease) * zoom
    for ang, ln, hw in cfg["spokes"]:
        a = math.radians(ang)
        ca, sa = math.cos(a), math.sin(a)
        px, py = -sa, ca                     # 垂直于出射方向 = 三角的底边方向
        rt = r0 + (ease * ln + len_add) * zoom
        hh = hw * hw_mul * zoom
        yield [(cx + r0 * ca + px * hh, cy + r0 * sa + py * hh),
               (cx + rt * ca, cy + rt * sa),
               (cx + r0 * ca - px * hh, cy + r0 * sa - py * hh)]


def _wedge_polys(cx, cy, k, cfg, zoom, aw_mul=1.0, len_add=0.0):
    """这一族：顶点钉在 (cx, cy)，往外张成楔形，长度随 k 顶出画面。

    第三轮（2026-09-27）多了两个动作，都由 cfg 开关控制、**默认全关** —— 上一版那两张爆发图的
    cfg 里没有 spin / widen，走的是同一条老算式，图必须一字不变地照旧画出来，否则
    "他批过的形状"会被这一轮的改动偷偷换掉。
      spin  = 整段行程里绕主角转的圈数（偏角 = spin*360*k，与根数无关）
      widen = 张角从终值的 WIDEN0 倍线性长到 1 倍 —— 就是"从细变粗"
    """
    ease = 1.0 - (1.0 - k) ** 2
    spin = cfg.get("spin", 0.0) * 360.0 * k
    wf = (WIDEN0 + (1.0 - WIDEN0) * k) if cfg.get("widen") else 1.0
    for ang, aw, ln in cfg["rays"]:
        r1 = (ease * ln + len_add) * zoom
        aw_e = aw * wf * aw_mul
        if r1 <= 1.0 or aw_e <= 0.05:      # 细到不足一度的楔形画出来就是一条线，省掉
            continue
        a = math.radians(ang + spin)
        ca, sa = math.cos(a), math.sin(a)
        px, py = -sa, ca
        half = math.tan(math.radians(aw_e)) * r1
        yield [(cx + zoom * ca, cy + zoom * sa),
               (cx + r1 * ca + px * half, cy + r1 * sa + py * half),
               (cx + r1 * ca - px * half, cy + r1 * sa - py * half)]


def _beam_alpha(k, cfg=None):
    """淡出的律：前 55% 行程**不淡**（那几帧要它硬白），之后线性收干净。

    试过 (1-k)^1.3：那样 k=0.5 就只剩 37% 不透明、k=0.95 已经小于一个可测像素（六行的
    收据里 ink=0 就是这么来的）—— 光柱在自己的拍子里就没了，比的是"消失"不是"射出"。

    cfg.hold 是第三轮那条律：光束要从头长到尾，所以**淡入**（前 FADE_IN 行程从 0 拉到满）
    之后一直拉满，"消失"交给爆炸之后那一拍的硬切 —— 不再淡第二遍。
    """
    if cfg is not None and cfg.get("hold"):
        return int(round(255.0 * min(1.0, k / FADE_IN)))
    return int(round(255.0 * (1.0 - max(0.0, (k - 0.55) / 0.45))))


def _beam_layer(size, cx, cy, k, cfg, zoom):
    """独立透明层再 alpha_composite —— 不是直接在底图上画。

    直接 `d.polygon(pts, fill=(...,alpha))` 写进去的是**替换**而非叠加，之后 convert("RGB")
    把 a 通道整个扔掉：那样"淡出"在图上根本不存在。在册那几枚环此前就吃了这个亏（本脚本
    已一并改走层，见 paint_stage），光柱的命根子就是那下淡出，不能再犯第二次。
    """
    wedge = "rays" in cfg
    fac = cfg.get("a_fac", 1.0)

    def _polys(c, kk, mul, add):
        return _wedge_polys(c[0], c[1], kk, cfg, zoom, aw_mul=mul, len_add=add) if wedge \
            else _beam_polys(c[0], c[1], kk, cfg, zoom, hw_mul=mul, len_add=add)

    core = Image.new("RGBA", size, (0, 0, 0, 0))
    if k > 0.0:
        d = ImageDraw.Draw(core)
        alpha = int(round(_beam_alpha(k, cfg) * fac))
        for pts in _polys((cx, cy), k, 1.0, 0.0):
            d.polygon(pts, fill=FLASH_COLOR + (alpha,))
    if not cfg.get("edge"):
        return core
    ring = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ring)
    alpha = int(round(_beam_alpha(k, cfg) * fac * 0.75))
    for pts in _polys((cx, cy), k, 1.6 if wedge else 1.75, 0.0 if wedge else 3.0):
        d.polygon(pts, fill=CORE_COLOR + (alpha,))
    ring.alpha_composite(core)
    return ring


# player.gd:46 那档授予提亮，原样搬过来（不自己另拟一个数）。
GRANT_GLOW = (1.0, 1.22, 1.35)


def _modulate(fr, k):
    """`_visual.modulate = Color(lerp(1.0, GRANT_GLOW, k))` 的离线版：逐通道乘、夹回 255。

    这条不是装饰：乘性提亮对近黑的身体本体几乎不做功（10 x 1.35 还是黑的），吹得动的只有
    描边和眼白。D44 那一档"发光"在图上到底剩多少，就是要它自己说清楚。
    """
    m = [1.0 + (c - 1.0) * k for c in GRANT_GLOW]
    r, g, b, a = fr.split()
    return Image.merge("RGBA", (
        r.point(lambda v: min(255, int(v * m[0] + 0.5))),
        g.point(lambda v: min(255, int(v * m[1] + 0.5))),
        b.point(lambda v: min(255, int(v * m[2] + 0.5))), a))


def paint_stage(img, clip, i, script, zoom, cx, ground, opts):
    """把「祭坛 + 被举起的人 + 核心 + 环」画进任意底图。

    zoom = 世界像素 -> 本图像素；cx / ground = 祭坛中轴与地面线（本图像素）。
    摆位算式与在册一致：脚底贴画布第 36 行（BOTTOM），玩家原点 = 碰撞盒中心 = 脚底上方 15 px。
    先画核心再画人：还在凹槽那两帧它会被他自己的身子挡住，那就是"还没出来"。
    """
    lift = script["lift"][i]
    feet = int(round(ground - lift * zoom))
    origin = feet - int(round(15.0 * zoom))
    if opts.get("terrain"):
        d0 = ImageDraw.Draw(img, "RGBA")
        d0.rectangle([0, ground, img.width, img.height], fill=(104, 120, 164, 255))
        d0.line([(0, ground), (img.width, ground)], fill=(206, 222, 250, 255), width=zoom)
    if opts.get("altar", True):
        ax = cx - ALTAR_W * 0.5 * zoom
        top = ground - ALTAR_H * zoom
        _tile(img, TEX_BASE, ax, ground - BASE_H * zoom, ALTAR_W, BASE_H, zoom)
        _tile(img, TEX_CAP, ax, top, ALTAR_W, CAP_H, zoom)
        _tile(img, TEX_SHAFT, ax + SHAFT_INSET * zoom, top + CAP_H * zoom,
              ALTAR_W - SHAFT_INSET * 2.0, ALTAR_H - BASE_H - CAP_H, zoom)
        _blit(img, TEX_GROOVE, cx - 9 * zoom, top + 3 * zoom, zoom)
    # 举升的收据：一条竖直细线 + 三格刻度（48 px = 3 格瓦片，摆图时头顶够不够就这么看）
    # 带 alpha 的画物一律先落在独立层上、再 alpha_composite：直接在底图上写半透明像素会被
    # 之后的 convert("RGB") 把 a 扔掉，淡出等于没画（见 _beam_layer 那段说明）。
    under = Image.new("RGBA", img.size, (0, 0, 0, 0))
    drew = False
    if opts.get("ruler") and lift > 0.5:
        d = ImageDraw.Draw(under)
        d.line([(cx, feet), (cx, ground)], fill=(110, 230, 240, 70), width=max(1, zoom // 2))
        for k in (1, 2, 3):
            y = int(round(ground - 16.0 * k * zoom))
            d.line([(cx - 9 * zoom, y), (cx + 9 * zoom, y)], fill=(110, 230, 240, 90),
                   width=max(1, zoom // 2))
        drew = True
    if opts.get("beams"):
        cfg, k = opts["beams"]
        under.alpha_composite(_beam_layer(img.size, cx, origin, k, cfg, zoom))
        drew = True
    if drew:
        img.alpha_composite(under)
    if script["core"][i] is not None:
        cxx, cyy = script["core"][i]
        _blit(img, TEX_CORE, cx + cxx * zoom - TEX_CORE.width * 0.5 * zoom,
              origin + cyy * zoom - TEX_CORE.height * 0.5 * zoom, zoom)
    fr = G.render(clip, i).convert("RGBA")
    glow = script["glow"][i]
    if glow:
        fr = _modulate(fr, glow)
    _blit(img, fr, cx - G.FRAME * 0.5 * zoom, feet - 36.0 * zoom, zoom)
    ages = script["rings"](i)
    if opts.get("rings", True) and ages:
        lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(lay)
        r0, r1 = opts.get("ring_r") or script["ring_r"]
        for a in ages:
            _diamond(d, cx, origin, (r0 + a * (r1 - r0)) * zoom,
                     (1.0 - a) * script["ring_a"], width=max(1, zoom))
        img.alpha_composite(lay)
    if opts.get("box"):
        # 碰撞盒 20x30：被举起来的是**这个**，不是皮 —— 红框跟着走才看得出契约
        ImageDraw.Draw(img, "RGBA").rectangle(
            [cx - 10 * zoom, feet - 30 * zoom, cx + 10 * zoom, feet],
            outline=(220, 60, 60, 255), width=max(1, zoom // 2))


# ------------------------------------------------------------------ 三张图

def sheet(path):
    """静态胶片：三档候选逐帧铺开，行首标账，拍点画在帧缝上。"""
    zoom = 3
    cell_w, cell_h = 72 * zoom, 128 * zoom
    ground = 108 * zoom
    strip, gap = 430, 10
    rows = []
    for key in ("A", "B", "C"):
        name = "sheet%s" % key
        _register(name, ROWS[key])
        canvas = Image.new("RGBA", (strip + N * cell_w, cell_h), (18, 24, 40, 255))
        for i in range(N):
            cell = Image.new("RGBA", (cell_w, cell_h), (18, 24, 40, 255))
            paint_stage(cell, name, i, NEW_SCRIPT, zoom, cell_w * 0.5, ground,
                        dict(terrain=True, ruler=True, box=True, rings=False))
            canvas.paste(cell, (strip + i * cell_w, 0))
        d = ImageDraw.Draw(canvas, "RGBA")
        frames = [G.render(name, i) for i in range(N)]
        widest = max(_used_w(f) for f in frames)
        d.text((12, 14), "%s\n%d 帧 / %.1f fps = %.2f s\n最宽 %d px（上限 36）\n"
               "举升峰值 %.0f px = 3 格瓦片\n红框 = 碰撞盒 20x30：被举起的是它\n"
               "青线/青横杠 = 举升高度与三格刻度\n这一格装不下爆发环（半径 96 px），\n"
               "环的三种画法看爆发图，时机看动图"
               % (LABELS[key], N, FPS, N / FPS, widest, max(LIFT)),
               fill=(240, 240, 240), font=GP._font(16))
        for start, end, label in BEATS:
            x = strip + start * cell_w
            d.line([(x, 0), (x, canvas.height)], fill=(255, 200, 90, 255), width=2)
            d.text((x + 4, canvas.height - 24), "%s %.1f s" % (label, (end - start) / FPS),
                   fill=(255, 200, 90), font=GP._font(13))
        rows.append(canvas.convert("RGB"))
        _unregister(name)
    out = Image.new("RGB", (max(r.width for r in rows),
                            sum(r.height for r in rows) + gap * 2), (10, 12, 16))
    y = 0
    for r in rows:
        out.paste(r, (0, y))
        y += r.height + gap
    out.save(path)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"), out.size)


def burst_sheet(path):
    """爆发那一档的三档候选 + 现状参照，全部画在同一张真帧的同一时刻上。

    底片不是画的：spot2_raw = frame_grab 抓的真帧。屏幕空间的滤镜与白闪只有套在真帧上
    才看得出它吃了谁（D46 同一条理由）。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    print("CRT mirror vs shipped filter (raw frame):",
          _crt_readout(raw, F.crt(raw, 1.3, 0.10, 0.25, 0.0, 0.001)))
    _register("bA", ROWS["A"])
    _register("bC", CUR_ROW)
    #        标题                                            clip  i   script  环           CRT  白闪
    cells_cfg = (
        ("D2   在册青菱形环放大：6->90 px（现状 6->26），零新零件",
         "bA", 9, NEW_SCRIPT, (6.0, 90.0), 0.0, 0.0),
        ("D2+D3   同 D2 + 那层 CRT 抖一下：strength 1.6 = mix 外推（压紧，不是变白）",
         "bA", 9, NEW_SCRIPT, (6.0, 90.0), 1.6, 0.0),
        ("D1   同 D2 + 全屏白闪 0.78（全项目第一处近白；它盖整屏，这里只裁了一块）",
         "bA", 9, NEW_SCRIPT, (6.0, 90.0), 0.0, 0.78),
        ("参照 1   同 D2，但滤镜走**在册强度** 1.0 —— 看 1.6 到底多买了多少",
         "bA", 9, NEW_SCRIPT, (6.0, 90.0), 1.0, 0.0),
        ("参照 2   这一帧的底色：无环、无滤镜、无白闪（= 冻结期以外的画面）",
         "bA", 9, NEW_SCRIPT, False, 0.0, 0.0),
        ("参照 3   现状 1.05 s 版的爆发档：人不离台、环 6->26、身体发光",
         "bC", 3, CUR_SCRIPT, None, 0.0, 0.0),
    )
    crop = (ALTAR_CX_DEV - 240, 60, ALTAR_CX_DEV + 240, 420)
    out_cells = []
    for title, clip, i, script, rr, s, flash in cells_cfg:
        extra = {} if rr is None else (dict(rings=False) if rr is False else dict(ring_r=rr))
        scene = paint_real(raw, clip, i, script, extra)
        if s > 0.0:
            scene = _crt_mixed(scene, s, F.crt(scene, 1.3, 0.10, 0.25, 0.0, 0.001))
        if flash > 0.0:
            scene = Image.blend(scene, Image.new("RGB", scene.size, FLASH_COLOR), flash)
        cell = scene.crop(crop)
        cell = cell.resize((cell.width * 2, cell.height * 2), Image.NEAREST)
        ImageDraw.Draw(cell).text((10, 6), title, fill=(240, 240, 240), font=GP._font(18))
        out_cells.append(cell)
    _unregister("bA")
    _unregister("bC")
    w = max(c.width for c in out_cells)
    rows = (len(out_cells) + 1) // 2
    out = Image.new("RGB", (w * 2 + 12, (out_cells[0].height + 8) * rows), (10, 12, 16))
    for n, c in enumerate(out_cells):
        out.paste(c, ((n % 2) * (w + 12), (n // 2) * (c.height + 8)))
    out.save(path)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"), out.size)


def paint_real(raw, clip, i, script, extra=None):
    """在真帧上摆台：x2 比例尺、祭坛中轴与地面线都钉在设备像素（见文件头那两条实测）。

    回来的是 RGB：那层 CRT 要吃 RGB（crt() 的输出就是 RGB），而这一张本来就铺满不透明。
    """
    scene = raw.copy().convert("RGBA")
    opts = dict(altar=True, ruler=False, box=False, rings=True)
    opts.update(extra or {})
    paint_stage(scene, clip, i, script, DEV_SCALE, ALTAR_CX_DEV, GROUND_DEV, opts)
    return scene.convert("RGB")


def _crt_readout(raw, calc):
    shipped = Image.open(FILTER_FRAME).convert("RGB")
    means, peak, big = F.diff_stats(calc, shipped)
    return "mean=%s peak=%d over3=%d" % (["%.2f" % m for m in means], peak, big)


# ------------------------------------------------------------------ 光柱两张图

BURST_I = 9          # 爆发第一帧：举升到峰值 48 px、核心已进胸（CORE[9]=None）


def _chest_dev(i):
    """第 i 帧的胸口（= 玩家原点）在真帧上的设备坐标 —— 光柱的出射中心。"""
    feet = GROUND_DEV - int(round(LIFT[i] * DEV_SCALE))
    return ALTAR_CX_DEV, feet - 15 * DEV_SCALE, feet


def _beam_coverage(cfg, i, k, clip):
    """楔形的三笔收据：铺掉多少屏幕、被他自己挡掉多少、以及顶点到端点的长度。

    画在身体**之后**（先楔形后人），所以顶点那一段必然被身子截掉 —— 这是 D56 那条便宜方案的
    直接代价：换来的是脸一个像素都没被盖住，而且他周身一圈全是硬白，近黑的剪影反而最跳。
    """
    cx, cy, feet = _chest_dev(i)
    lay = _beam_layer((REAL_W, REAL_H), cx, cy, k, cfg, DEV_SCALE)
    la = lay.getchannel("A")
    body = Image.new("RGBA", (REAL_W, REAL_H), (0, 0, 0, 0))
    _blit(body, G.render(clip, i), cx - G.FRAME * 0.5 * DEV_SCALE,
          feet - 36.0 * DEV_SCALE, DEV_SCALE)
    ba = body.getchannel("A")
    tot = sum(1 for v in la.getdata() if v > 8)
    occ = sum(1 for v, w in zip(la.getdata(), ba.getdata()) if v > 8 and w > 8)
    box = lay.getbbox()
    if "rays" in cfg:
        reach = max(ln for _, _, ln in cfg["rays"])
        aw = max(a for _, a, _ in cfg["rays"])
    else:
        reach = max(3.0 + cfg.get("travel", 6.0) + ln for _, ln, _ in cfg["spokes"])
        aw = 0.0
    return dict(tot=tot, visible=tot - occ, occl=100.0 * occ / max(1, tot), reach=reach,
                aw=aw, cover=100.0 * tot / float(REAL_W * REAL_H),
                box=None if box is None else (int((box[2] - box[0]) / DEV_SCALE),
                                              int((box[3] - box[1]) / DEV_SCALE)))


def _wedge_scene(raw, clip, i, cfg, k, a_fac=1.0):
    """真帧上摆一台：楔形（或对照用的旧星芒）画在身体之后，环只在 cfg.rings 时叠。"""
    c = dict(cfg)
    c["a_fac"] = a_fac
    return paint_real(raw, clip, i, NEW_SCRIPT,
                      dict(rings=bool(c.get("rings")), beams=(c, k), ring_r=(6.0, 90.0)))


def _tl_scene(raw, clip, i, cfg, st="auto", rings=True):
    """整段时间线那一族：楔形 + 环 + 人 + 台按脚本同帧叠出来（谁也不替谁让位）。

    与 _wedge_scene 的差别只有一个：这一条默认不关环。爆发那一拍在册本来就有三枚青菱形环，
    既然光束现在也铺到同一帧，评审件就得**同时**在场 —— 否则这张图替他把"要不要同时上"
    这条决定做掉了。st 传 _tl_state 的结果；"auto" = 按默认的硬切算。
    """
    if st == "auto":
        st = _tl_state(i)
    extra = dict(rings=rings, ring_r=(6.0, 90.0))
    if st is not None:
        k, fac = st
        extra["beams"] = (dict(cfg, a_fac=fac), k)
    return paint_real(raw, clip, i, NEW_SCRIPT, extra)


def _tl_cell(scene, i, fw, fh):
    """按脚本给这一帧的 CRT 强度，再等比 /2 收回评审尺寸。"""
    if STRENGTH[i] > 0.0:
        scene = _crt_mixed(scene, STRENGTH[i],
                          F.crt(scene, 1.3, 0.10, 0.25, 0.0, 0.001))
    return scene.convert("RGB").resize((fw, fh), Image.NEAREST)


def _tag(cell, txt, size=16):
    ImageDraw.Draw(cell).text((10, 6), txt, fill=(255, 200, 90), font=GP._font(size))
    return cell


def beams_sheet(path):
    """六个楔形候选 × 三个进度（整屏）+ 一格里距细节，全画在同一张真帧的爆发第一帧上。

    这一张只比**光柱本身**：CRT 抖与全屏白闪的选型在上次那张 burst 图里，这里一律不开，
    否则比的就不是形状了。最后一行不是候选，是同一组楔形的不透明度阶梯 —— 一旦"铺满屏幕"，
    吃多少背景就是另一个独立旋钮，得单独定。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    _register("bs", ROWS["A"])
    cx, cy, feet = _chest_dev(BURST_I)
    crop = (cx - 190, cy - 160, cx + 190, cy + 140)
    strip, gap, fw, fh = 560, 10, 640, 360
    row_w = strip + 3 * (fw + gap) + (crop[2] - crop[0] + gap)

    # ---- 对照条（不是候选）：上一版我误读的那一族留在图上，形状差异一眼对得上。
    top = Image.new("RGB", (row_w, 240), (10, 12, 16))
    d = ImageDraw.Draw(top)
    old = dict(spokes=_circle(6, 46, 5.5), travel=6.0)
    p1 = Image.new("RGBA", (170, 130), (18, 24, 40, 255))
    p1.alpha_composite(_beam_layer(p1.size, 85, 65, 0.5, old, 1.3))
    top.paste(p1.convert("RGB"), (8, 14))
    d.text((8, 150), "上一版（我误读了）\n尖端朝外、根部离体\n= 绕一圈小尖刺",
           fill=(170, 180, 200), font=GP._font(11))
    new = dict(rays=_rays(6, 11.0, 480.0))
    p2 = Image.new("RGBA", (170, 130), (18, 24, 40, 255))
    p2.alpha_composite(_beam_layer(p2.size, 85, 65, 0.5, new, 0.26))
    top.paste(p2.convert("RGB"), (190, 14))
    d.text((190, 150), "这一版（你要的）\n尖端钉在胸口、向外张开\n长度顶出画面",
           fill=(236, 246, 252), font=GP._font(11))
    p3 = Image.new("RGBA", (170, 130), (18, 24, 40, 255))
    _blit(p3, TEX_SPIKE, 45, 25, 5)
    top.paste(p3.convert("RGB"), (372, 14))
    d.text((372, 150), "在册 spike_unit\n(206,222,250) 危险尖刺\n楔形与它只同源在配色",
           fill=(206, 222, 250), font=GP._font(11))
    d.text((strip + 6, 10), "行 = 六个候选；前三列 = 同一拍的三个进度 k=0.15 / 0.5 / 0.95（整屏）；"
                            "第四列 = 胸口那一格的近距细节\n"
                            "出射中心 = 胸口（碰撞盒中心 = 脚底上方 15 px）：第 9 帧核心已进胸，"
                            "「从中射出」只有这一处可落\n"
                            "算式：顶点钉在胸口，端点 = ease*ln（ease = 1-(1-k)^2 先快后慢），"
                            "半宽 = tan(张角) * 端点 -> 越远越宽；不透明度前 55% 拉满、之后线性散尽\n"
                            "ln = 480 世界 px 的来由：这张底片里相机把祭坛钉在偏右，胸口到屏幕"
                            "左下那角 = 476 px，要铺满就得按它走；实机相机跟人（他居中）到四角"
                            "只要 367 px（视口 640x360 世界 px）-> 同一组楔形在游戏里 k≈0.52 就"
                            "铺满，在这张钉死的底片上要 k≈0.90\n"
                            "楔形一律画在身体之后 -> 脸零遮挡，代价是顶点那一小段被他自己截掉"
                            "（行首给了百分比）",
           fill=(255, 200, 90), font=GP._font(14))

    ladder = ("LAD", "不透明度阶梯（不是候选）\n同一组 W6、同一个 k=0.5，只改不透明度",
              dict(rays=_rays(6, 11.0, 480.0)))
    rows = [top]
    for key, label, cfg in BEAM_ROWS + (ladder,):
        row = Image.new("RGB", (row_w, fh), (18, 24, 40))
        dr = ImageDraw.Draw(row)
        st = _beam_coverage(cfg, BURST_I, 0.5, "bs")
        if key == "LAD":
            for n, (tg, fac) in enumerate((("不透明度 100%", 1.0), ("不透明度 70%", 0.7),
                                           ("不透明度 45%", 0.45), ("不透明度 22%", 0.22))):
                scene = _wedge_scene(raw, "bs", BURST_I, cfg, 0.5, fac)
                row.paste(_tag(scene.resize((fw, fh), Image.NEAREST), "k=0.50  " + tg),
                          (strip + n * (fw + gap), 0))
            dr.text((12, 14), "%s\n\n四格铺掉同一比例的屏幕：%.0f%%（不透明度只改亮度，不改形状）\n"
                    "挑一档，或直接说「按第几格」" % (label, st["cover"]),
                    fill=(240, 240, 240), font=GP._font(14))
            rows.append(row)
            continue
        for n, k in enumerate(MOMENTS):
            scene = _wedge_scene(raw, "bs", BURST_I, cfg, k)
            row.paste(_tag(scene.resize((fw, fh), Image.NEAREST),
                           "%s  k = %.2f  整屏" % (key, k)), (strip + n * (fw + gap), 0))
        detail = _wedge_scene(raw, "bs", BURST_I, cfg, 0.5).crop(crop).convert("RGB")
        row.paste(_tag(detail, "k = 0.50  胸口细节（1:1 设备像素）", 13),
                  (strip + 3 * (fw + gap), 0))
        dr.text((12, 14), "%s\n\n每根张角 %.0f 度、长 %.0f px\n（他这帧本身宽 34、举升 %.0f）\n"
                "k=0.5 铺掉 %.0f%% 屏幕 / k=0.95 铺掉 %.0f%%\n顶点被他自己挡掉 %.0f%%（脸 0 遮挡）"
                % (label, st["aw"] * 2, st["reach"], LIFT[BURST_I], st["cover"],
                   _beam_coverage(cfg, BURST_I, 0.95, "bs")["cover"], st["occl"]),
                fill=(240, 240, 240), font=GP._font(14))
        rows.append(row)
    _unregister("bs")
    out = Image.new("RGB", (rows[0].width, sum(r.height for r in rows) + gap * len(rows)),
                    (10, 12, 16))
    y = 0
    for r in rows:
        out.paste(r, (0, y))
        y += r.height + gap
    out.save(path)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"), out.size)


def beams_anim(path):
    """六个候选各演一遍爆发那一拍（帧 9..12，k = 0 / .33 / .66 / 1），六行整屏同拍并排。

    楔形要的就是"铺满屏幕"那个动作，所以这一张不裁：每格都是整帧，相机钉死（实机相机会跟
    人，他基本居中，铺满得比这里更早 —— 静态图行首那两个数给了两种口径）。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    _register("ba", ROWS["A"])
    strip, gap, fw, fh = 300, 8, 640, 360
    idx = (9, 10, 11, 12)
    rows = []
    for key, label, cfg in BEAM_ROWS:
        cells = []
        for i in idx:
            k = (i - 9) / 3.0
            scene = _wedge_scene(raw, "ba", i, cfg, k)
            scene = _crt_mixed(scene, STRENGTH[i], F.crt(scene, 1.3, 0.10, 0.25, 0.0, 0.001))
            cells.append(scene.resize((fw, fh), Image.NEAREST).convert("RGB"))
        rows.append((label, cells))
    _unregister("ba")
    row_h = fh + gap
    canvas0 = Image.new("RGB", (strip + fw + gap, row_h * len(rows) + 26), (10, 12, 16))
    d0 = ImageDraw.Draw(canvas0)
    for n, (label, _) in enumerate(rows):
        d0.text((8, n * row_h + 6), label, fill=(240, 240, 240), font=GP._font(12))
    d0.text((8, len(rows) * row_h + 2), "每行 = 一个候选，整屏，同一拍的四帧（0/.31/.63/.94 s）；"
            "人那一拍六行完全一样（A 档 + CRT 抖 1.6->1.15->1.0->0.7）",
            fill=(255, 200, 90), font=GP._font(12))
    times = [i / FPS for i in idx]
    span = times[-1] + 0.6
    ticks = sorted(set(times) | {span})
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        for ri, (label, cells) in enumerate(rows):
            j = max(m for m, tm in enumerate(times) if tm <= t + 1e-6)
            canvas.paste(cells[j], (strip + gap, ri * row_h + gap))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.4
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=False)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"),
          "ticks=%d size=%dx%d" % (len(frames), frames[0].width, frames[0].height))


def timeline_sheet(path):
    """第三轮：六个候选 × 整段 5 s 的五个断面（帧 1/4/7/9/10），每格都是整屏真帧。

    这一张答的是"从动画一开始就逐渐出现、从细变粗、最后填满然后消失"这条时间线读不读得出来。
    旋转连不连续静态图说不准（那要看 spin 那张动图），这里给的是五个断面 + 每行的频闪收据。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    _register("tl", ROWS["A"])
    strip, gap, fw, fh = 520, 10, 640, 360
    row_w = strip + len(TL_FRAMES) * (fw + gap)

    top = Image.new("RGB", (row_w, 170), (10, 12, 16))
    ImageDraw.Draw(top).text(
        (12, 10),
        "行 = 六个几何候选（形状与上一版一字不差，只换时间线）；五列 = 整段 5 s 里的五个断面\n"
        "帧 1（0.31 s）刚出 / 帧 4（1.25 s）半程 / 帧 7（2.19 s）快满 / 帧 9（2.81 s）爆炸那一拍"
        " / 帧 10（3.13 s）消失后的第一拍\n"
        "行程 k = 帧号 / 9：第 9 帧正好铺满，第 10 帧整族没了（「消失」现在是硬切，不再淡第二遍）\n"
        "细→粗：张角从终值的 %.0f%% 线性长到 100%%；逐渐出现：不透明度在行程前 %.0f%% 内从 0 拉满"
        "，之后不淡\n"
        "旋转：整段绕主角 %.1f 圈 = 每帧 %.0f 度（等分 n 根的图样每 %.1f/n 度重复一次，"
        "跨过「间隔的一半」就读成抖动或倒转 -> 每行首给了那一行的上限）\n"
        "出射中心 = 胸口，跟着举升一起走；楔形一律画在身体之后（脸零遮挡）；"
        "在册那三枚青环这一张不关：帧 9 起它与光束同帧在场，两样要不要同时上归你定"
        % (WIDEN0 * 100.0, FADE_IN * 100.0, SPIN, SPIN * 360.0 / 9.0, 360.0),
        fill=(255, 200, 90), font=GP._font(14))

    rows = [top]
    for key, label, cfg in _tl_rows():
        n, spacing, step, ok, margin = _spin_step(cfg)
        row = Image.new("RGB", (row_w, fh), (18, 24, 40))
        dr = ImageDraw.Draw(row)
        for j, i in enumerate(TL_FRAMES):
            cell = _tl_cell(_tl_scene(raw, "tl", i, cfg), i, fw, fh)
            k = BK[i]
            tg = ("帧%d  %.2fs  无光束" % (i, i / FPS)) if k is None else \
                ("帧%d  %.2fs  k=%.2f  已转 %.0f 度" % (i, i / FPS, k, SPIN * 360.0 * k))
            row.paste(_tag(cell, tg, 13), (strip + j * (fw + gap), 0))
        a = _beam_coverage(cfg, 1, BK[1], "tl")
        b = _beam_coverage(cfg, BURST_I, 1.0, "tl")
        dr.text((12, 14), "%s\n\n每帧转 %.0f 度｜根间隔 %.0f 度｜频闪上限 %.0f 度/帧 -> %s\n"
                "帧 1：张角 %.1f 度、长 %.0f px、铺 %.1f%% 屏幕\n"
                "帧 9：张角 %.0f 度、长 %.0f px、铺 %.1f%% 屏幕（顶点被他自己挡掉 %.1f%%）"
                % (label, step, spacing, spacing / 2.0,
                   "不频闪（余量 %.1f 倍）" % margin if ok else "**会频闪**（超上限 %.1f 倍）"
                   % (step / (spacing / 2.0)),
                   a["aw"] * 2 * (WIDEN0 + (1 - WIDEN0) * BK[1]),
                   a["reach"] * (1.0 - (1.0 - BK[1]) ** 2),
                   a["cover"], b["aw"] * 2, b["reach"], b["cover"], b["occl"]),
                fill=(240, 240, 240), font=GP._font(14))
        rows.append(row)
    _unregister("tl")
    out = Image.new("RGB", (rows[0].width, sum(r.height for r in rows) + gap * len(rows)),
                    (10, 12, 16))
    y = 0
    for r in rows:
        out.paste(r, (0, y))
        y += r.height + gap
    out.save(path)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"), out.size)


def spin_anim(path):
    """第三轮：六个候选各演一遍**整段** 5 s（16 帧全给），六行同拍并排。

    静态断面看不出的三件事全在这张：转得连不连贯、细变粗读不读得出、频闪在哪一行发作。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    _register("sa", ROWS["A"])
    strip, gap, fw, fh = 300, 8, 640, 360
    rows = []
    for key, label, cfg in _tl_rows():
        n, spacing, step, ok, margin = _spin_step(cfg)
        cells = [_tl_cell(_tl_scene(raw, "sa", i, cfg), i, fw, fh) for i in range(N)]
        rows.append((("%s  每帧 %.0f 度 / 上限 %.0f%s" % (label.split("\n")[0], step, spacing / 2.0,
                                                         "" if ok else "  << 会频闪")), cells))
    _unregister("sa")
    row_h = fh + gap
    canvas0 = Image.new("RGB", (strip + fw + gap, row_h * len(rows) + 30), (10, 12, 16))
    d0 = ImageDraw.Draw(canvas0)
    for n, (label, _) in enumerate(rows):
        d0.text((8, n * row_h + 6), label, fill=(240, 240, 240), font=GP._font(12))
    d0.text((8, len(rows) * row_h + 6), "整段 5 s / 16 帧 @ 3.2 fps；光束在第 0..9 帧里长出来"
            "（细->粗、绕半圈、逐渐变亮后拉满），第 9 帧铺满，第 10 帧起没了",
            fill=(255, 200, 90), font=GP._font(12))
    times = [i / FPS for i in range(N)]
    span = times[-1] + 1.0 / FPS + 0.8      # 收尾静一拍，让"演完了"被看见
    ticks = sorted(set(times) | {span})
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        for ri, (label, cells) in enumerate(rows):
            j = max(m for m, tm in enumerate(times) if tm <= t + 1e-6)
            canvas.paste(cells[j], (strip + gap, ri * row_h + gap))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.8
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=False)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"),
          "ticks=%d size=%dx%d" % (len(frames), frames[0].width, frames[0].height))


def chosen_sheet(path):
    """选定那一行（CHOSEN）单独一张：转速 / 亮度 / 消失方式 / 与青环是否同帧，四问一次裁。

    转速发不发作静态图看不出来 —— 频闪是"动起来才读得出"的东西，所以这里两档转速只当形状
    对照摆出来，发作的过程在 .gif 里。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    _register("ch", ROWS["A"])
    fast, slow = _chosen_cfg(SPIN), _chosen_cfg(SPIN_SLOW)
    n, spacing, step, ok, margin = _spin_step(fast)
    lim = spacing / 2.0

    blocks = [
        ("转速 A：每帧 %.0f 度（整段 %.1f 圈）\n本行根间隔 %.0f 度 -> 上限 %.0f 度/帧，%s"
         % (step, SPIN, spacing, lim, "超了 %.2f 倍" % (step / lim) if not ok else "在上限内"),
         [("帧%d  k=%.2f  已转 %.0f 度" % (i, BK[i], step * i), fast, _tl_state(i), True, i)
          for i in (1, 4, 7, 9)]),
        ("转速 B：每帧 %.0f 度（整段 %.1f 圈）\n同一族形状，只是转得慢 —— 差别只在动图里"
         % (SPIN_SLOW * 360.0 / 9.0, SPIN_SLOW),
         [("帧%d  k=%.2f  已转 %.0f 度" % (i, BK[i], SPIN_SLOW * 360.0 * BK[i]), slow,
           _tl_state(i), True, i) for i in (1, 4, 7, 9)]),
        ("亮度阶梯 @ 帧 9（铺满那一拍）\n形状完全一样，只改不透明度：吃多少背景是独立旋钮",
         [("不透明度 %.0f%%" % (f * 100.0), fast, (1.0, f), True, BURST_I)
          for f in (1.0, 0.7, 0.45, 0.22)]),
        ("消失方式 A：硬切\n第 10 帧整族没了（现在图里走的就是这一条）",
         [("帧%d  %s" % (i, "铺满" if i == 9 else "已无光束"), fast, _tl_state(i, "cut"),
           True, i) for i in (9, 10, 11, 12)]),
        ("消失方式 B：散三帧\n几何已经铺满，只把亮度收到 66/33%，第 12 帧干净"
         "（铺满的光再缩短会读成往里吸，不是散去）",
         [("帧%d  亮度 %.0f%%" % (i, (1.0 if i == 9 else DIS.get(i, 0.0)) * 100.0), fast,
           _tl_state(i, "dis"), True, i) for i in (9, 10, 11, 12)]),
        ("青环要不要与光束同帧（在册那三枚菱形，帧 9..12 出场）\n左两格 = 帧 9，右两格 = 帧 10",
         [("帧9 环同帧", fast, _tl_state(9), True, 9),
          ("帧9 环不画", fast, _tl_state(9), False, 9),
          ("帧10 环同帧", fast, _tl_state(10), True, 10),
          ("帧10 环不画", fast, _tl_state(10), False, 10)]),
    ]

    strip, gap, fw, fh = 520, 10, 640, 360
    row_w = strip + 4 * (fw + gap)
    a1 = _beam_coverage(fast, 1, BK[1], "ch")
    a9 = _beam_coverage(fast, BURST_I, 1.0, "ch")
    top = Image.new("RGB", (row_w, 150), (10, 12, 16))
    ImageDraw.Draw(top).text(
        (12, 10),
        "选定行 = %s：%s\n"
        "整段 5 s / 16 帧 @ 3.2 fps；行程 k = 帧号/9，第 9 帧（爆炸那一拍）铺满；"
        "细->粗 = 张角从终值 %.0f%% 线性长到 100%%；逐渐出现 = 不透明度在行程前 %.0f%% 内从 0 拉满\n"
        "出射中心 = 胸口（跟着举升走），楔形一律画在身体之后 -> 脸零遮挡\n"
        "本行收据：帧 1 铺 %.1f%% 屏幕（%.0f px 长）/ 帧 9 铺 %.1f%%（%.0f px 长、顶点被他自己"
        "挡掉 %.1f%%）；实机相机居中时同一族 k=%.2f 就铺满，这张钉死相机的底片要 k=%.2f"
        % (CHOSEN, dict((k, l) for k, l, _ in BEAM_ROWS)[CHOSEN].replace("\n", "  "),
           WIDEN0 * 100.0, FADE_IN * 100.0, a1["cover"],
           a1["reach"] * (1.0 - (1.0 - BK[1]) ** 2), a9["cover"], a9["reach"], a9["occl"],
           0.52, 0.90),
        fill=(255, 200, 90), font=GP._font(14))

    rows = [top]
    for title, cells in blocks:
        row = Image.new("RGB", (row_w, fh), (18, 24, 40))
        ImageDraw.Draw(row).text((12, 14), title, fill=(240, 240, 240), font=GP._font(14))
        for j, (tg, cfg, st, rn, fr) in enumerate(cells):
            scene = _tl_cell(_tl_scene(raw, "ch", fr, cfg, st, rn), fr, fw, fh)
            row.paste(_tag(scene, tg, 13), (strip + j * (fw + gap), 0))
        rows.append(row)
    _unregister("ch")
    out = Image.new("RGB", (rows[0].width, sum(r.height for r in rows) + gap * len(rows)),
                    (10, 12, 16))
    y = 0
    for r in rows:
        out.paste(r, (0, y))
        y += r.height + gap
    out.save(path)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"), out.size)


def chosen_anim(path):
    """选定那一行的动图：三档并排演整段 5 s —— 转速两档 + 消失方式两档的组合。

    频闪只在动起来时才读得出来（A 档每帧 20 度跨过本行 30 度重复周期的一半以上，会读成抖动
    或倒转），这张就是给那条限制作证的；B/C 两档是把它修好之后的样子。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    strip, gap, fw, fh = 300, 8, 640, 360
    _n, spacing, step, ok, margin = _spin_step(_chosen_cfg(SPIN))
    tracks = [("A  每帧 %.0f 度 + 硬切｜本行上限 %.0f 度/帧 -> %s"
               % (step, spacing / 2.0,
                  "频闪（超上限 %.2f 倍）" % (step / (spacing / 2.0)) if not ok
                  else "余量 %.2f 倍" % margin),
               _chosen_cfg(SPIN), "cut"),
              ("B  每帧 %.0f 度 + 硬切（降到上限内）" % (SPIN_SLOW * 40.0),
               _chosen_cfg(SPIN_SLOW), "cut"),
              ("C  每帧 %.0f 度 + 散三帧" % (SPIN_SLOW * 40.0), _chosen_cfg(SPIN_SLOW), "dis")]
    _register("ca", ROWS["A"])
    rows = []
    for label, cfg, mode in tracks:
        cells = [_tl_cell(_tl_scene(raw, "ca", i, cfg, _tl_state(i, mode)), i, fw, fh)
                 for i in range(N)]
        rows.append((label, cells))
    _unregister("ca")
    row_h = fh + 26
    canvas0 = Image.new("RGB", (strip + fw + gap, row_h * len(rows) + 30), (10, 12, 16))
    d0 = ImageDraw.Draw(canvas0)
    for n, (label, _) in enumerate(rows):
        d0.text((8, n * row_h + 6), label, fill=(240, 240, 240), font=GP._font(13))
    d0.text((8, len(rows) * row_h + 6), "整段 5 s / 16 帧 @ 3.2 fps：%s 那一族，"
            "光束在帧 0..9 里长出来（细->粗、逐渐变亮后拉满），帧 9 铺满，之后按各行说的消失"
            % CHOSEN, fill=(255, 200, 90), font=GP._font(12))
    times = [i / FPS for i in range(N)]
    ticks = sorted(set(times) | {times[-1] + 1.0 / FPS + 0.8})
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        for ri, (label, cells) in enumerate(rows):
            j = max(m for m, tm in enumerate(times) if tm <= t + 1e-6)
            canvas.paste(cells[j], (strip + gap, ri * row_h + 26))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.8
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=False)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"),
          "ticks=%d size=%dx%d" % (len(frames), frames[0].width, frames[0].height))


def final_anim(path):
    """定案那一条：整段 5 s 单轨全屏，四条裁定全部落在上面（形状 / 亮度 / 消失 / 环）。

    这张就是"批准之后实装会长什么样"的那一张。亮度 45% 是**全局乘子**（不是只压爆发那一帧）：
    长出来的过程仍然从 0 拉到 45%，节奏感与 100% 那版一致，只是整体让出背景。
    """
    raw = Image.open(REAL_FRAME).convert("RGB")
    cfg = _chosen_cfg(SPIN)
    _register("fn", ROWS["A"])
    cells = []
    for i in range(N):
        st = _tl_state(i, CHOSEN_MODE)
        if st is not None:
            st = (st[0], st[1] * CHOSEN_FAC)
        cells.append(_tl_cell(_tl_scene(raw, "fn", i, cfg, st, CHOSEN_RINGS), i, 640, 360))
    _unregister("fn")
    canvas0 = Image.new("RGB", (640, 396), (10, 12, 16))
    ImageDraw.Draw(canvas0).text(
        (8, 366), "定案：%s + 亮度 %.0f%% + 消失散三帧 + 青环同帧 + 整段半圈｜5.00 s / 16 帧"
        % (CHOSEN, CHOSEN_FAC * 100.0), fill=(255, 200, 90), font=GP._font(13))
    times = [i / FPS for i in range(N)]
    ticks = sorted(set(times) | {times[-1] + 1.0 / FPS + 1.0})
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        j = max(m for m, tm in enumerate(times) if tm <= t + 1e-6)
        canvas.paste(cells[j], (0, 0))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 1.0
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=False)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"),
          "ticks=%d size=%dx%d" % (len(frames), frames[0].width, frames[0].height))


def anim(path):
    """动图：新档（5.0 s）与现状档（1.05 s）上下两行，都画在同一张真帧上，按各自时刻播。"""
    raw = Image.open(REAL_FRAME).convert("RGB")
    full = F.crt(raw, 1.3, 0.10, 0.25, 0.0, 0.001)
    tracks = []
    for tag, clip_frames, script, use_crt in (("new", ROWS["A"], NEW_SCRIPT, True),
                                              ("cur", CUR_ROW, CUR_SCRIPT, False)):
        name = "anim_%s" % tag
        _register(name, clip_frames)
        cells = []
        for i in range(script["n"]):
            scene = paint_real(raw, name, i, script)
            if use_crt:
                scene = _crt_mixed(scene, script["strength"][i],
                                   F.crt(scene, 1.3, 0.10, 0.25, 0.0, 0.001))
            cells.append(scene.convert("RGB").resize((640, 360), Image.NEAREST))
        _unregister(name)
        tracks.append((tag, cells, script))
    labels = {"new": "D61 新：5.00 s / 16 帧 @ 3.2 fps（A 档 + 举升 + CRT 抖）",
              "cur": "现状 D44：1.05 s / 7 帧 @ 6.7 fps（只飞核心 + 三环，不举人）"}
    row_h, gap = 360, 30
    canvas0 = Image.new("RGB", (640, (row_h + gap) * 2), (10, 12, 16))
    d0 = ImageDraw.Draw(canvas0)
    for n, (tag, _, _) in enumerate(tracks):
        d0.text((8, n * (row_h + gap) + 8), labels[tag], fill=(240, 240, 240), font=GP._font(15))
    times = [[i / script["fps"] for i in range(len(cells))] for _, cells, script in tracks]
    span = max(len(c) / s["fps"] for _, c, s in tracks) + 1.0   # 收尾静一拍，让"演完了"被看见
    ticks = sorted({t for tl in times for t in tl} | {span})
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        for ri, (tag, cells, script) in enumerate(tracks):
            idx = 0
            for i, ti in enumerate(times[ri]):
                if ti <= t + 1e-6:
                    idx = i
            canvas.paste(cells[idx], (0, ri * (row_h + gap) + gap))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.5
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=False)
    print("wrote", os.path.relpath(path, ROOT).replace("\\", "/"),
          "ticks=%d size=%dx%d" % (len(frames), frames[0].width, frames[0].height))


def report():
    """陈述，不裁定：三拍情绪彼此 + 对在册姿态的剪影对称差；CRT 复现对不对得上实机抓帧。"""
    _register("rp", ROWS["A"])
    idle, crouch, wake = G.render("idle", 0), G.render("crouch", 0), G.render("wake", 0)
    for idx, tag in ((3, "QUIZ f3"), (6, "SHOCK f6"), (9, "BURST f9"), (14, "JOY f14"),
                     (15, "END f15")):
        a = G.render("rp", idx)
        e, m = _ink_diff(a, idle)
        print("%-10s vs_idle sil=%4.1f%% eyes=%3dpx mouth=%2dpx | vs_crouch=%4.1f%% "
              "vs_wake=%4.1f%%  widest=%d"
              % (tag, _sym_diff(a, idle), e, m, _sym_diff(a, crouch), _sym_diff(a, wake),
                 _used_w(a)))
    print("frame15 == frame0 of idle:", ROWS["A"][15] == STANCE)
    a = G.render("rp", 9)
    b = _modulate(a, 1.0)
    pa, pb = a.load(), b.load()
    changed = dark = 0
    for y in range(G.FRAME):
        for x in range(G.FRAME):
            if pa[x, y] != pb[x, y]:
                changed += 1
                if sum(pb[x, y][:3]) < 150:
                    dark += 1
    print("D44 glow modulate%s at k=1 on BURST f9: changed=%d px, of which still dark "
          "(sum<150)=%d px" % (GRANT_GLOW, changed, dark))
    for key in ("A", "B", "C"):
        _register("rv%s" % key, ROWS[key])
        assert len(ROWS[key]) == N, "%s has %d frames" % (key, len(ROWS[key]))
        line = []
        for idx in (3, 4, 5, 13, 14):
            e, m = _ink_diff(G.render("rv%s" % key, idx), G.render("rp", idx))
            line.append("f%d sil=%4.1f%% eyes=%2d mouth=%2d"
                        % (idx, _sym_diff(G.render("rv%s" % key, idx), G.render("rp", idx)),
                           e, m))
        print("row %s vs row A   %s   widest=%d"
              % (key, "  ".join(line),
                 max(_used_w(G.render("rv%s" % key, i)) for i in range(N))))
        q, s_, j = (G.render("rv%s" % key, i) for i in (3, 6, 14))
        print("     within-row eye/mouth px: quiz-shock %d/%d  shock-joy %d/%d  "
              "quiz-joy %d/%d"
              % (_ink_diff(q, s_)[0], _ink_diff(q, s_)[1], _ink_diff(s_, j)[0],
                 _ink_diff(s_, j)[1], _ink_diff(q, j)[0], _ink_diff(q, j)[1]))
        _unregister("rv%s" % key)
    _unregister("rp")
    raw = Image.open(REAL_FRAME).convert("RGB")
    print("CRT mirror vs shipped filter:",
          _crt_readout(raw, F.crt(raw, 1.3, 0.10, 0.25, 0.0, 0.001)))
    print("timing: %d frames / %.1f fps = %.2f s, lift peak = %.0f px (%.2f tiles), "
          "frozen look = %.2f s (frames 9..12)"
          % (N, FPS, N / FPS, max(LIFT), max(LIFT) / 16.0, 4 / FPS))
    print("current version for reference: 7 frames / %.2f fps = %.2f s, lift 0 px"
          % (7 / 1.05, 1.05))


def beam_report():
    """六行楔形的收据（全 ASCII：GBK 控制台不打印中文，也不许出现替换字符）。

    两条"铺满"的口径分开给：这张底片里胸口到远角 476 世界 px（相机把祭坛钉在偏右），而实机
    相机跟人、他居中时到四角 = 367 px（视口 640x360 世界 px 的半对角）—— 同一个 ln 在两种
    口径下铺满的时机差很远，混成一条数就会骗人。
    """
    _register("brk", ROWS["A"])
    cx, cy, feet = _chest_dev(BURST_I)
    far = max(math.hypot(cx - x, cy - y) for x, y in
              ((0, 0), (REAL_W, 0), (0, REAL_H), (REAL_W, REAL_H))) / DEV_SCALE
    mid = math.hypot(REAL_W / (2.0 * DEV_SCALE), REAL_H / (2.0 * DEV_SCALE))

    def _k_fill(ln, need):
        if ln <= 0 or need >= ln:
            return float("nan")
        e = need / ln
        return 1.0 - math.sqrt(max(0.0, 1.0 - e))

    print("wedge burst frame: i=%d lift=%.0f px chest_dev=(%d,%d) zoom=%d flash=%s"
          % (BURST_I, LIFT[BURST_I], cx, cy, DEV_SCALE, FLASH_COLOR))
    print("fill distance: this plate (camera pinned, altar right-of-centre) far corner "
          "= %.0f world px; shipped in-game camera (player centred) half-diagonal = %.0f px"
          % (far, mid))
    for key, _label, cfg in BEAM_ROWS:
        a = _beam_coverage(cfg, BURST_I, 0.5, "brk")
        b = _beam_coverage(cfg, BURST_I, 0.95, "brk")
        print("%-4s rays=%2d ang=%4.0f deg reach=%4.0f px  cover@k.5=%5.1f%% "
              "cover@k.95=%5.1f%%  apex-occl=%4.1f%%  fills-plate k=%.2f  fills-centred k=%.2f"
              % (key, len(cfg["rays"]), a["aw"] * 2, a["reach"], a["cover"], b["cover"],
                 a["occl"], _k_fill(a["reach"], far), _k_fill(a["reach"], mid)))
    print("reference: player at burst frame w=34 h=18 px, lift above cap = %.0f px, "
          "shipped spike ink = (206,222,250)" % LIFT[BURST_I])
    _unregister("brk")


def timeline_report():
    """第三轮时间线的收据（全 ASCII）：每一步转多少度、离频闪上限还有多少余量。

    形状那一栏上一轮已经给过，这里不换 —— 这一轮只换了「什么时候在、多粗、朝哪边」。
    """
    _register("tr", ROWS["A"])
    print("timeline: k = frame/9 for frames 0..9, gone from frame 10; widen0=%.2f "
          "fade_in=%.2f spin=%.2f turns (%.1f deg/frame)"
          % (WIDEN0, FADE_IN, SPIN, SPIN * 360.0 / 9.0))
    for key, _label, cfg in _tl_rows():
        n, spacing, step, ok, margin = _spin_step(cfg)
        f1 = _beam_coverage(cfg, 1, BK[1], "tr")
        f7 = _beam_coverage(cfg, 7, BK[7], "tr")
        f9 = _beam_coverage(cfg, BURST_I, 1.0, "tr")
        print("%-4s rays=%2d spacing=%5.1f deg limit=%5.1f step=%4.1f %-9s margin=%4.2fx  "
              "cover f1=%5.1f%% f7=%5.1f%% f9=%5.1f%%  alpha f1=%3d f9=%3d"
              % (key, n, spacing, spacing / 2.0, step, "ok" if ok else "STROBE", margin,
                 f1["cover"], f7["cover"], f9["cover"],
                 _beam_alpha(BK[1], cfg), _beam_alpha(1.0, cfg)))
    _unregister("tr")


def main():
    if len(sys.argv) > 1 and sys.argv[1].lower() in ("chosen", CHOSEN.lower()):
        chosen_sheet(OUT_CHOSEN)      # 只重出选定那一行那两张（全套要跑几分钟）
        chosen_anim(OUT_CHOSEN_GIF)
        final_anim(OUT_FINAL)
        return
    report()
    beam_report()
    timeline_report()
    sheet(OUT_SHEET)
    burst_sheet(OUT_BURST)
    beams_sheet(OUT_BEAMS)
    beams_anim(OUT_BEAMS_GIF)
    timeline_sheet(OUT_TL)
    spin_anim(OUT_SPIN)
    chosen_sheet(OUT_CHOSEN)
    chosen_anim(OUT_CHOSEN_GIF)
    final_anim(OUT_FINAL)
    anim(OUT_GIF)


if __name__ == "__main__":
    main()
