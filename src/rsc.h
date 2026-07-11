/* rsc.h — portable GEM .rsc reader/writer (pure C, no dependencies).
 *
 * One implementation shared by the Rocks editor (Objective-C wraps this) and
 * the fpga-xt/gem C desktop, so both read and write byte-identical files.
 *
 * On disk the format is classic big-endian GEM (RSHDR + OBJECT + TEDINFO +
 * ICONBLK + strings + tree index) with a few documented extensions (see
 * RSC-FORMAT.md): extended widget types (G_CHECKBOX..G_CICON), colour icons /
 * images as embedded P7 PAM, and use of the ob_type high byte.
 *
 * In memory the OBJECT trees are "loaded" the way the AES expects: ob_spec is a
 * resolved pointer (char* / TEDINFO* / ICONBLK* / CICON*, or an inline box word),
 * ob_head/ob_tail/ob_next are indices relative to each tree's root, and
 * coordinates are in pixels. rsc_read owns all memory; rsc_free releases it.
 *
 * Only <stdint.h>/<stddef.h>/<stdlib.h>/<string.h> are used, so this compiles on
 * the host and the target unchanged. It does NOT decode/encode PAM pixels or
 * draw anything — it only moves bytes between disk and OBJECT trees.
 *
 * ---- Integration ---------------------------------------------------------
 *   Add rsc.c + rsc.h to your build.  If you already have an AES header that
 *   defines OF_/OS_/BOX_ROUND_ and the G_ object types, #define
 *   RSC_NO_STATE_FLAGS (and provide a `G_BOX` macro) before including rsc.h so
 *   the duplicates are skipped; then treat RSC_OBJECT as your OBJECT (its field
 *   layout matches AES aes.h: ob_w/ob_h, void* ob_spec).
 *
 * ---- Reading -------------------------------------------------------------
 *   const char *err = NULL;
 *   RSC *r = rsc_read(file_bytes, file_len, &err);   // NULL + err on failure
 *   if (r) {
 *       RSC_OBJECT *tree = rsc_tree(r, 0);           // root of tree 0
 *       // Walk it like the AES: indices are relative to the tree root, so
 *       // children are tree[tree[obj].ob_head], siblings via .ob_next, until
 *       // .ob_tail.  ob_spec is already a pointer (char* / RSC_TEDINFO* / ...).
 *       for (int c = tree->ob_head; c != RSC_NIL; c = tree[c].ob_next) {
 *           RSC_OBJECT *o = &tree[c];
 *           if ((o->ob_type & 0xFF) == G_STRING) puts((char *)o->ob_spec);
 *           if (c == tree->ob_tail) break;
 *       }
 *       rsc_free(r);                                 // frees everything
 *   }
 *
 * ---- Writing (building a resource) ---------------------------------------
 *   RSC *r = rsc_new();
 *   int base = rsc_alloc_objects(r, 2);              // root + one child
 *   rsc_add_tree(r, base);                           // tree 0 roots at `base`
 *   RSC_OBJECT *o = rsc_objects(r, NULL);            // re-fetch after any alloc
 *   o[base+0] = (RSC_OBJECT){ RSC_NIL, 1, 1, G_BOX, 0, OS_NORMAL,
 *                             (void*)(uintptr_t)RSC_BOXWORD(0,2,0x1100), 0,0,320,200 };
 *   o[base+1] = (RSC_OBJECT){ 0, RSC_NIL, RSC_NIL, G_STRING, OF_LASTOB, OS_NORMAL,
 *                             rsc_intern_str(r,"Hello"), 16,10,120,16 };
 *   uint8_t *bytes; size_t len; const char *err;
 *   if (rsc_write(r, &bytes, &len, &err) == 0) { fwrite(bytes,1,len,f); free(bytes); }
 *   rsc_free(r);
 *
 * Notes: ob_head/ob_tail/ob_next are indices RELATIVE to the tree root (0-based
 * within the tree, contiguous).  rsc_alloc_objects may realloc the object array,
 * so fetch the pointer with rsc_objects() AFTER the last allocation.  Strings and
 * sub-structures must come from the rsc_intern_ and rsc_new_ helpers (arena-
 * owned) so they outlive the call.  Coordinates are pixels; packing uses an 8x16 cell by
 * default (rsc_set_cell to change).
 */
#ifndef RSC_H
#define RSC_H

#include <stdint.h>
#include <stddef.h>

/* ---- object types / flags / states (classic + fpga-xt extensions) -------- */
#ifndef G_BOX
enum { G_BOX = 20, G_TEXT = 21, G_BOXTEXT = 22, G_IMAGE = 23, G_USERDEF = 24,
       G_IBOX = 25, G_BUTTON = 26, G_BOXCHAR = 27, G_STRING = 28, G_FTEXT = 29,
       G_FBOXTEXT = 30, G_ICON = 31, G_TITLE = 32,
       G_CHECKBOX = 40, G_RADIO = 41, G_POPUP = 42, G_FIELD = 43, G_CICON = 44 };
#endif
/* Flag/state constants.  Define RSC_NO_STATE_FLAGS before including this header
 * if your project already provides the OF_, OS_ and BOX_ROUND_ constants (e.g.
 * from an AES header), to avoid a redefinition. */
#ifndef RSC_NO_STATE_FLAGS
enum { OF_NONE = 0x00, OF_SELECTABLE = 0x01, OF_DEFAULT = 0x02, OF_EXIT = 0x04,
       OF_EDITABLE = 0x08, OF_RBUTTON = 0x10, OF_LASTOB = 0x20, OF_TOUCHEXIT = 0x40,
       OF_HIDETREE = 0x80,
       /* fpga-xt/gem runtime extensions (reuse freed 3D-flag bit positions): */
       OF_CANCEL = 0x200,     /* Esc fires this object (Cancel affordance)      */
       OF_MOVEABLE = 0x400 }; /* on the tree ROOT: the dialog is movable        */
