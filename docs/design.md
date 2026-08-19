# Org Agents: Tinderbox-Style Persistent Queries for Org-mode

**Status:** Revision 2 — reshaped by the seven-pass review of 2026-08-18 (see `2026-08-18-org-agents-design-review.md`)
**Date:** 2026-08-18
**Sources pinned at:** dot-emacs `b869cdacc`, org-jw `4047166`, org-ql `20250421.133` (0.9-pre per its manual), Org 9.8.7

## Purpose

`org-agents.el` will provide *agents* in the sense of Eastgate Tinderbox (v9.2 manual, `~/Desktop/tbxman920.txt`, "Agents" and "Queries and Actions" chapters): ordinary Org entries that carry a query and, when updated, populate themselves with links back to every entry in `~/org` that matches. An agent renders its matches as child "alias" headings, a plain list, or a table. Queries are org-ql S-expressions extended with a compact `$PROP` property-reference layer. Evaluation is always performed by org-ql against live buffers; the PostgreSQL database maintained by `org db` (org-jw) serves as an optional *candidate-file prefilter* that makes whole-corpus agents affordable. There is exactly one evaluation engine and one answer.

The package is `org-agents.el` (prefix `org-agents-`, avoiding the existing `org-agent-deck-` prefix; no `AGENT_*` property occurs anywhere in the corpus today). A small shared bridge, `org-db-cli.el`, owns the `org` CLI invocation.

## Background (corrected in revision 2)

1. **Tinderbox agents**: a note's `$AgentQuery` is evaluated continuously; matches acquire child aliases; sorting and container counts are visible on the agent. Compactness comes from `$Attr` references with truthiness and coercion, designators, regex operators, and relative dates.
2. **org-db** (PostgreSQL): `entries` with ltree paths, keyword/priority/title/byte-offset columns; `entry_properties` and `entry_tags` hold **local values only** — `is_inherited` is written as false on every store path; tag inheritance is computed *per query* through an ltree ancestor join, property inheritance is not modeled at all, and `#+FILETAGS:` are invisible to the tag join. `entry_stamps` stores planning stamps as Modified-Julian-Day integers (consistent with the compiler's date math). Entry IDs are the `:ID:` property only when it consists of hex-and-dash characters; otherwise (including the corpus's 554 `src-…`/`%(generate-uuid)` IDs) a fresh random UUID is minted **on every store**, so DB ids must never be used to build links.
3. **`org db query --ql`** (`org-jw/bin/DB/Exec.hs`, `org-db/src/Org/DB/Query.hs`) parses an org-ql-like sexp dialect and compiles it to SQL. Its grammar overlaps org-ql's but its **semantics diverge** on `todo`/`done` (any-keyword vs non-done; and empty unless the store ran with `--keywords`), `regexp`/`rifle` (literal ILIKE / tsquery vs Emacs regexp incl. drawers and property values), `heading` (OR over the raw heading line vs AND over the cleaned title), `path` (ILIKE on relative path vs regexp on absolute), `ts` (planning stamps vs whole-entry text), `category` (file fallback vs ancestor inheritance), and `property` equality (local vs org-ql's selective inheritance). It also accepts CLI-only forms (`headline`, `re`, `p`, bare atoms, `:before`, `=`) that are not valid org-ql. `--limit` is a client-side `take` over an unordered result set. The 889-line compiler currently has no test coverage. These facts drive the push-down rules below.
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
- `:AGENT_SCOPE:` — `agenda` (default; `org-agenda-files`), `active` (the corpus minus `archive/`), `all`, a directory, or a list of files. Resolution reuses `org-ql-view--expand-buffers-files` where possible. Corpus-wide scopes (`active`, `all`, directories beyond agenda) **require the database prefilter**: if the prefilter is unavailable or returns no usable skeleton, the update fails with a clear error rather than opening thousands of buffers or silently shrinking scope.
- `:AGENT_SORT:` — for `children`/`list`: one of org-ql's sorters (`date`, `todo`, `priority`, `reverse`); for `table`: `(column N)` or `(ts-column N)`, 1-indexed as in `ql-columnview`. Sort forms are view-specific because org-ql's sorters act on elements and table rows are strings.
- `:AGENT_LIMIT:` — maximum matches rendered. Applied in Emacs *after* sorting; never forwarded to the CLI (whose `--limit` is an unordered client-side `take`).
- `:AGENT_COLUMNS:` — table view: space-separated property names; `ITEM_BY_ID` names the link column, rendered by org-agents' own link builder (not `org-ext-get-properties`, which emits `[[id:nil]]` for ID-less entries).
- `:AGENT_FORMAT:` — `children`/`list` views: a space-separated list of property names appended after each link, e.g. `LOCATION NEXT_REVIEW`. (Not Elisp; this keeps rendering out of the eval surface.)

