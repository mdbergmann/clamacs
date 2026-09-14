/*
 * repl.c -- phase 3: the REPL window.
 *
 * A listener in a ClamacsText: the transcript above the prompt is history,
 * the text after the prompt is the input, RET sends it when the parens
 * balance, and what comes back arrives as commands at the editor's OWN
 * ARexx port -- OUTPUT as it is printed, READLINE when the form reads from
 * standard input, RESULT with the values and the package for the next
 * prompt (rexxport.c hands them over).  The other end is clamiga's REPL
 * thread, lib/dev-repl.lisp in cl-amiga; specs/clamacs-ide.md, phase 3,
 * has the protocol and the reason it is two-way: MUI answers an ARexx
 * command the moment the hook returns, so the editor can hold no reply
 * until the user has typed.
 *
 * Bookkeeping is two document indices.  input_start is where the input
 * begins -- after the prompt while idle, right after the last output while
 * a READLINE is outstanding -- and -1 while a form runs, when there is no
 * input at all and output is appended.  prompt_start is where the prompt
 * begins, so output that arrives while the prompt is showing goes above it
 * (a thread other than the REPL's printing later) and both indices move
 * along.  Everything the editor inserts itself leaves HasChanged clear:
 * the window never asks to save a transcript.
 */

#include "clamacs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static void ck_repl_busy_message(ck_doc *doc);
static void ck_repl_attach(ck_doc *doc);

static void ck_first_line(const char *text, char *out, int32_t size)
{
    int32_t n = 0;

    if (text == NULL) {
        out[0] = '\0';
        return;
    }
    while (text[n] != '\0' && text[n] != '\n' && text[n] != '\r' && n < size - 1) {
        out[n] = text[n];
        n++;
    }
    out[n] = '\0';
}

static ck_doc *ck_repl_doc(ck_app *app)
{
    ck_doc *doc = app->repl;
    return (doc != NULL && !doc->closing) ? doc : NULL;
}

/* ------------------------------------------------------------------ *
 * Inserting into the transcript
 * ------------------------------------------------------------------ */

/* Insert TEXT at INDEX, moving the cursor and the two bookkeeping indices
 * along with the text when they sit at or after it. */
static void ck_repl_insert(ck_doc *doc, int32_t index, const char *text)
{
    int32_t cursor = ck_doc_cursor_index(doc);
    int32_t len    = (int32_t)strlen(text);

    if (len == 0)
        return;

    ck_doc_insert_at(doc, index, text);

    if (cursor >= index)
        cursor += len;
    if (doc->prompt_start >= index)
        doc->prompt_start += len;
    if (doc->input_start >= index)
        doc->input_start += len;
    ck_doc_set_cursor_index(doc, cursor);

    doc->repl_bol = (text[len - 1] == '\n');
    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
}

static void ck_repl_append(ck_doc *doc, const char *text)
{
    ck_repl_insert(doc, ck_doc_end_index(doc), text);
}

/* A prompt starts a line of its own. */
static void ck_repl_ensure_bol(ck_doc *doc)
{
    if (!doc->repl_bol && ck_doc_end_index(doc) > 0)
        ck_repl_append(doc, "\n");
}

static void ck_repl_prompt(ck_doc *doc)
{
    char    prompt[CK_PKG_MAX + 4];
    int32_t end;

    ck_repl_ensure_bol(doc);
    end = ck_doc_end_index(doc);

    snprintf(prompt, sizeof prompt, "%s> ",
             doc->package[0] != '\0' ? doc->package : "CL-USER");

    /* Not through ck_repl_insert: the indices are being set, not moved. */
    doc->prompt_start = -1;
    doc->input_start  = -1;
    ck_doc_insert_at(doc, end, prompt);
    doc->prompt_start = end;
    doc->input_start  = end + (int32_t)strlen(prompt);
    doc->repl_bol     = 0;
    ck_doc_set_cursor_index(doc, doc->input_start);
    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
    ck_doc_update_status(doc);
}

/* A line of the editor's own: `; ...' in the transcript, as a listener
 * would print it. */
