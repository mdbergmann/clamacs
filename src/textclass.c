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
 * string gadget's hands.  It needs two hooks for that, not one: the handler
 * node is what MUI asks while the String is NOT active (the port's KEY
 * command, FS-UAE's one-key deactivation), but an ACTIVE MUI 3.8 String
 * edits its keys before the window's handler list is consulted, through an
 * Intuition-style string edit hook -- so on a real keyboard TAB moved the
 * focus and C-g typed nothing (Vampire, 2026-09-11).  MUIA_String_EditHook
 * is called ahead of the class's own edit hook, and that is where the
 * minibuffer's keys are taken now; see ck_mini_edit_func().
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
    struct MUI_EventHandlerNode ehnode;
    int32_t eh_added;
    struct MUI_InputHandlerNode ihtimer;   /* the arglist idle timer */
    int32_t timer_added;
};

struct ck_mini_data {
    ck_doc *doc;
    Object *self;
    struct MUI_EventHandlerNode ehnode;
    int32_t eh_added;
    struct Hook edithook;    /* MUIA_String_EditHook; h_Data is this struct */
    /* The key the edit hook last took, so the handler node -- if MUI goes
     * on to consult it for the same event -- does not act on it twice. */
    ck_key  hook_key;
    int32_t hook_taken;
};

/* ------------------------------------------------------------------ *
 * Raw key decoding
 *
 * The rules -- which qualifier is Meta, what the keymap may be told, which
 * keys are recognised by code, what to refuse -- live in emacs/rawkey.c,
 * where tests/test_rawkey.c can reach them.  This is the one OS call they
 * are parameterised over.
 * ------------------------------------------------------------------ */

static int32_t ck_maprawkey(void *ctx, uint16_t code, uint16_t qualifier,
                            uint8_t *out, int32_t size)
{
    const struct IntuiMessage *imsg = (const struct IntuiMessage *)ctx;
    struct InputEvent          ie;

    memset(&ie, 0, sizeof ie);
    ie.ie_Class     = IECLASS_RAWKEY;
    ie.ie_Code      = code;
    ie.ie_Qualifier = qualifier;
    /* For IDCMP_RAWKEY, IAddress points at the previous key codes the keymap
     * needs for dead-key composition. */
    if (imsg->IAddress != NULL)
        ie.ie_EventAddress = (APTR)(*(ULONG *)imsg->IAddress);

    return (int32_t)MapRawKey(&ie, (STRPTR)out, (LONG)size, NULL);
}

ck_key ck_decode_rawkey(const struct IntuiMessage *imsg)
{
    if (imsg == NULL || imsg->Class != IDCMP_RAWKEY)
        return CK_KEY_NONE;
    return ck_rawkey_decode(imsg->Code, imsg->Qualifier, ck_maprawkey,
                            (void *)imsg);
}

/*
 * Our own RAWKEY event handler node.
 *
 * The reason it exists rather than a plain MUIM_HandleEvent override: MUI
 * delivers input by CoerceMethod on the class stored in a handler node's
 * ehn_Class (mui.h: "MUIM_HandleEvent is invoked on exactly this class").
 * TextEditor.mcc registers its node with ehn_Class = cl in its own Setup,
 * and because the subclass reaches that code through DoSuperMethodA, `cl'
 * there is the SUPERCLASS -- so every key is coerced straight to the class,
 * and a MUIM_HandleEvent override on the subclass is never called (confirmed
 * in FS-UAE: only the class's own self-insert ran).  Registering a node that
 * names OUR class, at a higher priority than the class's 0, puts the Emacs
 * layer first; when it does not consume the key it returns 0 and MUI's next
 * handler -- the class's own node -- does the ordinary editing.
 */
static void ck_add_handler(struct MUI_EventHandlerNode *ehn, struct IClass *cl,
                           Object *obj)
{
    ehn->ehn_Priority = 1;      /* above the class's 0: the Emacs layer first */
    ehn->ehn_Flags    = MUI_EHF_GUIMODE;
    ehn->ehn_Object   = obj;
    ehn->ehn_Class    = cl;     /* our subclass: CoerceMethod comes back here */
    ehn->ehn_Events   = IDCMP_RAWKEY;
    DoMethod(_win(obj), MUIM_Window_AddEventHandler, (IPTR)ehn);
}

static void ck_rem_handler(struct MUI_EventHandlerNode *ehn, Object *obj)
{
    DoMethod(_win(obj), MUIM_Window_RemEventHandler, (IPTR)ehn);
}

