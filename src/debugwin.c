/*
 * debugwin.c -- phase 4: the debugger window.
 *
 * When a form at the REPL signals an unhandled error, clamiga's REPL thread
 * (attached with REPL-ATTACH ... DEBUG) does not end the form: it stays on
 * the erring stack, sends `DEBUGGER <level>' with the condition and the
 * restarts to the editor's port, and waits for its next step over the port
 * -- BACKTRACE, FRAME, FRAME-EVAL, RESTART, ABORT, CONTINUE (cl-amiga's
 * lib/dev-repl.lisp has the protocol; specs/clamacs-ide.md, phase 4).
 * This window is the editor's face for that: the condition, the restarts
 * (double-click invokes one), the backtrace (selecting a frame asks for its
 * locals, double-click opens its source), the locals, and a line to
 * evaluate in the selected frame, whose values land in the REPL transcript
 * as OUTPUT.  `DEBUGGER 0' -- the thread has left the debugger -- closes
 * it; a nested level (an error inside a FRAME-EVAL) refreshes it, and
 * leaving that level refreshes it again with the level below.
 *
 * Everything here is asynchronous, as the rest of the client is: a button
 * queues a request and returns, and the reply (or the next DEBUGGER
 * message) does the rest.  The window is one MUI object per application,
 * created at startup and opened on demand, like the error list.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

static LONG ck_dbg_get(Object *obj, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, obj, &value);
    return (LONG)value;
}

/* Where messages about the debugger go: the REPL window, whose form is
 * being debugged, else the active document. */
static ck_doc *ck_debug_doc(ck_app *app)
{
    if (app->repl != NULL && !app->repl->closing)
        return app->repl;
    return ck_doc_active(app);
}

static void ck_debug_first_line(const char *text, char *out, int32_t size)
{
    const char *p = text;
    if (!ck_dbg_line(&p, out, size))
        out[0] = '\0';
}

/* One row per non-empty line of TEXT. */
static void ck_debug_list_fill(Object *list, const char *text)
{
    const char *p = (text != NULL) ? text : "";
    char        line[CK_MSG_MAX];

    set(list, MUIA_List_Quiet, TRUE);
    DoMethod(list, MUIM_List_Clear);
    while (ck_dbg_line(&p, line, (int32_t)sizeof line)) {
        if (line[0] != '\0')
            DoMethod(list, MUIM_List_InsertSingle, (IPTR)line,
                     (IPTR)MUIV_List_Insert_Bottom);
    }
    set(list, MUIA_List_Quiet, FALSE);
}

static int32_t ck_debug_active(ck_doc *doc)
{
    ck_app *app = doc->app;

    if (app->dbg_level > 0)
        return 1;
    ck_message(doc, "The REPL is not in the debugger");
    ck_beep(doc);
    return 0;
}

/* ------------------------------------------------------------------ *
 * What clamiga announces
 * ------------------------------------------------------------------ */

