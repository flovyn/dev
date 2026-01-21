# Bug: Workflow Definitions Missing Input Schema Support

**Date:** 2025-12-30
**Severity:** Medium
**Component:** Workflow Definition API
**Status:** FIXED (Server + Rust SDK: 2025-12-30, Kotlin SDK: 2025-12-31)

## Summary

Workflow definitions do not expose `input_schema` in the API response, preventing the frontend from generating sample input when launching workflows. Tasks have the proto field for this but it's never populated by SDKs.

## Resolution

Added full `input_schema` and `output_schema` support with auto-generation from Rust types and manual schema support for Kotlin.

### Server-Side Changes:
- Added `input_schema` (field 11) and `output_schema` (field 12) to `WorkflowCapability` proto message
- Added database migration `20251230214436_add_workflow_input_schema.sql`
- Updated domain model, repository, gRPC handler, and REST API
- Updated REST client types for SDK consumers

### SDK Changes (sdk-rust):
- Added `schemars` dependency for JSON Schema auto-generation (like Kotlin's JsonSchemaGenerator)
- Added `JsonSchema` trait bound to `WorkflowDefinition::Input` and `WorkflowDefinition::Output` types
- Added `input_schema()` and `output_schema()` methods to `WorkflowDefinition` trait with default auto-generation
- Added `input_schema()` and `output_schema()` methods to `DynamicWorkflow` trait for manual schemas
- Updated blanket impl `impl<T: DynamicWorkflow> WorkflowDefinition for T` to delegate to manual schemas
- Updated `WorkflowMetadata` to include `input_schema` and `output_schema` fields
- Single `register_workflow()` method works for both typed and dynamic workflows
- Re-exported `schemars::JsonSchema` in prelude for convenience

### SDK Changes (sdk-kotlin):
- Added `inputSchema` and `outputSchema` properties to `WorkflowDefinition` abstract class (default to `null`)
- Created `WorkflowMetadataFfi` and `TaskMetadataFfi` structs in FFI layer with schema fields
- Updated `WorkerConfig` FFI from `workflow_kinds: Vec<String>` to `workflow_metadata: Vec<WorkflowMetadataFfi>`
- Updated `FlovynClient.kt` to pass full workflow metadata including schemas through FFI
- Updated FFI worker registration to convert metadata and parse JSON schema strings
- Added unit tests for schema support

### How It Works:

**Rust SDK:**
1. **Typed Workflows**: Auto-generate JSON Schema from `#[derive(JsonSchema)]` on Input/Output types
2. **Dynamic Workflows**: Use manual `input_schema()` and `output_schema()` methods

**Kotlin SDK:**
1. Override `inputSchema` and `outputSchema` properties with JSON Schema strings
2. Default returns `null` (no schema)

### Verified by:

**Integration tests (end-to-end):**
- `test_workflow_definition_should_have_input_schema` - DynamicWorkflow with manual schemas
- `test_typed_workflow_auto_generated_schema` - Typed workflow with auto-generated schemas from Rust types

**Rust SDK unit tests (schema structure verification):**
- `test_generate_schema_has_correct_properties` - All struct fields become JSON Schema properties
- `test_generate_schema_has_correct_types` - Rust types map correctly (String→"string", u64→"integer", bool→"boolean")
- `test_generate_schema_has_required_fields` - Non-Option fields are in `required` array
- `test_generate_schema_optional_field_allows_null` - Option<T> fields NOT in `required` array
- `test_generate_schema_output_type` - Output schema also correctly formed
- `test_schema_is_valid_json_schema` - Has proper JSON Schema structure ($schema, type: object)

**Kotlin SDK unit tests:**
- `WorkflowDefinitionSchemaTest.default schema is null` - Workflows without schema override return null
- `WorkflowDefinitionSchemaTest.explicit schema is returned` - Explicit schema is properly returned
- `WorkflowDefinitionSchemaTest.workflow properties are correctly set` - Other properties work with schemas

**Example - Rust type to JSON Schema:**
```rust
#[derive(JsonSchema)]
struct OrderInput {
    order_id: String,
    amount: u64,
    customer_email: Option<String>,
    send_receipt: bool,
}
```
Generates:
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "order_id": { "type": "string" },
    "amount": { "type": "integer" },
    "customer_email": { "type": "string" },
    "send_receipt": { "type": "boolean" }
  },
  "required": ["order_id", "amount", "send_receipt"]
}
```
Note: `customer_email` is NOT in required because it's `Option<String>`.

## Current Behavior

1. `GET /api/orgs/{slug}/workflow-definitions` returns `WorkflowDefinitionResponse` without `inputSchema` field
2. Frontend "Run Workflow" dialog shows empty `{}` as default input

## Expected Behavior

1. Workflow definitions should have `input_schema` support
2. API should return `inputSchema` field in `WorkflowDefinitionResponse`
3. Frontend should be able to generate sample input from the schema

---

## Technical Analysis

### Proto File Comparison

There are **two proto files** that must stay in sync:
1. **Server**: `flovyn-server/server/proto/flovyn.proto`
2. **SDK**: `sdk-rust/proto/flovyn.proto`

#### TaskCapability (Both protos - identical)
```protobuf
message TaskCapability {
  string kind = 1;
  string name = 2;
  string description = 3;
  optional int32 timeout_seconds = 4;
  bool cancellable = 5;
  repeated string tags = 6;
  bytes retry_policy = 7;
  bytes input_schema = 8;   // ✅ EXISTS
  bytes output_schema = 9;  // ✅ EXISTS
  bytes metadata = 10;
}
```

#### WorkflowCapability (Both protos - identical, before fix)
```protobuf
message WorkflowCapability {
  string kind = 1;
  string name = 2;
  string description = 3;
  optional int32 timeout_seconds = 4;
  bool cancellable = 5;
  repeated string tags = 6;
  bytes retry_policy = 7;
  bytes metadata = 8;
  string version = 9;
  string content_hash = 10;
  // ❌ NO input_schema
  // ❌ NO output_schema
}
```

### SDK Metadata Structs Comparison

#### WorkflowMetadata (`sdk-rust/core/src/workflow/execution.rs`)
```rust
pub struct WorkflowMetadata {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub tags: Vec<String>,
    pub cancellable: bool,
    pub timeout_seconds: Option<u64>,
    pub content_hash: Option<String>,
    // ❌ NO input_schema
}
```

#### TaskMetadata (`sdk-rust/core/src/task/execution.rs`)
```rust
pub struct TaskMetadata {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub tags: Vec<String>,
    pub timeout_seconds: Option<u32>,
    pub cancellable: bool,
    pub heartbeat_timeout_seconds: Option<u32>,
    // ❌ NO input_schema (even though proto has it!)
}
```

### SDK Proto Conversion (`sdk-rust/core/src/client/worker_lifecycle.rs`)

#### workflow_to_proto (lines 173-192)
```rust
fn workflow_to_proto(metadata: WorkflowMetadata) -> WorkflowCapability {
    WorkflowCapability {
        kind: metadata.kind,
        name: metadata.name,
        description: metadata.description.unwrap_or_default(),
        timeout_seconds: metadata.timeout_seconds.map(|s| s as i32),
        cancellable: metadata.cancellable,
        tags: metadata.tags,
        retry_policy: Vec::new(),
        metadata: Vec::new(),
        version,
        content_hash,
        // NO input_schema field exists in proto
    }
}
```

#### task_to_proto (lines 206-218)
```rust
fn task_to_proto(metadata: TaskMetadata) -> TaskCapability {
    TaskCapability {
        kind: metadata.kind,
        name: metadata.name,
        description: metadata.description.unwrap_or_default(),
        timeout_seconds: metadata.timeout_seconds.map(|s| s as i32),
        cancellable: metadata.cancellable,
        tags: metadata.tags,
        retry_policy: Vec::new(),
        input_schema: Vec::new(),   // ⚠️ ALWAYS EMPTY!
        output_schema: Vec::new(),  // ⚠️ ALWAYS EMPTY!
        metadata: Vec::new(),
    }
}
```

### Kotlin SDK Architecture (UPDATED after fix)

The Kotlin SDK does NOT have its own proto file. It uses:
```
Kotlin SDK → UniFFI → Rust FFI → Rust SDK Core → gRPC (proto)
```

#### How Kotlin SDK Registers Workers (after fix)

**Step 1: FlovynClient.start() creates WorkerConfig with full metadata**
```kotlin
// FlovynClient.kt
val workflowMetadata = workflowRegistry.getAll().map { registered ->
    val def = registered.definition
    WorkflowMetadataFfi(
        kind = def.kind,
        name = def.name,
        description = def.description,
        version = def.version.toString(),
        tags = def.tags,
        cancellable = def.cancellable,
        timeoutSeconds = def.timeoutSeconds?.toUInt(),
        inputSchema = def.inputSchema,    // ✅ Now passed!
        outputSchema = def.outputSchema   // ✅ Now passed!
    )
}
```

**Step 2: FFI WorkerConfig accepts full metadata**
```rust
// ffi/src/config.rs
pub struct WorkflowMetadataFfi {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub tags: Vec<String>,
    pub cancellable: bool,
    pub timeout_seconds: Option<u32>,
    pub input_schema: Option<String>,   // ✅ Full metadata
    pub output_schema: Option<String>,  // ✅ Full metadata
}

