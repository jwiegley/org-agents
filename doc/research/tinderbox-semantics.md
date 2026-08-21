# Tinderbox's Dynamic-Property Concepts: Actual Semantics

Research for a design conversation about extending `org-agents`. Agent A of 3.
Source of authority: `/Users/johnw/Desktop/tbxman920.txt` — the Tinderbox v9.2
manual (109 pages, 5682 lines in the text extraction). All line numbers below
refer to that file; every claim also carries a distinctive phrase to grep for,
so nothing here has to be taken on trust.

Nothing has been agreed or built. This document says what Tinderbox does, then
argues about what should and should not cross over into Org.

---

## 0. What this source is, and where it runs out

This is Tinderbox's *built-in Help*, not `aTbRef`. It is generous about
concepts and stingy about scheduling. Three consequences worth stating before
anything else:

1. **There is no "Rules" section.** Rules appear only inside "Queries and
   Actions ▸ Actions, Expressions, and Rules" (line 2796) and in passing
   examples. The manual never states the rule interval, the evaluation order
   among notes, or what happens when two triggers write the same attribute.
2. **Where the manual does give numbers, it hedges.** Edicts: "at present,
   edicts run at startup and then at intervals of approximately one hour,
   though these details are subject to change" (line 2906).
3. **Some of the sharpest facts are in the Release Notes, not the body.** The
   agent-priority intervals (line 5357), `createAttribute()` (line 4981), and
   `attribute(name)[default]=` (line 5395) are all release-note material.

I flag UNCERTAIN wherever the manual is silent, and say what would settle it.
The manual itself points at the deeper reference: "aTbRef (A Tinderbox
Reference), a comprehensive reference to Tinderbox" (line 1181, section
"Learning More").

One structural fact governs everything that follows, and it is the deepest
difference from Org. In Tinderbox a note *is* its attribute list:

> "Internally, a note is a long list of attributes and values." (line 995,
> section "Anatomy Of A Note")

> "Whenever you rename, edit, or change a note in Tinderbox, you are actually
> changing the value of one or more attributes of that note." (line 1332,
> section "Attributes")

`$Name` is a String attribute; `$Text` is an attribute. The title and the body
are cells in the same table as the colour and the width. Every view — map,
outline, timeline, attribute browser — is a projection of that table, and
action code can rewrite any cell. In Org the *text is the artifact* and
properties are annotations living inside it. That inversion, not any individual
feature, is what most of the translation questions come down to.

---

## 1. System Attributes

### What it is

Several hundred built-in attributes that Tinderbox keeps for every note and
gives special meaning to.

> "Tinderbox has several hundred built-in system attributes which have special
> meaning to the system. You can also add your own user attributes. If we need
> to distinguish between the name of an attribute and something else, we place
> a '$' before the attribute name: 'Name' is a word, and $Name is an
> attribute." (line 1002, section "Anatomy Of A Note")

> "System attributes: information built into all Tinderbox documents such as
> the color of the note, or its width and height. Tinderbox keeps this
> information about every note, and you may view, use, and change it." (line
> 1337, section "Attributes")

The category is not homogeneous. It bundles at least four different kinds of
thing, and they translate very differently:

| Kind | Examples | Writable? |
|---|---|---|
| Content | `$Name`, `$Text`, `$Subtitle`, `$Caption`, `$URL` | yes |
| Appearance | `$Color`, `$BorderColor`, `$Width`, `$Height`, `$Badge`, `$Shape`, `$Pattern`, `$Opacity`, `$Flags` | yes |
| Geometry / structure | `$Xpos`, `$Ypos`, `$Container`, `$ID`, `$OutlineOrder` | mostly yes, some read-only |
| Derived facts | `$Created`, `$Modified`, `$Creator`, `$TextLength`, `$WordCount`, `$ChildCount`, `$InboundLinkCount`, `$OutlineDepth`, `$SiblingOrder` | **no** |
| Behaviour (Action type) | `$Rule`, `$Edict`, `$OnAdd`, `$AgentQuery`, `$AgentAction`, `$DisplayExpression`, `$HoverExpression`, `$TableExpression`, `$OnJoin` | yes |

That last row is the important one. Behaviour is stored in attributes:

> "The Action data type is only used internally. $AgentAction,
> $DisplayExpression, $OnAdd, $Rule and $TableExpression are all Action type
> attributes. These attribute all hold strings of Tinderbox action code and are
> evaluated as such when used." (line 1455, section "Attribute types")

Read-only attributes are explicitly carved out:

> "Read-only attributes: information such as the date and time the note was
> created… Other read-only attributes, such as TextLength and ChildCount,
> describe properties derived from the document's current state and are
> inherently read-only. Tinderbox keeps this information about every note, and
> you may view and use it, but you cannot change it." (line 1342)

### When it evaluates

System attributes are stored values, not evaluated things — with two
exceptions. Derived read-only attributes are recomputed by the application
whenever the underlying state changes (mechanism undocumented; UNCERTAIN
whether they are eager or lazy). Action-type system attributes are evaluated
according to the trigger they belong to; see §3.

### What it can touch

Nothing on its own. System attributes are the *target* of action code, and the
*source* for queries and display expressions.

### Inheritance

System attributes inherit from prototypes exactly like user attributes, minus
two exclusions:

> "A few attributes are intrinsic. Aliases have their own values of intrinsic
> attributes. Intrinsic attributes are never inherited from prototypes…
> Other intrinsic attributes include $Height, Width, $ID, $Container, $Created,
> $Modified, $Creator, $RuleDisabled, $DisplayExpressionDisabled,
> $IsPrototype, $Flags, $MapScrollX, $MapScrollY, $TimelineBand, and
> $AgentPriority." (line 1560, section "Intrinsic Attributes")

Read-only attributes are likewise not inherited (line 1785, section "User
Prototypes", lists "Readonly attributes" among the exceptions when importing a
prototype).

Note `$RuleDisabled` in that list. It is mentioned exactly once in the whole
manual — but it is the escape hatch that makes rules survivable: a per-note,
never-inherited switch that turns off an inherited rule for one note.

### Type system

See §5 — the type system is shared with user attributes.

### Defaults are per-document and settable

> "The default value of an attribute is the value Tinderbox uses if no specific
> value has been set for that note. The System Attributes panel of the Document
> Inspector lets you change the default value of attributes. If you set the
> default value of Color to red, then all newly-created notes will be red, and
> all notes for which no specific color was chosen will also become red." (line
> 1358, section "To change an attribute's default value")

Action code can change defaults at runtime:

> "attribute(attributeName)[suggested]="value 1; value 2";
> attribute(attributeName)[default]="value 1";" (line 4396, section "Attribute
> Operators"; also line 5395 in the release notes: "Actions may now modify the
> default value and suggested values of an attribute.")

---

## 2. User Attributes

### What it is

Custom, document-scoped attributes that every note in the document then has.

> "User attributes: you may add your own attributes that every note will have.
> For instance, you could add the attribute 'Priority,' and assign every note a
> priority level from one to five." (line 1340, section "Attributes")

> "You can add your own user attributes to any Tinderbox document. To define a
> new attribute, open the Document Inspector and switch to the User pane… The
> inspector lets you choose to type of attribute – some of the choice included
> number, string, URL, or list – and set the default value that the attribute
> should use. A text field labeled 'Description' invites you to write a brief
> explanation of the way you intend to use the new attribute." (line 1529,
> section "User Attributes")

