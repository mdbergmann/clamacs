/*
 * test_replmsg.c -- the commands clamiga's REPL thread sends to the editor.
 *
 * The strings here are what cl-amiga's tests/test_dev_commands.sh shows the
 * REPL thread sending (`SENT EDITOR|OUTPUT hello', `RESULT 0 CL-USER' with
 * the value on the next line), so the two ends are pinned to one wire
 * format from both sides.
 */

#include "test.h"
#include "rexx/replmsg.h"

TEST(output_keeps_its_text_verbatim)
{
    ck_replmsg m;

    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT hello\n", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_OUTPUT);
    ASSERT_STR_EQ(m.text, "hello\n");

    /* Leading blanks belong to the chunk: an indented line of output must
     * not lose its indentation.  Only the verb's own separator goes. */
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT   indented\n", &m), 1);
    ASSERT_STR_EQ(m.text, "  indented\n");

    /* A chunk with quotes -- balanced or not -- is text, not syntax. */
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT say \"hi", &m), 1);
    ASSERT_STR_EQ(m.text, "say \"hi");

    /* Several lines in one chunk (a WRITE-STRING with newlines inside). */
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT a\nb\nc\n", &m), 1);
    ASSERT_STR_EQ(m.text, "a\nb\nc\n");

    /* An empty chunk, both spellings. */
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT ", &m), 1);
    ASSERT_STR_EQ(m.text, "");
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUT", &m), 1);
    ASSERT_STR_EQ(m.text, "");
}

TEST(readline_has_no_argument)
{
    ck_replmsg m;

    ASSERT_EQ_INT(ck_replmsg_parse("READLINE", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_READLINE);
    ASSERT_EQ_INT(ck_replmsg_parse("READLINE\n", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_READLINE);
}

TEST(result_carries_rc_package_and_values)
{
    ck_replmsg m;

    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0 CL-USER\n5", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_RESULT);
    ASSERT_EQ_INT(m.rc, 0);
    ASSERT_STR_EQ(m.package, "CL-USER");
    ASSERT_STR_EQ(m.text, "5");

    /* Several values, one per line, and the no-values marker. */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0 CL-USER\n1\n2\n3", &m), 1);
    ASSERT_STR_EQ(m.text, "1\n2\n3");
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0 CL-USER\n; No values", &m), 1);
    ASSERT_STR_EQ(m.text, "; No values");

    /* An error: rc 10 and the text after the newline. */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 10 EXT.DEV\nERROR: boom", &m), 1);
    ASSERT_EQ_INT(m.rc, 10);
    ASSERT_STR_EQ(m.package, "EXT.DEV");
    ASSERT_STR_EQ(m.text, "ERROR: boom");

    /* No newline at all: nothing follows the header. */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0 CL-USER", &m), 1);
    ASSERT_STR_EQ(m.text, "");
}

TEST(verbs_match_like_mui_does)
{
    ck_replmsg m;

    /* MUI matches its command names case-insensitively; so do we. */
    ASSERT_EQ_INT(ck_replmsg_parse("output x", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_OUTPUT);
    ASSERT_EQ_INT(ck_replmsg_parse("Result 0 CL-USER\n1", &m), 1);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_RESULT);

    /* But a verb is a whole word: OUTPUTS is not OUTPUT. */
    ASSERT_EQ_INT(ck_replmsg_parse("OUTPUTS x", &m), 0);
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_NONE);
}

TEST(malformed_and_foreign_commands_are_rejected)
{
    ck_replmsg m;

    ASSERT_EQ_INT(ck_replmsg_parse("STATUS", &m), 0);
    ASSERT_EQ_INT(ck_replmsg_parse("", &m), 0);
    ASSERT_EQ_INT(ck_replmsg_parse(NULL, &m), 0);
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT", &m), 0);          /* no rc */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT x CL-USER", &m), 0); /* no rc */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0", &m), 0);        /* no package */
    ASSERT_EQ_INT(ck_replmsg_parse("RESULT 0\n5", &m), 0);     /* no package */

    /* A rejected message leaves OUT in a state a caller can read safely. */
    ASSERT_EQ_INT(m.kind, CK_REPLMSG_NONE);
    ASSERT_STR_EQ(m.text, "");
}

int main(void)
{
    test_init();
    RUN(output_keeps_its_text_verbatim);
    RUN(readline_has_no_argument);
    RUN(result_carries_rc_package_and_values);
    RUN(verbs_match_like_mui_does);
    RUN(malformed_and_foreign_commands_are_rejected);
    REPORT();
}
