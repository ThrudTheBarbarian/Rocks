# Who does what

The contract between the layers of the XT graphics stack: what each one **owns**, what
it may **assume**, and what it must **never** do.

Read this when you are about to write code and need to know whose job something is.

Companions: `AES-SERVER.md` argues *why* the client/server split is shaped this way;
`XTG-DESIGN.md` argues *why* a UI view is a GEM object. This document assumes neither —
it states the conclusions and the obligations.

---

## Implementation status — as of 2026-07-16 (board-verified on `fpga-xt`)

**Legend:** ✅ done and board-verified · 🟡 partial / deferred by design · 🔴 outstanding.
Marked against the shipped state after M4b. The window server (`gemd`) went from "M4 of 7,
built-not-run" (as several §§ still say inline, now stale) to the **whole §3–§14 contract
running on hardware** — including tonight's menu strip, grabs and liveness.

| § | Area | Status | Note |
|---|---|---|---|
| 2 | XTOS kernel prerequisites | ✅ | dynamic L2, variable-size shm (`NSHM=256`), `sys_shm_unmap`, `plv_alloc`+`XT_SHM_CONTIG`, `/dev/blitter` — the whole "verified ABSENT" table is **built**. Kernel-plan items 0–5 done; item 6 (reclaim ~31 MB DDR) not chased. |
| 2 / 15 | **`SEC_PLANE` → PL0-none isolation** | 🔴 | **The one big red.** The blanket PL0-RW plane mapping still stands — the M7 "gate" / *last commit of phase 1*. Only `desktop.c` draws direct now; nothing in `gem/`. |
| 3 | `gemd` — the window server | ✅ | M1–M4 board-verified: window list, z-order, chrome, compositing, input routing, reaping. |
| 4 | The desktop is an app | ✅ | `W_BOTTOM`; kill/restart the desktop under live apps — board-verified. |
| 5 | `libGEM.so` in a client | ✅ | one library, two modes; AES signatures unchanged. |
| 6 | Xtg — the toolkit | ✅ | toolkit + the dirty-rect union (`setNeedsDisplay` overload → `markDirty`/`display`); §16.4 closed. |
| 9 | When things go wrong | ✅ | wedge → still composites; **grab + §9 revoke land M4b, board-verified**. (Death = channel EOF, not SIGCHLD — the table's `SIGCHLD` wording is superseded by M0.) |
| 10 | The menu strip | ✅ | **per-app strip surface, board-verified M4b**: desktop bar composites, dropdowns open under a grab. |
| 11 | Chrome is declarative | ✅ | `wind_set` fields landed + board-verified. (The inline "⚠ Built, not run / M4 of 7" callouts are **stale**.) |
| 12 | Buffer lifetime: refcount | ✅ | `sys_shm_unmap` refcount; resize is a non-event. |
| 13 | Surface memory: capacity/extent/resize | ✅ | capacity vs extent, the drag scratch, quantised shrink — M5 board-verified. |
| 14 | The blitter | 🟡 | `/dev/blitter` + engine present **done, 777 MB/s board-verified**; the VDI blitter *backend* and `gemd`'s inner composite-via-engine are **designed, deferred to M7**. |
| 15 | Staging | 🟡 | phase 1 ✅; phase 2's blitter ✅, its plv-backing-store + composite move deferred to M7; the `SEC_PLANE` flip (🔴 above) is the outstanding last commit. |
| 16 | Not yet decided | 🔴 | open by design: tearing/double-buffer, liveness constants (tunable). (Xtg dirty-rects ✅; dialogs-are-windows + `form_alert` modality now ✅ — dialogs are chromeless `gemd` windows, drag by their background, save-under retires.) |

---

## 0. Terms

Written for three audiences (the OS thread, the compiler thread, and the UI thread), so
nothing below assumes you know the GEM vocabulary.

| | |
|---|---|
| **XTOS** | the operating system. FreeRTOS on a Zynq-7020 (Cortex-A9). Processes, shared memory, the framebuffer, the input device. Knows nothing about windows. **The live kernel is `loader/kernel` + `loader/test/freertos`.** `vitis/` still generates bitstreams, but its **OS side is vestigial** and signposted as such — read it and you will get wrong answers with a straight face (it cost this document two retracted findings: see §2 and §13). |
| **GEM** | the graphics stack, in two halves. Historically Atari's; here, ours. |
| **VDI** | GEM's *drawing* half. `v_gtext`, `vr_recfl`, `vr_transfer_bits` — pixels, lines, text, blits. Draws onto a **surface**. |
| **AES** | GEM's *windowing* half. Windows, events, menus, dialogs. `wind_*`, `evnt_*`, `objc_*`, `form_*`. |
| **`OBJECT` tree** | how the AES represents a UI: a **flat array** of `OBJECT` structs, linked by index into a tree. One entry per widget (button, checkbox, text field…). The AES draws it (`objc_draw`), hit-tests it (`objc_find`), edits it (`objc_edit`). |
| **`G_USERDEF`** | an `OBJECT` type meaning *"call this function pointer to draw me"*. The hook that lets app code draw inside the AES's own traversal. |
| **`gemd`** | **the window server.** One process. Owns windows, z-order, chrome, compositing, input routing. *Not the desktop* — see §4. |
| **`libGEM.so`** | linked into **every** process. In `gemd` it is the server; in an app it is the client half, which turns AES calls into messages. Same library, two modes. |
| **`libXtg.so`** ("Xtg") | our AppKit-style UI toolkit, in the **xtc** language, sitting *on* the AES API. Views, responder chain, target/action, run loop. |
| **`desktop.so`** | the app that draws the wallpaper and the icons. **An ordinary client.** See §4. |
| **`Rocks.so`** | the resource editor. Another ordinary client, and Xtg's proof-of-concept. |
| **nib** | a `.rsc` resource file authored in Rocks. It *contains* an `OBJECT` tree, so Xtg loads it and binds views onto it directly — there is no conversion step. |
| **damage / damage rect** | "this rectangle of my window changed". A client posts one; `gemd` composites it. |
| **backing store** | the off-screen buffer a client draws its window into. `gemd` composites from it. See §3. |
| **the grab** | "all input comes to me, and nothing may be topped, until I release it." What a menu or a modal dialog holds. GEM spells it `wind_update(BEG_MCTRL)`. |
| **xtc** | the language Xtg and Rocks are written in. Classes, protocols, ARC, `weak:`. **No closures, no selectors, no reflection** — which shapes several decisions below. |
| **the blitter** | `xt-blitter`, a command-queued 2D engine in the FPGA fabric. Fills, blits, **scaled** blits, and **alpha blending**, writing DDR3 over AXI. A ~1024-deep command FIFO. **It is a DMA engine with no MMU** — it takes *physical* addresses. See §12. |
| **PL** | the FPGA fabric ("programmable logic"), as opposed to the CPU ("PS"). The blitter and the compositor planes live here. |
| **`plv_alloc`** | the PL-visible heap (`0x3800_0000`, ~128 MB). Physically contiguous, uncached, readable by the PL by physical address. Where window backing stores live. Shared with glyph atlases and DMA buffers, so it is a **budget**, not a free lunch. |
| **surface handle** | an integer id naming a surface. **Clients name surfaces by handle, never by address** — that is what stops a client blitting into someone else's memory (§12). |

---

## 1. The stack

```
    Rocks.so          desktop.so         (any other app)     <- ORDINARY CLIENTS.
    the app           the app that        the app               gemd cannot tell
                      draws wallpaper                           them apart.
                      and icons
      |                  |                   |
      +--------- libXtg.so (the toolkit) ----+     views, responders, actions,
      |                  |                   |     the run loop, nibs
      +--------- libGEM.so (client mode) ----+     objc_*, theme_*, form_*, v_*
                         |
        messages (control)  |  shm (pixels)
                         v
    +-----------------------------------------------------------+
    |  gemd                THE WINDOW SERVER. ONE process.       |   who arbitrates
    |  (libGEM.so,         windows, z-order, chrome, compositing |   between apps
    |   server mode)       input routing, grabs, lifecycle       |
    +-----------------------------------------------------------+
    |  libxtos.so / XTOS   processes, shm, input, framebuffer    |   the machine
    +-----------------------------------------------------------+
```

**Two rules generate almost everything in this document:**

> ### 1. Only `gemd` touches the screen.
> ### 2. Only the app knows what its content looks like.

Rule 1 alone gives you X11 (stream every drawing primitive to the server). Rule 2 alone
gives you classic GEM (every app scribbles directly on the framebuffer). Holding **both
at once** forces the per-window backing store (§3), forces the menu bar to be painted by
its owner (§10), and forces the grab (§9). None of those were free choices — they are
consequences.

**Note what is *not* in that diagram's server box: the desktop.** It is a client,
`desktop.so`, sitting beside `Rocks.so`. That is §4, and it is the single most
load-bearing decision here.

---

## 2. XTOS ✅🔴

**Owns.** Processes. The framebuffer (`sys_fb_info`, `sys_fb_wallpaper`). Shared memory.
The input device. The syscall ABI, exported as real symbols from `libxtos.so` so a
non-C language can reach it.

**Promises.**
- A shm segment created by one process and mapped by another is the same memory.
- Input events arrive in order, and only to the process that asked for them.
- A dead process's shm mappings are reclaimed.

**Verified present** (`nm -D libxtos.so`), because the whole architecture rests on these and
they should not be taken on trust:

```
    sys_pipe   sys_socket   sys_read   sys_write     the control channel exists
    sys_waitpid  _nb  _peek                          client death is observable
    sys_input                                        input
    sys_fb_info  sys_fb_wallpaper  sys_fb_present    the plane
    sys_xtos_recv                                    a non-blocking message receive
    sys_shm_create   sys_shm_map                     shared memory exists — but see below
```

### ✅ RESOLVED (2026-07-16) — every gap below is now built and board-verified

> **This whole subsection was written when the kernel could not host `gemd`. It has all been
> built.** Dynamic L2 tables, variable-size shm (`NSHM=256`, the 1 MB cap gone), `sys_shm_unmap`,
> `plv_alloc`+`XT_SHM_CONTIG`, and `/dev/blitter` (777 MB/s engine) are shipped and running on
> hardware — kernel-plan items 0–5 below are done (item 6, reclaiming ~31 MB DDR, not chased).
> Kept as-is because the *ordering* lesson (`MAXSEC` bites first) is worth keeping; read it as
> history, not a live blocker.

### ⚠ Verified ABSENT (HISTORICAL — see ✅ above) — the backing store was **not** buildable when written

> **Recorded because this document made the opposite mistake to the one below.** An earlier
> draft listed `sys_shm_create` + `sys_shm_map` under "verified present" and concluded from
> their existence that *"the backing store (§3) is buildable"*. That is the exact **mirror**
> of the `SIGCHLD` error recorded at the end of this section. There the lesson was *absence
> of a symbol is not absence of a feature*; here the converse bites just as hard:
> **presence of a symbol is not sufficiency of the feature.** The two symbols are real. The
> semantics behind them do not meet §3, §11, §12 or §13. Checked against the **live** kernel
> (`loader/kernel` + `loader/test/freertos`), not `vitis/xtos`:

| what is missing | why it matters |
|---|---|
| **`sys_shm_unmap` does not exist.** The only `nref--` is `vm_shm_drop_space`, called solely from `vm_space_destroy` — i.e. **process death**. A *live* process cannot drop a ref. | **This is the load-bearing one, and it is worse than a leak — see below.** §11 ("gemd drops its ref on the old; the client drops its ref on the old → refcount 0 → freed"), §12's settle-and-hand-over, and §13's "the surface outlives an in-flight blit" **all** require dropping a ref while both processes are alive. |
| **1 MB per surface.** `SHM_MAXPG = SHM_SLOT>>12`, `SHM_SLOT = XTOS_SHM_SIZE/NSHM` = 16 MB/16. | Not a corner case — **every window**. A 640×400 window is already 1.02 MiB. |
| **shm is pool-backed, so physically SCATTERED** — `dpage_raw()`, one 4 KB frame at a time. | §13 requires surfaces to be **contiguous, PL-visible and uncached**. The blitter accumulates `base + stride` and cannot walk a page list. Pool-backed shm is structurally unusable for it. |
| **`plv_alloc` does not exist.** | It is specified in `docs/Zynq/memory-map.md` (`0x3800_0000`, 128 MB, *"GEM window surfaces"*) and implemented **nowhere** — not in the live kernel, and not even in the dead `vitis` tree. §12 and §13 both assume it. |
| **`NSHM = 16`** surfaces, machine-wide. | One per window, plus one menu strip per app (§10), plus resize churn. |
| **No `/dev/blitter`, and no blitter driver at all.** | The live kernel has **zero** blitter code. The only driver is `vitis/xtos/src/blitter.c` — the dead tree. §13 is entirely unbuilt. |
| **`MAXSEC = 12`** — per-space L2 slots, **statically** allocated (`space_l2pool[NSPACE][MAXSEC][256]`), and already consumed by libc + each shared lib's data + the program's own data. | **A ~2–3 window cap.** An 8.5 MB surface needs **9 sections** of VA on its own. And it strangles **`gemd` first**: a client maps *its own* one or two surfaces, while **`gemd` maps every surface in the system** — so `gemd`'s L2 slots are the scarce resource, and `gemd` is the process that must not run out. |

#### Three hard caps — and they bite in an order that matters

| order | cap | when it stops you |
|---|---|---|
| **1st** | **`MAXSEC = 12`** — per-space L2 slots | **`gemd` dies at its third window.** |
| 2nd | **1 MB per surface** (`SHM_MAXPG`) | every window — a 640×400 is already 1.02 MiB |
| 3rd | **16 surfaces, *ever*** (`NSHM`, ids never reclaimed) | after 16 window *opens*, for `gemd`'s whole uptime |

**`MAXSEC` is first, and that is the trap.** You would never *reach* `NSHM = 16`, and you would
never see the unmap leak. So fixing them in the obvious order — raise `NSHM`, lift the 1 MB
cap — produces a system that **looks fixed and then fails at window three**, with:

```c
    perproc_l2():   if (space_l2n[idx] >= MAXSEC) return 0;    /* exhausted */
    vm_shm_map():   uint32_t *l2 = perproc_l2(...);
                    if (!l2) return 0;                          /* the map simply FAILS */
```

— a `shm_map` returning VA 0, with **nothing in the shm code to blame.** Finding this before
anyone started is worth more than the fix.

#### Why `MAXSEC` cannot simply be raised

`NSPACE = 64`, and one L2 table is 1 KB:

```
    MAXSEC = 12  ->    768 KB static      <- what dynamic L2 recovers
    MAXSEC = 32  ->  2,048 KB  (+1.3 MB)
    MAXSEC = 64  ->  4,096 KB  (+3.3 MB)
```

**The cost is paid ×64 — by every space — while the need is concentrated in one process.**
`gemd` maps *every* surface (ten 2 MiB windows ≈ 30 sections); the other 63 spaces want a
handful. Paying 4 MB so that 63 processes can each have 64 slots they will never use is the
wrong trade, and **no value of `MAXSEC` is both cheap and sufficient.**

**So the fix is neither knob — it is to make L2 tables dynamic.** Allocate them from the page
pool on demand (each L2 is 1 KB; **four fit in a page**). Then the cost is proportional to
*actual mappings* rather than `NSPACE × MAXSEC`: `gemd` maps forty surfaces, an idle process
costs **zero**, the 768 KB static array is recovered, and `NSHM = 256` becomes genuinely free.

That is why dynamic L2 is a **prerequisite for phase 1**, not an optimisation. Without it
`gemd` cannot map its windows at all.

#### The `sys_shm_unmap` gap is a hard stop, not a leak

`gemd` is **long-lived**, and it holds a ref on every surface it creates. So:

```
    gemd creates a surface, maps it                nref = 1
    the client maps it                             nref = 2
    the client dies      -> drop_space          -> nref = 1     <- never reaches 0
    gemd cannot drop its ref (there is no unmap) -> nref = 1     forever
```

The surface is never freed, so `used` is never cleared, so **the id is never reclaimed**. With
`NSHM = 16`:

> ### The machine can create sixteen surfaces. **Ever.**
> Not sixteen *concurrent* — sixteen for the entire uptime of `gemd`. Open and close a window
> sixteen times and **no window can ever be created again.**

That is not a leak that degrades gracefully; it is a hard stop after sixteen windows. It makes
`sys_shm_unmap` an **absolute phase-1 blocker**, not a refcounting nicety.

None of this is a design problem — §12 and §13 are right, and the memory map already
reserves the region. It is **unbuilt kernel**, and it is being built:

#### The kernel plan (agreed, in order)

| | | unblocks |
|---|---|---|
| **0** | **flags on `shm_create`** — take the ABI headroom now | everything after this, without an ABI break |
| **1** | **dynamic L2 tables** — kills `MAXSEC`, recovers 768 KB | **prerequisite.** Without it `gemd` stops at 2–3 windows |
| **2** | **variable-size shm** — VA allocated at create, window moved out of the pool's identity range, dynamic page list, `NSHM = 256` | the 1 MB cap, the 16-surface cap |
| **3** | **`sys_shm_unmap`** | §11 refcount, §12 resize/settle, §13 in-flight blit. **`gemd` phase 1 is unblocked here.** |
| **4** | **`plv_alloc` + `XT_SHM_CONTIG`**, section-mapped | §13 — phase 2 |
| **5** | **`/dev/blitter`** — handles, FIFO headroom, retire counter, per-process fairness | §13 — phase 2 |
| **6** | reclaim ~31 MB of dead DDR (`POOL_FLOOR` drops once shm's VA window moves) | — |

**Phase 1 (§14) needs 0–3. Phase 2 needs 4–5.** Item 6 is a bonus.

**But do not file it all under phase 2.** Phase 1 keeps backing stores in ordinary *cached*
OS-heap memory, so it genuinely escapes `plv`, contiguity, uncached discipline and
`/dev/blitter` (§14). It does **not** escape the other two: those buffers are still **shm**
(the client draws, `gemd` copies out), so they still hit the **1 MB cap**, and §11's refcount
still needs a **live process to drop a ref** on resize and on window close — which is exactly
what `sys_shm_unmap` would do, and exactly what XTOS cannot do. §14 lists phase 1's kernel
need as *"one thing only"*; it is **two**.

**Must never.** Care about windows. XTOS has no concept of a window and must not grow one —
that is `gemd`'s entire job.

### `gemd` **is** privileged — and the sentence that said otherwise was about the desktop

An earlier draft of this section ended *"…and `gemd` is an ordinary user process with no
privileges XTOS knows about."* **That claim is false of `gemd`** — and it is worth recording
*why*, because the mistake is instructive rather than careless.

It was written when there **was** no `gemd`: there was only `desktop.app`, which was both the
desktop and the server. When the two were split (§4), the sentence stayed attached to the
server. But the property it names — *an ordinary process, no special privileges* — is a
statement about the **desktop**, and it is **load-bearing there**: §4's entire argument is
that `desktop.so` is a client `gemd` cannot tell apart from `Rocks.so`, which is what lets it
crash, be restarted, and be replaced. The sentence was true. It was simply left on the wrong
noun.

`gemd` is **special**, and deliberately so:

| | |
|---|---|
| it is the **only** process that presents to the framebuffer | Rule 1 |
| it holds the blitter's `PRIORITY` `ioctl` | §13 — *"privileged; only the `aes_init` process"* |
| it holds **the grab**, and arbitrates input for everyone | §3, §9 |
| it reaps dead clients' windows and surfaces | §9 |

What *is* true — and is the invariant actually worth defending — is narrower:

> **`gemd`'s privileges are ordinary OS capabilities** — a device fd, an ioctl, a mapping.
> XTOS knows it as *a process holding a capability*. It must never know it as **a window
> server**.

That is what keeps §2's "must never care about windows" honest. The kernel mediates the
blitter because the blitter is a **DMA engine with no MMU** (§13), not because the process
holding the fd happens to manage windows.

### 🔴 The memory path is not isolated — `SEC_PLANE` is PL0-RW in every space

`/dev/blitter` (§13) mediates the **blitter** path: a client names surfaces by handle, so it
cannot express a blit outside the surfaces it owns. That is necessary and **not sufficient**,
because the **memory** path is wide open.

`mmu.c:121`:

```c
    else if (i < 1024)  l1[i] = base | SEC_PLANE;   /* SALLY/planes: PL0-RW, non-cacheable */
    #define SEC_PLANE 0x1C12u   /* AP=11 (PL0 RW) */
```

`i` runs from `0x200` to `1024` — so **the whole `0x2000_0000..0x3FFF_FFFF` range, 512 MB, is
PL0-RW in the master table and inherited by every space.** Every process can write:

- the **framebuffer** (`0x3000_0000`)
- the **wallpaper** plane, the **drag overlay**, the **sprite arena**, the SALLY banks
- **`plv` at `0x3800_0000` — where phase-2 backing stores live**

Which means that in phase 2 **a client could `memcpy` another client's backing store**, bypassing
`/dev/blitter` entirely. We would have locked the front door and left the wall down.

**It is deliberate, and correct today.** `mmu.c:101` says so: *"the PL-shared planes stay PL0-RW
(programs draw the framebuffer)"*. There is no `gemd`, so programs genuinely do draw the
framebuffer. **The hole cannot close until `gemd` exists** — it is `gemd` that makes direct
framebuffer access unnecessary.

#### Close it in phase 1 — it is the cheapest moment, not the hardest

The instinct is to defer this to phase 2, alongside `plv`. **Do the opposite.**

In phase 1 a client needs **zero** access to `SEC_PLANE`. Backing stores are ordinary *cached*
OS-heap memory (§14) — deliberately not `plv`. The only process that needs the framebuffer plane
is `gemd`, which composites into it with the CPU.

```
    phase 1:   SEC_PLANE -> PL0-none for everyone.
               gemd gets the framebuffer plane mapped explicitly.   Clients get NOTHING.
               <- the hole closes, and there is nothing to build.

    phase 2:   surfaces come BACK, individually, via shm (kernel items 2-4)
               — machinery that is being built anyway.
```

Defer it and phase 2 must build the per-surface mapping **and** flip the blanket at once, with
more moving parts and a live system to keep working. Do it in phase 1 and the blanket comes down
while **nobody is standing under it.**

#### It is a one-way door, so it is a *completion criterion*

The moment `SEC_PLANE` goes PL0-none, **any app still drawing direct to the framebuffer breaks.**
So this is not a task *inside* phase 1 — it is the **last commit of phase 1**, gated on *"no app
draws direct any more"*.

That makes it a good gate to have: it is a hard, mechanical proof that the client/server split is
complete. **If flipping it breaks something, the split is not done.**

#### And one plane may simply disappear

`WALLPAPER_BASE` (16 MB, PL0-RW **cacheable**) is a dedicated plane every process can write. But
§4 says the desktop is an ordinary app and its wallpaper is **content**, drawn into its own
backing store like any other client's. In the `gemd` world that plane is both a hole *and*
redundant.

---

### How clients and `gemd` find each other — and how `gemd` waits

**The rendezvous was missing entirely, and this document did not notice.** An earlier draft said
the control channel was *"one pipe per client"*. **Pipes require shared ancestry** — and `gemd` is
the parent of neither a boot-script desktop nor an ssh-launched app. The window server and its
clients **literally could not reach each other**. That was not a detail to design around; it was a
wall, and the design walked straight past it.

XTOS gained a real rendezvous (M0, `3c6f5b4`), BSD-shaped so there is no new mental model:

```
    sys_svc_register(name) -> listen fd      (bind + listen)
    sys_svc_connect(name)  -> channel fd     (connect)
    sys_svc_accept(lfd)    -> channel fd     (accept)
    sys_poll(fds, n, ms)                     (pipes, channels, sockets, files)
```

A **channel is bidirectional** — two pipes under one fd — so `read`/`write`/`close`/`poll` just
work on it, and **a dead peer surfaces as EOF**, which is exactly what §9's lifecycle rules need.

### `sys_poll` is an architectural improvement, not an ergonomic one

The original plan had the kernel injecting input into *"whichever process holds the gem service"* —
**window-server policy inside the kernel**, which §2 flatly forbids ("XTOS must never care about
windows").

With a real `poll`, `gemd` is an **ordinary poll loop** over its listen fd, its client channels,
and its input fd. **The kernel knows nothing about window servers at all.** The rule held, and
holding it produced the better design.

> An earlier draft of this section proposed that `gemd` block on `sys_input` and be woken by
> signals (`-EINTR`). That worked, but it was a workaround for the absence of `poll` — and it
> would have pushed input routing towards the kernel. `sys_poll` is strictly better and the
> signal scheme is retired. `SIGCHLD` remains useful for reaping, but is no longer load-bearing:
> a dead client's channel simply reads EOF.

---

## 3. `gemd` — the window server ✅

**One process.** The only one that calls `aes_init`, and the only one that presents to
the framebuffer.

**It is deliberately small.** It routes input, arbitrates z-order, composites, and does
nothing else — because it is the process that holds **the grab**, and *a process that
holds the grab must never be able to block*. §4 is where that constraint comes from.

### It owns

| | |
|---|---|
| the window list, z-order, geometry | `awin g_w[MAXW]` lives here and nowhere else. Honours `W_BOTTOM` at insertion (§4) |
| window **chrome** | title bar, closer, mover, sizer, sliders — all themed |
| **compositing** and `fb_present` | it alone decides what pixel is on screen. Composites **with the blitter**, in hardware (§13) |
| a fallback background **colour** | *only* a colour. The wallpaper belongs to `desktop.so` (§4) |
| **input** (`sys_input`) | it does the top-level hit-test and routes |
| the **menu strip** | it reserves the region (`g_top_reserve`) and owns one strip surface **per app**. It composites the active app's. It does not *draw* the menu — it cannot (§10) |
| the **grab** | it decides who receives input, and honours `wind_update(BEG_MCTRL)` |
| **lifecycle** | it reaps a dead client's windows |

### It promises

- **A window's pixels survive occlusion.** Once a client has drawn its window and posted
  damage, `gemd` can bring that window forward, move it, or reveal it from under another
  — *without asking the client anything*. This is the whole point of the per-window
  backing store, and **every other promise leans on it.**
  *(The one exception is the memory pressure valve — §12. Under duress `gemd` may drop a
  fully-occluded window's surface and ask its owner to redraw on reveal. Never on the normal
  path.)*
- **Damage is honoured.** A client posts a rect; `gemd` composites it in z-order and
  presents. It does not batch it into next week.
- **Input goes to exactly one place.** The window under the pointer, or the grab holder
  if there is one. Never both, never neither.
- **A grab is absolute.** While `BEG_MCTRL` is held, *all* input goes to the holder and
  **nothing is topped**. This is what makes menus, `menu_popup` and `form_alert` safe,
  and it is the only ordering guarantee they need.

### How a repaint starts — two triggers, and they must not be confused

There are exactly **two** reasons the screen changes, and they are asymmetric. Almost
every mistake in a window system comes from muddling them.

| what changed | who can notice | who acts | app involved? |
|---|---|---|---|
| **geometry** — a window moved, was topped, or was revealed from under another | `gemd` | `gemd` re-composites from the backing store | **no.** This is exactly what the backing store buys. |
| **content** — text inserted, a list scrolled, a selection changed | **only the app** | the app draws into **its own** backing store, then posts a damage rect | **yes, and only the app.** |

**`gemd` never knows that an app's content is stale, and must never try to find out.** It
has no idea what a line of text is. It does not diff buffers (that would be O(pixels) and
pointless), and it does not poll. The app tells it:

```
    the app inserts "xxx" into a line:

      app mutates its model
      the view marks itself dirty
      run loop -> drawRect -> the VDI writes into the APP'S OWN buffer
                              (local memory; zero IPC; full speed)
      app posts ONE message:  "this rect of my surface is new"
      gemd blits that rect.   It never learns why.
```

`gemd` is told *"these pixels changed"* — never *"I inserted text"*.

**Scrolling is the case worth stating explicitly**, because the drawable area is
unchanged while the content is entirely different. The pixels genuinely *did* all change,
so a damage rect covering the whole scrolled region is **correct, not wasteful**. The app
may of course be clever *inside its own buffer* — `vr_transfer_bits` the region up by N
pixels and redraw only the newly-exposed strip, which costs no IPC at all — but the
*composited output* differs everywhere in that view, and the damage rect must say so.

**A consequence: `WM_REDRAW` nearly disappears.** Classic GEM sends it because the server
exposed part of your window and only you could repaint it. Here `gemd` already has those
pixels. `WM_REDRAW` survives only for **resize** (the buffer changed size, so content must
reflow) and the **first paint**. Every other repaint is the app deciding, unprompted, that
its own content is stale.

**And note what the app does *not* have to know:** whether it is visible. It draws and
posts damage regardless; `gemd` clips. If the damaged region is occluded, the backing
store still holds the new content, so it is correct the moment it is revealed. That is why
§5 can flatly forbid a client from caring whether it is on screen.

### It must never

- **Draw an app's content.** It has the pixels; it does not have the *meaning*. It can
  re-composite what the app last drew; it cannot repaint a window from scratch.
- **Guess whether an app's content has changed.** No polling, no buffer diffing. Content
  staleness is knowable only by the app, and the app says so with a damage rect (above).
- **Parse an app's `OBJECT` tree.** Those pointers are in *another address space*. This
  is not a style rule, it is a hardware fact — and it is why the menu bar works the way
  it does (§10).
- **Assume a client is alive, responsive, or well-behaved.** See §9.
- **Know what a file is.** No filesystem, no icons, no drag-and-drop semantics, no file
  picker. All of that belongs to `desktop.so`, which is an app (§4).
- **Block. Ever.** It holds the grab.

---

## 4. The desktop is an app ✅

`desktop.so` is an **ordinary GEM client**. `gemd` cannot tell it apart from `Rocks.so`
except by a single flag on its window.

### Why this matters more than replaceability

You do get replaceability — swap in `desktop+` and nothing else changes. That is the
smaller prize.

**The arbiter must be boring.** A desktop does file I/O, renders icons, runs
drag-and-drop, opens a file picker, maybe indexes a search field. If the desktop *is*
the server, all of that runs inside the process that owns input routing and the grab —
and **every desktop bug becomes a system freeze**. Keeping them apart means the process
that arbitrates between apps is small, does nothing risky, and has no reason to block.

TOS made the other choice. TOS also froze a lot.

### The wallpaper is content

Rule 2 says only an app knows what its content looks like — and a wallpaper is content.
So the desktop draws its wallpaper and icons into **its own backing store**, with
`objc_draw`, exactly like every other client. `gemd` keeps a fallback background
*colour* for when no desktop is running (or one is restarting), and nothing more.

### It needs almost no new mechanism — one flag

There is no "root window", no window level, no special case in the compositor. The
desktop is an ordinary client that calls:

```c
    wind_create(W_BOTTOM /* and no W_NAME, no W_CLOSER, no W_MOVER */,
                0, strip_h, screen_w, screen_h - strip_h);
```

- **No chrome**, because it passed none of the chrome bits. `wind_create`'s kind mask
  already expresses this.
- **Bottom of the z-order, and not toppable** — because of `W_BOTTOM`, one new bit in a
  mask that already holds `W_CLOSER` and `W_MOVER`.

### `W_BOTTOM` means two things, and it needs both

```
    1. INSERT AT THE BOTTOM of the z-order — whenever the window is created.
    2. NEVER TOPPED by a click.
```

**(2) alone is not enough, and (1) is not free.** It is tempting to say the desktop is
simply *the first app launched*, so it is at the bottom because new windows go on top —
no flag needed for (1). **That is true at boot and false ever after.**

Restart the desktop while apps are running — which §4 explicitly promises works, and
which is exactly the path you take *when something has already gone wrong* — and its new
screen-sized window is created **last**. Without (1) it lands on **top** and swallows the
entire session: every app invisible, the machine apparently dead. Creation order is luck,
not design.

So `W_BOTTOM` is a real z-order rule that `gemd` honours at insertion, not merely a
"don't top me" hint.

**Why `W_BOTTOM` and not `W_ROOT`:** it names a *z-order position*, which is the only
thing `gemd` should understand. `W_ROOT` would smuggle a *role* into the server — and the
whole argument of this section is that **`gemd` must not know what a desktop is.** Nothing
stops two clients setting `W_BOTTOM`; they simply stack at the bottom among themselves,
and `gemd` neither knows nor cares which of them is "the desktop".

That is the entire cost. **One flag, and the desktop is an ordinary app.**

### It follows that

- **The desktop's menu bar is not special.** It is simply the active app's menu bar, and
  the desktop is sometimes the active app.
- **The desktop can crash and be restarted** without taking the window system with it.
  Other apps keep running and stay clickable; the background falls back to `gemd`'s
  colour until the desktop returns — and when it returns, `W_BOTTOM` puts it back
  *underneath* the apps that outlived it, rather than on top of them.
- **`gemd` starts first** and launches the desktop. Not the other way round.

---

## 5. `libGEM.so`, in a client ✅

The same library `gemd` links, running on the other side of the wire. `aes_init` puts it
in server mode; `appl_init` puts it in client mode.

### It owns

- **The client's VDI.** `v_opnvwk` on the client's *own* surface. Every drawing
  primitive — `vr_recfl`, `v_gtext`, `vr_transfer_bits` — is issued client-side, with **zero
  IPC to `gemd`**. Note this does *not* mean "the CPU writes pixels": the VDI submits
  **blitter** commands through its own `/dev/blitter` fd, and `theme_draw`, text and fills
  are hardware (§13).
- **`objc_*`.** The tree walk (`objc_draw`), hit-testing (`objc_find`), coordinate
  resolution (`objc_offset`), editing (`objc_edit`), and the `G_USERDEF` callback
  (`objc_set_userdraw`). All client-side; `gemd` never sees a tree.
- **`theme_draw` and `form_*`.** The theme atlas is read-only art; both sides may load
  it, and there is no conflict.
- **Translation.** `wind_create`, `wind_open`, `wind_content`, `evnt_multi` keep their
  **exact signatures**. Only their *bodies* change, from "touch `g_w[]`" to "send a
  message". This is the entire reason the client/server split is tractable, and it must
  stay true: **if an AES call ever grows a new parameter for `gemd`'s benefit, the
  layering has gone wrong.**

### It promises the app

> **Nothing about the AES API changes.** An app written against single-process GEM
> compiles and runs against `gemd` unmodified.

### It must never

- **Touch the framebuffer.** Ever. There are **no exceptions** — not even the menu strip,
  which is a surface `gemd` owns and hands the app, not a mapping of the screen (§10).
- **Assume it owns the screen.** A client does not know where its window is on screen,
  what is above it, or whether it is visible at all. It draws into its buffer and posts
  damage. That is all.

---

## 6. Xtg — the toolkit ✅

Xtg sits **on** the AES API, not underneath it. That is why moving to a client/server
GEM costs it exactly one method (`XGApplication.boot()` → `.attach()`) and nothing else.

### It owns

| | |
|---|---|
| **`XGView`** | a view **IS** a GEM object. It owns an *index* into an `OBJECT[]`, not a rectangle. |
| **`XGViewTree`** | the flat `OBJECT[]` plus a parallel array of views. `addChild`/`removeChild` wrap `objc_add`/`objc_delete`. |
| **the draw seam** | a view's `gemType()` returns `G_USERDEF`, so **the AES itself** calls `drawRect` during its own `objc_draw` traversal. |
| **`XGResponder`** | the chain, built without reflection: defaults forward to `nextResponder`, and a subclass consumes an event by simply *not* calling `super`. |
| **target/action** | one field: `weak: XGAction^` — a bound method (`&self.onOK`), with an auto-zeroing receiver. No selectors, no reflection. |
| **the run loop** | `evnt_multi`, and the coalescing of `setNeedsDisplay` into one repaint per pass. |
| **nibs** | `XGNib.load` binds a view onto each object of a Rocks-authored `.rsc`. There is **no inflation step** — the resource's own array *is* the view tree. |

### It promises the app

- **`drawRect` is called by the AES**, with an `XGGraphics` already clipped and offset to
  the view's frame. The view draws in its own coordinates, starting at 0,0.
- **A stock widget needs no drawing code.** `XGButton` returns `G_BUTTON` and sets its
  label; GEM themes it. `XGButton` contains **zero** drawing code — and that is the
  measure of whether this design is working.
- **`setNeedsDisplay` is cheap.** It sets a flag; the run loop coalesces.

### It must never

- **Draw outside `drawRect`.** Painting from a click handler paints to a surface `gemd`
  may not composite, and to a clip rect that is not the view's.
- **Cache a screen coordinate.** Ask `absoluteFrame` (which asks `objc_offset`). A window
  can move without the app being told.
- **Re-implement what GEM already does.** If Xtg is drawing a button border, that is a
  bug in Xtg, not a feature.
- **Repaint more than changed.** A view that marks itself dirty must cost a repaint of
  *that view*, not of the window. See the known gap below.

### ✅ CLOSED — `setNeedsDisplay` carries a rect (dirty-rect union landed)

The fix is in Xtg, via the natural overload: **`setNeedsDisplay(void)` is sugar that calls
`setNeedsDisplayInRect(self.absoluteFrame())`** — the whole-view rect — so the cheap "just
mark me dirty" call still works, and code that knows better (a text view changing one line, a
table scrolling one row) calls `setNeedsDisplayInRect(rect)` directly. xtc overloads by
argument type, so both are `setNeedsDisplay` at the call site with the signature the caller
wants. (Same idea `wind_set` uses — one name, the toolkit adds the typed convenience.)

The rect then flows all the way through:
- `XGViewTree.markDirty(abs)` accumulates the **union** of every rect marked since the last
  paint (`XGGeom.unite`), on the tree — not a global flag.
- `XGWindow.display()` takes that union and posts it as the damage rect: `wind_redraw_area(d)`
  (→ `client_paint` of exactly that rect under gemd), and hands the same rect to `objc_draw`
  as the **clip**, so a one-line change repaints one line, not the window.
- `gNeedsDisplay` survives only as the O(1) "is ANY window dirty?" pre-check the run loop does
  before walking windows.

So the old "single global boolean → whole-window redraw" is gone. (See §16 — this closes the
last of its open items too.)

---

## 7. The application

**Owns.** What its content looks like, what its controls mean, its documents, its menus.

**May assume.** Everything in §6's promises. And: **its window's backing store persists**,
so it is *not* asked to redraw merely because it was occluded, moved, or topped.

**Must.**
- **Post a damage rect whenever its own content changes.** Nothing else can know (§3).
  This is the app's single most important obligation: `gemd` cannot compensate for an app
  that quietly draws and never says so, and it cannot compensate for an app that changes
  its model and never draws.
- Draw its content on `WM_REDRAW` — which now means only **resize** and **first paint**
  (§3). It is *not* sent for occlusion, moves or topping any more.
- Draw its menu bar when told it has become the active app (§10).
- Return to `evnt_multi` promptly. Not a moral requirement — a functional one (§9).

**Must never.** Assume it is the only app; assume it is visible; assume its menu is
showing.

---

## 8. The seams

Where two layers meet, exactly what crosses:

| seam | what crosses | direction |
|---|---|---|
| app ↔ Xtg | `drawRect`, `mouseDown`, target/action, delegate protocols | both — Xtg calls **down** into the app's overrides |
| Xtg ↔ libGEM | the AES API, verbatim | Xtg calls libGEM; libGEM calls **back** via `wind_content` and `objc_set_userdraw` |
| libGEM ↔ `gemd` | **control**: window ops, damage rects, input events, grabs. **pixels**: shm, never the pipe. | both |
| `gemd` ↔ XTOS | syscalls | one way |

**Two callbacks are the whole design.** `wind_content` gives the AES a function to call
when a window needs drawing; `objc_set_userdraw` gives it a function to call for each
`G_USERDEF` inside that draw. Xtg hangs its entire view system off those two function
pointers — and the `void*` carried alongside each one is what smuggles the `XGWindow`
across the C boundary. **xtc has no closures, so that `void*` is load-bearing.**

---

## 9. When things go wrong ✅

The interesting half of any contract.

| | what happens | whose job |
|---|---|---|
| **an app crashes** | **`SIGCHLD`** interrupts whatever `gemd` is blocked in (`-EINTR`); it reaps with `sys_waitpid_nb` and drops the client's windows and surfaces. No ghost windows, no leaked shm, and no polling (§2). | `gemd` |
| **an app wedges** (never returns to `evnt_multi`) | its **windows still composite**, and so does **its menu bar** — `gemd` holds both, and needs nothing from the app (§10). It gets a **busy cursor**. It simply stops *responding*; it does not stop *appearing*. | `gemd` |
| **an app wedges while holding a grab** | **the grab times out** (below). `gemd` discards its overlay, recomposites from the backing stores, and injects a *cancel* so the app runs its own dismissal path when it wakes. It may not re-grab until the user tops it again. | `gemd` |
| **an app posts damage outside its window** | clamped. A client's damage rect is a *request*, not an instruction. | `gemd` |
| **an app never draws** | its window composites as whatever its buffer contains — i.e. blank. Correct. | — |
| **`desktop.so` crashes** | nothing else stops. The background falls back to `gemd`'s colour; other apps keep running and stay clickable. Restart it. | `gemd` |
| **`gemd` crashes** | everything is gone. Which is exactly why it is small, boring, and does no file I/O (§4). | — |

### Wedged is a state `gemd` can detect without asking

The liveness signal is **"is this client draining its event pipe?"** — which `gemd` can
observe *without the client doing anything*. That is the essential property, because a
wedged client cooperates with nothing.

The clock runs **only when there is input queued for that client and still unread**. It
is *not* a wall-clock idle timer: a modal dialog sitting quietly while the user thinks is
perfectly healthy, and a naive idle timer cannot tell the two apart.

```
    input queued for a client, unread:   +2s  ->  busy cursor
                                         +7s  ->  its grab (if any) is revoked
    client drains its pipe:                       clock resets
```

One clock detects **every** wedged app. Losing a grab is merely the extra consequence
when the wedged app happened to be holding one.

A wedged app *looking* wedged is **right**. Failure should be visible in proportion to
how badly something has failed, and no more — but no app may freeze **`gemd`**. The
desktop is just another app, and it may freeze without taking anything else down. That is
precisely the point of §4.

---

## 10. The menu strip: a surface per app, not a hole in the framebuffer ✅

The strip is the one place where it is tempting to let a client draw straight to the
screen. **Resist it.** This section records why, because the tempting version looks
cheaper than it is.

### Why the strip is delegated at all

`menu_bar(tree)` hands the AES an `OBJECT` tree **in the client's address space**, which
`gemd` cannot reach (§3). So `gemd` *cannot* draw the menu. The active app must draw its
own, with the same `objc_draw` it uses for everything else.

The only question is **what it draws into**.

### A VDI workstation does not cross a process boundary

Worth stating plainly, because loose language here hides the real problem. A workstation
is **not** a handle `gemd` can pass out. `v_opnvwk(&surface)` is entirely client-side: the
client builds a `gfx_surface { w, h, stride, px }` and opens a workstation on it *locally*.

So nothing "hands a workstation to an app". What must cross is **the memory** (a mapping)
and **the geometry**. Which forces the real question: *whose* memory?

### The alternative: map the framebuffer's top strip into the client

Because the menu bar is at the **top**, the strip is a **contiguous prefix** of the desktop
plane — bytes `[0, strip_h × stride)`. (An arbitrary window rect is *not* contiguous; its
rows are a stride apart. The strip is special.) So `gemd` *could* map exactly those bytes
and nothing else, with the **MMU** as the enforcement.

And on this hardware that is **exactly page-aligned, for free**. The stride is hardwired in
the RTL:

```
    compositor.h:  /* overlay surface stride in 32-bit words (= 8192 B) */
    main.c:        #define DESK_STRIDE  2048u   /* words per row (8192-byte stride) */

    1920 visible px, padded to 2048 words.   stride = 8192 = 2^13
    page = 4096 = 2^12,  and  2^13 is a multiple of 2^12
    => strip_h × 8192 is page-aligned for ANY strip_h.
```

**So this option is sound.** There is no constraint on the menu-bar height and no
partially-mapped page to leak into the row below. (The client would additionally be able to
write the 128 px/row of off-screen padding between 1920 and 2048 — harmless; it is never
scanned out.)

It is also **cheaper**: zero copies. `objc_draw` writes the final pixels straight into the
plane.

### The decision: one strip surface **per app**, opened once

Not a shared buffer loaned around — **`gemd` gives each app that calls `menu_bar()` its own
strip-sized surface**, and composites whichever app's is active.

```
    menu_bar(tree):        ONCE, in the client's lifetime
        surface = my own strip surface        (gemd allocates it, maps it, keeps it)
        vh = v_opnvwk(&surface)               // ONCE.  Never re-opened.
        objc_draw(tree, ...)                  // and again only when the MENU changes
        post damage

    app switch:            gemd composites a DIFFERENT BUFFER.
                           No remap.  No workstation.  No message.  No repaint.
```

**Why not one shared buffer, loaned to the active app?** Because "loan" and "revoke" imply
the memory can move, and every way of arranging that is bad:

| | |
|---|---|
| **remap on each switch** | the address may differ, so the client must rebuild its `gfx_surface` and **re-open its workstation** — on every single app switch |
| **keep it mapped in everyone** | any backgrounded app can **write** to the strip the active app is using. Ignoring their *damage* is not enough; they would corrupt the *pixels*, and `gemd` would blit the corruption |
| **keep it mapped, flip page protections on switch** | the address is stable and the workstation survives — but an inactive app then cannot draw its menu, so it **must repaint on becoming active**: a round-trip on every switch, and a wedged app shows a blank strip |

A surface per app costs **192 KB each** instead of 192 KB total (24 rows × 8192). Eight apps
with menus is ~1.5 MB — nothing on a DDR machine — and it buys four things at once:

1. **The workstation is opened once** and stays valid for the app's lifetime. The strip is
   not a thing an app re-negotiates.
2. **No cross-app write hazard.** Nobody shares a buffer, so nobody can scribble on anybody.
3. **An app switch costs zero IPC.** It is a compositing decision, not a conversation.
4. **`gemd` holds every app's menu pixels** — so a **wedged app's menu bar still composites
   correctly** rather than going blank.

(4) deletes a failure mode this document previously accepted. It also removes two mechanisms
outright: `gemd` no longer needs to **clear the strip** before an ownership change, and there
is no *"tell the new owner to draw its menu"* step at all. **Ownership of the strip is not an
event.** It is just which buffer gets composited.

An app that never calls `menu_bar()` never gets a strip surface, and costs nothing.

### Which means Rule 1 has no exceptions

> **Only `gemd` touches the screen.** No client, ever, for any reason.

`gemd` still owns the strip region, still reserves it (`g_top_reserve`), still clears it
before handing it to a new owner. It simply hands over **a surface**, not a window onto the
framebuffer.

## 11. Chrome is declarative ✅

> ### If a client has to **draw** it, it is not chrome.
> Chrome is **`gemd`'s**, drawn from a **model**. Anything that needs arbitrary drawing is
> **content**, and content goes in a **view**.

That single line decides every case below, including the ones that look awkward.

### The old philosophy, and why the split ends it

`aes.h` says it three times: *"window.c stays content-agnostic"* — GEM draws the boxes, and **the
app draws the contents and hit-tests them itself** (`wind_title`, `wind_info`, and
`wind_titlebtn_rect` + a raw `MU_BUTTON` in the title span).

That was right in one process, where an app *could* draw on the screen. **In the split it is not a
preference — it is impossible.** A client has no screen. Chrome lives in `gemd`'s pixels.

### What each call becomes

| today | becomes | why |
|---|---|---|
| `wind_set_name(h, name)` | **keep** | already declarative |
| `wind_titlebtns(h, glyphs[], n)` | **keep** | already declarative — a list of glyph ids |
| `wind_titlebtn_rect()` + app hit-tests | **delete** | `gemd` routes input, so a press is a **message**: `WM_TBUTTON(idx)`, the same shape as `WM_CLOSED` |
| **`wind_title(h, fn, ud)`** — a draw callback | **delete** | → `wind_set_title(h, text, subtitle, icon_id, flags)` |
| **`wind_title_active()`** | **delete** | it exists *only* so an app can pick a pen legible against `gemd`'s own bar. `gemd` knows its own bar. The app must never need to. |
| **`wind_info(h, fn, ud)`** — a draw callback | **delete** | → `wind_set_info(h, text)` |

A declarative title covers everything the callback was *for*: a proxy/document icon (an icon id), a
modified indicator (a flag), middle-ellipsis truncation (**`gemd` does it** — `aes_label_fit`
already exists), a path or subtitle (a second string). All model. No drawing.

### The one that looks like a loss, and is not

`W_INFO`'s footer is the only place the current API lets an app put **arbitrary drawing into
chrome** — the header even says *"count/path/toolbar"*. A toolbar is not a string.

**But a toolbar is not chrome either. It is content**, so it belongs in a view at the bottom of the
content area. And that is strictly *more* capable: such a view is themable, hit-testable, gets
target/action, and **draws into the client's own backing store**, so it costs `gemd` nothing. The
only thing lost is the ability to draw badly in someone else's territory.

### Why declarative, and not "a chrome surface per client"

**1. Chrome is exactly the part that must survive the app being dead.** §9 promises a wedged app's
windows still composite from their backing stores. If chrome were a client callback — or a client
surface it had stopped updating — `gemd` could not repaint the title bar of a wedged app, and you
would get a window compositing correctly with a **blank or stale title**. Declarative chrome means
`gemd` redraws it from its own model. Always.

**2. Dragging is the latency-critical path.** `gemd` repaints chrome every frame while a window
moves. Client-drawn chrome means a **client round-trip per frame**, or a cached surface with
invalidation. Declarative means `gemd` just draws it.

**3. It is bytes, not surfaces.** The menu strip needs a surface because a menu is an arbitrary
`OBJECT` tree (§10). **A title bar is ~64 bytes of model.** Making it a surface would be absurd —
and it would be one more place a client writes into `gemd`'s pixels, which is the exact category
this design has spent its life closing (`SEC_PLANE` §2, `menu.c`'s save-under §10, `form.c`'s
save-under §16).

**4. It deletes code.** `wind_title`, `wind_title_active`, `wind_titlebtn_rect`, the app-side chrome
hit-testing, and the "a raw `MU_BUTTON` in the title span" special case **all go away**, replaced by
one message. A change that makes both sides smaller is usually in the right place.

### Are we losing any *standard* GEM calls?  No — and the change is a RETURN to GEM

Every call being deleted is **our own invention**. And three of the four are inventions that
**replaced a declarative classic-GEM mechanism with a callback**:

| deleted | classic GEM equivalent |
|---|---|
| `wind_title(fn)` | `wind_set(h, **WF_NAME**, string)` — **a string** |
| `wind_title_active()` | none — it exists *only* to serve `wind_title` |
| `wind_titlebtns()` / `wind_titlebtn_rect()` | none |
| `wind_info(fn)` | `wind_set(h, **WF_INFO**, string)` — **a string** |

**Classic GEM's title and info line were always declarative strings.** `WF_NAME=2` is still sitting
in our enum; `WF_INFO` — field 3 in classic GEM — **we never implemented at all**, and replaced with
a draw callback.

So this is not a deviation from GEM. **It is a return to it.** TOS drew the title and the info line
from strings for forty years, and it was right to: *an app that cannot draw on the screen cannot
draw its own chrome* — as true on a 68000 as it is across a socket.

We are already halfway there: `wind_set_name(h, name)` **is** the declarative form, spelled more
nicely than `wind_set(h, WF_NAME, ptr_hi, ptr_lo, 0, 0)`. We are not inventing a mechanism; we are
extending one we already have.

**Every classic AES window call survives untouched** — `wind_create`, `wind_open`, `wind_close`,
`wind_delete`, `wind_get`, `wind_set`, `wind_calc`, `wind_find`. And our *other* inventions stay,
because they are **additive rather than substitutive**: `wind_content`, `wind_redraw_win`/`_area`,
`wind_content_size`, the scroll calls. None of those asks a client to draw in `gemd`'s pixels.

### ✅ LANDED (`fpga-xt` `ff669ca`) — and it should be `wind_set`, because `wind_set` was BROKEN

`wind_set` implements **exactly one field**:

```c
    void wind_set(int hd,int field,int a,int b,int c,int d){
        if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
        if(field==WF_CURRXYWH){ ... }        /* <- the ONLY field.  That is the whole function. */
    }
```

**`WF_NAME` is in the enum and silently ignored.** Meanwhile `aes.h` opens with:

> *"The classic GEM ABI (OBJECT layout, types, flags, states, **call names**) is preserved so **m68k
> apps bind to it directly**."*

So a classic GEM app that sets its title the only way it knows how — `wind_set(h, WF_NAME, ...)` —
**gets silence.** No title, no error. The silent-degradation pattern, this time in GEM.

**And `wind_set_name()` is why nobody noticed.** The sugar gave everything in our own tree a working
path, so the hole in the *compatible* path was never exercised. **A convenience wrapper that hides a
broken standard call is worse than no wrapper**, and this one hid it for the whole life of the
project.

### The protocol — one field per attribute, which is how GEM has always grown

No new mechanism. The declarative chrome model *is* `wind_set`:

```
    WF_NAME       (2)   title string            <- classic.  Currently IGNORED.
    WF_INFO       (3)   info string             <- classic.  Never implemented.
    WF_SUBTITLE         subtitle string         <- new field, classic shape
    WF_ICON             proxy / document icon
    WF_TITLEFLAGS       modified dot, etc.
    WF_TITLEBTNS        glyph list + count

    gemd -> client:     WM_TBUTTON(h, idx)      a title button was pressed
                        WM_CLOSED / WM_TOPPED / ...   as now
```

`wind_title`, `wind_title_active`, `wind_info`, `wind_titlebtns`, `wind_titlebtn_rect` **and
`wind_set_name`** all collapse into `wind_set`.

**The type-safety objection answers itself.** Yes, `wind_set(int,int,int,int,int,int)` passing a
`char*` through an `int` is ugly, and DWARF cannot tell xtc it is a pointer. But that is GEM's ABI,
and it is the price of the compatibility the header promises. **Type safety belongs in Xtg, not the
AES**: `XGWindow.setTitle(u8@)` wraps the cast and app code never sees it.

> **The toolkit is where types go. The AES is where compatibility goes.** That is the same layering
> this document defends everywhere else — and the reason `wind_set_name` felt harmless is that it
> quietly put a toolkit concern (a nicer signature) into the compatibility layer.

**Open question for the GEM/m68k track:** if m68k apps really do "bind directly", `wind_set(WF_NAME)`
must accept the classic **hi/lo pointer split** across two 16-bit args — our `int` is 32-bit and the
pointer fits in `a` alone. Someone should decide whether "binds directly" is literally true, because
the answer changes the signature.

`gemd` owns the model, so a full repaint, a drag, a theme change or a wedged owner all redraw
correctly with **no client involvement whatsoever.**

### What landed

**libGEM** (`ff669ca`):

```c
    wind_set(h, field, a, b, c, d)      /* now implements its fields:                       */
        WF_NAME (2)  WF_INFO (3)  WF_TOP (10)  WF_CURRXYWH (5)          /* classic          */
        WF_SUBTITLE (32)  WF_ICON (33)  WF_TITLEFLAGS (34)  WF_TITLEBTNS (35)  /* ours       */

    wind_get_str(h, field, &hi, &lo)    /* read a string field back — the AES's OWN copy     */
    WIND_PTR_HI/LO/WIND_PTR             /* the classic hi/lo split, for native callers       */
```

- **Pointer fields take the classic hi/lo split** (`a` = high half, `b` = low half), because GEM has
  always passed a pointer as two 16-bit words and an m68k app must bind directly.
- **`draw_one` renders the title MODEL**: proxy icon (`WF_ICON`, a theme slice name) · name ·
  unsaved-changes dot (`WT_MODIFIED`) · subtitle, centred as one group. And it draws the `W_INFO`
  footer from `WF_INFO` text.
- **The `wind_title` / `wind_info` draw callbacks are deprecated**: consulted *only* when no model
  text is set, so nothing in the tree breaks while `aesdesk`/`xtdesk` migrate. They go away after
  that — **a client cannot draw in `gemd`'s chrome.**
- `wind_set_name` is now implemented **through** `wind_set` rather than *beside* it. That is the only
  reason it is safe to keep.

**Xtg** — the typed wrapper, and the whole point of having a toolkit:

```c
    win.setTitle("Rocks");
    win.setSubtitle("/System/OS/Apps/Desktop/desktop.rsc");
    win.setInfo("11 objects   tree 0 of 1");
    win.setIcon("alert.note");
    win.setModified(true);
```

The hi/lo cast is buried in **one** private method (`XGWindow.setField`). App code never sees it.

> **The toolkit is where types go. The AES is where compatibility goes.** The reason `wind_set_name`
> felt harmless is precisely that it smuggled a *toolkit* concern (a nicer signature) into the
> *compatibility* layer — and then hid a hole in the layer it had displaced.

### ✅ Verification status — BOARD-VERIFIED (updated 2026-07-16)

**The declarative chrome model runs on hardware.** The window title/subtitle/icon/modified/buttons
model draws correctly on the board; breadcrumbs hit-test via `WM_PATHSEG`; the info strip is client
content; and (M4b) the menu bar and its dropdowns work. `gemd` reached M4b (menus + grabs + liveness),
not "M4 of 7 built-not-run". `libGEM` still has no single-process mode on XTOS — correct, and the Xtg
`test_chrome.xt` suite is the remaining piece to run, but the AES/chrome layer itself is proven.

> *(Original note, superseded: "Built, not run… gemd is at M4 of 7… no client can attach." That was
> true at the time of writing; the split is now board-verified through M4b.)*

`gemd` owns the model, so a full repaint, a drag, a theme change or a wedged owner all redraw
correctly with **no client involvement whatsoever.**

### What landed

**libGEM** (`ff669ca`):

```c
    wind_set(h, field, a, b, c, d)      /* now implements its fields:                       */
        WF_NAME (2)  WF_INFO (3)  WF_TOP (10)  WF_CURRXYWH (5)          /* classic          */
        WF_SUBTITLE (32)  WF_ICON (33)  WF_TITLEFLAGS (34)  WF_TITLEBTNS (35)  /* ours       */

    wind_get_str(h, field, &hi, &lo)    /* read a string field back — the AES's OWN copy     */
    WIND_PTR_HI/LO/WIND_PTR             /* the classic hi/lo split, for native callers       */
```

- **Pointer fields take the classic hi/lo split** (`a` = high half, `b` = low half), because GEM has
  always passed a pointer as two 16-bit words and an m68k app must bind directly.
- **`draw_one` renders the title MODEL**: proxy icon (`WF_ICON`, a theme slice name) · name ·
  unsaved-changes dot (`WT_MODIFIED`) · subtitle, centred as one group. And it draws the `W_INFO`
  footer from `WF_INFO` text.
- **The `wind_title` / `wind_info` draw callbacks are deprecated**: consulted *only* when no model
  text is set, so nothing in the tree breaks while `aesdesk`/`xtdesk` migrate. They go away after
  that — **a client cannot draw in `gemd`'s chrome.**
- `wind_set_name` is now implemented **through** `wind_set` rather than *beside* it. That is the only
  reason it is safe to keep.

**Xtg** — the typed wrapper, and the whole point of having a toolkit:

```c
    win.setTitle("Rocks");
    win.setSubtitle("/System/OS/Apps/Desktop/desktop.rsc");
    win.setInfo("11 objects   tree 0 of 1");
    win.setIcon("alert.note");
    win.setModified(true);
```

The hi/lo cast is buried in **one** private method (`XGWindow.setField`). App code never sees it.

> **The toolkit is where types go. The AES is where compatibility goes.** The reason `wind_set_name`
> felt harmless is precisely that it smuggled a *toolkit* concern (a nicer signature) into the
> *compatibility* layer — and then hid a hole in the layer it had displaced.

### ✅ Verification status — BOARD-VERIFIED (updated 2026-07-16)

**The declarative chrome model runs on hardware.** The window title/subtitle/icon/modified/buttons
model draws correctly on the board; breadcrumbs hit-test via `WM_PATHSEG`; the info strip is client
content; and (M4b) the menu bar and its dropdowns work. `gemd` reached M4b (menus + grabs + liveness),
not "M4 of 7 built-not-run". `libGEM` still has no single-process mode on XTOS — correct, and the Xtg
`test_chrome.xt` suite is the remaining piece to run, but the AES/chrome layer itself is proven.

> *(Original note, superseded: "Built, not run… gemd is at M4 of 7… no client can attach." That was
> true at the time of writing; the split is now board-verified through M4b.)*

---

## 12. Buffer lifetime: refcount, do not handshake ✅

A surface is **reference-counted**. `gemd` holds one ref; each client that has it mapped
holds one. It is freed when the count reaches zero and **not before** — no matter how
dead, stale or superseded it has been declared.

This makes resize a non-event:

```
    resize:   gemd allocates a NEW buffer (new id), tells the client, and drops its
              own ref on the old one.

    client:   may still be mid-draw into the old buffer.  That is fine.  It finishes,
              harmlessly, into memory nobody will composite.  Then it maps the new id
              and drops its ref on the old.          refcount -> 0 -> freed.
```

**Nobody blocks and nobody waits.** The in-flight draw is merely *wasted*, not *unsafe* —
and wasting one frame during a resize is not worth a round-trip to avoid. `gemd` still
carries a generation number per surface, but only so it can **discard** damage posted
against a stale one; it never has to *synchronise* on it.

And this is not a resize mechanism. It is the buffer lifetime rule, and the same counter
covers three separate bugs:

| | |
|---|---|
| **resize** | the old buffer outlives the client's in-flight draw |
| **window closed while `gemd` is mid-composite** | `gemd`'s own ref keeps it alive until the composite ends |
| **app died while `gemd` still holds its pixels** | the dead client's ref is dropped; `gemd`'s keeps the memory valid |
| **a blit is in flight into a dead process's surface** | the surface outlives the process until the blit retires (§13) |

**What it does not fix, and does not pretend to: tearing.** A client can be painting frame
N+1 into a buffer `gemd` is compositing frame N from. Refcounting is *lifetime*, not
*exclusion*. That is a separate decision — §15.

---

## 13. Surface memory: capacity, extent, and resize ✅

A backing store is the **elephant** in the memory budget, and the naive policy — "allocate
exactly the window size, reallocate on every resize" — fails badly. This section is the policy.

### First, the size is not what it looks like

**A backing store is *window*-sized, not screen-sized.** A surface has its own stride, so:

```
    800 x 600 window        800 x 600 x 4  =  1.92 MB       (not 8.5)
    full-screen window     1920 x 1080 x 4 =  8.5 MB        (the only 8.5 MB case)
```

A plausible session:

| | |
|---|---|
| the desktop (full screen) | 8.5 MB |
| 4 app windows @ 800×600 | 7.7 MB |
| 4 menu strips | 0.8 MB |
| **total** | **≈ 17 MB** |

Nothing against phase 1's 480 MB OS heap; **13% of phase 2's 128 MB `plv`**, which is shared
with glyph atlases and DMA buffers. So it is a budget, not a crisis — but it needs a policy,
and for a sharper reason than steady-state size.

### The real problem is interactive resize

Dragging a window edge fires a resize **on every mouse move** — dozens per second. A naive
realloc-per-resize would reallocate, copy and remap an 8 MB surface **sixty times a second**.
*That* is what falls over, not the steady state.

And the case that makes it look worse than it is: **a tiling grid of small windows, any one of
which could be dragged out to fill the screen.** Sizing every window for its worst case would
be ruinous. The answer (below) is that it never happens — only *one* window is ever growing at
a time, because resize is a grab.

### The rule: a surface has a **capacity** and an **extent**

- **capacity** — what is allocated
- **extent** (`w`, `h`) — what the window currently is

**Resize within capacity is free.** Change `w`/`h`; no realloc, no copy, no remap, no new
handle, no protocol traffic. Only growth *past* capacity reallocates.

> ### 🔴 A surface's stride is its CAPACITY width, not its current width.
>
> This must be designed in from **day one**. If the stride tracked the *visible* width, growing
> a window by one pixel would invalidate the entire layout of the buffer — every row would move.
> With a fixed stride, the window simply uses the top-left `w × h` **sub-rect** and the rows stay
> put. The VDI draws into the sub-rect; `gemd` blits the sub-rect.
>
> Small decision, very expensive to retrofit.

### Interactive resize: one scratch surface, no allocations

The hot case is solved by not allocating at all during the gesture.

> **Resize is a grab. Only one can be in flight, system-wide.**

That is the property that makes this cheap: **one** scratch surface suffices — not one per app,
not one per window. Ten tiled windows, any of which *could* be grown to full screen, cost
nothing extra, because only one is ever *growing* at a time.

```
    sizer grabbed:     gemd maps THE scratch (screen-sized) into the resizing app.
                       the app retargets its VDI at it and draws there.
    during the drag:   every mouse move changes w/h.  NO ALLOCATION.  NO REALLOC.  NO REMAP.
                       gemd composites the window from the scratch.
    button-up:         gemd allocates the real surface at the final size, rounded up to 64px,
                       BLITS scratch -> new surface, hands the app the new id, unmaps the
                       scratch.
```

**And it is the same buffer as the drag overlay.** You cannot move and resize a window at once
— both start from a click on chrome (mover vs sizer), both take the grab, both are exclusive.
So the move overlay and the resize scratch are **never live simultaneously** and share one
allocation:

```
    DRAG_BASE  0x3200_0000  drag-overlay surface (16 MB)   <- screen-size is 8.5 MB. It fits.
```

**Zero new memory.**

#### The wrinkle: the app's workstation retargets

During the drag the app draws into the scratch, not its own backing store — yet §10 insists a
workstation is **opened once and never re-opened**.

That survives, because this is a **retarget, not a re-open**. The VDI holds a *pointer* to a
`gfx_surface`; mutate that struct's `px` / `stride` / `w` / `h` in place and the workstation
now targets the scratch. No `v_opnvwk`, no fd churn.

And §10's objection to "loan/revoke" does not apply:

| §10 — the menu strip | here — the resize scratch |
|---|---|
| loan/revoke on **every app switch** | map once per **gesture** |
| **every** app would have it mapped → cross-app write hazard | **exactly one** app has it mapped — resize is a grab |

#### Settle is a blit, not a redraw

On button-up `gemd` blits scratch → the new surface. The blitter handles the differing strides
(screen stride in the scratch, capacity stride in the new surface), so **the app never repaints
at settle**. The old surface stays alive until the handover completes — §11's refcount already
guarantees that.

### Capacity, quantised — for everything the scratch does not cover

The scratch handles the *interactive* case completely. Capacity/extent still earns its keep for
the rest:

- **programmatic resizes** (an app setting its own size) — rare, un-gestured, no grab
- **fine adjustments after settle**, absorbed by the 64 px headroom

**Quantise; do not multiply.** An over-allocation *multiplier* is the obvious policy and it is
the wrong one. **1.5× on both axes is 2.25× the memory** — and for a full-screen window it asks
for 2880×1620 = **18.7 MB** of capacity **no window can ever use**:

| | exact | 1.5× on both axes | **64 px grid** |
|---|---|---|---|
| 800 × 600 | 1.92 MB | 4.32 MB (**+125%**) | 832 × 640 = **2.13 MB (+11%)** |
| full screen | 8.5 MB | 18.7 MB (**unusable**) | **8.5 MB (+0%)** |

**Capacity is capped at screen size**, always.

### Shrink when the gesture settles — never during it

"Never shrink" is tempting and wrong: **maximise a window once and it holds 8.5 MB forever.**
Do that to three windows and `plv` is gone. With the scratch, shrinking is not even a special
case — the surface is *allocated fresh at settle*, to the final size. There is nothing to shrink.

For programmatic resizes, which have no gesture: shrink capacity when the new extent has been
smaller than half the capacity for some settling period. Cheap, and it is not the hot path.

### The pressure valve

Under memory pressure, `gemd` may **drop the backing store of a fully-occluded or minimised
window**, and ask its owner to redraw on reveal.

This deliberately trades away §3's promise — *"a window's pixels survive occlusion"* — for RAM,
and **only under duress**. It is written down as an explicit valve so that it is a decision
rather than a discovery. The normal path never does this.

---

## 14. The blitter: how pixels actually get drawn 🟡

Everything above talks about "drawing" as if it were the CPU writing pixels. It is not.
**Drawing is hardware**, and that changes three things: where surfaces live, how a client
reaches the engine, and what "I have drawn" actually means.

### The blitter does the work — including alpha

The `xt-blitter` is a command-queued 2D engine in fabric, reading source pixels and writing
DDR3 directly over AXI:

- rectangle fill and **pattern fill** (RGBA-8888, **per-pixel alpha**)
- **block blit**, and **scaled blit** (nearest / bilinear)
- **alpha blending** over the destination
- line draw, rotate / affine

Which means **`theme_draw` is not CPU work.** A 9-slice is nine alpha blits, two of them
stretched — squarely inside the engine's capabilities. The same goes for text (a glyph atlas
is an alpha-coverage blit), icons, and every fill. **The CPU never touches those pixels.**

That is what makes the next fact affordable.

### Surfaces are PL-visible, contiguous — and uncached

The blitter is a DMA engine reading **physical** addresses, so anything it touches must be
physically contiguous and inside the PL-shared region (`0x2000_0000..0x3FFF_FFFF`). The MMU
maps that region **Normal non-cacheable** — the *"PL-visible ⇒ wired/uncached"* invariant
(`mmu.c`).

Window backing stores therefore come from `plv_alloc` (the PL-visible heap at `0x3800_0000`,
whose documented purpose is literally *"GEM window backing surfaces"*), and they are
**uncached**.

**This is fine precisely because the CPU is not the renderer.** Uncached memory would be a
disaster for software alpha blending — read-modify-write per pixel, straight to DRAM — but
nothing does that here. The blitter does not go through the CPU cache at all.

**What is still CPU**, and what it costs:

| | |
|---|---|
| stock widgets, text, icons, fills, theme | **blitter.** The CPU never sees the pixels. |
| a custom `drawRect` (a canvas, a waveform, an image editor) | **CPU**, and it would be slow writing straight to an uncached surface |
| polygon scan conversion | CPU |

So an app doing genuine raw pixel work draws into a **private cached buffer** and lands it
with **one blit**. The staging cost falls on the handful of apps that pixel-push — *not* on
every button in the system.

> **⚠ Not true yet — and deliberately deferred.** The VDI is `gfx_soft.c` today, so
> `theme_draw` *is* currently CPU. Giving the VDI a blitter backend is what makes uncached
> surfaces acceptable, so **the blitter backend and the move to PL-visible backing stores must
> land together** — either alone is worse than neither. All of this section is **phase 2**;
> see §14.

### `/dev/blitter`: a client may never touch the engine directly

**The blitter has no MMU.** It takes physical addresses. A process with raw access to its
registers can blit to **any physical address** — another app's backing store, the
framebuffer, the kernel. Raw blitter access *is* arbitrary physical write, and it would
silently annihilate every isolation property in this document.

So it is a **device**, and the kernel mediates:

```
    v_opnvwk(surface)  ->  the VDI opens a /dev/blitter fd, bound to that surface
    drawing            ->  write(fd, cmds, n)      one batch per objc_draw, not per primitive
    gemd               ->  ioctl(fd, PRIORITY)     privileged; only the aes_init process
```

The fd is the capability. The kernel already knows which process owns it; it closes on
process death, so queue cleanup is free.

**Four rules the driver must hold.**

**(1) Commands name surfaces by *handle*, never by address.**

```c
    { op, dst_id, dst_rect, src_id, src_rect, flags }      /* ids — NOT addresses */
```

The driver resolves `id → physical` and clips the rects to the surface bounds. **A client
cannot even express an out-of-bounds blit.** If commands carried physical addresses instead,
the driver would have to validate every rect × stride range against the caller's surface
set — possible, but it only needs to be got wrong once. Sources need this as much as
destinations (the theme atlas, the glyph atlas, and the client's own surface — a scroll is
`src == dst`).

**(2) Arbitrate at the hardware FIFO, not at accept.**

The engine has a single **~1024-deep** command FIFO. If the driver accepts round-robin but
then pushes client work straight into it, **the FIFO becomes the unarbitrated resource** and
`gemd`'s priority commands simply wait behind 1024 already-committed client blits. The driver
must hold its own software queues and feed the hardware a few commands at a time, keeping
headroom so the priority fd can always get in.

**(3) 🔴 Damage carries a blit sequence number — or priority causes half-drawn windows.**

This hazard is *created* by giving `gemd` priority; it cannot happen in a plain FIFO.

```
    client:  enqueues its draw blits         (round-robin queue — waits)
    client:  posts damage
    gemd:    enqueues a composite blit        (PRIORITY — jumps the queue)
    gemd:    composites a window whose own draws HAVE NOT RETIRED.
```

The fix is a counter. **The driver returns a sequence number on submit; the damage message
carries it; `gemd` does not composite until that seq has retired.**

This also makes the damage contract *honest*. §3 says "the client draws, then posts damage",
which quietly assumed drawing was synchronous. **With a queued engine it never was** —
priority merely exposes an assumption that was already false. "Posted damage" must mean *"my
pixels are in memory"*, and only a fence can say that.

**(4) Fairness is per-*process*, not per-fd.**

The VDI opens a blitter fd per **workstation**, so an app with six windows and a menu strip
has seven fds. Round-robin over *fds* rewards opening windows; an app would get a bigger
share of the engine by having more surfaces. Round-robin over **processes**, with an app's
fds sharing one slot, is what fairness means.

### It falls out that

- **A client that floods the queue cannot stall the screen.** Priority + FIFO headroom means
  `gemd` always composites. This matters: the blitter is a *hardware* path, and none of the
  software rules in §9 would have protected it. It is exactly the regression §13 tells us to
  defend against, arriving by a route the rest of the document does not cover.
- **`gemd` never blocks on a full queue** (§3 forbids it). It gets `EAGAIN` and retries; a
  *client* may block.
- **An in-flight blit into a dead process's surface is already safe.** `shm_t.nref` keeps the
  surface alive until the blit retires — which is precisely the refcount rule in §11. The
  lifetime rule designed for *resize* covers *DMA-in-flight* for free, which is a good sign
  the model is right.

---

## 15. Staging: what lands when 🟡

Standing up `gemd`, splitting the client libraries, rewriting the toolkit **and** bringing up
hardware blitting at once is too much in flight. It is staged. This section exists so the
staging does not quietly bake in an assumption that phase 2 has to unpick.

### Phase 1 — `gemd`, with **software** compositing

Everything in §3–§11. **No blitter.**

| | |
|---|---|
| **backing stores** | **ordinary cached memory**, scattered pages, from the 480 MB OS heap. **Not `plv`.** |
| **client drawing** | the software VDI, as now (`gfx_soft.c`) — into *cached* memory, so it is fast |
| **`gemd` compositing** | **CPU**: a copy of the damaged rect into the framebuffer plane. That write is to uncached PL memory, but a sequential streaming write is the one thing uncached memory is good at, and it is only the damaged bytes. |
| **kernel needs** | **two things.** (1) **Variable-size shm** — drop the 1 MB per-object cap and the fixed VA slot partition. (We never used the same-VA guarantee — only *pixels* cross, and a pixel buffer holds no pointers.) (2) **`sys_shm_unmap`** — §11's refcount requires a **live** process to drop a ref, and XTOS's only `nref--` runs on process *death* (`vm_space_destroy` → `vm_shm_drop_space`). Without it, every resize (§12) and every window close leaks its surface **and** its id — in phase 1 exactly as in phase 2. See §2. |
| **Xtg needs** | **one method.** `XGApplication.boot()` → `.attach()`. |
| **the last commit of phase 1** | **`SEC_PLANE` → PL0-none** (§2). Clients need *nothing* from it in phase 1, so this is the cheapest moment to close the hole — and it doubles as a mechanical proof that the split is complete: **if flipping it breaks something, the split is not done.** |

> **⚠ Do not put backing stores in `plv` "to be ready for the blitter".** `plv` is **uncached**
> (§13), and a *software* VDI writing to uncached memory is the worst of both worlds: the full
> uncached penalty, none of the hardware speed. Backing stores move to `plv` **when the VDI's
> blitter backend moves**, and not one commit before. The two are a single change.

### Phase 2 — hardware blitting

| | |
|---|---|
| **kernel** | `/dev/blitter`: handle-based commands, priority ioctl, per-process fairness, retire counter (§13). Plus `plv` surface allocation. |
| **GEM** | a **blitter backend for the VDI**; backing stores move to `plv` (contiguous, uncached); `gemd` composites with the blitter |
| **Xtg** | `XGGraphics` stages a custom `drawRect` through a private *cached* buffer and lands it with one blit — so raw pixel-pushing apps still draw fast against an uncached surface |

### ✅ What phase 1 must get right, even though it does nothing there — DONE

**The damage message carries a retire-sequence number.** From day one. ✅ — it is in the wire
protocol (`m->u[2]`, dead in phase 1, live for the phase-2 fence). The stride-is-capacity rule,
the handle-not-address rule, and the VDI backend seam below are all in place and board-verified.

In phase 1 drawing is **synchronous**, so *"I posted damage"* genuinely does mean *"my pixels
are in memory"*. The fence is unnecessary and the field sits unused, always comparing
"retired".

In phase 2 that is **false** (§13.3): a queued blitter means the client's draws may still be
in flight when `gemd`'s priority composite jumps ahead. If the seq field is not in the wire
protocol from the start, phase 2 becomes a **protocol change across every client**.

> It is a dead `u32` now, and it saves a migration later. And it is the general shape of the
> risk in any staging: **phase 1 makes a false assumption look true for a year.** The
> assumption "drawing is synchronous" is false the moment the engine is queued — the staging
> merely hides it.

**And the stride rule (§12).** A surface's stride is its **capacity** width, not its current
width. If phase 1 sets stride from the visible width, every resize invalidates the buffer
layout and the capacity/extent scheme cannot be added later without touching every draw path.

**Two more, cheaper:**

- **Surfaces are named by *handle* everywhere**, never by address — so phase 2 changes only the
  allocator behind the id, not the protocol (§13.1).
- **The VDI keeps a backend interface** (fill / blit / scaled-blit / blend), even while the only
  implementation is software. If the VDI's internals assume direct pixel access to the target,
  a command-queue backend is a rewrite rather than a backend.

### 🔴 The blanket `PL0-RW` mapping comes down in phase 1 — it is the *last commit* of phase 1

**Today every process can write the framebuffer.** Not by mapping it — by *already having it*.
`mmu.c` builds the master L1 with

```c
else if (i < 1024)  l1[i] = base | SEC_PLANE;   /* SALLY/planes: PL0-RW, non-cacheable */
```

`i` runs from `0x200`, so that is `0x2000_0000`–`0x3FFF_FFFF` — **512 MB, PL0-RW, in the master
table, inherited by every space** (`vm_space_create` copies it). Verified: there are **three**
doors, not one.

| L1 sections | region | mapping |
|---|---|---|
| `0x200`–`0x3FF` | `0x2000_0000` (512 MB) | `SEC_PLANE` — PL0-RW, non-cacheable. Framebuffer, wallpaper plane, drag overlay, sprite arena, SALLY banks — **and `plv` at `0x3800_0000`.** |
| `0x330`–`0x33F` | `0x3300_0000` (16 MB) | `SEC_PLANE_C` — wallpaper back-buffer, PL0-RW **cacheable** |
| `0x208`–`0x209` | `0x2080_0000` (2 MB) | `SEC_PLANE_C` — math-cop chunk stack, PL0-RW cacheable (a DMA buffer shared with the PL) |

**This is deliberate and correct *today*** — the comment at `mmu.c:101` says so: *"the PL-shared
planes stay PL0-RW (programs draw the framebuffer)"*. There is no `gemd`, and programs genuinely
do draw the framebuffer. It cannot close until `gemd` exists. Agreed.

**But it means the handle-based validation of §13.1 is defeated by a `memcpy`.** `plv` lives at
`0x3800_0000`, *inside* the blanket. In phase 2, backing stores live in `plv`. So a client could
read and write another client's backing store directly, at its identity address, never going
near `/dev/blitter`. Two doors — and §13 locks one of them.

> A capability you can walk around is not a capability. `/dev/blitter` refusing an
> out-of-bounds rect is theatre if the same client can `memcpy` to the same pixels.

**Phase 1 is the cheapest moment to close this, not the hardest.** The instinct is to defer it
to phase 2, alongside `plv` and the per-surface mapping. That is backwards:

| | |
|---|---|
| **phase 1** | A client needs **zero** access to `SEC_PLANE`. Backing stores are ordinary cached OS-heap memory (§14) — deliberately *not* `plv`. The only process that needs the framebuffer plane is `gemd`, which composites into it with the CPU. So: **`SEC_PLANE` → PL0-none for everyone; `gemd` gets the plane mapped explicitly; clients get nothing.** The hole closes, and *there is nothing to build.* |
| **phase 2** | Surfaces come **back**, individually, via `shm` — which is the per-surface mapping machinery you are building anyway (kernel items 2–4). |

Defer it, and phase 2 must build the per-surface mapping **and** flip the blanket at the same
time, with more moving parts and a live system to keep working. Do it in phase 1 and the blanket
comes down **while nobody is standing under it**.

**It is a one-way door, so it is a completion criterion, not a task.** The moment `SEC_PLANE`
goes PL0-none, any app still drawing direct to the framebuffer breaks. So it is not a ticket
*inside* phase 1 — it is **the last commit of phase 1**, gated on *"no app draws direct any
more"*. That is a good gate to have: it is a hard, mechanical proof that the client/server split
is complete. **If flipping it breaks something, the split is not done.**

The gate is closer than it looks: today only **two** programs draw direct — `aesdesk.c` and
`desktop.c`. Nothing in `gem/` does.

**Two things fall out of it:**

- **`WALLPAPER_BASE` (16 MB, PL0-RW cacheable) is not what its name says.** I previously called it
  "probably redundant". **That was wrong, and the correction matters:** the desktop no longer uses
  it as a wallpaper backdrop at all — it uses it as its **entire cacheable compositing
  back-buffer**, drawing everything there and pushing only dirty rects to the scanned plane. It is
  *repurposed*, and it is load-bearing today.

  So it cannot simply be deleted. What §4 *does* imply is that its **original** purpose is
  redundant — the desktop is an ordinary app and its wallpaper is *content*, in its own backing
  store, not a privileged plane every process can write. Under gemd the back-buffer becomes an
  ordinary surface too. **The region goes away by being made unnecessary, not by being removed
  from under a live user.** (Wallpaper image support was lost in the desktop rename and is tracked
  separately: `docs/OS/wallpaper-restore.md` in fpga-xt.)
- **The math-cop chunk stack: DECIDED — it stays PL0-RW, for now.** It is the third door
  (`0x2080_0000`, 2 MB, cacheable), and it is not about drawing at all — it is a DMA buffer
  shared with the PL math coprocessor. It is *deliberately* being left generally accessible: the
  math co-pro is a compute service any program may use, and exposing it is not a windowing
  concern. **This is a narrow, conscious exception, not an oversight** — which is the whole
  reason it is written down here. The blanket coming down (above) is about *pixels*, and it must
  not silently sweep the co-pro up with them.

  > The risk it leaves is bounded and worth naming: a hostile program can corrupt *another
  > program's math results* through that buffer. That is a real hole, but it is a **compute**
  > hole, not a **display** one — it cannot be used to read or scribble another client's window.
  > If the co-pro ever grows per-process state worth protecting, it wants the same treatment as
  > a surface: mapped on request, not blanket-granted.

### What phase 1 deliberately does *not* do

No `plv` pressure, no contiguity requirement, no cache-maintenance discipline, no
`/dev/blitter`, no FIFO fairness, no fence. Every one of those is a phase-2 concern, and phase
1 is better for not pretending otherwise.

(**Note that the `SEC_PLANE` flip above is *not* on this list.** It is the one piece of
phase-2's isolation story that must land in phase 1 — precisely because in phase 1 it costs
nothing, and in phase 2 it costs a migration.)

---

## 16. Not yet decided 🔴

The honest list. Someone will have to make a call on each.

1. **Tearing.** Refcounting (§11) gives a buffer's lifetime, not exclusive access — a
   client may paint frame N+1 while `gemd` composites frame N. Per-window double-buffer,
   or accept it? Costs one more surface per window if we care.
2. ~~**`form_alert`: system-modal or app-modal?**~~ ✅ **Answered — app-modal, and not by
   choice (see "Dialogs are always windows" below).** A client can only draw into its own
   surface and hold its own grab; it has no way to touch another app's window, so
   *system*-modal is not expressible under the split. app-modal falls out of the
   architecture. GEM's promise changes, but nothing else could have honoured it anyway.
3. **The liveness constants.** 2 s to the busy cursor and 7 s to grab revocation (§9) are
   a guess. They should be tunable, and felt on real hardware.
4. ~~**Xtg: dirty rects, not a dirty flag.**~~ ✅ **DONE (§6).** `setNeedsDisplay(void)` is an
   overload that calls `setNeedsDisplayInRect(absoluteFrame())`; `XGViewTree.markDirty` unites
   the rects; `XGWindow.display` posts that union to `gemd` (`wind_redraw_area`) and clips
   `objc_draw` to it. One line changed repaints one line.

### Resolved: dialogs are always windows, and save-under retires

A dialog is a **gemd window**. Every dialog, always — `form_alert`, `form_do`, an Xtg
`XGDialog`, all of them. There is no second path where a dialog draws into its parent's
surface and saves the pixels underneath. The save-under machinery in `form.c` retires.

**The reason this is not a trade-off: it is free.** `form.c`'s save-under *already* allocates
a dialog-sized surface —

```c
gfx_surface *s = gfx_surface_alloc(t[0].ob_w, t[0].ob_h);   // sav_push
```

— so "draw-into-parent + save-under" and "open a transient window" cost the **same** one
surface. The window spends that surface on something `gemd` understands, and for the same
price it gets, for nothing:

- **dragging** — `gemd` runs window moves already (§11);
- **occlusion and recompositing** — `gemd` repaints what was underneath from the *real*
  surfaces, instead of `form.c` blitting back a saved rectangle and hoping;
- **correctness under a compositor** — save-under is what you do when you have one
  framebuffer and *no* window server. We have a window server. save-under is `form.c`
  reimplementing `gemd`, and by the same rule that says a client must not reimplement
  `libGEM` (§5, §6), `libGEM` must not reimplement `gemd`.

So this **deletes** code, it does not add it: the `g_sav[]` stack, `sav_blit`, `sav_push`,
`sav_pop_restore`, and the pixel-blitting half of `drag_dialog` all go.

**Classic apps never learn a window was involved.** An m68k program calls `form_do(tree,
start)` and expects it to just work. It does: `form_do_dialog` opens the window *internally*
— sized to `tree[0]`, runs the loop against its surface, closes it, returns the exit object.
The `form_*` signatures do not move (§5 holds); only what happens inside them does. This also
disposes of the handle-0 geometry question — a dialog window has its own real work area, so
nothing has to centre on the ambiguous `WF_WORKXYWH(0)`.

**Dialogs have no chrome, and drag by their background.** A dialog window is opened with **no
title bar, closer, or mover** — that is what makes it read as a dialog and not a document
window. It is still movable: **a drag that begins on any non-control area of the dialog moves
it.** The logic that decides "non-control area" already exists — `form.c`'s `want_move`, which
is true for the root, the empty background, and any inert object, and false for a button, an
edit field, or a radio. Nothing new to compute.

Who *runs* that drag is the interesting part, and it falls out of the grab (§0). A normal
window is dragged by its title bar, and **`gemd`** runs that move because `gemd` owns the
chrome and the client is not even involved. A modal dialog is the mirror image: the **client**
holds the grab, so the client sees every `BTN_DOWN`, and when one lands on a `want_move` area
the client runs the drag itself — moving its *own* window live via a position request per
frame (`wind_set(WF_CURRXYWH)`), the exact live-drag path `gemd` already runs for a scrollbar
thumb. So `drag_dialog` survives, but it stops blitting pixels and starts moving a window:
smaller, and correct. **Whoever holds the grab drives the drag** — chrome→`gemd`,
modal-dialog→client — and both are already-built mechanisms.

**Modality is app-modal, by construction** (item 2). The dialog window holds the grab, so
within its app nothing else is topped and all input comes to it; other apps keep running,
because a client cannot reach across to freeze them even if it wanted to.

*Owner: this is a `libGEM` `form.c` change (AES/`gemd` thread), and it is a net simplification
of their code. Xtg's `XGDialog` is then just a modal `XGWindow` — the same object a classic
dialog compiles down to, so the two worlds do not diverge.*

### Closed, and worth not reopening

- ~~Breaking a grab held by a wedged app~~ — it times out, on the liveness clock (§9).
- ~~Who owns the menu bar when the desktop is active~~ — the desktop is an app; when it is
  active, its menu is the menu (§4).
- ~~Resize racing the shm reallocation~~ — refcount the buffers (§11). No handshake, no
  round-trip.
- ~~`gemd` cannot wait on more than one source~~ — **it can.** XTOS has real signals with
  async delivery, and blocking syscalls unwind with `-EINTR`. `gemd` blocks on `sys_input`
  and a signal wakes it (§2). No `select` needed, no polling, no new syscall. *This was
  briefly filed as the one genuine blocker; it was never real.*

> **None of the open items can freeze the machine.** That property was won by §9's
> liveness clock and by §4's separation of `gemd` from the desktop, and it should be
> **defended**: any future addition that lets one client stall another is a regression,
> not a feature.