static void ck_repl_note(ck_doc *doc, const char *fmt, ...)
{
    char    line[CK_MSG_MAX];
    va_list args;
    int32_t n;

    line[0] = ';';
    line[1] = ' ';
    va_start(args, fmt);
    n = vsnprintf(line + 2, sizeof line - 4, fmt, args);
    va_end(args);
    if (n < 0)
        n = 0;
    if (n > (int32_t)sizeof line - 4)
        n = (int32_t)sizeof line - 4;
    line[2 + n]     = '\n';
    line[2 + n + 1] = '\0';

    ck_repl_ensure_bol(doc);
    ck_repl_append(doc, line);
}

/* clamiga's *command-package* moved: a buffer eval that follows must not
 * assume the port is still where it last put it. */
static void ck_repl_wire_package(ck_app *app, const char *package)
{
    if (package == NULL || package[0] == '\0')
        return;
    strncpy(app->wire_package, package, sizeof app->wire_package - 1);
    app->wire_package[sizeof app->wire_package - 1] = '\0';
}

/* The prompt's package.  Only a form typed at the prompt moves it: a
 * buffer eval runs in its buffer's package and leaves the prompt alone,
 * as in SLIME (ck_repl_return re-asserts the prompt's package before each
 * form anyway). */
static void ck_repl_set_package(ck_doc *doc, const char *package)
{
    if (package == NULL || package[0] == '\0')
        return;
    strncpy(doc->package, package, sizeof doc->package - 1);
    doc->package[sizeof doc->package - 1] = '\0';
    ck_repl_wire_package(doc->app, package);
}

/* ------------------------------------------------------------------ *
 * Buffer evals waiting for the attach
 * ------------------------------------------------------------------ */

static void ck_repl_clear_pending(ck_app *app)
{
    if (app->repl_pending != NULL)
        free(app->repl_pending);
    app->repl_pending        = NULL;
    app->repl_pending_origin = 0;
}

static int32_t ck_repl_set_pending(ck_app *app, ck_doc *from, const char *text)
{
    size_t n = strlen(text);
    char  *copy;

    ck_repl_clear_pending(app);
    copy = (char *)malloc(n + 1);
    if (copy == NULL)
        return 0;
    memcpy(copy, text, n + 1);
    app->repl_pending        = copy;
    app->repl_pending_origin = from->id;
    return 1;
}

/* ------------------------------------------------------------------ *
 * Attaching
 * ------------------------------------------------------------------ */

static void ck_repl_attach(ck_doc *doc)
{
    ck_app     *app = doc->app;
    const char *own;

    if (app->repl_attaching)
        return;

    own = ck_rexx_own_port(app);
    if (own == NULL) {
        ck_message(doc, "Cannot find the editor's own ARexx port");
        ck_beep(doc);
        return;
    }

    /* DEBUG: an unhandled error parks the REPL thread and opens the
     * debugger window (phase 4) instead of ending the form. */
    if (ck_rexx_send(app, doc, CK_REQ_REPL_ATTACH, "REPL-ATTACH %s DEBUG", own) >= 0) {
        app->repl_attaching = 1;
        ck_message(doc, "Attaching the REPL to %s ...", app->clamiga_port);
    }
}

/* The REPL window, opened if there is none yet.  Opening puts it in front;
 * the caller decides whether that is where the user goes. */
static ck_doc *ck_repl_open(ck_app *app, ck_doc *from)
{
    ck_doc *doc = ck_repl_doc(app);

    if (doc != NULL)
        return doc;

    doc = ck_doc_scratch(app, CK_REPL_NAME, 1);
    if (doc == NULL) {
        ck_message(from, "Cannot open the REPL window");
        ck_beep(from);
        return NULL;
    }
    doc->repl_mode    = 1;
    doc->prompt_start = -1;
    doc->input_start  = -1;
    doc->repl_busy    = 0;
    doc->repl_reading = 0;
    doc->repl_bol     = 1;
    ck_keystate_init(&doc->keys, app->global, app->repl_map);
    app->repl          = doc;
    app->repl_attached = 0;
    app->repl_origin   = 0;
    return doc;
}

