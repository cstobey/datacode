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
- Row-level restrictions are also defined as access control functors (path equivalences in the schema graph)
- Required on every request — no anonymous access

### Token Lifecycle
```
Initial login:
  User presents long-lived credential (username + password or key)
  DataCode server verifies against system shard
  Server issues per-device session token (shorter-lived)
  Session token is used for all subsequent requests

Token refresh:
  Session tokens expire; client re-authenticates with long-lived credential
  Long-lived credentials can be revoked by operator or user

Server tokens:
  Generated at server provisioning time
  Stored in system shard; rotated on a schedule
  Localhost daemon caches its token after startup auth handshake
```

## Credential Storage

Passwords are stored as a `Hashed` type. Hashing is not a validation predicate and is not
something the login code does — it is the field's type, which is what makes it impossible
to get wrong:

```
type Password : Hashed Text using system.crypto.password_v2
  where
    minLen 12
    \p -> not $ isBreached p

table system.auth.users : Configuration {
  username : Username unique,
  password : Password,
  status   : Active | Locked | Suspended = Active
}
```

The `where` predicates run on the plaintext, which is the only stage that sees it; the
digest is produced afterwards and is all that reaches the transaction log. That ordering is
fixed by the type, not by convention — see
[schema/functors.md](schema/functors.md#order-of-operations-for-a-field-write).

Because `Password` is `Hashed`, it is `Secret`, and four things follow automatically
([schema/types.md](schema/types.md#secret-types)):

- `users.password` reads as `Sealed`, never as bytes, for every token.
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
authenticate name attempt =
  let u = system.auth.users where username == name
  in if attempt `matches` u.password && u.status is Active
       then issueSession u
       else Left AuthFailed
```

`matches` hashes its right-hand argument under the policy recorded on the stored value and
compares in constant time. It applies to a single resolved row:
``users where attempt `matches` password`` is a scan of every row against a per-row salt, and
is rejected at compile time.

## Password Policy Rotation

Rotating the hash algorithm or tightening the password rules is repointing `Password` at a
new row in `system.crypto.hash_policies` — a schema commit against a populated field, which
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
one of the two varieties of path-equivalence functor, distinguished only by the fact that
one of its two path terms is the requesting token rather than a data path. See
[schema/functors.md](schema/functors.md#path-equivalence-and-its-two-varieties).

- An access control functor is a path equivalence constraint evaluated against the active token
- It restricts which morphisms (foreign key traversals, field reads) a token can perform
- Composition: token A's access is the intersection of the client token's schema-level access and the user token's row-level access
- Access rules can be analyzed statically for consistency (no contradictions, complete coverage) before deployment

ACL rules use the same `assert` keyword as path-equivalence constraints — both are path-equivalence assertions; ACL just has the requesting token as one term. Full syntax reference: [schema/constraints.md](schema/constraints.md).

### Syntax

```
-- Inline in table definition
table app.commerce.Order {
  customer :> Customer,

  -- Only a user can see/write their own orders
  assert access { user.id == customer.user_id }
}

-- Standalone (add or update after the table is defined)
assert Order.access { user.id == customer.user_id }
```

`user` refers to the requesting user token. The exact fields exposed on `user` (full user row vs. just `user.id`) are TBD — see open questions in the design plan.

### Schema-Level Access (Client Token Restrictions)

Client tokens restrict which tables and fields are accessible at the schema level. This is configured in `system.auth.*` tables — not expressed as `assert` rules in the table definition. A client token that is scoped to `app.commerce` cannot access `app.hr.*` regardless of what row-level `assert access` rules exist on those tables.

### Path Equivalence (Data Constraints)

Path equivalence constraints that are not about token access use the same `assert` syntax without the `access` name:

```
table Order {
  customer  :> Customer,
  bill_addr :> Address,

  -- Assert: two FK paths reach the same address
  assert billingMatch { customer.billing_address == bill_addr }
}

-- Standalone
assert Order.billingMatch { customer.billing_address == bill_addr }
```

Both ACL and path-equivalence constraints are first-class schema objects stored as `FunctorRef`s in the system schema.

## Self-Management and Extensibility

DataCode's own user table is a normal table in the `system` shard. Applications can extend it:
- Define an **additive view** that joins the DataCode user table with application-specific user data
- Add application-specific fields without modifying the system table directly
- Apply additional access control functors on top of the base auth rules

This means the auth schema is not locked — but the base system tables are protected by system-level access control functors that prevent destructive modification by non-system tokens.

## Open Questions

- Should long-lived credentials support hardware keys (FIDO2/WebAuthn)? This would strengthen the identity model considerably.
- How are client tokens provisioned and distributed to thick client deployments?
- What is the token revocation latency? (Depends on how quickly the system shard propagates to all servers)
- Should there be a concept of "service accounts" distinct from user accounts for machine-to-machine calls?
