# Category model

## The governing monad

DataCode's runtime is a **graded monad**, indexed by the effect lattice `Pure ≤ Read ≤ Tx`, beside a separate `Effect` monad that exactly one arrow reaches: `commit :: Tx a -> Effect a`. Every operation that reads or writes data, validates a type, traverses a relationship, or checks authorization is a computation at one of those grades.

The grading is what carries the design, not the monad. The load-bearing property is that one lift is **missing** — nothing takes `Effect a` back to `Tx a` — and within a single monad every computation composes with every other, so a single monad could not state it. The ladder and what each grade admits are in [schema/functions.md](schema/functions.md#the-effect-ladder).

Every grade carries the same reader environment:

- The current point in the schema transaction graph (what schema version applies)
- The current authentication context (what tokens are active)
- The current shard topology (where data lives)
- The evaluation environment (what types and functions are loaded)

None of the four is read from the world. Each is threaded in — the same discipline [denotative time](#denotative-time) applies to the clock.

Schema authors do not define monads. They define **functors** — the rules that apply to custom data types within the runtime.

## Functors

A functor in DataCode is a named, transparent rule attached to a schema object, encoded as a term in the effect-indexed GADT DSL and interpreted by the runtime rather than compiled (OQ-001, [dynamic-loading.md](dynamic-loading.md)). There are four functor kinds, each applied on an as-needed basis per type or relationship.

The word is DataCode's term of art, and it is looser than Spivak's. In the formalism cited below the functors are the instance assignment `I : C → Set` and the schema morphisms that induce a migration; a foreign key is a *morphism* of the schema category, and a validation predicate or an event trigger is neither. The naming is settled and pervasive, so this document keeps it and says once what it means.

This document is the *why*; [schema/functors.md](schema/functors.md) is the operational reference (signatures, when each runs, surface syntax).

### 1. Type validation functors
Applied to individual fields. Enforce invariants on values within a type:
- Range checks, format validation, referential integrity within a field
- Example: `Email` type with a functor that validates RFC 5322 format
- Automatically applied whenever a value of that type is constructed or mutated
- Written as a `where` clause on a type or field declaration

### 2. Foreign key functors (relational functors)
The primary set/relational connection between tables. Map objects in one table to objects in another:
- Encode the "arrows" of the schema category
- Compose: a foreign key chain is morphism composition — Kleisli composition in `Either Error`, given the signature `DataId → Either Error Row`
- Carry provenance: the query result type retains the chain of functors that produced it
- Written with the `:>` field token

### 3. Path constraint functors
Constrain what is reachable from a row through the schema graph. The original and still the central case is commutativity: if two different paths through the schema should produce the same result, a path equivalence encodes that requirement:
- Based on David Spivak's formalism for database schemas as categories (see *Functorial Data Migration*)
- Applied during mutation validation; the access variety also runs on read (see below)
- Written with `assert`

Equivalence is not the only proposition worth asserting about a neighbourhood, and restricting the kind to it made two ordinary requirements inexpressible: that a linking row *exists* along some path, and that none does. Neither is an equality, and neither can be forced into one — every *forward* path in the schema graph is single-valued by construction, so an equality-only assert had nothing to quantify over. Presence and absence quantify over the reverse direction of a `:>` edge, which is a relation rather than a function. The kind is therefore **path constraint**, `Row → Either Error ()`, with three shapes: an equivalence between two paths, a rooted subquery asserted non-empty, and its negation. The comma-category framing is what makes the last two well-posed rather than ad hoc — the set a presence assert quantifies over is a fibre, the preimage of the row under a declared morphism, which is a construction on the same diagram the equivalence case constrains.

This is a single functor kind with **two varieties**, distinguished only by whether the requesting token is one of the terms:

**Data constraint** — every term is a data path from the row.
- Example: `order.customer.billing_address` must equal `order.billing_address` at commit time
- The primary mechanism for enforcing business rules that span tables

**Access constraint** — the requesting token is one of the terms.
- Evaluated per row, and per row is the finest granularity there is: a failed assert redacts the whole row, key included, and the only coarser unit is the namespace subtree a grant covers. There is no per-edge traversal right — see [schema/constraints.md](schema/constraints.md#redaction-scope)
- Reaches other tables exactly as a data constraint does, by traversing declared `:>` edges from the row
- Recognized structurally, by the token binding appearing in the body — not by a name, so that the set of rules an administrator's grant exempts is exact rather than conventional

The two are *structurally identical* apart from that one term, which is why they are one kind rather than two. That identity is the payoff of the categorical framing: authorization is not a bolt-on subsystem with its own semantics, it is the same commutative-diagram machinery pointed at the authentication context. Consequences follow for free — one structural walk over the assert term answers the same questions for both varieties, and both render as edges in the same schema diagram.

What that walk decides is bounded, and an earlier claim that access rules can be checked statically for consistency **and completeness** is withdrawn. Containment between two access rules is decidable only for the positive conjunctive fragment, which is what anchoring at `self` guarantees; a body carrying `not`, `=~`, or a user-defined predicate is not attempted, and the checker reports "cannot decide" rather than "consistent". Completeness is worse than undecidable: under default-deny an ungranted row is the normal case, so "no gaps" is not a well-formed property without a specification to compare the policy against, and there is none. [schema/functors.md](schema/functors.md#path-constraints-and-their-two-varieties) lists what the walk does compute.

Where they differ is only in evaluation timing, and that difference is derived rather than stipulated: a data constraint has nothing to check until a mutation is proposed, so it runs at commit; an access constraint is meaningful on any traversal, so it runs on read as well. On a failed read the row resolves to `Redacted` rather than aborting — absence is typed, so "you may not see this" is expressible in the result rather than only as an error.

### 4. Event functors
Schedule a deferred effect rather than enforcing an invariant. An event functor maps a committed row to an `EventRef` — a work item inserted into a queue table — instead of to `Either Error a`:
- The only functor kind that cannot abort a commit; inserting the queue row *is* the commit
- Keeps the category closed under composition: an external side effect would not be a morphism in the schema category at all, so it is reified as data (a queue row) that later processing consumes
- This is why "no external calls inside a transaction" is a structural consequence of the model, not merely an operational policy
- Written `on <condition> emit <queue> { <payload> }`, or `every <interval> emit <queue> { <payload> } where <condition>`, on the producing table, with `handler` on the queue (OQ-030). See [schema/functors.md](schema/functors.md#event-functor) and [events.md](events.md#triggering-an-event)

## Reified failure

The event functor's design move — an external side effect cannot be a morphism in the schema
category, so it is reified as data (a queue row) that later processing consumes — applies a
second time, to a different problem.

A validation functor rejects. Rejection is total and synchronous: the transaction does not
happen. But a rule can be introduced *after* data exists, and the data cannot then be
retroactively rejected without mutating history, which the transaction graph forbids. The
category has no morphism for "this row that already exists should not have".

So the failure is reified the same way the side effect is: a **violation** is a row that records
`(subject_table, subject)`, the violated functor, and the schema node. What cannot be an arrow
becomes an object. The full row, and why the subject is an explicit pair rather than a bare
`DataId`, are in [integrity.md](integrity.md#the-violations-table).

Three properties follow, and none of them is an added feature:

- **Validity is a relation, not a predicate on rows.** A row is conforming *at a schema
  node*. The same row is conforming at one node and not at another with no contradiction,
  because the functors attached at those nodes differ. This is the same relativity that makes
  historical queries work at all.
- **Repair and revision are the same operation, applied to different sides.** A violation is
  discharged either by changing the subject or by changing the rule — and changing the rule
  on a branch is an ordinary schema commit. Sometimes the data is right.
- **Enforcement mode is a property of the attachment, not of the functor.** The functor is
  the same object whether it rejects, records, or enqueues a repair; what changes is what the
  runtime does with the `Left`. Keeping the mode out of the functor is what lets it stay
  transparent and analyzable.

The operational treatment is in [integrity.md](integrity.md).

## Denotative time

DataCode is a **denotative, continuous-time** system in Conal Elliott's sense: every construct
inside the effect ladder — `Pure`, `Read`, `Tx` — has a meaning as a mathematical function,
independent of how it is evaluated, and time is a continuum that computations are parameterised
over rather than a clock they consult. Handlers are deliberately outside the discipline. They
run in `Effect`, are not inspected, not replayed and not solvable, and the missing lift is what
keeps them out.

Three prohibitions that were adopted for unrelated reasons turn out to be exactly the
discipline this requires, which is why it fits rather than being retrofitted:

| Existing rule | What it buys |
|---|---|
| No lift from `Effect` into `Tx` | No functor can read the clock or call out. Time can only arrive as a parameter — the whole denotative discipline, already enforced. |
| Append-only, no in-place update, idempotent records | Along one branch, a row's history denotes an `Event a ≅ [(Time, a)]`. Across branches it is a tree, so a query resolves the branch before the moment. |
| Views are queries pegged to a `(commit node, sample moment)` pair | Materialisation is already sample-at-a-point, not cached mutable state. |

The two FRP primitives are therefore already present. `Event a` is the transaction log
filtered to a subject, along one branch. `Behavior a ≅ Moment -> a` is what a query's `at`
clause has always computed for stored fields — the value of a row at a chosen point —
generalised so that a field may vary between writes as well as at them. See
[schema/types.md](schema/types.md#behaviors).

**The peg has two coordinates, not one.** A query denotes `(CommitNode, Moment) -> Table`, and
`Behavior a ≅ Moment -> a` is the special case at a fixed node. Both are needed: which fields
exist is a function of the graph point rather than of the moment, so under `Moment -> a` alone a
query over a schema-evolved table has no well-defined meaning. Elliott's discipline applied in
schema position as well as in time is a stronger claim than applying it once, not a weaker one.

The types are present; a combinator library deliberately is not. There is no `Applicative` over
`Behavior`, no `stepper`, no `switcher`. What DataCode adopts is the denotational method — fix
the meaning first, take time as a parameter — and `on <behavior condition> emit` is its one
`Behavior`-to-`Event` operator.

What the framing adds is not expressiveness but *closure*. A stored field changes only when
something writes it, so "when does this become true?" has been answerable only by polling. A
behavior is a function, so the question has a solution rather than a search, and the event
scheduler can ask it directly. That is what makes an external event functor a declaration on
the table it belongs to instead of a queue row someone remembered to insert
([events.md](events.md#triggering-an-event)).

The restriction to a closed-form-solvable class of behaviors follows from the same place. An
arbitrary `Moment -> a` can be sampled but not solved, and a scheduler that can only sample is
a poller. The class is a constraint on the *category*, not a performance concession.

The class itself, the per-class solver, and their encoding in the DSL are open — see OQ-034.
Until they land, an open-form behavior is sampled with `every`, which is polling with bounded
lateness and a `system.events.TriggerState` bit per `(trigger, row)`. See
[events.md](events.md#behavior-triggered-scheduling).

A behavior is not a functor of any of the four kinds. It enforces nothing, rejects nothing,
and enqueues nothing — it is a projection, and specifically the field-scoped computed type
that a field declaration already creates.

## Path equivalence (David Spivak model)

A schema is a **finitely presented category** where:
- Objects = tables (or types)
- Morphisms = foreign keys
- Equations = commutative diagram constraints (path equivalences)

A path equivalence asserts: for two paths `f ∘ g` and `h ∘ k` through the schema graph, the composites must produce the same result. It is an **equality-generating dependency**. Referential integrity is a different and weaker thing — the totality of the foreign-key map, which the functorial model gives for free. That is why foreign keys are a separate kind, one that *resolves* rather than asserts.

It is also not the only proposition the presentation can carry. **Presence** asserts that the set of rows reached by a composition is inhabited, and **absence** that it is empty — neither is an equation, and both are needed constantly in practice. In dependency terms presence is a **tuple-generating dependency** and absence a **denial constraint**, and naming them pays for itself: equality- and tuple-generating dependencies are monotone and survive append-only merge replication, and a denial constraint does not. An absence assert satisfied at commit can be falsified by an insert into a different table in another shard, which is why a cross-shard absence assert may not be attached `enforce always` — see [distribution.md](distribution.md#constraints-that-cross-shards-cannot-promise-enforce-always).

All three are subject to one restriction that keeps them categorical rather than arbitrary: the composition must start at the row under evaluation, and every step must be a declared morphism followed **in either direction** — forwards to a referent, or backwards to its referrers. The backward direction is what presence and absence quantify over, since a forward path is single-valued and total. A composition free to start anywhere would be a predicate over the whole database, not a statement about this object's neighbourhood — and, less abstractly, would be a table scan on every read. [schema/constraints.md](schema/constraints.md#anchoring) owns the rule.

Two operations over the presentation are easy to conflate, and only one of them is cheap:

- **Instance-level checking** evaluates two paths on one row and compares. It is decidable, per row, and it is what mutation validation does: the system walks the affected subgraph and verifies that all declared constraints still hold after the change — a bounded chase, bounded by anchoring. That rootedness is what makes "the affected subgraph" **findable**, by traversing the declared morphisms backwards from the written row. Findable is not the same as small: a backward traversal is a preimage, with no bound short of the connected component. What the revalidation set includes, and what happens when it is large, belong with the anchoring rule.
- **Schema-level entailment** asks whether the declared equations imply a new one. That is the word problem for a finitely presented category, undecidable in general, and it is what query optimization needs before it may reorder. Declared path equations must therefore form a convergent rewriting system, checked at schema commit, with non-termination reported as a commit error naming the offending pair. The completion bound and the diagnostic are unspecified.

For access control the same walk runs with the active tokens, and a row whose access assert fails resolves to `Redacted` — the whole row, key included. Nothing prunes an individual morphism; see [schema/constraints.md](schema/constraints.md#redaction-scope).

**A schema coercion is Δ.** Spivak's schema morphism induces three migration functors, and DataCode uses one of them: coercing a row from an old schema node to a new one is a pullback along the morphism between the two nodes. Δ is the migration that needs no key generation, where Σ and Π mint keys the source did not have — which [schema/queries.md](schema/queries.md#keys-are-computed-never-declared) forbids outright. Saying which one strengthens the citation rather than qualifying it.

## Functor composition and transparency

All functors must be **transparent** — their behavior is fully inspectable by the runtime. This is required for:
- Schema evolution: coercing data from an old schema point to a new one requires composing the functor chain between those two points
- Access control analysis: the system must be able to read an assert's variety off its body and compute the exact set a `bypass access` grant exempts
- Query optimization: the optimizer can reorder functor application when commutativity can be proven, which is what makes the convergence restriction above load-bearing

Opaque computation is not merely disallowed inside a functor, it is unrepresentable. `Effect` has no lift into `Tx`, so there is no type an external call could produce there — an absent constructor rather than a rule. This replaces the earlier `a -> IO b` signature rejection, which was weaker: `IO` no longer appears in any DataCode signature at all. See [schema/functions.md](schema/functions.md#the-effect-ladder).

## Absent values

Because NULL is eliminated, any value that might be absent says so in its type. Absence is modelled as an ADT family rooted at `Null` — **not** as `Maybe`:

```
type MissingCustomer : Null
```

Built-in members cover the recurring reasons — not found, redacted, sealed, erased, not retained; the full list is in [schema/types.md](schema/types.md#absence-types). Schema authors add their own. The distinction from `Maybe` is the point. `Nothing` is a single inhabitant carrying no information, so it conflates every reason a value might be missing — which is the same defect NULL has, merely better typed. A `Null`-rooted family makes the *reason* part of the type, so "no phone number was given", "you are not permitted to see this", and "the join found no counterpart" are different types with different handling.

A field's type is the sum of its present and absent cases:

```
phone     : Phone    | NotGiven
customer :> Customer | MissingCustomer
```

Outer joins add a `Null`-derived variant to the field types on the outer side, and the guard semantics of `><` are exactly the left-to-right resolution of that sum. This means:

- Every consumer of an outer-joined field is forced by the type system to handle the absent case, and to handle each *reason* separately if they differ
- No silent propagation of NULL through computations
- Absence composes with pattern matching and functor targeting the same way any other sum type does — no special case in the category

`Maybe` does appear, but only at the Haskell function boundary: a user-supplied functor with signature `a -> Maybe b` has its `Nothing` lifted into a validation failure by the auto-wrapping rules (see [schema/functions.md](schema/functions.md)). That is an interop convenience for writing predicates in idiomatic Haskell, not the data model's representation of absence.

## Domain type refinement

Domain types form a **nominal subtyping chain**. A new type inherits the constraints of the type it extends — `type Email : Text where isValidEmail` is a `Text` with an additional validation functor attached — and a field declared `email : Email` narrows it once more, minting a field-scoped subtype at `namespace.table.field`.

Validation functors accumulate down the chain rather than replacing one another. The same is true across trait inheritance: a field merged from two traits carries both traits' predicates, each still addressable at its originating path. See [schema/types.md](schema/types.md) and [schema/traits.md](schema/traits.md).