void ck_repl_switch(ck_doc *from)
{
    ck_app *app = from->app;
    ck_doc *doc = ck_repl_open(app, from);

    if (doc == NULL)
        return;

    ck_doc_activate(doc);
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);

    if (!app->repl_attached)
        ck_repl_attach(doc);
}

/*
 * A buffer eval on the REPL thread.  SLIME's model: C-c C-c in a source
 * buffer is the same evaluation a form typed at the prompt gets -- output
 * streams into the transcript, an error parks the thread and opens the
 * debugger window -- only the values go to the buffer's echo area instead
 * of the transcript, and the prompt's package is left alone.  Before the
 * REPL is attached the form waits for the REPL-ATTACH reply; the REPL
 * window opens for that, but the user stays in the buffer.
 */
void ck_repl_eval_from(ck_doc *from, const char *text)
{
    ck_app *app  = from->app;
    ck_doc *repl = ck_repl_doc(app);

    if (!app->repl_attached) {
        if (repl == NULL) {
            repl = ck_repl_open(app, from);
            if (repl == NULL)
                return;
            /* The new window came up in front: the eval came from FROM. */
            ck_doc_activate(from);
            set(from->win, MUIA_Window_ActiveObject, (IPTR)from->text);
        }
        if (!ck_repl_set_pending(app, from, text)) {
            ck_message(from, "Out of memory");
            ck_beep(from);
            return;
        }
        ck_repl_attach(repl);
        if (!app->repl_attaching)
            ck_repl_clear_pending(app);   /* the attach never left */
        return;
    }

    if (app->repl_origin != 0 || (repl != NULL && repl->input_start < 0)) {
        ck_repl_busy_message(from);
        return;
    }

    /* The buffer's package, not the prompt's: IN-PACKAGE first when they
     * differ from what the port was last told. */
    ck_doc_send_package(from, 1);
    if (ck_rexx_send_text(app, from, CK_REQ_REPL_EVAL, "REPL-EVAL ", text) >= 0)
        app->repl_origin = from->id;
}

/* ------------------------------------------------------------------ *
 * The commands
 * ------------------------------------------------------------------ */

static int32_t ck_repl_blank(const char *text)
{
    while (*text != '\0') {
        if (*text != ' ' && *text != '\t' && *text != '\n' && *text != '\r')
            return 0;
        text++;
    }
    return 1;
}

void ck_repl_return(ck_doc *doc)
{
    ck_app *app = doc->app;
    STRPTR  owned;
    const char *text;
    int32_t end;

    if (doc->input_start < 0) {
        ck_repl_busy_message(doc);
        return;
    }

    end   = ck_doc_end_index(doc);
    owned = ck_doc_text_range(doc, doc->input_start, end);
    text  = (owned != NULL) ? (const char *)owned : "";

    if (doc->repl_reading) {
        /* The answer to a READLINE: one line, sent as typed. */
        doc->repl_reading = 0;
        doc->input_start  = -1;
        doc->prompt_start = -1;
        ck_repl_append(doc, "\n");
        if (ck_rexx_send_text(app, doc, CK_REQ_REPL_INPUT, "REPL-INPUT ", text) < 0)
            ck_repl_prompt(doc);
        else
            ck_message(doc, "");
    } else if (ck_repl_blank(text)) {
        /* Nothing to send: a fresh prompt, as a listener gives. */
        ck_repl_append(doc, "\n");
        ck_repl_prompt(doc);
    } else if (!ck_sexp_input_complete(text, (int32_t)strlen(text))) {
        /* Still typing the form: RET does what it does in a source buffer. */
        ck_doc_set_cursor_index(doc, end);
        ck_doc_run_command(doc, CK_CMD_NEWLINE_AND_INDENT, 1);
    } else if (app->repl_origin != 0) {
        /* The thread is running a buffer eval; the prompt stayed up. */
        ck_repl_busy_message(doc);
    } else if (!app->repl_attached) {
        ck_message(doc, "No REPL attached -- C-c C-z attaches one");
        ck_beep(doc);
    } else {
        ck_hist_add(&app->hist_repl, text);
        doc->input_start  = -1;
        doc->prompt_start = -1;
        doc->repl_busy    = 1;
        ck_doc_set_cursor_index(doc, end);
        ck_repl_append(doc, "\n");
        /* The prompt's package is the form's package, whatever a buffer
         * eval told the port in between. */
        ck_doc_send_package(doc, 0);
        if (ck_rexx_send_text(app, doc, CK_REQ_REPL_EVAL, "REPL-EVAL ", text) < 0) {
            doc->repl_busy = 0;
            ck_repl_prompt(doc);
        }
    }

    if (owned != NULL)
        FreeVec(owned);
}

