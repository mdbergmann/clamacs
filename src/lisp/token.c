/*
 * token.c -- see token.h.
 */

#include "token.h"

#include <string.h>

static int32_t tk_is_space(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\f';
}

static int32_t tk_is_terminating(char c)
{
    return tk_is_space(c) || c == '\n' || c == '(' || c == ')' || c == '[' ||
           c == ']' || c == '"' || c == ';' || c == '\'' || c == '`' || c == ',';
}

static char tk_lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

void ck_tok_state_init(ck_tok_state *state)
{
    state->where = CK_TOK_IN_CODE;
    state->depth = 0;
    state->head  = 0;
}

int32_t ck_tok_state_equal(const ck_tok_state *a, const ck_tok_state *b)
{
    return a->where == b->where && a->depth == b->depth && a->head == b->head;
}

/* ------------------------------------------------------------------ *
 * Numbers
 * ------------------------------------------------------------------ */

static int32_t tk_digits(const char *t, int32_t len, int32_t *i, int32_t radix)
{
    int32_t n = 0;
    while (*i < len) {
        char c = tk_lower(t[*i]);
        int32_t v;
        if (c >= '0' && c <= '9')      v = c - '0';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 10;
        else break;
        if (v >= radix)
            break;
        (*i)++;
        n++;
    }
    return n;
}

int32_t ck_tok_is_number(const char *text, int32_t len)
{
    int32_t i = 0, radix = 10, intdigits, fracdigits;

    if (text == NULL || len <= 0)
        return 0;

    /* #x1f, #b1010, #o17, #16rFF */
    if (text[0] == '#' && len >= 2) {
        char c = tk_lower(text[1]);
        i = 2;
        if      (c == 'x') radix = 16;
        else if (c == 'b') radix = 2;
        else if (c == 'o') radix = 8;
        else if (c >= '0' && c <= '9') {
            int32_t r = 0;
            i = 1;
            while (i < len && text[i] >= '0' && text[i] <= '9')
                r = r * 10 + (text[i++] - '0');
            if (i >= len || tk_lower(text[i]) != 'r' || r < 2 || r > 36)
                return 0;
            i++;
            radix = r;
        } else {
            return 0;
        }
        if (i < len && (text[i] == '+' || text[i] == '-'))
            i++;
        if (tk_digits(text, len, &i, radix) == 0)
            return 0;
        if (i < len && text[i] == '/') {
            i++;
            if (tk_digits(text, len, &i, radix) == 0)
                return 0;
        }
        return i == len;
    }

    if (i < len && (text[i] == '+' || text[i] == '-'))
        i++;

    intdigits = tk_digits(text, len, &i, 10);

    /* A ratio: 1/2 */
    if (intdigits > 0 && i < len && text[i] == '/') {
        i++;
        if (tk_digits(text, len, &i, 10) == 0)
            return 0;
        return i == len;
    }

    /* An integer written with a trailing dot: 10. */
    if (intdigits > 0 && i == len - 1 && text[i] == '.')
        return 1;

    fracdigits = 0;
    if (i < len && text[i] == '.') {
        i++;
        fracdigits = tk_digits(text, len, &i, 10);
    }

    if (intdigits == 0 && fracdigits == 0)
        return 0;   /* `-', `.', `+' and friends are symbols */

    /* An exponent marker: 1e10, 1.0d0, 1s-3 */
    if (i < len) {
        char c = tk_lower(text[i]);
        if (c == 'e' || c == 's' || c == 'f' || c == 'd' || c == 'l') {
            i++;
            if (i < len && (text[i] == '+' || text[i] == '-'))
                i++;
            if (tk_digits(text, len, &i, 10) == 0)
                return 0;
        }
    }

    return i == len;
}

/* ------------------------------------------------------------------ *
 * Defining forms
 * ------------------------------------------------------------------ */

static const char *const tk_defining[] = {
    "defclass", "defconstant", "defgeneric", "define-compiler-macro",
    "define-condition", "define-method-combination", "define-modify-macro",
    "define-setf-expander", "define-symbol-macro", "defmacro", "defmethod",
    "defpackage", "defparameter", "defsetf", "defstruct", "defsubst",
    "deftype", "defun", "defvar",
    NULL
};

static int32_t tk_equal_ci(const char *text, int32_t len, const char *word)
{
    int32_t i;
    for (i = 0; i < len; i++) {
        if (word[i] == '\0' || tk_lower(text[i]) != word[i])
            return 0;
    }
    return word[len] == '\0';
}

