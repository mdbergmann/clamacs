/* drive.rexx -- the unattended acceptance run, driven through clamacs's own
** ARexx port: the phase-1 editor and integration checks, then the phase-2
** introspection leg and the phase-3 REPL leg against the same clamiga.
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
** they would under a user's fingers.  (These KEY-command tests still stop
** above the raw-key decoder; the sendkey leg further down drives real
** IECLASS_RAWKEY events through it.)
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
** Raw keys.  Everything above handed ck_keys to the layer BELOW the
** decoder.  These are real IECLASS_RAWKEY events, written to input.device
** by verify/realamiga/sendkey, so they take the whole path a keyboard
** takes: Intuition, the active window, MUI's event handlers, the
** ClamacsText MUIM_HandleEvent override, MapRawKey.  What they answer:
** does Alt reach us as Meta under MUI 3.8; do keys reach the RIGHT object
** (the minibuffer, while it is open); does what we do not bind still fall
** through to the class.
**
** The `<' and `>' are quoted because the command line goes through the
** DOS shell, where they would be redirections.
** ------------------------------------------------------------------ */

SENDKEY = 'Clamacs:build/amiga/sendkey'
IF ~EXISTS(SENDKEY) THEN DO
    SAY 'FAIL no sendkey tool at' SENDKEY '-- the raw-key leg could not run'
END
ELSE DO
    /* OPEN activates the window; give Intuition a moment to make it so. */
    'OPEN FILE Clamacs:verify/realamiga/sample.lisp'
    'EVAL beginning-of-buffer'
    CALL DELAY(25)

    /* An unbound key falls through to the class: the arrow moves the
    ** cursor.  This is also the smoke test -- if the events do not arrive
    ** at all, everything below fails the same way, and sendkey's INFO line
    ** names the window that got them instead. */
    ADDRESS COMMAND SENDKEY '"<down>"'
    CALL DELAY(10)
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = 1 THEN
        SAY 'OK raw <down> reached the class, CursorY' RESULT
    ELSE
        SAY 'FAIL raw <down> CursorY=' RESULT

    /* Control: the decoder must see C-n, not the 0x0E the keymap would
    ** have made of it. */
    ADDRESS COMMAND SENDKEY 'C-n'
    CALL DELAY(10)
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = 2 THEN
        SAY 'OK raw C-n ran next-line, CursorY' RESULT
    ELSE
        SAY 'FAIL raw C-n CursorY=' RESULT

    /* Alt as Meta -- the spec's open question, answered here for MUI 3.8
    ** under emulation.  M-< is Alt+Shift+comma: Shift goes to the keymap
    ** and yields `<'; Alt must reach the decoder rather than MUI. */
    'EVAL end-of-buffer'
    'TE GETCURSOR LINE'
    LASTY = RESULT
    ADDRESS COMMAND SENDKEY '"M-<"'
    CALL DELAY(10)
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = 0 THEN
        SAY 'OK raw M-< (Alt as Meta) reached the top'
    ELSE
        SAY 'FAIL raw M-< CursorY=' RESULT

    /* ESC as Meta: the same command by the other spelling. */
    ADDRESS COMMAND SENDKEY 'ESC ">"'
    CALL DELAY(10)
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = LASTY THEN
        SAY 'OK raw ESC > acted as Meta, CursorY' RESULT
    ELSE
        SAY 'FAIL raw ESC > CursorY=' RESULT '(wanted' LASTY')'

    /* A prefix key and an undefined completion, through the real path. */
    ADDRESS COMMAND SENDKEY 'C-x C-q'
    CALL DELAY(10)
    'STATUS'
    IF POS('undefined', RESULT) > 0 THEN
        SAY 'OK raw C-x C-q went through the prefix map:' RESULT
    ELSE
        SAY 'FAIL raw C-x C-q gave' RESULT

    /* The minibuffer is deliberately NOT driven by injected keys here.
    ** MUI deactivates a programmatically-activated string gadget once the
    ** injected input stream falls idle -- it holds the focus for a single
    ** key -- so `sendkey' can neither type a name into it nor reliably land a
    ** second key on it; a real keyboard streams keys without those gaps.
    ** That is a harness limit, not an editor one: the minibuffer's command
    ** loop, prompt, completion and history are exercised by the KEY leg above
    ** (`M-x opened the minibuffer and C-g closed it') and by the host tests,
    ** and raw typing into it is left for the hardware leg
    ** (specs/clamacs-ide.md, "Still open"). */

    /* Typing, in a buffer nothing else has touched.  RET after `(when x' is
    ** newline-and-indent in Lisp mode; the text after it self-inserts
    ** through the class, with Shift wherever the characters need it. */
    'OPEN FILE Clamacs:verify/realamiga/sample2.lisp'
    'EVAL end-of-buffer'
    CALL DELAY(25)
    ADDRESS COMMAND SENDKEY 'TEXT "(when x"'
    ADDRESS COMMAND SENDKEY 'RET'
    CALL DELAY(10)
    'TE GETCURSOR COLUMN'
    IF RC = 0 & RESULT = 2 THEN
        SAY 'OK raw RET indented the new line to column' RESULT
    ELSE
        SAY 'FAIL raw RET left the cursor at column' RESULT
    ADDRESS COMMAND SENDKEY 'TEXT "(foo Bar)"'
    CALL DELAY(10)
    'TE GETLINE'
    IF POS('(foo Bar)', RESULT) > 0 THEN
        SAY 'OK raw typing self-inserted:' RESULT
    ELSE
        SAY 'FAIL raw typing gave' RESULT
