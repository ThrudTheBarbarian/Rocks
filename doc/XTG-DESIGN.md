# Xtg — an AppKit-shaped toolkit over GEM, for XTOS

**Status: design, not yet built.** This is the map we agreed before writing code.

Two deliverables:

- `libXtg.so` — the toolkit, written in xtc, calling into `libGEM.so`.
- `Rocks.so` — the resource editor, rewritten in xtc against Xtg. The proof.

Both run natively on the XT (Zynq-7020, Cortex-A9, ARMv7-A) under XTOS.

---

## 1. What already exists (so we don't re-invent it)

| | Where | Note |
|---|---|---|
| `libGEM.so` | `fpga-xt/loader/Makefile:280` | **Already a PIC `ET_DYN`**, built `-g`, `DT_NEEDED` → `libc.so`, `libm.so`. VDI + AES + theming + FreeType. |
| Dynamic linker | `fpga-xt/loader/xtld.c` | Real one. `ET_DYN`, recursive `DT_NEEDED`, `DT_INIT_ARRAY`. Apps are `.so` in `/OS/bin`. |
| xtc arm9 | `fpga-xtc` | Emits PIC `ET_DYN` `.so`. `--emit-lib` exports a class API + an embedded `.xtc.iface`. |
| C import | `fpga-xtc/src/xtc/dwarf/` | `#import <GEM>` reads `libGEM.so`'s DWARF and types every call **with struct layouts honoured verbatim**. |
| Theming | `gem/theme.c`, `themes/Aristo2` | 9-slice atlas, 57 slices, alpha-composited via `vr_transfer_bits(VR_OVER)`. |
| Resources | `gem/aes/rscload.c` + `Rocks/src/rsc.c` | The *same* `rsc.c` Rocks uses. Trees come back with `ob_spec` resolved. |

**The build graph is therefore:**

```
    libc.so  libm.so          (newlib, PIC)
        ▲        ▲
        └────┬───┘
        libGEM.so             C. exists. VDI + AES + theme + FreeType.
             ▲
             │  #import <GEM>        (DWARF ⇒ typed prototypes, verbatim structs)
             │
        libXtg.so             xtc --emit-lib -A arm9.  THE TOOLKIT.
             ▲
             │  #import <Xtg>        (.xtc.iface ⇒ classes, protocols)
             │
         Rocks.so             xtc -A arm9.  THE CLIENT.
```

Nothing here needs inventing. The pieces snap together — *if* the one gating risk in §9 holds.

---

## 2. The impedance mismatch

This is the whole design problem, stated plainly.

| GEM/AES gives us | AppKit wants |
|---|---|
| A window = chrome + **one** content-draw callback (`wind_content`) | A window = a **tree** of views |
| **Pull**-based drawing: the AES calls *you* during `wind_redraw()` | **Push**: `setNeedsDisplay` → later, `drawRect:` |
| **Whole-screen** repaint, bottom-up. No damage rects, no `WM_REDRAW`, no `wind_update` | Dirty rectangles, coalesced |
| Widgets = a flat `OBJECT[]` array with 16-bit sibling links, driven by **modal** `form_do` | Widgets = subclassable view objects, non-modal |
| `evnt_multi` **pre-consumes** menu-bar and window-frame clicks | The app sees everything and routes it |
| Theming: `theme_draw(name, rect)` | `drawRect:` with a graphics context |

GEM is an *immediate-mode, modal, whole-screen* system. AppKit is a *retained, event-driven, incremental* one. Xtg's job is to be the second while standing on the first.

The good news: GEM's chrome (frames, title bars, scrollbars, menu bar, alerts) is genuinely good and already themed. We should **keep all of it** and only replace the part GEM lacks — the view tree.

---

## 3. The central decision: a view IS a GEM object

The first draft had Xtg build a parallel view tree and only *borrow* GEM's theming.
That was wrong. It reimplements things GEM already does, and it isn't "wrapping GEM"
in any honest sense.

