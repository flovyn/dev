# Plugin System

## Overview

This document defines the **unified plugin system** for Flovyn Server. It supersedes and incorporates the authentication plugin concepts from [Pluggable Auth Design](./pluggable-auth.md).

The plugin system enables modular extensibility while maintaining type safety and native performance. Plugins can:

1. **Manage database schemas** - Own migrations for their tables
2. **Expose endpoints** - Add REST and gRPC routes
3. **Extend authentication** - Provide custom authenticators/authorizers
4. **Use core services** - Access database pool, config, and future core APIs

### Relationship to Pluggable Auth

The [Pluggable Auth Design](./pluggable-auth.md) defines:
- Core traits: `Authenticator`, `Authorizer`, `Identity`, `AuthRequest`
- Protocol adapters: HTTP and gRPC request conversion
- Composition: `CompositeAuthenticator`, `AuthStack`

**This plugin system unifies with that design:**
- Auth implementations (worker-token, SSO, LDAP) are **plugins**
- Core auth traits live in `crates/core`
- `AuthStackBuilder` uses `PluginRegistry` to collect authenticators
- Configuration follows the same pattern for all plugins

```
┌─────────────────────────────────────────────────────────────────┐
│                         Plugin System                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────────┐     ┌─────────────────────────────────┐   │
│   │  Auth Plugins   │     │  Other Plugins                  │   │
│   │  - worker-token │     │  - audit-log                    │   │
│   │  - sso          │     │  - webhooks                     │   │
│   │  - ldap         │     │  - custom-metrics               │   │
│   └────────┬────────┘     └────────────────┬────────────────┘   │
│            │                               │                     │
│            └───────────────┬───────────────┘                     │
│                            ▼                                     │
│                    ┌───────────────┐                             │
│                    │PluginRegistry │                             │
│                    └───────┬───────┘                             │
│                            │                                     │
│            ┌───────────────┼───────────────┐                     │
│            ▼               ▼               ▼                     │
│     Authenticators    REST Routes    Migrations                  │
│            │                                                     │
│            ▼                                                     │
│   ┌─────────────────────────────────────────┐                   │
│   │ AuthStackBuilder (from pluggable-auth)  │                   │
│   │ Composes: Core + Plugin Authenticators  │                   │
│   └─────────────────────────────────────────┘                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Goals

1. **Unified extensibility** - One plugin system for auth and everything else
2. **Type-safe** - Plugins use Rust traits, full compile-time checks
3. **Zero runtime overhead** - No dynamic dispatch beyond trait objects
4. **Self-contained plugins** - Each plugin owns its code, migrations, config, and tests
5. **Optional features** - Plugins enabled/disabled via Cargo feature flags
6. **Clear boundaries** - Plugins depend on core, never the reverse

## Non-Goals

1. **Runtime plugin loading** - No `.so`/`.dll` loading (can be added later if needed)
2. **WASM sandboxing** - Plugins are trusted code compiled together
3. **Third-party plugin marketplace** - Plugins are vetted and compiled in
4. **Hot reload** - Requires server restart to change plugins

---

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Flovyn Server                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         Plugin Registry                              │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │    │
│  │  │ Plugin A    │  │ Plugin B    │  │ Plugin C    │  ...             │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        PluginServices                                │    │
│  │  ┌──────────┐  ┌───────────────┐  ┌────────────┐  ┌──────────────┐  │    │
│  │  │ PgPool   │  │ Authenticator │  │ Authorizer │  │ Config       │  │    │
│  │  └──────────┘  └───────────────┘  └────────────┘  └──────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                              Core Services                                   │
│  ┌──────────┐  ┌────────────┐  ┌────────────┐  ┌─────────────────────┐      │
│  │ Auth     │  │ Repository │  │ Scheduler  │  │ WorkerNotifier      │      │
│  └──────────┘  └────────────┘  └────────────┘  └─────────────────────┘      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| `Plugin` trait | Interface that all plugins implement |
| `PluginRegistry` | Collects and manages registered plugins |
| `PluginServices` | Services provided by core to plugins |
| `PluginConfig` | Configuration passed to plugins |

---

## Core Types

### Plugin Trait

The central abstraction that all plugins implement:

```rust
// crates/core/src/plugin/mod.rs

use async_trait::async_trait;
use axum::Router;
use sqlx::PgPool;
use std::sync::Arc;

use crate::auth::{Authenticator, Authorizer};

/// Services provided by core to plugins.
pub struct PluginServices {
    /// Database connection pool.
    pub db_pool: PgPool,

    /// Tenant lookup service (resolve slugs to tenant info).
    pub tenant_lookup: Option<Arc<dyn TenantLookup>>,

    /// Workflow launcher (start workflows from plugins).
    pub workflow_launcher: Option<Arc<dyn WorkflowLauncher>>,

    /// Task launcher (start standalone tasks from plugins).
    pub task_launcher: Option<Arc<dyn TaskLauncher>>,

    /// Promise resolver (resolve/reject promises from plugins).
    pub promise_resolver: Option<Arc<dyn PromiseResolver>>,
}

/// Error type for plugin operations.
#[derive(Debug, thiserror::Error)]
pub enum PluginError {
    #[error("Migration failed: {0}")]
    Migration(String),

    #[error("Startup failed: {0}")]
    Startup(String),

    #[error("Database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Plugin interface.
///
/// Implement this trait to create a plugin. All methods have default
/// implementations, so plugins only need to override what they use.
#[async_trait]
pub trait Plugin: Send + Sync + 'static {
    /// Unique identifier for this plugin.
    /// Convention: lowercase with hyphens (e.g., "worker-token", "audit-log").
    fn name(&self) -> &'static str;

