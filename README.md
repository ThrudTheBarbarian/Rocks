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
make          # -> build/Rocks.app
make run      # build and launch
./build/Rocks.app/Contents/MacOS/Rocks --selftest [file.rsc]   # headless checks
```

Requires the Xcode command-line toolchain (clang). No Xcode project, no XIB — the
UI is built in code.

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

## Menus

- **File:** New, Open/Save native `.gemproj` (JSON), Import/Export GEM `.rsc`.
- **Edit:** Undo/Redo, Cut/Copy/Paste, Duplicate, Delete, Select All.
- **Object:** align (6 ways), distribute H/V, bring to front / send to back.
- **View:** snap to grid, alignment guides, zoom.

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
- **Write:** classic big-endian, coordinates re-packed so the same tools read it
  back. Extended widgets keep their type numbers; a `G_CICON` embeds its P7 PAM
  blob in the image-data section (`ob_spec` → the PAM). Standard files stay
  fully classic.

## Source layout (`src/`)

| file | role |
|------|------|
| `GModel.*`         | OBJECT tree model, payloads, flatten-to-classic |
| `GRsc.*`           | classic `.rsc` reader + writer |
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
  look tall until a per-document cell-size control is added.
- `G_CICON` is an fpga-xt extension; classic editors won't render it.
