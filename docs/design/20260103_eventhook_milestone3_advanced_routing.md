# Eventhook Milestone 3: Advanced Routing

**Date:** 2026-01-03
**Status:** Implemented
**Related:** [M1 Design](./20250101_eventhook_milestone1_receive_route.md), [M2 Design](./20260103_eventhook_milestone2_management_api.md), [Research](../research/eventhook/20251231_research.md)

## Overview

This document describes the design for Milestone 3 of the Eventhook feature: advanced routing capabilities including JSON pattern matching, input transformation, JavaScript filters, and multi-target rules.

**Scope:**
- Data pattern matching (match on JSON fields)
- Input transformation (JMESPath extraction)
- JavaScript filter functions (custom predicates)
- JavaScript transform functions (custom transformations)
- Multi-target rules (one event → multiple targets)

## Goals

1. **Powerful filtering** - Match events based on payload content, not just event type
2. **Flexible transformation** - Reshape payloads before sending to targets
3. **Custom logic** - JavaScript for complex routing decisions
4. **Fan-out patterns** - Single event triggers multiple targets

## Non-Goals

- Outbound webhook delivery (Milestone 4)
- Event persistence with JetStream (Milestone 5)
- Full EventBridge compatibility (syntax differs)

## Prerequisites

- M1 complete: Ingest endpoint, signature verification, event processing
- M2 complete: Management API for sources, routes, events

## Architecture

### Current Route Matching (M1/M2)

```rust
pub struct WebhookRoute {
    // Existing fields
    pub event_type_filter: Option<String>,  // Glob pattern: "push", "pull_request.*"
    pub condition: Option<String>,           // Reserved but unused
    pub target: TargetConfig,                // Single target
}
```

Current matching is simple:
1. Match event type against glob pattern
2. Execute single target

### Extended Route Matching (M3)

```rust
pub struct WebhookRoute {
    // Existing fields (unchanged)
    pub event_type_filter: Option<String>,

    // New: JSON pattern matching
    pub filter_pattern: Option<FilterPattern>,

    // New: JavaScript filter function
    pub filter_function: Option<String>,

    // New: Input transformation
    pub input_transform: Option<InputTransform>,

    // Changed: Multiple targets
    pub targets: Vec<TargetConfig>,  // Was: target: TargetConfig

    pub priority: i32,
    pub enabled: bool,
}
```

### Matching Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Webhook Event                                 │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Event Type Filter (existing)                                     │
│    - Glob matching: "push", "pull_request.*", "payment_intent.*"    │
│    - Fast, string-based filtering                                   │
└─────────────────────────────────────────────────────────────────────┘
                                │ (if passes)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. Filter Pattern (new)                                             │
│    - JSON pattern matching on payload fields                         │
│    - Numeric comparisons, array contains, existence checks          │
└─────────────────────────────────────────────────────────────────────┘
                                │ (if passes)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. Filter Function (new)                                            │
│    - JavaScript predicate: function(event) → boolean                │
│    - For complex logic not expressible in patterns                  │
└─────────────────────────────────────────────────────────────────────┘
                                │ (if returns true)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. Input Transform (new)                                            │
│    - JMESPath: Extract and restructure payload                      │
│    - JavaScript: Custom transformation logic                         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. Execute Targets (extended)                                       │
│    - Multiple targets per route                                      │
│    - Each target receives transformed input                          │
└─────────────────────────────────────────────────────────────────────┘
```

## Filter Pattern

JSON pattern matching inspired by AWS EventBridge, but simplified.

### Pattern Syntax

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterPattern {
    /// Field conditions (all must match)
    pub fields: HashMap<String, FieldCondition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum FieldCondition {
    /// Exact match: { "status": "active" }
    Exact(serde_json::Value),

    /// Match any of these values: { "status": ["active", "pending"] }
    AnyOf(Vec<serde_json::Value>),

    /// Operators: { "amount": { "$gte": 1000 } }
    Operator(OperatorCondition),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OperatorCondition {
    #[serde(rename = "$eq")]
    pub eq: Option<serde_json::Value>,

    #[serde(rename = "$ne")]
    pub ne: Option<serde_json::Value>,

    #[serde(rename = "$gt")]
    pub gt: Option<serde_json::Number>,

    #[serde(rename = "$gte")]
    pub gte: Option<serde_json::Number>,

    #[serde(rename = "$lt")]
    pub lt: Option<serde_json::Number>,

    #[serde(rename = "$lte")]
    pub lte: Option<serde_json::Number>,

    #[serde(rename = "$contains")]
    pub contains: Option<String>,

    #[serde(rename = "$startsWith")]
    pub starts_with: Option<String>,

    #[serde(rename = "$endsWith")]
    pub ends_with: Option<String>,

    #[serde(rename = "$exists")]
    pub exists: Option<bool>,

    #[serde(rename = "$in")]
    pub in_array: Option<Vec<serde_json::Value>>,
}
```

