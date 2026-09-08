/*
 * test_diag.c -- parsing clamiga's replies.
 */

#include "test.h"
#include "rexx/diag.h"

TEST(located_diagnostic)
{
    ck_diag d;
    const char *line = "Work:src/foo.lisp:3: ERROR: Too many arguments to FOO";

    ASSERT_EQ_INT(ck_diag_parse_line(line, (int32_t)strlen(line), &d), 1);
    /* An Amiga path has a colon of its own, so the split cannot be on the
     * first one -- nor even on the second, for a path with an assign AND a
     * drive. */
    ASSERT_STR_EQ(d.file, "Work:src/foo.lisp");
    ASSERT_EQ_INT(d.line, 3);
    ASSERT_EQ_INT(d.severity, CK_SEV_ERROR);
    ASSERT_STR_EQ(d.text, "Too many arguments to FOO");
    ASSERT_STR_EQ(d.rendered, line);
    free(d.file); free(d.text); free(d.rendered);
}

TEST(path_with_spaces_and_assigns)
{
    ck_diag d;
    const char *line = "Ram Disk:my file.lisp:12: WARNING: unused variable X";

    ASSERT_EQ_INT(ck_diag_parse_line(line, (int32_t)strlen(line), &d), 1);
    ASSERT_STR_EQ(d.file, "Ram Disk:my file.lisp");
    ASSERT_EQ_INT(d.line, 12);
    ASSERT_EQ_INT(d.severity, CK_SEV_WARNING);
    free(d.file); free(d.text); free(d.rendered);
}

TEST(unlocated_diagnostic)
{
    ck_diag d;
    const char *line = "ERROR: no such package: FOO";

    ASSERT_EQ_INT(ck_diag_parse_line(line, (int32_t)strlen(line), &d), 1);
    ASSERT(d.file == NULL);
    ASSERT_EQ_INT(d.line, 0);
    ASSERT_EQ_INT(d.severity, CK_SEV_ERROR);
    /* The message keeps its own colons. */
    ASSERT_STR_EQ(d.text, "no such package: FOO");
    free(d.file); free(d.text); free(d.rendered);
}

TEST(message_containing_a_severity_word)
{
    ck_diag d;
    const char *line = "foo.lisp:1: ERROR: the word ERROR: appears again";

    ASSERT_EQ_INT(ck_diag_parse_line(line, (int32_t)strlen(line), &d), 1);
    ASSERT_STR_EQ(d.file, "foo.lisp");
    ASSERT_EQ_INT(d.line, 1);
    ASSERT_STR_EQ(d.text, "the word ERROR: appears again");
    free(d.file); free(d.text); free(d.rendered);
}

TEST(non_diagnostic_lines)
{
    ck_diag d;
    static const char *const lines[] = {
        "; loading Work:src/foo.lisp",
        "--- log ---",
        "just some output",
        "a:b:c",
        "",
        NULL
    };
    int32_t i;

    for (i = 0; lines[i] != NULL; i++) {
        if (ck_diag_parse_line(lines[i], (int32_t)strlen(lines[i]), &d)) {
            printf("  \"%s\" was read as a diagnostic\n", lines[i]);
            test_current_failed = 1;
            free(d.file); free(d.text); free(d.rendered);
        }
    }
}

TEST(full_reply)
{
    ck_diaglist list;
    const char *reply =
        "; loading Work:src/foo.lisp\n"
        "Work:src/foo.lisp:3: ERROR: Too many arguments to FOO\n"
        "Work:src/foo.lisp:7: WARNING: Undefined variable Y\n"
        "1 error(s), 1 warning(s)\n"
        "--- log ---\n"
        "some compiler chatter\n";

    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, reply), 2);
    ASSERT_EQ_INT(list.count, 2);
    ASSERT_EQ_INT(list.errors, 1);
    ASSERT_EQ_INT(list.warnings, 1);
    ASSERT_EQ_INT(list.summary_seen, 1);
    ASSERT_STR_EQ(list.summary, "1 error(s), 1 warning(s)");

    ASSERT_EQ_INT(list.items[0].line, 3);
    ASSERT_EQ_INT(list.items[0].severity, CK_SEV_ERROR);
    ASSERT_EQ_INT(list.items[1].line, 7);
    ASSERT_EQ_INT(list.items[1].severity, CK_SEV_WARNING);

    ck_diag_clear(&list);
    ASSERT_EQ_INT(list.count, 0);
}

TEST(the_log_section_is_not_parsed)
{
    /* The reply carries the diagnostics first, then the summary, then
     * everything the command printed.  That last part contains clamiga's own
     * error reports, which begin with `ERROR: ' -- and reading those as
     * diagnostics doubles the list, so `C-x `' walks into rows that are not
     * real and cannot be jumped to.  Found on the Amiga, not here; this test
     * is what keeps it fixed. */
    ck_diaglist list;
    const char *reply =
        "; loading Work:errors.lisp\n"
        "Work:errors.lisp:7: ERROR: first deliberate error\n"
        "Work:errors.lisp:9: ERROR: Undefined function: NO-SUCH-FUNCTION\n"
        "2 error(s), 0 warning(s)\n"
        "--- log ---\n"
        "; Loading Work:errors.lisp\n"
        "ERROR: SIMPLE-ERROR: first deliberate error\n"
        "Backtrace:\n"
        "  0: <anonymous> (Work:errors.lisp:7)\n"
        "ERROR: Undefined function: NO-SUCH-FUNCTION\n"
        "Backtrace:\n"
        "  0: <anonymous> (Work:errors.lisp:9)\n";

    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, reply), 2);
    ASSERT_EQ_INT(list.count, 2);
    ASSERT_EQ_INT(list.errors, 2);
    ASSERT_EQ_INT(list.items[0].line, 7);
    ASSERT_EQ_INT(list.items[1].line, 9);
    ck_diag_clear(&list);
}

