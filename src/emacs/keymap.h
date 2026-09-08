/*
 * keymap.h -- key encoding, keymaps and the prefix-key state machine.
 *
 * Pure C: no MUI and no OS types, so the whole engine is exercised by
 * tests/test_keymap.c on the host.  The MUI side (src/textclass.c) does one
 * job this file cannot: turn an IDCMP_RAWKEY event into a ck_key.  Everything
 * after that -- prefix maps, C-u arguments, ESC-as-Meta, C-g -- happens here.
 *
 * Why the editor owns its bindings at all: TextEditor.mcc resolves keys
 * through a table taken from the USER's MUI preferences, and although
 * MUIA_TextEditor_KeyBindings exists in the header, nothing in the class
 * reads it (checked against the 15.56 sources).  An application cannot hand
 * the class a table, so the Emacs layer sees keys first in MUIM_HandleEvent
 * and passes what it does not bind down to the superclass.
 */

#ifndef CLAMACS_KEYMAP_H
#define CLAMACS_KEYMAP_H

#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Key encoding
 *
 * A ck_key is a 16-bit key code in the low half and modifier bits in the
 * high half.  Codes 0x01..0xFF are ISO-8859-1 characters (the editor is
 * 8-bit, matching clamiga's narrow strings); codes from CK_KEY_UP up name
 * the keys that have no character.
 * ------------------------------------------------------------------ */

typedef uint32_t ck_key;

#define CK_MOD_CTRL   0x00010000UL
#define CK_MOD_META   0x00020000UL
#define CK_MOD_SHIFT  0x00040000UL
#define CK_MOD_MASK   0x00070000UL

#define CK_KEY_CODE(k) ((uint16_t)((k) & 0xFFFFUL))
#define CK_KEY_MODS(k) ((uint32_t)((k) & CK_MOD_MASK))

#define CK_KEY_NONE 0UL

enum {
    CK_KEY_BACKSPACE = 0x08,
    CK_KEY_TAB       = 0x09,
    CK_KEY_RETURN     = 0x0D,
    CK_KEY_ESC       = 0x1B,
    CK_KEY_SPACE     = 0x20,
    CK_KEY_DELETE    = 0x7F,

    /* Keys with no character.  Kept above 0xFF so a code and a character
     * never collide. */
    CK_KEY_UP        = 0x100,
    CK_KEY_DOWN,
    CK_KEY_LEFT,
    CK_KEY_RIGHT,
    CK_KEY_HOME,
    CK_KEY_END,
    CK_KEY_PAGEUP,
    CK_KEY_PAGEDOWN,
    CK_KEY_INSERT,
    CK_KEY_HELP,
    CK_KEY_F1,       /* F1..F10 are CK_KEY_F1 + 0 .. + 9 */
    CK_KEY_F10       = CK_KEY_F1 + 9
};

/* Build a key, normalising the combinations that would otherwise produce two
 * spellings of one keystroke:
 *   - Control plus a letter is stored lowercase, so C-f and C-S-f are one key
 *     (Emacs treats them the same and no phase-1 binding distinguishes them).
 *   - Shift is dropped for printable characters, where the shift is already
 *     expressed in the character itself ('<' is not S-','). */
ck_key ck_key_make(uint16_t code, uint32_t mods);

/* Emacs spelling of a key: "C-x", "M-f", "C-M-f", "C-SPC", "TAB", "RET",
 * "ESC", "DEL", "<up>", "<f1>".  Always NUL-terminates.  Returns buf. */
char *ck_key_to_string(ck_key key, char *buf, int32_t size);

/* Inverse of ck_key_to_string.  Returns CK_KEY_NONE when the spelling is not
 * understood.  Used by the tests and by the ARexx/`M-x` layers that name a
 * key in text. */
ck_key ck_key_from_string(const char *text);

/* ------------------------------------------------------------------ *
 * Keymaps
 * ------------------------------------------------------------------ */

typedef enum {
    CK_BIND_NONE = 0,
    CK_BIND_COMMAND,
    CK_BIND_KEYMAP
} ck_bind_kind;

struct ck_keymap;

typedef struct {
    ck_key             key;
    uint16_t           kind;     /* ck_bind_kind */
    uint16_t           owned;    /* CK_BIND_KEYMAP created by bind_seq, so
                                  * ck_keymap_free() disposes of it too */
    int16_t            command;  /* CK_BIND_COMMAND: a command id */
    struct ck_keymap  *map;      /* CK_BIND_KEYMAP: the prefix map */
} ck_keyentry;

typedef struct ck_keymap {
    const char  *name;
    ck_keyentry *entries;
    int32_t      count;
    int32_t      cap;
} ck_keymap;

ck_keymap *ck_keymap_new(const char *name);
void       ck_keymap_free(ck_keymap *map);

/* Bind KEY in MAP.  Rebinding an existing key replaces it.  Returns 0 on
 * success, -1 when out of memory. */
int ck_keymap_bind(ck_keymap *map, ck_key key, int16_t command);
int ck_keymap_bind_map(ck_keymap *map, ck_key key, ck_keymap *sub);

/* Bind a key given by its Emacs spelling ("C-x C-f" binds through prefix
 * maps, creating them as needed under MAP; the intermediate keys must be
 * unbound or already prefix maps).  Returns 0 on success, -1 on failure. */
int ck_keymap_bind_seq(ck_keymap *map, const char *keys, int16_t command);

const ck_keyentry *ck_keymap_lookup(const ck_keymap *map, ck_key key);

/* ------------------------------------------------------------------ *
 * The key state machine
 * ------------------------------------------------------------------ */

#define CK_MAX_SEQ 4

typedef enum {
    CK_KEY_UNBOUND = 0, /* nothing matched at top level -- let the superclass
                         * have it, which is how the class's own arrows,
                         * Home/End, mouse selection and self-insert keep
                         * working */
    CK_KEY_PREFIX,      /* a prefix map is pending; echo the sequence */
    CK_KEY_COMMAND,     /* *command_out is ready to run */
    CK_KEY_UNDEFINED,   /* the sequence ended with no binding */
    CK_KEY_ARG,         /* consumed by the C-u numeric-argument reader */
    CK_KEY_CANCEL       /* C-g cancelled a pending sequence or argument */
} ck_keyresult;

typedef struct {
    ck_keymap *global;
    ck_keymap *local;        /* mode map, consulted first; may be NULL */

    /* Inside a prefix, BOTH sides stay live.  The Lisp map binds `C-x C-e'
     * and the global map binds `C-x C-f' on the same prefix key, so entering
     * the local C-x map must not hide the global one -- otherwise turning on
     * Lisp mode would break find-file. */
    ck_keymap *pending;        /* the local prefix map, or NULL */
    ck_keymap *pending_global; /* the global prefix map, or NULL */
    int32_t    in_prefix;      /* a sequence is in progress */

    ck_key     seq[CK_MAX_SEQ];
    int32_t    seqlen;

    int32_t    meta_pending; /* ESC was seen: the next key gains CK_MOD_META */

    /* C-u state.  arg_valid says an argument was actually given, which is
     * what distinguishes `C-u 0 C-k' (kill to start of line) from a plain
     * C-k, and lets a command default to 1 without inventing one. */
    int32_t    arg;
    int32_t    arg_valid;
    int32_t    arg_reading;  /* digits are being accumulated */
    int32_t    arg_negative;

    /* The argument that belongs to the command just returned.  feed() moves
     * it here and clears the accumulator, so a caller that forgets to read
     * it cannot leak an argument into the next command. */
    int32_t    last_arg;
    int32_t    last_arg_given;
} ck_keystate;

void ck_keystate_init(ck_keystate *st, ck_keymap *global, ck_keymap *local);
void ck_keystate_reset(ck_keystate *st);

/* Feed one key.  On CK_KEY_COMMAND, *command_out holds the command id.
 * COMMAND_OUT may be NULL. */
ck_keyresult ck_keystate_feed(ck_keystate *st, ck_key key, int16_t *command_out);

/* The pending sequence as text for the echo area: "C-x -", "C-u 4 C-x -". */
char *ck_keystate_describe(const ck_keystate *st, char *buf, int32_t size);

/* The numeric argument for the command just returned: the given argument, or
 * 1 when none was given.  Reading it clears it, so every command sees either
 * its own argument or the default. */
int32_t ck_keystate_take_arg(ck_keystate *st);

/* Whether an argument was actually typed (for commands whose behaviour
 * differs between `C-k' and `C-u 1 C-k'). */
int32_t ck_keystate_arg_given(const ck_keystate *st);

#endif /* CLAMACS_KEYMAP_H */
