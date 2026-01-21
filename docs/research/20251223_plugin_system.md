# Plugin System Research

## Context

Flovyn Server uses an open-core license model. We need a plugin system that allows:

1. **Own database tables and migrations** - Plugins manage their own schema
2. **Own endpoints** - REST and gRPC endpoints
3. **Access to core services** - Initially auth (`Authenticator`, `Authorizer`), more over time

## Requirements

| Requirement | Priority | Notes |
|-------------|----------|-------|
| Plugin-managed migrations | Must | Each plugin owns its DB schema |
| REST endpoint registration | Must | Merge into Axum router |
| gRPC service registration | Should | Extend Tonic services |
| Access to core services | Must | Auth now, repos/scheduler later |
| Runtime loading (no recompile) | Nice | For third-party plugins |
| Sandboxing | Nice | Isolate untrusted plugins |

## Approaches Evaluated

### 1. Compile-Time Plugins (Feature Flags)

Plugins are separate crates, conditionally compiled via Cargo features.

```rust
// Cargo.toml
[features]
plugin-audit = ["flovyn-plugin-audit"]

[dependencies]
flovyn-plugin-audit = { path = "plugins/audit-log", optional = true }
```

**Pros:**
- Full type safety - plugins use Rust traits directly
- No runtime overhead
- Easy debugging and testing
- Async traits work natively
- IDE support (autocomplete, go-to-definition)

**Cons:**
- Requires recompilation to add/remove plugins
- All plugins must be known at build time
- Not suitable for true third-party extensibility

**Best for:** Open-core tiers (community vs enterprise), vetted partner plugins.

### 2. Dynamic Loading (`libloading` + `abi_stable`)

Plugins compiled as shared libraries (`.so`/`.dylib`/`.dll`), loaded at runtime.

```rust
use abi_stable::prelude::*;

#[sabi_trait]
pub trait PluginFfi: Send + Sync {
    fn name(&self) -> RString;
    fn migrations(&self) -> RVec<MigrationFfi>;
}
```

**Pros:**
- True runtime loading - no recompilation
- Plugins can be added/removed without server rebuild
- Native performance

**Cons:**
- ABI stability is complex - `abi_stable` crate required
- No async support in `abi_stable` (need `async_ffi` workaround)
- Plugins must use exact same `abi_stable` version
- FFI-safe wrappers needed for all types crossing boundary
- Debugging is harder
- Malicious/buggy plugins can crash the host

**Best for:** Third-party plugin ecosystems where recompilation is not acceptable.

### 3. WASM Plugins (Extism/Wasmtime)

Plugins compiled to WebAssembly, executed in sandboxed runtime.

```rust
use extism::{Plugin, host_fn};

#[host_fn]
fn authenticate(request: Json<AuthRequest>) -> Json<AuthResult> {
    // Host implements, plugin calls
}
```

**Pros:**
- Sandboxed - plugins cannot crash host or access memory
- Language-agnostic - plugins in Rust, Go, JS, etc.
- No ABI compatibility issues
- Safe to run untrusted code

**Cons:**
- Performance overhead (~10-20%)
- All host interactions via host functions - complex to expose rich APIs
- Async is difficult across WASM boundary
- DB access must go through host functions
- Limited ecosystem for complex use cases

**Best for:** Untrusted third-party plugins, simple extension points.

### 4. Script-Based Plugins (Rhai/Lua)

Embed a scripting language for lightweight extensions.

```rust
use rhai::{Engine, Scope};

let engine = Engine::new();
engine.register_fn("authenticate", |req: AuthRequest| { ... });
let result = engine.eval_file("plugins/custom.rhai")?;
```

**Pros:**
- Very safe - scripts run in interpreter sandbox
- Hot-reload without restart
- Simple for non-Rust developers

**Cons:**
- Limited to what you expose
- Performance overhead
- Not suitable for complex plugins (DB, endpoints)
- Type safety lost

**Best for:** Simple customization (e.g., custom validation rules, transformations).

## Comparison Matrix

