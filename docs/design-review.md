# org-agents Design — Consolidated Heavy-Review Report

**Date:** 2026-08-18
**Scope:** frozen snapshot of `docs/superpowers/specs/2026-08-18-org-agents-design.md` (225 lines) at dot-emacs `b869cdacc`, org-jw `4047166`
**Process:** seven concurrent, independent, read-only passes, each in a no-history subagent (isolation proven by sentinel probe, verified with `verify-history-isolation.py`). 119 raw findings, deduplicated below. Line numbers cite the snapshot, which is identical to the canonical spec at review time.

| Pass | Result | Findings (by severity) |
|---|---|---|
| deep-review | not clean | 5 high, 12 medium, 3 low, 2 questions, 1 observation |
| alexey-discipline | not clean | 5 high, 8 medium, 6 low, 2 questions, 1 observation |
| abstraction-review | EVADES (1 critical) | 1 critical, 3 high, 5 medium, 2 low, 1 question, 1 observation |
| validated (single-model)¹ | not clean | 3 P0, 5 P1-high, 5 P1-medium, 3 P2, 1 question |
| ponytail | not clean | ≈ −650 lines of cuts proposed; core untouched |
| stale-content audit | not clean | 2 high, 6 medium, 4 low, 1 question, 2 observations |
| fact-check audit | not clean | 3 high, 6 medium, 4 low |

¹ The validated pass's **multi-model stage aborted per contract**: `mcp__pal__listmodels` succeeded (exact names `claude-fable-5`, `gpt-5.6-sol` present), but every `mcp__pal__chat` dispatch failed with authentication errors — Anthropic 401 "invalid x-api-key", OpenAI 401 with the key literal `${OPENAI*****KEY}` (an unexpanded shell variable in the PAL server environment), Gemini 400 API_KEY_INVALID. No `metadata.model_used` attestation was obtainable, so per the charter the pass did not substitute models and returned single-model findings, verified against primary sources instead. **Action for the user: the PAL MCP server's API keys are not being expanded into its environment.**

