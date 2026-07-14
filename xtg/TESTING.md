# What is verified, and how

This project has learned, expensively, that **"it builds" means nothing**. The
depth-8 tree truncation, the dangling VDI surface, the `vs_clip` push-vs-pop, and
five separate compiler miscompiles **all compiled clean**. So the status of every
claim is recorded here, and "verified" always means *run*.

## gemd now DUMPS THE SCREEN as ASCII art

`gemd` prints an ASCII-art rendering of the framebuffer to the console. It is a good debug
feature and it will wreck a naive test harness: it floods stdout, and a grep for failure will
happily match the art. Filter it — every art line is made only of `-*:=. ~+#@%$&`:

```sh
qemu ... | grep -vE '^[-*:=. ~+#@%$&]*$'
```

I lost an hour to this: I read a screen dump as a crash, "bisected" a library that was never
broken, and reported gemd as down when it was up and working. **Look at the raw bytes before
believing a filter.**

## Build directory

**Use a private one.** `make BUILD=build-xtg` in `fpga-xt/loader`, and point `xtg/Makefile`'s
`GEMLIB` at it. Sharing `build/` with the gemd thread means racing them for `libGEM.so` and the
loader image, and stale `.o` files are indistinguishable from real bugs — that has already cost
this project two false findings.

`make clean` also **strands the dropbear archives**: `objects.list` survives while the `.a` files
do not, so make believes it is done. If `freertos.elf` fails on `libtomcrypt.a`, delete
`$(BUILD)/dropbear/objects.list` and rebuild.

## ✅ The whole suite now runs AS GEMD CLIENTS

Every test below runs under qemu against a real `gemd`, over a real shm backing store. Nothing
is "verified by build" any more.

| | proves |
|---|---|
| `test_spine` | tree math: 20 checks, 0 failures (needs no server) |
| `test_window` | the AES calls our `drawRect`, and it paints pixels **into our own surface** |
| `demo` | hit-test → responder → target/action → `setNeedsDisplay` → repaint |
| `libdemo` | **the same program against `libXtg.so`** — subclass + override across a `.so` |
| `nibdemo` | a Rocks-authored `.rsc` is a LIVE view hierarchy |
| `test_dirty` | one view marked dirty repaints ONE view |
| `test_scale` | depth 16/16, and 2 objects visited to deliver 2 draws |
| `test_clip` | `OF_CLIPCHILDREN`, `G_SCROLL`, `G_SLIDER` |
| `test_key` | click → first responder → `keyDown` → `objc_edit` → text |
| `test_menu` | model → `menu_build` → `MN_SELECTED` → bound method |
| `test_alert` | modal `form_alert`, driven through the pluggable input source |
| `test_chrome` | every chrome field through `wind_set`, hi/lo split |
| `test_scroll` | the AES runs the scrollbar; clicks follow the scroll with no arithmetic |
| `test_table` | a datasource-driven table of real GEM objects — and it repaints only what is visible |
| `test_outline` | expand/collapse re-derives the rows; the row OBJECTS are reused, so the tree never grows |
| `libtable` | a protocol declared IN the `.so`, adopted by a client class, called back across the boundary |
| `Rocks` / `test_rocks` | the app: a `.rsc` as a live canvas, selection, menus, alerts |

### `XGOutlineView` — and the bug that made it look broken

`test_outline` is in the suite and passes. It very nearly was not, and the story is worth
keeping.

The outline corrupted memory. I chased it into an `Array` bug, then a protocol-dispatch bug,
then heap corruption, and wrote all three up. **All three were wrong.** The actual cause was
one line in the *test's datasource*:

```c
Node@ n = item == (Object@)0 ? root : (Node@ ?)item;
```

