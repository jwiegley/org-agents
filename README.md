# org-agents

Agents for Org-mode, in the sense Eastgate Tinderbox uses the word: an
ordinary Org entry that carries a query, and that populates itself with
links back to every entry in the corpus that matches when you ask it to
update.

An agent renders its matches three ways — as child "alias" headings, as a
plain list, or as a table. Queries are [org-ql](https://github.com/alphapapa/org-ql)
S-expressions with a compact `$PROP` property-reference layer on top.

Evaluation is *always* org-ql, against live buffers. There is exactly one
evaluation engine and therefore exactly one answer.
[ripgrep](https://github.com/BurntSushi/ripgrep) is an optional
candidate-**file** prefilter and nothing more: it can narrow the set of
files org-ql then opens and verifies, and it cannot change what matches.

One file makes up the package, `org-agents.el` (~2,700 lines), and one
tests it, `org-agents-test.el` — 199 ERT tests, all of which run in a
plain `make test` with no external service. The 25 that exercise the
prefilter end to end need `rg` on `PATH`, and `make test` says so when it
is missing.

## A worked example

Put this in a file, with point on the heading, and press whatever you bound
`org-agents-update` to:

```org
* Reviews that have come due
:PROPERTIES:
:AGENT_QUERY:  (and (todo) (property-ts $NEXT_REVIEW :to today))
:AGENT_FORMAT: NEXT_REVIEW
:AGENT_SORT:   date
:AGENT_LIMIT:  25
:END:
```

It uses the default `children` view and the default `agenda` scope, so it
searches `org-agenda-files` and needs no prefilter at all. Afterwards
the entry has grown one child per match, and a status line of its own:

```org
* Reviews that have come due
:PROPERTIES:
:AGENT_QUERY:   (and (todo) (property-ts $NEXT_REVIEW :to today))
:AGENT_FORMAT:  NEXT_REVIEW
:AGENT_SORT:    date
:AGENT_LIMIT:   25
:AGENT_MATCHED: 3 [2026-08-19 Wed 09:14]
:END:
** [[id:1F2E3D4C-...][Review: Renew the domain]] [2026-08-14 Fri]
:PROPERTIES:
:AGENT_MATCH: t
:END:
```

`$NEXT_REVIEW` is read as the property *name* there, because
`property-ts`'s first argument is a name. In another position the same
reference reads as the value, or as a number — see below.

Those child headings are aliases, and they are ephemeral: every update
deletes the ones that hold nothing but their own drawer and writes them
again. Write anything at all under an alias and it becomes yours: no update
deletes it, and when its match is gone it is retitled `(stale)` instead. A
child that never carried `:AGENT_MATCH: t` is not the package's to touch.

The update leaves the buffer modified and unsaved, deliberately, so the
result can be read over — and undone — before it is kept.

## The query language

The base language is org-ql's. On top of it, a `$PROP` reference expands
according to the position it appears in:

| Written | Expands to | Position |
| --- | --- | --- |
| `(and (todo) $URL)` | `(property "URL")` | boolean |
| `(string-match "gh" $URL)` | `(or (org-entry-get nil "URL") "")` | value |
| `(> $REVIEWS 3)` | `(string-to-number (or … "0"))` | numeric |
| `(property-ts $NEXT_REVIEW :to today)` | `"NEXT_REVIEW"` | name |
| `$OWNER*` | `(org-entry-get nil "OWNER" t)` | inherited |

The trailing `*` asks for inheritance. Seven specials reference the entry
itself rather than a property: `$ITEM`, `$TODO`, `$PRIORITY`, `$TAGS`,
`$CATEGORY`, `$LEVEL`, `$FILE`.

An org-ql query is Lisp, and org-ql evaluates residual Lisp at every
candidate entry, so a query read out of a property drawer is code out of a
file. The form that is evaluated passes a gate first. The *form*, not the
query: `org-agents-exclude` is conjoined in before org-ql sees it, so what
the gate shows, hashes and approves is the query with the exclusion
appended. A form built only from org-ql predicates, combinators and `$`
references runs unremarked; anything else asks once, and remembers the
answer by SHA-1 hash in `org-agents-safe-queries`. An approval therefore
names a form: change `org-agents-exclude` and every remembered approval
stops matching, and each agent asks again once.

A predicate head vouches for its own name and nothing more. org-ql runs
each predicate's *normalizer* when it compiles a query — after the gate
has admitted the head, and before any entry is examined — and a normalizer
is arbitrary code from wherever the predicate was defined. So a form the
gate calls structurally safe can still reach out. `org-agents-refused-heads`
names the heads that are refused outright: refusal is checked first, names
the head, and is beaten by nothing — not a remembered approval, and not
`org-ql-ask-unsafe-queries`, which governs whether the user is *asked*.
`semantic` ships in the list because `org-ql-semantic.el` defines it with a
normalizer that runs `org db search` in a subprocess. Matching is by
literal symbol, so an alias of an IO-bearing predicate has to be listed
too.

An Org property value is one line. Keep the query on one line, or name a
shorter one and let a residual predicate do the rest. A `:AGENT_QUERY+:`
continuation *is* read — `org-entry-get` joins the pieces with
`org--property-get-separator`, a space unless `org-property-separators`
says otherwise — so a query split at a whitespace boundary reads back
correctly. It is still a bad idea: split anywhere else and the pieces join
into a different sexp, or into one that will not read at all, and nothing
about the drawer says which happened.

## The property vocabulary

This is the whole of it, as implemented.

| Property | Meaning |
| --- | --- |
| `AGENT_QUERY` | the query. Required — this property is what makes an entry an agent. |
| `AGENT_VIEW` | `children` (default), `list`, or `table`. Any other value is refused rather than rendered. |
| `AGENT_SCOPE` | `agenda` (default), `active`, `all`, a directory relative to `org-directory`, or a `read`-able list of file names. |
| `AGENT_SORT` | `date`, `todo`, `priority`, `reverse`, or a list of those, which org-ql applies to the matched entries; or `(column N)` / `(ts-column N)`, which order the rows of a **table** view and are refused in any other. |
| `AGENT_LIMIT` | a count, applied after the sort. |
| `AGENT_COLUMNS` | whitespace-separated column names for a table view. `ITEM_BY_ID` is the link to the match; every other name is read as a property at the match. |
| `AGENT_FORMAT` | whitespace-separated property names, shown after the link in the `children` and `list` views. |
| `AGENT_MATCH` | written by the package on a generated alias, never by hand. |
| `AGENT_MATCHED` | written by the package after an update: how many entries matched, and when. |

Org reads the value `nil` as no value at all, so `:AGENT_VIEW: nil` is an
agent with no view rather than an error, and takes the default.

`AGENT_MATCHED`'s timestamp is inactive and therefore visible to a query:
`(ts-inactive :from ...)` over a corpus that holds agents will match the
agents themselves.

## Dynamic blocks

The `list` and `table` views render into an `org-agents` dynamic block.
`C-c C-x x` offers `org-agents` among the block types once the package has
loaded, and `C-c C-x C-u` updates the block at point.

A block written inside an agent entry overrides that entry's `AGENT_*`
properties name by name — `:view`, `:scope`, `:sort`, `:limit`, `:columns`,
`:format` — so one agent can carry several views of itself. A block with its
own `:query` needs no agent entry around it and can go in any file:

```org
#+BEGIN: org-agents :query (and (property "NEXT_REVIEW") (todo "TODO")) :view table :columns "ITEM_BY_ID NEXT_REVIEW LAST_REVIEW" :sort (ts-column 2) :limit 20
#+END:
```

A block's parameters are read as Lisp by Org before the package sees them,
so a block can say things a drawer never could. `:view "table"` is a string
and not the symbol `table`, and `:limit "5"` is not a count; both are
refused by name rather than rendered wrongly.

## Commands and options

| Command | What it does |
| --- | --- |
| `org-agents-update` | update the agent at point, or the block point is inside |
| `org-agents-update-buffer` | update every agent in the current buffer |
| `org-agents-update-all` | update every agent in the files `org-agents-files` names |
| `org-agents-preview` | `org-ql-search` over a query read from the minibuffer, expanded and gated exactly as an agent's is, with `org-agents-exclude` appended, over `org-agenda-files` |
| `org-agents-insert-dblock` | insert an empty `org-agents` block at point |
| `org-agents-list-approvals` | list every remembered approval and refusal, each with the query its hash covers; `d` forgets an approval, `r` turns it into a refusal, `u` lifts a refusal |
| `org-agents-mode` | update this buffer's agents before each save |
| `global-org-agents-mode` | turn `org-agents-mode` on in every Org buffer whose text mentions `:AGENT_QUERY:` |

| Option | Default | Meaning |
| --- | --- | --- |
| `org-agents-files` | `'("~/org/agents.org")` | where `org-agents-update-all` looks: files, directories, or the symbol `agenda` |
| `org-agents-exclude` | `(not (property "AGENT_MATCH"))` | conjunct appended to every agent query and every preview, so agents do not consume each other's aliases. Part of the form the gate approves: Lisp here is gated like Lisp in a query, and changing it invalidates every remembered approval |
| `org-agents-refused-heads` | `(semantic)` | predicate heads refused outright, before the safe list and before any approval, because org-ql runs their normalizers past the gate |
| `org-agents-refused-queries` | `nil` | forms refused outright by hash, beating every approval; managed through `org-agents-list-approvals` |
| `org-agents-safe-queries` | `nil` | forms approved to run without prompting, each recorded as `(HASH . QUERY-TEXT)` |
| `org-agents-prefilter` | `auto` | whether to narrow an unbounded scope with ripgrep: `auto`, `require` (refuse a scope that cannot be narrowed rather than scan it live), or `nil` (never spawn anything) |
| `org-agents-rg-executable` | `"rg"` | the ripgrep binary, resolved against `exec-path`. Set it where ripgrep is installed under another name, or in a directory Emacs's `exec-path` does not hold — routine on macOS, where a GUI Emacs does not inherit a login shell's PATH |

An approval is recorded as `(HASH . QUERY-TEXT)` — the hash and the very
text it was taken of, so `org-agents-list-approvals` can show what each
remembered decision covers instead of a bare forty characters of SHA-1.
From that listing `d` forgets an approval (in this session as well as on
disk — an approval revoked only where it was saved would go on working
until Emacs restarted), `r` turns it into a refusal recorded in
`org-agents-refused-queries`, and `u` lifts a refusal, which returns the
query to *needing* approval rather than to having it. A refusal is
consulted before the safe list and before `org-ql-ask-unsafe-queries`, so
no later yes can undo one. An entry that is a bare hash string was written
by an earlier version; it is still honoured, and listed as legacy, because
nothing can recover the query it stood for.

Both lists are persisted through `customize-save-variable`, which writes to
the file `(custom-file t)` names — and writes nothing at all unless
`user-init-file` is set, saying so in a message. Where the real init is a
tangled Org file, `user-init-file` is the tangled output and a saved
approval is lost the next time it is generated. Set `custom-file` to a file
of its own to keep approvals.

## Updating on save

`org-agents-mode` is a buffer-local minor mode that updates every agent in
the buffer before it is saved, so what reaches the file is what the queries
match now rather than what they matched the last time somebody remembered to
ask. It refuses to enable outside Org, and it hooks only the buffer it was
enabled in.

`global-org-agents-mode` turns it on in every Org buffer whose text mentions
`:AGENT_QUERY:`. That test is a plain regexp search over the text and not the
scan `org-agents-update-buffer` uses, which asks each heading's own drawer. It
decides only whether to arm a hook, so a buffer that merely quotes the
property line in a body is armed too. The cost of arming one wrongly is the
real scan on each of its saves, finding nothing and doing nothing; the cost of
deciding it properly here would be that same scan in every Org buffer you
visit, agent or no agent.

Three things are deliberately not done, and together they are what make the
mode usable rather than a tax on saving.

**A save spawns no prefilter, whatever `org-agents-prefilter` is set to.**
`org-agents--scope-files` already declines one for every scope a save
updates — `agenda` and an explicit file list name their files — so the
binding on the save path is a belt rather than the rule. It is worth
wearing: it makes "a save spawns no subprocess" a property of
`org-agents--update-on-save` rather than something a reader has to derive
from a rule stated two sections away. Nothing is lost by it, because the
prefilter only ever narrows the candidate file set and never changes an
answer. The manual commands keep it, which is where waiting for it is
something you chose to wait for.

**An agent whose scope needs a prefilter is not updated on save.**
`active`, `all` and a directory have no bound on what they would open, and
an update of one is work a keystroke should not be doing. So those agents
are dropped before the update and named once in the echo area, one message
however many there are. `org-agents-update` still refreshes any of them on
demand. There is no option to override this.

**A save whose render changes nothing changes no bytes.** `:AGENT_MATCHED:`
records when an update ran, so stamping it on every save would rewrite the
file, and the date a reader trusts, whether or not the query found anything
new. So the buffer text before the update is compared against the text after
it with the `:AGENT_MATCHED:` lines masked out of both; where the rest is
identical the render wrote what was already there, the snapshot is put back
with `replace-buffer-contents` — a minimal diff, so point and every marker
survive — and the file reaches disk byte-identical, old stamps included. A
stamp is worth reading only if it dates the render it describes.

A failure is reported and the save then goes through: a file must not become
unsavable because a query written in it has a typo, since fixing the typo is
what the next save is for. `C-g` is the exception, and deliberately so — a
quit during an update on save aborts the save along with the update, rather
than committing a render that was interrupted half way through.

```elisp
;; Every Org buffer that holds an agent, for the rest of the session.
(global-org-agents-mode 1)
```

`M-x org-agents-mode` arms one buffer, for someone who would rather say where.
Hooking it to `org-mode-hook` instead arms every Org buffer whether or not it
holds an agent, and each of their saves then pays for the scan that finds none.

## Installation

### Requirements

* Emacs 29.1
* [org-ql](https://github.com/alphapapa/org-ql) 0.8 — `org-ql` and
  `org-ql-search`, both of which ship together
* Org itself, which is bundled. The package was developed against Org
  9.8.7; no lower bound has been established by testing, and none is
  declared.
* [ripgrep](https://github.com/BurntSushi/ripgrep) 13 or later, and only
  for the prefilter. Without it, `agenda` and file-list scopes work
  exactly as they do with it, and an unbounded scope is scanned live with
  one message saying so. The argument vector was verified against 15.2.0
  and no other version; 13 is a round, safely old floor, named because the
  prefilter passes `--crlf`. Point `org-agents-rg-executable` at the binary
  where a bare `rg` is not on Emacs's `exec-path`.

### The two repo-local dependencies

`org-agents.el` requires `org-ql-ext`, which requires `org-ext`. **Neither
is part of this repository.** They are single-file modules from the author's
Emacs configuration (`dot-emacs/lisp/org-ql-ext.el` and
`dot-emacs/lisp/org-ext.el`), and `org-ql-ext` is where the `property-ts`
predicate the examples above lean on comes from.

Because they are not on any package archive, they cannot be declared in
`Package-Requires`, and `org-agents` cannot be installed as a
self-contained package until that is resolved. What has to be true is only
that both files are on `load-path` before `org-agents` is required.

Where this repository is checked out *inside* `dot-emacs/lisp`, both files
sit in its parent directory, and every entry point here defaults to looking
for them there:

```sh
make test                        # uses ../ for the dependencies
make test DEPS_DIR=/elsewhere    # or say where they are
```

### Configuration

Both files must be on `load-path`. Then, in the style of the surrounding
Org extensions in the author's init:

```elisp
(use-package org-agents
  :after (org-ql-ext)
  :commands (org-agents-update
             org-agents-update-buffer
             org-agents-update-all
             org-agents-preview
             org-agents-mode
             global-org-agents-mode)
  ;; Org calls the dynamic-block writer by name, from C-c C-x C-u and from
  ;; `org-update-all-dblocks', so it has to be autoloaded as well.
  :autoload (org-dblock-write:org-agents)
  :bind (("M-s a" . org-agents-preview)
         :map org-mode-map
         ("C-c C-x Q" . org-agents-update))
  :custom
  (org-agents-files '("~/org/agents.org")))
```

Nothing else is needed. `org-agents-prefilter` defaults to `auto`, which
uses `rg` from `exec-path` where it is found and scans live where it is
not; set it to `require` to be refused rather than kept waiting, or to
`nil` never to spawn anything. Where ripgrep is installed under another
name, or somewhere Emacs's `exec-path` does not reach, name it with
`org-agents-rg-executable`.

## Running the tests

There is no `emacs` on PATH on the machine this was written on — the
interpreter comes out of the nix store — so every target below finds one, or
takes `EMACS=/path/to/emacs`. Never point it at an Emacs invoked with `-Q`:
org-ql lives in site-lisp, which `-Q` suppresses.

```sh
make test        # 199 tests, no external service needed
make test-one T=org-agents-test-expand
make gate        # byte-compile, and fail on any warning at all
make check       # gate, then test
```

`make test` reports `199 tests, 199 results as expected, 0 unexpected` and
takes about twenty seconds. There is nothing to configure and nothing to
set up. Where `rg` is not on `PATH` it reports `174 results as expected, 0
unexpected, 25 skipped`, and prints one line saying why — `skip-unless` is
honest but silent, and silence is precisely what let this suite's
predecessor report green for months while proving nothing.

The tests that describe what a machine WITHOUT ripgrep does — the live
fallback, its one message, `require` refusing, `nil` never spawning — do
not skip there, which is the whole point of them. They supply their own
ripgrep, or none.

The pattern, argument-vector and exit-status tests never skip. That is
deliberate: every under-match measured while the prefilter was designed
originated in a pattern or a missing flag, and none of it needs a
subprocess to test.

## The byte-compile gate

`org-agents.el` is kept warning-free under the byte compiler, and
`tools/org-agents-byte-compile-gate.sh` is what says so. It compiles the
file and exits nonzero on any warning at all, including a docstring line
over 80 columns.

It builds the two repo-local dependencies first, into a temporary directory
placed ahead of everything on `load-path`. That is not tidiness: where no
`.elc` exists for them, `(require 'org-ql-ext)` loads both as *source*,
which evaluates each one's `(eval-when-compile (require 'cl))` and reports
"Package cl is deprecated" against the `require` lines *here* rather than
theirs. Building them first reproduces the environment this code actually
runs in. Their own warnings are their own business and are not gated;
neither file is warning-free, for reasons that have nothing to do with this
package. Nothing is written into the dependency directory, which by default
is somebody else's live Emacs configuration.

A full run takes about five seconds, or ten if the script has to search
the nix store for an Emacs. An earlier note in this repository claimed two
and a half minutes; that is not reproducible and should not be budgeted
for — see `docs/measured-facts.md` E9, which was written to kill exactly
that belief. Do not skip the gate on the assumption it is slow: it is the
only thing enforcing the zero-warning invariant.

## The ripgrep prefilter

**The prefilter can only narrow which files org-ql then verifies. It can
never change an answer.** Every match is still decided by org-ql, in Emacs,
against the live buffer. What ripgrep produces is a set of candidate files,
which is intersected with the files the agent's scope names so that org-ql
opens fewer buffers.

Only a conjunct whose ripgrep answer is *provably a superset* of org-ql's is
pushed; everything else stays residual and is applied by org-ql. Five
shapes push today:

| Conjunct | Pattern | Why it is a superset |
| --- | --- | --- |
| `(property "P")` | `^[ \t]*:P\+?:` | A non-nil `org-entry-get` with `inherit` nil needs a drawer line matching `org-property-re` whose key upcases to `P` or `P+`. The `\+?` is required: an entry whose only line is `:P+: v` answers `"v"`. |
| `(property "P" "v")` | `^[ \t]*:P\+?:[ \t]+v[ \t]*$` | `org-entry-get` joins `:P:` and each `:P+:` with `org--property-get-separator`, so a value that does not contain that separator came from exactly one line. A value that does — or an empty one, or an empty separator — downgrades to the existence pattern above. |
| `(property-ts "P" …)` | as existence | A date match on the value implies the property is there. |
| `scheduled` / `deadline` / `closed` | `SCHEDULED:[ \t]*<`, `DEADLINE:[ \t]*<`, `CLOSED:[ \t]*\[` | Every branch of `org-ql--predicate-ts` begins with a search for the keyword and the bracket, so org-ql cannot match without that text. Bounds are dropped, which drops a *conjunct* of org-ql's condition and never adds one. Deliberately unanchored: all three keywords may share one planning line, in any order. |
| `(heading "lit" …)` | `^\*+(?-u:.)*lit`, one per literal, intersected | org-ql `regexp-quote`s every `heading` argument, so a heading argument is always a literal and is sought as text on both sides — regexp syntax is pushed. `org-get-heading t t` reassembles the title from `org-complex-heading-regexp`'s groups joined by one space, and each group is preceded in the line by at least one real space, so the only substring the line need not spell is one crossing the priority-cookie junction — and every one of those holds the `]` that the guard refuses. `]` is the only character refused. `(?-u:.)` rather than `.` because in ripgrep's Unicode mode `.` matches a codepoint and cannot cross an invalid UTF-8 byte. |

`todo`, `tags`, `regexp`, `ts`, `category`, `priority`, `level` and `path`
are all residual, and so is every conjunct under `or` or `not` and every
nested query — by omission, which widens. A literal is pushed only when
every character in it is printable ASCII: ripgrep decodes as UTF-8 while
Emacs may decode a file as latin-1, and `--encoding` is one global setting
that a mixed corpus cannot use.

Three consequences worth knowing before you rely on it:

* A broad `org-use-property-inheritance` — `t` most of all — makes no
  property conjunct pushable, so a property-only agent falls back to its
  scope's whole file set. Still correct, and much slower. The prefilter's
  value depends on keeping inheritance narrow.
* The scopes `active`, `all` and any directory do not name the files they
  will open. Where one cannot be narrowed — no ripgrep, a query with
  nothing to push, a failed ripgrep run, or `org-agents-prefilter` nil — it
  is scanned live and one message says so, naming the file count. Set
  `org-agents-prefilter` to `require` to be refused instead. The failed run
  is the only one of the four you cannot cause on purpose; see the
  limitations below.
* An over-match is a cost, not a fault. A `:P: v` line in ordinary body
  prose, in no drawer, puts its file in the candidate set; org-ql then does
  not match it, and the agent renders nothing for it.

What this measures, on the author's 3,669-file corpus, for
`(and (todo) (property "NEXT_REVIEW"))` over scope `all`:

| | |
| --- | --- |
| `directory-files-recursively` over the corpus | 0.27 s, 3,669 files |
| one ripgrep run | 0.09 s, 314 files |
| the whole of `org-agents--scope-files` | 0.73 s |
| org-ql over those 314 files | 4–26 s, 764 matches, 320 buffers |
| org-ql over all 3,669 files, same query | 172 s, 764 matches, 3,675 buffers |

**Read those last two rows as orders of magnitude, not as benchmarks.** They
move by more than the difference between them, for two reasons that have nothing
to do with this package. Measured on one machine, one query, one corpus: the same
314 files took 26 s cold and 3.9 s once the OS page cache was warm — 6.6× — and
the same 600-file slice took 103 s at the batch default `gc-cons-threshold` of
800,000 against 22 s at 512 MB — 4.7×, because opening thousands of Org buffers
makes garbage faster than the collector's default budget expects. The 172 s above
is at `gc-cons-threshold` 128 MB, which is what the author's own configuration
sets; at the batch default the same run did not finish in nine minutes. Two
careful people measuring this disagreed by an order of magnitude before either
thought to say which of those two states they were in.

The row that does *not* move is the ripgrep run: 0.09 s, indifferent to both. And
the number that actually explains the design is the buffer count — **320 against
3,669**. org-ql's own preamble makes a file with no `:NEXT_REVIEW:` line a cheap
scan, so the 3,355 files ripgrep removes were never the expensive part; what they
cost is 3,355 `find-file-noselect` calls with full `org-mode` initialisation. The
prefilter buys buffers and memory, not regexp work.

There is no staleness window. ripgrep reads the bytes on disk as they are
now, so a file that *newly* satisfies a pushed conjunct is in the candidate
set immediately. There is nothing to sync and no cadence to keep.

## Honest limitations

### 1. An accumulated property value is compared by existence, not by value

`org-entry-get` joins `:TOKENS: alpha` and `:TOKENS+: beta` into
`"alpha beta"`, a string that appears on **no single line of the file**. No
line-oriented matcher can find it, ripgrep included. So a `(property "P"
"v")` conjunct whose value could have been assembled that way — one that
contains `org--property-get-separator` for `P`, or where that separator is
empty — is downgraded to the existence pattern, which is wider and
therefore sound.

This is a deliberate widening rather than a bug, and the widening is what
makes it safe. The rule is stated in terms of the separator and not of
whitespace, because they only coincide by default: with
`org-property-separators` set to `(("P") . "/")`, `:P: al` plus `:P+: pha`
answers `"al/pha"` — no whitespace in it, and no line in the file spelling
it. `org-agents-test-rg-downgrades-a-value-it-cannot-see-on-one-line`
pins that case.

The `(property "P")` direction, by contrast, is exact: the pattern admits
the `:P+:` spelling, so an entry whose only line is `:P+: beta` is in the
candidate set. (An earlier version of this package prefiltered through a
PostgreSQL index built by a separate CLI; ripgrep replaced it, and there
the `:P+:` spelling was a recorded expected failure. Nothing in the
package speaks to a database any more, and there is nothing to install or
configure for the prefilter beyond ripgrep itself.)

### 2. A buffer-wide update refreshes only an agent's first dynamic block

One agent may carry several blocks, each its own view of it. An update that
was not asked for from inside a particular block writes only the **first**:
`org-agents-update` with point outside a block, and therefore
`org-agents-update-buffer` and `org-agents-update-all`, refresh that one and
leave the rest as they were. Put point in a block to write that block, or
use `org-update-all-dblocks` to write every block in the buffer.

### 3. Deleting a pristine alias discards what you added to its drawer

An alias holding nothing but `:AGENT_MATCH: t` is *pristine* and belongs to
the package: every update deletes it and writes it again. Because it is
deleted rather than edited, **extra drawer properties or tags you added to a
body-less alias are discarded.** Write a line under the alias and they are
kept along with it.

### 4. One unreadable file, or one symlink loop, disables the prefilter corpus-wide

ripgrep exits 2 for any per-file I/O error — an unreadable `.org` file, a
dangling `*.org` symlink, a directory symlink loop — and it can print a
partial answer *and* exit 2 at the same time. A partial answer is exactly
the unsound direction, so the package **discards it on purpose** and treats
the whole run as a failure. That is the right call, and its cost is blunt:
one such file anywhere under the scope's root sends every corpus-scope
agent down the live path on every update, and under
`org-agents-prefilter` `require` makes them refuse to update at all. The
message names ripgrep's own stderr, which names the offending path; there
is nothing to do but fix the file.

The loop case is arrived at deliberately. ripgrep is run with `--follow`
because `directory-files-recursively` *lists* a symlink to a file outside
the tree and org-ql matches through it, so without `--follow` the
candidate set would be narrower than the scope's own file list — a lost
match rather than a slow one. Following symlinks is therefore on, and a
convenience symlink pointing at an ancestor directory is fatal to the
prefilter for as long as it is there.

Also worth knowing: a personal ripgrep configuration cannot narrow the
candidate set. `RIPGREP_CONFIG_PATH` is unset for the child, because
ripgrep prepends that file's arguments to the command line and the
package's own flags do not override `--max-depth`, `--max-filesize`,
`--pre`, `--encoding` or `--glob`.

### Others, less sharp

* Changing `org-agents-exclude` re-prompts for every previously approved
  query, once each. By design: the gate approves the form that runs, the
  exclusion is part of that form, and an approval that survived a change to
  it would be an approval of something the user never saw. Anyone upgrading
  from a version that gated the query alone will see the same one-time
  re-prompt, because the stored hashes are of the old shape.
* On this platform `directory-files-recursively` can intermittently drop a
  symlink to a FILE from an `active` or `all` scope's base file set:
  `file-name-all-completions` sometimes reports such a link with a trailing
  slash, which makes the walk take it for a directory it must not follow.
  So a corpus assembled out of per-file symlinks may see matches in the
  linked files appear and disappear between updates, with no message. A
  symlink to a DIRECTORY is unaffected, and so is the prefilter — ripgrep
  reports the file either way; it is the scope's own file list that
  wavers, and it has the last word.

* A preserved alias keeps the description and format suffix it was written
  with. Only the stale mark changes, so an alias whose match has since been
  renamed goes on showing the old title.
* An alias is recognized by the target it links to, so a match that gains an
  `:ID:` between updates is a *different* target: the old alias is marked
  stale and a new one is written beside it.
* Two matches with no ID and identical headings in one file share one
  `file:...::*` target, so one alias may stand for both while
  `AGENT_MATCHED` counts two. Give them IDs to tell them apart.
* A planning bound is never pushed, only the presence of the stamp:
  ripgrep cannot compare dates. org-ql applies the bound, so this costs
  candidate files and never a match. Every shape now pushes the stamp,
  including `(deadline 7)` and `(deadline auto)`, which the database
  predecessor could not push at all — a bound had to be resolved to a
  calendar day that a second engine would read the same way, and these
  two have no such day.
* A non-ASCII literal is not pushed, for the encoding reason above. A
  `(heading "Café")` agent over a corpus scope therefore narrows by its
  other conjuncts only, or not at all.
* There is no file-count ceiling under which an unbounded scope would be
  walked live without a prefilter even being attempted. With
  `org-agents-prefilter` at its `auto` default the live walk is what
  happens anyway, so this matters only under `require`.

## License

Free software. `org-agents.el` carries a GNU General Public License notice —
version 2 or later — and names John Wiegley as the copyright holder.

The other source is less tidy than that: `org-agents-test.el` carries no
copyright or license notice at all. Extracting this package into a
repository of its own is the moment to settle it, and this README does not
pretend it is settled.