void ck_repl_history(ck_doc *doc, int32_t back)
{
    ck_app     *app  = doc->app;
    ck_history *hist = &app->hist_repl;
    const char *item;
    int32_t     end;

    if (doc->input_start < 0) {
        ck_beep(doc);
        return;
    }
    end = ck_doc_end_index(doc);

    /* Leaving the input for the history: keep it, so M-n past the newest
     * entry brings it back. */
    if (hist->cursor == 0) {
        STRPTR now = ck_doc_text_range(doc, doc->input_start, end);
        strncpy(doc->repl_saved, now != NULL ? (const char *)now : "",
                sizeof doc->repl_saved - 1);
        doc->repl_saved[sizeof doc->repl_saved - 1] = '\0';
        if (now != NULL)
            FreeVec(now);
    }

    item = back ? ck_hist_prev(hist) : ck_hist_next(hist);
    if (item == NULL) {
        if (back) {
            ck_message(doc, "Beginning of history");
            ck_beep(doc);
            return;
        }
        item = doc->repl_saved;
    }

    ck_doc_replace(doc, doc->input_start, end, item);
    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
}

void ck_repl_clear(ck_doc *doc)
{
    if (doc->input_start < 0) {
        ck_repl_busy_message(doc);
        return;
    }
    doc->prompt_start = -1;
    doc->input_start  = -1;
    ck_doc_set_text(doc, "");
    doc->repl_bol = 1;
    ck_repl_prompt(doc);
}

void ck_repl_interrupt(ck_doc *doc)
{
    ck_app *app = doc->app;

    if (!app->repl_attached) {
        ck_message(doc, "No REPL attached");
        ck_beep(doc);
        return;
    }
    if (ck_rexx_send(app, doc, CK_REQ_REPL_INTERRUPT, "REPL-INTERRUPT") >= 0)
        ck_message(doc, "Interrupting ...");
}

/* ------------------------------------------------------------------ *
 * Keeping edits inside the input
 * ------------------------------------------------------------------ */

static void ck_repl_busy_message(ck_doc *doc)
{
    if (doc->app->dbg_level > 0)
        ck_message(doc, "The REPL is in the debugger (M-x clamacs-debugger shows it, "
                        "M-x clamacs-debugger-abort returns to the prompt)");
    else if (doc->repl_mode)
        ck_message(doc, "The REPL is busy (C-c C-c interrupts)");
    else
        ck_message(doc, "The REPL is busy (C-c C-b interrupts)");
    ck_beep(doc);
}

int32_t ck_repl_unbound_key(ck_doc *doc, ck_key key)
{
    uint16_t code = CK_KEY_CODE(key);
    int32_t  cursor;

    /* Only what would edit: a character, Backspace, Delete.  Motion and the
     * class's other keys pass. */
    if (CK_KEY_MODS(key) != 0)
        return 0;
    if (code != CK_KEY_BACKSPACE && code != CK_KEY_DELETE &&
        (code < CK_KEY_SPACE || code > 0xFF))
        return 0;

    if (doc->input_start < 0) {
        ck_repl_busy_message(doc);
        return 1;
    }

    cursor = ck_doc_cursor_index(doc);
    if (code == CK_KEY_BACKSPACE)
        return cursor <= doc->input_start;   /* the prompt stays */
    if (code == CK_KEY_DELETE)
        return cursor < doc->input_start;

    /* Typing into the transcript lands in the input instead. */
    if (cursor < doc->input_start)
        ck_doc_set_cursor_index(doc, ck_doc_end_index(doc));
    return 0;
}

