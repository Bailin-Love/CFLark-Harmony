#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CFLark 图标资源生成器（源码）

用途
----
一次生成 CFLark 的全部图标位图：
  1) 桌面/应用图标（layered_image）：foreground.png + background.png
     - light 版：浅色玻璃底板（当前线上采用的版本，顶部带一点紫调）
     - navy  版：深海军蓝底板 + 发光玻璃鸟（备选 A 版）
  2) 启动页图标（splash_icon）：base 与 dark 两套，两套 alpha 逐像素一致，
     保证系统缩放到同一目标框，深浅两模式的图标大小/位置完全相同。

依赖：Python 3.9+、Pillow（`pip install pillow`）

用法
----
  python tools/gen_app_icon.py --style light          # 生成浅色底板（线上版本）
  python tools/gen_app_icon.py --style navy           # 生成深色底板（备选 A 版）
  python tools/gen_app_icon.py --style light --splash # 同时重建启动页图标
  python tools/gen_app_icon.py --style light --dry-run  # 只写 _verify/out，不改工程资源

输入素材
--------
- --logo : 高清 logo 源图，默认 _verify/splash_base_orig.png
           （1024×1024 RGBA，内容框约 (237,232)-(801,807)）
- --wave : 波浪纹理源图，默认 _verify/icon_bg_orig.png
           （旧版背景图，只取它底部 0.72 以下的纯净波浪带）