**Instead: an `XGView` is backed by a real `OBJECT` in a real AES tree.** The
hierarchy, the traversal, the clipping, the hit-testing, the disabled/selected
state and the theming are all GEM's. Xtg supplies *behaviour* and *identity*.

This works because of a hole GEM left open:

```c
    // gem/aes/aes.h:27  — G_USERDEF is DECLARED …
    enum { G_BOX=20, ..., G_IMAGE=23, G_USERDEF=24, G_IBOX=25, ... };

    // gem/aes/object.c:254  — … but never DRAWN.
    default: break;
```

`G_USERDEF` is the classic AES escape hatch — an object whose drawing the
application supplies. It is exactly the seam we need, and it is currently a no-op.

### The mapping

| Xtg class | GEM object | Who draws it |
|---|---|---|
| `XGView` (custom, subclassable) | `G_USERDEF` | **us** — the AES calls back into `drawRect` |
| `XGView` (plain container) | `G_IBOX` | nobody: an invisible container |
| `XGBox` | `G_BOX` | GEM |
| `XGButton` | `G_BUTTON` | **GEM** — themed, free |
| `XGCheckbox` / `XGRadio` | `G_CHECKBOX` / `G_RADIO` | **GEM** |
| `XGTextField` | `G_FIELD` / `G_FTEXT` | **GEM** (+ `objc_edit` for editing) |
| `XGPopUp` | `G_POPUP` | **GEM** (+ the existing `form_hook`) |
| `XGLabel` | `G_STRING` / `G_TEXT` | **GEM** |
| `XGImageView` | `G_IMAGE` / `G_CICON` | **GEM** |
| `XGWindow` | an AES window handle | GEM draws the frame; we draw the content tree |

**The point: standard controls cost us nothing.** A button is a `G_BUTTON`; GEM
themes it. Only a genuinely custom view pays for a callback. That is the opposite
of the first draft, where every control was a hand-drawn `XGView`.

### Identity: OBJECT ↔ XGView

`ob_spec` is already spoken for on standard widgets (string / TEDINFO / CICON), so
we don't steal it. Each view tree carries a parallel array:

```c
class XGViewTree {
    pointer   tree;       // OBJECT[] — the canonical structure, handed to the AES
    Array@    views;      // views[i] is the XGView backing tree[i].  O(1) both ways.
    u16       count, capacity;
}
```

`objc_find` returns an index; `views[index]` is the view. `objc_draw` calls back
with an index; `views[index]` is the view. No lookup, no map, no reflection.

### Structure changes

`ob_next` / `ob_head` / `ob_tail` are 16-bit indices *relative to the tree root*, so
`addSubview` / `removeFromSuperview` mean relinking a flat array — which is precisely
what the classic AES `objc_add` / `objc_delete` / `objc_order` do, and which
fpga-xt's GEM currently lacks. Xtg can implement them over its own array, but they
belong in GEM (see §8).

---

## 4. Drawing

`objc_draw(tree, start, depth, clx, cly, clw, clh)` **already takes a clip rect.**
Everything needed for incremental redraw is present; only `wind_redraw()` throws it
away by clearing the whole framebuffer first.

```
    AES wind_redraw(dirty)              ← GEM (once damage rects land)
      └─ draw_one(window)               ← GEM: theme frame
          └─ xtg_window_draw(h,x,y,w,h,ud)      ← one C trampoline; ud = XGWindow
              └─ objc_draw(tree, 0, 8, dirty…)  ← GEM walks OUR tree
                   ├─ G_BUTTON     → GEM themes it                       (free)
                   ├─ G_FIELD      → GEM themes it                       (free)
                   └─ G_USERDEF    → objc_userdraw hook →
                                        views[obj].drawRect(g, dirty)     ← app code
```

