# DataCode

A category-theoretic distributed database in Haskell. Currently **design/planning phase** —
the repository is documentation and feasibility spikes, no production source yet.

## Environment

**The Bash tool does not work here.** Every command fails with
`bwrap: Can't mount tmpfs on /newroot/home/cstobey/.aws: No such file or directory` — the
sandbox deny-list names paths that don't exist under WSL2. This is known and the user has
chosen to live with it. Do not retry, and do not propose `mkdir` fixes.

Consequences:

- No directory listing. Discover files by probing likely paths with parallel `Read` calls
  (failures are cheap) and by following cross-references. Say so when an inventory is
  probe-based and may be incomplete.
- No `grep`. For a repo-wide sweep, hand the user a `! grep -rn '…' docs/` line — the `!`
  prefix runs it in their session and the output lands in the conversation.
- No file deletion. `Write` can stub a file; the user runs `git rm`.

## Repository Layout

```
docs/          17 design documents — see docs/README.md for the index
docs/schema/   the schema language, 10 files by topic; normative
spikes/        5 standalone Haskell feasibility projects
```

That is the whole repository. There is no `src/` yet, and no `.claude/plans/`.

The five spikes are `capnproto`, `dynamic-loading`, `route-trie`, `servant-warp`, and
`storage`. Each is a self-contained cabal project with an `output.txt` holding its recorded
run — that file is the evidence cited by the answered OQs, so read it rather than rebuilding
(you cannot run cabal anyway; see Environment). Build artifacts under `dist-newstyle/` are
gitignored via `dist-*`.

`docs/README.md` is the entry point and lists every document. `docs/open-questions.md`
tracks decisions as OQ-nnn, answered and outstanding — **check it before proposing a design
change**, because most of the obvious questions are already settled there with reasoning.
`docs/category-model.md` is the theoretical foundation and explains *why* the design is
shaped as it is; `docs/schema/` is the operational *what*.

`docs/schema/railroad.md` holds the full EBNF for the schema language *and* the CLI. It is
the single source of truth for syntax: the EBNF is both the normative grammar and the
railroad-diagram source (rendered at https://rr.red-dove.net/ui.html). If a syntax decision
changes, that file must change.

## Design Principles

**Make it feel like Haskell.** This is the tie-breaker for syntax decisions. DataCode's
constructs may carry narrower meanings than their Haskell counterparts — `where` constrains
a type rather than binding names — but the *shape* should be what a Haskell reader expects.
Settled consequences: `=` binds and `==` compares; `/=`, `&&`, `||`, `not`, `True`, `False`;
one `where` per declaration with an indented block, never repeated; the offside rule for
continuation; `let … in` for local bindings.

The user is a senior data architect with a category theory background who prefers functional
style and terse output. Do not restate settled decisions back to them.

**Other load-bearing invariants**, each with reasoning recorded in `docs/`:

- **No NULL.** Absence is a typed ADT extending `Null` (`NotFound`, `Redacted`, `NotGiven`, …) so the *reason* for absence is in the type.
- **The schema is data.** Schema, routes, connector config, event queues, and auth all live in the same append-only transaction graph as user data. Self-hosting is a design goal, not an aspiration.
- **Nothing is destroyed.** Evolution adds graph nodes; old schema versions stay queryable. `deprecate` hides, `prune` removes, and only orphaned branches are truly deletable.
- **No external calls inside a commit.** Side effects go to a queue table and run later under the event scheduler. An `a -> IO b` functor is rejected at schema commit.
- **Four functor kinds**: validation, foreign key, path equivalence, event. Data constraints and access control are the *same* kind (path equivalence), differing only in whether a path term is the requesting token.

## Syntax Quick Reference

Full detail in `docs/schema/`. The two tokens most easily got wrong:

- `:` is "is a kind of" — types, traits. `:>` is "references a row in" — foreign keys. Using one where the other belongs is a compile-time error. In an alternation only the *head* decides: `customer :> Customer | MissingCustomer`.
- Inside a body, declarations are `,`-separated and closed by `}`; leading-comma style when any field has a block `where`. At top level there is no separator — a declaration ends at the next token in column 0.

```
type Email : Text where isValidEmail

table app.commerce.Order : UserData {
  customer :> Customer | MissingCustomer,
  total    : Amount = 0
    where
      \a -> a >= 0
      isRoundedToCents
  , status : Pending | Shipped | Cancelled = Pending,
  order by placed_at desc,

  assert access { user.id == customer.user_id }
}
```

## Working Norms

- Analysis before implementation when the user asks for it — they frequently do, and they mean it.
- When a decision has a real trade-off, state a recommendation rather than surveying options.
- Flag adjacent inconsistencies you notice, but don't fix them unilaterally when the fix is itself a design decision.
- Record every settled syntax or architecture decision in `docs/open-questions.md`, including the reasoning and what it replaced.
