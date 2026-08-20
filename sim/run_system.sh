#!/bin/sh
# Full-system bench: build the main board and boot the game.
#   sim/run_system.sh <frame> [more frames...]
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_system
verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
    --top-module tp84_main --Mdir "$BUILD" -o tb_system \
    -Imodules/cpu-mc6809 \
    rtl/tp_ram.sv rtl/tp84_video.sv rtl/tp84_main.sv \
    modules/cpu-mc6809/mc6809i.v sim/tb_system.cpp >/dev/null
for f in "$@"; do
    tag=$(printf "%04d" "$f")
    "$BUILD/tb_system" build/tp84.rom "$f" "build/sys_$tag.ppm" -ram "build/sys_$tag.txt"
done
