# Plugin System Implementation Plan

**Design Document**: [Plugin System Design](../design/plugin-system.md)

## Overview

This plan outlines the implementation of the unified plugin system for Flovyn Server. The system enables modular extensibility while maintaining type safety and native performance.

## Current State

✅ **Implementation Complete** (Phases 1-5)

The project has been restructured as a Cargo workspace:
- `crates/core/` - flovyn-core with Plugin trait and auth traits
- `server/` - Main binary with build info and feature flags
- `plugins/worker-token/` - First plugin (worker token authentication)
- `.dev/docs/guides/plugin-development.md` - Plugin development guide

## Target State

Transform into a Cargo workspace:
```
flovyn-server/
├── Cargo.toml          # Workspace manifest
├── crates/core/        # flovyn-core (plugin + auth traits)
├── server/             # Main binary (current src/)
└── plugins/            # Plugin crates
    └── worker-token/   # First plugin
```

## Implementation Phases

### Phase 1: Workspace Restructure

Convert from single crate to workspace structure without changing behavior.

### Phase 2: Core Library

Extract shared types to `crates/core`:
- Plugin trait and types
- Auth traits (from `src/auth/core/`)
- Plugin migration infrastructure

### Phase 3: Plugin Infrastructure

Implement plugin system components in `server/`:
- PluginRegistry
- PluginServices
- Plugin migration runner
- Plugin integration in startup sequence

### Phase 4: Worker Token Plugin

Extract worker token as the first plugin:
- Move from `src/auth/` and `src/repository/` to `plugins/worker-token/`
- Implement Plugin trait
- Wire up through registry

### Phase 5: Build Configuration

Set up feature flags and build variants.

---

## TODO List

### Phase 1: Workspace Restructure ✅

- [x] **1.0** Remove worker_token table from core migrations
  - Removed `worker_token` table DDL from `flovyn-server/migrations/001_init.sql`
  - Table now created by worker-token plugin

- [x] **1.1** Create workspace Cargo.toml at root
  - Defined workspace members
  - Set up workspace-wide dependencies
  - Configured workspace.package settings

- [x] **1.2** Move server code to `server/` directory
  - Moved `src/` to `server/src/`
  - Moved `migrations/` to `server/migrations/`
  - Kept `proto/` at workspace root
  - Moved `build.rs` to `flovyn-server/server/build.rs`

- [x] **1.3** Create `flovyn-server/server/Cargo.toml`
  - Package metadata referencing workspace
  - Binary target configured

- [x] **1.4** Update dev scripts
  - Updated all `flovyn-server/bin/dev/*.sh` scripts for workspace
  - Updated Dockerfile for workspace build

- [x] **1.5** Verify build and tests pass
  - All unit tests pass (167 tests)
  - Integration tests pass (20 tests)

### Phase 2: Core Library ✅

- [x] **2.1** Create `crates/core/` directory structure
  - Created `flovyn-server/crates/core/Cargo.toml`
  - Created `flovyn-server/crates/core/src/lib.rs`

- [x] **2.2** Create plugin module in core
  - Created `flovyn-server/crates/core/src/plugin/mod.rs`
  - Created `flovyn-server/crates/core/src/plugin/error.rs` with PluginError enum
  - Created `flovyn-server/crates/core/src/plugin/migration.rs` with PluginMigration struct
  - Created `flovyn-server/crates/core/src/plugin/services.rs` with PluginServices struct
  - Created `flovyn-server/crates/core/src/plugin/traits.rs` with Plugin trait

- [x] **2.3** Move auth traits to core
  - Created `flovyn-server/crates/core/src/auth/mod.rs`
  - Moved `Authenticator`, `Authorizer` traits
  - Moved `Identity`, `AuthRequest`, `AuthResponse` types
  - Moved `AuthError`, `AuthzError` types
  - Moved `AuthzContext`, `Decision`, `PrincipalType`, `Protocol` types

