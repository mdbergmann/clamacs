/*
 * main.c -- libraries, the application object, and the input loop.
 *
 * The loop is the reason the ARexx client can be asynchronous: the reply
 * port's signal joins the mask MUI's own Wait() uses, so a reply from
 * clamiga arrives as one more event among keystrokes and window messages.
 * Nothing here ever waits for a reply on its own.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>
#include <stdarg.h>

struct Library       *MUIMasterBase;
struct IntuitionBase *IntuitionBase;
struct GfxBase       *GfxBase;
struct Library       *KeymapBase;
struct Library       *AslBase;
/* The definition must match the extern in proto/rexxsyslib.h, and the two
 * SDKs disagree: the m68k NDK declares `struct RxsLib *`, the MorphOS SDK
 * `struct Library *` (cl-amiga's platform_amiga_rexx.c does the same). */
#ifdef __MORPHOS__
typedef struct Library ck_rexxsysbase_t;
#else
typedef struct RxsLib ck_rexxsysbase_t;
#endif
ck_rexxsysbase_t     *RexxSysBase;

/* clamacs is a small program with one application object; a file-scope
 * pointer is what lets the ARexx command hooks -- which MUI calls with no
 * context of their own -- find it. */
static ck_app *ck_the_app;

long __stack = 32768;

ck_app *ck_app_current(void)
{
    return ck_the_app;
}

void ck_message(ck_doc *doc, const char *fmt, ...)
{
    va_list args;

    if (doc == NULL)
        return;

    va_start(args, fmt);
    vsnprintf(doc->message, sizeof doc->message, fmt, args);
    va_end(args);

    ck_doc_echo(doc);
}

void ck_beep(ck_doc *doc)
{
    if (doc != NULL && doc->win != NULL)
        DisplayBeep(NULL);
}

/* ------------------------------------------------------------------ */

/*
 * MUI 3.8 -- the version installed on an ordinary AmigaOS 3 system, and the
 * one the test image has -- is muimaster.library 19.  The header's
 * MUIMASTER_VMIN and MUIMASTER_VLATEST are both 20, so opening with either
 * of those refuses to run on exactly the target this editor is for.  19 is
 * the real floor: TextEditor.mcc 15.x needs MUI 3.8 anyway.
 */
#define CK_MUIMASTER_VMIN 19

static int32_t ck_open_libraries(void)
{
    IntuitionBase = (struct IntuitionBase *)OpenLibrary((STRPTR)"intuition.library", 39);
    GfxBase       = (struct GfxBase *)OpenLibrary((STRPTR)"graphics.library", 39);
    KeymapBase    = OpenLibrary((STRPTR)"keymap.library", 37);
    AslBase       = OpenLibrary((STRPTR)"asl.library", 37);
    RexxSysBase   = (ck_rexxsysbase_t *)OpenLibrary((STRPTR)"rexxsyslib.library", 36);
    MUIMasterBase = OpenLibrary((STRPTR)MUIMASTER_NAME, CK_MUIMASTER_VMIN);

    return IntuitionBase != NULL && GfxBase != NULL && KeymapBase != NULL &&
           AslBase != NULL && RexxSysBase != NULL && MUIMasterBase != NULL;
}

static void ck_close_libraries(void)
{
    if (MUIMasterBase != NULL) CloseLibrary(MUIMasterBase);
    if (RexxSysBase != NULL)   CloseLibrary((struct Library *)RexxSysBase);
    if (AslBase != NULL)       CloseLibrary(AslBase);
    if (KeymapBase != NULL)    CloseLibrary(KeymapBase);
    if (GfxBase != NULL)       CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase != NULL) CloseLibrary((struct Library *)IntuitionBase);

    MUIMasterBase = NULL;
    RexxSysBase   = NULL;
    AslBase       = NULL;
    KeymapBase    = NULL;
    GfxBase       = NULL;
    IntuitionBase = NULL;
}

