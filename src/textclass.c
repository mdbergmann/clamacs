/*
 * textclass.c -- the two private MUI subclasses.
 *
 * ClamacsText subclasses the INSTALLED TextEditor.mcc.  It is created at
 * runtime with MUI_CreateCustomClass(NULL, "TextEditor.mcc", ...), so it
 * uses whatever copy of the class the user has -- the AmigaOS 3 archive
 * bundles one, MorphOS ships one -- and the class is never forked or built
 * here.
 *
 * The subclass exists for one reason: to see keys BEFORE the class does.
 * TextEditor resolves keys through a table taken from the user's MUI
 * preferences, and although MUIA_TextEditor_KeyBindings exists in the header
 * nothing in the class reads it (checked against the 15.56 sources), so an
 * application cannot hand it a table.  Overriding MUIM_HandleEvent is the
 * hook that works, and it has a pleasant property: whatever the Emacs layer
 * does not bind is passed straight to the superclass, so the class's own
 * arrows, Home/End, mouse selection, Backspace, undo and self-insert all
 * keep working without being reimplemented.
 *
 * ClamacsMini does the same for the minibuffer's String object, which needs
 * Tab (completion), C-g (abort) and M-p/M-n (history) taken out of the
 * string gadget's hands.
 */

#include "clamacs.h"

#include <string.h>

/*
 * Eight pens for MUIA_TextEditor_ColorMap.  A SetBlock colour value of N
 * means cmap[N-1]; 0 means the normal pen.  document.c maps token kinds onto
 * these, and the order is fixed by that mapping: 1 black, 2 white, 3 red,
 * 4 green, 5 cyan, 6 yellow, 7 blue, 8 magenta.
 */
#define CK_NUM_PENS 8

static const ULONG ck_pen_rgb[CK_NUM_PENS][3] = {
    { 0x00, 0x00, 0x00 },   /* black   */
    { 0xff, 0xff, 0xff },   /* white   */
    { 0xcc, 0x00, 0x00 },   /* red     */
    { 0x00, 0x88, 0x00 },   /* green   */
    { 0x00, 0x99, 0x99 },   /* cyan    */
    { 0x99, 0x77, 0x00 },   /* yellow  */
    { 0x00, 0x00, 0xcc },   /* blue    */
    { 0xaa, 0x00, 0xaa }    /* magenta */
};

struct ck_text_data {
    ck_doc *doc;
    LONG    cmap[CK_NUM_PENS];
    int32_t pens_held;
};

struct ck_mini_data {
    ck_doc *doc;
};

/* ------------------------------------------------------------------ *
 * Raw key decoding
 * ------------------------------------------------------------------ */

ck_key ck_decode_rawkey(const struct IntuiMessage *imsg)
{
    struct InputEvent ie;
    UBYTE             buffer[8];
    LONG              n;
    uint32_t          mods = 0;
    UWORD             qual, code;

    if (imsg == NULL || imsg->Class != IDCMP_RAWKEY)
        return CK_KEY_NONE;

    code = imsg->Code;
    if ((code & IECODE_UP_PREFIX) != 0)
        return CK_KEY_NONE;

    qual = imsg->Qualifier;

    /* Meta is Alt, either one.  The Amiga keys stay free for the OS and for
     * MUI's menu shortcuts, which is why they are not tested here. */
    if ((qual & IEQUALIFIER_CONTROL) != 0)
        mods |= CK_MOD_CTRL;
    if ((qual & (IEQUALIFIER_LALT | IEQUALIFIER_RALT)) != 0)
        mods |= CK_MOD_META;
    if ((qual & (IEQUALIFIER_LSHIFT | IEQUALIFIER_RSHIFT)) != 0)
        mods |= CK_MOD_SHIFT;

    /* The keys that have no character have to be recognised by raw code;
     * MapRawKey would give nothing useful for them. */
    switch (code) {
    case 0x4C: return ck_key_make(CK_KEY_UP, mods);
    case 0x4D: return ck_key_make(CK_KEY_DOWN, mods);
    case 0x4E: return ck_key_make(CK_KEY_RIGHT, mods);
    case 0x4F: return ck_key_make(CK_KEY_LEFT, mods);
    case 0x5F: return ck_key_make(CK_KEY_HELP, mods);
    default:   break;
    }
    if (code >= 0x50 && code <= 0x59)
        return ck_key_make((uint16_t)(CK_KEY_F1 + (code - 0x50)), mods);

    /* Shift and caps only: we want the BASE character, and add our own
     * modifier bits on top.  Letting MapRawKey see Control would turn C-f
     * into 0x06 and lose which letter it was -- and Alt would produce a
     * dead-key accent instead of Meta. */
    memset(&ie, 0, sizeof(ie));
    ie.ie_Class     = IECLASS_RAWKEY;
    ie.ie_Code      = code;
    ie.ie_Qualifier = (UWORD)(qual & (IEQUALIFIER_LSHIFT | IEQUALIFIER_RSHIFT |
                                      IEQUALIFIER_CAPSLOCK | IEQUALIFIER_NUMERICPAD));
    if (imsg->IAddress != NULL)
        ie.ie_EventAddress = (APTR)(*(ULONG *)imsg->IAddress);

    n = MapRawKey(&ie, (STRPTR)buffer, (LONG)sizeof(buffer), NULL);
    if (n != 1)
        return CK_KEY_NONE;

    return ck_key_make((uint16_t)buffer[0], mods);
}

/* ------------------------------------------------------------------ *
 * ClamacsText
 * ------------------------------------------------------------------ */

