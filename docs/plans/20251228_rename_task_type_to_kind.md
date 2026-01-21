# Implementation Plan: Rename task_type to kind

## Overview

The codebase has an inconsistency in naming:
- **Workflows**: Use `kind` consistently (proto, domain, REST API)
- **Tasks**: Use `task_type` / `taskType`, but `TaskCapability` already uses `kind`

This plan renames all `task_type` occurrences to `kind` for consistency with the workflow naming pattern.

## Design Reference

This is a refactoring task with no architectural decisions. The goal is naming consistency.

## Impact Analysis

### Files Affected

| Layer | Files | Changes |
|-------|-------|---------|
| Proto | `server/proto/flovyn.proto` | 3 fields |
| Generated | `flovyn-server/server/src/generated/flovyn.v1.rs` | Auto-generated after proto change |
| Domain | `flovyn-server/server/src/domain/task.rs` | 1 struct field + methods |
| Repository | `flovyn-server/server/src/repository/task_repository.rs` | SQL queries |
| REST API | `flovyn-server/server/src/api/rest/tasks.rs` | DTOs, query params |
| REST API | `flovyn-server/server/src/api/rest/workflows.rs` | Nested task response |
| gRPC | `flovyn-server/server/src/api/grpc/task_execution.rs` | Field access |
| gRPC | `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` | Field access |
| Metrics | `flovyn-server/server/src/metrics/mod.rs` | Label names |
| Database | New migration | Column rename |
| CLI | `flovyn-server/cli/src/commands/tasks.rs`, `flovyn-server/cli/src/output.rs` | Field names |
| REST Client | `flovyn-server/crates/rest-client/src/types.rs` | Field names |
| Tests | Multiple test files | Field references |

### Breaking Changes

1. **REST API**: JSON field changes from `taskType` to `kind`
2. **Query Parameters**: `?taskType=x` becomes `?kind=x`
3. **gRPC API**: Proto field names change (wire-compatible via field numbers)
4. **Database**: Column renamed in init schema

## TODO

### Phase 1: Database Schema
- [x] Update `flovyn-server/server/migrations/20251214220815_init.sql`:
  - Change column `task_type` to `kind` in `task_execution` table (line 91)

### Phase 2: Proto and Generated Code
- [x] Update `server/proto/flovyn.proto`:
  - `SubmitTaskRequest.task_type` (line 327) → `kind`
  - `TaskExecutionInfo.task_type` (line 367) → `kind`
  - `ScheduleTaskCommand.task_type` (line 531) → `kind`
- [x] Rebuild proto: `cargo build` (triggers build.rs)
- [x] Verify generated code in `flovyn-server/server/src/generated/flovyn.v1.rs`

### Phase 3: Domain Model
- [x] Update `flovyn-server/server/src/domain/task.rs`:
  - Rename field `task_type` to `kind` in `TaskExecution` struct
  - Update `new()` and `new_with_id()` parameters
  - Update `to_proto()` method

### Phase 4: Repository Layer
- [x] Update `flovyn-server/server/src/repository/task_repository.rs`:
  - All SQL queries referencing `task_type` column
  - Function parameters `task_type: Option<&str>` → `kind: Option<&str>`

### Phase 5: REST API Layer
- [x] Update `flovyn-server/server/src/api/rest/tasks.rs`:
  - `CreateTaskRequest.task_type` → `kind`
  - `TaskResponse.task_type` → `kind`
  - `ListTasksQuery.task_type` → `kind`
  - Update `From<&TaskExecution>` impl
  - Update tracing field names
- [x] Update `flovyn-server/server/src/api/rest/workflows.rs`:
  - `TaskExecutionSummary.task_type` → `kind`

### Phase 6: gRPC Handlers
- [x] Update `flovyn-server/server/src/api/grpc/task_execution.rs`:
  - All references to `.task_type` on proto messages
  - JSON event data fields
  - Tracing span fields
- [x] Update `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`:
  - All references to `.task_type` on proto messages
  - JSON event data fields

