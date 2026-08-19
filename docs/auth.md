# Authentication and Authorization

## Identity Provider

DataCode is its own identity provider. There is no dependency on an external IdP (OAuth, LDAP, etc.) for the core system, though the user table can be federated via extension (see Self-Management below).

User and client credentials are stored in the `system` shard using the same table/functor machinery as application data. This means:
- Auth rules are defined as access control functors over the same schema graph as application data
- The auth system is inspectable, auditable, and extensible through normal DataCode schema operations
- DataCode's own auth schema can be queried and modified through the same query interface as application data

## Token Types

Every request requires **two tokens**: one from the first group and one user token.

### Server Token
- Held by DataCode server processes
- Grants full schema-level access — can read and write any data the server is responsible for
- On localhost, the server token is implicit (the locally running daemon authenticates at startup and caches its credentials)
- Never issued to human users

### Client Token
- Held by thick client applications
- Grants restricted schema-level access — can see and operate on the subset of the schema that the application is authorized to access
- Schema-level restrictions are defined as access control functors
- A thick client running as a user's desktop app holds a client token plus the user's token

### User Token
- Held per authenticated human user
- Grants row-level access restrictions on top of whatever schema-level access the client token allows
- Row-level restrictions are also defined as access control functors (path constraints in the schema graph)
- Required on every request — no anonymous access, and machine callers are no exception (see Service Accounts below)

### Token Lifecycle
```
Initial login:
  User presents a credential for one method (see Credential Storage)
  DataCode server verifies against system shard
  Any method named by that method's `requires` chain is presented in the same exchange
  Server issues per-device session token (shorter-lived)
  Session token is used for all subsequent requests

Token refresh:
  Session tokens expire; client re-authenticates with a long-lived credential
  Long-lived credentials can be revoked by operator or user

Server tokens:
  Generated at server provisioning time
  Stored in system shard; rotated on a schedule
  Localhost daemon caches its token after startup auth handshake
```

