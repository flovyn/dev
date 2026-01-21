# Bug Report: REST API Tests Return 404 Due to URL Pattern Mismatch

**Date**: 2025-12-31
**Status**: RESOLVED
**Severity**: High (blocks ~40+ integration tests)

## Summary

Most workflow/task REST integration tests fail with 404 errors because they use incorrect URL patterns that don't match the server's actual routes.

## Resolution

Fixed by updating:
1. `flovyn-server/crates/rest-client/src/types.rs` - Added `kind` field to `TriggerWorkflowRequest`
2. `flovyn-server/crates/rest-client/src/client.rs` - Updated client URLs from `/tasks` to `/task-executions` and `/workflows/{kind}/trigger` to `/workflow-executions`
3. `flovyn-server/server/tests/integration/workflows_tests.rs` - Fixed all URL patterns (23+ occurrences), added `kind` field to requests, and fixed SQL column names (`state`→`status`, `task_type`→`kind`)
4. `flovyn-server/server/tests/integration/standalone_tasks_tests.rs` - Fixed all URL patterns from `/tasks` to `/task-executions`
5. Both test files - Changed `reqwest::Client::new()` to `harness.http_client()` for authentication
6. `flovyn-server/server/src/repository/idempotency_key_repository.rs` - Fixed SQL column name from `state` to `status` in two queries (caused 500 errors on idempotency hits)

### Test Results After Fix
- **34/34** workflow tests pass
- **21/21** standalone task tests pass

## Affected Tests

- `test_rest_trigger_workflow_basic`
- `test_rest_create_task_basic`
- `test_rest_list_tasks_empty`
- And approximately 40+ more REST API tests

## Root Cause

### 1. Workflow Trigger URL Mismatch

**Tests use**:
```rust
let url = format!(
    "http://localhost:{}/api/orgs/{}/workflows/greeting/trigger",
    harness.http_port, harness.org_slug
);
// POST /api/orgs/{org_slug}/workflows/{kind}/trigger
```

**Server route** (in `server/src/api/rest/mod.rs:101-103`):
```rust
.route(
    "/api/orgs/:org_slug/workflow-executions",
    post(workflows::trigger_workflow).get(workflows::list_workflows),
)
// POST /api/orgs/:org_slug/workflow-executions
```

The `kind` should be in the **request body**, not the URL path.

### 2. REST Client Type Mismatch

**`crates/rest-client/src/types.rs:12-25`** - `TriggerWorkflowRequest`:
```rust
pub struct TriggerWorkflowRequest {
    pub input: serde_json::Value,
    pub queue: Option<String>,
    pub idempotency_key: Option<String>,
    pub idempotency_key_ttl: Option<String>,
    pub version: Option<String>,
    // MISSING: kind field!
}
```

**Server `TriggerWorkflowRequest`** (`server/src/api/rest/workflows.rs:39-71`):
```rust
pub struct TriggerWorkflowRequest {
    pub kind: String,  // Required field
    pub input: serde_json::Value,
    pub queue: String,
    pub priority_seconds: i32,
    pub version: Option<String>,
    pub idempotency_key: Option<String>,
    pub idempotency_key_ttl: String,
    pub labels: HashMap<String, String>,
}
```

The REST client type is missing the `kind` field that the server handler requires.

## Correct API Usage

### Trigger Workflow
```
POST /api/orgs/{org_slug}/workflow-executions
Content-Type: application/json

{
    "kind": "greeting",
    "input": {"name": "World"},
    "queue": "default"
}
```

### List Workflows
```
GET /api/orgs/{org_slug}/workflow-executions?kind=greeting&status=PENDING
```

## Fix Options

### Option A: Fix Tests (Recommended)
Update all tests to use the correct URL patterns and request bodies:

```rust
// Before:
let url = format!(
    "http://localhost:{}/api/orgs/{}/workflows/greeting/trigger",
    harness.http_port, harness.org_slug
);
let request = TriggerWorkflowRequest {
    input: serde_json::json!({"name": "World"}),
    queue: None,
    ...
};

// After:
let url = format!(
    "http://localhost:{}/api/orgs/{}/workflow-executions",
    harness.http_port, harness.org_slug
);
let request = serde_json::json!({
    "kind": "greeting",
    "input": {"name": "World"},
    "queue": "default"
});
```

### Option B: Add URL Alias Route
Add an additional route to support the legacy URL pattern (not recommended - creates API inconsistency).

## Files to Modify

1. `flovyn-server/crates/rest-client/src/types.rs` - Add `kind` field to `TriggerWorkflowRequest`
2. `flovyn-server/server/tests/integration/workflows_tests.rs` - Fix all URL patterns
3. `flovyn-server/server/tests/integration/standalone_tasks_tests.rs` - Likely same issue
4. `flovyn-server/server/tests/integration/streaming_tests.rs` - Check for similar issues

## Verification

After fix, run:
```bash
cargo test --test integration_tests -- --nocapture
```

All REST tests should pass.
