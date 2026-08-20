//------------------------------------------------------------------------------
// Time Pilot '84 sound board: Z80 @ 3.579545 MHz driving three SN76489As at
// 1.789773 MHz, each through its own switchable RC low-pass.
//
// docs/hardware.md 3 has the map. Three things matter for it to sound right:
//
//   * The timer at 8000 is (cycles / 1024) & 0x0F -- a free-running divider off
//     the sound Z80 clock, so it has to be a real counter here rather than
//     something derived from instructions executed.
//   * Writing anywhere in A000-A1FF sets the filters; the *address* is the
//     data, and the bit numbering in MAME's driver counts a fourth SN76489A
//     that was never fitted, so bits 3/4 belong to sn1, bit 7 to sn2 and bit 8
//     to sn3.
//   * MAME models each filter as a one-pole IIR at the chip's own stream rate,
//     which is clock/2. The coefficients below are computed from the same
//     resistor and capacitor values rather than approximated.
//
// The board runs from its own 14.31818 MHz crystal, asynchronous to the video
// board. Here both rates come from phase accumulators off the system clock.
//------------------------------------------------------------------------------
`default_nettype none

module tp84_sound (
    input  wire        clk,             //! 49.152 MHz
    input  wire        reset,
    input  wire        pause,

    // ---- from the main board ---------------------------------------------
    input  wire  [7:0] snd_data,
    input  wire        snd_irq,         //! one clk pulse per write to 3800

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- audio out --------------------------------------------------------
    output logic signed [15:0] audio,
    output logic       audio_ce,

    // ---- diagnostics ------------------------------------------------------
    output wire  [3:0] dbg_timer,
    output wire [15:0] dbg_filter,
    output logic [15:0] dbg_sn_writes,
    output logic [15:0] dbg_irqs
);

    // ------------------------------------------------- 3.579545 MHz enable
    // 2^24 * 3579545 / 49152000 = 1221817.3; 1221817 gives 3579544.1 Hz.
    localparam [24:0] ACC_STEP = 25'd1221817;
    logic [24:0] acc;
    logic        cen_z80_r;
    always_ff @(posedge clk) begin
        if (reset) begin
            acc <= 25'd0; cen_z80_r <= 1'b0;
        end else begin
            acc       <= {1'b0, acc[23:0]} + ACC_STEP;
            cen_z80_r <= acc[24];
        end
    end
    wire cen_z80 = cen_z80_r && !pause && !dl_we;

    // The SN76489As run at half the Z80 clock on the board -- both come from
    // the same crystal, divided by 4 and by 8 -- so derive one from the other
    // rather than running a second accumulator that could drift against it.
    logic sn_half;
    always_ff @(posedge clk) if (cen_z80) sn_half <= ~sn_half;
    wire cen_sn = cen_z80 && sn_half;

    // MAME's stream rate for these chips, and so the rate its filter
    // coefficients are computed at, is the chip clock over two.
    logic fs_half;
    always_ff @(posedge clk) if (cen_sn) fs_half <= ~fs_half;
    wire cen_fs = cen_sn && fs_half;

    // ------------------------------------------------------------------ CPU
    wire [15:0] cpu_a;
    wire  [7:0] cpu_do;
    logic [7:0] cpu_di;
    wire        cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n, cpu_rfsh_n, cpu_iorq_n;
    logic       irq_n;

    tv80s_cen u_cpu (
        .reset_n (~reset), .clk (clk), .cen (cen_z80),
        .wait_n (1'b1), .int_n (irq_n), .nmi_n (1'b1), .busrq_n (1'b1),
        .m1_n (cpu_m1_n), .mreq_n (cpu_mreq_n), .iorq_n (cpu_iorq_n),
        .rd_n (cpu_rd_n), .wr_n (cpu_wr_n), .rfsh_n (cpu_rfsh_n),
        .halt_n (), .busak_n (),
        .A (cpu_a), .di (cpu_di), .dout (cpu_do)
    );

    wire mem    = ~cpu_mreq_n && cpu_rfsh_n;
    wire mem_wr = mem && ~cpu_wr_n;

    // IM1 IRQ held until the CPU acknowledges it (MAME's HOLD_LINE)
    wire int_ack = ~cpu_m1_n && ~cpu_iorq_n;
    logic irq_req;
    always_ff @(posedge clk) begin
        if (reset)        irq_req <= 1'b0;
        else if (snd_irq) irq_req <= 1'b1;
        else if (int_ack) irq_req <= 1'b0;
        if (reset)        dbg_irqs <= 16'd0;
        else if (snd_irq) dbg_irqs <= dbg_irqs + 16'd1;
    end
    assign irq_n = ~irq_req;

    // ------------------------------------------------------------- decode
    wire sel_rom   = (cpu_a[15:14] == 2'b00);            // 0000-3FFF, 0000-1FFF filled
    wire sel_ram   = (cpu_a[15:12] == 4'h4);             // 4000-43FF
    wire sel_latch = (cpu_a[15:12] == 4'h6);             // 6000
    wire sel_timer = (cpu_a[15:12] == 4'h8);             // 8000
    wire sel_filt  = (cpu_a[15:13] == 3'b101);           // A000-BFFF
    wire sel_sn    = (cpu_a[15:12] == 4'hc);             // C000-C004

    wire  [7:0] rom_q;
    wire        dl_snd = dl_we && (dl_addr >= 18'h0A000) && (dl_addr < 18'h0C000);
    wire [17:0] o_snd  = dl_addr - 18'h0A000;
    tp_spram_dp #(.AW(13), .DW(8)) u_rom (
        .clk(clk), .wa(o_snd[12:0]), .we(dl_snd), .d(dl_data),
        .ra(cpu_a[12:0]), .q(rom_q));

    wire [7:0] ram_q;
    tp_spram_dp #(.AW(10), .DW(8)) u_ram (
        .clk(clk), .wa(cpu_a[9:0]), .we(sel_ram && mem_wr), .d(cpu_do),
        .ra(cpu_a[9:0]), .q(ram_q));

    // ------------------------------------------------------------- timer
    logic [9:0] tdiv;
    logic [3:0] tval;
    always_ff @(posedge clk) begin
        if (reset) begin tdiv <= 10'd0; tval <= 4'd0; end
        else if (cen_z80) begin
            tdiv <= tdiv + 10'd1;
            if (&tdiv) tval <= tval + 4'd1;
        end
    end
    assign dbg_timer = tval;

    // ---------------------------------------------------------- filters
    logic [11:0] filt;
    always_ff @(posedge clk) begin
        if (reset)                   filt <= 12'd0;
        else if (sel_filt && mem_wr) filt <= cpu_a[11:0];
    end
    assign dbg_filter = {4'd0, filt};

    // --------------------------------------------------------- SN76489A x3
    // C001, C003, C004; C000 and C002 are ignored (C002 is the chip the board
    // has a footprint for but never had fitted).
    //
    // The Z80 write strobe is about 13 system clocks long and the chips' clock
    // enable is 27 apart, so a write can fall entirely between two enables and
    // be missed -- which is exactly what made the board run, set its filters
    // and stay silent. Each write is therefore latched and held asserted until
    // the chip has actually been clocked once.
    wire sn_wr = sel_sn && mem_wr;
    logic sn_wr_d;
    logic [2:0] sn_pend;
    logic [7:0] sn_din;
    always_ff @(posedge clk) begin
        sn_wr_d <= sn_wr;
        if (reset) begin
            sn_pend <= 3'b000;
        end else begin
            if (cen_sn) sn_pend <= 3'b000;
            if (sn_wr && !sn_wr_d) begin
                sn_din <= cpu_do;
                case (cpu_a[2:0])
                    3'd1: sn_pend[0] <= 1'b1;
                    3'd3: sn_pend[1] <= 1'b1;
                    3'd4: sn_pend[2] <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    wire signed [10:0] sn1_o, sn2_o, sn3_o;

    jt89 u_sn1 (.rst(reset), .clk(clk), .clk_en(cen_sn),
                .wr_n(~sn_pend[0]), .cs_n(1'b0), .din(sn_din), .sound(sn1_o), .ready());
    jt89 u_sn2 (.rst(reset), .clk(clk), .clk_en(cen_sn),
                .wr_n(~sn_pend[1]), .cs_n(1'b0), .din(sn_din), .sound(sn2_o), .ready());
    jt89 u_sn3 (.rst(reset), .clk(clk), .clk_en(cen_sn),
                .wr_n(~sn_pend[2]), .cs_n(1'b0), .din(sn_din), .sound(sn3_o), .ready());

    always_ff @(posedge clk) begin
        if (reset)                  dbg_sn_writes <= 16'd0;
        else if (sn_wr && !sn_wr_d) dbg_sn_writes <= dbg_sn_writes + 16'd1;
    end

    always_comb begin
        cpu_di = 8'h00;
        if      (sel_rom)   cpu_di = rom_q;
        else if (sel_ram)   cpu_di = ram_q;
        else if (sel_latch) cpu_di = snd_data;
        else if (sel_timer) cpu_di = {4'd0, tval};
    end

    // ------------------------------------------------------- RC low-pass x3
    //   Req = R1*(R2+R3)/(R1+R2+R3) = 1000*3200/4200 = 761.9 ohm
    //   k   = 1 - exp(-1/(Req*C)/fs),  fs = 1789773/2 = 894886.5 Hz
    localparam [12:0] K_47N  = 13'd2014;   // 4444 Hz
    localparam [12:0] K_470N = 13'd204;    //  444 Hz
    localparam [12:0] K_517N = 13'd186;    //  404 Hz

    wire [1:0] sel1 = filt[4:3];           // sn1: 47nF and 470nF
    wire       sel2 = filt[7];             // sn2: 470nF
    wire       sel3 = filt[8];             // sn3: 470nF

    wire signed [15:0] f1, f2, f3;
    tp84_rc u_f1 (.clk(clk), .reset(reset), .cen(cen_fs),
                  .k(sel1 == 2'b00 ? 13'd0 : sel1 == 2'b01 ? K_47N :
                     sel1 == 2'b10 ? K_470N : K_517N),
                  .din(sn1_o), .dout(f1));
    tp84_rc u_f2 (.clk(clk), .reset(reset), .cen(cen_fs),
                  .k(sel2 ? K_470N : 13'd0), .din(sn2_o), .dout(f2));
    tp84_rc u_f3 (.clk(clk), .reset(reset), .cen(cen_fs),
                  .k(sel3 ? K_470N : 13'd0), .din(sn3_o), .dout(f3));

    // ------------------------------------------------- per-chip DC removal
    // The chips are unipolar, so an active channel carries a standing offset
    // of half its amplitude and that offset moves every time a channel starts
    // or stops. Remove it per chip, after the RC network and before the mix:
    // the RC filters then see exactly what MAME's filter_rc sees, while the
    // Pocket's single downstream DC blocker is no longer left chasing a
    // composite level that three chips move independently. The MiSTer core
    // does the same thing with jt49_dcrm2, one instance per chip.
    wire signed [15:0] d1, d2, d3;
    tp84_dcrm u_d1 (.clk(clk), .reset(reset), .cen(cen_fs), .din(f1), .dout(d1));
    tp84_dcrm u_d2 (.clk(clk), .reset(reset), .cen(cen_fs), .din(f2), .dout(d2));
    tp84_dcrm u_d3 (.clk(clk), .reset(reset), .cen(cen_fs), .din(f3), .dout(d3));

    // ------------------------------------------------------------------ mix
    logic signed [17:0] mix;
    always_ff @(posedge clk) if (cen_fs)
        mix <= {{2{d1[15]}}, d1} + {{2{d2[15]}}, d2} + {{2{d3[15]}}, d3};

    // Output gain, calibrated against MAME over a matched window. Re-measured
    // after jt89 was made unipolar -- a unipolar square carries less AC than a
    // bipolar one of the same peak, but the RC network and the three-chip sum
    // make it not quite a factor of two, so this was measured rather than
    // scaled: 33300 bipolar and 53530 unipolar both land +0.4 dB on MAME over
    // the same window.
    localparam [16:0] OUT_GAIN = 17'd53530;
    wire signed [35:0] scaled = mix * $signed({1'b0, OUT_GAIN});

    always_ff @(posedge clk) begin
        if (reset)       audio <= 16'sd0;
        else if (cen_fs) audio <= clamp16(scaled[35:16]);
        audio_ce <= cen_fs;
    end

    function automatic signed [15:0] clamp16(input signed [19:0] v);
        if (v > 20'sh0_7fff)       clamp16 = 16'sh7fff;
        else if (v < -20'sh0_8000) clamp16 = 16'sh8000;
        else                       clamp16 = v[15:0];
    endfunction

endmodule


//! DC removal: a running mean subtracted from the signal. The shift sets the
//! corner at fs / (2*pi*2^15) = 4.3 Hz, far below anything audible, so it
//! takes the standing offset out without touching the sound. Rounding rather
//! than truncating the increment keeps the residual under half a count.
module tp84_dcrm (
    input  wire               clk,
    input  wire               reset,
    input  wire               cen,
    input  wire signed [15:0] din,
    output wire signed [15:0] dout
);
    localparam int Q = 15;
    logic signed [31:0] acc;
    wire  signed [31:0] x   = {din[15], din, {Q{1'b0}}};
    wire  signed [31:0] err = x - acc;
    always_ff @(posedge clk) begin
        if (reset)    acc <= 32'sd0;
        else if (cen) acc <= acc + ((err + (1 <<< (Q-1))) >>> Q);
    end
    wire signed [16:0] y = {din[15], din} - $signed(acc[31:Q]);
    assign dout = (y >  17'sh0_7fff) ? 16'sh7fff :
                  (y < -17'sh0_8000) ? 16'sh8000 : y[15:0];
endmodule

//! One-pole low-pass matching MAME's filter_rc LOWPASS_3R. A coefficient of
//! zero means no capacitor is switched in, which MAME treats as a pass-through.
module tp84_rc (
    input  wire               clk,
    input  wire               reset,
    input  wire               cen,
    input  wire        [12:0] k,
    input  wire signed [10:0] din,
    output wire signed [15:0] dout
);
    logic signed [26:0] y;                       // Q16 with 11 integer bits
    wire  signed [27:0] err  = {din, 16'd0} - {y[26], y};
    wire  signed [40:0] prod = err * $signed({1'b0, k});

    always_ff @(posedge clk) begin
        if (reset)    y <= 27'sd0;
        else if (cen) y <= (k == 13'd0) ? {din, 16'd0}
                                        : (y + {{2{prod[40]}}, prod[40:16]});
    end
    assign dout = y[26:11];
endmodule

`default_nettype wire
