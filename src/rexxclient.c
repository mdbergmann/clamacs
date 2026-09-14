/*
 * rexxclient.c -- the asynchronous ARexx client.
 *
 * The rule this file exists to enforce: the editor NEVER waits for a reply.
 * Every request is a RexxMsg sent with PutMsg; the reply port's signal is
 * folded into the MUI input loop's Wait() mask and the reply is handled like
 * any other event.  A long COMPILE-FILE therefore does not freeze redisplay,
 * and -- the reason it matters beyond comfort -- phase 3's REPL has clamiga
 * calling back into the editor's own port while the editor's REPL-EVAL is
 * still outstanding.  A blocking client would deadlock there.
 *
 * The ordering discipline lives in rexx/queue.c, which is host-tested; what
 * is here is the transport and the continuations.
 */

#include "clamacs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static void ck_rexx_pump(ck_app *app);

int32_t ck_rexx_open(ck_app *app)
{
    app->reply = CreateMsgPort();
    if (app->reply == NULL)
        return 0;
    ck_queue_init(&app->queue);
    ck_diag_init(&app->diags);
    return 1;
}

void ck_rexx_close(ck_app *app)
{
    /* A message still on the wire will be replied to whatever we do, so wait
     * for it rather than leaving clamiga's handler thread writing into a
     * port that no longer exists.  A REPL-DETACH queued behind it (the
     * editor is quitting with a REPL attached) goes out too, so clamiga's
     * REPL thread is stopped rather than left sending to a port that is
     * about to vanish; everything else queued is dropped. */
    for (;;) {
        while (app->inflight_msg != NULL) {
            struct RexxMsg *rm;
            WaitPort(app->reply);
            while ((rm = (struct RexxMsg *)GetMsg(app->reply)) != NULL) {
                ck_queue_release(ck_queue_complete(&app->queue, (int32_t)rm->rm_Result1));
                if (rm->rm_Result2 != 0)
                    DeleteArgstring((STRPTR)rm->rm_Result2);
                if (rm->rm_Args[0] != 0)
                    DeleteArgstring((STRPTR)rm->rm_Args[0]);
                DeleteRexxMsg(rm);
                app->inflight_msg = NULL;
            }
        }
        if (app->queue.head == NULL || app->queue.head->kind != CK_REQ_REPL_DETACH)
            break;
        ck_rexx_pump(app);
        if (app->inflight_msg == NULL)
            break;
    }

    ck_queue_clear(&app->queue);
    ck_diag_clear(&app->diags);

    if (app->reply != NULL) {
        DeleteMsgPort(app->reply);
        app->reply = NULL;
    }
}

uint32_t ck_rexx_signal(ck_app *app)
{
    if (app->reply == NULL)
        return 0;
    return 1UL << app->reply->mp_SigBit;
}

int32_t ck_rexx_find_port(ck_app *app)
{
    char    name[32];
    int32_t i;
    int32_t was = app->connected;

    /* CLAMIGA, then CLAMIGA.1 .. CLAMIGA.9 -- the same scan the shipped
     * clamiga.rexx macro does, so a second clamiga instance is reachable. */
    for (i = 0; i <= 9; i++) {
        if (i == 0)
            strcpy(name, "CLAMIGA");
        else
            snprintf(name, sizeof name, "CLAMIGA.%ld", (long)i);

        Forbid();
        if (FindPort((STRPTR)name) != NULL) {
            Permit();
            strncpy(app->clamiga_port, name, sizeof app->clamiga_port - 1);
            app->clamiga_port[sizeof app->clamiga_port - 1] = '\0';
            app->connected = 1;
            if (!was) {
                /* Newly found -- at startup, or back after it was gone.
                 * Say so where the user is looking, since the command
                 * that provoked the scan would otherwise just work as if
                 * nothing had happened; and a fresh clamiga starts in
                 * CL-USER, whatever the old one was last told. */
                ck_doc *doc = ck_doc_active(app);
                app->wire_package[0] = '\0';
                if (doc != NULL)
                    ck_message(doc, "clamiga found on %s", name);
                ck_repl_reconnected(app);
            }
            ck_menu_update(app);
            return 1;
        }
        Permit();
    }

    app->connected = 0;
    ck_menu_update(app);
    return 0;
}

/*
 * Where the clamiga to start is.  The binary release puts clamiga beside
 * the editor (bin/aos3/), so PROGDIR:clamiga is tried first -- resolved to
 * an absolute path here, because the shell System() starts has a PROGDIR:
 * of its own.  A bare "clamiga" is the fallback, for a clamiga on the
 * shell path.  Returns the command to run in BUF.
 */
