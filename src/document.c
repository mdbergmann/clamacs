/*
 * document.c -- one window per file, and the commands that act on it.
 *
 * This is where the portable core meets MUI.  The rule it follows: never
 * reimplement something TextEditor.mcc already does.  Ordinary motion,
 * deletion, undo and selection are delegated to the class's own ARexx
 * command interface (MUIM_TextEditor_ARexxCmd), which is a documented,
 * stable entry point into exactly those operations -- and is the same
 * interface the editor's `TE' ARexx command passes through to.  Only the
 * things the class has no notion of -- the kill ring, sexp motion, Lisp
 * indentation, talking to clamiga -- are implemented here.
 *
 * One byte-offset convention holds throughout: MUIA_TextEditor_CursorIndex
 * and the offsets in exported text are the same numbers, because a line
 * node's length includes its newline.  That only stays true with the
 * NoStyle export hook -- the Plain hook writes \033P[...] colour escapes
 * into the exported text, which would both desynchronise every offset and
 * put escape sequences in saved files.  See ck_doc_new().
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>
#include <stdarg.h>

/* ------------------------------------------------------------------ *
 * Small wrappers
 * ------------------------------------------------------------------ */

static LONG ck_get(Object *obj, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, obj, &value);
    return (LONG)value;
}

/* Run one of the class's own ARexx commands.  Returns 1 on success. */
static int32_t ck_te(ck_doc *doc, const char *cmd)
{
    IPTR r = DoMethod(doc->text, MUIM_TextEditor_ARexxCmd, (IPTR)cmd);

    if (r == 0)
        return 0;
    if (r != (IPTR)TRUE)
        FreeVec((APTR)r);   /* a query command answered with a string */
    return 1;
}

static void ck_te_repeat(ck_doc *doc, const char *cmd, int32_t times)
{
    int32_t i;
    if (times < 0)
        times = -times;
    for (i = 0; i < times; i++) {
        if (!ck_te(doc, cmd))
            break;
    }
}

int32_t ck_doc_cursor_index(ck_doc *doc)
{
    return (int32_t)ck_get(doc->text, MUIA_TextEditor_CursorIndex);
}

void ck_doc_set_cursor_index(ck_doc *doc, int32_t index)
{
    if (index < 0)
        index = 0;
    set(doc->text, MUIA_TextEditor_CursorIndex, (IPTR)index);
}

STRPTR ck_doc_export_all(ck_doc *doc)
{
    return (STRPTR)DoMethod(doc->text, MUIM_TextEditor_ExportText);
}

/* The class has no attribute for the text's length, but POSITION EOF
 * followed by a read of the cursor index answers it; the cursor is put
 * back afterwards, so this is a query and not a move. */
int32_t ck_doc_end_index(ck_doc *doc)
{
    int32_t was = ck_doc_cursor_index(doc);
    int32_t end;

    DoMethod(doc->text, MUIM_TextEditor_ARexxCmd, (IPTR)"POSITION EOF");
    end = ck_doc_cursor_index(doc);
    if (end != was)
        set(doc->text, MUIA_TextEditor_CursorIndex, (IPTR)was);
    return end;
}

void ck_doc_insert_at(ck_doc *doc, int32_t index, const char *text)
{
    ck_doc_set_cursor_index(doc, index);
    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)(text != NULL ? text : ""),
             (IPTR)MUIV_TextEditor_InsertText_Cursor);
}

static STRPTR ck_export_lines(ck_doc *doc, LONG y0, LONG y1)
{
    return (STRPTR)DoMethod(doc->text, MUIM_TextEditor_ExportBlock,
                            (IPTR)(MUIF_TextEditor_ExportBlock_TakeBlock |
                                   MUIF_TextEditor_ExportBlock_FullLines),
                            (IPTR)0, (IPTR)y0, (IPTR)0, (IPTR)y1);
}

static STRPTR ck_export_range(ck_doc *doc, LONG x0, LONG y0, LONG x1, LONG y1)
{
    return (STRPTR)DoMethod(doc->text, MUIM_TextEditor_ExportBlock,
                            (IPTR)MUIF_TextEditor_ExportBlock_TakeBlock,
                            (IPTR)x0, (IPTR)y0, (IPTR)x1, (IPTR)y1);
}

static void ck_index_to_xy(ck_doc *doc, int32_t index, LONG *x, LONG *y)
{
    *x = 0;
    *y = 0;
    DoMethod(doc->text, MUIM_TextEditor_IndexToCursorXY, (IPTR)index,
             (IPTR)x, (IPTR)y);
}

void ck_context_free(ck_context *ctx)
{
    if (ctx->raw != NULL) {
        FreeVec(ctx->raw);
        ctx->raw = NULL;
    }
    ctx->buf   = NULL;
    ctx->len   = 0;
    ctx->point = 0;
}

/*
 * Export a range of lines with a starting point the sexp scanner can trust.
 * Its contract is that offset 0 is outside any string and any comment, and a
 * `(' in column 0 is the cheap way to guarantee that: it is a defun start by
 * definition.  If the range holds none, the caller falls back to the whole
 * buffer, where offset 0 is trivially clean.
 */
static int32_t ck_doc_context_range(ck_doc *doc, ck_context *ctx,
                                    LONG y0, LONG y1)
{
    int32_t cursor = ck_doc_cursor_index(doc);
    LONG    idx    = 0;
    STRPTR  raw;
    int32_t skip = -1, i, n;

    ctx->raw   = NULL;
    ctx->buf   = NULL;
    ctx->len   = 0;
    ctx->base  = 0;
    ctx->point = 0;

    if (y0 < 0)
        y0 = 0;
    if (y1 < y0)
        y1 = y0;

    raw = ck_export_lines(doc, y0, y1);
    if (raw == NULL)
        return 0;

    DoMethod(doc->text, MUIM_TextEditor_CursorXYToIndex,
             (IPTR)0, (IPTR)y0, (IPTR)&idx);

    n = (int32_t)strlen((const char *)raw);

    if (y0 == 0) {
        skip = 0;
    } else if (raw[0] == '(') {
        skip = 0;
    } else {
        for (i = 0; i + 1 < n; i++) {
            if (raw[i] == '\n' && raw[i + 1] == '(') {
                skip = i + 1;
                break;
            }
        }
    }

    if (skip < 0) {
        FreeVec(raw);
        return 0;
    }

    ctx->raw   = raw;
    ctx->buf   = (const char *)raw + skip;
    ctx->len   = n - skip;
    ctx->base  = (int32_t)idx + skip;
    ctx->point = cursor - ctx->base;
    if (ctx->point < 0)
        ctx->point = 0;
    if (ctx->point > ctx->len)
        ctx->point = ctx->len;
    return 1;
}

static LONG ck_doc_last_line(ck_doc *doc)
{
    /* MUIA_TextEditor_Prop_Entries is the class's totallines, a 1-based
     * count; the last line's 0-based index is one less.  ExportBlock leaves
     * its stop line alone when asked for one past the end, which would
     * silently truncate the export at the cursor -- so this clamp matters. */
    LONG total = ck_get(doc->text, MUIA_TextEditor_Prop_Entries);
    return (total > 0) ? total - 1 : 0;
}

/*
 * The window around the cursor, for the things that run on every keystroke:
 * colouring, paren matching, indentation, package tracking.  It reaches
 * forward as well as back -- a paren typed at point can have its partner
 * below, and an indenter that only ever saw the text above the cursor would
 * still be right, but a forward scan that ran off the end of the buffer it
 * was handed would not.
 */
int32_t ck_doc_context(ck_doc *doc, ck_context *ctx)
{
    LONG cy   = ck_get(doc->text, MUIA_TextEditor_CursorY);
    LONG last = ck_doc_last_line(doc);
    LONG y1   = cy + CK_CONTEXT_LINES;

    if (y1 > last)
        y1 = last;

    if (ck_doc_context_range(doc, ctx, cy - CK_CONTEXT_LINES, y1))
        return 1;

    /* No `(' in column 0 in the window: fall back to the whole buffer, where
     * offset 0 needs no proof. */
    return ck_doc_context_range(doc, ctx, 0, last);
}

/*
 * The whole buffer, for the structural commands -- end-of-defun, the sexp
 * motions, and everything that hands a form to clamiga.  A window is wrong
 * for these: a defun whose closing paren falls outside it reads as
 * unbalanced, so `C-M-e' would not move and `C-c C-c' would refuse to
 * evaluate.  These are single user actions, not per-keystroke work, so the
 * full export is affordable.
 */
int32_t ck_doc_context_full(ck_doc *doc, ck_context *ctx)
{
    return ck_doc_context_range(doc, ctx, 0, ck_doc_last_line(doc));
}

/* ------------------------------------------------------------------ *
 * Status line and echo area
 * ------------------------------------------------------------------ */

void ck_doc_update_status(ck_doc *doc)
{
    LONG x = ck_get(doc->text, MUIA_TextEditor_CursorX);
    LONG y = ck_get(doc->text, MUIA_TextEditor_CursorY);
    LONG changed = ck_get(doc->text, MUIA_TextEditor_HasChanged);

    /* The arglist of the operator at point rides at the end, where a long
     * one is cut by the window edge rather than pushing the line number
     * out of sight (introspect.c fills it in). */
    snprintf(doc->statusline, sizeof doc->statusline, "%s%s  %s  %ld:%ld%s%s",
             changed ? "*" : " ",
             doc->name[0] != '\0' ? doc->name : "(unnamed)",
             doc->package[0] != '\0' ? doc->package : "CL-USER",
             (long)(y + 1), (long)(x + 1),
             doc->arglist[0] != '\0' ? "  " : "", doc->arglist);

    set(doc->status, MUIA_Text_Contents, (IPTR)doc->statusline);
}

