/*
 * test_bindings.c -- the phase-1 key table.
 *
 * specs/clamacs-ide.md calls this table "the bindings a user can rely on".
 * This file is what makes that promise checkable: every sequence below is
 * fed through the real state machine against the real maps, so a binding
 * that stops resolving -- or starts resolving to something else -- fails
 * here rather than on an Amiga.
 */

#include "test.h"
#include "emacs/bindings.h"
#include "emacs/command.h"

struct expectation {
    const char *keys;    /* space-separated, as ck_key_from_string spells them */
    const char *command;
};

static void check_table(const struct expectation *table, int32_t use_lisp_map)
{
    ck_keymap *global = ck_bindings_global();
    ck_keymap *lisp   = use_lisp_map ? ck_bindings_lisp() : NULL;
    int32_t    i;

    ASSERT(global != NULL);
    if (use_lisp_map)
        ASSERT(lisp != NULL);

    for (i = 0; table[i].keys != NULL; i++) {
        ck_keystate  st;
        const char  *p = table[i].keys;
        char         spelling[32];
        ck_keyresult r   = CK_KEY_UNBOUND;
        int16_t      cmd = CK_CMD_NONE;

        ck_keystate_init(&st, global, lisp);

        for (;;) {
            int32_t n = 0;
            while (*p == ' ')
                p++;
            if (*p == '\0')
                break;
            while (*p != '\0' && *p != ' ' && n < (int32_t)sizeof(spelling) - 1)
                spelling[n++] = *p++;
            spelling[n] = '\0';
            r = ck_keystate_feed(&st, ck_key_from_string(spelling), &cmd);
        }

        if (r != CK_KEY_COMMAND) {
            printf("  %s did not resolve to a command (result %d)\n",
                   table[i].keys, (int)r);
            test_current_failed = 1;
            continue;
        }
        if (cmd != ck_command_lookup(table[i].command)) {
            printf("  %s ran %s, expected %s\n", table[i].keys,
                   ck_command_name(cmd), table[i].command);
            test_current_failed = 1;
        }
    }

    ck_keymap_free(global);
    ck_keymap_free(lisp);
}

TEST(spec_movement_keys)
{
    static const struct expectation t[] = {
        { "C-f", "forward-char" },
        { "C-b", "backward-char" },
        { "C-n", "next-line" },
        { "C-p", "previous-line" },
        { "C-a", "beginning-of-line" },
        { "C-e", "end-of-line" },
        { "M-f", "forward-word" },
        { "M-b", "backward-word" },
        { "M-<", "beginning-of-buffer" },
        { "M->", "end-of-buffer" },
        { "C-v", "scroll-up" },
        { "M-v", "scroll-down" },
        { NULL,  NULL }
    };
    check_table(t, 0);
}

TEST(spec_kill_and_yank_keys)
{
    static const struct expectation t[] = {
        { "C-d", "delete-char" },
        { "M-d", "kill-word" },
        { "C-k", "kill-line" },
        { "C-w", "kill-region" },
        { "M-w", "kill-ring-save" },
        { "C-y", "yank" },
        { "M-y", "yank-pop" },
        { NULL,  NULL }
    };
    check_table(t, 0);
}

TEST(spec_mark_undo_and_search_keys)
{
    static const struct expectation t[] = {
        { "C-SPC",   "set-mark-command" },
        { "C-x h",   "mark-whole-buffer" },
        { "C-/",     "undo" },
        { "C-_",     "undo" },
        { "C-x u",   "undo" },
        { "C-s",     "isearch-forward" },
        { "C-r",     "isearch-backward" },
        { NULL,      NULL }
    };
    check_table(t, 0);
}

TEST(spec_file_and_window_keys)
{
    static const struct expectation t[] = {
        { "C-x C-f", "find-file" },
        { "C-x C-s", "save-buffer" },
        { "C-x C-w", "write-file" },
        { "C-x b",   "switch-to-buffer" },
        { "C-x k",   "kill-buffer" },
        { "C-x C-c", "save-buffers-kill-emacs" },
        { "C-x o",   "other-window" },
        { "C-x 2",   "find-file-other-window" },
        { "M-x",     "execute-extended-command" },
        { NULL,      NULL }
    };
    check_table(t, 0);
}

TEST(spec_sexp_keys_are_lisp_mode)
{
    static const struct expectation t[] = {
        { "C-M-f", "forward-sexp" },
        { "C-M-b", "backward-sexp" },
        { "C-M-u", "backward-up-list" },
        { "C-M-d", "down-list" },
        { "C-M-a", "beginning-of-defun" },
        { "C-M-e", "end-of-defun" },
        { "C-M-k", "kill-sexp" },
        { "M-(",   "insert-parentheses" },
        { "TAB",   "indent-for-tab-command" },
        { NULL,    NULL }
    };
    check_table(t, 1);
}