END

/* ------------------------------------------------------------------ *
** The point of the whole thing: driving a real clamiga.
** ------------------------------------------------------------------ */

/* clamiga was started before the editor, but it compiles the port's library
** from source before the port exists, and on an emulated 14 MHz 68020 that
** can outlast the editor leg above.  Two minutes of patience here is what
** separates "slow" from "never came up". */
LISP = ''
DO i = 1 TO 240 WHILE LISP = ''
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

/* ------------------------------------------------------------------ *
** Phase 2: introspection.  Six questions to clamiga -- ARGLIST, COMPLETE,
** SOURCE-LOCATION, DESCRIBE, APROPOS, MACROEXPAND -- each asked the way a
** user asks it (the SLIME keys, through the keymaps), and each answered
** later, so every check waits for the answer to land where it belongs: the
** echo area, the buffer, the cursor, or a scratch window.  intro.lisp holds
** the definitions the answers are about; it is loaded first, since clamiga
** can only describe what it has.  The WaitXxx procedures are at the end.
** ------------------------------------------------------------------ */

INTRO = 'Clamacs:verify/realamiga/intro.lisp'
'OPEN FILE' INTRO
CALL DELAY(25)
'EVAL clamacs-load-buffer'
LOADED = WaitEcho('error(s)', 120)
IF POS('0 error(s)', LOADED) = 1 THEN
    SAY 'OK intro.lisp loaded:' LOADED
ELSE
    SAY 'FAIL intro.lisp load reported' LOADED

/* The arglist in the status line comes from an idle timer: once the cursor
** has rested inside `(twice 21)' for a moment, the editor asks ARGLIST
** twice on its own and caches the answer.  The status line cannot be read
** through the port, but the cache shows: `M-x clamacs-arglist' answers from
** it at once, where a cold cache would have to ask clamiga and answer later.
** An immediate echo is therefore the proof that the idle path ran. */
'GOTOLINE 24'
'TE POSITION SOL'
'KEY C-u 8 C-f'
CALL DELAY(150)
'EVAL clamacs-arglist'
'STATUS'
ARGS = RESULT
IF ARGS = '(twice n)' THEN
    SAY 'OK the idle timer had the arglist ready:' ARGS
ELSE DO
    LATE = WaitEcho('(twice n)', 40)
    IF LATE ~= '' THEN
        SAY 'FAIL the arglist came only when asked for -- the idle timer had not cached it'
    ELSE
        SAY 'FAIL clamacs-arglist gave' ARGS
END

/* M-. on `twice' asks SOURCE-LOCATION and jumps to the DEFUN -- line 9 of
** intro.lisp, CursorY 8 -- in the window that already shows the file, not
** a second one.  M-, comes back to where the cursor was. */
'TE POSITION SOL'
'KEY C-f'
'TE GETCURSOR LINE'
FROM = RESULT
'KEY M-.'
LANDED = WaitCursor(FROM, 40)
'GETFILE'
IF LANDED = 8 & UPPER(RESULT) = UPPER(INTRO) THEN
    SAY 'OK M-. jumped to the definition of twice, CursorY' LANDED
