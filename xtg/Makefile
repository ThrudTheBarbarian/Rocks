# Xtg — an AppKit-style UI toolkit for the XT, in xtc, over libGEM.
#
# The build invocation was living only in my shell history, which is not a place a
# build lives.  Two things are needed and neither is obvious:
#
#   -I .          local #import "..." — xtc does NOT search the source file's own
#                 directory by default.
#   -L $(GEMLIB)  a LIBRARY path, not an include path.  `#import <GEM>` resolves
#                 libGEM.so and reads its .dynsym ∩ DWARF, which is what gives us
#                 `theme` at its true size (19502 bytes) and `OBJECT` laid out exactly
#                 as libGEM sees it, rather than by hand.  See spikes/RESULTS.md — a
#                 guessed sizeof(theme) smashed the heap.
#                 (-L is not in `xtc --help`.  It cost me an hour.)
#
# Targets:
#   make            build every demo/test .so for arm9
#   make host       run the HOST tests natively (no GEM, no gemd, no qemu)
#   make run-demo   run demo.so on the XTOS loader (BLOCKED: see TESTING.md)

XTC     ?= xtc
LOADER  ?= $(HOME)/src/fpga-xt/loader
GEMLIB  ?= $(LOADER)/build-xtg

ARCH    ?= arm9
XTCFLAGS = -A $(ARCH) -I . -L $(GEMLIB)

# The toolkit's own sources.  Not built standalone yet: xtc has no separate
# compilation, so a program #imports the sources it needs.  When libXtg.so becomes a
# real --emit-lib artefact, this list is what goes into it.
SRCS = XGLibc.xt XGGeometry.xt XGResponder.xt XGViewTree.xt XGView.xt XGControl.xt \
       XGWindow.xt XGApplication.xt XGEvent.xt XGGraphics.xt XGNib.xt \
       XGMenu.xt XGAlert.xt XGString.xt XGGem.xt XGGem.h.xt XGTableView.xt \
       XGOutlineView.xt

PROGS = demo.so nibdemo.so test_spine.so test_window.so test_scroll.so \
        test_dirty.so test_key.so test_menu.so test_alert.so test_clip.so \
        test_scale.so test_chrome.so test_table.so test_outline.so libdemo.so libtable.so

all: $(PROGS)

# ---- libXtg.so — the toolkit as a REAL shared library --------------------------
# `xtc --emit-lib` takes a single translation unit ("multi-file inputs not supported
# on the new-IR path yet"), and #import is include-once — so Xtg.xt is an umbrella
# that pulls in the ten sources, and that umbrella IS the library.
#
# A client then says `#import <Xtg>` and LINKS against it. It does not yet WORK.
#
# BLOCKED (spikes/XTC-BUGS.md §5): imported STRUCT types are a parse error in half the
# positions and a SILENT MISCOMPILE in the other half — a struct parameter lowers to
# u8. Which hits the one signature the whole toolkit turns on:
#
#     void drawRect(XGGraphics@ g, XGRect dirty)   <- compiles.  Miscompiled.
#
# The library passes an XGRect; the client's override reads a byte. So until that
# lands, programs #import the sources directly (the PROGS above) and libXtg.so is
# built only to keep the library path honest.
# The only verification available while gemd is mid-build and qemu will not boot.
# XGGeom and XGStr are pure logic and need neither, so they run natively.
host: test_host
	./test_host

test_host: test_host.xt XGGeometry.xt XGString.xt XGLibc.xt
	$(XTC) -A arm64 -I . $< -o $@

# ---- VERSIONING: major.minor.patch, and the ABI lives in the SYMBOL NAME ---------
#
# A client compiled against one libXtg.so and run against another does not fail politely:
# it jumps through a stale vtable offset and dies as PC=0, PREFETCH-ABORT, naming neither
# the library nor the mismatch. That cost us a debugging session, and in a tree where three
# threads rebuild each other's libraries it will happen again.
#
# VERSION is `major.minor.patch`, and the three parts mean different things:
#
#   major   a conceptual redesign. Different library, in effect.
#   minor   AN ABI BREAK — the layout moved. A client built against 1.2 CANNOT run on 1.3.
#   patch   compatible: additions and fixes. 1.2.5 satisfies a client that needs 1.2.4.
#
# So the two halves are enforced in two different places, because they need different rules:
#
#   major.minor -> THE SYMBOL NAME.   libXtg.so defines Xtg_abi_1_0; a client CALLS it. Bump
#                  the minor and that symbol ceases to exist, so the LOADER refuses the stale
#                  client, by name, before main() runs:
#
#                      xtld_load err: Xtg_abi_1_0 rc=undefined symbol
#
#                  It is exact-match by construction, which is what an ABI break means, and it
#                  cannot be outrun — a stale layout cannot crash us before a check that the
#                  loader performs.
#
#   patch       -> A RETURNED NUMBER.  Xtg_abi_1_0() returns the patch level, so a client can
#                  say "I need at least 1.0.4" and be happy with 1.0.7. An exact match here
#                  would be wrong: that is the whole difference between `patch` and `minor`.
#
# The generated files exist only because xtc has no `##` token-paste operator (see
# spikes/XTC-BUGS.md #16), so the symbol name cannot be built from the numbers in a macro.
# If ## lands, XGAbi.xt/XGAbiDef.xt collapse into a couple of lines of ordinary header.
XTG_VERSION := $(strip $(shell cat VERSION))
XTG_MAJOR   := $(word 1,$(subst ., ,$(XTG_VERSION)))
XTG_MINOR   := $(word 2,$(subst ., ,$(XTG_VERSION)))
XTG_PATCH   := $(word 3,$(subst ., ,$(XTG_VERSION)))
XTG_ABI     := $(XTG_MAJOR)_$(XTG_MINOR)