pub struct WorkerConfig {
    ...
    pub workflow_metadata: Vec<WorkflowMetadataFfi>,  // Full metadata, not just strings
    pub task_metadata: Vec<TaskMetadataFfi>,
}
```

**Step 3: FFI CoreWorker.register() converts metadata with schemas**
```rust
// ffi/src/worker.rs
let workflows: Vec<WorkflowMetadata> = self
    .config
    .workflow_metadata
    .iter()
    .map(|m| {
        let mut metadata = WorkflowMetadata::new(&m.kind)
            .with_name(&m.name)
            .with_cancellable(m.cancellable);
        if let Some(schema_str) = &m.input_schema {
            if let Ok(schema) = serde_json::from_str(schema_str) {
                metadata = metadata.with_input_schema(schema);
            }
        }
        // ... similar for output_schema
        metadata
    })
    .collect();
```

#### Kotlin WorkflowDefinition schema support

```kotlin
abstract class WorkflowDefinition<INPUT, OUTPUT> {
    // Manual schema override (default to null)
    open val inputSchema: String? get() = null
    open val outputSchema: String? get() = null
}

// Usage:
class MyWorkflow : WorkflowDefinition<MyInput, MyOutput>() {
    override val kind = "my-workflow"

    override val inputSchema: String = """
        {
            "type": "object",
            "properties": {
                "orderId": { "type": "string" }
            },
            "required": ["orderId"]
        }
    """.trimIndent()
}
```

#### Note: No auto-generation in Kotlin

Unlike the Rust SDK which can auto-generate schemas from `#[derive(JsonSchema)]`, the Kotlin SDK requires manual schema definition. Future work could add auto-generation using `jackson-module-jsonSchema` or similar.