ELSE
    SAY 'FAIL M-. put the cursor at CursorY' LANDED 'in' RESULT
'KEY M-,'
'TE GETCURSOR LINE'
IF RESULT = FROM THEN
    SAY 'OK M-, returned to CursorY' RESULT
ELSE
    SAY 'FAIL M-, went to CursorY' RESULT '(wanted' FROM')'

/* C-c RET macroexpands the form at point once, into a scratch window that
** then has the focus; C-c M-m expands it all the way.  twice-of expands to
** a with-twice, which expands to a let, so the two answers differ. */
'OPEN FILE' INTRO
CALL DELAY(25)
'GOTOLINE 22'
'KEY C-c RET'
LINE = WaitLine('(with-twice z 4 z)', 40)
'GETNAME'
IF LINE ~= '' & RESULT = '*clamacs-macroexpansion*' THEN
    SAY 'OK C-c RET expanded once into' RESULT':' LINE
ELSE
    SAY 'FAIL C-c RET gave' LINE 'in window' RESULT

'OPEN FILE' INTRO
CALL DELAY(25)
'GOTOLINE 22'
'KEY C-c M-m'
LINE = WaitLine('(let ((z (twice 4))) z)', 40)
IF LINE ~= '' THEN
    SAY 'OK C-c M-m expanded fully:' LINE
ELSE
    SAY 'FAIL C-c M-m did not show the full expansion'

/* C-c C-d d describes the symbol at point: the minibuffer opens with it
** filled in, RET accepts (KEY types into the minibuffer as the gadget
** would), and the description lands in a scratch window.  The docstring is
** in it -- the compiler keeping docstrings was the cl-amiga half of this
** phase. */
'OPEN FILE' INTRO
CALL DELAY(25)
'GOTOLINE 24'
'KEY C-f'
'KEY C-c C-d d'
'STATUS'
IF POS('Describe symbol', RESULT) > 0 THEN
    SAY 'OK C-c C-d d prompted:' RESULT
ELSE
    SAY 'FAIL C-c C-d d gave' RESULT
'KEY RET'
LINE = WaitLine('is a SYMBOL', 40)
'GETNAME'
IF POS('TWICE', UPPER(LINE)) > 0 & RESULT = '*clamacs-description*' THEN
    SAY 'OK DESCRIBE opened' RESULT':' LINE
ELSE
    SAY 'FAIL DESCRIBE gave' LINE 'in window' RESULT
IF FindLine('Documentation: Twice N.', 12) THEN
    SAY 'OK the description carries the docstring'
ELSE
    SAY 'FAIL no docstring in the description'

/* C-c C-d a asks for a string, typed here key by key; the answer is one
** line per matching symbol with what it names, in whatever order
** APROPOS-LIST returns them.  The cursor is parked on the in-package line
** first, so the wait cannot match `twice' in intro.lisp itself. */
'OPEN FILE' INTRO
CALL DELAY(25)
'GOTOLINE 7'
'KEY C-c C-d a'
'STATUS'
IF POS('Apropos', RESULT) > 0 THEN
    SAY 'OK C-c C-d a prompted:' RESULT
ELSE
    SAY 'FAIL C-c C-d a gave' RESULT
'KEY t w i c e RET'
LINE = WaitLine('twice', 40)
'GETNAME'
IF LINE ~= '' & RESULT = '*clamacs-apropos*' THEN
    SAY 'OK APROPOS opened' RESULT':' LINE
ELSE
    SAY 'FAIL APROPOS gave' LINE 'in window' RESULT
IF FindLine('twice function', 8) & FindLine('with-twice macro', 8) THEN
    SAY 'OK APROPOS tagged the function and the macro'
ELSE
    SAY 'FAIL APROPOS did not list twice as a function and with-twice as a macro'

