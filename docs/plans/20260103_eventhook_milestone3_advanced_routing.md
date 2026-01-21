# Eventhook Milestone 3: Advanced Routing Implementation Plan

**Date:** 2026-01-03
**Design Reference:** [M3 Design Document](../design/20260103_eventhook_milestone3_advanced_routing.md)
**Status:** Implemented (Core Features)

## Implementation Summary

**Completed:** 2026-01-03

Core M3 features implemented:
- ✅ Filter pattern matching (JSON field conditions with operators)
- ✅ JavaScript filter functions with timeout protection
- ✅ JMESPath transformations
- ✅ JavaScript transformations
- ✅ Multi-target routes
- ✅ API DTOs and handlers updated
- ✅ 69 unit tests passing

**Remaining:**
- Integration tests (Phase 13)
- Validation endpoint (optional - can be added later)

## Overview

This plan implements M3 Advanced Routing for the Eventhook plugin. M3 adds filter patterns, JavaScript filter/transform functions, JMESPath transforms, and multi-target routes to the existing M1/M2 foundation.

## Current State Analysis

**Existing Code Structure (from codebase exploration):**

| Component | File | Current State |
|-----------|------|---------------|
| Route Domain | `flovyn-server/plugins/eventhook/src/domain/route.rs` | `target: TargetConfig` (single), `condition: Option<String>` (unused TEXT column) |
| Processor | `flovyn-server/plugins/eventhook/src/service/processor.rs` | Glob matching on `event_type_filter` only, `match_event_type()` at line 365 |
| Repository | `flovyn-server/plugins/eventhook/src/repository/route_repository.rs` | Standard CRUD with JSON serialization for `target` |
| DTOs | `flovyn-server/plugins/eventhook/src/api/dto.rs` | `CreateRouteRequest` with single `target` field |
| Migration | `flovyn-server/plugins/eventhook/migrations/20260102000001_init.up.sql` | `target JSONB NOT NULL`, `condition TEXT` (unused) |

**Key Technical Details:**
- `rquickjs = "0.10"` is in workspace `Cargo.toml` but NOT used by eventhook plugin yet
- Existing JSON path extraction: `extract_idempotency_key()` in `processor.rs` (lines 385-408) uses simple dot-notation
- Route matching flow: `find_routes_for_source()` → `match_event_type()` → `execute_route()`

**To implement (M3):**
- Filter pattern matching (JSON field conditions)
- Filter function (JavaScript predicates)
- Input transform (JMESPath and JavaScript)
- Multi-target routes
- Validation endpoint

---

## Implementation Phases

### Phase 0: Dependencies Setup

**Rationale:** Set up dependencies first before any implementation.

#### 0.1 Update Cargo.toml

**File:** `flovyn-server/plugins/eventhook/Cargo.toml`

- [x] Add `jmespath = "0.4"` dependency
- [x] Add `rquickjs.workspace = true` to use workspace rquickjs (v0.10)
- [x] Verify with `cargo check -p flovyn-plugin-eventhook`

```toml
# Add to [dependencies]
jmespath = "0.3"
rquickjs.workspace = true
```

---

### Phase 1: Database Migration

**Rationale:** Schema changes first, but keep backward compatibility during transition.

#### 1.1 Create Migration

**File:** `flovyn-server/plugins/eventhook/migrations/20260103HHMMSS_advanced_routing.sql`

**Note:** Use actual timestamp when creating the file.

```sql
-- Add new columns (all nullable for backward compatibility)
ALTER TABLE p_eventhook__route
    ADD COLUMN filter_pattern JSONB,
    ADD COLUMN filter_function TEXT,
    ADD COLUMN input_transform JSONB,
    ADD COLUMN targets JSONB;

-- Migrate existing target to targets array
UPDATE p_eventhook__route
SET targets = jsonb_build_array(target)
WHERE target IS NOT NULL AND targets IS NULL;

-- Add NOT NULL constraint with default for new routes
ALTER TABLE p_eventhook__route
    ALTER COLUMN targets SET DEFAULT '[]'::jsonb;

-- Keep old 'target' column for backward compat during migration
-- (to be dropped in future migration after all code updated)

-- Drop unused 'condition' column (was TEXT, never used)
ALTER TABLE p_eventhook__route DROP COLUMN IF EXISTS condition;

-- Optional: index for routes with filters (for debugging/monitoring)
CREATE INDEX idx_route_has_advanced_filter
    ON p_eventhook__route(source_id)
    WHERE filter_pattern IS NOT NULL OR filter_function IS NOT NULL;
```

