/*
 * bindings.h -- the default key tables.
 *
 * Split in two because Lisp mode is the only mode phase 1 has, and the
 * commands that only make sense with a Lisp reader behind them (sexp motion,
 * indentation, everything that talks to clamiga) belong to it rather than to
 * every buffer.  The state machine consults the local map first, so a
 * non-Lisp buffer still gets the whole global table.
 */

#ifndef CLAMACS_BINDINGS_H
#define CLAMACS_BINDINGS_H

#include "keymap.h"

/* Build the phase-1 global map.  Returns NULL when out of memory. */
ck_keymap *ck_bindings_global(void);

/* Build the Lisp-mode map. */
ck_keymap *ck_bindings_lisp(void);

/* Build the REPL window's map (phase 3): the Lisp map with RET, the input
 * history and the interrupt rebound for a listener. */
ck_keymap *ck_bindings_repl(void);

#endif /* CLAMACS_BINDINGS_H */
