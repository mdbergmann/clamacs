# Clamacs Makefile -- host unit tests for the portable C core.
#
# The editor itself is cross-compiled (Makefile.cross for AmigaOS 3,
# Makefile.mos for MorphOS).  What builds HERE is the half of clamacs that
# takes no MUI and no OS types -- the keymap engine, the command table, the
# kill ring, the Lisp tokenizer, the sexp scanner, the indenter, the
# diagnostic parser and the ARexx request queue.  Keeping those free of
# Amiga headers is a design rule (specs/clamacs-ide.md, "Testing"), and this
# Makefile is what enforces it: anything that reaches for <proto/exec.h>
# stops compiling here.
#
#   make test        build and run the whole host suite (C and Lisp)
#   make test-keymap run one test binary
#   make test-lisp   the Lisp editor's pure modules (specs/clamacs-lisp.md)
#                    under ../build/host/clamiga; CLAMACS_TEST=keymap for one
#   make test-lisp-gc-stress  the same, a compaction at every allocation
#                    (needs the superproject's `make test-gc-stress' binary)
#   make amiga       cross-compile the editor (delegates to Makefile.cross)
#
# The host frontend (specs/clamacs-host.md; host/ and verify/host/):
#
#   make host        build/host-frontend/: the page, webview and the shim
#   make host-image  ... plus clamacs.img, the editor's heap image, verified
#   make host-app    ... plus Clamacs.app, the macOS bundle
#   make host-check  the smoke run, the key run and the drive (needs a window
#                    server); host-check-image and host-check-app the drive
#                    from the image and through the bundle
#   make host-linux  the smoke run and the drive on Linux, in a container

CC_HOST     ?= cc
CFLAGS_HOST  = -std=c99 -Wall -Wextra -Wpedantic -g -O1 -Isrc

BUILDDIR = build/host
SRCDIR   = src

# The portable core.  Every test binary links all of it: the modules are
# small and independent, and one link line beats a per-test dependency list
# that would go stale.
CORE_SRC = $(SRCDIR)/emacs/keymap.c \
           $(SRCDIR)/emacs/rawkey.c \
           $(SRCDIR)/emacs/command.c \
           $(SRCDIR)/emacs/bindings.c \
           $(SRCDIR)/emacs/killring.c \
           $(SRCDIR)/emacs/minihist.c \
           $(SRCDIR)/emacs/locstack.c \
           $(SRCDIR)/emacs/menudef.c \
           $(SRCDIR)/emacs/winstore.c \
           $(SRCDIR)/lisp/token.c \
           $(SRCDIR)/lisp/sexp.c \
           $(SRCDIR)/lisp/indent.c \
           $(SRCDIR)/rexx/diag.c \
           $(SRCDIR)/rexx/queue.c \
           $(SRCDIR)/rexx/symcache.c \
           $(SRCDIR)/rexx/replmsg.c \
           $(SRCDIR)/rexx/dbgmsg.c

CORE_OBJ = $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(CORE_SRC))

TESTS = keymap rawkey command bindings killring minihist locstack menudef winstore token sexp indent diag queue symcache replmsg dbgmsg

TEST_BINS = $(patsubst %,$(BUILDDIR)/test_%,$(TESTS))

# The Lisp editor's tests run under the SUPERPROJECT's host build.
CLAMIGA_HOST     ?= ../build/host/clamiga
CLAMIGA_GCSTRESS ?= ../build/host-gcstress/clamiga

.PHONY: all test test-lisp test-lisp-gc-stress clean amiga mos install-hooks $(patsubst %,test-%,$(TESTS)) \
        host host-image host-app host-check host-check-image host-check-app host-linux

# Without this, make treats the core objects as intermediates of the pattern
# rule that builds a test binary and deletes them after every run, so each
# `make test-x' rebuilds the whole core.
.SECONDARY: $(CORE_OBJ)

all: $(TEST_BINS)

test: $(TEST_BINS)
	@fail=0; \
	echo "=== tests/check-commands.sh ==="; \
	tests/check-commands.sh || fail=1; \
	for t in $(TEST_BINS); do \
	    echo "=== $$t ==="; \
	    $$t || fail=1; \
	done; \
	echo "=== tests/run-lisp-tests.sh ==="; \
	tests/run-lisp-tests.sh $(CLAMIGA_HOST) || fail=1; \
	if [ $$fail -ne 0 ]; then echo "=== SOME TESTS FAILED ==="; exit 1; fi; \
	echo "=== ALL TESTS PASSED ==="

test-lisp:
	@tests/run-lisp-tests.sh $(CLAMIGA_HOST)

test-lisp-gc-stress:
	@CLAMIGA_GC_STRESS=1 tests/run-lisp-tests.sh $(CLAMIGA_GCSTRESS)

$(patsubst %,test-%,$(TESTS)): test-%: $(BUILDDIR)/test_%
	$<

$(BUILDDIR)/test_%: tests/test_%.c $(CORE_OBJ)
	@mkdir -p $(dir $@)
	$(CC_HOST) $(CFLAGS_HOST) -Itests -o $@ $< $(CORE_OBJ)

$(BUILDDIR)/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC_HOST) $(CFLAGS_HOST) -MMD -MP -c -o $@ $<

-include $(CORE_OBJ:.o=.d)

amiga:
	$(MAKE) -f Makefile.cross amiga

mos:
	$(MAKE) -f Makefile.mos mos

host:
	host/build.sh

host-image:
	host/make-image.sh

host-app:
	host/make-app.sh

host-check:
	verify/host/run-smoke.sh && verify/host/host-keys.sh && verify/host/run-drive.sh

host-check-image:
	IMAGE=1 verify/host/run-drive.sh

host-check-app:
	APP=1 verify/host/run-drive.sh

host-linux:
	verify/host/run-linux.sh

clean:
	rm -rf build/host

# Activate the auto-review git hook for this clone.  Sets a RELATIVE
# core.hooksPath (local to the clone, survives a repo move), so the tracked
# githooks/pre-commit runs and delegates to scripts/review/pre-commit.sh.
# Run once after cloning.  See scripts/review/README.md.
install-hooks:
	@git config core.hooksPath githooks
	@chmod +x githooks/* scripts/review/*.sh 2>/dev/null || true
	@echo "=> auto-review hook activated (core.hooksPath=githooks)"
	@echo "   bypass one commit with 'git commit --no-verify'; disable with CLAUDE_AUTO_REVIEW=0"
