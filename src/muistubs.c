/*
 * muistubs.c -- varargs stubs for the MUI tag functions.
 *
 * The MUI headers spell object creation as
 *
 *     app = ApplicationObject, MUIA_..., value, ... End;
 *
 * which expands to a call to MUI_NewObject with a varargs tag list.  On gcc
 * that only works one of two ways: as a stdarg MACRO (inline/muimaster.h's
 * NO_INLINE_STDARG branch), which cannot be used because nesting object
 * macros inside a macro's argument list does not preprocess -- the inner
 * `WindowObject' is not expanded while the outer call's arguments are being
 * collected, so its parenthesis never balances; or as a real varargs
 * FUNCTION, which is what the AmigaOS MUI SDK ships in libmui.a.
 *
 * We are not using that SDK (the whole point of vendoring only headers), and
 * bebbo's toolchain has no libmui, so the three functions we need are
 * defined here.  The trick is the classic amiga.lib one: on m68k every
 * argument is passed on the stack, contiguously, so the address of the last
 * fixed parameter is already the tag array the *A form wants.  That is only
 * true on m68k -- hence the guard.  MorphOS provides its own stubs, so
 * Makefile.mos leaves this file out.
 */

#include <exec/types.h>
#include <utility/tagitem.h>
#include <libraries/mui.h>
#include <proto/muimaster.h>

#if !defined(__mc68000) && !defined(__M68000) && !defined(_M68000)
#error "muistubs.c relies on m68k stack argument passing"
#endif

Object *MUI_NewObject(const char *classname, Tag tag1, ...)
{
    return MUI_NewObjectA(classname, (struct TagItem *)&tag1);
}

Object *MUI_MakeObject(LONG type, ...)
{
    return MUI_MakeObjectA(type, (ULONG *)(&type + 1));
}

LONG MUI_Request(APTR app, APTR win, LONGBITS flags, const char *title,
                 const char *gadgets, const char *format, ...)
{
    return MUI_RequestA(app, win, flags, title, gadgets, format,
                        (APTR)(&format + 1));
}

APTR MUI_AllocAslRequestTags(unsigned long reqType, Tag tag1, ...)
{
    return MUI_AllocAslRequest(reqType, (struct TagItem *)&tag1);
}

BOOL MUI_AslRequestTags(APTR requester, Tag tag1, ...)
{
    return MUI_AslRequest(requester, (struct TagItem *)&tag1);
}
