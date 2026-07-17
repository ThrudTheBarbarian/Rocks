# Foundation regression: `Object <Comparable>` without `compare`

**Blocks all real library imports on arm9** (libXG/libdemo/libtable/Rocks) — and it
reproduces in the untouched tree, so it is NOT the XG repo move; it is the new
production-Foundation landing in `/opt/xtc`.

## Minimal repro (arm9)

`clib.xt` — a library that uses the new `Array`:
```
#import <Array.xt>
class Bag : Object {
    Array@ items;
    void init(void) { items = new Array(); }
    void add(Object@ o) { items.add(o); }
    u16  size(void) { return items.count(); }
}
```
`ccli.xt` — any client that imports it:
```
#import <Stdio.xt>
#import <clib>
void main(void) { Bag@ b = new Bag(); }
```
```
xtc -A arm9 --emit-lib -L <gemlib> clib.xt -o libclib.so     # ok
xtc -A arm9 -L . -L <gemlib> ccli.xt -o ccli.so
  <imported>:0:0: error: Class 'Object' claims conformance to protocol
                         'Comparable' but doesn't implement 'compare'
```

A trivial library (a class that does NOT touch `Array`) imports fine — so the trigger
is specifically **materializing `Comparable`'s conformance on import**, which any real
library does through `Array`.

## Root cause

`support/generic/lib/Object.xt:32`:
```
class Object <Hashable, Comparable>
```
`Object` implements `equals`/`hash` (Hashable) but **not `compare`** (Comparable).

## Fix (maintainer's principle: "anything declaring Comparable should implement compare")

Two directions, and the second is the more correct one:
1. Implement `compare` on `Object`.
2. **Drop `Comparable` from `Object`** — keep `Hashable`. Identity equality and a
   pointer hash are meaningful for an arbitrary object; **ordering** two arbitrary
   objects is not (there is no natural order of heap blocks). `Object` should be
   `Hashable`; only concrete value types (`Number`, `String`, …) are `Comparable`.

Compiler thread's call — `Object.xt` is their Foundation.
