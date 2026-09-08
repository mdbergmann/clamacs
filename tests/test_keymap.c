/*
 * test_keymap.c -- key encoding, keymaps, and the prefix/argument machine.
 */

#include "test.h"
#include "emacs/keymap.h"
#include "emacs/command.h"

static char buf[64];

TEST(key_make_normalises)
{
    /* Control plus a letter has one spelling, whatever the shift state. */
    ASSERT(ck_key_make('F', CK_MOD_CTRL) == ck_key_make('f', CK_MOD_CTRL));

    /* Shift on a printable character is already in the character. */
    ASSERT(ck_key_make('<', CK_MOD_META | CK_MOD_SHIFT) ==
           ck_key_make('<', CK_MOD_META));

    /* ... but a key with no character keeps it. */
    ASSERT(ck_key_make(CK_KEY_TAB, CK_MOD_SHIFT) !=
           ck_key_make(CK_KEY_TAB, 0));

    ASSERT_EQ_INT(CK_KEY_CODE(ck_key_make('a', CK_MOD_CTRL)), 'a');
    ASSERT_EQ_INT(CK_KEY_MODS(ck_key_make('a', CK_MOD_CTRL)), CK_MOD_CTRL);
}

TEST(key_to_string)
{
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make('x', CK_MOD_CTRL), buf, sizeof buf), "C-x");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make('f', CK_MOD_META), buf, sizeof buf), "M-f");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make('f', CK_MOD_CTRL | CK_MOD_META), buf, sizeof buf), "C-M-f");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make(CK_KEY_SPACE, CK_MOD_CTRL), buf, sizeof buf), "C-SPC");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make(CK_KEY_TAB, 0), buf, sizeof buf), "TAB");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make(CK_KEY_RETURN, 0), buf, sizeof buf), "RET");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make(CK_KEY_UP, 0), buf, sizeof buf), "<up>");
    ASSERT_STR_EQ(ck_key_to_string(ck_key_make('<', CK_MOD_META), buf, sizeof buf), "M-<");
}

TEST(key_from_string)
{
    ASSERT(ck_key_from_string("C-x") == ck_key_make('x', CK_MOD_CTRL));
    ASSERT(ck_key_from_string("M-f") == ck_key_make('f', CK_MOD_META));
    ASSERT(ck_key_from_string("C-M-f") == ck_key_make('f', CK_MOD_CTRL | CK_MOD_META));
    ASSERT(ck_key_from_string("C-SPC") == ck_key_make(CK_KEY_SPACE, CK_MOD_CTRL));
    ASSERT(ck_key_from_string("<f1>") == ck_key_make(CK_KEY_F1, 0));

    /* A bare minus and a control-minus must both survive the modifier
     * parser, which is the one place the spelling grammar is ambiguous. */
    ASSERT(ck_key_from_string("-") == ck_key_make('-', 0));
    ASSERT(ck_key_from_string("C--") == ck_key_make('-', CK_MOD_CTRL));
    ASSERT(ck_key_from_string("C-_") == ck_key_make('_', CK_MOD_CTRL));

    ASSERT(ck_key_from_string("nonsense") == CK_KEY_NONE);
    ASSERT(ck_key_from_string("") == CK_KEY_NONE);
}

TEST(key_string_round_trip)
{
    static const char *const spellings[] = {
        "C-x", "M-f", "C-M-f", "C-SPC", "TAB", "RET", "ESC", "DEL",
        "<up>", "<down>", "<f10>", "a", "Z", "M-<", "M->", "C--", NULL
    };
    int32_t i;

    for (i = 0; spellings[i] != NULL; i++) {
        ck_key k = ck_key_from_string(spellings[i]);
        ASSERT(k != CK_KEY_NONE);
        ASSERT_STR_EQ(ck_key_to_string(k, buf, sizeof buf), spellings[i]);
    }
}

