/* clamacs-host.m -- the native shim of the host frontend (specs/clamacs-host.md).
 *
 * What a page cannot do and the webview C API does not offer: one turn
 * of the event loop (the editor's run-loop steps it, so the main thread
 * reaches a GC safepoint every few milliseconds instead of parking in
 * webview_run), a wake from another thread, the requesters, the file
 * panels, the beep, the clipboard, the URL opener, a window's frame, its
 * close button and its raising (the editor opens a window per detached
 * tab, so what is per window is kept ON the window, never in a static)
 * -- and on macOS the menu bar, the screen's, built from the editor's
 * menu table (the page draws its own where the host has no menu of its
 * own).  Built into libclamacs-host.{dylib,so,dll} by host/build.sh and
 * called through ffi:call-foreign; every entry is plain C, and the same
 * on every host:
 *
 *   __APPLE__          Cocoa (the file is Objective-C there, hence .m)
 *   CLAMACS_HOST_GTK   GTK 3 on Linux and the BSDs (build.sh defines it
 *                      when pkg-config finds gtk+-3.0; compiled as C with
 *                      `-x c')
 *   _WIN32             Win32 (MSYS2 gcc; compiled as C the same way).
 *                      Written to the API, compiled with mingw-w64, not
 *                      yet run on a Windows machine -- specs/clamacs-host.md,
 *                      H6
 *   anything else      every entry has a "not available" return so the
 *                      editor runs without them (the requester falls back
 *                      to the echo area, the file dialog to the prompt)
 *
 * The strings that arrive are the editor's: 8-bit, Latin-1 for text and
 * the file system's bytes for a path (see text_arg below the Cocoa part;
 * each backend converts the same way).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

/* ---- the event loop ------------------------------------------------- */

/* Run the loop for at most MS milliseconds: wait for the first event that
 * long, then deliver everything already pending without waiting.  The
 * blocks webview_dispatch queues on the main queue run inside the wait
 * (the run loop services the main dispatch queue), as do the bindings'
 * callbacks.  Returns the number of events delivered. */
int clamacs_host_step(void *w, int ms)
{
    (void)w;
    @autoreleasepool {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:ms / 1000.0];
        int n = 0;
        for (;;) {
            NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                             untilDate:until
                                                inMode:NSDefaultRunLoopMode
                                               dequeue:YES];
            if (ev == nil)
                break;
            [NSApp sendEvent:ev];
            n++;
            until = [NSDate distantPast];
        }
        return n;
    }
}

/* From any thread: end the step in progress, so the loop returns to Lisp
 * and drains its mailbox.  An application-defined event, which sendEvent:
 * ignores -- the same event webview's own terminate posts. */
void clamacs_host_wake(void)
{
    @autoreleasepool {
        NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                         location:NSMakePoint(0, 0)
                                    modifierFlags:0
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                          subtype:0
                                            data1:0
                                            data2:0];
        [NSApp postEvent:ev atStart:YES];
    }
}

/* ---- string arguments ------------------------------------------------ */

/* The editor's strings are 8-bit and ffi:foreign-string writes one byte per
 * character, so a character from 128 to 255 arrives as a lone byte, which
 * is not UTF-8: stringWithUTF8String: answers nil for it, and a nil handed
 * on raises an Objective-C exception that ends the editor.  Text (messages,
 * button names, the clipboard, an address) is Latin-1 and decodes as such,
 * which cannot fail; a path is the file system's bytes, UTF-8 on macOS, and
 * is nil when it is not valid.  Both answer nil for NULL, and every caller
 * checks. */
static NSString *text_arg(const char *s)
{
    return s ? [NSString stringWithCString:s encoding:NSISOLatin1StringEncoding] : nil;
}

static NSString *path_arg(const char *s)
{
    return s ? [NSString stringWithUTF8String:s] : nil;
}

/* ---- requesters ----------------------------------------------------- */

/* An NSAlert with TEXT and the buttons of BUTTONS ("Save|Discard|Cancel"),
 * answering the index of the one pressed.  A button named Cancel takes
 * Escape as well; without one Escape answers -1. */
int clamacs_host_ask(void *win, const char *text, const char *buttons)
{
    (void)win;
    @autoreleasepool {
        NSString *message = text_arg(text ? text : "");
        NSString *list = text_arg(buttons ? buttons : "OK");
        if (message == nil || list == nil)
            return -1;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = message;
        NSArray *names = [list componentsSeparatedByString:@"|"];
        NSUInteger i;
        for (i = 0; i < names.count; i++) {
            NSButton *b = [alert addButtonWithTitle:names[i]];
            if ([names[i] isEqualToString:@"Cancel"])
                b.keyEquivalent = @"\033";
        }
        NSModalResponse r = [alert runModal];
        if (r >= NSAlertFirstButtonReturn &&
            r < NSAlertFirstButtonReturn + (NSModalResponse)names.count)
            return (int)(r - NSAlertFirstButtonReturn);
        return -1;
    }
}

/* The file panel: an NSSavePanel when SAVE, else an NSOpenPanel; INITIAL
 * is the path to start from (a file or a directory), or NULL.  The chosen
 * path, malloc'd (clamacs_host_free), or NULL when cancelled. */
