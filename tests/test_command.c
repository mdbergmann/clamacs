/*
 * test_command.c -- the command table and completion.
 */

#include "test.h"
#include "emacs/command.h"

TEST(name_and_lookup_agree)
{
    int16_t i;

    /* Every id names a command, and that name looks the id up again.  This
     * is the property the ARexx port relies on when it turns a string from
     * another program into something to run. */
    for (i = 0; i < (int16_t)CK_CMD_COUNT; i++) {
        const char *name = ck_command_name(i);
        ASSERT(name != NULL);
        ASSERT(name[0] != '\0');
        ASSERT_EQ_INT(ck_command_lookup(name), i);
    }
}

TEST(names_are_unique)
{
    int16_t i, j;

    for (i = 0; i < (int16_t)CK_CMD_COUNT; i++) {
        for (j = (int16_t)(i + 1); j < (int16_t)CK_CMD_COUNT; j++) {
            if (strcmp(ck_command_name(i), ck_command_name(j)) == 0) {
                printf("  duplicate command name: %s\n", ck_command_name(i));
                test_current_failed = 1;
            }
        }
    }
}

TEST(lookup_rejects_junk)
{
    ASSERT_EQ_INT(ck_command_lookup("no-such-command"), CK_CMD_NONE);
    ASSERT_EQ_INT(ck_command_lookup(""), CK_CMD_NONE);
    ASSERT_EQ_INT(ck_command_lookup(NULL), CK_CMD_NONE);
    /* Case matters: an ARexx macro sending FIND-FILE has a bug. */
    ASSERT_EQ_INT(ck_command_lookup("FIND-FILE"), CK_CMD_NONE);
}

TEST(name_rejects_out_of_range)
{
    ASSERT(ck_command_name(-1) == NULL);
    ASSERT(ck_command_name((int16_t)CK_CMD_COUNT) == NULL);
    ASSERT(ck_command_name(30000) == NULL);
}

TEST(completion_finds_prefix)
{
    const char *hits[32];
    char        common[64];
    int32_t     n;

    n = ck_command_complete("beginning-of-", hits, 32, common, sizeof common);
    ASSERT_EQ_INT(n, 3);   /* line, buffer, defun */
    ASSERT_STR_EQ(common, "beginning-of-");

    n = ck_command_complete("kill-r", hits, 32, common, sizeof common);
    ASSERT_EQ_INT(n, 2);   /* kill-region, kill-ring-save */
    ASSERT_STR_EQ(common, "kill-r");

    n = ck_command_complete("yank-p", hits, 32, common, sizeof common);
    ASSERT_EQ_INT(n, 1);
    ASSERT_STR_EQ(hits[0], "yank-pop");
    ASSERT_STR_EQ(common, "yank-pop");   /* a unique match completes fully */
}

TEST(completion_empty_prefix_is_everything)
{
    int32_t n = ck_command_complete("", NULL, 0, NULL, 0);
    ASSERT_EQ_INT(n, (int32_t)CK_CMD_COUNT);
}

TEST(completion_reports_more_than_it_returns)
{
    const char *hits[2];
    int32_t     n = ck_command_complete("", hits, 2, NULL, 0);

    /* The minibuffer shows a few and says how many there are. */
    ASSERT_EQ_INT(n, (int32_t)CK_CMD_COUNT);
    ASSERT(hits[0] != NULL);
}

TEST(completion_no_match)
{
    const char *hits[4];
    char        common[16];
    int32_t     n = ck_command_complete("zzz", hits, 4, common, sizeof common);

    ASSERT_EQ_INT(n, 0);
    ASSERT_STR_EQ(common, "");
}

TEST(clamacs_commands_are_namespaced)
{
    /* The commands that talk to clamiga carry the editor's own prefix, so
     * `M-x' completion separates them from ordinary editing commands. */
    const char *hits[32];
    int32_t     n = ck_command_complete("clamacs-", hits, 32, NULL, 0);
    ASSERT(n >= 8);
    ASSERT(ck_command_lookup("clamacs-load-buffer") != CK_CMD_NONE);
    ASSERT(ck_command_lookup("clamacs-eval-defun") != CK_CMD_NONE);
}

int main(void)
{
    test_init();
    RUN(name_and_lookup_agree);
    RUN(names_are_unique);
    RUN(lookup_rejects_junk);
    RUN(name_rejects_out_of_range);
    RUN(completion_finds_prefix);
    RUN(completion_empty_prefix_is_everything);
    RUN(completion_reports_more_than_it_returns);
    RUN(completion_no_match);
    RUN(clamacs_commands_are_namespaced);
    REPORT();
}
