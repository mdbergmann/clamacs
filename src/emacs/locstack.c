/*
 * locstack.c -- see locstack.h.
 */

#include "locstack.h"

#include <string.h>

void ck_locstack_init(ck_locstack *stack)
{
    memset(stack, 0, sizeof(*stack));
}

void ck_locstack_push(ck_locstack *stack, const char *path, uint32_t id,
                      int32_t index)
{
    ck_location *loc;

    if (stack->count == CK_LOCSTACK_SIZE) {
        memmove(&stack->items[0], &stack->items[1],
                (size_t)(CK_LOCSTACK_SIZE - 1) * sizeof(ck_location));
        stack->count--;
    }

    loc = &stack->items[stack->count++];
    memset(loc, 0, sizeof(*loc));
    if (path != NULL) {
        strncpy(loc->path, path, sizeof loc->path - 1);
        loc->path[sizeof loc->path - 1] = '\0';
    }
    loc->id    = id;
    loc->index = index;
}

int32_t ck_locstack_pop(ck_locstack *stack, ck_location *out)
{
    if (stack->count == 0)
        return 0;
    stack->count--;
    if (out != NULL)
        *out = stack->items[stack->count];
    return 1;
}

int32_t ck_locstack_depth(const ck_locstack *stack)
{
    return stack->count;
}
