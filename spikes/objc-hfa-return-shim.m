#import <Cocoa/Cocoa.h>
void* mkview(int x, int y, int w, int h) { return [[NSView alloc] initWithFrame:NSMakeRect(x,y,w,h)]; }
