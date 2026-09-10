/*
 * minihist.h -- minibuffer history and completion.
 *
 * The minibuffer is one MUI String object reused for every prompt, so the
 * history has to be per PROMPT KIND (file names, commands, search patterns)
 * rather than per object -- hence a plain struct the caller keeps one of per
 * kind.  Completion is generic over a candidate list so `M-x', file names and,
 * from phase 2, symbol names from clamiga all share one implementation.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_MINIHIST_H
#define CLAMACS_MINIHIST_H

#include <stdint.h>

#define CK_HIST_SIZE 32

typedef struct {
    char   *items[CK_HIST_SIZE];
    int32_t count;   /* filled slots */
    int32_t head;    /* slot holding the newest entry */
    int32_t cursor;  /* 0 = not walking, N = N entries back from head */
} ck_history;

void ck_hist_init(ck_history *hist);
void ck_hist_clear(ck_history *hist);

/* Record an entry.  A repeat of the newest entry is dropped, so holding a
 * key down does not fill the ring with one string.  Resets the cursor. */
int ck_hist_add(ck_history *hist, const char *text);

/* `M-p' / `M-n'.  Return the entry to show, or NULL at the end of the ring
 * (for M-n, NULL means "back to what the user was typing"). */
const char *ck_hist_prev(ck_history *hist);
const char *ck_hist_next(ck_history *hist);

/* Stop walking; the next M-p starts from the newest entry again. */
void ck_hist_reset(ck_history *hist);

/* Entry N back from the newest (0 = newest), or NULL. */
const char *ck_hist_nth(const ck_history *hist, int32_t n);

/* ------------------------------------------------------------------ *
 * Completion
 * ------------------------------------------------------------------ */

/* Candidates from CANDS that start with PREFIX.  Fills OUT (may be NULL)
 * with up to MAX of them in table order and returns the total number that
 * matched -- which can exceed MAX, so a caller can say "37 matches" while
 * showing ten.  COMMON, when not NULL, receives the longest common prefix of
 * all matches, which is what TAB inserts. */
int32_t ck_complete(const char *const *cands, int32_t ncands,
                    const char *prefix, const char **out, int32_t max,
                    char *common, int32_t common_size);

/* A candidate list that came from clamiga: COMPLETE answers one symbol per
 * line, and this turns that reply into the array ck_complete() takes. */
typedef struct {
    char   **items;
    int32_t  count;
    int32_t  cap;
} ck_strlist;

void ck_strlist_init(ck_strlist *list);
void ck_strlist_clear(ck_strlist *list);

/* Replace the list with the non-empty lines of TEXT (CR/LF stripped).
 * Returns the count, or -1 when out of memory (the list is then empty). */
int32_t ck_strlist_set_lines(ck_strlist *list, const char *text);

#endif /* CLAMACS_MINIHIST_H */
