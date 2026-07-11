// main.m — NSApplication bootstrap (AppKit, no XIB/storyboard).

#import <AppKit/AppKit.h>
#import "AppDelegate.h"
#import "GModel.h"
#import "GRsc.h"
#import "GProject.h"
#import "GTheme.h"
#import "GImage.h"
#import "GRender.h"
#import "GForm.h"

// Headless checks: Rocks --selftest [file.rsc]
static int selftest(int argc, const char *argv[]) {
    // 1. build a small dialog, write .rsc, read back, compare object counts
    GResource *r = [GResource emptyDialog];
    GObject *root = r.trees[0].root;
    [root.children addObject:[GObject objectOfType:GT_STRING frame:NSMakeRect(16,10,120,16)]];
    GObject *btn = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(200,150,72,24)];
    btn.flags = OF_SELECTABLE|OF_EXIT|OF_DEFAULT; btn.text = @"OK";
    [root.children addObject:btn];
    GObject *fld = [GObject objectOfType:GT_FIELD frame:NSMakeRect(16,40,180,20)];
    fld.ted.tmplt = @"Name: ____________"; fld.ted.text = @"Simon";
    [root.children addObject:fld];
    GObject *pop = [GObject objectOfType:GT_POPUP frame:NSMakeRect(16,70,140,20)];
    pop.text = @"Choose…"; pop.extType = 3;    // popup linked to tree 3
    [root.children addObject:pop];
    int before = (int)r.trees[0].allObjects.count;

    NSString *err = nil;
    NSData *bin = GRscWrite(r, &err);
    printf("write: %lu bytes, err=%s\n", (unsigned long)bin.length, err.UTF8String ?: "none");
    GResource *r2 = GRscRead(bin, &err);
    int after = r2 ? (int)r2.trees[0].allObjects.count : -1;
    printf("roundtrip objects: before=%d after=%d %s\n", before, after,
           (before == after) ? "OK" : "MISMATCH");
    if (r2) {
        GObject *b2 = r2.trees[0].root.children[1];
        printf("button text='%s' flags=0x%x  x=%d y=%d w=%d h=%d\n",
               b2.text.UTF8String, b2.flags, b2.x, b2.y, b2.w, b2.h);
        GObject *f2 = r2.trees[0].root.children[2];
        printf("field tmpl='%s' text='%s'\n", f2.ted.tmplt.UTF8String, f2.ted.text.UTF8String);
        GObject *p2 = r2.trees[0].root.children[3];
        printf("popup text='%s' extType(tree link)=%d %s\n", p2.text.UTF8String, p2.extType,
               p2.extType == 3 ? "OK" : "MISMATCH");
    }

    // 2. if a path is given, read that real .rsc and dump its trees
    if (argc > 2) {
        NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        NSString *e2 = nil;
        GResource *rr = d ? GRscRead(d, &e2) : nil;
        if (!rr) { printf("read %s: FAILED (%s)\n", argv[2], e2.UTF8String ?: "?"); return 1; }
        printf("read %s: %lu trees, endian=%s\n", argv[2],
               (unsigned long)rr.trees.count, rr.bigEndian ? "big" : "little");
        int ti = 0;
        for (GTree *t in rr.trees) {
            GObject *r = t.root;
            NSString *k0 = r.children.count ? GObTypeName(r.children[0].type) : @"-";
            printf("  tree %d '%s': %lu objects, root %s %dx%d, child0=%s\n",
                   ti++, t.name.UTF8String, (unsigned long)t.allObjects.count,
                   GObTypeName(r.type).UTF8String, r.w, r.h, k0.UTF8String);
        }
    }
    return (before == after) ? 0 : 1;
}

// Rocks --formtest: exercise the AES form rules (GForm) with no window.
// These are the semantics test-drive mode relies on and they are easy to get
// subtly wrong, so they are checked rather than eyeballed.
static int gFails = 0, gChecks = 0;
static void ck(BOOL cond, const char *what) {
    gChecks++;
    if (!cond) { gFails++; printf("  FAIL %s\n", what); }
}

