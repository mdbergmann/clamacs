/*
 * sendkey -- type into the active window through input.device.
 *
 *     sendkey C-x C-q            press keys, spelled the way the editor
 *     sendkey M-< RET <down>     spells them (see src/emacs/keymap.c)
 *     sendkey TEXT "(foo Bar)"   type a string
 *
 * The unattended test drives clamacs through its ARexx port, and the port's
 * KEY command stops one step short of a real keyboard: it feeds ck_keys to
 * the keymaps, so the raw-key decoder and the MUI event routing in front of
 * it are never exercised.  This tool closes that gap.  Each key is written
 * to input.device as an IECLASS_RAWKEY event (a press and a release), so it
 * travels the whole path a finger on the keyboard would: the input handler
 * chain, Intuition, the active window's IDCMP, MUI's event handlers, the
 * ClamacsText MUIM_HandleEvent override, MapRawKey.
 *
 * Raw codes come from keymap.library's MapANSI -- the inverse of the
 * MapRawKey the editor uses -- so the tool is right for whatever keymap the
 * system has, and Shift comes out where the character needs it.  The keys
 * that have no character use the same raw-code table as the decoder
 * (src/emacs/rawkey.c), and Control/Alt are added as qualifiers exactly as
 * the decoder expects to find them.
 *
 * Runs wherever input.device does: FS-UAE, a real Amiga, and MorphOS (as a
 * 68k program) -- which is what makes it the one tool for the emulator run
 * and for the real-hardware check of Alt-as-Meta.
 */

#include <exec/types.h>
#include <exec/io.h>
#include <exec/memory.h>
#include <devices/input.h>
#include <devices/inputevent.h>
#include <dos/dos.h>
#include <dos/rdargs.h>
#include <intuition/intuition.h>
#include <intuition/intuitionbase.h>

#include <clib/alib_protos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/keymap.h>

#include <stdio.h>
#include <string.h>

#include "emacs/keymap.h"
#include "emacs/rawkey.h"

struct Library       *KeymapBase;
struct IntuitionBase *IntuitionBase;

static struct MsgPort  *port;
static struct IOStdReq *io;
static LONG             delay_ticks = 2;

static const char template[] = "KEYS/M,TEXT/K,DELAY/K/N,DIAG/S";

enum { ARG_KEYS, ARG_TEXT, ARG_DELAY, ARG_DIAG, ARG_COUNT };

static LONG diag = 0;

static int32_t send_event(UWORD code, UWORD qualifier)
{
    struct InputEvent ie;
    LONG              err;

    memset(&ie, 0, sizeof ie);
    ie.ie_Class     = IECLASS_RAWKEY;
    ie.ie_Code      = code;
    ie.ie_Qualifier = qualifier;
    CurrentTime(&ie.ie_TimeStamp.tv_secs, &ie.ie_TimeStamp.tv_micro);

    io->io_Command = IND_WRITEEVENT;
    io->io_Flags   = 0;
    io->io_Data    = &ie;
    io->io_Length  = sizeof ie;
    err = DoIO((struct IORequest *)io);
    if (diag)
        printf("DIAG sendkey: event code=%02x qual=%04x io_err=%ld io_actual=%ld\n",
               (unsigned)code, (unsigned)qualifier, (long)err, (long)io->io_Actual);
    return err == 0;
}

/*
 * The raw codes of the qualifier keys, so a modifier can be HELD DOWN around
 * the keystroke it modifies rather than merely flagged on it.
 *
 * This is the fix the FS-UAE probe pointed to: an injected event that sets
 * IEQUALIFIER_CONTROL without a Control key being down is dropped -- `n' with
 * the control bit produced nothing, while `n' alone self-inserted.  Intuition
 * tracks the live qualifier from the qualifier KEYS, and a synthesised event
 * has to move them the way a finger would.  Sending them also makes the OS
 * apply the bit itself, so the flag on the main event is belt-and-braces.
 */
struct ck_qual_key {
    uint16_t bit;
    uint16_t code;
};

static const struct ck_qual_key ck_qual_keys[] = {
    { CK_QUAL_LSHIFT,  0x60 },
    { CK_QUAL_RSHIFT,  0x61 },
    { CK_QUAL_CONTROL, 0x63 },
    { CK_QUAL_LALT,    0x64 },
    { CK_QUAL_RALT,    0x65 }
};
#define CK_NUM_QUAL_KEYS  ((int)(sizeof ck_qual_keys / sizeof ck_qual_keys[0]))

/* One keystroke: hold the qualifier keys, press and release the key, release
 * the qualifiers, and pause a moment for the receiver.  MUI processes its
 * IDCMP queue when the application task next runs, and an editor command that
 * opens the minibuffer must have moved the focus before the next key lands. */
static int32_t press(UWORD code, UWORD qualifier)
{
    UWORD held = 0;
    int   i;

    for (i = 0; i < CK_NUM_QUAL_KEYS; i++) {
        if ((qualifier & ck_qual_keys[i].bit) != 0) {
            held |= ck_qual_keys[i].bit;
            if (!send_event(ck_qual_keys[i].code, held))
                return 0;
        }
    }

    if (!send_event(code, (UWORD)(held | qualifier)))
        return 0;
    if (!send_event((UWORD)(code | IECODE_UP_PREFIX), (UWORD)(held | qualifier)))
        return 0;

    for (i = CK_NUM_QUAL_KEYS - 1; i >= 0; i--) {
        if ((held & ck_qual_keys[i].bit) != 0) {
            held &= ~ck_qual_keys[i].bit;
            if (!send_event((UWORD)(ck_qual_keys[i].code | IECODE_UP_PREFIX), held))
                return 0;
        }
    }

    if (delay_ticks > 0)
        Delay(delay_ticks);
    return 1;
}