void ck_debug_entered(ck_app *app, int32_t level, const char *text)
{
    ck_doc     *doc = ck_debug_doc(app);
    const char *p   = (text != NULL) ? text : "";
    char        line[CK_MSG_MAX];
    int32_t     has_continue = 0;

    if (app->debugwin == NULL)
        return;

    app->dbg_level = level;
    app->dbg_frame = -1;

    /* The condition is the first line; the restarts follow.  A CONTINUE
     * restart among them enables the button. */
    if (!ck_dbg_line(&p, line, (int32_t)sizeof line))
        line[0] = '\0';
    strncpy(app->dbg_condition, line, sizeof app->dbg_condition - 1);
    app->dbg_condition[sizeof app->dbg_condition - 1] = '\0';
    set(app->dbg_condition_obj, MUIA_Text_Contents, (IPTR)app->dbg_condition);

    ck_debug_list_fill(app->dbg_restarts, p);
    {
        const char *q = p;
        while (ck_dbg_line(&q, line, (int32_t)sizeof line)) {
            const char *name = strchr(line, ':');
            if (name != NULL && strncmp(name, ": CONTINUE", 10) == 0 &&
                (name[10] == ' ' || name[10] == '\0'))
                has_continue = 1;
        }
    }
    set(app->dbg_continue_btn, MUIA_Disabled, !has_continue);

    DoMethod(app->dbg_frames, MUIM_List_Clear);
    DoMethod(app->dbg_locals, MUIM_List_Clear);

    snprintf(app->dbg_title, sizeof app->dbg_title, "clamacs debugger (level %ld)",
             (long)level);
    set(app->debugwin, MUIA_Window_Title, (IPTR)app->dbg_title);
    /* Opened, not activated: it arrives asynchronously, while the user
     * may be typing, and the keyboard stays where it was -- `M-x
     * clamacs-debugger' gives the window the focus on purpose. */
    set(app->debugwin, MUIA_Window_Open, TRUE);

    if (doc != NULL)
        ck_message(doc, "Debugger level %ld: %s", (long)level, app->dbg_condition);

    /* The frames come separately, and frame 0's locals once they are in. */
    ck_rexx_send(app, doc, CK_REQ_DBG_BACKTRACE, "BACKTRACE");
}

void ck_debug_left(ck_app *app)
{
    app->dbg_level = 0;
    app->dbg_frame = -1;
    if (app->debugwin != NULL)
        set(app->debugwin, MUIA_Window_Open, FALSE);
}

/* ------------------------------------------------------------------ *
 * The commands
 * ------------------------------------------------------------------ */

void ck_debug_show(ck_doc *doc)
{
    ck_app *app = doc->app;

    if (!ck_debug_active(doc))
        return;
    set(app->debugwin, MUIA_Window_Open, TRUE);
    set(app->debugwin, MUIA_Window_Activate, TRUE);
}

void ck_debug_abort(ck_doc *doc)
{
    if (!ck_debug_active(doc))
        return;
    if (ck_rexx_send(doc->app, doc, CK_REQ_DBG_RESTART, "ABORT") >= 0)
        ck_message(doc, "Aborting ...");
}

void ck_debug_continue(ck_doc *doc)
{
    if (!ck_debug_active(doc))
        return;
    if (ck_rexx_send(doc->app, doc, CK_REQ_DBG_RESTART, "CONTINUE") >= 0)
        ck_message(doc, "Continuing ...");
}

void ck_debug_restart(ck_doc *doc, int32_t n)
{
    if (!ck_debug_active(doc))
        return;
    if (n < 0) {
        ck_doc_prompt(doc, "Restart: ", "", CK_CMD_DEBUGGER_RESTART,
                      CK_COMPLETE_NONE, 0);
        return;
    }
    if (ck_rexx_send(doc->app, doc, CK_REQ_DBG_RESTART, "RESTART %ld", (long)n) >= 0)
        ck_message(doc, "Invoking restart %ld ...", (long)n);
}

void ck_debug_frame(ck_doc *doc, int32_t n)
{
    ck_app *app = doc->app;

    if (!ck_debug_active(doc))
        return;
    if (n < 0) {
        ck_doc_prompt(doc, "Frame: ", "", CK_CMD_DEBUGGER_FRAME,
                      CK_COMPLETE_NONE, 0);
        return;
    }
    /* Select the row without the notification: this IS the request the
     * notification would make. */
    SetAttrs(app->dbg_frames, MUIA_NoNotify, TRUE, MUIA_List_Active, (IPTR)n, TAG_DONE);
    app->dbg_frame = n;
    DoMethod(app->dbg_locals, MUIM_List_Clear);
    ck_rexx_send(app, doc, CK_REQ_DBG_FRAME, "FRAME %ld", (long)n);
}