- [x] Create migration file with actual timestamp (`20260103133348_advanced_routing.up.sql`)
- [x] Run migration locally: `./dev.sh migrate`
- [x] Verify schema: `./bin/dev/db-schema.sh`

---

### Phase 2: Filter Pattern (Test-First)

**Rationale:** Filter pattern is purely Rust logic with no external dependencies beyond serde_json. Implement with test-first approach.

#### 2.1 Write Filter Pattern Tests First

**File:** `flovyn-server/plugins/eventhook/src/service/filter_pattern.rs`

Create test module before implementation:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_pattern_exact_match() {
        let pattern = FilterPattern::from_json(json!({
            "fields": { "status": "active" }
        })).unwrap();
        let payload = json!({"status": "active"});
        assert!(matches_pattern(&payload, &pattern));
    }
    // ... more tests
}
```

- [x] `test_pattern_exact_match` - exact value matching
- [x] `test_pattern_any_of` - match any of multiple values
- [x] `test_pattern_numeric_operators` - $gt, $gte, $lt, $lte, $eq, $ne
- [x] `test_pattern_string_operators` - $contains, $startsWith, $endsWith
- [x] `test_pattern_exists` - $exists true/false
- [x] `test_pattern_in_array` - $in operator
- [x] `test_pattern_nested_path` - e.g., "data.object.amount"
- [x] `test_pattern_array_index` - e.g., "items.0.sku"
- [x] `test_pattern_multiple_conditions` - all conditions AND together
- [x] `test_pattern_no_match` - verify returns false when no match

**Verify tests fail:** `cargo test -p flovyn-plugin-eventhook filter_pattern -- --nocapture`

#### 2.2 Implement Filter Pattern Types

**File:** `flovyn-server/plugins/eventhook/src/service/filter_pattern.rs`

```rust
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterPattern {
    pub fields: HashMap<String, FieldCondition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum FieldCondition {
    Exact(serde_json::Value),
    AnyOf(Vec<serde_json::Value>),
    Operator(OperatorCondition),
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct OperatorCondition {
    #[serde(rename = "$eq", skip_serializing_if = "Option::is_none")]
    pub eq: Option<serde_json::Value>,
    #[serde(rename = "$ne", skip_serializing_if = "Option::is_none")]
    pub ne: Option<serde_json::Value>,
    // ... all operators from design doc
}
```

- [x] Define `FilterPattern`, `FieldCondition`, `OperatorCondition` structs
- [x] Implement `extract_path()` - reuse logic from `extract_idempotency_key()` in processor.rs
- [x] Implement `matches_pattern()` - main entry point
- [x] Implement `matches_condition()` for each condition type
- [x] Implement `matches_operator()` for each operator

#### 2.3 Verify All Tests Pass

```bash
cargo test -p flovyn-plugin-eventhook filter_pattern -- --nocapture
```

- [x] All filter pattern tests pass
- [x] `cargo clippy -p flovyn-plugin-eventhook` - no warnings

---

### Phase 3: JavaScript Sandbox

**Rationale:** Shared infrastructure for both filter functions and JS transforms. Must have timeout protection.

#### 3.1 Write Sandbox Tests First

**File:** `flovyn-server/plugins/eventhook/src/service/script_sandbox.rs`

- [ ] `test_sandbox_simple_execution` - basic script runs
- [ ] `test_sandbox_timeout` - infinite loop times out (100ms)
- [ ] `test_sandbox_syntax_error` - returns appropriate error
- [ ] `test_sandbox_return_value` - can return JSON values

#### 3.2 Implement Script Sandbox

**File:** `flovyn-server/plugins/eventhook/src/service/script_sandbox.rs`

```rust
use rquickjs::{Context, Runtime};
use std::time::Duration;

pub const SCRIPT_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Debug, thiserror::Error)]
pub enum ScriptError {
    #[error("Script execution timed out after {0:?}")]
    Timeout(Duration),
    #[error("Syntax error: {0}")]
    SyntaxError(String),
    #[error("Runtime error: {0}")]
    RuntimeError(String),
    #[error("Missing required function: {0}")]
    MissingFunction(String),
}

