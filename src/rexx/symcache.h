/*
 * symcache.h -- what clamiga has already said about a symbol.
 *
 * The status line asks for the arglist of the operator at point whenever
 * the cursor comes to rest somewhere new, and most of the time that operator
 * is one it has asked about before -- `let', `defun', the project's own
 * functions.  A round trip over ARexx is cheap, but it is not free on a
 * 68020 and it queues behind whatever else is on the wire, so the answer is
 * kept.  A miss is kept too (an empty value): asking again about `x' every
 * time the cursor enters a binding list would be the same waste.
 *
 * Keys are compared case-insensitively, as Lisp reads symbols, and are
 * expected to carry the package they were resolved in (`CL-USER|foo'): the
 * same unqualified name can mean different things in different packages.
 *
 * Pure C: no MUI, no OS types.
 */

#ifndef CLAMACS_SYMCACHE_H
#define CLAMACS_SYMCACHE_H

#include <stdint.h>

#define CK_SYMCACHE_SIZE 64

typedef struct {
    char *key;
    char *value;
} ck_symcache_entry;

typedef struct {
    ck_symcache_entry items[CK_SYMCACHE_SIZE];
    int32_t           next;   /* the slot the next new entry replaces */
} ck_symcache;

void ck_symcache_init(ck_symcache *cache);
void ck_symcache_clear(ck_symcache *cache);

/* Remember VALUE for KEY.  An existing key is updated in place; a new one
 * takes the oldest slot.  VALUE may be "" to record that clamiga had no
 * answer.  Returns 0, or -1 when out of memory. */
int32_t ck_symcache_put(ck_symcache *cache, const char *key, const char *value);

/* The remembered value, "" for a remembered miss, or NULL when KEY has never
 * been asked about -- the one case that needs a round trip. */
const char *ck_symcache_get(const ck_symcache *cache, const char *key);

#endif /* CLAMACS_SYMCACHE_H */
