# Regression: Foundation rewrite (u32 Array / Comparable-Hashable on Object /
# optional .xtc.iface round-trip) broke 3 toolkit tests

**17/17 before the Foundation rewrite → 14/17 after.** Reproduces in the UNTOUCHED
`~/src/atari/XT/Rocks/xtg` tree, so it is not the XG repo move.

## Reproduce

    ~/src/atari/XT/Rocks/spikes/frun.sh        # builds the 3 cases, runs them on the loader

## The three failures (all against the current installed xtc)

| test | symptom |
|---|---|
| `libdemo` | behavioural: click → target/action → `drawRect` never fires — `clicks=0 draws=0`. The **library-linked** case (`#import <XG>`, override called back across the `.so`). |
| `test_alert` | `DATA-ABORT  PC=0x021bd6a4  CALLER=0x00000001  DFAR=0x33010240` |
| `test_clip`  | `DATA-ABORT  PC=0x0219f4c0  CALLER=0x33000320  DFAR=0x33000000` |

Both aborts are **jumps/reads through a corrupted pointer** — `DFAR=0x33xxxxxx`,
`CALLER` garbage. `0x33` = ASCII `'3'`; `test_alert`'s tree starts `[3]…` (icon 3),
so DATA may be landing in a pointer slot. The two crashes are in **unrelated
subsystems** (modal alert vs child-clipping), which argues for a shared low-level
cause, not three separate bugs.

## What is RULED OUT (all PASS standalone on arm9 against the new Foundation)

Minimal single-module repros of each mechanism work correctly:
- plain virtual override dispatch through a base ref  → ok
- protocol-method dispatch through a protocol ref     → ok
- `^` bound method `(recv, code)` call                → ok
- **optional** protocol method via `&d.method` bound pointer, tested then called → ok

So the mechanisms are individually sound; the break only manifests in the **full
toolkit** context.

## Suspects (compiler thread's call)

- The Foundation rewrite: `Array` `u16→u32`, and `Object <Hashable, Comparable>`
  (base-class conformance/itable layout changed).
- The `optional`-method `.xtc.iface` round-trip (Task #618). `libdemo` is the one
  that crosses the `.so`; but `test_alert`/`test_clip` are **source imports** and
  still crash, so it is not *purely* the cross-`.so` path.

Bisect target is clean: the toolkit was 17/17 immediately before these compiler/
Foundation changes.

## Update: stale libraries RULED OUT

A full clean rebuild — `rm -rf build-xtg`, fresh `libGEM.so`/`libc.so`/`libxtos.so`,
`make clean && make` on the toolkit, all against the stable current `xtc` — reproduces
the **identical** crash addresses (`PC`/`DFAR` byte-for-byte stable across rebuilds). So
it is a **deterministic miscompile**, not stale-library skew and not a memory-corruption
race. A stable wild jump to `0x33xxxxxx` points at one specific mis-lowered call site
(a function-pointer / vtable-slot / bound-method target computed wrong, the same way
every build).

Separately: the **Comparable-on-import** error WAS stale-library skew — `libXtg.so` built
moments before a compiler reinstall had a `.xtc.iface` the newer binary rejected. Rebuilding
the library against the current `xtc` clears it. That one is not a compiler bug; the runtime
`0x33xxxxxx` regression is.

## RESOLVED — root cause found, and it is NOT the compiler (I misdiagnosed)

Diagnosed by the compiler thread via gdb; recording the correction because this file's earlier
conclusion was **wrong**.

`0x33000000` is **`WALLPAPER_BASE`**, read *correctly* from `sys_fb_wallpaper` — not a corrupted
pointer, and the `'3'` is just its high byte. The `DATA-ABORT` is because a **same-day kernel
change** — commit `23f74b4`, "gemd: M7 — the engine composite and the SEC_PLANE gate" (14:05) —
flipped the wallpaper region to `SEC_PLANE_CK` = **PL1-RW / PL0-none** (descriptor `0x1C12 →
0x141E`, matching `L1[sec]=0x3300141e` exactly), granting PL0-RW only to the display owner
(gemd). `test_clip`/`test_alert` draw **directly into the wallpaper** from a non-owner process,
so the write faults. The regression merely *coincided* with the Foundation rewrite; the cause was
the M7 plane-isolation gate.

**My two red herrings, retracted:** (1) the "deterministic miscompile / layout-sensitivity" was
me toggling whether the stripped test *drew into the plane* at all, not register allocation; (2)
"`0x33` = string bytes" was coincidence — it is `WALLPAPER_BASE`. Confirmed from the test side:
pointing `bb.px` at a PL0-RW **heap** buffer instead of the wallpaper makes `test_clip` pass.

**The gate is correct** — it enforces "only gemd touches the plane" (RESPONSIBILITIES rule 1),
which `test_clip`/`test_alert` were quietly violating. The fix is on the toolkit side: a client
must draw into a surface it owns, never the plane.
