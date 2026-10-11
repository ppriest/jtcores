/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Written by Paul Priest. */

// Xexex's mixer, as MAME's xexex.cpp screen_update draws:
//   1. the K054338 background colour
//   2. tile layers 1-3 and the K053250, sorted by their
//      K053251 priorities with konami_sortlayers4's compare-swaps
//   3. sprites, hidden by any opaque layer whose priority is below the sprite's
//      (sprite_callback's masks); sprite shadows darken by the K054338's deltas
//   4. layer 1's alpha-flagged tiles, blended over all that at the K054338's
//      level, when control2 bit 9 is clear
//   5. layer 0 on top, at colour base 0x70
// Colour bases from the K053251 (k053251.cpp reset_indexes). The palette is
// xRGB_888, two words a colour (xexex.cpp:708).
//
// Three pixels of latency: the blanking out is delayed to match.

module jtxexex_colmix(
    input             rst,
    input             clk,
    input             pxl_cen,

    input             lhbl,
    input             lvbl,
    output reg        lhbl_dly,
    output reg        lvbl_dly,

    // CPU
    input             pcu_cs,     // K053251, 0cc000
    input             reg_cs,     // K054338, 0ca000
    input             pal_cs,
    input             cpu_we,
    input      [15:0] cpu_dout,
    input      [ 1:0] cpu_dsn,
    input      [12:1] cpu_addr,
    output     [15:0] cpu_din,
    input             alpha_off,  // control2 bit 9

    // pixels
    input      [ 8:0] lyr0_pxl,   // { alpha flag, colour, pen }
    input      [ 8:0] lyr1_pxl,
    input      [ 8:0] lyr2_pxl,
    input      [ 8:0] lyr3_pxl,
    input      [ 8:0] lyro_pxl,   // { colour, pen }
    input      [ 8:0] lvc_pxl,    // { colour, pen }
    input      [ 4:0] lyro_pri,
    input      [ 1:0] shadow,

    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,

    // Debug
    input      [11:0] ioctl_addr,
    input             ioctl_ram,
    output     [ 7:0] ioctl_din,
    output     [ 7:0] dump_mmr,
    input      [ 7:0] debug_bus
);

// ---------------------------------------------------------------- registers
reg  [ 5:0] k251[0:15];
integer i;
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<16; i=i+1 ) k251[i] <= 0;
    end else if( pcu_cs && cpu_we && !cpu_dsn[0] ) k251[cpu_addr[4:1]] <= cpu_dout[5:0];
end

