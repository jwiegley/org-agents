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
;; there is exactly one evaluation engine and one answer.  The
;; PostgreSQL database maintained by `org db' serves only as an
;; optional candidate-file prefilter that makes whole-corpus agents
;; affordable.
;;
;; See docs/superpowers/specs/2026-08-18-org-agents-design.md for the
;; full design, including the agent-entry property vocabulary, the
;; evaluation gate, scope resolution, and the renderers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-ql)
(require 'org-ql-ext)
(require 'org-db-cli)

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

(defun org-agents--ref-p (form)
  "If FORM is a $ref symbol, return (NAME . INHERITP); else nil."
  (when (and (symbolp form)
             (string-prefix-p "$" (symbol-name form))
             (> (length (symbol-name form)) 1))
    (let* ((name (substring (symbol-name form) 1))
           (inherit (string-suffix-p "*" name)))
      (cons (if inherit (substring name 0 -1) name) inherit))))

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
interactively offers to persist its hash here."
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
  "Return the first $ref symbol anywhere in FORM, or nil if there is none."
  (cond ((org-agents--ref-p form) form)
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

(defun org-agents--date-arg-ok-p (plist)
  "Non-nil when PLIST holds only :from/:to/:on with CLI-safe values."
  (cl-loop for (k v) on plist by #'cddr
           always (and (memq k '(:from :to :on))
                       (or (integerp v) (eq v 'today)
                           (org-agents--date-string-p v)))))

(defun org-agents--push-planning (form)
  "Push planning FORM unchanged, provided its date arguments are CLI-safe."
  (and (org-agents--date-arg-ok-p (cdr form)) form))

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
   ;; both sides bound the raw stamp, so the bounds select alike.
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

(defconst org-agents--element-sorts '(date todo priority reverse)
  "The `:AGENT_SORT:' methods org-ql can sort matched elements by.
A table's `(column N)' or `(ts-column N)' sorts rendered rows of
strings instead, so the renderer -- not org-ql -- answers for those.")

(defun org-agents--element-sort (sort)
  "Return SORT if org-ql can sort elements by it, else nil.
One method or a list of them, since `reverse' is only meaningful
alongside another; a table's sort form is neither, and handing it to
org-ql would raise an error over a view that is not org-ql's business."
  (and sort (cl-subsetp (ensure-list sort) org-agents--element-sorts) sort))

(defun org-agents--entry-get (property)
  "Return PROPERTY of the entry at point, or nil when it has no value.
A property line written with nothing after it reads as the empty
string, which `read-from-string' cannot read at all and which
`expand-file-name' resolves to the whole of `org-directory'.  Written
but empty and not written at all mean the same thing here."
  (when-let* ((value (org-entry-get nil property)))
    (unless (string-blank-p value) value)))

(defun org-agents--read-sexp (property value)
  "Read VALUE, the `:PROPERTY:' of an agent entry, as a Lisp form.
A malformed value reaches `read-from-string' as an end of file, which
`org-agents-update-all' cannot tell from a bug in this package: it
answers for one agent at a time by catching `user-error', and anything
else aborts the whole run."
  (condition-case err (car (read-from-string value))
    (error (user-error "org-agents: unreadable :%s: `%s': %s"
                       property value (error-message-string err)))))

(defun org-agents--read-scope (value)
  "Read the `:AGENT_SCOPE:' property VALUE, which may be nil."
  (cond
   ((null value) 'agenda)
   ((string-prefix-p "(" value) (org-agents--read-sexp "AGENT_SCOPE" value))
   ;; Only the three corpus names are symbols.  Interning every bare
   ;; value would leave no way to write the directory scope the design
   ;; calls for, and no `stringp' scope could ever reach
   ;; `org-agents--scope-conjunct'.
   ((member value org-agents--scope-names) (intern value))
   (t value)))

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
    (let ((query (org-agents--read-sexp "AGENT_QUERY" q)))
      (list :query (org-agents--expand query)
            :view (intern (or (org-agents--entry-get "AGENT_VIEW") "children"))
            :scope (org-agents--read-scope (org-agents--entry-get "AGENT_SCOPE"))
            :sort (when-let* ((s (org-agents--entry-get "AGENT_SORT")))
                    (org-agents--read-sexp "AGENT_SORT" s))
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
    ((pred stringp) (directory-files-recursively
                     (expand-file-name scope org-directory) "\\.org\\'"))
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
  ;; Without a marker the self-skip cannot be made, and the agent
  ;; renders itself as one of its own matches.
  (unless (markerp (plist-get agent :marker))
    (user-error "org-agents: agent has no marker"))
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

(provide 'org-agents)
;;; org-agents.el ends here
