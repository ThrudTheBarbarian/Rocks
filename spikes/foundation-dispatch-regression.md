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
