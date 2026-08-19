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
  ;; An ordinary reference is unaffected, star and all.
  (should (equal '("URL" . nil) (org-agents--ref-p '$URL)))
  (should (equal '("URL" . t) (org-agents--ref-p '$URL*))))

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
  ;; A relative bound is pushed only while the local and UTC days coincide,
  ;; so these two assertions are made with that pinned rather than left to
  ;; the hour the suite happens to run at.
  (cl-letf (((symbol-function 'org-agents--relative-dates-agree-p)
             (lambda (&rest _) t)))
    (should (equal (org-agents--skeleton '(and (scheduled :to 7) (tags "x")))
                   "(scheduled :to 7)"))
    (should (equal (org-agents--skeleton '(deadline :from today :to "2026-12-31"))
                   "(deadline :from today :to \"2026-12-31\")")))
  ;; An absolute bound needs no such agreement.
  (should (equal (org-agents--skeleton '(scheduled :to "2026-12-31"))
                 "(scheduled :to \"2026-12-31\")")))

(ert-deftest org-agents-test-relative-dates-agree-p ()
  "The predicate answers whether the local and UTC days coincide.
Swept over a whole day of instants rather than asserted at one, because
the answer depends on the host's own zone: under UTC the two days always
coincide, and anywhere else there are hours where they do and hours where
they do not."
  ;; It is exactly the comparison it claims to be, at every hour.
  (let ((base (encode-time 0 0 0 19 8 2026 t))
        (agree 0)
        (differ 0))
    (dotimes (h 24)
      (let ((time (time-add base (* h 3600))))
        (should (eq (and (org-agents--relative-dates-agree-p time) t)
                    (equal (format-time-string "%F" time)
                           (format-time-string "%F" time t))))
        (if (org-agents--relative-dates-agree-p time)
            (cl-incf agree)
          (cl-incf differ))))
    (should (= 24 (+ agree differ)))
    (if (zerop (car (current-time-zone base)))
        ;; A UTC host: the days can never disagree, so nothing is ever
        ;; refused for this reason.
        (should (= 24 agree))
      ;; Any other zone: both outcomes occur within one day, which is why
      ;; the guard cannot be settled once at load time.
      (should (> agree 0))
      (should (> differ 0)))))

(ert-deftest org-agents-test-skeleton-relative-date-pushed-only-when-days-agree ()
  "A relative bound is pushed only while both engines mean the same day.
The database resolves `today' and an integer offset against the UTC day
and org-ql against the local one, so where those differ a pushed relative
bound selects by a different day than org-ql does -- and drops files
org-ql matches, which is an under-match in the one property the whole
push-down table exists to guarantee.  Pushing nothing instead leaves the
conjunct residual: the prefilter stops narrowing by date, which is slower
and never wrong."
  (let ((relative '((scheduled :to today) (scheduled :from today)
                    (scheduled :on today) (deadline :to 7) (deadline :from -7)
                    (closed :on today) (closed :to -1)
                    (scheduled :from today :to 7)))
        (absolute '((scheduled :to "2026-12-31") (deadline :on "2024-02-29")
                    (closed :from "2024-01-01" :to "2024-12-31"))))
    ;; Days agree: every relative form pushes, unchanged.
    (cl-letf (((symbol-function 'org-agents--relative-dates-agree-p)
               (lambda (&rest _) t)))
      (dolist (q relative)
        (should (equal (org-agents--skeleton q) (prin1-to-string q))))
      (dolist (q absolute)
        (should (equal (org-agents--skeleton q) (prin1-to-string q)))))
    ;; Days differ: every relative form pushes nothing at all ...
    (cl-letf (((symbol-function 'org-agents--relative-dates-agree-p) #'ignore))
      (dolist (q relative)
        (should (null (org-agents--skeleton q))))
      ;; ... while an absolute date is a calendar date to both sides and is
      ;; unaffected, so the push-down does not collapse wholesale.
      (dolist (q absolute)
        (should (equal (org-agents--skeleton q) (prin1-to-string q))))
      ;; A mixed plist is only as pushable as its weakest value.
      (should (null (org-agents--skeleton
                     '(deadline :from today :to "2026-12-31"))))
      ;; Another conjunct still pushes; only the date drops out.
      (should (equal (org-agents--skeleton
                      '(and (property "URL") (scheduled :to today) (todo)))
                     "(property \"URL\")"))
      ;; `property-ts' pushes existence only and discards its dates, so it
      ;; is not touched by the guard.
      (should (equal (org-agents--skeleton '(property-ts "NEXT_REVIEW" :to today))
                     "(property \"NEXT_REVIEW\")")))))

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
  (cl-letf (((symbol-function 'org-agents--relative-dates-agree-p)
             (lambda (&rest _) t)))
    (should (equal (org-agents--skeleton
                    '(and (property "URL") (scheduled :to 7) (todo))
                    '(path "positron/"))
                   "(and (property \"URL\") (scheduled :to 7) (path \"positron/\"))"))))

(ert-deftest org-agents-test-skeleton-no-ts-structs ()
  "Serialization must come from the pre-normalization sexp, and stay readable."
  (cl-letf (((symbol-function 'org-agents--relative-dates-agree-p)
             (lambda (&rest _) t)))
    (let ((s (org-agents--skeleton '(and (scheduled :to 7) (property "X")))))
      (should-not (string-match-p "#s(" s))
      (should-not (string-match-p "#(" s)))))

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

;;;; Collection

(defmacro org-agents-test--with-corpus (&rest body)
  "Run BODY with `dir' bound to a temp corpus of two org files and
`agent-file' bound to a file containing one agent entry.
`a' and `b' name the corpus files, whose absolute paths the agent
entry's `:AGENT_SCOPE:' lists.  `org-directory' is the corpus, so no
test can reach the developer's own; the database bridge is left
unconfigured and property inheritance off, so a test that wants either
must arrange it; the ID location table is a fresh one, so rendering a
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
  "The body of `org-agents-test--with-corpus'; call that instead."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "org-agents-corpus" t))
          (a (expand-file-name "a.org" dir))
          (b (expand-file-name "b.org" dir))
          (agent-file (expand-file-name "agents.org" dir))
          (org-directory dir)
          (org-db-cli-config-file nil)
          (org-db-cli-db-url nil)
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
  "Which scopes may only be resolved through the database.
`agenda' and an explicit file list name their files and are read live;
the corpus names and any directory promise nothing about how much they
hold.  The absolute-directory row is the one worth pinning: such a scope
needs the prefilter and pushes no `path' conjunct to earn one with, so
the two answers have to be read together."
  (dolist (scope '(active all "sub" "sub/" "a/b" "/Users/johnw/org/sub"
                   "~/org/sub"))
    (should (org-agents--needs-prefilter-p scope)))
  (dolist (scope '(agenda ("a.org") ("a.org" "b.org") nil))
    (should-not (org-agents--needs-prefilter-p scope)))
  ;; An absolute directory needs the prefilter and pushes nothing.
  (should (org-agents--needs-prefilter-p "/Users/johnw/org/sub"))
  (should (null (org-agents--scope-conjunct "/Users/johnw/org/sub")))
  ;; A relative one needs it too, and does push a conjunct.
  (should (equal '(path "sub/") (org-agents--scope-conjunct "sub"))))

(ert-deftest org-agents-test-scope-conjunct ()
  "Only a directory scope earns a path conjunct, and it travels as plain text."
  (should (equal (org-agents--scope-conjunct "positron") '(path "positron/")))
  (should (equal (org-agents--scope-conjunct "positron/") '(path "positron/")))
  (should (null (org-agents--scope-conjunct 'active)))
  (should (null (org-agents--scope-conjunct '("a.org"))))
  ;; The conjunct is a prefix relative to the corpus root, which an
  ;; absolute directory is not, so it pushes nothing rather than asking
  ;; the database a question in terms it does not share.
  (should (null (org-agents--scope-conjunct "/Users/johnw/elsewhere")))
  (let ((conjunct (org-agents--scope-conjunct (propertize "positron" 'face 'bold))))
    (should (equal conjunct '(path "positron/")))
    (should (null (text-properties-at 0 (cadr conjunct))))))

(ert-deftest org-agents-test-scope-files-intersects-by-truename ()
  "The database canonicalizes; `org-directory' is commonly a symlink.
Compared with `equal' the two spellings have nothing in common, and the
agent would silently match nothing at all."
  (org-agents-test--with-corpus
    (let ((link (expand-file-name "link-a.org" dir)))
      (make-symbolic-link "a.org" link)
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
          (cl-letf (((symbol-function 'org-db-cli-available-p) (lambda () t))
                    ((symbol-function 'org-db-cli-query-files) (lambda (_) (list a)))
                    ((symbol-function 'org-agents--scope-base-files)
                     (lambda (_scope) (list link b))))
            ;; The base spelling is what is returned: it is the name the
            ;; user reads and the link that will be followed.
            (should (equal (list link) (org-agents--scope-files agent)))))))))

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

(ert-deftest org-agents-test-collect-skips-the-agent-itself ()
  "An agent that matches its own query does not render itself."
  (org-agents-test--in-agent
    (goto-char (point-max))
    (let ((agent (org-agents--read-agent)))
      (setq agent (plist-put agent :scope (list agent-file)))
      (setq agent (plist-put agent :query '(property "AGENT_QUERY")))
      (should (null (org-agents--collect agent))))))

(ert-deftest org-agents-test-collect-corpus-scope-needs-prefilter ()
  "And it says so before walking the corpus it is refusing to read."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
      (cl-letf (((symbol-function 'org-db-cli-available-p) #'ignore)
                ((symbol-function 'org-agents--scope-base-files)
                 (lambda (_scope) (error "must not walk the corpus"))))
        (should-error (org-agents--collect agent) :type 'user-error)))))

(ert-deftest org-agents-test-collect-directory-scope-needs-prefilter ()
  "A directory needs the prefilter as much as `all' does.
Nothing about naming a directory bounds it below corpus size, and the
recursive walk it would otherwise take is what the prefilter is for."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :scope "sub")))
      (cl-letf (((symbol-function 'org-db-cli-available-p) #'ignore)
                ((symbol-function 'org-agents--scope-base-files)
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

(ert-deftest org-agents-test-collect-corpus-scope-needs-a-skeleton ()
  "A query with nothing to push must not open the whole corpus either."
  (org-agents-test--in-agent
    (let ((agent (plist-put (org-agents--read-agent) :scope 'all)))
      (setq agent (plist-put agent :query '(todo)))
      (cl-letf (((symbol-function 'org-db-cli-available-p) (lambda () t))
                ((symbol-function 'org-db-cli-query-files)
                 (lambda (_) (error "must not be called without a skeleton"))))
        (should-error (org-agents--collect agent) :type 'user-error)))))

(ert-deftest org-agents-test-collect-prefilter-intersects ()
  "A corpus scope narrows to the candidate files, and only those are read."
  (org-agents-test--with-corpus
    (let ((link (expand-file-name "link-a.org" dir))
          (queried nil))
      (make-symbolic-link "a.org" link)
      (with-current-buffer (find-file-noselect agent-file)
        (goto-char (point-min))
        (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
          (cl-letf (((symbol-function 'org-db-cli-available-p) (lambda () t))
                    ((symbol-function 'org-db-cli-query-files)
                     (lambda (skel) (setq queried skel) (list a)))
                    ((symbol-function 'org-agents--scope-base-files)
                     (lambda (_scope) (list link b))))
            (let ((matches (org-agents--collect agent)))
              (should (string-match-p "NEXT_REVIEW" queried))
              (should (= 1 (length matches)))
              (should (equal "Fix widget"
                             (org-element-property :raw-value (car matches)))))))))))

(ert-deftest org-agents-test-collect-empty-prefilter-selects-nothing ()
  "A prefilter that rules out every file selects nothing.
Handed no files at all, `org-ql-select' searches the current buffer,
which for an agent is the file the agent itself lives in."
  (org-agents-test--with-corpus
    (with-temp-buffer
      (insert "* TODO Decoy beside the agent\n")
      (append-to-file (point-min) (point-max) agent-file))
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (plist-put (org-agents--read-agent)
                              :query '(heading "Decoy"))))
        (cl-letf (((symbol-function 'org-db-cli-available-p) (lambda () t))
                  ((symbol-function 'org-db-cli-query-files)
                   (lambda (_) (list (expand-file-name "elsewhere.org" dir)))))
          (should (null (org-agents--scope-files agent)))
          (should (null (org-agents--collect agent))))))))

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
  "org-ql sorts elements; a table view sorts rendered rows of strings."
  (should (eq 'date (org-agents--element-sort 'date)))
  ;; `reverse' means nothing on its own, so a list of methods passes too.
  (should (equal '(date reverse) (org-agents--element-sort '(date reverse))))
  (should (null (org-agents--element-sort nil)))
  (should (null (org-agents--element-sort '(ts-column 2))))
  (should (null (org-agents--element-sort '(column 2))))
  (should (null (org-agents--element-sort 'bogus))))

(ert-deftest org-agents-test-collect-passes-only-element-sorters ()
  "A sort org-ql does not know would raise an error out of `org-ql-select'."
  (org-agents-test--in-agent
    (let ((agent (org-agents--read-agent)))
      (should (= 1 (length (org-agents--collect (plist-put agent :sort 'date)))))
      (should (= 1 (length (org-agents--collect
                            (plist-put agent :sort '(date reverse))))))
      (should (= 1 (length (org-agents--collect
                            (plist-put agent :sort '(ts-column 2))))))
      (should (= 1 (length (org-agents--collect
                            (plist-put agent :sort 'bogus))))))))

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
      (should (string-suffix-p "]]  [2020-01-01 Wed]"
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
    (should (string-match-p "^- \\[\\[id:11111111-.*Fix widget\\]\\]  \\[2020-01-01 Wed\\]"
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
    (cl-letf (((symbol-function 'org-agenda-files) (lambda (&rest _) '("a.org")))
              ((symbol-function 'org-ql-search)
               (lambda (fs query &rest _) (setq files fs received query))))
      (org-agents-preview "(todo)")
      (should (equal received `(and (todo) ,org-agents-exclude)))
      (should (equal files '("a.org")))
      ;; The `$PROP' layer is expanded exactly as an agent's query is.
      (org-agents-preview "(and (todo) $URL)")
      (should (equal received
                     `(and (and (todo) (property "URL")) ,org-agents-exclude)))
      ;; And with the exclusion off, the query alone: nil conjoined here
      ;; would be a clause that never matches.
      (let ((org-agents-exclude nil))
        (org-agents-preview "(todo)")
        (should (equal received '(todo)))))))

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
  "A preview is gated like an agent, and evaluates nothing it refuses."
  (cl-letf (((symbol-function 'org-ql-search)
             (lambda (&rest _) (error "must not be reached"))))
    (should-error (org-agents-preview "(and (todo") :type 'user-error)
    (should-error (org-agents-preview "(headline \"x\")") :type 'user-error)
    (let ((org-agents--session-approved (make-hash-table :test 'equal))
          (org-agents-safe-queries nil)
          (noninteractive t))
      (should-error (org-agents-preview "(and (todo) (shell-command \"x\"))")
                    :type 'user-error))))

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

;;;; Differential (database prefilter superset)

;; This section proves the one property the splitter must have: for every
;; row of `org-agents--pushdown-fns', the candidate FILE set the `org db
;; query' prefilter answers with is a SUPERSET of the files org-ql
;; actually matches.  A conjunct that is not a superset would drop a true
;; match, which no unit test over the skeleton string can detect: only
;; running both engines over one corpus can.
;;
;; It therefore needs a real PostgreSQL database and the real Haskell CLI,
;; and is gated on four variables.  Absent, the whole section skips
;; silently; present but unusable, it fails loudly, because a mis-set DSN
;; that quietly disabled the suite would be worse than a red test.
;;
;;   ORG_AGENTS_TEST_DB_URL   DSN of a SCRATCH database, which this suite
;;                            drops and recreates every run.  Its name
;;                            must contain "org_agents_test", so a DSN
;;                            naming the user's real corpus cannot be
;;                            handed to `db unstore' by accident.
;;   ORG_AGENTS_TEST_CONFIG   org-jw YAML config, e.g. ~/org/org.yaml
;;   ORG_AGENTS_TEST_KEYWORDS keywords DOT file, e.g. ~/org/org.dot.
;;                            REQUIRED: the YAML declares empty keyword
;;                            lists, so without it every entry stores
;;                            with keyword_value NULL and "TODO" glued
;;                            onto the front of its title.
;;   ORG_AGENTS_TEST_ORG_EXE  the cabal-built `org' carrying the `file'
;;                            field of this project's first task.  The
;;                            `org' on PATH does NOT have it, and without
;;                            the field every candidate set comes back
;;                            empty -- which looks exactly like a sound
;;                            but narrow prefilter, and would let a real
;;                            regression pass unremarked.
;;                            ORG_AGENTS_TEST_ORG_BIN is read as well, so
;;                            that either spelling works.
;;
;; One-time operator setup:
;;   createdb org_agents_test
;;   psql -d org_agents_test -c 'CREATE EXTENSION IF NOT EXISTS ltree;
;;                               CREATE EXTENSION IF NOT EXISTS vector'
;; (`db init' creates both best-effort, but they need a superuser.)  Then
;; build the CLI and run:
;;   export ORG_AGENTS_TEST_DB_URL=postgresql:///org_agents_test
;;   export ORG_AGENTS_TEST_CONFIG=$HOME/org/org.yaml
;;   export ORG_AGENTS_TEST_KEYWORDS=$HOME/org/org.dot
;;   export ORG_AGENTS_TEST_ORG_EXE=.../x/org/build/org/org
;;   "$EMACS" -batch -L . -L ~/.emacs.d/lisp -l org-agents-test.el \
;;     --eval '(ert-run-tests-batch-and-exit "org-agents-test-diff")'

(defconst org-agents-test--db-env
  '("ORG_AGENTS_TEST_DB_URL" "ORG_AGENTS_TEST_CONFIG"
    "ORG_AGENTS_TEST_KEYWORDS")
  "The variables the differential suite needs besides the binary.")

(defun org-agents-test--db-env ()
  "Return the differential environment as a plist, or nil if incomplete.
The binary is read from either spelling of its variable, so that both
names this project has used for it work."
  (let ((vals (mapcar #'getenv org-agents-test--db-env))
        (bin (or (getenv "ORG_AGENTS_TEST_ORG_EXE")
                 (getenv "ORG_AGENTS_TEST_ORG_BIN"))))
    (when (cl-every (lambda (v) (and v (not (string-empty-p v))))
                    (append vals (list bin)))
      (list :dsn (nth 0 vals) :config (nth 1 vals)
            :keywords (nth 2 vals) :bin bin))))

(defconst org-agents-test--diff-corpus
  ;; (RELATIVE-NAME . CONTENTS) -- one hazard per file, so that a per-file
  ;; superset assertion can say which hazard broke.  A single-file corpus
  ;; could not: its candidate set is the whole corpus or nothing, and the
  ;; superset relation would hold without distinguishing a prefilter that
  ;; narrows from one that does nothing at all.
  '(("prop.org" . "\
* TODO Review the widget
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:STYLE:      habit
:END:
")
    ;; The only NEXT_REVIEW here is on a DONE entry, so org-ql's residual
    ;; `(todo)' rejects it while the pushed `(property ...)' keeps the
    ;; file: a superset is allowed to be wider, and this is the proof that
    ;; the residual really is applied on the Emacs side.
    ("prop-done.org" . "\
* DONE Retired widget
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:END:
")
    ;; A leap day, a repeater on the same day, a deadline and a closing
    ;; stamp: one file for the three planning rows.
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
    ;; A keyword, a priority cookie and tags: org-ql matches over the
    ;; cleaned title \"[#A] Review widget spec\", the database ILIKEs the
    ;; raw headline \"TODO [#A] Review widget spec :work:urgent:\".  The
    ;; second heading carries the LIKE metacharacters `%' and `_', which
    ;; the CLI must escape and which are not regexp metacharacters, so
    ;; `org-agents--literal-strings-p' allows them through.
    ("head.org" . "\
* TODO [#A] Review widget spec :work:urgent:
* Review 50%_done
")
    ;; Regexp metacharacters, which the splitter refuses to push.
    ("head-regexp.org" . "\
* Rev.*iew of plans
")
    ;; `#+FILETAGS:' only: org-ql inherits the tag onto both entries,
    ;; while the store writes no entry_tags row at all.
    ("filetags.org" . "\
#+FILETAGS: :ftag:

* Tagged by the file
* Also tagged by the file
")
    ;; A property whose only source is a `#+PROPERTY:' line.  A canary:
    ;; BOTH sides must answer \"no match\".  The `property' row IS pushed,
    ;; so if org-ql ever begins answering `(property N)' out of file-level
    ;; properties, the push-down becomes unsound the same day.
    ("fileprop.org" . "\
#+PROPERTY: FILEPROP fromfile

* Sees FILEPROP only by inheritance
")
    ;; An ancestor's CATEGORY: org-ql matches parent AND child, the store
    ;; records the category against the parent only.
    ("anccat.org" . "\
* Parent with category
:PROPERTIES:
:CATEGORY: AncCat
:END:
** Child inherits the category
")
    ;; An active timestamp in the body text: org-ql's `ts' sees it,
    ;; entry_stamps holds nothing for this entry.
    ("bodyts.org" . "\
* Mentions a date in prose
Some prose mentioning <2024-02-29 Thu> inline.
")
    ;; `:TOKENS+:' accumulation: `org-entry-get' joins the two lines into
    ;; \"alpha beta\", while the Haskell parser cannot read a `+' in a
    ;; property name and degrades the WHOLE drawer to a body block -- so
    ;; entry_properties gets no row, not even for the ordinary `:TOKENS:'
    ;; line above it.
    ("accum.org" . "\
* TODO Accumulated tokens
:PROPERTIES:
:TOKENS: alpha
:TOKENS+: beta
:END:
")
    ;; Under a subdirectory, for the `(path \"sub/\")' scope conjunct.
    ("sub/scoped.org" . "\
* TODO Scoped review
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:END:
")
    ;; A non-ASCII heading, which travels into the skeleton raw and
    ;; reaches the CLI through `call-process': the coding system is
    ;; answered with evidence rather than with a claim.
    ("nonascii.org" . "\
* TODO Révisér le café
:PROPERTIES:
:NEXT_REVIEW: [2024-01-15 Mon]
:END:
")
    ;; Matches nothing, so the prefilter can be shown to narrow at all.
    ("filler.org" . "\
* Nothing to see here
"))
  "Fixture files for the differential suite: relative name . contents.")

(defun org-agents-test--org-cli (env &rest args)
  "Run the differential `org' binary with ARGS; return (CODE . OUTPUT).
Stdout and stderr come back together, because the CLI writes its PARSE
ERROR lines to stdout and libpq's diagnostics to stderr, and the harness
has to see both."
  (with-temp-buffer
    (let* ((default-directory temporary-file-directory)
           (code (apply #'call-process (plist-get env :bin) nil t nil
                        "--config"   (expand-file-name (plist-get env :config))
                        "--keywords" (expand-file-name (plist-get env :keywords))
                        args)))
      (cons code (buffer-string)))))

(defun org-agents-test--db-preflight (env)
  "Fail the test when ENV is set but unusable.
The DSN check is the one that matters: every run of this section drops
every data table in the database it is pointed at, so a DSN that is not
obviously a scratch database is refused rather than emptied.

The binary check reads the symbol table.  GHC Z-encodes a module name, so
the symbol to look for is `OrgziDBziRender' and not `Org.DB.Render' --
measured on this host as 33 occurrences in the cabal-built binary and 0
in the one on PATH.  Where `nm' cannot be run at all the check is
skipped: the store's own self-check in `org-agents-test--with-db-corpus'
is the authoritative one, since it exercises the `file' field instead of
guessing at it from a symbol name."
  (unless (string-match-p "org_agents_test" (plist-get env :dsn))
    (ert-fail (format "refusing DSN %S: this suite drops every data table \
in it, so the scratch database's name must contain \"org_agents_test\""
                      (plist-get env :dsn))))
  (unless (file-executable-p (plist-get env :bin))
    (ert-fail (format "%s is not executable" (plist-get env :bin))))
  (dolist (file (list (plist-get env :config) (plist-get env :keywords)))
    (unless (file-readable-p (expand-file-name file))
      (ert-fail (format "%s is not readable" file))))
  (with-temp-buffer
    (when (eq 0 (ignore-errors
                  (call-process "nm" nil t nil "-a" (plist-get env :bin))))
      (goto-char (point-min))
      (unless (re-search-forward "OrgziDBziRender" nil t)
        (ert-fail
         (format "%s predates the `file' JSON field (no OrgziDBziRender \
symbol); rebuild with `cabal build org-jw'" (plist-get env :bin)))))))

(defun org-agents-test--db-files (skeleton)
  "Candidate file truenames for SKELETON, through the real CLI."
  (mapcar #'file-truename (org-db-cli-query-files skeleton)))

(defun org-agents-test--live-files (query paths)
  "Truenames of the files org-ql actually matches for QUERY over PATHS.
`delq' first: a match carrying no marker answers nil, and a nil among the
file names would fail a later comparison over a nil rather than a file."
  (delete-dups
   (mapcar #'file-truename
           (delq nil (org-ql-select paths query :action '(buffer-file-name))))))

(defun org-agents-test--all-paths (files)
  "Every fixture path in FILES, as `org-agents-test--with-db-corpus' binds it."
  (mapcar #'cdr files))

(defun org-agents-test--should-be-superset (query skeleton paths)
  "Assert SKELETON's candidate set covers every file org-ql matches for QUERY.
Never `equal': the contract is a superset, and two of the fixtures below
depend on the prefilter being legitimately wider than org-ql.  Both sides
are asserted non-empty, so a fixture that quietly stopped matching cannot
make the relation hold for want of anything to relate."
  (let ((live (org-agents-test--live-files query paths))
        (cands (org-agents-test--db-files skeleton)))
    (should live)
    (should cands)
    (dolist (f live)
      (should (member f cands)))))

(defmacro org-agents-test--with-db-corpus (&rest body)
  "Store the differential fixture corpus into the scratch DB and run BODY.
Binds `env' (the plist `org-agents-test--db-env' answers with), `dir'
(the corpus root) and `files' (an alist of relative name . absolute
TRUENAME).  Truenames, because `files.path' in the database is
`canonicalizePath'-ed: on macOS a corpus under /var/folders/... is stored
as /private/var/folders/..., and `equal' on those two spellings of one
file is nil.  The production code compares by truename for the same
reason, and a test must not be laxer than what it tests.

The environment is checked before anything is created, so a skipped run
leaves no temporary directory behind."
  (declare (indent 0))
  `(let ((env (org-agents-test--db-env)))
     (skip-unless env)
     (org-agents-test--db-preflight env)
     (let* ((dir (make-temp-file "org-agents-diff" t))
            (org-directory dir)
            (org-db-cli-executable (plist-get env :bin))
            (org-db-cli-config-file (plist-get env :config))
            (org-db-cli-db-url (plist-get env :dsn))
            (org-db-cli-files-directory dir)
            (org-use-property-inheritance nil)
            (org-element-use-cache nil)
            ;; The fixtures carry no `:ID:' and nothing here renders, but
            ;; the bindings cost nothing and keep a future test in this
            ;; section from writing a temporary corpus into the
            ;; developer's own `org-id-locations-file'.
            (org-id-track-globally nil)
            (org-id-locations (make-hash-table :test #'equal))
            (org-id-files nil)
            (org-id-locations-file (expand-file-name ".org-id-locations" dir))
            files)
       (unwind-protect
           (progn
             ;; 1. Materialise the corpus, subdirectories included.
             (dolist (spec org-agents-test--diff-corpus)
               (let ((path (expand-file-name (car spec) dir)))
                 (make-directory (file-name-directory path) t)
                 (with-temp-file path (insert (cdr spec)))
                 (push (cons (car spec) (file-truename path)) files)))
             ;; 2. The one fixture whose content depends on the clock.
             (let ((path (expand-file-name "today.org" dir)))
               (with-temp-file path
                 (insert (format "* TODO Due today\nSCHEDULED: <%s>\n"
                                 (format-time-string "%Y-%m-%d %a"))))
               (push (cons "today.org" (file-truename path)) files))
             (setq files (nreverse files))
             ;; 3. Reset the scratch database.  `unstore' is DROP TABLE IF
             ;;    EXISTS ... CASCADE throughout, so it is safe on a
             ;;    virgin database and leaves a crashed run's leftovers
             ;;    behind either way; `init' must follow it, because `db
             ;;    store' calls `requireEmbeddingDimensions' and fails
             ;;    without the row `init' writes.  The dimension count is
             ;;    arbitrary: `--no-embed' means no vector is ever stored.
             (dolist (cmd '(("db" "--db-url" :dsn "unstore")
                            ("db" "--db-url" :dsn "init" "--dimensions" "1536")))
               (let* ((args (mapcar (lambda (a)
                                      (if (keywordp a) (plist-get env a) a))
                                    cmd))
                      (res (apply #'org-agents-test--org-cli env args)))
                 (unless (eq 0 (car res))
                   ;; The substituted arguments, not the template: this is
                   ;; the message someone whose scratch database is not
                   ;; reachable has to work from.
                   (ert-fail (format "`org %s' exited %s: %s"
                                     (string-join args " ")
                                     (car res) (cdr res))))))
             ;; 4. Store every fixture in one invocation -- the files are
             ;;    the CLI's global positional arguments, `db store' has
             ;;    none of its own -- and then assert the store took them
             ;;    all.  A file the Haskell parser rejects is dropped with
             ;;    a PARSE ERROR line on stdout and the run still exits 0,
             ;;    which would make a later superset failure look like a
             ;;    splitter bug rather than a missing file.
             (let* ((paths (mapcar #'cdr files))
                    (res (apply #'org-agents-test--org-cli env
                                (append (list "db" "--db-url" (plist-get env :dsn)
                                              "store" "--no-embed")
                                        paths))))
               (unless (eq 0 (car res))
                 (ert-fail (format "db store exited %s: %s" (car res) (cdr res))))
               (should-not (string-match-p "PARSE ERROR" (cdr res)))
               (should-not (string-match-p "^Error: " (cdr res)))
               ;; Quoted, because the CLI's own message contains `(' and
               ;; `)' and would otherwise be read as a group matching
               ;; "files" rather than the literal "file(s)".
               (should (string-match-p
                        (regexp-quote (format "Stored: %d file(s) processed"
                                              (length paths)))
                        (cdr res))))
             ;; 5. The store worked, so a skeleton every corpus answers
             ;;    must come back with files.  This, not the symbol-table
             ;;    check, is what proves the binary carries the `file'
             ;;    field: without it `org-db-cli-query-files' finds no
             ;;    file key, answers nil, and every superset assertion
             ;;    below would hold vacuously.
             (unless (org-agents-test--db-files "(property \"NEXT_REVIEW\")")
               (ert-fail "the CLI answered no files for a skeleton three \
fixtures match: either the binary predates the `file' JSON field, or the \
store did not reach this database"))
             ,@body)
         (dolist (buf (buffer-list))
           (when-let* ((f (buffer-file-name buf)))
             (when (string-prefix-p (file-name-as-directory dir) f)
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf))))
         (delete-directory dir t)))))

;;; Positive rows: one test per row of `org-agents--pushdown-fns'.

(ert-deftest org-agents-test-diff-property-existence ()
  "Row `property', existence form."
  (org-agents-test--with-db-corpus
    (let ((q '(and (todo) (property "NEXT_REVIEW"))))
      (should (equal (org-agents--skeleton q) "(property \"NEXT_REVIEW\")"))
      (org-agents-test--should-be-superset
       q "(property \"NEXT_REVIEW\")" (org-agents-test--all-paths files))
      (let ((cands (org-agents-test--db-files "(property \"NEXT_REVIEW\")")))
        ;; The prefilter narrows, rather than merely being correct.
        (should-not (member (cdr (assoc "filler.org" files)) cands))
        ;; And is allowed to be wider: org-ql's residual `(todo)' rejects
        ;; the DONE entry, while the pushed conjunct keeps its file.
        (should (member (cdr (assoc "prop-done.org" files)) cands))))))

(ert-deftest org-agents-test-diff-property-equality ()
  "Row `property', single-token equality form."
  (org-agents-test--with-db-corpus
    (let ((q '(and (property "STYLE" "habit") (todo))))
      (should (equal (org-agents--skeleton q) "(property \"STYLE\" \"habit\")"))
      (org-agents-test--should-be-superset
       q "(property \"STYLE\" \"habit\")" (org-agents-test--all-paths files))
      ;; A value the corpus does not hold narrows to nothing at all.
      (should (null (org-agents-test--db-files
                     "(property \"STYLE\" \"nosuchvalue\")"))))))

(ert-deftest org-agents-test-diff-property-ts-existence ()
  "Row `property-ts' pushes the existence of the property and no more.
The database has no reading of a timestamp inside a property value, so
the date bounds stay residual and org-ql alone applies them."
  (org-agents-test--with-db-corpus
    (let ((q '(and (todo) (property-ts "NEXT_REVIEW" :to "2030-01-01"))))
      (should (equal (org-agents--skeleton q) "(property \"NEXT_REVIEW\")"))
      (org-agents-test--should-be-superset
       q "(property \"NEXT_REVIEW\")" (org-agents-test--all-paths files)))))

(ert-deftest org-agents-test-diff-scheduled-leap-day ()
  "Row `scheduled', with an absolute date that only exists in a leap year."
  (org-agents-test--with-db-corpus
    (let ((q '(and (scheduled :on "2024-02-29") (todo))))
      (should (equal (org-agents--skeleton q) "(scheduled :on \"2024-02-29\")"))
      (org-agents-test--should-be-superset
       q "(scheduled :on \"2024-02-29\")" (org-agents-test--all-paths files))
      ;; A repeater's base date is what both sides bound, so the file is
      ;; kept for the plain entry and the repeating one alike.
      (should (member (cdr (assoc "plan.org" files))
                      (org-agents-test--db-files
                       "(scheduled :on \"2024-02-29\")"))))))

(ert-deftest org-agents-test-diff-deadline-range ()
  "Row `deadline', with both bounds."
  (org-agents-test--with-db-corpus
    (let ((q '(and (deadline :from "2024-01-01" :to "2024-12-31") (todo))))
      (should (equal (org-agents--skeleton q)
                     "(deadline :from \"2024-01-01\" :to \"2024-12-31\")"))
      (org-agents-test--should-be-superset
       q "(deadline :from \"2024-01-01\" :to \"2024-12-31\")"
       (org-agents-test--all-paths files))
      ;; A range the corpus has no deadline in narrows to nothing.
      (should (null (org-agents-test--db-files
                     "(deadline :from \"1990-01-01\" :to \"1990-12-31\")"))))))

(ert-deftest org-agents-test-diff-closed ()
  "Row `closed'."
  (org-agents-test--with-db-corpus
    (let ((q '(closed :on "2024-03-01")))
      (should (equal (org-agents--skeleton q) "(closed :on \"2024-03-01\")"))
      (org-agents-test--should-be-superset
       q "(closed :on \"2024-03-01\")" (org-agents-test--all-paths files)))))

(ert-deftest org-agents-test-diff-heading-literal ()
  "Row `heading': org-ql's AND over the cleaned title, the CLI's OR over
the raw headline.  Cleaned is a substring of raw and AND implies OR, so
the database's answer is a superset twice over."
  (org-agents-test--with-db-corpus
    (let ((q '(and (heading "Review") (todo))))
      (should (equal (org-agents--skeleton q) "(heading \"Review\")"))
      (org-agents-test--should-be-superset
       q "(heading \"Review\")" (org-agents-test--all-paths files)))
    ;; Two literals: org-ql requires both of the cleaned title, the CLI
    ;; either of the raw headline.
    (let ((q '(heading "widget" "spec")))
      (should (equal (org-agents--skeleton q) "(heading \"widget\" \"spec\")"))
      (org-agents-test--should-be-superset
       q "(heading \"widget\" \"spec\")" (org-agents-test--all-paths files)))
    ;; The keyword and the tags live in the raw headline and not in
    ;; org-ql's heading, so here the CLI over-matches -- the safe
    ;; direction, and the reason this row may be pushed at all.
    (should (member (cdr (assoc "head.org" files))
                    (org-agents-test--db-files "(heading \"urgent\")")))
    (should (null (org-agents-test--live-files
                   '(heading "urgent") (org-agents-test--all-paths files))))))

(ert-deftest org-agents-test-diff-heading-like-metacharacters ()
  "`%' and `_' are LIKE metacharacters, and the CLI must escape them.
Neither is a regexp metacharacter, so `org-agents--literal-strings-p'
deliberately lets them through to be pushed."
  (org-agents-test--with-db-corpus
    (let ((q '(heading "50%_done")))
      (should (equal (org-agents--skeleton q) "(heading \"50%_done\")"))
      (org-agents-test--should-be-superset
       q "(heading \"50%_done\")" (org-agents-test--all-paths files))
      ;; Unescaped, `%' and `_' would match every heading in the corpus;
      ;; escaped, only the one that spells them out.
      (should (equal (org-agents-test--db-files "(heading \"50%_done\")")
                     (list (cdr (assoc "head.org" files))))))))

(ert-deftest org-agents-test-diff-heading-non-ascii ()
  "A non-ASCII literal survives the trip out through `call-process'.
The heading goes into the skeleton raw and reaches the CLI as process
arguments, so the coding system is answered here with evidence."
  (org-agents-test--with-db-corpus
    (let ((q '(and (heading "Révisér") (todo))))
      (should (equal (org-agents--skeleton q) "(heading \"Révisér\")"))
      (org-agents-test--should-be-superset
       q "(heading \"Révisér\")" (org-agents-test--all-paths files))
      (should (equal (org-agents-test--db-files "(heading \"café\")")
                     (list (cdr (assoc "nonascii.org" files))))))))

(ert-deftest org-agents-test-diff-scope-conjunct ()
  "The scope conjunct narrows to a subdirectory, and stays a superset."
  (org-agents-test--with-db-corpus
    (let* ((q '(and (property "NEXT_REVIEW") (todo)))
           (skel (org-agents--skeleton q (org-agents--scope-conjunct "sub"))))
      (should (equal skel "(and (property \"NEXT_REVIEW\") (path \"sub/\"))"))
      (let ((cands (org-agents-test--db-files skel)))
        (should (member (cdr (assoc "sub/scoped.org" files)) cands))
        (should-not (member (cdr (assoc "prop.org" files)) cands))
        ;; Every file it kept really is under the subdirectory.
        (dolist (f cands)
          (should (string-match-p "/sub/" f)))))))

;;; Negative rows: the guards, and the divergence each one answers to.
;;
;; Two layers.  The first is pure -- `org-agents--skeleton' must not push
;; the conjunct -- and is what a unit test can say.  The second is the
;; differential half that makes the first load-bearing: it runs the naive
;; skeleton the guard suppressed and shows the file it would have dropped.
;; Without that half these tests would pass even where the database
;; happened to agree, and the guard's justification would rot unnoticed.

(ert-deftest org-agents-test-diff-guard-tags-not-pushed ()
  "`#+FILETAGS:' is inherited by org-ql and invisible to the store."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(tags "ftag"))))
    (let ((live (org-agents-test--live-files
                 '(tags "ftag") (org-agents-test--all-paths files))))
      (should (member (cdr (assoc "filetags.org" files)) live))
      ;; What a `tags' push would have answered: nothing, dropping a file
      ;; org-ql matches twice over.
      (should (null (org-agents-test--db-files "(tags \"ftag\")"))))))

(ert-deftest org-agents-test-diff-guard-category-not-pushed ()
  "An ancestor's `:CATEGORY:' reaches the child in org-ql, not in the store."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(category "AncCat"))))
    (let ((live (org-agents-test--live-files
                 '(category "AncCat") (org-agents-test--all-paths files)))
          (cands (org-agents-test--db-files "(category \"AncCat\")")))
      (should (member (cdr (assoc "anccat.org" files)) live))
      ;; The FILE survives, because its parent entry carries the row --
      ;; so a per-file prefilter would be a superset here by accident.
      ;; The row stays unpushed for the entry-level reason instead: the
      ;; child has no category row of its own, and a future entry-level
      ;; prefilter would drop it.
      (should (member (cdr (assoc "anccat.org" files)) cands)))))

(ert-deftest org-agents-test-diff-guard-ts-not-pushed ()
  "A body-text timestamp is a match for org-ql and no entry_stamps row."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(ts :on "2024-02-29"))))
    (let ((live (org-agents-test--live-files
                 '(ts :on "2024-02-29") (org-agents-test--all-paths files))))
      (should (member (cdr (assoc "bodyts.org" files)) live))
      (should-not (member (cdr (assoc "bodyts.org" files))
                          (org-agents-test--db-files
                           "(ts :on \"2024-02-29\")"))))))

(ert-deftest org-agents-test-diff-guard-invalid-date-not-pushed ()
  "An impossible date is MJD 0 in the database and a normal bound in org-ql.
`resolveMjd' answers a date `parseTimeM' cannot read with 0, which is
1858-11-17, so the query bounds by that and answers with nothing --
emptying the candidate set rather than narrowing it."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(scheduled :to "2026-02-30"))))
    (should (null (org-agents--skeleton '(deadline :on "2026-13-45"))))
    ;; org-ql reads the typo as if it were a real bound ...
    (should (org-agents-test--live-files
             '(scheduled :to "2026-02-30") (org-agents-test--all-paths files)))
    ;; ... while the CLI bounds by 1858-11-17 and answers with nothing.
    (should (null (org-agents-test--db-files
                   "(scheduled :to \"2026-02-30\")")))))

(ert-deftest org-agents-test-diff-guard-heading-regexp-not-pushed ()
  "A regexp is not a LIKE pattern, so the conjunct stays residual."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(heading "Rev.*iew"))))
    (should (member (cdr (assoc "head-regexp.org" files))
                    (org-agents-test--live-files
                     '(heading "Rev.*iew")
                     (org-agents-test--all-paths files))))
    ;; ILIKE has no `.' or `*' metacharacter, so the naive push finds the
    ;; literal text and nothing else -- and the corpus holds none.
    (should (null (org-agents-test--db-files "(heading \"Rev.*iew\")")))))

(ert-deftest org-agents-test-diff-guard-file-property-canary ()
  "A `#+PROPERTY:'-only value is invisible to BOTH sides.
The `property' row IS pushed, so if org-ql ever begins answering
`(property N)' out of file-level properties or `org-global-properties',
the push-down becomes unsound the same day.  This is the tripwire."
  (org-agents-test--with-db-corpus
    (should (equal (org-agents--skeleton '(property "FILEPROP"))
                   "(property \"FILEPROP\")"))
    (should (null (org-agents-test--live-files
                   '(property "FILEPROP") (org-agents-test--all-paths files))))
    (should (null (org-agents-test--db-files "(property \"FILEPROP\")")))
    ;; And the value really is reachable by inheritance, so the fixture is
    ;; not silently inert.
    (with-current-buffer (find-file-noselect
                          (cdr (assoc "fileprop.org" files)))
      (goto-char (point-min))
      (re-search-forward "^\\* ")
      (should (equal (org-entry-get nil "FILEPROP" t) "fromfile")))))

(ert-deftest org-agents-test-diff-guard-special-property-not-pushed ()
  "A special property is entry structure, not an entry_properties row."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(property "CATEGORY" "AncCat"))))
    (should (null (org-agents--skeleton '(property-ts "DEADLINE" :to today))))
    ;; The evidence for the guard: the store writes CATEGORY into
    ;; entry_categories and never into entry_properties, so the naive push
    ;; answers with nothing at all.
    (should (null (org-agents-test--db-files
                   "(property \"CATEGORY\" \"AncCat\")")))
    ;; While a plain drawer property of the same corpus does answer, so
    ;; the emptiness above is the special name and not an empty database.
    (should (org-agents-test--db-files "(property \"NEXT_REVIEW\")"))))

(ert-deftest org-agents-test-diff-guard-todo-not-pushed ()
  "Keyword classification is a store-time flag, so `todo' cannot push.
A bare `(todo)' would in fact be a superset -- \"has a keyword\" covers
\"has a not-done keyword\" -- so the DONE fixture alone does not condemn
the row.  What condemns it is that the classification depends on the
`--keywords' DOT file supplied at STORE time, which nothing in
`org-db-cli.el' controls and which a corpus may well have been stored
without.  Demonstrated by storing one extra file without it."
  (org-agents-test--with-db-corpus
    (should (null (org-agents--skeleton '(todo))))
    (should (null (org-agents--skeleton '(todo "TODO"))))
    (should (null (org-agents--skeleton '(done))))
    (let* ((path (expand-file-name "nokw.org" dir))
           (true (progn (with-temp-file path
                          (insert "* TODO Stored without keywords\n"))
                        (file-truename path))))
      ;; Stored with NO --keywords, as a forgetful cron job would.
      (with-temp-buffer
        (let* ((default-directory temporary-file-directory)
               (code (call-process
                      (plist-get env :bin) nil t nil
                      "--config" (expand-file-name (plist-get env :config))
                      "db" "--db-url" (plist-get env :dsn)
                      "store" "--no-embed" true)))
          (unless (eq 0 code)
            (ert-fail (format "store without --keywords exited %s: %s"
                              code (buffer-string))))))
      ;; org-ql matches it; the naive keyword push does not, because
      ;; keyword_value is NULL and the title is the whole raw line.
      (should (member true (org-agents-test--live-files '(todo "TODO")
                                                        (list true))))
      (should (null (org-agents-test--db-files "(todo \"TODO\")")))
      ;; The `heading' row is unaffected by the flag: `headline' is the
      ;; raw line whether the keywords were supplied or not.
      (should (member true (org-agents-test--db-files
                            "(heading \"Stored without keywords\")"))))))

;;; The two places where the superset property does NOT hold.
;;
;; Both are real, both reproducible, and neither can be papered over by
;; choosing a gentler fixture.  They are written as expected failures so
;; that the suite stays green while the defect stays visible, and convert
;; to ordinary passing tests the day either is fixed.

(ert-deftest org-agents-test-diff-accumulated-property-breaks-superset ()
  "KNOWN DEFECT: `:NAME+:' makes the org-jw parser drop the whole drawer.
`FlatParse.Combinators.identifier' accepts alphanumerics, `_' and space,
and no `+', so `:TOKENS+: beta' cannot be read as a property line;
`parseProperties' then fails for the drawer, which degrades to a plain
body block.  entry_properties gets no row at all -- not for `TOKENS+',
and not for the perfectly ordinary `:TOKENS: alpha' line above it.

So the pushed `(property \"TOKENS\")' answers with no file while org-ql
matches on the joined value, and the prefilter drops a true match.  The
fix belongs in org-jw, in `identifier' and in the accumulation semantics
`Store.hs' would then need.  Recorded here rather than hidden: the
existing unit test asserting the equality-to-existence downgrade is not
wrong, it is only not sufficient."
  :expected-result :failed
  (org-agents-test--with-db-corpus
    (let ((q '(and (level 1) (property "TOKENS" "alpha beta"))))
      (should (equal (org-agents--skeleton q) "(property \"TOKENS\")"))
      (org-agents-test--should-be-superset
       q "(property \"TOKENS\")" (org-agents-test--all-paths files)))))

(ert-deftest org-agents-test-diff-today-guard-keeps-the-superset ()
  "The relative-date guard is what keeps `today' a superset, and it holds.
The database resolves `today' against `utctDay <$> getCurrentTime' and
org-ql against `(ts-now)', so on the hours those name different days a
pushed `:on today' selects by a different day than org-ql does.  This is
the differential half of
`org-agents-test-skeleton-relative-date-pushed-only-when-days-agree':
whichever branch the clock is in, the prefilter must never be missing a
file org-ql matches.

Deterministic in both branches.  Where the days agree the conjunct is
pushed and asserted to be a superset over the whole corpus.  Where they
differ nothing is pushed at all -- so there is no candidate set to be
wrong, and the naive skeleton the guard suppressed is run anyway to show
the file it would have dropped."
  (org-agents-test--with-db-corpus
    (let* ((q '(and (scheduled :on today) (todo)))
           (today-file (cdr (assoc "today.org" files)))
           (live (org-agents-test--live-files
                  q (org-agents-test--all-paths files))))
      ;; The fixture is scheduled on the LOCAL day, so org-ql matches it.
      (should (member today-file live))
      (if (org-agents--relative-dates-agree-p)
          (progn
            (should (equal (org-agents--skeleton q) "(scheduled :on today)"))
            (org-agents-test--should-be-superset
             q "(scheduled :on today)" (org-agents-test--all-paths files)))
        ;; The guard refused it, so no date narrowing happens at all ...
        (should (null (org-agents--skeleton q)))
        ;; ... and this is what pushing it anyway would have answered: the
        ;; file org-ql matches, missing from the candidates.
        (should-not (member today-file
                            (org-agents-test--db-files
                             "(scheduled :on today)")))))))

(provide 'org-agents-test)
;;; org-agents-test.el ends here
