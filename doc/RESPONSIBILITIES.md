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

**Must never.** Care about windows. XTOS has no concept of a window and should not grow
one — that is `gemd`'s entire job, and `gemd` is an ordinary user process with no
privileges XTOS knows about.

**Settled.** `libxtos.so` is now built with `-g`, so xtc can read its DWARF and type it
directly instead of hand-mirroring structs. (Why that matters: a hand-guessed
`sizeof(theme)` once smashed the heap — the real answer is 19502 bytes. See
`spikes/RESULTS.md`.)

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
| **compositing** and `fb_present` | it alone decides what pixel is on screen |
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
  primitive — `vr_recfl`, `v_gtext`, `vr_transfer_bits` — runs client-side, at full
  speed, against local memory. **Zero IPC while drawing.**
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
clip) and to `gemd` (as the damage rect). Tracked in §12.

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
| **an app crashes** | `gemd` reaps its windows on `waitpid`. No ghost windows, no leaked shm. | `gemd` |
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

**What it does not fix, and does not pretend to: tearing.** A client can be painting frame
N+1 into a buffer `gemd` is compositing frame N from. Refcounting is *lifetime*, not
*exclusion*. That is a separate decision — §12.

---

## 12. Not yet decided

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

> **None of the open items can freeze the machine.** That property was won by §9's
> liveness clock and by §4's separation of `gemd` from the desktop, and it should be
> **defended**: any future addition that lets one client stall another is a regression,
> not a feature.