| Approach | Type Safety | Performance | Runtime Load | Async Support | Sandboxing | Complexity |
|----------|-------------|-------------|--------------|---------------|------------|------------|
| Feature Flags | Excellent | Native | No | Full | No | Low |
| abi_stable | Good | Native | Yes | Via async_ffi | No | High |
| WASM | Limited | ~80-90% | Yes | Difficult | Yes | High |
| Scripting | None | ~50% | Yes | No | Yes | Medium |

## Recommendation

### Phase 1: Compile-Time Plugins (Feature Flags)

Start with compile-time plugins for several reasons:

1. **Simplicity** - No FFI, no ABI concerns, just Rust traits
2. **Full async support** - Core services like `Authenticator` are async traits
3. **Type safety** - Plugins get compile-time checks against core APIs
4. **Incremental** - Easy to add runtime loading later without breaking existing plugins

### Phase 2: Runtime Loading (Optional Future)

If third-party extensibility becomes a requirement:

1. Define a stable `PluginApi` trait with versioning
2. Use `abi_stable` for the plugin interface
3. Wrap core services in FFI-safe adapters
4. Consider WASM for untrusted plugins

## Proposed Design

### Plugin Trait

```rust
use async_trait::async_trait;
use axum::Router;
use sqlx::migrate::Migration;

/// Services provided by core to plugins
pub struct PluginServices {
    pub db_pool: PgPool,
    pub authenticator: Arc<dyn Authenticator>,
    pub authorizer: Arc<dyn Authorizer>,
    // Future: workflow_repo, task_repo, scheduler, etc.
}

/// Plugin interface
#[async_trait]
pub trait Plugin: Send + Sync + 'static {
    /// Unique plugin identifier
    fn name(&self) -> &'static str;

    /// Semantic version
    fn version(&self) -> &'static str;

    /// Database migrations owned by this plugin
    fn migrations(&self) -> Vec<Migration> {
        vec![]
    }

    /// REST routes to merge into main router
    fn rest_routes(&self, services: Arc<PluginServices>) -> Router {
        Router::new()
    }

    /// gRPC services to register
    fn grpc_services(&self, services: Arc<PluginServices>) -> Vec<BoxGrpcService> {
        vec![]
    }

    /// Custom authenticator to add to composite
    fn authenticator(&self, services: Arc<PluginServices>) -> Option<Arc<dyn Authenticator>> {
        None
    }

    /// Custom authorizer to add to composite
    fn authorizer(&self, services: Arc<PluginServices>) -> Option<Arc<dyn Authorizer>> {
        None
    }

    /// Called during server startup
    async fn on_startup(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        Ok(())
    }

    /// Called during graceful shutdown
    async fn on_shutdown(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        Ok(())
    }
}
```

### Plugin Registry

```rust
pub struct PluginRegistry {
    plugins: Vec<Arc<dyn Plugin>>,
}

impl PluginRegistry {
    pub fn new() -> Self {
        let mut registry = Self { plugins: vec![] };

        #[cfg(feature = "plugin-audit")]
        registry.register(Arc::new(flovyn_plugin_audit::AuditPlugin));

        #[cfg(feature = "plugin-sso")]
        registry.register(Arc::new(flovyn_plugin_sso::SsoPlugin));

        registry
    }

    pub fn register(&mut self, plugin: Arc<dyn Plugin>) {
        tracing::info!(plugin = plugin.name(), "Registered plugin");
        self.plugins.push(plugin);
    }

    pub async fn run_migrations(&self, pool: &PgPool) -> Result<()> {
        for plugin in &self.plugins {
            for migration in plugin.migrations() {
                tracing::info!(
                    plugin = plugin.name(),
                    version = migration.version,
                    "Running plugin migration"
                );
                migration.run(pool).await?;
            }
        }
        Ok(())
    }

    pub fn build_router(&self, services: Arc<PluginServices>) -> Router {
        let mut router = Router::new();
        for plugin in &self.plugins {
            let plugin_routes = plugin.rest_routes(services.clone());
            router = router.merge(plugin_routes);
        }
        router
    }

    pub fn collect_authenticators(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authenticator>> {
        self.plugins
            .iter()
            .filter_map(|p| p.authenticator(services.clone()))
            .collect()
    }
}
```

### Migration Strategy