pub fn execute_with_timeout<F, T>(timeout: Duration, f: F) -> Result<T, ScriptError>
where
    F: FnOnce() -> Result<T, ScriptError> + Send + 'static,
    T: Send + 'static,
{ ... }
```

- [ ] Define `ScriptError` enum
- [ ] Implement `execute_with_timeout()` using thread + channel
- [ ] All sandbox tests pass

---

### Phase 4: Filter Function (JS Predicates)

**Rationale:** Build on sandbox to implement filter functions.

#### 4.1 Write Filter Function Tests First

**File:** `flovyn-server/plugins/eventhook/src/service/filter_function.rs`

- [ ] `test_filter_returns_true` - filter matches
- [ ] `test_filter_returns_false` - filter doesn't match
- [ ] `test_filter_syntax_error` - caught at creation
- [ ] `test_filter_missing_function` - no `filter` function defined
- [ ] `test_filter_runtime_error` - throws during execution
- [ ] `test_filter_access_event` - can read headers, body, eventType

#### 4.2 Implement Filter Function Executor

**File:** `flovyn-server/plugins/eventhook/src/service/filter_function.rs`

```rust
pub struct FilterInput {
    pub headers: serde_json::Value,
    pub body: serde_json::Value,
    pub event_type: Option<String>,
}

pub struct FilterFunctionExecutor {
    script: String,
}

impl FilterFunctionExecutor {
    pub fn new(script: &str) -> Result<Self, ScriptError>;
    pub fn execute(&self, input: &FilterInput) -> Result<bool, ScriptError>;
}
```

- [ ] Define `FilterInput` struct
- [ ] Implement `FilterFunctionExecutor::new()` with validation
- [ ] Implement `FilterFunctionExecutor::execute()`
- [ ] All filter function tests pass

---

### Phase 5: Transform - JMESPath

**Rationale:** JMESPath is simpler than JS transforms, do first.

#### 5.1 Write JMESPath Tests First

**File:** `flovyn-server/plugins/eventhook/src/service/transform_jmespath.rs`

- [ ] `test_jmespath_extract_field` - extract single field
- [ ] `test_jmespath_restructure` - create new object structure
- [ ] `test_jmespath_array_projection` - `items[*].name`
- [ ] `test_jmespath_invalid_expression` - error on bad syntax

#### 5.2 Implement JMESPath Transformer

```rust
pub struct JmespathTransformer {
    expression: jmespath::Expression<'static>,
}

impl JmespathTransformer {
    pub fn new(expr: &str) -> Result<Self, TransformError>;
    pub fn transform(&self, input: &serde_json::Value) -> Result<serde_json::Value, TransformError>;
}
```

- [ ] Implement transformer
- [ ] All JMESPath tests pass

---

### Phase 6: Transform - JavaScript

**Rationale:** Build on sandbox for JS transforms.

#### 6.1 Write JS Transform Tests First

**File:** `flovyn-server/plugins/eventhook/src/service/transform_javascript.rs`

- [ ] `test_js_transform_simple` - basic restructuring
- [ ] `test_js_transform_missing_function` - no `transform` function
- [ ] `test_js_transform_runtime_error` - throws during execution
- [ ] `test_js_transform_timeout` - long transform times out

#### 6.2 Implement JavaScript Transformer

```rust
pub struct JavascriptTransformer {
    script: String,
}

