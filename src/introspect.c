/*
 * introspect.c -- phase 2: what the editor asks clamiga about a symbol.
 *
 * Everything here is a question put to clamiga's port and a place for the
 * answer to land: the arglist of the operator at point goes to the status
 * line, completions go into the buffer or the minibuffer, a source location
 * moves the cursor, and DESCRIBE, APROPOS and MACROEXPAND open a scratch
 * window.  The questions are the six commands cl-amiga added for this phase
 * (lib/dev-commands.lisp); the editor adds no logic of its own to their
 * replies beyond parsing a `file:line'.
 *
 * Two rules from the ARexx client carry over.  Nothing here waits for a
 * reply: each request has a continuation in ck_intro_reply(), reached from
 * the input loop when the reply arrives.  And the idle timer never prompts:
 * a status-line lookup that found no clamiga port stays quiet, where a
 * command the user typed may offer to start one.
 *
 * What the scanner side of this looks like is in lisp/sexp.c
 * (ck_sexp_operator_at_point, ck_sexp_symbol_at_point), host-tested.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

static LONG ck_get(Object *obj, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, obj, &value);
    return (LONG)value;
}

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

static void ck_copy(char *out, int32_t size, const char *s)
{
    strncpy(out, s, (size_t)size - 1);
    out[size - 1] = '\0';
}

/* The argument of a command string: what follows the verb and one space,
 * or "" -- `ARGLIST foo' gives `foo'. */
static const char *ck_subject_arg(const char *subject)
{
    const char *sp = (subject != NULL) ? strchr(subject, ' ') : NULL;
    return (sp != NULL) ? sp + 1 : "";
}

/* ------------------------------------------------------------------ *
 * What is at point
 * ------------------------------------------------------------------ */

/* The symbol under or before point, its bounds as document indices. */
static int32_t ck_intro_symbol_at_point(ck_doc *doc, char *out, int32_t size,
                                        int32_t *start, int32_t *end)
{
    ck_context ctx;
    int32_t    s, e, n;

    out[0] = '\0';
    if (!ck_doc_context(doc, &ctx))
        return 0;
    if (!ck_sexp_symbol_at_point(ctx.buf, ctx.len, ctx.point, &s, &e)) {
        ck_context_free(&ctx);
        return 0;
    }
    n = e - s;
    if (n > size - 1)
        n = size - 1;
    memcpy(out, ctx.buf + s, (size_t)n);
    out[n] = '\0';
    if (start != NULL)
        *start = ctx.base + s;
    if (end != NULL)
        *end = ctx.base + e;
    ck_context_free(&ctx);
    return 1;
}

static int32_t ck_intro_operator_at_point(ck_doc *doc, char *out, int32_t size)
{
    ck_context ctx;
    int32_t    s, e, n;

    out[0] = '\0';
    if (!ck_doc_context(doc, &ctx))
        return 0;
    if (!ck_sexp_operator_at_point(ctx.buf, ctx.len, ctx.point, &s, &e)) {
        ck_context_free(&ctx);
        return 0;
    }
    n = e - s;
    if (n > size - 1)
        n = size - 1;
    memcpy(out, ctx.buf + s, (size_t)n);
    out[n] = '\0';
    ck_context_free(&ctx);
    return 1;
}

/* ------------------------------------------------------------------ *
 * The arglist in the status line
 * ------------------------------------------------------------------ */

static void ck_intro_cache_key(ck_doc *doc, const char *op, char *key, int32_t size)
{
    snprintf(key, (size_t)size, "%s|%s",
             doc->package[0] != '\0' ? doc->package : "CL-USER", op);
}

/* `(a &optional b)' from clamiga becomes `(foo a &optional b)' on the
 * status line: the operator is what the user is looking at. */
static void ck_intro_render_arglist(const char *op, const char *reply,
                                    char *out, int32_t size)
{
    if (reply[0] == '(')
        snprintf(out, (size_t)size, "(%s%s%s", op,
                 (reply[1] == ')') ? "" : " ", reply + 1);
    else
        snprintf(out, (size_t)size, "%s: %s", op, reply);
}

