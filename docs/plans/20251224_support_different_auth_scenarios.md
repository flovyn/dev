# Implementation Plan: Support Different Auth Scenarios

Reference: [Design Document](../design/support-different-auth-scenarios.md)

## Overview

This plan implements all components identified in the design document to support the four authentication scenarios:

| Scenario | Description | Key Components |
|----------|-------------|----------------|
| 1 | Static API Keys | `StaticApiKeyAuthenticator`, Pre-configured tenants |
| 2 | Google OAuth / Service Accounts | `JwtAuthenticator` + `ClaimsAttributeResolver` |
| 3 | Better Auth Integration | `JwtAuthenticator` + `ExternalApiKeyAuthenticator` |
| 4 | Keycloak / Generic OIDC | `JwtAuthenticator` + `ScriptAttributeResolver` |

## Current State Analysis

### What Already Exists

| Component | Status | Location |
|-----------|--------|----------|
| `Authenticator` trait | Complete | `flovyn-server/crates/core/src/auth/traits.rs` |
| `JwtAuthenticator` | Complete | `flovyn-server/server/src/auth/authenticator/jwt.rs` |
| `CompositeAuthenticator` | Complete | `flovyn-server/server/src/auth/authenticator/composite.rs` |
| `AuthStackBuilder` | Complete | `flovyn-server/server/src/auth/builder.rs` |
| `ClaimsAttributeResolver` | Complete | `flovyn-server/server/src/auth/attributes/claims.rs` |
| `ScriptAttributeResolver` | Complete | `flovyn-server/crates/auth-script/src/lib.rs` |
| `TenantRepository` | Complete | `flovyn-server/server/src/repository/tenant_repository.rs` |
| Config loading | Complete | `flovyn-server/server/src/config.rs` using `config` crate |

### What Needs Implementation

| Priority | Component | Effort | Scenarios |
|----------|-----------|--------|-----------|
| **High** | `StaticApiKeyAuthenticator` | Low | 1 |
| **High** | Pre-configured tenants (config + sync) | Low | 1 |
| **High** | ClaimsAttributeResolver integration tests | Low | 2, 3, 4 |
| **Low** | `BetterAuthApiKeyAuthenticator` | Medium | 3 (Option B) |

---

## Part 1: High Priority - Static API Keys (Scenario 1)

### Task 1.1: Create auth-statickeys Crate

**Directory: `crates/auth-statickeys/`** (new crate)

Create a dedicated crate for static API key authentication, following the pattern of other auth crates.

**File: `flovyn-server/crates/auth-statickeys/Cargo.toml`**

```toml
[package]
name = "flovyn-auth-statickeys"
version = "0.1.0"
edition = "2021"

[dependencies]
flovyn-core = { path = "../core" }
async-trait = "0.1"
uuid = { version = "1", features = ["serde"] }
serde = { version = "1", features = ["derive"] }

[dev-dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
```

**File: `flovyn-server/crates/auth-statickeys/src/lib.rs`**

```rust
//! Static API key authentication for Flovyn.
//!
//! This crate provides an authenticator that validates API keys
//! from a pre-configured list.

mod authenticator;
mod config;

pub use authenticator::StaticApiKeyAuthenticator;
pub use config::{ApiKeyEntry, StaticKeysConfig};
```

### Task 1.2: StaticApiKeyAuthenticator

**File: `flovyn-server/crates/auth-statickeys/src/authenticator.rs`**

Create the authenticator that validates API keys from configuration.

```rust
use std::collections::HashMap;
use async_trait::async_trait;
use uuid::Uuid;

use flovyn_core::auth::{AuthError, AuthRequest, Principal, PrincipalType};
use crate::auth::core::Authenticator;

/// Configuration for a single API key.
#[derive(Debug, Clone)]
pub struct ApiKeyEntry {
    pub key: String,
    pub tenant_id: Uuid,
    pub principal_type: PrincipalType,
    pub principal_id: String,
    pub role: Option<String>,
}

/// Authenticator that validates static API keys from configuration.
pub struct StaticApiKeyAuthenticator {
    /// Map from API key to its configuration
    keys: HashMap<String, ApiKeyEntry>,
}

impl StaticApiKeyAuthenticator {
    pub fn new(entries: Vec<ApiKeyEntry>) -> Self {
        let keys = entries.into_iter().map(|e| (e.key.clone(), e)).collect();
        Self { keys }
    }
}

#[async_trait]
impl Authenticator for StaticApiKeyAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Principal, AuthError> {
        // Extract Bearer token
        let token = request.bearer_token().ok_or(AuthError::NoCredentials)?;

        // Look up key
        let entry = self.keys.get(token).ok_or(AuthError::InvalidCredentials(
            "Invalid API key".to_string(),
        ))?;

        // Build principal with attributes
        let mut attributes = HashMap::new();
        if let Some(ref role) = entry.role {
            attributes.insert("role".to_string(), role.clone());
        }

        Ok(Principal {
            principal_type: entry.principal_type.clone(),
            principal_id: entry.principal_id.clone(),
            tenant_id: Some(entry.tenant_id),
            attributes,
        })
    }

    fn name(&self) -> &'static str {
        "static_api_key"
    }
}
```

**Tests** (in `flovyn-server/crates/auth-statickeys/src/authenticator.rs`):
- Authenticate with valid key returns correct principal
- Authenticate with invalid key returns `InvalidCredentials`
- Authenticate without credentials returns `NoCredentials`
- Role attribute is set when configured
- Worker principal type is correctly assigned

### Task 1.3: Static Keys Config Types

**File: `flovyn-server/crates/auth-statickeys/src/config.rs`**

