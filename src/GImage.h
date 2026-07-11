// GImage.h — Netpbm P7 (PAM) decode/encode + classic mono ICONBLK rendering.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Decode a binary P7 PAM (GRAY / GRAY_ALPHA / RGB / RGB_ALPHA) to an NSImage.
NSImage * _Nullable GImageFromPAM(NSData *data);

// Encode an NSImage as a binary P7 PAM, RGB_ALPHA (depth 4).
NSData * _Nullable GPAMFromImage(NSImage *image);

// Render a classic mono ICONBLK (1bpp data + optional mask, rows padded to a
// 16-bit boundary) to an NSImage: set data bit -> black, mask governs alpha.
NSImage * _Nullable GImageFromMono(NSData *data, NSData * _Nullable mask, int w, int h);

NS_ASSUME_NONNULL_END
