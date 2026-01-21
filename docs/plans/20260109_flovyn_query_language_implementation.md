# Implementation Plan: Flovyn Query Language (FQL)

Reference: [Design Document](./../design/20260109_flovyn_query_language.md)

**Status**: Completed (All Phases)

## Overview

This plan implements a JQL-style query language for filtering workflows, tasks, and definitions. The implementation follows a test-first approach, building incrementally from parser to API endpoints.

### Implementation Summary

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | FQL Parser Core | ✅ Complete |
| 2 | Integrate FQL with List Endpoints | ✅ Complete |
| 3 | Remove Legacy Filter Parameters | ✅ Complete |
| 4 | Saved Queries CRUD | ✅ Complete |
| 5 | Query Limits and Security | ✅ Complete |
| 6 | Autocomplete Support | ✅ Complete |

**Test Results**: 131 FQL unit tests passing, 13 saved queries integration tests passing

## Supported Entities and Fields

FQL supports querying **4 entity types**:

### Workflow Executions (`workflow`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Workflow execution ID |
| `kind` | string | Workflow type |
| `status` | enum | PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED |
| `queue` | string | Task queue name |
| `version` | string | Workflow version |
| `createdAt` | datetime | Creation timestamp |
| `startedAt` | datetime | Execution start timestamp |
| `completedAt` | datetime | Completion timestamp |
| `updatedAt` | datetime | Last update timestamp |
| `metadata.<key>` | any | Metadata field access |

### Task Executions (`task`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Task execution ID |
| `kind` | string | Task type |
| `status` | enum | PENDING, RUNNING, COMPLETED, FAILED, CANCELLED |
| `queue` | string | Task queue name |
| `attempt` | number | Current attempt number |
| `maxRetries` | number | Maximum retry count |
| `workflowId` | UUID | Parent workflow ID (null for standalone) |
| `createdAt` | datetime | Creation timestamp |
| `startedAt` | datetime | Execution start timestamp |
| `completedAt` | datetime | Completion timestamp |
| `metadata.<key>` | any | Metadata field access |

### Workflow Definitions (`workflowDefinition`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Definition ID |
| `kind` | string | Workflow type identifier |
| `name` | string | Human-readable name |
| `description` | string | Description |
| `timeoutSeconds` | number | Default timeout |
| `cancellable` | boolean | Whether cancellable |
| `latestVersion` | string | Latest registered version |
| `availabilityStatus` | enum | AVAILABLE, UNAVAILABLE, DEGRADED |
| `workerCount` | number | Number of supporting workers |
| `firstSeenAt` | datetime | First registration timestamp |
| `lastRegisteredAt` | datetime | Last worker registration |

### Task Definitions (`taskDefinition`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Definition ID |
| `kind` | string | Task type identifier |
| `name` | string | Human-readable name |
| `description` | string | Description |
| `timeoutSeconds` | number | Default timeout |
| `cancellable` | boolean | Whether cancellable |
| `availabilityStatus` | enum | AVAILABLE, UNAVAILABLE, DEGRADED |
| `workerCount` | number | Number of supporting workers |
| `firstSeenAt` | datetime | First registration timestamp |
| `lastRegisteredAt` | datetime | Last worker registration |

## Phase 1: FQL Parser Core

Build the lexer, parser, and AST in the `flovyn-core` crate as a reusable module.

### File Structure

```
crates/core/src/
├── fql/
│   ├── mod.rs          # Module exports
│   ├── lexer.rs        # Tokenizer
│   ├── parser.rs       # AST builder
│   ├── ast.rs          # AST types (Expr, Field, Value, etc.)
│   ├── validator.rs    # Field/value validation
│   └── sql.rs          # SQL generator
└── domain/
    └── mod.rs          # Add fql export
```

### TODO