void ck_debug_eval(ck_doc *doc, const char *form)
{
    ck_app *app   = doc->app;
    int32_t frame = (app->dbg_frame >= 0) ? app->dbg_frame : 0;
    char    prefix[48];

    if (!ck_debug_active(doc))
        return;
    if (form == NULL) {
        snprintf(prefix, sizeof prefix, "Eval in frame %ld: ", (long)frame);
        ck_doc_prompt(doc, prefix, "", CK_CMD_DEBUGGER_EVAL, CK_COMPLETE_NONE, 0);
        return;
    }
    if (form[0] == '\0') {
        ck_beep(doc);
        return;
    }
    snprintf(prefix, sizeof prefix, "FRAME-EVAL %ld ", (long)frame);
    if (ck_rexx_send_text(app, doc, CK_REQ_DBG_FRAME_EVAL, prefix, form) >= 0)
        ck_message(doc, "Evaluating in frame %ld ...", (long)frame);
}

/* ------------------------------------------------------------------ *
 * The replies
 * ------------------------------------------------------------------ */

void ck_debug_reply(ck_app *app, ck_doc *doc, uint16_t kind, int32_t rc,
                    const char *text)
{
    char line[CK_MSG_MAX];

    if (text == NULL)
        text = "";
    ck_debug_first_line(text, line, (int32_t)sizeof line);

    if (rc != CK_RC_OK) {
        if (doc != NULL) {
            ck_message(doc, "%s", line[0] != '\0' ? line : "clamiga refused the debugger command");
            ck_beep(doc);
        }
        return;
    }

    /* A reply to a level that is already gone is stale. */
    if (app->dbg_level == 0 || app->debugwin == NULL)
        return;

    switch (kind) {
    case CK_REQ_DBG_BACKTRACE:
        ck_debug_list_fill(app->dbg_frames, text);
        /* Frame 0 is where the error is: select it, and the notification
         * asks for its locals. */
        set(app->dbg_frames, MUIA_List_Active, (IPTR)0);
        break;

    case CK_REQ_DBG_FRAME:
        ck_debug_list_fill(app->dbg_locals, text);
        /* The level is named too: this is the last echo after a DEBUGGER
         * message (entry asks BACKTRACE, which selects frame 0, which
         * asks this), so it is the state a macro polling STATUS can rely
         * on. */
        if (doc != NULL)
            ck_message(doc, "Debugger level %ld, frame %ld: %s", (long)app->dbg_level,
                       (long)app->dbg_frame, line[0] != '\0' ? line : "no locals");
        break;

    case CK_REQ_DBG_FRAME_EVAL:
    case CK_REQ_DBG_RESTART:
    default:
        /* Taken; what follows comes as OUTPUT, a DEBUGGER message or
         * RESULT. */
        break;
    }
}

/* ------------------------------------------------------------------ *
 * The window
 * ------------------------------------------------------------------ */

HOOKPROTONHNO(ck_debug_frame_active_func, void, ULONG *params)
{
    ck_app *app    = (ck_app *)params[0];
    LONG    active = ck_dbg_get(app->dbg_frames, MUIA_List_Active);

    if (active < 0 || app->dbg_level == 0 || active == app->dbg_frame)
        return;
    app->dbg_frame = (int32_t)active;
    DoMethod(app->dbg_locals, MUIM_List_Clear);
    ck_rexx_send(app, ck_debug_doc(app), CK_REQ_DBG_FRAME, "FRAME %ld", (long)active);
}
MakeStaticHook(ck_debug_frame_active_hook, ck_debug_frame_active_func);

/* Double-click on a frame: its source, when the backtrace names one. */
HOOKPROTONHNO(ck_debug_frame_click_func, void, ULONG *params)
{
    ck_app *app    = (ck_app *)params[0];
    LONG    active = ck_dbg_get(app->dbg_frames, MUIA_List_Active);
    STRPTR  entry  = NULL;
    char    file[CK_PATH_MAX];
    int32_t line   = 0;
    ck_doc *doc;

    if (active < 0)
        return;
    DoMethod(app->dbg_frames, MUIM_List_GetEntry, (IPTR)active, (IPTR)&entry);
    if (entry == NULL)
        return;
    if (!ck_dbg_frame_location((const char *)entry, file, (int32_t)sizeof file, &line)) {
        doc = ck_debug_doc(app);
        if (doc != NULL)
            ck_message(doc, "No source location for this frame");
        return;
    }

    doc = ck_doc_find_by_path(app, file);
    if (doc == NULL)
        doc = ck_doc_new(app, file);
    if (doc == NULL)
        return;
    if (line > 0)
        ck_doc_goto_line(doc, line);
    else
        set(doc->win, MUIA_Window_Activate, TRUE);
}
MakeStaticHook(ck_debug_frame_click_hook, ck_debug_frame_click_func);

