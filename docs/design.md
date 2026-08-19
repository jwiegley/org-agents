# Org Agents: Tinderbox-Style Persistent Queries for Org-mode

**Status:** Revision 3 — reconciled with the implementation (ten tasks and twelve review rounds of 2026-08-18); reshaped in revision 2 by the seven-pass review (see `2026-08-18-org-agents-design-review.md`)
**Date:** 2026-08-18
**Sources pinned at:** dot-emacs `b869cdacc`, org-jw `4047166`, org-ql `20250421.133` (0.9-pre per its manual), Org 9.8.7

## Purpose

`org-agents.el` will provide *agents* in the sense of Eastgate Tinderbox (v9.2 manual, `~/Desktop/tbxman920.txt`, "Agents" and "Queries and Actions" chapters): ordinary Org entries that carry a query and, when updated, populate themselves with links back to every entry in `~/org` that matches. An agent renders its matches as child "alias" headings, a plain list, or a table. Queries are org-ql S-expressions extended with a compact `$PROP` property-reference layer. Evaluation is always performed by org-ql against live buffers; the PostgreSQL database maintained by `org db` (org-jw) serves as an optional *candidate-file prefilter* that makes whole-corpus agents affordable. There is exactly one evaluation engine and one answer.

The package is `org-agents.el` (prefix `org-agents-`, avoiding the existing `org-agent-deck-` prefix; no `AGENT_*` property occurs anywhere in the corpus today). A small shared bridge, `org-db-cli.el`, owns the `org` CLI invocation.

## Background (corrected in revision 2)

1. **Tinderbox agents**: a note's `$AgentQuery` is evaluated continuously; matches acquire child aliases; sorting and container counts are visible on the agent. Compactness comes from `$Attr` references with truthiness and coercion, designators, regex operators, and relative dates.
2. **org-db** (PostgreSQL): `entries` with ltree paths, keyword/priority/title/byte-offset columns; `entry_properties` and `entry_tags` hold **local values only** — `is_inherited` is written as false on every store path; tag inheritance is computed *per query* through an ltree ancestor join, property inheritance is not modeled at all, and `#+FILETAGS:` are invisible to the tag join. `entry_stamps` stores planning stamps as Modified-Julian-Day integers (consistent with the compiler's date math). Entry IDs are the `:ID:` property only when it consists of hex-and-dash characters; otherwise (including the corpus's 554 `src-…`/`%(generate-uuid)` IDs) a fresh random UUID is minted **on every store**, so DB ids must never be used to build links.
3. **`org db query --ql`** (`org-jw/bin/DB/Exec.hs`, `org-db/src/Org/DB/Query.hs`) parses an org-ql-like sexp dialect and compiles it to SQL. Its grammar overlaps org-ql's but its **semantics diverge** on `todo`/`done` (any-keyword vs non-done; and empty unless the store ran with `--keywords`), `regexp`/`rifle` (literal ILIKE / tsquery vs Emacs regexp incl. drawers and property values), `heading` (OR over the raw heading line vs AND over the cleaned title), `path` (ILIKE on relative path vs regexp on absolute), `ts` (planning stamps vs whole-entry text), `category` (file fallback vs ancestor inheritance), and `property` equality (the CLI compares one stored row, `org-entry-get` compares the drawer's accumulated value). It also accepts CLI-only forms (`headline`, `re`, `p`, bare atoms, `:before`, `=`) that are not valid org-ql. `--limit` is a client-side `take` over an unordered result set. The 889-line compiler currently has no test coverage. These facts drive the push-down rules below.
4. **Emacs-side assets**: org-ql (`org-ql-defpred`, normalizers, its own gated dynamic block); `org-ql-ext.el` (predicates `about`, `verb`, `shown`, `keyword`, `tasks-for`, `refile-target`, `property-ts`, and the `ql-columnview` dblock — 124 live blocks in the corpus, which this design must not disturb); `org-ql-semantic.el` (CLI JSON-lines bridge and the `(semantic …)` normalizer-primed predicate — the architectural template for the prefilter). `org-transclusion` 1.4.0 is installed.
5. **Property vocabulary in live use**: `ID`, `CREATED`, `MODIFIED`, `LOCATION`, `NEXT_REVIEW`, `LAST_REVIEW`, `REVIEWS`, `URL`, `CATEGORY`.

## Concept Mapping

