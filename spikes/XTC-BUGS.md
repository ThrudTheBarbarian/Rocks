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

## Gap D — DWARF import does not surface anonymous enum constants

`#import <GEM>` brings in structs (verbatim — proven) and functions, but **not the
enumerators of an unnamed enum**. `aes.h` declares *every* constant that way:

```c
enum { G_BOX=20, G_TEXT=21, ..., G_USERDEF=24, ... };
enum { OF_NONE=0x00, OF_SELECTABLE=0x01, ..., OF_HIDETREE=0x80 };
enum { OS_NORMAL=0x00, ..., OS_DISABLED=0x08 };
```

So `G_USERDEF`, `OF_HIDETREE`, `OS_DISABLED`, `W_NAME` … are all invisible to xtc,
and every binding has to hand-mirror them (`xtg/XGGem.xt` does this today) —
duplication that silently drifts when the C header changes.

Two possible fixes; the first is better because it costs GEM nothing and helps every
future binding, in any language:

- **(a) xtc: import the enumerators of anonymous enums** as constants.
- (b) GEM: name its enums (`enum ObType { ... }`).

Not a blocker — just a papercut that will bite whoever forgets to re-sync.
