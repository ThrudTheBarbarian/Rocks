# xtc: findings from building Xtg

Everything found while building **Xtg** — an AppKit-style UI toolkit in xtc, over
libGEM, running on XTOS/arm9. Xtg is a deliberately demanding client: it subclasses
library classes across a `.so` boundary, is called *back* by C (the AES), leans on ARC
and `weak:`, and holds hundreds of live objects. It is meant to find the sharp edges.

**Status at a glance.**

| | | |
|---|---|---|
| **A** | `--emit-lib` devirtualises exported methods | ✅ fixed (phase-586) |
| **B** | implicit self-calls devirtualised | ✅ fixed (phase-585) |
| **C** | unknown struct member = note, store dropped | ✅ fixed (phase-592) |
| **E** | `&Class.staticMethod` unsupported, only a note | ✅ fixed (phase-590) |
| **F** | non-weak `^` is a silent UAF | ✅ fixed (phase-594/595) |
| **D** | anonymous enum constants | ✅ xtc side fixed (phase-593) — **remaining half is one flag on libGEM's build, see §1** |
| **1** | **weak-reference table: capped, and O(N) on every store and every dealloc** | 🔴 **OPEN — the one that blocks Xtg at scale** |
| **2** | `-L` absent from `xtc --help` | 🟡 open (doc) |
| **3** | gcc temp object name leaks into the `.so` | 🟡 open (cosmetic; breaks reproducible builds) |
| **4** | cross-`.so` trampoline identity for `^` | ❓ open, unexamined by me |
| **5** | arrays of class instances go silent | ❓ open (yours) — I can reproduce it if useful |

**Verified against xtc `69ec25d`:** all four Xtg programs pass on the real XTOS loader
(`demo`, `nibdemo`, `test_spine` 14/14, `test_window`). A–F are confirmed fixed from
this side.

---

---

# 1. 🔴 The weak-reference table

**This is the one I care about.** Not because it is wrong today — it *works* — but
because Xtg is precisely the workload it cannot carry, and the current shape has three
independent problems, only one of which is the cap.

## What it does now

```c
static struct { void *obj; void **slot; } _xtc_weak_tbl[1024];   /* 64 on m68k */

void _xtc_weak_register(void **slot, void *obj) {
    for (int i=0;i<1024;i++) if (_xtc_weak_tbl[i].slot==slot) { ...clear... }  // scan 1
    if (!obj) return;
    for (int i=0;i<1024;i++) if (!_xtc_weak_tbl[i].slot) { ...store...; return; }  // scan 2
    FATAL("weak-reference table full");
}
```

and `_xtc_weak_zero_for(obj)` scans the whole table on **every dealloc**.

## Three problems, not one

### (a) The cap is a static check on a dynamic quantity

The table is sized in **instances**: one `weak:` field on a class costs one entry *per
object*. Sema's overflow check counts **declarations**. Those are different numbers and
no amount of care will reconcile them — **a static check cannot bound a dynamic
quantity.** Halting loudly beats corrupting silently, but the real answer is not to
have a limit.

### (b) O(N) on every weak store

Two full scans per assignment. Wiring a Rocks-sized UI — ~300 controls, each with one
action — costs **300 × 2 × 1024 ≈ 600,000 iterations** at start-up, to store 300
pointers.

### (c) O(N) on every dealloc — *including objects with no weak refs at all*  ⟵ the worst one

`_xtc_weak_zero_for` is called for **every** object destroyed and scans the entire
table. Closing one Rocks window (say 500 objects in the view tree) costs
**500 × 1024 ≈ 512,000 comparisons** — and 499 of those objects were never weakly
referenced by anything.

**This is the defect that bites even when you are far under the cap.** Every object in
the program pays for a feature it does not use.

## What Xtg actually costs

| | entries |
|---|---|
| each `XGControl` with an action (`weak: XGAction^`) | 1 **per instance** |
| each window's delegate | 1 |
| each view's `nextResponder`… if it were weak | 1 per view |

A Rocks-scale app is **hundreds of live entries**. So:

- **m68k's 64 is dead on arrival** — a *single* moderately complex dialog exceeds it.
- **1024 survives, but only just**, and (b)/(c) still make it quadratic in practice.

## The proposal: delete the table

Do not pick a bigger number. **Remove the number**, by threading an intrusive list
through the weak slots themselves.

- Every object header gains one word: `weak_head`.
- A weak slot becomes **two** words: `{ referent, next_slot }`.

```
    register(slot, o):     slot.referent = o;
                           slot.next = o.weak_head;      // O(1)
                           o.weak_head = &slot;

    overwrite(slot, new):  unlink slot from old.weak_head chain    // O(refs to that
                           register(slot, new);                    //  object) ~ 1

    dealloc(o):            for (s = o.weak_head; s; s = s.next) s.referent = 0;
                           // objects with NO weak refs: one null test.  Free.
```

Which fixes all three at once:

| | now | proposed |
|---|---|---|
| cap | 1024 / 64, and unbounded-able | **none** |
| weak store | O(table) | **O(1)** |
| dealloc, object with no weak refs | **O(table)** | **O(1)** — one null test |
| dealloc, object with *k* weak refs | O(table) | O(k) |
| heap allocation | none | **none** (the nodes *are* the slots) |
| global table | 1024 × 2 words, always | **gone** |

**Cost:** one word per object header, and one extra word per `weak:` field. On 32-bit
that is 4 bytes; on 6502, 2. Note the table it replaces is *already* 8 KB of static RAM
on a 32-bit target (1024 × 2 words), so on any target with more than ~2000 objects the
intrusive form is also **smaller**.

For a weak `^` the slot becomes 3 words — `(recv, code, next)` — which is fine; weak
bound-pointers are rare compared with objects.

**And the sema overflow check should then be deleted, not fixed.** With no cap there is
nothing to check, and (a) says it could never have been sound anyway.

## If the header word is unacceptable on 6502

The fallback is a **growable hash side-table** keyed on the object pointer: no header
cost, no cap, O(1) average register, O(1) average dealloc lookup. It needs a heap and a
rehash, and it is strictly more machinery than the intrusive list — but it is still
strictly better than a fixed array, and it fixes (a), (b) and (c) too.

**What I would not do is raise 64 to 512 and move on.** That trades a hard failure for
a rarer hard failure, and leaves (c) — the one that taxes every object in the
program — completely untouched.

---

# 2. 🟡 `-L` is not in `xtc --help`

`#import <GEM>` is a **library metadata import**: xtc resolves `libGEM.so` on a
*library* path, reads its `.dynsym` ∩ DWARF, and hands back the real C types. It is the
single most valuable thing xtc does for this project — it supplies `theme` at its true
19502 bytes (a hand-guessed size smashed the heap; see `RESULTS.md`) and `OBJECT` laid
out exactly as libGEM sees it.

The flag that drives it is **`-L`**, and it **does not appear in `xtc --help`**.

The failure mode compounds it. Reaching for `-I` (the obvious guess) gives:

```
error: Cannot find include file 'GEM' (searched: '.', ..., '/opt/xtc/support/arm9/lib')
```

which says *include file*, lists only the include paths, and gives no hint that a
different flag with a different search path exists. I lost an hour, having already used
the feature successfully once.

One line in `--help`. Ideally the error adds: *"`<GEM>` is a library import; set the
library path with `-L`."*

---

# 3. 🟡 A gcc temp object name leaks into the `.so`

Two clean builds of identical source produce different binaries. They differ by
**8 bytes** — a gcc temp object name (`ccTxhJ1j.o` vs `cchJQb8F.o`) in the symbol
table. The **code is identical**.

Cosmetic, but it defeats reproducible builds and content-addressed caching, and it
cost me real time: I spent a while believing codegen was non-deterministic, which is a
very expensive thing to believe while debugging.

---

# 4. ❓ Cross-`.so` trampoline identity for `^`