/* Double-click on a restart, or the Invoke button. */
HOOKPROTONHNO(ck_debug_restart_click_func, void, ULONG *params)
{
    ck_app *app    = (ck_app *)params[0];
    LONG    active = ck_dbg_get(app->dbg_restarts, MUIA_List_Active);
    ck_doc *doc    = ck_debug_doc(app);

    if (doc == NULL)
        return;
    if (active < 0) {
        ck_message(doc, "Select a restart first");
        ck_beep(doc);
        return;
    }
    ck_debug_restart(doc, (int32_t)active);
}
MakeStaticHook(ck_debug_restart_click_hook, ck_debug_restart_click_func);

HOOKPROTONHNO(ck_debug_abort_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    ck_doc *doc = ck_debug_doc(app);
    if (doc != NULL)
        ck_debug_abort(doc);
}
MakeStaticHook(ck_debug_abort_hook, ck_debug_abort_func);

HOOKPROTONHNO(ck_debug_continue_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    ck_doc *doc = ck_debug_doc(app);
    if (doc != NULL)
        ck_debug_continue(doc);
}
MakeStaticHook(ck_debug_continue_hook, ck_debug_continue_func);

/* RET in the eval line. */
HOOKPROTONHNO(ck_debug_eval_func, void, ULONG *params)
{
    ck_app     *app  = (ck_app *)params[0];
    ck_doc     *doc  = ck_debug_doc(app);
    const char *text = (const char *)ck_dbg_get(app->dbg_evalstr, MUIA_String_Contents);
    char        form[CK_MINI_MAX];

    if (doc == NULL || text == NULL || text[0] == '\0')
        return;
    /* The string's buffer is cleared below, so the form is copied first. */
    strncpy(form, text, sizeof form - 1);
    form[sizeof form - 1] = '\0';
    ck_debug_eval(doc, form);
    set(app->dbg_evalstr, MUIA_String_Contents, (IPTR)"");
}
MakeStaticHook(ck_debug_eval_hook, ck_debug_eval_func);

/* Closing the window hides it; the REPL thread stays parked until a
 * restart is chosen, and `M-x clamacs-debugger' brings the window back. */
HOOKPROTONHNO(ck_debug_close_func, void, ULONG *params)
{
    ck_app *app = (ck_app *)params[0];
    ck_doc *doc = ck_debug_doc(app);

    set(app->debugwin, MUIA_Window_Open, FALSE);
    if (doc != NULL && app->dbg_level > 0)
        ck_message(doc, "The REPL is still in the debugger (M-x clamacs-debugger shows it, "
                        "M-x clamacs-debugger-abort leaves it)");
}
MakeStaticHook(ck_debug_close_hook, ck_debug_close_func);