/* The arglist shown belongs to a text that is gone: forget it, and let the
 * idle tick look again from scratch. */
static void ck_doc_forget_arglist(ck_doc *doc)
{
    doc->arglist[0]      = '\0';
    doc->arglist_op[0]   = '\0';
    doc->arglist_want[0] = '\0';
    doc->arglist_index   = -1;
    doc->idle_index      = -1;
    doc->edit_serial++;
}

/* ------------------------------------------------------------------ *
 * Colouring
 * ------------------------------------------------------------------ */

/* Values index MUIA_TextEditor_ColorMap, which textclass.c fills with eight
 * pens: 1 black, 2 white, 3 red, 4 green, 5 cyan, 6 yellow, 7 blue,
 * 8 magenta.  0 means "the normal pen". */
static uint32_t ck_colour_of(uint8_t kind)
{
    switch (kind) {
    case CK_TOK_COMMENT:  return 4;
    case CK_TOK_STRING:   return 6;
    case CK_TOK_CHAR:     return 6;
    case CK_TOK_KEYWORD:  return 5;
    case CK_TOK_NUMBER:   return 8;
    case CK_TOK_DEFINING: return 7;
    default:              return 0;
    }
}

static void ck_set_colour(ck_doc *doc, LONG x0, LONG y0, LONG x1, LONG y1,
                          uint32_t value)
{
    DoMethod(doc->text, MUIM_TextEditor_SetBlock, (IPTR)x0, (IPTR)y0,
             (IPTR)x1, (IPTR)y1, (IPTR)MUIF_TextEditor_SetBlock_Color,
             (IPTR)value);
}

/* Colour one line of already-exported text.  LINE points at the line's first
 * byte; LEN excludes the newline. */
#define CK_MAX_LINE_TOKENS 96

static void ck_colour_one(ck_doc *doc, LONG y, const char *line, int32_t len,
                          ck_tok_state *state)
{
    ck_token tokens[CK_MAX_LINE_TOKENS];
    int32_t  n, i;

    n = ck_tokenize_line(line, len, state, tokens, CK_MAX_LINE_TOKENS);
    if (n > CK_MAX_LINE_TOKENS)
        n = CK_MAX_LINE_TOKENS;

    /* Clear first: a token that shrank must not leave its old colour
     * behind on the characters it no longer covers. */
    if (len > 0)
        ck_set_colour(doc, 0, y, len, y, 0);

    for (i = 0; i < n; i++) {
        uint32_t colour = ck_colour_of(tokens[i].kind);
        if (colour == 0)
            continue;
        ck_set_colour(doc, (LONG)tokens[i].start, y,
                      (LONG)(tokens[i].start + tokens[i].len), y, colour);
    }
}

void ck_doc_colour_all(ck_doc *doc)
{
    STRPTR       text;
    const char  *p;
    ck_tok_state state;
    LONG         y = 0;
    LONG         was_changed;

    if (!doc->lisp_mode)
        return;

    text = ck_doc_export_all(doc);
    if (text == NULL)
        return;

    /* SetBlock counts as an edit as far as the class is concerned, so
     * colouring a freshly loaded file would mark it modified -- the status
     * line would show a `*' on an untouched buffer and closing it would ask
     * to save.  Colour is presentation, not content: restore the flag. */
    was_changed = ck_get(doc->text, MUIA_TextEditor_HasChanged);

    ck_tok_state_init(&state);
    set(doc->text, MUIA_TextEditor_Quiet, TRUE);

    p = (const char *)text;
    while (*p != '\0') {
        const char *nl  = strchr(p, '\n');
        int32_t     len = (nl != NULL) ? (int32_t)(nl - p) : (int32_t)strlen(p);
        ck_colour_one(doc, y, p, len, &state);
        y++;
        if (nl == NULL)
            break;
        p = nl + 1;
    }

    set(doc->text, MUIA_TextEditor_Quiet, FALSE);
    set(doc->text, MUIA_TextEditor_HasChanged, (IPTR)was_changed);
    FreeVec(text);
}

void ck_doc_colour_line(ck_doc *doc, int32_t line)
{
    ck_context   ctx;
    ck_tok_state state;
    const char  *p;
    LONG         y;
    LONG         was_changed;

    if (!doc->lisp_mode)
        return;
    if (!ck_doc_context(doc, &ctx))
        return;

    was_changed = ck_get(doc->text, MUIA_TextEditor_HasChanged);

    /* The context starts at a defun, where the tokenizer state is known to
     * be plain code -- so the carried state reaching the cursor's line is
     * correct without rescanning the whole file. */
    ck_tok_state_init(&state);
    {
        LONG bx = 0, by = 0;
        ck_index_to_xy(doc, ctx.base, &bx, &by);
        y = by;
    }

    p = ctx.buf;
    while (p < ctx.buf + ctx.len) {
        const char *nl  = memchr(p, '\n', (size_t)(ctx.buf + ctx.len - p));
        int32_t     len = (nl != NULL) ? (int32_t)(nl - p)
                                       : (int32_t)(ctx.buf + ctx.len - p);
        if (y == line)
            ck_colour_one(doc, y, p, len, &state);
        else
            ck_tokenize_line(p, len, &state, NULL, 0);
        y++;
        if (nl == NULL)
            break;
        p = nl + 1;
    }

    set(doc->text, MUIA_TextEditor_HasChanged, (IPTR)was_changed);
    ck_context_free(&ctx);
}

/* ------------------------------------------------------------------ *
 * Paren matching
 * ------------------------------------------------------------------ */

void ck_doc_show_paren(ck_doc *doc)
{
    ck_context ctx;
    int32_t    partner;
    int32_t    probe;
    LONG       was_changed;

    if (!doc->lisp_mode)
        return;

    was_changed = ck_get(doc->text, MUIA_TextEditor_HasChanged);

    /* Take the previous highlight down first. */
    if (doc->paren_y >= 0) {
        ck_set_colour(doc, doc->paren_x, doc->paren_y,
                      doc->paren_x + 1, doc->paren_y, 0);
        doc->paren_x = doc->paren_y = -1;
    }

    if (!ck_doc_context(doc, &ctx)) {
        set(doc->text, MUIA_TextEditor_HasChanged, (IPTR)was_changed);
        return;
    }

    /* Emacs highlights the partner of the paren BEFORE point, which is where
     * the cursor sits after typing a `)'. */
    probe = ctx.point - 1;
    if (probe < 0 || probe >= ctx.len) {
        ck_context_free(&ctx);
        set(doc->text, MUIA_TextEditor_HasChanged, (IPTR)was_changed);
        return;
    }

    partner = ck_sexp_match_paren(ctx.buf, ctx.len, probe);
    if (partner >= 0) {
        LONG px = 0, py = 0;
        ck_index_to_xy(doc, ctx.base + partner, &px, &py);
        ck_set_colour(doc, px, py, px + 1, py, 3);
        doc->paren_x = px;
        doc->paren_y = py;
    }

    ck_context_free(&ctx);
    set(doc->text, MUIA_TextEditor_HasChanged, (IPTR)was_changed);
}

/* ------------------------------------------------------------------ *
 * The kill ring
 * ------------------------------------------------------------------ */

static int32_t ck_last_was_kill(ck_doc *doc)
{
    return doc->last_command == CK_CMD_KILL_LINE ||
           doc->last_command == CK_CMD_KILL_WORD ||
           doc->last_command == CK_CMD_KILL_SEXP;
}

static void ck_kill_text(ck_doc *doc, const char *text, int32_t backwards)
{
    ck_app *app = doc->app;

    if (text == NULL)
        return;

    if (ck_last_was_kill(doc)) {
        if (backwards)
            ck_kill_prepend(&app->kill, text, (int32_t)strlen(text));
        else
            ck_kill_append(&app->kill, text, (int32_t)strlen(text));
    } else {
        ck_kill_push(&app->kill, text, (int32_t)strlen(text));
    }
}

/* Mark [start,stop) as a block, hand its text back, and (optionally) delete
 * it.  Returns an AllocVec'd string the caller frees. */
static STRPTR ck_take_region(ck_doc *doc, int32_t start, int32_t stop,
                             int32_t erase)
{
    LONG   x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    STRPTR text;

    if (stop <= start)
        return NULL;

    ck_index_to_xy(doc, start, &x0, &y0);
    ck_index_to_xy(doc, stop,  &x1, &y1);

    text = ck_export_range(doc, x0, y0, x1, y1);
    if (text == NULL)
        return NULL;

    if (erase) {
        DoMethod(doc->text, MUIM_TextEditor_MarkText,
                 (IPTR)x0, (IPTR)y0, (IPTR)x1, (IPTR)y1);
        /* ERASE deletes the block without touching the clipboard, which is
         * what a kill should do -- only C-w and M-w mirror to it. */
        ck_te(doc, "ERASE");
    }
    return text;
}

/* ------------------------------------------------------------------ *
 * File I/O
 * ------------------------------------------------------------------ */

static void ck_basename(const char *path, char *out, int32_t size)
{
    const char *p = path;
    const char *base = path;

    while (*p != '\0') {
        if (*p == '/' || *p == ':')
            base = p + 1;
        p++;
    }
    strncpy(out, base, (size_t)size - 1);
    out[size - 1] = '\0';
}

STRPTR ck_doc_text_range(ck_doc *doc, int32_t start, int32_t stop)
{
    return ck_take_region(doc, start, stop, 0);
}

