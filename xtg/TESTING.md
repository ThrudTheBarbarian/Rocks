# What is verified, and how

This project has learned, expensively, that **"it builds" means nothing**. The
depth-8 tree truncation, the dangling VDI surface, the `vs_clip` push-vs-pop, and
five separate compiler miscompiles **all compiled clean**. So the status of every
claim is recorded here, and "verified" always means *run*.

## 🔴 The hardware suite is PARKED

`libGEM` now hard-exits without `gemd`:

```
gem: no window server — is gemd running? (there is no single-process mode on XTOS)
```

Every Xtg test calls `appl_init`, so **none of them can run**. `gemd` is at **M4 of 7**,
and qemu does not currently boot. There is no path to hardware verification.

**This is the right call on the GEM side** — a local-fallback mode would be a lie, and it
would hide exactly the bugs the split exists to surface. But it means everything built
during this window is **verified by build, not by running**, and must not be described as
"working" until it has run.

### Must be re-run against the first `gemd` that hosts a client

| | proves |
|---|---|
| `test_spine` | the toolkit's 14 core invariants |
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

## ✅ What still runs: the host suite

`make host` — 21 checks, natively, no GEM and no loader.

`XGGeom` and `XGStr` are pure logic, so they need neither. And they are exactly where a
silent error hides: **an off-by-one in a rect union yields a damage rect that is subtly
too small**, which surfaces months later as "sometimes it doesn't repaint". `XGGeom.unite`
is also precisely where the struct-ternary miscompile (`spikes/XTC-BUGS.md` §10) bit — the
best argument there is for testing it rather than reading it.

Keeping `XGGeometry` and `XGString` free of `#import <GEM>` is what makes this possible.
**Do not casually add a GEM dependency to either.**
