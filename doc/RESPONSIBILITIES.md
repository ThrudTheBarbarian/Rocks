# Who does what

The contract between the layers: what each one **owns**, what it may **assume**, and
what it must **never** do. Companion to `AES-SERVER.md` (which argues *why* the split
is shaped this way) and `XTG-DESIGN.md` (which argues *why* a view is a GEM object).

This document is the one to read when you are about to write code and need to know
whose job something is.

---

## 0. The stack

```
    Rocks.so          desktop.so         (any other app)     <- ORDINARY CLIENTS.
    the app           the app that        the app             gemd cannot tell
                      draws wallpaper                         them apart.
                      and icons
      |                  |                   |
      +--------- libXtg.so (the framework) --+     views, responders, actions,
      |                  |                   |     the run loop, nibs
      +--------- libGEM.so (client half) ----+     objc_*, theme_*, form_*, v_*
                         |
        messages (control)  |  shm (pixels)
                         v
    +-----------------------------------------------------------+
    |  gemd                THE WINDOW SERVER. ONE process.       |   who arbitrates
    |                      windows, z-order, chrome, compositing |   between apps
    |                      input routing, grabs, lifecycle       |
    +-----------------------------------------------------------+
    |  libxtos.so / XTOS   processes, shm, input, framebuffer    |   the machine
    +-----------------------------------------------------------+
```

Two rules generate almost everything below:

> **1. Only `gemd` touches the screen.**
> **2. Only the app knows what its content looks like.**

Every responsibility falls out of holding both at once. Rule 1 alone gives you X11
(stream every primitive to the server). Rule 2 alone gives you classic GEM (everyone
scribbles on the framebuffer). Holding both *forces* the per-window backing store,
*forces* the menu bar to be painted by its owner, and *forces* the grab — none of
those were free choices.

**And note what is not in that list: the desktop.** It is a client, `desktop.so`,
sitting beside `Rocks.so`. See §3.

---

## 1. XTOS

**Owns.** Processes. The framebuffer (`sys_fb_info`, `sys_fb_wallpaper`). Shared
memory. The input device. The syscall ABI, exported as real symbols from
`libxtos.so` so that a non-C language can reach it.

**Promises.**
- A shm segment created by one process and mapped by another is the same memory.
- Input events arrive in order, and only to the process that asked for them.
- A dead process's shm mappings are reclaimed.

**Must never.** Care about windows. XTOS has no concept of a window, and should not
grow one — that is `gemd`'s entire job, and `gemd` is an ordinary process.

**Currently owed.** `libxtos.so` is built without `-g`, so it carries no DWARF and
xtc cannot type it (see `spikes/RESULTS.md`). Adding `-g` — as `libGEM` already does
— removes a hand-mirrored struct from every xtc program.

---

## 2. `gemd` — *the window server*

**One process.** It is the only process that calls `aes_init`, and the only process
that presents to the framebuffer.

**It is not the desktop.** That distinction is the subject of §3, and it is load-
bearing enough to be worth stating before the table: `gemd` is deliberately *small*.
It routes input, arbitrates z-order, composites, and does nothing else — because it
is the process that holds **the grab**, and a process that holds the grab must never
be able to block.

### It owns

| | |
|---|---|
| the window list, z-order, geometry | `awin g_w[MAXW]` lives here and nowhere else |
| window **chrome** | title bar, closer, mover, sizer, sliders — all themed |
| **compositing** and `fb_present` | it alone decides what pixel is on screen |
| a fallback background **colour** | *only* a colour — the wallpaper belongs to the desktop **client** (§3) |
| **input** (`sys_input`) | it does the top-level hit-test and routes |
| the **menu strip** | it reserves it (`g_top_reserve`) and clears it |
| the **grab** | it decides who is receiving input, and honours `BEG_MCTRL` |
| **lifecycle** | it reaps a dead client's windows |

### It promises

- **A window's pixels survive occlusion.** If a client has drawn its window and
  posted damage, the desktop can bring that window forward, move it, or reveal it
  from under another, *without asking the client anything*. This is the whole point of
  the per-window backing store, and every other promise leans on it.
