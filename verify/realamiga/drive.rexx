/* drive.rexx -- the unattended acceptance run, driven through clamacs's own
** ARexx port: the phase-1 editor checks, the window-position snapshot
** (with a second editor started to see the restore), then the integration
** checks, the phase-2 introspection leg, the phase-3 REPL leg and the
** phase-4 debugger and inspector leg against the same clamiga.
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

/* `RX drive.rexx HARDWARE' (what run-drive says) enables the leg that only a
** real input chain can pass: keys into an ACTIVE minibuffer String.  Under
** FS-UAE MUI deactivates a programmatically activated String after one
** injected key, so that leg is skipped there rather than failed.
**
** `PHASE n' runs the legs the Lisp editor (specs/clamacs-lisp.md) has
** reached: 2 is the editor checks and the integration leg, 3 adds the
** introspection leg, 4 the REPL and debugger legs, 5 (the default: all of
** it, what the C editor answers) the menu strip and the window snapshot.
** The checks themselves are the same either way -- the script talks to a
** port and reads a log, so it does not know which language answered.
**
** `LISP <clamiga>' names the clamiga binary the snapshot leg starts its
** SECOND editor with (the Lisp editor, from Clamacs:lisp/clamacs.lisp);
** without it the second editor is the C binary, Clamacs:build/amiga/clamacs. */
MODE = ''
PHASE = 5
CLAMIGA = ''
PARSE UPPER ARG ARGS
DO WHILE ARGS ~= ''
    PARSE VAR ARGS WORD ARGS
    SELECT
        WHEN WORD = 'HARDWARE' THEN MODE = 'HARDWARE'
        WHEN WORD = 'PHASE' THEN PARSE VAR ARGS PHASE ARGS
        WHEN WORD = 'LISP' THEN PARSE VAR ARGS CLAMIGA ARGS
        OTHERWISE SAY 'INFO ignoring argument' WORD
    END
END
IF CLAMIGA = '' THEN
    SECOND = 'Clamacs:build/amiga/clamacs Clamacs:verify/realamiga/sample2.lisp'
ELSE
    SECOND = CLAMIGA '--no-userinit --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- Clamacs:verify/realamiga/sample2.lisp'

/* MUI's startup on an emulated 14 MHz 68020 is not instant: the class
** scan, the config load and the first window layout all happen before the
** application object exists, and the port comes with it.  Wait for it
** properly rather than assuming it is already there.
**
** Every pause goes through `pause' below, a C Delay() in sendkey, so the
** script needs no rexxsupport.library. */

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
    IF PORT = '' THEN CALL pause 25    /* 1/2 second */
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

/* A launch of clamiga whose CPU loses memory stores cannot be gated: the
** Apollo 68080 drops a store depending on where the data hunk landed, so
** about every second launch on a Vampire fails somewhere at random
** (cl-amiga's README "CPU store self-test"; it was finding (C) of the
** phase-3 hardware run, two days of hunting a bug that was not there).
** clamiga's startup self-test puts :CPU-LOST-STORES on *FEATURES* on such
** a launch; asked here, before anything is driven, so the log names the
** cause and no leg below is chased.  Relaunch and rerun.  The C editor
** answers `unknown command' to a form and has no such CPU under it. */
CALL checkstores PORT, 'the editor'

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

/* An argument starting with `(' is a FORM, evaluated in the editor's own
** Lisp -- the live-hacking door.  What the form PRINTS comes back in front
** of its values, which is the whole point for everything that REPORTS
** instead of returning: the editor has no console of its own, so without
** the capture the report is not misplaced, it is lost.
**
** These two legs are the ONE place the script knows which language
** answered: the C editor's EVAL looks a command name up and nothing else
** (src/rexxport.c, ck_rx_eval_func), so a form there is simply an unknown
** command.  It is frozen and will not grow the door, so the legs run only
** for the Lisp editor -- the run that passed `LISP <clamiga>'. */
IF CLAMIGA ~= '' THEN DO
'EVAL (progn (princ "printed") 42)'
IF RC = 0 & POS('printed', RESULT) > 0 & POS('42', RESULT) > 0 THEN
    SAY 'OK EVAL of a form answered with what it printed and its value'
ELSE
    SAY 'FAIL EVAL of a printing form gave rc=' RC 'result=' RESULT

/* And (room) on the editor's own heap, the reason a user reaches for this:
** it prints from C (cl_write_cstring_to_stdout), so this leg is the one
** that proves the runtime honours the editor's rebound *STANDARD-OUTPUT*
** on the MUI task -- a per-thread binding, read from C. */
'EVAL (room)'
IF RC = 0 & POS('Heap:', RESULT) > 0 & POS('bytes free', RESULT) > 0 THEN
    SAY 'OK EVAL (room) reported the editor heap,' LENGTH(RESULT) 'characters'
ELSE
    SAY 'FAIL EVAL (room) gave rc=' RC 'result=' RESULT
END /* CLAMIGA ~= '': the form-eval legs, Lisp editor only */

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

