/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Derived from cores/rungun/hdl/jtrungun_sound.v: one K054539, through
 * jtxexex_k054539, and the YM2151. Z80 map: doc/xexex.cpp:610-619.
 * Modified by Paul Priest. */

module jtxexex_sound(
    input           rst,
    input           clk,
    input           cen_8,
    input           cen_pcm,
    input           cen_fm,     // 4 MHz
    input           cen_fm2,    // 2 MHz

    input           pair_we,
    // communication with main CPU
    input   [ 7:0]  main_dout,
    output  [ 7:0]  pair_dout,
    input   [ 4:1]  main_addr,

    input           snd_irq,
    // ROM
    output  [16:0]  rom_addr,
    output  reg     rom_cs,
    input   [ 7:0]  rom_data,
    input           rom_ok,
    // PCM ROM
    output   [21:2] pcm_addr,
    input    [31:0] pcm_data,
    output          pcm_cs,
    input           pcm_ok,
    // Sound output
    output signed [15:0] k539_l, k539_r,
    output signed [15:0] fm_l, fm_r,
    // Debug
    input    [ 7:0] debug_bus,
    output   [ 7:0] st_dout,
    output reg [7:0] reply      // the last byte the Z80 wrote to K054321 latch 2 (debug)
);
/* verilator tracing_off */
wire        [ 7:0]  cpu_dout, cpu_din, ram_dout, ctl, k39_dout, latch_dout, fm_dout;
wire        [ 3:0]  rom_hi, bank;
wire        [15:0]  A;
wire                m1_n, mreq_n, rd_n, wr_n, iorq_n, rfsh_n,
                    cpu_cen, latch_we, tima, k39_ok, int_n;
reg                 ram_cs, k21_cs, k39_cs, fm_cs, mem_acc, bank_cs;

