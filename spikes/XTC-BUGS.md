# Two xtc bugs found while spiking the Xtg toolkit

Both block an AppKit-style framework. Both have minimal reproducers here. Neither is
a `.so` bug — **the shared-library boundary itself works** (proved by `Spike4`).

---

## Bug B — an implicit self-call is devirtualised  ⟵ the serious one

**Not a library bug. No `.so` involved. Affects every target.**

`selfcall.xt`, run on arm64 (`xtc -A arm64 selfcall.xt -o selfcall && ./selfcall`):

```c
class A {
    u16 f(void)       { return 1; }
    u16 viaSelf(void) { return f() * 10; }        // implicit self-call
    u16 viaThis(void) { return self.f() * 10; }   // explicit self
}
class B : A { u16 f(void) { return 42; } }
```

```
b.f()       = 42    OK
a.f()       = 42    OK   (through a base-typed pointer)
b.viaSelf() = 10    BUG  -- A.viaSelf hard-called A.f, ignoring B's override
b.viaThis() = 420   OK   -- self.f() dispatches correctly
```

So a bare `f()` inside a method body compiles to a direct call to the *lexically
enclosing class's* implementation, rather than a vtable dispatch on `self`.

**Why it matters:** this breaks the template-method pattern, which is the spine of
any UI toolkit — a base `display()` that calls `drawRect()`, a base `mouseDown()`
that calls `hitTest()`. It is also a silent wrong-answer bug, not a compile error.

**Expected:** a self-call to a method that has (or could have) an override must go
through the vtable, exactly as `self.f()` already does.

**Workaround:** write `self.f()` everywhere. Easy to forget; easy to get silently wrong.

---

## Bug A — `--emit-lib` devirtualises exported methods

Virtuality is inferred whole-program: *"methods that are never overridden keep a
direct JSR"*. Under `--emit-lib` the program is **not** whole — the overrides live in
a client that does not exist yet. So a library method nothing overrides *inside the
library* gets no vtable slot, and an app's override can never be reached.

`Spike1.xt` (library) + `app1.xt` (app), run with
`make xtcrun XTC_SO=app1.so` in `fpga-xt/loader`:

```
direct   area()      = 42    OK   (app-side dispatch)
lib      describe()  = 10    BUG  (library saw area() == 1, the base)
lib      render()    = 11    BUG
```

Add an override *inside* the library and `area()` gains a slot — then the library's
`v.area()` correctly reaches the app's `42`. That is the proof of the cause.

**Expected:** under `--emit-lib`, every public method of an exported class must be
given a vtable slot. Whole-program devirtualisation is unsound when the program is
not whole. (A `final` keyword could restore the optimisation opt-in later.)

**Workaround:** declare a dummy subclass inside the library that overrides every
method a client might override, purely to force slot allocation. Grim.

---

## Proof the boundary is fine

`Spike4.xt` + `app4.xt` apply both workarounds — a forced slot **and** `self.` — and
the library reaches the app's override across the `.so`:

```
lib render(app subclass) = 462  (expect 42+420=462)
PASS: with a slot AND self., the .so boundary works
```

So: fix these two and an app can subclass a library class, override a method, and
have the *library* call it back. That is all Xtg needs.

---

## Bug C — assigning to a non-existent struct field is only a *note*

Typo'd an imported C struct's field name and the compiler emitted:

```
gemobj.xt:16:62: note: ABANDON|lowering: struct '$anon_266581' has no field 'ob_width'
```

…and **still produced a .so**. A note, not an error. The store is silently dropped.

For DWARF-imported C structs this is dangerous: a field-name change in the C header
turns into silently-lost writes rather than a build failure. Should be an error.

---

## Gap D — anonymous enum constants  ✅ SOLVED (one flag, on libGEM's build)

`#import <GEM>` brings in structs and functions but **not** the enumerators of an
unnamed enum — and `aes.h` declares *every* constant that way:

```c
enum { G_BOX=20, G_TEXT=21, ..., G_USERDEF=24, G_CICON=33 };
enum { OF_NONE=0x00, OF_SELECTABLE=0x01, ..., OF_LASTOB=0x20 };
```

So `xtg/XGGem.xt` hand-mirrors 49 constants — a hand-copy that **silently drifts** when
`aes.h` changes. A wrong `G_USERDEF` does not fail to build; it draws the wrong widget.

**The xtc side is fixed (phase-593).** The remaining half was thought to be blocked on
`aes.h` — *"the DWARF genuinely doesn't exist unless the enum type is used in an
exported signature"*. **It is not blocked.** The DWARF is missing because of a **gcc
default**, not because the enum is anonymous:

> `-feliminate-unused-debug-types` — *"Normally, when producing DWARF output, GCC
> avoids producing debug symbol output for types that are nowhere used in the source
> file being compiled."* **On by default.**

