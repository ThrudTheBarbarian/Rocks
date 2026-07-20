# Xtg across the desktop hosts — one source, native look

**Status: design, consolidated.** Companion to `XTG-DESIGN.md`, which designs Xtg
*over GEM for XTOS/A9*. This doc asks the next question and answers it: can the
**same** AppKit-shaped Xtg API also render through the native toolkits of the
desktop hosts — AppKit (macOS), Win32 (Windows), GTK (Linux) — so one program
source runs, and looks native, on all of them plus the A9?

It defers to `XTG-DESIGN.md` for everything about the GEM backend's internals, and
does not change the app-visible API that doc already defines. (This is the folded
form of a multi-round design convergence between the compiler/hosts thread and the
A9/Rocks thread; the decisions below are settled.)

## 0. The two requirements (and nothing else)

They are the whole spec:

1. **The app source stays the same** across platforms.
2. **The look-and-feel is native** on each.

Implementation differences between backends are explicitly *not* a concern. That
freedom is what makes this tractable.

## 1. The reframe: Xtg already is the toolkit; this adds backends

Xtg is not a widget layer to be built — it exists and is largely board-verified on
the A9: `XGApplication`, `XGWindow`, `XGView`, `XGResponder` (a real responder chain
by forwarding, not reflection), `XGControl` with target/action, the stock controls,
`XGMenu`, `XGAlert`, `XGScrollView`, `XGTableView`, `XGOutlineView`, `XGNib`. It has
**one backend today: GEM/AES**, where — per `XTG-DESIGN.md` §3 — *a view is a GEM
object* (an `OBJECT` in an AES tree, themed for free, drawn by the AES calling back
into `drawRect` through the `G_USERDEF` seam).

So the task is not "design a portable widget toolkit." It is: **give Xtg's existing
API additional backends, so the same source targets AppKit / Win32 / GTK alongside
GEM.** That framing is the whole difference between this and a from-scratch
cross-platform GUI.

(On the `XG` prefix: it stays. It once read "**X**tg over **G**EM"; re-read it as
"**cross**-**g**raphics" and it now says what the framework became. Renaming to `G*`
would have *created* a real clash with GLib/GIO — `GString`, `GApplication` — to
cure a cosmetic one; `XG`+Capital collides with nothing, and xtc's import check is
exact-identifier, so board-verified code keeps its names.)

## 2. The model: an opaque handle + a per-platform stateless driver

The tempting move — a generic widget that *holds a* per-platform "peer" object — is
wrong twice over: it allocates an object per widget (a cost the A9 can least afford),
and it forces a uniform per-widget shape onto every backend, which makes GEM's "a
control is an `int16` index into an array" wear an object costume it doesn't fit.

The right move is one more level of indirection, and it *removes* an assumption
rather than adding one:

> The generic layer holds an **opaque handle** it never dereferences. Each backend
> decides what the handle means. A per-platform **stateless driver** interprets
> handles.

The generic layer thereby assumes neither "object" nor "array" — it assumes a word.
And the payoff is that on three of the four platforms the native thing *already is*
an opaque handle: `HWND`, `GtkWidget*`, `NSView*`. There the `XGHandle` **is** the
native handle, zero wrapping. On GEM it is the `(window, index)` pair Xtg already
owns — so "keep the AES hierarchy for GEM" stops being a special accommodation and
becomes simply what the GEM driver stores in its handle.

```
    ┌──────────────────────────────────────────────────────────┐
    │  Generic Xtg  (written ONCE, portable)                    │
    │    XGView / XGControl / XGResponder / XGWindow / XGApp     │
    │    holds:  XGHandle handle  (opaque — never dereferenced)  │
    │    owns:   lifetime (strong refs), responder chain,        │
    │            target/action, delegation, geometry, layout,    │
    │            dirty accumulation, table/outline projection    │
    └───────────────────────────┬──────────────────────────────┘
                                 │  speaks handles
                 ┌───────────────┼───────────────┬───────────────┐
                 ▼               ▼               ▼               ▼
            GEM driver      Win32 driver     GTK driver     AppKit driver
         handle=(win,idx)   handle=HWND   handle=GtkWidget* handle=NSView*
         (Xtg's guts, kept)  (native)        (native)        (native)
```

The driver is **one per platform, not one per widget** — a stateless object (it can
be a process singleton, so a view need not even carry a driver field, only its
handle). Its surface:

```
protocol XGViewDriver {
    // view hierarchy
    XGHandle create(XGKind kind);                    // native realization for a kind
    void     attach(XGHandle parent, XGHandle child, XGRect frame);
    void     destroy(XGHandle h);                    // frees native + clears reverse map
    XGRect   frameOf(XGHandle h);                    // truth lives natively
    void     setFrame(XGHandle h, XGRect r);
    XGSize   sizeThatFits(XGHandle h, XGSize limit); // native intrinsic size (§6)
    void     setText(XGHandle h, XGString@ s);
    void     setEnabled(XGHandle h, bool on);
    void     invalidate(XGHandle h, XGRect r);       // "needs display" → native repaint
    XGHandle hitTest(XGHandle root, XGPoint p);      // native z-order / disabled state
    u16      childCount(XGHandle h);                 // structure lives natively (§6)
    XGHandle childAt(XGHandle h, u16 i);
    void     focus(XGHandle h);                      // move native focus (§5)
    // menus — a second small vocabulary (§5)
    XGHandle menuCreate(void);
    void     menuAddItem(XGHandle menu, XGString@ title, XGAction@ act);
    void     menuAttach(XGHandle menu, XGHandle appOrWindow);
    // NOTE: no draw() — drawing flows the OTHER way (§4).
}
```

**What is neutral (written once) vs realized (per driver):**

| Neutral — generic Xtg | Realized — per driver |
|---|---|
| lifetime / ownership (strong refs, §6) | `create` / `attach` / `destroy` |
| responder chain (forwarding) | frame get/set (native is the truth) |
| target/action + bound methods | `sizeThatFits` (native intrinsic size) |
| delegate/datasource protocols | `setText` / `setEnabled` |
| geometry + layout math | `invalidate` → native repaint request |
| dirty-rect accumulation | `hitTest`, `childCount`/`childAt` (structure) |
| table/outline projection, cell recycling | `focus`; event source → normalized `XGEvent` |
| menu model, alert model, tab-ring | menu vocabulary; `XGContext` draw primitives |

The generic `XGView` holds **no realization state** — no frame field, no native
handle interpretation. It asks the driver. On GEM the frame's truth is the
`OBJECT`'s `ob_x/y/w/h`; a shadow copy in a generic field is a second source of
truth waiting to diverge.

**Honest cost.** Versus the peer-object model this is strictly leaner in memory (one
scalar handle per view, plus a shared singleton driver — no per-widget object), at
the cost of one extra indirection (the driver dispatch) per realization call. That
indirection is noise next to a blit or a native control update. Leaner in footprint;
not slower in any way that matters.

## 3. The two cross-backend contracts — keep them minimal

The seam did not vanish; it became **two vocabularies**, and both deserve the same
paranoia as the type-width invariant (every entry is paid on every backend, and is a
place backends can silently disagree):

1. **`XGKind`** — the set of things `create(kind)` can make: **primitives + `custom`
   + a small closed set of compound kinds** (`table`, `outline`, `scroll`). A kind's
   realization is **the driver's choice** — a native compound control where the
   toolkit has one, a composition of primitive handles where it does not. The neutral
   datasource/delegate logic and cell recycling are written once and bridged per
   platform (below); GEM's realization of the compound kinds *is* the composition Xtg
   already built (`XTG-DESIGN.md` §10), so nothing is lost there.

2. **`XGContext`** — the drawing primitives a custom view's `drawRect` uses. It must
   be implementable over VDI (GEM), GDI/Direct2D (Win32), Cairo (GTK) and CoreGraphics
   (AppKit), so it is the *intersection* that still yields native-enough custom
   drawing: text, lines, fills, images, clip, transform.

### Kind → native realization

Stock controls cost **zero** drawing code on every host — each is a real native
control the platform themes/paints:

| `XGKind` | GEM | Win32 | GTK | AppKit |
|---|---|---|---|---|
| `button` | `G_BUTTON` | `BUTTON` | `GtkButton` | `NSButton` |
| `label` | `G_STRING`/`G_TEXT` | `STATIC` | `GtkLabel` | `NSTextField` (static) |
| `field` | `G_FIELD`/`G_FTEXT` | `EDIT` | `GtkEntry` | `NSTextField` |
| `checkbox` | `G_CHECKBOX` | `BUTTON`(check) | `GtkCheckButton` | `NSButton`(check) |
| `radio` | `G_RADIO` | `BUTTON`(radio) | `GtkRadioButton` | `NSButton`(radio) |
| `popup` | `G_POPUP` | `COMBOBOX` | `GtkComboBox` | `NSPopUpButton` |
| `scrollbar` | `G_SCROLL` | native SB | `GtkScrollbar` | `NSScroller` |
| `slider` | `G_SLIDER` | `TRACKBAR` | `GtkScale` | `NSSlider` |
| `image` | `G_IMAGE`/`G_CICON` | `STATIC`(bitmap) | `GtkImage` | `NSImageView` |
| `container` | `G_IBOX` | plain `HWND` | `GtkFixed` | `NSView` |
| `custom` | `G_USERDEF` | owner-draw `HWND` | `GtkDrawingArea` | `NSView`(drawRect) |
| `window` | AES window | overlapped `HWND` | `GtkWindow` | `NSWindow` |
| `table` | compose `custom`+`label` | `SysListView32` | **`GtkColumnView`** (GTK4) | `NSTableView` |
| `outline` | compose | `SysTreeView32` | **`GtkColumnView`** (GTK4) | `NSOutlineView` |
| `scroll` | AES scrollbar + content-size | `WS_*SCROLL` | `GtkScrolledWindow` | `NSScrollView` |

Only `custom` routes `drawRect` back; everything else is native and free — which is
how "native look" is met without a rendering engine per platform.

**Compound kinds carry a datasource bridge.** A native compound control is itself
datasource-driven (`NSTableViewDataSource`, `GtkListItemFactory`, `LVN_GETDISPINFO`),
so the driver's realization of a compound kind adapts that native data protocol to
the neutral `XGTableDataSource` — heavier than a primitive's `create`+`attach`, and
that weight is exactly where the portable datasource logic pays off. A **custom cell
is a `custom` sub-handle** hosted inside the native control (a view-based
`NSTableView` cell *is* an `NSView` *is* our `custom` kind), so customization
composes on the hosts as on GEM.

> **GTK note:** custom cells force the *view-based* widget — classic `GtkTreeView`
> cannot host an arbitrary widget as a cell (`GtkCellRenderer` only). Realize `table`
> / `outline` on **`GtkColumnView` / `GtkListView` (GTK4)**, whose `GtkListItemFactory`
> is also the cleanest datasource-bridge mechanism (C signal callbacks with a context
> word, not a `GtkTreeModel` subclass). This pins **GTK4** as the floor for the GTK
> backend once custom cells are in scope.

## 4. Drawing, events, and the reverse map (= the callback bridge)

Drawing flows **backend → view**, so it is not a driver method. When the platform
needs a custom view painted (AES traversal hits a `G_USERDEF`; Win32 gets `WM_PAINT`;
AppKit calls `drawRect:`), the backend uses the **reverse map** `handle → XGView` to
find the front object and calls its `drawRect(XGContext, dirty)`. Same shape for
input: "this handle was clicked" → reverse map → the `XGView` → the neutral
responder / target-action dispatch.

The reverse map is the one genuinely-new-per-backend piece, and every platform has a
natural slot for it: Win32 `GWLP_USERDATA`, GTK `user_data`, AppKit the control's
`target`, GEM the `views[index]` side array Xtg already keeps. It is exactly the
**callback-with-context** mechanism — proven cross-ABI (§8).

**Stock vs custom is a property of `create(kind)`, not a second protocol.** A `button`
handle never routes `draw`; a `custom` handle does. One vocabulary.

## 5. Native subsystems beyond the view hierarchy

The handle/driver model is about the *view hierarchy*. Three toolkit subsystems live
outside it and each needs its own home; all are **neutral model + small driver
vocabulary**, and none needs a new neutral mechanism — they reuse target/action and
the nullable-bound-method "optional method" pattern already in the design.

**Menus.** A menu is not a view (`NSMenu` ≠ `NSView`, `HMENU` ≠ `HWND`), and it is
the single most divergent subsystem: AppKit has one *global* menu bar owned by the
application; Win32 a *per-window* `HMENU`; GTK per-window `GtkMenuBar` (GTK4:
`GMenuModel` + popovers); GEM a per-*app* strip. The neutral part is the **menu model**
— `XGMenu` as it already exists (items / submenus / separators, actions via bound
methods, enable/disable via a nullable bound method). The realization is the small
`menuCreate` / `menuAddItem` / `menuAttach` vocabulary. **Placement resolves toward
app-level:** `XGApplication.setMainMenu(menu)` is the primary API — it *is* the AppKit
idiom (the menu belongs to `NSApplication`) — and the Win32/GTK drivers realize the
same model **per window**. Per-window menus (a distinct menu per document window) are
a later extension via `menuAttach(to: window)`.

