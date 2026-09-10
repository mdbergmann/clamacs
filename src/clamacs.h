/*
 * clamacs.h -- the MUI half of the editor.
 *
 * Everything below the line "OS types start here" is the part that CANNOT be
 * host-tested; the modules it pulls in from emacs/, lisp/ and rexx/ are the
 * part that can, and none of them may include this file.  That split is the
 * design rule from specs/clamacs-ide.md, and the host Makefile enforces it.
 */

#ifndef CLAMACS_H
#define CLAMACS_H

#include <stdint.h>

#include "emacs/keymap.h"
#include "emacs/rawkey.h"
#include "emacs/command.h"
#include "emacs/bindings.h"
#include "emacs/killring.h"
#include "emacs/minihist.h"
#include "emacs/locstack.h"
#include "lisp/token.h"
#include "lisp/sexp.h"
#include "lisp/indent.h"
#include "rexx/diag.h"
#include "rexx/queue.h"
#include "rexx/symcache.h"

/* ---- OS types start here ---------------------------------------- */

#include <exec/types.h>
#include <exec/ports.h>
#include <exec/memory.h>
#include <devices/inputevent.h>
#include <dos/dos.h>
#include <dos/dostags.h>
#include <intuition/intuition.h>
#include <libraries/asl.h>
#include <libraries/iffparse.h>   /* MAKE_ID */
#include <libraries/mui.h>
#include <rexx/storage.h>
#include <rexx/rxslib.h>
#include <workbench/startup.h>

#include <clib/alib_protos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/utility.h>
#include <proto/keymap.h>
#include <proto/asl.h>
#include <proto/rexxsyslib.h>
#include <proto/graphics.h>
#include <proto/muimaster.h>

#include <mui/TextEditor_mcc.h>
#include "muiextra.h"   /* MUIM_GoActive/GoInactive, undocumented but stable */

#include "SDI_compiler.h"
#include "SDI_hook.h"

/* Private attribute: which document an object belongs to.  In the user tag
 * space, so it cannot collide with MUI's own. */
#define CKA_Doc (TAG_USER | 0x0C1A0001)

/* Private method: the idle tick, fired by the text object's own MUI timer
 * input handler (MUIIHNF_TIMER).  It carries no parameters -- the handler
 * finds its document from instance data -- so a plain method id is enough.
 * ck_intro_idle() does the work; the guard against a moving cursor and an
 * inactive window is there, so an idle tick on a background document is
 * cheap. */
#define CKM_IdleTick (TAG_USER | 0x0C1A0002)

#define CK_PATH_MAX 256
#define CK_PKG_MAX   64
#define CK_MSG_MAX  512
#define CK_MINI_MAX 512
#define CK_SYM_MAX  128   /* a symbol name as the editor passes it around */
#define CK_ARGLIST_MAX 256

/* Private method: the idle tick that drives the arglist in the status line.
 * textclass.c registers a MUI timer input handler per text object that
 * invokes it; introspect.c answers it. */
#define CKM_Idle (TAG_USER | 0x0C1A0100)
#define CK_IDLE_MILLIS 250

/* How many lines above the cursor get exported when a structural command
 * needs context.  The scanner needs a starting point outside any string or
 * comment; a `(' in column 0 within this window provides one, and failing
 * that we fall back to the whole buffer.  200 lines is a couple of defuns
 * even in generously spaced code, and exporting that costs far less than
 * exporting a 60 KB file on every keystroke. */
#define CK_CONTEXT_LINES 200

struct ck_app;

/* Text exported around the cursor, with a starting point the sexp scanner
 * can trust.  See ck_doc_context(). */
typedef struct {
    STRPTR      raw;   /* what to free; NULL when there is nothing */
    const char *buf;   /* raw + skip: offset 0 is outside any string/comment */
    int32_t     len;
    int32_t     base;  /* document index of buf[0] */
    int32_t     point; /* the cursor, as an offset into buf */
} ck_context;

/* What the minibuffer is currently doing. */
typedef enum {
    CK_MINI_IDLE = 0,   /* showing a message; not accepting input */
    CK_MINI_PROMPT,     /* reading a line for CK_DOC.mini_command */
    CK_MINI_ISEARCH
} ck_mini_state;

