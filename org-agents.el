;;; org-agents.el --- Tinderbox-style Org agents -*- lexical-binding: t -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 18 Aug 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org-ql "0.8") (ts "0.2"))
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
;; there is exactly one evaluation engine and one answer.  The
;; PostgreSQL database maintained by `org db' serves only as an
;; optional candidate-file prefilter that makes whole-corpus agents
;; affordable.
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
;; An Org property value is a single line.  A query too long for one line
;; cannot be continued onto the next -- and must not be written with a
;; `:AGENT_QUERY+:' continuation either, because the Haskell parser
;; behind the database prefilter cannot read a `+' in a property name and
;; discards the WHOLE drawer it appears in, taking every other property
;; of that entry with it.  Keep the query on one line, or name a shorter
;; one and let a residual predicate do the rest.
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
;;   - It changes the entry's content, so `org db sync' sees the agent as
;;     changed on every update: its children are stored again and its
;;     title re-embedded.
;;
;; Scope, and why a corpus scope needs the database:
;;
;; `agenda' and an explicit list of files name the files they will open,
;; and are evaluated live.  `active', `all' and any directory do not:
;; nothing about naming a directory bounds how much it holds, and reading
;; one live means opening however many files it turns out to contain.  So
;; those scopes are resolved through the `org db query' prefilter, and an
;; agent using one *errors* when no prefilter is available rather than
;; walking the corpus.  (A file-count ceiling, above which a live walk is
;; refused and below which it is allowed, is the obvious way to soften
;; this and is not implemented.)
;;
;; The bridge cannot distinguish "the database failed to answer" from
;; "the database answered, and no file matches", so an agent over a
;; corpus scope whose query genuinely matches nothing reports a missing
;; prefilter.  A needless error, never a wrong answer.
;;
;; Only conjuncts whose database answer is provably a superset of org-ql's
;; are pushed into the prefilter; everything else stays residual and is
;; applied by org-ql.  A broad `org-use-property-inheritance' -- `t' most
;; of all -- makes no property conjunct pushable, so a property-only
;; agent falls back to its scope's whole file set: still correct, and
;; much slower.  The prefilter's value depends on keeping inheritance
;; narrow.
;;
;; Known limitations:
;;
;;   - A relative date in a planning bound -- `today', or an integer day
;;     offset -- is resolved to an absolute local date when the query is
;;     pushed, rather than sent for the database to resolve.  The database
;;     would resolve it against the UTC day and org-ql against the local
;;     one, so naming the day is what keeps the two from disagreeing.  A
;;     skeleton therefore always carries a `"YYYY-MM-DD"', whatever the
;;     agent wrote.  One consequence worth knowing: the day is fixed when
;;     the query is built, so an update running across local midnight uses
;;     the day it started on.
;;   - An entry whose only value for a property comes from `:NAME+:'
;;     accumulation has no property rows in the database at all, so a
;;     `property' conjunct over such a name may drop it from the
;;     candidate set.
;;   - One agent may carry several blocks, each its own view of it, but an
;;     update that was not asked for from inside a particular one writes
;;     only the FIRST: `org-agents-update' with point outside a block, and
;;     therefore `org-agents-update-buffer' and `org-agents-update-all',
;;     refresh that one and leave the rest as they were.  Put point in a
;;     block to write that block, or use `org-update-all-dblocks' to write
;;     every block in the buffer.
;;
;; Both are covered by tests in the differential section of
;; org-agents-test.el, which record them rather than hide them.
;;
;; See docs/superpowers/specs/2026-08-18-org-agents-design.md for the
;; full design, including the evaluation gate, the push-down table with
;; the divergence evidence for each row, and the renderers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-id)
(require 'org-ql)
(require 'org-ql-search)                ; `org-agents-preview' delegates to it
;; `org-agents--absolute-date' resolves a relative date with the same
;; `ts-adjust' org-ql resolves one with, so the two cannot drift apart.
(require 'ts)
(require 'org-ql-ext)
(require 'org-db-cli)

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
;; code from a file, and every query passes this gate before it is
;; evaluated.  Queries built only from org-ql predicates and
;; combinators run unremarked; anything else needs the user's word for
;; it, once, remembered by hash.

(defcustom org-agents-safe-queries nil
  "List of sha1 hashes of queries approved to run without prompting.
Managed like `safe-local-variable-values': approving a query
interactively offers to persist its hash here.

Persisting goes through `customize-save-variable', which writes to
`custom-file' or, without one, to `user-init-file'.  Where the real init
is an Org file that is tangled, `user-init-file' is the tangled output,
and the saved approval will be overwritten the next time it is generated.
Set `custom-file' to a file of its own to keep approvals."
  :type '(repeat string) :group 'org-agents)

(defvar org-agents--session-approved (make-hash-table :test 'equal)
  "Query hashes approved for this session only.")

(defconst org-agents--cli-only-heads
  '((headline . heading) (re . regexp) (p . priority))
  "CLI grammar spellings that are not valid org-ql, with replacements.")

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

(defun org-agents--check-cli-spelling (form)
  "Signal `user-error' if FORM uses a CLI-only predicate spelling.
Only query positions are examined -- combinators, nested queries, and
the arguments of known predicates, the same descent
`org-agents--structurally-safe-p' makes -- because those are the
positions where the user meant to write a query.  `(property \"K\"
 (headline \"x\"))' is caught there, while in residual Lisp `p' or `re'
is an ordinary variable or datum, and diagnosing it would answer a
question the user was never asked."
  (when (and (consp form) (proper-list-p form))
    (when-let* ((fix (alist-get (car form) org-agents--cli-only-heads)))
      (user-error "org-agents: `%s' is CLI-only syntax; use `%s'"
                  (car form) fix))
    (when (or (memq (car form) org-agents--boolean-heads)
              (memq (car form) org-agents--nested-query-heads)
              (org-agents--known-predicate-p (car form)))
      (mapc #'org-agents--check-cli-spelling (cdr form)))))

(defun org-agents--check-spelling (form)
  "Signal `user-error' if FORM cannot be evaluated as written.
FORM has already been through `org-agents--expand', so a surviving
$ref sits in a position the expander has no reading for, and would
otherwise reach org-ql as a void variable at match time."
  (org-agents--check-cli-spelling form)
  (when-let* ((ref (org-agents--leftover-ref form)))
    (user-error "org-agents: no expansion for `%s' in `%S'" ref form)))

(defun org-agents--query-hash (query)
  "Return the hash under which QUERY is approved.
Printing is unabbreviated: a truncated query would hash as its own
prefix, so one approval would answer for every query sharing it."
  (let ((print-level nil)
        (print-length nil))
    (sha1 (prin1-to-string query))))

(defun org-agents--gate (query &optional context)
  "Return non-nil when QUERY may be evaluated.
Structurally safe queries always pass.  Unsafe queries pass when
`org-ql-ask-unsafe-queries' is nil, when previously approved, or when
the user confirms; in `noninteractive' (or CONTEXT `batch') they are
skipped instead of prompting."
  (org-agents--check-spelling query)
  (or (org-agents--structurally-safe-p query)
      (not org-ql-ask-unsafe-queries)
      (let ((hash (org-agents--query-hash query)))
        (or (gethash hash org-agents--session-approved)
            (member hash org-agents-safe-queries)
            (if (or noninteractive (eq context 'batch))
                (progn
                  (message "org-agents: skipping unapproved query %S" query)
                  nil)
              (when (yes-or-no-p
                     (format "Query contains arbitrary Lisp: %S — run it? "
                             query))
                (puthash hash t org-agents--session-approved)
                ;; Only offer to persist where customize has a file to
                ;; write; without one `customize-save-variable' errors.
                (when (and (or (bound-and-true-p custom-file) user-init-file)
                           (yes-or-no-p "Remember this approval permanently? "))
                  (customize-save-variable
                   'org-agents-safe-queries
                   (cons hash org-agents-safe-queries)))
                t))))))

;;;; Splitter

;; The splitter picks out the conjuncts of an expanded query that the
;; `org db query' CLI may answer as a candidate-file prefilter.  The
;; CLI's semantics diverge from org-ql's on most predicates, so a
;; conjunct may be pushed only when the database's answer is provably a
;; SUPERSET of org-ql's: the prefilter narrows which files are opened,
;; and org-ql alone decides what matches.  Whatever cannot be proven a
;; superset stays residual, at the price of a wider candidate set.
;; Divergence evidence: docs/superpowers/specs/2026-08-18-org-agents-design-review.md C1.

(defconst org-agents--literal-regexp "[][*+?^$\\.{}|]"
  "Characters that make a string a regexp rather than a literal.")

(defun org-agents--literal-strings-p (strings)
  "Non-nil when STRINGS is a non-empty list of literals, no regexp among them."
  (and strings
       (cl-every (lambda (s)
                   (and (stringp s)
                        (not (string-match-p org-agents--literal-regexp s))))
                 strings)))

;; A note on org-ql's `property', because its docstring reads the other
;; way and the mistake is easy to make twice.  The docstring says the
;; inheritance default is `org-use-property-inheritance'; the normalizer
;; applies that default only to a `property' form that carries an extra
;; plist.  The plain `(property NAME)' and `(property NAME VALUE)' forms
;; -- the only two this splitter pushes -- leave `inherit' at its nil
;; default and read the entry's own drawer, which is exactly what the
;; database stores.  Measured twice.  Do not write "plain forms inherit"
;; anywhere: it is false.
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
`org-entry-get' answers a special property such as CATEGORY or
DEADLINE from the entry's structure or its file, where the database
holds no property row at all, so pushing one as a property test would
drop true matches.

A name in `org-use-property-inheritance' is refused as well.  That is a
conservative guard rather than a correctness requirement; the `property'
row of `org-agents--pushdown-fns' records why."
  (and (stringp name)
       (not (member-ignore-case name (cons "CATEGORY" org-special-properties)))
       (not (org-agents--property-inherits-p name))))

(defun org-agents--date-string-p (v)
  "Non-nil when V is a YYYY-MM-DD string naming a date that exists.
The database reads an impossible date as MJD 0 and answers with no
files at all, while org-ql normalizes it and matches -- so a typo like
\"2026-02-30\" would empty the candidate set rather than narrow it.
Only a date that survives the round trip is read alike by both sides."
  (and (stringp v)
       (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" v)
       (equal v (ignore-errors
                  (format-time-string
                   "%Y-%m-%d"
                   (encode-time
                    (parse-time-string (concat v " 00:00:00"))))))))

(defun org-agents--absolute-date (value)
  "VALUE as an absolute local `YYYY-MM-DD' string, or nil if it is no date.
`today' and an integer day offset are resolved HERE, in local time, rather
than pushed for the database to resolve for itself.  That is what keeps
the two engines from disagreeing: the database resolves a relative value
against `utctDay <$> getCurrentTime', the UTC day, while org-ql resolves
it against `(ts-now)', the local one -- so a relative value pushed
verbatim names a different day to each of them, and for part of every day
the prefilter would drop entries org-ql matches.  Naming the day removes
that disagreement rather than working around it.

The substitution is exact, not approximate.  org-ql gives an absolute
string precisely the treatment it gives `today': `:from' and `:on' floored
to 00:00:00 and `:to' ceilinged to 23:59:59 of that local day
\(`org-ql--from-to-on'), and the database compares whole-day MJD integers,
so both sides select by the same calendar day.

The offset is computed with `ts-adjust', which is what org-ql uses itself,
so the arithmetic is identical by construction rather than by
reimplementation.  Seconds arithmetic would not do: on the day before a
daylight-saving change `(time-add now 86400)' lands on a different
calendar day than `ts-adjust' does, and the prefilter would be a day out
exactly when the query crosses the change."
  (cond
   ((eq value 'today) (ts-format "%Y-%m-%d" (ts-now)))
   ((integerp value) (ts-format "%Y-%m-%d" (ts-adjust 'day value (ts-now))))
   ;; Already absolute: kept as written, so its calendar-validity round
   ;; trip still answers for it.
   ((org-agents--date-string-p value) value)))

(defun org-agents--push-planning (form)
  "Push planning FORM with every date argument resolved to a local date.
A form whose arguments are not all `:from'/`:to'/`:on' naming a date this
package can resolve pushes nothing at all, since a bound the database
would read differently is worse than no bound.  A form with no arguments
asks whether the stamp is there, which needs no date and is pushed as it
stands."
  (if (null (cdr form))
      form
    (let ((plist (cdr form))
          (resolved nil)
          (ok t))
      (while (and ok plist)
        (let* ((key (car plist))
               (date (and (memq key '(:from :to :on))
                          (org-agents--absolute-date (cadr plist)))))
          (if date
              (setq resolved (nconc resolved (list key date)))
            (setq ok nil))
          (setq plist (cddr plist))))
      (and ok (cons (car form) resolved)))))

;; Each classifier returns the CLI conjunct to push for a form, or nil
;; to leave it residual.  Every row states why its conjunct is a
;; superset of what org-ql will accept at match time.
(defconst org-agents--pushdown-fns
  (list
   (cons 'property
         (lambda (form)
           ;; Inheriting names: push nothing.  org-ql applies the
           ;; `org-use-property-inheritance' default only to `property'
           ;; forms that carry an extra plist; the plain (property NAME)
           ;; and (property NAME VALUE) forms this classifier pushes
           ;; leave `inherit' at its nil default, so org-ql reads the
           ;; entry's own drawer only -- exactly what the database
           ;; stores.  Refusing to push for a name in
           ;; `org-use-property-inheritance' is therefore not required
           ;; for correctness; it is a conservative guard that only
           ;; widens the candidate set and never drops a match.
           (pcase form
             ;; Existence is local on both sides: one-argument `property'
             ;; reads this entry's own drawer, as the database rows do.
             (`(property ,(and name (pred org-agents--property-pushable-p)))
              `(property ,name))
             ;; Equality: both sides compare the entry's own value.  A
             ;; form carrying `:inherit' says for itself whether to
             ;; inherit, and has an arity neither pattern matches, so it
             ;; pushes nothing at all.
             (`(property ,(and name (pred org-agents--property-pushable-p))
                         ,(and val (pred stringp)))
              (if (string-match-p "[[:space:]]" val)
                  ;; `:NAME+:' lines accumulate into a single value,
                  ;; joined by `org--property-get-separator' -- a space
                  ;; unless `org-property-separators' says otherwise.
                  ;; The database keeps one row per line and compares it
                  ;; whole, so no row can equal the joined value.
                  `(property ,name)
                `(property ,name ,val)))
             (_ nil))))
   (cons 'property-ts
         (lambda (form)
           (pcase form
             ;; A date match on the value implies the property is there.
             (`(property-ts ,(and name (pred org-agents--property-pushable-p))
                            . ,_)
              `(property ,name))
             (_ nil))))
   ;; Planning stamps are stored for exactly these three keywords, and
   ;; both sides bound the raw stamp, so the bounds select alike -- once
   ;; every bound names a calendar day rather than a relative one, which
   ;; is what `org-agents--absolute-date' is for.
   (cons 'scheduled #'org-agents--push-planning)
   (cons 'deadline #'org-agents--push-planning)
   (cons 'closed #'org-agents--push-planning)
   (cons 'heading
         (lambda (form)
           (pcase form
             ;; ILIKE over the raw heading line ⊇ org-ql's quoted match
             ;; over the cleaned title, and the database ORs the patterns
             ;; org-ql ANDs.  Only literals: a regexp is neither.
             (`(heading . ,(and strs (pred org-agents--literal-strings-p)))
              `(heading ,@strs))
             (_ nil)))))
  "Alist of predicate head → superset-safe CLI conjunct, or nil.")

(defun org-agents--plain-strings (form)
  "Return FORM with the text properties stripped from every string in it.
A heading literal or property value lifted out of an Org buffer carries
properties, and `prin1' writes such a string as `#(\"Review\" 0 6
 (face bold))', which the CLI's reader cannot parse."
  (cond ((stringp form) (substring-no-properties form))
        ((consp form) (cons (org-agents--plain-strings (car form))
                            (org-agents--plain-strings (cdr form))))
        (t form)))

(defun org-agents--skeleton (query &optional scope-conjunct)
  "Extract the CLI prefilter skeleton from expanded QUERY as a string.
Only top-level `and' conjuncts (or the whole query when it is a single
pushable predicate) are considered, in query order, with SCOPE-CONJUNCT
last.  Return nil when no conjunct pushes: a scope on its own is
already known to the caller and does not earn a query."
  (let* ((conjuncts (if (eq (car-safe query) 'and) (cdr query) (list query)))
         (pushed
          (delq nil
                (mapcar (lambda (c)
                          (when-let* ((fn (alist-get (car-safe c)
                                                     org-agents--pushdown-fns)))
                            (funcall fn c)))
                        conjuncts)))
         (all (append pushed (and scope-conjunct (list scope-conjunct))))
         ;; As in `org-agents--query-hash': an abbreviated skeleton is a
         ;; different query, and the CLI would read it as one.
         (print-level nil)
         (print-length nil))
    (when pushed                     ; scope alone is not worth a round trip
      (prin1-to-string
       (org-agents--plain-strings
        (if (cdr all) (cons 'and all) (car all)))))))

;;;; Collection

;; Reading an agent turns the entry's `AGENT_*' properties into a plist,
;; and collecting runs the resulting query.  Every one of those
;; properties is text out of a file, so a value that cannot be used is
;; diagnosed here rather than left to fail, or to quietly do nothing, at
;; match time.

(defcustom org-agents-exclude '(not (property "AGENT_MATCH"))
  "Conjunct appended to every agent query and to previews.
Keeps agents from matching generated aliases.  Appended last so cheap
predicates short-circuit first; applied only on the Emacs side, never
in the database skeleton.  Set to nil to match aliases like any other
entry."
  :type 'sexp :group 'org-agents)

(defcustom org-agents-files '("~/org/agents.org")
  "Where `org-agents-update-all' looks for agents.
A list of files and directories, or the symbol `agenda'."
  :type '(choice (const agenda) (repeat file)) :group 'org-agents)

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
   ;; `org-agents--scope-conjunct'.
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
                    (org-agents--read-sexp ":AGENT_SORT:" s))
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
  "Non-nil when SCOPE is unbounded, so may only be resolved through the DB.
`active' and `all' are the corpus by name, and a directory promises no
less: nothing about naming one bounds what it holds, and reading it live
means opening however many files it turns out to hold.  `agenda' and an
explicit file list name their files, and are read live."
  (or (memq scope org-agents--corpus-scopes) (stringp scope)))

(defun org-agents--scope-conjunct (scope)
  "CLI path conjunct for directory SCOPE, else nil.
The conjunct is this package's contract with the CLI: a path prefix
relative to the corpus root.  An absolute directory is no such prefix,
so it pushes nothing and narrows the candidates by `base' alone, as any
other unpushable conjunct does.  The directory travels as plain text: a
scope lifted out of a buffer carries text properties, which `prin1'
would write into the skeleton in a form the CLI's reader cannot parse."
  (when (and (stringp scope) (not (file-name-absolute-p scope)))
    `(path ,(file-name-as-directory (substring-no-properties scope)))))

(defun org-agents--same-files (base candidates)
  "Return the members of BASE that CANDIDATES names too.
Names are compared as truenames: the database answers with canonical
absolute paths, while BASE is reached through `org-directory', commonly
itself a symlink, so under `equal' the two spellings of one file have
nothing in common and every agent would match nothing.  BASE's own
spellings are what is returned, because those are the names the user
reads and the links that will be followed."
  (let ((wanted (make-hash-table :test #'equal)))
    (dolist (candidate candidates)
      (puthash (file-truename candidate) t wanted))
    (cl-remove-if-not (lambda (file) (gethash (file-truename file) wanted))
                      base)))

(defun org-agents--scope-files (agent)
  "Resolve AGENT's scope to files, applying the DB prefilter when possible."
  (let* ((scope (plist-get agent :scope))
         (skeleton (org-agents--skeleton (plist-get agent :query)
                                         (org-agents--scope-conjunct scope)))
         (candidates (and skeleton
                          (org-db-cli-available-p)
                          (org-db-cli-query-files skeleton))))
    ;; The base files are gathered only where they will be used: for an
    ;; unbounded scope, gathering them is the recursive walk that the
    ;; prefilter exists to make unnecessary, and the refusal below must
    ;; not pay for it first.
    (cond
     (candidates (org-agents--same-files (org-agents--scope-base-files scope)
                                         candidates))
     ;; No candidates, and a scope with no bound on what it would open.
     ;; The bridge returns nil for a failure and for a genuinely empty
     ;; answer alike, so an agent matching nothing at all is reported
     ;; here as a missing prefilter -- a needless error, but never a
     ;; wrong answer, and the alternative is opening everything.
     ((org-agents--needs-prefilter-p scope)
      (user-error
       ;; `%s': only a reserved name or a directory reaches this, and
       ;; `%S' would quote the directory twice over.
       (concat "org-agents: scope `%s' needs the database prefilter or a"
               " pushable query (skeleton %s, cli %s); for live evaluation"
               " use `agenda' or an explicit file list")
       scope (if skeleton "ok" "empty")
       (if (org-db-cli-available-p) "failed" "unconfigured")))
     (t (org-agents--scope-base-files scope)))))

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
  (unless (org-agents--gate (plist-get agent :query))
    (user-error "org-agents: query not approved"))
  ;; Without a marker naming a live buffer the self-skip cannot be made,
  ;; and the agent renders itself as one of its own matches.  A detached
  ;; marker is no better than none: `org-agents--self-match-p' would
  ;; compare nil against each match's buffer and answer nil every time,
  ;; and where the match's own marker is detached too the comparison
  ;; reaches `=' as a wrong type, out of a `when-let*' body that names
  ;; neither the agent nor what went wrong with it.
  (let ((marker (plist-get agent :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "org-agents: agent has no live marker")))
  (let* ((query (plist-get agent :query))
         (self (plist-get agent :marker))
         (sort (plist-get agent :sort))
         (limit (plist-get agent :limit))
         (files (org-agents--scope-files agent))
         (matches
          ;; Handed no files, `org-ql-select' searches the current
          ;; buffer, which for an agent is the file it lives in: a scope
          ;; that resolved to nothing must select nothing.
          (and files
               (org-ql-select files
                 (if org-agents-exclude
                     `(and ,query ,org-agents-exclude)
                   ;; nil conjoined here is a clause that never matches,
                   ;; which is not what turning the exclusion off means.
                   query)
                 :action 'element-with-markers
                 :sort (org-agents--element-sort sort))))
         (matches (cl-remove-if (lambda (element)
                                  (org-agents--self-match-p element self))
                                matches)))
    (if limit (take limit matches) matches)))

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
              (end (save-excursion (org-end-of-subtree t t) (point))))
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
           ;; marker in this buffer may be sitting on.
           (when-let* ((new (cl-remove-if (lambda (row) (member (car row) kept))
                                          rendered)))
             (goto-char marker)
             (org-back-to-heading t)
             (org-end-of-subtree t)
             (pcase-dolist (`(,_ ,text ,suffix) new)
               (insert "\n" (make-string (1+ level) ?*) " " text)
               (when-let* ((extra (org-string-nw-p suffix)))
                 (insert "  " extra))
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
               (and suffix (concat "  " suffix)))))
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

`:scope' and `:sort' answer for themselves further along, and are not
repeated here: `org-agents--scope-base-files' names a scope it cannot
resolve, and `org-agents--check-row-sort' a row sort in a view that has
no rows to order."
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
           (push (copy-marker heading) markers)))))
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
it.  The search is over `org-agenda-files': a scope belongs to an agent,
and a preview has no agent.  With no agenda files there is nothing to
preview, and this says so rather than searching the current buffer, which
is what `org-ql-search' does when it is handed none."
  (interactive "sAgent query: ")
  (let ((query (org-agents--expand
                (org-agents--read-sexp "the query" query-string)))
        (files (org-agenda-files)))
    (unless (org-agents--gate query)
      (user-error "org-agents: query not approved"))
    ;; Handed no files, `org-ql-search' searches the current buffer -- so a
    ;; preview with no agenda files would list matches from wherever the
    ;; user happened to be standing, under a heading promising the agenda.
    ;; `org-agents--collect' guards the same case for the same reason.
    (unless files
      (user-error
       "org-agents: `org-agenda-files' is empty, so there is nothing to preview"))
    (org-ql-search files
                   (if org-agents-exclude
                       `(and ,query ,org-agents-exclude)
                     ;; nil conjoined here is a clause that never
                     ;; matches, which is not what turning the exclusion
                     ;; off means.
                     query))))

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

(provide 'org-agents)
;;; org-agents.el ends here
