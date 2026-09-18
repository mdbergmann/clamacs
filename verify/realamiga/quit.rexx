/* quit.rexx -- shut clamacs down through its own command namespace, then
** the clamiga the run started.
**
** Separate from drive.rexx so the boot script can take an `avail' reading
** with the editor still up.  Measuring after it has exited would record what
** it failed to give back, not what it uses.
**
** The editor goes first, and clamiga only once the editor's port is gone:
** save-buffers-kill-emacs sends REPL-DETACH to an attached clamiga, which
** must still be there to take it.  clamiga is told to stop by setting the
** flag verify/realamiga/arexx-host.lisp waits on; a clamiga that is not
** running that host (a user's own, say) just gets a variable set in
** CL-USER and carries on.
*/

OPTIONS RESULTS
OPTIONS FAILAT 21

PORT = findport('CLAMACS')
IF PORT = '' THEN
    SAY 'INFO no clamacs port to quit'
ELSE DO
    ADDRESS VALUE PORT
    /* The Lisp editor's teardown trace (frontend-mui.lisp, *EXIT-TRACE*):
    ** every step of START's exit goes to T:clamacs-exit.log, and a window
    ** dispose that signals is written there whether the trace is on or
    ** not.  Read back below, once the port is gone.  The C editor answers
    ** `unknown command' to a form and writes no such log. */
    'EVAL (setf clamacs::*exit-trace* t)'
    traced = (RESULT = 'T')
    /* kill-emacs discards what the run typed into the fixtures without a
    ** requester nobody is here to answer (the Lisp editor asks on
    ** save-buffers-kill-emacs, as Emacs does); the C editor has no
    ** kill-emacs, and its save-buffers-kill-emacs never asked. */
    'EVAL kill-emacs'
    IF RESULT = 'unknown command' THEN 'EVAL save-buffers-kill-emacs'
    SAY 'OK asked clamacs to quit'
    CALL waitgone PORT, 'clamacs'
    IF traced THEN CALL checkexit
END

/* Only the clamiga this run itself started: arexx-host.lisp records its
** port name to T:clamacs-clamiga-port.  SHOW('P', name) only proves a port
** is still registered, not that the task behind it is alive, so messaging
** a port found by scanning CLAMIGA/CLAMIGA.1-9 risks hitting one left by an
** unrelated, already-dead run -- exactly the stale-port hang CLAUDE.md
** warns about ("the sender ... waits forever").  Reading back the name
** this run's own host wrote keeps the send off any port we did not watch
** come up ourselves.
*/
told = 0
name = readport('T:clamacs-clamiga-port')
IF name = '' THEN
    SAY 'INFO no clamiga port file; nothing to quit'
ELSE IF ~SHOW('P', name) THEN
    SAY 'INFO' name 'is already gone'
ELSE DO
    ADDRESS VALUE name
    'EVAL (setf cl-user::*clamacs-host-quit* t)'
    IF RC = 0 THEN DO
        SAY 'OK asked' name 'to quit'
        CALL waitgone name, 'clamiga'
        told = told + 1
    END
    ELSE
        SAY 'FAIL' name 'refused the quit request, rc' RC
END
IF told = 0 THEN
    SAY 'INFO no clamiga port to quit'
EXIT 0

/* The port is what the process holds; once it is gone the process is on
** its way out, and the `avail' reading that follows means something.
*/
waitgone: PROCEDURE
    PARSE ARG port, who
    DO i = 1 TO 10 WHILE SHOW('P', port)
        ADDRESS COMMAND 'C:Wait 1'
    END
    IF SHOW('P', port) THEN
        SAY 'FAIL' port 'is still open ten seconds after' who 'was asked to quit'
    ELSE
        SAY 'OK' port 'is gone'
    RETURN

/* The Lisp editor's exit log, once the port is gone.  The port stops
** BEFORE the windows and the application are disposed of, so the last
** step is waited for.  The whole log is read, since a dispose that
** signalled in the middle of the run (a kill-buffer's reap) lands there
** too: on a Vampire that was the minibuffer class's OM_DISPOSE freeing
** its edit hook through an unowned pointer, and the teardown then left an
** orphan window behind (2026-09-18).  The run scripts delete the log
** before the editor starts, so it is this run's alone.
*/
checkexit: PROCEDURE
    path = 'T:clamacs-exit.log'
    DO i = 1 TO 20
        last = lastline(path)
        IF last = 'clamacs: exit application disposed' THEN LEAVE
        ADDRESS COMMAND 'C:Wait 1'
    END
    IF ~EXISTS(path) THEN DO
        SAY 'FAIL the editor wrote no' path 'although its exit trace was on'
        RETURN
    END
    bad = ''
    IF ~OPEN('xf', path, 'R') THEN DO
        SAY 'FAIL cannot read' path
        RETURN
    END
    DO WHILE ~EOF('xf')
        line = READLN('xf')
        IF POS('signalled', line) > 0 & bad = '' THEN bad = line
    END
    CALL CLOSE('xf')
    IF bad ~= '' THEN
        SAY 'FAIL a window dispose signalled:' bad
    ELSE IF last ~= 'clamacs: exit application disposed' THEN
        SAY 'FAIL the exit log ends with `'last'`, not with the application disposed'
    ELSE
        SAY 'OK the teardown disposed the application and no dispose signalled'
    RETURN

/* The last non-empty line of a file, '' when it is not there. */
lastline: PROCEDURE
    PARSE ARG path
    IF ~EXISTS(path) THEN RETURN ''
    IF ~OPEN('lf', path, 'R') THEN RETURN ''
    last = ''
    DO WHILE ~EOF('lf')
        line = STRIP(READLN('lf'))
        IF line ~= '' THEN last = line
    END
    CALL CLOSE('lf')
    RETURN last

findport: PROCEDURE
    PARSE ARG base
    IF SHOW('P', base) THEN RETURN base
    DO n = 1 TO 9
        IF SHOW('P', base'.'n) THEN RETURN base'.'n
    END
    RETURN ''

/* The one line arexx-host.lisp wrote, or '' if the file is not there --
** an earlier run's clamiga never started, or its host already cleaned up
** after itself on a clean exit.
*/
readport: PROCEDURE
    PARSE ARG path
    IF ~EXISTS(path) THEN RETURN ''
    IF ~OPEN('pf', path, 'R') THEN RETURN ''
    line = READLN('pf')
    CALL CLOSE('pf')
    RETURN STRIP(line)
