/* rsc.c — see rsc.h.  Portable C GEM .rsc reader/writer. */

#include "rsc.h"
#include <stdlib.h>
#include <string.h>

enum { SZ_OBJ = 24, SZ_TED = 28, SZ_IB = 34, SZ_HDR = 36 };

/* ---- arena (block list; pointers stay valid for the resource's lifetime) -- */
typedef struct ArenaBlock { struct ArenaBlock *next; size_t used, cap; } ArenaBlock;

struct RSC {
    RSC_OBJECT *obj;   int nobj, obj_cap;
    int32_t    *trees; int ntree, tree_cap;
    ArenaBlock *arena;
    int cell_w, cell_h;
};

static void *arena_alloc(RSC *r, size_t n) {
    n = (n + 7) & ~(size_t)7;
    ArenaBlock *b = r->arena;
    if (!b || b->used + n > b->cap) {
        size_t cap = n > 65536 ? n : 65536;
        b = (ArenaBlock *)malloc(sizeof(ArenaBlock) + cap);
        if (!b) return NULL;
        b->next = r->arena; b->used = 0; b->cap = cap;
        r->arena = b;
    }
    void *p = (uint8_t *)(b + 1) + b->used;
    b->used += n;
    memset(p, 0, n);
    return p;
}

/* ---- byte order (files are big-endian) ----------------------------------- */
static uint16_t rd16(const uint8_t *p, int be) {
    return be ? (uint16_t)((p[0] << 8) | p[1]) : (uint16_t)((p[1] << 8) | p[0]);
}
static uint32_t rd32(const uint8_t *p, int be) {
    return be ? ((uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3])
              : ((uint32_t)p[3]<<24 | (uint32_t)p[2]<<16 | (uint32_t)p[1]<<8 | p[0]);
}
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void wr32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v;
}

static int unpack_coord(uint16_t raw, int cell) {
    int lo = raw & 0xff; int hi = (int8_t)((raw >> 8) & 0xff);
    return lo * cell + hi;
}
static uint16_t pack_coord(int px, int cell) {
    if (cell <= 0) cell = 8;
    int chars = px / cell, extra = px - chars * cell;
    return (uint16_t)(((extra & 0xff) << 8) | (chars & 0xff));
}

/* exact byte length of a P7 PAM at offset (header + WIDTH*HEIGHT*DEPTH) */
static uint32_t pam_len(const uint8_t *p, size_t len, uint32_t off) {
    if (off + 2 >= len || p[off] != 'P' || p[off+1] != '7') return 0;
    size_t i = off + 2; int w = 0, h = 0, depth = 0;
    while (i < len) {
        size_t s = i; while (i < len && p[i] != '\n') i++;
        size_t n = i - s; const char *ln = (const char *)(p + s);
        if (i < len) i++;
        if      (n >= 6 && !memcmp(ln, "ENDHDR", 6)) break;
        else if (n >= 6 && !memcmp(ln, "WIDTH ",  6)) w     = atoi(ln + 6);
        else if (n >= 7 && !memcmp(ln, "HEIGHT ", 7)) h     = atoi(ln + 7);
        else if (n >= 6 && !memcmp(ln, "DEPTH ",  6)) depth = atoi(ln + 6);
    }
    if (w <= 0 || h <= 0 || depth <= 0) return 0;
    return (uint32_t)((i - off) + (size_t)w * h * depth);
}

/* type categories (low byte of ob_type) */
static int is_box(int t)    { return t==G_BOX || t==G_IBOX || t==G_BOXCHAR; }
static int is_string(int t) { return t==G_STRING||t==G_BUTTON||t==G_TITLE||t==G_CHECKBOX||t==G_RADIO||t==G_POPUP; }
static int is_ted(int t)    { return t==G_TEXT||t==G_BOXTEXT||t==G_FTEXT||t==G_FBOXTEXT||t==G_FIELD; }
static int is_cicon(int t)  { return t==G_CICON || t==G_IMAGE; }

