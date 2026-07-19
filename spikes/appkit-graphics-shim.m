#import <Cocoa/Cocoa.h>

static NSBitmapImageRep *g_rep = 0;

/* Begin drawing into an offscreen RGBA bitmap; clears to white. Returns the rep (for readback). */
void *xg_gfx_begin(int w, int h) {
    g_rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:g_rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    return (void *)g_rep;
}
void xg_gfx_fill(int x, int y, int w, int h, int r, int g, int b) {
    [[NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(x, y, w, h));
}
void xg_gfx_line(int x1, int y1, int x2, int y2, int r, int g, int b) {
    [[NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x1, y1)];
    [p lineToPoint:NSMakePoint(x2, y2)];
    [p setLineWidth:2];
    [p stroke];
}
void xg_gfx_text(int x, int y, const char *s, int r, int g, int b) {
    NSDictionary *a = @{ NSForegroundColorAttributeName:
        [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0] };
    [[NSString stringWithUTF8String:s] drawAtPoint:NSMakePoint(x, y) withAttributes:a];
}
void xg_gfx_end(void) { [NSGraphicsContext restoreGraphicsState]; }

/* Read a pixel back as packed 0xRRGGBB — the verification hook. */
int xg_gfx_pixel(void *rep, int x, int y) {
    NSColor *c = [(NSBitmapImageRep *)rep colorAtX:x y:y];
    int R = (int)([c redComponent]   * 255 + 0.5);
    int G = (int)([c greenComponent] * 255 + 0.5);
    int B = (int)([c blueComponent]  * 255 + 0.5);
    return (R << 16) | (G << 8) | B;
}
