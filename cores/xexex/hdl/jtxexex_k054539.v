/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright: Paul Priest */

// gx_k054539 on jtframe: its 32 KB RAM in BRAM, its sample ROM on a 32-bit
// SDRAM bus. gx_k054539 reads memory a 64-bit granule at a time through p_*,
// the ROM below granule RAM_G0 and the RAM from there; the CPU's 0x22d port
// reads a byte of either through m_*.

module jtxexex_k054539(
    input                rst,
    input                clk,       // 48 MHz: gx_k054539's timer assumes it
    input                cen_pcm,   // 18.432 MHz

    // Z80: rd and wr are the bus strobes while cs is set
    input                cs,
    input                rd,
    input                wr,
    input         [ 9:0] addr,
    input         [ 7:0] din,
    output reg    [ 7:0] dout,
    output               rd_ok,     // the read has its data: hold the Z80 until then
    output               timer,

    output reg    [21:2] rom_addr,
    output reg           rom_cs,
    input         [31:0] rom_data,
    input                rom_ok,

    output reg signed [15:0] left,
    output reg signed [15:0] right
);

localparam [23:0] PCM_MASK = 24'h3f_ffff;           // 3 MB of samples, mirrored as 4 MB
localparam [23:0] RAM_B0   = PCM_MASK + 24'd1;
localparam [20:0] RAM_G0   = RAM_B0[23:3];

// ---------------------------------------------------------------- sample strobe
reg  [8:0] smp_cnt;
reg        smp;

always @(posedge clk) begin
    smp <= 0;
    if( rst ) smp_cnt <= 0;
    else if( cen_pcm ) begin
        smp_cnt <= smp_cnt==9'd383 ? 9'd0 : smp_cnt + 9'd1;
        smp     <= smp_cnt==0;
    end
end

// ---------------------------------------------------------------- Z80 access
// one gx_k054539 access per bus cycle: on the strobe's leading edge
reg        strb_l, rd_done;
wire       strb = cs & (rd | wr);
wire       k_cs = strb & ~strb_l;
wire       k_ack;
wire [7:0] k_dout;

assign rd_ok = rd_done;

always @(posedge clk) begin
    strb_l <= strb;
    if( rst || !cs ) rd_done <= 0;
    else if( k_ack ) begin
        rd_done <= 1;
        dout    <= k_dout;
    end
end

// ---------------------------------------------------------------- gx_k054539
wire        m_req, m_we, m_ram, p_cs, r_req;
wire [21:0] m_addr;
wire [ 7:0] m_wdata;
wire [20:0] p_addr;
wire [12:0] r_word;
wire [15:0] r_data;
wire signed [25:0] out_l, out_r;
wire        out_v;
reg         m_ack, p_ok, r_ack;
reg  [ 7:0] m_rdata;
reg  [63:0] p_data;

gx_k054539 #(.CHIP(0)) u_chip(
    .clk        ( clk       ),
    .rst        ( rst       ),
    .cs         ( k_cs      ),
    .we         ( wr        ),
    .addr       ( {1'b0,addr} ),
    .din        ( din       ),
    .dout       ( k_dout    ),
    .ack        ( k_ack     ),
    .timer_out  ( timer     ),
    .m_req      ( m_req     ),
    .m_we       ( m_we      ),
    .m_ram      ( m_ram     ),
    .m_addr     ( m_addr    ),
    .m_wdata    ( m_wdata   ),
    .m_ack      ( m_ack     ),
    .m_rdata    ( m_rdata   ),
    .smp        ( smp       ),
    .pcm_mask   ( PCM_MASK  ),
    .p_cs       ( p_cs      ),
    .p_addr     ( p_addr    ),
    .p_ok       ( p_ok      ),
    .p_data     ( p_data    ),
    .out_l      ( out_l     ),
    .out_r      ( out_r     ),
    .out_v      ( out_v     ),
    .ovr        (           ),
    .r_req      ( r_req     ),
    .r_word     ( r_word    ),
    .r_data     ( r_data    ),
    .r_ack      ( r_ack     )
);

function signed [15:0] sat16( input signed [25:0] v ); // drops the 8 fraction bits
    sat16 = v[25:23]==3'b000 || v[25:23]==3'b111 ? v[23:8] :
            v[25] ? 16'sh8000 : 16'sh7fff;
endfunction

always @(posedge clk) begin
    if( rst ) begin
        left  <= 0;
        right <= 0;
    end else if( out_v ) begin
        left  <= sat16(out_l);
        right <= sat16(out_r);
    end
end

// ---------------------------------------------------------------- RAM
// eight byte lanes of 4096: port 0 serves p_* reads and r_* word writes,
// port 1 the CPU's m_* bytes
reg  [11:0] ra0;
reg  [ 7:0] we0;
reg  [63:0] wd0;
wire [63:0] q0, q1;
wire        m_ramwe = m_req & m_ram & m_we & ~m_ack;
wire [20:0] p_rel   = p_addr - RAM_G0;

genvar lane;
generate for( lane=0; lane<8; lane=lane+1 ) begin : g_ram
    jtframe_dual_ram #(.DW(8),.AW(12)) u_lane(
        .clk0   ( clk                   ),
        .data0  ( wd0[8*lane+:8]        ),
        .addr0  ( ra0                   ),
        .we0    ( we0[lane]             ),
        .q0     ( q0[8*lane+:8]         ),
        .clk1   ( clk                   ),
        .data1  ( m_wdata               ),
        .addr1  ( m_addr[14:3]          ),
        .we1    ( m_ramwe && m_addr[2:0]==lane ),
        .q1     ( q1[8*lane+:8]         )
    );