enum { OS_NORMAL = 0x00, OS_SELECTED = 0x01, OS_CROSSED = 0x02, OS_CHECKED = 0x04,
       OS_DISABLED = 0x08, OS_OUTLINED = 0x10, OS_SHADOWED = 0x20,
       OS_WHITEBAK = 0x40 };  /* mnemonic present; bits 8-14 = shortcut char idx */
/* ob_type high byte (extended byte): per-corner box rounding */
enum { BOX_ROUND_TL = 0x10, BOX_ROUND_TR = 0x20, BOX_ROUND_BR = 0x40, BOX_ROUND_BL = 0x80 };
#endif
/* mnemonic index accessor (valid when OS_WHITEBAK is set) */
#define RSC_WB_INDEX(state) (((state) >> 8) & 0x7F)

#define RSC_NIL (-1)

/* ---- resource sub-structures (in memory; pointers resolved) --------------- */

typedef struct {
    char   *te_ptext, *te_ptmplt, *te_pvalid;
    int16_t te_font, te_fontid, te_just, te_color, te_fontsize, te_thickness;
    int16_t te_txtlen, te_tmplen;
} RSC_TEDINFO;

typedef struct {
    uint8_t *ib_pmask, *ib_pdata;   /* bitplane data (may be NULL) */
    char    *ib_ptext;
    int16_t  ib_char, ib_xchar, ib_ychar;
    int16_t  ib_xicon, ib_yicon, ib_wicon, ib_hicon;
    int16_t  ib_xtext, ib_ytext, ib_wtext, ib_htext;
} RSC_ICONBLK;

/* Rocks extension: a colour icon/image stored as a self-delimiting P7 PAM. */
typedef struct {
    uint8_t *pam;       /* embedded PAM bytes (NULL if none) */
    uint32_t pam_len;
    char    *text;      /* optional label */
} RSC_CICON;

/* ---- the AES OBJECT (in-memory layout) ----------------------------------- */
/* Field names match fpga-xt/gem aes.h so the desktop can use these directly. */
typedef struct {
    int16_t  ob_next, ob_head, ob_tail;  /* indices relative to the tree root */
    uint16_t ob_type;                    /* low byte = G_*, high byte = extended */
    uint16_t ob_flags;
    uint16_t ob_state;
    void    *ob_spec;                    /* char* | RSC_TEDINFO* | RSC_ICONBLK* |
                                            RSC_CICON* | inline box word (see below) */
    int16_t  ob_x, ob_y, ob_w, ob_h;     /* pixels */
} RSC_OBJECT;

/* For G_BOX / G_IBOX / G_BOXCHAR, ob_spec is an inline 32-bit "box word":
 * (character<<24) | (thickness<<16) | colour_word. Use these to pack/unpack. */
#define RSC_BOXWORD(ch, thick, colour) \
    (((uint32_t)((ch) & 0xFF) << 24) | ((uint32_t)((thick) & 0xFF) << 16) | ((colour) & 0xFFFF))
#define RSC_BOX_CHAR(w)    (((uint32_t)(w) >> 24) & 0xFF)
#define RSC_BOX_THICK(w)   ((int8_t)(((uint32_t)(w) >> 16) & 0xFF))
#define RSC_BOX_COLOUR(w)  ((uint16_t)((uint32_t)(w) & 0xFFFF))
#define RSC_OB_BOXWORD(o)  ((uint32_t)(uintptr_t)(o)->ob_spec)

/* ---- the loaded resource ------------------------------------------------- */
typedef struct RSC RSC;   /* opaque; owns all memory */

/* Parse a big-endian classic-or-extended .rsc image (little-endian tolerated on
 * read). Returns a handle, or NULL with *err set (err may be NULL). */
RSC *rsc_read(const uint8_t *data, size_t len, const char **err);

int          rsc_ntrees(const RSC *r);
RSC_OBJECT  *rsc_tree(const RSC *r, int index);   /* root OBJECT of tree `index` */
RSC_OBJECT  *rsc_objects(const RSC *r, int *count_out);  /* the flat array */

/* Serialize to a big-endian .rsc image (classic layout + extensions). Allocates
 * *out (caller free()s it). Returns 0 on success, non-zero on error. */
int  rsc_write(const RSC *r, uint8_t **out, size_t *len, const char **err);

void rsc_free(RSC *r);

/* ---- building a resource programmatically (used by the editor bridge) ----- */
/* Create an empty resource. */
RSC *rsc_new(void);
/* Allocate `n` zeroed OBJECTs owned by the resource; returns the base index. */
int  rsc_alloc_objects(RSC *r, int n);
/* Register object index `root` as tree number returned. */
int  rsc_add_tree(RSC *r, int root);
/* Copy a string / bytes into the resource's arena (returns an owned pointer). */
char    *rsc_intern_str(RSC *r, const char *s);
uint8_t *rsc_intern_bytes(RSC *r, const uint8_t *b, uint32_t n);
/* Allocate a zeroed sub-structure in the arena. */
RSC_TEDINFO *rsc_new_tedinfo(RSC *r);
RSC_ICONBLK *rsc_new_iconblk(RSC *r);
RSC_CICON   *rsc_new_cicon(RSC *r);

/* Coordinate cell used when packing/unpacking (default 8×16). */
void rsc_set_cell(RSC *r, int cw, int ch);

#endif /* RSC_H */
