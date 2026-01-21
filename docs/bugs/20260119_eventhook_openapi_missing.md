# Bug: Eventhook Plugin OpenAPI Documentation Missing

**Date**: 2026-01-19
**Status**: FIXED
**Severity**: Medium - API documentation is incomplete
**Fixed Date**: 2026-01-19

## Summary

The Eventhook plugin's REST API endpoints are not appearing in the OpenAPI documentation served at `/api/docs`. This affects API discoverability and documentation for users of the plugin.

## Evidence

### 1. OpenAPI Export Shows No Eventhook Paths

```bash
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("eventhook")))'
```

**Result**: `[]` (empty array)

### 2. No Eventhook Tags in OpenAPI Spec

```bash
./target/debug/export-openapi | jq '.tags[].name'
```

**Result**: Lists 13 tags, none contain "Eventhook":
- Health, Organizations, Workflows, Tasks, Workers, Workflow Definitions, Task Definitions, Promises, Metadata Fields, Saved Queries, Streaming, FQL, Schedules

### 3. No Eventhook Schemas in Components

```bash
./target/debug/export-openapi | jq '.components.schemas | keys' | grep -i "source\|route\|event\|provider"
```

**Result**: Only matches unrelated schemas (WorkflowEventResponse, etc.)

### 4. Handlers Missing `#[utoipa::path]` Annotations

Searched for utoipa path annotations:

```bash
grep -r "#\[utoipa::path" plugins/eventhook/src/
```

**Result**: Only found in `openapi.rs` as a **comment** at line 67:
```
/// are applied directly to handlers using #[utoipa::path].
```

No actual `#[utoipa::path]` annotations exist on any handlers.

### 5. OpenAPI Struct Missing `paths(...)` Registration

File: `flovyn-server/plugins/eventhook/src/api/openapi.rs` (lines 68-134)

```rust
#[derive(OpenApi)]
#[openapi(
    components(
        schemas(
            // All DTOs listed here...
        )
    ),
    tags(
        (name = "Eventhook Sources", description = "Webhook source management"),
        // other tags...
    )
)]
pub struct EventhookApiDoc;
```

**Missing**: `paths(...)` section to register handler functions.

### 6. Source Code Confirms Work Not Complete

File: `flovyn-server/plugins/eventhook/src/api/openapi.rs` (line 4)

```rust
//! Path annotations will be added to handlers in a follow-up.
```

This explicitly states the work was deferred.

## Root Cause Analysis

There are **two separate issues**:

### Issue A: Eventhook Handlers Missing OpenAPI Annotations

The eventhook plugin handlers in `plugins/eventhook/src/api/handlers/` lack:
1. `#[utoipa::path]` proc macro annotations on handler functions
2. Registration in the `EventhookApiDoc` struct's `paths(...)` section

**Affected handlers (16 total)**:

| File | Handler Functions |
|------|-------------------|
| `sources.rs` | `list_sources`, `create_source`, `get_source`, `update_source`, `delete_source`, `test_source` |
| `routes.rs` | `list_routes`, `create_route`, `get_route`, `update_route`, `delete_route`, `reorder_routes` |
| `events.rs` | `list_events`, `get_event`, `get_event_payload`, `reprocess_events` |
| `providers.rs` | `list_providers` |

### Issue B: export_openapi Binary Doesn't Merge Plugin Specs [FIXED]

**Status**: Fixed on 2026-01-19

**Fix Applied**:
1. Added `create_default_registry()` function in `flovyn-server/server/src/plugin/registry.rs`
2. Made `plugin` module public in `flovyn-server/server/src/lib.rs`
3. Updated `flovyn-server/server/src/bin/export_openapi.rs` to use merged OpenAPI spec

**Verification**:
```bash
./target/debug/export-openapi | jq '.tags[].name'
# Now includes: "WorkerToken", "Eventhook Sources", "Eventhook Routes", etc.

./target/debug/export-openapi | jq '.paths | keys | map(select(contains("worker-token")))'
# Returns: ["/api/orgs/{org_slug}/worker-token/tokens"]
```

Worker-token paths now appear because it has proper `#[utoipa::path]` annotations. Eventhook tags appear but paths are empty (Issue A remains).

## Comparison: Working Plugin (worker-token)

The worker-token plugin correctly implements OpenAPI:

File: `flovyn-server/plugins/worker-token/src/api.rs`

```rust
#[derive(OpenApi)]
#[openapi(
    paths(create_token),  // <-- Handler registered
    components(schemas(...)),
    tags(...)
)]
pub struct WorkerTokenApiDoc;

#[utoipa::path(  // <-- Annotation present
    post,
    path = "/tokens",
    request_body = CreateWorkerTokenRequest,
    responses(...)
)]
pub async fn create_token(...) { ... }
```

## Expected API Paths (After Fix)

