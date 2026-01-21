# Workload Metadata Design

## Problem Statement

Users need to attach arbitrary contextual metadata to workflow and task executions for:
- **Tracking**: Associate executions with business entities (customer IDs, order IDs)
- **Filtering**: Find executions by metadata in the UI (flovyn-app)
- **Cost allocation**: Enable chargeback/backbilling by cost centers, departments
- **Analytics**: Aggregate and analyze executions by business dimensions

Current state: The gRPC proto has an unused `labels` field in `StartWorkflowRequest` and `SubmitTaskRequest` that is never persisted. We'll rename it to `metadata` for clarity.

## Requirements

### Functional
1. Accept arbitrary key-value string metadata when starting workflows and tasks
2. Store metadata with executions for later retrieval
3. Support filtering executions by metadata in list endpoints
4. Return metadata when fetching execution details

### Non-Functional
1. Minimal storage overhead for executions without metadata
2. Efficient filtering for common query patterns
3. No schema changes required when adding new metadata keys
4. Backward compatible (existing executions work without metadata)

## Design

### Storage: JSONB Column

Add a `metadata JSONB` column to both `workflow_execution` and `task_execution` tables.

**Rationale**:
- Consistent with existing patterns (`task_execution.state` is already JSONB)
- Flexible schema - no migrations when adding new metadata keys
- PostgreSQL JSONB supports efficient indexing via GIN indexes
- Nullable column has zero storage overhead when unused

```sql
-- Migration: YYYYMMDDHHMMSS_add_execution_metadata.sql
ALTER TABLE workflow_execution ADD COLUMN metadata JSONB;
ALTER TABLE task_execution ADD COLUMN metadata JSONB;

-- Optional: GIN index for jsonb_path_ops (efficient @> containment queries)
CREATE INDEX idx_workflow_execution_metadata ON workflow_execution USING GIN (metadata jsonb_path_ops);
CREATE INDEX idx_task_execution_metadata ON task_execution USING GIN (metadata jsonb_path_ops);
```

### API Changes

#### gRPC

Rename unused `labels` field to `metadata` in the proto:

```protobuf
message StartWorkflowRequest {
  map<string, string> metadata = 4;  // Renamed from labels
}

message SubmitTaskRequest {
  map<string, string> metadata = 5;  // Renamed from labels
}
```

Note: `worker_labels` in `PollTaskRequest` remains unchanged - that's for worker routing, a different concept.

#### REST API

**TriggerWorkflowRequest** - Rename `labels` to `metadata`:
```rust
pub struct TriggerWorkflowRequest {
    #[serde(default)]
    pub metadata: HashMap<String, String>,
}
```

**CreateTaskRequest** - Add `metadata` field:
```rust
pub struct CreateTaskRequest {
    #[serde(default)]
    pub metadata: HashMap<String, String>,
}
```

**Response DTOs** - Add metadata to execution responses:
```rust
pub struct WorkflowExecutionResponse {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}

pub struct TaskExecutionResponse {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}
```

### Filtering

Add optional `metadata` filter parameter to list endpoints:

```
GET /api/tenants/{tenant}/workflows?metadata.customerId=CUST-123
GET /api/tenants/{tenant}/tasks?metadata.costCenter=MARKETING
```

SQL query pattern using JSONB containment:
```sql
SELECT * FROM workflow_execution
WHERE tenant_id = $1
  AND metadata @> '{"customerId": "CUST-123"}'::jsonb;
```

### Domain Model Changes

```rust
// crates/core/src/domain/workflow.rs
pub struct WorkflowExecution {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}

// crates/core/src/domain/task.rs
pub struct TaskExecution {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}
```

### Event Sourcing Consideration

Metadata should be captured in the `WorkflowStarted` event for audit trail:

```rust
WorkflowStarted {
    input: Bytes,
    metadata: Option<serde_json::Value>,  // Add this
}
```

This ensures metadata is part of the immutable event log and can be reconstructed during replay.

## Constraints

1. **Key format**: Keys must be valid JSON object keys (strings)
2. **Value format**: Values are strings only (consistent with proto `map<string, string>`)
3. **Size limit**: Total metadata size capped at 64KB (configurable via server config)
4. **Key count**: Maximum 50 keys per execution
5. **Reserved prefixes**: Keys starting with `_flovyn_` are reserved for system use

## Future Considerations (Out of Scope)

1. **Typed Search Attributes**: Pre-defined, indexed attributes with specific types (like Temporal's SearchAttributes). Would require a separate `search_attributes` table and admin API for attribute registration.

2. **Metadata Updates**: Ability to modify metadata after execution starts. Current design is write-once at creation time.

3. **Metadata Inheritance**: Child workflows automatically inheriting parent's metadata.

## Migration Strategy

1. Add nullable `metadata` column (zero downtime)
2. Deploy new server code that persists metadata
3. Optionally add GIN indexes after observing query patterns
4. UI can start using metadata filters immediately
