# DataCode design review — 2026-08-28

A deep pass over all 31 files in `docs/`, plus designs for the sixteen syntax and architecture
changes you asked for. Two multi-agent runs produced it: a 31-agent audit (nine document clusters
× two lenses, four cross-cutting sweeps, one adversarial verifier per cluster) and a 33-agent
design pass (one designer and one adversarial critic per question, plus an integrating grammar
reviewer). Every audit finding below survived a verification pass whose default was to refute it.

## Contents

| File | Holds |
|---|---|
| `00-report.md` | This report |
| `10-findings.md` | All 640 verified findings, grouped by file, with evidence and a fix each |
| `20-syntax-decisions.md` | The sixteen questions: recommendation, pushback, alternatives, critique |
| `30-integrated-grammar.md` | The conflict-resolved EBNF delta across all sixteen, plus the phase plan |
| `40-bibliography.md` | Annotated bibliography, organised by the design claim each source bears on |
| `50-validation.md` | Validation of the two Phase 0 rules: the admissible-default table, corpus violations, and ten open items |
| `90-questions.md` | What I need from you |

## Decisions taken

Four questions were put to Chris on 2026-08-28 and answered. They are recorded here because each
one changes several of the sixteen items below, and because two of them settle a Phase 0 blocker.

### A `:>` field to a `Component` sub-table is table-valued

`headers :> RequestHeader : Component { … }` holds **all** of that request's header rows, in
`ordinal` order. Consequences, each of which needs writing down:

- `tables.md:421-429` is correct as written. **Do not rewrite that example** — several proposals
  wanted to, and they were wrong.
- `queries.md:234-236`'s "the same construct as an inline component sub-table" becomes true rather
  than aspirational.
- **1:many inline declaration already exists** for owned children. `:<` (item 16) therefore shrinks
  to the case that actually needs it: children that are *not* owned — true linking tables, and
  children with independent lifetime.
- The asymmetry must be stated in `tables.md`: a `:>` whose target carries `Component` is
  table-valued; a `:>` to any other table is single-valued and wraps one `DataId`. This is what
  resolves `tables.md:326` against `traits.md:199` — a component has no `DataId`, so the field
  cannot be wrapping one, and the parent-prefix range scan is what it denotes instead.
- `settings :> Settings : Component = { theme = Dark }` (`tables.md:441-446`) is a 1:1 component, so
  `= { … }` becomes sugar for a one-element literal. State it, or the default clause and the field
  type disagree.
- A table-valued field is rejected in a key, in `unique`, in `order by`, and in `==`, and is excluded
  from `*` unconditionally.
- `ordinal` stays on **stored** components and is withdrawn from nested tables produced by `group`
  or by a projection sub-nesting — nothing was inserted in any order there.

### Membership is `` `elem` ``

`` status `elem` [Pending, Shipped] ``. `in` stays reserved for `let … in` and gains no second
meaning. One production is added — `TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'` — shared with
the multi-row insert of item 13.

One refinement that falls out and improves both items: **the multi-field form uses a `RecordLit`,
not a tuple.** `{ customer = c, order_num = n } `elem` <table>` reuses a production that already
exists, needs no `TupleLit`, binds by name rather than position, and makes the element shape
identical to the one the insert literal uses. One element shape everywhere.

### The client kind is `Client`; the registry is a separate table

Chris's reading is the right one and it dissolves the naming problem: the two things were being
conflated. Split them and no qualifier word is needed.

| Table | Trait | Holds |
|---|---|---|
| `system.auth.Client` | `Reference` | The **kind** — `Storefront`, `AdminIde`, `Cli`, `Server`. Low cardinality, schema, replicated everywhere. Schema-level reach attaches here. |
| `system.auth.Registration` | `Configuration` | One row per **registered device or installation**: `:> Client`, `:> User`, plus the per-platform identifiers. |
| `system.auth.ClientToken` | `Configuration` | The bearer credential issued at registration, `:> Registration`. |

`Server` is a `Client` that cannot be narrowed, which is the unification asked for. OQ-008 narrows to
"which identifiers must each platform supply on `Registration`". The hostname is an **issuance-time
selector** only: at request time it is checked for equality with the origin recorded on the
registration, never consulted to decide reach. Getting that backwards lets a browser reach
`system.auth` by sending `Host: ide.example.com`.

`authed_client` stays rejected. Schema-level reach is what a `Client` row decides; row-level
filtering is what an assert decides; admitting the client into an assert body would put one decision
in two places, and the critic found three fail-open paths in the version that tried.

### The type is `File`, not `Blob`, and DataCode is the origin

DataCode serves the CSS and JS. No external CDN. Two consequences that change the design as
proposed:

- **`File` carries a media type, not just octets.** It has to, because the HTTP response needs one
  and `api.md` currently has no octet-stream response mode at all. That mode is now required work.
- **`File` content must be readable in `Read`, not only in `Effect`.** The motivating case is a
  stylesheet that is both served at a URL *and* inlined into rendered HTML for email, where mail
  clients demand inline CSS. A template hole is `Read` (`templates.md:128-130`), so an
  `Effect`-only `File` cannot serve the second path. The read is bounded by a
  `system.config` size cap; above it, the value is reachable only through the streaming handler.

Storage tiering is settled as **(a) default, (b) available, (c) modelled as an ordinary URL**:

- **(a)** Where a `File`'s chunks are laid out *inside* the graph — inline with the parent's extent
  or in an extent of their own — is a `Configuration` row beside `ExtentPolicy`, per field with a
  per-server override. Pure tuning, invisible to the model.
- **(b)** Bytes on the server filesystem with the row holding a digest and a path is available, as a
  **separately named type**, never as a quiet per-field flag. It gives up four properties a reader
  otherwise assumes — `verify shard` cannot check the bytes, replication does not carry them, a
  restore does not restore them, and `scrub` cannot reach them — so the type name is what warns.
- **(c)** A purely external reference is an ordinary `Text` URL and needs no mechanism.

### `Component` is 1:many, and a many:many *link table* may still be a `Component`

These are two questions and they have different answers.

**A component has exactly one parent, structurally.** The parent's `DataId` *is* the component's
identity prefix (`transaction-graph.md:473-491`), so a second parent has nowhere to live. Cardinality
from the parent is 0..2³²; from the child it is exactly 1. `Component` is therefore always 1:many and
a many:many *identity* is unrepresentable rather than merely disallowed. The ordinal follows from the
same fact rather than being a separate choice: single parent → the parent's id is the prefix →
an ordinal disambiguates siblings → the parent link costs zero bytes and the subtree is one range
scan.

**But a many:many relationship can be implemented with a `Component` link table**, because
`traits.md:221-222` permits an outbound FK from a component to anything: *"A component may reference
outward freely — an outbound FK creates no inbound dependency."* So `OrderTag : Component` of `Order`
with `tag :> Tag` is a legal many:many between `Order` and `Tag`, shard-local to `Order`, with a
zero-byte order link.

The discriminator is the *other* invariant, `traits.md:220`: **nothing outside the parent's subtree
may reference a component.** So:

> Use a `Component` for a link exactly when nothing needs to reference the **link row itself** from
> outside, and the link's lifetime is the owner's.

A `Membership` row that a `Payment` points at cannot be a component. A `Membership` row nobody points
at can be.

| Relationship | Construct | Owned by | Placement |
|---|---|---|---|
| 1:many, wholly owned | `:>` to an inline `Component` sub-table | the parent | parent's shard; ordinals; zero-byte link |
| many:many, one side owns the link, nothing points at link rows | `Component` of that side + outbound `:>` to the other | that side | owner's shard |
| many:many, neither side owns, or link rows are referenced | a table with two `:>` fields — declared top level or via `:<` | nobody | the **first** FK in its key decides the root |
| 1:many, child outlives parent or has its own identity | a table with a `:>` back — top level or via `:<` | nobody | the child's key decides |

