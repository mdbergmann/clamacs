/*
 * killring.h -- the kill ring.
 *
 * Distinct from the Amiga clipboard on purpose: `C-k' three times in a row
 * must build one entry, and `M-y' must walk backwards through entries the
 * clipboard has no concept of.  The MUI layer additionally copies what
 * `C-w'/`M-w' kill to the clipboard so other applications see the last kill;
 * that is a one-way mirror and does not live here.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_KILLRING_H
#define CLAMACS_KILLRING_H

#include <stdint.h>

#define CK_KILL_RING_SIZE 16

typedef struct {
    char   *slots[CK_KILL_RING_SIZE];
    int32_t count;  /* filled slots, 0..CK_KILL_RING_SIZE */
    int32_t head;   /* slot holding the most recent kill */
    int32_t yank;   /* how far `M-y' has rotated back from head */
} ck_killring;

void ck_kill_init(ck_killring *ring);
void ck_kill_clear(ck_killring *ring);

/* Start a new entry.  Returns 0 on success, -1 when out of memory. */
int ck_kill_push(ck_killring *ring, const char *text, int32_t len);

/* Extend the most recent entry, as consecutive `C-k' does.  Appends at the
 * end (forward kills) or at the front (backward kills such as
 * `backward-kill-word'), which is what makes `M-DEL M-DEL' yank back in
 * reading order.  Falls back to a push when the ring is empty. */
int ck_kill_append(ck_killring *ring, const char *text, int32_t len);
int ck_kill_prepend(ck_killring *ring, const char *text, int32_t len);

/* What `C-y' yanks: the entry at the current rotation, or NULL when the ring
 * is empty. */
const char *ck_kill_current(const ck_killring *ring);

/* `M-y': step one entry further back and return it, or NULL when the ring is
 * empty.  Wraps around. */
const char *ck_kill_rotate(ck_killring *ring);

/* Called when something other than a yank happens, so the next `C-y' starts
 * from the most recent kill again. */
void ck_kill_reset_yank(ck_killring *ring);

#endif /* CLAMACS_KILLRING_H */