static int formtest(void) {
    // a dialog: two radios, a check box, a validated field, OK (default) + Cancel
    GResource *r = [GResource emptyDialog];
    GTree *t = r.trees[0];
    GObject *root = t.root;

    GObject *r1 = [GObject objectOfType:GT_RADIO frame:NSMakeRect(10, 10, 80, 20)];
    GObject *r2 = [GObject objectOfType:GT_RADIO frame:NSMakeRect(10, 34, 80, 20)];
    GObject *cb = [GObject objectOfType:GT_CHECKBOX frame:NSMakeRect(10, 58, 80, 20)];
    r1.flags |= OF_SELECTABLE | OF_RBUTTON;
    r2.flags |= OF_SELECTABLE | OF_RBUTTON;
    cb.flags |= OF_SELECTABLE;
    r1.state |= OS_SELECTED;                       // r1 starts on

    GObject *fld = [GObject objectOfType:GT_FIELD frame:NSMakeRect(10, 90, 160, 20)];
    fld.flags |= OF_EDITABLE;
    fld.ted.tmplt = @"____";                        // 4 slots
    fld.ted.valid = @"9999";                        // digits only
    fld.ted.text  = @"";

    GObject *ok  = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(200, 150, 60, 24)];
    GObject *can = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(130, 150, 60, 24)];
    ok.flags  |= OF_SELECTABLE | OF_EXIT | OF_DEFAULT;  ok.text = @"OK";
    can.flags |= OF_SELECTABLE | OF_EXIT | OF_CANCEL;   can.text = @"Cancel";
    GObject *dis = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(60, 150, 60, 24)];
    dis.flags |= OF_SELECTABLE | OF_EXIT;  dis.state |= OS_DISABLED;  dis.text = @"Nope";

    for (GObject *o in @[r1, r2, cb, fld, ok, can, dis]) [root.children addObject:o];

    // ---- radio exclusivity -------------------------------------------------
    [GForm released:r2 inTree:t];
    ck((r2.state & OS_SELECTED) != 0, "clicking a radio selects it");
    ck((r1.state & OS_SELECTED) == 0, "its peer is deselected");
    [GForm released:r2 inTree:t];
    ck((r2.state & OS_SELECTED) != 0, "a radio does not toggle off when re-clicked");

    // ---- check box latches and toggles ------------------------------------
    [GForm released:cb inTree:t];
    ck((cb.state & OS_SELECTED) != 0, "check box turns on");
    [GForm released:cb inTree:t];
    ck((cb.state & OS_SELECTED) == 0, "check box toggles back off");

    // ---- buttons: momentary, and they exit ---------------------------------
    GObject *exit = nil;
    GObject *held = [GForm pressed:ok inTree:t exit:&exit];
    ck(held == ok && (ok.state & OS_SELECTED), "an exit button lights while held");
    ck(exit == nil, "...but does not exit until released");
    ck([GForm released:ok inTree:t] == ok, "releasing it exits through it");
    ck((ok.state & OS_SELECTED) == 0, "...and the highlight does not stick");

    // ---- disabled objects are inert ----------------------------------------
    exit = nil;
    ck([GForm pressed:dis inTree:t exit:&exit] == nil && exit == nil, "a disabled button ignores a press");
    ck([GForm released:dis inTree:t] == nil, "a disabled button ignores a release");

    // ---- default / cancel lookup -------------------------------------------
    ck([GForm objectWithFlag:OF_DEFAULT in:t] == ok,  "Return finds OF_DEFAULT");
    ck([GForm objectWithFlag:OF_CANCEL  in:t] == can, "Esc finds OF_CANCEL");

    // ---- validated text entry ----------------------------------------------
    ck([GForm slotCountOf:fld] == 4, "template slot count");
    int caret = 0;
    ck([GForm insert:'1' into:fld caret:&caret], "'1' accepted by the 9999 mask");
    ck(![GForm insert:'x' into:fld caret:&caret], "'x' rejected by the 9999 mask");
    ck([GForm insert:'2' into:fld caret:&caret] && [GForm insert:'3' into:fld caret:&caret] &&
       [GForm insert:'4' into:fld caret:&caret], "fills the remaining slots");
    ck([fld.ted.text isEqualToString:@"1234"], "text is '1234'");
    ck(![GForm insert:'5' into:fld caret:&caret], "a full template rejects more input");
    ck(caret == 4, "caret sits at the end");
    ck([GForm deleteBackwardIn:fld caret:&caret] && [fld.ted.text isEqualToString:@"123"],
       "backspace deletes before the caret");
    caret = 0;
    ck([GForm deleteForwardIn:fld caret:&caret] && [fld.ted.text isEqualToString:@"23"],
       "forward delete removes at the caret");

    // ---- case folding in the mask ------------------------------------------
    GObject *up = [GObject objectOfType:GT_FIELD frame:NSMakeRect(0, 0, 80, 20)];
    up.flags |= OF_EDITABLE; up.ted.tmplt = @"___"; up.ted.text = @"";
    up.ted.valid = @"AAA";                            // upper alpha, folds case
    int c2 = 0;
    ck([GForm insert:'a' into:up caret:&c2] && [up.ted.text isEqualToString:@"A"],
       "the 'A' mask upper-cases input");
    ck(![GForm insert:'7' into:up caret:&c2], "the 'A' mask rejects a digit");
    up.ted.valid = @"";                               // no mask: anything printable
    GObject *any = [GObject objectOfType:GT_FIELD frame:NSMakeRect(0, 0, 80, 20)];
    any.flags |= OF_EDITABLE; any.ted.tmplt = @"___"; any.ted.text = @""; any.ted.valid = @"";
    int c3 = 0;
    ck([GForm insert:'#' into:any caret:&c3], "an empty mask accepts anything printable");

    // ---- tab order ----------------------------------------------------------
    NSArray *fields = [GForm editableObjectsIn:t];
    ck(fields.count == 1 && fields[0] == fld, "only the editable field is in the tab order");

    printf("formtest: %d checks, %d failure(s) — %s\n", gChecks, gFails, gFails ? "FAIL" : "OK");
    return gFails ? 1 : 0;
}

