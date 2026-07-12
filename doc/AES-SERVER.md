# The AES as a server

**Problem.** `aes/window.c` keeps the window list in `static awin g_w[MAXW]`, and a
`.so`'s writable data is per-process (COW). So every process linking `libGEM.so`
gets its *own* window list, z-order, desktop background and VDI workstation. Today only
`aesdesk` calls `aes_init`, so nothing has noticed — but a second GEM app would get
a **private AES** drawing to the same framebuffer: two window managers, unshared
z-order, duelling menu bars.

**Decision.** One process owns the window system; apps talk to it. This is TOS's
actual model, and `appl_init → ap_id` / `appl_write` / `evnt_mesag` are already
shaped for it and currently unused.

Call that process **`gemd`**. It is **not** the desktop.

---

## 0. `gemd` is not the desktop

The obvious move is to make the desktop *be* the server — it is already the process
that calls `aes_init`, and TOS did exactly that. It is the wrong move.

**The arbiter must be boring.** If the desktop is the server, then every desktop
feature — file I/O, icon rendering, drag-and-drop, a file picker, a search field —
is code running inside the process that owns input routing and **the grab**. Every
desktop bug becomes a system freeze. Keep them apart and the process that arbitrates
between apps is small, does nothing risky, and has no reason to ever block.

So:

```
    gemd          the window server.  Windows, z-order, chrome, compositing,
                  input routing, grabs, lifecycle.  Small.  Boring.  Never blocks.

    desktop.so    an ORDINARY GEM CLIENT.  Wallpaper, icons, drag-and-drop, the
                  root menu bar.  Replaceable — swap in `desktop+` if you like.

    Rocks.so      an ordinary GEM client.  Indistinguishable, to gemd, from the
                  desktop.
```

Which means the **wallpaper is not `gemd`'s**. Wallpaper and icons are *content*, and
only an app knows its content (rule 2 — see `RESPONSIBILITIES.md`). The desktop is a
client owning a **bottom-most, screen-sized window**, drawing into a backing store
with `objc_draw` like everyone else. `gemd` keeps a fallback background **colour**,
for when no desktop is running or one is restarting, and nothing more.

And it needs **no new mechanism**. The desktop is simply the *first app launched*: it
calls `wind_create` with none of the chrome bits (no `W_NAME`, no `W_CLOSER`, no
`W_MOVER`) at screen size minus the strip. Being created first puts it at the bottom
of the z-order — nobody has to declare it the bottom, it just *is*.

**One bit is genuinely new — `W_BOTTOM`** — and it means *two* things:

```
    1. INSERT AT THE BOTTOM of the z-order — whenever the window is created.
    2. NEVER TOPPED by a click.
```

(2) is obvious: a screen-sized window that came forward when clicked would swallow every
other app. **(1) is the one that is easy to miss.** "The desktop is the first app
launched, so it is at the bottom for free" is true at boot and **false ever after** —
restart the desktop while apps are running (the very thing this design promises works,
and the path you take when something has *already* gone wrong) and its new window is
created *last*, landing on **top** of everything. Creation order is luck, not design.

`W_BOTTOM` lives beside `W_CLOSER` and `W_MOVER` in a mask that already exists. It names
a **z-order position**, deliberately, and not a role: `W_ROOT` would smuggle "what a
desktop is" into `gemd`, and `gemd` must not know.

One flag, and the desktop is an ordinary app. The dropdown needs nothing either — it
lives inside a grab and never enters the z-order at all (§5).

---

## 1. The split

| | `gemd` (the server) | Client (`libGEM.so`, linked by each app — **including the desktop**) |
|---|---|---|
| Window list, z-order, geometry | **owns** | asks |
| Window chrome (title, closer, mover, sliders) | **draws** | never touches |
| Compositing + `fb_present` | **owns** | never touches |
| Input (`sys_input`) | **owns**, routes | receives events |
| The grab (`BEG_MCTRL`) | **honours it** | requests it |
| Menu bar (global strip) | **reserves the region; owns one strip surface per app; composites the active one** | **paints its own**, once, into its own surface (see §5) |
| Background **colour** (fallback) | **owns** | — |
| **Wallpaper, icons, drag-and-drop** | — | **the desktop client**, in a root-level window |
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

Resize = `gemd` reallocates the shm and tells the client the new id.

---

## 3. Input

`gemd` owns `sys_input`. It already has the geometry and the z-order, so it does
the top-level hit-test (which window? chrome or work area?), handles chrome itself,
and posts everything else to the owning client.

The seam already exists:

```c
    // gem/aes/event.c
    void aes_set_events(aes_event_fn fn);   // the AES's input source is pluggable
```

In a client, that source reads the `gemd` pipe instead of `sys_input`. So
`evnt_multi` keeps working exactly as it does now — which means **Xtg's run loop does
not change at all**.

