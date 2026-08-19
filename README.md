# org-agents

Agents for Org-mode, in the sense Eastgate Tinderbox uses the word: an
ordinary Org entry that carries a query, and that populates itself with
links back to every entry in the corpus that matches when you ask it to
update.

An agent renders its matches three ways — as child "alias" headings, as a
plain list, or as a table. Queries are [org-ql](https://github.com/alphapapa/org-ql)
S-expressions with a compact `$PROP` property-reference layer on top.

Evaluation is *always* org-ql, against live buffers. There is exactly one
evaluation engine and therefore exactly one answer. The PostgreSQL
database maintained by the `org db` CLI of
[org-jw](https://github.com/jwiegley/org-jw) is an optional
candidate-**file** prefilter and nothing more: it can narrow the set of
files org-ql then opens and verifies, and it cannot change what matches.

Two files make up the package:

| File | What it is |
| --- | --- |
| `org-agents.el` | the package (~2000 lines) |
| `org-db-cli.el` | the bridge to the `org db` CLI (~160 lines) |

and two more test it: `org-agents-test.el` and `org-db-cli-test.el`, 176
ERT tests between them. 20 of those need a database; see
[Honest limitations](#honest-limitations) before you trust them.

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
searches `org-agenda-files` and needs nothing from the database. Afterwards
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
** [[id:1F2E3D4C-...][Review: Renew the domain]]  [2026-08-14 Fri]
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
file. Every query passes a gate before it is evaluated. A query built only
from org-ql predicates, combinators and `$` references runs unremarked;
anything else asks once, and remembers the answer by SHA-1 hash in
`org-agents-safe-queries`.

An Org property value is one line, and a query cannot be continued onto the
next. Do **not** write `:AGENT_QUERY+:`: see limitation 2 below for what the
`+` does. Keep the query on one line, or name a shorter one and let a
residual predicate do the rest.

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

| Option | Default | Meaning |
| --- | --- | --- |
| `org-agents-files` | `'("~/org/agents.org")` | where `org-agents-update-all` looks: files, directories, or the symbol `agenda` |
| `org-agents-exclude` | `(not (property "AGENT_MATCH"))` | conjunct appended to every agent query and every preview, so agents do not consume each other's aliases |
| `org-agents-safe-queries` | `nil` | SHA-1 hashes of queries approved to run without prompting |

`org-agents-safe-queries` is persisted through `customize-save-variable`,
which writes to `custom-file` or, without one, to `user-init-file`. Where
the real init is a tangled Org file, `user-init-file` is the tangled output
and a saved approval is lost the next time it is generated. Set
`custom-file` to a file of its own to keep approvals.

## Installation

### Requirements

* Emacs 29.1
* [org-ql](https://github.com/alphapapa/org-ql) 0.8 — `org-ql` and
  `org-ql-search`, both of which ship together
* [ts](https://github.com/alphapapa/ts.el) 0.2 — used directly, by
  `org-agents--absolute-date`, so that a relative date is resolved with the
  same `ts-adjust` org-ql resolves one with and the two cannot drift apart
* Org itself, which is bundled. The package was developed against Org
  9.8.7; no lower bound has been established by testing, and none is
  declared.

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
(use-package org-db-cli
  :after org
  :custom
  (org-db-cli-executable "org")
  (org-db-cli-config-file "~/org/org.yaml")
  ;; A relative `file' field resolves against `org-directory' when this is
  ;; nil, which is what the files table holds for anything under ~/org.
  ;; (org-db-cli-files-directory "~/org/")
  :config
  ;; `setq' in `:config', not `:custom': a `:custom' form is evaluated as
  ;; init loads, and this one reaches auth-source.
  (setq org-db-cli-db-url
        (format "postgresql://USER:%s@HOST:5432/org"
                (lookup-password "HOST" "USER" 5432))))

(use-package org-agents
  :after (org-ql-ext)
  :commands (org-agents-update
             org-agents-update-buffer
             org-agents-update-all
             org-agents-preview)
  ;; Org calls the dynamic-block writer by name, from C-c C-x C-u and from
  ;; `org-update-all-dblocks', so it has to be autoloaded as well.
  :autoload (org-dblock-write:org-agents)
  :bind (("M-s a" . org-agents-preview)
         :map org-mode-map
         ("C-c C-x Q" . org-agents-update))
  :custom
  (org-agents-files '("~/org/agents.org")))
```

The `org-db-cli` block is optional. Leave `org-db-cli-config-file` at `nil`
and the bridge reports itself unconfigured and is never called; agents whose
scope is `agenda` or an explicit file list go on working exactly as they do
with it.

## Running the tests

There is no `emacs` on PATH on the machine this was written on — the
interpreter comes out of the nix store — so every target below finds one, or
takes `EMACS=/path/to/emacs`. Never point it at an Emacs invoked with `-Q`:
org-ql lives in site-lisp, which `-Q` suppresses.

```sh
make test        # both suites: 176 tests, of which 20 skip (see below)
make test-fast   # the same, minus the database suite, which is then not
                 # run even if its environment is set
make test-db     # ONLY the database suite, saying which variables are unset
make test-one T=org-agents-test-expand
make gate        # byte-compile, and fail on any warning at all
make check       # gate, then test
```

`make test` reports `176 tests, 156 results as expected, 0 unexpected, 20
skipped` on a machine with no test database configured. That is the expected
result, and the 20 skips are the subject of the first limitation below.

The differential suite runs only when all four of these are set:

| Variable | What it must be |
| --- | --- |
| `ORG_AGENTS_TEST_DB_URL` | DSN of a **scratch** database. Every run drops every data table in it, so the suite refuses any DSN whose name does not contain `org_agents_test`. |
| `ORG_AGENTS_TEST_CONFIG` | org-jw YAML config, e.g. `~/org/org.yaml` |
| `ORG_AGENTS_TEST_KEYWORDS` | keywords DOT file, e.g. `~/org/org.dot`. Required: the YAML declares empty keyword lists, so without it every entry stores with `keyword_value` NULL and `TODO` glued onto the front of its title. |
| `ORG_AGENTS_TEST_ORG_EXE` | a `cabal build`-ed org-jw `org` carrying the `file` field in `db query --format json`. The `org` on PATH does **not** have it, and without the field every candidate set comes back empty — which looks exactly like a sound but narrow prefilter. `ORG_AGENTS_TEST_ORG_BIN` is read as an alternative spelling. |

One-time operator setup, and the reason it is not automated: `db init`
creates the two extensions best-effort, but they need a superuser.

```sh
createdb org_agents_test
psql -d org_agents_test -c 'CREATE EXTENSION IF NOT EXISTS ltree;
                            CREATE EXTENSION IF NOT EXISTS vector'
```

Absent, the whole section skips silently. Present but unusable, it fails
loudly — a mis-set DSN that quietly disabled the suite would be worse than a
red test.

## The byte-compile gate

`org-agents.el` and `org-db-cli.el` are kept warning-free under the byte
compiler, and `tools/org-agents-byte-compile-gate.sh` is what says so. It
compiles the two files and exits nonzero on any warning at all, including a
docstring line over 80 columns.

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

A full run takes about two and a half minutes, nearly all of it
`org-agents.el`.

## The database prefilter

`org-db-cli-query-files SKELETON` shells out to

```
org --config CFG db --db-url URL query --ql SKELETON --format json
```

and returns a sorted list of distinct absolute files, or `nil` — plus a
message — on any failure. It never signals. (A `quit` from `C-g` during a
synchronous run still escapes, as it must.)

What that list is used for, and the whole of it: intersecting it with the
files the agent's scope names, so that org-ql opens fewer buffers. **The
prefilter can only narrow which files org-ql then verifies. It can never
change an answer.** Every match is still decided by org-ql, in Emacs,
against the live buffer.

Only a conjunct whose database answer is *provably a superset* of org-ql's
is pushed into the skeleton; everything else stays residual and is applied by
org-ql. Six shapes push today: `(property "P")`, `(property "P" "v")` (as
equality where the value has no whitespace, downgraded to existence where it
does), `(property-ts $P …)` as existence, the three planning predicates
`scheduled` / `deadline` / `closed`, and `(heading "literal")` where the
string holds no regexp metacharacter. `todo`, `tags`, `regexp`, `ts`,
`category`, `priority`, `level` and `path` are all residual, each for a
divergence recorded in the design document.

Two consequences worth knowing before you rely on it:

* A broad `org-use-property-inheritance` — `t` most of all — makes no
  property conjunct pushable, so a property-only agent falls back to its
  scope's whole file set. Still correct, and much slower. The prefilter's
  value depends on keeping inheritance narrow.
* The scopes `active`, `all` and any directory do not name the files they
  will open, and an agent using one **errors** when no prefilter is
  available rather than walking the corpus. Since the bridge cannot
  distinguish "the database failed to answer" from "the database answered,
  and no file matches", such an agent whose query genuinely matches nothing
  reports a missing prefilter. A needless error, never a wrong answer.

Staleness, stated plainly: a file whose contents changed since the last `org
db sync` is still verified live if it is in the candidate set, but a file
that *newly* satisfies a pushed conjunct since the last sync is missed until
the next one. Freshness is your own `org db sync` cadence; this package does
not wrap it.

## Honest limitations

### 1. The superset property is designed and self-checking, but unproven

The 20 tests of the differential suite exist to prove the one property the
prefilter must have: for every row of the push-down table, the candidate
file set the database answers with is a superset of the files org-ql
actually matches. No unit test over a skeleton string can establish that;
only running both engines over one corpus can.

**Those 20 tests have never been executed against a live database.** They
are written, wired, gated, and self-checking — the suite refuses a
non-scratch DSN, checks the CLI's symbol table for the `file`-field patch,
and asserts both sides non-empty so that a fixture which quietly stopped
matching cannot make the relation hold for want of anything to relate — and
they have not run. `make test` skips all 20 and reports green. That green
says nothing whatever about the superset property.

Until they run, treat the push-down table as a careful argument rather than
as a verified one.

### 2. A `:PROP+:` continuation line silently costs the whole drawer

`FlatParse.Combinators.identifier` in org-jw accepts alphanumerics, `_` and
space, and no `+`. So `:TOKENS+: beta` cannot be read as a property line,
`parseProperties` fails for the drawer, and the drawer degrades to a plain
body block. `entry_properties` then gets **no row at all** — not for
`TOKENS+`, and not for the perfectly ordinary `:TOKENS: alpha` line above
it.

Consequence: `org-entry-get` joins the two lines into `"alpha beta"` and
org-ql matches, while a pushed `(property "TOKENS")` answers with no file.
The prefilter drops a true match, and nothing says so. The fix belongs in
org-jw, in `identifier` and in the accumulation semantics `Store.hs` would
then need.

This is recorded as a deliberately failing test,
`org-agents-test-diff-accumulated-property-breaks-superset`, marked
`:expected-result :failed`. Note what that costs: because it is DB-gated it
currently skips, and because it is marked expected-failure it will not turn
the suite red even once it runs. It is a record, not an alarm.

### 3. A buffer-wide update refreshes only an agent's first dynamic block

One agent may carry several blocks, each its own view of it. An update that
was not asked for from inside a particular block writes only the **first**:
`org-agents-update` with point outside a block, and therefore
`org-agents-update-buffer` and `org-agents-update-all`, refresh that one and
leave the rest as they were. Put point in a block to write that block, or
use `org-update-all-dblocks` to write every block in the buffer.

### 4. Deleting a pristine alias discards what you added to its drawer

An alias holding nothing but `:AGENT_MATCH: t` is *pristine* and belongs to
the package: every update deletes it and writes it again. Because it is
deleted rather than edited, **extra drawer properties or tags you added to a
body-less alias are discarded.** Write a line under the alias and they are
kept along with it.

### Others, less sharp

* A preserved alias keeps the description and format suffix it was written
  with. Only the stale mark changes, so an alias whose match has since been
  renamed goes on showing the old title.
* An alias is recognized by the target it links to, so a match that gains an
  `:ID:` between updates is a *different* target: the old alias is marked
  stale and a new one is written beside it.
* Two matches with no ID and identical headings in one file share one
  `file:...::*` target, so one alias may stand for both while
  `AGENT_MATCHED` counts two. Give them IDs to tell them apart.
* A relative date in a planning bound is resolved to an absolute local date
  when the query is pushed, so a skeleton always carries a `"YYYY-MM-DD"`
  whatever the agent wrote. The day is fixed when the query is built, so an
  update running across local midnight uses the day it started on.
* Writing `AGENT_MATCHED` changes the entry's content, so `org db sync` sees
  every agent as changed on every update: its children are stored again and
  its title re-embedded.
* There is no file-count ceiling under which an unbounded scope could be
  walked live rather than refused. That is the obvious way to soften the
  corpus-scope error and it is not implemented.

## License

Free software. `org-agents.el` carries a GNU General Public License notice —
version 2 or later — and names John Wiegley as the copyright holder.

Three of the four sources are less tidy than that: `org-db-cli.el`,
`org-agents-test.el` and `org-db-cli-test.el` carry no copyright or license
notice at all. Extracting this package into a repository of its own is the
moment to settle it, and this README does not pretend it is settled.
