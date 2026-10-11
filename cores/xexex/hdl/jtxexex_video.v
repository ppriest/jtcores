/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Rafael Eduardo Paiva Feener. Copyright: Jose Tejada Gomez
 * Version: 1.0
 * Date: 17-6-2026 */

module jtxexex_video(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,

    // Base Video
    output            lhbl,
    output            lvbl,
    output            hs,
    output            vs,

    output            tile_irqn,
    output            tile_nmin,

    // Object DMA
    input      [13:1] oram_addr,
    input      [ 1:0] oram_we,
    // CPU interface
    input      [16:1] cpu_addr,
    input      [ 1:0] cpu_dsn,
    input      [15:0] cpu_dout,
    input             cpu_we,

    input             pcu_cs,
    input             col_cs,
    input             pal_cs,
    output     [15:0] pal_dout,
    output     [15:0] tilesys_dout,

    input             cco_cs,
    input             rw,
    input      [ 3:0] vtimer_addr,
    output     [ 7:0] vtimer_mmr,

    output            dma_bsy,
    output     [15:0] objsys_dout,
    input             objsys_cs,
    input             objreg_cs,
    input             objcha_n,
    input             alpha_off,  // control2 bit 9

    input             scrreg_cs,
    input             scr_cs,
    input             blnk_sel,

    output reg        vdtac,
    input             tilesys_cs,
    output            rst8,     // reset signal at 8th frame

    // control
    input             tilerom_cs, // 190000-191fff read
    output     [15:0] tilerom_dout,
    output            tilerom_ok,
    // K053250
    input             lvcram_cs,
    input             lvcreg_cs,
    input             lvcrom_cs,
    output     [15:0] lvc_dout,
    output            lvcrom_ok,
    output     [18:2] lvc_addr,
    output            lvc_cs,
    input      [31:0] lvc_data,
    input             lvc_ok,
    input             flip,     // the frame turned 180 degrees (OSD)
    output            int1,
    // Tile ROMs
    output     [20:2] lyrf_addr,
    output     [20:2] lyra_addr,
    output     [20:2] lyrb_addr,
    output     [22:2] lyro_addr,

    output            lyrf_cs,
    output            lyra_cs,
    output            lyrb_cs,
    output            lyro_cs,

    input             lyrf_ok,
    input             lyra_ok,
    input             lyrb_ok,
    input             lyro_ok,

    input      [31:0] lyrf_data,
    input      [31:0] lyra_data,
    input      [31:0] lyrb_data,
    input      [31:0] lyro_data,

    // Color
    input      [ 2:0] dim,
    input             dimmod,
    input             dimpol,

    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,

    // Debug
    input      [15:0] ioctl_addr,
    input             ioctl_ram,
    output     [ 7:0] ioctl_din,

    input      [ 3:0] gfx_en,
    input      [ 7:0] debug_bus,
    output     [ 7:0] st_dout
);

wire [12:0] ocode;
wire [ 8:0] lyr0_pxl, lyr1_pxl, lyr2_pxl, lyr3_pxl;
wire        ccu_lhbl, ccu_lvbl;
wire [ 8:0] ynow;
// the object chip scans at HS for the line after next (it draws during the next line
// and shows the buffer a line later), numbered as jtframe's Konami timers
// (0x100 + line); outside the screen it gets 0x0ff, which it does not scan
wire [ 8:0] ynext    = ynow + 9'd2;
wire [ 8:0] xlast, ylast, obj_y = flip ? ylast - ynext : ynext;
wire [ 8:0] obj_vdump = ynext[8] || ynext > ylast ? 9'h0ff : { 1'b1, obj_y[7:0] };
// flipped, the object line buffer is read right to left: screen pixel x reads what
// pixel xlast-x read, at hdump xlast + 2*hvis - hdump (hvis: hdump of pixel 0)
reg  [ 8:0] hvis;
wire [ 8:0] obj_hdump;
reg  [ 8:0] hdump, vdump;

wire [ 8:0] vrender, vrender1, lyro_pxl, lvc_pxl, rx;
wire [ 7:0] dump_scr, st_scr,
            dump_obj, scr_mmr,  obj_mmr, dump_other,
            dump_pal, opal,     cpu_d8, pal_mmr;
wire [ 4:0] obj_prio;
wire [ 1:0] shadow;
wire [ 3:0] obj_amsb;
wire        nc, obj_nmin,
            lyro_blnk_n, ormrd,    pre_vdtac,   cpu_weg;

assign cpu_weg    = cpu_we && cpu_dsn!=3;
assign cpu_d8     = cpu_dout[7:0];
assign dump_other = {2'd0,dimpol, dimmod, 1'b0, dim};