/* Type a character: MapANSI gives the raw code and the qualifier (Shift, or
 * a dead-key sequence) that produce it under the current keymap. */
static int32_t press_char(UBYTE ch, UWORD extra)
{
    UBYTE pairs[8];
    LONG  n, i;

    n = MapANSI((STRPTR)&ch, 1, (STRPTR)pairs, (LONG)(sizeof pairs / 2), NULL);
    if (diag)
        printf("DIAG sendkey: MapANSI('%c'=0x%02x) -> n=%ld pairs=%02x,%02x,%02x,%02x\n",
               (ch >= 0x20 && ch < 0x7f) ? ch : '?', (unsigned)ch, (long)n,
               pairs[0], pairs[1], pairs[2], pairs[3]);
    if (n <= 0) {
        printf("sendkey: no key produces character 0x%02x under this keymap\n", ch);
        return 0;
    }
    for (i = 0; i < n; i++) {
        if (!press(pairs[2 * i], (UWORD)(pairs[2 * i + 1] | extra)))
            return 0;
    }
    return 1;
}

static int32_t press_spelling(const char *spelling)
{
    ck_key   key = ck_key_from_string(spelling);
    uint16_t code, raw, qualifier;

    if (key == CK_KEY_NONE) {
        printf("sendkey: unknown key `%s'\n", spelling);
        return 0;
    }

    code      = CK_KEY_CODE(key);
    qualifier = ck_rawkey_qualifier(CK_KEY_MODS(key));
    raw       = ck_rawkey_special(code);

    if (raw != 0)
        return press(raw, qualifier);

    /* A character: Shift is the keymap's decision (M-< is Alt plus whatever
     * produces `<'), so only Control and Alt are passed along. */
    return press_char((UBYTE)code, (UWORD)(qualifier & ~(CK_QUAL_LSHIFT | CK_QUAL_RSHIFT)));
}

static void report_active_window(void)
{
    struct Window *win;
    const char    *title = "(none)";
    char           copy[80];

    /* The pointer is only stable while multitasking is off; copy the title
     * out under Forbid and print it afterwards. */
    Forbid();
    win = IntuitionBase->ActiveWindow;
    if (win != NULL && win->Title != NULL) {
        strncpy(copy, (const char *)win->Title, sizeof copy - 1);
        copy[sizeof copy - 1] = '\0';
        title = copy;
    } else if (win != NULL) {
        title = "(untitled)";
    }
    Permit();

    printf("INFO sendkey: active window is %s\n", title);
}

int main(void)
{
    struct RDArgs *rdargs;
    LONG           args[ARG_COUNT] = { 0, 0, 0, 0 };
    int            rc = RETURN_FAIL;

    KeymapBase    = OpenLibrary((STRPTR)"keymap.library", 37);
    IntuitionBase = (struct IntuitionBase *)OpenLibrary((STRPTR)"intuition.library", 37);
    if (KeymapBase == NULL || IntuitionBase == NULL) {
        printf("sendkey: cannot open keymap.library and intuition.library\n");
        goto out;
    }

    rdargs = ReadArgs((STRPTR)template, args, NULL);
    if (rdargs == NULL) {
        printf("sendkey: usage: %s\n", template);
        goto out;
    }

    if (args[ARG_DELAY] != 0)
        delay_ticks = *(LONG *)args[ARG_DELAY];
    diag = args[ARG_DIAG];

    port = CreateMsgPort();
    io   = (struct IOStdReq *)CreateIORequest(port, sizeof(struct IOStdReq));
    if (port == NULL || io == NULL ||
        OpenDevice((STRPTR)"input.device", 0, (struct IORequest *)io, 0) != 0) {
        printf("sendkey: cannot open input.device\n");
        FreeArgs(rdargs);
        goto out_io;
    }

    report_active_window();
    rc = RETURN_OK;

    if (args[ARG_KEYS] != 0) {
        const char **keys = (const char **)args[ARG_KEYS];
        while (*keys != NULL) {
            if (!press_spelling(*keys)) {
                rc = RETURN_ERROR;
                break;
            }
            keys++;
        }
    }

    if (rc == RETURN_OK && args[ARG_TEXT] != 0) {
        const char *text = (const char *)args[ARG_TEXT];
        while (*text != '\0') {
            if (!press_char((UBYTE)*text, 0)) {
                rc = RETURN_ERROR;
                break;
            }
            text++;
        }
    }

    CloseDevice((struct IORequest *)io);
    FreeArgs(rdargs);

out_io:
    if (io != NULL)
        DeleteIORequest((struct IORequest *)io);
    if (port != NULL)
        DeleteMsgPort(port);
out:
    if (IntuitionBase != NULL)
        CloseLibrary((struct Library *)IntuitionBase);
    if (KeymapBase != NULL)
        CloseLibrary(KeymapBase);
    return rc;
}
