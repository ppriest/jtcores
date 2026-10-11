#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's Xexex video, modelled from a state (scripts/video_state.py), for checking
bench/video layer by layer.

    python scripts/video_model.py state-2000.txt [--snap snap-2000.png] [--out dir]

Follows k054156_k054157_k056832.cpp (get_tile_info, tilemap_draw_common),
k053250.cpp (draw, pdraw_scanline32) and xexex.cpp (tile_callback, set_layer_offs,
screen_update). Writes layer<L>.png (pens over magenta where transparent), lvc.png, and
mix.png, the layers and background composed as screen_update does, with sprites if
--sprites. With --snap, prints how many pixels mix.png differs from MAME's frame in.

Screen x is MAME's 40-423 (xexex.cpp:705) shown as 0-383, y 0-255.
"""
import argparse
import os
from pathlib import Path

import numpy as np
from PIL import Image

W, H, X0 = 384, 256, 40
OFFS_X = (-2, 2, 4, 6)          # xexex.cpp:306-309
OFFS_Y = 16
SHIFTMASKS = ((6, 0x3f, 0, 0x00), (4, 0x0f, 2, 0x30), (2, 0x03, 2, 0x3c), (0, 0x00, 2, 0x3f))


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class State:
    def __init__(self, path):
        self.vram = np.zeros(16 * 4096, np.uint32)
        self.mem = {}               # word address -> value, for registers and RAMs
        # K053250: CPU RAM, its two line tables and the page draw() reads (k053250.cpp)
        self.lvc_ram = [0] * 0x1000
        self.lvc_buf = [[0] * 0x800, [0] * 0x800]
        self.lvc_page = 0
        page = -1
        for ln in open(path):
            t = ln.split()
            if not t or t[0] == "#":
                continue
            if t[0] == "D":         # dma(): RAM to buffer[page], then flip the page
                self.lvc_buf[self.lvc_page] = self.lvc_ram[:0x800]
                self.lvc_page ^= 1
            elif t[0] == "P":
                page = int(t[1])
            elif t[0] == "W":
                a, d, m = int(t[1], 16), int(t[2], 16), int(t[3], 16)
                if 0x180000 <= a < 0x184000:
                    self.vram[page * 4096 + ((a - 0x180000) >> 1 & 0xfff)] = d
                elif 0x0c6000 <= a < 0x0c8000:
                    i = (a - 0x0c6000) >> 1
                    self.lvc_ram[i] = (self.lvc_ram[i] & ~m & 0xffff) | (d & m)
                else:
                    old = self.mem.get(a, 0)
                    self.mem[a] = (old & ~m & 0xffff) | (d & m)
        self.regs = [self.mem.get(0x0c0000 + 2 * i, 0) for i in range(32)]
        self.k251 = [self.mem.get(0x0cc000 + 2 * i, 0) & 0xff for i in range(16)]
        self.k338 = [self.mem.get(0x0ca000 + 2 * i, 0) for i in range(16)]
        self.pal = np.array([self.mem.get(0x1b0000 + 2 * i, 0) for i in range(4096)], np.uint32)
        self.ctrl2 = self.mem.get(0x0de000, 0)
        self.lvc_regs = [self.mem.get(0x0c8000 + 2 * i, 0) & 0xff for i in range(8)]

    def colours(self):
        r = self.pal[0::2] & 0xff
        g = self.pal[1::2] >> 8
        b = self.pal[1::2] & 0xff
        return np.stack([r, g, b], -1).astype(np.uint8)

    def palette_index(self):     # k053251.cpp reset_indexes
        r9, r10 = self.k251[9], self.k251[10]
        return [32 * (r9 & 3), 32 * (r9 >> 2 & 3), 32 * (r9 >> 4 & 3), 16 * (r10 & 7), 16 * (r10 >> 3 & 7)]


def layer_page_owner(st):
    """update_page_layout: page -> layer, with association"""
    owner = [-1] * 16
    ys = [st.regs[8 + l] for l in range(4)]
    xs = [st.regs[12 + l] for l in range(4)]
    assoc = not any((ys[l] >> 3 & 3) == 0 and (xs[l] >> 3 & 3) == 0 and (ys[l] & 3) == 3 and (xs[l] & 3) == 3
                    for l in range(4))
    for l in range(4):
        y, h, x, w = ys[l] >> 3 & 3, ys[l] & 3, xs[l] >> 3 & 3, xs[l] & 3
        for r in range(h + 1):
            for c in range(w + 1):
                owner[((y + r) & 3) * 4 + ((x + c) & 3)] = l
    return owner, assoc


def scroll_entries(rowspan, ay, dy, flipy, mode):
    """Word offset of each screen line's scroll pair in the layer's line-scroll area:
    the r loop of tilemap_draw_common, as written, for modes 0 (per line) and 2 (per 8)"""
    ph = 256
    height = rowspan * ph
    ent = [None] * H
    lh = 1 if mode == 0 else 8
    adv = (2 if mode == 0 else 16) * (-1 if flipy else 1)
    for r in range(rowspan):
        if rowspan > 1:
            sy, ty = ay, r * ph
            if not flipy:
                if r == 0 and sy > height - ph:
                    sy -= height
                if sy + ph <= ty or sy - ph >= ty:
                    continue
                ty -= sy
                if ty >= 0:
                    cliph, clipy, starty, endy, start = ph - ty, ty, ty, ph, 0
                else:
                    cliph, ty = ph + ty, -ty
                    clipy, starty, endy, start = 0, 0, cliph, ty
                    if mode == 2:
                        start &= ~7
                        starty -= ty & 7
            else:
                ty += ph
                if r == rowspan - 1 and sy < ph:
                    sy += height
                if sy + ph <= ty or sy - ph >= ty:
                    continue
                ty -= sy
                if ty <= 0:
                    cliph, clipy, starty, endy, start = ph + ty, -ty, -ty, ph, ph - 1
                    if mode == 2:
                        start &= ~7
                else:
                    cliph = ph - ty
                    clipy, starty, endy, start = 0, 0, cliph, cliph - 1
                    if mode == 2:
                        start &= ~7
                        starty -= ty & 7
        else:
            cliph, clipy, starty, endy = ph, 0, 0, ph
            start = ph - 1 if flipy else dy
            if mode == 2:
                start &= ~7
                starty -= dy & 7
        walk = (start + r * ph) << 1
        clipmax = clipy + cliph - 1
        ly = starty
        while ly < endy:
            for y in range(max(ly, clipy, 0), min(ly + lh - 1, clipmax, H - 1) + 1):
                ent[y] = walk & 0x3ff
            walk += adv
            ly += lh
    return ent


def render_layer(st, rom, l, colorbase):
    """-> (pen, colour, alpha flag) arrays of H x W; pen 0 is transparent"""
    regs = st.regs
    assert not (regs[0] & 0x10), "flip x not modelled"
    flipy = regs[0] & 0x20
    yreg, xreg = regs[8 + l], regs[12 + l]
    rowstart, rowspan = yreg >> 3 & 3, (yreg & 3) + 1
    colstart, colspan = xreg >> 3 & 3, (xreg & 3) + 1
    height, width = rowspan * 256, colspan * 512
    dy, dx = s16(regs[16 + l]), s16(regs[20 + l])
    mode = regs[5] >> (2 * l) & 3
    bank = (regs[0x18] >> 1 & 0xc) | (regs[0x18] & 3)
    if flipy:                   # tilemap_draw_common: the flip correction, register 0x3c
        c = regs[0x1e] & 0x7ff
        dy += c - 0x800 if c & 0x400 else c
    ay = (dy - OFFS_Y) % height
    corr = -OFFS_X[l]
    owner, assoc = layer_page_owner(st)
    fl, palm1, pals2, palm2 = SHIFTMASKS[regs[3] >> 6 & 3]
    flip_en = regs[1] >> (2 * l) & 3
    sbase = bank * 4096 + l * 1024
    pen = np.zeros((H, W), np.uint8)
    col = np.zeros((H, W), np.uint16)
    alp = np.zeros((H, W), np.uint8)
    xs = np.arange(W) + X0
    ents = scroll_entries(rowspan, ay, dy, flipy, mode) if mode in (0, 2) else None
    for y in range(H):
        # source row: a flipped tilemap is mirrored about its own height (tilemap.cpp)
        sy = (ay - 1 - y) % height if flipy else (y + ay) % height
        if mode == 0 or mode == 2:
            o = ents[y]
            if o is None:
                continue
            sdx = (int(st.vram[sbase + o]) << 16 | int(st.vram[sbase + o + 1]))
            if sdx & 0x80000000:
                sdx -= 1 << 32
            ex = sdx + corr
        else:
            ex = dx + corr
        sx = (xs + ex) & (width - 1)
        page = ((rowstart + (sy >> 8)) & 3) * 4 + ((colstart + (sx >> 9)) & 3)
        tile = ((sy >> 3) & 31) * 64 + ((sx >> 3) & 63)
        base = page * 4096 + tile * 2
        attr = st.vram[base]
        code = st.vram[base + 1]
        flip = flip_en & (attr >> fl) & 3
        colour = (attr & palm1) | ((attr >> pals2) & palm2)
        row = np.where(flip & 2, 7 - (sy & 7), sy & 7)
        cx = np.where(flip & 1, 7 - (sx & 7), sx & 7)
        word = rom[(code.astype(np.int64) * 8 + row) % len(rom)]
        shift = np.array([12, 8, 4, 0, 28, 24, 20, 16])[cx]
        p = (word >> shift) & 0xf
        own = np.array([owner[pg] == l if assoc else owner[pg] >= 0 for pg in page])
        p = np.where(own, p, 0)
        pen[y] = p
        col[y] = colorbase | (colour >> 2 & 0x0f)
        alp[y] = colour & 1
    return pen, col, alp


SPR_DX, SPR_DY = -48, 32         # xexex.cpp:719 set_config
SRC = None                       # set to a dict to record sprite pixel sources
XOFFS = (0, 1, 4, 5, 16, 17, 20, 21)
YOFFS = (0, 2, 8, 10, 32, 34, 40, 42)
SPR_X = (2, 3, 0, 1, 6, 7, 4, 5, 10, 11, 8, 9, 14, 15, 12, 13)   # nibble of each pixel


LVC_OFFX, LVC_OFFY = -5, -16           # xexex.cpp K053250(config, ..., -5, -16)
LVC_ROM_NIBBLES = 0x100000
LVC_SRC = None      # when an (H, W) array, render_lvc stores each pixel's source nibble there


def lvc_scanline(pen, linepos, source, scroll, zoom, clipmask, wrapmask, swap, flip, line):
    """pdraw_scanline32 into pen[y][x] (screen x as 0-383): the line's source pixels,
    0 where transparent; line(i) gives the source nibble at offset i."""
    PREC, HALF = 16, 1 << 15
    dst_min, dst_max = (X0, X0 + W - 1) if not swap else (0, H - 1)
    if clipmask:
        dst_start = -scroll
        if dst_start > dst_max:
            return
        dst_length = clipmask + 1
        if zoom:
            dst_length = (dst_length << 6) // zoom
        end_pixel = dst_start + dst_length - 1
        if end_pixel < dst_min:
            return
        end_pixel -= dst_max
        if end_pixel > 0:
            dst_length -= end_pixel
        if dst_length <= 0:
            return
        src_fdx = zoom << (PREC - 6)
        end_pixel = dst_min - dst_start
        if end_pixel > 0:
            dst_length -= end_pixel
            dst_start = dst_min
            src_fx = end_pixel * src_fdx + HALF
        else:
            src_fx = HALF
        if flip:
            dst_start = dst_max + dst_min - dst_start - (dst_length - 1)
            src_fx += (dst_length - 1) * src_fdx - 1
            src_fdx = -src_fdx
    else:
        dst_start, dst_length = dst_min, dst_max - dst_min + 1
        src_fdx = zoom << (PREC - 6)
        if not flip:
            src_fx = (scroll + dst_min) * src_fdx + HALF
        else:
            src_fx = (scroll + dst_max) * src_fdx + HALF - 1
            src_fdx = -src_fdx
    src_mask = 0xffffffff if clipmask else wrapmask
    for k in range(dst_length):
        d = dst_start + k
        si = (src_fx >> PREC) & src_mask
        v = line(si)
        if LVC_SRC is not None:
            y, x = (linepos, d - X0) if not swap else (d, linepos - X0)
            if 0 <= y < H and 0 <= x < W:
                LVC_SRC[y][x] = getattr(line, 'base', 0) + si
        src_fx += src_fdx
        if v:
            if not swap:
                if 0 <= linepos < H:
                    pen[linepos][d - X0] = v
            else:
                if 0 <= d < H and X0 <= linepos < X0 + W:
                    pen[d][linepos - X0] = v


def render_lvc(st, rom):
    """k053250.cpp draw(): per-pixel pens (0 transparent) and palette rows (colour & 0x1f)"""
    pen = np.zeros((H, W), np.int64)
    col = np.zeros((H, W), np.int64)
    r = st.lvc_regs
    line_ram = st.lvc_buf[st.lvc_page]
    map_scrollx = s16(r[0] << 8 | r[1]) - LVC_OFFX
    map_scrolly = s16(r[2] << 8 | r[3]) - LVC_OFFY
    ctrl = r[4]
    swap, flipx, flipy = not ctrl & 1, bool(ctrl & 8), bool(ctrl & 0x10)
    dst_height, adv, wrap500 = 512, 4, False
    mode = ctrl >> 5
    if mode == 0:
        wrapmask = clipmask = 0xff
        dst_height = 0x100
    elif mode == 1:
        wrapmask = clipmask = 0x1ff
    elif mode == 4:
        wrapmask = clipmask = 0xff
        wrap500 = True
    else:
        wrapmask = clipmask = 0x3ff
    if ctrl & 4:
        clipmask = 0
    if not swap:
        line_start, line_end = 0, H - 1
        scroll_corr, offs = map_scrollx, map_scrolly
        if flipx:
            scroll_corr = -scroll_corr
        if flipy:
            adv = -adv
            offs += H - 1
        dst_wrapmask, passes = 0xffffffff, 1
        flip = flipx
    else:
        line_start, line_end = X0, X0 + W - 1
        scroll_corr, offs = map_scrolly, map_scrollx
        if flipy:
            scroll_corr = 0x100 - scroll_corr - 2
            offs -= 5
        if flipx:
            adv = -adv
            offs += X0 + W - 1
        if clipmask:
            dst_wrapmask, passes = dst_height - 1, 2
        else:
            dst_wrapmask, passes = 0xffffffff, 1
        flip = flipy
    offs = (offs * 4) & 0x7ff
    offs += line_start * adv
    for line_pos in range(line_start, line_end + 1):
        offs &= 0x7ff
        color = line_ram[offs]
        o = offs
        offs += adv
        if color == 0xffff:
            continue
        offset = line_ram[o + 1]
        if not (color & 0xff) and not offset:
            continue
        base = (offset << 8) % LVC_ROM_NIBBLES
        zoom = line_ram[o + 2]
        scroll = s16(line_ram[o + 3])
        if wrap500 and scroll >= 0x500:
            scroll -= 0x800
        scroll = (scroll + scroll_corr) & dst_wrapmask
        if scroll & 0x80000000:
            scroll -= 1 << 32

        def nib(i, base=base):
            b = rom[((base + i) % LVC_ROM_NIBBLES) >> 1]
            return (b >> 4) if (base + i) % 2 == 0 else (b & 0xf)
        nib.base = base
        mark = np.zeros((H, W), np.int64)
        for _ in range(passes):
            lvc_scanline(mark, line_pos, None, scroll, zoom, clipmask, wrapmask, swap, flip, nib)
            scroll -= dst_height
        sel = mark != 0
        pen[sel] = mark[sel]
        col[sel] = color & 0x1f
    return pen, col


def draw_sprites(st, obj, rgb, mix, tile_pri, lp_sorted, cb_obj):
    """k053247_sprites_draw_common and draw_single_sprite_gxcore for unzoomed, unflipped-
    screen sprites, with pdrawgfx's priority: tile_pri holds the OR of 1<<plane of the
    opaque layers; a sprite pixel sets it to 31, so the first sprite drawn there wins."""
    ram = [st.mem.get(0x090000 + 2 * i, 0) for i in range(0x4000)]
    # xexex.cpp object_dma
    dst = []
    for e in range(256):
        src = ram[e * 0x40:e * 0x40 + 16]
        if src[0] & 0x8000:
            dst.append([src[2 * k] for k in range(8)])
    regs = [0] * 8
    for i in range(4):
        w = st.mem.get(0x0c2000 + 2 * i, 0)
        regs[2 * i], regs[2 * i + 1] = w >> 8, w & 0xff
    assert not regs[5] & 3, "sprite flip screen not modelled"
    offx = (regs[0] << 8 | regs[1]); offx -= 0x10000 if offx & 0x8000 else 0
    offy = (regs[2] << 8 | regs[3]); offy -= 0x10000 if offy & 0x8000 else 0
    act = [d for d in dst if d[0] & 0x8000 and (d[0] & 0xff) != 0]     # z rejection 0
    # descending z, as the swap sort leaves it; drawn from the end (smallest z first)
    for y in range(len(act) - 1):
        for x in range(y + 1, len(act)):
            if (act[y][0] & 0xff) <= (act[x][0] & 0xff):
                act[y], act[x] = act[x], act[y]
    pri = tile_pri.copy()
    for d in reversed(act):
        code, colour = d[1], d[6]
        xa = (code & 1) + (code >> 1 & 2) + (code >> 2 & 4)
        ya = (code >> 1 & 1) + (code >> 2 & 2) + (code >> 3 & 4)
        code &= ~0x3f
        oy, ox = d[2] & 0x3ff, d[3] & 0x3ff
        flipx, flipy = d[0] & 0x1000, d[0] & 0x2000
        mirrorx, mirrory = colour & 0x4000, colour & 0x8000
        if mirrorx:
            flipx = 0
        ox = (ox - offx) & 1023
        oy = (-oy - offy) & 1023
        if ox >= 1024 - 384: ox -= 1024
        if oy >= 1024 - 512: oy -= 1024
        width, height = 1 << (d[0] >> 8 & 3), 1 << (d[0] >> 10 & 3)
        scaley = d[4] & 0x3ff
        zoomy = (0x400000 + (scaley >> 1)) // scaley if scaley else 0x800000
        if not d[0] & 0x4000:
            scalex = d[5] & 0x3ff
            zoomx = (0x400000 + (scalex >> 1)) // scalex if scalex else 0x800000
        else:
            zoomx = zoomy
        ox += SPR_DX
        oy -= SPR_DY
        ox -= (zoomx * width) >> 13        # the position is the centre
        oy -= (zoomy * height) >> 13
        spri = (colour & 0x3e0) >> 4
        if spri <= lp_sorted[3]: pmask = 0
        elif spri <= lp_sorted[2]: pmask = 0xff00
        elif spri <= lp_sorted[1]: pmask = 0xff00 | 0xf0f0
        elif spri <= lp_sorted[0]: pmask = 0xff00 | 0xf0f0 | 0xcccc
        else: pmask = 0xff00 | 0xf0f0 | 0xcccc | 0xaaaa
        pmask |= 1 << 31
        col = cb_obj | (colour & 0x1f)
        shadow = (colour >> 10) & 3
        assert not (mirrorx or mirrory), "mirrored sprite not modelled"
        for cy in range(height):
            sy0 = oy + ((zoomy * cy + (1 << 11)) >> 12)
            zh = (oy + ((zoomy * (cy + 1) + (1 << 11)) >> 12)) - sy0
            for cx in range(width):
                sx0 = ox + ((zoomx * cx + (1 << 11)) >> 12)
                zw = (ox + ((zoomx * (cx + 1) + (1 << 11)) >> 12)) - sx0
                if zw < 1 or zh < 1:
                    continue
                tc = code + XOFFS[((width - 1 - cx) if flipx else cx) + xa & 7] \
                          + YOFFS[((height - 1 - cy) if flipy else cy) + ya & 7]
                stepx, stepy = (16 << 16) // zw, (16 << 16) // zh     # drawgfxzoom_core
                for py in range(zh):
                    yy = sy0 + py
                    if not 0 <= yy < H: continue
                    srcy = (zh - 1) * stepy - py * stepy if flipy else py * stepy
                    row = srcy >> 16
                    base = ((tc * 16 + row) * 8) % len(obj)
                    rb = obj[base:base + 8]
                    for px in range(zw):
                        xx = sx0 + px - X0
                        if not 0 <= xx < W: continue
                        srcx = (zw - 1) * stepx - px * stepx if flipx else px * stepx
                        sxp = srcx >> 16
                        n = SPR_X[sxp]
                        b = int(rb[n >> 1])
                        pen = (b >> 4) if n & 1 == 0 else (b & 0xf)
                        if pen == 0: continue
                        if not ((1 << (int(pri[yy, xx]) & 0x1f)) & pmask):
                            if shadow and pen == 15:
                                mix[yy, xx] = mix[yy, xx]   # shadow: not modelled yet
                            else:
                                mix[yy, xx] = rgb[(col * 16 + pen) & 0x7ff]
                            if SRC is not None:
                                SRC[yy, xx] = (tc, row, sxp, pen)
                        pri[yy, xx] = 31


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("state")
    ap.add_argument("--snap")
    ap.add_argument("--out")
    ap.add_argument("--sprites", action="store_true")
    ap.add_argument("--obj", default=str(Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex"))
                                         / "bench" / "video" / "obj.bin"))
    ap.add_argument("--tiles", default=str(Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex"))
                                           / "bench" / "video" / "tiles.bin"))
    ap.add_argument("--lvc", default=str(Path(os.environ.get("XEXEX_WORK", "D:/jtcores-work/xexex"))
                                         / "bench" / "video" / "lvc.bin"))
    a = ap.parse_args()
    st = State(a.state)
    rom = np.frombuffer(Path(a.tiles).read_bytes(), "<u4")
    out = Path(a.out or Path(a.state).with_suffix(""))
    out.mkdir(parents=True, exist_ok=True)
    rgb = st.colours()
    pidx = st.palette_index()
    colorbase = [0x70, pidx[2], pidx[3], pidx[4]]
    layers = {}
    for l in range(4):
        pen, col, alp = render_layer(st, rom, l, colorbase[l])
        layers[l] = (pen, col, alp)
        img = rgb[(col.astype(np.int64) * 16 + pen) & 0x7ff]
        img[pen == 0] = (255, 0, 255)
        Image.fromarray(img).save(out / f"layer{l}.png")
    np.savez(out / "layers.npz", **{f"pen{l}": layers[l][0] for l in range(4)},
             **{f"col{l}": layers[l][1] & 0xf for l in range(4)}, **{f"alp{l}": layers[l][2] for l in range(4)})
    lvc_rom = np.frombuffer(Path(a.lvc).read_bytes(), np.uint8)
    lvc_pen, lvc_col = render_lvc(st, lvc_rom)
    lvc_cb = pidx[1]                            # bg_colorbase: K053251 CI1
    img = rgb[(lvc_cb * 16 + lvc_col * 16 + lvc_pen) & 0x7ff]
    img[lvc_pen == 0] = (255, 0, 255)
    Image.fromarray(img).save(out / "lvc.png")
    np.savez(out / "lvc.npz", pen=lvc_pen, col=lvc_col)
    # screen_update
    bg = ((st.k338[0] & 0xff) << 16) | st.k338[1]
    mix = np.zeros((H, W, 3), np.uint8)
    mix[:] = (bg >> 16 & 0xff, bg >> 8 & 0xff, bg & 0xff)
    order = [1, 2, 3, -1]
    pri = [st.k251[2], st.k251[3], st.k251[4], st.k251[1]]
    # konami_sortlayers4: unrolled bubble sort, swapping on <=
    pairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
    for p0, p1 in pairs:
        if pri[p0] <= pri[p1]:
            pri[p0], pri[p1] = pri[p1], pri[p0]
            order[p0], order[p1] = order[p1], order[p0]
    cur_alpha = not st.ctrl2 & 0x200        # xexex.cpp control2_w
    tile_pri = np.zeros((H, W), np.int64)
    for plane, l in enumerate(order):
        if l < 0:                               # the K053250 sets the priority, not ORs it
            draw = lvc_pen != 0
            px = rgb[(lvc_cb * 16 + lvc_col * 16 + lvc_pen) & 0x7ff]
            mix[draw] = px[draw]
            tile_pri[draw] = 1 << plane
            continue
        pen, col, alp = layers[l]
        draw = pen != 0
        if cur_alpha and l == 1:
            draw &= alp == 0                    # TILEMAP_DRAW_CATEGORY(0)
        px = rgb[(col.astype(np.int64) * 16 + pen) & 0x7ff]
        mix[draw] = px[draw]
        tile_pri[draw] |= 1 << plane
    if a.sprites:
        draw_sprites(st, np.frombuffer(Path(a.obj).read_bytes(), np.uint8), rgb, mix, tile_pri, pri,
                     pidx[0])
    if cur_alpha:
        # k054338 set_alpha_level(1) & 0xff: register 13's low byte, 5 bits expanded
        lv = st.k338[13] & 0x1f
        alpha = (lv << 3) | (lv >> 2)
        if alpha > 0:
            pen, col, alp = layers[1]
            sel = (pen != 0) & (alp == 1)
            src = rgb[(col.astype(np.int64) * 16 + pen) & 0x7ff].astype(np.int64)
            dst = mix.astype(np.int64)
            blend = (src * alpha + dst * (256 - alpha)) >> 8     # alpha_blend_r32
            mix[sel] = blend[sel].astype(np.uint8)
    pen, col, _ = layers[0]
    px = rgb[(col.astype(np.int64) * 16 + pen) & 0x7ff]
    mix[pen != 0] = px[pen != 0]
    Image.fromarray(mix).save(out / "mix.png")
    print(f"order {order} + 0, pri {pri}, colour bases {colorbase}, bg {bg:06x}, "
          f"ctrl2 {st.ctrl2:04x}, reg0 {st.regs[0]:02x} reg5 {st.regs[5]:02x}")
    if a.snap:
        ref = np.array(Image.open(a.snap).convert("RGB"))
        d = np.any(ref != mix, -1)
        print(f"mix differs from {a.snap} in {d.sum()} of {d.size} pixels")
        diff = np.where(d[..., None], ref, ref // 4)
        Image.fromarray(np.concatenate([ref, mix, diff], 1)).save(out / "cmp.png")


if __name__ == "__main__":
    main()