static int32_t ck_repl_command_edits(int16_t command)
{
    switch (command) {
    case CK_CMD_DELETE_CHAR:
    case CK_CMD_BACKWARD_DELETE_CHAR:
    case CK_CMD_KILL_WORD:
    case CK_CMD_BACKWARD_KILL_WORD:
    case CK_CMD_KILL_LINE:
    case CK_CMD_KILL_REGION:
    case CK_CMD_YANK:
    case CK_CMD_YANK_POP:
    case CK_CMD_KILL_SEXP:
    case CK_CMD_INSERT_PARENTHESES:
    case CK_CMD_INDENT_FOR_TAB_COMMAND:
    case CK_CMD_NEWLINE_AND_INDENT:
    case CK_CMD_INDENT_REGION:
    case CK_CMD_COMPLETE_SYMBOL:
        return 1;
    default:
        return 0;
    }
}

int32_t ck_repl_allow_command(ck_doc *doc, int16_t command)
{
    int32_t cursor;

    if (command == CK_CMD_UNDO || command == CK_CMD_REDO) {
        /* An undo step could take back an OUTPUT insert and leave the
         * bookkeeping pointing into text that is gone. */
        ck_message(doc, "Undo is not available in the REPL");
        ck_beep(doc);
        return 0;
    }

    if (command == CK_CMD_BEGINNING_OF_LINE && doc->input_start >= 0) {
        /* C-a on the prompt line stops after the prompt, as in comint. */
        LONG cx = 0, cy = 0, ix = 0, iy = 0;
        cursor = ck_doc_cursor_index(doc);
        DoMethod(doc->text, MUIM_TextEditor_IndexToCursorXY, (IPTR)cursor,
                 (IPTR)&cx, (IPTR)&cy);
        DoMethod(doc->text, MUIM_TextEditor_IndexToCursorXY, (IPTR)doc->input_start,
                 (IPTR)&ix, (IPTR)&iy);
        if (cy == iy && cursor > doc->input_start) {
            ck_doc_set_cursor_index(doc, doc->input_start);
            return 0;
        }
        return 1;
    }

    if (!ck_repl_command_edits(command))
        return 1;

    if (doc->input_start < 0) {
        ck_repl_busy_message(doc);
        return 0;
    }
    cursor = ck_doc_cursor_index(doc);
    if (cursor < doc->input_start)
        ck_doc_set_cursor_index(doc, ck_doc_end_index(doc));
    if (doc->mark >= 0 && doc->mark < doc->input_start)
        doc->mark = doc->input_start;
    return 1;
}

/* ------------------------------------------------------------------ *
 * What clamiga sends
 * ------------------------------------------------------------------ */

void ck_repl_output(ck_app *app, const char *text)
{
    ck_doc *doc = ck_repl_doc(app);

    if (doc == NULL || text == NULL || text[0] == '\0')
        return;

    if (doc->input_start >= 0) {
        /* A prompt (or a READLINE's input) is showing: the output goes
         * above it, and the indices follow. */
        int32_t at = (doc->prompt_start >= 0) ? doc->prompt_start : doc->input_start;
        int32_t bol = doc->repl_bol;
        ck_repl_insert(doc, at, text);
        doc->repl_bol = bol;   /* the end of the transcript did not change */
    } else {
        ck_repl_append(doc, text);
    }
}

void ck_repl_readline(ck_app *app)
{
    ck_doc *doc = ck_repl_doc(app);
    int32_t end;

    if (doc == NULL)
        return;

    end = ck_doc_end_index(doc);
    doc->repl_reading = 1;
    doc->prompt_start = end;
    doc->input_start  = end;
    ck_doc_set_cursor_index(doc, end);
    ck_message(doc, "clamiga is reading a line: type it and press RET");
}