- [x] **1.1** Create `flovyn-server/crates/core/src/fql/ast.rs` with AST types:
  - `Expr` enum (Comparison, Binary, Not, Group)
  - `Field` enum (Simple, Metadata)
  - `ComparisonOp` enum (Eq, Ne, Gt, Gte, Lt, Lte, In, NotIn, Contains, NotContains, IsNull, IsNotNull)
  - `BinaryOp` enum (And, Or)
  - `Value` enum (String, Number, Boolean, List, DateTime, RelativeTime, Function, Null)
  - `Query` struct (filter, order_by)
  - `OrderBy` struct (field, direction)

- [x] **1.2** Create `flovyn-server/crates/core/src/fql/lexer.rs`:
  - Define `Token` enum (keywords, operators, identifiers, literals, punctuation)
  - Implement `Lexer` struct with `tokenize(&str) -> Result<Vec<Token>, LexError>`
  - Handle: string literals (double quotes), numbers, identifiers, operators, keywords (AND, OR, NOT, IN, ORDER, BY, ASC, DESC, IS, NULL)
  - Handle relative time literals: `-7d`, `-24h`, `-30m`
  - Handle function calls: `NOW()`, `TODAY()`

- [x] **1.3** Write unit tests for lexer in `flovyn-server/crates/core/src/fql/lexer.rs`:
  - Test tokenizing simple expressions: `status = "FAILED"`
  - Test tokenizing complex expressions: `status IN ("PENDING", "RUNNING") AND createdAt >= -7d`
  - Test metadata fields: `metadata.customerId = "CUST-123"`
  - Test error cases: unterminated strings, invalid tokens

- [x] **1.4** Create `flovyn-server/crates/core/src/fql/parser.rs`:
  - Implement recursive descent parser
  - Precedence: NOT > AND > OR (similar to SQL)
  - Methods: `parse(&str) -> Result<Query, ParseError>`
  - Handle grouping with parentheses
  - Handle ORDER BY clause

- [x] **1.5** Write unit tests for parser:
  - Test simple comparisons
  - Test AND/OR combinations
  - Test NOT negation
  - Test parentheses grouping
  - Test ORDER BY
  - Test error recovery with position info

- [x] **1.6** Create `flovyn-server/crates/core/src/fql/validator.rs`:
  - Define `FieldRegistry` trait for valid fields per entity type
  - Implement `WorkflowExecutionRegistry` with fields (id, kind, status, queue, version, createdAt, etc.)
  - Implement `TaskExecutionRegistry` with fields (id, kind, status, queue, attempt, maxRetries, workflowId, etc.)
  - Implement `WorkflowDefinitionRegistry` with fields (id, kind, name, availabilityStatus, workerCount, firstSeenAt, etc.)
  - Implement `TaskDefinitionRegistry` with fields (id, kind, name, availabilityStatus, workerCount, firstSeenAt, etc.)
  - Validate enum values:
    - Execution status: PENDING|RUNNING|WAITING|COMPLETED|FAILED|CANCELLED
    - Definition availabilityStatus: AVAILABLE|UNAVAILABLE|DEGRADED
  - Validate type compatibility (createdAt requires datetime, attempt requires number, cancellable requires boolean)

- [x] **1.7** Write unit tests for validator:
  - Test valid workflow execution fields
  - Test valid task execution fields
  - Test valid workflow definition fields
  - Test valid task definition fields
  - Test invalid field names for each entity type
  - Test invalid enum values
  - Test type mismatches

- [x] **1.8** Create `flovyn-server/crates/core/src/fql/sql.rs`:
  - Implement `Query::to_sql(&self, entity: EntityType, param_offset: usize) -> (String, Vec<SqlParam>)`
  - Map field names to column names (camelCase -> snake_case)
  - Map metadata fields to JSONB access: `metadata->>'key'`
  - Handle relative time: `-7d` -> `NOW() - INTERVAL '7 days'`
  - Handle IN operator with parameterized arrays
  - Prevent SQL injection via parameterization only

- [x] **1.9** Write unit tests for SQL generator:
  - Test simple WHERE clause generation
  - Test AND/OR clause generation
  - Test metadata JSONB access
  - Test IN with array parameters
  - Test relative time conversion
  - Test ORDER BY generation

