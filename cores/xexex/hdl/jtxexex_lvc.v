/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Written by Paul Priest. */

// The K053250 (LVC) of Xexex, as MAME's k053250.cpp draws it.
//
// CPU side: 4k words of RAM (0c6000), eight registers (0c8000, low bytes) and the ROM
// readback (1a0000: byte 0x800 * reg 7 + offset / 2). A falling bit 1 of register 4
// copies RAM 0-0x7ff into line table [page] and flips the page; the frame is drawn from
// table [page], the one copied the time before (dma(), draw()).
//
// Each line table entry is four words: colour (0xffff skips the line), ROM offset in
// 256-pixel units, zoom (0x40 is 1:1), scroll. In normal mode an entry draws a screen
// line; with X and Y swapped (register 4 bit 0 clear) it draws a column, walked down
// the lines with a per-column accumulator.
//
// MAME's pdraw_scanline32 places source pixel floor((k * zoom * 1024 + 0x8000) / 0x10000)
// at destination k of the line, k counted from -scroll; a source-clipped line is
// floor((clipmask + 1) * 64 / zoom) pixels long. Here k * zoom is stepped by adds, one
// multiply by shift-add per line (normal) or per column per frame (swapped). A flipped
// line is the unflipped one mirrored, its source position one less in fixed point.
//
// The renderer works up to RING lines ahead of the display into a ring of line
// buffers: swapped frames need up to 384 ROM words a line for some twenty lines and a
// few dozen on most (scripts/lvc_bandwidth.py), so it builds a lead on the light lines.
// A frame's registers and table are taken 10 lines before its first line.

module jtxexex_lvc #(parameter RW=5)(     // RING = 2^RW lines
    input             rst,
    input             clk,
    input             pxl_cen,

    // timing, from jtxexex_tilemap
    input             lhbl,
    input      [ 8:0] ynow,       // the displayed line; vblank lines read as 0x1xx
    input      [ 8:0] rx,         // the displayed pixel, addressed through the blank
    input      [ 8:0] xlast,
    input      [ 8:0] ylast,
    input             flip,       // the frame turned 180 degrees (OSD)

    // CPU
    input             ram_cs,     // 0c6000-0c7fff
    input             reg_cs,     // 0c8000-0c800f
    input             rom_cs,     // 1a0000-1a1fff, reads
    input             cpu_we,
    input      [12:1] cpu_addr,
    input      [15:0] cpu_dout,
    input      [ 1:0] cpu_dsn,
    output     [15:0] cpu_din,
    output            rom_ok_cpu,

    // ROM, 512 kB as 32-bit words
    output reg [18:2] rom_addr,
    output reg        rom_cs_o,
    input      [31:0] rom_data,
    input             rom_ok,

    output     [ 8:0] pxl         // { colour, pen }
);

// ---------------------------------------------------------------- CPU side
reg  [ 7:0] regs[0:7];
reg         page, dma_go, dma_bsy;
reg  [10:0] dma_a;
wire [15:0] ram_q, ram_dma_q;
wire [ 1:0] ram_we = {2{ram_cs & cpu_we}} & ~cpu_dsn;

