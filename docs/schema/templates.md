# Templates

A template is **text with holes**. It is not a function with strings in it, and it is not a
template language with control flow — there is one construct, and the control flow falls out of
it.

```ebnf
Template ::= ( TemplateText | Hole )*
Hole     ::= '{{' Query ( 'using' QName )? '}}'
```

That is the whole grammar. Templates are rows in `Reference` tables, so a template is code:
versioned by schema node, replicated everywhere, diffable per path, and old versions stay
queryable like every other schema object.

## Cardinality Is the Control Flow

A hole holds a query. The query's **result count** does the work that `if`, `each`, and `unless`
do in a conventional template language:

| Rows | Renders |
|---|---|
| 0 | nothing — this is the conditional |
| 1 | once — this is plain interpolation |
| N | N times, joined by the template's separator — this is the loop |

Zero, one, and many are one rule, so there is nothing to choose between. `self` is a query of
one row, and `self.field` and `self { field }` are the same single-value projection, so a bare
interpolation is not a special case of anything — it is the degenerate query.

```
<h2>Order {{ self.order_num }}</h2>
<p>Placed {{ self.placed_at }} for {{ money self.total }}</p>

{{ self >< LineItem where qty > 0 using lineRow }}

{{ self >< Order >< (Shipment where state is Delayed) using delayNotice }}
```

The last hole is the conditional: a delayed shipment renders the notice, no delayed shipment
renders nothing, and the filter is the query's own `where`. Nothing had to be added for it.

## `using` Names the Template Applied Per Row

Omitted, **the active theme's render function for the row's type applies**. That is not a
fallback invented to fill the hole — it is
[../api-and-rendering.md](../api-and-rendering.md)'s "render functions per type", which means
the template system and the theme system are one mechanism rather than two. `{{ self.total }}`
renders an `Amount` however the active theme renders `Amount`s, and a theme swap changes every
amount on every page with no template edited.

`using` is the existing `UsingClause` token, which already means "supply this parameterizing
thing" ([types.md](types.md#hashed-types)). Same meaning, wider position.

A template named by `using` must be declared, so a typo is a schema-commit error. Templates
invoking templates must form an acyclic graph — the same check
[functions.md](functions.md#restrictions) applies to function columns, and for the same reason.

## The Separator Is Data, Not Syntax

A template's `Reference` row carries its own separator:

```
table app.ui.Template : Reference {
  name      : Text unique,
  body      : TemplateBody,
  separator : Text = ""
}
```

So a fragment that joins with `", "` is a different template row from one that joins with
`"\n"`. Templates are `Reference` rows, so that is cheap, and it keeps the hole at two parts
instead of three. It also means the separator is visible in the template list rather than
scattered across every call site.

## Absence Renders Because Absence Is a Type

The one thing cardinality cannot express is a **negative branch** — render something *only if*
the query is empty. An empty result renders nothing by construction, so there is no `else` to
hang it on.

The language already has the answer: outer-join a `Null`-derived catch-all, and the row always
exists.

```
{{ self >< Account >< (Suspension where lifted is NotLifted) | NoSuspension }}
```

The row is now either a `Suspension` or a `NoSuspension`, and the theme's render function for
`NoSuspension` is what renders the empty case. **Absence renders because absence is a type**,
which is what the `Null`-rooted ADT family exists for.

This inherits the trap [constraints.md](constraints.md#absence) documents: a filter on an
outer-joined source must be written **inside** the join term. An outer-level `where` naming a
field of an outer-joined source is a compile-time error, here as there — otherwise every
suspension being lifted yields zero rows instead of a `NoSuspension` row, and the template
renders the opposite of what it says.

## Formatting Needs No Filters

A projected expression already mints a type ([queries.md](queries.md#view-field-types)), so a
hole may project one:

```
{{ money self.total }}
{{ truncate 80 self.description }}
```

Formatting is an ordinary function call. There are no filters, no pipes, and no template-local
helper namespace — the functions in a hole are the functions in the schema.

## Escaping Is a Type Property

A hole's output is escaped according to the type of the target document. Emitting unescaped
markup requires a value of type `Html`, which only a template or a render function can produce,
so **injection safety is a typing property rather than a template feature**. There is no
triple-brace raw-output escape, because there is nothing for it to do that the type system does
not already decide.

## Anchoring and Effect

A template's holes obey the same two rules the rest of the schema obeys:

- **Rooted at `self`**, every subsequent source reached by a join along a declared `:>` edge.
  A template renders per row on every read that reaches it, so an unanchored template would
  scan on every page render. Same rule, same reason, as
  [constraints.md](constraints.md#anchoring).
- **`Read` only.** A template is a projection. `Tx` and `Effect` are both rejected in a hole,
  so rendering a page cannot write and cannot call out. See
  [functions.md](functions.md#the-effect-ladder).

## What Composition Is Not the Template's Job

Page-level layout is the renderer's, not a template's. The renderer walks the schema by
PageRank weight and windows it by the user's information-density value
([../api-and-rendering.md](../api-and-rendering.md)); templates are the per-type fragments it
composes. That is why the template language needs no partials, no inheritance, and no blocks.

The cost is real and worth stating: **a page whose layout is not derivable from the schema walk
cannot be expressed as a template.** If that turns out to bind, the fix is a layout template
with iteration and conditionals of its own — at which point this stops being one production and
becomes a language, and the trade should be made deliberately rather than by accretion.
