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
(require 'org)
(require 'org-ql)
(require 'org-ql-ext)
;; org-db-cli is required from Task 6 onward.

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
    (let ((ref (org-agents--ref-p form)))
      (if (cdr ref)                         ; inherited: residual accessor
          `(org-entry-get nil ,(car ref) t)
        `(property ,(car ref)))))
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

(defun org-agents--structurally-safe-p (form)
  "Non-nil if FORM consists solely of known predicates and combinators."
  (cond
   ((not (consp form)) t)                  ; literals as arguments
   ((memq (car form) org-agents--boolean-heads)
    (cl-every #'org-agents--structurally-safe-p (cdr form)))
   ((memq (car form) org-agents--nested-query-heads)
    (cl-every #'org-agents--structurally-safe-p (cdr form)))
   ((org-agents--known-predicate-p (car form)) t)
   (t nil)))

(defun org-agents--leftover-ref (form)
  "Return the first $ref symbol anywhere in FORM, or nil if there is none."
  (cond ((org-agents--ref-p form) form)
        ((consp form) (or (org-agents--leftover-ref (car form))
                          (org-agents--leftover-ref (cdr form))))))

(defun org-agents--check-cli-spelling (form)
  "Signal `user-error' if FORM uses a CLI-only predicate spelling."
  (when (consp form)
    (when-let* ((fix (alist-get (car form) org-agents--cli-only-heads)))
      (user-error "org-agents: `%s' is CLI-only syntax; use `%s'"
                  (car form) fix))
    (when (memq (car form)
                (append org-agents--boolean-heads
                        org-agents--nested-query-heads))
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

(provide 'org-agents)
;;; org-agents.el ends here
