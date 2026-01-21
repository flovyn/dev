# Implementation Plan: Metadata Schema Registry

**Design Document**: [20260109_metadata_schema_registry.md](../design/20260109_metadata_schema_registry.md)

**Status**: Completed (Phases 1-3)

## Overview

This plan implements the Metadata Schema Registry as specified in the design document. The feature allows frontends to discover metadata fields and their allowed values for workflow and task executions.

## Pre-Implementation Checklist

- [x] Review existing `metadata` JSONB implementation in `workflow_execution` and `task_execution`
- [x] Confirm no breaking changes to existing metadata filtering

---

## Phase 1: Database Schema & Domain Model

### 1.1 Create Migration

**File**: `flovyn-server/server/migrations/20260109183521_metadata_field_definition.sql`

- [x] Create `metadata_field_definition` table as specified in design doc
- [x] Add indexes for tenant, workflow_kind, task_kind lookups
- [x] Add constraints for scope validation, field type validation, enum requires values
- [x] Add unique index with COALESCE to handle NULL values properly

### 1.2 Add Domain Model

**File**: `flovyn-server/crates/core/src/domain/metadata_field_definition.rs`

- [x] Create `MetadataFieldDefinition` struct with `#[derive(Debug, Clone, FromRow)]`
- [x] Create `MetadataFieldType` enum with `Enum`, `Text`, `Number`, `Boolean` variants
- [x] Implement `as_str()` and `parse()` for `MetadataFieldType` (for database mapping)
- [x] Add `new()` constructor following existing patterns
- [x] Add helper methods: `field_type()`, `allowed_values_vec()`, `scope()`

**File**: `flovyn-server/crates/core/src/domain/mod.rs`

- [x] Export `MetadataFieldDefinition` and `MetadataFieldType`

### 1.3 Test: Verify Domain Model

- [x] Write unit test for `MetadataFieldType` conversion to/from string
- [x] Verify `new()` constructor sets correct defaults
- [x] Test scope calculation (global, workflow:kind, task:kind)

---

## Phase 2: Repository Layer

### 2.1 Create Repository

**File**: `flovyn-server/server/src/repository/metadata_field_definition_repository.rs`

- [x] Implement `MetadataFieldDefinitionRepository` struct with `PgPool`
- [x] Implement `create()` - insert new field definition
- [x] Implement `get()` - fetch by ID
- [x] Implement `get_by_tenant()` - fetch by ID and tenant
- [x] Implement `update()` - update existing field definition
- [x] Implement `delete()` - remove field definition
- [x] Implement `list_by_tenant()` - list all fields for a tenant
- [x] Implement `list_for_workflow()` - list fields applicable to a workflow kind (global + kind-specific, merged with DISTINCT ON)
- [x] Implement `list_for_task()` - list fields applicable to a task kind (global + kind-specific, merged with DISTINCT ON)
- [x] Implement `list_global()` - list only global fields

**File**: `flovyn-server/server/src/repository/mod.rs`

- [x] Export `MetadataFieldDefinitionRepository`

---

## Phase 3: REST API Endpoints

### 3.1 Create Handler Module

**File**: `flovyn-server/server/src/api/rest/metadata_fields.rs`

#### DTOs

- [x] `ListMetadataFieldsQuery` - query params: `workflow_kind`, `task_kind`
- [x] `CreateMetadataFieldRequest` - request body for POST
- [x] `UpdateMetadataFieldRequest` - request body for PUT
- [x] `MetadataFieldResponse` - single field response (camelCase)
- [x] `ListMetadataFieldsResponse` - list response with `fields` array

#### Handlers

- [x] `list_metadata_fields` - GET `/api/tenants/{tenant_slug}/metadata-fields`
  - Query params: `workflow_kind`, `task_kind`
  - Returns merged fields (global + kind-specific)
  - Authorization: list "MetadataFieldDefinition"

- [x] `create_metadata_field` - POST `/api/tenants/{tenant_slug}/metadata-fields`
  - Request body: field definition data
  - Returns created field with ID
  - Authorization: create "MetadataFieldDefinition"

- [x] `update_metadata_field` - PUT `/api/tenants/{tenant_slug}/metadata-fields/{field_id}`
  - Request body: updated field definition
  - Authorization: update "MetadataFieldDefinition"

- [x] `delete_metadata_field` - DELETE `/api/tenants/{tenant_slug}/metadata-fields/{field_id}`
  - Authorization: delete "MetadataFieldDefinition"

