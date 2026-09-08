/*
 * test_rawkey.c -- IDCMP_RAWKEY decoding, minus the one OS call.
 *
 * The mapper below stands in for keymap.library's MapRawKey with a slice of
 * the US keymap, and it RECORDS the qualifier it was called with -- because
 * the rule under test is not only what comes out but what the keymap was
 * allowed to see: never Control (C-f would become 0x06), never Alt (a
 * dead-key accent instead of Meta).
 */

#include "test.h"
#include "emacs/rawkey.h"

/* A slice of the US keymap: raw code, unshifted, shifted. */
struct mapping {
    uint16_t code;
    uint8_t  plain;
    uint8_t  shifted;
};

static const struct mapping us_keymap[] = {
    { 0x10, 'q', 'Q' },
    { 0x20, 'a', 'A' },
    { 0x21, 's', 'S' },
    { 0x33, 'x', 'X' },
    { 0x36, 'n', 'N' },
    { 0x38, ',', '<' },
    { 0x39, '.', '>' },
    { 0x0A, '9', '(' },
    { 0x0B, '0', ')' },
    { 0x0C, '-', '_' },
    { 0x40, ' ', ' ' },
    { 0x41, 0x08, 0x08 },   /* Backspace */
    { 0x42, 0x09, 0x09 },   /* Tab */
    { 0x43, 0x0D, 0x0D },   /* Enter */
    { 0x44, 0x0D, 0x0D },   /* Return */
    { 0x45, 0x1B, 0x1B },   /* Esc */
    { 0x46, 0x7F, 0x7F },   /* Del */
    { 0,    0,    0 }
};

static uint16_t seen_qualifier;
static int32_t  mapper_calls;

static int32_t fake_map(void *ctx, uint16_t code, uint16_t qualifier,
                        uint8_t *out, int32_t size)
{
    int32_t i;

    (void)ctx;
    mapper_calls++;
    seen_qualifier = qualifier;

    if (size < 1)
        return -1;

    /* A dead key: no character on its own. */
    if (code == 0x00)
        return 0;

    for (i = 0; us_keymap[i].code != 0; i++) {
        if (us_keymap[i].code == code) {
            int shifted = (qualifier & (CK_QUAL_LSHIFT | CK_QUAL_RSHIFT)) != 0;
            out[0] = shifted ? us_keymap[i].shifted : us_keymap[i].plain;
            return 1;
        }
    }
    return -1;
}

static ck_key decode(uint16_t code, uint16_t qualifier)
{
    mapper_calls   = 0;
    seen_qualifier = 0xFFFF;
    return ck_rawkey_decode(code, qualifier, fake_map, NULL);
}

TEST(plain_character)
{
    ASSERT(decode(0x20, 0) == ck_key_make('a', 0));
    ASSERT_EQ_INT(mapper_calls, 1);
}

TEST(shift_goes_to_the_keymap)
{
    /* Shift selects the character; the keymap sees it, and the result is the
     * shifted character with no Shift modifier of its own. */
    ASSERT(decode(0x20, CK_QUAL_LSHIFT) == ck_key_make('A', 0));
    ASSERT_EQ_INT(seen_qualifier, CK_QUAL_LSHIFT);
    ASSERT(decode(0x38, CK_QUAL_RSHIFT) == ck_key_from_string("<"));
}

TEST(control_is_ours)
{
    ck_key k = decode(0x36, CK_QUAL_CONTROL);
    ASSERT(k == ck_key_from_string("C-n"));
    /* ... and the keymap was not told about it. */
    ASSERT_EQ_INT(seen_qualifier & CK_QUAL_CONTROL, 0);
}

TEST(alt_is_meta)
{
    ASSERT(decode(0x33, CK_QUAL_LALT) == ck_key_from_string("M-x"));
    ASSERT_EQ_INT(seen_qualifier & (CK_QUAL_LALT | CK_QUAL_RALT), 0);

    ASSERT(decode(0x33, CK_QUAL_RALT) == ck_key_from_string("M-x"));

    /* M-< is Alt plus Shift plus the comma key: Shift reaches the keymap and
     * yields `<'; Alt does not, and becomes Meta. */
    ASSERT(decode(0x38, CK_QUAL_LALT | CK_QUAL_LSHIFT) == ck_key_from_string("M-<"));
    ASSERT_EQ_INT(seen_qualifier, CK_QUAL_LSHIFT);
}

TEST(control_meta_together)
{
    ASSERT(decode(0x36, CK_QUAL_CONTROL | CK_QUAL_LALT) == ck_key_from_string("C-M-n"));
}

TEST(control_letter_is_case_insensitive)
{
    /* C-S-n and C-n are one key, as ck_key_make promises. */
    ASSERT(decode(0x36, CK_QUAL_CONTROL | CK_QUAL_LSHIFT) == ck_key_from_string("C-n"));
}

TEST(key_release_is_ignored)
{
    ASSERT(decode((uint16_t)(0x20 | CK_RAW_UP_PREFIX), 0) == CK_KEY_NONE);
    ASSERT_EQ_INT(mapper_calls, 0);
}

TEST(amiga_keys_are_not_ours)
{
    /* Amiga+x is MUI's (menu shortcuts) or the OS's; it must not even reach
     * the keymaps as an unbound `x'. */
    ASSERT(decode(0x33, CK_QUAL_LCOMMAND) == CK_KEY_NONE);
    ASSERT(decode(0x33, CK_QUAL_RCOMMAND | CK_QUAL_LSHIFT) == CK_KEY_NONE);
    ASSERT_EQ_INT(mapper_calls, 0);
}