TEST(keymap_bind_and_lookup)
{
    ck_keymap *map = ck_keymap_new("test");
    const ck_keyentry *e;

    ASSERT(map != NULL);
    ASSERT_EQ_INT(ck_keymap_bind(map, ck_key_from_string("C-f"), 11), 0);
    ASSERT_EQ_INT(ck_keymap_bind(map, ck_key_from_string("C-b"), 22), 0);
    ASSERT_EQ_INT(ck_keymap_bind(map, ck_key_from_string("M-f"), 33), 0);

    e = ck_keymap_lookup(map, ck_key_from_string("C-f"));
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->kind, CK_BIND_COMMAND);
    ASSERT_EQ_INT(e->command, 11);

    e = ck_keymap_lookup(map, ck_key_from_string("M-f"));
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->command, 33);

    ASSERT(ck_keymap_lookup(map, ck_key_from_string("C-z")) == NULL);

    /* Rebinding replaces. */
    ASSERT_EQ_INT(ck_keymap_bind(map, ck_key_from_string("C-f"), 99), 0);
    e = ck_keymap_lookup(map, ck_key_from_string("C-f"));
    ASSERT_EQ_INT(e->command, 99);
    ASSERT_EQ_INT(map->count, 3);

    ck_keymap_free(map);
}

TEST(keymap_many_bindings_stay_sorted)
{
    ck_keymap *map = ck_keymap_new("test");
    int32_t    i;

    /* More than the initial capacity, inserted in an order that exercises
     * the shifting insert. */
    for (i = 0; i < 60; i++)
        ASSERT_EQ_INT(ck_keymap_bind(map, ck_key_make((uint16_t)('a' + (i * 7) % 26),
                                                      (i & 1) ? CK_MOD_CTRL : CK_MOD_META),
                                     (int16_t)i), 0);
    for (i = 1; i < map->count; i++)
        ASSERT(map->entries[i - 1].key < map->entries[i].key);

    ck_keymap_free(map);
}

TEST(keymap_bind_seq_builds_prefix_maps)
{
    ck_keymap         *map = ck_keymap_new("test");
    const ck_keyentry *e;

    ASSERT_EQ_INT(ck_keymap_bind_seq(map, "C-x C-f", 7), 0);
    ASSERT_EQ_INT(ck_keymap_bind_seq(map, "C-x C-s", 8), 0);
    ASSERT_EQ_INT(ck_keymap_bind_seq(map, "C-x b", 9), 0);

    e = ck_keymap_lookup(map, ck_key_from_string("C-x"));
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->kind, CK_BIND_KEYMAP);
    ASSERT(e->map != NULL);
    ASSERT_EQ_INT(e->map->count, 3);

    ASSERT_EQ_INT(ck_keymap_lookup(e->map, ck_key_from_string("C-f"))->command, 7);
    ASSERT_EQ_INT(ck_keymap_lookup(e->map, ck_key_from_string("b"))->command, 9);

    ASSERT(ck_keymap_bind_seq(map, "", 1) != 0);
    ASSERT(ck_keymap_bind_seq(map, "C-x nonsense", 1) != 0);

    ck_keymap_free(map);
}

/* --- the state machine ------------------------------------------- */

struct fixture {
    ck_keymap  *global;
    ck_keystate st;
};

static void fixture_init(struct fixture *f)
{
    f->global = ck_keymap_new("global");
    ck_keymap_bind_seq(f->global, "C-f", 1);
    ck_keymap_bind_seq(f->global, "M-f", 2);
    ck_keymap_bind_seq(f->global, "C-x C-f", 3);
    ck_keymap_bind_seq(f->global, "C-x b", 4);
    ck_keymap_bind_seq(f->global, "C-g", 5);
    ck_keystate_init(&f->st, f->global, NULL);
}

static void fixture_free(struct fixture *f)
{
    ck_keymap_free(f->global);
}

static ck_keyresult feed(struct fixture *f, const char *spelling, int16_t *cmd)
{
    return ck_keystate_feed(&f->st, ck_key_from_string(spelling), cmd);
}

TEST(state_simple_command)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 1);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 1);
    fixture_free(&f);
}

TEST(state_unbound_falls_through)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    /* A plain character is not ours: it must reach TextEditor.mcc, or
     * self-insert stops working. */
    ASSERT_EQ_INT(feed(&f, "a", &cmd), CK_KEY_UNBOUND);
    ASSERT_EQ_INT(feed(&f, "C-z", &cmd), CK_KEY_UNBOUND);
    fixture_free(&f);
}

