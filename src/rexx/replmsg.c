/*
 * replmsg.c -- see replmsg.h.
 */

#include "replmsg.h"

#include <string.h>

static int32_t rm_lower(int32_t c)
{
    return (c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c;
}

/* Whether RAW starts with VERB (case-insensitively) followed by a space, a
 * newline or the end.  Returns the length of the verb when it does. */
static int32_t rm_verb(const char *raw, const char *verb)
{
    int32_t i = 0;

    while (verb[i] != '\0') {
        if (rm_lower((unsigned char)raw[i]) != rm_lower((unsigned char)verb[i]))
            return 0;
        i++;
    }
    if (raw[i] != '\0' && raw[i] != ' ' && raw[i] != '\n')
        return 0;
    return i;
}

int32_t ck_replmsg_parse(const char *raw, ck_replmsg *out)
{
    int32_t n;

    if (out == NULL)
        return 0;
    out->kind       = CK_REPLMSG_NONE;
    out->rc         = 0;
    out->package[0] = '\0';
    out->text       = "";
    if (raw == NULL)
        return 0;

    if ((n = rm_verb(raw, "OUTPUT")) > 0) {
        /* Exactly one separator is the verb's; everything after it is the
         * chunk, blanks included.  `OUTPUT' alone is an empty chunk. */
        out->kind = CK_REPLMSG_OUTPUT;
        out->text = (raw[n] == ' ') ? raw + n + 1 : raw + n;
        return 1;
    }

    if ((n = rm_verb(raw, "READLINE")) > 0) {
        out->kind = CK_REPLMSG_READLINE;
        return 1;
    }

    if ((n = rm_verb(raw, "RESULT")) > 0) {
        const char *p = raw + n;
        int32_t     rc = 0, digits = 0, i = 0;

        while (*p == ' ')
            p++;
        while (*p >= '0' && *p <= '9') {
            rc = rc * 10 + (*p - '0');
            p++;
            digits++;
        }
        if (digits == 0)
            return 0;
        while (*p == ' ')
            p++;
        while (*p != '\0' && *p != ' ' && *p != '\n' && *p != '\r') {
            if (i < CK_REPLMSG_PKG_MAX - 1)
                out->package[i++] = *p;
            p++;
        }
        out->package[i] = '\0';
        if (i == 0)
            return 0;

        /* The values start after the first newline; a RESULT without one
         * carries none. */
        while (*p != '\0' && *p != '\n')
            p++;
        if (*p == '\n')
            p++;

        out->kind = CK_REPLMSG_RESULT;
        out->rc   = rc;
        out->text = p;
        return 1;
    }

    return 0;
}