### Pattern Examples

**Exact match:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.status": "succeeded"
    }
  }
}
```

**Match any of multiple values:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.status": ["succeeded", "pending"]
    }
  }
}
```

**Numeric comparison:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.amount": { "$gte": 1000 },
      "data.object.currency": "usd"
    }
  }
}
```

**String operations:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.customer_email": { "$endsWith": "@enterprise.com" },
      "data.object.description": { "$contains": "VIP" }
    }
  }
}
```

**Existence check:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.metadata.priority": { "$exists": true }
    }
  }
}
```

**Array membership:**
```json
{
  "filterPattern": {
    "fields": {
      "data.object.payment_method_types": { "$in": ["card", "bank_transfer"] }
    }
  }
}
```

### Implementation

```rust
// plugins/eventhook/src/service/filter_pattern.rs

pub fn matches_pattern(payload: &serde_json::Value, pattern: &FilterPattern) -> bool {
    for (path, condition) in &pattern.fields {
        let value = extract_path(payload, path);
        if !matches_condition(&value, condition) {
            return false;
        }
    }
    true
}

fn extract_path(value: &serde_json::Value, path: &str) -> Option<&serde_json::Value> {
    let parts: Vec<&str> = path.split('.').collect();
    let mut current = value;

    for part in parts {
        match current {
            serde_json::Value::Object(map) => {
                current = map.get(part)?;
            }
            serde_json::Value::Array(arr) => {
                let index: usize = part.parse().ok()?;
                current = arr.get(index)?;
            }
            _ => return None,
        }
    }

    Some(current)
}

fn matches_condition(value: &Option<&serde_json::Value>, condition: &FieldCondition) -> bool {
    match condition {
        FieldCondition::Exact(expected) => {
            value.map(|v| v == expected).unwrap_or(false)
        }
        FieldCondition::AnyOf(options) => {
            value.map(|v| options.contains(v)).unwrap_or(false)
        }
        FieldCondition::Operator(op) => matches_operator(value, op),
    }
}

fn matches_operator(value: &Option<&serde_json::Value>, op: &OperatorCondition) -> bool {
    // Handle $exists first
    if let Some(should_exist) = op.exists {
        return value.is_some() == should_exist;
    }

    let Some(v) = value else { return false };

    // Numeric comparisons
    if let Some(ref threshold) = op.gte {
        if !compare_numeric(v, threshold, |a, b| a >= b) {
            return false;
        }
    }
    // ... other operators

    true
}
```

## Filter Function

JavaScript predicate for complex routing decisions.

### Interface

```javascript
// Filter function signature
function filter(event) {
    // event.headers: object with HTTP headers
    // event.body: parsed JSON payload
    // event.eventType: string (if extracted)
    // Returns: boolean (true = match, false = skip)

    return event.body.type === 'payment_intent.succeeded'
        && event.body.data.object.amount >= 1000
        && !event.body.data.object.metadata.skip_workflow;
}
```

### Execution

Reuses existing QuickJS infrastructure from `flovyn-auth-script`:

```rust
// plugins/eventhook/src/service/filter_function.rs

use rquickjs::{Context, Runtime, Value as JsValue};

pub struct FilterFunctionExecutor {
    script: String,
}

impl FilterFunctionExecutor {
    pub fn new(script: &str) -> Result<Self, FilterError> {
        // Validate script has filter function
        Self::validate_script(script)?;
        Ok(Self { script: script.to_string() })
    }

