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
struct RxsLib        *RexxSysBase;

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

    set(doc->prompt, MUIA_Text_Contents, (IPTR)doc->message);
}

void ck_beep(ck_doc *doc)
{
    if (doc != NULL && doc->win != NULL)
        DisplayBeep(NULL);
}

/* ------------------------------------------------------------------ */

static int32_t ck_open_libraries(void)
{
    IntuitionBase = (struct IntuitionBase *)OpenLibrary((STRPTR)"intuition.library", 39);
    GfxBase       = (struct GfxBase *)OpenLibrary((STRPTR)"graphics.library", 39);
    KeymapBase    = OpenLibrary((STRPTR)"keymap.library", 37);
    AslBase       = OpenLibrary((STRPTR)"asl.library", 37);
    RexxSysBase   = (struct RxsLib *)OpenLibrary((STRPTR)"rexxsyslib.library", 36);
    MUIMasterBase = OpenLibrary((STRPTR)MUIMASTER_NAME, MUIMASTER_VLATEST);

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

static void ck_fail(const char *message)
{
    if (IntuitionBase != NULL) {
        struct EasyStruct es;
        es.es_StructSize   = sizeof es;
        es.es_Flags        = 0;
        es.es_Title        = (STRPTR)"clamacs";
        es.es_TextFormat   = (STRPTR)"%s";
        es.es_GadgetFormat = (STRPTR)"OK";
        EasyRequestArgs(NULL, &es, NULL, (APTR)&message);
    } else {
        printf("clamacs: %s\n", message);
    }
}

/* ------------------------------------------------------------------ */

static const char *ck_used_classes[] = { "TextEditor.mcc", NULL };

static int32_t ck_app_create(ck_app *app)
{
    memset(app, 0, sizeof(*app));
    app->next_id = 1;

    ck_kill_init(&app->kill);
    ck_hist_init(&app->hist_file);
    ck_hist_init(&app->hist_command);
    ck_hist_init(&app->hist_search);
    ck_hist_init(&app->hist_eval);

    app->global = ck_bindings_global();
    app->lisp   = ck_bindings_lisp();
    if (app->global == NULL || app->lisp == NULL)
        return 0;

    if (!ck_classes_create(app))
        return 0;

    if (!ck_rexx_open(app))
        return 0;

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
    End;

    if (app->app == NULL)
        return 0;

    ck_errorwin_create(app);
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
    ck_kill_clear(&app->kill);
    ck_hist_clear(&app->hist_file);
    ck_hist_clear(&app->hist_command);
    ck_hist_clear(&app->hist_search);
    ck_hist_clear(&app->hist_eval);
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
    if (opened == 0 && ck_doc_new(&app, NULL) == NULL) {
        ck_fail("Cannot open a document window.");
        ck_app_destroy(&app);
        ck_close_libraries();
        ck_the_app = NULL;
        return RETURN_FAIL;
    }

    ck_app_run(&app);

    ck_app_destroy(&app);
    ck_close_libraries();
    ck_the_app = NULL;
    return RETURN_OK;
}
