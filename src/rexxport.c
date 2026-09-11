/*
 * rexxport.c -- the editor's own ARexx port.
 *
 * MUI opens and serves the port for us (MUIA_Application_UseRexx plus a
 * MUIA_Application_Commands table), which is one of the reasons the design
 * chose MUI: an application-owned ARexx port for free, with ReadArgs
 * templates and result strings already handled.
 *
 * The command set is the phase-1 table from specs/clamacs-ide.md, plus
 * `GETNAME' from phase 2 (the scratch windows have no file for GETFILE to
 * name).  `EVAL' runs an EDITOR command by name -- the same namespace `M-x'
 * uses, which is the point of having a command table at all -- and `TE'
 * passes straight through to MUIM_TextEditor_ARexxCmd, so the macros people
 * already have for CygnusEd-style editors keep working.
 *
 * Phase 3 adds the three commands clamiga's REPL thread sends the OTHER way
 * -- OUTPUT, READLINE, RESULT -- but not to this table: they come in through
 * MUIA_Application_RexxHook (ck_rexx_repl_hook, at the end), which MUI calls
 * with the raw RexxMsg for any command it cannot map.  That keeps ReadArgs
 * out of the way, so a chunk of output that starts with blanks, holds a lone
 * quote or ends in a newline arrives exactly as printed.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

/*
 * MUI hands each command hook the parsed ReadArgs results as an array of
 * IPTRs, one per template item, and it uses the hook's RETURN VALUE as the
 * command's ARexx return code.  Every hook here therefore returns LONG 0
 * explicitly: declared void, the code a macro sees is whatever happened to
 * be left in d0, which is how `TE GETCURSOR LINE' came back as rc 24 while
 * the commands next to it came back as 0.
 */

static ck_doc *ck_rx_doc(void)
{
    ck_app *app = ck_app_current();
    return (app != NULL) ? ck_doc_active(app) : NULL;
}

static LONG ck_rx_get(Object *obj, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, obj, &value);
    return (LONG)value;
}

static void ck_rx_result(const char *text)
{
    ck_app *app = ck_app_current();
    if (app != NULL && app->app != NULL)
        set(app->app, MUIA_Application_RexxString, (IPTR)(text != NULL ? text : ""));
}

HOOKPROTONHNO(ck_rx_open_func, LONG, IPTR *args)
{
    ck_app     *app  = ck_app_current();
    const char *file = (const char *)args[0];
    const LONG *line = (const LONG *)args[1];
    ck_doc     *doc;

    if (app == NULL || file == NULL)
        return 0;

    doc = ck_doc_find_by_path(app, file);
    if (doc == NULL)
        doc = ck_doc_new(app, file);
    if (doc == NULL)
        return 0;

    ck_doc_activate(doc);
    if (line != NULL && *line > 0) {
        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(*line - 1));
    }

    return 0;
}
MakeStaticHook(ck_rx_open_hook, ck_rx_open_func);

HOOKPROTONHNO(ck_rx_save_func, LONG, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;

    if (doc == NULL || doc->path[0] == '\0')
        return 0;
    ck_doc_save_file(doc, doc->path);

    return 0;
}
MakeStaticHook(ck_rx_save_hook, ck_rx_save_func);

HOOKPROTONHNO(ck_rx_getfile_func, LONG, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;
    ck_rx_result((doc != NULL) ? doc->path : "");

    return 0;
}
MakeStaticHook(ck_rx_getfile_hook, ck_rx_getfile_func);

/*
 * The active document's name: the file part of its path, or the name of a
 * window that has no file -- `*clamacs-description*' and the other scratch
 * windows phase 2 opens.  GETFILE is empty for those (a macro that wants
 * to save must not be told a name it cannot write to), so this is how a
 * macro learns which window it is talking to.
 */
HOOKPROTONHNO(ck_rx_getname_func, LONG, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;
    ck_rx_result((doc != NULL) ? doc->name : "");

    return 0;
}
MakeStaticHook(ck_rx_getname_hook, ck_rx_getname_func);

/*
 * LINE is 1-based here, unlike the class's own GOTOLINE (which sets
 * MUIA_TextEditor_CursorY straight from its argument, and whose GETCURSOR
 * reports that same 0-based number).  1-based is what `file:12:' in a
 * diagnostic means and what the error list clicks through to, so it is the
 * convention every line number crossing THIS port uses.
 */
HOOKPROTONHNO(ck_rx_gotoline_func, LONG, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const LONG *line = (const LONG *)args[0];

    if (doc == NULL || line == NULL || *line <= 0)
        return 0;
    set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
    set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(*line - 1));

    return 0;
}
MakeStaticHook(ck_rx_gotoline_hook, ck_rx_gotoline_func);

