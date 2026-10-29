#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""D77 梦泡的零件落盘器 —— 单一写手就是选型图那个写手。

**为什么 import 而不是重写一遍画法**：`gen_props` / `gen_tiles` 那条老账（D56「同一块牌不许两处
书写」、D58「选型图必须由落盘那个渲染函数直接生成」）说的是同一件事 —— 出货的皮与批过的图必须
是**同一段代码的两次调用**。所以这里只 import `gen_dream_bubble_preview.bubble_of()`，
一格像素都不重画；构件那边再只画这些 PNG（它自己不算形状），皮就只有一双手写过。

产物：
  assets/props/dream_bubble/<part>_<state>.png   4 只泡 × 4 态（0 = 待按，1..3 = 破的三帧）
  assets/props/dream_bubble.json                 清单：零件尺寸、态数、弧心角度、默认半径、动作映射
**弧的几何也住在清单里**，不住在 GDScript 里 —— 构件读它，`verify_kit` 钉的就是"构件源码里
不许出现第二份半径/角度"（那条"断言不许抄第二份数"的老账在皮这一侧的对应物）。

用法：  py tools/gen_dream_bubble_parts.py
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_dream_bubble_preview as P      # 皮与弧的唯一写手

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "props", "dream_bubble")
MANIFEST = os.path.join(ROOT, "assets", "props", "dream_bubble.json")

STATES = 4                                 # 0 = 待按；1..3 = 破的那一拍（不循环）
# 清单里的一条 = 一只泡：动作名（InputMap 的，不是 keycode）、零件名、弧上角度
BUBBLES = [
    {"action": "move_left", "part": "a", "deg": 160},
    {"action": "move_down", "part": "s", "deg": 120},
    {"action": "jump", "part": "space", "deg": 60},
    {"action": "move_right", "part": "d", "deg": 20},
]
RADIUS = 56                                # 他 2026-10-29 按图挑的那一档（贴着人、贴边重生时零 clamp）
## 弧心相对**玩家节点原点**的偏移。原点不是脚底，是碰撞盒中心（`player.tscn` 的
## `CollisionShape2D` 无 offset；`Player.COLLISION_HALF_HEIGHT = 15` ⇒ 脚底在 +15）。
## 睡姿头顶 ≈ 脚底往上 20 ⇒ 15 - 20 = -5。
ARC_ORIGIN_Y = -5


def emit():
    skin = P.SKINS[P.SHIPPED]
    os.makedirs(OUT_DIR, exist_ok=True)
    parts = {}
    for entry in BUBBLES:
        key = entry["part"]
        name = P.BEST_SPACE if key == "space" else key.upper()
        for frame in range(STATES):
            pixels, w, h = P.bubble_of(name, skin, frame)
            img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            for (x, y), c in pixels.items():
                img.putpixel((x, y), tuple(c) + (255,))
            img.save(os.path.join(OUT_DIR, "%s_%d.png" % (key, frame)))
            if frame == 0:
                parts[key] = [w, h]
            else:
                assert parts[key] == [w, h], "%s 第 %d 态尺寸变了：构件得按格对齐" % (key, frame)
    manifest = {
        "style": P.SHIPPED,
        "states": STATES,
        "radius": RADIUS,
        "arc_origin_y": ARC_ORIGIN_Y,
        "bubbles": BUBBLES,
        "parts": parts,
    }
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
    print("saved %d 张 PNG + %s" % (len(BUBBLES) * STATES, MANIFEST))
    for k, v in parts.items():
        print("  %s_%d.png = %dx%d" % (k, 0, v[0], v[1]))


if __name__ == "__main__":
    emit()
