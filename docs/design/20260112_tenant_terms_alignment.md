# Tenant/Space → Organization/Team Terminology Alignment

## Problem Statement

The Flovyn ecosystem currently uses inconsistent terminology across components:

| Component | Entity 1 | Entity 2 |
|-----------|----------|----------|
| flovyn-server | Tenant | Space |
| flovyn-app (BetterAuth) | Organization | Team |

This inconsistency creates confusion for developers and complicates onboarding. The terminology should be unified around `organization`/`team` to align with the authentication system (BetterAuth) that defines user identity.

## Goals

1. **Unify terminology** across all Flovyn repositories to use `organization`/`team`
2. **Zero database migration** - since we're in MVP stage, modify existing migrations directly
3. **All tests pass** - integration tests, e2e tests across all affected repositories
4. **Breaking change** - this is acceptable at MVP stage; no backward compatibility required

## Non-Goals

- Maintaining backward compatibility with old `tenant`/`space` terminology
- Supporting both terminologies simultaneously
- Database migration scripts for production data (no production data exists yet)

## Terminology Mapping

### Identifiers

| Current | New |
|---------|-----|
| `tenant_id` | `org_id` |
| `tenant_slug` | `org_slug` |
| `space_id` | `team_id` |

### Types/Structs

| Current | New |
|---------|-----|
| `Tenant` | `Organization` |
| `NewTenant` | `NewOrganization` |
| `TenantWithId` | `OrganizationWithId` |
| `TenantTier` | `OrganizationTier` |
| `TenantLookup` | `OrganizationLookup` |

### REST API Paths

| Current | New |
|---------|-----|
| `POST /api/tenants` | `POST /api/orgs` |
| `GET /api/tenants/{slug}` | `GET /api/orgs/{slug}` |
| `/api/tenants/:tenant_slug/*` | `/api/orgs/:org_slug/*` |

### Database

| Current Table/Column | New Table/Column |
|---------------------|------------------|
| `tenant` (table) | `organization` |
| `tenant.id` | `organization.id` |
| `tenant.slug` | `organization.slug` |
| `*.tenant_id` (FK column) | `*.org_id` |
| `*.space_id` | `*.team_id` |
| `idx_*_tenant_id` | `idx_*_org_id` |
| `idx_*_space` | `idx_*_team` |

### gRPC Proto Fields

| Current | New |
|---------|-----|
| `string tenant_id` | `string org_id` |
| `optional string space_id` | `optional string team_id` |

## Scope of Changes

### 1. flovyn-server (this repo)

**Domain Models** (`crates/core/src/domain/`):
- `tenant.rs` → rename to `organization.rs`
- Update all structs: `Tenant` → `Organization`, `TenantTier` → `OrganizationTier`, etc.
- Update `space_id` → `team_id` in: `workflow_definition.rs`, `task_definition.rs`, `worker.rs`, `discovery.rs`

**Traits** (`crates/core/src/`):
- `tenant.rs` → `organization.rs`: `TenantLookup` → `OrganizationLookup`

**REST API** (`server/src/api/rest/`):
- `tenants.rs` → `organizations.rs`
- Update all route definitions in `mod.rs`
- Update path extractors (`:tenant_slug` → `:org_slug`)
- Update OpenAPI tags and documentation

**gRPC** (`proto/flovyn.proto` and `server/src/api/grpc/`):
- Update all `tenant_id` fields to `org_id`
- Update all `space_id` fields to `team_id`
- Regenerate Rust code from proto

**Repository Layer** (`server/src/repository/`):
- `tenant_repository.rs` → `organization_repository.rs`
- Update all SQL queries with new column names
- Update all struct field bindings

**Database Migrations** (`server/migrations/`):
- `20251214220815_init.sql`: Rename `tenant` table to `organization`
- `20251226093042_workload_discovery.sql`: Rename `space_id` to `team_id`
- `20260101110000_fix_null_space_id_unique.sql`: Update constraint names
- All other migrations: Update `tenant_id` → `org_id`

**Plugins** (`plugins/`):
- Update any `tenant_id` references in plugin tables and code
- Worker-token plugin: update token claims

**Auth** (`server/src/auth/`):
- Update JWT claims if they contain `tenant_id`
- Update worker token validation

### 2. sdk-rust (`../sdk-rust`)

**Files affected** (~45 files):
- `flovyn-server/core/src/generated/flovyn.v1.rs` - regenerate from updated proto
- `flovyn-server/sdk/src/client/flovyn_client.rs` - API methods
- `flovyn-server/sdk/src/client/builder.rs` - builder pattern
- `flovyn-server/sdk/src/worker/*.rs` - worker implementations
- All test files using `tenant_id`
- All example apps

**Key changes**:
- `FlovynClient::tenant_id()` → `FlovynClient::org_id()`
- Builder method `tenant_id()` → `org_id()`
- WorkflowContext `tenant_id()` → `org_id()`

### 3. sdk-kotlin (`../sdk-kotlin`)

**Files affected** (~7 files):
- `flovyn-server/native/src/main/kotlin/.../flovyn_ffi.kt` - regenerate from FFI
- `flovyn-server/core/src/main/kotlin/.../FlovynClient.kt`
- `flovyn-server/core/src/main/kotlin/.../WorkflowContext.kt`
- Test files and harness

### 4. flovyn-app (`../flovyn-app`)

**API Client** (`packages/api/`):
- Regenerate API types from OpenAPI spec
- `flovynServerApiSchemas.ts` - auto-generated, will update

**Web App** (`apps/web/`):
- Page routes: `/[tenant]/...` → `/[org]/...` (if applicable)
- Hooks: update any `tenantSlug` parameters
- Components: update any tenant-related props/state

### 5. dev (`../dev`)

- Docker compose files
- Environment variables
- Test fixtures
- Documentation

## Implementation Approach

Since we're modifying migrations directly (no production data):

1. **Search and replace** with careful ordering:
   - First: Database column/table names in migrations
   - Second: Rust struct/field names
   - Third: Proto field names
   - Fourth: API paths and handlers
   - Fifth: SDK code
   - Sixth: App code

2. **Proto regeneration** after updating `flovyn.proto`

3. **Verify compilation** at each step

4. **Run all tests** to catch missed references

## Testing Strategy

### Per-Repository Verification

| Repository | Command | Expected |
|-----------|---------|----------|
| flovyn-server | `./bin/dev/test.sh` | All unit tests pass |
| flovyn-server | `cargo test --test integration_tests` | All integration tests pass |
| flovyn-server | `./bin/dev/run-e2e-tests.sh` | All E2E tests pass |
| sdk-rust | `cargo test` | All tests pass |
| sdk-kotlin | `./gradlew test` | All tests pass |
| flovyn-app | `pnpm test` | All tests pass |

### Manual Verification

- Start server and connect with SDK example app
- Verify OpenAPI spec exports correctly
- Verify gRPC reflection shows new field names

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Missed references cause runtime errors | Comprehensive grep/search before declaring complete |
| Proto changes break existing SDK builds | Coordinate changes across repos, update simultaneously |
| OpenAPI client generation issues | Regenerate and verify type compatibility |

## Decisions

1. **Naming convention**: Use full `Organization` for struct/type names, short `org` for REST API paths (e.g., `/api/orgs/:org_slug/...`)

2. **Variable naming**: Follow each language's convention
   - Rust/Python: `org_slug`, `org_id`, `team_id` (snake_case)
   - Kotlin/TypeScript: `orgSlug`, `orgId`, `teamId` (camelCase)
