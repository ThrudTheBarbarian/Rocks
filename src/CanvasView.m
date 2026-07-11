// CanvasView.m — see CanvasView.h.

#import "CanvasView.h"
#import "GRender.h"

NSPasteboardType const GPaletteDragType = @"net.gornall.rocks.palette";

static const CGFloat kMargin = 40;      // view-space padding around the dialog
static const CGFloat kHandle = 7;       // resize handle size (view space)
static const CGFloat kSnap = 5;         // snap threshold (model px)

typedef NS_ENUM(int, DragMode) { DM_NONE, DM_MOVE, DM_RESIZE, DM_MARQUEE };
typedef NS_ENUM(int, GHandle) {
    H_NONE, H_TL, H_T, H_TR, H_R, H_BR, H_B, H_BL, H_L
};

@implementation CanvasView {
    DragMode _mode;
    GHandle   _handle;
    NSPoint  _downModel;        // mouse-down point (model)
    NSData  *_dragSnapshot;     // resource state at drag start (for one undo)
    // per-object start geometry, keyed by object
    NSMapTable<GObject *, NSValue *> *_startFrames;
    NSRect   _marquee;          // view space
    NSArray<NSValue *> *_guideLines; // horizontal/vertical guide segments (view space)
    BOOL     _didDrag;
    int      _activeMenu;       // which menu title's dropdown is shown
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _scale = 2.0; _showGrid = YES; _snapEnabled = YES; _showGuides = YES; _gridSize = 8;
        _mode = DM_NONE; _startFrames = [NSMapTable strongToStrongObjectsMapTable];
        [self registerForDraggedTypes:@[GPaletteDragType]];
    }
    return self;
}

