/*
 * test_indent.c -- Lisp indentation.
 *
 * Each fixture is written the way the file would actually look, and the test
 * asks for the indent of the line containing a marker.  What the marker line
 * is currently indented to is irrelevant -- the indenter only reads what
 * comes BEFORE the line -- which is exactly the property that makes `Tab'
 * idempotent.
 */

#include "test.h"
#include "lisp/indent.h"

static int32_t indent_of_line_with(const char *src, const char *needle)
{
    const char *p = strstr(src, needle);
    int32_t     n = (int32_t)strlen(src);
    int32_t     start;

    if (p == NULL) {
        printf("  fixture does not contain \"%s\"\n", needle);
        return -99;
    }
    start = ck_indent_line_start(src, n, (int32_t)(p - src));
    return ck_indent_for_line(src, n, start);
}

TEST(top_level_is_column_zero)
{
    ASSERT_EQ_INT(indent_of_line_with("(a b)\n\n(c d)\n", "(c d)"), 0);
    ASSERT_EQ_INT(ck_indent_for_line("", 0, 0), 0);
}

TEST(defun_body_indents_two)
{
    ASSERT_EQ_INT(indent_of_line_with("(defun foo (a b)\n  body)\n", "body"), 2);
}

TEST(defun_distinguished_arguments_indent_four)
{
    /* The lambda list is a distinguished argument of `defun', so a lambda
     * list on its own line lines up further in than the body does. */
    ASSERT_EQ_INT(indent_of_line_with("(defun foo\n    (a b)\n  body)\n", "(a b)"), 4);
}

TEST(let_and_when)
{
    ASSERT_EQ_INT(indent_of_line_with("(let ((a 1))\n  body)\n", "body"), 2);
    ASSERT_EQ_INT(indent_of_line_with("(when x\n  y)\n", "y)"), 2);
    ASSERT_EQ_INT(indent_of_line_with("(unless x\n  y)\n", "y)"), 2);
    ASSERT_EQ_INT(indent_of_line_with("(let\n    ((a 1))\n  body)\n", "((a 1))"), 4);
}

TEST(if_distinguishes_two_arguments)
{
    const char *src = "(if test\n    then\n  else)\n";
    ASSERT_EQ_INT(indent_of_line_with(src, "then"), 4);
    ASSERT_EQ_INT(indent_of_line_with(src, "else"), 2);
}

TEST(unknown_operator_aligns_under_the_first_argument)
{
    ASSERT_EQ_INT(indent_of_line_with("(foo bar\n     baz)\n", "baz"), 5);
    ASSERT_EQ_INT(indent_of_line_with("(frobnicate a\n            b)\n", "b)"), 12);
}

TEST(operator_alone_on_its_line_indents_one_past_the_paren)
{
    ASSERT_EQ_INT(indent_of_line_with("(foo\n  bar)\n", "bar"), 1);
    ASSERT_EQ_INT(indent_of_line_with("(\n  foo)\n", "foo"), 1);
}

TEST(loop_aligns_its_clauses)
{
    /* `loop' is deliberately absent from the table: the default rule lines
     * clauses up under the first one, which no fixed argument count could
     * express. */
    ASSERT_EQ_INT(indent_of_line_with("(loop for x in xs\n      collect x)\n",
                                      "collect"), 6);
}

TEST(data_list_indents_one_past_the_paren)
{
    ASSERT_EQ_INT(indent_of_line_with("((a 1)\n (b 2))\n", "(b 2)"), 1);
}

TEST(nested_forms)
{
    const char *src =
        "(defun f ()\n"
        "  (let ((x 1))\n"
        "    (+ x\n"
        "       1)))\n";

    ASSERT_EQ_INT(indent_of_line_with(src, "(let"), 2);
    ASSERT_EQ_INT(indent_of_line_with(src, "(+ x"), 4);
    ASSERT_EQ_INT(indent_of_line_with(src, "1)))"), 7);
}

TEST(comment_lines_indent_like_body)
{
    ASSERT_EQ_INT(indent_of_line_with("(defun f ()\n  ;; note\n  body)\n", ";; note"), 2);
}