Object *ck_debugwin_create(ck_app *app)
{
    Object *abort_btn, *invoke_btn;

    app->dbg_level = 0;
    app->dbg_frame = -1;
    app->dbg_condition[0] = '\0';
    strcpy(app->dbg_title, "clamacs debugger");

    app->debugwin = WindowObject,
        MUIA_Window_Title,  (IPTR)app->dbg_title,
        MUIA_Window_ID,     MAKE_ID('C','L','D','B'),
        MUIA_Window_Width,  MUIV_Window_Width_Visible(60),
        MUIA_Window_Height, MUIV_Window_Height_Visible(60),
        WindowContents, VGroup,
            Child, app->dbg_condition_obj = TextObject,
                MUIA_Text_Contents, (IPTR)app->dbg_condition,
                MUIA_Text_SetMin,   FALSE,
                MUIA_Frame,         MUIV_Frame_Text,
                MUIA_Background,    MUII_TextBack,
            End,
            Child, VGroup,
                MUIA_Frame,      MUIV_Frame_Group,
                MUIA_FrameTitle, (IPTR)"Restarts",
                MUIA_Weight,     40,
                Child, ListviewObject,
                    MUIA_Listview_DoubleClick, TRUE,
                    MUIA_Listview_List, app->dbg_restarts = ListObject,
                        InputListFrame,
                        MUIA_List_ConstructHook, (IPTR)MUIV_List_ConstructHook_String,
                        MUIA_List_DestructHook,  (IPTR)MUIV_List_DestructHook_String,
                    End,
                End,
            End,
            Child, VGroup,
                MUIA_Frame,      MUIV_Frame_Group,
                MUIA_FrameTitle, (IPTR)"Backtrace",
                MUIA_Weight,     100,
                Child, ListviewObject,
                    MUIA_Listview_DoubleClick, TRUE,
                    MUIA_Listview_List, app->dbg_frames = ListObject,
                        InputListFrame,
                        MUIA_List_ConstructHook, (IPTR)MUIV_List_ConstructHook_String,
                        MUIA_List_DestructHook,  (IPTR)MUIV_List_DestructHook_String,
                    End,
                End,
            End,
            Child, VGroup,
                MUIA_Frame,      MUIV_Frame_Group,
                MUIA_FrameTitle, (IPTR)"Locals",
                MUIA_Weight,     60,
                Child, ListviewObject,
                    MUIA_Listview_List, app->dbg_locals = ListObject,
                        ReadListFrame,
                        MUIA_List_ConstructHook, (IPTR)MUIV_List_ConstructHook_String,
                        MUIA_List_DestructHook,  (IPTR)MUIV_List_DestructHook_String,
                    End,
                End,
            End,
            Child, HGroup,
                Child, TextObject,
                    MUIA_Text_Contents, (IPTR)"Eval in frame:",
                    MUIA_Text_SetMin,   TRUE,
                    MUIA_Weight,        0,
                End,
                Child, app->dbg_evalstr = StringObject,
                    MUIA_Frame,         MUIV_Frame_String,
                    MUIA_String_MaxLen, CK_MINI_MAX,
                    MUIA_CycleChain,    TRUE,
                End,
            End,
            Child, HGroup,
                Child, invoke_btn = KeyButton("_Invoke restart", 'i'),
                Child, app->dbg_continue_btn = KeyButton("_Continue", 'c'),
                Child, abort_btn = KeyButton("_Abort", 'a'),
            End,
        End,
    End;

    if (app->debugwin == NULL)
        return NULL;

    DoMethod(app->app, OM_ADDMEMBER, (IPTR)app->debugwin);

    DoMethod(app->debugwin, MUIM_Notify, MUIA_Window_CloseRequest, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_close_hook, (IPTR)app);
    DoMethod(app->dbg_frames, MUIM_Notify, MUIA_List_Active, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_frame_active_hook, (IPTR)app);
    DoMethod(app->dbg_frames, MUIM_Notify, MUIA_Listview_DoubleClick, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_frame_click_hook, (IPTR)app);
    DoMethod(app->dbg_restarts, MUIM_Notify, MUIA_Listview_DoubleClick, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_restart_click_hook, (IPTR)app);
    DoMethod(invoke_btn, MUIM_Notify, MUIA_Pressed, FALSE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_restart_click_hook, (IPTR)app);
    DoMethod(app->dbg_continue_btn, MUIM_Notify, MUIA_Pressed, FALSE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_continue_hook, (IPTR)app);
    DoMethod(abort_btn, MUIM_Notify, MUIA_Pressed, FALSE,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_abort_hook, (IPTR)app);
    DoMethod(app->dbg_evalstr, MUIM_Notify, MUIA_String_Acknowledge, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_debug_eval_hook, (IPTR)app);

    return app->debugwin;
}