/* Close it again over the port, then bring it back: a window reaped
** from the event loop in the middle of a run, with the editor going on
** afterwards.  On a Vampire this is where the Lisp editor froze the
** machine on 2026-09-18 (its minibuffer class's OM_DISPOSE signalled and
** the window was disposed of twice); quit.rexx then reads the editor's
** exit log for any dispose that signalled.  The reopen restores the
** state the legs below expect: sample2.lisp active, so that nothing
** they type lands in a buffer the shipped macro later saves. */
'EVAL kill-buffer'
'GETFILE'
IF POS('sample2.lisp', RESULT) = 0 THEN
    SAY 'OK kill-buffer closed the second document; the active document is now' RESULT
ELSE
    SAY 'FAIL kill-buffer left' RESULT 'active'
'OPEN FILE Clamacs:verify/realamiga/sample2.lisp LINE 2'
'GETFILE'
IF RC = 0 & POS('sample2.lisp', RESULT) > 0 THEN
    SAY 'OK the second document is open again after kill-buffer'
ELSE
    SAY 'FAIL reopening after kill-buffer gave rc=' RC 'active=' RESULT

/* ------------------------------------------------------------------ *
** The menu strip.  MENU <command> picks the item the way the mouse
** would (on the active document, only while it is enabled); MENU
** <command> STATE reports whether it is enabled.  What is under test is
** the editor's side of the menu: that the items exist, that the enable
** state follows the buffer, and that a pick runs the command.  MUI's own
** path from IDCMP_MENUPICK to MUIA_Application_MenuAction is MUI's.
** ------------------------------------------------------------------ */

IF PHASE >= 5 THEN DO
'MENU find-file STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK the menu strip has Open'
ELSE
    SAY 'FAIL MENU find-file STATE gave' RESULT

/* Cursor motion is deliberately not in the menu. */
'MENU forward-char STATE'
IF RESULT = 'no such menu item' THEN
    SAY 'OK forward-char is not a menu item'
ELSE
    SAY 'FAIL MENU forward-char STATE gave' RESULT

/* Save follows the buffer: dimmed while it is clean, enabled by the first
** edit, dimmed again once the menu has saved it.  A file in RAM: so the
** fixtures are not written to. */
'OPEN FILE RAM:clamacs-menu-test.lisp'
'MENU save-buffer STATE'
IF RESULT = 'disabled' THEN
    SAY 'OK Save is dimmed for a clean buffer'
ELSE
    SAY 'FAIL Save on a clean buffer is' RESULT
'INSERT (defun menu-test () 42)'
'MENU save-buffer STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK the first edit enabled Save'
ELSE
    SAY 'FAIL Save after an edit is' RESULT
'MENU save-buffer'
IF RC = 0 & RESULT = '' & EXISTS('RAM:clamacs-menu-test.lisp') THEN
    SAY 'OK the menu saved the buffer'
ELSE
    SAY 'FAIL MENU save-buffer rc=' RC 'result=' RESULT 'exists=' EXISTS('RAM:clamacs-menu-test.lisp')
'MENU save-buffer STATE'
IF RESULT = 'disabled' THEN
    SAY 'OK Save dimmed after the menu saved'
ELSE
    SAY 'FAIL Save after the save is' RESULT

/* Close Buffer from the menu; the saved buffer goes without a question. */
'MENU kill-buffer'
'GETFILE'
IF POS('clamacs-menu-test', RESULT) = 0 THEN
    SAY 'OK Close Buffer closed it; the active document is now' RESULT
ELSE
    SAY 'FAIL Close Buffer left' RESULT 'active'

/* A pick runs the command on the active document: the same defun the
** EVAL check above found from line 6. */
'OPEN FILE Clamacs:verify/realamiga/sample.lisp'
'GOTOLINE 6'
'MENU beginning-of-defun'
'TE GETCURSOR LINE'
IF RC = 0 & RESULT = 2 THEN
    SAY 'OK the menu ran beginning-of-defun, CursorY' RESULT
ELSE
    SAY 'FAIL the menu pick left CursorY=' RESULT

/* The REPL window's own items are dimmed in a file buffer. */
'MENU clamacs-repl-clear STATE'
IF RESULT = 'disabled' THEN
    SAY 'OK Clear Transcript is dimmed outside the REPL'
ELSE
    SAY 'FAIL Clear Transcript in a file buffer is' RESULT

/* Help > Common Lisp HyperSpec is always live.  Only its STATE is asked:
** a pick hands the URL to openurl.library, which the test image does not
** have, and the requester that follows would park an unattended run. */
'MENU clamacs-hyperspec STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK the Help menu has the HyperSpec'
ELSE
    SAY 'FAIL MENU clamacs-hyperspec STATE gave' RESULT