char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)
{
    (void)win;
    @autoreleasepool {
        NSSavePanel *panel;
        if (save) {
            panel = [NSSavePanel savePanel];
        } else {
            NSOpenPanel *open = [NSOpenPanel openPanel];
            open.canChooseFiles = YES;
            open.canChooseDirectories = NO;
            open.allowsMultipleSelection = NO;
            panel = open;
        }
        NSString *message = text_arg(title);
        if (message != nil)
            panel.message = message;
        /* A start path that is not valid UTF-8, or has no directory part,
         * leaves the panel where it opens by itself. */
        NSString *path = (initial && *initial) ? path_arg(initial) : nil;
        if (path != nil) {
            BOOL dir = NO;
            NSString *parent = [path stringByDeletingLastPathComponent];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] && dir) {
                panel.directoryURL = [NSURL fileURLWithPath:path];
            } else {
                if (parent.length > 0)
                    panel.directoryURL = [NSURL fileURLWithPath:parent];
                panel.nameFieldStringValue = [path lastPathComponent];
            }
        }
        if ([panel runModal] != NSModalResponseOK || panel.URL == nil)
            return NULL;
        const char *chosen = [[panel.URL path] UTF8String];
        return chosen ? strdup(chosen) : NULL;
    }
}

void clamacs_host_free(void *p)
{
    free(p);
}

/* ---- small services -------------------------------------------------- */

void clamacs_host_beep(void)
{
    NSBeep();
}

int clamacs_host_clipboard_set(const char *text)
{
    @autoreleasepool {
        NSString *s = text_arg(text ? text : "");
        if (s == nil)
            return 0;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        return [pb setString:s forType:NSPasteboardTypeString] ? 1 : 0;
    }
}

int clamacs_host_open_url(const char *url)
{
    @autoreleasepool {
        NSString *s = text_arg(url ? url : "");
        NSURL *u = s ? [NSURL URLWithString:s] : nil;
        if (u == nil)
            return 0;
        return [[NSWorkspace sharedWorkspace] openURL:u] ? 1 : 0;
    }
}

/* ---- the window ------------------------------------------------------ */

/* The frame with a top-left origin (the editor's and the layout file's
 * convention), flipped from Cocoa's bottom-left one on the primary
 * screen: out[0] left, out[1] top, out[2] width, out[3] height. */
static CGFloat primary_screen_height(void)
{
    NSScreen *primary = [[NSScreen screens] firstObject];
    return primary ? primary.frame.size.height : 0;
}

void clamacs_host_get_frame(void *win, int32_t out[4])
{
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        NSRect f = window.frame;
        out[0] = (int32_t)f.origin.x;
        out[1] = (int32_t)(primary_screen_height() - (f.origin.y + f.size.height));
        out[2] = (int32_t)f.size.width;
        out[3] = (int32_t)f.size.height;
    }
}

void clamacs_host_set_frame(void *win, int left, int top, int width, int height)
{
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        NSRect f = NSMakeRect(left, primary_screen_height() - top - height, width, height);
        [window setFrame:f display:YES];
    }
}

/* The close button asks the editor instead of closing the window: FN(ARG)
 * runs (save-buffers-kill-emacs for the main window, the tabs' return for
 * a detached one -- Lisp callbacks) and the window stays; the loop ends it
 * when the editor is done.  Everything else the window asks its delegate
 * is forwarded to webview's own.  One delegate per window, kept alive by
 * the window itself (an associated object), so a second window's hook
 * never replaces the first's. */
@interface ClamacsWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, strong) id inner;
@property (nonatomic, assign) void (*fn)(void *);
@property (nonatomic, assign) void *arg;
@end

