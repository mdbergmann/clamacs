/*
 * diag.c -- see diag.h.
 */

#include "diag.h"

#include <stdlib.h>
#include <string.h>

struct sev_word {
    const char *word;
    uint8_t     severity;
};

static const struct sev_word ck_sev_words[] = {
    { "ERROR",         CK_SEV_ERROR },
    { "STYLE-WARNING", CK_SEV_WARNING },
    { "WARNING",       CK_SEV_WARNING },
    { "NOTE",          CK_SEV_NOTE },
    { NULL,            0 }
};

static char *ck_strndup(const char *s, int32_t n)
{
    char *copy;

    if (s == NULL || n < 0)
        return NULL;
    copy = (char *)malloc((size_t)n + 1);
    if (copy == NULL)
        return NULL;
    if (n > 0)
        memcpy(copy, s, (size_t)n);
    copy[n] = '\0';
    return copy;
}

void ck_diag_init(ck_diaglist *list)
{
    memset(list, 0, sizeof(*list));
}

void ck_diag_clear(ck_diaglist *list)
{
    int32_t i;

    for (i = 0; i < list->count; i++) {
        free(list->items[i].file);
        free(list->items[i].text);
        free(list->items[i].rendered);
    }
    free(list->items);
    free(list->summary);
    memset(list, 0, sizeof(*list));
}

/* A severity keyword at LINE[at], followed by ": ".  Returns its length, or
 * 0.  Longest match first, so STYLE-WARNING is not read as an unknown word
 * beginning with a match for nothing. */
static int32_t sev_at(const char *line, int32_t len, int32_t at, uint8_t *sev)
{
    int32_t i;

    for (i = 0; ck_sev_words[i].word != NULL; i++) {
        int32_t wlen = (int32_t)strlen(ck_sev_words[i].word);
        if (at + wlen + 1 > len)
            continue;
        if (memcmp(line + at, ck_sev_words[i].word, (size_t)wlen) != 0)
            continue;
        if (line[at + wlen] != ':')
            continue;
        *sev = ck_sev_words[i].severity;
        return wlen;
    }
    return 0;
}

static int32_t all_digits(const char *s, int32_t len)
{
    int32_t i;
    if (len <= 0)
        return 0;
    for (i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9')
            return 0;
    }
    return 1;
}

static int32_t to_int(const char *s, int32_t len)
{
    int32_t v = 0, i;
    for (i = 0; i < len; i++)
        v = v * 10 + (s[i] - '0');
    return v;
}

int32_t ck_diag_parse_line(const char *line, int32_t len, ck_diag *out)
{
    int32_t at, wlen, text_at;
    uint8_t sev = CK_SEV_NOTE;
    int32_t prefix_end = -1;

    if (line == NULL || out == NULL || len <= 0)
        return 0;

    memset(out, 0, sizeof(*out));

    /* `SEVERITY: message' -- a diagnostic clamiga could not locate. */
    wlen = sev_at(line, len, 0, &sev);
    if (wlen > 0) {
        prefix_end = -1;
        at         = 0;
    } else {
        /* `file:line: SEVERITY: message'.  Anchor on the severity keyword,
         * never on a colon: `Work:src/foo.lisp' has two of its own. */
        for (at = 0; at + 2 < len; at++) {
            if (line[at] != ':' || line[at + 1] != ' ')
                continue;
            wlen = sev_at(line, len, at + 2, &sev);
            if (wlen > 0) {
                prefix_end = at;
                at         = at + 2;
                break;
            }
        }
        if (wlen == 0)
            return 0;
    }

    text_at = at + wlen + 1;              /* past "SEVERITY:" */
    while (text_at < len && line[text_at] == ' ')
        text_at++;

    out->severity = sev;
    out->line     = 0;
    out->file     = NULL;

    if (prefix_end > 0) {
        /* Split `file:line' from the right: the LAST colon whose tail is all
         * digits is the line number, so a path keeps its own colons. */
        int32_t i, colon = -1;
        for (i = prefix_end - 1; i >= 0; i--) {
            if (line[i] == ':') { colon = i; break; }
        }
        if (colon >= 0 && all_digits(line + colon + 1, prefix_end - colon - 1)) {
            out->line = to_int(line + colon + 1, prefix_end - colon - 1);
            out->file = ck_strndup(line, colon);
        } else {
            out->file = ck_strndup(line, prefix_end);
        }
        if (out->file == NULL)
            return 0;
    }

    out->text     = ck_strndup(line + text_at, len - text_at);
    out->rendered = ck_strndup(line, len);
    if (out->text == NULL || out->rendered == NULL) {
        free(out->file);
        free(out->text);
        free(out->rendered);
        memset(out, 0, sizeof(*out));
        return 0;
    }
    return 1;
}

static int32_t diag_append(ck_diaglist *list, const ck_diag *d)
{
    if (list->count == list->cap) {
        int32_t  cap = (list->cap == 0) ? 16 : list->cap * 2;
        ck_diag *grown =
            (ck_diag *)realloc(list->items, (size_t)cap * sizeof(ck_diag));
        if (grown == NULL)
            return -1;
        list->items = grown;
        list->cap   = cap;
    }
    list->items[list->count++] = *d;
    return 0;
}

/* `N error(s), M warning(s)' */
static int32_t summary_line(const char *line, int32_t len,
                            int32_t *errors, int32_t *warnings)
{
    int32_t i = 0, n;
    static const char *e_tag = " error(s), ";
    static const char *w_tag = " warning(s)";
    int32_t elen = (int32_t)strlen(e_tag);
    int32_t wlen = (int32_t)strlen(w_tag);

    while (i < len && line[i] == ' ')
        i++;
    n = i;
    while (i < len && line[i] >= '0' && line[i] <= '9')
        i++;
    if (i == n)
        return 0;
    *errors = to_int(line + n, i - n);

    if (i + elen > len || memcmp(line + i, e_tag, (size_t)elen) != 0)
        return 0;
    i += elen;

    n = i;
    while (i < len && line[i] >= '0' && line[i] <= '9')
        i++;
    if (i == n)
        return 0;
    *warnings = to_int(line + n, i - n);

    if (i + wlen > len || memcmp(line + i, w_tag, (size_t)wlen) != 0)
        return 0;

    return 1;
}

int32_t ck_diag_parse(ck_diaglist *list, const char *text)
{
    int32_t added = 0;
    const char *p = text;

    if (list == NULL || text == NULL)
        return 0;

    while (*p != '\0') {
        const char *nl  = strchr(p, '\n');
        int32_t     len = (nl != NULL) ? (int32_t)(nl - p) : (int32_t)strlen(p);
        int32_t     errors = 0, warnings = 0;
        ck_diag     d;

        if (len > 0 && p[len - 1] == '\r')
            len--;

        if (len > 0) {
            if (summary_line(p, len, &errors, &warnings)) {
                list->errors       = errors;
                list->warnings     = warnings;
                list->summary_seen = 1;
                free(list->summary);
                list->summary = ck_strndup(p, len);
            } else if (len >= 12 && memcmp(p, "[truncated a", 12) == 0) {
                list->truncated = 1;
            } else if (len >= 11 && memcmp(p, "; aborted -", 11) == 0) {
                list->aborted = 1;
            } else if (ck_diag_parse_line(p, len, &d)) {
                if (diag_append(list, &d) != 0) {
                    free(d.file);
                    free(d.text);
                    free(d.rendered);
                    return -1;
                }
                added++;
            }
        }

        if (nl == NULL)
            break;
        p = nl + 1;
    }

    return added;
}
