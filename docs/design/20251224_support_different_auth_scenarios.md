# Supporting Different Authentication Scenarios

## Context

Flovyn Server has a flexible, pluggable authentication and authorization architecture:

| Component | Purpose |
|-----------|---------|
| `crates/core/auth` | Protocol-agnostic traits (`Authenticator`, `Authorizer`, `PrincipalAttributeResolver`) and types (`Principal`, `AuthRequest`, `Decision`) |
| `crates/auth-script` | JavaScript-based `ScriptAttributeResolver` for dynamic attribute extraction |
| `crates/auth-cedar` | Cedar policy-based `CedarAuthorizer` with RBAC/ABAC support |

The goal is to ensure common authentication scenarios are implementable and identify any missing building blocks.

---

## Current Capabilities

### What We Have

1. **Authenticators** (configured per endpoint)
   - `JwtAuthenticator` - Validates JWTs via JWKS
   - `WorkerTokenAuthenticator` - HMAC-based worker tokens
   - `SessionAuthenticator` - Cookie-based sessions

2. **Authorizers**
   - `CedarAuthorizer` - Fine-grained Cedar policies with built-in RBAC (OWNER/ADMIN/MEMBER roles)
   - `NoopAuthorizer` - Always allow (for disabled auth)

3. **Attribute Resolvers**
   - `ScriptAttributeResolver` - Execute JavaScript to extract attributes from principals
   - `NoopAttributeResolver` - No additional attributes

4. **Configuration Structure**
   ```yaml
   security:
     enabled: true
     endpoints:
       http:
         authenticators: ["jwt", "session"]
         authorizer: "cedar"
       grpc:
         authenticators: ["worker_token"]
         authorizer: "cedar"
     jwt:
       jwks_uri: "https://..."
       issuer: "..."
     worker_token:
       secret: "..."
   ```

### What's Missing

| Gap | Description |
|-----|-------------|
| **Static API Key Authenticator** | No built-in support for config-based API keys (different from worker tokens) |
| **Claims-based Attribute Resolver** | While configured, not fully implemented for extracting roles from JWT claims |

---

## Scenarios

### Scenario 1: Static API Keys

**Use Case**: Simple deployments where operators configure static API keys in the config file for both REST API and workers (gRPC).

**Requirements**:
- Keys defined in configuration file
- Single authenticator for both HTTP and gRPC endpoints
- Keys scoped to specific tenants
- Per-key principal type (User vs Worker) and role assignment

**Current Support**: ❌ Not supported
- Current `WorkerTokenAuthenticator` uses HMAC-signed tokens, not static keys

**Solution**:

Add `StaticApiKeyAuthenticator` (new implementation of `Authenticator` trait):

```rust
pub struct StaticApiKeyAuthenticator {
    keys: HashMap<String, ApiKeyConfig>,  // key -> config lookup
}

struct ApiKeyConfig {
    tenant_id: Uuid,
    principal_type: String,  // "User", "Worker", or "Service"
    principal_id: String,
    role: Option<String>,    // "OWNER", "ADMIN", "MEMBER" (for Users)
}
```

**Configuration**:
```yaml
security:
  endpoints:
    http:
      authenticators: ["static_api_key"]
    grpc:
      authenticators: ["static_api_key"]  # Same authenticator for workers
  static_api_key:
    keys:
      # REST API key for admin access
      - key: "flovyn_sk_live_abc123..."
        tenant_id: "550e8400-e29b-41d4-a716-446655440000"
        principal_type: "User"
        principal_id: "api:production"
        role: "ADMIN"
      # REST API key for read-only access
      - key: "flovyn_sk_live_xyz789..."
        tenant_id: "550e8400-e29b-41d4-a716-446655440000"
        principal_type: "User"
        principal_id: "api:readonly"
        role: "MEMBER"
      # Worker key
      - key: "flovyn_wk_live_worker1..."
        tenant_id: "550e8400-e29b-41d4-a716-446655440000"
        principal_type: "Worker"
        principal_id: "worker:default"
```

