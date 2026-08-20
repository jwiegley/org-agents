# Dynamic properties for org-agents — design

**Status:** Revision 1 — approved in conversation on 2026-08-19; the work is
planned in `PLAN.org` under the five epics this document defines.

**Sources.** The Tinderbox v9.2 manual (`tbxman920.txt`), read for what
Tinderbox *does* rather than what its summaries say; three research documents
committed beside this one under `research/` — `tinderbox-semantics.md` (the
seven action triggers, the exact inheritance order, what does not survive
translation to plain text), `org-existing-facilities.md` (what Org already
has, with the measurements), and `action-code-safety.md` (the gate audit, the
Emacs precedent, the ranked trust models); and this package as it stands
(199 tests, ripgrep prefilter, no database).

## What this adds, in one paragraph

org-agents today implements one of Tinderbox's five dynamic-property
concepts: the agent. This design adds the other four, translated rather than
transliterated: a corpus-wide **attribute registry** (typed user attributes),
**prototypes** resolved virtually at read time (never materialised),
**appearance** driven from attribute values without changing a byte, and
**action code** as a small declarative verb vocabulary applied only by an
explicit command with a dry run. It also hardens the existing query gate
first, because the audit found real gaps that new features would multiply.

## Decisions taken, and their grounds

Four decisions were put to the user and settled on 2026-08-19:

1. **Actions: declarative verbs**, not Lisp, not an org-edna extension, not
   nothing. Arguments are data and are never evaluated; the worst expressible
   attack is a bounded, legible, greppable Org edit.
2. **Prototypes: virtual reads only.** Inherited values exist at read time;
   no command writes them into followers. (Tinderbox's own manual, line 4397:
   wanting to know whether a value is local or inherited "is often a sign
   that your overall design is incorrect" — on disk that distinction would
   be the whole file.)
3. **Appearance: font-lock only.** Zero bytes change. Geometry
   (`$Width`, `$Xpos`) is not ported at all: it describes a map view Org does
   not have.
4. **The registry lives in the corpus**, as an Org file. It is pure data, so
   there is nothing to trust; it syncs with the corpus and is edited as
   notes are.

Two further decisions were forced by measurement rather than preference:

- **org-ql cannot see an inherited property.** With
  `org-use-property-inheritance` at `t`, `(property "STATUS" "active")`
  matches nothing when the value lives on an ancestor: the preamble reads the
  entry's own drawer. Advising `org-entry-get` is silently defeated the same
  way, and defeated a third way by the ripgrep prefilter. So prototype
  resolution is its own predicate, preamble-free by construction.
- **Timer-driven rules are not ported in any form.** Tinderbox's `$Rule` and
  `$Edict` poll a live in-memory graph inside a single document the user
  authored. Here every firing would be an uncommitted edit to one of 3,600
  git-tracked files, made behind the user's back. The byte-identical
  save-time render is already the honest Edict; anything that *writes* runs
  from one explicit command, or not at all.

## Epic 1 — Harden the gate (first, and on its own)

The audit (`research/action-code-safety.md` part 1) verified four gaps in the
shipped package. No new feature lands before these close, because each new
feature multiplies their surface.

- **The gate does not cover what runs.** `org-agents--collect` gates QUERY
  but byte-compiles `(and QUERY org-agents-exclude)`; the exclude is spliced
  in after the gate. Fix: gate and hash the form that is actually compiled.
- **No defcustom is `:risky t`.** `org-agents-exclude`,
  `org-agents-safe-queries`, `org-agents-files`, `org-agents-prefilter`,
  `org-agents-rg-executable` can all be set file-locally today, and Emacs's
  local-variable prompt offers permanent and directory-wide trust. Fix: mark
  all five (and every defcustom this design adds) risky.
- **The approval prompt can show less than the hash covers.** The hash site
  binds `print-level`/`print-length` to nil; the prompt site does not, so a
  deep query can be approved without being fully displayed. Fix: same
  bindings both places.
- **Approvals are invisible and irrevocable.** Fix: a command that lists
  each remembered approval with the query it covers, and removes one; plus a
  negative list refusing a query permanently.
