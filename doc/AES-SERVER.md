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

## 5. The one genuine wrinkle: the menu bar

`menu_bar(tree)` hands the AES an `OBJECT` tree **in the client's address space**.
The server owns the global menu strip but cannot reach that tree. Options:

- **(a) The menu bar is a window the active app owns.** The server allocates the
  strip's shm surface, the client draws its menu tree into it with the same
  `objc_draw` it uses for everything else, and the server composites it. Consistent
  with §2, no new mechanism, and `menu_bar()` becomes "here is my bar, show it".
- (b) Serialise the menu tree to the server on `menu_bar()`. The server then owns
  drawing and hit-testing. Fewer round-trips on every click, but it needs a whole
  serialisation format for OBJECT trees + strings, and drops `G_USERDEF` menus.

**Recommend (a)** — it reuses the window path entirely, and the menu bar genuinely
*is* a window that happens to be pinned to the top strip and owned by whoever is
active. `MN_SELECTED` then flows back like any other event.

Same argument covers `menu_popup` and `form_alert`: both are client-side windows.

---

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
2. Backing-store drawing (§2) first, with a **single** client — provable before any
   multi-app work: run `aesdesk` as the server and one Xtg app as a client.
3. Input routing (§3).
4. The menu bar (§5).
5. Then, and only then, multiple concurrent apps.
