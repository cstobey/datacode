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

## Access Control Functors

Access control is not a separate ACL system — it is a category of functors applied to the schema graph:

- An access control functor is a path equivalence constraint evaluated against the active token
- It restricts which morphisms (foreign key traversals, field reads) a token can perform
- Composition: token A's access is the intersection of the client token's schema-level access and the user token's row-level access
- Access rules can be analyzed statically for consistency (no contradictions, complete coverage) before deployment

### Example
```
-- Only a user can see their own orders
access_control OrderVisibility {
  path: User -> Order [via Order.user_id]
  allowed_tokens: [user_token where user_token.user_id = Order.user_id]
}

-- Client application can only access the Order schema, not User PII
access_control ClientSchema {
  restrict_schema: [Order, OrderLine, Product]
  token_type: client
}
```

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
