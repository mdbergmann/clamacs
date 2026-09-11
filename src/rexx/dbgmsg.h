/*
 * dbgmsg.h -- the lines of the debugger and inspector replies.
 *
 * Phase 4's windows are lists: the restarts and the frames of a debugger
 * level, a frame's locals, an object's parts.  clamiga answers each as
 * text with one row per line (cl-amiga's lib/dev-repl.lisp and the
 * INSPECT command in lib/dev-commands.lisp print them), and the MUI layer
 * puts the lines into MUI Lists as they are.  What it has to READ out of a
 * line is small and is here, pure, so tests/test_dbgmsg.c can pin the
 * formats to what the other end's tests show it sending:
 *
 *   <n>: <NAME> <report>       a restart (DEBUGGER's body, after the
 *                              condition line)
 *   <n>: <name>  <file>:<line> a frame (BACKTRACE); the location is
 *                              optional
 *   <name> = <value>           a local (FRAME)
 *   <TYPE> <depth> <count>     the first line of an INSPECT / PART / POP
 *   <object>                   reply, then the object, then
 *   <n>: <label> = <value>     one part per line
 */

#ifndef CLAMACS_DBGMSG_H
#define CLAMACS_DBGMSG_H

#include <stdint.h>

/* Copy the next line of *CURSOR (without its newline) into OUT, at most
 * SIZE bytes with the terminator, and move *CURSOR past it.  Returns 1 when
 * a line was produced, 0 at the end of the text.  A line longer than OUT
 * is cut, not split. */
int32_t ck_dbg_line(const char **cursor, char *out, int32_t size);

/* The row number a line starts with (`3: ...'), or -1. */
int32_t ck_dbg_row_index(const char *line);

/* The source location at the end of a frame line, `<file>:<line>' after two
 * blanks.  Returns 1 and fills FILE (at most SIZE bytes) and LINENO, or 0
 * when the frame has none. */
int32_t ck_dbg_frame_location(const char *line, char *file, int32_t size,
                              int32_t *lineno);

/* The header line of an inspector reply.  Returns 1 and fills TYPE (at
 * most SIZE bytes), DEPTH and COUNT, or 0 when TEXT does not start with
 * one. */
int32_t ck_dbg_inspect_header(const char *text, char *type, int32_t size,
                              int32_t *depth, int32_t *count);

#endif /* CLAMACS_DBGMSG_H */