**Alerts.** `XGAlert` over `NSAlert` / `MessageBox` / `GtkMessageDialog`. The neutral
call declares the buttons **and which is default / which is cancel** — a *role*, not
a position — and the driver orders them natively (Mac and Windows disagree on
OK/Cancel order; one source, native order on each).

**Focus & keyboard.** Mostly free on the hosts — a native `EDIT`/`GtkEntry`/
`NSTextField` does its own editing, cursor and selection — but two pieces are neutral
and will otherwise surface as "Tab does nothing" / "Enter doesn't fire the default
button": (a) `firstResponder` ↔ native focus is a **bidirectional sync** (the driver
reports a native focus change so the neutral `firstResponder` follows; a neutral
`makeFirstResponder` calls the driver's `focus`), and (b) tab order and the default /
cancel buttons are app-declared and neutral — `XTG-DESIGN.md` §4 already does this on
GEM via `form_keybd`. One driver op (`focus`) plus a neutral tab-ring.

**Timers.** A neutral `XGTimer` over `NSTimer` / `g_timeout` / `SetTimer` / the GEM
timer, so `XGApplication.run()` has somewhere to put them. A one-liner, but named.

## 6. Invariants: lifetime, structure, coordinates

These are settled rules, not open questions.

**Lifetime, structure and the reverse map are three separate concerns** that merge
differently per backend, which is exactly why a single "subview list" leaks:

| | ownership (strong ref) | structure (order/enumeration) | reverse map (`handle → view`) |
|---|---|---|---|
| **GEM** | new generic strong-ref array | `OBJECT[]` `ob_head`/`ob_next` (driver-read) | `views[index]` — reverse map **only** |
| **Win32** | generic strong-ref array | parent's child list (driver-read) | `GWLP_USERDATA` — **unretained** |

`GWLP_USERDATA` is unretained, so on Win32 the reverse map **cannot** be the owner.
The rule that falls out: **the generic layer owns lifetime (the strong refs); the
driver owns structure and the reverse map.** Structural queries (`childCount` /
`childAt` / `hitTest`) are driver ops; the generic layer never enumerates a
realization tree. On GEM this keeps `OBJECT[]` the single source of structure and
`views[]` the reverse map only.

**Handle width.** `XGHandle` is `pointer`-width (not a fixed `u32`/`u64`), so it rides
the per-target pointer width. GEM packs `(window:u16, index:u16)` — exact on the A9's
32-bit pointer, where GEM runs; a host holds a real 64-bit handle. Type-width-
invariant-adjacent: hardcode the width and it bites on a 64-bit host.

**Lifetime teardown.** `XGView.dealloc → driver.destroy(h)` **and** clear the reverse
slot, or a late OS callback dispatches into a freed view (the `crossmod`
`after-death=0` pattern, generalized). Design it into the first driver.

**Coordinates: top-left origin, y-down** is the neutral system (three of four hosts
and the A9 code). AppKit is bottom-left/y-up by default, so the AppKit driver
overrides **`NSView.isFlipped = YES`** on its content/custom views — the entire
subview layer is then natively y-down and needs no per-call flip; the one explicit
flip is at the `NSWindow` screen-frame boundary. `XGRect` is in **points**; the driver
maps to device pixels (HiDPI/Retina/GTK-scale) — a one-liner while scaling stays a
non-goal.

**Intrinsic size is native.** "Native look" is also native *size*: a button is as
wide as its title in the native font plus native padding, which differs per platform
and per locale ("Abbrechen" ≠ "Cancel"). The layout engine cannot place a native
control without asking — hence `sizeThatFits(h, limit)` in the driver
(`intrinsicContentSize`/`sizeThatFits:`, `gtk_widget_measure`, `DrawText(DT_CALCRECT)`,
`vqt_extent`). It takes a constraint from day one so a wrapping label doesn't force a
retrofit. A `setText` that changes intrinsic size must **mark layout dirty**.

**Redraw.** GEM is pull (the AES calls you during `wind_redraw`); Win32/GTK/AppKit are
invalidate→paint (also pull at the realization). Neutral `setNeedsDisplay` accumulates
a dirty rect; the driver's `invalidate` turns it into the platform's repaint request.

**Portable vs platform-specific apps.** A portable app never touches the driver (the
handle is opaque to it). A platform-specific app — **Rocks** — may `#import` the GEM
types and poke the `OBJECT[]` directly. So "Rocks is allowed to be GEM-only" is a
structural fact, not a rule to remember; a `.rsc` editor is inherently GEM-specific.

