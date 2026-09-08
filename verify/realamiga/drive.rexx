/* drive.rexx -- phase-1 smoke test, driven through clamacs's own ARexx port.
**
** This is the shape specs/clamacs-ide.md asks for under Testing: a script
** that talks to the editor the way a user's macro would, so the run is
** unattended and the result is a log rather than a screenshot.  Every line
** printed here lands in build/amiga/clamacs-test.log; verify-amiga greps it.
**
** OPTIONS FAILAT 21 so a command that answers with an error return code does
** not abort the script before it can report what happened.
*/

OPTIONS RESULTS
OPTIONS FAILAT 21

/* MUI's startup on an emulated 14 MHz 68020 is not instant: the class
** scan, the config load and the first window layout all happen before the
** application object exists, and the port comes with it.  Wait for it
** properly rather than assuming it is already there. */
IF ~SHOW('L', 'rexxsupport.library') THEN
    CALL ADDLIB('rexxsupport.library', 0, -30, 0)

/* MUI numbers the port it builds from MUIA_Application_Base, and on MUI 3.8
** the FIRST instance already comes up as CLAMACS.1 -- observed, not assumed.
** So scan the way the spec has the editor scan for CLAMIGA: the base name,
** then .1 .. .9.  A macro written against clamacs has to do the same. */
PORT = ''
DO i = 1 TO 120 WHILE PORT = ''
    IF SHOW('P', 'CLAMACS') THEN
        PORT = 'CLAMACS'
    ELSE DO n = 1 TO 9
        IF SHOW('P', 'CLAMACS.'n) THEN DO
            PORT = 'CLAMACS.'n
            LEAVE n
        END
    END
    IF PORT = '' THEN CALL DELAY(25)    /* 1/2 second */
END

IF PORT = '' THEN DO
    /* Name every public port, so a port that exists under a name we did not
    ** expect identifies itself instead of leaving us guessing. */
    SAY 'FAIL no clamacs ARexx port appeared'
    SAY 'INFO public ports:' SHOW('P')
    EXIT 10
END
SAY 'OK clamacs ARexx port is' PORT

ADDRESS VALUE PORT

/* The file the boot script asked for should be the active document. */
'GETFILE'
IF RC = 0 & POS('sample.lisp', RESULT) > 0 THEN
    SAY 'OK GETFILE' RESULT
ELSE
    SAY 'FAIL GETFILE rc=' RC 'result=' RESULT

/* Two line-numbering conventions meet here, and the difference is
** deliberate rather than an oversight:
**   GOTOLINE (ours)          1-based -- what `file:12:' in a diagnostic
**                            means, and what the error list clicks through
**                            to.
**   TE GETCURSOR LINE        0-based -- the class returns MUIA_TextEditor_
**                            CursorY verbatim (checked in HandleARexx.c).
** So line 3 to us is cursor line 2 to the class. */
'GOTOLINE 3'
IF RC = 0 THEN SAY 'OK GOTOLINE' ; ELSE SAY 'FAIL GOTOLINE rc=' RC

'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 2 THEN
    SAY 'OK GOTOLINE 3 put the cursor on CursorY' RESULT
ELSE
    SAY 'FAIL CURSOR rc=' RC 'CursorY=' RESULT

/* EVAL runs an EDITOR command by name -- the same namespace M-x uses. */
'EVAL end-of-buffer'
IF RC = 0 THEN SAY 'OK EVAL end-of-buffer' ; ELSE SAY 'FAIL EVAL rc=' RC

'EVAL beginning-of-buffer'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 0 THEN
    SAY 'OK beginning-of-buffer moved to CursorY' RESULT
ELSE
    SAY 'FAIL beginning-of-buffer CursorY=' RESULT

/* The sexp scanner, on the real thing: from inside the body of frobnicate,
** beginning-of-defun must find the `(' in column 0 that opens it -- line 3
** of sample.lisp, CursorY 2.  This is the editor's own code, not the
** class's: it exports a window of lines, finds a clean starting point and
** scans. */
'GOTOLINE 6'
'EVAL beginning-of-defun'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 2 THEN
    SAY 'OK beginning-of-defun found the defun at CursorY' RESULT
ELSE
    SAY 'FAIL beginning-of-defun CursorY=' RESULT

'EVAL end-of-defun'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 7 THEN
    SAY 'OK end-of-defun reached CursorY' RESULT
ELSE
    SAY 'FAIL end-of-defun CursorY=' RESULT

/* A command that does not exist must be reported, not run. */
'EVAL no-such-command'
IF RESULT = 'unknown command' THEN
    SAY 'OK unknown command rejected'