- (GObject *)activeMenuTitle {
    NSArray *titles = self.tree.menuTitles;
    return (_activeMenu >= 0 && _activeMenu < (int)titles.count) ? titles[_activeMenu] : nil;
}
- (GObject *)activeMenuDropdown { return [self.tree dropdownUnderTitle:[self activeMenuTitle]]; }
- (void)setActiveMenuTitle:(GObject *)t {
    NSUInteger i = [self.tree.menuTitles indexOfObject:t];
    if (i != NSNotFound) { _activeMenu = (int)i; self.needsDisplay = YES; }
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (GTree *)tree { return self.doc.tree; }

// MARK: coordinate mapping

- (NSPoint)viewFromModel:(NSPoint)m { return NSMakePoint(kMargin + m.x * _scale, kMargin + m.y * _scale); }
- (NSPoint)modelFromView:(NSPoint)v { return NSMakePoint((v.x - kMargin) / _scale, (v.y - kMargin) / _scale); }
- (NSRect)viewRectFromModel:(NSRect)r {
    return NSMakeRect(kMargin + r.origin.x * _scale, kMargin + r.origin.y * _scale,
                      r.size.width * _scale, r.size.height * _scale);
}

- (void)sizeToFitModel {
    GObject *root = self.tree.root;
    NSSize s = NSMakeSize(kMargin * 2 + root.w * _scale, kMargin * 2 + root.h * _scale);
    NSSize vis = self.enclosingScrollView.contentView.bounds.size;
    s.width = MAX(s.width, vis.width); s.height = MAX(s.height, vis.height);
    [self setFrameSize:s];
}
- (void)refresh {
    int nt = (int)self.tree.menuTitles.count;
    if (_activeMenu >= nt) _activeMenu = 0;
    [self sizeToFitModel]; self.needsDisplay = YES;
}

// MARK: drawing

- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithWhite:0.28 alpha:1] set]; NSRectFill(self.bounds);

    GTree *tree = self.tree; GObject *root = tree.root;
    NSRect page = [self viewRectFromModel:NSMakeRect(0, 0, root.w, root.h)];
    // page shadow + surface
    [[NSColor colorWithWhite:0 alpha:0.35] set]; NSRectFill(NSOffsetRect(page, 3, 3));
    [[NSColor colorWithWhite:0.93 alpha:1] set]; NSRectFill(page);

    if (_showGrid) [self drawGridIn:page];

    // draw the object tree, scaled — nearest-neighbour keeps the pixel-art theme
    // crisp at the (integer) edit zoom instead of blurring it.
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    [gc saveGraphicsState];
    gc.imageInterpolation = NSImageInterpolationNone;
    NSAffineTransform *tf = [NSAffineTransform transform];
    [tf translateXBy:kMargin yBy:kMargin];
    [tf scaleBy:_scale];
    [tf concat];
    if (tree.isMenu) [GRender drawMenuTree:tree activeIndex:_activeMenu];
    else [GRender drawTree:tree];
    [gc restoreGraphicsState];

    // selection overlays
    for (GObject *o in self.doc.selection) {
        NSPoint ao = [tree absoluteOriginOf:o];
        if (isnan(ao.x)) continue;
        NSRect vr = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
        [[NSColor colorWithSRGBRed:0.15 green:0.5 blue:1 alpha:1] set];
        NSFrameRectWithWidth(NSInsetRect(vr, -0.5, -0.5), 1.5);
    }
    // resize handles on the anchor
    GObject *anchor = self.doc.anchor;
    if (anchor && self.doc.selection.count == 1) {
        for (NSValue *v in [self handleRectsFor:anchor]) {
            NSRect hr = v.rectValue;
            [[NSColor whiteColor] set]; NSRectFill(hr);
            [[NSColor colorWithSRGBRed:0.15 green:0.5 blue:1 alpha:1] set]; NSFrameRect(hr);
        }
    }

    // alignment guides
    if (_guideLines.count) {
        [[NSColor colorWithSRGBRed:1 green:0.2 blue:0.5 alpha:0.9] set];
        for (NSValue *v in _guideLines) {
            NSRect seg = v.rectValue;
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:seg.origin];
            [p lineToPoint:NSMakePoint(seg.origin.x + seg.size.width, seg.origin.y + seg.size.height)];
            p.lineWidth = 1; [p stroke];
        }
    }

    // marquee
    if (_mode == DM_MARQUEE) {
        [[NSColor colorWithWhite:1 alpha:0.15] set]; NSRectFill(_marquee);
        [[NSColor whiteColor] set]; NSFrameRect(_marquee);
    }
}

- (void)drawGridIn:(NSRect)page {
    [[NSColor colorWithWhite:0 alpha:0.08] set];
    CGFloat step = _gridSize * _scale;
    if (step < 4) return;
    for (CGFloat x = page.origin.x; x <= NSMaxX(page); x += step) {
        NSRectFill(NSMakeRect(x, page.origin.y, 1, page.size.height));
    }
    for (CGFloat y = page.origin.y; y <= NSMaxY(page); y += step) {
        NSRectFill(NSMakeRect(page.origin.x, y, page.size.width, 1));
    }
}

- (NSArray<NSValue *> *)handleRectsFor:(GObject *)o {
    NSPoint ao = [self.tree absoluteOriginOf:o];
    if (isnan(ao.x)) return @[];
    NSRect r = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
    CGFloat mx = NSMidX(r), my = NSMidY(r);
    NSPoint pts[8] = {
        {r.origin.x, r.origin.y}, {mx, r.origin.y}, {NSMaxX(r), r.origin.y},
        {NSMaxX(r), my}, {NSMaxX(r), NSMaxY(r)}, {mx, NSMaxY(r)},
        {r.origin.x, NSMaxY(r)}, {r.origin.x, my}
    };
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < 8; i++)
        [out addObject:[NSValue valueWithRect:NSMakeRect(pts[i].x - kHandle/2, pts[i].y - kHandle/2, kHandle, kHandle)]];
    return out;
}