int32_t ck_doc_load_file(ck_doc *doc, const char *path)
{
    BPTR   fh;
    LONG   size, got;
    STRPTR buffer;

    fh = Open((STRPTR)path, MODE_OLDFILE);
    if (fh == (BPTR)0)
        return 0;

    Seek(fh, 0, OFFSET_END);
    size = Seek(fh, 0, OFFSET_BEGINNING);
    if (size < 0) {
        Close(fh);
        return 0;
    }

    buffer = (STRPTR)AllocVec((ULONG)size + 1, MEMF_ANY);
    if (buffer == NULL) {
        Close(fh);
        return 0;
    }

    got = Read(fh, buffer, size);
    Close(fh);
    if (got < 0) {
        FreeVec(buffer);
        return 0;
    }
    buffer[got] = '\0';

    set(doc->text, MUIA_TextEditor_Contents, (IPTR)buffer);
    FreeVec(buffer);

    strncpy(doc->path, path, sizeof doc->path - 1);
    doc->path[sizeof doc->path - 1] = '\0';
    ck_basename(doc->path, doc->name, (int32_t)sizeof doc->name);

    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
    set(doc->win, MUIA_Window_Title, (IPTR)doc->name);
    ck_doc_forget_arglist(doc);
    return 1;
}

void ck_doc_replace(ck_doc *doc, int32_t start, int32_t stop, const char *text)
{
    if (stop > start) {
        STRPTR old = ck_take_region(doc, start, stop, 1);
        if (old != NULL)
            FreeVec(old);
    }
    ck_doc_set_cursor_index(doc, start);
    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)text,
             (IPTR)MUIV_TextEditor_InsertText_Cursor);
}

void ck_doc_goto_line(ck_doc *doc, int32_t line)
{
    set(doc->win, MUIA_Window_Activate, TRUE);
    if (line > 0) {
        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(line - 1));
    }
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);
}

ck_doc *ck_doc_scratch(ck_app *app, const char *name, int32_t lisp_mode)
{
    ck_doc *doc;

    for (doc = app->docs; doc != NULL; doc = doc->next) {
        if (!doc->closing && doc->path[0] == '\0' && strcmp(doc->name, name) == 0)
            return doc;
    }

    doc = ck_doc_new(app, NULL);
    if (doc == NULL)
        return NULL;

    strncpy(doc->name, name, sizeof doc->name - 1);
    doc->name[sizeof doc->name - 1] = '\0';
    set(doc->win, MUIA_Window_Title, (IPTR)doc->name);

    if (doc->lisp_mode != lisp_mode) {
        doc->lisp_mode = lisp_mode;
        ck_keystate_init(&doc->keys, app->global, lisp_mode ? app->lisp : NULL);
    }
    return doc;
}

void ck_doc_set_text(ck_doc *doc, const char *text)
{
    set(doc->text, MUIA_TextEditor_Contents, (IPTR)(text != NULL ? text : ""));
    /* A reply is not an edit: closing the window must not ask to save. */
    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
    ck_doc_forget_arglist(doc);
    ck_doc_colour_all(doc);
    ck_doc_set_cursor_index(doc, 0);
    set(doc->win, MUIA_Window_Activate, TRUE);
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);
    ck_doc_update_status(doc);
}

int32_t ck_doc_save_file(ck_doc *doc, const char *path)
{
    BPTR   fh;
    STRPTR text;
    LONG   len, written;

    text = ck_doc_export_all(doc);
    if (text == NULL)
        return 0;

    fh = Open((STRPTR)path, MODE_NEWFILE);
    if (fh == (BPTR)0) {
        FreeVec(text);
        return 0;
    }

    len     = (LONG)strlen((const char *)text);
    written = Write(fh, text, len);
    Close(fh);
    FreeVec(text);

    if (written != len)
        return 0;

    if (path != doc->path) {
        strncpy(doc->path, path, sizeof doc->path - 1);
        doc->path[sizeof doc->path - 1] = '\0';
        ck_basename(doc->path, doc->name, (int32_t)sizeof doc->name);
        set(doc->win, MUIA_Window_Title, (IPTR)doc->name);
    }
    set(doc->text, MUIA_TextEditor_HasChanged, FALSE);
    return 1;
}

/* The ASL requester, used when `C-x C-f' is answered with an empty line. */
static int32_t ck_ask_file(ck_doc *doc, const char *title, int32_t save,
                           char *out, int32_t size)
{
    struct FileRequester *req;
    int32_t               ok = 0;

    req = (struct FileRequester *)MUI_AllocAslRequestTags(ASL_FileRequest,
                                                          TAG_DONE);
    if (req == NULL)
        return 0;

    if (MUI_AslRequestTags(req,
                           ASLFR_TitleText,    (IPTR)title,
                           ASLFR_DoSaveMode,   (IPTR)(save ? TRUE : FALSE),
                           ASLFR_InitialFile,  (IPTR)doc->name,
                           TAG_DONE)) {
        strncpy(out, (const char *)req->fr_Drawer, (size_t)size - 1);
        out[size - 1] = '\0';
        AddPart((STRPTR)out, (STRPTR)req->fr_File, (ULONG)size);
        ok = 1;
    }

    MUI_FreeAslRequest(req);
    return ok;
}

/* ------------------------------------------------------------------ *
 * The minibuffer
 * ------------------------------------------------------------------ */

/* The prompt label is sized to its text (MUIA_Text_SetMin), and MUI measures
 * a Text object only when its group is laid out, so a new prompt text needs
 * the row relaid: MUIM_Group_InitChange/ExitChange is how a group is
 * changed under an open window.  Unchanged text is left alone, so isearch
 * does not relayout on every keystroke. */
static void ck_doc_set_label(ck_doc *doc, const char *text)
{
    if (strcmp(doc->label, text) == 0)
        return;

    strncpy(doc->label, text, sizeof doc->label - 1);
    doc->label[sizeof doc->label - 1] = '\0';

    if (DoMethod(doc->miniline, MUIM_Group_InitChange)) {
        set(doc->prompt, MUIA_Text_Contents, (IPTR)doc->label);
        DoMethod(doc->miniline, MUIM_Group_ExitChange);
        /* The relayout re-shows the row's objects and the String comes
         * back inactive -- the window still names it as the active object,
         * so it must be taken away and given back for the keys to reach
         * it again (Vampire, MUI 3.8, 2026-09-11: without this, every key
         * after `Failing I-search: ' appeared was lost). */
        if (doc->mini_state != CK_MINI_IDLE) {
            set(doc->win, MUIA_Window_ActiveObject, MUIV_Window_ActiveObject_None);
            set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->mini);
        }
    } else {
        set(doc->prompt, MUIA_Text_Contents, (IPTR)doc->label);
    }
}

void ck_doc_echo(ck_doc *doc)
{
    /* With the minibuffer idle the echo area is the message line.  While a
     * prompt is open the message takes the prompt's place beside the input
     * ("[No match]" after TAB), which is as close as one line gets to
     * Emacs's minibuffer-message. */
    if (doc->mini_state == CK_MINI_IDLE)
        set(doc->msgline, MUIA_Text_Contents, (IPTR)doc->message);
    else
        ck_doc_set_label(doc, doc->message);
}

/* Open the minibuffer: the echo area flips to the prompt + input page,
 * the label is relaid for the new prompt, and the input gets the focus.
 * The page is switched before the label is set so that the row being
 * relaid is the one on show. */
static void ck_mini_open(ck_doc *doc, const char *prompt, const char *initial)
{
    /* The prompt IS what the echo area shows, so the port's STATUS reports
     * it too -- that is how a macro sees that a prompt is open. */
    strncpy(doc->message, prompt, sizeof doc->message - 1);
    doc->message[sizeof doc->message - 1] = '\0';

    set(doc->echo, MUIA_Group_ActivePage, 1);
    ck_doc_set_label(doc, prompt);
    set(doc->mini, MUIA_String_Contents, (IPTR)(initial != NULL ? initial : ""));
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->mini);
}

void ck_doc_prompt(ck_doc *doc, const char *prompt, const char *initial,
                   int16_t command, uint16_t source, int32_t arg)
{
    doc->mini_state   = CK_MINI_PROMPT;
    doc->mini_command = command;
    doc->mini_source  = source;
    doc->mini_arg     = arg;

    ck_mini_open(doc, prompt, initial);
}

static void ck_mini_finish(ck_doc *doc)
{
    doc->mini_state   = CK_MINI_IDLE;
    doc->mini_command = CK_CMD_NONE;
    doc->mini_source  = CK_COMPLETE_NONE;
    doc->message[0]   = '\0';
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);
    set(doc->echo, MUIA_Group_ActivePage, 0);
    set(doc->msgline, MUIA_Text_Contents, (IPTR)doc->message);
    set(doc->mini, MUIA_String_Contents, (IPTR)"");
    /* The label is cleared on the hidden page without a relayout; the next
     * prompt relays it once it is on show again. */
    doc->label[0] = '\0';
    set(doc->prompt, MUIA_Text_Contents, (IPTR)doc->label);
}

void ck_doc_minibuffer_abort(ck_doc *doc)
{
    if (doc->mini_state == CK_MINI_ISEARCH)
        ck_doc_set_cursor_index(doc, doc->isearch_anchor);
    ck_mini_finish(doc);
    ck_message(doc, "Quit");
}

static ck_history *ck_doc_history(ck_doc *doc)
{
    switch (doc->mini_source) {
    case CK_COMPLETE_COMMAND: return &doc->app->hist_command;
    case CK_COMPLETE_FILE:    return &doc->app->hist_file;
    case CK_COMPLETE_SYMBOL:  return &doc->app->hist_symbol;
    default:                  return &doc->app->hist_eval;
    }
}

static void ck_isearch_step(ck_doc *doc, const char *pattern, int32_t again)
{
    ULONG flags = 0;

    if (pattern == NULL || pattern[0] == '\0')
        return;

    if (doc->isearch_back)
        flags |= MUIF_TextEditor_Search_Backwards;
    if (again)
        flags |= MUIF_TextEditor_Search_Next;

    /* The pattern is in the input beside the label, so the label carries
     * only the state; the port's STATUS still reports the whole line. */
    if (!DoMethod(doc->text, MUIM_TextEditor_Search, (IPTR)pattern, (IPTR)flags)) {
        snprintf(doc->message, sizeof doc->message, "Failing I-search: %s", pattern);
        ck_doc_set_label(doc, "Failing I-search: ");
    } else {
        snprintf(doc->message, sizeof doc->message, "%sI-search: %s",
                 doc->isearch_back ? "Reverse " : "", pattern);
        ck_doc_set_label(doc, doc->isearch_back ? "Reverse I-search: " : "I-search: ");
    }
}

