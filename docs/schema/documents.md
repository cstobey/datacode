# Documents

`Doc` is DataCode's type for tree-shaped data whose shape is not known in advance: webhook
bodies, raw connector payloads, structured log context. It exists because those things are
real, not because schemaless data is desirable — anything whose shape you control should be
a table.

## It Is Not Called `Json`

JSON is a serialization of this type, not the type itself. Naming it `Json` would import
JSON's type system, which is worse than DataCode's in three specific ways: numbers are IEEE
doubles, there is no timestamp, and there is exactly one untyped `null` — the construct this
project spends most of its design budget eliminating.

So: the type is `Doc`, JSON is an encoding at the API boundary, and the mapping is explicit.

| JSON | `Doc` |
|---|---|
| object | `Object` node; children keyed by name |
| array | `Array` node; children keyed by position |
| string | `Text` |
| number | `Decimal` — never a float; precision is preserved as received |
| `true` / `false` | `Bool` |
| `null` | `JsonNull`, a `Null`-derived absence type |

`type JsonNull : Null` is how "the sender explicitly sent null" stays distinguishable from
"the key was absent" and from "we could not parse it" — the ordinary
[absence-type](types.md#absence-types) treatment, applied to the one case JSON conflates.

## Storage: Bytes First, Shredded Second

A `Doc` field stores **the received bytes**, one row, no expansion.

```
table app.log.Request : LogData {
  received_at : Timestamp,
  body        : Doc              -- stored as bytes; opaque to queries
}
```

Three reasons the bytes are authoritative rather than a cache of the shredded form:

1. **Signature verification needs the exact bytes.** Webhook authentication is an HMAC over
   the body as received. Shredding and re-serializing loses key order, duplicate keys, and
   number formatting, so a re-serialized document cannot be verified. See OQ-020.
2. **Write amplification.** A 200-key payload shreds into 200 rows in one transaction's
   mutation list. On a log or ingest path that is the hot path, and paying it unconditionally
   would make `Doc` unusable exactly where it is most needed.
3. **The shredded form is derivable.** It can be rebuilt at any time, at any schema node,
   which makes it a materialized view rather than data.

Adding `indexed` requests the shredded form:

```
table app.log.Request : LogData {
  received_at : Timestamp,
  body        : Doc indexed      -- bytes, plus a shredded tree that queries can reach
}
```

`indexed` is a storage hint in the same sense that materialization is a storage hint on a
view: it changes what is computed and kept, never what the field means.
[queries.md](queries.md#document-paths) covers reading it;
[README.md](README.md#clause-order) places it in the clause order.

## The Shredded Form

`Doc indexed` generates three sibling tables per field. For `app.log.Request.body`:

```
table app.log.RequestBodyNode : Component {
  key   :> app.log.RequestBodyKey | app.log.RequestBodyKeyRaw | NoKey,
  value : Text | Decimal | Bool | Timestamp | Object | Array | JsonNull
}

table app.log.RequestBodyKey : DocKeys        -- interned keys; schema; 2-byte tag

table app.log.RequestBodyKeyRaw : LogData {   -- spilled keys; data; the owner's trait
  name : Text unique
}
```

They are generated with `internal` visibility, so they do not clutter the IDE or the
namespace sidebar, and they are `:describe`-able like any other table.

**The spill table inherits the owning table's replication trait** — `LogData` here because
`app.log.Request` carries it, `UserData` where the field sits on a user table. Only the
interned key table is fixed, at `DocKeys : Reference, Extensible`, because interning is a
schema act rather than a data one. The node table is `Component`, which by definition places
itself wherever its parent is.

### Nodes Are Components

`RequestBodyNode` carries the `Component` trait, so a node has no `DataId` of its own — it is
identified by its parent's identifier plus an `Ordinal`, and nesting appends another ordinal
per level (see
[../transaction-graph.md](../transaction-graph.md#component-ordinals)). Three properties fall
out, and they are the reason this design works at all:

- **The whole document is one range scan.** Every node shares the owning row's byte prefix,
  in document order.
- **The parent link is free.** It is the identifier prefix; no stored pointer, no FK.
- **Arrays are free.** Ordinals are already assigned in insertion order and are contiguous,
  so an array node's children *are* its ordinals. There is no `Index` key type, and an array
  element's `key` is `NoKey` — a `Null`-derived type meaning "position is the identity here".

`Object` and `Array` carry no payload. They say that a node has children; the children are
the component subtree beneath it.

### Keys Are Interned Per Field

`DocKeys` gives every generated key table the same shape:

```
trait DocKeys : Reference, Extensible {
  name : Text unique
}
```

Because `Reference` rows are schema rather than data (see
[traits.md](traits.md#reference-tables-are-code)), an interned key is a **2-byte variant
tag** that replicates to every server with the schema, not a 12-byte `DataId` that has to be
joined. For log data with recurring keys this is the dominant saving — and it is the
mechanism, not just an optimization, because it is what makes the key set a *closed,
enumerable* thing rather than an open set of strings.

The key table is **per field**, not global. The trade, stated plainly:

- `user_id` appearing in fifty different `Doc` fields gets fifty separate tags.
- In exchange, the cardinality cap is per field, so one badly-behaved source cannot pollute
  every other field's key space; and "what keys have ever appeared in *this* field" is a
  table rather than a filtered scan over a shared one.

That is the right trade. A shared key table optimizes the byte count of the thing that is
already cheap, and gives up the control on the thing that is dangerous.

### Key Spill

Unbounded key cardinality is the failure mode that matters. A source that uses UUIDs as
object keys would grow a `Reference` table that replicates to **every server in the
cluster** — one badly-behaved webhook becoming a cluster-wide problem.

Each `Doc indexed` field therefore has a key-cardinality cap. Under the cap, a new key is
interned. Over it, the key spills to `…KeyRaw` — an ordinary data table carrying the owning
table's replication trait, so it never leaves the shard or the server the owner is on — and the
overflow is reported through [../integrity.md](../integrity.md).

Resolution is the ordinary left-to-right guard semantics of a fallback chain, identical to a
nullable or fallback foreign key:

```
key :> app.log.RequestBodyKey | app.log.RequestBodyKeyRaw | NoKey
```

The head is a table, the tail is further tables and a `Null`-derived type — the
[head rule](README.md#-versus-) as written, not bent. This is why the spill target is a
table rather than a bare `Text`: admitting `Text` into the tail of a `:>` would break the
"references a row in" guarantee everywhere in the language for the sake of one type.

| | Interned | Spilled |
|---|---|---|
| Kind | Schema | Data |
| Stored as | 2-byte variant tag | 12-byte `DataId` |
| Replication | All servers | The owning table's — shard-local under `UserData`, server-local under `LogData` |
| Added by | Schema transaction | Ordinary insert |

## Querying

Field access into a `Doc indexed` reads as an ordinary path, and resolves through the
shredded tree:

```
app.log.Request where body.event_type == "charge.succeeded"

app.log.Request
  { received_at, body.data.object.amount as amount }
```

A path into a `Doc` is a sum of every type that path has ever held, plus `NotFound` for
documents that lack it. There is no implicit coercion — a path that has held both `Text` and
`Decimal` must be handled as both, which is the same discipline every other sum type imposes.

Accessing a path on a non-`indexed` `Doc` is a compile-time error, not a slow query. The
bytes are opaque by construction; the error names `indexed` as the fix.

### The Actual Payoff

The key set is queryable, which a blob's is not:

```
:describe app.log.Request.body
-- keys: 47 interned, 3 spilled
-- event_type   Text        99.8% present
-- data         Object      100%
-- amount       Decimal     61.2% present
-- livemode     Bool        100%
```

A key that turns out to be always present and always one type is a candidate to be promoted
into a real column with a real type and real validation. That path — ingest as a document,
observe the shape, promote what stabilizes — is why shredding is worth doing at all. The
storage saving is a side benefit.

## Rejected: Anonymous Sub-Tables

The obvious way to express a document inline is an anonymous nested table. DataCode does not
have one, for reasons already settled elsewhere in the language:

- **Validations are addressed by path** ([README.md](README.md#addressing-validations)). An
  anonymous table has no path, so nothing in it can be validated, reported on, or diffed.
- **The ER diagram has no node for it**, so a significant part of the schema becomes
  invisible to the IDE.
- **Evolution cannot name it.** `rename from`, `deprecate`, and `prune` all take a path.
- [tables.md](tables.md#inline-sub-tables) already establishes that an inline sub-table is
  sugar for a *named* sibling, precisely so that "there is no embedded product-in-row" stays
  true.

`Doc indexed` uses the same trick: the generated tables are named, addressable, and
describable. The ergonomics of anonymity, none of the cost.
