# Flovyn App Authentication Integration

**Status:** Draft
**Date:** 2025-12-28

## Overview

This document defines how the Flovyn App (NextJS + BetterAuth) authenticates with the Flovyn Server API. The app manages users and organizations via BetterAuth; the server manages workflow execution with multi-tenant isolation.

**Key principle:** BetterAuth organization **slug** = Flovyn tenant **slug** (used for linking).

## Current State

### Flovyn App (flovyn-app)
- Uses BetterAuth with organization plugin
- JWT tokens include: `sub`, `email`, `name`, `org.id`, `org.slug`, `org.role`
- JWKS endpoint at `flovyn-server//.well-known/jwks.json`
- Has `getAccessToken()` helper that fetches JWT for API calls

### Flovyn Server (flovyn-server)
- JWT authenticator (`flovyn-server/server/src/auth/authenticator/jwt.rs`) - validates JWTs
- BetterAuth API key authenticator (`crates/auth-betterauth`) - validates API keys via HTTP callback
- Static API key authenticator - for dev/testing
- Worker token authenticator - for workers

## Deployment Modes

### Mode 1: Self-Hosted (Static Tenants)

Customer deploys their own server with pre-configured tenants.

**Characteristics:**
- Tenants defined in config file (`dev/config.toml`)
- Fixed set of tenants, rarely changes
- Can be used with or without Flovyn App

**Authentication Options:**

| Client | Method | How it Works |
|--------|--------|--------------|
| Flovyn App (User) | JWT | App sends JWT → Server validates via JWKS → Resolves tenant by `org.slug` |
| Flovyn App (User) | Static API Key | Customer pre-configures API keys per tenant |
| Worker | Worker Token | HMAC-signed token with embedded tenant_id |
| Worker | Static API Key | Pre-configured in config file |

**Configuration Example:**
```toml
[[tenants]]
id = "550e8400-e29b-41d4-a716-446655440000"  # Server's internal ID (auto-generated or manual)
name = "Acme Corp"
slug = "acme"  # Must match org.slug in BetterAuth

[auth]
enabled = true

[auth.jwt]
jwks_uri = "https://app.acme.com/.well-known/jwks.json"
issuer = "https://app.acme.com"
audience = "flovyn-server"

[auth.endpoints.http]
authenticators = ["jwt", "static_api_key"]
authorizer = "cedar"
```

**Trade-offs:**
- ✅ Simple configuration
- ✅ Works without external dependencies
- ✅ Full control over tenants
- ✅ Slug-based linking is intuitive (no UUID synchronization)
- ❌ Requires config change to add tenants

### Mode 2: SaaS (Dynamic Tenants)

Single server instance serving multiple customers with on-demand tenant creation.

**Characteristics:**
- Tenants created automatically when organizations are created in BetterAuth
- No pre-configuration required
- Server trusts BetterAuth as source of truth for organization/tenant mapping

**Authentication Flow:**

```
┌─────────────┐      JWT w/ org.slug     ┌─────────────────┐
│ Flovyn App  │ ────────────────────────>│  Flovyn Server  │
└─────────────┘                          └────────┬────────┘
                                                  │
                                    Extract org.slug from JWT
                                                  │
                                         ┌────────v────────┐
                                         │ Lookup tenant   │
                                         │ by slug         │
                                         └─────────────────┘
```

**Auto-Tenant Creation:**
When JWT contains an unknown `org.slug`, the server can:
1. **Option A: Reject** - Return 403 "Unknown tenant" (safer, requires explicit onboarding)
2. **Option B: Auto-create** - Create tenant with org.id, using org metadata from JWT (simpler UX)

**Recommendation:** Option A (reject) by default, with Option B configurable.

**Configuration Example:**
```toml
[auth]
enabled = true
auto_create_tenant = false  # Option A: explicit onboarding required

[auth.jwt]
jwks_uri = "https://app.flovyn.com/.well-known/jwks.json"
issuer = "https://app.flovyn.com"
audience = "flovyn-server"

[auth.endpoints.http]
authenticators = ["jwt"]
authorizer = "cedar"
```

