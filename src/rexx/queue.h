/*
 * queue.h -- the ARexx request queue.
 *
 * clamiga's port serves ONE message at a time, and the editor must never
 * block waiting for a reply -- a long COMPILE-FILE would otherwise freeze
 * redisplay, and the phase-3 REPL depends on the editor answering clamiga's
 * calls while its own request is outstanding.  So: at most one request in
 * flight, everything else waits here in order, and each request carries the
 * continuation that will consume its reply.
 *
 * Pure C: no MUI, no OS types.  The RexxMsg lives in the MUI layer; what is
 * modelled here is the ordering discipline, which is the part that has rules
 * worth testing.
 */

#ifndef CLAMACS_QUEUE_H
#define CLAMACS_QUEUE_H

#include <stdint.h>

#include "rc.h"

/* What the reply is for.  The MUI layer switches on this to decide where the
 * text goes: the error list, the minibuffer, the status line. */
typedef enum {
    CK_REQ_NONE = 0,
    CK_REQ_PING,
    CK_REQ_VERSION,
    CK_REQ_IN_PACKAGE,
    CK_REQ_LOAD,
    CK_REQ_COMPILE_FILE,
    CK_REQ_EVAL,
    CK_REQ_LASTRESULT
} ck_req_kind;

typedef struct ck_request {
    char              *command;  /* the exact ARexx command string */
    uint16_t           kind;     /* ck_req_kind */
    uint16_t           flags;
    uint32_t           cookie;   /* the document (or window) the reply belongs
                                  * to, so a reply that arrives after its
                                  * window closed can be dropped */
    int32_t            serial;
    int32_t            rc;       /* filled in when the reply arrives */
    struct ck_request *next;
} ck_request;

/* Set on a request the editor issued by itself to recover the text of a
 * failing command, so the continuation knows the reply is not a fresh
 * result. */
#define CK_REQF_AUTO_LASTRESULT 0x0001

typedef struct {
    ck_request *head;
    ck_request *tail;
    ck_request *inflight;
    int32_t     count;        /* queued, not counting the one in flight */
    int32_t     next_serial;
} ck_queue;

void ck_queue_init(ck_queue *q);
void ck_queue_clear(ck_queue *q);

/* Enqueue.  Returns the request's serial, or -1 when out of memory. */
int32_t ck_queue_push(ck_queue *q, const char *command, uint16_t kind,
                      uint32_t cookie);

/* Enqueue at the FRONT.  This is how the automatic LASTRESULT after a
 * non-zero rc is issued: it has to be the very next thing on the wire, or a
 * queued command would run first and *LAST-RESULT* would no longer hold the
 * text we came for. */
int32_t ck_queue_push_front(ck_queue *q, const char *command, uint16_t kind,
                            uint32_t cookie, uint16_t flags);

/* The next request to put on the wire, or NULL when one is already in flight
 * or nothing is waiting.  The returned request becomes the in-flight one. */
ck_request *ck_queue_begin(ck_queue *q);

/* The reply for the in-flight request arrived with return code RC.  Returns
 * that request, which the caller owns and must release. */
ck_request *ck_queue_complete(ck_queue *q, int32_t rc);

void ck_queue_release(ck_request *req);

ck_request *ck_queue_inflight(const ck_queue *q);
int32_t     ck_queue_depth(const ck_queue *q);

/* Drop every queued request belonging to COOKIE (a window that just closed).
 * The in-flight one is left alone: its reply is already on its way, and
 * cancelling it would break the one-in-flight accounting.  Returns how many
 * were dropped. */
int32_t ck_queue_drop_cookie(ck_queue *q, uint32_t cookie);

#endif /* CLAMACS_QUEUE_H */