**Float ABI.** Each host toolkit's C ABI must match what xtc emits (the A9 already has
a `softfp`/`hard` question with `libGEM`, `XTG-DESIGN.md` §9). The callback proof
already links against clang/mingw output, so this is likely fine — confirm per host at
first link.

## 7. This rests on cross-`.so` override dispatch — the gate

When the library (`libXtg`) calls a custom view's `drawRect`/`mouseDown` through the
reverse map, and that override lives in the **app's** `.so`, the call crosses the
module boundary. xtc computes vtable slots by whole-program analysis and a client
recomputes them from the imported `.xtc.iface`; if they disagree, every override
silently mis-dispatches. This is `XTG-DESIGN.md` §9's #1 gating spike, and the handle
model depends on the same mechanism — so it adds **no new hazard**, it inherits the
existing one. On the A9 it is covered and passing; whether it holds on the hosts is
Spike 0.

## 8. What is proven, and the gap the hosts leave open

**Proven:**
- Xtg's toolkit + "view is a GEM object" — on the A9 (`XTG-DESIGN.md`, board-verified
  through clipping / scroll / slider / dirty-rects / scaling).
- **The reverse-map → override path itself** — `libtable` / `libdemo`: the *library*
  (`libXtg.so`) calls an *app-subclass's* `drawRect` / `mouseDown` override across the
  `.so`, and `libtable` additionally routes an optional protocol method through a
  bound-method pointer. That is the path the whole model rests on, running on the A9
  through the XTOS loader — the primary evidence, with `crossmod` (`bound-fire=55`,
  `after-death=0` weak-zeroing) as the mechanism cover.
- **Callback-with-context, cross-ABI** — a foreign C shim calls an xtc free function
  with a `void*` context; the callback recovers a seeded object by cast and dispatches
  a method. `count=105` on **arm64 (AAPCS)** and **win64 (Win64 ABI, under Wine)** from
  one source (`fpga-xtc/tests/interop/callback-context/`). The reverse-map's
  C-trampoline half, on two hosts.

**The gap:** the shared-object lifecycle the whole model rests on — `--emit-lib`
produce/consume, cross-`.so` override dispatch, weak-ref zeroing across the boundary,
`.xtc.iface` import — is **only proven on the A9**. The hosts have the linking/import
machinery (and the callback proof exercises import + C-ABI callback on arm64/win64)
but **not** the xtc↔xtc `.so` **override** + lifetime round-trip. That is Spike 0.

## 9. Enforce "the source stays the same" mechanically

Make requirement (1) a CI tripwire, like the type-width invariant:

- A **portable-app fixture** that must compile *and link* against **every** backend's
  Xtg libs. If it only builds for one, a platform-ism leaked.
- A **lint** that a portable source never `#import <GEM>` and never names a
  `G_*`/`ob_*` symbol. Rocks is explicitly exempt.

## 10. Spikes and milestones

Every milestone from M1 carries a **per-backend memory gate**: create/destroy N
windows+controls in a loop and assert **both** the driver's own native-object counter
(incremented in `create`, decremented in `destroy`) *and* the xtc allocator baseline
return to zero. This is the enforcement of §6's lifetime rule — the three concerns are
three leak sites (native object, front object, reverse-map entry), and a leak in any
one shows only under a create/destroy probe, never a functional test (the A9 saw a
100% Foundation leak sit behind a fully green suite; GTK floating refs and Win32 manual
`DestroyWindow` are the host analogues waiting to happen). The counter proves
create/destroy *balance*; a per-backend OS check (`IsWindow` false after destroy, a GTK
weak-ref notify, a zero AppKit `retainCount`) can strengthen it where cheap.

**Spike 0 — host shared-object lifecycle parity (do first).** Reproduce the
`libtable`/`libdemo` A9 result on the top-tier hosts (arm64, win64, x86_64):
`--emit-lib` a library class with a virtual method + a caller; in a separate app
`.so`/`.dylib`/`.dll`, `#import` it, subclass, override, and confirm the library
reaches the override — plus weak-zeroing when the app object dies and `.xtc.iface`
round-trip — **and** one **multi-argument** callback-with-context (the GTK `bind`
shape `cb(factory, item, ctx)` is the cleanest to test first, since the existing proof
only covers the one-arg `void cb(void*)` form). **Gate:** the known-good A9 oracle
reproduces on all three hosts. Needs no repo split. *If it fails*, the fallback is
ship-Xtg-as-source-per-app (`XTG-DESIGN.md` §9) — unglamorous but fine, and it changes
nothing else here.

