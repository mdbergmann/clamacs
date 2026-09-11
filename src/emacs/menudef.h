/*
 * menudef.h -- the menu strip, as data.
 *
 * The menu is the command table seen from the mouse: every item names a
 * command by its id, so picking an item and typing `M-x <name>' are one
 * path with two entrances.  What is listed here is what a user who has
 * never heard of `C-x C-f' needs to find, plus the commands that have no
 * key at all (connect, run-lisp, compile-file, the arglist).  Cursor and
 * word motion, the kill commands and the like are left out on purpose:
 * nobody picks `forward-char' from a menu.
 *
 * Each item also carries the Emacs key it is bound to, shown in the
 * shortcut column, and an enable rule that says when the item is greyed
 * out.  The rule is evaluated against a plain struct of flags, so the
 * table and the rules are host-tested: tests/test_menudef.c checks that
 * every command exists, that every key shown really runs that command
 * through the real keymaps, and that the rules answer as documented.
 *
 * Pure C: no MUI, no OS types.  src/menu.c turns this into MUI objects.
 */

#ifndef CLAMACS_MENUDEF_H
#define CLAMACS_MENUDEF_H

#include <stdint.h>

/* When an item is enabled. */
typedef enum {
    CK_MENU_ALWAYS = 0,
    CK_MENU_DOC_CHANGED,    /* the active document has unsaved changes */
    CK_MENU_DOC_HAS_PATH,   /* ... has a file behind it */
    CK_MENU_CONNECTED,      /* a clamiga port is known */
    CK_MENU_NOT_CONNECTED,
    CK_MENU_REPL_WINDOW,    /* the active document is the REPL window */
    CK_MENU_DEBUGGING,      /* clamiga's REPL thread is parked in the debugger */
    CK_MENU_DIAGNOSTICS,    /* the error list is not empty */
    CK_MENU_CAN_POP         /* `M-.' has been used: there is a place to go back to */
} ck_menu_rule;

/* What the rules are evaluated against; the MUI layer fills it in from the
 * application state. */
typedef struct {
    uint8_t doc_changed;
    uint8_t doc_has_path;
    uint8_t connected;
    uint8_t repl_window;
    uint8_t debugging;
    uint8_t diagnostics;
    uint8_t can_pop;
} ck_menu_state;

/* What an entry is. */
typedef enum {
    CK_MENU_END = 0,   /* terminates the table */
    CK_MENU_TITLE,     /* a menu heading: `title' names the menu */
    CK_MENU_ITEM,      /* an item that runs `command' */
    CK_MENU_BAR        /* a separator */
} ck_menu_kind;

/* Items that are not editor commands.  Negative so they cannot collide
 * with a command id. */
#define CK_MENU_CMD_ABOUT (-2)

typedef struct {
    uint8_t     kind;      /* ck_menu_kind */
    uint8_t     rule;      /* ck_menu_rule; CK_MENU_ALWAYS for titles and bars */
    int16_t     command;   /* CK_CMD_*, CK_MENU_CMD_ABOUT, or CK_CMD_NONE */
    const char *title;     /* the label, NULL for a bar */
    const char *keys;      /* the key shown beside it, NULL for none */
    /* Which map the key lives in: 0 global, 1 Lisp mode, 2 the REPL window.
     * Only the test reads it; the shortcut column shows the key regardless. */
    uint8_t     map;
} ck_menu_entry;

/* The table, terminated by a CK_MENU_END entry. */
const ck_menu_entry *ck_menudef_entries(void);

/* How many entries precede the terminator. */
int32_t ck_menudef_count(void);

/* The index of the item for COMMAND, or -1. */
int32_t ck_menudef_find(int16_t command);

/* Whether RULE holds for STATE. */
int32_t ck_menudef_enabled(uint8_t rule, const ck_menu_state *state);

#endif /* CLAMACS_MENUDEF_H */
