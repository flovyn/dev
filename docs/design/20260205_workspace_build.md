# Workspace Build: Centralized CI for Cross-Repo Testing and Releases

**Date**: 2026-02-05
**Status**: Draft
**GitHub Issue**: [flovyn/dev#15](https://github.com/flovyn/dev/issues/15)

## Problem Statement

When developing features that span multiple repositories, CI workflows fail due to circular dependencies between repos. The dependency graph:

```
                         flovyn-app
                              ↓ (E2E tests need Docker images)
                    flovyn-server
                    ↑ (integration tests)    ↓ (E2E tests need Docker image)
                         sdk-rust (core FFI)
                    ↑ (FFI bindings)
        ┌───────────┼───────────┐
   sdk-python   sdk-kotlin   sdk-typescript
        └───────────┼───────────┘
                    ↓ (E2E tests)
                flovyn-server Docker
```

**The core issue:** Each repo's CI tries to download released artifacts from other repos, but during cross-repo development, those releases don't exist yet.

## Solution: Workspace-Level CI

Instead of modifying each repo's CI to build dependencies from source, centralize cross-repo testing and releases in a **single workspace CI** in the `dev` repo.

### Architecture Overview

```
Individual Repo CI              Workspace CI (dev repo)
┌──────────────────────┐        ┌─────────────────────────────────────┐
│ - Unit tests         │        │ Integration Tests:                  │
│ - Linting            │   +    │   - Checkout all repos (same branch)│
│ - Type checking      │        │   - Build everything from source    │
│ - Fast feedback      │        │   - Run all E2E tests               │
│ - No cross-repo deps │        │                                     │
└──────────────────────┘        │ Releases:                           │
                                │   - Coordinate version bumps        │
                                │   - Release in topological order    │
                                │   - Single source of truth          │
                                └─────────────────────────────────────┘
```

### What Changes

| Concern | Before | After |
|---------|--------|-------|
| **Unit tests** | Per-repo CI | Per-repo CI (unchanged) |
| **E2E tests** | Per-repo CI (downloads releases) | Workspace CI (builds from source) |
| **Integration tests** | Per-repo CI | Workspace CI |
| **Releases** | Manual, repo-by-repo | Coordinated workspace workflow |

### Benefits

1. **Single place for cross-repo logic** - No duplicated branch resolution in every repo
2. **Atomic releases** - Coordinate sdk-rust → language SDKs → server in one workflow
3. **Simpler per-repo CI** - Each repo only runs unit tests, no Rust toolchain needed in Python/Kotlin/TS repos
4. **Easier maintenance** - Update CI logic in one place

### Drawbacks

1. **E2E results not directly on PR** - Mitigated by posting commit status back
2. **Extra coordination** - Need to trigger or wait for workspace CI
3. **PAT required** - Cross-repo triggers need personal access token

## Detailed Design

### 1. Per-Repo CI Simplification

Remove E2E/integration tests that depend on other repos. Keep only fast, isolated tests.

**sdk-rust CI** (simplified):
```yaml
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: cargo build --workspace
      - name: Run unit tests
        run: cargo test --workspace
      - name: Run model checking tests
        run: cargo test --test model -p flovyn-worker-sdk
      # E2E job REMOVED - moved to workspace CI
```

**sdk-python/kotlin/typescript CI** (simplified):
```yaml
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - name: Lint and format
        run: ...
      - name: Run unit tests
        run: ...
      # E2E job REMOVED - moved to workspace CI
      # No more FFI download needed for CI
```

**flovyn-server CI** (simplified):
```yaml
jobs:
  check:
    steps:
      - uses: actions/checkout@v4
      - name: Build and unit tests
        run: cargo build && cargo test
      # Integration tests REMOVED - moved to workspace CI
```

### 2. Workspace CI Workflow

Located at `dev/.github/workflows/integration.yml`:

```yaml
name: Workspace Integration

on:
  workflow_dispatch:
    inputs:
      branch:
        description: 'Branch to test across repos'
        required: true
        default: 'main'
  repository_dispatch:
    types: [trigger-integration]

# DEDUPLICATION: Only one run per branch at a time
# If sdk-python and sdk-typescript both push to feature/foo,
# the second trigger cancels the first (which is still building)
# and runs with the latest code from all repos
concurrency:
  group: workspace-${{ github.event.inputs.branch || github.event.client_payload.branch || 'main' }}
  cancel-in-progress: true

env:
  RUST_VERSION: "1.92.0"

jobs:
  resolve-refs:
    name: Resolve Branch Refs
    runs-on: ubuntu-latest
    outputs:
      branch: ${{ steps.resolve.outputs.branch }}
      server_ref: ${{ steps.resolve.outputs.server_ref }}
      sdk_rust_ref: ${{ steps.resolve.outputs.sdk_rust_ref }}
      sdk_python_ref: ${{ steps.resolve.outputs.sdk_python_ref }}
      sdk_kotlin_ref: ${{ steps.resolve.outputs.sdk_kotlin_ref }}
      sdk_typescript_ref: ${{ steps.resolve.outputs.sdk_typescript_ref }}
    steps:
      - name: Resolve refs
        id: resolve
        run: |
          BRANCH="${{ github.event.inputs.branch || github.event.client_payload.branch || 'main' }}"
          echo "branch=$BRANCH" >> $GITHUB_OUTPUT

          resolve_ref() {
            if git ls-remote --exit-code --heads "https://github.com/flovyn/$1" "$BRANCH" 2>/dev/null; then
              echo "$BRANCH"
            else
              echo "main"
            fi
          }

          echo "server_ref=$(resolve_ref flovyn-server)" >> $GITHUB_OUTPUT
          echo "sdk_rust_ref=$(resolve_ref sdk-rust)" >> $GITHUB_OUTPUT
          echo "sdk_python_ref=$(resolve_ref sdk-python)" >> $GITHUB_OUTPUT
          echo "sdk_kotlin_ref=$(resolve_ref sdk-kotlin)" >> $GITHUB_OUTPUT
          echo "sdk_typescript_ref=$(resolve_ref sdk-typescript)" >> $GITHUB_OUTPUT

  build-artifacts:
    name: Build Artifacts
    runs-on: ubuntu-latest
    needs: resolve-refs
    steps:
      - name: Checkout sdk-rust
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-rust
          ref: ${{ needs.resolve-refs.outputs.sdk_rust_ref }}
          path: sdk-rust

      - name: Checkout flovyn-server
        uses: actions/checkout@v4
        with:
          repository: flovyn/flovyn-server
          ref: ${{ needs.resolve-refs.outputs.server_ref }}
          path: flovyn-server

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ env.RUST_VERSION }}

      - name: Install protoc
        run: sudo apt-get update && sudo apt-get install -y protobuf-compiler

      - name: Build FFI library (for Python/Kotlin)
        run: |
          cd sdk-rust
          cargo build --release -p flovyn-worker-ffi

      - name: Generate Python bindings
        run: |
          cd sdk-rust
          mkdir -p bindings/python
          cargo run -p flovyn-worker-ffi --bin uniffi-bindgen -- \
            generate --library target/release/libflovyn_worker_ffi.so \
            --language python \
            --out-dir bindings/python

      - name: Build NAPI library (for TypeScript)
        run: |
          cd sdk-rust/worker-napi
          pnpm install
          pnpm build --release

      - name: Build flovyn-server Docker image
        run: |
          cd flovyn-server
          docker build -t rg.fr-par.scw.cloud/flovyn/flovyn-server:latest .

      - name: Upload FFI artifact (Python/Kotlin)
        uses: actions/upload-artifact@v4
        with:
          name: ffi-linux-x86_64
          path: |
            sdk-rust/target/release/libflovyn_worker_ffi.so
            sdk-rust/bindings/python/flovyn_worker_ffi.py

      - name: Upload NAPI artifact (TypeScript)
        uses: actions/upload-artifact@v4
        with:
          name: napi-linux-x64-gnu
          path: sdk-rust/worker-napi/flovyn-worker-napi.linux-x64-gnu.node

      - name: Save Docker image
        run: docker save rg.fr-par.scw.cloud/flovyn/flovyn-server:latest | gzip > server-image.tar.gz

      - name: Upload Docker image artifact
        uses: actions/upload-artifact@v4
        with:
          name: server-docker-image
          path: server-image.tar.gz

  e2e-sdk-rust:
    name: E2E Tests (sdk-rust)
    runs-on: ubuntu-latest
    needs: [resolve-refs, build-artifacts]
    steps:
      - name: Checkout sdk-rust
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-rust
          ref: ${{ needs.resolve-refs.outputs.sdk_rust_ref }}

      - name: Download Docker image
        uses: actions/download-artifact@v4
        with:
          name: server-docker-image

      - name: Load Docker image
        run: gunzip -c server-image.tar.gz | docker load

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ env.RUST_VERSION }}

      - name: Install protoc
        run: sudo apt-get update && sudo apt-get install -y protobuf-compiler

      - name: Run E2E tests
        run: cargo test --test e2e -- --ignored --nocapture

  e2e-sdk-python:
    name: E2E Tests (sdk-python)
    runs-on: ubuntu-latest
    needs: [resolve-refs, build-artifacts]
    steps:
      - name: Checkout sdk-python
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-python
          ref: ${{ needs.resolve-refs.outputs.sdk_python_ref }}

      - name: Download FFI artifact
        uses: actions/download-artifact@v4
        with:
          name: ffi-linux-x86_64
          path: flovyn/_native

      - name: Setup FFI files
        run: |
          cd flovyn/_native
          mkdir -p linux-x86_64
          mv libflovyn_worker_ffi.so linux-x86_64/
          ln -sf linux-x86_64/libflovyn_worker_ffi.so libflovyn_worker_ffi.so
          # flovyn_worker_ffi.py is already in the right place from artifact download

      - name: Download Docker image
        uses: actions/download-artifact@v4
        with:
          name: server-docker-image

      - name: Load Docker image
        run: gunzip -c server-image.tar.gz | docker load

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install uv
        uses: astral-sh/setup-uv@v4

      - name: Install dependencies
        run: uv sync --all-extras

      - name: Run E2E tests
        run: uv run pytest tests/e2e -v --tb=short -m e2e

  e2e-sdk-kotlin:
    name: E2E Tests (sdk-kotlin)
    runs-on: ubuntu-latest
    needs: [resolve-refs, build-artifacts]
    steps:
      - name: Checkout sdk-kotlin
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-kotlin
          ref: ${{ needs.resolve-refs.outputs.sdk_kotlin_ref }}

      - name: Download FFI artifact
        uses: actions/download-artifact@v4
        with:
          name: ffi-linux-x86_64
          path: tmp-ffi

      - name: Setup FFI files
        run: |
          mkdir -p worker-native/src/main/resources/natives/linux-x86_64
          cp tmp-ffi/libflovyn_worker_ffi.so worker-native/src/main/resources/natives/linux-x86_64/

      - name: Download Docker image
        uses: actions/download-artifact@v4
        with:
          name: server-docker-image

      - name: Load Docker image
        run: gunzip -c server-image.tar.gz | docker load

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: "17"
          distribution: "temurin"

      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@v5

      - name: Run E2E tests
        run: ./gradlew :worker-sdk-jackson:e2eTest

  e2e-sdk-typescript:
    name: E2E Tests (sdk-typescript)
    runs-on: ubuntu-latest
    needs: [resolve-refs, build-artifacts]
    steps:
      - name: Checkout sdk-typescript
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-typescript
          ref: ${{ needs.resolve-refs.outputs.sdk_typescript_ref }}

      - name: Download NAPI artifact
        uses: actions/download-artifact@v4
        with:
          name: napi-linux-x64-gnu
          path: packages/native

      - name: Download Docker image
        uses: actions/download-artifact@v4
        with:
          name: server-docker-image

      - name: Load Docker image
        run: gunzip -c server-image.tar.gz | docker load

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Setup pnpm
        uses: pnpm/action-setup@v4

      - name: Install dependencies
        run: pnpm install

      - name: Build packages
        run: pnpm build

      - name: Run E2E tests
        run: pnpm test:e2e

  integration-flovyn-server:
    name: Integration Tests (flovyn-server)
    runs-on: ubuntu-latest
    needs: [resolve-refs]
    steps:
      - name: Checkout flovyn-server
        uses: actions/checkout@v4
        with:
          repository: flovyn/flovyn-server
          ref: ${{ needs.resolve-refs.outputs.server_ref }}

      - name: Checkout sdk-rust
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-rust
          ref: ${{ needs.resolve-refs.outputs.sdk_rust_ref }}
          path: _deps/sdk-rust

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ env.RUST_VERSION }}

      - name: Install protoc
        run: sudo apt-get update && sudo apt-get install -y protobuf-compiler

      - name: Patch Cargo.toml for local sdk-rust
        run: |
          cat >> Cargo.toml << 'PATCH'

          [patch.crates-io]
          flovyn-worker-sdk = { path = "_deps/sdk-rust/worker-sdk" }
          flovyn-worker-core = { path = "_deps/sdk-rust/worker-core" }
          PATCH

      - name: Run integration tests
        run: cargo test --test integration_tests

  post-status:
    name: Post Status to Repos
    runs-on: ubuntu-latest
    needs: [resolve-refs, e2e-sdk-rust, e2e-sdk-python, e2e-sdk-kotlin, e2e-sdk-typescript, integration-flovyn-server]
    if: always()
    steps:
      - name: Determine overall status
        id: status
        run: |
          if [ "${{ needs.e2e-sdk-rust.result }}" = "success" ] && \
             [ "${{ needs.e2e-sdk-python.result }}" = "success" ] && \
             [ "${{ needs.e2e-sdk-kotlin.result }}" = "success" ] && \
             [ "${{ needs.e2e-sdk-typescript.result }}" = "success" ] && \
             [ "${{ needs.integration-flovyn-server.result }}" = "success" ]; then
            echo "state=success" >> $GITHUB_OUTPUT
          else
            echo "state=failure" >> $GITHUB_OUTPUT
          fi

      - name: Post commit status to repos
        env:
          GH_TOKEN: ${{ secrets.WORKSPACE_PAT }}
          BRANCH: ${{ needs.resolve-refs.outputs.branch }}
        run: |
          STATE="${{ steps.status.outputs.state }}"
          TARGET_URL="${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

          for repo in flovyn-server sdk-rust sdk-python sdk-kotlin sdk-typescript; do
            if git ls-remote --exit-code --heads "https://github.com/flovyn/$repo" "$BRANCH" 2>/dev/null; then
              SHA=$(git ls-remote "https://github.com/flovyn/$repo" "refs/heads/$BRANCH" | cut -f1)
              gh api "repos/flovyn/$repo/statuses/$SHA" \
                -f state="$STATE" \
                -f context="workspace/integration" \
                -f description="Workspace integration tests" \
                -f target_url="$TARGET_URL" || true
            fi
          done
```

### 3. Auto-Trigger from Per-Repo CI

Each repo can trigger workspace CI when matching branches are detected:

```yaml
# In sdk-rust/.github/workflows/ci.yml (add at end)
  trigger-workspace:
    name: Trigger Workspace CI
    runs-on: ubuntu-latest
    needs: [build]  # Only after unit tests pass
    if: github.event_name == 'push' && github.ref_name != 'main'
    steps:
      - name: Check for matching branches
        id: check
        run: |
          BRANCH="${GITHUB_REF_NAME}"
          MATCHING_REPOS=""

          for repo in flovyn-server sdk-python sdk-kotlin sdk-typescript; do
            if git ls-remote --exit-code --heads "https://github.com/flovyn/$repo" "$BRANCH" 2>/dev/null; then
              MATCHING_REPOS="$MATCHING_REPOS $repo"
            fi
          done

          if [ -n "$MATCHING_REPOS" ]; then
            echo "trigger=true" >> $GITHUB_OUTPUT
            echo "Found matching branches in:$MATCHING_REPOS"
          else
            echo "trigger=false" >> $GITHUB_OUTPUT
          fi

      - name: Trigger workspace CI
        if: steps.check.outputs.trigger == 'true'
        run: |
          gh workflow run integration.yml -R flovyn/dev -f branch="${GITHUB_REF_NAME}"
        env:
          GH_TOKEN: ${{ secrets.WORKSPACE_PAT }}
```

### 4. Workspace Release Workflow

Located at `dev/.github/workflows/release.yml`:

```yaml
name: Workspace Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release (e.g., 0.2.0)'
        required: true
      dry_run:
        description: 'Dry run (no actual releases)'
        type: boolean
        default: true

jobs:
  release-sdk-rust:
    name: Release sdk-rust
    runs-on: ubuntu-latest
    steps:
      - name: Checkout sdk-rust
        uses: actions/checkout@v4
        with:
          repository: flovyn/sdk-rust
          token: ${{ secrets.WORKSPACE_PAT }}

      - name: Create and push tag
        if: ${{ !inputs.dry_run }}
        run: |
          git tag "v${{ inputs.version }}"
          git push origin "v${{ inputs.version }}"
        # This triggers sdk-rust's release workflow

  release-language-sdks:
    name: Release Language SDKs
    runs-on: ubuntu-latest
    needs: release-sdk-rust
    strategy:
      matrix:
        repo: [sdk-python, sdk-kotlin, sdk-typescript]
    steps:
      - name: Checkout ${{ matrix.repo }}
        uses: actions/checkout@v4
        with:
          repository: flovyn/${{ matrix.repo }}
          token: ${{ secrets.WORKSPACE_PAT }}

      - name: Update FFI version
        run: |
          # Update FFI_VERSION in CI workflow
          sed -i "s/FFI_VERSION: v.*/FFI_VERSION: v${{ inputs.version }}/" .github/workflows/ci.yml
          git add .github/workflows/ci.yml
          git commit -m "chore: update FFI version to v${{ inputs.version }}"
          git push

      - name: Create and push tag
        if: ${{ !inputs.dry_run }}
        run: |
          git tag "v${{ inputs.version }}"
          git push origin "v${{ inputs.version }}"

  release-server:
    name: Release flovyn-server
    runs-on: ubuntu-latest
    needs: release-language-sdks
    steps:
      - name: Checkout flovyn-server
        uses: actions/checkout@v4
        with:
          repository: flovyn/flovyn-server
          token: ${{ secrets.WORKSPACE_PAT }}

      - name: Create and push tag
        if: ${{ !inputs.dry_run }}
        run: |
          git tag "v${{ inputs.version }}"
          git push origin "v${{ inputs.version }}"
```

## Trigger Moments

### For Integration/E2E Tests

| Trigger | When | Use Case |
|---------|------|----------|
| **Auto (repo dispatch)** | Any repo detects matching branch exists elsewhere | Cross-repo feature development |
| **Manual** | Developer runs `gh workflow run` | On-demand verification |
| **On merge to main** | After PR merged in any repo | Verify main branch health |

### For Releases

| Trigger | When | Use Case |
|---------|------|----------|
| **Manual with version input** | Ready to release | Coordinated multi-repo release |

## Example: Cross-Repo PR Flow

```
1. Developer pushes feature/foo to flovyn-server
   └─> flovyn-server CI: unit tests ✓

2. Developer pushes feature/foo to sdk-rust
   └─> sdk-rust CI: unit tests ✓
   └─> Detects matching branch in flovyn-server
   └─> Triggers workspace CI with branch=feature/foo

3. Workspace CI runs
   └─> Checkouts both repos at feature/foo
   └─> Builds server Docker from feature/foo
   └─> Builds FFI from feature/foo
   └─> Runs sdk-rust E2E tests
   └─> Posts status back to both PRs

4. Developer sees "workspace/integration ✓" on both PRs
```

## Design Decisions

### Decision 1: Centralized vs Distributed

**Chosen**: Centralized workspace CI in `dev` repo.

**Rationale**:
- Single source of truth for cross-repo logic
- Simpler per-repo CI (no Rust toolchain in Python/Kotlin/TS)
- Easier to maintain and update

**Trade-off**: E2E results require checking `dev` repo (mitigated by commit status posting).

### Decision 2: Auto-Trigger vs Manual-Only

**Chosen**: Auto-trigger when matching branches detected, with manual fallback.

**Rationale**:
- Developers don't need to remember to trigger
- Fast feedback loop
- Manual trigger available for edge cases

### Decision 3: Status Reporting

**Chosen**: Post commit status back to source repos.

**Rationale**:
- Developers see integration status directly on their PR
- Works with branch protection rules
- No context switching to check `dev` repo

### Decision 4: Artifact Sharing

**Chosen**: Build artifacts once, share via GitHub Actions artifacts.

**Rationale**:
- Avoids rebuilding FFI for each SDK
- Docker image built once, loaded by each E2E job
- Faster overall CI time

### Decision 5: Deduplication of Concurrent Triggers

**Chosen**: GitHub Actions concurrency groups with `cancel-in-progress: true`.

**Problem**: If you push to sdk-python and sdk-typescript at roughly the same time, both repos detect matching branches and trigger workspace CI, resulting in duplicate runs.

**Solution**: Use concurrency groups keyed by branch name:

```yaml
concurrency:
  group: workspace-${{ github.event.inputs.branch || github.event.client_payload.branch || 'main' }}
  cancel-in-progress: true
```

**Behavior**:
- First trigger starts the workflow
- Second trigger (within seconds/minutes) cancels the in-progress run
- Second run executes with latest code from all repos

**Why `cancel-in-progress: true`**:
- The second push likely has newer code, so testing the first is wasteful
- Reduces CI minutes consumption
- Developer gets results for the most recent state

**Alternatives Considered**:

| Option | Behavior | Trade-off |
|--------|----------|-----------|
| `cancel-in-progress: false` | Queue runs sequentially | Wasteful - tests outdated code |
| Debounce (wait 60s before running) | Batch triggers | Adds latency to feedback |
| Single trigger point (e.g., only sdk-rust triggers) | Prevents duplicates | Misses changes in other repos |
| Check for recent run before triggering | Skip if recent run exists | Complex, race conditions |

## Open Questions

### 1. PAT Token Management

The workspace CI needs a PAT with permissions to:
- Read all repos
- Write commit status to all repos
- Trigger workflows

**Options**:
- Fine-grained PAT with minimal scope
- GitHub App installation token
- GITHUB_TOKEN with workflow permissions (limited)

**Recommendation**: Start with fine-grained PAT, consider GitHub App for production.

### 2. Handling Flaky Tests

If workspace CI fails due to flaky tests, it affects all repos with matching branches.

**Options**:
- Retry logic in workflow
- Mark flaky tests as allowed-to-fail
- Separate required vs optional test suites

**Recommendation**: Add retry for known flaky tests, don't block on E2E initially.

### 3. flovyn-app E2E Tests

Currently disabled. Should they be included in workspace CI?

**Recommendation**: Yes, include when re-enabling. Follows same pattern.

### 4. Caching Strategy

Building Rust and Docker from scratch is slow.

**Options**:
- GitHub Actions cache for Cargo registry
- Docker layer caching
- Pre-built base images

**Recommendation**: Start with standard caching, optimize if needed.

## Implementation Phases

### Phase 1: Workspace Integration Workflow

1. Create `dev/.github/workflows/integration.yml`
2. Implement branch resolution
3. Build FFI and Docker artifacts
4. Run sdk-rust E2E tests
5. Post status back to repos

### Phase 2: Per-Repo CI Simplification

1. Remove E2E jobs from sdk-rust CI
2. Remove E2E jobs from sdk-python/kotlin/typescript CI
3. Remove integration job from flovyn-server CI
4. Add auto-trigger to each repo

### Phase 3: Additional E2E Suites

1. Add sdk-python E2E to workspace CI
2. Add sdk-kotlin E2E to workspace CI
3. Add sdk-typescript E2E to workspace CI
4. Add flovyn-server integration to workspace CI

### Phase 4: Workspace Release Workflow

1. Create `dev/.github/workflows/release.yml`
2. Implement coordinated release flow
3. Test with dry-run
4. Document release process

## References

- [GitHub Issue #15](https://github.com/flovyn/dev/issues/15) - Original discussion
- [GitHub Actions: Triggering workflows](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow)
- [GitHub API: Create commit status](https://docs.github.com/en/rest/commits/statuses)
