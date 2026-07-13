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
#   make run-demo   run demo.so on the real XTOS loader under qemu
#   make host       build the host-arm64 tests (no GEM, no loader)

XTC     ?= xtc
LOADER  ?= $(HOME)/src/fpga-xt/loader
GEMLIB  ?= $(LOADER)/build

ARCH    ?= arm9
XTCFLAGS = -A $(ARCH) -I . -L $(GEMLIB)

# The toolkit's own sources.  Not built standalone yet: xtc has no separate
# compilation, so a program #imports the sources it needs.  When libXtg.so becomes a
# real --emit-lib artefact, this list is what goes into it.
SRCS = XGGeometry.xt XGResponder.xt XGViewTree.xt XGView.xt XGControl.xt \
       XGWindow.xt XGApplication.xt XGEvent.xt XGGraphics.xt XGNib.xt \
       XGGem.xt XGGem.h.xt

PROGS = demo.so nibdemo.so test_spine.so test_window.so

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
lib: libXtg.so
libXtg.so: Xtg.xt $(SRCS)
	$(XTC) -A $(ARCH) --emit-lib -I . -L $(GEMLIB) Xtg.xt -o $@

%.so: %.xt $(SRCS)
	$(XTC) $(XTCFLAGS) $< -o $@

run-demo:    demo.so    ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/demo.so
run-nibdemo: nibdemo.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/nibdemo.so
run-spine:   test_spine.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_spine.so
run-window:  test_window.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_window.so

clean: ; rm -f $(PROGS) libXtg.so

.PHONY: all lib clean run-demo run-nibdemo run-spine run-window