END /* PHASE >= 5: the menu strip */

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
    CALL pause 25

    /* An unbound key falls through to the class: the arrow moves the
    ** cursor.  This is also the smoke test -- if the events do not arrive
    ** at all, everything below fails the same way, and sendkey's INFO line
    ** names the window that got them instead. */
    ADDRESS COMMAND SENDKEY '"<down>"'
    CALL pause 10
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = 1 THEN
        SAY 'OK raw <down> reached the class, CursorY' RESULT
    ELSE
        SAY 'FAIL raw <down> CursorY=' RESULT

    /* Control: the decoder must see C-n, not the 0x0E the keymap would
    ** have made of it. */
    ADDRESS COMMAND SENDKEY 'C-n'
    CALL pause 10
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
    CALL pause 10
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = 0 THEN
        SAY 'OK raw M-< (Alt as Meta) reached the top'
    ELSE
        SAY 'FAIL raw M-< CursorY=' RESULT

    /* ESC as Meta: the same command by the other spelling. */
    ADDRESS COMMAND SENDKEY 'ESC ">"'
    CALL pause 10
    'TE GETCURSOR LINE'
    IF RC = 0 & RESULT = LASTY THEN
        SAY 'OK raw ESC > acted as Meta, CursorY' RESULT
    ELSE
        SAY 'FAIL raw ESC > CursorY=' RESULT '(wanted' LASTY')'

    /* A prefix key and an undefined completion, through the real path. */
    ADDRESS COMMAND SENDKEY 'C-x C-q'
    CALL pause 10
    'STATUS'
    IF POS('undefined', RESULT) > 0 THEN
        SAY 'OK raw C-x C-q went through the prefix map:' RESULT
    ELSE
        SAY 'FAIL raw C-x C-q gave' RESULT

    /* The minibuffer is NOT driven by injected keys under FS-UAE.  MUI
    ** there deactivates a programmatically-activated string gadget once the
    ** injected input stream falls idle -- it holds the focus for a single
    ** key -- so `sendkey' can neither type a name into it nor reliably land a
    ** second key on it; a real keyboard streams keys without those gaps.
    ** That is a harness limit, not an editor one: the minibuffer's command
    ** loop, prompt, completion and history are exercised by the KEY leg above
    ** (`M-x opened the minibuffer and C-g closed it') and by the host tests.
    ** On real hardware (run-drive passes HARDWARE) the String stays active
    ** and the leg below drives it, which is the only way to see the keys an
    ** ACTIVE String would otherwise keep: TAB, C-g, Alt-x (the
    ** MUIA_String_EditHook in ClamacsMini, specs/clamacs-ide.md). */
    IF MODE = 'HARDWARE' THEN DO
        'OPEN FILE Clamacs:verify/realamiga/sample.lisp'
        'EVAL beginning-of-buffer'
        CALL pause 25

        /* TAB inside the active minibuffer completes instead of cycling
        ** the focus: the sole completion of `end-of-b' is reported, and
        ** RET then runs it. */
        ADDRESS COMMAND SENDKEY 'M-x'
        CALL pause 10
        ADDRESS COMMAND SENDKEY 'TEXT "end-of-b"'
        ADDRESS COMMAND SENDKEY 'TAB'
        CALL pause 10
        'STATUS'
        IF POS('completion', RESULT) > 0 THEN
            SAY 'OK raw TAB completed inside the active minibuffer:' RESULT
        ELSE
            SAY 'FAIL raw TAB in the active minibuffer gave' RESULT
        ADDRESS COMMAND SENDKEY 'RET'
        CALL pause 10
        'TE GETCURSOR LINE'
        IF RC = 0 & RESULT > 0 THEN
            SAY 'OK raw RET ran the completed command, CursorY' RESULT
        ELSE
            SAY 'FAIL raw RET after the completion left CursorY=' RESULT

        /* Alt-x while a prompt is open: neither a stray `×' in the input nor
        ** a lost key -- it is reported undefined, and the prompt stays. */
        ADDRESS COMMAND SENDKEY 'M-x'
        CALL pause 10
        ADDRESS COMMAND SENDKEY 'M-x'
        CALL pause 10
        'STATUS'
        IF POS('undefined', RESULT) > 0 THEN
            SAY 'OK raw M-x inside the active minibuffer is undefined:' RESULT
        ELSE
            SAY 'FAIL raw M-x inside the active minibuffer gave' RESULT

        /* C-g from the active minibuffer aborts the prompt. */
        ADDRESS COMMAND SENDKEY 'C-g'
        CALL pause 10
        'STATUS'
        IF RESULT = 'Quit' THEN
            SAY 'OK raw C-g aborted the active minibuffer'
        ELSE
            SAY 'FAIL raw C-g in the active minibuffer gave' RESULT

        /* Isearch: the pattern is typed into the active String, C-s searches
        ** again from there, and C-g abandons the search.  `sample' is in
        ** the docstring and again in `*sample*' further down. */
        'EVAL beginning-of-buffer'
        ADDRESS COMMAND SENDKEY 'C-s'
        CALL pause 10
        ADDRESS COMMAND SENDKEY 'TEXT "sample"'
        CALL pause 10
        'TE GETCURSOR LINE'
        FIRSTHIT = RESULT
        ADDRESS COMMAND SENDKEY 'C-s'
        CALL pause 10
        'TE GETCURSOR LINE'
        IF RC = 0 & RESULT > FIRSTHIT THEN
            SAY 'OK raw C-s searched again from the active minibuffer, CursorY' RESULT
        ELSE
            SAY 'FAIL raw C-s in isearch left CursorY=' RESULT '(first hit' FIRSTHIT')'
        ADDRESS COMMAND SENDKEY 'C-g'
        CALL pause 10
        'STATUS'
        IF RESULT = 'Quit' THEN
            SAY 'OK raw C-g abandoned isearch from the active minibuffer'
        ELSE
            SAY 'FAIL raw C-g in isearch gave' RESULT
    END

    /* Typing, in a buffer nothing else has touched.  RET after `(when x' is
    ** newline-and-indent in Lisp mode; the text after it self-inserts
    ** through the class, with Shift wherever the characters need it. */
    'OPEN FILE Clamacs:verify/realamiga/sample2.lisp'
    'EVAL end-of-buffer'
    CALL pause 25
    ADDRESS COMMAND SENDKEY 'TEXT "(when x"'
    ADDRESS COMMAND SENDKEY 'RET'
    CALL pause 10
    'TE GETCURSOR COLUMN'
    IF RC = 0 & RESULT = 2 THEN
        SAY 'OK raw RET indented the new line to column' RESULT
    ELSE
        SAY 'FAIL raw RET left the cursor at column' RESULT
    ADDRESS COMMAND SENDKEY 'TEXT "(foo Bar)"'
    CALL pause 10
    'TE GETLINE'
    IF POS('(foo Bar)', RESULT) > 0 THEN
        SAY 'OK raw typing self-inserted:' RESULT
    ELSE
        SAY 'FAIL raw typing gave' RESULT
