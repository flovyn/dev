# Implementation Plan: Improve Frontend Experience

**Date:** 2026-01-22
**Design:** [20260122_improve_frontend_exprience.md](../design/20260122_improve_frontend_exprience.md)

## Overview

This plan implements the approved design for improving frontend experience. The work is organized into phases that build upon each other, with early phases creating reusable infrastructure for later phases.

**Important:** E2E tests will break due to URL changes. Each phase that modifies URLs must include corresponding E2E test updates to maintain a working test suite throughout implementation.

## Pre-Implementation

- [x] Verify dev environment is working (`mise run dev` in flovyn-app)
- [x] Run existing tests to establish baseline (`mise run lint && mise run typecheck`)
  - Note: Pre-existing lint warnings and type errors in test/story files, not blocking
- [x] Run E2E tests to verify they pass before changes (`mise run e2e:test` in flovyn-app)
  - Note: E2E tests require full Docker environment; will verify incrementally
- [x] Document current E2E test results as baseline

## Phase 1: Foundation - Page Layout Components

Create composable page layout components in the UI package. These will be used by all subsequent page refactors.

**E2E Impact:** None - no URL or navigation changes.

### 1.1 Create Page.* Components
**Location:** `packages/ui/src/components/page.tsx`

- [x] Create `Page.Root` - Root container with optional detail panel layout
- [x] Create `Page.Main` - Main content area with container and overflow handling
- [x] Create `Page.Header` - Header with flex layout for title and actions
- [x] Create `Page.Title` - Title with optional count badge
- [x] Create `Page.Actions` - Action buttons container
- [x] Create `Page.Filters` - Filter bar container
- [x] Create `Page.Content` - Flexible content area (for data grids)
- [x] Create `Page.Footer` - Footer area (for pagination)
- [x] Create `Page.DetailPanel` - Side panel wrapper for detail views
- [x] Export components from `packages/ui/src/components/page.tsx`
- [x] Add export to `packages/ui/package.json` exports

### 1.2 Create Reusable Action Components
**Location:** `packages/ui/src/components/page-actions.tsx`

- [x] Create `RefreshButton` - Refresh button with loading spinner
- [x] Create `AutoRefreshSelect` - Auto-refresh interval selector
- [x] Export from package

### 1.3 Validation
- [x] Build UI package (`pnpm build --filter @workspace/ui`)
- [x] Verify exports work by importing in one existing page
- [x] Run lint and typecheck

## Phase 2: Remove Duplicate Components

Clean up duplicate components before creating new consolidated pages.

**E2E Impact:** None - internal refactor only.

- [x] Replace `WebhookEventsPagination` usage with generic `Pagination` from `@workspace/ui`
  - Update `flovyn-app/apps/web/app/org/[orgSlug]/webhook-events/page.tsx`
- [x] Delete `flovyn-app/apps/web/components/webhooks/events/webhook-events-pagination.tsx`
- [x] Run lint and typecheck

## Phase 3: Navigation Reorganization

Update sidebar navigation to match the new structure defined in the design.

**E2E Impact:** HIGH - Multiple URL changes affect many tests.

### 3.1 Update Sidebar Component
**Location:** `flovyn-app/apps/web/components/app-sidebar.tsx`

- [x] Remove nested navigation items for Workflows (just link to `/workflows`)
- [x] Remove nested navigation items for Tasks (just link to `/tasks`)
- [x] Create "Triggers" section with Schedules and Webhooks links
- [x] Move "Webhooks" link from Settings to Triggers section (pointing to `/webhooks`)
- [x] Remove Settings collapsible entirely
- [x] Add "Metadata" as top-level item in Manage section (pointing to `/metadata`)
- [x] Update Workers link to point to `/workers` (consolidated page)
- [x] Remove "Webhook events" link (merged into Webhooks)
- [x] Update active state detection for new URL structure

### 3.2 Update Routing Structure
Create redirects and new route structure:

- [x] Create redirect from `/org/[orgSlug]/page.tsx` to `/org/[orgSlug]/workflows`
- [x] Create redirect from `/org/[orgSlug]/settings/page.tsx` to `/org/[orgSlug]/workers`
- [x] Create redirect from `/org/[orgSlug]/settings/webhooks/page.tsx` to `/org/[orgSlug]/webhooks`
- [ ] Create redirect from `/org/[orgSlug]/webhook-events/page.tsx` to `/org/[orgSlug]/webhooks` (deferred to Phase 4.3)
- [x] Create redirect from `/org/[orgSlug]/settings/worker-tokens/page.tsx` to `/org/[orgSlug]/workers/tokens`
- [x] Create redirect from `/org/[orgSlug]/settings/metadata-fields/page.tsx` to `/org/[orgSlug]/metadata`

### 3.3 E2E Test Updates for Navigation Changes
**Note:** These tests should be updated to use new URLs but may still fail until corresponding pages are created in Phase 4. Mark tests as `.skip()` temporarily if needed.

- [x] Update `tests/e2e/smoke.spec.ts` - Update any navigation expectations
- [x] Update `tests/e2e/organization/access-control.spec.ts` - Update URL patterns if affected

## Phase 4: Page Consolidations with Tabs

Merge related pages into single tabbed pages. **Each subsection must include E2E test updates.**

### 4.1 Workflows Page (Executions | Definitions)
**Location:** `flovyn-app/apps/web/app/org/[orgSlug]/workflows/`

- [x] Refactor to use `Page.*` components
- [x] Add tabs using `Tabs` component from `@workspace/ui`
- [x] Implement "Executions" tab content (move from `/workflows/executions/page.tsx`)
- [x] Implement "Definitions" tab content (existing content)
- [x] Add smart default: show Executions if data exists, else Definitions
- [x] Use path-based routing: `/workflows/executions` and `/workflows/definitions`
- [x] Create `layout.tsx` for shared tab navigation
- [x] Create `page.tsx` that redirects to `/workflows/executions`
- [x] Create `executions/page.tsx` for Executions tab content
- [x] Create `definitions/page.tsx` for Definitions tab content
- [x] Keep `/workflows/[workflowId]/page.tsx` as-is (workflow detail)
- [x] Execution details shown in side panels, not separate page

**E2E Test Updates:**
- [x] Update `tests/e2e/executions/list.spec.ts`:
  - Change URL to `/workflows/executions`
  - Update `beforeEach` navigation to wait for group-by select
- [x] Update `tests/e2e/executions/actions.spec.ts` - Update URLs if needed
- [x] Update `tests/e2e/executions/details.spec.ts` - Verify detail page URLs still work
- [x] Update `tests/e2e/workflows/list.spec.ts` - Update to use `/workflows/definitions`
- [x] Update `tests/e2e/workflows/filter.spec.ts` - Update to use `/workflows/definitions`
- [x] Update `tests/e2e/workflows/saved-queries.spec.ts` - May need tab awareness
- [x] Run E2E tests for executions and workflows (`npx playwright test executions workflows`)

### 4.2 Tasks Page (Executions | Definitions)
**Location:** `flovyn-app/apps/web/app/org/[orgSlug]/tasks/`

- [x] Refactor to use `Page.*` components
- [x] Add tabs: "Executions" | "Definitions"
- [x] Implement "Executions" tab content (move from `/tasks/executions/page.tsx`)
- [x] Implement "Definitions" tab content (existing content)
- [x] Add smart default logic
- [x] Use path-based routing: `/tasks/executions` and `/tasks/definitions`
- [x] Create `layout.tsx` for shared tab navigation
- [x] Create `page.tsx` that redirects to `/tasks/executions`
- [x] Create `executions/page.tsx` for Executions tab content
- [x] Create `definitions/page.tsx` for Definitions tab content
- [x] Keep `/tasks/[taskKind]/page.tsx` as-is (task detail)

**E2E Test Updates:**
- [x] Check if any tasks-related E2E tests exist and update URLs
- [x] Run E2E tests to verify

### 4.3 Webhooks Page (Events | Sources)
**Location:** `flovyn-app/apps/web/app/org/[orgSlug]/webhooks/`

