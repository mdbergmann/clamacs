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
#include "emacs/command.h"
#include "emacs/bindings.h"
#include "emacs/killring.h"
#include "emacs/minihist.h"
#include "lisp/token.h"
#include "lisp/sexp.h"
#include "lisp/indent.h"
#include "rexx/diag.h"
#include "rexx/queue.h"

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

#include "SDI_compiler.h"
#include "SDI_hook.h"

/* Private attribute: which document an object belongs to.  In the user tag
 * space, so it cannot collide with MUI's own. */
#define CKA_Doc (TAG_USER | 0x0C1A0001)

#define CK_PATH_MAX 256
#define CK_PKG_MAX   64
#define CK_MSG_MAX  512
#define CK_MINI_MAX 512

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
    CK_COMPLETE_BUFFER
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
} ck_doc;

typedef struct ck_app {
    Object *app;
    struct MUI_CustomClass *textclass;
    struct MUI_CustomClass *miniclass;

    ck_keymap  *global;
    ck_keymap  *lisp;
    ck_killring kill;

    ck_history hist_file;
    ck_history hist_command;
    ck_history hist_search;
    ck_history hist_eval;

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

int32_t ck_classes_create(ck_app *app);
void    ck_classes_free(ck_app *app);

/* Decode an IDCMP_RAWKEY into a ck_key.  Exposed so both custom classes use
 * one decoder. */
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
void    ck_context_free(ck_context *ctx);

int32_t ck_doc_cursor_index(ck_doc *doc);
void    ck_doc_set_cursor_index(ck_doc *doc, int32_t index);
STRPTR  ck_doc_export_all(ck_doc *doc);

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

/* Queue a command.  KIND says what the reply is for; DOC may be NULL. */
int32_t ck_rexx_send(ck_app *app, ck_doc *doc, uint16_t kind, const char *fmt, ...);

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
