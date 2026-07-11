# Phase 0 spikes — results

All run on the real XTOS loader under qemu (`make xtcrun XTC_SO=...` in fpga-xt/loader).

| Spike | Verdict |
|---|---|
| 1. Subclass across the `.so` boundary | **PASS** — *after* two compiler bugs (see XTC-BUGS.md). The boundary itself is sound. |
| 2. `#import <GEM>` + struct layout | **PASS** — `sizeof(OBJECT)==24` verbatim; the AES walks a tree built in xtc. |
| 3. The draw trampoline | **PASS** — C invokes an xtc callback, which recovers an xtc object from a `void*` and dispatches a virtual method. |
| Float ABI (softfp vs hard) | **NO MISMATCH** — everything is softfp + VFPv3/NEON. `sqrtf`/`pow` round-trip correctly. |

## The one thing that blocks a real GEM app — and it is an XTOS gap, not a compiler one

I first wrote this up as "xtc cannot bootstrap GEM", which mis-assigns it. The real
statement is bigger and is about XTOS's packaging:

**XTOS exposes only half of its own syscall ABI as a callable binary interface.**

| | Exported as real symbols? |
|---|---|
| POSIX calls (`write`, `open`, `close`, …) | **Yes** — `libc.so` |
| XT-specific calls (`sys_fb_info`, `sys_fb_present`, `sys_fb_wallpaper`, `sys_input`, `sys_xtos_recv`) | **No — nowhere, in any `.so`** |

They exist only as `static inline` C in `loader/test/qemu/usys.h`:

```c
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, ...); }
```

which is a *compile-time, C-only* interface. There is no `libxtos.so`; every other
`.so` on the box is a program.

**Consequence:** any language that is not C-with-inline-asm is locked out of the XT's
own hardware — the framebuffer, the mouse, the keyboard. XTOS is, today, effectively
a C-only OS for anything graphical. That is not something xtc can fix from its side,
and it is not really about xtc at all: it would block Rust, Zig, or any other client
equally.

### The fix (small, general, unblocks everything)

Ship the XT syscalls as **real symbols** — either add them to `libc.so` (that is where
`write` and `open` already live) or, cleaner, a small `libxtos.so`, since they are
XT-specific rather than POSIX. It is ~60 one-line wrappers, mechanically derivable
from `usys.h`, and it is the difference between "C only" and "any language".

With that, xtc needs nothing special: the structs (`os_fbinfo`, `gfx_surface`) come
through DWARF import — already proven in Spike 2, where `sizeof(OBJECT)` matched C
byte-for-byte — and `vdi_init` / `v_opnvwk` / `theme_load` / `aes_init` are already
exported by `libGEM.so`.

### `gem_boot()` — still nice, but now only a convenience

```c
int  gem_boot(const char *theme_dir, const char *font_path);   // -> VDI handle
void gem_shutdown(void);
```

`aesdesk.c`, `desktop.c` and `gemtext.c` all copy-paste the same ~20-line bootstrap
today, so this is worth doing on its own merits. But it is **not** the fix — with the
syscalls exported, xtc can do the bootstrap itself. Do the XTOS one first.

---

## Phase 1 complete: a real GEM window, driven from xtc

`xtg/test_window.xt`, run on the loader:

```
sizeof(theme) = 19502 bytes (via DWARF)
GEM booted from xtc: 200x120, vdi handle 2
userdraw invoked 2 time(s)   (the AES called our xtc code)
G_USERDEF is at 17,43  (screen is 200x120)
pixel inside the G_USERDEF = FF0000FF
PASS: the AES called our xtc drawRect, and it painted pixels.
      The G_BUTTON next to it was drawn by GEM, themed, for free.
```

The full chain, with nothing stubbed:

```
  sys_fb_info / sys_fb_wallpaper   (libxtos.so — the new export)
    -> vdi_init -> v_opnvwk -> theme_load -> aes_init -> appl_init
    -> wind_create -> wind_content -> wind_open
    -> wind_redraw_win                       (the new per-window damage path)
       -> the AES's content callback (an xtc free function)
          -> objc_draw walks OUR tree
             |- G_BUTTON   -> GEM themes it.  We wrote no drawing code.
             '- G_USERDEF  -> objc_set_userdraw -> our xtc drawRect -> VDI -> pixels
```

**One fix needed: build `libxtos.so` with `-g`.**

`PROGCFLAGS`/`ARMCFLAGS` carry no `-g`, so `libxtos.so` ships without DWARF, and:

```
xtc: warning: 'libxtos.so' carries no DWARF — imported names are untyped
error: Call to undeclared function 'sys_fb_info'
```

"Untyped" means *unusable*: `#import <xtos>` finds the library but exposes nothing,
so nothing can call it. Hand-declaring the prototypes does not help — that makes
them plain externs bound to no library, so no `DT_NEEDED` is recorded and the loader
cannot resolve them either. `libGEM.so` already builds with `-g`; `libxtos.so` needs
the same. (Rebuilt locally with `-g` to unblock; the Makefile change is one word.)

The DWARF import is also what saved this from a silent heap smash: `theme` is
**19502 bytes** (256 slices). Guessing a `malloc(4096)` for it, as I first did, would
have corrupted the heap. With the type imported, `theme gTheme;` is simply correct.
