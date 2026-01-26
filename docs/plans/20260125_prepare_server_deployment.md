# Implementation Plan: Prepare Server Deployment

**Design Document**: [20260125_prepare_server_deployment.md](../design/20260125_prepare_server_deployment.md)

## Pre-Implementation Notes

### Critical Observations

1. **NATS connectivity check**: The `async_nats::Client` doesn't expose a simple `is_connected()` method. Need to use a lightweight operation (publish to a non-existent subject or check `client.connection_state()`) to verify connectivity.

2. **flovyn-app migration script**: The current `db:migrate` command uses `dotenv-cli` which isn't available in the production image. Need a production-compatible migration script that reads `DATABASE_URL` from environment.

3. **Graceful shutdown scope**: The current server uses `tokio::select!` which immediately stops when either server terminates. Need to add signal handling and proper shutdown coordination.

---

## Phase 1: flovyn-server Health Endpoints

### TODO

- [x] **1.1** Create health check types in `flovyn-server/server/src/api/rest/health.rs`
  - Add `CheckStatus` enum (UP/DOWN)
  - Add `ComponentCheck` struct for individual component status
  - Add `HealthDetailResponse` struct for `/ready` and `/startup` responses

- [x] **1.2** Implement `/_/health/live` endpoint
  - Returns 200 with `{"status": "UP"}` unconditionally
  - Register in router and OpenAPI spec

- [x] **1.3** Implement database health check function
  - Use `SELECT 1` with 5-second timeout
  - Return component status with error message on failure

- [x] **1.4** Implement NATS health check function (conditional)
  - Only check if NATS is enabled
  - Use `client.flush()` or `client.connection_state()` to verify connectivity
  - Return component status with error message on failure

- [x] **1.5** Implement `/_/health/ready` endpoint
  - Check database connectivity
  - Check NATS connectivity (if enabled)
  - Return 200 if all checks pass, 503 if any fail
  - Include component details in response

- [x] **1.6** Implement `/_/health/startup` endpoint
  - Same implementation as `/ready` (startup probe allows longer initial timeout)
  - Register in router and OpenAPI spec

- [x] **1.7** Update `AppState` to include streaming backend reference for NATS checks
  - Add `Option<Arc<dyn StreamingHealthCheck>>` to AppState
  - Pass NATS client reference during state construction

- [x] **1.8** Preserve backward compatibility for `/_/health`
  - Keep existing endpoint working for any external dependencies

- [x] **1.9** Add unit tests for health check logic
  - Test database check success/failure
  - Test NATS check enabled/disabled scenarios
  - Test response status code logic

---

## Phase 2: flovyn-app Health Endpoints

### TODO

- [x] **2.1** Create health route files
  - Create `apps/web/app/api/health/live/route.ts`
  - Create `apps/web/app/api/health/ready/route.ts`
  - Create `apps/web/app/api/health/startup/route.ts`

- [x] **2.2** Implement `/api/health/live` route
  - Return `{ status: "UP" }` with 200 status
  - No dependencies to check

- [x] **2.3** Create database health check utility
  - Create `apps/web/lib/health/db-check.ts`
  - Use existing Kysely/pg pool to run `SELECT 1`
  - Include 5-second timeout

- [x] **2.4** Create backend health check utility
  - Create `apps/web/lib/health/backend-check.ts`
  - Fetch `BACKEND_URL/_/health/live` with 5-second timeout
  - Handle connection failures gracefully

- [x] **2.5** Implement `/api/health/ready` route
  - Check database connectivity
  - Check backend server connectivity
  - Return 200 if all pass, 503 if any fail
  - Return JSON with component status details

- [x] **2.6** Implement `/api/health/startup` route
  - Same implementation as `/ready`

- [ ] **2.7** Add tests for health endpoints
  - Test live endpoint always returns 200
  - Test ready endpoint with mocked dependencies

---

## Phase 3: flovyn-app Automatic Migrations

### TODO

- [x] **3.1** Create production migration script
  - Updated `migrations/migrate-auth.mjs` to include all auth plugins
  - Updated `migrations/package.json` with oauth-provider dependency
  - Migration scripts work without dev dependencies
  - Read `DATABASE_URL` from process.env directly

- [x] **3.2** Create docker-entrypoint.sh for flovyn-app
  - Create `flovyn-app/docker-entrypoint.sh`
  - Run migration script
  - Then exec to `node apps/web/server.js`
  - Handle migration failures (exit with error)