- [x] **1.10** Create `flovyn-server/crates/core/src/fql/mod.rs` exporting public API:
  - Re-export: `Query`, `Expr`, `Field`, `Value`, `ParseError`, `ValidationError`
  - Public function: `parse(query: &str) -> Result<Query, ParseError>`
  - Public function: `validate(query: &Query, entity: EntityType) -> Result<(), ValidationError>`

## Phase 2: Integrate FQL with Existing List Endpoints

Replace the ad-hoc `status`, `kind`, `metadata` query parameters with FQL support on existing endpoints. This provides backwards compatibility while enabling powerful queries.

### Current Limitations Being Addressed

| Endpoint | Current Params | Limitations |
|----------|----------------|-------------|
| `GET /workflows` | `status`, `kind`, `metadata={}` | Equality only, AND only, no dates |
| `GET /tasks` | `status`, `queue`, `kind`, `metadata={}` | Equality only, AND only, no dates |
| `GET /workflow-definitions` | `availabilityStatus` | Equality only, no text search |
| `GET /task-definitions` | `availabilityStatus` | Equality only, no text search |

### Migration Strategy

1. Add optional `query` parameter to existing endpoints
2. When `query` is present, ignore legacy filter params (`status`, `kind`, `metadata`)
3. Mark legacy params as deprecated in OpenAPI docs
4. Legacy params remain functional for backwards compatibility

### TODO

- [x] **2.1** Write integration tests for FQL on existing endpoints:
  - **Workflow executions:**
    - Test `GET /workflows?query=status = "FAILED"` returns same as `?status=FAILED`
    - Test `GET /workflows?query=status IN ("PENDING", "RUNNING")` (not possible with old params)
    - Test `GET /workflows?query=createdAt >= -7d` (not possible with old params)
    - Test `GET /workflows?query=metadata.env = "prod" AND status = "FAILED"`
    - Test `GET /workflows?query=...&status=COMPLETED` ignores `status` param when `query` present
  - **Task executions:**
    - Test `GET /tasks?query=status = "PENDING" AND attempt >= 2`
    - Test `GET /tasks?query=workflowId IS NULL` (standalone tasks)
  - **Workflow definitions:**
    - Test `GET /workflow-definitions?query=availabilityStatus = "AVAILABLE"`
    - Test `GET /workflow-definitions?query=name ~ "order" AND workerCount > 0`
  - **Task definitions:**
    - Test `GET /task-definitions?query=cancellable = true`
    - Test `GET /task-definitions?query=availabilityStatus != "UNAVAILABLE"`
  - **Common:**
    - Test invalid FQL returns 400 with error details
    - Test ORDER BY override: `GET /workflows?query=status = "FAILED" ORDER BY createdAt ASC`

- [x] **2.2** Update `ListWorkflowsQuery` in `flovyn-server/server/src/api/rest/workflows.rs`:
  ```rust
  pub struct ListWorkflowsQuery {
      /// FQL query string. When provided, overrides status/kind/metadata params.
      /// Example: `status = "FAILED" AND createdAt >= -7d ORDER BY createdAt DESC`
      pub query: Option<String>,

      /// [DEPRECATED] Use `query` param instead. Filter by workflow status.
      #[deprecated(note = "Use `query` param with FQL syntax")]
      pub status: Option<String>,

      /// [DEPRECATED] Use `query` param instead. Filter by workflow kind.
      #[deprecated(note = "Use `query` param with FQL syntax")]
      pub kind: Option<String>,

      // ... limit, offset remain unchanged

      /// [DEPRECATED] Use `query` param instead. Filter by metadata.
      #[deprecated(note = "Use `query` param with FQL syntax")]
      #[serde(default, deserialize_with = "deserialize_json_query")]
      pub metadata: Option<serde_json::Value>,
  }
  ```