TEST(state_prefix_sequence)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-x", &cmd), CK_KEY_PREFIX);
    ck_keystate_describe(&f.st, buf, sizeof buf);
    ASSERT_STR_EQ(buf, "C-x -");
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 3);

    /* And the state is clean again afterwards. */
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 1);
    fixture_free(&f);
}

TEST(state_undefined_sequence_is_eaten)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-x", &cmd), CK_KEY_PREFIX);
    /* C-x C-q is ours and undefined: reporting it is right, letting the
     * superclass insert a `q' is not. */
    ASSERT_EQ_INT(feed(&f, "C-q", &cmd), CK_KEY_UNDEFINED);
    ASSERT(f.st.pending == NULL);
    fixture_free(&f);
}

TEST(state_esc_is_meta)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "ESC", &cmd), CK_KEY_PREFIX);
    ASSERT_EQ_INT(feed(&f, "f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 2);   /* the M-f binding */
    fixture_free(&f);
}

TEST(state_c_g_cancels_then_runs)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-x", &cmd), CK_KEY_PREFIX);
    ASSERT_EQ_INT(feed(&f, "C-g", &cmd), CK_KEY_CANCEL);
    ASSERT(f.st.pending == NULL);

    /* With nothing pending, C-g is an ordinary command. */
    ASSERT_EQ_INT(feed(&f, "C-g", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 5);
    fixture_free(&f);
}

TEST(state_universal_argument)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 4);

    /* C-u C-u multiplies. */
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 16);

    /* Digits after C-u replace the 4. */
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "1", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "2", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 12);

    /* C-u - negates. */
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "-", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "5", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), -5);

    /* M-5 is an argument too. */
    ASSERT_EQ_INT(feed(&f, "M-5", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 5);

    fixture_free(&f);
}

TEST(state_argument_does_not_leak)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    /* The caller here deliberately does NOT read the argument; the next
     * command must still see the default. */
    ASSERT_EQ_INT(feed(&f, "C-f", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 1);
    fixture_free(&f);
}

TEST(state_digit_inside_prefix_is_a_key)
{
    struct fixture f;
    int16_t        cmd = -1;

    fixture_init(&f);
    ck_keymap_bind_seq(f.global, "C-x 2", 42);
    ASSERT_EQ_INT(feed(&f, "C-u", &cmd), CK_KEY_ARG);
    ASSERT_EQ_INT(feed(&f, "C-x", &cmd), CK_KEY_PREFIX);
    /* Inside C-x, `2' is a key and not a digit of the argument. */
    ASSERT_EQ_INT(feed(&f, "2", &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 42);
    ASSERT_EQ_INT(ck_keystate_take_arg(&f.st), 4);
    fixture_free(&f);
}

TEST(state_local_map_wins)
{
    ck_keymap  *global = ck_keymap_new("global");
    ck_keymap  *local  = ck_keymap_new("local");
    ck_keystate st;
    int16_t     cmd = -1;

    ck_keymap_bind_seq(global, "C-f", 1);
    ck_keymap_bind_seq(global, "C-b", 2);
    ck_keymap_bind_seq(local, "C-f", 99);
    ck_keystate_init(&st, global, local);

    ASSERT_EQ_INT(ck_keystate_feed(&st, ck_key_from_string("C-f"), &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 99);
    ASSERT_EQ_INT(ck_keystate_feed(&st, ck_key_from_string("C-b"), &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, 2);

    ck_keymap_free(global);
    ck_keymap_free(local);
}

int main(void)
{
    test_init();
    RUN(key_make_normalises);
    RUN(key_to_string);
    RUN(key_from_string);
    RUN(key_string_round_trip);
    RUN(keymap_bind_and_lookup);
    RUN(keymap_many_bindings_stay_sorted);
    RUN(keymap_bind_seq_builds_prefix_maps);
    RUN(state_simple_command);
    RUN(state_unbound_falls_through);
    RUN(state_prefix_sequence);
    RUN(state_undefined_sequence_is_eaten);
    RUN(state_esc_is_meta);
    RUN(state_c_g_cancels_then_runs);
    RUN(state_universal_argument);
    RUN(state_argument_does_not_leak);
    RUN(state_digit_inside_prefix_is_a_key);
    RUN(state_local_map_wins);
    REPORT();
}