`aes.h`'s enums are declared and never used *as a type*, so gcc drops them. The
documented switch to keep them is one flag on **libGEM's build**:

```make
CFLAGS += -g -fno-eliminate-unused-debug-types
```

### Measured, on the real `aes.h` (arm-none-eabi-gcc)

| | plain `-g` | `+ -fno-eliminate-unused-debug-types` |
|---|---|---|
| enumerators in DWARF | **0** | **287** |
| `.text` / `.data` / `.rodata` / `.bss` | — | **byte-identical** |
| `.debug_info` + `.debug_str` | — | ~+10 KB per TU (`.debug_str` dedups at link) |

**All 49/49** of the constants `XGGem.xt` mirrors are recovered — `G_USERDEF`,
`OF_LASTOB`, `OS_DISABLED`, `W_NAME`, `WM_REDRAW`, `MN_SELECTED`, `WF_WORKXYWH`, every
one. Nothing needs naming, nothing needs to appear in an exported signature, and
`aes.h` does not change.

Zero runtime cost: the ALLOC sections are identical, only debug sections grow — and
debug sections are not loaded.

**Action:** add the flag to libGEM's build, then delete `xtg/XGGem.xt`.

(Same question applies to `libxtos.so`, which still needs `-g` at all — see the
standing ask. If its constants are also anonymous enums, it wants the same flag.)

---

## Gap E — `&Class.staticMethod` is not supported (and is only a *note*)

```c
b.setTarget(self, &Controller.onClick);
// note: ABANDON|lowering: & on member-access requires a struct-typed base
```

A **note**, and the build succeeds with a bad pointer. Same silent-wrong-code family
as Gap C. Target/action must therefore use a free function today:

```c
void onClick(Object@ t, XGControl@ sender) { ... }   // free fn: works
b.setTarget(self, &onClick);
```

The `^` bound-method work supersedes this entirely (`&controller.onClick`), which is
exactly why it is the highest-value language ask. Until then, `&` on a member should
at least be an **error**, not a note.