version: ; @echo "libXtg.so $(XTG_VERSION)  (abi symbol: Xtg_abi_$(XTG_ABI))"

# The library half: DEFINE the ABI symbol, and have it return the patch level.
XGAbiDef.xt: VERSION Makefile
	@printf '// GENERATED from VERSION. Do not edit.\n' > $@
	@printf '// The library half of the version gate: the symbol NAME carries major.minor (an ABI\n' >> $@
	@printf '// break renames it, so a stale client cannot link), and the RETURN VALUE is the patch\n' >> $@
	@printf '// level (so a newer patch still satisfies an older requirement). See the Makefile.\n' >> $@
	@printf 'i32 Xtg_abi_$(XTG_ABI)(void) { return (i32)$(XTG_PATCH); }\n' >> $@

# The client half: CALL it. The reference must survive dead-code elimination, so the result
# is consumed by the caller's branch — an unused call is optimised away and the gate silently
# vanishes, which is exactly what happened the first time I built this.
XGAbi.xt: VERSION Makefile
	@printf '// GENERATED from VERSION. Do not edit. Include this in any client of libXtg.so.\n' > $@
	@printf '//\n' >> $@
	@printf '//     if (!xtg_require((i32)4)) { ...refuse to run... }   // needs >= $(XTG_MAJOR).$(XTG_MINOR).4\n' >> $@
	@printf '//\n' >> $@
	@printf '// Calling this makes the client REFERENCE Xtg_abi_$(XTG_ABI). If libXtg.so has had an ABI\n' >> $@
	@printf '// break since, that symbol is gone and the loader rejects the client BY NAME, at load,\n' >> $@
	@printf '// rather than letting it die as PC=0 in a stale vtable.\n' >> $@
	@printf 'i32 gXtgPatch;\n' >> $@
	@printf 'bool xtg_require(i32 minPatch) {\n' >> $@
	@printf '    gXtgPatch = Xtg_abi_$(XTG_ABI)();      // the ABI reference the loader checks\n' >> $@
	@printf '    return gXtgPatch >= minPatch;          // consumed: survives dead-code elimination\n' >> $@
	@printf '}\n' >> $@

lib: libXtg.so

# BUILDING THE LIBRARY DEPLOYS IT.  The loader ships libXtg.so out of its romfs-overlay,
# so a build that stops at the .so leaves the IMAGE running the previous one — and the
# failure is a link error inside qemu (`xtld_load err: XGButton$$init rc=undefined symbol`)
# that points at the symbol, not at the stale file.  The copy used to live in one `run`
# target in ../xt/Makefile, so every other way of building got the old library.
#
# A library that is built but not deployed is a stale library.  These are one step.
LIBDEST = $(LOADER)/romfs-overlay/Library

libXtg.so: Xtg.xt $(SRCS) XGAbiDef.xt XGAbi.xt
	$(XTC) -A $(ARCH) --emit-lib -I . -L $(GEMLIB) Xtg.xt -o $@
	@mkdir -p $(LIBDEST)
	cp $@ $(LIBDEST)/

# libdemo is the ONE program that links Xtg as a real library instead of #importing the
# sources — it subclasses XGView across the .so boundary and lets the LIBRARY call its
# override back.  It needs `-L .` (where libXtg.so is), which the generic %.so rule below
# does not pass, so it gets its own rule.  It had none: it was being built from my shell
# history, which is exactly what the note at the top of this file complains about.
libtable.so: libtable.xt libXtg.so
	$(XTC) -A $(ARCH) -I . -L . -L $(GEMLIB) $< -o $@

libdemo.so: libdemo.xt libXtg.so
	$(XTC) -A $(ARCH) -I . -L . -L $(GEMLIB) $< -o $@

%.so: %.xt $(SRCS)
	$(XTC) $(XTCFLAGS) $< -o $@

run-demo:    demo.so    ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/demo.so
run-nibdemo: nibdemo.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/nibdemo.so
run-spine:   test_spine.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_spine.so
run-window:  test_window.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_window.so

clean: ; rm -f $(PROGS) libXtg.so test_host XGAbi.xt XGAbiDef.xt

.PHONY: all lib host clean version abi run-demo run-nibdemo run-spine run-window