END

/* ------------------------------------------------------------------ *
** Window positions.  clamacs-snapshot-windows writes where every open
** window is to ENV:Clamacs/windows.cfg and ENVARC:, and GETWINDOW says
** where the active window is and under which role, so the file can be
** checked against the window.  The restore cannot be seen in THIS
** editor -- a window is placed when it is created, from a file read at
** startup -- so a SECOND editor is started against a file this script
** writes, and asked where its first window came up.  Both files are
** deleted afterwards: the Workbench image the run leaves behind must not
** carry a snapshot into the next run.
** ------------------------------------------------------------------ */

IF PHASE >= 5 THEN DO
CFG     = 'ENV:Clamacs/windows.cfg'
ARCHIVE = 'ENVARC:Clamacs/windows.cfg'

/* The error list is opened too, so a fixed window is in the snapshot
** beside the file windows; sample.lisp, opened at startup, is doc1. */
'EVAL clamacs-show-errors'
'OPEN FILE Clamacs:verify/realamiga/sample.lisp'
CALL pause 10
'GETWINDOW'
PLACE = RESULT
PARSE VAR PLACE ROLE L T W H .
IF RC = 0 & ROLE = 'doc1' & DATATYPE(L, 'W') & DATATYPE(T, 'W') & DATATYPE(W, 'W') & DATATYPE(H, 'W') & W > 0 & H > 0 THEN
    SAY 'OK GETWINDOW answered' PLACE
ELSE
    SAY 'FAIL GETWINDOW gave' PLACE

'EVAL clamacs-snapshot-windows'
'STATUS'
IF POS('Saved the positions', RESULT) > 0 THEN
    SAY 'OK the snapshot was taken:' RESULT
ELSE
    SAY 'FAIL clamacs-snapshot-windows said' RESULT

IF EXISTS(CFG) & EXISTS(ARCHIVE) THEN
    SAY 'OK the snapshot wrote ENV: and ENVARC:'
ELSE
    SAY 'FAIL after the snapshot ENV: has' EXISTS(CFG) 'and ENVARC: has' EXISTS(ARCHIVE)

/* The line for the active window must say what GETWINDOW said, and the
** error list must have a line of its own. */
IF FileHasLine(CFG, PLACE) THEN
    SAY 'OK the file holds the active window as' PLACE
ELSE
    SAY 'FAIL no line' PLACE 'in' CFG
IF FileHasLine(ARCHIVE, PLACE) THEN
    SAY 'OK ENVARC: holds the same line'
ELSE
    SAY 'FAIL no line' PLACE 'in' ARCHIVE
IF FileHasPrefix(CFG, 'errors ') THEN
    SAY 'OK the file holds the error list'
ELSE
    SAY 'FAIL no errors line in' CFG

/* A second editor, against a file with a place of our choosing for its
** first window: it must come up there.  Its port is the first CLAMACS
** name that is not ours.  A comment line and a blank line go in front,
** as a hand-edited file would have them. */
WANT = 'doc1 24 48 400 160'
IF WriteFile(CFG, '; written by drive.rexx' || '0A'x || '0A'x || WANT || '0A'x) THEN
    SAY 'OK wrote a file of our own:' WANT
ELSE
    SAY 'FAIL could not write' CFG
ADDRESS COMMAND 'Run >NIL:' SECOND
PORT2 = ''
DO i = 1 TO 120 WHILE PORT2 = ''
    IF SHOW('P', 'CLAMACS') & 'CLAMACS' ~= PORT THEN
        PORT2 = 'CLAMACS'
    ELSE DO n = 1 TO 9
        IF SHOW('P', 'CLAMACS.'n) & 'CLAMACS.'n ~= PORT THEN DO
            PORT2 = 'CLAMACS.'n
            LEAVE n
        END
    END
    IF PORT2 = '' THEN CALL pause 25
END
IF PORT2 = '' THEN
    SAY 'FAIL no second editor port appeared'
ELSE DO
    SAY 'OK a second editor is at' PORT2
    ADDRESS VALUE PORT2
    /* The port comes with the application object, before the first
    ** window is opened: wait for a window to answer. */
    GOT = ''
    DO i = 1 TO 40 WHILE GOT = ''
        'GETWINDOW'
        IF RC = 0 & RESULT ~= '' THEN GOT = RESULT
        ELSE CALL pause 25
    END
    IF GOT = WANT THEN
        SAY 'OK a second editor came up where the file said:' GOT
    ELSE
        SAY 'FAIL the second editor came up at' GOT '(wanted' WANT')'
    'EVAL save-buffers-kill-emacs'
    DO i = 1 TO 20 WHILE SHOW('P', PORT2)
        CALL pause 25
    END
    IF SHOW('P', PORT2) THEN
        SAY 'FAIL the second editor did not quit'
    ELSE
        SAY 'OK the second editor quit'
    ADDRESS VALUE PORT