jtriders_dump #(.FULLRAM(1)) u_dump(
    .clk            ( clk             ),
    .dump_scr       ( dump_scr        ),
    .dump_obj       ( dump_obj        ),
    .dump_pal       ( dump_pal        ),
    .pal_mmr        ( pal_mmr         ),
    .scr_mmr        ( scr_mmr         ),
    .obj_mmr        ( obj_mmr         ),
    .psac_mmr       ( 8'b0            ),
    .other          ( dump_other      ),

    .ioctl_addr     ( ioctl_addr      ),
    .ioctl_din      ( ioctl_din       ),
    .obj_amsb       ( obj_amsb        ),
    .part_addr      (                 ),

    .debug_bus      ( debug_bus       ),
    .st_scr         ( st_scr          ),
    .st_dout        ( st_dout         )
);

always @(posedge clk) vdtac <= pre_vdtac; // delay, since cpu_din also delayed

// tile ROM readback (k056832 rom_word_r): byte 0x2000 * bank + 2 * offset, high byte first
wire [ 7:0] rom_bank;
assign lyrf_addr    = { rom_bank, cpu_addr[12:2] };
assign lyrf_cs      = tilerom_cs;
assign tilerom_ok   = lyrf_ok;
assign tilerom_dout = cpu_addr[1] ? { lyrf_data[23:16], lyrf_data[31:24] }
                                  : { lyrf_data[ 7: 0], lyrf_data[15: 8] };

