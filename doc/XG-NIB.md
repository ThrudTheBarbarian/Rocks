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
5. **Wire connections**, resolving each `Ref` (both go through the `UIDesignable` protocol §4):
   - OUTLET: `((UIDesignable@ ?)resolve(src)).setOutlet(member, resolve(dst))`  — `src.member = dst`
   - ACTION: `((UIDesignable@ ?)resolve(dst)).wireAction(member, (XGControl@ ?)resolve(src))`  — the
     target (`dst`) binds its named method to the source control's action
6. Optional `owner.awakeFromNib(vt)` hook after wiring.
7. Return the tree.

Everything name-driven in steps 3–5 goes through the compiler-emitted reflection below; the loader
itself contains no per-app knowledge.

---

## 4. The compiler contract  ← settled with the compiler author, 2026-07-19

Two decorations, in xtc's existing shapes — a field *qualifier* and a method *annotation*:

```
class SignupController : Object                 // <UIDesignable> is auto-applied (see below)
{
    weak outlet XGTextField@ nameField;         // qualifiers, colon-free; compose in any order
    outlet      XGCheckbox@  subscribe;

    void submit(XGControl@ sender) :action {     // an action target
        ...
    }
}
```

- **`outlet`** — a field qualifier, exactly like `weak`. Compiler change (in flight): it becomes a
  qualifier, and multiple qualifiers no longer need the trailing `:` (which got hard to scan past
  one). Both `weak outlet Object@ p;` and `weak:outlet:Object@ p;` are accepted.
- **`:action`** — a method annotation, as written. `void` return, one object parameter (the sender).
- **No class annotation.** xtc has no class annotations yet, and doesn't need one here: a class that
  declares any `outlet`/`action` member **auto-conforms to the `UIDesignable` protocol** (below) —
  the compiler adds the conformance and fills the bodies. `: Object <UIDesignable>` written by hand
  is equivalent; the auto-apply is just so app code carries no boilerplate.

### `UIDesignable` — the runtime binding protocol

The generic loader binds by name against a live `Object@` cast to this protocol. The compiler
generates both bodies from the decorations:

```
protocol UIDesignable {
    // Assign a named `outlet` field with a CHECKED cast.  false = unknown name or type mismatch,
    // so a bad wire is a soft no-op, never a smash.
    bool setOutlet(u8@ name, Object@ value);
    // Bind the named `:action` method to a control's action, IN this method.  false = unknown name.
    bool wireAction(u8@ name, XGControl@ control);
}
```

Generated `setOutlet` is a switch over the outlets: `field = (DeclaredType@ ?)value; return field
!= 0 || value == 0;`. Generated `wireAction` is a switch over the actions: `control.setAction(&self
.method); return true;`. Plus one generated global for construction:

```
Object@ xgNibNew(u8@ className);          // construct a UIDesignable class by name; 0 if unknown
```

