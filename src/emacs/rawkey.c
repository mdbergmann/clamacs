/*
 * rawkey.c -- see rawkey.h.
 */

#include "rawkey.h"

#include <stddef.h>

static uint32_t ck_rawkey_mods(uint16_t qualifier)
{
    uint32_t mods = 0;

    if ((qualifier & CK_QUAL_CONTROL) != 0)
        mods |= CK_MOD_CTRL;
    /* Meta is Alt, either one (specs/clamacs-ide.md, "Key handling"). */
    if ((qualifier & (CK_QUAL_LALT | CK_QUAL_RALT)) != 0)
        mods |= CK_MOD_META;
    if ((qualifier & (CK_QUAL_LSHIFT | CK_QUAL_RSHIFT)) != 0)
        mods |= CK_MOD_SHIFT;
    return mods;
}

ck_key ck_rawkey_decode(uint16_t code, uint16_t qualifier,
                        ck_rawkey_mapper mapper, void *ctx)
{
    uint32_t mods;
    uint8_t  buffer[8];
    int32_t  n;

    if ((code & CK_RAW_UP_PREFIX) != 0)
        return CK_KEY_NONE;

    /* The Amiga keys stay free for the OS and for MUI's menu shortcuts.  A
     * key held with one of them is not a keystroke of ours at all -- not even
     * an unbound one, which would still go through the keymaps. */
    if ((qualifier & (CK_QUAL_LCOMMAND | CK_QUAL_RCOMMAND)) != 0)
        return CK_KEY_NONE;

    mods = ck_rawkey_mods(qualifier);

    /* The keys that have no character are recognised by raw code; the keymap
     * would give nothing useful for them. */
    switch (code) {
    case CK_RAW_UP:    return ck_key_make(CK_KEY_UP, mods);
    case CK_RAW_DOWN:  return ck_key_make(CK_KEY_DOWN, mods);
    case CK_RAW_RIGHT: return ck_key_make(CK_KEY_RIGHT, mods);
    case CK_RAW_LEFT:  return ck_key_make(CK_KEY_LEFT, mods);
    case CK_RAW_HELP:  return ck_key_make(CK_KEY_HELP, mods);
    default:           break;
    }
    if (code >= CK_RAW_F1 && code <= CK_RAW_F1 + 9)
        return ck_key_make((uint16_t)(CK_KEY_F1 + (code - CK_RAW_F1)), mods);

    if (mapper == NULL)
        return CK_KEY_NONE;

    /* Shift and caps only: we want the BASE character and add our own
     * modifier bits on top. */
    n = mapper(ctx, code, (uint16_t)(qualifier & CK_QUAL_MAP_MASK),
               buffer, (int32_t)sizeof buffer);
    if (n != 1 || buffer[0] == 0)
        return CK_KEY_NONE;

    return ck_key_make((uint16_t)buffer[0], mods);
}

uint16_t ck_rawkey_special(uint16_t keycode)
{
    switch (keycode) {
    case CK_KEY_UP:    return CK_RAW_UP;
    case CK_KEY_DOWN:  return CK_RAW_DOWN;
    case CK_KEY_RIGHT: return CK_RAW_RIGHT;
    case CK_KEY_LEFT:  return CK_RAW_LEFT;
    case CK_KEY_HELP:  return CK_RAW_HELP;
    default:           break;
    }
    if (keycode >= CK_KEY_F1 && keycode <= CK_KEY_F10)
        return (uint16_t)(CK_RAW_F1 + (keycode - CK_KEY_F1));
    return 0;
}

uint16_t ck_rawkey_qualifier(uint32_t mods)
{
    uint16_t qualifier = 0;

    if ((mods & CK_MOD_CTRL) != 0)
        qualifier |= CK_QUAL_CONTROL;
    if ((mods & CK_MOD_META) != 0)
        qualifier |= CK_QUAL_LALT;
    if ((mods & CK_MOD_SHIFT) != 0)
        qualifier |= CK_QUAL_LSHIFT;
    return qualifier;
}