## Authentication Methods Detail

### 1. JWT (Primary for Flovyn App Users)

**Token Flow:**
1. User logs into Flovyn App
2. User selects active organization
3. App calls `getAccessToken()` → receives JWT with org claims
4. App includes `Authorization: Bearer <jwt>` in API calls
5. Server validates JWT signature via JWKS
6. Server extracts `org.slug` → looks up tenant by slug → gets `tenant_id`
7. Server extracts `org.role` → uses for authorization (owner, admin, member)

**Required JWT Claims:**
```json
{
  "sub": "user-uuid",
  "email": "user@example.com",
  "name": "John Doe",
  "org": {
    "id": "org-uuid",      // BetterAuth's internal ID (informational)
    "slug": "acme",        // → used to resolve tenant_id
    "name": "Acme Corp",
    "role": "admin"        // → used for authorization
  },
  "aud": "flovyn-server",
  "iss": "https://app.example.com",
  "exp": 1234567890
}
```

**Current Gap:** The JWT authenticator extracts `sub` but doesn't yet extract `org.slug` to resolve `tenant_id` or `org.role` as attribute.

### 2. API Keys (Alternative for Flovyn App or External Integrations)

Two options for API key validation:

**Option A: Static API Keys (Self-Hosted)**
- Defined in config file
- No external dependency
- Good for development and simple deployments

**Option B: BetterAuth API Key Validation (Integrated)**
- API keys managed in BetterAuth
- Server validates via HTTP callback to BetterAuth
- Uses existing `crates/auth-betterauth` crate

**API Key Validation Endpoint Contract:**
```typescript
// POST /api/auth/validate-key
// Request:
{ "apiKey": "flovyn_sk_..." }

// Response:
{
  "valid": true,
  "userId": "user-uuid",
  "tenantId": "org-uuid",      // Organization ID
  "principalType": "User",     // or "Worker", "Service"
  "role": "ADMIN"
}
```

### 3. Worker Tokens (for Workers)

Workers need to authenticate for long-running poll operations.

**Options:**
- **HMAC Worker Token:** Server-generated `fwt_<base64>` tokens with embedded tenant_id
- **API Keys via BetterAuth:** Workers use API keys managed in BetterAuth

**Recommendation:** Use HMAC worker tokens for:
- Lower latency (no HTTP roundtrip for validation)
- Works offline
- Tenant-scoped by design

## Implementation Requirements

### Server Changes Needed

1. **Enhance JWT Authenticator** (`flovyn-server/server/src/auth/authenticator/jwt.rs`):
   - Extract `org.slug` claim → lookup tenant by slug → set `tenant_id` on Principal
   - Extract `org.role` claim → set as `role` attribute
   - Handle missing `org` claim (return error for endpoints requiring tenant context)

2. **Tenant Resolution Strategy:**
   ```rust
   // Priority order for tenant_id:
   // 1. From JWT org.slug claim → lookup tenant by slug
   // 2. From API key validation response (already has tenant_id)
   // 3. From worker token payload (already has tenant_id)
   // 4. From X-Tenant-ID header (for admin endpoints only)
   ```

3. **Tenant Lookup by Slug:**
   - Add `get_tenant_by_slug()` to repository
   - Cache slug → tenant_id mapping (short TTL, e.g., 5 minutes)
   - Return 403 if slug not found (unless auto_create_tenant enabled)

4. **Add JWKS Fetching with Caching:**
   - Fetch JWKS from configured URI
   - Cache with configurable TTL (default 1 hour)
   - Fallback to local cache on fetch failure

5. **Optional: Auto-Tenant Creation:**
   - Config flag: `auth.auto_create_tenant`
   - On first request with unknown org.slug, create tenant record
   - Use org.name and org.slug from JWT to populate tenant fields
   - Generate new UUID for tenant_id

### Flovyn App Changes Needed

1. **Add API Key Plugin to BetterAuth:**

