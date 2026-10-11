// jtxexex_sound from reset: T80, K054321, K054539 (gx_k054539 behind jtxexex_k054539),
// YM2151 (jt51). The 68000's side is replayed from MAME's main-CPU trace: its writes
// to the K054321 (0d6000-0d601f) and the sound IRQ (0d4000), each at its frame and line.
// Every Z80 memory access outside the program ROM (0000-bfff) is logged as
// scripts/boot_trace.py --cpu audiocpu logs them, for scripts/compare_trace.py --z80.
//
// The K054539 and YM2151 outputs are written at 48 kHz to k539.wav and fm.wav, to be
// judged by ear.
//
//   obj_dir/Vjtxexex_sound main.trace out.trace frames
#include "Vjtxexex_sound.h"
#include "Vjtxexex_sound___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

double sc_time_stamp() { return 0; }

struct MainWr { long clk; int addr; int data; };

struct Wav {    // 16-bit stereo, 48 kHz
    FILE* f; long n = 0;
    explicit Wav(const char* name) { f = fopen(name, "wb"); uint8_t h[44] = {}; fwrite(h, 1, 44, f); }
    void put(int16_t l, int16_t r) { fwrite(&l, 2, 1, f); fwrite(&r, 2, 1, f); n++; }
    ~Wav() {
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
        fseek(f, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, f); w32(36 + n * 4); fwrite("WAVEfmt ", 1, 8, f);
        w32(16); w16(1); w16(2); w32(48000); w32(48000 * 4); w16(4); w16(16);
        fwrite("data", 1, 4, f); w32(n * 4); fclose(f);
    }
};

static std::vector<uint8_t> load(const char* name, size_t size) {
    std::vector<uint8_t> v(size, 0);
    FILE* f = fopen(name, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", name); exit(1); }
    fread(v.data(), 1, size, f);
    fclose(f);
    return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const long LINE = 3072, FRAME = LINE * 289;
    auto snd = load("snd.bin", 0x20000);
    auto pcm = load("pcm.bin", 0x300000);
    long frames = argc > 3 ? atol(argv[3]) : 600;

    // main-CPU writes to replay, from MAME's trace (line relative to frame 0 at line 256)
    std::vector<MainWr> wr;
    {
        FILE* f = fopen(argv[1], "r");
        char ln[256];
        while (fgets(ln, sizeof ln, f)) {
            long seq, fr, line; char rw; unsigned a, m, d;
            if (ln[0] == '#' || sscanf(ln, "%ld %c %x %x %x %ld %ld", &seq, &rw, &a, &m, &d, &fr, &line) != 7) continue;
            if (rw != 'W') continue;
            if ((a >= 0x0d6000 && a < 0x0d6020) || a == 0x0d4000)
                wr.push_back({ (fr * 289 + (line - 256 + 289) % 289) * LINE, (int)a, (int)(d & 0xff) });
        }
        fclose(f);
    }
    FILE* out = fopen(argv[2], "w");
    fprintf(out, "# rtl Z80 accesses from reset: seq rw addr mask data frame line\n");

    Vjtxexex_sound m;
    auto* r = m.rootp;
    size_t wi = 0;
    long clk = 0, n = 0, hold = 0;
    int rom_cnt = 0, pcm_cnt = 0; uint32_t rom_last = ~0u, pcm_last = ~0u;
    uint32_t pcm_acc = 0;
    bool rd_l = true, wr_l = true;
    uint16_t l_a = 0; uint8_t l_d = 0;
    Wav wk("k539.wav"), wf("fm.wav");
    m.rst = 1; m.debug_bus = 0; m.pair_we = 0; m.snd_irq = 0; m.main_addr = 0; m.main_dout = 0;

    while (clk < frames * FRAME) {
        if (clk == 32) m.rst = 0;
        m.cen_8   = clk % 6 == 0;
        m.cen_fm  = clk % 12 == 0;
        m.cen_fm2 = clk % 24 == 0;
        pcm_acc += 48; m.cen_pcm = pcm_acc >= 125; if (pcm_acc >= 125) pcm_acc -= 125;

        // replayed 68000 writes, each held for a main bus cycle (7 clocks)
        if (hold) hold--;
        else { m.pair_we = 0; m.snd_irq = 0; }
        if (!hold && wi < wr.size() && wr[wi].clk <= clk) {
            if (wr[wi].addr == 0x0d4000) m.snd_irq = 1;
            else { m.pair_we = 1; m.main_addr = (wr[wi].addr >> 1) & 0xf; m.main_dout = wr[wi].data; }
            hold = 7; wi++;
        }

        // Z80 program ROM and sample ROM: data after a few clocks of an unchanged request
        if (m.rom_cs) {
            if (m.rom_addr != rom_last) { rom_last = m.rom_addr; rom_cnt = 0; }
            if (rom_cnt < 5) rom_cnt++;
            m.rom_ok = rom_cnt >= 5; m.rom_data = snd[m.rom_addr & 0x1ffff];
        } else { m.rom_ok = 0; rom_last = ~0u; }
        if (m.pcm_cs) {
            if (m.pcm_addr != pcm_last) { pcm_last = m.pcm_addr; pcm_cnt = 0; }
            if (pcm_cnt < 5) pcm_cnt++;
            uint32_t b = (m.pcm_addr << 2) % 0x300000;
            m.pcm_ok = pcm_cnt >= 5;
            m.pcm_data = pcm[b] | pcm[b + 1] << 8 | pcm[b + 2] << 16 | (uint32_t)pcm[b + 3] << 24;
        } else { m.pcm_ok = 0; pcm_last = ~0u; }

        m.clk = 0; m.eval();
        m.clk = 1; m.eval();
        clk++;
        if (clk % 1000 == 0) {       // 48 kHz
            wk.put(m.k539_l, m.k539_r);
            wf.put(m.fm_l, m.fm_r);
        }

        // a memory access ends when its strobe rises; address and data latched while low
        auto& s = *r;
        bool mreq = !s.jtxexex_sound__DOT__mreq_n, rd = s.jtxexex_sound__DOT__rd_n, wn = s.jtxexex_sound__DOT__wr_n;
        uint16_t A = s.jtxexex_sound__DOT__A;
        if (mreq && (!rd || !wn)) { l_a = A; l_d = !rd ? s.jtxexex_sound__DOT__cpu_din : s.jtxexex_sound__DOT__cpu_dout; }
        long line = (clk % FRAME) / LINE, fr = clk / FRAME;
        long mline = (line + 256) % 289;
        if ((rd && !rd_l) || (wn && !wr_l)) {
            bool is_rd = rd && !rd_l;
            if (!(is_rd && l_a < 0xc000))
                fprintf(out, "%ld %c %06X FF %02X %ld %ld\n", ++n, is_rd ? 'R' : 'W', l_a, l_d,
                        fr, mline);
        }
        rd_l = rd; wr_l = wn;
    }
    fprintf(out, "# %ld logged\n", n);
    fclose(out);
    printf("%ld Z80 accesses logged in %ld frames, %zu of %zu main writes replayed\n", n, frames, wi, wr.size());
    return 0;
}
