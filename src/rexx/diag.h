/*
 * diag.h -- parsing clamiga's replies into a diagnostic list.
 *
 * clamiga renders diagnostics as `file:line: SEVERITY: message' followed by
 * a `N error(s), M warning(s)' summary (lib/dev-commands.lisp, %RENDER-DIAG).
 * The editor turns those lines into rows in the error list window, where
 * selecting one jumps to the file and line.
 *
 * The parsing is fiddlier than it looks and that is why it is here rather
 * than inline in the MUI code: Amiga paths contain colons, so
 * `Work:src/foo.lisp:3: ERROR: ...' cannot be split on the first colon, or
 * even the second.  The severity keyword is the only reliable anchor.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_DIAG_H
#define CLAMACS_DIAG_H

#include <stdint.h>

#include "rc.h"

typedef enum {
    CK_SEV_NOTE = 0,
    CK_SEV_WARNING,
    CK_SEV_ERROR
} ck_severity;

typedef struct {
    char   *file;      /* NULL when the diagnostic carried no location */
    int32_t line;      /* 1-based, 0 when unknown */
    uint8_t severity;  /* ck_severity */
    char   *text;      /* the message alone */
    char   *rendered;  /* the whole reply line, which is what the list shows */
} ck_diag;

typedef struct {
    ck_diag *items;
    int32_t  count;
    int32_t  cap;

    /* From the summary line, which is authoritative: a diagnostic can be
     * lost to the 8 KB reply cap while its count is not. */
    int32_t  errors;
    int32_t  warnings;
    int32_t  summary_seen;

    /* Markers clamiga appends. */
    int32_t  truncated;   /* the reply hit *MAX-RESULT-LENGTH* */
    int32_t  aborted;     /* a reader error took the rest of the file with it */

    char    *summary;     /* the summary line verbatim, for the minibuffer */
} ck_diaglist;

void ck_diag_init(ck_diaglist *list);
void ck_diag_clear(ck_diaglist *list);

/* Parse a whole reply.  Appends to LIST (so a LOAD followed by a
 * COMPILE-FILE can accumulate if a caller wants that); returns the number of
 * diagnostics added, or -1 when out of memory. */
int32_t ck_diag_parse(ck_diaglist *list, const char *text);

/* Parse one line.  Returns 1 when it was a diagnostic and fills *OUT (whose
 * strings the caller owns), 0 when it was something else. */
int32_t ck_diag_parse_line(const char *line, int32_t len, ck_diag *out);

/* A bare `file:line' -- what SOURCE-LOCATION answers.  Only the first line
 * of TEXT is read.  The same right-hand split as a diagnostic's location:
 * the last colon whose tail is all digits, so `Work:src/foo.lisp:12' keeps
 * the path's own colons.  Returns 1 and fills FILE and *LINE (1-based, so
 * a `:0' is not a location), 0 when TEXT is not one -- which is what an
 * error reply looks like. */
int32_t ck_diag_parse_location(const char *text, char *file, int32_t file_size,
                               int32_t *line);

#endif /* CLAMACS_DIAG_H */
