/*
 * rawkey.h -- IDCMP_RAWKEY to ck_key: the portable part.
 *
 * Intuition reports a keypress as a raw key code plus a qualifier word, and
 * the character it stands for has to be looked up in the keymap.  Splitting
 * the job in two keeps the decision-making host-testable: everything that is
 * a RULE -- which qualifier is Meta, what the keymap may be told, which keys
 * are recognised by code rather than by character, what to refuse -- lives
 * here and runs under tests/test_rawkey.c; the one OS call, MapRawKey, is
 * passed in by the caller as a function pointer (src/textclass.c supplies the
 * real one, the tests a table).
 *
 * Pure C: no MUI and no OS types.  The values below are those from
 * <devices/inputevent.h>, fixed by the OS ABI since 1.x, so restating them
 * here is what lets the module compile on the host without the header.
 */

#ifndef CLAMACS_RAWKEY_H
#define CLAMACS_RAWKEY_H

#include <stdint.h>

#include "keymap.h"

/* IECODE_UP_PREFIX: set in the code of a key-release event. */
#define CK_RAW_UP_PREFIX    0x80

/* IEQUALIFIER_* bits. */
#define CK_QUAL_LSHIFT      0x0001
#define CK_QUAL_RSHIFT      0x0002
#define CK_QUAL_CAPSLOCK    0x0004
#define CK_QUAL_CONTROL     0x0008
#define CK_QUAL_LALT        0x0010
#define CK_QUAL_RALT        0x0020
#define CK_QUAL_LCOMMAND    0x0040
#define CK_QUAL_RCOMMAND    0x0080
#define CK_QUAL_NUMERICPAD  0x0100
#define CK_QUAL_REPEAT      0x0200

/* The qualifier bits the keymap is allowed to see.  Shift and caps select the
 * character; Control and Alt are OURS: letting the keymap see Control would
 * turn C-f into 0x06 and lose which letter it was, and Alt would produce a
 * dead-key accent instead of Meta. */
#define CK_QUAL_MAP_MASK \
    (CK_QUAL_LSHIFT | CK_QUAL_RSHIFT | CK_QUAL_CAPSLOCK | CK_QUAL_NUMERICPAD)

/* Raw codes of the keys that have no character. */
#define CK_RAW_UP     0x4C
#define CK_RAW_DOWN   0x4D
#define CK_RAW_RIGHT  0x4E
#define CK_RAW_LEFT   0x4F
#define CK_RAW_F1     0x50   /* F1..F10 are 0x50..0x59 */
#define CK_RAW_HELP   0x5F

/*
 * The keymap lookup.  Given a raw code and the (already masked) qualifier,
 * write the character(s) the keymap gives for it to OUT and return how many
 * there were; 0 for a dead key or a key with no character, negative for a
 * failure.  On the Amiga this is MapRawKey; the decoder only accepts a result
 * of exactly one byte, since a key that maps to a string (or to nothing) is
 * not something the Emacs layer binds and belongs to the class.
 */
typedef int32_t (*ck_rawkey_mapper)(void *ctx, uint16_t code, uint16_t qualifier,
                                    uint8_t *out, int32_t size);

/*
 * Decode one event.  Returns CK_KEY_NONE for anything the Emacs layer must
 * not act on -- a key release, a key held with an Amiga (Command) key, a key
 * without a single-character meaning -- so the caller can pass it to the
 * superclass untouched.
 */
ck_key ck_rawkey_decode(uint16_t code, uint16_t qualifier,
                        ck_rawkey_mapper mapper, void *ctx);

/*
 * The inverse, for a tool that synthesises events (verify/realamiga/
 * sendkey.c): the raw code of a key that has no character, or 0 when KEYCODE
 * is a character (whose code the keymap has to supply); and the qualifier
 * bits for a set of CK_MOD_* modifiers.
 */
uint16_t ck_rawkey_special(uint16_t keycode);
uint16_t ck_rawkey_qualifier(uint32_t mods);

#endif /* CLAMACS_RAWKEY_H */
