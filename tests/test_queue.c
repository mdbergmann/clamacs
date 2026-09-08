/*
 * test_queue.c -- the ARexx request queue.
 *
 * The rules under test are the ones that make the editor stay responsive
 * while clamiga compiles: one request on the wire at a time, everything else
 * in order behind it, and an automatic LASTRESULT that jumps the queue.
 */

#include "test.h"
#include "rexx/queue.h"

TEST(empty_queue)
{
    ck_queue q;
    ck_queue_init(&q);
    ASSERT_EQ_INT(ck_queue_depth(&q), 0);
    ASSERT(ck_queue_begin(&q) == NULL);
    ASSERT(ck_queue_inflight(&q) == NULL);
    ASSERT(ck_queue_complete(&q, 0) == NULL);
    ck_queue_clear(&q);
}

TEST(one_request_in_flight_at_a_time)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ASSERT(ck_queue_push(&q, "PING", CK_REQ_PING, 1) > 0);
    ASSERT(ck_queue_push(&q, "VERSION", CK_REQ_VERSION, 1) > 0);
    ASSERT_EQ_INT(ck_queue_depth(&q), 2);

    r = ck_queue_begin(&q);
    ASSERT(r != NULL);
    ASSERT_STR_EQ(r->command, "PING");
    ASSERT_EQ_INT(ck_queue_depth(&q), 1);
    ASSERT(ck_queue_inflight(&q) == r);

    /* The port serves one message at a time: nothing else may go out until
     * the reply comes back. */
    ASSERT(ck_queue_begin(&q) == NULL);

    r = ck_queue_complete(&q, CK_RC_OK);
    ASSERT_STR_EQ(r->command, "PING");
    ASSERT_EQ_INT(r->rc, CK_RC_OK);
    ck_queue_release(r);
    ASSERT(ck_queue_inflight(&q) == NULL);

    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "VERSION");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));

    ASSERT(ck_queue_begin(&q) == NULL);
    ck_queue_clear(&q);
}

TEST(fifo_order)
{
    ck_queue q;
    int32_t  i;

    ck_queue_init(&q);
    for (i = 0; i < 5; i++) {
        char cmd[16];
        snprintf(cmd, sizeof cmd, "EVAL %d", (int)i);
        ck_queue_push(&q, cmd, CK_REQ_EVAL, 7);
    }
    for (i = 0; i < 5; i++) {
        char        want[16];
        ck_request *r = ck_queue_begin(&q);
        snprintf(want, sizeof want, "EVAL %d", (int)i);
        ASSERT_STR_EQ(r->command, want);
        ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    }
    ck_queue_clear(&q);
}

TEST(serials_are_unique_and_increasing)
{
    ck_queue q;
    int32_t  a, b, c;

    ck_queue_init(&q);
    a = ck_queue_push(&q, "A", CK_REQ_EVAL, 0);
    b = ck_queue_push(&q, "B", CK_REQ_EVAL, 0);
    c = ck_queue_push_front(&q, "C", CK_REQ_LASTRESULT, 0, 0);
    ASSERT(a < b);
    ASSERT(b < c);
    ck_queue_clear(&q);
}

TEST(lastresult_jumps_the_queue)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ck_queue_push(&q, "LOAD foo.lisp", CK_REQ_LOAD, 1);
    ck_queue_push(&q, "EVAL (+ 1 2)", CK_REQ_EVAL, 1);

    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "LOAD foo.lisp");
    r = ck_queue_complete(&q, CK_RC_ERROR);
    ASSERT_EQ_INT(r->rc, CK_RC_ERROR);
    ck_queue_release(r);

    /* rc 10 means ARexx dropped the text, so LASTRESULT has to be the very
     * next thing on the wire -- if the queued EVAL ran first, *LAST-RESULT*
     * would already hold ITS output. */
    ck_queue_push_front(&q, "LASTRESULT", CK_REQ_LASTRESULT, 1,
                        CK_REQF_AUTO_LASTRESULT);

    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "LASTRESULT");
    ASSERT_EQ_INT(r->flags, CK_REQF_AUTO_LASTRESULT);
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));

    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "EVAL (+ 1 2)");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));

    ck_queue_clear(&q);
}