- [x] **3.3** Update flovyn-app Dockerfile
  - Added migrations-deps stage for installing migration dependencies
  - Copy migration scripts and node_modules to runner
  - Change CMD to ENTRYPOINT with entrypoint script

- [ ] **3.4** Test migration in container
  - Build image locally
  - Start with fresh database
  - Verify migrations run before server starts
  - Verify server starts after migrations complete

---

## Phase 4: flovyn-server Graceful Shutdown

### TODO

- [x] **4.1** Create shutdown coordination module
  - Create `flovyn-server/server/src/shutdown.rs`
  - Define `ShutdownSignal` struct with atomic flag and Notify
  - Implement SIGTERM/SIGINT handler using `tokio::signal`

- [x] **4.2** Integrate shutdown signal into AppState
  - Add shutdown signal reference to `AppState` (done in Phase 1)
  - Update `/ready` to return 503 when shutdown is signaled

- [x] **4.3** Update main.rs to use shutdown coordination
  - Create shutdown signal at startup
  - Register SIGTERM/SIGINT handlers
  - Spawn signal handler task to trigger shutdown

- [x] **4.4** Implement graceful HTTP server shutdown
  - Use `axum::serve().with_graceful_shutdown()`
  - Stop accepting new connections on shutdown signal
  - Wait for in-flight requests to complete

- [x] **4.5** Implement graceful gRPC server shutdown
  - Create `start_grpc_server_with_shutdown()` function
  - Use `serve_with_shutdown()` from tonic

- [ ] **4.6** Test shutdown behavior
  - Start server, send SIGTERM
  - Verify ready endpoint returns 503 after signal
  - Verify in-flight requests complete
  - Verify clean exit

---

## Phase 5: Update E2E Test Harness

### TODO

- [x] **5.1** Update flovyn-server wait strategy in harness
  - Change from `Wait.forHttp('/_/health', 8000)`
  - To `Wait.forHttp('/_/health/ready', 8000)`
  - Update `flovyn-app/tests/e2e/harness.ts:178`

- [x] **5.2** Update flovyn-app wait strategy in harness
  - Change from `Wait.forLogMessage(/Listening on|Ready/)`
  - To `Wait.forHttp('/api/health/ready', 3000)`
  - Update `flovyn-app/tests/e2e/harness.ts:200`

- [ ] **5.3** Run E2E tests to verify
  - Build both Docker images with changes
  - Run full E2E test suite
  - Verify containers start correctly with new health checks

---

## Phase 6: Integration Testing

### TODO

- [x] **6.1** Add flovyn-server integration test for health endpoints
  - Test `/live` returns 200
  - Test `/ready` returns 200 when DB is connected
  - Test `/startup` behaves like `/ready`
  - Test legacy `/_/health` still works
  - Created `server/tests/integration/health_tests.rs`

- [ ] **6.2** Add flovyn-app integration test for health endpoints (Deferred)
  - Similar tests as server
  - Test backend connectivity check

- [ ] **6.3** Test graceful shutdown with docker-compose (Deferred)
  - Start services with `docker-compose up`
  - Send SIGTERM to flovyn-server container
  - Verify it exits cleanly within timeout

---

## Test Plan

### Unit Tests
- Health check status aggregation logic
- Shutdown signal state transitions
- Migration script error handling

### Integration Tests
- Health endpoints with real database
- Health endpoints with NATS (when enabled)
- Graceful shutdown with in-flight requests

### E2E Tests
- Full container startup with new health endpoints
- Verify existing E2E tests pass with updated wait strategies

---

## Rollout Considerations

1. **Backward compatibility**: The existing `/_/health` endpoint is preserved. Any systems depending on it will continue to work.

2. **flovyn-edka updates**: After these changes are deployed, flovyn-edka Kubernetes manifests should be updated to use:
   - `livenessProbe`: `/_/health/live` (flovyn-server) or `/api/health/live` (flovyn-app)
   - `readinessProbe`: `/_/health/ready` or `/api/health/ready`
   - `startupProbe`: `/_/health/startup` or `/api/health/startup`

3. **Image tagging**: New images should be built and tagged after all phases are complete. Recommended tag format: `vX.Y.Z` with this feature.

4. **Migration idempotency**: Both Better Auth and Kysely migrations are idempotent. Running them on an already-migrated database is safe.
