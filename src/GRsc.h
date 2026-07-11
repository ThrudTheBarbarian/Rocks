// GRsc.h — classic GEM .rsc binary reader/writer.
//
// Read: parses standard .rsc files produced by other editors (Interface, ORCS,
// WERCS, RCS…) — big-endian by default with a little-endian fallback, classic
// RSHDR + OBJECT + TEDINFO + ICONBLK + free strings + tree index, char/pixel
// packed coordinates unpacked to pixels.
//
// Write: emits a classic big-endian .rsc with packed coordinates so the same
// tools can read it back; extended fpga-xt widgets (G_CHECKBOX..G_CICON) keep
// their type numbers, and G_CICON colour icons embed a P7 PAM blob.

#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

GResource * _Nullable GRscRead(NSData *data, NSString * _Nullable * _Nullable err);
NSData    * _Nullable GRscWrite(GResource *r, NSString * _Nullable * _Nullable err);

NS_ASSUME_NONNULL_END
