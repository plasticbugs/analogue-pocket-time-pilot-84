//------------------------------------------------------------------------------
// Time Pilot '84 video hardware.
//
// The semantics implemented here are the ones pinned down by tools/tp84video.py,
// which is pixel-identical to MAME across the captured states -- read that
// alongside this file. In brief:
//
//   * Two 32x32 tilemaps of 8x8 2bpp tiles from one tile ROM. The background
//     scrolls in both axes and wraps at 256; the foreground does not scroll and
//     is drawn only in two 16-pixel strips at the raster's left and right edges,
//     which become the status bars once the screen is rotated.
//   * 24 sprites, 16x16 4bpp, scanned 0x5C down to 0 so later entries win.
//   * Priority: foreground strip, else sprite, else background.
//   * Colour is two indirections deep and both are fed by the palette bank
//     register, so writing that register recolours the whole screen without
//     touching a byte of tile or sprite RAM:
//         char   idx = {pb[4:3], attr[3:0], pix[1:0]} -> clut
//                col = 0x80 | {pb[2:0], clut[3:0]}
//         sprite idx = {attr[3:0], pix[3:0]}          -> slut
//                col =        {pb[2:0], slut[3:0]},  transparent when slut[3:0]==0
//     then col indexes three 4-bit PROMs feeding a resistor DAC.
//
// Timing (docs/hardware.md 4): 6.144 MHz dot clock, 384 dots per line, 264
// lines, 60.606 Hz -- the same Konami chain as Time Pilot.
//
// Clocked at 8x the dot clock. Because the background scroll is arbitrary, an
// 8-pixel group on screen straddles two map tiles, so each group fetches two
// background tiles plus one foreground tile and picks per pixel. That is nine
// block RAM reads against a 64-clock budget.
//------------------------------------------------------------------------------
`default_nettype none

module tp84_video (
    input  wire        clk,            //! 8x the dot clock
    input  wire        reset,

    // ---- control ---------------------------------------------------------
    input  wire        flip_x,
    input  wire        flip_y,
    input  wire  [7:0] palette_bank,
    input  wire  [7:0] scroll_x,
    input  wire  [7:0] scroll_y,

    // ---- master CPU access to the tilemap memories ------------------------
    input  wire  [9:0] cpu_vaddr,
    input  wire  [7:0] cpu_vdin,
    input  wire        bg_vram_we,
    input  wire        fg_vram_we,
    input  wire        bg_cram_we,
    input  wire        fg_cram_we,
    output wire  [7:0] bg_vram_q,
    output wire  [7:0] fg_vram_q,
    output wire  [7:0] bg_cram_q,
    output wire  [7:0] fg_cram_q,

    // ---- slave CPU access to sprite RAM -----------------------------------
    input  wire  [6:0] cpu_saddr,
    input  wire  [7:0] cpu_sdin,
    input  wire        spr_we,
    output wire  [7:0] spr_q,

    // ---- ROM image download (offsets within the .rom) --------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- video out -------------------------------------------------------
    output logic [7:0] red,
    output logic [7:0] green,
    output logic [7:0] blue,
    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       de,
    output wire        ce_pix,

    // ---- to the CPUs -----------------------------------------------------
    output wire  [7:0] vpos,           //! the slave's beam-position register
    output logic       vblank_rise,

    // ---- diagnostics -----------------------------------------------------
    output logic       dbg_spr_overrun
);

    // ------------------------------------------------------------- .rom map
    localparam [17:0] OFS_TILES  = 18'h0C000;
    localparam [17:0] OFS_SPR    = 18'h10000;
    localparam [17:0] OFS_PROM_R = 18'h18000;
    localparam [17:0] OFS_PROM_G = 18'h18100;
    localparam [17:0] OFS_PROM_B = 18'h18200;
    localparam [17:0] OFS_CLUT   = 18'h18300;
    localparam [17:0] OFS_SLUT   = 18'h18400;
    localparam [17:0] OFS_END    = 18'h18500;

    wire [17:0] o_tiles = dl_addr - OFS_TILES;
    wire [17:0] o_spr   = dl_addr - OFS_SPR;
    wire [17:0] o_r     = dl_addr - OFS_PROM_R;
    wire [17:0] o_g     = dl_addr - OFS_PROM_G;
    wire [17:0] o_b     = dl_addr - OFS_PROM_B;
    wire [17:0] o_cl    = dl_addr - OFS_CLUT;
    wire [17:0] o_sl    = dl_addr - OFS_SLUT;

    wire dl_tiles = dl_we && (dl_addr >= OFS_TILES)  && (dl_addr < OFS_SPR);
    wire dl_sprlo = dl_we && (dl_addr >= OFS_SPR)    && (dl_addr < OFS_SPR + 18'h4000);
    wire dl_sprhi = dl_we && (dl_addr >= OFS_SPR + 18'h4000) && (dl_addr < OFS_PROM_R);
    wire dl_pr    = dl_we && (dl_addr >= OFS_PROM_R) && (dl_addr < OFS_PROM_G);
    wire dl_pg    = dl_we && (dl_addr >= OFS_PROM_G) && (dl_addr < OFS_PROM_B);
    wire dl_pb    = dl_we && (dl_addr >= OFS_PROM_B) && (dl_addr < OFS_CLUT);
    wire dl_clut  = dl_we && (dl_addr >= OFS_CLUT)   && (dl_addr < OFS_SLUT);
    wire dl_slut  = dl_we && (dl_addr >= OFS_SLUT)   && (dl_addr < OFS_END);

    // -------------------------------------------------------- video timing
    localparam int HTOTAL = 384;
    localparam int HDISP  = 256;
    localparam int HLEAD  = 8;
    localparam int HS_BEG = 272, HS_END = 304;
    localparam int VFIRST = 248, VLAST = 511;
    localparam int VVIS0  = 272, VVIS1 = 495;
    localparam int VS_BEG = 500, VS_END = 502;

    logic [2:0] phase;
    logic [8:0] hcnt;
    logic [8:0] vcnt;

    assign ce_pix = (phase == 3'd7);
    wire       h_last    = (hcnt == HTOTAL[8:0] - 9'd1);
    wire [8:0] vcnt_next = (vcnt == VLAST[8:0]) ? VFIRST[8:0] : (vcnt + 9'd1);

    always_ff @(posedge clk) begin
        if (reset) begin
            phase <= 3'd0; hcnt <= 9'd0; vcnt <= VFIRST[8:0];
        end else begin
            phase <= phase + 3'd1;
            if (ce_pix) begin
                hcnt <= h_last ? 9'd0 : (hcnt + 9'd1);
                if (h_last) vcnt <= vcnt_next;
            end
        end
    end

    assign vpos = vcnt[7:0];

    wire [8:0] src_x  = hcnt - HLEAD[8:0];
    wire       h_vis  = (hcnt >= HLEAD[8:0]) && (hcnt < HLEAD[8:0] + HDISP[8:0]);
    wire       v_vis  = (vcnt >= VVIS0[8:0]) && (vcnt <= VVIS1[8:0]);
    wire       de_src = h_vis && v_vis;
    wire       hs_src = (hcnt >= HS_BEG[8:0]) && (hcnt < HS_END[8:0]);
    wire       vs_src = (vcnt >= VS_BEG[8:0]) && (vcnt <= VS_END[8:0]);

    always_ff @(posedge clk)
        vblank_rise <= ce_pix && h_last && (vcnt_next == VVIS1[8:0] + 9'd1);

    // The scroll registers are latched once per frame at the top of the visible
    // area, which is what MAME's tilemap does. Games write scroll in vblank, so
    // a continuously-applied scroll would look the same; this way the frozen
    // bench and MAME cannot disagree about it.
    logic [7:0] sc_x, sc_y;
    always_ff @(posedge clk)
        if (ce_pix && h_last && (vcnt_next == VVIS0[8:0])) begin
            sc_x <= scroll_x;
            sc_y <= scroll_y;
        end

    // ---------------------------------------------------- tilemap memories
    wire  [9:0] bg_idx, fg_idx;
    wire  [7:0] bg_vq, bg_cq, fg_vq, fg_cq;

    tp_dpram #(.AW(10), .DW(8)) u_bgv (
        .clk(clk), .a_addr(cpu_vaddr), .a_we(bg_vram_we), .a_d(cpu_vdin), .a_q(bg_vram_q),
        .b_addr(bg_idx), .b_we(1'b0), .b_d(8'd0), .b_q(bg_vq));
    tp_dpram #(.AW(10), .DW(8)) u_bgc (
        .clk(clk), .a_addr(cpu_vaddr), .a_we(bg_cram_we), .a_d(cpu_vdin), .a_q(bg_cram_q),
        .b_addr(bg_idx), .b_we(1'b0), .b_d(8'd0), .b_q(bg_cq));
    tp_dpram #(.AW(10), .DW(8)) u_fgv (
        .clk(clk), .a_addr(cpu_vaddr), .a_we(fg_vram_we), .a_d(cpu_vdin), .a_q(fg_vram_q),
        .b_addr(fg_idx), .b_we(1'b0), .b_d(8'd0), .b_q(fg_vq));
    tp_dpram #(.AW(10), .DW(8)) u_fgc (
        .clk(clk), .a_addr(cpu_vaddr), .a_we(fg_cram_we), .a_d(cpu_vdin), .a_q(fg_cram_q),
        .b_addr(fg_idx), .b_we(1'b0), .b_d(8'd0), .b_q(fg_cq));

    logic [13:0] tile_ra;
    wire   [7:0] tile_q;
    tp_spram_dp #(.AW(14), .DW(8)) u_tilerom (
        .clk(clk), .wa(o_tiles[13:0]), .we(dl_tiles), .d(dl_data), .ra(tile_ra), .q(tile_q));

    // ------------------------------------------------------- tilemap fetch
    // Each 8-dot group fetches two background tiles (the group straddles a tile
    // boundary whenever the scroll is not a multiple of 8) and one foreground
    // tile, in nine steps of the 64-clock group.
    wire [5:0] step = {hcnt[2:0], phase};

    // map position of the first pixel of the group being fetched
    wire [7:0] mx0   = hcnt[7:0] + sc_x;
    wire [7:0] my    = vcnt[7:0] + sc_y;
    wire [4:0] mtx_a = mx0[7:3];
    wire [4:0] mtx_b = mx0[7:3] + 5'd1;
    wire [4:0] mty   = my[7:3];

    // screen flip mirrors both maps, as MAME's set_flip_all does
    wire [4:0] f_mtx_a = flip_x ? ~mtx_a : mtx_a;
    wire [4:0] f_mtx_b = flip_x ? ~mtx_b : mtx_b;
    wire [4:0] f_mty   = flip_y ? ~mty   : mty;
    wire [4:0] f_ftx   = flip_x ? ~hcnt[7:3] : hcnt[7:3];
    wire [4:0] f_fty   = flip_y ? ~vcnt[7:3] : vcnt[7:3];

    assign bg_idx = (step >= 6'd3) ? {f_mty, f_mtx_b} : {f_mty, f_mtx_a};
    assign fg_idx = {f_fty, f_ftx};

    // pending fetch results
    logic [7:0] p_attr_a, p_attr_b, p_attr_f;
    logic [7:0] p_la, p_ra_, p_lb, p_rb, p_lf, p_rf;
    logic [2:0] p_row_a, p_row_b, p_row_f;
    logic [2:0] p_fine;

    // combinational view of the attribute currently on the bus
    wire [7:0] c_attr = (step >= 6'd6) ? fg_cq : bg_cq;
    wire [7:0] c_code = (step >= 6'd6) ? fg_vq : bg_vq;
    wire [9:0] f_code = {c_attr[5:4], c_code};
    wire [2:0] c_line = (step >= 6'd6) ? (flip_y ? ~vcnt[2:0] : vcnt[2:0])
                                       : (flip_y ? ~my[2:0]   : my[2:0]);
    wire [2:0] c_rowe = c_attr[7] ? ~c_line : c_line;

    always_comb begin
        tile_ra = {f_code, 1'b0, c_rowe};
        case (step)
            6'd2, 6'd5, 6'd8: tile_ra = {f_code, 1'b1, c_rowe};
            default:          tile_ra = {f_code, 1'b0, c_rowe};
        endcase
    end

    always_ff @(posedge clk) begin
        case (step)
            6'd1: begin p_attr_a <= bg_cq; p_row_a <= c_rowe; end
            6'd2: p_la  <= tile_q;
            6'd3: p_ra_ <= tile_q;
            6'd4: begin p_attr_b <= bg_cq; p_row_b <= c_rowe; end
            6'd5: p_lb  <= tile_q;
            6'd6: begin p_rb <= tile_q; p_fine <= mx0[2:0]; end
            6'd7: begin p_attr_f <= fg_cq; p_row_f <= c_rowe; end
            6'd8: p_lf  <= tile_q;
            6'd9: p_rf  <= tile_q;
            default: ;
        endcase
    end

    logic [7:0] a_attr_a, a_attr_b, a_attr_f, a_la, a_ra_, a_lb, a_rb, a_lf, a_rf;
    logic [2:0] a_fine;
    wire group_start = ce_pix && (hcnt[2:0] == 3'd7);

    always_ff @(posedge clk) if (group_start) begin
        a_attr_a <= p_attr_a; a_attr_b <= p_attr_b; a_attr_f <= p_attr_f;
        a_la <= p_la; a_ra_ <= p_ra_; a_lb <= p_lb; a_rb <= p_rb;
        a_lf <= p_lf; a_rf <= p_rf; a_fine <= p_fine;
    end

    // ---- pixel selection within the displayed group
    function automatic [1:0] tpix(input [7:0] lo, input [7:0] hi, input [2:0] idx);
        logic [7:0] b;
        logic [1:0] k;
        begin
            b = idx[2] ? hi : lo;
            k = idx[1:0];
            tpix = {b[3 - k], b[7 - k]};
        end
    endfunction

    wire [2:0] k     = src_x[2:0];
    wire [3:0] mpos  = {1'b0, a_fine} + {1'b0, k};   // 0..14, >=8 means the second tile
    wire       use_b = mpos[3];
    wire [7:0] bg_attr = use_b ? a_attr_b : a_attr_a;
    wire [2:0] bg_i0   = mpos[2:0];
    wire [2:0] bg_ii   = bg_attr[6] ? ~bg_i0 : bg_i0;      // tile's own flipx
    wire [1:0] bg_px   = use_b ? tpix(a_lb, a_rb, bg_ii) : tpix(a_la, a_ra_, bg_ii);

    wire [2:0] fg_i0 = flip_x ? ~k : k;
    wire [2:0] fg_ii = a_attr_f[6] ? ~fg_i0 : fg_i0;
    wire [1:0] fg_px = tpix(a_lf, a_rf, fg_ii);

    // the foreground is only drawn in the two 16-pixel edge strips
    wire in_fg = (src_x < 9'd16) || (src_x >= 9'd240);

    // ----------------------------------------------------- sprite memories
    logic [6:0] spr_ra;
    wire  [7:0] spr_vq;
    tp_dpram #(.AW(7), .DW(8)) u_spr (
        .clk(clk), .a_addr(cpu_saddr), .a_we(spr_we), .a_d(cpu_sdin), .a_q(spr_q),
        .b_addr(spr_ra), .b_we(1'b0), .b_d(8'd0), .b_q(spr_vq));

    // The four sprite planes live in the two halves of the region, so both
    // halves are separate memories read at the same index -- one address gives
    // all four bits of four pixels.
    logic [13:0] sgfx_ra;
    wire   [7:0] sgfx_lo, sgfx_hi;
    tp_spram_dp #(.AW(14), .DW(8)) u_sprlo (
        .clk(clk), .wa(o_spr[13:0]), .we(dl_sprlo), .d(dl_data), .ra(sgfx_ra), .q(sgfx_lo));
    tp_spram_dp #(.AW(14), .DW(8)) u_sprhi (
        .clk(clk), .wa(o_spr[13:0]), .we(dl_sprhi), .d(dl_data), .ra(sgfx_ra), .q(sgfx_hi));

    // ------------------------------------------------------ colour lookups
    logic [7:0] clut_ra, slut_ra, prom_ra;
    wire  [7:0] clut_q, slut_q, prom_rq, prom_gq, prom_bq;
    tp_spram_dp #(.AW(8), .DW(8)) u_clut (
        .clk(clk), .wa(o_cl[7:0]), .we(dl_clut), .d(dl_data), .ra(clut_ra), .q(clut_q));
    tp_spram_dp #(.AW(8), .DW(8)) u_slut (
        .clk(clk), .wa(o_sl[7:0]), .we(dl_slut), .d(dl_data), .ra(slut_ra), .q(slut_q));
    tp_spram_dp #(.AW(8), .DW(8)) u_pr (
        .clk(clk), .wa(o_r[7:0]), .we(dl_pr), .d(dl_data), .ra(prom_ra), .q(prom_rq));
    tp_spram_dp #(.AW(8), .DW(8)) u_pg (
        .clk(clk), .wa(o_g[7:0]), .we(dl_pg), .d(dl_data), .ra(prom_ra), .q(prom_gq));
    tp_spram_dp #(.AW(8), .DW(8)) u_pb_ (
        .clk(clk), .wa(o_b[7:0]), .we(dl_pb), .d(dl_data), .ra(prom_ra), .q(prom_bq));

    // -------------------------------------------------- sprite line buffer
    // Four bits per pixel: the sprite lookup PROM's low nibble, already
    // resolved. That nibble is zero exactly when the pixel is transparent, so
    // it doubles as the empty marker and no valid bit is needed.
    wire       lb_disp = vcnt[0];
    wire [7:0] rd_addr = src_x[7:0];

    logic [7:0] clr_addr;
    logic       clr_en;
    always_ff @(posedge clk) if (ce_pix) begin
        clr_addr <= rd_addr;
        clr_en   <= h_vis;
    end

    logic [7:0] lb_wa;
    logic [3:0] lb_d;
    logic       lb_we;

    wire [3:0] lb0_q, lb1_q;
    tp_spram_dp #(.AW(8), .DW(4)) u_lb0 (
        .clk(clk),
        .wa(lb_disp ? lb_wa : clr_addr),
        .we(lb_disp ? lb_we : (clr_en && ce_pix)),
        .d (lb_disp ? lb_d  : 4'd0),
        .ra(rd_addr), .q(lb0_q));
    tp_spram_dp #(.AW(8), .DW(4)) u_lb1 (
        .clk(clk),
        .wa(lb_disp ? clr_addr : lb_wa),
        .we(lb_disp ? (clr_en && ce_pix) : lb_we),
        .d (lb_disp ? 4'd0 : lb_d),
        .ra(rd_addr), .q(lb1_q));
    wire [3:0] spr_nib = lb_disp ? lb1_q : lb0_q;

    // ---------------------------------------------------------- sprite engine
    // Runs in the hblank at the end of each line, filling the buffer for the
    // line about to be displayed. Worst case 24 sprites x 29 clocks = 696 of
    // the 1024 available.
    localparam [3:0] S_IDLE = 4'd0, S_A0 = 4'd1, S_A1 = 4'd2, S_A2  = 4'd3,
                     S_A3   = 4'd4, S_CHK = 4'd5, S_ROW = 4'd6,
                     S_G0   = 4'd7, S_G1  = 4'd8, S_PX  = 4'd9;

    logic [3:0] st;
    logic [6:0] offs;
    logic [7:0] s_x, s_code, s_attr, s_ysrc, s_lo, s_hi;
    logic [3:0] s_row;
    logic [1:0] s_grp, s_k;

    wire [7:0] tgt_y  = vcnt_next[7:0];
    wire [7:0] eff_y  = flip_y ? ~tgt_y : tgt_y;
    wire [9:0] row_sum = {2'b0, eff_y} + {2'b0, s_ysrc};
    wire       row_hit = (row_sum >= 10'd240) && (row_sum <= 10'd255);
    wire [3:0] row_idx = row_sum[3:0];                    // row_sum - 240

    wire [3:0] s_srow = s_attr[7] ? ~s_row : s_row;       // sprite flipy
    wire [3:0] s_col  = {s_grp, s_k};
    wire [3:0] s_dcol = s_attr[6] ? s_col : ~s_col;       // flipx when bit 6 is 0
    wire [8:0] s_dx   = {1'b0, s_x} + {5'b0, s_dcol};
    wire [8:0] s_dxf  = flip_x ? (9'd255 - s_dx) : s_dx;
    wire [3:0] s_pix  = {s_hi[3 - s_k], s_hi[7 - s_k], s_lo[3 - s_k], s_lo[7 - s_k]};

    wire spr_start   = ce_pix && (hcnt == HLEAD[8:0] + HDISP[8:0] - 9'd1);
    wire last_sprite = (offs == 7'd0);

    always_comb begin
        case (st)
            S_A0:    spr_ra = offs;
            S_A1:    spr_ra = offs | 7'd1;
            S_A2:    spr_ra = offs | 7'd2;
            default: spr_ra = offs | 7'd3;
        endcase
        sgfx_ra = {s_code, s_srow[3], s_grp, s_srow[2:0]};
        slut_ra = {s_attr[3:0], s_pix};
    end

    // The lookup PROM read costs a cycle, so the line buffer write trails the
    // pixel it belongs to by one.
    logic [8:0] w_dx;
    logic       w_en;
    always_ff @(posedge clk) begin
        w_en <= (st == S_PX);
        w_dx <= s_dxf;
    end
    always_comb begin
        lb_we = w_en && !w_dx[8] && (slut_q[3:0] != 4'd0);
        lb_wa = w_dx[7:0];
        lb_d  = slut_q[3:0];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE;
        end else case (st)
            S_IDLE: if (spr_start) begin offs <= 7'h5c; st <= S_A0; end
            S_A0:   st <= S_A1;                              // address on the bus
            S_A1:   begin s_x    <= spr_vq; st <= S_A2; end
            S_A2:   begin s_code <= spr_vq; st <= S_A3; end
            S_A3:   begin s_attr <= spr_vq; st <= S_CHK; end
            S_CHK:  begin s_ysrc <= spr_vq; st <= S_ROW; end
            S_ROW:                                           // s_ysrc valid now
                if (row_hit) begin
                    s_row <= row_idx;
                    s_grp <= 2'd0;
                    st    <= S_G0;
                end else begin
                    offs <= offs - 7'd4;
                    st   <= last_sprite ? S_IDLE : S_A0;
                end
            // S_G0 presents the gfx address built from s_row and s_grp, which
            // were both written at the end of the previous state; the data is
            // latched a cycle later. Skipping this step was the bug that made
            // the first pixel group of every sprite use the previous group's
            // bytes.
            S_G0: st <= S_G1;
            S_G1: begin
                s_lo <= sgfx_lo;
                s_hi <= sgfx_hi;
                s_k  <= 2'd0;
                st   <= S_PX;
            end
            S_PX:
                if (s_k != 2'd3) begin
                    s_k <= s_k + 2'd1;
                end else if (s_grp != 2'd3) begin
                    s_grp <= s_grp + 2'd1;
                    st    <= S_G0;
                end else begin
                    offs <= offs - 7'd4;
                    st   <= last_sprite ? S_IDLE : S_A0;
                end
            default: st <= S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) dbg_spr_overrun <= 1'b0;
        else if (ce_pix && (hcnt == HLEAD[8:0]) && (st != S_IDLE)) dbg_spr_overrun <= 1'b1;
    end

    // ------------------------------------------------------ colour pipeline
    wire [7:0] char_attr = in_fg ? a_attr_f : bg_attr;
    wire [1:0] char_px   = in_fg ? fg_px    : bg_px;
    always_comb clut_ra = {palette_bank[4:3], char_attr[3:0], char_px};

    wire use_spr = !in_fg && (spr_nib != 4'd0);
    always_comb prom_ra = use_spr ? {1'b0, palette_bank[2:0], spr_nib}
                                  : {1'b1, palette_bank[2:0], clut_q[3:0]};

    // 4-bit resistor DAC: 1k/470/220/100 with a 470 ohm pulldown, autoscaled to
    // 0-255 by MAME's compute_resistor_weights. Precomputed rather than built
    // from adders, because the weights are not the obvious 8/4/2/1.
    function automatic [7:0] gun(input [3:0] v);
        case (v)
            4'd0:  gun = 8'd0;   4'd1:  gun = 8'd14;  4'd2:  gun = 8'd31;  4'd3:  gun = 8'd45;
            4'd4:  gun = 8'd66;  4'd5:  gun = 8'd80;  4'd6:  gun = 8'd96;  4'd7:  gun = 8'd111;
            4'd8:  gun = 8'd144; 4'd9:  gun = 8'd159; 4'd10: gun = 8'd175; 4'd11: gun = 8'd189;
            4'd12: gun = 8'd210; 4'd13: gun = 8'd224; 4'd14: gun = 8'd241; default: gun = 8'd255;
        endcase
    endfunction

    always_ff @(posedge clk) if (ce_pix) begin
        red    <= de_src ? gun(prom_rq[3:0]) : 8'h00;
        green  <= de_src ? gun(prom_gq[3:0]) : 8'h00;
        blue   <= de_src ? gun(prom_bq[3:0]) : 8'h00;
        de     <= de_src;
        hsync  <= hs_src;
        vsync  <= vs_src;
        hblank <= ~h_vis;
        vblank <= ~v_vis;
    end

endmodule

`default_nettype wire
