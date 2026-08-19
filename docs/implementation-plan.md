# org-agents Implementation Plan

> **Historical, 2026-08-18.** Nothing here is current guidance; it is kept to
> answer "why is it like this?". Removed on 2026-08-19, when ripgrep replaced
> the database prefilter: Task 1 (the org-jw `file` field), Task 2
> (`org-db-cli.el`), the `(require 'org-db-cli)` in Task 3, **Task 5's
> skeleton serializer** — the shipped splitter returns a list of abstract
> conjuncts, emits no `prin1-to-string`'d CLI sexp and has no `path`
> conjunct, so every interface Task 5 specifies for `org-agents--skeleton`
> and `org-agents--scope-conjunct` is wrong — **Task 6's CLI call**
> (`org-db-cli-available-p`, `org-db-cli-query-files`), and Task 10's
> differential suite. The rest of Tasks 3-9 describes shipped code.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tinderbox-style agents for Org-mode — entries carrying an org-ql query (with `$PROP` sugar) that populate themselves with child aliases, a list, or a table of links to matching entries, optionally prefiltered by the org-jw PostgreSQL database.

**Architecture:** One evaluation engine (org-ql over live buffers). The database is only a candidate-*file* prefilter reached through a small CLI bridge (`org-db-cli.el`); a soundness table restricts push-down to provably superset-safe conjuncts. Rendering happens at live headings with marker-based positions. A whole-query gate controls evaluation of any non-predicate Lisp.

**Tech Stack:** Emacs Lisp (org-ql 20250421.133, Org 9.8.7, ERT), one small Haskell change in `~/src/org-jw` (tasty/HUnit test).

**Spec:** `docs/superpowers/specs/2026-08-18-org-agents-design.md` (revision 2). Review that produced it: `docs/superpowers/specs/2026-08-18-org-agents-design-review.md`.

## Global Constraints

- New files live in `/Users/johnw/src/dot-emacs/lisp/`: `org-db-cli.el`, `org-agents.el`, `org-db-cli-test.el`, `org-agents-test.el`. Lexical binding, standard package skeleton, `provide` matching filename (repo CLAUDE.md).
- Byte-compilation must be warning-free (repo CLAUDE.md: "Fix all warnings").
- `emacs` is NOT on PATH. Resolve once per shell session:

  ```sh
  EMACS=$(for e in /nix/store/*emacs-mac-macport-with-packages-*/bin/emacs; do
    "$e" -batch --eval "(require 'org-ql)" 2>/dev/null && { echo "$e"; break; }; done)
  ```

  Do not pass `-Q` (it suppresses the nix site-lisp). Verified working: this Emacs batch-loads `org-ql` and `org-ql-ext` with `-L /Users/johnw/src/dot-emacs/lisp -L /Users/johnw/.emacs.d/lisp`.
- ERT run template (from `/Users/johnw/src/dot-emacs/lisp`):

  ```sh
  "$EMACS" -batch -L . -L /Users/johnw/.emacs.d/lisp -l org-agents-test.el \
    --eval '(ert-run-tests-batch-and-exit "PATTERN")'
  ```
