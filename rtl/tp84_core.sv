//------------------------------------------------------------------------------
// Time Pilot '84: the whole machine.
//
// A video board with two MC6809Es sharing RAM, and a sound board with a Z80 and
// three SN76489As, meeting only at a command latch and an interrupt line. The
// whole 99 KB romset lives in block RAM, so every access is single cycle.
//------------------------------------------------------------------------------
`default_nettype none

module tp84_core (
    input  wire        clk,             //! 49.152 MHz = 8x the dot clock
    input  wire        reset,
    input  wire        pause,

    input  wire  [7:0] in_system,
    input  wire  [7:0] in_p1,
    input  wire  [7:0] in_p2,
    input  wire  [7:0] dsw1,
    input  wire  [7:0] dsw2,

    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        de,
    output wire        ce_pix,
    output wire        vblank_rise,

    output wire signed [15:0] audio,
    output wire        audio_ce,

    output wire        dbg_spr_overrun,
    output wire        dbg_watchdog,
    output wire [15:0] dbg_pc_main,
    output wire [15:0] dbg_pc_sub,
    output wire  [7:0] dbg_palette_bank,
    output wire  [7:0] dbg_scroll_x,
    output wire  [7:0] dbg_scroll_y,
    output wire  [1:0] dbg_flip,
    output wire  [3:0] dbg_snd_timer,
    output wire [15:0] dbg_snd_filter,
    output wire [15:0] dbg_sn_writes,
    output wire [15:0] dbg_snd_irqs
);

    wire [7:0] snd_data;
    wire       snd_irq;

    tp84_main u_main (
        .clk(clk), .reset(reset), .pause(pause),
        .in_system(in_system), .in_p1(in_p1), .in_p2(in_p2),
        .dsw1(dsw1), .dsw2(dsw2),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .snd_data(snd_data), .snd_irq(snd_irq),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .de(de), .ce_pix(ce_pix), .vblank_rise_o(vblank_rise),
        .dbg_spr_overrun(dbg_spr_overrun), .dbg_watchdog(dbg_watchdog),
        .dbg_pc_main(dbg_pc_main), .dbg_pc_sub(dbg_pc_sub),
        .dbg_palette_bank(dbg_palette_bank),
        .dbg_scroll_x(dbg_scroll_x), .dbg_scroll_y(dbg_scroll_y),
        .dbg_flip(dbg_flip)
    );

    tp84_sound u_sound (
        .clk(clk), .reset(reset), .pause(pause),
        .snd_data(snd_data), .snd_irq(snd_irq),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .audio(audio), .audio_ce(audio_ce),
        .dbg_timer(dbg_snd_timer), .dbg_filter(dbg_snd_filter),
        .dbg_sn_writes(dbg_sn_writes), .dbg_irqs(dbg_snd_irqs)
    );

endmodule

`default_nettype wire