So a user attribute has a **declaration**: name, type, default value,
suggested values, description, and a group/category (line 5033: "The System
Attribute pane of the Document Inspector now refers to attribute 'Group' rather
than attribute 'Category'"). That declaration is a first-class object in the
document, queryable by action code:

> "attribute("Width").at("default") / attribute("Width")[suggested] /
> attribute("Width").at("category") / attribute("Width").at("type") /
> attribute("Width").at("description")" (line 4386, section "Attribute
> Operators")

> "document[user-attributes] returns a list of user attributes available in
> this document." (line 4385)

Suggested values are a controlled vocabulary, not a constraint:

> "The attribute inspectors also allow you to add suggested values; these
> values will be available in menus even if they are not currently used in the
> document. Suggested values can be useful when an attribute's vocabulary
> should be limited -- for example, the anticipated values of $Status might be
> 'planned;in progress;overdue;completed'" (line 1468, section "Suggested
> Values")

Nothing enforces them. They populate menus and autocomplete (lines 1494–1503).

### When it evaluates

Never. They are storage. The declaration is consulted at lookup time to supply
the default.

### Creation is cheap, and the manual insists on it

> "You don't have to define Tinderbox attributes before you begin making and
> using notes. Tinderbox is designed to encourage experimentation and
> evolutionary change in your work. As your needs change and your understanding
> grows, you can add, change, and delete attributes whenever you like." (line
> 1329)

> "Over time, you may create new attributes to describe them and new agents and
> actions to take advantage of those attributes." (line 1060, section
> "Discovering Emergent Structure")

Attributes can be created by action code, `createAttribute(name[, type])` (line
4981), and are created *implicitly* by importing a spreadsheet:

> "The first row is treated as a set of headings, which map to attributes. New
> user attributes will be created for attributes that do not already exist."
> (line 4478, section "Spreadsheets and Comma-Separated Value Files")

### The failure mode of a document-scoped registry

Because the registry is per-document, code that refers to an attribute the
document has not declared silently does nothing:

> "If the stamp action refers to user attributes that don't exist in the new
> document, those actions will have no effect until the attribute is defined."
> (line 1858, section "Inspect Stamps")

And prototypes imported across documents drop values for undeclared attributes
(line 1782, section "User Prototypes": "User attributes that do not exist in
your document").

### Inheritance

Identical to system attributes: local → prototype chain → declared default.
See §4.

---

## 3. Action Code

This is the crux, and the part every summary gets wrong. There are not "code
snippets in rules and agents". There are **seven distinct evaluation triggers**
plus a family of display-time expressions, and they differ in *when*, *how
often*, *what `this` is bound to*, and *whether the result is stored*.

### 3.1 What it is

A small imperative expression language. Assignment, sequencing with `;`,
`if`/`else`, local variables with optional types, user-defined functions,
iteration over lists, regex with back-references, string/list/set/dictionary
operators, date and interval arithmetic, and a shell escape.

> "An expression is simply something that has a value… An action describes a
> change made on one or more notes. For example, the action
> $Color(California)="red" sets the color of the note named 'California' to
> 'red'." (line 2793, section "Actions, Expressions, and Rules")

Key primitives, with locations:

- Assignment and sequencing: `$Color="red";$BorderColor="white";` (line 2850)
- **Unset**: `$Color=;` — "To remove the value from the current note, restoring
  the inherited or default value, simply omit the value the follows the '='
  sign." (line 2853)
- **Conditional assignment**: `|=` assigns "only if that attribute's value is
  currently false, zero, or empty"; `&=` assigns "only if that attribute's
  value is not false, zero, or empty" (lines 2855–2859)
- `+=` / `-=`, also for lists, sets, and string append (line 2860)
- `if(cond){…} else {…}` (line 2874)
- Bare expressions as side effects: `runCommand("open /Applications/iTunes.app")`,
  `notify("find concert tickets")` (line 2881, section "Side Effects")
- `var x:number(5)` with types number/set/list/date/color/interval/dictionary
  (line 3165, section "Local Variables")
- `function fname(args){action}`, recursive, defined in notes under
  `/Hints/Library` (line 3178, section "Functions")
- Comments with `//`, terminated by the next `//`, newline, or end (line 2805)

### 3.2 When it evaluates — the seven triggers

The manual's own statement of the core three:

> "Actions may be performed at a variety of times.
> An OnAdd action is performed when a note is added to a container, is
> discovered by an agent, or is placed atop an adornment, and affects the note
> being added.
> A Rule is performed at frequent intervals, and affects the note that
> possesses the rule.
> An Edict is performed after a document is opened, and at infrequent intervals
> while the document remains open." (lines 2796–2801, section "Actions,
> Expressions, and Rules")

Rules are described elsewhere only by example:

> "Each note can also have a list of Rules – actions that are automatically
> applied to the note at all times. For example: if a Task is marked as
> complete, it might automatically move itself into the container for Completed
> Tasks." (line 1052, section "Active Notes")

Edicts get a rationale that is really an argument about cost:

> "You could use a rule, inherited from the Task prototype, to perform these
> chores. Each morning, you'd open the document, Tinderbox would review each
> task in turn, and then adjust the appearance of each task… Once done, though,
> Tinderbox's rule manager would then check each Task again, just in case a
> task had changed status since the previous check. This does no particular
> harm, but it does use a little extra processing power and consume some battery
> charge, while the benefit of checking whether a task has suddenly become
> overdue in the previous minute is slight." (line 2897, section "Edicts")

> "Edicts run infrequently, and so they consume less processing power and
> battery charge. (At present, edicts run at startup and then at intervals of
> approximately one hour, though these details are subject to change.)" (line
> 2906)

That paragraph is the single most useful passage in the manual for our
purposes. It says out loud that a Rule is a *polling loop over the whole
document*, that its correctness story is "re-check everything, forever", and
that the only reason to reach for an Edict instead is battery. Edicts are not
a different semantics; they are a different *sampling rate on the same polling
loop*.

Agents have their own rate, per-agent, from `$AgentPriority`:

> "AgentPriority — The agent's relative priority, controlling how frequently
> the agent updates itself." (line 2547, section "Agents")

> "Tinderbox provides better control of agent priority. Highest priority agents
> run every few seconds. Normal priority agents are updated at approximately
> ten second intervals. Low priority agents are updated every minute. Lowest
> priority agents are updated every five minutes. Occasional agents are updated
> every hour." (lines 5357–5362, Release Notes 9.0)

Agents can also be switched off entirely — "If an agent is turned off, it's
title bar is hollow" (line 2291, section "The Outline Icon").

Stamps are the manual trigger, and the manual is explicit about why they exist:

> "Stamps apply a Tinderbox action to the currently-selected notes. Stamps are
> valuable for actions that you may want to do frequently, but that aren't
> suitable for automatic application through agents or OnAdd actions." (line
> 1849, section "Inspect Stamps")

Stamps are named, live in a menu, may be nested one level by `menu:name`, may
be stored as notes in `/Hints/Stamps` with the action in the note's text
(line 1596, section "The Stamps Container"), may be hidden from the menu by a
leading period, and may be invoked from action code: `stamp(designator,
stampName)` / `stamp(markAsComplete)` (line 4324).

There is also an explicit force-evaluation operator:

> "update(notes) asks Tinderbox to update one or more notes by evaluating their
> rule and edict. Notes may be an individual or group designator, or a list of
> paths. **If the note has been evaluated recently, Tinderbox will not evaluate
> it again.** update() returns a list of updated notes." (line 4301, section
> "Eval(), Action(), and Update"; emphasis mine)

