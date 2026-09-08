/* quit.rexx -- shut clamacs down through its own command namespace.
**
** Separate from drive.rexx so the boot script can take an `avail' reading
** with the editor still up.  Measuring after it has exited would record what
** it failed to give back, not what it uses.
*/

OPTIONS RESULTS
OPTIONS FAILAT 21

PORT = ''
IF SHOW('P', 'CLAMACS') THEN
    PORT = 'CLAMACS'
ELSE DO n = 1 TO 9
    IF SHOW('P', 'CLAMACS.'n) THEN DO
        PORT = 'CLAMACS.'n
        LEAVE n
    END
END

IF PORT = '' THEN DO
    SAY 'INFO no clamacs port to quit'
    EXIT 0
END

ADDRESS VALUE PORT
'EVAL save-buffers-kill-emacs'
SAY 'OK asked clamacs to quit'
EXIT 0
