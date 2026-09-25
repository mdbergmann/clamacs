/* clamacs-host.m -- the native shim of the host frontend (specs/clamacs-host.md).
 *
 * What a page cannot do and the webview C API does not offer: one turn
 * of the event loop (the editor's run-loop steps it, so the main thread
 * reaches a GC safepoint every few milliseconds instead of parking in
 * webview_run), a wake from another thread, the requesters, the file
 * panels, the beep, the clipboard, the URL opener, the window's frame and
 * its close button.  Built into libclamacs-host.dylib by host/build.sh and
 * called through ffi:call-foreign; every entry is plain C.
 *
 * macOS (Cocoa) today.  The GTK and Win32 bodies go behind #ifdef here
 * when those hosts are taken up; until then every entry has a "not
 * available" return so the editor runs without them.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#import <Cocoa/Cocoa.h>

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
 * runs (save-buffers-kill-emacs, a Lisp callback) and the window stays;
 * the loop ends it when the editor is done.  Everything else the window
 * asks its delegate is forwarded to webview's own. */
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

static ClamacsWindowDelegate *close_delegate;

void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)
{
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        if (close_delegate == nil) {
            close_delegate = [[ClamacsWindowDelegate alloc] init];
            close_delegate.inner = window.delegate;
            window.delegate = close_delegate;
        }
        close_delegate.fn = fn;
        close_delegate.arg = arg;
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

#else /* not __APPLE__: every entry says "not available" */

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
const char *clamacs_host_toolkit(void) { return "no native shim on this host"; }

#endif
