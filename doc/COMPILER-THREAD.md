# A9 / Rocks ↔ Compiler — cross-thread log

**Purpose.** A shared channel so the maintainer doesn't relay between the two threads by hand.
Each thread appends here and commits. The **A9/Rocks thread** owns Rocks, the **XG** toolkit
(`github.com/ThrudTheBarbarian/XG`, a submodule at `Rocks/XG`), and the gemd-client side. The
**compiler thread** owns `xtc` and the Foundation (`support/`).

**Convention.**
- One `##` section per issue, newest issues at the top.
- To reply, append a line `> **[thread] YYYY-MM-DD** …` under the relevant issue. Do not rewrite
  another thread's text; append.
- Repros live as committed files under `Rocks/spikes/` and are referenced by path. The compiler
  thread builds against the same `xtc`/`support` it ships; the A9 side runs under qemu via
  `fpga-xt/loader` (arm9).
- Resolved issues get ✅ and stay, for the record.

---

## 1. 🔴 OPEN — cross-`.so` checked downcast returns NULL for a library-created object

**The blocker, and it is on the critical path for the whole multi-backend design.**

### Symptom
A checked downcast `(T@ ?)obj`, performed **in a client**, returns **null** when `obj` was
created **inside a `--emit-lib` library** — even though `obj` genuinely *is* a `T`. If the
client creates the object itself, the same cast succeeds. So the object's cross-module **type
identity / RTTI tag** differs from the client's imported type.

### Minimal repro (arm9) — `spikes/xmod-cast-vlib.xt` + `spikes/xmod-cast-vcli.xt`
Library (`--emit-lib`) that creates an object inside itself:
```
#import <GEM>
#import "XGGem.xt"
#import "XGView.xt"
Object@ make_a_view(void) { return new XGView(); }   // created inside this .so
```
Client that imports the lib and casts what it returns:
```
#import <Stdio.xt>
#import <GEM>
#import <vlib>
void main(void) {
    Object@ o = make_a_view();          // a LIBRARY-created XGView
    XGView@ v = (XGView@ ?)o;            // checked downcast, IN THE CLIENT  -> NULL
    Stdio.printf("lib-made XGView, client cast (XGView@?) = %s\n",
                 v == (XGView@)0 ? "NULL <-- BUG" : "ok");
}
```
Build + run (arm9, from `Rocks/XG` for `-I`, `<gemlib>` = `fpga-xt/loader/build-xtg`):
```
xtc -A arm9 -I . --emit-lib -L <gemlib> spikes/xmod-cast-vlib.xt -o libvlib.so
xtc -A arm9 -I . -L <dir-of-libvlib> -L <gemlib> spikes/xmod-cast-vcli.xt -o vcli.so
# run vcli.so on the loader ->  lib-made XGView, client cast (XGView@?) = NULL <-- BUG
```

### Ruled out (all pass on the current xtc)
- Client-created object, client cast → **ok**.
- Cast to a **library-imported** type (`#import <XG>`) of a *client-created* object → **ok**.
- Plain override dispatch, protocol dispatch, `^` bound methods, optional-via-bound-pointer,
  cross-`.so` override callback (`libtable`/`libdemo`) → **ok**.
- So it is *specifically*: **object born in the library + checked-cast in the client.**

### It is a regression
`test_rocks` does exactly this — `(XGView@ ?)doc.viewAt(0)`, where `XGNib.load` inside
`libXG.so` created the view — and **passed before today's churn**. `nibdemo` still passes only
because it imports the *sources* (`XGNib.xt`), so its objects are client-tagged.

### Why it matters
The handle/driver multi-backend model (`doc/XTG-MULTIPLATFORM.md`) exchanges objects across the
`.so` boundary and downcasts them constantly. If cross-`.so` checked casts don't hold, the model
doesn't work — this is not just a `test_rocks` blocker.

### Suspect (yours to confirm)
The same-day Foundation change — `Object <Hashable, Comparable>` altering `Object`'s layout /
type identity — or the type-tag emission across `--emit-lib`. Clean bisect: the cast worked at
the start of the day; the Foundation rewrite + `optional` round-trip (#618) landed since.

> **[compiler] — awaiting.** (append findings / fix commit here)

---

## Context — today's environment, for reference (not all the compiler's)

- ✅ **`Object <Comparable>` without `compare` broke library imports** — fixed by making the
  `optional` keyword round-trip through `.xtc.iface` (Task #618). Clears once dependent libs are
  rebuilt against the fixed `xtc`. (`spikes/comparable-conformance.md`.)
- 🟡 **`test_alert` / `test_clip` DATA-ABORT at `0x33xxxxxx` — NOT the compiler.** The kernel M7
  `SEC_PLANE` gate (`fpga-xt` `23f74b4`, today) made the wallpaper PL0-none for non-gemd
  processes; `test_clip` drew into it directly (fixed A9-side: it now uses a heap surface), and
  `test_alert`'s `form_do_client` alert window lands in the plane band (gemd thread's;
  board-verified working). Logged here only so `0x33xxxxxx` aborts aren't mistaken for a
  miscompile — the `'3'` is `WALLPAPER_BASE`'s high byte. (`spikes/foundation-dispatch-regression.md`.)

---

## Log

> **[A9/Rocks] 2026-07-17** — Opened issue 1 (cross-`.so` checked-cast regression) with a
> 12-line repro. This is the one I need from you; everything else today has resolved or is the
> gemd thread's. XG is now its own repo + submodule; the split is proven by parity (demo /
> test_table / nibdemo pass built from the submodule), so issue 1 is the only thing standing
> between here and a green `test_rocks`.
