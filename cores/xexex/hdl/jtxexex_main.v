/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Xexex main CPU, written from MAME's xexex.cpp main_map, control2 and
 * interrupt handling (doc/xexex.cpp:465-607). Replaces moo's jtmoo_main.
 * Modified by Paul Priest. */

module jtxexex_main(
    input                rst,
    input                clk,       // 48 MHz
    input                cen_16,
    input                LVBL,      // falling: vblank start, line 256; rising: line 0
    input                dma_bsy,   // K053246 object DMA running

    output        [20:1] main_addr,
    output        [ 1:0] ram_dsn,
    output        [15:0] cpu_dout,
    output               cpu_we,
    // program ROM, SDRAM
    output reg           rom_cs,
    input         [15:0] rom_data,
    input                rom_ok,
    output reg           ram_cs,    // work RAM in BRAM
    input         [15:0] ram_dout,
    output        [ 1:0] ram_we,
    // video chips
    output reg           scrreg_cs, // K054157 registers 0c0000
    output reg           tilesys_cs,// K054157 B registers 0d8000
    output reg           scr_cs,    // tile RAM 180000
    input         [15:0] tilesys_dout,
    output reg           objreg_cs, // K053246 registers 0c2000
    output reg           obj_cs,    // sprite RAM 090000, also written to the object chip
    output        [ 1:0] oram_we,
    input         [15:0] oram_dout, // sprite RAM, or the K053246 ROM readback when objcha_n is low
    output reg           objcha_n,
    output reg           col_cs,    // K054338 0ca000
    output reg           pcu_cs,    // K053251 0cc000
    output reg           pal_cs,    // palette 1b0000
    input         [15:0] pal_dout,
    output reg           tilerom_cs,// tile ROM readback 190000, from SDRAM
    input         [15:0] tilerom_dout,
    input                tilerom_ok,
    output reg           lvcram_cs, // K053250 RAM 0c6000, registers 0c8000, ROM 1a0000
    output reg           lvcreg_cs,
    output reg           lvcrom_cs,
    input         [15:0] lvc_dout,
    input                lvcrom_ok,
    output reg           cco_cs,    // K053252 0d0000
    input         [ 7:0] vtimer_mmr,
    output reg           alpha_off, // control2 bit 9
    // sound
    output reg           sndon,     // 0d4000 write: Z80 IRQ
    output               pair_we,   // K054321 0d6000
    input         [ 7:0] pair_dout,
    // EEPROM
    output        [ 6:0] nv_addr,
    input         [ 7:0] nv_dout,
    output        [ 7:0] nv_din,
    output               nv_we,
    // cabinet, active low
    input         [ 6:0] joystick1,
    input         [ 6:0] joystick2,
    input         [ 3:0] cab_1p,
    input         [ 3:0] coin,
    input         [ 3:0] service,
    input                dip_pause,
    input                dip_test,
    output        [ 7:0] st_dout,
    output        [ 7:0] st_where,  // debug: where the CPU is (see below)
    input         [ 7:0] debug_bus
);

wire [23:1] A;
wire        cpu_cen, cpu_cenb;
wire        UDSn, LDSn, RnW, ASn, VPAn, DTACKn, BGn, cpu_dtackn;
wire [ 2:0] FC;
wire        eep_rdy, eep_do, bus_cs, bus_busy, BUSn, iack;
reg  [ 2:0] IPLn;
reg  [15:0] cpu_din, ctrl2;
reg  [15:0] cab_dout;
reg         HALTn, spr_cs,
            p12_cs, sys_cs, ctrl2_cs, sndirq_cs, pair_cs;
reg         pend4, pend5, pend6, lvbl_l, dma_l;

