## D58 开局苏醒第二版选型图：用户反馈「1. 动画太快了 2. 和向下压扁的动画几乎一模一样」。
##
## 这张图的唯一任务是让那两条能被眼睛裁：
##   · 每行按自己的 fps 播放，行首标帧数 / fps / 总时长，快慢一眼分得出来；
##   · 最后一行是 `crouch` 循环 —— 被指控"长得一样"的那一档，摆在一起才看得出差在哪。
##
## 画法只有一个来源：候选帧表临时塞进 gen_player_frames 的 FRAMES / CLIPS，再走同一个
## `render()`（同一个 draw_slime、同一条底边波浪相位算式）。这里不重写第二份画法。
##
## 跑法：py tools/gen_wake_preview.py
##   -> assets/player/preview_wake_sheet.png   逐帧胶片，引擎取景 2 倍 + 红色 20x30 碰撞盒
##   -> assets/player/preview_wake_anim.gif    各行同时播放（播放点取所有行切换时刻的并集，
##                                             不按固定 tick 量化，否则 7 fps 那行会被拖慢）
## 末尾打印的三条读数是陈述不是裁定：睡态第 0 帧与 crouch 的形状对称差、最宽帧、总时长。

import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
import gen_player_frames as g
import gen_props as GP        # _font：中文标签要 CJK 字体，PIL 自带那张贴不了汉字

FRAME_H = 96        # 一行的高度（世界像素）：地面线在 76，上方留 20 给弹起那几帧
FLOOR = 76          # 地面线所在的行内 y（= local +15，与 in_game_preview 同一口径）
STEP = 40           # 相邻两格间距（世界像素）
STRIP = 300         # 行首标签条（屏幕像素）
SHEET_ZOOM = 3      # 胶片：再放大一档好读数
GIF_ZOOM = 2        # GIF：PlayerCamera.zoom 的真倍率，"实机就这么大"

# 收帧一律与 idle 第 0 帧一字不差：这段不循环，停在哪一帧就是玩家看见的第一眼。
IDLE0 = dict(w=31, h=25)


def _breathe(base, hs, ws=None, dns=None):
    """睡态的呼吸：只动列出的那几根参数，其余笔画一字不动。"""
    out = []
    for i, h in enumerate(hs):
        f = dict(base)
        f["h"] = h
        if ws:
            f["w"] = ws[i]
        if dns:
            f["dome_lean"] = dns[i]
        out.append(f)
    return out


# V0 = 已落盘那版（7 fps / 8 帧），摆在第一行当被指控的对象。
V0 = [dict(f) for f in g.FRAMES["wake"]]

# V1 侧倒瘫睡：还是"摊平"，但把 crouch 没有的笔画用起来 —— 顶往一侧倒 + 一只小耳塌下去
# （不对称，crouch 是左右对称的），眼皮闭成一条线并滑到低处，呼吸 5 帧慢慢走。
_V1_SLEEP = dict(w=33, h=12, flare=1.06, dome_lean=-5.0, eye_open=0.15,
                 eye_dy=-2.2, eye_scale=0.5, nubs=(1, 0))
V1_WAKE = [
    dict(w=32, h=15, flare=1.08, dome_lean=-3.0, eye_open=1.0, eye_dy=-1.6,
         eye_scale=0.7, nubs=(1, 1)),
    dict(w=30, h=19, flare=1.06, dome_lean=-1.0, eye_open=0.4, eye_dy=-0.4,
         mouth="open", nubs=(1, 1)),
    dict(w=25, h=29, flare=0.88, dome=1.05, eye_dy=0.6, nubs=(0, 0)),
    dict(w=32, h=21, flare=1.06, eye_dy=0.4, nubs=(1, 1)),
    dict(IDLE0),
]
V1 = _breathe(_V1_SLEEP, [12, 12.8, 13.4, 12.8, 12],
              dns=[-5.0, -4.4, -3.8, -4.4, -5.0]) + V1_WAKE

# V2 收团而睡：把"睡"从压扁轴搬到收拢轴 —— 又窄又圆、小耳全收、底裙往里卷。
# 与"往下压扁"（又宽又扁、底裙外翻）在每一根轴上都是反的。
_V2_SLEEP = dict(w=24, h=20, flare=0.86, dome=1.07, eye_open=0.15,
                 eye_dy=-1.2, eye_scale=0.6, nubs=(0, 0))