Two corrections to the assumption this came from:

- **Outward references are not limited to `Reference` tables.** A component may point at any table.
  That is precisely what makes the second row of the table above work. The cost is that an outbound
  FK crossing a shard is a warning naming the edge (`constraints.md:187-189`) and restricts that
  attachment to `enforce forward`, `monitor`, or `repair` (`distribution.md:442-457`).
- **`:<` does not *make* a relationship many:many.** It is sugar for "declare that other table and
  give it an FK back to me". The many:many-ness comes from the link table carrying two `:>` fields.
  `:<` and a top-level declaration produce the same graph; `:<` only removes the second statement.

And one consequence worth stating in `tables.md`, because it is not obvious: a two-`:>` link table
lands in **one** side's shard family, decided by the head rule (the first FK in the key). The
asymmetry is unavoidable — a row lives in one shard — and it should be chosen deliberately rather
than by declaration order.

### `Component` shrinks to one bit: owned lifetime

The generalization is right and it removes a trait's worth of special-casing. `Component` stops
being a thing you get and becomes a thing you *declare only where it cannot be derived*, which is
one bit.

**Adopted:**

- **A `Component` may declare `unique`.** `tables.md:129` exempts it from *needing* a key and does
  not forbid one; the justification ("it is already keyed — by parent plus `Ordinal`") explains why
  it is optional, not why it is unavailable. A `unique` on a component is checked within the parent,
  so it costs one shard-local check. This closes the two-identical-`(order, tag)`-links gap.
- **`Component` stops occupying the replication-trait slot.** `traits.md:182` currently makes
  `table T : Component, UserData` an error. That is backwards: "wherever the parent is" is not a
  replication *policy*, it is what rooted placement already means, and the row's real replication
  answer comes from `UserData`. `Component` becomes a marker trait alongside `Personal` and
  `Keyless`, and `table OrderTag : UserData, Component` is legal.
- **The ordinal representation is derived, not declared.** Eligibility is mechanical: the key's head
  is an FK reaching the shard root through its chain. That is the same rule that already decides
  placement, so it cannot drift.
- **Many:many is then ordinary.** `table app.commerce.OrderTag : UserData, Component { order :>
  Order, tag :> Tag, unique linkRef { order, tag } }`. The ordinal is the surrogate, `linkRef` is
  the natural key — exactly parallel to `DataId` plus a candidate key on any other table.

**One bit cannot be derived from the key, and it is lifetime.** Two tables with an identical key
shape want opposite answers:

| Table | Key | On parent delete |
|---|---|---|
| `Order` | `{ customer, order_num }` | orders **survive** — `tables.md:464`, non-`Component` FKs never cascade |
| `OrderLine` | `{ order, product }` | lines **go** — a line has no meaning without its order |

Both are `{ <FK reaching the root>, <local discriminator> }`. Nothing in the key distinguishes them,
so `Component` survives as exactly that declaration, and everything it currently bundles becomes a
consequence of it: `created_at` and `origin_server` inherit (the row cannot outlive its owner);
nothing outside the subtree may reference it (or the subtree is not prunable as a unit); the row
cannot be reparented; the surrogate identity is the position.

Two costs to price rather than hide:

- **Ordinal assignment is a per-parent read-modify-write.** Coordination-free, because the parent's
  shard primary linearizes writes — but still a serialization point on that parent, where a `DataId`
  needs no coordination at all. Bounded children (order lines, request headers, `Doc` nodes) do not
  notice. A component directly under a shard root with unbounded cardinality does. Schema commit
  should price it exactly as a table-wide `next` is priced today (`tables.md:269-271`) — the same
  diagnostic, naming the serialization it introduces.
- **`created_at` is the parent's.** `transaction-graph.md:642-643` already supplies the escape
  (declare a `Timestamp` field), but it should be named at the point of decision rather than found
  later.

### Re-keying is a delete plus an insert

The placement-key hole closes without new machinery, and closing it deletes four rules.

**The chain.** A foreign-key functor is `DataId → Either Error Row` and resolves to a **live** row
(`functors.md:15`), so an FK can name a deleted row only where the field carries a `Null`-derived
tail. A placement-key FK can never carry one, because `tables.md:207` rejects a `Null`-derived
variant in a key — and that rule is **general, not Component-specific**, so it already holds for
`Order.customer` as much as for a component's owner. So a shard-bounded `Ordinal`, and a rooted key
generally, can be invalidated by exactly one thing: the placement-key FK being **updated**.

**The rule.** A write that changes a placement key is not an update. It is a **delete and an
insert**, and it applies generally rather than only to components — two rules for one situation
would be worse than one.

Four things stop needing to exist:

- The recorded cross-shard *migration* it would otherwise need. A delete in shard A plus an insert in
  shard B is an ordinary two-participant transaction: a prepared node each and one commit node,
  already fully specified (`distribution.md:401-432`).
- `traits.md:220`'s "a component cannot be reparented" as a standalone invariant. It follows.
- Any rule about placement-key mutability. There is nothing to permit or forbid.
- `traits.md:221`'s "nothing outside the parent's subtree may reference a component" can relax to a
  warning: an outside reference makes the subtree non-prunable as a unit, which is worth saying, not
  worth forbidding, once the delete is restricted.

Two things must be added, and the design needed both anyway:

- **Deleting a row with live inbound non-nullable references is rejected.** This is `RESTRICT`, and it
  follows from the FK functor's own signature rather than being a new policy. `tables.md:464` says
  non-`Component` foreign keys never cascade and never says what they do instead; this is the answer.
- **Re-keying is therefore rejected wherever the delete is** — that is, where the row has non-owned
  inbound references. Moving a row across shards while things point at it from elsewhere is the hard
  case, and rejecting it is better than a silent distributed rewrite.

Two consequences to state rather than discover:

- **The row's `DataId` changes.** It genuinely became a different row in a different shard. The old
  row's history stays readable under its own id, and *nothing links the two* — see the open detail
  below.
**The rule is gated, and the gate is every `unique` on the table.**

> Delete-plus-insert applies only where **every `unique` on the table is headed by a foreign key
> reaching the same shard root as the placement key.** Where any `unique` is table-wide, or rooted
> elsewhere, changing the placement key is rejected.

The gate is not decoration. Two things go wrong without it, and only the first is about reservations:

- **A second `unique` collides with its own tombstone.** The placement key is safe, because the
  trigger for the operation is that its value changed, so the new value differs from the reserved
  one. Any *other* `unique` on the row keeps its value: the delete tombstones the row, a tombstone
  does not free the value (`distribution.md:315-330`), and the insert then writes the same value and
  is rejected. A table-wide `unique` served by a constraint shard fails this way every time.
- **A `unique` rooted elsewhere silently changes what it means.** A non-root key is checked within
  one shard (`tables.md:188`), and that shard is the row's — decided by the placement key's head.
  So a `unique` headed at a *different* root is checked against whichever population the row
  currently sits among, and moving the row changes that population without any of the constraint's
  own values changing. That is a semantic change with no write behind it.

The head is what matters, not every field: `unique linkRef { order, tag }` on a component of `Order`
is headed by `order`, so it qualifies, and it means "this order has at most one link to this tag" —
which is the intended reading of a many:many link.

Where the gate fails, the mutation is rejected with a diagnostic naming the constraint. The escape
is the existing one and it is deliberately manual: `release` the offending value, with its mandatory
authority and reason (`railroad.md:826`), then re-key. Auto-releasing inside an ordinary update would
defeat the property `distribution.md:315` exists to protect — a reserved value is released only
deliberately — and it would put an `ErasureCmd` inside the query language, which the design keeps
out on purpose.

**Open detail, not blocking:** nothing connects the tombstoned row to its successor, so "this order
moved from C1 to C2" is findable only by scanning. A `supersedes` edge on the insert would fix it and
is one field; whether audit needs it is a decision, not a derivation.