/* The keys the minibuffer takes away from the string gadget: C-g whenever
 * it is open; C-s/C-r in isearch; TAB and the history keys at a prompt.
 * This is the one place that list lives -- ck_doc_minibuffer_key() acts on
 * exactly these, and the mini class's edit hook (textclass.c) asks it
 * before taking a key out of the active String's hands. */
int32_t ck_doc_minibuffer_binds(const ck_doc *doc, ck_key key)
{
    if (doc->mini_state == CK_MINI_IDLE)
        return 0;
    if (key == ck_key_make('g', CK_MOD_CTRL))
        return 1;
    if (doc->mini_state == CK_MINI_ISEARCH)
        return key == ck_key_make('s', CK_MOD_CTRL) ||
               key == ck_key_make('r', CK_MOD_CTRL);
    return key == ck_key_make(CK_KEY_TAB, 0) ||
           key == ck_key_make('p', CK_MOD_META) ||
           key == ck_key_make('n', CK_MOD_META);
}

/* Return non-zero when the key belongs to the minibuffer and must not reach
 * the string gadget. */
int32_t ck_doc_minibuffer_key(ck_doc *doc, ck_key key)
{
    if (!ck_doc_minibuffer_binds(doc, key))
        return 0;

    if (key == ck_key_make('g', CK_MOD_CTRL)) {
        ck_doc_minibuffer_abort(doc);
        return 1;
    }

    if (doc->mini_state == CK_MINI_ISEARCH) {
        /* C-s or C-r: search again, in that direction. */
        doc->isearch_back = (key == ck_key_make('r', CK_MOD_CTRL));
        ck_isearch_step(doc, (const char *)ck_get(doc->mini,
                                                  MUIA_String_Contents), 1);
        return 1;
    }

    if (key == ck_key_make(CK_KEY_TAB, 0)) {
        const char *text = (const char *)ck_get(doc->mini, MUIA_String_Contents);
        const char *hits[16];
        char        common[CK_MINI_MAX];
        int32_t     n = 0;

        if (doc->mini_source == CK_COMPLETE_COMMAND) {
            n = ck_command_complete(text, hits, 16, common, (int32_t)sizeof common);
        } else if (doc->mini_source == CK_COMPLETE_SYMBOL) {
            /* Symbols come from clamiga, asynchronously; introspect.c
             * completes from the candidates it has or asks for more. */
            ck_intro_mini_complete(doc, text);
            return 1;
        } else {
            ck_beep(doc);
            return 1;
        }

        if (n == 0) {
            ck_message(doc, "[No match]");
        } else {
            set(doc->mini, MUIA_String_Contents, (IPTR)common);
            if (n == 1)
                ck_message(doc, "[Sole completion]");
            else
                ck_message(doc, "[%ld completions]", (long)n);
        }
        return 1;
    }

    /* M-p / M-n: the history. */
    {
        ck_history *hist = ck_doc_history(doc);
        const char *item = (key == ck_key_make('p', CK_MOD_META))
                               ? ck_hist_prev(hist) : ck_hist_next(hist);
        set(doc->mini, MUIA_String_Contents, (IPTR)(item != NULL ? item : ""));
    }
    return 1;
}

/* ------------------------------------------------------------------ *
 * Talking to clamiga
 * ------------------------------------------------------------------ */

static void ck_doc_track_package(ck_doc *doc)
{
    ck_context ctx;
    char       pkg[CK_PKG_MAX];

    /* The whole buffer, not a window: `(in-package ...)' sits at the top of
     * the file and the cursor is usually nowhere near it.  This runs when a
     * document opens and before an eval, not on every keystroke. */
    if (!ck_doc_context_full(doc, &ctx))
        return;
    if (ck_sexp_current_package(ctx.buf, ctx.len, ctx.point, pkg,
                                (int32_t)sizeof pkg)) {
        strncpy(doc->package, pkg, sizeof doc->package - 1);
        doc->package[sizeof doc->package - 1] = '\0';
    }
    ck_context_free(&ctx);
}

void ck_doc_send_package(ck_doc *doc, int32_t track)
{
    ck_app     *app = doc->app;
    const char *pkg;

    if (track)
        ck_doc_track_package(doc);

    /* No (in-package ...) in the buffer means CL-USER, which is also where
     * a fresh clamiga starts -- but not where it stays once another buffer
     * has spoken, so it is said explicitly. */
    pkg = (doc->package[0] != '\0') ? doc->package : "CL-USER";
    if (Stricmp((STRPTR)pkg, (STRPTR)app->wire_package) == 0)
        return;

    if (ck_rexx_send(app, doc, CK_REQ_IN_PACKAGE, "IN-PACKAGE %s", pkg) >= 0) {
        strncpy(app->wire_package, pkg, sizeof app->wire_package - 1);
        app->wire_package[sizeof app->wire_package - 1] = '\0';
    }
}

/* Send a form for evaluation, preceded by an IN-PACKAGE when the buffer's
 * package differs from what the port was last told. */
static void ck_doc_eval(ck_doc *doc, const char *form)
{
    ck_doc_send_package(doc, 1);
    ck_rexx_send_text(doc->app, doc, CK_REQ_EVAL, "EVAL ", form);
}

static void ck_doc_eval_region(ck_doc *doc, int32_t start, int32_t stop)
{
    STRPTR text = ck_take_region(doc, start, stop, 0);

    if (text == NULL) {
        ck_beep(doc);
        return;
    }
    ck_doc_eval(doc, (const char *)text);
    FreeVec(text);
}

static void ck_doc_save_and_load(ck_doc *doc)
{
    if (doc->path[0] == '\0') {
        ck_message(doc, "Save the buffer to a file first");
        ck_beep(doc);
        return;
    }
    if (!ck_doc_save_file(doc, doc->path)) {
        ck_message(doc, "Cannot write %s", doc->path);
        ck_beep(doc);
        return;
    }
    ck_diag_clear(&doc->app->diags);
    ck_rexx_send(doc->app, doc, CK_REQ_LOAD, "LOAD %s", doc->path);
    ck_message(doc, "Loading %s ...", doc->name);
}

/* ------------------------------------------------------------------ *
 * Commands
 * ------------------------------------------------------------------ */

static void ck_cmd_kill_line(ck_doc *doc, int32_t arg)
{
    ck_context ctx;
    int32_t    start, stop;
    STRPTR     text;

    if (!ck_doc_context(doc, &ctx)) {
        ck_beep(doc);
        return;
    }

    start = ctx.point;
    stop  = start;
    while (stop < ctx.len && ctx.buf[stop] != '\n')
        stop++;

    /* At the end of a line, C-k joins it with the next one. */
    if (stop == start && stop < ctx.len)
        stop++;

    if (arg > 1) {
        int32_t lines = arg;
        while (lines > 1 && stop < ctx.len) {
            stop++;                       /* over the newline */
            while (stop < ctx.len && ctx.buf[stop] != '\n')
                stop++;
            lines--;
        }
    }

    start += ctx.base;
    stop  += ctx.base;
    ck_context_free(&ctx);

    text = ck_take_region(doc, start, stop, 1);
    if (text != NULL) {
        ck_kill_text(doc, (const char *)text, 0);
        FreeVec(text);
    }
}

static void ck_cmd_yank(ck_doc *doc, int32_t rotate)
{
    ck_app     *app = doc->app;
    const char *text;

    if (rotate) {
        if (doc->last_command != CK_CMD_YANK &&
            doc->last_command != CK_CMD_YANK_POP) {
            ck_message(doc, "Previous command was not a yank");
            ck_beep(doc);
            return;
        }
        text = ck_kill_rotate(&app->kill);
    } else {
        ck_kill_reset_yank(&app->kill);
        text = ck_kill_current(&app->kill);
    }

    if (text == NULL) {
        ck_message(doc, "Kill ring is empty");
        ck_beep(doc);
        return;
    }

    /* M-y replaces what the previous yank inserted.  Doing that properly
     * needs the extent of the last yank; for phase 1 the undo step is the
     * honest way to take it back. */
    if (rotate)
        ck_te(doc, "UNDO");

    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)text,
             (IPTR)MUIV_TextEditor_InsertText_Cursor);
}

static void ck_cmd_region(ck_doc *doc, int32_t erase, int32_t clipboard)
{
    int32_t point = ck_doc_cursor_index(doc);
    int32_t start, stop;
    STRPTR  text;

    if (doc->mark < 0) {
        ck_message(doc, "No mark set in this buffer");
        ck_beep(doc);
        return;
    }

    start = (doc->mark < point) ? doc->mark : point;
    stop  = (doc->mark < point) ? point : doc->mark;

    if (clipboard) {
        /* C-w and M-w also put the text on the Amiga clipboard, so other
         * applications see the last kill. */
        LONG x0 = 0, y0 = 0, x1 = 0, y1 = 0;
        ck_index_to_xy(doc, start, &x0, &y0);
        ck_index_to_xy(doc, stop,  &x1, &y1);
        text = ck_export_range(doc, x0, y0, x1, y1);
        DoMethod(doc->text, MUIM_TextEditor_MarkText,
                 (IPTR)x0, (IPTR)y0, (IPTR)x1, (IPTR)y1);
        ck_te(doc, erase ? "CUT" : "COPY");
    } else {
        text = ck_take_region(doc, start, stop, erase);
    }

    if (text != NULL) {
        ck_kill_push(&doc->app->kill, (const char *)text,
                     (int32_t)strlen((const char *)text));
        FreeVec(text);
    }
    doc->mark = -1;
}

