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
;;
;; "Never signals" means never signals an *error*: a `quit' raised by C-g
;; during a synchronous run still escapes, as it must.

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

(defun org-db-cli--file-contents (file)
  "Return FILE's contents, trimmed, or an empty string if unreadable."
  (or (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (string-trim (buffer-string))))
      ""))

(defun org-db-cli--run (args)
  "Run the CLI with ARGS; return stdout string, or nil on failure.
Stderr is captured separately so that a nonzero exit can be reported
with the diagnostics the CLI actually wrote there, falling back to
stdout when stderr is empty.  The process is spawned from
`temporary-file-directory', because a `default-directory' that has been
deleted makes `call-process' signal, and a remote one would run the
binary on another host.  Failure to spawn at all is reported like any
other failure rather than signalling."
  (when (org-db-cli-available-p)
    (condition-case err
        (let ((stderr-file (make-temp-file "org-db-cli-stderr")))
          (unwind-protect
              (with-temp-buffer
                ;; `default-directory' is buffer-local, so this must be
                ;; bound with the temp buffer current to have any effect
                ;; on the process `call-process' spawns.
                (let* ((default-directory temporary-file-directory)
                       (code (apply #'call-process org-db-cli-executable
                                    nil (list (current-buffer) stderr-file)
                                    nil args)))
                  (if (eq code 0)
                      (buffer-string)
                    (let ((stderr (org-db-cli--file-contents stderr-file)))
                      (message "org-db-cli: %s exited %s: %s"
                               org-db-cli-executable code
                               (if (string-empty-p stderr)
                                   (string-trim (buffer-string))
                                 stderr)))
                    nil)))
            (ignore-errors (delete-file stderr-file))))
      (error
       (message "org-db-cli: %s failed: %s"
                org-db-cli-executable (error-message-string err))
       nil))))

(defun org-db-cli--parse-lines (output)
  "Parse JSON-lines OUTPUT into a list of alists, skipping unusable lines.
A line is unusable when it is not valid JSON, or when it parses to
something other than an object -- an array, number, string or boolean
yields no alist, and would make `alist-get' signal downstream.  The
count is reported in a single summary message rather than one per line.

`json-error' is caught rather than `json-parse-error' so that its
sibling `json-utf8-decode-error', raised by invalid UTF-8, is handled
too."
  (let ((malformed 0)
        rows)
    (dolist (line (split-string (or output "") "\n" t))
      (condition-case nil
          ;; An empty JSON object parses to nil, which is a list, so
          ;; `listp' rather than `consp' is the right admission test.
          (let ((row (json-parse-string line :object-type 'alist
                                        :null-object nil)))
            (if (listp row)
                (push row rows)
              (cl-incf malformed)))
        (json-error (cl-incf malformed))))
    (when (> malformed 0)
      (message "org-db-cli: skipped %d malformed JSON line(s)" malformed))
    (nreverse rows)))

(defun org-db-cli-query-files (skeleton)
  "Run `db query --ql SKELETON'; return sorted unique absolute files.
Return nil if the CLI is unconfigured, fails, or yields no file fields.

The `file' field the CLI writes is already absolute and canonicalized --
the store records `canonicalizePath' of each file it reads -- so what
comes back names a file by its truename and not by whatever spelling a
caller reached it through.  A caller intersecting these names with its own
must therefore compare truenames on both sides: where `org-directory' is
itself a symlink, the two spellings of one file have nothing in common
under `equal'.  `org-agents--same-files' is where that is done."
  (when (and skeleton (org-db-cli-available-p))
    (let* ((output (org-db-cli--run
                    (list "--config" (expand-file-name org-db-cli-config-file)
                          "db" "--db-url" org-db-cli-db-url
                          "query" "--ql" skeleton "--format" "json")))
           (rows (and output (org-db-cli--parse-lines output)))
           (base (or org-db-cli-files-directory org-directory))
           files)
      (dolist (row rows)
        (let ((f (alist-get 'file row)))
          ;; Only a NUL-free string is usable: `expand-file-name' signals
          ;; on a number, on an array, and on a string carrying a NUL --
          ;; all three of which JSON can deliver, the last as an escape.
          (when (and (stringp f) (not (string-search "\0" f)))
            (cl-pushnew (expand-file-name f base) files :test #'equal))))
      (sort files #'string<))))

(provide 'org-db-cli)
;;; org-db-cli.el ends here
