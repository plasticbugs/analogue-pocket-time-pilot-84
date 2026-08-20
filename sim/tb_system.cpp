// Full-system bench: boot the real game on the real 6809s and look at what
// comes out.
//
// Drives the same scripted inputs as tools/dumpstate.lua, runs to a target
// frame, pauses the CPUs and captures one clean frame as a native 256x224 PPM.
// With -ram it also dumps the video state in the same text format the Lua
// dumper writes, so RTL and MAME state can be diffed directly.
//
//   tb_system <tp84.rom> <frame> <out.ppm> [-ram out_state.txt] [-2p] [-quiet]

#include "Vtp84_main.h"
#include "Vtp84_main___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>

static Vtp84_main *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

// The RTL bench and the MAME dumper do not start their frame counters at the
// same instant and do not stop at the same point inside a frame. Measured, not
// assumed -- see docs/verification.md.
static int FRAME_SKEW = 2;
static bool two_player = false;
static bool bgpoll = false;

static void set_inputs(int frame) {
    unsigned sys = 0xff, p1 = 0xff;
    if (two_player) {
        if ((frame >= 600 && frame < 604) || (frame >= 620 && frame < 624)) sys &= ~0x01u;
        if (frame >= 660 && frame < 664) sys &= ~0x10u;   // 2 player start
    } else {
        if (frame >= 600 && frame < 604) sys &= ~0x01u;   // coin 1
        if (frame >= 660 && frame < 664) sys &= ~0x08u;   // 1 player start
    }
    if (frame > 700) {
        p1 &= ~0x10u;                                      // button 1
        if ((frame / 30) % 4 == 0) p1 &= ~0x20u;           // button 2
        if ((frame / 60) % 2 == 0) p1 &= ~0x02u; else p1 &= ~0x01u;
    }
    dut->in_system = sys;
    dut->in_p1 = p1;
}

static std::vector<unsigned char> load_rom(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> d(n);
    if (fread(d.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); exit(1); }
    fclose(f);
    return d;
}