static char *dup_cstr(RSC *r, const uint8_t *p, size_t len, uint32_t off) {
    if (off == 0 || off >= len) return arena_alloc(r, 1);   /* "" */
    uint32_t e = off; while (e < len && p[e]) e++;
    char *s = arena_alloc(r, e - off + 1);
    if (s) memcpy(s, p + off, e - off);
    return s;
}

/* ---- reader -------------------------------------------------------------- */

static RSC *try_parse(const uint8_t *p, size_t len, int be) {
    if (len < SZ_HDR) return NULL;
    uint16_t h[18];
    for (int i = 0; i < 18; i++) h[i] = rd16(p + i*2, be);
    uint32_t objBase = h[1], tedBase = h[2], ibBase = h[3], trindex = h[9];
    int nobs = h[10], ntree = h[11];
    uint16_t rssize = h[17];

    if (nobs <= 0 || nobs > 8000 || ntree <= 0 || ntree > 2000) return NULL;
    if (objBase < SZ_HDR || objBase >= len) return NULL;
    if (objBase + (size_t)nobs * SZ_OBJ > len) return NULL;
    if (trindex + (size_t)ntree * 4 > len) return NULL;
    if (rssize != 0 && rssize != len && rssize < objBase) return NULL;

    RSC *r = rsc_new();
    if (!r) return NULL;
    r->obj = (RSC_OBJECT *)calloc(nobs, sizeof(RSC_OBJECT));
    if (!r->obj) { rsc_free(r); return NULL; }
    r->nobj = r->obj_cap = nobs;
    int cw = r->cell_w, ch = r->cell_h;

    for (int i = 0; i < nobs; i++) {
        const uint8_t *o = p + objBase + (size_t)i * SZ_OBJ;
        RSC_OBJECT *g = &r->obj[i];
        g->ob_next  = (int16_t)rd16(o + 0, be);
        g->ob_head  = (int16_t)rd16(o + 2, be);
        g->ob_tail  = (int16_t)rd16(o + 4, be);
        g->ob_type  = rd16(o + 6, be);         /* keep both bytes */
        g->ob_flags = rd16(o + 8, be);
        g->ob_state = rd16(o + 10, be);
        uint32_t spec = rd32(o + 12, be);
        g->ob_x = (int16_t)unpack_coord(rd16(o + 16, be), cw);
        g->ob_y = (int16_t)unpack_coord(rd16(o + 18, be), ch);
        g->ob_w = (int16_t)unpack_coord(rd16(o + 20, be), cw);
        g->ob_h = (int16_t)unpack_coord(rd16(o + 22, be), ch);

        int t = g->ob_type & 0xFF;
        if (is_box(t)) {
            g->ob_spec = (void *)(uintptr_t)spec;               /* inline box word */
        } else if (is_string(t)) {
            g->ob_spec = dup_cstr(r, p, len, spec);
        } else if (is_ted(t)) {
            RSC_TEDINFO *ti = rsc_new_tedinfo(r);
            if (spec + SZ_TED <= len && ti) {
                const uint8_t *b = p + spec;
                ti->te_ptext  = dup_cstr(r, p, len, rd32(b + 0, be));
                ti->te_ptmplt = dup_cstr(r, p, len, rd32(b + 4, be));
                ti->te_pvalid = dup_cstr(r, p, len, rd32(b + 8, be));
                ti->te_font=(int16_t)rd16(b+12,be); ti->te_fontid=(int16_t)rd16(b+14,be);
                ti->te_just=(int16_t)rd16(b+16,be); ti->te_color=(int16_t)rd16(b+18,be);
                ti->te_fontsize=(int16_t)rd16(b+20,be); ti->te_thickness=(int16_t)rd16(b+22,be);
                ti->te_txtlen=(int16_t)rd16(b+24,be); ti->te_tmplen=(int16_t)rd16(b+26,be);
            }
            g->ob_spec = ti;
        } else if (t == G_ICON) {
            RSC_ICONBLK *ib = rsc_new_iconblk(r);
            if (spec + SZ_IB <= len && ib) {
                const uint8_t *b = p + spec;
                uint32_t pmask=rd32(b+0,be), pdata=rd32(b+4,be), ptext=rd32(b+8,be);
                ib->ib_char=(int16_t)rd16(b+12,be);
                ib->ib_xchar=(int16_t)rd16(b+14,be); ib->ib_ychar=(int16_t)rd16(b+16,be);
                ib->ib_xicon=(int16_t)rd16(b+18,be); ib->ib_yicon=(int16_t)rd16(b+20,be);
                ib->ib_wicon=(int16_t)rd16(b+22,be); ib->ib_hicon=(int16_t)rd16(b+24,be);
                ib->ib_xtext=(int16_t)rd16(b+26,be); ib->ib_ytext=(int16_t)rd16(b+28,be);
                ib->ib_wtext=(int16_t)rd16(b+30,be); ib->ib_htext=(int16_t)rd16(b+32,be);
                ib->ib_ptext = dup_cstr(r, p, len, ptext);
                uint32_t bytes = (uint32_t)(((ib->ib_wicon + 15) / 16) * 2) * (ib->ib_hicon > 0 ? ib->ib_hicon : 0);
                if (pdata && pdata + bytes <= len) ib->ib_pdata = rsc_intern_bytes(r, p + pdata, bytes);
                if (pmask && pmask + bytes <= len) ib->ib_pmask = rsc_intern_bytes(r, p + pmask, bytes);
            }
            g->ob_spec = ib;
        } else if (is_cicon(t)) {
            RSC_CICON *ci = rsc_new_cicon(r);
            uint32_t pl = pam_len(p, len, spec);
            if (pl && ci) { ci->pam = rsc_intern_bytes(r, p + spec, pl); ci->pam_len = pl; }
            g->ob_spec = ci;
        } else {
            g->ob_spec = NULL;
        }
        (void)tedBase; (void)ibBase;
    }

    for (int t = 0; t < ntree; t++) {
        uint32_t off = rd32(p + trindex + (size_t)t * 4, be);
        if (off < objBase || off >= objBase + (size_t)nobs * SZ_OBJ) continue;
        rsc_add_tree(r, (int)((off - objBase) / SZ_OBJ));
    }
    if (r->ntree == 0) { rsc_free(r); return NULL; }
    return r;
}

