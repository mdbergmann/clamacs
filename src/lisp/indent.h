/*
 * indent.h -- Lisp indentation.
 *
 * The rules follow SLIME's cl-indent: a table maps an operator to the number
 * of DISTINGUISHED arguments it takes.  Those arguments indent four columns
 * past the open paren; everything after them -- the body -- indents two.  An
 * operator that is not in the table aligns its arguments under the first
 * one, or one column past the paren when it stands alone on its line.  That
 * one rule, plus the table, covers `defun', `let', `when', `handler-case'
 * and `(foo bar\n     baz)' alike.
 *
 * The table is data, so phase 2 can extend it with &body positions asked
 * from clamiga rather than guessed here.
 *
 * Pure C: no MUI, no OS types.  Same buffer contract as sexp.h -- offset 0
 * must be outside any string and any comment.
 */

#ifndef CLAMACS_INDENT_H
#define CLAMACS_INDENT_H

#include <stdint.h>

/* The column the line beginning at LINE_START should start in.  Returns -1
 * when the line must be left alone, which is the case inside a multi-line
 * string: reindenting there would change the string's contents. */
int32_t ck_indent_for_line(const char *buf, int32_t len, int32_t line_start);

/* Distinguished-argument count for an operator, or -1 when it is not in the
 * table.  Case insensitive; a package prefix (`cl:when') is ignored. */
int32_t ck_indent_body_args(const char *name, int32_t namelen);

/* The column of OFFSET within its line, counting a tab as one column.  The
 * indenter emits spaces, so a file it has touched has no tabs in its
 * indentation and the two notions agree. */
int32_t ck_indent_column_of(const char *buf, int32_t len, int32_t offset);

/* Start of the line containing OFFSET. */
int32_t ck_indent_line_start(const char *buf, int32_t len, int32_t offset);

#endif /* CLAMACS_INDENT_H */
