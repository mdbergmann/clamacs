/*
 * snapshot.c -- window positions: the file, the tags, the command.
 *
 * The store itself (emacs/winstore.c) is data and host-tested; this is the
 * OS half around it.  Three jobs:
 *
 *   - at startup, read ENV:Clamacs/windows.cfg (or the ENVARC: copy) into
 *     app->layout;
 *   - whenever a window is created, hand back its stored geometry as
 *     window-creation tags (ck_snapshot_tags) -- the one place a window's
 *     position comes from;
 *   - `clamacs-snapshot-windows': read every open window's geometry, put
 *     it in the store and write the file to ENV: and ENVARC:.
 *
 * Why not MUI's snapshot (MUIA_Window_ID)?  MUI 3.8 snapshots one window
 * at a time from that window's own MUI menu, and a window that has an ID
 * takes MUI's snapshot over any LeftEdge/TopEdge it was created with -- so
 * the two mechanisms would fight, and the user could not tell which one
 * put a window where.  The editor's windows therefore carry no MUI ID:
 * this file is the only place a position lives, on MUI 3.8 and MUI 4
 * alike, and it is plain text the user can read and edit.
 */

#include "clamacs.h"

#include <stdio.h>
#include <string.h>

#define CK_SNAPSHOT_DIR_ENV     "ENV:Clamacs"
#define CK_SNAPSHOT_FILE_ENV    "ENV:Clamacs/windows.cfg"
#define CK_SNAPSHOT_DIR_ENVARC  "ENVARC:Clamacs"
#define CK_SNAPSHOT_FILE_ENVARC "ENVARC:Clamacs/windows.cfg"

/* One application per process: the file text lives here rather than on the
 * 32 KB process stack. */
static char ck_snapshot_text[CK_WINSTORE_TEXT_MAX];

/* ------------------------------------------------------------------ *
 * The file
 * ------------------------------------------------------------------ */

static int32_t ck_snapshot_read_file(const char *path, char *buf, int32_t size)
{
    BPTR file = Open((STRPTR)path, MODE_OLDFILE);
    LONG n;

    if (file == (BPTR)0)
        return 0;
    n = Read(file, buf, size - 1);
    Close(file);
    if (n < 0)
        return 0;
    buf[n] = '\0';
    return 1;
}

static int32_t ck_snapshot_write_file(const char *dir, const char *path,
                                      const char *text, int32_t len)
{
    BPTR lock, file;
    LONG written;

    /* The drawer may be there already; a failed CreateDir then costs
     * nothing, and a missing one would make the Open below fail. */
    lock = CreateDir((STRPTR)dir);
    if (lock != (BPTR)0)
        UnLock(lock);

    file = Open((STRPTR)path, MODE_NEWFILE);
    if (file == (BPTR)0)
        return 0;
    written = Write(file, (APTR)text, len);
    Close(file);
    return written == len;
}

void ck_snapshot_load(ck_app *app)
{
    ck_winstore_init(&app->layout);
    if (ck_snapshot_read_file(CK_SNAPSHOT_FILE_ENV, ck_snapshot_text,
                              (int32_t)sizeof ck_snapshot_text) ||
        ck_snapshot_read_file(CK_SNAPSHOT_FILE_ENVARC, ck_snapshot_text,
                              (int32_t)sizeof ck_snapshot_text)) {
        ck_winstore_parse(&app->layout, ck_snapshot_text);
    }
}

/* Both copies: ENV: is what this boot reads, ENVARC: is what the next one
 * copies to ENV:.  Reports each path's own result in *ENV_OK/*ENVARC_OK so
 * the caller can name the one that actually failed. */
static void ck_snapshot_save(ck_app *app, int32_t *env_ok, int32_t *envarc_ok)
{
    int32_t len = ck_winstore_format(&app->layout, ck_snapshot_text,
                                     (int32_t)sizeof ck_snapshot_text);

    if (len < 0) {
        *env_ok = 0;
        *envarc_ok = 0;
        return;
    }
    *env_ok    = ck_snapshot_write_file(CK_SNAPSHOT_DIR_ENV, CK_SNAPSHOT_FILE_ENV,
                                        ck_snapshot_text, len);
    *envarc_ok = ck_snapshot_write_file(CK_SNAPSHOT_DIR_ENVARC, CK_SNAPSHOT_FILE_ENVARC,
                                        ck_snapshot_text, len);
}

/* ------------------------------------------------------------------ *
 * The tags
 * ------------------------------------------------------------------ */