@implementation ClamacsWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    if (self.fn) {
        self.fn(self.arg);
        return NO;
    }
    return YES;
}
- (BOOL)respondsToSelector:(SEL)sel
{
    return [super respondsToSelector:sel] || [self.inner respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel
{
    (void)sel;
    return self.inner;
}
@end

static const void *close_delegate_key = &close_delegate_key;

void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)
{
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        ClamacsWindowDelegate *delegate = objc_getAssociatedObject(window, close_delegate_key);
        if (delegate == nil) {
            delegate = [[ClamacsWindowDelegate alloc] init];
            delegate.inner = window.delegate;
            window.delegate = delegate;
            objc_setAssociatedObject(window, close_delegate_key, delegate,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        delegate.fn = fn;
        delegate.arg = arg;
    }
}

/* The window to the front with the keyboard: a document activated in
 * another window than the one that had it. */
void clamacs_host_raise(void *win)
{
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        [window makeKeyAndOrderFront:nil];
    }
}

/* The toolkit's name and version, for About. */
const char *clamacs_host_toolkit(void)
{
    static char line[96];
    if (line[0] == 0) {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        snprintf(line, sizeof line, "Cocoa/WebKit on macOS %ld.%ld.%ld",
                 (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
    }
    return line;
}

/* ---- the menu bar ---------------------------------------------------- */

/* The editor's menu table on the screen's menu bar, where a Mac keeps
 * its menus (webview makes no main menu at all, so until now Cmd-Q did
 * nothing).  TABLE is the table of menu.lisp, one entry per line in
 * order -- "kind<TAB>title<TAB>keys", kind one of title, item, bar,
 * hidden (an entry this bar does not draw; its line is kept so the
 * indices stay the table's), or the name of a DYNAMIC GROUP (buffers,
 * themes): a menu whose items the editor remakes at run time through
 * clamacs_host_menu_dynamic -- the shim does not know what a buffer or
 * a theme is, it keeps a named list of lines.  An item's position in the
 * table is its table index, which a pick hands back: FN(0, index, ARG)
 * for an item of the table, FN(group, n, ARG) for the n-th line of a
 * dynamic group (the bar counts), GROUP the table index of the group's
 * own entry -- never 0, the first entry being a title.
 * The key an item shows is the editor's Emacs chord (C-x C-s), drawn
 * dimmed beside the label: it is not a Cocoa key equivalent -- the page
 * handles every key, and a menu key equivalent would take the key away
 * from it before it arrived.  The one application menu Cocoa expects
 * comes first, with Hide and a Quit (Cmd-Q) that asks the window to
 * close, which is the close button's path -- the editor decides.  The
 * items enable nothing by themselves (autoenablesItems off): the editor
 * says which are enabled, through clamacs_host_menu_enable.  Answers 1;
 * a host without a menu bar of its own answers 0 and the page draws it. */
@interface ClamacsMenuTarget : NSObject
@property (nonatomic, assign) void (*fn)(int32_t, int32_t, void *);
@property (nonatomic, assign) void *arg;
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, strong) NSMenu *previous;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMenuItem *> *items;
/* The dynamic groups by name: the menu, its entry's table index, the
 * lines it shows, and the names in table order for the report. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMenu *> *dynamic;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *dynamicIndex;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *dynamicLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *dynamicOrder;
@end

@implementation ClamacsMenuTarget
- (void)pick:(NSMenuItem *)sender
{
    if (self.fn)
        self.fn(0, (int32_t)sender.tag, self.arg);
}
/* A dynamic group's item carries its group's table index as its
 * represented object and its line's position as its tag. */
- (void)pickDynamic:(NSMenuItem *)sender
{
    if (self.fn)
        self.fn((int32_t)[(NSNumber *)sender.representedObject intValue],
                (int32_t)sender.tag, self.arg);
}
- (void)quit:(id)sender
{
    (void)sender;
    [self.window performClose:nil];
}
@end

static ClamacsMenuTarget *menu_target;

/* The label, and the Emacs key after it in a smaller, dimmed monospace
 * run -- the shortcut column of the Amiga's strip, as near as a Cocoa
 * item gets without a key equivalent. */
static NSAttributedString *menu_item_title(NSString *label, NSString *keys)
{
    NSFont *font = [NSFont menuFontOfSize:0];
    NSMutableAttributedString *s =
        [[NSMutableAttributedString alloc] initWithString:label
                                               attributes:@{NSFontAttributeName: font}];
    if (keys.length > 0) {
        NSFont *mono = [NSFont monospacedSystemFontOfSize:font.pointSize - 2
                                                   weight:NSFontWeightRegular];
        NSDictionary *dim = @{NSFontAttributeName: mono,
                              NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
        [s appendAttributedString:
            [[NSAttributedString alloc] initWithString:[@"    " stringByAppendingString:keys]
                                            attributes:dim]];
    }
    return s;
}

static NSMenu *menu_application(void)
{
    NSMenu *app = [[NSMenu alloc] initWithTitle:@"Clamacs"];
    NSMenuItem *others;
    [app addItemWithTitle:@"Hide Clamacs" action:@selector(hide:) keyEquivalent:@"h"];
    others = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:)
                     keyEquivalent:@"h"];
    others.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Quit Clamacs" action:@selector(quit:) keyEquivalent:@"q"].target = menu_target;
    return app;
}

int clamacs_host_menu_set(void *win, const char *table,
                          void (*fn)(int32_t, int32_t, void *), void *arg)
{
    @autoreleasepool {
        NSString *text = text_arg(table);
        NSMenu *main, *menu = nil;
        NSMenuItem *top;
        NSInteger index = 0;
        if (text == nil)
            return 0;
        if (menu_target == nil) {
            menu_target = [[ClamacsMenuTarget alloc] init];
            menu_target.previous = NSApp.mainMenu;
        }
        menu_target.fn = fn;
        menu_target.arg = arg;
        menu_target.window = (__bridge NSWindow *)win;
        menu_target.items = [NSMutableDictionary dictionary];
        menu_target.dynamic = [NSMutableDictionary dictionary];
        menu_target.dynamicIndex = [NSMutableDictionary dictionary];
        menu_target.dynamicLines = [NSMutableDictionary dictionary];
        menu_target.dynamicOrder = [NSMutableArray array];

        main = [[NSMenu alloc] initWithTitle:@"MainMenu"];
        top = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
        top.submenu = menu_application();
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
            NSString *kind = f[0];
            NSString *title = f.count > 1 ? f[1] : @"";
            NSString *keys = f.count > 2 ? f[2] : @"";
            if ([kind isEqualToString:@"title"]) {
                top = [main addItemWithTitle:title action:nil keyEquivalent:@""];
                menu = [[NSMenu alloc] initWithTitle:title];
                menu.autoenablesItems = NO;
                top.submenu = menu;
                if ([title isEqualToString:@"Help"])
                    NSApp.helpMenu = menu;
            } else if (menu == nil || [kind isEqualToString:@"hidden"]) {
                /* an entry before the first title, or one not drawn here */
            } else if ([kind isEqualToString:@"bar"]) {
                [menu addItem:[NSMenuItem separatorItem]];
            } else if (![kind isEqualToString:@"item"]) {
                /* a dynamic group, named by its kind */
                if (kind.length > 0 && menu_target.dynamic[kind] == nil) {
                    menu_target.dynamic[kind] = menu;
                    menu_target.dynamicIndex[kind] = @(index);
                    menu_target.dynamicLines[kind] = [NSMutableArray array];
                    [menu_target.dynamicOrder addObject:kind];
                }
            } else {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                              action:@selector(pick:)
                                                       keyEquivalent:@""];
                item.attributedTitle = menu_item_title(title, keys);
                item.target = menu_target;
                item.tag = index;
                [menu addItem:item];
                menu_target.items[@(index)] = item;
            }
            index++;
        }
        /* The application menu's title is the bundle's CFBundleName, or the
         * process name without a bundle (`clamiga' from run.sh; the bundle
         * says Clamacs).  AppKit reads it from the main bundle's info
         * dictionary when the menu is installed, and that dictionary is
         * mutable in practice: the name is set there first. */
        {
            NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
            if ([info isKindOfClass:[NSMutableDictionary class]] && info[@"CFBundleName"] == nil)
                ((NSMutableDictionary *)info)[@"CFBundleName"] = @"Clamacs";
        }
        NSApp.mainMenu = main;
        return 1;
    }
}

