# Xtg across the desktop hosts — one source, native look

**Status: design proposal, for review.** Companion to `XTG-DESIGN.md`, which
designs Xtg *over GEM for XTOS/A9*. This doc asks the next question: can the
**same** AppKit-shaped Xtg API also render through the native toolkits of the
desktop hosts — AppKit (macOS), Win32 (Windows), GTK (Linux) — so one program
source runs, and looks native, on all of them plus the A9?

It defers to `XTG-DESIGN.md` for everything about the GEM backend's internals.
It does not touch the app-visible API that doc already defines.

## 0. The two requirements (and nothing else)

From the maintainer, and they are the whole spec:

1. **The app source stays the same** across platforms.
2. **The look-and-feel is native** on each.

Implementation differences between backends are explicitly *not* a concern.
That freedom is what makes this tractable.

## 1. The reframe: Xtg already is the toolkit; this adds backends

Xtg is not a widget layer to be built — it exists and is largely board-verified
on the A9: `XGApplication`, `XGWindow`, `XGView`, `XGResponder` (a real
responder chain by forwarding, not reflection), `XGControl` with target/action,
the stock controls, `XGMenu`, `XGAlert`, `XGScrollView`, `XGTableView`,
`XGOutlineView`, `XGNib`. It has **one backend today: GEM/AES**, where — per
`XTG-DESIGN.md` §3 — *a view is a GEM object* (an `OBJECT` in an AES tree,
themed for free, drawn by the AES calling back into `drawRect` through the
`G_USERDEF` seam).

So the task is not "design a portable widget toolkit." It is: **give Xtg's
existing API a second and third backend, so the same source targets AppKit /
Win32 / GTK alongside GEM.** That framing is the whole difference between this
and a from-scratch cross-platform GUI.

## 2. The model: an opaque handle + a per-platform stateless driver

The tempting move — a generic widget that *holds a* per-platform "peer" object —
is wrong twice over: it allocates an object per widget (a cost the A9 can least
afford), and it forces a uniform per-widget shape onto every backend, which
makes GEM's "a control is an `int16` index into an array" wear an object costume
it doesn't fit.

The right move is one more level of indirection, and it *removes* an assumption
rather than adding one:

> The generic layer holds an **opaque handle** it never dereferences. Each
> backend decides what the handle means. A per-platform **stateless driver**
> interprets handles.

The generic layer thereby assumes neither "object" nor "array" — it assumes a
word. And the payoff is that on three of the four platforms the native thing
*already is* an opaque handle: `HWND`, `GtkWidget*`, `NSView*`. There the
`GHandle` **is** the native handle, zero wrapping. On GEM it is the
`(window, index)` pair Xtg already owns — so "keep the AES hierarchy for GEM"
stops being a special accommodation and becomes simply what the GEM driver
stores in its handle.

```
    ┌──────────────────────────────────────────────────────────┐
    │  Generic Xtg  (written ONCE, portable)                    │
    │    GView / GControl / GResponder / GWindow / GApplication  │
    │    holds:  GHandle handle   (opaque — never dereferenced)  │
    │    owns:   responder chain, target/action, delegation,     │
    │            geometry, layout, dirty accumulation,           │
    │            table/outline projection                        │
    └───────────────────────────┬──────────────────────────────┘
                                 │  speaks handles
                 ┌───────────────┼───────────────┬───────────────┐
                 ▼               ▼               ▼               ▼
            GEM driver      Win32 driver     GTK driver     AppKit driver
         handle = (win,idx)  handle = HWND  handle=GtkWidget* handle=NSView*
         (Xtg's guts, kept)  (native)        (native)        (native)
```

The driver is **one per platform, not one per widget** — a stateless object (it
can be a process singleton, so a view need not even carry a driver field, only
its handle). Its whole surface is roughly:

```
protocol GViewDriver {
    GHandle create(GKind kind);                 // native realization for a kind
    void    attach(GHandle parent, GHandle child, GRect frame);
    void    destroy(GHandle h);                 // frees native + clears reverse map
    GRect   frameOf(GHandle h);                 // truth lives natively, not in GView
    void    setFrame(GHandle h, GRect r);
    void    setText(GHandle h, XGString@ s);
    void    setEnabled(GHandle h, bool on);
    void    invalidate(GHandle h, GRect r);     // "needs display" → native repaint
    GHandle hitTest(GHandle root, GPoint p);    // native z-order / disabled state
    // NOTE: there is no draw() here — drawing flows the OTHER way (§4).
}
```

**What is neutral (written once) vs realized (per driver):**

