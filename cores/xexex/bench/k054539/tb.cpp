// Smoke bench for jtxexex_k054539: register write and read-back through
// the rd_ok wait, and a key-on that makes the voices fetch ROM granules
// from a modelled PCM bus. Not a MAME comparison; that is Phase 1.
#include "Vjtxexex_k054539.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

double sc_time_stamp() { return 0; }

static Vjtxexex_k054539* m;
static uint64_t cyc = 0;
static std::vector<uint8_t> rom(1 << 22);
static int rom_lat = 0, rom_reads = 0;
static uint32_t cen_acc = 0;

static void tick() {
    // cen_pcm: 18.432 MHz from 48 MHz, 48/125
    cen_acc += 48;
    m->cen_pcm = cen_acc >= 125;
    if (cen_acc >= 125) cen_acc -= 125;
    // PCM bus: data after 6 clocks of a steady request
    if (m->rom_cs) {
        if (rom_lat < 6) { rom_lat++; m->rom_ok = 0; }
        else {
            uint32_t a = m->rom_addr << 2;
            m->rom_data = rom[a] | rom[a+1] << 8 | rom[a+2] << 16 | (uint32_t)rom[a+3] << 24;
            if (!m->rom_ok) rom_reads++;
            m->rom_ok = 1;
        }
    } else { rom_lat = 0; m->rom_ok = 0; }
    m->clk = 0; m->eval();
    m->clk = 1; m->eval();
    cyc++;
}

static void wr(int a, int d) {
    m->cs = 1; m->addr = a; m->din = d; m->wr = 1;
    for (int k = 0; k < 24; k++) tick();       // one Z80 bus cycle at 8 MHz
    m->wr = 0; m->cs = 0; tick();
}

static int rd(int a, int& waited) {
    m->cs = 1; m->addr = a; m->rd = 1; waited = 0;
    while (!m->rd_ok && waited < 10000) { tick(); waited++; }
    int d = m->dout;
    m->rd = 0; m->cs = 0; tick();
    return d;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    m = new Vjtxexex_k054539;
    for (size_t i = 0; i < rom.size(); i++) rom[i] = (i * 7) & 0x7f;   // no 0x80 end marker
    m->rst = 1; for (int k = 0; k < 20; k++) tick(); m->rst = 0;
    int fails = 0, w;

    wr(0x003, 0x5a);
    int d = rd(0x003, w);
    printf("reg 0x003: wrote 5a, read %02x after %d clocks\n", d, w);
    if (d != 0x5a || w >= 10000) fails++;

    // channel 0: 8-bit PCM from 0x001000, pitch 0x10000 (one byte a sample), volume 0, centre pan
    wr(0x000, 0x00); wr(0x001, 0x00); wr(0x002, 0x01);
    wr(0x003, 0x00); wr(0x005, 0x18);
    wr(0x00c, 0x00); wr(0x00d, 0x10); wr(0x00e, 0x00);
    wr(0x200, 0x00);
    wr(0x22f, 0x01);            // enable
    wr(0x214, 0x01);            // key on channel 0
    uint64_t start = cyc;
    int nonzero = 0;
    while (cyc - start < 48000) {           // 1 ms: 48 samples
        tick();
        if (m->left || m->right) nonzero++;
    }
    printf("1 ms after key on: %d ROM reads, output nonzero on %d clocks, last %d/%d\n",
           rom_reads, nonzero, (int16_t)m->left, (int16_t)m->right);
    if (rom_reads == 0 || nonzero == 0) fails++;

    printf(fails ? "FAIL\n" : "PASS\n");
    delete m;
    return fails ? 1 : 0;
}
