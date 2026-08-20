# Time Pilot '84 (Konami, 1984) — hardware notes

Source of truth: MAME `src/mame/konami/tp84.cpp` (vendored read-only under
`ref/mame/`, gitignored), cross-checked with `mame -listxml tp84` (MAME 0.288).

Status legend: **[MAME]** taken from the driver, **[XML]** from listxml,
**[PCB]** MAME marks it "verified on PCB", **[ASSUMED]** inferred and needs
confirmation, **[VERIFIED]** confirmed here by experiment.

Time Pilot '84 shares almost nothing with Time Pilot beyond the manufacturer,
the master crystal and the Konami video timing chain. It is three CPUs, two
tilemaps with a scrolling background, 4bpp sprites, an indexed palette with a
runtime-selected bank, and three SN76489As instead of two AY-3-8910s.

---

## 1. Clocks

| Signal | Frequency | Source |
|---|---|---|
| Video board crystal | 18.432 MHz | [MAME] |
| Master 6809E | 1.536 MHz = 18.432/12 | [PCB] |
| Slave 6809E | 1.536 MHz = 18.432/12 | [PCB] |
| Dot clock | 6.144 MHz = 18.432/3 | [ASSUMED] see §4 |
| Sound board crystal | 14.31818 MHz | [MAME] |
| Sound Z80 | 3.579545 MHz = 14.31818/4 | [PCB] |
| SN76489A ×3 | 1.789773 MHz = 14.31818/8 | [PCB] |

The sound board runs from its own crystal, asynchronous to the video board,
exactly as on Time Pilot.

## 2. Master 6809E memory map [MAME]

```
2000        w   watchdog reset
2800        r   SYSTEM        w  palette bank (COL0)
2820        r   P1
2840        r   P2
2860        r   DSW1
3000        r   DSW2
3000-3007   w   LS259 (3B), write_d0
3800        w   sound IRQ trigger (SON)
3A00        w   sound command latch (SDA)
3C00        w   background scroll X          (driver header calls this Y; the
3E00        w   background scroll Y           map's share names are authoritative)
4000-43FF   rw  bg video RAM   (tile codes)
4400-47FF   rw  fg video RAM   (tile codes)
4800-4BFF   rw  bg colour RAM  (attributes)
4C00-4FFF   rw  fg colour RAM  (attributes)
5000-57FF   rw  shared RAM (with the slave)
8000-FFFF   r   ROM
```

### LS259 (3B) outputs [MAME]

| Q | Function |
|---|---|
| 0 | master IRQ enable — clearing it also clears a pending IRQ |
| 1 | coin counter 2 |
| 2 | coin counter 1 |
| 3 | MUT (audio mute) — present on the board, not wired up in MAME |
| 4 | flip screen X |
| 5 | flip screen Y |
| 6 | unused |
| 7 | GMED |

Note flip X and flip Y are **separate** here, unlike Time Pilot's single bit.

## 3. Slave 6809E and sound Z80

**Slave 6809E** [MAME]

```
2000        r   scanline counter (beam position)
4000        w   slave IRQ mask
6000-679F   rw  RAM
67A0-67FF   rw  sprite RAM (96 bytes = 24 sprites x 4)
8000-87FF   rw  shared RAM (with the master)
E000-FFFF   r   ROM
```

Both CPUs take their IRQ from vblank, each gated by its own enable: the
master's is LS259 Q0, the slave's is the write to 4000.

**Sound Z80** [MAME]

```
0000-3FFF   r   ROM (only 0000-1FFF is populated)
4000-43FF   rw  RAM
6000        r   sound command latch
8000        r   timer
A000-A1FF   w   filter control (the ADDRESS carries the data)
C000        w   ignored
C001        w   SN76489A #1
C003        w   SN76489A #2
C004        w   SN76489A #3
```

The timer at 8000 is `(cycles / 1024) & 0x0F` — a free-running divider off the
sound Z80 clock, so like Time Pilot's AY port B it must be a real counter in
the core, not something derived from instructions executed. C002 exists on the
board for a fourth SN76489A that was never fitted.

Filter control, from the address bits within A000-A1FF [MAME]:

| bit | effect |
|---|---|
| 3 | SN #1 += 47 nF |
| 4 | SN #1 += 470 nF |
| 5, 6 | SN #2 as fitted — the *optional* chip, commented out in MAME |
| 7 | SN #3 += 470 nF |
| 8 | SN #4 += 470 nF |