| Neutral — generic Xtg | Realized — per driver |
|---|---|
| responder chain (forwarding) | `create` / `attach` / `destroy` |
| target/action + bound methods | frame get/set (native is the truth) |
| delegate/datasource protocols | `setText` / `setEnabled` / `setValue` |
| geometry + layout math | `invalidate` → native repaint request |
| dirty-rect accumulation | `hitTest` (native) |
| table/outline projection, cell recycling | event source → normalized `GEvent` |
| ownership / view enumeration (see §7 open pt) | `GContext` drawing primitives (custom kinds) |
|  | reverse map `handle → GView` + its lifetime |

The generic `GView` holds **no realization state** — no frame field, no native
handle interpretation. It asks the driver. On GEM the frame's truth is the
`OBJECT`'s `ob_x/y/w/h`; a shadow copy in a generic field is a second source of
truth waiting to diverge.

**Honest cost.** Versus the peer-object model this is strictly leaner in memory
(one scalar handle per view, plus a shared singleton driver — no per-widget
object), at the cost of one extra indirection (the driver dispatch) per
realization call. That indirection is noise next to a blit or a native control
update. Leaner in footprint; not slower in any way that matters.

## 3. The two cross-backend contracts — keep them minimal

The seam did not vanish; it became **two vocabularies**, and both deserve the
same paranoia as the type-width invariant (every entry is paid on every
backend, and is a place backends can silently disagree):

1. **`GKind`** — the set of things `create(kind)` can make. Every backend must
   map every kind to a native realization. Keep it to **primitives + custom**.
   The compound controls (`XGTableView`, `XGOutlineView`, `XGScrollView`) are
   **not** kinds — they are neutral logic that composes primitive-kind handles
   (exactly the viewport/projection Xtg already does, `XTG-DESIGN.md` §10). That
   is what keeps `GKind` small.

2. **`GContext`** — the drawing primitives a custom view's `drawRect` uses. It
   must be implementable over VDI (GEM), GDI/Direct2D (Win32), Cairo (GTK) and
   CoreGraphics (AppKit), so it is the *intersection* that still yields
   native-enough custom drawing: text, lines, fills, images, clip, transform.

### Kind → native realization

The thesis in one table — stock controls cost **zero** drawing code on every
host, because each is a real native control the platform themes/paints:

| `GKind` | GEM | Win32 | GTK | AppKit |
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

Only `custom` routes `drawRect` back. Everything else is native and free — which
is how "native look" is met without a rendering engine per platform.

## 4. Drawing, events, and the reverse map (= the callback bridge)

Drawing flows **backend → view**, so it is not a driver method. When the
platform needs a custom view painted (AES traversal hits a `G_USERDEF`; Win32
gets `WM_PAINT`; AppKit calls `drawRect:`), the backend uses the **reverse map**
`handle → GView` to find the front object and calls its `drawRect(GContext,
dirty)`. Same shape for input: "this handle was clicked" → reverse map → the
`GView` → the neutral responder/target-action dispatch.

The reverse map is the one genuinely-new-per-backend piece, and every platform
has a natural slot for it: Win32 `GWLP_USERDATA`, GTK `user_data`, AppKit the
control's `target`, GEM the `views[index]` side array Xtg already keeps
(`objc_set_userdraw` + `viewAt`). It is exactly the **callback-with-context**
mechanism — and it is already proven cross-ABI (see §6).

**`GWidgetPeer` vs `GDrawablePeer` collapses.** An earlier draft split "stock
control draws itself" from "custom view draws" into two protocols. In the handle
model that distinction is just a property of `create(kind)`: a `button` handle
never routes `draw`; a `custom` handle does. One vocabulary, not two protocols.

## 5. This rests on cross-`.so` override dispatch — no new risk, but it's the gate

When the library (`libXtg`) calls a custom view's `drawRect`/`mouseDown` through
the reverse map, and that override lives in the **app's** `.so`, the call
crosses the module boundary. xtc computes vtable slots by whole-program analysis
and a client recomputes them from the imported `.xtc.iface`; if they disagree,
every override silently mis-dispatches. This is `XTG-DESIGN.md` §9's #1 gating
spike, and it is the same mechanism the handle model depends on — so this adds
**no new hazard**, it inherits the existing one.

On the A9 that mechanism is covered and passing (`fpga-xtc/tests/crossmod/`:
`bound-fire=55` app-method-through-library-widget, `after-death=0`
weak-zeroing). The open question is whether it holds on the **hosts** — see §6.

## 6. What is proven, and the gap the hosts leave open