static void ck_cmd_sexp_move(ck_doc *doc, int16_t command, int32_t arg)
{
    ck_context ctx;
    int32_t    pos, target = -1, i;
    int32_t    times = (arg < 0) ? -arg : arg;

    if (!ck_doc_context_full(doc, &ctx)) {
        ck_beep(doc);
        return;
    }

    pos = ctx.point;
    for (i = 0; i < times; i++) {
        switch (command) {
        case CK_CMD_FORWARD_SEXP:       target = ck_sexp_forward(ctx.buf, ctx.len, pos); break;
        case CK_CMD_BACKWARD_SEXP:      target = ck_sexp_backward(ctx.buf, ctx.len, pos); break;
        case CK_CMD_BACKWARD_UP_LIST:   target = ck_sexp_up(ctx.buf, ctx.len, pos); break;
        case CK_CMD_DOWN_LIST:          target = ck_sexp_down(ctx.buf, ctx.len, pos); break;
        case CK_CMD_BEGINNING_OF_DEFUN: target = ck_sexp_defun_start(ctx.buf, ctx.len, pos); break;
        case CK_CMD_END_OF_DEFUN:       target = ck_sexp_defun_end(ctx.buf, ctx.len, pos); break;
        default:                        target = -1; break;
        }
        if (target < 0)
            break;
        pos = target;
    }

    if (target < 0 && pos == ctx.point) {
        ck_context_free(&ctx);
        ck_message(doc, "No further expression");
        ck_beep(doc);
        return;
    }

    ck_doc_set_cursor_index(doc, ctx.base + pos);
    ck_context_free(&ctx);
}

static void ck_cmd_kill_sexp(ck_doc *doc)
{
    ck_context ctx;
    int32_t    start, stop;
    STRPTR     text;

    if (!ck_doc_context_full(doc, &ctx)) {
        ck_beep(doc);
        return;
    }
    start = ctx.point;
    stop  = ck_sexp_forward(ctx.buf, ctx.len, start);
    if (stop < 0) {
        ck_context_free(&ctx);
        ck_message(doc, "No expression after point");
        ck_beep(doc);
        return;
    }
    start += ctx.base;
    stop  += ctx.base;
    ck_context_free(&ctx);

    text = ck_take_region(doc, start, stop, 1);
    if (text != NULL) {
        ck_kill_text(doc, (const char *)text, 0);
        FreeVec(text);
    }
}

/*
 * Replace the leading whitespace of line Y with COLUMN spaces.
 *
 * The cursor follows the text: a cursor that was inside the indentation ends
 * up at the first non-blank character (which is what Emacs does, and is why
 * pressing Tab at the start of an already-correct line still moves point),
 * and one that was in the text keeps its position relative to it.
 */
static void ck_reindent_line(ck_doc *doc, LONG y, int32_t column)
{
    STRPTR  line;
    int32_t old = 0, i;
    LONG    cx  = ck_get(doc->text, MUIA_TextEditor_CursorX);
    LONG    new_cx;
    char    spaces[128];

    if (column < 0)
        return;
    if (column > (int32_t)sizeof spaces - 1)
        column = (int32_t)sizeof spaces - 1;

    line = ck_export_lines(doc, y, y);
    if (line == NULL)
        return;
    while (line[old] == ' ' || line[old] == '\t')
        old++;
    FreeVec(line);

    if (old != column) {
        for (i = 0; i < column; i++)
            spaces[i] = ' ';
        spaces[column] = '\0';

        /* Mark the old indentation and erase it in one step: that is one
         * undo entry rather than N backspaces, and ERASE leaves the
         * clipboard alone, which a kill would not. */
        if (old > 0) {
            DoMethod(doc->text, MUIM_TextEditor_MarkText,
                     (IPTR)0, (IPTR)y, (IPTR)old, (IPTR)y);
            ck_te(doc, "ERASE");
        }
        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)y);
        if (column > 0)
            DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)spaces,
                     (IPTR)MUIV_TextEditor_InsertText_Cursor);
    }

    new_cx = (cx <= old) ? (LONG)column : (cx - old + column);
    set(doc->text, MUIA_TextEditor_CursorY, (IPTR)y);
    set(doc->text, MUIA_TextEditor_CursorX, (IPTR)new_cx);
}

static void ck_cmd_indent_line(ck_doc *doc)
{
    ck_context ctx;
    int32_t    line_start, column;
    LONG       y = ck_get(doc->text, MUIA_TextEditor_CursorY);

    if (!ck_doc_context(doc, &ctx)) {
        ck_beep(doc);
        return;
    }

    line_start = ck_indent_line_start(ctx.buf, ctx.len, ctx.point);
    column     = ck_indent_for_line(ctx.buf, ctx.len, line_start);
    ck_context_free(&ctx);

    if (column >= 0)
        ck_reindent_line(doc, y, column);
}

static void ck_cmd_newline_and_indent(ck_doc *doc)
{
    DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)"\n",
             (IPTR)MUIV_TextEditor_InsertText_Cursor);
    ck_cmd_indent_line(doc);
}

/*
 * Reindent every line of the region.  Bottom to top: reindenting a line
 * changes the offsets of everything after it, but nothing before it, so
 * working upwards means the line numbers gathered at the start stay valid.
 */
static void ck_cmd_indent_region(ck_doc *doc)
{
    int32_t point = ck_doc_cursor_index(doc);
    LONG    y0 = 0, y1 = 0, y;

    if (doc->mark < 0) {
        ck_message(doc, "No mark set in this buffer");
        ck_beep(doc);
        return;
    }

    ck_index_to_xy(doc, (doc->mark < point) ? doc->mark : point, &y0, &y0);
    {
        LONG x = 0;
        ck_index_to_xy(doc, (doc->mark < point) ? doc->mark : point, &x, &y0);
        ck_index_to_xy(doc, (doc->mark < point) ? point : doc->mark, &x, &y1);
    }

    set(doc->text, MUIA_TextEditor_Quiet, TRUE);
    for (y = y1; y >= y0; y--) {
        ck_context ctx;
        int32_t    line_start, column;

        set(doc->text, MUIA_TextEditor_CursorX, (IPTR)0);
        set(doc->text, MUIA_TextEditor_CursorY, (IPTR)y);

        if (!ck_doc_context(doc, &ctx))
            continue;
        line_start = ck_indent_line_start(ctx.buf, ctx.len, ctx.point);
        column     = ck_indent_for_line(ctx.buf, ctx.len, line_start);
        ck_context_free(&ctx);

        if (column >= 0)
            ck_reindent_line(doc, y, column);
    }
    set(doc->text, MUIA_TextEditor_Quiet, FALSE);

    ck_message(doc, "Indented %ld line(s)", (long)(y1 - y0 + 1));
}

static void ck_cmd_eval_last_sexp(ck_doc *doc)
{
    ck_context ctx;
    int32_t    start, stop = -1;

    if (!ck_doc_context_full(doc, &ctx)) {
        ck_beep(doc);
        return;
    }
    start = ck_sexp_last_sexp(ctx.buf, ctx.len, ctx.point, &stop);
    if (start < 0 || stop < 0) {
        ck_context_free(&ctx);
        ck_message(doc, "No expression before point");
        ck_beep(doc);
        return;
    }
    start += ctx.base;
    stop  += ctx.base;
    ck_context_free(&ctx);

    ck_doc_eval_region(doc, start, stop);
}

static void ck_cmd_eval_defun(ck_doc *doc)
{
    ck_context ctx;
    int32_t    start, stop;

    if (!ck_doc_context_full(doc, &ctx)) {
        ck_beep(doc);
        return;
    }
    start = ck_sexp_defun_start(ctx.buf, ctx.len, ctx.point);
    if (start < 0)
        start = 0;
    stop = ck_sexp_forward(ctx.buf, ctx.len, start);
    if (stop < 0) {
        ck_context_free(&ctx);
        ck_message(doc, "Unbalanced expression");
        ck_beep(doc);
        return;
    }
    start += ctx.base;
    stop  += ctx.base;
    ck_context_free(&ctx);

    ck_doc_eval_region(doc, start, stop);
}

