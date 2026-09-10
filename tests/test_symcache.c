/*
 * test_symcache.c -- the arglist cache.
 */

#include "test.h"
#include "rexx/symcache.h"

TEST(unknown_miss_and_hit_are_three_different_answers)
{
    ck_symcache c;
    ck_symcache_init(&c);

    /* Never asked: NULL, the one case that costs a round trip. */
    ASSERT(ck_symcache_get(&c, "CL-USER|foo") == NULL);

    ASSERT_EQ_INT(ck_symcache_put(&c, "CL-USER|foo", "(a &optional b)"), 0);
    ASSERT_STR_EQ(ck_symcache_get(&c, "CL-USER|foo"), "(a &optional b)");

    /* Asked, and clamiga had nothing: "" -- remembered so the cursor
     * entering a binding list does not ask about `x' every time. */
    ASSERT_EQ_INT(ck_symcache_put(&c, "CL-USER|x", ""), 0);
    ASSERT_STR_EQ(ck_symcache_get(&c, "CL-USER|x"), "");
    ASSERT_EQ_INT(ck_symcache_put(&c, "CL-USER|y", NULL), 0);
    ASSERT_STR_EQ(ck_symcache_get(&c, "CL-USER|y"), "");

    ck_symcache_clear(&c);
    ASSERT(ck_symcache_get(&c, "CL-USER|foo") == NULL);
}

TEST(keys_are_symbols_so_case_does_not_matter)
{
    ck_symcache c;
    ck_symcache_init(&c);

    ck_symcache_put(&c, "cl-user|Mapcar", "(fn list &rest more)");
    ASSERT_STR_EQ(ck_symcache_get(&c, "CL-USER|MAPCAR"), "(fn list &rest more)");
    ASSERT_STR_EQ(ck_symcache_get(&c, "Cl-User|mapcar"), "(fn list &rest more)");

    /* A package is part of the key: the same name elsewhere is another
     * symbol. */
    ASSERT(ck_symcache_get(&c, "FOO|mapcar") == NULL);

    ck_symcache_clear(&c);
}

TEST(putting_again_updates_in_place)
{
    ck_symcache c;
    ck_symcache_init(&c);

    ck_symcache_put(&c, "P|f", "(a)");
    ck_symcache_put(&c, "P|f", "(a b)");     /* redefined with more arguments */
    ASSERT_STR_EQ(ck_symcache_get(&c, "P|f"), "(a b)");
    ASSERT_EQ_INT(c.next, 1);                /* one slot used, not two */

    ck_symcache_clear(&c);
}

TEST(the_oldest_entry_goes_first)
{
    ck_symcache c;
    char        key[32];
    int32_t     i;

    ck_symcache_init(&c);
    for (i = 0; i < CK_SYMCACHE_SIZE + 5; i++) {
        snprintf(key, sizeof key, "P|sym%d", (int)i);
        ASSERT_EQ_INT(ck_symcache_put(&c, key, "(x)"), 0);
    }
    /* The first five were replaced; the rest are still there. */
    for (i = 0; i < 5; i++) {
        snprintf(key, sizeof key, "P|sym%d", (int)i);
        ASSERT(ck_symcache_get(&c, key) == NULL);
    }
    for (i = 5; i < CK_SYMCACHE_SIZE + 5; i++) {
        snprintf(key, sizeof key, "P|sym%d", (int)i);
        ASSERT(ck_symcache_get(&c, key) != NULL);
    }

    ck_symcache_clear(&c);
}

TEST(junk_keys_are_refused)
{
    ck_symcache c;
    ck_symcache_init(&c);
    ASSERT_EQ_INT(ck_symcache_put(&c, "", "(x)"), -1);
    ASSERT_EQ_INT(ck_symcache_put(&c, NULL, "(x)"), -1);
    ASSERT(ck_symcache_get(&c, "") == NULL);
    ASSERT(ck_symcache_get(&c, NULL) == NULL);
    ck_symcache_clear(&c);
}

int main(void)
{
    test_init();
    RUN(unknown_miss_and_hit_are_three_different_answers);
    RUN(keys_are_symbols_so_case_does_not_matter);
    RUN(putting_again_updates_in_place);
    RUN(the_oldest_entry_goes_first);
    RUN(junk_keys_are_refused);
    REPORT();
}