assign main_addr = A[20:1];
assign ram_dsn   = { UDSn, LDSn };
assign cpu_we    = ~RnW;
assign ram_we    = {2{ram_cs & ~RnW}} & ~ram_dsn;
assign oram_we   = {2{obj_cs & ~RnW}} & ~ram_dsn;
assign bus_cs    = rom_cs | tilerom_cs | lvcrom_cs;   // only SDRAM reads wait
assign bus_busy  = (rom_cs & ~rom_ok) | (tilerom_cs & ~tilerom_ok) | (lvcrom_cs & ~lvcrom_ok);
assign BUSn      = ASn | (LDSn & UDSn);
assign iack      = ~ASn && FC==3'b111;
assign VPAn      = ~iack;          // autovectors
assign pair_we   = pair_cs & ~RnW & ~LDSn;
// DTACK: jtframe's generator for the SDRAM ROM, which holds and repays the CPU's
// phases; from AS for everything else, as the board's zero-wait RAM and chips (and
// MAME) have it. jtframe_68kdtack_cen arms DTACK two clocks after a data strobe,
// and a write strobe comes at S4, too late for S4's sample: a wait state per write.
assign cpu_dtackn = bus_cs ? DTACKn : ASn;
// debug view, bit 7 always set so the row shows: a toggle per object-DMA end, IRQ4 and
// IRQ5 counts (bit 3), control2 bits 11 and 6 (their enables), a blink per 2^20 bus
// cycles; bit 0 is left for the game module
reg  [20:0] bus_cnt;
reg  [ 3:0] irq4_cnt, irq5_cnt;
reg         iack_l, as_l, dma_tog, dmab_l;
assign st_dout   = { 1'b1, dma_tog, irq4_cnt[3], irq5_cnt[3], ctrl2[11], ctrl2[6], bus_cnt[20], 1'b0 };

// where the CPU is, for a screenshot: a bus cycle that stayed open more than 255 clocks
// latches its address (stall); otherwise the address is the current one. st_where
// alternates every 2^26 clocks (1.4 s) between { 0, stall, A[20:15] } and { 1, A[14:8] }
reg  [ 7:0] as_len;
reg  [25:0] phase;
reg  [20:8] where;
reg         stall;
assign st_where = phase[25] ? { 1'b1, where[14:8] } : { 1'b0, stall, where[20:15] };
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        as_len <= 0;
        phase  <= 0;
        stall  <= 0;
        where  <= 0;
    end else begin
        phase  <= phase + 26'd1;
        as_len <= ASn ? 8'd0 : (&as_len ? as_len : as_len + 8'd1);
        if( &as_len ) stall <= 1;
        if( !stall ) where <= A[20:8];
    end