Each plugin prefixes its tables to avoid conflicts:

```sql
-- plugins/audit-log/migrations/001_create_tables.sql
CREATE TABLE IF NOT EXISTS plugin_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organization(id),
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    details JSONB
);

CREATE INDEX idx_plugin_audit_log_org ON plugin_audit_log(org_id);
CREATE INDEX idx_plugin_audit_log_timestamp ON plugin_audit_log(timestamp);
```

### Project Structure

```
flovyn-server/
├── src/
│   ├── plugin/
│   │   ├── mod.rs           # Plugin trait, PluginServices
│   │   ├── registry.rs      # PluginRegistry
│   │   └── error.rs         # PluginError
│   ├── auth/                # Core auth (used by plugins)
│   └── main.rs
├── Cargo.toml               # Feature flags
│
plugins/                     # Plugin crates (separate workspace members)
├── audit-log/
│   ├── src/
│   │   ├── lib.rs           # AuditPlugin impl
│   │   └── handlers.rs      # REST handlers
│   ├── migrations/
│   │   └── 001_create_tables.sql
│   └── Cargo.toml
└── sso-provider/
    ├── src/
    │   ├── lib.rs           # SsoPlugin impl
    │   ├── authenticator.rs # Custom SAML/OIDC authenticator
    │   └── handlers.rs
    ├── migrations/
    └── Cargo.toml
```

## Concrete Example: Worker Token as a Plugin

This section demonstrates how to refactor the existing `worker_token` module into a plugin.

### Current Structure (Monolithic)

```
src/
├── auth/
│   ├── worker_token.rs              # WorkerTokenService
│   └── authenticator/
│       └── worker_token.rs          # WorkerTokenAuthenticator
├── repository/
│   └── worker_token_repository.rs   # WorkerTokenRepository
├── domain/
│   └── worker_token.rs              # WorkerToken, NewWorkerToken
└── main.rs                          # Wires everything together
```

In `main.rs`:
```rust
let worker_token_repo = WorkerTokenRepository::new(pool.clone());
let worker_token_service = Arc::new(WorkerTokenService::new(
    worker_token_repo,
    secret_key,
));

AuthStackBuilder::new(config)
    .with_worker_token_service(worker_token_service)
    .build()
```

### Target Structure (Plugin)

```
flovyn-server/
├── src/
│   ├── plugin/
│   │   ├── mod.rs                   # Plugin trait, PluginServices, PluginRegistry
│   │   └── hooks.rs                 # AuthenticatorProvider, AuthorizerProvider traits
│   ├── auth/
│   │   └── core/                    # Core traits only (Authenticator, Authorizer)
│   └── main.rs                      # Uses PluginRegistry
├── Cargo.toml
│
plugins/
└── worker-token/                    # NEW: Plugin crate
    ├── src/
    │   ├── lib.rs                   # WorkerTokenPlugin
    │   ├── service.rs               # WorkerTokenService (moved from core)
    │   ├── authenticator.rs         # WorkerTokenAuthenticator (moved)
    │   └── repository.rs            # WorkerTokenRepository (moved)
    ├── migrations/
    │   └── 001_worker_token.sql     # Table creation (moved from core migrations)
    └── Cargo.toml
```

### Step 1: Define Plugin Hooks in Core

```rust
// src/plugin/hooks.rs

use crate::auth::{Authenticator, Authorizer};

/// Hook for plugins to provide custom authenticators.
/// Called during AuthStackBuilder construction.
pub trait AuthenticatorProvider: Send + Sync {
    /// Return authenticators to add to the composite.
    /// Called with plugin services for dependency access.
    fn authenticators(&self, services: &PluginServices) -> Vec<Arc<dyn Authenticator>>;
}

/// Hook for plugins to provide custom authorizers.
pub trait AuthorizerProvider: Send + Sync {
    fn authorizers(&self, services: &PluginServices) -> Vec<Arc<dyn Authorizer>>;
}
```

### Step 2: Extend Plugin Trait

