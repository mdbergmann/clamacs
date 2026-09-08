/*
 * test_sexp.c -- the s-expression scanner.
 *
 * Positions are located with strstr rather than counted by hand, so the test
 * source stays readable and a fixture can be edited without renumbering.
 */

#include "test.h"
#include "lisp/sexp.h"

static int32_t at(const char *buf, const char *needle)
{
    const char *p = strstr(buf, needle);
    if (p == NULL) {
        printf("  fixture does not contain \"%s\"\n", needle);
        return -1;
    }
    return (int32_t)(p - buf);
}

static int32_t slen(const char *s) { return (int32_t)strlen(s); }

TEST(forward_over_atoms_and_lists)
{
    const char *b = "(foo bar)";
    int32_t     n = slen(b);

    ASSERT_EQ_INT(ck_sexp_forward(b, n, 0), 9);          /* the whole list */
    ASSERT_EQ_INT(ck_sexp_forward(b, n, 1), 4);          /* foo */
    ASSERT_EQ_INT(ck_sexp_forward(b, n, 4), 8);          /* bar */
    ASSERT_EQ_INT(ck_sexp_forward(b, n, 8), -1);         /* at the close paren */
    ASSERT_EQ_INT(ck_sexp_forward(b, n, n), -1);         /* at the end */
}

TEST(forward_from_inside_an_atom)
{
    const char *b = "(foo bar)";
    /* Emacs moves to the end of the atom point is standing in. */
    ASSERT_EQ_INT(ck_sexp_forward(b, slen(b), 2), 4);
}

TEST(forward_over_a_quoted_form)
{
    const char *b = "'(a b) next";
    ASSERT_EQ_INT(ck_sexp_forward(b, slen(b), 0), 6);
    /* ,@ and #' are prefixes too. */
    ASSERT_EQ_INT(ck_sexp_forward(",@(a) x", 7, 0), 5);
    ASSERT_EQ_INT(ck_sexp_forward("#'foo bar", 9, 0), 5);
    ASSERT_EQ_INT(ck_sexp_forward("#(1 2 3) x", 10, 0), 8);
}

TEST(forward_over_a_string)
{
    const char *b = "(f \"a ) b\" c)";
    int32_t     s = at(b, "\"");
    ASSERT_EQ_INT(ck_sexp_forward(b, slen(b), s), s + 7);   /* past "a ) b" */
    /* The `)' inside the string must not close the list. */
    ASSERT_EQ_INT(ck_sexp_forward(b, slen(b), 0), slen(b));
}

TEST(unbalanced_input_does_not_hang)
{
    ASSERT_EQ_INT(ck_sexp_forward("(a b", 4, 0), -1);
    ASSERT_EQ_INT(ck_sexp_forward("", 0, 0), -1);
    ASSERT_EQ_INT(ck_sexp_forward(")))", 3, 0), -1);
    ASSERT_EQ_INT(ck_sexp_backward("(((", 3, 3), -1);
    ASSERT_EQ_INT(ck_sexp_forward("\"unterminated", 13, 0), 13);
}

TEST(backward_over_atoms_and_lists)
{
    const char *b = "(foo bar)";
    int32_t     n = slen(b);

    ASSERT_EQ_INT(ck_sexp_backward(b, n, n), 0);   /* the whole list */
    ASSERT_EQ_INT(ck_sexp_backward(b, n, 8), 5);   /* bar */
    ASSERT_EQ_INT(ck_sexp_backward(b, n, 4), 1);   /* foo */
    ASSERT_EQ_INT(ck_sexp_backward(b, n, 1), -1);  /* nothing before it */
    ASSERT_EQ_INT(ck_sexp_backward(b, n, 0), -1);
}

TEST(backward_includes_the_quote)
{
    const char *b = "'(a b)";
    /* backward-sexp from the end must land on the quote, not on the paren:
     * the quote is part of the form, and `C-x C-e' sends what it delimits. */
    ASSERT_EQ_INT(ck_sexp_backward(b, slen(b), slen(b)), 0);
}