ELSE
    SAY 'FAIL unknown command gave' RESULT

/* Insert text and read the line back. */
'EVAL end-of-buffer'
'INSERT (list 1 2 3)'
'TE GETLINE'
IF POS('(list 1 2 3)', RESULT) > 0 THEN
    SAY 'OK INSERT and GETLINE round trip'
ELSE
    SAY 'FAIL GETLINE gave' RESULT

/* backward-sexp over the form just inserted must land on its open paren,
** which is column 0 of that line. */
'EVAL backward-sexp'
'TE GETCURSOR COLUMN'
IF RC = 0 & RESULT = 0 THEN
    SAY 'OK backward-sexp landed on the open paren, column' RESULT
ELSE
    SAY 'FAIL backward-sexp column=' RESULT

/* Opening a second file must give a second window. */
'OPEN FILE Clamacs:verify/realamiga/sample2.lisp LINE 2'
IF RC = 0 THEN SAY 'OK OPEN second file' ; ELSE SAY 'FAIL OPEN rc=' RC

'GETFILE'
IF POS('sample2.lisp', RESULT) > 0 THEN
    SAY 'OK second document is active' RESULT
ELSE
    SAY 'FAIL active document is' RESULT

/* ------------------------------------------------------------------ *
** The Emacs layer, driven by KEYS rather than by command names.
**
** Everything above went in through the ARexx commands, which walk straight
** past the keymaps.  These go through them: prefix maps, the C-u argument
** reader, C-g, the kill ring and the minibuffer all take part, exactly as
** they would under a user's fingers.  (The raw-key decoder itself still
** needs a real keyboard -- see the open question in the spec.)
** ------------------------------------------------------------------ */

'OPEN FILE Clamacs:verify/realamiga/sample.lisp'
'EVAL beginning-of-buffer'

/* A prefix key must leave the sequence pending and say so. */
'KEY C-x'
'STATUS'
IF RESULT = 'C-x -' THEN
    SAY 'OK C-x is pending and echoed as' RESULT
ELSE
    SAY 'FAIL C-x echoed' RESULT

/* ... and C-g must abandon it. */
'KEY C-g'
'STATUS'
IF RESULT = 'Quit' THEN
    SAY 'OK C-g cancelled the prefix'
ELSE
    SAY 'FAIL C-g gave' RESULT

/* An undefined sequence is ours: reported, and not passed to the class
** (where the trailing key would have inserted itself). */
'KEY C-x C-q'
'STATUS'
IF POS('undefined', RESULT) > 0 THEN
    SAY 'OK C-x C-q reported:' RESULT
ELSE
    SAY 'FAIL C-x C-q gave' RESULT

/* C-u 4 C-n moves four lines, not one. */
'EVAL beginning-of-buffer'
'KEY C-u 4 C-n'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 4 THEN
    SAY 'OK C-u 4 C-n moved four lines, CursorY' RESULT
ELSE
    SAY 'FAIL C-u 4 C-n CursorY=' RESULT

/* M-> and M-< are Meta keys through the same path. */
'KEY M-<'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 0 THEN
    SAY 'OK M-< reached the top'
ELSE
    SAY 'FAIL M-< CursorY=' RESULT

/* The kill ring: C-SPC, move, C-w, then C-y puts it back.  None of this is
** the class's -- the class has a clipboard, not a ring. */
'EVAL beginning-of-buffer'
'TE GETLINE'
FIRSTLINE = RESULT
'KEY C-SPC'
'KEY C-n'
'KEY C-w'
'EVAL beginning-of-buffer'
'TE GETLINE'
IF RESULT ~= FIRSTLINE THEN
    SAY 'OK C-w killed the first line'
ELSE
    SAY 'FAIL C-w did not change the buffer'

'KEY C-y'
'EVAL beginning-of-buffer'
'TE GETLINE'
IF RESULT = FIRSTLINE THEN
    SAY 'OK C-y yanked it back:' RESULT
ELSE
    SAY 'FAIL C-y gave' RESULT

/* M-x opens the minibuffer, and C-g closes it again. */
'KEY M-x'
'STATUS'
'KEY C-g'
'STATUS'
IF RESULT = 'Quit' THEN
    SAY 'OK M-x opened the minibuffer and C-g closed it'
ELSE
    SAY 'FAIL minibuffer C-g gave' RESULT