### 3.2 Register Routes

**File**: `flovyn-server/server/src/api/rest/mod.rs`

- [x] Add `pub mod metadata_fields;`
- [x] Register routes under `/api/tenants/:tenant_slug/metadata-fields`

### 3.3 OpenAPI Documentation

**File**: `flovyn-server/server/src/api/rest/openapi.rs`

- [x] Add tag `(name = "Metadata Fields", description = "Metadata field definition management")`
- [x] Register all DTOs in `components(schemas(...))`
- [x] Register all handlers in `paths(...)`

### 3.4 Test: REST API Integration

**File**: `flovyn-server/tests/integration/metadata_fields_tests.rs`

- [x] Test create global enum field
- [x] Test create workflow-scoped field
- [x] Test create task-scoped field
- [x] Test list metadata fields
- [x] Test update metadata field
- [x] Test delete metadata field
- [x] Test list with workflow_kind filter (merge behavior)
- [x] Test list with task_kind filter (merge behavior)
- [x] Test workflow-specific overrides global with same key
- [x] Test validation: invalid field type
- [x] Test validation: enum without allowed_values
- [x] Test validation: both workflow_kind and task_kind specified
- [x] Test unique constraint conflict (409 Conflict)

---

## Phase 4: Default Field Templates (Optional Enhancement)

**Status**: Deferred to future iteration

### 4.1 Create Seeding Utility

- [ ] Implement `default_global_fields()` returning common field definitions:
  - `env` (enum: dev, staging, prod)
  - `region` (enum: us-east, us-west, eu-west, ap-southeast)
  - `priority` (enum: low, normal, high, critical)

### 4.2 CLI Command for Seeding

- [ ] Add command to seed default fields for a tenant
- [ ] Skip fields that already exist (upsert logic)

---

## Files Created/Modified

| File | Action |
|------|--------|
| `flovyn-server/server/migrations/20260109183521_metadata_field_definition.sql` | Created |
| `flovyn-server/crates/core/src/domain/metadata_field_definition.rs` | Created |
| `flovyn-server/crates/core/src/domain/mod.rs` | Modified (add export) |
| `flovyn-server/server/src/repository/metadata_field_definition_repository.rs` | Created |
| `flovyn-server/server/src/repository/mod.rs` | Modified (add export) |
| `flovyn-server/server/src/api/rest/metadata_fields.rs` | Created |
| `flovyn-server/server/src/api/rest/mod.rs` | Modified (add module, routes) |
| `flovyn-server/server/src/api/rest/openapi.rs` | Modified (add DTOs, handlers, tag) |
| `flovyn-server/server/tests/integration/metadata_fields_tests.rs` | Created |
| `flovyn-server/server/tests/integration_tests.rs` | Modified (add test module) |

---

## Test Results

All 13 integration tests pass:

```
test metadata_fields_tests::test_create_global_enum_field ... ok
test metadata_fields_tests::test_create_workflow_scoped_field ... ok
test metadata_fields_tests::test_create_task_scoped_field ... ok
test metadata_fields_tests::test_list_metadata_fields ... ok
test metadata_fields_tests::test_update_metadata_field ... ok
test metadata_fields_tests::test_delete_metadata_field ... ok
test metadata_fields_tests::test_list_with_workflow_kind_filter_merge ... ok
test metadata_fields_tests::test_list_with_task_kind_filter_merge ... ok
test metadata_fields_tests::test_workflow_specific_overrides_global ... ok
test metadata_fields_tests::test_invalid_field_type_rejected ... ok
test metadata_fields_tests::test_enum_without_allowed_values_rejected ... ok
test metadata_fields_tests::test_both_workflow_and_task_kind_rejected ... ok
test metadata_fields_tests::test_duplicate_key_scope_rejected ... ok
```

---

## Rollback Plan

If issues arise:
1. Migration can be reverted by dropping the `metadata_field_definition` table
2. No breaking changes to existing metadata functionality
3. Feature is additive only - existing workflows/tasks remain unaffected

---

## Open Questions Resolution

From design document:

1. **Track field usage?** - Defer to future iteration. Not required for MVP.
2. **Inheritance for child workflows?** - Not implementing for MVP. Child workflows query their own kind.
3. **Field groups?** - Not implementing for MVP. Can add `group` column later if needed.
