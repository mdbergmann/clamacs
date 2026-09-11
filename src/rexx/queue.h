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
    CK_REQ_LASTRESULT,

    /* Phase 2: introspection.  Each names where its reply goes. */
    CK_REQ_ARGLIST,          /* the status line, quietly (the idle timer) */
    CK_REQ_ARGLIST_ECHO,     /* the status line AND the echo area (M-x) */
    CK_REQ_COMPLETE_BUFFER,  /* M-TAB: complete the symbol before point */
    CK_REQ_COMPLETE_MINI,    /* TAB in a symbol prompt */
    CK_REQ_DESCRIBE,         /* the description window */
    CK_REQ_APROPOS,          /* the apropos window */
    CK_REQ_SOURCE_LOCATION,  /* M-.: jump there */
    CK_REQ_MACROEXPAND,      /* the macroexpansion window */

    /* Phase 3: the REPL window.  These replies say only whether clamiga
     * took the command; what the user waits for (output, a read request,
     * the values) arrives later as commands at the editor's own port. */
    CK_REQ_REPL_ATTACH,      /* the reply is the prompt's package */
    CK_REQ_REPL_EVAL,        /* rc 10 means the REPL was busy */
    CK_REQ_REPL_INPUT,       /* the answer to a READLINE */
    CK_REQ_REPL_INTERRUPT,
    CK_REQ_REPL_DETACH,

    /* Phase 4: the debugger window (asked while clamiga's REPL thread is
     * parked at a DEBUGGER level) and the inspector window. */
    CK_REQ_DBG_BACKTRACE,    /* the frames list */
    CK_REQ_DBG_FRAME,        /* the locals list of one frame */
    CK_REQ_DBG_FRAME_EVAL,   /* rc only; the values arrive as OUTPUT */
    CK_REQ_DBG_RESTART,      /* rc only: RESTART <n>, ABORT, CONTINUE */
    CK_REQ_INSPECT           /* INSPECT, PART and POP: the parts window */
} ck_req_kind;

typedef struct ck_request {
    char              *command;  /* the exact ARexx command string */
    char              *context;  /* for an automatic LASTRESULT: the command
                                  * string whose text it is fetching, so a
                                  * continuation that reads its argument
                                  * back out of the command (which symbol
                                  * was asked about) still can */
    uint16_t           kind;     /* ck_req_kind */
    uint16_t           origin;   /* for an automatic LASTRESULT: the kind of
                                  * the command whose text it is fetching, so
                                  * the continuation still knows what to do
                                  * with the reply */
    int32_t            origin_rc; /* and that command's own return code: a
                                  * LASTRESULT always comes back 0, but a
                                  * phase-2 continuation needs to tell a miss
                                  * (rc 10) from an answer */
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

/* Attach a copy of TEXT as REQ's context (see the field).  Returns 0, or -1
 * when out of memory, in which case the request has no context. */
int32_t ck_request_set_context(ck_request *req, const char *text);

/* The command string a reply answers: the request's own, or -- for an
 * automatic LASTRESULT -- the one it stands in for. */
const char *ck_request_subject(const ck_request *req);

ck_request *ck_queue_inflight(const ck_queue *q);
int32_t     ck_queue_depth(const ck_queue *q);

/* Drop every queued request belonging to COOKIE (a window that just closed).
 * The in-flight one is left alone: its reply is already on its way, and
 * cancelling it would break the one-in-flight accounting.  Returns how many
 * were dropped. */
int32_t ck_queue_drop_cookie(ck_queue *q, uint32_t cookie);

#endif /* CLAMACS_QUEUE_H */