### What is left of `Component`

Restating after the above, because it is now smaller than the previous section says.

**The counter-scoping credit belongs to the key rule, not to `Component`.** `next <UniqueName>`
already allocates within the named constraint's field list minus the defaulted field
(`tables.md:249-256`), so `unique orderRef { customer, order_num }` already gives a per-customer,
shard-local counter with no coordination, and `unique invoiceNum { invoice_num }` already warns about
the table-wide one. Any rooted key gets this; `Component` adds nothing to it.

What `Component` adds is that **the ordinal replaces the `DataId` rather than sitting beside it**:

| | Ordinary rooted dependent | `Component` |
|---|---|---|
| Surrogate identity | `DataId`, 12 bytes | `Ordinal`, 4 bytes |
| Parent reference | FK column, 12 bytes | the identifier prefix, 0 bytes |
| Declared counter | `order_num : Int = next orderRef`, 4–8 bytes | none needed |

Roughly 24 bytes a row, and it is the whole of the space case.

**And one bit remains declared: does a delete cascade or restrict?** That bit is now smaller than it
was. Under the delete-plus-insert rule, reparenting, `created_at` inheritance and identity all follow
from the key; the only thing left that the key cannot say is whether deleting the owner destroys the
owned. `Component` means cascade; its absence means restrict. Everything else is derived.

### `retain` on `UserData` stands; branch squashing does not

`retain` on `UserData` is admissible and expected to be rare, which is what `aggregates.md:322`
already says. Phase 0 question 0.2 resolves to: keep the section, and add the missing half — there is
still no row-level `prune`, and `retain` is the only path.

**Squash merge is the wrong shape, and there is a better mechanism already implied by the design.**
The motivation is right: a local admin branch accumulates schema nodes nobody will ever need
individually, and they should be reclaimable. Three reasons not to squash:

- **Squash makes the source branch look orphaned.** Under a squash the branch is not a parent of
  anything on `main`, so `transaction-graph.md:88-92`'s "a branch with any path to `main` cannot be
  deleted" stops protecting it, and the git idiom that follows a squash is deleting the branch. That
  is history destruction arriving by convention.
- **Two-parent merge is load-bearing.** Merge reconciliation identifies "the same" row across
  branches by candidate key (`tables.md:136-143`), and the audit property is that the DAG shows both
  lineages. Collapse the second parent and you cannot say which branch asserted a value — the same
  gap that made the supplied-field mask undecidable at a merge.
- **Replay needs intermediate predicates, sometimes.** `enforce forward` compares against the
  predicate *as it was*, and re-deriving a `Derived` violation needs the predicate as of the
  violation (OQ-001). Squashing discards those.

That third reason also supplies the discriminator that makes reclamation safe:

> **A schema node is discardable exactly when no row was ever committed under it.**

On a local branch, by construction, none was — `distribution.md:251-264` says a local branch holds
the schema graph plus `Reference` rows and no user data. So the whole intermediate run qualifies,
and no rule has to be relaxed to say so.

The mechanism should therefore be **pruning, not squashing**, and it needs one existing rule
widened rather than a new merge mode: a *merged* branch's exclusive schema nodes become prunable once
nothing references them. That is the same refcount `prune` already needs, it keeps the merge
two-parented, it rewrites nothing, and it lands on the side of the line the design already draws —
reclamation is a consequence of a policy, never a verb someone types.

**The OQ is general graph reclamation, not branch cleanup.** Branch reclamation is the easy corner
of it — the case where the discriminator is free, because a local branch provably committed no rows.
The real question is what an administrator does when they genuinely need the space back across the
whole graph, and it is deliberately scheduled late: it is a background maintenance process on the
existing queue, it changes no syntax, and answering it early would mean designing a reference count
before the things being counted are stable. The reclamation *rule* — discardable exactly when no row
was ever committed under it — is what to record now; the traversal, the refcount representation, and
the operator surface are the OQ.

### Connectors: one kind, two GTID dialects, selected per connector

MariaDB is the required source and MySQL is supported alongside it, configured per connector row —
not two connector kinds, because everything downstream of the position is identical.

The two dialects are genuinely incompatible and the difference is not cosmetic:

| | MariaDB | MySQL |
|---|---|---|
| Position | `domain_id-server_id-sequence`, one per domain | `source_uuid:interval-list`, a GTID **set** |
| Handshake | session vars (`@slave_connect_state`, `@mariadb_slave_capability`) then `COM_BINLOG_DUMP` | `COM_BINLOG_DUMP_GTID` carrying the set in the packet body |
| Gaps | not representable — a domain has one high-water mark | representable, and normal |

So the stored position is **a set of rows, not a scalar**: one row per source (a MariaDB `domain_id`
or a MySQL `source_uuid`) carrying its high-water mark. MySQL's interval list is the one real
asymmetry — a single high-water mark is lossy once a gap exists, so the MySQL row needs the interval
set or an explicit "no gaps asserted" flag.

Two details worth fixing while this is written:

- **Detect and verify, do not just configure.** `@@gtid_mode`, `@@gtid_current_pos` and
  `@@version_comment` distinguish the two at connect time. Configuring the dialect and never checking
  it means a misconfiguration replicates from the wrong position silently.
- **A connector needs a seed.** An empty arrival log yields no position at all, so there must be an
  explicit origin — `Streamed | Snapshot | Reseeded Text` — or a connector cannot be started,
  re-seeded, or recovered from a source purge.

Neither dialect is supported by `mysql-haskell` 1.3.0; both are reachable through
`Database.MySQL.Connection`'s `writeCommand` and `putToPacket` with no fork.

### Every added column declares a default

> **A field added to an existing table must carry a `DefaultClause`. Omitting one is a compile-time
> error.**

Unconditional — it does not depend on whether the table currently has rows. That is deliberately the
opposite polarity from `integrity.md:173-197`'s "mode is mandatory on a *populated* field", and the
asymmetry is defensible: that rule is conditional because the blast-radius *number* is what the
author needs in hand, and here there is no number. The answer is the same at zero rows and at forty
million, so making it conditional would only mean a schema file that succeeds in development and
fails in production.

This replaces three contradictory statements about what an added field reads on older rows:
`evolution.md:34` (the default), `evolution.md:274` (`NotFound`), and `transaction-graph.md:655`
(`NotGiven`). The latter two are wrong for one reason — both sit outside the field's declared type.
`loyalty_tier : Tier` returning `NotFound` makes an exhaustive match over `Tier` non-exhaustive, and
it does so because of an evolution that happened *later*, which would make
`category-model.md:171`'s "every consumer is forced by the type system to handle the absent case"
untrue of every field in the database.

Requiring the default outright is stronger than requiring *either* a default *or* a `Null`-derived
variant in the type, and better, because the weaker rule has to infer which variant an old row reads
and a type may carry two (`Phone | NotGiven | Redacted`). Writing the default removes the inference.

**Nothing is backfilled.** No old row is rewritten; the value is computed at read from the schema
node that added the field.

Which forces the admissibility criterion, and validation tightened it twice from what this section
first said:

> **A default is admissible on an added field exactly when it is `Pure` *and* stable for the life of
> the row** — reproducible at read from the old row plus the schema node, and identical to what an
> insert after the add would have stored.

"`Pure`" alone is too weak. `= other_field * 2` and `= (OrderStatus where name == "Pending")` take no
ambient input, but an old row recomputes them at read while a row inserted after the add froze the
value at insert — so the two populations diverge with nothing in the row saying which regime it is
under. `tables.md:219-220` already excludes `updated_at` from a key on exactly this ground.

The full form-by-form table is in [50-validation.md](50-validation.md) §B. Three entries matter here:

- **`= next orderRef` is rejected.** It allocates rather than evaluates — a read-modify-write on a
  counter row (`tables.md:258`) — and it is the only genuinely `Tx` default, which is the sole reason
  the ladder has a `Tx` cell for defaults at all.
