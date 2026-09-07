# Action code: the safety problem, the Emacs precedent, and the real options

Agent C research note. Nothing here is a decision. Everything is checkable: file and line
references are given for every claim about code, and every empirical result was produced by
running the user's own Emacs
(`/nix/store/1jy6wkqyckvs10q661zvpaxx52g97206-emacs-mac-macport-with-packages-30.2.50/bin/emacs`)
against the installed packages.

The one-sentence version: of the four remaining Tinderbox concepts, three declare data and
one is a programming language whose whole point is side effects; org-agents' existing gate
is a good gate for *queries* and is the wrong shape for *actions*, because a query's worst
case is a wrong answer and an action's worst case is a wrong corpus; and the closest prior
art in Emacs (org-edna) solved this by never admitting Lisp from a file at all.

---

## Part 1 — What org-agents' gate does today, exactly

### 1.1 Why a query needs a gate at all

An org-ql sexp query is not interpreted clause by clause with unknown forms discarded. It is
*spliced verbatim into a lambda and byte-compiled*. In
`/nix/store/rk1xmpfp7677259v9l2wl44wqbqsna6c-emacs-org-ql-20250421.133/share/emacs/site-lisp/elpa/org-ql-20250421.133/org-ql.el`
(grep for `defun org-ql--query-predicate`, line 879):

```elisp
(defun org-ql--query-predicate (query)
  "Return predicate function for QUERY."
  (let ((byte-compile-log-warning-function #'org-ql--byte-compile-warning))
    (byte-compile
     `(lambda ()
        (cl-macrolet ((clocked (&key from to on) ...)
                      ...)
          ...
          ,query)))))          ; line 935: the query, verbatim, in tail position