> **LANDED** (`ef5837e`, Task #590). `^` works, and so does `@`→`^` widening. See the
> next section — it delivers more than was asked for, and carries one sharp edge.

---

## `^` bound methods: landed, and better than the ask

`spikes/bound_weak.xt`, `spikes/bound_unowned.xt` (arm64):

| | |
|---|---|
| `act_t^ h = &t.onClick;` | **works** — receiver captured, virtual dispatch |
| `act_t^ p = &plainFn;` | **works** — `@`→`^` widening, a plain fn fills a bound slot |
| `if (h)` on a null bound ptr | **works** — tests false |
| `sizeof(act_t^)` | 16 on arm64 — two words, `(recv, code)`, as designed |

### The prize: `weak: act_t^`

It parses **and it auto-zeroes**:

```
bound, target alive:
  waction tests TRUE  -> calling
    ping tag=7
    Callee(7) dealloc          <- last strong ref released
target released:
  waction tests FALSE -> target is gone, correctly skipped
```

One feature, two contracts, and they turn out to be the same contract:

- **AppKit target/action.** A control must not keep its target alive, or
  `window → viewtree → button → action → window` is a retain cycle. AppKit needs a
  separate weak `target` field to break it. Here it is one field.
- **The optional delegate.** `if (h)` reads as *"not implemented"* **and** *"the
  delegate has died"* with the same syntax and no extra machinery — exactly the
  `windowShouldClose` question that started this.

`XGControl` can drop its hand-rolled `(target, action)` pair for a single
`weak: XGAction^`.

### Gap F — a **non**-weak `^` is a silent use-after-free

`spikes/bound_unowned.xt`:

```c
Holder@ h = new Holder();
{
    Callee@ c = new Callee((i32)1);
    h.action = &c.ping;         // plain (non-weak) act_t^ field
}                               // c's last strong ref dies here
h.fire();                       // <- calls through a dangling receiver
```

```
  Callee(1) DEALLOC
   scope exited. firing:
  ping from tag 0               <- read freed memory, printed garbage, did not crash
```

So a bare `^` field is **unowned and non-zeroing**: it neither retains its receiver
nor notices when the receiver dies. It is not a dangling *pointer* in the usual sense
either — `if (action)` still tests **true**, because the truth test is on `code`, and
`code` is fine. Only `recv` is dead.

That last detail is the sharp part. The one guard a programmer would reach for is the
guard that does not work.

**The fix is NOT "make `^` retain by default".** That was my first suggestion and it
is wrong. Almost every `^` in UI code is a **back-reference** — a control calling into
its controller, a window calling into its delegate — and those are precisely the edges
that close a cycle:

```
    window -> viewtree -> button -> action^ -> controller -> window
    window -> delegate^ -> controller -> window
```

Retain-by-default would mean *every* realistic use needs `weak:`, so the default would
be wrong for the dominant case. Leak-by-default is not obviously better than
UAF-by-default; it is just a different wrong.

**The defensible complaint is narrower and sharper: the truth test lies.**

```c
XGAction^ a = &c.onClick;    // non-weak
// ... c is deallocated ...
if (a) { a(sender); }        // tests TRUE.  Calls through a dead receiver.
```

`if (a)` is *the one guard a programmer writes*, and it passes — because the test is on
`code`, and `code` is fine; only `recv` is dead. The failure is invisible at exactly
the point where someone was being careful. And it **cannot** be fixed for an unowned
pointer, because an unowned pointer has no way to learn its receiver died.

So the ask is not about ownership defaults. It is that **`^` should never be silently
unowned**:

1. **Require the ownership to be spelled on a `^` field** — `weak:` or `unowned:` —
   so nobody acquires a dangling receiver by omission. A local `^` can keep the
   current behaviour; it is fields that outlive their targets.
2. Failing that, **warn** when a non-`weak` `^` field is assigned a bound method whose
   receiver is an ARC object.

`weak:` is the right default *for a UI toolkit* regardless, and `XGControl` uses it.
The problem is only that today the safe form is the one you have to know to ask for,
and the unsafe form fails silently past its own guard.

Note the interaction with widening: a widened plain function carries its code pointer
in `recv`, so "zero the recv" cannot be the weak-zeroing implementation — it must zero
the **pair** (or at least `code`), or a zeroed weak bound-pointer would still test true
and jump through null. The implementation evidently already gets this right; it is
recorded here because it is the non-obvious constraint on any future change.

---

---

## Gap G — `-L` is not in `xtc --help`

`#import <GEM>` is a **library metadata import**: xtc resolves `libGEM.so` on a
*library* path, reads its `.dynsym` ∩ DWARF, and gives you the real C types. It is the
single most valuable thing xtc does for this project — it is what supplies `theme` at
its true 19502 bytes and `OBJECT` laid out exactly as libGEM sees it.

The path it searches is set by **`-L`**, and `-L` **does not appear in `xtc --help`**.

The failure mode is also misleading: reaching for `-I` (the obvious guess) produces

```
error: Cannot find include file 'GEM' (searched: '.', ..., '/opt/xtc/support/arm9/lib')
```

— which says *include file*, names only the include paths, and gives no hint that a
different flag and a different search path exist. I lost an hour to it, and I had
already used the feature successfully once.

One line in `--help` fixes it. Ideally the error would add: *"`<GEM>` is a library
import; set the library path with `-L`."*

While chasing an Xtg DATA-ABORT I suspected three compiler causes and **disproved all
three** on the loader (`spikes/weakglobal.xt`, `spikes/addrfn.xt`):

- reading a `weak:` global from a callback entered from C — **works**
- writing a `weak:` global from a callback entered from C — **works**
- `&freeFunction` taken inside a class method — **works**

The fault was almost certainly mine: `objc_set_userdraw` is a single global hook, so
it fires for *any* `objc_draw` — including AES-internal trees — and a hook keyed off
"the window currently drawing" can be handed an object index that is not its own.
Passing the window through the hook's own `ud`, re-registered per draw, is exact and
removes the class of bug entirely.

### Cleared #2: "the AES never calls our content callback"

A second, longer hunt — through PIC relocations, the `.so` symbol table, `--emit-lib`
devirtualisation and (briefly, and wrongly) a suspected non-deterministic codegen —
that ended at **my own bug**, again.

`XGApplication.boot()` declared the back-buffer surface as a **stack local** and passed
its address to `vdi_init`, which **stores the pointer** rather than copying the struct
(`gem/vdi/core.c`: `ws_tab[0].target = default_target`). When `boot()` returned, the
VDI was holding dead stack.

It presented as a *callback* problem because `wind_redraw_area()` opens with

```c
    gfx_surface *d = vdi_screen_target(); if(!d) return;
```

so the redraw bailed out before it ever reached `draw_one() -> W->draw`. Every argument
to `wind_content()` was correct — I verified the relocated function pointer, the handle
and the `ud` on hardware — and none of that mattered.

Two lessons worth keeping:

1. **`test_window.xt` could not catch it**, because its surface lives in `main()`, which
   never returns. A test that keeps everything alive cannot detect a lifetime bug. The
   toolkit was broken in exactly the shape the test was blind to.
2. **Trust the build.** Much of the confusion was a `.so` that had silently failed to
   rebuild (Gap H) while the loader kept running the previous binary, so edits appeared
   to do nothing — and "appears to do nothing" is indistinguishable from a codegen bug
   if you are not checking exit codes.

No compiler bug. Recorded here because I nearly reported one.
