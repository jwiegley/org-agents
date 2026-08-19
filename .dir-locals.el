;;; Directory Local Variables            -*- no-byte-compile: t -*-
;;; For more information see (info "(emacs) Directory Variables")

;; Three settings, all of them already `safe-local-variable' so that
;; visiting a file here asks nothing:
;;
;;   indent-tabs-mode  The four sources contain no tab character at all.
;;                     Emacs Lisp mode does not set this and the global
;;                     default is t, so a re-indented defun is the one
;;                     realistic way tabs would arrive.
;;   fill-column       The commentary in both sources wraps at 72.  M-q
;;                     inside a docstring uses
;;                     `emacs-lisp-docstring-fill-column' (65) instead, so
;;                     this cannot produce the >80-column docstring line
;;                     that tools/org-agents-byte-compile-gate.sh rejects.
;;   sentence-end-double-space
;;                     Records the convention the prose is written in.  A
;;                     no-op wherever the default still holds.

((emacs-lisp-mode . ((indent-tabs-mode . nil)
                     (fill-column . 72)
                     (sentence-end-double-space . t))))