**Spike 1 — one driver, one window, one custom view, one host.** Pick Win32
(reachable under Wine, pure C ABI, no ObjC bridge). `create(window)`,
`create(custom)`, `attach`, run the message pump, paint one rect via `XGContext`,
route one click through the reverse map into `XGView.mouseDown`. **First structural
act: split Xtg into its own repo** — the version gate and §9's link-against-every-
backend fixture both want a real library boundary, and now (right after Spike 0's
go/no-go, which decides whether binary `.so` distribution is even the model) is the
cheap time. **Gate:** a native window with a custom-drawn view that reports a click,
same neutral Xtg code path as GEM.

> **DONE (2026-07-18).** `XGWin32Driver` realizes the full `XGViewDriver` protocol over
> Win32/GDI: a shadow-tree structure model (the driver owns structure, as §6 requires —
> no `OBJECT[]`), a `WndProc` whose `WM_PAINT` flows *backend → the neutral draw seam*
> (`xtg_window_draw → treeDraw → xtg_userdraw → XGView.drawRect`, painting through
> `XGGdiGraphics`), a `GWLP_USERDATA` reverse map, and a message pump. `make win32-real`
> compiles the **actual** `XGWindow`/`XGView`/`XGViewTree` (not the seed's mini-toolkit)
> for win64 and runs them under Wine: `drawRect` paints via GDI and an injected click
> routes through the *same* `tree.hitTest` the GEM backend uses. The neutral layer now
> **runs** on a second backend, not just compiles — the seed's gap list is closed
> (structure relocated into the driver; `XGGraphics` is a swappable protocol; no GEM type
> reaches the neutral layer). Files: `XGWin32.h.xt`, `XGGdiGraphics.xt`, `XGWin32Driver.xt`,
> `test_win32_real.xt`. The one Win32-aware line in an app is `new XGWin32Driver()`.
>
> **Also done: the run loop.** `XGMenu` and `XGApplication` were the last GEM-coupled
> pieces above the driver; both are neutral now (the backend is *injected* — `gDriver` /
> `XGApplication.setDriver()` — not chosen inside `XGApplication`), so `make win64-lib`
> gates the **entire** neutral toolkit. `make win32-loop` runs a real app under
> `XGApplication.run()` on Win32: a posted `WM_LBUTTONDOWN` travels `nextEvent` (the
> message pump) → `dispatchEvent` → the window → `XGView.mouseDown`, and `WM_QUIT` ends
> the loop. The neutral event loop — not just paint and hit-test — now runs on a second
> backend. The neutral event loop — not just paint and hit-test — now runs on a second
> backend.
>
> **Also done: live controls, text editing, menus, and the §10 gate.** The Win32 driver
> is no longer stubbed above paint/click. `make win32-field` types into a real
> `XGTextField` through the message pump — `WM_CHAR → nextEvent → XGEventKeyDown →
> XGTextField.keyDown → driver.editText`, the driver being the edit engine that `objc_edit`
> is on GEM. `make win32-menu` builds an app-level `XGMenuBar` that the driver realizes as
> a per-window `HMENU`; a pick fires `WM_COMMAND`, decoded to a neutral `XGEventMenuSelect`
> and routed to the bound method — the same path GEM takes from `MN_SELECTED`. `make
> win32-memgate` is the Win32 instance of the §10 gate: open/close N forms (window + button
> + field), native-object counter **and** heap baseline both return to zero on the close()
> and dealloc paths. **M1 is met on Win32** for button/label/field + menus; remaining
> breadth is checkbox/radio/popup (new neutral controls, not yet in the toolkit) and
> per-character field validation.

**Spike 2 — AppKit / Objective-C bridge** (the go/no-go on Mac-native). Drive
`objc_msgSend` to open an `NSWindow` + `NSButton`, register a class with a callback
IMP, receive a click into an xtc method; native on the dev Mac. *If it passes*, AppKit
is a committed backend; *if not*, macOS uses a draw-everything fallback — the seam is
unaffected (Spike 1 already proved a non-GEM driver).

> **VERDICT: GO (2026-07-19).** The two hard bridge mechanisms are proven from xtc, native on
> arm64: **linking** (`xtc -A arm64 -framework Foundation` after COMPILER-THREAD #6 —
> `[[NSString stringWithUTF8String:] length]` == 5) and, the crux, **a custom ObjC class whose
> method IMP is an xtc function** — `objc_allocateClassPair` + `class_addMethod(&xtcFn, "v@:")` +
> `objc_registerClassPair`, then `objc_msgSend(inst, greet)` dispatches *into the xtc code*
> (`spikes/objc-custom-class-imp.xt`). That is the AppKit analogue of the Win32 WndProc / the GEM
> G_USERDEF callback: an `NSView` subclass whose `drawRect:` and action targets are xtc functions.
> So a real AppKit `XGViewDriver` is feasible. The one remaining gate for a *view* driver is
> COMPILER-THREAD #8 (struct-by-value through `objc_msgSend` — `NSRect` for `frame`/`setFrame:`
> geometry); a driver that tracks its own frames minimises the surface, but positioning `NSView`s
> needs it, so the full driver waits on #8. Everything else — class registration, dispatch,
> callbacks — is in hand.
>
> **UPGRADE: the full view+draw path now RUNS (2026-07-19).** Not just the primitives — the actual
> AppKit driver core is demonstrated end to end (`spikes/appkit-drawrect.xt` + `-shim.m`). A custom
> `NSView` subclass (`XGDrawView`) is registered, made the window's `contentView`, and *drawn*; AppKit's
> own draw machinery calls `drawRect:` **into an xtc function** (registered as `&myDraw`), which then
> **paints** via a drawing primitive — verified headless via an offscreen bitmap cache
> (`cacheDisplayInRect:toBitmapImageRep:`), so it needs no visible window or run loop. This also
> dissolves the #8 caveat: a thin ObjC shim owns the `NSRect` boundary (`drawRect:`'s rect is absorbed
> by a C trampoline and handed to xtc as `x,y,w,h` primitives; `initWithFrame:`/`setFrame:` take ints),
> so **struct-by-value never crosses into xtc** and the driver is unblocked *today*. #8 remains a
> cleanup (drive `objc_msgSend` structs directly, no shim), not a prerequisite. Spike 2 is not merely
> GO — its hardest loop (window → custom view → xtc `drawRect:` → xtc paint) is working code.
>
> **Both halves of the loop now run, and the paint vocabulary is pixel-verified.** Three spikes:
> - `spikes/appkit-drawrect.*` — the *draw callback*: a custom `NSView`'s `drawRect:` is an xtc function.
> - `spikes/appkit-action.*` — *input*: an `NSButton` target/action fires into xtc on `performClick:`.
> - `spikes/appkit-graphics.*` — the *drawing vocabulary*: xtc drives fill/stroke/text into an offscreen
>   `NSBitmapImageRep`, and pixel readback confirms it landed (fill@(20,20) reads the exact red asked
>   for). This is the one draw-path piece that's fully headless-verifiable, and it is.
> So the three things a UI backend must do — *paint on demand*, *have something to paint with*, and
> *deliver input* — all dispatch into xtc across the ObjC boundary, as working code.
> What's left for a real `XGViewDriver` is engineering (map XG's driver seam onto these shim calls,
> integrate the run loop), not risk: every mechanism it depends on is demonstrated working code.
>
> **The driver, scoped.** `XGViewDriver` (XG/XGViewDriver.xt) is ~50 methods; the existing backends
> are `XGWin32Driver` 519 lines and `XGGemDriver` 402, so an `XGAppKitDriver` is comparable — plus a
> C/ObjC shim (the `spikes/appkit-*-shim.m` pattern, grown up) owning every `NSRect`/struct boundary.
> Mapping, by group:
> - **window\*** → `NSWindow` (`initWithContentRect:` via shim ints; `setTitle:`, `orderFront:`,
>   `close`; `windowSetContent`'s draw callback → the `XGDrawView`/`drawRect:` trampoline, proven).
> - **struct\*** (the tree model) → an owned `OBJECT[]`-shaped array *or* a tree of `NSView`s; the
>   `structAdopt` path (a `.rsc` tree) argues for keeping the neutral `OBJECT[]` and letting the
>   driver *draw* it (like GEM), rather than one `NSView` per object — less AppKit, more reuse.
> - **treeDraw / beginViewDraw** → `XGGraphics` over an `NSGraphicsContext` (the shim's `xg_fill`
>   generalised to lines/text/blits); drives from `drawRect:`, proven.
> - **editText / fieldEditor\*** → `NSText`/field editor, or reuse the neutral edit engine over a
>   custom-drawn field (as GEM now does post-#7) — the lower-risk path.
> - **menuBuild/Show, alertRun** → `NSMenu` / `NSAlert` (both native, both need the run loop live).
> - **nextEvent / pumpMessages** → the crux: an `NSApplication` run-loop pump
>   (`nextEventMatchingMask:untilDate:inMode:dequeue:` + `sendEvent:`) translated to `XGEvent`.
> - **boot / liveNativeCount** → `sharedApplication` (proven) + the §10 native-object counter.
> This is buildable now; it's deferred only because most of it (the event pump, menus, alerts,
> interactive editing) wants interactive verification, which the headless spikes above can't give —
> so it's a milestone to build where it can be exercised, not an overnight green-slice.
>
> **BUILT (2026-07-20) — the third backend runs, four verified slices.** `XGAppKitDriver` +
> `XGCocoaGraphics` + the `libXGAppKit.m` shim now run the ACTUAL neutral layer (XGWindow/XGView/
> XGViewTree/XGButton/XGTextField) native on macOS, the only backend-aware line being `gDriver = new
> XGAppKitDriver()`. It reuses the Win32 driver's shadow-tree / hit-test / editText / state
> (backend-neutral) and swaps drawing (NSGraphicsContext), windowing (NSWindow), events (the
> NSApplication run loop), and boot for shim calls; the `XGDrawView` is flipped so the toolkit's
> coordinates map straight through. All four slices verify headless (offscreen `cacheDisplayInRect:`,
> synthetic `NSEvent`s through the real queue), each a `make` target:
> - **`appkit`** — paint: the custom view draws through the neutral seam, pixel readback confirms it,
>   a click routes through the shared hit-test (canvas mouseDown + button action fire).
> - **`appkit-loop`** — the run loop: a posted `NSEvent` travels `nextEvent -> dispatchEvent -> the
>   view` under `XGApplication.run()`. (Wrinkle solved: without a full `[NSApp run]`, a `postEvent:`
>   is invisible to `nextEventMatchingMask` until the CFRunLoop is pumped.)
> - **`appkit-field`** — keyboard: a posted key-down edits the focused field via the reused `editText`
>   engine (`Hi`+BS+`o` -> `Ho`).
> - **`appkit-memgate`** — §10: a create/destroy loop returns the native-object counter to zero
>   (deterministic MRC lifetime; the malloc-address heap oracle is printed but not asserted — Cocoa
>   churns its own caches, so it isn't a valid leak detector for this backend).
>
> What remains for a full driver is **menus (`NSMenu`), alerts (`NSAlert`), and scrolling** — the
> pieces that are genuinely modal/interactive and want a shown-window GUI session to verify (they are
> stubs today). Also #10's HFA `objc_msgSend` means the shim's int-based geometry could later drive
> `NSView.frame` directly. Everything the "neutral layer runs native with full input" milestone needs
> is working code.

**M1 — the stock control set on one host.** `button/label/field/checkbox/radio/popup`
via `create(kind)`, target/action firing, `setText`/`setEnabled`. **Gate:** a form
with live controls, driven by injected events, same source as the GEM form (+ memory
gate).

**M2 — layout, intrinsic size, and a compound control.** The neutral box/stack engine
places native controls by computed rect using `sizeThatFits`; `XGScrollView` /
`XGTableView` as compound kinds — native on the hosts (with the datasource bridge),
composition on GEM. **Gate:** a scrolling table of native cells with correct native
sizing (+ memory gate).

**M3 — native subsystems.** `XGMenu` (app-level main menu; Mac-native, per-window on
the others), `XGAlert` with role-ordered buttons, focus / tab traversal. **Gate:** a
menu bar, a native modal dialog with platform-correct OK/Cancel order, and Tab/Enter
working — same source (+ memory gate).

**M4 — the same app, two hosts.** One non-trivial app (a converter, a small editor)
built unmodified for two hosts, driven by a scripted event sequence to **identical
logical output**. The headline: one source, native on two hosts (+ memory gate).

**M5 — the A9 rejoins.** The same app source runs on GEM via the existing Xtg backend,
unchanged. Three backends, one source (+ memory gate).

## 11. Where this lives

Today, `Rocks/doc` beside `XTG-DESIGN.md`. The repo split (Spike 1) moves Xtg to its
**own repo** — it is a library on top of GEM, not part of it, and not part of the
compiler either (`XTG-DESIGN.md` §9 open-question 1); the multi-backend story makes it
larger still. The fpga-xtc note `docs/Design/cross-platform-gui.md` is a retracted
stub pointing here; the callback proof it references lives at
`fpga-xtc/tests/interop/callback-context/`.