Raised when the `^` design was settled, never resolved: the `@`→`^` widening uses **one
trampoline per signature**, with the function pointer carried in `recv`. If a client
`.so` and `libXtg.so` each instantiate the trampoline for the same signature, do they
agree on its identity — or does `-Wl,-Bsymbolic` (or its absence) give two distinct
trampolines, so that comparing two `^` values for equality gives the wrong answer
across the boundary?

Xtg has not yet hit this because `libXtg.so` is not yet a real `--emit-lib` artefact —
programs still `#import` its sources. **It will hit it the moment that changes**, which
is the next structural step. Worth settling before then.

---

# 5. ❓ Arrays of class instances go silent

Yours: `new B[1200]` + `bs[i].set(...)` → no output, no diagnostic. Unexamined.

Flagging that **Xtg will hit this**: a view tree is a flat `OBJECT[]` with a parallel
array of view objects, and a Rocks-scale resource is hundreds of entries. If it is a
live bug, I am a natural place to reproduce it against real code — say the word.

---

---

# Fixed — confirmed from this side

Verified against xtc `69ec25d`; all four Xtg programs pass on the loader.

- **A — `--emit-lib` devirtualisation.** Virtuality was inferred whole-program, but
  under `--emit-lib` the program is not whole: the overrides live in a client that does
  not exist yet. Fixed (phase-586). This was *the* structural blocker — the entire
  toolkit rests on an app subclassing a library class and the **library** calling the
  override back.
- **B — implicit self-calls.** A bare `f()` in a method body hard-called the lexically
  enclosing class's implementation, silently ignoring an override. It broke the
  template-method pattern, which is the spine of any UI toolkit (a base `display()` that
  calls `drawRect()`). Fixed (phase-585), plus a `final` keyword to opt back into the
  direct call.
- **C — unknown struct member was a *note***, and the store was silently dropped. For
  DWARF-imported C structs that turned a header rename into lost writes rather than a
  build failure. Fixed (phase-592).
- **E — `&Class.staticMethod`** was a *note* and produced a bad pointer. Fixed
  (phase-590), and superseded by `^` anyway.
- **F — non-weak `^` was a silent use-after-free.** The sharp part was not the dangling
  receiver but that **`if (action)` still tested true** afterwards — the truth test is
  on `code`, and only `recv` was dead, so the one guard a programmer writes was the
  guard that did not work. Fixed (phase-594/595): a stored `^` always auto-zeroes.

## `^` bound methods: the headline result

`^` did more than was asked. **`weak: act_t^`** turns out to satisfy two contracts that
are really one contract:

- **AppKit target/action** — a control must not own its controller, or
  `window → viewtree → button → action → window` is a retain cycle. AppKit needs a
  *separate* weak `target` field to break it. Here it is one field.
- **The optional delegate** — `if (h)` reads as *"not implemented"* **and** *"the
  delegate has died"*, same syntax, no extra machinery. Exactly the
  `-windowShouldClose` question that started the whole thread.

In Xtg it deleted a downcast preamble from every action:

```c
-  b.setTarget(self, &onClick);                    // free fn + a typed pair
-  void onClick(Object@ t, XGControl@ sender) {
-      Controller@ me = (Controller@ ?)t;          // recover self by downcasting
-      if (me == (Controller@)0) { return; }
-      me.clicks = me.clicks + (u16)1;  ...

+  b.setAction(&self.onClick);                     // a bound method
+  void onClick(XGControl@ sender) {               // an ordinary method
+      clicks = clicks + (u16)1;  ...
```

**Non-obvious constraint, recorded so it stays true:** a widened plain function carries
its code pointer in `recv`, so weak-zeroing cannot simply null the `recv` — it must zero
the **pair**, or a dead weak bound-pointer would still test true and jump through null.
The implementation gets this right today.

## D — anonymous enum constants: the xtc half is done; the other half is a build flag

`#import <GEM>` brought in structs and functions but not the enumerators of an unnamed
enum — and `aes.h` declares *every* constant that way. So `xtg/XGGem.xt` hand-mirrors
**49 constants**, a hand-copy that silently **drifts**: a wrong `G_USERDEF` does not
fail to build, it draws the wrong widget.