end
always @(posedge clk) begin
    iack_l <= iack;
    as_l   <= ASn;
    dmab_l <= dma_bsy;
    if( iack && !iack_l && A[3:1]==3'd4 ) irq4_cnt <= irq4_cnt + 4'd1;
    if( iack && !iack_l && A[3:1]==3'd5 ) irq5_cnt <= irq5_cnt + 4'd1;
    if( !dma_bsy && dmab_l ) dma_tog <= ~dma_tog;
    if( !ASn && as_l ) bus_cnt <= bus_cnt + 21'd1;
end

// Address map, xexex.cpp main_map (doc/xexex.cpp:565-597). Unlisted addresses read 0.
always @* begin
    { rom_cs, ram_cs, spr_cs, scrreg_cs, objreg_cs, obj_cs, lvcram_cs, lvcreg_cs,
      col_cs, pcu_cs, cco_cs, sndirq_cs, pair_cs, tilesys_cs, p12_cs, sys_cs,
      ctrl2_cs, scr_cs, tilerom_cs, lvcrom_cs, pal_cs } = 0;
    if( !ASn && !iack && A[23:21]==0 ) begin
        case( A[20:16] )
            5'h00,5'h01,5'h02,5'h03,5'h04,5'h05,5'h06,5'h07,
            5'h10,5'h11,5'h12,5'h13,5'h14,5'h15,5'h16,5'h17: rom_cs = 1;
            5'h08: ram_cs = ~BUSn;
            5'h09: spr_cs = ~BUSn;              // 090000-09ffff, mirror at 098000
            5'h0c: case( A[15:13] )             // 0c0000-0cffff, 8 kB blocks
                3'd0: scrreg_cs = A[12:6]==0;   // 0c0000-0c003f
                3'd1: objreg_cs = A[12:3]==0;   // 0c2000-0c2007
                3'd2: obj_cs    = 0;            // 0c4000: K053246 ROM readback, read below
                3'd3: lvcram_cs = ~BUSn;        // 0c6000-0c7fff
                3'd4: lvcreg_cs = A[12:4]==0;   // 0c8000-0c800f
                3'd5: col_cs    = A[12:5]==0;   // 0ca000-0ca01f
                3'd6: pcu_cs    = A[12:5]==0;   // 0cc000-0cc01f
                default:;
            endcase
            5'h0d: case( A[15:13] )
                3'd0: cco_cs     = A[12:5]==0;  // 0d0000-0d001f
                3'd2: sndirq_cs  = 1;           // 0d4000
                3'd3: pair_cs    = A[12:5]==0;  // 0d6000-0d601f
                3'd4: tilesys_cs = A[12:3]==0;  // 0d8000-0d8007
                3'd5: p12_cs     = A[12:2]==0;  // 0da000-0da003
                3'd6: sys_cs     = A[12:2]==0;  // 0dc000-0dc003
                3'd7: ctrl2_cs   = A[12:1]==0;  // 0de000
                default:;
            endcase
            5'h18: case( A[15:14] )
                2'd0: scr_cs     = 1;           // 180000-183fff
                default:;
            endcase
            5'h19: tilerom_cs = A[15:13]==0;    // 190000-191fff
            5'h1a: lvcrom_cs  = A[15:13]==0;    // 1a0000-1a1fff
            5'h1b: pal_cs     = A[15:13]==0;    // 1b0000-1b1fff
            default:;
        endcase
    end
    obj_cs = spr_cs;
    sndon  = sndirq_cs & ~RnW & ~BUSn;
end

wire objrom_rd = !ASn && A[23:13]=={3'd0,5'h0c,3'd2} && RnW;

// Reads. MAME's 68000 space reads 0 where nothing is mapped.
always @(posedge clk) begin
    cpu_din <= rom_cs     ? rom_data :
               tilerom_cs ? tilerom_dout :
               ram_cs     ? ram_dout :
               spr_cs     ? oram_dout :     // the object chip's RAM
               objrom_rd  ? oram_dout :
               scr_cs     ? tilesys_dout :
               (lvcram_cs | lvcreg_cs | lvcrom_cs) ? lvc_dout :
               cco_cs     ? { 8'd0, vtimer_mmr } :
               pair_cs    ? { 8'd0, pair_dout } :
               p12_cs     ? cab_dout :
               sys_cs     ? cab_dout :
               ctrl2_cs   ? ctrl2 :
               pal_cs     ? pal_dout : 16'd0;
end

// xexex.cpp:622-651. P1/P2: KONAMI16_LSB, button 3 unused. SYSTEM: coins, services.
// EEPROM port: DO, ready, service switch.
always @(posedge clk) begin
    case( { sys_cs, A[1] } )
        2'b00: cab_dout <= { 8'd0, cab_1p[0], 1'b1, joystick1[5:0] };
        2'b01: cab_dout <= { 8'd0, cab_1p[1], 1'b1, joystick2[5:0] };
        2'b10: cab_dout <= { 8'hff, 2'b11, service[1], service[0], 2'b11, coin[1], coin[0] };
        2'b11: cab_dout <= { 8'd0, 4'd0, dip_test, 1'b0, eep_rdy, eep_do };
    endcase
end

// control2 (doc/xexex.cpp:465-480)
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ctrl2 <= 0;
    end else if( ctrl2_cs && !RnW && !BUSn ) begin
        if( !UDSn ) ctrl2[15:8] <= cpu_dout[15:8];
        if( !LDSn ) ctrl2[ 7:0] <= cpu_dout[ 7:0];
    end
end

always @* begin
    objcha_n  = ~ctrl2[8];
    alpha_off =  ctrl2[9];
end

// Interrupts, HOLD_LINE: pending until the CPU acknowledges that level (doc/xexex.cpp:512-561).
//   4 vblank, line 256, control2 bit 11
//   5 object DMA end, control2 bit 6
//   6 line 0, control2 bit 5 (test mode)
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        { pend4, pend5, pend6 } <= 0;
        lvbl_l <= 1;
        dma_l  <= 0;
        IPLn   <= 3'b111;
    end else begin
        lvbl_l <= LVBL;
        dma_l  <= dma_bsy;
        if( !LVBL &&  lvbl_l && ctrl2[11] ) pend4 <= 1;
        if( !dma_bsy && dma_l && ctrl2[ 6] ) pend5 <= 1;
        if(  LVBL && !lvbl_l && ctrl2[ 5] ) pend6 <= 1;
        if( iack && A[3:1]==3'd4 ) pend4 <= 0;
        if( iack && A[3:1]==3'd5 ) pend5 <= 0;
        if( iack && A[3:1]==3'd6 ) pend6 <= 0;
        IPLn <= pend6 ? ~3'd6 : pend5 ? ~3'd5 : pend4 ? ~3'd4 : 3'b111;
    end
end

always @(posedge clk) HALTn <= dip_pause & ~rst;

jt5911 #(.SIMFILE("nvram.bin")) u_eeprom(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .sclk       ( ctrl2[2]  ),
    .sdi        ( ctrl2[0]  ),
    .sdo        ( eep_do    ),
    .rdy        ( eep_rdy   ),
    .scs        ( ctrl2[1]  ),
    .mem_addr   ( nv_addr   ),
    .mem_din    ( nv_din    ),
    .mem_we     ( nv_we     ),
    .mem_dout   ( nv_dout   ),
    .dump_clr   ( 1'b0      ),
    .dump_flag  (           )
);

jtframe_68kdtack_cen #(.W(6),.RECOVERY(1)) u_dtack(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cpu_cen    ( cpu_cen   ),
    .cpu_cenb   ( cpu_cenb  ),
    .bus_cs     ( bus_cs    ),
    .bus_busy   ( bus_busy  ),
    .bus_legit  ( 1'b0      ),
    .bus_ack    ( 1'b0      ),
    .ASn        ( ASn       ),
    .DSn        ({UDSn,LDSn}),
    .num        ( 5'd1      ),
    .den        ( 6'd3      ),  // 16 MHz from 48 MHz
    .DTACKn     ( DTACKn    ),
    .wait2      ( 1'b0      ),
    .wait3      ( 1'b0      ),
    .fave       (           ),
    .fworst     (           )
);

jtframe_m68k u_cpu(
    .clk        ( clk         ),
    .rst        ( rst         ),
    .RESETn     (             ),
    .cpu_cen    ( cpu_cen     ),
    .cpu_cenb   ( cpu_cenb    ),
    .eab        ( A           ),
    .iEdb       ( cpu_din     ),
    .oEdb       ( cpu_dout    ),
    .eRWn       ( RnW         ),
    .LDSn       ( LDSn        ),
    .UDSn       ( UDSn        ),
    .ASn        ( ASn         ),
    .VPAn       ( VPAn        ),
    .FC         ( FC          ),
    .BERRn      ( 1'b1        ),
    .HALTn      ( HALTn       ),
    .BRn        ( 1'b1        ),
    .BGACKn     ( 1'b1        ),
    .BGn        ( BGn         ),
    .DTACKn     ( cpu_dtackn  ),
    .IPLn       ( IPLn        )
);

endmodule