| Tinderbox | org-agents |
|---|---|
| Agent note with `$AgentQuery` | Org entry with `:AGENT_QUERY:` |
| Child aliases of matches | `children` view: managed child headings linking by `id:`/`file:` |
| Summary table / `$TableExpression` | `table` view |
| Container counts | `:AGENT_MATCHED: N [timestamp]` status property |
| Agent sorting | `:AGENT_SORT:` |
| `$Attr`, truthiness, coercion | `$PROP` references with contextual coercion |
| Designators (`descendedFrom`, `inside`) | org-ql `ancestors`, `parent`, `children`, `descendants` |
| `find()` (transient query) | `org-agents-preview` (thin wrapper over `org-ql-search`, exclusion-parity) |
| `$AgentAction`, `$AgentPriority`, alias attribute display | deferred (see Scope) |

## The Agent Entry

An agent is any Org entry bearing an `:AGENT_QUERY:` property. All user configuration lives in the drawer. **The query must be a single property line** — `:PROP+:` continuation is forbidden because the org-jw parser rejects `+` in property names and then silently discards the *entire drawer* (verified empirically; filed against org-jw). Long queries should name predicates (via `org-ql-defpred` in init) rather than inline complexity.

```org
* Due for review
  :PROPERTIES:
  :AGENT_QUERY:   (and (todo) (property-ts $NEXT_REVIEW :to today))
  :AGENT_VIEW:    table
  :AGENT_COLUMNS: ITEM_BY_ID NEXT_REVIEW REVIEWS
  :AGENT_SORT:    (ts-column 2)
  :END:
```

User-configuration properties — this list is complete:

- `:AGENT_QUERY:` (required) — the query sexp, read with `read`, evaluated only through the gate described under Safety.
- `:AGENT_VIEW:` — `children` (default), `list`, or `table`.
- `:AGENT_SCOPE:` — `agenda` (default; `org-agenda-files`), `active` (the corpus minus `archive/`), `all`, a directory named relative to `org-directory`, or a list of files. Resolution is this package's own: `org-agenda-files` for `agenda`, `directory-files-recursively` for the rest. `agenda` and an explicit file list name their files and are read live. Every other scope is unbounded — `active` and `all` by name, and a directory no less, since naming one bounds nothing about what it holds — and therefore **requires the database prefilter**: if the prefilter is unconfigured, fails, or the query pushes no conjunct for it to answer, the update fails with an error naming the scope, the skeleton and the CLI's state, rather than opening thousands of buffers or silently shrinking scope. The consequence is worth stating plainly: an agent whose query pushes nothing — `:AGENT_SCOPE: positron` with `:AGENT_QUERY: (about "positron")` — errors under a directory scope instead of walking that directory live. Spec fidelity was chosen over a silent mega-open; a file-count threshold that would let small directories evaluate live is a v2 knob, not a v1 behaviour. An absolute directory resolves as a scope but pushes no path conjunct, so it needs a pushable query conjunct like any other unbounded scope.
- `:AGENT_SORT:` — for `children`/`list`: one of org-ql's sorters (`date`, `todo`, `priority`, `reverse`), or a list of them, since `reverse` is only meaningful alongside another; for `table`: `(column N)` or `(ts-column N)`, 1-indexed as in `ql-columnview`, and a number naming no column is refused. Sort forms are view-specific because org-ql's sorters act on elements and table rows are strings, and the mismatch is diagnosed rather than ignored: a form that orders nothing — a row-sort form under `children` or `list`, or a misspelled sorter naming no ordering at all — raises a `user-error` naming it, since a sort that quietly orders nothing looks exactly like a sort that had no effect.
- `:AGENT_LIMIT:` — maximum matches rendered. Applied in Emacs *after* sorting, and after the agent's own entry has been dropped from its matches, so the agent never spends a slot on itself. An element sort is org-ql's, and the limit is taken where the matches are collected; a table's row sort is the renderer's own, so the matches arrive there unlimited and the limit is taken after the rows are ordered — cut first, they would be an arbitrary subset of themselves. A value that is not a count is refused, because `string-to-number` would read one as zero and an agent that renders nothing looks exactly like an agent whose query matched nothing. Never forwarded to the CLI (whose `--limit` is an unordered client-side `take`).
- `:AGENT_COLUMNS:` — table view: space-separated property names; `ITEM_BY_ID` names the link column, wherever in the list it appears, rendered by org-agents' own link builder (not `org-ext-get-properties`, which emits `[[id:nil]]` for ID-less entries). Absent, the table renders `ITEM_BY_ID` alone, which is the one column no property can supply. The link is built only for a table that names the column, so a table without one records no id locations for links nobody holds.
- `:AGENT_FORMAT:` — `children`/`list` views: a space-separated list of property names appended after each link, e.g. `LOCATION NEXT_REVIEW`. (Not Elisp; this keeps rendering out of the eval surface.)