TEST(truncation_is_seen_after_the_log)
{
    /* %TRUNCATE appends its marker to the assembled reply, so it arrives
     * after the log section -- past the point where diagnostics stop being
     * parsed.  It still has to register, or a half-received reply would be
     * reported as a complete one. */
    ck_diaglist list;
    const char *reply =
        "foo.lisp:1: ERROR: boom\n"
        "1 error(s), 0 warning(s)\n"
        "--- log ---\n"
        "ERROR: chatter that is not a diagnostic\n"
        "[truncated at 8192 characters]\n";

    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, reply), 1);
    ASSERT_EQ_INT(list.count, 1);
    ASSERT_EQ_INT(list.truncated, 1);
    ck_diag_clear(&list);
}

TEST(clean_reply)
{
    ck_diaglist list;
    const char *reply = "; loading Work:src/foo.lisp\n0 error(s), 0 warning(s)";

    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, reply), 0);
    ASSERT_EQ_INT(list.summary_seen, 1);
    ASSERT_EQ_INT(list.errors, 0);
    ASSERT_EQ_INT(list.warnings, 0);
    ck_diag_clear(&list);
}

TEST(markers)
{
    ck_diaglist list;
    const char *reply =
        "foo.lisp:1: ERROR: boom\n"
        "1 error(s), 0 warning(s)\n"
        "; aborted -- the remaining forms were not processed\n"
        "[truncated at 8192 characters]\n";

    ck_diag_init(&list);
    ck_diag_parse(&list, reply);
    ASSERT_EQ_INT(list.aborted, 1);
    ASSERT_EQ_INT(list.truncated, 1);
    ASSERT_EQ_INT(list.count, 1);
    ck_diag_clear(&list);
}

TEST(crlf_and_missing_final_newline)
{
    ck_diaglist list;
    const char *reply = "foo.lisp:1: ERROR: boom\r\nfoo.lisp:2: ERROR: bang";

    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, reply), 2);
    ASSERT_STR_EQ(list.items[0].text, "boom");
    ASSERT_STR_EQ(list.items[1].text, "bang");
    ck_diag_clear(&list);
}

TEST(parse_accumulates)
{
    ck_diaglist list;

    ck_diag_init(&list);
    ck_diag_parse(&list, "a.lisp:1: ERROR: one\n");
    ck_diag_parse(&list, "b.lisp:2: ERROR: two\n");
    ASSERT_EQ_INT(list.count, 2);
    ASSERT_STR_EQ(list.items[0].file, "a.lisp");
    ASSERT_STR_EQ(list.items[1].file, "b.lisp");
    ck_diag_clear(&list);
}

TEST(many_diagnostics_grow_the_list)
{
    ck_diaglist list;
    int32_t     i;

    ck_diag_init(&list);
    for (i = 0; i < 100; i++)
        ck_diag_parse(&list, "x.lisp:1: ERROR: boom\n");
    ASSERT_EQ_INT(list.count, 100);
    ck_diag_clear(&list);
}

TEST(empty_and_null_input)
{
    ck_diaglist list;
    ck_diag_init(&list);
    ASSERT_EQ_INT(ck_diag_parse(&list, ""), 0);
    ASSERT_EQ_INT(ck_diag_parse(&list, NULL), 0);
    ASSERT_EQ_INT(list.count, 0);
    ck_diag_clear(&list);
}

TEST(return_code_ladder)
{
    /* ARexx carries RESULT only with rc 0, so anything else needs a
     * LASTRESULT to recover the text -- including rc 5, where the command
     * actually succeeded with warnings. */
    ASSERT_EQ_INT(ck_rc_needs_lastresult(CK_RC_OK), 0);
    ASSERT_EQ_INT(ck_rc_needs_lastresult(CK_RC_WARN), 1);
    ASSERT_EQ_INT(ck_rc_needs_lastresult(CK_RC_ERROR), 1);
    ASSERT_EQ_INT(ck_rc_needs_lastresult(CK_RC_FATAL), 1);
}

int main(void)
{
    test_init();
    RUN(located_diagnostic);
    RUN(path_with_spaces_and_assigns);
    RUN(unlocated_diagnostic);
    RUN(message_containing_a_severity_word);
    RUN(non_diagnostic_lines);
    RUN(full_reply);
    RUN(the_log_section_is_not_parsed);
    RUN(truncation_is_seen_after_the_log);
    RUN(clean_reply);
    RUN(markers);
    RUN(crlf_and_missing_final_newline);
    RUN(parse_accumulates);
    RUN(many_diagnostics_grow_the_list);
    RUN(empty_and_null_input);
    RUN(return_code_ladder);
    REPORT();
}