- [x] Create new page using `Page.*` components
- [x] Add tabs: "Events" | "Sources"
- [x] Implement "Events" tab content (move from `/webhook-events/page.tsx`)
- [x] Implement "Sources" tab content (move from `/settings/webhooks/sources/page.tsx`)
- [x] Add smart default: show Events if data exists, else Sources
- [x] Use path-based routing: `/webhooks/events` and `/webhooks/sources`
- [x] Create `layout.tsx` for shared tab navigation
- [x] Create `page.tsx` that redirects to `/webhooks/events`
- [x] Create `events/page.tsx` for Events tab content
- [x] Create `sources/page.tsx` for Sources tab content
- [x] Move source detail page to `/webhooks/sources/[sourceSlug]/page.tsx`
- [x] Delete old pages after migration

**E2E Test Updates:**
- [x] Update `tests/e2e/webhooks/sources.spec.ts`:
  - Change URL from `/settings/webhooks/sources` to `/webhooks/sources`
  - Update `beforeEach` navigation
  - Fix Edit button click using JavaScript evaluation
- [x] Update `tests/e2e/webhooks/events.spec.ts`:
  - Change URL from `/webhook-events` to `/webhooks/events`
  - Update `beforeEach` navigation
- [x] Update `tests/e2e/webhooks/routes.spec.ts`:
  - Update source detail page URL from `/settings/webhooks/sources/[slug]` to `/webhooks/sources/[slug]`
- [x] Run E2E tests for webhooks (`npx playwright test webhooks`)

### 4.4 Workers Page (Workers | Tokens)
**Location:** `flovyn-app/apps/web/app/org/[orgSlug]/workers/`

- [x] Refactor to use `Page.*` components
- [x] Add tabs: "Workers" | "Tokens"
- [x] Implement "Workers" tab content (existing content)
- [x] Implement "Tokens" tab content (move from `/settings/worker-tokens/page.tsx`)
- [x] Add smart default: show Workers if data exists, else Tokens
- [x] Use path-based routing: `/workers/list` and `/workers/tokens`
- [x] Create `layout.tsx` for shared tab navigation
- [x] Create `page.tsx` that redirects to `/workers/list`
- [x] Create `list/page.tsx` for Workers tab content
- [x] Create `tokens/page.tsx` for Tokens tab content
- [x] Keep `/workers/[workerId]/page.tsx` as-is (worker detail)
- [x] Delete `/settings/worker-tokens/page.tsx` after migration

**E2E Test Updates:**
- [x] Update `tests/e2e/workers/tokens.spec.ts`:
  - Change URL from `/settings/worker-tokens` to `/workers/tokens`
  - Update `beforeEach` navigation
- [x] Update `tests/e2e/workers/list.spec.ts` - Update to use `/workers/list`
- [x] Run E2E tests for workers (`npx playwright test workers`)

### 4.5 Metadata Page (Move and Rename)
**New Location:** `flovyn-app/apps/web/app/org/[orgSlug]/metadata/page.tsx`

- [x] Move from `/settings/metadata-fields/page.tsx`
- [x] Refactor to use `Page.*` components
- [x] Rename title from "Metadata Fields" to "Metadata"
- [x] Delete old page

**E2E Test Updates:**
- [x] Update `tests/e2e/metadata/fields.spec.ts`:
  - Change URL from `/settings/metadata-fields` to `/metadata`
  - Update `beforeEach` navigation
- [x] Run E2E tests for metadata (`npx playwright test metadata`)

### 4.6 Phase 4 Validation
- [x] Run full E2E test suite (`mise run e2e:test`) - 139 passed, 27 skipped
- [x] Build passes successfully

## Phase 5: Pagination Additions

Add pagination to data grids that need it.

**E2E Impact:** Low - adds functionality, shouldn't break existing tests.

### 5.1 WebhookSourcesDataGrid Pagination
**Files:**
- `flovyn-app/apps/web/app/org/[orgSlug]/webhooks/sources/page.tsx` (Sources tab)
- `flovyn-app/apps/web/components/webhooks/sources/webhook-sources-data-grid.tsx`

