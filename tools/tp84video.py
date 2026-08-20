"""Time Pilot '84 video model: the executable spec for the video hardware.

A direct transcription of MAME's tp84 driver -- gfx decode, the resistor-network
palette, the two lookup PROMs, tilemap scroll and priority -- written so it can
be read while writing RTL instead of re-deriving from C++.

No third-party modules: PNG in and out are done with zlib and struct.
"""
import os, zlib, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# ---------------------------------------------------------------- .rom layout
ROM_MAIN    = (0x00000, 0x8000)   # master 6809E, maps to 8000-FFFF
ROM_SUB     = (0x08000, 0x2000)   # slave  6809E, maps to E000-FFFF
ROM_SOUND   = (0x0A000, 0x2000)   # sound Z80,    maps to 0000-1FFF
ROM_TILES   = (0x0C000, 0x4000)   # 1024 tiles x 16 bytes
ROM_SPRITES = (0x10000, 0x8000)   # 256 sprites x 128 bytes (two 16K halves)
PROM_R      = (0x18000, 0x100)
PROM_G      = (0x18100, 0x100)
PROM_B      = (0x18200, 0x100)
PROM_CLUT   = (0x18300, 0x100)    # character lookup
PROM_SLUT   = (0x18400, 0x100)    # sprite lookup
ROM_SIZE    = 0x18500

# Screen: 256x256 raster, rows 16..239 visible.
SCR_W, SCR_H = 256, 256
VIS_Y0, VIS_Y1 = 16, 240
VIS_W, VIS_H = 256, VIS_Y1 - VIS_Y0

