#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff the RTL 68000's trace against MAME's (scripts/boot_trace.py).

    python scripts/compare_trace.py work/mame/boot-xexex-maincpu/boot.trace bench/main_boot/rtl.trace
    python scripts/compare_trace.py --frames <mame trace> <rtl trace>     # past the first interrupt
    python scripts/compare_trace.py --z80 work/mame/boot-xexex-audiocpu_600/boot.trace bench/snd_boot/rtl.trace

Both files: seq rw addr mask data frame line. Adapted from the mister-arcade-core
skill's compare_boot_trace.py, which says why each check is shaped as it is:

  * writes, strictly in order: address, byte lanes, data under the mask;
  * non-ROM reads (RAM and I/O), in order;
  * ROM reads as a superset: two correct 68000 models prefetch differently, so every
    ROM word MAME read inside the RTL's window must have been read by the RTL too.

The RTL trace is compared up to the MAME access that made the RTL's last write.

--frames: once interrupts run, MAME's 68000 and fx68k take an interrupt an instruction or
so apart, so the stacked PC and SR, and the task switcher's copy of them, differ; the
program does not. From the first vector fetch, writes are compared per frame as
multisets, leaving out the two stacks (08fd00-08ffff); the stack writes that differ
are counted. Before it, the comparison is strict as above.