END
ADDRESS COMMAND 'Delete >NIL: QUIET' CFG ARCHIVE
IF EXISTS(CFG) | EXISTS(ARCHIVE) THEN
    SAY 'FAIL the snapshot files could not be deleted'
ELSE
    SAY 'OK the snapshot files are gone again'
END /* PHASE >= 5: the window snapshot */

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
    IF LISP = '' THEN CALL pause 25
END

IF LISP = '' THEN DO
    SAY 'INFO no clamiga port -- skipping the integration leg'
    SAY 'DRIVE-DONE'
    EXIT 0
END
SAY 'OK clamiga ARexx port is' LISP

/* The target clamiga is a launch of its own, with a data hunk of its
** own: the same check as for the editor (see the top). */
CALL checkstores LISP, 'the target clamiga'

/* C-x C-e: evaluate the last expression before point.  The spec's
** acceptance criterion is literally "C-x C-e on (+ 1 2) echoes 3". */
ADDRESS VALUE PORT
'OPEN FILE Clamacs:verify/realamiga/eval.lisp'
'EVAL end-of-buffer'
'STATUS'
BEFORE = RESULT
'EVAL clamacs-eval-last-sexp'

/* The client never blocks on a reply, so the answer arrives later -- poll
** the echo area for it rather than assuming it is already there.  A buffer
** eval runs on clamiga's REPL thread, and this is the first one: the
** editor opens the REPL window and attaches it first, which loads dev-repl
** in clamiga -- gray streams and CLOS, compiled from source when the FASL
** cache is cold, so minutes on an emulated 68020 -- and the echo area
** says other things (`clamiga found on ...') on the way.  So wait for the
** value itself, and generously: a cold cache took the first attach past
** the 180 s the REPL leg budgets (2026-09-14), the value arriving only
** after that leg had given up. */
ANSWER = ''
LAST = ''
DO i = 1 TO 900
    CALL pause 25
    'STATUS'
    IF RESULT = '3' THEN DO
        ANSWER = RESULT
        LEAVE
    END
    IF RESULT ~= BEFORE & RESULT ~= '' THEN LAST = RESULT
END

IF ANSWER = '3' THEN
    SAY 'OK eval-last-sexp on (+ 1 2) echoed' ANSWER 'after' i '/ 2 s (the first eval attaches the REPL)'
ELSE
    SAY 'FAIL eval-last-sexp echoed' LAST

/* That eval attached the REPL: its window exists, and the buffer that
** asked kept the focus. */
'GETNAME'
IF RESULT = 'eval.lisp' THEN
    SAY 'OK the buffer eval left eval.lisp active:' RESULT
ELSE
    SAY 'FAIL after the buffer eval the active window is' RESULT

/* That request found the port, so the Clamiga menu is live now and Start
** clamiga is not. */
IF PHASE >= 5 THEN DO
'MENU clamacs-eval-defun STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK the Clamiga menu woke up with the port'
ELSE
    SAY 'FAIL Eval Defun with a port is' RESULT
'MENU run-lisp STATE'
IF RESULT = 'disabled' THEN
    SAY 'OK Start clamiga is dimmed while connected'
ELSE
    SAY 'FAIL Start clamiga while connected is' RESULT
END

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
    CALL pause 25
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

/* The reply filled the error list, which is what enables Next Error. */
IF PHASE >= 5 THEN DO
'MENU clamacs-next-error STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK Next Error woke up with the diagnostics'
ELSE
    SAY 'FAIL Next Error with two diagnostics is' RESULT
END

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
IF PHASE < 3 THEN DO
    SAY 'INFO PHASE' PHASE': the introspection, REPL and debugger legs are not run'
    SIGNAL Done
END
'OPEN FILE' INTRO
CALL pause 25
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
CALL pause 150
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
CALL pause 25
'GOTOLINE 22'
'KEY C-c RET'
LINE = WaitLine('(with-twice z 4 z)', 40)
'GETNAME'
IF LINE ~= '' & RESULT = '*clamacs-macroexpansion*' THEN
    SAY 'OK C-c RET expanded once into' RESULT':' LINE
ELSE
    SAY 'FAIL C-c RET gave' LINE 'in window' RESULT

'OPEN FILE' INTRO
CALL pause 25
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
CALL pause 25
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
CALL pause 25
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
CALL pause 25
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

IF PHASE < 4 THEN DO
    SAY 'INFO PHASE' PHASE': the REPL and debugger legs are not run'
    SIGNAL Done
END
'OPEN FILE' INTRO
CALL pause 25
'KEY C-c C-z'
'GETNAME'
IF RESULT = '*clamacs-repl*' THEN DO
    SAY 'OK C-c C-z opened' RESULT
    IF PHASE >= 5 THEN DO
        'MENU clamacs-repl-clear STATE'
        IF RESULT = 'enabled' THEN
            SAY 'OK Clear Transcript is live in the REPL window'
        ELSE
            SAY 'FAIL Clear Transcript in the REPL window is' RESULT
    END