HOOKPROTONHNO(ck_rx_eval_func, LONG, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const char *name = (const char *)args[0];
    int16_t     cmd;
    char        trimmed[64];
    int32_t     n = 0;

    if (doc == NULL || name == NULL)
        return 0;

    /* A /F argument keeps trailing spaces; the command table does not. */
    while (name[n] != '\0' && n < (int32_t)sizeof trimmed - 1)
        trimmed[n] = name[n], n++;
    while (n > 0 && (trimmed[n - 1] == ' ' || trimmed[n - 1] == '\n'))
        n--;
    trimmed[n] = '\0';

    cmd = ck_command_lookup(trimmed);
    if (cmd == CK_CMD_NONE) {
        ck_rx_result("unknown command");
        return 0;
    }
    ck_doc_run_command(doc, cmd, 1);
    ck_rx_result("");

    return 0;
}
MakeStaticHook(ck_rx_eval_hook, ck_rx_eval_func);

HOOKPROTONHNO(ck_rx_insert_func, LONG, IPTR *args)
{
    ck_doc     *doc  = ck_rx_doc();
    const char *text = (const char *)args[0];

    if (doc == NULL || text == NULL)
        return 0;
    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)text,
             (IPTR)MUIV_TextEditor_InsertText_Cursor);

    return 0;
}
MakeStaticHook(ck_rx_insert_hook, ck_rx_insert_func);

/*
 * The echo area, as text.  Everything the editor says back -- a diagnostic
 * summary, the value of an evaluated form, an error message -- lands there,
 * and a macro that has just asked for a LOAD needs to read it.  It is also
 * how the unattended test observes an ASYNCHRONOUS result: issue the
 * command, then poll STATUS until the reply has arrived.
 */
HOOKPROTONHNO(ck_rx_status_func, LONG, IPTR *args)
{
    ck_doc *doc = ck_rx_doc();
    (void)args;
    ck_rx_result((doc != NULL) ? doc->message : "");

    return 0;
}
MakeStaticHook(ck_rx_status_hook, ck_rx_status_func);

HOOKPROTONHNO(ck_rx_te_func, LONG, IPTR *args)
{
    ck_doc     *doc = ck_rx_doc();
    const char *cmd = (const char *)args[0];
    IPTR        r;

    if (doc == NULL || cmd == NULL)
        return 0;

    r = DoMethod(doc->text, MUIM_TextEditor_ARexxCmd, (IPTR)cmd);
    if (r != 0 && r != (IPTR)TRUE) {
        ck_rx_result((const char *)r);
        FreeVec((APTR)r);
    }

    return 0;
}
MakeStaticHook(ck_rx_te_hook, ck_rx_te_func);

/*
 * Feed a key sequence to the Emacs layer, spelled the way the editor spells
 * it: `KEY C-x C-s', `KEY C-u 4 C-f', `KEY M-x'.
 *
 * This is the counterpart of EVAL.  EVAL runs a command directly; KEY goes
 * through the keymaps, so prefix keys, the C-u argument reader, C-g and the
 * minibuffer all take part.  A macro can therefore do what a user does, and
 * -- the reason it exists -- the unattended test can exercise the command
 * loop, which the ARexx commands otherwise walk straight past.
 *
 * It stops short of the raw-key decoder and of MUI's event routing in front
 * of it: KEY hands a ck_key to the layer below.  verify/realamiga/sendkey.c
 * covers the rest by writing real key events to input.device -- the same
 * spellings, one level deeper -- and is also how the Alt-as-Meta question is
 * put to real hardware.
 *
 * With the minibuffer open the keys belong to it, and the ones the Emacs
 * layer does not take (C-g, TAB, M-p, M-n) are the String gadget's: from
 * the keyboard it types them itself, but KEY is above the gadget, so
 * ck_rx_mini_edit() does what it would -- a plain character self-inserts,
 * BS deletes, RET acknowledges.  That is what lets a macro do `KEY M-x',
 * type a name, `KEY RET', and what drives the phase-2 prompts in drive.rexx.
 */
static void ck_rx_mini_edit(ck_doc *doc, ck_key key)
{
    uint16_t    code = CK_KEY_CODE(key);
    const char *now;
    char        text[CK_MINI_MAX];
    int32_t     n;

    if (CK_KEY_MODS(key) != 0)
        return;
    if (code == CK_KEY_RETURN) {
        ck_doc_minibuffer_done(doc);
        return;
    }

    now = (const char *)ck_rx_get(doc->mini, MUIA_String_Contents);
    strncpy(text, now != NULL ? now : "", sizeof text - 1);
    text[sizeof text - 1] = '\0';
    n = (int32_t)strlen(text);

    if (code == CK_KEY_BACKSPACE) {
        if (n > 0)
            text[n - 1] = '\0';
    } else if (code >= CK_KEY_SPACE && code <= 0xFF && code != CK_KEY_DELETE) {
        if (n >= (int32_t)sizeof text - 1)
            return;
        text[n]     = (char)code;
        text[n + 1] = '\0';
    } else {
        return;
    }
    /* The contents notification runs, as it does for typing: an isearch
     * prompt searches as the pattern grows. */
    set(doc->mini, MUIA_String_Contents, (IPTR)text);
}

