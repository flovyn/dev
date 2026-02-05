# Workspace Build: Implementation Plan

**Date**: 2026-02-05
**Design Document**: `dev/docs/design/20260205_workspace_build.md`

## Overview

This plan implements centralized CI for cross-repo testing and releases as described in the design document. The implementation is split into phases that can be deployed incrementally, with the system remaining functional after each phase.

## Pre-requisites

Before starting implementation:

- [x] Create `WORKSPACE_PAT` fine-grained PAT with:
  - `contents: read` for all repos (flovyn-server, sdk-rust, sdk-python, sdk-kotlin, sdk-typescript, dev)
  - `statuses: write` for all repos (to post commit status)
  - `actions: write` for dev repo (to trigger workflows)
- [x] Add `WORKSPACE_PAT` as a repository secret in `flovyn/dev` repo

## Phase 1: Workspace Integration Workflow

Create the centralized integration workflow in the dev repo. This phase does NOT modify per-repo CI yet.

### Tasks

- [x] **1.1** Create `dev/.github/workflows/integration.yml` with:
  - [x] Workflow triggers (workflow_dispatch + repository_dispatch)
  - [x] Concurrency group for deduplication
  - [x] `resolve-refs` job for branch resolution
  - [x] `build-artifacts` job (FFI, NAPI, Python bindings, Docker image)
  - [x] `e2e-sdk-rust` job
  - [x] `e2e-sdk-python` job
  - [x] `e2e-sdk-kotlin` job
  - [x] `e2e-sdk-typescript` job
  - [x] `integration-flovyn-server` job
  - [x] `post-status` job

- [ ] **1.2** Test the workflow manually:
  - [ ] Trigger with `branch: main` to verify all jobs pass
  - [ ] Trigger with a non-existent branch to verify fallback to main
  - [ ] Verify commit status appears on repo commits

### Validation

After Phase 1:
- Workspace CI can be triggered manually via `gh workflow run`
- Per-repo CI continues to work unchanged
- E2E tests run in workspace CI (duplicating per-repo for now)

## Phase 2: Per-Repo CI Simplification

Remove E2E/integration tests from individual repos and add auto-trigger to workspace CI.

### Tasks

- [x] **2.1** Simplify `sdk-rust/.github/workflows/ci.yml`:
  - [x] Remove `e2e` job entirely
  - [x] Add `trigger-workspace` job that triggers workspace CI when matching branches exist

- [x] **2.2** Simplify `sdk-python/.github/workflows/ci.yml`:
  - [x] Remove `e2e-test` job entirely
  - [x] Add `trigger-workspace` job

- [x] **2.3** Simplify `sdk-kotlin/.github/workflows/ci.yml`:
  - [x] Remove `e2e-test` job entirely
  - [x] Add `trigger-workspace` job

- [x] **2.4** Simplify `sdk-typescript/.github/workflows/ci.yml`:
  - [x] Remove `e2e-test` job entirely
  - [x] Add `trigger-workspace` job

- [x] **2.5** Simplify `flovyn-server/.github/workflows/ci.yml`:
  - [x] Remove `integration` job entirely
  - [x] Add `trigger-workspace` job

### Validation

After Phase 2:
- Pushing to any repo with matching branch elsewhere triggers workspace CI
- Per-repo CI is faster (no E2E downloads/tests)
- Status from workspace CI appears on PRs in all repos

## Phase 3: Workspace Release Workflow

Create coordinated release workflow.

### Tasks

- [x] **3.1** Create `dev/.github/workflows/release.yml` with:
  - [x] Manual trigger with version input and dry_run flag
  - [x] `release-sdk-rust` job (tag and push)
  - [x] `release-language-sdks` job (update FFI version, tag, push)
  - [x] `release-server` job (tag and push)

- [x] **3.2** Test the release workflow:
  - [ ] Run with `dry_run: true` to verify workflow logic (requires deployment)
  - [x] Document the release process in `dev/docs/operations/release.md`

### Validation

After Phase 3:
- Releases can be coordinated from a single workflow
- Version bumps happen automatically in sequence
- Release process is documented

## Test Plan

### Manual Testing (Phase 1)

1. **Branch resolution test**:
   - Create `test/workspace-ci` branch in sdk-rust and flovyn-server
   - Trigger workflow with `branch: test/workspace-ci`
   - Verify both repos are checked out at `test/workspace-ci`
   - Verify other repos fall back to `main`

2. **Artifact sharing test**:
   - Verify FFI artifact contains both `.so` and `.py` files
   - Verify NAPI artifact contains `.node` file
   - Verify Docker image loads correctly in E2E jobs

3. **Status posting test**:
   - After workflow completes, check commit statuses on all repos with the branch
   - Verify status shows `workspace/integration` context with link to workflow run

### Manual Testing (Phase 2)

1. **Auto-trigger test**:
   - Push to sdk-rust on a branch that exists in sdk-python
   - Verify workspace CI is triggered automatically
   - Verify deduplication works (second push cancels first)

2. **Single-repo test**:
   - Push to sdk-rust on a unique branch (no matching branches elsewhere)
   - Verify workspace CI is NOT triggered

### Manual Testing (Phase 3)

1. **Dry-run release**:
   - Run release workflow with `dry_run: true`
   - Verify no tags are created
   - Verify version update logic is correct

## Rollout Considerations

### Gradual Rollout

1. **Phase 1**: Deploy and test without affecting existing CI
2. **Phase 2**: Roll out repo-by-repo, starting with sdk-rust
3. **Phase 3**: Deploy after Phase 2 is stable

### Rollback Plan

- Phase 1: Delete `dev/.github/workflows/integration.yml`
- Phase 2: Revert individual repo CI changes
- Phase 3: Delete `dev/.github/workflows/release.yml`

### Monitoring

After deployment, monitor:
- Workspace CI run times
- Flaky test failures
- PAT rate limits (1000 requests/hour for fine-grained PAT)

## Known Limitations

1. **flovyn-app E2E**: Currently disabled. Can be added to workspace CI when re-enabled.
2. **macOS/Windows tests**: Only linux-x86_64 E2E is implemented. Cross-platform can be added later.
3. **Caching**: No Cargo/npm/gradle caching implemented. Add if CI times become problematic.

## Notes

- The design document was updated during planning to fix:
  - Missing NAPI build for TypeScript (TypeScript uses different bindings than Python/Kotlin)
  - Missing Python bindings generation step
  - Incomplete e2e-sdk-kotlin and e2e-sdk-typescript job definitions
