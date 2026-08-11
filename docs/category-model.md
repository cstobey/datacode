# Category Model

## The Governing Monad

The DataCode **runtime is the governing monad**. Every operation that reads or writes data, validates a type, traverses a relationship, or checks authorization is a computation within this monad. The monad encapsulates:

- The current point in the schema transaction graph (what schema version applies)
- The current authentication context (what tokens are active)
- The current shard topology (where data lives)
- The evaluation environment (what types and functions are loaded)

Schema authors do not define monads; they define **functors** — the rules that apply to custom data types within the runtime monad.

## Functors

A functor in DataCode is a structure-preserving mapping between categories. In practice, each functor is a Haskell function applied to a type or relationship that enforces a rule. There are four functor kinds, each applied on an as-needed basis per type or relationship.

This document is the *why*; [schema/functors.md](schema/functors.md) is the operational reference (signatures, when each runs, surface syntax).

### 1. Type Validation Functors
Applied to individual fields. Enforce invariants on values within a type:
- Range checks, format validation, referential integrity within a field
- Example: `Email` type with a functor that validates RFC 5322 format
- Automatically applied whenever a value of that type is constructed or mutated
- Written as a `where` clause on a type or field declaration

### 2. Foreign Key Functors (Relational Functors)
The primary set/relational connection between tables. Map objects in one table to objects in another:
- Encode the "arrows" of the schema category
- Compose: a foreign key chain is functor composition
- Carry provenance: the query result type retains the chain of functors that produced it
- Written with the `:>` field token

### 3. Path Equivalence Functors
Enforce commutativity of diagrams in the schema graph. If two different paths through the schema should produce the same result, a path equivalence encodes that requirement:
- Based on David Spivak's formalism for database schemas as categories (see *Functorial Data Migration*)
- Applied during mutation validation, not at query time
- Written with `assert`

This is a single functor kind with **two varieties**, distinguished only by what the two path terms refer to:

**Data constraint** — both terms are data paths from the row.
- Example: `order.customer.billing_address` must equal `order.billing_address` at commit time
- The primary mechanism for enforcing business rules that span tables

**Access control** — one term is the requesting token, the other a data path.
- Restricts which morphisms (paths through the schema) a given token can traverse
- Composes with relational functors: you can only follow a foreign key if your token has the appropriate path traversal right

The two are *structurally identical*, which is why they are one kind rather than two. That identity is the payoff of the categorical framing: authorization is not a bolt-on subsystem with its own semantics, it is the same commutative-diagram machinery pointed at the authentication context. Consequences follow for free — access rules can be statically analyzed for consistency (no contradictions, no gaps) before deployment by exactly the analysis that checks data constraints, and both render as edges in the same schema diagram.

Where they differ is only in evaluation timing, and that difference is derived rather than stipulated: a data constraint has nothing to check until a mutation is proposed, so it runs at commit; an access-control equivalence is meaningful on any traversal, so it runs on read as well. On a failed read the field resolves to `Redacted` rather than aborting — absence is typed, so "you may not see this" is expressible in the result rather than only as an error.

### 4. Event Functors
Schedule a deferred effect rather than enforcing an invariant. An event functor maps a committed row to an `EventRef` — a work item inserted into a queue table — instead of to `Either Error a`:
- The only functor kind that cannot abort a commit; inserting the queue row *is* the commit
- Keeps the category closed under composition: an external side effect would not be a morphism in the schema category at all, so it is reified as data (a queue row) that later processing consumes
- This is why "no external calls inside a transaction" is a structural consequence of the model, not merely an operational policy
- Surface syntax is not yet settled — see OQ-030

## Reified Failure

The event functor's design move — an external side effect cannot be a morphism in the schema
category, so it is reified as data (a queue row) that later processing consumes — applies a
second time, to a different problem.

A validation functor rejects. Rejection is total and synchronous: the transaction does not
happen. But a rule can be introduced *after* data exists, and the data cannot then be
retroactively rejected without mutating history, which the transaction graph forbids. The
category has no morphism for "this row that already exists should not have".

So the failure is reified the same way the side effect is: a **violation** is a row that
records the triple `(subject, violated functor, schema node)`. What cannot be an arrow becomes
an object.

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

## Path Equivalence (David Spivak Model)

A schema is a **finitely presented category** where:
- Objects = tables (or types)
- Morphisms = foreign keys and functional dependencies
- Equations = commutative diagram constraints (path equivalences)

A path equivalence asserts: for two paths `f ∘ g` and `h ∘ k` through the schema graph, the composed functors must produce the same result. This is the categorical analog of a referential integrity constraint, but far more general.

For mutations, the system walks the affected subgraph and verifies that all declared equivalences still hold after the change. For access control, the system walks the same graph with the active tokens and prunes morphisms the token cannot traverse.

## Functor Composition and Transparency

All functors must be **transparent** — their behavior is fully inspectable by the runtime. This is required for:
- Schema evolution: coercing data from an old schema point to a new one requires composing the functor chain between those two points
- Access control analysis: the system must be able to enumerate what a token can and cannot see
- Query optimization: the optimizer can reorder functor application when commutativity can be proven

Opaque functions (arbitrary IO, FFI calls with side effects) are not permitted inside functors.

## Absent Values

Because NULL is eliminated, any value that might be absent says so in its type. Absence is modelled as an ADT family rooted at `Null` — **not** as `Maybe`:

```
type MissingCustomer : Null
```

Built-in members are `NotFound`, `Redacted`, `Pending`, and `Deleted`; schema authors add their own. The distinction from `Maybe` is the point. `Nothing` is a single inhabitant carrying no information, so it conflates every reason a value might be missing — which is the same defect NULL has, merely better typed. A `Null`-rooted family makes the *reason* part of the type, so "no phone number was given", "you are not permitted to see this", and "the join found no counterpart" are different types with different handling.

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

## Type Classes and Inheritance

DataCode uses Haskell's typeclass system to encode functor behavior. When a new type is defined, it inherits the constraints of the type it extends — `type Email : Text where isValidEmail` is a `Text` with an additional validation functor attached, and a field declared `email : Email` further narrows it to a field-scoped subtype at `namespace.table.field`.

Domain types therefore form a subtyping chain, and validation functors accumulate down it rather than replacing one another. The same is true across trait inheritance: a field merged from two traits carries both traits' predicates, each still addressable at its originating path. See [schema/types.md](schema/types.md) and [schema/traits.md](schema/traits.md).