# The foreground tilemap is drawn only in these two strips of the raster; once
# the screen is rotated they are the status bars top and bottom.
FG_LEFT  = (0, 16)
FG_RIGHT = (SCR_W - 16, SCR_W)
# ------------------------------------------------------------------- PNG i/o
def read_png(path):
    d = open(path, 'rb').read()
    pos, idat, plte = 8, b'', None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        if tag == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
        elif tag == b'PLTE':
            plte = d[pos + 8:pos + 8 + ln]
        elif tag == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * ch
    img = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f:
            for x in range(stride):
                a = row[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                if f == 1:   row[x] = (row[x] + a) & 0xff
                elif f == 2: row[x] = (row[x] + b) & 0xff
                elif f == 3: row[x] = (row[x] + (a + b) // 2) & 0xff
                elif f == 4:
                    pp = a + b - c
                    pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                    row[x] = (row[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xff
        prev = row
        for x in range(w):
            o = (y * w + x) * 3
            if ct == 3:
                pi = row[x] * 3
                img[o:o + 3] = plte[pi:pi + 3]
            elif ct == 0:
                img[o:o + 3] = bytes([row[x]] * 3)
            else:
                img[o:o + 3] = row[x * ch:x * ch + 3]
    return w, h, img


def write_png(path, w, h, img):
    raw = b''.join(b'\x00' + bytes(img[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(tag, d):
        c = tag + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n'
                           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 6))
                           + chunk(b'IEND', b''))



# --------------------------------------------------------------------- ROM
def _resistor_weights(resistances, pulldown=470, pullup=0, minval=0, maxval=255):
    """MAME's compute_resistor_weights for one network, autoscaled.

    Each gun is a 4-bit ladder of 1k/470/220/100 ohm resistors with a 470 ohm
    pulldown. Ported faithfully rather than approximated: the weights are not
    the obvious 8/4/2/1 and getting them wrong shifts every colour slightly.
    """
    n = len(resistances)
    w = []
    for i in range(n):
        r0 = (1.0 / pulldown) if pulldown else 1.0 / 1e12
        r1 = (1.0 / pullup) if pullup else 1.0 / 1e12
        for j in range(n):
            if resistances[j] == 0:
                continue
            if j == i:
                r1 += 1.0 / resistances[j]
            else:
                r0 += 1.0 / resistances[j]
        r0, r1 = 1.0 / r0, 1.0 / r1
        vout = (maxval - minval) * r0 / (r1 + r0) + minval
        w.append(min(max(vout, minval), maxval))
    scale = float(maxval) / sum(w)
    return [x * scale for x in w]


def _combine(weights, bits):
    """MAME's combine_weights: int(sum + 0.5)."""
    return int(sum(wt * b for wt, b in zip(weights, bits)) + 0.5)


class Rom:
    def __init__(self, path=None):
        path = path or os.path.join(ROOT, 'build', 'tp84.rom')
        d = open(path, 'rb').read()
        if len(d) != ROM_SIZE:
            raise SystemExit(f'{path}: expected {ROM_SIZE} bytes, got {len(d)}')
        cut = lambda r: d[r[0]:r[0] + r[1]]
        self.main    = cut(ROM_MAIN)
        self.sub     = cut(ROM_SUB)
        self.sound   = cut(ROM_SOUND)
        self.tiles   = cut(ROM_TILES)
        self.sprites = cut(ROM_SPRITES)
        self.prom_r, self.prom_g, self.prom_b = cut(PROM_R), cut(PROM_G), cut(PROM_B)
        self.clut, self.slut = cut(PROM_CLUT), cut(PROM_SLUT)

        wts = _resistor_weights([1000, 470, 220, 100])
        self.weights = wts
        # 256 physical colours, indexed by the "ctabentry" the lookups produce
        self.colour = []
        for i in range(256):
            bits = lambda v: [(v >> b) & 1 for b in range(4)]
            self.colour.append((_combine(wts, bits(self.prom_r[i])),
                                _combine(wts, bits(self.prom_g[i])),
                                _combine(wts, bits(self.prom_b[i]))))

        self.tile_px = _decode_tiles(self.tiles)
        self.spr_px  = _decode_sprites(self.sprites)


def _decode_tiles(rom):
    """1024 tiles -> 64-entry pixel lists, row-major, 2 bpp.

    Same layout as Time Pilot's characters: byte[y] holds x=0..3 and byte[8+y]
    holds x=4..7, high nibble the LSB plane and low nibble the MSB plane.
    """
    out = []
    for code in range(len(rom) // 16):
        base = code * 16
        px = [0] * 64
        for y in range(8):
            for x in range(8):
                b = rom[base + (8 if x >= 4 else 0) + y]
                k = x & 3
                px[y * 8 + x] = (((b >> (3 - k)) & 1) << 1) | ((b >> (7 - k)) & 1)
        out.append(px)
    return out


def _decode_sprites(rom):
    """256 sprites -> 256-entry pixel lists, row-major, 4 bpp.

    The four planes are split across the two halves of the region: the byte
    index inside a half works out identical to Time Pilot's sprite formula,
    with the high half carrying the two most significant planes.
    """
    half = len(rom) // 2
    out = []
    for code in range(half // 64):
        base = code * 64
        px = [0] * 256
        for y in range(16):
            for x in range(16):
                idx = base + 8 * (x >> 2) + y + (24 if y >= 8 else 0)
                lo, hi = rom[idx], rom[half + idx]
                k = x & 3
                px[y * 16 + x] = (((hi >> (3 - k)) & 1) << 3) | (((hi >> (7 - k)) & 1) << 2) \
                               | (((lo >> (3 - k)) & 1) << 1) | ((lo >> (7 - k)) & 1)
        out.append(px)
    return out


# ------------------------------------------------------------------- state
def load_state(path):
    """Read a dump written by tools/dumpstate.lua."""
    regions, cur, meta = {}, None, {}
    for line in open(path):
        line = line.strip()
        if not line or line == 'END':
            continue
        if line[0].isupper() and not all(c in '0123456789abcdef' for c in line):
            cur = line
            regions[cur] = bytearray()
        elif cur is None:
            k, _, v = line.partition(' ')
            meta[k] = v
        else:
            regions[cur] += bytes.fromhex(line)
    return meta, regions


# ------------------------------------------------------------------ render
def render(rom, st, flipx=False, flipy=False):
    """Produce the full 256x256 raster as a list of (r,g,b).

    Order is MAME's screen_update: the scrolling background, then sprites, then
    the foreground tilemap in two 16-pixel strips at the raster's left and right
    edges (the status bars, once rotated).
    """
    if flipx or flipy:
        raise SystemExit('flipped states are not modelled here; none captured so far')

    bg_v, bg_c = st['BGVIDEORAM'], st['BGCOLORRAM']
    fg_v, fg_c = st['FGVIDEORAM'], st['FGCOLORRAM']
    spr = st['SPRITERAM']
    pb = st['PALETTEBANK'][0]
    scroll_x = st['SCROLLX'][0]
    scroll_y = st['SCROLLY'][0]

    fb = [(0, 0, 0)] * (SCR_W * SCR_H)

    # --- background, opaque, scrolled and wrapping at 256
    #
    # Measured, not guessed: MAME places the tilemap instance at the scroll
    # value, so screen x maps to tilemap x PLUS the scroll, not minus. All four
    # sign combinations were rendered against a state with both axes non-zero;
    # this one differed in 399 background pixels where the others differed in
    # 5800-7700 (the residual being the sprites, drawn later).
    for sy in range(SCR_H):
        my = (sy + scroll_y) & 0xff
        ty, row = my >> 3, my & 7
        base = sy * SCR_W
        for sx in range(SCR_W):
            mx = (sx + scroll_x) & 0xff
            fb[base + sx] = _tile_pixel(rom, bg_v, bg_c, ty * 32 + (mx >> 3), mx & 7, row, pb)

    # --- sprites, offs 0x5C down to 0, later entries on top
    for offs in range(0x5c, -1, -4):
        x = spr[offs]
        code = spr[offs + 1]
        attr = spr[offs + 2]
        y = 240 - spr[offs + 3]
        colour = ((pb & 0x07) << 4) | (attr & 0x0f)
        flip_x = not (attr & 0x40)
        flip_y = bool(attr & 0x80)
        px = rom.spr_px[code]
        for row in range(16):
            py = y + row
            if not (0 <= py < SCR_H):
                continue
            sr = 15 - row if flip_y else row
            o = py * SCR_W
            for col in range(16):
                pxx = x + col
                if not (0 <= pxx < SCR_W):
                    continue
                v = px[sr * 16 + (15 - col if flip_x else col)]
                lut = rom.slut[((attr & 0x0f) << 4) | v] & 0x0f
                if lut == 0:            # transparent: lookup maps to the base colour
                    continue
                fb[o + pxx] = rom.colour[((pb & 0x07) << 4) | lut]

    # --- foreground, opaque, only in the two edge strips
    for x0, x1 in (FG_LEFT, FG_RIGHT):
        for sy in range(SCR_H):
            ty, row = sy >> 3, sy & 7
            base = sy * SCR_W
            for sx in range(x0, x1):
                fb[base + sx] = _tile_pixel(rom, fg_v, fg_c, ty * 32 + (sx >> 3), sx & 7, row, pb)
    return fb


def _tile_pixel(rom, vram, cram, idx, col, row, pb):
    attr = cram[idx]
    code = ((attr & 0x30) << 4) | vram[idx]
    r = 7 - row if (attr & 0x80) else row
    c = 7 - col if (attr & 0x40) else col
    v = rom.tile_px[code][r * 8 + c]
    lut = rom.clut[((pb & 0x18) << 3) | ((attr & 0x0f) << 2) | v] & 0x0f
    return rom.colour[0x80 | ((pb & 0x07) << 4) | lut]


def crop_visible(fb):
    out = bytearray(VIS_W * VIS_H * 3)
    i = 0
    for y in range(VIS_Y0, VIS_Y1):
        for x in range(VIS_W):
            r, g, b = fb[y * SCR_W + x]
            out[i] = r; out[i + 1] = g; out[i + 2] = b
            i += 3
    return out

def rot90cw(w, h, img):
    """Rotate clockwise: dst(x,y) = src(y, h-1-x).  256x224 -> 224x256."""
    dw, dh = h, w
    out = bytearray(dw * dh * 3)
    for dy in range(dh):
        for dx in range(dw):
            sx, sy = dy, h - 1 - dx
            s = (sy * w + sx) * 3
            d = (dy * dw + dx) * 3
            out[d:d + 3] = img[s:s + 3]
    return dw, dh, out


def rot90ccw(w, h, img):
    """Rotate counter-clockwise: dst(x,y) = src(w-1-y, x)."""
    dw, dh = h, w
    out = bytearray(dw * dh * 3)
    for dy in range(dh):
        for dx in range(dw):
            sx, sy = w - 1 - dy, dx
            s = (sy * w + sx) * 3
            d = (dy * dw + dx) * 3
            out[d:d + 3] = img[s:s + 3]
    return dw, dh, out
