/*
 * indent.c -- see indent.h.
 */

#include "indent.h"
#include "sexp.h"

#include <string.h>

#define CK_IND_MAX_DEPTH 128
#define CK_IND_BODY      2   /* body forms, past the distinguished arguments */
#define CK_IND_DISTINCT  4   /* the distinguished arguments themselves */

struct ck_indent_rule {
    const char *name;
    int32_t     args;
};

/*
 * Distinguished-argument counts.  `defun' is 2 (name and lambda list), `let'
 * is 1 (the bindings), `when' is 1 (the test); everything after those is
 * body.  `loop' is deliberately absent: the default rule aligns its clauses
 * under the first one, which is what `(loop for x in xs\n      collect x)'
 * wants and what a fixed number could not express.
 */
static const struct ck_indent_rule ck_indent_rules[] = {
    { "block",                     1 },
    { "case",                      1 },
    { "catch",                     1 },
    { "ccase",                     1 },
    { "cond",                      0 },
    { "ctypecase",                 1 },
    { "defclass",                  2 },
    { "defconstant",               1 },
    { "define-compiler-macro",     2 },
    { "define-condition",          2 },
    { "define-modify-macro",       1 },
    { "define-setf-expander",      2 },
    { "define-symbol-macro",       1 },
    { "defgeneric",                2 },
    { "defmacro",                  2 },
    { "defmethod",                 2 },
    { "defpackage",                1 },
    { "defparameter",              1 },
    { "defsetf",                   2 },
    { "defstruct",                 1 },
    { "defsubst",                  2 },
    { "deftype",                   2 },
    { "defun",                     2 },
    { "defvar",                    1 },
    { "destructuring-bind",        2 },
    { "do",                        2 },
    { "do*",                       2 },
    { "dolist",                    1 },
    { "dotimes",                   1 },
    { "ecase",                     1 },
    { "etypecase",                 1 },
    { "eval-when",                 1 },
    { "flet",                      1 },
    { "handler-bind",              1 },
    { "handler-case",              1 },
    { "if",                        2 },
    { "labels",                    1 },
    { "lambda",                    1 },
    { "let",                       1 },
    { "let*",                      1 },
    { "locally",                   0 },
    { "loop-finish",               0 },
    { "macrolet",                  1 },
    { "multiple-value-bind",       2 },
    { "prog1",                     1 },
    { "prog2",                     2 },
    { "progn",                     0 },
    { "restart-bind",              1 },
    { "restart-case",              1 },
    { "symbol-macrolet",           1 },
    { "tagbody",                   0 },
    { "typecase",                  1 },
    { "unless",                    1 },
    { "unwind-protect",            1 },
    { "when",                      1 },
    { "with-accessors",            2 },
    { "with-input-from-string",    1 },
    { "with-open-file",            1 },
    { "with-open-stream",          1 },
    { "with-output-to-string",     1 },
    { "with-slots",                2 },
    { "with-standard-io-syntax",   0 },
    { NULL,                        0 }
};

static char ind_lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

static int32_t ind_equal_ci(const char *text, int32_t len, const char *word)
{
    int32_t i;
    for (i = 0; i < len; i++) {
        if (word[i] == '\0' || ind_lower(text[i]) != word[i])
            return 0;
    }
    return word[len] == '\0';
}

int32_t ck_indent_body_args(const char *name, int32_t namelen)
{
    int32_t i, start = 0;

    if (name == NULL || namelen <= 0)
        return -1;

    /* Ignore a package prefix: `cl:when' indents like `when'.  The last
     * colon wins, so `cl-user::foo' works too. */
    for (i = 0; i < namelen; i++) {
        if (name[i] == ':')
            start = i + 1;
    }
    name    += start;
    namelen -= start;
    if (namelen <= 0)
        return -1;

    for (i = 0; ck_indent_rules[i].name != NULL; i++) {
        if (ind_equal_ci(name, namelen, ck_indent_rules[i].name))
            return ck_indent_rules[i].args;
    }

    /* An unknown `def...' is almost always a defining macro whose first two
     * arguments name the thing being defined.  Guessing 2 here is what makes
     * a project's own `define-foo' indent sensibly before phase 2 can ask
     * clamiga for its real &body position. */
    if (namelen > 3 && ind_lower(name[0]) == 'd' && ind_lower(name[1]) == 'e' &&
        ind_lower(name[2]) == 'f')
        return 2;

    return -1;
}

int32_t ck_indent_line_start(const char *buf, int32_t len, int32_t offset)
{
    int32_t i;

    if (buf == NULL || offset <= 0)
        return 0;
    if (offset > len)
        offset = len;
    for (i = offset - 1; i >= 0; i--) {
        if (buf[i] == '\n')
            return i + 1;
    }
    return 0;
}