- [x] **2.3** Update `list_workflows` handler logic:
  ```rust
  // If FQL query provided, use it exclusively
  if let Some(fql_query) = &query.query {
      let parsed = fql::parse(fql_query)?;
      fql::validate(&parsed, EntityType::Workflow)?;
      let (sql, params) = parsed.to_sql(EntityType::Workflow, tenant_id);
      // Execute FQL-based query
  } else {
      // Legacy path: use individual params (status, kind, metadata)
      // Existing implementation unchanged
  }
  ```

- [x] **2.4** Update `ListTasksQuery` in `flovyn-server/server/src/api/rest/tasks.rs`:
  - Add `query: Option<String>` parameter
  - Mark `status`, `queue`, `kind`, `metadata` as deprecated

- [x] **2.5** Update `list_tasks` handler with same FQL logic

- [x] **2.6** Update `ListWorkflowDefinitionsQuery` in `flovyn-server/server/src/api/rest/workflow_definitions.rs`:
  - Add `query: Option<String>` parameter
  - Mark `availability_status` as deprecated
  - Added `list_with_fql` method in WorkflowDefinitionRepository

- [x] **2.7** Update `list_workflow_definitions` handler with FQL logic

- [x] **2.8** Update `ListTaskDefinitionsQuery` in `flovyn-server/server/src/api/rest/task_definitions.rs`:
  - Add `query: Option<String>` parameter
  - Mark `availability_status` as deprecated
  - Added `list_with_fql` method in TaskDefinitionRepository

- [x] **2.9** Update `list_task_definitions` handler with FQL logic

- [x] **2.10** Update OpenAPI documentation:
  - N/A - Legacy parameters removed in Phase 3, OpenAPI auto-generated from structs

- [x] **2.11** Verify all Phase 2 integration tests pass (18 tests)

### Example API Usage (After Implementation)

```bash
# Old way (still works, but deprecated)
GET /api/tenants/acme/workflows?status=FAILED&kind=order-workflow

# New way with FQL
GET /api/tenants/acme/workflows?query=status = "FAILED" AND kind = "order-workflow"

# Powerful queries now possible
GET /api/tenants/acme/workflows?query=status IN ("PENDING", "RUNNING") AND createdAt >= -24h

GET /api/tenants/acme/workflows?query=(status = "FAILED" OR status = "CANCELLED") AND metadata.priority = "high" ORDER BY createdAt DESC

GET /api/tenants/acme/tasks?query=attempt >= 2 AND status != "COMPLETED"

# Definition queries
GET /api/tenants/acme/workflow-definitions?query=availabilityStatus = "AVAILABLE" AND workerCount > 0

GET /api/tenants/acme/task-definitions?query=name ~ "email" ORDER BY firstSeenAt DESC
```

## Phase 3: Remove Legacy Filter Parameters

After FQL is confirmed stable in production, remove the deprecated individual filter parameters to simplify the API.

**Prerequisites:**
- Phase 2 complete and deployed
- FQL working correctly in production for sufficient time
- No critical issues reported with FQL queries

### TODO

- [x] **3.1** Update integration tests to use FQL exclusively:
  - Updated tests in `workflows_tests.rs`, `standalone_tasks_tests.rs`, `metadata_tests.rs`
  - All filter tests now use FQL `query` parameter

- [x] **3.2** Remove legacy params from `ListWorkflowsQuery`:
  - Removed `status`, `kind`, `metadata` fields
  - Kept only `query`, `limit`, `offset`

- [x] **3.3** Remove legacy params from `ListTasksQuery`:
  - Removed `status`, `queue`, `kind`, `metadata` fields
  - Kept only `query`, `limit`, `offset`

- [x] **3.4** Remove legacy params from `ListWorkflowDefinitionsQuery`:
  - Removed `availability_status` field
  - Kept only `query`, `limit`, `offset`

- [x] **3.5** Remove legacy params from `ListTaskDefinitionsQuery`:
  - Removed `availability_status` field
  - Kept only `query`, `limit`, `offset`

