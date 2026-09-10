/*
 * command.h -- the command table.
 *
 * Commands are named, and the name is the whole point: `M-x' and the
 * editor's own ARexx port (`EVAL <command-name>') share one namespace, so a
 * macro can drive anything a key can.  The list below is the single source
 * of both the enum and the name table -- they cannot drift apart, which
 * matters because the ARexx port turns a string from another program into a
 * command id.
 *
 * Pure C: no MUI, no OS types.  What each command DOES lives in the MUI
 * layer; what each command IS lives here and is host-tested.
 */

#ifndef CLAMACS_COMMAND_H
#define CLAMACS_COMMAND_H

#include <stdint.h>

/*
 * X(ENUM_SUFFIX, "emacs-name")
 *
 * Order is not significant; keep it grouped the way the phase-1 key table in
 * specs/clamacs-ide.md is grouped, so the two can be read side by side.
 */
#define CK_COMMAND_LIST(X)                                                    \
    /* movement */                                                            \
    X(FORWARD_CHAR,             "forward-char")                               \
    X(BACKWARD_CHAR,            "backward-char")                              \
    X(NEXT_LINE,                "next-line")                                  \
    X(PREVIOUS_LINE,            "previous-line")                              \
    X(BEGINNING_OF_LINE,        "beginning-of-line")                          \
    X(END_OF_LINE,              "end-of-line")                                \
    X(FORWARD_WORD,             "forward-word")                               \
    X(BACKWARD_WORD,            "backward-word")                              \
    X(BEGINNING_OF_BUFFER,      "beginning-of-buffer")                        \
    X(END_OF_BUFFER,            "end-of-buffer")                              \
    X(SCROLL_UP,                "scroll-up")                                  \
    X(SCROLL_DOWN,              "scroll-down")                                \
    X(GOTO_LINE,                "goto-line")                                  \
    X(RECENTER,                 "recenter")                                   \
    /* deleting, killing, yanking */                                          \
    X(DELETE_CHAR,              "delete-char")                                \
    X(BACKWARD_DELETE_CHAR,     "backward-delete-char")                       \
    X(KILL_WORD,                "kill-word")                                  \
    X(BACKWARD_KILL_WORD,       "backward-kill-word")                         \
    X(KILL_LINE,                "kill-line")                                  \
    X(KILL_REGION,              "kill-region")                                \
    X(KILL_RING_SAVE,           "kill-ring-save")                             \
    X(YANK,                     "yank")                                       \
    X(YANK_POP,                 "yank-pop")                                   \
    /* mark and region */                                                     \
    X(SET_MARK_COMMAND,         "set-mark-command")                           \
    X(MARK_WHOLE_BUFFER,        "mark-whole-buffer")                          \
    X(EXCHANGE_POINT_AND_MARK,  "exchange-point-and-mark")                    \
    /* undo */                                                                \
    X(UNDO,                     "undo")                                       \
    X(REDO,                     "redo")                                       \
    /* search */                                                              \
    X(ISEARCH_FORWARD,          "isearch-forward")                            \
    X(ISEARCH_BACKWARD,         "isearch-backward")                           \
    /* files, buffers, windows */                                             \
    X(FIND_FILE,                "find-file")                                  \
    X(FIND_FILE_OTHER_WINDOW,   "find-file-other-window")                     \
    X(SAVE_BUFFER,              "save-buffer")                                \
    X(WRITE_FILE,               "write-file")                                 \
    X(SWITCH_TO_BUFFER,         "switch-to-buffer")                           \
    X(KILL_BUFFER,              "kill-buffer")                                \
    X(OTHER_WINDOW,             "other-window")                               \
    X(SAVE_BUFFERS_KILL_EMACS,  "save-buffers-kill-emacs")                    \
    /* the command loop itself.  `C-u' is deliberately absent: the numeric
     * argument is read by the key state machine before dispatch, so it never
     * becomes a command and `M-x universal-argument' would be meaningless. */\
    X(EXECUTE_EXTENDED_COMMAND, "execute-extended-command")                   \
    X(KEYBOARD_QUIT,            "keyboard-quit")                              \
    /* Lisp mode: structure */                                                \
    X(FORWARD_SEXP,             "forward-sexp")                               \
    X(BACKWARD_SEXP,            "backward-sexp")                              \
    X(BACKWARD_UP_LIST,         "backward-up-list")                           \
    X(DOWN_LIST,                "down-list")                                  \
    X(BEGINNING_OF_DEFUN,       "beginning-of-defun")                         \
    X(END_OF_DEFUN,             "end-of-defun")                               \
    X(KILL_SEXP,                "kill-sexp")                                  \
    X(INSERT_PARENTHESES,       "insert-parentheses")                         \
    X(INDENT_FOR_TAB_COMMAND,   "indent-for-tab-command")                     \
    X(NEWLINE_AND_INDENT,       "newline-and-indent")                         \
    X(INDENT_REGION,            "indent-region")                              \
    /* Lisp mode: talking to clamiga.  No interrupt yet -- clamiga has no
     * command for it until the phase-3 REPL thread exists. */               \
    X(LOAD_BUFFER,              "clamacs-load-buffer")                        \
    X(LOAD_FILE,                "clamacs-load-file")                          \
    X(COMPILE_FILE,             "clamacs-compile-file")                       \
    X(EVAL_DEFUN,               "clamacs-eval-defun")                         \
    X(EVAL_LAST_SEXP,           "clamacs-eval-last-sexp")                     \
    X(EVAL_REGION,              "clamacs-eval-region")                        \
    X(EVAL_EXPRESSION,          "clamacs-eval-expression")                    \
    X(CONNECT,                  "clamacs-connect")                            \
    X(SHOW_ERRORS,              "clamacs-show-errors")                        \
    X(NEXT_ERROR,               "clamacs-next-error")                         \
    X(PREVIOUS_ERROR,           "clamacs-previous-error")                     \
    X(RUN_LISP,                 "run-lisp")                                   \
    /* Lisp mode: introspection (phase 2).  `complete-symbol' keeps its Emacs
     * name because it is the same key doing the same thing; the rest carry
     * the editor's prefix, as the other clamiga commands do. */              \
    X(COMPLETE_SYMBOL,          "complete-symbol")                            \
    X(ARGLIST,                  "clamacs-arglist")                            \
    X(EDIT_DEFINITION,          "clamacs-edit-definition")                    \
    X(POP_DEFINITION,           "clamacs-pop-definition")                     \
    X(DESCRIBE_SYMBOL,          "clamacs-describe-symbol")                    \
    X(APROPOS,                  "clamacs-apropos")                            \
    X(MACROEXPAND_1,            "clamacs-macroexpand-1")                      \
    X(MACROEXPAND,              "clamacs-macroexpand")

typedef enum {
    CK_CMD_NONE = -1,
#define CK_COMMAND_ENUM(sym, name) CK_CMD_##sym,
    CK_COMMAND_LIST(CK_COMMAND_ENUM)
#undef CK_COMMAND_ENUM
    CK_CMD_COUNT
} ck_command;

/* Name of a command id, or NULL when the id is out of range. */
const char *ck_command_name(int16_t id);

/* Command id for a name, or CK_CMD_NONE.  Exact match, case sensitive:
 * command names are lowercase by convention and an ARexx macro that sends
 * `FIND-FILE' has a bug, not a spelling variant. */
int16_t ck_command_lookup(const char *name);

/* Completion over command names for the minibuffer.  Fills OUT with up to
 * MAX pointers to the (static) names that start with PREFIX, in table order,
 * and returns how many matched.  COMMON, when not NULL, receives the longest
 * common prefix of the matches (NUL-terminated, at most COMMON_SIZE bytes),
 * which is what TAB inserts. */
int32_t ck_command_complete(const char *prefix, const char **out, int32_t max,
                            char *common, int32_t common_size);

#endif /* CLAMACS_COMMAND_H */