RSC *rsc_read(const uint8_t *data, size_t len, const char **err) {
    RSC *r = try_parse(data, len, 1);          /* big-endian (Atari) */
    if (!r) r = try_parse(data, len, 0);       /* little-endian fallback */
    if (!r && err) *err = "not a recognisable GEM .rsc (or unsupported extended format)";
    return r;
}

/* ---- writer -------------------------------------------------------------- */

/* small growable index tables */
typedef struct { void **items; int n, cap; } PtrVec;
static int pv_find(PtrVec *v, void *p) { for (int i=0;i<v->n;i++) if (v->items[i]==p) return i; return -1; }
static int pv_add(PtrVec *v, void *p) {
    if (v->n == v->cap) { v->cap = v->cap ? v->cap*2 : 16; v->items = realloc(v->items, v->cap*sizeof(void*)); }
    v->items[v->n] = p; return v->n++;
}
typedef struct { char **items; uint32_t *off; int n, cap; } StrVec;
static int sv_intern(StrVec *v, const char *s) {
    if (!s) s = "";
    for (int i=0;i<v->n;i++) if (!strcmp(v->items[i], s)) return i;
    if (v->n == v->cap) { v->cap = v->cap ? v->cap*2 : 16;
        v->items = realloc(v->items, v->cap*sizeof(char*)); v->off = realloc(v->off, v->cap*sizeof(uint32_t)); }
    v->items[v->n] = (char *)s; return v->n++;
}