No pass was clean; there are no clean-pass statements to record. Notably, several passes verified empirically (running the real `org` CLI with the user's own config) rather than by reading alone.

## Verified defects

### Critical

**C1 — Push-down by predicate name is semantically unsound; "exact mode" returns wrong answers and even candidate mode can drop true matches.**
Sources: deep#1,#13; alexey#0,#1,#4; abstraction#1 (high); validated#0 (P0),#5,#6,#7; deadcode#0,#1,#9; factcheck#1,#2,#3,#12.
Anchors: spec 105–117, 17, 71; `Org/DB/Query.hs:439-446, 474-482, 529-544, 592-620, 637-655, 855-877`; org-ql.el predicate bodies.
Evidence highlights: DB `(todo)` = `keyword_value IS NOT NULL` (matches DONE; and with the user's `org.yaml` declaring **no keywords**, matches *nothing* unless the store ran with `--keywords`); DB `regexp` = literal `ILIKE` substring (metachars escaped) over headline+body, org-ql `regexp` = real Emacs regexp over the whole entry including drawers and property values; DB `heading` = OR over raw heading line (keyword/priority/tags included), org-ql = AND over the cleaned title; DB `ts` sees only planning stamps; DB tags-inheritance misses `#+FILETAGS:`; org-ql two-arg `property` inherits selectively under the user's `org-use-property-inheritance '("OVERLAY")`; DB `category` lacks ancestor-heading inheritance. Candidate mode's soundness premise (DB result ⊇ live result) is violated by the under-matching cases, so spec line 114's "the only loss is a file that newly matches" was false.

**C2 — The safety gate as specified does not gate: org-ql byte-compiles the whole query sexp, so an unapproved `:AGENT_QUERY:` containing any function call executes arbitrary code; the "pure org-ql" exemption is the hole.**
Sources: deep#2,#16; validated#1 (P0); abstraction#9; ponytail#0.
Anchors: spec 183, 52, 146; org-ql.el `org-ql--query-predicate` (`byte-compile` splices the query verbatim), `org-ql--normalize-query` ("Any other form: passed through unchanged"), `org-ql--ask-unsafe-query`; org-ql-semantic.el:359-361 (the `semantic` *normalizer* spawns a subprocess at normalize time). Standalone dblock inline params were also outside the stated threat model.

**C3 — DB-side rendering cannot produce correct back-links.**
Sources: deep#3,#12; alexey#7,#8; validated#2 (P0),#14; factcheck#4,#8; deadcode#3.
Evidence highlights: synthetic UUIDs are indistinguishable from real `:ID:`s in the JSON; **554 real IDs in the corpus fail `isValidId`** (`src-…` prefixed and literal `%(generate-uuid)`) and get re-randomized per sync; the DB `headline` field is the raw heading line, which Org's `::*HEADLINE` search can never match; `org-ext-get-properties` emits `[[id:nil][…]]` for ID-less entries; no escaping was specified for `]`/`[[`/`|` in link descriptions or table cells (Org provides `org-link-make-string`, `org-link-escape`, `org-link-heading-search-string`).

**C4 — Architectural: the three-backend engine is a parallel mechanism beside an abstraction the codebase already owns.**
Sources: abstraction#0 (critical); alexey#14; ponytail#2.
The candidate composition *is* `org-ql-semantic`'s established pattern (normalizer-primed cache + file prefilter + org-ql as the single evaluator). Exact mode is the only part that genuinely can't be a predicate — and exact mode is exactly the unsound part (C1, C3). The bridge also re-implements org-ql-semantic's private CLI machinery instead of extracting a shared module (abstraction#2), and the `db`-forced backend's only distinct behavior is failing (alexey#14).

### High

**H1 — `:AGENT_QUERY+:` continuation lines destroy the agent's entire property drawer for the `org` CLI** (empirically verified: `properties":[]`, drawer demoted to body text, `:ID:` lost, fresh random UUID per sync). Sources: deep#0; validated#3. Anchors: `flatparse-util Combinators.hs:121-122` (identifier accepts no `+`), `org-parse Parse.hs:63,75,184`. The Emacs side is fine (org concatenates `PROP+` with a space — verified), so this is also a standing org-jw parser bug affecting any drawer containing a `+`-suffixed property.

**H2 — The implicit-conjunct scheme is self-defeating.** With two `(not (property …))` conjuncts prepended, the top level is always `and`, the specified `or`/`not` live-degradation rule is unreachable, and a residual-heavy query issues a near-universal DB query returning one JSON row per corpus entry; `:AGENT_MATCH_AGENTS:` removed *both* exclusions, making an agent-of-agents consume and regrow its own aliases; the spec's own `inside(agent)` example matched the empty set; the exclusion also made preview evaluate a different query than the agent. Sources: deep#4,#9,#22; alexey#16,#17; validated#8; abstraction#3,#7; ponytail#6.

**H3 — Two contradictory scope defaults (`active` ≈ 3,635 files vs live `agenda` ≈ 11 files), and the CLI-failure fallback silently rewrites an agent's children from the large answer to the small one** while reporting success; pure-live `active` would also open and retain ~3,634 buffers. Sources: alexey#2; deadcode#5; deep#11.

**H4 — `--limit` is a client-side `take` over an unordered result set** (no ORDER BY anywhere in the compiler), so forwarding `:AGENT_LIMIT:` yields an arbitrary subset and inverts the spec's sort-then-limit rule; in candidate mode it truncates the candidate file set silently. Sources: deep#5; alexey#5; validated#4; factcheck#6; deadcode#12.

**H5 — The claim that org-db materializes inherited tags/properties is false** (`is_inherited` hard-coded false; inheritance never applied on the store path; tag inheritance is computed per-query via ltree, property inheritance not modeled at all), which invalidated the Taggers mapping and part of the push-down rationale. Sources: deep#19; alexey#4; abstraction#5; deadcode#2; factcheck#0.

**H6 — "The Haskell query compiler is already written and tested" is false** — `org-db`'s entire test suite is `EmbedRetryTest`; Query.hs has zero coverage. "Proven" and "bounds staleness" were also overclaims. Sources: alexey#3,#15.

### Medium (deduplicated)

- **M1** Org's dblock machinery deletes the block body *before* the writer runs; atomicity requires catching errors and reinstating `:content`, and `:AGENT_MATCHED:` must be written by the caller after `org-update-dblock` returns (a drawer edit above the block invalidates the saved position). (deep#8; validated#11)
- **M2** `AGENT_MATCHED` cannot detect change (same-cardinality different sets collide); the embedded inactive timestamp is visible to `(ts-inactive …)` queries and changes the entry's org-db content hash every cycle (children delete/re-insert + re-embed per sync); unconditional writes dirty buffers. (alexey#10; validated#13; deep#15)
- **M3** Children regeneration destroys user content nested under an alias (the natural annotate-a-match workflow); marker-based ownership also lets agent B reap an alias refiled from agent A, and promotes-by-removing-marker changes query visibility at the same time. (deep#14; abstraction#3)
- **M4** `:AGENT_COPY: planning` re-introduces agenda double-counting the spec declared impossible (org-agenda collects scheduled/deadline/timestamp entries with no TODO keyword). (deep#6; alexey#15; deadcode#4)
- **M5** `:AGENT_SORT:` offered org-ql's element sorters uniformly, but table rows are strings — `org-element-property` on them signals wrong-type-argument (which is why `ql-columnview` uses a hand comparator). (alexey#6)
- **M6** `$PROP` had two incompatible readings — value (general rule) vs name (`prop-ts $NEXT_REVIEW`) — leaving the "pure function" expander undefined for predicate argument positions. (deadcode#7; abstraction#11)
- **M7** Sync CLI invocation blocks Emacs per agent and `user-error`s on failure, contradicting collect-and-summarize; the reused invocation shape also cannot run `org db sync` at all (no input files ⇒ empty collection ⇒ no-op), and store/sync require `--keywords` for keyword columns. (deep#17; alexey#9; factcheck#7; validated#0)
- **M8** Nothing accounted for `org-id-locations`: `id:` links to matches outside agenda files never resolve, and each failed open triggers a whole-corpus rescan. (deep#7)
- **M9** The default `db` registry cannot work before the org-jw patch and is stale by construction; four accepted value shapes for one variable. (validated#10; ponytail#7)
- **M10** "Accepted verbatim / always runnable org-ql" is false in both directions: CLI-only names (`headline`, `re`, `p`, bare atoms, `:before`, `=` comparator) are not org-ql, and CLI `(property NAME CMP VALUE)` silently mis-evaluates in org-ql (compares against the symbol `>`). (deadcode#6; factcheck#11; alexey#18; validated#15)
- **M11** Expander/splitter rules covered only top-level `and`/`or`/`not`, omitting the nested-query arguments of `parent`/`ancestors`/`children`/`descendants` that the spec's own examples use ($refs inside them ⇒ void-variable at match time). (abstraction#8)
- **M12** The table view created a third parallel dblock renderer beside `org-dblock-write:org-ql` and `ql-columnview` (124 live blocks in the corpus; `org-ql-ext-export-columnview` parses fixed columns and would silently mis-export a differently-shaped table). (abstraction#4; deadcode#8; ponytail#9)
- **M13** The db-supported predicate table is a hand-copied constant across two repos with no introspection; version skew silently degrades agents to whole-corpus live mode. (abstraction#6)

### Low (deduplicated)

`:AGENT_ADD_IDS:` writes IDs into arbitrary corpus files as a rendering side effect outside the safety story (alexey#13; ponytail#5) · `prop-ts` is a second name for `property-ts`, which itself ignores `:on`/`regexp`/`:with-time` (ponytail#12; deadcode#10) · `rifle` compiles to a `tsv` column that exists only after migrations, and `db query` never runs migrations (factcheck#9) · `LOWER(name)` defeats the property-name index (validated#9) · spec cites `bin/DB/Exec.hs` (actual: `org-jw/bin/DB/Exec.hs`) and pins no org-jw revision (deadcode#11) · predicate inventory omits `refile-target` (deadcode#13; factcheck#10) · Tinderbox manual uncited; Open Decision 4 poses no question (deadcode#14) · exact-mode titles would carry keyword text unlike live titles (validated#16) · connection defaults-by-boundp break because `org-ql-semantic-db-url` is set in a deferred `:config` block (ponytail#15) · `org-agents-update`/`-update-buffer` largely duplicate `org-dblock-update` for the block views (ponytail#13) · preview is a thin wrapper over `org-ql-search` (ponytail#14) · `:AGENT_SCOPE:` re-implements `org-ql-view--expand-buffers-files` (ponytail#8) · idle mode replaceable by `org-update-all-dblocks` in a hook (ponytail#1).

### Questions (not defects)

- Serialization for the CLI must come from `prin1` of the *read* sexp (org-ql normalizers produce `#s(ts …)` structs the CLI can't parse; `+7` reads as `7`, which is why it survives). State it explicitly. (deep#20)
- Behavior under narrowing/indirect buffers; markers vs positions for multi-agent files and action-shifted offsets. (deep#21; alexey#11)
- What does the null alternative actually cost? org-ql's per-buffer cache makes repeated updates cheap; the first-open of N files is the real cost and is measurable in one line. (alexey#19)

### Observations

Things done right, preserved deliberately (abstraction#12): org-ql as the surface language; rejecting a bespoke DSL and direct SQL; `property-ts` reuse through the sanctioned normalizer seam; enriching the producer (org-jw JSON) rather than rediscovering identity in Emacs; deferring transclusion/aggregates. The corpus measurements confirmed: 3,669–3,670 `.org` files (35 under `archive/`), all property-vocabulary claims, `ITEM_BY_ID` conventions, 1-indexed sort columns, CLI flag shapes and ordering, MJD day encoding consistency, `org-transclusion` 1.4.0, and that `AGENT_*` is unused in the corpus.

## Resolution — smallest safe fix order

Applied to the spec as revision 2 (same file). Each fix names its verification; ERT names refer to the implementation plan.

1. **Delete exact mode and the `db` backend; recast the DB as a candidate-file prefilter inside the single org-ql engine** (fixes C1's exactness half, C3, C4; shrinks the org-jw patch to one field). Verify: spec no longer contains an execution path that renders from JSON rows; ERT `org-agents-test-candidate-superset` (differential, DSN-gated) asserts DB candidate files ⊇ org-ql match files per pushed predicate.
2. **Replace the name-based splitter with a per-predicate soundness table seeded only with provably superset-safe conjuncts** — property existence, property equality for names outside `org-use-property-inheritance`, `scheduled`/`deadline`/`closed` date filters, literal-string `heading` — everything else residual; no useful skeleton ⇒ skip the CLI call (fixes C1's candidate half, H2's near-universal query, M13 partially). Verify: ERT `org-agents-test-pushdown-table`; the table lives in one defconst with a comment citing each divergence.
3. **Gate the whole query**: allowlist-walk (predicate heads from `org-ql-predicates` + sugar, recursing into `and/or/not/when/unless` and nested-query predicates); anything else ⇒ org-ql-style confirm + persistent safelist; honor `org-ql-ask-unsafe-queries`; same gate for inline dblock params (fixes C2). Verify: ERT `org-agents-test-gate-refuses-bare-call` — `(and (todo) (shell-command "x"))` is not evaluated without approval.
4. **Single-line `:AGENT_QUERY:` only** (drop `PROP+`); file the org-jw parser bug (identifier rejects `+`, drawer silently dropped) separately (fixes H1). Verify: spec statement + org-jw issue note; ERT for the reader rejecting multi-line advice removed.
5. **One implicit exclusion, owned by a defcustom (`org-agents-exclude`, default `(not (property "AGENT_MATCH"))`), appended to the residual verification only, plus render-time self-skip; delete `AGENT_QUERY` exclusion and `:AGENT_MATCH_AGENTS:`** (fixes H2, alexey#16, deep#9/#22; preview applies the same exclusion for parity). Verify: ERT `org-agents-test-exclusion-parity`.
6. **One scope story**: default `agenda`; `active`/`org-directory` scopes require a healthy DB prefilter and refuse pure-live evaluation; DB failure ⇒ per-agent error, previous content preserved — never a silent smaller-scope rewrite (fixes H3, part of M7). Verify: ERT `org-agents-test-cli-failure-preserves-content`.
7. **Never pass `--limit`; sort then limit in Emacs; sort forms are view-specific** (org-ql sorters for children/list; `(column N)`/`(ts-column N)` for tables) (fixes H4, M5). Verify: ERT `org-agents-test-sort-then-limit`, `-table-sort`.
8. **Correct the false background claims** (inherited materialization, "written and tested", "proven/bounds", ladder description, `org-jw/bin/DB/Exec.hs` path, pin org-jw rev, add `refile-target`, cite the manual, note CLI grammar extras) (fixes H5, H6, M10 prose, lows). Verify: fact-check pass rules re-checked against spec text.
9. **Children-view ownership: preserve aliases carrying user content; delete only pristine generated children; document the refile/promote contract** (fixes M3). Verify: ERT `org-agents-test-children-preserve-annotations`.
10. **Feature cuts (ponytail)**: `AGENT_ACTION` + bespoke safety machinery, `AGENT_COPY`, `AGENT_FORMAT`-as-Elisp (becomes a property-name list), computed columns and Elisp sort keys, `AGENT_ADD_IDS`, `AGENT_MATCH_AGENTS`, `AGENT_UPDATE`/idle mode, `sync-before-update`, db registry discovery, `prop-ts` alias, `AGENT_BACKEND`. Registry defaults to an explicit file list (`~/org/agents.org`). Verify: property table in spec lists exactly QUERY, VIEW, SCOPE, SORT, LIMIT, COLUMNS, FORMAT.
11. **Rendering mechanics**: links built only at live headings via `org-link-make-string`/`org-id-get`/`org-link-heading-search-string`, `|` escaped in tables, `org-id-add-location` called per rendered id link, matches held as markers (`element-with-markers`), updates widen, dblock writer restores `:content` on error, `AGENT_MATCHED` written by the caller after the dblock update (fixes C3 residue, M1, M8, deep#21). Verify: ERT `org-agents-test-link-escaping`, `-dblock-error-restores-content`, `-idempotent-update`.
12. **Bridge**: new `org-db-cli.el` owning invocation + JSON-lines parsing with explicit defcustoms (no boundp-defaulting); errors return nil + message (no `user-error` from the bridge); org-ql-semantic migration noted as follow-up (fixes M7's abort behavior, abstraction#2, ponytail#15). Verify: ERT `org-agents-test-bridge-failure-returns-nil` with stubbed `call-process`, plus the DSN-gated live test.
13. **org-jw patch (single, small)**: join `files` in `entrySelectSQL` and emit `file` in `printEntryRowJson` (no N+1); optional follow-ups noted (`--list-predicates`, `LOWER(name)` functional index, `+` in property identifiers, migrations before `db query`). Verify: `cabal test` in org-jw plus one CLI round-trip in the DSN-gated ERT.

Fixes 1–5 change the architecture and were applied before any implementation planning; 6–13 are spec-level corrections carried into the revised design and its test plan.
