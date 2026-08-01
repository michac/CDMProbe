#!/usr/bin/env python3
"""Palette PNG -> uncompressed-or-RLE 32-bit RGBA TGA, stdlib only (no PIL here).

WoW's texture loader is documented for BLP/JPEG/PNG/TGA at power-of-two sizes, but the
PNG path is the least-specified of the four and these Kenney sprites are PALETTE
(colortype 3) with tRNS alpha -- the variant most likely to be refused or to lose
transparency.  32-bit RGBA TGA is the classic addon format with the least doubt, so
convert rather than gamble.  RLE because these are mostly flat transparent field:
uncompressed 512x512x4 is 1 MiB per sprite, which is not shippable at a dozen sprites.
"""
import glob, os, struct, sys, zlib


def decode_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    pos, idat, plte, trns, ihdr = 8, [], None, None, None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            plte = body
        elif typ == b"tRNS":
            trns = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
        pos += 12 + ln
    w, h, bd, ct, comp, filt, interlace = ihdr
    assert interlace == 0, f"{path}: interlaced PNG unsupported"
    assert bd == 8, f"{path}: bit depth {bd} unsupported"
    raw = zlib.decompress(b"".join(idat))

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = channels                      # bytes per pixel (bd == 8)
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif f != 0:
            raise ValueError(f"{path}: bad filter {f}")
        out += line
        prev = line

    # -> RGBA
    px = bytearray(w * h * 4)
    for i in range(w * h):
        if ct == 3:
            idx = out[i]
            px[i * 4:i * 4 + 3] = plte[idx * 3:idx * 3 + 3]
            px[i * 4 + 3] = trns[idx] if (trns and idx < len(trns)) else 255
        elif ct == 6:
            px[i * 4:i * 4 + 4] = out[i * 4:i * 4 + 4]
        elif ct == 2:
            px[i * 4:i * 4 + 3] = out[i * 3:i * 3 + 3]
            px[i * 4 + 3] = 255
        elif ct == 0:
            g = out[i]
            px[i * 4:i * 4 + 3] = bytes((g, g, g))
            px[i * 4 + 3] = 255
        elif ct == 4:
            g, a = out[i * 2], out[i * 2 + 1]
            px[i * 4:i * 4 + 3] = bytes((g, g, g))
            px[i * 4 + 3] = a
    return w, h, px


def write_tga(path, w, h, rgba):
    """32-bit RLE TGA, BGRA, top-left origin (descriptor 0x28 = 8-bit alpha + top-down)."""
    px = [bytes((rgba[i * 4 + 2], rgba[i * 4 + 1], rgba[i * 4], rgba[i * 4 + 3]))
          for i in range(w * h)]
    body = bytearray()
    for row in range(h):
        line = px[row * w:(row + 1) * w]
        i = 0
        while i < len(line):
            run = 1
            while run < 128 and i + run < len(line) and line[i + run] == line[i]:
                run += 1
            if run > 1:
                body.append(0x80 | (run - 1)); body += line[i]; i += run
            else:
                j = i + 1
                while (j < len(line) and j - i < 128
                       and not (j + 1 < len(line) and line[j] == line[j + 1])):
                    j += 1
                n = j - i
                body.append(n - 1)
                for k in range(i, j):
                    body += line[k]
                i = j
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 10, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    open(path, "wb").write(hdr + bytes(body))


def box_downscale(w, h, rgba, target):
    """Integer-factor box filter.  512 -> 128 is a clean 4x, so no resampling artefacts.

    Premultiply-free straight average is fine here: these sprites are white/grey with the
    shape carried in ALPHA, so colour bleed from transparent pixels cannot tint anything.
    """
    f = w // target
    assert f >= 1 and w % target == 0 and h % target == 0, "non-integer downscale factor"
    if f == 1:
        return w, h, rgba
    tw, th = w // f, h // f
    out = bytearray(tw * th * 4)
    n = f * f
    for y in range(th):
        for x in range(tw):
            r = g = b = a = 0
            for dy in range(f):
                base = ((y * f + dy) * w + x * f) * 4
                for dx in range(f):
                    i = base + dx * 4
                    r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; a += rgba[i + 3]
            o = (y * tw + x) * 4
            out[o] = r // n; out[o + 1] = g // n; out[o + 2] = b // n; out[o + 3] = a // n
    return tw, th, out


if __name__ == "__main__":
    # A glow ring draws at ~28 px base, ~38 px escalated, ~110 px at the largest echo.
    # 128x128 is comfortably above that and 1/16 the bytes of the 512 source; 512 would
    # cost 4.8 MiB across the set for resolution nothing ever samples.
    TARGET = int(os.environ.get("TARGET", "128"))
    total = 0
    for f in sorted(glob.glob(sys.argv[1] if len(sys.argv) > 1 else "*.png")):
        w, h, px = decode_png(f)
        w, h, px = box_downscale(w, h, px, TARGET)
        out = f[:-4] + ".tga"
        write_tga(out, w, h, px)
        sz = os.path.getsize(out)
        total += sz
        opaque = sum(1 for i in range(w * h) if px[i * 4 + 3] > 0)
        print(f"{os.path.basename(out):16} {w}x{h}  {sz/1024:7.1f} KiB  "
              f"non-transparent px {100*opaque//(w*h)}%")
    print(f"total TGA: {total/1024/1024:.2f} MiB")
