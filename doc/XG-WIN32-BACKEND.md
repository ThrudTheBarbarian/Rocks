# XG on Win32 — the second backend

Status reference for the Win32 realization of the XG toolkit (the multiplatform work in
[XTG-MULTIPLATFORM.md](XTG-MULTIPLATFORM.md)). The claim of that design is that the neutral
toolkit talks only to a per-platform `XGViewDriver`, so a second backend is a second
implementation of that one interface and **nothing above it changes**. This documents how far
that claim has been carried on Win32.

## What it is

`XGWin32Driver` implements the full `XGViewDriver` protocol over the Win32 / GDI C ABI — which
is exactly what `xtc -A win64` emits, so it binds directly, no shim. Three files:

| File | Role | GEM counterpart |
|---|---|---|
| `XG/XGWin32.h.xt` | Win32 / GDI / menu / scrollbar bindings + constants | `XGGem.h.xt` |
| `XG/XGGdiGraphics.xt` | the GDI realization of the `XGGraphics` protocol | `XGGemGraphics.xt` |
| `XG/XGWin32Driver.xt` | the driver: shadow-tree structure model, `WndProc`, hit-test, message pump, menus, alerts, scrolling, the field edit engine | `XGGemDriver.xt` |

Where GEM has the AES's `OBJECT[]` and `objc_draw`/`objc_find`/`objc_edit`, this driver keeps
its **own** shadow tree (a flat node array with parent/sibling links, per §6 — the driver owns
structure) and walks it itself. HWNDs are pointer-width, so they live in a table indexed by the
`i32` handle the protocol uses. Paint flows *backend → the neutral seam*: `WM_PAINT →
xtg_window_draw → treeDraw → xtg_userdraw → XGView.drawRect`, painting through `XGGdiGraphics`.

The **one** Win32-aware line in an application is `new XGWin32Driver()` (or, for a program
linking `libXG.so`, `app.setDriver(new XGWin32Driver())`). Everything else — views, controls,
the window, the run loop, the responder chain, target/action — is the same neutral source that
runs on GEM.

## Demos (each is a `make` target, built for win64 and run under Wine)

Every demo is headless-deterministic: it forces the interaction through the real message queue
and checks sentinels, so `make <target>` recompiles from source, runs it under Wine, shows the
output, and verifies it. All skip cleanly when Wine is absent.

| `make` target | Proves |
|---|---|
| `win32` | the M1/Spike-1 seed: a native window + custom view + a click (a self-contained mini-toolkit) |
| `win32-real` | the **real** neutral `XGWindow`/`XGView`/`XGViewTree` paint via GDI + a click through the same `tree.hitTest` GEM uses; the §10 native-object count returns to zero |
| `win32-loop` | the neutral **run loop** — `XGApplication.run()` pumping the real Win32 queue (a posted `WM_LBUTTONDOWN` → `nextEvent` → `dispatchEvent` → `mouseDown`; `WM_QUIT` ends it) |
| `win32-field` | **live text editing** — `WM_CHAR` → `nextEvent` → `XGTextField.keyDown` → `driver.editText` (the driver is the edit engine `objc_edit` is on GEM) |
| `win32-valid` | per-character field **validation** ("99999" rejects letters keystroke-by-keystroke) |
| `win32-menu` | **menus** — an app-level `XGMenuBar` realized as a per-window `HMENU`; a pick fires `WM_COMMAND` → neutral `MenuSelect` → the bound method |
| `win32-focus` | keyboard **focus traversal** + the default button — the neutral tab-ring, no Win32-specific focus code |
| `win32-check` | a **checkbox** (custom-drawn neutral control) toggling on click |
| `win32-radio` | **radio buttons** — mutual exclusion in a group |
| `win32-alert` | modal **alerts** — a native `MessageBox`, result mapped to the neutral button index (dismissed via a WH_CBT hook for the headless test) |
| `win32-scroll` | vertical **scrolling** — a native `WS_VSCROLL` bar drives the neutral offset, so the tree and hit-testing scroll for free (§11) |
| `win32-kitchensink` | the **capstone**: a whole form (menu + label + field + checkbox + radio group + Submit button) composed in one window and driven end to end |
| `win32-memgate` | the §10 **memory gate**: open/close N forms, native-object counter AND heap baseline both return to zero on the close() and dealloc paths |
| `win64-lib` | a compile gate: the **entire** neutral toolkit (views, controls, window, menu, alert, `XGApplication`) compiles for win64 — nothing above the driver names a GEM type |

## Status

**M1 is met on Win32.** The stock control set — button, label, field (with validation),
checkbox, radio — plus menus, alerts, focus/keyboard, scrolling, the run loop, and the memory
gate all run under Wine, driven by the same neutral source the GEM suite uses. The neutralization
that made this possible (relocating the `OBJECT[]` structure into the driver, making `XGGraphics`
a swappable protocol, injecting the backend into `XGApplication`, and moving the menu/alert
string formats out of the neutral layer) is complete: `make win64-lib` gates it.

**Stubbed / not yet done:** popup/dropdown control; per-window *distinct* menus (the app-level
menu is realized per-window, which is the common case); timers (`XGTimer`). Scrolling covers
both axes.

**Known issues:**
- **#6 (blocks AppKit):** xtc has no way to link a system library that isn't a `#import <Lib>`
  DWARF `.so`, so the ObjC runtime can't be linked — Spike 2 (the AppKit backend) is parked
  pending a linker passthrough. See COMPILER-THREAD.md #6.
- **#7 (GEM-only):** focusing a GEM text field DATA-ABORTs in libGEM's `objc_edit` when the tree
  also holds a custom-drawn control (a G_USERDEF checkbox/radio). Win32 is unaffected; each GEM
  control works individually. Repro: `spikes/gem-field-userdef-abort.xt`. See COMPILER-THREAD.md #7.