```rust
use serde::Deserialize;
use uuid::Uuid;
use flovyn_core::auth::PrincipalType;

/// Configuration for the static API key authenticator.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct StaticKeysConfig {
    /// List of configured API keys.
    pub keys: Vec<ApiKeyEntry>,
}

/// Configuration for a single API key.
#[derive(Debug, Clone, Deserialize)]
pub struct ApiKeyEntry {
    /// The API key value (secret).
    pub key: String,
    /// Tenant ID this key is scoped to.
    pub tenant_id: Uuid,
    /// Principal type: "User", "Worker", or "Service".
    #[serde(default = "default_principal_type")]
    pub principal_type: PrincipalType,
    /// Principal ID (e.g., "api:production", "worker:default").
    pub principal_id: String,
    /// Role for RBAC: "OWNER", "ADMIN", "MEMBER" (optional).
    pub role: Option<String>,
}

fn default_principal_type() -> PrincipalType {
    PrincipalType::User
}
```

---

### Task 1.4: Server Integration - Config Types

**File: `flovyn-server/server/src/auth/core/config.rs`**

Add configuration types for server-side:

```rust
/// Static API key configuration.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct StaticApiKeyAuthConfig {
    /// List of configured API keys.
    pub keys: Vec<ApiKeyConfig>,
}

/// Configuration for a single API key.
#[derive(Debug, Clone, Deserialize)]
pub struct ApiKeyConfig {
    /// The API key value (secret).
    pub key: String,
    /// Tenant ID this key is scoped to.
    pub tenant_id: Uuid,
    /// Principal type: "User", "Worker", or "Service".
    #[serde(default = "default_principal_type")]
    pub principal_type: String,
    /// Principal ID (e.g., "api:production", "worker:default").
    pub principal_id: String,
    /// Role for RBAC: "OWNER", "ADMIN", "MEMBER" (optional).
    pub role: Option<String>,
}

fn default_principal_type() -> String {
    "User".to_string()
}
```

Add to `AuthConfig`:
```rust
pub struct AuthConfig {
    // ... existing fields ...
    /// Static API key configuration.
    pub static_api_key: StaticApiKeyAuthConfig,
}
```

---

### Task 1.5: Server Integration - Feature Flag and Builder

**File: `flovyn-server/server/Cargo.toml`**

Add optional dependency:

```toml
[features]
default = ["cedar-authz", "script-authz", "static-keys", "plugin-worker-token"]
cedar-authz = ["flovyn-auth-cedar"]
script-authz = ["flovyn-auth-script"]
static-keys = ["flovyn-auth-statickeys"]
plugin-worker-token = ["flovyn-plugin-worker-token"]

[dependencies]
flovyn-auth-statickeys = { path = "../crates/auth-statickeys", optional = true }
```

**File: `flovyn-server/server/src/auth/builder.rs`**

```rust
#[cfg(feature = "static-keys")]
use flovyn_auth_statickeys::{StaticApiKeyAuthenticator, ApiKeyEntry};

// In build_authenticator method:
"static_api_key" => {
    #[cfg(feature = "static-keys")]
    {
        let entries = self.build_api_key_entries();
        if entries.is_empty() {
            tracing::warn!("static_api_key authenticator has no keys configured");
        }
        authenticators.push(Arc::new(StaticApiKeyAuthenticator::new(entries)));
    }
    #[cfg(not(feature = "static-keys"))]
    {
        tracing::warn!("static_api_key authenticator requires static-keys feature");
    }
}

// New helper method:
#[cfg(feature = "static-keys")]
fn build_api_key_entries(&self) -> Vec<ApiKeyEntry> {
    use flovyn_core::auth::PrincipalType;

    self.config.static_api_key.keys.iter().map(|c| {
        let principal_type = match c.principal_type.as_str() {
            "Worker" => PrincipalType::Worker,
            "Service" => PrincipalType::Service,
            _ => PrincipalType::User,
        };
        ApiKeyEntry {
            key: c.key.clone(),
            tenant_id: c.tenant_id,
            principal_type,
            principal_id: c.principal_id.clone(),
            role: c.role.clone(),
        }
    }).collect()
}
```

---

### Task 1.6: Pre-configured Tenants - Configuration Types

**File: `flovyn-server/server/src/config.rs`**

Add tenant configuration to `ServerConfig` (this stays in server, not a separate crate).

```rust
/// Pre-configured tenant definition.
#[derive(Debug, Clone, Deserialize)]
pub struct TenantConfig {
    /// Tenant UUID (must be valid UUID).
    pub id: Uuid,
    /// Tenant name.
    pub name: String,
    /// Unique slug for the tenant.
    pub slug: String,
    /// Tier: "FREE", "PRO", "ENTERPRISE" (optional, defaults to "FREE").
    #[serde(default = "default_tier")]
    pub tier: String,
    /// Region (optional).
    pub region: Option<String>,
}

fn default_tier() -> String {
    "FREE".to_string()
}

pub struct ServerConfig {
    // ... existing fields ...

    /// Pre-configured tenants to sync on startup.
    #[serde(default)]
    pub tenants: Vec<TenantConfig>,
}
```

---

### Task 1.7: Tenant Sync on Startup

**File: `flovyn-server/server/src/startup.rs`** (new file)

Create a startup module for initialization tasks.

```rust
use sqlx::PgPool;
use uuid::Uuid;
use crate::config::TenantConfig;
use crate::repository::TenantRepository;
use crate::domain::NewTenant;

/// Sync pre-configured tenants from config to database.
pub async fn sync_tenants(
    pool: &PgPool,
    tenants: &[TenantConfig],
) -> anyhow::Result<()> {
    if tenants.is_empty() {
        return Ok(());
    }

    let repo = TenantRepository::new(pool.clone());

    for tenant_config in tenants {
        repo.upsert(&NewTenant {
            id: tenant_config.id,
            name: tenant_config.name.clone(),
            slug: tenant_config.slug.clone(),
            tier: tenant_config.tier.clone(),
            region: tenant_config.region.clone(),
        }).await?;

        tracing::info!(
            tenant_id = %tenant_config.id,
            name = %tenant_config.name,
            "Synced pre-configured tenant"
        );
    }

    Ok(())
}
```

**File: `flovyn-server/server/src/main.rs`**

Call sync during startup:

```rust
// After database pool creation, before server start:
startup::sync_tenants(&pool, &config.tenants).await?;
```

---

### Task 1.8: Configuration Validation

**File: `flovyn-server/server/src/auth/core/config.rs`**

Add validation to ensure static API keys reference valid tenants.

```rust
impl AuthConfig {
    pub fn validate_with_tenants(&self, tenant_ids: &[Uuid]) -> Result<(), ConfigError> {
        // Existing validation
        self.validate()?;

        if !self.enabled {
            return Ok(());
        }

        // Validate static API key tenant references
        for (i, key_config) in self.static_api_key.keys.iter().enumerate() {
            if !tenant_ids.contains(&key_config.tenant_id) {
                return Err(ConfigError::Validation(format!(
                    "static_api_key.keys[{}]: tenant_id {} not found in configured tenants",
                    i, key_config.tenant_id
                )));
            }
        }

        Ok(())
    }
}
```

**File: `flovyn-server/server/src/main.rs`**

Validate before startup:

```rust
// Validate tenant references in API keys
let tenant_ids: Vec<Uuid> = config.tenants.iter().map(|t| t.id).collect();
config.auth.validate_with_tenants(&tenant_ids)?;
```

---

### Task 1.9: Update TenantRepository for Upsert

**File: `flovyn-server/server/src/repository/tenant_repository.rs`**

Add upsert method:

```rust
pub async fn upsert(&self, tenant: &NewTenant) -> Result<Tenant, sqlx::Error> {
    sqlx::query_as::<_, Tenant>(
        r#"
        INSERT INTO tenant (id, name, slug, tier, region, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            tier = EXCLUDED.tier,
            region = EXCLUDED.region,
            updated_at = NOW()
        RETURNING *
        "#
    )
    .bind(tenant.id)
    .bind(&tenant.name)
    .bind(&tenant.slug)
    .bind(&tenant.tier)
    .bind(&tenant.region)
    .fetch_one(&self.pool)
    .await
}
```

---

## Part 2: High Priority - Google OAuth / Service Accounts (Scenario 2)

Scenario 2 uses the same approach as Keycloak: `JwtAuthenticator` + `ScriptAttributeResolver`. This provides flexibility for extracting roles from Google's JWT claims structure.

### Task 2.1: Google OAuth Configuration Example

**File: `examples/config/google-oauth.env`** (new file)

```bash
# Google OAuth Configuration for Flovyn Server
# Use with Google Identity Platform or Firebase Auth

AUTH__ENABLED=true

# HTTP endpoints: Accept Google-issued JWTs
AUTH__ENDPOINTS__HTTP__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__HTTP__AUTHORIZER=cedar

# gRPC endpoints: Accept Google Service Account JWTs
AUTH__ENDPOINTS__GRPC__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__GRPC__AUTHORIZER=cedar

# JWT validation against Google's public keys
AUTH__JWT__JWKS_URI=https://www.googleapis.com/oauth2/v3/certs
AUTH__JWT__ISSUER=https://accounts.google.com
AUTH__JWT__AUDIENCE=your-client-id.apps.googleusercontent.com

# Use script resolver for role derivation (same approach as Keycloak)
AUTH__ATTR_RESOLVER__RESOLVER_TYPE=script
AUTH__ATTR_RESOLVER__SCRIPT__PATH=./config/google-resolver.js
```

### Task 2.2: Google Role Extraction Script

**File: `examples/config/google-resolver.js`** (new file)

```javascript
// Script for extracting roles from Google JWT claims
// Works with Google Identity Platform, Firebase Auth, and Google Workspace

function resolve(principal, tenantId) {
  const attrs = principal.attributes;
  const email = attrs.email || '';
  const hd = attrs.hd || '';  // Google Workspace domain (hosted domain)
  const emailVerified = attrs.email_verified === 'true';

  // Determine principal type
  // Google Service Accounts have emails ending in .iam.gserviceaccount.com
  let principalType = 'User';
  if (email.endsWith('.iam.gserviceaccount.com')) {
    principalType = 'Service';
  }

  // Check for custom claims (if using Firebase Auth custom claims)
  // These would be set via Firebase Admin SDK
  const customRole = attrs['https://flovyn.io/role'];
  if (customRole) {
    return { role: customRole, principalType: principalType };
  }

  // Map Google Workspace domain to roles
  if (hd === 'yourcompany.com' && emailVerified) {
    return { role: 'ADMIN', principalType: principalType };
  }

  // Check for specific admin emails
  const ownerEmails = ['admin@example.com', 'ops@example.com'];
  if (ownerEmails.includes(email)) {
    return { role: 'OWNER', principalType: principalType };
  }

  // Default to MEMBER for verified emails
  if (emailVerified) {
    return { role: 'MEMBER', principalType: principalType };
  }

  // Deny unverified emails
  return { role: 'ANONYMOUS', principalType: principalType };
}
```

### Task 2.3: OIDC Integration Test (Using Keycloak)

OIDC integration tests use Keycloak via Testcontainers as a representative provider. This validates the full flow with a real OIDC provider that we can control.

**Note:** Google and Better Auth OIDC use the same `JwtAuthenticator` + `ScriptAttributeResolver` pattern, so testing with Keycloak validates the approach for all providers. The only differences are the claim structures, which are handled by provider-specific scripts.

---

## Part 3: High Priority - Better Auth Integration (Scenario 3)

### Task 3.1: Better Auth OIDC Configuration Example

**File: `examples/config/better-auth-oidc.env`** (new file)

