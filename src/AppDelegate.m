// AppDelegate.m — see AppDelegate.h.

#import "AppDelegate.h"
#import "MainWindowController.h"

@implementation AppDelegate {
    MainWindowController *_wc;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    _wc = [[MainWindowController alloc] init];
    [_wc showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

// menu items whose action is routed through the responder chain (target nil)
static NSMenuItem *mi(NSMenu *m, NSString *title, SEL action, NSString *key) {
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:key];
    return it;
}

- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init]; [main addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About Rocks" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Rocks" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // File
    NSMenuItem *fileItem = [[NSMenuItem alloc] init]; [main addItem:fileItem];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    mi(file, @"New", @selector(newDocument:), @"n");
    mi(file, @"Open…", @selector(openDocument:), @"o");
    [file addItem:[NSMenuItem separatorItem]];
    mi(file, @"Save…", @selector(saveDocument:), @"s");
    [file addItem:[NSMenuItem separatorItem]];
    mi(file, @"Import GEM .rsc…", @selector(importRsc:), @"i");
    mi(file, @"Export GEM .rsc…", @selector(exportRsc:), @"e");
    fileItem.submenu = file;

    // Edit
    NSMenuItem *editItem = [[NSMenuItem alloc] init]; [main addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    mi(edit, @"Undo", @selector(undo:), @"z");
    NSMenuItem *redo = mi(edit, @"Redo", @selector(redo:), @"Z");
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:[NSMenuItem separatorItem]];
    mi(edit, @"Cut", @selector(cutObject:), @"x");
    mi(edit, @"Copy", @selector(copyObject:), @"c");
    mi(edit, @"Paste", @selector(pasteObject:), @"v");
    mi(edit, @"Duplicate", @selector(duplicateObject:), @"d");
    mi(edit, @"Delete", @selector(deleteObject:), @"");
    [edit addItem:[NSMenuItem separatorItem]];
    mi(edit, @"Select All", @selector(selectAllObjects:), @"a");
    editItem.submenu = edit;

    // Object
    NSMenuItem *objItem = [[NSMenuItem alloc] init]; [main addItem:objItem];
    NSMenu *obj = [[NSMenu alloc] initWithTitle:@"Object"];
    NSMenuItem *at = mi(obj, @"Add Menu Title", @selector(addMenuTitle:), @"t");
    at.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem *ai = mi(obj, @"Add Menu Item", @selector(addMenuItem:), @"i");
    ai.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [obj addItem:[NSMenuItem separatorItem]];
    mi(obj, @"Align Left", @selector(alignLeft:), @"");
    mi(obj, @"Align Right", @selector(alignRight:), @"");
    mi(obj, @"Align Top", @selector(alignTop:), @"");
    mi(obj, @"Align Bottom", @selector(alignBottom:), @"");
    mi(obj, @"Align Centres H", @selector(alignCenterH:), @"");
    mi(obj, @"Align Centres V", @selector(alignCenterV:), @"");
    [obj addItem:[NSMenuItem separatorItem]];
    mi(obj, @"Distribute Horizontally", @selector(distributeH:), @"");
    mi(obj, @"Distribute Vertically", @selector(distributeV:), @"");
    [obj addItem:[NSMenuItem separatorItem]];
    mi(obj, @"Bring to Front", @selector(bringToFront:), @"]");
    mi(obj, @"Send to Back", @selector(sendToBack:), @"[");
    objItem.submenu = obj;

    // View
    NSMenuItem *viewItem = [[NSMenuItem alloc] init]; [main addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *snap = mi(view, @"Snap to Grid", @selector(toggleSnap:), @"'"); snap.state = NSControlStateValueOn;
    NSMenuItem *guides = mi(view, @"Alignment Guides", @selector(toggleGuides:), @";"); guides.state = NSControlStateValueOn;
    [view addItem:[NSMenuItem separatorItem]];
    mi(view, @"Zoom In", @selector(zoomIn:), @"+");
    mi(view, @"Zoom Out", @selector(zoomOut:), @"-");
    mi(view, @"Actual Size", @selector(zoomActual:), @"0");
    viewItem.submenu = view;

    NSApp.mainMenu = main;
}
@end