// video timer
jtk053252 u_k053252(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( pxl_cen       ),


    .cs         ( cco_cs        ), // CCO
    .addr       ( vtimer_addr   ),
    .rnw        ( rw            ), // R/W (CPU + prot)
    .din        ( cpu_dout[7:0] ),
    .dout       ( vtimer_mmr    ),

    .hs         ( hs            ),
    .vs         ( vs            ),
    .lhbl       ( ccu_lhbl      ),
    .lhbs       (               ),
    .lvbl       ( ccu_lvbl      ),
    .hld        (               ),
    .vld        (               ),
    // unused
    .vldi       ( 1'b1          ),
    .hldi       ( 1'b1          ),
    .sel        ( 3'd0          ),
    .int1       ( int1          ),
    .int2       (               ),
    // IOCTL dump
    .ioctl_addr ( ioctl_addr[3:0]),
    .ioctl_din  ( /*ccu_mmr*/       )
);

// line and pixel counters, for the object chip
// (on the syncs' rising edges: HS lasts several pixels)
reg [2:0] frame_cnt;
reg       rst8_r, hs_l, vs_l;
assign rst8 = rst8_r;
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        hdump <= 0; vdump <= 0; frame_cnt <= 0; rst8_r <= 0; hs_l <= 0; vs_l <= 0;
    end else if( pxl_cen ) begin
        hs_l  <= hs;
        hdump <= hs && !hs_l ? 9'd0 : hdump + 9'd1;
        if( hs && !hs_l ) begin
            vs_l  <= vs;
            vdump <= vs && !vs_l ? 9'd0 : vdump + 9'd1;
            if( vs && !vs_l ) begin
                frame_cnt <= frame_cnt + 3'd1;
                rst8_r    <= &frame_cnt;
            end
        end
    end
end
reg ccu_lhbl_l;
always @(posedge clk) if( pxl_cen ) begin
    ccu_lhbl_l <= ccu_lhbl;
    if( ccu_lhbl && !ccu_lhbl_l ) hvis <= hdump;
end
assign obj_hdump = flip ? xlast + { hvis[7:0], 1'b0 } - hdump : hdump;
assign vrender   = vdump;
assign vrender1  = vdump + 9'd1;
assign tile_irqn = 1;
assign tile_nmin = 1;
assign pre_vdtac = 1;
assign dump_scr  = 0;
assign scr_mmr   = 0;

/* verilator tracing_on */
jtxexex_tilemap u_tilemap(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),
    .lhbl       ( ccu_lhbl  ),
    .lvbl       ( ccu_lvbl  ),
    .vdump      ( vdump     ),

    .reg_cs     ( scrreg_cs ),
    .vram_cs    ( scr_cs    ),
    .cpu_we     ( cpu_weg   ),
    .cpu_addr   ( cpu_addr[13:1] ),
    .cpu_dout   ( cpu_dout  ),
    .cpu_dsn    ( cpu_dsn   ),
    .vram_dout  ( tilesys_dout ),

    .rom0_addr  ( lyra_addr ),
    .rom0_cs    ( lyra_cs   ),
    .rom0_data  ( lyra_data ),
    .rom0_ok    ( lyra_ok   ),
    .rom1_addr  ( lyrb_addr ),
    .rom1_cs    ( lyrb_cs   ),
    .rom1_data  ( lyrb_data ),
    .rom1_ok    ( lyrb_ok   ),

    .lyr0_pxl   ( lyr0_pxl  ),
    .lyr1_pxl   ( lyr1_pxl  ),
    .lyr2_pxl   ( lyr2_pxl  ),
    .lyr3_pxl   ( lyr3_pxl  ),
    .ynow       ( ynow      ),
    .rx         ( rx        ),
    .xlast      ( xlast     ),
    .ylast      ( ylast     ),
    .flip       ( flip      ),
    .rom_bank   ( rom_bank  ),
    .st_dout    ( st_scr    )
);

/* verilator tracing_on */
wire [ 4:0] lyro_pri;
wire [ 3:0] ommra;
wire [14:1] orama;

assign ommra = {cpu_addr[3:1],cpu_dsn[1]};
assign orama = cpu_addr[14:1];      // 32 kB, mirrored at 098000

localparam [9:0] OVOFFSET=10'h120;

// HFIX off: flipped, the line buffer is read right to left, which HFIX's count-up
// would override; this hdump does not wrap inside the visible line
jtsimson_obj #(.RAMW(14),.SHADOW(1),.LARGE_DMA(1),.ZSORT8(1),.NO_LEFT_WRAP(1),.ROM_WINDOW(1),.HFIX(0),.VTOP(9'h0ff),.BOTTOM(9'h1ff),.HOFFSET(10'd7)) u_obj(    // sprite logic
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),
    .pxl2_cen   ( pxl2_cen  ),
    .simson     ( 1'b0      ),
    .ln_done    (           ),

    .voffset    ( OVOFFSET  ),
    // Base Video (inputs)
    .hs         ( hs        ),
    .lvbl       ( ccu_lvbl  ),
    .hdump      ( obj_hdump ),
    .vdump      ( obj_vdump ),
    // CPU interface
    .ram_cs     ( objsys_cs ),
    .ram_addr   ( orama     ),
    .ram_din    ( cpu_dout  ),
    .ram_we     ( oram_we   ),
    .cpu_din    (objsys_dout),

    .reg_cs     ( objreg_cs ),
    .mmr_addr   ( ommra     ),
    .mmr_din    ( cpu_dout  ),
    .mmr_we     ( cpu_we    ), // active on ~dsn[1] but ignores cpu_dout[15:8]
    .mmr_dsn    ( cpu_dsn   ),

    .dma_bsy    ( dma_bsy   ),
    // ROM
    .rom_addr   ( lyro_addr ),
    .rom_data   ( lyro_data ),
    .rom_ok     ( lyro_ok   ),
    .rom_cs     ( lyro_cs   ),
    .objcha_n   ( objcha_n  ),
    // pixel output
    .pxl        ( lyro_pxl  ),
    .shd        ( shadow    ),
    .prio       ( lyro_pri  ),
    // Debug
    .ioctl_ram  ( ioctl_ram ),
    .ioctl_addr ( {obj_amsb[1:0],ioctl_addr[11:0]} ),
    .dump_ram   ( dump_obj  ),
    .dump_reg   ( obj_mmr   ),
    .gfx_en     ( gfx_en    ),
    .debug_bus  ( debug_bus )
);

/* verilator tracing_on */
jtxexex_lvc u_lvc(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),
    .lhbl       ( ccu_lhbl  ),
    .ynow       ( ynow      ),
    .rx         ( rx        ),
    .xlast      ( xlast     ),
    .ylast      ( ylast     ),
    .flip       ( flip      ),

    .ram_cs     ( lvcram_cs ),
    .reg_cs     ( lvcreg_cs ),
    .rom_cs     ( lvcrom_cs ),
    .cpu_we     ( cpu_weg   ),
    .cpu_addr   ( cpu_addr[12:1] ),
    .cpu_dout   ( cpu_dout  ),
    .cpu_dsn    ( cpu_dsn   ),
    .cpu_din    ( lvc_dout  ),
    .rom_ok_cpu ( lvcrom_ok ),

    .rom_addr   ( lvc_addr  ),
    .rom_cs_o   ( lvc_cs    ),
    .rom_data   ( lvc_data  ),
    .rom_ok     ( lvc_ok    ),

    .pxl        ( lvc_pxl   )
);

jtxexex_colmix u_colmix(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),

    .lhbl       ( ccu_lhbl  ),
    .lvbl       ( ccu_lvbl  ),
    .lhbl_dly   ( lhbl      ),
    .lvbl_dly   ( lvbl      ),

    .pcu_cs     ( pcu_cs    ),
    .reg_cs     ( col_cs    ),
    .pal_cs     ( pal_cs    ),
    .cpu_we     ( cpu_weg   ),
    .cpu_dout   ( cpu_dout  ),
    .cpu_dsn    ( cpu_dsn   ),
    .cpu_addr   (cpu_addr[12:1]),
    .cpu_din    ( pal_dout  ),
    .alpha_off  ( alpha_off ),

    .lyr0_pxl   ( lyr0_pxl  ),
    .lyr1_pxl   ( lyr1_pxl  ),
    .lyr2_pxl   ( lyr2_pxl  ),
    .lyr3_pxl   ( lyr3_pxl  ),
    .lyro_pxl   ( lyro_pxl  ),
    .lvc_pxl    ( lvc_pxl   ),
    .lyro_pri   ( lyro_pri  ),
    .shadow     ( shadow    ),

    .red        ( red       ),
    .green      ( green     ),
    .blue       ( blue      ),

    .ioctl_addr ( ioctl_addr[11:0]),
    .ioctl_ram  ( ioctl_ram ),
    .ioctl_din  ( dump_pal  ),
    .dump_mmr   ( pal_mmr   ),
    .debug_bus  ( debug_bus )
);

endmodule
