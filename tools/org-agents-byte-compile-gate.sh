#!/bin/sh
# org-agents-byte-compile-gate.sh --- assert a warning-free byte-compile
#
# Compiles org-agents.el and fails unless the byte compiler reports ZERO
# warnings for it.  Run it from anywhere; it finds its own repository
# root.
#
# The two repo-local dependencies.  org-agents.el requires `org-ql-ext',
# which requires `org-ext'.  Neither is part of this repository -- both are
# single-file modules from the author's Emacs configuration -- so the gate
# has to be told where they live.  ORG_AGENTS_DEPS_DIR names that
# directory and defaults to the repository's PARENT, which is where they
# sit when this repository is checked out inside `dot-emacs/lisp' as it is
# on the author's machine.
#
# Why the dependencies are compiled first.  Where no .elc exists for them,
# `(require 'org-ql-ext)' loads that file -- and org-ext.el below it -- as
# SOURCE, which evaluates each one's `(eval-when-compile (require 'cl))'
# and reports "Package cl is deprecated" against OUR require line rather
# than theirs.  Where this code actually runs, both .elc exist and the
# warning never fires, so the gate builds them first to reproduce that
# environment.  Their own warnings are their own business and are NOT
# gated: neither file is warning-free, for reasons that have nothing to do
# with this package.
#
# Where those .elc are written.  Not beside the sources: the dependency
# directory belongs to somebody else -- by default it is the user's live
# Emacs configuration -- and a gate has no business leaving build output
# in it.  `byte-compile-dest-file-function' redirects them into a
# temporary directory instead, which is placed FIRST on the load path so
# that it is the copy `require' finds, and is removed on exit.
#
# The gated file IS compiled in place, and its .elc is removed first, so the
# pre-existing file does not survive the run -- an equivalent fresh one
# takes its place.  MEASURED, so that the reason given is the true one:
# `batch-byte-compile' does NOT skip a file whose .elc is newer, so the
# removal is not what forces a fresh compile.  What it buys is a
# deterministic starting state, which is worth the two lines in a script
# whose whole output is a warning count.
#
# What the bookkeeping below decides is only whether that fresh .elc is
# LEFT BEHIND: it is, exactly where the checkout already had one, so a
# passing gate does not strip a build someone else is relying on and does
# not leave build output in a checkout that had none.  Both of those were
# measured.
#
# ON A FAILING GATE the pre-existing .elc is gone and nothing replaces it,
# because the compile that would have rebuilt it is the thing that failed.
# That is a real gap and it is not worth closing here: a checkout whose
# gate fails wants a rebuild anyway, and saving the file aside to restore
# it would add a second failure mode to a script that exists to be simple.
#
# Usage:
#   tools/org-agents-byte-compile-gate.sh
#
#   EMACS=/path/to/emacs      the interpreter to use.  Without it, an
#                             Emacs that can `(require 'org-ql)' is
#                             searched for among the nix store's
#                             emacs-mac-macport builds, then plain
#                             `emacs' on PATH.  Do NOT point this at an
#                             Emacs invoked with -Q: org-ql lives in
#                             site-lisp, which -Q suppresses.
#   ORG_AGENTS_DEPS_DIR=DIR   where org-ext.el and org-ql-ext.el live.
#                             Defaults to the repository's parent
#                             directory.
set -eu

tools=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$tools/.." && pwd)
deps_dir=${ORG_AGENTS_DEPS_DIR-$(CDPATH= cd -- "$root/.." && pwd)}

# In order: org-ql-ext requires org-ext, so org-ext must be built first or
# it is loaded as source while the second is compiled.
deps='org-ext.el org-ql-ext.el'
gated='org-agents.el'

# ONE OF A PAIR.  The Makefile's FIND_EMACS searches the same glob for the
# same reason, and the two probes differ ON PURPOSE: that one uses
# `locate-library', which loads nothing and so costs a few seconds less,
# while this one keeps the stricter `(require 'org-ql)' it was verified
# with.  Change one and look at the other: they are allowed to differ, but
# only deliberately.
emacs=${EMACS-}
if [ -z "$emacs" ]; then
    for candidate in /nix/store/*emacs-mac-macport-with-packages-*/bin/emacs; do
        if [ -x "$candidate" ] &&
            "$candidate" -batch --eval "(require 'org-ql)" >/dev/null 2>&1
        then
            emacs=$candidate
            break
        fi
    done
fi
if [ -z "$emacs" ]; then
    emacs=emacs
fi
if ! command -v "$emacs" >/dev/null 2>&1; then
    echo "org-agents gate: no usable Emacs found; set EMACS" >&2
    exit 1
fi

for f in $deps; do
    if [ ! -r "$deps_dir/$f" ]; then
        echo "org-agents gate FAILED: $deps_dir/$f not found." >&2
        echo "  org-agents.el requires org-ql-ext, which requires org-ext." >&2
        echo "  Point ORG_AGENTS_DEPS_DIR at the directory holding them." >&2
        exit 1
    fi
done

cd "$root"

preexisting=' '
for f in $gated; do
    if [ -e "${f}c" ]; then
        preexisting="$preexisting${f}c "
    fi
done

work=''
cleanup() {
    for f in $gated; do
        case "$preexisting" in
            *" ${f}c "*) ;;
            *) rm -f "${f}c" ;;
        esac
    done
    if [ -n "$work" ]; then
        rm -rf "$work"
    fi
}
trap cleanup EXIT INT TERM

work=$(mktemp -d "${TMPDIR:-/tmp}/org-agents-gate.XXXXXX")
log="$work/compile.log"

echo "org-agents gate: emacs=$emacs"
echo "org-agents gate: root=$root"
echo "org-agents gate: deps=$deps_dir"

# `byte-compile-dest-file-function' sends each .elc into $work instead of
# beside its source.  The lambda reads the directory out of the
# environment rather than out of the shell's quoting, so a temporary
# directory with an awkward name cannot break the --eval form.
redirect='(setq byte-compile-dest-file-function
  (lambda (src)
    (expand-file-name (concat (file-name-nondirectory src) "c")
                      (getenv "ORG_AGENTS_GATE_DEST"))))'

for f in $deps; do
    ORG_AGENTS_GATE_DEST="$work" "$emacs" -batch \
        -L "$work" -L . -L "$deps_dir" \
        --eval "$redirect" \
        -f batch-byte-compile "$deps_dir/$f" >/dev/null 2>&1 || true
    if [ ! -e "$work/${f}c" ]; then
        echo "org-agents gate FAILED: $f did not compile" >&2
        exit 1
    fi
done
echo "org-agents gate: dependencies built in $work (not gated)"

# Start from no .elc at all, so the run begins in a known state.  This is
# what makes the pre-existing file not survive; `cleanup' decides only
# whether its replacement stays.  See the header for what was measured.
for f in $gated; do
    rm -f "${f}c"
done

status=0
"$emacs" -batch -L "$work" -L . -L "$deps_dir" \
    -f batch-byte-compile $gated >"$log" 2>&1 || status=$?
cat "$log"

# "Source file ... newer than byte-compiled file" is informational, not a
# Warning, and does not trip this.
count=$(grep -ci 'warning' "$log" || true)

if [ "$status" -ne 0 ]; then
    echo "org-agents gate FAILED: byte-compile exited $status" >&2
    exit 1
fi
if [ "$count" -ne 0 ]; then
    echo "org-agents gate FAILED: $count warning line(s)" >&2
    exit 1
fi
echo "org-agents gate PASSED: zero warnings for $gated"