/*
 * Whether OBJ is the window's active object.  MUI delivers a RAWKEY to every
 * registered handler regardless of focus -- the text object and the
 * minibuffer both have one -- so each checks whether it is the active object
 * and only the one with the focus acts, exactly as TextEditor.mcc does
 * before its own self-insert.
 */
static int32_t ck_is_active(Object *obj)
{
    Object *win    = _win(obj);
    IPTR    active = 0;

    if (win == NULL)
        return 0;
    GetAttr(MUIA_Window_ActiveObject, win, &active);
    return (Object *)active == obj;
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

        /* The Emacs layer's key handler, ahead of the class's own. */
        ck_add_handler(&data->ehnode, cl, obj);
        data->eh_added = 1;

        /* The arglist idle timer.  MUI fires CKM_IdleTick on this object
         * every 3/10 s; ck_intro_idle() returns at once unless the cursor
         * has come to rest in this (active) window, so a background document
         * costs a comparison per tick.  Its own handler node, like the
         * RAWKEY one, so its lifetime is exactly the object's. */
        memset(&data->ihtimer, 0, sizeof data->ihtimer);
        data->ihtimer.ihn_Flags  = MUIIHNF_TIMER | MUIIHNF_TIMER_SCALE100;
        data->ihtimer.ihn_Millis  = 3;
        data->ihtimer.ihn_Object  = obj;
        data->ihtimer.ihn_Method  = CKM_IdleTick;
        DoMethod(_app(obj), MUIM_Application_AddInputHandler, (IPTR)&data->ihtimer);
        data->timer_added = 1;
        return TRUE;
    }

    case MUIM_Cleanup: {
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        if (data->timer_added) {
            DoMethod(_app(obj), MUIM_Application_RemInputHandler,
                     (IPTR)&data->ihtimer);
            data->timer_added = 0;
        }
        if (data->eh_added) {
            ck_rem_handler(&data->ehnode, obj);
            data->eh_added = 0;
        }
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

        /* Invoked only through our own handler node, so it does not chain to
         * the superclass: when the Emacs layer does not consume the key it
         * returns 0 and MUI's next handler -- the class's node -- edits. */
        if (data->doc != NULL && m->imsg != NULL &&
            m->imsg->Class == IDCMP_RAWKEY && ck_is_active(obj)) {
            ck_key key = ck_decode_rawkey(m->imsg);
            if (key != CK_KEY_NONE && ck_doc_handle_key(data->doc, key))
                return MUI_EventHandlerRC_Eat;
        }
        return 0;
    }

    case CKM_IdleTick: {
        data = (struct ck_text_data *)INST_DATA(cl, obj);
        if (data->doc != NULL)
            ck_intro_idle(data->doc);
        return 0;
    }

    /*
     * The Emacs layer is the keyboard authority for the text object, but
     * several of its keys are also MUI's built-in window controls, and MUI
     * acts on those at the window level whether or not our handler ate the
     * event -- so the focus is stolen before the Emacs binding runs.  The
     * superclass already disables MUIKEY_GADGET_NEXT here so TAB reaches us;
     * the rest have to be disabled too while the text object is active:
     *   RET -> MUIKEY_PRESS (fire the default gadget)
     *   ESC -> MUIKEY_GADGET_OFF / MUIKEY_WINDOW_CLOSE (deactivate / close)
     *   TAB, Shift-TAB -> GADGET_NEXT / GADGET_PREV
     * The minibuffer manages its own set in its GoActive, and the superclass
     * restores 0 in GoInactive, so this scope is exactly "text has focus".
     */
    case MUIM_GoActive: {
        IPTR result = DoSuperMethodA(cl, obj, (Msg)msg);
        set(_win(obj), MUIA_Window_DisableKeys,
            MUIKEYF_PRESS | MUIKEYF_GADGET_NEXT | MUIKEYF_GADGET_PREV |
            MUIKEYF_GADGET_OFF | MUIKEYF_WINDOW_CLOSE);
        return result;
    }

    default:
        break;
    }

    return DoSuperMethodA(cl, obj, (Msg)msg);
}

/* ------------------------------------------------------------------ *
 * ClamacsMini
 * ------------------------------------------------------------------ */

/*
 * The string edit hook: MUI calls it "as if it was a real string edit hook
 * in a real string gadget" (MUI_String.doc), with the SGWork in A2 and the
 * command word in A1, BEFORE the class's own edit hook, and it ignores the
 * result.  That last point shapes what the hook can do.  It cannot tell
 * MUI "handled, stop here": the class's hook runs on the same SGWork next,
 * so a key we take has to be made invisible to it -- the event's code is
 * turned into a key release and the mapped character cleared, and a string
 * gadget does nothing with those.  And the action itself is deferred with
 * MUIM_Application_PushMethod rather than run here: the class's hook may
 * still write its work buffer back to the gadget after us, which would
 * undo a completion or a history item set from inside this call.  What
 * the hook does here is decide, exactly as the handler node decides, and
 * ck_doc_minibuffer_binds() is the one list both consult.
 *
 * Meta plus a character that the minibuffer does not bind is taken too:
 * left to the gadget, Alt-x goes through the keymap with Alt as a dead-key
 * qualifier and types a stray character (`x' gave `×' on the Vampire).
 * The deferred method reports it undefined, as the text object does.
 */