/*
 * Startup diagnostics.
 *
 * A process started with `run' has no output stream at all -- Output() is 0
 * -- so a message written there goes nowhere, and a requester put up instead
 * is a hang rather than a diagnostic when nobody is watching (which is
 * exactly what an unattended FS-UAE run is).  Everything therefore also goes
 * to PROGDIR:clamacs-startup.log, opened and closed per line so the file is
 * complete even if the next step never returns.
 */
static void ck_log(const char *message)
{
    BPTR out = Output();
    BPTR file;

    if (out != (BPTR)0) {
        FPuts(out, (STRPTR)"clamacs: ");
        FPuts(out, (STRPTR)message);
        FPuts(out, (STRPTR)"\n");
        Flush(out);
    }

    file = Open((STRPTR)"PROGDIR:clamacs-startup.log", MODE_READWRITE);
    if (file != (BPTR)0) {
        Seek(file, 0, OFFSET_END);
        FPuts(file, (STRPTR)message);
        FPuts(file, (STRPTR)"\n");
        Close(file);
    }
}

static void ck_note(const char *message)
{
    ck_log(message);
}

static void ck_fail(const char *message)
{
    ck_log(message);

    /* Only bother a user who is actually there. */
    if (Output() == (BPTR)0 && IntuitionBase != NULL &&
        FindTask(NULL) != NULL && ((struct Process *)FindTask(NULL))->pr_CLI == (BPTR)0) {
        struct EasyStruct es;
        es.es_StructSize   = sizeof es;
        es.es_Flags        = 0;
        es.es_Title        = (STRPTR)"clamacs";
        es.es_TextFormat   = (STRPTR)"%s";
        es.es_GadgetFormat = (STRPTR)"OK";
        EasyRequestArgs(NULL, &es, NULL, (APTR)&message);
    }
}

/* ------------------------------------------------------------------ */

static const char *ck_used_classes[] = { "TextEditor.mcc", NULL };

static int32_t ck_app_create(ck_app *app)
{
    char note[128];

    memset(app, 0, sizeof(*app));
    app->next_id = 1;

    ck_kill_init(&app->kill);
    ck_hist_init(&app->hist_file);
    ck_hist_init(&app->hist_command);
    ck_hist_init(&app->hist_search);
    ck_hist_init(&app->hist_eval);
    ck_hist_init(&app->hist_symbol);
    ck_hist_init(&app->hist_repl);

    /* Phase 2 introspection state. */
    ck_symcache_init(&app->arglists);
    ck_locstack_init(&app->locations);

    app->global   = ck_bindings_global();
    app->lisp     = ck_bindings_lisp();
    app->repl_map = ck_bindings_repl();
    if (app->global == NULL || app->lisp == NULL || app->repl_map == NULL)
        return 0;

    ck_note("keymaps built");

    switch (ck_classes_create(app)) {
    case CK_CLASSES_OK:
        snprintf(note, sizeof note, "custom classes created (TextEditor.mcc %ld.%ld)",
                 (long)app->te_version, (long)app->te_revision);
        ck_note(note);
        break;
    case CK_CLASSES_TOO_OLD:
        snprintf(note, sizeof note,
                 "TextEditor.mcc %ld.%ld is too old -- clamacs needs 15.29 or newer",
                 (long)app->te_version, (long)app->te_revision);
        ck_fail(note);
        return 0;
    default:
        ck_fail("MUI_CreateCustomClass failed -- is TextEditor.mcc in MUI:Libs/mui/?");
        return 0;
    }

    if (!ck_rexx_open(app)) {
        ck_fail("cannot create the ARexx reply port");
        return 0;
    }
    ck_note("reply port created");

    app->app = ApplicationObject,
        MUIA_Application_Title,       (IPTR)"clamacs",
        MUIA_Application_Version,     (IPTR)"$VER: clamacs 0.1 (" __DATE__ ")",
        MUIA_Application_Copyright,   (IPTR)"(c) 2026 Manfred Bergmann",
        MUIA_Application_Author,      (IPTR)"Manfred Bergmann",
        MUIA_Application_Description, (IPTR)"Common Lisp IDE for clamiga",
        MUIA_Application_Base,        (IPTR)"CLAMACS",
        MUIA_Application_UsedClasses, (IPTR)ck_used_classes,
        MUIA_Application_UseRexx,     TRUE,
        MUIA_Application_Commands,    (IPTR)ck_rexx_commands,
        /* What clamiga's REPL thread sends (phase 3), raw. */
        MUIA_Application_RexxHook,    (IPTR)&ck_rexx_repl_hook,
    End;

    if (app->app == NULL) {
        ck_fail("the MUI application object could not be created");
        return 0;
    }
    ck_note("application object created");

    ck_errorwin_create(app);
    ck_debugwin_create(app);
    ck_inspectwin_create(app);
    return 1;
}

