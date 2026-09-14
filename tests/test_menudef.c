/*
 * test_menudef.c -- the menu strip as data.
 *
 * Three promises the table makes, each checkable on the host:
 *   - every item names a real command (or the About pseudo-command), and
 *     no command is listed twice;
 *   - the key shown in an item's shortcut column really runs that command,
 *     fed through the real state machine against the real maps -- a
 *     rebinding that forgets the menu fails here, not on an Amiga;
 *   - the enable rules answer as menudef.h documents them.
 */

#include "test.h"
#include "emacs/menudef.h"
#include "emacs/bindings.h"
#include "emacs/command.h"

static int16_t resolve(const char *keys, ck_keymap *global, ck_keymap *local)
{
    ck_keystate  st;
    const char  *p = keys;
    char         spelling[32];
    ck_keyresult r   = CK_KEY_UNBOUND;
    int16_t      cmd = CK_CMD_NONE;

    ck_keystate_init(&st, global, local);
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
    return (r == CK_KEY_COMMAND) ? cmd : CK_CMD_NONE;
}

TEST(table_is_well_formed)
{
    const ck_menu_entry *t = ck_menudef_entries();
    int32_t i, titles = 0, items = 0;
    int32_t seen[CK_CMD_COUNT];

    memset(seen, 0, sizeof seen);
    ASSERT(t[0].kind == CK_MENU_TITLE);   /* the first entry opens a menu */

    for (i = 0; t[i].kind != CK_MENU_END; i++) {
        switch (t[i].kind) {
        case CK_MENU_TITLE:
            ASSERT(t[i].title != NULL && t[i].title[0] != '\0');
            titles++;
            break;
        case CK_MENU_BAR:
            ASSERT(t[i].title == NULL);
            /* A bar never opens or closes a menu. */
            ASSERT(i > 0 && t[i - 1].kind != CK_MENU_TITLE);
            ASSERT(t[i + 1].kind == CK_MENU_ITEM);
            break;
        case CK_MENU_ITEM:
            ASSERT(t[i].title != NULL && t[i].title[0] != '\0');
            if (t[i].command == CK_MENU_CMD_ABOUT) {
                ASSERT(t[i].keys == NULL);
            } else {
                ASSERT(t[i].command >= 0 && t[i].command < (int16_t)CK_CMD_COUNT);
                ASSERT(ck_command_name(t[i].command) != NULL);
                ASSERT(!seen[t[i].command]);   /* listed once */
                seen[t[i].command] = 1;
            }
            ASSERT(t[i].rule <= CK_MENU_CAN_POP);
            ASSERT(t[i].map <= 2);
            items++;
            break;
        default:
            ASSERT(0);
        }
    }
    ASSERT_EQ_INT(i, ck_menudef_count());
    ASSERT_EQ_INT(titles, 6);
    ASSERT(items > 30);
}

TEST(find_returns_the_item)
{
    const ck_menu_entry *t = ck_menudef_entries();
    int32_t i = ck_menudef_find(CK_CMD_SAVE_BUFFER);

    ASSERT(i >= 0);
    ASSERT_EQ_INT(t[i].command, CK_CMD_SAVE_BUFFER);
    ASSERT_EQ_INT(t[i].rule, CK_MENU_DOC_CHANGED);
    ASSERT_EQ_INT(ck_menudef_find(CK_CMD_FORWARD_CHAR), -1);   /* not in the menu */
    ASSERT_EQ_INT(ck_menudef_find(CK_CMD_NONE), -1);
}

TEST(the_unbound_commands_are_reachable_from_the_menu)
{
    /* The reason the menu exists for these: they have no key. */
    ASSERT(ck_menudef_find(CK_CMD_NEW_BUFFER) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_CONNECT) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_RUN_LISP) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_COMPILE_FILE) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_ARGLIST) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_DEBUGGER) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_SNAPSHOT_WINDOWS) >= 0);
    ASSERT(ck_menudef_find(CK_CMD_HYPERSPEC) >= 0);
}

TEST(every_shortcut_shown_runs_its_command)
{
    const ck_menu_entry *t = ck_menudef_entries();
    ck_keymap *global = ck_bindings_global();
    ck_keymap *lisp   = ck_bindings_lisp();
    ck_keymap *repl   = ck_bindings_repl();
    int32_t    i;

    ASSERT(global != NULL && lisp != NULL && repl != NULL);

    for (i = 0; t[i].kind != CK_MENU_END; i++) {
        ck_keymap *local;
        int16_t    got;

        if (t[i].kind != CK_MENU_ITEM || t[i].keys == NULL)
            continue;
        local = (t[i].map == 1) ? lisp : (t[i].map == 2) ? repl : NULL;
        got   = resolve(t[i].keys, global, local);
        if (got != t[i].command) {
            printf("  %s shows %s, which runs %s\n", t[i].title, t[i].keys,
                   got == CK_CMD_NONE ? "nothing" : ck_command_name(got));
            test_current_failed = 1;
        }
    }

    ck_keymap_free(global);
    ck_keymap_free(lisp);
    ck_keymap_free(repl);
}

TEST(rules)
{
    ck_menu_state s;

    memset(&s, 0, sizeof s);
    ASSERT(ck_menudef_enabled(CK_MENU_ALWAYS, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_DOC_CHANGED, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_DOC_HAS_PATH, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_CONNECTED, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_NOT_CONNECTED, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_REPL_WINDOW, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_DEBUGGING, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_DIAGNOSTICS, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_CAN_POP, &s));

    s.doc_changed = s.doc_has_path = s.connected = s.repl_window = 1;
    s.debugging = s.diagnostics = s.can_pop = 1;
    ASSERT(ck_menudef_enabled(CK_MENU_DOC_CHANGED, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_DOC_HAS_PATH, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_CONNECTED, &s));
    ASSERT(!ck_menudef_enabled(CK_MENU_NOT_CONNECTED, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_REPL_WINDOW, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_DEBUGGING, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_DIAGNOSTICS, &s));
    ASSERT(ck_menudef_enabled(CK_MENU_CAN_POP, &s));
}

int main(void)
{
    RUN(table_is_well_formed);
    RUN(find_returns_the_item);
    RUN(the_unbound_commands_are_reachable_from_the_menu);
    RUN(every_shortcut_shown_runs_its_command);
    RUN(rules);
    REPORT();
}