- Commit style: `org-agents: Sentence` / `org-db-cli: Sentence` / `org db: Sentence` (org-jw), matching repo history. Commits happen in the repo that owns the files (Tasks 1 is in `~/src/org-jw`, everything else in `~/src/dot-emacs`).
- Machine-maintained property names are fixed: `AGENT_MATCH` (on generated children), `AGENT_MATCHED` (status). User properties: `AGENT_QUERY`, `AGENT_VIEW`, `AGENT_SCOPE`, `AGENT_SORT`, `AGENT_LIMIT`, `AGENT_COLUMNS`, `AGENT_FORMAT`. No others.
- `:AGENT_QUERY:` is a single line; never suggest `:AGENT_QUERY+:` (org-jw's parser silently discards the whole drawer — spec Background §2).
- The CLI is invoked exactly as: `org --config CFG db --db-url URL query --ql SEXP --format json` — never `--limit` (unordered client-side `take`), never `-Q`-style shortcuts. `--db-url` must precede `query`.

---

### Task 1: org-jw — `db query --format json` emits `file`

**Files:**
- Create: `/Users/johnw/src/org-jw/org-db/src/Org/DB/Render.hs`
- Create: `/Users/johnw/src/org-jw/org-db/test/RenderTest.hs`
- Modify: `/Users/johnw/src/org-jw/org-db/package.yaml` (library `exposed-modules`, test `other-modules`)
- Modify: `/Users/johnw/src/org-jw/org-db/test/Spec.hs`
- Modify: `/Users/johnw/src/org-jw/org-jw/bin/DB/Exec.hs` (DBQuery JSON branch ~line 96-105; delete `printEntryRowJson` at 226-237; keep `jsonEscape` where it is — `Render.hs` gets its own copy so the executable keeps compiling for `printSearchRowJson`)

**Interfaces:**
- Produces (consumed by Task 2's parser): JSON lines of shape
  `{"id":"…","title":"…","keyword":"TODO"|null,"depth":2,"file":"todo.org"}` — `file` present whenever the files row resolves; relative to the collection root (same convention `db search` uses today).
- Produces (library): `Org.DB.Render.entryRowJson :: Maybe Text -> EntryRow -> Text`.

- [ ] **Step 1: Write the failing test**

`/Users/johnw/src/org-jw/org-db/test/RenderTest.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module RenderTest (tests) where

import qualified Data.Text as T
import Org.DB.Render
import Org.DB.Types
import Test.Tasty
import Test.Tasty.HUnit

sampleRow :: EntryRow
sampleRow =
  EntryRow
    { erId = "abc-123"
    , erFileId = "file-1"
    , erParentId = Nothing
    , erDepth = 2
    , erPosition = 0
    , erByteOffset = 42
    , erKeywordType = Just "open"
    , erKeywordValue = Just "TODO"
    , erPriority = Nothing
    , erHeadline = "TODO A \"quoted\" title"
    , erTitle = "A \"quoted\" title"
    , erVerb = Nothing
    , erContext = Nothing
    , erLocator = Nothing
    , erHash = Nothing
    , erModTime = Nothing
    , erCreatedTime = Nothing
    , erPath = Nothing
    }

tests :: TestTree
tests =
  testGroup
    "Org.DB.Render"
    [ testCase "emits file field when path known" $
        assertBool "file present" ("\"file\":\"todo.org\"" `T.isInfixOf` entryRowJson (Just "todo.org") sampleRow)
    , testCase "omits file field when path unknown" $
        assertBool "no file field" (not ("\"file\"" `T.isInfixOf` entryRowJson Nothing sampleRow))
    , testCase "keeps existing fields" $
        assertBool "id+depth" (("\"id\":\"abc-123\"" `T.isInfixOf` out) && ("\"depth\":2" `T.isInfixOf` out))
    , testCase "escapes quotes in title" $
        assertBool "escaped" ("\\\"quoted\\\"" `T.isInfixOf` out)
    ]
 where
  out = entryRowJson Nothing sampleRow
```

Register it: in `org-db/test/Spec.hs` add `import qualified RenderTest` and add `RenderTest.tests` to the `testGroup "org-db"` list. In `org-db/package.yaml`, add `Org.DB.Render` under the library's `exposed-modules` and `RenderTest` under the test suite's `other-modules`, then regenerate the cabal file with `hpack` (available in the flake dev shell: `nix develop` at the repo root if not on PATH).

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/johnw/src/org-jw && hpack org-db && cabal build org-db 2>&1 | tail -5
```
Expected: FAIL — `Org.DB.Render` does not exist.

- [ ] **Step 3: Write the module**

`/Users/johnw/src/org-jw/org-db/src/Org/DB/Render.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure JSON-line renderers for CLI output, kept in the library so they
-- are testable. The executable's per-row IO printers wrap these.
module Org.DB.Render (
  entryRowJson,
  jsonEscapeText,
) where

import Data.Char (isControl, ord)
import Data.Text (Text)
import qualified Data.Text as T
import Org.DB.Types
import Text.Printf (printf)

-- | One JSON-lines object for @db query --format json@. The optional file
-- path is the files-table path for the row's file_id; when unknown the
-- field is omitted rather than emitted as null.
entryRowJson :: Maybe Text -> EntryRow -> Text
entryRowJson mfile row =
  "{\"id\":\""
    <> jsonEscapeText (erId row)
    <> "\",\"title\":\""
    <> jsonEscapeText (erTitle row)
    <> "\",\"keyword\":"
    <> maybe "null" (\k -> "\"" <> jsonEscapeText k <> "\"") (erKeywordValue row)
    <> ",\"depth\":"
    <> T.pack (show (erDepth row))
    <> maybe "" (\f -> ",\"file\":\"" <> jsonEscapeText f <> "\"") mfile
    <> "}"

jsonEscapeText :: Text -> Text
jsonEscapeText = T.concatMap esc
 where
  esc '"' = "\\\""
  esc '\\' = "\\\\"
  esc '\n' = "\\n"
  esc '\r' = "\\r"
  esc '\t' = "\\t"
  esc c
    | isControl c = T.pack (printf "\\u%04x" (ord c))
    | otherwise = T.singleton c
```

(Do not try to import the executable's `jsonEscape`; the dependency direction is library ← executable.)

- [ ] **Step 4: Run test to verify it passes**

```sh
cd /Users/johnw/src/org-jw && cabal test org-db 2>&1 | tail -5
```
Expected: PASS including the four `Org.DB.Render` cases.

- [ ] **Step 5: Wire the executable**

In `/Users/johnw/src/org-jw/org-jw/bin/DB/Exec.hs`:

1. Add imports: `import Org.DB.Render (entryRowJson)` and `import Data.List (nub)` (check the existing import list first; `Data.Map` may not be needed — an alist suffices).
2. Replace the `JsonFormat -> mapM_ printEntryRowJson limited` arm of the `DBQuery` case (currently ~line 105) with:

```haskell
        JsonFormat -> do
          let fileIds = nub (map erFileId limited)
          pathPairs <-
            mapM (\fid -> (,) fid <$> queryFilePath db fid) fileIds
          let pathFor fid = maybe Nothing id (lookup fid pathPairs)
          mapM_
            (\row -> TIO.putStrLn (entryRowJson (pathFor (erFileId row)) row))
            limited
```

3. Delete the now-unused `printEntryRowJson` (lines 226-237). `queryFilePath` is already imported for `printSearchRowJson`. One files-table lookup per *distinct* file, not per row.

- [ ] **Step 6: Build, test, and smoke**

```sh
cd /Users/johnw/src/org-jw && cabal build org-jw org-db && cabal test org-db 2>&1 | tail -3
```
Expected: build clean, tests PASS. Optional live smoke (needs the DSN; skip if unavailable):

```sh
org --config ~/org/org.yaml db --db-url "$ORG_DB_URL" query \
  --ql '(property "NEXT_REVIEW")' --format json 2>/dev/null | head -2
```
Expected: each line contains `"file":"…"`.

- [ ] **Step 7: Commit (in org-jw)**

```sh
cd /Users/johnw/src/org-jw && git add org-db/src/Org/DB/Render.hs org-db/test/RenderTest.hs \
  org-db/test/Spec.hs org-db/package.yaml org-db/org-db.cabal org-jw/bin/DB/Exec.hs
git commit -m "org db: Emit file path in query --format json rows"
```

---

### Task 2: `org-db-cli.el` — the CLI bridge

**Files:**
- Create: `/Users/johnw/src/dot-emacs/lisp/org-db-cli.el`
- Test: `/Users/johnw/src/dot-emacs/lisp/org-db-cli-test.el`

**Interfaces:**
- Produces: `org-db-cli-available-p` → non-nil when executable+config+db-url are all configured; `org-db-cli-query-files (skeleton-string)` → list of absolute file names, or nil (with a `message`) on any failure — **never signals**. Defcustoms: `org-db-cli-executable` (string, default `"org"`), `org-db-cli-config-file`, `org-db-cli-db-url`, `org-db-cli-files-directory` (nil ⇒ `org-directory`).

- [ ] **Step 1: Write the failing tests**

`/Users/johnw/src/dot-emacs/lisp/org-db-cli-test.el`:

```elisp
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
```

- [ ] **Step 2: Run to verify failure**

```sh
"$EMACS" -batch -L . -l org-db-cli-test.el --eval '(ert-run-tests-batch-and-exit "org-db-cli-")'
```
Expected: FAIL — `Cannot open load file: org-db-cli`.

- [ ] **Step 3: Implement**

`/Users/johnw/src/dot-emacs/lisp/org-db-cli.el`:

```elisp
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
```

- [ ] **Step 4: Run tests to verify pass**

Same command as Step 2. Expected: 4 PASS.

- [ ] **Step 5: Byte-compile clean, commit**

```sh
"$EMACS" -batch -L . -f batch-byte-compile org-db-cli.el 2>&1 | grep -i warning ; \
cd /Users/johnw/src/dot-emacs && git add lisp/org-db-cli.el lisp/org-db-cli-test.el && \
git commit -m "org-db-cli: New bridge to the org-jw db CLI"
```
Expected: no warnings printed before the commit line.

---

### Task 3: `org-agents.el` — the `$PROP` expander

**Files:**
- Create: `/Users/johnw/src/dot-emacs/lisp/org-agents.el` (header + expander section)
- Test: `/Users/johnw/src/dot-emacs/lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-agents--expand (form)` → an org-ql-valid query sexp; pure, no buffer access. Ref syntax: `$NAME` (value/boolean per position), `$NAME*` (inherited, residual), name-position substitution inside `(property …)` and `(property-ts …)`. Specials `$ITEM $TODO $PRIORITY $TAGS $CATEGORY $LEVEL $FILE`. Also `org-agents--ref-p (sym)` → `(NAME . INHERITP)` or nil, and `org-agents--nested-query-heads` = `(parent ancestors children descendants)` (shared with Tasks 4–5).

- [ ] **Step 1: Write the failing tests** (start `org-agents-test.el`)

```elisp
;;; org-agents-test.el --- Tests for org-agents -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

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

(ert-deftest org-agents-test-expand-passthrough ()
  (should (equal (org-agents--expand '(and (todo "TODO") (tags "urgent")))
                 '(and (todo "TODO") (tags "urgent")))))

(provide 'org-agents-test)
;;; org-agents-test.el ends here
```

- [ ] **Step 2: Verify failure** — run the ERT template with pattern `"org-agents-test-expand"`. Expected: `Cannot open load file: org-agents`.

- [ ] **Step 3: Implement the expander**

Create `org-agents.el` with the standard header (Author John Wiegley, `Package-Requires: ((emacs "29.1") (org-ql "0.8"))`, Commentary summarizing the spec's Purpose paragraph and pointing at the spec path), `(require 'cl-lib) (require 'org) (require 'org-ql) (require 'org-ql-ext) (require 'org-db-cli)`, then:

```elisp
(defconst org-agents--nested-query-heads '(parent ancestors children descendants)
  "org-ql predicates whose argument is itself a query.")

(defconst org-agents--boolean-heads '(and or not when unless))

(defconst org-agents--name-position-heads '(property property-ts)
  "Predicates whose first argument is a property NAME; a $ref there
denotes the name string, not the value.")

(defconst org-agents--numeric-heads '(< > <= >= = + - * /))

(defconst org-agents--specials
  '(("ITEM" . (org-get-heading t t t t))
    ("TODO" . (org-get-todo-state))
    ("PRIORITY" . (org-entry-get nil "PRIORITY"))
    ("TAGS" . (org-get-tags))
    ("CATEGORY" . (org-get-category))
    ("LEVEL" . (org-current-level))
    ("FILE" . (buffer-file-name)))
  "Accessor forms for $SPECIAL references.")

(defun org-agents--ref-p (form)
  "If FORM is a $ref symbol, return (NAME . INHERITP); else nil."
  (when (and (symbolp form)
             (string-prefix-p "$" (symbol-name form))
             (> (length (symbol-name form)) 1))
    (let* ((name (substring (symbol-name form) 1))
           (inherit (string-suffix-p "*" name)))
      (cons (if inherit (substring name 0 -1) name) inherit))))

(defun org-agents--known-predicate-p (head)
  "Non-nil if HEAD names an org-ql predicate (built-in or user-defined)."
  (and (symbolp head)
       (or (assq head org-ql-predicates)
           ;; org-ql-predicates keys by main name; also check aliases.
           (cl-some (lambda (pred)
                      (memq head (plist-get (cdr pred) :aliases)))
                    org-ql-predicates))))

(defun org-agents--value-ref (ref &optional numeric)
  "Accessor form for REF (from `org-agents--ref-p') in value position."
  (let* ((name (car ref))
         (special (cdr (assoc name org-agents--specials)))
         (base (cond (special special)
                     ((cdr ref) `(org-entry-get nil ,name t))
                     (t `(org-entry-get nil ,name)))))
    (cond ((and numeric special) base)     ; specials manage their own types
          (numeric `(string-to-number (or ,base "0")))
          (special base)
          (t `(or ,base "")))))

(defun org-agents--expand-residual (form numeric)
  "Rewrite $refs in residual Lisp FORM.  NUMERIC applies to direct args."
  (cond
   ((org-agents--ref-p form)
    (org-agents--value-ref (org-agents--ref-p form) numeric))
   ((consp form)
    (let ((n (memq (car form) org-agents--numeric-heads)))
      (cons (car form)
            (mapcar (lambda (arg) (org-agents--expand-residual arg n))
                    (cdr form)))))
   (t form)))

(defun org-agents--expand (form)
  "Expand $PROP references in query FORM, yielding a plain org-ql query."
  (cond
   ;; Bare $ref in boolean position.
   ((org-agents--ref-p form)
    (let ((ref (org-agents--ref-p form)))
      (if (cdr ref)                         ; inherited: residual accessor
          `(org-entry-get nil ,(car ref) t)
        `(property ,(car ref)))))
   ((not (consp form)) form)
   ;; Boolean combinators: recurse into every clause.
   ((memq (car form) org-agents--boolean-heads)
    (cons (car form) (mapcar #'org-agents--expand (cdr form))))
   ;; Nested-query predicates: recurse into the query argument.
   ((memq (car form) org-agents--nested-query-heads)
    (cons (car form) (mapcar #'org-agents--expand (cdr form))))
   ;; Name-position predicates: first arg $ref becomes the NAME string.
   ((memq (car form) org-agents--name-position-heads)
    (let ((args (cdr form)))
      (cons (car form)
            (cons (if (org-agents--ref-p (car args))
                      (car (org-agents--ref-p (car args)))
                    (car args))
                  (cdr args)))))
   ;; Any other known predicate: pass through untouched.
   ((org-agents--known-predicate-p (car form)) form)
   ;; Residual Lisp: rewrite refs with coercion.
   (t (org-agents--expand-residual form nil))))
```

Note the value-position rule expands to `(or (org-entry-get nil "P") "")` — the spec's "the property's string value" with a nil-guard so `string-match` on an absent property tests false instead of signaling. (The spec's illustrative `(org-entry-get nil "PROP")` is updated to match.)

- [ ] **Step 4: Verify pass** — ERT pattern `"org-agents-test-expand"`. Expected: 8 PASS. If `org-ql-predicates` entries don't carry `:aliases` in this version, adapt `org-agents--known-predicate-p` to the actual alist shape (inspect `(car org-ql-predicates)` in batch) — the tests define the contract, not the shape.

- [ ] **Step 5: Commit**

```sh
cd /Users/johnw/src/dot-emacs && git add lisp/org-agents.el lisp/org-agents-test.el && \
git commit -m "org-agents: New package with the \$PROP query expander"
```

---

### Task 4: The whole-query gate

**Files:**
- Modify: `lisp/org-agents.el` (gate section)
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-agents--gate (query &optional context)` → t when QUERY may run; signals `user-error` for CLI-only spellings; prompts (honoring `org-ql-ask-unsafe-queries`) for structurally unsafe queries, memoizing approval in `org-agents--session-approved` and optionally `org-agents-safe-queries` (defcustom list of sha1 strings). In `noninteractive` or when CONTEXT is `batch`, unsafe+unapproved ⇒ returns nil (caller skips the agent with a message). Also `org-agents--structurally-safe-p (query)`.

- [ ] **Step 1: Failing tests**

```elisp
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
        (query '(and (todo) (string-match "x" (or (org-entry-get nil "URL") "")))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (org-agents--gate query)))
    ;; Second call: memoized, no prompt.
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not re-prompt"))))
      (should (org-agents--gate query)))))

(ert-deftest org-agents-test-gate-rejects-cli-only-spelling ()
  (should-error (org-agents--gate '(headline "foo")) :type 'user-error))

(ert-deftest org-agents-test-gate-master-switch-off ()
  (let ((org-ql-ask-unsafe-queries nil)
        (org-agents--session-approved (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "must not prompt"))))
      (should (org-agents--gate '(ignore))))))
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-gate"`. Expected: void-function `org-agents--gate`.

- [ ] **Step 3: Implement**

```elisp
(defcustom org-agents-safe-queries nil
  "List of sha1 hashes of queries approved to run without prompting.
Managed like `safe-local-variable-values': approving a query
interactively offers to persist its hash here."
  :type '(repeat string) :group 'org-agents)

(defvar org-agents--session-approved (make-hash-table :test 'equal)
  "Query hashes approved for this session only.")

(defconst org-agents--cli-only-heads
  '((headline . heading) (re . regexp) (p . priority))
  "CLI grammar spellings that are not valid org-ql, with replacements.")

(defun org-agents--structurally-safe-p (form)
  "Non-nil if FORM consists solely of known predicates and combinators."
  (cond
   ((not (consp form)) t)                  ; literals as arguments
   ((memq (car form) org-agents--boolean-heads)
    (cl-every #'org-agents--structurally-safe-p (cdr form)))
   ((memq (car form) org-agents--nested-query-heads)
    (cl-every #'org-agents--structurally-safe-p (cdr form)))
   ((org-agents--known-predicate-p (car form)) t)
   (t nil)))

(defun org-agents--check-spelling (form)
  "Signal `user-error' if FORM uses a CLI-only predicate spelling."
  (when (consp form)
    (when-let* ((fix (alist-get (car form) org-agents--cli-only-heads)))
      (user-error "org-agents: `%s' is CLI-only syntax; use `%s'"
                  (car form) fix))
    (when (memq (car form)
                (append org-agents--boolean-heads
                        org-agents--nested-query-heads))
      (mapc #'org-agents--check-spelling (cdr form)))))

(defun org-agents--query-hash (query)
  (sha1 (prin1-to-string query)))

(defun org-agents--gate (query &optional context)
  "Return non-nil when QUERY may be evaluated.
Structurally safe queries always pass.  Unsafe queries pass when
`org-ql-ask-unsafe-queries' is nil, when previously approved, or when
the user confirms; in `noninteractive' (or CONTEXT `batch') they are
skipped instead of prompting."
  (org-agents--check-spelling query)
  (or (org-agents--structurally-safe-p query)
      (not org-ql-ask-unsafe-queries)
      (let ((hash (org-agents--query-hash query)))
        (or (gethash hash org-agents--session-approved)
            (member hash org-agents-safe-queries)
            (if (or noninteractive (eq context 'batch))
                (progn
                  (message "org-agents: skipping unapproved query %S" query)
                  nil)
              (when (yes-or-no-p
                     (format "Query contains arbitrary Lisp: %S — run it? "
                             query))
                (puthash hash t org-agents--session-approved)
                (when (yes-or-no-p "Remember this approval permanently? ")
                  (customize-save-variable
                   'org-agents-safe-queries
                   (cons hash org-agents-safe-queries)))
                t))))))
```

- [ ] **Step 4: Verify pass** — pattern `"org-agents-test-gate"`. Expected: 5 PASS.
- [ ] **Step 5: Commit** — `git commit -m "org-agents: Gate whole queries before evaluation"` (add both files).

---

### Task 5: Soundness table and skeleton splitter

**Files:**
- Modify: `lisp/org-agents.el` (splitter section)
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-agents--skeleton (expanded-query &optional scope-conjunct)` → CLI sexp *string* (via `prin1-to-string`) or nil when no conjunct pushes. SCOPE-CONJUNCT is a ready CLI form like `(path "positron/")` appended by Task 6. Push-down classes live in `org-agents--pushdown-fns`.

- [ ] **Step 1: Failing tests**

```elisp
(ert-deftest org-agents-test-skeleton-property-exists ()
  (should (equal (org-agents--skeleton '(and (todo) (property "NEXT_REVIEW")))
                 "(property \"NEXT_REVIEW\")")))

(ert-deftest org-agents-test-skeleton-property-ts-implies-exists ()
  (should (equal (org-agents--skeleton
                  '(and (todo) (property-ts "NEXT_REVIEW" :to today)))
                 "(property \"NEXT_REVIEW\")")))

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
    (should (equal (org-agents--skeleton '(property "STYLE" "habit"))
                   "(property \"STYLE\" \"habit\")"))
    ;; Inheriting names: only existence is safe.
    (should (equal (org-agents--skeleton '(property "OVERLAY" "x"))
                   "(property \"OVERLAY\")"))
    (let ((org-use-property-inheritance t))
      (should (equal (org-agents--skeleton '(property "STYLE" "habit"))
                     "(property \"STYLE\")")))))

(ert-deftest org-agents-test-skeleton-nested-queries-residual ()
  (should (null (org-agents--skeleton '(parent (property "X")))))
  (should (null (org-agents--skeleton '(descendants (todo))))))

(ert-deftest org-agents-test-skeleton-multiple-conjuncts-and-scope ()
  (should (equal (org-agents--skeleton
                  '(and (property "URL") (scheduled :to 7) (todo))
                  '(path "positron/"))
                 "(and (property \"URL\") (scheduled :to 7) (path \"positron/\"))")))

(ert-deftest org-agents-test-skeleton-no-ts-structs ()
  "Serialization must come from the pre-normalization sexp."
  (let ((s (org-agents--skeleton '(and (scheduled :to 7) (property "X")))))
    (should-not (string-match-p "#s(" s))))
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-skeleton"`.

- [ ] **Step 3: Implement**

```elisp
;; Each classifier returns the CLI conjunct to push (a sexp), or nil.
;; A row may only push a conjunct that is a SUPERSET of the org-ql
;; predicate's matches — the prefilter narrows files; org-ql decides.
;; Divergence evidence: docs/superpowers/specs/2026-08-18-org-agents-design-review.md C1.
(defconst org-agents--literal-regexp "[][*+?^$\\.{}|]"
  "Characters that make a string a regexp rather than a literal.")

(defun org-agents--property-inherits-p (name)
  (pcase org-use-property-inheritance
    ('nil nil)
    ('t t)
    ((pred listp) (member name org-use-property-inheritance))
    ((pred stringp) (string-match-p org-use-property-inheritance name))))

(defun org-agents--date-arg-ok-p (plist)
  "Non-nil when PLIST holds only :from/:to/:on with CLI-safe values."
  (cl-loop for (k v) on plist by #'cddr
           always (and (memq k '(:from :to :on))
                       (or (integerp v) (eq v 'today)
                           (and (stringp v)
                                (string-match-p
                                 "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" v))))))

(defconst org-agents--pushdown-fns
  (list
   (cons 'property
         (lambda (form)
           (pcase form
             (`(property ,(and name (pred stringp)))
              `(property ,name))
             (`(property ,(and name (pred stringp)) ,(and val (pred stringp)))
              (if (org-agents--property-inherits-p name)
                  `(property ,name)        ; equality unsafe when inherited
                `(property ,name ,val)))
             (_ nil))))
   (cons 'property-ts
         (lambda (form)
           (pcase form
             (`(property-ts ,(and name (pred stringp)) . ,_)
              `(property ,name))
             (_ nil))))
   (cons 'scheduled #'org-agents--push-planning)
   (cons 'deadline #'org-agents--push-planning)
   (cons 'closed #'org-agents--push-planning)
   (cons 'heading
         (lambda (form)
           (pcase form
             (`(heading . ,(and strs (guard (cl-every
                                             (lambda (s)
                                               (and (stringp s)
                                                    (not (string-match-p
                                                          org-agents--literal-regexp s))))
                                             strs))))
              ;; DB ORs multiple patterns; OR ⊇ org-ql's AND — superset-safe.
              `(heading ,@strs))
             (_ nil)))))
  "Alist of predicate head → superset-safe CLI conjunct, or nil.")

(defun org-agents--push-planning (form)
  (and (org-agents--date-arg-ok-p (cdr form)) form))

(defun org-agents--skeleton (query &optional scope-conjunct)
  "Extract the CLI prefilter skeleton from expanded QUERY as a string.
Only top-level `and' conjuncts (or the whole query when it is a single
pushable predicate) are considered.  Return nil when nothing pushes and
no SCOPE-CONJUNCT is given."
  (let* ((conjuncts (if (eq (car-safe query) 'and) (cdr query) (list query)))
         (pushed
          (delq nil
                (mapcar (lambda (c)
                          (when-let* ((fn (alist-get (car-safe c)
                                                     org-agents--pushdown-fns)))
                            (funcall fn c)))
                        conjuncts)))
         (all (append pushed (and scope-conjunct (list scope-conjunct)))))
    (when pushed                     ; scope alone is not worth a round trip
      (prin1-to-string
       (if (cdr all) (cons 'and all) (car all))))))
```

- [ ] **Step 4: Verify pass** — pattern `"org-agents-test-skeleton"`. Expected: 9 PASS.
- [ ] **Step 5: Commit** — `git commit -m "org-agents: Superset-safe push-down skeleton"`.

---

### Task 6: Agent reading, scope resolution, and match collection

**Files:**
- Modify: `lisp/org-agents.el`
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-agents--read-agent ()` → plist `(:query SEXP :view SYM :scope VAL :sort VAL :limit INT-or-nil :columns STRING-or-nil :format STRING-or-nil :marker MARKER)` from the entry at point (`user-error` on missing/unreadable query). `org-agents--collect (agent)` → list of org-element headlines *with markers*, sorted and limited; applies `org-agents-exclude` and self-skip; resolves scope per spec (corpus scopes demand a prefilter). Defcustoms `org-agents-exclude` (default `'(not (property "AGENT_MATCH"))`) and `org-agents-files` (default `'("~/org/agents.org")`).

- [ ] **Step 1: Failing tests** (fixture helpers included — real files, no DB)

```elisp
(defmacro org-agents-test--with-corpus (&rest body)
  "Run BODY with `dir' bound to a temp corpus of two org files and
`agent-file' bound to a file containing one agent entry."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "org-agents-corpus" t))
          (a (expand-file-name "a.org" dir))
          (b (expand-file-name "b.org" dir))
          (agent-file (expand-file-name "agents.org" dir)))
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
       (delete-directory dir t))))

(ert-deftest org-agents-test-read-agent ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (org-agents--read-agent)))
        (should (equal (plist-get agent :query)
                       '(and (todo) (property "NEXT_REVIEW"))))
        (should (eq (plist-get agent :view) 'children))
        (should (markerp (plist-get agent :marker)))))))

(ert-deftest org-agents-test-collect-applies-exclusion-and-todo ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let* ((agent (org-agents--read-agent))
             (matches (org-agents--collect agent)))
        (should (= 1 (length matches)))
        (should (equal (org-element-property :raw-value (car matches))
                       "Fix widget"))))))

(ert-deftest org-agents-test-collect-corpus-scope-needs-prefilter ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (plist-put (org-agents--read-agent) :scope 'active)))
        (cl-letf (((symbol-function 'org-db-cli-available-p) #'ignore))
          (should-error (org-agents--collect agent) :type 'user-error))))))

(ert-deftest org-agents-test-collect-prefilter-intersects ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (let ((agent (plist-put (org-agents--read-agent) :scope 'active))
            (queried nil))
        (cl-letf (((symbol-function 'org-db-cli-available-p) (lambda () t))
                  ((symbol-function 'org-db-cli-query-files)
                   (lambda (skel) (setq queried skel) (list a)))
                  ((symbol-function 'org-agents--scope-base-files)
                   (lambda (_scope) (list a b))))
          (let ((matches (org-agents--collect agent)))
            (should (string-match-p "NEXT_REVIEW" queried))
            (should (= 1 (length matches)))))))))
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-\\(read\\|collect\\)"`.

- [ ] **Step 3: Implement**

```elisp
(defcustom org-agents-exclude '(not (property "AGENT_MATCH"))
  "Conjunct appended to every agent query and to previews.
Keeps agents from matching generated aliases.  Appended last so cheap
predicates short-circuit first; applied only on the Emacs side, never
in the database skeleton."
  :type 'sexp :group 'org-agents)

(defcustom org-agents-files '("~/org/agents.org")
  "Where `org-agents-update-all' looks for agents.
A list of files and directories, or the symbol `agenda'."
  :type '(choice (const agenda) (repeat file)) :group 'org-agents)

(defun org-agents--read-agent ()
  "Read the agent entry at point into a plist."
  (let ((q (org-entry-get nil "AGENT_QUERY")))
    (unless q (user-error "No :AGENT_QUERY: at point"))
    (let ((query (condition-case err (car (read-from-string q))
                   (error (user-error "org-agents: unreadable query %s: %s"
                                      q (error-message-string err))))))
      (list :query (org-agents--expand query)
            :view (intern (or (org-entry-get nil "AGENT_VIEW") "children"))
            :scope (let ((s (org-entry-get nil "AGENT_SCOPE")))
                     (cond ((null s) 'agenda)
                           ((string-prefix-p "(" s) (car (read-from-string s)))
                           (t (intern s))))
            :sort (when-let* ((s (org-entry-get nil "AGENT_SORT")))
                    (car (read-from-string s)))
            :limit (when-let* ((l (org-entry-get nil "AGENT_LIMIT")))
                     (string-to-number l))
            :columns (org-entry-get nil "AGENT_COLUMNS")
            :format (org-entry-get nil "AGENT_FORMAT")
            :marker (point-marker)))))

(defun org-agents--scope-base-files (scope)
  "Files named by SCOPE, before any prefilter."
  (pcase scope
    ('agenda (org-agenda-files))
    ('active (directory-files-recursively
              org-directory "\\.org\\'" nil
              (lambda (d) (not (string-match-p "/archive\\'" d)))))
    ('all (directory-files-recursively org-directory "\\.org\\'"))
    ((pred stringp) (directory-files-recursively
                     (expand-file-name scope org-directory) "\\.org\\'"))
    ((pred listp) (mapcar #'expand-file-name scope))
    (_ (user-error "org-agents: bad scope %S" scope))))

(defun org-agents--corpus-scope-p (scope)
  (memq scope '(active all)))

(defun org-agents--scope-conjunct (scope)
  "CLI path conjunct for directory scopes, else nil."
  (when (stringp scope) `(path ,(file-name-as-directory scope))))

(defun org-agents--scope-files (agent)
  "Resolve AGENT's scope to files, applying the DB prefilter when possible."
  (let* ((scope (plist-get agent :scope))
         (skeleton (org-agents--skeleton (plist-get agent :query)
                                         (org-agents--scope-conjunct scope)))
         (base (org-agents--scope-base-files scope))
         (candidates (and skeleton
                          (org-db-cli-available-p)
                          (org-db-cli-query-files skeleton))))
    (cond
     (candidates (cl-intersection base candidates :test #'equal))
     ((org-agents--corpus-scope-p scope)
      (user-error
       "org-agents: scope `%s' needs the database prefilter (skeleton %s, cli %s)"
       scope (if skeleton "ok" "empty")
       (if (org-db-cli-available-p) "failed" "unconfigured")))
     (t base))))

(defun org-agents--collect (agent)
  "Return AGENT's sorted, limited matches as headlines with markers."
  (unless (org-agents--gate (plist-get agent :query))
    (user-error "org-agents: query not approved"))
  (let* ((files (org-agents--scope-files agent))
         (sort (plist-get agent :sort))
         (self (plist-get agent :marker))
         (matches
          (org-ql-select files
            `(and ,(plist-get agent :query) ,org-agents-exclude)
            :action 'element-with-markers
            :sort (and (symbolp sort) sort
                       (memq sort '(date todo priority reverse)) sort)))
         (matches (cl-remove-if
                   (lambda (el)
                     (let ((m (org-element-property :org-hd-marker el)))
                       (and m (eq (marker-buffer m) (marker-buffer self))
                            (= (marker-position m) (marker-position self)))))
                   matches)))
    (if-let* ((limit (plist-get agent :limit)))
        (cl-subseq matches 0 (min limit (length matches)))
      matches)))
```

- [ ] **Step 4: Verify pass** — pattern from Step 2, 4 PASS. (If `org-ql-select`'s marker property is named differently in this version, check `org-ql--add-markers` — `org-ql-semantic.el:588` uses it — and adjust the self-skip accessor; the tests define behavior.)
- [ ] **Step 5: Commit** — `git commit -m "org-agents: Scope resolution and match collection"`.

---

### Task 7: Link builder and the children view

**Files:**
- Modify: `lisp/org-agents.el`
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-agents--link-to (element)` → org link string built at the match's live heading (id-preferred, `org-id-add-location` called; file+heading-search fallback; description via `org-link-make-string`); `org-agents--render-children (agent matches)` → replaces pristine `AGENT_MATCH` children under the agent, preserves annotated ones (marking vanished ones `(stale)`), returns the match count.

- [ ] **Step 1: Failing tests**

```elisp
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
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-\\(link\\|children\\)"`.

- [ ] **Step 3: Implement**

```elisp
(defun org-agents--link-to (element)
  "Return an Org link to ELEMENT's heading, built at the live heading."
  (let ((m (org-element-property :org-hd-marker element)))
    (with-current-buffer (marker-buffer m)
      (org-with-wide-buffer
       (goto-char m)
       (let* ((title (org-get-heading t t t t))
              (id (org-id-get)))
         (if id
             (progn (org-id-add-location id (buffer-file-name))
                    (org-link-make-string (concat "id:" id) title))
           (org-link-make-string
            (concat "file:" (buffer-file-name)
                    "::*" (org-link-heading-search-string))
            title)))))))

(defun org-agents--format-suffix (element format-props)
  "Property values named by FORMAT-PROPS at ELEMENT's heading."
  (when format-props
    (let ((m (org-element-property :org-hd-marker element)))
      (with-current-buffer (marker-buffer m)
        (org-with-wide-buffer
         (goto-char m)
         (mapconcat (lambda (p) (or (org-entry-get nil p) ""))
                    (split-string format-props) "  "))))))

(defun org-agents--child-pristine-p ()
  "Non-nil when the child at point is exactly a generated alias:
heading, property drawer, nothing else."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (forward-line 1)
      (and (looking-at-p ":PROPERTIES:")
           (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
           (progn (forward-line 1)
                  (>= (point) end))))))

(defun org-agents--render-children (agent matches)
  "Replace AGENT's generated children with MATCHES; return match count."
  (let* ((marker (plist-get agent :marker))
         (kept-targets nil)
         (links (mapcar (lambda (el)
                          (cons (org-agents--link-to el)
                                (org-agents--format-suffix
                                 el (plist-get agent :format))))
                        matches)))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (org-back-to-heading t)
       (let ((level (org-current-level))
             (subtree-end (save-excursion (org-end-of-subtree t t) (point))))
         ;; Pass 1: delete pristine aliases; keep and mark annotated ones.
         (while (re-search-forward
                 (format "^\\*\\{%d\\} " (1+ level)) subtree-end t)
           (beginning-of-line)
           (if (not (equal (org-entry-get nil "AGENT_MATCH") "t"))
               (org-end-of-subtree t t)
             (if (org-agents--child-pristine-p)
                 (let ((beg (point)))
                   (org-end-of-subtree t t)
                   (delete-region beg (point))
                   (setq subtree-end (- subtree-end (- (point) beg))
                         subtree-end (max subtree-end (point))))
               ;; Annotated: keep; record its link target; mark stale if gone.
               (let ((heading (org-get-heading t t t t)))
                 (push heading kept-targets)
                 (unless (or (cl-find heading links
                                      :key (lambda (l)
                                             (and (string-match
                                                   org-link-bracket-re (car l))
                                                  (match-string 2 (car l))))
                                      :test #'equal)
                             (string-suffix-p "(stale)" heading))
                   (org-edit-headline (concat heading " (stale)")))
                 (org-end-of-subtree t t))))
           (setq subtree-end (save-excursion
                               (goto-char marker) (org-back-to-heading t)
                               (org-end-of-subtree t t) (point))))
         ;; Pass 2: append children for matches not represented by kept aliases.
         (goto-char marker)
         (org-back-to-heading t)
         (org-end-of-subtree t t)
         (unless (bolp) (insert "\n"))
         (dolist (link links)
           (let ((desc (and (string-match org-link-bracket-re (car link))
                            (match-string 2 (car link)))))
             (unless (member desc kept-targets)
               (insert (make-string (1+ level) ?*) " " (car link))
               (when (and (cdr link) (not (string-empty-p (cdr link))))
                 (insert "  " (cdr link)))
               (insert "\n:PROPERTIES:\n:AGENT_MATCH: t\n:END:\n")))))))
    (length matches)))
```

- [ ] **Step 4: Verify pass** — 3 PASS. This is the fiddliest buffer code in the plan; if position bookkeeping in pass 1 proves fragile, restructure to collect `(beg . end)` regions first and delete back-to-front — the tests define the observable behavior.
- [ ] **Step 5: Commit** — `git commit -m "org-agents: Children view with annotation preservation"`.

---

### Task 8: Dynamic block — list and table views

**Files:**
- Modify: `lisp/org-agents.el`
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces: `org-dblock-write:org-agents (params)` — reads the enclosing entry's agent properties, inline PARAMS override (`:query STRING`, `:view`, `:columns`, `:sort`, `:limit`, `:format`, `:scope`); gates inline queries; renders list or table; on *any* error reinstates `(plist-get params :content)` and re-signals as `message`. Table: first column `ITEM_BY_ID` = link; sort `(column N)`/`(ts-column N)` 1-indexed over columns.

- [ ] **Step 1: Failing tests**

```elisp
(defmacro org-agents-test--with-dblock-agent (view extra &rest body)
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

(ert-deftest org-agents-test-dblock-list ()
  (org-agents-test--with-dblock-agent "list" ":AGENT_FORMAT: NEXT_REVIEW\n"
    (org-dblock-update)
    (should (string-match-p "^- \\[\\[id:11111111-.*Fix widget\\]\\]  \\[2020-01-01 Wed\\]"
                            (buffer-string)))))

(ert-deftest org-agents-test-dblock-table ()
  (org-agents-test--with-dblock-agent "table"
      ":AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW\n"
    (org-dblock-update)
    (let ((s (buffer-string)))
      (should (string-match-p "| *ITEM_BY_ID *| *NEXT_REVIEW *|" s))
      (should (string-match-p "Fix widget" s)))))

(ert-deftest org-agents-test-dblock-error-restores-content ()
  (org-agents-test--with-dblock-agent "list" ""
    ;; Seed the block with prior content, then force a failure.
    (org-dblock-update)
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'org-agents--collect)
                 (lambda (&rest _) (error "boom"))))
        (org-dblock-update))
      (should (equal (buffer-string) before)))))
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-dblock"`.

- [ ] **Step 3: Implement**

```elisp
(defun org-agents--table-cell (s)
  "Escape S for use inside an Org table cell."
  (replace-regexp-in-string "|" "\\\\vert{}" (or s "")))

(defun org-agents--table-rows (matches columns)
  "Rows (lists of strings) for MATCHES over the COLUMNS name list."
  (mapcar
   (lambda (el)
     (let ((m (org-element-property :org-hd-marker el)))
       (with-current-buffer (marker-buffer m)
         (org-with-wide-buffer
          (goto-char m)
          (mapcar (lambda (col)
                    (org-agents--table-cell
                     (if (equal col "ITEM_BY_ID")
                         (org-agents--link-to el)
                       (or (org-entry-get nil col) ""))))
                  columns)))))
   matches))

(defun org-agents--sort-rows (rows sort)
  "Sort table ROWS by SORT — (column N) or (ts-column N), 1-indexed."
  (pcase sort
    (`(column ,n)
     (sort rows (lambda (x y) (string< (nth (1- n) x) (nth (1- n) y)))))
    (`(ts-column ,n)
     (sort rows
           (lambda (x y)
             (let ((tx (ignore-errors
                         (org-time-string-to-seconds (nth (1- n) x))))
                   (ty (ignore-errors
                         (org-time-string-to-seconds (nth (1- n) y)))))
               (cond ((and tx ty) (< tx ty)) (tx t) (t nil))))))
    (_ rows)))

;;;###autoload
(defun org-dblock-write:org-agents (params)
  "Write the list or table view for the enclosing (or inline) agent."
  (let ((content (plist-get params :content))
        (insert-point (point)))
    (condition-case err
        (let* ((agent (save-excursion
                        (if (plist-get params :query)
                            ;; Standalone block: params are the agent.
                            (list :query (org-agents--expand
                                          (car (read-from-string
                                                (plist-get params :query))))
                                  :view (or (plist-get params :view) 'list)
                                  :scope (or (plist-get params :scope) 'agenda)
                                  :sort (plist-get params :sort)
                                  :limit (plist-get params :limit)
                                  :columns (plist-get params :columns)
                                  :format (plist-get params :format)
                                  :marker (point-marker))
                          (org-back-to-heading t)
                          (org-agents--read-agent))))
               (matches (org-agents--collect agent))
               (view (plist-get agent :view)))
          (pcase view
            ('table
             (let* ((columns (split-string (or (plist-get agent :columns)
                                               "ITEM_BY_ID")))
                    (rows (org-agents--sort-rows
                           (org-agents--table-rows matches columns)
                           (plist-get agent :sort))))
               (insert "| " (mapconcat #'identity columns " | ") " |\n|-|\n")
               (dolist (row rows)
                 (insert "| " (mapconcat #'identity row " | ") " |\n"))
               (delete-char -1)         ; drop trailing newline for dblock
               (org-table-align)))
            (_                          ; list (default for blocks)
             (dolist (el matches)
               (insert "- " (org-agents--link-to el))
               (when-let* ((suffix (org-agents--format-suffix
                                    el (plist-get agent :format))))
                 (unless (string-empty-p suffix) (insert "  " suffix)))
               (insert "\n"))
             (when matches (delete-char -1))))
          (setq org-agents--last-count (length matches)))
      (error
       (delete-region insert-point (point))
       (when content (insert content))
       (message "org-agents: dblock update failed: %s"
                (error-message-string err))))))

(defvar org-agents--last-count nil
  "Match count from the most recent dblock render, for the caller.")
```

- [ ] **Step 4: Verify pass** — 3 PASS. Note `org-dblock-update` passes `:content`; confirm the parameter name against Org 9.8.7's `org-prepare-dblock` if the restore test fails (some versions only supply `:content` when the block declares `:content` in its header — in that case capture prior content in the writer by reading between block boundaries *before* Org deletes it is impossible, so instead set the block header to include `:content t`… the correct mechanism per Org 9.8.7 is that `org-prepare-dblock` always records `:content`; the test verifies it).
- [ ] **Step 5: Commit** — `git commit -m "org-agents: List and table dynamic block"`.

---

### Task 9: Commands, `AGENT_MATCHED`, update-all, preview

**Files:**
- Modify: `lisp/org-agents.el`
- Modify: `lisp/org-agents-test.el`

**Interfaces:**
- Produces (autoloaded commands): `org-agents-update` (agent or block at point; writes `:AGENT_MATCHED: N [ts]` *after* rendering), `org-agents-update-buffer`, `org-agents-update-all` (over `org-agents-files`; collects per-agent errors, reports a summary, never aborts midway), `org-agents-preview` (reads a query, expands, gates, appends `org-agents-exclude`, delegates to `org-ql-search`).

- [ ] **Step 1: Failing tests**

```elisp
(ert-deftest org-agents-test-update-writes-matched ()
  (org-agents-test--with-corpus
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (org-agents-update)
      (let ((val (org-entry-get nil "AGENT_MATCHED")))
        (should val)
        (should (string-match-p "\\`1 \\[[0-9]\\{4\\}-" val))))))

(ert-deftest org-agents-test-update-all-continues-past-failure ()
  (org-agents-test--with-corpus
    ;; Add a second agent with an unreadable query above the good one.
    (with-current-buffer (find-file-noselect agent-file)
      (goto-char (point-min))
      (insert "* Broken agent\n:PROPERTIES:\n:AGENT_QUERY: (and (todo\n:END:\n")
      (save-buffer))
    (let ((org-agents-files (list agent-file)))
      (org-agents-update-all)
      (with-current-buffer (find-file-noselect agent-file)
        (should (string-match-p ":AGENT_MATCHED: 1" (buffer-string)))))))

(ert-deftest org-agents-test-preview-applies-exclusion ()
  (let (received)
    (cl-letf (((symbol-function 'org-ql-search)
               (lambda (_files query &rest _) (setq received query))))
      (org-agents-preview "(todo)")
      (should (equal received `(and (todo) ,org-agents-exclude))))))
```

- [ ] **Step 2: Verify failure** — pattern `"org-agents-test-\\(update\\|preview\\)"`.

- [ ] **Step 3: Implement**

```elisp
(defun org-agents--write-matched (marker count)
  "Record COUNT and a timestamp on the agent at MARKER."
  (org-with-point-at marker
    (org-entry-put nil "AGENT_MATCHED"
                   (format "%d [%s]" count
                           (format-time-string "%Y-%m-%d %a %H:%M")))))

;;;###autoload
(defun org-agents-update ()
  "Update the agent at point (children view) or its dynamic block."
  (interactive)
  (org-with-wide-buffer
   (org-back-to-heading t)
   (let* ((agent (org-agents--read-agent))
          (marker (plist-get agent :marker))
          (count
           (if (eq (plist-get agent :view) 'children)
               (org-agents--render-children agent (org-agents--collect agent))
             ;; list/table: drive the block machinery, then read the count.
             (let ((end (save-excursion (org-end-of-subtree t t) (point))))
               (unless (re-search-forward "^[ \t]*#\\+BEGIN: org-agents" end t)
                 ;; Create the block on first update.
                 (org-end-of-meta-data t)
                 (insert "#+BEGIN: org-agents\n#+END:\n")
                 (forward-line -2))
               (setq org-agents--last-count nil)
               (org-dblock-update)
               (or org-agents--last-count
                   (user-error "org-agents: block update failed"))))))
     (org-agents--write-matched marker count)
     (message "org-agents: %d match%s" count (if (= count 1) "" "es")))))

;;;###autoload
(defun org-agents-update-buffer ()
  "Update every agent in the current buffer, continuing past failures."
  (interactive)
  (let (failures (updated 0))
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward "^[ \t]*:AGENT_QUERY:" nil t)
       (condition-case err
           (progn (org-agents-update) (cl-incf updated))
         (error (push (cons (line-number-at-pos)
                            (error-message-string err))
                      failures)))
       (outline-next-heading)))
    (message "org-agents: updated %d agent(s)%s" updated
             (if failures (format ", %d failed: %S" (length failures)
                                  (nreverse failures))
               ""))))

;;;###autoload
(defun org-agents-update-all ()
  "Update every agent found via `org-agents-files'."
  (interactive)
  (dolist (f (if (eq org-agents-files 'agenda)
                 (org-agenda-files)
               (cl-loop for entry in org-agents-files
                        for path = (expand-file-name entry)
                        append (if (file-directory-p path)
                                   (directory-files-recursively path "\\.org\\'")
                                 (list path)))))
    (when (file-readable-p f)
      (with-current-buffer (find-file-noselect f)
        (org-agents-update-buffer)))))

;;;###autoload
(defun org-agents-preview (query-string)
  "Preview QUERY-STRING as an agent would evaluate it (the find() analog)."
  (interactive "sAgent query: ")
  (let ((query (org-agents--expand
                (car (read-from-string query-string)))))
    (unless (org-agents--gate query)
      (user-error "org-agents: query not approved"))
    (org-ql-search (org-agenda-files) `(and ,query ,org-agents-exclude))))
```

- [ ] **Step 4: Verify pass** — 3 PASS, then run the FULL suite (`pattern "org-agents-"`) and the org-db-cli suite; all green.
- [ ] **Step 5: Commit** — `git commit -m "org-agents: Update commands, status property, preview"`.

---

### Task 10: Differential suite, byte-compilation, wrap-up

**Files:**
- Modify: `lisp/org-agents-test.el` (differential section)
- Modify: `lisp/org-agents.el` (Commentary finalization only)

**Interfaces:**
- Produces: env-gated differential tests proving the superset property of every push-down row against a real database; a warning-free byte-compile of both packages.

- [ ] **Step 1: Add the DSN-gated differential tests**

```elisp
;; Differential backend-agreement suite.
;; Requires a scratch database and the org CLI:
;;   ORG_AGENTS_TEST_DB_URL=postgresql://…  (a database safe to init/store into)
;;   ORG_AGENTS_TEST_CONFIG=~/org/org.yaml
;;   ORG_AGENTS_TEST_KEYWORDS=~/org/org.dot
;; Skipped otherwise.

(defun org-agents-test--dsn () (getenv "ORG_AGENTS_TEST_DB_URL"))

(defmacro org-agents-test--with-db-corpus (&rest body)
  "Store a small fixture corpus into the scratch DB, bind `dir', run BODY."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "org-agents-diff" t))
          (org-db-cli-config-file (getenv "ORG_AGENTS_TEST_CONFIG"))
          (org-db-cli-db-url (org-agents-test--dsn))
          (org-db-cli-files-directory dir))
     (skip-unless (org-agents-test--dsn))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "d.org" dir)
             (insert "* TODO Alpha\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"
                     "* DONE Beta\n:PROPERTIES:\n:NEXT_REVIEW: [2020-01-01 Wed]\n:END:\n"
                     "* Plain Gamma with Review word\nSCHEDULED: <2020-01-02 Thu>\n"))
           (dolist (cmd (list (list "db" "--db-url" org-db-cli-db-url "unstore")
                              (list "db" "--db-url" org-db-cli-db-url "store"
                                    "--no-embed" (expand-file-name "d.org" dir))))
             (apply #'call-process org-db-cli-executable nil nil nil
                    (append (list "--config" (expand-file-name
                                              org-db-cli-config-file)
                                  "--keywords" (expand-file-name
                                                (getenv "ORG_AGENTS_TEST_KEYWORDS")))
                            cmd)))
           ,@body)
       (delete-directory dir t))))

(ert-deftest org-agents-test-differential-superset ()
  "For every push-down row: candidate files ⊇ org-ql match files."
  (org-agents-test--with-db-corpus
    (dolist (q '((property "NEXT_REVIEW")
                 (property-ts "NEXT_REVIEW" :to today)
                 (scheduled :to today)
                 (heading "Alpha")))
      (let* ((full (org-agents--expand q))
             (skel (org-agents--skeleton full))
             (candidates (org-db-cli-query-files skel))
             (live (delete-dups
                    (mapcar (lambda (el)
                              (buffer-file-name
                               (marker-buffer
                                (org-element-property :org-hd-marker el))))
                            (org-ql-select
                              (directory-files-recursively dir "\\.org\\'")
                              full :action 'element-with-markers)))))
        (should skel)
        (dolist (f live)
          (should (member f candidates)))))))
```

(Adjust the `store` invocation flags to the CLI's actual store options — check `org db store --help`; the fixture intent is: parse with keywords, no embeddings.)

- [ ] **Step 2: Run the unit suite (differential auto-skips without DSN)**

```sh
"$EMACS" -batch -L . -L /Users/johnw/.emacs.d/lisp -l org-db-cli-test.el \
  -l org-agents-test.el --eval '(ert-run-tests-batch-and-exit)'
```
Expected: all PASS, differential SKIPPED unless env is set.

- [ ] **Step 3: Byte-compile both, warning-free**

```sh
cd /Users/johnw/src/dot-emacs/lisp && \
"$EMACS" -batch -L . -L /Users/johnw/.emacs.d/lisp \
  -f batch-byte-compile org-db-cli.el org-agents.el 2>&1 | tee /tmp/oa-bc.log; \
! grep -i warning /tmp/oa-bc.log
```
Expected: no warnings. Fix any (typically: missing `declare-function`, unused lexical vars).

- [ ] **Step 4: Finalize Commentary + run everything once more**

Ensure `org-agents.el`'s Commentary documents: single-line AGENT_QUERY; the property table; the `AGENT_MATCHED` side effects (buffer dirtying, ts-inactive visibility, org-db hash churn); the alias contract (pristine deleted, annotated preserved + `(stale)`, refile caveat); corpus scopes need the DB. Then run the full ERT suite and byte-compile once more.

- [ ] **Step 5: Commit**

```sh
cd /Users/johnw/src/dot-emacs && git add lisp/org-agents.el lisp/org-agents-test.el \
  lisp/org-db-cli.el lisp/org-db-cli-test.el && \
git commit -m "org-agents: Differential suite and byte-compile cleanup"
```

---

## Deferred follow-ups (recorded, not tasks)

From the spec's Scope: `AGENT_ACTION` behind the gate; `AGENT_COPY`; Elisp formats/columns/sorts; `AGENT_ADD_IDS`; db registry discovery; growing the push-down table (todo/done behind a keyword-config probe, tags after an org-jw FILETAGS-aware fix); `(org-db …)` as a general org-ql predicate; migrating `org-ql-semantic.el` onto `org-db-cli`; org-jw: `+` in property identifiers, `--list-predicates`, `LOWER(name)` functional index, migrations before `db query`, Query.hs test coverage; `use-package` block for init.org (the user wires init themselves).

## Self-review notes

- Spec coverage: expander (T3), gate (T4), splitter/table (T5), scope+prefilter+exclusion+markers (T6), children+links+preservation (T7), dblock list/table+content-restore (T8), commands+AGENT_MATCHED-after-render+update-all+preview (T9), differential+byte-compile (T10), org-jw patch (T1), bridge (T2). Spec's "value position" line updated to the nil-guarded form `(or (org-entry-get nil "P") "")` to match T3.
- Types: `org-agents--read-agent` plist keys used consistently across T6–T9; `org-agents--last-count` produced in T8, consumed in T9; marker property `:org-hd-marker` used in T6–T8 (verify against installed org-ql once, in T6 step 4).
