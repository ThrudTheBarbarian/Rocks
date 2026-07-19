#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

/* xtc-provided action callback: (target, sender). */
typedef void (*xg_action_cb)(void *self, void *sender);
static xg_action_cb g_action_cb = 0;
void xg_set_action_cb(void *cb) { g_action_cb = (xg_action_cb)cb; }

/* C trampoline registered as onClick: — hands the click to xtc. */
static void shim_action(id self, SEL _cmd, id sender) {
    if (g_action_cb) g_action_cb((void *)self, (void *)sender);
}

void xg_init(void) { [NSApplication sharedApplication]; }

/* A target class exposing onClick:, dispatched into xtc. Returns an instance. */
void *xg_make_target(void) {
    Class c = objc_allocateClassPair([NSObject class], "XGTarget", 0);
    class_addMethod(c, sel_registerName("onClick:"), (IMP)shim_action, "v@:@");
    objc_registerClassPair(c);
    return (void *)[[c alloc] init];
}
void *xg_make_button(int w, int h) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    [b setTitle:@"OK"];
    return (void *)b;
}
void xg_wire_button(void *btn, void *target) {
    [(NSButton *)btn setTarget:(id)target];
    [(NSButton *)btn setAction:sel_registerName("onClick:")];
}
void xg_click(void *btn) { [(NSButton *)btn performClick:nil]; }