END
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
CALL pause 50
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
CALL pause 10
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

/* ------------------------------------------------------------------ *
** Phase 4: the debugger and inspector windows.  The REPL was attached
** with DEBUG, so an error at the prompt does not end the form: clamiga's
** REPL thread parks on the erring stack and sends DEBUGGER 1, the editor
** opens its debugger window, asks for the backtrace and then for frame
** 0's locals, and echoes each step in the REPL's echo area -- the last
** of which, `Debugger level N, frame 0: <first local>', is the state a
** poll can rely on.  The window's lists and buttons want a mouse, so the
** commands behind them are driven by name here, as M-x would.  dbg-fn
** and dbg-go-on are in intro.lisp, loaded by the phase-2 leg, so no
** string has to travel through INSERT's ReadArgs template.
** ------------------------------------------------------------------ */

'EVAL clamacs-repl'
'EVAL end-of-buffer'
'TE GETCURSOR LINE'
P = RESULT
'INSERT (dbg-fn 3 4)'
'KEY RET'
ECHO = WaitEcho('Debugger level 1, frame 0: ARG0 = 3', 60)
IF ECHO ~= '' THEN
    SAY 'OK an error at the prompt opened the debugger:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL no debugger for (dbg-fn 3 4); the echo area says' RESULT
END

/* The Windows menu's Debugger item follows the DEBUGGER messages (the
** menu strip is phase 5 of the Lisp port). */
IF PHASE >= 5 THEN DO
    'MENU clamacs-debugger STATE'
    IF RESULT = 'enabled' THEN
        SAY 'OK the Debugger item woke up with the debugger'
    ELSE
        SAY 'FAIL the Debugger item while debugging is' RESULT
END
CALL LispView 'level 1'

/* The transcript is closed while the form is parked. */
'KEY RET'
'STATUS'
IF POS('in the debugger', RESULT) > 0 THEN
    SAY 'OK RET at the prompt is refused while debugging:' RESULT
ELSE
    SAY 'FAIL RET while debugging gave' RESULT

/* Eval in frame 0, with the locals bound under their placeholder names;
** the values come back as OUTPUT into the transcript, after the input
** line (the cursor follows the append, as it does for any output). */
'EVAL clamacs-debugger-eval'
'STATUS'
IF POS('Eval in frame 0', RESULT) > 0 THEN
    SAY 'OK clamacs-debugger-eval prompted:' RESULT
ELSE
    SAY 'FAIL clamacs-debugger-eval gave' RESULT
'KEY ( l i s t SPC a r g 0 SPC a r g 1 )'
'KEY RET'
Y = WaitCursorAt(P + 2, 40)
'GOTOLINE' P + 2
L = GetLine()
IF Y ~= '' & L = '(3 4)' THEN
    SAY 'OK the frame eval saw the locals by name:' L
ELSE
    SAY 'FAIL the frame eval gave' L '(cursor' Y')'
'EVAL end-of-buffer'

/* An error inside the frame eval is a nested level -- a different frame
** 0, with ARG0 = 1 -- and ABORT there returns to level 1, announced
** again with its own frame 0. */
'EVAL clamacs-debugger-eval'
'KEY ( d b g - f n SPC 1 SPC 2 )'
'KEY RET'
ECHO = WaitEcho('Debugger level 2, frame 0: ARG0 = 1', 40)
IF ECHO ~= '' THEN
    SAY 'OK an error in the frame eval nested the debugger:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL no nested debugger; the echo area says' RESULT
END
CALL LispView 'level 2'
'EVAL clamacs-debugger-abort'
ECHO = WaitEcho('Debugger level 1, frame 0: ARG0 = 3', 40)
IF ECHO ~= '' THEN
    SAY 'OK ABORT returned to level 1:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL ABORT from level 2 left the echo area at' RESULT
END
CALL LispView 'after the abort'

/* A restart by number: 0 is the REPL's own ABORT, so the form ends with
** `; Aborted' as its value and a fresh prompt. */
'EVAL clamacs-debugger-restart'
'KEY 0'
'KEY RET'
LINE = WaitLine('CL-USER> ', 40)
IF LINE ~= '' THEN DO
    SAY 'OK RESTART 0 returned to the prompt'
    IF PHASE >= 5 THEN DO
        'MENU clamacs-debugger STATE'
        IF RESULT = 'disabled' THEN
            SAY 'OK the Debugger item dimmed with the restart'
        ELSE
            SAY 'FAIL the Debugger item after the restart is' RESULT
    END
END
ELSE DO
    'STATUS'
    SAY 'FAIL no prompt after RESTART 0; the echo area says' RESULT
END
'TE GETCURSOR LINE'
Q = RESULT
'GOTOLINE' Q
L = GetLine()
IF L = '; Aborted' THEN
    SAY 'OK the transcript says the form was aborted:' L
ELSE
    SAY 'FAIL before the prompt came' L
'EVAL end-of-buffer'

/* CONTINUE: a CERROR's restart, and the form goes on to its value. */
'TE GETCURSOR LINE'
P = RESULT
'INSERT (dbg-go-on)'
'KEY RET'
ECHO = WaitEcho('Debugger level 1, frame 0', 60)
IF ECHO ~= '' THEN
    SAY 'OK CERROR opened the debugger:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL no debugger for (dbg-go-on); the echo area says' RESULT