    /// Semantic version of this plugin.
    fn version(&self) -> &'static str;

    /// Database migrations owned by this plugin.
    ///
    /// Migrations run in order during server startup, after core migrations.
    /// Use table name prefix to avoid conflicts (e.g., `plugin_audit_`).
    fn migrations(&self) -> Vec<PluginMigration> {
        vec![]
    }

    /// REST routes to merge into the main Axum router.
    ///
    /// Routes are merged at the top level. Use path prefixes to namespace
    /// (e.g., `/api/v1/audit/...`).
    fn rest_routes(&self, services: Arc<PluginServices>) -> Router {
        Router::new()
    }

    /// gRPC services to register.
    ///
    /// Returns service descriptors that will be added to the gRPC server.
    fn grpc_services(&self, services: Arc<PluginServices>) -> Vec<GrpcServiceRegistration> {
        vec![]
    }

    /// Authenticators provided by this plugin.
    ///
    /// These are added to the composite authenticator and tried in order.
    fn authenticators(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authenticator>> {
        vec![]
    }

    /// Authorizers provided by this plugin.
    ///
    /// These are added to the composite authorizer.
    fn authorizers(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authorizer>> {
        vec![]
    }

    /// Called during server startup, after migrations but before serving.
    ///
    /// Use for initialization tasks like background job registration,
    /// cache warming, or validation.
    async fn on_startup(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        Ok(())
    }

    /// Called during graceful shutdown.
    ///
    /// Use for cleanup tasks like flushing buffers or closing connections.
    async fn on_shutdown(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        Ok(())
    }
}
```

### Plugin Migration

Represents a database migration owned by a plugin:

```rust
// crates/core/src/plugin/migration.rs

/// A database migration owned by a plugin.
pub struct PluginMigration {
    /// Unique version number within this plugin.
    /// Convention: timestamp-based (e.g., 20240101120000).
    pub version: i64,

    /// Short description of the migration.
    pub description: &'static str,

    /// SQL to apply the migration.
    pub up: &'static str,

    /// SQL to revert the migration (optional).
    pub down: Option<&'static str>,
}

impl PluginMigration {
    pub fn new(version: i64, description: &'static str, up: &'static str) -> Self {
        Self {
            version,
            description,
            up,
            down: None,
        }
    }

    pub fn with_down(mut self, down: &'static str) -> Self {
        self.down = Some(down);
        self
    }
}
```

### Plugin Registry

Manages plugin registration and lifecycle:

```rust
// server/src/plugin/registry.rs

use std::sync::Arc;
use tracing::{info, warn};

/// Registry of all loaded plugins.
pub struct PluginRegistry {
    plugins: Vec<Arc<dyn Plugin>>,
}

impl PluginRegistry {
    /// Create a new registry with compiled-in plugins.
    pub fn new() -> Self {
        let mut registry = Self { plugins: vec![] };

        // Register plugins based on feature flags
        #[cfg(feature = "plugin-worker-token")]
        registry.register(Arc::new(
            flovyn_plugin_worker_token::WorkerTokenPlugin::from_env()
        ));

        #[cfg(feature = "plugin-audit-log")]
        registry.register(Arc::new(
            flovyn_plugin_audit::AuditLogPlugin::new()
        ));

        registry
    }

    /// Register a plugin.
    pub fn register(&mut self, plugin: Arc<dyn Plugin>) {
        info!(
            plugin = plugin.name(),
            version = plugin.version(),
            "Registered plugin"
        );
        self.plugins.push(plugin);
    }

    /// Get all registered plugins.
    pub fn plugins(&self) -> &[Arc<dyn Plugin>] {
        &self.plugins
    }

    /// Run all plugin migrations.
    pub async fn run_migrations(&self, pool: &PgPool) -> Result<(), PluginError> {
        // Ensure plugin migration tracking table exists
        self.ensure_migration_table(pool).await?;

        for plugin in &self.plugins {
            for migration in plugin.migrations() {
                if self.migration_applied(pool, plugin.name(), migration.version).await? {
                    continue;
                }

                info!(
                    plugin = plugin.name(),
                    version = migration.version,
                    description = migration.description,
                    "Running plugin migration"
                );

                sqlx::query(migration.up)
                    .execute(pool)
                    .await
                    .map_err(|e| PluginError::Migration(e.to_string()))?;

                self.record_migration(pool, plugin.name(), migration.version).await?;
            }
        }

        Ok(())
    }

    /// Build merged REST router from all plugins.
    pub fn build_rest_router(&self, services: Arc<PluginServices>) -> Router {
        let mut router = Router::new();

        for plugin in &self.plugins {
            let plugin_routes = plugin.rest_routes(services.clone());
            router = router.merge(plugin_routes);
        }

        router
    }

    /// Collect all authenticators from plugins.
    pub fn collect_authenticators(
        &self,
        services: Arc<PluginServices>,
    ) -> Vec<Arc<dyn Authenticator>> {
        self.plugins
            .iter()
            .flat_map(|p| p.authenticators(services.clone()))
            .collect()
    }

    /// Collect all authorizers from plugins.
    pub fn collect_authorizers(
        &self,
        services: Arc<PluginServices>,
    ) -> Vec<Arc<dyn Authorizer>> {
        self.plugins
            .iter()
            .flat_map(|p| p.authorizers(services.clone()))
            .collect()
    }

    /// Run startup hooks for all plugins.
    pub async fn startup(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        for plugin in &self.plugins {
            info!(plugin = plugin.name(), "Starting plugin");
            plugin.on_startup(services.clone()).await?;
        }
        Ok(())
    }

    /// Run shutdown hooks for all plugins.
    pub async fn shutdown(&self, services: Arc<PluginServices>) -> Result<(), PluginError> {
        for plugin in &self.plugins {
            info!(plugin = plugin.name(), "Stopping plugin");
            if let Err(e) = plugin.on_shutdown(services.clone()).await {
                warn!(plugin = plugin.name(), error = %e, "Plugin shutdown error");
            }
        }
        Ok(())
    }

    async fn ensure_migration_table(&self, pool: &PgPool) -> Result<(), PluginError> {
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS _plugin_migrations (
                plugin_name TEXT NOT NULL,
                version BIGINT NOT NULL,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (plugin_name, version)
            )
            "#,
        )
        .execute(pool)
        .await?;
        Ok(())
    }

    async fn migration_applied(
        &self,
        pool: &PgPool,
        plugin: &str,
        version: i64,
    ) -> Result<bool, PluginError> {
        let result = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM _plugin_migrations WHERE plugin_name = $1 AND version = $2",
        )
        .bind(plugin)
        .bind(version)
        .fetch_one(pool)
        .await?;
        Ok(result > 0)
    }

