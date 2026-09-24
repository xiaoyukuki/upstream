"""生成主角（黑色流体小史莱姆）的像素动画序列帧。

用法：py tools/gen_player_frames.py
产物：assets/player/slime/<clip>_<n>.png（44x44 RGBA，逐帧独立文件）
      assets/player/slime_contact.png（所有帧的检视图）
      assets/player/slime_ingame.png（按引擎 2 倍取景 + 叠碰撞盒的合成图）
      assets/player/slime_anim.gif（各段剪辑按各自 fps 连播）
      以上三张预览只给人眼看，不进引擎。

为什么用代码画而不是用图像模型生成：需要的是定尺寸、脚底对齐同一条基线、
带真 alpha、调色板逐帧一致的帧。生成式模型给的是高分辨率、无透明通道、
每个姿势轮廓尺寸都不一样的图，切片后逐帧抖动。代码画的帧由同一组参数
（宽高、挤压、眼神方向）驱动，改数值就能重出，像素画师后续逐帧替换也不动接线。
"""

import json
import math
import os
from PIL import Image, ImageDraw

FRAME = 44    # 最宽帧 33 px；画布要留出前倾剪切把整团质量甩向一侧时的单侧余量，否则亮边被切（check_fit 拦）
DOME_RX = 0.42  # 穹顶半宽 / 身体宽。越小下摆越往外翻成圆弧（水母钟形），越大肩越撑、底边越平
DOME_CY = 0.68  # 穹顶椭圆中心在身高上的位置（自上而下），同时决定穹顶的短轴
BOTTOM = FRAME / 2.0 + 14.0  # 身体底边的基线（也是脚趾那一行的下边界）。任何一列都不许抬到基线之下
LAMBDA = 11.0  # 底边波浪的波长（px）：约等于站姿宽的 1/3，一列起伏不会糊成锯齿
WAVE_AMP_MAX = 3.0
WAVE_AMP_MIN = 1.6

PAL = {
    "outline": (4, 4, 4, 255),
    "rim_bright": (193, 211, 223, 255),
    "rim_mid": (103, 109, 123, 255),
    "rim_dim": (58, 64, 72, 255),
    "body": (10, 12, 12, 255),
    "body_up": (26, 28, 33, 255),
    "skirt": (45, 49, 56, 255),
    "spec": (193, 211, 223, 255),
    "spec_soft": (103, 109, 123, 255),
    "eye": (254, 255, 249, 255),
    "mouth": (242, 162, 171, 255),
    "mouth_dark": (203, 116, 130, 255),
}

CLIPS = {
    "wake": {"loop": False, "fps": 7.0},
    "idle": {"loop": True, "fps": 6.0},
    "run": {"loop": True, "fps": 14.0},
    "start": {"loop": False, "fps": 16.0},
    "stop": {"loop": False, "fps": 16.0},
    "jump": {"loop": False, "fps": 12.0},
    "jump_straight": {"loop": False, "fps": 12.0},
    "fall": {"loop": True, "fps": 8.0},
    "land": {"loop": False, "fps": 22.0},
    "crouch_in": {"loop": False, "fps": 16.0},
    "crouch": {"loop": True, "fps": 6.0},
    "crouch_out": {"loop": False, "fps": 16.0},
    "wall_press_in": {"loop": False, "fps": 18.0},
    "wall_press": {"loop": True, "fps": 6.0},
    "wall_press_out": {"loop": False, "fps": 16.0},
}


def ellipse(cx, cy, rx, ry):
    return {"cx": cx, "cy": cy, "rx": max(rx, 0.5), "ry": max(ry, 0.5)}


def inside(e, x, y):
    dx = (x - e["cx"]) / e["rx"]
    dy = (y - e["cy"]) / e["ry"]
    return dx * dx + dy * dy <= 1.0