- (GHandle)handleAtView:(NSPoint)v for:(GObject *)o {
    NSArray *rects = [self handleRectsFor:o];
    for (int i = 0; i < (int)rects.count; i++)
        if (NSPointInRect(v, [rects[i] rectValue])) return (GHandle)(i + 1);
    return H_NONE;
}

// MARK: context menu

- (NSMenu *)menuForEvent:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    GObject *hit = [self hitTestMenuAware:[self modelFromView:v]];
    if (hit && hit != self.tree.root) {
        [self.doc select:hit extend:NO];
        if (hit.type == GT_TITLE) [self setActiveMenuTitle:hit];   // edit this menu
    } else {
        [self.doc clearSelection];
    }
    self.needsDisplay = YES;

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    if (self.tree.isMenu) {
        [[menu addItemWithTitle:@"Add Menu Title" action:@selector(addMenuTitle:) keyEquivalent:@""] setTarget:nil];
        [[menu addItemWithTitle:@"Add Menu Item" action:@selector(addMenuItem:) keyEquivalent:@""] setTarget:nil];
        [menu addItem:[NSMenuItem separatorItem]];
    }
    BOOL haveSel = self.doc.selection.count > 0;
    NSMenuItem *dup = [menu addItemWithTitle:@"Duplicate" action:@selector(duplicateObject:) keyEquivalent:@""];
    NSMenuItem *del = [menu addItemWithTitle:@"Delete" action:@selector(deleteObject:) keyEquivalent:@""];
    dup.enabled = haveSel; del.enabled = haveSel;
    return menu;
}

// MARK: mouse

- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint m = [self modelFromView:v];
    _downModel = m; _didDrag = NO; _guideLines = nil;
    BOOL shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;

    // resize handle on the single anchor?
    if (self.doc.selection.count == 1) {
        GHandle h = [self handleAtView:v for:self.doc.anchor];
        if (h != H_NONE) {
            _mode = DM_RESIZE; _handle = h;
            [self beginDragCapture];
            return;
        }
    }

    GObject *hit = [self hitTestMenuAware:m];
    // clicking a menu title switches which dropdown is shown
    if (hit && hit.type == GT_TITLE) {
        NSUInteger idx = [self.tree.menuTitles indexOfObject:hit];
        if (idx != NSNotFound) { _activeMenu = (int)idx; }
    }
    if (hit && hit != self.tree.root) {
        if (shift) { [self.doc select:hit extend:YES]; }
        else if (![self.doc isSelected:hit]) { [self.doc select:hit extend:NO]; }
        _mode = DM_MOVE;
        [self beginDragCapture];
    } else if (hit == self.tree.root && !shift) {
        // clicking the dialog background: allow selecting/moving the root too
        [self.doc select:hit extend:NO];
        _mode = DM_MOVE; [self beginDragCapture];
    } else {
        if (!shift) [self.doc clearSelection];
        _mode = DM_MARQUEE; _marquee = NSMakeRect(v.x, v.y, 0, 0);
    }
    self.needsDisplay = YES;
}

// Hit-test that ignores hidden menu dropdowns (only the active one is live).
- (GObject *)hitTestMenuAware:(NSPoint)m {
    GTree *tree = self.tree;
    if (!tree.isMenu) return [tree hitTest:m];
    NSArray<GObject *> *titles = tree.menuTitles;
    GObject *activeTitle = (_activeMenu >= 0 && _activeMenu < (int)titles.count) ? titles[_activeMenu] : nil;
    GObject *activeDrop = [tree dropdownUnderTitle:activeTitle];
    NSMutableSet *skip = [NSMutableSet set];
    for (GObject *dd in tree.menuDropdowns)
        if (dd != activeDrop) [dd preorder:^(GObject *o) { [skip addObject:o]; }];
    __block GObject *best = nil;
    int px = (int)m.x, py = (int)m.y;
    void (^walk)(GObject *, int, int) = nil;
    __block __weak void (^weakWalk)(GObject *, int, int);
    weakWalk = walk = ^(GObject *o, int ax, int ay) {
        if ((o.flags & OF_HIDETREE) || [skip containsObject:o]) return;
        int bx = ax + o.x, by = ay + o.y;
        if (px >= bx && py >= by && px < bx + o.w && py < by + o.h) best = o;
        for (GObject *c in o.children) weakWalk(c, bx, by);
    };
    walk(tree.root, 0, 0);
    return best;
}

