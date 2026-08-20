# Time Pilot '84 for Analogue Pocket

An openFPGA core for **Time Pilot '84** (Konami, 1984), reimplementing the
arcade hardware: two MC6809Es over shared RAM, a Z80 driving three SN76489As,
two tilemaps with a scrolling background, 4bpp sprites and an indexed palette
whose bank is selected at runtime.

Despite the name it shares almost nothing with Time Pilot beyond the
manufacturer, the master crystal and the Konami video timing chain.

The whole 99 KB romset fits in block RAM, so there is no SDRAM in the design.

> **ROMs are not included and never will be.** You supply your own MAME `tp84`
> romset; the core reads one image built from it.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card.
2. Build the ROM image and copy it to `Assets/timepilot84/common/tp84.rom`:

   ```sh
   python3 mra_build.py tp84.mra tp84.zip
   ```

   Nothing but Python 3 is needed. It checks every ROM's CRC32 and verifies the
   finished 99,584-byte image, so a wrong or bad romset is reported rather than
   silently built.

## Controls

| | |
|---|---|
| Move | D-pad (8 directions) |
| Fire | B |
| Missile | A |
| Insert coin | Select |
| 1 player start | Start |
| 2 player start | Y |

Player 2 is mirrored onto the same pad, so in upright mode — the default — the
console can just be handed over between turns.

## The screen

The monitor is mounted rotated. The core emits the native 256x224 raster and the
Pocket's scaler turns it 90 degrees clockwise. **Screen Shape** in the Interact
menu switches between the arcade shape (black bars either side) and filling the
screen; it reads the choice every frame, so it switches live.

`aspect_w`/`aspect_h` in `video.json` describe the raster *before* rotation, so
the arcade entry is written `10:9`, not `3:4` — measured on the Time Pilot core.

## How it is verified

Everything is checked against MAME; see [docs/verification.md](docs/verification.md).

| gate | what it proves | runtime |
|---|---|---|
| `tools/regress_ref.sh` | the Python model of the video hardware matches MAME | seconds |
| `sim/run_video.sh` | the video RTL matches that model, pixel for pixel | ~10 s |
| `sim/run_system.sh` | both 6809s boot and reach MAME's exact machine state | minutes |
| `sim/run_audio.sh` | the sound board's level against MAME's recording | minutes |

Current status: **0 differing pixels on ten frozen states**, video memory
**byte-identical to MAME through boot and attract mode**, and audio within
0.3 dB of MAME's recording of the same window.

Gameplay frames are not byte-compared, and `docs/verification.md` §3 explains
why that is a property of MAME rather than of the core: MAME runs the two 6809s
in 6 kHz slices by its own admission, while the core runs them in lockstep as
the board does.

[docs/hardware.md](docs/hardware.md) is the hardware map.

## Building

```sh
./build-local.sh map        # analysis & synthesis only
./build-local.sh            # full compile, then package into release/pocket/
```

Needs Docker and the `raetro/quartus:pocket` image. CI does the same on push.

## Credits and licences

* [mc6809](https://github.com/cavnex/mc6809) — cycle-accurate MC6809E by Greg
  Miller, used under the BSD option of its licence.
* [tv80](https://github.com/hutch31/tv80) — Z80, MIT.
* [jt89](https://github.com/jotego/jt89) — SN76489, GPLv3, by Jose Tejada.
* [OpenGateware](https://github.com/opengateware) Pocket platform — MIT/BSD.
* MAME's `tp84` driver by Aaron Giles, used as the oracle throughout.

This core is GPLv3, following jt89.