static void ck_intro_show_arglist(ck_doc *doc, const char *op, const char *value)
{
    ck_copy(doc->arglist_op, (int32_t)sizeof doc->arglist_op, op);
    if (value != NULL && value[0] != '\0')
        ck_intro_render_arglist(op, value, doc->arglist, (int32_t)sizeof doc->arglist);
    else
        doc->arglist[0] = '\0';
    ck_doc_update_status(doc);
}

int32_t ck_intro_arglist(ck_doc *doc, int32_t echo)
{
    ck_app     *app = doc->app;
    char        op[CK_SYM_MAX];
    char        key[CK_SYM_MAX + CK_PKG_MAX + 2];
    const char *cached;

    if (!ck_intro_operator_at_point(doc, op, (int32_t)sizeof op)) {
        doc->arglist_want[0] = '\0';
        if (doc->arglist[0] != '\0' || doc->arglist_op[0] != '\0') {
            doc->arglist[0]    = '\0';
            doc->arglist_op[0] = '\0';
            ck_doc_update_status(doc);
        }
        if (echo) {
            ck_message(doc, "No operator at point");
            ck_beep(doc);
        }
        return 1;
    }

    ck_copy(doc->arglist_want, (int32_t)sizeof doc->arglist_want, op);

    /* Already showing it -- or already known to have none. */
    if (!echo && strcmp(op, doc->arglist_op) == 0)
        return 1;

    ck_intro_cache_key(doc, op, key, (int32_t)sizeof key);
    cached = ck_symcache_get(&app->arglists, key);
    if (cached != NULL) {
        ck_intro_show_arglist(doc, op, cached);
        if (echo) {
            if (doc->arglist[0] != '\0') {
                ck_message(doc, "%s", doc->arglist);
            } else {
                ck_message(doc, "No arglist for %s", op);
                ck_beep(doc);
            }
        }
        return 1;
    }

    if (!echo) {
        /* Quietly: never prompt, and one question at a time. */
        if (!ck_rexx_ready(app))
            return 0;
        if (doc->arglist_inflight > 0)
            return 0;
    }

    ck_doc_send_package(doc, 0);
    if (ck_rexx_send(app, doc, echo ? CK_REQ_ARGLIST_ECHO : CK_REQ_ARGLIST,
                     "ARGLIST %s", op) < 0)
        return echo;   /* the user declined to start clamiga: done */
    if (!echo)
        doc->arglist_inflight++;
    return 1;
}

static void ck_intro_arglist_reply(ck_doc *doc, uint16_t kind, const char *subject,
                                   int32_t rc, const char *text)
{
    const char *op = ck_subject_arg(subject);
    char        key[CK_SYM_MAX + CK_PKG_MAX + 2];
    char        value[CK_ARGLIST_MAX];

    if (kind == CK_REQ_ARGLIST && doc->arglist_inflight > 0)
        doc->arglist_inflight--;
    if (op[0] == '\0')
        return;

    if (rc == CK_RC_OK)
        ck_first_line(text, value, (int32_t)sizeof value);
    else
        value[0] = '\0';   /* remembered as a miss */

    ck_intro_cache_key(doc, op, key, (int32_t)sizeof key);
    ck_symcache_put(&doc->app->arglists, key, value);

    /* Still what the cursor is on?  The idle tick asks again otherwise. */
    if (strcmp(op, doc->arglist_want) == 0)
        ck_intro_show_arglist(doc, op, value);

    if (kind == CK_REQ_ARGLIST_ECHO) {
        if (value[0] != '\0') {
            char shown[CK_ARGLIST_MAX];
            ck_intro_render_arglist(op, value, shown, (int32_t)sizeof shown);
            ck_message(doc, "%s", shown);
        } else {
            char line[CK_MSG_MAX];
            ck_first_line(text, line, (int32_t)sizeof line);
            ck_message(doc, "%s", line[0] != '\0' ? line : "No arglist");
            ck_beep(doc);
        }
    }
}