```ts
// better-auth-server.ts
import { apiKey, deviceAuthorization } from "better-auth/plugins";

export const auth = betterAuth({
  plugins: [
    apiKey({
      defaultPrefix: "flovyn_sk_",           // Prefix for easy identification
      enableMetadata: true,                   // Store org context
      rateLimit: {
        enabled: true,
        timeWindow: 86400000,                 // 24 hours
        maxRequests: 10000,
      },
      permissions: {
        defaultPermissions: async (userId) => {
          // Could map to org role
          return { workflows: ["read", "write"], tasks: ["read", "write"] };
        },
      },
    }),
    deviceAuthorization({
      verificationUri: "/device",
    }),
    // ... other plugins
  ],
});
```

```ts
// better-auth-client.ts
import { apiKeyClient, deviceAuthorizationClient } from "better-auth/client/plugins";

export const authClient = createAuthClient({
  plugins: [
    apiKeyClient(),
    deviceAuthorizationClient(),
  ],
});
```

2. **Run Migration:**
```bash
pnpm dlx @better-auth/cli migrate
```

3. **Create API Key Management UI:**

| Page | Scope | Key Type | Purpose |
|------|-------|----------|---------|
| `/profile/api-keys` | Personal | User (`flovyn_sk_`) | CLI access, personal integrations |
| `/settings/worker-tokens` | Organization | Worker (`flovyn_wk_`) | Workers polling for tasks |

**Key Types:**

| Type | Prefix | Scope | Use Case |
|------|--------|-------|----------|
| **User** | `flovyn_sk_` | Personal | CLI, personal scripts, integrations |
| **Worker** | `flovyn_wk_` | Organization | SDK workers, background jobs |

```tsx
// Profile page: Create personal API key for CLI
const { data } = await authClient.apiKey.create({
  name: "My Laptop CLI",
  prefix: "flovyn_sk_",
  permissions: {
    workflows: ["read", "write", "start", "cancel"],
    tasks: ["read"],
  },
  metadata: {
    orgSlug: activeOrganization.slug,
  },
});

// Org settings: Create worker token for infrastructure
const { data } = await authClient.apiKey.create({
  name: "Production Worker Pool",
  prefix: "flovyn_wk_",
  permissions: {
    tasks: ["read", "write", "execute", "heartbeat"],
    workflows: ["read"],
  },
  metadata: {
    orgSlug: activeOrganization.slug,
  },
});
```

**Key differences:**
- User keys: shown only to the user who created them
- Worker tokens: visible to org admins, shared across infrastructure

4. **Implement API Key Validation Endpoint:**

```ts
// app/api/auth/validate-key/route.ts
import { auth } from "@/lib/auth/better-auth-server";

export async function POST(request: Request) {
  const { apiKey } = await request.json();

  const result = await auth.api.verifyApiKey({
    body: { key: apiKey },
  });

  if (!result.valid || !result.key) {
    return Response.json({ valid: false, error: result.error?.message });
  }

  const metadata = result.key.metadata as { orgSlug: string };

  // Determine principal type from prefix
  const principalType = result.key.prefix === "flovyn_wk_" ? "Worker" : "User";

  return Response.json({
    valid: true,
    userId: result.key.userId,
    tenantSlug: metadata.orgSlug,
    principalType,
    permissions: result.key.permissions,
  });
}
```

5. **Expose Organization Slug in JWT:**
   - Already done: `org.slug` is included in JWT payload

6. **Add Device Flow Pages:**

| Page | Purpose |
|------|---------|
| `/device` | User enters code from CLI |
| `/device/approve` | User approves/denies authorization |

## Security Considerations

1. **Tenant Isolation:**
   - JWT `org.slug` is the ONLY source of tenant context for user requests
   - Never trust client-provided tenant_id or slug headers (except for admin APIs with extra verification)
   - Slug lookup must be authoritative (from DB), not from request

2. **Token Expiry:**
   - JWTs from BetterAuth expire in 5 minutes
   - Server must reject expired tokens (already handled by JWT validation)

