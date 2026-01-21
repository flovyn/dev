# Schedules Implementation Plan

**Date:** 2026-01-11
**Design Document:** [20260111_schedules.md](../design/20260111_schedules.md)
**Status:** In Progress (Backend complete, Frontend pending)

## Progress Summary

**Phase 1 (Domain & Database)**: ✅ Complete
- All domain models, migration, repositories, and cron utilities implemented
- 21 unit tests passing (6 schedule domain + 15 cron)

**Phase 2 (Scheduler Integration)**: ✅ Complete
- `fire_due_schedules()` integrated into scheduler loop
- Workflow and task target execution working
- Overlap policies: skip, allow, cancel_previous
- Missed run policies: skip (5 min tolerance), execute_once
- Fixed `find_and_lock_due_schedules()` to preserve original `next_run_at` for missed run calculation
- Added `spawn_additional_server()` to test harness for multi-instance testing
- 9 scheduler integration tests passing (including concurrent scheduler test)

**Phase 3 (REST API)**: ✅ Complete
- Full CRUD for schedules (create, list, get, update, delete)
- Action endpoints (pause, resume, trigger)
- Schedule runs history endpoint
- All validation (cron, timezone, unique names, future dates)
- OpenAPI annotations and route registration
- 16 integration tests passing

**Phase 4 (Remove scheduled_at)**: ✅ Complete
- Removed `scheduled_at` from task domain model, repository, REST API, CLI, and rest-client types
- Updated all integration tests to remove `scheduled_at` references
- Deleted `test_rest_create_task_scheduled` test (no longer applicable)
- Created migration `20260111202056_drop_task_scheduled_at.sql` to drop column and recreate index

**Phase 5 (Frontend UI)**: ⏳ Pending
- Schedules list page with DataGrid
- Detail panel for viewing/managing schedules
- Create/Edit dialogs with cron input and timezone picker
- Runs history view
- Navigation sidebar integration

## Overview

This plan implements the schedule system as designed. The implementation is split into 5 phases:
1. Domain & Database foundation
2. Scheduler integration (core execution loop)
3. REST API with full CRUD
4. Cleanup of legacy `scheduled_at` field
5. Frontend UI in flovyn-app

## Pre-Implementation Notes

### Codebase Patterns Discovered

- **Scheduler loop**: Uses `tokio::select!` with interval-based checks (see `scheduler.rs`)
- **Distributed locking**: Use `SELECT FOR UPDATE SKIP LOCKED` for safe concurrent access across instances (same pattern as task polling)
- **Worker notification**: Call `WorkerNotifier.notify_work_available()` after creating work
- **REST routes**: Mount at `/api/tenants/{tenant_slug}/...`
- **Task `scheduled_at`**: Already exists - will be removed entirely (no backward compat needed)

### Dependencies to Add

```toml
cron = "0.12"
chrono-tz = "0.10"
```

### Critical Design Decisions

1. **Overlap policy `cancel_previous`**: Requires ability to cancel running workflows/tasks. Current cancel implementation exists - need to verify it works for this use case.

2. **`created_by` field**: Will extract from `AuthenticatedPrincipal` in request context (already available in handlers).

3. **Human-readable cron**: Use `croner` or implement simple descriptions for common patterns. Defer complex descriptions to Phase 3.

---

## Phase 1: Domain & Database Foundation

### TODO

- [x] **1.1** Add `cron` and `chrono-tz` dependencies to `flovyn-server/server/Cargo.toml`
  - Note: `cron` crate uses 6-field format (with seconds). Added `normalize_cron_expression()` to convert 5-field to 6-field.
- [x] **1.2** Create domain models in `flovyn-server/crates/core/src/domain/schedule.rs`:
  - `Schedule`, `ScheduleRun`, `ScheduleType`, `ScheduleTarget`
  - `MissedRunPolicy`, `OverlapPolicy`, `ScheduleRunStatus`
  - Unit tests for serialization/deserialization (6 tests passing)