// Rocks --clicktest <file.rsc> — drive a REAL resource through the same sequence
// the canvas does on a click: hit-test at a point, then GForm pressed/released.
// This is the click path without a window: no synthetic mouse events, no screen.
static int clicktest(const char *path) {
    NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    NSString *err = nil;
    GResource *res = d ? GRscRead(d, &err) : nil;
    if (!res) { printf("clicktest: cannot read %s (%s)\n", path, err.UTF8String ?: "?"); return 1; }

    // Click an object by hit-testing its centre, exactly as CanvasView does:
    // press, and only release what the press actually took hold of (a TOUCHEXIT
    // object exits on the way down and is never released, so it applies once).
    GObject *(^clickAt)(GTree *, GObject *) = ^GObject *(GTree *tr, GObject *target) {
        NSPoint o = [tr absoluteOriginOf:target];
        NSPoint c = NSMakePoint(o.x + target.w / 2.0, o.y + target.h / 2.0);
        GObject *hit = [tr hitTest:c];
        GObject *exitObj = nil;
        GObject *held = [GForm pressed:hit inTree:tr exit:&exitObj];
        GObject *viaRelease = held ? [GForm released:held inTree:tr] : nil;
        return exitObj ?: viaRelease;
    };

    int radiosSeen = 0, groupsChecked = 0;
    for (GTree *tr in res.trees) {
        // gather the radio groups (radios sharing a parent)
        NSMutableDictionary<NSValue *, NSMutableArray<GObject *> *> *groups = [NSMutableDictionary dictionary];
        for (GObject *o in [tr allObjects]) {
            if (![GForm isRadio:o]) continue;
            radiosSeen++;
            GObject *parent = [tr parentOf:o] ?: tr.root;
            NSValue *k = [NSValue valueWithNonretainedObject:parent];
            if (!groups[k]) groups[k] = [NSMutableArray array];
            [groups[k] addObject:o];
        }
        for (NSArray<GObject *> *grp in groups.allValues) {
            if (grp.count < 2) continue;
            groupsChecked++;
            for (GObject *pick in grp) {
                GObject *hitObj = [tr hitTest:NSMakePoint([tr absoluteOriginOf:pick].x + pick.w / 2.0,
                                                          [tr absoluteOriginOf:pick].y + pick.h / 2.0)];
                ck(hitObj == pick, "hit-testing a radio's centre finds that radio");
                clickAt(tr, pick);
                int on = 0;
                for (GObject *g in grp) if (g.state & OS_SELECTED) on++;
                ck((pick.state & OS_SELECTED) != 0, "the clicked radio is selected");
                ck(on == 1, "exactly one radio in the group is selected");
            }
        }
        // Clicking a push button reports itself and leaves no stuck highlight.
        // (A radio may also carry OF_EXIT; it is meant to latch, so skip those.)
        for (GObject *o in [tr allObjects]) {
            if (o.type == GT_BUTTON && (o.flags & OF_EXIT) &&
                ![GForm isRadio:o] && ![GForm isDisabled:o]) {
                ck(clickAt(tr, o) == o, "clicking a push button exits through it");
                ck((o.state & OS_SELECTED) == 0, "...and leaves no stuck highlight");
                break;
            }
        }
    }
    printf("clicktest %s: %d radios, %d group(s); %d checks, %d failure(s) — %s\n",
           path, radiosSeen, groupsChecked, gChecks, gFails, gFails ? "FAIL" : "OK");
    return gFails ? 1 : 0;
}

