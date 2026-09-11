/*
 * menudef.c -- see menudef.h.
 */

#include "menudef.h"
#include "command.h"

#include <stddef.h>

#define TITLE(name)                 { CK_MENU_TITLE, CK_MENU_ALWAYS, CK_CMD_NONE, name, NULL, 0 }
#define BAR                         { CK_MENU_BAR,   CK_MENU_ALWAYS, CK_CMD_NONE, NULL, NULL, 0 }
#define ITEM(cmd, rule, label, keys, map) { CK_MENU_ITEM, rule, cmd, label, keys, map }

/* The order is the order on screen.  Project first, as on any Amiga; the
 * key in the shortcut column is the one a user would learn next. */
static const ck_menu_entry ck_menu_table[] = {
    TITLE("Project"),
    ITEM(CK_CMD_FIND_FILE,               CK_MENU_ALWAYS,        "Open...",             "C-x C-f", 0),
    ITEM(CK_CMD_FIND_FILE_OTHER_WINDOW,  CK_MENU_ALWAYS,        "Open in New Window...", "C-x 2",  0),
    ITEM(CK_CMD_SAVE_BUFFER,             CK_MENU_DOC_CHANGED,   "Save",                "C-x C-s", 0),
    ITEM(CK_CMD_WRITE_FILE,              CK_MENU_ALWAYS,        "Save As...",          "C-x C-w", 0),
    BAR,
    ITEM(CK_CMD_SWITCH_TO_BUFFER,        CK_MENU_ALWAYS,        "Next Buffer",         "C-x b",   0),
    ITEM(CK_CMD_KILL_BUFFER,             CK_MENU_ALWAYS,        "Close Buffer",        "C-x k",   0),
    BAR,
    ITEM(CK_MENU_CMD_ABOUT,              CK_MENU_ALWAYS,        "About...",            NULL,      0),
    BAR,
    ITEM(CK_CMD_SAVE_BUFFERS_KILL_EMACS, CK_MENU_ALWAYS,        "Quit",                "C-x C-c", 0),

    TITLE("Edit"),
    ITEM(CK_CMD_UNDO,                    CK_MENU_ALWAYS,        "Undo",                "C-/",     0),
    ITEM(CK_CMD_REDO,                    CK_MENU_ALWAYS,        "Redo",                "C-x r",   0),
    BAR,
    ITEM(CK_CMD_KILL_REGION,             CK_MENU_ALWAYS,        "Cut",                 "C-w",     0),
    ITEM(CK_CMD_KILL_RING_SAVE,          CK_MENU_ALWAYS,        "Copy",                "M-w",     0),
    ITEM(CK_CMD_YANK,                    CK_MENU_ALWAYS,        "Paste",               "C-y",     0),
    ITEM(CK_CMD_YANK_POP,                CK_MENU_ALWAYS,        "Paste Previous",      "M-y",     0),
    ITEM(CK_CMD_MARK_WHOLE_BUFFER,       CK_MENU_ALWAYS,        "Select All",          "C-x h",   0),
    BAR,
    ITEM(CK_CMD_ISEARCH_FORWARD,         CK_MENU_ALWAYS,        "Search Forward...",   "C-s",     0),
    ITEM(CK_CMD_ISEARCH_BACKWARD,        CK_MENU_ALWAYS,        "Search Backward...",  "C-r",     0),
    ITEM(CK_CMD_GOTO_LINE,               CK_MENU_ALWAYS,        "Go to Line...",       "M-g g",   0),
    BAR,
    ITEM(CK_CMD_EXECUTE_EXTENDED_COMMAND, CK_MENU_ALWAYS,       "Run Command...",      "M-x",     0),

    TITLE("Lisp"),
    ITEM(CK_CMD_INDENT_FOR_TAB_COMMAND,  CK_MENU_ALWAYS,        "Indent Line",         "TAB",     1),
    ITEM(CK_CMD_INDENT_REGION,           CK_MENU_ALWAYS,        "Indent Region",       "C-M-\\",  1),
    BAR,
    ITEM(CK_CMD_BEGINNING_OF_DEFUN,      CK_MENU_ALWAYS,        "Beginning of Defun",  "C-M-a",   1),
    ITEM(CK_CMD_END_OF_DEFUN,            CK_MENU_ALWAYS,        "End of Defun",        "C-M-e",   1),
    BAR,
    ITEM(CK_CMD_COMPLETE_SYMBOL,         CK_MENU_CONNECTED,     "Complete Symbol",     "M-TAB",   1),
    ITEM(CK_CMD_ARGLIST,                 CK_MENU_CONNECTED,     "Show Arglist",        NULL,      1),
    ITEM(CK_CMD_DESCRIBE_SYMBOL,         CK_MENU_CONNECTED,     "Describe Symbol...",  "C-c C-d d", 1),
    ITEM(CK_CMD_APROPOS,                 CK_MENU_CONNECTED,     "Apropos...",          "C-c C-d a", 1),
    BAR,
    ITEM(CK_CMD_EDIT_DEFINITION,         CK_MENU_CONNECTED,     "Edit Definition",     "M-.",     1),
    ITEM(CK_CMD_POP_DEFINITION,          CK_MENU_CAN_POP,       "Back from Definition", "M-,",    1),
    BAR,
    ITEM(CK_CMD_MACROEXPAND_1,           CK_MENU_CONNECTED,     "Macroexpand Once",    "C-c RET", 1),
    ITEM(CK_CMD_MACROEXPAND,             CK_MENU_CONNECTED,     "Macroexpand All",     "C-c M-m", 1),

    TITLE("Clamiga"),
    ITEM(CK_CMD_CONNECT,                 CK_MENU_ALWAYS,        "Connect",             NULL,      0),
    ITEM(CK_CMD_RUN_LISP,                CK_MENU_NOT_CONNECTED, "Start clamiga",       NULL,      0),
    BAR,
    ITEM(CK_CMD_LOAD_BUFFER,             CK_MENU_CONNECTED,     "Load Buffer",         "C-c C-k", 1),
    ITEM(CK_CMD_LOAD_FILE,               CK_MENU_CONNECTED,     "Load File...",        "C-c C-l", 1),
    ITEM(CK_CMD_COMPILE_FILE,            CK_MENU_DOC_HAS_PATH,  "Compile File",        NULL,      1),
    BAR,
    ITEM(CK_CMD_EVAL_DEFUN,              CK_MENU_CONNECTED,     "Eval Defun",          "C-c C-c", 1),
    ITEM(CK_CMD_EVAL_LAST_SEXP,          CK_MENU_CONNECTED,     "Eval Last Sexp",      "C-x C-e", 1),
    ITEM(CK_CMD_EVAL_REGION,             CK_MENU_CONNECTED,     "Eval Region",         "C-c C-r", 1),
    ITEM(CK_CMD_EVAL_EXPRESSION,         CK_MENU_CONNECTED,     "Eval Expression...",  "C-c C-e", 1),
    BAR,
    ITEM(CK_CMD_INTERRUPT,               CK_MENU_CONNECTED,     "Interrupt",           "C-c C-b", 1),
    BAR,
    ITEM(CK_CMD_SHOW_ERRORS,             CK_MENU_ALWAYS,        "Show Errors",         "C-c ! l", 1),
    ITEM(CK_CMD_NEXT_ERROR,              CK_MENU_DIAGNOSTICS,   "Next Error",          "C-x `",   1),
    ITEM(CK_CMD_PREVIOUS_ERROR,          CK_MENU_DIAGNOSTICS,   "Previous Error",      "C-x ~",   1),

    TITLE("Windows"),
    ITEM(CK_CMD_REPL,                    CK_MENU_CONNECTED,     "REPL",                "C-c C-z", 0),
    ITEM(CK_CMD_INSPECT,                 CK_MENU_CONNECTED,     "Inspect...",          "C-c I",   1),
    ITEM(CK_CMD_DEBUGGER,                CK_MENU_DEBUGGING,     "Debugger",            NULL,      0),
    BAR,
    ITEM(CK_CMD_REPL_CLEAR,              CK_MENU_REPL_WINDOW,   "Clear Transcript",    "C-c M-o", 2),
    ITEM(CK_CMD_REPL_PREVIOUS_INPUT,     CK_MENU_REPL_WINDOW,   "Previous Input",      "M-p",     2),
    ITEM(CK_CMD_REPL_NEXT_INPUT,         CK_MENU_REPL_WINDOW,   "Next Input",          "M-n",     2),
    BAR,
    ITEM(CK_CMD_OTHER_WINDOW,            CK_MENU_ALWAYS,        "Other Window",        "C-x o",   0),

    { CK_MENU_END, CK_MENU_ALWAYS, CK_CMD_NONE, NULL, NULL, 0 }
};