int32_t ck_indent_column_of(const char *buf, int32_t len, int32_t offset)
{
    return offset - ck_indent_line_start(buf, len, offset);
}

static int32_t ind_same_line(const char *buf, int32_t from, int32_t to)
{
    int32_t i;
    for (i = from; i < to; i++) {
        if (buf[i] == '\n')
            return 0;
    }
    return 1;
}

typedef struct {
    int32_t open;         /* offset of the '(' */
    int32_t nforms;       /* complete forms seen inside, head included */
    int32_t head_start;
    int32_t head_end;
    int32_t head_is_list;
    int32_t arg1_start;   /* start of the second form, or -1 */
    int32_t pending;      /* start of a form introduced by prefix characters */
} ck_ind_frame;

static void ind_complete_form(ck_ind_frame *f, int32_t start, int32_t end,
                              int32_t is_list)
{
    if (f->nforms == 0) {
        f->head_start   = start;
        f->head_end     = end;
        f->head_is_list = is_list;
    } else if (f->nforms == 1) {
        f->arg1_start = start;
    }
    f->nforms++;
}

int32_t ck_indent_for_line(const char *buf, int32_t len, int32_t line_start)
{
    ck_sx_token   t;
    int32_t       p = 0;
    int32_t       depth = 0;
    ck_ind_frame  stack[CK_IND_MAX_DEPTH + 1];
    ck_ind_frame *f;
    int32_t       arg_index, rule;

    if (buf == NULL || len < 0 || line_start < 0 || line_start > len)
        return -1;

    memset(&stack[0], 0, sizeof(stack[0]));
    stack[0].pending    = -1;
    stack[0].arg1_start = -1;

    while (ck_sx_next(buf, len, &p, &t) != CK_SX_EOF) {
        if (t.start >= line_start)
            break;

        if (t.end > line_start) {
            /* The token straddles the start of the line.  Inside a string
             * the line's leading bytes ARE the string, so reindenting would
             * silently edit data; inside a block comment there is nothing to
             * align to.  Either way, hands off. */
            if (t.kind == CK_SX_STRING || t.kind == CK_SX_COMMENT)
                return -1;
            break;
        }

        if (t.kind == CK_SX_COMMENT)
            continue;

        f = &stack[depth];

        switch (t.kind) {
        case CK_SX_QUOTE:
            if (f->pending < 0)
                f->pending = t.start;
            break;

        case CK_SX_ATOM:
        case CK_SX_STRING:
            ind_complete_form(f, (f->pending >= 0) ? f->pending : t.start,
                              t.end, 0);
            f->pending = -1;
            break;

        case CK_SX_OPEN:
            if (depth >= CK_IND_MAX_DEPTH)
                return -1;
            depth++;
            memset(&stack[depth], 0, sizeof(stack[depth]));
            stack[depth].open       = (f->pending >= 0) ? f->pending : t.start;
            stack[depth].pending    = -1;
            stack[depth].arg1_start = -1;
            f->pending              = -1;
            break;

        case CK_SX_CLOSE:
            if (depth > 0) {
                int32_t opened = stack[depth].open;
                depth--;
                ind_complete_form(&stack[depth], opened, t.end, 1);
                stack[depth].pending = -1;
            }
            break;

        default:
            break;
        }
    }

    if (depth == 0)
        return 0;   /* top level */

    f = &stack[depth];

    /* Nothing after the open paren yet: `(\n   foo)'. */
    if (f->nforms == 0)
        return ck_indent_column_of(buf, len, f->open) + 1;

    /* The head is itself a list, so this is data or `((lambda ...) x)': line
     * the elements up one past the paren. */
    if (f->head_is_list)
        return ck_indent_column_of(buf, len, f->open) + 1;

    arg_index = f->nforms - 1;   /* the head is form 0 */
    rule      = ck_indent_body_args(buf + f->head_start,
                                    f->head_end - f->head_start);

    if (rule >= 0) {
        int32_t base = ck_indent_column_of(buf, len, f->open);
        return base + ((arg_index < rule) ? CK_IND_DISTINCT : CK_IND_BODY);
    }

    /* Unknown operator: align under the first argument when there is one on
     * the operator's own line, otherwise one past the paren. */
    if (f->arg1_start >= 0 && ind_same_line(buf, f->head_start, f->arg1_start))
        return ck_indent_column_of(buf, len, f->arg1_start);

    return ck_indent_column_of(buf, len, f->open) + 1;
}