TEST(backward_from_inside_an_atom)
{
    const char *b = "(foo bar)";
    ASSERT_EQ_INT(ck_sexp_backward(b, slen(b), 6), 5);
}

TEST(up_and_down_list)
{
    const char *b = "(a (b (c)) d)";
    int32_t     n = slen(b);
    int32_t     c = at(b, "c");

    ASSERT_EQ_INT(ck_sexp_up(b, n, c), at(b, "(c)"));
    ASSERT_EQ_INT(ck_sexp_up(b, n, at(b, "(c)")), at(b, "(b "));
    ASSERT_EQ_INT(ck_sexp_up(b, n, at(b, "(b ")), 0);
    ASSERT_EQ_INT(ck_sexp_up(b, n, 0), -1);          /* already at top level */

    ASSERT_EQ_INT(ck_sexp_down(b, n, 0), 1);
    ASSERT_EQ_INT(ck_sexp_down(b, n, 1), at(b, "(b ") + 1);
}

TEST(down_list_refuses_to_leave_the_list)
{
    const char *b = "(a b) (c)";
    /* From inside the first list there is no sublist to descend into; the
     * close paren stops the search rather than jumping to (c). */
    ASSERT_EQ_INT(ck_sexp_down(b, slen(b), 3), -1);
}

static const char *const fixture =
    "(in-package :my-app)\n"
    "\n"
    "(defun frobnicate (x)\n"
    "  ;; a ) paren in a comment\n"
    "  (let ((y \"a ( string\"))\n"
    "    (list x y)))\n"
    "\n"
    "(defvar *thing* 42)\n";

TEST(defun_start_and_end)
{
    int32_t     n     = slen(fixture);
    int32_t     defun = at(fixture, "(defun");
    int32_t     inner = at(fixture, "(list");
    int32_t     defvar = at(fixture, "(defvar");

    ASSERT_EQ_INT(ck_sexp_defun_start(fixture, n, inner), defun);
    /* A `(' in column 0 is what makes a defun; the nested ones do not
     * count, however deep point is. */
    ASSERT_EQ_INT(ck_sexp_defun_start(fixture, n, defvar), defvar);
    ASSERT_EQ_INT(ck_sexp_defun_start(fixture, n, 0), 0);

    ASSERT_EQ_INT(ck_sexp_defun_end(fixture, n, inner),
                  at(fixture, "(list x y)))") + slen("(list x y)))"));
}

TEST(comments_and_strings_hide_their_parens)
{
    int32_t n = slen(fixture);

    /* The whole defun still closes correctly despite a `)' in a comment and
     * a `(' in a string. */
    ASSERT_EQ_INT(ck_sexp_forward(fixture, n, at(fixture, "(defun")),
                  at(fixture, "(list x y)))") + slen("(list x y)))"));
}

TEST(context)
{
    int32_t n = slen(fixture);

    ASSERT_EQ_INT(ck_sexp_context(fixture, n, at(fixture, "paren in a")), CK_CTX_COMMENT);
    ASSERT_EQ_INT(ck_sexp_context(fixture, n, at(fixture, "a ( string") + 2), CK_CTX_STRING);
    ASSERT_EQ_INT(ck_sexp_context(fixture, n, at(fixture, "(list")), CK_CTX_CODE);
}

TEST(match_paren)
{
    const char *b = "(a (b) c)";
    int32_t     n = slen(b);

    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 0), 8);
    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 8), 0);
    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 3), 5);
    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 5), 3);
    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 1), -1);   /* not on a paren */
}

TEST(match_paren_ignores_comments_and_strings)
{
    int32_t n = slen(fixture);
    int32_t comment_paren = at(fixture, ") paren in a comment");
    int32_t string_paren  = at(fixture, "( string");

    ASSERT_EQ_INT(ck_sexp_match_paren(fixture, n, comment_paren), -1);
    ASSERT_EQ_INT(ck_sexp_match_paren(fixture, n, string_paren), -1);

    /* And a real paren still matches across both of them. */
    ASSERT_EQ_INT(ck_sexp_match_paren(fixture, n, at(fixture, "(let")),
                  at(fixture, "(list x y)))") + slen("(list x y))") - 1);
}