MAME models each as `filter_rc LOWPASS_3R` with R1 = 1 kΩ, R2 = 2.2 kΩ,
R3 = 1 kΩ. Note MAME's three filter devices attach to sn1, sn2 and sn3, and
the bit numbering in the driver comments counts the unfitted chip, so the
mapping is bits 3/4 → sn1, bit 7 → sn2, bit 8 → sn3.

## 4. Video

### Timing

MAME uses the same 256×256 @ 60.000 Hz approximation as its `timeplt` driver
with the visible area 0-255 × 16-239 [MAME]. Real hardware is the Konami chain
of the period [ASSUMED — same reasoning as the Time Pilot core, from the
measured values in `konami/pooyan.cpp`]:

```
dot clock 6.144 MHz = 18.432/3
HTOTAL 384   H visible 0..255
VTOTAL 264   V visible 16..239   (224 lines)
refresh = 6144000 / (384*264) = 60.606 Hz
```

Same master crystal, same visible window, same manufacturer and era as Pooyan,
whose driver carries these values marked "measured".

### Two tilemaps [MAME]

Both are 32×32 of 8×8 tiles, 2 bpp, from the same tile ROM.

```
code   = ((colorram & 0x30) << 4) | videoram      -> 10 bits, 1024 tiles
color  = ((pb & 0x07) << 6) | ((pb & 0x18) << 1) | (colorram & 0x0f)
flip X = colorram bit 6
flip Y = colorram bit 7
```

`pb` is the palette bank written to 2800. The **background** scrolls, its X and
Y latched from 3C00/3E00 at the first visible scanline of the frame. The
**foreground** does not scroll and is drawn only in two 16-pixel-wide strips at
the left and right edges of the raster — which, once the screen is rotated, are
the status bars at the top and bottom.

Draw order: background, then sprites, then those two foreground strips.

### Sprites [MAME]

24 sprites, 16×16, 4 bpp, from sprite RAM on the **slave** CPU at 67A0-67FF.
Scanned `offs = 0x5C` down to `0` step −4, so later entries draw on top.

```
x      = spriteram[offs]
code   = spriteram[offs + 1]
color  = ((pb & 0x07) << 4) | (spriteram[offs + 2] & 0x0F)
flip X = !(spriteram[offs + 2] & 0x40)
flip Y =   spriteram[offs + 2] & 0x80
y      = 240 - spriteram[offs + 3]
```

Writes to sprite RAM force `update_partial(vpos)` in MAME, i.e. the game
multiplexes sprites down the frame exactly as Time Pilot does, so sprite RAM
must be evaluated per scanline.

Transparency is **not** a fixed pen: MAME uses `transpen_mask` against the
palette base, which works out as *a sprite pixel is transparent when the low
nibble of its sprite lookup PROM entry is 0*.

### GFX decode [MAME]

Tiles (`388_h02.2j` + `388_d01.1j`, 16 KB = 1024 tiles × 16 bytes), 2 bpp,
planes at bit offsets {4, 0} — the same layout as Time Pilot's tiles:

```
byte[y]     -> pixels x=0..3      byte[8+y] -> pixels x=4..7
within a byte: bit(7-k) = LSB plane of pixel k, bit(3-k) = MSB plane
```

Sprites (`388_e09/10/11/12`, 32 KB = 256 sprites × 128 bytes), 4 bpp, with the
planes split across the two halves of the region:

```
planes at RGN_FRAC(1,2)+4, RGN_FRAC(1,2)+0, 4, 0
xoffset = { STEP4(0,1), STEP4(64,1), STEP4(128,1), STEP4(192,1) }
yoffset = { STEP8(0,8), STEP8(256,8) }
total   = 16*16*2 = 512 bits = 64 bytes per half, 128 bytes per sprite
```

### Colour [MAME]

Five PROMs:

| PROM | Size | Role |
|---|---|---|
| `388d14.2c` | 256 | palette red |
| `388d15.2d` | 256 | palette green |
| `388d16.1e` | 256 | palette blue |
| `388d18.1f` | 256 | character lookup |
| `388j17.16c` | 256 | sprite lookup |

Each gun is a 4-bit resistor DAC — 1 kΩ, 470 Ω, 220 Ω, 100 Ω with a 470 Ω
pulldown — resolved through MAME's `compute_resistor_weights` with autoscaling
to 0-255.