- [x] **3.6** Simplify handler logic:
  - Removed legacy filter code paths in all 4 list handlers
  - Handlers now always use FQL (empty query returns all results)
  - `deserialize_json_query` helper is now unused (can be removed)

- [x] **3.7** Update repository methods:
  - Legacy `list_with_filters`, `list`, `count` methods now unused
  - `list_with_fql` methods used for all queries

- [x] **3.8** Update OpenAPI documentation:
  - Query structs updated with FQL-only parameters
  - Documentation reflects new API

- [x] **3.9** Verify all Phase 3 tests pass
  - All 18 FQL tests pass
  - All workflow list tests pass (6 tests)
  - All task list tests pass (6 tests)

## Phase 4: Saved Queries CRUD

Implement saved query persistence and management.

**Status**: Completed

### TODO

- [x] **4.1** Write integration tests for saved queries CRUD (13 tests):
  - Test create saved query
  - Test list saved queries (filter by entity)
  - Test get saved query by ID
  - Test update saved query
  - Test delete saved query
  - Test execute saved query (workflows and tasks)
  - Test duplicate name returns 409
  - Test validation on create (invalid query returns 400)
  - Test validation on create (invalid entity type returns 400)

- [x] **4.2** Create migration `flovyn-server/server/migrations/20260109220631_saved_query.sql`

- [x] **4.3** Create domain model `flovyn-server/crates/core/src/domain/saved_query.rs`:
  - `SavedQuery` struct with FromRow derive
  - `SavedQueryEntityType` enum (Workflow, Task, WorkflowDefinition, TaskDefinition)

- [x] **4.4** Export from `flovyn-server/crates/core/src/domain/mod.rs`

- [x] **4.5** Create `flovyn-server/server/src/repository/saved_query_repository.rs`:
  - `create()`, `get()`, `get_by_tenant()`, `list()`, `update()`, `delete()`, `increment_usage()`

- [x] **4.6** Export from `flovyn-server/server/src/repository/mod.rs`

- [x] **4.7** Create `flovyn-server/server/src/api/rest/saved_queries.rs` with handlers:
  - `list_saved_queries`, `get_saved_query`, `create_saved_query`
  - `update_saved_query`, `delete_saved_query`, `execute_saved_query`

- [x] **4.8** Add routes in `flovyn-server/server/src/api/rest/mod.rs`

- [x] **4.9** Register in OpenAPI with "Saved Queries" tag

- [x] **4.10** Verify all Phase 4 integration tests pass (13 tests)

## Phase 5: Query Limits and Security

Add resource limits, rate limiting, and security hardening.

**Status**: Completed

### TODO

- [x] **5.1** Write tests for query limits:
  - Test query length limit (4KB)
  - Test max expressions limit (50)
  - Test max IN list size (100)
  - Test max results limit (1000)
  - Unit tests in `flovyn-server/crates/core/src/fql/limits.rs`

- [x] **5.2** Implement `QueryLimits` configuration in `flovyn-server/crates/core/src/fql/limits.rs`:
  - `QueryLimits` struct with default values
  - `LimitError` enum for limit violations
  - Check methods: `check_query_length()`, `check_expression_count()`, `check_in_list_size()`, `check_result_count()`

- [x] **5.3** Add limit checks in parser and validator:
  - Added `parse_with_limits()` in parser.rs
  - Added `validate_with_limits()` in validator.rs
  - Added `expression_count()` and `in_list_sizes()` to AST types

- [x] **5.4** Add SQL query timeout using `SET statement_timeout`
  - Added `timeout_seconds: Option<u64>` parameter to all FQL list methods
  - Implemented using `SET LOCAL statement_timeout` within transactions
  - Default timeout of 30 seconds from `QueryLimits::default()`
  - Updated repositories: workflow, task, workflow_definition, task_definition
  - Updated REST handlers to pass timeout to repository methods

- [x] **5.5** Verify all Phase 5 tests pass (6 limit tests + 131 total FQL tests)