Machine-maintained properties: `:AGENT_MATCH: t` on generated children; `:AGENT_MATCHED: N [inactive timestamp]` on the agent after every update. Documented side effects of `AGENT_MATCHED`: it dirties the buffer, its timestamp is visible to `(ts-inactive …)` queries against agent entries, and its churn changes the entry's org-db content hash (children re-store and title re-embed on the next `org db sync`) — accepted costs of a visible status line. It is *not* a change detector: `org-agents-update-all` reports how many agents it updated and names each one that failed, rather than comparing this render against the last.

### Exclusions

One implicit conjunct keeps agents from consuming other agents' output: the value of `org-agents-exclude` (a defcustom, default `(not (property "AGENT_MATCH"))`) is **appended** (short-circuit last) to the *Emacs-side* verification query only — it is never sent to the database, so it cannot become a near-universal SQL query. The agent entry itself is skipped where the matches are collected, by comparing org-ql's `:org-hd-marker` against the marker read from the agent's own headline; an agent that carries no marker is refused outright rather than allowed to render itself as one of its own matches. `org-agents-preview` applies the same exclusion, so a query developed in preview matches what the agent renders.

## The Query Language

### Base language

The surface language is org-ql's sexp dialect — every installed org-ql predicate, the user's `org-ql-ext` predicates, and `(semantic …)`. The query must be *valid org-ql after expansion*. The gate names the three CLI-only predicate spellings it can name — `headline`, `re`, `p`, each with its org-ql replacement — and looks for them only in query positions: combinators, nested queries, and the arguments of known predicates. In residual Lisp `p` and `re` are an ordinary variable or datum, and diagnosing them there would answer a question the user was never asked. The remaining CLI-only forms (bare atoms, `(property N CMP V)`, `:before`) carry no head to recognize and are refused by org-ql itself at match time rather than by the gate. Any future org-ql predicate works unchanged (it is simply never pushed down until added to the soundness table).

### Property references

- **Truthiness**: bare `$PROP` in boolean position ⇒ `(property "PROP")`, except for the specials below, which name the entry itself and have no property row of that name: `(property "TODO")` is a valid query that never matches, so a bare special expands to its accessor instead and is tested as residual truthiness.
- **Value position**: inside any non-predicate form, `$PROP` ⇒ `(or (org-entry-get nil "PROP") "")` — the empty-string default keeps string functions from signaling on absent properties; the containing form becomes a residual Elisp predicate: `(string-match "github\\.com" $URL)`.
- **Numeric coercion**: when the immediately containing form's head is one of `< > <= >= = + - * /`, the reference coerces via `string-to-number`, absent ⇒ 0: `(> $REVIEWS 3)`.
- **Inheritance**: `$OWNER*` ⇒ `(org-entry-get nil "OWNER" t)`. Inherited references are always residual (the database has no inherited rows).
- **Name position**: as the *first* argument of `property` or `property-ts`, `$PROP` denotes the property **name** string — `(property $KEY "v")`, `(property-ts $NEXT_REVIEW :to today)`. This is the one deterministic exception to the value rule, and it is deliberately narrow: the expander has no reading for a `$ref` in any other argument of those two predicates, and any other known predicate's arguments pass through untouched. A `$ref` that survives expansion is refused by the gate, naming the reference and the form it sits in, rather than reaching org-ql as a void variable at match time.
- **Specials**: `$ITEM`, `$TODO`, `$PRIORITY`, `$TAGS`, `$CATEGORY`, `$LEVEL`, `$FILE` map to the corresponding accessors, a closed set of read-only readers of the entry at point. An inheritance star on a special is ignored, there being no drawer row to inherit. Because the set is closed and known, a query is no less structurally safe for holding one.

`property-ts` is used under its existing name (no `prop-ts` alias), extended only to accept the `$PROP` name position. (Known upstream wart, documented: it ignores `:on`.)

Expansion and splitting are two pure functions rather than one. The expander maps the read sexp to standard org-ql; the splitter maps that expanded query, plus an optional scope conjunct, to the CLI-dialect skeleton string or to nil. The skeleton is produced by `prin1` from the *pre-normalization* sexp (org-ql normalizers create `#s(ts …)` structs the CLI cannot read; `read` has already turned `+7` into `7`), with text properties stripped from every string it carries, since `prin1` would otherwise write a propertized heading literal as `#("Review" 0 6 (face bold))` and the CLI's reader cannot parse that.