    pub fn execute(&self, event: &FilterInput) -> Result<bool, FilterError> {
        let rt = Runtime::new()?;
        let ctx = Context::full(&rt)?;

        ctx.with(|ctx| {
            // Load script
            ctx.eval::<(), _>(&self.script)?;

            // Get filter function
            let globals = ctx.globals();
            let filter_fn: rquickjs::Function = globals.get("filter")?;

            // Build event object
            let event_obj = self.build_event_object(&ctx, event)?;

            // Call filter(event)
            let result: bool = filter_fn.call((event_obj,))?;
            Ok(result)
        })
    }

    fn build_event_object(&self, ctx: &rquickjs::Ctx, event: &FilterInput)
        -> Result<rquickjs::Object, FilterError>
    {
        let obj = rquickjs::Object::new(ctx.clone())?;

        // Convert headers
        let headers_json = serde_json::to_string(&event.headers)?;
        let headers: JsValue = ctx.json_parse(headers_json)?;
        obj.set("headers", headers)?;

        // Convert body
        let body_json = serde_json::to_string(&event.body)?;
        let body: JsValue = ctx.json_parse(body_json)?;
        obj.set("body", body)?;

        // Set event type
        if let Some(ref et) = event.event_type {
            obj.set("eventType", et.as_str())?;
        }

        Ok(obj)
    }
}

pub struct FilterInput {
    pub headers: serde_json::Value,
    pub body: serde_json::Value,
    pub event_type: Option<String>,
}
```

### Example Filter Functions

**Complex business logic:**
```javascript
function filter(event) {
    const body = event.body;

    // Only high-value orders from enterprise customers
    if (body.type !== 'order.created') return false;

    const order = body.data.object;
    const isEnterprise = order.customer_email?.endsWith('@enterprise.com');
    const isHighValue = order.amount >= 10000;

    return isEnterprise && isHighValue;
}
```

**Time-based routing:**
```javascript
function filter(event) {
    // Route to different workflows based on time
    const hour = new Date().getUTCHours();
    const isBusinessHours = hour >= 9 && hour < 17;

    // Only process during business hours
    return isBusinessHours;
}
```

**Header-based filtering:**
```javascript
function filter(event) {
    // Check for specific header values
    const priority = event.headers['x-priority'];
    return priority === 'high' || priority === 'critical';
}
```

## Input Transform

Transform payload before sending to targets.

### Transform Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputTransform {
    /// Pass payload unchanged
    Passthrough,

    /// Extract using JMESPath expression
    Jmespath { expression: String },

    /// Custom JavaScript transformation
    Javascript { function: String },
}
```

### JMESPath Transform

Uses the `jmespath` crate for JSON querying and restructuring.

```rust
// plugins/eventhook/src/service/transform_jmespath.rs

use jmespath::{Expression, Variable};

pub struct JmespathTransformer {
    expression: Expression<'static>,
}

impl JmespathTransformer {
    pub fn new(expr: &str) -> Result<Self, TransformError> {
        let expression = jmespath::compile(expr)?;
        Ok(Self { expression })
    }

    pub fn transform(&self, input: &serde_json::Value) -> Result<serde_json::Value, TransformError> {
        let var = Variable::from(input.clone());
        let result = self.expression.search(&var)?;
        Ok(result.into())
    }
}
```

**Examples:**

Extract specific fields:
```json
{
  "inputTransform": {
    "type": "jmespath",
    "expression": "{ orderId: data.object.id, amount: data.object.amount, customer: data.object.customer_email }"
  }
}
```

Extract array items:
```json
{
  "inputTransform": {
    "type": "jmespath",
    "expression": "data.object.line_items[*].{sku: sku, qty: quantity}"
  }
}
```

Conditional extraction:
```json
{
  "inputTransform": {
    "type": "jmespath",
    "expression": "{ status: data.object.status, refunded: data.object.refunded || `false` }"
  }
}
```

### JavaScript Transform

For transformations too complex for JMESPath.

