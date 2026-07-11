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