Based on route definitions in `flovyn-server/plugins/eventhook/src/api/mod.rs`, the following paths should be documented:

```
POST   /api/orgs/{org_slug}/eventhook/sources
GET    /api/orgs/{org_slug}/eventhook/sources
GET    /api/orgs/{org_slug}/eventhook/sources/{source_slug}
PATCH  /api/orgs/{org_slug}/eventhook/sources/{source_slug}
DELETE /api/orgs/{org_slug}/eventhook/sources/{source_slug}
POST   /api/orgs/{org_slug}/eventhook/sources/{source_slug}/test

POST   /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes
GET    /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes
GET    /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/{route_slug}
PATCH  /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/{route_slug}
DELETE /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/{route_slug}
POST   /api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/reorder

GET    /api/orgs/{org_slug}/eventhook/events
GET    /api/orgs/{org_slug}/eventhook/events/{event_id}
GET    /api/orgs/{org_slug}/eventhook/events/{event_id}/payload
POST   /api/orgs/{org_slug}/eventhook/events/reprocess

GET    /api/orgs/{org_slug}/eventhook/providers
```

## Fix Required

### Fix A: Add OpenAPI Annotations to Eventhook Handlers [DONE]

For each handler function:

1. Add `#[utoipa::path]` annotation with:
   - HTTP method
   - Path (relative, e.g., `/sources`)
   - Parameters (path params, query params)
   - Request body (where applicable)
   - Responses
   - Tag

2. Register handler in `EventhookApiDoc`:
   ```rust
   #[openapi(
       paths(
           list_sources, create_source, get_source, update_source, delete_source, test_source,
           list_routes, create_route, get_route, update_route, delete_route, reorder_routes,
           list_events, get_event, get_event_payload, reprocess_events,
           list_providers,
       ),
       // ... existing components and tags
   )]
   ```

### Fix B: Update export_openapi Binary [DONE]

Fixed by updating `export_openapi.rs` to use `create_default_registry()` and merge plugin specs.

## Verification

After fix, verify with:

```bash
# Check paths appear
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("eventhook")))'

# Check tags appear
./target/debug/export-openapi | jq '.tags[] | select(.name | contains("Eventhook"))'

# Check schemas appear
./target/debug/export-openapi | jq '.components.schemas | keys | map(select(startswith("Source") or startswith("Route")))'
```

## Fix Verification (2026-01-19)

All fixes have been applied and verified:

### Paths Now Appearing
```bash
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("eventhook")))'
```
**Result**: 11 eventhook paths now documented:
- `/api/orgs/{org_slug}/eventhook/events`
- `/api/orgs/{org_slug}/eventhook/events/reprocess`
- `/api/orgs/{org_slug}/eventhook/events/{event_id}`
- `/api/orgs/{org_slug}/eventhook/events/{event_id}/payload`
- `/api/orgs/{org_slug}/eventhook/providers`
- `/api/orgs/{org_slug}/eventhook/sources`
- `/api/orgs/{org_slug}/eventhook/sources/{source_slug}`
- `/api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes`
- `/api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/reorder`
- `/api/orgs/{org_slug}/eventhook/sources/{source_slug}/routes/{route_id}`
- `/api/orgs/{org_slug}/eventhook/sources/{source_slug}/test`

### Tags Now Appearing
Tags include: "Eventhook Sources", "Eventhook Routes", "Eventhook Events", "Eventhook Providers"

### Schemas Now Appearing
All eventhook schemas are now in the OpenAPI spec components.

### Files Modified
- `flovyn-server/server/src/lib.rs` - Made plugin module public
- `flovyn-server/server/src/plugin/registry.rs` - Added `create_default_registry()` function
- `flovyn-server/server/src/plugin/mod.rs` - Exported `create_default_registry`
- `flovyn-server/server/src/bin/export_openapi.rs` - Updated to use merged OpenAPI spec
- `flovyn-server/plugins/eventhook/src/api/openapi.rs` - Added paths() registration
- `flovyn-server/plugins/eventhook/src/api/dto.rs` - Added IntoParams derive to query structs
- `flovyn-server/plugins/eventhook/src/api/handlers/sources.rs` - Added #[utoipa::path] annotations
- `flovyn-server/plugins/eventhook/src/api/handlers/routes.rs` - Added #[utoipa::path] annotations
- `flovyn-server/plugins/eventhook/src/api/handlers/events.rs` - Added #[utoipa::path] annotations
- `flovyn-server/plugins/eventhook/src/api/handlers/providers.rs` - Added #[utoipa::path] annotations

## References

- Plugin README: `flovyn-server/plugins/README.md` (section on OpenAPI)
- Working example: `flovyn-server/plugins/worker-token/src/api.rs`
- Server handlers example: `flovyn-server/server/src/api/rest/workers.rs` (lines 178-191)
- Utoipa rules: `.claude/rules/utoipa.md`