V2_WAKE = [
    dict(w=25, h=22, flare=0.90, dome=1.05, eye_open=1.0, eye_dy=-0.6,
         eye_scale=0.9, nubs=(1, 1)),
    dict(w=23, h=25, flare=0.92, dome=1.04, eye_open=0.4, eye_dy=0.2,
         mouth="open", nubs=(1, 1)),
    dict(w=24, h=30, flare=0.82, dome=1.06, eye_dy=0.8, nubs=(0, 0)),
    dict(w=32, h=21, flare=1.06, eye_dy=0.6, nubs=(1, 1)),
    dict(IDLE0),
]
V2 = _breathe(_V2_SLEEP, [20, 21, 21.6, 21, 20], ws=[24, 23.4, 23, 23.4, 24]) + V2_WAKE

# V3 = V2 的形 + 打瞌睡点头：顶往前栽两下再惊醒。最有戏也最长。
# 眼睛画不了水平位移，所以点头只由穹顶倒 + 身高回落承担。
V3 = _breathe(_V2_SLEEP, [20, 21, 20.4, 21]) + [
    dict(w=24, h=19, flare=0.88, dome=1.06, dome_lean=4.5, eye_open=0.15,
         eye_dy=-1.4, eye_scale=0.6, nubs=(0, 0)),
    dict(w=24, h=18, flare=0.90, dome=1.05, dome_lean=-1.5, eye_open=0.15,
         eye_dy=-1.6, eye_scale=0.6, nubs=(0, 0)),
    dict(w=24, h=19, flare=0.88, dome=1.06, dome_lean=4.5, eye_open=0.15,
         eye_dy=-1.4, eye_scale=0.6, nubs=(0, 0)),
    dict(w=25, h=21, flare=0.86, dome=1.07, eye_open=0.5, eye_dy=-1.0,
         eye_scale=0.7, nubs=(0, 0)),
] + V2_WAKE[1:]

CROUCH = [(tag, [dict(f) for f in g.FRAMES["crouch"]], 6.0) for tag in
          ["参照 crouch 循环（按住下键；入势那档更深，见 PNG 末行）"]]

ROWS = [
    ("V0 现状（已落盘）摊平 + 闭眼", V0, 7.0),
    ("V1 侧倒瘫睡 + 慢呼吸", V1, 5.0),
    ("V2 收团而睡 + 慢呼吸", V2, 5.0),
    ("V3 V2 收团 + 点头打盹", V3, 5.0),
] + CROUCH

# 只有最后那行参照是循环播的：候选行演完必须钉在末帧，那才是玩家看见的第一眼。
LOOPS = [False] * (len(ROWS) - 1) + [True]


def _register(name, frames, fps):
    """把候选帧表临时塞进生成器的全局表，好复用同一个 render()（含同一条波浪相位算式）。"""
    g.FRAMES[name] = frames
    g.CLIPS[name] = {"loop": False, "fps": fps}


def _unregister(name):
    g.FRAMES.pop(name, None)
    g.CLIPS.pop(name, None)


def _used_w(img):
    box = img.getchannel("A").getbbox()
    return 0 if box is None else box[2] - box[0]


