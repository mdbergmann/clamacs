/*
 * inspectwin.c -- phase 4: the inspector window.
 *
 * `C-c I' asks for a form, clamiga evaluates it and answers INSPECT with
 * the object and its numbered parts (cl-amiga's lib/dev-commands.lisp:
 * a header `<TYPE> <depth> <count>', the object, then `<n>: <label> =
 * <value>' per part).  The window shows the object and the parts;
 * double-clicking a part sends PART <n> and the window shows that, Back
 * sends POP.  The navigation stack lives in clamiga, one per connection,
 * so the editor only mirrors the depth it is told.  Synchronous replies,
 * unlike the debugger's: the object is evaluated on the port's handler
 * thread (with the REPL's `*' in scope, so `C-c I *' looks at the last
 * REPL value).
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

static LONG ck_insp_get(Object *obj, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, obj, &value);
    return (LONG)value;
}

static ck_doc *ck_inspect_doc(ck_app *app)
{
    return ck_doc_active(app);
}

/* ------------------------------------------------------------------ *
 * The commands
 * ------------------------------------------------------------------ */

void ck_inspect_prompt(ck_doc *doc)
{
    ck_doc_prompt(doc, "Inspect value (evaluated): ", "", CK_CMD_INSPECT,
                  CK_COMPLETE_NONE, 0);
}

void ck_inspect_form(ck_doc *doc, const char *form)
{
    if (form == NULL || form[0] == '\0') {
        ck_beep(doc);
        return;
    }
    ck_doc_send_package(doc, 1);
    ck_rexx_send_text(doc->app, doc, CK_REQ_INSPECT, "INSPECT ", form);
}

static int32_t ck_inspect_active(ck_doc *doc)
{
    if (doc->app->insp_depth > 0)
        return 1;
    ck_message(doc, "Nothing is being inspected (C-c I inspects a value)");
    ck_beep(doc);
    return 0;
}

void ck_inspect_part(ck_doc *doc, int32_t n)
{
    if (!ck_inspect_active(doc))
        return;
    if (n < 0) {
        ck_doc_prompt(doc, "Part: ", "", CK_CMD_INSPECTOR_PART, CK_COMPLETE_NONE, 0);
        return;
    }
    ck_rexx_send(doc->app, doc, CK_REQ_INSPECT, "PART %ld", (long)n);
}

void ck_inspect_pop(ck_doc *doc)
{
    if (!ck_inspect_active(doc))
        return;
    if (doc->app->insp_depth == 1) {
        ck_message(doc, "Already at the object the inspector started from");
        ck_beep(doc);
        return;
    }
    ck_rexx_send(doc->app, doc, CK_REQ_INSPECT, "POP");
}

/* ------------------------------------------------------------------ *
 * The reply
 * ------------------------------------------------------------------ */

void ck_inspect_reply(ck_app *app, ck_doc *doc, int32_t rc, const char *text)
{
    const char *p;
    char        type[64], line[CK_MSG_MAX];
    int32_t     depth = 0, count = 0, listed = 0;

    if (text == NULL)
        text = "";

    if (rc != CK_RC_OK || !ck_dbg_inspect_header(text, type, (int32_t)sizeof type,
                                                 &depth, &count)) {
        p = text;
        if (!ck_dbg_line(&p, line, (int32_t)sizeof line) || line[0] == '\0')
            strcpy(line, "clamiga could not inspect that");
        if (doc != NULL) {
            ck_message(doc, "%s", line);
            ck_beep(doc);
        }
        return;
    }
    if (app->inspectwin == NULL)
        return;

    /* The header, the object, then the parts. */
    p = text;
    ck_dbg_line(&p, line, (int32_t)sizeof line);
    if (!ck_dbg_line(&p, line, (int32_t)sizeof line))
        line[0] = '\0';
    strncpy(app->insp_object, line, sizeof app->insp_object - 1);
    app->insp_object[sizeof app->insp_object - 1] = '\0';
    set(app->insp_object_obj, MUIA_Text_Contents, (IPTR)app->insp_object);

    set(app->insp_parts, MUIA_List_Quiet, TRUE);
    DoMethod(app->insp_parts, MUIM_List_Clear);
    while (ck_dbg_line(&p, line, (int32_t)sizeof line)) {
        if (line[0] == '\0')
            continue;
        DoMethod(app->insp_parts, MUIM_List_InsertSingle, (IPTR)line,
                 (IPTR)MUIV_List_Insert_Bottom);
        listed++;
    }
    if (count > listed) {
        snprintf(line, sizeof line, "... %ld more part(s); M-x clamacs-inspector-part takes any number",
                 (long)(count - listed));
        DoMethod(app->insp_parts, MUIM_List_InsertSingle, (IPTR)line,
                 (IPTR)MUIV_List_Insert_Bottom);
    }
    set(app->insp_parts, MUIA_List_Active, (IPTR)MUIV_List_Active_Off);
    set(app->insp_parts, MUIA_List_Quiet, FALSE);

    app->insp_depth = depth;
    snprintf(app->insp_title, sizeof app->insp_title, "clamacs inspector: %s", type);
    set(app->inspectwin, MUIA_Window_Title, (IPTR)app->insp_title);
    set(app->insp_back_btn, MUIA_Disabled, depth <= 1);
    set(app->inspectwin, MUIA_Window_Open, TRUE);
    set(app->inspectwin, MUIA_Window_Activate, TRUE);

    if (doc != NULL)
        ck_message(doc, "Inspecting %s: %s", type, app->insp_object);
}