void ck_doc_run_command(ck_doc *doc, int16_t command, int32_t arg)
{
    ck_app *app = doc->app;

    /* In the REPL window the transcript is read-only; repl.c decides. */
    if (doc->repl_mode && !ck_repl_allow_command(doc, command)) {
        doc->last_command = command;
        ck_doc_update_status(doc);
        return;
    }

    switch (command) {
    /* --- motion, delegated to the class ------------------------- */
    case CK_CMD_FORWARD_CHAR:       ck_te_repeat(doc, arg < 0 ? "CURSOR LEFT" : "CURSOR RIGHT", arg); break;
    case CK_CMD_BACKWARD_CHAR:      ck_te_repeat(doc, arg < 0 ? "CURSOR RIGHT" : "CURSOR LEFT", arg); break;
    case CK_CMD_NEXT_LINE:          ck_te_repeat(doc, arg < 0 ? "CURSOR UP" : "CURSOR DOWN", arg); break;
    case CK_CMD_PREVIOUS_LINE:      ck_te_repeat(doc, arg < 0 ? "CURSOR DOWN" : "CURSOR UP", arg); break;
    case CK_CMD_BEGINNING_OF_LINE:  ck_te(doc, "POSITION SOL"); break;
    case CK_CMD_END_OF_LINE:        ck_te(doc, "POSITION EOL"); break;
    case CK_CMD_FORWARD_WORD:       ck_te_repeat(doc, "NEXT WORD", arg); break;
    case CK_CMD_BACKWARD_WORD:      ck_te_repeat(doc, "PREVIOUS WORD", arg); break;
    case CK_CMD_BEGINNING_OF_BUFFER:ck_te(doc, "POSITION SOF"); break;
    case CK_CMD_END_OF_BUFFER:      ck_te(doc, "POSITION EOF"); break;
    case CK_CMD_SCROLL_UP:          ck_te_repeat(doc, "NEXT PAGE", arg); break;
    case CK_CMD_SCROLL_DOWN:        ck_te_repeat(doc, "PREVIOUS PAGE", arg); break;
    case CK_CMD_RECENTER:           ck_doc_colour_all(doc); break;

    case CK_CMD_DELETE_CHAR:        ck_te_repeat(doc, "DELETE", arg); break;
    case CK_CMD_BACKWARD_DELETE_CHAR: ck_te_repeat(doc, "BACKSPACE", arg); break;
    case CK_CMD_UNDO:               ck_te(doc, "UNDO"); break;
    case CK_CMD_REDO:               ck_te(doc, "REDO"); break;
    case CK_CMD_MARK_WHOLE_BUFFER:  ck_te(doc, "SELECTALL"); break;

    case CK_CMD_KILL_WORD: {
        int32_t start = ck_doc_cursor_index(doc);
        int32_t stop;
        STRPTR  text;
        ck_te_repeat(doc, "NEXT WORD", arg);
        stop = ck_doc_cursor_index(doc);
        ck_doc_set_cursor_index(doc, start);
        text = ck_take_region(doc, start, stop, 1);
        if (text != NULL) {
            ck_kill_text(doc, (const char *)text, 0);
            FreeVec(text);
        }
        break;
    }

    case CK_CMD_BACKWARD_KILL_WORD: {
        int32_t stop = ck_doc_cursor_index(doc);
        int32_t start;
        STRPTR  text;
        ck_te_repeat(doc, "PREVIOUS WORD", arg);
        start = ck_doc_cursor_index(doc);
        text  = ck_take_region(doc, start, stop, 1);
        if (text != NULL) {
            ck_kill_text(doc, (const char *)text, 1);
            FreeVec(text);
        }
        break;
    }

    case CK_CMD_KILL_LINE:      ck_cmd_kill_line(doc, arg); break;
    case CK_CMD_KILL_REGION:    ck_cmd_region(doc, 1, 1); break;
    case CK_CMD_KILL_RING_SAVE: ck_cmd_region(doc, 0, 1); break;
    case CK_CMD_YANK:           ck_cmd_yank(doc, 0); break;
    case CK_CMD_YANK_POP:       ck_cmd_yank(doc, 1); break;

    case CK_CMD_SET_MARK_COMMAND:
        doc->mark = ck_doc_cursor_index(doc);
        ck_message(doc, "Mark set");
        break;

    case CK_CMD_EXCHANGE_POINT_AND_MARK: {
        int32_t point = ck_doc_cursor_index(doc);
        if (doc->mark < 0) {
            ck_message(doc, "No mark set in this buffer");
            ck_beep(doc);
            break;
        }
        ck_doc_set_cursor_index(doc, doc->mark);
        doc->mark = point;
        break;
    }

    /* --- search -------------------------------------------------- */
    case CK_CMD_ISEARCH_FORWARD:
    case CK_CMD_ISEARCH_BACKWARD:
        doc->mini_state     = CK_MINI_ISEARCH;
        doc->isearch_anchor = ck_doc_cursor_index(doc);
        doc->isearch_back   = (command == CK_CMD_ISEARCH_BACKWARD);
        doc->mini_source    = CK_COMPLETE_NONE;
        doc->mini_command   = command;
        ck_mini_open(doc, doc->isearch_back ? "Reverse I-search: " : "I-search: ", "");
        break;

    /* --- files and buffers --------------------------------------- */
    case CK_CMD_FIND_FILE:
    case CK_CMD_FIND_FILE_OTHER_WINDOW:
    case CK_CMD_LOAD_FILE:
        ck_doc_prompt(doc, "Find file: ", "", command, CK_COMPLETE_FILE, arg);
        break;

    case CK_CMD_SAVE_BUFFER:
        if (doc->path[0] == '\0') {
            ck_doc_prompt(doc, "Write file: ", "", CK_CMD_WRITE_FILE,
                          CK_COMPLETE_FILE, arg);
            break;
        }
        if (ck_doc_save_file(doc, doc->path))
            ck_message(doc, "Wrote %s", doc->path);
        else
            ck_message(doc, "Cannot write %s", doc->path);
        break;

    case CK_CMD_WRITE_FILE:
        ck_doc_prompt(doc, "Write file: ", doc->path, CK_CMD_WRITE_FILE,
                      CK_COMPLETE_FILE, arg);
        break;

    case CK_CMD_KILL_BUFFER:
        ck_doc_close(doc, 1);
        break;

    case CK_CMD_SWITCH_TO_BUFFER:
    case CK_CMD_OTHER_WINDOW: {
        ck_doc *next = (doc->next != NULL) ? doc->next : app->docs;
        if (next != NULL && next != doc)
            set(next->win, MUIA_Window_Activate, TRUE);
        break;
    }

    case CK_CMD_SAVE_BUFFERS_KILL_EMACS:
        /* Stop clamiga's REPL thread on the way out; ck_rexx_close() waits
         * for that one reply. */
        ck_repl_quit(app);
        app->quitting = 1;
        DoMethod(app->app, MUIM_Application_ReturnID,
                 (IPTR)MUIV_Application_ReturnID_Quit);
        break;

    case CK_CMD_GOTO_LINE:
        ck_doc_prompt(doc, "Goto line: ", "", CK_CMD_GOTO_LINE,
                      CK_COMPLETE_NONE, arg);
        break;

    /* --- the command loop ---------------------------------------- */
    case CK_CMD_EXECUTE_EXTENDED_COMMAND:
        ck_doc_prompt(doc, "M-x ", "", CK_CMD_EXECUTE_EXTENDED_COMMAND,
                      CK_COMPLETE_COMMAND, arg);
        break;

    case CK_CMD_KEYBOARD_QUIT:
        doc->mark = -1;
        ck_te(doc, "SELECTNONE");
        ck_message(doc, "Quit");
        break;

    /* --- Lisp structure ------------------------------------------ */
    case CK_CMD_FORWARD_SEXP:
    case CK_CMD_BACKWARD_SEXP:
    case CK_CMD_BACKWARD_UP_LIST:
    case CK_CMD_DOWN_LIST:
    case CK_CMD_BEGINNING_OF_DEFUN:
    case CK_CMD_END_OF_DEFUN:
        ck_cmd_sexp_move(doc, command, arg);
        break;

    case CK_CMD_KILL_SEXP:
        ck_cmd_kill_sexp(doc);
        break;

    case CK_CMD_INSERT_PARENTHESES:
        DoMethod(doc->text, MUIM_TextEditor_InsertText, (IPTR)"()",
                 (IPTR)MUIV_TextEditor_InsertText_Cursor);
        ck_te(doc, "CURSOR LEFT");
        break;

    case CK_CMD_INDENT_FOR_TAB_COMMAND:
        ck_cmd_indent_line(doc);
        break;

    case CK_CMD_NEWLINE_AND_INDENT:
        ck_cmd_newline_and_indent(doc);
        break;

    case CK_CMD_INDENT_REGION:
        ck_cmd_indent_region(doc);
        break;

    /* --- clamiga -------------------------------------------------- */
    case CK_CMD_LOAD_BUFFER:
        ck_doc_save_and_load(doc);
        break;

    case CK_CMD_COMPILE_FILE:
        if (doc->path[0] == '\0') {
            ck_message(doc, "Save the buffer to a file first");
            ck_beep(doc);
            break;
        }
        ck_diag_clear(&app->diags);
        ck_rexx_send(app, doc, CK_REQ_COMPILE_FILE, "COMPILE-FILE %s", doc->path);
        break;

    case CK_CMD_EVAL_DEFUN:
        ck_cmd_eval_defun(doc);
        break;

    case CK_CMD_EVAL_LAST_SEXP:
        ck_cmd_eval_last_sexp(doc);
        break;

    case CK_CMD_EVAL_REGION: {
        int32_t point = ck_doc_cursor_index(doc);
        if (doc->mark < 0) {
            ck_message(doc, "No mark set in this buffer");
            ck_beep(doc);
            break;
        }
        ck_doc_eval_region(doc,
                           (doc->mark < point) ? doc->mark : point,
                           (doc->mark < point) ? point : doc->mark);
        break;
    }

    case CK_CMD_EVAL_EXPRESSION:
        ck_doc_prompt(doc, "Eval: ", "", CK_CMD_EVAL_EXPRESSION,
                      CK_COMPLETE_NONE, arg);
        break;

    case CK_CMD_CONNECT:
        if (ck_rexx_find_port(app))
            ck_rexx_send(app, doc, CK_REQ_VERSION, "VERSION");
        else
            ck_message(doc, "No clamiga port found");
        break;

    case CK_CMD_RUN_LISP:
        if (ck_rexx_launch(app))
            ck_message(doc, "Started clamiga");
        else
            ck_message(doc, "Cannot start clamiga");
        break;

    case CK_CMD_SHOW_ERRORS:
        ck_errorwin_fill(app);
        if (app->errorwin != NULL)
            set(app->errorwin, MUIA_Window_Open, TRUE);
        break;

    /* `C-x `' walks the diagnostics from the keyboard, and it shares both
     * the position and the jump with the error list -- clicking a row and
     * pressing the key are two ways into one place, not two features. */
    case CK_CMD_NEXT_ERROR:
    case CK_CMD_PREVIOUS_ERROR: {
        int32_t row = ck_errorwin_current(app);
        int32_t step = (command == CK_CMD_NEXT_ERROR) ? 1 : -1;

        if (app->diags.count == 0) {
            ck_message(doc, "No diagnostics");
            ck_beep(doc);
            break;
        }
        row += step;
        if (row < 0 || row >= app->diags.count) {
            ck_message(doc, "%s diagnostic",
                       (step > 0) ? "No further" : "No previous");
            ck_beep(doc);
            break;
        }
        ck_errorwin_jump(app, row);
        if (app->errorlist != NULL)
            set(app->errorlist, MUIA_List_Active, (IPTR)row);
        break;
    }

    /* --- introspection (phase 2), see introspect.c ---------------- */
    case CK_CMD_COMPLETE_SYMBOL:  ck_intro_complete(doc); break;
    case CK_CMD_ARGLIST:          ck_intro_arglist(doc, 1); break;
    case CK_CMD_EDIT_DEFINITION:  ck_intro_edit_definition(doc); break;
    case CK_CMD_POP_DEFINITION:   ck_intro_pop_definition(doc); break;
    case CK_CMD_DESCRIBE_SYMBOL:  ck_intro_describe(doc); break;
    case CK_CMD_APROPOS:          ck_intro_apropos(doc); break;
    case CK_CMD_MACROEXPAND_1:    ck_intro_macroexpand(doc, 0); break;
    case CK_CMD_MACROEXPAND:      ck_intro_macroexpand(doc, 1); break;

    /* --- the REPL window (phase 3), see repl.c ------------------- */
    case CK_CMD_REPL:                ck_repl_switch(doc); break;
    case CK_CMD_INTERRUPT:           ck_repl_interrupt(doc); break;
    case CK_CMD_REPL_RETURN:
    case CK_CMD_REPL_PREVIOUS_INPUT:
    case CK_CMD_REPL_NEXT_INPUT:
    case CK_CMD_REPL_CLEAR:
        if (!doc->repl_mode) {
            ck_message(doc, "Not in the REPL window (C-c C-z goes there)");
            ck_beep(doc);
            break;
        }
        if (command == CK_CMD_REPL_RETURN)
            ck_repl_return(doc);
        else if (command == CK_CMD_REPL_CLEAR)
            ck_repl_clear(doc);
        else
            ck_repl_history(doc, command == CK_CMD_REPL_PREVIOUS_INPUT);
        break;

    default:
        ck_message(doc, "%s is not implemented yet",
                   ck_command_name(command) != NULL
                       ? ck_command_name(command) : "that command");
        ck_beep(doc);
        break;
    }

    doc->last_command = command;
    ck_doc_update_status(doc);
}

