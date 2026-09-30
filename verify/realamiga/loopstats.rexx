/* loopstats.rexx [RESET] -- the Lisp editor's event-loop account.
 *
 * Asks the editor's port for LOOP-STATS-REPORT (frontend-mui.lisp): what
 * woke the loop and which methods MUI called on the classes since the
 * last reset, with rates.  RESET zeroes the counters instead of printing
 * them -- run-cpu-idle.sh resets at the start of a phase and prints at
 * its end.  The port is CLAMACS, the first Lisp editor's.
 */
PARSE ARG mode
OPTIONS RESULTS
ADDRESS 'CLAMACS'
IF UPPER(mode) = 'RESET' THEN DO
    'EVAL (clamacs::loop-stats-reset)'
    EXIT 0
END
'EVAL (clamacs::loop-stats-report)'
IF rc ~= 0 THEN DO
    'LASTRESULT'
    SAY 'loopstats: rc' rc result
    EXIT rc
END
SAY result
EXIT 0