/* Tab reindents through the Lisp indenter -- a Lisp-mode binding, so this
** also proves the mode map is live in a .lisp buffer. */
'GOTOLINE 6'
'TE POSITION SOL'
'KEY TAB'
'TE GETCURSOR COLUMN'
IF RC = 0 & RESULT = 4 THEN
    SAY 'OK TAB indented the (when ...) line to column' RESULT
ELSE
    SAY 'FAIL TAB put the cursor at column' RESULT

/* ------------------------------------------------------------------ *
** The point of the whole thing: driving a real clamiga.
** ------------------------------------------------------------------ */

LISP = ''
DO i = 1 TO 60 WHILE LISP = ''
    IF SHOW('P', 'CLAMIGA') THEN
        LISP = 'CLAMIGA'
    ELSE DO n = 1 TO 9
        IF SHOW('P', 'CLAMIGA.'n) THEN DO
            LISP = 'CLAMIGA.'n
            LEAVE n
        END
    END
    IF LISP = '' THEN CALL DELAY(25)
END

IF LISP = '' THEN DO
    SAY 'INFO no clamiga port -- skipping the integration leg'
    SAY 'DRIVE-DONE'
    EXIT 0
END
SAY 'OK clamiga ARexx port is' LISP

/* C-x C-e: evaluate the last expression before point.  The spec's
** acceptance criterion is literally "C-x C-e on (+ 1 2) echoes 3". */
ADDRESS VALUE PORT
'OPEN FILE Clamacs:verify/realamiga/eval.lisp'
'EVAL end-of-buffer'
'STATUS'
BEFORE = RESULT
'EVAL clamacs-eval-last-sexp'

/* The client never blocks on a reply, so the answer arrives later -- poll
** the echo area for it rather than assuming it is already there. */
ANSWER = ''
DO i = 1 TO 60
    CALL DELAY(25)
    'STATUS'
    IF RESULT ~= BEFORE & RESULT ~= '' THEN DO
        ANSWER = RESULT
        LEAVE
    END
END

IF ANSWER = '3' THEN
    SAY 'OK eval-last-sexp on (+ 1 2) echoed' ANSWER
ELSE
    SAY 'FAIL eval-last-sexp echoed' ANSWER

/* C-c C-k on a file with two errors.  The reply comes back with rc 10, so
** ARexx drops RESULT and the editor has to fetch the text with LASTRESULT
** on its own before it can report anything -- that whole round trip is
** under test here, not just the load. */
'OPEN FILE Clamacs:verify/realamiga/errors.lisp'
'STATUS'
BEFORE = RESULT
'EVAL clamacs-load-buffer'

/* And while that load is in flight, the editor must still answer.  This is
** the "stays responsive while clamiga compiles" criterion: if the client
** waited for its reply, this GETFILE would not come back until the load
** finished. */
'GETFILE'
IF POS('errors.lisp', RESULT) > 0 THEN
    SAY 'OK the editor answered while a load was in flight'
ELSE
    SAY 'FAIL editor did not answer during a load:' RESULT

DIAGS = ''
DO i = 1 TO 120
    CALL DELAY(25)
    'STATUS'
    IF POS('error(s)', RESULT) > 0 THEN DO
        DIAGS = RESULT
        LEAVE
    END
END

IF POS('2 error(s)', DIAGS) > 0 THEN
    SAY 'OK clamacs-load-buffer reported' DIAGS
ELSE
    SAY 'FAIL load-buffer diagnostics were' DIAGS

/* "selecting one jumps to the file and line" -- the other acceptance
** criterion of the error list.  next-error shares its position and its jump
** with the list, so driving the keyboard command exercises the same code a
** mouse click would, which is the only way to reach it without a mouse. */
'EVAL clamacs-next-error'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 6 THEN
    SAY 'OK next-error jumped to the first error, CursorY' RESULT
ELSE
    SAY 'FAIL next-error CursorY=' RESULT

'EVAL clamacs-next-error'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 8 THEN
    SAY 'OK next-error jumped to the second error, CursorY' RESULT
ELSE
    SAY 'FAIL second next-error CursorY=' RESULT

/* And walking off the end must say so rather than wrap or crash. */
'EVAL clamacs-next-error'
'STATUS'
IF POS('No further', RESULT) > 0 THEN
    SAY 'OK next-error stopped at the last diagnostic:' RESULT
ELSE
    SAY 'FAIL next-error past the end gave' RESULT

'EVAL clamacs-previous-error'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 6 THEN
    SAY 'OK previous-error went back to CursorY' RESULT
ELSE
    SAY 'FAIL previous-error CursorY=' RESULT

SAY 'DRIVE-DONE'
EXIT 0