void clamacs_host_menu_enable(int index, int flag)
{
    @autoreleasepool {
        NSMenuItem *item = menu_target ? menu_target.items[@(index)] : nil;
        if (item)
            item.enabled = flag != 0;
    }
}

/* The dynamic group WHICH (its kind in the table: "buffers", "themes")
 * remade from LINES, one per line as the editor's BUFFERS and THEMES
 * verbs spell them: "-" a bar, "> label" the ticked item, "  label"
 * another.  A pick hands back the group's table index and the line's
 * position.  A group the table did not have: nothing. */
void clamacs_host_menu_dynamic(const char *which, const char *lines)
{
    @autoreleasepool {
        NSString *name = text_arg(which);
        NSString *text = text_arg(lines);
        NSMenu *menu = (menu_target && name) ? menu_target.dynamic[name] : nil;
        NSMutableArray<NSString *> *shown;
        NSNumber *group;
        NSInteger n = 0;
        if (text == nil || menu == nil)
            return;
        shown = menu_target.dynamicLines[name];
        group = menu_target.dynamicIndex[name];
        [menu removeAllItems];
        [shown removeAllObjects];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if (line.length == 0)
                continue;
            if ([line isEqualToString:@"-"]) {
                [menu addItem:[NSMenuItem separatorItem]];
            } else {
                BOOL ticked = [line hasPrefix:@"> "];
                NSString *label = line.length >= 2 ? [line substringFromIndex:2] : line;
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label
                                                              action:@selector(pickDynamic:)
                                                       keyEquivalent:@""];
                item.target = menu_target;
                item.tag = n;
                item.representedObject = group;
                item.state = ticked ? NSControlStateValueOn : NSControlStateValueOff;
                [menu addItem:item];
            }
            [shown addObject:line];
            n++;
        }
    }
}

/* The dynamic group whose entry is at the table index WHICH, or nil. */
static NSMenu *menu_dynamic_at(int which)
{
    for (NSString *name in menu_target.dynamicOrder)
        if ([menu_target.dynamicIndex[name] intValue] == which)
            return menu_target.dynamic[name];
    return nil;
}

/* For a script: perform the action of an item as a click would -- WHICH
 * 0 and a table index, or a dynamic group's table index and a position
 * in it -- so the whole path from the NSMenuItem to the editor's callback
 * is exercised.  1 when there was such an item (a disabled one is passed
 * over, as the mouse would), 0 otherwise. */
int clamacs_host_menu_click(int which, int n)
{
    @autoreleasepool {
        NSMenuItem *item = nil;
        NSMenu *group;
        if (menu_target == nil)
            return 0;
        if (which == 0) {
            item = menu_target.items[@(n)];
        } else if ((group = menu_dynamic_at(which)) != nil
                   && n >= 0 && n < (int)group.numberOfItems) {
            item = [group itemAtIndex:n];
            if (item.isSeparatorItem)
                item = nil;
        }
        if (item == nil)
            return 0;
        if (item.enabled)
            [item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];
        return 1;
    }
}

static void json_string(NSMutableString *out, NSString *s)
{
    NSUInteger i;
    [out appendString:@"\""];
    for (i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '"' || c == '\\')
            [out appendFormat:@"\\%C", c];
        else if (c < 0x20)
            [out appendFormat:@"\\u%04x", (unsigned)c];
        else
            [out appendFormat:@"%C", c];
    }
    [out appendString:@"\""];
}

/* What the menu bar shows, as the page reports its own: the item count,
 * the dimmed table indices in order, and each dynamic group's lines
 * under its name, in table order -- JSON, malloc'd (clamacs_host_free);
 * NULL without a menu.  Read off the NSMenuItems, so a script checks
 * what is on the screen, not what the editor said. */
char *clamacs_host_menu_report(void)
{
    @autoreleasepool {
        NSMutableString *out;
        NSArray<NSNumber *> *indices;
        NSUInteger i;
        BOOL first = YES;
        if (menu_target == nil)
            return NULL;
        indices = [menu_target.items.allKeys sortedArrayUsingSelector:@selector(compare:)];
        out = [NSMutableString stringWithFormat:@"{\"items\":%lu,\"disabled\":[",
               (unsigned long)indices.count];
        for (NSNumber *index in indices) {
            if (!menu_target.items[index].enabled) {
                [out appendFormat:@"%s%@", first ? "" : ",", index];
                first = NO;
            }
        }
        [out appendString:@"]"];
        for (NSString *name in menu_target.dynamicOrder) {
            NSArray<NSString *> *lines = menu_target.dynamicLines[name];
            [out appendString:@","];
            json_string(out, name);
            [out appendString:@":["];
            for (i = 0; i < lines.count; i++) {
                if (i > 0)
                    [out appendString:@","];
                json_string(out, lines[i]);
            }
            [out appendString:@"]"];
        }
        [out appendString:@"}"];
        return strdup([out UTF8String]);
    }
}

