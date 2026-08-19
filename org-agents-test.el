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
afterwards, because the files they visit are about to be deleted."
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
  (let ((dir (make-temp-file "org-agents-noid" t)))
    (unwind-protect
        (let ((f (expand-file-name "x.org" dir)))
          (with-temp-file f (insert "* TODO A [tricky] title\n"))
          (let* ((matches (org-ql-select (list f) '(todo)
                            :action 'element-with-markers))
                 (link (org-agents--link-to (car matches))))
            (should (string-match-p "\\`\\[\\[file:" link))
            (should (string-match-p "::\\*" link))))
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

(provide 'org-agents-test)
;;; org-agents-test.el ends here
