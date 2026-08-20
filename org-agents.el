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
;;   $OWNER*                      ; outline:  (org-entry-get nil "OWNER" t)
;;   $OWNER^                      ; prototype: (property-resolved "OWNER")
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
;;   :AGENT_ACTION:  what to DO to the entries the query matched, as a
;;                   declarative sentence: `set-property!(REVIEWED, today)
;;                   tag!(+reviewed)'.  Read only by
;;                   `org-agents-apply-actions', from this entry's own
;;                   drawer, and never evaluated.  See `Actions' below.
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
;; The attribute registry:
;;
;; Beside the agents there is an optional second file, named by
;; `org-agents-attributes-file', which declares the corpus's own user
;; attributes.  Each of its top-level entries declares one: the heading
;; is the attribute's name, the body is its documentation, and the drawer
;; carries the declaration.
;;
;;   :ATTR_TYPE:    string, number, date, boolean, set or list.
;;                  Required; the property is what makes an entry a
;;                  declaration.  `set' and `list' are Tinderbox's --
;;                  unordered-unique and ordered -- and their members are
;;                  separated by whitespace, as Org's own `NAME_ALL'
;;                  convention separates values.
;;   :ATTR_VALUES:  the values the attribute admits, whitespace
;;                  separated.  A trailing `:ETC' leaves the vocabulary
;;                  open, which is Org's own spelling of that.
;;   :ATTR_DEFAULT: the default, as text.
;;   :ATTR_FACES:   `VALUE FACE | VALUE FACE ...': what
;;                  `org-agents-faces-mode' draws a headline with.
;;
;; The drawer must sit immediately under the heading, where Org keeps a
;; property drawer.  One written after the body text is not a property
;; drawer at all, and the entry is reported as declaring no type.
;;
;; It is PURE DATA.  Every field is read with `org-entry-get' and used as
;; a string, as one of six symbols out of a fixed table, or as a face
;; name; there is nothing a registry file can hold that this package will
;; evaluate.  A missing or unreadable registry declares nothing and says
;; nothing about it, and a malformed entry is named once and skipped --
;; a bad type costs its entry, a bad anything-else costs only that field.
;; The file is read lazily and at most once per edit, including an edit
;; not yet saved.  See `org-agents-attribute' for the declaration a
;; reader gets back, and docs/attributes-example.org for a whole file.
;;
;; Prototypes:
;;
;; The registry file carries one reserved top-level section, `Prototypes',
;; whose every entry is a MASTER: an ordinary entry whose drawer holds
;; ordinary properties, which any entry in the corpus may read through by
;; naming it in `:PROTOTYPE:' -- by name out of that section, or by
;; `id:UUID', which resolves to an entry carrying that `:ID:' wherever
;; `org-id-locations' says it lives.  That table is the one precondition
;; the feature has: see `org-agents--prototype-id-read' for why the
;; resolver consults it rather than calling `org-id-find', and for what a
;; reference whose id the table does not know does instead.
;; This is Tinderbox's prototype, and like Tinderbox's it is
;; independent of the outline: it relates two entries rather than saying
;; anything about where either sits.  Resolution order, per attribute:
;; the entry's own drawer with inheritance OFF, then the chain nearest hop
;; first, then `:ATTR_DEFAULT:', then nil.
;;
;; Outline inheritance is deliberately NOT in that order.  Containment is
;; not inheritance, and the outline axis has a spelling of its own in
;; `$NAME*'; `$NAME^' is this one, and the two are orthogonal.
;;
;; Reads are VIRTUAL: nothing is ever written into the inheriting entry, so
;; a master may be changed once and every follower changes with it.  The
;; price is worth stating plainly -- GREP DOES NOT SEE AN INHERITED VALUE,
;; and neither does `org-entry-get', a column view, or org-ql's own
;; `property'.  What does is `property-resolved', which is what `$NAME^'
;; expands to, and `org-agents-resolve-property' for a caller in Lisp.
;;
;; Two names never travel: `AGENT_*', because behaviour does not, and
;; `PROTOTYPE' itself, because a declared default for it would hand every
;; entry in the corpus a master.  So does no special property: a master's
;; `CATEGORY' is not this entry's.  A dangling reference is one message
;; naming the entry, a cycle is one `user-error' naming the hops, and both
;; are said once per update.
;;
;; What reads it: `org-agents-allowed-values', which on
;; `org-property-allowed-value-functions' makes `org-set-property'
;; complete declared values in any Org buffer -- it is not added to that
;; hook for you, the hook is Org's and it is the user's -- and
;; `org-agents-check-attributes', which lints a scope against the
;; registry and REPORTS, never edits: a name in use that nothing
;; declares, a value outside its declared vocabulary, a value that does
;; not parse as its declared type.  And `org-agents-attribute-columns',
;; which builds a `COLUMNS' format out of chosen declarations -- see
;; README's "Corpus-wide column view" for what that is for, which is a
;; recipe rather than a renderer: MEASURED, `org-agenda-columns' already
;; runs inside an `org-ql-search' results buffer, so corpus-wide
;; displayed attributes with write-back editing exist today and what was
;; missing was the format string.
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
;; Actions:
;;
;; An agent may carry an ACTION as well as a query -- `:AGENT_ACTION:',
;; holding a declarative sentence over a fixed vocabulary of nine verbs,
;; each of which edits the entries the query matched.  It is the only part
;; of this package that writes outside the agent's own file, and three
;; refusals are what make that affordable to reason about.
;;
;; It NEVER RUNS ON SAVE, on a timer, or from either minor mode: the only
;; thing that runs an action is `org-agents-apply-actions', typed.  That is
;; structural -- the action text is not in the plist `org-agents--read-agent'
;; answers with, so it does not exist as data anywhere on the save path.  It
;; is NOT INHERITABLE: read from the entry's own drawer with no INHERIT
;; argument and never through `org-agents-resolve-property', because if a
;; prototype, an ancestor, a `#+PROPERTY:' line or `org-global-properties'
;; could supply one, the code that edits your corpus when you act on file A
;; would be written in file B.  And NOTHING IN IT IS EVER EVALUATED: the
;; parser is a regexp lexer, a token becomes a function by name construction
;; plus `fboundp', and arguments reach a verb as strings.  The worst thing
;; expressible is a bounded, greppable Org edit.
;;
;; What the command does is print a DRY RUN first -- one `FILE:LINE:' line
;; per intended edit, `old -> new' -- and write nothing until that report is
;; agreed to.  `archive!' and `delete-property!' confirm at every entry on
;; every run, and in batch they are refused rather than assumed.  Nothing is
;; saved, so the worst case of a bad run is N modified buffers.
;; `org-agents-action-limit' bounds N.  See the `Actions' section at the end
;; of this file, and README's `Action code'.
;;
;; Appearance:
;;
;; The registry's `:ATTR_FACES:' is what `org-agents-faces-mode' draws with:
;; a headline whose RESOLVED value for a declared attribute is one that
;; attribute maps to a face is drawn in that face, ahead of `org-level-N'
;; rather than instead of it.  Resolved, so an entry spelling only
;; `:PROTOTYPE:' -- or nothing at all, and taking `:ATTR_DEFAULT:' -- is
;; faced exactly as one spelling the value in its own drawer.  It CHANGES NO
;; BYTES: one font-lock keyword, no text written, no property written, no
;; overlay, and turning it off puts the buffer back exactly as it was.
;; `global-org-agents-faces-mode' turns it on in EVERY Org buffer, and
;; deliberately not only in those whose text mentions a property -- a value
;; that arrives through a prototype is spelled nowhere, so a text scan would
;; miss the entries the mode exists for.  Two refusals, both stated in the
;; `Appearance' section below: no geometry, and no writes of any kind from an
;; appearance declaration.
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
;; of all -- makes no `property' or `property-ts' conjunct pushable, so an
;; agent built only out of those falls back to its scope's whole file set:
;; still correct, and much slower.  The prefilter's value depends on
;; keeping inheritance narrow.  `property-resolved' is the exception, and
;; deliberately so: the resolver never reads that option, so it cannot
;; change what the predicate answers.
;;
;; A `property-resolved' conjunct pushes a WIDENED pattern -- the local
;; `:NAME:' line OR a `:PROTOTYPE:' line, as one alternation -- because an
;; inheriting entry never spells the value, and the ordinary pattern would
;; therefore drop its file with no error.  Where the registry declares an
;; `:ATTR_DEFAULT:' that the query could match, an entry spelling NEITHER
;; line matches too, nothing can narrow, and the conjunct stays residual.
;; That exception costs narrowing and never an answer.
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
;; For the evaluation gate as it stands, see the `;;;; Gate' section below
;; and README.md's "The query language": docs/design.md's own §Safety is
;; superseded in part, and says at its head which four statements no
;; longer describe the code.  See docs/design.md for the renderers.  Do
;; NOT read its push-down table: that table describes the PostgreSQL
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
(require 'compile)                      ; `org-agents-check-attributes' report

;; `org-ql-select' expands into a call to this, which org-ql does not
;; autoload: without the declaration the compiler reports it as possibly
;; undefined at runtime, over a call site that is org-ql's own and not
;; this file's.
(declare-function org-ql--normalize-query "org-ql")

;; Declared here and defined with the Registry, far below.  The prefilter
;; reads it long before that: `org-agents--resolved-default' refuses to
;; answer outside a registry batch, and the batch is what binds this.  A
;; forward declaration rather than a moved `defvar', so that the variable
;; stays documented beside the caches it describes.
(defvar org-agents--attributes-fresh)

(defgroup org-agents nil
  "Tinderbox-style persistent queries for Org-mode."
  :group 'org
  :prefix "org-agents-")

;;;; The prototype property

;; One name, spelled above every section that reads it, because three of
;; them must agree about it: the resolver walks the chain by it, the
;; ripgrep prefilter builds the `:PROTOTYPE:' arm of its widened pattern
;; out of it, and the registry reader reserves the heading of the section
;; the masters live in.  See the `Prototypes' section below for what a
;; prototype is and how one is resolved.

(defconst org-agents--prototype-property "PROTOTYPE"
  "The property naming an entry's prototype.
The only non-`AGENT_' property this package reads by name.")

;;;; Expander

;; The expander rewrites the `$PROP' layer into a plain org-ql query.
;; It is pure: it reads no buffer and evaluates nothing, so it can be
;; tested and inspected without an Org context.

(defconst org-agents--nested-query-heads '(parent ancestors children descendants)
  "org-ql predicates whose argument is itself a query.")

(defconst org-agents--boolean-heads '(and or not when unless)
  "Heads whose arguments are themselves queries in boolean position.")

(defconst org-agents--name-position-heads
  '(property property-ts property-resolved)
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
  "If FORM is a $ref symbol naming a property, return (NAME . AXIS).
AXIS says which of the three readings of a property the reference asks
for, and they are orthogonal:

  nil        `$NAME'   the entry's OWN drawer.
  `inherit'  `$NAME*'  the OUTLINE axis: `org-entry-get' with INHERIT, so
                       an ancestor's value, a `#+PROPERTY:' keyword and
                       `org-global-properties' all answer.
  `proto'    `$NAME^'  the PROTOTYPE axis: the entry, then its
                       `:PROTOTYPE:' chain, then the registry's default.

At most ONE suffix is read.  Else nil -- which is the answer for `$' and
`$*', neither of which names a property, and for `$N*^' and `$N^*', which
name no axis.  Reading `$*' as a reference would hand `org-entry-get' the
empty name, which answers nil at every entry, and reading `$N*^' as one
would name a property whose key holds a `^', which no drawer spells:
either way an agent that matches nothing with nothing said about why.
Left as the symbols they are, they reach
`org-agents--check-spelling', which says which reference it could not
read."
  (when (and (org-agents--ref-name-p form)
             (> (length (symbol-name form)) 1))
    (let* ((name (substring (symbol-name form) 1))
           (axis (cond ((string-suffix-p "*" name) 'inherit)
                       ((string-suffix-p "^" name) 'proto)))
           (bare (if axis (substring name 0 -1) name)))
      (unless (or (string-empty-p bare)
                  (string-suffix-p "*" bare)
                  (string-suffix-p "^" bare))
        (cons bare axis)))))

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
With NUMERIC non-nil, coerce a property's string value to a number.

The axis is dispatched on by SYMBOL and not on truthiness: `inherit' is
truthy, so a site that went on asking `(cdr ref)' would take the OUTLINE
branch for a caret and do it silently.
`org-agents-test-expand-caret-in-every-position' is the twelve-cell table
that makes such a site loud.

The prototype axis reads through `org-agents-resolve-property-quietly'
and never the signalling resolver: this is residual Lisp, evaluated at
every candidate entry, and a `user-error' there aborts the update from
inside org-ql's generated matcher."
  (let* ((name (car ref))
         (special (cdr (assoc name org-agents--specials)))
         (base (cond (special special)
                     ((eq (cdr ref) 'inherit) `(org-entry-get nil ,name t))
                     ((eq (cdr ref) 'proto)
                      `(org-agents-resolve-property-quietly ,name))
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
       ;; matches.  Test the accessor instead, and ignore any suffix,
       ;; since there is nothing to inherit and nothing for a prototype
       ;; to carry.
       (special (cdr special))
       ((eq (cdr ref) 'inherit) `(org-entry-get nil ,(car ref) t))
       ;; The prototype axis in boolean position is a known org-ql
       ;; predicate, so the gate admits it unremarked -- unlike the
       ;; outline axis above, and unlike either axis in value position.
       ;; That asymmetry is real and is documented in README.
       ((eq (cdr ref) 'proto) `(property-resolved ,(car ref)))
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

(defun org-agents--check-resolved-args (form)
  "Signal `user-error' if FORM holds a `property-resolved' that cannot run.
`property-resolved' is defined with no `:normalizers' clause, and that is
not an omission: a normalizer is where a preamble comes from, and this
predicate must contribute none -- see its own docstring for the
measurement.  The consequence is that, unlike org-ql's `property', it has
nothing to swallow a keyword argument with, so `(property-resolved \"S\"
:inherit t)' would reach `string-equal' with a symbol and fail at match
time from inside org-ql's generated matcher, naming neither the agent nor
the argument that was wrong.  It is named here instead, once, before any
entry is examined.

Only query positions are examined -- the same descent
`org-agents--check-head-spelling' makes, and for the same reason: in
residual Lisp `property-resolved' is an ordinary function call and not
this predicate."
  (when (and (consp form) (proper-list-p form))
    (when (eq (car form) 'property-resolved)
      (pcase form
        (`(property-resolved ,(pred stringp)))
        (`(property-resolved ,(pred stringp) ,(pred stringp)))
        (_ (user-error
            (concat "org-agents: `property-resolved' takes a property name"
                    " and an optional value, both strings: `%s'")
            (org-agents--query-text form)))))
    (when (or (memq (car form) org-agents--boolean-heads)
              (memq (car form) org-agents--nested-query-heads)
              (org-agents--known-predicate-p (car form)))
      (mapc #'org-agents--check-resolved-args (cdr form)))))

(defun org-agents--check-spelling (form)
  "Signal `user-error' if FORM cannot be evaluated as written.
FORM has already been through `org-agents--expand', so a surviving
$ref sits in a position the expander has no reading for, and would
otherwise reach org-ql as a void variable at match time."
  (org-agents--check-head-spelling form)
  (org-agents--check-resolved-args form)
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

(defun org-agents--resolved-pushable-p (name)
  "Non-nil when NAME is a name a `property-resolved' conjunct may narrow on.
Two clauses, and only ONE of `org-agents--property-pushable-p''s two.

The special-property clause is kept, and for a STRONGER reason than the
`property' row has.  `org-entry-get' answers CATEGORY, TODO, DEADLINE and
the rest out of entry structure, and no drawer holds a line for one.  For
plain `property' the consequence of pushing is an empty candidate set --
visibly wrong.  Here it is worse: the widened alternation's `:PROTOTYPE:'
arm still matches SOME files, so the answer is non-empty and wrong, and
every structurally matching file with no `:PROTOTYPE:' line in it is
dropped with no error at all.

The inheritance clause is dropped, and that is a correctness statement
rather than a liberty.  `org-agents-resolve-property' never reads
`org-use-property-inheritance' and never passes an INHERIT argument, so
that variable cannot change this predicate's answer -- keeping the guard
would push nothing for any user whose inheritance setting is broad, which
is a pure loss of narrowing, and one INVISIBLE to every soundness test in
the suite, since those assert supersets only.
`org-agents-test-rg-property-resolved-ignores-org-use-property-inheritance'
is the narrowing test that says so."
  (and (stringp name) (not (org-agents--attr-special-p name))))

(defun org-agents--resolved-default (name)
  "The registry's declared `:ATTR_DEFAULT:' for NAME, as text, or nil.
The one reader of it on the prefilter's side, so that the splitter's
exception and `property-resolved''s own comparison are asking the same
question of the same string: `:default' \"stays the trimmed STRING the
file holds\", and the predicate compares it with `string-equal'.

An absent or unreadable registry declares no default, `org-agents-attribute'
answers nil, and `(plist-get nil :default)' is nil -- which is exactly the
branch in which the widened alternation is sound, so nothing has to be
written for it.  It still has a test, because it is the branch a later
refactor is most likely to invert.

SIGNALS outside a registry batch, and that is the point of the function
existing at all.  The exception this answer decides is sound only while
the splitter and `property-resolved' read ONE snapshot: narrow against a
default of `dflt', have the registry change to declare `other' before
org-ql runs, and every entry spelling neither a `:NAME:' line nor a
`:PROTOTYPE:' line is dropped from the answer with no error -- MEASURED,
two entries of a twelve-file corpus lost silently, and nothing lost when
the identical experiment ran inside the batch.

Today no caller can straddle it: `org-agents--scope-files' is reached
only from `org-agents--collect', which wraps
`org-agents--in-attributes-batch'; `org-agents-preview' is inside the
batch and never narrows; and `org-agents-check-attributes' narrows with
`org-agents--rg-drawer-pattern', which reads no registry.  That is an
audit of today's tree, though, and an audit is not an invariant.  The
signal is what makes it one: a later narrowing caller written outside the
batch fails loudly here instead of quietly returning fewer files than it
should.  `org-agents-test-resolved-default-refuses-to-answer-outside-a-batch'
pins it."
  (unless org-agents--attributes-fresh
    (error "org-agents: `%s' narrowed outside `org-agents--in-attributes-batch'"
           name))
  (plist-get (org-agents-attribute name) :default))

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
   ;; The widened row, and the argument for it in full, because this is
   ;; the one row where the ORDINARY property pattern would be UNSOUND.
   ;;
   ;; An entry that resolves NAME through a prototype never spells the
   ;; value: it spells `:PROTOTYPE:' and the value is in another file
   ;; entirely.  So `^[ \t]*:NAME\+?:' under-matches, and an under-match
   ;; here is a lost match with no error -- the one failure mode this
   ;; package must not have.  The widening is a disjunction: a file
   ;; holding an entry that resolves NAME either spells a local `:NAME:'
   ;; line or carries a `:PROTOTYPE:' line.
   ;;
   ;; THE SUPERSET ARGUMENT.  Let E be an entry that satisfies the
   ;; conjunct, in file F, with NAME neither opaque nor special.
   ;; `org-agents-resolve-property' has four steps and E's answer came
   ;; from one of them:
   ;;
   ;;   local   `(org-entry-get E NAME)' with INHERIT nil is non-nil only
   ;;           if F holds a line matching `org-property-re' whose key
   ;;           upcases to NAME or NAME+ -- exactly the set
   ;;           `org-agents--rg-property-pattern' matches, which is the
   ;;           `property' row's own argument unchanged.  The INHERIT
   ;;           argument being nil is what makes this step a statement
   ;;           about F at all: MEASURED, an inheriting read also answers
   ;;           from a `#+PROPERTY:' keyword and from
   ;;           `org-global-properties', the first spelled by a line no
   ;;           drawer pattern matches and the second spelled in no file
   ;;           at all.  So F matches the NAME arm.
   ;;   chain   reached only when the local step answered nil, and it
   ;;           begins at `(org-entry-get E "PROTOTYPE")' with INHERIT
   ;;           nil, which is non-nil only if F holds a `:PROTOTYPE:' or
   ;;           `:PROTOTYPE+:' line.  So F matches the PROTOTYPE arm.
   ;;           Note what is NOT claimed: the file the VALUE lives in
   ;;           need not be a candidate.  org-ql matches E, which is in
   ;;           F, and the resolver reads the master directly rather than
   ;;           through org-ql.
   ;;   default reached only when both steps above answered nil, and this
   ;;           is the EXCEPTION below: such an entry may be in a file
   ;;           holding neither line, so nothing can narrow and the
   ;;           conjunct must stay residual.
   ;;   nil     not a match.
   ;;
   ;; So outside the exception every matching file matches one arm, and
   ;; the candidate set is a superset.  Two details are load-bearing.
   ;; The alternation must reach ripgrep as ONE pattern:
   ;; `org-agents--rg-files' INTERSECTS the patterns of a conjunct, so two
   ;; patterns would mean "spells `:NAME:' AND carries `:PROTOTYPE:'",
   ;; catastrophically narrow and silent.  And the exception's comparison
   ;; and the predicate's comparison are one decision -- `equal' on the
   ;; raw strings here, `string-equal' there, which agree on two strings;
   ;; a case-INSENSITIVE predicate against a case-sensitive exception
   ;; would lose exactly the files whose default differs only in case.
   (cons 'property-resolved
         (lambda (form)
           (pcase form
             ;; An opaque name resolves LOCAL-ONLY -- no chain, no default
             ;; -- so a drawer line is exactly its condition and the
             ;; ORDINARY conjunct is sound and narrower.  Emitting the
             ;; alternation here would be over-wide rather than unsound,
             ;; and slower for no reason.  No inheritance guard, for
             ;; `org-agents--resolved-pushable-p''s reason.
             (`(property-resolved
                ,(and name (pred org-agents--prototype-opaque-p)))
              `(property ,name))
             (`(property-resolved
                ,(and name (pred org-agents--prototype-opaque-p))
                ,(and val (pred stringp)))
              (if (org-agents--property-value-pushable-p name val)
                  `(property ,name ,val)
                `(property ,name)))
             ;; Existence, and a declared default makes it residual: with
             ;; one declared, EVERY entry resolves NAME, including entries
             ;; in files holding neither line.
             (`(property-resolved
                ,(and name (pred org-agents--resolved-pushable-p)))
              (unless (org-agents--resolved-default name)
                `(property-resolved ,name)))
             ;; Equality, and the exception is narrower: only a value
             ;; EQUAL to the declared default can be answered by an entry
             ;; that spells neither line.
             (`(property-resolved
                ,(and name (pred org-agents--resolved-pushable-p))
                ,(and val (pred stringp)))
              (unless (equal val (org-agents--resolved-default name))
                (if (org-agents--property-value-pushable-p name val)
                    `(property-resolved ,name ,val)
                  ;; The value spans two lines, or cannot be argued not
                  ;; to.  Existence is wider, and wider is sound.
                  `(property-resolved ,name))))
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

`require' refuses a QUERY, and one caller is deliberately outside it:
`org-agents-check-attributes' scans live rather than refusing, with the
same message naming the file count.  It is a lint the user typed rather
than an agent a save set off, and one that declined to run would be
failing its own contract rather than declining an expense on anyone's
behalf.

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

(defconst org-agents--rg-drawer-pattern "^[ \\t]*:PROPERTIES:"
  "The ripgrep pattern for a property drawer's opening line.
A provable SUPERSET of the files that could hold a property at all, and
therefore of the files `org-agents-check-attributes' could have a finding
in: Org reads a property only from a line inside a drawer whose opener
matches `org-property-start-re', `^[ \\t]*:PROPERTIES:[ \\t]*$'.
`--ignore-case' is in `org-agents--rg-args' already, so a lower-case
`:properties:' is covered; the trailing `[ \\t]*$' is dropped because
narrower is the unsound direction here and the anchor buys nothing.
Spelled with a literal backslash and `t', because the pattern is handed
to a Rust regexp and not to Emacs's -- see `org-agents--rg-quote'.

Unlike a per-name pattern this narrows LITTLE on a property-heavy corpus,
and that is the honest answer rather than a shortcoming.  A pattern built
from the registry's own names would be much narrower and UNSOUND for the
first thing the check looks for: an undeclared property name lives, by
definition, in a file that may hold no declared name at all, so such a
pattern would drop exactly the files the check exists to find.")

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
    ;; The widened arms.  ONE pattern each, holding an alternation, and
    ;; the count is asserted by a test: `org-agents--rg-files' INTERSECTS
    ;; the patterns of a conjunct, so returning two would turn this
    ;; disjunction into a conjunction -- "spells `:NAME:' AND carries
    ;; `:PROTOTYPE:'" -- which is catastrophically narrow and silent.
    ;; `org-agents--pushdown-fns' carries the superset argument; this only
    ;; renders it.
    ;;
    ;; Built by `concat' from `org-agents--rg-property-pattern', so
    ;; `^[ \t]*' and `\+?' stay stated once -- and NEVER passed through
    ;; `org-agents--rg-quote' afterwards, which escapes `|', `(' and `)'
    ;; and would turn the alternation into a literal.
    (`(property-resolved ,name)
     (when (org-agents--rg-name-p name)
       (list (concat "(?:" (org-agents--rg-property-pattern name)
                     "|" (org-agents--rg-property-pattern
                          org-agents--prototype-property)
                     ")"))))
    ;; The value arm is deliberately NARROWER than the design document's
    ;; widening, which puts existence on both sides.  It is sound by the
    ;; same argument -- a matching entry either spells the value on one
    ;; line of its own file or carries a `:PROTOTYPE:' line in it -- and
    ;; MEASURED over the fixture corpus it drops a file the doc's spelling
    ;; keeps, which is what stops `$NAME^' from being markedly slower than
    ;; `$NAME' for no reason.  A value ripgrep cannot carry degrades to
    ;; the existence arm, which is wider and always sound.
    (`(property-resolved ,name ,value)
     (when (org-agents--rg-name-p name)
       (list (concat "(?:" (org-agents--rg-property-pattern name)
                     (if (org-agents--rg-literal-p value)
                         (concat "[ \\t]+" (org-agents--rg-quote value)
                                 "[ \\t]*$")
                       "")
                     "|" (org-agents--rg-property-pattern
                          org-agents--prototype-property)
                     ")"))))
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

(defun org-agents--rg-conjunct-patterns (conjuncts)
  "Every ripgrep pattern CONJUNCTS offer, flattened in order.
`cl-loop ... append' rather than `mapcan', because `mapcan' is
destructive on the lists `org-agents--rg-patterns' returns and one of
them is a `list' of a shared constant."
  (cl-loop for conjunct in conjuncts
           append (org-agents--rg-patterns conjunct)))

(defun org-agents--rg-files-for (patterns root)
  "Candidate files under ROOT for ready-made ripgrep PATTERNS.
Three kinds of answer, and conflating any two of them is a bug:

  a LIST          ripgrep answered.  The empty list is such an answer,
                  and it means no file can match.
  `unavailable'   ripgrep could not be run, or failed.  One failed run
                  poisons the whole prefilter: an intersection missing
                  one of its terms would be WIDER, and therefore sound,
                  but a partial answer from a broken tool is not a thing
                  to build on and the live fallback is merely slower.
  t               no pattern was offered, so nothing was narrowed at
                  all.  What an EMPTY PATTERNS yields, and distinct from
                  the empty list, which is the narrowest possible answer.

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
      (dolist (pattern patterns)
        (let ((answer (org-agents--rg-run pattern root)))
          (unless (listp answer)
            (setq failed t)
            (throw 'org-agents--rg-done nil))
          (setq candidates
                (if (eq candidates t)
                    answer
                  (org-agents--intersect-files candidates answer)))
          (when (null candidates)
            (throw 'org-agents--rg-done nil)))))
    (if failed 'unavailable candidates)))

(defun org-agents--rg-files (conjuncts root)
  "Candidate files under ROOT for CONJUNCTS.
`org-agents--rg-files-for' over the patterns CONJUNCTS offer, and every
word of that function's contract holds here unchanged.  The split exists
because `org-agents-check-attributes' has no query and therefore no
conjuncts, and pushes one ready-made pattern instead."
  (org-agents--rg-files-for (org-agents--rg-conjunct-patterns conjuncts) root))

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

(defun org-agents--narrowed-files (scope patterns what refuse)
  "Resolve SCOPE to files, narrowing an unbounded one with ready-made PATTERNS.
A scope that NAMES its files is returned as it stands: prefiltering an
`agenda' scope or an explicit list would spend a subprocess to narrow a
set that is already small, and measured, that makes the common case 5 to
25 times slower to reach the same answer.

For an unbounded scope the PATTERNS are run and the answer is intersected
with the scope's own file list.  An EMPTY answer is an answer -- the
caller sees nothing -- and only a failure, a missing ripgrep, no pattern
at all, or `org-agents-prefilter' set to nil sends this down the fallback
below.

WHAT names the kind of thing that had nothing to push, and appears in the
reason a fallback and a refusal both quote: `conjunct' for an agent,
whose patterns come from its query.

REFUSE says whether `org-agents-prefilter' set to `require' refuses this
caller's unnarrowable scope, which is a question about the CALLER and not
about the scope.  An agent passes non-nil: `require' exists so that
someone would rather be told an agent cannot be answered affordably than
wait for a live walk of the whole corpus.  `org-agents-check-attributes'
passes nil, and here is the argument.  A refusal is only ever a refusal
to run a QUERY; a lint that declined to run would not be declining an
expense on the user's behalf, it would be failing its own contract, and
it is a command the user typed rather than something a save set off.  The
live scan still says so, with its file count, so the cost is explained
either way.  Spelled as an argument and not as a `let' around the option,
because a caller quietly rebinding a user's setting is exactly what this
must not do.

The base files are gathered only where they will be used: for an
unbounded scope, gathering them is the recursive walk the prefilter
exists to make unnecessary."
  (if (not (org-agents--needs-prefilter-p scope))
      (org-agents--scope-base-files scope)
      ;; Before anything is spawned, so a mistyped directory is named as
      ;; one rather than as a prefilter failure.
      (let* ((root (org-agents--scope-root scope))
             (reason
              (cond ((null org-agents-prefilter) "prefiltering off")
                    ((null patterns) (format "no pushable %s" what))
                    ((not (org-agents--rg-available-p)) "ripgrep not found")))
             (candidates (unless reason
                           (org-agents--rg-files-for patterns root))))
        (cond ((eq candidates 'unavailable) (setq reason "ripgrep failed"))
              ;; Belt: every pattern declined, so nothing ran and nothing
              ;; was narrowed.  `t' is not the empty answer.
              ((eq candidates t) (setq reason (format "no pushable %s" what))))
        (cond
         (reason
          (when (and refuse (eq org-agents-prefilter 'require))
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
                                    candidates))))))

(defun org-agents--scope-files (agent)
  "Resolve AGENT's scope to files, narrowing an unbounded scope with ripgrep.
`org-agents--narrowed-files' over the patterns AGENT's query offers, and
every word of that function's contract holds here unchanged."
  (org-agents--narrowed-files
   (plist-get agent :scope)
   (org-agents--rg-conjunct-patterns
    (org-agents--prefilter-conjuncts (plist-get agent :query)))
   "conjunct" t))

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
    ;; `org-agents--in-attributes-batch', and it is a SOUNDNESS
    ;; requirement rather than a saving: the splitter and the predicate
    ;; must read one registry.  See that function for the argument.
    (org-agents--in-attributes-batch
     (lambda ()
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
         (if limit (take limit matches) matches))))))

;;;; Registry

;; A corpus-wide attribute registry: one Org file whose every top-level
;; entry declares one user attribute -- its type, its default, the
;; values it admits, the faces it is drawn in, and what it is for.  The
;; heading is the name, the drawer carries the fields, and the body is
;; the documentation.
;;
;; PURE DATA, and that is a property of the format rather than a promise
;; about it.  Every field is read with `org-entry-get' and used as a
;; string, as one of six symbols out of a fixed table, or as a face
;; name: there is nothing a registry file can hold that this package
;; will `eval', `read', or run.  Contrast `:AGENT_QUERY:', which is Lisp
;; and is gated for exactly that reason.
;;
;; Below Collection rather than above it because everything here reads a
;; drawer through `org-agents--entry-get', and because
;; `org-agents-check-attributes' resolves its scope through
;; `org-agents--narrowed-files'.  The dependencies all point upward.

(defcustom org-agents-attributes-file "~/org/attributes.org"
  "The Org file declaring this corpus's user attributes.
Each top-level entry declares one: the heading is the attribute's name,
the drawer carries `:ATTR_TYPE:', `:ATTR_DEFAULT:', `:ATTR_VALUES:' and
`:ATTR_FACES:', and the body is its documentation.  See
`org-agents-attribute' for the declaration a reader gets back, and
`org-agents-attribute-valid-p' for what each type admits.

The file is optional.  One that is missing or unreadable declares
nothing, and says nothing about it.

Pure data.  Nothing in this file is ever evaluated, and there is no
value it can hold that this package will run.

Risky all the same: it says which file gets opened and read on every
property completion in every Org buffer, and what values that completion
then offers -- so a file-local setting could point it at a file outside
the corpus and quietly change the vocabulary the user is offered."
  :type 'file
  :risky t
  :group 'org-agents)

(defconst org-agents--attribute-types '(string number date boolean set list)
  "The values `:ATTR_TYPE:' may take.
`set' and `list' are Tinderbox's: a set is unordered and deduplicating, a
list is ordered and admits duplicates.  Tinderbox separates their members
with semicolons; here they are separated by WHITESPACE, which is what
Org's own `NAME_ALL' convention uses and therefore what
`org-property-get-allowed-values' already reads.")

(defconst org-agents--attribute-type-names
  (mapcar #'symbol-name org-agents--attribute-types)
  "`org-agents--attribute-types' as text, for comparing an unread type.
A type is compared as a STRING before it is interned: `intern' of a
misspelling would answer a symbol that is not in the table but is now in
the obarray, and `intern-soft' would answer non-nil for a misspelling
some other library had already interned.")

(defconst org-agents--attribute-boolean-values '("true" "false")
  "What a `boolean' attribute may hold, and the only values it completes.
Tinderbox's spelling: unquoted keywords, lower case, and no others --
`t', `yes' and `True' are not booleans.  Synthesized by the READER onto
every boolean declaration, so completion needs no type dispatch and the
lint's vocabulary check and its type check are one check.")

(defconst org-agents--attr-number-re
  "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\'"
  "What a `number' attribute's value must look like, whole.
A signed integer or decimal, and NO exponent: Tinderbox's numbers are
\"int or float, signed\", and `1e3' in a drawer is far more likely to be
a product code than a thousand.  Anchored at both ends, so `3 4' -- which
is what `org-entry-get' answers for a `:N: 3' beside a `:N+: 4' -- is not
a number, and is reported as one thing rather than passing as two.")

(defconst org-agents--prototypes-section "Prototypes"
  "The top-level registry heading whose subtree holds the prototypes.
Spelled once, here, and read by two things that must not drift apart: the
declaration reader below skips it, because it declares no attribute, and
`org-agents--prototypes-scan' scans exactly its subtree.  See the
`Prototypes' section of this file for what a prototype is.")

(defconst org-agents--attributes-reserved
  (list org-agents--prototypes-section)
  "Top-level registry headings that declare no attribute.
Skipped SILENTLY, where any other top-level entry with no `:ATTR_TYPE:'
is named.  `Prototypes' is reserved because the prototype entries live in
a top-level section of this same file, and taking the name from
`org-agents--prototypes-section' is what keeps the heading this reader
skips and the heading the resolver scans from becoming two headings.")

(defvar org-agents--attributes-cache nil
  "`(KEY . ALIST)' for the registry as last read, or nil.
KEY is `org-agents--file-cache-key' as it stood at the time of the
read, and ALIST is `(NAME . PLIST)' in file order.  One cons rather than
a hash table keyed by file name: `org-agents-attributes-file' names ONE
file, and a table keyed on it would grow one entry that never got a
second.")

(defvar org-agents--attributes-fresh nil
  "Non-nil while the registry file's caches are known to be up to date.
Both of them: `org-agents--attributes-cache' and
`org-agents--prototypes-cache' are read out of the same file, keyed the
same way, and brought up to date together -- see
`org-agents--warm-attributes'.  It also suppresses revalidation of
`org-agents--prototype-id-cache', whose entries are keyed on files of
their own.

Bound by `org-agents--with-attributes' and by
`org-agents--in-attributes-batch', and by nothing else, around a
BATCH of look-ups that all want the same answer.

The cache hit itself is one `equal', but computing the key it is compared
against is not free: `org-agents--file-cache-key' calls
`file-truename' and `find-buffer-visiting', and the second of those walks
the whole buffer list and truenames each buffer's file name.  And
`org-agents-check-attributes' looks a name up once per drawer line while
visiting every file in scope, so the buffer list grows under it as it
goes and the cost of the key alone grows as the square of the corpus.
MEASURED, over fixture corpora of 20 entries and two linted lines each:
200 files cost 1.57 s with the key computed once per command and 4.43 s
with it computed per look-up; 600 files cost 4.96 s and 33.93 s.

Within one batch that is not merely faster but no less correct: the
registry cannot be edited by the user in the middle of a synchronous
command, and this package never writes it.")

(defmacro org-agents--with-attributes (&rest body)
  "Run BODY with the registry read at most once, however often it is asked.
The key is computed and both caches the registry file feeds are brought up
to date ONCE, here, and every `org-agents-attribute',
`org-agents-attributes' and `org-agents-resolve-property' inside BODY then
answers from them with no further look at the file system -- see
`org-agents--attributes-fresh' for what that saves and why it is sound.

For a batch of look-ups over a corpus.  A single completion needs nothing
of this: it wants the freshest answer there is, which is what the cache
gives it unwrapped.

An UPDATE wants `org-agents--in-attributes-batch' instead, which adds the
once-per-update diagnostic table and may be called from above its own
definition.  This macro is what a reader in this section reaches for."
  (declare (indent 0) (debug t))
  `(progn
     (org-agents--warm-attributes)
     (let ((org-agents--attributes-fresh t))
       ,@body)))

(defun org-agents--attr-warn (name file reason)
  "Say that the registry entry NAME in FILE is REASON.
Said once per edit to the registry however many times a declaration is
looked up afterwards, because this is called from the READER and
`org-agents--attributes-alist' calls that at most once per cache key.  A
re-read after an edit says it again, which is right: the user has just
been editing the file.

A `message' and not a `user-error': a registry with one bad entry
declares the other forty, and a completion that signalled would make the
whole file unusable until it was perfect."
  (message "org-agents: attribute `%s' in %s: %s"
           name (abbreviate-file-name file) reason))

(defun org-agents--attr-split (value)
  "The whitespace-separated members of VALUE, as a list.
Empty members are dropped, so a value padded or doubly spaced has the
members it looks like it has.  The separator is whitespace because that
is what Org's own `NAME_ALL' convention uses."
  (split-string (or value "") nil t))

(defun org-agents--attr-parse-faces (raw)
  "Read RAW as `VALUE FACE | VALUE FACE ...', or nil when it is not that.
Nil for anything that does not split cleanly into two-word groups, so a
misspelled line costs the faces and not the declaration.

Deliberately not `read': the registry is data, and a `read' here would be
the one place in it where a file could hand this package a form.  `intern'
rather than `intern-soft' because a face this names may well be defined
after the registry is first read, and a symbol is not a value that runs."
  (let ((pairs nil)
        (clean t))
    (dolist (group (split-string (or raw "") "|" t))
      (let ((words (split-string group nil t)))
        (if (= 2 (length words))
            (push (cons (car words) (intern (cadr words))) pairs)
          (setq clean nil))))
    (and clean pairs (nreverse pairs))))

(defun org-agents--attr-vocabulary-ok-p (member values)
  "Non-nil when MEMBER is admitted by the declared VALUES.
Nil VALUES declares no vocabulary at all and admits everything.

So does a vocabulary holding `\":ETC\"'.  That is Org's own marker for
\"these are defaults, other values should be allowed too\" -- see
`org-property-allowed-value-functions' -- and a lint that reported a
value outside an explicitly OPEN vocabulary would be reporting the
declaration rather than the value.  `\":ETC\"' is never itself a
member: it is a word about the set, not one of its elements."
  (and (not (equal member ":ETC"))
       (or (null values)
           (and (member ":ETC" values) t)
           (and (member member values) t))))

(defun org-agents--attr-date-p (value)
  "Non-nil when VALUE names a day that exists.
Two halves, and both are needed.  MEASURED: `org-parse-time-string' reads
`[2020-13-45 Xyz]' as day 45 of month 13 and `[2020-02-30 Sun]' as the
thirtieth of February, without complaint in either case -- so the syntax
check alone admits two dates no calendar has.  The round trip through
`encode-time' and `decode-time' is what catches them: 45/13/2020 comes
back as 14/2/2021.

`org-timestamp-from-string' is not used, and this is why: MEASURED, it
accepts that same impossible `[2020-13-45 Xyz]' and REJECTS the plain
`2020-01-01' a user will certainly write, and it needs `org-element'
loaded or it dies with a void function in batch."
  (when-let* ((parsed (ignore-errors (org-parse-time-string value t)))
              (day (nth 3 parsed))
              (month (nth 4 parsed))
              (year (nth 5 parsed)))
    (let ((back (decode-time
                 (encode-time (list 0 0 12 day month year nil -1 nil)))))
      (and (= day (nth 3 back))
           (= month (nth 4 back))
           (= year (nth 5 back))))))

(defun org-agents-attribute-valid-p (type value &optional values)
  "Non-nil when VALUE is a valid value of TYPE, admitting only VALUES.
TYPE is one of `org-agents--attribute-types' and VALUE is the text of a
property, which is all an Org property value ever is.  VALUES is the
declared vocabulary, `:ATTR_VALUES:' split into members; nil declares
none and admits anything the type does.

  `string'   any text.  With VALUES, the whole trimmed value must be a
             member -- compared case-SENSITIVELY, because a declared
             vocabulary is one the user wrote down.
  `number'   `org-agents--attr-number-re': signed integer or decimal.
  `date'     `org-agents--attr-date-p': parses, and names a real day.
  `boolean'  `true' or `false', and nothing else.  VALUES is ignored:
             the type already fixes the set, and the reader synthesizes
             it rather than reading one.
  `set'      every whitespace-separated member is admitted by VALUES,
             and NO member repeats.  The empty set is valid.
  `list'     every member is admitted by VALUES.  Duplicates are fine
             and order is significant.

Answers about a whole property value, so `set' and `list' fall out of the
same vocabulary rule one member at a time.  It is a predicate and not a
diagnosis: the caller that wants to tell \"outside the vocabulary\" from
\"not of the type\" asks twice, once without VALUES."
  (let ((text (string-trim (or value ""))))
    (pcase type
      ('string (org-agents--attr-vocabulary-ok-p text values))
      ('number (and (string-match-p org-agents--attr-number-re text)
                    (org-agents--attr-vocabulary-ok-p text values)))
      ('date (and (org-agents--attr-date-p text)
                  (org-agents--attr-vocabulary-ok-p text values)
                  t))
      ('boolean (and (member text org-agents--attribute-boolean-values) t))
      ((or 'set 'list)
       (let ((members (org-agents--attr-split text)))
         (and (cl-every (lambda (member)
                          (org-agents--attr-vocabulary-ok-p member values))
                        members)
              (or (eq type 'list)
                  (= (length members)
                     (length (delete-dups (copy-sequence members))))))))
      (_ nil))))

(defun org-agents--attr-special-p (name)
  "Non-nil when Org answers for NAME before this package is ever consulted.
`org-property-get-allowed-values' answers for `TODO' and `PRIORITY' out
of clauses of its own, returns nil for `CATEGORY' and for every member of
`org-special-properties', and only then runs
`org-property-allowed-value-functions'.  So no declaration of such a name
can complete anything, whatever it says.

The declaration is still worth keeping: `org-agents-check-attributes'
reads it, and a corpus that sets `:TAGS:' by hand in a drawer is a corpus
worth linting."
  (and (member-ignore-case name (cons "CATEGORY" org-special-properties)) t))

(defun org-agents--attr-doc ()
  "The documentation body of the registry entry at point, or nil for none.
Everything after the heading's own metadata -- its planning line and its
drawers -- down to the next heading of any level.  The next heading and
not the end of the subtree, so that a section holding child entries
documents itself rather than quoting its children.

Blank throughout is no documentation rather than the empty string, which
is the same rule `org-agents--entry-get' applies to a drawer field."
  (save-excursion
    (org-back-to-heading t)
    (org-end-of-meta-data t)
    (let* ((start (point))
           (end (if (org-at-heading-p)
                    start
                  (if (outline-next-heading) (point) (point-max))))
           (text (string-trim (buffer-substring-no-properties start end))))
      (unless (string-empty-p text) text))))

(defun org-agents--attr-declaration (name type file line warn)
  "The declaration at point: NAME, of TYPE, declared in FILE at LINE.
WARN is called with one string for each field that had to be discarded,
and for a name whose completion Org will never reach.  Point is on the
heading, and every field is read out of that entry's OWN drawer through
`org-agents--entry-get' -- no inheritance, and a field written with
nothing after it is a field that is not there.

`:default' stays the trimmed STRING the file holds, never a parsed number
or a decoded time.  An Org property value is a string: the lint compares
strings, and a later epic will write this one into a follower's drawer.
The parse happens here only to DIAGNOSE it, and its result is thrown
away."
  (let* ((raw-values (org-agents--entry-get "ATTR_VALUES"))
         (values (if (eq type 'boolean)
                     (progn
                       (when raw-values
                         (funcall warn (concat ":ATTR_VALUES: has no meaning"
                                               " for a boolean")))
                       (copy-sequence org-agents--attribute-boolean-values))
                   (and raw-values (org-agents--attr-split raw-values))))
         (raw-faces (org-agents--entry-get "ATTR_FACES"))
         (faces (and raw-faces (org-agents--attr-parse-faces raw-faces)))
         (default (org-agents--entry-get "ATTR_DEFAULT")))
    (when (and raw-faces (null faces))
      (funcall warn (format "unreadable :ATTR_FACES: `%s'" raw-faces)))
    (when (and default
               (not (org-agents-attribute-valid-p type default values)))
      (funcall warn (format ":ATTR_DEFAULT: `%s' is not a %s" default type))
      (setq default nil))
    (when (org-agents--attr-special-p name)
      (funcall warn (format (concat "`%s' is a special property;"
                                    " no completion is possible for it")
                            name)))
    (list :name name :type type :values values :default default
          :faces faces :doc (org-agents--attr-doc)
          :file file :line line)))

(defun org-agents--attributes-scan (file)
  "Read every declaration in the current buffer, which holds FILE's text.
FILE is named only so that a diagnosis can say where an entry is and a
declaration can carry `:file'; the text comes from this buffer.  The
answer is an alist of `(NAME . PLIST)' in file order.

Two tiers of malformation, and the distinction is the whole of the
policy: a bad TYPE costs the entry, a bad anything-else costs only that
field.  An entry with no readable type declares nothing that could be
completed or linted, while one whose default does not parse still has a
type worth both."
  (let ((declarations nil))
    (goto-char (point-min))
    (org-map-entries
     (lambda ()
       (let* ((name (org-get-heading t t t t))
              (line (line-number-at-pos))
              (type (org-agents--entry-get "ATTR_TYPE"))
              (warn (lambda (reason)
                      (org-agents--attr-warn name file reason))))
         (cond
          ((member name org-agents--attributes-reserved))
          ((not (and name (org--valid-property-p name)))
           (funcall warn (format "`%s' is not a property name" name)))
          ((null type) (funcall warn "no :ATTR_TYPE:"))
          ((not (member type org-agents--attribute-type-names))
           (funcall warn (format "unknown :ATTR_TYPE: `%s'" type)))
          ((assoc-string name declarations t)
           (funcall warn "declared twice; the first declaration stands"))
          (t (push (cons name (org-agents--attr-declaration
                               name (intern type) file line warn))
                   declarations)))))
     "LEVEL=1")
    (nreverse declarations)))

(defun org-agents--in-org-copy (file fn)
  "Call FN in a temporary Org buffer holding FILE's text, and answer what it does.
Filled either from the BUFFER visiting FILE where there is one or from
the file itself.  Three things fall out of that, and all three are
wanted:

  - An UNSAVED edit to FILE is what the next reader sees.  That is the
    case that matters: the user adds a value to `:ATTR_VALUES:', or
    changes a prototype's property, and expects the very next look-up to
    answer for it.
  - Nothing here visits FILE.  `find-file-noselect' would leave the
    user's own file visited by a buffer they never opened -- and it
    would flip `org-agents--file-cache-key' from its file half to
    its buffer half on the very first read, forcing a second one.
  - FN runs in an Org buffer of this function's own making, so it
    cannot move point in a buffer the user is editing, and needs no
    opinion about the mode that buffer happens to be in.

The copy is character-for-character FILE's text apart from
`#+SETUPFILE:', whose neutralization below is length-preserving on
purpose -- so a position found in one is the same position in the other,
which is what lets `org-agents--prototype-id-read' take a position from
`org-id' and use it here.

`#+SETUPFILE:' is neutralized in the COPY before the mode is enabled, and
that is not cosmetic.  `org-mode' collects keywords whatever
`org-inhibit-startup' says, and a `#+SETUPFILE:' is FOLLOWED: MEASURED,
enabling the mode over a registry naming one called `org-file-contents'
on it twice per read, and Org routes a URL there through
`url-retrieve-synchronously' and its own download-policy prompt.  So a
registry inheriting shared keywords the ordinary Org way would have made
a blocking fetch -- or asked a question -- from inside
`org-property-allowed-value-functions' while the user was answering an
`org-set-property' prompt in an unrelated buffer, and a missing setup
file would have messaged from there.  Nothing this reader wants is in a
setup file: it reads headings and property drawers, and both are Org
syntax rather than configuration.

Never signals.  The caller has established that FILE is readable, and a
file that stops being readable between that test and this read declares
nothing and is named once: an error raised here would reach the user out
of `org-set-property' in some entirely unrelated buffer.  So FN must not
be a function that has a signal of its own to raise -- both callers only
read text."
  (condition-case err
      (let ((text (when-let* ((buffer (find-buffer-visiting file)))
                    (with-current-buffer buffer
                      (save-restriction
                        (widen)
                        (buffer-substring-no-properties (point-min)
                                                        (point-max)))))))
        (with-temp-buffer
          (if text (insert text) (insert-file-contents file))
          (goto-char (point-min))
          (let ((case-fold-search t))
            (while (re-search-forward "^\\([ \t]*\\)#\\+SETUPFILE:" nil t)
              (replace-match "\\1# SETUPFILE:" t)))
          (let ((org-inhibit-startup t)
                (org-element-use-cache nil))
            (delay-mode-hooks (org-mode))
            (funcall fn))))
    (error (message "org-agents: cannot read %s: %s"
                    (abbreviate-file-name file) (error-message-string err))
           nil)))

(defun org-agents--attributes-read (file)
  "FILE's declarations as an alist of `(NAME . PLIST)', in file order.
Read in a copy: `org-agents--in-org-copy' says which copy, and why the
registry is never visited to read it."
  (org-agents--in-org-copy file
                           (lambda () (org-agents--attributes-scan file))))

(defun org-agents--file-cache-key (file)
  "What a cache over FILE is keyed on, or nil when FILE cannot be read.
Two halves, because the file may or may not be visited.  Where a buffer
is visiting it, the key carries that buffer and
its `buffer-chars-modified-tick' -- the same pair `org-ql--value-at' keys
its own node cache on -- so an UNSAVED edit invalidates.  Where no buffer
is visiting it, there is no tick to read and the key is the file's
modification time and size, which is all `file-attributes' has to offer.

Nil for a file that cannot be read, which is how a missing registry
declares nothing without anything being opened to find that out.

Not registry-specific, and the name says so: the registry's declarations,
the prototypes read out of the same file, and each file an id-named
prototype was read from are all keyed by this one function."
  (when (file-readable-p file)
    (let* ((true (file-truename file))
           (buffer (find-buffer-visiting true)))
      (if buffer
          (list true buffer (buffer-chars-modified-tick buffer))
        (let ((attributes (file-attributes true)))
          (list true
                (file-attribute-modification-time attributes)
                (file-attribute-size attributes)))))))

(defun org-agents--attributes-alist ()
  "The registry's declarations, read at most once per edit to the file.
A file that is missing or unreadable declares NOTHING and says nothing
about it: the registry is optional, and a package that reported its
absence would report it at every property completion in every Org
buffer.

The unreadable branch CLEARS the cache rather than answering from it.  A
registry that has been deleted declares nothing from that moment, and
going on answering what it used to say would be a stale answer with no
way back to a true one.

Inside `org-agents--with-attributes' the key is not recomputed at all:
the batch established it once on entry, and recomputing it per look-up is
what made a corpus-wide lint quadratic."
  (if org-agents--attributes-fresh
      (cdr org-agents--attributes-cache)
    (let ((file (expand-file-name org-agents-attributes-file)))
      (org-agents--attributes-alist-1 file
                                      (org-agents--file-cache-key file)))))

(defun org-agents--attributes-alist-1 (file key)
  "Read `org-agents--attributes-alist' answer for FILE, whose key is KEY.
Split out so that the fresh-cache short circuit above it is one branch
and this is the whole of the work it skips -- and so that
`org-agents--warm-attributes' can hand FILE and KEY to this reader and to
the prototype reader beside it, having computed the key ONCE for both."
  (cond
   ((null key) (setq org-agents--attributes-cache nil))
   ((equal key (car org-agents--attributes-cache))
    (cdr org-agents--attributes-cache))
   (t (cdr (setq org-agents--attributes-cache
                 (cons key (org-agents--attributes-read file)))))))

(defun org-agents--warm-attributes ()
  "Bring both of the registry file's caches up to date, keying it ONCE.
The declarations and the prototypes come out of the same file, so one
`org-agents--file-cache-key' answers for both -- and it has to be one
call rather than two, because that key is the expensive half: see
`org-agents--attributes-fresh' for the measurement.

Called by `org-agents--with-attributes' and by
`org-agents--in-attributes-batch', and by nothing else."
  (let* ((file (expand-file-name org-agents-attributes-file))
         (key (org-agents--file-cache-key file)))
    (org-agents--attributes-alist-1 file key)
    (org-agents--prototypes-alist-1 file key)))

(defun org-agents-attribute (name)
  "The registry's declaration of NAME as a plist, or nil when it has none.
NAME is matched case-insensitively, which is how Org matches a property
key: a drawer line reading `:status: open' is a value of a declared
`STATUS'.

The plist, in this order:

  `:name'     the name as the registry spells it.
  `:type'     one of `org-agents--attribute-types'.
  `:values'   `:ATTR_VALUES:' split into members, or nil for a name that
              declares no vocabulary.  A `boolean' answers
              `org-agents--attribute-boolean-values', which is in no
              drawer: the reader synthesizes it.
  `:default'  `:ATTR_DEFAULT:' as TEXT, or nil where there is none or
              where what was written does not parse as the type.
  `:faces'    `((VALUE . FACE) ...)', which `org-agents-faces-mode'
              draws a headline with.  Read here and never re-parsed: see
              `org-agents--faces-declared'.
  `:doc'      the entry's body, or nil.
  `:file'     the registry, expanded.
  `:line'     the heading's line in it, so that a diagnosis about the
              registry itself is as navigable as one about the corpus.

Reads through `org-agents--attributes-alist', so the file is opened at
most once per edit to it."
  (cdr (assoc-string name (org-agents--attributes-alist) t)))

(defun org-agents-attributes ()
  "The names the registry declares, in the order the file declares them.
File order rather than sorted: the registry is a document, and the order
its author chose is information."
  (mapcar #'car (org-agents--attributes-alist)))

;;;###autoload
(defun org-agents-allowed-values (property)
  "Allowed values for PROPERTY out of the registry, or nil for none.
Written for `org-property-allowed-value-functions', whose contract this
matches exactly: one argument, a FLAT LIST of strings, and nil for a
property this is not responsible for.  Turn it on with

  (add-hook \\='org-property-allowed-value-functions
            #\\='org-agents-allowed-values)

after which `org-set-property' completes declared values in every Org
buffer.  Never added at load time: a library has no business mutating a
user's hook.

Three things this must not do, each of them measured.

Answer for an UNDECLARED name, or for a declared name carrying no
`:ATTR_VALUES:'.  `org-property-get-allowed-values' consults this hook
from a `cond' clause ABOVE the one that reads `NAME_ALL', and with
`run-hook-with-args-until-success', so any non-nil answer SHADOWS every
`_ALL' declaration in the corpus for that name.  Measured: a hook
answering for `STATUS' beat a `:STATUS_ALL: a b c' in the entry's own
drawer.  So nil is how a name is left alone, and the empty list would be
an answer rather than the absence of one.

Return the cached list.  Where the vocabulary ends in `:ETC',
`org-property-get-allowed-values' calls `org-add-props' on the first
string of the list it was handed, and `org-add-props' adds text
properties IN PLACE.  Measured: a hook that returned its own cached list
left `(org-unrestricted t)' on that list's first string for the rest of
the session.  Hence `copy-sequence' on every member.

Filter `:ETC' out.  It is Org's own marker for \"these are defaults,
other values should be allowed too\", and dropping it would turn an open
vocabulary into a closed one: `org-read-property-value' reads
REQUIRE-MATCH off the `org-unrestricted' text property that `:ETC' is
what puts there.

A vocabulary of `:ETC' and nothing else is not an answer, though, and is
the one case where the marker alone must be declined.  MEASURED: Org
removes `:ETC' from the list this hook hands it and is then left with an
empty one, so `org-property-get-allowed-values' answered nil -- while the
non-nil answer had already shadowed the `NAME_ALL' declarations that
would otherwise have supplied the corpus's own values.  Offering nothing
where Org would have offered something is worse than declining.

A `boolean' answers its two values because the READER synthesized them,
so there is no type dispatch here at all; a `set' or a `list' answers its
member vocabulary, which is what completing one member needs.  And
fourteen names plus `CATEGORY' never reach this function -- Org answers
for them in clauses of its own -- which the reader says once, at the
declaration."
  (when-let* ((attr (org-agents-attribute property))
              (values (plist-get attr :values)))
    (when (cl-remove ":ETC" values :test #'equal)
      (mapcar #'copy-sequence values))))

;; The lint.  It reads a scope and says what the registry does not account
;; for, and it edits NOTHING: a normalisation that looked like a kindness
;; would be a command rewriting a corpus nobody asked it to rewrite.

(defconst org-agents--attributes-exempt
  (append '("ID")
          '("ARCHIVE_TIME" "ARCHIVE_FILE" "ARCHIVE_OLPATH"
            "ARCHIVE_CATEGORY" "ARCHIVE_TODO" "ARCHIVE_ITAGS")
          org-special-properties
          org-default-properties)
  "Property names `org-agents-check-attributes' never asks the registry about.
Org's own, in two lists it publishes: `org-special-properties', the
fourteen `org-property-get-allowed-values' short-circuits before this
package is ever consulted, and `org-default-properties', the
twenty-seven Org itself writes or reads.

Plus `ID', which `org-id' writes and which is in NEITHER of those lists
-- MEASURED at 36,991 uses in the author's corpus, so leaving it out
would drown every real finding in one name.  Plus the six
`org-archive-subtree' writes from `org-archive-save-context-info',
MEASURED at 21,572 uses for `ARCHIVE_TIME' and 21,476 for
`ARCHIVE_CATEGORY'.

Names matching `org-agents--attributes-exempt-re' are exempt as well.")

(defconst org-agents--attributes-exempt-re
  "\\`\\(?:AGENT_\\|ATTR_\\)\\|_ALL\\'"
  "Property names exempt by SHAPE rather than by listing.
`AGENT_' is this package's own vocabulary and `ATTR_' is the registry
file's own -- which matters because the registry commonly lives inside
the scope being checked, and would otherwise have every one of its own
declarations reported as an undeclared property.

A `_ALL' suffix is Org's allowed-values convention and not a user
attribute: `STATUS_ALL' is a declaration ABOUT `STATUS', not a property
of its own, and reporting it would be reporting the vocabulary as a
violation of itself.")

(defun org-agents--attr-exempt-p (name)
  "Non-nil when property NAME is one the registry is never asked about.
Case-insensitively against `org-agents--attributes-exempt', because Org
matches a property key that way, and by shape against
`org-agents--attributes-exempt-re'.  Tested BEFORE the registry is
consulted, so an exempt name is never reported as undeclared.

NAME is a property name and not a raw drawer key: the caller strips a
trailing `+' first, so that `:ID+:' is as exempt as `:ID:' and a
`:STATUS_ALL+:' is as exempt as the `:STATUS_ALL:' it extends."
  (or (and (member-ignore-case name org-agents--attributes-exempt) t)
      (and (string-match-p org-agents--attributes-exempt-re name) t)))

(defun org-agents--attr-line-finding (key value joined)
  "What is wrong with the drawer line KEY / VALUE, or nil when nothing is.
JOINED is a function of a property name answering what `org-entry-get'
answers for it at this entry -- which is not the text of any one line,
and is why it is asked for separately.

Three kinds of finding, which is all this reports:

  - a name in use that the registry does not declare;
  - a value that does not parse as the declared `:ATTR_TYPE:';
  - a value outside the declared `:ATTR_VALUES:'.

Four things Org does that a naive reading of a drawer gets wrong, each
MEASURED against one drawer holding `:STATUS: open', `:STATUS+: extra',
`:status: lower', `:REVIEWS: 3' and `:STATUS_ALL: open wip'.

Keys match case-INSENSITIVELY, so `:status:' is a value of a declared
`STATUS'.  Hence `org-agents-attribute', which looks a name up the way
Org does.

A `+' key ACCUMULATES: `org-entry-get' answered \"lower extra\" for
`STATUS' there, and answers \"3 4\" for a `:REVIEWS: 3' beside a
`:REVIEWS+: 4'.  So for a scalar type -- one value, however many lines
spell it -- the value to judge is the JOINED one, and the line to report
it on is the `+' line that made it that: the earlier line was fine until
this one arrived.  For a `set' or a `list' a `+' line simply contributes
more members, and its own fragment is judged.

A value written with nothing after it is no value: `org-agents--entry-get'
says so for the registry's own fields, and the same rule holds here.  The
NAME is still in use, so an undeclared one is still reported; there is
just no value to typecheck.

And `org-entry-properties' is not what walks the drawer, because it
answered `(\"CATEGORY\" \"STATUS_ALL\" \"REVIEWS\" \"STATUS\")' for that
drawer: it SYNTHESIZES `CATEGORY', which is on no line, and collapses the
three `STATUS' spellings into one.  A finding must point at a line that
exists."
  (let* ((accumulates (string-suffix-p "+" key))
         (name (if accumulates (substring key 0 -1) key)))
    ;; The exemption is tested on the NAME and not on the raw key.  A `+'
    ;; is how Org spells an addition to a value, not part of the name it
    ;; adds to: `:STATUS_ALL+: done' extends the vocabulary of `STATUS'
    ;; the ordinary Org way, and testing the key would have reported
    ;; `STATUS_ALL' -- the vocabulary as a violation of itself -- and
    ;; would have let `:ID+:' and `:ARCHIVE_TIME+:' through the two
    ;; exemptions that suppress about 58,000 findings on the author's
    ;; corpus.
    (unless (org-agents--attr-exempt-p name)
      (let ((attr (org-agents-attribute name)))
        (cond
         ((null attr)
          (format "%s is not declared in %s" name
                  (abbreviate-file-name
                   (expand-file-name org-agents-attributes-file))))
         (t
          (let* ((type (plist-get attr :type))
                 (values (plist-get attr :values))
                 (text (if (and accumulates (not (memq type '(set list))))
                           (funcall joined name)
                         value))
                 ;; A `set' forbids a REPEAT, and a repeat is a thing no
                 ;; single line can show: `:STATUS: open' beside a
                 ;; `:STATUS+: open' is `open open', which is not a set.
                 ;; So the accumulating line of a set is judged on its
                 ;; own fragment for membership -- which is what
                 ;; completing one member needs -- and on the joined
                 ;; value for the one rule that distinguishes a set from
                 ;; a list.
                 (all (and accumulates (eq type 'set)
                           (funcall joined name))))
            (cond
             ((or (null text) (string-blank-p text)) nil)
             ((not (org-agents-attribute-valid-p type text))
              (format "%s: `%s' is not a %s" name text type))
             ((not (org-agents-attribute-valid-p type text values))
              (format "%s: `%s' is not one of %s" name text
                      (string-join values " ")))
             ((and all (not (org-agents-attribute-valid-p type all)))
              (format "%s: `%s' is not a %s" name all type))))))))))

(defun org-agents--attr-drawer-findings (file where)
  "Findings for the property drawer belonging to position WHERE, newest first.
FILE is what each finding names.  WHERE is where `org-entry-get' is asked
what a property accumulates to -- a heading, or a position before the
first heading for a file-level drawer.

The drawer is found with `org-get-property-block' -- Org's own answer to
where the properties belonging to a position are -- and walked with
`org-property-re', Org's own answer to what a property line is.  The
block's range excludes the `:PROPERTIES:' and `:END:' lines, both of
which `org-property-re' would otherwise match as keys."
  (let ((findings nil))
    (save-excursion
      (goto-char where)
      (when-let* ((block (org-get-property-block)))
        (goto-char (car block))
        (beginning-of-line)
        (while (< (point) (cdr block))
          (when (looking-at org-property-re)
            (when-let* ((text (org-agents--attr-line-finding
                               (match-string-no-properties 2)
                               (match-string-no-properties 3)
                               (lambda (name) (org-entry-get where name)))))
              (push (format "%s:%d: %s" file (line-number-at-pos) text)
                    findings)))
          (forward-line 1))))
    findings))

(defun org-agents--attr-buffer-findings (file)
  "`(ENTRIES . FINDINGS)' for the current buffer, whose file is FILE.
Every heading is counted, so a clean report can say what it looked at,
and every line of every property drawer is one finding site.

The drawer BEFORE the first heading is walked as well, and is counted as
no entry because it is none.  It is a real property block all the same:
MEASURED, `org-entry-get' at `point-min' answers `x' for a `:WIDGET: x'
written there, and with `org-use-property-inheritance' on every entry in
the file sees it -- so a lint that skipped it would call a file clean
while a misspelled name and an unparseable value sat at the top of it."
  (let ((entries 0)
        (findings nil))
    (org-with-wide-buffer
     (goto-char (point-min))
     (when (org-before-first-heading-p)
       (setq findings (org-agents--attr-drawer-findings file (point-min))))
     (goto-char (point-min))
     (org-map-entries
      (lambda ()
        (cl-incf entries)
        (setq findings
              (nconc (org-agents--attr-drawer-findings file (point))
                     findings)))))
    (cons entries (nreverse findings))))

(defun org-agents--attr-findings (files)
  "`(ENTRIES . FINDINGS)' over FILES, continuing past one that cannot be read.
The per-file `condition-case' is the same guard `org-agents-update-all'
carries and for the same reason: `find-file-noselect' can fail or ask a
question of its own -- a file grown past `large-file-warning-threshold',
one changed on disk since it was last visited, a coding system that
cannot decode it -- and one such file must not take the whole run with
it.  The file is NAMED, on a line of the same navigable shape, so the
report says what it could not read rather than quietly reading less than
it was asked to."
  (let ((entries 0)
        (findings nil))
    (dolist (file files)
      (condition-case err
          (with-current-buffer (find-file-noselect file)
            (pcase-let ((`(,n . ,fs) (org-agents--attr-buffer-findings file)))
              (cl-incf entries n)
              (setq findings (nconc findings fs))))
        (error
         (setq findings
               (nconc findings
                      (list (format "%s:1: cannot be read: %s" file
                                    (error-message-string err))))))))
    (cons entries findings)))

(defconst org-agents--attributes-buffer "*org-agents attributes*"
  "Name of the buffer `org-agents-check-attributes' shows.")

(defun org-agents--attr-clean-line (files entries)
  "The one line a run over FILES and ENTRIES with no findings writes.
A command that popped an empty buffer would look broken, and the counts
are what say the run really looked at something: a scope that resolved to
no file at all reads as clean otherwise, and reads as clean loudly."
  (let ((declarations (length (org-agents-attributes))))
    (format (concat "org-agents: no findings; every property in scope is"
                    " declared and valid\n(%d file%s, %d entr%s,"
                    " %d declaration%s)")
            (length files) (if (= 1 (length files)) "" "s")
            entries (if (= 1 entries) "y" "ies")
            declarations (if (= 1 declarations) "" "s"))))

(defun org-agents--attr-report (findings files entries)
  "Show FINDINGS over FILES and ENTRIES, and return how many there were.
`compilation-mode', and not one line of navigation code.  MEASURED: with
findings of the shape `FILE:LINE: TEXT' inserted into a buffer,
`compilation-mode' parsed every one of them as an error -- so `RET',
`next-error' and `M-g n' all work here for free.

The lines go in FIRST and the mode is set after, because the mode makes
the buffer read-only.  `default-directory' is set after that in turn,
because `compilation-mode' runs `kill-all-local-variables': it is
`org-directory', so that a relative name could never resolve against
wherever the command happened to be called from.  Every path emitted is
absolute, so that is belt rather than braces."
  (let ((buffer (get-buffer-create org-agents--attributes-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if findings
            (dolist (finding findings) (insert finding "\n"))
          (insert (org-agents--attr-clean-line files entries) "\n")))
      (compilation-mode)
      (setq-local default-directory (expand-file-name org-directory))
      (goto-char (point-min)))
    (display-buffer buffer)
    (message "org-agents: %d finding%s over %d file%s"
             (length findings) (if (= 1 (length findings)) "" "s")
             (length files) (if (= 1 (length files)) "" "s"))
    (length findings)))

;;;###autoload
(defun org-agents-check-attributes (scope)
  "Report every property in SCOPE the registry does not account for.
SCOPE takes the same values `:AGENT_SCOPE:' does -- `agenda' (the
default), `active', `all', a directory relative to `org-directory', or a
`read'-able list of file names -- and is read by the very same
`org-agents--read-scope', so the two vocabularies cannot drift.

Three kinds of finding, and NOTHING is edited:

  - a property name in use that the registry does not declare;
  - a value that does not parse as its `:ATTR_TYPE:';
  - a value outside its `:ATTR_VALUES:'.

Org's own vocabulary is never asked about, nor this package's, nor the
registry file's own -- see `org-agents--attributes-exempt'.  Without
those exemptions `ID' alone would be about 37,000 findings on the
author's corpus.

A corpus scope is narrowed through the same ripgrep machinery an agent
uses, and with `org-agents--rg-drawer-pattern' -- a provable superset of
the files that could hold a finding -- then falls back to a live scan
with one message naming the file count, exactly as an agent's does.  It
never refuses, and `org-agents-prefilter' set to `require' does not make
it: an agent may fairly be told its query cannot be answered affordably,
where a lint that declined to run would fail its own contract.  Nor is
the option rebound behind the user's back -- see the REFUSE argument of
`org-agents--narrowed-files'.

The findings go into a `compilation-mode' buffer, one per line, each
`FILE:LINE:' and so navigable with `RET' and `next-error'.  A run with
nothing to report says so there, with its counts, rather than popping an
empty buffer.

Every file in scope is left VISITED, as `org-agents-update-all' leaves
the files it wrote to.  Over a corpus that is thousands of buffers, and
nothing here reaps them: killing a buffer this command opened would be
indistinguishable, from inside, from killing one the user had open
already.  `M-x org-agents-check-attributes' over `all' is therefore a
command with a footprint, and README's \"Honest limitations\" says so.

The registry is read ONCE for the whole run -- see
`org-agents--with-attributes'.  Recomputing the cache key per look-up
made the run quadratic in the corpus."
  (interactive
   (list (org-agents--read-scope
          (completing-read "Scope: " org-agents--scope-names nil nil
                           "agenda"))))
  (let ((files (org-agents--narrowed-files
                scope (list org-agents--rg-drawer-pattern) "pattern" nil)))
    (org-agents--with-attributes
      (let ((found (org-agents--attr-findings files)))
        (org-agents--attr-report (cdr found) files (car found))))))

;; The `COLUMNS' generator, and the one thing this epic does NOT build.
;;
;; MEASURED: `org-agenda-columns' already runs inside an `org-ql-search'
;; results buffer.  That buffer is an `org-agenda-mode' one carrying
;; `org-hd-marker' on every line, and `org-agenda-columns' itself reads
;; the format from the matched entry's inherited `:COLUMNS:' -- the
;; `(org-entry-get m "COLUMNS" t)' arm of its own `cond', which
;; `org-overriding-columns-format', `org-local-columns-format' and the
;; `org-columns-default-format-for-agenda' option all outrank -- and an
;; edit goes back to the source file through
;; `org-columns-edit-value'.  (Not `org-columns-get-format': that reads
;; `(org-entry-get nil "COLUMNS" t)', which in an agenda buffer is the
;; agenda buffer's own absent property.)  So corpus-wide
;; displayed attributes with write-back editing exist today, and what was
;; missing was a format string.  This generates one; README's
;; "Corpus-wide column view" is the recipe.  No renderer is written here
;; and none is wanted.

(defconst org-agents--attribute-column-operators
  '((number . "+"))
  "The `COLUMNS' summary operator each `:ATTR_TYPE:' earns, where any.
Only `number' gets one, and it gets `+' -- the sum,
`org-columns--summary-sum' in `org-columns-summary-types-default'.
Nothing else is defensible from a TYPE alone.  `X' means the column is
read as a checkbox and a `boolean' here is the text `true'/`false'; `:'
and `@' read a column as a duration and as an age, which a `date' may or
may not be; and a summary over a `set' or a `string' has no meaning at
all.  A user who wants one writes it into the `:COLUMNS:' line by hand --
this command generates a starting point, not a policy.")

(defconst org-agents--attribute-column-name-re "\\`[[:alnum:]_-]+\\'"
  "What a property name must look like to be spellable in a `COLUMNS' format.
Not this package's rule: it is the character class
`org-columns-compile-format' matches a column's property with, `(in alnum
\"_-\")'.  A name holding anything else is TRUNCATED at the offending
character rather than rejected -- MEASURED, `%HAS=EQ %WITH.DOT{+}'
compiled to columns named `HAS' and `WITH', and the number's summary
operator was dropped with it -- and Org accepts such a name as a property
perfectly well, since `org--valid-property-p' rejects only whitespace.
So the registry may declare one and only the column view cannot spell
it.")

;;;###autoload
(defun org-agents-attribute-columns (names &optional insert)
  "Return a `COLUMNS' format for the registry attributes NAMES.
`%ITEM' first, so a column view has something to name its rows by, then
one `%NAME' per attribute in the order given, with `{+}' on the numbers.
With INSERT non-nil -- interactively, a prefix argument -- also set the
`:COLUMNS:' property of the entry at point to it.  The property and not a
`#+COLUMNS:' keyword: the property is what descendants inherit, and it is
what `org-agenda-columns' reads for a matched entry.

An undeclared name is REFUSED rather than emitted.  A `COLUMNS' line
naming a property nothing declares renders an empty column, which looks
exactly like a property nothing has set -- so the mistake would show up
as a corpus with no data in it rather than as a mistake.

So is a declared name a `COLUMNS' format cannot spell -- see
`org-agents--attribute-column-name-re'.  Emitting one produces the very
same silent, always-empty column, from a name the registry does declare:
`PROJECT.PHASE' would render as a column headed `PROJECT' that nothing
ever fills.

MEASURED: `org-columns-compile-format' validates no operator whatever --
`%X{nope}' compiles to `(\"X\" \"X\" nil \"nope\" nil)' with no complaint
whatever -- so
the guarantee that every operator emitted here is one `org-columns'
implements is this function's own, and
`org-agents--attribute-column-operators' is where it lives."
  (interactive
   (list (completing-read-multiple "Attributes: " (org-agents-attributes)
                                   nil t)
         current-prefix-arg))
  (unless names
    (user-error "org-agents: name at least one attribute to put in a column"))
  (let ((format
         (concat
          "%ITEM"
          (mapconcat
           (lambda (name)
             (let ((attr (org-agents-attribute name)))
               (unless attr
                 (user-error "org-agents: `%s' is not declared in %s" name
                             (abbreviate-file-name
                              (expand-file-name org-agents-attributes-file))))
               (unless (string-match-p org-agents--attribute-column-name-re
                                       name)
                 (user-error (concat "org-agents: `%s' cannot be spelled in"
                                     " a COLUMNS format")
                             name))
               (format " %%%s%s" name
                       (if-let* ((operator
                                  (alist-get
                                   (plist-get attr :type)
                                   org-agents--attribute-column-operators)))
                           (format "{%s}" operator)
                         ""))))
           names ""))))
    (when insert (org-entry-put nil "COLUMNS" format))
    (when (called-interactively-p 'interactive)
      (message "%s" format))
    format))

;;;; Prototypes

;; Prototypes, in Eastgate Tinderbox's sense.  An entry names a MASTER
;; entry in `:PROTOTYPE:' and reads through it whatever it does not
;; spell for itself.  The master may be ANYWHERE -- a named entry of the
;; registry file's `Prototypes' section, or any entry in the corpus
;; named by its `:ID:' -- so this is a relation between entries and not
;; a fact about the outline.  A master may name a master of its own, and
;; the chain is walked nearest-first.
;;
;; Reads are VIRTUAL.  Nothing is ever written into the inheriting
;; entry, and that is the whole of the design decision: a prototype can
;; be changed once and every follower changes with it, an entry's drawer
;; goes on saying only what the user put there, and no update has to
;; find and rewrite the followers of a master that moved.  The price is
;; stated rather than hidden: grep does not see an inherited value.  A
;; reader who wants one must ask this package, which is what
;; `property-resolved' below is for.
;;
;; The resolution order, per attribute, and it is Tinderbox's:
;;
;;   1. the entry's OWN drawer, with no inheritance whatever;
;;   2. the prototype chain, nearest hop first;
;;   3. the registry's `:ATTR_DEFAULT:';
;;   4. nil.
;;
;; Outline inheritance is deliberately NOT in that order.  Containment
;; is not inheritance -- a task filed under a project is not a kind of
;; project -- and the outline axis already has a spelling of its own,
;; `$NAME*', which is `org-entry-get' with INHERIT.  The two axes are
;; orthogonal, and a query says which one it means.
;;
;; Two names never travel, for two separate reasons.  `AGENT_*' because
;; behaviour does not: a master that lent its `:AGENT_QUERY:' would make
;; every follower an agent, and a registry default for such a name would
;; make every entry in the corpus one.  `PROTOTYPE' because a DEFAULT for
;; it would hand every entry in the corpus a prototype -- one declaration
;; and the whole corpus follows one master, which is the kind of thing a
;; user should have to write down entry by entry.  Both get the local
;; value and nothing else: no chain, no default.
;;
;; Below the Registry because every step of the order above ends in it.

(defconst org-agents--prototype-opaque-re "\\`AGENT_\\|\\`PROTOTYPE\\'"
  "Property names that resolve LOCALLY and by nothing else.
No chain and no registry default -- the two members are refused for two
different reasons, and both are in the section comment above:
`AGENT_...' because behaviour does not travel, `PROTOTYPE' because a
declared default for it would hand every entry in the corpus a master.

Only the DEFAULT arm of the `PROTOTYPE' refusal is reachable, and saying
so is worth more than the tidier claim it replaces.  The chain arm cannot
be reached at all: the walk finds its first hop with `org-entry-get' and
each later hop from the previous hop's plist, never through this
resolver, so a `PROTOTYPE' that has a local value answers with it at step
3 and one that has none has no chain to walk.  The claim \"the walk would
read its own answer\" was written here first and MEASURED false -- with
A -> B -> C, dropping `PROTOTYPE' from this regexp changes nothing about
what an entry following A resolves `PROTOTYPE' to.  What it does change
is what an entry with NO `:PROTOTYPE:' line resolves it to, which is why
`org-agents-test-prototype-property-does-not-travel' declares one.

Matched case-insensitively, because Org matches a property key that way:
`:agent_query:' is the same name as `:AGENT_QUERY:', and a resolver that
disagreed with `org-entry-get' about which name it had been handed would
be a hole in exactly the refusal this exists for.")

(defconst org-agents--prototype-uuid-re
  "\\`[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}\
-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\'"
  "What a bare `:PROTOTYPE:' value must look like to be read as an ID.
`org-id-new' with the default `org-id-method' produces exactly this
shape, so a reference written without the `id:' prefix is still
unambiguous -- no Org heading looks like it.  A reference that DOES carry
the prefix is an id whatever follows it, which is what keeps a corpus
using some other `org-id-method' working.")

(defvar org-agents--prototypes-cache nil
  "`(KEY . ALIST)' for the registry file's prototypes as last read, or nil.
KEY is `org-agents--file-cache-key' of `org-agents-attributes-file', and
ALIST is `(NAME . PLIST)' in file order.  One cons, and for the same
reason `org-agents--attributes-cache' is one: the prototypes come out of
the one file that option names.")

(defvar org-agents--prototype-id-cache nil
  "Prototypes resolved by `:ID:', as `(ID KEY FILE . PLIST)', newest first.
FILE is the file that was CONSULTED for ID and KEY is
`org-agents--file-cache-key' of it, which is a DIFFERENT file per id -- so
this is an alist where `org-agents--prototypes-cache' is one cons.  An
entry whose file's key has moved is re-read; inside
`org-agents--with-attributes' no key is recomputed at all.

PLIST is nil for an id that FILE does not hold, and such a cell is kept
rather than dropped: `org-agents--prototype-id-entry' says what an
uncached miss costs a fontifier, which is why FILE is recorded at all --
a nil answer has no `:file' of its own to revalidate against.")

(defvar org-agents--prototype-warned nil
  "A hash table of prototype diagnostics already said, or nil for none.
Keyed on the reference or the cycle rather than on the text, so twenty
entries naming one missing prototype cost one message -- see
`org-agents--prototype-report'.

Bound to a fresh table by `org-agents--collect' and by
`org-agents-preview', around one whole update: a dangling reference or a
cycle is a fact about the corpus, and an update should say it once.  When
it is nil the reporter still messages, because silence is worse; a caller
that runs the resolver over many entries of its own -- a fontifier, say
-- inherits the obligation to bind it.")

(defun org-agents--in-attributes-batch (fn)
  "Call FN as ONE registry batch, and answer what it answers.
The registry read at most once however often it is asked, and every
prototype diagnostic said at most once.  What `org-agents--collect' and
`org-agents-preview' wrap a whole update in.

A function and not the `org-agents--with-attributes' macro, for two
reasons.  It bundles the two bindings an update wants -- one read, one
table -- so that an update's registry batch is one named thing rather
than two nested forms remembered separately.  And a function may be
called from above its own definition, which the macro may not: the
collector sits above the Registry in this file, because it reads drawers
through the machinery the Registry is built on.

The one read is a SOUNDNESS requirement rather than a saving.  The
prefilter's splitter decides whether to narrow a `property-resolved'
conjunct by reading `:ATTR_DEFAULT:', and `property-resolved' decides
whether an entry matches by reading the same `:ATTR_DEFAULT:'.  Two
separate reads could in principle straddle an edit, and a narrowing
decided against a default that had since gone away would drop files with
no error.  Inside one batch they are provably the same read -- the
argument `org-agents--attributes-fresh' already rests on."
  (org-agents--warm-attributes)
  (let ((org-agents--attributes-fresh t)
        (org-agents--prototype-warned (make-hash-table :test #'equal)))
    (funcall fn)))

(defun org-agents--prototype-report (key format &rest args)
  "Say FORMAT with ARGS once per KEY, and answer nil.
`message' and never `user-error', and the argument is
`org-agents--attr-warn''s carried one step further.  The resolver runs
from a predicate body at every candidate entry, and
`org-agents--collect' hands ONE form to `org-ql-select': a signal from
inside org-ql's generated matcher aborts that agent's whole update, and
`org-agents-update-all' -- which catches `user-error' per agent -- would
then report the agent as failed on account of one drawer's typo.

Answers nil so that a caller can end with it: the failed look-up and the
diagnosis are one expression."
  (unless (and org-agents--prototype-warned
               (gethash key org-agents--prototype-warned))
    (when org-agents--prototype-warned
      (puthash key t org-agents--prototype-warned))
    (apply #'message format args))
  nil)

(defun org-agents--prototype-warn (name file reason)
  "Say that the prototype NAME in FILE is REASON.
`org-agents--attr-warn' for the section beside the declarations, and said
once per edit for the same reason: this is called from the READER, and
`org-agents--prototypes-alist' calls that at most once per cache key."
  (message "org-agents: prototype `%s' in %s: %s"
           name (abbreviate-file-name file) reason))

(defun org-agents--prototype-opaque-p (name)
  "Non-nil when NAME is a name no prototype and no default may answer for.
See `org-agents--prototype-opaque-re' for the two members and the two
arguments."
  (and (stringp name)
       (let ((case-fold-search t))
         (string-match-p org-agents--prototype-opaque-re name))
       t))

(defun org-agents--prototype-where (pom)
  "Where POM is, as one string, for a diagnostic to name it by.
A heading, a file and a line, so that a dangling `:PROTOTYPE:' can be
navigated to rather than hunted for.  A buffer visiting no file is named
by its buffer name, which is what a read in a temporary copy has."
  (org-with-point-at pom
    (let ((file (buffer-file-name (or (buffer-base-buffer) (current-buffer)))))
      (format "`%s' in %s:%d"
              (or (ignore-errors (org-get-heading t t t t)) "?")
              (if file (abbreviate-file-name file) (buffer-name))
              (line-number-at-pos)))))

(defun org-agents--prototype-at-point (file)
  "The prototype entry at point as a plist, read out of FILE.
`:key' is what a cycle is detected by, and it is `FILE:POSITION' for
every hop however the hop was reached -- by name out of the registry's
`Prototypes' section, or by its `:ID:' out in the corpus.  ONE key space,
so that two spellings of one entry cannot walk past each other.

That is a correctness requirement of the diagnostic rather than of the
walk.  Keyed per spelling -- a downcased name for a named master and
`FILE:POSITION' for an id-named one -- both key spaces are finite and the
walk still terminates, but a chain mixing the two spellings is walked one
hop further than its length and the cycle is MISNAMED: measured, a
two-entry cycle whose master named its partner by name and was named back
by `id:' printed `Alpha -> Beta -> Alpha -> Beta', which says four
masters where there are two and does not say where the cycle closed.

A position is a safe key because `org-agents--in-org-copy' guarantees it:
the copy is character-for-character the file's text, `#+SETUPFILE:'
neutralization included, so a position found by one reader is the same
position for the other.  Both caches are keyed on
`org-agents--file-cache-key' of that file, so an edit that would move an
entry invalidates them together.

`:properties' is `(org-entry-properties nil \\='standard)', which is
exact rather than convenient: MEASURED, it joins `:T:' with `:T+:'
exactly as `org-entry-get' does, so ONE read answers for every attribute
the entry carries at once.  Its synthesized `CATEGORY' is never reached,
because a special property is answered locally before the chain is
walked at all."
  (list :name (org-get-heading t t t t)
        :key (format "%s:%d" file (point))
        :properties (org-entry-properties nil 'standard)
        :prototype (org-entry-get nil org-agents--prototype-property)
        :file file
        :line (line-number-at-pos)))

(defun org-agents--prototypes-section-p ()
  "Non-nil when point is on the top-level `Prototypes' heading.
`org-get-heading' with every argument, as the readers around it use it,
so the heading is its text: MEASURED, `* Prototypes :noexport:' and
`* TODO Prototypes' are both this section, because tags and a keyword are
not part of a heading's name.

Case-SENSITIVE, unlike the prototype names below it.  A mis-cased
`* prototypes' is therefore not this section -- and is not silently
dropped either: it falls through to the attribute reader, which reports
it as a declaration missing `:ATTR_TYPE:'.  MEASURED, and it is the
reason this is left alone: the user is told, and
`org-agents--attributes-reserved' skips one spelling only."
  (and (= 1 (org-current-level))
       (equal (org-get-heading t t t t) org-agents--prototypes-section)))

(defun org-agents--prototypes-scan (file)
  "Read every prototype in the current buffer, which holds FILE's text.
The subtree of the FIRST top-level heading whose text is
`org-agents--prototypes-section', and every entry below it at any depth:
a section that groups its masters is a section, not a second kind of
declaration.  FILE is named only so that a diagnosis can say where an
entry is.

A duplicate name is diagnosed and the first declaration stands, which is
the registry's own rule for a duplicate.  Names are matched
case-insensitively, as `org-agents-attribute' matches a declaration --
and a heading is not a property key, so here that is a convention rather
than a consequence.  The diagnosis is what makes it a safe one.

A duplicate SECTION is diagnosed for the same reason, and it was not
before: only the FIRST such heading is read, so a registry grown a second
`Prototypes' heading further down -- the natural thing to do when
grouping masters by area -- had every master under it silently name
nothing.  MEASURED, `* Prototypes/** A' followed by `* Prototypes/** B'
answered `(\"A\")' and said nothing at all: `B' was unreachable, and
because the heading is reserved it was not reported as a declaration
missing `:ATTR_TYPE:' either.  So each follower naming `B' got a dangling
diagnostic blaming its own drawer, which is the one place the mistake was
not."
  (let ((prototypes nil))
    (goto-char (point-min))
    (unless (org-at-heading-p) (outline-next-heading))
    (while (and (org-at-heading-p)
                (not (org-agents--prototypes-section-p)))
      (outline-next-heading))
    (when (org-at-heading-p)
      (let ((end (save-excursion (org-end-of-subtree t t) (point))))
        (while (and (outline-next-heading) (< (point) end))
          (let ((name (org-get-heading t t t t)))
            (cond
             ((or (null name) (string-empty-p name)))
             ((assoc-string name prototypes t)
              (org-agents--prototype-warn
               name file "declared twice; the first declaration stands"))
             (t (push (cons name (org-agents--prototype-at-point file))
                      prototypes)))))
        ;; Past the subtree, so a heading INSIDE it cannot be mistaken
        ;; for a second section however it is spelled.
        (goto-char end)
        (unless (org-at-heading-p) (outline-next-heading))
        (catch 'second
          (while (org-at-heading-p)
            (when (org-agents--prototypes-section-p)
              (org-agents--prototype-warn
               org-agents--prototypes-section file
               "a second section is ignored; the first one stands")
              (throw 'second t))
            (outline-next-heading)))))
    (nreverse prototypes)))

(defun org-agents--prototypes-read (file)
  "FILE's prototypes as an alist of `(NAME . PLIST)', in file order.
Read in a copy: `org-agents--in-org-copy' says which copy, and why the
registry is never visited to read it."
  (org-agents--in-org-copy file
                           (lambda () (org-agents--prototypes-scan file))))

(defun org-agents--prototypes-alist ()
  "The registry file's prototypes, read at most once per edit to it.
A missing or unreadable file names no prototype and says nothing about
it, exactly as it declares no attribute: the reference that then fails to
resolve is what gets diagnosed, once, by the resolver.

Inside `org-agents--with-attributes' the key is not recomputed at all."
  (if org-agents--attributes-fresh
      (cdr org-agents--prototypes-cache)
    (let ((file (expand-file-name org-agents-attributes-file)))
      (org-agents--prototypes-alist-1 file
                                      (org-agents--file-cache-key file)))))

(defun org-agents--prototypes-alist-1 (file key)
  "Read `org-agents--prototypes-alist' answer for FILE, whose key is KEY.
The unreadable branch CLEARS the cache, for the reason
`org-agents--attributes-alist' gives: a file that has been deleted names
nothing from that moment."
  (cond
   ((null key) (setq org-agents--prototypes-cache nil))
   ((equal key (car org-agents--prototypes-cache))
    (cdr org-agents--prototypes-cache))
   (t (cdr (setq org-agents--prototypes-cache
                 (cons key (org-agents--prototypes-read file)))))))

(defun org-agents--prototype-id (ref)
  "The id REF names, or nil when REF is a prototype NAME.
An `id:' prefix says so outright; a bare `org-id-new' UUID says so by its
shape -- see `org-agents--prototype-uuid-re'.  Everything else is a name,
and a name is looked up in the registry's `Prototypes' section."
  (cond ((string-prefix-p "id:" ref t) (substring ref 3))
        ((string-match-p org-agents--prototype-uuid-re ref) ref)))

(defun org-agents--prototype-id-read (id)
  "The prototype whose `:ID:' is ID, as a plist, or nil when nothing knows it.
`org-id-find' is deliberately NOT called, and the reason is in its
source: when the location table has no answer it calls
`org-id-update-id-locations', which rescans every agenda and extra file
and WRITES `org-id-locations-file' -- or signals \"Please turn on
`org-id-track-globally'\" where that option is nil.  This runs from a
predicate body once per candidate entry, so one mistyped id would either
rescan the corpus per entry or abort the update.  The two steps
`org-id-find' takes BEFORE its rescan are the two steps taken here:
`org-id-find-id-file' consults the table, and the entry is then found in
a copy of that file.

Found in a copy rather than at `org-id-find-id-in-file''s position, so
that an unsaved edit to the master is what the follower reads -- the same
choice, and the same `org-agents--in-org-copy', that the registry reader
makes."
  (when-let* ((file (org-id-find-id-file id)))
    (org-agents--in-org-copy
     file
     (lambda ()
       (catch 'found
         (goto-char (point-min))
         (unless (org-at-heading-p) (outline-next-heading))
         (while (org-at-heading-p)
           (when (equal id (org-entry-get nil "ID"))
             (throw 'found (org-agents--prototype-at-point file)))
           (outline-next-heading))
         nil)))))

(defun org-agents--prototype-id-entry (id)
  "The prototype whose `:ID:' is ID, from the cache or by reading for it.
Keyed on `org-agents--file-cache-key' of the file that was CONSULTED, so
an unsaved edit to a master out in the corpus invalidates it -- the same
guarantee the registry's own prototypes get, extended to the file each id
happens to live in.

A MISS is cached too, and that is a fix rather than an optimization.
Reading for an id costs `org-agents--in-org-copy' of a whole file and an
`outline-next-heading' walk of it, and a caller that runs at every
DISPLAYED entry -- `org-agents-faces-mode' -- asks again on every
fontification of the region holding the reference.  MEASURED with the
miss uncached: one entry naming an id its file does not hold cost one
whole-file copy per fontification, 11.8 ms against 0.4 ms for the same
screenful without it, on every redisplay of that region and so on every
keystroke in it.  A stale `org-id-locations-file' or a renamed master is
all it takes.

Hence the CONSULTED file rather than the answer's: a nil answer has no
`:file' to revalidate against, so the cell carries the file the answer
was sought in and `(ID KEY FILE . PLIST)' is its shape.  Inside
`org-agents--with-attributes' no key is recomputed at all, so a region
pays one `gethash'."
  (let* ((cell (assoc id org-agents--prototype-id-cache))
         (cached (cdddr cell)))
    (if (and cell
             (or org-agents--attributes-fresh
                 (equal (cadr cell)
                        (org-agents--file-cache-key (caddr cell)))))
        cached
      (let* ((file (org-id-find-id-file id))
             (found (and file (org-agents--prototype-id-read id))))
        (setq org-agents--prototype-id-cache
              (cons (cons id (cons (org-agents--file-cache-key file)
                                   (cons file found)))
                    (assoc-delete-all id org-agents--prototype-id-cache)))
        found))))

(defun org-agents--prototype-id-untracked-p (id)
  "Non-nil when `org-id' has no file recorded for ID.
Which is the difference between \"that master is not there\" and \"org-id
does not know where to look\", and the two want different fixes: the first
is a typo in a drawer, the second is `org-id-track-globally' and a
populated `org-id-locations-file'.  `org-agents--prototype-id-read' says
why the table is consulted rather than `org-id-find', which would rebuild
it from a predicate body."
  (not (and (hash-table-p org-id-locations)
            (gethash id org-id-locations))))

(defun org-agents--prototype-entry (ref pom)
  "The prototype REF names, as a plist, or nil with ONE diagnostic.
POM is the entry that named it, so that the diagnostic can say where the
reference was written.  Keyed on the reference and not on the text, so a
hundred entries naming one missing master cost one message naming the
first of them.

An `id:' the location table does not know says so, because otherwise the
message names the FOLLOWER and the follower is the one thing that is
spelled correctly: MEASURED, a master one file away with an empty table
resolved nil and reported `no prototype `id:...' named by `F'', which
sends the user hunting for a typo in a drawer that has none.  The cause is
that `org-id-find-id-file' answers the current buffer's own file on a
table miss -- so the id is looked for in the follower's file and not in
the master's.

Which is also why an id the table does not know is not looked for at all.
The contract is the table's -- `:PROTOTYPE: id:UUID' resolves where
`org-id-locations' knows the id -- and the read on a table miss searches
the FOLLOWER's own file, so it can only ever answer by accident, and the
same reference in another file would fail.  It is not a cheap accident
either: MEASURED, one such reference cost a whole-file
`org-agents--in-org-copy' plus a heading walk of the displayed buffer on
every fontification of the region holding it -- 11.8 ms against 0.4 ms
for the same screenful, on every redisplay, because a miss found in the
buffer being edited is revalidated on every keystroke.  One `gethash'
answers instead, and the diagnostic below already tells the user which of
the two causes it was."
  (let ((id (org-agents--prototype-id ref)))
    (or (if id
            (unless (org-agents--prototype-id-untracked-p id)
              (org-agents--prototype-id-entry id))
          (cdr (assoc-string ref (org-agents--prototypes-alist) t)))
        (org-agents--prototype-report
         (concat "dangling\0" (downcase ref))
         "org-agents: no prototype `%s' named by %s%s"
         ref (org-agents--prototype-where pom)
         (if (and id (org-agents--prototype-id-untracked-p id))
             "; org-id knows no file for that id"
           "")))))

(defconst org-agents--prototype-chain-limit 1000
  "How many hops `org-agents--prototype-chain' walks before it refuses.
A SECOND bound, and deliberately not a tight one.  The visited set is
what detects a cycle and names it; this only guarantees that the loop
returns at all, so that a refactor which drops or mis-keys that set fails
a test instead of hanging the suite.

Not derived from the number of registry prototypes, which would be the
obvious cap and is the wrong one: an `id:' chain walks entries out in the
corpus that the registry never names, so a cap counted from the registry
would refuse a legitimate chain.  A thousand distinct masters in one
chain is not a corpus anyone has -- Tinderbox chains are two to four deep
-- and every hop past the first is a cache hit, so the bound costs
nothing where it is not reached.

A `defconst' and not a `defcustom': it is a bound on a broken corpus, not
a preference, and nothing a user wants to raise.")

(defun org-agents--prototype-path (names)
  "NAMES joined as a chain for a diagnostic to print.
Truncated, because the second bound admits a path a thousand hops long
and a diagnostic that prints one says less than a diagnostic that prints
its beginning: where a cycle closes is visible in the first few hops, and
that is what the reader is looking for."
  (let ((shown (take 12 names)))
    (concat (string-join shown " -> ")
            (when (> (length names) (length shown)) " -> ..."))))

(defun org-agents--prototype-chain (name ref pom)
  "Look NAME up along the prototype chain starting at REF, or answer nil.
Nearest hop first, and the walk stops at the first hop that carries NAME.
POM is the entry the chain hangs from, named in a diagnostic.

A hop already visited is a CYCLE, and a cycle is a `user-error' naming
the hops in order: it is a broken corpus rather than a missing value, and
the caller that must not signal calls
`org-agents-resolve-property-quietly' instead.  The visited set is keyed
on each hop's own `:key', which `org-agents--prototype-at-point' makes
one key space, so a master reached once by name and once by id is one hop
and not two.

`org-agents--prototype-chain-limit' bounds the walk a SECOND time, and
independently.  The visited set alone is sound -- the key space is
finite, so the walk terminates -- but it was also the only thing bounding
this loop, and that made the loudest failure mode the least legible one:
MEASURED, neutering the cycle branch did not fail
`org-agents-test-prototype-cycle-names-the-cycle', it hung the suite
until the runner's timeout, which in CI reads as an infrastructure flake
rather than as the cycle regression it is.  The counter turns that back
into the signal the cycle tests already assert.

A dangling reference ends the walk with the value nil, having already
been diagnosed by `org-agents--prototype-entry'."
  (let ((visited (make-hash-table :test #'equal))
        (hops 0)
        (path nil)
        (value nil))
    (while (and ref (null value))
      (let ((entry (org-agents--prototype-entry ref pom)))
        (cond
         ((null entry) (setq ref nil))
         ((or (gethash (plist-get entry :key) visited)
              (> (cl-incf hops) org-agents--prototype-chain-limit))
          (user-error "org-agents: prototype cycle at %s: %s"
                      (org-agents--prototype-where pom)
                      (org-agents--prototype-path
                       (nreverse (cons (plist-get entry :name) path)))))
         (t
          (puthash (plist-get entry :key) t visited)
          (push (plist-get entry :name) path)
          (setq value (cdr (assoc-string
                            name (plist-get entry :properties) t)))
          (setq ref (and (null value) (plist-get entry :prototype)))))))
    value))

(defun org-agents-resolve-property (name &optional pom)
  "Resolve attribute NAME at POM through prototypes, and answer TEXT or nil.
POM is a marker or a position, and defaults to point.  The answer is the
string a drawer holds, or the registry's declared default, or nil: an Org
property value is text, and nothing here parses it.

The order, which is the section comment's order above:

  1. `AGENT_...' and `PROTOTYPE' answer from the entry's own drawer and
     stop -- see `org-agents--prototype-opaque-re'.
  2. So does a special property: a prototype's `CATEGORY' is not this
     entry's, and a `DEADLINE' is entry structure rather than a drawer
     line at all.

     A BELT, and its own test says so.  MEASURED, no change to THIS file
     can tell the clause from its absence, because Org will not hand a
     special name out of a drawer at all: a master whose drawer holds
     `:DEADLINE: <2030-01-01 Tue>', `:TODO: DONE', `:ITEM: fake' and
     `:PRIORITY: A' answers `org-entry-properties' with neither the
     deadline nor the keyword, at `standard', at `special' and at `all'
     alike.  So the chain cannot carry a special, and `CATEGORY' -- the
     one Org does synthesize -- is one `org-entry-get' answers for at
     every entry anyway.  That measurement is what the clause's
     unreachability rests on, and
     `org-agents-test-prototype-special-property-is-local-only' pins it,
     so a later Org that reported drawer specials would fail a test
     rather than change an answer.
  3. The entry's own drawer, through `org-entry-get' with INHERIT NIL.
     Raw `org-entry-get' and not `org-agents--entry-get': a present but
     EMPTY `:NAME:' answers \"\", which is non-nil, and org-ql's own
     `property' matches it -- so this must too, or `property-resolved'
     and `property' would disagree about an entry neither prototypes nor
     defaults are involved in.

     The INHERIT argument is nil and must stay nil.  MEASURED: an
     inheriting read answers from an ancestor's drawer, from a
     `#+PROPERTY:' file keyword, and from `org-global-properties' -- the
     first spelled by a line no drawer pattern matches, the last spelled
     in no file at all.  Any of them in this step would be a value the
     ripgrep prefilter's widened pattern cannot see, which is a lost
     match with no error.  See `org-agents--pushdown-fns'.
  4. The prototype chain, nearest first.
  5. The registry's `:ATTR_DEFAULT:'.

Signals a `user-error' naming the cycle where the chain has one.  A
caller that runs at every entry of a corpus wants
`org-agents-resolve-property-quietly', which reports instead."
  (cond
   ((org-agents--prototype-opaque-p name) (org-entry-get pom name))
   ((org-agents--attr-special-p name) (org-entry-get pom name))
   (t (or (org-entry-get pom name)
          (org-agents--prototype-chain
           name
           (org-entry-get pom org-agents--prototype-property)
           pom)
          (plist-get (org-agents-attribute name) :default)))))

(defun org-agents-resolve-property-quietly (name &optional pom)
  "`org-agents-resolve-property', with a cycle reported rather than signalled.
The one demotion site, and it is documented here rather than spread over
the callers: a `user-error' out of a predicate body or out of residual
Lisp aborts the whole update from inside org-ql's generated matcher.  The
signalling function stays for a command and for a caller that wants to be
told."
  (condition-case err
      (org-agents-resolve-property name pom)
    (user-error
     (let ((text (error-message-string err)))
       (org-agents--prototype-report (concat "cycle\0" text) "%s" text)))))

(org-ql-defpred property-resolved (name &optional value)
  "Return non-nil if this entry resolves NAME, or resolves it to VALUE.
The prototype-aware `property': `org-agents-resolve-property-quietly' is
what answers, so a value the entry does not spell -- one that arrives
through its `:PROTOTYPE:' chain, or out of the registry's
`:ATTR_DEFAULT:' -- is a match here where `property' has none.

PREAMBLE-FREE BY CONSTRUCTION, and the true reason is not the obvious
one.  It is NOT that a preamble would hide an inherited value, which
invites the fix \"turn the preamble off\": MEASURED, org-ql's plain
`property' forms attach no `:inherit' at all and read the entry's own
drawer, so `(property \"X\" \"v\")' misses a descendant of the entry
holding X at every setting of `org-use-property-inheritance', and
`org-ql-use-preamble' nil changes nothing -- the bare `(property \"X\")'
form has no preamble to turn off and still misses it.  What a preamble
WOULD do here is re-impose the drawer text as a filter over this
predicate's answer, which is precisely what defeats advice on
`org-entry-get': MEASURED, with such advice installed the value form
finds a follower with the preamble off and loses it with the preamble on.
So this predicate contributes NO preamble, ever, and org-ql itself sets
the precedent -- it emits none for any `property' form that carries
`:inherit'.

A preamble hoisted out of a sibling conjunct is another matter and is
sound: MEASURED, `(and (property-resolved ...) (property \"Z\" \"1\"))'
searches on `:Z: 1', which is a necessary condition of the conjunction.

VALUE is compared with `string-equal', case-SENSITIVELY, and the
argument order is org-ql's own `property' body's.  That comparison is
one decision with the ripgrep prefilter's default exception -- see
`org-agents--pushdown-fns' -- and the two must not drift."
  :body (let ((resolved (org-agents-resolve-property-quietly name)))
          (if value
              (and resolved (string-equal value resolved))
            resolved)))

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
    ;; The registry read once and the prototype diagnostics said once over
    ;; the whole preview.  A REFRESH of the resulting `org-ql-search'
    ;; buffer runs outside this extent, and that is sound: a preview is
    ;; handed `org-agenda-files' and is never narrowed, so there is no
    ;; narrowing decision for a later read to disagree with.
    (org-agents--in-attributes-batch (lambda () (org-ql-search files form)))))

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

;;;; Appearance

;; A headline's APPEARANCE following a declared attribute's resolved value.
;; This is Tinderbox's `$Color', and the whole of it is one font-lock
;; keyword: `:ATTR_FACES:' maps values to faces, and a headline whose
;; resolved value is one of those values is drawn in the face beside it.
;;
;; It CHANGES NO BYTES.  No text is inserted, no property is written, no
;; overlay is created -- the `face' text property font-lock manages, and
;; removes again, is the entire mechanism.  Turning the mode off
;; un-declares the keyword and lets font-lock's own unfontify pass take
;; the face off, so the buffer comes back exactly as it was.
;; `org-agents-test-faces-change-no-bytes' watches the writers by name and
;; `org-agents-test-faces-disabling-leaves-no-residue' watches the
;; restoration; both are the guard, and both are worth keeping.
;;
;; The value it reads is the RESOLVED one, which is what makes the mode
;; worth having: an entry that spells only `:PROTOTYPE: Task', or that
;; spells nothing at all and takes `:ATTR_DEFAULT:', is faced exactly as
;; one that spells the value in its own drawer.  Grep does not see an
;; inherited value and neither does the drawer under the user's eye -- but
;; the face does, and reading a corpus is what that is for.
;;
;; The cost is what is DISPLAYED.  The matcher reads only the entry at its
;; match and honours its LIMIT, so jit-lock pays per screenful and not per
;; corpus: MEASURED over a 400-entry buffer of which one entry is drawn,
;; under the suite's registry of TWO face-declaring attributes -- each
;; unmapped headline is resolved once per declaration, so the figures scale
;; with how many attributes name faces -- a twelve-line window costs 5
;; resolutions where the whole buffer costs 799, and a headline outside the
;; region carries no `face' property at all.  The same measurement under a
;; registry declaring one faced attribute is 3 against 400.
;;
;; `org-agents--faces-fontify-region' is the one piece of machinery beyond
;; the keyword, and it exists for two things a keyword cannot do, because
;; a keyword has no extent over which to hold a dynamic binding.  It reads
;; the registry ONCE for the region -- MEASURED, a whole-buffer
;; fontification of that fixture costs 405 `org-agents--file-cache-key'
;; calls and 0.097 s with the batch established per matcher call, against
;; 1 call and 0.033 s with it established once for the region, over an
;; Org-alone baseline of 0.010 s: a marginal cost of 23 ms against 87 ms,
;; and the saving grows with the buffer list because that key walks it.  And it
;; binds `org-agents--prototype-warned', whose own docstring already
;; assigns a fontifier that obligation: MEASURED, twenty entries naming
;; one missing master produce twenty messages unbound and one bound, and
;; unbound those would be twenty messages PER REDISPLAY.
;;
;; And the face FOLLOWS an edit to the value it is drawn from, which needs a
;; second hook of the same kind and for the same reason -- the face is on the
;; headline and the value is in the drawer below it, and a change refontifies
;; its own line.  `org-agents--faces-extend-region' says what
;; `jit-lock-after-change' does not reach, and what this mode does not reach
;; either: an edit to the registry, or to a master in another buffer.
;;
;; Two refusals, and they are refusals rather than omissions.
;;
;; NO GEOMETRY.  Tinderbox's `$Width', `$Xpos' and `$Height' describe a
;; map view, and Org has no map: there is nothing in an outline for them
;; to mean, so they are not ported and no spelling of them is reserved.
;;
;; NO WRITES, of any kind, from an appearance declaration.  Setting a tag
;; or a TODO state from a resolved value is action code arriving through
;; another door: it would be INHERITABLE behaviour, which part 3 of
;; docs/research/action-code-safety.md is about -- a master's declaration
;; running in every follower's file makes per-file trust meaningless.  Any
;; such thing goes through the action-code trust model or not at all.

(require 'font-lock)                    ; the keyword, and the region function

(defconst org-agents--faces-heading-re "^\\*+ \\(.*\\)$"
  "The headline this mode faces, with group 1 spanning what it draws.
The same span as Org's own headline keyword's group 3 -- the TODO
keyword, the priority, the title and the tags -- and never the trailing
newline, so `org-fontify-whole-heading-line' still governs the fill of
the line and this mode governs the text on it.

Not built from `org-fontify-whole-heading-line', and not built from
anything else optional either: `font-lock-remove-keywords' removes by
`equal', so a keyword form that depended on an option would fail to
remove if the option changed between the two calls.  See
`org-agents--faces-keywords'.")

(defvar org-agents--faces-face nil
  "The face `org-agents--faces-matcher' last decided on.
Read by the FACENAME of `org-agents--faces-keywords', which font-lock
`eval's at apply time -- so a bare variable reference is a legal and
idiomatic dynamic face, and Org's own headline keyword does the same
thing with `(org-get-level-face 1)'.  Set immediately before the matcher
answers non-nil and read immediately after, with nothing between: the
matcher and `font-lock-apply-highlight' are two steps of one call.")

(defconst org-agents--faces-keywords
  '((org-agents--faces-matcher (0 org-agents--faces-face prepend)))
  "The ONE font-lock keyword `org-agents-faces-mode' installs.
SUBEXP 0 because the matcher sets match-data to exactly the span it wants
faced, and `prepend' with the keyword APPENDED to `font-lock-keywords'.
Both of those are load-bearing and neither is stylistic.

Org's own headline keyword carries OVERRIDE nil -- \"apply only where no
face is set yet\" -- so whichever keyword runs first claims the headline
outright.  MEASURED, adding this one at the FRONT of the list, which is
`font-lock-add-keywords''s default, leaves the title `(org-warning)' with
`org-level-N' destroyed; `append' puts it last, where it prepends onto
what Org already put there and the title reads `(org-warning
org-level-1)'.  The four OVERRIDE values from that position: `prepend'
gives `(org-warning org-level-1)' -- ours wins attribute by attribute and
Org's survives underneath; `append' gives `(org-level-1 org-warning)',
where Org's colour wins and ours is dead weight; `keep' gives
`org-level-1' alone, so ours never applies; and t gives `org-warning'
alone, DESTROYING `org-level-N' -- the height, the family, the lot.
`prettify-symbols-mode' uses the default HOW; do not copy it here.

A `defconst', and it must stay one: `font-lock-remove-keywords' removes
by `equal', so the same form has to be passed to the add and to the
remove.  MEASURED, that round trip leaves `font-lock-keywords' `equal' to
what it was and leaves nothing in `font-lock-removed-keywords-alist'.")

(defvar-local org-agents--faces-warned nil
  "`(REGISTRY-KEY . TABLE)' of diagnostics already said in this buffer.
The table outlives a fontified region, so a typo in the registry is said
once and not once per scroll; and it is REMADE where the registry's cache
key has moved, so a typo the user has since fixed is noticed and one they
have not is not re-said.  See `org-agents--faces-warned-table'.")

(defvar-local org-agents--faces-outer-fontify nil
  "What `font-lock-fontify-region-function' was before this mode wrapped it.
Meaningful only where `org-agents--faces-outer-local' is non-nil.")

(defvar-local org-agents--faces-outer-local nil
  "Non-nil when `font-lock-fontify-region-function' was ALREADY local.
MEASURED, an Org buffer does not localize that variable -- only
`font-lock-unfontify-region-function' -- so the ordinary restore is
`kill-local-variable'.  But another mode may have localized it first, and
MEASURED, an unconditional `kill-local-variable' loses that mode's value
for good.  Which of the two restores is right is what this records.")

(defvar-local org-agents--faces-outer-extend nil
  "What `font-lock-extend-after-change-region-function' was before the wrap.
Meaningful only where `org-agents--faces-outer-extend-local' is non-nil.
An Org buffer HAS localized this one -- `org-mode' sets it to
`org-fontify-extend-region' -- so unlike the region function this record
is the ordinary case rather than the unusual one.")

(defvar-local org-agents--faces-outer-extend-local nil
  "Non-nil when `font-lock-extend-after-change-region-function' was local.
The same record `org-agents--faces-outer-local' keeps for the region
function, for the same reason, and it is t in every Org buffer.")

(defun org-agents--faces-warned-table ()
  "This buffer's diagnostic table, fresh where the registry has changed.
Keyed on `(car org-agents--attributes-cache)', which IS the registry's
own cache key: the caller has just run `org-agents--with-attributes', so
that key is up to date and a table made against it is a table made
against the declarations now in force.

Bound over `org-agents--prototype-warned', so ONE table serves both the
prototype diagnostics and this section's face diagnostics, through the
existing `org-agents--prototype-report' and its existing key-space
convention -- `\"dangling\\0...\"', `\"cycle\\0...\"', and here
`\"face\\0ATTR\\0FACE\"' and `\"faces\\0MESSAGE\"'.  No second reporter."
  (let ((key (car org-agents--attributes-cache)))
    (unless (and org-agents--faces-warned
                 (equal key (car org-agents--faces-warned)))
      (setq org-agents--faces-warned
            (cons key (make-hash-table :test #'equal))))
    (cdr org-agents--faces-warned)))

(defun org-agents--faces-declared ()
  "`(NAME . FACES)' for every declared attribute that names faces, in file order.
`:ATTR_FACES:' IS the opt-in, and there is deliberately no option beside
it: a declaration that names faces is a declaration asking to be drawn,
and a second list to enrol it in would be a second place to edit whose
commonest failure would be a registry that names faces and silently draws
nothing -- the one bug this section exists to prevent.

File order because `org-agents-attributes' is file order, and its own
docstring says why: the registry is a document, and the order its author
chose is information.  That order is the precedence rule -- see
`org-agents--faces-at'."
  (cl-loop for name in (org-agents-attributes)
           for faces = (plist-get (org-agents-attribute name) :faces)
           when faces collect (cons name faces)))

(defun org-agents--faces-at (pom attrs)
  "The face ATTRS give the entry at POM, or nil where they give none.
ATTRS is `org-agents--faces-declared''s answer, hoisted by the caller so
that the registry is consulted once for a region rather than once per
headline.  The FIRST declaration that resolves to a named value wins.

`org-agents-resolve-property-quietly' and not `org-entry-get': a value
arriving through a `:PROTOTYPE:' chain or out of `:ATTR_DEFAULT:' must
face this headline exactly as a local value does, and that is the whole
point of the mode.  Quietly, because fontification must not signal.

The value is matched WHOLE and CASE-SENSITIVELY.  Both halves are one
decision with `property-resolved''s `string-equal' and with
`org-agents-attribute-valid-p''s \"compared case-SENSITIVELY, because a
declared vocabulary is one the user wrote down\", and the three must not
drift.  A consequence worth knowing: a `set' or `list' attribute is faced
only where its whole value equals a declared key, since `:ATTR_FACES:'
does not face by member.

A face the registry names and Emacs does not is a DIAGNOSTIC and not an
error, said once per attribute and face.  A typo in the registry costs
its own mapping and must not cost the rest of the buffer's fontification
-- so the walk goes on to the next declaration, which is what lets a
later one still face the headline.  `facep' is checked here, at USE, and
never in the reader: `org-agents--attr-parse-faces' says why, which is
that a face this names may well be defined by a theme loaded afterwards.

The MAPPING is what the `when-let*' requires, and not the face it holds.
`:ATTR_FACES: done nil' interns the symbol nil -- a plausible way to
spell \"draw this one plainly\", and a leftover from an edit -- and a
clause requiring the cdr would drop it before `facep' ever saw it: no
face and no diagnostic, which is the one bug this section exists to
prevent said of the one face name that reads as false.  So the cons cell
is what is bound, and its cdr is tested rather than required."
  (catch 'org-agents--face
    (pcase-dolist (`(,name . ,faces) attrs)
      (when-let* ((value (org-agents-resolve-property-quietly name pom))
                  (cell (assoc-string (string-trim value) faces)))
        (if (facep (cdr cell))
            (throw 'org-agents--face (cdr cell))
          (org-agents--prototype-report
           (format "face\0%s\0%s" name (cdr cell))
           "org-agents: attribute `%s' names no such face: `%s'"
           name (cdr cell)))))
    nil))

(defun org-agents--faces-matcher (limit)
  "Face the next headline before LIMIT that a declared attribute draws.
A font-lock MATCHER: it answers non-nil for a match, leaves match-data
describing what to face and leaves point where the search should resume.
Called again by font-lock for whatever is left of the region, so a
headline that maps to nothing must not stop the scan -- hence the loop,
which runs on to LIMIT and answers nil there.

Three details, all measured, and each of them a way to get this wrong.

`org-agents-resolve-property-quietly' CLOBBERS match-data, so the
resolution happens inside `save-match-data' and `set-match-data' is the
last thing done.  It does not move point today -- measured across a local
value, a chain hop, a declared default and a dangling reference -- and
`save-excursion' wraps it anyway, so that where this loop leaves point is
a property of this function rather than a fact about a callee.

And it must never SIGNAL.  `org-agents-resolve-property-quietly' demotes
a `user-error' and nothing else, and an `error' escaping a matcher
reaches redisplay, where Emacs turns the keyword off for the rest of the
session -- leaving a buffer that has silently stopped following its
attributes.  So the per-headline resolution wears a `condition-case'
belt, reporting through the once-per-key table rather than through
`with-demoted-errors', which would message per occurrence.

Answers nil without resolving anything at all where nothing declares a
face, which is what makes the global variant affordable in a corpus with
no registry."
  (let ((attrs (org-agents--faces-declared))
        (found nil))
    (while (and attrs (not found)
                (re-search-forward org-agents--faces-heading-re limit t))
      (let ((bol (match-beginning 0))
            (beg (match-beginning 1))
            (end (match-end 1)))
        (when-let* ((face (save-excursion
                            (save-match-data
                              (condition-case err
                                  (org-agents--faces-at bol attrs)
                                (error
                                 (org-agents--prototype-report
                                  (concat "faces\0" (error-message-string err))
                                  "org-agents: faces: %s"
                                  (error-message-string err))))))))
          (setq org-agents--faces-face face)
          (set-match-data (list beg end))
          (setq found t))))
    found))

(defun org-agents--faces-fontify-region (beg end &optional loudly)
  "Fontify BEG to END with the registry read once and each diagnostic said once.
The smallest thing that can hold a dynamic binding across a whole
fontification run, which a font-lock keyword cannot.  Both bindings are
measured, and the section comment above carries the numbers: one registry
read against 405 for a whole-buffer pass over a 400-entry buffer, and one
message against twenty for twenty dangling references.  Please do not
simplify it away -- `org-agents-test-faces-read-the-registry-once-per-region'
and `org-agents-test-faces-a-dangling-prototype-is-said-once' are what
will tell you if you do.

Calls whatever this variable held before the mode wrapped it, so a mode
that had installed a region function of its own goes on fontifying
underneath."
  (org-agents--with-attributes
    (let ((org-agents--prototype-warned (org-agents--faces-warned-table)))
      (funcall (if org-agents--faces-outer-local
                   org-agents--faces-outer-fontify
                 #'font-lock-default-fontify-region)
               beg end loudly))))

(defun org-agents--faces-extend-region (beg end old-len)
  "Extend a post-change refontification back to the enclosing HEADLINE.
For `font-lock-extend-after-change-region-function', and it is what makes
the face follow an EDIT to the value it is drawn from.

The face is on the headline and the value is in the drawer under it, so
the two are on different lines -- and a change refontifies its own line.
MEASURED under real jit-lock, without this: changing `:STATUS: blocked'
to `:STATUS: done' in a drawer left the headline reading
`(org-warning org-level-1)' after a whole-buffer `jit-lock-fontify-now',
and only an explicit `font-lock-flush' moved it to `(org-done
org-level-1)'.  The display was asserting a value the drawer no longer
held, in a mode whose whole pitch is that the face sees what grep cannot.
`jit-lock-after-change' clears the `fontified' property over the changed
line only, and Org's own `org-fontify-extend-region' extends for `\\[',
`#+begin_' and `\\begin{' blocks and never back to a heading.

So the extension is ours to make, and it is the cheapest one that
answers: one regexp search backwards for the enclosing headline, which
costs an entry's worth of buffer and adds that entry's ONE resolution to
the region font-lock was going to fontify anyway.

The outer function is called FIRST and its answer widened rather than
replaced, so Org's block extension still happens underneath -- the same
shape `org-agents--faces-fontify-region' has, for the same reason.  BEG,
END and OLD-LEN are `after-change-functions''s three, and OLD-LEN is
passed on rather than read here.

What this does NOT reach, and no hook in this mode does: a change to the
REGISTRY, to a prototype MASTER out in the corpus, or to a `:PROTOTYPE:'
line in another buffer.  Any of those moves a resolved value in every
follower buffer at once, and nothing here refontifies a buffer other than
the one being edited -- so a corpus buffer left open across such an edit
keeps its old colour until it is refontified, by `M-x font-lock-flush' or
by scrolling away and back.  Documented rather than fixed: flushing every
armed buffer on a registry edit means watching the registry's cache key
from a change hook in an unrelated buffer, which is a great deal more
machinery than the case is worth, and the value it draws is right again
the moment the buffer is refontified."
  (let* ((outer (and org-agents--faces-outer-extend-local
                     org-agents--faces-outer-extend))
         (region (and outer (funcall outer beg end old-len)))
         (from (if region (min beg (car region)) beg))
         (to (if region (max end (cdr region)) end)))
    (cons (save-excursion
            (save-match-data
              (goto-char from)
              (forward-line 1)
              (if (re-search-backward "^\\*+ " nil t) (point) from)))
          to)))

;;;###autoload
(define-minor-mode org-agents-faces-mode
  "Face this buffer's headlines from declared attribute values.
A headline whose RESOLVED value for a declared attribute is one that the
attribute's `:ATTR_FACES:' names is drawn in the face beside it, ahead of
`org-level-N' rather than instead of it -- so the colour follows the
attribute and the height, the family and everything else the face does
not specify still come from Org.

Resolved, and that is the point.  A value arriving through a
`:PROTOTYPE:' chain, or out of the registry's `:ATTR_DEFAULT:', faces the
headline exactly as a value in its own drawer does, so an entry that
spells nothing at all is drawn from what it inherits.

`:ATTR_FACES:' is the whole of the opt-in: every declared attribute that
names faces is consulted, in the order the registry declares them, and
the first one that resolves to a named value wins.

CHANGES NO BYTES.  One font-lock keyword and nothing else: no text is
inserted, no property is written, no overlay is created, and turning the
mode off puts the buffer back exactly as it was -- the keyword is removed
and font-lock's own unfontify pass takes the face off.  So it is safe to
leave on in a file under version control.

Costs what is displayed.  jit-lock calls the matcher over the region it
is about to draw, the matcher reads only the entry at its match, and the
registry is read once for that region rather than once per headline.

Follows an EDIT to the value it draws from: changing `:STATUS:' in an
entry's drawer moves the face on the headline above it, which takes a hook
of its own because a change refontifies its own line and the two are on
different lines -- see `org-agents--faces-extend-region', which also says
what is NOT followed.  An edit to the registry, or to a prototype master
in another buffer, moves a resolved value in every follower at once, and
nothing here refontifies a buffer other than the one being edited: an
armed buffer left open across such an edit keeps its old colour until it
is refontified, by `M-x font-lock-flush' or by being scrolled away and
back.

Nothing here writes, and nothing here is geometry.  See the `Appearance'
section of org-agents.el for both refusals and for why they are
refusals."
  :lighter " Attrs"
  :group 'org-agents
  (cond
   ((not org-agents-faces-mode)
    (font-lock-remove-keywords nil org-agents--faces-keywords)
    ;; Only where ours is still the installed one.  A mode layered on TOP
    ;; of this one, going off after it, would otherwise be clobbered.
    (when (eq font-lock-fontify-region-function
              #'org-agents--faces-fontify-region)
      (if org-agents--faces-outer-local
          (setq-local font-lock-fontify-region-function
                      org-agents--faces-outer-fontify)
        (kill-local-variable 'font-lock-fontify-region-function)))
    (when (eq font-lock-extend-after-change-region-function
              #'org-agents--faces-extend-region)
      (if org-agents--faces-outer-extend-local
          (setq-local font-lock-extend-after-change-region-function
                      org-agents--faces-outer-extend)
        (kill-local-variable 'font-lock-extend-after-change-region-function)))
    (kill-local-variable 'org-agents--faces-outer-fontify)
    (kill-local-variable 'org-agents--faces-outer-local)
    (kill-local-variable 'org-agents--faces-outer-extend)
    (kill-local-variable 'org-agents--faces-outer-extend-local)
    (kill-local-variable 'org-agents--faces-warned)
    (font-lock-flush))
   ;; Turned off again before the refusal is signaled, as `org-agents-mode'
   ;; is: `define-minor-mode' has set the variable by the time this body
   ;; runs, so a refusal that only signaled would leave a mode reporting
   ;; itself enabled with no keyword behind it.
   ((not (derived-mode-p 'org-mode))
    (setq org-agents-faces-mode nil)
    (user-error "org-agents: `org-agents-faces-mode' needs an Org buffer"))
   (t
    ;; IDEMPOTENT, and it has to be.  `define-minor-mode' runs this body on
    ;; every `(mode 1)' however often the mode is already on, and two
    ;; enables reach one buffer through the two configurations
    ;; docs/init-snippet.org recommends side by side: the globalized mode
    ;; arms the buffer from `after-change-major-mode-hook', and
    ;; `hack-local-variables' then honours a file-local
    ;; `mode: org-agents-faces' and asks for it again.  Recorded
    ;; unconditionally, the second pass would find the variable local
    ;; BECAUSE WE MADE IT LOCAL and record OUR OWN function as the outer
    ;; one, and `org-agents--faces-fontify-region' would funcall itself:
    ;; MEASURED, `excessive-lisp-nesting' out of the first jit-lock pass,
    ;; every headline left with no face at all -- Org's `org-level-N'
    ;; included, because ours is the region function that never ran -- and
    ;; jit-lock's `fontified' property already stamped, so nothing retries.
    ;; Disabling did not repair it either: the `eq' guard above passed and
    ;; handed our own function back as the restore.
    ;;
    ;; The guard is on the region function alone and covers both records,
    ;; because both are made in this one block and are therefore consistent
    ;; whenever ours is not yet installed.  The keyword needs no guard:
    ;; MEASURED, `font-lock-add-keywords' with a nil MODE removes an
    ;; `equal' keyword before adding it, so a second add is a no-op.
    (unless (eq font-lock-fontify-region-function
                #'org-agents--faces-fontify-region)
      (setq org-agents--faces-outer-local
            (local-variable-p 'font-lock-fontify-region-function))
      (setq org-agents--faces-outer-fontify
            (and org-agents--faces-outer-local
                 font-lock-fontify-region-function))
      (setq org-agents--faces-outer-extend-local
            (local-variable-p 'font-lock-extend-after-change-region-function))
      (setq org-agents--faces-outer-extend
            (and org-agents--faces-outer-extend-local
                 font-lock-extend-after-change-region-function))
      (setq-local font-lock-fontify-region-function
                  #'org-agents--faces-fontify-region)
      (setq-local font-lock-extend-after-change-region-function
                  #'org-agents--faces-extend-region))
    ;; `append', and `org-agents--faces-keywords' says at length why.
    (font-lock-add-keywords nil org-agents--faces-keywords 'append)
    (font-lock-flush))))

(defun org-agents--faces-turn-on ()
  "Enable `org-agents-faces-mode' in an Org buffer.
What `global-org-agents-faces-mode' calls in each buffer.  A buffer that
is not Org is passed over silently rather than refused: the mode's own
refusal is for a user who asked for it by name.

Every Org buffer, and DELIBERATELY not the shape `org-agents--turn-on'
has.  That one arms only a buffer whose text matches `:AGENT_QUERY:', and
copying it here would be a bug: the values this mode draws from arrive
through a `:PROTOTYPE:' chain or out of `:ATTR_DEFAULT:', and an entry
faced that way spells NOTHING AT ALL -- grep does not see an inherited
value, so a text scan for any property name would miss exactly the
entries this mode exists for.

Affordable because measured: where nothing declares a face the matcher
answers nil before it resolves anything, so a corpus with no registry
pays a regexp scan of the displayed region and nothing else."
  (when (derived-mode-p 'org-mode)
    (org-agents-faces-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-org-agents-faces-mode
  org-agents-faces-mode org-agents--faces-turn-on
  ;; `:risky t' reaches the `defcustom' this generates: turning the mode on
  ;; is what makes every Org buffer read the registry and walk prototype
  ;; chains as it redisplays.
  :risky t
  :group 'org-agents)

;;;; Actions

;; An agent may carry an ACTION as well as a query: a declarative
;; sentence in `:AGENT_ACTION:' saying what to do to the entries the
;; query matched.  This is the only part of the package that writes
;; outside the agent's own file, and it is placed LAST, physically apart
;; from `Commands' and from `Minor mode', so that nothing about the
;; file's layout invites the inference that a save touches it.  Being
;; last also means every function it calls is already defined, which is
;; what keeps the section free of forward references under a byte
;; compiler run at zero warnings.
;;
;; Three refusals, and they are the design rather than caveats on it.
;;
;; NEVER ON SAVE, never on a timer, never from either minor mode.  The
;; only thing that runs an action is `org-agents-apply-actions', typed.
;; Structurally, and not by discipline: the action text is NOT part of
;; the plist `org-agents--read-agent' answers with, so it does not exist
;; as data anywhere on the save path -- there is no `:action' for a
;; renderer to find, and a reader does not have to prove that nobody
;; used it.  The one read is the `org-agents--entry-get' in the command
;; below.  `org-agents-test-action-entry-points-never-run-a-verb'
;; enumerates every entry point in this file and asserts it, and
;; `org-agents-test-action-entry-point-list-is-complete' derives that
;; enumeration from the source text so a new command cannot arrive
;; unexamined.
;;
;; NEVER INHERITABLE.  The action is read from the agent entry's OWN
;; drawer, with `org-entry-get' and no INHERIT argument, and never
;; through `org-agents-resolve-property' -- even though that resolver
;; refuses `AGENT_' names itself, because a guarantee that lives in
;; another section's regexp is a guarantee one edit away from gone.  The
;; reason is per-file trust: if a prototype, an outline ancestor, a
;; `#+PROPERTY:' line or `org-global-properties' could supply an action,
;; then the code that edits your corpus when you act on file A is
;; written in file B, and reading a file before trusting it means
;; nothing.
;;
;; NOTHING IN THE PROPERTY IS EVER EVALUATED.  The parser is a regexp
;; lexer over a string: no `read', no `read-from-string', no `eval', no
;; `format' into a form, no `macroexpand', and no `intern' of caller
;; text -- `intern-soft' of a CONSTRUCTED name, and then `fboundp'.
;; Arguments reach a verb as strings, verbatim.  A token naming no verb
;; is a syntax error rather than a call, and an argument shaped like a
;; sexp is refused by shape.  The worst thing expressible here is a
;; bounded, greppable Org edit.
;;
;; A verb is a `defun' named `org-agents-action/NAME!' taking
;; `(PHASE . ARGS)': `plan' answers `(OLD . NEW)' and writes nothing,
;; `apply' performs the edit.  Extension is therefore a `defun' in init
;; and nothing registers anything -- the namespace convention is the
;; contract.  A planner that writes anyway is CAUGHT rather than
;; trusted: see `org-agents--action-plan' and its modification-tick
;; tripwire.
;;
;; After this section, `org-entry-delete', `org-todo', `org-set-tags',
;; `org-schedule', `org-deadline', `org-priority' and
;; `org-archive-subtree' appear exactly once each in the whole package,
;; every one of them inside an `org-agents-action/...' verb.  That is a
;; greppable invariant, and README states it.

(require 'org-archive)                  ; `org-archive--compute-location'

(defcustom org-agents-action-limit 100
  "How many entries `org-agents-apply-actions' will edit in one run.
Nil for no limit.  A plan over more entries than this is REFUSED rather
than truncated: a truncated plan applies a subset the user cannot
predict, which is worse than a refusal that names the number.  Raising it
is a decision taken in init -- the option is risky, so no file can take
it.

The gate is on ENTRIES and not on edits, because entries are what a user
reasons about: an agent matches four hundred things, not four hundred
times two verbs.  The report shows both numbers, and the refusal quotes
the entry count, this limit and this option's name.

The DRY RUN is never capped, whatever this is set to.  A cap on planning
would make the report understate what applying would do, which is the
one thing the report may not do; the limit refuses before anything is
planned, so a refused run costs the match and nothing more.

It is the bound on how much one command can do, and there is deliberately
no other: an agent that legitimately stamps three thousand entries must
raise this in init before it will run.  That is the cost, and it is the
right one -- the three-thousand-entry case is exactly the alarming one,
and putting its enablement in the trusted zone is the rule that file
content may only tighten."
  :type '(choice (const :tag "No limit" nil) integer)
  :risky t
  :group 'org-agents)

;;; The parser.  Pure: it reads no buffer, creates none, and writes
;;; nothing.  Every diagnostic fires before the query has run.

(defconst org-agents--action-prefix "org-agents-action/"
  "The namespace every action verb's name begins with.
Name construction plus `fboundp' IS the resolver.  There is no registry
and nothing declares anything, so a `defun' in init is an extension --
and no text out of a property can name a function outside this
namespace.")

(defconst org-agents--action-token-re "[[:alnum:]][[:alnum:]-]*!"
  "A verb token: alphanumerics and hyphens, ending in `!'.
The bang is part of the name and not punctuation around it, which is
what makes a token visibly a thing that acts.")

(defconst org-agents--action-ws-re "[ \t\n]*"
  "Whitespace between the pieces of an action.
A newline counts: an `:AGENT_ACTION:' value is one line, but a
`:AGENT_ACTION+:' continuation is joined by whatever
`org-property-separators' says, which may be one.")

(defconst org-agents--action-quoted-re "\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\""
  "A quoted argument, group 1 holding its text still escaped.
A quoted argument may hold commas, parentheses and escaped quotes, and
is ALWAYS literal -- it is never read as a value keyword.  That is the
documented escape hatch for both of the shape rules below.")

(defconst org-agents--action-bare-re "[^,()\"]+"
  "A bare argument: anything but a comma, a parenthesis or a quote.
Parentheses are outside it DELIBERATELY, and this is where the design
parts from an evaluator.  `set-property!(X, (shell-command \"y\"))' is
therefore a parse error naming the verb and the argument position,
rather than a value that has to be proved harmless afterwards: an
argument that LOOKS like Lisp is refused by shape.  The documented way
to store literal parentheses is to quote the argument, and a quoted one
arrives as text.")

(defconst org-agents--action-values
  '(("today" . date) ("now" . datetime) ("empty" . empty))
  "The value keywords, and what each expands to.
Three, and a `defconst' rather than an option: this is a vocabulary,
nothing configures it, and a file cannot extend it.  Interpreted by the
verbs that take a VALUE and by nothing else -- see
`org-agents--action-value' for why the parser cannot do it.")

(defconst org-agents--action-date-re
  "\\`\\(?:[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?: [0-9]\\{2\\}:[0-9]\\{2\\}\\)?\
\\|[-+][-+]?[0-9]+[dwmy]\\|today\\|now\\)\\'"
  "The shapes `scheduled!' and `deadline!' accept.
A date, a date and a time, an offset like `+7d' or `++2w', `today' or
`now'.  Anything else is refused, and the refusal is the point: MEASURED,
`(org-read-date nil nil \"junk\")' answers with TODAY'S DATE silently,
so `(org-schedule nil \"garbage\")' schedules today and says nothing.
Ported naively, `scheduled!(nextweek)' would mass-schedule a corpus to
today.")

(defconst org-agents--action-tag-re "\\`[-+][[:alnum:]_@#%]+\\'"
  "A `tag!' term: a sign, then a tag Org will accept.
The sign is required.  See `org-agents-action/tag!' for why an unsigned
term is refused rather than read as \"add\".")

(defconst org-agents--action-special-verbs
  '(("TODO" . "todo!") ("PRIORITY" . "priority!")
    ("SCHEDULED" . "scheduled!") ("DEADLINE" . "deadline!")
    ("TAGS" . "tag!"))
  "The verb that edits each special property `set-property!' refuses.
Named in the refusal, so a corpus that spelled `set-property!(TODO, ...)'
is told what to write instead of being told only that it cannot.")

(defun org-agents--action-error (format &rest args)
  "Signal a `user-error' about the action text, prefixed as one.
Every diagnostic in this section names the thing a reader has to go and
fix -- the token, the verb, the argument's position -- because the text
came out of a file and the reader is looking at that file."
  (apply #'user-error (concat "org-agents: :AGENT_ACTION: " format) args))

(defun org-agents--action-at (regexp text index)
  "Non-nil when REGEXP matches TEXT starting exactly at INDEX.
Sets the match data, so a caller reads with `match-string' and advances
with `match-end'.

DELIBERATELY NOT a regexp beginning `\\\\=': MEASURED, `string-match'
with a non-zero START does not anchor such a pattern at START, and the
first prototype of this lexer therefore mis-lexed every input -- a bare
`archive!' was reported as an error at character 4.  `\\\\=' is a POINT
anchor and there is no point in a string.  The `(= (match-beginning 0)
INDEX)' idiom below is what org-edna's own lexer uses, and it is
correct.  Please do not \"simplify\" this back."
  (and (string-match regexp text index)
       (= (match-beginning 0) index)))

(defun org-agents--action-skip-ws (text index)
  "The index in TEXT of the first non-whitespace character at or after INDEX."
  (if (org-agents--action-at org-agents--action-ws-re text index)
      (match-end 0)
    index))

(defun org-agents--action-unescape (text)
  "TEXT with each `\\X' reduced to `X'.
One `replace-regexp-in-string', with FIXEDCASE non-nil so that nothing
about the replacement is taken from the case of the text it replaces.
The template is this function's own -- a corpus never supplies one."
  (replace-regexp-in-string "\\\\\\(.\\)" "\\1" text t))

(defun org-agents--action-quoted-p (text)
  "Non-nil when TEXT came out of a QUOTED argument.
The parser marks a quoted argument with a text property rather than
answering with a richer object, so that every argument is still a string
and `org-agents--parse-actions' still answers with strings alone.  What
the mark is for is `org-agents--action-value': a bare word may be one of
three value keywords, and a quoted one is always the literal text."
  (and (> (length text) 0)
       (get-text-property 0 'org-agents-action-quoted text)
       t))

(defun org-agents--action-token (verb)
  "The `:AGENT_ACTION:' token VERB answers to."
  (string-remove-prefix org-agents--action-prefix (symbol-name verb)))

(defun org-agents--action-resolve (token)
  "The verb TOKEN names, or nil when nothing does.
`intern-soft' of a CONSTRUCTED name, and then `fboundp'.  Both halves
matter.  The name is constructed, so a property can never reach a
function outside `org-agents--action-prefix'.  It is `intern-soft' and
not `intern' so that a corpus full of misspelled tokens cannot grow the
obarray either: a symbol that does not exist yet cannot be `fboundp', so
there is nothing to be gained by making one."
  (when-let* ((symbol (intern-soft (concat org-agents--action-prefix token))))
    (and (fboundp symbol) symbol)))

(defun org-agents--action-terminal-p (verb)
  "Non-nil when VERB must be the last one in an action.
Declared with a symbol property, like destructiveness, so that a verb
defined in init can declare it too."
  (and (get verb 'org-agents-action-terminal) t))

(defun org-agents--action-check-arity (verb token args)
  "Refuse ARGS where VERB, which TOKEN names, does not take that many.
`func-arity' answers for a verb defined in init exactly as for one
defined here, so the check costs an extension nothing: no declaration,
no registration, and no second name to keep in step.  PHASE is the first
parameter of every verb, so the arity of the argument list is the
function's own less one."
  (pcase-let ((`(,minimum . ,maximum) (func-arity verb)))
    (unless (and (integerp minimum) (>= minimum 1))
      (org-agents--action-error
       "`%s' is not a usable verb: a verb takes PHASE and then its arguments"
       token))
    (let* ((low (1- minimum))
           (high (and (integerp maximum) (1- maximum)))
           (given (length args)))
      (when (or (< given low) (and high (> given high)))
        (org-agents--action-error
         "`%s' takes %s, and %d %s given" token
         (cond ((and high (= low high))
                (format "%d argument%s" low (if (= 1 low) "" "s")))
               (high (format "%d to %d arguments" low high))
               (t (format "at least %d argument%s" low (if (= 1 low) "" "s"))))
         given (if (= 1 given) "was" "were"))))))

(defun org-agents--action-args (text index token)
  "Parse the argument list of TOKEN, which opens at INDEX in TEXT.
Answers `(ARGS . NEW-INDEX)'.  TEXT at INDEX is the opening parenthesis.
Every argument is a string: a bare one `string-trim'med, a quoted one
unescaped and marked -- see `org-agents--action-quoted-p'.  Every
diagnostic names TOKEN and the 1-based position of the argument, because
that is what a reader has to go and look at."
  (let ((length (length text))
        (args nil)
        (position 0)
        (index (1+ index))
        (done nil))
    (setq index (org-agents--action-skip-ws text index))
    (if (and (< index length) (= (aref text index) ?\)))
        (cons nil (1+ index))           ; an empty list, `todo!()'
      (while (not done)
        (setq position (1+ position))
        (setq index (org-agents--action-skip-ws text index))
        (cond
         ((>= index length)
          (org-agents--action-error "`%s' argument list is not closed" token))
         ((org-agents--action-at org-agents--action-quoted-re text index)
          (push (propertize (org-agents--action-unescape (match-string 1 text))
                            'org-agents-action-quoted t)
                args)
          (setq index (match-end 0)))
         ((org-agents--action-at org-agents--action-bare-re text index)
          (let ((bare (string-trim (match-string 0 text))))
            (when (string-empty-p bare)
              (org-agents--action-error "`%s' argument %d is malformed"
                                        token position))
            (push bare args)
            (setq index (match-end 0))))
         (t (org-agents--action-error "`%s' argument %d is malformed"
                                      token position)))
        (setq index (org-agents--action-skip-ws text index))
        (cond
         ((>= index length)
          (org-agents--action-error "`%s' argument list is not closed" token))
         ((= (aref text index) ?,) (setq index (1+ index)))
         ((= (aref text index) ?\)) (setq index (1+ index)) (setq done t))
         (t (org-agents--action-error "`%s' argument %d is malformed"
                                      token position))))
      (cons (nreverse args) index))))

(defun org-agents--parse-actions (text)
  "Parse TEXT, an `:AGENT_ACTION:' value, into a list of `(VERB . ARGS)'.
VERB is a symbol `fboundp' answered t for, produced only by
`org-agents--action-resolve'.  Every element of ARGS is a STRING, taken
verbatim out of TEXT: there are no symbols, no numbers, no lists and no
other object type anywhere in the answer.  So

  set-property!(REVIEWED, today) tag!(+reviewed)

parses to

  ((org-agents-action/set-property! \"REVIEWED\" \"today\")
   (org-agents-action/tag!          \"+reviewed\"))

PURE.  No buffer is read, none is created, and nothing is written -- so
a caller may parse in any buffer, at any point, as often as it likes.

Every diagnostic is a `user-error' naming the token, the verb and the
argument's position, and every one of them fires HERE: parsing is step 2
of `org-agents-apply-actions' and collecting the matches is step 3, so a
typo does not even open the corpus and there is no partial application
to undo.  There is no half-applied state to close off, only an ordering
to hold, and a test holds it.

Nothing is read as Lisp.  What is deliberately absent, and why:
`read-from-string' -- which is how org-edna lexes -- accepts far more
than this language names.  MEASURED, as the argument list of one verb:
`(#$)' reads as nil and, inside a file being loaded, as that file's own
name; `(#s(hash-table test equal))' yields a live hash table;
`(#1=(a . #1#))' yields a CIRCULAR cons, which `format' \"%s\" prints
forever unless `print-circle' happens to be bound, so a property could
hang a report; `(#[257 \"\\300\\207\" [1] 2])' yields a byte-code
object, a callable arriving as data; and `(a b' yields
`(end-of-file nil)' -- no position and no verb name, which is exactly
the diagnostic this function may not give.  `read' also INTERNS every
bare word it passes, so a corpus could grow the obarray, and every
argument would then have to be turned back into a string anyway.  The
regexp lexer refuses all of those by shape, and names the verb when it
does."
  (save-match-data
    (let ((length (length text))
          (index (org-agents--action-skip-ws text 0))
          (verbs nil))
      (while (< index length)
        (unless (org-agents--action-at org-agents--action-token-re text index)
          (org-agents--action-error
           "unreadable at character %d: `%s'" (1+ index)
           (substring text index (min length (+ index 24)))))
        (let ((token (match-string 0 text))
              (args nil)
              (verb nil))
          (setq index (match-end 0))
          (setq verb (or (org-agents--action-resolve token)
                         (org-agents--action-error
                          "`%s' is not an action verb (there is no `%s%s')"
                          token org-agents--action-prefix token)))
          (setq index (org-agents--action-skip-ws text index))
          (when (and (< index length) (= (aref text index) ?\())
            (let ((parsed (org-agents--action-args text index token)))
              (setq args (car parsed))
              (setq index (cdr parsed))))
          (org-agents--action-check-arity verb token args)
          ;; Refused HERE and not diagnosed mid-apply.  A terminal verb
          ;; removes the subtree a later verb would edit, so anything
          ;; after one -- another copy of it included -- is a parse
          ;; error, and nothing runs at all.  Cheap, and it turns a
          ;; confusing half-applied failure into a sentence about the
          ;; property.
          (when-let* ((previous (car-safe (car verbs))))
            (when (org-agents--action-terminal-p previous)
              (org-agents--action-error
               "`%s' must be the last verb"
               (org-agents--action-token previous))))
          (push (cons verb args) verbs)
          (setq index (org-agents--action-skip-ws text index))))
      (nreverse verbs))))

;;; The vocabulary.  Nine verbs, each over Org's own editing primitives,
;;; each a `pcase' on PHASE.  An unknown phase is an `error' and not a
;;; `user-error': the phase is this package's own argument, so a third
;;; value can only be a bug here.

(defun org-agents--action-phase-error (token phase)
  "Signal that the verb TOKEN was called with PHASE, which is neither."
  (error "org-agents: `%s' called with bad action phase %S" token phase))

(defun org-agents--action-where ()
  "Where point is, as one string, for a verb's diagnostic to name it by."
  (format "%s:%d"
          (if-let* ((file (buffer-file-name (buffer-base-buffer))))
              (abbreviate-file-name file)
            (buffer-name))
          (line-number-at-pos)))

(defun org-agents--action-value (text)
  "TEXT as a property value: a keyword expanded, anything else verbatim.
The three keywords are `org-agents--action-values': `today' is an
INACTIVE date stamp, `now' an inactive date and time, `empty' the empty
string.  Inactive deliberately -- a value written into a drawer must not
put the entry on the agenda, which is the reasoning `:AGENT_MATCHED:'
already records.

Interpreted HERE, in the verbs, and never in the parser: the parser
cannot know which argument is a value, since `set-property!''s first
argument is a property NAME and must stay literal whatever it spells.

A QUOTED argument is never a keyword.  `set-property!(REVIEWED, today)'
stores today's date and `set-property!(REVIEWED, \"today\")' stores the
five letters.  That is the one cost of having keywords at all -- a
keyword shadows a literal -- and quoting is the escape hatch: a bare
word is literal unless it is one of three keywords, and a quoted
argument is always literal.

Text properties come off, because the answer is inserted into a buffer
and the quoting mark is the parser's business rather than Org's."
  (let ((plain (substring-no-properties text)))
    (pcase (and (not (org-agents--action-quoted-p text))
                (cdr (assoc-string plain org-agents--action-values)))
      ('date (format-time-string (org-time-stamp-format nil t)))
      ('datetime (format-time-string (org-time-stamp-format t t)))
      ('empty "")
      (_ plain))))

(defun org-agents--action-date (token date)
  "DATE as text `org-read-date' will read, or a `user-error' naming TOKEN.
The SHAPE is checked first, and that check is the whole reason this
function exists -- see `org-agents--action-date-re' for the measurement.

`today' and `now' are expanded here rather than handed to
`org-read-date', so what is scheduled is what the word says and not
whatever that parser makes of it."
  (unless (string-match-p org-agents--action-date-re date)
    (org-agents--action-error
     (concat "`%s' takes a date `2026-08-27', a date and time"
             " `2026-08-27 14:00', an offset `+7d', `today' or `now'"
             " -- not `%s'")
     token date))
  (cond ((equal date "today") (format-time-string "%Y-%m-%d"))
        ((equal date "now") (format-time-string "%Y-%m-%d %H:%M"))
        (t date)))

(defun org-agents--action-stamp (date)
  "The planning stamp DATE resolves to, as `<2026-08-27 Thu>'.
Computed, and computed WITHOUT writing: the dry run has to show the date
the apply phase is about to write, and an offset like `+7d' is not one a
reader can work out from the line."
  (let* ((with-time (and (string-match-p "[0-9][0-9]:[0-9][0-9]" date) t))
         (time (org-read-date with-time t date)))
    (format-time-string (org-time-stamp-format with-time) time)))

(defun org-agents--action-planning (phase token property setter date)
  "The body `scheduled!' and `deadline!' share.
PROPERTY is read for the plan's OLD, SETTER writes it in the apply phase,
and TOKEN names the verb in a diagnostic.

SETTER is `org-schedule' or `org-deadline', called DIRECTLY.  Never
`org-entry-put': MEASURED, it special-cases `SCHEDULED' and `DEADLINE'
and for an empty or `earlier'/`later' value reaches
`call-interactively' on `org-schedule' -- a prompt from inside a verb, in
the middle of a run over a corpus."
  (let ((date (org-agents--action-date token date)))
    (pcase phase
      ('plan (cons (org-entry-get nil property)
                   (org-agents--action-stamp date)))
      ('apply (funcall setter nil date))
      (_ (org-agents--action-phase-error token phase)))))

(defun org-agents--action-tag-terms (spec)
  "SPEC's signed terms, each checked against `org-agents--action-tag-re'."
  (let ((terms (split-string spec "[ \t]+" t)))
    (unless terms
      (org-agents--action-error "`tag!' was given no tag"))
    (dolist (term terms)
      (unless (string-match-p org-agents--action-tag-re term)
        (org-agents--action-error
         "`tag!' term `%s' must be `+TAG' to add it or `-TAG' to remove it"
         term)))
    terms))

(defun org-agents--action-tags (spec tags)
  "TAGS with SPEC's signed terms applied, left to right.
A tag added twice is added once, and a tag removed that was not there is
not an error: the answer is a set, and the order of what was already
there is kept so that the report's `old -> new' reads as a change rather
than as a rewrite."
  (let ((result (copy-sequence tags)))
    (dolist (term (org-agents--action-tag-terms spec))
      (let ((name (substring term 1)))
        (setq result
              (if (eq (aref term 0) ?+)
                  (if (member name result) result (append result (list name)))
                (remove name result)))))
    result))

(defun org-agents--action-tag-text (tags)
  "TAGS as Org spells them, `:a:b:', or the empty string for none."
  (if tags (concat ":" (string-join tags ":") ":") ""))

(defun org-agents-action/set-property! (phase name value)
  "Set property NAME to VALUE at the entry.

Syntax: set-property!(NAME, VALUE)

VALUE goes through `org-agents--action-value', so `today', `now' and
`empty' are the three keywords and everything else is its own text.

A SPECIAL property is refused, and named.  MEASURED: `org-entry-put'
special-cases `TODO', `PRIORITY', `SCHEDULED' and `DEADLINE', and for a
`SCHEDULED'/`DEADLINE' value that is empty or `earlier'/`later' it
reaches `call-interactively' on `org-schedule'.  Org would signal for
some of those anyway; naming the verb that does edit them turns what
looks like a bug in this package into a diagnosis of the corpus."
  (when (member (upcase name) org-special-properties)
    (let ((instead (cdr (assoc-string (upcase name)
                                      org-agents--action-special-verbs))))
      (org-agents--action-error
       "`set-property!' will not write the special property `%s'%s" name
       (if instead (format "; use `%s'" instead) ""))))
  (let ((new (org-agents--action-value value)))
    (pcase phase
      ('plan (cons (org-entry-get nil name) new))
      ('apply (org-entry-put nil name new))
      (_ (org-agents--action-phase-error "set-property!" phase)))))

(defun org-agents-action/delete-property! (phase name)
  "Delete property NAME at the entry.

Syntax: delete-property!(NAME)

DESTRUCTIVE: it removes information, so it confirms at every entry on
every run.  There is no remembered approval, no option that silences it,
and in batch it is refused rather than assumed -- see
`org-agents--action-confirm'."
  (pcase phase
    ('plan (cons (org-entry-get nil name) nil))
    ('apply (org-entry-delete nil name))
    (_ (org-agents--action-phase-error "delete-property!" phase))))

(defun org-agents-action/tag! (phase spec)
  "Add and remove tags at the entry, following SPEC.

Syntax: tag!(+added -removed)

Whitespace-separated SIGNED terms, applied left to right.  `tag!(+a -b)'
adds `a' and removes `b'; `tag!(reviewed)' is refused, and the refusal
says to write `+reviewed'.

DELIBERATELY NOT org-edna's `tag!', and the divergence is the point.
That one hands a whole tag specification to `org-set-tags' and therefore
REPLACES the entry's tags.  Over an agent's match set that is a silent
mass deletion -- bounded, and data-destroying -- from a verb whose
one-word form looks additive.  A set-all form, if it is ever wanted, is a
different verb and it is destructive.  README states this."
  (let ((tags (org-get-tags nil t)))
    (pcase phase
      ('plan (cons (org-agents--action-tag-text tags)
                   (org-agents--action-tag-text
                    (org-agents--action-tags spec tags))))
      ('apply (org-set-tags (org-agents--action-tags spec tags)))
      (_ (org-agents--action-phase-error "tag!" phase)))))

(defun org-agents-action/todo! (phase state)
  "Set the entry's TODO keyword to STATE.

Syntax: todo!(DONE)

STATE is checked against `org-todo-keywords-1' READ IN THE MATCH'S OWN
BUFFER, because those keywords are buffer-local: a corpus may spell
different ones file by file, which is another reason the planner runs at
the match rather than at the agent.

The check is a better-LOCATED version of a refusal that already exists.
MEASURED, `org-todo' itself signals a `user-error' for a state the file
does not admit.  Raised in the `plan' phase, so a state no file admits
costs nothing: the command refuses before any entry is edited, rather
than half a corpus in."
  (pcase phase
    ('plan
     (unless (member state org-todo-keywords-1)
       (org-agents--action-error
        "`todo!' state `%s' is not a keyword in %s" state
        (org-agents--action-where)))
     (cons (org-get-todo-state) state))
    ('apply (org-todo state))
    (_ (org-agents--action-phase-error "todo!" phase))))

(defun org-agents-action/priority! (phase letter)
  "Set the entry's priority to LETTER.

Syntax: priority!(A)

One upper-case letter, inside `org-priority-highest' to
`org-priority-lowest'.  `aref' of the checked string, never
`string-to-char' of something `read'.

MEASURED, `org-priority' signals a `user-error' for a letter outside the
range, so this check too only moves an existing refusal earlier -- into
the phase that has not written anything yet."
  (unless (string-match-p "\\`[A-Z]\\'" letter)
    (org-agents--action-error
     "`priority!' takes one upper-case letter, not `%s'" letter))
  (let ((char (aref letter 0)))
    (unless (and (<= org-priority-highest char) (<= char org-priority-lowest))
      (org-agents--action-error
       "`priority!' letter `%s' is outside %c to %c" letter
       org-priority-highest org-priority-lowest))
    (pcase phase
      ('plan (cons (org-entry-get nil "PRIORITY") letter))
      ('apply (org-priority char))
      (_ (org-agents--action-phase-error "priority!" phase)))))

(defun org-agents-action/scheduled! (phase date)
  "Schedule the entry for DATE.

Syntax: scheduled!(2026-08-27), scheduled!(+7d), scheduled!(today)

See `org-agents--action-date-re' for the shapes accepted, and for the
measured hazard the shape check exists to close."
  (org-agents--action-planning phase "scheduled!" "SCHEDULED"
                               #'org-schedule date))

(defun org-agents-action/deadline! (phase date)
  "Give the entry a deadline of DATE.

Syntax: deadline!(2026-08-27), deadline!(+7d), deadline!(today)

The same shapes `scheduled!' takes, and the same refusal."
  (org-agents--action-planning phase "deadline!" "DEADLINE"
                               #'org-deadline date))

(defun org-agents-action/effort! (phase value)
  "Set the entry's effort to VALUE.

Syntax: effort!(0:30)

The argument stays a STRING.  Org's effort values are text -- `0:30',
`2d' -- so there is nothing to convert, and nothing in this vocabulary
calls `string-to-number' at all.  Written to `org-effort-property',
which is the name Org's own column summaries read."
  (let ((new (org-agents--action-value value)))
    (pcase phase
      ('plan (cons (org-entry-get nil org-effort-property) new))
      ('apply (org-entry-put nil org-effort-property new))
      (_ (org-agents--action-phase-error "effort!" phase)))))

(defun org-agents-action/archive! (phase)
  "Archive the entry's subtree.

Syntax: archive!

DESTRUCTIVE, so it confirms at every entry on every run; and TERMINAL,
so it must be the last verb in the text and may appear once -- it removes
the subtree a later verb would edit, and the parser refuses the ordering
rather than letting an apply pass discover it.

The destination is computed WITHOUT archiving, with the expression
`org-archive-subtree' itself uses, so the dry run can say where the
subtree is about to go.

`org-archive-subtree' directly, and deliberately neither
`org-archive-subtree-default' -- whose behaviour is whatever
`org-archive-default-command' names -- nor
`org-archive-subtree-default-with-confirmation', whose own `y-or-n-p'
would read standard input in batch and whose refusal path signals a bare
`error'.  The confirmation this verb needs is
`org-agents--action-confirm', asked by the apply pass, once per entry,
every run."
  (pcase phase
    ('plan (cons "<subtree>"
                 (car (org-archive--compute-location
                       (or (org-entry-get nil "ARCHIVE" 'inherit)
                           org-archive-location)))))
    ('apply (org-archive-subtree))
    (_ (org-agents--action-phase-error "archive!" phase))))

;; Destructiveness and terminality are declared by SYMBOL PROPERTIES, and
;; not by a list in this file or by a variable.  A verb defined in init
;; declares itself with the same two `put's, which is why a property beats
;; a list: extension must not require editing the package.  And a
;; file-local variables block cannot `put' a property -- only the `eval:'
;; escape hatch could, and that is already behind `enable-local-eval'.
;; There is no option that turns either off, because there is nothing to
;; set.
(put 'org-agents-action/delete-property! 'org-agents-action-destructive t)
(put 'org-agents-action/archive! 'org-agents-action-destructive t)
(put 'org-agents-action/archive! 'org-agents-action-terminal t)

;;; The command: read, parse, match, gate on scale, plan, report,
;;; confirm, apply, say what was modified.  Nothing is saved.

(defconst org-agents--action-buffer "*Org Agents Actions*"
  "Name of the buffer `org-agents-apply-actions' reports into.")

(defun org-agents--action-confirm (format &rest args)
  "Ask FORMAT/ARGS, or REFUSE where there is nobody to ask.
Batch and `inhibit-interaction' are REFUSALS and not defaults, and the
check comes BEFORE `y-or-n-p' so that neither of them reads standard
input and neither can hang.

MEASURED, in `-batch': `(y-or-n-p \"ok? \")' with a `y' on standard
input returns t, and with standard input closed it signals `end-of-file'
from inside whatever called it.  So a script, a CI job, or any
invocation whose stdin happened to carry text would answer yes for the
user.  `inhibit-interaction' is a caller's own declaration that it must
not be asked -- which Emacs 28 added for exactly this -- and honouring
it is honouring that contract.

There is no option that turns this off.  There is nothing to set."
  (let ((prompt (apply #'format format args)))
    (when (or noninteractive inhibit-interaction)
      (user-error "org-agents: %s -- refused, because there is no one to ask"
                  prompt))
    (y-or-n-p prompt)))

(defun org-agents--action-call (verb phase args)
  "Call VERB for PHASE with ARGS, which are strings.
The ONE call site, and it exists to be one: the test that proves no save
path reaches the action machinery replaces this along with the nine
verbs, so a caller that got at the machinery without naming a verb would
be caught too."
  (apply verb phase args))

(defun org-agents--action-visited-files ()
  "The files Emacs is already visiting, as truenames, in a hash table.
Read BEFORE the match runs, because matching opens files: someone about
to edit a file they had never opened should be told so in the sentence
they answer, and after the query there is nothing left to ask."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer)))
        (puthash (file-truename file) t table)))
    table))

(defun org-agents--action-link-marker (target)
  "A marker on the heading TARGET links to, or nil when it resolves to none.
An `id:' target is looked up in `org-id-locations' and NOWHERE else:
`org-id-find' may rescan the corpus to answer, which is not something a
command about a selection should set off.  A `file:...::*' target is
resolved by `org-link-search' in that file's own buffer."
  (save-match-data
    (cond
     ((string-prefix-p "id:" target)
      (let* ((id (substring target 3))
             (file (and (hash-table-p org-id-locations)
                        (gethash id org-id-locations))))
        (when (and file (file-readable-p file))
          (with-current-buffer (find-file-noselect file)
            (org-with-wide-buffer
             (when-let* ((position (org-find-entry-with-id id)))
               (goto-char position)
               (point-marker)))))))
     ((string-match "\\`file:\\(.+?\\)::\\(.+\\)\\'" target)
      (let ((file (match-string 1 target))
            (search (match-string 2 target)))
        (when (file-readable-p file)
          (with-current-buffer (find-file-noselect file)
            (org-with-wide-buffer
             (goto-char (point-min))
             (when (condition-case nil
                       (progn (org-link-search search nil t) t)
                     (error nil))
               (org-back-to-heading t)
               (point-marker))))))))))

(defun org-agents--action-region-targets ()
  "The entries the lines of the region link to, in order and without repeats.
The FIRST bracket link on each line, read with
`org-agents--alias-target' -- the same reading `org-agents--render-children'
recognizes an alias by -- so this serves a children view's alias
headings, a list view's items and a table view's rows alike.

This is what makes a STAMP fall out of `org-agents-apply-actions': a
stamp is this command pointed at a selection, and the region is the
selection.  The action text still comes from the agent's own drawer.

Point and the mark, and DELIBERATELY not `use-region-p'.  That predicate
answers nil wherever `transient-mark-mode' is off -- which is a setting
some people keep, and MEASURED, is also what `-batch' has -- and it is
the right predicate for a command that acts on the region only when one
happens to be active.  This one was told to: the prefix argument IS the
request, so what has to be true is that there is a mark and that it is
somewhere other than point."
  (unless (mark t)
    (user-error (concat "org-agents: with a prefix argument this acts on the"
                        " entries the region's links name, and there is no"
                        " region")))
  (let* ((targets nil)
         (seen (make-hash-table :test #'equal))
         (start (min (point) (mark t)))
         (end (max (point) (mark t))))
    (when (= start end)
      (user-error (concat "org-agents: with a prefix argument this acts on the"
                          " entries the region's links name, and the region"
                          " is empty")))
    (save-excursion
      (goto-char start)
      (beginning-of-line)
      (while (< (point) end)
        (when-let* ((target (org-agents--alias-target
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position)))))
          (let* ((marker (org-agents--action-link-marker target))
                 (key (if marker
                          (format "%s:%d" (buffer-name (marker-buffer marker))
                                  (marker-position marker))
                        target)))
            (unless (gethash key seen)
              (puthash key t seen)
              (push (list :marker marker :label target) targets))))
        (forward-line 1)))
    (unless targets
      (user-error "org-agents: no links in the region to act on"))
    (nreverse targets)))

(defun org-agents--action-targets (marker explicit)
  "The entries an action applies to: the agent's matches, or an explicit set.
Without EXPLICIT, `org-agents--collect' of the agent at MARKER -- which
gates, prefilters, self-skips and excludes generated aliases exactly as
an update does.  Two protections fall out of that, and both are worth
naming rather than rebuilding: an agent's action never edits the agent
itself, because `org-agents--self-match-p' drops it from its own match
set; and it never edits a generated alias, because `org-agents-exclude'
defaults to `(not (property \"AGENT_MATCH\"))'.

With EXPLICIT -- a prefix argument -- the set is
`org-agents--action-region-targets'.

A target is a plist `(:marker M :label TEXT)', and M may be nil: a match
whose buffer has since been killed is REPORTED rather than dropped."
  (if explicit
      (org-agents--action-region-targets)
    (org-with-point-at marker
      (mapcar (lambda (element)
                (list :marker (org-agents--live-marker element)
                      :label (or (org-element-property :raw-value element) "")))
              (org-agents--collect (org-agents--read-agent))))))

(defun org-agents--action-plan (verbs targets)
  "Plan VERBS at each of TARGETS, writing nothing; return the rows.
A row is a plist -- `:file', `:line', `:marker', `:verb', `:token',
`:args', `:old', `:new', `:outcome' -- in target order and then verb
order.  A target whose marker no longer names a live buffer becomes a
row of its own, so it is reported rather than silently dropped.

Nothing is written here, and that does NOT rest on a verb author's
discipline.  `buffer-chars-modified-tick' is read before and after every
planner call, and a tick that moved is a `user-error' naming the verb,
raised before the apply pass exists at all.  A `plan' phase that answers
anything but a cons of two strings-or-nil is diagnosed the same way: a
verb whose author wrote only the applier would otherwise contribute no
line, and the report would UNDERSTATE what applying is about to do,
which is the one failure a dry run may not have.

MEASURED, and this is the load-bearing measurement of the feature:
`buffer-read-only' cannot be the guard.  `org-entry-put' wraps its body
in `org-no-read-only', which binds `inhibit-read-only', so under
`(let ((buffer-read-only t)) ...)' it writes regardless -- while
`org-todo', `org-set-tags', `org-schedule', `org-priority' and
`org-entry-delete' all signal.  The tick is reliable: that same
suppressed `org-entry-put' MOVED it, and a pass of pure reads moved it
not at all.  It is also the right primitive rather than
`buffer-modified-p', because it counts character changes only -- a
planner that provokes fontification or folding changes text properties,
and must not be accused of writing."
  (let ((rows nil))
    (dolist (target targets)
      (let ((marker (plist-get target :marker)))
        (if (not (and (markerp marker) (marker-buffer marker)))
            (push (list :label (plist-get target :label)
                        :dead t :outcome nil)
                  rows)
          (with-current-buffer (marker-buffer marker)
            (org-with-wide-buffer
             (goto-char marker)
             (let ((file (buffer-file-name (buffer-base-buffer)))
                   (line (line-number-at-pos)))
               (pcase-dolist (`(,verb . ,args) verbs)
                 (let* ((tick (buffer-chars-modified-tick))
                        (plan (org-agents--action-call verb 'plan args))
                        (token (org-agents--action-token verb)))
                   (unless (= tick (buffer-chars-modified-tick))
                     (user-error
                      (concat "org-agents: the verb `%s' modified %s during"
                              " the dry run; nothing was applied")
                      token (if file (abbreviate-file-name file)
                              (buffer-name))))
                   (unless (and (consp plan)
                                (or (null (car plan)) (stringp (car plan)))
                                (or (null (cdr plan)) (stringp (cdr plan))))
                     (user-error
                      (concat "org-agents: the verb `%s' planned nothing: its"
                              " `plan' phase must answer (OLD . NEW), each a"
                              " string or nil, and it answered %S")
                      token plan))
                   (push (list :file file :line line
                               :marker (copy-marker marker)
                               :verb verb :token token :args args
                               :old (car plan) :new (cdr plan)
                               :outcome nil)
                         rows)))))))))
    (nreverse rows)))

(defun org-agents--action-counts (rows visited)
  "Counts describing ROWS, as a plist.
`:edits' is how many lines the report holds, `:entries' how many distinct
entries they touch, `:files' how many files those entries live in,
`:shut' how many of those files VISITED does not name -- files nobody had
open when the command began -- `:dead' how many targets had no live
buffer, and `:destructive' the tokens among them that confirm."
  (let ((entries (make-hash-table :test #'equal))
        (files (make-hash-table :test #'equal))
        (destructive nil)
        (edits 0)
        (dead 0)
        (shut 0))
    (dolist (row rows)
      (if (plist-get row :dead)
          (setq dead (1+ dead))
        (setq edits (1+ edits))
        (when-let* ((marker (plist-get row :marker)))
          (puthash (format "%s:%d" (buffer-name (marker-buffer marker))
                           (marker-position marker))
                   t entries))
        (when-let* ((file (plist-get row :file)))
          (puthash (file-truename file) t files))
        (when (get (plist-get row :verb) 'org-agents-action-destructive)
          (cl-pushnew (plist-get row :token) destructive :test #'equal))))
    (maphash (lambda (file _) (unless (gethash file visited)
                                (setq shut (1+ shut))))
             files)
    (list :edits edits
          :entries (hash-table-count entries)
          :files (hash-table-count files)
          :shut shut
          :dead dead
          :destructive (nreverse destructive))))

(defun org-agents--action-scale (counts)
  "COUNTS as the clause every sentence about them shares."
  (format "%d edit%s at %d entr%s in %d file%s%s%s"
          (plist-get counts :edits)
          (if (= 1 (plist-get counts :edits)) "" "s")
          (plist-get counts :entries)
          (if (= 1 (plist-get counts :entries)) "y" "ies")
          (plist-get counts :files)
          (if (= 1 (plist-get counts :files)) "" "s")
          (if (> (plist-get counts :shut) 0)
              (format " (%d not open before this ran)" (plist-get counts :shut))
            "")
          (if (> (plist-get counts :dead) 0)
              (format ", and %d entr%s skipped for want of a live buffer"
                      (plist-get counts :dead)
                      (if (= 1 (plist-get counts :dead)) "y" "ies"))
            "")))

(defun org-agents--action-header (counts state)
  "The report's first line: COUNTS, and where the run got to in STATE."
  (format "org-agents: %s.  %s" (org-agents--action-scale counts)
          (pcase state
            ('planned "Nothing written yet.")
            ('refused "NOTHING WAS APPLIED.")
            ('applied "Nothing was saved; every edit is undoable per buffer.")
            (_ ""))))

(defun org-agents--action-prompt (counts)
  "The one question the whole plan is answered with.
It names the destructive verbs, and it names how many files nobody had
open: those are the two things a reader of a long report might not have
noticed, and they belong in the sentence being answered."
  (format "org-agents: apply %s%s? " (org-agents--action-scale counts)
          (if-let* ((destructive (plist-get counts :destructive)))
              (format ", including the destructive %s"
                      (string-join destructive ", "))
            "")))

(defun org-agents--action-call-text (row)
  "ROW's verb and arguments, spelled the way the property spells them."
  (if-let* ((args (plist-get row :args)))
      (format "%s(%s)" (plist-get row :token)
              (mapconcat #'substring-no-properties args ", "))
    (plist-get row :token)))

(defun org-agents--action-line (row)
  "ROW as one report line.
`FILE:LINE:' first, because `compilation-mode' parses that shape as an
error: `RET', `next-error' and `M-g n' then navigate to every INTENDED
edit before anything is written, which is worth more than any prose
about a dry run.  Same measured precedent as `org-agents--attr-report'."
  (concat
   (if (plist-get row :dead)
       (format "%s: skipped: no live buffer" (plist-get row :label))
     (format "%s:%d: %s  %s -> %s"
             (or (plist-get row :file) "?")
             (or (plist-get row :line) 0)
             (org-agents--action-call-text row)
             (or (plist-get row :old) "nil")
             (or (plist-get row :new) "nil")))
   (if-let* ((outcome (plist-get row :outcome)))
       (concat "  " outcome)
     "")))

(defun org-agents--action-report (rows state counts)
  "Show ROWS in STATE, under a header describing COUNTS.
The lines go in first and the mode is set after, because the mode makes
the buffer read-only; `default-directory' is set after that in turn,
because `compilation-mode' runs `kill-all-local-variables'.  Both for
the reasons `org-agents--attr-report' gives at length."
  (let ((buffer (get-buffer-create org-agents--action-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (org-agents--action-header counts state) "\n")
        (dolist (row rows) (insert (org-agents--action-line row) "\n")))
      (compilation-mode)
      (setq-local default-directory (expand-file-name org-directory))
      (goto-char (point-min)))
    (display-buffer buffer)
    buffer))

(defun org-agents--action-apply (rows)
  "Apply ROWS in order, recording each outcome; return the buffers written.
Destructive rows confirm INDIVIDUALLY and every time -- the whole-plan
confirmation the caller already asked does not stand in for it.

An error, a refusal or a `C-g' STOPS the run at that row: the row is
marked with what happened, every later row is marked `not attempted', and
nothing after it is touched.  Deliberately not `atomic-change-group': it
cannot span buffers, and a corpus-wide rollback does not exist.  The
honest substitute is this report, plus `undo' one buffer at a time, plus
the fact that nothing was saved."
  (let ((stopped nil)
        (buffers nil))
    (dolist (row rows)
      (cond
       (stopped (plist-put row :outcome "not attempted"))
       ((plist-get row :dead)
        (plist-put row :outcome "skipped: no live buffer"))
       (t
        (condition-case err
            (let ((verb (plist-get row :verb))
                  (marker (plist-get row :marker)))
              (cond
               ((and (get verb 'org-agents-action-destructive)
                     (not (org-agents--action-confirm
                           "org-agents: %s at %s:%d -- apply it? "
                           (org-agents--action-call-text row)
                           (abbreviate-file-name (or (plist-get row :file) "?"))
                           (or (plist-get row :line) 0))))
                (plist-put row :outcome "refused")
                (setq stopped t))
               ((not (and (markerp marker) (marker-buffer marker)))
                (plist-put row :outcome "skipped: no live buffer"))
               (t
                (with-current-buffer (marker-buffer marker)
                  (org-with-wide-buffer
                   (goto-char marker)
                   (org-agents--action-call verb 'apply
                                            (plist-get row :args))))
                (cl-pushnew (marker-buffer marker) buffers)
                (plist-put row :outcome "applied"))))
          (quit (plist-put row :outcome "interrupted")
                (setq stopped t))
          (error (plist-put row :outcome
                            (format "FAILED: %s" (error-message-string err)))
                 (setq stopped t))))))
    (nreverse buffers)))

(defun org-agents--action-message (rows buffers)
  "Say what ROWS did and which of BUFFERS are modified.
The counts and the buffer names, because a summary saying only how many
had failed would leave the user to find out which -- and because the
buffers are what there is to review, `undo' and save by hand."
  (let ((applied 0) (refused 0) (failed 0) (skipped 0) (untried 0))
    (dolist (row rows)
      (pcase (plist-get row :outcome)
        ("applied" (setq applied (1+ applied)))
        ("refused" (setq refused (1+ refused)))
        ("not attempted" (setq untried (1+ untried)))
        ("interrupted" (setq failed (1+ failed)))
        ((and text (guard (and (stringp text)
                               (string-prefix-p "FAILED" text))))
         (setq failed (1+ failed)))
        (_ (setq skipped (1+ skipped)))))
    (let ((modified (cl-remove-if-not #'buffer-modified-p buffers)))
      (message (concat "org-agents: applied %d, refused %d, failed %d,"
                       " skipped %d, %d not attempted; %s; nothing was saved"
                       " -- see `%s'")
               applied refused failed skipped untried
               (if modified
                   (format "modified %s"
                           (mapconcat #'buffer-name modified ", "))
                 "no buffer modified")
               org-agents--action-buffer))))

;;;###autoload
(defun org-agents-apply-actions (&optional explicit)
  "Apply the `:AGENT_ACTION:' of the agent at point to the entries it matched.
THE ONLY THING IN THIS PACKAGE THAT RUNS AN ACTION.  There is no hook, no
timer, no option and no save that does -- see the `Actions' section
comment for why that is structural rather than a promise.

What happens, in order:

  1. The action text is read from the agent entry's OWN drawer, with no
     inheritance of any kind.  None, and the command stops there.
  2. The text is parsed.  Every diagnostic fires here, before the query
     has run, so a typo does not even open the corpus.  Nothing in the
     text is ever evaluated.
  3. The match set is computed exactly as an update computes it: gated,
     prefiltered, with the agent itself and every generated alias
     excluded.  With a prefix argument the set is instead the entries the
     links in the REGION name, which is what makes a stamp fall out of
     this command -- the action text still comes from the agent.
  4. A plan over more than `org-agents-action-limit' entries is REFUSED,
     naming the count, the limit and the option.  Nothing is planned.
  5. Every verb is run in its `plan' phase at every match, which writes
     NOTHING -- and is caught if it does.
  6. The plan is shown in `*Org Agents Actions*', one line per intended
     edit, `FILE:LINE:' first so `next-error' walks them.  Nothing has
     been written at this point.
  7. You are asked once, about the whole plan.  In batch, or under
     `inhibit-interaction', the answer is a REFUSAL and not a yes.
  8. The edits are applied in order.  A destructive verb asks again at
     every entry, every run.  An error, a `no' or a `C-g' stops at that
     edit; its line says what happened and every later line says `not
     attempted'.
  9. The buffers that were modified are named.  NOTHING IS SAVED -- the
     worst case of a bad run is N modified buffers, reviewable and
     undoable one at a time, and not N modified files.

The vocabulary is the nine `org-agents-action/...' functions, and a
tenth is a `defun' in your init file: see README's \"Action code\"."
  (interactive "P")
  (let* ((marker (org-with-wide-buffer
                  (or (org-agents--agent-marker)
                      (user-error "org-agents: no agent at point"))))
         (text (org-with-point-at marker
                 (org-agents--entry-get "AGENT_ACTION"))))
    (unless text
      (user-error "org-agents: no :AGENT_ACTION: at point"))
    (let* ((verbs (org-agents--parse-actions text))
           (visited (org-agents--action-visited-files))
           (targets (org-agents--action-targets marker explicit)))
      (unless targets
        (user-error
         "org-agents: nothing matched, so there is nothing to apply"))
      (when (and org-agents-action-limit
                 (> (length targets) org-agents-action-limit))
        (user-error
         (concat "org-agents: %d entries matched and `org-agents-action-limit'"
                 " is %d, so nothing was planned; raise the option in init to"
                 " act on more -- a truncated plan would apply a subset you"
                 " could not predict")
         (length targets) org-agents-action-limit))
      (let* ((rows (org-agents--action-plan verbs targets))
             (counts (org-agents--action-counts rows visited)))
        (org-agents--action-report rows 'planned counts)
        (if (not (org-agents--action-confirm
                  "%s" (org-agents--action-prompt counts)))
            (progn
              (org-agents--action-report rows 'refused counts)
              (message "org-agents: nothing was applied"))
          (let ((buffers (org-agents--action-apply rows)))
            (org-agents--action-report rows 'applied counts)
            (org-agents--action-message rows buffers)))))))

(provide 'org-agents)
;;; org-agents.el ends here