- **Normalizers run after the gate.** A structurally safe head may expand,
  via its org-ql normalizer, into IO (in this configuration, `(semantic …)`
  spawns a subprocess). Fix: a `defcustom org-agents-refused-heads` the gate
  consults, shipped non-empty with the known cases, `:risky t`.

## Epic 2 — The attribute registry

**`defcustom org-agents-attributes-file`**, default `~/org/attributes.org`,
`:risky t`. Each top-level entry declares one attribute: the heading is the
attribute name; the body is its documentation; the drawer carries

    :ATTR_TYPE:    string | number | date | boolean | set | list
    :ATTR_DEFAULT: <value>
    :ATTR_VALUES:  <whitespace-separated allowed values>
    :ATTR_FACES:   <value face [| value face]...>     (consumed by Epic 4)

`set` and `list` follow Tinderbox's meanings — unordered-unique and
ordered — with whitespace-separated members, matching Org's `_ALL`
convention. Types describe; they never block an edit.

The reader parses the file once and caches on its modification tick.
Consumers:

- **Completion.** A function on `org-property-allowed-value-functions`
  answers for declared names, so `org-set-property` completes declared
  values corpus-wide — the registry is the `_ALL` convention with a home.
- **`org-agents-check-attributes`** lints a scope (same scope vocabulary as
  agents): undeclared property names, values outside `ATTR_VALUES`, values
  that do not parse as `ATTR_TYPE`. A report, never an edit. The corpus
  currently uses 137 distinct property names; the first run of this command
  is how the registry gets seeded.
- **A `COLUMNS` generator**: registry names and types to a column format
  string, plus a documented recipe for the fact (measured) that
  `org-agenda-columns` already works inside an `org-ql-search` buffer —
  corpus-wide displayed attributes with write-back editing, today, no code.

## Epic 3 — Prototypes

Any entry may carry `:PROTOTYPE: <name-or-id>`. A name resolves among the
entries of a `Prototypes` top-level section in the attributes file; an
`id:`-style UUID resolves to any entry in the corpus. Prototypes may
themselves carry `:PROTOTYPE:`; chains are followed with a visited set, and
a cycle is a `user-error` naming the cycle.

**Resolution order, per attribute — Tinderbox's exactly:** local value →
prototype chain, nearest first → registry `ATTR_DEFAULT` → nil. Outline
inheritance is deliberately *not* in this order: containment is not
inheritance in Tinderbox, and the two axes stay orthogonal here. The `$PROP`
sugar keeps them separate too: `$NAME` is the local value, `$NAME*` reads up
the outline (existing), and **`$NAME^`** reads through the prototype chain
(new).

`$NAME^` expands to a new org-ql predicate, **`(property-resolved NAME
[VALUE])`**, defined with `org-ql-defpred` and no preamble. It is added to
the gate's known predicates (a pure read), and it is what makes prototypes
real: an agent can say `(and (todo) (property-resolved "STATUS" "active"))`
and match entries whose STATUS arrives from their prototype.

**Prefilter soundness — the one subtle rule.** An inheriting entry never
spells the value, so the ordinary property pattern under-matches. The
widening that restores the superset property: a file containing a matching
entry either spells a local `:NAME:` line or carries a `:PROTOTYPE:` line,
so the pushed pattern is the alternation

    ^[ \t]*:(NAME\+?|PROTOTYPE\+?):

As shipped, that is the **existence** form's pattern (spelled as a
distributed alternation, `(?:^[ \t]*:NAME\+?:|^[ \t]*:PROTOTYPE\+?:)`). The
**value** form puts the value on the NAME arm —
`(?:^[ \t]*:NAME\+?:[ \t]+VALUE[ \t]*$|^[ \t]*:PROTOTYPE\+?:)` — which is
strictly narrower and sound by the identical argument: a matching entry
either spells the value on one line of its own file, or carries a
`:PROTOTYPE:` line in it. A value ripgrep cannot carry on one line degrades
to the existence arm, which is wider and always sound.

