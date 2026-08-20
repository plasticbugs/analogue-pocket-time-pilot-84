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
static int reset_at = -1;      // -resetat N: pulse reset after frame N
// -range A B DIR: dump every frame in [A,B] as DIR/rtl_%04d.ppm, captured
// live with the CPUs running. Every other capture in this bench pauses the
// CPUs first, which freezes the scroll registers and the tilemap -- exactly
// the conditions under which a fault that only appears while scrolling
// cannot show itself.
static int range_lo = -1, range_hi = -1;
static const char *range_dir = nullptr;
// -bgtrace A B FILE: dump the background tilemap every frame, same format as
// build/bgtrace.lua, so the two can be diffed frame by frame.
static int bgt_lo = -1, bgt_hi = -1;
static const char *bgt_path = nullptr;
static FILE *bgt_f = nullptr;
// -wrlog A B: print every master-CPU write into 4000-4FFF over frames [A,B],
// with the PC that issued it.
static int wr_lo = -1, wr_hi = -1;
// -shtrace A B FILE: the master/slave shared RAM every frame. It is the
// master's only work RAM, so the first divergence there is upstream of any
// tilemap symptom.
static int sh_lo = -1, sh_hi = -1;
static const char *sh_path = nullptr;
static FILE *sh_f = nullptr;
// -bus A B FILE: the master's address bus at every E falling edge over frames
// [A,B]. Diffing a frame that draws a tilemap column against one that should
// points straight at the branch that goes the wrong way.
static int bus_lo = -1, bus_hi = -1;
static const char *bus_path = nullptr;
static FILE *bus_f = nullptr;
// -vtrace A B FILE: all four tilemap memories every frame. The master's
// direct page is 4400, inside the fg video RAM, so game variables live here
// too and a divergence is not necessarily a video symptom.
static int vt_lo = -1, vt_hi = -1;
static const char *vt_path = nullptr;
static FILE *vt_f = nullptr;
// The Interact reset holds for 8000 clk_74a cycles = 107.7 us; at 49.152 MHz
// that is 5294 clk_sys cycles.
static const int RESET_CLKS = 5294;

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
        else if (!strcmp(argv[i], "-resetat") && i + 1 < argc) reset_at = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-vtrace") && i + 3 < argc) {
            vt_lo = atoi(argv[++i]); vt_hi = atoi(argv[++i]); vt_path = argv[++i];
        }
        else if (!strcmp(argv[i], "-bus") && i + 3 < argc) {
            bus_lo = atoi(argv[++i]); bus_hi = atoi(argv[++i]); bus_path = argv[++i];
        }
        else if (!strcmp(argv[i], "-shtrace") && i + 3 < argc) {
            sh_lo = atoi(argv[++i]); sh_hi = atoi(argv[++i]); sh_path = argv[++i];
        }
        else if (!strcmp(argv[i], "-wrlog") && i + 2 < argc) {
            wr_lo = atoi(argv[++i]); wr_hi = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-bgtrace") && i + 3 < argc) {
            bgt_lo = atoi(argv[++i]); bgt_hi = atoi(argv[++i]); bgt_path = argv[++i];
        }
        else if (!strcmp(argv[i], "-range") && i + 3 < argc) {
            range_lo = atoi(argv[++i]); range_hi = atoi(argv[++i]); range_dir = argv[++i];
        }
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
    bool did_reset = false;
    long long vec_fetches = 0;
    int prev_e = 0;
    set_inputs(-FRAME_SKEW);
    // Per-frame view of which tilemap columns the game rewrites, in the same
    // shape as tools/bgpoll.lua, so RTL and MAME can be lined up directly.
    unsigned char prev[1024];
    memset(prev, 0xff, sizeof prev);
    std::vector<unsigned char> live;
    int live_prev_ce = 0;
    live.reserve(256 * 224 * 3);
    while (vbl < target + FRAME_SKEW) {
        tick();
        if (bus_path) {
            int gf = vbl - FRAME_SKEW;
            if (gf >= bus_lo && gf <= bus_hi) {
                auto *rp = dut->rootp;
                int e = rp->tp84_main__DOT__cpu_e;
                static int pe = 0;
                if (pe && !e) {
                    if (!bus_f) bus_f = fopen(bus_path, "w");
                    fprintf(bus_f, "%d %04x %d %02x\n", gf,
                            rp->tp84_main__DOT__m_addr,
                            rp->tp84_main__DOT__m_rnw ? 1 : 0,
                            (rp->tp84_main__DOT__m_rnw ? rp->tp84_main__DOT__m_din
                                                       : rp->tp84_main__DOT__m_dout) & 0xff);
                }
                pe = e;
            }
        }
        if (wr_lo >= 0) {
            int gf = vbl - FRAME_SKEW;
            if (gf >= wr_lo && gf <= wr_hi) {
                auto *rp = dut->rootp;
                if (rp->tp84_main__DOT__m_wr) {
                    unsigned a = rp->tp84_main__DOT__m_addr;
                    if (a >= 0x4000 && a < 0x5000)
                        printf("[w] f%d %04x <= %02x  pc=%04x\n", gf, a,
                               rp->tp84_main__DOT__m_dout & 0xff, dut->dbg_pc_main);
                }
            }
        }
        if (range_dir) {
            int gf = vbl - FRAME_SKEW;
            int ce = dut->ce_pix;
            if (live_prev_ce && !ce && dut->de && gf >= range_lo && gf <= range_hi) {
                live.push_back(dut->red); live.push_back(dut->green); live.push_back(dut->blue);
            }
            live_prev_ce = ce;
        }
        // count reset-vector fetches so a reboot can be seen, not inferred
        {
            int e = dut->rootp->tp84_main__DOT__cpu_e;
            // only FFFE: the 6809 parks on FFFF during dead cycles, so counting
            // that counts almost every idle cycle
            if (prev_e && !e && dut->dbg_pc_main == 0xfffe)
                vec_fetches++;
            prev_e = e;
        }
        if (dut->vblank_rise_o) {
            if (range_dir) {
                int gf = vbl - FRAME_SKEW;
                if (gf >= range_lo && gf <= range_hi && (int)live.size() == 256 * 224 * 3) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/rtl_%04d.ppm", range_dir, gf);
                    FILE *lf = fopen(fn, "wb");
                    if (lf) {
                        fprintf(lf, "P6\n256 224\n255\n");
                        fwrite(live.data(), 1, live.size(), lf);
                        fclose(lf);
                    }
                    printf("[f%4d] scroll=%02x,%02x pb=%02x\n", gf,
                           dut->dbg_scroll_x, dut->dbg_scroll_y, dut->dbg_palette_bank);
                } else if (gf >= range_lo && gf <= range_hi) {
                    printf("[f%4d] SHORT FRAME: %zu px\n", gf, live.size() / 3);
                }
                live.clear();
            }
            if (vt_path) {
                int gf = vbl - FRAME_SKEW;
                if (gf >= vt_lo && gf <= vt_hi) {
                    if (!vt_f) vt_f = fopen(vt_path, "w");
                    auto *rp = dut->rootp;
                    fprintf(vt_f, "%d ", gf);
                    for (int i = 0; i < 1024; i++)
                        fprintf(vt_f, "%02x", rp->tp84_main__DOT__u_video__DOT__u_bgv__DOT__mem[i] & 0xff);
                    for (int i = 0; i < 1024; i++)
                        fprintf(vt_f, "%02x", rp->tp84_main__DOT__u_video__DOT__u_fgv__DOT__mem[i] & 0xff);
                    for (int i = 0; i < 1024; i++)
                        fprintf(vt_f, "%02x", rp->tp84_main__DOT__u_video__DOT__u_bgc__DOT__mem[i] & 0xff);
                    for (int i = 0; i < 1024; i++)
                        fprintf(vt_f, "%02x", rp->tp84_main__DOT__u_video__DOT__u_fgc__DOT__mem[i] & 0xff);
                    fprintf(vt_f, "\n");
                }
            }
            if (sh_path) {
                int gf = vbl - FRAME_SKEW;
                if (gf >= sh_lo && gf <= sh_hi) {
                    if (!sh_f) sh_f = fopen(sh_path, "w");
                    auto &mem = dut->rootp->tp84_main__DOT__u_share__DOT__mem;
                    fprintf(sh_f, "%d ", gf);
                    for (int i = 0; i < 2048; i++) fprintf(sh_f, "%02x", mem[i] & 0xff);
                    fprintf(sh_f, "\n");
                }
            }
            if (bgt_path) {
                int gf = vbl - FRAME_SKEW;
                if (gf >= bgt_lo && gf <= bgt_hi) {
                    if (!bgt_f) bgt_f = fopen(bgt_path, "w");
                    auto &mem = dut->rootp->tp84_main__DOT__u_video__DOT__u_bgv__DOT__mem;
                    fprintf(bgt_f, "%d ", gf);
                    for (int i = 0; i < 1024; i++) fprintf(bgt_f, "%02x", mem[i] & 0xff);
                    fprintf(bgt_f, "\n");
                }
            }
            vbl++;
            set_inputs(vbl - FRAME_SKEW);
            if (reset_at >= 0 && !did_reset && (vbl - FRAME_SKEW) == reset_at) {
                did_reset = true;
                long long before = vec_fetches;
                dut->reset = 1;
                for (int i = 0; i < RESET_CLKS; i++) tick();
                dut->reset = 0;
                printf("[rst] pulsed reset for %d clks after frame %d "
                       "(reset-vector fetches before=%lld)\n",
                       RESET_CLKS, reset_at, before);
            }
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

    if (bgt_f) fclose(bgt_f);
    if (sh_f) fclose(sh_f);
    if (bus_f) fclose(bus_f);
    if (vt_f) fclose(vt_f);
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

    if (reset_at >= 0)
        printf("[rst] reset-vector fetches total=%lld  (a reboot should add some)\n",
               vec_fetches);
    if (!quiet)
        printf("frame %d: wrote %s%s%s  (overrun=%d watchdog=%d mainpc=%04x subpc=%04x "
               "pb=%02x scroll=%d,%d)\n",
               target, ppm_path, ram_path ? " + " : "", ram_path ? ram_path : "",
               dut->dbg_spr_overrun, dut->dbg_watchdog, dut->dbg_pc_main, dut->dbg_pc_sub,
               dut->dbg_palette_bank, dut->dbg_scroll_x, dut->dbg_scroll_y);
    return 0;
}
