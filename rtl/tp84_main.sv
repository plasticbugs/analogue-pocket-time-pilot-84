//------------------------------------------------------------------------------
// Time Pilot '84 main board: two MC6809Es at 1.536 MHz over shared RAM, the
// LS259 control latch, the I/O decode and the video hardware.
//
// The master owns the tilemaps and the I/O; the slave owns sprite RAM and reads
// the beam position. They meet only at a 2 KB shared RAM -- 5000-57FF on the
// master, 8000-87FF on the slave -- which is a true dual-port block RAM here.
// On the board the two CPUs run from the same clock generator and their bus
// accesses interleave; a dual-port RAM is more permissive than that, never less.
//
// mc6809i is clocked by its E and Q inputs rather than a system clock, so both
// are generated here as a quadrature pair off clk_sys: 32 system clocks per E
// period, Q leading E by a quarter.
//------------------------------------------------------------------------------
`default_nettype none

module tp84_main (
    input  wire        clk,            //! 49.152 MHz
    input  wire        reset,
    input  wire        pause,

    // ---- inputs (active low, as the CPU reads them) ----------------------
    input  wire  [7:0] in_system,
    input  wire  [7:0] in_p1,
    input  wire  [7:0] in_p2,
    input  wire  [7:0] dsw1,
    input  wire  [7:0] dsw2,

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- to the sound board ----------------------------------------------
    output logic [7:0] snd_data,
    output logic       snd_irq,

    // ---- video out ---------------------------------------------------------
    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        de,
    output wire        ce_pix,
    output wire        vblank_rise_o,

    // ---- diagnostics --------------------------------------------------------
    output wire        dbg_spr_overrun,
    output logic       dbg_watchdog,
    output wire [15:0] dbg_pc_main,
    output wire [15:0] dbg_pc_sub,
    output wire  [7:0] dbg_palette_bank,
    output wire  [7:0] dbg_scroll_x,
    output wire  [7:0] dbg_scroll_y,
    output wire  [1:0] dbg_flip
);

    // ---------------------------------------------------- E / Q generation
    // 49.152 MHz / 32 = 1.536 MHz, Q leading E by 90 degrees.
    // E and Q free-run: they are NOT gated by reset. mc6809i has no system
    // clock -- its only sequential elements are clocked by E and Q -- so
    // holding them still during reset means the core never sees a clocked edge
    // with nRESET asserted and never initialises. It then comes out of reset
    // taking a spurious NMI: twelve pushes onto an uninitialised stack, then a
    // vector fetch from FFFC. Hold reset for a few E periods instead.
    logic [4:0] eq;
    logic       cpu_e, cpu_q;
    always_ff @(posedge clk) begin
        if (!pause && !dl_we) begin
            eq <= eq + 5'd1;
            case (eq[4:3])
                2'd0: cpu_e <= 1'b0;
                2'd1: cpu_q <= 1'b1;
                2'd2: cpu_e <= 1'b1;
                2'd3: cpu_q <= 1'b0;
            endcase
        end
    end
    // one system clock just before E falls: when a CPU write commits
    wire wr_stb = (eq == 5'd31);

    // mc6809i's NMI latch powers up asserted, and the only things that clear it
    // are servicing an NMI or a falling edge on nNMI while NMIMask is set.
    // Neither happens on a board that never uses NMI, so the CPU takes one
    // spurious NMI out of reset -- twelve pushes onto an uninitialised stack
    // and a vector fetch from FFFC, which is exactly what the bus trace showed.
    // Reset sets NMIMask, so a single high-then-low-then-high pulse during
    // reset marks the latch not-pending without touching the vendored core.
    // Held at zero while the ROM download runs, because E and Q are gated off
    // then: the pulse has to land in a window where the core is actually being
    // clocked, or it does nothing at all.
    logic [10:0] rst_cnt;
    always_ff @(posedge clk) begin
        if (!reset || dl_we)   rst_cnt <= 11'd0;
        else if (!rst_cnt[10]) rst_cnt <= rst_cnt + 11'd1;
    end
    wire cpu_nnmi = ~(reset && (rst_cnt >= 11'd512) && (rst_cnt < 11'd1024));

    // ------------------------------------------------------------- master CPU
    wire [15:0] m_addr;
    wire  [7:0] m_dout;
    logic [7:0] m_din;
    wire        m_rnw;
    logic       m_irq_n;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_master (
        .D(m_din), .DOut(m_dout), .ADDR(m_addr), .RnW(m_rnw),
        .E(cpu_e), .Q(cpu_q),
        .BS(), .BA(), .nIRQ(m_irq_n), .nFIRQ(1'b1), .nNMI(cpu_nnmi),
        .AVMA(), .BUSY(), .LIC(),
        .nHALT(1'b1), .nRESET(~reset), .nDMABREQ(1'b1), .RegData()
    );
    assign dbg_pc_main = m_addr;

    // -------------------------------------------------------------- slave CPU
    wire [15:0] s_addr;
    wire  [7:0] s_dout;
    logic [7:0] s_din;
    wire        s_rnw;
    logic       s_irq_n;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_slave (
        .D(s_din), .DOut(s_dout), .ADDR(s_addr), .RnW(s_rnw),
        .E(cpu_e), .Q(cpu_q),
        .BS(), .BA(), .nIRQ(s_irq_n), .nFIRQ(1'b1), .nNMI(cpu_nnmi),
        .AVMA(), .BUSY(), .LIC(),
        .nHALT(1'b1), .nRESET(~reset), .nDMABREQ(1'b1), .RegData()
    );
    assign dbg_pc_sub = s_addr;

    wire m_wr = ~m_rnw && wr_stb;
    wire s_wr = ~s_rnw && wr_stb;

    // -------------------------------------------------------- master decode
    wire msel_wdog  = (m_addr == 16'h2000);
    wire msel_28    = (m_addr[15:8] == 8'h28) && (m_addr[4:0] == 5'h00);
    wire msel_sys   = msel_28 && (m_addr[7:5] == 3'd0);   // 2800
    wire msel_p1    = msel_28 && (m_addr[7:5] == 3'd1);   // 2820
    wire msel_p2    = msel_28 && (m_addr[7:5] == 3'd2);   // 2840
    wire msel_dsw1  = msel_28 && (m_addr[7:5] == 3'd3);   // 2860
    wire msel_dsw2  = (m_addr == 16'h3000);
    wire msel_latch = (m_addr[15:3] == 13'h0600);         // 3000-3007
    wire msel_sirq  = (m_addr == 16'h3800);
    wire msel_slat  = (m_addr == 16'h3a00);
    wire msel_scx   = (m_addr == 16'h3c00);
    wire msel_scy   = (m_addr == 16'h3e00);
    wire msel_bgv   = (m_addr[15:10] == 6'b010000);       // 4000-43FF
    wire msel_fgv   = (m_addr[15:10] == 6'b010001);       // 4400-47FF
    wire msel_bgc   = (m_addr[15:10] == 6'b010010);       // 4800-4BFF
    wire msel_fgc   = (m_addr[15:10] == 6'b010011);       // 4C00-4FFF
    wire msel_share = (m_addr[15:11] == 5'b01010);        // 5000-57FF
    wire msel_rom   = m_addr[15];                         // 8000-FFFF

    // --------------------------------------------------------- slave decode
    wire ssel_beam  = (s_addr == 16'h2000);
    wire ssel_imask = (s_addr == 16'h4000);
    wire ssel_ram   = (s_addr[15:11] == 5'b01100) && (s_addr[10:0] < 11'h7a0);  // 6000-679F
    wire ssel_spr   = (s_addr[15:11] == 5'b01100) && (s_addr[10:0] >= 11'h7a0); // 67A0-67FF
    wire ssel_share = (s_addr[15:11] == 5'b10000);        // 8000-87FF
    wire ssel_rom   = (s_addr[15:13] == 3'b111);          // E000-FFFF

    // --------------------------------------------------------------- memories
    wire [7:0] mrom_q, srom_q, sram_q, share_mq, share_sq;

    wire dl_mrom = dl_we && (dl_addr < 18'h08000);
    tp_spram_dp #(.AW(15), .DW(8)) u_mrom (
        .clk(clk), .wa(dl_addr[14:0]), .we(dl_mrom), .d(dl_data),
        .ra(m_addr[14:0]), .q(mrom_q));

    wire        dl_srom = dl_we && (dl_addr >= 18'h08000) && (dl_addr < 18'h0A000);
    wire [17:0] o_srom  = dl_addr - 18'h08000;
    tp_spram_dp #(.AW(13), .DW(8)) u_srom (
        .clk(clk), .wa(o_srom[12:0]), .we(dl_srom), .d(dl_data),
        .ra(s_addr[12:0]), .q(srom_q));

    // slave scratch RAM 6000-679F (sprite RAM above it lives in the video core)
    tp_spram_dp #(.AW(11), .DW(8)) u_sram (
        .clk(clk), .wa(s_addr[10:0]), .we(ssel_ram && s_wr), .d(s_dout),
        .ra(s_addr[10:0]), .q(sram_q));

    // shared RAM: master at 5000-57FF, slave at 8000-87FF
    tp_dpram #(.AW(11), .DW(8)) u_share (
        .clk(clk),
        .a_addr(m_addr[10:0]), .a_we(msel_share && m_wr), .a_d(m_dout), .a_q(share_mq),
        .b_addr(s_addr[10:0]), .b_we(ssel_share && s_wr), .b_d(s_dout), .b_q(share_sq));

    // ------------------------------------------------------------- LS259 (3B)
    //  0 master IRQ enable   1 coin counter 2   2 coin counter 1   3 MUT
    //  4 flip screen X       5 flip screen Y    6 unused           7 GMED
    logic [7:0] latch;
    always_ff @(posedge clk) begin
        if (reset)                    latch <= 8'h00;
        else if (msel_latch && m_wr)  latch[m_addr[2:0]] <= m_dout[0];
    end

    // -------------------------------------------------- write-only registers
    logic [7:0] palette_bank, scroll_x, scroll_y;
    always_ff @(posedge clk) begin
        if (reset) begin
            palette_bank <= 8'h00; scroll_x <= 8'h00; scroll_y <= 8'h00;
        end else if (m_wr) begin
            if (msel_sys) palette_bank <= m_dout;   // 2800 is read SYSTEM, write COL0
            if (msel_scx) scroll_x     <= m_dout;
            if (msel_scy) scroll_y     <= m_dout;
        end
    end

    assign dbg_palette_bank = palette_bank;
    assign dbg_scroll_x     = scroll_x;
    assign dbg_scroll_y     = scroll_y;
    assign dbg_flip         = {latch[5], latch[4]};

    always_ff @(posedge clk) begin
        snd_irq <= msel_sirq && m_wr;
        if (msel_slat && m_wr) snd_data <= m_dout;
    end

    // ------------------------------------------------------------------ video
    wire [7:0] bg_vq, fg_vq, bg_cq, fg_cq, spr_q, vpos;
    wire       vbl_rise;

    tp84_video u_video (
        .clk(clk), .reset(reset),
        .flip_x(latch[4]), .flip_y(latch[5]),
        .palette_bank(palette_bank), .scroll_x(scroll_x), .scroll_y(scroll_y),
        .cpu_vaddr(m_addr[9:0]), .cpu_vdin(m_dout),
        .bg_vram_we(msel_bgv && m_wr), .fg_vram_we(msel_fgv && m_wr),
        .bg_cram_we(msel_bgc && m_wr), .fg_cram_we(msel_fgc && m_wr),
        .bg_vram_q(bg_vq), .fg_vram_q(fg_vq), .bg_cram_q(bg_cq), .fg_cram_q(fg_cq),
        // sprite RAM starts at 67A0, so index 0 is s_addr[6:0] == 0x20. The
        // frozen-state bench loads it by index and so could never catch this.
        .cpu_saddr(s_addr[6:0] - 7'h20), .cpu_sdin(s_dout), .spr_we(ssel_spr && s_wr),
        .spr_q(spr_q),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .de(de), .ce_pix(ce_pix),
        .vpos(vpos), .vblank_rise(vbl_rise),
        .dbg_spr_overrun(dbg_spr_overrun)
    );
    assign vblank_rise_o = vbl_rise;

    // -------------------------------------------------------------- read mux
    // Unmapped reads are 0: none of tp84's maps ask for unmap_value_high.
    //
    // Registered, not combinational. mc6809i is combinational from D through to
    // ADDR, so a combinational read mux closes a loop D -> ADDR -> select -> D.
    // The CPU holds an address for 32 system clocks and samples on the falling
    // edge of E, so a clock of latency here is invisible -- and both the
    // simulator and the fitter then see ordinary logic rather than a loop.
    always_ff @(posedge clk) begin
        m_din <= 8'h00;
        if      (msel_rom)   m_din <= mrom_q;
        else if (msel_bgv)   m_din <= bg_vq;
        else if (msel_fgv)   m_din <= fg_vq;
        else if (msel_bgc)   m_din <= bg_cq;
        else if (msel_fgc)   m_din <= fg_cq;
        else if (msel_share) m_din <= share_mq;
        else if (msel_sys)   m_din <= in_system;
        else if (msel_p1)    m_din <= in_p1;
        else if (msel_p2)    m_din <= in_p2;
        else if (msel_dsw1)  m_din <= dsw1;
        else if (msel_dsw2)  m_din <= dsw2;
    end

    always_ff @(posedge clk) begin
        s_din <= 8'h00;
        if      (ssel_rom)   s_din <= srom_q;
        else if (ssel_share) s_din <= share_sq;
        else if (ssel_spr)   s_din <= spr_q;
        else if (ssel_ram)   s_din <= sram_q;
        else if (ssel_beam)  s_din <= vpos;
    end

    // ------------------------------------------------------------ interrupts
    // Both CPUs take their IRQ from vblank, each gated by its own enable, and
    // each clears it by writing its enable back to 0 -- the 6809's IRQ is
    // level-sensitive, so nothing else deasserts it.
    logic sub_irq_mask;
    always_ff @(posedge clk) begin
        if (reset)                   sub_irq_mask <= 1'b0;
        else if (ssel_imask && s_wr) sub_irq_mask <= s_dout[0];
    end

    logic m_irq_req, s_irq_req;
    always_ff @(posedge clk) begin
        if (reset)            m_irq_req <= 1'b0;
        else if (!latch[0])   m_irq_req <= 1'b0;
        else if (vbl_rise)    m_irq_req <= 1'b1;

        if (reset)              s_irq_req <= 1'b0;
        else if (!sub_irq_mask) s_irq_req <= 1'b0;
        else if (vbl_rise)      s_irq_req <= 1'b1;
    end
    assign m_irq_n = ~m_irq_req;
    assign s_irq_n = ~s_irq_req;

    // -------------------------------------------------------------- watchdog
    // Kicked by any write to 2000. Resets nothing yet -- see docs; it is here
    // as a measurement first, exactly as it was on the Time Pilot core.
    logic [21:0] wdog;
    wire         wdog_kick = (msel_wdog && m_wr) || dl_we;
    always_ff @(posedge clk) begin
        if (reset) begin
            wdog <= 22'd0; dbg_watchdog <= 1'b0;
        end else if (wdog_kick) begin
            wdog <= 22'd0;
        end else if (wr_stb) begin
            if (&wdog) dbg_watchdog <= 1'b1;
            else       wdog <= wdog + 22'd1;
        end
    end

endmodule

`default_nettype wire