```bash
# Better Auth OIDC Configuration
# For applications using Better Auth's OIDC Provider plugin

AUTH__ENABLED=true

# HTTP endpoints: Accept Better Auth OIDC tokens
AUTH__ENDPOINTS__HTTP__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__HTTP__AUTHORIZER=cedar

# gRPC endpoints: Use worker tokens (Option A - Recommended)
AUTH__ENDPOINTS__GRPC__AUTHENTICATORS=["worker_token"]
AUTH__ENDPOINTS__GRPC__AUTHORIZER=cedar

# Better Auth JWKS endpoint
AUTH__JWT__JWKS_URI=https://your-app.com/.well-known/jwks.json
AUTH__JWT__ISSUER=https://your-app.com
AUTH__JWT__AUDIENCE=flovyn

# Worker token for gRPC
WORKER_TOKEN_SECRET=your-worker-token-secret

# Claims-based attribute resolution
AUTH__ATTR_RESOLVER__RESOLVER_TYPE=claims
AUTH__ATTR_RESOLVER__MAPPINGS__0__ATTRIBUTE=role
AUTH__ATTR_RESOLVER__MAPPINGS__0__CLAIMS_PATH=tenant_roles.{tenant_id}
AUTH__ATTR_RESOLVER__MAPPINGS__0__VALUE_TYPE=string
```

---

## Part 4: Low Priority - BetterAuthApiKeyAuthenticator (Scenario 3, Option B)

For deployments where API keys are managed in Better Auth.

### Task 4.1: Create auth-betterauth Crate

**Directory: `crates/auth-betterauth/`** (new crate)

Create a dedicated crate for Better Auth integration, following the pattern of `auth-script` and `auth-cedar`.

**File: `flovyn-server/crates/auth-betterauth/Cargo.toml`**

```toml
[package]
name = "flovyn-auth-betterauth"
version = "0.1.0"
edition = "2021"

[dependencies]
flovyn-core = { path = "../core" }
async-trait = "0.1"
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1", features = ["derive"] }
tracing = "0.1"
uuid = { version = "1", features = ["serde"] }
thiserror = "2"

[dev-dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
wiremock = "0.6"
```

**File: `flovyn-server/crates/auth-betterauth/src/lib.rs`**

```rust
//! Better Auth integration for Flovyn authentication.
//!
//! This crate provides an authenticator that validates API keys
//! against a Better Auth instance.

mod authenticator;
mod config;
mod error;

pub use authenticator::BetterAuthApiKeyAuthenticator;
pub use config::BetterAuthConfig;
pub use error::BetterAuthError;
```

### Task 4.2: BetterAuthApiKeyAuthenticator

**File: `flovyn-server/crates/auth-betterauth/src/authenticator.rs`**

```rust
use async_trait::async_trait;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

use flovyn_core::auth::{AuthError, AuthRequest, Principal, PrincipalType};
use crate::auth::core::Authenticator;

/// Response from external API key validation endpoint.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidationResponse {
    valid: bool,
    #[serde(default)]
    user_id: Option<String>,
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default)]
    principal_type: Option<String>,
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// Request body for API key validation.
#[derive(Debug, Serialize)]
struct ValidationRequest {
    api_key: String,
}

/// Configuration for Better Auth API key authenticator.
#[derive(Debug, Clone)]
pub struct BetterAuthApiKeyConfig {
    /// Better Auth API key validation URL.
    pub validation_url: String,
    /// Timeout for validation requests.
    pub timeout: Duration,
}

impl Default for BetterAuthApiKeyConfig {
    fn default() -> Self {
        Self {
            validation_url: String::new(),
            timeout: Duration::from_secs(5),
        }
    }
}

/// Authenticator that validates API keys against Better Auth.
pub struct BetterAuthApiKeyAuthenticator {
    config: BetterAuthApiKeyConfig,
    client: Client,
}

impl BetterAuthApiKeyAuthenticator {
    pub fn new(config: BetterAuthApiKeyConfig) -> Self {
        let client = Client::builder()
            .timeout(config.timeout)
            .build()
            .expect("Failed to create HTTP client");
        Self { config, client }
    }
}

#[async_trait]
impl Authenticator for BetterAuthApiKeyAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Principal, AuthError> {
        // Extract Bearer token
        let api_key = request.bearer_token().ok_or(AuthError::NoCredentials)?;

        // Build validation request to Better Auth
        let response = self.client
            .post(&self.config.validation_url)
            .json(&ValidationRequest {
                api_key: api_key.to_string(),
            })
            .send()
            .await
            .map_err(|e| {
                tracing::error!(error = %e, "Better Auth API key validation failed");
                AuthError::Internal(format!("Validation request failed: {}", e))
            })?;

        if !response.status().is_success() {
            return Err(AuthError::InvalidCredentials(format!(
                "Validation endpoint returned {}",
                response.status()
            )));
        }

        let validation: ValidationResponse = response.json().await.map_err(|e| {
            AuthError::Internal(format!("Failed to parse validation response: {}", e))
        })?;

        if !validation.valid {
            return Err(AuthError::InvalidCredentials(
                validation.error.unwrap_or_else(|| "Invalid API key".to_string()),
            ));
        }

        // Build principal from validation response
        let principal_type = match validation.principal_type.as_deref() {
            Some("Worker") => PrincipalType::Worker,
            Some("Service") => PrincipalType::Service,
            _ => PrincipalType::User,
        };

        let mut attributes = std::collections::HashMap::new();
        if let Some(role) = validation.role {
            attributes.insert("role".to_string(), role);
        }

        Ok(Principal {
            principal_type,
            principal_id: validation.user_id.unwrap_or_else(|| "unknown".to_string()),
            tenant_id: validation.tenant_id,
            attributes,
        })
    }

    fn name(&self) -> &'static str {
        "better_auth_api_key"
    }
}
```

### Task 4.3: Better Auth Config and Error Types

**File: `flovyn-server/crates/auth-betterauth/src/config.rs`**

```rust
use std::time::Duration;
use serde::Deserialize;

/// Configuration for Better Auth API key authentication.
#[derive(Debug, Clone, Deserialize)]
pub struct BetterAuthConfig {
    /// Better Auth API key validation URL.
    /// Example: https://your-app.com/api/auth/validate-key
    pub validation_url: String,
    /// Timeout for validation requests (default: 5 seconds).
    #[serde(default = "default_timeout")]
    pub timeout: Duration,
}

fn default_timeout() -> Duration {
    Duration::from_secs(5)
}

impl Default for BetterAuthConfig {
    fn default() -> Self {
        Self {
            validation_url: String::new(),
            timeout: default_timeout(),
        }
    }
}
```

