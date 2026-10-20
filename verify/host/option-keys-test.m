/* The macOS shim's Option keys, as a table (verify/host/option-keys.sh).
 *
 * Includes clamacs-host.m itself, so option_key_js is the shim's own, and
 * hands it what Cocoa reports for keys on a German keyboard: `characters'
 * (the Option level) and `charactersIgnoringModifiers' (Shift alone),
 * with the left and right Option bits.  The left Option is Meta, the right
 * composes, both together are Meta with the composed character -- M-{ on
 * a layout whose braces live under Option -- and a dead key under the
 * right Option alone is left to WebKit.  Exits 1 and names the first row
 * that disagrees. */
#include "../../host/clamacs-host.m"

struct row {
    const char *name;
    BOOL left, right, ctrl;
    const char *composed, *plain;
    const char *want;      /* the JavaScript, "" for a swallowed key, NULL for Cocoa's */
};

static NSString *js(unsigned c, const char *ctrl, const char *alt)
{
    return [NSString stringWithFormat:
        @"simulateKey(\"\\u%04x\",{code:\"\",ctrlKey:%s,altKey:%s,shiftKey:false})", c, ctrl, alt];
}

int main(void)
{
    @autoreleasepool {
        const struct row rows[] = {
            {"left Option-8 is M-8 (a digit argument)",      YES, NO,  NO, "{",      "8", "M8"},
            {"left+right Option-8 is M-{",                   YES, YES, NO, "{",      "8", "M{"},
            {"right Option-8 types {",                       NO,  YES, NO, "{",      "8", "{"},
            {"right Option-9 types }",                       NO,  YES, NO, "}",      "9", "}"},
            {"right Option-N (dead) composes in WebKit",     NO,  YES, NO, "",       "n", NULL},
            {"left+right Option-N is M-n",                   YES, YES, NO, "",       "n", "Mn"},
            {"right Option-F (florin) is swallowed",         NO,  YES, NO, "\xc6\x92", "f", ""},
            {"left+right Option-F is M-f",                   YES, YES, NO, "\xc6\x92", "f", "Mf"},
            {"an Option of unknown side is Meta",            NO,  NO,  NO, "{",      "8", "M8"},
            {"Control makes the right Option Meta (C-M-x)",  NO,  YES, YES, "\x18",  "x", "CMx"},
            {"left Option with an arrow is Cocoa's",         YES, NO,  NO, "\xef\x9c\x82", "\xef\x9c\x82", NULL},
            {"left Option-; (Shift+Comma) is M-;",           YES, NO,  NO, "\xe2\x80\xa6", ";", "M;"},
        };
        int failed = 0;
        for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
            const struct row *r = &rows[i];
            NSEventModifierFlags mods = NSEventModifierFlagOption | (r->ctrl ? NSEventModifierFlagControl : 0);
            NSString *got = option_key_js(mods, r->left, r->right,
                                          [NSString stringWithUTF8String:r->composed],
                                          [NSString stringWithUTF8String:r->plain]);
            NSString *want = nil;
            if (r->want != NULL) {
                if (r->want[0] == '\0')
                    want = @"";
                else {
                    const char *p = r->want;
                    BOOL ctrl = NO, alt = NO;
                    for (;; p++) {
                        if (*p == 'C') ctrl = YES;
                        else if (*p == 'M') alt = YES;
                        else break;
                    }
                    want = js((unsigned char)*p, ctrl ? "true" : "false", alt ? "true" : "false");
                }
            }
            BOOL ok = (got == nil && want == nil) || (got != nil && want != nil && [got isEqualToString:want]);
            printf("%s: %s\n", ok ? "OK" : "FAIL", r->name);
            if (!ok) {
                printf("  want %s\n  got  %s\n", want ? want.UTF8String : "(nil)", got ? got.UTF8String : "(nil)");
                failed++;
            }
        }
        printf("OPTION-KEYS: %s\n", failed ? "FAIL" : "PASS");
        return failed ? 1 : 0;
    }
}