static void ck_app_destroy(ck_app *app)
{
    while (app->docs != NULL) {
        ck_doc *doc = app->docs;
        app->docs = doc->next;
        set(doc->win, MUIA_Window_Open, FALSE);
        DoMethod(app->app, OM_REMMEMBER, (IPTR)doc->win);
        MUI_DisposeObject(doc->win);
        FreeVec(doc);
    }

    if (app->app != NULL) {
        MUI_DisposeObject(app->app);
        app->app = NULL;
    }

    ck_rexx_close(app);
    ck_classes_free(app);

    ck_keymap_free(app->global);
    ck_keymap_free(app->lisp);
    ck_keymap_free(app->repl_map);
    ck_kill_clear(&app->kill);
    ck_hist_clear(&app->hist_file);
    ck_hist_clear(&app->hist_command);
    ck_hist_clear(&app->hist_search);
    ck_hist_clear(&app->hist_eval);
    ck_hist_clear(&app->hist_symbol);
    ck_hist_clear(&app->hist_repl);
    ck_symcache_clear(&app->arglists);
}

static void ck_app_run(ck_app *app)
{
    ULONG sigs = 0;
    ULONG rexx = ck_rexx_signal(app);

    while ((LONG)DoMethod(app->app, MUIM_Application_NewInput, (IPTR)&sigs) !=
           MUIV_Application_ReturnID_Quit) {
        if (sigs != 0) {
            sigs = Wait(sigs | SIGBREAKF_CTRL_C | rexx);
            if ((sigs & SIGBREAKF_CTRL_C) != 0)
                break;
        }
        /* A reply from clamiga is just another event in the loop; the client
         * never blocks on one. */
        if ((sigs & rexx) != 0)
            ck_rexx_handle_replies(app);

        /* Windows retired during this pass are disposed of here, at top
         * level, and never from inside the hook that closed them. */
        ck_app_reap(app);

        if (app->quitting)
            break;
    }
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    static ck_app app;
    int32_t       i, opened = 0;

    if (!ck_open_libraries()) {
        ck_fail("clamacs needs intuition, graphics, keymap, asl, rexxsyslib\n"
                "and muimaster.library (MUI 3.8 or newer).");
        ck_close_libraries();
        return RETURN_FAIL;
    }

    ck_the_app = &app;
    ck_note("libraries opened");

    if (!ck_app_create(&app)) {
        ck_fail("Cannot create the application.\n"
                "TextEditor.mcc must be installed in MUI:Libs/mui/.");
        ck_app_destroy(&app);
        ck_close_libraries();
        ck_the_app = NULL;
        return RETURN_FAIL;
    }

    for (i = 1; i < argc; i++) {
        if (argv[i] != NULL && argv[i][0] != '\0') {
            if (ck_doc_new(&app, argv[i]) != NULL)
                opened++;
        }
    }
    ck_note("documents opened");
    if (opened == 0 && ck_doc_new(&app, NULL) == NULL) {
        ck_fail("Cannot open a document window.");
        ck_app_destroy(&app);
        ck_close_libraries();
        ck_the_app = NULL;
        return RETURN_FAIL;
    }

    ck_note("running; ARexx port CLAMACS");

    ck_app_run(&app);

    ck_app_destroy(&app);
    ck_close_libraries();
    ck_the_app = NULL;
    return RETURN_OK;
}
