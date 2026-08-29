# Templates

A template is **text with holes**. It is not a function with strings in it, and it is not a
template language with control flow — there is one construct, and the control flow falls out of
it.

A hole is `{{ <expression> }}` with an optional `using` clause naming the template applied per
row. [railroad.md](railroad.md#templates) owns the two productions; this file owns what they
mean.

## A template is a `Reference` row

```
table app.ui.Template : Reference {
  subject   : Text,
  name      : Text unique,
  body      : Text,
  separator : Text = ""
}
```

Templates are rows in `Reference` tables, so a template is code: versioned by schema node,
replicated everywhere, diffable per path, and old versions stay queryable like every other
schema object.

- **`subject` names the type or table the template renders**, in the same key space as
  `system.ui.TypeRender.type_name`
  ([functions.md](functions.md#functions-as-column-values)). `self` in a hole is a row of that
  type. Three checks need it and none can run without it: anchoring has to know which `:>` edges
  exist, a hole's field paths are checked against it at schema commit, and theme dispatch keys
  on it. The previous declaration carried no subject, so all three had nothing to resolve
  against.
- **`name` is unique table-wide**, because `using` names a row with a `QName` —
  `using app.ui.Template.lineRow`, the spelling `using system.crypto.HashPolicy.password_v2`
  already uses ([types.md](types.md#hashed-types)). A two-part `{ subject, name }` key would
  have no spelling in a `QName`, and a bare `lineRow` would not say which table it came from.
- **`body` is `Text`**, parsed against `TemplateBody` at schema commit, so a malformed template
  fails the commit rather than a page render. The column is deliberately not typed by the
  grammar's nonterminal name: one identifier meaning both a production and a DataCode type is
  what the previous draft got wrong.
- **`separator`** joins the rows a hole produces. See
  [The separator is data, not syntax](#the-separator-is-data-not-syntax).

### The caller supplies `self`

The renderer never selects a template by name. It walks the schema and renders each row with the
active theme's render function for the row's type
([../api-and-rendering.md](../api-and-rendering.md)). A template is admissible as that function,
because applied to a row of its `subject` it has the render function's shape —
`Order -> Read Html` beside `Renderer = Amount -> Read Html`
([functions.md](functions.md#function-types)). Schema commit checks that the template's
`subject` matches the type the theme registers it under.

So `self` is bound by a caller — the renderer at the root of a page, the enclosing hole below it
— and `subject` is what says which callers are admissible.

## Cardinality is the control flow

A hole holds an expression. Carrying a query clause makes it a query, and the query's **result
count** does the work that `if`, `each`, and `unless` do in a conventional template language.
Carrying none makes it an ordinary expression that renders one value. That is the same
query-versus-expression rule the rest of the grammar uses
([railroad.md](railroad.md#functions-and-expressions)), in one more position.

| Hole | Renders |
|---|---|
| expression, no query clause | the value, once |
| query, 0 rows | nothing — this is the conditional |
| query, 1 row | once — this is plain interpolation |
| query, N rows | N times, joined by the separator — this is the loop |

Zero, one, and many are one rule, so there is nothing to choose between, and a value hole is the
degenerate case of that rule rather than a second form. Earlier drafts got there by calling
`self.field` and `self { field }` "the same projection". They are not the same: `self.field` is a
value and `self { field }` is a one-row, one-column table, and `count` is well typed on the
second only. The hole admits both because it takes an `Expr`, not because the two are equal.

A template whose `subject` is `app.commerce.Order`:

```
<h2>Order {{ self.order_num }}</h2>
<p>Placed {{ self.placed_at }} for {{ money self.total }}</p>

{{ self >< LineItem as line where line.qty > 0 { line.* } using app.ui.Template.lineRow }}

{{ self >< (Shipment where state is Delayed) as ship { ship.* } using app.ui.Template.delayNotice }}
```

The last hole is the conditional: a delayed shipment renders the notice, no delayed shipment
renders nothing, and the filter is the query's own `where`. Nothing had to be added for it.

`as line` is not decoration. A join against the reference direction has no `:>` field to name its
result, so `as` is mandatory wherever the query names that source
([queries.md](queries.md#joining-against-the-reference-direction)).

## `using` names the template applied per row

`using` takes the `QName` of a template row. The table part is what makes the lookup well
defined — templates are rows in `Reference` tables, plural, so a bare name would not say which
one. A template named by `using` must be declared, so a typo is a schema-commit error, and its
`subject` must be the type of the row the hole produces. A joined hole produces a joined row,
which is no declared type, so it projects down to the named template's subject — `{ line.* }` in
the line-item hole above.

Omitted, **the active theme's render function for the row's type applies**. That is not a
fallback invented to fill the hole — it is
[../api-and-rendering.md](../api-and-rendering.md)'s "render functions per type", which means
the template system and the theme system are one mechanism rather than two. `{{ self.total }}`
renders an `Amount` however the active theme renders `Amount`s, and a theme swap changes every
amount on every page with no template edited.

`using` is the existing `UsingClause` token, which already means "supply this parameterizing
thing" ([types.md](types.md#hashed-types)). Same meaning, wider position — the operand kind is
what varies by position: a function for `Doc indexed`, a policy row for a hashed type, a
template row here.

Where both could apply, `using` wins. A hole that names a template is asking for that fragment;
the theme's render function is what a hole with no opinion gets.

### Templates naming templates must be acyclic

The check is the one [functions.md](functions.md#restrictions) applies to function columns, for
the same reason.

The graph includes **theme dispatch**, not only `using` edges. A hole with no `using` gets an
edge to the render function each theme supplies for every type that hole can produce, and the
check runs per theme, so a cycle in one theme cannot be introduced by another. That keeps the
guarantee static rather than a render-time depth limit, because a theme is `Reference` data and
inserting a `Reference` row is a schema transaction
([traits.md](traits.md#reference-tables-are-code)) — every edge that can change the graph
changes it at a schema commit, where the check already runs. Restricting the check to `using`
edges would have covered the rare path and missed the common one.

## The separator is data, not syntax

A template's `Reference` row carries its own separator, so a fragment that joins with `", "` is
a different template row from one that joins with `"\n"`. Templates are `Reference` rows, so
that is cheap, and it keeps the hole at two parts instead of three. It also means the separator
is visible in the template list rather than scattered across every call site.

Which separator a hole uses follows from that: **a hole's rows are joined by the separator of
the template named by `using`.** A hole with no `using` joins with the enclosing template's
separator, because the per-row renderer is then a render function and a function carries no
separator column.

## Absence renders because absence is a type

The one thing cardinality cannot express is a **negative branch** — render something *only if*
the query is empty. An empty result renders nothing by construction, so there is no `else` to
hang it on.

The language already has the answer: outer-join a `Null`-derived catch-all, and the row always
exists. In a template whose `subject` is `Account`:

```
{{ self >< (Suspension where lifted is NotLifted) | NoSuspension as suspension { suspension } }}
```

The projected column is now typed `Suspension | NoSuspension`, and the theme's render function
for `NoSuspension` is what renders the empty case. **Absence renders because absence is a type**,
which is what the `Null`-rooted ADT family exists for.

This inherits the trap [queries.md](queries.md#filter-before-guard) documents: a filter on an
outer-joined source must be written **inside** the join term, as it is above. An outer-level
`where` naming a field of an outer-joined source is a compile-time error, here as in an
`assert` — otherwise every suspension being lifted yields zero rows instead of a `NoSuspension`
row, and the template renders the opposite of what it says.

## Formatting needs no filters

A projected expression already mints a type ([queries.md](queries.md#field-types)), and a hole
holds an expression, so formatting is an ordinary function call:

```
{{ money self.total }}
{{ truncate 80 self.description }}
```

There are no filters, no pipes, and no template-local helper namespace — the functions in a hole
are the functions in the schema. This is what the `Expr` hole buys. While a hole took a `Query`
alone, `money self.total` had no parse at all, because a function application is not a query
source, and every formatted example in this file was ungrammatical.

## Escaping is a type property

A hole's output is escaped for the **output type of the template**, which is the result type of
the render position the template fills: a theme's HTML render column is typed `Html`
([types.md](types.md)), a plain-text mail column is typed `Text`. A template used at two output
types is two rows. Nothing else tells a hole which escaper it is under.

Emitting unescaped markup requires a value of type `Html`, which only a template or a render
function produces, so **injection safety is a typing property rather than a template feature**.
There is no triple-brace raw-output escape: a raw hole is a hole with its type erased, and the
type is the whole mechanism. What the typing buys is not that markup cannot be produced — a
template is exactly the thing that produces it — but that every producer is a named schema
object, versioned by schema node and enumerable at commit.

One narrowing, because the claim was stated too strongly: **one escaper per output type closes
element-text context only.** HTML has at least five escaping contexts — element text, quoted
attribute, unquoted attribute, URL, and `<script>` or `<style>` body — and an escaper correct
for the first is unsafe in the other four. A hole in one of those positions needs a
context-appropriate `Html` producer, and reaching for one is explicit and auditable rather than
implied by the output type.

## Anchoring and effect

A template's holes obey the same two rules the rest of the schema obeys:

- **Rooted at `self`**, every subsequent source reached by a join along a declared `:>` edge in
  either direction. `self` is a row of the template's `subject`, which is what makes the check
  runnable at all. A template renders per row on every read that reaches it, so an unanchored
  template would scan on every page render. Same rule, same reason, as
  [constraints.md](constraints.md#anchoring).
- **`Read` only.** A template is a projection. `Tx` and `Effect` are both rejected in a hole, so
  rendering a page cannot write and cannot call out. See
  [functions.md](functions.md#the-effect-ladder). A `File`'s content is readable in a hole up to
  the size cap in `system.config`, which is what lets one stylesheet be both served at a URL and
  inlined into rendered HTML for mail clients that demand inline CSS. Above the cap the bytes
  are reachable only through the streaming handler, which is `Effect`.

## Composition is not the template's job

Page-level layout is the renderer's, not a template's. The renderer walks the schema by
PageRank weight and windows it by the user's information-density value
([../api-and-rendering.md](../api-and-rendering.md)); templates are the per-type fragments it
composes. That is why the template language needs no partials, no inheritance, and no blocks.

The cost is real and worth stating: **a page whose layout is not derivable from the schema walk
cannot be expressed as a template.** If that turns out to bind, the fix is a layout template
with iteration and conditionals of its own — at which point this stops being one production and
becomes a language, and the trade should be made deliberately rather than by accretion.
