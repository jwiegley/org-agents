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

One file makes up the package, `org-agents.el` (~8,700 lines), and one
tests it, `org-agents-test.el` — 449 ERT tests, all of which run in a
plain `make test` with no external service. The 40 that exercise the
prefilter and the attribute census end to end need `rg` on `PATH`, and
`make test` says so when it
is missing.

Beside the agents there is an optional second file, which declares the
corpus's own attributes — their types, their allowed values, their
documentation — and which drives value completion, a linter, and column
formats. See "The attribute registry" below.

## The manual

There is a Texinfo manual under `doc/`, and it is the fuller and more
carefully organised account: a tutorial, a chapter per feature, a
complete reference for every command, option, property and verb, four
indices, and the attribution owed to Tinderbox.

The source is `doc/org-agents.org`. The `.info` is built, not tracked, so
build it once:

    make manual

Then read it with

    C-u C-h i doc/org-agents.info RET

(`C-h i` with a prefix argument prompts for an Info file), or with
`info -f doc/org-agents.info` from a shell. `make manual` fails on any
`makeinfo` warning, and rebuilds whenever the source, `doc/doc-setup.org`
or `org-agents.el` changes. What follows in this README is the shorter
tour.

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
| `$OWNER*` | `(org-entry-get nil "OWNER" t)` | outline axis |
| `$OWNER^` | `(property-resolved "OWNER")` | prototype axis |

A reference may carry **at most one** trailing suffix, and the two are
different axes rather than degrees of the same one. `*` asks the
**outline**: `org-entry-get` with inheritance, so an ancestor's drawer, a
`#+PROPERTY:` keyword and `org-global-properties` all answer. `^` asks the
**prototype**: the entry's own drawer, then the `:PROTOTYPE:` chain, then
the registry's declared default — see [Prototypes](#prototypes). `$N*^` and
`$N^*` name no axis and are refused by name. Seven specials reference the
entry itself rather than a property: `$ITEM`, `$TODO`, `$PRIORITY`,
`$TAGS`, `$CATEGORY`, `$LEVEL`, `$FILE`; a suffix on one of those is
ignored, since there is nothing to inherit and nothing for a prototype to
carry.

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
| `AGENT_ACTION` | what to do to the entries the query matched. Read only by `org-agents-apply-actions`, from this entry's own drawer — never inherited, never evaluated, and never read on a save. See [Action code](#action-code). |

