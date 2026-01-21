# Bug: E2E Tests Fail - Organization Not Created from Config

## Summary

Kotlin SDK E2E tests fail during worker registration because the organization defined in the config file is not being created in the database.

## Status

**RESOLVED** - Fixed on 2026-01-15

## Resolution

**Root Causes Identified:**
1. Server image was outdated - needed rebuild
2. macOS temp file location (`/var/folders/...`) not accessible to Docker - changed to `/tmp`
3. `ClientConfig.clientToken` was `null` - needed to use `workerToken` for client operations

**Fixes Applied:**
1. Rebuilt server image with `./bin/dev/docker-build.sh`
2. Changed `TestHarness.kt` to use `File.createTempFile(..., File("/tmp"))` for macOS Docker compatibility
3. Changed `FlovynClient.kt` to set `clientToken = workerToken` in ClientConfig (same as Rust SDK)

**Test Results:** 11/11 tests pass.

**Additional Fix (Promise Resolution):**
4. Fixed `FlovynClient.resolvePromise` and `rejectPromise` to fetch the actual promise UUID from workflow events (matching Rust SDK implementation) instead of using incorrect `$workflowId:$promiseName` format.

## Environment

- Kotlin SDK: `sdk-kotlin`
- Server image: `rg.fr-par.scw.cloud/flovyn/flovyn-server:latest`
- Test framework: Testcontainers (Java)
- Platform: macOS Darwin 25.1.0
- Java: Temurin 17 (via mise)

## Symptoms

```
uniffi.flovyn_worker_ffi.FfiException$Grpc: msg=Failed to register worker: error returned from database: insert or update on table "worker" violates foreign key constraint "worker_org_id_fkey", code=13
```

Test report shows both `TaskE2ETest` and `WorkflowE2ETest` fail with `initializationError` in `0.002s`.

## Root Cause

Unknown. The organization defined in `[[orgs]]` config section is not present in the database when the worker attempts to register.

## Expected Behavior

Server should:
1. Read config file from `CONFIG_FILE` env var
2. Parse `[[orgs]]` section
3. Sync orgs to database via `startup::sync_orgs()`
4. Worker registration should succeed

## Current Behavior

- Server starts successfully
- Health check passes (`/_/health` returns 200)
- Worker registration fails with foreign key constraint violation
- Organization does not exist in database

## Test Setup (TestHarness.kt)

1. Creates temp config file with `[[orgs]]` and `[auth.static_api_key]` sections
2. Starts PostgreSQL container (`postgres:18-alpine`)
3. Starts NATS container (`nats:latest`)
4. Starts Flovyn server container with:
   - Config file bind-mounted to `sdk-kotlin//app/config.toml`
   - `sdk-kotlin/CONFIG_FILE=/app/config.toml` environment variable
5. Waits for server health check
6. Test attempts to register worker using configured `workerToken`

## Config File Content

```toml
[[orgs]]
id = "<generated-uuid>"
name = "Test Organization"
slug = "test-<random>"
tier = "FREE"

[auth]
enabled = true

[auth.static_api_key]
keys = [
    { key = "flovyn_sk_test_<random>", org_id = "<same-uuid>", principal_type = "User", principal_id = "api:test", role = "ADMIN" },
    { key = "flovyn_wk_test_<random>", org_id = "<same-uuid>", principal_type = "Worker", principal_id = "worker:test" }
]

[auth.endpoints.http]
authenticators = ["static_api_key"]
authorizer = "cedar"

[auth.endpoints.grpc]
authenticators = ["static_api_key"]
authorizer = "cedar"
```

## Related

- Rust SDK E2E tests (`sdk-rust/worker-sdk/tests/e2e/harness.rs`) use the same approach and reportedly work

## Files Involved

- `sdk-kotlin/worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/TestHarness.kt`
- `sdk-kotlin/worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/TaskE2ETest.kt`
- `sdk-kotlin/worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/WorkflowE2ETest.kt`
- `flovyn-server/server/src/startup.rs` - `sync_orgs()` function
- `flovyn-server/server/src/config.rs` - Config parsing

---

## Debugging Attempts

### Attempt 1: Initial Test Run

**Action**:
```bash
./gradlew :worker-sdk-jackson:e2eTest
```

**Result**:
```
TaskE2ETest > initializationError FAILED
    uniffi.flovyn_worker_ffi.FfiException$Grpc at TaskE2ETest.kt:26

WorkflowE2ETest > initializationError FAILED
    uniffi.flovyn_worker_ffi.FfiException$Grpc at WorkflowE2ETest.kt:28
```

**Evidence**: Test report at `worker-sdk-jackson/build/reports/tests/e2eTest/classes/ai.flovyn.sdk.e2e.TaskE2ETest.html`

### Attempt 2: Test Duration Analysis

**Observation**: Test report shows duration of `0.002s` for both tests.

**Conclusion**: Containers start successfully and health check passes. Failure occurs immediately when registering worker.

### Attempt 3: Reviewed Rust Harness Implementation

**Action**: Read `sdk-rust/worker-sdk/tests/e2e/harness.rs`

