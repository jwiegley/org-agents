# What Org and org-agents already give us free

Agent B of 3. Research for a design conversation; nothing here is a commitment to build.

**Bottom line.** Three of the four remaining Tinderbox concepts are substantially already
implemented in stock Org, and the user's own configuration already turns most of them on.
The real gaps are narrow and specific: (1) corpus-wide *scope* for facilities that are
currently per-file or per-subtree, (2) one missing kind of inheritance — by reference
rather than by outline ancestry, and (3) one missing event — "a property changed" as
opposed to "a TODO reached DONE". Everything else in this space is either present, or is
an artifact of Tinderbox being an in-memory GUI database and should not be ported.

The single most important finding is a hazard, not a feature: **any scheme that makes
`org-entry-get` report a value that is not spelled in the file will be silently defeated by
org-ql's preamble optimization and by org-agents' own ripgrep prefilter.** Measured below
(§Check 8). That fact constrains the Prototypes design more than anything else in this
document.

## Environment this was measured in

| Thing | Value |
|---|---|
| Emacs | `/nix/store/1jy6wkqyckvs10q661zvpaxx52g97206-emacs-mac-macport-with-packages-30.2.50/bin/emacs` (30.2.50) |
| Org | 9.8.6, `/nix/store/chhmf76w149f1zps5nh1y9nlvsnl2w1b-emacs-packages-deps/share/emacs/site-lisp/elpa/org-9.8.6/` |
| org-ql | 20250421.133 |
| org-edna | **1.1.2, installed and enabled** (`~/org/init.org:12312`, `(org-edna-mode)`) |
| org-depend | **not installed** (`locate-library` → nil), though `org-depend-tag-blocked` is set at `~/org/init.org:11063` |
| org-agents | `/Users/johnw/.emacs.d/lisp/org-agents/org-agents.el`, 2,847 lines |

Relevant settings already in the user's config (`~/org/init.org`):

- `:11223` `(org-use-property-inheritance '("OVERLAY"))` — deliberately narrow, which is
  what keeps org-agents' prefilter useful (org-agents.el Commentary, "The prefilter's value
  depends on keeping inheritance narrow").
- `:11112` `(org-global-properties '(("Effort_ALL" . "0:05 0:15 …")))` — one declared value set.
- `:11057` `(org-columns-default-format "%TODO %64ITEM(Task) %NEXT_REVIEW")` — column view configured.
- `:11189` `org-todo-keyword-faces` (16 keywords), `:11208` `org-tag-faces`, `:11156` `org-priority-faces`.
- `:12994` `org-after-todo-state-change-hook` and `org-capture-before-finalize-hook` already
  carry `org-review-ext-reviewed-today`; `org-review-insert-last-review` is advised to
  increment a counter. So "a property is updated automatically when something happens" is
  already a live pattern in this configuration.

---

## Already exists / gap

| Tinderbox concept | Org's existing answer | What it does not do | Smallest honest gap | Verdict |
|---|---|---|---|---|
| **System Attributes** ($Color, $Width, $Name) | `org-todo-keyword-faces`, `org-tag-faces`, `org-priority-faces` (all three already configured); a ~12-line font-lock keyword can face a headline from *any* property value with zero bytes changed (Check 6); overlays likewise (Check 7); column view is 100 % overlay-driven (Check 4) | No stock way to say "face this headline by property P"; no geometry, because there is no canvas | A ~40-line minor mode: `:COLOR:` (or a small alist of property → face) driven by a font-lock keyword | **Build the small thing.** Do not port $Width/$Xpos/$Height — they describe a map view Org does not have. |
| **User Attributes** ($Priority, $Status, $DueDate) | The `_ALL` convention, which inherits up the tree *and* falls back to `#+PROPERTY:` and `org-global-properties` (Check 3); `org-property-allowed-value-functions` for computed value sets (Check 9); `:ETC` to allow free values; `org-read-property-name` completion; `org-columns` types by operator | No type declaration beyond the value enumeration; no corpus-wide registry — `org-buffer-property-keys` is per-buffer; no description field | A corpus-wide *declaration* file listing the 137 property names actually in use (Check 11), with type + doc + allowed values, feeding completion | **Mostly use what exists.** `_ALL` is Org's answer and it already has full prototype-style inheritance. The gap is a registry and discoverability, not semantics. |
| **Action Code** (rules, agent actions, OnAdd) | **org-edna, installed and already enabled**: a declarative action language written in the `TRIGGER`/`BLOCKER` properties, with finders (`match()`, `ids()`, `relatives()`, `olp()`, `file()`…), actions (`set-property!`, `todo!`, `scheduled!`, `deadline!`, `tag!`, `set-priority!`, `set-effort!`, `archive!`, `chain!`) and conditions; extensible by defining `org-edna-action/NAME` (Check 5). Plus `org-property-changed-functions`, which fires on every `org-entry-put` (Check 5) | org-edna fires on **exactly one event**: TODO → DONE (`org-edna--should-run-p`, org-edna.el:667). `org-trigger-hook`/`org-blocker-hook` are documented as implemented only for "TODO state changes" (org.el:2111ff). `org-property-changed-functions` does **not** fire on a hand edit of drawer text | Widen the *event*, reuse the *language*: run edna-style forms from a new `AGENT_ACTION`-ish property when an agent matches an entry, and/or on `org-property-changed-functions` | **Do not invent a new action language.** Emit edna forms, or new `org-edna-action/…` functions. This is by far the strongest reuse opportunity in the whole exercise. |
| **Prototypes** | Outline property inheritance (`org-entry-get … t`), which org-agents already exposes as the `$PROP*` sugar; `_ALL` inheritance; `COLUMNS` inheritance; `#+PROPERTY:` / `org-global-properties` as document-level defaults | Tinderbox prototypes inherit **by reference** — a note names any other note as its prototype (manual: "Any note can serve as a prototype to another note"). Org inherits only along the outline tree. `#+PROPERTY:` and `org-global-properties` are invisible to a plain `org-entry-get` (Check 2), so they cannot serve as a general default layer | A `:PROTOTYPE: <id>` resolution step. Feasible in ~15 lines (Check 8) — but see the hazard | **Build, but not by advising `org-entry-get`.** Advice works for direct reads and for `(property NAME)`, and is silently wrong for `(property NAME VALUE)` because of org-ql's preamble, and would be silently wrong for org-agents' ripgrep prefilter too. A dedicated preamble-free org-ql predicate is sound and already passes org-agents' safety gate unchanged (Check 10). |