HOOKPROTONHNO(ck_rx_key_func, LONG, IPTR *args)
{
    ck_doc     *doc = ck_rx_doc();
    const char *seq = (const char *)args[0];
    char        spelling[32];

    if (doc == NULL || seq == NULL)
        return 0;

    for (;;) {
        int32_t n = 0;
        ck_key  key;

        while (*seq == ' ' || *seq == '\t')
            seq++;
        if (*seq == '\0' || *seq == '\n')
            break;

        while (*seq != '\0' && *seq != ' ' && *seq != '\t' && *seq != '\n' &&
               n < (int32_t)sizeof spelling - 1)
            spelling[n++] = *seq++;
        spelling[n] = '\0';

        key = ck_key_from_string(spelling);
        if (key == CK_KEY_NONE) {
            ck_rx_result("unknown key");
            return 0;
        }

        /* Whichever object has the focus decides, exactly as a keypress
         * would: with the minibuffer open the keys belong to it. */
        if (doc->mini_state != CK_MINI_IDLE) {
            if (!ck_doc_minibuffer_key(doc, key))
                ck_rx_mini_edit(doc, key);
        } else {
            ck_doc_handle_key(doc, key);
        }
    }

    ck_rx_result("");
    return 0;
}
MakeStaticHook(ck_rx_key_hook, ck_rx_key_func);

/*
 * OUTPUT, READLINE, RESULT and (phase 4) DEBUGGER from clamiga's REPL
 * thread.  The hook gets the
 * RexxMsg itself (a1) and its return value is the message's rc; the text is
 * rm_Args[0], the command as sent.  Each returns at once -- the REPL thread
 * is waiting on this reply, and the editor never holds one -- after handing
 * the parsed message to repl.c.  Anything else is what it always was, an
 * unknown command.
 */
HOOKPROTONH(ck_rx_repl_func, LONG, Object *obj, struct RexxMsg *rm)
{
    ck_app     *app = ck_app_current();
    const char *raw = (rm != NULL && rm->rm_Args[0] != 0) ? (const char *)rm->rm_Args[0] : NULL;
    ck_replmsg  msg;
    (void)obj;

    if (app == NULL || !ck_replmsg_parse(raw, &msg)) {
        ck_rx_result("unknown command");
        return 0;
    }

    switch (msg.kind) {
    case CK_REPLMSG_OUTPUT:   ck_repl_output(app, msg.text); break;
    case CK_REPLMSG_READLINE: ck_repl_readline(app); break;
    case CK_REPLMSG_RESULT:   ck_repl_result(app, msg.rc, msg.package, msg.text); break;
    case CK_REPLMSG_DEBUGGER: ck_repl_debugger(app, msg.rc, msg.package, msg.text); break;
    default: break;
    }
    return 0;
}
MakeHook(ck_rexx_repl_hook, ck_rx_repl_func);

const struct MUI_Command ck_rexx_commands[] = {
    { (char *)"OPEN",     (char *)"FILE/A,LINE/N", 2, (struct Hook *)&ck_rx_open_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"SAVE",     (char *)"",              0, (struct Hook *)&ck_rx_save_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"GETFILE",  (char *)"",              0, (struct Hook *)&ck_rx_getfile_hook,  { 0, 0, 0, 0, 0 } },
    { (char *)"GETNAME",  (char *)"",              0, (struct Hook *)&ck_rx_getname_hook,  { 0, 0, 0, 0, 0 } },
    { (char *)"GOTOLINE", (char *)"LINE/N/A",      1, (struct Hook *)&ck_rx_gotoline_hook, { 0, 0, 0, 0, 0 } },
    { (char *)"EVAL",     (char *)"FORM/F",        1, (struct Hook *)&ck_rx_eval_hook,     { 0, 0, 0, 0, 0 } },
    { (char *)"INSERT",   (char *)"TEXT/F",        1, (struct Hook *)&ck_rx_insert_hook,   { 0, 0, 0, 0, 0 } },
    { (char *)"TE",       (char *)"CMD/F",         1, (struct Hook *)&ck_rx_te_hook,       { 0, 0, 0, 0, 0 } },
    { (char *)"STATUS",   (char *)"",              0, (struct Hook *)&ck_rx_status_hook,   { 0, 0, 0, 0, 0 } },
    { (char *)"KEY",      (char *)"KEYS/F",        1, (struct Hook *)&ck_rx_key_hook,      { 0, 0, 0, 0, 0 } },
    { NULL, NULL, 0, NULL, { 0, 0, 0, 0, 0 } }
};