```rust
// plugins/eventhook/src/service/transform_javascript.rs

pub struct JavascriptTransformer {
    script: String,
}

impl JavascriptTransformer {
    pub fn new(script: &str) -> Result<Self, TransformError> {
        Self::validate_script(script)?;
        Ok(Self { script: script.to_string() })
    }

    pub fn transform(&self, event: &TransformInput) -> Result<serde_json::Value, TransformError> {
        let rt = Runtime::new()?;
        let ctx = Context::full(&rt)?;

        ctx.with(|ctx| {
            ctx.eval::<(), _>(&self.script)?;

            let globals = ctx.globals();
            let transform_fn: rquickjs::Function = globals.get("transform")?;

            let event_obj = self.build_event_object(&ctx, event)?;
            let result: rquickjs::Value = transform_fn.call((event_obj,))?;

            // Convert JS result back to serde_json::Value
            let json_str = ctx.json_stringify(result)?;
            let value: serde_json::Value = serde_json::from_str(&json_str)?;
            Ok(value)
        })
    }
}

pub struct TransformInput {
    pub headers: serde_json::Value,
    pub body: serde_json::Value,
    pub event_type: Option<String>,
}
```

**Examples:**

Unit conversion:
```javascript
function transform(event) {
    const obj = event.body.data.object;
    return {
        id: obj.id,
        amountCents: Math.round(obj.amount * 100),
        currency: obj.currency.toUpperCase(),
        metadata: obj.metadata || {}
    };
}
```

Combine headers and body:
```javascript
function transform(event) {
    return {
        eventType: event.headers['x-event-type'] || event.body.type,
        source: event.headers['x-source'] || 'unknown',
        payload: event.body.data
    };
}
```

Complex restructuring:
```javascript
function transform(event) {
    const order = event.body.data.object;
    const items = order.line_items || [];

    return {
        orderId: order.id,
        customer: {
            email: order.customer_email,
            name: order.shipping?.name
        },
        items: items.map(item => ({
            sku: item.sku,
            name: item.description,
            quantity: item.quantity,
            price: item.amount / 100
        })),
        total: order.amount / 100,
        currency: order.currency
    };
}
```

## Multi-Target Routes

A single route can trigger multiple targets.

### Schema Change

```sql
-- Migration: 20260103_multi_target_routes.sql

-- Change target column to targets array
ALTER TABLE p_eventhook__route
    RENAME COLUMN target TO targets;

ALTER TABLE p_eventhook__route
    ALTER COLUMN targets TYPE JSONB[] USING ARRAY[targets];

-- Add new filter columns
ALTER TABLE p_eventhook__route
    ADD COLUMN filter_pattern JSONB,
    ADD COLUMN filter_function TEXT,
    ADD COLUMN input_transform JSONB;
```

### Domain Model

```rust
pub struct WebhookRoute {
    pub id: Uuid,
    pub source_id: Uuid,
    pub name: String,
    pub description: Option<String>,

    // Filtering (existing + new)
    pub event_type_filter: Option<String>,
    pub filter_pattern: Option<FilterPattern>,
    pub filter_function: Option<String>,

    // Transformation (new)
    pub input_transform: Option<InputTransform>,

    // Multi-target (changed)
    pub targets: Vec<TargetConfig>,

    pub priority: i32,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

### Execution

```rust
impl EventProcessor {
    async fn execute_route(
        &self,
        event: &WebhookEvent,
        route: &WebhookRoute,
        payload: &serde_json::Value,
    ) -> Result<Vec<TargetResult>, ProcessorError> {
        // 1. Apply input transformation
        let input = match &route.input_transform {
            Some(InputTransform::Passthrough) | None => payload.clone(),
            Some(InputTransform::Jmespath { expression }) => {
                self.jmespath_transform(payload, expression)?
            }
            Some(InputTransform::Javascript { function }) => {
                self.js_transform(event, payload, function)?
            }
        };

        // 2. Execute all targets
        let mut results = Vec::new();
        for target in &route.targets {
            match self.execute_target(event.tenant_id, target, &input).await {
                Ok(result) => results.push(result),
                Err(e) => {
                    tracing::warn!(
                        route_id = %route.id,
                        target_type = ?target,
                        error = %e,
                        "Target execution failed"
                    );
                    // Continue with other targets
                }
            }
        }

        Ok(results)
    }
}
```

### API Changes

**Create Route with Multiple Targets:**
```json
{
  "name": "High-Value Order Processing",
  "eventTypeFilter": "order.created",
  "filterPattern": {
    "fields": {
      "data.object.amount": { "$gte": 10000 }
    }
  },
  "inputTransform": {
    "type": "jmespath",
    "expression": "{ orderId: data.object.id, amount: data.object.amount }"
  },
  "targets": [
    {
      "type": "workflow",
      "workflowKind": "vip-order-handler",
      "queue": "priority"
    },
    {
      "type": "task",
      "taskKind": "notify-sales-team"
    },
    {
      "type": "task",
      "taskKind": "audit-log"
    }
  ]
}
```

**Backward Compatibility:**

For M1/M2 routes with single target, the API accepts both:
```json
// Old format (still works)
{ "target": { "type": "workflow", ... } }

