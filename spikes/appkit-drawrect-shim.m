#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

/* xtc-provided draw callback: (self, x, y, w, h) — primitives only, no NSRect crosses into xtc. */
typedef void (*xg_draw_cb)(void *self, int x, int y, int w, int h);
static xg_draw_cb g_draw_cb = 0;
void xg_set_draw_cb(void *cb) { g_draw_cb = (xg_draw_cb)cb; }

/* C trampoline registered as drawRect: — absorbs the NSRect, calls xtc with primitives. */
static void shim_drawRect(id self, SEL _cmd, NSRect r) {
    if (g_draw_cb)
        g_draw_cb((void *)self, (int)r.origin.x, (int)r.origin.y,
                  (int)r.size.width, (int)r.size.height);
}

void xg_init(void) { [NSApplication sharedApplication]; }

/* A custom NSView subclass whose drawRect: is the trampoline above. */
void *xg_make_viewclass(void) {
    Class c = objc_allocateClassPair([NSView class], "XGDrawView", 0);
    class_addMethod(c, sel_registerName("drawRect:"), (IMP)shim_drawRect,
                    "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    objc_registerClassPair(c);
    return (void *)c;
}

void *xg_make_window(int w, int h) {
    return (void *)[[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, w, h)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
}
void *xg_make_view(void *cls, int w, int h) {
    return (void *)[[(Class)cls alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
}
void xg_set_content(void *win, void *view) {
    [(NSWindow *)win setContentView:(NSView *)view];
}

/* Force an offscreen draw -> triggers drawRect: -> the xtc callback. Returns 1 if it drew. */
int xg_force_draw(void *view, int w, int h) {
    NSView *v = (NSView *)view;
    NSRect b = NSMakeRect(0, 0, w, h);
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:b];
    if (!rep) return 0;
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    return 1;
}

/* A drawing primitive the xtc callback can call — fills a rect (proves xtc can paint). */
void xg_fill(int x, int y, int w, int h, int gray) {
    [[NSColor colorWithWhite:(gray / 255.0) alpha:1.0] setFill];
    NSRectFill(NSMakeRect(x, y, w, h));
}