Machine-maintained properties: `:AGENT_MATCH: t` on generated children; `:AGENT_MATCHED: N [inactive timestamp]` on the agent after every update. Documented side effects of `AGENT_MATCHED`: it dirties the buffer, its timestamp is visible to `(ts-inactive …)` queries against agent entries, and its churn changes the entry's org-db content hash (children re-store and title re-embed on the next `org db sync`) — accepted costs of a visible status line. It is *not* a change detector; `org-agents-update-all` reports changes by comparing rendered content.

### Exclusions

One implicit conjunct keeps agents from consuming other agents' output: the value of `org-agents-exclude` (a defcustom, default `(not (property "AGENT_MATCH"))`) is **appended** (short-circuit last) to the *Emacs-side* verification query only — it is never sent to the database, so it cannot become a near-universal SQL query. The agent entry itself is skipped at render time by position. `org-agents-preview` applies the same exclusion, so a query developed in preview matches what the agent renders.

## The Query Language

### Base language

The surface language is org-ql's sexp dialect — every installed org-ql predicate, the user's `org-ql-ext` predicates, and `(semantic …)`. The query must be *valid org-ql after expansion*; CLI-only spellings (`headline`, `re`, `p`, bare atoms, `(property N CMP V)`, `:before`) are rejected by the gate with a message naming the valid form. Any future org-ql predicate works unchanged (it is simply never pushed down until added to the soundness table).

### Property references

- **Truthiness**: bare `$PROP` in boolean position ⇒ `(property "PROP")`.
- **Value position**: inside any non-predicate form, `$PROP` ⇒ `(or (org-entry-get nil "PROP") "")` — the empty-string default keeps string functions from signaling on absent properties; the containing form becomes a residual Elisp predicate: `(string-match "github\\.com" $URL)`.
- **Numeric coercion**: when the immediately containing form's head is one of `< > <= >= = + - * /`, the reference coerces via `string-to-number`, absent ⇒ 0: `(> $REVIEWS 3)`.
- **Inheritance**: `$OWNER*` ⇒ `(org-entry-get nil "OWNER" t)`. Inherited references are always residual (the database has no inherited rows).
- **Name position**: inside a *known predicate's* argument list, `$PROP` denotes the property **name** string — `(property $KEY "v")`, `(property-ts $NEXT_REVIEW :to today)`. This is the one deterministic exception to the value rule; the expander knows the predicate heads.
- **Specials**: `$ITEM`, `$TODO`, `$PRIORITY`, `$TAGS`, `$CATEGORY`, `$LEVEL`, `$FILE` map to the corresponding accessors.

`property-ts` is used under its existing name (no `prop-ts` alias), extended only to accept the `$PROP` name position. (Known upstream wart, documented: it ignores `:on`.)

Expansion is a pure function from the read sexp to `(:full QUERY :skeleton SEXP-STRING-OR-NIL)`. `:full` is standard org-ql; `:skeleton` is the CLI-dialect string for the prefilter, produced by `prin1` from the *pre-normalization* sexp (org-ql normalizers create `#s(ts …)` structs the CLI cannot read; `read` has already turned `+7` into `7`). The expander and the splitter recurse over the same form set: `and`/`or`/`not`/`when`/`unless` plus the nested-query arguments of `parent`, `ancestors`, `children`, `descendants` — `$refs` are expanded inside nested queries too, and a nested query's push-down class is the class of its weakest member.

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