/* ------------------------------------------------------------------ *
 * The window
 * ------------------------------------------------------------------ */

/* Double-click on a part, or the Part button. */
HOOKPROTONHNO(ck_inspect_part_click_func, void, ULONG *params)
{
    ck_app *app    = (ck_app *)params[0];
    LONG    active = ck_insp_get(app->insp_parts, MUIA_List_Active);
    STRPTR  entry  = NULL;
    ck_doc *doc    = ck_inspect_doc(app);
    int32_t n;

    if (doc == NULL || active < 0)
        return;
    DoMethod(app->insp_parts, MUIM_List_GetEntry, (IPTR)active, (IPTR)&entry);
    /* The row's own number, not its position: the `... more' row has
     * none. */
    n = (entry != NULL) ? ck_dbg_row_index((const char *)entry) : -1;
    if (n < 0) {
        ck_message(doc, "Not a part");
        ck_beep(doc);
        return;
    }
    ck_inspect_part(doc, n);
}
MakeStaticHook(ck_inspect_part_click_hook, ck_inspect_part_click_func);

HOOKPROTONHNO(ck_inspect_back_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    ck_doc *doc = ck_inspect_doc(app);
    if (doc != NULL)
        ck_inspect_pop(doc);
}
MakeStaticHook(ck_inspect_back_hook, ck_inspect_back_func);

HOOKPROTONHNO(ck_inspect_close_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    set(app->inspectwin, MUIA_Window_Open, FALSE);
}
MakeStaticHook(ck_inspect_close_hook, ck_inspect_close_func);

Object *ck_inspectwin_create(ck_app *app)
{
    Object *part_btn;

    app->insp_depth     = 0;
    app->insp_object[0] = '\0';
    strcpy(app->insp_title, "clamacs inspector");

    app->inspectwin = WindowObject,
        MUIA_Window_Title,  (IPTR)app->insp_title,
        MUIA_Window_ID,     MAKE_ID('C','L','I','N'),
        MUIA_Window_Width,  MUIV_Window_Width_Visible(50),
        MUIA_Window_Height, MUIV_Window_Height_Visible(40),
        WindowContents, VGroup,
            Child, app->insp_object_obj = TextObject,
                MUIA_Text_Contents, (IPTR)app->insp_object,
                MUIA_Text_SetMin,   FALSE,
                MUIA_Frame,         MUIV_Frame_Text,
                MUIA_Background,    MUII_TextBack,
            End,
            Child, ListviewObject,
                MUIA_Listview_DoubleClick, TRUE,
                MUIA_Listview_List, app->insp_parts = ListObject,
                    InputListFrame,
                    MUIA_List_ConstructHook, (IPTR)MUIV_List_ConstructHook_String,
                    MUIA_List_DestructHook,  (IPTR)MUIV_List_DestructHook_String,
                End,
            End,
            Child, HGroup,
                Child, part_btn = KeyButton("Inspect _part", 'p'),
                Child, app->insp_back_btn = KeyButton("_Back", 'b'),
            End,
        End,
    End;

    if (app->inspectwin == NULL)
        return NULL;

    DoMethod(app->app, OM_ADDMEMBER, (IPTR)app->inspectwin);

    DoMethod(app->inspectwin, MUIM_Notify, MUIA_Window_CloseRequest, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_inspect_close_hook, (IPTR)app);
    DoMethod(app->insp_parts, MUIM_Notify, MUIA_Listview_DoubleClick, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_inspect_part_click_hook, (IPTR)app);
    DoMethod(part_btn, MUIM_Notify, MUIA_Pressed, FALSE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_inspect_part_click_hook, (IPTR)app);
    DoMethod(app->insp_back_btn, MUIM_Notify, MUIA_Pressed, FALSE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_inspect_back_hook, (IPTR)app);

    return app->inspectwin;
}