The two do not recurse over the same form set. The expander descends through `and`/`or`/`not`/`when`/`unless` and through the nested-query arguments of `parent`, `ancestors`, `children`, `descendants`, so `$refs` are expanded inside nested queries too. The splitter considers only the conjuncts of a top-level `and`, or the whole query when it is a single pushable predicate: a conjunct under `or` or `not`, and every nested query, is residual by omission. That is the safe direction — a wider candidate set, never a wrong one — and it makes a weakest-member rule for nested queries unnecessary in v1. Traversing `or`/`not` and computing a weakest-member class for a nested query is a v2 item, not a defect in v1.

### Comparison with Tinderbox

| Tinderbox action code | org-agents query |
|---|---|
| `$Todo` | `(todo)` |
| `$URL.icontains("github")` | `(string-match "github" $URL)` |
| `$DueDate < date("today")` | `(deadline :to today)` / `(property-ts $DUE :to today)` |
| `$Text.contains("frog")` | `(regexp "frog")` |
| `descendedFrom(/Projects)` | `(ancestors (heading "Projects"))` |
| `$MyNumber > 3` | `(> $MYNUMBER 3)` |

## The Database Prefilter

### Shape

`org-db-cli.el` provides `org-db-cli-query-files SKELETON` → a sorted list of distinct absolute files (nil plus a message on any failure — never a signal). It shells `org --config CFG db --db-url URL query --ql SKELETON --format json` and reads JSON lines, dropping any line that is not a JSON object and any row whose `file` is not a NUL-free string, and reporting the count of skipped lines once.

**Path convention.** The `file` field is **absolute and canonicalized**: the store records `canonicalizePath` of every file it reads, so the CLI answers with truenames. Any consumer intersecting those names with names of its own must compare truenames on both sides — where `org-directory` is a symlink (or, in a test, where macOS hands out `/var/folders/…` whose truename is `/private/var/folders/…`), the two spellings of one file share nothing under `equal` and every agent would match nothing. `org-agents--same-files` is the one place this is done, and it returns the caller's own spellings, because those are the names the user reads and the links that will be followed. Because the field is already absolute, `org-db-cli-files-directory` — the fourth defcustom, named for the relative convention this design first assumed — resolves nothing and stands only as a hedge against a future CLI that emits relative paths. Connection settings are explicit defcustoms in `org-db-cli` (executable, config file, db-url, files-directory); they are **not** defaulted from `org-ql-semantic`'s variables, whose `db-url` is assigned in a deferred `:config` block and is unbound until that package loads. One `setq` in init configures both consumers; migrating `org-ql-semantic.el` onto this bridge is a follow-up, not part of v1.

**Prerequisite org-jw patch (small, landed):** the JSON arm of `DBQuery` resolves file paths once per *distinct* `file_id` through `queryFilePath` and renders each row with a new pure function, `entryRowJson`, moved out of the executable into `Org.DB.Render` so it can be unit tested; `printEntryRowJson` is deleted and `file` is omitted rather than nulled when the path is unknown. `entrySelectSQL` is untouched: revision 2 asked for a join on `files` there — "one query, no per-row `queryFilePath` round trips" — and the implementation deliberately did the other thing, since a join would have paid for the file path on every row of every format where one lookup per distinct file is both cheaper and confined to the format that needs it. Nothing else is required. Optional org-jw follow-ups recorded, not blocking: a batched `SELECT id, path … WHERE id = ANY(?)` in place of one lookup per distinct file id, together with hash-table dedup in place of the three linear passes now on that path (`nub`, the per-row `lookup`, and `cl-pushnew` against a growing list), which correctness does not depend on and a live-DB harness should measure before it lands; accept `+` in property-name identifiers (currently discards whole drawers); a `--list-predicates` capability output; a functional index on `LOWER(name)`; running migrations before `db query`; tests for Query.hs.

### Soundness classes, not names

A pushed conjunct must be **provably a superset filter** (DB result ⊇ org-ql result), because the prefilter only narrows the file set that org-ql then verifies. The v1 table — one defconst of classifier functions keyed by predicate head, each returning the conjunct to push or nil, and each commented with the divergence evidence:

| Conjunct | Pushed as | Why safe |
|---|---|---|
| bare `$PROP` / `(property "P")`, P pushable | `(property "P")` | one-argument `property` carries no `:inherit`, so both sides read the entry's own drawer |
| `(property "P" "v")`, P pushable, `v` free of whitespace | same | two-argument `property` carries no `:inherit` either, so both sides compare the entry's own value |
| `(property "P" "v")`, P pushable, `v` holding whitespace | `(property "P")` | `:P+:` lines accumulate into one separator-joined value; no single stored row can equal it, so equality downgrades to existence |
| `(property-ts $P …)`, P pushable | `(property "P")` | existence is implied by any date match |
| `(scheduled …)` `(deadline …)` `(closed …)`, `:from`/`:to`/`:on` with an integer, `today`, or a calendar-valid `YYYY-MM-DD` | same, with every date resolved to an absolute **local** `"YYYY-MM-DD"` | planning stamps stored for exactly these; MJD-consistent |
| `(heading "lit")`, literal (no regexp metachars) | `(heading "lit")` | ILIKE %lit% over the raw line ⊇ regexp-quoted match over the cleaned title; multi-arg OR ⊇ AND |

A property name is *pushable* when it is an ordinary drawer property: not `CATEGORY` and not one of `org-special-properties`, which `org-entry-get` answers from the entry's structure or its file where the database holds no property row at all. A name in `org-use-property-inheritance` is refused as well — not because the plain `property` forms above inherit, since they do not, but as a conservative guard against a file valued only through `#+PROPERTY:`, which has no property row to find; refusing widens the candidate set and can never drop a match. A form carrying `:inherit` says for itself whether to inherit and has an arity no pattern matches, so it pushes nothing.

A relative date is resolved on the Elisp side, at push time, to an absolute local calendar date, and never sent for the database to resolve: the CLI resolves a relative value against `utctDay <$> getCurrentTime` while org-ql uses `(ts-now)`, so a relative value pushed verbatim names a different day to each engine and under-matches for part of every day. `today` and integer offsets are resolved with `ts-adjust`, which is what org-ql itself uses, so the day arithmetic cannot drift — seconds arithmetic would land on a different calendar day across a daylight-saving change, exactly when the query crosses one. The substitution is exact rather than approximate: org-ql treats an absolute string precisely as it treats `today` — `:from`/`:on` floored, `:to` ceilinged — and the database compares whole-day MJD integers, so both sides select by the same calendar day. The visible consequence is that a skeleton always carries a `"YYYY-MM-DD"`, whatever the agent wrote, and the day is fixed when the query is built, so an update running across local midnight uses the day it started on.

A date filter is pushed only when each of `:from`, `:to` and `:on` appears at most once, and `:on` never appears beside a bound. Both refusals have the same cause: the two engines read those shapes *differently*, not merely loosely. Emacs reads the first occurrence of a repeated key (`plist-get`) while the CLI folds left and keeps the last, so `(scheduled :to today :to "2026-01-01")` bounds by today in org-ql and by 2026-01-01 in the database — a candidate set narrower than what org-ql matches, with nothing said about it. And `org-ql--from-to-on` lets `:on` overwrite both ends while `compileDateConds` emits `day = on` *and* the bound, so the database can answer with nothing where org-ql matches. A bound read differently is the one thing a superset argument cannot cover, so neither shape pushes at all.

A date argument is validated for the calendar, not merely for its shape: the CLI reads an impossible date such as `2026-02-30` as MJD 0 and answers with no files at all, while org-ql normalizes it and matches, which would make the prefilter a subset rather than a superset. Only a date that survives a round trip through `encode-time` and `format-time-string` unchanged is read alike by both sides.

Everything else is residual in v1 — explicitly including `todo`/`done` (keyword columns are empty unless the store ran with `--keywords`; DB `todo` also includes done), `tags` (misses `#+FILETAGS:`), `regexp`/`rifle` (drawer/property-value text is outside `entry_body_blocks`; tsquery stems), `ts` (planning-only in the DB), `category`, `priority`, `level`, `path`, and every `org-ql-ext`/`semantic` predicate. Growing the table later requires a differential test per row (below) and, where the DB under-matches, an org-jw fix first.

The splitter takes the top-level `and`'s table-passing conjuncts as the skeleton, in query order, or the whole query when it is a single pushable predicate. **If no conjunct pushes, the CLI is not called** — the agent runs live over its scope, which therefore must be `agenda`-sized or an explicit file list. A relative `:AGENT_SCOPE:` directory compiles into the skeleton as an org-agents-owned path prefix, last (our contract, relative to `org-directory`), but a scope conjunct alone is not worth a round trip: the caller already knows the scope, so a directory scope whose query pushes nothing yields no skeleton and, being unbounded, is refused. An absolute directory is no such prefix and pushes nothing. User-written `(path …)` predicates stay residual.

### Update data flow

agent entry → read properties → expand → split → (skeleton and CLI configured? → `org-db-cli-query-files` → candidate files ∩ scope files : scope files) → gate → `org-ql-select` of the expanded query + exclusion, `:action 'element-with-markers` → drop the agent itself → sort → limit → render → write `AGENT_MATCHED`.

