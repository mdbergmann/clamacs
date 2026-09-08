/*
 * minihist.c -- see minihist.h.
 */

#include "minihist.h"

#include <stdlib.h>
#include <string.h>

void ck_hist_init(ck_history *hist)
{
    memset(hist, 0, sizeof(*hist));
}

void ck_hist_clear(ck_history *hist)
{
    int32_t i;
    for (i = 0; i < CK_HIST_SIZE; i++) {
        free(hist->items[i]);
        hist->items[i] = NULL;
    }
    hist->count  = 0;
    hist->head   = 0;
    hist->cursor = 0;
}

const char *ck_hist_nth(const ck_history *hist, int32_t n)
{
    int32_t slot;

    if (n < 0 || n >= hist->count)
        return NULL;
    slot = hist->head - n;
    while (slot < 0)
        slot += CK_HIST_SIZE;
    return hist->items[slot % CK_HIST_SIZE];
}

int ck_hist_add(ck_history *hist, const char *text)
{
    char   *copy;
    int32_t slot;

    hist->cursor = 0;
    if (text == NULL || text[0] == '\0')
        return 0;

    if (hist->count > 0) {
        const char *newest = ck_hist_nth(hist, 0);
        if (newest != NULL && strcmp(newest, text) == 0)
            return 0;
    }

    copy = (char *)malloc(strlen(text) + 1);
    if (copy == NULL)
        return -1;
    strcpy(copy, text);

    slot = (hist->count == 0) ? 0 : (hist->head + 1) % CK_HIST_SIZE;
    free(hist->items[slot]);
    hist->items[slot] = copy;
    hist->head        = slot;
    if (hist->count < CK_HIST_SIZE)
        hist->count++;
    return 0;
}

const char *ck_hist_prev(ck_history *hist)
{
    if (hist->count == 0 || hist->cursor >= hist->count)
        return NULL;
    return ck_hist_nth(hist, hist->cursor++);
}

const char *ck_hist_next(ck_history *hist)
{
    if (hist->cursor <= 1) {
        /* Walking back off the newest entry returns to the line the user was
         * typing, which the caller holds; NULL says so. */
        hist->cursor = 0;
        return NULL;
    }
    hist->cursor--;
    return ck_hist_nth(hist, hist->cursor - 1);
}

void ck_hist_reset(ck_history *hist)
{
    hist->cursor = 0;
}

int32_t ck_complete(const char *const *cands, int32_t ncands,
                    const char *prefix, const char **out, int32_t max,
                    char *common, int32_t common_size)
{
    int32_t     matches = 0, n = 0, common_len = 0;
    const char *first = NULL;
    size_t      plen;
    int32_t     i;

    if (common != NULL && common_size > 0)
        common[0] = '\0';
    if (cands == NULL || ncands <= 0)
        return 0;
    if (prefix == NULL)
        prefix = "";
    plen = strlen(prefix);

    for (i = 0; i < ncands; i++) {
        const char *name = cands[i];
        if (name == NULL || strncmp(name, prefix, plen) != 0)
            continue;
        matches++;
        if (first == NULL) {
            first      = name;
            common_len = (int32_t)strlen(name);
        } else {
            int32_t k = 0;
            while (k < common_len && name[k] != '\0' && name[k] == first[k])
                k++;
            common_len = k;
        }
        if (out != NULL && n < max)
            out[n++] = name;
    }

    if (common != NULL && common_size > 0 && first != NULL && common_len > 0) {
        int32_t copy = common_len;
        if (copy > common_size - 1)
            copy = common_size - 1;
        memcpy(common, first, (size_t)copy);
        common[copy] = '\0';
    }

    return matches;
}