- **`= authed_user` is rejected, but not for the reason this section originally gave.** It is *not*
  that no token exists: `railroad.md:913` puts `authed_user` in scope in field defaults and every
  read carries a token, so the default resolves — **to whoever is reading**, which would make
  `created_by` differ between two readers of the same row. Silent divergence is worse than failure.
  The correct reason is that `authed_user` is transaction-ambient input rather than row data, the
  same shape as *time is a parameter, never ambient*.
- **A `:>` field to a `Component` target needs no default at all.** Under the table-valued decision
  its old-row value is the **empty table**, which is inside the declared type — no write, no ambient
  input, nothing to supply. Only the *constructing* form `= { theme = Dark }` (`tables.md:443`) is
  rejected, because a construction needs a transaction and a row committed last year has none.

Two rules travel with the table. The default must **satisfy the field's own `where`**, since under
Rule A it becomes the value of every existing row and a default failing its own predicate marks 100%
of them in one commit — a schema error, not a migration choice. And **no `unique` field may be added
to a populated table**, because every admissible default is constant and no injective row-local
expression is spellable.

**Scope.** State the rule over the **effective field set**, not over table redeclaration: a trait
gaining a field adds a column to every table extending it, and generated tables (`Doc indexed`
siblings, rollup levels, connector shadow schemas) reach the same path without a redeclaration
anywhere. Two citations in the paragraph above are off by a few lines and corrected in
[50-validation.md](50-validation.md) §D — `evolution.md:39` carries the contradiction, not `:34`,
which is the compliant example.

### Re-keying records itself on the transaction node

The link between a tombstoned row and its successor is a property of the **transaction node**, not a
column on the row. A row column would be `DataId | NotSuperseded` on every row of every rooted table
for something that almost never happens; the deciding objection is not sparsity but placement — a
supersession is a fact about a *transaction*, so a row column stores it on the wrong object.

Validation corrected three claims this section first made, and the substance survives all three:

- **The record cannot be typed `(old DataId, new DataId)`.** A component has no `DataId`
  (`traits.md:199`) and its identifier is variable-length (`transaction-graph.md:493`), so that type
  cannot name a component reparent — which is precisely the case this rule exists to cover, since it
  is what retires `traits.md:220`. Type the two fields as **`head_index` row keys**
  (`storage.md:43-45`): a `DataId`, or a `DataId` plus one `Ordinal` per nesting level. That is the
  key the index is already keyed by.
- **"Queryable" was false.** No `system.*` table exposes transaction nodes; `TxnCmd`
  (`railroad.md:818`) is CLI-only. `system.integrity.Violation` is queryable because it is an
  ordinary table — a property belonging to the alternative this rule rejected. Either declare
  `system.graph.Transaction` or drop the word. Declaring it is the better answer and the review
  already wants it for two other reasons (structural defect 6, and `show transactions` having no
  access story).
- **"Costs nothing per row" understated it.** A list of structs is a *pointer* field, so it costs one
  pointer word on every `TxNode` in the cluster forever. `spikes/capnproto/output.txt:89-95` measured
  a data-section scalar, and `storage.md:186`'s "exactly 8 bytes per message" is a claim about that
  scalar, not about a pointer field. Re-run the spike before leaning on it.

One gap the record does not close on its own: it is old→new and lives on the **old** row's shard, but
every consumer starts from the successor — the version-chain walk, `Violation.subject`,
`TriggerState.subject`, a captured queue payload id, merge reconciliation. A server-local,
unreplicated **new→old index derived from it** is what makes it usable, and it is derived rather than
authoritative, so it costs nothing in the graph.

### The re-key trigger is a change of shard root, not of any placement-key field

This narrows the rule two sections above, which was too broad in one direction and unusable in
another. Validation found both, and the second is serious.

> **Delete-plus-insert applies exactly when the write changes the row's *shard root*.**

- **Too broad as written.** Changing `Order.order_num` — a non-head field of
  `unique orderRef { customer, order_num }` — was a re-key under the old phrasing, with a new
  `DataId`, a severed version chain and re-fired events, while none of the stated harms occur: the
  shard root is unchanged, so no `Ordinal` is invalidated and nothing crosses a shard.
- **Unusable for root tables, which is the serious one.** A root table is *defined* by its key
  containing no same-family FK (`tables.md:172`), so no `unique` on a root is headed by an FK
  reaching a root, and the gate rejected **every root candidate-key change** with no escape: no
  username change, no email change, no branch rename. The resolution is that a root's candidate-key
  change is **not a re-key at all** — a shard is named by its root row's `DataId`
  (`transaction-graph.md:158`), which does not move, so nothing crosses shards and no ordinal is
  invalidated. It is an ordinary update plus a shard-directory write.

**The gate is also restated**, because the earlier phrasing admitted the collision it was written to
prevent: a second `unique` headed by a *different* FK, whose value the re-key does not change, passed
the gate and then collided with its own tombstone.

> **Every `unique` on the table must be headed by the placement key's own head field.**

Unambiguous, strictly stronger, and it is what the worked example two sections above already
demonstrates.

Ten questions the validation could not close are in [50-validation.md](50-validation.md) §E, each
with a recommendation. The two that reach other files are whether to declare
`system.graph.Transaction`, and what an existing rollup bucket reads for a column added to a live
retention chain — where Rule A as phrased would forbid the answer `aggregates.md:275-282` implies.

### `Reference` rows live on the branch shard; variant tags are allocated cluster-wide

`distribution.md:246` is right and `traits.md:330` is the stale sentence. A `Reference` row *is*
schema, schema is branch-versioned, and the local-branch workflow depends on it — an administrator
clones "the schema graph to the branch point plus its `Reference` rows" and works offline
(`distribution.md:255-258`), which is impossible if those rows live on one global shard.

The **variant tag** is not branch-scoped. Two branches would otherwise allocate tag 7 to different
names, and a merge would carry two meanings for one tag — unfixable by renumbering, because
renumbering "would silently change the meaning of every historical row carrying the old tag"
(`traits.md:340`).

> **The row is branch-versioned; the tag is cluster-wide.**

A tag allocator is a table-wide `next`, and a table-wide `next` already has a home: the constraint's
own shard, alongside its counter (`distribution.md:281-284`). No new mechanism, and the cost lands on
an operation that is already a serialized schema commit.

One consequence to state: a genuinely offline branch cannot reach the allocator, so its `Reference`
rows exist **by name** on the branch and receive tags at upload. Sound, because a local branch holds
no user data, so nothing on it was ever stored under a tag.

This closes the cross-branch collision question that D12 wanted to raise as an OQ. Do not file it.

### `:<` declares the child's FK and nothing on the parent

The left-hand name is **the field name on the child**, exactly as originally specified. The parent
retains nothing: no column, no virtual column, no reverse relation. The proposal that came back from
the design pass added a table-valued reverse column on the parent; that is **withdrawn**, and with it
every rule written to support it.

Three reasons, the third being the one that decides it:

- **It is a second spelling for a join.** `queries.md:136-146` already covers navigating against the
  reference direction, with `as` mandatory. A reverse column says the same thing a second way, which
  is the defect OQ-005 keeps withdrawing things for.
- **It puts a `*`-exclusion special case in the language** that exists only because the feature does.
- **The syntax would not look like what it costs.** A non-owned child has its own `DataId` and its
  own placement, possibly in another shard. Written as a field access, `Order { *, comments { … } }`
  hides a cross-shard fan-out; written as `Order >< Comment as c`, it looks like the join it is.
  Nesting stays available through the join plus a sub-projection, where the cost is visible.

**The name goes on the right, with `via`:**

```
table app.pm.Document : UserData {
  title : Text unique,
  :< Comment via document { body : Text, author :> User }
}
```