SDISPATCHER(ck_text_dispatcher)
{
    struct ck_text_data *data;

    switch (msg->MethodID) {
    case OM_NEW: {
        Object *self = (Object *)DoSuperMethodA(cl, obj, (Msg)msg);
        if (self != NULL) {
            data = (struct ck_text_data *)INST_DATA(cl, self);
            data->doc = (ck_doc *)GetTagData(CKA_Doc, 0,
                                             ((struct opSet *)msg)->ops_AttrList);
        }
        return (IPTR)self;
    }

    case OM_SET: {
        struct TagItem *tags = ((struct opSet *)msg)->ops_AttrList;
        struct TagItem *tag;
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        while ((tag = NextTagItem(&tags)) != NULL) {
            if (tag->ti_Tag == CKA_Doc)
                data->doc = (ck_doc *)tag->ti_Data;
        }
        break;
    }

    case MUIM_Setup: {
        struct ColorMap *cm;
        int32_t          i;

        if (DoSuperMethodA(cl, obj, (Msg)msg) == 0)
            return FALSE;

        /* Pens for syntax colouring.  Obtained here rather than at
         * construction because a pen belongs to the screen the object ends
         * up on, which is not known until Setup. */
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        cm   = muiRenderInfo(obj)->mri_Screen->ViewPort.ColorMap;
        for (i = 0; i < CK_NUM_PENS; i++) {
            data->cmap[i] = ObtainBestPenA(cm,
                                           ck_pen_rgb[i][0] << 24,
                                           ck_pen_rgb[i][1] << 24,
                                           ck_pen_rgb[i][2] << 24, NULL);
        }
        data->pens_held = 1;
        set(obj, MUIA_TextEditor_ColorMap, (IPTR)data->cmap);
        return TRUE;
    }

    case MUIM_Cleanup: {
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        if (data->pens_held) {
            struct ColorMap *cm = muiRenderInfo(obj)->mri_Screen->ViewPort.ColorMap;
            int32_t          i;
            set(obj, MUIA_TextEditor_ColorMap, (IPTR)NULL);
            for (i = 0; i < CK_NUM_PENS; i++) {
                if (data->cmap[i] != -1)
                    ReleasePen(cm, data->cmap[i]);
                data->cmap[i] = -1;
            }
            data->pens_held = 0;
        }
        break;
    }

    case MUIM_HandleEvent: {
        struct MUIP_HandleEvent *m = (struct MUIP_HandleEvent *)msg;
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        if (data->doc != NULL && m->imsg != NULL &&
            m->imsg->Class == IDCMP_RAWKEY) {
            ck_key key = ck_decode_rawkey(m->imsg);
            if (key != CK_KEY_NONE && ck_doc_handle_key(data->doc, key))
                return MUI_EventHandlerRC_Eat;
        }
        break;   /* not ours: the class gets it unchanged */
    }

    default:
        break;
    }

    return DoSuperMethodA(cl, obj, (Msg)msg);
}

/* ------------------------------------------------------------------ *
 * ClamacsMini
 * ------------------------------------------------------------------ */

SDISPATCHER(ck_mini_dispatcher)
{
    struct ck_mini_data *data;

    switch (msg->MethodID) {
    case OM_NEW: {
        Object *self = (Object *)DoSuperMethodA(cl, obj, (Msg)msg);
        if (self != NULL) {
            data = (struct ck_mini_data *)INST_DATA(cl, self);
            data->doc = (ck_doc *)GetTagData(CKA_Doc, 0,
                                             ((struct opSet *)msg)->ops_AttrList);
        }
        return (IPTR)self;
    }

    case OM_SET: {
        struct TagItem *tags = ((struct opSet *)msg)->ops_AttrList;
        struct TagItem *tag;
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        while ((tag = NextTagItem(&tags)) != NULL) {
            if (tag->ti_Tag == CKA_Doc)
                data->doc = (ck_doc *)tag->ti_Data;
        }
        break;
    }

    case MUIM_HandleEvent: {
        struct MUIP_HandleEvent *m = (struct MUIP_HandleEvent *)msg;
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        if (data->doc != NULL && m->imsg != NULL &&
            m->imsg->Class == IDCMP_RAWKEY) {
            ck_key key = ck_decode_rawkey(m->imsg);
            if (key != CK_KEY_NONE && ck_doc_minibuffer_key(data->doc, key))
                return MUI_EventHandlerRC_Eat;
        }
        break;
    }

    default:
        break;
    }

    return DoSuperMethodA(cl, obj, (Msg)msg);
}

/* ------------------------------------------------------------------ *
 * Creation
 * ------------------------------------------------------------------ */

int32_t ck_classes_create(ck_app *app)
{
    app->textclass = MUI_CreateCustomClass(NULL, "TextEditor.mcc", NULL,
                                           (int)sizeof(struct ck_text_data),
                                           ENTRY(ck_text_dispatcher));
    if (app->textclass == NULL)
        return 0;

    app->miniclass = MUI_CreateCustomClass(NULL, MUIC_String, NULL,
                                           (int)sizeof(struct ck_mini_data),
                                           ENTRY(ck_mini_dispatcher));
    if (app->miniclass == NULL) {
        MUI_DeleteCustomClass(app->textclass);
        app->textclass = NULL;
        return 0;
    }
    return 1;
}

void ck_classes_free(ck_app *app)
{
    if (app->miniclass != NULL) {
        MUI_DeleteCustomClass(app->miniclass);
        app->miniclass = NULL;
    }
    if (app->textclass != NULL) {
        MUI_DeleteCustomClass(app->textclass);
        app->textclass = NULL;
    }
}
