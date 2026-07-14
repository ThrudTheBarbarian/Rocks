# Rocks.app — the resource editor, on the XT.
#
# An APPLICATION: it #imports <Xtg> and LINKS libXtg.so.  It does not compile the
# toolkit in.  That is the whole proof — a real app against a real shared library.
XTC    ?= xtc
LOADER ?= $(HOME)/src/fpga-xt/loader
GEMLIB ?= $(LOADER)/build
XTG    ?= ../xtg
ARCH   ?= arm9

all: Rocks.app test_rocks.app

Rocks.app: Rocks.xt RocksApp.xt $(XTG)/libXtg.so
	$(XTC) -A $(ARCH) -I . -I $(XTG) -L $(XTG) -L $(GEMLIB) Rocks.xt -o $@

test_rocks.app: test_rocks.xt RocksApp.xt $(XTG)/libXtg.so
	$(XTC) -A $(ARCH) -I . -I $(XTG) -L $(XTG) -L $(GEMLIB) test_rocks.xt -o $@

$(XTG)/libXtg.so:
	$(MAKE) -C $(XTG) lib

run: Rocks.app
	cp $(XTG)/libXtg.so $(LOADER)/romfs-overlay/Library/
	$(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/Rocks.app

clean: ; rm -f Rocks.app test_rocks.app
.PHONY: all run clean