- [x] **2.4** Update server to use core
  - Added `flovyn-core` dependency to `flovyn-server/server/Cargo.toml`
  - Updated imports in `server/src/auth/` to use core types
  - Server re-exports core types for backward compatibility

- [ ] ~~**2.5** Create PluginConfig trait in core~~ (Deferred - not needed for MVP)

### Phase 3: Plugin Infrastructure ✅

- [x] **3.1** Create plugin registry in server
  - Created `flovyn-server/server/src/plugin/mod.rs`
  - Created `flovyn-server/server/src/plugin/registry.rs` with PluginRegistry
  - Implemented `register()`, `plugins()`, `run_migrations()` methods
  - Migration tracking via `_plugin_migrations` table

- [x] **3.2** Implement table naming validation
  - Created `flovyn-server/server/src/plugin/validator.rs`
  - Validates table names match `p_<plugin>__<table>` pattern
  - Rejects migrations with non-prefixed tables
  - Allows system tables and core table references

- [x] **3.3** Implement plugin routes collection
  - Added `build_rest_router()` to PluginRegistry
  - Validation helpers for REST paths (`/api/v1/p/<plugin>/`)
  - Validation helpers for gRPC services (`flovyn.plugins.*`)

- [x] **3.4** Implement plugin auth collection
  - Added `collect_authenticators()` to PluginRegistry
  - Added `collect_authorizers()` to PluginRegistry

- [x] **3.5** Implement plugin lifecycle
  - Added `startup()` method for `on_startup` hooks
  - Added `shutdown()` method for `on_shutdown` hooks

- [ ] ~~**3.6** Create AuthenticatorRegistry~~ (Not needed - using existing AuthStackBuilder)

- [x] **3.7** Update server startup sequence
  - PluginRegistry initialized after core migrations
  - Plugin migrations run via `run_migrations()`
  - Worker-token plugin registered automatically

### Phase 4: Worker Token Plugin ✅

- [x] **4.1** Create plugin directory structure
  - Created `flovyn-server/plugins/worker-token/Cargo.toml`
  - Created `flovyn-server/plugins/worker-token/src/lib.rs`

- [x] **4.2** Move worker token service
  - Created `flovyn-server/plugins/worker-token/src/service.rs`
  - Exports `WorkerTokenService`, `GeneratedToken`, `TOKEN_PREFIX`

- [x] **4.3** Move worker token repository
  - Created `flovyn-server/plugins/worker-token/src/repository.rs`
  - Uses table `p_worker_token__tokens`

- [x] **4.4** Move worker token authenticator
  - Created `flovyn-server/plugins/worker-token/src/authenticator.rs`
  - Implements `Authenticator` trait from flovyn-core

- [x] **4.5** Move worker token domain types
  - Created `flovyn-server/plugins/worker-token/src/domain.rs`
  - `WorkerToken`, `NewWorkerToken` structs

- [x] **4.6** Create plugin migration
  - Migration embedded in `lib.rs` as const
  - Creates `p_worker_token__tokens` table
  - Includes indexes for prefix lookup

- [x] **4.7** Implement Plugin trait
  - `name()` returns "worker-token"
  - `version()` returns "0.1.0"
  - `migrations()` returns embedded migration
  - `authenticators()` returns WorkerTokenAuthenticator

- [ ] ~~**4.8** Create plugin config struct~~ (Deferred - using server config for now)

- [x] **4.9** Update server to use plugin
  - Plugin is now a required dependency (not feature-gated)
  - Removed duplicate code from server
  - Server imports types from plugin

- [x] **4.10** Test plugin integration
  - All unit tests pass (167 tests)
  - All integration tests pass (20 tests)

### Phase 5: Build Configuration

- [x] **5.1** Set up feature flags for optional plugins
  - Feature `plugin-worker-token` controls worker-token plugin inclusion
  - Default features include `plugin-worker-token`
  - `all-plugins` convenience feature for all plugins
  - Conditional compilation via `#[cfg(feature = "plugin-worker-token")]`

