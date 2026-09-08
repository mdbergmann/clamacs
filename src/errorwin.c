/*
 * errorwin.c -- the diagnostics window.
 *
 * A plain MUI List, deliberately: the error list is the one place where a
 * fancier widget would add a second MCC dependency to the release archive
 * for no functional gain.  Selecting a row jumps to the file and line, which
 * is the whole feature.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

static void ck_errorwin_jump(ck_app *app, int32_t row)
{
    ck_diag *d;
    ck_doc  *doc;

    if (row < 0 || row >= app->diags.count)
        return;

    d = &app->diags.items[row];
    if (d->file == NULL) {
        doc = ck_doc_active(app);
        if (doc != NULL)
            ck_message(doc, "%s", d->text != NULL ? d->text : "");
        return;
    }

    doc = ck_doc_find_by_path(app, d->file);
    if (doc == NULL)
        doc = ck_doc_new(app, d->file);
    if (doc == NULL)
        return;

    set(doc->win, MUIA_Window_Activate, TRUE);
    if (d->line > 0) {
        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(d->line - 1));
    }
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);
    ck_message(doc, "%s", d->text != NULL ? d->text : "");
}

HOOKPROTONHNO(ck_errorwin_active_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    IPTR    active = MUIV_List_Active_Off;

    GetAttr(MUIA_List_Active, app->errorlist, &active);
    if ((LONG)active >= 0)
        ck_errorwin_jump(app, (int32_t)active);
}
MakeStaticHook(ck_errorwin_active_hook, ck_errorwin_active_func);

HOOKPROTONHNO(ck_errorwin_close_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    set(app->errorwin, MUIA_Window_Open, FALSE);
}
MakeStaticHook(ck_errorwin_close_hook, ck_errorwin_close_func);

Object *ck_errorwin_create(ck_app *app)
{
    app->errorwin = WindowObject,
        MUIA_Window_Title,  (IPTR)"clamacs diagnostics",
        MUIA_Window_ID,     MAKE_ID('C','L','E','R'),
        MUIA_Window_Width,  MUIV_Window_Width_Visible(60),
        MUIA_Window_Height, MUIV_Window_Height_Visible(25),
        WindowContents, VGroup,
            Child, ListviewObject,
                MUIA_Listview_List, app->errorlist = ListObject,
                    InputListFrame,
                    MUIA_List_ConstructHook, (IPTR)MUIV_List_ConstructHook_String,
                    MUIA_List_DestructHook,  (IPTR)MUIV_List_DestructHook_String,
                End,
            End,
        End,
    End;

    if (app->errorwin == NULL)
        return NULL;

    DoMethod(app->app, OM_ADDMEMBER, (IPTR)app->errorwin);

    DoMethod(app->errorwin, MUIM_Notify, MUIA_Window_CloseRequest, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_errorwin_close_hook, (IPTR)app);
    DoMethod(app->errorlist, MUIM_Notify, MUIA_List_Active, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_errorwin_active_hook, (IPTR)app);

    return app->errorwin;
}

void ck_errorwin_fill(ck_app *app)
{
    int32_t i;

    if (app->errorlist == NULL)
        return;

    set(app->errorlist, MUIA_List_Quiet, TRUE);
    DoMethod(app->errorlist, MUIM_List_Clear);

    for (i = 0; i < app->diags.count; i++) {
        const char *row = app->diags.items[i].rendered;
        if (row == NULL)
            row = "";
        DoMethod(app->errorlist, MUIM_List_InsertSingle, (IPTR)row,
                 (IPTR)MUIV_List_Insert_Bottom);
    }

    /* Setting Active would fire the notification and jump somewhere the user
     * did not ask to go, so the list comes up with nothing selected. */
    set(app->errorlist, MUIA_List_Active, (IPTR)MUIV_List_Active_Off);
    set(app->errorlist, MUIA_List_Quiet, FALSE);
}

void ck_errorwin_show(ck_app *app, const char *text)
{
    if (app->errorwin == NULL)
        return;
    if (text != NULL && app->errorlist != NULL) {
        DoMethod(app->errorlist, MUIM_List_InsertSingle, (IPTR)text,
                 (IPTR)MUIV_List_Insert_Bottom);
    }
    set(app->errorwin, MUIA_Window_Open, TRUE);
}