assign rom_hi   = A[15] ? bank : {3'd0, A[14]};
assign rom_addr = {rom_hi[2:0], A[13:0]};
assign bank     = ctl[3:0];
// debug view: a blink per 2^19 Z80 memory accesses, a blink per 8 writes to the
// K054539 and YM2151, a toggle per sound command, K054539 and YM2151 output nonzero
// (held 2^22 clocks, about 90 ms), and the Z80's A[15:13]
reg  [18:0] zbus;
reg  [ 3:0] chip_wr;
reg  [21:0] pcm_hold, fm_hold;
reg         wr_l, mreq_l, cmd_tog, irq_l;
assign st_dout  = { zbus[18], chip_wr[3], cmd_tog, |pcm_hold, |fm_hold, A[15:13] };
always @(posedge clk) if( latch_we && A[1:0]==0 ) reply <= cpu_dout;
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        { zbus, chip_wr, cmd_tog } <= 0;
        { wr_l, mreq_l, irq_l } <= 3'b110;
        pcm_hold <= 0;
        fm_hold  <= 0;
    end else begin
        wr_l   <= wr_n;
        mreq_l <= mreq_n;
        irq_l  <= snd_irq;
        if( !wr_n && wr_l && (k39_cs || fm_cs) ) chip_wr <= chip_wr + 4'd1;
        if( !mreq_n && mreq_l ) zbus <= zbus + 19'd1;
        if( snd_irq && !irq_l ) cmd_tog <= ~cmd_tog;
        pcm_hold <= (k539_l != 0 || k539_r != 0) ? {22{1'b1}} : pcm_hold - (pcm_hold != 0 ? 22'd1 : 22'd0);
        fm_hold  <= (fm_l   != 0 || fm_r   != 0) ? {22{1'b1}} : fm_hold  - (fm_hold  != 0 ? 22'd1 : 22'd0);
    end
end
assign latch_we = k21_cs & ~wr_n;

always @(*) begin
    mem_acc =!mreq_n  && rfsh_n;
    rom_cs  = mem_acc &&(!A[15] || !A[14]);
    ram_cs  = mem_acc &&  A[15:13]==3'b110;     // Cxxx
    k39_cs  = mem_acc &&  A[15:10]==6'b1110_00; // E0xx-E3xx
    fm_cs   = mem_acc &&  A[15:10]==6'b1110_11; // ECxx
    k21_cs  = mem_acc &&  A[15:10]==6'b1111_00; // F0xx
    bank_cs = mem_acc &&  A[15:10]==6'b1111_10; // F8xx
end

jtframe_8bit_reg u_reg(rst,clk,wr_n,cpu_dout,bank_cs,ctl);

jt054321 u_54321(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .maddr      ( main_addr ),
    .mdout      ( main_dout ),
    .mdin       ( pair_dout ),
    .mwe        ( pair_we   ),

    .saddr      ( A[1:0]    ),
    .sdout      ( cpu_dout  ),
    .sdin       ( latch_dout),
    .swe        ( latch_we  ),

    .snd_on     ( snd_irq   ),
    .siorq_n    ( iorq_n    ),
    .int_n      ( int_n     )
);

`ifndef NOSOUND
wire k39_rd = k39_cs & ~rd_n;

assign cpu_din  = rom_cs  ? rom_data   :
                  ram_cs  ? ram_dout   :
                  k39_cs  ? k39_dout   :
                  fm_cs   ? fm_dout    :
                  k21_cs  ? latch_dout : 8'h0;

// K054539 reads hold the Z80 through the ROM wait
jtframe_sysz80 #(.RAM_AW(13)) u_cpu(
    .rst_n      ( ~rst      ),
    .clk        ( clk       ),
    .cen        ( cen_8     ),
    .cpu_cen    ( cpu_cen   ),
    .int_n      ( int_n     ),
    .nmi_n      ( 1'b1      ), // xexex.cpp leaves the K054539 timer unconnected
    .busrq_n    ( 1'b1      ),
    .m1_n       ( m1_n      ),
    .mreq_n     ( mreq_n    ),
    .iorq_n     ( iorq_n    ),
    .rd_n       ( rd_n      ),
    .wr_n       ( wr_n      ),
    .rfsh_n     ( rfsh_n    ),
    .halt_n     (           ),
    .busak_n    (           ),
    .A          ( A         ),
    .cpu_din    ( cpu_din   ),
    .cpu_dout   ( cpu_dout  ),
    .ram_dout   ( ram_dout  ),
    .ram_cs     ( ram_cs    ),
    .rom_cs     ( rom_cs | k39_rd ),
    .rom_ok     ( rom_cs ? rom_ok : k39_ok )
);

/* verilator tracing_on */
jtxexex_k054539 u_k054539(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen_pcm    ( cen_pcm   ),
    .cs         ( k39_cs    ),
    .rd         ( ~rd_n     ),
    .wr         ( ~wr_n     ),
    .addr       ( A[9:0]    ),
    .din        ( cpu_dout  ),
    .dout       ( k39_dout  ),
    .rd_ok      ( k39_ok    ),
    .timer      ( tima      ),
    .rom_addr   ( pcm_addr  ),
    .rom_cs     ( pcm_cs    ),
    .rom_data   ( pcm_data  ),
    .rom_ok     ( pcm_ok    ),
    .left       ( k539_l    ),
    .right      ( k539_r    )
);

// xexex.cpp gives the YM2151 no IRQ handler
jt51 u_jt51(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen_fm    ),
    .cen_p1     ( cen_fm2   ),
    .cs_n       ( ~fm_cs    ),
    .wr_n       ( wr_n      ),
    .a0         ( A[0]      ),
    .din        ( cpu_dout  ),
    .dout       ( fm_dout   ),
    .ct1        (           ),
    .ct2        (           ),
    .irq_n      (           ),
    .sample     (           ),
    .left       (           ),
    .right      (           ),
    .xleft      ( fm_l      ),
    .xright     ( fm_r      )
);

`else
assign k539_l=0, k539_r=0, fm_l=0, fm_r=0, fm_dout=0,
       m1_n=1, mreq_n=1, rfsh_n=1, wr_n=1, rd_n=1, A=0, cpu_dout=0, iorq_n=1, tima=0,
       pcm_cs=0, pcm_addr=0, ram_dout=0, k39_dout=0, k39_ok=0;
`endif
endmodule
