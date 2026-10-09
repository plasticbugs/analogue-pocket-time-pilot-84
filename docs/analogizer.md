# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This core supports it (`USE_ANALOGIZER = 1` in `core_top.sv`), added after
release 0.1.5 by the pocket-core-template's retrofit handoff
(`docs/analogizer-retrofit.md` there), with the template's wrapper and bench.
This page is what the player needs, what the core does, and what has been
proven.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; this
core does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -24 to +8 dots; + moves the picture right along the scan line |
| Analogizer V Position | -24 to +4 lines; + moves the picture down the frame |
| Analogizer H Size | -20% to +20%; + wider. With the set on its side, the game's height |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Width.** "Analogizer H Size" makes the picture narrower or wider about
its centre, in percent, in the 15 kHz modes (RGBS, RGsB, YPbPr, Y/C): the
core plays each line back a little faster or slower. With the CRT stood on
its side, as this board's monitor was, that is the game's height. The
board starts hsync only 8 dots after the picture, so first centre the
picture with H Position (about -24), then widen it. Where the two together
would put picture on the sync or on the colour burst after it, the core
crops the picture's edge instead, so the set never loses sync. There is
no vertical equivalent (a CRT's height is its sweep), and the scandoubler
modes are left alone. How it works is in the template's
docs/analogizer.md, "Picture width". Bench: at +20% and -20% with the
picture centred (H Position -24), 224 lines of 2,458 and 1,639 clocks
(asked 2,458 and 1,638), centred to the clock, every dot in order, held 9
or 10 (6 or 7) clocks, the lines as far from vsync as at 0; at +20% with H
Position at either end, csync never low while a dot is drawn and the
colour burst clear.

**Position.** The two sliders move the picture on the CRT, in the board's
own dots and lines, for a set whose picture sits off centre (the first one
tried with Moo Mesa showed it about 10 lines high). They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing. Directions are the
raster's, not the cabinet's: on a set turned on its side (below), "H" moves
the picture along the set's own scan lines, which is up and down as the game
is played. The range is short on the + side because the board leaves little
blanking there: 8 dots before hsync, and 4 lines before vsync.

**Video.** The core sends the board's own signal, at the board's own line
and frame rate -- the timing a 15 kHz arcade monitor or a PVM expects:
256 × 224 visible, 384 × 264 dots at 6.144 MHz, 16.0 kHz lines, 60.6 Hz
(`rtl/tp84_video.sv`).

**The picture is not rotated.** The cabinet's monitor stood on its side,
and the Analogizer gets the board's raster as that monitor saw it; only the
Pocket's scaler turns the picture (`rotation: 90` in `video.json`). On a CRT
the game is upright when the set is turned on its side as the cabinet's was:
clockwise as you face it, the top of the set to the right, the same
orientation as MAME's ROT90. On a set left flat the game plays sideways.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: twice the line rate |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Four SNAC players need the PC Engine multitap. A pad's buttons arrive as the
Pocket's own (SNAC's A is the Pocket's A, and so on), so they do whatever the
core maps those to. A PlayStation pad in analog mode steers with its left
stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

Say in the core's README whether it has been tried on an Analogizer. What
the bench proves is listed under *What was measured* below. Send problems with
the adapter itself to the Analogizer project.

**Trying it on hardware**, in this order -- each step's reading tells the
next one where to look:

1. Menu "Analogizer: Off" (the default): the game plays exactly as 0.1.5,
   on the Pocket's screen and controls. If not, the cart port is not idle:
   stop there.
2. Analogizer On, Video RGBS, SNAC Adapter None, the CRT on its side: the
   same picture on both, 16.0 kHz / 60.6 Hz. No picture at all: say whether
   the CRT reports a signal.
3. Each other video mode (RGsB and YPbPr need the SOG switch on).
4. SNAC: one pad, "SNAC P1 -> P1"; the Pocket's own controls also play.
5. Change Video, quit and reload: it, and Analogizer On, are still set;
   changing one entry leaves the others alone.
6. Position: a + and a - value on each slider move the picture and are kept
   across a reload. A value shown other than the one set means the firmware
   does not read 0xF7000004/8 back as written.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim**, from MiraxPocket (`src/fpga/analogizer/`, commit 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f, GPL-3.0-or-later). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, picture position, SNAC → controller words. Core-agnostic; the template's file, with one fix not yet in the template (the jump back to 0, under *Picture position*). |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (`LINE_LEN` 384, `CLK_HZ` 49,152,000, fed `tp84_core`'s own outputs), `key1..key4` in place of `cont1..4_key` into the `gamepad` helper, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `clk_sys` | the Analogizer's clock too: 49.152 MHz, 8 × the dot. No PLL output and no SDC change. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008`. 14 entries and one data slot, inside Analogue's 16 (`tools/check_json.py`) |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below); the raster at the top of `sim/tb_analogizer.sv` is `tp84_video.sv`'s |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead. At 0 the
