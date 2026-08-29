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

**No JSON input produces a `Timestamp` node**, because JSON has no timestamp — the second of
the three reasons above. A `Timestamp` node comes only from a non-JSON producer: a `Doc` built
inside DataCode, such as structured log context, where the value was already typed before it
reached the document. A query over a field fed only by JSON never meets the variant; a query
over a mixed field does.

`type JsonNull : Null` is how "the sender explicitly sent null" stays distinguishable from
"the key was absent" and from "the payload could not be parsed" — the ordinary
[absence-type](types.md#absence-types) treatment, applied to the one case JSON conflates.

The third of those distinctions needs a type of its own, on the same principle:

```
type Malformed : Null
```

Unparseable bytes are an expected case rather than an edge one: the next section keeps raw
payloads exactly as received, which means keeping the ones that do not parse.

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
3. **The tree is recoverable from the bytes.** A node's shape and its leaf values can be
   rebuilt at any time, so nothing is lost by not shredding. The **key encoding** is not
   recoverable: which keys interned and which spilled depends on the cap's fill state when
   each document arrived, and which tag a key holds depends on arrival order. A rebuild
   therefore reuses the key tables at that schema node rather than recomputing them — which is
   the same path-dependence [Superseding a Key Table](#superseding-a-key-table) relies on.
   Only the node table is derived, and only it is droppable.

Adding `indexed` requests the shredded form:

```
table app.log.Request : LogData {
  received_at : Timestamp,
  body        : Doc indexed      -- bytes, plus a shredded tree that queries can reach
}
```

`indexed` widens the field's **interface** — it makes document paths addressable — and changes
what is computed and kept as a consequence. It is a schema-author declaration, like `retain`,
which is why it is schema syntax and materialization deliberately is not
([railroad.md](railroad.md#reserved-words)): which view is materialized is operational policy
that changes over time and is not the author's decision, while whether a path type-checks is.
[queries.md](queries.md#document-paths) covers reading it;
[README.md](README.md#clause-order) places it in the clause order.

**Bytes that do not parse are still stored.** The insert succeeds, the field records a
violation through [../integrity.md](../integrity.md), and every path into that document
resolves to `Malformed` rather than to `NotFound` — the row is not missing the key, it never
had a tree. Because the bytes are never rewritten, a later rebuild reparses: fix the producer
or the parser, re-shred, and the paths resolve. See
[../storage.md](../storage.md#shredded-documents) for how the bytes and the tree are laid out.

## The Shredded Form

`Doc indexed` generates three sibling tables per field. For `app.log.Request.body`:

```
table app.log.RequestBodyNode : LogData, Component {
  key   :> app.log.RequestBodyKey | app.log.RequestBodyKeyRaw | NoKey,
  value : DocNode
}

table app.log.RequestBodyKey : DocKeys { }         -- interned keys; schema; 2-byte tag

table app.log.RequestBodyKeyRaw : LogData, Component {   -- spilled keys; data; the owner's row
  name : Text unique
}
```

The node value is one built-in sum:

```
type DocNode = Text | Decimal | Bool | Timestamp | Object | Array | JsonNull
```

`Object` and `Array` carry no payload. They say that a node has children; the children are
the component subtree beneath it.

`RequestBodyKey` has an empty body because `DocKeys` supplies the whole of it — `name : Text
unique`, inherited, which is also what satisfies the candidate-key rule
([tables.md](tables.md#candidate-keys-are-mandatory)).

**The names are derived, not chosen**: the owning table's name, the field name in
`UpperCamelCase`, and one of `Node`, `Key`, or `KeyRaw`, in the owning table's namespace. A
collision is a schema-commit error naming both declarations — against a hand-declared table,
or between two fields whose names differ only where the transform erases the difference, as
`body` and `body_key` do. The rule has to be stated because the names are user-visible: they
are generated with `internal` visibility, so they do not clutter the IDE or the namespace
sidebar, but an `internal` table is `:describe`-able like any other.

**Each generated table carries the owning table's replication trait** — `LogData` here because
`app.log.Request` carries it, `UserData` where the field sits on a user table. Two of the three
add `Component`, which is a marker rather than a replication policy
([traits.md](traits.md#component)): it says the rows are owned by the document's row, placed
with it and destroyed with it. Only the interned key table differs, and it is fixed at
`DocKeys : Reference, Extensible`, because interning is a schema act rather than a data one.

### Nodes Are Components

`RequestBodyNode` carries the `Component` trait, so a node has no `DataId` of its own — it is
identified by its parent's identifier plus an `Ordinal`, and nesting appends another ordinal
per level (see
[../transaction-graph.md](../transaction-graph.md#component-ordinals)). Three properties fall
out, and they are the reason this design works at all:

- **The whole document is one range scan.** Every node shares the owning row's byte prefix,
  in document order.
- **The parent link is free.** It is the identifier prefix; no stored pointer, no FK.
- **Arrays are free.** Ordinals are assigned in insertion order and sort in it, so an array
  node's children *are* its ordinals. There is no `Index` key type, and an array element's
  `key` is `NoKey` — a `Null`-derived type meaning "position is the identity here".

Ordinals are **ordered, not contiguous**. A deleted component leaves a gap and the ordinal is
never reused, which is what keeps an array element's identity stable: renumbering to close a
gap would silently move every element after it. Document order is the ordinal order, not the
ordinal value.

### Keys Are Interned Per Field

`DocKeys` gives every generated key table the same shape:

```
trait DocKeys : Reference, Extensible {
  name : Text unique
}
```

Two claims are easy to run together, and they carry different weight:

- **The key table is what makes the key set closed and enumerable.** A finite relation naming
  every key the field has ever held is the mechanism, and a table of 12-byte `DataId`s would be
  equally closed and equally enumerable. The tag width carries none of that argument.
- **The 2-byte tag is a storage win on top of that.** Because `Reference` rows are schema
  rather than data (see [traits.md](traits.md#reference-tables-are-code)), an interned key is a
  variant tag that replicates to every server with the schema, not a 12-byte `DataId` that has
  to be joined. For log data with recurring keys this is the dominant saving.

The key table is **per field**, not global. The trade, stated plainly:

- `user_id` appearing in fifty different `Doc` fields gets fifty rows and fifty tags.
- In exchange, the cardinality cap is per field, so one badly-behaved source cannot pollute
  every other field's key space; and "what keys have ever appeared in *this* field" is a
  table rather than a filtered scan over a shared one.

That is the right trade. A shared table would not change the per-node byte count — both
designs store one tag per node. What it would buy is fewer replicated rows and one shared tag
space, against a shared blast radius and no per-field cap: it optimizes the thing that is
already cheap, and gives up the control on the thing that is dangerous.

### Key Spill

Unbounded key cardinality is the failure mode that matters. A source that uses UUIDs as
object keys would grow a `Reference` table that replicates to **every server in the
cluster** — one badly-behaved webhook becoming a cluster-wide problem.

Each `Doc indexed` field therefore has a key-cardinality cap. Under the cap, a new key is
interned. Over it, the key spills to `…KeyRaw` and the overflow is reported through
[../integrity.md](../integrity.md).

**The spill table is a `Component` of the document's own row** — the same parent the node table
has. That is what places it. The alternative shape, an ordinary table keyed `name : Text
unique`, has no foreign key at all, so under the [key-rooting
rule](tables.md#keys-must-be-rooted) it would be a shard root and each distinct spilled string
would root a shard of its own — the opposite of staying with the owner.

Three answers follow from the parent, each to a question the ordinary shape could not answer:

- **`unique` is per document.** One row per distinct spilled key in one document, not in the
  field. A key repeated at two hundred array positions is stored once; the same key in two
  documents is stored twice. A `Component` may declare `unique` and it is checked within the
  parent, so this costs one shard-local check.
- **Retention follows the owner.** The spill rows are inside the owning row's subtree, so the
  owner's `retain` chain reaches them and a `retain`-less owner keeps them. A separate table
  would have needed a chain of its own, and nothing would have said so.
- **The reference costs 4 bytes.** The node and the spill row are siblings under one parent, so
  the stored reference is the sibling's `Ordinal` and the shared identifier prefix is implicit —
  the same saving the parent link itself gets.

Resolution is the ordinary left-to-right guard semantics of a fallback chain, identical to a
nullable or fallback foreign key:

```
key :> app.log.RequestBodyKey | app.log.RequestBodyKeyRaw | NoKey
```

The head is a table, the tail is further tables and a `Null`-derived type — the
[head rule](README.md#-versus-) as written, not bent. This is why the spill target is a
table rather than a bare `Text`: admitting `Text` into the tail of a `:>` would break the
"references a row in" guarantee everywhere in the language for the sake of one type. The head
is also what keeps the field single-valued: a `:>` whose target carries `Component` is
table-valued, and the head here is a `Reference` table, so only one row is denoted.

| | Interned | Spilled |
|---|---|---|
| Kind | Schema | Data |
| Stored as | 2-byte variant tag | 4-byte sibling `Ordinal` |
| Replication | All servers | The owning row's — wherever the document is |
| Unique across | The field | One document |
| Added by | Schema transaction | Ordinary insert |

#### The Intern Protocol

Interning on the ingest path means one arriving document can touch two graphs, so the order is
part of the design rather than an implementation detail:

- **The tag allocator is the serialization point.** A variant tag is a table-wide `next`, which
  already lives on the constraint's own shard and is allocated cluster-wide even though the
  `Reference` row itself is branch-versioned ([../distribution.md](../distribution.md)). Two
  shards interning the same key concurrently therefore converge on one tag rather than
  allocating two.
- **The schema commit lands first, and the two are not one unit.** The node row is written
  referencing the tag the intern returned. Ordered the other way a node could point at a tag
  that never committed; ordered this way the only residue of a failure is an unused tag, and
  tags are monotonic and never reused anyway.
- **Anything that stops an intern spills, and nothing blocks.** Cap reached, `Extensible` rate
  limit reached ([traits.md](traits.md#extensible)), branch primary unreachable, allocation
  refused — the key spills, the write proceeds, and the overflow is reported.

That last rule is the reason the fallback chain has a data arm at all. Ingest is the one path
where the schema graph must not be able to stall a write.

### Key Shape Rules

The cap is a backstop, and reaching it means the damage is already done. A field whose keys are
known to be identifiers should say so at declaration:

```
body : Doc indexed using app.log.isKeyLike
```

`using` names a `Text -> Bool` function over the key name. A key that fails it spills rather than
interning, however far the field is below the cap. Omitting the clause keeps the existing
behaviour: intern until the cap.

This is the same `using` that parameterizes `Hashed`. A declaration that must name a policy names
a function or a row rather than carrying a literal, so the rule is testable, reusable across
fields, and visible in the schema graph.

The distinction it lets the schema state: a document keyed by identifiers is a **map keyed by a
value**, not a record with named fields.

### Demoting an Interned Key

`deprecate` on an interned key demotes it. No new write interns it, the key spills from then on,
and every existing row still resolves, because the `Reference` row is still there.

```
deprecate app.log.RequestBodyKey.a3f2b1c9
deprecate app.log.RequestBodyKey.*
```

The pattern form is not a convenience. Cleaning forty thousand accidental keys one statement at
a time is a second incident.

**A key is nameable only where its name is an identifier.** `deprecate` takes a `NamePattern`,
whose segments are `Ident`s ([railroad.md](railroad.md#schema-evolution)), so `content-type`,
`X-Request-Id`, a hyphenated UUID and any key carrying a space cannot be demoted one at a time.
The available paths for those are the wildcard above and supersession below. This is the
sharpest argument for writing a key shape rule before a table fills rather than after: the keys
most likely to need demoting are the ones the statement cannot name.

**Demotion stops growth; it does not reclaim tags.** Variant tags are assigned monotonically and
never reused ([traits.md](traits.md#reference-tables-are-code)), and proving that no row anywhere
holds one is not decidable while unmerged branches exist. The counter does not move back — and
in exchange nothing is rewritten and no historical row changes meaning.

On a general `Extensible` `Reference` table there is no spill target, so the same verb reads as
a denylist instead: a connector meeting a deprecated value records a violation rather than
extending the table, which is how a non-`Extensible` table already behaves. One verb, one
meaning, two positions. [traits.md](traits.md#extensible) is the home for that behaviour.

### Superseding a Key Table

Where a key table is beyond saving, redeclare the field. Keys are interned per field, so the
redeclaration mints a new key table at a new schema node, the cap resets, and historical rows
decode against the key table at *their* schema node.

Nothing is rewritten and no tag is renumbered. The old key table survives for historical decode
and becomes prunable once no live row references it — the ordinary rule that only orphaned
branches are deletable ([evolution.md](evolution.md)).

### The Cap Reports Before It Bites

Two limits govern a key table, and they fail in opposite directions:

- The **ceiling** is 65 535, fixed by the 2-byte tag
  ([traits.md](traits.md#reference-tables-are-code)). Past it the table is not a code table, and
  reaching it is rejected at commit.
- The **cap** is a `Configuration` value, per field and overridable per connector, validated at
  commit to be strictly below the ceiling. Reaching it spills. The cap exists so that an ingest
  path meets a graceful limit and never the hard one.

A key table crossing a fill threshold raises a violation, and the report names the shape it
found:

```
app.log.RequestBodyKey: 39 210 of 48 000 interned (ceiling 65 535)
  94% match /^[0-9a-f-]{8,}$/ — candidates for a key shape rule
```

The figure reported first is the cap, because that is the one the field will meet. That
diagnostic is the point of having a per-field cap at all. A shape rule written while the
table is 60 percent full costs one declaration; written at the cap it costs a supersession. The
threshold sits in `Configuration` beside the cap.

## Querying

Field access into a `Doc indexed` reads as an ordinary path and resolves through the shredded
tree. [queries.md](queries.md#document-paths) owns that rule — the result type, the absence of
implicit coercion, and the compile-time error on a non-`indexed` `Doc`.

Two properties of the shredded tree decide what a path can denote, and they belong here
because they are facts about the tree rather than about queries:

- **An array element has no name.** Its `key` is `NoKey` and its identity is its `ordinal`, so
  no key path reaches one.
- **A duplicate object key produces two sibling nodes under one name**, because the bytes are
  authoritative and JSON permits duplicates.

Both make a document path capable of denoting more than one node, which is why its cardinality
is stated with the path rule rather than here.

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
- **Evolution cannot name it.** A rename projection, `deprecate`, and `prune` all take a path.
- [tables.md](tables.md#inline-sub-tables) already establishes that an inline sub-table is
  sugar for a *named* sibling, precisely so that "there is no embedded product-in-row" stays
  true.

`Doc indexed` uses the same trick: the generated tables are named, addressable, and
describable. The ergonomics of anonymity, none of the cost.
