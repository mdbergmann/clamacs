/*
 * test_token.c -- the Lisp colouring tokenizer.
 */

#include "test.h"
#include "lisp/token.h"

#define MAXTOK 64

static ck_token toks[MAXTOK];
static ck_tok_state state;

static int32_t tokenize(const char *line)
{
    return ck_tokenize_line(line, (int32_t)strlen(line), &state, toks, MAXTOK);
}

static int32_t tok_is(const char *line, int32_t i, uint8_t kind, const char *text)
{
    int32_t n = (int32_t)strlen(text);
    if (toks[i].kind != kind) {
        printf("  token %d: kind %d, expected %d\n", (int)i,
               (int)toks[i].kind, (int)kind);
        return 0;
    }
    if (toks[i].len != (uint16_t)n ||
        strncmp(line + toks[i].start, text, (size_t)n) != 0) {
        printf("  token %d: \"%.*s\", expected \"%s\"\n", (int)i,
               (int)toks[i].len, line + toks[i].start, text);
        return 0;
    }
    return 1;
}

#define TOK_IS(line, i, kind, text) ASSERT(tok_is((line), (i), (kind), (text)))

TEST(numbers)
{
    static const char *const yes[] = {
        "42", "-3", "+7", "1/2", "-1/2", "1.5", ".5", "1.", "1.0d0", "1e10",
        "1.5e-3", "#xFF", "#xff", "#b1010", "#o17", "#16rFF", "#x-10", NULL
    };
    static const char *const no[] = {
        "1+", "-", "+", "a1", "1.2.3", "foo", "1/", "#x", "#xg", "#zz",
        ":42", "", NULL
    };
    int32_t i;

    for (i = 0; yes[i] != NULL; i++) {
        if (!ck_tok_is_number(yes[i], (int32_t)strlen(yes[i]))) {
            printf("  \"%s\" should be a number\n", yes[i]);
            test_current_failed = 1;
        }
    }
    for (i = 0; no[i] != NULL; i++) {
        if (ck_tok_is_number(no[i], (int32_t)strlen(no[i]))) {
            printf("  \"%s\" should not be a number\n", no[i]);
            test_current_failed = 1;
        }
    }
}

TEST(defining_forms)
{
    ASSERT(ck_tok_is_defining("defun", 5));
    ASSERT(ck_tok_is_defining("DEFUN", 5));
    ASSERT(ck_tok_is_defining("DefMacro", 8));
    ASSERT(ck_tok_is_defining("define-condition", 16));
    ASSERT(!ck_tok_is_defining("defunny", 7));
    ASSERT(!ck_tok_is_defining("def", 3));
    ASSERT(!ck_tok_is_defining("", 0));
}

TEST(simple_form)
{
    const char *line = "(defun foo (a b)";
    int32_t     n;

    ck_tok_state_init(&state);
    n = tokenize(line);
    ASSERT_EQ_INT(n, 7);
    TOK_IS(line, 0, CK_TOK_PAREN,    "(");
    TOK_IS(line, 1, CK_TOK_DEFINING, "defun");
    TOK_IS(line, 2, CK_TOK_SYMBOL,   "foo");
    TOK_IS(line, 3, CK_TOK_PAREN,    "(");
    TOK_IS(line, 4, CK_TOK_SYMBOL,   "a");
    TOK_IS(line, 5, CK_TOK_SYMBOL,   "b");
    TOK_IS(line, 6, CK_TOK_PAREN,    ")");
}

TEST(defun_only_colours_in_head_position)
{
    const char *line = "(list defun 1)";
    ck_tok_state_init(&state);
    tokenize(line);
    TOK_IS(line, 1, CK_TOK_SYMBOL, "list");
    /* Not the head of its list, so it is an ordinary symbol here. */
    TOK_IS(line, 2, CK_TOK_SYMBOL, "defun");
    TOK_IS(line, 3, CK_TOK_NUMBER, "1");
}

TEST(keywords_and_numbers)
{
    const char *line = "(foo :key 42 1/2 x)";
    ck_tok_state_init(&state);
    tokenize(line);
    TOK_IS(line, 2, CK_TOK_KEYWORD, ":key");
    TOK_IS(line, 3, CK_TOK_NUMBER,  "42");
    TOK_IS(line, 4, CK_TOK_NUMBER,  "1/2");
    TOK_IS(line, 5, CK_TOK_SYMBOL,  "x");
}

TEST(line_comment)
{
    const char *line = "(foo) ; and the rest (is) \"not\" code";
    int32_t     n;

    ck_tok_state_init(&state);
    n = tokenize(line);
    ASSERT_EQ_INT(n, 4);
    TOK_IS(line, 3, CK_TOK_COMMENT, "; and the rest (is) \"not\" code");
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
}

TEST(string_on_one_line)
{
    const char *line = "(format t \"hi ; there (\" x)";
    ck_tok_state_init(&state);
    tokenize(line);
    TOK_IS(line, 3, CK_TOK_STRING, "\"hi ; there (\"");
    TOK_IS(line, 4, CK_TOK_SYMBOL, "x");
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
}

