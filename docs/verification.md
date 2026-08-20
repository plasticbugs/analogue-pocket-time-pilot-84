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

## 4. What still needs real hardware

Everything above is simulation. Not yet settled:

* Real H/V timing. 384x264 at 6.144 MHz is inherited from the measurement in
  `konami/pooyan.cpp` rather than measured for this board.
* Whether sprites come from a line buffer filled during the previous line. The
  `update_partial` on every sprite RAM write says they are evaluated per
  scanline; it does not say when.
* Screen flip. MAME flips the tilemaps only, so the core's sprite flip is
  unverified — no captured state has either flip bit set.