---

## 4. Transport

- **Control**: one pipe (or unix socket) per client — the message format is already
  defined (`msg[0] = type`, `msg[1] = sender ap_id`).
- **Pixels**: shm, never the pipe.
- **Lifecycle**: `gemd` reaps a client's windows on `SIGCHLD` / `waitpid`. A
  crashed app must not leave a ghost window.

`appl_init` becomes "connect and get my `ap_id`"; `appl_exit` disconnects.

---

## 5. The menu bar: no backing store, just a clear and a message

`menu_bar(tree)` hands the AES an `OBJECT` tree **in the client's address space**,
which `gemd` cannot reach. So the app must draw its own menu. The question is
only *where*, and *when*.

### It needs no surface of its own

A window needs a backing store (§2) because of **occlusion** — `gemd` must be
able to repaint a window it cannot see all of, without the owner's help.

**The strip is never occluded.** `g_top_reserve` keeps windows out of it, and menu
dropdowns hang *below* it. So there is no repaint `gemd` ever has to perform on
the app's behalf. The only thing that ever dirties the strip is an **ownership
change** — and an ownership change is already a message to the new owner. A backing
store would buy nothing.

```
    menu_bar(tree):                     (client, ONCE)
        objc_draw(tree, ...)            into MY OWN strip surface (see below)
        post damage

    WM_TOPPED, new window's owner != $currentApp:      (gemd)
        composite THAT app's strip surface.
        No clear.  No message.  No repaint.  No round-trip.
```

Ownership of the strip follows the top window — exactly TOS's rule — but it is **not an
event**: it is simply which buffer gets composited.

### What it draws into: a surface `gemd` gives it — NOT the framebuffer

A VDI workstation does not cross a process boundary. `v_opnvwk(&surface)` is entirely
client-side — the client builds a `gfx_surface` and opens a workstation on it locally. So
nothing "hands a workstation to an app": what must cross is **memory** and **geometry**.
Whose memory is then the whole question.

**Mapping the plane's top strip into the client is SAFE here — and we still do not do it.**
The strip is a contiguous prefix of the desktop plane (rows 0..strip_h-1), so `gemd` could
map exactly those bytes with the MMU as enforcement. And the stride is hardwired at **8192
bytes** (2048 words/row; 1920 visible, padded) — and 8192 is a multiple of the 4 KB page, so
`strip_h × 8192` is page-aligned for **any** strip height. No constraint, no partial page,
no leak into the row below. It is also cheaper: zero copies.

> An earlier draft rejected this on page-alignment grounds, computing from a stride of
> 7680 (= 1920 × 4). **The real stride is 8192 and that hazard does not exist.** Retracted —
> a fabricated constraint is worse than none.

**Decided: one strip surface PER APP, opened once.** Not a shared buffer loaned around.
`gemd` gives each app that calls `menu_bar()` its own strip-sized surface and composites
whichever app's is active.

```
    menu_bar(tree):     ONCE in the client's lifetime — map my surface, v_opnvwk it,
                        objc_draw my menu tree into it, post damage.
                        Redraw only when the MENU itself changes.

    app switch:         gemd composites a DIFFERENT BUFFER.
                        No remap.  No workstation.  No message.  No repaint.
```

**Why not one buffer, loaned to the active app?** "Loan" and "revoke" imply the memory can
move, and every arrangement of that is bad: *remap on switch* forces the client to rebuild
its surface and **re-open its workstation every time**; *keep it mapped in everyone* lets a
backgrounded app **write** to the active app's strip (ignoring its damage is not enough — it
would corrupt the pixels); *flip page protections on switch* keeps the address stable but
means an inactive app cannot draw, so it **must repaint on becoming active** — a round-trip
on every switch, and a blank strip whenever the app is slow.

192 KB per app (24 × 8192) instead of 192 KB total. Eight apps ≈ 1.5 MB — nothing — and it
buys four things:

1. **The workstation is opened once** and stays valid for the app's lifetime.
2. **No cross-app write hazard** — nobody shares a buffer.
3. **An app switch costs zero IPC.** It is a compositing decision, not a conversation.
4. **`gemd` holds every app's menu pixels**, so a **wedged app's menu bar still composites**.

(4) removes the residual this section used to carry, and two mechanisms with it: `gemd` no
longer clears the strip on an ownership change, and there is **no "tell the new owner to draw
its menu" step at all**. Ownership of the strip is not an event — it is just which buffer gets
composited.

> Safety is **not** among the reasons. Mapping the plane's top strip would be safe here (it is
> a contiguous prefix, and at an 8192-byte stride it is page-aligned at any height). This is
> about workstation stability, write isolation, and a wedged app still having a menu.

### The dropdown: a grab, and a scratch overlay