`via` already means precisely this — "names its FK back to the containing row" (`queries.md:227`) —
and omitting it already has a default: the parent's table name in `lower_snake_case`, the rule
`group`'s nested tables (`queries.md:230-232`) and split fragments (`evolution.md:146`) both use. Three
advantages over the left-hand spelling: no phantom field name sitting in a body where it is not a
field, no new meaning for `via`, and `deprecate` addresses the thing that exists
(`deprecate app.pm.Comment.document`) rather than a name on a table that does not hold it. The parse
stays unambiguous because the item begins with `:<`, so no left-hand identifier is needed to
distinguish it from a `FieldDecl`, and a body item starting with a token scans faster than one whose
first word is an identifier that means something different from every other identifier in the body.

```ebnf
BackRefDecl  ::= ':<' QName SubTableTraits? ( 'via' Ident )? SubTableBody?
```

Supersedes `30-integrated-grammar.md` §B.3, which carries the left-hand `Ident` form.

Superseded by this: the `BackRefDecl` bullets in `30-integrated-grammar.md` §B.9 that describe the
left-hand `Ident` as "a table-valued virtual column", its `*` exclusion, and its rejection in
`UniqueDecl`/`DefaultClause`/`RecordLit`/`OrderByDecl`. Also conflict #29 there, which folded D11's
`parent` virtual column into the reverse name — with the reverse name gone, `parent` on a `Component`
returns as the open question it was, and it stays parked with recursion.

### Pagination is a cursor, not an offset; no exact total

`LimitClause ::= 'limit' NumLit` — there is **no offset**, and none is added. The absence was never
recorded as deliberate (`offset` is not in the considered-and-rejected list, and OQ-005 still lists
"pagination config" as open), so this makes it deliberate, with the reason:

- **A cursor needs no syntax.** Given a total order, "resume after the last row" is
  `where (ordering tuple) > (last values)` — an ordinary `where`. DataCode gets cursor pagination for
  free and would have to *add* a production to get offset.
- **Offset is O(offset) and hides it.** Every shard must produce and discard its prefix so the
  coordinator can merge, and nothing in the syntax says so.
- **The one thing offset would have had going for it here does not survive contact.** Unlike SQL,
  DataCode could make offset stable, because a query pegged to a `(commit node, sample moment)` pair
  sees the same relation twice — but only if the caller threads the peg, and `at` defaults to request
  arrival (`queries.md:393`). A cursor threads the peg and the position in one token; an offset
  requires the caller to remember to.

**No exact total.** `100 of 100+` is the signal, produced by fetching `limit + 1` and discarding the
extra — exact for the "is there more" bit, one row of cost, no query-language feature. Where a real
total is wanted it is a separate query, and the language already has it: `count (Order where total >
100)` is an ordinary function application returning a scalar (`queries.md:251-262`). An exact footer
would otherwise have meant running the whole query, which is the cost `limit` exists to avoid.

`100 of 100+` is a CLI display convention, not grammar. It applies to the `table` and `json` output
formats and not to `csv` or `raw`, because a pipe cannot carry a footer and a silently truncated
export is worse than a slow one.

**`limit` requires a total order**, and it comes from an explicit `order by`, else the source's
declared one, else candidate key ascending. **Any stated order is extended by the candidate key as a
final tiebreak**, because `order by placed_at desc` is not total: fifty orders sharing a timestamp
put a page boundary mid-tie, and a resume predicate then either skips the rest of the tie or repeats
it. `limit` on a degenerate-keyed source that declares no ordering is a compile-time error.

**A truncated result prints its own continuation.** The admin should not have to reconstruct the
cursor:

```
 placed_at            | total
----------------------+-------
 2026-08-27T14:02:11Z | 99.99
 …
100 of 100+
next: Order at "05KG3N0000ZQ8V4T1H7C" where (placed_at, id) < ("2026-08-27T14:02:11Z", "05KG…")
        order by placed_at desc limit 100
```

Four rules make it correct rather than merely helpful:

- **It carries the `at` peg.** Without it the continuation runs against a moved relation, which is
  the exact failure the cursor was chosen over offset to avoid — `at` defaults to request arrival
  (`queries.md:393`), so a pasted predicate with no peg is unstable.
- **It uses the effective ordering tuple, tiebreak included.** This is what the rule above is for;
  without the key in the tuple the printed predicate is wrong at a tie boundary.
- **It prints only when truncated**, and not in `csv` or `raw`.
- **Mixed directions degrade honestly.** `order by a desc, b asc` cannot be written as one tuple
  comparison; it prints the expanded form (`a < x || (a == x && b > y)`), which is uglier and
  correct. Worth stating so nobody assumes the tuple form always applies.

### `LogData` gets two secondaries; `system.logs.HttpRequest` relaxes geography

`distribution.md:110-136` is right and `transaction-graph.md:117,131-136` is the stale text.
`LogData` carries two secondaries under the **batched** durability class — the primary commits when
its own append is durable and ships accumulated deltas afterwards — so log volume never puts two
network round trips on the hottest path.

`system.logs.HttpRequest` was the case that motivated the "server-local" language, and it needs less
protection than a violation log does. The relaxation is **geographic, not role count**, which is
exactly the shape `distribution.md:519-538` already gives cold shards: *three role holders always; a
dump is not one of them.* One rule, two callers. Its secondaries may sit in the same region, or the
same rack, which is also what makes the bandwidth cheap.

Both knobs are the same decision seen from two sides — how much do you mind losing this — so they
belong on one `Configuration` row keyed by table path, resolved most-specific-first:
`system.shards.DurabilityPolicy`, which `distribution.md:128` already names and never declares.

Six places say the old thing and need correcting: `transaction-graph.md:117` (the shard-type table),
`transaction-graph.md:131-136` (the paragraph), `traits.md:104` (the replication table),
`api.md:220` ("not cross-replicated"), `documents.md:164` ("server-local under `LogData`"), and
`transaction-graph.md:273-274`, whose locality argument survives but whose premise does not — a
segment is still contiguous on the server that wrote it, it is simply no longer the only place it
is read.

## Clusters

The corpus divides into nine clusters. Coupling runs left to right; `railroad.md` and
`open-questions.md` are cited by every one of them.

| Cluster | Files | Findings |
|---|---|---|
| Foundations | `README.md`, `vision.md`, `category-model.md`, `schema/README.md` | 30 |
| Schema core | `schema/railroad.md`, `types.md`, `tables.md`, `traits.md` | 79 |
| Query and evolution | `schema/queries.md`, `aggregates.md`, `evolution.md` | 68 |
| Functors and functions | `schema/functors.md`, `constraints.md`, `functions.md` | 62 |
| Documents, templates, namespaces | `schema/documents.md`, `templates.md`, `namespaces.md` | 71 |
| Engine | `transaction-graph.md`, `storage.md`, `distribution.md` | 76 |
| Runtime | `tech-stack.md`, `dynamic-loading.md`, `events.md` | 79 |
| Interfaces | `cli.md`, `ide.md`, `api.md`, `api-and-rendering.md` | 74 |
| Ops and security | `auth.md`, `integrity.md`, `connectors.md` | 67 |
| Cross-cutting sweeps | grammar conformance, links and anchors, OQ drift | 134 |

## Health verdict

The *decisions* are in good shape. `open-questions.md` is a genuinely strong decision record, the
load-bearing invariants hold up under attack, and the categorical framing is doing real work rather
than decorating an ordinary design — the structural reading of an assert's variety, the missing
`Effect → Tx` lift, and the key-declaration-is-the-sharding-declaration rule are each the kind of
move that pays for the theory.

What has drifted is the **mechanical layer**. `railroad.md` calls itself the single source of
syntax truth, and it has fallen behind the prose it governs: 76 verified findings are a snippet that
does not derive or a production that contradicts its own stated constraint, and several of those are
the *normative* spelling of a settled decision. The defects are concentrated rather than diffuse,
which is good news — most of it is one afternoon of grammar repair.

