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
#   make test        build and run the whole host suite
#   make test-keymap run one test binary
#   make amiga       cross-compile the editor (delegates to Makefile.cross)

CC_HOST     ?= cc
CFLAGS_HOST  = -std=c99 -Wall -Wextra -Wpedantic -g -O1 -Isrc

BUILDDIR = build/host
SRCDIR   = src

# The portable core.  Every test binary links all of it: the modules are
# small and independent, and one link line beats a per-test dependency list
# that would go stale.
CORE_SRC = $(SRCDIR)/emacs/keymap.c \
           $(SRCDIR)/emacs/command.c \
           $(SRCDIR)/emacs/bindings.c \
           $(SRCDIR)/emacs/killring.c \
           $(SRCDIR)/emacs/minihist.c \
           $(SRCDIR)/lisp/token.c \
           $(SRCDIR)/lisp/sexp.c \
           $(SRCDIR)/lisp/indent.c \
           $(SRCDIR)/rexx/diag.c \
           $(SRCDIR)/rexx/queue.c

CORE_OBJ = $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(CORE_SRC))

TESTS = keymap command bindings killring minihist token sexp indent diag queue

TEST_BINS = $(patsubst %,$(BUILDDIR)/test_%,$(TESTS))

.PHONY: all test clean amiga mos $(patsubst %,test-%,$(TESTS))

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
	if [ $$fail -ne 0 ]; then echo "=== SOME TESTS FAILED ==="; exit 1; fi; \
	echo "=== ALL TESTS PASSED ==="

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

clean:
	rm -rf build/host
