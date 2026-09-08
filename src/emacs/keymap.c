/*
 * keymap.c -- see keymap.h.
 */

#include "keymap.h"

#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * Key encoding
 * ------------------------------------------------------------------ */

ck_key ck_key_make(uint16_t code, uint32_t mods)
{
    mods &= CK_MOD_MASK;

    if ((mods & CK_MOD_CTRL) != 0 && code >= 'A' && code <= 'Z')
        code = (uint16_t)(code - 'A' + 'a');

    /* Shift on a printable character is already expressed by the character
     * ('<' is not S-','), so keeping the bit would give one keystroke two
     * spellings and make `M-<' unbindable. */
    if (code >= 0x20 && code <= 0xFF)
        mods &= ~(uint32_t)CK_MOD_SHIFT;

    return (ck_key)code | mods;
}

struct named_key {
    const char *name;
    uint16_t    code;
};

/* Spelling table.  The first entry for a code is the one printed; later
 * entries are accepted aliases. */
static const struct named_key ck_named_keys[] = {
    { "SPC",       CK_KEY_SPACE },
    { "TAB",       CK_KEY_TAB },
    { "RET",       CK_KEY_RETURN },
    { "ESC",       CK_KEY_ESC },
    { "DEL",       CK_KEY_DELETE },
    { "BS",        CK_KEY_BACKSPACE },
    { "<up>",      CK_KEY_UP },
    { "<down>",    CK_KEY_DOWN },
    { "<left>",    CK_KEY_LEFT },
    { "<right>",   CK_KEY_RIGHT },
    { "<home>",    CK_KEY_HOME },
    { "<end>",     CK_KEY_END },
    { "<prior>",   CK_KEY_PAGEUP },
    { "<next>",    CK_KEY_PAGEDOWN },
    { "<pageup>",  CK_KEY_PAGEUP },
    { "<pagedown>",CK_KEY_PAGEDOWN },
    { "<insert>",  CK_KEY_INSERT },
    { "<help>",    CK_KEY_HELP },
    { "<f1>",      CK_KEY_F1 + 0 },
    { "<f2>",      CK_KEY_F1 + 1 },
    { "<f3>",      CK_KEY_F1 + 2 },
    { "<f4>",      CK_KEY_F1 + 3 },
    { "<f5>",      CK_KEY_F1 + 4 },
    { "<f6>",      CK_KEY_F1 + 5 },
    { "<f7>",      CK_KEY_F1 + 6 },
    { "<f8>",      CK_KEY_F1 + 7 },
    { "<f9>",      CK_KEY_F1 + 8 },
    { "<f10>",     CK_KEY_F1 + 9 },
    { NULL,        0 }
};

static const char *ck_key_code_name(uint16_t code)
{
    int32_t i;
    for (i = 0; ck_named_keys[i].name != NULL; i++) {
        if (ck_named_keys[i].code == code)
            return ck_named_keys[i].name;
    }
    return NULL;
}

char *ck_key_to_string(ck_key key, char *buf, int32_t size)
{
    uint16_t    code = CK_KEY_CODE(key);
    uint32_t    mods = CK_KEY_MODS(key);
    const char *name;
    int32_t     n = 0;

    if (buf == NULL || size <= 0)
        return buf;
    buf[0] = '\0';
    if (key == CK_KEY_NONE)
        return buf;

#define PUT(str) do { \
        const char *_s = (str); \
        while (*_s != '\0' && n < size - 1) buf[n++] = *_s++; \
    } while (0)

    if ((mods & CK_MOD_CTRL) != 0)  PUT("C-");
    if ((mods & CK_MOD_META) != 0)  PUT("M-");
    if ((mods & CK_MOD_SHIFT) != 0) PUT("S-");

    name = ck_key_code_name(code);
    if (name != NULL) {
        PUT(name);
    } else if (code >= 0x20 && code <= 0xFF) {
        if (n < size - 1)
            buf[n++] = (char)code;
    } else {
        /* A control character with no name.  Print it the way Emacs does
         * when it has no better spelling. */
        char tmp[8];
        tmp[0] = '<'; tmp[1] = '?'; tmp[2] = '>'; tmp[3] = '\0';
        PUT(tmp);
    }

#undef PUT

    buf[n] = '\0';
    return buf;
}

ck_key ck_key_from_string(const char *text)
{
    uint32_t mods = 0;
    int32_t  i;

    if (text == NULL || text[0] == '\0')
        return CK_KEY_NONE;

    /* Modifier prefixes.  The trailing length test keeps "C--" (control and
     * minus) and a bare "-" working. */
    while (text[0] != '\0' && text[1] == '-' && text[2] != '\0') {
        if      (text[0] == 'C') mods |= CK_MOD_CTRL;
        else if (text[0] == 'M') mods |= CK_MOD_META;
        else if (text[0] == 'S') mods |= CK_MOD_SHIFT;
        else break;
        text += 2;
    }

    for (i = 0; ck_named_keys[i].name != NULL; i++) {
        if (strcmp(text, ck_named_keys[i].name) == 0)
            return ck_key_make(ck_named_keys[i].code, mods);
    }

    if (text[0] != '\0' && text[1] == '\0')
        return ck_key_make((uint16_t)(unsigned char)text[0], mods);

    return CK_KEY_NONE;
}