const ck_menu_entry *ck_menudef_entries(void)
{
    return ck_menu_table;
}

int32_t ck_menudef_count(void)
{
    int32_t n = 0;
    while (ck_menu_table[n].kind != CK_MENU_END)
        n++;
    return n;
}

int32_t ck_menudef_find(int16_t command)
{
    int32_t i;
    for (i = 0; ck_menu_table[i].kind != CK_MENU_END; i++) {
        if (ck_menu_table[i].kind == CK_MENU_ITEM &&
            ck_menu_table[i].command == command)
            return i;
    }
    return -1;
}

int32_t ck_menudef_enabled(uint8_t rule, const ck_menu_state *state)
{
    switch (rule) {
    case CK_MENU_ALWAYS:        return 1;
    case CK_MENU_DOC_CHANGED:   return state->doc_changed != 0;
    case CK_MENU_DOC_HAS_PATH:  return state->doc_has_path != 0;
    case CK_MENU_CONNECTED:     return state->connected != 0;
    case CK_MENU_NOT_CONNECTED: return state->connected == 0;
    case CK_MENU_REPL_WINDOW:   return state->repl_window != 0;
    case CK_MENU_DEBUGGING:     return state->debugging != 0;
    case CK_MENU_DIAGNOSTICS:   return state->diagnostics != 0;
    case CK_MENU_CAN_POP:       return state->can_pop != 0;
    default:                    return 1;
    }
}