```rust
// src/plugin/mod.rs

#[async_trait]
pub trait Plugin: Send + Sync + 'static {
    fn name(&self) -> &'static str;
    fn version(&self) -> &'static str;

    /// Database migrations
    fn migrations(&self) -> Vec<Migration> { vec![] }

    /// REST routes
    fn rest_routes(&self, services: Arc<PluginServices>) -> Router { Router::new() }

    /// Authenticator provider (NEW)
    fn authenticator_provider(&self) -> Option<Arc<dyn AuthenticatorProvider>> { None }

    /// Authorizer provider (NEW)
    fn authorizer_provider(&self) -> Option<Arc<dyn AuthorizerProvider>> { None }

    async fn on_startup(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        Ok(())
    }
}
```

### Step 3: Create Worker Token Plugin

```rust
// plugins/worker-token/src/lib.rs

use flovyn_core::plugin::{Plugin, PluginServices, AuthenticatorProvider};
use flovyn_core::auth::Authenticator;

mod service;
mod authenticator;
mod repository;

pub use service::WorkerTokenService;
pub use authenticator::WorkerTokenAuthenticator;
pub use repository::WorkerTokenRepository;

pub struct WorkerTokenPlugin {
    secret_key: Vec<u8>,
}

impl WorkerTokenPlugin {
    pub fn new(secret_key: Vec<u8>) -> Self {
        Self { secret_key }
    }
}

#[async_trait]
impl Plugin for WorkerTokenPlugin {
    fn name(&self) -> &'static str { "worker-token" }
    fn version(&self) -> &'static str { "1.0.0" }

    fn migrations(&self) -> Vec<Migration> {
        vec![
            Migration::new(1, "create_worker_token", include_str!("../migrations/001_worker_token.sql")),
        ]
    }

    fn authenticator_provider(&self) -> Option<Arc<dyn AuthenticatorProvider>> {
        Some(Arc::new(WorkerTokenAuthProvider {
            secret_key: self.secret_key.clone(),
        }))
    }

    fn rest_routes(&self, services: Arc<PluginServices>) -> Router {
        // Admin routes for managing tokens
        Router::new()
            .route("/api/v1/worker-tokens", post(create_token))
            .route("/api/v1/worker-tokens", get(list_tokens))
            .route("/api/v1/worker-tokens/:id", delete(revoke_token))
            .with_state(WorkerTokenState::new(services, self.secret_key.clone()))
    }
}

struct WorkerTokenAuthProvider {
    secret_key: Vec<u8>,
}

impl AuthenticatorProvider for WorkerTokenAuthProvider {
    fn authenticators(&self, services: &PluginServices) -> Vec<Arc<dyn Authenticator>> {
        let repo = WorkerTokenRepository::new(services.db_pool.clone());
        let service = Arc::new(WorkerTokenService::new(repo, self.secret_key.clone()));
        vec![Arc::new(WorkerTokenAuthenticator::new(service))]
    }
}
```

### Step 4: Plugin Registration in Core

```rust
// src/main.rs

fn main() {
    // ...

    let mut registry = PluginRegistry::new();

    // Register worker-token plugin (via feature flag)
    #[cfg(feature = "plugin-worker-token")]
    {
        let secret = std::env::var("WORKER_TOKEN_SECRET")
            .expect("WORKER_TOKEN_SECRET required");
        registry.register(Arc::new(
            flovyn_plugin_worker_token::WorkerTokenPlugin::new(secret.into_bytes())
        ));
    }

    // Run plugin migrations
    registry.run_migrations(&pool).await?;

    // Build plugin services
    let plugin_services = Arc::new(PluginServices {
        db_pool: pool.clone(),
        authenticator: base_authenticator.clone(),  // Core authenticator
        authorizer: base_authorizer.clone(),
    });

    // Collect authenticators from plugins
    let plugin_authenticators = registry.collect_authenticators(&plugin_services);

    // Build composite authenticator (core + plugins)
    let authenticator = Arc::new(CompositeAuthenticator::new(
        std::iter::once(base_authenticator)
            .chain(plugin_authenticators)
            .collect()
    ));

    // Merge plugin routes
    let plugin_routes = registry.build_router(plugin_services);
    let app = Router::new()
        .merge(core_routes)
        .merge(plugin_routes);
}
```

