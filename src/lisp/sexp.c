/*
 * sexp.c -- see sexp.h.
 *
 * Everything here is built on one low-level walker, ck_sx_next, and every
 * public function is a single left-to-right pass over it starting at offset
 * 0.  That is deliberate: a backwards scanner cannot tell a `;' that starts
 * a comment from a `;' inside a string without reading forward anyway, and a
 * defun-sized buffer is small enough that one pass costs nothing even on a
 * 68020.  It also means there is exactly one place where Lisp lexical rules
 * live, so `#\(' and "a ) in a string" cannot be right in one function and
 * wrong in the next.
 */

#include "sexp.h"

#include <string.h>

#define CK_SX_MAX_DEPTH 128

static int32_t sx_is_space(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

static int32_t sx_is_terminating(char c)
{
    return sx_is_space(c) || c == '(' || c == ')' || c == '[' || c == ']' ||
           c == '"' || c == ';' || c == '\'' || c == '`' || c == ',';
}

static int32_t sx_is_constituent(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '-';
}

uint8_t ck_sx_next(const char *buf, int32_t len, int32_t *pos, ck_sx_token *tok)
{
    int32_t p = *pos;
    char    c;

    if (p < 0)
        p = 0;
    while (p < len && sx_is_space(buf[p]))
        p++;

    tok->start = p;
    if (p >= len) {
        tok->end  = len;
        tok->kind = CK_SX_EOF;
        *pos      = len;
        return CK_SX_EOF;
    }

    c = buf[p];

    if (c == ';') {
        while (p < len && buf[p] != '\n')
            p++;
        tok->kind = CK_SX_COMMENT;
    } else if (c == '#' && p + 1 < len && buf[p + 1] == '|') {
        int32_t depth = 0;
        while (p < len) {
            if (p + 1 < len && buf[p] == '#' && buf[p + 1] == '|') {
                depth++;
                p += 2;
                continue;
            }
            if (p + 1 < len && buf[p] == '|' && buf[p + 1] == '#') {
                depth--;
                p += 2;
                if (depth == 0)
                    break;
                continue;
            }
            p++;
        }
        tok->kind = CK_SX_COMMENT;
    } else if (c == '#' && p + 1 < len && buf[p + 1] == '\\') {
        /* A character literal.  Handled before the general `#' case because
         * `#\(' and `#\;' must not be read as a paren or a comment. */
        p += 2;
        if (p < len)
            p++;
        while (p < len && sx_is_constituent(buf[p]))
            p++;
        tok->kind = CK_SX_ATOM;
    } else if (c == '"') {
        p++;
        while (p < len) {
            if (buf[p] == '\\') {
                p += 2;
                continue;
            }
            if (buf[p] == '"') {
                p++;
                break;
            }
            p++;
        }
        if (p > len)
            p = len;
        tok->kind = CK_SX_STRING;
    } else if (c == '(' || c == '[') {
        p++;
        tok->kind = CK_SX_OPEN;
    } else if (c == ')' || c == ']') {
        p++;
        tok->kind = CK_SX_CLOSE;
    } else if (c == '\'' || c == '`') {
        p++;
        tok->kind = CK_SX_QUOTE;
    } else if (c == ',') {
        p++;
        if (p < len && buf[p] == '@')
            p++;
        tok->kind = CK_SX_QUOTE;
    } else if (c == '#') {
        /* Any other dispatch macro: #', #(, #x10, #p"...".  One byte of
         * prefix, then the form that follows -- which is what makes
         * forward-sexp treat `#(1 2 3)' as a single form. */
        p++;
        tok->kind = CK_SX_QUOTE;
    } else {
        while (p < len) {
            char d = buf[p];
            if (d == '|') {           /* |symbol with spaces| */
                p++;
                while (p < len && buf[p] != '|') {
                    if (buf[p] == '\\')
                        p++;
                    p++;
                }
                if (p < len)
                    p++;
                continue;
            }
            if (d == '\\') {
                p += 2;
                continue;
            }
            if (sx_is_terminating(d))
                break;
            p++;
        }
        if (p > len)
            p = len;
        if (p == tok->start)          /* a lone terminating byte we do not
                                       * otherwise handle: never loop on it */
            p++;
        tok->kind = CK_SX_ATOM;
    }

    tok->end = p;
    *pos     = p;
    return tok->kind;
}

int32_t ck_sexp_context(const char *buf, int32_t len, int32_t pos)
{
    int32_t     p = 0;
    ck_sx_token t;

    if (pos <= 0 || pos > len)
        return CK_CTX_CODE;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.start >= pos)
            break;
        if (t.end > pos) {
            if (t.kind == CK_SX_STRING)
                return CK_CTX_STRING;
            if (t.kind == CK_SX_COMMENT)
                return CK_CTX_COMMENT;
            return CK_CTX_CODE;
        }
    }
    return CK_CTX_CODE;
}

