/*
 * bindings.c -- see bindings.h.
 *
 * This is the phase-1 key table of specs/clamacs-ide.md, in the order the
 * spec lists it.  tests/test_bindings.c walks the same table and fails if a
 * promised key stops resolving, so the document and the binary cannot drift.
 *
 * Anything NOT bound here reaches TextEditor.mcc unchanged, which is how the
 * arrows, Home/End, mouse selection, Backspace and self-insert keep working
 * without the editor reimplementing them.
 */

#include "bindings.h"
#include "command.h"

#include <stdlib.h>

struct ck_binding_spec {
    const char *keys;
    int16_t     command;
};

static const struct ck_binding_spec ck_global_bindings[] = {
    /* movement */
    { "C-f",     CK_CMD_FORWARD_CHAR },
    { "C-b",     CK_CMD_BACKWARD_CHAR },
    { "C-n",     CK_CMD_NEXT_LINE },
    { "C-p",     CK_CMD_PREVIOUS_LINE },
    { "C-a",     CK_CMD_BEGINNING_OF_LINE },
    { "C-e",     CK_CMD_END_OF_LINE },
    { "M-f",     CK_CMD_FORWARD_WORD },
    { "M-b",     CK_CMD_BACKWARD_WORD },
    { "M-<",     CK_CMD_BEGINNING_OF_BUFFER },
    { "M->",     CK_CMD_END_OF_BUFFER },
    { "C-v",     CK_CMD_SCROLL_UP },
    { "M-v",     CK_CMD_SCROLL_DOWN },
    { "C-l",     CK_CMD_RECENTER },
    { "M-g g",   CK_CMD_GOTO_LINE },

    /* deleting, killing, yanking */
    { "C-d",     CK_CMD_DELETE_CHAR },
    { "M-d",     CK_CMD_KILL_WORD },
    { "M-DEL",   CK_CMD_BACKWARD_KILL_WORD },
    { "M-BS",    CK_CMD_BACKWARD_KILL_WORD },
    { "C-k",     CK_CMD_KILL_LINE },
    { "C-w",     CK_CMD_KILL_REGION },
    { "M-w",     CK_CMD_KILL_RING_SAVE },
    { "C-y",     CK_CMD_YANK },
    { "M-y",     CK_CMD_YANK_POP },

    /* mark and region */
    { "C-SPC",   CK_CMD_SET_MARK_COMMAND },
    { "C-x h",   CK_CMD_MARK_WHOLE_BUFFER },
    { "C-x C-x", CK_CMD_EXCHANGE_POINT_AND_MARK },

    /* undo */
    { "C-/",     CK_CMD_UNDO },
    { "C-_",     CK_CMD_UNDO },
    { "C-x u",   CK_CMD_UNDO },
    { "C-x r",   CK_CMD_REDO },

    /* search */
    { "C-s",     CK_CMD_ISEARCH_FORWARD },
    { "C-r",     CK_CMD_ISEARCH_BACKWARD },
    { "M-%",     CK_CMD_QUERY_REPLACE },

    /* files, buffers, windows, quit */
    { "C-x C-f", CK_CMD_FIND_FILE },
    { "C-x C-s", CK_CMD_SAVE_BUFFER },
    { "C-x C-w", CK_CMD_WRITE_FILE },
    { "C-x b",   CK_CMD_SWITCH_TO_BUFFER },
    { "C-x k",   CK_CMD_KILL_BUFFER },
    { "C-x C-c", CK_CMD_SAVE_BUFFERS_KILL_EMACS },
    { "C-x o",   CK_CMD_OTHER_WINDOW },
    { "C-x 2",   CK_CMD_FIND_FILE_OTHER_WINDOW },

    /* the command loop itself */
    { "M-x",     CK_CMD_EXECUTE_EXTENDED_COMMAND },
    { "C-g",     CK_CMD_KEYBOARD_QUIT },

    { NULL,      CK_CMD_NONE }
};

static const struct ck_binding_spec ck_lisp_bindings[] = {
    /* sexp motion and editing */
    { "C-M-f",   CK_CMD_FORWARD_SEXP },
    { "C-M-b",   CK_CMD_BACKWARD_SEXP },
    { "C-M-u",   CK_CMD_BACKWARD_UP_LIST },
    { "C-M-d",   CK_CMD_DOWN_LIST },
    { "C-M-a",   CK_CMD_BEGINNING_OF_DEFUN },
    { "C-M-e",   CK_CMD_END_OF_DEFUN },
    { "C-M-k",   CK_CMD_KILL_SEXP },
    { "M-(",     CK_CMD_INSERT_PARENTHESES },

    /* indentation.  Both live in the Lisp map: without a Lisp indenter
     * behind them, Tab and Return are better served by the class's own
     * handling, which is exactly what an unbound key gets. */
    { "TAB",     CK_CMD_INDENT_FOR_TAB_COMMAND },
    { "RET",     CK_CMD_NEWLINE_AND_INDENT },
    { "C-M-\\",  CK_CMD_INDENT_REGION },

    /* talking to clamiga */
    { "C-c C-k", CK_CMD_LOAD_BUFFER },
    { "C-c C-l", CK_CMD_LOAD_FILE },
    { "C-c C-c", CK_CMD_EVAL_DEFUN },
    { "C-x C-e", CK_CMD_EVAL_LAST_SEXP },
    { "C-c C-r", CK_CMD_EVAL_REGION },
    { "C-c C-e", CK_CMD_EVAL_EXPRESSION },
    { "C-c C-b", CK_CMD_INTERRUPT },
    { "C-c C-d", CK_CMD_SHOW_ERRORS },
    { "C-x `",   CK_CMD_NEXT_ERROR },

    { NULL,      CK_CMD_NONE }
};

static ck_keymap *ck_bindings_build(const char *name,
                                    const struct ck_binding_spec *specs)
{
    ck_keymap *map = ck_keymap_new(name);
    int32_t    i;

    if (map == NULL)
        return NULL;

    for (i = 0; specs[i].keys != NULL; i++) {
        if (ck_keymap_bind_seq(map, specs[i].keys, specs[i].command) != 0) {
            ck_keymap_free(map);
            return NULL;
        }
    }
    return map;
}

ck_keymap *ck_bindings_global(void)
{
    return ck_bindings_build("global", ck_global_bindings);
}

ck_keymap *ck_bindings_lisp(void)
{
    return ck_bindings_build("lisp", ck_lisp_bindings);
}