### Step 5: Cargo Configuration

```toml
# Cargo.toml (root)
[features]
default = ["plugin-worker-token"]
plugin-worker-token = ["flovyn-plugin-worker-token"]

[dependencies]
flovyn-plugin-worker-token = { path = "plugins/worker-token", optional = true }

# plugins/worker-token/Cargo.toml
[package]
name = "flovyn-plugin-worker-token"
version = "1.0.0"

[dependencies]
flovyn-core = { path = "../../src" }  # Or use workspace
async-trait = "0.1"
sqlx = { version = "0.8", features = ["postgres", "runtime-tokio"] }
```

### Migration File (Moved to Plugin)

```sql
-- plugins/worker-token/migrations/001_worker_token.sql
CREATE TABLE IF NOT EXISTS worker_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organization(id),
    token_prefix VARCHAR(20) NOT NULL UNIQUE,
    token_hash VARCHAR(64) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(255),
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

CREATE INDEX idx_worker_token_org ON worker_token(org_id);
CREATE INDEX idx_worker_token_prefix ON worker_token(token_prefix);
```

### What Changes

| Aspect | Before (Monolithic) | After (Plugin) |
|--------|---------------------|----------------|
| Code location | `flovyn-server/src/auth/worker_token.rs` | `plugins/worker-token/src/` |
| Migrations | `flovyn-server/migrations/00X_worker_token.sql` | `plugins/worker-token/migrations/` |
| Dependency | Always compiled | Optional via feature flag |
| Configuration | Hardcoded in `main.rs` | Plugin self-configures |
| Auth integration | Builder pattern in core | `AuthenticatorProvider` hook |

### Benefits

1. **Separation of concerns** - Worker token is self-contained
2. **Optional feature** - Disable with `--no-default-features`
3. **Independent testing** - Plugin has its own test suite
4. **Clear boundaries** - Plugin depends on core, not vice versa
5. **Extensibility pattern** - Same pattern for future plugins (SSO, LDAP, API keys)

### Plugin Using Core Auth Services

If the worker-token plugin needed to use core auth (e.g., verify the caller is admin before creating tokens):

```rust
// plugins/worker-token/src/handlers.rs

async fn create_token(
    State(state): State<WorkerTokenState>,
    headers: HeaderMap,
    Json(req): Json<CreateTokenRequest>,
) -> Result<Json<TokenResponse>, ApiError> {
    // Use core authenticator from PluginServices
    let identity = state.services.authenticator
        .authenticate(&headers.into())
        .await
        .map_err(|_| ApiError::Unauthorized)?;

    // Check authorization using core authorizer
    let decision = state.services.authorizer
        .authorize(&identity, &AuthzContext::new("worker_token", "create"))
        .await?;

    if !decision.is_allowed() {
        return Err(ApiError::Forbidden);
    }

    // Create token using plugin's own service
    let token = state.token_service.create_token(
        identity.org_id()?,
        req.display_name,
        Some(identity.principal_id.clone()),
    ).await?;

    Ok(Json(TokenResponse { token }))
}
```

## Open Questions

1. **Plugin dependencies** - Can plugins depend on other plugins? (Recommend: no, keep simple)
2. **Plugin configuration** - How do plugins receive config? (Via `PluginServices` or separate config?)
3. **Plugin isolation** - Should plugin routes be namespaced? (e.g., `/plugins/audit/...`)
4. **Migration ordering** - How to handle cross-plugin migration dependencies?
5. **Hot reload** - Is hot-reload of compile-time plugins needed? (Requires dynamic loading)

## Real-World Examples

### 1. Vector (Datadog) - Feature Flags for Sources/Sinks/Transforms