wire [ 6:0] cb_obj = { k251[9][1:0], 5'd0 };     // 32 * (ram[9] & 3)
wire [ 6:0] cb1    = { k251[9][5:4], 5'd0 };     // 32 * (ram[9] >> 4 & 3)
wire [ 6:0] cb2    = { k251[10][2:0], 4'd0 };    // 16 * (ram[10] & 7)
wire [ 6:0] cb3    = { k251[10][5:3], 4'd0 };    // 16 * (ram[10] >> 3 & 7)
wire [ 6:0] cb_lvc = { k251[9][3:2], 5'd0 };     // 32 * (ram[9] >> 2 & 3)

wire [23:0] bg_rgb;
wire [ 7:0] alpha_level;
wire signed [9:0] shd_r, shd_g, shd_b;
wire [15:0] k338_dout;
reg  [ 1:0] shd_l;

jt054338 u_k054338(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cs         ( reg_cs        ),
    .we         ( cpu_we        ),
    .addr       ( cpu_addr[4:1] ),
    .din        ( cpu_dout      ),
    .dsn        ( cpu_dsn       ),
    .dout       ( k338_dout     ),
    .pblend     ( 2'd1          ),
    .shadow     ( shd_l         ),
    .bg_rgb     ( bg_rgb        ),
    .alpha_level( alpha_level   ),
    .alpha_add  (               ),
    .video_en   (               ),
    .mixpri     (               ),
    .shdpri     (               ),
    .brtpri     (               ),
    .clipsl     (               ),
    .dump_mmr   (               ),
    .shadow_r   ( shd_r         ),
    .shadow_g   ( shd_g         ),
    .shadow_b   ( shd_b         )
);

// ---------------------------------------------------------------- layer order
// konami_sortlayers4 on { layer 1, 2, 3, K053250 } with priorities { CI2, CI3, CI4,
// CI1 }: compare-swap (0,1) (0,2) (0,3) (1,2) (1,3) (2,3), swapping on <=. Entry 0
// is drawn first. Ids: 1-3 tile layers, 0 the K053250.
reg  [ 1:0] ord[0:3];
reg  [ 5:0] lp[0:3];
always @* begin : sort
    reg [1:0] tid; reg [5:0] tp;
    ord[0] = 2'd1; lp[0] = k251[2];
    ord[1] = 2'd2; lp[1] = k251[3];
    ord[2] = 2'd3; lp[2] = k251[4];
    ord[3] = 2'd0; lp[3] = k251[1];
    `define CSWAP(a,b) if( lp[a] <= lp[b] ) begin tp=lp[a]; lp[a]=lp[b]; lp[b]=tp; tid=ord[a]; ord[a]=ord[b]; ord[b]=tid; end
    `CSWAP(0,1) `CSWAP(0,2) `CSWAP(0,3) `CSWAP(1,2) `CSWAP(1,3) `CSWAP(2,3)
    `undef CSWAP
end

// ---------------------------------------------------------------- per pixel
reg  [ 8:0] l0, l1, l2, l3, ob, lv;
reg  [ 4:0] opri;
wire        cur_alpha = ~alpha_off;

always @(posedge clk) if( pxl_cen ) begin
    l0 <= lyr0_pxl; l1 <= lyr1_pxl; l2 <= lyr2_pxl; l3 <= lyr3_pxl; lv <= lvc_pxl;
    ob <= lyro_pxl; opri <= lyro_pri; shd_l <= shadow;
end

// per layer id: opaque in the sorted pass, palette index. Plain wires: Quartus 20.1
// synthesizes a function that reads module signals without them (warning 10036).
wire [ 3:0] opq_id = {
    l3[3:0]!=0,                                 // 3
    l2[3:0]!=0,                                 // 2
    l1[3:0]!=0 && !(cur_alpha && l1[8]),        // 1: alpha tiles are blended later
    lv[3:0]!=0 };                               // 0: the K053250
wire [10:0] pidx0 = { cb_lvc[6:5], lv[8:4], lv[3:0] },
            pidx1 = { cb1[6:4], l1[7:4], l1[3:0] },
            pidx2 = { cb2[6:4], l2[7:4], l2[3:0] },
            pidx3 = { cb3[6:4], l3[7:4], l3[3:0] };

reg  [10:0] base_idx;
reg         base_pal, spr_on, shd_on;
always @* begin : mix
    reg [5:0] spri;
    reg       blocked;
    integer p;
    base_pal = 0;
    base_idx = 0;
    blocked  = 0;
    spri     = { opri, 1'b0 };       // (color & 0x3e0) >> 4
    for( p=0; p<4; p=p+1 ) begin
        if( opq_id[ord[p]] ) begin
            base_pal = 1;
            case( ord[p] )
                2'd0: base_idx = pidx0;
                2'd1: base_idx = pidx1;
                2'd2: base_idx = pidx2;
                default: base_idx = pidx3;
            endcase
            // the K053250 sets the priority bitmap where it draws, the tile layers OR
            // into it (k053250.cpp pdraw_scanline32, tilemap_draw)
            if( ord[p]==2'd0 ) blocked = spri > lp[p];
            else if( spri > lp[p] ) blocked = 1;
        end
    end
    spr_on = ob[3:0]!=0 && !blocked;
    shd_on = ob[3:0]==0 && shd_l!=0 && !blocked;
    if( spr_on ) begin
        base_pal = 1;
        base_idx = { cb_obj[6:5], ob[8:4], ob[3:0] };
    end
end

// palette: the pixel's colours are read in the clocks between pixel enables, then
// blended during the next pixel: three pixels from the inputs to the output
wire [ 7:0] pal_r, pal_g, pal_b;
reg  [10:0] scan_idx, alpha_idx, fix_idx;
reg  [ 2:0] ph;
reg  [23:0] base_rgb, alpha_rgb, fix_rgb, out_rgb;
reg         use_pal, use_fix, use_shd, use_alpha, lhbl_d1, lvbl_d1, lhbl_d2, lvbl_d2;
// blend stage: (s*a + d*(256-a)) >> 8, alpha_blend_r32, as 256d + a(s-d) with the
// product built two bits of a a clock
reg  [23:0] bd_rgb, bf_rgb;
reg         b_fix;
reg  [ 7:0] b_a;
reg signed [ 9:0] df_r, df_g, df_b;
reg signed [17:0] acc_r, acc_g, acc_b;

function [7:0] add_clip( input [7:0] c, input signed [9:0] d );
    reg signed [10:0] s;
    begin
        s = $signed({3'd0,c}) + d;
        add_clip = s < 0 ? 8'd0 : s > 11'sd255 ? 8'hff : s[7:0];
    end
endfunction

// d times two bits of a, shifted into place
function signed [17:0] step( input signed [9:0] d, input [1:0] a2, input [2:0] sh );
    reg signed [17:0] dx, m;
    begin
        dx = { {8{d[9]}}, d };
        m  = (a2[0] ? dx : 18'sd0) + (a2[1] ? dx <<< 1 : 18'sd0);
        step = m <<< sh;
    end
endfunction

wire [23:0] pal_rgb = { pal_r, pal_g, pal_b };
wire [23:0] shd_rgb = { add_clip(base_rgb[23:16], shd_r), add_clip(base_rgb[15:8], shd_g),
                        add_clip(base_rgb[7:0], shd_b) };
wire [ 7:0] res_r = acc_r[15:8], res_g = acc_g[15:8], res_b = acc_b[15:8];

always @(posedge clk) begin
    if( rst ) begin
        ph <= 0; out_rgb <= 0; lhbl_dly <= 0; lvbl_dly <= 0;
    end else begin
        ph <= pxl_cen ? 3'd1 : (ph==0 ? 3'd0 : ph + 3'd1);
        // stage A: read the base, alpha and fix colours
        case( ph )
            3'd1: begin     // inputs latched at pxl_cen
                scan_idx  <= base_idx;
                alpha_idx <= { cb1[6:4], l1[7:4], l1[3:0] };
                fix_idx   <= { 3'b111, l0[7:4], l0[3:0] };      // colour base 0x70
                use_pal   <= base_pal;
                use_shd   <= shd_on;
                use_fix   <= l0[3:0]!=0;
                use_alpha <= cur_alpha && l1[3:0]!=0 && l1[8];
            end
            3'd2: scan_idx <= alpha_idx;
            3'd3: begin
                base_rgb <= use_pal ? pal_rgb : bg_rgb;
                scan_idx <= fix_idx;
            end
            3'd4: begin
                alpha_rgb <= pal_rgb;
                if( use_shd ) base_rgb <= shd_rgb;  // shadow deltas: shd_l still this pixel's
            end
            3'd5: fix_rgb <= pal_rgb;
            default:;
        endcase
        // stage B: the blend, over the next pixel's clocks
        if( pxl_cen ) begin
            bd_rgb <= base_rgb;
            bf_rgb <= fix_rgb;
            b_fix  <= use_fix;
            b_a    <= use_alpha ? alpha_level : 8'd0;
            df_r   <= $signed({2'd0,alpha_rgb[23:16]}) - $signed({2'd0,base_rgb[23:16]});
            df_g   <= $signed({2'd0,alpha_rgb[15: 8]}) - $signed({2'd0,base_rgb[15: 8]});
            df_b   <= $signed({2'd0,alpha_rgb[ 7: 0]}) - $signed({2'd0,base_rgb[ 7: 0]});
            acc_r  <= { 2'd0, base_rgb[23:16], 8'd0 };
            acc_g  <= { 2'd0, base_rgb[15: 8], 8'd0 };
            acc_b  <= { 2'd0, base_rgb[ 7: 0], 8'd0 };
        end else if( ph>=3'd1 && ph<=3'd4 ) begin
            acc_r <= acc_r + step( df_r, b_a[ (ph-3'd1)*2 +: 2 ], (ph-3'd1)<<1 );
            acc_g <= acc_g + step( df_g, b_a[ (ph-3'd1)*2 +: 2 ], (ph-3'd1)<<1 );
            acc_b <= acc_b + step( df_b, b_a[ (ph-3'd1)*2 +: 2 ], (ph-3'd1)<<1 );
        end
        if( pxl_cen ) begin
            { lhbl_dly, lhbl_d2, lhbl_d1 } <= { lhbl_d2, lhbl_d1, lhbl };
            { lvbl_dly, lvbl_d2, lvbl_d1 } <= { lvbl_d2, lvbl_d1, lvbl };
            out_rgb <= b_fix ? bf_rgb : { res_r, res_g, res_b };
        end
    end
end

assign { red, green, blue } = lhbl_dly && lvbl_dly ? out_rgb : 24'd0;

// 2048 colours of two words, xRGB_888 as MAME's palette (doc/xexex.cpp:708): word 0 holds
// red in its low byte, word 1 green and blue. Four byte RAMs keep one colour per address,
// so the scan side reads a whole colour at once.
wire [ 7:0] pal_x, cpu_x, cpu_r, cpu_g, cpu_b;
wire [ 1:0] cpu_palwe = {2{cpu_we & pal_cs}} & ~cpu_dsn;
wire [ 3:0] palwe     = { cpu_palwe & {2{ cpu_addr[1]}}, cpu_palwe & {2{~cpu_addr[1]}} };
wire [15:0] pal_cpu_din = cpu_addr[1] ? { cpu_g, cpu_b } : { cpu_x, cpu_r };

assign cpu_din   = reg_cs ? k338_dout : pal_cpu_din;
assign ioctl_din = ioctl_addr[1:0]==0 ? pal_x : ioctl_addr[1:0]==1 ? pal_r :
                   ioctl_addr[1:0]==2 ? pal_g : pal_b;
assign dump_mmr  = { 2'd0, k251[ioctl_addr[3:0]] };

jtframe_dual_nvram #(.AW(11),.SIMFILE("pal_r.bin")) u_ram_r(
    .clk0   ( clk           ), .data0  ( cpu_dout[7:0]  ),
    .addr0  ( cpu_addr[12:2]), .we0    ( palwe[0]       ), .q0 ( cpu_r ),
    .clk1   ( clk           ), .data1  ( 8'd0           ),
    .addr1a ( scan_idx      ), .addr1b ( {1'b0,ioctl_addr[11:2]}), .sel_b ( ioctl_ram ),
    .we_b   ( 1'b0          ), .q1     ( pal_r          )
);

jtframe_dual_nvram #(.AW(11),.SIMFILE("pal_x.bin")) u_ram_x(
    .clk0   ( clk           ), .data0  ( cpu_dout[15:8] ),
    .addr0  ( cpu_addr[12:2]), .we0    ( palwe[1]       ), .q0 ( cpu_x ),
    .clk1   ( clk           ), .data1  ( 8'd0           ),
    .addr1a ( scan_idx      ), .addr1b ( {1'b0,ioctl_addr[11:2]}), .sel_b ( ioctl_ram ),
    .we_b   ( 1'b0          ), .q1     ( pal_x          )
);

jtframe_dual_nvram #(.AW(11),.SIMFILE("pal_b.bin")) u_ram_b(
    .clk0   ( clk           ), .data0  ( cpu_dout[7:0]  ),
    .addr0  ( cpu_addr[12:2]), .we0    ( palwe[2]       ), .q0 ( cpu_b ),
    .clk1   ( clk           ), .data1  ( 8'd0           ),
    .addr1a ( scan_idx      ), .addr1b ( {1'b0,ioctl_addr[11:2]}), .sel_b ( ioctl_ram ),
    .we_b   ( 1'b0          ), .q1     ( pal_b          )
);

jtframe_dual_nvram #(.AW(11),.SIMFILE("pal_g.bin")) u_ram_g(
    .clk0   ( clk           ), .data0  ( cpu_dout[15:8] ),
    .addr0  ( cpu_addr[12:2]), .we0    ( palwe[3]       ), .q0 ( cpu_g ),
    .clk1   ( clk           ), .data1  ( 8'd0           ),
    .addr1a ( scan_idx      ), .addr1b ( {1'b0,ioctl_addr[11:2]}), .sel_b ( ioctl_ram ),
    .we_b   ( 1'b0          ), .q1     ( pal_g          )
);

endmodule