The intersection is taken over truenames, by the path convention above, and returns the scope's own spellings — those are the names the user reads and the links that will be followed. (`org-directory` is itself commonly a symlink: `~/org` resolves through the Nix store to `/Users/johnw/doc/org`.) The scope's base files are gathered only where they will be used: for an unbounded scope, gathering them is the recursive walk the prefilter exists to make unnecessary, and the refusal must not pay for it first.

Staleness contract, stated honestly: a file whose contents changed since the last `org db sync` is still verified live if it is in the candidate set; a file that *newly* satisfies a pushed conjunct since the last sync is missed until the next sync. Freshness is the user's existing `org db sync` cadence (which requires input files and `--keywords` — the design does not wrap it).

## Materialization

All views link back with links built at the live heading: `org-link-make-string` for descriptions (nested-bracket-safe), target `id:UUID` when `(org-id-get)` returns one — with `(org-id-add-location id file)` called so the link resolves without a corpus rescan — else `file:PATH::SEARCH`, where SEARCH comes from `org-link-heading-search-string` and already begins with the asterisk that makes the search a headline search; writing `::*` before it would yield `::**Heading`, which resolves to nothing. PATH is the base buffer's file, as `org-id` itself reads it, since an indirect buffer visits none. A match with neither an ID nor a file has no location to name at all and is rendered as its heading text with the `(?)` marker, as an unresolvable match is. Table cells additionally escape `|`. Matches are handled as org-ql `element-with-markers` so earlier renders in the same file cannot invalidate later positions; updates run under `org-with-wide-buffer`.

### children view (default)

An update deletes only *pristine* generated children — children at exactly the agent's level plus one whose own drawer carries `AGENT_MATCH` with the value `t` (read locally, never inherited, so a nested agent is not reaped by its parent's), holding a property drawer immediately after the heading and nothing but whitespace after that drawer — and appends one child per match:

```org
** [[id:53A0…][Fix the widget]]
   :PROPERTIES:
   :AGENT_MATCH: t
   :END:
```

Three independent conditions must hold before anything is deleted, and a child failing any of them is the user's. Whitespace after the drawer counts as nothing: a blank line carries no text of the user's, and reading one as an annotation would pin the alias for good. The corollary is a sharp edge worth documenting: because the whole subtree region goes, a property the user added inside an otherwise body-less alias's own drawer, and any tag on its heading line, is discarded with it. Writing anything under the alias is what makes it theirs.

An alias under which the user has nested notes or written text is **preserved**: its match is not duplicated, and if the query no longer finds it, the alias is retitled with a trailing `(stale)` marker rather than deleted. A match that comes back unmarks it again, so the mark answers for this update rather than for an older one. Preservation is keyed on the link *target*, never on the description, which is the live heading text and drifts; the consequence is that a preserved alias goes on showing the description and format suffix it was written with, even after the entry it stands for is renamed. That is what "preserved" means here. An alias whose heading holds no readable link cannot be compared against this round's matches at all, so it is left exactly as it stands and a fresh alias is written for the match it stood for — a duplicate, accepted as the price of not reading a mangled link as any match at all. Two ID-less matches with the same heading in the same file share one target, so an annotated alias standing for either suppresses both: one alias shows where the reported count says two. Manually created children lacking `AGENT_MATCH` are never touched. Contract to document: aliases are ephemeral by default; annotate one to pin it; remove `AGENT_MATCH` to promote it to a real note (which also re-exposes it to agent queries); an alias refiled under a *different* agent will be reaped by that agent's update if pristine.

### list and table views

A dynamic block in the agent's body:

```org
#+BEGIN: org-agents
- [[id:53A0…][Fix the widget]]  Positron office  [2026-08-11 Tue]
#+END:
```

The writer reads the enclosing entry's `AGENT_*` properties; inline block parameters override them, and a standalone block with inline parameters needs no enclosing agent. Inline parameters pass through the same gate as drawer properties. The table view renders `AGENT_COLUMNS` with `ITEM_BY_ID` as the link column. Because Org's dblock machinery deletes the body *before* invoking the writer, the writer computes content first and reinstates the prior body from `(plist-get params :content)` on failure — this is what makes list/table updates atomic under `C-c C-x C-u` and `org-update-all-dblocks` too. `quit` is handled alongside `error`, since it is no subtype of one and C-g part way through a corpus-wide query is the interruption users actually cause: the body goes back first and the quit is signaled again after, so the interrupt still interrupts. The restore is dedented by the block's own indentation column on the error path and not on the quit path, because `org-update-dblock` indents every body line once the writer returns and a re-signaled quit skips that pass; a body put back carrying the indentation it was found with would otherwise gain it again on every failed render. Only a table this render built is aligned afterwards; a body put back is the text that was there. `AGENT_MATCHED` is written by the *caller* after `org-update-dblock` returns (a drawer edit above the block would invalidate the position Org saved before the writer ran).

