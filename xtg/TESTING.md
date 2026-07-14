# What is verified, and how

This project has learned, expensively, that **"it builds" means nothing**. The
depth-8 tree truncation, the dangling VDI surface, the `vs_clip` push-vs-pop, and
five separate compiler miscompiles **all compiled clean**. So the status of every
claim is recorded here, and "verified" always means *run*.

## Build directory

**Use a private one.** `make BUILD=build-xtg` in `fpga-xt/loader`, and point `xtg/Makefile`'s
`GEMLIB` at it. Sharing `build/` with the gemd thread means racing them for `libGEM.so` and the
loader image, and stale `.o` files are indistinguishable from real bugs — that has already cost
this project two false findings.

`make clean` also **strands the dropbear archives**: `objects.list` survives while the `.a` files
do not, so make believes it is done. If `freertos.elf` fails on `libtomcrypt.a`, delete
`$(BUILD)/dropbear/objects.list` and rebuild.

## 🟡 The hardware suite is MOSTLY parked

`libGEM` now hard-exits without `gemd`:

```
gem: no window server — is gemd running? (there is no single-process mode on XTOS)
```

Every test that opens a *window* calls `appl_init`, so those cannot run. `gemd` is at **M4 of 7**.

**But not everything needs a server.** `objc_offset`, `objc_find` and the damage logic are **pure
tree math** — they never touch the AES's window list. So the tree half of the toolkit *is*
verifiable on hardware today, and `test_spine` now covers it: **20 checks, 0 failures.**

**This is the right call on the GEM side** — a local-fallback mode would be a lie, and it
would hide exactly the bugs the split exists to surface. But it means everything built
during this window is **verified by build, not by running**, and must not be described as
"working" until it has run.

### Must be re-run against the first `gemd` that hosts a client

| | proves |
|---|---|
| ~~`test_spine`~~ | ✅ **RUNS — 20 checks, 0 failures.** No server needed. |
| `test_window` | the AES calls our `drawRect`, and it paints pixels |
| `demo` | hit-test → responder → target/action → `setNeedsDisplay` → repaint |
| `libdemo` | **the same program against `libXtg.so`** — subclass + override across a `.so` |
| `nibdemo` | a Rocks-authored `.rsc` is a LIVE view hierarchy |
| `test_dirty` | one view marked dirty repaints ONE view |
| `test_scale` | depth 16/16, and 2 objects visited to deliver 2 draws |
| `test_clip` | `OF_CLIPCHILDREN`, `G_SCROLL`, `G_SLIDER` |
| `test_key` | click → first responder → `keyDown` → `objc_edit` → text |
| `test_menu` | model → `menu_build` → `MN_SELECTED` → bound method |
| `test_alert` | modal `form_alert`, driven through the pluggable input source |
| `test_chrome` | **NEVER RUN.** Every chrome field through `wind_set`, hi/lo split |
| `Rocks` / `test_rocks` | the app: a `.rsc` as a live canvas, selection, menus, alerts |

Everything except `test_chrome` **had** passed on the loader before the split landed.
`test_chrome` has never run at all.

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