A click in the strip routes to the active app, which `objc_find`s its own menu tree
and drops the menu down over the windows below. That looks like it needs an
always-on-top window in the z-order, with rules for what happens if another window is
topped while the menu is down.

**It does not, because a menu grabs input.** You cannot top a window while a menu is
down — the first click *dismisses the menu*. The two are strictly serial, never
concurrent, so there is no interaction to design.

GEM already names the grab: **`wind_update(BEG_MCTRL)`**. Making it real server-side
is the whole fix, and it is also the fix for the only race here — an input event in
flight to another app while the menu is still down:

```
    while a grab is held:   gemd routes ALL input to the holder, and tops nothing.
    menu dismissed:         END_MCTRL.  Normal routing resumes.
```

This is not a menu special case: `form_do` and any modal dialog need exactly the same
thing.

### A grab times out. It has to.

A grab is the one thing a client holds that can hurt everyone else: a wedged app
holding `BEG_MCTRL` routes all input to a process that will never read it, and nothing
can be topped. So `gemd` must be able to take it back — **without the app's
cooperation, because a wedged app cooperates with nothing.**

**The clock measures the right thing.** Not "no user input for N seconds" — a modal
dialog sitting quietly while the user thinks is perfectly healthy, and looks identical
to a wedged one. The clock runs only when `gemd` **has input for the grab holder that
the holder has not taken**:

```
    gemd has queued input for the holder, still unread:
        + 2s    busy cursor.   gemd draws it (the cursor is gemd's — which is exactly
                               why this still works when the app is completely dead).
        + 7s    grab revoked.

    holder drains its pipe:    clock resets.  An idle modal never ticks at all.
```

The liveness signal is *"is this client draining its event pipe"*, which `gemd` can
observe without the client doing anything.

**Revoking injects a cancel; it does not just drop the flag.** Otherwise the app
un-wedges into a world where its menu is still logically down but input goes
elsewhere. Instead:

1. `gemd` discards the holder's overlay surface and **recomposites that rect from the
   window backing stores** — so the dropdown simply vanishes and the screen is clean.
   (This is §2 paying for itself again.)
2. `gemd` pushes a synthetic **cancel** into the app's queue — an `ESC`, or a
   dedicated `WM_GRABLOST`.
3. When the app comes back, it reads the cancel and runs **its own existing dismissal
   path**. No new code in the app, no new state to reason about.

**One guard against ping-pong:** an app that *lost* a grab may not take another until
the user has topped it again. Human intent is the gate.

### It is not really a grab feature — it is the liveness rule

"Events pending and unread for N seconds" detects **any** wedged app, grab or no grab.
So `gemd` shows the busy cursor over any wedged app's windows, and *losing the grab* is
simply the extra consequence when the wedged app happened to be holding one.

One clock, one signal, and the only case where a bad client could take the machine
down stops existing.

So the dropdown is a **scratch overlay**, not a window: it never enters the z-order,
never persists, and never interacts with topping, because its entire lifetime sits
inside a grab. It does not even need save-under — on dismiss `gemd` recomposites
that rect from the **window backing stores**, which is precisely what §2 bought.

`menu_popup` and `form_alert` are the same shape: grab, overlay, dismiss,
recomposite.

## 6. What Xtg has to change

**One method.**

```c
    XGApplication.boot()      // vdi_init, v_opnvwk, theme_load, aes_init, appl_init
    ->  XGApplication.attach()  // connect to gemd, get ap_id, get my surface
```

Nothing else. Views, the responder chain, the draw seam (`objc_set_userdraw`),
target/action, the run loop and the `.rsc` nib path are all identical, because Xtg
sits **on** the AES API rather than underneath it. The split is invisible to it.

That is worth saying plainly: the fact that this architectural change costs the
toolkit one method is evidence the layering is in the right place.

The boot path does not disappear — it becomes **`gemd`'s** privilege (not the
desktop's: the desktop is a client like any other, and calls `attach()` too). Whoever is
Whoever is the server calls `aes_init`; `gemd` is.

---

## 7. Suggested order

1. **Keep libGEM's API; split the implementation.** `aes/window.c` grows a
   client/server switch, chosen at `aes_init` (server) vs `appl_init` (client).
2. **Backing-store drawing** (§2) first, with a **single** client — provable before
   any multi-app work: run `gemd` as the server and one Xtg app as a client.
3. **Input routing** (§3). `aes_set_events` is already the seam.
4. **The input grab** (§5) — `wind_update(BEG_MCTRL)`, honoured by `gemd`. It is
   what makes menus, `menu_popup` and `form_alert` all safe, and it is the race fix.
5. **The menu bar** (§5) — a clear, a message, and a clipped workstation. No surface,
   and the dropdown is a scratch overlay recomposited from the backing stores.
6. Then, and only then, multiple concurrent apps.

Steps 2 and 3 are the whole architecture; 4-6 are consequences of it.
