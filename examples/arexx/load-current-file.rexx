/* load-current-file.rexx -- load the buffer clamacs is showing into clamiga.
**
** The clamacs counterpart of cl-amiga's examples/amiga/arexx/
** load-current-file.ced, which does the same job from CygnusEd.  Copy it to
** REXX: and run it with `rx load-current-file'; bind it to a key from your
** shell or a Workbench icon if you like, though inside clamacs you would
** normally just press C-c C-k.
**
** Start the port on the clamiga side first -- these two lines belong in
** S:.clamigarc:
**
**     (require "amiga/arexx")
**     (amiga.arexx:start)
*/

OPTIONS RESULTS

/* FAILAT 21 is not optional.  ARexx aborts a macro when a command's return
** code reaches the FAILAT threshold, and the default is 10 -- which is
** exactly the code clamiga returns for `your file has errors'.  Without
** this the macro would die at the moment it had something to report. */
OPTIONS FAILAT 21

EDITOR = FindPort('CLAMACS')
IF EDITOR = '' THEN DO
    SAY 'clamacs is not running.'
    EXIT 10
END

LISP = FindPort('CLAMIGA')
IF LISP = '' THEN DO
    SAY 'clamiga is not running, or its ARexx port is not started.'
    EXIT 10
END

/* --- save the buffer so clamiga loads what is on screen -------------- */

ADDRESS VALUE EDITOR
'GETFILE'
FILENAME = RESULT
IF FILENAME = '' THEN DO
    SAY 'Save this buffer to a file first.'
    EXIT 10
END
'SAVE'

/* --- load it ---------------------------------------------------------- */

ADDRESS VALUE LISP
'LOAD "' || FILENAME || '"'
RC_LOAD = RC

IF RC_LOAD = 0 THEN DO
    SAY 'Loaded' FILENAME 'OK.'
    EXIT 0
END

/* rc /= 0, so ARexx did not give us RESULT: ask for the text explicitly.
** This is the protocol, not a clamiga quirk -- a result string may only
** accompany a zero return code. */
ADDRESS VALUE LISP
'LASTRESULT'
DIAGS = RESULT

IF RC_LOAD >= 10 THEN
    SAY 'Load failed:' DIAGS
ELSE
    SAY 'Loaded with warnings:' DIAGS

EXIT RC_LOAD

/* Both programs number a second instance's port: CLAMACS.1, CLAMIGA.1, and
** so on.  Any macro that does not scan works until the day someone starts a
** second copy -- and on MUI 3.8 the FIRST clamacs already comes up as
** CLAMACS.1, so scanning is not a corner case here, it is the normal path. */
FindPort:
    PARSE ARG base
    IF SHOW('P', base) THEN RETURN base
    DO i = 1 TO 9
        IF SHOW('P', base'.'i) THEN RETURN base'.'i
    END
    RETURN ''