By category, over the 640 verified findings: 212 contradictions, 152 underspecified, 67
theory errors, 53 examples that do not parse, 49 redundancies that have drifted, 42 naming drifts,
24 OQ drifts, 23 grammar mismatches, 15 style, 2 broken links, 1 type error. 37 are blockers.

Second-largest is **system tables and types that are used but never declared**. Third is
**redundancy that has already drifted**: eleven rules are stated normatively in two or three files
and the copies now disagree.

## The eight structural defects

Each of these would have cost a rewrite if it were found during implementation rather than now.

### 1. The assert grammar cannot express asserts

Four separate failures, one root cause: `AssertBody ::= Expr | Query` admits a query *or* an
expression, never a query inside an expression.

- **`not $ <Query>` has no parse.** `NotExpr ::= 'not' '$' Expr`, and `Expr` reaches `Query` only
  through the `'(' Query ')'` atom. `assert payable { not $ self >< Account >< Suspension … }`
  (`constraints.md:147`) is the normative spelling of an absence assert and it does not derive.
- **A bare `Query` cannot be an operand of `||`.** OQ-005 makes `||` inside one assert the
  *mandatory* spelling for access alternatives — "alternatives are `||` inside one assert rather
  than several asserts" — and `constraints.md:83-87` and `auth.md:108-112` both write it. No
  production admits it.
- **`StandaloneAssert ::= 'assert' QName '{' Expr '}'` admits only `Expr`.** A binding has no body,
  so standalone is its *only* form — which means no derived table can carry a presence or access
  assert at all. `auth.md`'s `secondFactorForAdmins` is exactly this shape.
- **`Binding ::= Ident` forbids a namespaced derived table.** `system.auth.ServiceAccount = …`
  appears in `auth.md`, `namespaces.md`, `aggregates.md` and `open-questions.md`, and parses in
  none of them. `TableDecl` uses `QName`; `Binding` should too.

Fix: `AssertBody ::= Expr`; add `'(' Query ')'`-free query atoms by admitting `Query` at `Atom`
under a non-emptiness coercion, or — cheaper and more Haskell-shaped — lift the existing
"a `Query` in boolean position asserts non-empty" rule from `AssertBody` to *every* `Bool`
position. That one change fixes all four and is also the best available answer to the `in`
operator (below).

### 2. Append-only has four exemptions, not one

"The `QueueState` field is the one exemption from append-only in the whole system" appears in
`traits.md`, `events.md` and `railroad.md` as a selling point. Three other fields are mutated:

| Field | Where | Mutated by |
|---|---|---|
| `system.integrity.Violation.state` | `integrity.md:209,313` | an ordinary operator mutation |
| `system.auth.Challenge.state` | `auth.md:149` | consuming the challenge |
| `system.events.TriggerState.held` | `events.md:186` | the scheduler, every tick |
| `Queue.scheduled_at` | `events.md:231` | retry backoff, against the queue's own rule 4 |

`TriggerState` is the worst of them: a `LogData` table holding one bit that must be overwritten per
`(trigger, row)` per tick, with no `retain` chain, so it is also unbounded.

Related and equally load-bearing: `system.integrity.Violation` is described as **a materialized view
over a query** (`integrity.md:53-58`), as **an ordinary `LogData` table sharded with its subject**
(`:258`), and as a table you **insert into by hand** (`:317`). Three authorities for one table.

### 3. `id` does not exist

Six documents filter, update and project on an `id` column. The virtual columns are `created_at`,
`origin_server`, `updated_at`, `ordinal` and `grain` — there is no `id`. Compounding it,
`"uuid-..."` is used as its value in `queries.md` while a `DataId` renders as 20 characters of
Crockford base32, and `cli.md`'s identifiers are 18 characters where `transaction-graph.md` and
`api.md` use 20.

### 4. Withdrawing `from` left a hole

`SourceClause` was withdrawn with `rename from`, because a projection expresses a rename. But the
*other* user of `from` was resolving a multiple-inheritance field collision by rename
(`traits.md:64`, restated at `schema/README.md:278`), and a projection cannot appear in a
`TableBody`. There is now no way to keep two colliding trait fields under different names.

### 5. `retain` chains contradict their own constraints

`drop` is a `ChainStep`, so it is subject to "every later step must carry `by`" and to "`as` is
required if the chain has more than one step". Every `, drop`-terminated chain in the repo —
including the one in `CLAUDE.md` — therefore violates both. `RetainDecl` needs `Chain ::= ChainStep
(',' ChainStep)* (',' 'drop')?` with `drop` as a terminal rather than a step.

### 6. Routing has no table

The **range tree** decides which server serves which key range and is invoked as authoritative in
three documents. It has no table name, no fields, no key, and no type for its heterogeneous bounds.
The **cluster shard directory** (`username → DataId → shard`) is invoked as free by three documents
and has no root, no primary, and no registration protocol. `system.auth.Grant` is written to by two
CLI commands and declared nowhere; so is `system.shards.DurabilityPolicy`.

Types used in normative declarations and defined nowhere: `TypeRef`, `TableRef`, `FormatRef`,
`ServerId`, `TokenId`, `HttpMethod`, `Html`, `NamespaceRef`, `TemplateBody`, `ChallengeCode`.
`api.md:43` also writes `methods : [HttpMethod]`, a list type the grammar has no production for.

### 7. `LogData` replication contradicts itself

`transaction-graph.md:117` and `traits.md:104` say `LogData` is server-local and does not replicate
to peers. `distribution.md:110-136` gives it two ACKing secondaries under a batched durability
class. Both are stated normatively. The batched reading is almost certainly the intended one — it is
newer and better argued — but `system.logs.HttpRequest` is described as per-server in three places
that depend on it.

### 8. The connector document is written in a different language

`connectors.md`'s two schema blocks use `Enum(...)`, `UUID`, `UUID?` and `_ms Int` — a nullable
marker, a type DataCode does not have, and a construct the project's first differentiator rejects.
You flagged this; it is worse than you said. `sync_status` is not merely a non-ADT enum, it is a
mutable column on a `LogData` table, and `connector_config` duplicates
`system.connectors.Connector`, which is itself declared twice more (in `events.md` and `cli.md`)
with three different field sets.

## Theory notes

Full citations in `40-bibliography.md`. Six claims need adjusting.

- **`vision.md:5` says data elements are the objects of the schema category.** `category-model.md`
  and Spivak say tables are, and instances are set-valued functors *on* the schema. Correct
  `vision.md`.
- **Spivak & Wisnesky's FQL requires key generation** for Σ-style migration. That is in direct
  tension with `queries.md`'s "keys are computed, never declared". Say which of Δ, Σ, Π a DataCode
  coercion is — the answer is almost certainly Δ (pullback along a schema morphism), which is the
  one that needs no key generation, and saying so strengthens the claim rather than weakening it.
- **Johnson & Rosebrugh give the exact criterion for a writable derived table**: a view update has a
  universal solution exactly when the view functor is a Grothendieck opfibration. That is sharper
  than the three conditions in `queries.md:543-550` and it is the categorical statement of the same
  fact. Cite it; it is the strongest available support for the write-through design.
- **"Access rules can be checked statically for consistency and completeness"** appears in four
  places, is not what `spikes/functor-dsl` computes, and no OQ tracks it. Consistency (no
  contradiction) is decidable for the anchored fragment; *completeness* of an access policy is not
  a defined property. Weaken the claim or define the property.
- **The denotative claim is stated in one coordinate and the design uses two.** A query is pegged to
  a `(commit node, sample moment)` pair, so DataCode is denotational in schema-position *and* in
  time. `category-model.md:97-99` states only the second. This is a strengthening, not a defect —
  Elliott's discipline applied twice is a better story than applied once.
