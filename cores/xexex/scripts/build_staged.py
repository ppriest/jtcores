#!/usr/bin/env python3
"""Build a jtframe core from a worktree of HEAD, on Windows.

    python cores/xexex/scripts/build_staged.py                  # xexex, mister
    python cores/xexex/scripts/build_staged.py --target pocket
    python cores/xexex/scripts/build_staged.py --seed 7
    python cores/xexex/scripts/build_staged.py --allow-dirty    # HEAD, edits excluded

Each target has its own persistent worktree, $JTCORES_BUILD/<target> (default
D:/jtcores-build, off the cores' shared E: volume), hard-reset
to HEAD on every run, so the main tree is free during the compile and every
.rbf maps to one commit (BUILT_COMMIT beside the outputs).

jtcore runs from Git Bash with Quartus 20.1. What it needs on Windows:
  * JTROOT in MSYS form (/e/...): a drive colon would split PATH. Native
    programs are handed E:/... by MSYS.
  * the jtframe binary copied in: the jtframe wrapper otherwise rebuilds it and
    runs its tests first, two of which fail on Windows over path separators.
  * register files for shared modules (jtframe mmr -m), which jtcore does not
    generate.
  * --nolinter: the linter needs a Linux Verilator setup.

Outputs, in <worktree>/cores/<core>/<target>/output_files/, and the log and
timing report in <worktree>/log/<target>/. The result line gives the game
clock's worst setup slack; a negative slack is a failed build.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
QUARTUS = "/c/intelFPGA_lite/20.1/quartus/bin64"
GO = "/c/Program Files/Go/bin"
BASH = r"C:\Program Files\Git\bin\bash.exe"
HWLOCK_DIR = Path("E:/Arcade-BallySente_MiSTer/scripts")
SUBMODULES = ["modules/fx68k", "modules/jt51", "modules/jteeprom"]
MMR_MODULES = []   # shared modules whose register files jtcore does not generate
JTFRAME_BIN = "modules/jtframe/src/jtframe/jtframe.exe"
# jtcore makes it with make from modules/jtframe/cc, which Git Bash lacks; build it
# once under MSYS2: gcc -O2 -o bin/reverse_bits.exe cc/reverse_bits.c
REVERSE_BITS = "modules/jtframe/bin/reverse_bits.exe"
# the game clock's PLL in each target's timing summary
# (every output of it: 48 MHz, and 96 MHz under JTFRAME_SDRAM96)
GAME_CLOCK = {"mister": r"emu\|pll\|pll_inst\|altera_pll_i\|general\[\d+\]",
              "pocket": r"u_clocks\|u_pll_game"}


def worktree(target: str) -> Path:
    return Path(os.environ.get("JTCORES_BUILD", "D:/jtcores-build")) / target


def staged_dir(target: str, core: str = "xexex") -> Path:
    """cores/<core>/<target> in the target's worktree: output_files/ and BUILT_COMMIT."""
    return worktree(target) / "cores" / core / target


def staged_log(target: str, corename: str = "jtxexex") -> Path:
    """Quartus's own log, which carries the success line deploy.py checks."""
    return worktree(target) / "log" / target / f"{corename}.log"


def git(*args, cwd=REPO, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check,
                          capture_output=True, text=True).stdout.strip()


def msys(p: Path) -> str:
    s = str(p).replace("\\", "/")
    return "/" + s[0].lower() + s[2:] if re.match(r"^[A-Za-z]:", s) else s


def stage(target: str) -> Path:
    wt = worktree(target)
    head = git("rev-parse", "HEAD")
    if not (wt / ".git").exists():
        wt.parent.mkdir(parents=True, exist_ok=True)
        git("worktree", "add", "--detach", str(wt), head)
    git("config", "core.autocrlf", "false", cwd=wt)
    git("reset", "-q", "--hard", head, cwd=wt)
    git("submodule", "update", "--init", *SUBMODULES, cwd=wt)
    src = REPO / JTFRAME_BIN
    if not src.exists():
        sys.exit(f"missing {src}: build it with go build in modules/jtframe/src/jtframe")
    dst = wt / JTFRAME_BIN
    shutil.copy2(src, dst)
    os.utime(dst)          # newer than every .go file, so the wrapper does not rebuild
    if target == "pocket":
        if not (REPO / REVERSE_BITS).exists():
            sys.exit(f"missing {REPO / REVERSE_BITS}: see REVERSE_BITS in this script")
        shutil.copy2(REPO / REVERSE_BITS, wt / REVERSE_BITS)
    return wt


