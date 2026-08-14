# DataCode

A category-theoretic distributed database in Haskell. Currently **design/planning phase** —
the repository is documentation and feasibility spikes, no production source yet.

## Environment

Bash works, sandboxed: writes are confined to this repo and `$TMPDIR`, and the network is
limited to an allowlist (github.com, hackage.haskell.org, docs.anthropic.com and friends).
`dangerouslyDisableSandbox` is disabled by policy, so a command needing to write outside the
repo cannot be talked into working — ask the user to run it in their own terminal.

`ghc` and `cabal` are on `PATH` (ghcup, GHC 9.10.3). One routine casualty: `$HOME` is
read-only, so `cabal` fails to write `~/.cabal/logs/build.log` and exits non-zero with
`permission denied (Read-only file system)` *after* a successful build. Read the compiler
output, not the exit code.

**MCP servers do not load.** `claude mcp list` reports none configured even with `.mcp.json`
present and enabled, and `claude mcp add` is refused by policy — the allowlist matches on
exact server name, and adding one takes an administrator. Do not route around it;
`--mcp-config` is the documented sideload path and `disableSideloadFlags` exists to reject
it. So `tools/cabal-mcp` is unreachable as a server: to build or test anything, invoke
`cabal` directly from Bash.

## Repository Layout

`docs/` is design documentation, `docs/schema/` the normative schema language, `spikes/`
feasibility projects, `tools/` tooling. There is no `src/` — no production source exists yet.

Each spike is a self-contained cabal project with an `output.txt` holding its recorded run.
That file is the evidence cited by the answered OQs, so read it rather than rebuilding.
Build artifacts under `dist-newstyle/` are gitignored via `dist-*`.

`tools/cabal-mcp` builds clean and its stdio protocol has been exercised by hand, but it has
never run as an actual MCP server (see Environment). Known issues: `runInDir` reads stdout to
EOF before stderr and deadlocks once stderr fills its pipe buffer; stderr is discarded
outright on success, losing GHC warnings; `runTimed`'s `timeout` kills the Haskell thread but
leaves the spawned process running; `directory` reaches `cwd` unvalidated despite the doc
string promising repo-relative; output is unbounded; and `.mcp.json` launches via `cabal run`,
which rebuilds on every start — point `command` at the `cabal list-bin` path instead.

`docs/README.md` is the entry point and lists every document. `docs/open-questions.md`
tracks decisions as OQ-nnn, answered and outstanding — **check it before proposing a design
change**, because most of the obvious questions are already settled there with reasoning.

**Only create a new OQ-nnn for something that is genuinely open.** A decision that was never
in doubt does not become an open question just because it is new; recording it as one bloats
the file and buries the questions that actually need answers. A settled decision belongs in
two places instead: normatively in the relevant `docs/` file, and as a bullet under the
existing OQ that covers its area (OQ-005 is the decision record for schema syntax). An OQ
already marked ✓ ANSWERED is updated in place, not superseded by a new number.
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

Do not restate settled decisions back to them.

**Other load-bearing invariants**, each with reasoning recorded in `docs/`:

- **No NULL.** Absence is a typed ADT extending `Null` (`NotFound`, `Redacted`, `NotGiven`, …) so the *reason* for absence is in the type.
- **The schema is data.** Schema, routes, connector config, event queues, and auth all live in the same append-only transaction graph as user data. Self-hosting is a design goal, not an aspiration.
- **Nothing is destroyed.** Evolution adds graph nodes; old schema versions stay queryable. `deprecate` hides, `prune` removes, and only orphaned branches are truly deletable. Log data is the one exception, and even there discarding is never manual — a `retain` chain rolls it to coarser resolutions and prunes as a consequence; a `LogData` table with no chain is never pruned. Silence means keep.
- **No external calls inside a commit.** Side effects go to a queue table and run later under the event scheduler. An `a -> IO b` functor is rejected at schema commit.
- **Four functor kinds**: validation, foreign key, path equivalence, event. Data constraints and access control are the *same* kind (path equivalence), differing only in whether a path term is the requesting token. A `Behavior` is not a fifth — it enforces nothing, it projects.
- **Every table declares a candidate key** unless it carries `LogData`, `Component`, or `Keyless`. `DataId` does not count. On a shard-local table the key must reach the shard root through its FK chain, which makes the key declaration also the sharding declaration. Shards are row-rooted. A **view** declares none — its key is derived from its sources, and a derived key that degenerates to all attributes blocks incremental refresh and pins its sources against `deprecate`.
- **Time is a parameter, never ambient.** `Behavior a ≅ Moment -> a` for values that change with no write. `Moment` (observation, ranges over past and future) is distinct from `Timestamp` (stored). Nothing may read the clock inside a functor — that is the existing `a -> IO b` rejection doing the work.

## Syntax Quick Reference

Full detail in `docs/schema/`. **Capitalization**: types, traits, tables, views, and variants are `UpperCamelCase` and singular; fields are `lower_snake_case`; functions and constraint names are `lowerCamelCase`; namespaces are `lowercase`. So `app.commerce.Order`.

The two tokens most easily got wrong:

- `:` is "is a kind of" — types, traits. `:>` is "references a row in" — foreign keys. Using one where the other belongs is a compile-time error. In an alternation only the *head* decides: `customer :> Customer | MissingCustomer`.
- Inside a body, declarations are `,`-separated and closed by `}`; leading-comma style when any field has a block `where`. At top level there is no separator — a declaration ends at the next token in column 0.

```
type Email : Text where isValidEmail

table app.commerce.Order : UserData {
  customer  :> Customer,
  order_num : Int,
  total     : Amount = 0
    where
      \a -> a >= 0
      isRoundedToCents
  , status  : Pending | Shipped | Cancelled = Pending
  , courier :> Courier | NotDispatched,
  unique orderRef { customer, order_num },
  order by placed_at desc,

  on status is Shipped emit app.events.email_queue { recipient = customer.email },
  assert access { user.id == customer.user_id }
}
```

## Working Norms

- Analysis before implementation when the user asks for it — they frequently do, and they mean it.
- When a decision has a real trade-off, state a recommendation rather than surveying options.
- Flag adjacent inconsistencies you notice, but don't fix them unilaterally when the fix is itself a design decision.
- Record every settled syntax or architecture decision with its reasoning and what it replaced — normatively in `docs/`, and as a bullet under the covering OQ. New OQ numbers are for open questions only; see above.