- **The zero-copy read path has no reader-visibility discipline.** Relocation and scrub rewrite
  bytes under live `mmap` readers with nothing stated about it. Crotty et al., "Are You Sure You
  Want to Use MMAP in Your DBMS?" (CIDR 2022) is the standard reference for exactly this hazard and
  should be cited and answered, not ignored.
- **The prepared-node protocol has no validation phase at commit.** Neither participant re-checks
  its read set before the commit node lands, and "the only outcome is an abort" is backwards —
  without a re-check the outcome is a *lost* conflict, not an abort. Gray & Lamport's
  consensus-on-transaction-commit is the right frame.

## The sixteen requested changes

Detail and full argument in `20-syntax-decisions.md`; the conflict-resolved grammar is in
`30-integrated-grammar.md`. **Net reserved-word change across all sixteen: −1.**

| # | Your ask | Verdict | Cost |
|---|---|---|---|
| 1 | Large files in the database | **Adopt a `File` type; DataCode is the origin; `Read`-readable** | 0 productions, 0 words |
| 2 | `Text 255` / `Text 1 255` | **Reject the syntax; use `where maxLen 255`** | 0, 0 — the feature exists |
| 3 | Client token types, `authed_client`, unify with server | **Adopt unification; reject `authed_client`; `Client` + `Registration`** | −2 words |
| 4 | Regex templates, alnum arguments, the library | **Keep the restriction, fix its stated reason; defer parameterisation** | 0, 0 |
| 5 | `in` operator with array and query RHS | **Spell it `` `elem` ``; multi-field is a `RecordLit`** | 1 production, 0 words |
| 6 | Kill long-running queries | **Adopt `cancel`; defer the `Ephemeral` trait it arrived with** | 2 productions, 1 word |
| 7 | Pre-hashed password ingest | **Adopt `preHashed <policy> "<digest>"`** | 0, 0 |
| 8 | CLI: shard split, pagination, DataIds, split-brain | **Three of four adopted; `split shard` was never removed** | ~6 productions, 0 words |
| 9 | Connectors: GTID, syntax, `connector_id` | **All three right; GTID needs no library fork** | 1 changed, −2 words |
| 10 | LMDB or SQLite for materialized views | **Neither — a view is a derived table in ordinary storage** | 0, 0 |
| 11 | Row-number column; recursive query | **`numbered <table>`; defer recursion** | 0, 0 |
| 12 | Reference autoinc; MariaDB autoinc | **Premise half right; key shadows on the source PK** | 0, 0 |
| 13 | Multi-table insert from virtual tables | **Adopt as a table *literal*, `[ {…}, {…} ]`** | 3 productions, 0 words |
| 14 | Automatic nesting, JSON in/out, dump to file | **Adopt; nest in the projection, not a `nest` clause** | 3 productions, 0 words |
| 15 | `Default` as an injected type | **Reject; and the free replacement does not fully cover it** | 0, 0 |
| 16 | `<:` backreference for linking tables | **Adopt, spelled `:<`; now scoped to non-owned children** | 1 production, 0 words |

### Where I am pushing back

**Item 2 — bounded `Text`.** `Text 255` and `Text 1 255` are *already grammatical*
(`Variant ::= QName TypeArg*`, `TypeArg ::= QName | Literal`), so this is not a grammar question.
It is a question of whether a length cap is a **type** or a **validation**, and it must be a
validation, for a reason that decides it: a type-level cap makes over-length connector data
*untypeable*, and `integrity.md`'s whole ingestion posture is that connector-sourced rules default
to `monitor` so one bad row cannot halt a binlog. A cap you cannot set to `monitor` converts a data
problem into an outage. `where maxLen 255` is already used in six files. What is genuinely missing:
`maxLen` and `minLen` are used eight times and **defined nowhere**, and "255 characters" has never
been pinned to code points, bytes, or grapheme clusters. Fix those two things and the feature ships
with no syntax at all.