/* Completion, in sample2.lisp so that nothing which gets saved changes.  A
** prefix with one candidate is completed in place; one with several hands
** over to the minibuffer, where TAB narrows and RET puts the choice in the
** buffer.  M-TAB and C-M-i are the two spellings of the binding. */
'OPEN FILE Clamacs:verify/realamiga/sample2.lisp'
CALL DELAY(25)
'EVAL end-of-buffer'
'KEY RET'
'INSERT twice-a'
'KEY M-TAB'
DONE = WaitEcho('Sole completion', 40)
'TE GETLINE'
IF DONE ~= '' & POS('twice-again', RESULT) > 0 THEN
    SAY 'OK M-TAB completed twice-a in place:' RESULT
ELSE
    SAY 'FAIL M-TAB gave' DONE 'and the line' RESULT

'KEY RET'
'INSERT twic'
'KEY C-M-i'
PROMPTED = WaitEcho('Complete:', 40)
IF PROMPTED ~= '' THEN
    SAY 'OK C-M-i handed the candidates to the minibuffer'
ELSE
    SAY 'FAIL C-M-i on twic did not prompt'
/* twice, twice-again and twice-of: intro.lisp defines all three. */
'KEY TAB'
'STATUS'
IF POS('3 completions', RESULT) > 0 & POS('twice-again', RESULT) > 0 THEN
    SAY 'OK TAB listed them:' RESULT
ELSE
    SAY 'FAIL TAB in the minibuffer gave' RESULT
'KEY - a TAB'
'STATUS'
IF POS('Sole completion', RESULT) > 0 THEN
    SAY 'OK TAB narrowed twice-a to one'
ELSE
    SAY 'FAIL narrowing gave' RESULT
'KEY RET'
'TE GETLINE'
IF POS('twice-again', RESULT) > 0 THEN
    SAY 'OK RET put the completion in the buffer:' RESULT
ELSE
    SAY 'FAIL after RET the line is' RESULT

/* ------------------------------------------------------------------ *
** Phase 3: the REPL window.  C-c C-z opens *clamacs-repl* and attaches
** clamiga's REPL thread to the editor's own port; from then on the
** conversation is two-way -- the editor sends REPL-EVAL and gets OUTPUT,
** READLINE and RESULT back as commands at its port -- so every check here
** waits for text to land in the transcript.  The cursor is parked at the
** prompt by every RESULT, so after RET at prompt line P the value is on
** line P+1 (0-based) and the next prompt on P+2, and a check reads those
** lines by number, then goes back to the end before typing again: INSERT
** goes through the port, below the Emacs layer that keeps typing inside
** the input.
** ------------------------------------------------------------------ */

'OPEN FILE' INTRO
CALL DELAY(25)
'KEY C-c C-z'
'GETNAME'
IF RESULT = '*clamacs-repl*' THEN
    SAY 'OK C-c C-z opened' RESULT
ELSE
    SAY 'FAIL C-c C-z gave window' RESULT

/* The first attach loads dev-repl in clamiga -- gray streams and CLOS,
** compiled from source when the FASL cache is cold -- so the prompt can
** be minutes away on an emulated 68020. */
LINE = WaitLine('CL-USER> ', 360)
IF GetLine() = 'CL-USER> ' THEN
    SAY 'OK the REPL prompt arrived:' GetLine()
ELSE DO
    'STATUS'
    SAY 'FAIL no REPL prompt; the cursor line is' GetLine() 'and the echo area says' RESULT
END

/* RET sends the input and the value comes back on the next line. */
'TE GETCURSOR LINE'
P = RESULT
'INSERT (+ 1 2)'
'KEY RET'
Y = WaitCursorAt(P + 2, 40)
'GOTOLINE' P + 2
L = GetLine()
IF Y ~= '' & L = 3 THEN
    SAY 'OK RET evaluated (+ 1 2) at the prompt:' L
ELSE
    SAY 'FAIL the line after (+ 1 2) is' L '(cursor' Y')'
'GOTOLINE' P + 3
L = GetLine()
IF L = 'CL-USER> ' THEN
    SAY 'OK a new prompt followed the value'
ELSE
    SAY 'FAIL after the value came' L
'EVAL end-of-buffer'