- **Damage is honoured.** A client posts a rect; the desktop composites that rect in
  z-order and presents. It does not batch it into next week.
- **Input goes to exactly one place.** The window under the pointer, or the grab
  holder if there is one. Never both, never neither.
- **A grab is absolute.** While `BEG_MCTRL` is held, *all* input goes to the holder
  and **nothing is topped**. This is what makes menus, `menu_popup` and `form_alert`
  safe, and it is the only ordering guarantee they need.
- **The strip is cleared before it is handed over.** A new menu owner gets clean
  space; it never has to erase the previous app's menu.

### It must never

- **Draw an app's content.** It has the pixels; it does not have the meaning. It
  cannot repaint a window from scratch, only re-composite what the app last drew.
- **Parse an app's `OBJECT` tree.** Those pointers are in *another address space*.
  This is not a style rule, it is a hardware fact, and it is why the menu bar works
  the way it does (§5 of `AES-SERVER.md`).
- **Assume a client is alive, responsive, or well-behaved.** See §7.
- **Know what a file is.** No filesystem, no icons, no drag-and-drop semantics, no
  file picker. All of that is the desktop's, and the desktop is an app.
- **Block. Ever.** It holds the grab. See §3.

---

## 3. The desktop is an app

`desktop.so` is an **ordinary GEM client**. `gemd` cannot tell it apart from
`Rocks.so` except by a single flag on its window.

### Why this matters more than replaceability

You do get replaceability — swap in `desktop+` and nothing else changes. But that is
the smaller prize.

**The arbiter must be boring.** A desktop does file I/O, renders icons, runs
drag-and-drop, opens a file picker, maybe indexes a search field. If the desktop *is*
the server, all of that runs inside the process that owns input routing and the grab —
and **every desktop bug becomes a system freeze**. Keeping them apart means the
process that arbitrates between apps is small, does nothing risky, and has no reason
to ever block.

TOS made the other choice. TOS also froze a lot.

### The wallpaper is content

Rule 2 says only an app knows what its content looks like — and a wallpaper is
content. So the desktop draws its wallpaper and icons into its own backing store with
`objc_draw`, exactly like every other client. `gemd` keeps a fallback background
*colour* for when no desktop is running (or one is restarting), and nothing more.

### It needs no new mechanism — it is just the first app launched

There is no "root window", no window level, no special case in the compositor. The
desktop is started first and calls:

```c
    wind_create(0 /* no W_NAME, no W_CLOSER, no W_MOVER */,
                0, strip_h, screen_w, screen_h - strip_h);
```

- **No chrome**, because it passed none of the chrome bits. `wind_create`'s kind mask
  already says this.
- **Bottom of the z-order**, because it was created first, and new windows go on top.
  Nobody has to declare it the bottom; it just *is*.

**One bit is genuinely new: it must not be toppable.** A screen-sized window that
comes to the front when clicked would swallow every other app. That bit sits beside
`W_CLOSER` and `W_MOVER` in a mask that already exists — call it `W_BOTTOM`.

That is the entire cost. One flag, and the desktop is an ordinary app.

(The dropdown needs no level either: it lives inside a grab and never enters the
z-order at all — see `AES-SERVER.md` §5.)

### It follows that

- **The desktop's menu bar is not special.** It is the active app's menu bar, and the
  desktop is sometimes the active app. (This closes what was an open question.)
- **The desktop can crash and be restarted** without taking the window system with it.
  Apps keep running; the background goes to `gemd`'s fallback colour until it returns.
- **`gemd` starts first**, and launches the desktop. Not the other way round.

---

## 4. libGEM, in a client

The same library the desktop links, running on the other side of the wire. `appl_init`
puts it in client mode; `aes_init` puts it in server mode.

### It owns

- **The client's VDI.** `v_opnvwk` on the client's *own* surface. Every drawing
  primitive — `vr_recfl`, `v_gtext`, `vr_transfer_bits` — runs client-side, at full
  speed, against local memory.
