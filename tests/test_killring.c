/*
 * test_killring.c -- the kill ring.
 */

#include "test.h"
#include "emacs/killring.h"

static int32_t slen(const char *s) { return (int32_t)strlen(s); }

TEST(empty_ring_yanks_nothing)
{
    ck_killring r;
    ck_kill_init(&r);
    ASSERT(ck_kill_current(&r) == NULL);
    ASSERT(ck_kill_rotate(&r) == NULL);
    ck_kill_clear(&r);
}

TEST(push_and_yank)
{
    ck_killring r;
    ck_kill_init(&r);

    ASSERT_EQ_INT(ck_kill_push(&r, "one", 3), 0);
    ASSERT_STR_EQ(ck_kill_current(&r), "one");

    ASSERT_EQ_INT(ck_kill_push(&r, "two", 3), 0);
    ASSERT_STR_EQ(ck_kill_current(&r), "two");
    ASSERT_EQ_INT(r.count, 2);

    ck_kill_clear(&r);
}

TEST(consecutive_kills_join)
{
    ck_killring r;
    ck_kill_init(&r);

    /* Three C-k on the same line make one entry, so C-y brings the whole
     * line back rather than its last third. */
    ck_kill_push(&r, "one ", 4);
    ck_kill_append(&r, "two ", 4);
    ck_kill_append(&r, "three", 5);
    ASSERT_STR_EQ(ck_kill_current(&r), "one two three");
    ASSERT_EQ_INT(r.count, 1);

    ck_kill_clear(&r);
}

TEST(backward_kills_join_at_the_front)
{
    ck_killring r;
    ck_kill_init(&r);

    /* M-DEL twice kills "two " then "one ", and the yank must read
     * forwards. */
    ck_kill_push(&r, "two ", 4);
    ck_kill_prepend(&r, "one ", 4);
    ASSERT_STR_EQ(ck_kill_current(&r), "one two ");

    ck_kill_clear(&r);
}

TEST(append_to_empty_ring_pushes)
{
    ck_killring r;
    ck_kill_init(&r);
    ASSERT_EQ_INT(ck_kill_append(&r, "x", 1), 0);
    ASSERT_STR_EQ(ck_kill_current(&r), "x");
    ASSERT_EQ_INT(r.count, 1);
    ck_kill_clear(&r);
}

TEST(yank_pop_walks_back)
{
    ck_killring r;
    ck_kill_init(&r);

    ck_kill_push(&r, "first", 5);
    ck_kill_push(&r, "second", 6);
    ck_kill_push(&r, "third", 5);

    ASSERT_STR_EQ(ck_kill_current(&r), "third");
    ASSERT_STR_EQ(ck_kill_rotate(&r), "second");
    ASSERT_STR_EQ(ck_kill_rotate(&r), "first");
    /* And wraps. */
    ASSERT_STR_EQ(ck_kill_rotate(&r), "third");

    /* Anything that is not a yank starts over at the newest kill. */
    ck_kill_rotate(&r);
    ck_kill_reset_yank(&r);
    ASSERT_STR_EQ(ck_kill_current(&r), "third");

    ck_kill_clear(&r);
}

TEST(a_new_kill_resets_the_rotation)
{
    ck_killring r;
    ck_kill_init(&r);

    ck_kill_push(&r, "a", 1);
    ck_kill_push(&r, "b", 1);
    ck_kill_rotate(&r);
    ASSERT_STR_EQ(ck_kill_current(&r), "a");

    ck_kill_push(&r, "c", 1);
    ASSERT_STR_EQ(ck_kill_current(&r), "c");

    ck_kill_clear(&r);
}

TEST(ring_wraps_and_drops_the_oldest)
{
    ck_killring r;
    char        text[8];
    int32_t     i;

    ck_kill_init(&r);
    for (i = 0; i < CK_KILL_RING_SIZE + 5; i++) {
        text[0] = (char)('a' + (i % 26));
        text[1] = '\0';
        ASSERT_EQ_INT(ck_kill_push(&r, text, 1), 0);
    }
    ASSERT_EQ_INT(r.count, CK_KILL_RING_SIZE);

    /* Rotating all the way round comes home without ever leaving the ring. */
    for (i = 0; i < CK_KILL_RING_SIZE; i++)
        ASSERT(ck_kill_rotate(&r) != NULL);
    ASSERT_STR_EQ(ck_kill_current(&r),
                  (text[0] = (char)('a' + ((CK_KILL_RING_SIZE + 4) % 26)), text));

    ck_kill_clear(&r);
}

TEST(embedded_newlines_survive)
{
    ck_killring r;
    const char *block = "(defun foo ()\n  42)\n";

    ck_kill_init(&r);
    ck_kill_push(&r, block, slen(block));
    ASSERT_STR_EQ(ck_kill_current(&r), block);
    ck_kill_clear(&r);
}

int main(void)
{
    test_init();
    RUN(empty_ring_yanks_nothing);
    RUN(push_and_yank);
    RUN(consecutive_kills_join);
    RUN(backward_kills_join_at_the_front);
    RUN(append_to_empty_ring_pushes);
    RUN(yank_pop_walks_back);
    RUN(a_new_kill_resets_the_rotation);
    RUN(ring_wraps_and_drops_the_oldest);
    RUN(embedded_newlines_survive);
    REPORT();
}