int rsc_write(const RSC *r, uint8_t **out_p, size_t *out_len, const char **err) {
    int nobs = r->nobj, ntree = r->ntree;
    int cw = r->cell_w, ch = r->cell_h;

    StrVec strs = {0};
    PtrVec teds = {0}, ibs = {0}, cics = {0};
    /* image data (icon bitplanes + embedded PAMs), built up-front */
    uint8_t *imdata = NULL; uint32_t imlen = 0, imcap = 0;
    #define IM_APPEND(ptr, n) do { if (imlen + (n) > imcap) { imcap = (imlen + (n)) * 2 + 64; imdata = realloc(imdata, imcap); } \
        memcpy(imdata + imlen, (ptr), (n)); imlen += (n); } while (0)
    uint32_t *ib_data_off = NULL, *ib_mask_off = NULL, *cic_off = NULL;

    /* pass 1: collect */
    for (int i = 0; i < nobs; i++) {
        RSC_OBJECT *o = &r->obj[i];
        int t = o->ob_type & 0xFF;
        if (is_string(t)) sv_intern(&strs, (const char *)o->ob_spec);
        else if (is_ted(t) && o->ob_spec) {
            RSC_TEDINFO *ti = o->ob_spec;
            sv_intern(&strs, ti->te_ptext); sv_intern(&strs, ti->te_ptmplt); sv_intern(&strs, ti->te_pvalid);
            pv_add(&teds, ti);
        } else if (t == G_ICON && o->ob_spec) {
            RSC_ICONBLK *ib = o->ob_spec;
            sv_intern(&strs, ib->ib_ptext ? ib->ib_ptext : "");
            int idx = pv_add(&ibs, ib);
            ib_data_off = realloc(ib_data_off, ibs.cap*sizeof(uint32_t));
            ib_mask_off = realloc(ib_mask_off, ibs.cap*sizeof(uint32_t));
            uint32_t bytes = (uint32_t)(((ib->ib_wicon + 15) / 16) * 2) * (ib->ib_hicon > 0 ? ib->ib_hicon : 0);
            ib_data_off[idx] = imlen; if (ib->ib_pdata && bytes) IM_APPEND(ib->ib_pdata, bytes); else if (bytes) { uint8_t z=0; for(uint32_t k=0;k<bytes;k++) IM_APPEND(&z,1);}
            ib_mask_off[idx] = imlen; if (ib->ib_pmask && bytes) IM_APPEND(ib->ib_pmask, bytes); else if (bytes) IM_APPEND(imdata + ib_data_off[idx], bytes);
        } else if (is_cicon(t) && o->ob_spec) {
            RSC_CICON *ci = o->ob_spec;
            int idx = pv_add(&cics, ci);
            cic_off = realloc(cic_off, cics.cap*sizeof(uint32_t));
            cic_off[idx] = imlen;
            if (ci->pam && ci->pam_len) IM_APPEND(ci->pam, ci->pam_len);
        }
    }
    int nted = teds.n, nib = ibs.n;

    /* layout */
    uint32_t objBase = SZ_HDR;
    uint32_t tedBase = objBase + (uint32_t)nobs * SZ_OBJ;
    uint32_t ibBase  = tedBase + (uint32_t)nted * SZ_TED;
    uint32_t bbBase  = ibBase + (uint32_t)nib * SZ_IB;   /* nbb = 0 */
    uint32_t trindex = bbBase;
    uint32_t strBase = trindex + (uint32_t)ntree * 4;
    uint32_t cur = strBase;
    /* string data + offsets */
    uint32_t strbytes = 0;
    for (int i = 0; i < strs.n; i++) { strs.off[i] = cur; uint32_t l = (uint32_t)strlen(strs.items[i]) + 1; cur += l; strbytes += l; }
    uint32_t imBase = cur;
    uint32_t total = imBase + imlen;

    uint8_t *buf = (uint8_t *)calloc(total ? total : 1, 1);
    if (!buf) { if (err) *err = "out of memory"; goto fail; }

    /* header */
    uint16_t hdr[18] = {0};
    hdr[0]=0; hdr[1]=(uint16_t)objBase; hdr[2]=(uint16_t)tedBase; hdr[3]=(uint16_t)ibBase;
    hdr[4]=(uint16_t)bbBase; hdr[5]=(uint16_t)bbBase; hdr[6]=(uint16_t)strBase; hdr[7]=(uint16_t)imBase;
    hdr[8]=(uint16_t)bbBase; hdr[9]=(uint16_t)trindex; hdr[10]=(uint16_t)nobs; hdr[11]=(uint16_t)ntree;
    hdr[12]=(uint16_t)nted; hdr[13]=(uint16_t)nib; hdr[14]=0; hdr[15]=0; hdr[16]=0; hdr[17]=(uint16_t)total;
    for (int i=0;i<18;i++) wr16(buf + i*2, hdr[i]);

    /* objects */
    for (int i = 0; i < nobs; i++) {
        RSC_OBJECT *o = &r->obj[i];
        uint8_t *d = buf + objBase + (size_t)i * SZ_OBJ;
        uint16_t flags = o->ob_flags;
        if (i == nobs - 1) flags |= OF_LASTOB;
        wr16(d+0,(uint16_t)o->ob_next); wr16(d+2,(uint16_t)o->ob_head); wr16(d+4,(uint16_t)o->ob_tail);
        wr16(d+6,o->ob_type); wr16(d+8,flags); wr16(d+10,o->ob_state);
        int t = o->ob_type & 0xFF;
        uint32_t spec = 0;
        if (is_box(t)) spec = RSC_OB_BOXWORD(o);
        else if (is_string(t)) spec = strs.off[sv_intern(&strs, (const char *)o->ob_spec)];
        else if (is_ted(t)) spec = tedBase + (uint32_t)pv_find(&teds, o->ob_spec) * SZ_TED;
        else if (t == G_ICON) spec = ibBase + (uint32_t)pv_find(&ibs, o->ob_spec) * SZ_IB;
        else if (is_cicon(t)) { int k = pv_find(&cics, o->ob_spec); spec = k>=0 ? imBase + cic_off[k] : 0; }
        wr32(d+12, spec);
        wr16(d+16, pack_coord(o->ob_x, cw)); wr16(d+18, pack_coord(o->ob_y, ch));
        wr16(d+20, pack_coord(o->ob_w, cw)); wr16(d+22, pack_coord(o->ob_h, ch));
    }
    /* tedinfo */
    for (int i = 0; i < nted; i++) {
        RSC_TEDINFO *ti = teds.items[i];
        uint8_t *d = buf + tedBase + (size_t)i * SZ_TED;
        wr32(d+0, strs.off[sv_intern(&strs, ti->te_ptext)]);
        wr32(d+4, strs.off[sv_intern(&strs, ti->te_ptmplt)]);
        wr32(d+8, strs.off[sv_intern(&strs, ti->te_pvalid)]);
        wr16(d+12,(uint16_t)ti->te_font); wr16(d+14,(uint16_t)ti->te_fontid);
        wr16(d+16,(uint16_t)ti->te_just); wr16(d+18,(uint16_t)ti->te_color);
        wr16(d+20,(uint16_t)ti->te_fontsize); wr16(d+22,(uint16_t)ti->te_thickness);
        wr16(d+24,(uint16_t)(ti->te_ptext?strlen(ti->te_ptext)+1:1));
        wr16(d+26,(uint16_t)(ti->te_ptmplt?strlen(ti->te_ptmplt)+1:1));
    }
    /* iconblk */
    for (int i = 0; i < nib; i++) {
        RSC_ICONBLK *ib = ibs.items[i];
        uint8_t *d = buf + ibBase + (size_t)i * SZ_IB;
        wr32(d+0, ib_mask_off ? imBase + ib_mask_off[i] : 0);
        wr32(d+4, ib_data_off ? imBase + ib_data_off[i] : 0);
        wr32(d+8, strs.off[sv_intern(&strs, ib->ib_ptext ? ib->ib_ptext : "")]);
        wr16(d+12,(uint16_t)ib->ib_char);
        wr16(d+14,(uint16_t)ib->ib_xchar); wr16(d+16,(uint16_t)ib->ib_ychar);
        wr16(d+18,(uint16_t)ib->ib_xicon); wr16(d+20,(uint16_t)ib->ib_yicon);
        wr16(d+22,(uint16_t)ib->ib_wicon); wr16(d+24,(uint16_t)ib->ib_hicon);
        wr16(d+26,(uint16_t)ib->ib_xtext); wr16(d+28,(uint16_t)ib->ib_ytext);
        wr16(d+30,(uint16_t)ib->ib_wtext); wr16(d+32,(uint16_t)ib->ib_htext);
    }
    /* tree index */
    for (int i = 0; i < ntree; i++) wr32(buf + trindex + (size_t)i * 4, objBase + (uint32_t)r->trees[i] * SZ_OBJ);
    /* string data */
    for (int i = 0; i < strs.n; i++) { size_t l = strlen(strs.items[i]) + 1; memcpy(buf + strs.off[i], strs.items[i], l); }
    /* image data */
    if (imlen) memcpy(buf + imBase, imdata, imlen);

    *out_p = buf; *out_len = total;
    free(strs.items); free(strs.off); free(teds.items); free(ibs.items); free(cics.items);
    free(imdata); free(ib_data_off); free(ib_mask_off); free(cic_off);
    (void)strbytes;
    return 0;
