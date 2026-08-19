# Measured facts about the surrounding systems

Facts about Emacs, Org, org-ql and the org-jw CLI/database that this package
depends on and that cost real effort to establish. Each entry states the fact,
the evidence for it, and why it matters here. Nothing below is repeated from a
docstring or a design note: everything was read out of the shipped source or
measured by running it, and where a previously believed fact turned out to be
wrong the correction is recorded rather than the belief.

> **§5 is historical, 2026-08-19.** It records the org-jw CLI, parser and
> PostgreSQL database, which this package no longer uses: ripgrep replaced them
> as the candidate-file prefilter. §§1-4 and §6 remain current except where a
> note below says otherwise.

Read this before changing the splitter, the gate, the dynamic-block writer, or
the prefilter. Several entries exist because a plausible assumption was made
first and cost a rewrite.

## Measurement baseline

Everything marked *measured* was measured on 2026-08-19 on this host:

| | |
|---|---|
| OS | macOS (darwin 25.5.0), Apple silicon |
| Emacs | 30.2.50, Nix `emacs-mac-macport-with-packages` |
| Org | 9.8.6 (`.../elpa/org-9.8.6/org.el`) |
| org-ql | 20250421.133 |
| ts | 20220822.2313 |
| local zone | `America/Los_Angeles`, UTC−7 in August |

Line numbers cite those exact versions. They are the fastest way back to the
code, but check the surrounding text before trusting one after an upgrade.

To reproduce anything here, resolve an Emacs first — there is none on `PATH`:

```sh
for e in /nix/store/*emacs-mac-macport-with-packages-*/bin/emacs; do
    "$e" -batch --eval "(require 'org-ql)" 2>/dev/null && { echo "$e"; break; }
done
```

---

## 1. Environment

**E1. `~/org` is a two-hop symlink, so paths must be compared by truename.**
`~/org` → `/nix/store/…-home-manager-files/org` → `/Users/johnw/doc/org`
(measured: `os.path.realpath("/Users/johnw/org")`). The database stores
`canonicalizePath` of every file it reads (§4), so the two spellings of one file
have *nothing* in common under `equal`. Any intersection of a locally gathered
file set with a database answer must run `file-truename` on both sides — and a
prefix-substitution shortcut is wrong, because the chain has two hops through a
store path. `org-agents--same-files` is where this is done; deleting it silently
empties every corpus-scope candidate set.

**E2. `/tmp` is `/private/tmp`.** Measured. A test that creates a fixture under
`temporary-file-directory` and compares its path against a database answer must
compare truenames for this reason alone, independently of E1.

**E3. `~/.emacs.d/lisp` *is* `/Users/johnw/src/dot-emacs/lisp`.** Measured
(`realpath`). This is why a checkout placed at `~/.emacs.d/lisp/org-agents`
lands inside the dot-emacs working tree, and why the repo-local dependencies
`org-ql-ext.el` and `org-ext.el` are reachable from this repo with `-L ..` and
nothing more.

**E4. `grep` needs `-a` on the installed `org-ql.el`.** Measured: `grep -c
defun org-ql.el` prints *nothing at all*, while `grep -ac defun` prints 33.
Root cause found: the file contains exactly one NUL byte, at offset 42154 —
a literal NUL written inside an `rx` form at org-ql.el:867, `(not (any "\0"))`
— so grep classifies the whole file as binary. `file` reports it as `data`.
This is inherent to the org-ql release, not a Nix artifact, and it silently
turns a search for a predicate definition into "no such thing exists". Use
`grep -a`, or search from inside Emacs.