输出
----
- entry/src/main/resources/base/media/{foreground,background,splash_icon}.png
- entry/src/main/resources/dark/media/splash_icon.png
- AppScope/resources/base/media/{foreground,background}.png
- _verify/out/ 下始终留一份预览图（fg/bg 各版本），便于快速对比
"""

import argparse
import math
import os
import shutil
import sys

try:
    from PIL import Image, ImageEnhance, ImageFilter
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow：pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRY_MEDIA = os.path.join(ROOT, "entry/src/main/resources/base/media")
DARK_MEDIA = os.path.join(ROOT, "entry/src/main/resources/dark/media")
APP_MEDIA = os.path.join(ROOT, "AppScope/resources/base/media")
OUT_DIR = os.path.join(ROOT, "_verify/out")

CANVAS = 1024           # layered image 与 splash 的画布尺寸
LOGO_BOX = (237, 232, 801, 807)   # 高清 logo 的内容框
SOLID_RATIO = 0.66      # 前景「实心区」占画布比例（图标安全区）
SPLASH_ALPHA_GAMMA = 1.6          # 启动页图标 alpha 曲线（深浅两版共用）


# --------------------------------------------------------------------------
# 通用小工具
# --------------------------------------------------------------------------
def solid_bbox(img, threshold=200):
    """alpha >= threshold 的区域外框。"""
    alpha = img.getchannel("A")
    px = alpha.load()
    w, h = img.size
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if px[x, y] >= threshold:
                xs.append(x)
                ys.append(y)
    if not xs:
        raise ValueError("图像没有实心像素，检查输入素材")
    return min(xs), min(ys), max(xs), max(ys)


def vertical_gradient(size, stops):
    """按 [(位置0~1, (r,g,b)), ...] 生成竖向渐变。stops 需按位置升序。"""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        color = stops[-1][1]
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                k = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
                color = tuple(int(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
                break
        for x in range(w):
            px[x, y] = color
    return img


def add_center_glow(img, center, radius, strength, tint=(255, 255, 255), power=1.8):
    """在 (cx, cy) 处叠一层径向柔光；tint 决定光色。"""
    w, h = img.size
    px = img.load()
    cx, cy = center[0] * w, center[1] * h
    rx, ry = radius[0] * w, radius[1] * h
    for y in range(h):
        for x in range(w):
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            d = math.sqrt(dx * dx + dy * dy)
            g = max(0.0, 1.0 - d) ** power * strength
            if g <= 0:
                continue
            r, gg, b = px[x, y]
            px[x, y] = (
                min(255, int(r + tint[0] * g)),
                min(255, int(gg + tint[1] * g)),
                min(255, int(b + tint[2] * g)),
            )
    return img


def add_vignette(img, strength=0.16, power=1.5):
    w, h = img.size
    px = img.load()
    for y in range(h):
        for x in range(w):
            dx = (x - w / 2) / (w / 2)
            dy = (y - h / 2) / (h / 2)
            d = math.sqrt(dx * dx + dy * dy) / 1.414
            k = 1.0 - strength * (d ** power)
            r, g, b = px[x, y]
            px[x, y] = (int(r * k), int(g * k), int(b * k))
    return img


def paint_wave(plate, wave_src, ratio=0.38, opacity=1.0, colorize=None,
               mask_power=1.05, sat=1.40, con=1.12, blur=0.5):
    """把 wave_src 底部的纯净波浪带贴到 plate 底部。"""
    w, h = plate.size
    band = wave_src.crop((0, int(wave_src.height * 0.72), wave_src.width, wave_src.height))
    band = band.resize((w, int(h * ratio)), Image.LANCZOS)
    band = ImageEnhance.Color(band).enhance(sat)
    band = ImageEnhance.Contrast(band).enhance(con)
    band = band.filter(ImageFilter.GaussianBlur(blur))
    if colorize is not None:                 # 深色底板上把波浪压成深色
        base = Image.new("RGB", band.size, colorize)
        band = Image.blend(base, band, 0.52)
    rgba = band.convert("RGBA")
    bw, bh = rgba.size
    mask = Image.new("L", (bw, bh), 0)
    mp = mask.load()
    for y in range(bh):
        v = int(255 * opacity * min(1.0, (y / bh) / 0.5) ** mask_power)
        for x in range(bw):
            mp[x, y] = v
    rgba.putalpha(mask)
    plate.paste(rgba, (0, h - bh), rgba)
    return plate


# --------------------------------------------------------------------------
# 底板（background）
# --------------------------------------------------------------------------
def make_background(style, wave_src):
    if style == "navy":
        plate = vertical_gradient(
            (CANVAS, CANVAS),
            [(0.0, (14, 26, 48)), (0.55, (28, 54, 96)), (1.0, (34, 72, 124))],
        )
        plate = add_center_glow(plate, (0.5, 0.42), (0.46, 0.46), 1.0,
                                tint=(44, 92, 146), power=1.55)
        plate = paint_wave(plate, wave_src, ratio=0.42, opacity=170 / 255,
                           colorize=(22, 56, 98), sat=1.20, con=1.0, blur=1.0)
        # 左下角青色环境光，呼应波浪
        px = plate.load()
        w, h = plate.size
        for y in range(h):
            if y <= h * 0.62:
                continue
            for x in range(w):
                if x >= w * 0.5:
                    continue
                t = ((y - h * 0.62) / (h * 0.38)) * max(0.0, 1.0 - (x / (w * 0.5)))
                r, g, b = px[x, y]
                px[x, y] = (int(r + 5 * t), int(g + 22 * t), int(b + 30 * t))
        return add_vignette(plate, 0.18, 1.5)

    # light：浅色玻璃底板（线上采用的版本，顶部略偏紫）
    plate = vertical_gradient(
        (CANVAS, CANVAS),
        [(0.0, (206, 226, 252)), (0.58, (140, 182, 238)), (1.0, (92, 150, 226))],
    )
    plate = add_center_glow(plate, (0.5, 0.40), (1.0 / 1.8, 1.0 / 1.8), 0.16,
                            tint=(255, 255, 255), power=1.0)
    plate = paint_wave(plate, wave_src, ratio=0.38, opacity=1.0,
                       sat=1.40, con=1.12, blur=0.5)
    return add_vignette(plate, 0.16, 1.5)


# --------------------------------------------------------------------------
# 前景（foreground）
# --------------------------------------------------------------------------
def make_foreground(style, logo_src):
    """从高清 logo 生成前景：收光晕 → 锐化 → 定尺寸 → 投影（navy 额外加外发光）。"""
    art = logo_src.crop(LOGO_BOX)

    # 收紧外圈光晕（只压低 alpha，主体不动）
    alpha = art.getchannel("A").point(lambda v: int(255 * ((v / 255.0) ** 1.35) + 0.5))
    rgb = art.convert("RGB")
    rgb = rgb.filter(ImageFilter.UnsharpMask(radius=1.6, percent=110, threshold=1))
    rgb = rgb.filter(ImageFilter.UnsharpMask(radius=6.0, percent=35, threshold=0))
    rgb = ImageEnhance.Contrast(rgb).enhance(1.12)
    rgb = ImageEnhance.Color(rgb).enhance(1.20 if style == "light" else 1.24)
    art = Image.merge("RGBA", (*rgb.split(), alpha))

    # 按实心区占比定位，保证不同版本图标视觉尺寸一致
    x0, y0, x1, y1 = solid_bbox(art)
    # 目标像素取整，保证不同次运行结果完全一致
    target = int(CANVAS * SOLID_RATIO)
    scale = target / max(x1 - x0 + 1, y1 - y0 + 1)
    art = art.resize((int(art.width * scale), int(art.height * scale)), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ox = (CANVAS - art.width) // 2
    oy = (CANVAS - art.height) // 2

    if style == "navy":
        # 冷蓝外发光：深色底板上让白玻璃边缘变成「光」
        glow_a = Image.new("L", (CANVAS, CANVAS), 0)
        glow_a.paste(art.getchannel("A"), (ox, oy))
        glow_a = glow_a.point(lambda v: int(v * 0.42)).filter(ImageFilter.GaussianBlur(24))
        glow = Image.new("RGBA", (CANVAS, CANVAS), (126, 196, 255, 255))
        glow.putalpha(glow_a)
        canvas.alpha_composite(glow, (0, 0))
        shadow_color, shadow_alpha, shadow_blur, shadow_y = (3, 9, 20), 0.50, 12, 14
    else:
        shadow_color, shadow_alpha, shadow_blur, shadow_y = (18, 46, 92), 0.34, 10, 9

    shadow_a = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_a.paste(art.getchannel("A"), (ox, oy))
    shadow_a = shadow_a.point(lambda v: int(v * shadow_alpha)) \
        .filter(ImageFilter.GaussianBlur(shadow_blur))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), shadow_color + (255,))
    shadow.putalpha(shadow_a)
    canvas.alpha_composite(shadow, (0, shadow_y))
    canvas.alpha_composite(art, (ox, oy))
    return canvas


# --------------------------------------------------------------------------
# 启动页图标（splash）：base 与 dark 两版共用同一条 alpha 曲线
# --------------------------------------------------------------------------
def make_splash(logo_src):
    base = logo_src.copy()   # base 保持原样（RGB 不动，alpha 不动）
    alpha = base.getchannel("A").point(
        lambda v: int(255 * ((v / 255.0) ** SPLASH_ALPHA_GAMMA) + 0.5))
    base = Image.merge("RGBA", (*base.convert("RGB").split(), alpha))

    # dark：核心（a>=170）与不透明度完全不动，只把「外侧光晕里的极亮像素」冷色化
    cool = (176, 198, 238)
    dark = base.copy()
    px = dark.load()
    w, h = dark.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0 or a >= 170:
                continue
            lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            if lum <= 0.90:
                continue
            f = min(1.0, (lum - 0.90) / 0.10) * 0.60
            px[x, y] = (
                int(r + (cool[0] - r) * f),
                int(g + (cool[1] - g) * f),
                int(b + (cool[2] - b) * f),
                a,
            )
    return base, dark


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="CFLark 图标资源生成器")
    ap.add_argument("--style", choices=["light", "navy"], default="light",
                    help="桌面图标底板风格：light=浅色（线上），navy=深色（备选 A）")
    ap.add_argument("--splash", action="store_true", help="同时重建启动页图标（base + dark）")
    ap.add_argument("--logo", default=os.path.join(ROOT, "_verify/splash_base_orig.png"),
                    help="高清 logo 源图（1024×1024 RGBA）")
    ap.add_argument("--wave", default=os.path.join(ROOT, "_verify/icon_bg_orig.png"),
                    help="波浪纹理源图（旧版背景图，仅取底部 0.72 以下）")
    ap.add_argument("--dry-run", action="store_true", help="只输出到 _verify/out，不改工程资源")
    args = ap.parse_args()

    if not os.path.exists(args.logo):
        sys.exit("找不到 logo 源图：%s（可用 --logo 指定）" % args.logo)
    if not os.path.exists(args.wave):
        sys.exit("找不到波浪源图：%s（可用 --wave 指定）" % args.wave)

    logo_src = Image.open(args.logo).convert("RGBA")
    wave_src = Image.open(args.wave).convert("RGB")

    fg = make_foreground(args.style, logo_src)
    bg = make_background(args.style, wave_src)

    os.makedirs(OUT_DIR, exist_ok=True)
    fg.save(os.path.join(OUT_DIR, "icon_%s_foreground.png" % args.style))
    bg.save(os.path.join(OUT_DIR, "icon_%s_background.png" % args.style))
    preview = Image.new("RGB", (CANVAS, CANVAS))
    preview.paste(bg, (0, 0))
    preview.paste(fg, (0, 0), fg)
    preview.save(os.path.join(OUT_DIR, "icon_%s_preview.png" % args.style))

    if not args.dry_run:
        for d in (ENTRY_MEDIA, APP_MEDIA):
            os.makedirs(d, exist_ok=True)
            fg.save(os.path.join(d, "foreground.png"))
            bg.save(os.path.join(d, "background.png"))
        print("已写入 foreground/background：\n  %s\n  %s" % (ENTRY_MEDIA, APP_MEDIA))

        if args.splash:
            base, dark = make_splash(logo_src)
            os.makedirs(DARK_MEDIA, exist_ok=True)
            base.save(os.path.join(ENTRY_MEDIA, "splash_icon.png"))
            dark.save(os.path.join(DARK_MEDIA, "splash_icon.png"))
            base.save(os.path.join(OUT_DIR, "splash_base.png"))
            dark.save(os.path.join(OUT_DIR, "splash_dark.png"))
            assert base.getchannel("A").tobytes() == dark.getchannel("A").tobytes(), \
                "splash 两版 alpha 必须一致，否则会出现大小不一致"
            print("已写入 splash：base + dark（alpha 逐像素一致）")

    print("预览图：%s" % OUT_DIR)


if __name__ == "__main__":
    main()
