/*
 * queue.c -- see queue.h.
 */

#include "queue.h"

#include <stdlib.h>
#include <string.h>

int32_t ck_rc_needs_lastresult(int32_t rc)
{
    return rc != CK_RC_OK;
}

void ck_queue_init(ck_queue *q)
{
    memset(q, 0, sizeof(*q));
    q->next_serial = 1;
}

void ck_queue_clear(ck_queue *q)
{
    ck_request *r = q->head;

    while (r != NULL) {
        ck_request *next = r->next;
        ck_queue_release(r);
        r = next;
    }
    ck_queue_release(q->inflight);
    memset(q, 0, sizeof(*q));
    q->next_serial = 1;
}

static ck_request *ck_request_new(ck_queue *q, const char *command,
                                  uint16_t kind, uint32_t cookie,
                                  uint16_t flags)
{
    ck_request *r;
    size_t      n;

    if (command == NULL)
        return NULL;
    r = (ck_request *)malloc(sizeof(ck_request));
    if (r == NULL)
        return NULL;

    n = strlen(command) + 1;
    r->command = (char *)malloc(n);
    if (r->command == NULL) {
        free(r);
        return NULL;
    }
    memcpy(r->command, command, n);

    r->kind   = kind;
    r->flags  = flags;
    r->cookie = cookie;
    r->serial = q->next_serial++;
    r->rc     = 0;
    r->next   = NULL;
    return r;
}

int32_t ck_queue_push(ck_queue *q, const char *command, uint16_t kind,
                      uint32_t cookie)
{
    ck_request *r = ck_request_new(q, command, kind, cookie, 0);

    if (r == NULL)
        return -1;

    if (q->tail == NULL)
        q->head = r;
    else
        q->tail->next = r;
    q->tail = r;
    q->count++;
    return r->serial;
}

int32_t ck_queue_push_front(ck_queue *q, const char *command, uint16_t kind,
                            uint32_t cookie, uint16_t flags)
{
    ck_request *r = ck_request_new(q, command, kind, cookie, flags);

    if (r == NULL)
        return -1;

    r->next = q->head;
    q->head = r;
    if (q->tail == NULL)
        q->tail = r;
    q->count++;
    return r->serial;
}

ck_request *ck_queue_begin(ck_queue *q)
{
    ck_request *r;

    if (q->inflight != NULL)
        return NULL;
    r = q->head;
    if (r == NULL)
        return NULL;

    q->head = r->next;
    if (q->head == NULL)
        q->tail = NULL;
    q->count--;
    r->next     = NULL;
    q->inflight = r;
    return r;
}

ck_request *ck_queue_complete(ck_queue *q, int32_t rc)
{
    ck_request *r = q->inflight;

    if (r == NULL)
        return NULL;
    r->rc       = rc;
    q->inflight = NULL;
    return r;
}

void ck_queue_release(ck_request *req)
{
    if (req == NULL)
        return;
    free(req->command);
    free(req);
}

ck_request *ck_queue_inflight(const ck_queue *q)
{
    return q->inflight;
}

int32_t ck_queue_depth(const ck_queue *q)
{
    return q->count;
}

int32_t ck_queue_drop_cookie(ck_queue *q, uint32_t cookie)
{
    ck_request *r    = q->head;
    ck_request *prev = NULL;
    int32_t     n    = 0;

    while (r != NULL) {
        ck_request *next = r->next;
        if (r->cookie == cookie) {
            if (prev == NULL)
                q->head = next;
            else
                prev->next = next;
            if (q->tail == r)
                q->tail = prev;
            ck_queue_release(r);
            q->count--;
            n++;
        } else {
            prev = r;
        }
        r = next;
    }
    return n;
}