/* The menu bar as it was before, and nothing of the editor's kept. */
void clamacs_host_menu_clear(void)
{
    @autoreleasepool {
        if (menu_target) {
            NSApp.mainMenu = menu_target.previous;
            NSApp.helpMenu = nil;
            menu_target = nil;
        }
    }
}

#elif defined(CLAMACS_HOST_GTK)
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

/* ---- the event loop ------------------------------------------------- */

static gboolean step_timeout(gpointer arg)
{
    *(int *)arg = 1;
    return G_SOURCE_REMOVE;
}

/* One blocking iteration of the default main context, ended by the first
 * event or by a timeout of MS, then everything already pending without
 * waiting (capped, so a source that re-arms itself cannot keep Lisp out).
 * webview's dispatch is a g_idle_add on this context and the bindings'
 * callbacks come through WebKit's script message handler on it, so both
 * run inside the step.  Returns the number of iterations that dispatched
 * something. */
int clamacs_host_step(void *w, int ms)
{
    GMainContext *ctx = g_main_context_default();
    int fired = 0, n = 0, cap = 200;
    guint id;
    (void)w;
    id = g_timeout_add(ms > 0 ? (guint)ms : 0, step_timeout, &fired);
    if (g_main_context_iteration(ctx, TRUE))
        n++;
    while (cap-- > 0 && g_main_context_pending(ctx)) {
        if (g_main_context_iteration(ctx, FALSE))
            n++;
    }
    if (!fired)
        g_source_remove(id);
    return n;
}

/* From any thread: end the step in progress. */
void clamacs_host_wake(void)
{
    g_main_context_wakeup(g_main_context_default());
}

/* ---- string arguments ------------------------------------------------ */

/* Text is Latin-1 and GTK takes UTF-8: converted, g_free'd by the caller.
 * A path is the file system's bytes and goes through as it is. */
static char *text_arg(const char *s)
{
    return g_convert(s ? s : "", -1, "UTF-8", "ISO-8859-1", NULL, NULL, NULL);
}

/* ---- requesters ----------------------------------------------------- */

int clamacs_host_ask(void *win, const char *text, const char *buttons)
{
    char *message = text_arg(text);
    char *list = text_arg(buttons ? buttons : "OK");
    GtkWidget *dialog;
    gchar **names;
    int i, count = 0, cancel = -1, answer;
    gint r;

    if (message == NULL || list == NULL) {
        g_free(message);
        g_free(list);
        return -1;
    }
    dialog = gtk_message_dialog_new(win ? GTK_WINDOW(win) : NULL,
                                    GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                    GTK_MESSAGE_QUESTION, GTK_BUTTONS_NONE,
                                    "%s", message);
    /* The response ids are the button indices shifted by one: GTK keeps
     * the non-positive values for itself (Escape and the close button
     * answer GTK_RESPONSE_DELETE_EVENT). */
    names = g_strsplit(list, "|", -1);
    for (i = 0; names[i] != NULL; i++) {
        gtk_dialog_add_button(GTK_DIALOG(dialog), names[i], i + 1);
        if (strcmp(names[i], "Cancel") == 0)
            cancel = i;
        count++;
    }
    r = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    answer = (r >= 1 && r <= count) ? (int)(r - 1) : cancel;
    g_strfreev(names);
    g_free(message);
    g_free(list);
    return answer;
}

char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)
{
    char *message = text_arg(title);
    GtkWidget *dialog;
    GtkFileChooser *chooser;
    char *result = NULL;

    dialog = gtk_file_chooser_dialog_new(message,
                                         win ? GTK_WINDOW(win) : NULL,
                                         save ? GTK_FILE_CHOOSER_ACTION_SAVE
                                              : GTK_FILE_CHOOSER_ACTION_OPEN,
                                         "_Cancel", GTK_RESPONSE_CANCEL,
                                         save ? "_Save" : "_Open", GTK_RESPONSE_ACCEPT,
                                         NULL);
    g_free(message);
    chooser = GTK_FILE_CHOOSER(dialog);
    if (save)
        gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
    if (initial && *initial) {
        if (g_file_test(initial, G_FILE_TEST_IS_DIR)) {
            gtk_file_chooser_set_current_folder(chooser, initial);
        } else {
            gchar *parent = g_path_get_dirname(initial);
            gchar *base = g_path_get_basename(initial);
            if (parent && strcmp(parent, ".") != 0)
                gtk_file_chooser_set_current_folder(chooser, parent);
            if (save)
                gtk_file_chooser_set_current_name(chooser, base);
            else if (g_file_test(initial, G_FILE_TEST_EXISTS))
                gtk_file_chooser_set_filename(chooser, initial);
            g_free(parent);
            g_free(base);
        }
    }
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        gchar *chosen = gtk_file_chooser_get_filename(chooser);
        if (chosen) {
            result = strdup(chosen);
            g_free(chosen);
        }
    }
    gtk_widget_destroy(dialog);
    return result;
}

void clamacs_host_free(void *p)
{
    free(p);
}

/* ---- small services -------------------------------------------------- */

void clamacs_host_beep(void)
{
    GdkDisplay *display = gdk_display_get_default();
    if (display)
        gdk_display_beep(display);
}

int clamacs_host_clipboard_set(const char *text)
{
    char *s = text_arg(text);
    if (s == NULL)
        return 0;
    gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), s, -1);
    g_free(s);
    return 1;
}