/* ------------------------------------------------------------------ *
 * The minibuffer answer
 * ------------------------------------------------------------------ */

void ck_doc_minibuffer_done(ck_doc *doc)
{
    char        answer[CK_MINI_MAX];
    const char *text;
    int16_t     command;

    if (doc->mini_state == CK_MINI_IDLE)
        return;

    if (doc->mini_state == CK_MINI_ISEARCH) {
        ck_mini_finish(doc);
        ck_message(doc, "Mark set");
        doc->mark = doc->isearch_anchor;
        return;
    }

    text = (const char *)ck_get(doc->mini, MUIA_String_Contents);
    strncpy(answer, text != NULL ? text : "", sizeof answer - 1);
    answer[sizeof answer - 1] = '\0';

    command = doc->mini_command;
    if (doc->mini_source != CK_COMPLETE_NONE)
        ck_hist_add(ck_doc_history(doc), answer);
    ck_mini_finish(doc);

    switch (command) {
    case CK_CMD_EXECUTE_EXTENDED_COMMAND: {
        int16_t cmd = ck_command_lookup(answer);
        if (cmd == CK_CMD_NONE) {
            ck_message(doc, "[No match]");
            ck_beep(doc);
            break;
        }
        ck_doc_run_command(doc, cmd, 1);
        break;
    }

    case CK_CMD_FIND_FILE:
    case CK_CMD_FIND_FILE_OTHER_WINDOW: {
        char path[CK_PATH_MAX];
        if (answer[0] == '\0') {
            /* An empty answer means "show me": the ASL requester behind
             * C-x C-f, as the spec asks for. */
            if (!ck_ask_file(doc, "Find file", 0, path, (int32_t)sizeof path))
                break;
        } else {
            strncpy(path, answer, sizeof path - 1);
            path[sizeof path - 1] = '\0';
        }
        if (command == CK_CMD_FIND_FILE && doc->path[0] == '\0' &&
            !ck_get(doc->text, MUIA_TextEditor_HasChanged)) {
            if (ck_doc_load_file(doc, path))
                ck_doc_colour_all(doc);
            else
                ck_message(doc, "Cannot open %s", path);
        } else if (ck_doc_new(doc->app, path) == NULL) {
            ck_message(doc, "Cannot open %s", path);
        }
        break;
    }

    case CK_CMD_WRITE_FILE: {
        char path[CK_PATH_MAX];
        if (answer[0] == '\0') {
            if (!ck_ask_file(doc, "Write file", 1, path, (int32_t)sizeof path))
                break;
        } else {
            strncpy(path, answer, sizeof path - 1);
            path[sizeof path - 1] = '\0';
        }
        if (ck_doc_save_file(doc, path))
            ck_message(doc, "Wrote %s", path);
        else
            ck_message(doc, "Cannot write %s", path);
        break;
    }

    case CK_CMD_LOAD_FILE:
        if (answer[0] != '\0') {
            ck_diag_clear(&doc->app->diags);
            ck_rexx_send(doc->app, doc, CK_REQ_LOAD, "LOAD %s", answer);
        }
        break;

    case CK_CMD_EVAL_EXPRESSION:
        if (answer[0] != '\0')
            ck_doc_eval(doc, answer);
        break;

    case CK_CMD_GOTO_LINE: {
        long line = 0;
        if (answer[0] != '\0' && sscanf(answer, "%ld", &line) == 1 && line > 0)
            set(doc->text, MUIA_TextEditor_CursorY, (IPTR)(line - 1));
        break;
    }

    /* introspection (phase 2) */
    case CK_CMD_COMPLETE_SYMBOL: ck_intro_complete_done(doc, answer); break;
    case CK_CMD_EDIT_DEFINITION: ck_intro_edit_definition_named(doc, answer); break;
    case CK_CMD_DESCRIBE_SYMBOL: ck_intro_describe_named(doc, answer); break;
    case CK_CMD_APROPOS:         ck_intro_apropos_named(doc, answer); break;

    default:
        break;
    }

    ck_doc_update_status(doc);
}

/* ------------------------------------------------------------------ *
 * Key entry
 * ------------------------------------------------------------------ */

int32_t ck_doc_handle_key(ck_doc *doc, ck_key key)
{
    int16_t      cmd = CK_CMD_NONE;
    ck_keyresult r;
    char         seq[64];

    r = ck_keystate_feed(&doc->keys, key, &cmd);

    switch (r) {
    case CK_KEY_COMMAND:
        ck_doc_run_command(doc, cmd, ck_keystate_take_arg(&doc->keys));
        return 1;

    case CK_KEY_PREFIX:
    case CK_KEY_ARG:
        ck_keystate_describe(&doc->keys, seq, (int32_t)sizeof seq);
        ck_message(doc, "%s", seq);
        return 1;

    case CK_KEY_UNDEFINED:
        ck_keystate_describe(&doc->keys, seq, (int32_t)sizeof seq);
        ck_message(doc, "%sis undefined", seq);
        ck_beep(doc);
        return 1;

    case CK_KEY_CANCEL:
        ck_message(doc, "Quit");
        return 1;

    case CK_KEY_UNBOUND:
    default:
        /* Not ours.  The class gets the key, and ordinary typing clears
         * whatever the echo area was showing.  In the REPL window a key
         * that would edit the transcript is redirected or swallowed. */
        doc->last_command = CK_CMD_NONE;
        if (doc->repl_mode && ck_repl_unbound_key(doc, key))
            return 1;
        return 0;
    }
}

/* ------------------------------------------------------------------ *
 * Notification hooks
 * ------------------------------------------------------------------ */

HOOKPROTONHNO(ck_mini_ack_func, void, ULONG *params)
{
    ck_doc_minibuffer_done((ck_doc *)params[0]);
}
MakeStaticHook(ck_mini_ack_hook, ck_mini_ack_func);

HOOKPROTONHNO(ck_mini_changed_func, void, ULONG *params)
{
    ck_doc *doc = (ck_doc *)params[0];
    if (doc->mini_state == CK_MINI_ISEARCH) {
        const char *pattern = (const char *)ck_get(doc->mini, MUIA_String_Contents);
        ck_doc_set_cursor_index(doc, doc->isearch_anchor);
        ck_isearch_step(doc, pattern, 0);
    }
}
MakeStaticHook(ck_mini_changed_hook, ck_mini_changed_func);

HOOKPROTONHNO(ck_cursor_func, void, ULONG *params)
{
    ck_doc *doc = (ck_doc *)params[0];
    ck_doc_update_status(doc);
    ck_doc_show_paren(doc);
}
MakeStaticHook(ck_cursor_hook, ck_cursor_func);

HOOKPROTONHNO(ck_changed_func, void, ULONG *params)
{
    ck_doc *doc = (ck_doc *)params[0];
    doc->edit_serial++;
    ck_doc_colour_line(doc, (int32_t)ck_get(doc->text, MUIA_TextEditor_CursorY));
    ck_doc_update_status(doc);
}
MakeStaticHook(ck_changed_hook, ck_changed_func);

HOOKPROTONHNO(ck_close_func, void, ULONG *params)
{
    ck_doc_close((ck_doc *)params[0], 1);
}
MakeStaticHook(ck_close_hook, ck_close_func);

/* ------------------------------------------------------------------ *
 * Creation and destruction
 * ------------------------------------------------------------------ */