- [x] **1.3** Create database migration `flovyn-server/server/migrations/20260111191038_schedules.sql`:
  - `schedule` table with all fields from design
  - `schedule_run` table for execution history
  - Indexes for scheduler polling and tenant queries
- [x] **1.4** Create `flovyn-server/server/src/repository/schedule_repository.rs`:
  - `create()`, `get()`, `get_by_name()`, `list()`, `count()`, `update()`, `delete()`
  - `pause()`, `resume()` - for enable/disable with next_run_at management
  - `find_and_lock_due_schedules()` - atomically selects and locks due schedules using `SELECT FOR UPDATE SKIP LOCKED`, clears `next_run_at` to prevent re-selection
  - `update_after_execution()` - update `next_run_at`, increment `run_count`, optionally disable
- [x] **1.5** Create `flovyn-server/server/src/repository/schedule_repository.rs` (combined with 1.4):
  - `ScheduleRunRepository` in same file
  - `create()`, `complete()`, `list_by_schedule()`, `count_by_schedule()`
  - `find_running_by_schedule()` - for overlap policy check
- [x] **1.6** Implement cron utilities in `flovyn-server/server/src/util/cron.rs`:
  - `calculate_next_run()` - handles Once and Recurring types
  - `validate_cron_expression()` - parse and validate
  - `validate_timezone()` - check IANA timezone validity
  - `describe_cron()` - human-readable descriptions for common patterns
  - `next_run_local()` - convert UTC to schedule's timezone for display
  - 15 unit tests passing covering all scenarios

### Implementation Notes
- Domain models in `crates/core` (shared), cron utilities in `server/src/util` (server-specific)
- `cron` crate v0.15 requires 6+ field expressions (sec, min, hour, dom, month, dow, [year])
- Added `normalize_cron_expression()` to auto-prepend "0" for seconds to 5-field expressions

---

## Phase 2: Scheduler Integration

### TODO

- [x] **2.1** Add `schedule_check_interval` to `SchedulerConfig`:
  - Duration (default 1 second)
- [x] **2.2** Add schedule repositories to `Scheduler::run()`:
  - `ScheduleRepository`, `ScheduleRunRepository`, `TaskRepository`
- [x] **2.3** Implement `fire_due_schedules()` in `scheduler.rs`:
  - Call `find_and_lock_due_schedules()` - atomically locks schedules and clears `next_run_at`
  - For each schedule:
    - Create `ScheduleRun` record
    - Execute target (workflow or task creation)
    - Complete run record with result
    - Calculate and update `next_run_at` (or set `enabled = false` for one-time schedules)
- [x] **2.4** Implement `execute_schedule_target()`:
  - For `ScheduleTarget::Workflow`: create workflow directly via `WorkflowRepository`
  - For `ScheduleTarget::Task`: create task directly via `TaskRepository`
  - Notify workers after creation via `WorkerNotifier`
- [x] **2.5** Add `fire_due_schedules()` to scheduler's `tokio::select!` loop
- [x] **2.6** Implement overlap policies:
  - `Skip`: Check for running executions, skip if found (creates SKIPPED run record)
  - `Allow`: Always proceed (no check needed)
  - `CancelPrevious`: Find running execution, cancel it, then proceed
- [x] **2.7** Implement missed run policies:
  - `Skip`: Only process if `next_run_at` is within tolerance window (5 minutes), uses `update_next_run_only()` to not increment `run_count`
  - `ExecuteOnce`: If missed, execute once then calculate next

### Implementation Notes
- Created `ScheduleError` enum for schedule execution errors
- Workflow/task creation uses `WorkflowExecution::new()` and `TaskExecution::new()` directly
- Structured logging added for schedule execution start/complete/fail

### Integration Tests

Added to `flovyn-server/tests/integration/schedules_tests.rs`:

- [x] **T2.1** `test_scheduler_one_time_schedule_fires` - verifies one-time schedule fires and is disabled afterward
- [x] **T2.2** `test_scheduler_recurring_schedule_recalculates` - verifies recurring schedule fires and recalculates next_run_at
- [x] **T2.3** `test_scheduler_paused_schedule_does_not_fire` - verifies paused schedules don't execute
- [x] **T2.4** `test_overlap_policy_skip` - verifies schedule run is skipped when previous run is still running
- [x] **T2.5** `test_overlap_policy_allow` - verifies schedule runs proceed even with running executions
- [x] **T2.6** `test_missed_run_policy_skip` - verifies runs older than 5 min tolerance are skipped without incrementing run_count
- [x] **T2.7** `test_missed_run_policy_execute_once` - verifies missed runs still execute with execute_once policy
- [x] **T2.8** `test_overlap_policy_cancel_previous` - verifies previous workflow is cancelled and new run proceeds
- [x] **T2.9** `test_concurrent_schedulers_no_duplicate_execution` - verifies `SELECT FOR UPDATE SKIP LOCKED` prevents duplicate execution across multiple server instances

---

## Phase 3: REST API

### TODO

- [x] **3.1** Create request/response DTOs in `flovyn-server/server/src/api/rest/schedules.rs`:
  - `CreateScheduleRequest`, `UpdateScheduleRequest`
  - `ScheduleResponse`, `ScheduleRunResponse`
  - `ListSchedulesResponse`, `ListScheduleRunsResponse`
  - Include `next_run_at_local` in response (convert from UTC)
- [x] **3.2** Implement CRUD handlers:
  - `POST /schedules` - create schedule, calculate initial `next_run_at`
  - `GET /schedules` - list with pagination
  - `GET /schedules/{id}` - get single schedule
  - `PUT /schedules/{id}` - update schedule, recalculate `next_run_at`
  - `DELETE /schedules/{id}` - delete schedule and cascade to runs
- [x] **3.3** Implement action handlers:
  - `POST /schedules/{id}/pause` - set `enabled = false`, clear `next_run_at`
  - `POST /schedules/{id}/resume` - set `enabled = true`, recalculate `next_run_at`
  - `POST /schedules/{id}/trigger` - execute immediately, return created execution
- [x] **3.4** Implement history endpoint:
  - `GET /schedules/{id}/runs` - list execution history with pagination
- [x] **3.5** Add validation:
  - Name uniqueness per tenant
  - Cron expression validity
  - Timezone validity (IANA format)
  - One-time `run_at` must be in future
- [x] **3.6** Extract `created_by` from `AuthenticatedPrincipal`:
  - Format as `"{type}:{principal_id}"` (e.g., `"user:john@example.com"`)
- [x] **3.7** Add human-readable cron description:
  - Implemented in `describe_cron()` with common patterns
  - Returns descriptions like "Every hour", "Daily at 09:30", etc.
- [x] **3.8** Register routes in `flovyn-server/server/src/api/rest/mod.rs`
- [x] **3.9** Add OpenAPI annotations:
  - All handlers with `#[utoipa::path]`
  - Register in `openapi.rs` paths and schemas
  - Tag: `"Schedules"`

### Implementation Notes
- Created `ScheduleTypeDto` and `ScheduleTargetDto` to match API serialization with domain types
- Authorization uses existing `CanAuthorize` trait with "Schedule" as resource type
- Trigger endpoint creates workflow/task directly and notifies workers

### Integration Tests

Created `flovyn-server/tests/integration/schedules_tests.rs` - all 16 tests passing:

- [x] **T3.1** `test_create_one_time_schedule`
- [x] **T3.2** `test_create_recurring_schedule`
- [x] **T3.3** `test_create_schedule_invalid_cron`
- [x] **T3.4** `test_create_schedule_invalid_timezone`
- [x] **T3.5** `test_create_schedule_past_run_at`
- [x] **T3.6** `test_create_schedule_duplicate_name`
- [x] **T3.7** `test_list_schedules`
- [x] **T3.8** `test_get_schedule`
- [x] **T3.9** `test_update_schedule`
- [x] **T3.10** `test_delete_schedule`
- [x] **T3.11** `test_pause_schedule`
- [x] **T3.12** `test_resume_schedule`
- [x] **T3.13** `test_trigger_schedule_workflow`
- [x] **T3.14** `test_trigger_schedule_task`
- [x] **T3.15** `test_list_schedule_runs`
- [x] **T3.16** `test_schedule_tenant_isolation`

---

## Phase 4: Remove Legacy `scheduled_at`

Since backward compatibility is not a concern, we remove the field completely.

### TODO

- [x] **4.1** Remove `scheduled_at` from task domain model (`flovyn-server/crates/core/src/domain/task.rs`):
  - Removed field from `TaskExecution` struct
  - Removed from `TaskExecution::new()` and `TaskExecution::new_with_id()` parameters
  - Removed `is_ready()` method
- [x] **4.2** Remove `scheduled_at` from task repository (`flovyn-server/server/src/repository/task_repository.rs`):
  - Removed from INSERT statements
  - Removed from SELECT field lists
  - Updated `find_lock_and_mark_running()` - removed `scheduled_at` filter and ordering
- [x] **4.3** Remove `scheduled_at` from REST API (`flovyn-server/server/src/api/rest/tasks.rs`):
  - Removed from `CreateTaskRequest`
  - Removed from `TaskResponse`
- [x] **4.4** Remove `scheduled_at` from task launcher service
- [x] **4.5** Remove `scheduled_at` from gRPC task execution and workflow dispatch
- [x] **4.6** Create migration to drop column:
  - Migration: `20260111202056_drop_task_scheduled_at.sql`
  - Drops index `idx_task_standalone_poll`
  - Drops column `scheduled_at` from `task_execution`
  - Recreates index without `scheduled_at`
- [x] **4.7** Update CLI and rest-client types:
  - Removed from `flovyn-server/cli/src/commands/tasks.rs`
  - Removed from `flovyn-server/cli/src/output.rs`
  - Removed from `flovyn-server/crates/rest-client/src/types.rs`
- [x] **4.8** Update integration tests:
  - Removed all `scheduled_at: None` from test files
  - Deleted `test_rest_create_task_scheduled` test

### Tests

- [x] **T4.1** Verify task creation works without `scheduled_at` (existing tests pass)
- [x] **T4.2** Verify task polling works without `scheduled_at` logic (existing tests pass)

---

## Phase 5: Frontend UI Implementation

This phase adds the Schedules UI to the flovyn-app, following existing UX patterns from Workflows, Tasks, and Settings pages.

### Reference: Existing UX Patterns

The frontend follows these established patterns:
- **Page structure**: `PageContainer` + `PageHeader` with action buttons on the right
- **Data display**: `DataGrid` component with column templates for custom cell rendering
- **Filtering**: `FQLFilterBar` for query-based filtering (optional for schedules)
- **Detail panel**: Slide-out panel (400px width) for viewing/editing item details
- **Create dialog**: Modal dialog with form fields and loading/success/error states
- **Navigation**: Collapsible sidebar items with parent → children structure
- **Actions**: Inline buttons (Run, Edit) and destructive actions in detail panel

### TODO

#### 5.1 API Client Generation

- [ ] **5.1.1** Add schedule endpoints to OpenAPI spec (server-side, if not already)
- [ ] **5.1.2** Regenerate `@workspace/api` types and hooks:
  - `useListSchedules`, `useGetSchedule`, `useCreateSchedule`, `useUpdateSchedule`, `useDeleteSchedule`
  - `usePauseSchedule`, `useResumeSchedule`, `useTriggerSchedule`
  - `useListScheduleRuns`
  - Types: `Schedule`, `ScheduleRun`, `ScheduleType`, `ScheduleTarget`, etc.

#### 5.2 Navigation