**File: `flovyn-server/crates/auth-betterauth/src/error.rs`**

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum BetterAuthError {
    #[error("HTTP request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("Invalid response from Better Auth: {0}")]
    InvalidResponse(String),
    #[error("Configuration error: {0}")]
    Config(String),
}
```

### Task 4.4: Server Integration - Config Types

**File: `flovyn-server/server/src/auth/core/config.rs`**

Add configuration types for server-side:

```rust
/// Better Auth API key authenticator configuration.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct BetterAuthAuthConfig {
    /// Better Auth API key validation URL.
    pub validation_url: String,
    /// Timeout in seconds (default: 5).
    #[serde(default = "default_better_auth_timeout")]
    pub timeout_secs: u64,
}

fn default_better_auth_timeout() -> u64 {
    5
}
```

Add to `AuthConfig`:
```rust
pub struct AuthConfig {
    // ... existing fields ...
    /// Better Auth API key authenticator configuration.
    pub better_auth: BetterAuthAuthConfig,
}
```

### Task 4.5: Server Integration - Feature Flag and Builder

**File: `flovyn-server/server/Cargo.toml`**

Add optional dependency:

```toml
[features]
default = ["cedar-authz", "script-authz", "plugin-worker-token"]
cedar-authz = ["flovyn-auth-cedar"]
script-authz = ["flovyn-auth-script"]
better-auth = ["flovyn-auth-betterauth"]
plugin-worker-token = ["flovyn-plugin-worker-token"]

[dependencies]
flovyn-auth-betterauth = { path = "../crates/auth-betterauth", optional = true }
```

**File: `flovyn-server/server/src/auth/builder.rs`**

```rust
#[cfg(feature = "better-auth")]
use flovyn_auth_betterauth::{BetterAuthApiKeyAuthenticator, BetterAuthConfig};

// In build_authenticator method:
"better_auth_api_key" => {
    #[cfg(feature = "better-auth")]
    {
        let config = &self.config.better_auth;
        if config.validation_url.is_empty() {
            tracing::warn!("better_auth_api_key authenticator requires validation_url");
        } else {
            authenticators.push(Arc::new(BetterAuthApiKeyAuthenticator::new(
                BetterAuthConfig {
                    validation_url: config.validation_url.clone(),
                    timeout: Duration::from_secs(config.timeout_secs),
                }
            )));
        }
    }
    #[cfg(not(feature = "better-auth"))]
    {
        tracing::warn!("better_auth_api_key authenticator requires better-auth feature");
    }
}
```

### Task 4.6: Better Auth API Key Configuration Example

**File: `examples/config/better-auth-api-key.env`** (new file)

```bash
# Better Auth API Key Validation (Option B)
# For when API keys are managed in Better Auth

AUTH__ENABLED=true

# HTTP endpoints: OIDC tokens
AUTH__ENDPOINTS__HTTP__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__HTTP__AUTHORIZER=cedar

# gRPC endpoints: Better Auth API keys
AUTH__ENDPOINTS__GRPC__AUTHENTICATORS=["better_auth_api_key"]
AUTH__ENDPOINTS__GRPC__AUTHORIZER=cedar

# JWT config for HTTP
AUTH__JWT__JWKS_URI=https://your-app.com/.well-known/jwks.json
AUTH__JWT__ISSUER=https://your-app.com
AUTH__JWT__AUDIENCE=flovyn

# Better Auth API key validation
AUTH__BETTER_AUTH__VALIDATION_URL=https://your-app.com/api/auth/validate-key
AUTH__BETTER_AUTH__TIMEOUT_SECS=5
```

### Task 4.7: Integration Test for Better Auth API Key

**File: `flovyn-server/tests/integration/auth_better_auth_test.rs`** (new file)

```rust
//! Integration test for BetterAuthApiKeyAuthenticator.
//! Uses mock HTTP server for validation endpoint.

use wiremock::{MockServer, Mock, ResponseTemplate};
use wiremock::matchers::{method, path};

#[tokio::test]
async fn test_better_auth_api_key_valid() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/api/auth/validate-key"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "valid": true,
            "userId": "user-123",
            "tenantId": "550e8400-e29b-41d4-a716-446655440000",
            "role": "ADMIN"
        })))
        .mount(&mock_server)
        .await;

    // Test authentication succeeds
}

#[tokio::test]
async fn test_better_auth_api_key_invalid() {
    // Test authentication fails with invalid key
}

#[tokio::test]
async fn test_better_auth_api_key_timeout() {
    // Test timeout handling
}
```

---

## Part 5: High Priority - Keycloak / Generic OIDC (Scenario 4)

Scenario 4 is already supported with existing components. This section adds configuration examples.

### Task 5.1: Keycloak Configuration Example

**File: `examples/config/keycloak.env`** (new file)

```bash
# Keycloak / Generic OIDC Configuration

AUTH__ENABLED=true

# Both HTTP and gRPC use JWT (Keycloak service accounts for workers)
AUTH__ENDPOINTS__HTTP__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__HTTP__AUTHORIZER=cedar
AUTH__ENDPOINTS__GRPC__AUTHENTICATORS=["jwt"]
AUTH__ENDPOINTS__GRPC__AUTHORIZER=cedar

# Keycloak JWKS endpoint
AUTH__JWT__JWKS_URI=https://keycloak.example.com/realms/myrealm/protocol/openid-connect/certs
AUTH__JWT__ISSUER=https://keycloak.example.com/realms/myrealm
AUTH__JWT__AUDIENCE=flovyn-api

