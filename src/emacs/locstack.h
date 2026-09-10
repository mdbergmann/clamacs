/*
 * locstack.h -- where `M-.' came from, so `M-,' can go back.
 *
 * A jump to a definition pushes the place it left; popping returns there.
 * The place is a file path and a byte index, plus the document id it was in:
 * the id finds the same window when it is still open, the path reopens the
 * file when it is not, and a scratch window (no path) is only ever found by
 * id.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_LOCSTACK_H
#define CLAMACS_LOCSTACK_H

#include <stdint.h>

#define CK_LOCSTACK_SIZE   16
#define CK_LOC_PATH_MAX    256   /* == CK_PATH_MAX in clamacs.h */

typedef struct {
    char     path[CK_LOC_PATH_MAX];
    uint32_t id;
    int32_t  index;
} ck_location;

typedef struct {
    ck_location items[CK_LOCSTACK_SIZE];
    int32_t     count;
} ck_locstack;

void ck_locstack_init(ck_locstack *stack);

/* Push a place.  When the stack is full the oldest entry is dropped: the
 * user can always get back to the last few places, which is what matters. */
void ck_locstack_push(ck_locstack *stack, const char *path, uint32_t id,
                      int32_t index);

/* Pop the most recent place into *OUT.  Returns 1, or 0 when empty. */
int32_t ck_locstack_pop(ck_locstack *stack, ck_location *out);

int32_t ck_locstack_depth(const ck_locstack *stack);

#endif /* CLAMACS_LOCSTACK_H */