- **`objc_*`.** The tree walk, hit-testing (`objc_find`), coordinate resolution
  (`objc_offset`), editing (`objc_edit`), the userdef callback
  (`objc_set_userdraw`). All of it is client-side; the server never sees a tree.
- **`theme_draw` and `form_*`.** The theme atlas is read-only art; both sides may
  load it, and there is no conflict.
- **Translation.** `wind_create`, `wind_open`, `wind_content`, `evnt_multi` keep their
  exact signatures. Only their *bodies* change from "touch `g_w[]`" to "send a
  message". **This is the entire reason the split is tractable**, and it must stay
  true: if an AES call ever grows a new parameter for the server's benefit, the
  layering has gone wrong.

### It promises the app

> **Nothing about the AES API changes.** An app written against single-process GEM
> compiles and runs against the server unmodified.

### It must never

- **Touch the framebuffer.** With exactly one deliberate exception — see §8.
- **Assume it owns the screen.** It does not know its window's position on screen,
  what is above it, or whether it is even visible. It draws into its buffer and posts
  damage. That is all.

---

## 5. Xtg — the framework

Xtg sits **on** the AES API, not underneath it. That is why the server split costs it
one method (`XGApplication.boot()` → `.attach()`) and nothing else.

### It owns

| | |
|---|---|
| **`XGView`** | a view **IS** a GEM object. It owns an *index* into an `OBJECT[]`, not a rectangle. |
| **`XGViewTree`** | the flat `OBJECT[]` plus a parallel array of views. `addChild`/`removeChild` wrap `objc_add`/`objc_delete`. |
| **the draw seam** | a view's `gemType()` returns `G_USERDEF`, so the **AES itself** calls `drawRect` during its own `objc_draw` traversal. |
| **`XGResponder`** | the chain, built without reflection: defaults forward to `nextResponder`, and a subclass consumes by not calling `super`. |
| **target/action** | a typed pair with a **weak** target. No selectors, no reflection. |
| **the run loop** | `evnt_multi`, and the coalescing of `setNeedsDisplay` into one `wind_redraw_win` per pass. |
| **nibs** | `XGNib.load` binds a view onto each object of a Rocks-authored `.rsc`. There is **no inflation step**. |

### It promises the app

- **`drawRect` is called by the AES**, with a `XGGraphics` already clipped and
  offset to the view's frame. The view draws in its own coordinates, starting at 0,0.
- **A stock widget needs no drawing code.** `XGButton` returns `G_BUTTON` and sets
  `ob_spec`; GEM themes it. `XGButton` contains **zero** drawing code, and that is the
  measure of whether the design is working.
- **`setNeedsDisplay` is cheap.** It sets a flag. The run loop coalesces.

### It must never

- **Draw outside `drawRect`.** Painting from a click handler paints to a surface the
  desktop may not composite, and to a clip rect that is not the view's.
- **Cache a screen coordinate.** Ask `absoluteFrame` (which asks `objc_offset`).
  A window can move without the app being told.
- **Re-implement what GEM already does.** If Xtg is drawing a button border, that is
  a bug in Xtg, not a feature.

---

## 6. The application

**Owns.** What its content looks like, what its controls mean, its documents, its
menus.

**May assume.** Everything in §5's promises. Additionally: that its window's backing
store persists, so it is **not** asked to redraw merely because it was occluded,
moved, or topped.

**Must.**
- Draw its content when asked (`WM_REDRAW`).
- Draw its menu bar when told it has become the active app.
- Return to `evnt_multi` promptly. Not a moral requirement — a functional one. See §7.

**Must never.** Assume it is the only app; assume it is visible; assume its menu is
showing.

---

## 7. The seams

Where two layers meet, exactly what crosses:

| seam | what crosses | direction |
|---|---|---|
| app ↔ Xtg | `drawRect`, `mouseDown`, target/action, delegate protocols | both — Xtg calls **down** into app overrides |
| Xtg ↔ libGEM | the AES API, verbatim | Xtg calls libGEM; libGEM calls back via `objc_set_userdraw` and `wind_content` |
| libGEM ↔ desktop | **control**: window ops, damage rects, input events, grabs. **pixels**: shm, never the pipe. | both |
| desktop ↔ XTOS | syscalls | one way |

**The two callbacks are the whole design.** `wind_content` gives the AES a function to
call when a window needs drawing; `objc_set_userdraw` gives it a function to call for
each `G_USERDEF` inside that draw. Xtg hangs its entire view system off those two
function pointers, and the `void*` on each is what carries the `XGWindow` across the
C boundary — xtc has no closures, so that `void*` is load-bearing.

---

## 8. When things go wrong

The interesting half of any contract.

| | what happens | whose job |
|---|---|---|
| **an app crashes** | `gemd` reaps its windows on `waitpid`. No ghost windows, no leaked shm. | `gemd` |
| **an app wedges** (never returns to `evnt_multi`) | its **windows still composite** — the backing store means `gemd` needs nothing from it. Its **menu bar goes blank** on the next switch, because the strip is cleared before the new owner draws. | desktop |
| **an app wedges while holding a grab** | this is the one that actually hurts: input is routed to a process that will never read it, and **nothing can be topped**. `gemd` must be able to break a grab. | **`gemd` — and this is not yet designed.** |
| **an app posts damage for a rect outside its window** | clamped. A client's damage rect is a *request*, not an instruction. | `gemd` |
| **an app never draws** | its window composites as whatever its buffer contains — i.e. blank. Correct. | — |
| **the desktop crashes** | nothing else stops. The background falls back to `gemd`'s colour; apps keep running and stay clickable. Restart it. | `gemd` |
| **`gemd` crashes** | everything is gone. Which is why it is small, boring, and does no file I/O. | — |

A wedged app looking wedged is **right**. The design should make an app's failure
visible in proportion to how badly it has failed, and no more: a wedged app should not
be able to freeze **`gemd`**. The desktop is just another app, and *it* may freeze
without taking anything else down — which is precisely the point of §3.

---

## 9. The deliberate exceptions

Every rule above has been kept clean except one, and it is written here so it is not
discovered by accident.

### The menu strip is server-owned pixels, painted by a client

The strip has no backing store (it is never occluded, so it needs none — see
`AES-SERVER.md` §5). The active app therefore paints it **directly**, via a second VDI
workstation on the framebuffer, clipped to the strip.

This is the *only* place a client touches the framebuffer, and it is precisely the
classic-GEM failure mode ("any app can scribble on the desktop") that the whole
backing-store design exists to prevent. It is contained by three rules:

1. The desktop hands out a strip workstation **only to the active app**.
2. It **revokes** it on switch.
3. The **clip rect is the enforcement** — not the app's good manners.

If we ever want the hole closed: **one** desktop-owned strip surface, *loaned* to
whoever is active (not one per app). ~190 KB total, no protocol change, and the
compositor then treats the strip like any other surface. It can wait.

---

## 10. Not yet decided

Honest list. These are the places where someone will have to make a call.

1. **Breaking a grab.** A wedged app holding `BEG_MCTRL` freezes input for everyone.
   A timeout? A hard escape key `gemd` always keeps for itself? Nothing yet. This is
   the **only** case where one bad app can take the machine down, and §3 exists partly
   to make sure that app is never `gemd` itself.
2. ~~Who owns the menu bar when the desktop is active~~ — **closed by §3.** The
   desktop is an app; when it is active, its menu is the menu.
3. **Resize.** The desktop reallocates the shm and tells the client the new id —
   but the client may be mid-draw into the old one. Needs a generation number, or a
   handshake.
4. **Whether `form_alert` is really system-modal or app-modal.** GEM says system.
   With multiple apps, system-modal means one app can hold the machine hostage with a
   dialog. Probably app-modal, which is a *semantic* change to a GEM call — the first
   one we would be making, so it deserves an argument.