# Use script resolver for Keycloak's nested claim structure
AUTH__ATTR_RESOLVER__RESOLVER_TYPE=script
AUTH__ATTR_RESOLVER__SCRIPT__PATH=./config/keycloak-resolver.js
```

### Task 5.2: Keycloak Role Extraction Script

**File: `examples/config/keycloak-resolver.js`** (new file)

```javascript
// Script for extracting roles from Keycloak JWT claims
// Keycloak puts roles in nested structures

function resolve(principal, tenantId) {
  const attrs = principal.attributes;

  // Parse realm_access.roles (realm-level roles)
  let realmRoles = [];
  try {
    const realmAccess = JSON.parse(attrs.realm_access || '{}');
    realmRoles = realmAccess.roles || [];
  } catch (e) {
    // Ignore parse errors
  }

  // Parse resource_access.{client}.roles (client-level roles)
  let clientRoles = [];
  try {
    const resourceAccess = JSON.parse(attrs.resource_access || '{}');
    const clientAccess = resourceAccess['flovyn-api'] || {};
    clientRoles = clientAccess.roles || [];
  } catch (e) {
    // Ignore parse errors
  }

  // Determine principal type (Service for service accounts)
  let principalType = 'User';
  const azp = attrs.azp || '';
  const preferredUsername = attrs.preferred_username || '';
  if (preferredUsername.startsWith('service-account-')) {
    principalType = 'Service';
  }

  // Map Keycloak roles to Flovyn roles
  // Priority: OWNER > ADMIN > MEMBER
  if (realmRoles.includes('flovyn-owner') || clientRoles.includes('owner')) {
    return { role: 'OWNER', principalType: principalType };
  }
  if (realmRoles.includes('flovyn-admin') || clientRoles.includes('admin')) {
    return { role: 'ADMIN', principalType: principalType };
  }
  if (realmRoles.includes('flovyn-user') || clientRoles.includes('user')) {
    return { role: 'MEMBER', principalType: principalType };
  }

  // Default to MEMBER
  return { role: 'MEMBER', principalType: principalType };
}
```

### Task 5.3: OIDC Integration Test with Keycloak Testcontainer

**File: `flovyn-server/tests/integration/auth_oidc_test.rs`** (new file)

This test uses Keycloak via Testcontainers to validate OIDC authentication end-to-end. It serves as the representative test for all OIDC providers (Google, Better Auth, Keycloak).

```rust
//! OIDC integration tests using Keycloak Testcontainer.
//!
//! Keycloak is used as the representative OIDC provider because:
//! - Full control over users, roles, and claims
//! - Real JWT signing and JWKS endpoint
//! - Testcontainers support for reproducible tests
//!
//! The same JwtAuthenticator + ScriptAttributeResolver pattern
//! works for Google and Better Auth with different scripts.

use testcontainers::{clients::Cli, images::keycloak::Keycloak};

struct KeycloakTestContext {
    container: Container<Keycloak>,
    admin_token: String,
    realm: String,
    client_id: String,
    jwks_uri: String,
}

impl KeycloakTestContext {
    async fn setup() -> Self {
        // 1. Start Keycloak container
        // 2. Create test realm
        // 3. Create client with roles
        // 4. Create test users with different roles
    }

    async fn get_user_token(&self, username: &str, password: &str) -> String {
        // Get JWT for a test user via password grant
    }

    async fn get_service_account_token(&self) -> String {
        // Get JWT via client credentials grant
    }
}

#[tokio::test]
async fn test_oidc_user_with_realm_roles() {
    let ctx = KeycloakTestContext::setup().await;

    // Create user with realm role "flovyn-admin"
    // Get JWT for user
    // Make authenticated request to Flovyn
    // Verify: ScriptAttributeResolver extracts ADMIN role
    // Verify: Cedar allows admin operations
}

#[tokio::test]
async fn test_oidc_user_with_client_roles() {
    let ctx = KeycloakTestContext::setup().await;

    // Create user with client role "owner"
    // Get JWT for user
    // Verify: resource_access claim is parsed correctly
    // Verify: User gets OWNER role
}

#[tokio::test]
async fn test_oidc_service_account() {
    let ctx = KeycloakTestContext::setup().await;

    // Get service account JWT (client credentials)
    // Verify: Principal type is Service
    // Verify: Can perform worker-like operations
}

#[tokio::test]
async fn test_oidc_user_without_roles() {
    let ctx = KeycloakTestContext::setup().await;

    // Create user with no roles
    // Verify: Defaults to MEMBER role
}

#[tokio::test]
async fn test_oidc_invalid_token() {
    // Use expired or tampered JWT
    // Verify: Authentication fails
}

