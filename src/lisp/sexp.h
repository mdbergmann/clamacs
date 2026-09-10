/*
 * sexp.h -- the s-expression scanner.
 *
 * Operates on a flat byte buffer, because that is what the text area can
 * give us: TextEditor.mcc has no line-access API, so structural editing
 * works on text exported with MUIM_TextEditor_ExportBlock over a range of
 * full lines (specs/clamacs-ide.md, "Text access").
 *
 * CONTRACT: offset 0 of BUF must be outside any string and any comment.  The
 * MUI layer guarantees that by exporting from a defun start -- a `(' in
 * column 0 -- or from the start of the buffer.  Every function here scans
 * from 0, so a buffer that violates the contract gives wrong answers rather
 * than crashing.
 *
 * All offsets are byte offsets into BUF.  Every navigation function returns
 * -1 when the move is not possible, which is what a command turns into a
 * beep and a message rather than a wrong cursor position.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_SEXP_H
#define CLAMACS_SEXP_H

#include <stdint.h>

/* Token kinds produced by the low-level walker.  Exposed because the
 * indenter walks the same stream. */
typedef enum {
    CK_SX_EOF = 0,
    CK_SX_OPEN,     /* ( or [ */
    CK_SX_CLOSE,    /* ) or ] */
    CK_SX_ATOM,     /* symbol, number, character literal */
    CK_SX_STRING,   /* "..." */
    CK_SX_QUOTE,    /* ' ` , ,@ #' #( and other # dispatch prefixes */
    CK_SX_COMMENT   /* ; to end of line, or #| ... |# */
} ck_sx_kind;

typedef struct {
    int32_t start;  /* first byte */
    int32_t end;    /* one past the last byte */
    uint8_t kind;   /* ck_sx_kind */
} ck_sx_token;

/* Read the token at or after *POS, advancing *POS past it.  Returns CK_SX_EOF
 * at the end of the buffer.  Whitespace is skipped; comments are RETURNED
 * rather than skipped, so a caller can tell "inside a comment" from "between
 * forms". */
uint8_t ck_sx_next(const char *buf, int32_t len, int32_t *pos, ck_sx_token *tok);

/* What kind of text POS sits in. */
typedef enum {
    CK_CTX_CODE = 0,
    CK_CTX_STRING,
    CK_CTX_COMMENT
} ck_sx_context;

int32_t ck_sexp_context(const char *buf, int32_t len, int32_t pos);

/* Navigation.  POS is the cursor; the return value is where the cursor
 * should end up, or -1. */
int32_t ck_sexp_forward(const char *buf, int32_t len, int32_t pos);
int32_t ck_sexp_backward(const char *buf, int32_t len, int32_t pos);

/* backward-up-list: the enclosing open paren.  down-list: just inside the
 * next open paren. */
int32_t ck_sexp_up(const char *buf, int32_t len, int32_t pos);
int32_t ck_sexp_down(const char *buf, int32_t len, int32_t pos);

/* The `(' in column 0 at or before POS, and the position just past the form
 * it opens.  These are what `C-M-a' / `C-M-e' move to, and what bounds the
 * text `C-c C-c' sends to clamiga. */
int32_t ck_sexp_defun_start(const char *buf, int32_t len, int32_t pos);
int32_t ck_sexp_defun_end(const char *buf, int32_t len, int32_t pos);

/* The partner of the paren at POS (either direction), or -1 when POS is not
 * on a paren or the parens do not balance.  Drives the paren highlight. */
int32_t ck_sexp_match_paren(const char *buf, int32_t len, int32_t pos);

/* Bounds of the sexp that ENDS at or immediately before POS -- what
 * `C-x C-e' sends.  Returns the start offset, or -1; *END receives one past
 * the last byte. */
int32_t ck_sexp_last_sexp(const char *buf, int32_t len, int32_t pos, int32_t *end);

/* The package named by the nearest (in-package ...) at or before POS, copied
 * into OUT.  Returns 1 when one was found, 0 otherwise.  The status line
 * shows it and every eval carries it. */
int32_t ck_sexp_current_package(const char *buf, int32_t len, int32_t pos,
                                char *out, int32_t out_size);

/* ------------------------------------------------------------------ *
 * Phase 2: what to ask clamiga about
 * ------------------------------------------------------------------ */

/* The operator whose arglist the status line should show: the head symbol
 * of the innermost list enclosing POS that is CODE.  Bounds go to *START and
 * *END; returns 1 when there is one.
 *
 * Lists that are data are transparent -- `(member x '(a b|))' answers
 * MEMBER, not A -- which is decided by the prefix in front of the open
 * paren: `'', `` ` '' and `#' make data, `,' and `,@' make code again inside
 * a backquote, and `#'' is a function, so `#'(lambda ...)' answers LAMBDA.
 * A head that cannot name an operator (a number, a keyword, a character, a
 * nested list) leaves the list without one.  While POS sits INSIDE the head
 * atom the user is still typing it, and nothing is answered rather than a
 * request per keystroke. */
int32_t ck_sexp_operator_at_point(const char *buf, int32_t len, int32_t pos,
                                  int32_t *start, int32_t *end);

/* The symbol under or just before POS, by the rule Emacs's `symbol-at-point'
 * uses: the run of symbol characters containing POS, or the one ending at it.
 * Character-based rather than token-based on purpose, so it also answers
 * inside a comment or a string, where `M-.' is still useful.  Returns 1 and
 * the bounds, or 0. */
int32_t ck_sexp_symbol_at_point(const char *buf, int32_t len, int32_t pos,
                                int32_t *start, int32_t *end);

#endif /* CLAMACS_SEXP_H */
