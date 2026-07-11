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
| Menu bar (global strip) | **owns the strip** | supplies the content (see §5) |
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

## 5. The menu bar: it is just another window

`menu_bar(tree)` hands the AES an `OBJECT` tree **in the client's address space**,
which the server cannot reach. But once the strip is shm, that stops being a
problem — the app draws its own menu, exactly as it draws its own windows.

**Give each app its own strip-sized surface.**

```
    menu_bar(tree):                         (client, ONCE)
        surface = my strip buffer           (1920 x ~25, from the server)
        objc_draw(tree, ...)                (the same call as any other content)
        wind_damage(strip, ...)

    WM_TOPPED to another app:               (server)
        composite THAT app's strip buffer.  No wipe.  No message.  No round-trip.
```

So the menu bar is literally a window — pinned to the top strip, owned by the app,
shown only while that app is active. It needs **no new mechanism**: the server
already reserves the strip (`g_top_reserve`), and an app redraws it only when its
menu actually changes (an item is checked, disabled, retitled) — the same rule as
any other window.

**Why not "wipe the strip and ask the new app to draw it" on switch.** That is the
obvious design, and it costs an IPC round-trip plus a repaint on *every* app switch:
wipe → message → the app maps and draws → damage → composite. If the app is busy or
blocked, the user watches a **blank menu bar** for the duration. Window switching is
the most latency-visible thing a WM does. With a per-app buffer the switch is one
blit of something already drawn.

Memory is the only cost — 1920 × 25 × 4 ≈ **190 KB per app**, so five apps is under a
megabyte. If that ever bites, the server can evict an inactive strip and fall back to
ask-on-switch: the round-trip design is the graceful-degradation mode, not the wrong
one.

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
5. **The menu bar** (§5), which by then is just a window.
6. Then, and only then, multiple concurrent apps.

Steps 2 and 3 are the whole architecture; 4-6 are consequences of it.