That recency guard is direct evidence of a dirty/throttle mechanism the manual
otherwise never describes.

And a family of **display-time expressions that are evaluated but never
stored** — the most portable idea in the whole concept:

> "The $DisplayExpression attribute lets you change the note's label without
> changing the value of its $Name… Whenever Tinderbox needs to display the
> note, it evaluates the note's $DisplayExpression and displays the result."
> (line 2139, section "Display Expression")

Likewise `$HoverExpression` (line 2155) and `$TableExpression` for a
container's summary table (line 2198). And `$AgentQuery` itself: "$AgentQuery
is an expression; if the $AgentQuery is true for a given note, then that note
will be listed by the agent." (line 2827).

Two further triggers round out the set: `$OnJoin`, fired when a note is dragged
into contact with another note in a map composite (line 2635, section
"Composite Actions"), and smart-adornment queries+actions, which *physically
move* matching notes onto the adornment (line 2043, section "Smart
Adornments"). Also: function-definition notes in `/Hints/Library` are
"executed at document startup and after they are edited" (line 3181).

### 3.3 Binding of `this` — precise, and it matters

> "In rules, this refers to the note whose rule is running.
> In agent queries, this refers to the note being examined by the agent.
> In agent actions, this refers to the **newly-created alias** that satisfies
> the agent's query.
> In OnAdd actions, this refers to the note that is being added." (lines
> 2948–2951, section "Designators"; emphasis mine)

Other designators: `agent` ("Available only in agent queries and agent
actions"), `adornment`, `original` ("In aliases, refers to the original note
associated with the alias"), and `that` (inside `find()`, `this` is the note
being tested and `that` is what `this` was outside). (Lines 3025–3033.)

The alias binding in agent actions is a genuine trap, and Tinderbox needs a
whole parallel operator family because of it. An alias is a live proxy:

> "The attribute values of an alias are almost always identical to the values
> of the original note. For example, the $Color of an alias is the color of the
> original. If you make the original note red, the alias will be red; if you
> make the alias green, the original note will also be green." (line 1553,
> section "Aliases and The Original Note")

So writes to *non-intrinsic* attributes through the alias reach the original,
while writes to *intrinsic* attributes (`$Xpos`, `$Height`, `$Container`,
`$Created`, …) stay on the alias. Hence:

> "In agent actions, this is the alias of the note being added to the agent.
> Often, you want to add links to the original note, not the alias. The
> operators linkToOriginal(target [,linkType]) … operate identically, but if
> either the source or the destination are aliases, the link is created or
> removed from the original note." (line 4222, section "Making Links")

And `originalLinkedTo()` / `originalLinkedFrom()`: "especially useful in
agents, where one often is interested in the links of the original note rather
than any links to the note owned by the agent" (line 4200).

### 3.4 What it can touch

Very nearly everything in the document, plus the operating system.

**Other notes — by name, path, ID, or relation.**

> "To refer to the value of an attribute of a different note, follow the
> attribute name with a designator in parentheses. For example, $Width(parent)…
> $Width(Burbank) refers to the width of the note named 'Burbank', and
> $Width(/people/Roosevelt)…" (line 2915, section "Attribute References")

Designators include `next`, `previous`, `prevSibling`, `nextSibling`,
`firstSibling`, `lastSibling`, `parent`, `grandparent`, `child`, `child[n]`,
`lastChild`, `randomChild`, `cover` (the first note in the document), `source`,
`destination`, and a raw `$ID` (lines 2954–3020). "Designators may be combined.
For example, $Name(nextSibling(parent))" (line 3020).

**Whole groups at once.**

> "Group designators can be used to assign a value to many notes at one time.
> $Color(children)="red"" (line 3064, section "Group Designators")

Groups: `children`, `descendants`, `siblings`, `ancestors`, **`all`** — "all
notes in the document" (line 3062). And a list of paths works anywhere a group
does.

**The entire document, by query, from inside a rule.**

> "The special designator find() searches through the entire Tinderbox document
> to locate notes that satisfy an expression. For example:
> $Color( find($Status="Urgent"))="red" will locate every note whose $Status is
> 'Urgent' and turn is red." (line 3068, section "find()")

Read that again with §3.2 in mind: that is a whole-document read-modify-write,
and if it sits in a `$Rule` it re-executes every few seconds, forever. The
manual's only comment is a performance nudge: "In general, prefer agents to
using find(), because the agent's results can be reused by other agents" (line
3072).

**Create notes.** `create(path)` (lines 3970, 5169). `1...10.each(x){ var
path="/container/item "+x; create(path);}` (line 3970).

**Move notes.** Documented only obliquely: a rule that "might automatically
move itself into the container for Completed Tasks" (line 1053); a release-note
fix for "a crash when an agent action tried to move a note to a new container"
(line 4999); smart adornments that move matching notes (line 2043). The
mechanism is presumably assignment to `$Container`. UNCERTAIN — the manual
never shows the syntax.

**Delete notes.** Not documented as an action-code operator anywhere in this
manual. AppleScript has `delete myNote` and `move myNote to theContainer` (line
4890). UNCERTAIN whether action code can delete; would be settled by aTbRef's
operator index.

**Create and redefine attributes.** `createAttribute(name[,type])` (line 4981);
`attribute(name)[default]=` and `[suggested]=` (line 4396).

**Links.** `linkTo`, `unlinkTo`, `linkFrom`, `unlinkFrom`, `createLink`, plus
the `…Original` variants; `eachLink(x){…}` (lines 4212–4231).

**The operating system.** `runCommand(command_line, input)` — "asks the
operating system to start a new process and results the result of that
process"; usable bare, and explicitly sanctioned inside rules: "If
$CommandValue holds a valid command line string, this can be used in a rule or
action: runCommand($CommandValue)" (line 4328). Plus `notify()` to Notification
Center and `.speak()` (lines 4306–4316).

**Read and write the same attribute.** Yes, freely: `$MyNumber += 3` (line
2860); `$Result=0; $MyList.each(x){$Result=Result+x;}` (line 2886).

### 3.5 The unwritten rule: actions attached to continuous triggers must be idempotent

The manual never says this. It is nevertheless the load-bearing invariant, and
the evidence is in the design of the operators rather than in the prose.

`$MyNumber += 1` in a `$Rule` is a counter that increments a few times a second
until the document is closed. Nothing prevents it and nothing warns about it.
Every rule example in the manual is idempotent by construction:

- `if($DueDate<date("tomorrow")) {$Color="red";}` (line 2874) — assignment to a
  fixed value, converges immediately.
- `Rule: if($Checked) {linkFrom(/agenda/today/tasks,"urgent!")}` with the
  explicit gloss: "This rule will insure that an 'urgent!' link runs from the
  note 'tasks' in today's agenda; **if the link already exists, the action has
  no effect**." (line 4220, emphasis mine)
- `linkTo`/`unlinkTo` are specified to be no-ops when there is nothing to do
  (line 4218).
- `|=` and `&=` exist precisely so that an action can be written to fire once
  and then stop mattering (line 2855).
- `update()` refuses to re-evaluate a recently-evaluated note (line 4301).

So Tinderbox's answer to "a rule runs forever" is: make the primitives
idempotent and let convergence do the rest. That works when re-running is free.
It is the assumption that breaks hardest in translation, because in a
plain-text, version-controlled corpus re-running is never free — it costs a
diff.

### 3.6 Conflicts — undocumented, and this is a real gap

