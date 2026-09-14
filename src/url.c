/*
 * url.c -- a URL into the user's browser.
 *
 * `clamacs-hyperspec' (Help > Common Lisp HyperSpec) is the one caller so
 * far.  The editor has no browser of its own and wants none: the URL goes
 * to openurl.library, which both targets have -- MorphOS ships it, and on
 * AmigaOS 3 it is the OpenURL package that every browser (IBrowse, AWeb,
 * NetSurf) installs or asks for.  The library knows which browser is
 * configured, talks to a running one over ARexx and starts one otherwise,
 * so the editor neither guesses a browser nor holds an ARexx conversation
 * with it.
 *
 * The library is opened per call and closed again.  Opening a URL is a
 * rare act, and a base held for the whole session would keep OpenURL and
 * its prefs resident on a machine where memory is the constraint
 * (docs/memory.md).
 *
 * Neither toolchain ships the OpenURL headers (the m68k NDK predates the
 * library, and vendor/texteditor carries only MUI's), so the one entry the
 * editor needs is declared here.  URL_OpenA is the library's first
 * function -- `##bias 30', url in a0, the tag list in a1 -- on every
 * platform OpenURL exists for; MorphOS calls it through its SDK's
 * proto/openurl.h, since a library call there is not a jsr.
 *
 * Without the library there is no browser to reach.  The URL is then put
 * in a requester, where the user can at least read it off -- a beep and
 * an echo-area message would hide the one thing they came for.
 */

#include "clamacs.h"

#include <stdio.h>

#ifdef __MORPHOS__
#include <proto/openurl.h>
#else
#include <inline/macros.h>
/* URL_OpenA(url, tags): TRUE when a browser took the URL. */
#define URL_OpenA(url, tags) \
    LP2(30, ULONG, URL_OpenA, STRPTR, (url), a0, struct TagItem *, (tags), a1, \
        , OpenURLBase)
#endif

struct Library *OpenURLBase = NULL;

int32_t ck_url_open(ck_doc *doc, const char *url)
{
    ck_app *app = doc->app;
    ULONG   ok  = 0;

    OpenURLBase = OpenLibrary((STRPTR)"openurl.library", 0);
    if (OpenURLBase != NULL) {
        ok = URL_OpenA((STRPTR)url, NULL);
        CloseLibrary(OpenURLBase);
        OpenURLBase = NULL;
    } else {
        MUI_Request(app->app, doc->win, 0, "Clamacs", "_OK",
                    "openurl.library is not installed, so no browser\n"
                    "can be asked to open\n"
                    "\n"
                    "%s\n"
                    "\n"
                    "Install the OpenURL package, or type the address\n"
                    "into your browser.", url);
        ck_message(doc, "openurl.library not found");
        return 0;
    }

    if (ok) {
        ck_message(doc, "Opened %s", url);
        return 1;
    }
    ck_message(doc, "No browser took %s (check the OpenURL prefs)", url);
    ck_beep(doc);
    return 0;
}
