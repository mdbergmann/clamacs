/*
 * menu.c -- the menu strip.
 *
 * One strip for the whole application (MUIA_Application_Menustrip), so
 * every window -- documents, the REPL, the debugger, the inspector, the
 * error list -- shows the same menus, and an item acts on the active
 * document exactly as the ARexx port's `EVAL' does: through
 * ck_doc_run_command() with the command id the item carries in its
 * MUIA_UserData.  The menu is therefore a third entrance to the command
 * table beside the keys and the port, not a second implementation of
 * anything.
 *
 * The strip is built from src/emacs/menudef.c, which is data and
 * host-tested; this file only turns entries into Menu and Menuitem
 * objects, reacts to MUIA_Application_MenuAction, and keeps
 * MUIA_Menuitem_Enabled in step with the application state.  The Emacs
 * key of an item is shown in the shortcut column as a command string
 * (MUIA_Menuitem_CommandString): MUI displays it and, as the autodoc
 * says, does not check for it -- the keys are the Emacs layer's.
 *
 * Enable state: ck_menu_update() computes the flags the rules need, asks
 * menudef which items should be enabled, and sets only the ones whose
 * state changed.  It is cheap enough to call from everywhere the state
 * can move (a keystroke, an activation, a reply, a debugger message), and
 * that is how it is called -- there is no notification for "the active
 * document changed", so polling at those points is the honest way.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

#include <libraries/gadtools.h>   /* NM_BARLABEL */

/* The items, by table index.  One application per process (see main.c),
 * so file scope is where they live. */
#define CK_MENU_MAX 96
static Object *ck_menu_items[CK_MENU_MAX];
static int8_t  ck_menu_enabled[CK_MENU_MAX];   /* -1 unknown, else the state set */

/* MUIA_UserData of the item at table index I.  Non-zero, so an action of
 * 0 -- which MUI reports for items without user data -- is never taken
 * for the first entry. */
#define CK_MENU_ID(i)       ((ULONG)(i) + 1UL)
#define CK_MENU_INDEX(id)   ((int32_t)(id) - 1)

/* ------------------------------------------------------------------ *
 * The action
 * ------------------------------------------------------------------ */

static void ck_menu_about(ck_app *app, ck_doc *doc)
{
    char text[512];

    snprintf(text, sizeof text,
             "clamacs 0.1 (" __DATE__ ")\n"
             "An Emacs-flavoured Common Lisp IDE for clamiga\n"
             "\n"
             "muimaster.library %ld.%ld\n"
             "TextEditor.mcc %ld.%ld\n"
             "clamiga: %s",
             (long)MUIMasterBase->lib_Version, (long)MUIMasterBase->lib_Revision,
             (long)app->te_version, (long)app->te_revision,
             app->connected
                 ? (app->version[0] != '\0' ? app->version : app->clamiga_port)
                 : "not connected");

    MUI_Request(app->app, doc != NULL ? doc->win : NULL, 0, "About clamacs",
                "_OK", "%s", text);
}

/* Run the item at table index I on the active document. */
int32_t ck_menu_pick(ck_app *app, int32_t i)
{
    const ck_menu_entry *t = ck_menudef_entries();
    ck_doc *doc;

    if (i < 0 || i >= ck_menudef_count() || t[i].kind != CK_MENU_ITEM)
        return 0;

    doc = ck_doc_active(app);
    if (t[i].command == CK_MENU_CMD_ABOUT) {
        ck_menu_about(app, doc);
        return 1;
    }
    if (doc == NULL)
        return 0;
    ck_doc_run_command(doc, t[i].command, 1);
    return 1;
}

HOOKPROTONHNO(ck_menu_action_func, void, ULONG *params)
{
    ck_app *app = ck_app_current();
    if (app != NULL)
        ck_menu_pick(app, CK_MENU_INDEX(params[0]));
}
MakeStaticHook(ck_menu_action_hook, ck_menu_action_func);

/* ------------------------------------------------------------------ *
 * Building
 * ------------------------------------------------------------------ */

