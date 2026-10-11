/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Written by Paul Priest. */

// The K054156/K054157 tile layers of Xexex, as MAME's k056832 draws them
// (k054156_k054157_k056832.cpp get_tile_info, update_page_layout,
// tilemap_draw_common) with xexex.cpp's layer offsets and tile callback.
// scripts/video_model.py is the same algorithm in Python.
//
// VRAM holds 8 of the 4x4 pages of 64x32 tiles: page rows 0-3 of columns 0-1,
// where Xexex lays out its layers; column bit 1 mirrors. Each tile is an 8-bit
// attribute (even word) and a 16-bit code (odd word).
//
// Each line is drawn a line ahead into a line buffer per layer, by two engines:
// layers 0-1 on ROM bus 0 and layers 2-3 on bus 1. Per layer and line: the line
// scroll, then 49 tiles, one ROM word each (a row of eight 4-bit pixels).
//
// Pixel out per layer: { alpha flag, colour[3:0], pen[3:0] }, the colour being
// the callback's (attr >> 2) & 0xf; the colour base is added by the mixer.

module jtxexex_tilemap(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             lhbl,
    input             lvbl,
    input      [ 8:0] vdump,      // counts lines, from the CCU's VS
    input             flip,       // the frame turned 180 degrees (OSD)

    // CPU
    input             reg_cs,     // 0c0000-0c003f
    input             vram_cs,    // 180000-183fff
    input             cpu_we,
    input      [13:1] cpu_addr,
    input      [15:0] cpu_dout,
    input      [ 1:0] cpu_dsn,
    output     [15:0] vram_dout,

    // tile ROM: { code, row } -> eight 4-bit pixels
    output     [20:2] rom0_addr,
    output            rom0_cs,
    input      [31:0] rom0_data,
    input             rom0_ok,
    output     [20:2] rom1_addr,
    output            rom1_cs,
    input      [31:0] rom1_data,
    input             rom1_ok,

    output     [ 8:0] lyr0_pxl,
    output     [ 8:0] lyr1_pxl,
    output     [ 8:0] lyr2_pxl,
    output     [ 8:0] lyr3_pxl,
    output     [ 8:0] ynow,       // MAME's screen line, for the object chip
    output reg [ 8:0] rx,         // the displayed pixel, addressed through the blank
    output reg [ 8:0] xlast,      // the last visible pixel and line, measured from the
    output reg [ 8:0] ylast,      // CCU's blanking
    output     [ 7:0] rom_bank,   // register 0x1a: the CPU's 8 kB tile ROM window
    output     [ 7:0] st_dout
);

parameter XOFF = 40;    // MAME's screen x of the first visible pixel (xexex.cpp:705)

