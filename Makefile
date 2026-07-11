# Rocks — a GEM Resource Construction Set for macOS (AppKit / Objective-C).
#
#   make        build Rocks.app
#   make run    build and launch
#   make clean

APP      := Rocks
BUNDLE   := build/$(APP).app
BIN      := $(BUNDLE)/Contents/MacOS/$(APP)
SRCS     := $(wildcard src/*.m)
CSRCS    := $(wildcard src/*.c)
OBJS     := $(patsubst src/%.m,build/obj/%.o,$(SRCS)) \
            $(patsubst src/%.c,build/obj/%.o,$(CSRCS))

CC       := clang
CFLAGS   := -x objective-c -fobjc-arc -Wall -Wno-deprecated-declarations \
            -mmacosx-version-min=13.0 -O0 -g
CONLY    := -std=c11 -Wall -O0 -g
LDFLAGS  := -framework Cocoa -framework AppKit -framework Foundation \
            -framework CoreText -framework CoreGraphics

THEME_SRC := ../fpga-xt/gem/themes
FONT_SRC  := ../fpga-xt/gem/fonts
.PHONY: all run clean
all: $(BIN) $(BUNDLE)/Contents/Info.plist theme fonts

# Bundle the Aristo2 theme into the app so it renders self-contained.
theme:
	@if [ -d "$(THEME_SRC)/Aristo2" ]; then \
		rm -rf "$(BUNDLE)/Contents/Resources/themes/Aristo2"; \
		mkdir -p "$(BUNDLE)/Contents/Resources/themes"; \
		cp -R "$(THEME_SRC)/Aristo2" "$(BUNDLE)/Contents/Resources/themes/"; \
	fi

# Bundle the XTOS UI font.
fonts:
	@if [ -f "$(FONT_SRC)/AovelSansRounded.ttf" ]; then \
		mkdir -p "$(BUNDLE)/Contents/Resources/fonts"; \
		cp "$(FONT_SRC)/AovelSansRounded.ttf" "$(BUNDLE)/Contents/Resources/fonts/"; \
	fi

build/obj/%.o: src/%.m | build/obj
	$(CC) $(CFLAGS) -c $< -o $@

build/obj/%.o: src/%.c | build/obj
	$(CC) $(CONLY) -c $< -o $@

$(BIN): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

$(BUNDLE)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp Info.plist $@

build/obj:
	@mkdir -p build/obj

run: all
	@echo "launching $(BUNDLE)"
	@open $(BUNDLE)

clean:
	rm -rf build