TEST(string_with_escaped_quote)
{
    const char *line = "\"a \\\" b\" tail";
    ck_tok_state_init(&state);
    tokenize(line);
    TOK_IS(line, 0, CK_TOK_STRING, "\"a \\\" b\"");
    TOK_IS(line, 1, CK_TOK_SYMBOL, "tail");
}

TEST(string_spanning_lines)
{
    const char *l1 = "(foo \"start";
    const char *l2 = "middle";
    const char *l3 = "end\" done)";

    ck_tok_state_init(&state);
    tokenize(l1);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_STRING);

    tokenize(l2);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_STRING);
    TOK_IS(l2, 0, CK_TOK_STRING, "middle");

    tokenize(l3);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
    TOK_IS(l3, 0, CK_TOK_STRING, "end\"");
    TOK_IS(l3, 1, CK_TOK_SYMBOL, "done");
    TOK_IS(l3, 2, CK_TOK_PAREN,  ")");
}

TEST(block_comment_nesting)
{
    const char *l1 = "#| outer #| inner";
    const char *l2 = "|# still in the outer";
    const char *l3 = "|# (code)";

    ck_tok_state_init(&state);
    tokenize(l1);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_BLOCK_COMMENT);
    ASSERT_EQ_INT(state.depth, 2);

    tokenize(l2);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_BLOCK_COMMENT);
    ASSERT_EQ_INT(state.depth, 1);

    tokenize(l3);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
    TOK_IS(l3, 1, CK_TOK_PAREN,  "(");
    TOK_IS(l3, 2, CK_TOK_SYMBOL, "code");
}

TEST(block_comment_on_one_line)
{
    const char *line = "(a #| b |# c)";
    ck_tok_state_init(&state);
    tokenize(line);
    TOK_IS(line, 1, CK_TOK_SYMBOL,  "a");
    TOK_IS(line, 2, CK_TOK_COMMENT, "#| b |#");
    TOK_IS(line, 3, CK_TOK_SYMBOL,  "c");
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
}

TEST(character_literals)
{
    const char *line = "(list #\\( #\\; #\\Space #\\a)";
    ck_tok_state_init(&state);
    tokenize(line);
    /* None of these open a list, start a comment or otherwise derail the
     * scan -- which is the whole reason character literals get their own
     * branch ahead of the dispatch-macro one. */
    TOK_IS(line, 2, CK_TOK_CHAR,  "#\\(");
    TOK_IS(line, 3, CK_TOK_CHAR,  "#\\;");
    TOK_IS(line, 4, CK_TOK_CHAR,  "#\\Space");
    TOK_IS(line, 5, CK_TOK_CHAR,  "#\\a");
    TOK_IS(line, 6, CK_TOK_PAREN, ")");
}

TEST(head_position_carries_across_a_line_break)
{
    const char *l1 = "(";
    const char *l2 = "  defun foo ()";

    ck_tok_state_init(&state);
    tokenize(l1);
    ASSERT_EQ_INT(state.head, 1);
    tokenize(l2);
    TOK_IS(l2, 0, CK_TOK_DEFINING, "defun");
}

TEST(state_equality)
{
    ck_tok_state a, b;
    ck_tok_state_init(&a);
    ck_tok_state_init(&b);
    ASSERT(ck_tok_state_equal(&a, &b));
    b.where = CK_TOK_IN_STRING;
    ASSERT(!ck_tok_state_equal(&a, &b));
}

TEST(empty_and_blank_lines)
{
    ck_tok_state_init(&state);
    ASSERT_EQ_INT(tokenize(""), 0);
    ASSERT_EQ_INT(tokenize("      "), 0);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_CODE);
}

TEST(token_overflow_still_tracks_state)
{
    /* More tokens than the caller's buffer: the count reports the truth and
     * the carried state is still right, so redisplay can widen and retry
     * rather than silently mis-colour the rest of the file. */
    const char *line = "(a b c \"open";
    int32_t     n;

    ck_tok_state_init(&state);
    n = ck_tokenize_line(line, (int32_t)strlen(line), &state, toks, 2);
    ASSERT_EQ_INT(n, 5);
    ASSERT_EQ_INT(state.where, CK_TOK_IN_STRING);
}

int main(void)
{
    test_init();
    RUN(numbers);
    RUN(defining_forms);
    RUN(simple_form);
    RUN(defun_only_colours_in_head_position);
    RUN(keywords_and_numbers);
    RUN(line_comment);
    RUN(string_on_one_line);
    RUN(string_with_escaped_quote);
    RUN(string_spanning_lines);
    RUN(block_comment_nesting);
    RUN(block_comment_on_one_line);
    RUN(character_literals);
    RUN(head_position_carries_across_a_line_break);
    RUN(state_equality);
    RUN(empty_and_blank_lines);
    RUN(token_overflow_still_tracks_state);
    REPORT();
}
