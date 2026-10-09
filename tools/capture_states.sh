#!/bin/sh
# Capture a spread of frozen states + matching MAME snapshots.
# One MAME run per state: freezing the CPU is a one-way door.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
# 1066 is the worst sprite load this game produces: all 24 sprites land on the
# same scanline, which happens in about 10% of gameplay frames. The original
# spread never sampled one, so the sprite engine had never been checked under
# maximum load.
FRAMES=${FRAMES:-"180 420 900 1066 1500 2100 2700 3300 3900"}
rm -rf "$OUT"; mkdir -p "$OUT" build/mamecfg
for f in $FRAMES; do
    tag=$(printf "%04d" "$f")
    # Headless: nothing may touch the display.  -video none stops MAME
    # rendering but not creating a window, and MAME's defaults are fullscreen,
    # which on macOS throws the desktop to another Space on every run.
    # SDL_VIDEODRIVER=dummy keeps SDL off the display, -videodriver dummy says
    # the same through MAME, and -window -nomaximize keeps any window that is
    # made regardless small.  -seconds_to_run caps the run if the script's
    # exit is missed (frame / 60 Hz, plus margin).
    SDL_VIDEODRIVER=dummy \
    TP_OUT="$OUT" TP_FRAME="$f" TP_TAG="$tag" TP_MODE="${TP_MODE:-1p}" \
    mame tp84 -rompath . -video none -videodriver dummy -window -nomaximize \
        -sound none -nothrottle -skip_gameinfo -seconds_to_run $((f / 60 + 30)) \
        -snapshot_directory "$OUT/snap_$tag" -cfg_directory build/mamecfg \
        -nvram_directory build/mamecfg -autoboot_script tools/dumpstate.lua \
        >/dev/null 2>&1
    snap=$(ls "$OUT/snap_$tag"/tp84/*.png 2>/dev/null | head -1)
    [ -n "$snap" ] || { echo "no snapshot for frame $f"; exit 1; }
    mv "$snap" "$OUT/mame_$tag.png"
    rm -rf "$OUT/snap_$tag"
    echo "captured $tag"
done
