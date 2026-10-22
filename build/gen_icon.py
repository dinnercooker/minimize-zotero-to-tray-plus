#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成插件图标：多尺寸 tray.ico（32bpp DIB 条目，兼容 GDI+）与 icon.png。

纯手写 PNG/ICO 编码，无第三方依赖。
"""
import os
import struct
import zlib

ICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "addon", "content", "icons")
BIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "addon", "content", "bin")

# ---------------------------------------------------------------- 渲染

SS = 4  # 超采样倍数


def _rounded_alpha(px, py, size, radius):
    """圆角矩形内部返回 True。"""
    half = size / 2.0
    r = radius
    dx = abs(px - half) - (half - r)
    dy = abs(py - half) - (half - r)
    dx = max(dx, 0.0)
    dy = max(dy, 0.0)
    return (dx * dx + dy * dy) <= r * r


def _in_z(u, v):
    """归一化坐标 (0..1) 内判断是否落在字母 Z 上。"""
    x0, x1 = 0.245, 0.755
    ytop0, ytop1 = 0.255, 0.375
    ybot0, ybot1 = 0.625, 0.745
    if ytop0 <= v <= ytop1 or ybot0 <= v <= ybot1:
        return x0 <= u <= x1
    if ytop1 < v < ybot0:
        t = (v - ytop1) / (ybot0 - ytop1)
        center = 0.615 + (0.385 - 0.615) * t
        return (center - 0.07) <= u <= (center + 0.07)
    return False


def render(size):
    """返回 size x size 的 RGBA 字节串（自上而下）。"""
    radius = max(2.0, size * 0.20) * SS
    sx = size * SS
    # 逐子像素计算颜色
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx_i in range(SS):
                    px = x * SS + sx_i + 0.5
                    py = y * SS + sy + 0.5
                    if not _rounded_alpha(px, py, sx, radius):
                        continue
                    u = px / sx
                    v = py / sx
                    if _in_z(u, v):
                        r, g, b = 255.0, 255.0, 255.0
                    else:
                        t = v  # 垂直渐变
                        r = 226 * (1 - t) + 168 * t
                        g = 76 * (1 - t) + 28 * t
                        b = 76 * (1 - t) + 44 * t
                    acc[0] += r
                    acc[1] += g
                    acc[2] += b
                    acc[3] += 255.0
            total = SS * SS
            a = acc[3] / total
            if a <= 0:
                row += bytes((0, 0, 0, 0))
            else:
                # 按覆盖率归一化颜色
                cov = acc[3] / 255.0
                row += bytes((
                    int(round(acc[0] / cov)),
                    int(round(acc[1] / cov)),
                    int(round(acc[2] / cov)),
                    int(round(a)),
                ))
        rows.append(bytes(row))
    return b"".join(rows)


# ---------------------------------------------------------------- PNG

def png_encode(size, rgba):
    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)  # filter: none
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---------------------------------------------------------------- ICO (DIB 条目)

def dib_entry(size, rgba):
    """32bpp 未压缩 DIB（ICO 内嵌格式，GDI+ 兼容性最好）。"""
    hdr = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    pixels = bytearray()
    stride = size * 4
    for y in range(size - 1, -1, -1):  # 自下而上
        line = rgba[y * stride:(y + 1) * stride]
        for i in range(0, len(line), 4):
            r, g, b, a = line[i], line[i + 1], line[i + 2], line[i + 3]
            pixels += bytes((b, g, r, a))
    mask_row = ((size + 31) // 32) * 4
    mask = bytes(mask_row * size)  # 全 0 = 全部不透明
    return hdr + bytes(pixels) + mask


def ico_encode(images):
    count = len(images)
    out = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    entries, blobs = b"", b""
    for size, data in images:
        b_ = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", b_, b_, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
        blobs += data
    return out + entries + blobs


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    os.makedirs(BIN_DIR, exist_ok=True)
    cache = {}
    for s in (16, 20, 24, 32, 48, 64, 128, 256):
        cache[s] = render(s)
        print("rendered", s)

    ico_sizes = (16, 20, 24, 32, 48, 64, 256)
    images = [(s, dib_entry(s, cache[s]) if s < 256 else png_encode(s, cache[s])) for s in ico_sizes]
    ico_path = os.path.join(BIN_DIR, "tray.ico")
    with open(ico_path, "wb") as f:
        f.write(ico_encode(images))
    print("wrote", ico_path, os.path.getsize(ico_path))

    png_path = os.path.join(ICON_DIR, "icon.png")
    with open(png_path, "wb") as f:
        f.write(png_encode(128, cache[128]))
    print("wrote", png_path, os.path.getsize(png_path))

    # 预览图（白底拼贴，方便目视检查）
    preview = 160
    rgba = render(preview)
    with open(os.path.join(ICON_DIR, "_preview.png"), "wb") as f:
        f.write(png_encode(preview, rgba))
    print("wrote preview")


if __name__ == "__main__":
    main()