/* The first token that is relevant to a forward move from POS: the token
 * containing POS, or the first one starting at or after it.  Comments are
 * skipped.  Returns 0 when there is none. */
static int32_t sx_token_at(const char *buf, int32_t len, int32_t pos,
                           int32_t *scan, ck_sx_token *tok)
{
    int32_t p = 0;

    while (ck_sx_next(buf, len, &p, tok) != CK_SX_EOF) {
        if (tok->kind == CK_SX_COMMENT)
            continue;
        if (tok->end <= pos)
            continue;
        *scan = p;
        return 1;
    }
    return 0;
}

int32_t ck_sexp_forward(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth;

    if (buf == NULL || len <= 0)
        return -1;
    if (pos < 0)
        pos = 0;

    if (!sx_token_at(buf, len, pos, &p, &t))
        return -1;

    /* Inside an atom or a string: move to its end, as Emacs does. */
    if (t.start < pos) {
        if (t.kind == CK_SX_ATOM || t.kind == CK_SX_STRING)
            return t.end;
        return -1;
    }

    /* Skip any prefix characters; the form they introduce is the one we
     * move over. */
    while (t.kind == CK_SX_QUOTE || t.kind == CK_SX_COMMENT) {
        if (ck_sx_next(buf, len, &p, &t) == CK_SX_EOF)
            return -1;
    }

    switch (t.kind) {
    case CK_SX_ATOM:
    case CK_SX_STRING:
        return t.end;

    case CK_SX_CLOSE:
        return -1;

    case CK_SX_OPEN:
        depth = 1;
        while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
            if (t.kind == CK_SX_OPEN) {
                depth++;
                if (depth > CK_SX_MAX_DEPTH)
                    return -1;
            } else if (t.kind == CK_SX_CLOSE) {
                depth--;
                if (depth == 0)
                    return t.end;
            }
        }
        return -1;   /* unbalanced */

    default:
        return -1;
    }
}

int32_t ck_sexp_backward(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth = 0;
    int32_t     pending[CK_SX_MAX_DEPTH + 1];
    int32_t     last[CK_SX_MAX_DEPTH + 1];
    int32_t     form_open[CK_SX_MAX_DEPTH + 1];

    if (buf == NULL || len <= 0 || pos <= 0)
        return -1;
    if (pos > len)
        pos = len;

    pending[0] = -1;
    last[0]    = -1;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_COMMENT)
            continue;
        if (t.start >= pos)
            break;

        if (t.end > pos) {
            /* POS sits inside this token.  For an atom or a string that is
             * the form we are standing in, so its start is the answer. */
            if (t.kind == CK_SX_ATOM || t.kind == CK_SX_STRING)
                return (pending[depth] >= 0) ? pending[depth] : t.start;
            break;
        }

        switch (t.kind) {
        case CK_SX_QUOTE:
            if (pending[depth] < 0)
                pending[depth] = t.start;
            break;

        case CK_SX_ATOM:
        case CK_SX_STRING:
            last[depth]    = (pending[depth] >= 0) ? pending[depth] : t.start;
            pending[depth] = -1;
            break;

        case CK_SX_OPEN:
            if (depth >= CK_SX_MAX_DEPTH)
                return -1;
            form_open[depth + 1] =
                (pending[depth] >= 0) ? pending[depth] : t.start;
            pending[depth] = -1;
            depth++;
            pending[depth] = -1;
            last[depth]    = -1;
            break;

        case CK_SX_CLOSE:
            if (depth > 0) {
                depth--;
                last[depth]    = form_open[depth + 1];
                pending[depth] = -1;
            }
            break;

        default:
            break;
        }
    }

    return last[depth];
}