### Server-Side Components

#### Database Schema
```sql
-- task_definition (has columns)
input_schema        | jsonb   -- ✅ EXISTS
output_schema       | jsonb   -- ✅ EXISTS

-- workflow_definition (missing columns)
metadata            | jsonb   -- exists but unused
-- ❌ NO input_schema
-- ❌ NO output_schema
```

#### Domain Models
- `TaskDefinition` struct has `input_schema: Option<serde_json::Value>` ✅
- `WorkflowDefinition` struct does NOT have `input_schema` ❌

#### API Response
- `TaskDefinitionResponse` includes `input_schema` ✅
- `WorkflowDefinitionResponse` does NOT include `input_schema` ❌

---

## Root Cause Analysis

1. **Proto asymmetry**: `TaskCapability` has `input_schema` field but `WorkflowCapability` doesn't
2. **SDK never populates**: Even for tasks, the SDK always sends `Vec::new()` for `input_schema`
3. **No schema source**: Neither SDK metadata structs have `input_schema` fields
4. **No schema derivation**: Kotlin captures `inputType: Class<*>` but doesn't derive JSON Schema from it

**The "task has schema support" is misleading** - the infrastructure exists but is never used.

---

## Proposed Solution

### Option A: Explicit Schema Definition (Recommended)
Users explicitly provide JSON Schema in their workflow/task definitions.

**Pros**: Simple, explicit, works across all languages
**Cons**: Manual, can get out of sync with actual types

### Option B: Type-Derived Schema
Derive JSON Schema from input/output types automatically.

**Rust**: Use `schemars` crate with `#[derive(JsonSchema)]`
**Kotlin**: Use `jackson-module-jsonSchema`

**Pros**: Always in sync with types
**Cons**: Requires additional dependencies, doesn't work for dynamic types

### Option C: Hybrid
- Default: derive from types if possible
- Override: allow explicit schema definition

---

## Implementation TODO

### Phase 1: Server-Side (flovyn-server) - COMPLETED

- [x] **1.1** Update proto `WorkflowCapability` to add `input_schema` (field 11) and `output_schema` (field 12)
- [x] **1.2** Database migration: Add `input_schema JSONB` column to `workflow_definition` (`20251230214436_add_workflow_input_schema.sql`)
- [x] **1.3** Update domain model `WorkflowDefinition` to include `input_schema` and `output_schema`
- [x] **1.4** Update repository queries (INSERT, UPDATE, SELECT)
- [x] **1.5** Update worker registration gRPC handler to store schema (`workflow_capability_to_definition`)
- [x] **1.6** Update `WorkflowDefinitionResponse` API response
- [x] **1.7** Update REST client types
- [x] **1.8** Update OpenAPI spec (via utoipa ToSchema derive)