static void ck_rexx_clamiga_command(char *buf, int32_t size)
{
    BPTR dir = GetProgramDir();

    if (dir != (BPTR)0 && NameFromLock(dir, (STRPTR)buf, (LONG)size)
        && AddPart((STRPTR)buf, (STRPTR)"clamiga", (ULONG)size)) {
        BPTR lock = Lock((STRPTR)buf, ACCESS_READ);
        if (lock != (BPTR)0) {
            UnLock(lock);
            return;
        }
    }
    strncpy(buf, "clamiga", (size_t)size - 1);
    buf[size - 1] = '\0';
}

/*
 * clamiga needs a 128K stack (the AmigaOS default of 64K is enough for the
 * core, not for the GUI libraries or Quicklisp), and the stack a shell runs
 * a command on is its cli_DefaultStack -- inherited from whatever started
 * the editor, so from Workbench it is the 16K system default.  The one
 * way to set it for a command started through System() is a script that
 * says `Stack' first, so the launch is written to T: and Executed.
 * CK_LAUNCH_STACK_SIZE is shared with the NP_StackSize fallback tag below,
 * so a command run directly (script unwritable/T: full) still gets the
 * same 128K instead of silently falling back to the 64K OS default.
 */
#define CK_LAUNCH_STACK_SIZE 131072
#define CK_STR2(x) #x
#define CK_STR(x) CK_STR2(x)

/*
 * The script name carries this task's address so two editor instances (or
 * two rapid launch attempts) never share a file: MODE_NEWFILE truncates,
 * so a shared name would let a second writer corrupt the first launch's
 * script out from under its still-reading Execute.
 */
static void ck_rexx_launch_script_path(char *path, int32_t size)
{
    snprintf(path, (size_t)size, "T:clamacs-start-clamiga-%08lx",
             (unsigned long)FindTask(NULL));
}

/* Returns 0 when the script cannot be written; the caller then runs the
 * command directly on whatever stack the shell has. */
static int32_t ck_rexx_write_launch_script(const char *command,
                                            const char *path)
{
    BPTR fh = Open((STRPTR)path, MODE_NEWFILE);
    LONG ok;

    if (fh == (BPTR)0)
        return 0;
    ok = FPuts(fh, (STRPTR)"Stack " CK_STR(CK_LAUNCH_STACK_SIZE) "\n\"") == 0
      && FPuts(fh, (STRPTR)command) == 0
      && FPuts(fh, (STRPTR)"\"\n") == 0;
    Close(fh);
    if (!ok)
        DeleteFile((STRPTR)path);
    return ok;
}

int32_t ck_rexx_launch(ck_app *app)
{
    BPTR        console;
    LONG        rc;
    int32_t     tries;
    int32_t     found = 0;
    char        command[512];
    char        script_path[64];
    const char *cmdline;
    int32_t     script_written;

    if (ck_rexx_find_port(app))
        return 1;

    ck_rexx_clamiga_command(command, sizeof command);
    ck_rexx_launch_script_path(script_path, sizeof script_path);
    script_written = ck_rexx_write_launch_script(command, script_path);
    if (script_written)
        snprintf(command, sizeof command, "Execute %s", script_path);
    cmdline = command;

    /* clamiga gets its own console window: it is a REPL in its own right,
     * and until phase 3 lands that window IS the REPL. */
    console = Open((STRPTR)"CON:0/40/640/220/clamiga/CLOSE/WAIT",
                   MODE_OLDFILE);
    if (console == (BPTR)0) {
        if (script_written)
            DeleteFile((STRPTR)script_path);
        return 0;
    }

    rc = SystemTags((STRPTR)cmdline,
                    SYS_Input,   (IPTR)console,
                    SYS_Output,  (IPTR)NULL,
                    SYS_Asynch,  TRUE,
                    NP_Name,     (IPTR)"clamiga",
                    NP_StackSize, CK_LAUNCH_STACK_SIZE,
                    TAG_DONE);
    if (rc != 0) {
        /* System() only takes ownership of the handles once it succeeds. */
        Close(console);
        if (script_written)
            DeleteFile((STRPTR)script_path);
        return 0;
    }

    /* The port appears once the user's S:.clamigarc has run
     * (require "amiga/arexx") (amiga.arexx:start).  Give it a few seconds;
     * this is the one place the editor waits, and it waits before there is
     * anything to be responsive about.  By the first time this loop checks,
     * Execute has long since read the (now unique) script into its own
     * buffer, so it is safe to remove once the wait is over either way. */
    for (tries = 0; tries < 100; tries++) {
        Delay(10);   /* 10 ticks = 1/5 s */
        if (ck_rexx_find_port(app)) {
            found = 1;
            break;
        }
    }
    if (script_written)
        DeleteFile((STRPTR)script_path);
    return found;
}