int32_t ck_sexp_up(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth = 0;
    int32_t     open_at[CK_SX_MAX_DEPTH + 1];

    if (buf == NULL || len <= 0 || pos <= 0)
        return -1;
    if (pos > len)
        pos = len;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_COMMENT)
            continue;
        if (t.start >= pos)
            break;
        if (t.end > pos)
            break;   /* inside an atom or string: the enclosing list stands */

        if (t.kind == CK_SX_OPEN) {
            if (depth >= CK_SX_MAX_DEPTH)
                return -1;
            depth++;
            open_at[depth] = t.start;
        } else if (t.kind == CK_SX_CLOSE) {
            if (depth > 0)
                depth--;
        }
    }

    return (depth > 0) ? open_at[depth] : -1;
}

int32_t ck_sexp_down(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;

    if (buf == NULL || len <= 0)
        return -1;
    if (pos < 0)
        pos = 0;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_COMMENT)
            continue;
        if (t.start < pos)
            continue;
        if (t.kind == CK_SX_OPEN)
            return t.end;      /* just inside the paren */
        if (t.kind == CK_SX_CLOSE)
            return -1;         /* left the list before finding one */
    }
    return -1;
}

int32_t ck_sexp_defun_start(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     found = -1;

    if (buf == NULL || len <= 0)
        return -1;
    if (pos < 0)
        pos = 0;
    if (pos > len)
        pos = len;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.start > pos)
            break;
        if (t.kind != CK_SX_OPEN)
            continue;
        /* Column 0 is what makes a defun a defun for navigation purposes --
         * the same convention Emacs uses, and the reason the MUI layer can
         * export a window of lines and trust offset 0 to be clean. */
        if (t.start == 0 || buf[t.start - 1] == '\n')
            found = t.start;
    }
    return found;
}

int32_t ck_sexp_defun_end(const char *buf, int32_t len, int32_t pos)
{
    int32_t start = ck_sexp_defun_start(buf, len, pos);

    if (start < 0)
        return -1;
    return ck_sexp_forward(buf, len, start);
}

int32_t ck_sexp_match_paren(const char *buf, int32_t len, int32_t pos)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth = 0;
    int32_t     open_at[CK_SX_MAX_DEPTH + 1];
    char        c;

    if (buf == NULL || pos < 0 || pos >= len)
        return -1;

    c = buf[pos];
    if (c != '(' && c != ')' && c != '[' && c != ']')
        return -1;
    if (ck_sexp_context(buf, len, pos) != CK_CTX_CODE)
        return -1;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_OPEN) {
            if (depth >= CK_SX_MAX_DEPTH)
                return -1;
            depth++;
            open_at[depth] = t.start;
            if (t.start == pos) {
                /* Forward from here to the matching close. */
                int32_t want = depth;
                while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
                    if (t.kind == CK_SX_OPEN) {
                        depth++;
                        if (depth > CK_SX_MAX_DEPTH)
                            return -1;
                    } else if (t.kind == CK_SX_CLOSE) {
                        depth--;
                        if (depth < want)
                            return t.start;
                    }
                }
                return -1;
            }
        } else if (t.kind == CK_SX_CLOSE) {
            if (t.start == pos)
                return (depth > 0) ? open_at[depth] : -1;
            if (depth > 0)
                depth--;
        }
    }
    return -1;
}

