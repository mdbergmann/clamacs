/*
 * symcache.c -- see symcache.h.
 */

#include "symcache.h"

#include <stdlib.h>
#include <string.h>

void ck_symcache_init(ck_symcache *cache)
{
    memset(cache, 0, sizeof(*cache));
}

void ck_symcache_clear(ck_symcache *cache)
{
    int32_t i;

    for (i = 0; i < CK_SYMCACHE_SIZE; i++) {
        free(cache->items[i].key);
        free(cache->items[i].value);
    }
    memset(cache, 0, sizeof(*cache));
}

static char *lowered_copy(const char *s)
{
    size_t n = strlen(s);
    char  *copy = (char *)malloc(n + 1);
    size_t i;

    if (copy == NULL)
        return NULL;
    for (i = 0; i < n; i++) {
        char c = s[i];
        if (c >= 'A' && c <= 'Z')
            c = (char)(c - 'A' + 'a');
        copy[i] = c;
    }
    copy[n] = '\0';
    return copy;
}

static int32_t find_slot(const ck_symcache *cache, const char *lowered)
{
    int32_t i;

    for (i = 0; i < CK_SYMCACHE_SIZE; i++) {
        if (cache->items[i].key != NULL &&
            strcmp(cache->items[i].key, lowered) == 0)
            return i;
    }
    return -1;
}

int32_t ck_symcache_put(ck_symcache *cache, const char *key, const char *value)
{
    char   *lowered, *copy;
    int32_t slot;

    if (key == NULL || key[0] == '\0')
        return -1;
    if (value == NULL)
        value = "";

    lowered = lowered_copy(key);
    if (lowered == NULL)
        return -1;
    copy = (char *)malloc(strlen(value) + 1);
    if (copy == NULL) {
        free(lowered);
        return -1;
    }
    strcpy(copy, value);

    slot = find_slot(cache, lowered);
    if (slot >= 0) {
        free(lowered);
        free(cache->items[slot].value);
        cache->items[slot].value = copy;
        return 0;
    }

    slot = cache->next;
    cache->next = (cache->next + 1) % CK_SYMCACHE_SIZE;
    free(cache->items[slot].key);
    free(cache->items[slot].value);
    cache->items[slot].key   = lowered;
    cache->items[slot].value = copy;
    return 0;
}

const char *ck_symcache_get(const ck_symcache *cache, const char *key)
{
    char   *lowered;
    int32_t slot;

    if (key == NULL || key[0] == '\0')
        return NULL;
    lowered = lowered_copy(key);
    if (lowered == NULL)
        return NULL;
    slot = find_slot(cache, lowered);
    free(lowered);
    return (slot >= 0) ? cache->items[slot].value : NULL;
}
