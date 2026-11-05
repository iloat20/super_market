"""最小 PNG 解码/对比工具（纯标准库），用于验证 UI 改动的视觉差异。

为什么不用 Pillow：这个环境没装。PNG 的 IDAT 只是 zlib 压缩的行数据 +
每行一个 filter 字节，解起来不到 40 行，够用了。

用法：
    python tool/pngdiff.py a.png b.png [region:x0,y0,x1,y1]
"""

import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "不是 PNG"
    pos = 8
    width = height = None
    bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        length = int.from_bytes(data[pos : pos + 4], "big")
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width = int.from_bytes(body[0:4], "big")
            height = int.from_bytes(body[4:8], "big")
            bit_depth = body[8]
            color_type = body[9]
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    assert bit_depth == 8, f"只支持 8bit，实际 {bit_depth}"
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * channels)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if ftype == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return width, height, channels, out


def main():
    a, b = sys.argv[1], sys.argv[2]
    region = None
    if len(sys.argv) > 3:
        region = [int(v) for v in sys.argv[3].split(":")[1].split(",")]

    wa, ha, ca, pa = read_png(a)
    wb, hb, cb, pb = read_png(b)
    if (wa, ha) != (wb, hb):
        print(f"尺寸不同：{wa}x{ha} vs {wb}x{hb}")
        return

    x0, y0, x1, y1 = region or (0, 0, wa, ha)
    diff = 0
    total = 0
    maxd = 0
    sum_a = [0, 0, 0]
    sum_b = [0, 0, 0]
    for y in range(y0, y1):
        for x in range(x0, x1):
            ia = (y * wa + x) * ca
            ib = (y * wb + x) * cb
            for c in range(3):
                va, vb = pa[ia + c], pb[ib + c]
                sum_a[c] += va
                sum_b[c] += vb
                d = abs(va - vb)
                maxd = max(maxd, d)
                total += 1
                if d > 2:
                    diff += 1
    n = max(1, (x1 - x0) * (y1 - y0))
    print(f"区域 {x0},{y0}-{x1},{y1}  像素数 {n}")
    print(f"平均 RGB  A={[v // n for v in sum_a]}  B={[v // n for v in sum_b]}")
    print(f"差异像素(>2/255) {diff} ({diff * 100.0 / n:.2f}%)  最大通道差 {maxd}")


if __name__ == "__main__":
    main()