The manual nowhere states what happens when a Rule, an Edict, an OnAdd action,
an agent action, and a Stamp all write `$Color` on the same note.

What can be inferred with confidence from documented facts:

- All of them are plain assignment into the same cell, so within a single pass
  it is last-writer-wins.
- A Rule runs "at frequent intervals" while OnAdd fires once and a Stamp fires
  on demand, so **over time a Rule always wins.** Any attribute a Rule assigns
  unconditionally is not hand-editable: the user's edit survives until the next
  rule pass, i.e. seconds.
- `$RuleDisabled` (line 1562) exists as the per-note, never-inherited opt-out,
  which is the only documented mechanism for reclaiming an attribute from an
  inherited rule.
- Agent actions write through the alias proxy (§3.3), so an agent action and a
  rule on the original are contending for the same cell by two different paths.

UNCERTAIN, and worth settling before designing anything that mimics rules.
Settled by experiment in Tinderbox: give a prototype a `$Rule` of
`$Color="red"`, an `$OnAdd` on the container of `$Color="blue"`, and a stamp of
`$Color="green"`; apply the stamp and watch how long green lasts. Also settled
by aTbRef's pages on `$Rule` and on evaluation order.

---

## 4. Prototypes

### What it is

An ordinary note designated as a prototype; other notes point at it and inherit
its attribute values.

> "Often, the easiest way to describe a note is to explain how it differs from
> another note. We say that the first note serves as the prototype of the
> second: it shares all the properties of the prototype, except where we
> specify otherwise." (line 1683, section "Prototypes")

> "Any Tinderbox note can serve as a prototype for other notes. Prototypes let
> you specify the default value for an entire class of notes. Whenever
> Tinderbox checks an attribute that you haven't specifically set, it will use
> the value from the prototype. Change an attribute in a prototype, and you
> change it for the notes that use that prototype." (line 1690)

> "Prototypes often establish the type or nature of a note. Notes about books
> might all share the prototype Book, and notes about people might all share
> the prototype Person." (line 1027, section "Inheritance")

Marked by the intrinsic boolean `$IsPrototype` (line 1562), set via a checkbox
(line 1701), and shown in outline view by "a light green circle" round the icon
(line 1697). The prototype relation is implemented as a *link* in the object
graph — a "prototype link", which every link operator and the hyperbolic view
explicitly exclude (lines 4183, 2440, 4231).

### When it evaluates

**At every attribute lookup, lazily.** This is the essential point. Prototypes
are not a copy-on-create template; they are a resolution rule consulted every
time a value is read. That is why changing a prototype changes every instance
retroactively (line 1690, and the worked example at lines 1754–1761).

There is exactly one carve-out, and it is instructive — see §4.4.

### 4.1 How inheritance resolves — the manual's own checklist

> "Whenever Tinderbox looks up the value of an attribute, it reviews the
> following checklist:
> If the note has a value for that attribute, that's the value.
> Otherwise,
> If the note has a prototype, and if the prototype has a value, then we
> inherit the prototype's value.
> Otherwise,
> If the prototype itself has a prototype, we inherit that value.
> Otherwise,
> We use the default value for that attribute." (lines 1739–1748, section
> "Inheritance")

So: **local → prototype → prototype's prototype → … → the attribute's declared
default.** Unbounded chaining. Single inheritance only:

> "A note can only have one prototype, but each prototype can be used by many
> different notes." (line 1722, section "Using Prototypes")

And, critically for the port, the axis is *not* containment:

> "Note that inheritance has nothing to do with the document hierarchy; a
> note's prototype is not necessarily its container. For example, Oliver Twist
> and Great Expectations might be two notes in a document. Each has the
> prototype 'Book'. One is inside the container 'Living Room Books,' the other
> is inside 'Books I've lent to friends.'" (line 1751)

Tinderbox is deliberately separating "where does this note live" from "what
kind of note is this". Org, out of the box, has only the first axis.

### 4.2 Local values always win, and the manual works the example

> "A note's own values always override inheritance. For example, suppose that
> note Prototypical Task is gray. We create a new note called Today's Meeting
> that inherits from Prototypical Task. Initially, Today's Meeting inherits
> everything from its prototype, so it's gray, too. But if we set the Color of
> Today's Meeting to blue, it turns blue. Other tasks remain gray. Now, we make
> yet another note, Conference Call, which also inherits from Prototypical
> Task. It, too, is gray… But perhaps we'd like all tasks to be green; we change
> the Color of Prototypical Task to green. Now, Conference Call turns green,
> because it inherits its Color from the prototype. Today's Meeting remains
> blue, because you gave it a specific color; a note's own values always take
> precedence over inheritance." (lines 1754–1761)

### 4.3 Behaviour is inherited *because behaviour is stored in an attribute*

This is the most elegant thing in Tinderbox's design and the manual barely
remarks on it. There is no separate mechanism for inheriting actions. `$Rule`,
`$OnAdd`, `$AgentQuery`, `$DisplayExpression`, `$HoverExpression`,
`$TableExpression` are Action-type attributes (line 1455), so they inherit by
the same checklist as `$Color`. Confirmations scattered through the manual:

> "You could use a rule, inherited from the Task prototype, to perform these
> chores." (line 2897)

> "A note may have its own hover expression, but often will inherit hover
> expression from a prototype." (line 2161)

> "Notes often inherit displayed attributes from their prototype." (line 1490)

> "Notes opt-in to highlighters, either individually or by inheriting a
> highlighter from their [prototype]" (line 5302)

> "grid properties are controlled by corresponding attributes, such as
> $GridColumns… Thus, grid properties may be inherited from prototypes or
> altered by rules or actions." (line 2024)

So a prototype passes down *both* values and behaviours, with no additional
machinery, purely because the behaviours are values.

### 4.4 Children are the one exception, and it is snapshot semantics

> "If a prototype is a container, then notes that use the prototype will
> 'inherit' copies of the prototype's children… Note that these 'inherited'
> notes are created at the time the prototype is assigned; adding or removing
> children to the prototype at some later time will not affect notes that
> already use the prototype." (lines 1727–1731, section "Children of
> Prototypes")

Controlled by `$PrototypeBequeathsChildren` (line 1732).

Tinderbox itself abandoned live semantics at exactly the point where the thing
inherited stopped being a *value* and became *content*. That is not an
accident, and it is the most useful single data point for the Org port, where
everything is content.

### 4.5 How inherited is distinguished from local — this is the subtle bit

Tinderbox represents it in three places, all consistent: a note either holds a
local value for an attribute, or it does not.

**In the data model.** The lookup checklist (§4.1) only makes sense if
"the note has a value" is a decidable predicate distinct from "the note's
resolved value is X".

**In the UI.**

> "You can inspect and change the value of any attribute in a note's Get
> Info... window… **Inherited values are in gray; values set specifically for
> this note are in black, and read-only values are italicized.**" (line 1348,
> section "Attributes"; emphasis mine)

And the way back:

> "To remove the value from the current note, restoring the inherited or default
> value, simply omit the value the follows the '=' sign. $Color=;" (line 2853)

> "In the displayed attributes table, the values pulldown menu handled 'normal'
> incorrectly. 'Normal' now restores the inherited or default value." (line
> 5582, Release Notes)

AppleScript: "delete value of (attribute of myNote named "Width") removes any
local value assigned to that attribute, restoring the inherited or default
value." (line 4877)

**In action code**, with an editorial sting in the tail:

> "The operator hasLocalValue() lets you determine whether a note has a specific
> value for an attribute, or whether that value is inherited from a prototype or
> a default. hasLocalValue("attributeName" [,target] )… **You will rarely if
> ever need to know whether a value is set locally or inherited. Wanting this
> information is often a sign that your overall design is incorrect!**" (lines
> 4388–4397, section "hasLocalValue"; emphasis mine)

Also `inheritsFrom(prototype)` / `inheritsFrom(which, prototype)`, which
"checks whether a note uses a specific note as a prototype, either directly or
through other prototypes" (line 4366).

That warning is worth dwelling on, because it *inverts* on translation. In
Tinderbox the local/inherited distinction is an implementation detail the user
should not need — the resolved value is the truth, and the store is invisible.
In Org the store *is* the document: the user reads the drawer. There, the
distinction is not a leak, it is the primary readable fact. §6 returns to this.

### 4.6 Built-in and user prototypes

Tinderbox ships specimen prototypes (`File ▸ Built-In Prototypes`), which land
in a root container named `Prototypes` (line 1765). Users can maintain their
own library at
`~/Library/Application Support/Tinderbox/prototypes/Prototypes.tbx` (line 1774).
Importing one drops values for user attributes the target document does not
declare, intrinsic attributes, and read-only attributes (lines 1781–1785).
Notable: a prototype library is *a document of notes*, not a config file — the
same substrate all the way down.

---

## 5. The attribute type system

### The types

From "Attribute types" (line 1369) onward:

| Type | Notes | Example |
|---|---|---|
| String | "Any sequence of text." | `$Name` |
| color | named / `#A482BF` / `HSV(0,100,50)` / `rgb(0,0,0)`; all stored as 6-digit hex | `$BorderColor` |
| File | "The pathname to a file." | `$File` |
| Boolean | true/false, unquoted keywords, case-sensitive | `$HideDisplayedAttributes` |
| Date | date+time; accepts `today`, `today - 7 days`, `Wednesday`; locale-dependent parsing, locale-independent storage | `$Created` |
| Interval | `03:16`, `3h30`, `7 days 03:15:00` | — |
| Number | int or float, signed | `$ChildCount` |
| List | semicolon-separated, ordered, sortable, duplicates allowed | `$TimeLineBandLabels` |
| Set | semicolon-separated, unordered, deduplicating, **not sortable** | `$KeyAttributes` |
| URL | string plus UI affordance (globe icon) | — |
| Action | **"System use only"**; holds action-code strings | `$Rule`, `$OnAdd` |
| Dictionary | `"cat:animal; dog:animal"`, `$MyDict[key]`, `.keys`, `.size` | — |

Two manual inconsistencies worth recording. **Dictionary is missing from the
"Attribute types" list** (line 1369) despite having a full operator section
(line 4141) and being an accepted `createAttribute` type: "Recognized values
for type include string, number, boolean, date, color, interval, file, list,
set, url, and dictionary" (line 4982). And `Action` is declared "System use
only" yet a user could presumably store code in a String; UNCERTAIN whether
user attributes may be declared Action-typed. Settled by opening the Document
Inspector's User pane and reading the type popup, or by aTbRef's attribute-type
page.

### Are types enforced?

No, in the interesting sense. Types govern *storage, comparison, and display*,
but almost everything coerces:

> "In many respects, List-type attributes can be considered a special form of
> String-type attribute (a string with semicolon delimited values), meaning
> that Lists can be coerced to/from Strings." (line 1436; the same sentence
> recurs for Set, URL, and Action)

Truthiness is defined by coercion table (line 4104, "Logical Operators"):
number 0 false; `""` and `"false"` false; empty set false; date `"never"`
false; colour black false. Restated at line 2836 ("True and False").

Comparison is context-sensitive: "If max(list) or min(list) is evaluated in a
numerical context, numerical comparison is used. Otherwise, Tinderbox uses
lexical comparison." (line 4068)

Types matter enough that local variables want annotations, and the manual shows
why with a three-line demonstration (line 3172):

```
var x:number(5); x=x+5; $MyString=x;  ➛ 10
var x:list(5);   x=x+5; $MyString=x;  ➛ 5;5
var x:string(5); x=x+5; $MyString=x;  ➛ 55
```

Introspection exists: `type("Width") ➛ "number"` (line 4402).

An attribute's type is a property of the *attribute*, document-wide — not of
the value on a particular note. There is no per-note type variation and no
union type.

### Default values

One declared default per attribute per document, and it is the bottom of the
inheritance chain (§4.1). Changing it retroactively changes every note that has
no local value and no prototype value (line 1358). Settable from the Document
Inspector, from AppleScript, and from action code.

### "Displayed attributes" — a view, not a schema

This is the distinction the task asks about, and it is sharp.

> "Tinderbox keeps track of hundreds of attributes for each note, but a few
> attributes of each note are likely to be of particular interest to you… A
> note's displayed attributes appear at the top of its text pane… You choose the
> displayed attributes by setting the value of the attribute
> $DisplayedAttributes — just enter the names of the attributes you'd like to
> make displayed attributes, separating them with semi-colons." (line 1477,
> section "Displayed Attributes")

Formerly "key attributes" (line 1479). Inherited from prototypes (line 1490).
Changed from a Set to a List in 9.2 for ordering control:

> "$DisplayedAttributes is now a list rather than a set… It is better to allow
> duplicate DisplayedAttributes in order to allow better control of the order in
> which they appear." (line 5586)

The key semantic point: **every note has every attribute.** There is no
question of which attributes a note "has"; only which are *shown*. The type of
each attribute determines its editor widget in the displayed-attributes table —
checkbox for Boolean, swatch for colour, globe for URL, folder for File,
semicolon string for List/Set (lines 1494–1503) — with autocomplete drawn from
values in use plus declared suggested values (lines 1494–1510, capped at 99
values).

This is a total inversion of Org, where a note has exactly the properties
written in its drawer, and "which properties does this note have" is the
primary question.

---

## 6. Evaluation-timing table

Consolidated. Everything here is cited above.

| Trigger | Fires when | How often | `this` is bound to | Stored? | Manual location |
|---|---|---|---|---|---|
| **`$Rule`** | continuously, unprompted | "at frequent intervals" — no number given (UNCERTAIN) | the note owning the rule | yes, writes attributes | line 2800; example line 1052 |
| **`$Edict`** | at document open, then unprompted | startup + "approximately one hour" | the note owning the edict | yes | lines 2801, 2906 |
| **`$OnAdd`** | a note enters a container, is discovered by an agent, or is placed on an adornment | once per entry event | the note **being added** | yes | line 2798; `this` at 2951 |
| **`$AgentAction`** | each agent refresh, per matched note | per `$AgentPriority`: few seconds / 10 s / 1 min / 5 min / 1 hr; or off | the **newly-created alias** (writes forward to the original except for intrinsics) | yes | lines 2543, 5357; `this` at 2950 |
| **`$AgentQuery`** | each agent refresh, per candidate note | same as above | the note being examined | no — evaluated for truth | lines 2538, 2827; `this` at 2949 |
| **Stamp** | user chooses it from the Stamps menu, or `stamp()` is called | never automatically | the selected note(s) | yes | lines 1570, 1849, 4324 |
| **`$OnJoin`** | a note is dragged into contact with a composite member | once per join | the joining note (`that` = the note joined) | yes | line 2635 |
| **Smart adornment query + action** | adornment refresh | like an agent (UNCERTAIN whether the same priority tiers apply) | the matched note; also **moves** it in the map | yes | line 2043 |
| **`$DisplayExpression`** | whenever the note is drawn | on every redraw | the note | **no** | line 2141 |
| **`$HoverExpression`** | on mouse hover | on hover | the note | **no** | line 2164 |
| **`$TableExpression`** | when a container's summary table is drawn | on redraw, per child | each child | **no** | line 2198 |
| **`update(notes)`** | called from action code | on demand; skipped if the note "has been evaluated recently" | the designated notes (runs their rule *and* edict) | yes | line 4301 |
| **Library function notes** | document startup, and after the note is edited | twice-ish | n/a — defines functions | n/a | line 3181 |