## Phase 6: Autocomplete Support

Provide autocomplete suggestions for query building UI.

**Status**: Completed

### TODO

- [x] **6.1** Write unit tests for autocomplete in `flovyn-server/crates/core/src/fql/autocomplete.rs`:
  - Test field suggestions for partial input
  - Test operator suggestions after field
  - Test value suggestions for enum fields (status)
  - Test value suggestions for datetime fields
  - Test value suggestions for boolean fields
  - Test context-aware suggestions (9 unit tests)

- [x] **6.2** Create autocomplete module `flovyn-server/crates/core/src/fql/autocomplete.rs`:
  - `Suggestion` struct with value, label, type, description
  - `SuggestionType` enum (Field, Operator, Value, Keyword, Function)
  - `get_field_suggestions()`, `get_operator_suggestions()`, `get_value_suggestions()`
  - `get_logical_suggestions()`, `get_suggestions()` (context-aware)

- [x] **6.3** Create REST handlers in `flovyn-server/server/src/api/rest/fql.rs`:
  - `POST /api/tenants/:tenant_slug/fql/autocomplete` - context-aware suggestions
  - `GET /api/tenants/:tenant_slug/fql/fields` - all fields for entity type
  - `GET /api/tenants/:tenant_slug/fql/operators` - all FQL operators
  - `GET /api/tenants/:tenant_slug/fql/values` - values for specific field

- [x] **6.4** Integrate with metadata schema registry:
  - Query `metadata_field_definition` table for metadata field suggestions
  - Include allowed_values for enum metadata fields
  - Return true/false for boolean metadata fields
  - Filter by entity type scope (workflow vs task)

- [x] **6.5** Add routes and OpenAPI registration:
  - Routes added in `flovyn-server/server/src/api/rest/mod.rs`
  - DTOs and handlers registered in `flovyn-server/server/src/api/rest/openapi.rs`
  - "FQL" tag added for API documentation

- [x] **6.6** Verify autocomplete tests pass (9 unit tests + 131 total FQL tests)

## Testing Strategy

### Unit Tests (Parser)
- Location: `flovyn-server/crates/core/src/fql/*.rs` (inline `#[cfg(test)]` modules)
- Focus: Lexer tokenization, parser AST building, SQL generation correctness
- Run: `cargo test -p flovyn-core`

### Integration Tests (API)
- Location: `flovyn-server/server/tests/integration/fql_tests.rs`
- Focus: End-to-end query execution, saved queries CRUD, error handling
- Run: `cargo test --test integration_tests fql`

### Test Data Setup
Integration tests should:
1. Create test workflows/tasks with known metadata
2. Execute FQL queries
3. Verify result counts and content match expectations

## Verification Commands

After each phase, verify with:

```bash
# Run unit tests
./bin/dev/test.sh fql

# Run integration tests
cargo test --test integration_tests fql

# Verify OpenAPI - check saved-queries and fql endpoints
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("saved-queries") or contains("fql")))'
./target/debug/export-openapi | jq '.tags[] | select(.name | contains("Saved") or contains("FQL"))'

# Build check
./bin/dev/build.sh
```

## Dependencies

No new external dependencies required. Uses existing:
- `regex` - For lexer patterns (already in workspace)
- `chrono` - For datetime handling (already in workspace)
- `sqlx` - For query execution (already in workspace)

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| SQL injection via metadata keys | Validate metadata keys against alphanumeric pattern, use JSONB operators |
| Query timeout causing connection pool exhaustion | Use separate connection with statement_timeout |
| Complex queries causing slow scans | Add query complexity scoring, warn on expensive queries |
| Parser edge cases | Comprehensive unit test coverage with fuzzing |

## Out of Scope

Per design document non-goals:
- Joins across entities
- Aggregations (GROUP BY, COUNT, SUM)
- Subqueries
- Query parameterization placeholders (open question)
- Cross-tenant template queries (open question)
- Query history tracking (open question)
- Result export to CSV/JSON (open question)