END
'EVAL clamacs-debugger-continue'
LINE = WaitLine('CL-USER> ', 40)
'GOTOLINE' P + 2
L = GetLine()
IF LINE ~= '' & L = ':WENT-ON' THEN
    SAY 'OK CONTINUE let the form finish:' L
ELSE
    SAY 'FAIL after CONTINUE came' L
'EVAL end-of-buffer'

/* A buffer eval reaches the debugger too (2026-09-14): C-x C-e on a form
** that errors runs on the same REPL thread, so it parks there and the
** debugger window opens, with the echo lines going to the buffer that
** asked; Abort brings `; Aborted' back to that echo area.  The buffer is
** a file in RAM: that does not exist yet -- Open... on such a name makes
** an empty buffer of it (the New file path) -- saved and closed at the
** end so quitting never asks about it. */
'OPEN FILE RAM:clamacs-bufeval-test.lisp'
'STATUS'
IF RESULT = '(New file)' THEN
    SAY 'OK Open... on a name no file has made a new buffer:' RESULT
ELSE
    SAY 'FAIL Open... on a new name said' RESULT
'INSERT (dbg-fn 5 6)'
'EVAL clamacs-eval-last-sexp'
ECHO = WaitEcho('Debugger level 1, frame 0: ARG0 = 5', 60)
IF ECHO ~= '' THEN
    SAY 'OK an error in a buffer eval opened the debugger:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL no debugger for the buffer eval of (dbg-fn 5 6); the echo area says' RESULT
END
'EVAL clamacs-debugger-abort'
ECHO = WaitEcho('Aborted', 40)
IF ECHO ~= '' THEN
    SAY 'OK Abort ended the buffer eval in its own echo area:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL after Abort the buffer''s echo area says' RESULT
END
/* By name, not through the menu: the same commands on both editors. */
'EVAL save-buffer'
'EVAL kill-buffer'
'EVAL clamacs-repl'
'EVAL end-of-buffer'

/* The inspector: C-c I evaluates a form in clamiga and the window shows
** the object and its numbered parts; a part descends, Back comes up.
** The inspector window takes the focus when it opens, so the REPL is
** raised again before each command typed by name. */
'KEY C-c I'
'STATUS'
IF POS('Inspect value', RESULT) > 0 THEN
    SAY 'OK C-c I prompted:' RESULT
ELSE
    SAY 'FAIL C-c I gave' RESULT
'KEY ( l i s t SPC 1 SPC ( l i s t SPC 2 SPC 3 ) )'
'KEY RET'
ECHO = WaitEcho('Inspecting CONS: (1 (2 3))', 40)
IF ECHO ~= '' THEN
    SAY 'OK the inspector showed the object:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL the inspector did not answer; the echo area says' RESULT
END
'EVAL clamacs-repl'
'EVAL clamacs-inspector-part'
'KEY 1'
'KEY RET'
ECHO = WaitEcho('Inspecting CONS: ((2 3))', 40)
IF ECHO ~= '' THEN
    SAY 'OK part 1 descended into the cdr:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL PART 1 gave' RESULT
END
'EVAL clamacs-repl'
'EVAL clamacs-inspector-pop'
ECHO = WaitEcho('Inspecting CONS: (1 (2 3))', 40)
IF ECHO ~= '' THEN
    SAY 'OK Back came up to the list again:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL POP gave' RESULT
END
'EVAL clamacs-repl'

/* ------------------------------------------------------------------ *
** The editor's own Lisp (the Lisp editor only: the C editor has no such
** item).  Clamiga > Talk to the Editor Itself switches the wire over: the
** REPL window is detached from clamiga and attached to the EDITOR's image
** -- loading dev-repl into the editor on this first attach, so the wait
** is long -- and a form at that prompt runs in the editor.  (room) there
** reports the editor's heap, IN-EDITOR reaches the MUI task and answers
** with the active window, and Talk to clamiga switches back.
** ------------------------------------------------------------------ */
IF CLAMIGA ~= '' & PHASE >= 5 THEN DO
'MENU clamacs-connect-self STATE'
IF RESULT = 'enabled' THEN
    SAY 'OK Talk to the Editor Itself is live while talking to clamiga'
ELSE
    SAY 'FAIL Talk to the Editor Itself is' RESULT
'MENU clamacs-connect-self'
ECHO = WaitEcho('REPL attached to the editor itself', 360)
IF ECHO ~= '' THEN
    SAY 'OK the REPL moved to the editor itself:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL the REPL did not attach to the editor itself; the echo area says' RESULT
END
'EVAL end-of-buffer'
'TE GETCURSOR LINE'
P = RESULT
'INSERT (room)'
'KEY RET'
/* ROOM's lines stream in ahead of RESULT and move the cursor with them:
** the form is done only when the cursor sits on the next prompt. */
Y = WaitCursorPast(P + 2, 120)
IF Y ~= '' THEN Y = WaitLine('CL-USER> ', 120)
'GOTOLINE' P + 2
L = GetLine()
IF Y ~= '' & POS('Heap:', L) > 0 THEN
    SAY 'OK (room) at the self REPL reported the editor heap:' L