int clamacs_host_open_url(const char *url)
{
    char *s = text_arg(url);
    GError *error = NULL;
    gboolean ok;
    if (s == NULL)
        return 0;
    ok = gtk_show_uri_on_window(NULL, s, GDK_CURRENT_TIME, &error);
    if (error)
        g_error_free(error);
    g_free(s);
    return ok ? 1 : 0;
}

/* ---- the window ------------------------------------------------------ */

/* GTK's frame is top-left already.  Under Wayland the position is what
 * the compositor allows: (0, 0) from get, and a move is ignored. */
void clamacs_host_get_frame(void *win, int32_t out[4])
{
    gint x = 0, y = 0, width = 0, height = 0;
    gtk_window_get_position(GTK_WINDOW(win), &x, &y);
    gtk_window_get_size(GTK_WINDOW(win), &width, &height);
    out[0] = x;
    out[1] = y;
    out[2] = width;
    out[3] = height;
}

void clamacs_host_set_frame(void *win, int left, int top, int width, int height)
{
    gtk_window_move(GTK_WINDOW(win), left, top);
    gtk_window_resize(GTK_WINDOW(win), width, height);
}

/* The close button asks the editor: the delete-event handler runs FN(ARG)
 * and answers TRUE, so the window stays and webview's own "destroy"
 * handler never runs; the loop ends the window when the editor is done.
 * The hook is kept on the window (object data, freed with it): one per
 * window. */
struct close_hook {
    void (*fn)(void *);
    void *arg;
};

static gboolean on_delete(GtkWidget *widget, GdkEvent *event, gpointer arg)
{
    struct close_hook *hook = g_object_get_data(G_OBJECT(widget), "clamacs-close");
    (void)event; (void)arg;
    if (hook && hook->fn) {
        hook->fn(hook->arg);
        return TRUE;
    }
    return FALSE;
}

void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)
{
    struct close_hook *hook = g_object_get_data(G_OBJECT(win), "clamacs-close");
    if (hook == NULL) {
        hook = g_new0(struct close_hook, 1);
        g_object_set_data_full(G_OBJECT(win), "clamacs-close", hook, g_free);
        g_signal_connect(G_OBJECT(win), "delete-event", G_CALLBACK(on_delete), NULL);
    }
    hook->fn = fn;
    hook->arg = arg;
}

void clamacs_host_raise(void *win)
{
    gtk_window_present(GTK_WINDOW(win));
}

const char *clamacs_host_toolkit(void)
{
    static char line[160];
    if (line[0] == 0) {
        gchar *os = g_get_os_info(G_OS_INFO_KEY_PRETTY_NAME);
        snprintf(line, sizeof line, "GTK %u.%u.%u / WebKitGTK %u.%u.%u on %s",
                 gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version(),
                 webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version(),
                 os ? os : "Linux");
        g_free(os);
    }
    return line;
}

/* No menu bar of the host's here: the page draws the editor's. */
int clamacs_host_menu_set(void *win, const char *table,
                          void (*fn)(int32_t, int32_t, void *), void *arg)
{ (void)win; (void)table; (void)fn; (void)arg; return 0; }
void clamacs_host_menu_enable(int index, int flag) { (void)index; (void)flag; }
void clamacs_host_menu_dynamic(const char *which, const char *lines) { (void)which; (void)lines; }
char *clamacs_host_menu_report(void) { return NULL; }
int clamacs_host_menu_click(int which, int n) { (void)which; (void)n; return 0; }
void clamacs_host_menu_clear(void) {}

#elif defined(_WIN32)
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>

/* ---- the event loop ------------------------------------------------- */

/* The thread the window belongs to, for the wake: the first step records
 * it (host-open steps before anything else could wake). */
static DWORD loop_thread;

/* Wait up to MS for the first message, then deliver everything queued
 * without waiting.  webview's dispatch posts to its message-only window
 * and WebView2's callbacks come as messages too, so both run inside the
 * step. */
int clamacs_host_step(void *w, int ms)
{
    MSG msg;
    int n = 0;
    (void)w;
    if (loop_thread == 0)
        loop_thread = GetCurrentThreadId();
    MsgWaitForMultipleObjectsEx(0, NULL, ms > 0 ? (DWORD)ms : 0, QS_ALLINPUT,
                                MWMO_INPUTAVAILABLE | MWMO_ALERTABLE);
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT)
            break;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        n++;
    }
    return n;
}

/* From any thread: a message with nothing in it ends the wait. */
void clamacs_host_wake(void)
{
    if (loop_thread)
        PostThreadMessageW(loop_thread, WM_NULL, 0, 0);
}

/* ---- string arguments ------------------------------------------------ */

/* Text is Latin-1: each byte is the code point, so the widening is a copy.
 * A path is UTF-8 (what clamiga's Windows platform layer hands out).
 * Both malloc'd; the caller frees. */
static wchar_t *text_arg(const char *s)
{
    size_t n = s ? strlen(s) : 0, i;
    wchar_t *out = (wchar_t *)malloc((n + 1) * sizeof(wchar_t));
    if (out == NULL)
        return NULL;
    for (i = 0; i < n; i++)
        out[i] = (wchar_t)(unsigned char)s[i];
    out[n] = 0;
    return out;
}