3. **Key Rotation:**
   - JWKS endpoint supports key rotation
   - Server should cache keys but respect cache headers

4. **Rate Limiting:**
   - JWKS fetching should be rate-limited (prevent DoS via forced cache invalidation)
   - BetterAuth API key validation calls should be rate-limited

## Configuration Summary

### Minimal Self-Hosted Config
```toml
[[tenants]]
id = "550e8400-e29b-41d4-a716-446655440000"  # Server's internal UUID
name = "My Tenant"
slug = "my-tenant"  # Must match org.slug in BetterAuth

[auth]
enabled = true

[auth.jwt]
jwks_uri = "https://myapp.com/.well-known/jwks.json"
audience = "flovyn-server"

[auth.endpoints.http]
authenticators = ["jwt"]
authorizer = "cedar"
```

### Full SaaS Config
```toml
[auth]
enabled = true
auto_create_tenant = false

[auth.jwt]
jwks_uri = "https://app.flovyn.com/.well-known/jwks.json"
issuer = "https://app.flovyn.com"
audience = "flovyn-server"

[auth.better_auth]
validation_url = "https://app.flovyn.com/api/auth/validate-key"
timeout_secs = 5

[auth.endpoints.http]
authenticators = ["jwt", "better_auth_api_key"]
authorizer = "cedar"

[auth.endpoints.grpc]
authenticators = ["worker_token", "better_auth_api_key"]
authorizer = "cedar"
```

## CLI Authentication

For CLI tools (like a `flovyn` CLI) to authenticate and interact with the Flovyn Server API.

**Use cases:**
- Developer runs `flovyn workflow list` from terminal
- CI/CD pipeline triggers workflows via `flovyn workflow start`
- Debug/inspect workflows from SSH session on remote server

### Option A: Device Authorization Flow (Recommended)

Standard OAuth 2.0 Device Authorization Grant (RFC 8628). BetterAuth has built-in support via the `deviceAuthorization` plugin.

```
┌──────────┐                              ┌─────────────┐
│  CLI     │ ──1. POST /auth/device/code─>│ Flovyn App  │
└──────────┘                              └─────────────┘
     │                                           │
     │<──2. Return device_code + user_code ──────┤
     │                                           │
     │   3. Display: "Visit https://app.flovyn.com/device"
     │              "Enter code: ABCD-1234"
     │                                           │
     │   (User visits URL, logs in, enters code) │
     │                                           │
     │ ──4. POST /auth/device/token (poll) ──────>
     │<──5. Return access_token (JWT) ───────────┤
     │                                           │
     │ ──6. Use JWT to call Flovyn Server ───────────────> [Flovyn Server]
```

**Pros:**
- Works on headless servers (no browser needed on CLI machine)
- Standard OAuth flow (RFC 8628)
- BetterAuth plugin available - no custom implementation needed

**Flovyn App Setup:**

```ts
// better-auth-server.ts
import { deviceAuthorization } from "better-auth/plugins";

export const auth = betterAuth({
  plugins: [
    deviceAuthorization({
      verificationUri: "/device",      // User visits this page
      expiresIn: 60 * 30,              // 30 minutes
      interval: 5,                      // Poll every 5 seconds
      userCodeLength: 8,                // e.g., "ABCD-1234"
    }),
    // ... other plugins
  ],
});
```

**CLI Implementation (Rust):**

```rust
// 1. Request device code
let resp = client.post("https://app.flovyn.com/auth/device/code")
    .json(&json!({ "client_id": "flovyn-cli", "scope": "openid" }))
    .send().await?;

let device_code = resp.json::<DeviceCodeResponse>().await?;
// { device_code, user_code, verification_uri, interval }

println!("Visit: {}", device_code.verification_uri);
println!("Enter code: {}", device_code.user_code);

// 2. Poll for token
loop {
    tokio::time::sleep(Duration::from_secs(device_code.interval)).await;

    let resp = client.post("https://app.flovyn.com/auth/device/token")
        .json(&json!({
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": device_code.device_code,
            "client_id": "flovyn-cli",
        }))
        .send().await?;

    match resp.json::<TokenResponse>().await? {
        TokenResponse::Success { access_token, .. } => {
            save_token(&access_token)?;
            break;
        }
        TokenResponse::Error { error: "authorization_pending" } => continue,
        TokenResponse::Error { error: "slow_down" } => {
            interval += 5; // Back off
            continue;
        }
        TokenResponse::Error { error } => return Err(anyhow!("{}", error)),
    }
}
```

