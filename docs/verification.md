# How this core is checked

Same method as the Time Pilot core: MAME is treated as a program to interrogate,
not a reference to read. Gates cheapest first.

## 1. Reference renderer — `tools/regress_ref.sh`

`tools/tp84video.py` is a Python transcription of the video hardware: gfx
decode, the resistor-network palette, both lookup PROMs, tilemap scroll and
priority. `tools/render_model.py` renders a dumped state and diffs it against
MAME's own snapshot.

**Status: 0 differing pixels on all ten captured states**, with both scroll axes
exercised, two palette banks and up to 23 live sprites.

### Capturing states

`tools/capture_states.sh` drives MAME to a set of frames and dumps everything
the renderer reads plus a PNG.

Time Pilot froze the machine by parking its CPU in a jump-to-self. **That does
not work here**: setting PC through MAME's state interface does not redirect
MAME's 6809. The slave ran away at exactly 0x2156 bytes per frame, which is
NEG-direct through unmapped space at six cycles per two bytes — that arithmetic
is what identified it rather than a guess.

So the dumper freezes the video *state* instead of the CPUs: everything the
renderer reads is copied into Lua tables and write taps then return those saved
values. The CPUs keep running and MAME keeps doing its partial updates, but
every slice draws the same picture, and the dump is written from the same
tables so it cannot drift from what was drawn.

### The scroll sign was measured, not reasoned

Every state with `scroll == 0` passed and every state with a non-zero scroll
failed. Rendering all four sign combinations against a state with both axes
non-zero gave 399 differing background pixels for plus/plus against 5800-7700
for the others. Screen x maps to tilemap x **plus** the scroll.

## 2. Frozen-state video bench — `sim/run_video.sh`

Loads the `.rom` and a state dump into the video core's block RAMs in Verilator,
renders one frame, diffs against MAME. About ten seconds for the set.

**Status: 0 differing pixels on all ten states.**

It also fails on `dbg_spr_overrun`: the sprite engine has 1024 clocks per line
against a 696-clock worst case.

## 3. Full-system bench — `sim/run_system.sh`

Boots the game on both 6809s and compares the video state and the picture
against MAME at the same frame.

**Status: frame 300 (attract mode) is byte-identical in RAM and 0 differing
pixels. Gameplay frames diverge slowly** — 72 bytes at frame 700, growing after
that, with the palette bank and both scroll registers still tracking.

### Why gameplay cannot be byte-compared here, and Time Pilot could

Two reasons, and neither is a defect in the core:

* **MAME does not model the two 6809s cycle-accurately against each other.**
  The driver sets `set_maximum_quantum(attotime::from_hz(6000))` with the
  comment "a high value to ensure proper synchronization of the CPUs" — MAME
  runs them in 6 kHz slices. The core runs them genuinely in lockstep off one
  clock generator, as the board does. The interleaving therefore differs by
  construction, and this game's master and slave hand work to each other
  through shared RAM.
* **The frame rates differ on purpose.** The core runs at the measured 60.606 Hz
  and MAME's driver at 60.000, so the core executes about 1% fewer CPU cycles
  per frame. Time Pilot absorbed that because its single CPU is frame-locked to
  the NMI; here it shifts how much the slave completes between vblanks.

Attract mode matches exactly because nothing depends on the handshake timing
yet. What this gate can still prove is that both CPUs boot, run real code, and
reach an identical machine state through the whole boot and attract sequence —
and the frozen-state bench continues to prove the video path exactly.

## 3a. Motion comparison — `-vtrace`, `-range`, `-bgtrace`

Everything above §3 captures **one frame with the CPUs paused**. That is a real
gate for the renderer, and it is worth nothing at all for a fault that only
appears while the picture is moving. A bug shipped past all of it: half the
background tilemap went undrawn during scrolling, which no still frame could
show because the columns that were missing had been correct when the level
loaded.

The gate that catches this class runs the game and compares **every** frame:

```sh
# RTL: dump all four tilemap memories once per frame
build/sim_wr/tb_wr build/tp84.rom 712 /dev/null -vtrace 655 710 build/rtl_vt.txt
# MAME: the same memories, same input script
mame tp84 -rompath . -video none -sound none -nothrottle -skip_gameinfo \
     -autoboot_script build/vtrace.lua
```

Two things matter when reading the result:

- **Align the frames.** The bench and MAME do not start counting at the same
  instant; at the time of writing the RTL runs one frame ahead, so RTL frame
  *n* must be compared with MAME frame *n+1*. Compare at several offsets and
  take the best — a constant offset is a bench artefact, a growing difference
  is a bug. Before alignment the shared RAM looked 77 bytes different per
  frame; after, 1.6.
