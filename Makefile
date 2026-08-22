# Makefile --- development targets for org-agents
#
# There is no `emacs' on PATH on the machine this package was written on:
# the interpreter comes out of the nix store.  Every target that needs one
# therefore looks for it, or takes EMACS from the environment or the
# command line (`make test EMACS=/path/to/emacs').  Never point EMACS at an
# Emacs invoked with -Q: org-ql lives in site-lisp, which -Q suppresses.
#
# org-agents.el requires `org-ql-ext', which requires `org-ext'.  Neither is
# part of this repository -- both are single-file modules from the author's
# Emacs configuration -- so every target says where they are.  DEPS_DIR
# defaults to this repository's PARENT directory, which is where they sit
# when this repository is checked out inside `dot-emacs/lisp' as it is on
# the author's machine.  Elsewhere:
#
#   make test DEPS_DIR=/path/to/dot-emacs/lisp

ROOT     := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))
DEPS_DIR ?= $(realpath $(ROOT)/..)

LOAD     := -L . -L "$(DEPS_DIR)"

LOADTESTS := -l org-agents-test.el

# The manual.  `doc/' is the Emacs and Org convention for a shipped manual
# and is where `install-info' expects to find one.  The working notes live
# there too, so mind which file you are editing: org-agents.org is the
# manual, and doc-setup.org is the export header it needs.
DOC      := $(ROOT)/doc
MANUAL   := $(DOC)/org-agents.org
TEXI     := $(DOC)/org-agents.texi
INFO     := $(DOC)/org-agents.info

# EMACS is exported so that the recipes below and the gate script both see
# whatever the caller set.  Exporting an undefined make variable exports it
# empty, which the `:-' in each recipe treats as "not set".
export EMACS

# A shell command that prints a usable Emacs.  Deliberately a plain string
# rather than a `$(shell ...)' assignment: stat-ing the nix store costs a
# few seconds, and only the targets that actually run Emacs should pay it.
# `locate-library' rather than `(require ...)' because it does not load
# anything.  ONE OF A PAIR: tools/org-agents-byte-compile-gate.sh searches
# the same glob and keeps the slower, stricter `require' probe it was
# verified with.  Change one and look at the other.
FIND_EMACS = for c in /nix/store/*emacs-mac-macport-with-packages-*/bin/emacs; do [ -x "$$c" ] && "$$c" -batch --eval '(unless (locate-library "org-ql") (kill-emacs 1))' >/dev/null 2>&1 && { printf '%s\n' "$$c"; break; }; done

# Every Emacs-running recipe begins with this.  It leaves the interpreter in
# $$emacs and fails with one clear line if there is none.
#
# The command substitution is a statement of its own, NOT spelled
# `$${EMACS:-$$(...)}'.  macOS's /bin/sh is bash 3.2.57, which cannot parse a
# `$(...)' holding a `for ... done' inside a `$${var:-...}' expansion, and
# fails with "syntax error near unexpected token `done'" before Emacs runs --
# even when EMACS is set on the command line, because the expansion is parsed
# either way.  Reproduced: GNU Make defaults SHELL to /bin/sh, so `make test'
# died for anyone whose PATH does not supply a newer bash.  Keep the two steps
# separate, and skip the search entirely when EMACS is already set.
EMACS_OR_DIE = emacs="$$EMACS"; \
	[ -n "$$emacs" ] || emacs=$$($(FIND_EMACS)); \
	emacs=$${emacs:-emacs}; \
	command -v "$$emacs" >/dev/null 2>&1 || \
	  { echo "no usable Emacs found; run again with EMACS=/path/to/emacs" >&2; exit 1; };

.PHONY: help test test-one gate check clean manual manual-clean