**Why `wireAction` binds instead of returning the bound method.** I tried the obvious
`actionNamed(name) -> Act^` and an `Act^@` out-param (your "bound methods are first-class"). Result,
verified on arm64: a bound method works perfectly **as a local value** — `Act^ a = &self.onOK;
a(sender)` runs with the receiver captured — but a `T^` **return type doesn't parse**
(`Unexpected token 'void'`), and a `T^@` **reference out-param compiles then SIGBUSes** (the fat
`(receiver, code)` value doesn't round-trip through the reference). So the working shape is to keep
the bound method a local: `wireAction` creates `&self.onOK` and hands it straight to
`control.setAction(...)` inside the method — no return, no reference. If you later make `T^`
returns parse, `actionNamed -> Act^` becomes a cleaner option, but `wireAction` needs nothing new
and is arguably tidier (the designable object wires *itself*).

### The design-time manifest — a DWARF section, not a companion file

Rocks needs the reflectable surface (which classes are designable, their outlets `(name, type)`,
their actions `(name, sender-type)`) to offer connections and validate every wire at save time — an
outlet typed `XGButton@` can't be dropped on a label; a renamed method drops the wire on the next
save. Per your call, this rides in a **custom DWARF section in the `.so`** (no sidecar), so the
library stays one self-describing file — the same DWARF Rocks already parses for types. A wire that
references a member the current `.so` no longer has is caught in the Rocks/build step (which the
command-line Rocks runs), the data-driven equivalent of the compile error we'd have got from
generated code.

**Net asks to the compiler**, smallest first (all settled with the compiler author 2026-07-19):
1. `outlet` as a qualifier + colon-free multi-qualifier syntax. *(in flight)*
2. A **redeclaration guard**: register an imported protocol in the client's type scope so a local
   `protocol UIDesignable {…}` is refused ("redeclares imported protocol; import it instead") —
   makes the single-declaration/slot-consistency rule (#1) hold by construction.
3. Auto-conform any class with `outlet`/`action` members to `UIDesignable`, generating `setOutlet`
   / `wireAction` and a per-module `xgNibNew` factory from the decorations.
4. Auto-register each module's factory via a per-module `.init_array` entry calling
   `XGNib.registerObjectFactory(&xgNibNew)` — app-invisible. **LANDED across all five live backends
   (xtc #657), no per-app code on any of them.** The XTOS loader runs `.init_array` deps-first before
   entry (`xtld_run_init`), so arm9 needs no loader work; arm64/x86_64 use `__mod_init_func` /
   `.init_array` under dyld; win64 rides the per-program mingw runtime stub's
   `__attribute__((constructor))` (a hand-emitted PE `.CRT$XCU` ctor gets dead-stripped by that
   linker, so the stub's constructor lands it in the `_initterm` range instead). The earlier win64
   "register manually" caveat is therefore gone. (Explicit `registerObjectFactory` remains only as a
   fallback the loader still supports.)
5. Emit the design-time manifest into a named DWARF section.
6. **#9 — an `Object@` ↔ protocol bridge** (runtime downcast `(P@ ?)Object@` + `P@`→`Object@`
   upcast). **LANDED (2026-07-20).** The two factories collapsed to one `xgNibNew(name) -> Object@`
   and the v1 restrictions lifted (see below). Implemented cross-module via a per-class
   conformed-protocol-id table in the vtable (the #621-style side table).  ·  (Still optional: `T^`
   return types, which would make an `actionNamed` shape available instead of `wireAction`.)

**Implemented (2026-07-19)** — the runtime side is done and proven end to end (`test_nib.xt`): the
RSC engine writes/reads the XGNB chunk, `rscload_nib_*` exposes it, and `XGNib.loadWired` /
`loadWiredMem` build a wired tree through `UIDesignable` + the registered factories. Hand-written
conformance/factory stand-ins fill in for the compiler-generated bits.

**#9 landed → the v1 restrictions are lifted (2026-07-20).** With the `Object@`↔protocol bridge in
`xtc`, the loader holds every instantiated object as `Object@` and downcasts `(UIDesignable@ ?)` on
the designable side of each wire, `(XGView@ ?)` for a view — so the two typed factories collapsed to
one `xgNibNew(name) -> Object@` per module (`XGNib.make`), and **any** object can play **any** role:
a designable *view* as an outlet owner or action target, and a top-level object as an outlet *value*,
both work. `test_nib` proves the full set on arm9 (qemu), cross-module (a client `Gauge : XGView
<UIDesignable>` downcast to the library protocol inside libXG): `outlet-view`, `outlet-toplevel`,
`owner-action`, and `view-action` all fire. Nothing in the wiring is restricted now.

Nothing here is dynamic reflection: every name resolves to a member the compiler validated at its
declaration, so a typo is a compile error, and a stale *wire* is caught by Rocks against the DWARF
manifest. It's the minimum metadata that lets one generic loader replace a per-app generated wiring
file — which is what keeps everything in the one `.rsc`.

---

> **[compiler] 2026-07-19 — asks (1a)(1b)(2-frontend)(3) landed; (2) synthesis planned.** Pushed
> (`~/bin`), `make test` 0 failures each. Detail in `fpga-xtc/docs/Design/xg-nib-compiler.md`.
> - **(1a)** `outlet` qualifier + colon-optional multi-qualifiers — `weak outlet XGTextField@`,
>   `banked outlet Foo@`, classic `weak:outlet:Foo@`, any order. `outlet` flags the field.
>   `weak`/`outlet` still usable as ordinary variable names (disambiguated by "a type must follow").
> - **(1b)** slot-consistency guard: a client that re-declares an imported protocol is refused
>   ("import it instead"), so itable slots can't drift. Verified 2-module.
> - **(2, front-end)** `:action` recognised on methods (no more "unknown annotation").
> - **(3)** the manifest ships: each class's `outlet` fields `{name,type}` and `:action` methods
>   `{name,sender}` ride under a `designable` flag in the `__XTC,__iface` section you already parse.
>   Verified: a designable `.dylib`'s `__iface` carries the outlets/actions. Only designable classes
>   carry the extra keys, so other libraries' interfaces are byte-unchanged.
> - **(2, runtime)** the setOutlet/wireAction/xgNibNew synthesis + mod-init auto-registration is its
>   own next pass — it needs the real `UIDesignable`/`XGControl`/`XGNib` to exercise the cross-module
>   itable path (stubs would test the wrong thing). Plan + body shapes in the doc above; the settled
>   decisions (slot adoption, per-module factory + registration list, at-module-init — confirmed
>   against your `.init_array` loader) are baked in. I'll pick it up when the XG side is ready to link.

---

## 5. `rocks -lipo`

The command-line Rocks writes the full chunk (including the editing tail) when saving a project.
`rocks -lipo in.rsc out.rsc` re-emits with `flags.STRIPPED` set and the editing tail dropped —
`classOverrides` / `topObjects` / `connections` / strings stay (the runtime needs them), only
Rocks' own lossless state goes. Optional: the loader never reads the tail, so shipping the fat file
only costs disk. It exists so a ROM build can be tight, not because the runtime cares.
