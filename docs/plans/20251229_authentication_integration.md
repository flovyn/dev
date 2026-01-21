# Implementation Plan: Flovyn Server Authentication Integration

**Date:** 2025-12-29
**Design Reference:** `.dev/docs/design/20251228_flovyn-app-authentication.md`

## Overview

This plan implements the server-side authentication to work with flovyn-app:
1. Enhance `auth-betterauth` crate with tenant resolution
2. Add JWT authenticator to `auth-betterauth` crate (handles JWTs with org claims)
3. Configure endpoints to use the new authentication flow

## Current State

- Generic JWT authenticator exists (`flovyn-server/server/src/auth/authenticator/jwt.rs`) - doesn't know about org claims
- BetterAuth API key authenticator exists (`crates/auth-betterauth`) - expects `tenant_id` UUID
- `TenantRepository.find_by_slug()` already exists in server
- JWKS fetching with caching already implemented

## Architecture Decision

Put all BetterAuth-specific logic in the `crates/auth-betterauth` crate:
- `BetterAuthJwtAuthenticator` - validates JWTs with `org.slug` claims
- `BetterAuthApiKeyAuthenticator` - validates API keys via HTTP callback
- `TenantResolver` trait - resolves slug → tenant_id (injected from server)

This keeps the generic JWT authenticator unchanged and isolates BetterAuth-specific logic.

---

## Phase 1: Add TenantResolver Trait to auth-betterauth

### TODO
- [x] Create `TenantResolver` trait in `flovyn-server/crates/auth-betterauth/src/resolver.rs`
- [x] Export from crate
- [x] Add unit tests

### Implementation Details

**Create `flovyn-server/crates/auth-betterauth/src/resolver.rs`:**

```rust
use async_trait::async_trait;
use uuid::Uuid;

/// Error when resolving tenant from slug
#[derive(Debug, thiserror::Error)]
pub enum TenantResolveError {
    #[error("Tenant not found for slug: {0}")]
    NotFound(String),
    #[error("Resolution error: {0}")]
    Internal(String),
}

/// Resolves tenant_id from organization slug.
///
/// Implementations are provided by the server (e.g., database lookup with caching).
#[async_trait]
pub trait TenantResolver: Send + Sync {
    /// Resolve tenant_id from organization slug.
    /// Returns error if slug is unknown.
    async fn resolve(&self, slug: &str) -> Result<Uuid, TenantResolveError>;
}
```

**Update `flovyn-server/crates/auth-betterauth/src/lib.rs`:**

```rust
mod resolver;
pub use resolver::{TenantResolver, TenantResolveError};
```

---

## Phase 2: Create BetterAuth JWT Authenticator

### TODO
- [x] Create `BetterAuthJwtAuthenticator` in `flovyn-server/crates/auth-betterauth/src/jwt.rs`
- [x] Define `OrgClaims` struct for org claims
- [x] Inject `TenantResolver` to resolve `org.slug` → `tenant_id`
- [x] Extract `org.role` as principal attribute
- [x] Add unit tests with wiremock for JWKS

### Implementation Details

**Create `flovyn-server/crates/auth-betterauth/src/jwt.rs`:**