TEST(match_paren_unbalanced)
{
    ASSERT_EQ_INT(ck_sexp_match_paren("(a b", 4, 0), -1);
    ASSERT_EQ_INT(ck_sexp_match_paren("a)", 2, 1), -1);
}

TEST(last_sexp)
{
    const char *b = "(foo) (+ 1 2)";
    int32_t     n = slen(b);
    int32_t     end = -1;
    int32_t     start;

    start = ck_sexp_last_sexp(b, n, n, &end);
    ASSERT_EQ_INT(start, 6);
    ASSERT_EQ_INT(end, 13);

    /* Point right after the first form. */
    start = ck_sexp_last_sexp(b, n, 5, &end);
    ASSERT_EQ_INT(start, 0);
    ASSERT_EQ_INT(end, 5);

    ASSERT_EQ_INT(ck_sexp_last_sexp(b, n, 0, &end), -1);
    ASSERT_EQ_INT(end, -1);
}

TEST(current_package)
{
    char    pkg[64];
    int32_t n = slen(fixture);

    ASSERT_EQ_INT(ck_sexp_current_package(fixture, n, n, pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "my-app");

    /* A form later in the file must not apply above itself. */
    ASSERT_EQ_INT(ck_sexp_current_package(fixture, n, 0, pkg, sizeof pkg), 0);
}

TEST(current_package_spellings)
{
    char pkg[64];

    ASSERT_EQ_INT(ck_sexp_current_package("(in-package \"BAR\")", 18, 18, pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "BAR");

    ASSERT_EQ_INT(ck_sexp_current_package("(in-package #:baz)", 18, 18, pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "baz");

    ASSERT_EQ_INT(ck_sexp_current_package("(IN-PACKAGE :qux)", 17, 17, pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "qux");

    ASSERT_EQ_INT(ck_sexp_current_package("(defun in-package ())", 21, 21, pkg, sizeof pkg), 0);
}

TEST(current_package_takes_the_nearest_one_above)
{
    const char *b = "(in-package :a)\n(foo)\n(in-package :b)\n(bar)\n";
    char        pkg[64];
    int32_t     n = slen(b);

    ASSERT_EQ_INT(ck_sexp_current_package(b, n, at(b, "(foo)"), pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "a");

    ASSERT_EQ_INT(ck_sexp_current_package(b, n, at(b, "(bar)"), pkg, sizeof pkg), 1);
    ASSERT_STR_EQ(pkg, "b");
}

TEST(character_literal_parens_are_not_parens)
{
    const char *b = "(list #\\( #\\))";
    int32_t     n = slen(b);
    ASSERT_EQ_INT(ck_sexp_forward(b, n, 0), n);
    ASSERT_EQ_INT(ck_sexp_match_paren(b, n, 0), n - 1);
}

int main(void)
{
    test_init();
    RUN(forward_over_atoms_and_lists);
    RUN(forward_from_inside_an_atom);
    RUN(forward_over_a_quoted_form);
    RUN(forward_over_a_string);
    RUN(unbalanced_input_does_not_hang);
    RUN(backward_over_atoms_and_lists);
    RUN(backward_includes_the_quote);
    RUN(backward_from_inside_an_atom);
    RUN(up_and_down_list);
    RUN(down_list_refuses_to_leave_the_list);
    RUN(defun_start_and_end);
    RUN(comments_and_strings_hide_their_parens);
    RUN(context);
    RUN(match_paren);
    RUN(match_paren_ignores_comments_and_strings);
    RUN(match_paren_unbalanced);
    RUN(last_sexp);
    RUN(current_package);
    RUN(current_package_spellings);
    RUN(current_package_takes_the_nearest_one_above);
    RUN(character_literal_parens_are_not_parens);
    REPORT();
}