/* The keymap lookup on the SGWork's InputEvent.  The dead-key history
 * (ie_EventAddress) is dropped: none of the keys the minibuffer binds is a
 * composed character, and a key the hook does not take goes to the class
 * with the event untouched. */
static int32_t ck_maprawkey_ie(void *ctx, uint16_t code, uint16_t qualifier,
                               uint8_t *out, int32_t size)
{
    struct InputEvent ie = *(const struct InputEvent *)ctx;

    ie.ie_NextEvent    = NULL;
    ie.ie_Class        = IECLASS_RAWKEY;
    ie.ie_Code         = code;
    ie.ie_Qualifier    = qualifier;
    ie.ie_EventAddress = NULL;
    return (int32_t)MapRawKey(&ie, (STRPTR)out, (LONG)size, NULL);
}

static int32_t ck_mini_meta_char(ck_key key)
{
    uint16_t code = CK_KEY_CODE(key);
    return (CK_KEY_MODS(key) & CK_MOD_META) != 0 && code >= 0x20 && code <= 0xFF;
}

HOOKPROTO(ck_mini_edit_func, ULONG, struct SGWork *sgw, ULONG *msg)
{
    struct ck_mini_data *data = (struct ck_mini_data *)hook->h_Data;
    struct InputEvent   *ie;
    ck_key               key;

    if (msg == NULL || msg[0] != SGH_KEY || sgw == NULL || sgw->IEvent == NULL ||
        data == NULL || data->doc == NULL)
        return 0;

    ie  = sgw->IEvent;
    key = ck_rawkey_decode(ie->ie_Code, ie->ie_Qualifier, ck_maprawkey_ie, ie);
    if (key == CK_KEY_NONE)
        return 0;
    if (!ck_doc_minibuffer_binds(data->doc, key) && !ck_mini_meta_char(key))
        return 0;

    data->hook_key   = key;
    data->hook_taken = 1;

    /* Make the key a no-op for the class's hook: a release of no key, with
     * no qualifier and no character. */
    ie->ie_Code      = (UWORD)(CK_RAW_UP_PREFIX | 0x7F);
    ie->ie_Qualifier = 0;
    sgw->Code        = 0;

    DoMethod(_app(data->self), MUIM_Application_PushMethod, (IPTR)data->self,
             2, CKM_MiniKey, (IPTR)key);
    return 0;
}
MakeStaticHook(ck_mini_edit_hook, ck_mini_edit_func);