void ck_intro_idle(ck_doc *doc)
{
    int32_t idx;

    if (doc->closing || !doc->lisp_mode || doc->win == NULL)
        return;
    /* Only the window the user is in; the others keep what they show. */
    if (ck_doc_active(doc->app) != doc)
        return;
    if (doc->mini_state != CK_MINI_IDLE)
        return;

    idx = ck_doc_cursor_index(doc);
    if (idx != doc->idle_index) {
        doc->idle_index = idx;   /* still moving: look again next tick */
        return;
    }
    if (idx == doc->arglist_index && doc->edit_serial == doc->arglist_serial)
        return;

    /* Without a port every tick would scan for one; every couple of
     * seconds is plenty. */
    if (!doc->app->connected && (++doc->idle_ticks % 8) != 0)
        return;

    if (ck_intro_arglist(doc, 0)) {
        doc->arglist_index  = idx;
        doc->arglist_serial = doc->edit_serial;
    }
}

/* ------------------------------------------------------------------ *
 * Completion
 * ------------------------------------------------------------------ */

#define CK_COMPLETE_SHOWN 8
#define CK_COMPLETE_CAP   200   /* ext.dev:*max-completions* */

void ck_intro_complete(ck_doc *doc)
{
    char    sym[CK_SYM_MAX];
    int32_t start = 0, end = 0, point, n;

    point = ck_doc_cursor_index(doc);
    if (!ck_intro_symbol_at_point(doc, sym, (int32_t)sizeof sym, &start, &end) ||
        start >= point) {
        ck_message(doc, "No symbol before point");
        ck_beep(doc);
        return;
    }

    /* Only the part before point is the prefix; what follows stays. */
    n = point - start;
    if (n < (int32_t)sizeof sym)
        sym[n] = '\0';
    doc->complete_start = start;
    doc->complete_end   = point;

    ck_doc_send_package(doc, 0);
    if (ck_rexx_send(doc->app, doc, CK_REQ_COMPLETE_BUFFER, "COMPLETE %s", sym) >= 0)
        ck_message(doc, "Completing %s ...", sym);
}

/* Apply the candidate list to TEXT in the minibuffer: complete it as far
 * as it goes and say what is left. */
static void ck_intro_mini_apply(ck_doc *doc, const char *text)
{
    const char *hits[CK_COMPLETE_SHOWN];
    char        common[CK_MINI_MAX];
    char        shown[CK_MSG_MAX];
    int32_t     n, i, used;

    n = ck_complete((const char *const *)doc->completions.items,
                    doc->completions.count, text, hits, CK_COMPLETE_SHOWN,
                    common, (int32_t)sizeof common);

    if (n == 0) {
        ck_message(doc, "[No match]");
        return;
    }
    if (n == 1) {
        set(doc->mini, MUIA_String_Contents, (IPTR)hits[0]);
        ck_message(doc, "[Sole completion]");
        return;
    }

    set(doc->mini, MUIA_String_Contents, (IPTR)common);
    used = snprintf(shown, sizeof shown, "[%ld completions:", (long)n);
    for (i = 0; i < n && i < CK_COMPLETE_SHOWN && used < (int32_t)sizeof shown - 8; i++)
        used += snprintf(shown + used, sizeof shown - (size_t)used, " %s", hits[i]);
    snprintf(shown + used, sizeof shown - (size_t)used, "%s]",
             (n > CK_COMPLETE_SHOWN) ? " ..." : "");
    ck_message(doc, "%s", shown);
}

/* Whether the candidates on hand answer for TEXT: they were fetched for a
 * prefix of it, and the list was not cut short by clamiga's cap (past the
 * cap a longer prefix may match symbols that were never sent). */
static int32_t ck_intro_completions_cover(ck_doc *doc, const char *text)
{
    size_t plen = strlen(doc->completions_prefix);

    if (plen == 0)
        return 0;
    if (strncmp(text, doc->completions_prefix, plen) != 0)
        return 0;
    if (doc->completions_capped && strlen(text) > plen)
        return 0;
    return 1;
}