static wchar_t *path_arg(const char *s)
{
    int n;
    wchar_t *out;
    if (s == NULL)
        return NULL;
    n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0)
        return NULL;
    out = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (out && MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

static char *path_result(const wchar_t *w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *out;
    if (n <= 0)
        return NULL;
    out = (char *)malloc((size_t)n);
    if (out && WideCharToMultiByte(CP_UTF8, 0, w, -1, out, n, NULL, NULL) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

/* ---- requesters ----------------------------------------------------- */

/* MessageBox has fixed button sets, so the names of BUTTONS pick the set
 * by their count -- one: OK; two: OK / Cancel; three: Yes / No / Cancel --
 * and the message lists them, so "Save|Discard|Cancel" reads
 * "Yes = Save, No = Discard".  The answer is the index into BUTTONS;
 * Escape answers the Cancel button's index, or -1 without one. */
int clamacs_host_ask(void *win, const char *text, const char *buttons)
{
    char message[1024];
    const char *list = buttons ? buttons : "OK";
    char names[3][64];
    int count = 0, cancel = -1;
    const char *p = list;
    wchar_t *wtext, *wtitle;
    UINT type;
    int r, answer = -1;

    while (count < 3) {
        const char *bar = strchr(p, '|');
        size_t len = bar ? (size_t)(bar - p) : strlen(p);
        if (len >= sizeof names[0])
            len = sizeof names[0] - 1;
        memcpy(names[count], p, len);
        names[count][len] = 0;
        if (strcmp(names[count], "Cancel") == 0)
            cancel = count;
        count++;
        if (bar == NULL)
            break;
        p = bar + 1;
    }
    if (count == 3)
        snprintf(message, sizeof message, "%s\n\nYes = %s, No = %s",
                 text ? text : "", names[0], names[1]);
    else if (count == 2)
        snprintf(message, sizeof message, "%s\n\nOK = %s, Cancel = %s",
                 text ? text : "", names[0], names[1]);
    else
        snprintf(message, sizeof message, "%s", text ? text : "");
    type = (count == 3 ? MB_YESNOCANCEL : count == 2 ? MB_OKCANCEL : MB_OK)
           | MB_ICONQUESTION | MB_TASKMODAL;
    wtext = text_arg(message);
    wtitle = text_arg("Clamacs");
    if (wtext == NULL || wtitle == NULL) {
        free(wtext);
        free(wtitle);
        return -1;
    }
    r = MessageBoxW((HWND)win, wtext, wtitle, type);
    free(wtext);
    free(wtitle);
    switch (r) {
    case IDOK: case IDYES: answer = 0; break;
    case IDNO: answer = 1; break;
    case IDCANCEL: answer = (count == 3) ? 2 : (count == 2 ? 1 : cancel); break;
    default: answer = cancel; break;
    }
    return answer;
}

char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)
{
    OPENFILENAMEW ofn;
    wchar_t file[MAX_PATH];
    wchar_t *wtitle = text_arg(title ? title : "");
    wchar_t *winitial = (initial && *initial) ? path_arg(initial) : NULL;
    wchar_t *dir = NULL;
    BOOL ok;
    char *result = NULL;

    file[0] = 0;
    if (winitial) {
        DWORD attr = GetFileAttributesW(winitial);
        if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) {
            dir = winitial;
            winitial = NULL;
        } else {
            wchar_t *slash = wcsrchr(winitial, L'/');
            wchar_t *bslash = wcsrchr(winitial, L'\\');
            if (bslash > slash)
                slash = bslash;
            if (slash) {
                wcsncpy(file, slash + 1, MAX_PATH - 1);
                file[MAX_PATH - 1] = 0;
                *slash = 0;
                dir = winitial;
                winitial = NULL;
            } else {
                wcsncpy(file, winitial, MAX_PATH - 1);
                file[MAX_PATH - 1] = 0;
            }
        }
    }
    memset(&ofn, 0, sizeof ofn);
    ofn.lStructSize = sizeof ofn;
    ofn.hwndOwner = (HWND)win;
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrTitle = wtitle;
    ofn.lpstrInitialDir = dir;
    ofn.Flags = OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_PATHMUSTEXIST
                | (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
    if (ok) {
        /* The editor's paths use forward slashes (clamiga's platform layer
         * normalises to them). */
        wchar_t *q;
        for (q = file; *q; q++)
            if (*q == L'\\')
                *q = L'/';
        result = path_result(file);
    }
    free(wtitle);
    free(winitial);
    free(dir);
    return result;
}

void clamacs_host_free(void *p)
{
    free(p);
}

/* ---- small services -------------------------------------------------- */

void clamacs_host_beep(void)
{
    MessageBeep(MB_OK);
}

int clamacs_host_clipboard_set(const char *text)
{
    wchar_t *w = text_arg(text ? text : "");
    size_t bytes;
    HGLOBAL mem;
    void *dst;
    if (w == NULL)
        return 0;
    bytes = (wcslen(w) + 1) * sizeof(wchar_t);
    mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (mem == NULL) {
        free(w);
        return 0;
    }
    dst = GlobalLock(mem);
    memcpy(dst, w, bytes);
    GlobalUnlock(mem);
    free(w);
    if (!OpenClipboard(NULL)) {
        GlobalFree(mem);
        return 0;
    }
    EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, mem) == NULL) {
        GlobalFree(mem);
        CloseClipboard();
        return 0;
    }
    CloseClipboard();
    return 1;
}

int clamacs_host_open_url(const char *url)
{
    wchar_t *w = text_arg(url ? url : "");
    HINSTANCE r;
    if (w == NULL)
        return 0;
    r = ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
    free(w);
    return ((INT_PTR)r > 32) ? 1 : 0;
}

/* ---- the window ------------------------------------------------------ */