Ordering among triggers, and conflict resolution when two write one attribute:
**not documented.** See §3.6.

---

## 7. What survives translation to plain text

Tinderbox is a single-user, closed-world, GUI database with a live object graph
in memory, a single writer, an undo stack, and no persistence until save. Org
is plain text in ~3,600 files, edited by hand and by other programs, under
version control, with no daemon and no single writer. Judgements below are
argued from that difference, with the manual as evidence.

I have separated **the idea** from **the artifact** for each concept, and I say
plainly where I think something should not be built.

### 7.1 User Attributes — survives, and Org is already 80% there

Org's `:PROPERTIES:` drawer *is* user attributes, and `org-agents`' `$PROP`
layer already reads them. What Org lacks is the *declaration*: Tinderbox has a
document-scoped registry with name, type, default, suggested values,
description, and group (§2), introspectable from code via
`attribute("X").at("type")` and `document[user-attributes]`.

**Port the registry.** It is the highest value-per-line item in this whole
space, and it is small: a declarative table of property name → type, default,
allowed values, docstring. Three concrete wins:

1. **Typed coercion in queries.** `org-agents` currently infers coercion from
   *syntactic position* — `(> $REVIEWS 3)` numeric, `(string-match "gh" $URL)`
   string, per the Commentary in `org-agents.el`. That is clever and it works,
   but it means the same property coerces differently in different queries, and
   a typo in position silently changes meaning. A declared type lets the
   *property* decide, and the position layer becomes a fallback.
2. **Defaults without writing anything.** Tinderbox's "default value" is
   resolution-time, not materialised (§5). Org's equivalents already exist and
   are exactly this shape: `#+PROPERTY:` per file and `org-global-properties`
   document-wide (verified: a child heading resolves `STATUS` from a file-level
   `#+PROPERTY:` line via `org-entry-get` with INHERIT, with no local value in
   the drawer). A registry default extends that chain by one step with zero
   writes.
3. **Allowed values.** This is already Org: `:PROP_ALL:` and
   `org-property-allowed-value-functions` are literally Tinderbox's "suggested
   values" (§2), including the "not enforced, just offered" semantics.

**Do not port:** "every note has every attribute." In Tinderbox that is free —
one table, one default column, invisible storage. In Org, materialising
defaults into 3,600 drawers would be a catastrophe: enormous diff churn, merge
conflicts on files nobody edited, and destruction of the property that makes
Org worth using — that the file is the truth and a human wrote what is in it.
The Org analogue of a default is *resolve at read time*, full stop.

**Cost:** small. A defcustom/alist, a resolver function, completion and lint on
top. Days, not weeks. Low risk because it adds a read path and writes nothing.

### 7.2 Prototypes — the value-inheritance half survives and is the most interesting thing here; the rest does not

**What is intrinsic to the concept:** a named entity that supplies default
values (and default *code*, §4.3) to many entries, resolved lazily at lookup,
overridable locally, chainable, single-parent, and — crucially —
**orthogonal to the containment hierarchy** (§4.1, line 1751).

That orthogonality is the part Org genuinely lacks. Org today offers exactly
three inheritance axes, and all three conflate inheritance with *location*:

- outline ancestry (`org-entry-get … t`) — free, but says "this note inherits
  because of where it sits", which is precisely the conflation Tinderbox went
  out of its way to reject;
- file-level `#+PROPERTY:` — inheritance by file;
- `org-global-properties` — inheritance by everything.

A `:PROTOTYPE:` property naming another entry, plus a resolver walking
**local → prototype chain → outline ancestors → file → global → declared
default**, is a small, well-defined addition that fits Org's grain: it is a
read-time rule, it writes nothing, it is diffable, and a human reading the file
can see the whole story (`:PROTOTYPE: Book` is right there in the drawer).

Three design consequences I would argue for firmly:

**(a) Resolve, never materialise.** The moment prototype values are copied into
instance drawers you lose the ability to change a prototype (Tinderbox's
headline benefit, line 1690), you generate a diff per instance per edit, and
you make the file lie about what the author wrote. Tinderbox resolves lazily
and so should this.

**(b) The local/inherited distinction is *free*, and in Org it is a feature
rather than a leak.** Empirically verified: `(org-entry-get nil "OWNER" nil)`
returns `nil` while `(org-entry-get nil "OWNER" t)` returns `"alice"` —
`hasLocalValue()` is already in Org's API, twice over. And note the inversion
of Tinderbox's own advice. The manual says wanting to know local-vs-inherited
"is often a sign that your overall design is incorrect" (line 4397) — true when
the store is invisible and the resolved value is the only truth. In Org the
store is the document a human reads; the drawer showing `:OWNER: alice` *is*
the statement "this one is different". Do not hide that. Design so the drawer
always shows exactly the local overrides and nothing else.

**(c) Single inheritance, and mean it.** Tinderbox allows one prototype with
unbounded chaining (line 1722). Resist `:PROTOTYPE: Book Reviewed`. Multiple
parents demand a linearization rule, and no reader of a plain-text file can
compute an MRO in their head — which forfeits the entire reason to prefer plain
text. Single parent plus chaining delivers essentially the whole win.

**What should not be ported:**

- **`$PrototypeBequeathsChildren` (§4.4).** This is template instantiation, not
  inheritance — and Tinderbox knows it, which is why the semantics are
  snapshot-at-assignment rather than live. Org already has `org-capture`
  templates and `org-structure-template-alist` for exactly this job. A second,
  weaker template mechanism inside `org-agents` would be a mistake. If a
  prototype should imply child structure, express that as a capture template
  that the prototype *names*.
- **Appearance inheritance.** See §7.3.
- **The `$IsPrototype` flag.** In Tinderbox it exists to populate a popup menu.
  In Org, "is this entry a prototype" is answered by "does anything name it in
  a `:PROTOTYPE:` property", and an ID or an outline path is the natural
  handle. Do not add a marker property whose only job is to feed a UI that does
  not exist.

**Cost:** small-to-medium. The resolver is easy. The real costs are cycle
detection (Tinderbox gets this free from its GUI; a text file can trivially say
`A → B → A`), cross-file prototype lookup (wants `org-id`, and then wants a
cache), and cache invalidation on edit. A week, and the risk is all in caching.

**One thing that ports *perfectly*, and is worth calling out:** §4.3's
insight — behaviour is inherited because behaviour is stored in an attribute.
Org properties hold strings. `:AGENT_QUERY:`, `:AGENT_VIEW:`, `:AGENT_COLUMNS:`
are already strings in drawers. So a prototype that supplies property values
automatically supplies inherited *queries and view configuration*, with no
additional machinery whatsoever. `#+COLUMNS:`/`:COLUMNS:` — which is Org's
already-existing, better-named "Displayed Attributes" — comes along for free
for the same reason. That is a genuinely free lunch and it should shape the
design: put configuration in properties, and inheritance of configuration costs
nothing.

