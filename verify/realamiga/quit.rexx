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
    'EVAL save-buffers-kill-emacs'
    SAY 'OK asked clamacs to quit'
    CALL waitgone PORT, 'clamacs'
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