def _slot(name, i, zoom):
    """一格：地面 + 红碰撞盒 + 帧贴在格心（与 in_game_preview 同一条摆位算式）。
    格子宽必须按**画布** 44 px 算而不是按 40 px 的步距 —— 上一版用步距当格宽，
    相邻格互相盖掉右侧 168 px，只剩一条竖条，整张图就成了"帧丢了"。"""
    cell_w = (STEP + 8) * zoom
    img = Image.new("RGB", (cell_w, FRAME_H * zoom), g.CLEAR)
    d = ImageDraw.Draw(img)
    floor = FLOOR * zoom
    d.rectangle([0, floor, img.width, img.height], fill=g.TERRAIN)
    fr = g.render(name, i).convert("RGBA").resize((g.FRAME * zoom, g.FRAME * zoom),
                                                  Image.NEAREST)
    cx = cell_w // 2
    img.paste(fr, (cx - g.FRAME * zoom // 2, floor - (g.FRAME // 2 + 15) * zoom), fr)
    d.rectangle([cx - 10 * zoom, floor - 30 * zoom, cx + 10 * zoom, floor],
                outline=(220, 60, 60, 255))
    return img


def sheet(path, cols):
    """静态胶片：每行一条候选，逐帧铺开，行首标账。"""
    rows = []
    cell_w = (STEP + 8) * SHEET_ZOOM
    for n, (label, frames, fps) in enumerate(ROWS):
        name = "s%d" % n
        _register(name, frames, fps)
        canvas = Image.new("RGB", (STRIP + cols * cell_w, FRAME_H * SHEET_ZOOM), g.CLEAR)
        for i in range(len(frames)):
            canvas.paste(_slot(name, i, SHEET_ZOOM), (STRIP + i * cell_w, 0))
        d = ImageDraw.Draw(canvas)
        widest = max(_used_w(g.render(name, i)) for i in range(len(frames)))
        d.text((10, 20), "%s\n%d 帧 / %.1f fps = %.2f s\n最宽 %d px（上限 36）"
               % (label, len(frames), fps, len(frames) / fps, widest),
               fill=(240, 240, 240), font=GP._font(15))
        rows.append(canvas)
        _unregister(name)
    gap = 8
    out = Image.new("RGB", (max(r.width for r in rows),
                            sum(r.height for r in rows) + gap * (len(rows) - 1)), g.CLEAR)
    y = 0
    for r in rows:
        out.paste(r, (0, y))
        y += r.height + gap
    out.save(path)
    print("wrote", os.path.basename(path))


def gif(path, cols):
    """各行按自己的 fps **原地**同时播（一行一格，眼睛只盯一个位置）；
    演完的行钉在末帧 —— 那就是玩家看见的第一眼。播放点取所有行切换时刻的并集，
    不按固定 tick 量化，否则 7 fps 那行会被 tick 拖慢。"""
    tracks = []
    for n, (label, frames, fps) in enumerate(ROWS):
        name = "a%d" % n
        _register(name, frames, fps)
        cells = [_slot(name, i, GIF_ZOOM) for i in range(len(frames))]
        _unregister(name)
        tracks.append((cells, [i / fps for i in range(len(frames))]))
    span = max(len(f) / fps for _, f, fps in ROWS) + 0.9   # 收尾静一拍，让"演完了"被看见
    ticks = sorted({i / fps for _, f, fps in ROWS for i in range(len(f))} | {span})
    gap = 4
    cell_w = (STEP + 8) * GIF_ZOOM
    canvas0 = Image.new("RGB", (STRIP + cell_w,
                                sum(FRAME_H * GIF_ZOOM for _ in ROWS) + gap * (len(ROWS) - 1)),
                        g.CLEAR)
    d0 = ImageDraw.Draw(canvas0)
    for n, (label, frames, fps) in enumerate(ROWS):
        d0.text((6, n * (FRAME_H * GIF_ZOOM + gap) + 6),
                "%s\n%d 帧 %.1f fps = %.2f s" % (label, len(frames), fps,
                                                 len(frames) / fps),
                fill=(240, 240, 240), font=GP._font(13))
    frames, durs = [], []
    for n, t in enumerate(ticks):
        canvas = canvas0.copy()
        for ri, (cells, times) in enumerate(tracks):
            if LOOPS[ri]:
                idx = int(t * ROWS[ri][2]) % len(cells)      # 参照行循环播，不钉末帧
            else:
                idx = 0
                for i, ti in enumerate(times):
                    if ti <= t + 1e-6:
                        idx = i
            canvas.paste(cells[idx], (STRIP, ri * (FRAME_H * GIF_ZOOM + gap)))
        frames.append(canvas)
        nxt = ticks[n + 1] if n + 1 < len(ticks) else t + 0.5
        durs.append(max(20.0, (nxt - t) * 1000.0))
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=durs, loop=0, optimize=False)
    print("wrote", os.path.basename(path), "ticks=%d" % len(frames))


def report():
    """陈述，不裁定：睡态第 0 帧与 crouch 的形状对称差（越小越像）+ 宽度 + 时长。"""
    cr = g.render("crouch", 0).getchannel("A")
    for label, frames, fps in ROWS[:-1]:
        name = "r%s" % abs(hash(label))
        _register(name, frames, fps)
        a = g.render(name, 0).getchannel("A")
        diff = sum(1 for y in range(a.size[1]) for x in range(a.size[0])
                   if (a.getpixel((x, y)) > 8) != (cr.getpixel((x, y)) > 8))
        print("%-24s 第0帧 vs crouch 差 %.1f%%  最宽 %d px  %.2f s"
              % (label, 100.0 * diff / (a.size[0] * a.size[1]),
                 max(_used_w(g.render(name, i)) for i in range(len(frames))),
                 len(frames) / fps))
        _unregister(name)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cols = max(len(f) for _, f, _ in ROWS)
    sheet(os.path.join(here, "assets", "player", "preview_wake_sheet.png"), cols)
    gif(os.path.join(here, "assets", "player", "preview_wake_anim.gif"), cols)
    report()


if __name__ == "__main__":
    main()