def draw_slime(w, h, lean=0.0, dome_lean=0.0, eye_open=1.0, eye_dy=0.0, eye_scale=1.0,
               mouth="smile", nubs=(1, 1), flare=1.0, dome=1.0, wave_offset=0.0,
               wall_clip=0.0, taper=1.0):
    """画一帧。w/h = 身体轮廓宽与高（不含脚趾），lean = 整体水平位移，
    dome_lean = 头顶相对脚底的水平剪切位移（脚底粘地不动，越往上摆越多），
    dome/flare = 顶部与底裙的收窄系数，eye_open = 眨眼开度，eye_scale = 压扁缩放
    （整团被压时眼睛跟着变扁），wave_offset = 底边波浪的相位起点。
    wall_clip > 0 = 贴墙压平：把前/右侧轮廓切在 FRAME/2 + wall_clip 这一列。切线钉在画布上
    而不是钉在 cx 上，所以 lean 照常把整团往墙里送或往背面拽，切线始终等于碰撞盒边界；
    taper = 接触面上下两端各让开的像素数（竖切椭圆会得到两个直角，读作被遮罩切掉）。"""
    img = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    px = img.load()

    cx = FRAME / 2.0 + lean
    top = BOTTOM - h
    L = h

    # 幅度：站姿 1.9 px 已经能跨过两条像素阈值（0.5/1.5）走出三级起伏；越扁涨得越凶，腾空拉长时收平。
    amp = min(WAVE_AMP_MAX, max(WAVE_AMP_MIN, 1.9 + (24.0 - h) * 0.11))
    # 只往上抬、绝不越过基线，所以脚底对齐与轮廓高度都不受波动影响。
    lifts = [amp * 0.5 * (1.0 - math.cos(2.0 * math.pi * (c + 0.5 - wave_offset) / LAMBDA))
             for c in range(FRAME)]

    def shear_at(y):
        """该高度上的水平剪切位移。脚底为 0（粘地），头顶为 dome_lean；k² 让下半身比上半身稳。"""
        k = max(0.0, (BOTTOM - y) / L)
        return dome_lean * k * k

    dome_e = ellipse(cx, top + L * DOME_CY, w * DOME_RX * dome, L * DOME_CY)
    base_e = ellipse(cx, BOTTOM - L * 0.38, w * 0.50 * flare, L * 0.38)

    mask = set()
    wall_x = FRAME / 2.0 + wall_clip if wall_clip > 0.0 else None
    for r in range(FRAME):
        y = r + 0.5
        if wall_x is None:
            clip_x = None
        else:
            k = min(1.0, max(0.0, (BOTTOM - y) / L))
            clip_x = wall_x - taper * (1.0 - math.sin(math.pi * k))
        for c in range(FRAME):
            if y >= BOTTOM - lifts[c]:  # 穹顶椭圆的下缘本来就超出基线，逐列按波抬起裁（旧版是一刀切平的）
                continue
            if clip_x is not None and c + 0.5 > clip_x:  # 贴墙压平：切线之外的部分进了墙，不画
                continue
            off = shear_at(y)
            x = c + 0.5 - off
            if inside(dome_e, x, y) or inside(base_e, x, y):
                mask.add((c, r))

    # 逐列最低不透明行：亮边、底裙、脚趾都改挂到它上面，底边一涨落这几层就跟着一起涨落
    lowest = {}
    for c, r in mask:
        if r > lowest.get(c, -1):
            lowest[c] = r

    def eroded(p):
        c, r = p
        for dc in (-1, 0, 1):
            for dr in (-1, 0, 1):
                if (c + dc, r + dr) not in mask:
                    return False
        return True

    interior = {p for p in mask if eroded(p)}
    outline = mask - interior
    body_cy = top + L * 0.5

    # 轮廓：只有朝下的边接亮边（地面反弹光），侧下接中灰，左上偏暗灰，其余纯黑
    # 亮边改挂在逐列最低行上 —— 否则底边一涨落，亮边就脱离轮廓变成悬空的一条横线
    for c, r in outline:
        dx = (c + 0.5 - (cx + shear_at(r + 0.5))) / (w * 0.5 + 1.0)
        dy = (r + 0.5 - body_cy) / (L * 0.5 + 1.0)
        if r == lowest[c]:
            col = PAL["rim_bright"]
        elif dy > 0.55:
            col = PAL["rim_mid"]
        elif dx < -0.6 and dy < 0.2:
            col = PAL["rim_dim"]
        else:
            col = PAL["outline"]
        px[c, r] = col

    # 身体：主体近黑，只有最底一小圈提亮成底裙。带子按各列自己的底边量，
    # 波谷那一列 edge == BOTTOM，与旧版一字不差；波峰那一列跟着底边一起往上收。
    for c, r in interior:
        y = r + 0.5
        edge = lowest[c] + 1.0
        if y > edge - L * 0.07:
            col = PAL["skirt"]
        elif y > edge - L * 0.12:
            col = PAL["body_up"]
        else:
            col = PAL["body"]
        px[c, r] = col

    # 高光：左上柔光斑 + 更亮的小核
    soft = ellipse(cx - w * 0.18 + shear_at(top + L * 0.22), top + L * 0.22, w * 0.13, L * 0.075)
    core = ellipse(cx - w * 0.19 + shear_at(top + L * 0.21), top + L * 0.21, w * 0.075, L * 0.042)
    for c, r in interior:
        x, y = c + 0.5, r + 0.5
        if inside(core, x, y):
            px[c, r] = PAL["spec"]
        elif inside(soft, x, y):
            px[c, r] = PAL["spec_soft"]

    # 脚趾：贴在所在列身体最底行的下一行，跟着底边一起涨落（挂死在基线上会露出悬空的黑点）
    for i, sign in enumerate((-1, 1)):
        if nubs[i] <= 0:
            continue
        nx = int(round(cx + sign * (w * 0.17)))
        for c in (nx - 1, nx):
            if c not in lowest:
                continue
            px[c, lowest[c] + 1] = PAL["outline"]

    # 眼睛：圆角方块，落在黑色穹顶里；eye_open 控制眨眼下压，eye_scale 再乘一道压扁
    eye_h = max(1, int(round(5.0 * eye_open * eye_scale)))
    eye_y = top + L * 0.54 + eye_dy
    eye_cx = cx + shear_at(eye_y)
    e0 = int(math.floor(eye_y - eye_h / 2.0))
    for sign in (-1, 1):
        ex = int(round(eye_cx + sign * (w * 0.185) - 2.0))
        for r in range(e0, e0 + eye_h):
            for c in range(ex, ex + 4):
                if not (0 <= c < FRAME and 0 <= r < FRAME):
                    continue
                if eye_h >= 4 and r in (e0, e0 + eye_h - 1) and c in (ex, ex + 3):
                    continue
                px[c, r] = PAL["eye"]

    # 嘴
    my = int(round(eye_y + 3))
    mx = int(round(cx + shear_at(my + 0.5)))
    if mouth == "smile":
        px[mx, my] = PAL["mouth"]
        px[mx + 1, my] = PAL["mouth"]
        px[mx, my + 1] = PAL["mouth_dark"]
    elif mouth == "open":
        for r in (my, my + 1):
            for c in (mx, mx + 1):
                px[c, r] = PAL["mouth"] if r == my else PAL["mouth_dark"]
    return img