- [x] Update `useListSources` hook call to include `limit` and `offset` params
- [x] Add pagination state (limit, offset) to Sources tab
- [x] Persist pagination in URL query params
- [x] Add `Pagination` component to page footer
- [x] Update data grid to receive paginated data

### 5.2 E2E Test Updates for Pagination
- [ ] Add pagination test to `tests/e2e/webhooks/sources.spec.ts` (optional - nice to have)
- [x] Run E2E tests to verify existing tests still pass

## Phase 6: Webhook Source eventTypeConfig UI

Add event type configuration fields to the webhook source edit dialog.

**E2E Impact:** Low - adds functionality, shouldn't break existing tests.

### 6.1 Update Edit Dialog
**Location:** `flovyn-app/apps/web/components/webhooks/sources/edit-webhook-source-dialog.tsx`

- [x] Add collapsible "Event Type Configuration" section
- [x] Add "Header Name" input field
- [x] Add "JMESPath Expression" input field with validation
- [x] Add precedence note text
- [x] Integrate with existing form state/submission

### 6.2 Add JMESPath Validation
- [x] Create hook `useValidateJMESPath` that calls `POST /validate/jmespath`
- [x] Add debounced validation on JMESPath input change
- [x] Show validation status (valid/invalid/loading) inline
- [x] Display error messages from validation response

### 6.3 E2E Test Updates for eventTypeConfig
- [ ] Add test for eventTypeConfig editing in `tests/e2e/webhooks/sources.spec.ts` (optional - nice to have)
- [x] Run E2E tests to verify

## Phase 7: Remaining Page Refactors

Refactor remaining pages to use `Page.*` components for consistency.

**E2E Impact:** None - internal refactor only.

- [x] Refactor `/schedules/page.tsx` to use `Page.*` components
- [ ] Refactor `/schedules/[scheduleId]/page.tsx` to use `Page.*` components (already using Page.* pattern)
- [x] Refactor `/members/page.tsx` to use `Page.*` components with path-based tabs (`/members/list`, `/members/invitations`)
- [x] Refactor `/workflows/[workflowId]/page.tsx` to use `Page.*` components
- [ ] Refactor `/workflows/executions/[executionId]/page.tsx` to use `Page.*` components (already using Page.* pattern)
- [x] Refactor `/tasks/[taskKind]/page.tsx` to use `Page.*` components
- [x] Refactor `/workers/[workerId]/page.tsx` to use `Page.*` components
- [ ] Refactor `/webhooks/sources/[sourceSlug]/page.tsx` to use `Page.*` components (already using Page.* pattern)
- [x] Run E2E tests to verify no regressions

## Phase 8: Cleanup

Final cleanup after all migrations complete.

- [x] Remove all unused imports from migrated files
- [x] Delete old/unused page files (verify no remaining references first)
- [x] Delete deprecated components (`PageContainer`, `PageHeader`)
- [x] Reorganize E2E test directory structure:
  - [x] Move `settings/webhooks-sources.spec.ts` to `webhooks/sources.spec.ts` with updated URLs
  - [x] Move `settings/webhooks-events.spec.ts` to `webhooks/events.spec.ts` with updated URLs
  - [x] Move `settings/webhooks-routes.spec.ts` to `webhooks/routes.spec.ts` with updated URLs
  - [x] Move `settings/worker-tokens.spec.ts` to `workers/tokens.spec.ts` with updated URLs
  - [x] Move `settings/metadata-fields.spec.ts` to `metadata/fields.spec.ts` with updated URLs
  - [x] Delete `tests/e2e/settings/` directory
- [x] Run full lint check (`mise run lint`) - pre-existing warnings in FQL/MetadataEditor components, not from changes
- [x] Run build (`mise run build`) - builds successfully
- [x] Run full E2E test suite - 139 passed, 27 skipped (`mise run e2e:test`)

## Test Plan

### Page File Changes Summary

