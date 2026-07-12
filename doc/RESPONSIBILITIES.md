# Who does what

The contract between the layers of the XT graphics stack: what each one **owns**, what
it may **assume**, and what it must **never** do.

Read this when you are about to write code and need to know whose job something is.

Companions: `AES-SERVER.md` argues *why* the client/server split is shaped this way;
`XTG-DESIGN.md` argues *why* a UI view is a GEM object. This document assumes neither —
it states the conclusions and the obligations.

---

## 0. Terms

Written for three audiences (the OS thread, the compiler thread, and the UI thread), so
nothing below assumes you know the GEM vocabulary.

| | |
|---|---|
| **XTOS** | the operating system. FreeRTOS on a Zynq-7020 (Cortex-A9). Processes, shared memory, the framebuffer, the input device. Knows nothing about windows. |
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

## 2. XTOS

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

### ⚠ Verified ABSENT — the backing store is **not** buildable today

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

#### Three hard caps, and all of them had to fall before window #4

| | cap | bites |
|---|---|---|
| `SHM_MAXPG` | **1 MB per surface** | every window — a 640×400 is already 1.02 MiB |
| `NSHM` + no unmap | **16 surfaces, *ever*** (ids are never reclaimed — below) | after 16 window *opens*, for the whole uptime of `gemd` |
| `MAXSEC = 12` | **~2–3 windows** of VA per space | **`gemd` first** — it maps *every* surface |

#### Why `MAXSEC` cannot simply be raised

`NSPACE = 64`, and one L2 table is 1 KB:

```
    MAXSEC = 12  ->    768 KB static      <- what dynamic L2 recovers
    MAXSEC = 32  ->  2,048 KB  (+1.3 MB)
    MAXSEC = 64  ->  4,096 KB  (+3.3 MB)
```

**The cost is paid ×64 — by every space — while the need is concentrated in one process.**
`gemd` alone may want 30+ sections; the other 63 spaces want a handful. A static array is the
wrong shape for a distribution that skewed, and **no value of `MAXSEC` is both cheap and
sufficient.** Dynamic L2 charges each space what it actually uses, and `gemd` is the only one
that grows.

That is why dynamic L2 is a **prerequisite**, not an optimisation.

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

### How `gemd` waits: signals, not polling

`gemd` must watch **three** things at once — `sys_input`, **N client pipes**, and **client
deaths**. XTOS has no `select`/`poll`/`epoll`, so this looks at first like it forces a poll
loop, with the poll interval becoming latency on every damage rect.

**It does not**, because XTOS has real signals *and* `-EINTR`:

- **Real signals.** Kernel-authoritative disposition table, `rt_sigaction` /
  `rt_sigprocmask` / `sigreturn`, and **async delivery** — the handler is vectored at the
  next return-to-PL0, which is a **syscall-return *or a timer-tick***. So even a fully
  blocked process gets one.
- **Blocking syscalls unwind with `-EINTR`.** From the kernel:
  *"a deliverable signal is pending → a blocking syscall should unwind with `-EINTR` (-4) so
  the kernel can vector the handler on the deferred return."* (`SA_RESTART` is honoured too.)

Which gives the loop for free, with no new syscall and no polling:

```
    gemd:      blocks INDEFINITELY on sys_input.   No timeout.  No poll.  No spin.

    a client:  writes its damage rect to its pipe, then signals gemd.
    gemd:      sys_input returns -EINTR -> drain the client pipes (non-blocking) -> composite.

    a client dies:   SIGCHLD -> the same -EINTR wake -> sys_waitpid_nb reaps it.
```

**Zero polling. Zero added latency on a damage rect.** And it satisfies §3's rule that `gemd`
must never block *on a client* — blocking on `sys_input` is fine, because a signal always
gets it out.

> **Recorded because it was nearly a fabricated blocker.** An earlier draft of this document
> claimed XTOS had no signal delivery and therefore no `SIGCHLD`, and filed "`gemd` cannot
> wait on more than one source" as *the* open blocker. Both were wrong. The claim came from
> running `nm -D libxtos.so` — which lists only the **syscall shims**, not the kernel's
> capabilities — and from reading `vitis/xtos`, which is a **dead tree**. The live kernel is
> `loader/kernel` + `loader/test/freertos`. Two lessons: *absence of a symbol is not absence
> of a feature*, and *check which tree is live before concluding anything from it*.

---

## 3. `gemd` — the window server

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

## 4. The desktop is an app

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

## 5. `libGEM.so`, in a client

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

## 6. Xtg — the toolkit

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

### ⚠ Known gap: `setNeedsDisplay` has no rect

Today `setNeedsDisplay()` raises a **single global boolean**, and the run loop responds by
redrawing the **whole window**. For a button changing state that is invisible. For a text
editor inserting one character it is exactly backwards: it redraws every view and damages
the entire window for one line.

This is a defect in **Xtg**, not in the architecture — the AES's `objc_draw` already takes
a clip rect, so the mechanism is there and Xtg simply is not using it. The fix is to
accumulate a **union of dirty rects** per window and pass it both to `objc_draw` (as the
clip) and to `gemd` (as the damage rect). Tracked in §15.

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

## 9. When things go wrong

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

## 10. The menu strip: a surface per app, not a hole in the framebuffer

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

## 11. Buffer lifetime: refcount, do not handshake

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

## 12. Surface memory: capacity, extent, and resize

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

## 13. The blitter: how pixels actually get drawn

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

## 14. Staging: what lands when

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

### 🔴 What phase 1 must get right, even though it does nothing there

**The damage message carries a retire-sequence number.** From day one.

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

### What phase 1 deliberately does *not* do

No `plv` pressure, no contiguity requirement, no cache-maintenance discipline, no
`/dev/blitter`, no FIFO fairness, no fence. Every one of those is a phase-2 concern, and phase
1 is better for not pretending otherwise.

---

## 15. Not yet decided

The honest list. Someone will have to make a call on each.

1. **Tearing.** Refcounting (§11) gives a buffer's lifetime, not exclusive access — a
   client may paint frame N+1 while `gemd` composites frame N. Per-window double-buffer,
   or accept it? Costs one more surface per window if we care.
2. **`form_alert`: system-modal or app-modal?** GEM says *system*. With multiple apps,
   system-modal means one app can hold the whole machine hostage behind a dialog. It
   probably has to become **app-modal** — which would be the first *semantic* change to a
   GEM call rather than an implementation one, so it deserves an argument rather than a
   quiet decision.
3. **The liveness constants.** 2 s to the busy cursor and 7 s to grab revocation (§9) are
   a guess. They should be tunable, and felt on real hardware.
4. **Xtg: dirty rects, not a dirty flag.** `setNeedsDisplay()` currently repaints the whole
   window (§6). It must accumulate a union of dirty rects and pass it to `objc_draw` as the
   clip and to `gemd` as the damage. Purely an Xtg change; no protocol impact. Needed
   before any real text editing is usable.

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
