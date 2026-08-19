#!/bin/sh
# org-agents-byte-compile-gate.sh --- assert a warning-free byte-compile
#
# Compiles org-db-cli.el and org-agents.el and fails unless the byte
# compiler reports ZERO warnings for them.  Run it from anywhere; it finds
# its own lisp/ directory.
#
# Why the dependencies are compiled first.  git tracks no .elc here, so in
# a fresh checkout `(require 'org-ql-ext)' loads that file -- and org-ext.el
# below it -- as SOURCE, which evaluates each one's
# `(eval-when-compile (require 'cl))' and reports "Package cl is
# deprecated" against OUR require line rather than theirs.  Where this code
# actually runs, both .elc exist and the warning never fires, so the gate
# builds them first to reproduce that environment.  Their own warnings are
# their own business and are NOT gated: neither file is warning-free for
# reasons that have nothing to do with this package.
#
# Only the .elc this run creates are removed afterwards.  In a checkout
# where one of them was already built, it is load-bearing for someone else.
#
# Usage:
#   lisp/tools/org-agents-byte-compile-gate.sh
#
#   EMACS=/path/to/emacs  the interpreter to use.  Without it, an Emacs
#                         that can `(require 'org-ql)' is searched for.
#   EXTRA_LOAD_PATH=DIR   one more -L directory, holding the modules these
#                         files require that lisp/ does not itself contain.
#                         Defaults to ~/.emacs.d/lisp.
set -eu

tools=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lisp=$(CDPATH= cd -- "$tools/.." && pwd)
extra=${EXTRA_LOAD_PATH-$HOME/.emacs.d/lisp}

# In order: org-ql-ext requires org-ext, so org-ext must be built first or
# it is loaded as source while the second is compiled.
deps='org-ext.el org-ql-ext.el'
gated='org-db-cli.el org-agents.el'

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

cd "$lisp"

preexisting=' '
for f in $deps $gated; do
    if [ -e "${f}c" ]; then
        preexisting="$preexisting${f}c "
    fi
done

log=''
cleanup() {
    for f in $deps $gated; do
        case "$preexisting" in
            *" ${f}c "*) ;;
            *) rm -f "${f}c" ;;
        esac
    done
    if [ -n "$log" ]; then
        rm -f "$log"
    fi
}
trap cleanup EXIT INT TERM

log=$(mktemp)

echo "org-agents gate: emacs=$emacs"
echo "org-agents gate: lisp=$lisp"

for f in $deps; do
    "$emacs" -batch -L . -L "$extra" -f batch-byte-compile "$f" \
        >/dev/null 2>&1 || true
    if [ ! -e "${f}c" ]; then
        echo "org-agents gate FAILED: $f did not compile" >&2
        exit 1
    fi
done
echo "org-agents gate: dependencies built (not gated)"

for f in $gated; do
    rm -f "${f}c"
done

status=0
"$emacs" -batch -L . -L "$extra" -f batch-byte-compile $gated \
    >"$log" 2>&1 || status=$?
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