/* Output is streamed as it is printed -- two OUTPUT commands, one per
** line -- and the value follows it.  Symbols rather than strings, so no
** quote has to travel through the port's ReadArgs template. */
'TE GETCURSOR LINE'
P = RESULT
'INSERT (progn (princ ''hello) (terpri) (princ ''there) 42)'
'KEY RET'
Y = WaitCursorAt(P + 4, 40)
'GOTOLINE' P + 2
L1 = GetLine()
'GOTOLINE' P + 3
L2 = GetLine()
'GOTOLINE' P + 4
L3 = GetLine()
IF Y ~= '' & L1 = 'HELLO' & L2 = 'THERE' & L3 = 42 THEN
    SAY 'OK output was streamed line by line before the value:' L1 L2 L3
ELSE
    SAY 'FAIL streamed output gave' L1 '/' L2 '/' L3 '(cursor' Y')'
'EVAL end-of-buffer'

/* READ-LINE asks the editor: READLINE arms an input line, RET answers it
** with REPL-INPUT, and the form's first value is the line typed (its
** second, missing-newline-p, is printed on the line after, so the wait is
** for the cursor to get past the typed line rather than for an exact
** line). */
'TE GETCURSOR LINE'
P = RESULT
'INSERT (read-line)'
'KEY RET'
ASKED = WaitEcho('reading a line', 40)
IF ASKED ~= '' THEN
    SAY 'OK READLINE armed the input:' ASKED
ELSE
    SAY 'FAIL READLINE did not arm the input'
'INSERT abc'
'KEY RET'
Y = WaitCursorPast(P + 2, 40)
'GOTOLINE' P + 3
L = GetLine()
IF Y ~= '' & POS('"abc"', L) > 0 THEN
    SAY 'OK RET answered READ-LINE and the value came back:' L
ELSE
    SAY 'FAIL after the READ-LINE answer came' L '(cursor' Y')'
'EVAL end-of-buffer'

/* C-c C-c interrupts a running form: REPL-INTERRUPT reaches the REPL
** thread at a safepoint inside the tight loop and the form ends with
** RESULT 10 and `ERROR: Interrupted'. */
'TE GETCURSOR LINE'
P = RESULT
'INSERT (loop)'
'KEY RET'
CALL DELAY(50)
'KEY C-c C-c'
Y = WaitCursorAt(P + 2, 60)
'GOTOLINE' P + 2
L = GetLine()
IF Y ~= '' & POS('Interrupted', L) > 0 THEN
    SAY 'OK C-c C-c interrupted (loop):' L
ELSE
    SAY 'FAIL the interrupt gave' L '(cursor' Y')'
'EVAL end-of-buffer'

/* IN-PACKAGE at the prompt moves the prompt, and back. */
'INSERT (in-package :ext.dev)'
'KEY RET'
LINE = WaitLine('EXT.DEV> ', 40)
IF LINE ~= '' THEN
    SAY 'OK the prompt followed IN-PACKAGE:' LINE
ELSE
    SAY 'FAIL the prompt did not change package'
'INSERT (in-package :cl-user)'
'KEY RET'
LINE = WaitLine('CL-USER> ', 40)
IF LINE ~= '' THEN
    SAY 'OK and back to' LINE
ELSE
    SAY 'FAIL the prompt did not come back to CL-USER'

/* M-p / M-n walk the input history at the prompt. */
'KEY M-p'
L = GetLine()
IF POS('(in-package :cl-user)', L) > 0 THEN
    SAY 'OK M-p brought back the last input:' L
ELSE
    SAY 'FAIL M-p gave' L
'KEY M-p'
L = GetLine()
IF POS('(in-package :ext.dev)', L) > 0 THEN
    SAY 'OK a second M-p went one further back'
ELSE
    SAY 'FAIL the second M-p gave' L
'KEY M-n'
'KEY M-n'
L = GetLine()
IF L = 'CL-USER> ' THEN
    SAY 'OK M-n came back to the empty input'
ELSE
    SAY 'FAIL M-n left' L

/* The port's handler thread stays free while a form runs: an ARGLIST
** asked from a source buffer during (sleep 6) is answered inside it.
** twice-again has not been asked about before, so the answer has to come
** from clamiga, not the cache; the call is typed at the end of intro.lisp
** (not saved) because the file holds no call to it. */
'INSERT (sleep 6)'
'KEY RET'
'OPEN FILE' INTRO
CALL DELAY(10)
'EVAL end-of-buffer'
'KEY RET'
'INSERT (twice-again 1'
'EVAL clamacs-arglist'
ARGS = WaitEcho('(twice-again n)', 8)
IF ARGS ~= '' THEN
    SAY 'OK the port answered ARGLIST while the REPL ran a form:' ARGS
