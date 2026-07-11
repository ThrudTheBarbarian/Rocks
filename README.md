# Rocks — Resource Object Creation Kit Suite

A GEM resource (`.rsc`) editor for macOS.

A native **AppKit / Objective-C** editor for GEM `OBJECT`-tree resources: a
drag-and-drop work area with alignment guides on the left, a property inspector
on the right, and a tree outline. It reads **standard `.rsc` files** made by
other editors (Interface, ORCS, WERCS, RCS, EmuTOS resources…) and writes
classic big-endian `.rsc`. Colour icons use the **P7 PAM** format the fpga-xt
GEM code loads (`img.c`).

## Build & run

```sh
make          # -> build/Rocks.app and build/rockscli
make run      # build and launch
make check    # export a real .rsc to C and diff it back, field by field
./build/Rocks.app/Contents/MacOS/Rocks --selftest [file.rsc]   # headless checks
```

Requires the Xcode command-line toolchain (clang). No Xcode project, no XIB — the
UI is built in code. The theme, the UI font and the `make check` sample come from
a sibling `fpga-xt/gem` checkout; override its location with `GEM_DIR=<path>`.

## Window

- **Palette (left):** drag a widget type onto the canvas to create it.
- **Canvas (centre):** WYSIWYG. Marquee/⇧-click multi-select, drag to move,
  8-handle resize, arrow-key nudge (⇧ = grid step). Live **alignment guides**
  snap to sibling edges/centres, the dialog centre, and the grid. Drop a widget
  inside a Box/IBox to re-parent it.
- **Outline (top-right):** the object hierarchy, synced to selection.
- **Inspector (bottom-right):** every `OBJECT` field (type, flags, state,
  x/y/w/h) plus type-specific payloads — string text, TEDINFO
  (text/template/valid/font/justify/colour), box colour word, and the icon
  (import `.pam`/`.png`/… for a colour `G_CICON`).

## Test drive

**View ▸ Test Drive (⌘R)** stops the canvas being an editor and makes it behave
like the AES, so you can find out whether a dialog actually *works* before
building anything: radio groups stay exclusive, check boxes latch, buttons
highlight while held, popups open their linked tree and copy the choice back, and
editable fields accept typing through their TEDINFO template and `te_pvalid`
mask (so a digits-only field rejects letters, and an upper-case mask folds what
you type). Tab cycles the fields, Return fires `OF_DEFAULT`, Esc fires
`OF_CANCEL`, and a banner names the object the form exited through — using the
same symbol the `.h` export emits, so what you read is what you write in code.

Clicking and typing really do mutate the objects, so Rocks snapshots the resource
on the way in and restores it on the way out: the document is untouched and the
undo stack never sees any of it.

The rules live in `GForm.*`, deliberately with no view attached, and are checked
headlessly — `--formtest` covers the semantics, `--clicktest <file.rsc>` drives a
real resource through the same hit-test → click path the canvas uses:

```sh
./build/Rocks.app/Contents/MacOS/Rocks --formtest
./build/Rocks.app/Contents/MacOS/Rocks --clicktest resource.rsc
```

## Source export

A resource is only useful if code can name the things in it. Rocks emits symbolic
names — one `#define` per tree and per object — so application code never hard-codes
an object index that shifts the moment you insert a widget.

Names come from the tree: a tree called `MAIN` holding an OK button gives
`#define MAIN 0` (the tree) and `#define MAIN_OK 3` (the object). An object's name
is taken from the **Name** field in the inspector if you set one, otherwise it is
derived from the object's text or label, otherwise from its type
(`MAIN_FIELD`). Clashes get an index suffix (`MAIN_OK_5`).

From the **File** menu — *Export C Source…* and *Export xtc Source…* — or headless:

```sh
rockscli app.gemproj -o build/app --emit h,c     # app.h + app.c
rockscli app.gemproj -o build/app --emit xt      # app.xt
rockscli legacy.rsc  -o out/legacy --emit h,c,rsc
rockscli --list app.rsc                          # trees, objects, symbols
```

- **`.h`** — the symbolic names, plus the AES structs (`OBJECT`, `TEDINFO`,
  `ICONBLK`, `CICON`). Define `ROCKS_AES_TYPES` to supply your own from `aes.h`.
- **`.c`** — the trees as static initialised data. C folds address constants, so
  every `ob_spec` is resolved at compile time and there is nothing to call at
  start-up. No `.rsc` file is needed at run time.