#[tokio::test]
async fn test_oidc_wrong_issuer() {
    // Use JWT from different issuer
    // Verify: Authentication fails
}
```

**Test Dependencies** (add to `Cargo.toml`):
```toml
[dev-dependencies]
testcontainers = "0.15"
testcontainers-modules = { version = "0.3", features = ["keycloak"] }
```

---

## TODO Checklist

### Part 1: Static API Keys (High Priority) ✅

#### Crate: `crates/auth-statickeys/`
- [x] Create `flovyn-server/crates/auth-statickeys/Cargo.toml`
- [x] Create `flovyn-server/crates/auth-statickeys/src/lib.rs`
- [x] Create `StaticApiKeyAuthenticator` in `flovyn-server/crates/auth-statickeys/src/authenticator.rs`
- [x] Create config types in `flovyn-server/crates/auth-statickeys/src/config.rs`
- [x] Add unit tests for `StaticApiKeyAuthenticator`

#### Server Integration
- [x] Add `static-keys` feature flag to `flovyn-server/server/Cargo.toml`
- [x] Add `StaticApiKeyAuthConfig` and `ApiKeyConfig` to `flovyn-server/server/src/auth/core/config.rs`
- [x] Add `static_api_key` field to `AuthConfig`
- [x] Integrate `static_api_key` authenticator in `AuthStackBuilder`
- [x] Add builder tests for static API key authenticator

#### Pre-configured Tenants
- [x] Add `TenantConfig` to `flovyn-server/server/src/config.rs`
- [x] Add `tenants` field to `ServerConfig`
- [x] Create `flovyn-server/server/src/startup.rs` with `sync_tenants` function
- [x] Add `upsert` method to `TenantRepository`
- [x] Call `sync_tenants` in `main.rs` during startup
- [x] Add `validate_api_key_tenant_refs` to `startup.rs` (simplified from `validate_with_tenants`)
- [x] Call validation in `main.rs` before startup
- [x] Add integration test: pre-configured tenants with static API keys (`static_api_key_tests.rs`)

### Part 2: Google OAuth (High Priority) ✅
- [x] Create `examples/config/google-oauth.env`
- [x] Create `examples/config/google-resolver.js`

### Part 3: Better Auth OIDC (High Priority) ✅
- [x] Create `examples/config/better-auth-oidc.env`

### Part 4: BetterAuthApiKeyAuthenticator (Low Priority) ✅

#### Crate: `crates/auth-betterauth/`
- [x] Create `flovyn-server/crates/auth-betterauth/Cargo.toml`
- [x] Create `flovyn-server/crates/auth-betterauth/src/lib.rs`
- [x] Create `BetterAuthApiKeyAuthenticator` in `flovyn-server/crates/auth-betterauth/src/authenticator.rs`
- [x] Create config types in `flovyn-server/crates/auth-betterauth/src/config.rs`
- [x] Create error types in `flovyn-server/crates/auth-betterauth/src/error.rs`
- [x] Add unit tests for `BetterAuthApiKeyAuthenticator` (using wiremock)

#### Server Integration
- [x] Add `better-auth` feature flag to `flovyn-server/server/Cargo.toml`
- [x] Add `BetterAuthAuthConfig` to `flovyn-server/server/src/auth/core/config.rs`
- [x] Add `better_auth` field to `AuthConfig`
- [x] Integrate `better_auth_api_key` authenticator in `AuthStackBuilder`
- [x] Create `examples/config/better-auth-api-key.env`
- [ ] Add integration test `flovyn-server/tests/integration/auth_better_auth_test.rs` (deferred - wiremock tests in crate provide coverage)

### Part 5: Keycloak / Generic OIDC (High Priority) ✅
- [x] Create `examples/config/keycloak.env`
- [x] Create `examples/config/keycloak-resolver.js`
- [x] Create `flovyn-server/examples/config/static-api-keys.toml`
- [x] Add OIDC integration tests (`flovyn-server/server/tests/integration/oidc_tests.rs`)
  - Uses `skip_verification` mode for simplicity (JWT signing/verification tested in unit tests)
  - Tests JWT authentication with Keycloak-like claims
  - Tests rejection of unauthenticated requests

---

## Example Configurations Summary

After implementation, these configuration examples will be available:

| File | Scenario | Description |
|------|----------|-------------|
| `flovyn-server/examples/config/static-api-keys.toml` | 1 | Static API keys with pre-configured tenants |
| `examples/config/google-oauth.env` | 2 | Google OAuth with script resolver |
| `examples/config/google-resolver.js` | 2 | Google role extraction script |
| `examples/config/better-auth-oidc.env` | 3 | Better Auth OIDC + worker tokens (Option A) |
| `examples/config/better-auth-api-key.env` | 3 | Better Auth API key validation (Option B) |
| `examples/config/keycloak.env` | 4 | Keycloak OIDC with script resolver |
| `examples/config/keycloak-resolver.js` | 4 | Keycloak role extraction script |

**Note:** All OIDC scenarios (Google, Better Auth OIDC, Keycloak) use the same pattern: `JwtAuthenticator` + `ScriptAttributeResolver`. The scripts handle provider-specific claim structures.

---

## Testing Strategy

1. **Unit tests** for new authenticators (in respective crates):
   - `StaticApiKeyAuthenticator` (`crates/auth-statickeys`): Valid/invalid/missing keys, role propagation
   - `BetterAuthApiKeyAuthenticator` (`crates/auth-betterauth`): Valid/invalid responses, timeout, error handling (using wiremock)

2. **Integration tests**:
   - **Static API Keys**: Test with pre-configured tenants and keys
   - **OIDC (Keycloak Testcontainer)**: Real OIDC provider for end-to-end JWT validation
     - Keycloak serves as representative for all OIDC providers (Google, Better Auth, Keycloak)
     - Tests realm roles, client roles, service accounts, invalid tokens
   - **Better Auth API Key**: Use wiremock to mock validation endpoint

3. **Configuration tests**:
   - Deserialization of all config types
   - Validation of tenant references
   - Validation of required fields

---

## Part 6: SDK Changes (For Static API Keys)

The Rust SDK (`../sdk-rust`) currently only supports worker tokens (`fwt_`/`fct_` prefix). For static API keys, the SDK needs to accept arbitrary Bearer tokens.

### Task 6.1: Update SDK Auth Interceptor

**File: `flovyn-server/sdk-rust/core/src/client/auth.rs`**

Update `WorkerTokenInterceptor` to support static API keys:

```rust
/// Authentication interceptor for gRPC requests.
/// Supports both worker tokens (fwt_/fct_) and static API keys.
#[derive(Clone)]
pub struct AuthInterceptor {
    token: String,
}

impl AuthInterceptor {
    /// Create a new auth interceptor with a worker token.
    /// Token must start with 'fwt_' or 'fct_' prefix.
    pub fn worker_token(token: impl Into<String>) -> Self {
        let token = token.into();
        assert!(
            token.starts_with("fwt_") || token.starts_with("fct_"),
            "Worker token must start with 'fwt_' or 'fct_' prefix"
        );
        Self { token }
    }

    /// Create a new auth interceptor with a static API key.
    /// No prefix validation - accepts any key.
    pub fn api_key(key: impl Into<String>) -> Self {
        Self { token: key.into() }
    }
}