int32_t ck_intro_mini_complete(ck_doc *doc, const char *text)
{
    if (text == NULL || text[0] == '\0') {
        ck_beep(doc);
        return 1;
    }
    if (ck_intro_completions_cover(doc, text)) {
        ck_intro_mini_apply(doc, text);
        return 1;
    }
    ck_doc_send_package(doc, 0);
    if (ck_rexx_send(doc->app, doc, CK_REQ_COMPLETE_MINI, "COMPLETE %s", text) >= 0)
        ck_message(doc, "Completing %s ...", text);
    return 1;
}

void ck_intro_complete_done(ck_doc *doc, const char *answer)
{
    if (answer == NULL || answer[0] == '\0')
        return;
    ck_doc_replace(doc, doc->complete_start, doc->complete_end, answer);
}

static void ck_intro_take_candidates(ck_doc *doc, const char *prefix,
                                     const char *text)
{
    int32_t n = ck_strlist_set_lines(&doc->completions, text);

    ck_copy(doc->completions_prefix, (int32_t)sizeof doc->completions_prefix, prefix);
    doc->completions_capped = (n >= CK_COMPLETE_CAP);
}

static void ck_intro_complete_buffer_reply(ck_doc *doc, const char *subject,
                                           int32_t rc, const char *text)
{
    const char *prefix = ck_subject_arg(subject);
    char        common[CK_MINI_MAX];
    int32_t     n;

    if (rc != CK_RC_OK) {
        char line[CK_MSG_MAX];
        ck_first_line(text, line, (int32_t)sizeof line);
        ck_message(doc, "%s", line);
        ck_beep(doc);
        return;
    }

    ck_intro_take_candidates(doc, prefix, text);
    n = doc->completions.count;

    if (n <= 0) {
        ck_message(doc, "[No match]");
        ck_beep(doc);
        return;
    }
    if (n == 1) {
        ck_doc_replace(doc, doc->complete_start, doc->complete_end,
                       doc->completions.items[0]);
        ck_message(doc, "[Sole completion]");
        return;
    }

    /* Ambiguous: the minibuffer takes over with the common prefix, TAB
     * there narrows it, RET puts the answer in the buffer. */
    ck_complete((const char *const *)doc->completions.items, n, prefix,
                NULL, 0, common, (int32_t)sizeof common);
    ck_doc_prompt(doc, "Complete: ", common[0] != '\0' ? common : prefix,
                  CK_CMD_COMPLETE_SYMBOL, CK_COMPLETE_SYMBOL, 0);
}

static void ck_intro_complete_mini_reply(ck_doc *doc, const char *subject,
                                         int32_t rc, const char *text)
{
    const char *current;

    /* The prompt may have been abandoned meanwhile. */
    if (doc->mini_state != CK_MINI_PROMPT || doc->mini_source != CK_COMPLETE_SYMBOL)
        return;

    if (rc != CK_RC_OK) {
        char line[CK_MSG_MAX];
        ck_first_line(text, line, (int32_t)sizeof line);
        ck_message(doc, "%s", line);
        ck_beep(doc);
        return;
    }

    ck_intro_take_candidates(doc, ck_subject_arg(subject), text);
    current = (const char *)ck_get(doc->mini, MUIA_String_Contents);
    ck_intro_mini_apply(doc, current != NULL ? current : "");
}

/* ------------------------------------------------------------------ *
 * Definitions
 * ------------------------------------------------------------------ */

void ck_intro_edit_definition(ck_doc *doc)
{
    char sym[CK_SYM_MAX];

    if (ck_intro_symbol_at_point(doc, sym, (int32_t)sizeof sym, NULL, NULL))
        ck_intro_edit_definition_named(doc, sym);
    else
        ck_doc_prompt(doc, "Edit definition of: ", "", CK_CMD_EDIT_DEFINITION,
                      CK_COMPLETE_SYMBOL, 0);
}

void ck_intro_edit_definition_named(ck_doc *doc, const char *name)
{
    if (name == NULL || name[0] == '\0') {
        ck_beep(doc);
        return;
    }
    ck_doc_send_package(doc, 1);
    ck_rexx_send(doc->app, doc, CK_REQ_SOURCE_LOCATION, "SOURCE-LOCATION %s", name);
}

