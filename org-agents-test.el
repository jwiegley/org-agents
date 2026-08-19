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

(ert-deftest org-agents-test-expand-passthrough ()
  (should (equal (org-agents--expand '(and (todo "TODO") (tags "urgent")))
                 '(and (todo "TODO") (tags "urgent")))))

(ert-deftest org-agents-test-gate-structural-safe-no-prompt ()
  (cl-letf (((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (error "must not prompt"))))
    (should (org-agents--gate '(and (todo "TODO") (property "URL"))))))

(ert-deftest org-agents-test-gate-refuses-bare-call ()
  "An unapproved arbitrary call is never evaluated, even inside (and ...)."
  (let ((org-agents--session-approved (make-hash-table :test 'equal))
        (org-agents-safe-queries nil)
        (noninteractive t))
    (should-not (org-agents--gate '(and (todo) (shell-command "touch /tmp/pwned"))))))

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

(ert-deftest org-agents-test-gate-rejects-cli-only-spelling ()
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

(ert-deftest org-agents-test-gate-cli-spelling-in-argument ()
  "A CLI-only spelling is caught in a predicate argument, but not in Lisp."
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

(ert-deftest org-agents-test-gate-allows-bare-special ()
  "A bare special expands to a read-only accessor, so it needs no approval."
  (let ((noninteractive t))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate (org-agents--expand '(and (todo) $TODO))))
      (should (org-agents--gate (org-agents--expand '$TAGS)))
      (should (org-agents--gate (org-agents--expand '$ITEM))))))

(ert-deftest org-agents-test-skeleton-property-exists ()
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--skeleton '(and (todo) (property "NEXT_REVIEW")))
                   "(property \"NEXT_REVIEW\")"))))

(ert-deftest org-agents-test-skeleton-property-ts-implies-exists ()
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--skeleton
                    '(and (todo) (property-ts "NEXT_REVIEW" :to today)))
                   "(property \"NEXT_REVIEW\")"))))

(ert-deftest org-agents-test-skeleton-rejects-invalid-date ()
  "An impossible date empties the candidate set instead of narrowing it."
  (should (null (org-agents--skeleton '(deadline :to "2026-02-30"))))
  (should (null (org-agents--skeleton '(deadline :to "2026-13-45"))))
  (should (equal (org-agents--skeleton '(deadline :to "2026-12-31"))
                 "(deadline :to \"2026-12-31\")"))
  ;; A leap day in a leap year is a real date.
  (should (equal (org-agents--skeleton '(deadline :to "2028-02-29"))
                 "(deadline :to \"2028-02-29\")")))

(ert-deftest org-agents-test-skeleton-multitoken-value-downgrades-to-existence ()
  "An accumulated value is one string to org-ql and several rows to the DB."
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--skeleton '(property "TAGS_TEXT" "a b"))
                   "(property \"TAGS_TEXT\")"))
    ;; A single token can still be compared whole.
    (should (equal (org-agents--skeleton '(property "TAGS_TEXT" "a"))
                   "(property \"TAGS_TEXT\" \"a\")"))))

(ert-deftest org-agents-test-skeleton-empty-for-residual-only ()
  (should (null (org-agents--skeleton '(todo))))
  (should (null (org-agents--skeleton '(tags "urgent"))))
  (should (null (org-agents--skeleton '(regexp "colou?r")))))

(ert-deftest org-agents-test-skeleton-heading-literal-only ()
  (should (equal (org-agents--skeleton '(and (heading "Review") (todo)))
                 "(heading \"Review\")"))
  (should (null (org-agents--skeleton '(heading "Rev.*iew")))))

(ert-deftest org-agents-test-skeleton-planning ()
  (should (equal (org-agents--skeleton '(and (scheduled :to 7) (tags "x")))
                 "(scheduled :to 7)"))
  (should (equal (org-agents--skeleton '(deadline :from today :to "2026-12-31"))
                 "(deadline :from today :to \"2026-12-31\")")))

(ert-deftest org-agents-test-skeleton-property-equality-respects-inheritance ()
  (let ((org-use-property-inheritance '("OVERLAY")))
    ;; A name that cannot inherit pushes as before.
    (should (equal (org-agents--skeleton '(property "STYLE" "habit"))
                   "(property \"STYLE\" \"habit\")"))
    (should (equal (org-agents--skeleton '(property "STYLE"))
                   "(property \"STYLE\")"))
    ;; An inheriting name pushes nothing, not even existence: the value
    ;; may come from a file-level #+PROPERTY: line or from
    ;; `org-global-properties', neither of which creates a property row
    ;; in any file, so the file would be dropped from the candidates.
    (should (null (org-agents--skeleton '(property "OVERLAY" "x"))))
    (should (null (org-agents--skeleton '(property "OVERLAY"))))
    (should (null (org-agents--skeleton '(property-ts "OVERLAY" :to today))))
    (let ((org-use-property-inheritance t))
      (should (null (org-agents--skeleton '(property "STYLE" "habit"))))
      (should (null (org-agents--skeleton '(property-ts "STYLE" :to today)))))))

(ert-deftest org-agents-test-skeleton-nested-queries-residual ()
  (should (null (org-agents--skeleton '(parent (property "X")))))
  (should (null (org-agents--skeleton '(descendants (todo))))))

(ert-deftest org-agents-test-skeleton-multiple-conjuncts-and-scope ()
  (should (equal (org-agents--skeleton
                  '(and (property "URL") (scheduled :to 7) (todo))
                  '(path "positron/"))
                 "(and (property \"URL\") (scheduled :to 7) (path \"positron/\"))")))

(ert-deftest org-agents-test-skeleton-no-ts-structs ()
  "Serialization must come from the pre-normalization sexp, and stay readable."
  (let ((s (org-agents--skeleton '(and (scheduled :to 7) (property "X")))))
    (should-not (string-match-p "#s(" s))
    (should-not (string-match-p "#(" s))))

(ert-deftest org-agents-test-skeleton-strips-text-properties ()
  "A literal lifted from a buffer carries properties the CLI cannot read."
  (let ((org-use-property-inheritance nil))
    (should (equal (org-agents--skeleton
                    `(and (heading ,(propertize "Review" 'face 'bold)) (todo)))
                   "(heading \"Review\")"))
    (should (equal (org-agents--skeleton
                    `(property "STYLE" ,(propertize "habit" 'face 'bold)))
                   "(property \"STYLE\" \"habit\")"))
    (should-not (string-match-p
                 "#("
                 (org-agents--skeleton
                  `(heading ,(propertize "Review" 'face 'bold)))))))

(ert-deftest org-agents-test-skeleton-special-properties-residual ()
  "A special property is entry structure, not a drawer row, so it never pushes."
  (should (null (org-agents--skeleton '(property "CATEGORY" "work"))))
  (should (null (org-agents--skeleton '(property "ITEM"))))
  (should (null (org-agents--skeleton '(property-ts "DEADLINE" :to today))))
  ;; An ordinary name in the same position still pushes.
  (should (equal (org-agents--skeleton '(property-ts "NEXT_REVIEW" :to today))
                 "(property \"NEXT_REVIEW\")")))

(ert-deftest org-agents-test-skeleton-resists-print-truncation ()
  "An abbreviated skeleton is a different query, and the CLI reads it as one."
  (let ((print-length 2)
        (print-level 2))
    (should (equal (org-agents--skeleton
                    '(and (property "A") (property "B") (property "C")))
                   "(and (property \"A\") (property \"B\") (property \"C\"))"))))

(provide 'org-agents-test)
;;; org-agents-test.el ends here