ELSE
    SAY 'FAIL no ARGLIST answer while the REPL was busy'
'KEY C-c C-z'
'GETNAME'
LINE = WaitLine('CL-USER> ', 40)
IF RESULT = '*clamacs-repl*' & LINE ~= '' THEN
    SAY 'OK C-c C-z raised the REPL again and (sleep 6) finished'
ELSE
    SAY 'FAIL back in' RESULT 'the cursor line is' LINE

/* Leave the errors file active, as the phase-1 leg did: the shipped macro
** runs next on whatever window is active, and its verdict on errors.lisp
** is what verify-amiga expects. */
'OPEN FILE Clamacs:verify/realamiga/errors.lisp'
CALL DELAY(25)

SAY 'DRIVE-DONE'
EXIT 0

/* ------------------------------------------------------------------ *
** Waiting for an answer.  The editor never blocks on clamiga, so a command
** that asks something returns before the answer exists; each of these polls
** the port twice a second until what it waits for is there, or TICKS
** half-seconds have passed.  A timeout returns '' (or 0), and the check
** that follows reports what WAS there.
** ------------------------------------------------------------------ */

/* The echo area, once it contains NEEDLE. */
WaitEcho: PROCEDURE EXPOSE PORT
    PARSE ARG needle, ticks
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO ticks
        'STATUS'
        IF RC = 0 & POS(needle, RESULT) > 0 THEN RETURN RESULT
        CALL DELAY(25)
    END
    RETURN ''

/* The line under the cursor of the active window, once it contains NEEDLE.
** A reply that fills a scratch window also activates it, and puts the
** cursor on its first line. */
WaitLine: PROCEDURE EXPOSE PORT
    PARSE ARG needle, ticks
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO ticks
        'TE GETLINE'
        IF RC = 0 & POS(needle, RESULT) > 0 THEN RETURN RESULT
        CALL DELAY(25)
    END
    RETURN ''

/* The cursor line (0-based, as GETCURSOR reports it), once it is no longer
** FROM. */
WaitCursor: PROCEDURE EXPOSE PORT
    PARSE ARG from, ticks
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO ticks
        'TE GETCURSOR LINE'
        IF RC = 0 & RESULT ~= from THEN RETURN RESULT
        CALL DELAY(25)
    END
    RETURN ''

/* The cursor line as text.  The class's GETLINE keeps the line's newline
** on it, which is invisible in a POS() check and fatal to an `=' one. */
GetLine: PROCEDURE EXPOSE PORT
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    'TE GETLINE'
    IF RC ~= 0 THEN RETURN ''
    line = RESULT
    IF RIGHT(line, 1) == '0A'x THEN line = LEFT(line, LENGTH(line) - 1)
    RETURN line

/* The cursor line, once it is past Y (0-based): a RESULT has arrived
** whose number of value lines is not fixed in advance. */
WaitCursorPast: PROCEDURE EXPOSE PORT
    PARSE ARG y, ticks
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO ticks
        'TE GETCURSOR LINE'
        IF RC = 0 & RESULT > y THEN RETURN RESULT
        CALL DELAY(25)
    END
    RETURN ''

/* The cursor line, once it is exactly Y (0-based).  Every RESULT parks the
** cursor at the new prompt, so this is how the REPL leg knows a form is
** done. */
WaitCursorAt: PROCEDURE EXPOSE PORT
    PARSE ARG y, ticks
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO ticks
        'TE GETCURSOR LINE'
        IF RC = 0 & RESULT = y THEN RETURN RESULT
        CALL DELAY(25)
    END
    RETURN ''

/* Whether one of the first N lines of the active window contains NEEDLE.
** Moves the cursor. */
FindLine: PROCEDURE EXPOSE PORT
    PARSE ARG needle, n
    OPTIONS RESULTS
    ADDRESS VALUE PORT
    DO i = 1 TO n
        'GOTOLINE' i
        'TE GETLINE'
        IF RC = 0 & POS(needle, RESULT) > 0 THEN RETURN 1
    END
    RETURN 0
