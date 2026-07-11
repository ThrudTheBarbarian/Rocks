# Phase 0 spikes — results

All run on the real XTOS loader under qemu (`make xtcrun XTC_SO=...` in fpga-xt/loader).

| Spike | Verdict |
|---|---|
| 1. Subclass across the `.so` boundary | **PASS** — *after* two compiler bugs (see XTC-BUGS.md). The boundary itself is sound. |
| 2. `#import <GEM>` + struct layout | **PASS** — `sizeof(OBJECT)==24` verbatim; the AES walks a tree built in xtc. |
| 3. The draw trampoline | **PASS** — C invokes an xtc callback, which recovers an xtc object from a `void*` and dispatches a virtual method. |
| Float ABI (softfp vs hard) | **NO MISMATCH** — everything is softfp + VFPv3/NEON. `sqrtf`/`pow` round-trip correctly. |

## The one thing that blocks a real GEM app today

**xtc cannot bootstrap GEM.** The display syscalls are `static inline` wrappers in
`loader/test/qemu/usys.h` — not exported symbols, in neither `libc.so` nor
`libGEM.so`:

```c
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, ...); }
static inline long sys_fb_wallpaper(struct os_fbinfo *fi) { ... }
```

xtc has no inline asm on arm9, so it cannot issue `svc #1` itself, and it cannot
import an inline function. Every GEM app therefore repeats ~20 lines of C bootstrap
(fb_info → wallpaper → gfx_surface → font_face_open → vdi_init → v_opnvwk →
theme_load → aes_init → appl_init) that xtc simply cannot express.

**Ask: give libGEM a one-call bootstrap.**

```c
// libGEM: does fb_info + back-buffer + font + vdi_init + v_opnvwk + theme_load
//         + aes_init + appl_init.  Returns the VDI handle, or 0.
int  gem_boot(const char *theme_dir, const char *font_path);
void gem_shutdown(void);
```

This is worth doing regardless of xtc: `aesdesk.c`, `desktop.c` and `gemtext.c` all
copy-paste the same block today. It also means Xtg needs **no raw syscalls at all** —
display and input come from GEM, files from libc.
