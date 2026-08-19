;;; org-db-cli-test.el --- Tests for org-db-cli -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-db-cli)

(defvar org-db-cli-test--last-args nil
  "Argument list passed to `call-process' during the most recent stubbed run.")

(defvar org-db-cli-test--last-directory nil
  "`default-directory' in effect during the most recent stubbed run.")

;; Declared, not required: binding `tramp-mode' below must be dynamic, and
;; it would silently be lexical wherever tramp has not already declared it.
(defvar tramp-mode)

(defmacro org-db-cli-test--with-cli (exit-code stdout &rest body)
  "Run BODY with the `org' CLI stubbed out.

`call-process' is replaced by a stub that returns EXIT-CODE, inserts
STDOUT into the destination buffer, and records both its argument list
and the ambient `default-directory' into `org-db-cli-test--last-args'
and `org-db-cli-test--last-directory'.  `executable-find' is stubbed to
report the executable as present, so no real binary is consulted.

All four defcustoms are bound to valid values: `org-db-cli-executable'
to \"org\", `org-db-cli-config-file' to \"/tmp/org.yaml\",
`org-db-cli-db-url' to \"postgresql://x\", and
`org-db-cli-files-directory' to \"/tmp/corpus\".

BODY may begin with the keyword `:stderr' followed by a string, in which
case the stub also writes that string to the stderr file that
`org-db-cli--run' passes as the second element of its destination."
  (declare (indent 2))
  (let ((stderr (and (eq (car body) :stderr) (cadr body))))
    (when stderr (setq body (cddr body)))
    `(let ((org-db-cli-test--last-args nil)
           (org-db-cli-test--last-directory nil))
       (cl-letf (((symbol-function 'call-process)
                  (lambda (_prog _in dest _display &rest args)
                    (setq org-db-cli-test--last-args args
                          org-db-cli-test--last-directory default-directory)
                    (with-current-buffer (if (consp dest) (car dest) dest)
                      (insert ,stdout))
                    ,@(when stderr
                        `((let ((stderr-file (and (consp dest) (cadr dest))))
                            (when (stringp stderr-file)
                              (with-temp-file stderr-file (insert ,stderr))))))
                    ,exit-code))
                 ((symbol-function 'executable-find) (lambda (_p) "/bin/org")))
         (let ((org-db-cli-executable "org")
               (org-db-cli-config-file "/tmp/org.yaml")
               (org-db-cli-db-url "postgresql://x")
               (org-db-cli-files-directory "/tmp/corpus"))
           ,@body)))))

(defmacro org-db-cli-test--capturing-messages (var &rest body)
  "Run BODY with `message' stubbed, VAR holding captured text newest first."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (apply #'format-message fmt args) ,var)
                  nil)))
       ,@body)))

