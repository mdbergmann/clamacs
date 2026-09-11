/*
 * replmsg.h -- the commands clamiga's REPL thread sends TO the editor.
 *
 * Phase 3 turns the ARexx conversation two-way.  The editor still asks
 * (REPL-EVAL, REPL-INPUT, REPL-INTERRUPT), but everything it has to WAIT
 * for comes back as a command at its own port, because MUI answers an
 * application's ARexx command the moment the hook returns and the editor
 * can hold no reply until the user has typed (cl-amiga's lib/dev-repl.lisp
 * is the other end).  Three commands arrive that way:
 *
 *   OUTPUT <text>          a chunk of output, verbatim: leading blanks and a
 *                          trailing newline are part of it
 *   READLINE               the form is reading a line from standard input
 *   RESULT <rc> <pkg>      the form is done; the printed values (one per
 *     <values...>          line, or `; No values') or `ERROR: <text>' follow
 *                          the first newline; PKG is for the prompt
 *
 * Phase 4 adds a fourth, from the same thread parked on an erring stack
 * (REPL-ATTACH ... DEBUG; cl-amiga's lib/dev-repl.lisp has the protocol):
 *
 *   DEBUGGER <level> <pkg> the REPL is in the debugger at LEVEL (1, 2, ...
 *     <type>: <report>     for nested ones); the condition and one restart
 *     <n>: <NAME> <report> per line follow the first newline.  LEVEL 0 says
 *                          the debugger has been left, with no body.
 *
 * They reach the MUI layer through MUIA_Application_RexxHook rather than
 * the command table, so no ReadArgs template stands between the wire and
 * the text: a chunk that starts with blanks, holds a lone quote or ends in
 * a newline arrives exactly as printed.  This file is the parse of the raw
 * argument string, kept pure so tests/test_replmsg.c can pin it down.
 */

#ifndef CLAMACS_REPLMSG_H
#define CLAMACS_REPLMSG_H

#include <stdint.h>

typedef enum {
    CK_REPLMSG_NONE = 0,
    CK_REPLMSG_OUTPUT,
    CK_REPLMSG_READLINE,
    CK_REPLMSG_RESULT,
    CK_REPLMSG_DEBUGGER
} ck_replmsg_kind;

#define CK_REPLMSG_PKG_MAX 64

typedef struct {
    uint16_t    kind;      /* ck_replmsg_kind */
    int32_t     rc;        /* RESULT: the return code; DEBUGGER: the level */
    char        package[CK_REPLMSG_PKG_MAX];  /* RESULT, DEBUGGER: the prompt's package */
    const char *text;      /* OUTPUT: the chunk; RESULT: the values;
                            * DEBUGGER: the condition and restart lines; or
                            * "" (a pointer into RAW, never NULL once parsed) */
} ck_replmsg;

/* Parse RAW.  Returns 1 and fills OUT when it is one of the four commands
 * (the verb is matched case-insensitively, as MUI matches its own), 0 for
 * anything else -- which the MUI layer answers as an unknown command. */
int32_t ck_replmsg_parse(const char *raw, ck_replmsg *out);

#endif /* CLAMACS_REPLMSG_H */