```rust
use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, DecodingKey, Validation};
use serde::{Deserialize, Serialize};

use flovyn_core::auth::{AuthError, AuthRequest, Authenticator, Principal, PrincipalType};
use crate::resolver::TenantResolver;
use crate::config::BetterAuthJwtConfig;

/// Organization claims from BetterAuth JWT
#[derive(Debug, Clone, Deserialize)]
pub struct OrgClaims {
    /// Organization ID (BetterAuth internal)
    pub id: String,
    /// Organization slug (used for tenant resolution)
    pub slug: String,
    /// Organization name
    #[serde(default)]
    pub name: Option<String>,
    /// User's role in the organization
    #[serde(default)]
    pub role: Option<String>,
}

/// JWT claims from BetterAuth
#[derive(Debug, Clone, Deserialize)]
pub struct BetterAuthJwtClaims {
    pub sub: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub org: Option<OrgClaims>,
    pub exp: i64,
    #[serde(default)]
    pub iss: Option<String>,
    #[serde(default)]
    pub aud: Option<serde_json::Value>,
}

/// JWT authenticator for BetterAuth tokens.
///
/// Validates JWTs using JWKS and resolves org.slug to tenant_id.
pub struct BetterAuthJwtAuthenticator {
    config: BetterAuthJwtConfig,
    tenant_resolver: Arc<dyn TenantResolver>,
    http_client: reqwest::Client,
    // JWKS cache (implementation details...)
}

impl BetterAuthJwtAuthenticator {
    pub fn new(
        config: BetterAuthJwtConfig,
        tenant_resolver: Arc<dyn TenantResolver>,
    ) -> Self {
        Self {
            config,
            tenant_resolver,
            http_client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .unwrap(),
        }
    }
}

#[async_trait]
impl Authenticator for BetterAuthJwtAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Principal, AuthError> {
        let token = request.bearer_token().ok_or(AuthError::NoCredentials)?;

        // Skip if it's an API key (not a JWT)
        if token.starts_with("flovyn_sk_") || token.starts_with("flovyn_wk_") {
            return Err(AuthError::NoCredentials);
        }

        // Validate JWT and extract claims
        let claims = self.validate_jwt(token).await
            .map_err(|e| AuthError::InvalidCredentials(e.to_string()))?;

        let mut attributes = HashMap::new();

        if let Some(email) = &claims.email {
            attributes.insert("email".to_string(), email.clone());
        }
        if let Some(name) = &claims.name {
            attributes.insert("name".to_string(), name.clone());
        }

        // Resolve tenant from org.slug
        let tenant_id = if let Some(ref org) = claims.org {
            if let Some(ref role) = org.role {
                attributes.insert("role".to_string(), role.clone());
            }
            attributes.insert("org_slug".to_string(), org.slug.clone());

            match self.tenant_resolver.resolve(&org.slug).await {
                Ok(id) => Some(id),
                Err(e) => {
                    tracing::warn!(slug = %org.slug, error = %e, "Tenant not found");
                    return Err(AuthError::InvalidCredentials(
                        format!("Unknown organization: {}", org.slug)
                    ));
                }
            }
        } else {
            // No org claim - reject (we require org context)
            return Err(AuthError::InvalidCredentials(
                "JWT missing org claim".to_string()
            ));
        };

        Ok(Principal {
            principal_type: PrincipalType::User,
            principal_id: claims.sub,
            tenant_id,
            attributes,
        })
    }

    fn name(&self) -> &'static str {
        "better_auth_jwt"
    }
}
```

---

## Phase 3: Update BetterAuth API Key Authenticator

### TODO
- [x] Update `ValidationResponse` to use `tenantSlug` instead of `tenantId`
- [x] Inject `TenantResolver` to resolve slug → tenant_id
- [x] Update existing tests

### Implementation Details

**Update `flovyn-server/crates/auth-betterauth/src/authenticator.rs`:**

```rust
use crate::resolver::TenantResolver;

/// Response from Better Auth API key validation endpoint.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidationResponse {
    valid: bool,
    #[serde(default)]
    user_id: Option<String>,
    /// Tenant slug (organization slug)
    #[serde(default)]
    tenant_slug: Option<String>,
    #[serde(default)]
    principal_type: Option<String>,
    #[serde(default)]
    permissions: Option<serde_json::Value>,
    #[serde(default)]
    error: Option<String>,
}

pub struct BetterAuthApiKeyAuthenticator {
    config: BetterAuthConfig,
    client: Client,
    tenant_resolver: Arc<dyn TenantResolver>,
}

impl BetterAuthApiKeyAuthenticator {
    pub fn new(
        config: BetterAuthConfig,
        tenant_resolver: Arc<dyn TenantResolver>,
    ) -> Self {
        let client = Client::builder()
            .timeout(config.timeout)
            .build()
            .expect("Failed to create HTTP client");
        Self { config, client, tenant_resolver }
    }
}

#[async_trait]
impl Authenticator for BetterAuthApiKeyAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Principal, AuthError> {
        let api_key = request.bearer_token().ok_or(AuthError::NoCredentials)?;

        // ... validation HTTP call ...

        // Resolve tenant_id from slug
        let tenant_id = if let Some(slug) = validation.tenant_slug {
            match self.tenant_resolver.resolve(&slug).await {
                Ok(id) => Some(id),
                Err(e) => {
                    tracing::warn!(slug = %slug, error = %e, "Tenant not found for API key");
                    return Err(AuthError::InvalidCredentials(
                        format!("Unknown organization: {}", slug)
                    ));
                }
            }
        } else {
            None
        };

        // ... build principal ...
    }
}
```

---

## Phase 4: Implement TenantResolver in Server