**Findings**:
- Uses `tempfile::NamedTempFile` to create config file
- Bind mounts via `Mount::bind_mount(&config_path, "/app/config.toml")`
- Sets `sdk-kotlin/CONFIG_FILE=/app/config.toml` env var
- Same config format with `[[orgs]]` and `[auth.static_api_key]`
- Token format: `flovyn_sk_test_<16-chars>` and `flovyn_wk_test_<16-chars>`

### Attempt 4: Reviewed Server Code

**Action**: Explored `flovyn-server` codebase

**Findings** (from `sdk-kotlin/server/src/startup.rs` and `sdk-kotlin/server/src/main.rs`):
- Server startup: load config → migrations → `sync_orgs()` → start servers
- `sync_orgs()` uses `INSERT ... ON CONFLICT` to upsert orgs
- `validate_api_key_org_refs()` validates API key org_ids before sync

### Attempt 5: Rewrote TestHarness to Match Rust

**Action**: Completely rewrote `TestHarness.kt` to match Rust implementation

**Changes**:
- Same UUID generation: `substring(0, 8)` and `substring(0, 16)`
- Same token prefixes: `flovyn_sk_test_` and `flovyn_wk_test_`
- Same config format (including leading newline)
- Same bind mount with `withFileSystemBind()`

**Result**: Same error persists

### Attempt 6: Checked System Temp Directory

**Action**:
```bash
echo $TMPDIR
```

**Result**:
```
/var/folders/0x/rly6wrq900qfznyjpcxs21fr0000gn/T/
```

**Note**: Rust tests use same temp directory and reportedly work.

### Attempt 7: Checked for Running Containers

**Action**:
```bash
docker ps -a --filter "label=flovyn-test"
```

**Result**: No containers found (cleaned up after test failure)

---

---

## Critical Finding: Server Image Issue (NOT SDK-specific)

### Attempt 8: Run Rust SDK E2E Tests

**Action**:
```bash
cd sdk-rust && cargo test -p flovyn-worker-sdk --test e2e simple -- --ignored --test-threads=1
```

**Result**: Rust SDK E2E tests ALSO FAIL with the SAME error:
```
Failed to register worker: error returned from database: insert or update on table "worker" violates foreign key constraint "worker_org_id_fkey"
```

**Evidence**: The Rust harness creates identical config file format:
```toml
# Pre-configured organizations
[[orgs]]
id = "92650fa8-39d1-49b5-aaa9-96c105ca0356"
name = "Test Organization"
slug = "test-15ed4cc1"
tier = "FREE"

[auth]
enabled = true
...
```

**Conclusion**: The issue is NOT specific to Kotlin SDK. Both Rust and Kotlin SDKs fail with the same error.

### Attempt 9: Check Server Logs with RUST_LOG

**Action**: Added `RUST_LOG=info,flovyn=debug` to server container

**Server Logs**:
```
INFO flovyn_server: Database connection established
INFO flovyn_server: Core database migrations completed
INFO flovyn_server: Plugin migrations completed
INFO flovyn_server: Authentication enabled - HTTP: static_api_key, gRPC: static_api_key
INFO flovyn_server: Starting HTTP server on 0.0.0.0:8000
INFO flovyn_server: Starting gRPC server on 0.0.0.0:9090
```

**Key Observation**: NO "Pre-configured orgs synced" log message. According to server code (`main.rs:136`), this log should appear after `sync_orgs()` is called.

### Attempt 10: Manual Server Test with Config File

**Action**: Ran server manually with config file:
```bash
docker run --rm \
  -e DATABASE_URL="postgres://..." \
  -e CONFIG_FILE="/app/config.toml" \
  -e RUST_LOG="info,flovyn=debug" \
  -v /tmp/test-config.toml:/app/config.toml:ro \
  rg.fr-par.scw.cloud/flovyn/flovyn-server:latest
```

**Result**: Server starts, auth is enabled (proving config IS being read), but `[[orgs]]` section is not parsed.

**Database Query**:
```sql
SELECT id, name, slug FROM organization;
-- (0 rows)
```

---

## Root Cause Identified

The server image (`rg.fr-par.scw.cloud/flovyn/flovyn-server:latest`) does NOT parse the `[[orgs]]` TOML array of tables section.

**Evidence**:
1. Server reads `[auth.static_api_key]` section correctly (authentication is enabled)
2. Server does NOT read `[[orgs]]` section (`config.orgs.is_empty()` returns true)
3. No "Pre-configured orgs synced" log appears
4. Organization table remains empty

**Server Code Reference** (`flovyn-server/server/src/main.rs:129-137`):
```rust
// Sync pre-configured orgs if any are configured
if !config.orgs.is_empty() {
    startup::validate_api_key_org_refs(&config.orgs, &config.auth)?;
    startup::sync_orgs(&pool, &config.orgs).await?;
    tracing::info!(count = config.orgs.len(), "Pre-configured orgs synced");
}
```

Since `config.orgs.is_empty()` is true, this block is skipped entirely.

## Recommended Next Steps

1. Investigate why `[[orgs]]` TOML array is not being parsed by the `config` crate
2. Check if there's a version mismatch between the server image and expected config format
3. Test with a known-working server image version
4. Check if the `config` crate requires special handling for TOML array of tables
