# XG nibs — the `.rsc` extension, the loader, and the compiler contract

A `.rsc` already *is* the view layout (an OBJECT tree the AES walks). To make it a real nib —
typed non-view objects, outlets, and target/action wiring — we append **one extension chunk** to
the same file. There is never a second file to keep in sync: the classic image is the runtime
layout, the extension is the graph, and both are the truth Rocks reads back and edits. The
runtime binds the graph generically using a small amount of **compiler-emitted reflection**,
turned on by two annotations (`outlet:`, `:action`) that name real members the compiler already
checks.

This document is three contracts: the **file format** (Rocks writes / the loader reads), the
**loader** (`XGNib`), and the **compiler ask** (what xtc emits from the annotations). The last
section is the one to review before it goes to the compiler.

---

## 1. Where the extension lives

The classic resource occupies `[0, rsh_rssize)` (the `RSHDR` total-size word). A classic AES
reads its arrays by header offsets and never looks past `rsh_rssize`, so anything after it is
invisible to a plain loader — that is our chunk. It is self-delimiting so Rocks and `XGNib` can
find it and a stripper can remove it:

```
offset rsh_rssize:
  magic     u32   'XGNB'  (0x5847_4E42)
  version   u16   = 1
  flags     u16   bit0 = STRIPPED (editing tail removed by `rocks -lipo`)
  size      u32   total bytes of this chunk (so the reader can bound it)
```

All multi-byte fields are **big-endian**, matching the `.rsc` body. `size` lets the loader accept
the chunk without trusting EOF, and lets a future version append more.

## 2. The chunk body

Four sections, in order, each a count + fixed-size records, then a shared string blob, then an
optional editing tail:

```
nClasses   u16      view-class overrides (custom G_USERDEF views)
nObjects   u16      top-level non-view objects
nConns     u16      connections
_pad       u16

classOverrides[nClasses]:   { view:Ref, className:u32 }      // str offset
topObjects[nObjects]:       { id:u16, className:u32 }         // id is local to this nib
connections[nConns]:        { kind:u8, _pad:u8, src:Ref, dst:Ref, member:u32 }

stringBlob:  NUL-terminated UTF-8 (class names, member names). offset 0 = "" (empty).

[editing tail]:  opaque to the runtime — Rocks' lossless state (names, canvas metadata,
                 undo is NOT persisted). Present unless flags.STRIPPED. `-lipo` drops it.
```

A **Ref** (6 bytes) names either a view or an object:

```
Ref { space:u8, a:u16, b:u16, _pad:u8 }
  space 0  view        a = tree index, b = object index within that tree
  space 1  top-level   a = id (into topObjects), b = 0
  space 2  File's Owner (the caller-provided owner)              a=b=0
  space 3  First Responder (reserved; not yet bound)             a=b=0
```

**Connection kinds** (both records carry `src`, `dst`, `member`; the member always belongs to the
side named below):

```
kind 0  OUTLET   member is a field on SRC.  Effect: src.<member> = dst
kind 1  ACTION   member is a method on DST.  Effect: src(a control).setAction(&dst.<member>)
```

Notes:
- **`classOverrides`** is how a custom view gets its subclass. A `G_USERDEF` at `(tree,obj)` whose
  entry says `"WaveformView"` is instantiated as that class instead of a bare `XGView`. Stock
  widgets (`G_BUTTON`, `G_CHECKBOX`, …) need no entry — their type already picks the class. This
  replaces the earlier "class byte in `ob_type`" idea; the class lives with the graph, not the
  layout, so the `.rsc` body stays plain classic GEM.
- **`topObjects`** are the controllers/formatters the designer dropped that aren't views. They are
  *instantiated by the loader*. File's Owner is **not** in this list — it is passed to `load`.
- Retention: every top-level object should be reachable from an outlet (a strong field) so its
  owner keeps it alive; `load` also returns the vector of top-level objects so an owner with no
  outlet to one can still retain it.

## 3. The loader

```
class XGNib {
    // Load tree `treeIndex`, bound to `owner` as File's Owner.  If the file has no XGNB chunk,
    // this degrades to today's behaviour (type -> view, no wiring).
    static XGViewTree@ load(u8@ path, i32 treeIndex, Object@ owner);
    static Array@      topObjects(void);     // the non-view objects it instantiated (retention)
}
```

Flow:
1. `rscload_file`; find the `XGNB` chunk (§1). No chunk → plain load, return.
2. Adopt tree `treeIndex`'s `OBJECT[]` into an `XGViewTree`.
3. **Instantiate views**: per object, if `classOverrides` names it → `xgNibNew(className)` +
   `adoptObject`; else the stock `viewForType(ob_type)` (which grows the arms it's missing today —
   `G_CHECKBOX -> XGCheckbox`, etc.).
4. **Instantiate top-level objects**: per `topObjects` → `xgNibNew(className)`, into an `id ->`
   `Object@` map. Bind `space 2` to `owner`.
