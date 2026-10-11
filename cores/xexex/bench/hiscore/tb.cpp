// jtxexex_hiscore against models of the 68000's work-RAM traffic, work RAM (a BRAM
// with registered output) and hiram. Two boots:
//   1. hiram empty: the game writes its default table at frame 40; hiram must then
//      hold the table, and later CPU writes to the areas must reach it.
//   2. hiram holds a saved table: after the default table is written, work RAM must
//      hold the saved bytes of the areas, and 85063 and 80056 must keep their own.
// The CPU uses work RAM on two clocks of every three, as a busy 68000 at most would.
//
//   bench/run_verilator.sh hiscore jtxexex_hiscore hdl/jtxexex_hiscore.v
#include "Vjtxexex_hiscore.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

double sc_time_stamp() { return 0; }

static Vjtxexex_hiscore v;
static uint16_t wram[0x8000], hiram[64];
static uint16_t wq, hq;
static long clk = 0;

// work RAM byte address (0x80000-0x8ffff) to word index
static int wi(uint32_t a) { return (a & 0xffff) >> 1; }
static uint8_t rd8(uint32_t a) { uint16_t w = wram[wi(a)]; return a & 1 ? w & 0xff : w >> 8; }

// one clock; the CPU writes word wa with lanes we when cpu_we is set
static void tick(bool cpu_cs, int cpu_wa, uint16_t cpu_d, int cpu_we) {
    v.ram_cs = cpu_cs;
    v.main_addr = cpu_wa;
    v.cpu_dout = cpu_d;
    v.main_we = cpu_cs ? cpu_we : 0;
    v.lvbl = (clk % 100000) < 90000;   // a frame every 100000 clocks
    v.wram_dout = wq;
    v.hi_dout = hq;
    v.clk = 0; v.eval();
    // memories sample on the rising edge
    int a = v.wram_a, we = v.wram_we;
    uint16_t d = v.wram_din;
    int ha = v.hi_addr, hwe = v.hi_we;
    uint16_t hd = v.hi_din;
    v.clk = 1; v.eval();
    if (we & 2) wram[a] = (wram[a] & 0x00ff) | (d & 0xff00);
    if (we & 1) wram[a] = (wram[a] & 0xff00) | (d & 0x00ff);
    wq = wram[a];
    if (hwe & 2) hiram[ha] = (hiram[ha] & 0x00ff) | (hd & 0xff00);
    if (hwe & 1) hiram[ha] = (hiram[ha] & 0xff00) | (hd & 0x00ff);
    hq = hiram[ha];
    clk++;
}

// the default table: first byte 00, last 1c; 80057 00, 80059 30
static void game_default(uint8_t fill) {
    for (uint32_t a = 0x85000; a < 0x85063; a++) {
        uint8_t b = a == 0x85000 ? 0 : a == 0x85062 ? 0x1c : fill;
        uint16_t& w = wram[wi(a)];
        w = a & 1 ? (w & 0xff00) | b : (w & 0x00ff) | (b << 8);
    }
    wram[wi(0x80056)] = (wram[wi(0x80056)] & 0xff00) | 0x00;
    wram[wi(0x80058)] = 0x7730;
}

static void run_frames(int n, int default_at, uint8_t fill, int cpu_write_at, int* fails) {
    for (int f = 0; f < n; f++) {
        if (f == default_at) game_default(fill);
        for (int c = 0; c < 100000; c++) {
            bool cs = (c % 3) != 2;
            if (f == cpu_write_at && c == 500)          // one CPU write into area 1
                tick(true, wi(0x85010), 0xbeef, 3);
            else
                tick(cs, wi(0x81000), 0, 0);
        }
    }
    (void)fails;
}

static int check(const char* what, bool ok) {
    printf("%s: %s\n", what, ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}

static void reset() {
    v.rst = 1;
    for (int i = 0; i < 8; i++) tick(false, 0, 0, 0);
    v.rst = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;

    // boot 1: empty hiram
    memset(wram, 0, sizeof wram); memset(hiram, 0, sizeof hiram);
    wram[wi(0x85062)] = 0x5a5a;    // 85063 is not ours
    reset();
    run_frames(80, 40, 0x11, 70, &fails);
    bool same = true;
    for (int i = 0; i < 50; i++) if (hiram[i] != wram[wi(0x85000) + i]) same = false;
    if (hiram[51] != wram[wi(0x80058)] || (hiram[50] & 0xff) != (wram[wi(0x80056)] & 0xff)) same = false;
    fails += check("boot 1: hiram holds the table and the CPU's later write", same && hiram[8] == 0xbeef);

    // boot 2: hiram keeps boot 1's table (0xbeef at 85010); the game writes a
    // different default; work RAM must end with boot 1's bytes
    memset(wram, 0, sizeof wram);
    wram[wi(0x85062)] = 0x00a5;    // 85063 = a5, kept
    wram[wi(0x80056)] = 0x6600;    // 80056 = 66, kept
    uint16_t saved[64]; memcpy(saved, hiram, sizeof saved);
    reset();
    run_frames(80, 40, 0x22, -1, &fails);
    bool rest = true;
    for (uint32_t a = 0x85000; a < 0x85063; a++) {
        int i = (a - 0x85000) >> 1;
        uint8_t want = a & 1 ? saved[i] & 0xff : saved[i] >> 8;
        if (rd8(a) != want) { rest = false; printf("  %05X: %02X, saved %02X\n", a, rd8(a), want); break; }
    }
    rest = rest && rd8(0x80057) == (saved[50] & 0xff) && rd8(0x80058) == (saved[51] >> 8)
                && rd8(0x80059) == (saved[51] & 0xff);
    fails += check("boot 2: work RAM holds the saved table", rest && rd8(0x85010) == 0xbe);
    fails += check("boot 2: 85063 and 80056 untouched", rd8(0x85063) == 0xa5 && rd8(0x80056) == 0x66);
    printf("%s\n", fails ? "FAIL" : "PASS");
    return fails;
}