static void ck_intro_definition_reply(ck_app *app, ck_doc *doc, const char *subject,
                                      int32_t rc, const char *text)
{
    char    file[CK_PATH_MAX];
    int32_t line = 0;
    ck_doc *target;

    if (rc != CK_RC_OK || !ck_diag_parse_location(text, file, (int32_t)sizeof file, &line)) {
        if (doc != NULL) {
            char shown[CK_MSG_MAX];
            ck_first_line(text, shown, (int32_t)sizeof shown);
            if (shown[0] == '\0')
                snprintf(shown, sizeof shown, "No source location for %s",
                         ck_subject_arg(subject));
            ck_message(doc, "%s", shown);
            ck_beep(doc);
        }
        return;
    }

    /* Remember where we were, so `M-,' can come back. */
    if (doc != NULL)
        ck_locstack_push(&app->locations, doc->path, doc->id, ck_doc_cursor_index(doc));

    target = ck_doc_find_by_path(app, file);
    if (target == NULL)
        target = ck_doc_new(app, file);
    if (target == NULL) {
        if (doc != NULL) {
            ck_message(doc, "Cannot open %s", file);
            ck_beep(doc);
        }
        return;
    }
    ck_doc_goto_line(target, line);
}

void ck_intro_pop_definition(ck_doc *doc)
{
    ck_app     *app = doc->app;
    ck_location loc;
    ck_doc     *target = NULL, *d;

    if (!ck_locstack_pop(&app->locations, &loc)) {
        ck_message(doc, "No previous definition");
        ck_beep(doc);
        return;
    }

    for (d = app->docs; d != NULL; d = d->next) {
        if (!d->closing && d->id == loc.id) {
            target = d;
            break;
        }
    }
    if (target == NULL && loc.path[0] != '\0') {
        target = ck_doc_find_by_path(app, loc.path);
        if (target == NULL)
            target = ck_doc_new(app, loc.path);
    }
    if (target == NULL) {
        ck_message(doc, "Cannot return to %s",
                   loc.path[0] != '\0' ? loc.path : "a closed window");
        ck_beep(doc);
        return;
    }

    ck_doc_activate(target);
    ck_doc_set_cursor_index(target, loc.index);
    set(target->win, MUIA_Window_ActiveObject, (IPTR)target->text);
}

/* ------------------------------------------------------------------ *
 * Describe, apropos, macroexpand: text into a scratch window
 * ------------------------------------------------------------------ */

void ck_intro_describe(ck_doc *doc)
{
    char sym[CK_SYM_MAX];

    ck_intro_symbol_at_point(doc, sym, (int32_t)sizeof sym, NULL, NULL);
    ck_doc_prompt(doc, "Describe symbol: ", sym, CK_CMD_DESCRIBE_SYMBOL,
                  CK_COMPLETE_SYMBOL, 0);
}

void ck_intro_describe_named(ck_doc *doc, const char *name)
{
    if (name == NULL || name[0] == '\0') {
        ck_beep(doc);
        return;
    }
    ck_doc_send_package(doc, 1);
    ck_rexx_send(doc->app, doc, CK_REQ_DESCRIBE, "DESCRIBE %s", name);
}

void ck_intro_apropos(ck_doc *doc)
{
    ck_doc_prompt(doc, "Apropos: ", "", CK_CMD_APROPOS, CK_COMPLETE_NONE, 0);
}

void ck_intro_apropos_named(ck_doc *doc, const char *text)
{
    if (text == NULL || text[0] == '\0') {
        ck_beep(doc);
        return;
    }
    ck_doc_send_package(doc, 1);
    ck_rexx_send(doc->app, doc, CK_REQ_APROPOS, "APROPOS %s", text);
}