// Rocks --cicons <file.rsc> <out.png> — render every colour icon a file carries,
// so the CICONBLK -> RGBA expansion can actually be looked at.
static int ciconshot(const char *rsc, const char *out) {
    NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:rsc]];
    NSString *err = nil;
    GResource *res = d ? GRscRead(d, &err) : nil;
    if (!res) { printf("cannot read %s: %s\n", rsc, err.UTF8String ?: "?"); return 1; }

    NSMutableArray<GObject *> *icons = [NSMutableArray array];
    for (GTree *t in res.trees)
        for (GObject *o in [t allObjects])
            if (o.type == GT_CICONBLK && o.icon.pam) [icons addObject:o];
    if (!icons.count) { printf("%s: no colour icons\n", rsc); return 1; }

    int cols = 8, cell = 40;
    int rows = ((int)icons.count + cols - 1) / cols;
    int W = cols * cell, H = rows * cell * 2;      // normal row, then SELECTED row
    // premultiplied: Core Graphics cannot composite into a non-premultiplied context
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [[NSColor colorWithWhite:0.85 alpha:1] set]; NSRectFill(NSMakeRect(0,0,W,H));

    // diagnostics on the first icon: is it decoding, and is anything opaque?
    {
        GIcon *ic0 = icons[0].icon;
        NSImage *im0 = GImageFromPAM(ic0.pam);
        const uint8_t *pb = ic0.pam.bytes;
        NSUInteger hdr = 0; while (hdr + 6 < ic0.pam.length && memcmp(pb + hdr, "ENDHDR", 6)) hdr++;
        hdr += 7;
        int opaque = 0, coloured = 0;
        for (NSUInteger k = hdr; k + 3 < ic0.pam.length; k += 4) {
            if (pb[k+3]) opaque++;
            if (pb[k] || pb[k+1] || pb[k+2]) coloured++;
        }
        printf("  icon0: %dx%d pam=%lu bytes decode=%s  opaque px=%d  non-black px=%d\n",
               ic0.iconW, ic0.iconH, (unsigned long)ic0.pam.length, im0 ? "ok" : "NIL",
               opaque, coloured);
    }

    int nsel = 0;
    for (int i = 0; i < (int)icons.count; i++) {
        GIcon *ic = icons[i].icon;
        int cx = (i % cols) * cell, cy = (i / cols) * cell * 2;
        NSImage *img = GImageFromPAM(ic.pam);
        if (img) [img drawInRect:NSMakeRect(cx+4, H - cy - cell + 4, 32, 32)
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        if (ic.selPam) {
            nsel++;
            NSImage *sel = GImageFromPAM(ic.selPam);
            if (sel) [sel drawInRect:NSMakeRect(cx+4, H - cy - cell*2 + 4, 32, 32)
                            fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[NSString stringWithUTF8String:out] atomically:YES];
    printf("%s: %d colour icon(s), %d with a SELECTED form -> %s\n",
           rsc, (int)icons.count, nsel, out);
    return 0;
}

// Rocks --images <file.rsc> <out.png> — render every BITBLK a file carries
// (G_IMAGE objects and the free-image table), so the bit forms can be looked at.
static int imageshot(const char *rsc, const char *out) {
    NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:rsc]];
    NSString *err = nil;
    GResource *res = d ? GRscRead(d, &err) : nil;
    if (!res) { printf("cannot read %s: %s\n", rsc, err.UTF8String ?: "?"); return 1; }

    NSMutableArray<GBitblk *> *bbs = [NSMutableArray array];
    for (GTree *t in res.trees)
        for (GObject *o in [t allObjects]) if (o.bitblk.data) [bbs addObject:o.bitblk];
    int inObjects = (int)bbs.count;
    for (GBitblk *bb in res.freeImages) if (bb.data) [bbs addObject:bb];
    if (!bbs.count) { printf("%s: no BITBLKs\n", rsc); return 1; }

    int cols = 8, cell = 48;
    int rows = ((int)bbs.count + cols - 1) / cols;
    int W = cols * cell, H = rows * cell;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [[NSColor colorWithWhite:0.75 alpha:1] set]; NSRectFill(NSMakeRect(0,0,W,H));

    [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationNone;
    for (int i = 0; i < (int)bbs.count; i++) {
        NSImage *img = [bbs[i] image];
        if (!img) continue;
        int cx = (i % cols) * cell, cy = (i / cols) * cell;
        NSSize s = img.size;
        // scale up to fill the cell (a 16x16 cursor is unreadable at 1:1)
        CGFloat sc = MIN((cell - 8) / s.width, (cell - 8) / s.height);
        CGFloat dw = s.width * sc, dh = s.height * sc;
        [img drawInRect:NSMakeRect(cx + (cell - dw)/2, H - cy - (cell + dh)/2, dw, dh)
               fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[NSString stringWithUTF8String:out] atomically:YES];
    printf("%s: %d BITBLK(s) — %d on objects, %d free -> %s\n", rsc,
           (int)bbs.count, inObjects, (int)res.freeImages.count, out);
    return 0;
}

// Rocks --slice <name> renders that theme slice at several sizes to scratch.
static int sliceTest(const char *name) {
    GTheme *th = [GTheme defaultTheme];
    if (!th) { printf("no theme\n"); return 1; }
    NSString *slice = [NSString stringWithUTF8String:name];
    NSSize ss = [th sliceSize:slice];
    printf("slice '%s' source %gx%g\n", name, ss.width, ss.height);
    int W = 220, H = 200;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *flip = [NSAffineTransform transform];
    [flip translateXBy:0 yBy:H]; [flip scaleXBy:1 yBy:-1];
    [NSGraphicsContext setCurrentContext:gc];
    [[NSColor colorWithWhite:0.85 alpha:1] set]; NSRectFill(NSMakeRect(0,0,W,H));
    [flip concat];
    // render the slice at native height and at 2x/3x heights
    int y = 10;
    for (int mult = 1; mult <= 4; mult++) {
        CGFloat hh = ss.height * mult;
        [th draw:slice inRect:NSMakeRect(10, y, 180, hh)];
        y += hh + 10;
    }
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *out = @"scratch/slice.png";
    [png writeToFile:out atomically:YES];
    printf("wrote %s\n", out.UTF8String);
    return 0;
}

int main(int argc, const char *argv[]) {
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        @autoreleasepool { return selftest(argc, argv); }
    }
    if (argc > 1 && strcmp(argv[1], "--formtest") == 0) {
        @autoreleasepool { return formtest(); }
    }
    if (argc > 2 && strcmp(argv[1], "--clicktest") == 0) {
        @autoreleasepool { return clicktest(argv[2]); }
    }
    if (argc > 3 && strcmp(argv[1], "--images") == 0) {
        @autoreleasepool { return imageshot(argv[2], argv[3]); }
    }
    if (argc > 3 && strcmp(argv[1], "--cicons") == 0) {
        @autoreleasepool { return ciconshot(argv[2], argv[3]); }
    }
    if (argc > 2 && strcmp(argv[1], "--slice") == 0) {
        @autoreleasepool { return sliceTest(argv[2]); }
    }
    if (argc > 2 && strcmp(argv[1], "--iconrender") == 0) {
        @autoreleasepool {
            NSImage *src = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
            GObject *ic = [GObject objectOfType:GT_ICON frame:NSMakeRect(20, 20, 48, 60)];
            ic.icon.isColor = YES; ic.icon.pam = GPAMFromImage(src); ic.icon.label = @"icon";
            int W = 160, H = 160;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:W*4 bitsPerPixel:32];
            NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
            // FLIPPED like the canvas
            NSAffineTransform *flip = [NSAffineTransform transform]; [flip translateXBy:0 yBy:H]; [flip scaleXBy:1 yBy:-1]; [flip concat];
            [[NSColor colorWithWhite:0.9 alpha:1] set]; NSRectFill(NSMakeRect(0,0,W,H));
            NSAffineTransform *tf = [NSAffineTransform transform]; [tf scaleBy:2]; [tf concat];
            [GRender drawObject:ic at:NSMakePoint(20,20)];
            [NSGraphicsContext restoreGraphicsState];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"scratch/iconrender.png" atomically:YES];
            printf("wrote scratch/iconrender.png (img=%s)\n", [ic.icon image]?"ok":"nil");
            return 0;
        }
    }
    if (argc > 2 && strcmp(argv[1], "--icontest") == 0) {
        @autoreleasepool {
            NSString *path = [NSString stringWithUTF8String:argv[2]];
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
            printf("NSImage: %s  size=%gx%g reps=%lu\n", img?"loaded":"nil",
                   img.size.width, img.size.height, (unsigned long)img.representations.count);
            NSData *pam = GPAMFromImage(img);
            printf("PAM: %lu bytes, header: %.60s\n", (unsigned long)pam.length,
                   pam.length ? (const char*)pam.bytes : "(none)");
            NSImage *back = GImageFromPAM(pam);
            printf("decoded back: %s size=%gx%g\n", back?"OK":"nil", back.size.width, back.size.height);
            return back ? 0 : 1;
        }
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