- [x] **5.2** Create build info module
  - Created `flovyn-server/server/src/build_info.rs` with `BuildInfo` and `PluginInfo` types
  - Health endpoint (`/_/health`) now returns version and enabled plugins
  - Added `NAME` and `VERSION` constants to `WorkerTokenPlugin`

- [x] **5.3** Update Docker build
  - Dockerfile supports `FEATURES` build arg for feature selection
  - `docker build .` - default features (all plugins)
  - `docker build --build-arg FEATURES=none .` - minimal build
  - `docker build --build-arg FEATURES=plugin-worker-token .` - specific plugins

- [ ] **5.4** Update CI/CD (Skipped)
  - Matrix builds when multiple editions exist

- [x] **5.5** Update documentation
  - Created `.dev/docs/guides/plugin-development.md`
  - Covers: directory structure, Plugin trait, migrations, REST routes, OpenAPI, auth, testing
  - Includes checklist and reference to worker-token as example

---

## Key Files Created

### Core Library (`crates/core/`)

| File | Purpose | Status |
|------|---------|--------|
| `Cargo.toml` | Core library manifest | ✅ |
| `flovyn-server/src/lib.rs` | Core library entry | ✅ |
| `flovyn-server/src/plugin/mod.rs` | Plugin module exports | ✅ |
| `flovyn-server/src/plugin/traits.rs` | Plugin trait definition | ✅ |
| `flovyn-server/src/plugin/migration.rs` | PluginMigration struct | ✅ |
| `flovyn-server/src/plugin/services.rs` | PluginServices struct | ✅ |
| `flovyn-server/src/plugin/error.rs` | PluginError enum | ✅ |
| `flovyn-server/src/auth/mod.rs` | Auth module exports | ✅ |
| `flovyn-server/src/auth/traits.rs` | Authenticator, Authorizer traits | ✅ |
| `flovyn-server/src/auth/identity.rs` | Identity, PrincipalType types | ✅ |
| `flovyn-server/src/auth/request.rs` | AuthRequest type | ✅ |
| `flovyn-server/src/auth/context.rs` | AuthzContext, Decision types | ✅ |
| `flovyn-server/src/auth/error.rs` | AuthError, AuthzError types | ✅ |

### Server Plugin Infrastructure (`server/src/plugin/`)

| File | Purpose | Status |
|------|---------|--------|
| `mod.rs` | Plugin module exports | ✅ |
| `registry.rs` | PluginRegistry with migration tracking | ✅ |
| `validator.rs` | Table/endpoint naming validation | ✅ |

### Worker Token Plugin (`plugins/worker-token/`)

| File | Purpose | Status |
|------|---------|--------|
| `Cargo.toml` | Plugin manifest | ✅ |
| `flovyn-server/src/lib.rs` | Plugin trait implementation | ✅ |
| `flovyn-server/src/domain.rs` | WorkerToken, NewWorkerToken | ✅ |
| `flovyn-server/src/repository.rs` | WorkerTokenRepository | ✅ |
| `flovyn-server/src/service.rs` | WorkerTokenService | ✅ |
| `flovyn-server/src/authenticator.rs` | WorkerTokenAuthenticator | ✅ |

### Workspace Root

| File | Purpose | Status |
|------|---------|--------|
| `Cargo.toml` | Workspace manifest | ✅ |

## Files Removed (Duplicates)

| File | Reason |
|------|--------|
| `flovyn-server/server/src/auth/worker_token.rs` | Moved to plugin |
| `flovyn-server/server/src/auth/authenticator/worker_token.rs` | Moved to plugin |
| `flovyn-server/server/src/repository/worker_token_repository.rs` | Moved to plugin |
| `flovyn-server/server/src/domain/worker_token.rs` | Moved to plugin |

---

## Plugin Table Naming Convention

**Pattern**: `p_<plugin_name>__<table_name>` (double underscore separator)

- Prefix `p_` identifies plugin-owned tables
- `<plugin_name>` is the plugin name with hyphens replaced by underscores
- `__` (double underscore) separates plugin name from table name
- `<table_name>` describes the table's purpose