fail:
    free(strs.items); free(strs.off); free(teds.items); free(ibs.items); free(cics.items);
    free(imdata); free(ib_data_off); free(ib_mask_off); free(cic_off);
    return 1;
}

/* ---- lifecycle + builders ------------------------------------------------ */

RSC *rsc_new(void) {
    RSC *r = (RSC *)calloc(1, sizeof(RSC));
    if (r) { r->cell_w = 8; r->cell_h = 16; }
    return r;
}
void rsc_free(RSC *r) {
    if (!r) return;
    ArenaBlock *b = r->arena;
    while (b) { ArenaBlock *n = b->next; free(b); b = n; }
    free(r->obj); free(r->trees); free(r);
}
void rsc_set_cell(RSC *r, int cw, int ch) { r->cell_w = cw > 0 ? cw : 8; r->cell_h = ch > 0 ? ch : 16; }

int rsc_ntrees(const RSC *r) { return r->ntree; }
RSC_OBJECT *rsc_tree(const RSC *r, int i) {
    return (i >= 0 && i < r->ntree && r->trees[i] < r->nobj) ? &r->obj[r->trees[i]] : NULL;
}
RSC_OBJECT *rsc_objects(const RSC *r, int *count_out) { if (count_out) *count_out = r->nobj; return r->obj; }