So the app's `drawRect` is invoked *by the AES, during the AES's own traversal,
inside the AES's clip*. That is what "bolting views into the widget hierarchy"
means, and it is a much smaller amount of Xtg code than the first draft.

`XGView.setNeedsDisplay(rect)` unions into the window's damage region; the run loop
asks the AES to repaint it. Once `wind_redraw` honours damage rects, that becomes
genuinely incremental with no change to Xtg's API.

### Keyboard and focus, without going modal

We do **not** use `form_do` for windows — it is modal. GEM has already factored the
policy out for exactly this case:

```c
// gem/aes/aes.h:186 — "for bare evnt_multi clients that host editable objects
// themselves.  edobj = the focused editable (-1 none); *new_edobj receives the
// focus after the key.  Returns the exit object fired, or -1 (keep going)."
int form_keybd(OBJECT *tree, int edobj, int key, int kstate, int *new_edobj);
int objc_edit (OBJECT *tree, int obj, int key, int *idx, int kind);
```

`XGWindow` keeps the focused object index and feeds `MU_KEYBD` through `form_keybd`,
getting Return/Esc/Tab/mnemonics/character-insertion for free, non-modally. Modal
dialogs can still just call `form_do`.

## 5. Event flow

`evnt_multi` is the only source. Critically, **the AES has already consumed menu-bar clicks and window-frame clicks** before we see anything — so Xtg must *not* try to own chrome. It only routes what's left.

```
                    ┌──────────────────────────────────────────┐
                    │  GApplication.run()                      │
                    │    evnt_multi(KEYBD|BUTTON|MESAG|TIMER)  │
                    └──────────────────┬───────────────────────┘
                                       │
      ┌──────────────┬─────────────────┼──────────────┬─────────────────┐
      │              │                 │              │                 │
   MU_QUIT       MU_MESAG          MU_BUTTON      MU_KEYBD          MU_TIMER
      │              │                 │              │                 │
    stop()           │        wind_find(mx,my)   window.first-      GTimer.fire
                     │                 │           Responder            │
      ┌──────────────┴─────────┐       │              │                 │
      │                        │       ▼              ▼                 │
  MN_SELECTED            WM_CLOSED   GWindow      GResponder.keyDown    │
      │                  WM_SIZED      │              │                 │
      ▼                  WM_MOVED      ▼              │                 │
  GMenuItem              WM_TOPPED  contentView       │                 │
   .target/.action           │       .hitTest(pt)     │                 │
                             ▼          │             │                 │
                      GWindowDelegate   ▼             │                 │
                       windowShould-  GView           │                 │
                       Close / did-    .mouseDown ────┘                 │
                       Resize             │                             │
                                          ▼                             │
                             ┌──────── responder chain ────────┐        │
                             │  view → superview → … →         │        │
                             │  contentView → window → app     │        │
                             └─────────────────────────────────┘        │
                                                                        │
      ┌─────────────────────────────────────────────────────────────────┘
      ▼
   end of iteration:  if any window is dirty → wind_redraw()   (see §6)
```

### The responder chain, without reflection

AppKit walks the chain by asking `respondsToSelector:`. **xtc has no reflection, no selectors, no `respondsToSelector`.** So the chain is built the other way round: `GResponder` provides default implementations that *forward*, and a subclass consumes by simply not calling `super`.

```c
class GResponder : Object {
    weak:GResponder@ nextResponder;

    // Default: I don't handle it — pass it on.  Override to consume.
    void mouseDown(GEvent@ e) {
        if (nextResponder != (GResponder@)0) { nextResponder.mouseDown(e); }
    }
    void keyDown(GEvent@ e) {
        if (nextResponder != (GResponder@)0) { nextResponder.keyDown(e); }
    }
}
```

This works precisely because xtc's vtables dispatch overrides through a base-typed pointer. It is *better defined* than AppKit's version — the chain is explicit and type-checked rather than probed at runtime.

### Target/action, without blocks