void clamacs_host_get_frame(void *win, int32_t out[4])
{
    RECT r;
    if (GetWindowRect((HWND)win, &r)) {
        out[0] = r.left;
        out[1] = r.top;
        out[2] = r.right - r.left;
        out[3] = r.bottom - r.top;
    } else {
        out[0] = out[1] = out[2] = out[3] = 0;
    }
}

void clamacs_host_set_frame(void *win, int left, int top, int width, int height)
{
    MoveWindow((HWND)win, left, top, width, height, TRUE);
}

/* The close button asks the editor: the window procedure is wrapped, WM_CLOSE
 * runs FN(ARG) and is swallowed (webview's own procedure would destroy the
 * window); everything else goes to webview's.  The hook and the previous
 * procedure are kept on the window (a property), one per window, and
 * freed with it. */
struct close_hook {
    WNDPROC previous;
    void (*fn)(void *);
    void *arg;
};

static LRESULT CALLBACK close_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    struct close_hook *hook = (struct close_hook *)GetPropW(hwnd, L"ClamacsClose");
    WNDPROC previous;
    if (hook == NULL)
        return DefWindowProcW(hwnd, msg, wp, lp);
    if (msg == WM_CLOSE && hook->fn) {
        hook->fn(hook->arg);
        return 0;
    }
    previous = hook->previous;
    if (msg == WM_NCDESTROY) {
        RemovePropW(hwnd, L"ClamacsClose");
        free(hook);
    }
    return CallWindowProcW(previous, hwnd, msg, wp, lp);
}

void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)
{
    struct close_hook *hook = (struct close_hook *)GetPropW((HWND)win, L"ClamacsClose");
    if (hook == NULL) {
        hook = (struct close_hook *)calloc(1, sizeof *hook);
        if (hook == NULL)
            return;
        SetPropW((HWND)win, L"ClamacsClose", hook);
        hook->previous = (WNDPROC)SetWindowLongPtrW((HWND)win, GWLP_WNDPROC,
                                                    (LONG_PTR)close_wndproc);
    }
    hook->fn = fn;
    hook->arg = arg;
}

void clamacs_host_raise(void *win)
{
    ShowWindow((HWND)win, SW_SHOW);
    SetForegroundWindow((HWND)win);
}

/* RtlGetVersion tells the truth where GetVersionEx answers what the
 * manifest allows. */
typedef LONG (WINAPI *RtlGetVersion_t)(PRTL_OSVERSIONINFOW);

const char *clamacs_host_toolkit(void)
{
    static char line[96];
    if (line[0] == 0) {
        RTL_OSVERSIONINFOW v;
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        RtlGetVersion_t get = ntdll ? (RtlGetVersion_t)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
        memset(&v, 0, sizeof v);
        v.dwOSVersionInfoSize = sizeof v;
        if (get && get(&v) == 0)
            snprintf(line, sizeof line, "Win32/WebView2 on Windows %lu.%lu build %lu",
                     (unsigned long)v.dwMajorVersion, (unsigned long)v.dwMinorVersion,
                     (unsigned long)v.dwBuildNumber);
        else
            snprintf(line, sizeof line, "Win32/WebView2 on Windows");
    }
    return line;
}

/* No menu bar of the host's here: the page draws the editor's. */
int clamacs_host_menu_set(void *win, const char *table,
                          void (*fn)(int32_t, int32_t, void *), void *arg)
{ (void)win; (void)table; (void)fn; (void)arg; return 0; }
void clamacs_host_menu_enable(int index, int flag) { (void)index; (void)flag; }
void clamacs_host_menu_dynamic(const char *which, const char *lines) { (void)which; (void)lines; }
char *clamacs_host_menu_report(void) { return NULL; }
int clamacs_host_menu_click(int which, int n) { (void)which; (void)n; return 0; }
void clamacs_host_menu_clear(void) {}

#else /* another host: every entry says "not available" */

int clamacs_host_step(void *w, int ms) { (void)w; (void)ms; return -1; }
void clamacs_host_wake(void) {}
int clamacs_host_ask(void *win, const char *text, const char *buttons)
{ (void)win; (void)text; (void)buttons; return -1; }
char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)
{ (void)win; (void)title; (void)save; (void)initial; return NULL; }
void clamacs_host_free(void *p) { free(p); }
void clamacs_host_beep(void) {}
int clamacs_host_clipboard_set(const char *text) { (void)text; return 0; }
int clamacs_host_open_url(const char *url) { (void)url; return 0; }
void clamacs_host_get_frame(void *win, int32_t out[4])
{ (void)win; out[0] = out[1] = out[2] = out[3] = 0; }
void clamacs_host_set_frame(void *win, int left, int top, int width, int height)
{ (void)win; (void)left; (void)top; (void)width; (void)height; }
void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)
{ (void)win; (void)fn; (void)arg; }
void clamacs_host_raise(void *win) { (void)win; }
const char *clamacs_host_toolkit(void) { return "no native shim on this host"; }
int clamacs_host_menu_set(void *win, const char *table,
                          void (*fn)(int32_t, int32_t, void *), void *arg)
{ (void)win; (void)table; (void)fn; (void)arg; return 0; }
void clamacs_host_menu_enable(int index, int flag) { (void)index; (void)flag; }
void clamacs_host_menu_dynamic(const char *which, const char *lines) { (void)which; (void)lines; }
char *clamacs_host_menu_report(void) { return NULL; }
int clamacs_host_menu_click(int which, int n) { (void)which; (void)n; return 0; }
void clamacs_host_menu_clear(void) {}

#endif
