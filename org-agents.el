;;; org-agents.el --- Tinderbox-style Org agents -*- lexical-binding: t -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 18 Aug 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org-ql "0.8"))
;; Keywords: org agent query outlines
;; X-URL: https://github.com/jwiegley/dot-emacs

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; This package provides *agents* in the sense of Eastgate Tinderbox:
;; ordinary Org entries that carry a query in an `:AGENT_QUERY:'
;; property and, when updated, populate themselves with links back to
;; every entry in the corpus that matches.  An agent renders its
;; matches as child "alias" headings, a plain list, or a table.
;;
;; Queries are org-ql S-expressions extended with a compact `$PROP'
;; property-reference layer, which this file implements.  A reference
;; expands according to its position:
;;
;;   (and (todo) $URL)            ; boolean:  (property "URL")
;;   (string-match "gh" $URL)     ; value:    (or (org-entry-get nil "URL") "")
;;   (> $REVIEWS 3)               ; numeric:  (string-to-number (or … "0"))
;;   (property-ts $NEXT_REVIEW …) ; name:     "NEXT_REVIEW"
;;   $OWNER*                      ; inherited: (org-entry-get nil "OWNER" t)
;;
;; The specials $ITEM, $TODO, $PRIORITY, $TAGS, $CATEGORY, $LEVEL and
;; $FILE reference the entry itself rather than a property.
;;
;; Evaluation is always performed by org-ql against live buffers, so
;; there is exactly one evaluation engine and one answer.  ripgrep
;; serves only as an optional candidate-FILE prefilter, which is what
;; makes a whole-corpus agent affordable.
;;
;; The agent properties:
;;
;;   :AGENT_QUERY:   the query.  Required; the property is what makes an
;;                   entry an agent.
;;   :AGENT_VIEW:    `children' (the default), `list', or `table'.  Any
;;                   other value is refused rather than rendered.
;;   :AGENT_SCOPE:   `agenda' (the default), `active', `all', a directory
;;                   relative to `org-directory', or a read-able list of
;;                   file names.
;;   :AGENT_SORT:    `date', `todo', `priority', `reverse', or a list of
;;                   those, which org-ql applies to the matched entries;
;;                   or `(column N)' / `(ts-column N)', which order the
;;                   rows of a table view and are refused in any other.
;;   :AGENT_LIMIT:   a count.  Applied after the sort.
;;   :AGENT_COLUMNS: whitespace-separated column names for a table view.
;;                   `ITEM_BY_ID' is the link to the match; every other
;;                   name is read as a property at the match.
;;   :AGENT_FORMAT:  whitespace-separated property names, shown after the
;;                   link in the children and list views.
;;   :AGENT_MATCH:   written by this package on a generated alias, never
;;                   by hand.  See the alias contract below.
;;   :AGENT_MATCHED: written by this package after an update: how many
;;                   entries matched, and when.
;;
;; An Org property value is a single line.  Keep the query on one line,
;; or name a shorter one and let a residual predicate do the rest.  A
;; `:AGENT_QUERY+:' continuation is read by `org-entry-get', which joins
;; the pieces with `org--property-get-separator' -- a space unless
;; `org-property-separators' says otherwise -- so a query split at a
;; whitespace boundary does read back correctly.  It is still a bad idea:
;; split anywhere else and the pieces join into a different sexp, or into
;; one that will not read at all, and nothing about the drawer says which
;; happened.
;;
;; Org reads the value `nil' as no value at all, so `:AGENT_VIEW: nil'
;; is an agent with no view rather than an error, and takes the default.
;;
;; The alias contract, and its sharp edges:
;;
;; In the children view each match becomes a child "alias" heading
;; carrying `:AGENT_MATCH: t'.  An alias holding nothing but that drawer
;; is *pristine* and belongs to this package: every update deletes it and
;; writes it again.  The moment anything is written under it, it is the
;; user's: no update deletes it, and a match that is gone marks it
;; `(stale)' instead.  A child that never carried `:AGENT_MATCH: t' is
;; not this package's to touch at all.
;;
;; Four consequences worth knowing before relying on it:
;;
;;   - Because a pristine alias is deleted rather than edited, extra
;;     drawer properties or tags added to a body-less alias are
;;     discarded.  Write a line under the alias and they are kept along
;;     with it.
;;   - A preserved alias keeps the description and format suffix it was
;;     written with.  Only the stale mark changes, so an alias whose
;;     match has since been renamed goes on showing the old title.
;;   - An alias is recognized by the target it links to.  So a match that
;;     gains an `:ID:' between updates is a different target: the old
;;     alias is marked stale and a new one is written beside it.
;;   - Two matches with no ID and identical headings in one file share
;;     one `file:...::*' target, so a single alias may stand for both
;;     while `:AGENT_MATCHED:' counts two.  Give them IDs to tell them
;;     apart.
;;
;; An alias whose link the user has mangled past reading is left alone
;; and a fresh alias is written beside it, rather than guessing which
;; match it stood for.
;;
;; `:AGENT_MATCHED:', and what writing it costs:
;;
;; Recording the result on the agent has three effects that are accepted
;; rather than avoided:
;;
;;   - It modifies the buffer.  An update leaves its files modified and
;;     unsaved, so the result can be read over -- and undone -- first.
;;   - Its timestamp is inactive, and therefore visible to a query:
;;     `(ts-inactive :from ...)' over a corpus holding agents will match
;;     the agents themselves.
;;   - It leaves an inactive timestamp in the file, so a version-control
;;     diff of a saved update shows the stamp even where the render
;;     itself did not move.
;;
;; Updating on save:
;;
;; Besides `org-agents-update', `org-agents-update-buffer' and
;; `org-agents-update-all', an agent may be refreshed by saving the file it
;; lives in: `org-agents-mode' updates a buffer's agents before each save,
;; and `global-org-agents-mode' turns it on in every Org buffer whose text
;; mentions `:AGENT_QUERY:'.  Three deliberate refusals keep a save cheap.
;; No save spawns a prefilter, whatever `org-agents-prefilter' says: a
;; prefilter can only narrow a file set and never change an answer, so an
;; agent updated without one matches what it would have matched anyway.  An
;; agent whose scope needs a prefilter is named and left for
;; `org-agents-update' -- there is no bound on what one of those would
;; open, and a save is a keystroke.  And an
;; update that renders what was already there puts the buffer back as it
;; was, stamps and all -- so a file whose agents found nothing new reaches
;; disk byte-identical, which is the one thing that makes writing
;; `:AGENT_MATCHED:' on every save affordable.  A C-g during such an update
;; aborts the save along with it.
;;
;; Scope, and why an unbounded one is worth narrowing:
;;
;; `agenda' and an explicit list of files name the files they will open,
;; and are evaluated live -- a prefilter there is pure overhead.
;; Measured: an `agenda'-scope update over the eight largest files of the
;; author's corpus, 8.9 MB and 373 matches, costs 0.03 to 0.05 seconds
;; once the buffers are visited and spawns no subprocess at all, against
;; 0.10 to 0.45 seconds for a single ripgrep run over the whole corpus.
;; `active', `all' and any directory name nothing: nothing about naming a
;; directory bounds how much it holds, and reading one live means opening
;; however many files it turns out to contain.  Measured over a
;; 3,669-file corpus: a `(and (todo) (property "NEXT_REVIEW"))' agent
;; narrows to 314 files in 0.09 seconds of ripgrep and finishes in 12
;; seconds; unnarrowed, the same query had not finished after nine
;; minutes.  So those scopes are narrowed with ripgrep, and where they
;; cannot be -- no ripgrep, or a query with nothing to push -- they are
;; scanned live with one message naming the file count, unless
;; `org-agents-prefilter' is `require', which refuses instead.  (A
;; file-count ceiling, above which a live walk is refused and below which
;; it is allowed, is the obvious way to sharpen this and is not
;; implemented.)
;;
;; ripgrep answers "no file matches" and "I could not answer" with
;; different exit statuses, so an agent over a corpus scope whose query
;; genuinely matches nothing renders zero matches rather than reporting a
;; broken prefilter.
;;
;; Only conjuncts whose ripgrep answer is provably a superset of org-ql's
;; are pushed into the prefilter; everything else stays residual and is
;; applied by org-ql.  A broad `org-use-property-inheritance' -- `t' most
;; of all -- makes no property conjunct pushable, so a property-only
;; agent falls back to its scope's whole file set: still correct, and
;; much slower.  The prefilter's value depends on keeping inheritance
;; narrow.
;;
;; Known limitations:
;;
;;   - A literal is pushed only when every character in it is printable
;;     ASCII.  ripgrep decodes as UTF-8 while Emacs may decode an Org
;;     file as latin-1, so a non-ASCII literal is a pattern that could
;;     match less than org-ql does -- and `--encoding' is one global
;;     setting, which a mixed corpus cannot use.  Such a conjunct is left
;;     residual, which costs breadth and never an answer.
;;   - A planning bound is never pushed, only the presence of the stamp:
;;     ripgrep cannot compare dates.  org-ql applies the bound, so this
;;     costs candidate files and no matches.
;;   - One agent may carry several blocks, each its own view of it, but an
;;     update that was not asked for from inside a particular one writes
;;     only the FIRST: `org-agents-update' with point outside a block, and
;;     therefore `org-agents-update-buffer' and `org-agents-update-all',
;;     refresh that one and leave the rest as they were.  Put point in a
;;     block to write that block, or use `org-update-all-dblocks' to write
;;     every block in the buffer.
;;
;; Each is covered by a test in org-agents-test.el rather than only
;; described here: the first two in the Prefilter section, beside the
;; soundness suite, and the third beside the other update commands.
;;
;; This file is kept warning-free under the byte compiler, and
;; tools/org-agents-byte-compile-gate.sh is what says so: it builds the two
;; repo-local dependencies first, because a checkout with no .elc loads
;; them as source and reports their own `(require 'cl)' against the require
;; lines here, then compiles this one and fails on any warning at all.
;;
;; See docs/design.md for the evaluation gate and the renderers.  Do NOT
;; read its push-down table: that table describes the PostgreSQL
;; prefilter this package used to have, and its per-row justifications
;; are facts about SQL operators that no longer run -- a heading literal
;; is argued safe there by `ILIKE %lit%', and a property value is said to
;; be pushable when it holds no whitespace, which the rule in this file
;; says outright is the wrong test.  Extending the table on those
;; arguments can push something ripgrep cannot see, which drops files
;; with no error.  The current push-down table is
;; `org-agents--pushdown-fns' below, whose every row states its own
;; superset argument, and README.md's "The ripgrep prefilter" section
;; states the same table for a reader.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cus-edit)                     ; `custom-file', the FUNCTION
(require 'tabulated-list)               ; `org-agents-list-approvals'
(require 'org)
(require 'org-id)
(require 'org-ql)
(require 'org-ql-search)                ; `org-agents-preview' delegates to it
(require 'org-ql-ext)

;; `org-ql-select' expands into a call to this, which org-ql does not
;; autoload: without the declaration the compiler reports it as possibly
;; undefined at runtime, over a call site that is org-ql's own and not
;; this file's.
(declare-function org-ql--normalize-query "org-ql")

(defgroup org-agents nil
  "Tinderbox-style persistent queries for Org-mode."
  :group 'org
  :prefix "org-agents-")

;;;; Expander

;; The expander rewrites the `$PROP' layer into a plain org-ql query.
;; It is pure: it reads no buffer and evaluates nothing, so it can be
;; tested and inspected without an Org context.

(defconst org-agents--nested-query-heads '(parent ancestors children descendants)
  "org-ql predicates whose argument is itself a query.")

(defconst org-agents--boolean-heads '(and or not when unless)
  "Heads whose arguments are themselves queries in boolean position.")

(defconst org-agents--name-position-heads '(property property-ts)
  "Predicates whose first argument is a property NAME; a $ref there
denotes the name string, not the value.")

(defconst org-agents--numeric-heads '(< > <= >= = + - * /)
  "Heads whose arguments are numbers, forcing numeric coercion of $refs.")

(defconst org-agents--specials
  '(("ITEM" . (org-get-heading t t t t))
    ("TODO" . (org-get-todo-state))
    ("PRIORITY" . (org-entry-get nil "PRIORITY"))
    ("TAGS" . (org-get-tags))
    ("CATEGORY" . (org-get-category))
    ("LEVEL" . (org-current-level))
    ("FILE" . (buffer-file-name)))
  "Accessor forms for $SPECIAL references.")

(defun org-agents--ref-name-p (form)
  "Non-nil if FORM is a symbol written as a `$' reference, readable or not.
`org-agents--ref-p' answers only for a reference it can read a property
name out of.  The gate has to refuse the rest as well: `$' and `$*' name
no property, and either would reach org-ql as a void variable at match
time."
  (and (symbolp form) form (string-prefix-p "$" (symbol-name form))))

(defun org-agents--ref-p (form)
  "If FORM is a $ref symbol naming a property, return (NAME . INHERITP).
Else nil, which is also the answer for `$' and `$*': neither names a
property, and reading `$*' as one would hand `org-entry-get' the empty
name, which answers nil at every entry.  Left as the symbols they are,
they reach `org-agents--check-spelling', which says which reference it
could not read."
  (when (and (org-agents--ref-name-p form)
             (> (length (symbol-name form)) 1))
    (let* ((name (substring (symbol-name form) 1))
           (inherit (string-suffix-p "*" name))
           (bare (if inherit (substring name 0 -1) name)))
      (unless (string-empty-p bare) (cons bare inherit)))))

(defun org-agents--known-predicate-p (head)
  "Non-nil if HEAD names an org-ql predicate (built-in or user-defined)."
  (and (symbolp head)
       (or (assq head org-ql-predicates)
           ;; org-ql-predicates keys by main name; also check aliases.
           (cl-some (lambda (pred)
                      (memq head (plist-get (cdr pred) :aliases)))
                    org-ql-predicates))))

(defun org-agents--value-ref (ref &optional numeric)
  "Accessor form for REF (from `org-agents--ref-p') in value position.
With NUMERIC non-nil, coerce a property's string value to a number."
  (let* ((name (car ref))
         (special (cdr (assoc name org-agents--specials)))
         (base (cond (special special)
                     ((cdr ref) `(org-entry-get nil ,name t))
                     (t `(org-entry-get nil ,name)))))
    (cond ((and numeric special) base)     ; specials manage their own types
          (numeric `(string-to-number (or ,base "0")))
          (special base)
          (t `(or ,base "")))))

(defun org-agents--expand-residual (form numeric)
  "Rewrite $refs in residual Lisp FORM.  NUMERIC applies to direct args."
  (cond
   ((org-agents--ref-p form)
    (org-agents--value-ref (org-agents--ref-p form) numeric))
   ((consp form)
    (let ((n (memq (car form) org-agents--numeric-heads)))
      (cons (car form)
            (mapcar (lambda (arg) (org-agents--expand-residual arg n))
                    (cdr form)))))
   (t form)))

(defun org-agents--expand (form)
  "Expand $PROP references in query FORM, yielding a plain org-ql query."
  (cond
   ;; Bare $ref in boolean position.
   ((org-agents--ref-p form)
    (let* ((ref (org-agents--ref-p form))
           (special (assoc (car ref) org-agents--specials)))
      (cond
       ;; A special names the entry itself, which has no property row of
       ;; that name: (property "TODO") is a valid query that never
       ;; matches.  Test the accessor instead, and ignore any star,
       ;; since there is nothing to inherit.
       (special (cdr special))
       ((cdr ref) `(org-entry-get nil ,(car ref) t))
       (t `(property ,(car ref))))))
   ((not (consp form)) form)
   ;; Boolean combinators: recurse into every clause.
   ((memq (car form) org-agents--boolean-heads)
    (cons (car form) (mapcar #'org-agents--expand (cdr form))))
   ;; Nested-query predicates: recurse into the query argument.
   ((memq (car form) org-agents--nested-query-heads)
    (cons (car form) (mapcar #'org-agents--expand (cdr form))))
   ;; Name-position predicates: first arg $ref becomes the NAME string.
   ((memq (car form) org-agents--name-position-heads)
    (let ((args (cdr form)))
      (cons (car form)
            (cons (if (org-agents--ref-p (car args))
                      (car (org-agents--ref-p (car args)))
                    (car args))
                  (cdr args)))))
   ;; Any other known predicate: pass through untouched.
   ((org-agents--known-predicate-p (car form)) form)
   ;; Residual Lisp: rewrite refs with coercion.
   (t (org-agents--expand-residual form nil))))

;;;; Gate

;; An org-ql query is Lisp, and org-ql evaluates residual Lisp at every
;; candidate entry.  A query read out of an Org property is therefore
;; code from a file, and the form that is evaluated passes this gate
;; first.  The form, not the query: `org-agents-exclude' is conjoined in
;; before org-ql sees it, and a gate that judged the query alone
;; approved a form nobody had been shown.  `org-agents--effective-query'
;; is the one place that says what that form is, so gate, hash and
;; evaluation cannot come to mean different things.  Forms built only
;; from org-ql predicates and combinators run unremarked; anything else
;; needs the user's word for it, once, remembered by hash.
;;
;; Refusal is checked first, and outranks `org-ql-ask-unsafe-queries' and
;; structural safety both: the switch governs whether the user is ASKED,
;; and a head on `org-agents-refused-heads' is not a question.  What a
;; predicate head vouches for is its own name; what its org-ql normalizer
;; runs when the query is compiled is code from wherever that predicate
;; was defined, and it runs past this gate no matter what the user answers.
;;
;; Approval and refusal are keyed on the same hash but not looked up the
;; same way, because their fail-safe directions are opposite.  An approval
;; that stops matching asks again; a refusal that stops matching RUNS.  So
;; an approval names the whole form and nothing else, while a refusal is
;; looked up for the form and for the query inside it, and editing
;; `org-agents-exclude' can therefore invalidate every approval -- as it
;; should, the exclusion being part of what was approved -- without
;; lifting a single refusal.

(defcustom org-agents-exclude '(not (property "AGENT_MATCH"))
  "Conjunct appended to every agent query and to previews.
Keeps agents from matching generated aliases.  Appended last so cheap
predicates short-circuit first; applied only on the Emacs side, never
in the prefilter.  Set to nil to match aliases like any other entry.

This value is conjoined into the form the gate approves, so Lisp here is
gated exactly like Lisp in a query, and changing it invalidates every
remembered approval: an approval names a form, and this is part of the
form.  A REFUSAL is not invalidated by it -- see
`org-agents-refused-queries' -- because an exclusion is not a place a
decision to say no can be undone from.

Risky: it is Lisp conjoined into every agent query and every preview."
  :type 'sexp :risky t :group 'org-agents)

(defun org-agents--effective-query (query)
  "Return the form org-ql will be handed for QUERY.
`org-agents-exclude' is conjoined in, unless it is nil.

This is the form that is gated, the form that is hashed, and the form
that is evaluated, and the three cannot diverge because there is one
function saying what it is.  They did diverge: the gate was handed the
query while the exclusion was spliced in afterwards, so approving a
query silently approved an exclusion nobody had been shown."
  (if org-agents-exclude
      ;; nil conjoined here is a clause that never matches, which is not
      ;; what turning the exclusion off means.
      `(and ,query ,org-agents-exclude)
    query))

(defun org-agents--base-query (form)
  "Return the query FORM was built from, undoing `org-agents--effective-query'.
FORM itself where the exclusion is off or FORM was not built by appending
the current one.

Approval is keyed on the whole form, deliberately: what is approved has
to be what runs.  Refusal cannot be keyed on that alone, or it would fail
OPEN -- edit `org-agents-exclude' and every refusal ever made stops
matching, without a single query being touched.  So the gate looks the
base query up as well, and a refusal is recorded under both.  The
asymmetry is the fail-safe direction of each: an approval that stops
matching asks again, a refusal that stops matching runs."
  (if (and org-agents-exclude
           (proper-list-p form)
           (= 3 (length form))
           (eq (car form) 'and)
           (equal (nth 2 form) org-agents-exclude))
      (nth 1 form)
    form))

(defcustom org-agents-refused-heads '(semantic)
  "Predicate heads this package refuses to hand org-ql, whatever else says.
Refusal is checked before the safe list and before any remembered
approval, and `org-ql-ask-unsafe-queries' does not override it: the
switch governs whether the user is asked, and a head on this list is not
a question.

A head with no dangerous argument of its own can still be dangerous.
org-ql runs each predicate's *normalizer* when it compiles a query --
after this gate has admitted the head, and before any entry is examined
-- and a normalizer is arbitrary code from wherever the predicate was
defined.  `(semantic \"x\")' is the shipped example: `org-ql-semantic.el'
defines `semantic' with a normalizer that calls
`org-ql-semantic--ensure-cache', which `call-process'es `org db search'.
Structurally the form is a predicate call like any other, so the safe
list admits it without a prompt and the subprocess runs.

This is where such a head goes.  Matching is by literal symbol, so an
alias of an IO-bearing predicate has to be listed too.

Risky: a file that could empty this list would remove the protection for
every file read afterwards in the session."
  :type '(repeat symbol) :risky t :group 'org-agents)

(defconst org-agents--approval-type
  '(repeat (choice (string :tag "Hash only (legacy)")
                   (cons (string :tag "Hash") (string :tag "Query"))))
  "Customize type of `org-agents-safe-queries' and its negative twin.
An entry is either a `(HASH . TEXT)' cons or, from a version that
recorded only the hash, a bare HASH string.  Both are read; only the cons
is written.  Strings and conses of strings are all this holds, so a saved
value evaluates nothing when `custom-file' is read back.")

(defcustom org-agents-refused-queries nil
  "Records of forms refused outright, whatever else has said about them.
A form whose hash is here is refused before the safe list is consulted
and before `org-ql-ask-unsafe-queries' is looked at, and the refusal
outlives the session that made it, exactly as an approval does.

Refusing through `org-agents-list-approvals' records TWO entries where
the form was built by appending `org-agents-exclude': the whole form, and
the query inside it.  That is what keeps a refusal in force when the
exclusion is later edited -- see `org-agents--base-query'.  An entry added
here by hand covers only the exact form it names.

What a hash identifies is one printed form, not a query up to meaning: a
refusal of `(and (todo) (evil))' does not cover `(and (evil) (todo))' or
`(and (and (todo) (evil)))', which print differently and hash
differently.  Where what the user objects to is a PREDICATE rather than a
particular query, `org-agents-refused-heads' is the instrument that
refuses it however the query around it is spelled.

Entries have the same shape as `org-agents-safe-queries', so one listing
can show an approval and a refusal side by side, each with the text its
hash covers.  Manage this through `org-agents-list-approvals' rather than
by hand.

Risky: this is the refusal record itself, and a file that could set it
could delete a refusal the user made deliberately."
  :type org-agents--approval-type :risky t :group 'org-agents)

(defcustom org-agents-safe-queries nil
  "Records of forms approved to run without prompting.
Managed like `safe-local-variable-values': approving a form interactively
offers to persist it here.

An entry is a `(HASH . TEXT)' cons, where TEXT is what
`org-agents--query-text' printed and HASH is the sha1 of that very text.
The two are therefore self-consistent by construction, and
`org-agents-list-approvals' can show precisely what each hash covers.  A
bare HASH string is a legacy entry, written by a version that recorded no
text; it is still honoured, and listed as legacy, since nothing can
recover the query it stood for.

Persisting goes through `customize-save-variable', which writes to the
file `(custom-file t)' names -- and answers nil, writing nothing, unless
`user-init-file' is set.  Where the real init is an Org file that is
tangled, `user-init-file' is the tangled output, and a saved approval
will be overwritten the next time it is generated.  Set `custom-file' to
a file of its own to keep approvals.

Risky: this is the approval record itself, and a file that could set it
could pre-approve its own query and never be asked about it."
  :type org-agents--approval-type :risky t :group 'org-agents)

(defvar org-agents--session-approved (make-hash-table :test 'equal)
  "Hash of each form approved for this session only, mapped to its text.
Keyed like `org-agents-safe-queries' and holding the same text beside the
same hash, so `org-agents-list-approvals' can show a session-only
approval and revoke it, instead of leaving it to work unseen until Emacs
is restarted.  Where customize has no file to write, EVERY approval is
session-only, so this is the common table and not the rare one.

Risky, and not as a matter of hygiene: this table IS the record the gate
consults first.  Unmarked it was settable from a Local Variables block --
Emacs classes it `unsafe' rather than `risky', which is precisely the
class it offers to mark permanently safe -- and the hash to put in it is
computable offline, `org-agents-exclude' having a published default.  A
file could therefore pre-approve its own arbitrary Lisp, which would then
run at every candidate entry with no prompt and no listing.")

;; `defcustom' takes `:risky t'; a `defvar' has to say it separately, and
;; the two must not diverge: the safe list and this table answer the same
;; question, one of them persistently and one of them for the session.
(put 'org-agents--session-approved 'risky-local-variable t)

(defun org-agents--approval-hash (entry)
  "The hash ENTRY records, whether ENTRY is a cons or a legacy string."
  (if (consp entry) (car entry) entry))

(defun org-agents--approval-text (entry)
  "The query text ENTRY records, or nil where it records only a hash."
  (and (consp entry) (cdr entry)))

(defun org-agents--approval-entry (hash entries)
  "The entry in ENTRIES recording HASH, or nil for none.
`member' answered for a list of bare hashes and for nothing else, so the
moment a cons was written it would have stopped matching what it wrote."
  (cl-find hash entries :key #'org-agents--approval-hash :test #'equal))

(defun org-agents--refusal-entry (form)
  "The `org-agents-refused-queries' entry refusing FORM, or nil for none.
FORM's own hash and that of `org-agents--base-query' are both looked up,
so editing `org-agents-exclude' cannot lift a refusal."
  (cl-loop for candidate in (delete-dups
                             (list form (org-agents--base-query form)))
           thereis (org-agents--approval-entry
                    (org-agents--query-hash candidate)
                    org-agents-refused-queries)))

(defun org-agents--persist-approvals (var value)
  "Set VAR to VALUE, saved where customize has a file to save it in.
`customize-save-variable' writes to `(custom-file t)', which answers nil
whenever `user-init-file' is nil -- and then it does not write: it says
so in a message and merely sets the variable.  So the file is what is
asked about here, and not `custom-file' and `user-init-file' separately.
The guard this replaced asked whether EITHER was set, passed where only
`custom-file' was, and left the user told an approval had been remembered
permanently when nothing had been written at all."
  (cond ((custom-file t) (customize-save-variable var value))
        (t (set-default var value)
           (message "org-agents: `%s' changed for this session only; \
customize has no file to save it in" var))))

(defconst org-agents--misspelled-heads
  '((headline . heading) (re . regexp) (p . priority))
  "Predicate spellings that are not valid org-ql, with their replacements.
The three most often written by hand for org-ql predicates that are
spelled otherwise.  `h' and `r' ARE org-ql aliases, so `re' and `p' look
like the same abbreviation habit -- which is what makes them worth
diagnosing.  Without the diagnostic the failure is not a clean one:
`org-agents--structurally-safe-p' returns nil, the query is put to the
user as unsafe (which it is not), and if approved it fails at match time
as a `void-function' from inside org-ql's own generated matcher, naming
neither the agent nor the word that was wrong.")

(defconst org-agents--special-accessors
  (mapcar #'cdr org-agents--specials)
  "The forms a bare $SPECIAL expands to.
A closed set of read-only readers of the entry at point, so a query is
no less safe for holding one.")

(defun org-agents--structurally-safe-p (form)
  "Non-nil if FORM consists solely of known predicates and combinators.
A predicate head vouches for its own name only: org-ql evaluates a
predicate's arguments as Lisp too, so every argument must answer for
itself or `(tags (shell-command \"x\"))' would pass unremarked.  An
argument that is a list with no symbol to call is the data it looks
like, which is how org-ql's own `(src :regexps (\"defun\"))' is
written."
  (cond
   ((not (consp form)) t)                  ; literals as arguments
   ((not (proper-list-p form)) nil)        ; dotted: fail closed
   ;; What a bare $SPECIAL expands to.
   ((member form org-agents--special-accessors) t)
   ;; Quoted data is returned, never evaluated, whatever it holds.
   ((eq (car form) 'quote) t)
   ;; No symbol in the car, so this is data and every element, the first
   ;; included, stands for itself -- unless the car is itself callable.
   ;; A byte-code object reads in from a property like any other text,
   ;; and Emacs calls whatever it finds in function position.
   ((not (symbolp (car form)))
    (and (not (functionp (car form)))
         (cl-every #'org-agents--structurally-safe-p form)))
   ((or (memq (car form) org-agents--boolean-heads)
        (memq (car form) org-agents--nested-query-heads)
        (org-agents--known-predicate-p (car form)))
    (cl-every #'org-agents--structurally-safe-p (cdr form)))
   (t nil)))

(defun org-agents--leftover-ref (form)
  "Return the first `$' reference symbol anywhere in FORM, or nil for none.
Anything written as a reference counts, not only what the expander can
read one out of: a `$' or a `$*' the expander left alone is exactly the
case that needs saying, since org-ql would reach it as a void variable."
  (cond ((org-agents--ref-name-p form) form)
        ((consp form) (or (org-agents--leftover-ref (car form))
                          (org-agents--leftover-ref (cdr form))))))

(defun org-agents--refused-head (form)
  "Return the first `org-agents-refused-heads' symbol in FORM, or nil.
Every cons cell is descended, and a refused symbol is reported wherever
it appears in a car -- in argument position and under a nested query, not
only as the head of FORM itself.

Deliberately more conservative than `org-agents--structurally-safe-p',
which exempts quoted data because quoted data is returned rather than
evaluated: `(quote (semantic \"x\"))' is refused here.  This fails
closed, and the shape it costs is one nobody writes on purpose, while
what failing open costs is a subprocess."
  (cond ((and (consp form) (symbolp (car form)) (car form)
              (memq (car form) org-agents-refused-heads))
         (car form))
        ((consp form) (or (org-agents--refused-head (car form))
                          (org-agents--refused-head (cdr form))))))

(defun org-agents--check-head-spelling (form)
  "Signal `user-error' if FORM uses a spelling org-ql has no reading for.
Only query positions are examined -- combinators, nested queries, and
the arguments of known predicates, the same descent
`org-agents--structurally-safe-p' makes -- because those are the
positions where the user meant to write a query.  `(property \"K\"
 (headline \"x\"))' is caught there, while in residual Lisp `p' or `re'
is an ordinary variable or datum, and diagnosing it would answer a
question the user was never asked."
  (when (and (consp form) (proper-list-p form))
    (when-let* ((fix (alist-get (car form) org-agents--misspelled-heads)))
      (user-error "org-agents: `%s' is not an org-ql predicate; use `%s'"
                  (car form) fix))
    (when (or (memq (car form) org-agents--boolean-heads)
              (memq (car form) org-agents--nested-query-heads)
              (org-agents--known-predicate-p (car form)))
      (mapc #'org-agents--check-head-spelling (cdr form)))))

(defun org-agents--check-spelling (form)
  "Signal `user-error' if FORM cannot be evaluated as written.
FORM has already been through `org-agents--expand', so a surviving
$ref sits in a position the expander has no reading for, and would
otherwise reach org-ql as a void variable at match time."
  (org-agents--check-head-spelling form)
  (when-let* ((ref (org-agents--leftover-ref form)))
    ;; Printed through `org-agents--query-text', not with `%S': under an
    ;; ambient `print-length' the query showed as a prefix ending in
    ;; `...', and the conjunct the unreadable reference sits in is the one
    ;; thing this message exists to supply.
    (user-error "org-agents: no expansion for `%s' in `%s'"
                ref (org-agents--query-text form))))

(defun org-agents--query-text (query)
  "Return QUERY printed whole, as one string.
This is the package's only printer of a query, and that is the point of
it: the text that is hashed, the text the user is shown, and the text
recorded beside an approval are all this one string, so none of the
three can come to say less than another.  Two display sites once
printed with `%S' under whatever `print-length' the user had, which
showed a prefix of a query the hash covered entire.

Every printer variable that can change what this prints is bound here,
because the text has to be a function of the form and of nothing else --
neither of what the caller's init happens to set, nor of what a query can
arrange for itself:

  `print-level', `print-length' nil, so nothing is elided;
  `print-circle' nil, so a shared substructure is printed out rather than
    abbreviated to `#1#';
  `print-escape-newlines', `print-escape-control-characters' t, so a
    string in the query cannot break the text into lines.  A query is
    shown in the minibuffer, which is capped at `max-mini-window-height'
    and scrolled to the end of the prompt: forty newlines in a `regexp'
    argument pushed the dangerous conjunct off the top of the window and
    left the user answering yes to a prompt that appeared to ask about
    nothing, under a hash that covered all of it;
  `print-gensym' t, so an uninterned symbol prints as `#:foo' and cannot
    share text -- and therefore a hash -- with the interned symbol of the
    same name;
  `print-quoted' t and `float-output-format' nil, their defaults, so that
    an init that changes either does not silently invalidate every
    approval stored on that machine."
  (let ((print-level nil)
        (print-length nil)
        (print-circle nil)
        (print-escape-newlines t)
        (print-escape-control-characters t)
        (print-gensym t)
        (print-quoted t)
        (float-output-format nil))
    (prin1-to-string query)))

(defun org-agents--query-hash (query)
  "Return the hash under which QUERY is approved.
Printing goes through `org-agents--query-text' and is therefore
unabbreviated: a truncated query would hash as its own prefix, so one
approval would answer for every query sharing it."
  (sha1 (org-agents--query-text query)))

(defun org-agents--gate (query &optional context)
  "Return non-nil when QUERY may be evaluated.
Structurally safe queries pass unless refused.  Unsafe queries pass when
`org-ql-ask-unsafe-queries' is nil, when previously approved, or when
the user confirms; in `noninteractive' (or CONTEXT `batch') they are
skipped instead of prompting.

A refusal -- a head in `org-agents-refused-heads', or a hash in
`org-agents-refused-queries' -- signals rather than returning nil.  The
callers turn nil into one generic \"query not approved\", which would say
nothing about which head was refused, or that no approval can help."
  (org-agents--check-spelling query)
  (when-let* ((head (org-agents--refused-head query)))
    (user-error "org-agents: `%s' is refused by `org-agents-refused-heads'"
                head))
  ;; Guarded on the list being non-empty so the common case does not pay
  ;; for a sha1 nothing will be looked up in.  Above the `or' below, and
  ;; not a branch of it: a refusal outranks structural safety as well as
  ;; every approval, since a form can be structurally safe and refused --
  ;; that is what refusing a query the safe list would admit means.
  (when (and org-agents-refused-queries (org-agents--refusal-entry query))
    (user-error
     "org-agents: this query is refused; see `org-agents-refused-queries'"))
  (or (org-agents--structurally-safe-p query)
      (not org-ql-ask-unsafe-queries)
      (let ((hash (org-agents--query-hash query))
            (text (org-agents--query-text query)))
        (or (gethash hash org-agents--session-approved)
            (org-agents--approval-entry hash org-agents-safe-queries)
            (if (or noninteractive (eq context 'batch))
                (progn
                  (message "org-agents: skipping unapproved query %s" text)
                  nil)
              ;; `%s' on an already-printed string, not `%S' on the form:
              ;; a second printing step would take whatever `print-length'
              ;; is ambient and show less than the hash covers.  The line
              ;; can be very long, which is correct -- a query being put to
              ;; the user must be shown whole, and the minibuffer wraps.
              (when (yes-or-no-p
                     (format "Query contains arbitrary Lisp: %s — run it? "
                             text))
                ;; The text, not `t': a session approval has to be
                ;; listable and revocable too, and where customize has no
                ;; file to write EVERY approval is a session approval.
                (puthash hash text org-agents--session-approved)
                ;; Only offer to remember where customize has a file to
                ;; write.  Without one `customize-save-variable' writes
                ;; nothing and says so in a message -- so asking would be
                ;; a promise this cannot keep.
                (when (and (custom-file t)
                           (yes-or-no-p "Remember this approval permanently? "))
                  ;; The text goes in beside the hash so the approval can
                  ;; afterwards be read, and revoked, for what it is.
                  (org-agents--persist-approvals
                   'org-agents-safe-queries
                   (cons (cons hash text) org-agents-safe-queries)))
                t))))))

;;;; Approval listing

;; The records the gate keeps are hashes, and a hash says nothing about
;; what it stands for.  Every entry written from here on therefore carries
;; the printed form beside its hash -- the same text the hash was taken of
;; and the same text the prompt showed, by way of the one printer -- so a
;; remembered decision can be read, revoked, or turned into a refusal
;; instead of being taken on trust.
;;
;; All THREE records are listed, the session table included.  Listing only
;; the two persistent ones said "nothing is remembered" to a user who had
;; just approved something -- and on a setup where customize has no file to
;; write, which is the setup `org-agents-safe-queries' documents, every
;; approval this package makes is a session approval.

(defconst org-agents--approvals-buffer "*org-agents approvals*"
  "Name of the buffer `org-agents-list-approvals' shows.")

(defconst org-agents--approvals-unrecorded "(query text not recorded)"
  "Stands in the Query column for an entry holding only a hash.
An empty cell would not tell a legacy entry apart from one whose query
really is empty text, and telling them apart is the point of listing.")

(defconst org-agents--approvals-sources
  '((org-agents-safe-queries . "approved")
    (org-agents--session-approved . "approved (session)")
    (org-agents-refused-queries . "refused"))
  "Each record the listing shows, with the State it shows for it.
In display order: what was saved, what holds only until Emacs is
restarted, what is refused outright.")

(defun org-agents--approvals-entries (var)
  "The `(HASH . TEXT)' entries the record VAR names holds now.
`org-agents--session-approved' is a hash table rather than a list, and
only the hashes `org-agents-safe-queries' does not already account for
are taken from it: the same decision listed twice would offer two rows
that mean the same thing, and revoking the saved one clears the session
copy anyway."
  (if (eq var 'org-agents--session-approved)
      (cl-loop for hash being the hash-keys of org-agents--session-approved
               using (hash-values text)
               unless (org-agents--approval-entry hash org-agents-safe-queries)
               collect (cons hash (and (stringp text) text)))
    (symbol-value var)))

(defun org-agents--approvals-rows ()
  "Rows for `org-agents-list-approvals', one per remembered decision.
A row's id is `(VARIABLE . HASH)', so a hash recorded in more than one
record still yields rows the commands can tell apart."
  (cl-loop for (var . state) in org-agents--approvals-sources
           append
           (cl-loop for entry in (org-agents--approvals-entries var)
                    for hash = (org-agents--approval-hash entry)
                    for text = (org-agents--approval-text entry)
                    collect
                    (list (cons var hash)
                          (vector (if text state (concat state " (legacy)"))
                                  (substring hash 0 (min 12 (length hash)))
                                  (or text org-agents--approvals-unrecorded))))))

(defun org-agents--approvals-refresh ()
  "Recompute the listing's rows from the two variables."
  (setq tabulated-list-entries (org-agents--approvals-rows)))

(defun org-agents--approvals-redisplay ()
  "Recompute and reprint the listing, keeping point where it can be kept."
  (org-agents--approvals-refresh)
  (tabulated-list-print t))

(defun org-agents--approvals-at-point ()
  "Return `(VARIABLE . HASH)' for the row point is on."
  (or (tabulated-list-get-id)
      (user-error "org-agents: no remembered decision on this line")))

(defun org-agents--approvals-forget (var hash)
  "Remove HASH's entry from the record VAR names, and save the result.
The session table is cleared whichever record the row came from: an
approval dropped only where it was saved goes on working until Emacs is
restarted, which is not what dropping one means."
  (remhash hash org-agents--session-approved)
  (unless (eq var 'org-agents--session-approved)
    (org-agents--persist-approvals
     var (cl-remove hash (symbol-value var)
                    :key #'org-agents--approval-hash :test #'equal))))

(defun org-agents--refusal-records (entry)
  "The entries to record so ENTRY's form stays refused.
ENTRY itself, and -- where its text reads back as a form built by
appending the current `org-agents-exclude' -- the query inside that form
as well.  Two records, because a refusal keyed on the whole form alone is
lifted by the next edit to the exclusion: see `org-agents--base-query'.

The text is read back only when re-printing it reproduces the text
exactly, so what is refused is a form this package itself printed and not
whatever a hand-edited entry happens to parse as.  A legacy entry carries
no text at all, and is refused as the one hash it is."
  (let* ((text (org-agents--approval-text entry))
         (form (and text
                    (ignore-errors
                      (let ((parsed (car (read-from-string text))))
                        (and (equal (org-agents--query-text parsed) text)
                             (list parsed))))))
         (base (and form (org-agents--base-query (car form)))))
    (if (and form (not (equal base (car form))))
        (list entry (cons (org-agents--query-hash base)
                          (org-agents--query-text base)))
      (list entry))))

(defvar-keymap org-agents-approvals-mode-map
  :doc "Keymap for `org-agents-approvals-mode'."
  "d" #'org-agents-approvals-revoke
  "r" #'org-agents-approvals-refuse
  "u" #'org-agents-approvals-unrefuse)

(define-derived-mode org-agents-approvals-mode tabulated-list-mode "Approvals"
  "Major mode for the listing `org-agents-list-approvals' shows.

Each row is one remembered decision: what state it is in, the first
twelve characters of its hash, and the query text that hash covers.  A
row written by a version that recorded no text says so rather than
showing an empty cell.  A row reading `approved (session)' was approved at
a prompt and not saved, so it lasts until Emacs is restarted; it is
listed, and revocable, exactly like a saved one.

\\<org-agents-approvals-mode-map>\
\\[org-agents-approvals-revoke] forgets the approval on this line, here
and on disk; \\[org-agents-approvals-refuse] turns it into a refusal,
which no later approval can undo; \\[org-agents-approvals-unrefuse] lifts
a refusal, returning the query to needing approval rather than to having
it; \\[tabulated-list-revert] rereads all three records."
  (setq tabulated-list-format [("State" 18 t) ("Hash" 14 t) ("Query" 0 t)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'org-agents--approvals-refresh nil t)
  (tabulated-list-init-header))

(defun org-agents-approvals-revoke ()
  "Forget the approval on this line, in this session and on disk.
Works on a session-only approval as well as a saved one -- there was no
other way back from one of those short of restarting Emacs."
  (interactive nil org-agents-approvals-mode)
  (pcase-let ((`(,var . ,hash) (org-agents--approvals-at-point)))
    (when (eq var 'org-agents-refused-queries)
      (user-error "org-agents: this line is a refusal; `u' lifts one"))
    (org-agents--approvals-forget var hash)
    (org-agents--approvals-redisplay)))

(defun org-agents-approvals-refuse ()
  "Refuse the query on this line, however it was approved before.
The approval is forgotten, the session copy with it, and the entry --
hash and text together -- is recorded as a refusal, which the gate
consults before it consults anything else.  Where the form carries the
current `org-agents-exclude', the query inside it is recorded too, so
that editing the exclusion afterwards cannot lift the refusal."
  (interactive nil org-agents-approvals-mode)
  (pcase-let ((`(,var . ,hash) (org-agents--approvals-at-point)))
    (when (eq var 'org-agents-refused-queries)
      (user-error "org-agents: this line is already a refusal"))
    (let ((entry (org-agents--approval-entry
                  hash (org-agents--approvals-entries var))))
      (org-agents--approvals-forget var hash)
      (org-agents--persist-approvals
       'org-agents-refused-queries
       (append (org-agents--refusal-records entry)
               org-agents-refused-queries)))
    (org-agents--approvals-redisplay)))

(defun org-agents-approvals-unrefuse ()
  "Lift the refusal on this line.
The query goes back to needing approval, not to having it: lifting a
refusal is not the same as saying yes.  A refusal list with no way out
would be a trap."
  (interactive nil org-agents-approvals-mode)
  (pcase-let ((`(,var . ,hash) (org-agents--approvals-at-point)))
    (unless (eq var 'org-agents-refused-queries)
      (user-error "org-agents: this line is an approval; `d' forgets one"))
    (org-agents--approvals-forget var hash)
    (org-agents--approvals-redisplay)))

;;;###autoload
(defun org-agents-list-approvals ()
  "List every form this package remembers being told to run, or not to run.
Each row carries the query text its hash covers, so a remembered decision
can be read instead of guessed at, and the listing's own keys revoke one,
refuse one, or lift a refusal.  See `org-agents-approvals-mode'."
  (interactive)
  (let ((buffer (get-buffer-create org-agents--approvals-buffer)))
    (with-current-buffer buffer
      (org-agents-approvals-mode)
      (org-agents--approvals-refresh)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

;;;; Splitter

;; The splitter picks out the conjuncts of an expanded query that a
;; ripgrep prefilter may answer over the raw bytes of the corpus.  There
;; is exactly one evaluation engine -- org-ql, against live buffers -- so
;; the prefilter only ever chooses which FILES that engine opens, and a
;; conjunct may be pushed only when the files ripgrep answers with are
;; provably a SUPERSET of the files org-ql's own matches would come from.
;; Whatever cannot be proven a superset stays residual, at the price of a
;; wider candidate set.
;;
;; Narrowing too little is merely slow.  Narrowing too much is a wrong
;; answer with no error at all.  So the analysis is in two layers on
;; purpose: this one decides WHICH conjuncts are superset-safe, in an
;; abstract vocabulary -- `(property NAME)', `(property NAME VALUE)',
;; `(scheduled)', `(deadline)', `(closed)', `(heading LITERAL...)' -- and
;; the emitter in the next section decides how ripgrep expresses one, or
;; declines to, which only widens.  Each layer states its own superset
;; argument, row by row and pattern by pattern.
;;
;; Soundness evidence: the `org-agents-test-rg-covers-*' tests, each of
;; which names the fixture file it loses under the mutation it guards
;; against, and README.md's push-down table.  Not docs/design.md's
;; table, which is the removed database's -- see the Commentary.

(defun org-agents--heading-literals-p (strings)
  "Non-nil when every string in non-empty STRINGS may be sought in a raw line.
A `heading' argument is ALWAYS a literal: org-ql's normalizer is
`(heading-regexp ,@(mapcar #\\='regexp-quote args))', which quotes every
argument unconditionally, so there is no such thing as a `heading'
argument that is a regexp.  Testing for regexp syntax here would be
testing a property org-ql guarantees, and the emitter escapes the whole
Rust metacharacter set anyway -- it carries `a.b+c(d)[e]' correctly on
the property-value path.  This predicate therefore refuses ONE
character, and refuses it for a reason that has nothing to do with
regexps.

The reason is `]'.  org-ql matches each literal against
`(org-get-heading t t)' while the emitter searches the raw heading LINE,
so pushing a literal is sound exactly when a literal org-ql matched is
also in the raw line.  `org-get-heading' does not return a slice of the
line: it reassembles it from `org-complex-heading-regexp''s groups,
`mapconcat'ed with a single space.  With NO-TAGS and NO-TODO the result
is the priority cookie, then one space, then the title.  Every separator
the regexp allows before the todo, priority and title groups is ` +' --
literal SPACES, never a tab -- so each group is preceded in the line by
at least one real space, and the only substring of the reassembled
heading that the line need not spell is one that crosses the junction
between the cookie and the title.  The cookie is
`\\[#\\(?:[A-Z]\\|[0-9]\\|[1-5][0-9]\\|6[0-4]\\)\\]', which always ends
in `]', so every such substring holds a `]' -- while a substring that
begins at the injected space is spelled by the line, the run of spaces
there being non-empty.

Measured, not merely argued.  Over 10,368 generated heading lines --
crossing star depth, one-and-two-space indents, TODO/DONE/COMMENT
keywords, present and absent priority cookies, five whitespace runs
before the title including tab-bearing ones, four titles, three trailing
runs and tags -- every one of the 482,148 substrings of
`(org-get-heading t t)' holding no `]' is a case-insensitive substring of
its raw line: zero violations.  The witness for why the guard cannot
simply be dropped is `* [#A]   Review', whose heading is `[#A] Review':
the literal `[#A] Review' is matched by org-ql and appears nowhere in
the line.

What this replaced refused `] [ * + ? ^ $ \\ . { } |', of which only `]'
carries an argument.  Measured over the author's own corpus, that cost
narrowing on about one heading title in four -- 9,883 of 40,891
distinct titles -- for a whole-corpus scan the package measures in
minutes against seconds prefiltered."
  (and strings
       (cl-every (lambda (s)
                   (and (stringp s) (not (string-search "]" s))))
                 strings)))

;; A note on org-ql's `property', because its docstring reads the other
;; way and the mistake is easy to make twice.  The docstring says the
;; inheritance default is `org-use-property-inheritance'; the normalizer
;; applies that default only to a `property' form that carries an extra
;; plist.  The plain `(property NAME)' and `(property NAME VALUE)' forms
;; -- the only two this splitter pushes -- leave `inherit' at its nil
;; default and read the entry's own drawer, which is exactly what a
;; `:NAME:' line in the file is.  Measured twice.  Do not write "plain
;; forms inherit" anywhere: it is false.
(defun org-agents--property-inherits-p (name)
  "Non-nil when property NAME might be inherited at match time.
Mirrors `org-property-inherit-p', including its case-insensitive
reading of a list.  An invalid setting of
`org-use-property-inheritance' counts as inheriting, the answer that
pushes less.  Refusing to push for such a name is a conservative guard
rather than a correctness requirement; the `property' row of
`org-agents--pushdown-fns' records why."
  (pcase org-use-property-inheritance
    ('nil nil)
    ('t t)
    ((pred stringp) (string-match-p org-use-property-inheritance name))
    ((pred listp) (member-ignore-case name org-use-property-inheritance))
    (_ t)))

(defun org-agents--property-pushable-p (name)
  "Non-nil when NAME is an ordinary drawer property that cannot inherit.
`org-entry-get' answers a special property such as CATEGORY or DEADLINE
from the entry's structure or its file, and no drawer anywhere holds a
`:TODO:' or a `:CATEGORY:' line for it, so pushing one as a property
test would return no files at all for a query that matches thousands.
The refused set is `(cons \"CATEGORY\" org-special-properties)', which
is exactly the set `org-entry-get' special-cases in its own first
clause; the two lists are aligned by construction.

A name in `org-use-property-inheritance' is refused as well.  That is a
conservative guard rather than a correctness requirement; the `property'
row of `org-agents--pushdown-fns' records why."
  (and (stringp name)
       (not (member-ignore-case name (cons "CATEGORY" org-special-properties)))
       (not (org-agents--property-inherits-p name))))

(defun org-agents--property-value-pushable-p (name value)
  "Non-nil when VALUE for property NAME is spelled by ONE drawer line.
`org-entry-get' builds a value by joining the `:NAME:' line with every
`:NAME+:' line, separated by `org--property-get-separator'.  A value
assembled from more than one line is therefore spelled on NO line of the
file at all, and a line-oriented matcher such as ripgrep cannot find it:
pushing it would empty the candidate set rather than narrow it.

A VALUE that does not contain the separator was assembled from exactly
one line.  `org-entry-get' drops only a MISSING piece from its list, not
an empty one, so two pieces always put a separator between them --
measured: `:FOO:' with no value followed by `:FOO+: bar' yields
\" bar\", leading space and all.

Two shapes make that argument unavailable and are refused:

An empty separator.  Measured: with `org-property-separators' bound to
`((\"P\") . \"\")', `:P: al' plus `:P+: pha' answers \"alpha\" -- and
every string contains the empty separator, so the test above cannot
distinguish one line from two.

An empty VALUE.  `org-entry-get' answers \"\" for a property that is
present and empty, whose line is spelled `:NAME:' with nothing after the
colon -- which the value pattern cannot match, because it demands
`[ \\t]+' there.

Note what this rule is NOT: a test for whitespace.  With the default
separator the two coincide, which is why the whitespace test served
until now.  But measured with `org-property-separators' bound to
`((\"P\") . \"/\")', `:P: al' plus `:P+: pha' answers \"al/pha\" -- a
value holding no whitespace that no single line spells.  The whitespace
test would push it and lose the file."
  (let ((sep (org--property-get-separator name)))
    (and (stringp value)
         (not (string-empty-p value))
         (stringp sep)
         (not (string-empty-p sep))
         (not (string-search sep value)))))

;; Each classifier returns the abstract conjunct to push for a form, or
;; nil to leave it residual.  Every row states why the files its conjunct
;; selects are a superset of the files org-ql will match in.
(defconst org-agents--pushdown-fns
  (list
   (cons 'property
         (lambda (form)
           ;; Inheriting names: push nothing.  org-ql applies the
           ;; `org-use-property-inheritance' default only to `property'
           ;; forms that carry an extra plist; the plain (property NAME)
           ;; and (property NAME VALUE) forms this classifier pushes
           ;; leave `inherit' at its nil default, so org-ql reads the
           ;; entry's own drawer only -- and a drawer line is exactly
           ;; what the pattern looks for.  Refusing to push for a name in
           ;; `org-use-property-inheritance' is therefore not required
           ;; for correctness; it is a conservative guard that only
           ;; widens the candidate set and never drops a match.  Keep it
           ;; anyway: org-ql's `property' docstring reads the other way,
           ;; and if a future org-ql made that true of the plain forms,
           ;; this guard is the only thing between that change and a
           ;; silent wrong answer.
           (pcase form
             ;; Existence.  A non-nil `org-entry-get' with `inherit' nil
             ;; requires at least one line in the file matching
             ;; `org-property-re' whose key upcases to NAME or NAME+, and
             ;; every such line is what the pattern matches.
             (`(property ,(and name (pred org-agents--property-pushable-p)))
              `(property ,name))
             ;; Equality: org-ql's body is `string-equal' against the
             ;; entry's own value.  A form carrying `:inherit' says for
             ;; itself whether to inherit, and has an arity neither
             ;; pattern matches, so it pushes nothing at all.
             (`(property ,(and name (pred org-agents--property-pushable-p))
                         ,(and val (pred stringp)))
              (if (org-agents--property-value-pushable-p name val)
                  `(property ,name ,val)
                ;; The value spans two lines, or cannot be argued not
                ;; to.  Existence is wider, and wider is sound.
                `(property ,name)))
             (_ nil))))
   (cons 'property-ts
         (lambda (form)
           (pcase form
             ;; A date match on the value implies the property is there.
             (`(property-ts ,(and name (pred org-agents--property-pushable-p))
                            . ,_)
              `(property ,name))
             (_ nil))))
   ;; Planning stamps: the head alone decides the conjunct, and every
   ;; argument is dropped.  All three predicates share
   ;; `org-ql--predicate-ts''s body, whose every branch begins with a
   ;; `re-search-forward' for the keyword followed by an opening bracket,
   ;; so org-ql cannot match without that text being in the file.
   ;; Dropping the bounds drops a CONJUNCT of org-ql's condition and
   ;; never adds one: "there is a stamp in the period" implies "there is
   ;; a stamp".  So `(deadline)', `(deadline :from F :to T)',
   ;; `(deadline 7)' and `(deadline auto)' all push the same thing, all
   ;; soundly -- which is a coverage GAIN: the last two pushed nothing at
   ;; all while a date had to be serialized for a second engine to read.
   (cons 'scheduled (lambda (form) (list (car form))))
   (cons 'deadline (lambda (form) (list (car form))))
   (cons 'closed (lambda (form) (list (car form))))
   (cons 'heading
         (lambda (form)
           (pcase form
             ;; org-ql normalizes `heading' to `heading-regexp' with
             ;; every argument `regexp-quote'd -- so a `heading'
             ;; argument is always a literal, never a regexp -- and
             ;; matches each of them against `(org-get-heading t t)'
             ;; with `case-fold-search' bound to t.  That reassembled
             ;; title is spelled by the raw heading line except across
             ;; the junction between a priority cookie and the title,
             ;; and every substring crossing that junction holds the
             ;; `]' which `org-agents--heading-literals-p' refuses --
             ;; see its docstring for the argument and the measurement.
             ;; So a literal org-ql matched is in the raw line, which
             ;; begins with `*' at column 0, which is what the pattern
             ;; anchors on.
             (`(heading . ,(and strs (pred org-agents--heading-literals-p)))
              `(heading ,@strs))
             (_ nil)))))
  "Alist of predicate head to superset-safe abstract conjunct, or nil.")

(defun org-agents--prefilter-conjuncts (query)
  "The superset-safe conjuncts of expanded QUERY, as a list.
Only top-level `and' conjuncts -- or the whole query, when it is a single
pushable predicate -- are considered, in query order.  A conjunct under
`or' or `not', and every nested query, is residual by omission, which
widens.  The list is empty when nothing pushes, and the caller reads that
as \"this query offers no narrowing\" rather than as an empty answer."
  (let ((conjuncts (if (eq (car-safe query) 'and) (cdr query) (list query))))
    (delq nil
          (mapcar (lambda (conjunct)
                    (when-let* ((fn (alist-get (car-safe conjunct)
                                               org-agents--pushdown-fns)))
                      (funcall fn conjunct)))
                  conjuncts))))

;;;; Prefilter

;; The emitter, and the subprocess.  Everything here answers one
;; question: which files under a root could possibly hold a match, given
;; a conjunct the splitter has already proven superset-safe.  A pattern
;; that cannot be written soundly is not written at all -- the conjunct
;; then contributes no narrowing, which is slow and correct rather than
;; fast and wrong.
;;
;; Three facts about ripgrep that the patterns and the argument vector
;; are built around, each measured rather than read off a manual page:
;;
;;   - Its regexp dialect is the Rust `regex' crate's, whose
;;     metacharacter set is not Emacs's.  `(' and `)' are literal in an
;;     Emacs regexp and grouping in a Rust one, so `regexp-quote' leaves
;;     a heading literal `Ship it (finally)' unprotected and the pattern
;;     then demands the text `Ship it finally'.
;;   - In its default Unicode mode `.' matches a CODEPOINT, so `.*'
;;     cannot cross an invalid UTF-8 byte.  A pure-ASCII literal after a
;;     latin-1 character on the same heading line is missed by
;;     `^\*+.*LIT' and found by `^\*+(?-u:.)*LIT'.
;;   - Its exit status is 0 for a match, 1 for no match, and 2 for an
;;     error -- and an error can arrive WITH a partial answer printed, so
;;     status 2 must discard whatever came with it.

(defcustom org-agents-prefilter 'auto
  "Whether to narrow an unbounded scope's files with ripgrep before evaluating.
Evaluation is always org-ql's, against live buffers.  A prefilter only
chooses which FILES org-ql opens, so it can never change an answer --
but without one, a scope with no bound on what it holds is read by
opening everything it turns out to hold.

Measured on the author's corpus, `(and (todo) (property \"NEXT_REVIEW\"))'
over an `active' scope: one ripgrep run narrows 3,634 files to 309 in
half a second, and org-ql over those 309 finishes in ten seconds with
764 matches over 316 buffers.  With no prefilter at all the same query
had not finished after NINE MINUTES.  Do not budget the unprefiltered
path in seconds: it is not a slower way to the same place within one
attention span, it is the thing this option exists to avoid.

Only `active', `all' and a directory scope are ever prefiltered.
`agenda' and an explicit file list name their files and are always read
live, where a prefilter is pure overhead: measured over the eight
largest files of that corpus, 8.9 MB and 373 matches, such an update
costs 0.03 to 0.05 seconds and spawns nothing, while one ripgrep run
over the corpus costs 0.10 to 0.45.

  `auto'     Use ripgrep when `org-agents-rg-executable' is found and
             the query offers a conjunct to push.  Otherwise scan live,
             with one message naming the number of files, so that the
             slowness is explained rather than mysterious.  The default.
  `require'  Refuse an unbounded scope that cannot be narrowed, with a
             `user-error' naming the scope and the reason, rather than
             scanning it live.  For someone who would rather be told
             that an agent cannot be answered affordably than wait for a
             live walk of the whole corpus.
  nil        Never run ripgrep; read every scope live.

Risky: this chooses whether a subprocess is spawned at all."
  :type '(choice (const :tag "Use ripgrep when it is available" auto)
                 (const :tag "Require ripgrep; refuse a scope without it"
                        require)
                 (const :tag "Never prefilter" nil))
  :risky t
  :group 'org-agents)

(defcustom org-agents-rg-executable "rg"
  "Name or path of the ripgrep executable used to narrow candidate files.
Looked up with `executable-find', so a bare name is resolved against
`exec-path'.  ripgrep 13 or later is wanted: the prefilter passes
`--crlf', without which a value pattern cannot match in a file with CRLF
line endings.  Every flag was verified against 15.2.0 and against no
other version; 13 is named as a round, safely old floor.

Risky: this names a program that will be `call-process'ed."
  :type 'string
  :risky t
  :group 'org-agents)

(defconst org-agents--rg-meta-characters "\\.+*?()|[]{}^$#&-~"
  "The characters `regex_syntax::escape' escapes, and only those.
Escaping anything else is not merely unnecessary, it is dangerous: `\\<'
is a word-start ASSERTION in the Rust regexp crate, so escaping a `<'
changes the pattern's meaning rather than protecting it.  Measured:
`a\\<b' finds nothing in a line reading `a<b', while `a\\-b', `a\\#b',
`a\\&b' and `a\\~b' all match their literal.")

(defconst org-agents--rg-literal-re "\\`[ -~]+\\'"
  "A literal that may be pushed: non-empty, and printable ASCII throughout.
One rule closes four holes at once.

Encoding.  ripgrep decodes as UTF-8; Emacs may decode an Org file as
latin-1 through a coding cookie or `file-coding-system-alist'.
Measured: a latin-1 file holding `* Cafe Review' -- with the `e'
accented -- matches the ASCII pattern `Caf' and does NOT match the UTF-8
pattern for the accented spelling.  No flag fixes that: `--encoding' is
one global setting and a corpus is mixed.

Newlines, tabs and control characters.  ripgrep rejects a pattern
holding a newline and exits 2, which would report a harmless query as a
prefilter failure.  org-ql could never match such a literal against a
one-line heading anyway, so refusing it loses nothing.

The empty literal.  `(heading \"\")' matches every entry in org-ql, and
an empty pattern matches every file, so pushing it is sound and useless.

Note what this rule is NOT justified by: case folding.  That was checked
and is safe for non-ASCII too.  Measured exhaustively over
#x0-#x10FFFF, no non-ASCII character is case-equivalent to an ASCII
letter under Emacs's default case table, so for an ASCII pattern Emacs's
fold classes are exactly {X,x}, which `--ignore-case' always covers; and
of the 1,405 non-ASCII pairs Emacs does equate, `rg -i' matched all
1,405.")

(defconst org-agents--rg-name-re "\\`[!-9;-~]+\\'"
  "A property name that may be pushed.
Printable ASCII as `org-agents--rg-literal-re' requires, less the space
and the colon: an Org property key is `\\S-+' with no colon in it, so a
name holding either is no key and matches no drawer line.")

(defun org-agents--rg-quote (string)
  "Return STRING as a literal in ripgrep's Rust regexp dialect.
Text properties are dropped here rather than by a walk over the whole
conjunct list: a literal lifted out of an Org buffer carries them, and
this is the one place a literal becomes something a subprocess sees."
  (mapconcat (lambda (c)
               (if (string-search (char-to-string c)
                                  org-agents--rg-meta-characters)
                   (string ?\\ c)
                 (string c)))
             (substring-no-properties string) ""))

(defun org-agents--rg-literal-p (string)
  "Non-nil when STRING may be pushed as a literal.
See `org-agents--rg-literal-re' for what the answer rests on."
  (and (stringp string) (string-match-p org-agents--rg-literal-re string)))

(defun org-agents--rg-name-p (string)
  "Non-nil when STRING may be pushed as a property name.
See `org-agents--rg-name-re'."
  (and (stringp string) (string-match-p org-agents--rg-name-re string)))

(defconst org-agents--rg-planning-patterns
  '((scheduled . "SCHEDULED:[ \\t]*<")
    (deadline . "DEADLINE:[ \\t]*<")
    (closed . "CLOSED:[ \\t]*\\["))
  "One ripgrep pattern per planning keyword, independent of every bound.
Deliberately NOT anchored to the start of the line.  Measured: all three
keywords may share one planning line, in any order, so `^[ \\t]*DEADLINE:'
misses `CLOSED: [..] DEADLINE: <..>' -- an under-match.  Org's own
`org-planning-line-re' also allows the line to be indented, which is why
even an anchored form would need `[ \\t]*'.

The opening bracket is not decoration.  An active Org timestamp begins
with `<' and an inactive one with `[', and org-ql's own regexps require
the same character, so demanding it narrows for free: measured over
3,669 corpus files, the bare keywords select 216, 91 and 18 files while
these patterns select 203, 76 and 3.")

(defun org-agents--rg-property-pattern (name)
  "The ripgrep pattern for a `:NAME:' drawer line.
`\\+?' admits the accumulating spelling, and it is exact rather than
generous: `org--property-local-values' looks up `:NAME' and `:NAME+' and
nothing else.  It is also REQUIRED.  Measured: an entry whose drawer
holds only `:NEXT_REVIEW+: plusvalue' answers `org-entry-get' with
\"plusvalue\" and org-ql matches `(property \"NEXT_REVIEW\")', so a
pattern anchored on `:NEXT_REVIEW:' alone misses the file.

`^[ \\t]*' rather than `^' because `org-property-re' allows leading
whitespace and Org reads a tab-indented property line inside an indented
drawer.  Case is left to `--ignore-case': measured both ways, a drawer
key `:next_review:' answers a query for \"NEXT_REVIEW\" and the
reverse."
  (concat "^[ \\t]*:" (org-agents--rg-quote name) "\\+?:"))

(defun org-agents--rg-patterns (conjunct)
  "The ripgrep patterns CONJUNCT compiles to, as a list of regexp strings.
Zero, one, or several -- several only for a multi-literal `heading', and
those are INTERSECTED by `org-agents--rg-files' rather than combined
into one pattern, because org-ql requires every literal in ONE heading
and that implies a heading line for each of them, in any order and on
any line.

Returns nil when CONJUNCT cannot be expressed soundly.  That is not a
failure: the conjunct then contributes no narrowing and stays residual
for org-ql, which is the widening direction.

Pure: nothing here spawns anything."
  (pcase conjunct
    (`(property ,name)
     (when (org-agents--rg-name-p name)
       (list (org-agents--rg-property-pattern name))))
    (`(property ,name ,value)
     (when (org-agents--rg-name-p name)
       (list (if (org-agents--rg-literal-p value)
                 ;; org-ql compared the whole value with `string-equal',
                 ;; and the splitter has established that the value is
                 ;; spelled by one line: the line's text with the leading
                 ;; `[ \t]+' consumed and the trailing `[ \t]*' excluded.
                 ;; `--ignore-case' makes this match MORE values than
                 ;; org-ql's case-sensitive comparison, which is the safe
                 ;; direction.
                 (concat (org-agents--rg-property-pattern name)
                         "[ \\t]+" (org-agents--rg-quote value) "[ \\t]*$")
               ;; A value ripgrep cannot carry: fall back to existence,
               ;; which is wider and always sound.
               (org-agents--rg-property-pattern name)))))
    (`(,(and head (or 'scheduled 'deadline 'closed)))
     (list (alist-get head org-agents--rg-planning-patterns)))
    (`(heading . ,literals)
     (delq nil
           (mapcar (lambda (literal)
                     (when (org-agents--rg-literal-p literal)
                       ;; `(?-u:.)' rather than `.': in ripgrep's default
                       ;; Unicode mode `.' matches a codepoint and cannot
                       ;; cross an invalid UTF-8 byte, so `^\\*+.*Review'
                       ;; misses a latin-1 heading whose accented
                       ;; character precedes the literal.  Measured; and
                       ;; `[^\\n]*' does not fix it either.
                       (concat "^\\*+(?-u:.)*"
                               (org-agents--rg-quote literal))))
                   literals)))
    (_ nil)))

(defun org-agents--rg-args (pattern root)
  "The ripgrep argument vector for PATTERN under ROOT.
Named as a function of its own so that a test can pin it: five of the
under-matches measured while this backend was designed were a missing
flag, not a wrong pattern.

  `--files-with-matches'  only file names are wanted.
  `--null'                paths are NUL-terminated, so a newline in a
                          file name cannot split one path into two.
  `--ignore-case'         org-ql's `heading' binds `case-fold-search' to
                          t inside its own body, and `org-entry-get' is
                          case-insensitive over property names.
  `--text'                an .org file holding a NUL is still an Org
                          file to Emacs; without this ripgrep stops at
                          the NUL and reports nothing for that file.
  `--crlf'                without it `$' cannot match before a CRLF line
                          ending and the value pattern misses every CRLF
                          file.
  `--no-ignore'           ripgrep honours .gitignore by default and a
                          corpus is commonly a git repository, while
                          `directory-files-recursively' honours nothing.
  `--hidden'              ripgrep skips dot-files and dot-directories by
                          default; `directory-files-recursively'
                          descends into them.
  `--follow'              `directory-files-recursively' LISTS a symlink
                          to a file outside the tree and org-ql matches
                          through it, while ripgrep does not follow a
                          symlink found by traversal without this.  A
                          symlink loop makes ripgrep exit 2, which
                          abandons the prefilter for a live scan -- slow
                          and correct.
  `--iglob \\='*.org\\='       `directory-files-recursively' matches its
                          regexp with the ambient `case-fold-search',
                          which is t, so NOTES.ORG is in the base file
                          set.  `--glob' would not match it.

`--regexp' before the pattern so that a literal beginning with `-' -- a
heading such as `* -- notes' -- cannot be read as a flag, and `--'
before the root for the same reason.  One pattern per invocation:
ripgrep ORs several `--regexp' arguments, and every combination this
package needs is an AND."
  (list "--files-with-matches" "--null" "--ignore-case" "--text" "--crlf"
        "--no-ignore" "--hidden" "--follow" "--iglob" "*.org"
        "--regexp" pattern "--" root))

(defun org-agents--file-contents (file)
  "Return FILE's contents, trimmed, or an empty string if unreadable."
  (or (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (string-trim (buffer-string))))
      ""))

(defun org-agents--rg-paths (raw)
  "Split RAW, ripgrep's NUL-terminated stdout, into a list of file names.
RAW is read as BYTES and each path decoded with the file-name coding
system.  Decoding the whole stream with `coding-system-for-read' would
be decoding file NAMES with a coding system for file CONTENTS: on a
Darwin HFS+ volume `default-file-name-coding-system' is `utf-8-hfs',
which normalizes NFD to NFC, and a name decoded the other way would
neither `equal' nor share a `file-truename' with the name
`directory-files-recursively' produced.

A NUL cannot occur in a POSIX file name, so splitting on NUL is exact
and no quoting is involved.  An empty element -- or one still holding a
NUL after decoding -- is dropped, because `expand-file-name' signals on
such a string."
  (delq nil
        (mapcar (lambda (bytes)
                  (let ((name (decode-coding-string
                               bytes (or file-name-coding-system
                                         default-file-name-coding-system
                                         'utf-8))))
                    (unless (or (string-empty-p name)
                                (string-search "\0" name))
                      name)))
                (split-string raw "\0" t))))

(defun org-agents--rg-available-p ()
  "Non-nil when `org-agents-rg-executable' names a program that can be run.
A function of its own for two reasons.  It is the one place the option is
resolved against `exec-path', so a caller cannot accidentally test the
option's VALUE -- which is a bare name by default and always non-nil.
And a test that stubs the backend can stub this beside it, instead of
having to put a program on `exec-path' to be allowed to reach the stub."
  (and (executable-find org-agents-rg-executable) t))

(defun org-agents--rg-run (pattern root)
  "Files under ROOT whose text matches PATTERN, or the symbol `unavailable'.
Returns a LIST -- possibly the EMPTY list, which means \"ripgrep
answered, and no file matches\".  That is an answer, and the caller must
treat it as one: reporting it as a missing prefilter is the defect this
backend exists to remove.  Only the symbol `unavailable' means \"no
answer\".  Callers test with `listp', which is exact: `(listp nil)' is t
and `(listp \\='unavailable)' is nil.

The status test is `(eq code 0)' and `(eq code 1)', never `(> code 1)':
`call-process' answers with a STRING such as \"Killed: 9\" when the
process dies on a signal, and a non-integer must fall to the failure
branch rather than slip past a numeric comparison.

Status 2 discards whatever was printed.  Measured: with one unreadable
file among two, ripgrep prints the readable match, writes `Permission
denied' to stderr, AND exits 2 -- so the printed answer is missing a
file, and a partial answer is exactly the unsound direction.

Never signals an error.  A `quit' from C-g during the synchronous call
still escapes, as it must.  Spawned from `temporary-file-directory',
because a `default-directory' that has been deleted makes `call-process'
signal and a remote one would run the binary on another host, against
files that are not the corpus.

RIPGREP_CONFIG_PATH is UNSET for the child, and that is a soundness
requirement rather than tidiness.  ripgrep prepends every argument in
the file that variable names to its command line, and the vector
`org-agents--rg-args' builds overrides only the flags it repeats:
`--max-depth', `--max-filesize', `--pre', `--encoding' and `--glob' are
not among them.  Measured, with a config file holding one line: under
`--max-depth=1' a matching file one directory down is not reported, and
under `--max-filesize=10' nothing is reported at all and ripgrep exits
1 -- which this function correctly reads as \"an answer, and no file
matches\", so every agent renders nothing with no error and no message.
A file the prefilter does not report is a file org-ql never opens, so a
personal ripgrep default -- the mechanism ripgrep's own README
recommends for one -- would silently empty an unbounded agent.

Unset rather than `--no-config': `org-agents-rg-executable' names
ripgrep 13 as the supported floor, an unknown flag there exits 2, and an
entry of `process-environment' holding no `=' removes the variable for
the child on every Emacs this package supports."
  (condition-case err
      (let ((stderr-file (make-temp-file "org-agents-rg-stderr")))
        (unwind-protect
            (with-temp-buffer
              ;; `default-directory' is buffer-local, so this must be
              ;; bound with the temp buffer current to have any effect on
              ;; the process `call-process' spawns.
              (let* ((default-directory temporary-file-directory)
                     (coding-system-for-read 'binary)
                     (process-environment
                      (cons "RIPGREP_CONFIG_PATH" process-environment))
                     (code (apply #'call-process org-agents-rg-executable
                                  nil (list (current-buffer) stderr-file)
                                  nil (org-agents--rg-args pattern root))))
                (cond
                 ((eq code 1) nil)      ; an answer: no file matches
                 ((eq code 0) (org-agents--rg-paths (buffer-string)))
                 (t
                  (let ((stderr (org-agents--file-contents stderr-file)))
                    (message "org-agents: %s exited %s: %s"
                             org-agents-rg-executable code
                             (if (string-empty-p stderr)
                                 (string-trim (buffer-string))
                               stderr)))
                  'unavailable))))
          (ignore-errors (delete-file stderr-file))))
    (error
     (message "org-agents: %s failed: %s"
              org-agents-rg-executable (error-message-string err))
     'unavailable)))

(defun org-agents--intersect-files (a b)
  "The members of A that B holds too, in A's order.
Compared with `equal' rather than by truename: every pattern is run
against the same root and ripgrep prints paths built from that root's
spelling, so plain string equality is exact here.  The truename
comparison is needed once only, against the scope's own file list --
`org-agents--same-files'."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (file b) (puthash file t seen))
    (cl-remove-if-not (lambda (file) (gethash file seen)) a)))

(defun org-agents--rg-files (conjuncts root)
  "Candidate files under ROOT for CONJUNCTS.
Three kinds of answer, and conflating any two of them is a bug:

  a LIST          ripgrep answered.  The empty list is such an answer,
                  and it means no file can match.
  `unavailable'   ripgrep could not be run, or failed.  One failed run
                  poisons the whole prefilter: an intersection missing
                  one of its terms would be WIDER, and therefore sound,
                  but a partial answer from a broken tool is not a thing
                  to build on and the live fallback is merely slower.
  t               no conjunct offered a pattern, so nothing was narrowed
                  at all.  Distinct from the empty list, which is the
                  narrowest possible answer.

Each pattern is a separate invocation and the resulting file sets are
INTERSECTED.  Independent runs rather than clever reuse, because they
are measured to be cheap: a whole-corpus run costs 0.10 seconds for a
property pattern and 0.45 for a heading one, against the ten seconds
org-ql then spends over the files one such run selects.  As soon as the
running intersection is empty the walk stops -- there is nothing left to
intersect, and in particular the scope's base files must not be gathered
to intersect against, which is the expensive thing the prefilter exists
to avoid."
  (let ((candidates t)
        (failed nil))
    (catch 'org-agents--rg-done
      (dolist (conjunct conjuncts)
        (dolist (pattern (org-agents--rg-patterns conjunct))
          (let ((answer (org-agents--rg-run pattern root)))
            (unless (listp answer)
              (setq failed t)
              (throw 'org-agents--rg-done nil))
            (setq candidates
                  (if (eq candidates t)
                      answer
                    (org-agents--intersect-files candidates answer)))
            (when (null candidates)
              (throw 'org-agents--rg-done nil))))))
    (if failed 'unavailable candidates)))

;;;; Collection

;; Reading an agent turns the entry's `AGENT_*' properties into a plist,
;; and collecting runs the resulting query.  Every one of those
;; properties is text out of a file, so a value that cannot be used is
;; diagnosed here rather than left to fail, or to quietly do nothing, at
;; match time.

(defcustom org-agents-files '("~/org/agents.org")
  "Where `org-agents-update-all' looks for agents.
A list of files and directories, or the symbol `agenda'.

Risky: it says which files `org-agents-update-all' opens and WRITES --
an update rewrites each agent's aliases."
  :type '(choice (const agenda) (repeat file)) :risky t :group 'org-agents)

(defconst org-agents--corpus-scopes '(active all)
  "Scope names that stand for the corpus rather than for named files.")

(defconst org-agents--scope-names '("agenda" "active" "all")
  "The `:AGENT_SCOPE:' values read as symbols.
Any other bare value names a directory, relative to `org-directory'.")

(defconst org-agents--known-views '(children list table)
  "The `:AGENT_VIEW:' values that name a renderer.
Every view but `table' renders as a list, so an unknown one would render
the wrong view rather than none: `tabel' would quietly come out as a
list, and a view this package simply does not have would look exactly
like a view whose renderer did nothing.")

(defconst org-agents--element-sorts '(date todo priority reverse)
  "The `:AGENT_SORT:' methods org-ql can sort matched elements by.
The `org-agents--row-sorts' forms sort rendered rows of strings
instead, so the renderer -- not org-ql -- answers for those.")

(defconst org-agents--row-sorts '(column ts-column)
  "The `:AGENT_SORT:' heads that order rendered table rows.
Their argument is a column number, 1-indexed over `:AGENT_COLUMNS:'.
org-ql answers for the methods in `org-agents--element-sorts' instead,
which order matched elements, before any of them is rendered.")

(defun org-agents--element-sort (sort)
  "Return SORT if org-ql can sort elements by it, else nil.
One method or a list of them, since `reverse' is only meaningful
alongside another; a table's sort form is neither, and handing it to
org-ql would raise an error over a view that is not org-ql's business."
  (and sort (cl-subsetp (ensure-list sort) org-agents--element-sorts) sort))

(defun org-agents--sort-ok-p (sort)
  "Non-nil when SORT names an ordering some view can actually apply.
Either a method org-ql sorts elements by, or one of the row-sort forms a
table orders its rendered rows with.  Nothing else orders anything.

A row sort must name its column with a number, which is checked here
because it is wrong whatever the table turns out to hold.  WHICH number
is `org-agents--sort-column''s to answer, since only it knows how many
columns there are."
  (or (null sort)
      (and (memq (car-safe sort) org-agents--row-sorts)
           (integerp (cadr sort))
           (null (cddr sort)))
      (and (org-agents--element-sort sort) t)))

(defun org-agents--read-sort (sort)
  "Return SORT, having checked that something can order by it.
A misspelling was the last agent property left to fail quietly: neither
`org-agents--element-sort' nor `org-agents--check-row-sort' answers for a
sort that is simply not a sort, so `:AGENT_SORT: dtae' rendered unsorted
and said nothing -- which reads exactly like a sort that had no effect
because the matches were already in that order."
  (unless (org-agents--sort-ok-p sort)
    (user-error
     "org-agents: cannot sort by `%S'; expected %s, a list of those, or (column N)/(ts-column N)"
     sort (mapconcat #'symbol-name org-agents--element-sorts ", ")))
  sort)

(defun org-agents--check-row-sort (agent)
  "Signal a `user-error' when AGENT sorts rows in a view that has none.
The `org-agents--row-sorts' forms order the rendered rows of a table,
and a list or a set of child headings has no rows to order.  org-ql
refuses the form as well, so an unremarked mismatch would order nothing
at all -- exactly what an agent whose sort simply had no effect looks
like."
  (when (and (memq (car-safe (plist-get agent :sort)) org-agents--row-sorts)
             (not (eq (plist-get agent :view) 'table)))
    (user-error "org-agents: %S sorts table rows, but the view is `%s'"
                (plist-get agent :sort) (plist-get agent :view))))

(defun org-agents--entry-get (property)
  "Return PROPERTY of the entry at point, or nil when it has no value.
A property line written with nothing after it reads as the empty
string, which `read-from-string' cannot read at all and which
`expand-file-name' resolves to the whole of `org-directory'.  Written
but empty and not written at all mean the same thing here."
  (when-let* ((value (org-entry-get nil property)))
    (unless (string-blank-p value) value)))

(defun org-agents--read-sexp (source value)
  "Read VALUE, which SOURCE supplied, as a Lisp form.
SOURCE names where the text came from, and is written into the diagnosis
as given: `:AGENT_QUERY:' for an agent property, `:query' for a dynamic
block parameter, `the query' for what was typed at a prompt.  Spelling it
here rather than wrapping it in colons is what keeps a prompt from being
reported as a property that does not exist.

A malformed value reaches `read-from-string' as an end of file, which
`org-agents-update-all' cannot tell from a bug in this package: it
answers for one agent at a time by catching `user-error', and anything
else aborts the whole run."
  (condition-case err (car (read-from-string value))
    (error (user-error "org-agents: unreadable %s `%s': %s"
                       source value (error-message-string err)))))

(defun org-agents--read-scope (value)
  "Read the `:AGENT_SCOPE:' property VALUE, which may be nil."
  (cond
   ((null value) 'agenda)
   ((string-prefix-p "(" value) (org-agents--read-sexp ":AGENT_SCOPE:" value))
   ;; Only the three corpus names are symbols.  Interning every bare
   ;; value would leave no way to write the directory scope the design
   ;; calls for, and no `stringp' scope could ever reach
   ;; `org-agents--scope-root'.
   ((member value org-agents--scope-names) (intern value))
   (t value)))

(defun org-agents--read-view (value)
  "Read the `:AGENT_VIEW:' property VALUE, which may be nil.
A view naming no renderer is refused rather than interned and rendered:
`org-dblock-write:org-agents' reads anything that is not `table' as a
list, so a misspelling would render a view the agent did not ask for and
say nothing about it.  Compared as text, so that a value no renderer
answers to leaves no symbol behind either."
  (let ((name (or value "children")))
    (unless (member name (mapcar #'symbol-name org-agents--known-views))
      (user-error "org-agents: :AGENT_VIEW: `%s' is not one of %s" name
                  (mapconcat #'symbol-name org-agents--known-views ", ")))
    (intern name)))

(defun org-agents--read-limit (value)
  "Read the `:AGENT_LIMIT:' property VALUE, which may be nil.
A limit that is not a count is refused: `string-to-number' reads one as
zero, and an agent that renders nothing looks exactly like an agent
whose query matched nothing."
  (when value
    (unless (string-match-p "\\`[0-9]+\\'" value)
      (user-error "org-agents: :AGENT_LIMIT: must be a count, not `%s'" value))
    (string-to-number value)))

(defun org-agents--read-agent ()
  "Read the agent entry at point into a plist."
  (let ((q (org-agents--entry-get "AGENT_QUERY")))
    (unless q (user-error "No :AGENT_QUERY: at point"))
    (let ((query (org-agents--read-sexp ":AGENT_QUERY:" q)))
      (list :query (org-agents--expand query)
            :view (org-agents--read-view (org-agents--entry-get "AGENT_VIEW"))
            :scope (org-agents--read-scope (org-agents--entry-get "AGENT_SCOPE"))
            :sort (when-let* ((s (org-agents--entry-get "AGENT_SORT")))
                    (org-agents--read-sort
                     (org-agents--read-sexp ":AGENT_SORT:" s)))
            :limit (org-agents--read-limit (org-agents--entry-get "AGENT_LIMIT"))
            :columns (org-agents--entry-get "AGENT_COLUMNS")
            :format (org-agents--entry-get "AGENT_FORMAT")
            :marker (save-excursion
                      ;; The agent's own headline, not wherever point
                      ;; happened to sit: `org-agents--self-match-p'
                      ;; compares this position against the headline
                      ;; positions org-ql reports.
                      (unless (org-before-first-heading-p)
                        (org-back-to-heading t))
                      (point-marker))))))

(defun org-agents--scope-base-files (scope)
  "Files named by SCOPE, before any prefilter."
  (pcase scope
    ('agenda (org-agenda-files))
    ('active (directory-files-recursively
              org-directory "\\.org\\'" nil
              (lambda (d) (not (string-match-p "/archive\\'" d)))))
    ('all (directory-files-recursively org-directory "\\.org\\'"))
    ((pred stringp)
     (let ((path (expand-file-name scope org-directory)))
       ;; A directory that is not there is a mistyped scope, and a
       ;; mistyped scope is one agent's problem: `file-missing' out of
       ;; `directory-files-recursively' is what this package raises for a
       ;; bug of its own, and `org-agents-update' lets that through to the
       ;; debugger rather than reporting it against the agent.
       (unless (file-directory-p path)
         (user-error "org-agents: scope `%s' names no directory (%s)"
                     scope (abbreviate-file-name path)))
       (directory-files-recursively path "\\.org\\'")))
    ;; A list of file names, and nothing else: anything further along
    ;; would reach `expand-file-name' as a wrong type and signal there,
    ;; rather than being named as the bad scope it is.
    ((and (pred listp) (guard (cl-every #'stringp scope)))
     (mapcar #'expand-file-name scope))
    (_ (user-error "org-agents: bad scope %S" scope))))

(defun org-agents--needs-prefilter-p (scope)
  "Non-nil when SCOPE is unbounded, so is worth narrowing before it is read.
`active' and `all' are the corpus by name, and a directory promises no
less: nothing about naming one bounds what it holds, and reading it live
means opening however many files it turns out to hold.  `agenda' and an
explicit file list name their files, and are read live -- where a
prefilter is pure overhead, not an optimization declined."
  (or (memq scope org-agents--corpus-scopes) (stringp scope)))

(defun org-agents--scope-root (scope)
  "The directory ripgrep searches for SCOPE, or nil when SCOPE names files.
Only an unbounded scope has a root: `active' and `all' are the corpus,
and a string scope is a directory relative to `org-directory'.  The path
is expanded, so ripgrep prints absolute names.

A directory that is not there is refused HERE rather than left for
ripgrep, whose exit status for a missing path is the same 2 it uses for a
broken pattern: reporting a mistyped scope as a prefilter failure would
name the wrong fault.  The message is the one
`org-agents--scope-base-files' raises for the same mistake, so which of
them gets there first cannot change what the user reads.

For `active' the root is the whole corpus, `archive' directories
included, which the scope's own file list excludes.  That is harmless --
`org-agents--same-files' drops them -- and a scope-dependent
`--glob' exclusion would be a second, differently-spelled expression of
the same bound, which is one more chance for one of them to be narrower
than the file list."
  (pcase scope
    ((or 'active 'all) (expand-file-name org-directory))
    ((pred stringp)
     (let ((path (expand-file-name scope org-directory)))
       (unless (file-directory-p path)
         (user-error "org-agents: scope `%s' names no directory (%s)"
                     scope (abbreviate-file-name path)))
       path))
    (_ nil)))

(defun org-agents--same-files (base candidates)
  "Return the members of BASE that CANDIDATES names too.
Names are compared as truenames.  `org-directory' is commonly itself a
symlink -- it is on the author's machine -- and ripgrep answers with
paths built from the root it was handed, so the two sides can name one
file two ways and under `equal' they would have nothing in common and
every agent would match nothing.  BASE's own spellings are what is
returned, because those are the names the user reads and the links that
will be followed.

Letting BASE have the last word cuts BOTH ways, and only one of them is
harmless.  A file ripgrep reported that BASE does not hold is dropped,
which is the safe direction and is how an `active' scope loses the
`archive' files its root includes.  A file BASE holds that ripgrep did
NOT report is dropped too -- and that is the under-match direction, a
match lost with no error.  Nothing in this function prevents it: what
prevents it is the argument vector, whose `--hidden', `--no-ignore',
`--follow' and inclusive `--iglob' exist so that ripgrep's traversal
cannot be narrower than `directory-files-recursively''s.  Read the flag
rationales in `org-agents--rg-args' as the guarantee this intersection
depends on, not as something this intersection makes safe.

Truenames are the authority, and they are needed: `directory-files-recursively'
does not expand `~', so with Emacs's default `org-directory' of \"~/org\"
BASE is spelled \"~/org/...\" while ripgrep prints \"/Users/you/org/...\",
and under `equal' the two sides would have nothing in common and every
agent would match nothing.

But `file-truename' is a chain of readlink calls per file, and where the
two sides agree letter for letter -- which is the usual case, since
ripgrep is handed an already-expanded root -- nearly all of them are
wasted.  So a base file whose own spelling is already a candidate
spelling is admitted without one: if FILE is literally among CANDIDATES
then its truename is trivially among their truenames, so the answer is
unchanged by construction.  The truename table is built lazily, only if
some base file is left over, which is where the \"~/org\" case still
gets its correct answer.

Measured over the author's corpus, 3,669 base files against 3,644
candidates, alternating the two implementations over three rounds: 0.57
seconds before, 0.30 after, the same 3,644 files each time.  Where every
base file is reported the table is never built at all: 0.58 seconds
before, 0.001 after.  For scale, the ripgrep run this pass exists to
protect costs about 0.1 to 0.5 seconds."
  (let ((literal (make-hash-table :test #'equal))
        (wanted nil))
    (dolist (candidate candidates) (puthash candidate t literal))
    (cl-remove-if-not
     (lambda (file)
       (or (gethash file literal)
           (progn
             (unless wanted
               (setq wanted (make-hash-table :test #'equal))
               (dolist (candidate candidates)
                 (puthash (file-truename candidate) t wanted)))
             (gethash (file-truename file) wanted))))
     base)))

(defun org-agents--scope-files (agent)
  "Resolve AGENT's scope to files, narrowing an unbounded scope with ripgrep.
A scope that NAMES its files is returned as it stands: prefiltering an
`agenda' scope or an explicit list would spend a subprocess to narrow a
set that is already small, and measured, that makes the common case 5 to
25 times slower to reach the same answer.

For an unbounded scope, the query's superset-safe conjuncts are turned
into ripgrep patterns and the answer is intersected with the scope's own
file list.  An EMPTY answer is an answer -- the agent renders nothing --
and only a failure, a missing ripgrep, a query with nothing to push, or
`org-agents-prefilter' set to nil sends this down the fallback below.

The base files are gathered only where they will be used: for an
unbounded scope, gathering them is the recursive walk the prefilter
exists to make unnecessary."
  (let ((scope (plist-get agent :scope)))
    (if (not (org-agents--needs-prefilter-p scope))
        (org-agents--scope-base-files scope)
      ;; Before anything is spawned, so a mistyped directory is named as
      ;; one rather than as a prefilter failure.
      (let* ((root (org-agents--scope-root scope))
             (conjuncts (org-agents--prefilter-conjuncts
                         (plist-get agent :query)))
             (reason
              (cond ((null org-agents-prefilter) "prefiltering off")
                    ((null conjuncts) "no pushable conjunct")
                    ((not (org-agents--rg-available-p)) "ripgrep not found")))
             (candidates (unless reason
                           (org-agents--rg-files conjuncts root))))
        (cond ((eq candidates 'unavailable) (setq reason "ripgrep failed"))
              ;; Belt: every pattern declined, so nothing ran and nothing
              ;; was narrowed.  `t' is not the empty answer.
              ((eq candidates t) (setq reason "no pushable conjunct")))
        (cond
         (reason
          (when (eq org-agents-prefilter 'require)
            (user-error
             ;; `%s': only a reserved name or a directory reaches this,
             ;; and `%S' would quote the directory twice over.
             (concat "org-agents: scope `%s' cannot be narrowed (%s) and"
                     " `org-agents-prefilter' is `require'; for live"
                     " evaluation set it to `auto', or use `agenda' or an"
                     " explicit file list")
             scope reason))
          (let ((base (org-agents--scope-base-files scope)))
            ;; Said once, and naming the count: on the author's corpus
            ;; this walk is 3,634 files and a query of 172 seconds, which
            ;; is a shocking thing to happen without explanation, and a
            ;; file count explains it.  (Longer at a low
            ;; `gc-cons-threshold' -- past nine minutes at the batch
            ;; default -- since opening this many Org buffers makes
            ;; garbage faster than the default budget expects.)
            (message (concat "org-agents: scope `%s' not narrowed (%s);"
                             " scanning %d files live")
                     scope reason (length base))
            base))
         ((null candidates) nil)
         (t (org-agents--same-files (org-agents--scope-base-files scope)
                                    candidates)))))))

(defun org-agents--self-match-p (element marker)
  "Non-nil when ELEMENT is the very entry MARKER points at.
org-ql sets `:org-hd-marker' to the headline's `:begin', and resolves a
file to a buffer already visiting it -- by truename, so a scope that
names the agent's file by another spelling still yields the same buffer.
An agent matched by its own query is therefore recognized by position.
MARKER must be one: `org-agents--collect' refuses an agent without a
marker rather than let this comparison quietly stop being made."
  (when-let* ((m (org-element-property :org-hd-marker element)))
    (and (eq (marker-buffer m) (marker-buffer marker))
         (= (marker-position m) (marker-position marker)))))

(defun org-agents--collect (agent)
  "Return AGENT's sorted, limited matches as headlines with markers."
  ;; One form, bound once: gated here and handed to `org-ql-select'
  ;; below.  Computing the effective form twice is what let the gated
  ;; form and the evaluated one drift apart in the first place.
  (let ((form (org-agents--effective-query (plist-get agent :query))))
    (unless (org-agents--gate form)
      (user-error "org-agents: query not approved"))
    ;; Without a marker naming a live buffer the self-skip cannot be
    ;; made, and the agent renders itself as one of its own matches.  A
    ;; detached marker is no better than none: `org-agents--self-match-p'
    ;; would compare nil against each match's buffer and answer nil every
    ;; time, and where the match's own marker is detached too the
    ;; comparison reaches `=' as a wrong type, out of a `when-let*' body
    ;; that names neither the agent nor what went wrong with it.
    (let ((marker (plist-get agent :marker)))
      (unless (and (markerp marker) (marker-buffer marker))
        (user-error "org-agents: agent has no live marker")))
    (let* ((self (plist-get agent :marker))
           (sort (plist-get agent :sort))
           (limit (plist-get agent :limit))
           (files (org-agents--scope-files agent))
           (matches
            ;; Handed no files, `org-ql-select' searches the current
            ;; buffer, which for an agent is the file it lives in: a
            ;; scope that resolved to nothing must select nothing.
            (and files
                 (org-ql-select files form
                   :action 'element-with-markers
                   :sort (org-agents--element-sort sort))))
           (matches (cl-remove-if (lambda (element)
                                    (org-agents--self-match-p element self))
                                  matches)))
      (if limit (take limit matches) matches))))

;;;; Links

;; Every view links back to the match's live heading rather than to the
;; element org-ql handed over: the buffer may have moved on since the
;; query ran, and the link has to resolve against the text that is
;; there now.  A match whose marker no longer names a buffer cannot be
;; linked at all, and says so rather than pointing somewhere wrong.

(defconst org-agents--unresolved-suffix " (?)"
  "Marks a match rendered as plain text for want of a live marker.")

(defun org-agents--live-marker (element)
  "Return ELEMENT's headline marker, if it still names a live buffer.
org-ql sets `:org-hd-marker' when selecting `element-with-markers'.
By the time a render reaches a match the marker may be detached -- its
buffer killed -- and a detached marker has no position to read a
heading at."
  (when-let* ((m (org-element-property :org-hd-marker element)))
    (and (marker-buffer m) m)))

(defun org-agents--link-to (element)
  "Return an Org link to ELEMENT's heading, built at the live heading.
An `id:' target is registered with `org-id-add-location', so following
the link needs no corpus rescan; without an ID the heading search
string stands in for one.  A match that cannot be located renders as
its recorded heading text, marked `(?)': a link that does not resolve
is worse than text saying there is none."
  (let (target title)
    (if-let* ((m (org-agents--live-marker element)))
        (with-current-buffer (marker-buffer m)
          (org-with-wide-buffer
           (goto-char m)
           ;; The base buffer's file, as `org-id' itself reads it: an
           ;; indirect buffer visits nothing, and a match reached
           ;; through one would have no file to fall back on.
           (let ((file (buffer-file-name (buffer-base-buffer)))
                 (id (org-id-get)))
             (setq title (org-get-heading t t t t)
                   target
                   (cond
                    (id (when file (org-id-add-location id file))
                        (concat "id:" id))
                    ;; With neither an ID nor a file there is nothing to
                    ;; link to: `file:nil::*…' is not a location, and
                    ;; `org-id-add-location' refuses a buffer that
                    ;; visits nothing.
                    (file
                     ;; `org-link-heading-search-string' supplies the
                     ;; `*' that makes the search a headline search.
                     (concat "file:" file "::"
                             (org-link-heading-search-string))))))))
      (setq title (or (org-element-property :raw-value element) "")))
    (if target
        (org-link-make-string target title)
      (concat title org-agents--unresolved-suffix))))

(defun org-agents--format-suffix (element format-props)
  "Property values named by FORMAT-PROPS at ELEMENT's heading.
FORMAT-PROPS is an `:AGENT_FORMAT:' value: property names separated by
whitespace.  A match that cannot be located has no entry to read them
at, and so has no suffix either."
  (when-let* ((props (and format-props (split-string format-props)))
              (m (org-agents--live-marker element)))
    (with-current-buffer (marker-buffer m)
      (org-with-wide-buffer
       (goto-char m)
       (mapconcat (lambda (p) (or (org-entry-get nil p) "")) props "  ")))))

(defun org-agents--alias-target (heading)
  "The target of the first bracket link in HEADING, or nil if it has none.
Read back unescaped, because `org-link-escape' escapes every bracket in
a target and a heading search string is full of them.  The same reading
serves both sides of the comparison `org-agents--render-children'
makes: an alias is recognized by the target it links to, never by its
description, which is the live heading text and drifts."
  (when (string-match org-link-bracket-re heading)
    (org-link-unescape (match-string 1 heading))))

;;;; Children view

;; The children view is the only view that writes outside a dynamic
;; block, so it alone must answer for what it deletes.  A generated
;; alias is ephemeral: it carries `:AGENT_MATCH: t' and holds nothing
;; but its own property drawer, and every update reaps it.  The moment
;; the user writes anything under one it is theirs, and no update
;; deletes it; when its match is gone it is retitled instead.  A child
;; that never carried `:AGENT_MATCH: t' is not this package's to touch.

(defconst org-agents--stale-suffix " (stale)"
  "Marks a preserved alias whose match the query no longer finds.")

;; Where a subtree stops, and which of Org's two answers is wanted.
;;
;; A blank line between one subtree and the next is ordinary Org style and
;; belongs to whoever wrote it, so no update may consume one -- and an
;; update that deletes a region has to say where that region stops.
;;
;; `org-end-of-subtree' answers two different questions.  With TO-HEADING it
;; runs on to the beginning of the next heading, blank lines included.
;; Without it, it backs over the whole run of them and stops at the end of
;; the last line holding text: "When end of the subtree has blank lines,
;; move point before these blank lines", as its docstring puts it, and its
;; `skip-chars-backward' takes any number of them.
;;
;; So the second is what an insertion point wants and already used.  What
;; was missing is a deletion bound, which is that position advanced over its
;; own newline -- near enough to the first form to have been reached for,
;; and different in exactly the blank line that made this necessary.

(defun org-agents--subtree-end ()
  "End of the subtree at point: past its last line of text, before the blanks.
The region a pristine alias is deleted over.  `org-end-of-subtree' with
TO-HEADING runs to the next heading, so a blank line the user wrote after
the alias would fall inside that region and be deleted with it; without
TO-HEADING it stops short of the newline ending the last line of text,
which would leave that newline behind.  This is the latter, advanced over
that newline: the subtree's own text is inside the region, and the blank
lines after it are not."
  (save-excursion
    (org-end-of-subtree t)
    (if (eobp) (point) (line-beginning-position 2))))

(defun org-agents--child-pristine-p ()
  "Non-nil when the alias at point holds nothing but its property drawer.
Whitespace after the drawer counts as nothing: a blank line carries no
text of the user's, and reading one as an annotation would pin the
alias for good."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (forward-line 1)
      (and (looking-at-p org-property-start-re)
           (re-search-forward org-property-end-re end t)
           (progn (forward-line 1)
                  (string-blank-p
                   (buffer-substring-no-properties (point) end)))))))

(defun org-agents--alias-regions (level bound)
  "Records of the generated aliases directly under the heading at point.
LEVEL is that heading's depth and BOUND the end of its subtree.  Each
record is (BEG END PRISTINE TARGET HEADING), in buffer order, where BEG
and END bound the whole child subtree.

Only a child at exactly LEVEL+1 carrying `:AGENT_MATCH: t' is recorded.
Everything else below the agent is the user's: a child written deeper
than LEVEL+1 is not something this package wrote, and neither is one
whose `AGENT_MATCH' says anything other than `t'."
  (let ((re (format "^\\*\\{%d\\} " (1+ level)))
        (records nil))
    (save-excursion
      (while (re-search-forward re bound t)
        (beginning-of-line)
        (let ((beg (point))
              ;; Not `org-end-of-subtree': its TO-HEADING form runs to the
              ;; next heading, so a blank line the user wrote after this
              ;; alias would fall inside the region -- and a pristine alias
              ;; is deleted over exactly this region.
              (end (org-agents--subtree-end)))
          (when (equal (org-entry-get nil "AGENT_MATCH") "t")
            ;; A COMMENT keyword is kept: `org-agents--mark-stale'
            ;; retitles through `org-edit-headline', which replaces the
            ;; whole title group, and the keyword lives in that group.
            ;; Read without it, a stale mark would uncomment the alias.
            (let ((heading (org-get-heading t t t nil)))
              (push (list beg end
                          (org-agents--child-pristine-p)
                          (org-agents--alias-target heading)
                          heading)
                    records)))
          (goto-char end))))
    (nreverse records)))

(defun org-agents--mark-stale (heading stale)
  "Retitle the alias at point, marking it stale or not according to STALE.
HEADING is its current title.  A match that comes back unmarks the
alias its absence marked, so the mark answers for this update rather
than for an older one."
  (let ((bare (string-remove-suffix org-agents--stale-suffix heading)))
    (org-edit-headline (if stale
                           (concat bare org-agents--stale-suffix)
                         bare))))

(defun org-agents--render-children (agent matches)
  "Render MATCHES as AGENT's child aliases; return how many there were.
A pristine alias -- `:AGENT_MATCH: t' and nothing but its own property
drawer -- is deleted and written again from MATCHES.  One the user has
annotated stays where they put it: no second alias is written for the
match it already stands for, and a match gone this round marks it
stale rather than deleting it.

Every link is built before the first edit, because a match may live in
the agent's own buffer, where an edit would move it."
  (let ((marker (plist-get agent :marker))
        (format-props (plist-get agent :format))
        (kept nil))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "org-agents: agent has no live marker to render under"))
    (org-agents--check-row-sort agent)
    (let ((rendered                     ; (TARGET TEXT SUFFIX) per match
           (mapcar (lambda (element)
                     (let ((text (org-agents--link-to element)))
                       (list (org-agents--alias-target text) text
                             (org-agents--format-suffix element format-props))))
                   matches)))
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (when (org-before-first-heading-p)
           (user-error "org-agents: the children view needs an agent heading"))
         (org-back-to-heading t)
         (let* ((level (org-current-level))
                (regions (org-agents--alias-regions
                          level (save-excursion (org-end-of-subtree t t)
                                                (point))))
                (targets (mapcar #'car rendered)))
           ;; Back to front: every edit below lies at or after the
           ;; region it belongs to, so the regions still to come keep
           ;; the positions they were found at.  Forwards, each
           ;; deletion and each retitle would move the next one.
           (pcase-dolist (`(,beg ,end ,pristine ,target ,heading)
                          (nreverse regions))
             (cond
              (pristine (delete-region beg end))
              ;; An alias whose heading holds no link cannot be compared
              ;; against this round's matches at all, so it is left as
              ;; it stands rather than marked on a guess.  It joins no
              ;; target to `kept' either, so pass 2 writes a fresh alias
              ;; for the match it stood for: a duplicate, accepted, the
              ;; price of not reading a mangled link as any match at all.
              ((null target))
              (t (push target kept)
                 (goto-char beg)
                 (org-agents--mark-stale heading
                                         (not (member target targets))))))
           ;; What the user annotated stays where it is; the rest of the
           ;; matches follow the subtree as it now stands.  The text is
           ;; inserted before the newline that ends the subtree rather
           ;; than at the position after it, which another agent's
           ;; marker in this buffer may be sitting on.  Without
           ;; TO-HEADING that position is also above any blank lines the
           ;; user left before the next heading, so the insertion has
           ;; never had this end of the problem.
           (when-let* ((new (cl-remove-if (lambda (row) (member (car row) kept))
                                          rendered)))
             (goto-char marker)
             (org-back-to-heading t)
             (org-end-of-subtree t)
             (pcase-dolist (`(,_ ,text ,suffix) new)
               (insert "\n" (make-string (1+ level) ?*) " " text)
               (when-let* ((extra (org-string-nw-p suffix)))
                 (insert " " extra))
               (insert "\n:PROPERTIES:\n:AGENT_MATCH: t\n:END:")))))))
    (length matches)))

;;;; Dynamic block

;; The list and table views live in a dynamic block, so they write only
;; between its delimiters and never touch the outline around them.
;; `org-prepare-dblock' deletes the previous body before calling the
;; writer and hands it over as `:content': everything a render needs is
;; therefore computed before anything is written, and a render that
;; fails puts that body back rather than leaving the block empty.

(defvar org-agents--last-count nil
  "How many rows or items the most recent dblock render wrote.
Nil until a render succeeds: `org-agents-update' writes
`:AGENT_MATCHED:' from this once `org-update-dblock' returns, and a
render that failed must not be reported with the count of an older one.")

(defvar org-agents--last-error nil
  "What the most recent dblock render failed with, or nil if it did not.
The writer catches its own failures, so the reason would otherwise reach
no further than a `message': `org-agents--update-block' reads it, and the
summary of an update over a whole file set is all a user sees of it.")

(defun org-agents--table-cell (s)
  "Escape S for use inside an Org table cell.
A bar in the text would read as the boundary of a cell that is not
there, and the row would be read as one column wider than the table.
The escape covers a link's description as well as a property value: a
broken link is a link that goes nowhere, while a broken row misaligns
every column after it."
  (replace-regexp-in-string "|" "\\\\vert{}" (or s "")))

(defun org-agents--table-columns (agent)
  "The column names AGENT's table renders, from `:AGENT_COLUMNS:'.
The link column alone by default, which is the one column no property
can supply."
  (split-string (or (plist-get agent :columns) "ITEM_BY_ID")))

(defun org-agents--table-row (element columns)
  "The escaped cells rendering ELEMENT over the COLUMNS name list.
`ITEM_BY_ID' is the link to the match, wherever in COLUMNS it is named;
every other name is read as a property at the match's own heading.  A
match that cannot be located has no entry to read one at, so those
cells are empty, as `org-agents--format-suffix' answers nothing for such
a match either.  The marker is what says so: `org-with-point-at' leaves
point where it stands for a marker naming no buffer, and would answer
with the properties of whatever entry the block itself sits in."
  (let ((marker (org-agents--live-marker element)))
    (mapcar (lambda (column)
              (org-agents--table-cell
               (cond
                ;; Built here rather than ahead of the columns, because
                ;; building one registers the match's id location: a
                ;; table that names no link column would otherwise
                ;; record every match for links nobody holds.
                ((equal column "ITEM_BY_ID") (org-agents--link-to element))
                ((null marker) "")
                (t (org-with-point-at marker
                     (org-entry-get nil column))))))
            columns)))

(defun org-agents--sort-column (sort columns)
  "Zero-based index into COLUMNS named by row SORT, or nil for any other.
A number naming no column is diagnosed here: `:AGENT_SORT:' is text
from a file like every other agent property, and `nth' would otherwise
answer nil and reach the comparison as a wrong type."
  (when (memq (car-safe sort) org-agents--row-sorts)
    (let ((n (cadr sort)))
      (unless (and (integerp n) (<= 1 n (length columns)))
        (user-error "org-agents: :AGENT_SORT: no column %S among %d columns"
                    n (length columns)))
      (1- n))))

(defun org-agents--sort-rows (rows sort columns)
  "Sort table ROWS by row SORT over COLUMNS, or return them as they came.
`(column N)' compares the rendered cells as strings; `(ts-column N)'
reads them as timestamps, and a cell naming no time sorts after every
cell that does -- an entry with no date is not an entry dated the epoch."
  (if-let* ((i (org-agents--sort-column sort columns)))
      (if (eq (car-safe sort) 'ts-column)
          (sort rows
                (lambda (x y)
                  (let ((tx (ignore-errors
                              (org-time-string-to-seconds (nth i x))))
                        (ty (ignore-errors
                              (org-time-string-to-seconds (nth i y)))))
                    (cond ((and tx ty) (< tx ty))
                          (tx t)))))
        (sort rows (lambda (x y) (string< (nth i x) (nth i y)))))
    rows))

(defun org-agents--table-rows (agent matches)
  "The sorted, limited rows rendering MATCHES for AGENT.
`:AGENT_LIMIT:' is applied here, after the sort, because a row sort is
this renderer's own: `org-agents--collect' cannot cut to the limit
before ordering rows it knows nothing about.  A limit it has already
applied cuts nothing further."
  (let* ((columns (org-agents--table-columns agent))
         (limit (plist-get agent :limit))
         (rows (org-agents--sort-rows
                (mapcar (lambda (element)
                          (org-agents--table-row element columns))
                        matches)
                (plist-get agent :sort) columns)))
    (if limit (take limit rows) rows)))

(defun org-agents--table-text (columns rows)
  "The Org table naming COLUMNS over ROWS, as a string.
The rule is written `|-|' and no cell is padded: the writer aligns the
table once it is in the buffer, which is where a width can be measured
at all.  There is no final newline, because `org-prepare-dblock' has
already opened the line that ends the body."
  (mapconcat (lambda (row)
               (if (eq row 'hline)
                   "|-|"
                 (concat "| " (string-join row " | ") " |")))
             (append (list (mapcar #'org-agents--table-cell columns) 'hline)
                     rows)
             "\n"))

(defun org-agents--list-text (agent matches)
  "The plain list rendering MATCHES for AGENT, as a string.
Each item is the link to a match followed by the `:AGENT_FORMAT:'
properties it carries; properties it carries none of add nothing, not
even the space that would have separated them.  There is no final
newline, because `org-prepare-dblock' has already opened the line that
ends the body."
  (mapconcat
   (lambda (element)
     (let ((suffix (org-string-nw-p
                    (org-agents--format-suffix
                     element (plist-get agent :format)))))
       (concat "- " (org-agents--link-to element)
               (and suffix (concat " " suffix)))))
   matches "\n"))

(defun org-agents--dblock-query (params)
  "The expanded query PARAMS supply inline, or nil when they supply none.
A block's `:query' is read where a property drawer's would be, so it
meets the same expander -- and, in `org-agents--collect', the same gate.
It may be written as a string or as the form itself, since Org has read
the block's parameters as Lisp before this function sees them."
  (when-let* ((query (plist-get params :query)))
    (org-agents--expand
     (if (stringp query) (org-agents--read-sexp ":query" query) query))))

(defun org-agents--check-dblock-param (key value)
  "Signal a `user-error' when a block's KEY parameter may not be VALUE.
Org reads a block's parameters as Lisp, so a block can say things a
property drawer never could.  `:view \"table\"' is the plain case: a
string is not the symbol `table', so the block would quietly render a
list.  `:limit \"5\"' is the same mistake the other way round -- it
reaches `take' as a wrong type, where the writer catches it and reports a
render that failed rather than the parameter that is wrong.

`:scope' answers for itself further along and is not repeated here:
`org-agents--scope-base-files' names a scope it cannot resolve.  `:sort'
is checked here, because what answers for it further along answers only
for part of it -- `org-agents--check-row-sort' catches a row sort in a
view that has no rows, and nothing at all catches a sort that is not a
sort."
  (pcase key
    (:view
     (unless (memq value org-agents--known-views)
       (user-error "org-agents: a block's `:view' must be one of %s, not %S"
                   (mapconcat #'symbol-name org-agents--known-views ", ")
                   value)))
    (:limit
     (unless (or (null value) (natnump value))
       (user-error "org-agents: a block's `:limit' must be a count, not %S"
                   value)))
    (:sort
     (unless (org-agents--sort-ok-p value)
       (user-error "org-agents: a block's `:sort' cannot order by %S" value)))
    ((or :columns :format)
     (unless (or (null value) (stringp value))
       (user-error "org-agents: a block's `%s' must be a string, not %S"
                   key value)))))

(defun org-agents--dblock-agent (params)
  "The agent a dynamic block renders: its entry's, overridden by PARAMS.
Point is inside the block, so the enclosing heading is the entry the
block was written under, and an entry carrying an `:AGENT_QUERY:' is
read as any agent is.  A block supplying its own `:query' needs no such
entry and renders standalone, over the agenda as a list until its own
parameters say otherwise.  A block with neither has nothing to render,
and says so rather than emptying itself over it."
  (let ((agent
         (or (save-excursion
               (and (not (org-before-first-heading-p))
                    (progn (org-back-to-heading t)
                           (org-agents--entry-get "AGENT_QUERY"))
                    (org-agents--read-agent)))
             (list :query nil :view 'list :scope 'agenda :sort nil
                   :limit nil :columns nil :format nil
                   ;; A block is not a headline, so there is nothing here
                   ;; for the self-skip in `org-agents--collect' to
                   ;; recognize: no query of its own can match it.
                   :marker (point-marker))))
        (query (org-agents--dblock-query params)))
    (when query (setq agent (plist-put agent :query query)))
    ;; A block's parameters override the entry's properties name by name,
    ;; so one agent may carry several blocks, each its own view of it.
    ;; Written by `plist-member', because a parameter written nil clears
    ;; the property -- `:limit nil' asks for no limit, which is not what
    ;; a block saying nothing about a limit asks for.
    (dolist (key '(:view :scope :sort :limit :columns :format))
      (when (plist-member params key)
        (let ((value (plist-get params key)))
          ;; Four of the six have a `none' for nil to ask for.  A scope
          ;; does not: no scope resolves to no files, so the block would
          ;; render empty and read exactly like a query that matched
          ;; nothing.  Neither does a view: nil is not `table', so it
          ;; would quietly render as a list and read out of
          ;; `org-agents--check-row-sort' as "the view is `nil'".
          (when (and (null value) (memq key '(:view :scope)))
            (user-error "org-agents: a block's `%s' may not be nil" key))
          ;; A parameter that cannot be used is diagnosed here, as an
          ;; agent entry's properties are: the block would otherwise
          ;; render the wrong view, or fail somewhere further along where
          ;; the reason is no longer the parameter's name.
          (org-agents--check-dblock-param key value)
          (setq agent (plist-put agent key value)))))
    (unless (plist-get agent :query)
      (user-error "org-agents: block has no :query and no enclosing agent"))
    (org-agents--check-row-sort agent)
    agent))

(defun org-agents--dblock-saved-body (params dedent)
  "The body `org-prepare-dblock' saved in PARAMS, ready to be put back.
The saved text ends in a newline that the line Org opened for the writer
now supplies, so that one comes off.

With DEDENT the block's own indentation comes off as well:
`org-update-dblock' indents every body line once the writer returns, and
a body put back carrying the indentation it was found with would gain it
twice over -- once more on every failed render.  Without DEDENT, which
is the quit the writer signals again rather than returning from, nothing
will indent anything, and the text goes back exactly as it was found.

The round trip is byte-exact for a body a successful render wrote, which
is the case that matters: a failed render leaves the block as the last
good one left it.  It is not byte-exact for a body edited by hand.  A
trailing blank line is lost, because the newline `org-prepare-dblock'
opened stands in for the last one; and a hand-indented line normalizes to
the block's own indentation column, because that is what the indent pass
applies to every line alike."
  (let ((content (or (plist-get params :content) ""))
        (column (plist-get params :indentation-column)))
    (string-remove-suffix
     "\n"
     (if (and dedent (integerp column) (> column 0))
         (replace-regexp-in-string
          (format "^[ \t]\\{1,%d\\}" column) "" content)
       content))))

;;;###autoload
(defun org-dblock-write:org-agents (params)
  "Write the list or table view of the agent this dynamic block belongs to.
PARAMS are the block's own parameters, which override the `AGENT_*'
properties of the entry it sits under; a block with an inline `:query'
renders without one.

Everything is computed before anything is written.  `org-prepare-dblock'
has already deleted the body this render replaces, so a failure part way
through the work would leave the block empty: instead the failure is
reported and that body goes back as it was.  A quit is caught for that
same reason and signaled again once the body is back, so C-g still
interrupts the update it interrupted."
  (setq org-agents--last-count nil
        org-agents--last-error nil)
  (let* ((restored nil)
         (interrupted nil)
         (body
          (condition-case err
              (let* ((agent (org-agents--dblock-agent params))
                     ;; Any view but `table' renders as a list: a block
                     ;; cannot write the child headings `children' names.
                     (table (eq (plist-get agent :view) 'table))
                     ;; A row sort is this renderer's own, so the matches
                     ;; must arrive unlimited for it to order: cut first,
                     ;; they would be an arbitrary subset of themselves.
                     (row-sort (and table
                                    (memq (car-safe (plist-get agent :sort))
                                          org-agents--row-sorts)))
                     (matches (org-agents--collect
                               (if row-sort
                                   (plist-put (copy-sequence agent) :limit nil)
                                 agent)))
                     (rows (and table (org-agents--table-rows agent matches)))
                     (text (if table
                               (org-agents--table-text
                                (org-agents--table-columns agent) rows)
                             (org-agents--list-text agent matches))))
                (setq org-agents--last-count
                      (if table (length rows) (length matches)))
                text)
            ;; `quit' is no subtype of `error', so a handler for one does
            ;; not catch the other -- and C-g part way through a query
            ;; over a corpus is the interruption users actually cause.
            ;; Named here, it puts the body back like any other failure,
            ;; and is signaled again below rather than swallowed.
            ((error quit)
             (setq restored t
                   interrupted (eq (car err) 'quit)
                   ;; Recorded rather than only messaged: the caller has
                   ;; nothing else to report a failed render by, and a
                   ;; message is gone by the time a summary is read.
                   org-agents--last-error (error-message-string err))
             (unless interrupted
               (message "org-agents: dblock update failed: %s"
                        (error-message-string err)))
             (org-agents--dblock-saved-body params (not interrupted))))))
    (unless (string-empty-p body)
      (save-excursion (insert body))
      ;; Only a table this render built is aligned: a body put back is
      ;; the text that was there, and goes back exactly as it was.
      (when (and (not restored) (string-prefix-p "|" body))
        ;; The table is in the buffer already, so an alignment that fails
        ;; leaves the block unaligned rather than empty -- and that is
        ;; worth less than the run it would otherwise take down: escaping
        ;; here, it reaches `org-update-dblock' as this render's failure,
        ;; and `org-agents-update-all' would stop at the agent it happened
        ;; in.  The handler is deliberately not widened over the render
        ;; above, which stays interruptible.
        (condition-case err (org-table-align)
          (error (message "org-agents: table alignment failed: %s"
                          (error-message-string err))))))
    ;; The interrupt still interrupts, but not before the body it
    ;; interrupted is back in the block.
    (when interrupted (signal 'quit nil))))

;;;; Commands

;; The commands are the only layer that writes `:AGENT_MATCHED:', and
;; they write it once a view has been rendered, never during one: adding
;; a line to an entry's drawer moves every position below it, and Org
;; calls a dynamic block writer at positions it worked out before the
;; call.  What goes wrong is named for the agent it went wrong in,
;; because an update over a buffer or a corpus answers for one agent
;; after another, and every property an agent supplies is text out of a
;; file.

(defun org-agents--agent-label (&optional pom)
  "How a message names the agent at POM: its heading, and where it lives.
POM defaults to point.  The file is named in full, because an update over
`org-agents-files' reports on agents in file after file, several of which
may well carry the same heading."
  (org-with-point-at pom
    (format "%s (%s:%d)"
            (org-get-heading t t t t)
            (if-let* ((file (buffer-file-name (buffer-base-buffer))))
                (abbreviate-file-name file)
              (buffer-name))
            (line-number-at-pos))))

(defun org-agents--failure-text (label err)
  "The text of ERR, told of the agent LABEL it came from.
This package's own prefix comes off the message and goes back on in front
of the label, so what is read is one diagnosis of one agent rather than
two of nothing in particular."
  (format "org-agents: %s: %s" label
          (string-remove-prefix "org-agents: " (error-message-string err))))

(defun org-agents--write-matched (marker count)
  "Record COUNT and the time of this update on the agent at MARKER.
Written only once the view has been rendered: `org-entry-put' adds a line
to the entry's drawer, which moves every position below it -- among them
the bounds of the very dynamic block a render was called for.  The time
is written as an inactive timestamp, so Org reads it back as one."
  (org-with-point-at marker
    (org-entry-put nil "AGENT_MATCHED"
                   (format "%d %s" count
                           (format-time-string
                            (org-time-stamp-format t t))))))

(defun org-agents--agent-marker ()
  "Marker on the headline of the agent point is in, or nil for none.
An entry is an agent when its own drawer supplies a query, and point may
sit anywhere in it: on the heading, in the drawer, in the body, in a
dynamic block.  A heading that supplies none is no agent -- an alias with
a note under it is the common case -- and a command asked for an agent
there says so rather than acting on whatever heading is above."
  (save-excursion
    (and (not (org-before-first-heading-p))
         (progn (org-back-to-heading t)
                (org-agents--entry-get "AGENT_QUERY"))
         (point-marker))))

(defun org-agents--block-at-point ()
  "Position of the `#+BEGIN:' line of the `org-agents' block point is in.
Nil when point is in no such block.  One agent may carry several blocks,
each its own view of it, so the block point sits in is the block an
update writes -- not whichever one the agent's subtree holds first."
  (save-excursion
    (and (ignore-errors (org-beginning-of-dblock) t)
         (looking-at org-dblock-start-re)
         (equal (match-string 1) "org-agents")
         (point))))

(defconst org-agents--empty-block "#+BEGIN: org-agents\n#+END:\n"
  "An `org-agents' dynamic block with nothing in it yet.
Written both by `org-agents--goto-block', for an agent whose view needs a
block and has none, and by `org-agents-insert-dblock' for `C-c C-x x'.")

(defun org-agents--goto-block ()
  "Move to the `org-agents' block of the agent at point, opening one if none.
An agent whose view is a list or a table has nowhere to render until it
has a block, so its first update opens one where the entry's own text
begins: after the drawers, and above whatever else the agent holds.

Only the agent's own entry is searched, not its whole subtree, and a
block is recognized by the name Org reads out of it rather than by the
text of its `#+BEGIN:' line.  A block under a child heading belongs to
that child -- `org-dblock-write:org-agents' reads the properties of the
heading a block sits under -- and adopting it would render one agent into
another's view.  An agent carrying several blocks of its own is answered
for by the first; the others are written where the user stands in them,
or by `org-update-all-dblocks'."
  (org-back-to-heading t)
  (let ((entry-end (save-excursion (outline-next-heading) (point)))
        (found nil))
    (save-excursion
      (while (and (not found)
                  (re-search-forward org-dblock-start-re entry-end t))
        (when (equal (match-string 1) "org-agents")
          (setq found (match-beginning 0)))))
    (if found
        (goto-char found)
      (org-end-of-meta-data t)
      ;; `org-end-of-meta-data' with FULL skips "any kind of drawer, and
      ;; blank lines" -- its own words -- so on an agent written in
      ;; ordinary Org style, with a blank line between it and the next
      ;; heading, point lands past that line and the block opens BELOW it:
      ;; detached from the agent it belongs to, glued to the following
      ;; heading, and with the user's separator now inside the agent.  Back
      ;; over them, so the block opens against the drawer and the blank
      ;; lines go on separating what they were written to separate.
      (skip-chars-backward " \t\n")
      (unless (eobp) (forward-line 1))
      ;; An entry that ends the buffer without a final newline leaves
      ;; point mid-line, where the block would be written onto the end of
      ;; it.
      (unless (bolp) (insert "\n"))
      (save-excursion (insert org-agents--empty-block)))))

(defun org-agents--update-dblock-in-window ()
  "Run `org-update-dblock' on the block at point, in a window showing it.
Once the writer returns, `org-update-dblock' indents the body it wrote by
selecting the window it was called from -- and then works in whatever
buffer that window shows.  Over a buffer no window displays, which is
every agent of an update over a file set, that is a stranger's buffer:
the pass fails there, leaving an indented block dedented and the update
reported as having failed, or it indents a dynamic block that is none of
ours.  So the block is written from a window that shows its own buffer:
one that already does where there is one, and otherwise the selected
window, borrowed for the duration.

`set-window-buffer' signals on the minibuffer window, so an update begun
while the minibuffer is selected -- `M-x' itself, or a run over a file set
started from there -- must not reach it.  Another window is looked for
instead, and where there is none to borrow the pass is simply run where it
stands: an unindented block is worth more than an update that failed over
where it was going to be indented."
  (let ((buffer (current-buffer))
        (position (point)))
    (cond
     ;; Already showing it: nothing to borrow.
     ((eq buffer (window-buffer (selected-window)))
      (org-update-dblock))
     ;; Displayed in some other window, so use that one rather than moving
     ;; buffers into and out of the selected window.
     ((when-let* ((window (get-buffer-window buffer)))
        (with-selected-window window
          (goto-char position)
          (org-update-dblock))
        t))
     (t
      (let ((window (if (window-minibuffer-p (selected-window))
                        (get-mru-window nil nil t)
                      (selected-window))))
        (if (or (null window) (window-minibuffer-p window))
            ;; Nothing to borrow -- the minibuffer is all there is.  Run it
            ;; where it stands: an unindented block is worth more than an
            ;; update that failed over where it was going to be indented.
            (org-update-dblock)
          (save-window-excursion
            ;; A strongly dedicated window refuses another buffer; the
            ;; window configuration puts the flag back with everything else.
            (set-window-dedicated-p window nil)
            (set-window-buffer window buffer)
            ;; Selected only once the window shows BUFFER, and through
            ;; `with-selected-window' so the selection is put back.
            ;; Selecting first would make the window's old buffer current,
            ;; and every edit below would land in a stranger's buffer.
            (with-selected-window window
              (goto-char position)
              (org-update-dblock)))))))))

(defun org-agents--update-block (&optional block)
  "Update an agent's dynamic block; return the rows or items it wrote.
BLOCK is the position of the `#+BEGIN:' line to write; without one the
agent at point is given a block if it has none.  The count is the
writer's own rather than one counted again here: a row-sorted table is
handed every match so that it can order them, and cuts to
`:AGENT_LIMIT:' only once its rows are built."
  (if block (goto-char block) (org-agents--goto-block))
  (setq org-agents--last-count nil
        org-agents--last-error nil)
  (org-agents--update-dblock-in-window)
  (or org-agents--last-count
      ;; The writer caught the failure and put the previous body back, so
      ;; it is the writer that holds the reason -- and an older render's
      ;; count is not this render's to record.  The type and the
      ;; backtrace were lost where the writer caught it, so nothing is
      ;; gained by signaling anything but a diagnosis of this agent.
      (user-error "org-agents: the block did not render: %s"
                  (string-remove-prefix
                   "org-agents: "
                   (or org-agents--last-error "it wrote no count")))))

(defun org-agents--update-agent (marker &optional block)
  "Update the agent at MARKER and return how many matches it rendered.
BLOCK, when non-nil, is the `#+BEGIN:' line of the dynamic block to
write: the one point sat in when the update was asked for.

The children view is rendered inside `atomic-change-group', because it
deletes the aliases it is about to write again before it writes any of
them: a failure part way through would otherwise leave the agent half
rewritten.  A dynamic block writer answers for its own body already."
  (org-with-point-at marker
    (let* ((agent (org-agents--read-agent))
           (count (if (eq (plist-get agent :view) 'children)
                      (atomic-change-group
                        (org-agents--render-children
                         agent (org-agents--collect agent)))
                    (org-agents--update-block block))))
      (org-agents--write-matched marker count)
      count)))

;;;###autoload
(defun org-agents-update ()
  "Update the agent at point, or the `org-agents' block point sits in.
An agent whose view is `children' rewrites its child aliases; any other
view is written into a dynamic block, opened for the agent if it has none
yet.  `:AGENT_MATCHED:' then records how many entries the query matched
and when, so an agent says what it last found without being run again.

A block supplying its own `:query' needs no agent entry, and is simply
written: there is nothing there to record a count on."
  (interactive)
  (org-with-wide-buffer
   (let ((block (org-agents--block-at-point))
         (marker (org-agents--agent-marker)))
     (cond
      (marker
       (condition-case err
           (let ((count (org-agents--update-agent marker block)))
             (message "org-agents: %d match%s" count (if (= count 1) "" "es")))
         ;; A diagnosed refusal says whose query it was: the agent is
         ;; standing right here, but the same refusals are read out of a
         ;; summary of many.  Anything else is a bug in this package, and
         ;; signals as itself -- debugger and backtrace included.
         (user-error
          (user-error "%s" (org-agents--failure-text
                            (org-agents--agent-label marker) err)))))
      (block
       ;; "item", not "row": a block renders a table only where its view
       ;; says so, and every other view is a list.  Not "match" either --
       ;; a row-sorted table cuts to `:AGENT_LIMIT:' after building its
       ;; rows, so the count can be smaller than the number of matches.
       (let ((count (org-agents--update-block block)))
         (message "org-agents: the block wrote %d item%s" count
                  (if (= count 1) "" "s"))))
      (t (user-error
          "org-agents: no agent and no `org-agents' block at point"))))))

(defun org-agents--buffer-agents ()
  "Markers on the headline of every agent in the current buffer, in order.
Collected before any of them is updated: rendering an agent inserts
headings under it and a line into its drawer, so an agent found by
position afterwards would no longer be where it was found.

Headings are what is scanned, and an agent is a heading whose own drawer
supplies a query.  Searching the buffer for the property name as text
would find it in the annotation a user wrote under an alias, or in an
agent's own body, and so call one heading two agents, or a heading that
is no agent one.  The whole buffer is read, whatever it is narrowed to."
  (let ((markers nil))
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward org-outline-regexp-bol nil t)
       ;; The heading's position is read before the property lookup, not
       ;; after: `org-entry-get' searches for the drawer itself, so by the
       ;; time it returns, the match data describes whatever Org's property
       ;; machinery matched last -- the entry's last property line, as it
       ;; happens -- and not the heading this loop just found.
       (let ((heading (match-beginning 0)))
         (when (org-agents--entry-get "AGENT_QUERY")
           ;; Insertion type t, and the choice is load-bearing.  A
           ;; block-view agent whose block does not exist yet has it
           ;; inserted at the end of its own meta-data, which for an agent
           ;; whose drawer is followed only by the next heading is exactly
           ;; where the NEXT agent's marker sits.  A marker of the default
           ;; insertion type does not advance for text inserted at its own
           ;; position, so that marker would be left pointing at the block
           ;; just written -- and the next agent, found there, would render
           ;; the previous agent's block a second time and never its own.
           ;; This is the same hazard Task 7 closed for alias insertion by
           ;; inserting before the subtree's final newline; here the anchor
           ;; itself is made to advance.
           (push (copy-marker heading t) markers)))))
    (nreverse markers)))

(defun org-agents--update-markers (markers)
  "Update the agents at MARKERS and return (UPDATED . FAILURES).
Every agent answers for itself: one that fails is recorded, named, and
the rest are updated regardless -- an update that stopped at the first
bad query would leave every agent after it as it was.  Anything at all is
caught, because a malformed property is diagnosed as a `user-error' and a
bug in a renderer is not, and neither is reason to leave the agents after
it unrendered."
  (let ((updated 0)
        (failures nil))
    (dolist (marker markers)
      (condition-case err
          (progn (org-agents--update-agent marker) (cl-incf updated))
        (error (push (org-agents--failure-text
                      (org-agents--agent-label marker) err)
                     failures))))
    (cons updated (nreverse failures))))

(defun org-agents--report (updated failures)
  "Say that UPDATED agents were updated and FAILURES were not; return that.
Each failure names its own agent, because a summary that said only how
many had failed would leave the user to find out which."
  (message "org-agents: updated %d agent%s%s" updated
           (if (= updated 1) "" "s")
           (if failures
               (format ", %d failed:\n%s" (length failures)
                       (string-join failures "\n"))
             "")))

;;;###autoload
(defun org-agents-update-buffer ()
  "Update every agent in the current buffer, continuing past failures.
An agent that fails is named in the summary rather than stopping the ones
after it.  A dynamic block that supplies its own query belongs to no
agent, and is left to `org-update-all-dblocks'."
  (interactive)
  (pcase-let ((`(,updated . ,failures)
               (org-agents--update-markers (org-agents--buffer-agents))))
    (org-agents--report updated failures)))

(defun org-agents--named-files ()
  "The files `org-agents-files' names, before they are winnowed.
A directory contributes the Org files below it, and the symbol `agenda'
whatever `org-agenda-files' answers with."
  (if (eq org-agents-files 'agenda)
      (org-agenda-files)
    (cl-loop for entry in (ensure-list org-agents-files)
             for path = (expand-file-name entry)
             append (if (file-directory-p path)
                        (directory-files-recursively path "\\.org\\'")
                      (list path)))))

(defun org-agents--agent-files ()
  "The readable files `org-agents-files' names, each of them once.
A file named twice over -- by itself and by a directory that holds it,
say -- is updated once: twice, and one summary would report the agents in
it twice, as though there were two of each.  Names are compared as
truenames, because two spellings of one file are one file."
  (let ((seen (make-hash-table :test #'equal))
        (files nil))
    (dolist (file (org-agents--named-files))
      (let ((true (file-truename file)))
        (when (and (file-readable-p file) (not (gethash true seen)))
          (puthash true t seen)
          (push file files))))
    (nreverse files)))

;;;###autoload
(defun org-agents-update-all ()
  "Update every agent in the files `org-agents-files' names.
An agent that fails leaves the others updated, and is named in the
summary along with what went wrong.  A whole file that cannot be read is
recorded the same way: `find-file-noselect' can fail or ask a question of
its own -- a file grown past `large-file-warning-threshold', one that
changed on disk since it was last visited, a coding system that cannot
decode it -- and one such file must not take with it the count of every
file already updated.  The files are left modified rather than saved, so
an update can be read over -- and undone -- before it is kept."
  (interactive)
  (let ((updated 0)
        (failures nil))
    (dolist (file (org-agents--agent-files))
      (condition-case err
          (with-current-buffer (find-file-noselect file)
            (pcase-let ((`(,n . ,fs) (org-agents--update-markers
                                      (org-agents--buffer-agents))))
              (cl-incf updated n)
              (setq failures (nconc failures fs))))
        ;; Named by its file, because nothing in it was reached: there is
        ;; no agent to name, and the file is what the user has to fix.
        (error (setq failures
                     (nconc failures
                            (list (org-agents--failure-text
                                   (abbreviate-file-name file) err)))))))
    (org-agents--report updated failures)))

;;;###autoload
(defun org-agents-preview (query-string)
  "Show what an agent whose query is QUERY-STRING would match.
The query is read, expanded and gated exactly as an agent's is, and
`org-agents-exclude' is appended before `org-ql-search' evaluates it, so
a preview lists what an agent would render rather than something close to
it.  The appended form is the form the gate sees: what is approved here
is what runs.  The search is over `org-agenda-files': a scope belongs to
an agent, and a preview has no agent.  With no agenda files there is
nothing to preview, and this says so rather than searching the current
buffer, which is what `org-ql-search' does when it is handed none."
  (interactive "sAgent query: ")
  (let* ((query (org-agents--expand
                 (org-agents--read-sexp "the query" query-string)))
         (form (org-agents--effective-query query))
         (files (org-agenda-files)))
    (unless (org-agents--gate form)
      (user-error "org-agents: query not approved"))
    ;; Handed no files, `org-ql-search' searches the current buffer -- so a
    ;; preview with no agenda files would list matches from wherever the
    ;; user happened to be standing, under a heading promising the agenda.
    ;; `org-agents--collect' guards the same case for the same reason.
    (unless files
      (user-error
       "org-agents: `org-agenda-files' is empty, so there is nothing to preview"))
    (org-ql-search files form)))

;;;###autoload
(defun org-agents-insert-dblock ()
  "Insert an empty `org-agents' dynamic block at point.
What `C-c C-x x' offers, and what `columnview' and `clocktable' do there:
insert the block, leaving it to be written.  Writing it is
`org-agents-update', which the block's own `C-c C-c' reaches -- and which
would be the wrong thing to offer here, since on a plain heading it has no
agent to update and on a `children' agent it would rewrite the aliases
rather than insert anything."
  (interactive)
  (unless (bolp) (insert "\n"))
  (save-excursion (insert org-agents--empty-block)))

;; So `C-c C-x x' offers the block among the dynamic block types it knows.
(org-dynamic-block-define "org-agents" #'org-agents-insert-dblock)

;;;; Minor mode

;; An agent is worth more refreshed than remembered, so this is the second
;; way to update one: before the buffer holding it is saved.  Three refusals
;; are what make that affordable rather than a nuisance.
;;
;; No save spawns a prefilter.  `org-agents--scope-files' already declines
;; one for every scope a save updates -- `agenda' and an explicit file list
;; name their files -- so this is a belt rather than the rule, and
;; `org-agents--update-on-save' wears it by binding `org-agents-prefilter'
;; to nil for its whole extent.  That makes "a save spawns no subprocess" a
;; property of that function rather than a consequence of a rule stated
;; elsewhere.
;;
;; An agent whose scope needs a prefilter is not updated on save at all.
;; `active', `all' and a directory have no bound on what they would open,
;; so an update of one is left for a command that was asked for.  Those
;; agents are dropped before the update and named once instead.
;;
;; And an update that renders exactly what was already rendered puts the
;; buffer back as it was.  Without that, `:AGENT_MATCHED:' alone would make
;; every save rewrite the file: the stamp says when an update ran, so it
;; differs on every run whatever the query found.  A stamp is worth reading
;; only if it dates the render it describes, so the render is compared with
;; the stamps masked out, and where nothing else moved the old stamps stay.

(defconst org-agents--matched-line-re "^[ \t]*:AGENT_MATCHED:.*$"
  "A whole `:AGENT_MATCHED:' property line: its indentation and its value.")

(defun org-agents--mask-matched (text)
  "Return TEXT with every `:AGENT_MATCHED:' line replaced by a constant.
An update writes a fresh timestamp there, so the text before an update and
the text after one always differ by at least that.  Masked, the two are
equal exactly when the render wrote what was already in the buffer."
  (replace-regexp-in-string org-agents--matched-line-re
                            ":AGENT_MATCHED:" text t t))

(defun org-agents--restore-text (text)
  "Put TEXT back into the accessible portion of the current buffer.
`replace-buffer-contents' rather than an erase and an insert: it changes
only what actually differs, so point, the mark, and every marker and
overlay in the buffer survive.  Its cost is the cost of the diff it has to
find, and the only caller reaches it having already established that the
two texts differ in nothing but their `:AGENT_MATCHED:' lines -- a handful
of lines however large the file is."
  (let ((snapshot (generate-new-buffer " *org-agents-snapshot*" t)))
    (unwind-protect
        (progn
          (with-current-buffer snapshot (insert text))
          (replace-buffer-contents snapshot))
      (kill-buffer snapshot))))

(defun org-agents--savable-markers (markers)
  "Split MARKERS into (SAVABLE . SKIPPED) for an update before a save.
SKIPPED holds the labels of the agents whose scope needs a prefilter,
which are not updated on save: `org-agents-update' still refreshes one of
those when it is asked to.

An agent this package cannot READ is not skipped.  Reading a scope means
reading a property out of a file, which may be malformed -- and a
malformed agent belongs in the failure summary an ordinary update already
produces, rather than in a list of agents whose scope was too expensive to
resolve.  So a marker whose agent will not read is passed along for
`org-agents--update-markers' to fail on and name."
  (let ((savable nil)
        (skipped nil))
    (dolist (marker markers)
      (if (condition-case nil
              (org-agents--needs-prefilter-p
               (plist-get (org-with-point-at marker (org-agents--read-agent))
                          :scope))
            (error nil))
          (push (org-agents--agent-label marker) skipped)
        (push marker savable)))
    (cons (nreverse savable) (nreverse skipped))))

(defun org-agents--update-on-save ()
  "Update this buffer's agents, as `org-agents-mode' does before a save.
A buffer holding no agent is left entirely alone, and nothing is said
about it: the mode may well be on in one that merely mentions the
property, and a save that finds no agent has nothing to report.

Any failure is reported and the save then goes on regardless.  A file must
not become unsavable because a query written in it is wrong -- fixing the
query is exactly what the next save is for.

A quit is deliberately NOT caught, so C-g during an update aborts the save
along with it: a half-written render is not what the user asked to keep.
`org-dblock-write:org-agents' names `quit' beside `error' for the same
reason, catching it only long enough to put the block's previous body back
before signaling it again.

No subprocess is spawned here, whatever `org-agents-prefilter' is set
to."
  (condition-case err
      ;; The whole of it runs with the prefilter bound off, which is what
      ;; makes "a save spawns no subprocess" a property of this function
      ;; rather than a hope about its callees.
      ;;
      ;; It is a belt, not the rule.  `org-agents--scope-files' consults
      ;; ripgrep only for a scope with no bound on what it holds --
      ;; `active', `all', a directory -- and every one of those is dropped
      ;; by `org-agents--savable-markers' just below, so no agent that
      ;; survives to be updated here would have reached the prefilter
      ;; anyway.  Binding it says so where the save is, instead of leaving
      ;; a reader to derive it from a rule stated two sections away.
      ;;
      ;; Safe because the prefilter only ever NARROWS the candidate file set
      ;; and never changes an answer: without it a surviving agent reads the
      ;; files its own scope names, live, and matches exactly what it would
      ;; have matched, having merely opened more of them to find out.
      ;;
      ;; The two rules answer different questions and both are wanted.  The
      ;; skip below is about what an update COSTS -- a corpus scope has no
      ;; bound on what it would open, so it is left for a command that was
      ;; asked for.  This is about a save doing no work that cannot pay for
      ;; itself: a ripgrep run costs 0.10 to 0.45 seconds while an
      ;; `agenda'-scope update over eight files measured 0.03 to 0.05, so
      ;; narrowing a scope that names its files makes a keystroke slower
      ;; to reach the same answer.  Only
      ;; the manual commands keep the prefilter, which is where waiting for
      ;; it is something the user chose to wait for.
      (let ((org-agents-prefilter nil))
        (when-let* ((markers (org-agents--buffer-agents)))
          (pcase-let ((`(,savable . ,skipped)
                       (org-agents--savable-markers markers)))
            ;; One message for all of them, however many there are: a save
            ;; is no place to report an agent at a time.
            (when skipped
              (message (concat "org-agents: not updated on save, the scope"
                               " needs a prefilter: %s")
                       (string-join skipped "; ")))
            (when savable
              ;; Widened throughout.  `org-agents--buffer-agents' answers for
              ;; the whole buffer whatever it is narrowed to, so an update may
              ;; well write outside the accessible portion -- and a snapshot
              ;; of only that portion would restore the wrong text.
              (org-with-wide-buffer
               (let ((before (buffer-substring-no-properties (point-min)
                                                             (point-max))))
                 (pcase-let ((`(,updated . ,failures)
                              (org-agents--update-markers savable)))
                   (org-agents--report updated failures))
                 (when (equal (org-agents--mask-matched before)
                              (org-agents--mask-matched
                               (buffer-substring-no-properties (point-min)
                                                               (point-max))))
                   ;; The render wrote what was there already, so the only
                   ;; change is a set of fresh stamps -- and stamping alone
                   ;; would have this save rewrite the file, and the dates a
                   ;; reader trusts, for nothing.  The buffer goes back as it
                   ;; was and the file reaches disk byte-identical.
                   (org-agents--restore-text before))))))))
    (error (message "org-agents: the update on save failed: %s"
                    (error-message-string err)))))

;;;###autoload
(define-minor-mode org-agents-mode
  "Update this buffer's agents before it is saved.

Every agent in the buffer is rendered afresh as part of the save, so what
reaches the file is what the queries match now.  Three things are
deliberately not done.

No save spawns a prefilter, whatever `org-agents-prefilter' is set to.
The prefilter can only narrow a set of candidate files and never change
an answer, so an agent updated without it matches what it would have
matched anyway -- having merely opened more files to find out.  The
manual commands keep it, which is where waiting for it is something the
user chose to wait for.

An agent whose `:AGENT_SCOPE:' needs a prefilter -- `active', `all', or a
directory -- is named in the echo area and left as it was, since there is
no bound on what it would otherwise open.  Use \\[org-agents-update] to
refresh one of those.

And an update that renders exactly what was rendered before puts the
buffer back as it was, `:AGENT_MATCHED:' stamps and all, so saving a file
whose agents found nothing new leaves it byte-identical -- old stamps
included, because a stamp is worth reading only if it dates the render it
describes.

C-g during an update on save aborts the save along with the update."
  :lighter " Agents"
  :group 'org-agents
  (cond
   ((not org-agents-mode)
    (remove-hook 'before-save-hook #'org-agents--update-on-save t))
   ;; Turned off again before the refusal is signaled.
   ;; `define-minor-mode' has set the variable by the time this body runs,
   ;; so a refusal that only signaled would leave behind a mode reporting
   ;; itself enabled with no hook under it.
   ((not (derived-mode-p 'org-mode))
    (setq org-agents-mode nil)
    (user-error "org-agents: `org-agents-mode' needs an Org buffer"))
   (t
    ;; Buffer-locally.  On the global value the hook would scan every save
    ;; in the session -- Org buffer or not -- for agents it will not find.
    (add-hook 'before-save-hook #'org-agents--update-on-save nil t))))

(defun org-agents--buffer-mentions-query-p ()
  "Non-nil when this buffer's text holds an `:AGENT_QUERY:' property line.
A deliberately CHEAP scan, and deliberately NOT
`org-agents--buffer-agents': all this decides is whether to arm a hook,
and the authoritative scan -- which asks each heading's own drawer, and so
is not fooled by the property name appearing as text -- runs at save time
anyway.  A buffer wrongly armed therefore costs that scan on each of its
saves, and finding nothing does nothing; asking every heading HERE would
instead cost it in every Org buffer the user visits, agent or no agent, to
decide something a search over the text decides well enough.  Please do
not \"fix\" this into the expensive scan.

The whole buffer is read, whatever it is narrowed to."
  (org-with-wide-buffer
   (goto-char (point-min))
   (re-search-forward "^[ \t]*:AGENT_QUERY:" nil t)))

(defun org-agents--turn-on ()
  "Enable `org-agents-mode' in an Org buffer whose text mentions an agent.
What `global-org-agents-mode' calls in each buffer.  A buffer that is not
Org is passed over silently rather than refused: the mode's own refusal is
for a user who asked for it by name."
  (when (and (derived-mode-p 'org-mode)
             (org-agents--buffer-mentions-query-p))
    (org-agents-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-org-agents-mode
  org-agents-mode org-agents--turn-on
  ;; `:risky t' reaches the `defcustom' this generates: turning the mode
  ;; on is what makes every save of an Org file run its agents' queries.
  :risky t
  :group 'org-agents)

(provide 'org-agents)
;;; org-agents.el ends here