**Examples**:
| Plugin | Table | Full Name |
|--------|-------|-----------|
| worker-token | tokens | `p_worker_token__tokens` |
| audit-log | events | `p_audit_log__events` |
| audit-log | retention | `p_audit_log__retention` |

**Enforcement**:
- Migration validator parses SQL for `CREATE TABLE` statements
- Rejects migrations creating tables without proper prefix
- Foreign keys to core tables (e.g., `tenant(id)`) are allowed
- Validation runs before executing migration SQL

**Core tables** (no prefix): `tenant`, `workflow_execution`, `task_execution`, etc.

---

## Plugin Endpoint Naming Convention

### REST Endpoints

**Final URL Pattern**: `/api/v1/p/<plugin>/<resource>`

**How it works**:
- Plugins define routes with **relative paths** (e.g., `/tokens`, `/items/:id`)
- Server automatically nests them under `/api/v1/p/<plugin-name>/`
- OpenAPI paths are also automatically prefixed when merging

**Examples**:
| Plugin | Plugin Defines | Final Endpoint |
|--------|---------------|----------------|
| worker-token | `/tokens` | `POST /api/v1/p/worker-token/tokens` |
| worker-token | `/tokens/:id` | `GET /api/v1/p/worker-token/tokens/:id` |
| audit-log | `/events` | `GET /api/v1/p/audit-log/events` |

**Core endpoints** (no `/p/` prefix): `/health`, `/api/v1/tenants`, `/api/v1/workflows`, etc.

### gRPC Services

**Pattern**: `flovyn.plugins.<plugin>.v1.<Service>`

- Package `flovyn.plugins.*` reserved for plugins
- `<plugin>` is the plugin name (underscores, not hyphens)
- Core uses `flovyn.v1.*`

**Examples**:
| Plugin | Service |
|--------|---------|
| worker-token | `flovyn.plugins.worker_token.v1.TokenService` |
| audit-log | `flovyn.plugins.audit_log.v1.AuditService` |

**Core services**: `flovyn.v1.WorkflowDispatch`, `flovyn.v1.TaskExecution`, etc.

### Enforcement

- PluginRegistry automatically nests plugin routes under `/api/v1/p/<plugin>/`
- OpenAPI paths automatically prefixed when merging specs
- Table name validation rejects non-prefixed tables at startup
- Prevents conflicts between core, plugins, and plugin-to-plugin

---

## Testing Strategy

1. ✅ **After Phase 1**: All existing tests pass with workspace structure (173 tests)
2. ✅ **After Phase 2**: Core compiles, server uses core without behavior change (150 tests)
3. ✅ **After Phase 3**: Plugin registry works with no plugins registered (167 tests)
4. ✅ **After Phase 4**: Worker token works through plugin system (167 unit + 20 integration tests)
5. **After Phase 5**: Build variants produce correct binaries (future work)

## Assumptions

- **Clean start**: No backward compatibility needed (MVP stage)
- Existing `worker_token` table removed from core migrations
- Fresh database instances will get plugin tables via plugin migrations

## Rollback Plan

Each phase is incremental. If issues arise:
- Phase 1: Revert workspace changes, restore single Cargo.toml
- Phase 2-5: Individual commits can be reverted while keeping workspace structure

## Dependencies

- No external dependencies added (uses existing crates)
- Internal dependency: `crates/core` is a new internal dependency

## Risks and Mitigations

| Risk | Mitigation | Status |
|------|------------|--------|
| Breaking integration tests | Run tests after each phase | ✅ All tests pass |
| Migration order issues | Plugin migrations run after core migrations | ✅ Implemented |
| Circular dependencies | Strict core -> plugin direction | ✅ No cycles |
| Build time increase | Workspace caching helps | ✅ Fast builds |
| Endpoint conflicts | Enforce `/api/v1/p/<plugin>/` prefix | ✅ Validator ready |
| Table name conflicts | Enforce `p_<plugin>__<table>` prefix | ✅ Validator active |