**Exception:** when the tested value equals the registry's `ATTR_DEFAULT`
(or the query is bare existence and a default is declared), an entry with
neither line also matches — nothing can narrow, and the conjunct stays
residual. This exception is where a soundness bug would live; it gets the
same differential-test treatment as every existing conjunct: org-ql's answer
over the whole fixture corpus, compared file-by-file against the narrowed
answer, with fixtures on both sides of the default.

The resolver's cache keys on the attributes file's and each prototype
buffer's modification tick. `AGENT_*` properties are excluded from
resolution by name: **behaviour does not travel through prototypes** (see
Epic 5).

## Epic 4 — Appearance

**`org-agents-faces-mode`**, buffer-local, with a global variant patterned on
`global-org-agents-mode`: one font-lock keyword that faces a headline when a
declared attribute's *resolved* value maps to a face in that attribute's
`ATTR_FACES`. Resolution uses Epic 3's cache; the font-lock function is
jit-lock-driven and reads only the entry at the match, so cost scales with
what is displayed, not with the corpus. Zero bytes change; disabling the
mode restores the buffer exactly.

Not in scope: writing anything (tags, TODO state) from appearance
declarations — that is action code through another door, and it goes through
Epic 5's trust model or not at all.

## Epic 5 — Action code

**`:AGENT_ACTION:`** on an agent entry holds edna-shaped text, never a sexp:

    :AGENT_ACTION: set-property!(REVIEWED, today) tag!(+reviewed)

- **Parsing.** Tokens resolve by name construction —
  `org-agents-action/set-property!` — plus `fboundp`. Arguments are strings
  handed to the verb as data; nothing in the property is ever evaluated. An
  unresolved token is a syntax error naming the token. Extension is a
  `defun` in init: the trusted zone Emacs already has.
- **Vocabulary, initially:** `set-property!`, `delete-property!`, `tag!`,
  `todo!`, `priority!`, `scheduled!`, `deadline!`, `effort!`, `archive!`.
  The destructive two — `archive!`, `delete-property!` — confirm every
  time, and no remembered approval silences them.
- **The trigger is the design.** One command,
  **`org-agents-apply-actions`**, runs the agent's query, prints a dry-run
  report — one line per intended edit: `file:line  verb  old → new` — and
  applies only on confirmation from that report. Actions never run from
  `before-save-hook`, a timer, or either minor mode, and a test holds the
  save path to it: saving a file whose agent carries `:AGENT_ACTION:`
  writes nothing beyond the ordinary render. Tinderbox's *Stamps* fall out
  for free: a stamp is this command pointed at a selection.
- **Actions are not inheritable.** The prototype resolver never surfaces
  `AGENT_ACTION` (or any `AGENT_*` property), so the code that can edit your
  corpus is written in the file you are looking at, not reached through a
  chain. `action-code-safety.md` part 3 is the argument: inheritable actions
  make per-file trust meaningless, because saving A would run code written
  in B.

## What is deliberately not ported

| Tinderbox | Disposition |
|---|---|
| `$Rule`, `$Edict` (polled re-evaluation) | Not ported in any form; explicit command only |
| `$Width`, `$Xpos`, `$Height`, geometry | Not ported; map-view artifacts |
| The alias/original live proxy (`$AgentAction` writing "forward") | Not ported; an Org alias is a link |
| `runCommand()`, `eval()`, in-document function library | Not ported; the trusted zone is init |
| Inheritable actions | Refused by design, with a test |
| Materialised inheritance | Refused by design (virtual reads only) |

## Testing strategy

Every epic follows the package's existing discipline: TDD with quoted RED
output, mutation-verified discrimination (each test named with the mutation
that fails it), differential superset tests for anything that touches the
prefilter, and the byte-compile gate at zero warnings. Epic 5 additionally
ships the negative tests first: no write on save, no inherited action, no
evaluation of arguments, destructive verbs confirm.

## Build order

1 (gate) → 2 (registry) → 3 (prototypes) → 4 (appearance) → 5 (actions).
Each epic is independently shippable; nothing later weakens an invariant
established earlier. The issues live in `PLAN.org` under one epic each,
with acceptance criteria per issue.