/* Put the head of the queue on the wire, if nothing is in flight. */
static void ck_rexx_pump(ck_app *app)
{
    ck_request     *req;
    struct RexxMsg *rm;
    struct MsgPort *port;
    STRPTR          arg;

    if (app->reply == NULL)
        return;
    if (ck_queue_inflight(&app->queue) != NULL)
        return;
    if (ck_queue_depth(&app->queue) == 0)
        return;

    rm = CreateRexxMsg(app->reply, NULL, NULL);
    if (rm == NULL)
        return;

    req = ck_queue_begin(&app->queue);
    if (req == NULL) {
        DeleteRexxMsg(rm);
        return;
    }

    arg = CreateArgstring((STRPTR)req->command, (ULONG)strlen(req->command));
    if (arg == NULL) {
        DeleteRexxMsg(rm);
        ck_queue_release(ck_queue_complete(&app->queue, CK_RC_FATAL));
        return;
    }

    rm->rm_Args[0] = arg;
    rm->rm_Action  = RXCOMM | RXFF_RESULT;

    /* FindPort and PutMsg must be one atomic step: the port can vanish
     * between them if clamiga exits. */
    Forbid();
    port = FindPort((STRPTR)app->clamiga_port);
    if (port != NULL)
        PutMsg(port, (struct Message *)rm);
    Permit();

    if (port == NULL) {
        ck_doc *doc;
        DeleteArgstring(arg);
        DeleteRexxMsg(rm);
        app->connected = 0;
        ck_queue_release(ck_queue_complete(&app->queue, CK_RC_FATAL));
        ck_repl_disconnected(app);
        ck_menu_update(app);
        doc = ck_doc_active(app);
        if (doc != NULL)
            ck_message(doc, "clamiga is not running (port %s is gone)",
                       app->clamiga_port);
        return;
    }

    app->inflight_msg = rm;
}

/*
 * Make sure a port is known before queuing a command.  When DOC is given and
 * none is, the spec's launch-if-missing offers to start clamiga; a quiet
 * caller (DOC NULL) just fails.  Returns 1 when a command may be queued.
 */
static int32_t ck_rexx_connect(ck_app *app, ck_doc *doc)
{
    if (app->connected || ck_rexx_find_port(app))
        return 1;

    if (doc != NULL) {
        if (MUI_Request(app->app, doc->win, 0, "clamacs", "_Start|_Cancel",
                        "No clamiga ARexx port was found.\n"
                        "Start clamiga in its own console window?") != 1)
            return 0;
    }
    if (!ck_rexx_launch(app)) {
        if (doc != NULL)
            ck_message(doc, "Cannot start clamiga");
        return 0;
    }
    return 1;
}

/* Whether a request can go out without asking the user anything: a port is
 * known, or one turns up on a scan.  The idle arglist lookup checks this so
 * a resting cursor never pops the launch requester. */
int32_t ck_rexx_ready(ck_app *app)
{
    return app->connected || ck_rexx_find_port(app);
}

/*
 * The editor's own port.  MUI builds it from MUIA_Application_Base and
 * numbers it -- the first instance is CLAMACS.1 on MUI 3.8 -- and offers no
 * attribute with the result, so the candidates are scanned for the one this
 * task owns: MUI created the port in the application's context, so its
 * mp_SigTask is us and not a second clamacs.
 */
const char *ck_rexx_own_port(ck_app *app)
{
    struct Task *me = FindTask(NULL);
    char         name[32];
    int32_t      i, found = 0;

    if (app->own_port[0] != '\0')
        return app->own_port;

    for (i = 0; i <= 9 && !found; i++) {
        struct MsgPort *port;

        if (i == 0)
            strcpy(name, "CLAMACS");
        else
            snprintf(name, sizeof name, "CLAMACS.%ld", (long)i);

        Forbid();
        port = FindPort((STRPTR)name);
        if (port != NULL && port->mp_SigTask == me)
            found = 1;
        Permit();
    }

    if (!found)
        return NULL;
    strncpy(app->own_port, name, sizeof app->own_port - 1);
    app->own_port[sizeof app->own_port - 1] = '\0';
    return app->own_port;
}