`org-db-cli.el` provides `org-db-cli-query-files SKELETON` → list of files (nil plus a message on any failure — never a signal). It shells `org --config CFG db --db-url URL query --ql SKELETON --format json` and reads JSON lines. Connection settings are explicit defcustoms in `org-db-cli` (executable, config file, db-url); they are **not** defaulted from `org-ql-semantic`'s variables, whose `db-url` is assigned in a deferred `:config` block and is unbound until that package loads. One `setq` in init configures both consumers; migrating `org-ql-semantic.el` onto this bridge is a follow-up, not part of v1.

**Prerequisite org-jw patch (small):** extend `entrySelectSQL` (`org-db/src/Org/DB/Query.hs:391`) with a join on `files` and emit a `file` field from `printEntryRowJson` (`org-jw/bin/DB/Exec.hs:226`) — one query, no per-row `queryFilePath` round trips. Nothing else is required. Optional org-jw follow-ups recorded, not blocking: accept `+` in property-name identifiers (currently discards whole drawers), a `--list-predicates` capability output, a functional index on `LOWER(name)`, running migrations before `db query`, tests for Query.hs.

### Soundness classes, not names

A pushed conjunct must be **provably a superset filter** (DB result ⊇ org-ql result), because the prefilter only narrows the file set that org-ql then verifies. The v1 table — one defconst, each row commented with the divergence evidence:

