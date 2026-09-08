/*
 * token.h -- the Lisp colouring tokenizer.
 *
 * Line-oriented and incremental, because that is what redisplay needs: after
 * an edit only the changed line is re-tokenized and recoloured with
 * MUIM_TextEditor_SetBlock.  A construct that spans lines (a string, a
 * `#| |#' comment) leaves its state in a ck_tok_state, and the caller
 * re-tokenizes forward until the state at the end of a line matches what it
 * was before the edit -- at which point the rest of the buffer is unchanged.
 *
 * Separate from sexp.c on purpose.  The sexp scanner answers structural
 * questions over a whole buffer; this answers "what colour is byte N of this
 * one line", and it must be able to start in the middle of a string.
 *
 * Pure C: no MUI, no OS types.  The mapping from ck_tok_kind to a
 * TextEditor colour index lives in the MUI layer.
 */

#ifndef CLAMACS_TOKEN_H
#define CLAMACS_TOKEN_H

#include <stdint.h>

typedef enum {
    CK_TOK_SYMBOL = 0,
    CK_TOK_PAREN,
    CK_TOK_COMMENT,
    CK_TOK_STRING,
    CK_TOK_CHAR,      /* #\a, #\Space */
    CK_TOK_KEYWORD,   /* :foo */
    CK_TOK_NUMBER,
    CK_TOK_DEFINING   /* the head of a defining form: defun, defclass, ... */
} ck_tok_kind;

/* Carried from one line to the next. */
typedef enum {
    CK_TOK_IN_CODE = 0,
    CK_TOK_IN_STRING,
    CK_TOK_IN_BLOCK_COMMENT
} ck_tok_where;

typedef struct {
    uint8_t where;  /* ck_tok_where */
    uint8_t depth;  /* #| |# nesting */
    uint8_t head;   /* the next atom is in head position (an open paren was
                     * the last thing seen), so `defun' colours as a
                     * defining form even when the paren was on the line
                     * before */
} ck_tok_state;

typedef struct {
    uint16_t start;  /* byte offset within the line */
    uint16_t len;
    uint8_t  kind;   /* ck_tok_kind */
} ck_token;

void ck_tok_state_init(ck_tok_state *state);
int32_t ck_tok_state_equal(const ck_tok_state *a, const ck_tok_state *b);

/* Tokenize one line (without its newline).  Writes the first MAX tokens to
 * OUT (which may be NULL) and returns the TOTAL number the line has, so a
 * caller can tell that it truncated.  The whole line is always scanned, so
 * *STATE is correct even when the tokens did not fit. */
int32_t ck_tokenize_line(const char *line, int32_t len, ck_tok_state *state,
                         ck_token *out, int32_t max);

/* Whether TEXT (LEN bytes) reads as a Common Lisp number.  Exposed because
 * it is the one piece of the tokenizer with interesting edge cases -- `1+'
 * and `-' are symbols, `1/2' and `1.0d0' are not. */
int32_t ck_tok_is_number(const char *text, int32_t len);

/* Whether TEXT names a defining form (defun, defmacro, defclass, ...).
 * Case insensitive. */
int32_t ck_tok_is_defining(const char *text, int32_t len);

#endif /* CLAMACS_TOKEN_H */