ELSE DO
    'STATUS'
    SAY 'FAIL (room) at the self REPL gave' L '(cursor' Y'); the echo area says' RESULT
    DO i = P - 2 TO P + 4
        'GOTOLINE' i
        SAY 'INFO self REPL line' i':' GetLine()
    END
END
'EVAL end-of-buffer'
'TE GETCURSOR LINE'
P = RESULT
'INSERT (clamacs:in-editor (clamacs::doc-name (clamacs::editor-active-document clamacs::*editor*)))'
'KEY RET'
Y = WaitCursorAt(P + 2, 120)
'GOTOLINE' P + 2
L = GetLine()
IF Y ~= '' & POS('*clamacs-repl*', L) > 0 THEN
    SAY 'OK IN-EDITOR ran on the MUI task and named the active window:' L
ELSE
    SAY 'FAIL IN-EDITOR gave' L '(cursor' Y')'
'EVAL end-of-buffer'
'MENU clamacs-connect-clamiga'
ECHO = WaitEcho('REPL attached to CLAMIGA', 120)
IF ECHO ~= '' THEN
    SAY 'OK Talk to clamiga moved the REPL back:' ECHO
ELSE DO
    'STATUS'
    SAY 'FAIL the REPL did not come back to clamiga; the echo area says' RESULT
END
'EVAL end-of-buffer'
END /* CLAMIGA ~= '' & PHASE >= 5: the editor's own Lisp */

/* Leave the errors file active, as the phase-1 leg did: the shipped macro
** runs next on whatever window is active, and its verdict on errors.lisp
** is what verify-amiga expects. */
Done:
ADDRESS VALUE PORT
'OPEN FILE Clamacs:verify/realamiga/errors.lisp'
CALL pause 25

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
        CALL pause 25
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
        CALL pause 25
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
        CALL pause 25
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
        CALL pause 25
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
        CALL pause 25
    END
    RETURN ''

/* clamiga's own view of the debugger, for the log: the current level's
** restarts and backtrace, asked over its port directly.  INFO lines only
** -- the checks are made through the editor -- but when one of those
** fails, this says which side got it wrong. */
LispView: PROCEDURE EXPOSE PORT LISP
    PARSE ARG what
    OPTIONS RESULTS
    ADDRESS VALUE LISP
    'RESTARTS'
    IF RC = 0 THEN SAY 'INFO restarts at' what':' RESULT
    ELSE SAY 'INFO RESTARTS at' what 'answered rc' RC
    'BACKTRACE'
    IF RC = 0 THEN SAY 'INFO backtrace at' what':' RESULT
    ADDRESS VALUE PORT
    RETURN

/* Whether PATH has a line that is exactly WANT (trailing blanks aside). */
FileHasLine: PROCEDURE
    PARSE ARG path, want
    IF ~OPEN('wf', path, 'R') THEN RETURN 0
    found = 0
    DO WHILE ~EOF('wf')
        IF STRIP(READLN('wf')) == want THEN found = 1
    END
    CALL CLOSE('wf')
    RETURN found

/* Whether PATH has a line that starts with PREFIX. */
FileHasPrefix: PROCEDURE
    PARSE ARG path, prefix
    IF ~OPEN('wf', path, 'R') THEN RETURN 0
    found = 0
    DO WHILE ~EOF('wf')
        IF LEFT(READLN('wf'), LENGTH(prefix)) == prefix THEN found = 1
    END
    CALL CLOSE('wf')
    RETURN found

/* Replace PATH with TEXT. */
WriteFile: PROCEDURE
    PARSE ARG path, text
    IF ~OPEN('wf', path, 'W') THEN RETURN 0
    CALL WRITECH('wf', text)
    CALL CLOSE('wf')
    RETURN 1

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

/* Whether the clamiga behind PORT lost memory stores on this launch
** (the 68080 defect, see the top): asks the port to evaluate a form.  A
** T ends the run with a FAIL that names the cause -- every leg after it
** would fail at random and mean nothing.  The C editor answers `unknown
** command' and is left alone. */
checkstores: PROCEDURE
    PARSE ARG port, who
    OPTIONS RESULTS
    OPTIONS FAILAT 21
    ADDRESS VALUE port
    'EVAL (if (member :cpu-lost-stores *features*) "LOST-STORES" "STORES-OK")'
    IF RC ~= 0 THEN DO
        SAY 'INFO' who 'did not answer the CPU store question (rc' RC'):' RESULT
        RETURN
    END
    IF POS('LOST-STORES', RESULT) > 0 THEN DO
        SAY 'FAIL' who 'is a launch that LOSES MEMORY STORES (clamiga''s startup self-test, the 68080 defect): this run is void, relaunch it and run again'
        SAY 'DRIVE-DONE'
        EXIT 10
    END
    IF POS('STORES-OK', RESULT) > 0 THEN
        SAY 'OK' who 'keeps its stores on this launch'
    ELSE
        SAY 'INFO' who 'answered the CPU store question with:' RESULT
    RETURN

/* A pause of TICKS/50 s without rexxsupport.library (see the top of the
** script): dos.library's Delay() through sendkey's WAIT option.  sendkey
** is at the fixed place run-drive and the FS-UAE boot scripts put it. */
pause: PROCEDURE
    PARSE ARG ticks
    ADDRESS COMMAND 'Clamacs:build/amiga/sendkey WAIT' ticks
    RETURN