### The one recommendation that saves the most work

`org-agenda-columns` already works inside an `org-ql-search` results buffer (Check 12).
That means **corpus-wide column view over an arbitrary org-ql query works today, with zero
new code**: displayed attributes, in-place editing that writes back to the source file
through `org-hd-marker`, and `_ALL`-driven completion on `a`. Before building anything for
"displayed attributes", try this. The user has `org-columns-default-format` configured and
exactly **one** `:COLUMNS:` property and **zero** `#+COLUMNS:` lines in a 3,600-file corpus
(Check 11) — the machinery is configured and unused, which is an adoption problem, not a
missing-feature problem.

---

## Two structural facts that constrain every design here

### 1. Tinderbox rules are polled; Org hooks are events

The manual is explicit (grep `"A Rule is performed at frequent intervals"`, ~line 2800):

> An OnAdd action is performed when a note is added to a container, is discovered by an
> agent, or is placed atop an adornment, and affects the note being added.
> A Rule is performed at frequent intervals, and affects the note that possesses the rule.
> An Edict is performed after a document is opened, and at infrequent intervals while the
> document remains open.

And on why Edicts exist (grep `"edicts run at startup and then at intervals"`, ~line 2906):

> You could use a rule, inherited from the Task prototype, to perform these chores. Each
> morning, you'd open the document, Tinderbox would review each task in turn … Once done,
> though, Tinderbox's rule manager would then check each Task again, just in case a task had
> changed status since the previous check. This does no particular harm, but it does use a
> little extra processing power … Instead, we can use an Edict to adjust the appearance.
> Edicts run infrequently … (At present, edicts run at startup and then at intervals of
> approximately one hour …)

