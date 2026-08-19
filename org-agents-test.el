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
  (should (null (org-agents--prefilter-conjuncts '(heading "Rev.*iew")))))

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
                    ((symbol-function 'org-agents--rg-files)
                     (lambda (_conjuncts _root) (list a)))
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
                    ((symbol-function 'org-agents--rg-files)
                     (lambda (conjuncts _root) (setq asked conjuncts) (list a)))
                    ((symbol-function 'org-agents--scope-base-files)
                     (lambda (_scope) (list link b))))
            (let ((matches (org-agents--collect agent)))
              (should (equal asked '((property "NEXT_REVIEW"))))
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
                  ((symbol-function 'org-agents--rg-files)
                   (lambda (_conjuncts _root)
                     (list (expand-file-name "elsewhere.org" dir)))))
          (should (null (org-agents--scope-files agent)))
          (should (null (org-agents--collect agent))))
        ;; An EMPTY ripgrep answer.  `nil' rather than the base list is
        ;; what distinguishes the branch, and the base list here is not
        ;; empty -- the corpus holds `a.org' and `b.org' -- so the
        ;; assertion cannot hold for want of anything to lose.
        (cl-letf (((symbol-function 'org-agents--rg-available-p)
                   (lambda () t))
                  ((symbol-function 'org-agents--rg-files)
                   (lambda (_conjuncts _root) nil)))
          (should (org-agents--scope-base-files 'active))
          (should (null (org-agents--scope-files agent)))
          (should (null (org-agents--collect agent))))
        ;; And the base files must not even be GATHERED for an empty
        ;; answer: gathering them is the recursive walk the prefilter
        ;; exists to make unnecessary.
        (cl-letf (((symbol-function 'org-agents--rg-available-p)
                   (lambda () t))
                  ((symbol-function 'org-agents--rg-files)
                   (lambda (_conjuncts _root) nil))
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

;;;; Minor mode

;; Every test here saves a real file, through `save-buffer', and reads the
;; result back off disk rather than out of the buffer that wrote it: what
;; the mode promises is about the bytes that reach the file.

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

(ert-deftest org-agents-test-rg-run-reports-a-signal-and-a-spawn-failure ()
  "A non-integer status must fall to the failure branch, not slip past it.
`call-process' answers with a STRING such as \"Killed: 9\" when the
process dies on a signal, so the test has to be `(eq code 0)' /
`(eq code 1)' and never `(> code 1)'."
  (let ((dir (make-temp-file "org-agents-rg" t)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest _) "Killed: 9")))
            (should (eq 'unavailable (org-agents--rg-run "PAT" dir))))
          ;; Failure to spawn at all is reported like any other failure
          ;; rather than signalling out of an agent update.
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest _) (signal 'file-missing '("no rg")))))
            (let (result)
              (let ((msgs (org-agents-test--messages
                           (setq result (org-agents--rg-run "PAT" dir)))))
                (should (eq result 'unavailable))
                (should (cl-find-if (lambda (m) (string-match-p "org-agents" m))
                                    msgs))))))
      (delete-directory dir t))))

(ert-deftest org-agents-test-rg-run-spawns-in-a-live-local-directory ()
  "A deleted `default-directory' makes `call-process' signal; a remote one
would run the binary on another host, against files that are not the
corpus.  So the process is spawned from `temporary-file-directory'."
  (let* ((dir (make-temp-file "org-agents-rg" t))
         (org-agents-rg-executable
          (org-agents-test--fake-rg (expand-file-name "rg" dir) "exit 1"))
         (seen nil))
    (unwind-protect
        (cl-letf* ((real (symbol-function 'call-process))
                   ((symbol-function 'call-process)
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
    ;; Regexp metacharacters the splitter refuses to push at all.
    ("head-regexp.org" . "\
* Rev.*iew of plans
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

(defconst org-agents-test--rg-corpus-count 30
  "How many `.org' files `org-agents-test--with-rg-corpus' reliably shows.
Twenty-nine from the manifest, plus the latin-1 file the macro builds.
`link.org' is a thirty-first that is deliberately NOT counted: see the
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
  `(let ((org-agents-prefilter 'auto))
     (let* ((dir (make-temp-file "org-agents-rg-corpus" t))
            (outside (make-temp-file "org-agents-rg-outside" t))
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
             (ignore F)
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
  "The cleaned title org-ql compares against is a substring of the raw line.
`org-get-heading' with `no-tags' and `no-todo' returns the title, or the
priority cookie joined to it by exactly one space -- and every substring
spanning that junction holds the `]' that `org-agents--literal-strings-p'
already refuses."
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
  "`(' is not in `org-agents--literal-regexp', so the splitter pushes it."
  (org-agents-test--with-rg-corpus
    (let ((cands (org-agents-test--should-cover '(heading "Review (draft)")
                                                paths dir)))
      (should (equal cands
                     (list (file-truename (funcall F "head-paren.org"))))))))

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
                     (heading "Rev.*iew") (property "CATEGORY" "work")
                     (property-ts "DEADLINE" :to today)
                     (parent (property "NEXT_REVIEW"))
                     (or (property "NEXT_REVIEW") (todo))
                     (not (property "NEXT_REVIEW"))))
      (should (null (org-agents--prefilter-conjuncts query))))
    ;; And the residual queries really do match, so the rows above are
    ;; refusing something that exists.
    (dolist (query '((todo) (heading "Rev.*iew") (ts :on "2024-02-29")))
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

;;; When the prefilter is consulted, and what happens when it cannot answer

(ert-deftest org-agents-test-prefilter-not-consulted-for-named-files ()
  "A scope that NAMES its files is scanned live, with no subprocess.
MEASURED: an `agenda'-scope update over eight named files costs 0.018 s
while a single rg run costs 0.10-0.45 s, so prefiltering a named file
list makes the common case 5-25 times slower to reach the same answer.
The spawn is made DETECTABLE rather than assumed away -- a `call-process'
that records the breach in a flag, because the backend catches errors by
design and would swallow a signalling stub."
  (org-agents-test--with-corpus
    (let ((breached nil)
          (query '(and (todo) (property "NEXT_REVIEW"))))
      ;; The query really does push, so the absence of a spawn is the
      ;; scope rule declining and not an empty conjunct list.
      (should (org-agents--prefilter-conjuncts query))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest _) (setq breached t) 1)))
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
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest _) (setq breached t) 1)))
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
45.98 seconds and 885 MB of RSS over 3,640 buffers is a shocking thing to
happen without explanation, and a message naming 3,634 files explains
it.  Silence is what this replaces; an error is what `require' is for."
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
  "`require' keeps the behaviour of the releases that had a database.
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

Note the change of REASON from the test this replaces: with a local rg
measured at 0.13 s over 3,634 files there is no network to block on, so
the rule is about pointless work rather than about a save that hangs."
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

(provide 'org-agents-test)
;;; org-agents-test.el ends here