// New format
{ "targets": [{ "type": "workflow", ... }] }
```

Server normalizes old format to new internally.

## Database Schema Changes

```sql
-- Migration: 20260103_advanced_routing.sql

-- Add filter and transform columns
ALTER TABLE p_eventhook__route
    ADD COLUMN filter_pattern JSONB,
    ADD COLUMN filter_function TEXT,
    ADD COLUMN input_transform JSONB;

-- Migrate target → targets (array)
ALTER TABLE p_eventhook__route
    ADD COLUMN targets JSONB;

-- Populate targets from target
UPDATE p_eventhook__route
SET targets = jsonb_build_array(target)
WHERE target IS NOT NULL;

-- Drop old column
ALTER TABLE p_eventhook__route
    DROP COLUMN target;

-- Add NOT NULL constraint
ALTER TABLE p_eventhook__route
    ALTER COLUMN targets SET NOT NULL,
    ALTER COLUMN targets SET DEFAULT '[]'::jsonb;

-- Index for filter pattern queries (if needed for debugging)
CREATE INDEX idx_route_has_filter
    ON p_eventhook__route(source_id)
    WHERE filter_pattern IS NOT NULL;
```

## JavaScript Sandbox Security

### Constraints

1. **No I/O**: No filesystem, network, or system access
2. **Memory limit**: QuickJS default limits apply
3. **Execution timeout**: 100ms per script execution
4. **No external modules**: Cannot import/require

### Implementation

```rust
// plugins/eventhook/src/service/script_sandbox.rs

use rquickjs::{Context, Runtime};
use std::time::{Duration, Instant};

const EXECUTION_TIMEOUT: Duration = Duration::from_millis(100);

pub fn execute_with_timeout<F, T>(f: F) -> Result<T, ScriptError>
where
    F: FnOnce() -> Result<T, ScriptError> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();

    std::thread::spawn(move || {
        let result = f();
        let _ = tx.send(result);
    });

    match rx.recv_timeout(EXECUTION_TIMEOUT) {
        Ok(result) => result,
        Err(_) => Err(ScriptError::Timeout),
    }
}
```

### Validation

Scripts are validated at route creation:

```rust
impl RouteValidator {
    pub fn validate_filter_function(script: &str) -> Result<(), ValidationError> {
        // 1. Check script compiles
        let rt = Runtime::new()?;
        let ctx = Context::full(&rt)?;

        ctx.with(|ctx| {
            ctx.eval::<(), _>(script)?;

            // 2. Check 'filter' function exists
            let globals = ctx.globals();
            let filter_fn: Result<rquickjs::Function, _> = globals.get("filter");
            if filter_fn.is_err() {
                return Err(ValidationError::MissingFunction("filter"));
            }

            // 3. Test with sample input
            let test_event = json!({
                "headers": {},
                "body": {},
                "eventType": null
            });

            // Should return boolean
            // ...

            Ok(())
        })
    }

    pub fn validate_transform_function(script: &str) -> Result<(), ValidationError> {
        // Similar validation for 'transform' function
    }
}
```

## API Changes Summary

### Route Create/Update

New fields in request:
```json
{
  "name": "...",
  "eventTypeFilter": "...",

  // New: Pattern matching
  "filterPattern": {
    "fields": {
      "path.to.field": "value",
      "other.field": { "$gte": 100 }
    }
  },

  // New: JavaScript filter
  "filterFunction": "function filter(event) { return event.body.amount >= 1000; }",

  // New: Input transformation
  "inputTransform": {
    "type": "jmespath",
    "expression": "{ id: data.id, amount: data.amount }"
  },

  // Changed: Array of targets
  "targets": [
    { "type": "workflow", "workflowKind": "..." },
    { "type": "task", "taskKind": "..." }
  ]
}
```

### Validation Endpoint

```
POST /api/tenants/{tenant_slug}/eventhook/routes/validate
```

Request:
```json
{
  "filterFunction": "function filter(event) { ... }",
  "inputTransform": {
    "type": "javascript",
    "function": "function transform(event) { ... }"
  },
  "testPayload": {
    "type": "payment_intent.succeeded",
    "data": { "object": { "amount": 5000 } }
  }
}
```

Response:
```json
{
  "valid": true,
  "filterResult": true,
  "transformResult": {
    "id": "pi_123",
    "amount": 5000
  },
  "errors": []
}
```

## Dependencies

Add to `flovyn-server/plugins/eventhook/Cargo.toml`:

```toml
[dependencies]
# JMESPath for JSON querying
jmespath = "0.3"

