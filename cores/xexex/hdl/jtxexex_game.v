/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Rafael Eduardo Paiva Feener. Copyright: Jose Tejada Gomez
 * Version: 1.0
 * Date: 17-6-2026 */

module jtxexex_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

/* verilator tracing_off */
wire        snd_irq, rst8, dma_bsy,
            pal_cs, cpu_we, tilesys_cs, objsys_cs, pcu_cs, col_cs, objcha_n,
            cpu_rnw, vdtac, tile_irqn, tile_nmin,
            objreg_cs, scrreg_cs, scr_cs, pair_we, cco_cs, int1,
            alpha_off, nc;
wire [ 1:0] oram_we;
wire [ 7:0] vtimer_mmr;
wire [15:0] pal_dout, oram_dout;
wire [ 7:0] snd_reply, st_where;
wire        ram_cs;
wire [ 1:0] main_ram_we, ram_dsn;
wire [15:0] cpu_dout;
wire [15:0] video_dumpa;
reg  [ 7:0] debug_mux;
// reg  [ 2:0] game_id;
wire [15:0] tilesys_dout, tilerom_dout, lvc_dout;
wire        tilerom_cs, tilerom_ok, lvcram_cs, lvcreg_cs, lvcrom_cs, lvcrom_ok;
wire [ 7:0] obj_dout, snd_latch, pair_dout,
            st_main, st_video, st_snd;
// wire [ 1:0] oram_we;
wire [ 3:0] vtimer_addr;

assign debug_view = debug_mux;
assign video_dumpa= ioctl_addr[15:0]-16'h100; // subtract the EEPROM and hiram
assign vtimer_addr= main_addr[4:1];

// debug_bus[7:6]: 0 where the 68000 is (jtxexex_main st_where), 1 the interrupt path
// (st_dout) with the sound-command toggle in bit 0, 2 the Z80's last reply (K054321
// latch 2), 3 sound CPU.
always @(posedge clk) begin
    case( debug_bus[7:6] )
        2'd0:    debug_mux <= st_where;
        2'd1:    debug_mux <= { st_main[7:1], st_snd[5] };
        2'd2:    debug_mux <= snd_reply;
        default: debug_mux <= st_snd;
    endcase
end

/* verilator tracing_on */
jtxexex_main u_main(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .cen_16         ( cen_16        ),
    .LVBL           ( LVBL          ),
    .dma_bsy        ( dma_bsy       ),

    .main_addr      ( main_addr     ),
    .ram_dsn        ( ram_dsn       ),
    .cpu_dout       ( cpu_dout      ),
    .cpu_we         ( cpu_we        ),
    // SDRAM
    .rom_cs         ( main_cs       ),
    .rom_data       ( main_data     ),
    .rom_ok         ( main_ok       ),
    .ram_cs         ( ram_cs        ),
    .ram_dout       ( ram_data      ),
    .ram_we         ( main_ram_we   ),
    // video chips
    .scrreg_cs      ( scrreg_cs     ),
    .tilesys_cs     ( tilesys_cs    ),
    .scr_cs         ( scr_cs        ),
    .tilesys_dout   ( tilesys_dout  ),
    .objreg_cs      ( objreg_cs     ),
    .obj_cs         ( objsys_cs     ),
    .oram_we        ( oram_we       ),
    .oram_dout      ( oram_dout     ),
    .objcha_n       ( objcha_n      ),
    .col_cs         ( col_cs        ),
    .pcu_cs         ( pcu_cs        ),
    .pal_cs         ( pal_cs        ),
    .pal_dout       ( pal_dout      ),
    .tilerom_cs     ( tilerom_cs    ),
    .tilerom_dout   ( tilerom_dout  ),
    .tilerom_ok     ( tilerom_ok    ),
    .lvcram_cs      ( lvcram_cs     ),
    .lvcreg_cs      ( lvcreg_cs     ),
    .lvcrom_cs      ( lvcrom_cs     ),
    .lvc_dout       ( lvc_dout      ),
    .lvcrom_ok      ( lvcrom_ok     ),
    .cco_cs         ( cco_cs        ),
    .vtimer_mmr     ( vtimer_mmr    ),
    .alpha_off      ( alpha_off     ),
    // sound
    .sndon          ( snd_irq       ),
    .pair_we        ( pair_we       ),
    .pair_dout      ( pair_dout     ),
    // EEPROM
    .nv_addr        ( nvram_addr    ),
    .nv_dout        ( nvram_dout    ),
    .nv_din         ( nvram_din     ),
    .nv_we          ( nvram_we      ),
    // cabinet
    .joystick1      ( joystick1     ),
    .joystick2      ( joystick2     ),
    .cab_1p         ( cab_1p        ),
    .coin           ( coin          ),
    .service        ( {4{service}}  ),
    .dip_pause      ( dip_pause     ),
    .dip_test       ( dip_test      ),
    .st_dout        ( st_main       ),
    .st_where       ( st_where      ),
    .debug_bus      ( debug_bus     )
);


/* verilator tracing_on */
jtxexex_hiscore u_hiscore(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .lvbl       ( LVBL          ),
    .main_addr  ( main_addr[15:1] ),
    .cpu_dout   ( cpu_dout      ),
    .ram_cs     ( ram_cs        ),
    .main_we    ( main_ram_we   ),
    .wram_a     ( wram_a        ),
    .wram_din   ( wram_din      ),
    .wram_we    ( ram_we        ),
    .wram_dout  ( ram_data      ),
    .hi_addr    ( hiram_addr    ),
    .hi_din     ( hiram_din     ),
    .hi_we      ( hiram_we      ),
    .hi_dout    ( hiram_dout    )
);