TEST(keys_without_a_character)
{
    ASSERT(decode(CK_RAW_UP, 0) == ck_key_make(CK_KEY_UP, 0));
    ASSERT(decode(CK_RAW_DOWN, 0) == ck_key_make(CK_KEY_DOWN, 0));
    ASSERT(decode(CK_RAW_LEFT, 0) == ck_key_make(CK_KEY_LEFT, 0));
    ASSERT(decode(CK_RAW_RIGHT, 0) == ck_key_make(CK_KEY_RIGHT, 0));
    ASSERT(decode(CK_RAW_HELP, 0) == ck_key_make(CK_KEY_HELP, 0));
    ASSERT(decode(CK_RAW_F1, 0) == ck_key_from_string("<f1>"));
    ASSERT(decode(CK_RAW_F1 + 9, 0) == ck_key_from_string("<f10>"));
    /* Recognised by code: the keymap is not consulted. */
    ASSERT_EQ_INT(mapper_calls, 0);

    /* Modifiers still apply to them. */
    ASSERT(decode(CK_RAW_UP, CK_QUAL_CONTROL) == ck_key_make(CK_KEY_UP, CK_MOD_CTRL));
    ASSERT(decode(CK_RAW_DOWN, CK_QUAL_LSHIFT) == ck_key_make(CK_KEY_DOWN, CK_MOD_SHIFT));
}

TEST(control_characters_come_from_the_keymap)
{
    ASSERT(decode(0x44, 0) == ck_key_from_string("RET"));
    ASSERT(decode(0x42, 0) == ck_key_from_string("TAB"));
    ASSERT(decode(0x45, 0) == ck_key_from_string("ESC"));
    ASSERT(decode(0x46, 0) == ck_key_from_string("DEL"));
    ASSERT(decode(0x41, 0) == ck_key_from_string("BS"));
    ASSERT(decode(0x40, CK_QUAL_CONTROL) == ck_key_from_string("C-SPC"));
    ASSERT(decode(0x41, CK_QUAL_LALT) == ck_key_from_string("M-BS"));

    /* Shift+Tab keeps its Shift: there is no character to carry it. */
    ASSERT(decode(0x42, CK_QUAL_LSHIFT) == ck_key_make(CK_KEY_TAB, CK_MOD_SHIFT));
}

TEST(dead_key_and_unmapped_keys_fall_through)
{
    /* A dead key gives no character on its own: not ours, the class composes
     * it with the next key. */
    ASSERT(decode(0x00, 0) == CK_KEY_NONE);
    /* A code the keymap does not know. */
    ASSERT(decode(0x7E, 0) == CK_KEY_NONE);
    /* No mapper at all: only the keys recognised by code decode. */
    ASSERT(ck_rawkey_decode(0x20, 0, NULL, NULL) == CK_KEY_NONE);
    ASSERT(ck_rawkey_decode(CK_RAW_UP, 0, NULL, NULL) == ck_key_make(CK_KEY_UP, 0));
}

TEST(repeat_and_numeric_pad_are_transparent)
{
    /* Auto-repeat is a keypress like any other. */
    ASSERT(decode(0x36, CK_QUAL_CONTROL | CK_QUAL_REPEAT) == ck_key_from_string("C-n"));
    /* The numeric pad flag is the keymap's business and is passed on. */
    ASSERT(decode(0x20, CK_QUAL_NUMERICPAD) == ck_key_make('a', 0));
    ASSERT_EQ_INT(seen_qualifier, CK_QUAL_NUMERICPAD);
}

TEST(inverse_for_event_synthesis)
{
    ASSERT_EQ_INT(ck_rawkey_special(CK_KEY_UP), CK_RAW_UP);
    ASSERT_EQ_INT(ck_rawkey_special(CK_KEY_F1 + 3), CK_RAW_F1 + 3);
    ASSERT_EQ_INT(ck_rawkey_special('a'), 0);
    ASSERT_EQ_INT(ck_rawkey_special(CK_KEY_TAB), 0);   /* has a character */

    ASSERT_EQ_INT(ck_rawkey_qualifier(CK_MOD_CTRL), CK_QUAL_CONTROL);
    ASSERT_EQ_INT(ck_rawkey_qualifier(CK_MOD_META), CK_QUAL_LALT);
    ASSERT_EQ_INT(ck_rawkey_qualifier(CK_MOD_CTRL | CK_MOD_META | CK_MOD_SHIFT),
                  CK_QUAL_CONTROL | CK_QUAL_LALT | CK_QUAL_LSHIFT);

    /* Round trip: what the inverse synthesises, the decoder reads back. */
    {
        ck_key   k    = ck_key_from_string("C-M-<up>");
        uint16_t code = ck_rawkey_special(CK_KEY_CODE(k));
        uint16_t qual = ck_rawkey_qualifier(CK_KEY_MODS(k));
        ASSERT(decode(code, qual) == k);
    }
}

int main(void)
{
    test_init();
    RUN(plain_character);
    RUN(shift_goes_to_the_keymap);
    RUN(control_is_ours);
    RUN(alt_is_meta);
    RUN(control_meta_together);
    RUN(control_letter_is_case_insensitive);
    RUN(key_release_is_ignored);
    RUN(amiga_keys_are_not_ours);
    RUN(keys_without_a_character);
    RUN(control_characters_come_from_the_keymap);
    RUN(dead_key_and_unmapped_keys_fall_through);
    RUN(repeat_and_numeric_pad_are_transparent);
    RUN(inverse_for_event_synthesis);
    REPORT();
}
