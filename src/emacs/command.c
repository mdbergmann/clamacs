/*
 * command.c -- see command.h.
 */

#include "command.h"
#include "minihist.h"

#include <string.h>

static const char *const ck_command_names[] = {
#define CK_COMMAND_NAME(sym, name) name,
    CK_COMMAND_LIST(CK_COMMAND_NAME)
#undef CK_COMMAND_NAME
    NULL
};

const char *ck_command_name(int16_t id)
{
    if (id < 0 || id >= (int16_t)CK_CMD_COUNT)
        return NULL;
    return ck_command_names[id];
}

int16_t ck_command_lookup(const char *name)
{
    int16_t i;

    if (name == NULL)
        return CK_CMD_NONE;
    for (i = 0; i < (int16_t)CK_CMD_COUNT; i++) {
        if (strcmp(ck_command_names[i], name) == 0)
            return i;
    }
    return CK_CMD_NONE;
}

int32_t ck_command_complete(const char *prefix, const char **out, int32_t max,
                            char *common, int32_t common_size)
{
    /* One completion implementation for the whole editor: `M-x', file names
     * and, from phase 2, symbol names from clamiga. */
    return ck_complete(ck_command_names, (int32_t)CK_CMD_COUNT, prefix,
                       out, max, common, common_size);
}