### 7.3 System Attributes — mostly an artifact; largely should not be ported

The category does not survive because the thing it is the "system" half *of*
does not exist in Org. There is no privileged attribute table; there is text in
a file. Taking the four kinds from §1 separately:

**Appearance (`$Color`, `$Width`, `$Xpos`, `$Badge`, `$Shape`, `$Pattern`) —
do not port.** These exist because Tinderbox owns the renderer and the map view
is the product. Org's renderer is the Emacs buffer, which is not
attribute-driven, and Org already has four native mechanisms for "make this
stand out": tags, TODO keywords, priorities, and faces. A `:COLOR:` property
would be a value with no consumer — inert text in 3,600 drawers, decorating
nothing. Worse, it invites building a display layer (overlays keyed on
properties) whose maintenance cost is unbounded and whose value is aesthetic.

The one defensible exception: `org-agents` *does* own the renderer for the
views it generates (`list` and `table` dynamic blocks, and the children view).
Appearance properties consumed *only there* — a face or a prefix marker per row
— are cheap and honest. Colouring the user's own corpus is a different and much
worse proposition.

**Derived read-only facts (`$Created`, `$Modified`, `$WordCount`,
`$ChildCount`, `$InboundLinkCount`) — port the *queryability*, not the
storage.** This is the sharpest single recommendation in the document: **the
correct Org analogue of a read-only system attribute is a computed query term,
not a property.** Writing `$Created` into every drawer duplicates what the
filesystem and git already know, and immediately goes stale. `org-agents`
already does this correctly: `$ITEM`, `$TODO`, `$PRIORITY`, `$TAGS`,
`$CATEGORY`, `$LEVEL`, `$FILE` are computed specials, not properties. The
System-Attribute concept is therefore **already ported**, and the work is to
extend that list — `$WORDCOUNT`, `$MODIFIED`, `$CHILDREN`, `$BACKLINKS`,
`$DEPTH` — rather than to introduce a parallel notion of system *properties*.

**Content (`$Name`, `$Text`) — does not translate, and the difference is
load-bearing.** In Tinderbox these are cells that action code rewrites at
will. In Org the heading and body are the artifact under version control. Any
design that treats the heading text as a writable attribute of an automated
rule has crossed a line that a plain-text corpus should not cross. Renaming
notes from a rule is trivially expressible in Tinderbox and should be
essentially unavailable here.

**`$DisplayedAttributes` — already ported, under a better name.** Org's
`#+COLUMNS:` / `:COLUMNS:` / `org-columns`, and `org-agents`' own
`:AGENT_COLUMNS:` and `:AGENT_FORMAT:`, are the same idea. The only missing
piece was prototype-inheritance of it, and §7.2 supplies that for free. Note
the semantic difference remains and is fine: Tinderbox needs displayed
attributes because every note has hundreds of attributes and 99% must be
hidden; Org needs columns because a *view* wants a subset. Same mechanism,
opposite motivations.

**Cost:** near zero for the query-term extensions (they are functions), and I
would spend nothing on appearance beyond the generated views.

### 7.4 Action Code — port the language and the trigger *taxonomy*; refuse the schedule

This is where the interesting judgement lives, and my answer is a split
decision.

**The expression language does not need porting at all.** Tinderbox invented a
DSL because it had no host language. Org has Elisp, and `org-agents` has
already made exactly the right call, stated in its own Commentary: "Evaluation
is always performed by org-ql against live buffers, so there is exactly one
evaluation engine and one answer." Inventing a Tinderbox-flavoured action DSL
would be a straight regression — worse than Elisp on every axis, plus a second
evaluator to maintain and a second set of semantics to document. Actions should
be Elisp (or a small restricted sexp form), evaluated with point at the entry.
The `$PROP` reader layer is the right amount of sugar and there should be no
more.

Two primitives *are* worth stealing verbatim, because they are about diffs
rather than about syntax: **`|=` and `&=` conditional assignment** (line 2855)
and **`$Prop=;` to unset** (line 2853). In Org, "assign only if not already
set" and "remove the local value so inheritance resumes" are precisely the two
operations that keep a run from producing a diff. They deserve to be first-class
in whatever action vocabulary emerges.

**The trigger taxonomy is the genuinely portable insight — and it is what every
summary omits.** Tinderbox's triggers are not five features; they are points on
one axis: *how often, and who asked*.

| | who asked | how often |
|---|---|---|
| Rule | nobody | seconds |
| Edict | nobody | hourly |
| Agent action | nobody | per priority tier |
| OnAdd | nobody (a structural event did) | once per event |
| Stamp | **the user** | once |

Naming that axis is the useful thing to hand the user, because it makes the
translation question concrete: *which of these can exist without a daemon and
without a single writer?*

**Rules and Edicts do not survive. I would not build them.** Not "hard" — wrong.
Three arguments, all grounded in the manual:

1. **Every firing is a commit.** Tinderbox's rule loop is affordable because
   the object graph is in memory, nothing persists until save, there is exactly
   one writer, and there is an undo stack. In Org, a rule that "adjusts the
   appearance of each task" (line 2897) rewrites files. Run it every few
   seconds over 3,600 files and the repository history becomes machine noise —
   and every `git pull` on another machine is a merge conflict in a drawer
   nobody touched. The manual's own justification for Edicts is *battery*
   (line 2906); ours would be *the integrity of the history*, which is a much
   stronger objection and does not get better at hourly resolution.
2. **A rule silently claims an attribute.** From §3.6: a rule that assigns
   unconditionally always wins over the user, over a stamp, and over an OnAdd,
   because it runs again. In Tinderbox that is tolerable — you see the value
   snap back, and `$RuleDisabled` is one checkbox away. In Org the user's hand
   edit is *reverted in a file on disk*, possibly while they are not looking,
   possibly after they committed. That is not a feature with rough edges; it is
   a data-loss shape.
3. **Convergence is not free.** Tinderbox's whole correctness story for rules is
   "make the primitives idempotent and re-run forever" (§3.5). That reasoning
   depends on re-running costing nothing. Here it costs a diff, so idempotence
   stops being a style guideline and becomes a hard precondition — and a
   precondition you cannot check, because the action is arbitrary Elisp.

What survives is the *purpose* of rules, and it splits cleanly in two:

- **Derived values that only need to be right when read should not be written
  at all — compute them in the view.** Tinderbox itself hands us the pattern:
  `$DisplayExpression`, `$HoverExpression`, and `$TableExpression` are
  expressions *evaluated at display time and never stored* (§3.2). That is
  precisely the Rule use-case minus the writes, and it is the single
  highest-value, lowest-risk item in this entire design space. `org-agents`
  already has the mechanism — `:AGENT_COLUMNS:` and `:AGENT_FORMAT:` render
  property values into generated views. Letting those hold *expressions* rather
  than bare property names delivers most of what people want from Rules
  (computed status, days-until-due, rolled-up counts, formatted labels) with
  zero corpus writes and therefore zero diffs. If only one thing gets built,
  build this.
- **Values that genuinely must be persisted** — because `org-agenda`, another
  tool, or a human reader consumes them — should be written by an **explicit,
  user-invoked, idempotent command over an explicit scope**. Which is to say:
  a Stamp.