/* Where TAB completion in the minibuffer gets its candidates. */
typedef enum {
    CK_COMPLETE_NONE = 0,
    CK_COMPLETE_COMMAND,
    CK_COMPLETE_FILE,
    CK_COMPLETE_BUFFER,
    CK_COMPLETE_SYMBOL   /* symbol names, asked from clamiga (phase 2) */
} ck_complete_source;

typedef struct ck_doc {
    struct ck_doc *next;
    struct ck_app *app;
    uint32_t       id;      /* the ARexx request cookie; never reused */

    Object *win;
    Object *text;
    Object *slider;
    Object *status;   /* file, package, line:column */
    Object *prompt;   /* the echo area: messages and minibuffer prompts */
    Object *mini;     /* the minibuffer input line */

    char path[CK_PATH_MAX];    /* "" for a buffer that has no file yet */
    char name[CK_PATH_MAX];    /* the file part, shown in the title */
    char package[CK_PKG_MAX];

    /* MUI keeps the pointer it is given for MUIA_Text_Contents, so the
     * strings behind the status line and the echo area have to outlive the
     * call that sets them. */
    char statusline[CK_MSG_MAX];
    char message[CK_MSG_MAX];

    ck_keystate keys;

    uint16_t mini_state;
    int16_t  mini_command;
    uint16_t mini_source;
    int32_t  mini_arg;

    int32_t  isearch_anchor;
    int32_t  isearch_back;

    int16_t  last_command;     /* for consecutive C-k and M-y */
    int32_t  mark;             /* document index, or -1 */

    /* The paren highlight currently showing, so it can be taken down again
     * without recolouring the buffer. */
    int32_t  paren_x, paren_y;
    int32_t  lisp_mode;

    /* Set by ck_doc_close(); the window is disposed of by ck_app_reap() once
     * the input loop is back at top level.  Disposing here would mean
     * destroying an object from inside its own notification -- and, for
     * `C-x k', from inside the MUIM_HandleEvent of the very text object
     * being freed. */
    int32_t  closing;

    /* Phase 2: the arglist in the status line (introspect.c).  The idle
     * tick compares the cursor with where it was a tick ago and with where
     * the arglist was last worked out, so a resting cursor costs one export
     * and a moving one costs nothing. */
    char     arglist[CK_ARGLIST_MAX];  /* shown, "" for none */
    char     arglist_op[CK_SYM_MAX];   /* the operator it is for */
    char     arglist_want[CK_SYM_MAX]; /* the operator at point, last looked */
    int32_t  arglist_index;            /* cursor index that arglist_want is for */
    int32_t  arglist_serial;           /* edit serial ditto */
    int32_t  arglist_inflight;         /* quiet ARGLIST requests on the wire */
    int32_t  idle_index;               /* the cursor a tick ago */
    int32_t  idle_ticks;
    int32_t  edit_serial;              /* bumped on every content change */

    /* Phase 2: symbol completion.  The candidates clamiga sent for
     * completions_prefix, and the stretch of buffer `M-TAB' replaces. */
    ck_strlist completions;
    char       completions_prefix[CK_SYM_MAX];
    int32_t    completions_capped;
    int32_t    complete_start;
    int32_t    complete_end;
} ck_doc;

typedef struct ck_app {
    Object *app;
    struct MUI_CustomClass *textclass;
    struct MUI_CustomClass *miniclass;

    /* The installed TextEditor.mcc, as ck_classes_create() found it. */
    LONG te_version;
    LONG te_revision;

    ck_keymap  *global;
    ck_keymap  *lisp;
    ck_killring kill;

    ck_history hist_file;
    ck_history hist_command;
    ck_history hist_search;
    ck_history hist_eval;
    ck_history hist_symbol;

    ck_doc  *docs;
    uint32_t next_id;

    /* ARexx client */
    struct MsgPort *reply;
    struct RexxMsg *inflight_msg;
    char            clamiga_port[32];
    int32_t         connected;
    ck_queue        queue;
    ck_diaglist     diags;
    char            version[128];

    /* The package clamiga's port was last told (IN-PACKAGE), so a request
     * from a buffer in the same package does not repeat it.  Cleared when a
     * port is (re)found, since a fresh clamiga starts in CL-USER. */
    char            wire_package[CK_PKG_MAX];

    /* Phase 2 */
    ck_symcache     arglists;    /* what clamiga said about each operator */
    ck_locstack     locations;   /* where `M-.' came from */

    /* the editor's own port name, as MUI registered it */
    const char *own_port;

    Object *errorwin;
    Object *errorlist;
    int32_t error_row;   /* the diagnostic next-error last visited, or -1 */

    int32_t quitting;
} ck_app;