# QuickJS JavaScript runtime (via existing infrastructure)
rquickjs = { version = "0.6", features = ["bindgen", "classes", "properties"] }
```

## Testing Strategy

### Unit Tests

**Filter Pattern:**
- `test_pattern_exact_match`
- `test_pattern_any_of`
- `test_pattern_numeric_gte`
- `test_pattern_string_contains`
- `test_pattern_exists`
- `test_pattern_nested_path`

**Filter Function:**
- `test_filter_function_returns_true`
- `test_filter_function_returns_false`
- `test_filter_function_syntax_error`
- `test_filter_function_missing_function`
- `test_filter_function_timeout`

**Transform JMESPath:**
- `test_jmespath_extract_field`
- `test_jmespath_restructure`
- `test_jmespath_array_projection`

**Transform JavaScript:**
- `test_js_transform_simple`
- `test_js_transform_complex`
- `test_js_transform_error`

**Multi-Target:**
- `test_multi_target_all_succeed`
- `test_multi_target_partial_failure`
- `test_backward_compat_single_target`

### Integration Tests

```rust
#[tokio::test]
async fn test_route_with_pattern_filter() {
    let harness = get_harness().await;

    // Create route with filter pattern
    harness.create_route(RouteConfig {
        event_type_filter: Some("payment_intent.*".into()),
        filter_pattern: Some(json!({
            "fields": {
                "data.object.amount": { "$gte": 1000 }
            }
        })),
        targets: vec![workflow_target("high-value-handler")],
        ..default()
    }).await;

    // Send event that matches
    harness.send_webhook(json!({
        "type": "payment_intent.succeeded",
        "data": { "object": { "amount": 5000 } }
    })).await;

    // Verify workflow started
    assert_workflow_started(&harness, "high-value-handler").await;

    // Send event that doesn't match
    harness.send_webhook(json!({
        "type": "payment_intent.succeeded",
        "data": { "object": { "amount": 500 } }
    })).await;

    // Verify no new workflow
    assert_workflow_count(&harness, 1).await;
}
```

## Exit Criteria

M3 is complete when:

**Filter Pattern:**
- [ ] Pattern matching on JSON fields works
- [ ] Numeric operators: $eq, $ne, $gt, $gte, $lt, $lte
- [ ] String operators: $contains, $startsWith, $endsWith
- [ ] Special operators: $exists, $in
- [ ] Nested path extraction works

**Filter Function:**
- [ ] JavaScript filter functions execute correctly
- [ ] Event object has headers, body, eventType
- [ ] Syntax errors caught at route creation
- [ ] Timeout protection works

**Input Transform:**
- [ ] JMESPath transformation works
- [ ] JavaScript transformation works
- [ ] Passthrough (no transform) works
- [ ] Transform errors handled gracefully

**Multi-Target:**
- [ ] Multiple targets per route works
- [ ] All targets receive transformed input
- [ ] Partial failures don't block other targets
- [ ] Backward compatibility with single target

**API:**
- [ ] Route create/update accepts new fields
- [ ] Validation endpoint works
- [ ] OpenAPI spec updated

**Testing:**
- [ ] Unit tests for all components
- [ ] Integration tests pass

## References

- [M1 Design](./20250101_eventhook_milestone1_receive_route.md) - Basic routing
- [M2 Design](./20260103_eventhook_milestone2_management_api.md) - Management API
- [Research](../research/eventhook/20251231_research.md) - Full research with EventBridge analysis
- [auth-script crate](../../crates/auth-script/20260103_README.md) - Existing QuickJS infrastructure
