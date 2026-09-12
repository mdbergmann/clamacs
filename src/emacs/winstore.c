/*
 * winstore.c -- see winstore.h.
 */

#include "winstore.h"

#include <stdio.h>
#include <string.h>

#define CK_WINSTORE_HEADER \
    "; clamacs window positions -- role left top width height\n"

void ck_winstore_init(ck_winstore *store)
{
    memset(store, 0, sizeof(*store));
}

static int32_t ck_winstore_index(const ck_winstore *store, const char *role)
{
    int32_t i;
    for (i = 0; i < store->count; i++) {
        if (strcmp(store->items[i].name, role) == 0)
            return i;
    }
    return -1;
}

const ck_winentry *ck_winstore_find(const ck_winstore *store, const char *role)
{
    int32_t i;
    if (role == NULL)
        return NULL;
    i = ck_winstore_index(store, role);
    return (i >= 0) ? &store->items[i] : NULL;
}

int32_t ck_winstore_set(ck_winstore *store, const char *role, int32_t left,
                        int32_t top, int32_t width, int32_t height)
{
    ck_winentry *e;
    int32_t      i;

    if (role == NULL || role[0] == '\0' ||
        strlen(role) >= (size_t)CK_WINSTORE_NAME_MAX)
        return 0;

    i = ck_winstore_index(store, role);
    if (i < 0) {
        if (store->count == CK_WINSTORE_MAX)
            return 0;
        i = store->count++;
    }
    e = &store->items[i];
    strcpy(e->name, role);
    e->left   = left;
    e->top    = top;
    e->width  = width;
    e->height = height;
    return 1;
}

/* ------------------------------------------------------------------ *
 * Text
 * ------------------------------------------------------------------ */

/* A signed decimal at *P; advances past it.  Returns 0 when there is none. */
static int32_t ck_winstore_number(const char **p, int32_t *out)
{
    const char *s = *p;
    int32_t     neg = 0, value = 0, digits = 0;

    while (*s == ' ' || *s == '\t')
        s++;
    if (*s == '-') {
        neg = 1;
        s++;
    }
    while (*s >= '0' && *s <= '9') {
        /* Anything wider than a screen is a corrupt line, not a position:
         * reject before folding in a 7th digit, not after. */
        if (digits >= 6)
            return 0;
        value = value * 10 + (*s - '0');
        digits++;
        s++;
    }
    if (digits == 0)
        return 0;
    if (*s != '\0' && *s != ' ' && *s != '\t' && *s != '\n' && *s != '\r')
        return 0;
    *out = neg ? -value : value;
    *p   = s;
    return 1;
}

/* One line, without its newline.  Returns 1 when it held an entry. */
static int32_t ck_winstore_parse_line(ck_winstore *store, const char *line)
{
    char        role[CK_WINSTORE_NAME_MAX];
    const char *p = line;
    int32_t     n = 0, v[4], i;

    while (*p == ' ' || *p == '\t')
        p++;
    if (*p == '\0' || *p == ';' || *p == '#' || *p == '\r')
        return 0;

    while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\r') {
        if (n >= CK_WINSTORE_NAME_MAX - 1)
            return 0;
        role[n++] = *p++;
    }
    role[n] = '\0';

    for (i = 0; i < 4; i++) {
        if (!ck_winstore_number(&p, &v[i]))
            return 0;
    }
    while (*p == ' ' || *p == '\t' || *p == '\r')
        p++;
    if (*p != '\0')
        return 0;   /* trailing junk: not an entry */

    return ck_winstore_set(store, role, v[0], v[1], v[2], v[3]);
}

int32_t ck_winstore_parse(ck_winstore *store, const char *text)
{
    char    line[128];
    int32_t n = 0, read = 0, overflow = 0;

    ck_winstore_init(store);
    if (text == NULL)
        return 0;

    for (;;) {
        char c = *text;

        if (c == '\n' || c == '\0') {
            line[n] = '\0';
            if (!overflow)
                read += ck_winstore_parse_line(store, line);
            n = 0;
            overflow = 0;
            if (c == '\0')
                break;
        } else if (n < (int32_t)sizeof line - 1) {
            line[n++] = c;
        } else {
            overflow = 1;   /* too long: the line is dropped */
        }
        text++;
    }
    return read;
}

int32_t ck_winstore_format(const ck_winstore *store, char *out, int32_t size)
{
    int32_t used = 0, i;

    if (size <= 0)
        return -1;
    out[0] = '\0';

    used = snprintf(out, (size_t)size, "%s", CK_WINSTORE_HEADER);
    if (used < 0 || used >= size)
        return -1;

    for (i = 0; i < store->count; i++) {
        const ck_winentry *e = &store->items[i];
        int32_t n = snprintf(out + used, (size_t)(size - used),
                             "%s %ld %ld %ld %ld\n", e->name,
                             (long)e->left, (long)e->top,
                             (long)e->width, (long)e->height);
        if (n < 0 || n >= size - used)
            return -1;
        used += n;
    }
    return used;
}

/* ------------------------------------------------------------------ *
 * Roles
 * ------------------------------------------------------------------ */

int32_t ck_winstore_doc_role(int32_t slot, char *out, int32_t size)
{
    int32_t n;

    if (slot <= 0 || size <= 0)
        return 0;
    n = snprintf(out, (size_t)size, "doc%ld", (long)slot);
    if (n < 0 || n >= size) {
        out[0] = '\0';
        return 0;
    }
    return n;
}

int32_t ck_winstore_doc_slot(const char *role)
{
    int32_t slot = 0;

    if (role == NULL || strncmp(role, "doc", 3) != 0 || role[3] == '\0')
        return 0;
    role += 3;
    while (*role >= '0' && *role <= '9') {
        if (slot > 99999)
            return 0;
        slot = slot * 10 + (*role - '0');
        role++;
    }
    return (*role == '\0') ? slot : 0;
}

void ck_winstore_scratch_role(const char *name, char *out, int32_t size)
{
    int32_t n = 0;

    if (size <= 0)
        return;
    out[0] = '\0';
    if (name == NULL)
        return;

    while (*name == '*')
        name++;
    if (strncmp(name, "clamacs-", 8) == 0)
        name += 8;

    while (*name != '\0' && *name != '*' && n < size - 1) {
        char c = *name++;
        out[n++] = (c == ' ' || c == '\t') ? '-' : c;
    }
    out[n] = '\0';
}