`ql-columnview` and its 124 existing blocks are untouched and not migrated; `org-dblock-write:org-ql` likewise. The table view is a third renderer only in the narrow sense that it sources query and columns from the agent entry; upstreaming an ID-fallback into `org-ext-get-properties` is a recorded follow-up.

### Commands

- `org-agents-update` — agent or standalone block at point (children view has no dblock, hence a command rather than `C-c C-x C-u` alone).
- `org-agents-update-buffer` / `org-agents-update-all` — all agents in the buffer / in `org-agents-files` (default `(list "~/org/agents.org")`; also accepts directories or `agenda`). Failures are collected per agent and summarized; a failed agent's previous content is preserved.
- `org-agents-preview` — read a query, expand, gate, apply the exclusion, hand to `org-ql-search`. A convenience wrapper, deliberately thin.

Scheduling is not built in: `org-update-all-dblocks` is hook-callable and a one-line `run-with-idle-timer` in init covers periodic refresh; revisit only if practice demands more.

## Safety

The unit of trust is the **whole query** (plus inline dblock params), because org-ql splices the query sexp into a byte-compiled lambda and passes unknown forms through unchanged — `(and (todo) (shell-command "x"))` contains no `$ref` yet would execute. The gate walks the expanded query. A predicate head vouches for its own name only, never for its arguments: org-ql evaluates a predicate's arguments as Lisp too, so `(tags (shell-command "x"))` must not pass on the strength of `tags`, and every argument answers for itself recursively. A form is *structurally safe* when it is a literal; a quoted form, which is returned and never evaluated; one of the seven closed-set `$SPECIAL` accessors; or a proper list whose head is a known predicate (`org-ql-predicates` and its aliases), a boolean combinator, or a nested-query predicate, and whose every argument is itself structurally safe. A proper list whose head is not a symbol is the data it looks like — which is how org-ql's own `(src :lang "elisp" :regexps ("defun"))` is written — and is safe when its elements are, unless that head is itself callable: a byte-code object reads in from a property like any other text and Emacs calls whatever it finds in function position. Anything else fails closed, an improper list included. Everything unsafe — including all `$ref`-generated residual bodies — runs only after confirmation, honoring `org-ql-ask-unsafe-queries` as the master switch, with a `sha1`-keyed session memo and an optional persistent safelist defcustom (the `safe-local-variable-values` pattern); the hash is taken with `print-level` and `print-length` bound to nil, so that a truncated query cannot hash as its own prefix and one approval answer for every query sharing it. Non-interactive contexts skip unapproved agents with a message. A known additional exposure, documented: org-ql *normalizers* run before any body executes (`semantic`'s normalizer spawns the CLI), so the gate runs before normalization, on the raw expanded sexp.

With actions, Elisp formats, computed columns, and Elisp sort keys all out of v1, residual query bodies are the *only* user-supplied code the gate ever evaluates. One conjunct does reach org-ql ungated: `org-agents-exclude` is spliced in *after* the gate has passed the query, which is safe only because it is a defcustom whose `sexp` type leaves it ineligible as a `safe-local-variable`, so a file cannot set it without Emacs's own file-local prompt — the one route by which anything but the user could put code there.

## Failure Handling

The bridge never signals an *error*; it returns nil with a message, on an unconfigured CLI, a nonzero exit (reported with the diagnostics the CLI wrote to stderr, falling back to stdout when stderr is empty), a failure to spawn at all, and unparseable output alike. A `quit` raised by C-g during a synchronous run still escapes, as it must. An update whose prefilter fails (and whose scope demands one) errors per agent, preserving previous content — a DB outage must not silently rewrite a corpus-wide agent as an 11-file agent. Queries that fail to read, expand, or pass the gate report `user-error` naming the agent and the offending form; `org-agents-update-all` continues past failures. A match that cannot be resolved at render time is rendered as plain text with a `(?)` marker.

## Scope of Version 1

In: the expander and gate, the soundness table and splitter, `org-db-cli.el`, the three views with the preservation rule, `AGENT_MATCHED`, sort/limit, preview, update commands, the one-field org-jw patch.

Deferred, in rough order of likely return: `AGENT_ACTION` (Tinderbox `$AgentAction`) behind the same gate; alias display copying (`AGENT_COPY` — note `planning` copying would surface aliases in the agenda, which collects scheduled/deadline entries regardless of TODO keyword); Elisp `AGENT_FORMAT`/computed columns/sort expressions; `AGENT_ADD_IDS`; db registry discovery; growing the push-down table (todo/done after a keyword-config probe, tags after an org-jw FILETAGS fix); traversing `or`/`not` and classifying nested queries by their weakest member; a file-count threshold under which an unbounded scope may still be walked live; the batched file-path lookup in the CLI's JSON arm; a transclusion view; aggregates; save-triggered scheduling; `org-ql-semantic` migration onto `org-db-cli`; a `(org-db …)` org-ql predicate exposing the prefilter to all org-ql consumers.

## Verification

ERT in `org-agents-test.el` (temp buffers; `call-process` stubbed except where noted):

- expansion: `$refs` in boolean/value/numeric/inherited/special/name positions; nested-query recursion; skeleton serialization via `prin1` (no `#s(ts …)`, no `+7`, no text properties);
- splitter: soundness-table membership; empty-skeleton ⇒ no CLI call; a nested query pushes nothing; a date filter the two engines would read differently is not pushed, and a relative date is pushed as an absolute local day that selects what the relative one did; CLI-only spellings rejected;
- gate: `org-agents-test-gate-refuses-bare-call` — an unapproved `(and (todo) (shell-command "x"))` is never evaluated; structural safety passes without prompt; inline dblock params gated;
- bridge: JSON-lines parsing; failure returns nil (`org-db-cli-test-failure-returns-nil`, in `org-db-cli-test.el`);
- rendering: link escaping (`]`, `[[`, `|`, ID-less fallback via heading-search-string); children preservation (`org-agents-test-children-render-and-preserve`); dblock error restores `:content` through the real `org-update-dblock` path; idempotent re-update; sort-then-limit; table `(ts-column N)`;
- exclusion parity between update and preview; `AGENT_MATCHED` written after the dblock update.

**Differential suite** (env-gated by a DSN; fixture corpus stored via `org db store --keywords`): for every row of the soundness table, assert candidate files ⊇ `org-ql-select` match files; one red-team case per known divergence (DONE entry vs `(todo)`, FILETAGS vs `(tags)`, regexp metachars, drawer-value regexp) asserting those conjuncts are *not* pushed. The suite additionally needs the patched CLI: it reads `org-db-cli-executable` from `ORG_AGENTS_TEST_ORG_EXE`, because the profile-installed `org` emits no `file` field until the user rebuilds their environment.

`org-agents.el` and `org-db-cli.el` must byte-compile with zero warnings, and two things make that check reproducible rather than nominal: `(declare-function org-ql--normalize-query "org-ql")` covers the call `org-ql-select` expands into, which org-ql does not autoload; and `org-ql-ext.el` is byte-compiled first, because the repository tracks no `.elc` files and a fresh worktree would otherwise compile that dependency as source and inherit the `Package cl is deprecated` warning its `(eval-when-compile (require 'cl))` raises — a warning the user's own environment, where the `.elc` exists, does not emit. Our source uses only `cl-lib`.

## Alternatives Considered

**Exact/db mode** (render straight from JSON rows) — rejected by review: the compiler's semantics diverge from org-ql on at least seven predicates, DB ids are unusable for links (synthetic and 554 invalid-charset re-randomized IDs), and the raw `headline` field cannot drive `::*` search links. The prefilter keeps the speed benefit without a second source of truth. **A bespoke DSL compiled to SQL in Elisp** — duplicates an (untested) Haskell compiler and loses live evaluation. **Pure org-ql with no database** — remains the degenerate case (empty skeleton / agenda scope); corpus-wide agents are the motivating case and get the prefilter. **Direct PostgreSQL from Emacs** — couples Emacs to the schema; the CLI is the maintained contract. **`org-transclusion` children** — deferred; body-keyword blocks fold poorly at scale. **Storing queries only in dblock headers** — the children view has no block; agent-on-the-note keeps the three views uniform, and standalone blocks remain for ad-hoc tables.

## Resolved Decisions

1. Default view: `children`. 2. Alias copying: none in v1 (`AGENT_COPY` deferred). 3. Registry: explicit `org-agents-files`, default `~/org/agents.org` (db discovery deferred). 4. Naming: `org-agents.el`, `AGENT_*`, plus `org-db-cli.el`. 5. Sequencing: the one-field org-jw patch lands first; everything except the prefilter works without it.