**Authentication Flow**:
1. Extract key from `Authorization: Bearer <key>` header (works for both HTTP and gRPC)
2. Look up key in configured keys map
3. Return `Principal` with tenant_id, principal_type, principal_id, and role from config
4. Cedar policies handle authorization based on principal type and role

---

### Pre-configured Tenants (Simple Deployments)

For small deployments with a fixed number of tenants, configure tenants directly in the config file. They are synced to the database on server startup, eliminating any bootstrapping complexity.

```yaml
tenants:
  - id: "550e8400-e29b-41d4-a716-446655440000"
    name: "Acme Corp"
    slug: "acme"
    tier: "FREE"
    region: "us-west-2"
  - id: "660e8400-e29b-41d4-a716-446655440001"
    name: "Beta Inc"
    slug: "beta"

security:
  static_api_key:
    keys:
      # Keys reference pre-configured tenant IDs
      - key: "flovyn_sk_acme_admin..."
        tenant_id: "550e8400-e29b-41d4-a716-446655440000"
        principal_type: "User"
        principal_id: "admin"
        role: "OWNER"
      - key: "flovyn_wk_acme_worker..."
        tenant_id: "550e8400-e29b-41d4-a716-446655440000"
        principal_type: "Worker"
        principal_id: "worker:default"
```

**Sync Behavior**:
- On startup, upsert configured tenants to database (insert if missing, update if changed)
- Tenants not in config are left untouched (allows mixing config + API-created tenants)
- Validation: fail startup if tenant IDs in `static_api_key` don't exist in `tenants` config

This approach:
- Single config file defines everything
- No chicken-and-egg problem
- Operator has full control
- Works well for single-tenant or small multi-tenant deployments

---

### Scenario 2: Google OAuth / Service Accounts

**Use Case**: Application uses Google Identity for user authentication, and Google Service Accounts for workers.

**Requirements**:
- REST API: Accept Google-issued JWTs from user sign-in
- gRPC (Workers): Accept Google Service Account JWTs

**Current Support**: ✅ Mostly supported

The existing `JwtAuthenticator` can validate Google JWTs if configured correctly:

```yaml
security:
  jwt:
    jwks_uri: "https://www.googleapis.com/oauth2/v3/certs"
    issuer: "https://accounts.google.com"
    audience: "your-client-id.apps.googleusercontent.com"
```

**Gap**: Extracting tenant_id and role from Google JWT claims.

**Solution**: Implement `ClaimsAttributeResolver`

```rust
// Extract attributes from JWT claims during authentication
pub struct ClaimsAttributeResolver {
    mappings: Vec<ClaimMapping>,
}

struct ClaimMapping {
    claim: String,           // e.g., "https://flovyn.io/tenant_id"
    attribute: String,       // e.g., "tenantId"
    transform: Option<...>,  // optional transformation
}
```

**Configuration**:
```yaml
security:
  attr_resolver:
    resolver_type: "claims"
    mappings:
      - claim: "https://flovyn.io/tenant_id"
        attribute: "tenantId"
      - claim: "https://flovyn.io/role"
        attribute: "role"
      # Or use Google groups for role mapping
      - claim: "groups"
        attribute: "groups"
```

For Google-specific role derivation, use `ScriptAttributeResolver`:
```javascript
function resolve(principal, tenantId) {
  const email = principal.attributes.email;
  // Map email domain or specific users to roles
  if (email.endsWith('@yourcompany.com')) {
    return { role: 'ADMIN' };
  }
  return { role: 'MEMBER' };
}
```

---

### Scenario 3: Better Auth Integration

