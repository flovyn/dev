# Implementation Plan: E2E Testing with Playwright and Testcontainers

**Date**: 2026-01-15
**Design Document**: [20260115_e2e_testing_playwright_testcontainers.md](../design/20260115_e2e_testing_playwright_testcontainers.md)
**Status**: In Progress
**Last Updated**: 2026-01-16

### Progress Summary
- **Phase 1 (Infrastructure)**: Complete - All containers, migrations, harness, and fixtures working
- **Phase 1B (Test Attributes)**: Registration and login forms complete, other forms pending
- **Phase 2 (Auth Tests)**: Registration (10/10), Login (8/8), Logout (3/3) passing. Device-auth tests removed (feature not implemented)
- **Phase 3-6**: Tests written but pending verification with full infrastructure

## Overview

This plan implements the E2E testing infrastructure as specified in the design document. The implementation follows a test-first approach where we verify each component works before moving to the next.

## Prerequisites

Before starting implementation:
- [x] Verify Docker is installed and running (`docker --version`)
- [x] Verify flovyn-server can be built (`cargo build --release` in `../flovyn-server`)
- [x] Verify sdk-rust examples exist (`../sdk-rust/examples/patterns`)

### Docker Configuration

This project uses **Docker** for container management. Testcontainers works out of the box with Docker - no special configuration needed.

### Build Docker Images Locally

The E2E tests require Docker images for flovyn-server and the patterns worker. These must be **built locally** from source with the same names specified in the design document (do NOT pull from private registries).

**Create the build script** at `flovyn-app/bin/build-e2e-images.sh`:

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Image registry prefix (matches design document)
REGISTRY="${FLOVYN_REGISTRY:-rg.fr-par.scw.cloud/flovyn}"

echo "Building E2E test Docker images..."

# Build flovyn-server
echo "Building ${REGISTRY}/flovyn-server:latest..."
docker build -t "${REGISTRY}/flovyn-server:latest" \
  --build-arg FEATURES=all-plugins \
  -f "$ROOT_DIR/../flovyn-server/Dockerfile" \
  "$ROOT_DIR/../flovyn-server"

# Build patterns worker
echo "Building ${REGISTRY}/patterns-worker:latest..."
docker build -t "${REGISTRY}/patterns-worker:latest" \
  -f "$ROOT_DIR/../sdk-rust/examples/patterns/Dockerfile" \
  "$ROOT_DIR/../sdk-rust"