int rsc_alloc_objects(RSC *r, int n) {
    int base = r->nobj;
    if (base + n > r->obj_cap) {
        int cap = (base + n) > r->obj_cap*2 ? (base + n) : (r->obj_cap ? r->obj_cap*2 : 16);
        r->obj = realloc(r->obj, cap * sizeof(RSC_OBJECT)); r->obj_cap = cap;
    }
    memset(r->obj + base, 0, n * sizeof(RSC_OBJECT));
    r->nobj = base + n;
    return base;
}
int rsc_add_tree(RSC *r, int root) {
    if (r->ntree == r->tree_cap) { r->tree_cap = r->tree_cap ? r->tree_cap*2 : 8;
        r->trees = realloc(r->trees, r->tree_cap * sizeof(int32_t)); }
    r->trees[r->ntree] = root;
    return r->ntree++;
}
char *rsc_intern_str(RSC *r, const char *s) {
    if (!s) s = "";
    size_t l = strlen(s) + 1; char *d = arena_alloc(r, l);
    if (d) memcpy(d, s, l);
    return d;
}
uint8_t *rsc_intern_bytes(RSC *r, const uint8_t *b, uint32_t n) {
    uint8_t *d = arena_alloc(r, n ? n : 1);
    if (d && n) memcpy(d, b, n);
    return d;
}
RSC_TEDINFO *rsc_new_tedinfo(RSC *r) { RSC_TEDINFO *t = arena_alloc(r, sizeof *t);
    if (t) { t->te_ptext = t->te_ptmplt = t->te_pvalid = arena_alloc(r, 1); } return t; }
RSC_ICONBLK *rsc_new_iconblk(RSC *r) { return arena_alloc(r, sizeof(RSC_ICONBLK)); }
RSC_CICON   *rsc_new_cicon(RSC *r)   { return arena_alloc(r, sizeof(RSC_CICON)); }