source's own sync passes through under the same rule: with this board's
3-line vsync, V Position +4 to 0 in one step otherwise put the board's
pulse one line after the re-made one, and this core's bench caught it (a
frame of csync inverted, 458,752 clocks low inside the picture).

**The range is this board's blanking.** Hsync runs at dots 272–303 of
384; the picture is 8–263. Moving right, hsync can come 8 dots earlier
before it meets the picture: +8, and +9 fails the bench. Moving left, it
can come later until the Y/C colour burst, which ends about 3.5 µs (22
dots) after hsync does, would reach the picture: 88 − 22 = 66 dots; the
menu stops at −24. Vsync runs at lines 500–502 of the counter's 248–511;
the picture is 272–495. Moving down, vsync can come 4 lines earlier: +4,
and +5 fails the bench. Moving up, 33 lines of blanking follow it; the menu
stops at −24. `sim/run_analogizer.sh` tries both ends of the range in
`interact.json` and fails if csync is low while a dot is drawn.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so this core uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. This
core's `clk_sys` is 49.152 MHz, eight clocks a 6.144 MHz dot, so it is
passed as both the source clock and the Analogizer's: no PLL output, no SDC
change. `pocket_analogizer` takes each pixel `PIX_LAG` (2) clocks after the
dot enable -- `tp84_video.sv` registers the colour on the enable itself --
into a holding register and hands it over with a toggle, which on one clock
is a short fixed delay.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`; this core reads its controls nowhere else.

The game reads one set of controls in upright mode, and core_top mirrors
player 1's onto player 2's (`tp_p2 = tp_p1`), with the platform's
`gamepad` helper combining the pads (`JOY_ALT`). So any SNAC pad -- and the
Pocket's own -- plays whichever player's turn it is, in upright and in
cocktail mode, and every SNAC Assignment works; "SNAC P1 -> P1" is all a
handheld pass-and-play needs.

### What was measured

- `sim/run_analogizer.sh` (PASS): the wrapper and the vendored module at this
  core's raster and clock (384 × 264 dots, 8 clocks a dot of 49.152 MHz),
  read at the cartridge pins as the DAC reads them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of the four Analogizer list entries in the package's
    `interact.json` (32), set as the firmware sets a masked entry, read back
    as the bridge samples it, merged and written: the word, the adapter's
    copy and the enable each followed.
  - RGBS: all 57,344 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, with 0 differing; 261 csync
    pulses of 32 dots.
  - Scandoubler: 528 lines per frame (twice 264) at 1536 clocks, half the
    core's 3072.
  - Position at +8,+4 and -24,-24: read back as written, the settings word
    untouched; at the pins csync moves by exactly 64 / -192 clocks (8 / -24
    dots) and 4 / -24 lines, the picture still all 57,344 dots with 0
    differing, csync never low while a dot is drawn, the scandoubler
    unchanged; back at 0, csync where it started. One step past either
    + end fails it: +9 dots (1,792 clocks of csync inside the picture), +5
    lines (2,048).
  - Jumps written just after a pulse (V +4 to 0, H +8 to -24, and H +8 to
    0): csync never low inside the picture over three frames. V +4 to 0 is
    the one that failed before the pass-through followed the off-time rule
    (458,752 clocks, a frame of inverted csync).
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled; the blank bit, and enable off again returning the port to idle.
- `sim/run_video.sh`: 0 differing pixels on all ten frozen states, as before
  (the machine is unchanged; this shows the tree still builds it).
- `sim/lint.sh`: clean, with the wrapper linted on its own and inside
  `core_top`; the vendored files' warnings are dropped by path.
- `tools/check_json.py pkg/pocket --active 256x224`: clean.
- Quartus 18.1: compiles; no negative slack at any corner. Worst setup
  +2.847 ns (slow 0C, clk_sys), worst hold +0.106 ns (fast 0C, clk_sys).
  The Analogizer costs 2,134 ALMs (6,657 → 8,791, 48%), 13 RAM blocks
  (118 → 131 of 308) and 3 DSP blocks (15 → 18); the "before" numbers are
  the last local compile (2026-08-20), not a fresh build of 0.1.5.
  `tp84_pocket.sdc` was ignored, in this build and (unchanged files) in
  0.1.5: the qsf reads it before the platform's `sys_constr.sdc` creates the
  clocks, and its `cpu_e`/`cpu_q` generated clocks name a PLL pin that does
  not match. That predates the Analogizer and is left for the core's own
  fix; the Analogizer needs nothing from it (one clock, `clk_sys`).

**Not proven:** anything on hardware; that the firmware writes a signed
slider as a two's-complement word; the SNAC serial protocols, which are the
adapter module's and are forced at its outputs in the bench rather than
driven over the pins; the Y/C and YPbPr encodings, which have no reference
to compare against, only a run without unknowns; the -24 dot end's colour
burst clearance, which is computed, not measured.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, and take the six menu entries
out of `interact.json` and `cartridge_adapter` back to -1 in `core.json`.