- **`.xt`** — the same for the [xtc](https://atari-xt.com/compiler/) language.
  xtc will not constant-fold a global whose type contains a pointer, so the tables
  are pure integers (`ob_spec` is the AES 32-bit LONG, which is what it is on a
  real Atari) and a generated `<stem>_fixup()` pokes the addresses in at start-up
  — the job `rsrc_load` does on real GEM. Call it once before handing a tree to
  the AES. Targets m68k and 6502.

`make check` exports a real `.rsc`, then walks the generated tree and the original
file in lockstep and diffs every field — geometry, links, box words, strings,
TEDINFO text/template/valid, ICONBLK bitplanes.

## Menus

- **File:** New, Open/Save native `.gemproj` (JSON), Import/Export GEM `.rsc`,
  Export C source (`.h`/`.c`) and xtc source (`.xt`).
- **Edit:** Undo/Redo, Cut/Copy/Paste, Duplicate, Delete, Select All.
- **Object:** align (6 ways), distribute H/V, bring to front / send to back.
- **View:** test drive, snap to grid, alignment guides, zoom.

## Widget types

Classic `G_BOX, G_IBOX, G_BOXTEXT, G_BOXCHAR, G_STRING, G_TEXT, G_FTEXT,
G_FBOXTEXT, G_TITLE, G_BUTTON, G_ICON, G_IMAGE` plus the fpga-xt/gem themed
extensions `G_CHECKBOX(40), G_RADIO(41), G_POPUP(42), G_FIELD(43),
G_CICON(44)`.

## The `.rsc` format

- **Read:** big-endian `RSHDR` + `OBJECT` + `TEDINFO` + `ICONBLK` + free strings +
  tree index, with a little-endian fallback for PC/GEM files. `char/pixel`-packed
  coordinates are unpacked to pixels (default cell 8×16). Mono `ICONBLK` bitplanes
  are preserved and rendered.
- **Extended (`vrsn & 4`, EmuTOS's `NEW_FORMAT_RSC`):** the appended CICON section
  is parsed — colour icons, their optional SELECTED forms, and the file's 256-colour
  palette. Note this bit does *not* lift the 64KB cap on the object/TEDINFO/string
  tables (every `RSHDR` offset is a 16-bit word); it only lets the icon data, reached
  through 32-bit offsets, live past it. **The source export has no such limit at all** —
  it emits resolved pointers, so nothing there is bounded by 64KB.
- **Colour icons.** A real Atari `G_CICON` (type **33**) is a `CICONBLK`: planar,
  palette-indexed, with a 1-bit mask — it cannot carry alpha or true colour. On import
  the deepest version is expanded to an **RGBA PAM**, so the whole editor (canvas,
  inspector, test drive, `.c`/`.xt` export) has one image path; the original block is
  kept verbatim so re-export stays byte-faithful. Rocks' own colour icon is a separate
  type (**44**, `G_PAMICON`) holding a straight RGBA PAM — strictly richer, and what
  fpga-xt uses.
- **Free strings** (`rsrc_gaddr(R_STRING, i)`) are read, kept, and exported as
  `#define STR_…` — real resources are full of them (EmuTOS's desktop has 64).
- **Lossy imports are never silent:** anything Rocks reads past but cannot preserve
  (BITBLKs, free images) is reported on import.
- **Write:** classic big-endian, coordinates re-packed so the same tools read it
  back. Extended widgets keep their type numbers; a `G_CICON` embeds its P7 PAM
  blob in the image-data section (`ob_spec` → the PAM). Standard files stay
  fully classic.

## Source layout (`src/`)

| file | role |
|------|------|
| `GModel.*`         | OBJECT tree model, payloads, flatten-to-classic |
| `GRsc.*`           | classic `.rsc` reader + writer |
| `GExport.*`        | source export: symbols + `.h` / `.c` / `.xt` emitters |
| `GForm.*`          | AES form behaviour (test drive): clicks, radios, validated text |
| `rockscli.m`       | headless resource compiler (`build/rockscli`) |
| `GImage.*`         | P7 PAM decode/encode, mono ICONBLK render |
| `GProject.*`       | `.gemproj` JSON (also used for undo snapshots) |
| `GRender.*`        | WYSIWYG OBJECT drawing |
| `CanvasView.*`     | drag/drop, selection, resize, snapping + guides |
| `PaletteView.*`    | widget palette (drag source) |
| `InspectorView.*`  | property inspector |
| `OutlineController.*` | tree outline |
| `Document.*`       | selection + undo + change notifications |
| `MainWindowController.*` | window, split layout, menu actions |

## Known limitations (v1)

- Menu-tree (`GK_MENU`) and `G_IMAGE`/BITBLK pixel editing are read-preserved but
  not yet authored in the UI.
- Imported coordinate cell height is assumed 8×16; resources designed at 8×8 will
  look tall until a per-document cell-size control is added (`rockscli --cell 8x8`
  sets it for an export).
- `G_CICON` is an fpga-xt extension; classic editors won't render it.
- A `.rsc` carries no tree names, so an imported one exports as `TREE0`, `TREE1`…
  until you rename the trees. Names live in the `.gemproj`.
- The `.xt` export targets m68k/6502. Build it with `-A 68030`, or `-A m68k`
  (plain 68000 only reaches ±32KB of PC-relative data, so a large resource needs
  `-mpic`). It cannot target arm64 yet: xtc's arm64 backend reports
  `sizeof(u8@) == 2` and mis-lays-out any struct with a pointer member, so a
  pointer-typed `OBJECT` faults there. The integer tables Rocks emits side-step
  that, but a 64-bit address will not fit in `ob_spec` until it is fixed.