Two indirection stages, both driven partly by the palette bank:

```
character:  lut_index = (pb[4:3] << 6) | (attr[3:0] << 2) | pixel[1:0]
            colour    = 0x80 | (pb[2:0] << 4) | (charlut[lut_index] & 0x0F)

sprite:     lut_index = (attr[3:0] << 4) | pixel[3:0]
            colour    =        (pb[2:0] << 4) | (sprlut[lut_index] & 0x0F)
            transparent when (sprlut[lut_index] & 0x0F) == 0

final RGB = { redprom[colour], greenprom[colour], blueprom[colour] }
```

So characters live in the upper half of the 256-colour space and sprites in the
lower half, and the palette bank moves both around inside it.

## 5. Inputs [MAME, konamipt.h]

All active low.

**SYSTEM (2800)**
| bit | function |
|---|---|
| 0 | Coin 1 |
| 1 | Coin 2 |
| 2 | Service 1 |
| 3 | Start 1 |
| 4 | Start 2 |
| 5-7 | unused |

**P1 (2820)** — 8-way stick and **two** buttons
| bit | function |
|---|---|
| 0 | Left |
| 1 | Right |
| 2 | Up |
| 3 | Down |
| 4 | Button 1 |
| 5 | Button 2 |
| 6-7 | unused |

**P2 (2840)** — cocktail equivalents, same bit layout.

**DSW1 (2860)** — coinage, bits 3:0 coin A and 7:4 coin B. 0x0F/0xF0 is
1 coin 1 credit; coin A 0x00 is Free Play, coin B 0x00 disables both slots.

**DSW2 (3000)**
| bits | function | default |
|---|---|---|
| 1:0 | Lives: 2/3/5/7 (3,2,1,0) | 3 (0x02) |
| 2 | Cabinet: 0 upright, 1 cocktail | upright |
| 4:3 | Bonus: 10k/50k, 20k/60k, 30k/70k, 40k/80k (3,2,1,0) | 20k (0x10) |
| 6:5 | Difficulty: easy/normal/hard/hardest (3,2,1,0) | hard (0x20) |
| 7 | Demo sounds: 0 = on | on (0x00) |

Factory defaults: DSW1 = 0xFF, DSW2 = 0x32.

## 6. ROM set (`tp84`) [XML]

| File | Size | CRC32 | Region / offset |
|---|---|---|---|
| 388_f04.7j | 8192 | 605f61c7 | cpu1 0x8000 |
| 388_05.8j | 8192 | 4b4629a4 | cpu1 0xA000 |
| 388_f06.9j | 8192 | dbd5333b | cpu1 0xC000 |
| 388_07.10j | 8192 | a45237c4 | cpu1 0xE000 |
| 388_f08.10d | 8192 | 36462ff1 | sub 0xE000 |
| 388j13.6a | 8192 | c44414da | audiocpu 0x0000 |
| 388_h02.2j | 8192 | 05c7508f | tiles 0x0000 |
| 388_d01.1j | 8192 | 498d90b7 | tiles 0x2000 |
| 388_e09.12a | 8192 | cd682f30 | sprites 0x0000 |
| 388_e10.13a | 8192 | 888d4bd6 | sprites 0x2000 |
| 388_e11.14a | 8192 | 9a220b39 | sprites 0x4000 |
| 388_e12.15a | 8192 | fac98397 | sprites 0x6000 |
| 388d14.2c | 256 | d737eaba | proms 0x000 red |
| 388d15.2d | 256 | 2f6a9a2a | proms 0x100 green |
| 388d16.1e | 256 | 2e21329b | proms 0x200 blue |
| 388d18.1f | 256 | 61d2d398 | proms 0x300 char lut |
| 388j17.16c | 256 | 13c4e198 | proms 0x400 sprite lut |

Total 90,880 bytes — still small enough to live entirely in block RAM.

## 7. Open questions

1. Real H/V timing — 384×264 @ 6.144 MHz is inherited from the Pooyan
   measurement rather than measured for this board.
2. Whether sprites come from a line buffer filled during the previous line, as
   assumed for Time Pilot. The `update_partial` on every sprite RAM write says
   they are evaluated per scanline; it does not say when.
3. What the game does with the two 6809s — how much work is on the slave, and
   how tightly the shared RAM handshake is timed. Needs disassembly.
4. LS259 Q3 (MUT) and Q7 (GMED) are unmodelled in MAME.