void ck_intro_macroexpand(ck_doc *doc, int32_t full)
{
    ck_context ctx;
    int32_t    pos, start, stop;
    STRPTR     form;
    char       c;

    if (!ck_doc_context_full(doc, &ctx)) {
        ck_beep(doc);
        return;
    }

    /* The form at point: the one starting here, else the one just closed
     * before point, else the innermost one around it. */
    pos = ctx.point;
    c   = (pos < ctx.len) ? ctx.buf[pos] : '\0';
    if (c == '(' || c == '\'' || c == '`' || c == '#' || c == ',')
        start = pos;
    else if (pos > 0 && ctx.buf[pos - 1] == ')')
        start = ck_sexp_backward(ctx.buf, ctx.len, pos);
    else
        start = ck_sexp_up(ctx.buf, ctx.len, pos);

    stop = (start >= 0) ? ck_sexp_forward(ctx.buf, ctx.len, start) : -1;
    if (stop < 0) {
        ck_context_free(&ctx);
        ck_message(doc, "No form at point");
        ck_beep(doc);
        return;
    }

    form = (STRPTR)AllocVec((ULONG)(stop - start) + 1, MEMF_ANY);
    if (form == NULL) {
        ck_context_free(&ctx);
        return;
    }
    memcpy(form, ctx.buf + start, (size_t)(stop - start));
    form[stop - start] = '\0';
    ck_context_free(&ctx);

    ck_doc_send_package(doc, 1);
    ck_rexx_send_text(doc->app, doc, CK_REQ_MACROEXPAND,
                      full ? "MACROEXPAND " : "MACROEXPAND-1 ", (const char *)form);
    FreeVec(form);
}

static void ck_intro_text_reply(ck_app *app, ck_doc *doc, const char *window,
                                int32_t lisp_mode, uint16_t kind,
                                const char *subject, int32_t rc, const char *text)
{
    ck_doc *out;

    if (rc != CK_RC_OK) {
        if (doc != NULL) {
            char line[CK_MSG_MAX];
            ck_first_line(text, line, (int32_t)sizeof line);
            ck_message(doc, "%s", line[0] != '\0' ? line : "clamiga could not answer");
            ck_beep(doc);
        }
        return;
    }

    if (kind == CK_REQ_APROPOS && text[0] == '\0') {
        if (doc != NULL)
            ck_message(doc, "No symbols matching \"%s\"", ck_subject_arg(subject));
        return;
    }

    out = ck_doc_scratch(app, window, lisp_mode);
    if (out == NULL) {
        if (doc != NULL)
            ck_message(doc, "Cannot open %s", window);
        return;
    }
    ck_doc_set_text(out, text);
}

/* ------------------------------------------------------------------ *
 * The continuations
 * ------------------------------------------------------------------ */

void ck_intro_reply(ck_app *app, ck_doc *doc, uint16_t kind,
                    const char *subject, int32_t rc, const char *text)
{
    if (text == NULL)
        text = "";
    if (subject == NULL)
        subject = "";

    switch (kind) {
    case CK_REQ_ARGLIST:
    case CK_REQ_ARGLIST_ECHO:
        if (doc != NULL)
            ck_intro_arglist_reply(doc, kind, subject, rc, text);
        break;

    case CK_REQ_COMPLETE_BUFFER:
        if (doc != NULL)
            ck_intro_complete_buffer_reply(doc, subject, rc, text);
        break;

    case CK_REQ_COMPLETE_MINI:
        if (doc != NULL)
            ck_intro_complete_mini_reply(doc, subject, rc, text);
        break;

    case CK_REQ_SOURCE_LOCATION:
        ck_intro_definition_reply(app, doc, subject, rc, text);
        break;

    case CK_REQ_DESCRIBE:
        ck_intro_text_reply(app, doc, "*clamacs-description*", 0, kind, subject, rc, text);
        break;

    case CK_REQ_APROPOS:
        ck_intro_text_reply(app, doc, "*clamacs-apropos*", 0, kind, subject, rc, text);
        break;

    case CK_REQ_MACROEXPAND:
        ck_intro_text_reply(app, doc, "*clamacs-macroexpansion*", 1, kind, subject, rc, text);
        break;

    default:
        break;
    }
}