TEST(push_front_onto_an_empty_queue)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ck_queue_push_front(&q, "LASTRESULT", CK_REQ_LASTRESULT, 0, 0);
    ck_queue_push(&q, "PING", CK_REQ_PING, 0);
    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "LASTRESULT");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "PING");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    ck_queue_clear(&q);
}

TEST(cookies_travel_with_the_request)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ck_queue_push(&q, "LOAD a", CK_REQ_LOAD, 42);
    r = ck_queue_begin(&q);
    ASSERT_EQ_INT(r->cookie, 42);
    ASSERT_EQ_INT(r->kind, CK_REQ_LOAD);
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    ck_queue_clear(&q);
}

TEST(dropping_a_closed_window_leaves_the_wire_alone)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ck_queue_push(&q, "A", CK_REQ_EVAL, 1);
    ck_queue_push(&q, "B", CK_REQ_EVAL, 2);
    ck_queue_push(&q, "C", CK_REQ_EVAL, 1);
    ck_queue_push(&q, "D", CK_REQ_EVAL, 2);

    r = ck_queue_begin(&q);          /* A goes out, cookie 1 */
    ASSERT_STR_EQ(r->command, "A");

    /* Window 1 closes.  Its queued work goes; the message already on the
     * wire does not, because its reply is coming either way and cancelling
     * would desync the one-in-flight rule. */
    ASSERT_EQ_INT(ck_queue_drop_cookie(&q, 1), 1);
    ASSERT_EQ_INT(ck_queue_depth(&q), 2);
    ASSERT(ck_queue_inflight(&q) == r);

    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "B");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "D");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));

    ck_queue_clear(&q);
}

TEST(dropping_the_tail_keeps_the_queue_usable)
{
    ck_queue    q;
    ck_request *r;

    ck_queue_init(&q);
    ck_queue_push(&q, "A", CK_REQ_EVAL, 1);
    ck_queue_push(&q, "B", CK_REQ_EVAL, 2);
    ASSERT_EQ_INT(ck_queue_drop_cookie(&q, 2), 1);   /* drops the tail */
    ck_queue_push(&q, "C", CK_REQ_EVAL, 3);

    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "A");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    r = ck_queue_begin(&q);
    ASSERT_STR_EQ(r->command, "C");
    ck_queue_release(ck_queue_complete(&q, CK_RC_OK));
    ck_queue_clear(&q);
}

TEST(dropping_everything)
{
    ck_queue q;

    ck_queue_init(&q);
    ck_queue_push(&q, "A", CK_REQ_EVAL, 1);
    ck_queue_push(&q, "B", CK_REQ_EVAL, 1);
    ASSERT_EQ_INT(ck_queue_drop_cookie(&q, 1), 2);
    ASSERT_EQ_INT(ck_queue_depth(&q), 0);
    ASSERT(ck_queue_begin(&q) == NULL);
    ck_queue_clear(&q);
}

TEST(clear_releases_the_inflight_request_too)
{
    ck_queue q;

    ck_queue_init(&q);
    ck_queue_push(&q, "A", CK_REQ_EVAL, 1);
    ck_queue_push(&q, "B", CK_REQ_EVAL, 1);
    ck_queue_begin(&q);
    ck_queue_clear(&q);              /* must not leak the in-flight one */
    ASSERT_EQ_INT(ck_queue_depth(&q), 0);
    ASSERT(ck_queue_inflight(&q) == NULL);
}

int main(void)
{
    test_init();
    RUN(empty_queue);
    RUN(one_request_in_flight_at_a_time);
    RUN(fifo_order);
    RUN(serials_are_unique_and_increasing);
    RUN(lastresult_jumps_the_queue);
    RUN(push_front_onto_an_empty_queue);
    RUN(cookies_travel_with_the_request);
    RUN(dropping_a_closed_window_leaves_the_wire_alone);
    RUN(dropping_the_tail_keeps_the_queue_usable);
    RUN(dropping_everything);
    RUN(clear_releases_the_inflight_request_too);
    REPORT();
}