help:
	@echo 'org-agents targets (DEPS_DIR=$(DEPS_DIR))'
	@echo
	@echo '  make test       the ERT suite.  The soundness tests SKIP'
	@echo '                  where ripgrep is not on PATH; everything'
	@echo '                  else, patterns included, always runs'
	@echo '  make test-one T=REGEXP   the tests whose names match REGEXP'
	@echo '  make gate       byte-compile, and fail on any warning at all'
	@echo '  make manual     export doc/org-agents.org to .texi and .info.'
	@echo '                  Fails on any makeinfo warning: a manual that'
	@echo '                  does not build clean is a manual nobody reads'
	@echo '  make check      gate, manual, then test'
	@echo '  make clean      remove byte-compiled output'
	@echo '  make manual-clean   remove the Texinfo intermediate'
	@echo
	@echo 'Overrides: EMACS=/path/to/emacs  DEPS_DIR=/dir/holding/org-ql-ext.el'

# `ert-run-tests-batch-and-exit' exits nonzero on any unexpected result, so
# this target is usable as a gate.  A test marked `:expected-result :failed'
# counts as a pass when it fails, and a skipped test counts as neither.
#
# The soundness suite needs ripgrep, and `skip-unless' is honest but
# silent.  A silent skip is how a suite rots unrun, so say it once,
# loudly, where ripgrep is missing.
test:
	@command -v rg >/dev/null 2>&1 || \
	  echo "org-agents: no ripgrep on PATH; the soundness tests will SKIP" >&2
	@cd $(ROOT) || exit 1; $(EMACS_OR_DIE) \
	  "$$emacs" -batch $(LOAD) $(LOADTESTS) \
	    --eval '(ert-run-tests-batch-and-exit)'

test-one:
	@test -n "$(T)" || { echo 'usage: make test-one T=REGEXP' >&2; exit 1; }
	@cd $(ROOT) || exit 1; $(EMACS_OR_DIE) \
	  "$$emacs" -batch $(LOAD) $(LOADTESTS) \
	    --eval '(ert-run-tests-batch-and-exit "$(T)")'

# The gate finds its own Emacs and takes the dependency directory from
# ORG_AGENTS_DEPS_DIR, so DEPS_DIR is passed through under that name.
gate:
	@ORG_AGENTS_DEPS_DIR="$(DEPS_DIR)" $(ROOT)/tools/org-agents-byte-compile-gate.sh

# The export needs no LOAD: `ox-texinfo' and Org come out of site-lisp,
# which is exactly why EMACS must never be an Emacs started with -Q.  Two
# explicit steps rather than `org-texinfo-export-to-info', which shells out
# to makeinfo from inside Emacs and buries its diagnostics.
#
# `makeinfo' warns on stderr and still exits 0, so its output is captured
# and a non-empty capture is the failure.  Otherwise a dangling @ref ships.
# Do NOT add --no-warn: making the warnings reach `make' is the whole point
# of the separate step.
#
# The export runs with `doc' as the working directory, because the manual's
# `#+setupfile:' and its `version' macro -- which reads the `;; Version:'
# line out of org-agents.el, so the manual cannot drift from the package --
# are both resolved relative to the Org file's own directory.  That version
# line is why org-agents.el is a real prerequisite here and not a courtesy.
manual: $(INFO)

$(TEXI): $(MANUAL) $(DOC)/doc-setup.org $(ROOT)/org-agents.el
	@cd $(DOC) || exit 1; $(EMACS_OR_DIE) \
	  "$$emacs" -batch \
	    --eval '(require (quote ox-texinfo))' \
	    --eval '(setq gc-cons-threshold (* 50 1000 1000))' \
	    --eval '(find-file "org-agents.org")' \
	    --eval '(org-texinfo-export-to-texinfo)'

$(INFO): $(TEXI)
	@out=$$(makeinfo --no-split "$(TEXI)" -o "$(INFO)" 2>&1); \
	  status=$$?; \
	  [ -z "$$out" ] || printf '%s\n' "$$out" >&2; \
	  [ $$status -eq 0 ] && [ -z "$$out" ] || \
	    { echo "org-agents: the manual did not build clean" >&2; exit 1; }

check: gate manual test

clean:
	rm -f $(ROOT)/*.elc
	rm -rf $(ROOT)/eln-cache

# Only the intermediate.  Neither it nor the .info is tracked -- see
# .gitignore -- so `make manual' is what produces a readable manual, and
# this target exists to clear the Texinfo step without clearing that.
manual-clean:
	rm -f $(TEXI)