- (void)beginDragCapture {
    _dragSnapshot = [self.doc snapshot];
    [_startFrames removeAllObjects];
    for (GObject *o in self.doc.selection)
        [_startFrames setObject:[NSValue valueWithRect:NSMakeRect(o.x, o.y, o.w, o.h)] forKey:o];
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint m = [self modelFromView:v];
    CGFloat dx = m.x - _downModel.x, dy = m.y - _downModel.y;
    if (!_didDrag && (fabs(v.x - [self viewFromModel:_downModel].x) > 2 || fabs(dx) + fabs(dy) > 0.5)) _didDrag = YES;

    if (_mode == DM_MOVE) {
        [self doMoveDX:dx DY:dy];
    } else if (_mode == DM_RESIZE) {
        [self doResizeDX:dx DY:dy];
    } else if (_mode == DM_MARQUEE) {
        _marquee = NSMakeRect(MIN(v.x, [self viewFromModel:_downModel].x),
                              MIN(v.y, [self viewFromModel:_downModel].y),
                              fabs(v.x - [self viewFromModel:_downModel].x),
                              fabs(v.y - [self viewFromModel:_downModel].y));
        [self selectInMarquee];
    }
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)e {
    if ((_mode == DM_MOVE || _mode == DM_RESIZE) && _didDrag) [self reparentByGeometry];
    _guideLines = nil;
    if ((_mode == DM_MOVE || _mode == DM_RESIZE) && _didDrag && _dragSnapshot) {
        [self.doc commit:(_mode == DM_RESIZE ? @"Resize" : @"Move") from:_dragSnapshot];
    }
    _mode = DM_NONE; _handle = H_NONE; _dragSnapshot = nil;
    self.needsDisplay = YES;
}

// MARK: move + snapping

- (void)doMoveDX:(CGFloat)dx DY:(CGFloat)dy {
    // Snap the anchor's new origin (in its parent space) to sibling/parent edges
    // and grid; apply the same delta to every selected object.
    GObject *anchor = self.doc.anchor;
    NSRect a0 = [_startFrames objectForKey:anchor].rectValue;
    CGFloat nx = a0.origin.x + dx, ny = a0.origin.y + dy;

    NSMutableArray *guides = [NSMutableArray array];
    CGFloat sdx = 0, sdy = 0;
    [self snapOrigin:&nx y:&ny width:a0.size.width height:a0.size.height
              parent:[self.tree parentOf:anchor] exclude:self.doc.selection
              guides:guides];
    sdx = nx - a0.origin.x; sdy = ny - a0.origin.y;

    for (GObject *o in self.doc.selection) {
        NSRect s0 = [_startFrames objectForKey:o].rectValue;
        o.x = (int)round(s0.origin.x + sdx);
        o.y = (int)round(s0.origin.y + sdy);
    }
    _guideLines = _showGuides ? guides : nil;
    [self.doc notifyModel];
}

