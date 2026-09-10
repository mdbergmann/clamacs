/*
 * test_locstack.c -- where `M-,' goes back to.
 */

#include "test.h"
#include "emacs/locstack.h"

TEST(empty_stack)
{
    ck_locstack s;
    ck_location loc;

    ck_locstack_init(&s);
    ASSERT_EQ_INT(ck_locstack_depth(&s), 0);
    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 0);
    ASSERT_EQ_INT(ck_locstack_pop(&s, NULL), 0);
}

TEST(last_in_first_out)
{
    ck_locstack s;
    ck_location loc;

    ck_locstack_init(&s);
    ck_locstack_push(&s, "Work:a.lisp", 1, 10);
    ck_locstack_push(&s, "Work:b.lisp", 2, 20);
    ASSERT_EQ_INT(ck_locstack_depth(&s), 2);

    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 1);
    ASSERT_STR_EQ(loc.path, "Work:b.lisp");
    ASSERT_EQ_INT(loc.id, 2);
    ASSERT_EQ_INT(loc.index, 20);

    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 1);
    ASSERT_STR_EQ(loc.path, "Work:a.lisp");
    ASSERT_EQ_INT(loc.index, 10);

    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 0);
}

TEST(a_scratch_window_has_no_path)
{
    ck_locstack s;
    ck_location loc;

    ck_locstack_init(&s);
    ck_locstack_push(&s, NULL, 7, 0);
    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 1);
    ASSERT_STR_EQ(loc.path, "");
    ASSERT_EQ_INT(loc.id, 7);
}

TEST(overflow_drops_the_oldest)
{
    ck_locstack s;
    ck_location loc;
    int32_t     i;

    ck_locstack_init(&s);
    for (i = 0; i < CK_LOCSTACK_SIZE + 3; i++)
        ck_locstack_push(&s, "f", (uint32_t)i, i);
    ASSERT_EQ_INT(ck_locstack_depth(&s), CK_LOCSTACK_SIZE);

    /* The newest are all there, in order ... */
    for (i = CK_LOCSTACK_SIZE + 2; i >= 3; i--) {
        ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 1);
        ASSERT_EQ_INT(loc.index, i);
    }
    /* ... and the three oldest are gone. */
    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 0);
}

TEST(a_long_path_is_cut_not_overrun)
{
    ck_locstack s;
    ck_location loc;
    char        path[CK_LOC_PATH_MAX + 50];

    memset(path, 'x', sizeof path - 1);
    path[sizeof path - 1] = '\0';

    ck_locstack_init(&s);
    ck_locstack_push(&s, path, 1, 0);
    ASSERT_EQ_INT(ck_locstack_pop(&s, &loc), 1);
    ASSERT_EQ_INT((int32_t)strlen(loc.path), CK_LOC_PATH_MAX - 1);
}

int main(void)
{
    test_init();
    RUN(empty_stack);
    RUN(last_in_first_out);
    RUN(a_scratch_window_has_no_path);
    RUN(overflow_drops_the_oldest);
    RUN(a_long_path_is_cut_not_overrun);
    REPORT();
}