SDISPATCHER(ck_mini_dispatcher)
{
    struct ck_mini_data *data;

    switch (msg->MethodID) {
    case OM_NEW: {
        Object *self = (Object *)DoSuperMethodA(cl, obj, (Msg)msg);
        if (self != NULL) {
            data = (struct ck_mini_data *)INST_DATA(cl, self);
            data->doc  = (ck_doc *)GetTagData(CKA_Doc, 0,
                                              ((struct opSet *)msg)->ops_AttrList);
            data->self = self;
            /* One hook per object, since it must find its instance data:
             * the static hook supplies the entry, h_Data the data. */
            InitHook(&data->edithook, ck_mini_edit_hook, data);
            set(self, MUIA_String_EditHook, (IPTR)&data->edithook);
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

    case MUIM_Setup:
        if (DoSuperMethodA(cl, obj, (Msg)msg) == 0)
            return FALSE;
        /* Same reason as the text class: MUIM_HandleEvent reaches a String
         * subclass only through a handler node naming this class. */
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        ck_add_handler(&data->ehnode, cl, obj);
        data->eh_added = 1;
        return TRUE;

    case MUIM_Cleanup:
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        if (data->eh_added) {
            ck_rem_handler(&data->ehnode, obj);
            data->eh_added = 0;
        }
        break;

    case MUIM_HandleEvent: {
        struct MUIP_HandleEvent *m = (struct MUIP_HandleEvent *)msg;
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        if (data->doc != NULL && m->imsg != NULL &&
            m->imsg->Class == IDCMP_RAWKEY && ck_is_active(obj)) {
            ck_key key = ck_decode_rawkey(m->imsg);
            /* An active String edits its keys through the edit hook before
             * the handler list is consulted, so when the hook has just taken
             * this key the node is seeing the same event again.  The flag
             * is cleared here whatever the key: if it is a different one the
             * String ate the earlier event and MUI never came this way. */
            if (data->hook_taken) {
                data->hook_taken = 0;
                if (key == data->hook_key)
                    return MUI_EventHandlerRC_Eat;
            }
            if (key != CK_KEY_NONE && ck_doc_minibuffer_key(data->doc, key))
                return MUI_EventHandlerRC_Eat;
        }
        /* Not consumed: MUI's next handler -- the string gadget's own -- does
         * the ordinary editing and cursor motion. */
        return 0;
    }

    /* A key the edit hook took, now that the String's own key handling is
     * over and the contents may be changed safely. */
    case CKM_MiniKey: {
        ck_key key = (ck_key)((struct CKP_MiniKey *)msg)->key;
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        if (data->doc != NULL && !ck_doc_minibuffer_key(data->doc, key) &&
            data->doc->mini_state != CK_MINI_IDLE) {
            char spelling[32];
            ck_message(data->doc, "%s is undefined",
                       ck_key_to_string(key, spelling, (int32_t)sizeof spelling));
        }
        return 0;
    }

    /* TAB is MUI's cycle-chain key, handled by the window whether or not an
     * object's handler ate it.  While the minibuffer has the focus TAB is
     * ours (completion), so the window's handling of it is switched off for
     * the duration -- the same thing TextEditor.mcc does for its own object
     * in mGoActive/mGoInactive. */
    case MUIM_GoActive:
        set(_win(obj), MUIA_Window_DisableKeys, MUIKEYF_GADGET_NEXT);
        break;

    case MUIM_GoInactive:
        data = (struct ck_mini_data *)INST_DATA(cl, obj);
        data->hook_taken = 0;
        set(_win(obj), MUIA_Window_DisableKeys, 0);
        break;

    default:
        break;
    }

    return DoSuperMethodA(cl, obj, (Msg)msg);
}

/* ------------------------------------------------------------------ *
 * Creation
 * ------------------------------------------------------------------ */

/*
 * The oldest TextEditor.mcc the phase-1 code works with.
 * MUIM_TextEditor_SetBlock, which the colouring and the paren highlight rest
 * on, arrived in 15.29 (vendor/texteditor/ChangeLog); ExportBlock's FullLines
 * flag and the NoStyle export hook are older, and the success codes that
 * 15.49 and 15.53 added to IndexToCursorXY/CursorXYToIndex are not relied
 * on.  Verified against 15.56.
 */
#define CK_TEXTEDITOR_VMIN 15
#define CK_TEXTEDITOR_RMIN 29

/* YAM's way of asking an MCC its version: make a bare object of the class
 * and read MUIA_Version/MUIA_Revision, which MUI answers with the module's
 * library version.  Works before any window or application object exists,
 * and loads the class, so a missing one fails here rather than later. */
static int32_t ck_texteditor_version(LONG *version, LONG *revision)
{
    Object *probe = MUI_NewObject("TextEditor.mcc", TAG_DONE);
    IPTR    v = 0, r = 0;

    if (probe == NULL)
        return 0;
    GetAttr(MUIA_Version,  probe, &v);
    GetAttr(MUIA_Revision, probe, &r);
    MUI_DisposeObject(probe);

    *version  = (LONG)v;
    *revision = (LONG)r;
    return 1;
}

int32_t ck_classes_create(ck_app *app)
{
    if (!ck_texteditor_version(&app->te_version, &app->te_revision))
        return CK_CLASSES_MISSING;
    if (app->te_version < CK_TEXTEDITOR_VMIN ||
        (app->te_version == CK_TEXTEDITOR_VMIN &&
         app->te_revision < CK_TEXTEDITOR_RMIN))
        return CK_CLASSES_TOO_OLD;

    app->textclass = MUI_CreateCustomClass(NULL, "TextEditor.mcc", NULL,
                                           (int)sizeof(struct ck_text_data),
                                           ENTRY(ck_text_dispatcher));
    if (app->textclass == NULL)
        return CK_CLASSES_MISSING;

    app->miniclass = MUI_CreateCustomClass(NULL, MUIC_String, NULL,
                                           (int)sizeof(struct ck_mini_data),
                                           ENTRY(ck_mini_dispatcher));
    if (app->miniclass == NULL) {
        MUI_DeleteCustomClass(app->textclass);
        app->textclass = NULL;
        return CK_CLASSES_MISSING;
    }
    return CK_CLASSES_OK;
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