(ert-deftest org-db-cli-test-parses-files ()
  "Rows become sorted, de-duplicated, absolute file names.
The fixture arrives unsorted and with a repeat, so both the sort and the
de-duplication are load-bearing: the expected result matches neither the
arrival order nor its reverse."
  (org-db-cli-test--with-cli 0
      "{\"id\":\"b\",\"title\":\"U\",\"keyword\":\"TODO\",\"depth\":2,\"file\":\"sub/x.org\"}
{\"id\":\"a\",\"title\":\"T\",\"keyword\":null,\"depth\":1,\"file\":\"todo.org\"}
{\"id\":\"d\",\"title\":\"W\",\"keyword\":null,\"depth\":3,\"file\":\"archive.org\"}
{\"id\":\"c\",\"title\":\"V\",\"keyword\":null,\"depth\":1,\"file\":\"todo.org\"}"
    (should (equal (org-db-cli-query-files "(property \"X\")")
                   '("/tmp/corpus/archive.org"
                     "/tmp/corpus/sub/x.org"
                     "/tmp/corpus/todo.org")))))

(ert-deftest org-db-cli-test-invocation-shape ()
  "The `db query' argument vector is pinned exactly, and omits --limit."
  (org-db-cli-test--with-cli 0 "{\"id\":\"a\",\"file\":\"todo.org\"}"
    (should (org-db-cli-query-files "(property \"X\")"))
    (should (equal org-db-cli-test--last-args
                   '("--config" "/tmp/org.yaml"
                     "db" "--db-url" "postgresql://x"
                     "query" "--ql" "(property \"X\")"
                     "--format" "json")))
    (should-not (member "--limit" org-db-cli-test--last-args))))

(ert-deftest org-db-cli-test-failure-returns-nil ()
  "A nonzero exit yields nil and reports stderr in preference to stdout."
  (org-db-cli-test--capturing-messages msgs
    (org-db-cli-test--with-cli 1 "stdout noise" :stderr "boom: unknown --ql form"
      (should (null (org-db-cli-query-files "(property \"X\")")))
      (should (string-match-p "exited 1" (car msgs)))
      (should (string-match-p "boom: unknown --ql form" (car msgs)))
      (should-not (string-match-p "stdout noise" (car msgs))))))

(ert-deftest org-db-cli-test-failure-falls-back-to-stdout ()
  "When stderr is empty the failure message falls back to stdout."
  (org-db-cli-test--capturing-messages msgs
    (org-db-cli-test--with-cli 1 "boom"
      (should (null (org-db-cli-query-files "(property \"X\")")))
      (should (string-match-p "exited 1" (car msgs)))
      (should (string-match-p "boom" (car msgs))))))

(ert-deftest org-db-cli-test-process-error-returns-nil ()
  "A `call-process' that signals is reported and yields nil, never an error."
  (org-db-cli-test--capturing-messages msgs
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _)
                 (signal 'file-missing
                         '("Searching for program" "No such file" "org"))))
              ((symbol-function 'executable-find) (lambda (_p) "/bin/org")))
      (let ((org-db-cli-executable "org")
            (org-db-cli-config-file "/tmp/org.yaml")
            (org-db-cli-db-url "postgresql://x")
            (org-db-cli-files-directory "/tmp/corpus"))
        (should (null (org-db-cli-query-files "(todo)")))
        (should (string-match-p "failed" (car msgs)))))))

(ert-deftest org-db-cli-test-runs-in-a-live-local-directory ()
  "The CLI is spawned with `default-directory' forced local and live.
A deleted working directory otherwise makes `call-process' signal
`file-missing', and a TRAMP one would run the binary on another host."
  (dolist (dir '("/nonexistent-dir-xyz/" "/ssh:host:/tmp/"))
    (let ((default-directory dir)
          ;; Keep the remote-looking directory inert: with no handlers,
          ;; TRAMP is never pulled in and cannot try to reach `host'.
          (file-name-handler-alist nil)
          (tramp-mode nil))
      (org-db-cli-test--with-cli 0 "{\"id\":\"a\",\"file\":\"todo.org\"}"
        (should (org-db-cli-query-files "(todo)"))
        (should (equal org-db-cli-test--last-directory
                       temporary-file-directory))))))

(ert-deftest org-db-cli-test-rows-without-file-are-dropped ()
  "A row carrying no `file' field contributes nothing."
  (org-db-cli-test--with-cli 0
      "{\"id\":\"a\",\"title\":\"T\",\"keyword\":null,\"depth\":1}"
    (should (null (org-db-cli-query-files "(property \"X\")")))))

(ert-deftest org-db-cli-test-non-object-json-lines-are-dropped ()
  "Valid JSON that is not an object is skipped instead of signalling.
Arrays, numbers, booleans and strings do not parse to alists, so
`alist-get' would raise `wrong-type-argument' on them."
  (org-db-cli-test--capturing-messages msgs
    (org-db-cli-test--with-cli 0
        "[]\n[1,2]\n5\ntrue\nfalse\n\"str\"\n{\"id\":\"a\",\"file\":\"todo.org\"}"
      (should (equal (org-db-cli-query-files "(todo)")
                     '("/tmp/corpus/todo.org")))
      (should (string-match-p "skipped 6 malformed JSON line" (car msgs))))))

(ert-deftest org-db-cli-test-empty-object-is-not-malformed ()
  "An empty JSON object parses to nil and must not count as malformed."
  (org-db-cli-test--capturing-messages msgs
    (org-db-cli-test--with-cli 0 "{}\n{\"id\":\"a\",\"file\":\"todo.org\"}"
      (should (equal (org-db-cli-query-files "(todo)")
                     '("/tmp/corpus/todo.org")))
      (should (null msgs)))))

(ert-deftest org-db-cli-test-non-string-file-is-dropped ()
  "A `file' field that is not a string is dropped instead of signalling.
`expand-file-name' raises `wrong-type-argument' on a number or vector."
  (org-db-cli-test--with-cli 0
      "{\"id\":\"a\",\"file\":123}
{\"id\":\"b\",\"file\":[\"a\"]}
{\"id\":\"c\",\"file\":null}
{\"id\":\"d\",\"file\":true}"
    (should (null (org-db-cli-query-files "(todo)")))))

(ert-deftest org-db-cli-test-nul-in-file-is-dropped ()
  "A `file' string carrying a NUL byte is dropped instead of signalling.
JSON delivers one through a \\u0000 escape, and it passes `stringp';
`expand-file-name' then raises `wrong-type-argument' on filenamep."
  (org-db-cli-test--with-cli 0 "{\"id\":\"a\",\"file\":\"a\\u0000b.org\"}"
    (should (null (org-db-cli-query-files "(todo)")))))

(ert-deftest org-db-cli-test-invalid-utf8-is-dropped ()
  "Invalid UTF-8 is skipped rather than escaping as an error.
It raises `json-utf8-decode-error', a sibling of `json-parse-error'
under `json-error', so a `json-parse-error' handler does not catch it."
  (org-db-cli-test--with-cli 0
      (concat "{\"id\":\"a\",\"file\":\"" (unibyte-string 255) "\"}\n"
              "{\"id\":\"b\",\"file\":\"todo.org\"}")
    (should (equal (org-db-cli-query-files "(todo)")
                   '("/tmp/corpus/todo.org")))))

(ert-deftest org-db-cli-test-malformed-lines-are-reported-once ()
  "Many unusable lines produce exactly one summary message, not a flood."
  (org-db-cli-test--capturing-messages msgs
    (org-db-cli-test--with-cli 0 "nope\nalso nope\n5\n[]"
      (should (null (org-db-cli-query-files "(todo)")))
      (should (= 1 (length msgs)))
      (should (string-match-p "skipped 4 malformed JSON line" (car msgs))))))

(ert-deftest org-db-cli-test-availability-conditions ()
  "Executable, config file and db URL are each individually required.
The unavailable cases also assert that no query is attempted.  Note that
a signalling stub alone would not prove that: `org-db-cli--run' catches
errors by design, so a breach would be swallowed and reported as an
ordinary failure.  The stub therefore records the breach in a flag that
`should-not' inspects, which also keeps a future broken guard from
quietly invoking the real CLI against a real --db-url."
  (let (breached)
    (cl-letf (((symbol-function 'executable-find) (lambda (_p) "/bin/org"))
              ((symbol-function 'call-process)
               (lambda (&rest _)
                 (setq breached t)
                 (error "guard breached: call-process ran while unavailable"))))
      (let ((org-db-cli-executable "org")
            (org-db-cli-config-file "/tmp/org.yaml")
            (org-db-cli-db-url "postgresql://x")
            (org-db-cli-files-directory "/tmp/corpus"))
        (should (org-db-cli-available-p))
        (let ((org-db-cli-config-file nil))
          (should-not (org-db-cli-available-p))
          (should (null (org-db-cli-query-files "(todo)")))
          (should-not breached))
        (let ((org-db-cli-db-url nil))
          (should-not (org-db-cli-available-p))
          (should (null (org-db-cli-query-files "(todo)")))
          (should-not breached))
        (cl-letf (((symbol-function 'executable-find) (lambda (_p) nil)))
          (should-not (org-db-cli-available-p))
          (should (null (org-db-cli-query-files "(todo)")))
          (should-not breached))))))

(provide 'org-db-cli-test)
;;; org-db-cli-test.el ends here
