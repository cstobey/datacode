# Category Model

## The Governing Monad

The DataCode **runtime is the governing monad**. Every operation that reads or writes data, validates a type, traverses a relationship, or checks authorization is a computation within this monad. The monad encapsulates:

- The current point in the schema transaction graph (what schema version applies)
- The current authentication context (what tokens are active)
- The current shard topology (where data lives)
- The evaluation environment (what types and functions are loaded)

Schema authors do not define monads; they define **functors** — the rules that apply to custom data types within the runtime monad.

## Functors

A functor in DataCode is a structure-preserving mapping between categories. In practice, each functor is a Haskell function applied to a type or relationship that enforces a rule. There are four functor types, each applied on an as-needed basis per type or relationship:

### 1. Type Validation Functors
Applied to individual fields. Enforce invariants on values within a type:
- Range checks, format validation, referential integrity within a field
- Example: `Email` type with a functor that validates RFC 5322 format
- Automatically applied whenever a value of that type is constructed or mutated

### 2. Foreign Key Functors (Relational Functors)
The primary set/relational connection between tables. Map objects in one table to objects in another:
- Encode the "arrows" of the schema category
- Compose: a foreign key chain is functor composition
- Carry provenance: the query result type retains the chain of functors that produced it

### 3. Schema-Level Constraint Functors (Path Equivalence)
Enforce commutativity of diagrams in the schema graph. If two different paths through the schema should produce the same result, a constraint functor encodes that requirement:
- Based on David Spivak's formalism for database schemas as categories (see *Functorial Data Migration*)
- Example: `order.customer.billing_address` must equal `order.billing_address` at commit time
- Applied during mutation validation, not at query time
- These are the primary mechanism for enforcing business rules that span tables

### 4. Access Control Functors (Authorization Path Equivalence)
Structurally identical to schema constraint functors, but evaluated against the authentication context:
- Restrict which morphisms (paths through the schema) a given token can traverse
- Compose with relational functors: you can only follow a foreign key if your token has the appropriate path traversal right
- Because they are path equivalences, they can be statically analyzed for consistency (no contradictions, no gaps) before deployment

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

## Type Classes and Inheritance

DataCode uses Haskell's typeclass system to encode functor behavior. When a new type is defined, it can inherit the typeclass instances of existing types:

```haskell
-- NOT_FOUND inherits the behavior of Maybe's Nothing
class (Functor Maybe) => NOT_FOUND a where
  -- NOT_FOUND carries the type of the field that was absent
```

This means `NOT_FOUND` participates in all the same functor machinery as `Maybe`, and query results that include outer joins produce well-typed values that compose correctly with downstream computations.

## The Maybe Monad and Absent Values

Because NULL is eliminated, any relationship that might be absent is expressed in the type. Outer joins add `NOT_FOUND` to the field types on the outer side. This means:

- Every consumer of an outer-joined field is forced by the type system to handle the absent case
- `NOT_FOUND` composes with the `Maybe` monad naturally — a chain of absent-capable lookups is a `do`-notation chain
- No silent propagation of NULL through computations