# ---- 帧表：每帧就是一组参数，改数值即可重出 ----
# 造型基线：站姿参数 31x25，含轮廓与脚趾的实测轮廓 32x26（旧版 26x28）。
# 高度不能再降，否则 20x30 碰撞盒的顶边会露在美术之外；宽度不能再加，第一章最小门洞 40 px。
# 行进方向的读法全靠 dome_lean：头顶相对脚底的剪切位移，正 = 往前扑，负 = 往后甩。
FRAMES = {
    # 开局苏醒（D57）：零文字，所以"睡着"只能由形状与眼睛开合说 —— 一坨摊平的身体 +
    # 闭成一条缝的眼皮，呼吸就靠那两帧几乎一样的起伏。第三条嘴（现成的 2x2 mouth="open"）
    # 是哈欠，不是新零件。最后两帧是弹过头再压回来，收帧参数与 idle 第 0 帧一字不差，
    # 演完交回循环时接缝才看不出跳（这段是不循环的，停在哪一帧就是玩家看见的第一眼）。
    # 摊平那帧 w=35 是守门第 3 组"全剪辑最宽 ≤36 px"给的上限（那条钉的是 40 px 最小门洞）。
    "wake": [
        dict(w=34, h=9, flare=1.04, eye_open=0.2, eye_dy=-1.0, nubs=(1, 1)),
        dict(w=33, h=11.5, flare=1.04, eye_open=0.2, eye_dy=-1.2, nubs=(1, 1)),
        dict(w=34, h=9.5, flare=1.04, eye_open=0.2, eye_dy=-1.1, nubs=(1, 1)),
        dict(w=32, h=14, flare=1.04, eye_open=0.5, eye_dy=-1.2, nubs=(1, 1)),
        dict(w=30, h=18, flare=1.06, dome_lean=-2.0, eye_dy=-0.6,
             mouth="open", nubs=(1, 1)),
        dict(w=26, h=27, flare=0.92, dome=1.05, eye_dy=0.4, mouth="open", nubs=(0, 0)),
        dict(w=32, h=21, flare=1.06, eye_dy=0.6, nubs=(1, 1)),
        dict(w=31, h=25, nubs=(1, 1)),
    ],
    "idle": [
        dict(w=31, h=25),
        dict(w=31, h=24),
        dict(w=31, h=23.5, eye_dy=0.6),
        dict(w=31, h=23, eye_dy=0.8),
        dict(w=31, h=24, eye_dy=0.4),
        dict(w=31, h=25, eye_open=0.5),
        dict(w=31, h=25, eye_open=0.16),
        dict(w=31, h=25),
    ],
    "run": [
        dict(w=31, h=20, flare=1.06, lean=1.5, dome_lean=4.0, eye_dy=-0.4, nubs=(1, 0)),
        dict(w=30, h=22, flare=1.04, lean=1.5, dome_lean=5.0, eye_dy=-0.2, nubs=(1, 0)),
        dict(w=27, h=25, flare=0.96, dome=1.02, lean=2.0, dome_lean=4.5, eye_dy=0.4, nubs=(0, 1)),
        dict(w=25, h=26, flare=0.92, dome=1.04, lean=2.0, dome_lean=3.5, eye_dy=0.6, nubs=(0, 1)),
        dict(w=29, h=23, flare=1.0, lean=1.5, dome_lean=2.5, eye_dy=0.2, nubs=(0, 1)),
        dict(w=31, h=20, flare=1.06, lean=1.5, dome_lean=4.0, eye_dy=-0.4, nubs=(1, 1)),
    ],
    "start": [
        dict(w=30, h=24, flare=1.0, lean=-1.0, dome_lean=-2.5, eye_dy=0.8, nubs=(1, 1)),
        dict(w=31, h=22, flare=1.04, lean=-1.5, dome_lean=-5.0, eye_dy=1.4, nubs=(1, 1)),
        dict(w=31, h=21, flare=1.06, lean=0.5, dome_lean=2.0, eye_dy=-0.2, nubs=(1, 1)),
    ],
    "stop": [
        dict(w=31, h=20, flare=1.06, lean=1.5, dome_lean=5.0, eye_dy=-0.6, mouth="open", nubs=(1, 1)),
        dict(w=30, h=22, flare=1.04, lean=1.0, dome_lean=3.0, eye_dy=0.2, nubs=(1, 1)),
        dict(w=29, h=25, flare=1.0, lean=0.0, dome_lean=-1.5, eye_dy=0.6, nubs=(1, 1)),
    ],
    "jump": [
        dict(w=25, h=28, flare=0.86, dome=1.04, lean=0.5, dome_lean=1.0, eye_dy=0.6,
             mouth="open", nubs=(0, 0)),
        dict(w=23, h=30, flare=0.80, dome=1.06, lean=1.0, dome_lean=1.5, eye_dy=0.8,
             mouth="open", nubs=(0, 0)),
    ],
    # 原地起跳：水平动量为零，所以整团不许往前甩（lean / dome_lean 直接归零 —— 不保留
    # 「一点点」，原地跳看得出倾斜就等于告诉玩家他在横移，而这一本作里「有没有横移」
    # 恰好等于「世界冻没冻」，这条读法不能糊）。拉伸全交给更窄 + 更收的底裙。
    # h 上限仍取 30 = 站姿盒顶，腾空美术不高出碰撞盒（D23 同一条契约）。
    "jump_straight": [
        dict(w=24, h=29, flare=0.84, dome=1.05, eye_dy=0.6, mouth="open", nubs=(0, 0)),
        dict(w=22, h=30, flare=0.76, dome=1.07, eye_dy=0.8, mouth="open", nubs=(0, 0)),
    ],
    "fall": [
        dict(w=30, h=22, flare=1.02, dome=1.02, dome_lean=-1.0, eye_dy=-0.4, nubs=(1, 0)),
        dict(w=31, h=19, flare=1.04, dome=1.04, dome_lean=-1.5, eye_dy=-0.8, mouth="open", nubs=(0, 1)),
        dict(w=30, h=21, flare=1.02, dome=1.02, dome_lean=-1.0, eye_dy=-0.6, nubs=(1, 1)),
    ],
    "land": [
        # 最深帧压到 h=12：重落地（含蹲着落地）读作整团拍扁。脸必须跟着用负 eye_dy 收上去，
        # 否则眼睛嘴会悬在被波浪裁掉的下半身之外（脸是无视轮廓直接盖章的）。
        dict(w=32, h=12, flare=1.08, dome=1.06, eye_dy=-2.0, eye_open=0.5, eye_scale=0.6,
             mouth="open", nubs=(1, 1)),
        dict(w=30, h=20, flare=1.0, dome=1.04, eye_dy=0.6, mouth="open", nubs=(1, 1)),
        dict(w=27, h=26, flare=0.94, dome=1.02, eye_dy=-0.6, nubs=(0, 0)),
        dict(w=30, h=24, flare=1.0, eye_dy=0.2, nubs=(1, 0)),
    ],
    # 按住下键贴地压扁（纯表现，碰撞盒不动）：入 3 帧、循环 4 帧、出 2 帧。
    # 深度帧 eye_dy 为负 —— 脸只能待在永远裁不到的 32 行以上，嘴同理。
    # eye_scale 让眼睛跟着整团一起变扁：5px → 3px → 2px，起身时倒放。
    "crouch_in": [
        dict(w=31, h=20, flare=1.04, eye_dy=0.6, nubs=(1, 1)),
        dict(w=31, h=15, flare=1.08, eye_dy=-1.0, eye_open=0.7, eye_scale=0.8, nubs=(1, 1)),
        dict(w=30, h=12, flare=1.1, eye_dy=-2.5, eye_open=0.6, eye_scale=0.55,
             mouth="open", nubs=(1, 1)),
    ],
    "crouch": [
        dict(w=30, h=12, flare=1.1, eye_dy=-2.5, eye_open=0.6, eye_scale=0.55, nubs=(1, 1)),
        dict(w=30, h=12.5, flare=1.1, eye_dy=-2.5, eye_open=0.6, eye_scale=0.55, nubs=(1, 1)),
        dict(w=30, h=13, flare=1.1, eye_dy=-2.5, eye_open=0.6, eye_scale=0.55, nubs=(1, 1)),
        dict(w=30, h=12.5, flare=1.1, eye_dy=-2.5, eye_open=0.6, eye_scale=0.55, nubs=(1, 1)),
    ],
    "crouch_out": [
        dict(w=31, h=15, flare=1.08, eye_dy=-1.0, eye_open=0.7, eye_scale=0.8, nubs=(1, 1)),
        dict(w=31, h=20, flare=1.04, eye_dy=0.6, nubs=(1, 1)),
    ],
    # 推墙时贴墙一侧压平到碰撞盒边界（D23）：wall_clip=10 就是盒的右边界，切掉的质量
    # 靠抬高 h 与加宽背面 w 补回来，h 上限 28 —— 再高轮廓就顶穿 20x30 盒顶（= 骗玩家头顶有空间）。
    # 只切一侧是刻意的：两侧都收到 ±10 会得到 20x28 的柱子，正是被否决过的「细长」。
    # 帧一律按「朝右、墙在右侧」作画，镜像由 _visual.scale.x 负责，不需要第二套。
    "wall_press_in": [
        dict(w=34, h=22, wall_clip=10.0, taper=0.8, flare=1.08, lean=1.0, dome_lean=3.0,
             eye_dy=-0.4, eye_scale=0.9, mouth="open", nubs=(1, 1)),
        dict(w=33, h=25, wall_clip=10.0, taper=1.0, flare=1.05, lean=1.5, dome_lean=2.0,
             eye_dy=0.2, nubs=(1, 1)),
    ],
    "wall_press": [
        dict(w=33, h=26, wall_clip=10.0, taper=1.0, flare=1.05, lean=1.5, dome_lean=1.5,
             eye_dy=0.2, nubs=(1, 1)),
        dict(w=32, h=28, wall_clip=10.0, taper=1.0, flare=1.03, lean=1.5, dome_lean=2.0,
             eye_dy=0.0, nubs=(1, 1)),
    ],
    "wall_press_out": [
        dict(w=32, h=25, wall_clip=10.0, taper=1.0, flare=1.02, lean=-1.0, dome_lean=-2.0,
             eye_dy=0.4, nubs=(1, 1)),
        dict(w=31, h=25, flare=1.0, lean=-1.5, dome_lean=-2.5, eye_dy=0.6, nubs=(1, 1)),
    ],
}