**Item 5 — `in`.** `in` is already reserved by `let … in`, and admitting it as a comparison operator
creates a real ambiguity: `let x = a in b` cannot be told from a `let` whose binder body is a
membership test. The proposed disambiguation ("the first `in` at bracket depth 0 closes the
binder") does not count `let` nesting and breaks `let a = let b = 1 in b + 1 in a * 2`, which parses
today. DataCode already has backtick infix at Haskell's fixity, and `Data.List` is auto-available,
so `` status `elem` [Pending, Shipped] `` costs one bracket-literal production and nothing else.
Your multi-field ask is served by a tuple LHS, not an array LHS — a list is homogeneous and a row is
not.

**Item 8 — `split shard`.** You are remembering the withdrawal of the `split`/`merge` *table*
statements (OQ-005). `split shard … at key` is alive and OQ-007 is ✓ ANSWERED keeping it: a
`UserData` split moves write authority, so it cannot be automatic. You are directionally right about
something else though — `split shard` is quietly much narrower than the docs imply, because
splitting a shard with one root row yields a **shard group sharing a primary**, which splits storage
and read capacity but never write authority. The example on `cli.md:118` is broken regardless: it
uses a uuid, and DataIds are not uuids.

**Item 11 — row numbers.** You already have most of it and the missing piece is smaller than a
window function. `group` *nests* rather than aggregating away, so "position within a partition" is
position within the generated `rows` column — an ordinary table. Making `row_number` a virtual
column would be a correctness hazard, because virtual columns are key-eligible and a row number
changes when an unrelated row is inserted; a materialized view keyed on position would renumber its
whole extent on one insert. `numbered <table>` — an ordinary function returning the table plus a
generated `n` column, exactly as `group` generates `rows` and `diff` generates `before`/`after` —
costs no grammar, no reserved word, and takes its ordering as a parameter instead of reading it from
an enclosing clause. It gives you `lag`/`lead` by self-join on `n-1` and running totals; it does not
give you `rank`/`dense_rank` (they differ on ties) or frame clauses. **Recursion is a separate and
larger thing**: there is no recursive production anywhere, OQ-001 lists recursive types as an open
DSL ceiling, and transitive closure is famously not expressible in first-order relational algebra —
so it needs a real construct, and the obvious one (`via manager+`) is blocked on a tension you have
not settled: `tables.md:207` rejects a `Null`-derived variant in a key, and every tree root's
self-FK is nullable.

**Item 15 — `Default`.** The proposal is elegant and I recommend against it, on one argument:
`is` would have to carry two contradictory meanings. Take `phone : Phone | NotGiven = NotGiven`. If
`Default` wraps the value, `phone is NotGiven` is **False** on every defaulted row — the absence
check, which is the single most load-bearing thing in a language with no NULL, breaks silently. If
`is` sees through `Default`, the feature does nothing. The only escape is a constructor that `is`
treats specially, which is the magic-`access`-identifier defect OQ-005 already withdrew once.

Being straight about the replacement: the free answer, `Order where total.updated_at /= created_at`,
finds fields **changed since the row was created**. It does *not* distinguish "supplied at insert"
from "defaulted at insert", because both land at the row's `created_at`. If what you want is
genuinely "which values did a human supply", that costs a supplied-field bitmask on the row version,
and I would hold it until merge semantics are written — otherwise the mask reads all-ones after any
merge and the feature it is justified by does not work. Worth asking: was the `Default` keyword
actually about a *record-literal expression* — `{ total = default }`, meaning "write whatever the
schema's default currently is"? That is a much smaller thing and needs no type.

**Item 16 — `:<`.** Adopt it, but spell it `:<`, not `<:`. `<:` is the subtyping operator in type
theory, Scala, F<:, and Julia, and DataCode's `:` already *means* subtype — `type Email : Text` is
`Email <: Text`. So `comments <: Comment` is a well-formed sentence saying the wrong thing, which is
worse than a parse error. `:<` joins the `:` munch family beside `:>`, reads as its mirror, and
costs no reserved word.

**Settled above**: a `Component` `:>` field is table-valued, so **1:many inline declaration already
exists** for owned children. `:<` therefore scopes to children that are *not* owned — true linking
tables, and children with independent lifetime and their own shard placement. That is still worth
having, and it is a much smaller change than the original proposal, which was trying to cover both.

The remaining live objection is worth answering rather than dismissing: `auth.md:476-500` plus
`queries.md:527-557` is already DataCode's idiom for "the linking table needs a second statement" —
declare it once, then bind a writable derived table over it, and the call site never names it. `:<`
does not replace that; it removes the second *declaration*, where the binding removes the second
*call site*. Both are worth having, but the docs should say which is for which, or authors will
reach for `:<` where a binding is the better answer.

### Where the request was already served

**Item 10 — LMDB or SQLite.** Neither, and the question dissolves: `storage.md:257-259` already says
materialization is a storage decision and that a table, a query and a derived table are one kind of
thing. Taken seriously, a view's rows *are* rows — they already have a format, an index, a locator
indirection, a compactor, a scrubber, a backup story and a wire protocol. SQLite adds a second of
each, plus a serialization boundary that breaks the zero-copy claim for that path. The only genuinely
new physical concepts are a **derived extent** (droppable, unreplicated) and an **arrangement** (one
LMDB sub-db per view and order) — and an arrangement is also what an index is, which is the physical
content of "materialization replaces the user-defined index". DuckDB is worth having as an
Arrow/Parquet *export target* from a tertiary; never as an engine.

**Item 9 — GTID.** All three of your complaints are right. On the library: `mysql-haskell` 1.3.0
exposes no GTID support at all — `BinLogTracker` is filename-plus-offset and there is no
`COM_BINLOG_DUMP_GTID` — but `Database.MySQL.Connection` is an exposed module with `MySQLConn(..)`,
`writeCommand` and `putToPacket`, so DataCode can speak GTID against the published API in roughly
150 lines with **no fork**. Note that MariaDB (`domain-server-sequence`, `@slave_connect_state`) and
MySQL (`uuid:txn`, GTID SET) are incompatible schemes; decide whether that is one connector with two
modes or two connector kinds. The GTID is also the natural idempotency key, which is what makes a
replayed event a no-op rather than a duplicate.

**Item 4 — regex.** The library is `regex-tdfa` (module `Text.Regex.TDFA`), added to `build-depends`
and fetched by `cabal build`; `functions.md:117` already lists it as always-available. The
substantive finding is that **the docs' stated reason for restricting the `=~` right-hand side is
false**: "TDFA is a DFA engine, so a pathological pattern costs no more than a linear scan"
(`railroad.md:535-537`) does not hold — TDFA builds its DFA lazily and caches states, and a
ten-character pattern was measured exhausting a 3 GB heap. Keep the restriction; replace the
justification with the real one (provenance, transparency, and a commit-time pattern budget). Also
worth knowing: TDFA defaults to `multiline = True`, so every `^…$` predicate written so far is
bypassable by an embedded newline, and its POSIX character classes are ASCII-only.

On "alnum arguments": alnum is the wrong safety property. Digits are alnum and `a{800}` is the
attack. The property you want is **positional** — an argument may only ever occupy an atom position
in the parsed pattern — which is a structural rule, not a character-class rule. That said, the
motivating example does not typecheck where it was written, and the repaired residue is already
expressible today by putting the pattern in a `Reference` row and reaching it by FK from an assert.
So: defer parameterisation, ship the corrections.

## Implementation plan

Phase 0 is blocking. Phases 1–5 are ordered by dependency; 5 runs in parallel with the rest.

### Phase 0 — settle five contradictions (no new syntax)

Each is depended on by two or more of the sixteen items, and three were asserted in opposite
directions by different designers in this batch.

| # | Question | Blocks |
|---|---|---|
| 0.1 | ~~Is a `Component` `:>` field one row or many?~~ **Answered: table-valued.** Write the rule and its six consequences into `tables.md`. | items 11, 13, 14, 16 |
| 0.2 | Does `retain` reach `UserData`, and is there any row-level `prune`? | items 1, 9 |
| 0.3 | Do `Reference` rows live on the `system` shard or the branch shard? | items 9, 12 |
| 0.4 | What does an evolution-added field read on old rows — the default, `NotFound`, or `NotGiven`? | items 12, 15, 16 |
| 0.5 | What does `limit` mean? It is in the grammar and appears nowhere in `queries.md`. | items 8, 11 |

Also in Phase 0, because they are pure repair and everything downstream reads the grammar: the
eight structural defects above.

### Phase 1 — lexical and literal foundation

`[` and `]` as tokens · `TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'` in `Atom` and `Source` ·
the position-fixes-the-row-type rule for elements · `` `elem` `` documented as the membership
spelling · the `:` maximal-munch row corrected to include `:<` and the seven `MetaCommand` literals.

Delivers literal sets, a table value usable as a join source and a binding right-hand side, and the
base that items 13 and 14 both need.

### Phase 2 — query surface

- **2a** `ProjItem ::= FieldPath Projection? NameClause?` — one nesting rule that absorbs the
  `nest` clause *and* the query side of `:<`, with the `*`-exclusion and nested-ordering rules.
- **2b** `numbered <table>` and its generated `n` column.
- **2c** `ShowCmd`/`ShowTarget`/`ReportClause` restructure, `--limit`, `system.config.PageSize`, and
  a desugaring table naming which system table each `show` target reads.
- **2d** `Insert ::= QName RecordLit | Query TableLit`, decomposition by base-table key,
  `max_transaction_rows`.

### Phase 3 — declaration surface

`:<` (blocked on 0.1) · `Blob` (disposal path rewritten against 0.2) · `minLen`/`maxLen` defined ·
`preHashed` · the regex corrections.

### Phase 4 — administration

`ShardRef`/`ShardRange` · `cancel` · `ExportCmd` with `system.export.Destination` · `Resolution ::=
QName` (unreserving `DataCode` and `External`) · every `Ident`-typed identifier argument retyped
`StringLit`, because a rendered `DataId` begins with a digit and cannot lex as an `Ident`.

### Phase 5 — storage and distribution (no grammar, longest lead)

Derived extents and arrangements · GTID connectors · epoch and fencing with a two-of-three ACK ·
the `Reference`-tag documentation fix.

### Deferred, with reasons

| Item | Why |
|---|---|
| Recursion / closure | Real new expressiveness, orthogonal, blocked on the `Null`-in-key vs. tree-rooting tension |
| `in` as an operator | `` `elem` `` covers it; revisit only if the `let` rule can be stated soundly |
| `Ephemeral` trait | Decide at its own scope, with `show replication lag` and the generation table on the table |
| Supplied-field mask | Justified only by merge reconciliation, which is not designed |
| `.dc` export format | Blocked on the table literal *and* on a scrub-replay rule for re-import |
| Parameterised regex | Motivating example does not typecheck; repaired residue is already legal |
| `Default a`, `Text 255` | Rejected on the merits. Record the reasoning; build nothing. |

## Doc rewrite

When the docs are rewritten, four rules do most of the work:

1. **Repair `railroad.md` first and regenerate every example against it.** A linter that extracts
   fenced blocks and parses them against the EBNF is the durable fix; without one this drifts again.
2. **Delete the eleven duplicated rules.** `bypass access` is stated normatively in four files;
   `Queue`/`QueueState` in two; grain alignment in three; the violation retention chain in three;
   the `system`-is-a-namespace rule in three; connector configuration in three. Each pair has
   already drifted.
3. **Declare the missing tables and types, or stop referring to them.** Twelve types and seven
   system tables are load-bearing and undeclared.
4. **Move `open-questions.md`'s answered content into the normative files.** Several answers exist
   only in the OQ entry, which `CLAUDE.md` already forbids.

`10-findings.md` gives every one of these an exact location and a proposed edit.
