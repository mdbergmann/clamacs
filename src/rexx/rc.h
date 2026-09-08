/*
 * rc.h -- the ARexx return-code ladder.
 *
 * These values are not arbitrary and they are not ours: ARexx aborts a macro
 * when a command's return code reaches FAILAT, which defaults to 10.  That
 * is why clamiga puts warnings at 5 (a style warning must not kill an editor
 * macro) and errors at 10 (a failed load must).  See cl-amiga's
 * lib/dev-commands.lisp, which defines the other end of this contract.
 *
 * Its own header because both halves of the ARexx client need it -- the
 * queue, to decide what to send next, and the diagnostic parser, to grade
 * what came back -- and neither owns it.
 */

#ifndef CLAMACS_RC_H
#define CLAMACS_RC_H

#include <stdint.h>

#define CK_RC_OK     0
#define CK_RC_WARN   5
#define CK_RC_ERROR  10
#define CK_RC_FATAL  20

/* ARexx only carries RESULT with rc 0, so any other rc has to be followed by
 * a LASTRESULT to recover the text that came with it. */
int32_t ck_rc_needs_lastresult(int32_t rc);

#endif /* CLAMACS_RC_H */