**E5. `-Q` does not suppress the Nix package load path on this build.**
Corrected. The received rule was "never pass `-Q`, it hides the site-lisp where
org-ql lives". Measured: `emacs -Q -batch --eval "(require 'org-ql)"` succeeds,
and `load-path` under `-Q` still begins with
`/nix/store/…-emacs-packages-deps/share/emacs/site-lisp`. The reason: the
`emacs` in `bin/` is a compiled binary wrapper that sets `EMACSLOADPATH` in the
process before Emacs starts, and `-Q` cannot remove that. Omitting `-Q` remains
a free habit, but a failure to load org-ql in batch is *not* explained by it —
look at `EMACSLOADPATH` and the wrapper instead.

**E6. `.elc` files are not tracked in the dot-emacs repository.**
`/Users/johnw/src/dot-emacs/.gitignore` line 1 is `*.elc`. (Verified from
`.gitignore`; no `git` was run.) Consequence, and the reason the byte-compile
gate has two stages: a fresh checkout has no `org-ql-ext.elc`, so `(require
'org-ql-ext)` loads it — and `org-ext.el` beneath it — as *source*, evaluating
each one's `(eval-when-compile (require 'cl))` and reporting the resulting
warning against **our** require line. Note that `lisp/CLAUDE.md` in dot-emacs
claims the opposite ("Byte-compiled files (.elc) are tracked"); it is wrong.

**E7. The `cl`-deprecation warning is attributed to the requiring file, and
compiling one dependency is not enough.** Measured, reproducing both stages in a
scratch copy:

| stage | warnings for `org-db-cli.el` + `org-agents.el` |
|---|---|
| neither dependency compiled | 1 — `org-agents.el:209:11: Warning: Package cl is deprecated` |
| both compiled first | 0 |

Line 209 is our own `(require 'org-ql-ext)`. `org-ql-ext.el:32` and
`org-ext.el:32` each carry `(require 'cl)` inside `(eval-when-compile …)`, and
`org-ql-ext.el:36` requires `org-ext` — so `org-ext.elc` must exist too, or the
warning survives. On their own, `org-ext.el` emits 14 warnings and
`org-ql-ext.el` 5; neither is ours to gate. This is exactly what
`tools/org-agents-byte-compile-gate.sh` encodes.

**E8. `org-ql--normalize-query` is not autoloaded.** `org-ql-select` expands
into a call to it, so a file that uses the macro gets "might not be defined at
runtime" over a call site that is org-ql's, not its own. One
`(declare-function org-ql--normalize-query "org-ql")` clears it. Both
`org-ext.el` and `org-ql-ext.el` emit the same warning about themselves, which
is how it was first mistaken for something inherited rather than fixable.

**E9. Byte-compiling this package takes seconds, not minutes.** Measured:
`org-db-cli.el` + `org-agents.el` in one batch invocation, 2.4 s with the
dependencies uncompiled and 3.6 s with them compiled. An earlier note in this
project's ledger said "~2 min per file"; that is not reproducible here and
should not be budgeted for. Do not skip the gate on the assumption it is slow.

**E10. `setenv "TZ"` moves the zone in-process; binding `process-environment`
does not.** Corrected, measured:

```
orig      : 2026-08-19 10:14 PDT
let p-env : 2026-08-19 10:14 PDT      ; (let ((process-environment (cons "TZ=…" …)))
setenv    : 2026-08-20 07:14 +14      ; (setenv "TZ" "Pacific/Kiritimati")
setenv LA : 2026-08-19 10:14 PDT      ; restored
```

A `let` on `process-environment` only affects subprocesses. `setenv` is special-
cased for `TZ` and really does change what `format-time-string` reports. An
earlier note claimed neither worked; that is false. Even so, threading an
explicit reference instant through the date helpers is the better test design —
it needs no zone data and works at any hour — which is what
`org-agents--absolute-date`'s optional NOW argument is for.

---

## 2. Emacs Lisp and Org

**L1. `quit` is not a subtype of `error`.** Measured: `(get 'quit
'error-conditions)` ⇒ `(quit)`. An `(error …)` handler therefore does not catch
`C-g`. This matters because `org-prepare-dblock` deletes a block's body *before*
the writer runs (O1): an `error`-only handler leaves the block empty on the one
interruption users actually cause. The handler must be `((error quit) …)`, and
must put the body back *before* re-signalling `quit`.

**L2. `plist-get` returns the FIRST occurrence of a repeated key.** Measured:
`(plist-get '(:to "a" :to "b") :to)` ⇒ `"a"`. The CLI's Haskell parser folds
left and keeps the **last** (§4, D3). Any plist forwarded from Emacs to the CLI
must be checked for repeated keys, or the two engines bound the same query
differently with no error anywhere.

**L3. Emacs Lisp `read` does not honour `#.` read-eval.** Measured: `(read
"#.(+ 1 2)")` signals `invalid-read-syntax ("#.")`, and so does
`(read-from-string "(and (todo) #.(shell-command \"x\"))")`. Read-eval is a
Common Lisp feature that Emacs Lisp does not implement. This is what makes the
trust boundary placeable *after* the read: reading a sexp out of an Org property
builds data and cannot execute anything, so a gate applied to the resulting form
is sound. (The `invalid-read-syntax` signal is itself a hostile-input case worth
catching, and is.)

**L4. `functionp` is true of a byte-code object and of a `lambda`-headed cons,
and false of a vector, a record, and a quoted list.** Measured, all six. A
byte-code object reads in from a property like any other text — `(read "#[257
\"\\300\\207\" [1] 3]")` produces a callable object — so a gate that decides
"the car is not a symbol, therefore this is data" must still refuse a callable
car. See Q6 for what org-ql does with one in practice.

**L5. `select-window` before `set-window-buffer` makes the window's OLD buffer
current.** Measured:

```
before        : current=probe-B   window shows=probe-A
after select  : current=probe-A            ; ← the stranger's buffer
after set-wb  : current=probe-A   window shows=probe-B
correct order : current=probe-B   window shows=probe-B
```

So `set-window-buffer` first, then select — and select through
`with-selected-window`, which puts the selection back. Getting the order wrong
runs every subsequent edit in whatever the window was showing, which in batch is
`*scratch*`. This cost six failing block tests once.

**L6. `org-get-heading t t t t` drops a `COMMENT` keyword; `org-edit-headline`
preserves it.** Measured, both directions:

| read with | after `org-edit-headline` of `read + " (stale)"` |
|---|---|
| `(org-get-heading t t t t)` | `* Alias (stale) :tag:` — COMMENT gone |
| `(org-get-heading t t t nil)` | `* COMMENT Alias (stale) :tag:` |

`org-edit-headline` replaces the whole title group, and the keyword lives inside
that group. Retitling through the pair therefore silently uncomments an entry —
the one place in the alias-preservation contract where user text can be lost.
Read with `nil` as the fourth argument.

**L7. `org-entry-get` is case-insensitive on property names and Org treats the
literal value `nil` as no value.** Measured: with `:Owner: john` in the drawer,
lookups of `Owner`, `OWNER` and `owner` all return `"john"`; and with
`:AGENT_VIEW: nil`, `(org-entry-get nil "AGENT_VIEW")` ⇒ `nil` while
`(org-entry-get nil "AGENT_VIEW" nil t)` ⇒ `"nil"`. So a hand-written
`:AGENT_VIEW: nil` is an agent with no view, takes the default, and *cannot* be
diagnosed as a bad value. Also measured: `(org-entry-get nil "")` ⇒ `nil`, which
is what a degenerate `$*` reference would ask for.

**L8. `:NAME+:` lines accumulate into one separator-joined value on the Emacs
side.** Measured: a drawer holding `:TOKENS: alpha` and `:TOKENS+: beta` gives
`(org-entry-get nil "TOKENS")` ⇒ `"alpha beta"`;
`(org--property-get-separator "TOKENS")` ⇒ `" "`; `org-property-separators`
defaults to `nil`. The database side of the same drawer is far worse — see D6 —
and the divergence is why property *equality* over a whitespace-bearing value
downgrades to existence before being pushed.

**L9. `org-link-heading-search-string` already supplies the leading `*`.**
Measured: `(org-link-heading-search-string "Heading")` ⇒ `"*Heading"`. A link
target built as `file:…::*` + that string yields `::**Heading`, which does not
resolve. Build `file:…::` + the string.

**L10. `proper-list-p` is the cheap dotted-form guard.** Measured:
`(proper-list-p '(todo . x))` ⇒ `nil`, `(proper-list-p '(todo))` ⇒ `1`. A query
read from a property can be dotted; without this test the walkers reach `cl-every`
on an improper list and raise `wrong-type-argument` instead of a legible refusal.

---

## 3. Org dynamic blocks

**O1. `org-prepare-dblock` deletes the body before the writer sees it, and hands
it over as `:content`.** org.el:9196-9219: it records `:content` as the buffer
substring between the delimiters, records `:indentation-column`, then
`delete-region`s that text, `goto-char`s the start and `open-line 1`s. Two
consequences: a writer must compute everything *before* it writes anything, and
a writer that fails must reinsert `:content` or leave the block empty. Because
of the `open-line`, a byte-exact restore needs the trailing newline trimmed
(`string-remove-suffix`).

**O2. `org-update-dblock` indents every body line unconditionally after a
writer returns.** org.el:9287-9317: after `(funcall cmd params)`, if
`:indentation-column` is greater than zero it walks from the line after the
`#+BEGIN:` to the `#+END:` inserting the indent string on every line, with no
check of whether the writer changed anything. So a body restored from
`:content` on the *error* path gets indented a second time and creeps right,
which is why the restore dedents to column 0 on that path — and must *not* on
the `quit` path, where re-signalling skips the indent pass entirely. Both
directions need a test; only one of them is intuitive.

**O3. That indent pass runs inside `(select-window win)` — in the SELECTED
window's buffer.** org.el:9308-9310, where `win` is `(selected-window)`
captured at entry. A batch updater iterating over `find-file-noselect` buffers
that nothing displays therefore runs `org-beginning-of-dblock` in `*scratch*`
and errors, or worse, indents a stranger. Any command that updates a block in a
buffer must make that buffer *displayed* as well as current — see L5 for the
order — or accept an unindented block. `org-agents--update-dblock-in-window`
borrows a window for exactly this reason.

**O4. `org-prepare-dblock` `read`s the block's parameter string.** org.el:9204,
`(read (concat "(" (match-string 3) ")"))`. A dynamic block header is therefore
another route by which text in a file becomes a Lisp form — the same trust
question as `:AGENT_QUERY:`, and the reason a standalone block's `:query` must
pass the same expand-and-gate choke point an agent entry's does.

---

## 4. org-ql

**Q1. The `property` predicate's docstring and its normalizer disagree, and the
normalizer wins.** The docstring promises that an unspecified `INHERIT` uses
`org-use-property-inheritance`. The normalizer (org-ql.el:1794-1848) attaches
`:inherit` **only** to a `property` form that carries an extra plist:

| written | normalized |
|---|---|
| `(property "K")` | `(property "K")` |
| `(property "K" "V")` | `(property "K" "V")` |
| `(property "K" :inherit t)` | `(property "K" nil :inherit t)` |
| `(property "K" "V" :inherit nil)` | `(property "K" "V" :inherit nil)` |

Measured end to end at *every* setting of `org-use-property-inheritance` — `nil`,
`t`, and the selective list `("OWNER")` — over a parent/child fixture: the plain
one- and two-argument forms matched the parent only in all nine combinations,
and only the `:inherit t` form matched the child. **Trusting the docstring is
what produced a wrong design premise here**, retracted twice (once in a
docstring, once in the spec) before it stopped propagating. Do not write "plain
forms inherit" anywhere. Note also that when `org-use-property-inheritance` is a
*list*, a plist-bearing form gets `:inherit ''selective`, not the list.

**Q2. `today` means the LOCAL day to org-ql.** org-ql.el:1313-1330 resolves
`'today`/`"today"` and integer offsets through `(ts-now)` and `ts-adjust`, both
of which are local. The CLI resolves the same words against `utctDay <$>
getCurrentTime` (§4, D2). A relative date pushed verbatim therefore names a
different day to each engine — measured on this host as a 7-hour daily window
(local 17:00 to midnight) in which the database's `today` is already tomorrow.
`org-agents--absolute-date` resolves the day in Emacs and pushes
`"YYYY-MM-DD"`, which removes the skew class rather than gating on it.

**Q3. `:from`/`:on` are floored and `:to` is ceilinged, and an absolute date
string gets exactly the same treatment as `today`.** org-ql.el:1310-1349, and
measured:

```
(scheduled :to today)         => :to 2026-08-19 23:59:59 [1787209199.0]
(scheduled :to "2026-08-19")  => :to 2026-08-19 23:59:59 [1787209199.0]
(scheduled :from today)       => :from 2026-08-19 00:00:00 [1787122800.0]
(scheduled :from "2026-08-19")=> :from 2026-08-19 00:00:00 [1787122800.0]
```

`today` goes through `ts-apply :hour 0/23 …`; a string goes through
`ts-parse-fill 'begin`/`'end`, which fills to `00:00:00`/`23:59:59`. Identical to
the second. This is what makes substituting an absolute date for `today` exact
rather than merely close: it cannot change which entries match.

**Q4. `:on` overwrites both ends and DISCARDS any bound written beside it.**
org-ql.el:1309-1311, `(when on (setq from on to on))`, and measured:
`(scheduled :on "2026-08-19" :to "2026-08-10")` normalizes to `:from 2026-08-19
00:00:00 :to 2026-08-19 23:59:59` — the `:to` is gone. The CLI instead
*conjoins* `day = ?` with `day <= ?` (§4, D4). Same shape, two different
answers, no error on either side.

**Q5. Date arithmetic must use `ts-adjust`, not seconds.** Measured across a
daylight-saving change:

```
base                 : 2026-03-07 23:30 -0800
ts-adjust 'day 1     : 2026-03-08 23:30 -0700   ← the next calendar day
+86400 seconds       : 2026-03-09 00:30 -0700   ← a day wrong
```

A day's error, exactly across the transition, and invisible for the rest of the
year. Using `ts-adjust` — the same function org-ql uses at Q3 — makes the two
engines' arithmetic identical by construction rather than by agreement. That
makes `ts` a real dependency, declared in `Package-Requires`. Any test of this
must pin a literal expected date (`"2026-03-08"`) and skip unless the
local zone really transitions that night; computing the expectation
with `ts-adjust` makes the test tautological, which is how the guarantee sat
unprotected for a while.

**Q6. org-ql byte-compiles the whole query sexp, passes unknown forms through
unchanged, and evaluates them at every candidate entry — including in predicate
ARGUMENT positions.** Measured over a three-entry fixture, counting calls to an
instrumented function:

| query | calls |
|---|---|
| `(and (todo) (probe "top"))` | 2 (the two TODOs; `and` short-circuits) |
| `(and (todo) (tags (probe "arg")))` | **2** |
| `(property "K" (probe "prop"))` | **3** |
| `(and (todo) '(probe "quoted"))` | 0 |

`(org-ql--normalize-query '(and (todo) (shell-command "x")))` returns its
argument unchanged, and `org-ql--query-predicate` produces a `byte-code-function`.
So *any* function call anywhere in a query runs, argument positions included —
which is why the trust boundary must be a whole-query structural gate and not a
scan for `$` references. A gate that vouches for a known predicate head and
stops there approves `(and (todo) (tags (shell-command "x")))`; that was this
project's one Critical finding.

**Q7. org-ql's own compiler refuses a non-symbol function position.** Measured:
a `lambda`-headed cons raises `org-ql-invalid-query … "Use of deprecated
((lambda nil ...) ...) form"`, and a byte-code object raises `org-ql-invalid-query
… "Use ‘funcall’ instead of ‘#[…]’ in the function position"`. Zero calls in
both cases. So the gate's `functionp` clause (L4) is defence in depth today, not
the only thing standing in the way — but it is the boundary that has to hold if
org-ql's compiler ever relaxes, and the gate is cheaper to keep correct than to
re-derive.

**Q8. `org-ql--add-markers` sets `:org-marker` and `:org-hd-marker` to the same
`copy-marker` at `:begin`.** Measured on a fixture: `(:begin 1 :org-marker 1
:org-hd-marker 1 :same-buffer t)`. Either will do for a headline; `:org-hd-marker`
is the one that stays right when a match is not itself the headline. Because
`find-buffer-visiting` matches by truename, comparing `marker-buffer` with `eq`
is a sound self-skip test.

**Q9. `org-ql-select` handed no files searches the CURRENT buffer.** This turns
"the scope resolved to nothing" into "matches from wherever the user was
standing", under a heading that promises otherwise. Both `org-agents--collect`
and `org-agents-preview` guard it. In batch this is easy to lean on by accident:
`-batch` leaves `org-agenda-files` empty, so a preview test can pass for the
wrong reason.

**Q10. `org-ql-ext.el` adds seven predicates to org-ql's 35.** Measured:
`(length org-ql-predicates)` is 35 bare and 42 after `(require 'org-ql-ext)`,
the additions being `property-ts`, `verb`, `refile-target`, `tasks-for`,
`about`, `shown`, `keyword`. Anything that decides "is this a known predicate?"
is therefore sensitive to *load state*: the same form is a known predicate or
residual Lisp depending on whether org-ql-ext has loaded. Also note
`org-ql-predicates` keys by main name, so alias spellings must be checked
separately.

**Q11. `(property)` with no arguments normalizes to `(property "")`.**
org-ql.el:1801-1811, a documented HACK guarding `org-ql-completing-read` while
the user is still typing. Worth knowing because a degenerate reference that
expands to a nameless property reaches a real, always-false predicate rather
than an error.

---

## 5. org-jw: the CLI, the parser, and the database

No PostgreSQL was reachable while this was written (`pg_isready` gets no
response; the real database is remote and keychain-gated). Everything in this
section is read out of the Haskell sources in the
`org-db-query-file-json` worktree, and is marked **source-verified**, not
measured. §6 records what that leaves unproven.

**D1. Invocation shape.** `--config` is a required global option
(`org-jw/bin/Options.hs:87-91`, a `strOption` with no default); `--keywords` is
optional; input files come last. `--db-url` belongs to `db`, *before* the
sub-subcommand (`org-jw/bin/DB/Options.hs:124-129`). So the prefilter call is

```
org --config CONF db --db-url URL query --ql SKELETON --format json
```

**D2. `today` is the UTC day to the CLI.** `org-jw/bin/DB/Exec.hs:92`, `today <-
utctDay <$> getCurrentTime`, and that `Day` is what
`Org/DB/Query.hs:708-712`'s `resolveMjd` resolves `DateToday` and `DateOffset`
against. `DateAbsolute` is the only constructor that escapes it. This is the
other half of Q2.

**D3. `parseDateFilter` folds left, so the LAST occurrence of a repeated key
wins.** `Org/DB/Query.hs:329-345`: `go` walks the argument list updating a
record field per key. Emacs takes the first (L2). `(scheduled :to today :to
"2026-01-01")` is therefore bounded by *today* in Emacs and by *2026-01-01* in
the database — measured end to end during the final review as a silent wrong
answer, one alias rendered where org-ql matched two. The splitter now pushes a
date filter only when each of `:from`/`:to`/`:on` appears at most once.

**D4. `compileDateConds` ANDs `day = on` with any bound, where org-ql discards
the bound.** `Org/DB/Query.hs:687-704` emits `day = ?` for `dfOn`, `day >= ?`
for `dfFrom` and `day <= ?` for `dfTo`, concatenating all three. Compare Q4.
Same root cause as D3, same refusal.

**D5. An unparseable absolute date becomes MJD 0.** `Org/DB/Query.hs:711`,
`DateAbsolute s -> maybe 0 dayToMjd (parseAbsoluteDate s)`, and
`parseAbsoluteDate` is `parseTimeM False defaultTimeLocale "%Y-%m-%d"`. MJD 0 is
1858-11-17, so `"2026-02-30"` does not fail — it quietly asks for a day no entry
has, and the candidate set comes back empty while org-ql normalizes the same
string and matches. Hence the calendar-validity round trip before any date is
pushed: format the date back out and require it to equal itself.

**D6. A `:PROP+:` line makes the parser discard the WHOLE drawer.**
`flatparse-util/src/FlatParse/Combinators.hs:121-122`:

```haskell
identifier :: FP.Parser r e String
identifier = some (satisfy (\c -> isAlphaNum c || c == '_' || c == ' '))
```

Alphanumerics, underscore and *space* — no `+`, and no `-` either.
`Org/Parse.hs:63` reads a property name as `between (char ':') (char ':')
identifier`, so `:TOKENS+: beta` fails mid-line; the enclosing `some` stops, the
following `:END:` is not where the parser now stands, and `parseProperties` fails
outright. The drawer degrades to body text and the entry gets **no property rows
at all** — not even for the ordinary `:TOKENS: alpha` line above it. Compare L8,
where Emacs happily reports `"alpha beta"`. Two consequences: a `property`
conjunct over such a name can drop a true match (an under-match unfixable from
Emacs, since the skeleton is built from the query and cannot know what the
matched entry's drawer looks like), and `:AGENT_QUERY+:` must never be used to
continue a long query. One fix to `identifier` closes both.

**D7. `is_inherited` is written false everywhere.** Tags:
`Org/DB/Store.hs:655`, a literal `SqlBool False`. Properties:
`Org/DB/Store.hs:669`, `SqlBool (prop ^. inherited)`, where the parser sets
`_inherited = False` on both construction paths (`Org/Parse.hs:71` for drawer
properties, `:132` for `#+NAME:` file properties). So the database holds LOCAL
values only.

**D8. Tag inheritance is computed per query by an ltree ancestor join, not
stored.** `Org/DB/Query.hs:580-590`: `EXISTS (SELECT 1 FROM entry_tags et__ JOIN
entries anc__ ON … WHERE anc__.path @> a.path AND anc__.id != a.id …)`. The same
`@>` idiom implements `ancestors`, `descendants` and `parent`
(`Query.hs:742-815`). Useful to know when reasoning about which tag query is
cheap, and that inheritance semantics live in the query compiler, where they can
diverge from Org's, rather than in the rows.

**D9. `#+PROPERTY:` and `#+FILETAGS:` are invisible to a query.** File-level
`#+NAME:` lines are parsed (`Org/Parse.hs:127-134`) into a separate
`file_properties` table (`Schema.hs:165`), while `QProperty` compiles to an
`EXISTS` over **`entry_properties`** only (`Query.hs:489-494`) and the tag
predicates to `entry_tags` only. So a file whose only value for a property comes
from `#+PROPERTY:`, or whose tags come only from `#+FILETAGS:`, has no matching
row. Combined with Org's own `org-global-properties`, that is why *any* widening
of `org-use-property-inheritance` makes property conjuncts unpushable and the
prefilter degrade to the scope's whole file set — correct, and much slower.

**D10. Property NAME matching is case-insensitive in SQL; VALUE matching is
exact.** `Query.hs:489-494`: `LOWER(name) = LOWER(?)` for the name, `value = ?`
(or a comparator) for the value. Measured on the Emacs side: `org-entry-get` is
also case-insensitive on names (L7), and org-ql's value comparison is
case-*sensitive* — `(property "OWNER" "JOHN")` does not match `john`. The two
engines therefore agree on values, and the database is no narrower than Org on
names. Both directions are what a superset argument needs.

**D11. `entry_properties` has PRIMARY KEY `(entry_id, name)`; `file_properties`
allows repeats.** `Schema.hs:215-223`, and `Migrate.hs:62-66` adds a `position`
column to `file_properties` precisely so repeated keys survive there. So a claim
that the database "keeps one row per drawer line" is imprecise: it keeps at most
*one row per name per entry*, and two same-named lines in one drawer would
violate the key on insert (the `+` spelling never gets that far, D6). The
downgrade of property equality to existence over a separator-bearing value (L8)
is still right; the reason is that no stored value can equal a joined one, not
that many rows exist.

**D12. `files.path` is `canonicalizePath`d.** `Org/DB/Store.hs:105`. The `file`
field in the query JSON comes from that column, so it is absolute and
symlink-resolved — see E1 for what that costs a consumer that does not compare
truenames.

**D13. The `file` key is OMITTED when the path cannot be resolved.**
`Org/DB/Render.hs:31` (and documented at :17-19), `maybe "" (\f -> ",\"file\":\"" <> … ) mfile`. A row can
legitimately arrive with no `file` at all, so a consumer must tolerate its
absence rather than assume every object carries one.

**D14. `entries.id` is the `:ID:` property only when it looks like a UUID, and
otherwise a fresh random UUID on EVERY store.** `Org/DB/Store.hs:261-268`:
accepted only when non-empty and composed entirely of hex digits and dashes,
else `nextRandom`. So a database id is not stable across syncs for an
ID-less entry, and **must never be used to build a link**. Links are built from
the live buffer instead.

**D15. `store` skips a file whose recorded `mod_time` is not older than the file
on disk, and again if the content hash is unchanged.**
`Org/DB/Store.hs:107-121` (the mtime test at 110-113). A test fixture rewritten without advancing its mtime
is silently not re-stored — a very quiet way for a differential run to be
measuring the previous corpus.

**D16. `db init --dimensions N` is mandatory, and `store` requires it.**
`DB/Options.hs:147-152` (`option auto` with no default), and
`DB/Exec.hs:115` calls `requireEmbeddingDimensions` on the store path. So the
scratch-database reset sequence must be `unstore` → `init --dimensions N` →
`store`; `unstore` alone leaves a database that `store` refuses. `unstore` is
`DROP TABLE IF EXISTS … CASCADE` throughout, so it is safe on a virgin database.

**D17. Without `--keywords`, every entry stores with `keyword_value` NULL and
its keyword glued to the front of its title.** `~/org/org.yaml` declares
`startKeywords: []`, `openKeywords: []`, `closedKeywords: []`, so the parser
recognizes no keyword unless the DOT graph supplies them. A differential run
that omits `--keywords` will look sound and be meaningless.

**D18. Operator prerequisites for a scratch database.** The `ltree` and `vector`
extensions must exist; `db init` attempts both best-effort but they need a
superuser, so in practice:
`createdb org_agents_test && psql -d org_agents_test -c 'CREATE EXTENSION IF NOT
EXISTS ltree; CREATE EXTENSION IF NOT EXISTS vector'`.

**D19. The `file` field is answered with one `queryFilePath` round trip per
distinct file id.** `DB/Exec.hs:107-109`: `nub` over the rows, then a query per
id. The design asked for a join in `entrySelectSQL` instead. Correctness is
unaffected; the dedup is quadratic at three points (Haskell `nub`, a `lookup`
per row, and `cl-pushnew :test #'equal` in `org-db-cli.el`), which is worth
measuring before running the prefilter over the full corpus. A hash table is
already the idiom two calls away.

---

## 6. What is NOT established

**N1. RESOLVED 2026-08-19, by removing the second engine.** This entry used to
read: "The superset property has never been evaluated against a database" — 20
differential tests designed, wired, self-verifying, and never once run, because
no PostgreSQL was reachable during development. The prefilter is now ripgrep,
so the property is provable in a plain `make test`: the same fixture corpus is
handed to org-ql and to the prefilter in one Emacs, and the candidate set is
asserted to cover org-ql's own answer. Twenty such tests exist and run, each
naming the fixture file it loses under the mutation it guards against, and
every one of those mutations was applied and watched to fail. What replaced the
unproven argument is not a better argument; it is a suite that executes.

**N2. `set-window-buffer` signalling on the minibuffer window is not
reproducible.** `org-agents--update-dblock-in-window`'s docstring asserts it.
Measured: with a live minibuffer window (`window-minibuffer-p` ⇒ t,
`window-live-p` ⇒ t) and an inactive minibuffer, `set-window-buffer` succeeded
and `switch-to-buffer` in that window also succeeded; the documented error
condition for `set-window-buffer` in Emacs 30.2 is strong dedication, not the
minibuffer. The guard is harmless and may well be right while a minibuffer is
*active* — which batch cannot exercise — but treat the stated mechanism as
unverified rather than as a fact to build on.

**N3. MOOT 2026-08-19.** D6's drawer collapse was a defect in the org-jw
parser, which this package no longer reads through, and the expected-failure
test that recorded it is gone. What followed the old limitation through and
survives it is a requirement on the NEW backend, now discharged: a
line-oriented prefilter must admit the `:NAME+:` spelling, because
`org-entry-get` answers from a `:NAME+:` line with no plain `:NAME:` line above
it. The pattern is `^[ \t]*:NAME\+?:` and
`org-agents-test-rg-covers-an-accumulated-property-name` is what says so — an
ordinary passing test where there used to be an expected failure.

**N4. `.elc` tracking (E6) was established from `.gitignore` only**, because no
`git` command was run while writing this. A `git ls-files 'lisp/*.elc'` would
settle it in one line.

**N5. Two org-jw follow-ups recorded but not fixed.** The legacy `jsonEscape`
used by `db search` and `db review` does not escape C0 control characters (the
new `jsonEscapeText` in `Render.hs:34-44` does). And `erPath` (an ltree path) is
printed as `"file"` by some db review JSON printers. Neither affects the
prefilter path this package uses.