### Phase 2: SDK Changes (sdk-rust) - COMPLETED

- [x] **2.1** Update proto `WorkflowCapability` (must match server)
- [x] **2.2** Add `schemars = "1"` dependency for JSON Schema generation (like Kotlin's JsonSchemaGenerator)
- [x] **2.3** Add `JsonSchema` trait bound to `WorkflowDefinition::Input` and `WorkflowDefinition::Output`
- [x] **2.4** Add `input_schema()` and `output_schema()` to `WorkflowDefinition` trait with auto-generation defaults using `schemars::schema_for!()`
- [x] **2.5** Add manual `input_schema()` and `output_schema()` to `DynamicWorkflow` trait (returns `None` by default)
- [x] **2.6** Update blanket impl `impl<T: DynamicWorkflow> WorkflowDefinition for T` to delegate schema methods to `DynamicWorkflow` trait
- [x] **2.7** Add `input_schema: Option<Value>` and `output_schema: Option<Value>` to registry's `WorkflowMetadata`
- [x] **2.8** Update `workflow_to_proto` in core to serialize schemas to bytes
- [x] **2.9** Remove `register_dynamic()` - single `register_workflow()` works for both typed and dynamic workflows
- [x] **2.10** Update existing unit tests to derive `JsonSchema` on Input/Output types

**Note:** Task schema support (TaskDefinition) follows the same pattern but is deferred for future work.

### Phase 3: SDK Kotlin (uses FFI) - COMPLETED

- [x] **3.1** Add `inputSchema` and `outputSchema` properties to `WorkflowDefinition.kt`
- [x] **3.2** Create `WorkflowMetadataFfi` struct in FFI with schema fields
- [x] **3.3** Update `WorkerConfig` FFI from `workflow_kinds: Vec<String>` to `workflow_metadata: Vec<WorkflowMetadataFfi>`
- [x] **3.4** Update `FlovynClient.kt` to pass full metadata including schemas through FFI
- [x] **3.5** Update FFI worker registration to convert metadata with schemas to core types
- [x] **3.6** Add unit tests for Kotlin schema support (`WorkflowDefinitionSchemaTest.kt`)

### Phase 4: Testing - COMPLETED

- [x] **4.1** Integration test: DynamicWorkflow with manual schemas (`test_workflow_definition_should_have_input_schema`)
- [x] **4.2** Integration test: Typed workflow with auto-generated schemas (`test_typed_workflow_auto_generated_schema`)
- [ ] **4.3** Integration test: task with schema (fix existing broken support) - deferred

---

## Files to Modify

### Server (flovyn-server)
| File | Change |
|------|--------|
| `server/proto/flovyn.proto` | Add `input_schema`, `output_schema` to `WorkflowCapability` |
| `server/migrations/` | New migration for `input_schema` column |
| `flovyn-server/server/src/domain/workflow_definition.rs` | Add `input_schema` field |
| `flovyn-server/server/src/repository/workflow_definition_repository.rs` | Update queries |
| `flovyn-server/server/src/api/rest/workflow_definitions.rs` | Update response |
| `flovyn-server/server/src/api/grpc/worker_lifecycle.rs` | Extract and store schema |
| `flovyn-server/crates/rest-client/src/types.rs` | Add field to response types |

### SDK Rust (sdk-rust)
| File | Change |
|------|--------|
| `proto/flovyn.proto` | Add `input_schema`, `output_schema` to `WorkflowCapability` |
| `flovyn-server/core/src/workflow/execution.rs` | Add `input_schema` to `WorkflowMetadata` |
| `flovyn-server/core/src/task/execution.rs` | Add `input_schema` to `TaskMetadata` |
| `flovyn-server/core/src/client/worker_lifecycle.rs` | Update `workflow_to_proto`, `task_to_proto` |
| `flovyn-server/sdk/src/workflow/definition.rs` | Add `input_schema()` method |
| `flovyn-server/sdk/src/task/definition.rs` | Add `input_schema()` method |
| `flovyn-server/sdk/src/worker/registry.rs` | Update `WorkflowMetadata` |
| `flovyn-server/sdk/src/task/registry.rs` | Update `TaskMetadata` |

---

## Frontend Status

The frontend (`flovyn-app`) is already prepared:
- `RunWorkflowDialog` has `generateExampleFromSchema()` function
- Dialog extracts `inputSchema` from response
- No frontend changes needed once backend provides the data