end endgenerate

always @* begin
    we0 = 0;
    wd0 = {4{r_data}};
    ra0 = r_req ? {1'b0, r_word[12:2]} : p_rel[11:0];
    if( r_req ) we0[{r_word[1:0],1'b0} +: 2] = 2'b11;
end

always @(posedge clk) r_ack <= r_req;

// ---------------------------------------------------------------- memory FSM
// ROM granules take two 32-bit reads; rom_cs drops for a clock around each
// address change so that rom_ok belongs to the new address
localparam IDLE=0, RAMRD=1, RAMLT=2, ROM0=3, ROM1=4, MROM=5, DROP=6;
reg [2:0] st;
reg       hi, wait1, srv_m;   // srv_m: serving m_*, else p_*

always @(posedge clk) begin
    m_ack <= 0;
    p_ok  <= 0;
    if( rst ) begin
        st     <= IDLE;
        rom_cs <= 0;
        wait1  <= 0;
    end else begin
        wait1 <= 0;
        case( st )
            IDLE: begin
                if( m_req && m_ram ) begin
                    st <= RAMLT; srv_m <= 1;        // m_* RAM: port 1, its address already settled
                end else if( p_cs && p_addr >= RAM_G0 ) begin
                    st <= RAMRD; srv_m <= 0;
                end else if( p_cs ) begin
                    srv_m    <= 0;
                    rom_addr <= {p_addr[18:0], 1'b0};  // ROM granules are below RAM_G0
                    rom_cs   <= 1; wait1 <= 1; hi <= 0;
                    st       <= ROM0;
                end else if( m_req ) begin
                    srv_m    <= 1;
                    rom_addr <= m_addr[21:2];
                    rom_cs   <= 1; wait1 <= 1;
                    st       <= MROM;
                end
            end
            RAMRD: st <= RAMLT;                     // p_* RAM: port 0 address settles
            RAMLT: begin
                if( srv_m ) begin
                    m_rdata <= q1[8*m_addr[2:0]+:8];
                    m_ack   <= 1;
                end else begin
                    p_data <= q0;
                    p_ok   <= 1;
                end
                st <= DROP;
            end
            ROM0: if( !wait1 && rom_ok ) begin
                if( !hi ) begin
                    p_data[31:0] <= rom_data;
                    rom_cs   <= 0;
                    hi       <= 1;
                    st       <= ROM1;
                end else begin
                    p_data[63:32] <= rom_data;
                    rom_cs <= 0;
                    p_ok   <= 1;
                    st     <= DROP;
                end
            end
            ROM1: begin
                rom_addr[2] <= 1;
                rom_cs      <= 1; wait1 <= 1;
                st          <= ROM0;
            end
            MROM: if( !wait1 && rom_ok ) begin
                m_rdata <= rom_data[8*m_addr[1:0]+:8];
                m_ack   <= 1;
                rom_cs  <= 0;
                st      <= DROP;
            end
            DROP: if( srv_m ? !m_req : !p_cs ) st <= IDLE; // the served request falls
            default: st <= IDLE;
        endcase
    end
end

endmodule
