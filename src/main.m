// main.m — NSApplication bootstrap (AppKit, no XIB/storyboard).

#import <AppKit/AppKit.h>
#import "AppDelegate.h"
#import "GModel.h"
#import "GRsc.h"
#import "GProject.h"
#import "GTheme.h"
#import "GImage.h"
#import "GRender.h"

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
