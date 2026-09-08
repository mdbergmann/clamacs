/*
 * rexxport.c -- the editor's own ARexx port.
 *
 * MUI opens and serves the port for us (MUIA_Application_UseRexx plus a
 * MUIA_Application_Commands table), which is one of the reasons the design
 * chose MUI: an application-owned ARexx port for free, with ReadArgs
 * templates and result strings already handled.
 *
 * The command set is the phase-1 table from specs/clamacs-ide.md.  `EVAL'
 * runs an EDITOR command by name -- the same namespace `M-x' uses, which is
 * the point of having a command table at all -- and `TE' passes straight
 * through to MUIM_TextEditor_ARexxCmd, so the macros people already have for
 * CygnusEd-style editors keep working.
 *
 * Phase 3 extends this table with OUTPUT and READLINE, which is how clamiga
 * pushes REPL output back at us.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

/* MUI hands each command hook the parsed ReadArgs results as an array of
 * IPTRs, one per template item. */

static ck_doc *ck_rx_doc(void)
{
    ck_app *app = ck_app_current();
    return (app != NULL) ? ck_doc_active(app) : NULL;
}

static void ck_rx_result(const char *text)
{
    ck_app *app = ck_app_current();
    if (app != NULL && app->app != NULL)
        set(app->app, MUIA_Application_RexxString, (IPTR)(text != NULL ? text : ""));
}

HOOKPROTONHNO(ck_rx_open_func, void, IPTR *args)
{
    ck_app     *app  = ck_app_current();
    const char *file = (const char *)args[0];
    const LONG *line = (const LONG *)args[1];
    ck_doc     *doc;

    if (app == NULL || file == NULL)
        return;

    doc = ck_doc_find_by_path(app, file);
    if (doc == NULL)
        doc = ck_doc_new(app, file);
    if (doc == NULL)
        return;

    set(doc->win, MUIA_Window_Activate, TRUE);
    if (line != NULL && *line > 0) {
        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(*line - 1));
    }
}
MakeStaticHook(ck_rx_open_hook, ck_rx_open_func);

HOOKPROTONHNO(ck_rx_save_func, void, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;

    if (doc == NULL || doc->path[0] == '\0')
        return;
    ck_doc_save_file(doc, doc->path);
}
MakeStaticHook(ck_rx_save_hook, ck_rx_save_func);

HOOKPROTONHNO(ck_rx_getfile_func, void, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;
    ck_rx_result((doc != NULL) ? doc->path : "");
}
MakeStaticHook(ck_rx_getfile_hook, ck_rx_getfile_func);

HOOKPROTONHNO(ck_rx_gotoline_func, void, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const LONG *line = (const LONG *)args[0];

    if (doc == NULL || line == NULL || *line <= 0)
        return;
    set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
    set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(*line - 1));
}
MakeStaticHook(ck_rx_gotoline_hook, ck_rx_gotoline_func);

HOOKPROTONHNO(ck_rx_eval_func, void, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const char *name = (const char *)args[0];
    int16_t     cmd;
    char        trimmed[64];
    int32_t     n = 0;

    if (doc == NULL || name == NULL)
        return;

    /* A /F argument keeps trailing spaces; the command table does not. */
    while (name[n] != '\0' && n < (int32_t)sizeof trimmed - 1)
        trimmed[n] = name[n], n++;
    while (n > 0 && (trimmed[n - 1] == ' ' || trimmed[n - 1] == '\n'))
        n--;
    trimmed[n] = '\0';

    cmd = ck_command_lookup(trimmed);
    if (cmd == CK_CMD_NONE) {
        ck_rx_result("unknown command");
        return;
    }
    ck_doc_run_command(doc, cmd, 1);
    ck_rx_result("");
}
MakeStaticHook(ck_rx_eval_hook, ck_rx_eval_func);

HOOKPROTONHNO(ck_rx_insert_func, void, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const char *text = (const char *)args[0];

    if (doc == NULL || text == NULL)
        return;
    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)text,
             (IPTR)MUIV_TextEditor_InsertText_Cursor);
}
MakeStaticHook(ck_rx_insert_hook, ck_rx_insert_func);

HOOKPROTONHNO(ck_rx_te_func, void, IPTR *args)
{
    ck_doc     *doc = ck_rx_doc();
    const char *cmd = (const char *)args[0];
    IPTR        r;

    if (doc == NULL || cmd == NULL)
        return;

    r = DoMethod(doc->text, MUIM_TextEditor_ARexxCmd, (IPTR)cmd);
    if (r != 0 && r != (IPTR)TRUE) {
        ck_rx_result((const char *)r);
        FreeVec((APTR)r);
    }
}
MakeStaticHook(ck_rx_te_hook, ck_rx_te_func);

const struct MUI_Command ck_rexx_commands[] = {
    { (char *)"OPEN",     (char *)"FILE/A,LINE/N", 2, (struct Hook *)&ck_rx_open_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"SAVE",     (char *)"",              0, (struct Hook *)&ck_rx_save_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"GETFILE",  (char *)"",              0, (struct Hook *)&ck_rx_getfile_hook,  { 0, 0, 0, 0, 0 } },
    { (char *)"GOTOLINE", (char *)"LINE/N/A",      1, (struct Hook *)&ck_rx_gotoline_hook, { 0, 0, 0, 0, 0 } },
    { (char *)"EVAL",     (char *)"FORM/F",        1, (struct Hook *)&ck_rx_eval_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"INSERT",   (char *)"TEXT/F",        1, (struct Hook *)&ck_rx_insert_hook,   { 0, 0, 0, 0, 0 } },
    { (char *)"TE",       (char *)"CMD/F",         1, (struct Hook *)&ck_rx_te_hook,       { 0, 0, 0, 0, 0 } },
    { NULL, NULL, 0, NULL, { 0, 0, 0, 0, 0 } }
};