/* ---- main.c ------------------------------------------------------ */

ck_app *ck_app_current(void);
void    ck_message(ck_doc *doc, const char *fmt, ...);
void    ck_beep(ck_doc *doc);

/* ---- textclass.c ------------------------------------------------- */

/* What ck_classes_create() found.  TOO_OLD leaves te_version/te_revision
 * filled in so the message can say what was found. */
enum {
    CK_CLASSES_MISSING = 0,
    CK_CLASSES_OK      = 1,
    CK_CLASSES_TOO_OLD = -1
};

int32_t ck_classes_create(ck_app *app);
void    ck_classes_free(ck_app *app);

/* Decode an IDCMP_RAWKEY into a ck_key: the rules of emacs/rawkey.c over the
 * real MapRawKey.  Exposed so both custom classes use one decoder. */
ck_key ck_decode_rawkey(const struct IntuiMessage *imsg);

/* ---- document.c -------------------------------------------------- */

ck_doc *ck_doc_new(ck_app *app, const char *path);
void    ck_doc_close(ck_doc *doc, int32_t ask);

/* Dispose of the windows ck_doc_close() retired.  Called from the input loop,
 * never from a hook. */
void    ck_app_reap(ck_app *app);
ck_doc *ck_doc_find_by_path(ck_app *app, const char *path);
ck_doc *ck_doc_active(ck_app *app);

/* Returns non-zero when the key was consumed and must not reach the
 * superclass. */
int32_t ck_doc_handle_key(ck_doc *doc, ck_key key);
void    ck_doc_run_command(ck_doc *doc, int16_t command, int32_t arg);

int32_t ck_doc_context(ck_doc *doc, ck_context *ctx);
int32_t ck_doc_context_full(ck_doc *doc, ck_context *ctx);
void    ck_context_free(ck_context *ctx);

int32_t ck_doc_cursor_index(ck_doc *doc);
void    ck_doc_set_cursor_index(ck_doc *doc, int32_t index);
STRPTR  ck_doc_export_all(ck_doc *doc);

/* Replace [START,STOP) with TEXT and leave the cursor after it. */
void    ck_doc_replace(ck_doc *doc, int32_t start, int32_t stop, const char *text);

/* Activate the window and put the cursor at the start of LINE (1-based). */
void    ck_doc_goto_line(ck_doc *doc, int32_t line);

/* A window with no file behind it -- `*clamacs-description*' and the like.
 * Reused when one of that NAME is open, else created; LISP_MODE says
 * whether it gets the Lisp map and the colouring. */
ck_doc *ck_doc_scratch(ck_app *app, const char *name, int32_t lisp_mode);
void    ck_doc_set_text(ck_doc *doc, const char *text);

/* Tell clamiga the buffer's package if it is not what the port was last
 * told; with TRACK the buffer is re-read for its (in-package ...) first,
 * which costs a full export -- the per-user-action commands do that, the
 * idle timer does not. */
void    ck_doc_send_package(ck_doc *doc, int32_t track);

void    ck_doc_update_status(ck_doc *doc);
void    ck_doc_colour_line(ck_doc *doc, int32_t line);
void    ck_doc_colour_all(ck_doc *doc);
void    ck_doc_show_paren(ck_doc *doc);

/* Minibuffer.  ck_doc_prompt() activates the string object; the answer comes
 * back through ck_doc_minibuffer_done(). */
void    ck_doc_prompt(ck_doc *doc, const char *prompt, const char *initial,
                      int16_t command, uint16_t source, int32_t arg);
