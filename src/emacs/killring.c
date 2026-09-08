/*
 * killring.c -- see killring.h.
 */

#include "killring.h"

#include <stdlib.h>
#include <string.h>

void ck_kill_init(ck_killring *ring)
{
    memset(ring, 0, sizeof(*ring));
}

void ck_kill_clear(ck_killring *ring)
{
    int32_t i;
    for (i = 0; i < CK_KILL_RING_SIZE; i++) {
        free(ring->slots[i]);
        ring->slots[i] = NULL;
    }
    ring->count = 0;
    ring->head  = 0;
    ring->yank  = 0;
}

static char *ck_kill_dup(const char *text, int32_t len)
{
    char *copy;

    if (text == NULL || len < 0)
        return NULL;
    copy = (char *)malloc((size_t)len + 1);
    if (copy == NULL)
        return NULL;
    if (len > 0)
        memcpy(copy, text, (size_t)len);
    copy[len] = '\0';
    return copy;
}

int ck_kill_push(ck_killring *ring, const char *text, int32_t len)
{
    char   *copy = ck_kill_dup(text, len);
    int32_t slot;

    if (copy == NULL)
        return -1;

    slot = (ring->count == 0) ? 0 : (ring->head + 1) % CK_KILL_RING_SIZE;
    free(ring->slots[slot]);
    ring->slots[slot] = copy;
    ring->head        = slot;
    if (ring->count < CK_KILL_RING_SIZE)
        ring->count++;
    ring->yank = 0;
    return 0;
}

static int ck_kill_extend(ck_killring *ring, const char *text, int32_t len,
                          int32_t at_front)
{
    char   *old, *joined;
    int32_t oldlen;

    if (ring->count == 0)
        return ck_kill_push(ring, text, len);
    if (text == NULL || len < 0)
        return -1;

    old    = ring->slots[ring->head];
    oldlen = (int32_t)strlen(old);

    joined = (char *)malloc((size_t)oldlen + (size_t)len + 1);
    if (joined == NULL)
        return -1;

    if (at_front) {
        memcpy(joined, text, (size_t)len);
        memcpy(joined + len, old, (size_t)oldlen);
    } else {
        memcpy(joined, old, (size_t)oldlen);
        memcpy(joined + oldlen, text, (size_t)len);
    }
    joined[oldlen + len] = '\0';

    free(old);
    ring->slots[ring->head] = joined;
    ring->yank              = 0;
    return 0;
}

int ck_kill_append(ck_killring *ring, const char *text, int32_t len)
{
    return ck_kill_extend(ring, text, len, 0);
}

int ck_kill_prepend(ck_killring *ring, const char *text, int32_t len)
{
    return ck_kill_extend(ring, text, len, 1);
}

const char *ck_kill_current(const ck_killring *ring)
{
    int32_t slot;

    if (ring->count == 0)
        return NULL;
    slot = ring->head - ring->yank;
    while (slot < 0)
        slot += CK_KILL_RING_SIZE;
    return ring->slots[slot % CK_KILL_RING_SIZE];
}

const char *ck_kill_rotate(ck_killring *ring)
{
    if (ring->count == 0)
        return NULL;
    ring->yank = (ring->yank + 1) % ring->count;
    return ck_kill_current(ring);
}

void ck_kill_reset_yank(ck_killring *ring)
{
    ring->yank = 0;
}