def render(clip, i):
    """取帧表参数并补上底边波浪的相位。
    相位步长取 LAMBDA / 帧数 —— 一个循环正好走完一个波长，循环接缝处才不跳波。"""
    f = dict(FRAMES[clip][i])
    f["wave_offset"] = i * LAMBDA / len(FRAMES[clip])
    return draw_slime(**f)


def contact_sheet(out, scale=8, cols=6):
    names = [(c, i) for c, fr in FRAMES.items() for i in range(len(fr))]
    rows = (len(names) + cols - 1) // cols
    cell = FRAME * scale
    W = cols * (cell + 8) + 8
    H = rows * (cell + 8 + 18) + 8
    sheet = Image.new("RGB", (W, H), (190, 198, 210))
    d = ImageDraw.Draw(sheet)
    for n, (clip, i) in enumerate(names):
        r, c = divmod(n, cols)
        x = 8 + c * (cell + 8)
        y = 8 + r * (cell + 8 + 18)
        img = render(clip, i).convert("RGBA")
        img = img.resize((cell, cell), Image.NEAREST)
        sheet.paste(img, (x, y), img)
        d.text((x + 4, y + cell + 2), "%s_%d" % (clip, i), fill=(20, 24, 30))
    sheet.save(out)


CLEAR = (77, 77, 89)      # 引擎默认 2D 清屏色 Color(0.3,0.3,0.35)
TERRAIN = (82, 89, 107)   # platform.gd 默认色 Color(0.32,0.35,0.42)
ZOOM = 2                  # PlayerCamera.zoom = 2 -> 1 世界像素 = 2 屏幕像素