- [ ] **5.2.1** Add "Schedules" to sidebar in `flovyn-server/apps/web/components/app-sidebar.tsx`:
  ```tsx
  // In mainNavItems array, after Tasks:
  {
    href: `/org/${orgSlug}/schedules`,
    label: 'Schedules',
    icon: Calendar,  // from lucide-react
  },
  ```

#### 5.3 Schedules List Page

- [ ] **5.3.1** Create `flovyn-server/apps/web/app/org/[orgSlug]/schedules/page.tsx`:
  - Use `PageContainer` and `PageHeader`
  - "Create Schedule" button in header
  - `SchedulesDataGrid` component for list display
  - Refresh button
  - Optional: FQL filter bar for filtering by name, enabled, target type

- [ ] **5.3.2** Create `flovyn-server/apps/web/components/schedules/SchedulesDataGrid.tsx`:
  - Columns:
    | Column | Width | Template | Sortable |
    |--------|-------|----------|----------|
    | Name | 200 | NameCell (name + description) | Yes |
    | Type | 120 | TypeCell (badge: "One-time" / "Recurring") | Yes |
    | Target | 180 | TargetCell (icon + kind) | Yes |
    | Status | 100 | StatusCell (badge: Enabled/Paused/Completed) | Yes |
    | Next Run | 150 | NextRunCell (relative time or "—") | Yes |
    | Last Run | 150 | LastRunCell (relative time or "Never") | Yes |
    | Run Count | 80 | plain text | Yes |
    | Actions | 100 | ActionsCell (Trigger button) | No |
  - Row click → open detail panel (not navigate)
  - Use `CopyableId` for ID display if needed

#### 5.4 Schedule Detail Panel

- [ ] **5.4.1** Create `flovyn-server/apps/web/components/schedules/ScheduleDetailPanel.tsx`:
  - Fixed width: 400px, slide from right
  - Sections:
    1. **Header**: Schedule name, close button
    2. **Status**: Badge showing Enabled/Paused/Completed
    3. **Schedule Info**:
       - Type (One-time: show `run_at`, Recurring: show cron + timezone)
       - Human-readable cron description (from API `cronDescription`)
       - Next run (UTC + local time)
       - Last run
       - Run count
    4. **Target Info**:
       - Target type (Workflow/Task)
       - Kind
       - Queue (if set)
       - Input (collapsible JSON viewer)
       - Metadata (if set)
    5. **Policies**:
       - Missed run policy
       - Overlap policy
    6. **Actions**:
       - Trigger Now (primary button)
       - Pause/Resume (toggle based on state)
       - Edit (opens edit dialog)
       - Delete (destructive, with confirmation)
    7. **Recent Runs**: Last 5 runs with status, time, link to execution

#### 5.5 Create Schedule Dialog

- [ ] **5.5.1** Create `flovyn-server/apps/web/components/schedules/CreateScheduleDialog.tsx`:
  - Multi-step or tabbed form:

    **Step 1: Basic Info**
    - Name (required, text input)
    - Description (optional, textarea)

    **Step 2: Schedule Type**
    - Radio: One-time / Recurring
    - One-time: Date/time picker for `runAt` (future only)
    - Recurring:
      - Cron expression input with validation
      - Timezone dropdown (searchable, common timezones at top)
      - Optional: End date picker
      - Preview: Show next 3 run times

    **Step 3: Target**
    - Radio: Workflow / Task
    - Kind dropdown (fetch from definitions API)
    - Queue (optional, text input with default)
    - Input JSON editor (optional, with schema validation if available)
    - Metadata key-value editor (optional)

    **Step 4: Policies (Advanced)**
    - Missed run policy: Skip (default) / Execute Once
    - Overlap policy: Skip (default) / Allow / Cancel Previous

  - States: `form` → `loading` → `success` / `error`
  - On success: Close dialog, refresh list

