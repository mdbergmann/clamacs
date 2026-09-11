/*
 * dbgmsg.c -- see dbgmsg.h.
 */

#include "dbgmsg.h"

#include <string.h>

int32_t ck_dbg_line(const char **cursor, char *out, int32_t size)
{
    const char *p = *cursor;
    int32_t     n = 0;

    if (p == NULL || *p == '\0') {
        if (size > 0)
            out[0] = '\0';
        return 0;
    }

    while (*p != '\0' && *p != '\n') {
        if (*p != '\r' && n < size - 1)
            out[n++] = *p;
        p++;
    }
    if (size > 0)
        out[n < size ? n : size - 1] = '\0';
    if (*p == '\n')
        p++;
    *cursor = p;
    return 1;
}

/* Digits at P, then C.  Returns the number and moves *P past C, or -1. */
static int32_t dm_number_before(const char **p, char c)
{
    const char *q = *p;
    int32_t     n = 0, digits = 0;

    while (*q >= '0' && *q <= '9') {
        n = n * 10 + (*q - '0');
        q++;
        digits++;
    }
    if (digits == 0 || *q != c)
        return -1;
    *p = q + 1;
    return n;
}

int32_t ck_dbg_row_index(const char *line)
{
    if (line == NULL)
        return -1;
    return dm_number_before(&line, ':');
}

int32_t ck_dbg_frame_location(const char *line, char *file, int32_t size,
                              int32_t *lineno)
{
    const char *sep, *colon, *p;
    int32_t     n = 0, digits = 0, len;

    if (line == NULL)
        return 0;

    /* The location is what follows the LAST run of two blanks: a function
     * name holds no blank, a file name may hold one. */
    sep = NULL;
    for (p = line; *p != '\0'; p++) {
        if (p[0] == ' ' && p[1] == ' ')
            sep = p;
    }
    if (sep == NULL)
        return 0;
    p = sep;
    while (*p == ' ')
        p++;
    if (*p == '\0')
        return 0;

    /* `<file>:<line>': the line number is after the last colon, and a
     * colon inside an Amiga path (`Work:src/foo.lisp') is left to the
     * file. */
    colon = strrchr(p, ':');
    if (colon == NULL || colon == p)
        return 0;
    for (sep = colon + 1; *sep >= '0' && *sep <= '9'; sep++) {
        n = n * 10 + (*sep - '0');
        digits++;
    }
    if (digits == 0 || (*sep != '\0' && *sep != '\r' && *sep != '\n'))
        return 0;

    len = (int32_t)(colon - p);
    if (len > size - 1)
        len = size - 1;
    if (size > 0) {
        memcpy(file, p, (size_t)len);
        file[len] = '\0';
    }
    if (lineno != NULL)
        *lineno = n;
    return 1;
}

int32_t ck_dbg_inspect_header(const char *text, char *type, int32_t size,
                              int32_t *depth, int32_t *count)
{
    const char *p = text;
    int32_t     n = 0, d, c;

    if (text == NULL)
        return 0;

    while (*p != '\0' && *p != ' ' && *p != '\n') {
        if (n < size - 1)
            type[n++] = *p;
        p++;
    }
    if (size > 0)
        type[n < size ? n : size - 1] = '\0';
    if (n == 0 || *p != ' ')
        return 0;
    p++;

    d = dm_number_before(&p, ' ');
    if (d < 0)
        return 0;
    c = dm_number_before(&p, '\n');
    if (c < 0) {
        /* A header with nothing after it: the count ends the text. */
        const char *q = p;
        c = 0;
        while (*q >= '0' && *q <= '9') {
            c = c * 10 + (*q - '0');
            q++;
        }
        if (q == p || (*q != '\0' && *q != '\r'))
            return 0;
    }

    if (depth != NULL)
        *depth = d;
    if (count != NULL)
        *count = c;
    return 1;
}