void ck_repl_result(ck_app *app, int32_t rc, const char *package,
                    const char *values)
{
    ck_doc *doc = ck_repl_doc(app);

    if (app->repl_origin != 0) {
        /* A buffer eval: the values are that buffer's news, the transcript
         * keeps its prompt (any output already went above it), and the
         * prompt's package is not touched. */
        ck_doc *from = ck_doc_by_id(app, app->repl_origin);
        char    line[CK_MSG_MAX];

        app->repl_origin = 0;
        ck_repl_wire_package(app, package);
        if (app->dbg_level > 0)
            ck_debug_left(app);
        if (from == NULL || from->closing)
            return;
        ck_first_line(values, line, (int32_t)sizeof line);
        if (rc != CK_RC_OK) {
            ck_message(from, "%s", line[0] != '\0' ? line : "Evaluation failed");
            ck_beep(from);
        } else {
            ck_message(from, "%s", line[0] != '\0' ? line : "; No values");
        }
        return;
    }

    if (doc == NULL)
        return;

    doc->repl_busy    = 0;
    doc->repl_reading = 0;
    doc->prompt_start = -1;
    doc->input_start  = -1;
    ck_repl_set_package(doc, package);

    /* The form is done, so the debugger is too, whatever was announced. */
    if (app->dbg_level > 0)
        ck_debug_left(app);

    ck_repl_ensure_bol(doc);
    if (values != NULL && values[0] != '\0') {
        ck_repl_append(doc, values);
        if (!doc->repl_bol)
            ck_repl_append(doc, "\n");
    }

    if (rc != CK_RC_OK) {
        char line[CK_MSG_MAX];
        ck_first_line(values, line, (int32_t)sizeof line);
        ck_message(doc, "%s", line[0] != '\0' ? line : "Evaluation failed");
        ck_beep(doc);
    } else {
        ck_message(doc, "");
    }

    ck_repl_prompt(doc);
}

/* DEBUGGER <level> <pkg> (phase 4).  The form is still running -- parked
 * in the debugger -- so the transcript stays as it is; the window is the
 * debugger's face (debugwin.c).  The package is the REPL thread's, moved
 * by a FRAME-EVAL's IN-PACKAGE as a form's would be. */
void ck_repl_debugger(ck_app *app, int32_t level, const char *package,
                      const char *text)
{
    ck_doc *doc = ck_repl_doc(app);

    if (app->repl_origin != 0)
        ck_repl_wire_package(app, package);   /* a buffer eval's package */
    else if (doc != NULL)
        ck_repl_set_package(doc, package);

    if (level > 0)
        ck_debug_entered(app, level, text);
    else
        ck_debug_left(app);
}

/* ------------------------------------------------------------------ *
 * The replies to the editor's own REPL commands
 * ------------------------------------------------------------------ */