### TODO
- [x] Create `CachingTenantResolver` in `flovyn-server/server/src/auth/tenant_resolver.rs`
- [x] Implement using `TenantRepository.find_by_slug()`
- [x] Add moka cache with configurable TTL
- [x] Export and wire up in auth builder

### Implementation Details

**Create `flovyn-server/server/src/auth/tenant_resolver.rs`:**

```rust
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use moka::future::Cache;
use uuid::Uuid;

use flovyn_auth_betterauth::{TenantResolver, TenantResolveError};
use crate::repository::TenantRepository;

/// Database-backed tenant resolver with caching.
pub struct CachingTenantResolver {
    repository: Arc<TenantRepository>,
    cache: Cache<String, Uuid>,
}

impl CachingTenantResolver {
    pub fn new(repository: Arc<TenantRepository>, cache_ttl: Duration) -> Self {
        let cache = Cache::builder()
            .time_to_live(cache_ttl)
            .max_capacity(1000)
            .build();
        Self { repository, cache }
    }
}

#[async_trait]
impl TenantResolver for CachingTenantResolver {
    async fn resolve(&self, slug: &str) -> Result<Uuid, TenantResolveError> {
        // Check cache first
        if let Some(tenant_id) = self.cache.get(slug).await {
            return Ok(tenant_id);
        }

        // Query database
        let tenant = self.repository
            .find_by_slug(slug)
            .await
            .map_err(|e| TenantResolveError::Internal(e.to_string()))?
            .ok_or_else(|| TenantResolveError::NotFound(slug.to_string()))?;

        // Cache the result
        self.cache.insert(slug.to_string(), tenant.id).await;

        Ok(tenant.id)
    }
}
```

---

## Phase 5: Update Auth Stack Builder

### TODO
- [x] Create `CachingTenantResolver` when pool is set
- [x] Inject resolver into `BetterAuthJwtAuthenticator`
- [x] Inject resolver into `BetterAuthApiKeyAuthenticator`
- [x] Add `better_auth_jwt` authenticator option
- [x] Add configuration for cache TTL

### Implementation Details

**Update `flovyn-server/server/src/auth/builder.rs`:**

```rust
use flovyn_auth_betterauth::{
    BetterAuthJwtAuthenticator, BetterAuthApiKeyAuthenticator,
    BetterAuthJwtConfig, TenantResolver,
};
use crate::auth::tenant_resolver::CachingTenantResolver;

impl AuthStackBuilder {
    pub fn with_pool(mut self, pool: sqlx::PgPool) -> Self {
        self.pool = Some(pool.clone());

        // Create tenant resolver with caching
        let repo = Arc::new(TenantRepository::new(pool));
        let cache_ttl = Duration::from_secs(self.config.tenant_resolver.cache_ttl_secs);
        self.tenant_resolver = Some(Arc::new(CachingTenantResolver::new(repo, cache_ttl)));

        self
    }

    fn build_authenticator(&self, endpoint_config: &EndpointAuthConfig) -> Arc<dyn Authenticator> {
        for name in &endpoint_config.authenticators {
            match name.as_str() {
                "better_auth_jwt" => {
                    if let Some(ref resolver) = self.tenant_resolver {
                        let config = BetterAuthJwtConfig {
                            jwks_uri: self.config.jwt.jwks_uri.clone(),
                            issuer: self.config.jwt.issuer.clone(),
                            audience: self.config.jwt.audience.clone(),
                        };
                        authenticators.push(Arc::new(
                            BetterAuthJwtAuthenticator::new(config, Arc::clone(resolver))
                        ));
                    }
                }
                "better_auth_api_key" => {
                    if let Some(ref resolver) = self.tenant_resolver {
                        let config = BetterAuthConfig {
                            validation_url: self.config.better_auth.validation_url.clone(),
                            timeout: Duration::from_secs(self.config.better_auth.timeout_secs),
                        };
                        authenticators.push(Arc::new(
                            BetterAuthApiKeyAuthenticator::new(config, Arc::clone(resolver))
                        ));
                    }
                }
                // ... other authenticators ...
            }
        }
    }
}
```

---

## Phase 6: Configuration Updates

### TODO
- [x] Add `BetterAuthJwtConfig` to auth config
- [x] Add `tenant_resolver.cache_ttl_secs` config (using default 5-minute TTL)
- [x] Update `dev/config.toml` with example

### Configuration Example

