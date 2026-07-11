// GImage.m — see GImage.h.

#import "GImage.h"

// Build an NSImage from RGBA8888 pixels (w*h*4, top-down).
static NSImage *imageFromRGBA(const unsigned char *px, int w, int h) {
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:w pixelsHigh:h
                                             bitsPerSample:8 samplesPerPixel:4
                                                  hasAlpha:YES isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                              bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                                               bytesPerRow:w * 4 bitsPerPixel:32];
    memcpy(rep.bitmapData, px, (size_t)w * h * 4);
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img addRepresentation:rep];
    return img;
}

NSImage *GImageFromPAM(NSData *data) {
    const unsigned char *p = data.bytes;
    NSUInteger len = data.length;
    if (len < 3 || p[0] != 'P' || p[1] != '7') return nil;
    NSUInteger i = 2;
    int w = 0, h = 0, depth = 0, maxval = 255;
    // parse header lines until ENDHDR
    while (i < len) {
        // read a line
        NSUInteger start = i;
        while (i < len && p[i] != '\n') i++;
        NSString *line = [[NSString alloc] initWithBytes:p + start length:i - start
                                                encoding:NSASCIIStringEncoding] ?: @"";
        if (i < len) i++; // skip newline
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"ENDHDR"]) break;
        if ([line hasPrefix:@"WIDTH"])       w = [[line substringFromIndex:5] intValue];
        else if ([line hasPrefix:@"HEIGHT"]) h = [[line substringFromIndex:6] intValue];
        else if ([line hasPrefix:@"DEPTH"])  depth = [[line substringFromIndex:5] intValue];
        else if ([line hasPrefix:@"MAXVAL"]) maxval = [[line substringFromIndex:6] intValue];
    }
    if (w <= 0 || h <= 0 || depth < 1 || depth > 4 || maxval != 255) return nil;
    NSUInteger need = (NSUInteger)w * h * depth;
    if (len - i < need) return nil;
    const unsigned char *raw = p + i;

    unsigned char *rgba = malloc((size_t)w * h * 4);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const unsigned char *s = raw + ((size_t)y * w + x) * depth;
            unsigned char r, g, b, a;
            switch (depth) {
                case 1: r = g = b = s[0]; a = 255; break;
                case 2: r = g = b = s[0]; a = s[1]; break;
                case 4: r = s[0]; g = s[1]; b = s[2]; a = s[3]; break;
                default: r = s[0]; g = s[1]; b = s[2]; a = 255; break; // 3
            }
            unsigned char *d = rgba + ((size_t)y * w + x) * 4;
            d[0] = r; d[1] = g; d[2] = b; d[3] = a;
        }
    }
    NSImage *img = imageFromRGBA(rgba, w, h);
    free(rgba);
    return img;
}

NSData *GPAMFromImage(NSImage *image) {
    NSSize sz = image.size;
    int w = (int)sz.width, h = (int)sz.height;
    if (w <= 0 || h <= 0) return nil;
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:w pixelsHigh:h
                                             bitsPerSample:8 samplesPerPixel:4
                                                  hasAlpha:YES isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:w * 4 bitsPerPixel:32];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [image drawInRect:NSMakeRect(0, 0, w, h)];
    [NSGraphicsContext restoreGraphicsState];

    NSMutableData *out = [NSMutableData data];
    NSString *hdr = [NSString stringWithFormat:
        @"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", w, h];
    [out appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];
    unsigned char *bd = rep.bitmapData;
    NSUInteger bpr = rep.bytesPerRow;
    for (int y = 0; y < h; y++) {
        [out appendBytes:bd + (NSUInteger)y * bpr length:(NSUInteger)w * 4];
    }
    return out;
}

NSImage *GImageFromMono(NSData *data, NSData *mask, int w, int h) {
    if (!data || w <= 0 || h <= 0) return nil;
    int wordW = ((w + 15) / 16) * 16;   // rows padded to 16-bit boundary
    int stride = wordW / 8;
    const unsigned char *d = data.bytes;
    const unsigned char *m = mask.bytes;
    NSUInteger dlen = data.length, mlen = mask.length;
    unsigned char *rgba = calloc((size_t)w * h * 4, 1);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            NSUInteger bit = (NSUInteger)y * stride + (x / 8);
            int shift = 7 - (x & 7);
            int on = (bit < dlen) ? ((d[bit] >> shift) & 1) : 0;
            int opaque = m ? ((bit < mlen) ? ((m[bit] >> shift) & 1) : 0) : 1;
            unsigned char *px = rgba + ((size_t)y * w + x) * 4;
            if (opaque) {
                unsigned char v = on ? 0 : 255;       // set bit -> black
                px[0] = px[1] = px[2] = v; px[3] = 255;
            }
        }
    }
    NSImage *img = imageFromRGBA(rgba, w, h);
    free(rgba);
    return img;
}