impl JavascriptTransformer {
    pub fn new(script: &str) -> Result<Self, ScriptError>;
    pub fn transform(&self, input: &TransformInput) -> Result<serde_json::Value, ScriptError>;
}
```

- [ ] Implement transformer
- [ ] All JS transform tests pass

---

### Phase 7: Domain Model Updates

**Rationale:** Update domain after all implementations are tested.

#### 7.1 Input Transform Enum

**File:** `flovyn-server/plugins/eventhook/src/domain/transform.rs` (new file)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputTransform {
    Passthrough,
    Jmespath { expression: String },
    Javascript { function: String },
}
```

- [ ] Create `InputTransform` enum with serde tag

#### 7.2 WebhookRoute Changes

**File:** `flovyn-server/plugins/eventhook/src/domain/route.rs`

- [ ] Add `filter_pattern: Option<FilterPattern>`
- [ ] Add `filter_function: Option<String>`
- [ ] Add `input_transform: Option<InputTransform>`
- [ ] Add `targets: Vec<TargetConfig>` (keep old `target` field temporarily)
- [ ] Remove unused `condition` field

---

### Phase 8: Repository Updates

**Rationale:** Update persistence layer after domain model is ready.

#### 8.1 Route Repository Changes

**File:** `flovyn-server/plugins/eventhook/src/repository/route_repository.rs`

- [ ] Update `create()` to write new fields (filter_pattern, filter_function, input_transform, targets)
- [ ] Update `find_by_id()` to read new fields
- [ ] Update `find_by_source()` to read new fields
- [ ] Update `update()` to handle new fields
- [ ] Update `list_all_by_source()` to read new fields
- [ ] Handle JSON serialization/deserialization for JSONB fields
- [ ] Maintain backward compat: if `targets` is empty, read from `target`

**Verify:** `cargo test -p flovyn-plugin-eventhook repository -- --nocapture`

---

### Phase 9: Processor Integration

**Rationale:** Wire up all components in the event processor.

#### 9.1 Update Processor Pipeline

**File:** `flovyn-server/plugins/eventhook/src/service/processor.rs`

Update `find_matching_routes()` (around line 154):

```rust
// Current: only event_type_filter
// New pipeline:
// 1. event_type_filter (existing glob match)
// 2. filter_pattern (new pattern match)
// 3. filter_function (new JS predicate)
```

- [ ] Add `matches_filter_pattern()` call after `match_event_type()`
- [ ] Add `execute_filter_function()` call after pattern match
- [ ] Log filter results for debugging

#### 9.2 Update Route Execution

**File:** `flovyn-server/plugins/eventhook/src/service/processor.rs`

Update `execute_route()` (around line 200):

```rust
// Current: executes single target
// New flow:
// 1. Apply input_transform to payload
// 2. Execute each target in targets[]
// 3. Continue even if some targets fail
```

- [ ] Add `apply_transform()` before target execution
- [ ] Change `execute_target()` to iterate over `targets`
- [ ] Track partial failures (some targets succeed, some fail)
- [ ] Update event_action records for each target

---

### Phase 10: API DTOs

**Rationale:** Update API layer after all core logic is working.

#### 10.1 Request/Response DTOs

**File:** `flovyn-server/plugins/eventhook/src/api/dto.rs`

- [ ] Add `filter_pattern: Option<FilterPatternDto>` to `CreateRouteRequest`
- [ ] Add `filter_function: Option<String>` to `CreateRouteRequest`
- [ ] Add `input_transform: Option<InputTransformDto>` to `CreateRouteRequest`
- [ ] Add `targets: Option<Vec<TargetConfigRequest>>` to `CreateRouteRequest`
- [ ] Keep `target: Option<TargetConfigRequest>` for backward compat
- [ ] Update `UpdateRouteRequest` with same fields
- [ ] Update `RouteResponse` with new fields

#### 10.2 Filter/Transform DTOs

**File:** `flovyn-server/plugins/eventhook/src/api/dto.rs`

```rust
#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct FilterPatternDto {
    pub fields: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputTransformDto {
    Passthrough,
    Jmespath { expression: String },
    Javascript { function: String },
}
```

