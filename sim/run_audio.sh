#!/bin/sh
# Record the sound board in Verilator.  sim/run_audio.sh <first_frame> <last_frame>
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_audio
verilator --cc --exe --build -j 0 -O2 -Wno-fatal --top-module tp84_core --Mdir "$BUILD" -o tb_audio \
    -Imodules/cpu-tv80 -Imodules/sound-jt89 -Imodules/cpu-mc6809 \
    rtl/tp_ram.sv rtl/tp84_video.sv rtl/tv80s_cen.v rtl/tp84_main.sv \
    rtl/tp84_sound.sv rtl/tp84_core.sv \
    modules/cpu-mc6809/mc6809i.v \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-jt89/jt89.v modules/sound-jt89/jt89_tone.v \
    modules/sound-jt89/jt89_noise.v modules/sound-jt89/jt89_vol.v \
    modules/sound-jt89/jt89_mixer.v sim/tb_audio.cpp >/dev/null
"$BUILD/tb_audio" build/tp84.rom "${1:-700}" "${2:-760}" build/rtl_audio.wav