int32_t ck_sexp_last_sexp(const char *buf, int32_t len, int32_t pos, int32_t *end)
{
    int32_t start = ck_sexp_backward(buf, len, pos);
    int32_t stop;

    if (end != NULL)
        *end = -1;
    if (start < 0)
        return -1;
    stop = ck_sexp_forward(buf, len, start);
    if (stop < 0)
        return -1;
    if (end != NULL)
        *end = stop;
    return start;
}

int32_t ck_sexp_current_package(const char *buf, int32_t len, int32_t pos,
                                char *out, int32_t out_size)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth = 0;
    int32_t     state = 0;      /* 0 idle, 1 saw top-level open, 2 saw in-package */
    int32_t     form_ok = 0;
    int32_t     found = 0;

    if (out != NULL && out_size > 0)
        out[0] = '\0';
    if (buf == NULL || len <= 0 || out == NULL || out_size <= 1)
        return 0;
    if (pos > len)
        pos = len;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_COMMENT)
            continue;

        if (t.kind == CK_SX_OPEN) {
            depth++;
            if (depth == 1) {
                state = 1;
                /* Strictly before: with point at the very start of the
                 * buffer no package is in effect yet, and the form sitting
                 * at offset 0 has not been read. */
                form_ok = (t.start < pos);
            }
            continue;
        }
        if (t.kind == CK_SX_CLOSE) {
            if (depth > 0)
                depth--;
            if (depth == 0)
                state = 0;
            continue;
        }

        if (state == 1 && depth == 1 && t.kind == CK_SX_ATOM) {
            int32_t n = t.end - t.start;
            if (n == 10) {
                int32_t i, same = 1;
                static const char *word = "in-package";
                for (i = 0; i < 10; i++) {
                    char a = buf[t.start + i];
                    if (a >= 'A' && a <= 'Z')
                        a = (char)(a - 'A' + 'a');
                    if (a != word[i]) { same = 0; break; }
                }
                state = same ? 2 : 0;
            } else {
                state = 0;
            }
            continue;
        }

        if (state == 2 && depth == 1 &&
            (t.kind == CK_SX_ATOM || t.kind == CK_SX_STRING)) {
            if (form_ok) {
                int32_t s = t.start, e = t.end, n;
                /* Strip the spellings a package designator comes in:
                 * "FOO", :foo, #:foo, foo. */
                if (buf[s] == '"' && e - s >= 2) { s++; e--; }
                if (e - s >= 2 && buf[s] == '#' && buf[s + 1] == ':') s += 2;
                else if (e - s >= 1 && buf[s] == ':') s += 1;
                n = e - s;
                if (n > out_size - 1)
                    n = out_size - 1;
                if (n > 0) {
                    memcpy(out, buf + s, (size_t)n);
                    out[n] = '\0';
                    found  = 1;
                }
            }
            state = 0;
            continue;
        }

        /* `#:foo' reaches here as QUOTE `#' then ATOM `:foo', so a prefix
         * must not abandon the form -- only something genuinely unexpected. */
        if (state == 2 && t.kind != CK_SX_QUOTE)
            state = 0;
    }

    return found;
}

/* ------------------------------------------------------------------ *
 * Phase 2: what to ask clamiga about
 * ------------------------------------------------------------------ */

/* Whether the atom at [S,E) could name an operator.  Numbers, keywords and
 * character literals cannot, and asking clamiga about `1' or `:key' would
 * only fill the arglist cache with misses. */
static int32_t sx_operator_like(const char *buf, int32_t s, int32_t e)
{
    char c = buf[s];

    if (e <= s)
        return 0;
    if (c >= '0' && c <= '9')
        return 0;
    if (c == '#' || c == ':')
        return 0;
    if ((c == '+' || c == '-' || c == '.') && e - s > 1 &&
        buf[s + 1] >= '0' && buf[s + 1] <= '9')
        return 0;
    return 1;
}