- [ ] **5.5.2** Create cron input helper component `flovyn-server/apps/web/components/schedules/CronInput.tsx`:
  - Text input for cron expression
  - Real-time validation (show error if invalid)
  - Show human-readable description below input
  - Quick presets dropdown: "Every hour", "Every day at 9 AM", "Every Monday at 9 AM", etc.

- [ ] **5.5.3** Create timezone picker component `flovyn-server/apps/web/components/schedules/TimezonePicker.tsx`:
  - Searchable combobox
  - Common timezones at top (UTC, America/New_York, America/Los_Angeles, Europe/London)
  - Show current time in selected timezone as preview

#### 5.6 Edit Schedule Dialog

- [ ] **5.6.1** Create `flovyn-server/apps/web/components/schedules/EditScheduleDialog.tsx`:
  - Same form as Create, pre-populated with existing values
  - Cannot change schedule type after creation (One-time ↔ Recurring)
  - Recalculates `next_run_at` on save if cron/timezone changed

#### 5.7 Schedule Runs History

- [ ] **5.7.1** Create `flovyn-server/apps/web/app/org/[orgSlug]/schedules/[scheduleId]/runs/page.tsx`:
  - Full page view of schedule run history
  - Link from detail panel "View all runs"

- [ ] **5.7.2** Create `flovyn-server/apps/web/components/schedules/ScheduleRunsDataGrid.tsx`:
  - Columns:
    | Column | Width | Template |
    |--------|-------|----------|
    | Scheduled At | 150 | DateTime |
    | Started At | 150 | DateTime |
    | Duration | 100 | DurationCell |
    | Status | 120 | StatusBadge (Running/Completed/Failed/Skipped) |
    | Target | 150 | Link to workflow/task execution |
    | Error | 200 | Truncated error message (if failed) |
  - Row click → navigate to target execution (if completed)

#### 5.8 Confirmation Dialogs

- [ ] **5.8.1** Create `flovyn-server/apps/web/components/schedules/DeleteScheduleDialog.tsx`:
  - Warning: "This will delete the schedule and all its run history"
  - Require typing schedule name to confirm (for recurring schedules with runs)

- [ ] **5.8.2** Pause confirmation (inline or simple dialog):
  - "Pause this schedule? It won't run until resumed."

#### 5.9 Status Badges

- [ ] **5.9.1** Create `flovyn-server/apps/web/components/schedules/ScheduleStatusBadge.tsx`:
  - Enabled: Green badge
  - Paused: Gray badge
  - Completed: Blue badge (one-time schedule that has run)
  - Expired: Orange badge (recurring with passed `end_at`)

- [ ] **5.9.2** Create `flovyn-server/apps/web/components/schedules/ScheduleRunStatusBadge.tsx`:
  - Running: Blue with spinner
  - Completed: Green
  - Failed: Red
  - Skipped: Gray

### File Structure (Frontend)

```
apps/web/
├── app/org/[orgSlug]/schedules/
│   ├── page.tsx                    # List page
│   └── [scheduleId]/
│       └── runs/
│           └── page.tsx            # Runs history page
├── components/schedules/
│   ├── SchedulesDataGrid.tsx       # Main list grid
│   ├── ScheduleDetailPanel.tsx     # Detail slide-out panel
│   ├── CreateScheduleDialog.tsx    # Create form dialog
│   ├── EditScheduleDialog.tsx      # Edit form dialog
│   ├── DeleteScheduleDialog.tsx    # Delete confirmation
│   ├── ScheduleRunsDataGrid.tsx    # Runs history grid
│   ├── ScheduleStatusBadge.tsx     # Status badge component
│   ├── ScheduleRunStatusBadge.tsx  # Run status badge
│   ├── CronInput.tsx               # Cron expression input with validation
│   ├── TimezonePicker.tsx          # Timezone combobox
│   └── TargetInput.tsx             # Workflow/Task target selector
```

### Integration Tests (E2E)