TEST(multi_line_string_is_left_alone)
{
    /* Reindenting inside a string would silently edit its contents. */
    const char *src =
        "(defun f ()\n"
        "  \"a string\n"
        "continues here\")\n";
    ASSERT_EQ_INT(indent_of_line_with(src, "continues here"), -1);
}

TEST(unknown_def_form_is_treated_as_a_definer)
{
    /* A project's own `define-...' macro indents sensibly before phase 2 can
     * ask clamiga where its &body starts. */
    ASSERT_EQ_INT(indent_of_line_with("(define-widget bar baz\n  body)\n", "body"), 2);
    ASSERT_EQ_INT(indent_of_line_with("(define-widget bar\n    baz)\n", "baz"), 4);
}

TEST(package_prefixes_are_ignored)
{
    ASSERT_EQ_INT(indent_of_line_with("(cl:when x\n  y)\n", "y)"), 2);
    ASSERT_EQ_INT(indent_of_line_with("(cl-user::defun f ()\n  body)\n", "body"), 2);
}

TEST(indented_open_paren_shifts_everything)
{
    const char *src =
        "(defun f ()\n"
        "  (when x\n"
        "    y))\n";
    ASSERT_EQ_INT(indent_of_line_with(src, "y))"), 4);
}

TEST(body_args_table)
{
    ASSERT_EQ_INT(ck_indent_body_args("defun", 5), 2);
    ASSERT_EQ_INT(ck_indent_body_args("DEFUN", 5), 2);
    ASSERT_EQ_INT(ck_indent_body_args("let", 3), 1);
    ASSERT_EQ_INT(ck_indent_body_args("let*", 4), 1);
    ASSERT_EQ_INT(ck_indent_body_args("progn", 5), 0);
    ASSERT_EQ_INT(ck_indent_body_args("cl:when", 7), 1);
    ASSERT_EQ_INT(ck_indent_body_args("loop", 4), -1);
    ASSERT_EQ_INT(ck_indent_body_args("frobnicate", 10), -1);
    ASSERT_EQ_INT(ck_indent_body_args("", 0), -1);
    ASSERT_EQ_INT(ck_indent_body_args(NULL, 0), -1);
}

TEST(column_helpers)
{
    const char *src = "abc\ndefgh\n";
    int32_t     n   = (int32_t)strlen(src);

    ASSERT_EQ_INT(ck_indent_line_start(src, n, 0), 0);
    ASSERT_EQ_INT(ck_indent_line_start(src, n, 2), 0);
    ASSERT_EQ_INT(ck_indent_line_start(src, n, 4), 4);
    ASSERT_EQ_INT(ck_indent_line_start(src, n, 7), 4);
    ASSERT_EQ_INT(ck_indent_column_of(src, n, 6), 2);
}

TEST(reindenting_is_idempotent)
{
    /* Whatever the line is currently indented to, the answer is the same --
     * the indenter reads only what comes before the line. */
    const char *a = "(defun f ()\nbody)\n";
    const char *b = "(defun f ()\n              body)\n";
    ASSERT_EQ_INT(indent_of_line_with(a, "body"), 2);
    ASSERT_EQ_INT(indent_of_line_with(b, "body"), 2);
}

int main(void)
{
    test_init();
    RUN(top_level_is_column_zero);
    RUN(defun_body_indents_two);
    RUN(defun_distinguished_arguments_indent_four);
    RUN(let_and_when);
    RUN(if_distinguishes_two_arguments);
    RUN(unknown_operator_aligns_under_the_first_argument);
    RUN(operator_alone_on_its_line_indents_one_past_the_paren);
    RUN(loop_aligns_its_clauses);
    RUN(data_list_indents_one_past_the_paren);
    RUN(nested_forms);
    RUN(comment_lines_indent_like_body);
    RUN(multi_line_string_is_left_alone);
    RUN(unknown_def_form_is_treated_as_a_definer);
    RUN(package_prefixes_are_ignored);
    RUN(indented_open_paren_shifts_everything);
    RUN(body_args_table);
    RUN(column_helpers);
    RUN(reindenting_is_idempotent);
    REPORT();
}