void ck_snapshot_tags(ck_app *app, const char *role, struct TagItem *tags,
                      IPTR def_width, IPTR def_height)
{
    const ck_winentry *e = ck_winstore_find(&app->layout, role);

    /* A size that is not positive would be one of MUI's special values
     * (MUIV_Window_Width_MinMax and friends are zero and below): a
     * hand-edited entry like that gets the default size instead. */
    if (e != NULL && e->width > 0 && e->height > 0) {
        tags[0].ti_Tag  = MUIA_Window_LeftEdge; tags[0].ti_Data = (IPTR)e->left;
        tags[1].ti_Tag  = MUIA_Window_TopEdge;  tags[1].ti_Data = (IPTR)e->top;
        tags[2].ti_Tag  = MUIA_Window_Width;    tags[2].ti_Data = (IPTR)e->width;
        tags[3].ti_Tag  = MUIA_Window_Height;   tags[3].ti_Data = (IPTR)e->height;
    } else {
        tags[0].ti_Tag  = (def_width  != 0) ? MUIA_Window_Width  : TAG_IGNORE;
        tags[0].ti_Data = def_width;
        tags[1].ti_Tag  = (def_height != 0) ? MUIA_Window_Height : TAG_IGNORE;
        tags[1].ti_Data = def_height;
        tags[2].ti_Tag  = TAG_IGNORE; tags[2].ti_Data = 0;
        tags[3].ti_Tag  = TAG_IGNORE; tags[3].ti_Data = 0;
    }
    tags[4].ti_Tag  = TAG_DONE;
    tags[4].ti_Data = 0;
}

/* ------------------------------------------------------------------ *
 * Reading the windows
 * ------------------------------------------------------------------ */

static LONG ck_snapshot_get(Object *win, ULONG attr)
{
    IPTR value = 0;
    GetAttr(attr, win, &value);
    return (LONG)value;
}

/* Put WIN's geometry in the store under ROLE, if it is open.  Returns 1
 * when it was. */
static int32_t ck_snapshot_record(ck_app *app, Object *win, const char *role)
{
    if (win == NULL || role == NULL || role[0] == '\0')
        return 0;
    if (!ck_snapshot_get(win, MUIA_Window_Open))
        return 0;
    return ck_winstore_set(&app->layout, role,
                           ck_snapshot_get(win, MUIA_Window_LeftEdge),
                           ck_snapshot_get(win, MUIA_Window_TopEdge),
                           ck_snapshot_get(win, MUIA_Window_Width),
                           ck_snapshot_get(win, MUIA_Window_Height));
}

void ck_snapshot_take(ck_doc *doc)
{
    ck_app  *app = doc->app;
    ck_doc  *d;
    int32_t  count = 0;

    for (d = app->docs; d != NULL; d = d->next) {
        if (!d->closing)
            count += ck_snapshot_record(app, d->win, d->role);
    }
    count += ck_snapshot_record(app, app->errorwin,   "errors");
    count += ck_snapshot_record(app, app->inspectwin, "inspector");
    count += ck_snapshot_record(app, app->debugwin,   "debugger");

    {
        int32_t env_ok, envarc_ok;

        ck_snapshot_save(app, &env_ok, &envarc_ok);
        if (!env_ok || !envarc_ok) {
            if (!env_ok && !envarc_ok)
                ck_message(doc, "Cannot write %s or %s",
                          CK_SNAPSHOT_FILE_ENV, CK_SNAPSHOT_FILE_ENVARC);
            else
                ck_message(doc, "Cannot write %s",
                          !env_ok ? CK_SNAPSHOT_FILE_ENV : CK_SNAPSHOT_FILE_ENVARC);
            ck_beep(doc);
            return;
        }
    }
    ck_message(doc, "Saved the positions of %ld window(s) to %s",
               (long)count, CK_SNAPSHOT_FILE_ENVARC);
}

void ck_snapshot_describe(ck_doc *doc, char *out, int32_t size)
{
    snprintf(out, (size_t)size, "%s %ld %ld %ld %ld",
             doc->role[0] != '\0' ? doc->role : "-",
             (long)ck_snapshot_get(doc->win, MUIA_Window_LeftEdge),
             (long)ck_snapshot_get(doc->win, MUIA_Window_TopEdge),
             (long)ck_snapshot_get(doc->win, MUIA_Window_Width),
             (long)ck_snapshot_get(doc->win, MUIA_Window_Height));
}