**Proven:**
- Xtg's toolkit + the "view is a GEM object" model — on the A9 (`XTG-DESIGN.md`,
  board-verified through clipping/scroll/slider/dirty-rects/scaling).
- Cross-`.so` override dispatch + weak lifetime + `.xtc.iface` import — on the
  A9 (`tests/crossmod`, via the XTOS loader).
- **Callback-with-context, cross-ABI** — a foreign C shim calls an xtc free
  function with a `void*` context; the callback recovers a seeded object by cast
  and dispatches a method. `count=105` on **arm64 (AAPCS)** and **win64 (Win64
  ABI, under Wine)** from one source (`fpga-xtc/tests/interop/callback-context/`).
  This is the reverse-map's C-trampoline half, on two hosts.

**The gap (and the maintainer's stated next exercise):** the shared-object
lifecycle the whole model rests on — `--emit-lib` produce/consume, cross-`.so`
override dispatch, weak-ref zeroing across the boundary, `.xtc.iface` import — is
**only proven on the A9**. The hosts have the *linking/import* machinery
(`fpga-xtc` builds `.dylib`/`.dll`/`.so` and the callback proof exercises import
+ C-ABI callback on arm64/win64) but **not** the xtc↔xtc `.so` **override** +
lifetime round-trip. That is Spike 0 below.

## 7. Open design points (for the Rocks thread to weigh)

- **The subview tree may exist twice on GEM.** If generic `GView` keeps an
  `Array@ subviews` (portable bookkeeping) *and* the GEM backend keeps the
  `OBJECT[]` `ob_head`/`ob_next` links, that is two representations to keep in
  sync (only `attach`/`detach` mutate, so it is bounded — but it is duplication).
  Lean: make **structural queries driver ops** — `childCount`/`childAt` and
  `hitTest` — so GEM stays single-source (the `OBJECT[]`) and hosts back them by
  a kept list, while the generic layer holds only ownership/responder links. To
  settle.
- **`GHandle` must be `pointer`-width**, not a fixed `u32`/`u64`, so it rides the
  per-target pointer width. GEM packs `(window:u16, index:u16)` — exact on the
  A9's 32-bit pointer, which is where GEM runs; a host holds a real 64-bit
  handle. This is type-width-invariant-adjacent: hardcode the width and it bites
  on a 64-bit host.
- **Lifetime is where the bugs will live.** `GView.dealloc → driver.destroy(h)`
  **and clear the reverse slot**, or a late OS callback dispatches into a freed
  view. This is the `crossmod` `after-death=0` pattern generalized — the reverse
  map is weak/cleared on destroy. Design it into the first driver.
- **Redraw model.** GEM is pull (AES calls you during `wind_redraw`); Win32/GTK/
  AppKit are invalidate→paint (also pull at the realization). Neutral
  `setNeedsDisplay` accumulates a dirty rect; the driver's `invalidate` turns it
  into the platform's repaint request. Xtg §6 already works this way; it
  generalizes.
- **Portable vs platform-specific apps.** A portable app never touches the
  driver (the handle is opaque to it). A platform-specific app — **Rocks** — may
  `#import` the GEM types and poke the `OBJECT[]` directly. So "Rocks is allowed
  to be GEM-only" becomes a structural fact, not a rule to remember. A `.rsc`
  editor is inherently GEM-specific; that is fine.
- **Float ABI on the hosts** (cf. `XTG-DESIGN.md` §9): the A9 already has a
  `softfp`/`hard` question with `libGEM`. Each host toolkit's C ABI must match
  what xtc emits — the callback proof already links against clang/mingw output,
  so this is likely fine, but confirm per host at first link.

## 8. Enforce "the source stays the same" mechanically

Make requirement (1) a CI tripwire, like the type-width invariant:

- A **portable-app fixture** that must compile *and link* against **every**
  backend's Xtg libs. If it only builds for one, a platform-ism leaked.
- A **lint** that a portable source never `#import <GEM>` and never names a
  `G_*`/`ob_*` symbol. Rocks is explicitly exempt.

That turns "source stays the same" from a convention into something the build
enforces.

## 9. Spikes and milestones

**Spike 0 — host shared-object lifecycle parity (do first; the maintainer's ask).**
Reproduce `tests/crossmod` on the top-tier hosts (arm64, win64, x86_64), not
just the A9: `--emit-lib` a library class with a virtual method + a caller;
in a separate app `.so`/`.dylib`/`.dll`, `#import` it, subclass, override, and
confirm the library reaches the override — plus weak-zeroing when the app object
dies, and `.xtc.iface` round-trip. **Gate:** the crossmod expected output
(`bound-fire`, `after-death=0`, the `ii-*` inheritance-across-`.so` cases)
reproduces on all three hosts. *If it fails*, the fallback from `XTG-DESIGN.md`
§9 applies (ship Xtg as source per app) — unglamorous but fine, and it changes
nothing above.

**Spike 1 — one driver, one window, one custom view, one host.** Pick Win32
(reachable under Wine, pure C ABI, no ObjC bridge). `create(window)`,
`create(custom)`, `attach`, run the message pump, paint one rect via `GContext`,
route one click through the reverse map into a `GView.mouseDown`. **Gate:** a
native window with a custom-drawn view that reports a click — same neutral Xtg
code path as GEM.

**Spike 2 — AppKit / Objective-C bridge** (the go/no-go on Mac-native). Drive
`objc_msgSend` to open an `NSWindow` + `NSButton`, register a class with a
`GCallback` IMP, receive a click into an xtc method. Runs native on the dev Mac.
*If it passes*, AppKit is a committed backend; *if not*, macOS uses the
draw-everything fallback — the seam is unaffected (Spike 1 already proved a
non-GEM driver).

**M1 — the stock control set on one host.** `button/label/field/checkbox/radio/
popup` via `create(kind)`, target/action firing, `setText`/`setEnabled`. **Gate:**
a form with live controls, driven by injected events, same source as the GEM
form.

**M2 — layout + scrolling + a compound control.** The neutral layout engine
places native controls by computed rect; `XGScrollView`/`XGTableView` as neutral
compositions of primitive handles. **Gate:** a scrolling table of native cells.

**M3 — the same app, two hosts.** One non-trivial app (a converter, a small
editor) built unmodified for Win32 **and** GTK (or AppKit), driven by a scripted
event sequence to **identical logical output**. This is the headline: one
source, native on two hosts.

**M4 — the A9 rejoins.** The same app source runs on GEM via the existing Xtg
backend, unchanged. Three backends, one source.

## 10. Where this lives

For now, here in `Rocks/doc` beside `XTG-DESIGN.md`. Longer term Xtg likely
deserves its **own repo** — it is a library on top of GEM, not part of it, and
not part of the compiler either (`XTG-DESIGN.md` §9 open-question 1), and the
multi-backend story makes it larger still. Deferred.

## 11. Addendum — review from the A9 / Rocks side

Notes from the thread that built and board-verified the GEM backend (Xtg-over-GEM,
`XTG-DESIGN.md`) and Rocks. The handle-plus-driver model above is right, and most of
this is additive. One point is a genuine correction, and it lands at the widget this
thread just finished building. Ordered by how much each changes the design.

### 11.1 Compound controls must be able to *be* native — the one real correction

§3 keeps `GKind` small by ruling that `TableView` / `OutlineView` / `ScrollView` are
**not** kinds — they are neutral logic composing primitive handles. That is exactly right
**for GEM**, where a table genuinely *is* a `G_USERDEF` row plus `G_STRING` cells (this
thread built it that way, `XTG-DESIGN.md` §10). It does **not** hold on the hosts, and it
fails precisely where requirement (2) is most visible.

A table is the poster child of native look-and-feel. `NSTableView` has alternating rows,
the system selection tint, a header with sort indicators, native keyboard navigation;
`GtkTreeView` and `SysListView32` the same. A composition of `NSTextField` primitives
reproduces **none** of it. Scrolling is the same story: `NSScrollView` has elastic
rubber-band scroll that a scrollbar-plus-clip composition cannot have. So "compound =
composition" optimises for GEM and a minimal seam **at the cost of the native feel of the
most recognisable widgets** — which is the requirement, not a nicety.

The fix keeps everything the model wants and costs only a slightly larger `GKind`:
**compound controls *are* kinds, and a kind's realization is the driver's choice** — a
native compound control where the toolkit has one, a composition where it does not.

| compound `GKind` | GEM | Win32 | GTK | AppKit |
|---|---|---|---|---|
| `table`   | compose `custom`+`label` (current Xtg) | `SysListView32` | `GtkTreeView` | `NSTableView` |
| `outline` | compose (current Xtg) | `SysTreeView32` | `GtkTreeView` (tree) | `NSOutlineView` |
| `scroll`  | AES scrollbar + content-size | `WS_*SCROLL` / native | `GtkScrolledWindow` | `NSScrollView` |

The neutral **logic** does not move: the datasource/delegate protocol, cell recycling,
and the selection model stay generic and written once — and they map cleanly onto the
native controls *because those controls are themselves datasource-driven*
(`NSTableViewDataSource`, `GtkTreeModel`). GEM's realization of these kinds **is** the
composition this thread already wrote, so nothing is lost there. The net: one source, a
native table on the hosts, the composition preserved on GEM, and the datasource API is the
seam that makes both true. "Keep `GKind` to primitives + custom" is correct for
*primitives*; extending it to "never a compound kind" is what breaks native look.

### 11.2 Ownership / structure / reverse-map are *three* concerns, not two trees

§7's first open point ("the subview tree may exist twice on GEM") is really three concerns
that collapse **differently per backend**, and naming them is what prevents the sync bugs:

- **ownership** — who holds the strong ARC reference that keeps a child alive;
- **structure** — child order and enumeration (draw order, next-sibling);
- **reverse map** — `handle → GView`, for routing a native callback to the front object.

They merge differently on each backend, which is exactly why a single "subview list"
assumption leaks:

| | ownership | structure | reverse map |
|---|---|---|---|
| **GEM** | `views[index]` (strong) | `ob_head`/`ob_next` | `views[index]` — *same array as ownership* |
| **Win32** | must be held generically | parent's child list | `GWLP_USERDATA` — **unretained**, so *not* ownership |

So `GWLP_USERDATA` cannot be the owner (the OS won't keep the view alive for ARC), and on
GEM the `views[]` side-array is already doing double duty. The rule that falls out, and
that keeps GEM single-source for structure: **the generic layer owns lifetime (the strong
refs); the driver owns structure and the reverse map.** Then `childCount`/`childAt`/
`hitTest` are driver ops (GEM answers from `OBJECT[]`, hosts from a kept list), the generic
layer never enumerates a realization tree, and there is no second *structural* copy to
drift.

### 11.3 A per-backend memory gate belongs in from M1 — even though the leak is fixed

The Foundation types (`Array` et al.) were leaking **totally** on the A9 until just now —
`free` was wrapped in `#if defined(6502)` and compiled to nothing everywhere else, so a
100%-leak sat behind a fully green test suite for the entire life of the toolkit. It took a
deliberate allocator probe (`test_leak`: grab a block, free it, do N cycles, grab again,
assert the address does not move) to see it; no functional test ever would.

That episode is the argument, not the leak itself (now fixed by the `u32` Foundation
rewrite). A four-backend toolkit that "holds hundreds of live objects" rides directly on
those types, and §9's milestones have no memory gate before an implied M7. It should be a
**per-backend gate from M1**: create/destroy N windows+controls in a loop and assert the
native object count *and* the xtc allocator both return to baseline. A leak that only shows
under a compositor, or only on one backend's native-lifetime rules (GTK floating refs,
Win32 manual `DestroyWindow`), is exactly the kind a functional suite passes over.

### 11.4 §6's "proven" list understates the A9 evidence

§6 cites `crossmod` (`bound-fire`, `after-death`). The stronger, more on-point proof exists
already: **`libtable` / `libdemo`** — the *library* (`libXtg.so`) calls an *app-subclass's*
`drawRect` / `mouseDown` override **across the `.so` boundary**, and `libtable` additionally
routes through an **optional protocol method reached via a bound-method pointer**. That is
not a proxy for the reverse-map→override path the whole model rests on — it *is* that path,
running on the A9 through the XTOS loader. Worth citing directly in §6's proven list, and it
tightens what Spike 0 has to reproduce on the hosts (it is reproducing a known-good A9
result, not exploring).

### 11.5 Naming: `XG*` → `G*`, settled

Decided (maintainer): every `XG*` symbol becomes `G*` — `XGView` → `GView`,
`XGTableView` → `GTableView`, and so on. The `X` stood for "**X**tg over **G**EM"; a
GEM-specific prefix *is* the built-in assumption this whole exercise removes, so it goes.
Mechanical, but far cheaper at the spike than after a control set exists — it should happen
**before** the first driver is written, so no symbol is ever born with the old name.

### 11.6 Split the repo at the spike, not after

§10 defers the own-repo question. Two mechanisms in this very doc want the boundary to be
real *now*: the version gate (`Xtg_abi_1_0`, `XGVersion.xt` — the loader refuses a stale
library by name) and §8's portable-app fixture that "must link against **every** backend's
Xtg libs." Both are awkward or meaningless inside Rocks' tree. The split is low-risk — it is
moving files and turning Rocks' relative imports (`-I ../xtg`) into a library import — and
doing it at the spike means the multi-backend structure is laid down in the repo that will
hold it, rather than retrofitted.