Object *ck_menu_create(ck_app *app)
{
    const ck_menu_entry *t = ck_menudef_entries();
    Object *strip, *menu = NULL;
    int32_t i, n = ck_menudef_count();

    (void)app;
    if (n > CK_MENU_MAX)
        return NULL;

    strip = MenustripObject, End;
    if (strip == NULL)
        return NULL;

    for (i = 0; i < n; i++) {
        Object *item = NULL;

        ck_menu_items[i]   = NULL;
        ck_menu_enabled[i] = -1;

        switch (t[i].kind) {
        case CK_MENU_TITLE:
            menu = MenuObjectT((IPTR)t[i].title), End;
            if (menu == NULL)
                goto fail;
            DoMethod(strip, MUIM_Family_AddTail, (IPTR)menu);
            continue;

        case CK_MENU_BAR:
            item = MenuitemObject,
                MUIA_Menuitem_Title, (IPTR)NM_BARLABEL,
            End;
            break;

        case CK_MENU_ITEM:
            if (t[i].keys != NULL) {
                item = MenuitemObject,
                    MUIA_Menuitem_Title,         (IPTR)t[i].title,
                    MUIA_Menuitem_Shortcut,      (IPTR)t[i].keys,
                    MUIA_Menuitem_CommandString, TRUE,
                    MUIA_UserData,               CK_MENU_ID(i),
                End;
            } else {
                item = MenuitemObject,
                    MUIA_Menuitem_Title,         (IPTR)t[i].title,
                    MUIA_UserData,               CK_MENU_ID(i),
                End;
            }
            break;

        default:
            continue;
        }

        if (item == NULL || menu == NULL)
            goto fail;
        DoMethod(menu, MUIM_Family_AddTail, (IPTR)item);
        ck_menu_items[i] = item;
    }

    return strip;

fail:
    /* The children added so far go with the strip. */
    MUI_DisposeObject(strip);
    for (i = 0; i < n; i++)
        ck_menu_items[i] = NULL;
    return NULL;
}

void ck_menu_attach(ck_app *app)
{
    if (app->app == NULL || app->menustrip == NULL)
        return;
    DoMethod(app->app, MUIM_Notify, MUIA_Application_MenuAction, MUIV_EveryTime,
             MUIV_Notify_Self, 3, MUIM_CallHook, (IPTR)&ck_menu_action_hook,
             MUIV_TriggerValue);
    ck_menu_update(app);
}

/* ------------------------------------------------------------------ *
 * Enable state
 * ------------------------------------------------------------------ */

void ck_menu_update(ck_app *app)
{
    const ck_menu_entry *t = ck_menudef_entries();
    ck_menu_state st;
    ck_doc *doc;
    int32_t i, n;

    if (app->menustrip == NULL || app->quitting)
        return;

    doc = ck_doc_active(app);
    memset(&st, 0, sizeof st);
    if (doc != NULL) {
        IPTR changed = 0;
        GetAttr(MUIA_TextEditor_HasChanged, doc->text, &changed);
        st.doc_changed  = (changed != 0);
        st.doc_has_path = (doc->path[0] != '\0');
        st.repl_window  = (doc->repl_mode != 0);
    }
    st.connected   = (app->connected != 0);
    st.debugging   = (app->dbg_level > 0);
    st.diagnostics = (app->diags.count > 0);
    st.can_pop     = (ck_locstack_depth(&app->locations) > 0);

    n = ck_menudef_count();
    for (i = 0; i < n; i++) {
        int8_t want;
        if (ck_menu_items[i] == NULL || t[i].kind != CK_MENU_ITEM)
            continue;
        want = (int8_t)ck_menudef_enabled(t[i].rule, &st);
        if (want == ck_menu_enabled[i])
            continue;
        set(ck_menu_items[i], MUIA_Menuitem_Enabled, (IPTR)want);
        ck_menu_enabled[i] = want;
    }
}

/* ------------------------------------------------------------------ *
 * For the port
 * ------------------------------------------------------------------ */

int32_t ck_menu_find(const char *command)
{
    int16_t cmd = ck_command_lookup(command);
    if (cmd == CK_CMD_NONE)
        return -1;
    return ck_menudef_find(cmd);
}

int32_t ck_menu_is_enabled(int32_t i)
{
    if (i < 0 || i >= ck_menudef_count() || ck_menu_items[i] == NULL)
        return 0;
    return ck_menu_enabled[i] > 0;
}
