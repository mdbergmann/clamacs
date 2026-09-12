/*
 * test_winstore.c -- the snapshot of window positions, as data.
 *
 * What the file format promises: an entry round-trips through format and
 * parse; a comment, a blank line or a line that does not parse is skipped
 * and costs nothing else; a role is looked up by name and replaced in
 * place; the roles of file windows and scratch windows are derived the way
 * winstore.h says.
 */

#include "test.h"
#include "emacs/winstore.h"

TEST(empty_store)
{
    ck_winstore s;
    char        out[CK_WINSTORE_TEXT_MAX];

    ck_winstore_init(&s);
    ASSERT_EQ_INT(s.count, 0);
    ASSERT(ck_winstore_find(&s, "repl") == NULL);
    ASSERT(ck_winstore_find(&s, NULL) == NULL);

    /* An empty store still formats to a valid file: the header only. */
    ASSERT(ck_winstore_format(&s, out, sizeof out) > 0);
    ASSERT(out[0] == ';');
    ASSERT_EQ_INT(ck_winstore_parse(&s, out), 0);
}

TEST(set_and_find)
{
    ck_winstore        s;
    const ck_winentry *e;

    ck_winstore_init(&s);
    ASSERT_EQ_INT(ck_winstore_set(&s, "repl", 10, 20, 640, 400), 1);
    ASSERT_EQ_INT(ck_winstore_set(&s, "doc1", 0, 11, 700, 500), 1);
    ASSERT_EQ_INT(s.count, 2);

    e = ck_winstore_find(&s, "repl");
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->left, 10);
    ASSERT_EQ_INT(e->top, 20);
    ASSERT_EQ_INT(e->width, 640);
    ASSERT_EQ_INT(e->height, 400);

    /* A second snapshot of the same window replaces, never duplicates. */
    ASSERT_EQ_INT(ck_winstore_set(&s, "repl", 30, 40, 600, 300), 1);
    ASSERT_EQ_INT(s.count, 2);
    e = ck_winstore_find(&s, "repl");
    ASSERT_EQ_INT(e->left, 30);
    ASSERT_EQ_INT(e->height, 300);

    /* Roles are exact: `Repl' is not `repl'. */
    ASSERT(ck_winstore_find(&s, "Repl") == NULL);
    ASSERT(ck_winstore_find(&s, "doc") == NULL);
}

TEST(set_rejects_what_it_cannot_hold)
{
    ck_winstore s;
    char        role[CK_WINSTORE_NAME_MAX + 8];
    int32_t     i;

    ck_winstore_init(&s);
    ASSERT_EQ_INT(ck_winstore_set(&s, "", 1, 2, 3, 4), 0);
    ASSERT_EQ_INT(ck_winstore_set(&s, NULL, 1, 2, 3, 4), 0);

    memset(role, 'x', sizeof role - 1);
    role[sizeof role - 1] = '\0';
    ASSERT_EQ_INT(ck_winstore_set(&s, role, 1, 2, 3, 4), 0);
    role[CK_WINSTORE_NAME_MAX - 1] = '\0';      /* exactly the longest allowed */
    ASSERT_EQ_INT(ck_winstore_set(&s, role, 1, 2, 3, 4), 1);
    ASSERT_EQ_INT(s.count, 1);

    for (i = 1; i < CK_WINSTORE_MAX; i++) {
        char name[16];
        snprintf(name, sizeof name, "doc%d", i);
        ASSERT_EQ_INT(ck_winstore_set(&s, name, i, i, i, i), 1);
    }
    ASSERT_EQ_INT(s.count, CK_WINSTORE_MAX);
    /* Full: a new role is refused, an existing one is still updated. */
    ASSERT_EQ_INT(ck_winstore_set(&s, "one-too-many", 1, 2, 3, 4), 0);
    ASSERT_EQ_INT(ck_winstore_set(&s, "doc1", 9, 9, 9, 9), 1);
    ASSERT_EQ_INT(ck_winstore_find(&s, "doc1")->left, 9);
    ASSERT_EQ_INT(s.count, CK_WINSTORE_MAX);
}