// Snap a rect origin to candidate lines; append guide segments (view space).
- (void)snapOrigin:(CGFloat *)nx y:(CGFloat *)ny width:(CGFloat)w height:(CGFloat)h
            parent:(GObject *)parent exclude:(NSArray<GObject *> *)excl
            guides:(NSMutableArray *)guides {
    if (!_snapEnabled) {
        if (_showGrid) { *nx = round(*nx / _gridSize) * _gridSize; *ny = round(*ny / _gridSize) * _gridSize; }
        return;
    }
    GObject *root = parent ?: self.tree.root;
    // candidate vertical lines (x values) and horizontal lines (y values) in parent space
    NSMutableArray<NSNumber *> *vx = [NSMutableArray array];
    NSMutableArray<NSNumber *> *hy = [NSMutableArray array];
    // parent content edges + centre
    [vx addObjectsFromArray:@[@0, @(root.w/2.0), @(root.w)]];
    [hy addObjectsFromArray:@[@0, @(root.h/2.0), @(root.h)]];
    for (GObject *c in root.children) {
        if ([excl containsObject:c]) continue;
        [vx addObjectsFromArray:@[@(c.x), @(c.x + c.w/2.0), @(c.x + c.w)]];
        [hy addObjectsFromArray:@[@(c.y), @(c.y + c.h/2.0), @(c.y + c.h)]];
    }
    // our candidate edges: left, centre, right / top, mid, bottom
    CGFloat myX[3] = { *nx, *nx + w/2, *nx + w };
    CGFloat myY[3] = { *ny, *ny + h/2, *ny + h };

    CGFloat bestDX = kSnap + 1, snapX = 0; BOOL hitX = NO; CGFloat lineX = 0;
    for (NSNumber *cand in vx) {
        for (int i = 0; i < 3; i++) {
            CGFloat d = cand.doubleValue - myX[i];
            if (fabs(d) < fabs(bestDX)) { bestDX = d; snapX = d; hitX = YES; lineX = cand.doubleValue; }
        }
    }
    CGFloat bestDY = kSnap + 1, snapY = 0; BOOL hitY = NO; CGFloat lineY = 0;
    for (NSNumber *cand in hy) {
        for (int i = 0; i < 3; i++) {
            CGFloat d = cand.doubleValue - myY[i];
            if (fabs(d) < fabs(bestDY)) { bestDY = d; snapY = d; hitY = YES; lineY = cand.doubleValue; }
        }
    }
    if (hitX && fabs(bestDX) <= kSnap) {
        *nx += snapX;
        // vertical guide line spanning the page (view space)
        NSPoint top = [self viewFromModel:NSMakePoint((parent ? [self.tree absoluteOriginOf:parent].x : 0) + lineX, 0)];
        [guides addObject:[NSValue valueWithRect:NSMakeRect(top.x, kMargin, 0, self.tree.root.h * _scale)]];
    } else if (_showGrid) { *nx = round(*nx / _gridSize) * _gridSize; }
    if (hitY && fabs(bestDY) <= kSnap) {
        *ny += snapY;
        NSPoint lft = [self viewFromModel:NSMakePoint(0, (parent ? [self.tree absoluteOriginOf:parent].y : 0) + lineY)];
        [guides addObject:[NSValue valueWithRect:NSMakeRect(kMargin, lft.y, self.tree.root.w * _scale, 0)]];
    } else if (_showGrid) { *ny = round(*ny / _gridSize) * _gridSize; }
}

// MARK: resize

- (void)doResizeDX:(CGFloat)dx DY:(CGFloat)dy {
    GObject *o = self.doc.anchor;
    NSRect s0 = [_startFrames objectForKey:o].rectValue;
    CGFloat x = s0.origin.x, y = s0.origin.y, w = s0.size.width, h = s0.size.height;
    switch (_handle) {
        case H_TL: x += dx; y += dy; w -= dx; h -= dy; break;
        case H_T:  y += dy; h -= dy; break;
        case H_TR: y += dy; w += dx; h -= dy; break;
        case H_R:  w += dx; break;
        case H_BR: w += dx; h += dy; break;
        case H_B:  h += dy; break;
        case H_BL: x += dx; w -= dx; h += dy; break;
        case H_L:  x += dx; w -= dx; break;
        default: break;
    }
    if (_snapEnabled || _showGrid) {
        x = round(x / _gridSize) * _gridSize; y = round(y / _gridSize) * _gridSize;
        w = round(w / _gridSize) * _gridSize; h = round(h / _gridSize) * _gridSize;
    }
    o.x = (int)x; o.y = (int)y; o.w = (int)MAX(w, 4); o.h = (int)MAX(h, 4);
    [self.doc notifyModel];
}