[Vector](https://vector.dev/) is a high-performance observability data pipeline written in Rust.

**Approach:** Compile-time feature flags

```toml
# Each source, sink, transform is a feature
[features]
default = ["sources-file", "sources-kafka", "sinks-elasticsearch", ...]
sources-file = ["dep:notify"]
sources-kafka = ["dep:rdkafka"]
sinks-elasticsearch = ["dep:elasticsearch"]
```

- Sources, transforms, and sinks are modular components
- Each can be enabled/disabled via feature flags
- `FEATURES="kafka,elasticsearch" make build` for custom builds
- CLI command lists available components for that build

**Why it works for them:**
- Known set of integrations (not third-party extensible)
- Performance critical - no runtime overhead
- Allows minimal builds for resource-constrained environments

**Relevance to Flovyn:** Very similar use case. Plugins are vetted and compiled in.

---

### 2. Bevy Game Engine - Plugin Trait

[Bevy](https://bevyengine.org/) is a data-driven game engine with a powerful plugin system.

**Approach:** Plugin trait + feature flags

```rust
pub trait Plugin: Send + Sync + 'static {
    fn build(&self, app: &mut App);
    fn name(&self) -> &str { ... }
    fn is_unique(&self) -> bool { true }
}

// Usage
App::new()
    .add_plugins(DefaultPlugins)
    .add_plugins(MyCustomPlugin)
    .run();
```

- `DefaultPlugins` bundles core functionality (rendering, input, etc.)
- `MinimalPlugins` for headless/server use
- Third-party plugins published as crates
- Feature flags control which default plugins are included

**Why it works for them:**
- Game engines need high modularity
- Third-party ecosystem (bevy plugins on crates.io)
- Compile-time composition is acceptable

**Relevance to Flovyn:** The `Plugin` trait pattern is directly applicable.

---

### 3. Tremor - Connectors with Dynamic Loading Research

[Tremor](https://www.tremor.rs/) is an event processing system for high-volume data.

**Approach:** Currently compile-time, researching dynamic loading

- Connectors (Kafka, HTTP, S3, etc.) are built-in
- [GSoC project](https://nullderef.com/blog/gsoc-proposal/) explored plugin PDK
- Concluded: Rust-to-Rust FFI is unstable, C ABI via `abi_stable` is the way

**Key learnings from their research:**
- Dynamic loading is complex but doable
- C ABI is required for stability
- `abi_stable` crate is the recommended approach
- Async support requires additional work

**Relevance to Flovyn:** If we need dynamic loading later, follow their research.

---

### 4. Quickwit/Tantivy - Tokenizer Plugin API

[Tantivy](https://github.com/quickwit-oss/tantivy) (search library used by Quickwit) has a plugin-like tokenizer API.

**Approach:** Trait-based extension points

```rust
// tantivy-tokenizer-api crate
pub trait Tokenizer: Send + Sync + Clone {
    fn token_stream(&self, text: &str) -> BoxTokenStream;
}
```

- Core defines the trait
- Third-party tokenizers implement it (Chinese, Japanese, etc.)
- Published as separate crates
- Composed at compile-time

**Relevance to Flovyn:** Good pattern for specific extension points (like custom Authenticators).

---

## Summary of Industry Patterns

| Project | Approach | Third-Party | Dynamic Load |
|---------|----------|-------------|--------------|
| Vector | Feature flags | No (curated) | No |
| Bevy | Plugin trait + features | Yes (crates.io) | No |
| Tremor | Compile-time (researching dynamic) | No | Researching |
| Tantivy | Trait extension points | Yes (crates.io) | No |
| Zellij | WASM plugins | Yes | Yes |

**Observation:** Most production Rust projects use compile-time plugins. Dynamic loading is rare due to ABI complexity.

## References

- [Plugins in Rust: Getting Started](https://nullderef.com/blog/plugin-start/)
- [Plugins in Rust: Dynamic Loading](https://nullderef.com/blog/plugin-dynload/)
- [Plugins in Rust: abi_stable](https://nullderef.com/blog/plugin-abi-stable/)
- [abi_stable crate](https://docs.rs/abi_stable/)
- [Zellij WASM Plugin System](https://zellij.dev/news/new-plugin-system/)
- [Extism - Universal Plugin System](https://extism.org/)
- [Vector Components](https://vector.dev/components/)
- [Bevy Plugins](https://bevyengine.org/learn/book/getting-started/plugins/)
- [Tremor Architecture](https://www.tremor.rs/docs/0.11/overview/)
- [Tremor Plugin PDK Proposal](https://nullderef.com/blog/gsoc-proposal/)