**Stamps survive intact, and they are the natural fit.** A stamp is an
interactive command applying an action over a scope. Org already has
`org-map-entries`; a stamp is `org-map-entries` with a saved name, and
Tinderbox even stores stamps as notes with the code in the note body (line
1596) — the direct Org analogue being a named entry whose body is the action, in
a well-known place. The manual's own framing is exactly right for our world:
stamps are for actions "that aren't suitable for automatic application through
agents or OnAdd actions" (line 1849). In Org, *nothing* is suitable for
automatic application, so stamps carry the whole load. The design work is not
the language; it is scope, preview, dry-run, and batching writes so one
invocation is one reviewable change.

**OnAdd survives only in a narrow, honest form, and the caveat must be stated
up front.** In Tinderbox "a note was added to this container" is a real,
observable, single-writer event. In Org, "a heading became a child of X" has no
reliable event: it happens by refile, by yank, by capture, by an external
script, by `git pull`, by another Emacs, by `sed`. Org does provide real hooks
(`org-after-refile-insert-hook`, capture templates, `org-insert-heading-hook`),
so OnAdd is portable *for the paths `org-agents` itself controls* — capture into
an agent's container, refile via a provided command, and the alias writing
`org-agents` already does — and not portable in general. Promising "OnAdd"
without that boundary promises something undeliverable, and the failure is
silent: entries that arrived by an unhooked path just never get stamped. If
built, it must be paired with a reconcile stamp that fixes up whatever the
hooks missed, and documented as such.

**Document-wide write authority must be reined in, but not forbidden.**
`$Color(find($Status="Urgent"))="red"` inside a `$Rule` (§3.4) is a one-line
whole-corpus read-modify-write re-executed every few seconds. Even as a stamp,
the Org version must load arbitrary files, write them, and produce a commit.
The recommendation is not to forbid reach but to make it *declared and
reviewable*: an action's default scope should be the agent's own match set,
which the user already wrote down and can see rendered; anything wider should be
explicit; writes should be batched with a preview and a dry-run. And
`runCommand()` deserves a specific mention: Tinderbox explicitly sanctions
shelling out from a rule (line 4328). Attaching a shell command to any automatic
trigger in a git-managed corpus is not something to offer.

**The alias indirection should not be ported at all.** §3.3 is a warning, not a
model. Tinderbox needs the alias/original distinction, the `original`
designator, and a whole parallel `…Original` link-operator family because an
alias is a *live proxy object* whose non-intrinsic writes forward to the
original. An Org alias is a *link* — there is no proxy and nothing to forward.
So: agent actions in Org should operate on the **match**, never on the generated
alias, and the generated alias should remain a pure rendering artifact. That is
already the spirit of `org-agents`' existing alias contract (a pristine alias
"belongs to this package"; the moment the user writes under it, it is theirs).
Introducing a `this`/`original` distinction would import Tinderbox's hardest
bug surface for no gain.

**Cost:** expressions-in-views, small and high value. Stamps, medium — the
language is free, the cost is entirely scope/preview/undo/not-corrupting-files.
OnAdd, small if honestly scoped to `org-agents`' own commands, unbounded if
promised generally. Rules and Edicts: I would spend nothing. If the user
insists, the only defensible shape is an explicit reconcile command (a stamp
over a saved scope), optionally wired to a single-file `before-save-hook` or a
git pre-commit hook — never a timer over the corpus.

### 7.5 Summary judgement

| Concept | Verdict |
|---|---|
| **User Attributes** | Survives. Org has the storage; port the *declaration* (type, default, allowed values, doc). Small, high value, writes nothing. |
| **Prototypes** | Survives in its valuable half: an orthogonal, lazily-resolved, single-parent, chainable value-and-code inheritance axis. Resolve, never materialise. Drop bequeathed children, appearance, and the prototype flag. |
| **System Attributes** | Mostly an artifact. Appearance: do not port. Derived facts: already ported correctly as computed query terms — extend that, do not store them. Content-as-attribute: does not translate, and should not. Displayed attributes: already Org's `:COLUMNS:`. |
| **Action Code — language** | Do not port. Use Elisp; one evaluator. Steal `\|=`, `&=`, and unset. |
| **Action Code — Stamp** | Survives intact. The natural Org fit and the load-bearer. |
| **Action Code — display expressions** | Survives, and is the best idea in the whole manual for this port. Build this first. |
| **Action Code — OnAdd** | Survives only for paths `org-agents` controls. Must ship with a reconcile stamp and an honest caveat. |
| **Action Code — Rule / Edict** | **Does not survive. Should not be built.** Continuous re-evaluation of a live in-memory graph is the artifact; here every firing is a commit and every unconditional assignment is a silent claim on a file the user also edits. |
| **Alias/original indirection** | Do not port. Act on the match; keep generated aliases inert. |

---

## 8. UNCERTAIN — open questions and what would settle them

1. **Rule evaluation interval and ordering among notes.** The manual says only
   "frequent intervals" (line 2800). Settled by aTbRef's `$Rule` page, or by
   instrumenting Tinderbox: a rule of `$MyNumber+=1` and a stopwatch.
2. **Conflict resolution when two triggers write one attribute.** Not documented
   anywhere (§3.6). Settled by the three-way experiment described in §3.6, or by
   aTbRef on evaluation order. This matters for the design conversation even
   though I recommend against porting rules, because it determines whether
   Tinderbox has a *policy* here or merely a race.
3. **Whether action code can delete notes.** `create()` is documented (line
   3970); no delete operator appears in this manual; AppleScript has
   `delete myNote` (line 4890). Settled by aTbRef's operator index.
4. **How a note is moved by action code.** Implied throughout (lines 1053,
   4999) but the syntax is never shown; presumably `$Container=`. Settled by
   aTbRef or by experiment.
5. **Whether OnAdd cascades.** If an OnAdd action creates a note inside the same
   container, does OnAdd fire again? Undocumented, and it is the difference
   between a trigger and a fixpoint. Settled by experiment.
6. **Whether a prototype's own `$Rule` runs on the prototype itself.** The
   prototype is an ordinary note holding a local `$Rule` value, so presumably
   yes — which means prototypes are live participants, not inert templates.
   Undocumented. Settled by experiment.
7. **Whether Dictionary is a first-class user-attribute type.** Accepted by
   `createAttribute` (line 4982) and fully operator-supported (line 4141), but
   absent from the "Attribute types" list (line 1369). Settled by the Document
   Inspector's User pane type popup.
8. **Whether user attributes may be declared Action-typed.** The manual says
   Action is "System use only" (line 1453). Settled the same way.
9. **Whether smart adornments share the agent priority tiers.** Line 2043 says
   they "have a query, just like agents" but says nothing about rate. Settled by
   aTbRef.

## 9. Reproducing the Org checks in this document

The one empirical claim made above about Org — that the local-vs-inherited
distinction is directly observable and that file-level `#+PROPERTY:` already
participates in the resolution chain — was verified with a throwaway fixture
under this session's scratchpad, using
`/nix/store/1jy6wkqyckvs10q661zvpaxx52g97206-emacs-mac-macport-with-packages-30.2.50/bin/emacs`
in batch mode. A child heading with a local `:KIND:`, a parent-only `:OWNER:`,
and a file-level `#+PROPERTY: STATUS`:

```
OWNER:  local=nil          inherited="alice"
KIND:   local="child-kind" inherited="child-kind"
STATUS: local=nil          inherited="global-status"
org-use-property-inheritance = nil
```

`org-entry-get` with and without INHERIT is therefore already
`hasLocalValue()`, and `#+PROPERTY:` is already an inheritance tier. Nothing in
§7.1 or §7.2 requires new lookup machinery — only a chain extended by one step.
