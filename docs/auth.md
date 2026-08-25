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
[OQ-011](open-questions.md#oq-011-fido2webauthn-for-long-lived-credentials--answered) is taken up —
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
shape. A shared secret the server must *reproduce from* is not, and it takes the second `Secret`
constructor, [`Encrypted`](schema/types.md#encrypted-types). Key custody is
[below](#envelope-encryption-and-key-custody).

Most deployments need neither, because the most-wanted second factor needs no recoverable secret
at all.

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

retain system.auth.Challenge for 30 day, drop
```

Five things fall out, and none of them is new machinery:

**The send is an event on insert.** Issuing a challenge *is* inserting the row, and delivery is
the scheduler's problem — retried under `system.events.QueuePolicy`, rate-limited, and never
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
| Stored as | `Hashed` — verified by re-hashing | `Encrypted` — recovered to recompute the code |
| Costs | nothing beyond what exists | a data key and its custody |

Reach for the delivered code first. It is the one most deployments want, it needs no key
management, and a code that lives ten minutes cannot be stolen from a backup taken a year later.
The authenticator app and a connector's outbound credential are the two cases that justify the
key custody below.

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

## Envelope Encryption and Key Custody

A key management service is three operations — `wrap`, `unwrap`, `rotate` — plus an audit trail
and an access policy, over key material that never crosses the boundary. HSMs, Vault, and cloud
KMS products are that interface with different trust anchors.

One consequence decides the design before any algorithm question does: **`unwrap` is an external
call, so it cannot happen inside a commit.** The effect ladder has no lift from `Effect` to `Tx`
([events.md](events.md)), and a commit that waits on a network round trip to a key service is
exactly what that missing lift forbids.

Envelope encryption is the arrangement that satisfies it:

```
table system.crypto.WrappingAuthority : Reference {
  name       : Text unique,
  effect_sig : TypeRef                    -- compiled-in: key file, PKCS#11, cloud KMS
}

table system.crypto.CipherPolicy : Reference {
  name      : Text unique,
  algorithm : Aes256Gcm | ChaCha20Poly1305 | XChaCha20Poly1305,
  key_name  : Text
}

table system.crypto.DataKey : Configuration {
  name       : Text,
  generation : Int,
  authority :> WrappingAuthority,
  wrapped    : Bytes,
  unique keyGeneration { name, generation }
}
```

The authority wraps a **data key**. Each server unwraps it once at startup or on rotation, in
`Effect`, in the generation pool ([dynamic-loading.md](dynamic-loading.md)), and holds the
plaintext data key in process memory. Commits encrypt with the cached key and make no external
call at all. `WrappingAuthority` naming compiled-in Haskell is the `system.events.Handler`
pattern reused, which is what makes a key file, a PKCS#11 token, and a cloud KMS
interchangeable without new mechanism.

**`CipherPolicy` names its key by name, not by `:>`.** The algorithm is schema and must be
identical everywhere; *which* key material stands behind that name is a deployment fact, and
staging must not share production's key. A `Reference` row holding a foreign key into a
`Configuration` table would make a schema object depend on a deployment row, which is the line
[schema/traits.md](schema/traits.md#traits-are-not-configuration) draws. Resolution by name keeps
each side owning what it should.

`DataKey` is keyed `{ name, generation }` rather than by name alone, because a rotation adds a
generation instead of replacing a row — which is what lets a check probe every live generation
when the plaintext behind an old digest is gone.

### Servers Do Not Share a Private Key

The obvious first implementation — one key file copied to every server — is the wrong one, and
the reason is not the algorithm but the copying. A key that must be identical everywhere has to
be distributed, and every distribution channel is a place it can be captured.

**Wrap the data key to each server's public key instead.** An X25519 recipient construction —
`age` is the packaged form, and it accepts existing SSH keys as recipients — wraps one data key
to many recipients. Each server holds only its own private key, on disk, outside the transaction
graph. Adding a server re-wraps a small blob; no server ever learns another's private key.

Two specifics worth stating because they are easy to get wrong:

- **`ssh-ed25519` is a signing key and cannot encrypt.** Encryption to an Ed25519 identity goes
  through its X25519 birational map, which is what the `age` SSH recipient type does. Reaching
  for the key directly does not work.
- **The wrapping key never encrypts row data.** Asymmetric primitives wrap the data key and
  nothing else; the rows are encrypted symmetrically under the data key named by their
  `CipherPolicy`.

The ciphertext therefore travels in every backup and replication stream, as it must, and the
key to it does not.

### Rotation Has Two Tiers

| Rotate | Cost |
|---|---|
| Wrapping key | Re-wrap one blob per data key. No row is touched. |
| Data key | Re-encrypt affected rows, lazily on write under `enforce forward`. |

Data-key rotation is the same machinery as [password policy rotation](#password-policy-rotation)
— each stored value records its policy, so a value under a superseded one is a reportable
violation and nothing else has to track the migration.

Destroying a data key destroys every value encrypted under it. That is crypto-shredding, and
here it costs nothing, because decryption was never on the read path. It reaches only
`Encrypted` fields; plaintext that reached the log is
[scrubbed](integrity.md#erasure-restricts-scrub-destroys) instead.

## Failed-Attempt Digests

Distinguishing a brute-force attack from a user retyping the same wrong password requires
knowing that two attempts were *equal*, which a per-row salt is designed to prevent. So attempt
comparison uses a **keyed deterministic digest**, in its own table:

```
table system.auth.AttemptDigest : LogData {
  user   :> User | NotFound,
  method :> CredentialMethod,
  digest : Bytes,
  outcome : Failed | Succeeded
}

retain system.auth.AttemptDigest for 90 day, drop
```

Three rules make this safe enough to be worth having:

- **The key is cluster-wide, one per generation.** Key scope must equal comparison scope: a
  per-server key makes an attack spread across points of presence invisible, which is the
  attack the table exists to catch. It is an ordinary data key under the envelope above.
- **The retention chain is short.** A deterministic digest is offline-dictionary-attackable if
  the key leaks, and the analysis window is days. `drop` is the terminal, deliberately.
- **It lives with the auth system, not in a request log.** Retention and access rules are then
  the auth system's, and the digest is never adjacent to the request body it came from.

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

`bypass erasure` is the second modifier and is separate from the first, because seeing the
history of an erased row is a narrower and rarer permission than administering a namespace. A
grant may carry either, both, or neither. See
[integrity.md](integrity.md#erasure-restricts-scrub-destroys).

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

system.auth.ServiceAccount = User >< AccountKind { User.*, AccountKind.purpose }
  where kind is Service
```

Because the join is along a `:>` edge and the derived key is meaningful, the derived table is
**writable**, and this is the point of the pattern rather than a bonus: inserting a service
account through it creates the `User` row and the `AccountKind` row, with `kind = Service`
supplied by the filter. The call site never names the linking table. See
[schema/queries.md](schema/queries.md#writing-through-a-derived-table).

A trait was rejected for this. A trait is a declaration on a table, so `User : ServiceAccount`
would make every user a service account; the thing being described is a set of rows, which is
what a query names.

The base system tables stay protected by system-level access constraints that prevent
destructive modification by non-system tokens.

## Service Accounts

Machine-to-machine callers hold ordinary `User` rows. Every request still carries a user
token, so no second identity model is introduced; what distinguishes a service account is a
linking row and the view over it, exactly as above. Third-party ingestion is the case this was
designed for: the connector authenticates as a service account whose credentials are
`ApiKey`-method rows, and every row it writes is attributable to an identity that appears in
the same tables and obeys the same asserts as a human's.

Answers [OQ-015](open-questions.md#oq-015-service-accounts--answered).

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
