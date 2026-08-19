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

# EMACS is exported so that the recipes below and the gate script both see
# whatever the caller set.  Exporting an undefined make variable exports it
# empty, which the `:-' in each recipe treats as "not set".
export EMACS

# A shell command that prints a usable Emacs.  Deliberately a plain string
# rather than a `$(shell ...)' assignment: stat-ing the nix store costs a
# few seconds, and only the targets that actually run Emacs should pay it.
# `locate-library' rather than `(require ...)' because it does not load
# anything -- the gate script keeps the slower, stricter probe, which is the
# one it was verified with.
FIND_EMACS = for c in /nix/store/*emacs-mac-macport-with-packages-*/bin/emacs; do [ -x "$$c" ] && "$$c" -batch --eval '(unless (locate-library "org-ql") (kill-emacs 1))' >/dev/null 2>&1 && { printf '%s\n' "$$c"; break; }; done

# Every Emacs-running recipe begins with this.  It leaves the interpreter in
# $$emacs and fails with one clear line if there is none.
EMACS_OR_DIE = emacs=$${EMACS:-$$($(FIND_EMACS))}; emacs=$${emacs:-emacs}; \
	command -v "$$emacs" >/dev/null 2>&1 || \
	  { echo "no usable Emacs found; run again with EMACS=/path/to/emacs" >&2; exit 1; };

.PHONY: help test test-one gate check clean

help:
	@echo 'org-agents targets (DEPS_DIR=$(DEPS_DIR))'
	@echo
	@echo '  make test       the ERT suite.  The soundness tests SKIP'
	@echo '                  where ripgrep is not on PATH; everything'
	@echo '                  else, patterns included, always runs'
	@echo '  make test-one T=REGEXP   the tests whose names match REGEXP'
	@echo '  make gate       byte-compile, and fail on any warning at all'
	@echo '  make check      gate, then test'
	@echo '  make clean      remove byte-compiled output'
	@echo
	@echo 'Overrides: EMACS=/path/to/emacs  DEPS_DIR=/dir/holding/org-ql-ext.el'

# `ert-run-tests-batch-and-exit' exits nonzero on any unexpected result, so
# this target is usable as a gate.  A test marked `:expected-result :failed'
# counts as a pass when it fails, and a skipped test counts as neither.
#
# The soundness suite needs ripgrep, and `skip-unless' is honest but
# silent -- silence is what let the suite this one replaces rot unrun for
# want of a database.  So say it once, loudly, where ripgrep is missing.
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

check: gate test

clean:
	rm -f $(ROOT)/*.elc
	rm -rf $(ROOT)/eln-cache