assign cpu_din = reg_cs ? { 8'd0, regs[cpu_addr[3:1]] } :
                 rom_cs ? { 8'd0, cpu_byte } : ram_q;

jtframe_dual_ram16 #(.AW(12)) u_ram(
    .clk0   ( clk           ),
    .data0  ( cpu_dout      ),
    .addr0  ( cpu_addr      ),
    .we0    ( ram_we        ),
    .q0     ( ram_q         ),
    .clk1   ( clk           ),
    .data1  ( 16'd0         ),
    .addr1  ( { 1'b0, dma_a } ),
    .we1    ( 2'b00         ),
    .q1     ( ram_dma_q     )
);

integer i;
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<8; i=i+1 ) regs[i] <= 0;
        dma_go <= 0;
    end else begin
        dma_go <= 0;
        if( reg_cs && cpu_we && !cpu_dsn[0] ) begin
            regs[cpu_addr[3:1]] <= cpu_dout[7:0];
            if( cpu_addr[3:1]==3'd4 && regs[4][1] && !cpu_dout[1] ) dma_go <= 1;
        end
    end
end

// DMA: RAM 0-0x7ff to table [page], then flip the page. RAM reads a clock late.
reg        tbl_we;
reg [10:0] tbl_wa;
always @(posedge clk) begin
    if( rst ) begin
        page <= 0; dma_bsy <= 0; dma_a <= 0; tbl_we <= 0; tbl_wa <= 0;
    end else begin
        tbl_we <= dma_bsy;
        tbl_wa <= dma_a;
        if( dma_go && !dma_bsy ) begin
            dma_bsy <= 1;
            dma_a   <= 0;
        end else if( dma_bsy ) begin
            dma_a <= dma_a + 11'd1;
            if( &dma_a ) dma_bsy <= 0;
        end
        if( tbl_we && &tbl_wa ) page <= ~page;
    end
end

reg  [11:0] tbl_ra;
wire [15:0] tbl_q;

jtframe_dual_ram16 #(.AW(12)) u_tables(
    .clk0   ( clk           ),
    .data0  ( ram_dma_q     ),
    .addr0  ( { page, tbl_wa } ),
    .we0    ( {2{tbl_we}}   ),
    .q0     (               ),
    .clk1   ( clk           ),
    .data1  ( 16'd0         ),
    .addr1  ( tbl_ra        ),
    .we1    ( 2'b00         ),
    .q1     ( tbl_q         )
);

// ---------------------------------------------------------------- line ring
reg  [RW+8:0] lb_wa;
reg  [ 8:0] lb_wd;
reg         lb_we;
wire [ 8:0] lb_q;
wire [ 8:0] rd_x = flip ? xlast - rx : rx;

jtframe_dual_ram #(.DW(9),.AW(RW+9)) u_ring(
    .clk0   ( clk           ),
    .data0  ( lb_wd         ),
    .addr0  ( lb_wa         ),
    .we0    ( lb_we         ),
    .q0     (               ),
    .clk1   ( clk           ),
    .data1  ( 9'd0          ),
    .addr1  ( { ynow[RW-1:0], rd_x } ),
    .we1    ( 1'b0          ),
    .q1     ( lb_q          )
);

assign pxl = lhbl ? lb_q : 9'd0;

// ---------------------------------------------------------------- columns (swapped)
// valid, colour, offset[11:0], zoom, k, k * zoom; and the column's cached ROM word
localparam CW = 1+5+12+16+17+34;
reg  [ 8:0] col_a, col_wa, cc_wa;   // read; write: column state, column cache
reg  [CW-1:0] col_wd;
reg         col_we;
wire [CW-1:0] col_q;
reg  [16:0] cw_wa_d;
reg  [31:0] cw_wd_d;
reg         cw_we, cw_wv;
wire [49:0] cw_q;

jtframe_dual_ram #(.DW(CW),.AW(9)) u_cols(
    .clk0   ( clk           ),
    .data0  ( {CW{1'b0}}    ),
    .addr0  ( col_a         ),
    .we0    ( 1'b0          ),
    .q0     ( col_q         ),
    .clk1   ( clk           ),
    .data1  ( col_wd        ),
    .addr1  ( col_wa        ),
    .we1    ( col_we        ),
    .q1     (               )
);

jtframe_dual_ram #(.DW(50),.AW(9)) u_colcache(
    .clk0   ( clk           ),
    .data0  ( 50'd0         ),
    .addr0  ( col_a         ),
    .we0    ( 1'b0          ),
    .q0     ( cw_q          ),
    .clk1   ( clk           ),
    .data1  ( { cw_wv, cw_wa_d, cw_wd_d } ),
    .addr1  ( cc_wa         ),
    .we1    ( cw_we         ),
    .q1     (               )
);

// ---------------------------------------------------------------- frame setup
wire signed [9:0] disp = ynow[8] ? { 1'b1, ynow } : { 1'b0, ynow };   // vblank: negative

reg  [ 7:0] f_ctrl;
reg         f_page, f_flip, f_swap, f_flipx, f_flipy, f_clip, f_w500, f_h512;
reg  [ 9:0] f_wrap, f_clipm;
reg  signed [16:0] f_corr;
reg  signed [12:0] f_offs;
reg  signed [ 2:0] f_dir;          // per line: k steps by f_dir in swapped mode

function signed [15:0] s16( input [7:0] h, input [7:0] l ); s16 = { h, l }; endfunction

// ---------------------------------------------------------------- renderer
localparam [4:0] IDLE=0, FS=1, FCOL=2, FCOLR=3, FMUL=4, FCOLW=5,
                 LSTART=6, LPKT=7, LMUL=8, LPIX=9, LFETCH=10, LWAIT=11, LWR=12,
                 SLINE=13, LNEXT=14;
reg  [ 4:0] st, ret;
reg  [ 8:0] R, c;
reg         frame_ok, disp_l8;
reg  [ 9:0] disp_l;
reg  [ 2:0] pk;                    // packet word being read
reg  [15:0] p_col, p_off, p_zoom, p_scr;
reg  signed [16:0] k;
reg  signed [33:0] kz, m_acc;
reg  [15:0] m_z;
reg  signed [16:0] m_k;
reg  [ 4:0] m_n;
reg  [10:0] po;
reg         valid;
reg  [16:0] cache_a;
reg  [31:0] cache_d;
reg         cache_v;
reg  [19:0] nib_b;
reg  [ 3:0] pen, pen_b;
reg         drawn_a, drawn_b, pass_b;
reg  [19:0] nib;
wire [ 8:0] s_line = f_flip ? ylast - R : R;     // the line or column position MAME draws

// swapped lines: a walker reads each column, steps it to the next line and queues its
// source nibbles; a fetcher takes the queue, reads the ROM on a cache miss and writes
// the pixel, so the walk overlaps the ROM's latency
localparam QW = 9+5+2+20+20+1+17+32;
reg  [QW-1:0] q[0:3];
reg  [ 1:0] q_wp, q_rp;
reg  [ 2:0] q_n;
reg  [ 8:0] w_c, f_cnt;
reg  [ 1:0] w_ph, f_ph;
reg         w_done;
reg  [ 8:0] f_c;
reg  [ 4:0] f_col;
reg         f_dra, f_drb;
reg  [19:0] f_na, f_nb;

// the source nibble of k (k * zoom = kzv) on the current entry
function [19:0] srcnib( input signed [33:0] kzv, input [11:0] off, input fl, input [9:0] mask );
    reg [31:0] t;
    begin
        t = { kzv[21:0], 10'd0 } + 32'h8000 - { 31'd0, fl };
        srcnib = { off, 8'd0 } + { 10'd0, t[25:16] & mask };
    end
endfunction

// whether k is inside a source-clipped line
function inclip( input signed [16:0] kk, input signed [33:0] kzv, input [15:0] z, input [9:0] cm );
    reg [10:0] lim;
    begin
        lim = { 1'b0, cm } + 11'd1;
        // MAME's length is floor((clipmask + 1) * 64 / zoom): k + 1 pixels fit
        inclip = kk >= 0 && ( z==0 ? kk <= $signed({7'd0,cm}) :
                              kzv + $signed({18'd0,z}) <= $signed({17'd0, lim, 6'd0}) );
    end
endfunction

function [3:0] nibble( input [31:0] d, input [2:0] j );
    reg [7:0] b;
    begin
        b = d[{j[2:1],3'd0}+:8];
        nibble = j[0] ? b[3:0] : b[7:4];
    end
endfunction

wire ahead = $signed({1'b0,R}) < disp + (10'sd1 << RW);  // the ring has room for line R

// CPU ROM readback shares the bus between the renderer's fetches
reg         cpu_rd, cpu_done;
reg  [ 7:0] cpu_byte;
assign rom_ok_cpu = cpu_done;
wire [18:0] cpu_rom_a = { regs[7], cpu_addr[11:1] };

always @(posedge clk) begin
    if( rst ) begin
        st <= IDLE; R <= 0; frame_ok <= 0; lb_we <= 0; col_we <= 0; cw_we <= 0;
        rom_cs_o <= 0; rom_addr <= 0; cache_v <= 0; disp_l <= 0; cpu_rd <= 0; cpu_done <= 0;
        tbl_ra <= 0; f_flip <= 0;
    end else begin
        lb_we  <= 0;
        col_we <= 0;
        cw_we  <= 0;
        disp_l <= disp;
        if( !rom_cs ) cpu_done <= 0;
        case( st )
            IDLE: begin
                // CPU readback, between fetches
                if( rom_cs && !cpu_done && !cpu_rd ) begin
                    cpu_rd <= 1; rom_addr <= cpu_rom_a[18:2]; rom_cs_o <= 1;
                end else if( cpu_rd && rom_ok && rom_cs_o ) begin
                    cpu_byte <= rom_data[{cpu_rom_a[1:0],3'd0}+:8];
                    cpu_rd <= 0; cpu_done <= 1; rom_cs_o <= 0;
                end else if( !cpu_rd && frame_ok && R <= ylast && ahead ) begin
                    st <= f_swap ? SLINE : LSTART;
                    c  <= 0;
                    w_c <= 0; w_ph <= 0; w_done <= 0;
                    q_wp <= 0; q_rp <= 0; q_n <= 0;
                    f_cnt <= 0; f_ph <= 0;
                end
            end
            FS: begin
                f_ctrl  <= regs[4];
                f_page  <= page;
                f_flip  <= flip;
                f_swap  <= ~regs[4][0];
                f_flipx <= regs[4][3];
                f_flipy <= regs[4][4];
                f_w500  <= regs[4][7:5]==3'd4;
                f_h512  <= regs[4][7:5]!=3'd0;
                case( regs[4][7:5] )
                    3'd0, 3'd4: begin f_wrap <= 10'h0ff; f_clipm <= regs[4][2] ? 10'd0 : 10'h0ff; end
                    3'd1:       begin f_wrap <= 10'h1ff; f_clipm <= regs[4][2] ? 10'd0 : 10'h1ff; end
                    default:    begin f_wrap <= 10'h3ff; f_clipm <= regs[4][2] ? 10'd0 : 10'h3ff; end
                endcase
                f_clip <= ~regs[4][2];
                R <= 0;
                cache_v <= 0;
                if( regs[4][0] ) begin  // normal: the X scroll corrects every line
                    f_corr <= regs[4][3] ? -($signed(s16(regs[0],regs[1]))+17'sd5)
                                         :   $signed(s16(regs[0],regs[1]))+17'sd5;
                    f_offs <= s16(regs[2],regs[3]) + 13'sd16 + (regs[4][4] ? 13'sd255 : 13'sd0);
                    frame_ok <= 1;
                    st <= IDLE;
                end else begin          // swapped: the Y scroll; columns from the X scroll
                    f_corr <= regs[4][4] ? 17'sh100 - ($signed(s16(regs[2],regs[3]))+17'sd16) - 17'sd2
                                         :   $signed(s16(regs[2],regs[3])) + 17'sd16;
                    f_offs <= s16(regs[0],regs[1]) + 13'sd5 - (regs[4][4] ? 13'sd5 : 13'sd0)
                                                     + (regs[4][3] ? 13'sd423 : 13'sd0);
                    f_dir  <= (regs[4][4] ^ flip) ? -3'sd1 : 3'sd1;
                    c <= 0;
                    st <= FCOL;
                end
            end
            // ---- per-column setup (swapped)
            FCOL: begin
                // entry of column c: (offs * 4 + (40 + c) * adv) & 0x7ff
                po <= ( {f_offs[8:0],2'd0} + ( f_flipx ? -{ {1'b0,c} + 10'd40, 2'd0 }
                                                       :  { {1'b0,c} + 10'd40, 2'd0 } ) );
                pk <= 0;
                st <= FCOLR;
            end
            FCOLR: begin
                tbl_ra <= { f_page, po[10:0] + {9'd0,pk[1:0]} };
                pk <= pk + 3'd1;
                case( pk )      // table read a clock after its address
                    3'd2: p_col  <= tbl_q;
                    3'd3: p_off  <= tbl_q;
                    3'd4: p_zoom <= tbl_q;
                    3'd5: begin
                        p_scr <= tbl_q;
                        st <= FMUL;
                    end
                endcase
            end
            FMUL: begin : fmul
                reg signed [16:0] sc, u0;
                sc = $signed(p_scr);
                if( f_w500 && $signed(p_scr) >= 16'sh500 ) sc = sc - 17'sh800;
                sc = sc + f_corr;
                if( f_clip ) sc = sc & (f_h512 ? 17'h1ff : 17'h0ff);
                u0 = f_flipy ? 17'sd255 - (f_flip ? $signed({8'd0,ylast}) : 17'sd0)
                             : (f_flip ? $signed({8'd0,ylast}) : 17'sd0);
                valid <= !(p_col==16'hffff) && !(p_col[7:0]==0 && p_off==0);
                m_k   <= u0 + sc;
                k     <= u0 + sc;
                m_z   <= p_zoom;
                m_acc <= 0;
                m_n   <= 0;
                ret   <= FCOLW;
                st    <= LMUL;
            end
            FCOLW: begin
                col_wa <= c;
                cc_wa  <= c;
                col_wd <= { valid, p_col[4:0], p_off[11:0], p_zoom, k, m_acc };
                col_we <= 1;
                cw_wv  <= 0; cw_wa_d <= 0; cw_wd_d <= 0; cw_we <= 1;
                if( c==9'd383 ) begin
                    frame_ok <= 1;
                    st <= IDLE;
                end else begin
                    c  <= c + 9'd1;
                    st <= FCOL;
                end
            end
            // ---- multiply m_k * m_z into m_acc, then return
            // shift-add multiply: m_acc = m_k * m_z, m_k two's complement, 17 clocks
            LMUL: begin
                if( m_k[m_n] ) m_acc <= m_n==5'd16 ? m_acc - ({18'd0,m_z} << m_n) : m_acc + ({18'd0,m_z} << m_n);
                if( m_n==5'd16 ) st <= ret; else m_n <= m_n + 5'd1;
            end
            // ---- normal line R
            LSTART: begin
                po <= {f_offs[8:0],2'd0} + ( f_flipy ? -{ s_line, 2'd0 } : { s_line, 2'd0 } );
                pk <= 0;
                st <= LPKT;
            end
            LPKT: begin
                tbl_ra <= { f_page, po[10:0] + {9'd0,pk[1:0]} };
                pk <= pk + 3'd1;
                case( pk )
                    3'd2: p_col  <= tbl_q;
                    3'd3: p_off  <= tbl_q;
                    3'd4: p_zoom <= tbl_q;
                    3'd5: begin : lsetup
                        reg signed [16:0] sc;
                        p_scr <= tbl_q;
                        sc = $signed(tbl_q);
                        if( f_w500 && $signed(tbl_q) >= 16'sh500 ) sc = sc - 17'sh800;
                        sc = sc + f_corr;
                        valid <= !(p_col==16'hffff) && !(p_col[7:0]==0 && p_off==0);
                        k     <= 17'sd40 + sc;
                        m_k   <= 17'sd40 + sc;
                        m_z   <= p_zoom;
                        m_acc <= 0;
                        m_n   <= 0;
                        ret   <= LPIX;
                        st    <= LMUL;
                        c     <= 0;
                    end
                endcase
            end
            LPIX: begin
                if( c==9'd0 ) kz <= m_acc;
                drawn_a <= valid && (!f_clip || inclip(k, c==0 ? m_acc : kz, p_zoom, f_clipm));
                nib     <= srcnib( c==0 ? m_acc : kz, p_off[11:0], f_flipx, f_clip ? 10'h3ff : f_wrap );
                st      <= LFETCH;
            end
            LFETCH: begin
                if( !drawn_a ) begin
                    pen <= 0; st <= LWR;
                end else if( cache_v && cache_a==nib[19:3] ) begin
                    pen <= nibble(cache_d, nib[2:0]); st <= LWR;
                end else begin
                    rom_addr <= nib[19:3]; rom_cs_o <= 1; st <= LWAIT;
                end
            end
            LWAIT: if( rom_ok && rom_addr==nib[19:3] && rom_cs_o ) begin
                cache_v <= 1; cache_a <= nib[19:3]; cache_d <= rom_data;
                pen <= nibble(rom_data, nib[2:0]);
                rom_cs_o <= 0;
                st <= LWR;
            end
            LWR: begin
                lb_wa <= { R[RW-1:0], f_flipx ? 9'd383 - c : c };
                lb_wd <= pen==0 ? 9'd0 : { p_col[4:0], pen };
                lb_we <= 1;
                k  <= k + 17'sd1;
                kz <= kz + {18'd0, p_zoom};
                if( c==9'd383 ) st <= LNEXT;
                else begin c <= c + 9'd1; st <= LPIX; end
            end
            // ---- swapped line R: walker and fetcher below
            SLINE: ;
            LNEXT: begin
                R  <= R + 9'd1;
                st <= IDLE;
            end
            default: st <= IDLE;
        endcase
        // ---- swapped line: the walker
        if( st==SLINE ) begin : walker
            reg signed [16:0] kk, kb;
            reg signed [33:0] kzz, kzb;
            reg [15:0] z;
            reg [11:0] off;
            reg        v;
            case( w_ph )
                2'd0: begin col_a <= w_c; w_ph <= 2'd1; end
                2'd1: w_ph <= 2'd2;            // column state out a clock after its address
                2'd2: if( !w_done && q_n < 3'd4 ) begin
                    v   = col_q[CW-1];
                    off = col_q[CW-7 -: 12];
                    z   = col_q[CW-19 -: 16];
                    kk  = col_q[50:34];
                    kzz = col_q[33:0];
                    kb  = kk - (f_h512 ? 17'sd512 : 17'sd256);
                    kzb = kzz - ({18'd0,z} << (f_h512 ? 9 : 8));
                    // pass 2 (k - height) draws over pass 1
                    q[q_wp] <= { w_c, col_q[CW-2 -: 5],
                                 v && (!f_clip || inclip(kk, kzz, z, f_clipm)),
                                 v && f_clip && inclip(kb, kzb, z, f_clipm),
                                 srcnib( kzz, off, f_flipy, f_clip ? 10'h3ff : f_wrap ),
                                 srcnib( kzb, off, f_flipy, 10'h3ff ),
                                 cw_q };
                    q_wp <= q_wp + 2'd1;
                    // the column one line on
                    col_wd <= { col_q[CW-1:51], kk + {{14{f_dir[2]}},f_dir},
                                f_dir[2] ? kzz - {18'd0,z} : kzz + {18'd0,z} };
                    col_wa <= w_c;
                    col_we <= 1;
                    if( w_c==9'd383 ) w_done <= 1;
                    else begin
                        w_c   <= w_c + 9'd1;
                        col_a <= w_c + 9'd1;
                        w_ph  <= 2'd1;
                    end
                end
                default:;
            endcase
        end
        // ---- swapped line: the fetcher
        if( st==SLINE ) begin : fetcher
            reg [19:0] n;
            reg        dr, wr;
            reg [ 3:0] pn;
            wr = 0;
            pn = 0;
            case( f_ph )
                2'd0: if( q_n != 0 ) begin
                    { f_c, f_col, f_dra, f_drb, f_na, f_nb, cache_v, cache_a, cache_d } <= q[q_rp];
                    q_rp   <= q_rp + 2'd1;
                    pass_b <= 1;
                    f_ph   <= 2'd1;
                end
                2'd1: begin
                    n  = pass_b ? f_nb : f_na;
                    dr = pass_b ? f_drb : f_dra;
                    if( !dr ) begin
                        if( pass_b ) pass_b <= 0;
                        else wr = 1;
                    end else if( cache_v && cache_a==n[19:3] ) begin
                        if( pass_b && nibble(cache_d, n[2:0])==0 ) pass_b <= 0;
                        else begin wr = 1; pn = nibble(cache_d, n[2:0]); end
                    end else begin
                        rom_addr <= n[19:3]; rom_cs_o <= 1; f_ph <= 2'd2;
                    end
                end
                2'd2: begin
                    n = pass_b ? f_nb : f_na;
                    if( rom_ok && rom_addr==n[19:3] && rom_cs_o ) begin
                        rom_cs_o <= 0;
                        cache_v <= 1; cache_a <= n[19:3]; cache_d <= rom_data;
                        f_ph <= 2'd1;
                    end
                end
                default:;
            endcase
            if( wr ) begin
                lb_wa <= { R[RW-1:0], f_c };
                lb_wd <= pn==0 ? 9'd0 : { f_col, pn };
                lb_we <= 1;
                cc_wa <= f_c;
                cw_wv <= cache_v; cw_wa_d <= cache_a; cw_wd_d <= cache_d; cw_we <= 1;
                f_ph  <= 2'd0;
                f_cnt <= f_cnt + 9'd1;
                if( f_cnt==9'd383 ) st <= LNEXT;
            end
        end
        // the queue's count: the walker pushes, the fetcher pops
        if( st==SLINE ) q_n <= q_n + ((w_ph==2'd2 && !w_done && q_n < 3'd4) ? 3'd1 : 3'd0)
                                    - ((f_ph==2'd0 && q_n != 0) ? 3'd1 : 3'd0);
        // frame setup ten lines before the first
        if( disp == -10'sd10 && disp_l != -10'sd10 ) begin
            st <= FS; frame_ok <= 0; rom_cs_o <= 0; cpu_rd <= 0;
        end
    end
end

`ifdef SIMULATION
// a line shown before it was rendered
always @(posedge clk) if( lhbl && !disp[9] && frame_ok && $signed({1'b0,R}) <= disp && disp <= $signed({1'b0,ylast}) && pxl_cen && rx==9'd0 )
    $display("jtxexex_lvc: line %0d shown before it was drawn", disp);
`endif

endmodule
