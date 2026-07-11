// GRsc.m — thin Objective-C bridge over the portable C library rsc.c.
//
// The actual .rsc byte layout lives in rsc.c (shared with the fpga-xt C
// desktop).  Here we only convert between the editor's GObject model and the C
// AES OBJECT trees that rsc_read/rsc_write consume.

#import "GRsc.h"
#define RSC_NO_STATE_FLAGS      // GModel.h already provides OF_*/OS_*/BOX_ROUND_*
#import "rsc.h"
#import "GImage.h"

static NSString *NSStr(const char *c) {
    return c ? ([NSString stringWithCString:c encoding:NSISOLatin1StringEncoding] ?: @"") : @"";
}
// NUL-terminated Latin-1 copy into the resource's arena (owned by the RSC).
static char *dupLatin1(RSC *r, NSString *s) {
    NSData *d = [(s ?: @"") dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES] ?: [NSData data];
    char *tmp = malloc(d.length + 1);
    memcpy(tmp, d.bytes, d.length); tmp[d.length] = 0;
    char *owned = rsc_intern_str(r, tmp);
    free(tmp);
    return owned;
}
static int typeIsBox(int t)    { return t==G_BOX || t==G_IBOX || t==G_BOXCHAR; }
static int typeIsString(int t) { return t==G_STRING||t==G_BUTTON||t==G_TITLE||t==G_CHECKBOX||t==G_RADIO||t==G_POPUP; }
static int typeIsTed(int t)    { return t==G_TEXT||t==G_BOXTEXT||t==G_FTEXT||t==G_FBOXTEXT||t==G_FIELD; }
static int typeIsCicon(int t)  { return t==G_CICON || t==G_IMAGE; }

// ---- read: C OBJECT tree -> GObject --------------------------------------

static GObject *buildG(RSC_OBJECT *objs, int base, int rel, int nobj) {
    int idx = base + rel;
    if (idx < 0 || idx >= nobj) return nil;
    RSC_OBJECT *o = &objs[idx];
    GObject *g = [GObject new];
    int t = o->ob_type & 0xFF;
    g.type = (GObType)t;
    g.extType = (o->ob_type >> 8) & 0xFF;
    g.flags = (GFlags)o->ob_flags;
    g.state = (GState)o->ob_state;
    g.x = o->ob_x; g.y = o->ob_y; g.w = o->ob_w; g.h = o->ob_h;

    if (typeIsBox(t)) {
        uint32_t bw = RSC_OB_BOXWORD(o);
        GBox *b = [GBox new];
        b.character = (uint8_t)RSC_BOX_CHAR(bw);
        b.thickness = RSC_BOX_THICK(bw);
        b.color = gcw_unpack(RSC_BOX_COLOUR(bw));
        g.box = b;
    } else if (typeIsString(t)) {
        g.text = NSStr((const char *)o->ob_spec);
    } else if (typeIsTed(t)) {
        RSC_TEDINFO *cti = o->ob_spec;
        GTedinfo *ti = [GTedinfo new];
        if (cti) {
            ti.text = NSStr(cti->te_ptext); ti.tmplt = NSStr(cti->te_ptmplt); ti.valid = NSStr(cti->te_pvalid);
            ti.font = cti->te_font; ti.fontId = cti->te_fontid; ti.just = cti->te_just;
            ti.color = gcw_unpack((uint16_t)cti->te_color); ti.fontsize = cti->te_fontsize; ti.thickness = cti->te_thickness;
        }
        g.ted = ti;
    } else if (t == G_ICON) {
        RSC_ICONBLK *ib = o->ob_spec;
        GIcon *ic = [GIcon new]; ic.isColor = NO;
        if (ib) {
            ic.iconChar = ib->ib_char; ic.charX = ib->ib_xchar; ic.charY = ib->ib_ychar;
            ic.iconX = ib->ib_xicon; ic.iconY = ib->ib_yicon; ic.iconW = ib->ib_wicon; ic.iconH = ib->ib_hicon;
            ic.textX = ib->ib_xtext; ic.textY = ib->ib_ytext; ic.textW = ib->ib_wtext; ic.textH = ib->ib_htext;
            ic.label = NSStr(ib->ib_ptext);
            uint32_t bytes = (uint32_t)(((ib->ib_wicon + 15) / 16) * 2) * (ib->ib_hicon > 0 ? ib->ib_hicon : 0);
            if (ib->ib_pdata && bytes) ic.monoData = [NSData dataWithBytes:ib->ib_pdata length:bytes];
            if (ib->ib_pmask && bytes) ic.monoMask = [NSData dataWithBytes:ib->ib_pmask length:bytes];
        }
        g.icon = ic;
    } else if (typeIsCicon(t)) {
        RSC_CICON *ci = o->ob_spec;
        GIcon *ic = [GIcon new]; ic.isColor = YES;
        if (ci && ci->pam && ci->pam_len) ic.pam = [NSData dataWithBytes:ci->pam length:ci->pam_len];
        g.icon = ic;
    }

    int c = o->ob_head;
    if (c != RSC_NIL && base + c < nobj) {
        while (1) {
            GObject *child = buildG(objs, base, c, nobj);
            if (child) [g.children addObject:child];
            if (c == o->ob_tail) break;
            int cn = objs[base + c].ob_next;
            if (cn == RSC_NIL || base + cn >= nobj || cn == rel) break;
            c = cn;
        }
    }
    return g;
}