static int32_t ck_looks_like_lisp(const char *path)
{
    int32_t n = (int32_t)strlen(path);

    if (n >= 5 && strcmp(path + n - 5, ".lisp") == 0) return 1;
    if (n >= 4 && strcmp(path + n - 4, ".lsp")  == 0) return 1;
    if (n >= 4 && strcmp(path + n - 4, ".cl")   == 0) return 1;
    if (n >= 4 && strcmp(path + n - 4, ".asd")  == 0) return 1;
    return 0;
}

ck_doc *ck_doc_new(ck_app *app, const char *path)
{
    ck_doc *doc = (ck_doc *)AllocVec(sizeof(ck_doc), MEMF_ANY | MEMF_CLEAR);

    if (doc == NULL)
        return NULL;

    doc->app     = app;
    doc->id      = app->next_id++;
    doc->mark    = -1;
    doc->paren_x = -1;
    doc->paren_y = -1;
    doc->last_command = CK_CMD_NONE;
    doc->mini_command = CK_CMD_NONE;
    doc->arglist_index = -1;
    doc->idle_index    = -1;
    ck_strlist_init(&doc->completions);
    strcpy(doc->name, "(unnamed)");
    doc->lisp_mode = (path != NULL) ? ck_looks_like_lisp(path) : 1;

    ck_keystate_init(&doc->keys, app->global, doc->lisp_mode ? app->lisp : NULL);

    doc->win = WindowObject,
        MUIA_Window_Title,  (IPTR)"clamacs",
        MUIA_Window_ID,     MAKE_ID('C','L','M','A'),
        WindowContents, VGroup,
            Child, HGroup,
                MUIA_Group_Spacing, 0,
                Child, doc->text = NewObject(app->textclass->mcc_Class, NULL,
                    MUIA_CycleChain,               TRUE,
                    MUIA_TextEditor_FixedFont,     TRUE,
                    MUIA_TextEditor_UndoLevels,    200,
                    MUIA_TextEditor_WrapMode,      MUIV_TextEditor_WrapMode_NoWrap,
                    /* NoStyle, not Plain: the Plain export hook writes
                     * \033P[...] colour escapes into the exported text,
                     * which would desynchronise every byte offset from
                     * MUIA_TextEditor_CursorIndex and put escape sequences
                     * into saved files. */
                    MUIA_TextEditor_ExportHook,    MUIV_TextEditor_ExportHook_NoStyle,
                    MUIA_TextEditor_ImportHook,    MUIV_TextEditor_ImportHook_Plain,
                    CKA_Doc,                       (IPTR)doc,
                TAG_DONE),
                Child, doc->slider = ScrollbarObject,
                End,
            End,
            Child, doc->status = TextObject,
                MUIA_Text_Contents, (IPTR)"",
                MUIA_Text_SetMin,   FALSE,
                MUIA_Frame,         MUIV_Frame_Text,
            End,
            /* The echo area: a message line, or the prompt beside the
             * minibuffer input, one at a time (see the ck_doc fields). */
            /* A page switch repaints only what the new page's objects
             * cover, so both Text objects are let grow to the row's full
             * height (SetVMax FALSE) and the row has no spacing: else the
             * hidden page's frame stays on screen around them. */
            Child, doc->echo = PageGroup,
                Child, doc->msgline = TextObject,
                    MUIA_Text_Contents, (IPTR)"",
                    MUIA_Text_SetMin,   FALSE,
                    MUIA_Text_SetVMax,  FALSE,
                End,
                Child, doc->miniline = HGroup,
                    MUIA_Group_Spacing, 0,
                    /* Sized to its text and given no share of the spare
                     * width, so the input gets everything the prompt does
                     * not need; ck_doc_set_label() relays the row when the
                     * text changes. */
                    Child, doc->prompt = TextObject,
                        MUIA_Text_Contents, (IPTR)"",
                        MUIA_Text_SetMin,   TRUE,
                        MUIA_Text_SetVMax,  FALSE,
                        MUIA_Weight,        0,
                    End,
                    Child, doc->mini = NewObject(app->miniclass->mcc_Class, NULL,
                        MUIA_Frame,        MUIV_Frame_String,
                        MUIA_String_MaxLen, CK_MINI_MAX,
                        MUIA_CycleChain,   TRUE,
                        CKA_Doc,           (IPTR)doc,
                    TAG_DONE),
                End,
            End,
        End,
    End;

    if (doc->win == NULL) {
        FreeVec(doc);
        return NULL;
    }

    set(doc->text, MUIA_TextEditor_Slider, (IPTR)doc->slider);

    DoMethod(app->app, OM_ADDMEMBER, (IPTR)doc->win);

    DoMethod(doc->win, MUIM_Notify, MUIA_Window_CloseRequest, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook, (IPTR)&ck_close_hook,
             (IPTR)doc);
    DoMethod(doc->mini, MUIM_Notify, MUIA_String_Acknowledge, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook, (IPTR)&ck_mini_ack_hook,
             (IPTR)doc);
    DoMethod(doc->mini, MUIM_Notify, MUIA_String_Contents, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook,
             (IPTR)&ck_mini_changed_hook, (IPTR)doc);
    DoMethod(doc->text, MUIM_Notify, MUIA_TextEditor_CursorY, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook, (IPTR)&ck_cursor_hook,
             (IPTR)doc);
    DoMethod(doc->text, MUIM_Notify, MUIA_TextEditor_CursorX, MUIV_EveryTime,
             MUIV_Notify_Application, 3, MUIM_CallHook, (IPTR)&ck_cursor_hook,
             (IPTR)doc);
    DoMethod(doc->text, MUIM_Notify, MUIA_TextEditor_ContentsChanged, TRUE,
             MUIV_Notify_Application, 3, MUIM_CallHook, (IPTR)&ck_changed_hook,
             (IPTR)doc);

    doc->next = app->docs;
    app->docs = doc;

    if (path != NULL && path[0] != '\0') {
        if (!ck_doc_load_file(doc, path)) {
            /* A file that does not exist yet is a new buffer with a name,
             * exactly as in Emacs. */
            strncpy(doc->path, path, sizeof doc->path - 1);
            doc->path[sizeof doc->path - 1] = '\0';
            ck_basename(doc->path, doc->name, (int32_t)sizeof doc->name);
            set(doc->win, MUIA_Window_Title, (IPTR)doc->name);
        }
    }

    set(doc->win, MUIA_Window_Open, TRUE);
    set(doc->win, MUIA_Window_ActiveObject, (IPTR)doc->text);

    ck_doc_track_package(doc);
    ck_doc_colour_all(doc);
    ck_doc_update_status(doc);
    return doc;
}

void ck_doc_close(ck_doc *doc, int32_t ask)
{
    ck_app *app = doc->app;

    if (doc->closing)
        return;

    /* A transcript is not a file: the REPL window never asks to save, and
     * closing it stops clamiga's REPL thread. */
    if (doc->repl_mode)
        ck_repl_closed(doc);

    if (ask && !doc->repl_mode && ck_get(doc->text, MUIA_TextEditor_HasChanged)) {
        /* MUI_Request answers 1 for the first gadget, 2 for the second and 0
         * for the rightmost (the cancel position). */
        LONG answer = MUI_Request(app->app, doc->win, 0, "clamacs",
                                  "_Save|_Discard|_Cancel",
                                  "%s has unsaved changes.", doc->name);
        if (answer == 0)
            return;
        if (answer == 1) {
            if (doc->path[0] == '\0') {
                ck_doc_prompt(doc, "Write file: ", "", CK_CMD_WRITE_FILE,
                              CK_COMPLETE_FILE, 1);
                return;
            }
            if (!ck_doc_save_file(doc, doc->path)) {
                ck_message(doc, "Cannot write %s", doc->path);
                return;
            }
        }
    }

    /* Queued work for a window that is going away has nowhere to land; the
     * message already on the wire is left alone, because its reply is coming
     * either way and cancelling it would break the one-in-flight rule. */
    ck_queue_drop_cookie(&app->queue, doc->id);

    /* Retire the window now, dispose of it later.  This is reached from a
     * notification hook and, for `C-x k', from inside the MUIM_HandleEvent
     * of the text object that is about to be freed -- destroying it here
     * would pull the ground out from under the caller. */
    set(doc->win, MUIA_Window_Open, FALSE);
    doc->closing = 1;
}

void ck_app_reap(ck_app *app)
{
    ck_doc **link = &app->docs;
    int32_t  alive = 0;

    while (*link != NULL) {
        ck_doc *doc = *link;
        if (doc->closing) {
            *link = doc->next;
            DoMethod(app->app, OM_REMMEMBER, (IPTR)doc->win);
            MUI_DisposeObject(doc->win);
            ck_strlist_clear(&doc->completions);
            FreeVec(doc);
        } else {
            alive++;
            link = &doc->next;
        }
    }

    if (alive == 0 && !app->quitting) {
        app->quitting = 1;
        DoMethod(app->app, MUIM_Application_ReturnID,
                 (IPTR)MUIV_Application_ReturnID_Quit);
    }
}

ck_doc *ck_doc_find_by_path(ck_app *app, const char *path)
{
    ck_doc *doc;

    for (doc = app->docs; doc != NULL; doc = doc->next) {
        if (!doc->closing && Stricmp((STRPTR)doc->path, (STRPTR)path) == 0)
            return doc;
    }
    return NULL;
}

ck_doc *ck_doc_active(ck_app *app)
{
    ck_doc *doc;

    for (doc = app->docs; doc != NULL; doc = doc->next) {
        if (!doc->closing && ck_get(doc->win, MUIA_Window_Activate))
            return doc;
    }
    for (doc = app->docs; doc != NULL; doc = doc->next) {
        if (!doc->closing)
            return doc;
    }
    return NULL;
}