void    ck_doc_minibuffer_done(ck_doc *doc);
void    ck_doc_minibuffer_abort(ck_doc *doc);
int32_t ck_doc_minibuffer_key(ck_doc *doc, ck_key key);

int32_t ck_doc_load_file(ck_doc *doc, const char *path);
int32_t ck_doc_save_file(ck_doc *doc, const char *path);

/* ---- rexxclient.c ------------------------------------------------ */

int32_t ck_rexx_open(ck_app *app);
void    ck_rexx_close(ck_app *app);
uint32_t ck_rexx_signal(ck_app *app);
void    ck_rexx_handle_replies(ck_app *app);

/* Find clamiga's port (CLAMIGA, CLAMIGA.1, ...).  Returns 1 when one was
 * found and remembered. */
int32_t ck_rexx_find_port(ck_app *app);
int32_t ck_rexx_launch(ck_app *app);

/* Queue a command.  KIND says what the reply is for; DOC may be NULL.  When
 * no port is known the user is offered to start clamiga first, so this is
 * for things the user asked for. */
int32_t ck_rexx_send(ck_app *app, ck_doc *doc, uint16_t kind, const char *fmt, ...);

/* The same for PREFIX followed by TEXT of any length -- a whole defun for
 * EVAL, a form for MACROEXPAND -- without a fixed-size format buffer in the
 * way. */
int32_t ck_rexx_send_text(ck_app *app, ck_doc *doc, uint16_t kind,
                          const char *prefix, const char *text);

/* Whether a request can go out without asking the user anything: a port is
 * known, or one turns up on a scan.  The idle timer checks this first. */
int32_t ck_rexx_ready(ck_app *app);

/* ---- introspect.c (phase 2) -------------------------------------- */

/* The idle tick, from the text object's timer input handler. */
void    ck_intro_idle(ck_doc *doc);

/* The arglist of the operator at point into the status line.  ECHO also
 * puts it in the echo area (`M-x clamacs-arglist') and may ask the user to
 * start clamiga; quiet calls never prompt.  Returns 1 when handled, 0 when
 * it could not act now (no port, a request already out) and should be
 * tried again. */
int32_t ck_intro_arglist(ck_doc *doc, int32_t echo);

void    ck_intro_complete(ck_doc *doc);                              /* M-TAB */
int32_t ck_intro_mini_complete(ck_doc *doc, const char *text);       /* TAB in a symbol prompt */
void    ck_intro_complete_done(ck_doc *doc, const char *answer);     /* RET in `Complete:' */

void    ck_intro_edit_definition(ck_doc *doc);                       /* M-. */
void    ck_intro_edit_definition_named(ck_doc *doc, const char *name);
void    ck_intro_pop_definition(ck_doc *doc);                        /* M-, */

void    ck_intro_describe(ck_doc *doc);                              /* C-c C-d d */
void    ck_intro_describe_named(ck_doc *doc, const char *name);
void    ck_intro_apropos(ck_doc *doc);                               /* C-c C-d a */
void    ck_intro_apropos_named(ck_doc *doc, const char *text);
void    ck_intro_macroexpand(ck_doc *doc, int32_t full);             /* C-c RET */

/* The continuation for every phase-2 request kind.  SUBJECT is the command
 * string the reply answers (ck_request_subject), DOC may be NULL when the
 * window that asked has closed. */
void    ck_intro_reply(ck_app *app, ck_doc *doc, uint16_t kind,
                       const char *subject, int32_t rc, const char *text);

/* ---- rexxport.c -------------------------------------------------- */

extern const struct MUI_Command ck_rexx_commands[];

/* ---- errorwin.c -------------------------------------------------- */

Object *ck_errorwin_create(ck_app *app);
void    ck_errorwin_show(ck_app *app, const char *text);
void    ck_errorwin_fill(ck_app *app);

/* Jump to diagnostic ROW, opening its file if it is not already open.  One
 * implementation for both ways in: clicking a row in the list, and
 * `C-x `' walking the diagnostics from the keyboard. */
void    ck_errorwin_jump(ck_app *app, int32_t row);

/* Which diagnostic the error list has selected, or -1.  next-error walks
 * from there, so the two stay in step. */
int32_t ck_errorwin_current(ck_app *app);

#endif /* CLAMACS_H */
