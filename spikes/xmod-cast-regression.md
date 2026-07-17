# Regression: checked downcast of a LIBRARY-created object returns NULL in the client

A cross-`.so` type-identity regression in the checked downcast (`@ ?`). It reproduces in
`~12` lines and is the root cause of `test_rocks` crashing after the XG repo split.

## Minimal repro (arm9)

`xmod-cast-vlib.xt` — an `--emit-lib` library that creates an object INSIDE itself:
```
#import <GEM>
#import "XGGem.xt"
#import "XGView.xt"
Object@ make_a_view(void) { return new XGView(); }   // created inside this .so
```
`xmod-cast-vcli.xt` — a client that imports the lib and casts the returned object:
```
#import <Stdio.xt>
#import <GEM>
#import <vlib>
void main(void) {
    Object@ o = make_a_view();          // a LIBRARY-created XGView
    XGView@ v = (XGView@ ?)o;            // checked downcast, IN THE CLIENT
    // -> v is NULL. The object IS an XGView; the cross-.so cast fails.
}
```
```
lib-made XGView, client cast (XGView@?) = NULL <-- BUG
```

## Why it matters

- It is a **regression** — `test_rocks` did exactly this (`(XGView@ ?)doc.viewAt(0)` on a
  library-created view from `XGNib.load` in `libXG.so`) and PASSED before today's churn.
- It **only** hits objects created *inside* a library and cast in a *client*. A client that
  creates the object itself (`new XGView()` in the client) casts fine — so the object's
  cross-module **type tag / RTTI identity** differs from the client's imported type.
- `nibdemo` passes because it imports the **sources** (`XGNib.xt`), so its objects are
  client-tagged. Rocks imports `<XG>` (the library), so `XGNib.load`'s objects are
  library-tagged → the client cast fails.
- This is on the **critical path for the multi-backend design**: the handle/driver model
  exchanges objects across the `.so` boundary and casts them. If cross-`.so` checked casts
  don't hold, that model doesn't work.

Suspect: the same-day Foundation change (Object gaining `<Hashable, Comparable>` altered
Object's layout / type identity), or the type-tag emission across `--emit-lib`. Clean bisect:
this cast worked before today.