static int32_t ck_rexx_queue(ck_app *app, ck_doc *doc, uint16_t kind,
                             const char *command)
{
    int32_t serial = ck_queue_push(&app->queue, command, kind,
                                   (doc != NULL) ? doc->id : 0);
    if (serial < 0)
        return -1;
    ck_rexx_pump(app);
    return serial;
}

int32_t ck_rexx_send(ck_app *app, ck_doc *doc, uint16_t kind,
                     const char *fmt, ...)
{
    char    command[CK_MSG_MAX];
    va_list args;

    if (!ck_rexx_connect(app, doc))
        return -1;

    va_start(args, fmt);
    vsnprintf(command, sizeof command, fmt, args);
    va_end(args);

    return ck_rexx_queue(app, doc, kind, command);
}

/*
 * PREFIX followed by TEXT of any length -- a whole defun for EVAL, a form for
 * MACROEXPAND -- with no fixed-size format buffer and no vsnprintf, so the
 * text is passed through verbatim (a `%' in the form is not a directive).
 */
int32_t ck_rexx_send_text(ck_app *app, ck_doc *doc, uint16_t kind,
                          const char *prefix, const char *text)
{
    char   *command;
    size_t  plen, tlen;
    int32_t serial;

    if (!ck_rexx_connect(app, doc))
        return -1;

    if (prefix == NULL) prefix = "";
    if (text == NULL)   text   = "";
    plen = strlen(prefix);
    tlen = strlen(text);

    command = (char *)malloc(plen + tlen + 1);
    if (command == NULL)
        return -1;
    memcpy(command, prefix, plen);
    memcpy(command + plen, text, tlen + 1);

    serial = ck_rexx_queue(app, doc, kind, command);
    free(command);
    return serial;
}

/* ------------------------------------------------------------------ *
 * Continuations
 * ------------------------------------------------------------------ */

ck_doc *ck_doc_by_id(ck_app *app, uint32_t id)
{
    ck_doc *doc;

    if (id == 0)
        return NULL;
    for (doc = app->docs; doc != NULL; doc = doc->next) {
        if (doc->id == id)
            return doc;
    }
    return NULL;
}

/* The first line of a reply, which for EVAL is the printed values. */
static void ck_first_line(const char *text, char *out, int32_t size)
{
    int32_t n = 0;

    if (text == NULL) {
        out[0] = '\0';
        return;
    }
    while (text[n] != '\0' && text[n] != '\n' && n < size - 1) {
        out[n] = text[n];
        n++;
    }
    out[n] = '\0';
}

static void ck_rexx_diagnostics(ck_app *app, ck_doc *doc, const char *text)
{
    char summary[CK_MSG_MAX];

    ck_diag_parse(&app->diags, text != NULL ? text : "");
    ck_errorwin_fill(app);

    if (app->diags.summary_seen) {
        snprintf(summary, sizeof summary, "%s%s%s", app->diags.summary,
                 app->diags.aborted ? " (aborted)" : "",
                 app->diags.truncated ? " (reply truncated)" : "");
    } else {
        ck_first_line(text, summary, (int32_t)sizeof summary);
    }

    if (doc != NULL)
        ck_message(doc, "%s", summary);
    if (app->diags.count > 0 && app->errorwin != NULL)
        set(app->errorwin, MUIA_Window_Open, TRUE);
}