// MARK: marquee

- (void)selectInMarquee {
    NSMutableArray *hits = [NSMutableArray array];
    for (GObject *o in self.tree.allObjects) {
        if (o == self.tree.root) continue;
        NSPoint ao = [self.tree absoluteOriginOf:o];
        NSRect vr = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
        if (NSIntersectsRect(vr, _marquee)) [hits addObject:o];
    }
    [self.doc setSelectionObjects:hits];
}

// MARK: reparent on drop

// Re-derive the whole tree's parent/child structure from geometry: every object
// becomes a child of the SMALLEST box that fully encloses it (inclusive edges),
// so the tree mirrors what's on screen.  Objects keep their absolute positions.
// Idempotent for unchanged geometry — only objects whose enclosure changed move.
- (void)reparentByGeometry {
    GTree *tree = self.tree;
    NSArray<GObject *> *all = tree.allObjects;      // preorder, root first
    if (all.count < 2) return;

    NSMapTable *rectFor = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable *idxFor  = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger i = 0; i < all.count; i++) {
        GObject *o = all[i];
        NSPoint ao = [tree absoluteOriginOf:o];
        [rectFor setObject:[NSValue valueWithRect:NSMakeRect(ao.x, ao.y, o.w, o.h)] forKey:o];
        [idxFor setObject:@(i) forKey:o];
    }

    NSMapTable *parentFor = [NSMapTable strongToStrongObjectsMapTable];
    for (GObject *o in all) {
        if (o == tree.root) continue;
        NSRect r = [[rectFor objectForKey:o] rectValue];
        CGFloat oArea = r.size.width * r.size.height;
        int oi = [[idxFor objectForKey:o] intValue];
        GObject *best = tree.root;
        NSRect rootR = [[rectFor objectForKey:tree.root] rectValue];
        CGFloat bestArea = rootR.size.width * rootR.size.height;
        int bestIdx = 0;
        for (GObject *p in all) {
            if (p == o || ![p canHaveChildren]) continue;
            NSRect pr = [[rectFor objectForKey:p] rectValue];
            BOOL enc = r.origin.x >= pr.origin.x && r.origin.y >= pr.origin.y &&
                       NSMaxX(r) <= NSMaxX(pr) && NSMaxY(r) <= NSMaxY(pr);
            if (!enc) continue;
            CGFloat pArea = pr.size.width * pr.size.height;
            int pi = [[idxFor objectForKey:p] intValue];
            if (pArea == oArea && pi >= oi) continue;   // tie: only an earlier object may parent (no cycles)
            if (pArea < bestArea || (pArea == bestArea && pi < bestIdx)) {
                best = p; bestArea = pArea; bestIdx = pi;
            }
        }
        [parentFor setObject:best forKey:o];
    }

    // rebuild children lists, preserving original order (z-order)
    NSMapTable *kidsFor = [NSMapTable strongToStrongObjectsMapTable];
    for (GObject *o in all) [kidsFor setObject:[NSMutableArray array] forKey:o];
    for (GObject *o in all) {
        if (o == tree.root) continue;
        [[kidsFor objectForKey:[parentFor objectForKey:o]] addObject:o];
    }
    for (GObject *o in all) {
        o.children = [kidsFor objectForKey:o];
        if (o == tree.root) continue;
        NSRect r = [[rectFor objectForKey:o] rectValue];
        NSRect pr = [[rectFor objectForKey:[parentFor objectForKey:o]] rectValue];
        o.x = (int)(r.origin.x - pr.origin.x);
        o.y = (int)(r.origin.y - pr.origin.y);
    }
}