int32_t ck_tok_is_defining(const char *text, int32_t len)
{
    int32_t i;

    if (text == NULL || len <= 0)
        return 0;
    for (i = 0; tk_defining[i] != NULL; i++) {
        if (tk_equal_ci(text, len, tk_defining[i]))
            return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * The line tokenizer
 * ------------------------------------------------------------------ */

static void tk_emit(ck_token *out, int32_t max, int32_t *n,
                    int32_t start, int32_t end, uint8_t kind)
{
    if (out != NULL && *n < max) {
        out[*n].start = (uint16_t)start;
        out[*n].len   = (uint16_t)(end - start);
        out[*n].kind  = kind;
    }
    (*n)++;
}

int32_t ck_tokenize_line(const char *line, int32_t len, ck_tok_state *state,
                         ck_token *out, int32_t max)
{
    int32_t written = 0;
    int32_t i = 0;

    if (line == NULL || len < 0 || state == NULL)
        return 0;

    /* Finish a construct the previous line left open before anything else:
     * the first bytes of this line belong to it, not to a new token. */
    if (state->where == CK_TOK_IN_STRING) {
        int32_t start = 0;
        while (i < len) {
            if (line[i] == '\\') { i += 2; continue; }
            if (line[i] == '"')  { i++; state->where = CK_TOK_IN_CODE; break; }
            i++;
        }
        if (i > len)
            i = len;
        tk_emit(out, max, &written, start, i, CK_TOK_STRING);
        if (state->where == CK_TOK_IN_CODE)
            state->head = 0;
    } else if (state->where == CK_TOK_IN_BLOCK_COMMENT) {
        int32_t start = 0;
        while (i < len) {
            if (i + 1 < len && line[i] == '#' && line[i + 1] == '|') {
                if (state->depth < 255)
                    state->depth++;
                i += 2;
                continue;
            }
            if (i + 1 < len && line[i] == '|' && line[i + 1] == '#') {
                i += 2;
                if (state->depth > 0)
                    state->depth--;
                if (state->depth == 0) {
                    state->where = CK_TOK_IN_CODE;
                    break;
                }
                continue;
            }
            i++;
        }
        tk_emit(out, max, &written, start, i, CK_TOK_COMMENT);
    }

    while (i < len) {
        int32_t start;
        char    c;

        while (i < len && tk_is_space(line[i]))
            i++;
        if (i >= len)
            break;

        start = i;
        c     = line[i];

        if (c == ';') {
            i = len;
            tk_emit(out, max, &written, start, i, CK_TOK_COMMENT);
            continue;
        }

        if (c == '#' && i + 1 < len && line[i + 1] == '|') {
            state->where = CK_TOK_IN_BLOCK_COMMENT;
            state->depth = 1;
            i += 2;
            while (i < len) {
                if (i + 1 < len && line[i] == '#' && line[i + 1] == '|') {
                    if (state->depth < 255)
                        state->depth++;
                    i += 2;
                    continue;
                }
                if (i + 1 < len && line[i] == '|' && line[i + 1] == '#') {
                    i += 2;
                    state->depth--;
                    if (state->depth == 0) {
                        state->where = CK_TOK_IN_CODE;
                        break;
                    }
                    continue;
                }
                i++;
            }
            tk_emit(out, max, &written, start, i, CK_TOK_COMMENT);
            continue;
        }

        if (c == '#' && i + 1 < len && line[i + 1] == '\\') {
            i += 2;
            if (i < len)
                i++;
            while (i < len && !tk_is_terminating(line[i]))
                i++;
            tk_emit(out, max, &written, start, i, CK_TOK_CHAR);
            state->head = 0;
            continue;
        }

        if (c == '"') {
            i++;
            state->where = CK_TOK_IN_STRING;
            while (i < len) {
                if (line[i] == '\\') { i += 2; continue; }
                if (line[i] == '"')  { i++; state->where = CK_TOK_IN_CODE; break; }
                i++;
            }
            if (i > len)
                i = len;
            tk_emit(out, max, &written, start, i, CK_TOK_STRING);
            state->head = 0;
            continue;
        }

        if (c == '(' || c == '[') {
            i++;
            tk_emit(out, max, &written, start, i, CK_TOK_PAREN);
            state->head = 1;
            continue;
        }

        if (c == ')' || c == ']') {
            i++;
            tk_emit(out, max, &written, start, i, CK_TOK_PAREN);
            state->head = 0;
            continue;
        }

        if (c == '\'' || c == '`' || c == ',' || c == '#') {
            /* A prefix character: it does not itself end head position, so
             * `(#'foo ...)' still sees foo as the head. */
            i++;
            if (c == ',' && i < len && line[i] == '@')
                i++;
            tk_emit(out, max, &written, start, i, CK_TOK_SYMBOL);
            continue;
        }

        /* An atom. */
        while (i < len) {
            char d = line[i];
            if (d == '|') {
                i++;
                while (i < len && line[i] != '|') {
                    if (line[i] == '\\')
                        i++;
                    i++;
                }
                if (i < len)
                    i++;
                continue;
            }
            if (d == '\\') { i += 2; continue; }
            if (tk_is_terminating(d))
                break;
            i++;
        }
        if (i > len)
            i = len;
        if (i == start)
            i++;   /* never fail to advance */

        {
            int32_t n    = i - start;
            uint8_t kind = CK_TOK_SYMBOL;
            if (line[start] == ':')
                kind = CK_TOK_KEYWORD;
            else if (ck_tok_is_number(line + start, n))
                kind = CK_TOK_NUMBER;
            else if (state->head && ck_tok_is_defining(line + start, n))
                kind = CK_TOK_DEFINING;
            tk_emit(out, max, &written, start, i, kind);
        }
        state->head = 0;
    }

    return written;
}
