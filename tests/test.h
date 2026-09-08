#ifndef CLAMACS_TEST_H
#define CLAMACS_TEST_H

/*
 * Minimal test framework for clamacs, in the style of cl-amiga's tests/test.h.
 *
 *   TEST(name) { ASSERT(...); ASSERT_EQ_INT(...); }
 *   int main(void) { RUN(name); REPORT(); }
 *
 * Everything the suite covers is pure C that takes no MUI or OS types, which
 * is a design rule of the editor (specs/clamacs-ide.md, "Testing") and not an
 * accident: the keymap engine, the Lisp tokenizer, the sexp scanner, the
 * indenter, the diagnostic parser and the request queue all run here on the
 * host, where a failing assertion costs a second instead of an emulator boot.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

static int test_pass = 0;
static int test_fail = 0;
static int test_current_failed = 0;
static volatile const char *test_current_name = "";
static volatile unsigned int test_current_name_len = 0;

/* Per-test watchdog (seconds).  A scanner that loops forever on a malformed
 * buffer is a real failure mode here — the sexp scanner and the tokenizer
 * both advance by cases — so a hang must fail loudly rather than stall the
 * suite.  TEST_WATCHDOG_SECS=0 disables it. */
#ifndef TEST_WATCHDOG_DEFAULT_SECS
#define TEST_WATCHDOG_DEFAULT_SECS 60
#endif

static volatile unsigned int test_watchdog_secs = TEST_WATCHDOG_DEFAULT_SECS;

static void test_watchdog_handler(int sig)
{
    static const char msg[] = "\n*** TEST WATCHDOG: timed out in test: ";
    (void)sig;
    /* async-signal-safe: write() and the literal test name only */
    write(2, msg, sizeof(msg) - 1);
    if (test_current_name)
        write(2, (const char *)test_current_name, test_current_name_len);
    write(2, "\n", 1);
    abort();
}

static void test_watchdog_arm(unsigned int secs)
{
    alarm(secs);
}

static void test_setup_once(void)
{
    static int done = 0;
    const char *env;
    if (done) return;
    done = 1;
    setvbuf(stdout, NULL, _IONBF, 0);
    env = getenv("TEST_WATCHDOG_SECS");
    if (env)
        test_watchdog_secs = (unsigned int)strtoul(env, NULL, 10);
    if (test_watchdog_secs)
        signal(SIGALRM, test_watchdog_handler);
}

#define TEST(name) static void test_##name(void)

#define RUN(name) do { \
    test_setup_once(); \
    test_current_name = #name; \
    test_current_name_len = (unsigned int)(sizeof(#name) - 1); \
    test_current_failed = 0; \
    if (test_watchdog_secs) test_watchdog_arm(test_watchdog_secs); \
    test_##name(); \
    if (test_watchdog_secs) test_watchdog_arm(0); \
    if (test_current_failed) { \
        printf("FAIL  %s\n", #name); \
        test_fail++; \
    } else { \
        printf("  ok  %s\n", #name); \
        test_pass++; \
    } \
    fflush(stdout); \
} while (0)

#define ASSERT(cond) do { \
    if (!(cond)) { \
        printf("  ASSERT FAILED: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        test_current_failed = 1; \
    } \
} while (0)

#define ASSERT_EQ_INT(a, b) do { \
    long _a = (long)(a), _b = (long)(b); \
    if (_a != _b) { \
        printf("  ASSERT_EQ_INT FAILED: %s:%d: %s = %ld, expected %ld\n", \
               __FILE__, __LINE__, #a, _a, _b); \
        test_current_failed = 1; \
    } \
} while (0)

#define ASSERT_STR_EQ(a, b) do { \
    const char *_a = (a), *_b = (b); \
    if (_a == NULL || _b == NULL || strcmp(_a, _b) != 0) { \
        printf("  ASSERT_STR_EQ FAILED: %s:%d: \"%s\" != \"%s\"\n", \
               __FILE__, __LINE__, _a ? _a : "(null)", _b ? _b : "(null)"); \
        test_current_failed = 1; \
    } \
} while (0)

#define REPORT() do { \
    printf("\n%d passed, %d failed, %d total\n", \
           test_pass, test_fail, test_pass + test_fail); \
    return test_fail > 0 ? 1 : 0; \
} while (0)

static void test_init(void)
{
    test_setup_once();
    (void)test_pass;
    (void)test_fail;
    (void)test_current_failed;
    (void)test_current_name;
    (void)test_current_name_len;
    (void)test_watchdog_arm;
}

#endif /* CLAMACS_TEST_H */
