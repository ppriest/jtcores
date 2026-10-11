// jtxexex_video from a MAME state (scripts/video_state.py): the state's writes are
// replayed through the video's CPU ports with the main CPU's chip selects
// (hdl/jtxexex_main.v), then frames are rendered with the graphics ROMs served from
// tiles.bin, obj.bin and lvc.bin (prep.py) as the SDRAM holds them. Each frame is
// written as frame-<n>.ppm, the whole active area (LHBL and LVBL high), each tile
// layer's pixels as frame-<n>-lyr<L>.bin, 16 bits a pixel ({alpha, colour, pen}), and
// the K053250's as frame-<n>-lvc.bin ({colour, pen}). A "D" line is a K053250 DMA
// strobe: register 4 bit 1 set, then cleared.
//
//   obj_dir/Vjtxexex_video state.txt [frames] [out prefix]
#include "Vjtxexex_video.h"
#include "Vjtxexex_video___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const char* name, size_t size) {
    std::vector<uint8_t> v(size, 0);
    FILE* f = fopen(name, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", name); exit(1); }
    fread(v.data(), 1, size, f);
    fclose(f);
    return v;
}

struct Wr { uint32_t a; uint16_t d, m; int page; bool dma; };
// clocks the K053250 ROM answers in after an address settles (LVC_LAT env)
static int LVC_LAT = 4;

static Vjtxexex_video v;
static long clk = 0;
static std::vector<uint8_t> tiles, obj, lvc;

// One 48 MHz clock, with the graphics ROMs answering a few clocks after an address
// settles, as the SDRAM's 32-bit slots do
static void tick() {
    static uint32_t la[5] = {~0u, ~0u, ~0u, ~0u, ~0u};
    static int cnt[5] = {};
    uint32_t a[5] = { v.lyrf_addr, v.lyra_addr, v.lyrb_addr, v.lyro_addr, v.lvc_addr };
    for (int k = 0; k < 5; k++) {
        if (a[k] != la[k]) { la[k] = a[k]; cnt[k] = 0; }
        else if (cnt[k] < 64) cnt[k]++;
    }
    auto rd32 = [](const std::vector<uint8_t>& r, uint32_t wa) {
        uint32_t b = (wa << 2) % r.size();
        return (uint32_t)r[b] | r[b + 1] << 8 | r[b + 2] << 16 | (uint32_t)r[b + 3] << 24;
    };
    v.lyrf_data = rd32(tiles, a[0]);
    v.lyra_data = rd32(tiles, a[1]);
    v.lyrb_data = rd32(tiles, a[2]);
    v.lyro_data = rd32(obj, a[3]);
    v.lvc_data  = rd32(lvc, a[4]);
    v.lvc_ok    = cnt[4] >= LVC_LAT;
    v.lyrf_ok = cnt[0] >= 4;
    v.lyra_ok = cnt[1] >= 4;
    v.lyrb_ok = cnt[2] >= 4;
    v.lyro_ok = cnt[3] >= 4;
    v.pxl_cen  = clk % 6 == 0;
    v.pxl2_cen = clk % 3 == 0;
    v.clk = 0; v.eval();
    v.clk = 1; v.eval();
    clk++;
}

static void idle_cs() {
    v.scrreg_cs = v.tilesys_cs = v.scr_cs = v.objreg_cs = v.objsys_cs = v.col_cs =
    v.pcu_cs = v.pal_cs = v.cco_cs = v.lvcram_cs = v.lvcreg_cs = v.lvcrom_cs = 0;
    v.oram_we = 0; v.cpu_we = 0; v.rw = 1; v.cpu_dsn = 3;
}

static bool objcha_n = true;