// Smallest container object whose rect fully encloses `rect` (used at drop time).
- (GObject *)containerEnclosing:(NSRect)rect excluding:(GObject *)skip {
    __block GObject *best = nil;
    void (^walk)(GObject *, int, int) = nil;
    __block __weak void (^weakWalk)(GObject *, int, int);
    weakWalk = walk = ^(GObject *o, int ax, int ay) {
        if (o == skip) return;
        int bx = ax + o.x, by = ay + o.y;
        if ([o canHaveChildren] &&
            rect.origin.x >= bx && rect.origin.y >= by &&
            NSMaxX(rect) <= bx + o.w && NSMaxY(rect) <= by + o.h)
            best = o;
        for (GObject *c in o.children) weakWalk(c, bx, by);
    };
    walk(self.tree.root, 0, 0);
    return best ?: self.tree.root;
}

// MARK: keyboard

- (void)keyDown:(NSEvent *)e {
    unichar k = [e.charactersIgnoringModifiers length] ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    int step = (e.modifierFlags & NSEventModifierFlagShift) ? _gridSize : 1;
    int dx = 0, dy = 0;
    if (k == 127 || k == 8 || k == NSDeleteFunctionKey) {   // Delete / Backspace
        [NSApp sendAction:@selector(deleteObject:) to:nil from:self];
        return;
    }
    if (k == NSLeftArrowFunctionKey) dx = -step;
    else if (k == NSRightArrowFunctionKey) dx = step;
    else if (k == NSUpArrowFunctionKey) dy = -step;
    else if (k == NSDownArrowFunctionKey) dy = step;
    else { [super keyDown:e]; return; }
    if (self.doc.selection.count == 0) return;
    [self.doc perform:@"Nudge" block:^{
        for (GObject *o in self.doc.selection) { o.x += dx; o.y += dy; }
    }];
}

// MARK: palette drop (create new objects)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSString *typeStr = [info.draggingPasteboard stringForType:GPaletteDragType];
    if (!typeStr) return NO;
    GObType type = (GObType)typeStr.intValue;
    NSPoint v = [self convertPoint:info.draggingLocation fromView:nil];
    NSPoint m = [self modelFromView:v];

    NSSize def = [self defaultSizeFor:type];
    // drop at the cursor (root coords), then parent into the smallest box that
    // fully encloses the new object's rect.
    int ax = (int)round(m.x), ay = (int)round(m.y);
    if (_showGrid) { ax = (int)round((double)ax / _gridSize) * _gridSize; ay = (int)round((double)ay / _gridSize) * _gridSize; }
    GObject *target = [self containerEnclosing:NSMakeRect(ax, ay, def.width, def.height) excluding:nil];
    NSPoint tp = [self.tree absoluteOriginOf:target];
    int lx = ax - (int)tp.x, ly = ay - (int)tp.y;
    GObject *o = [GObject objectOfType:type frame:NSMakeRect(lx, ly, def.width, def.height)];

    [self.doc perform:@"Add Object" block:^{
        [target.children addObject:o];
        [self reparentByGeometry];   // adopt into/under boxes as needed
    }];
    [self.doc select:o extend:NO];
    return YES;
}

- (NSSize)defaultSizeFor:(GObType)t {
    switch (t) {
        case GT_BUTTON: return NSMakeSize(72, 24);
        case GT_CHECKBOX: case GT_RADIO: return NSMakeSize(120, 18);
        case GT_STRING: case GT_TEXT: case GT_TITLE: return NSMakeSize(100, 16);
        case GT_FIELD: case GT_FTEXT: case GT_POPUP: return NSMakeSize(140, 20);
        case GT_BOX: case GT_IBOX: return NSMakeSize(120, 80);
        case GT_ICON: case GT_CICON: return NSMakeSize(48, 60);
        default: return NSMakeSize(80, 24);
    }
}
@end