void ck_repl_reply(ck_app *app, ck_doc *doc, uint16_t kind, int32_t rc,
                   const char *text)
{
    char line[CK_MSG_MAX];

    if (text == NULL)
        text = "";
    ck_first_line(text, line, (int32_t)sizeof line);

    switch (kind) {
    case CK_REQ_REPL_ATTACH:
        app->repl_attaching = 0;
        if (rc != CK_RC_OK) {
            ck_doc *from = ck_doc_by_id(app, app->repl_pending_origin);
            if (doc != NULL) {
                ck_repl_note(doc, "%s", line[0] != '\0' ? line : "REPL-ATTACH failed");
                ck_message(doc, "%s", line[0] != '\0' ? line : "REPL-ATTACH failed");
                ck_beep(doc);
            }
            /* The buffer eval that waited for this is off. */
            if (from != NULL && from != doc && !from->closing) {
                ck_message(from, "%s", line[0] != '\0' ? line : "REPL-ATTACH failed");
                ck_beep(from);
            }
            ck_repl_clear_pending(app);
            break;
        }
        if (doc == NULL || doc != ck_repl_doc(app)) {
            /* The window went away while the request was out: do not leave
             * a REPL thread sending to nobody. */
            ck_rexx_send(app, NULL, CK_REQ_REPL_DETACH, "REPL-DETACH");
            ck_repl_clear_pending(app);
            break;
        }
        app->repl_attached = 1;
        app->repl_origin   = 0;
        doc->repl_busy     = 0;
        doc->repl_reading  = 0;
        ck_repl_set_package(doc, line);
        ck_repl_note(doc, "REPL attached to %s", app->clamiga_port);
        ck_message(doc, "REPL attached to %s", app->clamiga_port);
        ck_repl_prompt(doc);
        /* Now the buffer eval that asked for the attach. */
        if (app->repl_pending != NULL) {
            ck_doc *from = ck_doc_by_id(app, app->repl_pending_origin);
            char   *form = app->repl_pending;
            app->repl_pending        = NULL;
            app->repl_pending_origin = 0;
            if (from != NULL && !from->closing)
                ck_repl_eval_from(from, form);
            free(form);
        }
        break;

    case CK_REQ_REPL_EVAL:
        if (rc != CK_RC_OK && doc != NULL) {
            /* Refused: the REPL thread is gone (clamiga restarted) or
             * still busy. */
            if (strstr(text, "no REPL attached") != NULL)
                app->repl_attached = 0;
            ck_message(doc, "%s", line[0] != '\0' ? line : "REPL-EVAL failed");
            ck_beep(doc);
            if (doc == ck_repl_doc(app)) {
                /* Typed at the prompt: the prompt comes back. */
                doc->repl_busy = 0;
                ck_repl_prompt(doc);
            } else if (app->repl_origin == doc->id) {
                /* A buffer eval that never started. */
                app->repl_origin = 0;
            }
        }
        break;

    case CK_REQ_REPL_INPUT:
        if (rc != CK_RC_OK && doc != NULL) {
            ck_message(doc, "%s", line[0] != '\0' ? line : "REPL-INPUT failed");
            ck_beep(doc);
        }
        break;

    case CK_REQ_REPL_INTERRUPT:
        if (doc != NULL && line[0] != '\0')
            ck_message(doc, "%s", line);
        break;

    case CK_REQ_REPL_DETACH:
    default:
        break;
    }
}

/* ------------------------------------------------------------------ *
 * Housekeeping
 * ------------------------------------------------------------------ */

void ck_repl_closed(ck_doc *doc)
{
    ck_app *app = doc->app;

    if (app->repl != doc)
        return;
    if (app->repl_attached)
        ck_rexx_send(app, NULL, CK_REQ_REPL_DETACH, "REPL-DETACH");
    app->repl_attached  = 0;
    app->repl_attaching = 0;
    app->repl_origin    = 0;
    app->repl           = NULL;
    ck_repl_clear_pending(app);
    /* The detach lets a parked REPL thread go; the window goes with it. */
    ck_debug_left(app);
}

void ck_repl_disconnected(ck_app *app)
{
    ck_doc *doc = ck_repl_doc(app);

    if (!app->repl_attached && !app->repl_attaching)
        return;
    app->repl_attached  = 0;
    app->repl_attaching = 0;
    app->repl_origin    = 0;
    ck_repl_clear_pending(app);
    ck_debug_left(app);
    if (doc == NULL)
        return;
    doc->repl_busy    = 0;
    doc->repl_reading = 0;
    doc->prompt_start = -1;
    doc->input_start  = -1;
    ck_repl_note(doc, "clamiga is gone (it is attached again when it comes back)");
    ck_repl_prompt(doc);
}

/* The port is back (ck_rexx_find_port saw it appear).  A REPL window that
 * lost its thread gets a new one without being asked: the transcript
 * says so, and the next RET at the prompt or C-c C-c in a buffer just
 * works.  A fresh clamiga has no REPL thread, so this is an attach, not a
 * resume -- the old session's history is gone with the old process. */
void ck_repl_reconnected(ck_app *app)
{
    ck_doc *doc = ck_repl_doc(app);

    if (doc == NULL || app->repl_attached || app->repl_attaching)
        return;
    ck_repl_note(doc, "clamiga is back on %s", app->clamiga_port);
    ck_repl_attach(doc);
}

void ck_repl_quit(ck_app *app)
{
    if (app->repl_attached)
        ck_rexx_send(app, NULL, CK_REQ_REPL_DETACH, "REPL-DETACH");
    app->repl_attached  = 0;
    app->repl_attaching = 0;
    app->repl_origin    = 0;
    ck_repl_clear_pending(app);
}