TEST(format_then_parse_round_trips)
{
    ck_winstore        a, b;
    char               text[CK_WINSTORE_TEXT_MAX];
    const ck_winentry *e;
    int32_t            len;

    ck_winstore_init(&a);
    ck_winstore_set(&a, "doc1", 0, 11, 640, 200);
    ck_winstore_set(&a, "doc2", 320, 11, 320, 200);
    ck_winstore_set(&a, "repl", 0, 222, 640, 100);
    ck_winstore_set(&a, "errors", -4, 300, 500, 60);   /* a window pushed off the left edge */

    len = ck_winstore_format(&a, text, sizeof text);
    ASSERT(len > 0);
    ASSERT_EQ_INT(len, (int32_t)strlen(text));
    ASSERT(strstr(text, "doc2 320 11 320 200\n") != NULL);
    ASSERT(strstr(text, "errors -4 300 500 60\n") != NULL);

    ASSERT_EQ_INT(ck_winstore_parse(&b, text), 4);
    ASSERT_EQ_INT(b.count, 4);
    e = ck_winstore_find(&b, "repl");
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->top, 222);
    e = ck_winstore_find(&b, "errors");
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->left, -4);
    ASSERT_EQ_INT(e->height, 60);
}

TEST(format_reports_when_it_does_not_fit)
{
    ck_winstore s;
    char        small[40];

    ck_winstore_init(&s);
    ck_winstore_set(&s, "doc1", 0, 11, 640, 200);
    ASSERT_EQ_INT(ck_winstore_format(&s, small, sizeof small), -1);
    ASSERT_EQ_INT(ck_winstore_format(&s, small, 0), -1);
    /* The declared maximum really holds a full store of the longest roles
     * and the widest numbers. */
    {
        static char text[CK_WINSTORE_TEXT_MAX];
        ck_winstore full;
        int32_t     i;

        ck_winstore_init(&full);
        for (i = 0; i < CK_WINSTORE_MAX; i++) {
            char name[CK_WINSTORE_NAME_MAX];
            memset(name, 'w', sizeof name - 1);
            name[sizeof name - 1] = '\0';
            name[0] = (char)('a' + (i % 26));
            name[1] = (char)('a' + (i / 26));
            ASSERT_EQ_INT(ck_winstore_set(&full, name, -99999, -99999, 999999, 999999), 1);
        }
        ASSERT_EQ_INT(full.count, CK_WINSTORE_MAX);
        ASSERT(ck_winstore_format(&full, text, sizeof text) > 0);
        ASSERT_EQ_INT(ck_winstore_parse(&full, text), CK_WINSTORE_MAX);
    }
}

TEST(parse_is_forgiving)
{
    ck_winstore        s;
    const ck_winentry *e;
    const char *text =
        "; a comment\n"
        "# another\n"
        "\n"
        "   \n"
        "doc1 10 20 300 400\r\n"          /* CRLF, from a file edited elsewhere */
        "  repl\t5\t6\t7\t8  \n"           /* tabs and stray blanks */
        "errors 1 2 3\n"                   /* one number short: skipped */
        "debugger 1 2 3 4 5\n"             /* one too many: skipped */
        "inspector x 2 3 4\n"              /* not a number: skipped */
        "doc2 10 20 30 40 ; trailing\n"    /* junk after the numbers: skipped */
        "doc3 12345678 1 1 1\n"            /* absurd: skipped */
        "sevendigit 1000000 1 1 1\n"       /* one digit past the 6-digit cap: skipped */
        "averyveryveryverylongrolename 1 2 3 4\n"   /* role too long: skipped */
        "apropos 0 0 0 0";                 /* no final newline */

    ASSERT_EQ_INT(ck_winstore_parse(&s, text), 3);
    e = ck_winstore_find(&s, "doc1");
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->height, 400);
    e = ck_winstore_find(&s, "repl");
    ASSERT(e != NULL);
    ASSERT_EQ_INT(e->left, 5);
    ASSERT_EQ_INT(e->height, 8);
    ASSERT(ck_winstore_find(&s, "apropos") != NULL);
    ASSERT(ck_winstore_find(&s, "errors") == NULL);
    ASSERT(ck_winstore_find(&s, "debugger") == NULL);
    ASSERT(ck_winstore_find(&s, "inspector") == NULL);
    ASSERT(ck_winstore_find(&s, "doc2") == NULL);
    ASSERT(ck_winstore_find(&s, "doc3") == NULL);
    ASSERT(ck_winstore_find(&s, "sevendigit") == NULL);

    /* A later line for the same role wins, as a hand edit would expect. */
    ASSERT_EQ_INT(ck_winstore_parse(&s, "repl 1 1 1 1\nrepl 2 2 2 2\n"), 2);
    ASSERT_EQ_INT(s.count, 1);
    ASSERT_EQ_INT(ck_winstore_find(&s, "repl")->left, 2);

    /* Parsing replaces: nothing of the old contents survives. */
    ASSERT_EQ_INT(ck_winstore_parse(&s, ""), 0);
    ASSERT_EQ_INT(s.count, 0);
    ASSERT_EQ_INT(ck_winstore_parse(&s, NULL), 0);
    ASSERT_EQ_INT(s.count, 0);
}