xtc is fixed (phase-593). The remaining half was believed blocked on `aes.h` — *"the
DWARF genuinely doesn't exist unless the enum type is used in an exported signature"*.
**It is not blocked, and `aes.h` does not change.** The DWARF is missing because of a
**gcc default**:

> `-feliminate-unused-debug-types` — *"GCC avoids producing debug symbol output for
> types that are nowhere used in the source file being compiled."* **On by default.**

`aes.h`'s enums are declared and never used *as a type*, so gcc drops them. Using an
*enumerator* does not count as using the *type*, which is why the constants vanish even
though `aes/*.c` reference them constantly. One flag on **libGEM's build**:

```make
CFLAGS += -g -fno-eliminate-unused-debug-types
```

Measured against the real `aes.h` with `arm-none-eabi-gcc`:

| | plain `-g` | `+ -fno-eliminate-unused-debug-types` |
|---|---|---|
| enumerators in DWARF | **0** | **287** |
| `.text` / `.data` / `.rodata` / `.bss` | — | **byte-identical** |
| `.debug_info` + `.debug_str` | — | ~+10 KB per TU (`.debug_str` dedups at link) |

**All 49/49** constants Xtg mirrors come back — `G_USERDEF`, `OF_LASTOB`, `OS_DISABLED`,
`W_NAME`, `WM_REDRAW`, `MN_SELECTED`, `WF_WORKXYWH`, every one. Zero runtime cost: the
ALLOC sections are identical and only debug sections grow, and debug sections are not
loaded.

**Action:** add the flag to libGEM's build; then delete `xtg/XGGem.xt`.
(`libxtos.so` now has `-g`; if its constants are anonymous enums too, it wants the same
flag.)

---

---

# Cleared — things I suspected and disproved

Recorded because I nearly reported all of them, and two of them turned out to be my own
bugs. Kept as a record of what the compiler was **not** guilty of.

- **`weak:` global read/written from a C-entered callback** — works
  (`spikes/weakglobal.xt`).
- **`&freeFunction` taken inside a class method** — works (`spikes/addrfn.xt`).
- **"The AES never calls our content callback."** Chased through PIC relocations, the
  `.so` symbol table, and (briefly, wrongly) suspected non-deterministic codegen. It was
  **my bug**: `XGApplication.boot()` declared the VDI back-buffer as a **stack local**
  and passed its address to `vdi_init`, which *stores the pointer* rather than copying
  the struct. `boot()` returned; the VDI held dead stack. It presented as a *callback*
  failure only because `wind_redraw_area()` opens with
  `gfx_surface *d = vdi_screen_target(); if (!d) return;` — so the redraw bailed out
  before ever reaching `W->draw`. Every argument to `wind_content()` was correct.
  > Two lessons kept: **`test_window.xt` structurally could not catch it**, because its
  > surface lives in `main()`, which never returns — a test that keeps everything alive
  > cannot detect a lifetime bug. And **trust the build**: much of the confusion was a
  > `.so` that had silently failed to rebuild while the loader kept running the previous
  > binary, and "my edit had no effect" is indistinguishable from a codegen bug if you
  > are not checking exit codes.
- **"Non-deterministic codegen."** Two clean builds, different MD5s — but they differ by
  8 bytes of gcc temp filename. Code identical. (Now filed as the cosmetic §3.)
- **`<stdio.h>` missing from the arm9/m68k PIC stub**, so `weak:` would not compile.
  Real at `279faa2`, which is what I had built; **fixed upstream concurrently** — HEAD
  includes `<stdio.h>` at all three sites. Not a live bug. Mentioned only because the
  *compounding* failure is worth knowing: `xtc` exits non-zero, but a build script that
  swallows that leaves the loader running the **previous** `.so`, so the symptom is "my
  change had no effect" rather than "my build failed".
- **A 68030 codegen bug.** There wasn't one. I was running a 68030 binary on a 68000
  core.
