;;; org-db-cli-test.el --- Tests for org-db-cli -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'ert)
(require 'org-db-cli)

(defmacro org-db-cli-test--with-cli (exit-code stdout &rest body)
  "Run BODY with `call-process' stubbed to return EXIT-CODE and insert STDOUT."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'call-process)
              (lambda (_prog _in dest _display &rest _args)
                (with-current-buffer (if (consp dest) (car dest) dest)
                  (insert ,stdout))
                ,exit-code))
             ((symbol-function 'executable-find) (lambda (_p) "/bin/org")))
     (let ((org-db-cli-executable "org")
           (org-db-cli-config-file "/tmp/org.yaml")
           (org-db-cli-db-url "postgresql://x")
           (org-db-cli-files-directory "/tmp/corpus"))
       ,@body)))

(ert-deftest org-db-cli-test-parses-files ()
  (org-db-cli-test--with-cli 0
      "{\"id\":\"a\",\"title\":\"T\",\"keyword\":null,\"depth\":1,\"file\":\"todo.org\"}
{\"id\":\"b\",\"title\":\"U\",\"keyword\":\"TODO\",\"depth\":2,\"file\":\"sub/x.org\"}
{\"id\":\"c\",\"title\":\"V\",\"keyword\":null,\"depth\":1,\"file\":\"todo.org\"}"
    (should (equal (org-db-cli-query-files "(property \"X\")")
                   '("/tmp/corpus/sub/x.org" "/tmp/corpus/todo.org")))))

(ert-deftest org-db-cli-test-failure-returns-nil ()
  (org-db-cli-test--with-cli 1 "boom"
    (should (null (org-db-cli-query-files "(property \"X\")")))))

(ert-deftest org-db-cli-test-rows-without-file-are-dropped ()
  (org-db-cli-test--with-cli 0
      "{\"id\":\"a\",\"title\":\"T\",\"keyword\":null,\"depth\":1}"
    (should (null (org-db-cli-query-files "(property \"X\")")))))

(ert-deftest org-db-cli-test-unconfigured-is-unavailable ()
  (let ((org-db-cli-db-url nil))
    (should-not (org-db-cli-available-p))
    (should (null (org-db-cli-query-files "(todo)")))))

(provide 'org-db-cli-test)
;;; org-db-cli-test.el ends here