An object-typed ternary bound to a strong local **freed the object it selected** (xtc bug,
`spikes/XTC-BUGS.md` #15 — **now fixed**; reproducer `spikes/ternary-release.xt`). Every datasource call
quietly decremented the model's refcount, and the model died mid-walk — surfacing as an
`Array` that read `count = 0` and a `DATA-ABORT` whose faulting address was a heap object,
nowhere near the ternary.

The compiler thread fixed it, the workaround came straight back out, and the datasource uses the
ternary again. **`XGOutlineView` was never at fault.** The lesson is the one at the top of this
file, again: a symptom that appears in an `Array` need not be a bug in the `Array`.

### The table scales with what is VISIBLE, not with how much data there is

The question that gets asked of every toolkit, answered by measurement rather than by
assertion. A 30-row, 2-column table is **91 real GEM objects** (1 root + 30 rows + 60
cells). Only 4 rows fit in the 64px work area. A full repaint:

```
full repaint of a 30-row table: the AES called back into 4 rows
  (4 rows fit in the 64px work area)
```

**Four.** A row that is scrolled out of sight carries `OF_CLIPCHILDREN`, misses the clip,
and is pruned *before* `draw_obj` runs — so it is never visited, and neither are its cells.
A 10,000-row table repaints in the time a 4-row one does.

Selection is equally local: selecting a different row damages **the two rows involved**, not
the table (`selecting row 5 damaged 0,32 170x64` — 4 rows tall, against a 480px table).

`gemd` confirms the design in its own log:

```
gemd: wind_open wh=1 pid=2 work 182x76 -> surf 0 gen 1 cap 192x120 (stride 192)
```

A shm backing store, with **stride = capacity width, not current width** (RESPONSIBILITIES §13).

### A CLIENT CANNOT READ THE SCREEN — and that broke a test, correctly

`test_window` used to draw and then peek at the **wallpaper framebuffer** to check for red pixels.
Under `gemd` that fails: `draws=2 red=0`. The `drawRect` ran; the pixels simply were not on the
plane, because **the plane is not ours**. A client paints into its own shm surface and `gemd`
composites it.

The fix is not to reach further — it is to ask a question a client is *allowed* to ask. The test
now reads the pixel back with **`v_get_pixel`, through the very workstation it painted with**.
That workstation targets our surface, so the question becomes "is the pixel *mine*?" instead of
"is the pixel *on the screen*?". Same proof, no trespass.

Any future test that verifies drawing must do the same. If a test needs to see the composited
screen, that is a `gemd`-side test, not a client-side one.

### Chrome is read back from a CACHE, not from the server

`test_chrome` failed the first time it ever ran: every field read back `""`. That was right too —
`wind_set(WF_NAME, ...)` on a client **sends the string to `gemd`** (§11) and stores nothing, so
`wind_get` had nothing to return.

`wind_set` now caches the **strings, and only the strings**, client-side. The asymmetry is the
point:

* **Chrome strings** — `gemd` never rewrites your title, so your request **is** the truth. Safe to
  cache, and `wind_get(WF_NAME)` is a classic call an app is entitled to.
* **Geometry** — `gemd` **clamps**. Your request is *not* the truth; the truth arrives later as
  `MSG_MOVED`. A client that cached `WF_CURRXYWH` would disagree with the screen every time
  `gemd` said no.

**Cache what cannot be refused.**

### Two traps that make a GREEN build run STALE code

Both of these produced failures that pointed nowhere near their cause. Both are now
impossible, because the Makefile does the step.

**1. Building `libXtg.so` did not deploy it.** The loader ships the library out of
`loader/romfs-overlay/Library/`, and the copy lived in *one* `run:` target in `xt/Makefile`
— so every other way of building left the image running the *previous* library. The symptom
is a link error inside qemu that names a symbol, not a file:

```
xtld_load err: XGButton$init rc=undefined symbol
```

`libXtg.so` now deploys as part of being built. **A library that is built but not deployed
is a stale library.**

**2. `libdemo` had no Makefile rule at all.** It needs `-L .` to find `libXtg.so`, which the
generic `%.so` rule does not pass — so it was only ever built by hand, from shell history.
It has a rule now, and every test is in `PROGS`: `make` builds the whole suite.

The lesson both times: **if a step is not in the Makefile, it is not in the build** — it is
in my shell history, and it will be skipped exactly when it matters.

### Running an app under qemu needs a bootstrap

qemu has **no SD card**, so `boot_run()` finds no `/OS/boot/NN-*` scripts and **nothing starts
`gemd`**. `XGBoot.ensureWindowServer()` (test scaffolding — deliberately *not* in the `Xtg.xt`
library umbrella) spawns `/bin/gemd` and waits for the `"gem"` service.

It is idempotent: on the board it connects to the already-running `gemd` and returns immediately.
An application does **not** get to start the window server; this goes the moment qemu boots
properly.

## ✅ What DOES run

### On hardware: `test_spine` — 20 checks

Tree linking, `objc_offset`, hit-testing, `OF_HIDETREE`, the responder chain,
`addChild`/`removeChild` — **and two things reclaimed** when the rest of the suite went dark:

- **damage-rect accumulation** — the union of two dirty views, `takeDirty` clears it, the next mark
  starts fresh. *This is where the struct-ternary miscompile bit (`XTC-BUGS` §10).*
- **`objc_find` reaches level 16** — the `XG_DEPTH` fix. Classic GEM stopped at 8, **silently**:
  past it, views are never drawn and never hit-tested, with no error.

Both were build-only until the suite went dark, which was the prompt to notice they needed no
server at all.

### On the host: `make host` — 21 checks

Natively, no GEM and no loader.

`XGGeom` and `XGStr` are pure logic, so they need neither. And they are exactly where a
silent error hides: **an off-by-one in a rect union yields a damage rect that is subtly
too small**, which surfaces months later as "sometimes it doesn't repaint". `XGGeom.unite`
is also precisely where the struct-ternary miscompile (`spikes/XTC-BUGS.md` §10) bit — the
best argument there is for testing it rather than reading it.

Keeping `XGGeometry` and `XGString` free of `#import <GEM>` is what makes this possible.
**Do not casually add a GEM dependency to either.**