```

Three consequences follow, and the gate's shape is a direct response to each:

1. **Any call anywhere in the sexp executes.** There is no evaluator of org-agents' own to
   restrict. `(and (todo) (shell-command "x"))` contains no `$ref`, is a perfectly ordinary
   `and`, and runs `shell-command` at the first candidate entry. Checking only the head of
   the form is worthless.
2. **A predicate head does not vouch for its arguments.** org-ql's predicates are
   `cl-macrolet` macros and functions whose arguments are ordinary Lisp, so
   `(tags (shell-command "x"))` evaluates the inner call to compute the tag to look for.
3. **It runs once per candidate entry**, i.e. potentially thousands of times over a corpus
   scope, so a slow or destructive body is amplified.

org-ql knows this about itself. `org-ql-ask-unsafe-queries` (org-ql.el line 301) exists for
exactly this reason, defaults to `t`, and — importantly — is declared `:risky t`:

> "Ask before running a query that could run arbitrary code. Org QL queries in sexp form can
> contain arbitrary expressions. When opening an \"org-ql-search:\" link or updating a
> dynamic block that contains a query in sexp form, and this option is non-nil, the user will
> be prompted for confirmation before opening the link. **This variable may be set
> file-locally to disable this warning in files that the user assumes are safe (e.g. of known
> provenance).**"

The prompt it drives (`org-ql--ask-unsafe-query`, org-ql.el line 710) is unconditional and
un-memoized: every sexp query in a dynamic block or `org-ql-search:` link asks, every time.
org-agents' gate is strictly better than that — it distinguishes safe from unsafe by
structure, and it remembers.

*Note for anyone grepping org-ql: the file contains non-UTF-8 bytes, so plain `grep` reports
nothing. Use `grep -a`.*

### 1.2 What `org-agents--structurally-safe-p` admits and refuses

`/Users/johnw/.emacs.d/lisp/org-agents/org-agents.el`, `;;;; Gate` section, lines 372–513.
The predicate (line 414) is a recursive allowlist walk over the **expanded** query — the form
after `org-agents--expand` has rewritten `$PROP` sugar into accessor calls. Clause by clause,
in order:

| Clause | Line | Verdict | Rationale as written |
|---|---|---|---|
| not a cons (number, string, symbol, keyword) | 423 | **safe** | literals as arguments |
| improper (dotted) list | 424 | **refused** | "dotted: fail closed" |
| `member` of `org-agents--special-accessors` | 426 | **safe** | the seven closed-set `$SPECIAL` accessor forms, compared as whole forms by `member` |
| `(quote ...)` | 428 | **safe** | "Quoted data is returned, never evaluated, whatever it holds" |
| car is not a symbol, and car is not `functionp` | 433 | **safe if every element is** | plist-style data, e.g. `(src :lang "elisp" :regexps ("defun"))` |
| car is not a symbol, and car *is* `functionp` | 433 | **refused** | a byte-code object or closure reads in from a property like any other text and Emacs calls whatever it finds in function position |
| car ∈ `and or not when unless` | 436 | recurse into every argument | |
| car ∈ `parent ancestors children descendants` | 437 | recurse into every argument | |
| car is a known org-ql predicate or alias (`org-ql-predicates`) | 438 | recurse into every argument | "A predicate head vouches for its own name only" |
| anything else | 440 | **refused** | fail closed |

Verified empirically (all results from a batch run against the live package):

```
(and (todo) $URL)               => (and (todo) (property "URL"))                        safe=t
$PRIORITY                       => (org-entry-get nil "PRIORITY")                       safe=t
$ITEM                           => (org-get-heading t t t t)                            safe=t
(src :lang "elisp" :regexps ("defun"))                                                  safe=t
'(shell-command "x")            [i.e. (quote (shell-command "x"))]                      safe=t
(and (todo) . 3)                                                                        safe=nil
((closure (t) nil (shell-command "x")))                                                 safe=nil
((lambda () (shell-command "x")))                                                       safe=nil
(and (todo) (shell-command "x"))                                                        safe=nil
(tags (shell-command "x"))                                                              safe=nil
(property "K" (progn (delete-file "/tmp/x") "v"))                                       safe=nil
```

Two ancillary refusals sit in front of the gate and are worth knowing because they are the
difference between a clean diagnosis and a `void-function` from inside org-ql's generated
matcher: `org-agents--check-head-spelling` (line 451) refuses `headline`/`re`/`p` by name,
and `org-agents--leftover-ref` (line 442) refuses any surviving `$…` symbol including bare
`$` and `$*`.

**A property worth stating loudly, because it decides how much weight the prompt can bear.**
Three of the five rows in the README's own `$PROP` expansion table produce structurally
*unsafe* queries:

```
(string-match "gh" $URL) => (string-match "gh" (or (org-entry-get nil "URL") ""))       safe=nil
(> $REVIEWS 3)           => (> (string-to-number (or (org-entry-get nil "REVIEWS") "0")) 3)  safe=nil
$OWNER*                  => (org-entry-get nil "OWNER" t)                               safe=nil
```

Value position, numeric position and inherited position all expand into function calls that
are not in the closed accessor set, so the package's own advertised sugar trips its own
prompt. This is deliberate (design.md: "including all `$ref`-generated residual bodies") and
it is *correct* — those forms really are residual Lisp. But the UX consequence is the
important one: a user who writes ordinary agents is trained to answer `yes` and
"remember permanently" as a reflex. **A prompt that fires on the common case cannot be the
security boundary for the dangerous case.** Any design that routes action code through this
same prompt inherits that training.

### 1.3 How approval works, and what the hash actually covers

`org-agents--gate` (line 486):

```elisp
(org-agents--check-spelling query)
(or (org-agents--structurally-safe-p query)
    (not org-ql-ask-unsafe-queries)                    ; master switch, org-ql's
    (let ((hash (org-agents--query-hash query)))
      (or (gethash hash org-agents--session-approved)  ; session memo
          (member hash org-agents-safe-queries)        ; persistent safelist
          (if (or noninteractive (eq context 'batch))
              (progn (message "org-agents: skipping unapproved query %S" query) nil)
            (when (yes-or-no-p (format "Query contains arbitrary Lisp: %S — run it? " query))
              (puthash hash t org-agents--session-approved)
              (when (and (or (bound-and-true-p custom-file) user-init-file)
                         (yes-or-no-p "Remember this approval permanently? "))
                (customize-save-variable 'org-agents-safe-queries
                                         (cons hash org-agents-safe-queries)))
              t)))))
```

- **Hash**: `sha1` of `prin1-to-string`, with `print-level` and `print-length` bound to nil
  (line 478) so a truncated print cannot hash as its own prefix.
- **Persistence**: `customize-save-variable` → `custom-file`, or `user-init-file` when there
  is none. The docstring already records the tangled-init trap.
- **Batch**: unapproved ⇒ skip with a message. Fails closed. Good.
- **Failure**: `org-agents--collect` (line 1571) turns a nil gate into
  `(user-error "org-agents: query not approved")`.

What the hash covers: **the expanded query sexp, and nothing else.** Verified — the written
form and the expanded form hash identically, because expansion happens before hashing:

```
hash (and (todo) $URL)                  = 79a5340c2ae90ab017c6cb55cc2db16adadd6526
hash (and (todo) (property "URL"))      = 79a5340c2ae90ab017c6cb55cc2db16adadd6526
```

So an approval is:

- **not scoped to a file or directory.** Approve a query once in a scratch file and every
  file in the corpus may run it, forever.
- **not scoped to a scope.** The same body approved for `:AGENT_SCOPE: agenda` runs under
  `:AGENT_SCOPE: all`.
- **fragile to cosmetics.** Reorder two conjuncts and the approval is gone; re-prompt.
- **irrevocable except by hand.** There is no `ignored-local-variable-values` analogue: no
  way to say "never approve this hash", and no record of where an approved hash came from.
  A safelist of bare SHA-1 strings is unauditable by construction — nobody can read
  `org-agents-safe-queries` and say what they approved.

### 1.4 The gap: what runs that the gate did not see

**(a) `org-agents-exclude` is spliced in *after* the gate.** `org-agents--collect`, lines
1571 and 1593:

```elisp
(unless (org-agents--gate (plist-get agent :query))     ; gates QUERY
  (user-error "org-agents: query not approved"))
...
(org-ql-select files
  (if org-agents-exclude
      `(and ,query ,org-agents-exclude)                 ; runs (and QUERY EXCLUDE)
    query)
  ...)
```

`org-agents-preview` does the same (lines 2582, 2593). The form that reaches
`byte-compile` is therefore *not* the form the gate examined and not the form the hash names.
design.md already admits this and offers a justification:

> "One conjunct does reach org-ql ungated: `org-agents-exclude` is spliced in *after* the
> gate has passed the query, which is safe only because it is a defcustom whose `sexp` type
> leaves it ineligible as a `safe-local-variable`, so a file cannot set it without Emacs's own
> file-local prompt — the one route by which anything but the user could put code there."

**That justification is wrong on the mechanism, in two ways.**

1. A `:type` has nothing to do with file-local eligibility. `safe-local-variable-p` consults
   the symbol's `safe-local-variable` *property* and `safe-local-variable-values`; the
   customize widget spec is never consulted. The conclusion happens to hold, but not for the
   stated reason — and the actual mechanism is what determines whether the prompt is
   once-per-value or once-ever.
2. "A file cannot set it without Emacs's own file-local prompt" is true *the first time*.
   Verified against the live package:

   ```
   org-agents-exclude          risky=nil  safe-local-variable prop=nil
   org-agents-safe-queries     risky=nil  safe-local-variable prop=nil
   org-agents-rg-executable    risky=nil  safe-local-variable prop=nil
   org-agents-prefilter        risky=nil  safe-local-variable prop=nil
   org-agents-files            risky=nil  safe-local-variable prop=nil
   org-ql-ask-unsafe-queries   risky=t                                  ← org-ql marks its own
   ```

   Because none is risky, all land in `unsafe-vars` in `hack-local-variables-filter`
   (files.el line 4148–4152), and `hack-local-variables-confirm` therefore offers `!` —
   "apply the local variables list, and permanently mark these values as safe" (files.el
   line 3969), which pushes the pair into `safe-local-variable-values`. One keystroke and
   `org-agents-exclude` is set silently from that file forever, in every session, with the
   form it carries evaluated at every candidate entry of every agent update — including
   every update on save. For a `.dir-locals.el` the prompt also offers `+`, which pushes the
   directory into `safe-local-variable-directories` and thereafter applies *every* local
   variable from that tree with **no prompt at all, risky ones included** (files.el
   3922–3932 and 4157–4161).

   A risky variable can never be added to `safe-local-variable-values` by `!`, because risky
   vars are put in `risky-vars` and only `unsafe-vars` are saved. So `:risky t` is exactly the
   mechanism that turns "prompt once" into "prompt forever" — and org-agents uses it nowhere.

   Independently of the corpus: `org-agents-rg-executable` is a program name handed to
   `call-process` (line 1127), and the name does not match Emacs's risky-by-name regexp
   (`-program$` is on the list, `-executable$` is not — files.el 4425). And
   `org-agents-safe-queries` is *the approval list itself*: a `.dir-locals.el` that pre-seeds
   it with hashes is a request to pre-approve arbitrary queries, and it renders as an
   innocuous-looking list of hex strings in the confirmation buffer.

   **Concrete fix, independent of any action-code decision:** mark `org-agents-exclude`,
   `org-agents-safe-queries`, `org-agents-rg-executable` and `org-agents-files` `:risky t`,
   and gate the *actual* form — hash `(and QUERY EXCLUDE)`, or gate the exclusion once at the
   point it is set.

**(b) org-ql predicate normalizers run inside `org-ql-select`, after the gate.** A known
predicate head passes the gate on the strength of its name, and org-ql runs each predicate's
`:normalizers` while normalizing the query — before any body executes. `org-ql-semantic.el`
line 359 is the live example in this configuration:

```elisp
(org-ql-defpred semantic (query)
  :normalizers ((`(semantic ,query)
                 (org-ql-semantic--ensure-cache query)   ; spawns `org db search'
                 `(semantic ,query))))
```

Verified: with `org-ql-semantic` loaded, `(semantic "x")` is `safe=t`. So an Org file
containing `:AGENT_QUERY: (semantic "…")` spawns a subprocess with no prompt, on save, under
`global-org-agents-mode`. design.md names this exposure. It generalises to a rule worth
carrying into any action design: **"structurally safe" means "names only predicates you have
installed", not "has no side effects."** Any capability the user installs is a capability a
file can invoke by name — which is fine, and is precisely the edna model, *provided the
capability set is chosen with that in mind.*

**(c) A print-binding asymmetry between the hash and the prompt.** The hash site binds
`print-level` and `print-length` to nil, with a comment explaining exactly why. The prompt
site (line 503) does `(format "… %S …" query)` with no such binding. Under a config that
sets `print-length` globally (common), the user is shown a form ending in `...` and approves
the whole of it. The reasoning that justified the binding at the hash applies verbatim at the
prompt. Small, but it is the same class of bug the hash comment was written to prevent.

**(d) Where the prompt fires.** `org-agents-mode` installs
`org-agents--update-on-save` on `before-save-hook` (line 2813) and
`global-org-agents-mode` arms it in any Org buffer whose *text* matches
`"^[ \t]*:AGENT_QUERY:"` (lines 2830, 2837, 2842) — a regexp over the buffer, so a file that
merely quotes the property line is armed too. The whole update body is wrapped in
`(condition-case err … (error (message …)))` (line 2709). Therefore, today: opening a file
from a git pull and pressing `C-x C-s` can produce
`Query contains arbitrary Lisp: … — run it?` from inside the save. That is the worst
possible moment to ask a security question, and Part 3 is about why.

For the record on blast radius as it stands: an update writes in exactly one place outside
its own rendering — `(org-entry-put nil "AGENT_MATCHED" …)` at the agent itself, line 2229.
Nothing writes at a match. `org-agents--link-to` calls `org-id-get`, never
`org-id-get-create`. Today an update cannot modify a file other than the agent's own.
Actions would end that, which is the single largest change in the threat model.

---

## Part 2 — The Emacs precedent, by mechanism

Emacs has been answering "a file wants to run code" for thirty years. The answers are not one
policy; they are five distinct mechanisms with different shapes, and the differences are the
useful part.

### 2.1 File-local variables

`files.el`, Emacs 30.2.50 (paths below are that tree; `gzcat` the `.el.gz`).

- **Master switch** `enable-local-variables` (line 669), default `t`, `:risky t`. Values:
  `t` = obey if all safe, else query once for all; `:safe` = set only safe ones, never ask;
  `:all` = set everything, never ask ("Don't set it permanently to `:all`."); `nil` = ignore.
- **Per-variable safety** is a property on the symbol, not a type: `(put 'VAR
  'safe-local-variable PREDICATE)`. Either the predicate accepts the value or the exact
  `(VAR . VALUE)` pair is in `safe-local-variable-values`.
- **Riskiness** (`risky-local-variable-p`, line 4410) is `(get sym 'risky-local-variable)`
  *or* a name matching
  `-hooks?$\|-functions?$\|-forms?$\|-program$\|-commands?$\|-predicates?$\|font-lock-keywords$\|…\|-map$\|-map-alist$\|-bindat-spec$`.
  `:risky t` in a `defcustom` sets that property.
- **What the user is actually shown** (`hack-local-variables-confirm`, line 3934): a
  `*Local Variables*` buffer listing every variable, `*` for unsafe and `**` for risky, and a
  `read-char-choice` over `y n ! i` (plus `+` for dir-locals). The text is verbatim:

  > `!  -- to apply the local variables list, and permanently mark these values (*) as safe
  >       (in the future, they will be set automatically.)`
  > `i  -- to ignore the local variables list, and permanently mark these values (*) as ignored`
  > `+  -- to apply the local variables list, and trust all directory-local variables in this directory`

  `!` and `i` write only the `*`-marked (unsafe) pairs into `safe-local-variable-values` /
  `ignored-local-variable-values`. **Risky variables are never written there**, because
  `hack-local-variables-filter` (line 4148) puts them in `risky-vars` and only `unsafe-vars`
  are saved. So `:risky t` means "ask every single time, forever" — the strongest thing a
  package can say about one of its own variables. Note also `ignored-local-variable-values`:
  Emacs has a *negative* list. org-agents has no equivalent.
- **`eval:`** is the escape hatch, and its guards are the interesting part.
  `hack-one-local-variable` (line 4499) does `(save-excursion (eval val t))`, reached only if
  `enable-local-eval` (line 801, default `'maybe`, `:risky t`) permits, and only counted safe
  if `hack-one-local-variable-eval-safep` (line 4436) says so. That function is a
  hand-written allowlist, and its clauses are instructive:
  - specific `(put 'sym 'prop val)` forms, and only for three known indent properties and
    `edebug-form-spec`;
  - exact membership in `safe-local-eval-forms` (line 3808, `:risky t`);
  - **any zero-argument call whose function name ends in `-mode`** ("Allow (minor)-modes calls
    with no arguments. This obsoletes the use of \"mode:\" for such things.") — a naming
    convention used as a capability allowlist;
  - a per-function `safe-local-eval-function` property: `t` means "safe if every argument is
    `macroexp-const-p`", a function means "ask this validator", a list means "ask each".

  And the shipped default of `safe-local-eval-forms` is worth quoting, because it is Emacs
  blessing exactly the pattern under discussion:

  ```elisp
  '((add-hook 'write-file-hooks 'time-stamp)
    (add-hook 'write-file-functions 'time-stamp)
    (add-hook 'before-save-hook 'time-stamp nil t)
    (add-hook 'before-save-hook 'delete-trailing-whitespace nil t))
  ```

  A file *may* install a before-save hook without asking — but only these four exact forms,
  naming two specific functions, both of which are idempotent text tidying. That is what a
  responsible "code runs on save from a file" grant looks like: not a language, a list of
  four literals.

### 2.2 Directory-local variables

`.dir-locals.el` is `read`, never `eval`ed, as an alist of `(MAJOR-MODE . ((VAR . VAL) …))`
with `(eval . FORM)` permitted as a pseudo-variable — it goes through the same filter as a
file-local `eval:`. The Emacs 30 addition is `safe-local-variable-directories` (line 3922,
`:risky t`):

> "A list of directories where local variables are always enabled. Directory-local variables
> loaded from these directories, such as the variables in .dir-locals.el, **will be enabled
> even if they are risky.**"

Mechanically it short-circuits the confirmation entirely (line 4157). This is the *only*
place-based trust decision in core Emacs, it is very new, and it is total: it defeats
`:risky t`. It is the honest precedent for "trust this file/tree", and its shape is a warning
as much as a model — the grant has no scope beyond the directory and no expiry.

### 2.3 org-babel

The mechanism has three layers, and the *asymmetry* between them is the single most
transferable idea in this document.

- **The switch.** `org-confirm-babel-evaluate` (ob-core.el line 116), default `t`; may also
  be a function of `(lang body)` returning non-nil to prompt. Immediately after the
  `defcustom`, line 139:

  ```elisp
  ;; don't allow this variable to be changed through file settings
  (put 'org-confirm-babel-evaluate 'safe-local-variable (lambda (x) (eq x t)))
  ```

  A **one-way ratchet**: a file may set this variable file-locally only to `t`, i.e. only to
  make itself *stricter*. Setting it to nil is not silently accepted. (It can still be reached
  through the ordinary unsafe-variable prompt, and `!` would then persist it — which is
  precisely the hole `:risky t` closes. Belt and braces would be both.)
- **The per-block restriction, supplied by the file.** `org-babel-check-confirm-evaluate`
  (line 243) reads the `:eval` header argument: `no`/`never` ⇒ never evaluate; `query` ⇒
  always prompt; `no-export`/`never-export`/`query-export` ⇒ the same restricted to export.
  All of these only *tighten*. There is no `:eval always` that skips the prompt.
- **The scope.** Because `:eval` is a header argument, it is subject to Org's ordinary
  header-args inheritance: `#+PROPERTY: header-args :eval never` at the top of a file, or
  `:header-args: :eval never` in a subtree's drawer, restricts a whole buffer or a whole
  subtree. So the *file* can declare its own blast radius downward, cheaply and legibly.
- **The keybinding.** `org-babel-no-eval-on-ctrl-c-ctrl-c` (line 142) lets a user remove
  evaluation from `C-c C-c` altogether — the acknowledgement that the *binding* is part of
  the threat model, not just the code.

Extract the rule: **file content may only tighten; loosening requires trusted configuration.**
And: evaluation is bound to a deliberate act (`C-c C-c` on the block, `C-c C-e` on export),
never to visiting or saving.

### 2.4 org-edna — the closest prior art, and it deserves the most attention

Installed here as
`/nix/store/n347ni3lkv081zl2fn1jhkd8644kbvs7-emacs-org-edna-1.1.2/share/emacs/site-lisp/elpa/org-edna-1.1.2/org-edna.el`
(2530 lines). Edna is "the other four Tinderbox concepts" done for Org, restricted to
dependencies and triggers, and it is the design this proposal should be measured against.

**How a trigger is expressed.** Two properties, `BLOCKER` and `TRIGGER`, whose values are
strings in a small DSL:

```org
:PROPERTIES:
:TRIGGER:  next-sibling todo!(NEXT) siblings todo!(TODO)
:BLOCKER:  previous-sibling
:END:
```

**How it is parsed — and this is the whole point.** `org-edna-parse-string-form` (line 205)
uses `read-from-string` to lex a token and an argument list, then
`org-edna--function-for-key` (line 173) resolves the token **by constructing a name and
checking `fboundp`**:

```elisp
((string-suffix-p "!" (symbol-name key))          ; Action
 (let ((func-sym (intern (format "org-edna-action/%s" key))))
   (when (fboundp func-sym) (cons 'action func-sym))))
((string-suffix-p "?" (symbol-name key))          ; Condition
 (let ((func-sym (intern (format "org-edna-condition/%s" key))))
   (when (fboundp func-sym) (cons 'condition func-sym))))
(t                                                ; Finder
 (let ((func-sym (intern (format "org-edna-finder/%s" key))))
   (when (fboundp func-sym) (cons 'finder func-sym))))
```

The namespace prefix *is* the allowlist. A token that does not resolve to a
`org-edna-action/…` / `-condition/…` / `-finder/…` function yields nil and a syntax error —
not a call. Arguments are passed through `org-edna--transform-arg` (line 138), which only
converts UUID-looking symbols to strings, and are then handed to the resolved function with
`apply` (lines 412, 432, 590, 639). **An argument is never evaluated as a form.** So there is
no expression language: no nesting, no calls in argument position, no arithmetic on
attributes. `(shell-command "x")` in a `TRIGGER` is a token `shell-command` that resolves to
nothing.

**What the vocabulary is** — and note how closely it matches what Tinderbox action code
actually does to an Org-shaped data model:

- actions: `todo!` `scheduled!` `deadline!` `tag!` `set-property!` `delete-property!`
  `clock-in!` `clock-out!` `set-priority!` `set-effort!` `archive!` `chain!`
- conditions: `done?` `todo-state?` `headings?` `variable-set?` `has-property?`
  `re-search?` `has-tags?` `matches?`
- finders (the target set): `match` `ids` `self` `relatives` `siblings`
  `rest-of-siblings[-wrap]` `next-sibling[-wrap]` `previous-sibling[-wrap]` `first-child`
  `children` `parent` `descendants` `ancestors` `olp` `file` `org-file`

Even the reads are careful: `org-edna-condition/variable-set?` (line 2132) uses
`symbol-value`, i.e. it can read a variable but not call anything.

**How it is extended.** By defining `org-edna-action/my-thing!` in your init — in trusted
Lisp, in a file you own. The file names capabilities; trusted code defines them. This is the
same relationship `org-ql-defpred` has with `:AGENT_QUERY:`, and it is the correct one.

**When it runs.** `org-edna--load` (line 725) adds to `org-trigger-hook` and
`org-blocker-hook` only, and `org-edna--should-run-p` (line 667) requires
`:type 'todo-state-change` from a not-done state to a done state. Nothing runs on visiting.
Nothing runs on saving. Nothing runs on a timer. It runs when you mark a task DONE — a
deliberate act, in the entry you are standing on. Also note `org-edna-prompt-for-archive`
(default `t`): the one action that destroys information asks, specifically, every time.

**The tell.** Grepping org-edna's 2530 lines of code and its whole manual for
`arbitrary|security|safe|trust|dangerous` returns nothing. Edna has no security section
because its design does not raise the question. That is what "responsible" looks like from
the outside.

### 2.5 org-depend — UNCERTAIN

Not installed in this environment (`locate-library "org-depend"` ⇒ nil; no org-contrib in the
Nix store). From recollection: it is edna's predecessor in org-contrib, using the same
`TRIGGER`/`BLOCKER` properties with a *different* and even smaller vocabulary parsed by
regexp — `chain-siblings(KEYWORD)`, `chain-find-next(…)`, `ID(KEYWORD)` — and I do not
believe it evaluates arbitrary Lisp. **I have not verified this** and it should not be relied
on. What would settle it: read `org-depend.el` from org-contrib and grep for `eval`,
`funcall`, `read`, `intern`. It matters only as corroboration; edna is the live prior art.

### 2.6 The rest of Org and Emacs, briefly, in descending order of relevance

- **`#+TBLFM:` Lisp formulas — the exact hazard shape, and Org considers it a defect.**
  `org-table.el` line 2640:

  ```elisp
  (if lispp
      (setq ev (condition-case nil
                   ;; FIXME: Arbitrary code evaluation.
                   (eval (eval (read form)))
                 (error "#ERROR"))
  ```

  No prompt. No switch. A double `eval`. And it is reachable **incidentally**:
  `org-table-auto-recalculate-regexp` is `"^[ \t]*| *# *\\(|\\|$\\)"` (line 560) and
  `org-table-maybe-recalculate-line` (line 2414) is called from TAB, RET and friends (lines
  1072, 1102, 1160, 1733, 1948, 2721, 5387), guarded only by
  `org-table-allow-automatic-line-recalculation` — default `t`, docstring:
  "Non-nil means lines marked with |#| or |*| will be recomputed automatically.
  Automatically means when `TAB' or `RET' or `C-c C-c' are pressed in the line."
  So: a `#`-marked row plus a `'(…)` formula plus one press of TAB in a file you merely
  opened runs arbitrary Lisp. This is the closest existing analogue to running actions from
  `before-save-hook`, it carries a FIXME in Org's own source, and it is a precedent to cite
  as a mistake — not to copy.
- **`#+MACRO:` with `(eval …)`.** `org-macro--set-templates` (org-macro.el line 108) turns
  such a definition into a lambda; `org-macro-expand` (line 200) `apply`s it with no
  confirmation whatsoever. The comment above it is the clearest statement of principle
  anywhere in Org, and it is worth quoting in full:

  > ";; This code can be evaluated unconditionally, as a part of loading Org mode. We *must
  > not* evaluate any code present inside the Org buffer while loading. **Org buffers may come
  > from various sources, like received email messages from potentially malicious senders. Org
  > mode might be used to preview such messages and no code evaluation from inside the
  > received Org text should ever happen without user consent.**"

  Note what Org does with that principle: it does not add a prompt. It *defers* evaluation
  out of load and into a deliberate act (export). Deferral to intent, not confirmation, is
  Org's actual answer.
- **`#+BIND:`.** `org-export-allow-bind-keywords` (ox.el line 831), default nil:
  "Non-nil means BIND keywords can define local variable values. **This is a potential
  security risk, which is why the default value is nil.**" A capability that exists,
  ships off, and is documented as a risk. That is a legitimate template for a feature whose
  value does not justify its default.
- **`#+SETUPFILE:`** pulls keywords from another file or a URL when the buffer's settings are
  refreshed. Not code, but a file-driven fetch, and a reminder that "reads only" still means
  "acts".
- **The `-*-` mode line.** `mode:` instantiates `FOO-mode` by name (`hack-one-local-variable`
  line 4499) — again a naming convention doing allowlist duty.
- **`custom-file`, `init.el`, `early-init.el`.** Loaded wholesale with no gate, by
  construction. This is the "trusted zone", and its existence is why the edna model works:
  there is always somewhere to put code you actually trust. It is also, note, where
  `customize-save-variable` writes `org-agents-safe-queries` — approvals live in the trusted
  zone, which is right.
- **Historical.** `enriched.el` once let a text property carry arbitrary Lisp
  (CVE-2017-14482, exploitable by mail Emacs merely *displayed*). Emacs's response was to
  remove the capability, not to prompt for it. UNCERTAIN on the exact patch shape; the
  incident is well documented and the direction of the fix is the point.

### 2.7 The pattern, extracted

Every mechanism above that has aged well obeys some subset of five rules:

1. **The file names capabilities; trusted code defines them.** (edna, `org-ql-defpred`,
   `mode:`, `safe-local-eval-function`.)
2. **File content may only tighten, never loosen.** (`:eval never`;
   `org-confirm-babel-evaluate`'s `(eq x t)` predicate.)
3. **Code runs on a deliberate act, and the act is specific to the code.** (`C-c C-c` on
   *this* block; marking *this* task DONE; `C-c C-e` for export.)
4. **A trust decision is a named, reviewable object.** (`safe-local-variable-values`,
   `safe-local-variable-directories`, `ignored-local-variable-values`.) Emacs also provides a
   negative list; a positive list of opaque hashes is the degenerate case.
5. **The refusal is the default, and the switch to weaken it is itself risky.**
   (`org-export-allow-bind-keywords` nil; `enable-local-variables`, `enable-local-eval`,
   `safe-local-eval-forms`, `safe-local-variable-directories` all `:risky t`.)

The two places Emacs violates these — Lisp table formulas and `(eval …)` macros — are the two
places with FIXMEs and CVE-adjacent history.

---

## Part 3 — Why "runs on save" changes the character of the problem

This deserves its own section because it is the reason a design that would be fine for babel
is not fine here.

**Consent is carried by the specificity of the act, not by the existence of a prompt.**
`C-c C-c` on a source block means: *this* block, *now*, chosen by pointing at it. The user has
read, or at least seen, the thing they are running. Marking a task DONE means: *this* entry.
`C-c C-e` means: this whole document, and export is understood to be a whole-document
operation.

`C-x C-s` means "do not lose my typing". It is pressed reflexively, dozens of times an hour,
in files the user opened to *look at*. It carries no information about what is in the file. If
saving runs actions, then:

- **Opening becomes executing, one keystroke later.** `global-org-agents-mode` arms
  `before-save-hook` on any Org buffer whose text matches `:AGENT_QUERY:` — no drawer parse,
  no provenance check. Pull a repo, open a file to read it, fix a typo, save: the file's code
  ran. In the user's described corpus — synced between machines, pulled from git, occasionally
  received from other people, partly machine-generated — that is a realistic sequence, not a
  contrived one.
- **A prompt at that moment is worse than no prompt.** It arrives during an operation the
  user did not initiate for this purpose, mid-flow, and the only thing standing between them
  and their save is a `yes-or-no-p`. Combined with §1.2 — where the package's own documented
  `$PROP` sugar already trips the same prompt — the prompt is training the reflex that
  defeats it. Prompts must be rare to mean anything.
- **The write is not confined to the file being saved.** Today an update writes only
  `:AGENT_MATCHED:` on the agent (line 2229). Tinderbox actions do not work that way: an
  OnAdd action "is performed when a note is added to a container, **is discovered by an
  agent**, or is placed atop an adornment, and affects **the note being added**"
  (tbxman920.txt near "Actions, Expressions, and Rules", line ~2799). Ported literally, an
  action in file A writes to every entry file A's query matched — across the corpus, in
  buffers the user never opened, from a hook they did not know was armed. A misfire is not a
  bad render that `undo` fixes; it is an unbounded set of edits across files whose buffers
  may not exist, and there is no corpus-wide undo.
- **The idempotence trick stops working.** The one thing that makes updating on save
  affordable is that a render that changed nothing is put back byte-identically
  (`org-agents--restore-text`, line 2652), so a no-op save touches no bytes. That comparison
  is over *the agent's own buffer*. An action that writes at a match writes in another buffer,
  which the snapshot does not cover — so every save leaves a trail of modified buffers
  elsewhere, and the property that "a file whose agents found nothing new reaches disk
  byte-identical" is lost.
- **Errors are swallowed.** `org-agents--update-on-save` wraps everything in
  `(condition-case err … (error (message …)))` (line 2709), because a file must not become
  unsavable. Correct for a render. For a partially-applied set of writes across several
  files it means a half-done mutation reported only in the echo area, which nobody reads
  during a save.

Tinderbox does exactly the thing being warned against, and it is worth being precise about
why it gets away with it. From the manual:

> "A Rule is performed at frequent intervals, and affects the note that possesses the rule.
> An Edict is performed after a document is opened, and at infrequent intervals while the
> document remains open." (line ~2801)

> "(At present, edicts run at startup and then at intervals of approximately one hour, though
> these details are subject to change.)" (line 2907)

> Under "Side Effects": "If an action is simply an expression, the expression is evaluated and
> the result discarded. For example, the action `runCommand("open /Applications/iTunes.app")`
> will ask your computer to open iTunes" (line ~2881)

And the language is not a closed vocabulary either. `runCommand(command_line, input)` runs a
shell command, and the manual's own example builds the command from *data*:
`$Text |= runCommand("curl "+$URL)`, and "It is not necessary to use an attribute to hold the
output from runCommand, allowing the operator to be used 'bare' in action code. If
$CommandValue holds a valid command line string, this can be used in a rule or action:
`runCommand($CommandValue)`" (lines 4319–4329). There is `eval()` and `action()` for
evaluating strings — "may occasionally prove useful when a note must assemble a rule on the
fly" (line 4300) — and in v9 user-defined functions live *in the document*, in
`/Hints/Library` (line 5157).

So Tinderbox is a closed-world app in which you deliberately open one document you authored,
where code, data and library all live in one file you own, and a timer runs your own shell
commands on your behalf. Every one of those assumptions fails for a 3,600-file Org corpus in
git. **The timer-driven rule is the single Tinderbox idea that should not be ported in any
form**, whatever is decided about the language.

One corollary that lands on the prototypes question (agent B's territory, but it belongs
here): Tinderbox rules are inherited from prototypes — "You could use a rule, inherited from
the Task prototype, to perform these chores" (line 2897). If a prototype can pass down an
action, then the code that runs when you save file A may be written in file B, reached by an
inheritance link. Per-file trust becomes meaningless: to know what saving A does you must
read the transitive closure of its prototypes. If action code happens at all, **actions must
not be inheritable**, or the trust decision must cover the whole closure and be recomputed
whenever any member changes.

---

## Part 4 — The real options, ranked, with costs

Ranked best-first by my judgement. The ranking is over "would I ship this in a package whose
input is a synced, partly-foreign Org corpus", not over expressive power.

### Option 1 — No action code; a restricted declarative vocabulary, run on an explicit act

Edna's design, narrowed to what agents need. A property such as `:AGENT_ACTION:` holds a
string in a small DSL, never a sexp:

```org
:AGENT_ACTION: set-property!(REVIEWED, today) tag!(+reviewed)
```

Tokens resolve by name construction (`org-agents-action/set-property!`) plus `fboundp`;
arguments are data, never evaluated; unresolved tokens are a syntax error, not a call.
Extension is by defining a function in init. Run by an explicit command
(`org-agents-apply-actions`) that reports what it will change, with a dry run, and — this is
the load-bearing part — **not from `before-save-hook`**.

- **A user can express:** everything the Org data model can be told: TODO state, scheduling,
  deadline, tags, priority, effort, property set/delete, archive, clock. Plus conditionals if
  a `when` guard reusing the existing query language is added. That covers, honestly, the
  large majority of real Tinderbox rules, which are `if(cond) {$Attr = value}`.
- **An attacker can express:** exactly the union of the vocabulary. Worst case is a
  data-destroying but *legible* and *bounded* edit: mass retagging, mass property deletion,
  mass archiving. Bad. Not "arbitrary code": no shell, no network, no file writes outside
  Org's own entry-editing primitives, no reading of the user's other data. `archive!` and
  `delete-property!` are the dangerous verbs and can be made confirm-always, as edna does for
  archive.
- **Failure mode:** a syntax error names the token it could not resolve. A wrong action makes
  a wrong but comprehensible edit, in one Emacs command, undoable per buffer.
- **Reviewability:** high, and this is the decisive advantage. A reader sees a fixed set of
  verbs and can say what the file does by reading one line. You can `grep` a corpus for
  `archive!`. You can write a linter. You cannot do any of that for Lisp.
- **Cost:** the largest implementation cost of the four. A parser (edna's is ~120 lines), a
  vocabulary (~12 functions), a target-set notion, a dry-run/preview, a report. Call it a
  substantial subsystem, not a weekend. And a permanent design tax: every new capability is a
  code change, and users will ask for one that is not there.

### Option 2 — No action code at all

Ship the other three concepts (system attributes, user attributes, prototypes) and refuse
this one. Say in the README that actions are out of scope, and that the supported way to
compute a property is a *command the user runs* or a function in their init — the trusted zone
Emacs already provides.

- **A user can express:** nothing new declaratively — but note how little is actually lost.
  Much of what Tinderbox rules do is *display* computation (`$Color`, `$DisplayExpression`,
  `$TableExpression`), and an org-agents `table` view with computed columns is the read-only
  version of exactly that: it shows the derived value without writing it anywhere. Tinderbox
  needs rules partly because its display is attribute-driven; Org's is not. What genuinely
  requires a write — "set NEXT_REVIEW three months out when I mark this reviewed" — is what
  edna already does, if edna is what the user wants.
- **An attacker can express:** nothing. There is no new attack surface at all.
- **Failure mode:** the feature request comes back in six months, and the user does it by
  hand in their init with `org-ql-select` plus a loop — which is, notably, the correct way to
  do it and takes ten lines.
- **Reviewability:** perfect; there is nothing to review.
- **Cost:** zero to build. The cost is a real capability gap and the risk of an ad-hoc
  reimplementation later, in a hurry, worse.

This is ranked second rather than first only because Option 1's vocabulary is genuinely
useful and genuinely safe. If effort is scarce, Option 2 is strictly better than a rushed
Option 3.

### Option 3 — Arbitrary Lisp behind a per-file (or per-directory) trust decision

Borrow `safe-local-variable-directories`: an `:AGENT_ACTION:` holding a sexp runs only if the
file (or its directory) is on an `org-agents-trusted-action-files` list, plus a
`local-variables`-style prompt naming the file. Actions never run from an untrusted file at
all — not with approval, not with a prompt.

- **A user can express:** anything. Full Lisp, at the entry, with the corpus available.
- **An attacker can express:** anything, in a file the user trusted — but *only* there. This
  is a coherent boundary, and it is the one Emacs itself chose most recently. It maps onto
  how people actually think ("`~/org/agents.org` is mine; `~/org/inbox/` is not").
- **Failure mode:** when it goes wrong it goes wrong at Lisp scope — a bad `dolist` writes to
  the whole corpus. But the *provenance* question is answered: the code was in a file you
  said you trusted.
- **Reviewability:** a reviewer must read and understand Lisp, which is a much higher bar
  than reading a vocabulary — but they know exactly which files to read: the trusted list is
  short and finite. Reviewing "is this file safe" is tractable; reviewing "is this hash safe"
  is not.
- **Cost:** small to build (a list, a predicate, a prompt) — much smaller than Option 1. The
  cost is entirely in discipline and in one nasty edge: trust attaches to a *path*, and paths
  are stable while content is not. A trusted file that is generated, or synced, or in a repo
  someone else can push to, is a trusted file whose contents change without a new decision.
  That edge is exactly why `safe-local-variable-directories` is `:risky t` and new.

**If arbitrary Lisp is going to exist at all, this is the way to admit it** — and it must be
combined with the trigger rules from Option 1 (explicit command, never `before-save-hook`).

### Option 4 — Arbitrary Lisp behind the existing gate-and-hash

Extend `org-agents--gate` to cover `:AGENT_ACTION:`: structurally safe ⇒ run; otherwise
prompt once and remember the SHA-1.

- **A user can express:** anything.
- **An attacker can express:** anything, subject to one `yes-or-no-p` — and this is where the
  option collapses. The gate's allowlist is *query* predicates. An action's whole purpose is
  side effects, so **essentially every useful action is structurally unsafe by construction**;
  the fast path never fires and the mechanism degenerates to "prompt for everything". Layered
  on the §1.2 finding — that the package's own documented sugar already prompts — the user is
  now answering `yes` several times per session for benign things and once, indistinguishably,
  for the malicious one. A hash safelist of opaque SHA-1s cannot be audited, has no
  revocation, and is not scoped to a file, so one approval covers the whole corpus forever.
  Then add the trigger: the prompt arrives inside `before-save-hook`.
- **Failure mode:** the worst of the four. Arbitrary code, corpus-wide writes, approval
  granted mid-save, no record of what was approved or where it came from.
- **Reviewability:** near zero. A reviewer reading a file sees a sexp; whether it will run
  depends on `org-agents-safe-queries`, which is a list of hashes in `custom-file` that
  nobody can read.
- **Cost:** cheapest to build. That is the whole of its appeal, and it is the reason to be
  suspicious of it.

I would argue against this one specifically and by name. It reuses a mechanism that was
correct for its original job — where the *safe* path is the common path and the prompt is the
exception — in a setting where the ratio is inverted. Reusing a gate outside the regime that
justified it is how prompt-fatigue vulnerabilities get built.

### Not an option: a Lisp sandbox

For completeness, since it will come up: there is no usable Emacs Lisp sandbox. You cannot
enumerate the dangerous functions (`funcall`, `apply`, `intern`, `symbol-function`,
backquote-built forms, macro expansion, `#[...]` literals, advice, timers, `format-message`
into `read`…), and org-ql byte-compiles the form so there is no interposition point.
`org-agents--structurally-safe-p` is an *allowlist over shapes*, which is the only tractable
version of this, and it works precisely because the shapes it allows call nothing. Extend it
to allow calls and it stops being a gate.

---

## Recommendation

**Option 1, with Option 2 as the fallback if the vocabulary cannot be kept small, and Option 3
as the escape hatch if arbitrary Lisp turns out to be genuinely required.** Concretely:

1. Actions are a **restricted vocabulary**, resolved by name against
   `org-agents-action/NAME!` functions defined in trusted Lisp. No sexp is ever read out of an
   `:AGENT_ACTION:` property. Extension is `defun` in init, exactly as `org-ql-defpred` extends
   the query language today.
2. Actions run **only from an explicit command**, with a **dry run that prints every intended
   edit and its location** before anything is written. Never from `before-save-hook`, never on
   a timer, never from `global-org-agents-mode`. This is the non-negotiable part; the language
   choice matters less than the trigger.
3. **Actions are not inheritable** and do not travel through prototypes, so the code that
   affects an entry is written in a file a reader can find.
4. Destructive verbs (`archive!`, `delete-property!`, anything that removes information)
   confirm every time, per edna's `org-edna-prompt-for-archive`, and are not silenced by any
   remembered approval.
5. Independently and immediately, whatever is decided about actions: mark
   `org-agents-exclude`, `org-agents-safe-queries`, `org-agents-rg-executable` and
   `org-agents-files` `:risky t`; hash and gate the form that actually runs
   (`(and QUERY EXCLUDE)`); bind `print-level`/`print-length` at the prompt as they are at the
   hash; and give the safelist a negative counterpart and a way to see what is in it.

### The strongest argument against my recommendation

**It is a large amount of work to build a worse version of org-edna, and the honest answer may
be "install edna".**

Edna already exists, is on GNU ELPA, is installed in this very configuration, has the
vocabulary (its twelve actions are very close to the twelve a port would need), has the
finders, has the parser, and has been debugged. A restricted action vocabulary for org-agents
would duplicate perhaps 80% of it in order to reach the last 20% — actions driven by an
*agent's* match set rather than by a TODO state change. And that 20% is precisely the part
with the alarming semantics: writing to every entry a query matched, across the corpus,
possibly in files that are not open. Edna deliberately does not do that; its finders are
structural (siblings, children, an explicit ID list) and local. It is entirely possible that
the right answer is: use org-agents for views, use edna for triggers, and accept that
Tinderbox's "agent action" — the thing that couples a query's match set to a write — is the
one Tinderbox idea whose semantics are wrong for a file-based corpus, regardless of what
language it is written in.

The counter-counter: an agent action operating on a match set is *also* the only one of these
features that cannot be expressed today by any combination of existing tools, which is a
reason it is being asked for. But it should be built, if at all, with that specific danger in
front of the design and not behind it — and the first thing to try is whether a
`table` view with computed columns satisfies the actual use case without writing anything at
all. In my judgement it will satisfy most of it, and that experiment costs nothing.

---

## Uncertainties, stated

- **org-depend** is not installed; my description of its trigger vocabulary is recollection.
  Settle it by reading `org-depend.el` from org-contrib.
- **`enriched.el` / CVE-2017-14482**: the incident and the direction of the fix are well
  documented; I did not read the patch, and I have not verified the current state of
  `enriched.el` in this Emacs.
- **Whether the user's `custom-file` is separate from the tangled init** determines whether
  `org-agents-safe-queries` persists at all today. `org-agents-safe-queries`'s own docstring
  raises this; I did not check the live configuration, and it is worth checking, because if
  approvals do not persist then every session re-prompts and the fatigue argument in §1.2 is
  worse than stated, not better.
- **`print-length` in the user's configuration** determines whether the prompt-truncation gap
  in §1.4(c) is live or merely latent.
- I did not empirically demonstrate the `#`-row table auto-recalculation attack; I read the
  code path (regexp at org-table.el:560, caller at 2414, callers of that at 1072/1102/1160/
  1733/1948/2721/5387, `eval` at 2640). A fixture in a temp directory would settle it in five
  minutes if the claim is going to be leaned on.