TEST(parse_survives_a_very_long_line)
{
    ck_winstore s;
    char        text[600];
    int32_t     n;

    /* A 500-character line of digits, then a good entry after it. */
    memset(text, '7', 500);
    n = 500;
    n += snprintf(text + n, sizeof text - (size_t)n, "\nrepl 1 2 3 4\n");
    ASSERT_EQ_INT(ck_winstore_parse(&s, text), 1);
    ASSERT(ck_winstore_find(&s, "repl") != NULL);
}

TEST(parse_line_exactly_fits_the_buffer)
{
    ck_winstore s;
    char        text[200];
    int32_t     n;

    /* The line buffer is 128 bytes; a 127-character line (126 for the
     * entry, trailing spaces padding it out) fits with the NUL and must
     * still parse -- it is one character short of the buffer, not over
     * it. */
    n = snprintf(text, sizeof text, "doc1 1 2 3 4");
    while (n < 127)
        text[n++] = ' ';
    text[n++] = '\n';
    text[n] = '\0';
    ASSERT_EQ_INT((int32_t)strlen(text) - 1, 127);   /* line itself, minus the '\n' */

    ASSERT_EQ_INT(ck_winstore_parse(&s, text), 1);
    ASSERT(ck_winstore_find(&s, "doc1") != NULL);
}

TEST(doc_roles)
{
    char role[CK_WINSTORE_NAME_MAX];

    ASSERT_EQ_INT(ck_winstore_doc_role(1, role, sizeof role), 4);
    ASSERT_STR_EQ(role, "doc1");
    ASSERT_EQ_INT(ck_winstore_doc_role(12, role, sizeof role), 5);
    ASSERT_STR_EQ(role, "doc12");
    ASSERT_EQ_INT(ck_winstore_doc_role(0, role, sizeof role), 0);
    ASSERT_EQ_INT(ck_winstore_doc_role(-3, role, sizeof role), 0);
    ASSERT_EQ_INT(ck_winstore_doc_role(1, role, 4), 0);   /* no room for the NUL */
    ASSERT_STR_EQ(role, "");

    ASSERT_EQ_INT(ck_winstore_doc_slot("doc1"), 1);
    ASSERT_EQ_INT(ck_winstore_doc_slot("doc12"), 12);
    ASSERT_EQ_INT(ck_winstore_doc_slot("doc"), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot("doc1x"), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot("docs"), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot("repl"), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot("document"), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot(""), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot(NULL), 0);
    ASSERT_EQ_INT(ck_winstore_doc_slot("doc99999999999"), 0);
}

TEST(scratch_roles)
{
    char role[CK_WINSTORE_NAME_MAX];

    ck_winstore_scratch_role("*clamacs-repl*", role, sizeof role);
    ASSERT_STR_EQ(role, "repl");
    ck_winstore_scratch_role("*clamacs-description*", role, sizeof role);
    ASSERT_STR_EQ(role, "description");
    ck_winstore_scratch_role("*clamacs-macroexpansion*", role, sizeof role);
    ASSERT_STR_EQ(role, "macroexpansion");
    ck_winstore_scratch_role("*scratch*", role, sizeof role);
    ASSERT_STR_EQ(role, "scratch");
    ck_winstore_scratch_role("no stars here", role, sizeof role);
    ASSERT_STR_EQ(role, "no-stars-here");
    ck_winstore_scratch_role("**", role, sizeof role);
    ASSERT_STR_EQ(role, "");
    ck_winstore_scratch_role(NULL, role, sizeof role);
    ASSERT_STR_EQ(role, "");

    /* A name longer than a role is cut to fit, never overrun. */
    ck_winstore_scratch_role("*clamacs-abcdefghijklmnopqrstuvwxyz0123456789*",
                             role, sizeof role);
    ASSERT_EQ_INT((int32_t)strlen(role), CK_WINSTORE_NAME_MAX - 1);
    ASSERT(strstr(role, "*") == NULL);

    /* The role of a scratch window is never a file window's slot. */
    ASSERT_EQ_INT(ck_winstore_doc_slot("repl"), 0);
}

int main(void)
{
    test_init();
    RUN(empty_store);
    RUN(set_and_find);
    RUN(set_rejects_what_it_cannot_hold);
    RUN(format_then_parse_round_trips);
    RUN(format_reports_when_it_does_not_fit);
    RUN(parse_is_forgiving);
    RUN(parse_survives_a_very_long_line);
    RUN(parse_line_exactly_fits_the_buffer);
    RUN(doc_roles);
    RUN(scratch_roles);
    REPORT();
}
