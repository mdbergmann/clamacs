/*
 * test_dbgmsg.c -- the lines of the debugger and inspector replies.
 *
 * The strings are what cl-amiga's tests/test_dev_commands.sh shows the
 * other end sending (`0: dbg-fn  <file>:27', `ARG0 = 3', `CONS 1 2'), so
 * the formats are pinned from both sides.
 */

#include "test.h"
#include "rexx/dbgmsg.h"

TEST(lines_are_split_without_their_newlines)
{
    const char *text = "first\nsecond\r\n\nlast";
    const char *p = text;
    char        line[16];

    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 1);
    ASSERT_STR_EQ(line, "first");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 1);
    ASSERT_STR_EQ(line, "second");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 1);
    ASSERT_STR_EQ(line, "");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 1);
    ASSERT_STR_EQ(line, "last");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 0);
    ASSERT_STR_EQ(line, "");

    /* A long line is cut to the buffer, and the cursor still moves past
     * all of it. */
    p = "0123456789\nnext";
    ASSERT_EQ_INT(ck_dbg_line(&p, line, 4), 1);
    ASSERT_STR_EQ(line, "012");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, 4), 1);
    ASSERT_STR_EQ(line, "nex");
    ASSERT_EQ_INT(ck_dbg_line(&p, line, 4), 0);

    p = NULL;
    ASSERT_EQ_INT(ck_dbg_line(&p, line, (int32_t)sizeof line), 0);
}

TEST(row_index_is_the_leading_number)
{
    ASSERT_EQ_INT(ck_dbg_row_index("0: ABORT Return to the REPL"), 0);
    ASSERT_EQ_INT(ck_dbg_row_index("12: Cdr = (2 3)"), 12);
    ASSERT_EQ_INT(ck_dbg_row_index("ARG0 = 3"), -1);
    ASSERT_EQ_INT(ck_dbg_row_index("SIMPLE-ERROR: boom"), -1);
    ASSERT_EQ_INT(ck_dbg_row_index(": no"), -1);
    ASSERT_EQ_INT(ck_dbg_row_index(""), -1);
    ASSERT_EQ_INT(ck_dbg_row_index(NULL), -1);
}

TEST(frame_location_is_file_and_line_after_two_blanks)
{
    char    file[64];
    int32_t line = 0;

    ASSERT_EQ_INT(ck_dbg_frame_location("0: dbg-fn  T:dbg.lisp:27", file,
                                        (int32_t)sizeof file, &line), 1);
    ASSERT_STR_EQ(file, "T:dbg.lisp");
    ASSERT_EQ_INT(line, 27);

    /* An Amiga path keeps its device colon; a path with a blank in it is
     * still one file. */
    ASSERT_EQ_INT(ck_dbg_frame_location("3: foo  Work:my src/a.lisp:5", file,
                                        (int32_t)sizeof file, &line), 1);
    ASSERT_STR_EQ(file, "Work:my src/a.lisp");
    ASSERT_EQ_INT(line, 5);

    /* No location: an anonymous frame, a frame with a name only. */
    ASSERT_EQ_INT(ck_dbg_frame_location("1: <anonymous>", file,
                                        (int32_t)sizeof file, &line), 0);
    ASSERT_EQ_INT(ck_dbg_frame_location("1: foo", file,
                                        (int32_t)sizeof file, &line), 0);
    /* Two blanks but no line number after the last colon. */
    ASSERT_EQ_INT(ck_dbg_frame_location("1: foo  Work:", file,
                                        (int32_t)sizeof file, &line), 0);
    ASSERT_EQ_INT(ck_dbg_frame_location("1: foo  nocolon", file,
                                        (int32_t)sizeof file, &line), 0);
    ASSERT_EQ_INT(ck_dbg_frame_location(NULL, file, (int32_t)sizeof file, &line), 0);

    /* A file name longer than the buffer is cut, not overrun. */
    ASSERT_EQ_INT(ck_dbg_frame_location("0: f  abcdefghij:1", file, 4, &line), 1);
    ASSERT_STR_EQ(file, "abc");
    ASSERT_EQ_INT(line, 1);
}

TEST(inspect_header_carries_type_depth_and_count)
{
    char    type[32];
    int32_t depth = 0, count = 0;

    ASSERT_EQ_INT(ck_dbg_inspect_header("CONS 1 2\n(1 (2 3))\n0: Car = 1\n",
                                        type, (int32_t)sizeof type, &depth, &count), 1);
    ASSERT_STR_EQ(type, "CONS");
    ASSERT_EQ_INT(depth, 1);
    ASSERT_EQ_INT(count, 2);

    /* A leaf: no parts, and nothing after the object line. */
    ASSERT_EQ_INT(ck_dbg_inspect_header("FIXNUM 3 0\n42", type,
                                        (int32_t)sizeof type, &depth, &count), 1);
    ASSERT_STR_EQ(type, "FIXNUM");
    ASSERT_EQ_INT(depth, 3);
    ASSERT_EQ_INT(count, 0);

    /* The header alone, and one with a Windows-style line end. */
    ASSERT_EQ_INT(ck_dbg_inspect_header("SIMPLE-VECTOR 1 10", type,
                                        (int32_t)sizeof type, &depth, &count), 1);
    ASSERT_EQ_INT(count, 10);
    ASSERT_EQ_INT(ck_dbg_inspect_header("CONS 1 2\r\nx", type,
                                        (int32_t)sizeof type, &depth, &count), 1);
    ASSERT_EQ_INT(count, 2);

    /* Not a header: an error text, a missing number, nothing. */
    ASSERT_EQ_INT(ck_dbg_inspect_header("ERROR: no", type,
                                        (int32_t)sizeof type, &depth, &count), 0);
    ASSERT_EQ_INT(ck_dbg_inspect_header("CONS 1", type,
                                        (int32_t)sizeof type, &depth, &count), 0);
    ASSERT_EQ_INT(ck_dbg_inspect_header("CONS x 2", type,
                                        (int32_t)sizeof type, &depth, &count), 0);
    ASSERT_EQ_INT(ck_dbg_inspect_header("", type,
                                        (int32_t)sizeof type, &depth, &count), 0);
    ASSERT_EQ_INT(ck_dbg_inspect_header(NULL, type,
                                        (int32_t)sizeof type, &depth, &count), 0);

    /* A type name longer than the buffer is cut. */
    ASSERT_EQ_INT(ck_dbg_inspect_header("SIMPLE-VECTOR 1 2", type, 4, &depth, &count), 1);
    ASSERT_STR_EQ(type, "SIM");
}

int main(void)
{
    test_init();
    RUN(lines_are_split_without_their_newlines);
    RUN(row_index_is_the_leading_number);
    RUN(frame_location_is_file_and_line_after_two_blanks);
    RUN(inspect_header_carries_type_depth_and_count);
    REPORT();
}