- [ ] **T5.1** `flovyn-server/tests/e2e/schedules.spec.ts`:
  - Navigate to schedules page
  - Create one-time schedule
  - Create recurring schedule
  - Verify schedule appears in list
  - Open detail panel
  - Trigger schedule manually
  - Pause/resume schedule
  - Delete schedule

### Implementation Notes

1. **API hooks**: Use the generated `@workspace/api` hooks (e.g., `useListSchedules`) following the pattern in workflows/tasks pages
2. **Optimistic updates**: Consider optimistic updates for pause/resume/trigger actions
3. **Polling**: For running schedules, poll for status updates (or use SSE if available)
4. **Cron validation**: Use a lightweight cron parser on the frontend for real-time validation (e.g., `cron-parser` npm package)
5. **Timezone handling**: Use `Intl.DateTimeFormat` for displaying times in the schedule's timezone

---

## Observability (Throughout Phases)

### TODO

- [ ] **O1** Add structured logging for schedule operations:
  - Schedule created/updated/deleted
  - Schedule execution started/completed/failed
  - Include: `schedule_id`, `schedule_name`, `tenant_id`, `target_type`
- [ ] **O2** Add metrics (if metrics infrastructure exists):
  - `flovyn_schedules_total{tenant, enabled}` - gauge of schedule counts
  - `flovyn_schedule_runs_total{tenant, status, target_type}` - counter
  - `flovyn_schedule_run_latency_seconds{tenant}` - histogram

---

## File Structure Summary

### Backend (flovyn-server)

```
server/src/
├── domain/
│   ├── schedule.rs           # Schedule, ScheduleRun, enums
│   ├── schedule_test.rs      # Unit tests
│   ├── cron_utils.rs         # Cron parsing, next-run calculation
│   └── cron_utils_test.rs    # Unit tests
├── repository/
│   ├── schedule_repository.rs
│   └── schedule_run_repository.rs
├── api/rest/
│   └── schedules.rs          # Handlers, DTOs
├── scheduler.rs              # Modified to add schedule firing
└── migrations/
    ├── YYYYMMDDHHMMSS_schedules.sql
    └── YYYYMMDDHHMMSS_drop_scheduled_at.sql

tests/integration/
├── schedules_scheduler_test.rs
└── schedules_api_test.rs
```

### Frontend (flovyn-app)

```
apps/web/
├── app/org/[orgSlug]/schedules/
│   ├── page.tsx                    # Schedules list page
│   └── [scheduleId]/
│       └── runs/
│           └── page.tsx            # Schedule runs history
├── components/schedules/
│   ├── SchedulesDataGrid.tsx       # List with columns
│   ├── ScheduleDetailPanel.tsx     # Slide-out detail view
│   ├── CreateScheduleDialog.tsx    # Create form
│   ├── EditScheduleDialog.tsx      # Edit form
│   ├── DeleteScheduleDialog.tsx    # Delete confirmation
│   ├── ScheduleRunsDataGrid.tsx    # Runs history grid
│   ├── ScheduleStatusBadge.tsx     # Enabled/Paused/Completed
│   ├── ScheduleRunStatusBadge.tsx  # Running/Completed/Failed/Skipped
│   ├── CronInput.tsx               # Cron expression with validation
│   ├── TimezonePicker.tsx          # Searchable timezone selector
│   └── TargetInput.tsx             # Workflow/Task target form

packages/api/src/
└── (regenerated)                   # Schedule types and hooks
```

---

## Implementation Order

1. **Phase 1** (domain, DB, repository) - foundation
2. **Phase 2** scheduler tests first, then implement
3. **Phase 3** API tests first, then implement
4. **Phase 4** cleanup (remove `scheduled_at`)
5. **Phase 5** frontend UI implementation:
   - 5.1 Regenerate API client with schedule endpoints
   - 5.2 Add navigation item
   - 5.3-5.4 List page + detail panel (core functionality)
   - 5.5-5.6 Create/Edit dialogs
   - 5.7-5.9 Runs history and supporting components

Each phase should be fully tested before moving to the next.
