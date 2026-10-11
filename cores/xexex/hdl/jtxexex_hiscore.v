/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Written by Paul Priest. */

// High scores in the NVRAM file. MAME's hiscore.dat for xexex names two work-RAM
// areas: 85000, 0x63 bytes, first byte 00 and last 1c once the game has written its
// default table; 80057, 3 bytes, first 00 and last 30. hiram, which jtframe saves and
// restores after the EEPROM, keeps them as 52 words: 85000-85063 in 0-49 and
// 80056-80059 in 50-51.
//
// Once the test passes on two frames running (the boot's RAM test never passes it),
// a hiram whose own sentinels are set is written into work RAM; otherwise work RAM is copied into hiram.
// From then on the CPU's writes to the areas are copied into hiram, so the file holds
// the current table whenever jtframe saves it. Work RAM is reached on the clocks the
// 68000 leaves it idle (ram_cs low), so the CPU never waits.

module jtxexex_hiscore(
    input             rst,
    input             clk,
    input             lvbl,
    // CPU side of work RAM
    input      [15:1] main_addr,
    input      [15:0] cpu_dout,
    input             ram_cs,
    input      [ 1:0] main_we,
    // work RAM port
    output     [15:1] wram_a,
    output     [15:0] wram_din,
    output     [ 1:0] wram_we,
    input      [15:0] wram_dout,
    // hiram port
    output reg [ 6:1] hi_addr,
    output reg [15:0] hi_din,
    output reg [ 1:0] hi_we,
    input      [15:0] hi_dout
);

localparam [15:1] R1 = 15'h2800,    // 85000
                  R2 = 15'h002b;    // 80056
localparam [ 5:0] NW = 6'd52;
localparam [ 3:0] WAIT=0, CHK=1, CHKRD=2, DECIDE=3, COPY=4, COPYRD=5, COPYWR=6, LIVE=7;

reg  [ 3:0] st;
reg  [ 5:0] idx, frames;
reg  [ 2:0] k;
reg  [ 1:0] passes;
reg  [15:0] w0, w49, w50, w51;
reg         restore, steal, swe_go, lvbl_l, rd_dly;
reg  [15:1] sa;
reg  [15:0] sd;
reg  [ 1:0] swe;

wire        idle   = !ram_cs;
wire        go     = steal && idle;
wire [ 5:0] last   = NW - 6'd1;

assign wram_a   = go ? sa  : main_addr;
assign wram_din = go ? sd  : cpu_dout;
assign wram_we  = go ? swe : main_we;

function [15:1] waddr(input [5:0] i);
    waddr = i < 6'd50 ? R1 + {9'd0, i} : R2 + {9'd0, i - 6'd50};
endfunction

// bytes of each word that belong to the areas: 85063 and 80056 do not
function [1:0] wmask(input [5:0] i);
    wmask = i == 6'd49 ? 2'b10 : i == 6'd50 ? 2'b01 : 2'b11;
endfunction

function sentinels(input [15:0] a0, a49, a50, a51);
    sentinels = a0[15:8]==8'h00 && a49[15:8]==8'h1c && a50[7:0]==8'h00 && a51[7:0]==8'h30;
endfunction

// the CPU's write into an area, as a hiram index
wire        in_r1 = main_addr >= R1 && main_addr < R1 + 15'd50;
wire        in_r2 = main_addr == R2 || main_addr == R2 + 15'd1;
wire [ 5:0] cpu_i = in_r1 ? main_addr[6:1] - R1[6:1] : { 5'b11001, main_addr[1] ^ R2[1] };

always @(posedge clk) begin
    if( rst ) begin
        st <= WAIT; frames <= 0; passes <= 0; steal <= 0; swe <= 0;
        hi_we <= 0; hi_addr <= 0; hi_din <= 0; restore <= 0; lvbl_l <= 0; rd_dly <= 0;
        idx <= 0; k <= 0;
    end else begin
        lvbl_l <= lvbl;
        hi_we  <= 0;
        rd_dly <= 0;
        if( go ) begin steal <= 0; swe <= 0; rd_dly <= 1; end
        case( st )
            WAIT: if( !lvbl && lvbl_l ) begin
                if( frames != 6'h3f ) frames <= frames + 6'd1;
                if( frames >= 6'd30 ) begin st <= CHK; k <= 0; end
            end
            // read the four sentinel words of work RAM
            CHK: if( !steal ) begin
                sa <= waddr( k==0 ? 6'd0 : k==1 ? 6'd49 : k==2 ? 6'd50 : 6'd51 );
                swe <= 0; steal <= 1; st <= CHKRD;
            end
            CHKRD: if( rd_dly ) begin
                case( k )
                    0: w0 <= wram_dout; 1: w49 <= wram_dout;
                    2: w50 <= wram_dout; default: w51 <= wram_dout;
                endcase
                k <= k + 3'd1;
                st <= k==3 ? DECIDE : CHK;
            end
            DECIDE: begin
                if( sentinels(w0, w49, w50, w51) ) begin
                    passes <= passes + 2'd1;
                    if( passes == 2'd1 ) begin
                        st <= COPY; idx <= 0; k <= 0;
                    end else st <= WAIT;
                end else begin
                    passes <= 0; st <= WAIT;
                end
            end
            // pass 0 (k==0): read hiram's sentinels to choose the direction;
            // then copy all 52 words one way
            COPY: begin
                hi_addr <= k==0 ? (idx==0 ? 6'd49 : 6'd51) : idx;
                st <= COPYRD;
            end
            COPYRD: begin
                st <= COPYWR;   // hiram's q is out a clock later
                if( k!=0 && !restore ) begin
                    sa <= waddr(idx); swe <= 0; steal <= 1;
                end
            end
            COPYWR: begin
                if( k==0 ) begin
                    if( idx==0 ) begin w49 <= hi_dout; idx <= 1; st <= COPY; end
                    else begin
                        restore <= w49[15:8]==8'h1c && hi_dout[7:0]==8'h30;
                        k <= 1; idx <= 0; st <= COPY;
                    end
                end else if( restore ) begin
                    if( !steal && !go ) begin
                        sa <= waddr(idx); sd <= hi_dout; swe <= wmask(idx); steal <= 1;
                    end
                    if( go ) begin
                        if( idx==last ) st <= LIVE; else begin idx <= idx+6'd1; st <= COPY; end
                    end
                end else if( rd_dly ) begin
                    hi_addr <= idx; hi_din <= wram_dout; hi_we <= 2'b11;
                    if( idx==last ) st <= LIVE; else begin idx <= idx+6'd1; st <= COPY; end
                end
            end
            LIVE: if( |main_we && (in_r1 || in_r2) ) begin
                hi_addr <= cpu_i; hi_din <= cpu_dout; hi_we <= main_we;
            end
            default: st <= WAIT;
        endcase
    end
end

endmodule
