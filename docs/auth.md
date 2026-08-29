# Authentication and authorization

## Identity provider

DataCode is its own identity provider. There is no dependency on an external IdP (OAuth, LDAP,
etc.) for the core system, though the user table can be federated by extension (see
[Self-management and extensibility](#self-management-and-extensibility)).

User and client credentials are ordinary rows in `system.auth.*`, declared with the same
table and functor machinery as application data. This means:

- Auth rules are access control functors over the same schema graph as application data.
- The auth system is inspectable, auditable, and extensible through normal schema operations.
- DataCode's own auth schema is queried and modified through the same interface as anything else.

There is no `system` shard. `system` is a namespace, and each table in it carries whichever
replication trait fits ([traits.md](schema/traits.md#replication-traits)). Which trait each auth
table carries, and why, is [below](#where-auth-data-lives).

## Where auth data lives

**Auth is `UserData`, sharded by user.** A cluster holds millions of accounts, so anything keyed
by user scales with user count, which is the definition of `UserData`. `Configuration` was the
earlier answer and it was wrong twice over: it rates "medium cardinality, operator-managed", and
it would put every credential digest and every contact address on every server in the cluster —
the exact replication property [integrity.md](integrity.md#erasure-restricts-scrub-destroys)
identifies as a privacy problem.

| Trait | Tables | Why |
|---|---|---|
| `Reference` | `Role`, `CredentialMethod`, `Client`, `ClientReach` | Code tables. Low cardinality, genuinely identical everywhere, and inserting one is a schema commit. |
| `Configuration` | `Origin`, `RequiredIdentifier`, `Grant`, `system.crypto.*` | Deployment facts. Replicated everywhere so the auth path is shard-local on every server. |
| `UserData` | `User`, `Credential`, `Contact`, `Challenge`, `Registration`, `ClientToken`, `AccountKind` | Keyed by user, scales with user count, rooted at `User`. |
| `LogData` | `AttemptDigest` | An occurrence written by whichever server handled the attempt. |

This is a trait change rather than a redesign, because the keys already reach the root:
`Credential` is keyed `{ user, method }`, and `user` is the foreign key to the shard root. The
key declaration is the sharding declaration ([tables.md](schema/tables.md#keys-must-be-rooted)),
and it already said `UserData`.

Three consequences, and the design had already anticipated the one that matters.

**Login is a shard-directory lookup, and that is the good case.** `User.username unique` is the
root table's key, which *is* the cluster shard directory
([tables.md](schema/tables.md#keys-must-be-rooted)) — the one key that must be globally unique is
also the one the system already needs a global index for. So `authenticate` resolves
username → `DataId` → shard, and everything after that is one shard-local read. A bulk credential
import becomes a shard-local operation instead of a cluster-wide event.

**Token validation must not touch the user's shard on every request**, or every request to any
table becomes two shards. It does not have to: session validity is a `Behavior` sampled at the
request's moment, so the user's shard is touched at **login** and at **revocation** and nowhere
else. See [Token expiry and revocation](#token-expiry-and-revocation), which was written for a
different reason and turns out to be what makes distributing auth affordable.

**Any role holder can authenticate, not only the primary.** Credential validation is a read;
secondaries serve reads directly and tertiaries serve them eventually-consistently
([distribution.md](distribution.md#tertiary-servers-any-number)), so a point-of-presence tertiary
resolves the user's shard through the directory and authenticates locally with no hop. That is
what tertiaries are for. It holds on one condition, and it is the difference between a read and a
write: **issuing a session must not be a row write.**

`system.auth.AttemptDigest` stays `LogData` and does not move into the user's shard. Each server
already roots its own segments, so a tertiary writing its own log rows is the existing model
rather than a tertiary accepting writes; the cluster-wide comparison the table exists for becomes
a distributed read merged across servers, which is the shape integrity reporting already uses.

`system.auth.Challenge` is the one table that had to move rather than merely change trait. It was
`LogData`, so it was rooted at a `LogSegment` on the server that wrote it — not in the user's
shard, which is where verification looks for it. It is now `UserData` rooted at `User`: a
challenge is an occurrence *with an owner*, its retention is still a `retain` chain, and being an
ordinary versioned row is also what gives the delivered code a write-back path
([below](#challenge-methods)).

## Token types

Every request carries **two tokens**.

### Client token

- Identifies the software making the request, and for an installed client, the device it runs on.
- Resolves to a `system.auth.Client` row, which decides which schema objects the request may
  reach at all. See [Clients](#clients).
- Restricted schema-level reach, expressed as data rather than as mechanism.

### User token

- Identifies the human or service identity on whose behalf the request is made.
- Resolves to a `system.auth.User` row, which is what `authed_user` is bound to.
- Grants row-level access on top of whatever the client token allows. Row-level restrictions are
  access control functors — path constraints in the schema graph.

**A server presents a client token like everything else.** There is no third token type. A server
is a `Client` whose reach is the root namespace and cannot be narrowed, which retires the last
surviving second identity model; OQ-015 already refused one for service accounts, and the same
argument retires `ServerToken`. Two names for one thing is what the `Client`/`Registration` split
removed.

**One carve-out, and it is named.** An external service posting to a webhook holds neither token —
signature verification is precisely a substitute for them. A `system.api.CustomRoute` whose functor
establishes caller identity by signature therefore substitutes for the pair, and every row it
inserts is attributed to the connector's service-account `User`. Which signature schemes are
admissible is [OQ-020](open-questions.md#oq-020-webhook-endpoint-security). Without this carve-out
the absolute claim and webhook ingestion as documented cannot both be true.

### Token lifecycle

```
Client registration (once per application):
  A schema author commits a system.auth.Client row and its ClientReach rows.
  A Reference insert is a schema transaction, so reach is versioned in the graph and
  replicates everywhere. Old versions stay queryable; nothing is destroyed.

Device registration (once per installed device):
  The device presents a live user token and names a Client.
  The identifiers system.auth.RequiredIdentifier demands for that client are supplied.
  The server writes a Registration and mints generation 1 of its ClientToken.
  The secret is returned once, by an Effect function, because a Hashed field reads as
  Sealed and can never be read back.
  Browsers do not register. The Origin row for the request host names the Client and the
  token is issued per session, bound to that origin.

Login (once per session):
  The user presents a credential for one method (see Credential storage).
  Any method named by that method's `requires` chain is presented in the same exchange.
  The server verifies against the user's shard and returns a session token.
  A session token is a bearer value, not a row: any role holder can complete a login.

Per request:
  The request host is matched against system.auth.Origin: exact, case-folded, port-stripped.
    Unknown host -> refused before routing.
  The client is resolved from the token's Registration, or from the Origin for a browser.
    The origin recorded on the token must equal the request host; mismatch rejects.
  The user is resolved from the session token. No user token -> authed_user is NotAuthenticated.
  Reach = the ClientReach closure for that Client. A name outside it does not resolve.
  Row access = the asserts mentioning authed_user.

Rotation and revocation:
  Rotation adds a ClientToken generation; earlier generations stay live until they expire.
  Revocation is a status write to Registration, or a shortened session. Nothing is deleted.
```

The credential presented at login is method-agnostic: password, API key, and — once
[OQ-011](open-questions.md#oq-011-fido2webauthn-for-long-lived-credentials--answered) is taken up —
hardware key. The identity model does not change to accommodate a new one, which is the point of
the `User`/`Credential` split below.

## Clients

The client **kind** and the **registry of installations** are two things, and conflating them is
what made the naming hard. Split them and no qualifier word is needed.

```
type Hostname    : Canonical Text using system.text.Policy.hostname
type SchemaPath  : Text where isSchemaPath
type TokenSecret : Hashed Text using system.crypto.HashPolicy.token_v1
type NotBound    : Null

table system.auth.Client : Reference {
  name : Text unique
}

table system.auth.ClientReach : Reference {
  client :> Client,
  target : SchemaPath,
  unique reachOf { client, target }
}

table system.auth.Origin : Configuration {
  host    : Hostname unique,
  client  :> Client,
  arrival : Direct | ViaProxy = Direct
}
```

`Client` is `Reference`, so a client row *is* schema: adding one is a schema commit, `client is
AdminIde` is checked at schema-commit time, a mistyped kind is a compile error, and a `:> Client`
field costs two bytes rather than twelve
([traits.md](schema/traits.md#reference-tables-are-code)). Four rows ship with the system —
`Storefront`, `AdminIde`, `Cli`, `Server` — and a deployment adds its own.

`Client` may not carry `Extensible`. Auto-registering a client is privilege escalation, and the
rate-limit argument that saves `Extensible` elsewhere does not reach it.

**Reach is a set of reachable schema objects, and narrowing below a whole table is a derived
table.** `ClientReach` names namespaces and tables, reusing the namespace access model unchanged —
default-deny, explicit grants, recursion downward over the named subtree, no deny rows
([namespaces.md](namespaces.md#namespace-access-control)). Where a client needs *less* than a whole
table, it reaches a binding instead of the table:

```
app.commerce.OnlineOrder = Order
  where channel is Online
  { customer, order_num, total, status, placed_at }
```

The storefront's `ClientReach` names `app.commerce.OnlineOrder` and not `app.commerce.Order`.
Everything a narrowed client needs then falls out of machinery that already exists: the `where`
is a read filter the planner pushes down, the projection is the field-level restriction, the
filter's constant conjuncts check on write and supply `channel = Online` on insert
([queries.md](schema/queries.md#writing-through-a-derived-table)), and the binding is an ordinary
materialization candidate. Rows outside it are absent rather than `Redacted`, which is correct:
`Redacted` says "you may not see this, ask someone", and a client can never be granted the row by
asking.

Two rules make that safe, and neither is expressible in the grammar:

- **A `ClientReach` row naming a binding grants the binding and not its sources.** The storefront
  may not write `OnlineOrder >< Order`.
- **The binding is evaluated under the server's authority**, exactly as a materialized view is.
  Reaching a binding is not reaching *through* it.

One interaction is worth pricing rather than discovering: a client-scope binding whose derived key
is degenerate is read-only and pins its sources against `deprecate`
([queries.md](schema/queries.md#what-the-key-decides)). So a `group` inside a client's binding
silently makes that client read-only. Schema commit names the client in that diagnostic.

**`Server` cannot be narrowed.** Its single `ClientReach` row names the root namespace, and
neither the row nor the reach may be shrunk or deprecated. The reason is not privilege but
mechanism: a server already holds the whole shard, so filtering it would filter replication itself
([distribution.md](distribution.md#tertiary-servers-any-number)).

`SchemaPath` is a path rather than a `:>` because a reach or a grant names a *subtree* of the
namespace tree, and a subtree is not a row — there is nothing to point a foreign key at.
Resolution is therefore by name at request time, the same shape as
[`CipherPolicy.key_name`](#envelope-encryption-and-key-custody), and it means a reach naming a
deprecated namespace confers nothing until that name is declared again.

### Request origin

**The hostname is an issuance-time selector, never an authorization input.** `Origin` chooses
which `Client` a browser's token is minted for. It never grants anything to a request that already
carries a token: at request time the origin recorded on the token is compared for *equality* with
the request host, and that is all it does. Getting this backwards is what would let a browser reach
`system.auth` by sending `Host: ide.example.com`.

Four rules, in request order:

1. **Match exact** — case-folded and port-stripped, which is what the `Hostname` canonical type
   does on write. No wildcards and no suffix matching: a suffix rule for `example.com` admits
   `evil-shop.example.com.attacker.net`.
2. **An unregistered host is refused before routing**, with 421 Misdirected Request — the status
   code exists for exactly "this connection is not authoritative for this host". Never a default
   client.
3. **Token and origin must agree.** The origin recorded on the token must equal the request host.
   This is audience restriction, and it is what stops replay between two clients on one cluster.
4. **A reverse proxy is declared, and the proxy authenticates.** A `ViaProxy` origin accepts a
   forwarded host only on a connection presenting a token for the `Server` client. A `Direct`
   origin ignores forwarded headers entirely.

> **Security consequence.** If DataCode accepts a forwarded host from any peer that can reach the
> port, every client kind is spoofable by anyone who can reach the port, and `AdminIde` — the one
> with reach into `system` — is spoofable first.

The damage is bounded because the origin set is registered and default-deny: getting the mapping
wrong cannot grant reach that no registered origin has. It can only confuse two registered origins
with each other, which is why `AdminIde` and `Server` must never share a hostname with an
application client.

## Device registration

Client tokens are issued to a **device**, and registration is what binds one:

```
table system.auth.RequiredIdentifier : Configuration {
  client :> Client,
  name   : Text,
  unique identifierOf { client, name }
}

table system.auth.Registration : UserData, Personal {
  user        :> User,
  client      :> Client,
  device      : Text,
  origin      :> Origin | NotBound,
  status      : Active | Revoked Timestamp = Active,
  identifiers :> DeviceIdentifier : Component {
    name  : Text,
    value : Text,
    unique identifierValue { name }
  },
  unique deviceOf { user, client, device },

  assert registrantAccess { authed_user == user }
}

table system.auth.ClientToken : UserData, Personal {
  registration :> Registration,
  generation   : Int = next tokenOf,
  secret       : TokenSecret,
  expires_at   : Timestamp,
  is_live      : Behavior Bool = \m -> m < expires_at,
  unique tokenOf { registration, generation }
}
```

- **The identifiers a platform can supply differ** — a desktop install, a mobile app, and a
  headless agent agree on nothing — so the required set is `Configuration` rather than fixed
  schema, and the supplied values are components of the registration. Which identifiers each
  client must supply is [OQ-008](open-questions.md#oq-008-client-token-provisioning); that the set
  is tunable rather than fixed is settled.
- **`next tokenOf` allocates within `{ registration }`**, so rotation is a shard-local
  read-modify-write in a shard the transaction already touches, and earlier generations stay live
  until they expire. Same shape as `DataKey { name, generation }`
  ([below](#envelope-encryption-and-key-custody)).
- **A browser is not a device.** It gets no `Registration` row: `Origin` maps the host to a
  `Client` and the token is issued per session against that origin. This is also the browser
  answer for OQ-008 — the required identifier set is empty, so a browser client token is only as
  strong as its transport and must be short-lived. Ten million browsers do not become ten million
  rows.
- **`registrantAccess` is a real access assert.** A user sees their own registrations; an
  administrator holding `bypass access` on `system.auth` sees all. That does not widen the
  administrator's *client* reach, which is the point.
- Registration produces a token scoped to a namespace subtree
  (`issue client token for "MyApplication" scoped to app.commerce`), rotatable without disturbing
  the user tokens presented alongside it.

## Credential storage

**The user table is authentication-method agnostic.** A `User` row is an identity; how that
identity is proved is a row in a separate table, keyed by user and method. That split is what lets
one user hold several credentials at once — a password, an API key, and a hardware key — and it is
what lets a new method be added without touching `User` or the rows already in it.

```
type ApiKey           : Hashed Text using system.crypto.HashPolicy.api_key_v1
type NoPrerequisite   : Null
type AuthFailed       : Null
type NotAuthenticated : Null
type Session          : Text

type Username : Canonical Text using system.text.Policy.username
  where
    minLen 3
    maxLen 64

table system.auth.User : UserData, Personal {
  username : Username unique,
  role     :> Role = Member,
  status   : Active | Locked | Suspended = Active
}

table system.auth.Credential : UserData, Personal {
  user   :> User,
  method :> CredentialMethod,
  secret : Password | ApiKey,
  unique perMethod { user, method }
}

table system.auth.CredentialMethod : Reference {
  name     : Text unique,
  requires :> CredentialMethod | NoPrerequisite,
  standing : Primary | SecondFactor = Primary
}

table system.auth.Role : Reference {
  name : Text unique
}
```

`type Password` lives with the constructor that produces it, in
[types.md](schema/types.md#hashed-types), where it is the worked `Hashed` example; repeating the
declaration here is how the two copies drifted the first time. `ApiKey` has no second home, so it
is declared above.

`Username` is `Canonical` because it is the shard-directory key: two spellings of one name must
not be two accounts, and canonicalizing on write keeps `==`, `unique`, and the index ordinary
operations over ordinary bytes ([types.md](schema/types.md#canonical-types)).

`role :> Role = Member` names a `Reference` row, which is the one default a `:>` field may carry —
the foreign key stores a two-byte variant tag rather than a `DataId`, so the default names schema
and not a deployment row. Without it a service account could not be written through
[`ServiceAccount`](#self-management-and-extensibility), because `role` is a required field of
`User` and nothing supplies it.

`CredentialMethod` and `Role` are `Reference` tables, so adding a method or a role is a schema
commit and `method is CredentialMethod.Password` is checked at schema-commit time
([traits.md](schema/traits.md#reference-tables-are-code)). Write the test qualified: `Password` is
also the name of a type, and `method is Password` reads as a constructor match against that type.

`Personal` on `User`, `Credential`, and `Contact` is what makes a subject-access erasure possible
at all — `erase` requires the named table to carry it. `User` is the erase root and the rest cascade
through the foreign-key chain
([integrity.md](integrity.md#erasure-is-restriction-of-processing)). Without the trait, the one
table in the corpus that stores contact addresses would be the one table that could never be
erased.

The two fields on a method answer different questions and neither is derivable from the other.
`requires` is a **prerequisite edge**: presenting this method also demands that one was satisfied
in the same exchange, which is what login walks. `standing` is a **classification**: a
`SecondFactor` never authenticates alone regardless of what it requires. Multi-factor is therefore
a property of the method rather than a branch in the login code, and demanding it of particular
users is an ordinary presence assert:

```
assert system.auth.User.secondFactorForAdmins {
  role is not Role.Admin
  || self >< Credential >< (CredentialMethod where standing is SecondFactor)
}
```

The rule reads as what it is — an administrator must hold a credential under some method that does
not authenticate on its own. A query in boolean position asserts that its result is non-empty, and
that rule now holds in *every* `Bool` position, which is what lets the query be an operand of `||`
([railroad.md](schema/railroad.md#tables-bindings-traits)). See
[constraints.md](schema/constraints.md#presence).

### Not every credential fits `Hashed`

Three shapes, and the type is what tells them apart:

| Credential | Constructor | Why |
|---|---|---|
| Password, API key | `Hashed` | Verified by re-deriving a digest from the presented value. |
| Authenticator-app shared secret, connector outbound credential | [`Encrypted`](schema/types.md#encrypted-types) | The server must *reproduce* the value, not re-derive a digest of it. |
| WebAuthn credential | neither | The stored value is a **public** key. It needs no confidentiality, and verification needs its value. |

Key custody for the second row is [below](#envelope-encryption-and-key-custody). Most deployments
need none of it, because the most-wanted second factor needs no recoverable secret at all — see
[Challenge methods](#challenge-methods).

The third row is why `WebAuthnKey` is gone from `Credential.secret`. WebAuthn authentication is a
signature check over the authenticator data and a hash of the client data, using the stored
credential public key as an *input* to the verification function. A one-way digest of that key
makes verification impossible, and a `Secret` read of `Sealed` makes even the digest unreachable.
It goes in its own table, where none of the three columns is a secret:

```
table system.auth.WebAuthnCredential : UserData, Personal {
  credential    :> Credential,
  credential_id : Bytes,
  public_key    : Bytes,
  sign_count    : Int,
  unique webauthnOf { credential }
}
```

Verification is a compiled-in verifier, not `matches` — `matches` has no shape that could carry a
challenge, authenticator data, and a signature. The `Credential` row still exists and still names
its `CredentialMethod`, so the `requires` chain and the presence assert above are unchanged; only
the secret moved. OQ-011's "adding WebAuthn later touches no existing row" therefore still holds —
a new method is a new `CredentialMethod` row and a new `WebAuthnCredential` row — with the
correction that the key was never storable in `Credential.secret` in the first place.

Discoverable credentials — where the browser offers a credential before naming a user — would need
a cluster-wide index on `credential_id`, which is the shard-directory shape and a second global
constraint. Deferred: the non-discoverable flow resolves the user first, then the credential, and
needs no such index.

`ApiKey` and `Password` are both `Hashed`, so `Credential.secret` is `Secret` however an
alternation's secrecy is decided, and four things follow automatically
([types.md](schema/types.md#secret-types)):

- `Credential.secret` reads as `Sealed`, never as bytes, for every token.
- `==` against it is a compile-time error. Verification goes through `matches`.
- Its validation predicates may only be `a -> Bool`, so no error payload can carry the plaintext
  into the append-only log, where nothing could subsequently remove it.
- `unique` on it is a compile-time error — per-row salts mean it would never fire.

### Breach checking

The recommended password policy is length plus a breach-list check, which is where NIST SP 800-63B
moved and what the declaration in [types.md](schema/types.md#hashed-types) uses. `isBreached` has
to be placed carefully, because a validation predicate is functor kind 1 and runs inside the
commit:

> **`isBreached` is a compiled-in `Pure` predicate over a locally mmapped breach corpus, shipped
> with the server generation and swapped the way a generation is swapped.**

A network lookup is out — the missing `Effect → Tx` lift forbids it inside a commit. So is a
corpus in the graph: hundreds of millions of digests is not a `Reference` code table, and as
`Configuration` it would replicate to every server. The corpus is versioned like a
`system.crypto.HashPolicy` row so a check is reproducible, and **where the corpus is absent the
predicate fails open and records a `Forced` violation** — the alternative locks every user out of a
system whose password file is intact.

### Importing a foreign digest

Migrating from another system means admitting a digest DataCode did not produce. The plaintext is
not available, so the ordinary write path — which hashes its input — cannot express it.

```
system.auth.Credential {
  user   = u,
  method = CredentialMethod.Password,
  secret = preHashed system.crypto.HashPolicy.legacy_mariadb
             "*2470C0C06DEE42FD1618BB99005ADCA2EC9D1E19"
}
```

`preHashed` is an ordinary function, not a keyword — `FuncApp` already admits it — and its result
type is what gates it: a field read yields `Sealed`, so `preHashed` is the only expression in the
language that produces a `Hashed` value. The mechanism, the verification-only policy that carries
no deriver, and the pipeline steps it skips belong to
[types.md](schema/types.md#hashed-types). What belongs here is the authority to call it and the
shape of a migration.

- **Calling it requires a grant naming the function**, checked on every token including a client
  token for `Server`: `grant system.auth.Role.Migrator on system.crypto.preHashed`. Because
  functors are DSL terms whose structure is stored, schema commit can answer "which routes and
  handlers reach `preHashed`?" and warns where one is reachable by a token that does not hold the
  grant.
- **A migration is a handler running as a service account**, not a binding. A binding would leave
  the digest in a plain `Text` column on the shadow table — outside the `Secret` apparatus,
  readable, and re-evaluated on every read.
- **The import is its own audit anchor.** The mutation expression is in the transaction graph as
  structure, with its author, so "find every imported credential" is a query rather than a log
  grep. That is also why passing a *plaintext* to `preHashed` must be rejected at commit rather
  than discovered later: it would put a live credential in the append-only log permanently.
- **Upgrade-on-login appends a version**, so the foreign digest stays readable at earlier sample
  moments and in every backup. For a broken scheme that leaves open the exposure the migration was
  meant to close, so a migration ends with a `scrub` of the superseded versions
  ([integrity.md](integrity.md#scrub-overwrites-payload-bytes)).

## Challenge methods

A `Credential` row is an **enduring capability**: something the user holds, keyed
`{ user, method }`, durable and replicated. A one-time code sent to the user is not that. It is an
**occurrence** — issued, delivered, used once, and gone — and separating the two is what the
`User`/`Credential` split makes possible. It gets its own table:

```
type ChallengeCode : Hashed Text using system.crypto.HashPolicy.challenge_v1
type NotIssued     : Null

table system.auth.Contact : UserData, Personal {
  user     :> User,
  channel  : EmailChannel | Sms | Push,
  address  : Text,
  status   : Verified Timestamp | Unverified = Unverified,
  unique contactOf { user, channel, address }
}

table system.auth.Challenge : UserData, Personal {
  user        :> User,
  method      :> CredentialMethod,
  destination :> Contact,
  generation  : Int = next challengeOf,
  code        : ChallengeCode | NotIssued = NotIssued,
  expires_at  : Timestamp,
  state       : Issued | Consumed = Issued,
  unique challengeOf { user, method, generation },

  is_live : Behavior Bool = \m -> m < expires_at,

  on state is Issued emit system.events.NotifyQueue {
    challenge = self,
    contact   = destination,
    template  = method.name
  }
}
```

```
retain system.auth.Challenge
  for 30 day
  , drop
```

`channel` spells the first variant `EmailChannel` rather than `Email` on purpose. An inline
alternation puts each name in type position, and `type Email` is in scope in every example schema,
so a bare `Email` would resolve to that type instead of introducing a variant.

Six things fall out, and none of them is new machinery.

**The send is an event on insert.** Issuing a challenge *is* inserting the row, and delivery is the
scheduler's problem — retried under `system.events.QueuePolicy`, rate-limited, and never holding
the commit open. This is exactly what "no external calls inside a commit"
([events.md](events.md#design-principle)) was written for. Insert is the degenerate case of the
false-to-true rule: before the write the row did not exist, so the condition was not true.

**The code is generated in the handler, not in the commit.** This is the ordering the section
previously left out, and every other exit is closed: the plaintext cannot be in the queue payload,
because the queue is a log; it cannot be read back off the row, because a `Hashed` field reads
`Sealed` for every token; and it cannot be sent from the inserting transaction, because that is an
external call. So:

1. The commit inserts the challenge with `code = NotIssued`.
2. The `on state is Issued` trigger enqueues a notification naming the challenge row.
3. The handler generates the code in `Effect`, sends it, and commits the digest back to
   `Challenge.code`. `commit :: Tx a -> Effect a` is available to a handler, and the write-back is
   an ordinary new row version — which is the second reason `Challenge` is `UserData` rather than
   `LogData`, since a log row could not be written twice.
4. Verification reads the row and calls `matches`. A challenge whose `code` still reads
   `NotIssued` has not been delivered and cannot be satisfied.

The plaintext therefore never exists in `Tx` at all: it is created, used, and discarded inside one
handler invocation.

**Expiry is a [behavior](schema/types.md#behaviors).** Nothing marks a challenge expired and
nothing polls it; `is_live` is a function of `Moment`, sampled at whatever moment the request
carries. There is no `Expired` state because no write would ever produce one — the same treatment
session expiry gets, and the same reason.

**Retention is a `retain` chain.** Spent challenges are pruned as a consequence of the chain rather
than by anything manual, which is the only row-level pruning path there is
([aggregates.md](schema/aggregates.md#retain-on-userdata-is-admissible-and-rare)).

**The destination is pinned at issue.** `destination :> Contact` is recorded on the challenge
rather than resolved from the user when the queue item runs, so editing a contact address cannot
redirect a code already in flight.

**It needs no reversible secret.** The code is hashed and verified with `matches` exactly as a
password is. Short-livedness is not a reason to store it in the clear: a bearer credential valid
for ten minutes grants login for ten minutes to anyone who can read it, and the log it would be
read from is append-only. `challenge_v1` is a deliberately slow policy for the same reason a
password policy is — a six-digit code carries about twenty bits, so the digest is worth little
without a cost factor, and the throttle [below](#failed-attempt-digests) is the other half.

### What this does and does not cover

Two mechanisms get called "TOTP" and only one of them fits above.

| | Delivered code | Authenticator app (RFC 6238) |
|---|---|---|
| Secret | generated per attempt | provisioned once, never re-transmitted |
| Stored as | `Hashed` — verified by re-hashing | `Encrypted` — recovered to recompute the code |
| Costs | nothing beyond what exists | a data key and its custody |

Reach for the delivered code first. It is the one most deployments want, it needs no key
management, and a code that lives ten minutes cannot be stolen from a backup taken a year later.
The authenticator app and a connector's outbound credential are the two cases that justify the key
custody below.

A `Challenge` is not a `Credential` and does not appear in `Credential`'s key, but it satisfies a
`CredentialMethod` the same way one does — so a method whose `standing` is `SecondFactor` may be
satisfied by a consumed challenge, and the `requires` chain walks the two uniformly.

The `where` predicates on a `Hashed` type run on the plaintext, which is the only stage that sees
it; the digest is produced afterwards and is all that reaches the transaction log. That ordering is
fixed by the type, not by convention — see
[functors.md](schema/functors.md#order-of-operations-for-a-field-write).

**Note on policy content.** The mechanism supports composition rules ("must contain a symbol")
because some environments are required to have them. The recommended default policy does not
include them, for the reason in [Breach checking](#breach-checking).

## Login

```
authenticate : Username -> Text -> Text -> Session | AuthFailed
authenticate user_name method_name attempt =
  let u = system.auth.User where username == user_name
      m = system.auth.CredentialMethod where name == method_name
      c = system.auth.Credential where user == u && method == m
  in if attempt `matches` c.secret && u.status is Active
       then issueSession u m
       else AuthFailed
```

All three lookups resolve a single row — `User.username` is `unique`, `CredentialMethod.name` is
`unique`, and `Credential` is keyed `{ user, method }` — which is what `matches` requires
([queries.md](schema/queries.md#a-query-that-pins-a-key-denotes-a-row)). `matches` hashes its
**left-hand** argument under the policy recorded on the stored value to its right and compares in
constant time; ``Credential where attempt `matches` secret`` is a scan of every row against a
per-row salt and is rejected at compile time.

**Every parameter is named so that no column shadows it.** An earlier version wrote
`authenticate name method attempt` and then `where user == u && method == method`, which compares
`Credential.method` to a parameter of the same name — a tautology, so the lookup narrowed only on
`user` and did not resolve the single row the next sentence claimed. Nothing in the language
resolves a column against a parameter of the same name, so the fix is naming rather than a scoping
rule.

The three bindings are one `let` block. A multi-binding `let` whose right-hand sides are queries
parses ([railroad.md](schema/railroad.md#functions-and-expressions)); it did not until this pass,
which left this example deriving from nothing.

The failure result is `AuthFailed`, an ordinary absence type. DataCode has no `Either`, and
inventing one for this one function would have introduced a second way to spell absence.

**Login is one shard-directory lookup and then one shard-local read.** `username` resolves to a
`DataId`, the `DataId` names the shard, and `Credential` is in that same shard because its key is
rooted at `user`. Any role holder can serve it — see
[Where auth data lives](#where-auth-data-lives).

Login is per method, and a method whose `requires` names another is not sufficient on its own: the
session is issued only once every prerequisite in that chain has been satisfied in the same
exchange. Which methods a deployment demands of which users is the assert above, not a branch here.

`authenticate` runs under the `Server` client's authority rather than the requester's. It is the
one function that does, and it is compiled in — the same shape as the one place a validation
functor legitimately runs outside a commit, below. Without it a browser would need `Credential` in
its reach to log in.

## Password policy rotation

Rotating the hash algorithm or tightening the password rules is repointing `Password` at a new row
in `system.crypto.HashPolicy` — a schema commit against a populated field, which by the rule in
[integrity.md](integrity.md#mode-is-mandatory-on-a-populated-field) must state an enforcement
mode. That rule covers a change of `using` policy as well as an added predicate, and the statement
addresses the field path with no `/`, because a storage transform is not one predicate within a
block ([types.md](schema/types.md#rotation)):

```
enforce system.auth.Credential.secret forward
```

Existing credentials keep working, and every row under a superseded policy becomes a reportable
violation.

Two of the three checks are **derivable** — the stored value records which policy produced it, so
"hashed under a policy other than the field's current one" is a standing query, not a consequence
of any particular rotation commit. That is also what puts an
[imported foreign digest](#importing-a-foreign-digest) on the ordinary migration path with no new
mechanism. The third check is not derivable. Whether a stored password satisfies a *new length or
content rule* cannot be determined from a digest. That fact is only observable at login, in the
moment the plaintext exists.

### Re-validation at login

When `matches` succeeds, the runtime, **in this order**:

1. Evaluates the field's `where` predicates against the supplied plaintext.
2. Opens or closes an observational violation according to whether they hold
   ([integrity.md](integrity.md#two-classes-of-nonconformance)).
3. Re-hashes under the current policy if the stored policy differs — **regardless of the outcome
   of step 1**.

This is the only place a validation functor legitimately runs outside a commit, and it is
justified by the fact that this is the only moment its input exists. Everywhere else,
re-validation is a query.

### The failure mode that must not happen

The re-hash in step 3 is a write, and a write is normally subject to the field's enforcement mode.
Under `enforce always` it would be rejected by the very predicates the user has just failed — and
the login would fail for someone whose password worked yesterday and who has been given no way to
know anything changed. Tightening a password policy would lock out precisely the population it was
meant to reach.

> **A failed post-login re-validation must never fail the login, and must never prevent the
> re-hash.**

The mandated behaviour: record the violation, re-hash under the current policy, complete the login,
and flag the account for a forced change at the next opportunity.

`enforce forward` is *not* what makes this the default, and the earlier text was wrong to credit
it. `forward` grandfathers rows left alone; it rejects new and changed values exactly as `always`
does, and a re-hash writes new bytes. What makes the re-hash admissible is narrower and has to be
stated as its own rule:

> **The post-login re-hash is exempt from the field's enforcement mode, because it re-encodes a
> value the row already holds rather than supplying a new one.**

The exemption is scoped to this one site and cannot be generalized. It is safe here only because
`matches` has just succeeded against the *old* digest, which is a proof that the pre-image is
unchanged — and that proof is available nowhere else. A general "the pre-image is unchanged"
reading would let any `forward` field be rewritten with a failing value on an unverifiable claim.
The exemption is recorded with the modes it excepts, in
[integrity.md](integrity.md#enforcement-modes).

## Envelope encryption and key custody

A key management service is three operations — `wrap`, `unwrap`, `rotate` — plus an audit trail and
an access policy, over key material that never crosses the boundary. HSMs, Vault, and cloud KMS
products are that interface with different trust anchors.

One consequence decides the design before any algorithm question does: **`unwrap` is an external
call, so it cannot happen inside a commit.** The effect ladder has no lift from `Effect` to `Tx`
([events.md](events.md#design-principle)), and a commit that waits on a network round trip to a key
service is exactly what that missing lift forbids.

Envelope encryption is the arrangement that satisfies it:

```
table system.crypto.WrappingAuthority : Reference {
  name : Text unique                      -- key file, PKCS#11, cloud KMS
}

table system.crypto.AuthorityConfig : Configuration {
  target   :> WrappingAuthority unique,
  endpoint : Text,
  timeout  : Duration
}

table system.crypto.CipherPolicy : Reference {
  name      : Text unique,
  algorithm : Aes256Gcm | ChaCha20Poly1305 | XChaCha20Poly1305,
  key_name  : Text
}

table system.crypto.DigestPolicy : Reference {
  name      : Text unique,
  algorithm : HmacSha256 | Blake2sKeyed | Kmac128,
  key_name  : Text
}

table system.crypto.DataKey : Configuration {
  name       : Text,
  generation : Int,
  authority  :> WrappingAuthority,
  wrapped    : Bytes,
  status     : Live | Retired Timestamp = Live,
  unique keyGeneration { name, generation }
}

table system.crypto.Recipient : Configuration {
  node       :> system.shards.Node,
  public_key : Bytes,
  unique recipientOf { node }
}
```

The authority wraps a **data key**. Each server unwraps it once at startup or on rotation, in
`Effect`, in the generation pool ([dynamic-loading.md](dynamic-loading.md)), and holds the
plaintext data key in process memory. Commits encrypt with the cached key and make no external
call at all.

`WrappingAuthority` is `Reference` and carries a name only: the name selects the compiled-in
wrap/unwrap pair, exactly as `system.events.Handler.name` selects a handler, and the deployment
specifics — which key file, which PKCS#11 slot, which KMS endpoint — are a `Configuration` row
beside it. That pairing is the `Handler`/`HandlerConfig` shape reused
([events.md](events.md#registration-is-two-rows)), and it is what makes a key file, a PKCS#11
token, and a cloud KMS interchangeable without new mechanism. An earlier draft typed the selector
`effect_sig : TypeRef`; `TypeRef` was never the right shape for naming compiled-in code, and the
same correction was made to `Handler`.

**`CipherPolicy` names its key by name, not by `:>`.** The algorithm is schema and must be
identical everywhere; *which* key material stands behind that name is a deployment fact, and
staging must not share production's key. A `Reference` row holding a foreign key into a
`Configuration` table would make a schema object depend on a deployment row, which is the line
[traits.md](schema/traits.md#traits-are-not-configuration) draws. Resolution by name keeps each
side owning what it should. This is the same stratification that decides what any `:>` default may
name ([railroad.md](schema/railroad.md#fields)).

`DataKey` is keyed `{ name, generation }` rather than by name alone, because a rotation adds a
generation instead of replacing a row — which is what lets a check probe every live generation when
the plaintext behind an old digest is gone. Two rules make the set unambiguous:

- **The highest `Live` generation encrypts.** Every earlier live generation is read-only, kept only
  so existing ciphertext stays readable.
- **Retiring a generation is a status write, not a delete.** A `Retired` generation is no longer
  probed, which is what bounds the read cost of a long rotation history.

### Servers do not share a private key

The obvious first implementation — one key file copied to every server — is the wrong one, and the
reason is not the algorithm but the copying. A key that must be identical everywhere has to be
distributed, and every distribution channel is a place it can be captured.

**Wrap the data key to each server's public key instead.** An X25519 recipient construction —
`age` is the packaged form, and it accepts existing SSH keys as recipients — wraps one data key to
many recipients. Each server holds only its own private key, on disk, outside the transaction
graph. Adding a server re-wraps a small blob; no server ever learns another's private key.

That recipient construction is **one `WrappingAuthority` kind among several**, not a layer beneath
them: PKCS#11 and cloud KMS wrap the same data key through their own boundary, and a deployment
picks one per key.

`system.crypto.Recipient` is the registry, and it is what closes the re-wrap loop:

- **A `Recipient` insert triggers a re-wrap handler** on the existing generation pool. Re-wrapping
  needs the plaintext data key, which exists only in the memory of an already-running server, so
  the handler runs on a server that already holds it.
- **A cold cluster with a new server has no such server**, and the failure is explicit rather than
  silent: the new node cannot decrypt until an existing node runs the re-wrap, so bring the new
  node up alongside a running one. Where the authority is a KMS rather than a key file, the KMS
  unwraps for the new node directly and the problem does not arise.

Two specifics worth stating because they are easy to get wrong:

- **`ssh-ed25519` is a signing key and cannot encrypt.** Encryption to an Ed25519 identity goes
  through its X25519 birational map, which is what the `age` SSH recipient type does. Reaching for
  the key directly does not work.
- **The wrapping key never encrypts row data.** Asymmetric primitives wrap the data key and
  nothing else; the rows are encrypted symmetrically under the data key named by their
  `CipherPolicy`.

The ciphertext therefore travels in every backup and replication stream, as it must, and the key to
it does not.

### Keyed digests are a policy, not an improvisation

Three mechanisms need a **keyed deterministic digest** rather than an AEAD cipher: failed-attempt
comparison [below](#failed-attempt-digests), the table-wide `unique` index that stores a digest
instead of a value ([distribution.md](distribution.md#the-unique-index-holds-digests-not-values)),
and the scrub-then-digest path in [integrity.md](integrity.md#scrub-overwrites-payload-bytes). Each
must reproduce the same digest cluster-wide and across key generations, so each names a
`system.crypto.DigestPolicy` row for the same reason a `Hashed` type names a `HashPolicy` one.

**A digest key is an HKDF-derived subkey of the named data key, with a purpose label.** No key
material serves two primitives: using an AEAD data key directly as a MAC key is key reuse across
two constructions with no domain separation.

### Rotation has two tiers

| Rotate | Cost |
|---|---|
| Wrapping key | Re-wrap one blob per data key. No row is touched. |
| Data key | Re-encrypt affected rows, lazily on write under `enforce forward`. |

Data-key rotation is the same machinery as
[password policy rotation](#password-policy-rotation) — each stored value records its policy, so a
value under a superseded one is a reportable violation and nothing else has to track the migration.

### Crypto-shredding is a property with a two-step operation

Destroying a data key destroys every value encrypted under it, and here that costs nothing on the
read path, because decryption was never on it. It reaches only `Encrypted` fields; plaintext that
reached the log is [scrubbed](integrity.md#erasure-restricts-scrub-destroys) instead.

Stating the property is not enough, and an earlier draft stopped there. There is no
`destroy key` command, and deleting the `DataKey` row would not do it — a `Configuration` delete
appends a tombstone and leaves `wrapped` readable at every earlier sample moment. Destroying a data
key is two steps, and only the first is DataCode's:

1. **`scrub` every version of `wrapped` for that generation.** `scrub` is the one operation that
   overwrites a written extent, and it records what it destroyed
   ([integrity.md](integrity.md#scrub-overwrites-payload-bytes)). It is not a second exception to
   "nothing is destroyed" — it is the existing one.
2. **Destroy the wrapping key material at the authority.** That material lives outside the
   transaction graph by design, so the step is the authority's own — deleting a key file,
   destroying a PKCS#11 object, scheduling a KMS key deletion — and DataCode cannot perform it.

Both steps are required. Either alone leaves a path back to the plaintext.

## Failed-attempt digests

Distinguishing a brute-force attack from a user retyping the same wrong password requires knowing
that two attempts were *equal*, which a per-row salt is designed to prevent. So attempt comparison
uses a keyed deterministic digest under a named
[`DigestPolicy`](#keyed-digests-are-a-policy-not-an-improvisation), in its own table:

```
table system.auth.AttemptDigest : LogData, Personal {
  user    :> User | NotFound,
  method  :> CredentialMethod,
  digest  : Bytes,
  outcome : Failed | Succeeded
}

table system.auth.AttemptPolicy : Configuration {
  name      : Text unique,
  window    : Duration,
  threshold : Int,
  lockout   : Duration
}
```

```
retain system.auth.AttemptDigest
  for 90 day
  , drop
```

Three rules make the digest safe enough to be worth having:

- **The key is cluster-wide, one per generation.** Key scope must equal comparison scope: a
  per-server key makes an attack spread across points of presence invisible, which is the attack
  the table exists to catch. It is an ordinary data key under the envelope above.
- **The retention chain is short.** A deterministic digest is offline-dictionary-attackable if the
  key leaks, and the analysis window is days. `drop` is the terminal, deliberately.
- **It lives with the auth system, not in a request log.** Retention and access rules are then the
  auth system's, and the digest is never adjacent to the request body it came from.

**Something has to consume it, and `AttemptPolicy` is what does.** SP 800-63B requires rate
limiting of the verifier, and citing the standard for its composition-rule guidance while omitting
throttling would take the convenient half of the reference. The policy row holds the window, the
threshold, and the lockout duration; crossing the threshold within the window writes
`User.status = Locked`, and the release is a `Behavior` over the lockout duration rather than a
scheduled job, so nothing polls.

The table is `LogData`, so it is written by whichever server handled the attempt and rooted in that
server's own segment. The cluster-wide comparison is therefore a distributed read merged across
servers, which is the shape integrity reporting already uses — not a write to a shard the handling
server does not own.

## Access control functors

Access control is not a separate ACL system — it is not even a separate functor kind. It is one of
the two varieties of path-constraint functor, distinguished only by the fact that the requesting
token is one of its terms. See
[functors.md](schema/functors.md#path-constraints-and-their-two-varieties) and, for the syntax,
[constraints.md](schema/constraints.md).

- An access constraint is a path constraint evaluated against the active token.
- It restricts which morphisms — foreign key traversals, field reads — a token can perform.
- **Composition**: a request's access is the intersection of the client token's schema-level reach
  and the user token's row-level access, *except* that a grant carrying `bypass access` removes
  the second factor within the subtree it names. Neither factor removes data constraints.
- **Static analysis** enumerates which access rules apply to a request and exactly which a
  `bypass access` grant exempts, and reports coverage per table so gaps are visible.

The exception is stated in the rule rather than forty lines below it, because the plain
intersection would tell a reader that a grant cannot widen access. It can.

**Static analysis does not prove a rule set contradiction-free**, and an earlier claim that it did
was too strong. Assert bodies admit named `Bool` functions, `=~`, and arithmetic comparisons, so
deciding whether two asserts contradict is deciding satisfiability over that fragment; even for the
negation-free conjunctive core, containment is NP-complete, and "complete coverage" is a validity
question over an unbounded instance. What the structural walk buys is the *set* of asserts, the
fields they touch, and the exact exemption set of a bypass grant — which is what the rest of this
section relies on.

### `authed_user`

`authed_user` is the requesting user token's row, bound in every `assert` body. It is a full row,
not an id — the earlier open question about what `user` exposes is answered by making the binding a
`system.auth.User` row and letting ordinary path traversal do the rest. On a request carrying no
user token it is bound to `NotAuthenticated`, so every access assert fails closed with no rule
added: `==` against a variant mismatch is `False`, and a join against an absence variant yields no
rows.

**Mentioning `authed_user` is what makes an assert an access constraint.** There is no `access`
keyword and no reserved constraint name; the classification is read off the body. The name was
chosen over the shorter `user` because `user` reads like a table and would collide with the
likeliest field name in any permissions schema, including this one.

```
-- equality: the requester is the customer
assert app.commerce.Order.ownerAccess { authed_user == customer.user }

-- presence: the requester is a member of this document's project
assert app.pm.Document.memberAccess { self >< Project >< Member >< authed_user }
```

**There is no `authed_client` binding.** Which rows a request may reach is what an assert decides;
what a client may reach at all is what a `Client` row decides. Admitting the client into an assert
body would put one decision in two places, and every version that tried it opened a fail-open path.

The cost is the second half of the answer, and it is worth recording because the question returns.
Admitting the binding requires six additions:

1. Widening the access-variety rule to "mentions `authed_user` **or** `authed_client`", because
   an assert mentioning only the client is otherwise classified as a *data* constraint and runs on
   write only — where a row filter does nothing.
2. A rule that `bypass access` must not skip client asserts, or an administrator's browser inherits
   the schema.
3. A rule that one assert may never mention both bindings, because asserts are bypassed whole and
   the two halves differ in bypass semantics.
4. A rule that a client assert must also mention `self`, or it merely restates a `ClientReach` row.
5. A second read-failure semantics: filtering for a client, `Redacted` for a user.
6. The reclassification diagnostic rewritten for the wider rule.

Against zero additions for scope-by-binding, which additionally does write filtering, projection,
default supply, and materialization that an assert cannot do at all. See
[Clients](#clients).

### Schema-level access and bypass

Client tokens restrict which tables and fields are reachable at all. That is `ClientReach` data,
not `assert` rules: a client scoped to `app.commerce` cannot reach `app.hr.*` regardless of what
row-level rules exist there, and a name outside the reach closure does not resolve — the diagnostic
is the one for a name that does not exist.

Administrators need the opposite of a restriction, and it does not belong in the tables either. A
grant may declare that it is not narrowed by row-level access:

```
grant system.auth.Role.Admin on app.pm bypass access
```

The grant is a row, and the command writes it:

```
table system.auth.Grant : Configuration {
  role    :> Role,
  target  : SchemaPath,
  access  : Narrowed | Bypassed = Narrowed,
  erasure : Restricted | Bypassed = Restricted,
  unique grantOf { role, target }
}
```

Both bypass kinds default to the narrow value, which is the default-deny polarity the whole access
model uses. What each one skips, why the two are independent, and why bypass belongs in the grant
rather than in the tables are [namespaces.md](namespaces.md#bypass)'s, and are not repeated here.
One consequence is this section's, because it is what forced the classification to be structural:
**an administrator is exempt from access control, never from data integrity**, and under a naming
convention an access rule someone named `ownerCheck` would not have been bypassed while nothing in
the syntax said so.

`Grant.target` is a `SchemaPath` for the same reason `ClientReach.target` is: a grant names a
subtree, and a subtree is not a row.

Two alternatives were rejected. Writing `|| authed_user.role is Admin` into every rule spreads one
decision across every table and cannot be audited. Rebinding `authed_user` to the set of all users
for administrators silently changes a term's arity — `self >< … >< authed_user` would degrade from
"I am a member" to "any member exists" — and means nothing at all for an assert that compares
rather than joins.

## Self-management and extensibility

DataCode's own user table is an ordinary table, and applications extend it with **derived tables**
rather than by modifying it. There is no schema object called a view: a table declaration, a query,
and a derived table are one kind of thing ([queries.md](schema/queries.md)). The word `view`
survives only in `materialized view`.

A derived table here is a filter, not a subtype: it narrows `User` to the rows reachable through
some linking table, and may project that table's columns or not.

```
table system.auth.AccountKind : UserData {
  user    :> User,
  kind    : Human | Service | Federated,
  purpose : Text,
  unique kindOf { user }
}

system.auth.ServiceAccount = User >< AccountKind as ak
  where ak.kind is Service
  { User.*, ak.purpose }
```

`AccountKind` references `User`, so the join runs against the reference direction and `as ak` is
**mandatory** — the result column has no `:>` field to name it, and the bare table name would read
as though the table were the value. The filter precedes the projection because `ak.kind` does not
survive it.

Because the join is along a `:>` edge and the derived key is meaningful, the derived table is
**writable**, and this is the point of the pattern rather than a bonus: inserting a service account
through it creates the `User` row and the `AccountKind` row, with `kind = Service` supplied by the
filter. `is` against a nullary variant pins a value the same way `==` against a literal does; a
payload-carrying `is` would not. The call site never names the linking table. See
[queries.md](schema/queries.md#writing-through-a-derived-table).

A trait was rejected for this. A trait is a declaration on a table, so `User : ServiceAccount`
would make every user a service account; the thing being described is a set of rows, which is what
a query names.

**Write access to `system.*` is grant-based, not assert-based.** The base system tables are
protected the same way every other namespace is: a `system.auth.Grant` row restricting the subtree
to a named role, plus the `ClientReach` requirement that the requesting client reach `system` at
all. Both must hold. Because the protection is a grant rather than an assert mentioning
`authed_user`, a `bypass access` grant does not defeat it — bypass removes row-level asserts and
confers no reach. See [namespaces.md](namespaces.md#namespace-access-control).

## Service accounts

Machine-to-machine callers hold ordinary `User` rows. Every request still carries a user token, so
no second identity model is introduced; what distinguishes a service account is a linking row and
the derived table over it, exactly as above. Third-party ingestion is the case this was designed
for: the connector authenticates as a service account whose credentials are `ApiKey`-method rows,
and every row it writes is attributable to an identity that appears in the same tables and obeys
the same asserts as a human's.

Answers [OQ-015](open-questions.md#oq-015-service-accounts--answered).

## Token expiry and revocation

> **A session token is a self-describing bearer value, not a row.**

Its validity is a [behavior](schema/types.md#behaviors) of the issue moment embedded in it,
evaluated at each request's sample moment. Nothing polls and nothing is scheduled: the token is
valid at the moment being asked about, or it is not. This is the cheap case of behavior evaluation,
not the crossing-solver case, so it does not touch
[OQ-034](open-questions.md#oq-034-behavior-triggered-event-scheduling).

Two things follow, and the second is why the rule is stated as a rule rather than as an
optimization:

- **Validation touches no shard.** A request presenting a session token is not a read of the user's
  shard, so distributing auth by user costs nothing per request.
- **Any role holder can issue one.** Login is a credential read plus a signature, so a secondary or
  a point-of-presence tertiary completes it locally. Were a session a stored row, login would be a
  write and only the shard primary could serve it — which would undo the whole reason auth is
  `UserData` ([distribution.md](distribution.md#tertiary-servers-any-number)).

Revocation of a long-lived credential — a `Registration`, a `ClientToken` generation, a
`Credential` — is a write to the user's shard, so its latency is that shard's replication latency
to the server handling the next request. That is the same latency budget the whole design is built
around and the reason for sharding in the first place; it is not given a separate mechanism.

Where a shorter bound is needed than replication provides, shorten the session behavior. An
expiring token bounds exposure without requiring the revocation to have arrived, which is the only
bound available to a validation path that deliberately reads nothing.
