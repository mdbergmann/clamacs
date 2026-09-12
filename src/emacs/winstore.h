/*
 * winstore.h -- where the windows go: the snapshot of window positions.
 *
 * `M-x clamacs-snapshot-windows' (Windows > Snapshot Windows) records the
 * position and size of every open window in a small text file,
 * ENVARC:Clamacs/windows.cfg (and ENV:), and the editor opens its windows
 * there from then on.  This is the editor's own store, not MUI's: MUI 3.8
 * can snapshot only one window at a time, from that window's MUI menu, and
 * a window with a MUI window ID would take MUI's snapshot over anything
 * the editor asked for, so the windows carry no MUI ID and this file is
 * the one place a position lives.
 *
 * A window is named by its ROLE.  The fixed windows are `errors',
 * `inspector' and `debugger'; the scratch windows go by their name without
 * the stars and the `clamacs-' prefix (`repl', `description', `apropos',
 * `macroexpansion'); a file window is `doc1', `doc2', ... -- the lowest
 * slot no open file window holds, so the first file opened in a session
 * comes up where the first file window was when the snapshot was taken,
 * the second where the second was, and so on.
 *
 * The file is one entry per line, `role left top width height', with `;'
 * and `#' lines as comments.  A line that does not parse is skipped, not
 * fatal: a hand-edited file loses one entry, never the editor's start.
 *
 * Pure C: no MUI, no OS types.  src/snapshot.c reads the MUI windows,
 * does the file I/O and hands the four numbers back as window tags.
 */

#ifndef CLAMACS_WINSTORE_H
#define CLAMACS_WINSTORE_H

#include <stdint.h>

#define CK_WINSTORE_MAX      24   /* entries */
#define CK_WINSTORE_NAME_MAX 24   /* a role, NUL included */

/* Room enough for the header line and CK_WINSTORE_MAX full entries. */
#define CK_WINSTORE_TEXT_MAX 2048

typedef struct {
    char    name[CK_WINSTORE_NAME_MAX];
    int32_t left;
    int32_t top;
    int32_t width;
    int32_t height;
} ck_winentry;

typedef struct {
    ck_winentry items[CK_WINSTORE_MAX];
    int32_t     count;
} ck_winstore;

void ck_winstore_init(ck_winstore *store);

/* The entry for ROLE, or NULL. */
const ck_winentry *ck_winstore_find(const ck_winstore *store, const char *role);

/* Record ROLE's geometry, replacing an entry of that role or appending.
 * Returns 1, or 0 when the store is full or ROLE is empty/too long. */
int32_t ck_winstore_set(ck_winstore *store, const char *role, int32_t left,
                        int32_t top, int32_t width, int32_t height);

/* Replace the store's contents with what TEXT holds (see the format above).
 * Returns the number of entries read; a NULL or empty TEXT gives 0. */
int32_t ck_winstore_parse(ck_winstore *store, const char *text);

/* Write the store as text into OUT (SIZE bytes), header line included.
 * Returns the length written, or -1 when it does not fit (OUT is then
 * NUL-terminated but incomplete). */
int32_t ck_winstore_format(const ck_winstore *store, char *out, int32_t size);

/* The role of file window number SLOT (1-based): `doc1', `doc2', ...
 * Returns the length, or 0 when SLOT is not positive or OUT is too small. */
int32_t ck_winstore_doc_role(int32_t slot, char *out, int32_t size);

/* The slot a `docN' role names, or 0 for any other role. */
int32_t ck_winstore_doc_slot(const char *role);

/* The role of the scratch window called NAME: the name without its stars
 * and a leading `clamacs-', so `*clamacs-repl*' is `repl'.  Blanks become
 * `-' (a role is one word in the file).  An empty result means the name
 * had nothing left; the caller then gives the window no stored place. */
void ck_winstore_scratch_role(const char *name, char *out, int32_t size);

#endif /* CLAMACS_WINSTORE_H */