TEST(spec_lisp_interaction_keys)
{
    static const struct expectation t[] = {
        { "C-c C-k", "clamacs-load-buffer" },
        { "C-c C-c", "clamacs-eval-defun" },
        { "C-x C-e", "clamacs-eval-last-sexp" },
        { "C-c C-r", "clamacs-eval-region" },
        { "C-c C-l", "clamacs-load-file" },
        { NULL,      NULL }
    };
    check_table(t, 1);
}

TEST(lisp_map_shadows_global_for_c_x_c_e)
{
    /* C-x C-e is a Lisp-mode binding on a C-x prefix that the global map
     * also owns.  The local map must win for the whole sequence, or
     * `C-x C-e' would fall into the global C-x map and report undefined. */
    ck_keymap  *global = ck_bindings_global();
    ck_keymap  *lisp   = ck_bindings_lisp();
    ck_keystate st;
    int16_t     cmd = CK_CMD_NONE;

    ck_keystate_init(&st, global, lisp);
    ASSERT_EQ_INT(ck_keystate_feed(&st, ck_key_from_string("C-x"), &cmd), CK_KEY_PREFIX);
    ASSERT_EQ_INT(ck_keystate_feed(&st, ck_key_from_string("C-e"), &cmd), CK_KEY_COMMAND);
    ASSERT_EQ_INT(cmd, ck_command_lookup("clamacs-eval-last-sexp"));

    ck_keymap_free(global);
    ck_keymap_free(lisp);
}

TEST(lisp_prefix_does_not_hide_the_global_one)
{
    /* The other half of the same problem, and the one that actually bites:
     * both maps bind something on C-x.  Entering Lisp mode must not cost the
     * user `C-x C-f', `C-x C-s' or `C-x u'. */
    static const struct expectation t[] = {
        { "C-x C-f", "find-file" },
        { "C-x C-s", "save-buffer" },
        { "C-x C-c", "save-buffers-kill-emacs" },
        { "C-x u",   "undo" },
        { "C-x b",   "switch-to-buffer" },
        { "C-x h",   "mark-whole-buffer" },
        { "C-x C-e", "clamacs-eval-last-sexp" },   /* the local one still wins */
        { NULL,      NULL }
    };
    check_table(t, 1);
}

TEST(unbound_keys_reach_the_superclass)
{
    /* The keys TextEditor.mcc handles itself must NOT be claimed here, or
     * the class's own navigation, selection and self-insert stop working. */
    static const char *const passthrough[] = {
        "a", "Z", "1", "<up>", "<down>", "<left>", "<right>",
        "<home>", "<end>", "BS", "DEL", "C-z", "M-z", NULL
    };
    ck_keymap  *global = ck_bindings_global();
    ck_keymap  *lisp   = ck_bindings_lisp();
    int32_t     i;

    for (i = 0; passthrough[i] != NULL; i++) {
        ck_keystate st;
        int16_t     cmd = CK_CMD_NONE;
        ck_keystate_init(&st, global, lisp);
        if (ck_keystate_feed(&st, ck_key_from_string(passthrough[i]), &cmd)
            != CK_KEY_UNBOUND) {
            printf("  %s was claimed by the editor but should fall through\n",
                   passthrough[i]);
            test_current_failed = 1;
        }
    }

    ck_keymap_free(global);
    ck_keymap_free(lisp);
}

TEST(every_binding_names_a_real_command)
{
    /* A binding to an id outside the table would be a silent no-op at
     * runtime; catch it here instead. */
    ck_keymap *maps[2];
    int32_t    m;

    maps[0] = ck_bindings_global();
    maps[1] = ck_bindings_lisp();

    for (m = 0; m < 2; m++) {
        int32_t i;
        for (i = 0; i < maps[m]->count; i++) {
            const ck_keyentry *e = &maps[m]->entries[i];
            if (e->kind == CK_BIND_COMMAND) {
                ASSERT(ck_command_name(e->command) != NULL);
            } else if (e->kind == CK_BIND_KEYMAP) {
                int32_t j;
                for (j = 0; j < e->map->count; j++) {
                    const ck_keyentry *sub = &e->map->entries[j];
                    if (sub->kind == CK_BIND_COMMAND)
                        ASSERT(ck_command_name(sub->command) != NULL);
                }
            }
        }
    }

    ck_keymap_free(maps[0]);
    ck_keymap_free(maps[1]);
}

int main(void)
{
    test_init();
    RUN(spec_movement_keys);
    RUN(spec_kill_and_yank_keys);
    RUN(spec_mark_undo_and_search_keys);
    RUN(spec_file_and_window_keys);
    RUN(spec_sexp_keys_are_lisp_mode);
    RUN(spec_lisp_interaction_keys);
    RUN(lisp_map_shadows_global_for_c_x_c_e);
    RUN(lisp_prefix_does_not_hide_the_global_one);
    RUN(unbound_keys_reach_the_superclass);
    RUN(every_binding_names_a_real_command);
    REPORT();
}