| Conjunct | Pushed as | Why safe |
|---|---|---|
| bare `$PROP` / `(property "P")` | `(property "P")` | local-only on both sides |
| `(property "P" "v")`, P ∉ `org-use-property-inheritance` | same | org-ql inherits only listed names ('selective) |
| `(property-ts $P …)` | `(property "P")` | existence is implied by any date match |
| `(scheduled …)` `(deadline …)` `(closed …)` | same, `:from/:to/:on` only | planning stamps stored for exactly these; MJD-consistent |
| `(heading "lit")`, literal (no regexp metachars) | `(heading "lit")` | ILIKE %lit% over the raw line ⊇ regexp-quoted match over the cleaned title; multi-arg OR ⊇ AND |

Everything else is residual in v1 — explicitly including `todo`/`done` (keyword columns are empty unless the store ran with `--keywords`; DB `todo` also includes done), `tags` (misses `#+FILETAGS:`), `regexp`/`rifle` (drawer/property-value text is outside `entry_body_blocks`; tsquery stems), `ts` (planning-only in the DB), `category`, `priority`, `level`, `path`, and every `org-ql-ext`/`semantic` predicate. Growing the table later requires a differential test per row (below) and, where the DB under-matches, an org-jw fix first.

The splitter takes the top-level `and`'s table-passing conjuncts as the skeleton. **If the skeleton is empty, the CLI is not called** — the agent runs live over its scope (which therefore must be `agenda`-sized). `:AGENT_SCOPE:` directories compile into the skeleton as an org-agents-owned path prefix (our contract, relative to `org-directory`); user-written `(path …)` predicates stay residual.

### Update data flow

agent entry → read properties → expand + gate → split → (skeleton? → `org-db-cli-query-files` → candidate files ∩ scope files : scope files) → `org-ql-select` of `:full` + exclusion, `:action 'element-with-markers` → sort → limit → render → write `AGENT_MATCHED`.

Staleness contract, stated honestly: a file whose contents changed since the last `org db sync` is still verified live if it is in the candidate set; a file that *newly* satisfies a pushed conjunct since the last sync is missed until the next sync. Freshness is the user's existing `org db sync` cadence (which requires input files and `--keywords` — the design does not wrap it).

## Materialization

All views link back with links built at the live heading: `org-link-make-string` for descriptions (nested-bracket-safe), target `id:UUID` when `(org-id-get)` returns one — with `(org-id-add-location id file)` called so the link resolves without a corpus rescan — else `file:PATH::*SEARCH` where SEARCH comes from `org-link-heading-search-string`. Table cells additionally escape `|`. Matches are handled as org-ql `element-with-markers` so earlier renders in the same file cannot invalidate later positions; updates run under `org-with-wide-buffer`.

### children view (default)

An update deletes only *pristine* generated children — direct children carrying `:AGENT_MATCH: t` with no body text and no children — and appends one child per match:

```org
** [[id:53A0…][Fix the widget]]
   :PROPERTIES:
   :AGENT_MATCH: t
   :END:
```

An alias under which the user has nested notes or written text is **preserved** (its match is not duplicated; if it no longer matches, it is retitled with a trailing `(stale)` marker rather than deleted). Manually created children lacking `AGENT_MATCH` are never touched. Contract to document: aliases are ephemeral by default; annotate one to pin it; remove `AGENT_MATCH` to promote it to a real note (which also re-exposes it to agent queries); an alias refiled under a *different* agent will be reaped by that agent's update if pristine.

### list and table views

A dynamic block in the agent's body:

```org
#+BEGIN: org-agents
- [[id:53A0…][Fix the widget]]  Positron office  [2026-08-11 Tue]
#+END:
```

The writer reads the enclosing entry's `AGENT_*` properties; inline block parameters override them, and a standalone block with inline parameters needs no enclosing agent. Inline parameters pass through the same gate as drawer properties. The table view renders `AGENT_COLUMNS` with `ITEM_BY_ID` as the link column. Because Org's dblock machinery deletes the body *before* invoking the writer, the writer computes content first and on any error reinstates the prior body from `(plist-get params :content)` — this is what makes list/table updates atomic under `C-c C-x C-u` and `org-update-all-dblocks` too. `AGENT_MATCHED` is written by the *caller* after `org-update-dblock` returns (a drawer edit above the block would invalidate the position Org saved before the writer ran).

`ql-columnview` and its 124 existing blocks are untouched and not migrated; `org-dblock-write:org-ql` likewise. The table view is a third renderer only in the narrow sense that it sources query and columns from the agent entry; upstreaming an ID-fallback into `org-ext-get-properties` is a recorded follow-up.

### Commands

- `org-agents-update` — agent or standalone block at point (children view has no dblock, hence a command rather than `C-c C-x C-u` alone).
- `org-agents-update-buffer` / `org-agents-update-all` — all agents in the buffer / in `org-agents-files` (default `(list "~/org/agents.org")`; also accepts directories or `agenda`). Failures are collected per agent and summarized; a failed agent's previous content is preserved.
- `org-agents-preview` — read a query, expand, gate, apply the exclusion, hand to `org-ql-search`. A convenience wrapper, deliberately thin.

Scheduling is not built in: `org-update-all-dblocks` is hook-callable and a one-line `run-with-idle-timer` in init covers periodic refresh; revisit only if practice demands more.

## Safety

The unit of trust is the **whole query** (plus inline dblock params), because org-ql splices the query sexp into a byte-compiled lambda and passes unknown forms through unchanged — `(and (todo) (shell-command "x"))` contains no `$ref` yet would execute. The gate walks the expanded query: a form whose every head is a known predicate (`org-ql-predicates`, the sugar, and the boolean/nested-query combinators, recursively) is *structurally safe* and runs without prompting. Any other form — including all `$ref`-generated residual bodies — makes the query *unsafe*: it runs only after confirmation, honoring `org-ql-ask-unsafe-queries` as the master switch, with a `sha1`-keyed session memo and an optional persistent safelist defcustom (the `safe-local-variable-values` pattern). Non-interactive contexts skip unapproved agents with a message. A known additional exposure, documented: org-ql *normalizers* run before any body executes (`semantic`'s normalizer spawns the CLI), so the gate runs before normalization, on the raw expanded sexp.

With actions, Elisp formats, computed columns, and Elisp sort keys all out of v1, residual query bodies are the *only* user-supplied code the gate ever evaluates.

## Failure Handling

The bridge never signals; it returns nil with a message. An update whose prefilter fails (and whose scope demands one) errors per agent, preserving previous content — a DB outage must not silently rewrite a corpus-wide agent as an 11-file agent. Queries that fail to read, expand, or pass the gate report `user-error` naming the agent and the offending form; `org-agents-update-all` continues past failures. A match that cannot be resolved at render time is rendered as plain text with a `(?)` marker.

## Scope of Version 1

In: the expander and gate, the soundness table and splitter, `org-db-cli.el`, the three views with the preservation rule, `AGENT_MATCHED`, sort/limit, preview, update commands, the one-field org-jw patch.

Deferred, in rough order of likely return: `AGENT_ACTION` (Tinderbox `$AgentAction`) behind the same gate; alias display copying (`AGENT_COPY` — note `planning` copying would surface aliases in the agenda, which collects scheduled/deadline entries regardless of TODO keyword); Elisp `AGENT_FORMAT`/computed columns/sort expressions; `AGENT_ADD_IDS`; db registry discovery; growing the push-down table (todo/done after a keyword-config probe, tags after an org-jw FILETAGS fix); a transclusion view; aggregates; save-triggered scheduling; `org-ql-semantic` migration onto `org-db-cli`; a `(org-db …)` org-ql predicate exposing the prefilter to all org-ql consumers.

## Verification

ERT in `org-agents-test.el` (temp buffers; `call-process` stubbed except where noted):

- expansion: `$refs` in boolean/value/numeric/inherited/special/name positions; nested-query recursion; skeleton serialization via `prin1` (no `#s(ts …)`, no `+7`);
- splitter: soundness-table membership; empty-skeleton ⇒ no CLI call; nested-query weakest-member rule; CLI-only spellings rejected;
- gate: `org-agents-test-gate-refuses-bare-call` — an unapproved `(and (todo) (shell-command "x"))` is never evaluated; structural safety passes without prompt; inline dblock params gated;
- bridge: JSON-lines parsing; failure returns nil (`org-agents-test-bridge-failure-returns-nil`);
- rendering: link escaping (`]`, `[[`, `|`, ID-less fallback via heading-search-string); children preservation (`org-agents-test-children-preserve-annotations`); dblock error restores `:content` through the real `org-update-dblock` path; idempotent re-update; sort-then-limit; table `(ts-column N)`;
- exclusion parity between update and preview; `AGENT_MATCHED` written after the dblock update.

**Differential suite** (env-gated by a DSN; fixture corpus stored via `org db store --keywords`): for every row of the soundness table, assert candidate files ⊇ `org-ql-select` match files; one red-team case per known divergence (DONE entry vs `(todo)`, FILETAGS vs `(tags)`, regexp metachars, drawer-value regexp) asserting those conjuncts are *not* pushed. `org-agents.el` and `org-db-cli.el` must byte-compile without warnings.

## Alternatives Considered

**Exact/db mode** (render straight from JSON rows) — rejected by review: the compiler's semantics diverge from org-ql on at least seven predicates, DB ids are unusable for links (synthetic and 554 invalid-charset re-randomized IDs), and the raw `headline` field cannot drive `::*` search links. The prefilter keeps the speed benefit without a second source of truth. **A bespoke DSL compiled to SQL in Elisp** — duplicates an (untested) Haskell compiler and loses live evaluation. **Pure org-ql with no database** — remains the degenerate case (empty skeleton / agenda scope); corpus-wide agents are the motivating case and get the prefilter. **Direct PostgreSQL from Emacs** — couples Emacs to the schema; the CLI is the maintained contract. **`org-transclusion` children** — deferred; body-keyword blocks fold poorly at scale. **Storing queries only in dblock headers** — the children view has no block; agent-on-the-note keeps the three views uniform, and standalone blocks remain for ad-hoc tables.

## Resolved Decisions

1. Default view: `children`. 2. Alias copying: none in v1 (`AGENT_COPY` deferred). 3. Registry: explicit `org-agents-files`, default `~/org/agents.org` (db discovery deferred). 4. Naming: `org-agents.el`, `AGENT_*`, plus `org-db-cli.el`. 5. Sequencing: the one-field org-jw patch lands first; everything except the prefilter works without it.