A `$Rule` is a *continuously re-evaluated dataflow cell* over an in-memory database of a few
thousand notes. Tinderbox can afford it because the whole document is resident and it owns
every mutation. A 3,600-file, 8.9 MB-in-the-eight-largest-files plain-text corpus cannot:
org-agents already measured 12 seconds for one narrowed corpus-scope agent and *nine minutes
without narrowing* (org-agents.el Commentary, "Scope, and why an unbounded one is worth
narrowing").

**Recommendation: do not port `$Rule` or `$Edict` as polling.** Port them as *idempotent
recomputation on an occasion you already have*: the agent update. org-agents already runs on
`before-save-hook` and via `org-agents-update-all`; an action that runs when an agent matches
an entry is Tinderbox's `$AgentAction` (manual, ~line 2543: "an optional action to be
performed on the newly-created alias of any note that matches the agent's query"), and that
*is* an event, not a poll. `$OnAdd` maps onto `org-capture-before-finalize-hook`, which the
user already uses.

### 2. Any "virtual" property value is silently invisible to two optimizers

Both org-ql and org-agents narrow work by looking at raw file bytes before ever evaluating a
predicate:

- **org-ql preamble.** `(property NAME VALUE)` compiles a preamble regexp
  `^\s*:NAME:\s+VALUE\s*$` (org-ql.el:1854) and only entries whose raw text matches are
  handed to the predicate body. A prototype-supplied value is spelled nowhere, so the entry
  never reaches the body. Measured, both directions, in Check 8.
- **org-agents ripgrep prefilter.** `org-agents--pushdown-fns` (org-agents.el:672) pushes
  `(property NAME VALUE)` as a literal drawer-line pattern, and `(property NAME)` as an
  existence pattern. Same failure mode, one level up: files get dropped with no error.

org-agents already has the right guard for this shape of problem —
`org-agents--property-pushable-p` (org-agents.el:614) refuses to push any name in
`org-use-property-inheritance`, and its comment says outright that the refusal "is a
conservative guard rather than a correctness requirement … if a future org-ql made that true
of the plain forms, this guard is the only thing between that change and a silent wrong
answer." A prototype design should extend exactly that guard rather than invent a new one.

But the clean answer is not a guard at all: define a **new preamble-free org-ql predicate**.
Check 10 shows a 6-line `org-ql-defpred property-proto` that resolves prototypes, matches
correctly with *and* without a value, passes `org-agents--structurally-safe-p` with no change
to org-agents, and is automatically residual in the prefilter because it is not in the
pushdown table. The cost is honest and stateable: a prototype-aware conjunct offers the
prefilter nothing, so a corpus-scope prototype agent is the slow path.

---

## Concept 1 — System Attributes (appearance and identity driven by data)

### What already exists

Org's three built-in "appearance from data" mechanisms are all in use here:
`org-todo-keyword-faces` (16 keywords, `init.org:11189`), `org-tag-faces` (`:11207`),
`org-priority-faces` (`:11154`). Each maps a *value* to a *face* without touching file bytes.

Beyond those, the general mechanism is a font-lock keyword. Check 6 shows a ~12-line matcher
that reads `:Color:` at each headline and faces the headline text accordingly — two headlines
faced `my-color-red` / `my-color-blue`, a third unfaced, buffer bytes unchanged. There is one
non-obvious requirement, worth writing down because it cost a measurement: **the matcher must
wrap its property read in `save-match-data`**, because `org-entry-get` performs regexp
searches and clobbers the match data font-lock is about to use. Without it the matcher runs,
returns non-nil, and font-lock faces the wrong region (Check 6a).

Overlays are the alternative (Check 7): also zero bytes, but they need explicit invalidation
on edit, where font-lock gets that free. Column view already demonstrates the overlay route
at scale — `org-columns` created 16 overlays over the fixture and changed no bytes (Check 4).

`org-columns` also gives the closest thing to `$DisplayExpression`: a `%N` width field and a
`{operator}` that computes a displayed value which is never stored. `org-columns-compile-format`
(org-colview.el:1210) parses `%WIDTH PROP(Title){operator;format}` — five fields, and
**none of them is a color**.

### What it does not do

- No stock "face this headline by property P". Every existing case is hard-wired to TODO
  state, tag, or priority.
- No geometry. `$Width`, `$Height`, `$Xpos`, `$Ypos`, `$MapScrollX` describe a map view. Org
  has no map view. Tinderbox itself classifies these as *intrinsic* — never inherited,
  because "moving an alias does not move the original note" (manual ~line 1560).
- `$Name` has no analogue worth building: the headline *is* the name. `$DisplayName` /
  `$DisplayExpression` — a computed title shown instead of the stored one — is expressible as
  a `display` text property or overlay, but it puts the file and the screen out of
  correspondence in a plain-text tool where that correspondence is the whole point.

### Smallest honest statement of the gap

A minor mode of roughly 40 lines: a customizable alist of property name → face (or a single
`:COLOR:` property naming a face), a font-lock keyword with `save-match-data`, and
`font-lock-flush` on `org-property-changed-functions`.

### Recommendation

Build that. Do **not** port `$Width`/`$Height`/`$Xpos`/`$MapScrollX` — they are artifacts of
the canvas. Do **not** port `$DisplayExpression`; it makes the buffer lie about the file.

---

## Concept 2 — User Attributes (custom data fields with a declared type)

### What already exists

Org's answer is the `_ALL` convention, and it is stronger than it looks.
`org-property-get-allowed-values` (org.el:14007) reads `PROPERTY_ALL` with the `inherit`
flag, so a declaration made once on an ancestor — or in `#+PROPERTY:`, or in
`org-global-properties` — reaches every descendant. Measured (Check 3): `Status_ALL` set only
on `* Parent` was visible three levels down at `*** Grandchild`, and `Effort_ALL` set only in
`org-global-properties` was visible there too.

That is the striking asymmetry of this whole area: **Org's type layer already inherits like a
prototype, while its value layer does not** (Check 1). The declaration mechanism the user
would want for prototypes already exists, one level up, for value sets.

Also present:

- `org-property-allowed-value-functions`, a hook returning a computed value list, so a value
  set can be dynamic (Check 9: a hook returning `("alice" "bob" ":ETC")` was honoured, and
  `:ETC` correctly marked the list unrestricted via the `org-unrestricted` text property).
- Values are read as a Lisp list, so numbers and symbols work, not just strings
  (org.el:14029: `(read-from-string (concat "(" vals ")"))`).
- `S-RIGHT`/`S-LEFT` cycle a property through its allowed values
  (`org-property-next-allowed-value`), and that path fires
  `org-property-changed-functions` (org.el:14076).
- `a` in column view edits the `_ALL` declaration in place and writes it back to the ancestor
  it was inherited from (`org-columns-edit-allowed`, org-colview.el:724).
- Column view types by operator: `{X}`/`{X/}`/`{X%}` treat a value as a checkbox, `{:}` as a
  duration, `{@…}` as an age, `{$}` as currency, `{est+}` as a three-point estimate — 16
  operators in `org-columns-summary-types-default` (org-colview.el:164).

### What it does not do

- No *type* declaration distinct from the value enumeration. Tinderbox has ten-odd types
  (manual ~line 1370: String, color, File, Boolean, Date, …) each with an editing affordance;
  Org has "an enumeration or nothing".
- No description/documentation field. Tinderbox's user-attribute inspector has one: "A text
  field labeled 'Description' invites you to write a brief explanation of the way you intend
  to use the new attribute" (manual ~line 1535).
- **No corpus-wide registry.** `org-read-property-name` completes over
  `(org-buffer-property-keys nil t t)` (org.el:13882) — this buffer's drawers, plus Org's
  defaults, plus names mentioned in COLUMNS formats. Nothing knows what the other 3,600 files
  use.
- No default *value* (as opposed to allowed values) that a plain `org-entry-get` can see —
  that is Concept 4's gap, measured in Check 2.

### Smallest honest statement of the gap

A declaration file — one Org file, or an alist in the config — naming the property names in
actual use with a type, a doc string, and an allowed-value set; feeding
`org-property-allowed-value-functions` for values and one new completion function for names.
The corpus survey (Check 11) says this is a 137-row table, not a thousand-row one.

### Recommendation

Use `_ALL` for value sets; it is already the right mechanism and it already inherits. Build
the registry, because that is genuinely missing and is cheap. Do **not** build a type system:
of 137 property names in the corpus, only 4 headings anywhere carry an `_ALL` declaration
(3 `TAGS_ALL`, 1 `VERB_ALL`) — the demand for *stricter* typing is not evidenced, while the
demand for *knowing what exists* plainly is.

---

## Concept 3 — Action Code

### What already exists

**org-edna, version 1.1.2, installed and enabled by the user's own config.** This is prior
art for exactly the thing being proposed: a declarative action language written in an Org
property. Its own Commentary: "Edna provides an extensible means of specifying conditions
which must be fulfilled before a task can be completed and actions to take once it is. Org
Edna runs when either the BLOCKER or TRIGGER properties are set on a heading, and when it is
changing from a TODO state to a DONE state."

Its vocabulary, from the source:

- **Finders** (which entries to act on): `match("SPEC" SCOPE SKIP)` — passed straight to
  `org-map-entries`, agenda-scoped by default — plus `ids()`, `olp()`, `file()`,
  `org-file()`, `relatives()`, `siblings()`, `children()`, `parent()`, `descendants()`,
  `ancestors()`, `next-sibling()`, `chain-find()`, and wrapping variants.
- **Actions**: `todo!`, `scheduled!`, `deadline!`, `tag!`, `set-property!`,
  `delete-property!`, `clock-in!`, `clock-out!`, `set-priority!`, `set-effort!`, `archive!`,
  `chain!`. `set-property!` takes `inc`/`dec`/`next`/`prev` as well as a literal, so
  counters and `_ALL` cycling are already there.
- **Conditions**: `done?`, `todo-state?`, `headings?`, `variable-set?`, `has-property?`.
- **Extension point**: dispatch is by symbol name, `org-edna-action/NAME` /
  `org-edna-finder/NAME` / `org-edna-condition/NAME`. A new action is a new function; no
  change to org-edna.

Measured (Check 5): `:TRIGGER: self set-property!("Status" "closed") set-property!("Hits" inc)`
on a `TODO` heading, marked DONE, produced `Status = "closed"` and `Hits` incremented
`3 → 4`. That is Tinderbox action code, working, today, in this environment.

Alongside it: `org-property-changed-functions` fires on every `org-entry-put`
(org.el:13634) — including edna's own writes, which is both the reason a change-driven rule
system is possible and the reason it can re-enter. `org-trigger-hook` and `org-blocker-hook`
are the general mechanism edna hangs on (`org-edna--load`, org-edna.el:729).

### What it does not do

- **One event only.** `org-edna--should-run-p` (org-edna.el:667) requires
  `(eq type 'todo-state-change)` *and* a from-TODO *and* a to-DONE. Measured: TODO → NEXT
  fired nothing (Check 5). `org-trigger-hook`'s own docstring says the mechanism "is
  currently implemented for: TODO state changes" (org.el:2111).
- `org-property-changed-functions` does **not** fire when the user edits the drawer text by
  hand (Check 5). It is an API hook, not a change hook. Anything relying on it will see
  programmatic writes and miss typing.
- No "run this for every note matching a query, now" occasion. `match()` exists as a
  *finder* but only reachable from a TODO→DONE trigger.
- No idempotence discipline. Tinderbox re-runs rules constantly and relies on assignment
  being idempotent; an Org action that runs once per save must be written to be safe to
  re-run, and nothing enforces that.

### Smallest honest statement of the gap

The gap is **the occasion, not the language**. Two candidate occasions, both of which
org-agents already owns:

1. *Agent match* — Tinderbox's `$AgentAction`. When `org-agents--collect` returns a match,
   run the agent's `:AGENT_ACTION:` at that entry. This is a genuinely new capability and it
   is the one Tinderbox users actually reach for.
2. *Property change* — add to `org-property-changed-functions`, accepting that hand edits are
   invisible and that re-entrancy needs a guard.

### Recommendation

**Emit org-edna syntax; do not design a second action language.** Either write
`:AGENT_ACTION:` values in edna's own notation and hand them to `org-edna-process-form`, or
add `org-edna-action/…` functions for whatever is missing. The user already has edna loaded,
already has 31 `:BLOCKER:` properties in the corpus, and would otherwise be maintaining two
incompatible mini-languages in the same drawers.

If a general "rules" facility is wanted, note that the honest Org equivalent of an Edict is
`org-agents-update-all` — a batch pass, run when asked, that recomputes everything and is
byte-identical when nothing changed. org-agents already implements exactly that discipline
(`org-agents--mask-matched` / `org-agents--restore-text`), and it is the single most valuable
piece of existing plumbing for this concept.

---

## Concept 4 — Prototypes

### What already exists

Three separate inheritance mechanisms, none of which is Tinderbox's:

1. **Outline inheritance.** `(org-entry-get POM PROP t)` walks ancestors and stops at the
   first that has the property (`org-entry-get-with-inheritance`, org.el:13512). org-agents
   already exposes this as the `$PROP*` sugar, which expands to `(org-entry-get nil NAME t)`
   (org-agents.el:318) — an explicit always-inherit read that ignores
   `org-use-property-inheritance` entirely. That is already a working
   inheritance-in-queries feature, and because it lands in residual Lisp it is also already
   immune to the preamble/prefilter hazard.
2. **`_ALL` inheritance** — Concept 2, above. Fully working, including document-level fallback.
3. **`COLUMNS` inheritance** — `org-columns` reads `(org-entry-get nil "COLUMNS" t)`
   (org-colview.el:859, :1769) and remembers where it came from via
   `org-entry-property-inherited-from`. So "which attributes this class of note displays" —
   Tinderbox's `$DisplayedAttributes`, which "notes often inherit … from their prototype"
   (manual ~line 1490) — already inherits in Org.

### What it does not do

**Tinderbox prototypes inherit by reference, not by containment.** From the manual
(grep `"Any note can serve as a prototype to another note"`, ~line 1020):

> Notes can inherit properties from another note, the note's prototype. Any note can serve as
> a prototype to another note. If a note has a prototype, most of its attributes will be
> inherited from the prototype. If you do set an attribute's value for that note, the value
> you supply overrides the inherited value. Inheritance lets you say, "Make this note just
> like that one, unless I tell you otherwise."
> … Prototypes may themselves inherit from prototypes.

and (~line 1691):

> Any Tinderbox note can serve as a prototype for other notes. Prototypes let you specify the
> default value for an entire class of notes. Whenever Tinderbox checks an attribute that you
> haven't specifically set, it will use the value from the prototype. Change an attribute in a
> prototype, and you change it for the notes that use that prototype.

Two properties of that which Org's outline inheritance does not have: the prototype is chosen
per note and can live anywhere in the document, and inheritance is *live* — editing the
prototype changes every user of it. Org's outline inheritance is live too, but you cannot
choose your ancestor.

And the document-level default layer is not usable as a substitute, because of a genuinely
surprising fact measured in Check 2: **`#+PROPERTY:` and `org-global-properties` are invisible
to a plain `org-entry-get`.** They are consulted only inside
`org-entry-get-with-inheritance` (org.el:13542-13545), i.e. only when the `inherit` argument
is non-nil. And Check 1 confirms the coordinator's measurement, with the source line that
explains it: `org-entry-get`'s dispatch is

```elisp
((and inherit (or (not (eq inherit 'selective)) (org-property-inherit-p property)))
 (org-entry-get-with-inheritance property literal-nil epom))
```

— `org-use-property-inheritance` is reached *only* through `'selective`. A plain
`org-entry-get` never inherits, at any setting of the variable. Neither does
`org-entry-properties` (Check 1).

There is a third sharp edge (Check 2a): a file-level property drawer only becomes an
`org-data` property if it is the **very first thing in the file**. Placed after a
`#+TITLE:` line it is inert, silently.

### Smallest honest statement of the gap

A `:PROTOTYPE: <id-or-olp>` resolution step, plus a decision about *where* it is resolved.
That decision is the whole design, and Check 8 measures why:

| Read path | Sees prototype under an `org-entry-get` advice? |
|---|---|
| direct `org-entry-get` | yes |
| org-agents `$PROP` / `$PROP*` (residual Lisp) | yes |
| org-ql `(property "Genre")` | yes (no preamble for the 1-arg form) |
| org-ql `(property "Genre" "fiction")` | **no** — preamble regexp drops the entry |
| org-ql `(property …)` with `org-ql-use-preamble` nil | yes |
| org-agents ripgrep prefilter | **no** — pushdown emits a literal drawer-line pattern |
| `org-entry-properties` (and anything built on it) | no |
| `org-columns` / `org-agenda-columns` | yes (they read via `org-entry-get`) |
| org-agents table cells / `:AGENT_FORMAT:` suffix | no — both use `(org-entry-get nil COLUMN)` with no inherit flag |

### Recommendation

**Do not implement prototypes by advising `org-entry-get`.** It is 15 lines and it works, and
it is wrong in exactly the places where being wrong is invisible: two independent optimizers
drop candidates without an error, and the failure depends on whether the query happened to
mention a value.

Implement instead as a **preamble-free org-ql predicate** plus an explicit reader function.
Check 10 shows the whole shape working: a 6-line `org-ql-defpred property-proto` matched both
the prototype and its user, with and without a value; `org-agents--structurally-safe-p`
accepted it with no change to org-agents (because `org-agents--known-predicate-p` consults
`org-ql-predicates`, which `org-ql-defpred` extends); and
`org-agents--prefilter-conjuncts` returned `nil` for it — automatically residual, therefore
automatically sound.

State the cost plainly to the user: a prototype-aware conjunct pushes nothing, so an agent
whose only conjunct is prototype-aware falls back to its scope's whole file set. Per
org-agents' own measurements that is 12 seconds narrowed versus "had not finished after nine
minutes" unnarrowed. Prototype agents want `agenda` or an explicit file list, not `all`.

Two smaller notes:

- `:PROTOTYPE:` is **unused in the corpus** (0 occurrences, Check 11) — the name is free.
- If prototypes land, org-agents' table view and format suffix should learn the `*` suffix
  the query language already has: `:AGENT_COLUMNS: ITEM_BY_ID OWNER*` reading
  `(org-entry-get nil "OWNER" t)`. Today a column reads the entry's own drawer only
  (org-agents.el:1916), so an inherited or prototype-supplied value renders as an empty cell.
  This is a one-line change to `org-agents--table-row` and
  `org-agents--format-suffix` and is worth doing regardless of prototypes, since
  `org-use-property-inheritance '("OVERLAY")` already means some values are inherited.

---

## What org-agents itself already provides, and must be reused

Anything built here should treat these as fixed infrastructure, not as things to re-solve:

| Facility | Where | Why a new feature must reuse it |
|---|---|---|
| **The `$PROP` expander** | `org-agents--expand`, :337 | Already handles boolean/value/numeric/name positions and the `*` inherit suffix. A `$PROP` in an action or a color rule should mean the same thing it means in a query. It is pure — no buffer, no eval — so it is testable in isolation. |
| **The safety gate** | `org-agents--gate`, :486 | A query read from a property is code from a file. Any *action* read from a property is code from a file too, and strictly more dangerous. The gate already has structural safety, session approval, sha1-hashed persistent approval, and a batch/`noninteractive` refusal path. Do not build a second approval mechanism. |
| **`org-agents--structurally-safe-p`** | :414 | Extends automatically to new org-ql predicates via `org-ql-predicates`. A new predicate needs no gate change (verified, Check 10). |
| **The splitter and pushdown table** | `org-agents--pushdown-fns`, :672; `org-agents--prefilter-conjuncts`, :753 | Every row states its own superset argument. A new predicate that is *absent* from this table is residual, hence sound, by construction. Adding a row is the dangerous act, and the file's own comment warns against extending it on the old PostgreSQL design doc's arguments. |
| **Dynamic-block plumbing** | `org-dblock-write:org-agents`, §Dynamic block :1860 | `org-prepare-dblock` hands over the previous body as `:content`, so a failing render restores it. Table escaping (`org-agents--table-cell`), row sorts, limit-after-sort, and `:AGENT_COLUMNS`/`ITEM_BY_ID` are all solved. A "displayed attributes" view is a column list in this block, not a new renderer. |
| **The before-save update, and byte-identity** | `org-agents--update-on-save`, :2691; `org-agents--mask-matched`, `org-agents--restore-text` | This is the Edict discipline already implemented: recompute everything, and if nothing changed put the buffer back exactly as it was so the file reaches disk byte-identical. Any recompute-on-occasion feature must join this, not add a second before-save pass. |
| **Scope resolution and the prefilter refusals** | `org-agents--scope-files`, :1496; `org-agents--savable-markers`, :2667 | The rule "a save spawns no subprocess, and an agent whose scope needs a prefilter is named and skipped" is what makes save-time updates affordable. A new feature that needs the corpus must obey it or it will make every save cost a ripgrep run. |
| **The `AGENT_*` vocabulary and reader** | `org-agents--read-agent`, :1351 | Uniform: `org-agents--entry-get` (plain `org-entry-get`, whitespace-trimmed, :1291) then a per-key reader that refuses a bad value with a `user-error` naming the property. New keys (`AGENT_ACTION`, `AGENT_COLOR`, …) should be added here with their own reader, not read ad hoc. |
| **The alias contract** | Commentary, "The alias contract, and its sharp edges" | Pristine aliases are deleted and rewritten every update. **A rule that writes a property onto a pristine alias will have it discarded.** Any action-on-match feature must act on the *match*, not on the alias — or must be documented as needing a body line under the alias to survive. |

---

## Empirical checks

All run with the Emacs above; fixtures in a scratch directory. No file in the repository or
under `~/org` was modified.

### Check 1 — `org-entry-get` does not inherit, at any setting

Fixture: `* Parent` (`:OWNER: alice`) → `** Child` → `*** Grandchild`. Point at `Grandchild`.

| `org-use-property-inheritance` | `(org-entry-get nil "OWNER")` | `… "OWNER" t` | `… "OWNER" 'selective` | `org-entry-properties nil 'standard` has OWNER |
|---|---|---|---|---|
| `nil` | `nil` | `"alice"` | `nil` | `nil` |
| `t` | **`nil`** | `"alice"` | `"alice"` | **`nil`** |
| `"OWNER"` | `nil` | `"alice"` | `"alice"` | `nil` |
| `("OWNER")` | `nil` | `"alice"` | `"alice"` | `nil` |

Confirms the coordinator's measurement. The source line that explains it is org.el:13404-13406:
the variable is consulted only when `inherit` is the symbol `selective`.

Consequence for design: `org-use-property-inheritance` is *not* a global "make properties
inherit" switch. It is a filter that only takes effect for callers that opt in with
`'selective`. Very few do.

### Check 2 — `#+PROPERTY:` and `org-global-properties` reach only the inheriting path

Same fixture, plus `#+PROPERTY: KEYPROP fromkeyword` and
`org-global-properties '(("GLOBALPROP" . "fromglobal"))`.

| Read | Result |
|---|---|
| `(org-entry-get nil "KEYPROP")` | `nil` |
| `(org-entry-get nil "KEYPROP" t)` | `"fromkeyword"` |
| `(org-entry-get nil "GLOBALPROP")` | `nil` |
| `(org-entry-get nil "GLOBALPROP" t)` | `"fromglobal"` |
| `(org-entry-get nil "COLUMNS")` | `nil` |
| `(org-entry-get nil "COLUMNS" t)` | `"%TODO %ITEM %Status %Effort{+}"` |

`org-keyword-properties` was `(("KEYPROP" . "fromkeyword"))`, so the keyword *was* parsed —
it simply is not on the non-inheriting path. Source: `org--property-global-or-keyword-value`
(org.el:13369) is called only from `org-entry-get-with-inheritance` (org.el:13543).

**This is load-bearing.** `#+PROPERTY:` cannot serve as a document-level default layer for
any code that reads properties plainly — which is most code, including org-ql's `property`
predicate and org-agents' table cells.

### Check 2a — a file-level property drawer must be the very first thing in the file

| Fixture | `(org-entry-get nil "ZEROTH")` at a headline | `… t` | `org-data` has it |
|---|---|---|---|
| drawer, then `#+TITLE:` | `nil` | `"v"` | yes |
| `#+TITLE:`, then drawer | `nil` | **`nil`** | **no** |
| `#+TITLE:`, blank line, drawer | `nil` | `nil` | no |

Silent failure. Worth documenting wherever a file-level default is recommended.

### Check 3 — `_ALL` inherits, and falls back to global properties

Fixture: `Status_ALL: active waiting done` on `* Parent` only; `Effort_ALL` only in
`org-global-properties`; point at `*** Grandchild`; `org-use-property-inheritance` nil.

```
allowed values for Status  = ("active" "waiting" "done")
allowed values for Effort  = ("0:05" "0:15" "0:30" "1:00" "2:00")
allowed values for TODO    = ("TODO" "DONE" "")
```

Both inherited. Source: `org-property-get-allowed-values` (org.el:14027) passes `'inherit`,
which is non-nil and not `'selective`, so it always inherits and always falls back to
`#+PROPERTY:` / `org-global-properties`.

### Check 4 — column view changes no bytes

```
columns fmt compiled = (("TODO" "TODO" nil nil nil) ("ITEM" "ITEM" nil nil nil)
                        ("STATUS" "Status" nil nil nil) ("EFFORT" "Effort" nil "+" nil))
buffer bytes changed by org-columns?  nil
number of org-columns overlays:       16
Parent :Effort: after summary =       nil       ; summary NOT written to the drawer
Parent EFFORT overlay display text =  "1      |"
buffer bytes changed after quit?      nil
```

Column view is entirely overlay-driven and the computed summary is displayed, never stored.
(The `{+}` operator is numeric, so `1:00 + 0:30` summed as `1`; `{:}` is the duration
operator. Not a bug — a reminder that the operator carries the type.)

### Check 5 — org-edna works; `org-property-changed-functions` fires only on the API

```
;; :TRIGGER: self set-property!("Status" "closed") set-property!("Hits" inc)   with :Hits: 3
after (org-todo "DONE"):
  Status = "closed"
  Hits   = "4"
  org-property-changed-functions fired with = (("Status" "closed") ("Hits" "4"))
  hand edit of drawer text fired = nil
  (org-entry-put nil "Manual" "x") fired = (("Manual" "x"))

;; TODO -> NEXT (not DONE), same TRIGGER
  Touched = nil     state = "NEXT"
```

Three findings in one: edna's action language works including `inc`; the change hook fires on
`org-entry-put` (so an action's own writes re-enter it — a rule system needs a guard); and
edna is deaf to any state change that is not to a DONE keyword.

### Check 6 — a property can drive a face with zero bytes changed

```elisp
(defun my-matcher (limit)
  (catch 'hit
    (while (re-search-forward org-complex-heading-regexp limit t)
      (let ((c (save-match-data                       ; ← required, see Check 6a
                 (save-excursion (goto-char (line-beginning-position))
                                 (org-entry-get nil "Color")))))
        (when c (setq my-face (intern c)) (throw 'hit t))))
    nil))
(font-lock-add-keywords nil '((my-matcher (4 my-face prepend))) 'append)
```

```
  One    face = (my-color-red org-level-1)
  Two    face = (my-color-blue org-level-1)
  Three  face = org-level-1
bytes changed by fontification = nil
```

### Check 6a — the same matcher without `save-match-data`

```
matcher invocations: 3
  One    face = org-level-1
  Two    face = org-level-1
  Three  face = org-level-1
```

The matcher ran and returned non-nil three times, and font-lock highlighted nothing useful,
because `org-entry-get`'s internal regexp searches had replaced the match data font-lock was
about to consume. Failure is total and silent. Any property-reading font-lock keyword must
wrap the read.

### Check 7 — the overlay route

```
overlay route: 1 overlays; bytes changed = nil
overlay face at One = (my-color-red)
```

Works, applied via `org-map-entries`. Needs explicit invalidation on edit, which font-lock
provides for free — prefer font-lock unless the effect must span a region font-lock does not
control.

### Check 8 — the preamble hazard, measured

A ~15-line `:around` advice on `org-entry-get` resolving `:PROTOTYPE: <id>` to another
heading's drawer. Fixture: `* Book prototype` (`:ID: proto-book`, `:Genre: fiction`) and
`* Great Expectations` (`:PROTOTYPE: proto-book`, `:Status: reading`).

Advice added **before** any query ran (see the caveat below):

```
(property "Genre")                    = ("Book prototype" "Great Expectations")
(property "Genre" "fiction")           = ("Book prototype")            ← MISS
residual (org-entry-get nil "Genre")   = ("Book prototype" "Great Expectations")
```

Isolating the cause with `org-ql-use-preamble`:

```
org-ql-use-preamble = nil
  (property "Genre" "fiction") = ("Book prototype" "Great Expectations")
org-ql-use-preamble = t
  (property "Genre" "fiction") = ("Book prototype")
```

Definitive. The preamble regexp `^\s*:Genre:\s+fiction\s*$` (org-ql.el:1854) pre-filters on
raw text, and the prototype's value is spelled on no line of the file.

And on org-agents' side:

```
(org-agents--prefilter-conjuncts '(and (property "Genre" "fiction")))
  => ((property "Genre" "fiction"))     ; pushed to ripgrep — same failure, one level up
```

**Methodology caveat, worth recording.** A first run of this experiment appeared to show the
advice failing for `(property "Genre")` too. That was an artifact: `org-ql--value-at`
(org-ql.el:654) memoizes per buffer + `buffer-chars-modified-tick` + position + function,
so a control query run *before* the advice was installed poisoned the cache with `nil`, and
the buffer had not been modified in between. Any measurement of this kind must
`clrhash org-ql-node-value-cache` between runs, or install the advice first. Mentioned
because it is exactly the sort of thing that would make an implementation look correct in
testing and wrong in use.

### Check 9 — dynamic allowed values

```elisp
(add-hook 'org-property-allowed-value-functions
          (lambda (prop) (when (equal prop "Owner") '("alice" "bob" ":ETC"))))
```

```
dynamic allowed values for Owner = (#("alice" 0 5 (org-unrestricted t)) "bob")
```

`:ETC` was consumed and the list marked unrestricted, so completion offers the values and
still accepts anything else. This is Org's existing extension point for a computed value set;
nothing needs building for that.

### Check 10 — the sound way to do prototypes

```elisp
(org-ql-defpred property-proto (property &optional value)
  "Property, resolved through :PROTOTYPE:."
  :body (let ((v (proto-get property)))
          (and v (or (null value) (string-equal v value)))))
```

```
(property-proto "Genre")            = ("Book prototype" "Great Expectations")
(property-proto "Genre" "fiction")  = ("Book prototype" "Great Expectations")

org-agents--structurally-safe-p '(and (level 1) (property-proto "Genre" "fiction"))  => t
org-agents--prefilter-conjuncts '(and (property-proto "Genre" "fiction"))            => nil
org-agents--prefilter-conjuncts '(and (property "Genre" "fiction"))                  => ((property "Genre" "fiction"))
```

Correct with and without a value; accepted by org-agents' gate with no change to org-agents;
residual in the prefilter by construction. This is the design.

### Check 11 — what the corpus actually contains

Read-only ripgrep over `~/org`, `*.org`:

- **137 distinct property names** (excluding `PROPERTIES`/`END`/`LOGBOOK`/`CLOCK`).
- Top by count: `ID` 36,991 · `CREATED` 36,950 · `MODIFIED` 33,147 ·
  `HASH_SHA512_256` 33,147 · `ARCHIVE_TIME` 21,572 · `ARCHIVE_CATEGORY` 21,476 ·
  `LOCATION` 7,814 · `LAST_REVIEW` 6,039 · `NEXT_REVIEW` 5,404 · `REVIEWS` 4,424 ·
  `MESSAGE` 4,418 · `DATE` 3,854 · `CUSTOM_ID` 3,564 · `AUTHOR` 3,426 · `URL` 2,234 ·
  `PROJECT` 1,791 · `BILLCODE` 1,788 · `SLUG` 1,398 · `TASKCODE` 1,283 · `CONFIDENCE` 273.
- `:BLOCKER:` **31** · `:TRIGGER:` **0** · `:COLUMNS:` **1** · `#+COLUMNS:` **0** ·
  `#+PROPERTY:` **0** · `:OVERLAY:` 38 · `:AGENT_QUERY:` 3 · `:PROTOTYPE:` **0**.
- `_ALL` declarations anywhere: 4 (3 × `TAGS_ALL`, 1 × `VERB_ALL`).

Reading of that: the facilities that answer Concepts 1–3 are configured and almost entirely
unused. `org-columns-default-format` is set and column view is used once. org-edna is enabled
and only its blocking half is used. That reframes the exercise — for displayed attributes and
declared value sets, the deliverable is more likely a set of worked examples plus corpus-wide
scope than new machinery.

### Check 12 — corpus-wide column view already works over an org-ql query

`org-ql-search` produces an `org-agenda-mode` buffer carrying `org-hd-marker` text
properties, and `org-agenda-columns` runs in it:

```
ql buffer major-mode = org-agenda-mode
org-hd-marker present: t
org-agenda-columns in org-ql-view: OK, 4 overlays
```

The format came from the matched entry's inherited `:COLUMNS:`
(`%TODO %ITEM %Status %Effort{+}`) via the `(org-entry-get m "COLUMNS" t)` branch at
org-colview.el:1769 — so per-class displayed-attribute sets already work corpus-wide. Editing
in that view goes through `org-columns-edit-value` (org-colview.el:647), which acts through
`org-hd-marker`, i.e. writes into the source file.

**Try this before building a table renderer.** Caveat below.

---

## Uncertain

- **UNCERTAIN: aggregate roll-up in an org-ql-view column view.**
  `org-agenda-colview-summarize` (org-colview.el:1819) writes summaries only onto lines
  carrying the `org-date-line` text property or the `org-agenda-structure` face. An
  `org-ql-search` buffer has neither for its result lines, so a whole-result total probably
  does not appear even though per-entry values do. *Settled by:* running
  `org-agenda-columns` interactively in an `org-ql-search` buffer with a `{+}` column and
  looking for a total, or by reading whether `org-ql-view` sets `org-date-line` anywhere.
- **UNCERTAIN: whether `org-ql-defpred` predicates survive org-ql's query cache across a
  redefinition.** `org-ql-cache` is keyed on buffer and query; redefining a predicate does not
  obviously invalidate it. Matters for development ergonomics, not for correctness in use.
  *Settled by:* redefining a predicate's body and re-running the same query without clearing
  `org-ql-cache`.
- **UNCERTAIN: cost of a preamble-free prototype predicate at corpus scale.** All the
  prototype measurements here are on a two-heading fixture. org-agents' Commentary gives the
  order of magnitude for an unnarrowed corpus walk (nine minutes, unfinished), but not for a
  predicate that additionally does an ID lookup per entry. *Settled by:* one timed
  `org-ql-select` with a `property-proto` conjunct over `agenda` scope on the real corpus.
- **UNCERTAIN: whether `org-property-changed-functions` is a usable rule trigger in practice.**
  It fires on `org-entry-put`, including from within an action, so a naive rule set can
  re-enter. Whether a depth guard is sufficient, or whether the hook is simply too partial to
  build on given it misses hand edits, is a judgement I have not tested at scale.
  *Settled by:* instrumenting the hook for a week of ordinary use and counting how many real
  property changes it sees versus how many the file's diffs show.

## Incidental finding, offered because it is cheap to fix

Five `:BLOCKER:` values in the corpus are bare UUIDs — **org-depend** syntax, not org-edna
syntax. org-depend is not installed in this environment (`locate-library` → nil), while
`org-depend-tag-blocked` is still set at `~/org/init.org:11063`. org-edna is what actually
reads `:BLOCKER:`, and it cannot parse a bare UUID:

```
Org Edna Syntax Error: Unrecognized Form
0B5B5396-3C92-45DE-8E17-D3E8D54CAB8E
^
TODO state change from TODO to DONE blocked (by "TODO Blocked the org-depend way")
state after = "TODO"
```

Those headings are permanently un-DONE-able. The fix is to rewrite them as
`ids(id:UUID)`. Not part of this exercise; reported because it surfaced while establishing
what the environment does.

## Fixtures

Left in the scratch directory, not in the repository:
`/private/tmp/claude-501/-Users-johnw-src-dot-emacs-lisp/f9adf1d3-f99f-4961-a238-65a63ba0fb2c/scratchpad/fix/`
(`proto.org`, `books.org`, `t1.el`–`t18.el`).
