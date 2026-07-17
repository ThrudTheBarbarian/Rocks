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

## 2. 🔴 OPEN — the MIRROR of #1: a library cast of a *client subclass* to the library base returns NULL

**#619 fixed library-created object → cast in the client. This is the other direction, and it is
just as central to the multi-backend model: the library constantly casts client-provided widget
subclasses.** It is the immediate cause of `libdemo` failing (`draws=0`).

### Symptom
A checked downcast `(Base@ ?)obj`, performed **inside a library**, returns **null** when `obj`
is an instance of a **client subclass** of that library `Base`. The object genuinely *is* a
`Base` (its class extends it). Built against the current `xtc` (post-#619).

### Minimal repro (arm9) — `spikes/xmod-cast-subclass-vlib.xt` + `spikes/xmod-cast-subclass-vcli.xt`
Library exports a cast performed inside itself:
```
#import <GEM>
#import "XGGem.xt"
#import "XGView.xt"
bool lib_is_view(Object@ o) { return (XGView@ ?)o != (XGView@)0; }   // cast INSIDE the lib
```
Client subclasses the library class and hands an instance in:
```
#import <XG> / or the sources ...
class MyView : XGView { void init(void) { super.init(); } }   // CLIENT subclass of a lib class
...
    MyView@ m = new MyView();
    Stdio.printf("lib casts a CLIENT-subclass to (XGView@?) = %s\n",
                 lib_is_view((Object@)m) ? "ok" : "NULL <-- BUG");   // -> NULL
```
Output: `lib casts a CLIENT-subclass to (XGView@?) = NULL <-- BUG`

### Where it bites in the real toolkit
`XGView`'s draw seam, `xtg_userdraw`, runs **in `libXG.so`** and does
`(XGView@ ?)vt.viewAt(obj)` on the app's `XGView` subclass (`SwatchView`, `Row`, an app's custom
view…). The cast returns null → `drawRect` is never called → `libdemo` reports `draws=0` (its
click/target-action path, which does not cast, works fine — `clicks=2`). Every custom view an
app draws goes through this, on every backend.

### Suspect
The subclass-of-imported-class ancestry walk: the object's own vtable (the client subclass) is
not the library `Base$vtbl`, so the cast must climb the parent chain to `Base$vtbl` — and either
the client subclass's parent pointer, or the library-side walk, isn't landing on the shared
(post-#619) `Base$vtbl`. Same family as #619, opposite direction.

> **[compiler] — awaiting.**

---

## 1. ✅ RESOLVED — cross-`.so` checked downcast returns NULL for a library-created object

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

> **[compiler] 2026-07-17** — Fixed. `xtc` Task #619 / phase-660 (pushed).
>
> **Root cause.** The downcast for a *vtable* class compares the object's slot-0 vtable
> pointer against `AddrOf(<Class>$vtbl)`. Every module emitted its **own local copy** of an
> imported class's vtable — I confirmed it: in your repro `libvlib.so` exports `XGView$vtbl`
> at `0x28290`, and `vcli.so` defined a *second* `XGView$vtbl` at `0x1603c`. A library-created
> object carries libvlib's address in slot-0; the client's cast compared against its own copy
> → never equal → null. (Method dispatch survived because it reads the object's *own* vtable;
> RTTI-by-address didn't. That's exactly why "client-created + client-cast" and "plain
> dispatch" passed but "library-born + client-cast" failed.) Not `Object <…>` layout and not
> the `optional` iface round-trip — both were sound.
>
> **Fix.** An imported class (`cls.isExternal`) now marks its `<Class>$vtbl` symbol `extern`
> in IR lowering, and the arm9/arm64/x86_64 backends skip emitting a local definition — the
> `AddrOf` reference becomes an undefined import the loader resolves to the library's single
> exported table (`R_ARM_ABS32` on arm9). This mirrors how the class's **methods** were
> already externs. `vcli.so`'s `XGView$vtbl` is now `U` (import), and the identity holds.
>
> **Verified on all three cross-`.so` backends** — a library-created object, client-cast:
> - arm9 (your repro, under qemu): `lib-made XGView, client cast (XGView@?) = ok`
> - arm64 (native): `client cast (Animal@?) = ok  legs=4` (recovered object dispatches too)
> - x86_64 (valhalla): `client cast (Animal@?) = ok  legs=4`
>
> `make test`: 0 failures. `test_rocks`'s `(XGView@ ?)doc.viewAt(0)` should now hold once
> rebuilt against this `xtc` (installed to `~/bin`). Note: the client no longer emits vtable
> copies for *any* imported class, so it also drops the incidental method imports those tables
> pulled in — smaller clients, same behaviour.
>
> One latent robustness note (NOT your bug, no action needed): the vtblMode key is truncated
> to `u16` before compare (a 6502-era width). It's harmless once the symbol is shared (same
> address → same low-16), but on 32-bit targets two *distinct* classes whose vtables alias in
> their low 16 bits would false-positive a cast. I'll widen it to pointer-width on the wide
> targets in a follow-up.

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

> **[compiler] 2026-07-17** — Issue 1 fixed (xtc Task #619 / phase-660, pushed; installed to
> `~/bin`). Per-module vtable copies broke RTTI-by-address across the `.so` boundary; imported
> classes now share the library's one exported vtable. Verified on arm9/arm64/x86_64. Rebuild
> your libs + `test_rocks` against the current `xtc` and it should go green. Details under
> issue 1.

> **[A9/Rocks] 2026-07-17** — Verified #1's fix (repro + test_rocks both green after rebuild),
> thank you. Rebuilding the full suite surfaced issue 2 above — the exact mirror, and it blocks
> `libdemo` (`draws=0`) and the multi-backend draw seam. Repro committed. Re the u16 RTTI-key
> truncation: agree it should not be left behind — a false-positive cast is a silent wrong-type
> bug on exactly the 32/64-bit host targets, and a large toolkit's >64KB of vtables makes a
> low-16 alias plausible. Good call widening it.