echo "All E2E images built successfully!"
```

**Run the build script:**
```bash
chmod +x bin/build-e2e-images.sh
./bin/build-e2e-images.sh
```

- [x] Create `flovyn-app/bin/build-e2e-images.sh` script (as specified in design doc)
- [x] Create Dockerfile for patterns-worker at `../sdk-rust/examples/patterns/Dockerfile` (as specified in design doc)
- [x] Build images locally: `./bin/build-e2e-images.sh`
- [x] Verify images exist: `docker images | grep flovyn`

---

## Phase 1: Infrastructure Setup

### 1.1 Install Dependencies

- [x] Add `@playwright/test` to devDependencies in root `package.json`
- [x] Add `testcontainers` to devDependencies
- [x] Add `@testcontainers/postgresql` to devDependencies
- [x] Run `pnpm install`
- [x] Run `pnpm exec playwright install chromium` to install browser

### 1.2 Create Directory Structure

- [x] Create `tests/e2e/` directory
- [x] Create `tests/e2e/helpers/` directory
- [x] Create `bin/` directory for scripts

### 1.3 Playwright Configuration

- [x] Create `playwright.config.ts` at root (see design doc for config)
- [x] Add `test:e2e` script to root `package.json`: `"test:e2e": "playwright test"`
- [x] Verify Playwright runs with empty test suite

### 1.4 Test Harness - Container Functions

Create `flovyn-app/tests/e2e/harness.ts` with container orchestration:

- [x] Implement `startPostgresApp()` - PostgreSQL for Better Auth
- [x] Implement `startPostgresServer()` - PostgreSQL for flovyn-server
- [x] Implement `startNats()` - NATS with JetStream
- [x] Test: Verify each container starts and is reachable

### 1.5 Test Harness - Database Migrations

- [x] Implement `runAppMigrations()` - Run Better Auth migrations against postgres-app
- [x] Implement `runServerMigrations()` - Run flovyn-server migrations
- [x] Test: Verify migrations complete successfully

### 1.6 Test Harness - Server & Worker Startup

- [x] Implement `startFlovynServer()` using GenericContainer with image
- [x] Implement `startSampleWorker()` using GenericContainer with patterns-worker image
- [x] Implement `waitForHealth()` polling function
- [x] Test: Verify server responds to `/_/health` endpoint

### 1.7 Test Harness - Next.js App Startup

- [x] Implement `startNextApp()` to spawn `pnpm dev --filter web`
- [x] Configure environment variables (DATABASE_URL, FLOVYN_SERVER_URL)
- [x] Test: Verify Next.js app responds at localhost:3333 (fixed port for stability)

### 1.8 Test Harness - Lifecycle Management

- [x] Implement singleton `getHarness()` function
- [x] Create `flovyn-app/tests/e2e/global-setup.ts` to initialize harness
- [x] Create `flovyn-app/tests/e2e/global-teardown.ts` to cleanup
- [x] Implement signal handlers for SIGINT/SIGTERM cleanup
- [x] Test: Run harness setup/teardown, verify no orphaned containers

### 1.9 Cleanup Script

- [x] Create `flovyn-app/bin/cleanup-e2e-containers.sh` (using Podman)
- [x] Make script executable: `flovyn-app/chmod +x bin/cleanup-e2e-containers.sh`
- [x] Test: Run script, verify it removes labeled containers

### 1.10 Custom Fixtures

- [x] Create `flovyn-app/tests/e2e/fixtures.ts` with custom test fixtures
- [x] Implement `harness` fixture
- [x] Implement `authenticatedPage` fixture (logs in test user)
- [x] Implement `adminPage` fixture (logs in admin user, navigates to org)
- [x] Test: Write smoke tests (`flovyn-app/tests/e2e/smoke.spec.ts`)

---

## Phase 1B: Add Test Attributes to UI Components

Before writing tests, add `data-testid` attributes to UI components for stable selectors. This prevents brittle tests that break when CSS classes or button text changes.

### Naming Conventions

Follow these patterns consistently:
- **Form inputs**: `{context}-{field}-input` (e.g., `login-email-input`)
- **Buttons**: `{context}-{action}-button` (e.g., `login-submit-button`)
- **Dialogs**: `{dialog-name}-dialog` (e.g., `invite-member-dialog`)
- **Data grids**: `{entity}-data-grid` (e.g., `members-data-grid`)
- **Grid rows**: `{entity}-row-{id}` (e.g., `member-row-123`)
- **Tabs**: `{page}-{tab-name}-tab` (e.g., `execution-timeline-tab`)
- **Alerts**: `{context}-error-alert` or `{context}-success-message`

### 1B.1 Authentication Forms

**File: `flovyn-app/apps/web/app/auth/login/LoginForm.tsx`**
- [x] Add `data-testid="login-form"` to form container
- [x] Add `data-testid="login-email-input"` to email input
- [x] Add `data-testid="login-password-input"` to password input
- [x] Add `data-testid="login-submit-button"` to Sign In button
- [x] Add `data-testid="login-error-alert"` to error message container
- [x] Add `data-testid="login-forgot-password-link"` to forgot password link
- [x] Add `data-testid="login-register-link"` to register link

**File: `flovyn-app/apps/web/app/auth/register/RegisterForm.tsx`**
- [x] Add `data-testid="register-form"` to form container
- [x] Add `data-testid="register-name-input"` to name input
- [x] Add `data-testid="register-email-input"` to email input
- [x] Add `data-testid="register-password-input"` to password input
- [x] Add `data-testid="register-confirm-password-input"` to confirm password input
- [x] Add `data-testid="register-submit-button"` to Create Account button
- [x] Add `data-testid="register-error-alert"` to error message container
- [x] Add `data-testid="register-signin-link"` to sign in link

**File: `flovyn-app/apps/web/app/auth/forgot-password/page.tsx`**
- [ ] Add `data-testid="forgot-password-email-input"` to email input
- [ ] Add `data-testid="forgot-password-submit-button"` to submit button
- [ ] Add `data-testid="forgot-password-error-alert"` to error container
- [ ] Add `data-testid="forgot-password-success-message"` to success screen

**File: `flovyn-app/apps/web/app/auth/set-password/page.tsx`**
- [ ] Add `data-testid="reset-password-input"` to new password input
- [ ] Add `data-testid="reset-confirm-password-input"` to confirm password input
- [ ] Add `data-testid="reset-password-submit-button"` to submit button
- [ ] Add `data-testid="reset-password-error-alert"` to error container
- [ ] Add `data-testid="reset-password-success-message"` to success screen

### 1B.2 Organization Pages

**File: `flovyn-app/apps/web/app/orgs/new/page.tsx`**
- [x] Add `data-testid="create-org-form"` to form container
- [x] Add `data-testid="create-org-name-input"` to organization name input
- [x] Add `data-testid="create-org-slug-input"` to slug input
- [x] Add `data-testid="create-org-submit-button"` to Create button
- [x] Add `data-testid="create-org-cancel-button"` to Cancel button
- [x] Add `data-testid="create-org-error-alert"` to error container

**File: `flovyn-app/apps/web/app/org/[orgSlug]/members/page.tsx`**
- [ ] Add `data-testid="members-page"` to main container
- [ ] Add `data-testid="members-refresh-button"` to refresh button
- [ ] Add `data-testid="members-invite-button"` to invite button
- [ ] Add `data-testid="members-tab"` to members tab trigger
- [ ] Add `data-testid="invitations-tab"` to invitations tab trigger

**File: `flovyn-app/apps/web/components/members/InviteMemberDialog.tsx`**
- [ ] Add `data-testid="invite-member-dialog"` to dialog container
- [ ] Add `data-testid="invite-member-email-input"` to email input
- [ ] Add `data-testid="invite-member-role-select"` to role select
- [ ] Add `data-testid="invite-member-submit-button"` to Send Invitation button
- [ ] Add `data-testid="invite-member-cancel-button"` to Cancel button
- [ ] Add `data-testid="invite-member-error-alert"` to error container
- [ ] Add `data-testid="invite-member-success-message"` to success message

**File: `flovyn-app/apps/web/components/members/MembersDataGrid.tsx`**
- [ ] Add `data-testid="members-data-grid"` to DataGrid container
- [ ] Add `data-testid="member-row-{id}"` pattern to each row (dynamic)

### 1B.3 Workflow Pages

**File: `flovyn-app/apps/web/app/org/[orgSlug]/workflows/page.tsx`**
- [ ] Add `data-testid="workflows-page"` to main container
- [ ] Add `data-testid="workflows-refresh-button"` to refresh button

**File: `flovyn-app/apps/web/components/workflows/WorkflowsDataGrid.tsx`**
- [ ] Add `data-testid="workflows-data-grid"` to DataGrid container
- [ ] Add `data-testid="workflow-row-{id}"` pattern to each row (dynamic)

**File: `flovyn-app/apps/web/components/fql/FQLFilterBar.tsx`** (or similar)
- [ ] Add `data-testid="fql-input"` to FQL query input
- [ ] Add `data-testid="fql-submit-button"` to apply/search button
- [ ] Add `data-testid="fql-clear-button"` to clear button
- [ ] Add `data-testid="fql-save-button"` to save query button
- [ ] Add `data-testid="fql-saved-queries-button"` to saved queries dropdown

### 1B.4 Execution Pages

**File: `flovyn-app/apps/web/app/org/[orgSlug]/workflows/executions/page.tsx`**
- [ ] Add `data-testid="executions-page"` to main container
- [ ] Add `data-testid="executions-refresh-button"` to refresh button
- [ ] Add `data-testid="executions-group-by-select"` to group by dropdown
- [ ] Add `data-testid="executions-time-range-picker"` to time range picker

**File: `flovyn-app/apps/web/components/executions/ExecutionsDataGrid.tsx`**
- [ ] Add `data-testid="executions-data-grid"` to DataGrid container
- [ ] Add `data-testid="execution-row-{id}"` pattern to each row (dynamic)
- [ ] Add `data-testid="execution-status-{id}"` to status badge (dynamic)

**File: `flovyn-app/apps/web/app/org/[orgSlug]/workflows/executions/[executionId]/page.tsx`**
- [ ] Add `data-testid="execution-detail-page"` to main container
- [ ] Add `data-testid="execution-detail-id"` to execution ID display
- [ ] Add `data-testid="execution-cancel-button"` to cancel button
- [ ] Add `data-testid="execution-retry-button"` to retry button
- [ ] Add `data-testid="execution-timeline-tab"` to timeline tab trigger
- [ ] Add `data-testid="execution-history-tab"` to history tab trigger

**File: `flovyn-app/apps/web/components/events/EventHistoryView.tsx`**
- [ ] Add `data-testid="event-history-view"` to main container
- [ ] Add `data-testid="event-tree-panel"` to tree panel
- [ ] Add `data-testid="event-timeline-panel"` to timeline panel
- [ ] Add `data-testid="event-history-loading"` to loading state
- [ ] Add `data-testid="event-history-empty"` to empty state

**File: Cancel/Retry dialogs**
- [ ] Add `data-testid="execution-cancel-dialog"` to cancel dialog
- [ ] Add `data-testid="execution-cancel-confirm-button"` to confirm button
- [ ] Add `data-testid="execution-retry-dialog"` to retry dialog
- [ ] Add `data-testid="execution-retry-submit-button"` to submit button

### 1B.5 Settings Pages

**File: `flovyn-app/apps/web/app/org/[orgSlug]/settings/metadata-fields/page.tsx`**
- [ ] Add `data-testid="metadata-fields-page"` to main container
- [ ] Add `data-testid="metadata-create-field-button"` to Create Field button

**File: `flovyn-app/apps/web/components/settings/create-metadata-field-dialog.tsx`**
- [ ] Add `data-testid="create-metadata-field-dialog"` to dialog container
- [ ] Add `data-testid="metadata-field-key-input"` to key input
- [ ] Add `data-testid="metadata-field-display-name-input"` to display name input
- [ ] Add `data-testid="metadata-field-description-textarea"` to description
- [ ] Add `data-testid="metadata-field-type-select"` to type select
- [ ] Add `data-testid="metadata-field-scope-select"` to scope select
- [ ] Add `data-testid="metadata-field-create-button"` to Create button
- [ ] Add `data-testid="metadata-field-cancel-button"` to Cancel button

**File: `flovyn-app/apps/web/components/settings/metadata-fields-data-grid.tsx`**
- [ ] Add `data-testid="metadata-fields-data-grid"` to DataGrid container
- [ ] Add `data-testid="metadata-field-row-{id}"` pattern to each row (dynamic)

**File: `flovyn-app/apps/web/components/settings/metadata-field-detail-panel.tsx`**
- [ ] Add `data-testid="metadata-field-detail-panel"` to panel container
- [ ] Add `data-testid="metadata-field-edit-button"` to edit button
- [ ] Add `data-testid="metadata-field-delete-button"` to delete button

**File: `flovyn-app/apps/web/app/org/[orgSlug]/settings/worker-tokens/page.tsx`**
- [ ] Add `data-testid="worker-tokens-page"` to main container
- [ ] Add `data-testid="worker-token-create-button"` to Create Token button

**File: `flovyn-app/apps/web/components/settings/worker-tokens-data-grid.tsx`**
- [ ] Add `data-testid="worker-tokens-data-grid"` to DataGrid container
- [ ] Add `data-testid="worker-token-row-{id}"` pattern to each row (dynamic)
- [ ] Add `data-testid="worker-token-revoke-button-{id}"` to revoke buttons (dynamic)

**File: Create worker token dialog**
- [ ] Add `data-testid="create-worker-token-dialog"` to dialog container
- [ ] Add `data-testid="worker-token-name-input"` to name input
- [ ] Add `data-testid="worker-token-create-button"` to Create button
- [ ] Add `data-testid="worker-token-value"` to displayed token value (one-time view)

### 1B.6 Workers Page

**File: `flovyn-app/apps/web/app/org/[orgSlug]/workers/page.tsx`**
- [ ] Add `data-testid="workers-page"` to main container
- [ ] Add `data-testid="workers-data-grid"` to workers list/grid

**File: Worker detail panel (if exists)**
- [ ] Add `data-testid="worker-detail-panel"` to panel container

### 1B.7 Common Components

**File: `flovyn-app/apps/web/components/org/org-switcher.tsx`**
- [ ] Add `data-testid="org-switcher-trigger"` to switcher button
- [ ] Add `data-testid="org-switcher-menu"` to dropdown menu
- [ ] Add `data-testid="org-menu-item-{slug}"` pattern to each org item (dynamic)
- [ ] Add `data-testid="org-menu-create"` to create organization menu item

**File: Device authorization pages**
- [ ] Add `data-testid="device-auth-approve-button"` to approve button
- [ ] Add `data-testid="device-auth-deny-button"` to deny button
- [ ] Add `data-testid="device-auth-code-display"` to code display

---

## Phase 2: Authentication Tests

### 2.1 Test Data Seeding

- [x] Implement `seedTestData()` in harness to create test org, admin user, member user
- [x] Create `flovyn-app/tests/e2e/helpers/data.ts` for unique ID generation utilities
- [x] Test: Verify seeded data exists after harness setup

### 2.2 Login Tests

Create `flovyn-app/tests/e2e/auth/login.spec.ts`:

- [x] Test: Successful login redirects to organization list
- [x] Test: Invalid credentials show error message
- [x] Test: Login with returnUrl redirects to specified page

### 2.3 Registration Tests

Create `flovyn-app/tests/e2e/auth/register.spec.ts`:

- [x] Test: Successful registration creates user and redirects
- [x] Test: Shows validation errors for invalid input
- [x] Test: Duplicate email shows appropriate error

### 2.4 Logout Tests

Create `flovyn-app/tests/e2e/auth/logout.spec.ts`:

- [x] Test: Logout clears session and redirects to login
- [x] Test: Protected routes redirect to login after logout

### 2.5 Device Authorization Tests

**REMOVED** - Feature not implemented yet. Tests will be added when device auth page is built.

---

## Phase 3: Organization Tests

### 3.1 Organization Creation

Create `flovyn-app/tests/e2e/organization/create.spec.ts`:

- [x] Test: Create new organization with unique name
- [x] Test: Validation errors for invalid org name
- [x] Test: New org appears in organization list

### 3.2 Member Management

Create `flovyn-app/tests/e2e/organization/members.spec.ts`:

- [x] Test: View organization members list
- [x] Test: Invite new member (verify pending state)
- [x] Test: Cancel pending invitation
- [x] Test: Change member role (admin to member, vice versa)

### 3.3 Access Control

Create `flovyn-app/tests/e2e/organization/access-control.spec.ts`:

- [x] Implement helper to create member-role user dynamically
- [x] Test: Non-admin cannot access member management page
- [x] Test: Non-admin cannot access settings pages
- [x] Test: Non-member cannot access organization at all

---

## Phase 4: Workflow Tests

### 4.1 API Helpers

Create `flovyn-app/tests/e2e/helpers/api.ts`:

- [x] Implement `harness.api.registerWorkflow()` to register workflow definitions
- [x] Implement `harness.api.startWorkflow()` to start workflow executions
- [x] Implement `harness.api.getExecution()` to fetch execution status
- [x] Implement `harness.waitForExecutionStatus()` polling helper

### 4.2 Workflow Listing

Create `flovyn-app/tests/e2e/workflows/list.spec.ts`:

- [x] Test: List workflow definitions (seed via API, verify UI shows them)
- [x] Test: Empty state when no workflows registered
- [x] Test: Pagination works correctly (if applicable)

### 4.3 FQL Filtering

Create `flovyn-app/tests/e2e/workflows/filter.spec.ts`:

- [x] Test: Filter workflows by FQL query (e.g., `kind = "order-workflow"`)
- [x] Test: Clear filter returns all results
- [x] Test: Invalid FQL shows error message

### 4.4 Saved Queries

Create `flovyn-app/tests/e2e/workflows/saved-queries.spec.ts`:

- [x] Test: Save FQL query with unique name
- [x] Test: Load saved query populates FQL input
- [x] Test: Delete saved query removes it from list

---

## Phase 5: Execution Tests

### 5.1 Execution Listing

Create `flovyn-app/tests/e2e/executions/list.spec.ts`:

- [x] Test: List workflow executions (start workflow via API, verify in UI)
- [x] Test: Filter executions by time range
- [x] Test: Group executions by status

### 5.2 Timeline Visualization

Create `flovyn-app/tests/e2e/executions/details.spec.ts`:

- [x] Test: View execution timeline (wait for completion, verify timeline renders)
- [x] Test: Click task span opens detail panel
- [x] Test: Timeline shows correct time range

### 5.3 Event History

Create `flovyn-app/tests/e2e/executions/events.spec.ts`:

- [x] Test: View execution events in History tab
- [x] Test: Filter events by type
- [x] Test: Event detail panel shows correct information

### 5.4 Execution Actions

Create `flovyn-app/tests/e2e/executions/actions.spec.ts`:

- [x] Test: Cancel running execution (start long-running workflow, cancel via UI)
- [x] Test: Retry failed execution (need workflow that can be configured to fail)

---

## Phase 6: Admin Features

### 6.1 Worker Management

Create `flovyn-app/tests/e2e/workers/list.spec.ts`:

- [x] Test: List registered workers (patterns-worker should appear)
- [x] Test: View worker details panel
- [x] Test: Non-admin cannot access workers page

### 6.2 Metadata Fields

Create `flovyn-app/tests/e2e/settings/metadata-fields.spec.ts`:

- [ ] Implement `harness.api.createMetadataField()` helper
- [x] Test: Create custom metadata field
- [x] Test: Edit metadata field display name
- [x] Test: Delete metadata field

### 6.3 Worker Tokens

Create `flovyn-app/tests/e2e/settings/worker-tokens.spec.ts`:

- [ ] Implement `harness.api.createWorkerToken()` helper
- [x] Test: Create worker token (verify one-time display)
- [x] Test: Revoke worker token
- [x] Test: Token appears in list after creation

---

## Phase 7: CI Integration

### 7.1 GitHub Actions Workflow

- [x] Create `.github/workflows/e2e.yml` (see design doc for config)
- [x] Configure artifact upload for Playwright reports
- [ ] Test: Run E2E tests in CI, verify they pass

### 7.2 Documentation

- [ ] Add E2E test instructions to README or CONTRIBUTING.md
- [ ] Document environment variables for local development
- [ ] Document how to run tests against existing infrastructure

---

## Verification Checklist

Before marking implementation complete:

- [ ] All `data-testid` attributes added to UI components (Phase 1B)
- [ ] All tests pass locally with `pnpm test:e2e`
- [ ] All tests pass in CI
- [ ] No orphaned containers after test run
- [ ] Harness cleans up properly on SIGINT (Ctrl+C)
- [ ] Tests can run in parallel without conflicts
- [ ] Playwright report generates correctly
- [ ] Tests use `data-testid` selectors, not CSS classes or button text

---

## Notes

- Follow test-first approach: write test, verify it fails for the right reason, then implement
- Verify one test works before moving to the next
- Use `randomUUID()` for all created resources to enable parallel execution
- If tests are slow/hanging, the issue is in our code, not testcontainers
- **Always use `data-testid` selectors** - avoid brittle selectors like:
  - `button:has-text("Submit")` - breaks if text changes
  - `.btn-primary` - breaks if CSS classes change
  - `[name="email"]` - acceptable but `data-testid` is more explicit
- Preferred: `page.getByTestId('login-submit-button')` or `[data-testid="login-submit-button"]`