**CLI UX:**
```bash
$ flovyn auth login
Visit: https://app.flovyn.com/device
Enter code: ABCD-1234

Waiting for authorization... ✓
Logged in as john@example.com (org: acme)
Token saved to ~/.flovyn/credentials
```

### Option B: API Key

User creates API key in web UI, configures CLI manually.

**Pros:**
- Simplest to implement
- Works everywhere
- No OAuth complexity

**Cons:**
- Worse UX (user must copy-paste)
- API keys are long-lived (security concern)
- User must manage key lifecycle manually

**CLI UX:**
```bash
$ flovyn auth login --api-key
Enter API key: flovyn_sk_xxxxxxxxxxxx
Validating... ✓
Logged in as john@example.com (org: acme)
```

### Supported Methods

| Method | Use Case | Requirements |
|--------|----------|--------------|
| **Device Flow** | Interactive login (developers) | BetterAuth device flow plugin |
| **API Key** | CI/CD, automation, scripts | API key management in Flovyn App |

**Implementation order:**
1. **API Key** - Works today, no BetterAuth changes needed
2. **Device Flow** - Add BetterAuth plugin, then CLI support

### Token Storage

CLI should store credentials securely:

| Platform | Storage |
|----------|---------|
| macOS | Keychain (`security` command) |
| Linux | `~/.flovyn/credentials` (chmod 600) or Secret Service |
| Windows | Windows Credential Manager |

**Credential file format:**
```toml
# ~/.flovyn/credentials
[default]
type = "jwt"  # or "api_key"
token = "eyJhbG..."
expires_at = "2025-12-28T12:00:00Z"
org_slug = "acme"
server_url = "https://api.flovyn.com"

[profiles.staging]
type = "api_key"
token = "flovyn_sk_..."
org_slug = "acme-staging"
server_url = "https://staging.api.flovyn.com"
```

### JWT Refresh

JWTs from BetterAuth expire in 5 minutes. CLI needs refresh strategy:

1. **Option A: Refresh token** - BetterAuth issues refresh token, CLI uses it to get new JWT
2. **Option B: Re-authenticate** - When JWT expires, prompt user to re-login
3. **Option C: Session token** - Store BetterAuth session cookie, fetch new JWT as needed

**Recommendation:** Option A (refresh token) if BetterAuth supports it, otherwise Option C.

## Open Questions

1. **Slug Uniqueness:** Slugs must be globally unique across all BetterAuth instances pointing to the same server. In SaaS mode, this is enforced by BetterAuth. In self-hosted mode with multiple BetterAuth instances, slug collisions are possible. Mitigation options:
   - Prefix slugs with instance identifier
   - Require unique slugs in documentation
   - Add issuer to slug lookup (slug + issuer = tenant)

2. **Organization Membership Changes:** If a user is removed from an org in BetterAuth, their cached JWT may still be valid. Acceptable due to short expiry (5 min)?

3. **Multi-Org Users:** A user can belong to multiple orgs. The JWT contains only the *active* org. Is this sufficient, or do we need endpoints to list accessible tenants?

4. **Worker Token Provisioning:** In SaaS mode, how are worker tokens generated?
   - Option A: Server generates, stored in DB, exposed via API
   - Option B: BetterAuth manages worker tokens as special API keys

5. **API Key Org Switching:** If a user belongs to multiple orgs, each API key is scoped to one org (via `orgSlug` in metadata). User must create separate keys per org they want to access.