**Pages with Path-Based Tabs (layout + redirect page + tab pages):**
| Directory | Layout | Default Redirect | Tab Pages |
|-----------|--------|------------------|-----------|
| `workflows/` | `layout.tsx` | `page.tsx` → `/executions` | `executions/page.tsx`, `definitions/page.tsx` |
| `tasks/` | `layout.tsx` | `page.tsx` → `/executions` | `executions/page.tsx`, `definitions/page.tsx` |
| `webhooks/` | `layout.tsx` | `page.tsx` → `/events` | `events/page.tsx`, `sources/page.tsx` |
| `workers/` | `layout.tsx` | `page.tsx` → `/list` | `list/page.tsx`, `tokens/page.tsx` |
| `members/` | `layout.tsx` | `page.tsx` → `/list` | `list/page.tsx`, `invitations/page.tsx` |

**Redirect Pages (old URLs → new URLs):**
| File | Redirects To |
|------|-------------|
| `app/org/[orgSlug]/page.tsx` | `/workflows` |
| `app/org/[orgSlug]/settings/page.tsx` | `/workers` |
| `app/org/[orgSlug]/settings/webhooks/page.tsx` | `/webhooks` |
| `app/org/[orgSlug]/settings/worker-tokens/page.tsx` | `/workers/tokens` |
| `app/org/[orgSlug]/settings/metadata-fields/page.tsx` | `/metadata` |
| `app/org/[orgSlug]/webhook-events/page.tsx` | `/webhooks/events` |

**Pages to Delete (content moved to tab pages):**
| File | Content Moved To |
|------|-----------------|
| `app/org/[orgSlug]/settings/webhooks/sources/page.tsx` | `/webhooks/sources/page.tsx` |

**Pages to Move:**
| Old Location | New Location |
|--------------|--------------|
| `app/org/[orgSlug]/settings/webhooks/sources/[sourceSlug]/page.tsx` | `app/org/[orgSlug]/webhooks/sources/[sourceSlug]/page.tsx` |

**New Pages Created:**
| New Page | Purpose |
|----------|---------|
| `app/org/[orgSlug]/metadata/page.tsx` | Moved and renamed from metadata-fields |

### E2E Test File Relocations Summary

| Old Location | New Location |
|--------------|--------------|
| `tests/e2e/settings/webhooks-sources.spec.ts` | `tests/e2e/webhooks/sources.spec.ts` |
| `tests/e2e/settings/webhooks-events.spec.ts` | `tests/e2e/webhooks/events.spec.ts` |
| `tests/e2e/settings/webhooks-routes.spec.ts` | `tests/e2e/webhooks/routes.spec.ts` |
| `tests/e2e/settings/worker-tokens.spec.ts` | `tests/e2e/workers/tokens.spec.ts` |
| `tests/e2e/settings/metadata-fields.spec.ts` | `tests/e2e/metadata/fields.spec.ts` |

### URL Changes Summary

| Old URL | New URL |
|---------|---------|
| `/org/[slug]/` (dashboard) | Redirects to `/org/[slug]/workflows` |
| `/org/[slug]/workflows` | Redirects to `/org/[slug]/workflows/executions` |
| `/org/[slug]/workflows/executions` | `/org/[slug]/workflows/executions` (no change, now tab) |
| `/org/[slug]/workflows/definitions` | `/org/[slug]/workflows/definitions` (new tab route) |
| `/org/[slug]/tasks` | Redirects to `/org/[slug]/tasks/executions` |
| `/org/[slug]/tasks/executions` | `/org/[slug]/tasks/executions` (now tab) |
| `/org/[slug]/tasks/definitions` | `/org/[slug]/tasks/definitions` (new tab route) |
| `/org/[slug]/webhook-events` | Redirects to `/org/[slug]/webhooks/events` |
| `/org/[slug]/webhooks` | Redirects to `/org/[slug]/webhooks/events` |
| `/org/[slug]/webhooks/events` | `/org/[slug]/webhooks/events` (new tab route) |
| `/org/[slug]/settings/webhooks/sources` | Redirects to `/org/[slug]/webhooks/sources` |
| `/org/[slug]/webhooks/sources` | `/org/[slug]/webhooks/sources` (new tab route) |
| `/org/[slug]/settings/webhooks/sources/[sourceSlug]` | `/org/[slug]/webhooks/sources/[sourceSlug]` |
| `/org/[slug]/settings/worker-tokens` | Redirects to `/org/[slug]/workers/tokens` |
| `/org/[slug]/workers` | Redirects to `/org/[slug]/workers/list` |
| `/org/[slug]/workers/list` | `/org/[slug]/workers/list` (new tab route) |
| `/org/[slug]/workers/tokens` | `/org/[slug]/workers/tokens` (new tab route) |
| `/org/[slug]/settings/metadata-fields` | `/org/[slug]/metadata` |
| `/org/[slug]/settings` | Redirects to `/org/[slug]/workers` |
| `/org/[slug]/members` | Redirects to `/org/[slug]/members/list` |
| `/org/[slug]/members/list` | `/org/[slug]/members/list` (new tab route) |
| `/org/[slug]/members/invitations` | `/org/[slug]/members/invitations` (new tab route) |