- [ ] Add `FilterPatternDto` with ToSchema
- [ ] Add `InputTransformDto` with ToSchema
- [ ] Add conversion impls to/from domain types

---

### Phase 11: API Handlers

**Rationale:** Update handlers to use new DTOs.

#### 11.1 Route Handlers

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/routes.rs`

- [ ] Update `create_route` to validate filter_function at creation
- [ ] Update `create_route` to validate JS transform at creation
- [ ] Update `create_route` to validate JMESPath expression at creation
- [ ] Handle `target` vs `targets` (normalize to `targets`)
- [ ] Update `update_route` with same changes
- [ ] Return validation errors with clear messages

#### 11.2 Validation Endpoint

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/routes.rs`

```rust
/// POST /api/tenants/{tenant_slug}/eventhook/routes/validate
pub async fn validate_route(
    State(state): State<EventhookState>,
    Path(tenant_slug): Path<String>,
    Json(req): Json<ValidateRouteRequest>,
) -> Result<Json<ValidateRouteResponse>, ApiError>
```

- [ ] Define `ValidateRouteRequest` DTO
- [ ] Define `ValidateRouteResponse` DTO
- [ ] Validate filter_function syntax (compile test)
- [ ] Validate transform function/expression syntax
- [ ] Execute with test payload if provided
- [ ] Return validation results + sample output

#### 11.3 Register Validation Route

**File:** `flovyn-server/plugins/eventhook/src/api/mod.rs`

- [ ] Add `POST /routes/validate` to router

---

### Phase 12: OpenAPI Updates

**File:** `flovyn-server/plugins/eventhook/src/api/openapi.rs`

- [ ] Register `FilterPatternDto` schema
- [ ] Register `InputTransformDto` schema
- [ ] Register `ValidateRouteRequest` schema
- [ ] Register `ValidateRouteResponse` schema
- [ ] Update existing route schemas for new fields
- [ ] Verify: `./target/debug/export-openapi | jq '.paths["/api/tenants/{tenant_slug}/eventhook/routes"]'`

---

### Phase 13: Integration Tests

**Rationale:** End-to-end tests to verify full flow.

**File:** `flovyn-server/server/tests/integration/eventhook_tests.rs`

#### 13.1 Filter Pattern Tests

- [ ] `test_route_filter_pattern_matches` - event with matching payload is processed
- [ ] `test_route_filter_pattern_no_match` - event that doesn't match is skipped
- [ ] `test_route_combined_filters` - event_type_filter + filter_pattern work together

#### 13.2 Filter Function Tests

- [ ] `test_route_filter_function_true` - JS returns true, event processed
- [ ] `test_route_filter_function_false` - JS returns false, event skipped
- [ ] `test_route_filter_function_invalid` - invalid JS rejected at creation

#### 13.3 Transform Tests

- [ ] `test_route_jmespath_transform` - workflow receives transformed payload
- [ ] `test_route_js_transform` - workflow receives JS-transformed payload

#### 13.4 Multi-Target Tests

- [ ] `test_route_multiple_targets` - multiple targets all executed
- [ ] `test_route_partial_target_failure` - continues after one target fails
- [ ] `test_backward_compat_single_target` - old API format still works

#### 13.5 Validation Tests

- [ ] `test_validate_endpoint_valid` - returns success for valid config
- [ ] `test_validate_endpoint_invalid_js` - returns error for bad JS
- [ ] `test_validate_endpoint_with_sample` - returns sample transform output

**Run:** `cargo test --test integration_tests eventhook_m3 -- --nocapture`

---

### Phase 14: Module Exports & Cleanup

#### 14.1 Module Exports

**File:** `flovyn-server/plugins/eventhook/src/service/mod.rs`

- [ ] Export `filter_pattern` module
- [ ] Export `filter_function` module
- [ ] Export `transform_jmespath` module
- [ ] Export `transform_javascript` module
- [ ] Export `script_sandbox` module

#### 14.2 Final Verification