def in_game_preview(out):
    """按引擎里的真实取景（2 倍放大）摆一遍帧，并叠上 20x30 碰撞盒，检查美术与碰撞的相对位置。
    seq 每项是 (clip, i, wall)；wall=True 的格子会在碰撞盒右边界外贴一块墙 —— 用来肉眼验
    贴墙压平有没有真的收进盒内。墙必须先画、帧后贴，否则墙会把越界的部分盖掉，预览就白做了。"""
    seq = [(c, i, False) for c, i in
           [("wake", i) for i in range(8)]
           + [("idle", i) for i in range(8)] + [("run", i) for i in range(6)]] + [
        ("jump", 1, False), ("jump_straight", 0, False), ("jump_straight", 1, False),
        ("fall", 1, False), ("land", 0, False),
        ("crouch_in", 2, False), ("crouch", 0, False), ("crouch_out", 0, False),
        ("wall_press_in", 0, True), ("wall_press_in", 1, True),
        ("wall_press", 0, True), ("wall_press", 1, True),
        ("wall_press_out", 0, True), ("wall_press_out", 1, True)]
    step = 40
    W = (len(seq) + 2) * step * ZOOM
    H = 120 * ZOOM
    img = Image.new("RGB", (W, H), CLEAR)
    d = ImageDraw.Draw(img)
    floor_y = 90 * ZOOM                      # 地面线：local y = +15 处
    d.rectangle([0, floor_y, W, H], fill=TERRAIN)
    for n, (clip, i, wall) in enumerate(seq):
        cx = (n + 1) * step * ZOOM
        if wall:
            d.rectangle([cx + 10 * ZOOM, floor_y - 40 * ZOOM, cx + 24 * ZOOM, floor_y], fill=TERRAIN)
        frame = render(clip, i).convert("RGBA")
        frame = frame.resize((FRAME * ZOOM, FRAME * ZOOM), Image.NEAREST)
        # 帧内 local 原点在画布中心，脚趾行底边在 local +15 -> 原点落在 floor 上方 15 世界像素
        img.paste(frame, (cx - FRAME * ZOOM // 2, floor_y - (FRAME // 2 + 15) * ZOOM), frame)
        d.rectangle([cx - 10 * ZOOM, floor_y - 30 * ZOOM, cx + 10 * ZOOM, floor_y],
                    outline=(220, 60, 60, 255))
    d.text((8, 8), "red = 20x30 collider / grey = ground+wall", fill=(240, 240, 240))
    img.save(out)


def check_fit():
    """任何一帧只要有不透明像素压到画布边缘，就说明轮廓被画布切掉了。"""
    bad = []
    for clip, frames in FRAMES.items():
        for i in range(len(frames)):
            alpha = render(clip, i).split()[3]
            w, h = alpha.size
            edge = ([alpha.getpixel((x, 0)) for x in range(w)]
                    + [alpha.getpixel((x, h - 1)) for x in range(w)]
                    + [alpha.getpixel((0, y)) for y in range(h)]
                    + [alpha.getpixel((w - 1, y)) for y in range(h)])
            if max(edge) > 0:
                bad.append("%s_%d" % (clip, i))
    if bad:
        raise SystemExit("帧被画布边缘切掉：%s —— 需要加大 FRAME 或收窄参数" % ", ".join(bad))


def anim_preview(out, scale=6):
    """把各段剪辑按各自的 fps 连起来放一遍，不启动引擎就能看动效。
    wall_press 三段会在右侧先画一块墙（先墙后帧，越界才看得见），
    所以 out 那一帧故意留着 6 px 越界 —— 那是 D23 后果二「松手回弹到全宽」的样子。"""
    imgs, durs = [], []
    ground = (FRAME // 2 + 15) * scale  # local y=+15 所在的屏幕行
    wall_x = (FRAME // 2 + 10) * scale  # 碰撞盒右边界所在的屏幕列
    for clip in ("wake", "idle", "crouch_in", "crouch", "crouch_out", "start", "run", "stop",
                 "wall_press_in", "wall_press", "wall_press_out", "jump", "jump_straight",
                 "fall", "land"):
        walled = clip.startswith("wall_press")
        for i in range(len(FRAMES[clip])):
            frame = Image.new("RGB", (FRAME * scale, FRAME * scale), CLEAR)
            d = ImageDraw.Draw(frame)
            d.rectangle([0, ground, FRAME * scale, FRAME * scale], fill=TERRAIN)
            if walled:
                d.rectangle([wall_x, 0, FRAME * scale, ground], fill=TERRAIN)
            img = render(clip, i).convert("RGBA").resize((FRAME * scale, FRAME * scale), Image.NEAREST)
            frame.paste(img, (0, 0), img)
            imgs.append(frame)
            durs.append(1000.0 / CLIPS[clip]["fps"])
    imgs[0].save(out, save_all=True, append_images=imgs[1:], duration=durs, loop=0, optimize=False)


def main():
    check_fit()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(here, "assets", "player", "slime")
    os.makedirs(out_dir, exist_ok=True)
    total = 0
    manifest = {}
    for name, frames in FRAMES.items():
        for i in range(len(frames)):
            render(name, i).save(os.path.join(out_dir, "%s_%d.png" % (name, i)))
            total += 1
        manifest[name] = {"fps": CLIPS[name]["fps"], "loop": CLIPS[name]["loop"], "frames": len(frames)}
        print("%-6s %2d frames" % (name, len(frames)))
    with open(os.path.join(out_dir, "clips.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)
    contact_sheet(os.path.join(here, "assets", "player", "slime_contact.png"))
    in_game_preview(os.path.join(here, "assets", "player", "slime_ingame.png"))
    anim_preview(os.path.join(here, "assets", "player", "slime_anim.gif"))
    print("wrote %d frames -> assets/player/slime/" % total)


if __name__ == "__main__":
    main()