impl Interceptor for AuthInterceptor {
    fn call(&mut self, mut request: Request<()>) -> Result<Request<()>, Status> {
        request
            .metadata_mut()
            .insert("authorization", self.authorization_value());
        Ok(request)
    }
}
```

### Task 6.2: Update SDK Client Builder

**File: `flovyn-server/sdk-rust/sdk/src/client/builder.rs`**

Add `api_key` method as alternative to `worker_token`:

```rust
pub struct FlovynClientBuilder {
    // ...
    auth_token: Option<AuthToken>,
    // ...
}

enum AuthToken {
    WorkerToken(String),
    ApiKey(String),
}

impl FlovynClientBuilder {
    /// Set the worker token for gRPC authentication.
    /// The token must start with 'fwt_' or 'fct_' prefix.
    pub fn worker_token(mut self, token: impl Into<String>) -> Self {
        self.auth_token = Some(AuthToken::WorkerToken(token.into()));
        self
    }

    /// Set a static API key for gRPC authentication.
    /// Use this when the server is configured with static API keys.
    pub fn api_key(mut self, key: impl Into<String>) -> Self {
        self.auth_token = Some(AuthToken::ApiKey(key.into()));
        self
    }

    pub async fn build(self) -> Result<super::FlovynClient> {
        let auth_token = self.auth_token.ok_or_else(|| {
            FlovynError::InvalidConfiguration(
                "Authentication required. Use .worker_token() or .api_key() to set credentials.".to_string(),
            )
        })?;

        let interceptor = match auth_token {
            AuthToken::WorkerToken(token) => AuthInterceptor::worker_token(token),
            AuthToken::ApiKey(key) => AuthInterceptor::api_key(key),
        };
        // ...
    }
}
```

### Task 6.3: Update SDK Examples

Update examples to show both authentication methods:

```rust
// Option 1: Worker token (existing behavior)
let client = FlovynClient::builder()
    .server_address(&server_host, server_port)
    .tenant_id(tenant_id)
    .worker_token("fwt_abc123...")
    .build()
    .await?;

// Option 2: Static API key (new)
let client = FlovynClient::builder()
    .server_address(&server_host, server_port)
    .tenant_id(tenant_id)
    .api_key("flovyn_wk_live_xyz789...")
    .build()
    .await?;
```

---

## TODO Checklist (SDK)

### Part 6: SDK Changes ✅
- [x] Rename `WorkerTokenInterceptor` to `AuthInterceptor` in `flovyn-server/sdk-rust/core/src/client/auth.rs`
- [x] Add `api_key()` constructor to `AuthInterceptor`
- [x] Add `api_key()` method to `FlovynClientBuilder` (uses same `worker_token` field internally)
- [x] Update `worker_token()` to validate prefix and suggest `api_key()` for static keys
- [x] Update error message in `build()` to mention both auth methods
- [x] Update core client wrappers to use `AuthInterceptor::api_key()` (supports both token types)
- [x] Add tests for API key authentication (8 new tests in auth.rs, 5 new tests in builder.rs)
- [x] Keep `WorkerTokenInterceptor` as deprecated type alias for backwards compatibility

---

## Part 7: SDK OAuth2 Client Credentials Auth Strategy ✅

The SDK now supports OAuth2 client credentials flow as an authentication strategy, allowing workers to authenticate using OAuth2/OIDC providers.

### Task 7.1: OAuth2 Module

**File: `flovyn-server/sdk-rust/sdk/src/client/oauth2.rs`** (new file)

Created OAuth2 module with:
- `OAuth2Credentials` struct for client_id, client_secret, token_endpoint
- `TokenResponse` and `TokenError` types
- `fetch_access_token()` function for OAuth2 client credentials flow
- `CachedToken` for future token refresh support

### Task 7.2: Builder Integration

**File: `flovyn-server/sdk-rust/sdk/src/client/builder.rs`**

Added OAuth2 client credentials methods:
- `oauth2_client_credentials(client_id, client_secret, token_endpoint)` - basic usage
- `oauth2_client_credentials_with_scopes(...)` - with additional scopes

The `build()` method now fetches the JWT token automatically when OAuth2 credentials are configured.

### Task 7.3: Feature Flag

**File: `flovyn-server/sdk-rust/sdk/Cargo.toml`**

Added:
- `reqwest` as optional dependency
- `oauth2` feature flag (enabled by default)

### Usage Example

```rust
// OAuth2 client credentials flow
let client = FlovynClient::builder()
    .server_address("localhost", 9090)
    .tenant_id(tenant_id)
    .oauth2_client_credentials(
        "my-worker-client",
        "my-client-secret",
        "https://keycloak.example.com/realms/flovyn/protocol/openid-connect/token"
    )
    .build()
    .await?;

// With additional scopes
let client = FlovynClient::builder()
    .server_address("localhost", 9090)
    .tenant_id(tenant_id)
    .oauth2_client_credentials_with_scopes(
        "my-worker-client",
        "my-client-secret",
        "https://keycloak.example.com/realms/flovyn/protocol/openid-connect/token",
        vec!["openid".to_string(), "profile".to_string()]
    )
    .build()
    .await?;
```

---

## TODO Checklist (SDK Part 7)

### Part 7: SDK OAuth2 Client Credentials ✅
- [x] Add `reqwest` as optional dependency with `oauth2` feature flag (enabled by default)
- [x] Create `OAuth2Credentials` struct with client_id, client_secret, token_endpoint
- [x] Create `fetch_access_token()` function using OAuth2 client credentials flow
- [x] Add `oauth2_client_credentials()` method to `FlovynClientBuilder`
- [x] Add `oauth2_client_credentials_with_scopes()` method for custom scopes
- [x] Update `build()` to fetch JWT when OAuth2 credentials are configured
- [x] Add `AuthenticationError` variant to `FlovynError`
- [x] Export `OAuth2Credentials` in prelude when feature is enabled
- [x] Add unit tests for OAuth2 module (8 tests)

---

## Non-Goals

As per design document:
- Building a full identity provider
- Supporting OAuth flows (token exchange, refresh)
- Session management for SPAs