xtc has **no closures, no blocks, and no method pointers** (you can't take `&obj.method`). A bare function pointer can't carry `self`. So target/action is a typed pair — the pre-blocks NeXTSTEP design, which is the right era anyway:

```c
typedef void GAction(Object@ target, GControl@ sender);

class GControl : GView {
    weak:Object@ target;
    GAction@     action;
    void setTarget(Object@ t, GAction@ a) { target = t; action = a; }
    void fire(void) {
        if (action != (GAction@)0) { action(target, self); }
    }
}
```

and in a controller:

```c
class EditorController : Object {
    void save(void) { /* … */ }

    // The action: a free/static function that recovers `self` from the target.
    static void onSave(Object@ t, GControl@ sender) {
        EditorController@ me = (EditorController@ ?)t;    // failable downcast
        if (me != 0) { me.save(); }
    }
}
...
    saveButton.setTarget(controller, &EditorController.onSave);
```

For richer contracts we use **delegate protocols** — but note xtc protocols have **no optional methods**, so they must be kept small and single-purpose (`GWindowDelegate`, `GListDataSource`, `GTextFieldDelegate`) rather than one fat protocol with twenty optional callbacks.

---

## 6. Drawing and the redraw model

This is the sharpest edge, and worth being honest about.

GEM's `wind_redraw()` **clears the entire framebuffer and repaints every window bottom-up.** There is no `WM_REDRAW` message, no damage-rectangle list, no `wind_update`. Occlusion is handled only by painting in z-order.

So:

- `GView.setNeedsDisplay(rect)` marks the view dirty and unions the rect into its window's dirty region. It draws **nothing**.
- At the **end of each run-loop iteration**, if any window is dirty, `GApplication` calls `wind_redraw()` **once**. GEM then pulls from us through the trampoline.
- Within a window, `displayIfNeeded` still clips per view and skips subtrees that don't intersect — so we don't waste time on views, only on the framebuffer clear.

**v1 cost: one full-screen composite per dirty frame** — 1920×1080×4 = 8 MB. On a Cortex-A9 that is *not* free. It is, however, exactly what the existing GEM desktop already does, so we are no worse than the status quo, and correctness comes first.

**The optimisation path is clear and already half-built:**
1. `aes_flush_rect(x,y,w,h)` exists.
2. `gfx_a9.c` (the Zynq PL hardware blitter) exists in the Vitis tree and is not yet wired into the FreeRTOS build.
3. What's missing is an occlusion/visible-region query in `aes/window.c` so a window can repaint *just* its dirty rect without painting over the windows above it. That's a small, well-defined addition to libGEM — and the right time to do it is after Xtg works, with a profile in hand.

Do not design Xtg's API around whole-screen repaint. `setNeedsDisplay(rect)` takes a rect from day one, so the optimisation is invisible to clients when it lands.

### Scrolling

`GScrollView` does **not** implement scrolling. The AES already owns it: `wind_content_size()` makes the scrollbars appear, shrinks the work area, and `wind_scroll_x/y(handle)` reports the offset. `GScrollView` just reports its document size and translates its subview by `-scroll`. Free scrollbars, themed, correct.

---

## 7. What we are asking of GEM

All four are things classic AES *has* and fpga-xt's GEM has simply not needed yet.
None is a hack; each fills a hole.

1. **`G_USERDEF` dispatch.** Declared in the enum, falls through `default: break;`
   in `draw_obj`. Copy the `form_set_hook` pattern already in `form.c`:

   ```c
   // gem/aes/aes.h — mirrors form_hook_fn exactly
   typedef void (*objc_userdraw_fn)(OBJECT *tree, int obj,
                                    int x, int y, int w, int h, void *ud);
   void objc_set_userdraw(objc_userdraw_fn fn, void *ud);
   ```
   `draw_obj` gains `case G_USERDEF: if (g_userdraw) g_userdraw(t, obj, x,y,w,h, g_ud); break;`
   The AES stays resource-agnostic; the app maps `obj` → behaviour, exactly as
   `form_hook` already does for `G_POPUP`. **This is the whole seam.**

2. **`objc_add` / `objc_delete` / `objc_order`.** Classic AES; absent here. Needed for
   a live view hierarchy (`addSubview`, `removeFromSuperview`, `bringToFront`). Pure
   index relinking on the flat array — no drawing, no state.

3. **Damage-rect redraw.** `wind_redraw()` currently clears the entire framebuffer and
   repaints every window bottom-up. `objc_draw` *already* takes a clip rect, so the
   machinery is there — what's missing is a per-window visible-region/damage path so a
   window can repaint just its dirty rect without painting over the windows above it.

4. **(Nice to have) `objc_offset` for a G_USERDEF's clip.** Already exists — noting it
   because the userdraw hook must receive *absolute* coordinates, which `draw_obj`
   already has to hand.

---

## 8. What we are asking of xtc — and what we are NOT

The offer was "blocks, closures, selectors if you need them". Here is the honest
ranking, because asking for everything would be the wrong answer.

### Must have (gating)

**Subclass-across-`.so` override dispatch must work.** Not a feature — a correctness
requirement. xtc computes vtable slots by whole-program analysis, and a client
importing a `.so` *recomputes* them from the embedded `.xtc.iface`. The whole toolkit
rests on the app subclassing a library class and overriding a method the *library*
then calls back (`drawRect`, `mouseDown`). No fixture in fpga-xtc exercises this.
If it silently mis-dispatches, everything is quietly wrong. **Spike this first.**

### Want, in order of value

1. **Bound method pointers** — `&obj.method` yielding a `(self, fn)` fat pointer.
   This is worth more than closures, and it is *smaller*. It is exactly what
   target/action is, and it removes the ugliest thing in the design:

   ```c
   // today: a free function that has to recover self by downcasting
   static void onSave(Object@ t, XGControl@ s) {
       EditorController@ me = (EditorController@ ?)t;
       if (me != 0) { me.save(); }
   }
   saveButton.setTarget(controller, &EditorController.onSave);

   // with bound methods: say what you mean
   saveButton.setAction(&controller.save);
   ```
   No capture, no heap, no ARC subtleties — a two-word value. It subsumes most of
   what we would otherwise want closures for.

2. **Optional protocol methods.** Every xtc protocol method is required, which is
   fatal to the Cocoa delegate pattern: `XGWindowDelegate` cannot have an optional
   `windowShouldClose`. Today the workaround is either many one-method protocols or
   adapter base classes full of empty stubs. Optional methods (with a compile-time
   "did they implement it" test) would make delegates idiomatic.

### Nice, but not on the critical path

3. **Closures.** Genuinely useful for enumeration, sorting and completion handlers —
   but they need capture, heap allocation and ARC interaction, which is a far bigger
   lift than (1). And they do **not** help at the C boundary: `wind_content` and
   `objc_set_userdraw` take bare C function pointers, so the trampoline stays
   regardless. If bound method pointers land, closures drop a long way down the list.

4. **Generics.** Collections are `Object@`; every read is a downcast. Noisy, not
   blocking.

### Explicitly NOT wanted

**Selectors / runtime reflection / `respondsToSelector:`.** I do not want these, and
I'd argue against adding them for our sake. They would drag stringly-typed dispatch
into a statically-typed language to solve problems we do not have:

- The **responder chain** does not need them. `XGResponder`'s default methods forward
  to `nextResponder`; a subclass consumes by not calling `super`. That is *better*
  defined than AppKit's version — explicit and compile-checked, not probed.
- **Target/action** does not need them. Bound method pointers are typed; a selector
  is a string that fails at runtime.
- **Optional protocol methods** are the real need underneath "respondsToSelector", and
  they can be answered at compile time.

Adding selectors would buy us nothing and cost the language its type safety. The one
thing reflection genuinely buys — dynamic UI wiring from a nib — we get instead from
`objc_find` + the `views[]` side array, which is O(1) and typed.

---

## 9. Risks, and the one that gates everything

**⚠ SPIKE FIRST — subclassing across the `.so` boundary.**

xtc computes vtable slots by *whole-program* analysis, and a client importing a `.so` **recomputes those slots** from the embedded `.xtc.iface`. The entire toolkit depends on the app subclassing library classes and overriding methods that the *library* then calls back (`drawRect`, `mouseDown`, `applicationDidStart`). If a slot computed in the app doesn't match the one the pre-compiled library body dispatches through, every override silently calls the wrong method.

There is **no test fixture in fpga-xtc that exercises this.** The existing `gem_hello.xt` imports the framework's *source*, not its `.so`.

> **Spike 1:** build a `.so` with `--emit-lib` containing a class with a virtual method and a function that calls it. In a *separate* app, `#import` the `.so`, subclass, override, and confirm the library's caller reaches the override.
>
> If it fails, the fallback is unglamorous but fine: ship `libXtg` **as source** (`#import "GView.xt"`), compiled into each app. We lose binary distribution and gain compile time. Everything else in this design is unaffected.

Other risks, in order:

| Risk | Note |
|---|---|
| **Float ABI mismatch** | The loader builds `libGEM.so` with `-mfloat-abi=softfp`; xtc's arm9 BSP flags say `-mfloat-abi=hard`. These are **not** link-compatible for anything passing floats. Check before the first link. |
| Whole-screen repaint cost | §6. Correct but slow. Measure before optimising. |
| No optional protocol methods | Forces many small protocols. A design constraint, not a blocker. |
| `Map` hashes to 256 buckets (u8 hash) | Fine for our sizes; don't build anything large on it. |
| `weak` side-table cap | Default 64 entries. Hundreds of views each with a weak `superview` could exceed it — it's a linker-script knob on arm9, but **verify the arm9 default**. |
| No generics | Collections are `Object@`; downcast with `(T@ ?)x` on the way out. |

---

## 8. Phasing

**Phase 0 — spikes (do not skip).**
1. Subclass-across-`.so` override dispatch. *Gating.*
2. `#import <GEM>` from xtc: call `appl_init`, `wind_create`, `wind_open`, spin `evnt_multi`. Proves the DWARF import and the float ABI.
3. Register a C content callback from xtc and paint one rectangle through the VDI. Proves the trampoline.

**Phase 1 — the spine.** `GRect`/`GPoint`, `GResponder`, `GView`, `GWindow`, `GApplication`, the run loop, `GGraphics`, dirty/redraw. Deliverable: a window with a custom-drawn view that responds to clicks.

**Phase 2 — controls.** `GControl` + target/action, `GButton`, `GLabel`, `GTextField`, `GCheckbox`, `GRadio`, `GPopUp`, `GScrollView`. All themed via `theme_draw`.

**Phase 3 — chrome.** `GMenu`/`GMenuItem` on `menu_bar` + `MN_SELECTED`; `GAlert` on `form_alert`; modal `GWindow` loop.

**Phase 4 — nibs.** `GViewInflater`: `.rsc` `OBJECT` trees → `GView` hierarchies. Rocks becomes the Interface Builder.

**Phase 5 — Rocks.so.** The editor, in xtc, on Xtg, loading its own UI from a `.rsc`.

---

## 9. Open questions

1. **Where does Xtg live?** Its own repo, inside `fpga-xt` beside `gem/`, or inside `fpga-xtc/support/arm9/lib`? It is a *library on top of* GEM, not part of it, and it is not part of the compiler either — a sibling repo feels right.
2. **Float ABI:** `softfp` (loader) vs `hard` (xtc BSP flags). Which wins?
3. **Rocks-on-XT scope.** The macOS Rocks is a big app. Which slice is the proof — canvas + palette + inspector + menus, and what gets dropped?