GResource *GRscRead(NSData *data, NSString **err) {
    const char *cerr = NULL;
    RSC *r = rsc_read(data.bytes, data.length, &cerr);
    if (!r) { if (err) *err = NSStr(cerr); return nil; }

    GResource *res = [GResource new];
    res.trees = [NSMutableArray array];
    res.bigEndian = YES; res.packedCoords = YES; res.charWidth = 8; res.charHeight = 16;
    int nobj = 0;
    RSC_OBJECT *objs = rsc_objects(r, &nobj);
    for (int i = 0; i < rsc_ntrees(r); i++) {
        RSC_OBJECT *root = rsc_tree(r, i);
        if (!root) continue;
        int base = (int)(root - objs);
        GTree *t = [GTree new];
        t.name = [NSString stringWithFormat:@"TREE%d", i];
        t.kind = GK_DIALOG;
        t.root = buildG(objs, base, 0, nobj);
        if (t.root) [res.trees addObject:t];
    }
    rsc_free(r);
    return res.trees.count ? res : nil;
}

// ---- write: GObject -> C OBJECT tree -------------------------------------

NSData *GRscWrite(GResource *res, NSString **err) {
    RSC *r = rsc_new();
    rsc_set_cell(r, res.charWidth ?: 8, res.charHeight ?: 16);

    for (GTree *tree in res.trees) {
        GFlatNode *flat = NULL;
        int n = [res flatten:tree into:&flat];
        int base = rsc_alloc_objects(r, n);
        rsc_add_tree(r, base);
        int nobj = 0; RSC_OBJECT *objs = rsc_objects(r, &nobj);   // valid until next alloc
        for (int i = 0; i < n; i++) {
            GObject *g = flat[i].obj;
            RSC_OBJECT *o = &objs[base + i];
            int t = g.type;
            o->ob_type  = (uint16_t)(((g.extType & 0xFF) << 8) | (t & 0xFF));
            o->ob_flags = g.flags;
            o->ob_state = g.state;
            o->ob_x = g.x; o->ob_y = g.y; o->ob_w = g.w; o->ob_h = g.h;
            o->ob_next = flat[i].next < 0 ? RSC_NIL : (int16_t)flat[i].next;
            o->ob_head = flat[i].head < 0 ? RSC_NIL : (int16_t)flat[i].head;
            o->ob_tail = flat[i].tail < 0 ? RSC_NIL : (int16_t)flat[i].tail;

            if (typeIsBox(t)) {
                GBox *b = g.box ?: [GBox new];
                o->ob_spec = (void *)(uintptr_t)RSC_BOXWORD(b.character, b.thickness, gcw_pack(b.color));
            } else if (typeIsString(t)) {
                o->ob_spec = dupLatin1(r, g.text);
            } else if (typeIsTed(t)) {
                GTedinfo *gt = g.ted ?: [GTedinfo new];
                RSC_TEDINFO *ti = rsc_new_tedinfo(r);
                ti->te_ptext = dupLatin1(r, gt.text); ti->te_ptmplt = dupLatin1(r, gt.tmplt); ti->te_pvalid = dupLatin1(r, gt.valid);
                ti->te_font = gt.font; ti->te_fontid = gt.fontId; ti->te_just = gt.just;
                ti->te_color = gcw_pack(gt.color); ti->te_fontsize = gt.fontsize; ti->te_thickness = gt.thickness;
                o->ob_spec = ti;
            } else if (t == G_ICON) {
                GIcon *gi = g.icon ?: [GIcon new];
                RSC_ICONBLK *ib = rsc_new_iconblk(r);
                ib->ib_char = gi.iconChar; ib->ib_xchar = gi.charX; ib->ib_ychar = gi.charY;
                ib->ib_xicon = gi.iconX; ib->ib_yicon = gi.iconY; ib->ib_wicon = gi.iconW; ib->ib_hicon = gi.iconH;
                ib->ib_xtext = gi.textX; ib->ib_ytext = gi.textY; ib->ib_wtext = gi.textW; ib->ib_htext = gi.textH;
                ib->ib_ptext = dupLatin1(r, gi.label);
                if (gi.monoData.length) ib->ib_pdata = rsc_intern_bytes(r, gi.monoData.bytes, (uint32_t)gi.monoData.length);
                if (gi.monoMask.length) ib->ib_pmask = rsc_intern_bytes(r, gi.monoMask.bytes, (uint32_t)gi.monoMask.length);
                o->ob_spec = ib;
            } else if (typeIsCicon(t)) {
                GIcon *gi = g.icon;
                RSC_CICON *ci = rsc_new_cicon(r);
                NSData *pam = gi.pam;
                if (!pam && gi.externalPath) pam = [NSData dataWithContentsOfFile:gi.externalPath];
                if (!pam) { NSImage *img = [gi image]; if (img) pam = GPAMFromImage(img); }
                if (pam.length) { ci->pam = rsc_intern_bytes(r, pam.bytes, (uint32_t)pam.length); ci->pam_len = (uint32_t)pam.length; }
                ci->text = dupLatin1(r, gi.label);
                o->ob_spec = ci;
            }
        }
        free(flat);
    }

    uint8_t *out = NULL; size_t olen = 0; const char *cerr = NULL;
    int rc = rsc_write(r, &out, &olen, &cerr);
    NSData *data = (rc == 0) ? [NSData dataWithBytes:out length:olen] : nil;
    free(out);
    rsc_free(r);
    if (rc && err) *err = NSStr(cerr ?: "write failed");
    return data;
}