`PROTOTYPE`, `ID` and the properties the action verbs edit are the only ones
outside that table the package reads by name. The verbs read `SCHEDULED`,
`DEADLINE`, `PRIORITY`, the effort property (`Effort` by default) and, for
`archive!`, an inherited `ARCHIVE` — each of them at the entry it is about to
edit, and each described under [Action code](#action-code). `PROTOTYPE` names the entry a value is inherited *from*, and
is described under [Prototypes](#prototypes). `ID` is how a match is linked
to: every rendered match is read for one, and an entry that has one is
registered with `org-id-add-location` so the link resolves — so an update
does touch `org-id` state. `COLUMNS` is *written* by the column-view command,
which says so where it is described. Every other property in a drawer is
data the package reads only because a query asked for it.

Org reads the value `nil` as no value at all, so `:AGENT_VIEW: nil` is an
agent with no view rather than an error, and takes the default.

`AGENT_MATCHED`'s timestamp is inactive and therefore visible to a query:
`(ts-inactive :from ...)` over a corpus that holds agents will match the
agents themselves.

### A file the scope names but nothing can open

A scope may name a file that is not there, or one the permissions refuse.
Handed such a file, org-ql calls `display-warning` — which *returns* the
warning text as a string, leaves that string among the buffers it is about
to map over, and calls `buffer-name` on it. The diagnostic therefore
arrives as the payload of a type error:

```
Wrong type argument: bufferp, "Error (org-ql-select): Can't open file: /home/you/org/gone.org"
```

and one bad path made **every** agent in the buffer fail with what reads
like a bug in this package. Reproduced for a missing file and for a
`chmod 000` one, over `agenda`, over an explicit list, and over `all`. It
is a *fallback-path* fault: ripgrep cannot read an unreadable file either,
so a narrowed scope never reports one and the type error appeared only
where the walk was live — the slow path, which is the worst place to meet
a type error.

The package now checks the list before org-ql sees it, and answers two
ways, because the two kinds of scope make different promises:

| scope | a file nothing can open |
| --- | --- |
| an explicit `AGENT_SCOPE` file list | **refused**: `user-error`, naming the files. You named this file in this agent, so a smaller answer with nothing to say it was smaller is not on offer |
| `agenda`, a directory, `active`, `all` | **skipped**, with one message naming the scope and the files. These describe a set rather than enumerating it, so one stale path in a list Org maintains — or one root-owned stray in the corpus — must not break every agent in the buffer |

Never silent either way: the message is the whole difference between a
skip and a drop. `org-agents-preview` reaches org-ql with a file list too,
met the same type error, and is guarded the same way — its scope is
`agenda` by construction, so unreadable files there are skipped and named.

The test is "readable, **or** already visited", which mirrors org-ql's own
rule rather than inventing a stricter one. Measured: a file visited while
readable and then made unreadable has `file-readable-p` nil,
`find-buffer-visiting` non-nil, and org-ql over it works and returns its
match. A bare `file-readable-p` gate would newly refuse something that
works today.

If you set `org-agenda-skip-unavailable-files` to `t` — as the author
does — Org has already filtered the list and this package has nothing to
say about it, and says nothing. Everything here is about the Emacs default
of `nil`.

Cost, measured over a 3,639-file `active` scope: 0.465 s, against 0.265 s
for the recursive walk that produced the list and the ten-odd seconds
org-ql then spends opening those files. So it is *not* negligible against
the walk — it is roughly twice it — and it is negligible against the read
it precedes, which is the comparison that matters, because the check only
ever runs on the list org-ql is about to open. On a narrowed scope the
list is short and so is the check.

## The attribute registry

An agent's vocabulary is the package's own — `AGENT_QUERY`, `AGENT_VIEW`,
and the rest above. A corpus has a second vocabulary, which is entirely
yours: `STATUS`, `REVIEWS`, `OWNER`, whatever you have been writing into
drawers. The registry is one Org file in which each of those is *declared*
— its type, the values it admits, its default, and what it is for — so that
the package can complete it, lint it, and put it in a column.

It is optional. `org-agents-attributes-file` defaults to
`~/org/attributes.org`, and a file that is not there declares nothing and
says nothing about it: the package never creates it and never assumes it
exists. `docs/attributes-example.org` is a whole one, written out.

### The file

Each top-level entry declares one attribute. The heading is the name, the
drawer carries the declaration, and the body is the documentation.

```org
* STATUS
:PROPERTIES:
:ATTR_TYPE:    set
:ATTR_VALUES:  open wip blocked done
:ATTR_DEFAULT: open
:ATTR_FACES:   blocked org-warning | done org-done
:END:
Where the item stands.  A set rather than a string: an item may be
blocked and waiting on review at once.
```

| Field | Meaning |
| --- | --- |
| `ATTR_TYPE` | `string`, `number`, `date`, `boolean`, `set`, or `list`. Required — this property is what makes an entry a declaration. |
| `ATTR_VALUES` | the values the attribute admits, whitespace-separated. A `:ETC` among them leaves the vocabulary **open**, which is Org's own spelling of that; `:ETC` *alone* declares no vocabulary at all, and completion defers as though the field were absent. |
| `ATTR_DEFAULT` | the default, as text. |
| `ATTR_FACES` | `VALUE FACE \| VALUE FACE …` — value/face pairs separated by a vertical bar. What `org-agents-faces-mode` draws a headline with; see "Appearance from attribute values". |

`set` and `list` are Tinderbox's: a set is unordered and admits no repeat, a
list is ordered and admits duplicates. Tinderbox separates their members
with semicolons; here the separator is whitespace, because that is what
Org's own `NAME_ALL` convention uses and therefore what
`org-property-get-allowed-values` already reads.

What each type admits:

| Type | A value is valid when |
| --- | --- |
| `string` | always. With `ATTR_VALUES`, the whole trimmed value is one of them, compared case-**sensitively** — a declared vocabulary is one you wrote down. |
| `number` | it is a signed integer or decimal, **whole**, with no exponent. `3`, `3.5`, `.5`, `-3` are numbers; `1e3` and `3 4` are not. |
| `date` | it both parses *and* names a day that exists. `[2026-12-31 Thu]`, `<2026-12-31 Thu 10:00>` and the plain `2026-12-31` all pass; `[2026-02-30 Mon]` does not. |
| `boolean` | it is `true` or `false`, lower case. Not `t`, not `yes`, not `True`. |
| `set` | every whitespace-separated member is admitted by `ATTR_VALUES`, and no member repeats. The empty set is valid. |
| `list` | every member is admitted. Duplicates are fine and order is significant. |

**Two things about the file that are easy to get wrong once.** The drawer
must sit immediately under the heading, where Org keeps a property drawer:
one written after the body text is not a property drawer at all —
`org-get-property-block` returns `nil` for it — and the entry is reported as
declaring no type, which is exactly what it looks like from Org's side. And
the heading must be something Org could read as a property key, so `* Ship
it` declares nothing and is named.

It is **pure data**. Every field is read with `org-entry-get` and used as a
string, as one of six symbols out of a fixed table, or as a face name.
There is nothing a registry file can hold that the package will evaluate,
`read`, or run — which is the whole difference between this file and
`AGENT_QUERY`, and why this one has no gate.

Reading it fetches nothing either, which took one deliberate line. The
reader enables `org-mode` over a copy of the text to get Org's own parsing,
and `org-mode` *follows* a `#+SETUPFILE:` whatever `org-inhibit-startup`
says — measured, twice per read, and through
`url-retrieve-synchronously` for a URL. Since the read happens inside
`org-property-allowed-value-functions`, that would have been a blocking
fetch, or Org's download-policy prompt, arriving while you answered an
`org-set-property` prompt in an unrelated buffer. So the keyword is
neutralized in the copy before the mode is enabled: nothing a setup file
could say matters to a reader that wants headings and drawers.

A missing or unreadable registry declares nothing, silently. A malformed
entry is named **once** — the diagnosis comes out of the reader, and the
reader runs at most once per edit — and then a bad *type* costs its entry
while a bad anything-else costs only that field: an attribute whose default
does not parse still has a type worth completing and linting against.

The file is read lazily and cached, and the cache notices an **unsaved**
edit: while a buffer is visiting the registry the cache is keyed on that
buffer's `buffer-chars-modified-tick`, so a value you have just typed into
`ATTR_VALUES` is offered by the very next `org-set-property`. With no
buffer visiting it, the key is the file's modification time and size and
nothing is opened to find that out.

### The four things that read it

**1. Completion.** `org-agents-allowed-values` on Org's own
`org-property-allowed-value-functions` makes `org-set-property` offer a
declared attribute's values, in every Org buffer. You add it yourself — see
Configuration — because a library has no business writing into a user's
hook at load time.

A name the registry says nothing about is left *entirely* alone, and that
distinction is sharper than it looks. `org-property-get-allowed-values`
consults that hook in a clause **above** the one that reads `:NAME_ALL:`,
and takes the first non-nil answer, so any answer at all shadows every
`_ALL` declaration in the corpus for that name. Measured: a hook answering
for `STATUS` beat a `:STATUS_ALL: a b c` in the entry's own drawer. So the
package answers `nil` both for an undeclared name and for a declared one
carrying no `ATTR_VALUES` — and for one whose whole vocabulary is `:ETC`,
where answering would shadow the `_ALL` declarations while offering
nothing, since Org strips `:ETC` and would then have an empty list — and
your existing `_ALL` declarations go on working untouched.

Fifteen names can never reach it: the fourteen in `org-special-properties`,
plus `CATEGORY`, all of which Org answers for in clauses of its own. A
declaration of one of them is kept — the linter still reads it — and the
reader says once that no completion is possible for it.

**2. The linter.** `M-x org-agents-check-attributes` takes a scope — the
same vocabulary `AGENT_SCOPE` takes, read by the same code — and reports
what the registry does not account for. It reports and **never** edits.

```
/Users/you/org/notes/a.org:12: WIDGET is not declared in ~/org/attributes.org
/Users/you/org/notes/a.org:19: STATUS: `nope' is not one of open wip blocked done
/Users/you/org/notes/b.org:4: REVIEWS: `many' is not a number
```

Those lines land in a `compilation-mode` buffer, which parses every one of
them — measured — so `RET`, `next-error` and `M-g n` navigate the findings
with no navigation code written for them. A run with nothing to report says
so, with its counts, rather than popping an empty buffer.

An **undeclared name** gets one finding, not one per line — `WIDGET is not
declared in ~/org/attributes.org (763 property-line sites)`, at a confirmed
example site. The number says *sites*, not *uses*, on the ripgrep path, and
that is a real distinction rather than pedantry: a text enumerator counts
lines that have the shape of a property line, and knowing which of them Org
would actually read is the per-entry walk this command stopped doing.
Measured on a file with one real `:NOTE:` drawer line and three `:NOTE:`
lines in body text, the two paths counted 4 and 1. Neither number is wrong;
one word for both was, so the walk — an `agenda` scope or an explicit file
list — says `(1 use)` and means uses.
A **bad value** keeps one finding per line, because those are per-line facts
about specific values and there is no summarising them. Over a corpus with
no registry yet, the per-line form is about 149,000 findings, and a
149,000-line buffer is not a report.

#### Two tiers, and why the lint finishes

The command asks two questions, and it used to pay per-entry Org-parsing
cost for both. Over a real corpus it did not finish: measured, killed at
**600 seconds with no report at all** — and the command is most valuable at
exactly the scope where it could not be run, because the first whole-corpus
run is how a registry gets seeded.

The fix is that the two questions have different costs.

*Which names are in use that nothing declares?* needs **no Org semantics**
at all — it is a question about text. One ripgrep run answers it for a whole
corpus: measured, 0.17 s for 336,628 sites and 21.5 MB of output, plus about
a second to parse and a second and a half to confirm.

*Do declared values match their declared type?* genuinely needs per-entry
reading, but only for the **declared** names, and only in the files that
hold them. One ripgrep run per declared name narrows those.

Measured over the author's 3,616-file `active` scope: **7 to 10 seconds
warm, 64 to 110 seconds cold**, against >600 s and no report. (Independently
re-measured while adjudicating this work: 88 findings over 3,616 files, 14.2 s
for the first run in a fresh process and 8.4 to 9.7 s for the four after it,
with 0 files invisible to the census.) (Cold versus
warm is an order of magnitude here for the same reason it is everywhere else
in this file — the OS page cache. Two careful people measuring this will
disagree by 10× before either thinks to say which state they were in.) With a registry declaring `CREATED`, which is in essentially
every file, the value tier reads the whole corpus and the run is about four
minutes; that cost is inherent, it is what checking every value *means*, and
it is why the command shows a progress reporter above 50 files rather than
sitting silent.

Two accidental quadratics went with it, and they, not Org, were where the
600 seconds came from. Findings were accumulated with `nconc` onto the whole
list once per file, which costs the sum of the findings so far over every
file; measured on a 1,840-file sample, 129.48 s with it and 35.45 s without,
and the term quadruples over the full corpus. And line numbers came from
`line-number-at-pos`, which counts from the top of the buffer every time —
another 1.8×. For comparison, the same corpus's walk with no findings built
at all is 38.59 s.

**The soundness obligation is that the fast path reports the same
vocabulary as the slow one**, and that is a test rather than a claim:
`org-agents-test-attr-census-fast-equals-slow` lints one fixture corpus
through both enumerators and compares the sets of names. The fixture holds
every case that separates them — a file-level drawer, a lower-case key, a
`+` key, a key with no value, a name containing a colon (`:A:B:` is the
property `A:B` to Org), a latin-1 name, a CRLF file, and four
property-line *shapes* that are not properties.

That last group is why an exclusion list is not enough. Ripgrep reads text
and cannot see drawer structure, so it also matches `:PROPERTIES:` and
`:END:` — removed by name — and, measured against the whole corpus, four
names the live walk never sees and no list could have anticipated:
`LOGBOOK` (1,407 sites), `RESULTS`, `SRSITEMS` and a stray `0`. Those are
other packages' drawer openers and a stray body line, and the next corpus
will have different ones. So every candidate is **confirmed** by reading a
real property drawer before it is reported, at most 20 files per name.
Measured: the pass drops precisely those four and nothing else. The
confirmation also supplies the name as *Emacs* decoded it, which is how a
latin-1 `:CAFÉ:` reaches the report spelled right rather than as mojibake.

Confirmation is one of **two** things that make the fast path's name set the
walk's set rather than a subset of it, and the other is easy to miss.
Ripgrep's line model splits on LF, and the census cannot pass `--crlf` (with
it, every extracted name comes back with a trailing CR; with a `\r` in the
pattern, ripgrep refuses to run at all). So a file written with **bare CR**
line endings — classic Mac, and what some old imports still hold — is *one
line* to ripgrep, while Emacs reads it as `undecided-mac` and Org reads its
drawers perfectly. Measured: the drawer prefilter admitted such a file, the
census reported nothing about it, and every name unique to it was missing
from the report with no count and no diagnostic. A file the census reports
**nothing** about — not even the `:PROPERTIES:` line it matches in every
file with a drawer — is therefore read live, names and values both. Normally
that list is empty and the check costs a hash table.

The bound has a cost and the report states it rather than hiding it, in two
sentences rather than one, because there are two different things to say.
Names that were looked at in every file holding them and turned out not to
be properties: "4 names appeared in property-line shape outside any drawer
and were not reported" — nothing is being withheld, they are not properties.
And names the 20-file bound ran out of opens on, which *may* be real: those
are **named**, with a suggestion to re-run over a narrower scope. Measured,
and the reason the two are now separate: with 25 decoy files and one genuine
drawer in the alphabetically last, the lint dropped a real property and told
the reader it had dropped something that was never a property. Without
ripgrep the whole thing falls back to the live walk with one message,
exactly as the prefilter does, and never refuses.

One more thing the equivalence test caught, which no amount of reading
would have: **ripgrep's output order is nondeterministic** — it walks the
tree in parallel. Since a candidate is reported at the first site that
confirms, and with the property name *as that file spells it*, the same
corpus reported `widget` on one run and `WIDGET` on the next. Org matches
property keys case-insensitively so neither spelling is wrong, but a report
that changes between runs of the same command is a flaw of its own. Both
enumerators now sort a candidate's files by name, so the reported spelling
and the reported example site are the alphabetically first file's, from
either path. It showed up only under CPU load, one run in six; twenty runs
under the same load afterwards were clean.

Org's own vocabulary is never asked about, nor the package's, nor the
registry's: `org-special-properties`, `org-default-properties`, `ID`, the
six `ARCHIVE_*` names `org-archive-subtree` writes, anything beginning
`AGENT_` or `ATTR_`, and anything ending `_ALL`. Without those exemptions
`ID` alone is about 37,000 findings on the author's corpus — measured at
36,991 uses — and `ATTR_` matters because the registry commonly lives
*inside* the scope being checked and would otherwise report every one of its
own declarations.

Four things Org does that the linter is careful about. A property key
matches case-insensitively, so `:status: open` is a value of a declared
`STATUS` and not an undeclared property. A `+` line **accumulates**:
`org-entry-get` answers `3 4` for a `:REVIEWS: 3` beside a `:REVIEWS+: 4`,
and `3 4` is not a number — so the finding is real, and it is reported on
the `+` line that caused it rather than on the line that was fine until
that one arrived. A `set` is judged on the accumulated value as well as on
the line, because a repeat — the one rule that separates a `set` from a
`list` — can only be spelled across lines: `:STATUS: open` beside
`:STATUS+: open` is `open open`, and that is not a set. And the `+`
spelling of an exempt name is exempt too: `:STATUS_ALL+: done` extends a
vocabulary the ordinary Org way, and reporting it would be reporting the
vocabulary as a violation of itself.

The drawer **before the first heading** is walked as well. Org reads those
properties — `org-entry-get` at the top of the file answers from them, and
with `org-use-property-inheritance` on so does every entry below — so a
lint that skipped them would call a file clean with a misspelled name and
an unparseable value sitting at the top of it. It is counted as no entry,
because it is none.

A corpus scope is narrowed with ripgrep through the same machinery an agent
uses, pushing `^[ \t]*:PROPERTIES:` — a provable superset of the files that
could hold a finding, since Org reads a property only from inside a drawer.
That narrows little on a property-heavy corpus, which is the honest answer:
a pattern built from the registry's own *names* would be far narrower and
unsound, because an undeclared name lives by definition in a file that may
hold no declared name at all. Unlike an agent, the linter is never refused
— `org-agents-prefilter` set to `require` declines a *query*, and a lint
that declined to run would be failing its own contract rather than saving
anyone an expense.

It also *opens* nearly all of that corpus, and leaves it open: every file
in scope comes out of the run visited by a buffer, and nothing here reaps
them. See "Honest limitations" for what to do about it.

**3. Column formats.** `M-x org-agents-attribute-columns` reads attribute
names and returns a `COLUMNS` format built from their declarations; with a
prefix argument it writes it into the entry at point's `:COLUMNS:` property,
which every descendant inherits.

```elisp
(org-agents-attribute-columns '("STATUS" "REVIEWS" "DUE"))
⇒ "%ITEM %STATUS %REVIEWS{+} %DUE"
```

Only `number` earns a summary operator, and it earns `+`. Nothing else is
defensible from a type alone: `X` reads its column as a checkbox and a
`boolean` here is the text `true`/`false`; `:` and `@` read a column as a
duration and as an age, which a `date` may or may not be; and a summary over
a set or a string means nothing. Write one in by hand if you want one — this
generates a starting point, not a policy. An undeclared name is refused
rather than emitted, because a `COLUMNS` line naming a property nothing
declares renders an empty column, which looks exactly like a property
nothing has set. So is a declared name a `COLUMNS` format cannot spell:
`org-columns-compile-format` matches a column's property with
`[[:alnum:]_-]` and truncates silently at anything else — measured,
`%WITH.DOT{+}` compiles to a column named `WITH` with no summary operator
— while Org accepts `WITH.DOT` as a property name perfectly well, so the
registry can declare one and only the column view cannot say it.

Measured, and worth knowing: `org-columns-compile-format` validates no
operator at all — `%X{nope}` compiles without complaint — so the guarantee
that these operators are real is this command's, and nowhere else.

**4. Appearance.** `org-agents-faces-mode` faces a headline from a declared
attribute's *resolved* value, through the `ATTR_FACES` mapping. It is the
one reader of that field, and the only one of the four that draws rather
than reports. See "Appearance from attribute values" — it sits after
Prototypes, because *resolved* is the word it turns on.

## Prototypes

Beside the declarations, the registry file carries one reserved top-level
section named `Prototypes`. Every entry below it, at any depth, is a
**master**: an ordinary Org entry whose drawer holds ordinary properties,
which any entry in the corpus may read through by naming it.

```org
* Prototypes
** Task
:PROPERTIES:
:STATUS:  open
:OWNER:   johnw
:REVIEWS: 0
:END:
The master every task follows.
```

```org
* TODO Ship the widget
:PROPERTIES:
:PROTOTYPE: Task
:END:
```

That entry's `OWNER` is `johnw`, and nothing was written into its drawer to
make it so. `:PROTOTYPE:` takes a **name** out of that section, or an
`id:UUID` (or a bare UUID), which resolves to an entry that carries the
`:ID:` — so a master need not live in the registry at all. This
is Eastgate Tinderbox's prototype, and like Tinderbox's it is independent
of the outline: a prototype is a relation between two entries, not a fact
about where either sits.

An `id:` reference resolves **through `org-id`'s location table**, and that
is the one precondition prototypes have. The resolver takes the two steps
`org-id-find` takes before its rescan — it deliberately does not call
`org-id-find` itself, because that would rescan the corpus and write
`org-id-locations-file` from inside a predicate body, once per candidate
entry — so an id resolves when `org-id-locations` already knows the master's
file, which is the ordinary state of a corpus where `org-id-track-globally`
is on and the file has been visited or scanned. Where the table has no
answer, `org-id-find-id-file` falls back to the *follower's own* file: a
master in a sibling file is then not found, and the reference dangles with
the ordinary one-message diagnostic. Measured, with an empty table and the
master one file away: `nil`, and one `no prototype` message. A master named
by **name** out of the registry needs none of this.

### The resolution order

Per attribute, and this is the whole of it:

| Step | Reads | Notes |
| --- | --- | --- |
| 1 | the entry's own drawer | `org-entry-get` with inheritance **off**. A `:NAME:` line with nothing after it answers `""`, which is a value. |
| 2 | the `:PROTOTYPE:` chain, nearest hop first | A master may itself carry `:PROTOTYPE:`. The walk stops at the first hop that carries the attribute. |
| 3 | the registry's `:ATTR_DEFAULT:` | Which is why prototypes live in the registry file: step 3 is the registry. |
| 4 | `nil` | |

**Outline inheritance is deliberately not in that list.** Containment is
not inheritance — a task filed under a project is not a kind of project —
and the outline axis already has a spelling of its own. `$NAME*` is that
axis and `$NAME^` is this one; they are orthogonal, and a query says which
it means. Both may be true of one entry, and neither implies the other.

Two names never travel, for two separate reasons:

* **`AGENT_*`** because behaviour does not. A master that lent its
  `:AGENT_QUERY:` would make every follower an agent, and a declared
  `:ATTR_DEFAULT:` for such a name would make every entry in the corpus
  one.
* **`PROTOTYPE`** because a declared default for *it* would hand every
  entry in the corpus a master — one line in the registry and the whole
  corpus follows one prototype.

Both are answered from the entry's own drawer and from nothing else: no
chain, no default. So is a special property — `CATEGORY`, `TODO`,
`DEADLINE` and the rest of `org-special-properties` — because a master's
category is not this entry's, and a deadline is entry structure rather than
a drawer line at all.

### Virtual reads, and what they cost

**Nothing is ever written into the inheriting entry.** A read resolves at
the moment it is asked. Change a master and every follower changes with it;
an entry's drawer goes on saying only what the user put in it; and no
update has to find and rewrite the followers of a master that moved.

The price is one sentence long, and it is worth reading twice: **grep does
not see an inherited value, and an agent through `property-resolved` does.**
`rg ':OWNER: johnw'` finds the master and none of its followers. So does
`org-entry-get`, so does a `COLUMNS` view, and so does org-ql's own
`(property "OWNER" "johnw")` — at every setting of
`org-use-property-inheritance`, because that option is about the outline
and has nothing to do with this. What sees an inherited value is
`(property-resolved "OWNER" "johnw")`, which is what `$OWNER^` expands to,
and `org-agents-resolve-property` for a caller in Lisp.

### The two diagnostics

A `:PROTOTYPE:` naming nothing — a misspelled master, or an `id:` the ID
table does not know — is **one message** naming the reference and the first
entry that carried it, and resolution answers as though the line were not
there. Where the reference is an `id:` that `org-id-locations` has no file
for, the message says so (`; org-id knows no file for that id`), because
that is a different fix from a typo: the drawer may be perfectly correct and
the table simply empty. Not an error: the resolver runs at every candidate entry of an
update, and a signal from inside org-ql's generated matcher aborts that
agent's whole update, so one drawer's typo would cost the agent.

A **cycle** in the chain is a `user-error` naming the hops in order
(`A -> B -> A`) when `org-agents-resolve-property` is called directly, and
one message per update when it is reached through a query. Both are said
once per update however many entries hit them.

### `property-resolved`, and why it exists

```elisp
(and (todo) (property-resolved "STATUS" "open"))
```

`$STATUS^` is *not* short for that. It expands to the bare
`(property-resolved "STATUS")` — existence, not this value — so the two
match different entry sets whenever anything resolves `STATUS` to something
other than `open` — and where the registry declares an `:ATTR_DEFAULT:` for
the name, the bare form is true of *every* entry and narrows nothing. The
sugar is one of the rows in [The query language](#the-query-language).

The predicate is **preamble-free by construction**, and the reason is not
the obvious one. org-ql's plain `property` forms attach no `:inherit` and
read the entry's own drawer, so they cannot see an inherited value at any
setting of `org-use-property-inheritance` — and `org-ql-use-preamble` nil
does not change that, because the bare `(property "X")` form has no
preamble to turn off and still does not see one. What a preamble *would* do
here is re-impose the drawer text as a filter over the resolver's answer,
which is exactly what defeats the other obvious approach, advice on
`org-entry-get`: measured, with such advice installed the value form finds a
follower with the preamble off and loses it with the preamble on. So this
predicate contributes no preamble, ever. A preamble hoisted out of a
*sibling* conjunct is a different thing and is sound — a conjunct's
necessary condition is the conjunction's.

One asymmetry is deliberate. `$NAME^` in boolean position becomes a known
org-ql predicate and the [gate](#the-query-language) admits it unremarked.
In value or numeric position it becomes residual Lisp — a call to
`org-agents-resolve-property-quietly` — and the gate asks once, exactly as
it does for `$NAME*`. Exempting the accessor would be widening the gate for
a call the package cannot distinguish from any other call in a query.

### What this adds to the configuration

No option of its own. Prototypes live in the file
`org-agents-attributes-file` already names, and this epic adds no option, no
command and no hook.

One existing setting does matter, though, and only for masters named by
`id:`: those resolve through `org-id`'s location table, so `org-id` has to
know where the master's file is — `org-id-track-globally` on and a populated
`org-id-locations-file`, or the master in the same file as the follower. A
master named by **name** out of the registry's `Prototypes` section needs
nothing beyond the file above.

## Appearance from attribute values

`org-agents-faces-mode` is a buffer-local minor mode that draws a headline
in the face its attribute value maps to. It is Tinderbox's `$Color`, and it
**changes no bytes**.

### The syntax

```org
* STATUS
:PROPERTIES:
:ATTR_TYPE:    string
:ATTR_VALUES:  active stalled done
:ATTR_DEFAULT: active
:ATTR_FACES:   active org-todo | stalled org-warning
:END:
```

`VALUE FACE | VALUE FACE …`, groups separated by a vertical bar and the two
words of a group by whitespace. All or nothing: a group that is not exactly
two words costs the **whole** field, and the reader names the attribute once
when that happens:

```
org-agents: attribute `STATUS' in ~/org/attributes.org: unreadable :ATTR_FACES: `active'
```

Said once per edit to the registry rather than once per redisplay, because
the mode reads the mapping the reader stored and never re-parses the field.

`ATTR_FACES` is the whole of the opt-in. Every declared attribute that names
faces is consulted; there is no second list to enrol one in, because the
commonest failure of one would be a registry that names faces and silently
draws nothing.

A face the registry names and Emacs does not is a **diagnostic, not an
error**. It is said once per attribute and face, that one mapping is
skipped, and the rest of the buffer is faced normally — a typo in the
registry must not cost the fontification of the file you are reading. That
includes a face spelled `nil` or `t`: neither is a face, so both are named
rather than silently drawing nothing.
`facep` is therefore checked at use and never when the registry is read: a
face a theme defines later would otherwise be rejected for good.

### The worked example

Given the `STATUS` declaration above, a master in the registry's
`Prototypes` section carrying `:STATUS: stalled`, and this corpus:

```org
* Rewrite the exporter
:PROPERTIES:
:STATUS: stalled
:END:

* Audit the fixtures
:PROPERTIES:
:PROTOTYPE: Task
:END:

* Read the mail
```

All three headlines are faced, and that is the point.

The first spells `stalled` and is drawn in `org-warning`. The second spells
only `:PROTOTYPE: Task`, and the master says `stalled` — so it is drawn in
`org-warning` too. The third spells nothing whatever, takes `ATTR_DEFAULT`'s
`active`, and is drawn in `org-todo`.

**Grep does not see an inherited value**, and neither does the drawer under
your eye — but the face does. That is the whole reason the mode is worth
more than a tag convention, and it is why `global-org-agents-faces-mode`
arms **every** Org buffer rather than only those whose text mentions a
property, the way `global-org-agents-mode` does: a text scan would miss
precisely the second and third entries above.

Values are matched **whole** and case-**sensitively** — `STALLED` is not
`stalled` — which is one decision with `property-resolved`'s own comparison
and with `ATTR_VALUES`, because a declared vocabulary is one you wrote down.

### It changes no bytes

One font-lock keyword and nothing else. No text is inserted, no property is
written, no overlay is created, and turning the mode off restores the buffer
exactly: the keyword is un-declared and font-lock's own unfontify pass takes
the face off. Nothing here removes a text property, because there is none of
ours to remove.

That is tested rather than claimed.
`org-agents-test-faces-change-no-bytes` replaces `insert`, `delete-region`,
`org-entry-put` and `replace-buffer-contents` with a tripwire across an
enable, a fontification and a disable, and asserts the count is zero beside
the modification flag, `buffer-chars-modified-tick`, the buffer text, the
file's bytes on disk, and the absence of any overlay.
`org-agents-test-faces-disabling-leaves-no-residue` asserts the other half —
`font-lock-keywords` `equal` to what it was, not one buffer-local variable
of ours left behind, and the face gone after a refontification.

So it is safe to leave on in files under version control.

### What it costs

jit-lock-driven, per displayed headline. The matcher reads only the entry at
its match and honours the region's limit, so cost scales with what is *on
screen* and not with the buffer or the corpus. Measured over a 400-entry
buffer of which one entry is drawn: a twelve-line window costs **3**
resolutions where the whole buffer costs **400**, and a headline outside the
region carries no `face` property at all.

Those two figures are for the single-`STATUS` registry above. Each unmapped
headline is resolved once *per face-declaring attribute*, so they scale with
how many attributes name faces: the same measurement under the test suite's
registry, which declares `STATUS` and `OWNER`, is **5** and **799**.

The registry is read **once per fontified region** rather than once per
headline, and that matters more than it sounds. Reaching the registry costs
`file-truename` plus `find-buffer-visiting`, and the second walks the whole
buffer list truenaming each buffer's file — so the cost grows with how many
buffers you have open. Measured on that same buffer, a whole-buffer
fontification costs 405 such reads and 0.097 s with the batch established
per matcher call, against **1** read and 0.033 s with it established once
for the region — against an Org-alone baseline of 0.010 s, a marginal cost
of 23 ms rather than 87 ms. A dangling `:PROTOTYPE:` is said once for the buffer for the
same reason: measured, twenty entries naming one missing master produce
twenty messages without that and one with it — and without it they would be
twenty messages *per redisplay*.

Where nothing declares a face the mode answers before resolving anything at
all, so a corpus with no registry pays a regexp scan of the displayed region
and nothing else. That is what makes arming every Org buffer affordable.

### It follows an edit, with one gap

Change `:STATUS:` in an entry's drawer and the face on the headline above it
moves with it. That takes a hook of its own, because a change refontifies
its own line and the face and the value are on different lines: without it,
measured, the headline kept the old value's colour until something unrelated
forced a refontification — a display asserting a value the drawer no longer
held.

The gap is edits **elsewhere**. A change to the registry's `ATTR_FACES` or
`ATTR_DEFAULT`, to a prototype master, or to a `:PROTOTYPE:` line in another
buffer moves a resolved value in every follower at once, and nothing here
refontifies a buffer other than the one being edited. An armed buffer left
open across such an edit keeps its old colour until it is refontified — by
`M-x font-lock-flush`, or simply by being scrolled away and back. Watching
the registry from a change hook in an unrelated buffer is a great deal more
machinery than the case is worth, and nothing is wrong in the file.

### Precedence

Two collisions, one rule each.

**Between two declared attributes, the first declaration in the registry
file wins.** `org-agents-attributes` answers in file order — the registry is
a document, and the order its author chose is information — and the walk
stops at the first declaration that resolves to a mapped value. There is no
option for this: the ordering already has a spelling you control, which is
where the declarations sit in the file, and a second spelling would let the
two disagree. A value declared twice inside one `ATTR_FACES` follows the
same rule.

**Against Org's `org-level-N`, the faces form a list with ours first.** The
keyword is appended to `font-lock-keywords` and applies with `prepend`, so
the title reads `(org-warning org-level-1)`: the colour follows the
attribute, and everything the attribute's face does not specify — the
height, the family — still comes from Org. The stars keep `org-level-1` by
itself, which is what keeps `org-hide-leading-stars` working. Measured, the
alternatives are all worse. At the *front* of the keyword list ours claims
the headline outright and `org-level-N` is destroyed, because Org's own
headline keyword applies with override nil. `append` gives `(org-level-1
org-warning)`, where Org's colour wins and ours is dead weight. `keep` never
applies at all. And override `t` gives `org-warning` alone, **destroying**
`org-level-N` — the height, the family, the lot.

The keyword faces the heading *text* and never the trailing newline, so
`org-fontify-whole-heading-line` still governs the fill of the line and this
mode governs the text on it.

### Two refusals

**No geometry.** Tinderbox's `$Width`, `$Xpos` and `$Height` are
deliberately not ported. They describe a **map view**, and Org has no map:
there is nothing in an outline for them to mean, so no spelling of them is
reserved and none is planned.

**No writes of any kind from an appearance declaration.** Setting a tag, a
TODO state or a property from a resolved value is action code arriving
through another door. What makes it different in kind from facing a headline
is that it would be *inheritable behaviour*: a master's declaration running
in every follower's file, in files you never opened, is what part 3 of
`docs/research/action-code-safety.md` says makes per-file trust
meaningless. Any such thing goes through the action-code trust model or not
at all.

One thing is neither refused nor done: facing by a **member** of a `set` or
`list` rather than by the whole value. `ATTR_FACES` maps whole values today,
so a `set` is faced only where its entire value equals a declared key.

## Corpus-wide column view

Here is what the first three of those readers add up to, and the reason
there is no renderer in this package. **`org-agenda-columns` already works inside an `org-ql-search`
results buffer.** That buffer is an `org-agenda-mode` buffer carrying
`org-hd-marker` on every result line; `org-agenda-columns` reads its
format from the matched entry's inherited `:COLUMNS:`, through the
`(org-entry-get m "COLUMNS" t)` arm of its own `cond`; and an edit is
written back to the source file by `org-columns-edit-value`. Corpus-wide
displayed attributes with write-back editing exist today. What was missing
was a format string, and the command above is it.

Two details worth having before you debug this. It is `org-agenda-columns`
that decides, and **not** `org-columns-get-format`, which reads
`(org-entry-get nil "COLUMNS" t)` — the agenda buffer's own absent
property — and answered the default format when measured on a live result
line. And that `cond` arm is the *fourth*: `org-overriding-columns-format`,
`org-local-columns-format` and the `org-columns-default-format-for-agenda`
option all outrank it. The last of those is an ordinary Org defcustom, nil
by default and set precisely by people who use agenda column views, and a
non-nil value silently defeats step 3 below — measured, the generated
`:COLUMNS:` is then ignored entirely.

Four steps, end to end.

1. `M-x org-agents-check-attributes` over `all`, and declare what it names.
   The first run of the linter is how the registry gets seeded: measured,
   this corpus has 137 distinct property names in it and **4** `_ALL`
   declarations anywhere.
2. `(add-hook 'org-property-allowed-value-functions #'org-agents-allowed-values)`,
   so `org-set-property` starts offering what you have just declared.
3. `C-u M-x org-agents-attribute-columns` on the top entry of the class of
   thing you care about, which writes a `:COLUMNS:` every descendant
   inherits.
4. `M-x org-ql-search`, then `M-x org-agenda-columns` in the results buffer.

A measured transcript of steps 3 and 4, over two matches in one file whose
parent carries `:COLUMNS: %ITEM %STATUS %REVIEWS{+}`:

```
generated COLUMNS: "%ITEM %STATUS %REVIEWS{+}"
inherited COLUMNS at a match: "%ITEM %STATUS %REVIEWS{+}"
results buffer: "*Org QL View: (todo TODO)*"  mode=org-agenda-mode
lines carrying org-hd-marker: 2
column overlays: 10

Fix widget | |open   | |3       |
Ship docs  | |wip    | |5       |
```

**One caveat, and it is the reason step 4 is a recipe and not a feature.**
Whole-result **roll-up** does not happen. There is no `{+}` total in that
transcript, and the reason was predicted before it was measured:
`org-agenda-colview-summarize` writes summaries only onto lines carrying the
`org-date-line` text property or the `org-agenda-structure` face, and an
`org-ql-search` buffer has neither on its result lines. Per-entry values
appear and are editable; a column total does not. Do not build on one.

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

### Several blocks under one agent

An update writes **every** block of the agent: `org-agents-update` with
point outside a block, and therefore `org-agents-update-buffer`,
`org-agents-update-all` and the save path, refresh them all. With point
*inside* a particular block, that block alone is written — which is how you
refresh one expensive view without the others.

It used to write only the first, and leave the rest as they were **with
nothing said about it**. A stale render kept silently is the same class of
defect this package refuses elsewhere, so it is fixed rather than
documented.

The blocks are written in buffer order and **the first failure stops the
run**, so the blocks after a failing one keep their previous contents. The
agent's failure line is what says something is wrong — this is not the
silent staleness above — but it does not say which blocks were reached.
Measured on a three-block agent whose middle block named a view that does
not exist: the first body rendered, the other two stayed empty, and the
summary said `updated 0 agents, 1 failed`.

`AGENT_MATCHED` records the **first** block's count, in buffer order. That
is a definition, not an approximation, and there is no better one to be had:
a block's parameters override the entry's — `:query` and `:scope` included —
so two blocks of one agent may run different queries over different file
sets, and what a block reports is *rows or items written*, which a
row-sorted table cuts to `AGENT_LIMIT` after building them. Measured on a
three-block agent: its blocks wrote 2, 2 and 1 items. The first block is
also what the property has always held, since a no-block update has always
written that one, so no existing file's stamp changes meaning.

One consequence will look like a regression the first time it happens. A
buffer whose second block was stale used to reach disk byte-identical on
save — the staleness was what made it identical — so the first save after
this change *writes the file*. That is the fix working; every save after it
is byte-identical again.

## Commands and options

| Command | What it does |
| --- | --- |
| `org-agents-update` | update the agent at point, or the block point is inside |
| `org-agents-update-buffer` | update every agent in the current buffer |
| `org-agents-update-all` | update every agent in the files `org-agents-files` names |
| `org-agents-preview` | `org-ql-search` over a query read from the minibuffer, expanded, with `org-agents-exclude` appended, and the appended form gated exactly as an agent's is, over `org-agenda-files` |
| `org-agents-apply-actions` | apply the `:AGENT_ACTION:` of the agent at point to the entries its query matched. Prints a dry run first — one `FILE:LINE:` line per intended edit, `old -> new` — and writes nothing until that report is agreed to; with a prefix argument the targets are the entries the links in the region name. The only thing in the package that runs an action: never a save, never a timer. See "Action code" |
| `org-agents-insert-dblock` | insert an empty `org-agents` block at point |
| `org-agents-attribute-columns` | build a `COLUMNS` format from chosen registry attributes; with a prefix argument write it into the entry at point's `:COLUMNS:`. See "Corpus-wide column view" |
| `org-agents-check-attributes` | report every property in a scope the attribute registry does not account for — undeclared names, values outside a declared vocabulary, values that do not parse as their declared type. Reports and never edits; the findings land in a `compilation-mode` buffer, so `RET` and `next-error` navigate them |
| `org-agents-list-approvals` | list every remembered approval and refusal, each with the query its hash covers; `d` forgets an approval, `r` turns it into a refusal, `u` lifts a refusal |
| `org-agents-mode` | update this buffer's agents before each save |
| `global-org-agents-mode` | turn `org-agents-mode` on in every Org buffer whose text mentions `:AGENT_QUERY:` |
| `org-agents-faces-mode` | face this buffer's headlines from declared attribute values; changes no bytes. See "Appearance from attribute values" |
| `global-org-agents-faces-mode` | turn `org-agents-faces-mode` on in **every** Org buffer. Not only those whose text mentions a property: a value arriving through a prototype or a default is spelled nowhere, so a text scan would miss exactly the entries the mode exists for |

| Option | Default | Meaning |
| --- | --- | --- |
| `org-agents-files` | `'("~/org/agents.org")` | where `org-agents-update-all` looks: files, directories, or the symbol `agenda` |
| `org-agents-exclude` | `(not (property "AGENT_MATCH"))` | conjunct appended to every agent query and every preview, so agents do not consume each other's aliases. Part of the form the gate approves: Lisp here is gated like Lisp in a query, and changing it invalidates every remembered approval |
| `org-agents-refused-heads` | `(semantic)` | predicate heads refused outright, before the safe list and before any approval, because org-ql runs their normalizers past the gate |
| `org-agents-refused-queries` | `nil` | forms refused outright by hash, beating every approval; managed through `org-agents-list-approvals` |
| `org-agents-safe-queries` | `nil` | forms approved to run without prompting, each recorded as `(HASH . QUERY-TEXT)` |
| `org-agents-prefilter` | `auto` | whether to narrow an unbounded scope with ripgrep: `auto`, `require` (refuse a scope that cannot be narrowed rather than scan it live), or `nil` (never spawn anything) |
| `org-agents-rg-executable` | `"rg"` | the ripgrep binary, resolved against `exec-path`. Set it where ripgrep is installed under another name, or in a directory Emacs's `exec-path` does not hold — routine on macOS, where a GUI Emacs does not inherit a login shell's PATH |
| `org-agents-rg-timeout` | `30` | seconds to wait for one ripgrep run, or `nil` for no bound. On expiry the run answers "no answer" and the scope is scanned live, so the price is a slow correct answer and never a wrong one. See "The prefilter cannot block Emacs without bound" |
| `org-agents-attributes-file` | `"~/org/attributes.org"` | the Org file declaring the corpus's user attributes. Optional: one that is missing or unreadable declares nothing and says nothing about it, and the package never creates it. See "The attribute registry" below |
| `org-agents-action-limit` | `100` | how many entries one `org-agents-apply-actions` will edit. Nil for no limit. A plan over more than this is refused rather than truncated, and the gate is on entries rather than on edits. See "Action code" |

Every option in that table is `:risky t`, and so are both of the globalized
modes' own options, `global-org-agents-mode` and
`global-org-agents-faces-mode`.
Emacs will not apply a file-local setting of a risky variable without asking,
and will not offer to trust one permanently or directory-wide. The reason is
that each of them names either Lisp to evaluate (`org-agents-exclude`), a
program to run (`org-agents-rg-executable`), whether a subprocess is spawned
at all (`org-agents-prefilter`), which files get opened and *written*
(`org-agents-files` — an update rewrites aliases), or the record of what has
already been approved or refused (`org-agents-safe-queries`,
`org-agents-refused-queries`, `org-agents-refused-heads`), how long Emacs
may be blocked waiting for that program (`org-agents-rg-timeout` — a
file-local `nil` takes the bound off entirely, and a file-local `0` expires
every run and sends every corpus-scope agent down the live whole-corpus
walk), or the bound on
how many entries one command may edit (`org-agents-action-limit` — a file
that could raise it could have `org-agents-apply-actions` edit the whole
corpus). A file that could set any of them from its own local-variables
block could pre-approve its own query, delete a refusal, name the binary to
execute, or lift the one limit on an action's reach.

The two globalized modes are risky for a reason of their own, since neither
names Lisp or a program. Turning `global-org-agents-mode` on is what makes
every save of an Org file run that file's agents' queries; turning
`global-org-agents-faces-mode` on is what makes every Org buffer read the
registry and walk prototype chains as it redisplays. A file that could
enable either from its own local-variables block would be deciding that for
the whole session, not for itself.

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

## Action code

An agent can carry an *action* as well as a query: a declarative sentence in
`:AGENT_ACTION:` saying what to do to the entries the query matched.

```org
* Stamp what I have reviewed
:PROPERTIES:
:AGENT_QUERY:  (and (todo) (property-ts "NEXT_REVIEW" :to today))
:AGENT_ACTION: set-property!(REVIEWED, today) tag!(+reviewed)
:END:
```

This is the only part of the package that writes outside the agent's own
file, so the refusals come before the syntax.

### The three refusals, which come before the syntax

**Actions never run on save, on a timer, or from either minor mode.** The
only thing that runs one is `M-x org-agents-apply-actions`, typed. There is
no hook, no idle timer, no option, and no `org-agents-update` integration
that changes that. Saving a file whose agent carries `:AGENT_ACTION:`
performs no write beyond the ordinary render — the same render it would have
performed with no action there at all.

That is structural rather than a promise. The action text is not part of the
plist `org-agents--read-agent` returns, so it does not exist as data anywhere
on the save path: there is no `:action` for a renderer to reach for, and a
reader does not have to prove that nobody used it. The one read of the
property is inside the command. A test *enumerates* every entry point in the
file — all fifteen autoloads and the six internal write drivers the save path
is built out of — replaces all nine verbs with a tripwire, and asserts the
tripwire is never touched, except by `org-agents-apply-actions`, which is
asserted to touch it so that the tripwire is proved live rather than assumed.
The list of autoloads is derived from the source text, so a sixteenth fails
the suite until somebody adds it to the table and exercises it too.

**Actions are not inheritable.** The action is read from the agent entry's
own drawer, with `org-entry-get` and no inheritance of any kind: not through
a `:PROTOTYPE:` chain, not from an outline ancestor, not from a
`#+PROPERTY:` line, not from `org-global-properties`, and not from an
`:ATTR_DEFAULT:` in the attribute registry. The reason is per-file trust: if
any of those could supply an action, then the code that edits your corpus
when you act on file A is written in file B, and reading a file before
trusting it would mean nothing.

The prototype resolver already refuses every `AGENT_*` name (see
"Prototypes"), and the command deliberately does not rely on that: a
guarantee living in another section's regexp is a guarantee one edit away
from gone. All five donors have a test. That is not belt and braces — a
prototype master is not an outline ancestor, so a prototype-only test passes
with the likeliest mutation, an added inherit argument, still in place.
Measured: with that mutation applied, the prototype test passed and the
outline and `#+PROPERTY:` tests failed.

**Nothing in `:AGENT_ACTION:` is ever evaluated.** No `read`, no
`read-from-string`, no `eval`, no `format` into a form, no `macroexpand`, and
no `intern` of text out of a property. A token becomes a function by *name
construction* — `org-agents-action/` plus the token — followed by
`intern-soft` and `fboundp`, so a token that names nothing is a syntax error
rather than a call, and a misspelling cannot even grow the obarray.
Arguments reach a verb as strings, verbatim.

### The vocabulary

Nine verbs. Each is one `defun` over one of Org's own entry-editing
primitives, and each of those primitives is *named once in the whole
package*: `org-entry-delete`, `org-todo`, `org-set-tags`, `org-priority` and
`org-archive-subtree` are called in the verb that owns them, and
`org-schedule` and `org-deadline` are named there and handed to the one
helper `scheduled!` and `deadline!` share. Nothing else in the file writes a
keyword, a tag, a planning stamp, a priority, or an archive. That is a
greppable invariant, and it is what makes the blast radius of this feature
something you can check rather than take on trust.

| Verb | What it edits | Through | Confirms |
| --- | --- | --- | --- |
| `set-property!(NAME, VALUE)` | the property `NAME` | `org-entry-put` | |
| `delete-property!(NAME)` | removes the property `NAME` | `org-entry-delete` | **every time** |
| `tag!(+added -removed)` | the entry's own tags | `org-set-tags` | |
| `todo!(STATE)` | the TODO keyword, and nothing else — no `CLOSED`, no note; a repeating entry is refused | `org-todo` | |
| `priority!(A)` | the priority cookie | `org-priority` | |
| `scheduled!(DATE)` | the `SCHEDULED` stamp | `org-schedule` | |
| `deadline!(DATE)` | the `DEADLINE` stamp | `org-deadline` | |
| `effort!(VALUE)` | `org-effort-property`, normally `Effort` | `org-entry-put` | |
| `archive!` | archives the subtree, into a buffer and never to disk | `org-archive-subtree` | **every time** |

Several of them refuse more than Org does, and each refusal is a measured
hazard rather than fastidiousness.

**`tag!` takes signed terms only, and diverges from org-edna deliberately.**
`org-edna-action/tag!` hands a whole tag specification to `org-set-tags`,
which *replaces* the entry's tags. Over an agent's match set that is a
silent mass deletion, from a verb whose one-word form looks additive. So
here `tag!(+reviewed)` adds, `tag!(-stale)` removes, `tag!(+reviewed -stale)`
does both left to right, and `tag!(reviewed)` is refused with a message
saying to write `+reviewed`. A set-all form, if it is ever wanted, will be a
different verb and it will be destructive.

**`set-property!` will not write a special property**, and names the verb
that will. Measured: `org-entry-put` special-cases `TODO`, `PRIORITY`,
`SCHEDULED` and `DEADLINE`, and for a `SCHEDULED`/`DEADLINE` value that is
empty or `earlier`/`later` it reaches `call-interactively` on `org-schedule`
— a prompt from inside a verb, in the middle of a run over a corpus.

**`scheduled!` and `deadline!` check the shape of the date first.** Measured:
`(org-read-date nil nil "junk")` answers with *today's date*, silently, so
`(org-schedule nil "nextweek")` schedules today and says nothing at all.
Ported naively, one misspelled action would mass-schedule a corpus to today.
The shapes accepted are a date (`2026-08-27`), a date and a time
(`2026-08-27 14:00`), an offset (`+7d`, `++2w`), `today` and `now`; anything
else is refused by name. The dry run then shows the computed stamp, so an
offset is a date you can read before agreeing to it.

**`todo!` checks the state against the keywords of the file the *match* is
in**, because `org-todo-keywords-1` is buffer-local and a corpus may spell
different ones file by file. `org-todo` refuses an unknown state anyway; this
refusal happens in the planning phase instead, so a typo costs a refusal
rather than half a corpus.

**`todo!` refuses a *repeating* entry**, and this one is a disappointment
taken on purpose. Measured on `* TODO Item` with
`SCHEDULED: <2020-01-01 Wed +1w>`: `org-todo` runs `org-auto-repeat-maybe`
from inside itself, so the entry is still `TODO` afterwards, its stamp has
moved to `<2020-01-08 Wed +1w>` and it has gained a `:LAST_REPEAT:` property
— while the line the user approved said `TODO -> DONE`. Two edits no report
line named, and an outcome the entry never reached. The repeater arithmetic
happens at apply time, so no dry run can show it; advancing a repeater is a
per-entry judgement anyway, and that is what `C-c C-t` is for.

**`set-property!` will not write an `AGENT_` name, `PROTOTYPE`, or
`ARCHIVE`.** Measured: `set-property!("AGENT_QUERY", "(todo)")
set-property!("AGENT_ACTION", "archive!")` left both properties on a matched
entry — one confirmed action turning every entry it matched into an agent
carrying its own action, written into files you have never edited. That is
exactly the per-file trust the non-inheritance rule exists to keep.
`ARCHIVE` is refused for a second measured reason: it *steers* where
`archive!` puts a subtree, and since the whole plan is computed before any
row is applied, the dry run named the innocuous default while the subtree
went to the other file.

**One action writes each field once.** Measured: `tag!(+alpha) tag!(+beta)`
at an entry tagged `:api:` reported `:api: -> :api:beta:` on its second line
and left the entry `:api:alpha:beta:` — a report showing *less* change than
the run made, because every planner runs against the state the run began in.
So two verbs writing one field is a parse error naming both, before the
corpus is opened: `tag!(+alpha -stale)` is how you say it in one. A verb of
your own declares what it writes with `org-agents-action-field`; without a
declaration, two calls of it collide and two different verbs do not.

**`archive!` must be the last verb**, and may appear once. It removes the
subtree a later verb would edit, so the ordering is a parse error rather than
something an apply pass discovers half way through.

**`archive!` saves nothing, and checks its destination twice.** Measured:
`org-archive-subtree` ends with `save-buffer` on the archive file, because
`org-archive-subtree-save-file-p` defaults to `from-org` — so a confirmed
`archive!` put files on disk while the command's own summary said *nothing
was saved*, and `undo` in the source buffer cannot take a file back off a
disk. The archive buffer is now left modified and unsaved like every other
buffer a run touches, and it is named in the summary. The destination is also
recomputed immediately before archiving, and a subtree is not archived at all
where that disagrees with the line you approved.

### Value keywords

Three, interpreted by the verbs that take a value — `set-property!` and
`effort!` — and by nothing else.

| Keyword | Expands to |
| --- | --- |
| `today` | an **inactive** date stamp, `[2026-08-20 Thu]` |
| `now` | an inactive date and time, `[2026-08-20 Thu 14:32]` |
| `empty` | the empty string |

Inactive deliberately: a value written into a drawer must not put the entry
on the agenda, which is the same reasoning `:AGENT_MATCHED:` records.

A keyword shadows a literal, and that is the one cost of having keywords at
all. `set-property!(REVIEWED, today)` cannot store the word *today*. The
escape hatch is quoting: `set-property!(REVIEWED, "today")` stores the five
letters. The rule to remember is that **a bare word is literal unless it is
one of those three, and a quoted argument is always literal.** The table is
a constant, not an option: it is a vocabulary, nothing configures it, and no
file can extend it.

### The dry run

`org-agents-apply-actions` reads the action, parses it, computes the match
set, and then prints one line per intended edit into `*Org Agents Actions*`
and stops. Nothing has been written at that point. This is a real transcript,
produced by running it — two files, one of them not open, three matching
entries, two verbs:

```
org-agents: 6 edits at 3 entries in 2 files (1 not open before this ran).  Nothing written yet.
/home/johnw/org/proj.org:1: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]
/home/johnw/org/proj.org:1: tag!(+reviewed)  :api: -> :api:reviewed:
/home/johnw/org/proj.org:5: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]
/home/johnw/org/proj.org:5: tag!(+reviewed)  :api: -> :api:reviewed:
/home/johnw/org/notes.org:1: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]
/home/johnw/org/notes.org:1: tag!(+reviewed)  :api: -> :api:reviewed:
```

The buffer is `compilation-mode`, so `RET`, `next-error` and `M-g n` navigate
to every *intended* edit before any of them exists. Then one question:

```
org-agents: apply 6 edits at 3 entries in 2 files (1 not open before this ran)?
```

The count of files that were not open is taken *before* the query runs,
because matching opens them and afterwards there is nothing left to ask.
Someone about to edit a file they have never opened should be told so in the
sentence they answer. Where the plan holds a destructive verb the question
names it: `..., including the destructive archive!`.

Answered `n`, the header changes to `NOTHING WAS APPLIED.` and not one byte
was written. Answered `y`, each line gains its outcome:

```
org-agents: 6 edits at 3 entries in 2 files (1 not open before this ran).  Nothing was saved; every edit is undoable per buffer.
/home/johnw/org/proj.org:1: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]  applied
/home/johnw/org/proj.org:1: tag!(+reviewed)  :api: -> :api:reviewed:  applied
/home/johnw/org/proj.org:5: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]  applied
/home/johnw/org/proj.org:5: tag!(+reviewed)  :api: -> :api:reviewed:  applied
/home/johnw/org/notes.org:1: set-property!(REVIEWED, today)  nil -> [2026-08-20 Thu]  applied
/home/johnw/org/notes.org:1: tag!(+reviewed)  :api: -> :api:reviewed:  applied
```

```
org-agents: applied 6, refused 0, failed 0, skipped 0, 0 not attempted; modified proj.org, notes.org; nothing was saved -- see ‘*Org Agents Actions*’
```

An error, a `no` to a destructive edit, or `C-g` **stops the run at that
edit**: its own line says `FAILED: ...`, `refused` or `interrupted`, and
every line after it says `not attempted`. There is no rollback.
`atomic-change-group` cannot span buffers and a corpus-wide undo does not
exist, so the honest substitute is that report, `undo` one buffer at a time,
and the fact that nothing was saved.

**Nothing is saved.** That is what actually bounds a bad run: its worst case
is *N modified buffers*, reviewable and undoable one at a time, not N
modified files.

A verb's planning phase is not trusted to write nothing — it is *checked*.
`buffer-chars-modified-tick` is read for **every buffer that was alive when
the plan began**, before and after every planner call, and a tick that moved
aborts the whole command naming the verb and the buffer, before anything is
applied. Measured, and this is why the tick and not the obvious guard:
`buffer-read-only` cannot be used, because `org-entry-put` wraps its body in
`org-no-read-only`, which binds `inhibit-read-only`, and it writes into a
read-only buffer regardless. Measured also, and this is why every buffer and
not the one being planned at: a planner that wrote into a shared scratch
buffer completed the command with no complaint at all, and left that buffer
modified on the runs the user *cancelled*.

A row that would change nothing says so, and is not counted as an edit.
Measured: `delete-property!(ABSENT)` reported `1 edit at 1 entry in 1 file`
and, because the verb is destructive, asked about deleting nothing — which
over ninety matched entries of which four carry the property is ninety
confirmations, eighty-six of them about nothing, in the one sentence this
design leans on for informed consent. Such a line reads `nothing to do`, the
header counts them separately, and where no row would change anything the
command says `THERE IS NOTHING TO DO` and asks nothing.

### The blast radius is the rows the report shows

That is a claim about a *run*, and Org's editing primitives do not honour it
on their own: they are the interactive commands, and they run your hooks. So
the apply phase binds off everything that would edit what no line names —
`org-after-todo-state-change-hook`, `org-trigger-hook`,
`org-property-changed-functions`, `org-after-tags-change-hook`,
`org-archive-hook`, `org-archive-finalize-hook`, `org-log-done`,
`org-todo-log-states`, `org-todo-state-tags-triggers`,
`org-provide-todo-statistics`, `org-log-reschedule`, `org-log-redeadline` and
`org-archive-subtree-save-file-p`.

Measured, each of these through the real command: one function on
`org-after-todo-state-change-hook` left `:TRIGGERED: yes` on an entry the
query never matched, while the report said `1 edit at 1 entry in 1 file`;
`org-log-done` `time` added a `CLOSED:` line no line named; and
`org-trigger-hook` is org-edna's own mechanism — the system this design
deliberately does not extend — so a corpus with `org-edna-mode` on would
schedule successors and flip blockers in other files, none of it reported and
none of it counted against `org-agents-action-limit`.

The cost is worth stating plainly: **`todo!` sets the keyword and nothing
else.** No `CLOSED` stamp is added or removed, no state note is written (a
note would *prompt*, in the middle of a run over a corpus), no statistics
cookie in an ancestor is refreshed, and no tag trigger fires.

`org-blocker-hook` is deliberately *not* bound off: a blocker is your own
refusal to let an entry change, and binding it off would widen a run past
what your config allows. Measured, though, `org-todo` fails **silently** when
a blocker blocks — a `message` and a `throw`, with no signal — so the row
would be reported `applied`. That is why every applied row is **verified**:
the verb's own planning phase is run again at the entry, and where what it
reads back is not what the line said, the row reads `APPLIED DIFFERENTLY: the
entry now reads X, and the plan said Y`, the run stops there, and every later
line says `not attempted`. It is the backstop for the failures nobody has
thought of yet.

### Stamps: the same command, pointed at a selection

With a prefix argument, `C-u M-x org-agents-apply-actions` acts on the
entries the links **in the region** name, rather than on the whole match set.
The action text still comes from the agent's own drawer; only the target set
changes. So a stamp — "mark these four as reviewed" — is this command
pointed at a selection, and the region is the selection.

Point has to be inside the agent's own entry, because that is where the
action is read from. For a list or a table view that is free: the rendered
block sits inside the agent's entry, so selecting rows of it never moves
point out of the agent. For a `children` view the aliases are entries of
their own, so the gesture is point on the agent's heading with the region
reaching down over the aliases you want.

The region is read from point and the mark, deliberately rather than through
`use-region-p`: that predicate answers nil wherever `transient-mark-mode` is
off, which is a setting some people keep. The prefix argument *is* the
request to use the region. A mark at point is refused as the empty region it
is, rather than read as a licence to act on everything.

### How much one run may edit

`org-agents-action-limit` is 100 by default: a plan over more entries than
that is **refused**, naming the count, the limit and the option. Not
truncated — a truncated plan applies a subset you cannot predict, which is
worse than a refusal that names the number.

The gate is on *entries* and not on edits, because entries are what you
reason about: an agent matches four hundred things, not four hundred times
two verbs. The report shows both numbers. And the limit refuses *before*
anything is planned, so a refused run costs the match and nothing more; the
dry run itself is never capped, because a report that understated what
applying would do is the one thing a report may not do.

There is deliberately no refusal by *scope*. Banning `active` or `all` while
permitting an explicit four-thousand-file `:AGENT_SCOPE:` list would be
security by spelling — the prefilter distinguishes cost, not danger. The
entry count covers both.

An agent that legitimately stamps three thousand entries must raise the limit
in init before it will run. That is the cost, and it is the right one: the
three-thousand-entry case is precisely the alarming one, and its enablement
belongs in the trusted zone. File content may only tighten.

### Destructive verbs, and what batch does

`archive!` and `delete-property!` confirm at **every entry, on every run**.
There is no remembered approval, no variable, and nothing to set. They
declare themselves with a symbol property rather than appearing on a list
here, which is also how a verb of your own declares itself.

Where there is nobody to ask, the answer is a **refusal and not a yes**.
Measured, all in `emacs -batch`: `(y-or-n-p "ok? ")` with a `y` on standard
input returns `t`, and with standard input closed it signals `end-of-file`
from inside whatever called it. So a script, a CI job, or any invocation
whose stdin happened to carry text would answer yes for you. The check
therefore comes *before* `y-or-n-p` is called at all — nothing reads stdin
and nothing can hang. `inhibit-interaction` is honoured the same way, because
it is a caller's own declaration that it must not be asked.

One consequence worth knowing: in batch, `org-agents-apply-actions` prints
its dry run and then refuses, whatever the plan holds. The report is still
there to read. There is no batch mode for applying actions, and that is the
design.

### The trust model, in plain words

Arguments are **data**. Nothing in `:AGENT_ACTION:` is read as Lisp,
evaluated, formatted into a form, or interned into a function position. A
verb is resolved by constructing `org-agents-action/` plus the token and
asking `fboundp`, so an unknown token is a syntax error naming the token and
the function that does not exist. An argument that *looks* like Lisp is
refused by shape — parentheses are outside the bare-argument pattern — and
`set-property!(X, (shell-command "y"))` is a parse error naming the verb and
the argument position. Quoting is how you store literal parentheses, and what
quoting gets you is text: `set-property!(NOTE, "(shell-command \"y\")")`
stores those characters.

This is where the design parts from org-edna, which lexes its actions with
`read-from-string`. Measured, as one verb's argument list, that reader
accepts: `(#$)`, which inside a file being loaded yields that file's own
name; `(#s(hash-table test equal))`, a live hash table; `(#1=(a . #1#))`, a
*circular* cons, which `format` `"%s"` prints forever unless `print-circle`
happens to be bound — a denial of service out of a property; and
`(#[257 "..." [1] 2])`, a byte-code object, a callable arriving as data. It
also interns every bare word it passes, so a corpus could grow the obarray,
and every argument would have to be turned back into a string anyway. The
regexp lexer refuses all of that by shape.

**So the worst thing expressible in `:AGENT_ACTION:` is a bounded, greppable
Org edit** — mass retagging, mass property deletion, mass archiving — at the
entries the report lists and nowhere else. There is no shell, no network, and
no file write outside Org's own entry-editing primitives. And the bound on a
misfire is `org-agents-action-limit` entries, in modified buffers, unsaved,
undoable one buffer at a time. An action cannot plant an agent, a prototype
link or action text, either: `set-property!` refuses those names.

Two protections come free on the ordinary path from machinery this feature
did not write. An agent's action never edits the agent itself, because
`org-agents--collect` drops the agent from its own match set; and it never
edits a generated alias, because `org-agents-exclude` defaults to
`(not (property "AGENT_MATCH"))`. If the self-skip ever regressed, an action
would rewrite the drawer it was read from.

The *explicit* path does not go through `org-agents--collect`, so it enforces
both itself. Measured, before it did: an agent whose body held a link to
itself, with that line in the region, applied
`set-property!(AGENT_QUERY, hijacked)` to its own drawer and rewrote the
query the next run would read. A rendered view is full of links and a region
is a hand-made selection, so the one entry that must not be touched is the
one most easily selected by accident. Both are now skipped and *reported* —
`skipped: this is the agent itself`, `skipped: this is a generated alias` —
rather than dropped, because a selection you made and the command declined
has to be visible.

### Writing a verb of your own

A verb is a `defun` in your init file. Nothing registers anything: the
namespace *is* the contract.

```elisp
(defun org-agents-action/shout! (phase name)
  "Upcase the value of property NAME.
Syntax: shout!(NAME)"
  (pcase phase
    ('plan  (cons (org-entry-get nil name)
                  (upcase (or (org-entry-get nil name) ""))))
    ('apply (org-entry-put nil name
                           (upcase (or (org-entry-get nil name) ""))))))

;; Only if it removes information.
(put 'org-agents-action/shout! 'org-agents-action-destructive t)
```

Two phases, one function. `plan` answers `(OLD . NEW)` — each a string or
nil — and must write nothing; `apply` performs the edit and its return value
is ignored. Both run at the match, with point on its heading.

Two phases in one `defun` rather than two functions, because a verb whose
author wrote only the applier would contribute no line to the dry run, and
the report would silently *understate* what applying is about to do. That is
the one failure a dry run may not have. As it is, a `plan` phase that
answers anything but a cons of two strings-or-nil is diagnosed by name.

And a `plan` phase that writes is caught by the tick tripwire, so the dry
run's honesty does not rest on your discipline either.

Arity comes from `func-arity`, so nothing has to be declared: the first
parameter is the phase and the rest are the arguments, positionally, each a
string. Convert a string to something else by *membership in a closed set or
by a regexp*, and refuse otherwise — never with `read`, `intern` or
`string-to-number`. The shipped verbs are the worked examples:
`todo!` checks membership in `org-todo-keywords-1`, `priority!` matches
`\`[A-Z]\'` and then bounds-checks `aref`, and `effort!` does not convert at
all because Org's effort values are text.

To mark a verb as one that must come last, as `archive!` is:

```elisp
(put 'org-agents-action/shout! 'org-agents-action-terminal t)
```

And to say what it writes, so that the one-write-per-field rule knows when
two of your calls collide:

```elisp
(put 'org-agents-action/shout! 'org-agents-action-field
     (lambda (args) (format "the property %s" (upcase (car args)))))
```

Without that, every call of `shout!` claims one field, so `shout!(A)
shout!(B)` is refused. With it, those two are different fields and
`shout!(A) shout!(a)` is still refused, which is right: Org matches a
property name case-insensitively. The string is printed in the refusal, so
write it to be read.

An applied row is **verified**: the planning phase is run again at the entry
and what it reads back has to equal the `NEW` the line showed. So keep the
two phases in step — a `plan` that predicts something the `apply` does not
produce stops the run with `APPLIED DIFFERENTLY`, which is the diagnostic,
not a bug in the machinery. A terminal verb is exempt, since the subtree it
was about to remove is gone.

### What is deliberately not ported

From Tinderbox, whose agents this feature is modelled on:

| Tinderbox | Disposition |
| --- | --- |
| `$Rule`, `$Edict` (polled re-evaluation) | Not ported in any form. Every firing would be an uncommitted edit to one of a few thousand git-tracked files, made behind your back. The save-time *render* is already the honest Edict; anything that writes runs only when asked |
| `$Width`, `$Xpos`, `$Height`, geometry | Not ported; map-view artifacts, and Org has no map view |
| The alias/original live proxy (`$AgentAction` writing "forward") | Not ported; an Org alias is a link, and a link is not a proxy |
| `runCommand()`, `eval()`, an in-document function library | Not ported; the trusted zone is init, and a property is data |
| Inheritable actions | Refused by design, with a test for each of the five donors |
| Materialised inheritance | Refused by design; prototype reads are virtual |


## Installation

### Requirements

* Emacs 29.1
* [org-ql](https://github.com/alphapapa/org-ql) 0.8 — `org-ql` and
  `org-ql-search`, both of which ship together. `org-ql` is required at
  load time; `org-ql-search` is required by `org-agents-preview`, the one
  command that uses it, and is only declared at the top of the file. That
  said, loading `org-agents` does load `org-ql-search` anyway on the
  author's machine, and the reason is transitive and outside this package:
  `org-agents` → `org-ql-ext` → `org-ql-find` → `org-ql-search`. MEASURED,
  `(require 'org-ql-ext)` alone takes `(featurep 'org-ql-search)` from nil
  to `t`. So the lazy require stops this file from *claiming* a load-time
  dependency it does not have; it does not by itself make the load cheaper.
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
             org-agents-list-approvals
             org-agents-check-attributes
             org-agents-attribute-columns
             org-agents-mode
             global-org-agents-mode)
  ;; Org calls the dynamic-block writer by name, from C-c C-x C-u and from
  ;; `org-update-all-dblocks', so it has to be autoloaded as well — and
  ;; `org-agents-allowed-values' is called by name off one of Org's hooks,
  ;; from any Org buffer, which is why the `:init' below is safe.
  :autoload (org-dblock-write:org-agents
             org-agents-allowed-values)
  :init
  ;; Completion of declared attribute values. A library has no business
  ;; adding itself to a user's hook at load time, so this is yours to add;
  ;; the symbol is autoloaded, so the package still loads on first use and
  ;; not at startup.
  (add-hook 'org-property-allowed-value-functions
            #'org-agents-allowed-values)
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

The `add-hook` above is the one thing that is not turned on for you, and
the `:autoload` line beside it is not decoration. This package has no
generated autoloads file — all that is required is that its files be on
`load-path` — so a deferred `use-package` form that adds
`org-agents-allowed-values` to Org's hook without autoloading that symbol
breaks `org-set-property` in **every** Org buffer with `void-function
org-agents-allowed-values`. Adding the hook outside the form, in an init
that never loads `org-agents` eagerly, has the same effect. Keep the two
together.

After that, `org-set-property` on a name the registry declares offers the
values it declares — in every Org buffer, not only in the corpus. A name
the registry says nothing about is left entirely alone, `:NAME_ALL:`
declarations included: see "The attribute registry" below for why that
distinction is sharper than it looks.

## Running the tests

There is no `emacs` on PATH on the machine this was written on — the
interpreter comes out of the nix store — so every target below finds one, or
takes `EMACS=/path/to/emacs`. Never point it at an Emacs invoked with `-Q`:
org-ql lives in site-lisp, which `-Q` suppresses.

```sh
make test        # 449 tests, no external service needed
make test-one T=org-agents-test-expand
make gate        # byte-compile, and fail on any warning at all
make check       # gate, then test
```

`make test` reports `449 tests, 449 results as expected, 0 unexpected` and
takes about half a minute. There is nothing to configure and nothing to
set up. Where `rg` is not on `PATH` it reports `404 results as expected, 0
unexpected, 45 skipped`, and prints one line saying why — `skip-unless` is
honest but silent, and silence is precisely what let this suite's
predecessor report green for months while proving nothing. No test asserts
the count, so these four figures drift whenever the suite grows: read them
as "about this many", and trust `0 unexpected` rather than the total.

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
pushed; everything else stays residual and is applied by org-ql. Seven
shapes push today:

| Conjunct | Pattern | Why it is a superset |
| --- | --- | --- |
| `(property "P")` | `^[ \t]*:P\+?:` | A non-nil `org-entry-get` with `inherit` nil needs a drawer line matching `org-property-re` whose key upcases to `P` or `P+`. The `\+?` is required: an entry whose only line is `:P+: v` answers `"v"`. |
| `(property "P" "v")` | `^[ \t]*:P\+?:[ \t]+v[ \t]*$` | `org-entry-get` joins `:P:` and each `:P+:` with `org--property-get-separator`, so a value that does not contain that separator came from exactly one line. A value that does — or an empty one, or an empty separator — downgrades to the existence pattern above. |
| `(property-ts "P" …)` | as existence | A date match on the value implies the property is there. |
| `(property-resolved "P")` | `(?:^[ \t]*:P\+?:\|^[ \t]*:PROTOTYPE\+?:)` | An entry that resolves `P` either spells a local `:P:` line — the local step reads with inheritance **off**, so a non-nil answer is a line in *this* file — or carries a `:PROTOTYPE:` line, because the chain walk starts at that property and reads it the same way. **Except** where the registry declares an `:ATTR_DEFAULT:` for `P`: then an entry spelling neither line resolves `P` anyway, nothing over the file's text can narrow, and the conjunct stays residual. |
| `(property-resolved "P" "v")` | `(?:^[ \t]*:P\+?:[ \t]+v[ \t]*$\|^[ \t]*:PROTOTYPE\+?:)` | The same argument with the value on the `P` arm — narrower than the existence-on-both-sides form, and sound by the identical reasoning. **Except** where the declared default *equals* `"v"`. A value ripgrep cannot carry degrades to the row above. |
| `scheduled` / `deadline` / `closed` | `SCHEDULED:[ \t]*<`, `DEADLINE:[ \t]*<`, `CLOSED:[ \t]*\[` | Every branch of `org-ql--predicate-ts` begins with a search for the keyword and the bracket, so org-ql cannot match without that text. Bounds are dropped, which drops a *conjunct* of org-ql's condition and never adds one. Deliberately unanchored: all three keywords may share one planning line, in any order. |
| `(heading "lit" …)` | `^\*+(?-u:.)*lit`, one per literal, intersected | org-ql `regexp-quote`s every `heading` argument, so a heading argument is always a literal and is sought as text on both sides — regexp syntax is pushed. `org-get-heading t t` reassembles the title from `org-complex-heading-regexp`'s groups joined by one space, and each group is preceded in the line by at least one real space, so the only substring the line need not spell is one crossing the priority-cookie junction — and every one of those holds the `]` that the guard refuses. `]` is the only character refused. `(?-u:.)` rather than `.` because in ripgrep's Unicode mode `.` matches a codepoint and cannot cross an invalid UTF-8 byte. |

`todo`, `tags`, `regexp`, `ts`, `category`, `priority`, `level` and `path`
are all residual, and so is every conjunct under `or` or `not` and every
nested query — by omission, which widens. A literal is pushed only when
every character in it is printable ASCII: ripgrep decodes as UTF-8 while
Emacs may decode a file as latin-1, and `--encoding` is one global setting
that a mixed corpus cannot use.

Five consequences worth knowing before you rely on it:

* A broad `org-use-property-inheritance` — `t` most of all — makes no
  `property` or `property-ts` conjunct pushable, so an agent built only out
  of those falls back to its scope's whole file set. Still correct, and much
  slower. The prefilter's value depends on keeping inheritance narrow.
  `property-resolved` is the exception, and deliberately: the resolver never
  reads that option and never passes an `INHERIT` argument, so the option
  cannot change what the predicate answers, and refusing to push for a name
  in it would cost narrowing and buy nothing.
* **The alternation is one ripgrep pattern, not two.** Several patterns from
  one conjunct are *intersected*, so a two-pattern answer would mean "spells
  `:P:` **and** carries `:PROTOTYPE:`" — far narrower than either, and
  silent about it. The two rows above return exactly one pattern each, and a
  test asserts the count.
* **The default exception costs narrowing, and only narrowing.** A query at
  the declared default pushes nothing, so an `active` or `all` scope is read
  live with one message naming the file count. That is the honest answer
  rather than a shortcoming: with a default declared, *every* entry in the
  corpus resolves the attribute, and there is no text in any file that
  distinguishes a match from a non-match.
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

### The prefilter cannot block Emacs without bound

The prefilter used to be a synchronous `call-process`, and *nothing* bounded
it. On an unresponsive filesystem — NFS, sshfs, a sleeping disk — or under
`--follow` over a pathological symlink arrangement, it returned when the
child felt like it, and Emacs waited.

Two candidate fixes were measured and one of them does not exist:

* **A timer around `call-process`.** Does not work, and cannot. A
  `run-at-time` set before a `call-process` to a hanging child **never
  fires** — Emacs runs no timers while blocked there. One set before a loop
  over `accept-process-output` fires at +0.57 s. That difference is the
  whole reason the run is now asynchronous.
* **A `timeout(1)` wrapper.** Rejected twice over. `/usr/bin/timeout` does
  not exist on stock macOS, so the package would claim a bound that its own
  platform's default install does not have. And `timeout` bounds the
  *child*, not Emacs: measured against a child that ignores SIGTERM,
  `timeout 2` ran the full 8 s until an outer SIGKILL. SIGKILL is equally
  powerless against a process in an uninterruptible disk wait, which is
  precisely the case this is for — and Emacs would then sit blocked waiting
  for `timeout` to reap something that will not die.

So the run is a `make-process` with a deadline loop, bounded by
`org-agents-rg-timeout` (default 30 s, `nil` for no bound). 30 s is roughly
fifty times the slowest run measured for any pattern this package builds
over a 3,649-file corpus: 0.564 s cold, 0.068–0.083 s warm. On expiry the
process is deleted, one message says so, and the answer is `unavailable` —
which is exactly what a missing ripgrep already answers, so the scope is
scanned live with the message that explains it. **A spurious expiry costs a
slow correct answer and never a wrong one**, and that is what makes having a
bound safe.

One consequence is new and worth stating plainly: **waiting on a subprocess
runs timers and process filters, where `call-process` ran nothing.** So an
update may execute an idle timer while its prefilter is in flight.
`org-agents--update-agent` is written for that — it collects *outside* its
`atomic-change-group`, so no timer's edits can land inside this package's
change group and be undone by a later render failure along with it. And no
save spawns a prefilter at all, whatever `org-agents-prefilter` says, so the
only way to reach the wait is a command you typed. C-g still escapes, because
the error handler catches `error` and not `quit`.

That mitigation covers the `children` view, and **not** the block views, which
is worth knowing if you run a timer that edits Org buffers. A list or a table
renders from Org's dynamic-block writer, which Org calls *after* it has
already deleted the block's body — so the prefilter wait happens with the
block emptied, and an edit landing there during the wait is either glued into
the rendered body or lost when a failed render puts the old body back.
Demonstrated with a one-second stub and a 0.4 s timer. Hoisting that collect
too would mean parsing the block's parameters ahead of Org and matching its
parser exactly, which trades a narrow exposure for a silent divergence, so it
is not done.

Three details of the process are load-bearing and each was wrong on the first
attempt. Completion is sentinel-driven, with `process-live-p` as a second
signal and a bounded drain after it — neither alone: a loop on `process-live-p`
alone returns while the output buffer is still empty, and the sentinel alone
may never arrive. Which is the third detail, and it was a live defect:
`accept-process-output` given a *process* argument returns instantly and never
delivers that process's sentinel once the child has been reaped, so a run that
finished before the wait began spun for the whole timeout — measured, 1.8
million iterations in 3.5 s — and its correct answer was then thrown away as
an expiry. The wait passes no process at all. And stderr goes to a separate
pipe, never merged into stdout: merged, a warning line gets glued onto a
NUL-delimited path, is kept as a file name, and a real file is then silently
dropped from the candidate set — the one direction that loses matches.

Finally, a signal death is not an exit. Measured: a child killed by SIGHUP
reports `process-status` `signal` and `process-exit-status` **1** — the
signal number — and exit 1 is ripgrep's own answer for "no file matches". Read
by exit status alone, an agent whose prefilter was killed would render nothing,
silently. The status is checked as well as the code.

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

### 2. Deleting a pristine alias discards what you added to its drawer

An alias holding nothing but `:AGENT_MATCH: t` is *pristine* and belongs to
the package: every update deletes it and writes it again. Because it is
deleted rather than edited, **extra drawer properties or tags you added to a
body-less alias are discarded.** Write a line under the alias and they are
kept along with it.

### 3. One unreadable file, or one symlink loop, disables the prefilter corpus-wide

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

### 4. A corpus-scope lint leaves every file in scope visited

`org-agents-check-attributes` opens each file with `find-file-noselect`,
as `org-agents-update-all` does, and kills nothing afterwards: a buffer
this command opened is indistinguishable, from inside, from one you had
open already. But an update visits only what `org-agents-files` names —
one file by default — while this is the first command here whose scope can
be `all`, and its `^[ \t]*:PROPERTIES:` pattern narrows a property-heavy
corpus barely at all. Measured: a 13-file scope went from 0 visited Org
buffers to 13. On a corpus of a few thousand files that is a few thousand
buffers, with no message saying so.

The two-tier split above makes this much better in the common case and does
not remove it. Against an **empty** registry the value tier reads nothing at
all, and the run's whole footprint is the confirmation pass — measured, about
150 file opens for 112 candidate names, not 3,616. Against a registry that
declares a name appearing in every file, the tier reads every file and the
old footprint is back. The clean report's counts now say which happened:
"3,616 files in scope, 3,616 read" against "3,616 files in scope, 0 read".

They are ordinary file buffers, unmodified because the lint edits nothing,
so nothing is at risk — but memory and every buffer-list operation
afterwards feel it, and the report's findings are navigable whether or not
the buffers stay. The remedy is the ordinary one: kill the unmodified Org
buffers once you have worked through the report, with
`clean-buffer-list`, with `M-x ibuffer` and `* u`, or by restarting the
session you ran the seeding lint in. Run the `all` scope deliberately
rather than casually.

### 5. Applying actions over a corpus scope leaves every file in scope visited

`org-agents-apply-actions` reaches its match set through the same
`org-agents--collect` an update uses, which opens each candidate file with
`find-file-noselect` and kills nothing afterwards — the footprint
`org-agents-check-attributes` already admits to above, with one difference
that matters: some of those buffers are now **modified**. Nothing is saved,
which is the point, so the corpus on disk is exactly as it was; but a run
over an `all` scope can leave a few thousand buffers open and some tens of
them modified, and there is no corpus-wide undo to put them back with. Undo
is per buffer, and the report in `*Org Agents Actions*` is the list of which
ones to look at.

The remedies are the ordinary ones and there are two, used together. Keep
`org-agents-action-limit` low enough that a mistake is reviewable — the
default of 100 is chosen for that and not for performance. And work through
the report before doing anything else: `next-error` walks the edits, `undo`
in a buffer takes back the edits made in it, and `M-x ibuffer` with `* u`
finds what is still modified. Run an action over an unbounded scope
deliberately rather than casually, and prefer an explicit `:AGENT_SCOPE:`
list where you can name the files.

### Others, less sharp

* `(semantic …)` in an agent query now signals rather than running. It is
  the one change here that can stop a working agent: `org-ql-semantic.el`
  defines `semantic` with a normalizer that runs `org db search` in a
  subprocess, and a normalizer runs when org-ql compiles the query —
  after the gate, so no answer to any prompt governs it. Remove `semantic`
  from `org-agents-refused-heads` to accept that subprocess deliberately;
  nothing else recovers it, because a refusal beats every approval.
* Changing `org-agents-exclude` re-prompts for every previously approved
  query, once each — wherever the exclusion is non-nil, which is the
  default; with it set to nil the form is the bare query and the old hashes
  still match. By design: the gate approves the form that runs, the
  exclusion is part of that form, and an approval that survived a change to
  it would be an approval of something the user never saw. Anyone upgrading
  from a version that gated the query alone will see the same one-time
  re-prompt, because the stored hashes are of the old shape. A REFUSAL is
  not affected either way: it is recorded for the query inside the form as
  well, so an exclusion change can only make the gate stricter.
* A refused query is one printed form, not a query up to meaning. Refusing
  `(and (todo) (evil))` does not cover `(and (evil) (todo))`, which hashes
  differently. Where the objection is to a *predicate*, put it in
  `org-agents-refused-heads`, which refuses it however the query around it
  is spelled.
* An approval made at the prompt on a setup where customize has no file to
  write lasts only until Emacs is restarted. `org-agents-list-approvals`
  lists those rows as `approved (session)` and `d` revokes one, but nothing
  can save one: see `org-agents-safe-queries` for what `custom-file` has to
  be for an approval to survive.
* Because the gate now reads `org-agents-exclude`, the spelling checks read
  it too. A `$PROP` reference there is refused by name — the exclusion is
  not put through the `$PROP` expander, so a reference in it would have
  reached org-ql as a void variable at match time — and so is a
  misspelled head like `headline`. Both used to pass unremarked and fail
  later, or quietly not at all.
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
