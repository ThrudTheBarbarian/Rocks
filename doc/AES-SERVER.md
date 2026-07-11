# The AES as a server

**Problem.** `aes/window.c` keeps the window list in `static awin g_w[MAXW]`, and a
`.so`'s writable data is per-process (COW). So every process linking `libGEM.so`
gets its *own* window list, z-order, desktop and VDI workstation. Today only
`aesdesk` calls `aes_init`, so nothing has noticed — but a second GEM app would get
a **private AES** drawing to the same framebuffer: two window managers, unshared
z-order, duelling menu bars.

**Decision.** One process owns the window system; apps talk to it. This is TOS's
actual model, and `appl_init → ap_id` / `appl_write` / `evnt_mesag` are already
shaped for it and currently unused.

---

## 1. The split

| | Server (the desktop process) | Client (`libGEM.so`, linked by each app) |
|---|---|---|
| Window list, z-order, geometry | **owns** | asks |
| Window chrome (title, closer, mover, sliders) | **draws** | never touches |
| Compositing + `fb_present` | **owns** | never touches |
| Input (`sys_input`) | **owns**, routes | receives events |
| Menu bar (global strip) | **owns and clears the strip** | **paints it** while active (see §5) |
| Desktop background / wallpaper | **owns** | — |
| VDI (`v_bar`, `v_gtext`, `vr_transfer_bits`…) | for chrome | **for its own content** |
| `objc_draw` / `theme_draw` / `form_do` / `form_alert` | — | **client-side, unchanged** |
| Theme atlas | loads it (chrome) | loads it (content) — read-only art, no conflict |

**The app-facing API does not change.** `wind_create`, `wind_open`, `wind_content`,
`evnt_multi`, `objc_draw` keep their signatures; only their *implementations* move
from "touch `g_w[]`" to "send a message". That is the whole reason this is tractable.

---

## 2. Drawing: a backing store per window

The one real design choice. Three options:

- **(a) Per-window shm surface, server composites.** Client draws into its own
  buffer with the full VDI — **zero IPC while drawing** — then posts a damage rect.
- (b) Client streams VDI commands to the server (X11-style). A protocol entry per
  VDI call, chatty, and every new VDI primitive becomes a protocol change. No.
- (c) Client draws straight into the shared framebuffer under a global
  `wind_update()` lock (classic GEM). Simple, but any client can paint over any
  other, and there is no way to redraw an occluded window without asking its owner.

**Take (a).** It costs one `shm_create` per window and nothing per primitive:

```
    server: id = sys_shm_create(w * h * 4);  attach it to the window
    client: px = sys_shm_map(id);
            gfx_surface s = { w, h, stride, px };
            vh = v_opnvwk(&s);          // a VDI workstation on MY buffer
            objc_draw(tree, ...);       // the whole existing draw path, unchanged
            wind_damage(handle, x,y,w,h);   // one message
    server: composite that rect from the window's buffer, in z-order, then present
```

Everything Xtg and every GEM app already does — `objc_draw`, `theme_draw`,
`objc_set_userdraw`, `form_do` — runs **client-side and untouched**. The client never
learns it is not drawing to the screen.

Resize = the server reallocates the shm and tells the client the new id.

---

## 3. Input

The server owns `sys_input`. It already has the geometry and the z-order, so it does
the top-level hit-test (which window? chrome or work area?), handles chrome itself,
and posts everything else to the owning client.

The seam already exists:

```c
    // gem/aes/event.c
    void aes_set_events(aes_event_fn fn);   // the AES's input source is pluggable
```

In a client, that source reads the server pipe instead of `sys_input`. So
`evnt_multi` keeps working exactly as it does now — which means **Xtg's run loop does
not change at all**.

---

## 4. Transport

- **Control**: one pipe (or unix socket) per client — the message format is already
  defined (`msg[0] = type`, `msg[1] = sender ap_id`).
- **Pixels**: shm, never the pipe.
- **Lifecycle**: the server reaps a client's windows on `SIGCHLD` / `waitpid`. A
  crashed app must not leave a ghost window.

`appl_init` becomes "connect and get my `ap_id`"; `appl_exit` disconnects.

---

## 5. The menu bar: no backing store, just a clear and a message