5. **Wire connections**, resolving each `Ref`:
   - OUTLET: `(XGNibReflectable@ ?)resolve(src)).nibSetValue(member, resolve(dst))`
   - ACTION: `((XGControl@ ?)resolve(src)).setAction( (XGAction^)(resolve(dst) as reflectable).nibAction(member) )`
6. Optional `owner.awakeFromNib(vt)` hook after wiring.
7. Return the tree.

Everything name-driven in steps 3–5 goes through the compiler-emitted reflection below; the loader
itself contains no per-app knowledge.

---

## 4. The compiler contract  ← review this

Two annotations, adopting xtc's existing shapes (a field *qualifier* like `weak:`, a method
*annotation* on the definition line):

```
class SignupController : Object :nib          // class annotation: nib may construct + reflect it
{
    weak: outlet: XGTextField@ nameField;     // an outlet (qualifier; composes with weak:)
    outlet:       XGCheckbox@  subscribe;

    void submit(XGControl@ sender) :action {  // an action target (annotation)
        ...
    }
}
```

- **`outlet:`** — a field qualifier. The field is a nib-settable outlet; its declared type is the
  binding type. Composes with `weak:` (outlets are frequently weak).
- **`:action`** — a method annotation. The method is a nib action target. Constraint: `void` return,
  exactly one object parameter (the sender). (Different toolkit senders — `XGControl@`,
  `XGMenuItem@` — are ABI-identical, one pointer; see the erasure note below.)
- **`:nib`** — a class annotation: the loader may construct this class by name and reflect it.
  Classes that are only ever File's Owner (app-constructed) still get reflected because they carry
  `outlet:`/`:action`; `:nib` additionally allows *nib construction*. Every wired class carries it.

### What xtc emits

**(a) A design-time manifest** — the reflectable surface, machine-readable, emitted beside the
`.so` (a sidecar text/JSON, or a named section — your call). Per `:nib` class: its name, its
outlets `(name, declared-type)`, its actions `(name, sender-type)`. Rocks reads this to populate
the connection palette and to *validate every wire at save time* (an outlet typed `XGButton@`
cannot be dropped on a label; an action name must exist). This is where a renamed member is caught
in the Rocks/build step, replacing the app-compile error the generated-code approach would have
given.

**(b) Runtime binding hooks** — so the generic loader binds by name against a live `Object@`. The
cleanest shape is a compiler-known protocol that xtc **auto-conforms** `:nib` classes to, filling
the bodies from the annotations:

```
typedef pointer XGBoundMethod;            // erased (receiver, code); cast to the concrete action^
protocol XGNibReflectable {
    bool          nibSetValue(u8@ outlet, Object@ value);   // checked-cast assign; false if unknown/mismatch
    XGBoundMethod nibAction(u8@ name);                      // the :action method bound to self, or 0
}
```

Generated `nibSetValue` is a switch over the `outlet:` fields doing a **checked** assignment
(`field = (DeclaredType@ ?)value`), returning false on an unknown name or a failed cast — so a
type-wrong wire that slipped past Rocks is a soft failure, not a smash. Generated `nibAction` is a
switch over the `:action` methods returning `&self.method` erased to `XGBoundMethod`. Plus one
global:

```
Object@ xgNibNew(u8@ className);          // construct a :nib class by name; 0 if unknown
```

### The two decisions I need from you

1. **`XGBoundMethod` representation.** All toolkit action types are `void(SomeObject@)^` — one
   pointer sender, ABI-uniform — so a bound `:action` method erases to the same `(receiver, code)`
   pair regardless of declared sender type. I've written it as an opaque `pointer` the loader casts
   to `XGAction^`/`XGMenuAction^`. If xtc's bound-method value is already a first-class movable
   type, expose *that* as the return instead and we skip the cast. Either works; I need to know
   which so `setAction` on the loader side is written correctly.
2. **Auto-conformance vs declared.** I'd prefer xtc auto-conform a class to `XGNibReflectable`
   the moment it sees `outlet:`/`:action` (no boilerplate in app code). If you'd rather the
   developer write `: Object <XGNibReflectable>` and xtc only *fills the bodies*, that's fine too —
   say which and I'll match the loader.

Nothing here is dynamic reflection: every name in `nibSetValue`/`nibAction`/`xgNibNew` resolves to
a member the compiler validated at its declaration, so a typo is a compile error at the source, and
a stale *wire* is caught by Rocks against manifest (a). It's the minimum metadata that lets one
generic loader replace a per-app generated wiring file — which is what keeps everything in the one
`.rsc`.

---

## 5. `rocks -lipo`

The command-line Rocks writes the full chunk (including the editing tail) when saving a project.
`rocks -lipo in.rsc out.rsc` re-emits with `flags.STRIPPED` set and the editing tail dropped —
`classOverrides` / `topObjects` / `connections` / strings stay (the runtime needs them), only
Rocks' own lossless state goes. Optional: the loader never reads the tail, so shipping the fat file
only costs disk. It exists so a ROM build can be tight, not because the runtime cares.