The credential presented at login is method-agnostic: password, API key, and — once
[OQ-011](open-questions.md#oq-011-fido2webauthn-for-long-lived-credentials) is taken up —
hardware key. The identity model does not change to accommodate a new one, which is the point
of the `User`/`Credential` split below.

## Credential Storage

**The user table is authentication-method agnostic.** A `User` row is an identity; how that
identity is proved is a row in a separate table, keyed by user and method. That split is what
lets one user hold several credentials at once — a password, an API key, and later a hardware
key — and it is what lets a new method be added without touching `User` or the rows already in
it.

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2
  where
    minLen 12
    \p -> not $ isBreached p

table system.auth.User : Configuration {
  username : Username unique,
  role     :> Role,
  status   : Active | Locked | Suspended = Active
}

table system.auth.Credential : Configuration {
  user   :> User,
  method :> CredentialMethod,
  secret : Password | WebAuthnKey | ApiKey,
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

`CredentialMethod` and `Role` are `Reference` tables, so adding a method or a role is a schema
commit and `method is Password` is checked at schema-commit time
([traits.md](schema/traits.md#reference-tables-are-code)).

The two fields on a method answer different questions and neither is derivable from the other.
`requires` is a **prerequisite edge**: presenting this method also demands that one was
satisfied in the same exchange, which is what login walks. `standing` is a **classification**:
a `SecondFactor` never authenticates alone regardless of what it requires. Multi-factor is
therefore a property of the method rather than a branch in the login code, and demanding it of
particular users is an ordinary presence assert:

```
assert User.secondFactorForAdmins {
  role is not Admin
  || self >< Credential >< (CredentialMethod where standing is SecondFactor)
}
```

The rule reads as what it is — an administrator must hold a credential under some method that
does not authenticate on its own. See
[schema/constraints.md](schema/constraints.md#presence).

**Not every method fits `Hashed`.** A password, an API key, and a WebAuthn public key are all
verified by re-deriving or re-checking against what is stored, so a one-way digest is the right
shape. A shared secret that the server must *reproduce from* is not. `Secret` is a type
*property* and `Hashed` is one constructor carrying it; a reversible constructor does not exist
yet, and inventing one alongside a key-management policy is more than this change should carry.
See [open-questions.md](open-questions.md#oq-037-reversible-secret-storage) — until it is
answered, methods needing a recoverable secret cannot be declared.

That restriction is narrower than it first looks, because the most-wanted second factor does
not need a recoverable secret at all.

## Challenge Methods

A `Credential` row is an **enduring capability**: something the user holds, keyed
`{ user, method }`, durable and replicated. A one-time code sent to the user is not that. It is
an **occurrence** — issued, delivered, used once, and gone — and separating the two is what the
`User`/`Credential` split makes possible. It gets its own table:

```
table system.auth.Contact : Configuration {
  user     :> User,
  channel  : Email | Sms | Push,
  address  : Text,
  status   : Verified Timestamp | Unverified = Unverified,
  unique contactOf { user, channel, address }
}

table system.auth.Challenge : LogData {
  user        :> User,
  method      :> CredentialMethod,
  destination :> Contact,
  code        : ChallengeCode,
  expires_at  : Timestamp,
  state       : Issued | Consumed = Issued,

  is_live : Behavior Bool = \m -> m < expires_at,

  on state is Issued emit system.events.NotifyQueue {
    contact  = destination,
    template = method.name
  }
}

retain system.auth.Challenge for 30 days, drop
```

Five things fall out, and none of them is new machinery:

**The send is an event on insert.** Issuing a challenge *is* inserting the row, and delivery is
the scheduler's problem — retried under `system.events.Queue`'s policy, rate-limited, and never
holding the commit open. This is exactly what "no external calls inside a commit"
([events.md](events.md)) was written for. Insert is the degenerate case of the false-to-true
rule: before the write the row did not exist, so the condition was not true.

**Expiry is a [behavior](schema/types.md#behaviors).** Nothing marks a challenge expired and
nothing polls it; `is_live` is a function of `Moment`, sampled at whatever moment the request
carries. There is no `Expired` state because no write would ever produce one — the same
treatment session token expiry gets, and the same reason.

**Retention is a `retain` chain.** The table is `LogData`, so it declares no candidate key —
occurrences have no identity beyond their occurrence — and spent challenges are pruned as a
consequence of the chain rather than by anything manual.

**The destination is pinned at issue.** `destination :> Contact` is recorded on the challenge
rather than resolved from the user when the queue item runs, so editing a contact address
cannot redirect a code already in flight.

**It needs no reversible secret.** The code is generated, hashed, and verified with `matches`
exactly as a password is. Short-livedness is not a reason to store it in the clear: a bearer
credential valid for ten minutes grants login for ten minutes to anyone who can read it, and
the log it would be read from is append-only.

### What This Does and Does Not Cover

Two mechanisms get called "TOTP" and only one of them fits above.

| | Delivered code | Authenticator app (RFC 6238) |
|---|---|---|
| Secret | generated per attempt | provisioned once, never re-transmitted |
| Stored as | `Hashed` — verified by re-hashing | must be recovered to recompute the code |
| Expressible today | **yes** | no — needs OQ-037 |

So a second factor is available in the first pass, and it is the one most deployments reach for
first. What stays blocked is any method whose secret the server must read back: authenticator
apps, and a connector's outbound credential to a third party.

A `Challenge` is not a `Credential` and does not appear in `Credential`'s key, but it satisfies
a `CredentialMethod` the same way one does — so a method whose `standing` is `SecondFactor` may
be satisfied by a consumed challenge, and the `requires` chain walks the two uniformly.

The `where` predicates run on the plaintext, which is the only stage that sees it; the
digest is produced afterwards and is all that reaches the transaction log. That ordering is
fixed by the type, not by convention — see
[schema/functors.md](schema/functors.md#order-of-operations-for-a-field-write).

Because `Password` is `Hashed`, it is `Secret`, and four things follow automatically
([schema/types.md](schema/types.md#secret-types)):

- `Credential.secret` reads as `Sealed`, never as bytes, for every token.
- `==` against it is a compile-time error. Verification goes through `matches`.
- Its validation predicates may only be `a -> Bool`, so no error payload can carry the
  plaintext into the append-only log, where nothing could subsequently remove it.
- `unique` on it is a compile-time error — per-row salts mean it would never fire.

**Note on policy content.** The mechanism supports composition rules ("must contain a
symbol") because some environments are required to have them. The recommended default policy
does not include them: NIST SP 800-63B moved to length plus breach-list checking, which is
what the example above uses.

## Login

```
authenticate name method attempt =
  let u = system.auth.User where username == name
      c = system.auth.Credential where user == u && method == method
  in if attempt `matches` c.secret && u.status is Active
       then issueSession u method
       else Left AuthFailed
```

Both lookups resolve a single row — `User.username` is `unique` and `Credential` is keyed
`{ user, method }` — which is what `matches` requires. `matches` hashes its right-hand
argument under the policy recorded on the stored value and compares in constant time;
``Credential where attempt `matches` secret`` is a scan of every row against a per-row salt
and is rejected at compile time.

Login is per method, and a method whose `requires` names another is not sufficient on its own:
the session is issued only once every prerequisite in that chain has been satisfied in the
same exchange. Which methods a deployment demands of which users is the assert above, not a
branch here.

## Password Policy Rotation

Rotating the hash algorithm or tightening the password rules is repointing `Password` at a
new row in `system.crypto.HashPolicy` — a schema commit against a populated field, which
by the rule in [integrity.md](integrity.md#mode-is-mandatory-on-a-populated-field) must state
an enforcement mode. It is `enforce forward`: existing credentials keep working, and every row
under the superseded policy becomes a reportable violation.

Two of the three checks are **derivable** — the stored value records which policy produced it,
so "hashed under a superseded policy" is a query. The third is not. Whether a stored password
satisfies a *new length or content rule* cannot be determined from a digest. That fact is
only observable at login, in the moment the plaintext exists.

### Re-Validation at Login

When `matches` succeeds, the runtime re-evaluates the field's `where` predicates against the
supplied plaintext and:

1. **Re-hashes** under the current policy if the stored policy id differs, and
2. **Opens or closes an observational violation** according to whether the predicates now
   hold ([integrity.md](integrity.md#two-classes-of-nonconformance)).

This is the only place a validation functor legitimately runs outside a commit, and it is
justified by the fact that this is the only moment its input exists. Everywhere else,
re-validation is a query.

### The Failure Mode That Must Not Happen

The re-hash in step 1 is a write, and a write is subject to the field's enforcement mode. If
that mode were `enforce always`, the write would be rejected by the very predicates the user
has just failed — and the login would fail for someone whose password worked yesterday and
who has been given no way to know anything changed. Tightening a password policy would lock
out precisely the population it was meant to reach.

> **A failed post-login re-validation must never fail the login.**

The mandated behaviour: keep the existing digest, record the violation, complete the login,
and flag the account for a forced change at the next opportunity. `enforce forward` is what
makes this the default rather than a special case — the old value is grandfathered, so
nothing about the existing row is rejected.

## Access Control Functors

Access control is not a separate ACL system — it is not even a separate functor kind. It is
one of the two varieties of path-constraint functor, distinguished only by the fact that the
requesting token is one of its terms. See
[schema/functors.md](schema/functors.md#path-constraints-and-their-two-varieties) and, for the
syntax, [schema/constraints.md](schema/constraints.md).

- An access constraint is a path constraint evaluated against the active token
- It restricts which morphisms (foreign key traversals, field reads) a token can perform
- Composition: a request's access is the intersection of the client token's schema-level
  access and the user token's row-level access
- Access rules can be analyzed statically for consistency (no contradictions, complete
  coverage) before deployment

### `authed_user`

`authed_user` is the requesting user token's row, bound in every `assert` body. It is a full
row, not an id — the earlier open question about what `user` exposes is answered by making the
binding a `system.auth.User` row and letting ordinary path traversal do the rest.

**Mentioning `authed_user` is what makes an assert an access constraint.** There is no
`access` keyword and no reserved constraint name; the classification is read off the body. The
name was chosen over the shorter `user` because `user` reads like a table and would collide
with the likeliest field name in any permissions schema, including this one.

```
-- equality: the requester is the customer
assert Order.ownerAccess { authed_user == customer.user }

-- presence: the requester is a member of this document's project
assert Document.memberAccess { self >< Project >< Member >< authed_user }
```

**There is no `authed_client` binding.** Client scope is schema level and lives in
`system.auth.*` configuration; admitting the client into an `assert` would put one decision in
two places.

### Schema-Level Access and Bypass

Client tokens restrict which tables and fields are reachable at all. That is configuration in
`system.auth.*`, not `assert` rules: a client token scoped to `app.commerce` cannot reach
`app.hr.*` regardless of what row-level rules exist there.

Administrators need the opposite of a restriction, and it does not belong in the tables
either. A grant may declare that it is not narrowed by row-level access:

```
grant system.auth.Role.Admin on app.pm bypass access
```

Every assert mentioning `authed_user` is skipped for a token holding that grant; every other
assert still runs. **An administrator is exempt from access control, never from data
integrity.** This is the requirement that forced the classification to be structural — under a
naming convention, an access rule someone named `ownerCheck` would not have been bypassed and
nothing in the syntax would have said so.

Two alternatives were rejected. Writing `|| authed_user.role is Admin` into every rule spreads
one decision across every table and cannot be audited. Rebinding `authed_user` to the set of
all users for administrators silently changes a term's arity — `self >< … >< authed_user` would
degrade from "I am a member" to "any member exists" — and means nothing at all for an assert
that compares rather than joins. See
[namespaces.md](namespaces.md#namespace-access-control).

## Self-Management and Extensibility

DataCode's own user table is a normal table in the `system` shard, and applications extend it
with views rather than by modifying it.

A view here is a filter, not a subtype: it narrows `User` to the rows reachable through some
linking table, and may project that table's columns or not.

```
table system.auth.AccountKind : Configuration {
  user    :> User,
  kind    : Human | Service | Federated,
  purpose : Text,
  unique kindOf { user }
}

view system.auth.ServiceAccount = User >< AccountKind { User.*, AccountKind.purpose }
  where kind is Service
```

Because the join is along a `:>` edge and the derived key is meaningful, the view is
**writable**, and this is the point of the pattern rather than a bonus: inserting a service
account through it creates the `User` row and the `AccountKind` row, with `kind = Service`
supplied by the view's own filter. The call site never names the linking table. See
[schema/queries.md](schema/queries.md#writing-through-a-view).

A trait was rejected for this. A trait is a declaration on a table, so `User : ServiceAccount`
would make every user a service account; the thing being described is a set of rows, which is
a view's job.

The base system tables stay protected by system-level access constraints that prevent
destructive modification by non-system tokens.

## Service Accounts

Machine-to-machine callers hold ordinary `User` rows. Every request still carries a user
token, so no second identity model is introduced; what distinguishes a service account is a
linking row and the view over it, exactly as above. Third-party ingestion is the case this was
designed for: the connector authenticates as a service account whose credentials are
`ApiKey`-method rows, and every row it writes is attributable to an identity that appears in
the same tables and obeys the same asserts as a human's.

Answers [OQ-015](open-questions.md#oq-015-service-accounts).

## Device Registration

Client tokens are issued to a **device**, and registration is what binds one:

- The identifiers a platform can supply differ — a desktop install, a mobile app, and a
  headless service agree on nothing — so the required set is per-platform configuration in
  `system.auth.*`, not a fixed schema.
- Registration produces a client token scoped to a namespace subtree
  (`issue client token for "MyApplication" scoped to app.commerce`), rotatable without
  disturbing the user tokens presented alongside it.

Which identifiers each platform must supply is [OQ-008](open-questions.md#oq-008-client-token-provisioning);
that the set is tunable rather than fixed is settled.

## Token Expiry and Revocation

Session tokens expire, and expiry is a [behavior](schema/types.md#behaviors) — a function of
`Moment`, evaluated at each request's sample moment. Nothing polls and nothing is scheduled:
the token is valid at the moment being asked about, or it is not. This is the cheap case of
behavior evaluation, not the crossing-solver case, so it does not touch
[OQ-034](open-questions.md#oq-034-behavior-triggered-event-scheduling).

Revocation of a long-lived credential is a write to the `system` shard, so its latency is the
system shard's replication latency to the server handling the next request. That is the same
latency budget the whole design is built around and the reason for sharding in the first
place; it is not given a separate mechanism. Where a shorter bound is needed than replication
provides, shorten the session behavior — an expiring token bounds exposure without requiring
the revocation to have arrived.