### Phase 7: Metrics
- [x] Update `flovyn-server/server/src/metrics/mod.rs`:
  - Rename label `task_type` → `kind` in:
    - `record_task_submitted()`
    - `record_task_completed()`
    - `record_task_failed()`

### Phase 8: CLI
- [x] Update `flovyn-server/cli/src/commands/tasks.rs`:
  - Command arguments and struct fields
- [x] Update `flovyn-server/cli/src/output.rs`:
  - Output field names

### Phase 9: REST Client Crate
- [x] Update `flovyn-server/crates/rest-client/src/types.rs`:
  - All `task_type` fields in request/response types

### Phase 10: Tests
- [x] Update integration tests:
  - `flovyn-server/server/tests/integration/standalone_tasks_tests.rs`
  - `flovyn-server/server/tests/integration/streaming_tests.rs`
  - `flovyn-server/server/tests/integration/oracle_tests.rs`
  - `flovyn-server/server/tests/integration/workflows_tests.rs`
- [x] Update model tests:
  - `flovyn-server/server/tests/model_tests/composite_workflow.rs`
  - `flovyn-server/server/tests/model_tests/recovery.rs`

### Phase 11: SDK - Rust (../sdk-rust)
- [x] Update proto file: `proto/flovyn.proto`
  - Same 3 fields as server proto
- [x] Update core domain code:
  - `flovyn-server/core/src/workflow/command.rs`: `WorkflowCommand::ScheduleTask.kind`
  - `flovyn-server/core/src/workflow/event.rs`: `with_task_kind()` method
  - `flovyn-server/core/src/worker/determinism.rs`: validation logic
  - `flovyn-server/core/src/client/task_execution.rs`: field access
- [x] Update SDK layer:
  - `flovyn-server/sdk/src/workflow/context_impl.rs`: schedule methods
  - `flovyn-server/sdk/src/worker/workflow_worker.rs`: command conversion
- [x] Update FFI layer:
  - `flovyn-server/ffi/src/command.rs`: FfiWorkflowCommand::ScheduleTask
  - `flovyn-server/ffi/src/context.rs`: schedule_task method
- [x] Update all test JSON data: `"taskType"` → `"kind"`
- [x] Verify: `cargo test --all` - all tests pass

### Phase 12: SDK - Kotlin (../sdk-kotlin)
- [x] Update all `taskType` parameter names → `kind`
  - `flovyn-server/core/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`
  - `flovyn-server/core/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`
  - `flovyn-server/core/src/main/kotlin/ai/flovyn/sdk/client/WorkflowHook.kt`
  - `flovyn-server/examples/src/main/kotlin/ai/flovyn/examples/OrderProcessing.kt`
- [x] Update README.md
- [x] Verify: `./gradlew test` - all tests pass

### Phase 13: Documentation
- [ ] Update design documents in `.dev/docs/design/` that reference `taskType` / `task_type`
  - These are historical records, consider adding a note about the rename

### Phase 14: Verification
- [x] Run unit tests: `./bin/dev/test.sh` - 210 tests passed
- [ ] Run integration tests: `cargo test --test integration_tests`
- [ ] Build Docker image: `./bin/dev/docker-build.sh`
- [ ] Run E2E tests: `./bin/dev/run-e2e-tests.sh`
- [ ] Verify OpenAPI spec: `./target/debug/export-openapi | jq '.paths'`

## Migration Strategy

### Database Schema

Modify the existing init migration directly since the schema hasn't been deployed to production.

### API Compatibility

This is a **breaking change** for API clients:
- REST: `taskType` → `kind` in JSON payloads
- REST: `?taskType=x` → `?kind=x` in query parameters
- gRPC: Field names change but field numbers preserved (wire-compatible)

Consider:
1. Version bump if following semver
2. ~~Update SDK clients (`sdk-rust`, others) if they exist~~ **DONE**: Updated both Rust and Kotlin SDKs
3. Notify API consumers of the breaking change

## Rollback Plan

If issues arise:
1. Revert code changes via git

## Notes

- The proto field numbers remain unchanged, so existing gRPC clients will continue to work at the wire level
- REST API changes are breaking and require client updates
- Metrics label changes may affect existing Grafana dashboards
