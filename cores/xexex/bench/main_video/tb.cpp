// mainvid (jtxexex_main and the real jtxexex_video) from reset. As main_boot, but palette,
// tile and sprite RAM, the K053252 timing and the object DMA are the RTL's own, so the
// boot's RAM tests read back what the core's RAMs hold. Program ROM, work RAM, EEPROM and
// the K054321 replay are main_boot's. Writes the same trace for scripts/compare_trace.py.
//
//   obj_dir/Vmainvid accesses trace [max clocks] [SDRAM latency] [norom] [frames]
#include "Vmainvid.h"
#include "Vmainvid___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const char* name, size_t size) {
    std::vector<uint8_t> v(size, 0xff);
    FILE* f = fopen(name, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", name); exit(1); }
    fread(v.data(), 1, size, f);
    fclose(f);
    return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long target = argc > 1 ? atol(argv[1]) : 200000;
    FILE* out = fopen(argc > 2 ? argv[2] : "rtl.trace", "w");
    long max_clk = argc > 3 ? atol(argv[3]) : 3072L * 289 * 60;   // 60 frames
    setvbuf(out, nullptr, _IOLBF, 1 << 16);
    long as_falls = 0, iacks = 0, as_t0 = 0;
    long dur_hist[3][32] = {};           // AS-low length in 48 MHz clocks: ROM, work RAM, other
    int l_dsn = 3, l_fc = 0; uint32_t l_a = 0; bool l_rd = true; uint16_t l_d = 0;
    auto rom = load("main.bin", 0x200000);
    auto eeprom = load("eeprom.bin", 128);
    std::vector<uint8_t> wram(0x10000, 0);
    std::vector<uint16_t> k321;
    bool norom = argc > 5 && atoi(argv[5]);
    long max_frames = argc > 6 ? atol(argv[6]) : 0;
    if (FILE* kf = fopen("k054321.txt", "r")) {
        unsigned v;
        while (fscanf(kf, "%x", &v) == 1) k321.push_back(v);
        fclose(kf);
    }
    size_t k321_i = 0;

    Vmainvid m;
    auto* r = m.rootp;
    // SDRAM latency in 48 MHz clocks: jtframe documents 9-12 clocks of 96 MHz on MiSTer
    // (modules/jtframe/doc/sdram.md:252-255), so 5 by default
    const int LAT = argc > 4 ? atoi(argv[4]) : 5;
    int rom_cnt = 0, ram_cnt = 0;
    uint32_t rom_last = ~0u, ram_last = ~0u, rom_line = ~0u;
    long clk = 0, n = 0, frame = 0;
    const long LINE = 3072, FRAME = LINE * 289;  // 512 x 289 at 8 MHz, from 48 MHz
    bool as_l = true;

    m.pair_dout = 0;
    m.rst = 1;
    fprintf(out, "# rtl accesses from reset: seq rw addr mask data frame line\n");

    while (n < target && clk < max_clk) {
        if (clk == 32) m.rst = 0;
        long lpos = clk % FRAME;
        long line = (lpos / LINE + 256) % 289;      // reset at MAME's frame 0, line 256
        // pixel enables: 8 MHz and 16 MHz from 48 MHz
        m.pxl_cen  = clk % 6 == 0;
        m.pxl2_cen = clk % 3 == 0;
        if (lpos == 0 && clk) frame++;
        {   // LVBL edges from the video, reported once the game has set up the K053252
            static bool lv_l = true; static int nedge = 0;
            if (m.LVBL != lv_l && frame >= 641 && nedge < 12) {
                printf("LVBL %d at frame %ld line %ld (clk %ld)\n", m.LVBL, frame, line, clk);
                nedge++;
            }
            lv_l = m.LVBL;
        }

        // SDRAM model: data after LAT clocks of an unchanged request
        uint32_t ra = m.main_addr;                 // [20:1]
        if (m.rom_cs) {
            // jtframe's ROM slot reads 32-bit bursts (SLOT1_BURSTLEN 32): the other
            // word of the last pair is served from its buffer in a clock
            if (ra != rom_last) {
                rom_cnt = (ra >> 1) == rom_line ? LAT - 1 : 0;
                rom_last = ra;
            }
            if (rom_cnt < LAT) rom_cnt++;
            if (rom_cnt >= LAT) rom_line = ra >> 1;
            m.rom_ok = rom_cnt >= LAT;
            uint32_t b = (ra << 1) & 0x1fffff;
            m.rom_data = rom[b] << 8 | rom[b + 1];
        } else { m.rom_ok = 0; rom_last = ~0u; }
        {   // work RAM: block RAM, written on the clock, read a clock later
            uint32_t b = (ra << 1) & 0xffff;
            m.ram_dout = wram[b] << 8 | wram[b + 1];
            if (m.ram_we & 2) wram[b]     = m.cpu_dout >> 8;
            if (m.ram_we & 1) wram[b + 1] = m.cpu_dout & 0xff;
        }
        m.nv_dout = eeprom[m.nv_addr & 0x7f];
        m.pair_dout = k321_i < k321.size() ? k321[k321_i] & 0xff : 0;

        m.clk = 0; m.eval();
        m.clk = 1; m.eval();
        if (m.nv_we) eeprom[m.nv_addr & 0x7f] = m.nv_din;
        clk++;

        // A bus cycle ends when AS rises. Its address, lanes and data are latched while AS
        // is low (the strobes rise with AS). IACK cycles are not logged: MAME's taps do not
        // see them.
        bool as = r->mainvid__DOT__u_main__DOT__ASn;
        if (!as && as_l) { as_falls++; as_t0 = clk; if (r->mainvid__DOT__u_main__DOT__FC == 7) iacks++; }
        if (as && !as_l && l_dsn != 3) {
            int k = (l_a < 0x80000 || (l_a >= 0x100000 && l_a < 0x180000)) ? 0 :
                    (l_a >= 0x80000 && l_a < 0x90000) ? 1 : 2;
            long d = clk - as_t0; dur_hist[k][d > 31 ? 31 : d]++;
        }
        if (!as) {
            int dsn = (r->mainvid__DOT__u_main__DOT__UDSn << 1) | r->mainvid__DOT__u_main__DOT__LDSn;
            if (dsn != 3) {
                l_dsn = dsn;
                l_a   = (r->mainvid__DOT__u_main__DOT__A << 1) & 0xffffff;
                l_rd  = r->mainvid__DOT__u_main__DOT__RnW;
                l_fc  = r->mainvid__DOT__u_main__DOT__FC;
                l_d   = l_rd ? r->mainvid__DOT__u_main__DOT__cpu_din : m.cpu_dout;
            }
        }
        // the vector table is logged even with norom: interrupts show as vector fetches
        bool is_rom = (l_a >= 0x100 && l_a < 0x80000) || (l_a >= 0x100000 && l_a < 0x180000);
        if (as && !as_l && l_dsn != 3 && l_fc != 7 && l_rd && l_a >= 0x0d6000 && l_a < 0x0d6020)
            k321_i++;                                   // next replayed K054321 value
        if (max_frames && frame >= max_frames) break;
        if (as && !as_l && l_dsn != 3 && l_fc != 7 && !(norom && l_rd && is_rom)) {
            int mask = (l_dsn & 2 ? 0 : 0xff00) | (l_dsn & 1 ? 0 : 0x00ff);
            fprintf(out, "%ld %c %06X %04X %04X %ld %ld\n", ++n, l_rd ? 'R' : 'W', l_a, mask,
                    l_d & mask, frame, line);
        }
        if (as && !as_l) l_dsn = 3;
        if (Verilated::gotFinish()) {
            printf("$finish at clock %ld, A %06X\n", clk, l_a);
            break;
        }
        as_l = as;
    }
    fprintf(out, "# %ld logged, %ld clocks\n", n, clk);
    fclose(out);
    const char* kn[3] = {"ROM", "work RAM", "other"};
    for (int k = 0; k < 3; k++) {
        printf("AS low, %s:", kn[k]);
        for (int d = 0; d < 32; d++) if (dur_hist[k][d]) printf(" %d:%ld", d, dur_hist[k][d]);
        printf("\n");
    }
    printf("%ld accesses in %ld clocks (%.2f frames); AS fell %ld times, %ld IACK\n",
           n, clk, (double)clk / FRAME, as_falls, iacks);
    printf("last A %06X FC %d ASn %d UDSn %d LDSn %d DTACKn %d HALTn %d rst %d rom_cs %d rom_ok %d\n",
           (r->mainvid__DOT__u_main__DOT__A << 1) & 0xffffff, r->mainvid__DOT__u_main__DOT__FC,
           r->mainvid__DOT__u_main__DOT__ASn, r->mainvid__DOT__u_main__DOT__UDSn, r->mainvid__DOT__u_main__DOT__LDSn,
           r->mainvid__DOT__u_main__DOT__DTACKn, r->mainvid__DOT__u_main__DOT__HALTn, m.rst, m.rom_cs, m.rom_ok);
    // the palette as the real CPU wrote it: pal.bin, 2048 colours of x, r, g, b bytes
    if (FILE* pf = fopen("pal.bin", "wb")) {
        for (int i = 0; i < 2048; i++) {
            uint8_t c[4] = {
                (uint8_t)r->mainvid__DOT__u_video__DOT__u_colmix__DOT__u_ram_x__DOT__u_dual__DOT__u_ram__DOT__mem[i],
                (uint8_t)r->mainvid__DOT__u_video__DOT__u_colmix__DOT__u_ram_r__DOT__u_dual__DOT__u_ram__DOT__mem[i],
                (uint8_t)r->mainvid__DOT__u_video__DOT__u_colmix__DOT__u_ram_g__DOT__u_dual__DOT__u_ram__DOT__mem[i],
                (uint8_t)r->mainvid__DOT__u_video__DOT__u_colmix__DOT__u_ram_b__DOT__u_dual__DOT__u_ram__DOT__mem[i] };
            fwrite(c, 1, 4, pf);
        }
        fclose(pf);
    }
    return 0;
}