// A CPU write: chip select, address, data and lanes held for 4 clocks, as an
// AS-low period of the 68000 at 16 MHz is longer than that
static void cpu_write(uint32_t a, uint16_t d, uint16_t m) {
    int dsn = (m & 0xff00 ? 0 : 2) | (m & 0x00ff ? 0 : 1);
    if (a == 0x0de000) {     // control2: OBJCHA (bit 8) and alpha off (bit 9)
        if (!(dsn & 2)) { objcha_n = !((d >> 8) & 1); v.alpha_off = (d >> 9) & 1; }
        v.objcha_n = objcha_n;
        return;
    }
    idle_cs();
    v.cpu_addr = (a >> 1) & 0xffff;
    v.vtimer_addr = (a >> 1) & 0xf;
    v.cpu_dout = d; v.cpu_dsn = dsn; v.cpu_we = 1; v.rw = 0;
    uint32_t blk = a >> 16, sub = (a >> 13) & 7;
    if (blk == 0x09) { v.objsys_cs = 1; v.oram_we = (~dsn) & 3; }
    else if (blk == 0x0c && sub == 0) v.scrreg_cs = 1;
    else if (blk == 0x0c && sub == 3) v.lvcram_cs = 1;
    else if (blk == 0x0c && sub == 4) v.lvcreg_cs = 1;
    else if (blk == 0x0c && sub == 1) v.objreg_cs = 1;
    else if (blk == 0x0c && sub == 5) v.col_cs = 1;
    else if (blk == 0x0c && sub == 6) v.pcu_cs = 1;
    else if (blk == 0x0d && sub == 0) v.cco_cs = 1;
    else if (blk == 0x0d && sub == 4) v.tilesys_cs = 1;
    else if (blk == 0x18) v.scr_cs = 1;
    else if (blk == 0x1b) v.pal_cs = 1;
    else { idle_cs(); return; }
    for (int i = 0; i < 4; i++) tick();
    idle_cs();
    for (int i = 0; i < 2; i++) tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s state.txt [frames] [prefix]\n", argv[0]); return 1; }
    int frames = argc > 2 ? atoi(argv[2]) : 3;
    std::string prefix = argc > 3 ? argv[3] : "frame";
    tiles = load("tiles.bin", 0x200000);
    obj = load("obj.bin", 0x400000);
    lvc = load("lvc.bin", 0x80000);
    if (getenv("LVC_LAT")) LVC_LAT = atoi(getenv("LVC_LAT"));

    std::vector<Wr> wr;
    {
        FILE* f = fopen(argv[1], "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
        char ln[128]; int page = -1;
        while (fgets(ln, sizeof ln, f)) {
            unsigned a, d, m; int p;
            if (sscanf(ln, "P %d", &p) == 1) page = p;
            else if (ln[0] == 'D') wr.push_back({0, 0, 0, page, true});
            else if (sscanf(ln, "W %x %x %x", &a, &d, &m) == 3) wr.push_back({a, (uint16_t)d, (uint16_t)m, page, false});
        }
        fclose(f);
    }

    v.debug_bus = 0; v.ioctl_addr = 0; v.ioctl_ram = 0; v.gfx_en = 0xf;
    v.blnk_sel = 0; v.tilerom_cs = 0; v.oram_addr = 0; v.dim = 0; v.dimmod = 0; v.dimpol = 0;
    v.objcha_n = 1; v.alpha_off = 0;
    v.flip = getenv("FLIP") != nullptr;    // the OSD's flip screen
    idle_cs();
    v.rst = 1;
    for (int i = 0; i < 64; i++) tick();
    v.rst = 0;
    for (int i = 0; i < 64; i++) tick();

    // tile pages: register 0x32 picks the CPU's page, bits 4-3 the row, 1-0 the column
    int cur_page = -2;
    for (auto& w : wr) {
        if (w.dma) {        // the K053250 copies 2048 words: let it finish
            cpu_write(0x0c8008, 0x0002, 0x00ff);
            cpu_write(0x0c8008, 0x0000, 0x00ff);
            for (int i = 0; i < 2200; i++) tick();
            continue;
        }
        if (w.a >= 0x180000 && w.a < 0x184000 && w.page != cur_page) {
            cur_page = w.page;
            int bank = (cur_page >> 2) << 3 | (cur_page & 3);
            cpu_write(0x0c0032, bank, 0x00ff);
        }
        cpu_write(w.a, w.d, w.m);
    }
    printf("%zu writes in %ld clocks\n", wr.size(), clk);

    // frames from the next LVBL rise
    std::vector<uint8_t> img;
    std::vector<uint16_t> lyr[4], lvcp;
    auto* r = v.rootp;
    int fr = 0, w = 0, h = 0, x = 0;
    bool lv_l = v.lvbl, lh_l = v.lhbl, started = false;
    long guard = clk + 48000000L / 59 * (frames + 2);
    while (fr < frames && clk < guard) {
        tick();
        bool lv = v.lvbl, lh = v.lhbl;
        if (lv && !lv_l) { started = true; img.clear(); for (auto& l : lyr) l.clear(); lvcp.clear(); h = 0; }
        if (started && v.pxl_cen && lv && lh) {
            img.push_back(v.red); img.push_back(v.green); img.push_back(v.blue);
            lyr[0].push_back(r->jtxexex_video__DOT__u_tilemap__DOT__lyr0_pxl);
            lyr[1].push_back(r->jtxexex_video__DOT__u_tilemap__DOT__lyr1_pxl);
            lyr[2].push_back(r->jtxexex_video__DOT__u_tilemap__DOT__lyr2_pxl);
            lyr[3].push_back(r->jtxexex_video__DOT__u_tilemap__DOT__lyr3_pxl);
            lvcp.push_back(r->jtxexex_video__DOT__lvc_pxl);
            x++;
        }
        if (started && lv && !lh && lh_l) { if (x) { w = x; h++; } x = 0; }
        if (started && !lv && lv_l && h) {
            std::string n = prefix + "-" + std::to_string(fr) + ".ppm";
            FILE* f = fopen(n.c_str(), "wb");
            fprintf(f, "P6 %d %d 255\n", w, h);
            fwrite(img.data(), 1, (size_t)w * h * 3, f);
            fclose(f);
            for (int k = 0; k < 4; k++) {
                std::string ln = prefix + "-" + std::to_string(fr) + "-lyr" + std::to_string(k) + ".bin";
                FILE* lf = fopen(ln.c_str(), "wb");
                fwrite(lyr[k].data(), 2, lyr[k].size(), lf);
                fclose(lf);
            }
            {
                std::string ln = prefix + "-" + std::to_string(fr) + "-lvc.bin";
                FILE* lf = fopen(ln.c_str(), "wb");
                fwrite(lvcp.data(), 2, lvcp.size(), lf);
                fclose(lf);
            }
            printf("%s: %dx%d at clock %ld\n", n.c_str(), w, h, clk);
            fr++;
        }
        {   // sprite path counters (debugging)
            static long bsy = 0, oks = 0, pix = 0; static bool bsy_l = false;
            bool b = r->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_dma__DOT__dma_bsy;
            if (b && !bsy_l) printf("DMA start at clock %ld, dma_en %d\n", clk,
                (int)r->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_dma__DOT__dma_en);
            if (!b && bsy_l) printf("DMA end at clock %ld: %ld entries, %ld sprite pixels so far\n", clk, oks, pix);
            bsy_l = b;
            if (r->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_dma__DOT__dma_ok && v.pxl2_cen) oks++;
            if (v.pxl_cen && (r->jtxexex_video__DOT__u_obj__DOT__pxl & 0xf)) pix++;
            static long rcs = 0; static bool cs_l = false;
            if (v.lyro_cs && !cs_l && rcs++ < 5) printf("obj ROM read %06X at clock %ld\n", v.lyro_addr << 2, clk);
            cs_l = v.lyro_cs;
            {
                static long nst = 0, nbusy = 0, ncs = 0;
                if (r->jtxexex_video__DOT__u_obj__DOT__dr_start) nst++;
                if (r->jtxexex_video__DOT__u_obj__DOT__dr_busy) nbusy++;
                if (r->jtxexex_video__DOT__u_obj__DOT__pre_cs) ncs++;
                if (getenv("SCANDBG") && clk % 1000000 == 0)
                    printf("clk %ld: dr_start %ld, dr_busy %ld, pre_cs %ld, lyro_cs %d ok %d\n",
                        clk, nst, nbusy, ncs, v.lyro_cs, v.lyro_ok);
            }
            static int dbg_n = 0;
            auto* sc = r;
            {   // SCANV: the line each object scan starts on, against the blanking
                static unsigned vl_l = 0;
                unsigned vl = sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__vlatch;
                if (getenv("SCANV") && vl != vl_l && fr == frames - 1)
                    printf("scan vlatch %03X ynow %03X lvbl %d line %d\n", vl,
                        sc->jtxexex_video__DOT__ynow, v.lvbl, h);
                vl_l = vl;
            }
            if (getenv("SCANDBG") && dbg_n < 40 && sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__vlatch == 0x180
                && sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__scan_sub == 3) {
                dbg_n++;
                printf("obj %02X even %04X y %03X ydiff_b %03X yadj %03X inzone %d\n",
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__scan_obj,
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__scan_even,
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__y,
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__ydiff_b,
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__yadj,
                    sc->jtxexex_video__DOT__u_obj__DOT__u_scan__DOT__u_scan__DOT__inzone);
            }
        }
        lv_l = lv; lh_l = lh;
    }

    // tile ROM readback (190000): k056832 rom_word_r on tiles.bin, which holds MAME's
    // region byte for byte
    int bad = 0;
    for (int k = 0; k < 64; k++) {
        int bank = (k * 37) & 0xff, off = (k * 1237) & 0xfff;
        cpu_write(0x0c0034, bank, 0x00ff);
        idle_cs();
        v.cpu_addr = 0x8000 | off; v.tilerom_cs = 1;     // 190000 + 2 * off, bits 16:1
        int t = 0;
        do { tick(); } while (!v.tilerom_ok && ++t < 64);
        tick();
        uint32_t a = 0x2000 * bank + 2 * off;
        uint16_t want = tiles[a] << 8 | tiles[a + 1];
        if (v.tilerom_dout != want && bad++ < 4)
            printf("tile ROM bank %02X offset %03X: %04X, MAME %04X\n", bank, off, v.tilerom_dout, want);
        v.tilerom_cs = 0;
        tick();
    }
    printf("tile ROM readback: %d of 64 differ\n", bad);
    printf("hvis %d xlast %d ylast %d\n", r->jtxexex_video__DOT__hvis,
        r->jtxexex_video__DOT__xlast, r->jtxexex_video__DOT__ylast);
    return 0;
}