reg  [15:0] regs[0:31];
wire [15:0] reg0 = regs[0], reg1 = regs[1], reg3 = regs[3], reg5 = regs[5];
wire [ 7:0] cpu_bank = regs[5'h19][7:0], scr_bank = regs[5'h18][7:0];
assign rom_bank = regs[5'h1a][7:0];  // MAME takes regs 0x1a | 0x1b<<16 modulo 256 banks
integer i;

// ---------------------------------------------------------------- CPU side
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<32; i=i+1 ) regs[i] <= 0;
    end else if( reg_cs && cpu_we ) begin
        if( !cpu_dsn[1] ) regs[cpu_addr[5:1]][15:8] <= cpu_dout[15:8];
        if( !cpu_dsn[0] ) regs[cpu_addr[5:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

wire [13:0] cpu_vaddr = { cpu_bank[4:3], cpu_bank[0], cpu_addr[12:2] };
wire        vram_wr   = vram_cs & cpu_we;
wire [ 7:0] cpu_attr;
wire [15:0] cpu_code;
assign vram_dout = cpu_addr[1] ? cpu_code : { 8'd0, cpu_attr };

// scan port, shared by the engines on alternate clocks
reg         scan_sel;
wire [13:0] scan_addr;
wire [ 7:0] scan_attr;
wire [15:0] scan_code;

jtframe_dual_ram #(.DW(8),.AW(14)) u_attr(
    .clk0   ( clk       ),
    .data0  ( cpu_dout[7:0] ),
    .addr0  ( cpu_vaddr ),
    .we0    ( vram_wr & ~cpu_addr[1] & ~cpu_dsn[0] ),
    .q0     ( cpu_attr  ),
    .clk1   ( clk       ),
    .data1  ( 8'd0      ),
    .addr1  ( scan_addr ),
    .we1    ( 1'b0      ),
    .q1     ( scan_attr )
);

jtframe_dual_ram16 #(.AW(15)) u_code(
    .clk0   ( clk       ),
    .data0  ( cpu_dout  ),
    .addr0  ( cpu_vaddr ),
    .we0    ( {2{vram_wr & cpu_addr[1]}} & ~cpu_dsn ),
    .q0     ( cpu_code  ),
    .clk1   ( clk       ),
    .data1  ( 16'd0     ),
    .addr1  ( scan_addr ),
    .we1    ( 2'b0      ),
    .q1     ( scan_code )
);

// ---------------------------------------------------------------- line timing
// Y is MAME's screen line: vdump less its value on the first visible line. At the
// end of line Y's visible part, line Y+2 is drawn into the buffer Y freed.
reg  [ 8:0] vstart;
reg         lvbl_l, lhbl_l, first;
reg  [ 8:0] ry;
reg         start;
wire [ 8:0] y_now = vdump - vstart;
assign ynow = y_now;

always @(posedge clk) begin
    if( rst ) begin
        vstart <= 0; lvbl_l <= 0; lhbl_l <= 0; first <= 0; start <= 0; ry <= 0; rx <= 0;
        xlast <= 9'd383; ylast <= 9'd250;
    end else begin
        lvbl_l <= lvbl;
        lhbl_l <= lhbl;
        start  <= 0;
        if( lvbl && !lvbl_l ) first <= 1;
        if( lhbl && !lhbl_l && first && lvbl ) begin vstart <= vdump; first <= 0; end
        // pixel 0 is addressed through the blank, so its data is out for the first pixel
        if( !lhbl ) rx <= 0; else if( pxl_cen ) rx <= rx + 9'd1;
        if( !lhbl && lhbl_l ) begin
            ry    <= y_now + 9'd2;
            start <= 1;
            if( lvbl ) xlast <= rx - 9'd1;
        end
        if( !lvbl && lvbl_l ) ylast <= y_now - 9'd1;
    end
end

// ---------------------------------------------------------------- engines
wire [13:0] scan_a0, scan_a1;
wire        scan_rq0, scan_rq1;
wire [ 9:0] lb_wa0, lb_wa1;
wire [ 8:0] lb_wd0, lb_wd1;
wire        lb_we0, lb_we1, lb_l0, lb_l1;   // lb_l: which of the engine's two layers
wire        busy0, busy1;

always @(posedge clk) scan_sel <= ~scan_sel;
assign scan_addr = scan_sel ? scan_a1 : scan_a0;

// flipped, line Y shows line ylast-Y, read right to left; the buffer half stays Y's
wire [ 8:0] src_y = flip ? ylast - ry : ry;

jtxexex_tileng #(.L0(0),.XOFF(XOFF)) u_eng0(
    .rst(rst), .clk(clk), .start(start), .y(src_y), .ry_buf(ry[0]),
    .reg0(reg0), .reg1(reg1), .reg3(reg3), .reg5(reg5), .scr_bank(scr_bank),
    .ys({regs[11],regs[10],regs[9],regs[8]}), .xs({regs[15],regs[14],regs[13],regs[12]}),
    .dys({regs[17],regs[16]}), .dxs({regs[21],regs[20]}), .vcorr(regs[5'h1e]),
    .scan_addr(scan_a0), .scan_gnt(~scan_sel), .scan_attr(scan_attr), .scan_code(scan_code),
    .rom_addr(rom0_addr), .rom_cs(rom0_cs), .rom_data(rom0_data), .rom_ok(rom0_ok),
    .lb_addr(lb_wa0), .lb_data(lb_wd0), .lb_we(lb_we0), .lb_layer(lb_l0), .busy(busy0)
);

jtxexex_tileng #(.L0(2),.XOFF(XOFF)) u_eng1(
    .rst(rst), .clk(clk), .start(start), .y(src_y), .ry_buf(ry[0]),
    .reg0(reg0), .reg1(reg1), .reg3(reg3), .reg5(reg5), .scr_bank(scr_bank),
    .ys({regs[11],regs[10],regs[9],regs[8]}), .xs({regs[15],regs[14],regs[13],regs[12]}),
    .dys({regs[19],regs[18]}), .dxs({regs[23],regs[22]}), .vcorr(regs[5'h1e]),
    .scan_addr(scan_a1), .scan_gnt(scan_sel), .scan_attr(scan_attr), .scan_code(scan_code),
    .rom_addr(rom1_addr), .rom_cs(rom1_cs), .rom_data(rom1_data), .rom_ok(rom1_ok),
    .lb_addr(lb_wa1), .lb_data(lb_wd1), .lb_we(lb_we1), .lb_layer(lb_l1), .busy(busy1)
);

// ---------------------------------------------------------------- line buffers
wire [ 9:0] rd_addr = { y_now[0], flip ? xlast - rx : rx };
wire [ 8:0] q0, q1, q2, q3;

jtframe_dual_ram #(.DW(9),.AW(10)) u_lb0(
    .clk0(clk), .data0(lb_wd0), .addr0(lb_wa0), .we0(lb_we0 & ~lb_l0), .q0(),
    .clk1(clk), .data1(9'd0),   .addr1(rd_addr), .we1(1'b0), .q1(q0) );
jtframe_dual_ram #(.DW(9),.AW(10)) u_lb1(
    .clk0(clk), .data0(lb_wd0), .addr0(lb_wa0), .we0(lb_we0 &  lb_l0), .q0(),
    .clk1(clk), .data1(9'd0),   .addr1(rd_addr), .we1(1'b0), .q1(q1) );
jtframe_dual_ram #(.DW(9),.AW(10)) u_lb2(
    .clk0(clk), .data0(lb_wd1), .addr0(lb_wa1), .we0(lb_we1 & ~lb_l1), .q0(),
    .clk1(clk), .data1(9'd0),   .addr1(rd_addr), .we1(1'b0), .q1(q2) );
jtframe_dual_ram #(.DW(9),.AW(10)) u_lb3(
    .clk0(clk), .data0(lb_wd1), .addr0(lb_wa1), .we0(lb_we1 &  lb_l1), .q0(),
    .clk1(clk), .data1(9'd0),   .addr1(rd_addr), .we1(1'b0), .q1(q3) );

assign lyr0_pxl = lhbl ? q0 : 9'd0;
assign lyr1_pxl = lhbl ? q1 : 9'd0;
assign lyr2_pxl = lhbl ? q2 : 9'd0;
assign lyr3_pxl = lhbl ? q3 : 9'd0;

// debug: an engine still drawing when the next line starts
reg late;
always @(posedge clk) if( rst ) late <= 0; else if( start && (busy0 || busy1) ) late <= 1;
assign st_dout = { late, busy0, busy1, 5'd0 };

`ifdef SIMULATION
// the longest line draw so far, in clocks; the limit is a line, 3072
integer bcnt=0, bmax=0;
always @(posedge clk) begin
    if( start ) bcnt <= 0; else if( busy0 || busy1 ) bcnt <= bcnt + 1;
    if( !(busy0 || busy1) && bcnt > bmax ) begin
        bmax <= bcnt;
        $display("jtxexex_tilemap: longest line draw %0d clocks", bcnt);
    end
end
always @(posedge clk) if( start && (busy0 || busy1) && lvbl )
    $display("jtxexex_tilemap: line %0d not finished in time", ry - 9'd2);
always @(posedge clk) if( reg0[4] && start && ry==9'd0 )
    $display("jtxexex_tilemap: flip x is not implemented");
`endif

endmodule

////////////////////////////////////////////////////////////////////////////////
// One engine: two layers of one line, L0 and L0+1
module jtxexex_tileng #(parameter L0=0, XOFF=40)(
    input             rst,
    input             clk,
    input             start,
    input      [ 8:0] y,
    input             ry_buf,
    input      [15:0] reg0, reg1, reg3, reg5,
    input      [ 7:0] scr_bank,
    input      [63:0] ys, xs,         // registers 0x10-0x16 and 0x18-0x1e, layer 0 in [15:0]
    input      [31:0] dys, dxs,       // this engine's two layers, L0 in [15:0]
    input      [15:0] vcorr,
    output reg [13:0] scan_addr,
    input             scan_gnt,
    input      [ 7:0] scan_attr,
    input      [15:0] scan_code,
    output reg [20:2] rom_addr,
    output reg        rom_cs,
    input      [31:0] rom_data,
    input             rom_ok,
    output reg [ 9:0] lb_addr,
    output reg [ 8:0] lb_data,
    output reg        lb_we,
    output reg        lb_layer,
    output            busy
);

localparam [3:0] IDLE=0, SETUP=1, SCR=2, SCRW=3, X=5, TREQ=6, TWAIT=7, TDATA=8, ROM=9;
localparam [1:0] LB = L0;
localparam [10:0] XO = XOFF;

reg  [ 3:0] st;
reg         ls;                 // layer select within the engine
reg  [ 8:0] ly;
reg         lbuf;
reg  [ 5:0] t;                  // tile count, 0-48

wire [ 1:0] lnum = LB + { 1'b0, ls };
wire [15:0] yreg = ys[ lnum*16 +: 16 ];
wire [15:0] xreg = xs[ lnum*16 +: 16 ];
wire [15:0] dy   = ls ? dys[31:16] : dys[15:0];
wire [15:0] dx   = ls ? dxs[31:16] : dxs[15:0];
wire [ 1:0] rowstart = yreg[4:3], rowh = yreg[1:0];
wire [ 1:0] colstart = xreg[4:3], colw = xreg[1:0];
wire [ 1:0] mode     = reg5[ lnum*2 +: 2 ];
wire        flipy    = reg0[5];
wire [ 1:0] fbits    = reg3[7:6];
wire [ 1:0] flip_en  = reg1[ lnum*2 +: 2 ];

// layer height and width masks: 1, 2 or 4 pages (3 wraps as 4: doc/HACKS.md)
wire [ 9:0] hmask = rowh==0 ? 10'h0ff : rowh==1 ? 10'h1ff : 10'h3ff;
wire [10:0] wmask = colw==0 ? 11'h1ff : colw==1 ? 11'h3ff : 11'h7ff;

// flip correction: register 0x3c, 11 bits signed, only with flip y
wire [15:0] vcorr_x = flipy ? { {5{vcorr[10]}}, vcorr[10:0] } : 16'd0;
wire [15:0] dyc     = dy + vcorr_x;
wire [ 9:0] ay      = (dyc[9:0] - 10'd16) & hmask;
// source row in the layer
wire [ 9:0] srow    = (flipy ? ay - 10'd1 - { 1'b0, ly } : ay + { 1'b0, ly }) & hmask;

// line scroll entry (scripts/video_model.py scroll_entries, in closed form)
reg  [ 8:0] ent;
always @* begin
    if( rowh != 0 )
        ent = mode==2'd2 ? { srow[8:3], 3'd0 } : srow[8:0];
    else if( !flipy )
        ent = mode==2'd2 ? { dyc[8:3], 3'd0 } + ((ly + { 6'd0, dyc[2:0] }) & 9'h1f8) : dyc[8:0] + ly;
    else
        ent = mode==2'd2 ? 9'd248 - ((ly + { 6'd0, dyc[2:0] }) & 9'h1f8) : 9'd255 - ly;
end

// layer x offsets, xexex.cpp:306-309, negated: corr = -offs
wire [15:0] corr = lnum==0 ? 16'd2 : lnum==1 ? -16'd2 : lnum==2 ? -16'd4 : -16'd6;

// page ownership, update_page_layout: the last layer whose rectangle holds the page;
// with association off (a layer spanning all 16 pages) any covered page draws
function covers( input [15:0] yr, input [15:0] xr, input [1:0] row, input [1:0] col );
    covers = ((row - yr[4:3]) <= yr[1:0]) && ((col - xr[4:3]) <= xr[1:0]);
endfunction
function whole( input [15:0] yr, input [15:0] xr );
    whole = yr[4:3]==0 && xr[4:3]==0 && yr[1:0]==3 && xr[1:0]==3;
endfunction

reg  [15:0] sdx;                // the line's x scroll
reg  [10:0] sx0;
reg  [10:0] tx;                 // source x of the tile being fetched
reg  [ 1:0] prow, pcol;
reg         own;
reg  [ 7:0] attr;
reg  [ 1:0] tflip;
reg  [ 3:0] tcol;
reg         talpha;
// pixel writer
reg  [31:0] wdata;
reg  [ 3:0] wcnt;
reg  [ 9:0] wx;
reg         wflipx, wown, walpha, wlayer;
reg  [ 3:0] wcol;

wire        assoc_off = whole(ys[15:0],xs[15:0]) || whole(ys[31:16],xs[31:16]) ||
                        whole(ys[47:32],xs[47:32]) || whole(ys[63:48],xs[63:48]);
reg         owned;
always @* begin
    owned = covers( yreg, xreg, prow, pcol );
    if( !assoc_off ) begin
        if( lnum < 1 && covers(ys[31:16],xs[31:16],prow,pcol) ) owned = 0;
        if( lnum < 2 && covers(ys[47:32],xs[47:32],prow,pcol) ) owned = 0;
        if( lnum < 3 && covers(ys[63:48],xs[63:48],prow,pcol) ) owned = 0;
    end else begin
        owned = covers(ys[15:0],xs[15:0],prow,pcol) || covers(ys[31:16],xs[31:16],prow,pcol) ||
                covers(ys[47:32],xs[47:32],prow,pcol) || covers(ys[63:48],xs[63:48],prow,pcol);
    end
end

// attribute decode, get_tile_info's shift masks and xexex's tile callback
reg  [ 7:0] colour;
reg  [ 1:0] aflip;
always @* begin
    case( fbits )
        2'd0: begin aflip = scan_attr[7:6]; colour = { 2'd0, scan_attr[5:0] }; end
        2'd1: begin aflip = scan_attr[5:4]; colour = { 2'd0, scan_attr[7:6], scan_attr[3:0] }; end
        2'd2: begin aflip = scan_attr[3:2]; colour = { 2'd0, scan_attr[7:4], scan_attr[1:0] }; end
        default: begin aflip = scan_attr[1:0]; colour = { 2'd0, scan_attr[7:2] }; end
    endcase
end

assign busy = st != IDLE || wcnt != 0;

always @(posedge clk) begin
    if( rst ) begin
        st <= IDLE; rom_cs <= 0; lb_we <= 0; wcnt <= 0; ls <= 0; t <= 0;
        scan_addr <= 0; rom_addr <= 0;
    end else begin
        lb_we <= 0;
        // pixel writer: eight pixels, one a clock
        if( wcnt != 0 ) begin : writer
            reg [2:0] cx;
            reg [3:0] pen;
            cx = wflipx ? 3'd7 - (4'd8 - wcnt) : 3'd0 + (4'd8 - wcnt);
            case( cx )
                3'd0: pen = wdata[15:12];
                3'd1: pen = wdata[11: 8];
                3'd2: pen = wdata[ 7: 4];
                3'd3: pen = wdata[ 3: 0];
                3'd4: pen = wdata[31:28];
                3'd5: pen = wdata[27:24];
                3'd6: pen = wdata[23:20];
                default: pen = wdata[19:16];
            endcase
            if( !wown ) pen = 0;
            lb_addr  <= { lbuf, wx[8:0] };
            lb_data  <= { walpha, wcol, pen };
            lb_layer <= wlayer;
            lb_we    <= wx < 10'd384;
            wx       <= wx + 10'd1;
            wcnt     <= wcnt - 4'd1;
        end
        case( st )
            IDLE: if( start ) begin
                ly <= y; lbuf <= ry_buf; ls <= 0; st <= SETUP;
            end
            SETUP: begin
                if( mode == 2'd3 || mode == 2'd1 ) begin
                    sdx <= dx; st <= X;
                end else begin
                    // the scroll pair's odd word, in the code RAM
                    scan_addr <= { scr_bank[4:3], scr_bank[0], lnum, ent };
                    st <= SCR;
                end
            end
            SCR:  if( scan_gnt ) st <= SCRW;
            SCRW: begin sdx <= scan_code; st <= X; end  // valid only this clock
            X: begin
                sx0 <= (XO + sdx[10:0] + corr[10:0]) & wmask;
                t   <= 0;
                st  <= TREQ;
            end
            TREQ: begin
                tx   = { sx0[10:3], 3'd0 } + { t, 3'd0 };
                tx   = tx & wmask;
                prow = rowstart + srow[9:8];
                pcol = colstart + tx[10:9];
                scan_addr <= { prow, pcol[0], srow[7:3], tx[8:3] };
                st <= TWAIT;
            end
            TWAIT: if( scan_gnt ) st <= TDATA;
            TDATA: begin    // the RAM's output, a clock after the granted address
                own    <= owned;
                tflip  <= flip_en & aflip;
                tcol   <= colour[5:2];
                talpha <= colour[0];
                rom_addr <= { scan_code, srow[2:0] ^ {3{flip_en[1] & aflip[1]}} };
                rom_cs <= 1;
                st <= ROM;
            end
            ROM: if( rom_ok && wcnt==0 && rom_cs ) begin
                wdata  <= rom_data;
                wcnt   <= 4'd8;
                wx     <= { 1'b0, t, 3'd0 } - { 7'd0, sx0[2:0] };
                wflipx <= tflip[0];
                wown   <= own;
                walpha <= talpha;
                wcol   <= tcol;
                wlayer <= ls;
                rom_cs <= 0;
                if( t == 6'd48 ) begin
                    if( ls ) st <= IDLE;
                    else begin ls <= 1; st <= SETUP; end
                end else begin
                    t  <= t + 6'd1;
                    st <= TREQ;
                end
            end
            default: st <= IDLE;
        endcase
    end
end

endmodule