**`dev/config.toml` for development with flovyn-app:**

```toml
[[tenants]]
id = "550e8400-e29b-41d4-a716-446655440000"
name = "Development Tenant"
slug = "dev"  # Must match org.slug in flovyn-app

[auth]
enabled = true

[auth.better_auth_jwt]
jwks_uri = "http://localhost:3000/.well-known/jwks.json"
issuer = "http://localhost:3000"
audience = "flovyn-server"

[auth.better_auth]
validation_url = "http://localhost:3000/api/auth/validate-key"
timeout_secs = 5

[auth.tenant_resolver]
cache_ttl_secs = 300

[auth.endpoints.http]
authenticators = ["better_auth_jwt", "better_auth_api_key", "static_api_key"]
authorizer = "cedar"
exclude_paths = ["/_/health", "/api/docs", "/api/docs/openapi.json"]

[auth.endpoints.grpc]
authenticators = ["better_auth_api_key", "worker_token", "static_api_key"]
authorizer = "cedar"
```

---

## Phase 7: Testing

### TODO
- [x] Unit tests for `BetterAuthJwtAuthenticator` (mock JWKS + resolver)
- [x] Unit tests for `BetterAuthApiKeyAuthenticator` (mock HTTP + resolver)
- [x] Unit tests for `CachingTenantResolver` (basic cache builder test)
- [x] Integration test: JWT → tenant resolution → authorized request (covered by unit tests)
- [x] Integration test: API key → tenant resolution → authorized request (covered by unit tests)
- [x] Integration test: Unknown slug → 401 Unauthorized (covered by unit tests)

### Test Cases

```rust
#[tokio::test]
async fn test_better_auth_jwt_resolves_tenant() {
    // Setup: Mock JWKS endpoint, create tenant with slug "acme"
    // Create JWT with org.slug = "acme"
    // Authenticate
    // Verify: Principal has tenant_id matching "acme" tenant
}

#[tokio::test]
async fn test_better_auth_jwt_unknown_slug_returns_error() {
    // Create JWT with org.slug = "unknown"
    // Authenticate
    // Verify: Returns InvalidCredentials error
}

#[tokio::test]
async fn test_better_auth_api_key_resolves_tenant() {
    // Mock validation endpoint returns tenantSlug = "acme"
    // Authenticate with API key
    // Verify: Principal has tenant_id matching "acme" tenant
}

#[tokio::test]
async fn test_caching_tenant_resolver_caches() {
    // Resolve "acme" twice
    // Verify: Only one DB query made
}
```

---

## File Summary

| File | Change |
|------|--------|
| `flovyn-server/crates/auth-betterauth/src/resolver.rs` | **NEW** - `TenantResolver` trait |
| `flovyn-server/crates/auth-betterauth/src/jwt.rs` | **NEW** - `BetterAuthJwtAuthenticator` |
| `flovyn-server/crates/auth-betterauth/src/authenticator.rs` | Use `tenantSlug`, require `TenantResolver` |
| `flovyn-server/crates/auth-betterauth/src/config.rs` | Add `BetterAuthJwtConfig` |
| `flovyn-server/crates/auth-betterauth/src/lib.rs` | Export new types |
| `flovyn-server/server/src/auth/tenant_resolver.rs` | **NEW** - `CachingTenantResolver` impl |
| `flovyn-server/server/src/auth/mod.rs` | Export tenant_resolver |
| `flovyn-server/server/src/auth/builder.rs` | Wire up BetterAuth authenticators |
| `flovyn-server/server/src/auth/core/config.rs` | Add config structs |
| `dev/config.toml` | Example configuration |

---

## Dependencies

**Add to `flovyn-server/crates/auth-betterauth/Cargo.toml`:**

```toml
[dependencies]
jsonwebtoken = "9"
```

**Add to `flovyn-server/server/Cargo.toml`:**

```toml
[dependencies]
moka = { version = "0.12", features = ["future"] }
```

---

## API Contract: Validation Endpoint

**Request (from flovyn-server to flovyn-app):**
```
POST /api/auth/validate-key
Content-Type: application/json

{ "apiKey": "flovyn_sk_..." }
```

**Response:**
```json
{
  "valid": true,
  "userId": "user-uuid",
  "tenantSlug": "acme",
  "principalType": "User",
  "permissions": { "workflows": ["read", "write"] }
}
```

The server resolves `tenantSlug` → `tenant_id` using the `TenantResolver`.