```bash
# All tests pass
cargo test -p flovyn-plugin-eventhook
cargo test --test integration_tests eventhook

# No warnings
cargo clippy -p flovyn-plugin-eventhook

# Formatting
cargo fmt -p flovyn-plugin-eventhook -- --check
```

- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] No clippy warnings
- [ ] Code is formatted

#### 14.3 Documentation Update

- [ ] Update design document status to "Implemented"
- [ ] Update this plan status to "Completed"

---

## Testing Commands Reference

```bash
# Unit tests for eventhook plugin
cargo test -p flovyn-plugin-eventhook

# Specific module tests
cargo test -p flovyn-plugin-eventhook filter_pattern
cargo test -p flovyn-plugin-eventhook script_sandbox
cargo test -p flovyn-plugin-eventhook filter_function
cargo test -p flovyn-plugin-eventhook transform_jmespath
cargo test -p flovyn-plugin-eventhook transform_javascript

# Integration tests (requires Docker for testcontainers)
cargo test --test integration_tests eventhook

# Run integration tests multiple times (flakiness check)
./bin/dev/run-tests-loop.sh 5 eventhook

# Verify OpenAPI spec
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("eventhook")))'
```

---

## File Structure Summary

```
plugins/eventhook/src/
├── domain/
│   ├── route.rs              # UPDATE: Add filter_pattern, filter_function, input_transform, targets
│   └── transform.rs          # NEW: InputTransform enum
├── service/
│   ├── mod.rs                # UPDATE: Export new modules
│   ├── processor.rs          # UPDATE: Add filter/transform pipeline
│   ├── filter_pattern.rs     # NEW: Pattern matching logic
│   ├── filter_function.rs    # NEW: JS filter executor
│   ├── transform_jmespath.rs # NEW: JMESPath transformer
│   ├── transform_javascript.rs # NEW: JS transformer
│   └── script_sandbox.rs     # NEW: Timeout/security wrapper
├── repository/
│   └── route_repository.rs   # UPDATE: Handle new fields
├── api/
│   ├── mod.rs                # UPDATE: Add /routes/validate endpoint
│   ├── dto.rs                # UPDATE: Add FilterPatternDto, InputTransformDto
│   ├── openapi.rs            # UPDATE: Register new schemas
│   └── handlers/
│       └── routes.rs         # UPDATE: Add validate_route handler
└── migrations/
    └── 20260103XXXXXX_advanced_routing.sql  # NEW: Schema changes
```

---

## Exit Criteria Checklist

M3 is complete when all items are checked:

### Filter Pattern
- [x] Exact match works (`"status": "active"`)
- [x] AnyOf match works (`"status": ["active", "pending"]`)
- [x] Numeric operators work ($eq, $ne, $gt, $gte, $lt, $lte)
- [x] String operators work ($contains, $startsWith, $endsWith)
- [x] $exists operator works
- [x] $in operator works
- [x] Nested path extraction works ("data.object.amount")
- [x] Multiple conditions AND together

### Filter Function (JavaScript)
- [x] Basic filter returns true/false
- [x] Can access event.headers, event.body, event.eventType
- [x] Syntax errors caught at route creation
- [x] Runtime errors caught during execution
- [x] Timeout protection works (100ms limit)

### Input Transform
- [x] Passthrough works (no transformation)
- [x] JMESPath transformation works
- [x] JavaScript transformation works
- [x] Transform errors handled gracefully

### Multi-Target Routes
- [x] Route with multiple targets executes all
- [x] Partial failures don't block remaining targets
- [x] Backward compatible: `target` field still works

### API
- [x] Create route accepts new fields
- [x] Update route accepts new fields
- [ ] Validation endpoint works (`POST /routes/validate`) - *deferred to future iteration*
- [x] OpenAPI spec includes new schemas

### Tests
- [x] All unit tests pass (`cargo test -p flovyn-plugin-eventhook`) - 69 tests passing
- [ ] All integration tests pass (`cargo test --test integration_tests eventhook`) - *pending*
- [x] No clippy warnings