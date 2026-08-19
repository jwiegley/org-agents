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

(ert-deftest org-agents-test-update-buffer-updates-every-agent ()
  "Every agent in the buffer, each anchored where it was found.
The agents are collected as markers before any of them renders: writing
the first one inserts headings under it and a line into its drawer, and
a position found beforehand would no longer name the agent it was found
for."
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

(ert-deftest org-agents-test-preview-applies-exclusion ()
  "What a preview lists is what an agent would render, aliases excluded."
  (let (received)
    (cl-letf (((symbol-function 'org-ql-search)
               (lambda (_files query &rest _) (setq received query))))
      (org-agents-preview "(todo)")
      (should (equal received `(and (todo) ,org-agents-exclude)))
      ;; The `$PROP' layer is expanded exactly as an agent's query is.
      (org-agents-preview "(and (todo) $URL)")
      (should (equal received
                     `(and (and (todo) (property "URL")) ,org-agents-exclude)))
      ;; And with the exclusion off, the query alone: nil conjoined here
      ;; would be a clause that never matches.
      (let ((org-agents-exclude nil))
        (org-agents-preview "(todo)")
        (should (equal received '(todo)))))))

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
  "`C-c C-x x' offers the block among the types it knows."
  (should (member "org-agents" (org-dynamic-block-types)))
  (should (eq #'org-agents-update (org-dynamic-block-function "org-agents"))))

(provide 'org-agents-test)
;;; org-agents-test.el ends here
