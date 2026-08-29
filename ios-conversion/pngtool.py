#!/usr/bin/env python3
"""Minimal dependency-free PNG (8-bit RGBA/RGB, non-interlaced) decode + box-resize + encode.
Uses only zlib + struct from the stdlib. Enough to turn the recovered 512x512 Vita3K
launcher icon into the exact iOS icon sizes."""
import struct, zlib, sys

def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc: return a
    if pb <= pc: return b
    return c

def decode(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    w, h, bd, ct, comp, filt, inter = struct.unpack(">IIBBBBB", d[16:29])
    assert bd == 8 and inter == 0 and ct in (2, 6), "unsupported PNG (need 8-bit RGB/RGBA, non-interlaced)"
    ch = 4 if ct == 6 else 3
    o = 8
    idat = bytearray()
    while o < len(d):
        ln = struct.unpack(">I", d[o:o+4])[0]
        typ = d[o+4:o+8]
        if typ == b"IDAT":
            idat += d[o+8:o+8+ln]
        o += 12 + ln
        if typ == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    stride = w * ch
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if f == 1:      # Sub
            for i in range(ch, stride): line[i] = (line[i] + line[i-ch]) & 255
        elif f == 2:    # Up
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:    # Average
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:    # Paeth
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                c = prev[i-ch] if i >= ch else 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 255
        prev = line
        # expand to RGBA
        do = y * w * 4
        if ch == 4:
            out[do:do+stride] = line
        else:
            for x in range(w):
                out[do+x*4+0] = line[x*3+0]
                out[do+x*4+1] = line[x*3+1]
                out[do+x*4+2] = line[x*3+2]
                out[do+x*4+3] = 255
    return w, h, out

def resize(w, h, data, tw, th):
    """Box-average resize RGBA (good for downscaling)."""
    out = bytearray(tw * th * 4)
    for ty in range(th):
        sy0 = ty * h // th; sy1 = max(sy0 + 1, (ty + 1) * h // th)
        for tx in range(tw):
            sx0 = tx * w // tw; sx1 = max(sx0 + 1, (tx + 1) * w // tw)
            r = g = b = a = cnt = 0
            for sy in range(sy0, sy1):
                base = (sy * w + sx0) * 4
                for sx in range(sx0, sx1):
                    r += data[base]; g += data[base+1]; b += data[base+2]; a += data[base+3]
                    base += 4; cnt += 1
            o = (ty * tw + tx) * 4
            out[o] = r // cnt; out[o+1] = g // cnt; out[o+2] = b // cnt; out[o+3] = a // cnt
    return out

def encode(w, h, data):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)  # filter None
        raw += data[y*stride:(y+1)*stride]
    comp = zlib.compress(bytes(raw), 9)
    def chunk(typ, payload):
        c = struct.pack(">I", len(payload)) + typ + payload
        return c + struct.pack(">I", zlib.crc32(typ + payload) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")

if __name__ == "__main__":
    src = sys.argv[1]
    w, h, data = decode(src)
    for spec in sys.argv[2:]:
        size, outpath = spec.split(":")
        size = int(size)
        rz = resize(w, h, data, size, size)
        open(outpath, "wb").write(encode(size, size, rz))
        print(f"wrote {outpath} ({size}x{size})")