template <typename T>
static void dump_region(FILE *f, const char *name, const T &mem, size_t len) {
    fprintf(f, "%s\n", name);
    for (size_t i = 0; i < len; i++) {
        fprintf(f, "%02x", mem[i] & 0xff);
        if ((i % 32) == 31) fputc('\n', f);
    }
    if (len % 32) fputc('\n', f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: tb_system <rom> <frame> <out.ppm> [-ram state.txt] [-2p] [-quiet]\n");
        return 2;
    }
    const char *rom_path = argv[1];
    const int target = atoi(argv[2]);
    const char *ppm_path = argv[3];
    const char *ram_path = nullptr;
    bool quiet = false;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-ram") && i + 1 < argc) ram_path = argv[++i];
        else if (!strcmp(argv[i], "-2p")) two_player = true;
        else if (!strcmp(argv[i], "-quiet")) quiet = true;
        else if (!strcmp(argv[i], "-skew") && i + 1 < argc) FRAME_SKEW = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-bgpoll")) bgpoll = true;
    }

    dut = new Vtp84_main;
    dut->reset = 1;
    dut->pause = 0;
    dut->in_system = dut->in_p1 = dut->in_p2 = 0xff;
    dut->dsw1 = 0xff;          // 1 coin 1 credit both slots
    dut->dsw2 = 0x32;          // 3 lives, upright, 20k/60k, hard, demo sounds on
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();

    auto rom = load_rom(rom_path);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    dut->dl_we = 0;
    // Hold reset for ~64 E periods with E and Q running: the 6809 core has no
    // system clock, so it only initialises on edges of E while nRESET is low.
    for (int i = 0; i < 64 * 32; i++) tick();
    dut->reset = 0;

    int vbl = 0;
    set_inputs(-FRAME_SKEW);
    // Per-frame view of which tilemap columns the game rewrites, in the same
    // shape as tools/bgpoll.lua, so RTL and MAME can be lined up directly.
    unsigned char prev[1024];
    memset(prev, 0xff, sizeof prev);
    while (vbl < target + FRAME_SKEW) {
        tick();
        if (dut->vblank_rise_o) {
            vbl++;
            set_inputs(vbl - FRAME_SKEW);
            if (bgpoll) {
                auto &mem = dut->rootp->tp84_main__DOT__u_video__DOT__u_bgv__DOT__mem;
                int changed = 0, cols[32] = {0};
                for (int i = 0; i < 1024; i++) {
                    unsigned char v = mem[i] & 0xff;
                    if (v != prev[i]) { prev[i] = v; if (vbl > 1) { changed++; cols[i & 31]++; } }
                }
                int gf = vbl - FRAME_SKEW;
                if (changed && gf >= 250 && gf <= 720) {
                    printf("[bg] frame %4d: %4d changed ", gf, changed);
                    int shown = 0;
                    for (int c = 0; c < 32 && shown < 8; c++)
                        if (cols[c]) { printf(" c%d:%d", c, cols[c]); shown++; }
                    printf("\n");
                }
            }
        }
    }

    dut->pause = 1;
    const int W = 256, H = 224;
    std::vector<unsigned char> img;
    img.reserve(W * H * 3);
    int seen = 0, prev_ce = 0;
    bool capturing = false;
    long long guard = 0;
    while (seen < 3 && guard < 20000000LL) {
        tick(); guard++;
        if (dut->vblank_rise_o) {
            seen++;
            if (seen == 1) capturing = true;
            if (seen == 2) break;
        }
        int ce = dut->ce_pix;
        if (prev_ce && !ce && capturing && dut->de) {
            img.push_back(dut->red); img.push_back(dut->green); img.push_back(dut->blue);
        }
        prev_ce = ce;
    }
    if ((int)img.size() != W * H * 3) {
        fprintf(stderr, "captured %zu pixels, expected %d\n", img.size() / 3, W * H);
        return 1;
    }

    FILE *o = fopen(ppm_path, "wb");
    if (!o) { fprintf(stderr, "cannot write %s\n", ppm_path); return 1; }
    fprintf(o, "P6\n%d %d\n255\n", W, H);
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);

    if (ram_path) {
        auto *r = dut->rootp;
        FILE *f = fopen(ram_path, "w");
        if (!f) { fprintf(stderr, "cannot write %s\n", ram_path); return 1; }
        fprintf(f, "frame %d\n", target);
        fprintf(f, "flipx %d\n", dut->dbg_flip & 1);
        fprintf(f, "flipy %d\n", (dut->dbg_flip >> 1) & 1);
        dump_region(f, "BGVIDEORAM", r->tp84_main__DOT__u_video__DOT__u_bgv__DOT__mem, 1024);
        dump_region(f, "FGVIDEORAM", r->tp84_main__DOT__u_video__DOT__u_fgv__DOT__mem, 1024);
        dump_region(f, "BGCOLORRAM", r->tp84_main__DOT__u_video__DOT__u_bgc__DOT__mem, 1024);
        dump_region(f, "FGCOLORRAM", r->tp84_main__DOT__u_video__DOT__u_fgc__DOT__mem, 1024);
        dump_region(f, "SPRITERAM",  r->tp84_main__DOT__u_video__DOT__u_spr__DOT__mem, 96);
        fprintf(f, "PALETTEBANK\n%02x\n", dut->dbg_palette_bank);
        fprintf(f, "SCROLLX\n%02x\n", dut->dbg_scroll_x);
        fprintf(f, "SCROLLY\n%02x\n", dut->dbg_scroll_y);
        fprintf(f, "END\n");
        fclose(f);
    }

    if (!quiet)
        printf("frame %d: wrote %s%s%s  (overrun=%d watchdog=%d mainpc=%04x subpc=%04x "
               "pb=%02x scroll=%d,%d)\n",
               target, ppm_path, ram_path ? " + " : "", ram_path ? ram_path : "",
               dut->dbg_spr_overrun, dut->dbg_watchdog, dut->dbg_pc_main, dut->dbg_pc_sub,
               dut->dbg_palette_bank, dut->dbg_scroll_x, dut->dbg_scroll_y);
    return 0;
}