/* ------------------------------------------------------------------ *
 * Keymaps
 *
 * A keymap is a sorted array searched by bisection.  Phase-1 maps hold a
 * few dozen entries at most, so the array costs one allocation and the
 * lookup is a handful of comparisons -- which matters on a 14 MHz 68020,
 * where this runs on every keystroke before the class sees it.
 * ------------------------------------------------------------------ */

ck_keymap *ck_keymap_new(const char *name)
{
    ck_keymap *map = (ck_keymap *)malloc(sizeof(ck_keymap));
    if (map == NULL)
        return NULL;
    map->name    = name;
    map->entries = NULL;
    map->count   = 0;
    map->cap     = 0;
    return map;
}

void ck_keymap_free(ck_keymap *map)
{
    int32_t i;

    if (map == NULL)
        return;
    for (i = 0; i < map->count; i++) {
        /* Only maps this map created itself (through ck_keymap_bind_seq) are
         * owned here.  A map handed in by ck_keymap_bind_map belongs to the
         * caller, who may well have bound it in two places. */
        if (map->entries[i].kind == CK_BIND_KEYMAP && map->entries[i].owned)
            ck_keymap_free(map->entries[i].map);
    }
    free(map->entries);
    free(map);
}

/* Index of KEY, or the insertion point with *found = 0. */
static int32_t ck_keymap_find(const ck_keymap *map, ck_key key, int32_t *found)
{
    int32_t lo = 0, hi = map->count;

    *found = 0;
    while (lo < hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (map->entries[mid].key == key) {
            *found = 1;
            return mid;
        }
        if (map->entries[mid].key < key)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

static ck_keyentry *ck_keymap_slot(ck_keymap *map, ck_key key)
{
    int32_t found, at;

    at = ck_keymap_find(map, key, &found);
    if (found)
        return &map->entries[at];

    if (map->count == map->cap) {
        int32_t      cap = (map->cap == 0) ? 16 : map->cap * 2;
        ck_keyentry *grown =
            (ck_keyentry *)realloc(map->entries, (size_t)cap * sizeof(ck_keyentry));
        if (grown == NULL)
            return NULL;
        map->entries = grown;
        map->cap     = cap;
    }

    memmove(&map->entries[at + 1], &map->entries[at],
            (size_t)(map->count - at) * sizeof(ck_keyentry));
    map->count++;
    map->entries[at].key     = key;
    map->entries[at].kind    = CK_BIND_NONE;
    map->entries[at].owned   = 0;
    map->entries[at].command = -1;
    map->entries[at].map     = NULL;
    return &map->entries[at];
}

int ck_keymap_bind(ck_keymap *map, ck_key key, int16_t command)
{
    ck_keyentry *e;

    if (map == NULL || key == CK_KEY_NONE)
        return -1;
    e = ck_keymap_slot(map, key);
    if (e == NULL)
        return -1;
    if (e->kind == CK_BIND_KEYMAP && e->owned)
        ck_keymap_free(e->map);
    e->kind    = CK_BIND_COMMAND;
    e->owned   = 0;
    e->command = command;
    e->map     = NULL;
    return 0;
}

int ck_keymap_bind_map(ck_keymap *map, ck_key key, ck_keymap *sub)
{
    ck_keyentry *e;

    if (map == NULL || sub == NULL || key == CK_KEY_NONE)
        return -1;
    e = ck_keymap_slot(map, key);
    if (e == NULL)
        return -1;
    if (e->kind == CK_BIND_KEYMAP && e->owned && e->map != sub)
        ck_keymap_free(e->map);
    e->kind    = CK_BIND_KEYMAP;
    e->owned   = 0;
    e->command = -1;
    e->map     = sub;
    return 0;
}

const ck_keyentry *ck_keymap_lookup(const ck_keymap *map, ck_key key)
{
    int32_t found, at;

    if (map == NULL)
        return NULL;
    at = ck_keymap_find(map, key, &found);
    if (!found)
        return NULL;
    if (map->entries[at].kind == CK_BIND_NONE)
        return NULL;
    return &map->entries[at];
}

int ck_keymap_bind_seq(ck_keymap *map, const char *keys, int16_t command)
{
    char        spelling[32];
    const char *p = keys;
    ck_keymap  *cur = map;

    if (map == NULL || keys == NULL)
        return -1;

    for (;;) {
        const char *start;
        int32_t     len;
        ck_key      key;

        while (*p == ' ')
            p++;
        if (*p == '\0')
            return -1;              /* trailing separator, no key */

        start = p;
        while (*p != '\0' && *p != ' ')
            p++;
        len = (int32_t)(p - start);
        if (len <= 0 || len >= (int32_t)sizeof(spelling))
            return -1;
        memcpy(spelling, start, (size_t)len);
        spelling[len] = '\0';

        key = ck_key_from_string(spelling);
        if (key == CK_KEY_NONE)
            return -1;

        while (*p == ' ')
            p++;

        if (*p == '\0')
            return ck_keymap_bind(cur, key, command);

        /* More keys follow: KEY must name a prefix map. */
        {
            const ck_keyentry *e = ck_keymap_lookup(cur, key);
            if (e != NULL && e->kind == CK_BIND_KEYMAP) {
                cur = e->map;
            } else {
                ck_keymap  *sub = ck_keymap_new(cur->name);
                ck_keyentry *slot;
                if (sub == NULL)
                    return -1;
                if (ck_keymap_bind_map(cur, key, sub) != 0) {
                    ck_keymap_free(sub);
                    return -1;
                }
                /* Created here, so this map frees it -- unlike a map the
                 * caller bound with ck_keymap_bind_map. */
                slot = ck_keymap_slot(cur, key);
                if (slot != NULL)
                    slot->owned = 1;
                cur = sub;
            }
        }
    }
}

/* ------------------------------------------------------------------ *
 * The key state machine
 * ------------------------------------------------------------------ */

void ck_keystate_init(ck_keystate *st, ck_keymap *global, ck_keymap *local)
{
    memset(st, 0, sizeof(*st));
    st->global = global;
    st->local  = local;
}

static void ck_keystate_reset_seq(ck_keystate *st)
{
    st->pending        = NULL;
    st->pending_global = NULL;
    st->in_prefix      = 0;
    st->seqlen         = 0;
    st->meta_pending   = 0;
}

static void ck_keystate_reset_arg(ck_keystate *st)
{
    st->arg          = 0;
    st->arg_valid    = 0;
    st->arg_reading  = 0;
    st->arg_negative = 0;
}

void ck_keystate_reset(ck_keystate *st)
{
    ck_keystate_reset_seq(st);
    ck_keystate_reset_arg(st);
}

static void ck_keystate_push(ck_keystate *st, ck_key key)
{
    if (st->seqlen < CK_MAX_SEQ)
        st->seq[st->seqlen++] = key;
}

ck_keyresult ck_keystate_feed(ck_keystate *st, ck_key key, int16_t *command_out)
{
    const ck_keyentry *entry = NULL;
    uint16_t           code;

    if (st == NULL || key == CK_KEY_NONE)
        return CK_KEY_UNBOUND;

    /* ESC is a Meta prefix as well as Alt, for keyboards and users where Alt
     * is awkward or is eaten by the window manager. */
    if (st->meta_pending) {
        st->meta_pending = 0;
        key = ck_key_make(CK_KEY_CODE(key), CK_KEY_MODS(key) | CK_MOD_META);
    } else if (key == (ck_key)CK_KEY_ESC) {
        st->meta_pending = 1;
        return CK_KEY_PREFIX;
    }

    code = CK_KEY_CODE(key);

    /* C-g abandons whatever is half-typed.  With nothing pending it falls
     * through so keyboard-quit itself can run (clear the region, close the
     * minibuffer). */
    if (key == (ck_key)('g' | CK_MOD_CTRL)) {
        if (st->in_prefix || st->seqlen > 0 || st->arg_valid) {
            ck_keystate_reset(st);
            return CK_KEY_CANCEL;
        }
    }

    /* --- the C-u numeric argument ---------------------------------- *
     * Only at top level: inside a prefix map a digit is a key like any
     * other (`C-x 2' must not be read as an argument). */
    if (!st->in_prefix) {
        if (key == (ck_key)('u' | CK_MOD_CTRL)) {
            /* C-u, C-u C-u, ... multiply by four; digits after a C-u
             * replace the accumulated value, as in Emacs. */
            st->arg         = st->arg_valid ? st->arg * 4 : 4;
            st->arg_valid   = 1;
            st->arg_reading = 0;
            return CK_KEY_ARG;
        }

        if (st->arg_valid &&
            (CK_KEY_MODS(key) == 0 || CK_KEY_MODS(key) == CK_MOD_META)) {
            if (code >= '0' && code <= '9') {
                if (st->arg_reading) {
                    st->arg = st->arg * 10 + (int32_t)(code - '0');
                } else {
                    st->arg         = (int32_t)(code - '0');
                    st->arg_reading = 1;
                }
                return CK_KEY_ARG;
            }
            if (code == '-' && !st->arg_reading && !st->arg_negative) {
                st->arg_negative = 1;
                st->arg          = 1;
                return CK_KEY_ARG;
            }
        }

        /* M-1 .. M-9 and M-- start an argument without a preceding C-u. */
        if (!st->arg_valid && CK_KEY_MODS(key) == CK_MOD_META) {
            if (code >= '0' && code <= '9') {
                st->arg         = (int32_t)(code - '0');
                st->arg_valid   = 1;
                st->arg_reading = 1;
                return CK_KEY_ARG;
            }
            if (code == '-') {
                st->arg          = 1;
                st->arg_valid    = 1;
                st->arg_negative = 1;
                return CK_KEY_ARG;
            }
        }
    }

    /* --- binding lookup -------------------------------------------- *
     * Both sides are consulted at every step, not just the first: local
     * wins where it has something, and the global map still answers for the
     * keys the local map leaves alone -- including inside a prefix the two
     * share. */
    {
        const ck_keyentry *local_entry  = NULL;
        const ck_keyentry *global_entry = NULL;

        if (st->in_prefix) {
            if (st->pending != NULL)
                local_entry = ck_keymap_lookup(st->pending, key);
            if (st->pending_global != NULL)
                global_entry = ck_keymap_lookup(st->pending_global, key);
        } else {
            if (st->local != NULL)
                local_entry = ck_keymap_lookup(st->local, key);
            global_entry = ck_keymap_lookup(st->global, key);
        }

        entry = (local_entry != NULL) ? local_entry : global_entry;

        if (entry == NULL) {
            int32_t was_prefix = st->in_prefix;
            ck_keystate_push(st, key);
            st->last_arg       = 1;
            st->last_arg_given = 0;
            ck_keystate_reset(st);
            /* `C-x C-q' with nothing bound: the sequence is ours and it is
             * undefined.  The caller reports it; the key must not reach the
             * superclass, or C-x C-q would insert a `q'. */
            return was_prefix ? CK_KEY_UNDEFINED : CK_KEY_UNBOUND;
        }

        ck_keystate_push(st, key);

        if (entry->kind == CK_BIND_KEYMAP) {
            st->pending = (local_entry != NULL &&
                           local_entry->kind == CK_BIND_KEYMAP)
                              ? local_entry->map : NULL;
            st->pending_global = (global_entry != NULL &&
                                  global_entry->kind == CK_BIND_KEYMAP)
                                     ? global_entry->map : NULL;
            st->in_prefix = 1;
            return CK_KEY_PREFIX;
        }
    }

    /* Hand the argument to the command that was just resolved, and clear it
     * here rather than trusting every caller to consume it. */
    st->last_arg       = st->arg_valid ? (st->arg_negative ? -st->arg : st->arg) : 1;
    st->last_arg_given = st->arg_valid;
    ck_keystate_reset(st);

    if (command_out != NULL)
        *command_out = entry->command;
    return CK_KEY_COMMAND;
}

char *ck_keystate_describe(const ck_keystate *st, char *buf, int32_t size)
{
    int32_t n = 0, i;
    char    tmp[32];

    if (buf == NULL || size <= 0)
        return buf;
    buf[0] = '\0';

#define PUT(str) do { \
        const char *_s = (str); \
        while (*_s != '\0' && n < size - 1) buf[n++] = *_s++; \
    } while (0)

    if (st->arg_valid) {
        char num[16];
        int32_t v = st->arg_negative ? -st->arg : st->arg;
        int32_t k = 0, j;
        int32_t neg = v < 0;
        uint32_t u = (uint32_t)(neg ? -v : v);
        do { num[k++] = (char)('0' + (u % 10)); u /= 10; } while (u != 0 && k < 15);
        if (neg && k < 15) num[k++] = '-';
        PUT("C-u ");
        for (j = k - 1; j >= 0; j--)
            if (n < size - 1) buf[n++] = num[j];
        if (n < size - 1) buf[n++] = ' ';
    }

    for (i = 0; i < st->seqlen; i++) {
        ck_key_to_string(st->seq[i], tmp, (int32_t)sizeof(tmp));
        PUT(tmp);
        if (n < size - 1) buf[n++] = ' ';
    }

    if (st->meta_pending)
        PUT("ESC ");

    if (st->in_prefix || st->meta_pending || st->arg_valid)
        PUT("-");

#undef PUT

    buf[n] = '\0';
    return buf;
}

int32_t ck_keystate_take_arg(ck_keystate *st)
{
    int32_t arg = st->last_arg;
    st->last_arg       = 1;
    st->last_arg_given = 0;
    return arg;
}

int32_t ck_keystate_arg_given(const ck_keystate *st)
{
    return st->last_arg_given;
}