**Use Case**: Application uses [Better Auth](https://www.better-auth.com) for authentication, with:
- OIDC Provider plugin for user JWT tokens
- API Key plugin for worker authentication

**Requirements**:
- REST API: Accept Better Auth OIDC-issued JWTs
- Workers: Accept Better Auth API keys

**Current Support**: ✅ Mostly supported

**For OIDC tokens** (REST API):
```yaml
security:
  jwt:
    jwks_uri: "https://your-app.com/.well-known/jwks.json"  # Better Auth JWKS endpoint
    issuer: "https://your-app.com"
    audience: "flovyn"
```

**For API Keys** (Workers): Two options:

**Option A**: Use existing `WorkerTokenAuthenticator` (Recommended)
- Generate worker tokens from Flovyn and configure them in Better Auth
- Keeps worker auth independent of Better Auth

**Option B**: Add Better Auth API key validation (if keys must be managed in Better Auth)
- Better Auth API keys are opaque tokens validated via HTTP call to Better Auth
- Requires new `ExternalApiKeyAuthenticator`:
  ```rust
  pub struct ExternalApiKeyAuthenticator {
      validation_url: String,  // POST key to this URL for validation
      // Response includes user/service info
  }
  ```

**Configuration for Option B**:
```yaml
security:
  endpoints:
    grpc:
      authenticators: ["external_api_key"]
  external_api_key:
    validation_url: "https://your-app.com/api/auth/validate-key"
    # Headers to forward, timeout, etc.
```

---

### Scenario 4: Keycloak / Generic OIDC

**Use Case**: Enterprise deployment using Keycloak or another OIDC provider.

**Requirements**:
- REST API: Accept Keycloak-issued JWTs
- Extract realm roles from Keycloak's nested claim structure
- Workers: Service accounts or client credentials

**Current Support**: ✅ Supported with configuration

**JWT Configuration**:
```yaml
security:
  jwt:
    jwks_uri: "https://keycloak.example.com/realms/myrealm/protocol/openid-connect/certs"
    issuer: "https://keycloak.example.com/realms/myrealm"
    audience: "flovyn-api"
```

**Role Extraction**: Keycloak puts roles in nested claims. Use `ScriptAttributeResolver`:
```javascript
function resolve(principal, tenantId) {
  const attrs = principal.attributes;

  // Keycloak realm roles are in: realm_access.roles
  const realmRoles = JSON.parse(attrs.realm_access || '{}').roles || [];

  // Map Keycloak roles to Flovyn roles
  if (realmRoles.includes('flovyn-admin')) {
    return { role: 'ADMIN' };
  } else if (realmRoles.includes('flovyn-user')) {
    return { role: 'MEMBER' };
  }

  // Keycloak client roles are in: resource_access.{client}.roles
  const clientRoles = JSON.parse(attrs.resource_access || '{}')['flovyn-api']?.roles || [];
  if (clientRoles.includes('owner')) {
    return { role: 'OWNER' };
  }

  return { role: 'MEMBER' };
}
```

**For Workers** (Keycloak Service Accounts):
- Keycloak service accounts get JWTs via client credentials flow
- Same `JwtAuthenticator` works; configure worker as `principalType: "Service"` via script

---

## Summary: Required Implementations

| Priority | Component | Effort | Scenarios |
|----------|-----------|--------|-----------|
| **High** | `StaticApiKeyAuthenticator` | Low | 1 |
| **High** | Pre-configured tenants (config + sync) | Low | 1 |
| **High** | `ClaimsAttributeResolver` | Low | 2, 3, 4 |
| Low | `ExternalApiKeyAuthenticator` | Medium | 3 (Option B) |

## Configuration Philosophy

1. **Centralized**: All auth configuration in one `security:` section
2. **Composable**: Mix authenticators per endpoint (e.g., `["jwt", "api_key"]`)
3. **Progressive**: Start simple (config-based keys), scale up (database, external validation)
4. **Flexible**: Script resolver handles edge cases without code changes

## Non-Goals

- Building a full identity provider
- Supporting OAuth flows (token exchange, refresh) - that's the client's responsibility
- Session management for SPAs - use the front-end's auth solution
