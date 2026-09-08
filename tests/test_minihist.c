/*
 * test_minihist.c -- minibuffer history and generic completion.
 */

#include "test.h"
#include "emacs/minihist.h"

TEST(empty_history)
{
    ck_history h;
    ck_hist_init(&h);
    ASSERT(ck_hist_prev(&h) == NULL);
    ASSERT(ck_hist_next(&h) == NULL);
    ASSERT(ck_hist_nth(&h, 0) == NULL);
    ck_hist_clear(&h);
}

TEST(add_and_walk)
{
    ck_history h;
    ck_hist_init(&h);

    ck_hist_add(&h, "first");
    ck_hist_add(&h, "second");
    ck_hist_add(&h, "third");

    ASSERT_STR_EQ(ck_hist_prev(&h), "third");
    ASSERT_STR_EQ(ck_hist_prev(&h), "second");
    ASSERT_STR_EQ(ck_hist_prev(&h), "first");
    ASSERT(ck_hist_prev(&h) == NULL);        /* the end of the ring */

    ASSERT_STR_EQ(ck_hist_next(&h), "second");
    ASSERT_STR_EQ(ck_hist_next(&h), "third");
    ASSERT(ck_hist_next(&h) == NULL);        /* back to what was being typed */

    ck_hist_clear(&h);
}

TEST(repeats_and_blanks_are_dropped)
{
    ck_history h;
    ck_hist_init(&h);

    ck_hist_add(&h, "same");
    ck_hist_add(&h, "same");
    ck_hist_add(&h, "");
    ck_hist_add(&h, NULL);
    ASSERT_EQ_INT(h.count, 1);

    ck_hist_clear(&h);
}

TEST(adding_resets_the_cursor)
{
    ck_history h;
    ck_hist_init(&h);

    ck_hist_add(&h, "a");
    ck_hist_add(&h, "b");
    ck_hist_prev(&h);
    ck_hist_add(&h, "c");
    ASSERT_STR_EQ(ck_hist_prev(&h), "c");

    ck_hist_clear(&h);
}

TEST(history_wraps)
{
    ck_history h;
    char       text[8];
    int32_t    i;

    ck_hist_init(&h);
    for (i = 0; i < CK_HIST_SIZE + 4; i++) {
        text[0] = 'a';
        text[1] = (char)('0' + (i % 10));
        text[2] = (char)('0' + (i / 10));
        text[3] = '\0';
        ck_hist_add(&h, text);
    }
    ASSERT_EQ_INT(h.count, CK_HIST_SIZE);
    ASSERT_STR_EQ(ck_hist_nth(&h, 0), text);
    ASSERT(ck_hist_nth(&h, CK_HIST_SIZE) == NULL);

    ck_hist_clear(&h);
}

static const char *const files[] = {
    "boot.lisp", "boot.fasl", "clos.lisp", "ffi.lisp", "dev-commands.lisp"
};

TEST(completion_common_prefix)
{
    const char *hits[8];
    char        common[32];
    int32_t     n;

    n = ck_complete(files, 5, "boot", hits, 8, common, sizeof common);
    ASSERT_EQ_INT(n, 2);
    ASSERT_STR_EQ(common, "boot.");

    n = ck_complete(files, 5, "c", hits, 8, common, sizeof common);
    ASSERT_EQ_INT(n, 1);
    ASSERT_STR_EQ(common, "clos.lisp");
    ASSERT_STR_EQ(hits[0], "clos.lisp");

    n = ck_complete(files, 5, "", hits, 8, common, sizeof common);
    ASSERT_EQ_INT(n, 5);
    ASSERT_STR_EQ(common, "");   /* nothing in common */

    n = ck_complete(files, 5, "zz", hits, 8, common, sizeof common);
    ASSERT_EQ_INT(n, 0);
    ASSERT_STR_EQ(common, "");
}

TEST(completion_respects_max)
{
    const char *hits[2];
    int32_t     n = ck_complete(files, 5, "", hits, 2, NULL, 0);

    ASSERT_EQ_INT(n, 5);            /* the true count */
    ASSERT_STR_EQ(hits[0], "boot.lisp");
    ASSERT_STR_EQ(hits[1], "boot.fasl");
}

TEST(completion_truncates_into_a_short_buffer)
{
    char    common[4];
    int32_t n = ck_complete(files, 5, "boot", NULL, 0, common, sizeof common);

    ASSERT_EQ_INT(n, 2);
    ASSERT_STR_EQ(common, "boo");   /* NUL-terminated, never overrun */
}

TEST(completion_handles_no_candidates)
{
    char common[8];
    ASSERT_EQ_INT(ck_complete(NULL, 0, "x", NULL, 0, common, sizeof common), 0);
    ASSERT_EQ_INT(ck_complete(files, 0, "x", NULL, 0, common, sizeof common), 0);
}

int main(void)
{
    test_init();
    RUN(empty_history);
    RUN(add_and_walk);
    RUN(repeats_and_blanks_are_dropped);
    RUN(adding_resets_the_cursor);
    RUN(history_wraps);
    RUN(completion_common_prefix);
    RUN(completion_respects_max);
    RUN(completion_truncates_into_a_short_buffer);
    RUN(completion_handles_no_candidates);
    REPORT();
}