`menu_bar(tree)` hands the AES an `OBJECT` tree **in the client's address space**,
which the server cannot reach. So the app must draw its own menu. The question is
only *where*, and *when*.

### It needs no surface of its own

A window needs a backing store (§2) because of **occlusion** — the server must be
able to repaint a window it cannot see all of, without the owner's help.

**The strip is never occluded.** `g_top_reserve` keeps windows out of it, and menu
dropdowns hang *below* it. So there is no repaint the server ever has to perform on
the app's behalf. The only thing that ever dirties the strip is an **ownership
change** — and an ownership change is already a message to the new owner. A backing
store would buy nothing.

```
    menu_bar(tree):                     (client)  remember the tree; if I am active, draw it

    WM_TOPPED, new window's owner != $currentApp:      (server)
        clear the strip                 (clean space — the AES owns the strip, it can)
        send the new owner "draw your menu bar, here is the rect"
                                        (client)
        objc_draw(myMenuTree, ...)      clipped to the strip.  The same call as ever.
```

So the menu bar is not a window and not a surface: it is a **region the server clears
and the active app paints**. Ownership follows the top window, which is exactly TOS's
rule.

### What it costs: one exception, and it must be written down

The client now draws into **server-owned pixels**. It needs a second VDI workstation
— on the framebuffer, clipped to the strip. That is the *single* place a client
touches the framebuffer, and it is precisely the classic-GEM failure mode that §2
option (c) was rejected to avoid (an app scribbling on the desktop).

It is containable: **the server hands out a strip workstation only to the active app
and revokes it on switch, and the clip rect is the enforcement.**

If we ever want the exception closed, there is a cheap upgrade that needs no protocol
change: **one** server-owned strip surface, *loaned* to whoever is active — not one
per app. ~190 KB total, and the compositor then treats the strip like any other
surface. Worth knowing about; not worth paying for now.

### The residual: a wedged app shows a blank menu bar

Because the strip is cleared before the new owner has drawn, an app that is wedged or
blocked shows an empty menu bar. **That is correct.** With backing stores a wedged
app's *windows* still composite fine, so the menu is the one place its wedged-ness
shows — and it should show. If it ever grates, defer the clear until the new owner's
paint lands.

### The dropdown needs one new primitive

A click in the strip routes to the active app, which `objc_find`s its own menu tree.
But **the dropdown is bigger than the strip** — it falls over other windows. So it
cannot live in the strip buffer.

It needs a **client-owned, server-composited, always-on-top transient window**. Which
is precisely what `menu_popup` needs, and what `form_alert` needs. One primitive,
three cases:

| | is a transient top window |
|---|---|
| a menu dropdown | ✔ |
| `menu_popup` | ✔ |
| `form_alert` / modal dialog | ✔ |

Get that right and all three fall out of it. It is the only thing besides the
per-window backing store (§2) that the compositor genuinely has to understand.

## 6. What Xtg has to change

**One method.**

```c
    XGApplication.boot()      // vdi_init, v_opnvwk, theme_load, aes_init, appl_init
    ->  XGApplication.attach()  // connect to the server, get ap_id, get my surface
```

Nothing else. Views, the responder chain, the draw seam (`objc_set_userdraw`),
target/action, the run loop and the `.rsc` nib path are all identical, because Xtg
sits **on** the AES API rather than underneath it. The split is invisible to it.

That is worth saying plainly: the fact that this architectural change costs the
toolkit one method is evidence the layering is in the right place.

The boot path does not disappear — it becomes the *desktop's* privilege. Whoever is
the server still calls `aes_init`.

---

## 7. Suggested order

1. **Keep libGEM's API; split the implementation.** `aes/window.c` grows a
   client/server switch, chosen at `aes_init` (server) vs `appl_init` (client).
2. **Backing-store drawing** (§2) first, with a **single** client — provable before
   any multi-app work: run `aesdesk` as the server and one Xtg app as a client.
3. **Input routing** (§3). `aes_set_events` is already the seam.
4. **The transient top window** (§5) — one primitive, and it buys the menu dropdown,
   `menu_popup` and `form_alert` together.
5. **The menu bar** (§5) — a clear, a message, and a clipped workstation. No surface.
6. Then, and only then, multiple concurrent apps.

Steps 2 and 3 are the whole architecture; 4-6 are consequences of it.