static void ck_rexx_dispatch(ck_app *app, ck_request *req, int32_t rc,
                             const char *text)
{
    ck_doc  *doc     = ck_doc_by_id(app, req->cookie);
    uint16_t kind    = req->kind;
    int32_t  orig_rc = rc;

    /* An automatic LASTRESULT carries the text of the command that failed,
     * so it is handled as if it were that command's own reply.  For the
     * phase-2 kinds the ORIGINAL return code matters -- an unknown symbol is
     * a miss, not an arglist -- and the LASTRESULT itself always comes back
     * 0, so the real rc is carried alongside the origin. */
    if (kind == CK_REQ_LASTRESULT && (req->flags & CK_REQF_AUTO_LASTRESULT)) {
        kind    = req->origin;
        orig_rc = req->origin_rc;
    }

    switch (kind) {
    case CK_REQ_PING:
        if (doc != NULL)
            ck_message(doc, "clamiga answers on %s", app->clamiga_port);
        break;

    case CK_REQ_VERSION:
        if (text != NULL) {
            strncpy(app->version, text, sizeof app->version - 1);
            app->version[sizeof app->version - 1] = '\0';
        }
        if (doc != NULL)
            ck_message(doc, "%s", app->version);
        break;

    case CK_REQ_IN_PACKAGE:
        if (rc != CK_RC_OK && doc != NULL)
            ck_message(doc, "%s", text != NULL ? text : "IN-PACKAGE failed");
        break;

    case CK_REQ_LOAD:
    case CK_REQ_COMPILE_FILE:
        ck_rexx_diagnostics(app, doc, text);
        break;

    case CK_REQ_EVAL: {
        char line[CK_MSG_MAX];
        if (rc == CK_RC_OK) {
            ck_first_line(text, line, (int32_t)sizeof line);
            if (doc != NULL)
                ck_message(doc, "%s", line[0] != '\0' ? line : "; no values");
        } else {
            ck_rexx_diagnostics(app, doc, text);
        }
        break;
    }

    /* --- phase 2: introspection.  Each reply has its continuation in
     * introspect.c; SUBJECT is the command it answers (the failing command
     * for a LASTRESULT), from which the handler recovers the symbol. */
    case CK_REQ_ARGLIST:
    case CK_REQ_ARGLIST_ECHO:
    case CK_REQ_COMPLETE_BUFFER:
    case CK_REQ_COMPLETE_MINI:
    case CK_REQ_DESCRIBE:
    case CK_REQ_APROPOS:
    case CK_REQ_SOURCE_LOCATION:
    case CK_REQ_MACROEXPAND:
        ck_intro_reply(app, doc, kind, ck_request_subject(req), orig_rc, text);
        break;

    /* --- phase 3: the REPL.  These replies only say whether clamiga took
     * the command; the output, the read requests and the values come in
     * through the editor's own port (rexxport.c -> repl.c). */
    case CK_REQ_REPL_ATTACH:
    case CK_REQ_REPL_EVAL:
    case CK_REQ_REPL_INPUT:
    case CK_REQ_REPL_INTERRUPT:
    case CK_REQ_REPL_DETACH:
        ck_repl_reply(app, doc, kind, orig_rc, text);
        break;

    /* --- phase 4: the debugger and inspector windows. */
    case CK_REQ_DBG_BACKTRACE:
    case CK_REQ_DBG_FRAME:
    case CK_REQ_DBG_FRAME_EVAL:
    case CK_REQ_DBG_RESTART:
        ck_debug_reply(app, doc, kind, orig_rc, text);
        break;

    case CK_REQ_INSPECT:
        ck_inspect_reply(app, doc, orig_rc, text);
        break;

    case CK_REQ_LASTRESULT:
    default:
        if (doc != NULL && text != NULL)
            ck_message(doc, "%s", text);
        break;
    }
}

void ck_rexx_handle_replies(ck_app *app)
{
    struct RexxMsg *rm;

    if (app->reply == NULL)
        return;

    while ((rm = (struct RexxMsg *)GetMsg(app->reply)) != NULL) {
        int32_t     rc   = (int32_t)rm->rm_Result1;
        const char *text = (rm->rm_Result2 != 0) ? (const char *)rm->rm_Result2
                                                 : NULL;
        ck_request *req  = ck_queue_complete(&app->queue, rc);

        app->inflight_msg = NULL;

        if (req != NULL) {
            /* ARexx carries RESULT only with rc 0, so a failing command's
             * text has to be fetched separately -- and that LASTRESULT must
             * be the very next thing on the wire, or a queued command would
             * overwrite *LAST-RESULT* first. */
            if (ck_rc_needs_lastresult(rc) &&
                (req->flags & CK_REQF_AUTO_LASTRESULT) == 0 &&
                req->kind != CK_REQ_LASTRESULT) {
                if (ck_queue_push_front(&app->queue, "LASTRESULT",
                                        CK_REQ_LASTRESULT, req->cookie,
                                        CK_REQF_AUTO_LASTRESULT) >= 0 &&
                    app->queue.head != NULL) {
                    app->queue.head->origin    = req->kind;
                    app->queue.head->origin_rc = rc;
                    /* Carry the failing command forward, so a phase-2 reply
                     * still knows which symbol it was about. */
                    ck_request_set_context(app->queue.head,
                                           ck_request_subject(req));
                }
            } else {
                ck_rexx_dispatch(app, req, rc, text);
            }
            ck_queue_release(req);
        }

        if (rm->rm_Result2 != 0)
            DeleteArgstring((STRPTR)rm->rm_Result2);
        if (rm->rm_Args[0] != 0)
            DeleteArgstring((STRPTR)rm->rm_Args[0]);
        DeleteRexxMsg(rm);
    }

    ck_rexx_pump(app);
    /* A reply may have filled the error list or pushed a location. */
    ck_menu_update(app);
}