--z80: the sound CPU. Its ROM is 0000-bfff; reads of the chips (e000-efff) are counted,
not compared, because how often a status bit is polled depends on the chip's busy time.
"""
import sys

# the vector table (000000-0000ff) is compared as I/O: interrupts show as vector fetches
ROM = [(0x000100, 0x07ffff), (0x100000, 0x17ffff)]
POLLED = []          # reads counted, not compared


def load(path):
    rows = []
    for ln in open(path, encoding="utf8"):
        if ln.startswith("#") or not ln.strip():
            continue
        seq, rw, a, m, d, fr, line = ln.split()
        m = int(m, 16)
        rows.append((int(seq), rw.upper(), int(a, 16), m, int(d, 16) & m, int(fr), int(line)))
    return rows


def is_rom(a):
    return any(lo <= a <= hi for lo, hi in ROM)


def compare_frames(mame, rtl):
    """Strict up to the first interrupt, then per-frame write multisets without the stacks."""
    import collections
    vec = lambda r: r[1] == "R" and r[2] in (0x70, 0x74, 0x78) and r[3] == 0xffff  # noqa: E731
    stack = lambda a: 0x08fd00 <= a <= 0x08ffff  # noqa: E731
    def split(rows):
        i = next((k for k, r in enumerate(rows) if vec(r)), len(rows))
        return rows[:i], rows[i:]
    m0, m1 = split(mame)
    r0, r1 = split(rtl)
    mw = [r[2:5] for r in m0 if r[1] == "W"]
    rw = [r[2:5] for r in r0 if r[1] == "W"]
    k = min(len(mw), len(rw))
    bad = next((i for i in range(k) if mw[i] != rw[i]), None)
    ok = bad is None and len(mw) == len(rw)
    print(f"BEFORE IRQ {len(rw)} writes, MAME {len(mw)}: " +
          ("identical in order" if ok else f"first difference at write {(bad if bad is not None else k) + 1}"))
    first_frame = m1[0][5] if m1 else None
    last = min(m1[-1][5] if m1 else 0, r1[-1][5] if r1 else 0) - 1   # the last frame both finish
    fm, fr = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    for rows, acc in ((m1, fm), (r1, fr)):
        for r in rows:
            if r[1] == "W" and r[5] <= last:
                acc[r[5]][r[2:5]] += 1
    frames = [f for f in range(first_frame, last + 1)] if first_frame is not None else []
    diff_frames, stack_diffs, other = 0, 0, collections.Counter()
    for f in frames:
        d = (fm[f] - fr[f]) + (fr[f] - fm[f])
        for (a, m, v), n in d.items():
            if stack(a):
                stack_diffs += n
            else:
                other[a] += n
        if any(not stack(a) for (a, _, _) in d):
            diff_frames += 1
    nw = sum(sum(c.values()) for f, c in fm.items() if f in frames)
    print(f"FROM IRQ  frames {first_frame}-{last}: {nw} MAME writes; "
          f"{diff_frames} frames differ outside the stacks; {stack_diffs} stack writes differ")
    for a, n in other.most_common(10):
        print(f"    {a:06X}: {n}")
    return 0 if ok and diff_frames == 0 else 1


def show(i, a, b):
    fmt = lambda r: f"{r[1]} {r[2]:06X} {r[3]:04X} {r[4]:04X} f{r[5]} l{r[6]}"  # noqa: E731
    print(f"    #{i + 1:<7} MAME {fmt(a)}   RTL {fmt(b)}")


def main():
    global ROM, POLLED
    args = sys.argv[1:]
    per_frame = "--frames" in args
    args = [x for x in args if x != "--frames"]
    if args and args[0] == "--z80":
        args = args[1:]
        ROM, POLLED = [(0x0000, 0xbfff)], [(0xe000, 0xefff)]
    mame, rtl = load(args[0]), load(args[1])
    if per_frame:
        return compare_frames(mame, rtl)
    polled = lambda a: any(lo <= a <= hi for lo, hi in POLLED)  # noqa: E731
    if not rtl:
        sys.exit("the RTL trace is empty")
    rc = 0
    mw = [r for r in mame if r[1] == "W"]
    rw_ = [r for r in rtl if r[1] == "W"]
    n = len(rw_)
    key = lambda r: r[2:5]  # noqa: E731
    first = next((i for i in range(min(n, len(mw))) if key(rw_[i]) != key(mw[i])), None)
    if first is None and n <= len(mw):
        print(f"WRITES    {n} of {n} match MAME in address, lanes, data and order")
    else:
        rc = 1
        if first is None:
            print(f"WRITES    the RTL made {n} writes, MAME only {len(mw)} in its trace")
        else:
            print(f"WRITES    MISMATCH at write {first + 1} of {n}:")
            for i in range(max(0, first - 3), min(first + 4, n, len(mw))):
                show(i, mw[i], rw_[i])

    wseen, cut = 0, len(mame)
    for i, r in enumerate(mame):
        if r[1] == "W":
            wseen += 1
            if wseen == n:
                cut = i + 1
                break
    window = mame[:cut]

    # both sides up to their n-th write
    rcut = next((i + 1 for i, r in enumerate(rtl) if r[1] == "W" and r is rw_[n - 1]), len(rtl)) if n else len(rtl)
    mio = [r for r in window if r[1] == "R" and not is_rom(r[2]) and not polled(r[2])]
    rio = [r for r in rtl[:rcut] if r[1] == "R" and not is_rom(r[2]) and not polled(r[2])]
    if POLLED:
        print(f"POLLED    chip reads, MAME {sum(1 for r in window if r[1] == 'R' and polled(r[2]))}, "
              f"RTL {sum(1 for r in rtl[:rcut] if r[1] == 'R' and polled(r[2]))} (not compared)")
    k = min(len(mio), len(rio))
    bad = next((i for i in range(k) if key(mio[i]) != key(rio[i])), None)
    if bad is None and len(mio) == len(rio):
        print(f"RAM/IO RD {len(rio)} of {len(rio)} match MAME in order")
    else:
        rc = 1
        at = bad if bad is not None else k
        print(f"RAM/IO RD MAME {len(mio)}, RTL {len(rio)}; first difference at read {at + 1}:")
        for i in range(max(0, at - 3), min(at + 4, k)):
            show(i, mio[i], rio[i])

    mrom = {(r[2], r[3]) for r in window if r[1] == "R" and is_rom(r[2])}
    lanes = {}
    for r in rtl:
        if r[1] == "R" and is_rom(r[2]):
            lanes[r[2]] = lanes.get(r[2], 0) | r[3]
    missing = sorted(x for x in mrom if x[1] & ~lanes.get(x[0], 0))
    if missing:
        rc = 1
        print(f"ROM       {len(mrom) - len(missing)} of {len(mrom)} of MAME's ROM reads also made by "
              f"the RTL; first missing {missing[0][0]:06X} {missing[0][1]:04X}")
    else:
        print(f"ROM       all {len(mrom)} of MAME's distinct ROM reads in the window made by the RTL")

    last_m, last_r = window[-1], rtl[rcut - 1]
    tm = last_m[5] * 289 + (last_m[6] - 256) % 289   # lines since reset (frame 0 starts at line 256)
    tr = last_r[5] * 289 + (last_r[6] - 256) % 289
    print(f"at write {n}: RTL access {rcut}, frame {last_r[5]} line {last_r[6]}; "
          f"MAME access {cut}, frame {last_m[5]} line {last_m[6]}; "
          f"RTL/MAME time {tr / max(tm, 1):.3f} ({tr} and {tm} lines)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
