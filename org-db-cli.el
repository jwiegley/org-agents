;;; org-db-cli.el --- Bridge to the org-jw `org db' CLI -*- lexical-binding: t -*-

;; Author: John Wiegley <johnw@gnu.org>
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: outlines data

;;; Commentary:

;; Shared invocation layer for the Haskell `org' CLI's `db' subcommands
;; (~/src/org-jw).  Consumers: org-agents.el (candidate-file prefilter);
;; org-ql-semantic.el migration is a planned follow-up.
;;
;; Contract: query functions never signal.  On any failure (unconfigured,
;; nonzero exit, unparseable output) they `message' and return nil, so
;; callers can distinguish "no answer" from "empty answer" only by
;; supplying queries guaranteed to match; org-agents treats nil as
;; prefilter-unavailable.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)

(defgroup org-db-cli nil
  "Bridge to the org-jw `org db' command-line interface."
  :group 'org
  :prefix "org-db-cli-")

(defcustom org-db-cli-executable "org"
  "Name or path of the `org' CLI executable."
  :type 'string :group 'org-db-cli)

(defcustom org-db-cli-config-file nil
  "YAML config passed as --config.  Required for all invocations."
  :type '(choice (const nil) file) :group 'org-db-cli)

(defcustom org-db-cli-db-url nil
  "PostgreSQL URL passed as `db --db-url'.
Set explicitly in init (do not derive from `org-ql-semantic-db-url',
which is only assigned when that package loads)."
  :type '(choice (const nil) string) :group 'org-db-cli)

(defcustom org-db-cli-files-directory nil
  "Directory against which relative `file' fields resolve.
When nil, `org-directory' is used."
  :type '(choice (const nil) directory) :group 'org-db-cli)

(defun org-db-cli-available-p ()
  "Return non-nil when the CLI is fully configured and present."
  (and org-db-cli-config-file
       org-db-cli-db-url
       (executable-find org-db-cli-executable)))

(defun org-db-cli--run (args)
  "Run the CLI with ARGS; return stdout string, or nil on failure."
  (when (org-db-cli-available-p)
    (with-temp-buffer
      (let ((code (apply #'call-process org-db-cli-executable
                         nil (list (current-buffer) nil) nil args)))
        (if (eq code 0)
            (buffer-string)
          (message "org-db-cli: %s exited %s: %s"
                   org-db-cli-executable code
                   (string-trim (buffer-string)))
          nil)))))

(defun org-db-cli--parse-lines (output)
  "Parse JSON-lines OUTPUT into a list of alists, skipping bad lines."
  (let (rows)
    (dolist (line (split-string (or output "") "\n" t))
      (condition-case nil
          (push (json-parse-string line :object-type 'alist :null-object nil)
                rows)
        (json-parse-error
         (message "org-db-cli: skipping malformed JSON line"))))
    (nreverse rows)))

(defun org-db-cli-query-files (skeleton)
  "Run `db query --ql SKELETON'; return sorted unique absolute files.
Return nil if the CLI is unconfigured, fails, or yields no file fields."
  (when (and skeleton (org-db-cli-available-p))
    (let* ((output (org-db-cli--run
                    (list "--config" (expand-file-name org-db-cli-config-file)
                          "db" "--db-url" org-db-cli-db-url
                          "query" "--ql" skeleton "--format" "json")))
           (rows (and output (org-db-cli--parse-lines output)))
           (base (or org-db-cli-files-directory org-directory))
           files)
      (dolist (row rows)
        (when-let* ((f (alist-get 'file row)))
          (cl-pushnew (expand-file-name f base) files :test #'equal)))
      (sort files #'string<))))

(provide 'org-db-cli)
;;; org-db-cli.el ends here