def bash_env(wt: Path, target: str) -> str:
    root = msys(wt)
    return (f'export JTROOT={root}; export JTFRAME=$JTROOT/modules/jtframe '
            f'CORES=$JTROOT/cores MODULES=$JTROOT/modules JTBIN=$JTROOT/release '
            f'ROM=$JTROOT/rom TARGET={target}; '
            f'export PATH="{QUARTUS}:{GO}:$PATH:$JTFRAME/bin"; cd $JTROOT; ')


def worst_slack(summary: Path, target: str):
    """The worst Setup slack, and the TNS summed, over the game PLL's outputs and every
    timing model in the summary."""
    if not summary.exists():
        return None
    text = summary.read_text(errors="replace")
    m = re.findall(r"Type\s*:[^\n]*Setup '" + GAME_CLOCK[target] + r"[^']*'\s*"
                   r"Slack\s*:\s*(-?[\d.]+)\s*TNS\s*:\s*(-?[\d.]+)", text)
    if not m:
        return None
    return min(float(x) for x, _ in m), sum(float(t) for _, t in m)


def implicit_nets(outdir: Path, core: str):
    """Quartus warnings 10236 (implicit net) in the core's own files."""
    rpt = next(iter(sorted(outdir.glob("*.map.rpt"))), None)
    if rpt is None:
        return []
    return sorted({re.sub(r"\s*File:.*", "", ln.strip()) for ln in rpt.read_text(errors="replace").splitlines()
                   if "(10236)" in ln and f"/cores/{core}/" in ln.replace("\\", "/")})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", default="xexex")
    ap.add_argument("--target", default="mister")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--debug", action="store_true",
                    help="keep jtframe's debug features (debug_bus, the on-screen debug_view); "
                         "by default the build is a release one (jtcore --nodbg, JTFRAME_RELEASE)")
    a = ap.parse_args()

    if git("status", "--porcelain", "--untracked-files=no") and not a.allow_dirty:
        sys.exit("the tree has uncommitted changes; commit them or pass --allow-dirty")

    sys.path.insert(0, str(HWLOCK_DIR))
    import hwlock
    hwlock.require_no_jtag(f"jtcore {a.core} -{a.target}")

    wt = stage(a.target)
    env = bash_env(wt, a.target)
    for m in MMR_MODULES:
        subprocess.run([BASH, "-c", env + f"jtframe mmr -m {m}"], check=True)

    commit = git("log", "-1", "--format=%h %s", cwd=wt)
    print(f"building {a.core} for {a.target} ({'debug' if a.debug else 'release'}) at {commit} in {wt}", flush=True)
    t0 = time.time()
    out = wt / "log" / a.target / f"{a.core}_staged.log"
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        rc = subprocess.run([BASH, "-c", env + f"jtcore {a.core} -{a.target} --nolinter "
                             f"--seed {a.seed}" + ("" if a.debug else " --nodbg")], stdout=f, stderr=subprocess.STDOUT).returncode

    # MiSTer's outputs are in output_files/, the Pocket's in the build folder itself
    bdir = staged_dir(a.target, a.core)
    outdir = bdir / "output_files" if a.target == "mister" else bdir
    (bdir / "BUILT_COMMIT").write_text(
        f"{git('rev-parse', 'HEAD', cwd=wt)}\n{time.ctime()}\nseed {a.seed}\n")
    rbf = next(iter(sorted(outdir.glob("*.rbf"))), None) if outdir.exists() else None
    slack = worst_slack(next(iter(sorted(outdir.glob("*.sta.summary"))), Path("-")), a.target)
    mins = (time.time() - t0) / 60
    print(f"jtcore exit {rc}, {mins:.1f} min, log {out}")
    print(f"rbf: {rbf}")
    if slack is None:
        print("RESULT: FAIL (no timing summary)")
        sys.exit(1)
    print(f"game clock worst setup slack {slack[0]} ns, TNS {slack[1]} ns")
    # an undeclared multi-bit signal becomes a 1-bit implicit net (warning 10236): the
    # benches, which declare their own wiring, do not see it
    implicit = implicit_nets(outdir, a.core)
    for w in implicit:
        print("implicit net:", w)
    ok = slack[0] >= 0 and rbf and not implicit
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