- **The stack is in video RAM.** The master's direct page is `$4400`, inside
  the fg video RAM, and its stack grows down from `$5000` through the fg colour
  RAM. So a handful of differing bytes in `FGCOLORRAM` is the interrupt frame
  sampled at a slightly different point, not a video fault. Differences in
  `BGVIDEORAM`, `FGVIDEORAM` or `BGCOLORRAM` are real.

`-range A B DIR` writes every frame as a PPM, captured live with the CPUs
running, which is what a person actually looks at. `-bgtrace` and `-shtrace`
are the same idea for a single memory, and `-wrlog` / `-bus` log the master's
writes and its whole address bus when the divergence has to be traced to the
instruction that caused it.

## 3b. Audio — `sim/run_audio.sh`, `-log`

Level is checked by decimating both the core's recording and a MAME
`-wavwrite` of the same window to 8 kHz, removing DC, and comparing RMS. The
shipped gain lands +0.41 dB on MAME.

Level agreement is necessary and not sufficient, and the gap is worth naming:
a core can match MAME's RMS and its band ratios exactly while sounding wrong
at every note boundary, because RMS says nothing about what the waveform does
in the moment a channel is switched on or off. Two faults were found by ear
after passing the level check, and neither would have been caught by it:

- **Resampling.** The 48 kHz handover point-sampled a box average whose nulls
  did not line up with the output rate, so chip harmonics near 48 kHz folded
  down near DC. Measured against a high-order reference decimation of the same
  recording, error was -21.4 dB relative to signal; averaging over the actual
  tick interval and adding a two-point average took it to -29.8 dB.
- **Polarity.** jt89 drove each channel bipolar, so switching a channel off
  moved its output to 0 -- the midpoint of its own swing, a level that waveform
  never occupies. Every note-off was a splice to a mismatched point. The real
  SN76489A and MAME's sn76496 are unipolar, where a switch-off lands on 0,
  which the square wave already visits every cycle.

`sim/run_audio.sh` with `-log` dumps every sound-chip and filter write against
the audio sample index, which is how the second one was pinned down: the pop at
t=0.7729s followed a channel volume going 15 -> 4 half a millisecond earlier.
Note that the game writes each byte to $C000 first -- an address MAME maps as
`nopw()` -- and then to the real chip, so writes appear in the log in pairs.

Do not try to diff the two recordings sample by sample. The best normalised
correlation achievable between them is about +0.4: same music, different
waveform detail. Compare statistics, and listen.

## 4. Synthesis

`./build-local.sh map` is a one-minute check before every push; the full compile
takes about fifteen.

| resource | used | available |
|---|---|---|
| Logic (ALMs) | 6,657 | 18,480 (36%) |
| RAM blocks | 118 | 308 (38%) |
| DSP blocks | 15 | 66 (23%) |
| PLLs | 2 | 4 |

Timing closes with every corner positive, the worst at +0.127 ns.

Two things had to be fixed to get there, and both were silent failures rather
than errors.

**The shared RAM did not infer.** The first fit came back at 126% logic with the
2 KB shared RAM between the two 6809s realised as 31,568 ALUTs and 16,400
flip-flops -- 73% of the design. An M10K in true dual-port mode cannot return
the old contents on a write, so a read-old-data template falls back to logic the
moment *both* ports write. Altera's write-through form, one always block per
port, took the design from 45,771 logic cells to 13,801. Nothing here reads and
writes the same port in the same cycle, so which data a port returns on its own
write is unobservable.

**The timing exceptions were being dropped.** `cpu_e` and `cpu_q` are generated
from clk_sys by a 32-count divider, and the analyser was pairing them at
essentially coincident edges -- the worst path reported a launch-to-latch
relationship of 0.010 ns. The multicycle exceptions meant to fix that never
applied, because `get_clocks` matches with Tcl globbing and `general[0]` is a
character class matching the single character "0": the pattern selected nothing
at all. Two compiles produced byte-identical slack before that was spotted; the
brackets have to be escaped.

## 5. What still needs real hardware

Everything above is simulation. Not yet settled:

* Real H/V timing. 384x264 at 6.144 MHz is inherited from the measurement in
  `konami/pooyan.cpp` rather than measured for this board.
* Whether sprites come from a line buffer filled during the previous line. The
  `update_partial` on every sprite RAM write says they are evaluated per
  scanline; it does not say when.
* Screen flip. MAME flips the tilemaps only, so the core's sprite flip is
  unverified — no captured state has either flip bit set.