int32_t ck_sexp_operator_at_point(const char *buf, int32_t len, int32_t pos,
                                  int32_t *start, int32_t *end)
{
    ck_sx_token t;
    int32_t     p = 0;
    int32_t     depth = 0;
    int32_t     head_start[CK_SX_MAX_DEPTH + 1];
    int32_t     head_end[CK_SX_MAX_DEPTH + 1];
    uint8_t     data[CK_SX_MAX_DEPTH + 1];       /* the list is quoted data */
    uint8_t     want_head[CK_SX_MAX_DEPTH + 1];  /* the next atom is the head */
    char        prefix[2];
    int32_t     prefix_len = 0;
    int32_t     prefix_end = -1;   /* where the prefix run ends; the open
                                    * paren it applies to starts there */

    if (buf == NULL || len <= 0 || pos < 0)
        return 0;
    if (pos > len)
        pos = len;

    data[0]       = 0;
    want_head[0]  = 0;
    head_start[0] = -1;
    head_end[0]   = -1;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.kind == CK_SX_COMMENT)
            continue;
        if (t.start >= pos)
            break;
        if (t.end > pos) {
            /* POS is inside this token.  Inside the head atom the operator
             * is still being typed. */
            if (t.kind == CK_SX_ATOM && depth > 0 && want_head[depth])
                return 0;
            break;
        }

        if (t.kind == CK_SX_QUOTE) {
            if (prefix_end != t.start)
                prefix_len = 0;
            if (prefix_len < 2)
                prefix[prefix_len++] = buf[t.start];
            prefix_end = t.end;
            continue;
        }

        switch (t.kind) {
        case CK_SX_OPEN: {
            uint8_t is_data;

            if (depth >= CK_SX_MAX_DEPTH)
                return 0;
            if (prefix_end == t.start && prefix_len > 0) {
                if (prefix[0] == ',')
                    is_data = 0;
                else if (prefix_len == 2 && prefix[0] == '#' && prefix[1] == '\'')
                    is_data = 0;
                else
                    is_data = 1;
            } else {
                is_data = data[depth];
            }
            /* A list in head position -- ((lambda ...) x) -- takes the
             * slot: the atoms after it are arguments, not the operator. */
            if (depth > 0)
                want_head[depth] = 0;
            depth++;
            data[depth]       = is_data;
            want_head[depth]  = 1;
            head_start[depth] = -1;
            head_end[depth]   = -1;
            break;
        }

        case CK_SX_CLOSE:
            if (depth > 0)
                depth--;
            break;

        case CK_SX_ATOM:
            if (depth > 0 && want_head[depth]) {
                if (!data[depth] && sx_operator_like(buf, t.start, t.end)) {
                    head_start[depth] = t.start;
                    head_end[depth]   = t.end;
                }
                want_head[depth] = 0;
            }
            break;

        case CK_SX_STRING:
            if (depth > 0)
                want_head[depth] = 0;
            break;

        default:
            break;
        }

        prefix_len = 0;
        prefix_end = -1;
    }

    /* The innermost enclosing list that has an operator. */
    while (depth > 0) {
        if (head_start[depth] >= 0) {
            if (start != NULL)
                *start = head_start[depth];
            if (end != NULL)
                *end = head_end[depth];
            return 1;
        }
        depth--;
    }
    return 0;
}

static int32_t sx_is_symbol_char(char c)
{
    return c != '\0' && !sx_is_terminating(c);
}

int32_t ck_sexp_symbol_at_point(const char *buf, int32_t len, int32_t pos,
                                int32_t *start, int32_t *end)
{
    int32_t s, e;

    if (buf == NULL || len <= 0 || pos < 0 || pos > len)
        return 0;

    if (pos < len && sx_is_symbol_char(buf[pos]))
        s = pos;
    else if (pos > 0 && sx_is_symbol_char(buf[pos - 1]))
        s = pos - 1;
    else
        return 0;

    while (s > 0 && sx_is_symbol_char(buf[s - 1]))
        s--;
    e = s;
    while (e < len && sx_is_symbol_char(buf[e]))
        e++;

    if (start != NULL)
        *start = s;
    if (end != NULL)
        *end = e;
    return 1;
}