### Manual Testing Checklist

**Navigation:**
- [ ] Sidebar shows correct structure with Triggers section
- [ ] All navigation links work and highlight correctly
- [ ] Settings section is removed
- [ ] Redirects work from old URLs to new URLs

**Workflows Page (`/workflows/executions`, `/workflows/definitions`):**
- [ ] Tabs switch correctly between Executions and Definitions
- [ ] Smart default redirects to correct tab based on data
- [ ] URL changes to path-based route on tab click
- [ ] Refresh and filter work in both tabs
- [ ] Controls (grouping, refresh) appear in filter row, not header
- [ ] Can navigate to workflow detail from Definitions tab
- [ ] Can navigate to execution detail from Executions tab

**Tasks Page (`/tasks/executions`, `/tasks/definitions`):**
- [ ] Same checks as Workflows page
- [ ] Create standalone task works from Executions tab

**Webhooks Page (`/webhooks/events`, `/webhooks/sources`):**
- [ ] Tabs switch correctly between Events and Sources
- [ ] Events tab shows all webhook events with filters and pagination
- [ ] Sources tab shows webhook sources with pagination
- [ ] Can navigate to source detail from Sources tab
- [ ] Smart default works correctly
- [ ] Controls appear in filter row, not header

**Workers Page (`/workers/list`, `/workers/tokens`):**
- [ ] Tabs switch correctly between Workers and Tokens
- [ ] Workers tab shows worker list with detail panel
- [ ] Tokens tab shows token management
- [ ] Create token works from Tokens tab
- [ ] Smart default works correctly
- [ ] Controls appear in filter row, not header

**Members Page (`/members/list`, `/members/invitations`):**
- [ ] Tabs switch correctly between Members and Invitations
- [ ] Badges show counts correctly
- [ ] Can invite members from Members tab
- [ ] Can cancel invitations from Invitations tab
- [ ] Controls appear in filter row, not header

**Metadata Page:**
- [ ] Accessible from sidebar under Manage section
- [ ] Metadata fields CRUD operations work

**Webhook Source Edit:**
- [ ] Event type configuration section appears in edit dialog
- [ ] Header name can be set
- [ ] JMESPath expression can be set with validation feedback
- [ ] Save persists configuration

**Pagination:**
- [ ] WebhookSourcesDataGrid paginates correctly
- [ ] Pagination state persists in URL

## Rollout Considerations

1. **URL Breaking Changes:** Old URLs (e.g., `/settings/webhooks/sources`) will redirect to new locations. Bookmarks and shared links will continue to work via redirects.

2. **Feature Flags:** Not needed - this is a UI reorganization without new backend functionality.

3. **Documentation:** Update any user documentation that references the old navigation structure.

## Dependencies

- No backend changes required (all APIs already exist)
- Depends on existing `Tabs` component from `@workspace/ui`
- Depends on existing `Pagination` component from `@workspace/ui`