jtxexex_video u_video (
    .rst            ( rst           ),
    .rst8           ( rst8          ),
    .clk            ( clk           ),
    .pxl_cen        ( pxl_cen       ),
    .pxl2_cen       ( pxl2_cen      ),

    .tile_irqn      ( tile_irqn     ),
    .tile_nmin      (               ),

    .lhbl           ( LHBL          ),
    .lvbl           ( LVBL          ),
    .hs             ( HS            ),
    .vs             ( VS            ),
    .flip           ( ~dip_flip     ), // dip_flip is the DIP level: 1 with the OSD option Off
    // GFX - CPU interface
    .cpu_we         ( cpu_we        ),
    .cpu_addr       (main_addr[16:1]),
    .cpu_dsn        ( ram_dsn       ),
    .cpu_dout       ( cpu_dout      ),

    // Object DMA
    .oram_we        ( oram_we       ),
    .oram_addr      ( 13'd0         ), // unused by jtxexex_video
    .dma_bsy        ( dma_bsy       ),

    .objsys_cs      ( objsys_cs     ),
    .objreg_cs      ( objreg_cs     ),
    .objcha_n       ( objcha_n      ),
    .alpha_off       ( alpha_off      ),
    .tilesys_cs     ( tilesys_cs    ),
    .scr_cs         ( scr_cs        ),
    .scrreg_cs      ( scrreg_cs     ),
    .blnk_sel       ( 1'b0          ), // moo's register bit
    .pal_cs         ( pal_cs        ),
    .pcu_cs         ( pcu_cs        ),
    .col_cs         ( col_cs        ),
    .vdtac          ( vdtac         ),
    .tilesys_dout   ( tilesys_dout  ),
    .objsys_dout    ( oram_dout     ),
    .pal_dout       ( pal_dout      ),
    .tilerom_cs     ( tilerom_cs    ),
    .tilerom_dout   ( tilerom_dout  ),
    .tilerom_ok     ( tilerom_ok    ),
    .lvcram_cs      ( lvcram_cs     ),
    .lvcreg_cs      ( lvcreg_cs     ),
    .lvcrom_cs      ( lvcrom_cs     ),
    .lvc_dout       ( lvc_dout      ),
    .lvcrom_ok      ( lvcrom_ok     ),
    .lvc_addr       ( lvc_addr      ),
    .lvc_cs         ( lvc_cs        ),
    .lvc_data       ( lvc_data      ),
    .lvc_ok         ( lvc_ok        ),

    .int1           ( int1          ),
    .cco_cs         ( cco_cs        ),
    .rw             ( ~cpu_we       ),
    .vtimer_mmr     ( vtimer_mmr    ),
    .vtimer_addr    ( vtimer_addr   ),
    // SDRAM
    .lyra_addr      ( lyra_addr     ),
    .lyrb_addr      ( lyrb_addr     ),
    .lyrf_addr      ( lyrf_addr     ),
    .lyro_addr      ( lyro_addr     ),
    .lyra_data      ( lyra_data     ),
    .lyrb_data      ( lyrb_data     ),
    .lyro_data      ( lyro_data     ),
    .lyrf_data      ( lyrf_data     ),
    .lyrf_cs        ( lyrf_cs       ),
    .lyra_cs        ( lyra_cs       ),
    .lyrb_cs        ( lyrb_cs       ),
    .lyro_cs        ( lyro_cs       ),
    .lyrf_ok        ( lyrf_ok       ),
    .lyra_ok        ( lyra_ok       ),
    .lyrb_ok        ( lyrb_ok       ),
    .lyro_ok        ( lyro_ok       ),
    // brightness
    .dim            (  3'b0         ),
    .dimmod         (  1'b0         ),
    .dimpol         (  1'b0         ),
    // pixels
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .ioctl_addr     ( video_dumpa   ),
    .ioctl_din      ( ioctl_din     ),
    .ioctl_ram      ( ioctl_ram     ),
    .gfx_en         ( gfx_en        ),
    .st_dout        ( st_video      )
);

/* verilator tracing_on */
jtxexex_sound u_sound(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .cen_8          ( cen_8         ),
    .cen_pcm        ( cen_pcm       ),
    .cen_fm         ( cen_4         ),
    .cen_fm2        ( cen_2         ),

    // communication with main CPU
    .main_dout      ( cpu_dout[7:0]  ),
    .pair_dout      ( pair_dout     ),
    .main_addr      ( main_addr[4:1]),
    .pair_we        ( pair_we       ),

    .snd_irq        ( snd_irq       ),
    // ROM
    .rom_addr       ( snd_addr      ),
    .rom_cs         ( snd_cs        ),
    .rom_data       ( snd_data      ),
    .rom_ok         ( snd_ok        ),
    // PCM ROM
    .pcm_addr       ( pcm_addr      ),
    .pcm_data       ( pcm_data      ),
    .pcm_cs         ( pcm_cs        ),
    .pcm_ok         ( pcm_ok        ),
    // Sound output
    .k539_l         ( k539_l        ),
    .k539_r         ( k539_r        ),
    .fm_l           ( fm_l          ),
    .fm_r           ( fm_r          ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .st_dout        ( st_snd        ),
    .reply          ( snd_reply     )
);
endmodule