    async fn record_migration(
        &self,
        pool: &PgPool,
        plugin: &str,
        version: i64,
    ) -> Result<(), PluginError> {
        sqlx::query("INSERT INTO _plugin_migrations (plugin_name, version) VALUES ($1, $2)")
            .bind(plugin)
            .bind(version)
            .execute(pool)
            .await?;
        Ok(())
    }
}
```

---

## Integration with Server

### Startup Sequence

```
1. Load configuration
2. Connect to database
3. Run core migrations
4. Create PluginRegistry (registers feature-flagged plugins)
5. Run plugin migrations
6. Build PluginServices
7. Collect plugin authenticators/authorizers → add to composite
8. Build REST router (core + plugin routes)
9. Build gRPC server (core + plugin services)
10. Call plugin on_startup hooks
11. Start serving
```

### Main Integration

```rust
// server/src/main.rs

#[tokio::main]
async fn main() -> Result<()> {
    // ... config, pool setup ...

    // Run core migrations
    sqlx::migrate!("./migrations").run(&pool).await?;

    // Initialize plugin registry
    let plugin_registry = PluginRegistry::new();

    // Run plugin migrations
    plugin_registry.run_migrations(&pool).await?;

    // Build base auth (core authenticators like JWT, session)
    let base_authenticator = build_base_authenticator(&config);
    let base_authorizer = build_base_authorizer(&config);

    // Create plugin services
    let plugin_services = Arc::new(PluginServices {
        db_pool: pool.clone(),
        authenticator: base_authenticator.clone(),
        authorizer: base_authorizer.clone(),
        config: config.clone(),
    });

    // Collect plugin auth components
    let plugin_authenticators = plugin_registry.collect_authenticators(plugin_services.clone());
    let plugin_authorizers = plugin_registry.collect_authorizers(plugin_services.clone());

    // Build composite authenticator (core + plugins)
    let authenticator: Arc<dyn Authenticator> = if plugin_authenticators.is_empty() {
        base_authenticator
    } else {
        Arc::new(CompositeAuthenticator::new(
            std::iter::once(base_authenticator)
                .chain(plugin_authenticators)
                .collect(),
        ))
    };

    // Build REST router
    let core_routes = build_core_routes(&pool, &config);
    let plugin_routes = plugin_registry.build_rest_router(plugin_services.clone());
    let app = Router::new()
        .merge(core_routes)
        .merge(plugin_routes)
        .layer(/* auth middleware */);

    // Run startup hooks
    plugin_registry.startup(plugin_services.clone()).await?;

    // Start servers
    let http_server = axum::Server::bind(&http_addr).serve(app);
    let grpc_server = /* ... */;

    // Graceful shutdown
    tokio::select! {
        _ = http_server => {},
        _ = grpc_server => {},
        _ = shutdown_signal() => {
            plugin_registry.shutdown(plugin_services).await?;
        }
    }

    Ok(())
}
```

---

## Project Structure

### Directory Layout

```
flovyn-server/
├── Cargo.toml                    # Workspace manifest (virtual)
├── Cargo.lock
│
├── crates/                       # Shared libraries
│   ├── core/                     # flovyn-core - shared types and traits
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── auth/             # Auth traits (Authenticator, Authorizer)
│   │       │   ├── mod.rs
│   │       │   └── traits.rs
│   │       ├── domain/           # Core domain models (Tenant, Workflow, Task, Worker, etc.)
│   │       │   ├── mod.rs
│   │       │   ├── tenant.rs
│   │       │   ├── workflow.rs
│   │       │   ├── task.rs
│   │       │   └── worker.rs
│   │       ├── launchers.rs      # Traits: WorkflowLauncher, TaskLauncher, PromiseResolver
│   │       └── tenant.rs         # TenantLookup trait
│   │
│   └── plugin/                   # flovyn-plugin - plugin system traits
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── traits.rs         # Plugin trait
│           ├── services.rs       # PluginServices struct
│           ├── migration.rs      # PluginMigration type
│           └── error.rs          # PluginError
│
├── server/                       # Main binary
│   ├── Cargo.toml
│   ├── build.rs
│   ├── migrations/               # Core database migrations
│   └── src/
│       ├── main.rs
│       ├── api/                  # REST and gRPC handlers
│       ├── repository/           # Database access
│       ├── scheduler.rs
│       └── ...
│
├── plugins/                      # Plugin crates
│   ├── worker-token/
│   │   ├── Cargo.toml
│   │   ├── migrations/
│   │   │   └── 20240101000000_create_worker_token.sql
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── service.rs
│   │       ├── authenticator.rs
│   │       ├── repository.rs
│   │       └── handlers.rs
│   └── audit-log/
│       ├── Cargo.toml
│       ├── migrations/
│       └── src/
│           └── lib.rs
│
├── proto/                        # Shared protobuf definitions
├── tests/                        # Workspace integration tests
├── bin/dev/                      # Development scripts
└── .dev/docs/                    # Documentation
```

### Dependency Graph

```
           ┌──────────────┐
           │  crates/core │
           └──────────────┘
                  ▲
           ┌──────┴──────┐
           │             │
    ┌──────────┐   ┌───────────┐
    │  server/ │◄──│ plugins/* │
    └──────────┘   └───────────┘
        (optional)
```

- `crates/core` - No internal dependencies, only external crates
- `plugins/*` - Depend only on `crates/core`
- `server/` - Depends on `crates/core`, optionally on `plugins/*`

### Cargo Configuration

```toml
# Cargo.toml (workspace root - virtual manifest)

[workspace]
resolver = "2"
members = [
    "crates/*",
    "server",
    "plugins/*",
]

[workspace.package]
edition = "2021"
rust-version = "1.82"
license = "MIT"
repository = "https://github.com/flovyn/flovyn-server"

[workspace.dependencies]
# Async runtime
tokio = { version = "1.42", features = ["full"] }
tokio-stream = { version = "0.1", features = ["sync"] }
async-trait = "0.1"

# Web framework
axum = { version = "0.7", features = ["macros"] }
tower = { version = "0.5", features = ["util"] }
tower-http = { version = "0.6", features = ["cors", "trace"] }

# gRPC
tonic = "0.12"
prost = "0.13"

# Database
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono", "json"] }

# Serialization
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# Utilities
uuid = { version = "1.11", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
thiserror = "2.0"
tracing = "0.1"

# Crypto
hmac = "0.12"
sha2 = "0.10"
base64 = "0.22"
hex = "0.4"
rand = "0.8"

# Internal crates (workspace references)
flovyn-core = { path = "crates/core" }
flovyn-plugin-worker-token = { path = "plugins/worker-token" }
flovyn-plugin-audit-log = { path = "plugins/audit-log" }
```

```toml
# crates/core/Cargo.toml

[package]
name = "flovyn-core"
version = "0.1.0"
edition.workspace = true
license.workspace = true

[dependencies]
async-trait.workspace = true
axum.workspace = true
sqlx.workspace = true
thiserror.workspace = true
tracing.workspace = true
uuid.workspace = true
serde.workspace = true
```

```toml
# server/Cargo.toml

[package]
name = "flovyn-server"
version = "0.1.0"
edition.workspace = true
license.workspace = true

[[bin]]
name = "flovyn-server"
path = "src/main.rs"

[features]
default = []

# Edition bundles
premium = [
    "plugin-worker-token",
    "plugin-audit-log",
]

# Individual plugins
plugin-worker-token = ["dep:flovyn-plugin-worker-token"]
plugin-audit-log = ["dep:flovyn-plugin-audit-log"]

[dependencies]
flovyn-core.workspace = true

# Core dependencies
tokio.workspace = true
axum.workspace = true
sqlx.workspace = true
tonic.workspace = true
prost.workspace = true
serde.workspace = true
serde_json.workspace = true
uuid.workspace = true
chrono.workspace = true
thiserror.workspace = true
tracing.workspace = true
# ... other server dependencies

# Optional plugins
flovyn-plugin-worker-token = { workspace = true, optional = true }
flovyn-plugin-audit-log = { workspace = true, optional = true }

[build-dependencies]
tonic-build = "0.12"
```

```toml
# plugins/worker-token/Cargo.toml

[package]
name = "flovyn-plugin-worker-token"
version = "1.0.0"
edition.workspace = true
license.workspace = true

[dependencies]
flovyn-core.workspace = true

async-trait.workspace = true
axum.workspace = true
sqlx.workspace = true
uuid.workspace = true
serde.workspace = true
thiserror.workspace = true
tracing.workspace = true

# Plugin-specific
hmac.workspace = true
sha2.workspace = true
base64.workspace = true
hex.workspace = true
rand.workspace = true
```

---

## Example Plugin: Worker Token

Complete example of refactoring the existing worker token into a plugin.

### Plugin Entry Point

```rust
// plugins/worker-token/src/lib.rs

use std::sync::Arc;
use async_trait::async_trait;
use axum::Router;

use flovyn_core::plugin::{Plugin, PluginError, PluginMigration, PluginServices};
use flovyn_core::auth::Authenticator;

mod authenticator;
mod handlers;
mod repository;
mod service;

pub use authenticator::WorkerTokenAuthenticator;
pub use repository::WorkerTokenRepository;
pub use service::WorkerTokenService;

/// Worker token authentication plugin.
///
/// Provides:
/// - HMAC-SHA256 based token generation and validation
/// - REST API for token management
/// - Authenticator for bearer token authentication
pub struct WorkerTokenPlugin {
    secret_key: Vec<u8>,
}

impl WorkerTokenPlugin {
    pub fn new(secret_key: Vec<u8>) -> Self {
        Self { secret_key }
    }

    /// Create from environment variable.
    pub fn from_env() -> Self {
        let secret = std::env::var("WORKER_TOKEN_SECRET")
            .expect("WORKER_TOKEN_SECRET environment variable required");
        Self::new(secret.into_bytes())
    }
}

#[async_trait]
impl Plugin for WorkerTokenPlugin {
    fn name(&self) -> &'static str {
        "worker-token"
    }

    fn version(&self) -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    fn migrations(&self) -> Vec<PluginMigration> {
        vec![PluginMigration::new(
            20240101000000,
            "create_worker_token_table",
            include_str!("../migrations/20240101000000_create_worker_token.sql"),
        )]
    }

    fn rest_routes(&self, services: Arc<PluginServices>) -> Router {
        handlers::routes(services, self.secret_key.clone())
    }

    fn authenticators(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authenticator>> {
        let repo = WorkerTokenRepository::new(services.db_pool.clone());
        let service = Arc::new(WorkerTokenService::new(repo, self.secret_key.clone()));
        vec![Arc::new(WorkerTokenAuthenticator::new(service))]
    }

    async fn on_startup(&self, _services: Arc<PluginServices>) -> Result<(), PluginError> {
        tracing::info!("Worker token plugin started");
        Ok(())
    }
}
```

### REST Handlers

```rust
// plugins/worker-token/src/handlers.rs

use std::sync::Arc;
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    routing::{delete, get, post},
    Json, Router,
};
use uuid::Uuid;

use flovyn_core::auth::{AuthRequest, ToAuthRequest};
use flovyn_core::plugin::PluginServices;

use crate::{WorkerTokenRepository, WorkerTokenService};

#[derive(Clone)]
pub struct WorkerTokenState {
    services: Arc<PluginServices>,
    token_service: Arc<WorkerTokenService>,
}

pub fn routes(services: Arc<PluginServices>, secret_key: Vec<u8>) -> Router {
    let repo = WorkerTokenRepository::new(services.db_pool.clone());
    let token_service = Arc::new(WorkerTokenService::new(repo, secret_key));

    let state = WorkerTokenState {
        services,
        token_service,
    };

    Router::new()
        .route("/api/v1/worker-tokens", post(create_token))
        .route("/api/v1/worker-tokens", get(list_tokens))
        .route("/api/v1/worker-tokens/:id", get(get_token))
        .route("/api/v1/worker-tokens/:id", delete(revoke_token))
        .with_state(state)
}

#[derive(serde::Deserialize)]
pub struct CreateTokenRequest {
    pub display_name: String,
    pub description: Option<String>,
}

#[derive(serde::Serialize)]
pub struct CreateTokenResponse {
    pub token: String,
    pub id: Uuid,
}

async fn create_token(
    State(state): State<WorkerTokenState>,
    headers: HeaderMap,
    Json(req): Json<CreateTokenRequest>,
) -> Result<Json<CreateTokenResponse>, ApiError> {
    // Authenticate caller using core authenticator
    let auth_request = headers.to_auth_request();
    let identity = state.services.authenticator
        .authenticate(&auth_request)
        .await
        .map_err(|_| ApiError::Unauthorized)?;

    // Get tenant from identity
    let tenant_id = identity.tenant_id()
        .ok_or(ApiError::Forbidden("No tenant context"))?;

    // Create token
    let (token, id) = state.token_service
        .create_token(tenant_id, req.display_name, Some(identity.principal_id))
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok(Json(CreateTokenResponse { token, id }))
}

// ... other handlers ...
```

### Migration

```sql
-- plugins/worker-token/migrations/20240101000000_create_worker_token.sql

CREATE TABLE worker_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    token_prefix VARCHAR(20) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(255),
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,

    CONSTRAINT uq_worker_token_prefix UNIQUE (token_prefix)
);

CREATE INDEX idx_worker_token_tenant ON worker_token(tenant_id);
CREATE INDEX idx_worker_token_prefix ON worker_token(token_prefix) WHERE revoked_at IS NULL;
```

---

## Configuration

### Design Principles

1. **Single source of truth** - One config file with env var overrides
2. **Flat plugin namespace** - All plugins under `[plugins.X]`
3. **Type-safe** - Each plugin defines its config struct
4. **Validated at startup** - Fail fast if config is invalid

### Config Structure

```rust
// crates/core/src/config.rs

#[derive(Debug, Deserialize)]
pub struct ServerConfig {
    pub server: ServerSettings,
    pub database: DatabaseSettings,
    pub plugins: PluginsConfig,
}

/// All plugin configurations in one place.
#[derive(Debug, Deserialize, Default)]
pub struct PluginsConfig {
    // Auth plugins
    #[serde(default)]
    pub worker_token: Option<WorkerTokenConfig>,

    #[serde(default)]
    pub sso: Option<SsoConfig>,

    // Other plugins
    #[serde(default)]
    pub audit: Option<AuditConfig>,
}
```

### Config File

```toml
# config.toml

[server]
http_port = 8000
grpc_port = 9090

[database]
url = "postgres://localhost/flovyn"

# All plugins configured under [plugins.*]
[plugins.worker_token]
enabled = true
secret = "${WORKER_TOKEN_SECRET}"
ttl = "30d"

[plugins.sso]
enabled = true
provider = "okta"
issuer_url = "https://company.okta.com"
client_id = "${SSO_CLIENT_ID}"
client_secret = "${SSO_CLIENT_SECRET}"

[plugins.audit]
enabled = true
retention_days = 90
```

### Plugin Config Trait

```rust
// crates/core/src/plugin/config.rs

use serde::de::DeserializeOwned;

/// Trait for plugin configuration types.
pub trait PluginConfig: DeserializeOwned + Default + Send + Sync + 'static {
    /// Whether this plugin is enabled.
    fn enabled(&self) -> bool;

    /// Validate the configuration.
    fn validate(&self) -> Result<(), ConfigError>;
}
```

### Example Plugin Config

```rust
// plugins/worker-token/src/config.rs

#[derive(Debug, Deserialize, Default)]
pub struct WorkerTokenConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,

    pub secret: Option<String>,

    #[serde(default = "default_ttl")]
    pub ttl: String,
}

impl PluginConfig for WorkerTokenConfig {
    fn enabled(&self) -> bool { self.enabled }

    fn validate(&self) -> Result<(), ConfigError> {
        if self.enabled && self.secret.is_none() {
            return Err(ConfigError::Missing("plugins.worker_token.secret"));
        }
        Ok(())
    }
}
```

### Environment Variables

```bash
# Override any config value
export FLOVYN__PLUGINS__WORKER_TOKEN__SECRET="my-secret"
export FLOVYN__PLUGINS__WORKER_TOKEN__ENABLED="true"
export FLOVYN__PLUGINS__SSO__ENABLED="false"
```

### Plugin Registration

```rust
// server/src/plugin/registry.rs

impl PluginRegistry {
    pub fn from_config(config: &ServerConfig) -> Result<Self, PluginError> {
        let mut registry = Self { plugins: vec![] };

        #[cfg(feature = "plugin-worker-token")]
        if let Some(ref cfg) = config.plugins.worker_token {
            if cfg.enabled() {
                cfg.validate()?;
                registry.register(Arc::new(WorkerTokenPlugin::new(cfg.clone())));
            }
        }

        #[cfg(feature = "plugin-sso")]
        if let Some(ref cfg) = config.plugins.sso {
            if cfg.enabled() {
                cfg.validate()?;
                registry.register(Arc::new(SsoPlugin::new(cfg.clone())));
            }
        }

        #[cfg(feature = "plugin-audit")]
        if let Some(ref cfg) = config.plugins.audit {
            if cfg.enabled() {
                cfg.validate()?;
                registry.register(Arc::new(AuditPlugin::new(cfg.clone())));
            }
        }

        Ok(registry)
    }
}

---

## Auth Integration

The plugin system unifies with authentication. Auth plugins provide authenticators/authorizers that are composed by the core.

### Auth Configuration

```toml
# config.toml

[auth]
enabled = true

# Default authenticators for gRPC (all services)
[auth.grpc]
authenticators = ["worker_token"]
authorizer = "tenant_scope"

# Path-specific overrides (first match wins)
[[auth.grpc.rules]]
paths = ["/flovyn.v1.Admin/*"]
authenticators = ["jwt"]
authorizer = "admin_only"

[[auth.grpc.rules]]
paths = ["/grpc.health.v1.Health/*"]
authenticators = []  # No auth (public)

# Default authenticators for HTTP
[auth.http]
authenticators = ["jwt", "session"]
authorizer = "tenant_scope"

[[auth.http.rules]]
paths = ["/health", "/metrics", "/api/v1/public/*"]
authenticators = []  # No auth

[[auth.http.rules]]
paths = ["/api/v1/admin/*"]
authenticators = ["jwt"]
authorizer = "admin_only"

# Core authenticator configs
[auth.jwt]
issuer = "https://auth.example.com"
audience = "flovyn"

[auth.session]
ttl = "24h"
cookie_name = "flovyn_session"

# Plugin configs
[plugins.worker_token]
enabled = true
secret = "${WORKER_TOKEN_SECRET}"
```

### Config Types

```rust
// crates/core/src/auth/config.rs

#[derive(Debug, Deserialize)]
pub struct AuthConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,

    #[serde(default)]
    pub grpc: EndpointAuthConfig,

    #[serde(default)]
    pub http: EndpointAuthConfig,

    // Core authenticator configs
    #[serde(default)]
    pub jwt: JwtConfig,

    #[serde(default)]
    pub session: SessionConfig,
}

#[derive(Debug, Deserialize, Default)]
pub struct EndpointAuthConfig {
    /// Default authenticators (by name)
    #[serde(default)]
    pub authenticators: Vec<String>,

    /// Default authorizer
    #[serde(default = "default_authorizer")]
    pub authorizer: String,

    /// Path-specific rules (first match wins)
    #[serde(default)]
    pub rules: Vec<AuthRule>,
}

#[derive(Debug, Deserialize)]
pub struct AuthRule {
    /// Path patterns (glob: * = one segment, ** = multiple)
    pub paths: Vec<String>,

    /// Authenticators for matching paths (empty = no auth)
    #[serde(default)]
    pub authenticators: Vec<String>,

    /// Authorizer override (uses default if not specified)
    pub authorizer: Option<String>,
}
```

### How It Works

1. **Plugins provide authenticators by name**:
   ```rust
   impl Plugin for WorkerTokenPlugin {
       fn name(&self) -> &'static str { "worker_token" }

       fn authenticators(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authenticator>> {
           vec![Arc::new(WorkerTokenAuthenticator::new(...))]
       }
   }
   ```

2. **Server collects all authenticators into a registry**:
   ```rust
   // server/src/auth/registry.rs

   pub struct AuthenticatorRegistry {
       authenticators: HashMap<String, Arc<dyn Authenticator>>,
   }

   impl AuthenticatorRegistry {
       pub fn new(config: &AuthConfig, plugins: &PluginRegistry) -> Self {
           let mut registry = Self::default();

           // Register core authenticators
           registry.register("jwt", Arc::new(JwtAuthenticator::new(&config.jwt)));
           registry.register("session", Arc::new(SessionAuthenticator::new(&config.session)));
           registry.register("noop", Arc::new(NoOpAuthenticator));

           // Register plugin authenticators
           for plugin in plugins.plugins() {
               for auth in plugin.authenticators(services.clone()) {
                   registry.register(plugin.name(), auth);
               }
           }

           registry
       }

       pub fn get(&self, name: &str) -> Option<Arc<dyn Authenticator>> {
           self.authenticators.get(name).cloned()
       }
   }
   ```

3. **Auth middleware resolves per request**:
   ```rust
   // server/src/auth/middleware.rs

   impl AuthStack {
       /// Get auth config for a specific path
       pub fn config_for_path(&self, path: &str) -> ResolvedAuth {
           // Check rules in order (first match wins)
           for rule in &self.config.rules {
               if rule.matches(path) {
                   return ResolvedAuth {
                       authenticators: &rule.authenticators,
                       authorizer: rule.authorizer.as_ref()
                           .unwrap_or(&self.config.authorizer),
                   };
               }
           }

           // Default
           ResolvedAuth {
               authenticators: &self.config.authenticators,
               authorizer: &self.config.authorizer,
           }
       }
   }

   impl<S, B> Service<Request<B>> for AuthMiddleware<S> {
       async fn call(&mut self, request: Request<B>) -> Response {
           let path = request.uri().path();
           let resolved = self.stack.config_for_path(path);

           // Empty authenticators = no auth required
           if resolved.authenticators.is_empty() {
               return self.inner.call(request).await;
           }

           // Build composite from resolved authenticator names
           let authenticator = self.registry.composite(resolved.authenticators);
           let identity = authenticator
               .authenticate(&request.to_auth_request())
               .await?;

           request.extensions_mut().insert(identity);
           self.inner.call(request).await
       }
   }
   ```

### Path Matching

```rust
impl AuthRule {
    pub fn matches(&self, path: &str) -> bool {
        self.paths.iter().any(|pattern| glob_match(pattern, path))
    }
}

fn glob_match(pattern: &str, path: &str) -> bool {
    // Simple glob matching:
    // - * matches one path segment
    // - ** matches zero or more segments
    // - Exact match otherwise

    // Examples:
    // "/api/v1/*" matches "/api/v1/users" but not "/api/v1/users/123"
    // "/api/v1/**" matches "/api/v1/users" and "/api/v1/users/123"
    // "/flovyn.v1.Admin/*" matches any method in Admin service
}
```

### Example Scenarios

**SDK Workers vs Admin Console:**
```toml
[auth.grpc]
authenticators = ["worker_token"]  # Default: workers

[[auth.grpc.rules]]
paths = ["/flovyn.v1.Admin/*"]
authenticators = ["jwt"]  # Admin uses JWT
```

**Public + Authenticated APIs:**
```toml
[auth.http]
authenticators = ["jwt", "session"]

[[auth.http.rules]]
paths = ["/api/v1/public/*", "/health"]
authenticators = []  # Public
```

**Multiple Auth Methods per Path:**
```toml
[[auth.grpc.rules]]
paths = ["/flovyn.v1.Workflow/*"]
authenticators = ["jwt", "worker_token", "service_account"]  # Any of these
```

---

## Building and Running

### Build Commands

```bash
# Build community edition (no plugins)
cargo build --release -p flovyn-server

# Build premium edition (all premium plugins)
cargo build --release -p flovyn-server --features premium

# Build with specific plugins
cargo build --release -p flovyn-server --features "plugin-worker-token"

# Build all workspace members
cargo build --release --workspace
```

### Build Variants / Editions

The server supports multiple editions via feature flags:

| Edition | Command | Plugins Included |
|---------|---------|------------------|
| Community | `cargo build --release -p flovyn-server` | None |
| Premium | `cargo build --release -p flovyn-server --features premium` | worker-token, audit-log |
| Custom | `cargo build --release -p flovyn-server --features "plugin-X"` | Selected plugins |

### Docker Images

```dockerfile
# Dockerfile.community
FROM rust:1.82 AS builder
WORKDIR /build
COPY . .
RUN cargo build --release -p flovyn-server

FROM debian:bookworm-slim
COPY --from=builder /build/target/release/flovyn-server /usr/local/bin/
CMD ["flovyn-server"]
```

```dockerfile
# Dockerfile.premium
FROM rust:1.82 AS builder
WORKDIR /build
COPY . .
RUN cargo build --release -p flovyn-server --features premium

FROM debian:bookworm-slim
COPY --from=builder /build/target/release/flovyn-server /usr/local/bin/
CMD ["flovyn-server"]
```

### CI/CD Matrix

```yaml
# .github/workflows/release.yml
jobs:
  build:
    strategy:
      matrix:
        edition:
          - name: community
            features: ""
          - name: premium
            features: "--features premium"
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --release -p flovyn-server ${{ matrix.edition.features }}
      - run: mv target/release/flovyn-server flovyn-server-${{ matrix.edition.name }}
```

### Runtime Feature Detection

The server can report its build configuration:

```rust
// server/src/build_info.rs

pub struct BuildInfo {
    pub version: &'static str,
    pub edition: &'static str,
    pub plugins: &'static [&'static str],
}

pub const BUILD_INFO: BuildInfo = BuildInfo {
    version: env!("CARGO_PKG_VERSION"),
    edition: if cfg!(feature = "premium") { "premium" } else { "community" },
    plugins: &[
        #[cfg(feature = "plugin-worker-token")]
        "worker-token",
        #[cfg(feature = "plugin-audit-log")]
        "audit-log",
    ],
};
```

Exposed via health endpoint:

```json
GET /health
{
  "status": "healthy",
  "version": "0.1.0",
  "edition": "premium",
  "plugins": ["worker-token", "audit-log"]
}
```

### Runtime Configuration

Plugins configure themselves via environment variables:

```bash
# Worker token plugin
export WORKER_TOKEN_SECRET="your-secret-key"

# Audit log plugin
export AUDIT_LOG_RETENTION_DAYS=90
```

---

## Migration Strategy

### From Monolithic to Plugins

To migrate existing functionality (like `worker_token`) to a plugin:

1. **Create plugin crate** - `plugins/worker-token/`
2. **Move code** - Service, repository, authenticator, handlers
3. **Move migration** - Copy SQL to plugin's migrations folder
4. **Implement Plugin trait** - Wire everything together
5. **Add feature flag** - Make it optional in Cargo.toml
6. **Update main.rs** - Remove direct usage, rely on registry
7. **Run migration script** - Mark existing migrations as applied for the plugin

### Migration Compatibility

For plugins extracted from core, ensure the plugin migration is marked as already applied if the table exists:

```sql
-- Run once during migration
INSERT INTO _plugin_migrations (plugin_name, version)
SELECT 'worker-token', 20240101000000
WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'worker_token')
ON CONFLICT DO NOTHING;
```

---

## Future Extensions

### Adding New Core Services

When adding new core services that plugins should access:

1. Add to `PluginServices` struct
2. Update `PluginRegistry::new()` to pass the service
3. Plugins can start using it in their next version

```rust
// Future: Add scheduler access
pub struct PluginServices {
    pub db_pool: PgPool,
    pub authenticator: Arc<dyn Authenticator>,
    pub authorizer: Arc<dyn Authorizer>,
    pub config: Arc<ServerConfig>,

    // New services over time
    pub scheduler: Arc<dyn Scheduler>,
    pub event_bus: Arc<dyn EventBus>,
}
```

### Plugin-to-Plugin Communication

If plugins need to communicate:

1. **Via database** - Shared tables with clear ownership
2. **Via events** - Core provides event bus, plugins subscribe
3. **Via services** - Register services in `PluginServices`

Recommend avoiding direct plugin dependencies to keep the graph simple.

---

## Testing

### Plugin Unit Tests

Each plugin has its own test suite:

```rust
// plugins/worker-token/src/lib.rs

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_token_generation() {
        let plugin = WorkerTokenPlugin::new(b"test-secret".to_vec());
        assert_eq!(plugin.name(), "worker-token");
    }
}
```

### Integration Tests

Test plugin integration with core:

```rust
// tests/plugin_integration.rs

#[tokio::test]
async fn test_plugin_authentication() {
    let pool = setup_test_db().await;
    let registry = PluginRegistry::new();

    registry.run_migrations(&pool).await.unwrap();

    let services = Arc::new(PluginServices { /* ... */ });
    let authenticators = registry.collect_authenticators(services);

    // Test that worker token authenticator is present
    assert!(!authenticators.is_empty());
}
```

---

## Summary: Unified System

This plugin system unifies with the [Pluggable Auth Design](./pluggable-auth.md). Here's what goes where:

### What Lives in `crates/core`

| Component | Description |
|-----------|-------------|
| `domain/*` | Core domain models (Tenant, Workflow, Task, Worker, etc.) |
| `Authenticator` trait | From pluggable-auth |
| `Authorizer` trait | From pluggable-auth |
| `Identity`, `AuthRequest` | From pluggable-auth |
| `WorkflowLauncher` trait | Start workflows from plugins |
| `TaskLauncher` trait | Start standalone tasks from plugins |
| `PromiseResolver` trait | Resolve/reject promises from plugins |
| `TenantLookup` trait | Resolve tenant slugs to tenant info |

### What Lives in `crates/plugin`

| Component | Description |
|-----------|-------------|
| `Plugin` trait | Interface all plugins implement |
| `PluginServices` | Services injected into plugins |
| `PluginMigration` | Migration type for plugin schemas |
| `PluginError` | Error type for plugin operations |

### What Lives in `server/`

| Component | Description |
|-----------|-------------|
| `PluginRegistry` | Manages plugin lifecycle |
| `AuthStackBuilder` | Builds auth stacks from config + plugins |
| `ServerConfig` | Full server configuration |
| Core authenticators | JWT, Session (always available) |

### What Lives in `plugins/*`

| Component | Description |
|-----------|-------------|
| Plugin struct | Implements `Plugin` trait |
| Config struct | Implements `PluginConfig` trait |
| Authenticator/Authorizer | If auth plugin |
| Handlers | REST/gRPC endpoints |
| Repository | Database access |
| Migrations | Plugin-owned schema |

### Configuration Layout

```toml
[server]                    # Server settings
[database]                  # Database settings
[auth]                      # Auth orchestration (which authenticators per endpoint)
[auth.jwt]                  # Core JWT config
[auth.session]              # Core session config
[plugins.worker_token]      # Plugin: worker-token
[plugins.sso]               # Plugin: sso
[plugins.audit]             # Plugin: audit-log
```

### Key Principles

1. **Core defines traits, plugins implement them**
2. **Plugins are optional** - feature flags control compilation
3. **Config is centralized** - `[plugins.*]` for all plugin config
4. **Auth plugins provide authenticators** - registered by name, resolved at startup
5. **Clear dependency direction** - plugins depend on core, never reverse

---

## References

- [Research: Plugin System](./../research/plugin-system.md) - Evaluation of approaches
- [Pluggable Auth Design](./pluggable-auth.md) - Core auth traits and patterns
- [Vector Components](https://vector.dev/components/) - Feature flag pattern
- [Bevy Plugins](https://bevyengine.org/) - Plugin trait pattern
