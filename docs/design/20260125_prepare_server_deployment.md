# Prepare Server Deployment

**Date**: 2026-01-25
**Status**: Approved
**Author**: Engineering
**Issue**: [flovyn/flovyn-server#10](https://github.com/flovyn/flovyn-server/issues/10)

## Problem Statement

We need to deploy flovyn-server and flovyn-app to Kubernetes using the [flovyn-edka](https://github.com/flovyn/flovyn-edka) infrastructure repository. The existing configurations in flovyn-edka are obsolete because they were designed for older server implementations.

To successfully deploy on Kubernetes, both applications must:
1. Have production-ready Docker images
2. Run database migrations automatically during deployment
3. Provide proper health endpoints for Kubernetes probes

## Current State Analysis

### flovyn-server

| Aspect | Status | Details |
|--------|--------|---------|
| Dockerfile | Ready | Multi-stage build, minimal debian:bookworm-slim image, feature flags support |
| Migrations | Ready | Embedded in binary via SQLx, run automatically on startup before serving traffic |
| Health endpoint | Partial | `GET /_/health` exists but only returns static "UP" status |
| Graceful shutdown | Missing | No SIGTERM handling, no connection draining |

**Current health endpoint** (`flovyn-server/server/src/api/rest/health.rs`):
```json
GET /_/health
{
  "status": "UP",
  "version": "x.y.z",
  "plugins": ["worker-token", "eventhook"]
}
```

This endpoint is insufficient for Kubernetes because:
- It does not verify database connectivity
- It does not verify NATS connectivity (if enabled)
- It always returns "UP" even during startup or shutdown
- It provides no distinction between liveness, readiness, and startup checks

### flovyn-app

| Aspect | Status | Details |
|--------|--------|---------|
| Dockerfile | Ready | Multi-stage build, node:22-slim image, standalone output mode |
| Migrations | Partial | Better Auth migrations exist, but not integrated into container startup |
| Health endpoint | Missing | No health check routes exist |
| Graceful shutdown | Missing | No signal handlers |

**Migration handling**: The app has `pnpm db:migrate` commands but these are not automatically run when the container starts.

### E2E Test Harness (Reference Implementation)

The E2E test harness (`flovyn-app/tests/e2e/harness.ts`) shows how these containers are currently configured:

**flovyn-server container**:
```typescript
.withEnvironment({
  DATABASE_URL: `postgres://flovyn:flovyn@${dbHost}:5432/flovyn`,
  NATS__ENABLED: 'true',
  NATS__URL: `nats://${natsHost}:4222`,
  SERVER_PORT: '8000',
  GRPC_SERVER_PORT: '9090',
})
.withWaitStrategy(Wait.forHttp('/_/health', 8000))
```

**flovyn-app container**:
```typescript
.withEnvironment({
  DATABASE_URL: `postgres://...`,
  BACKEND_URL: `http://${serverHost}:8000`,
  BETTER_AUTH_SECRET: '...',
  BETTER_AUTH_TRUST_HOST: 'true',
})
.withWaitStrategy(Wait.forLogMessage(/Listening on|Ready/))  // No health endpoint!
```

## Goals

1. **Health endpoints**: Implement Kubernetes-compatible health probes for both applications
2. **Automatic migrations**: Ensure migrations run automatically during container startup
3. **Graceful shutdown**: Handle SIGTERM properly for clean pod termination
4. **Documentation**: Update configurations that flovyn-edka will need

## Non-Goals

- Creating Kubernetes manifests (flovyn-edka responsibility)
- Setting up CI/CD pipelines for image publishing
- Implementing horizontal scaling or high availability
- Adding Prometheus metrics endpoints (already exists for flovyn-server)

## Solution Design

### 1. Health Endpoints

Both applications should implement three distinct endpoints for Kubernetes probes:

| Endpoint | Purpose | Kubernetes Probe | Response |
|----------|---------|------------------|----------|
| `/_/health/live` | Is the process alive? | livenessProbe | Always 200 if process is running |
| `/_/health/ready` | Can the app handle traffic? | readinessProbe | 200 if all dependencies are connected |
| `/_/health/startup` | Has initialization completed? | startupProbe | 200 after migrations and startup complete |

#### flovyn-server Health Checks

**Liveness** (`/_/health/live`):
- Always returns 200 if the HTTP server is responding
- No dependency checks (restart won't help if DB is down)

**Readiness** (`/_/health/ready`):
- Verifies PostgreSQL connection (SELECT 1)
- Verifies NATS connection (if enabled)
- Returns 503 if any dependency is unavailable

**Startup** (`/_/health/startup`):
- Same as readiness, but only used during pod startup
- Allows longer initial connection timeout

Response format:
```json
{
  "status": "UP" | "DOWN",
  "checks": {
    "database": { "status": "UP" },
    "nats": { "status": "UP" }  // only if NATS enabled
  }
}
```

#### flovyn-app Health Checks

**Liveness** (`/api/health/live`):
- Always returns 200 if Node.js server is responding

**Readiness** (`/api/health/ready`):
- Verifies PostgreSQL connection (Better Auth database)
- Verifies backend server connectivity (BACKEND_URL)
- Returns 503 if any dependency is unavailable

**Startup** (`/api/health/startup`):
- Same as readiness

### 2. Automatic Migrations

#### flovyn-server (Already Working)

The Rust server already handles migrations correctly:
1. On startup, `run_migrations()` is called before the HTTP/gRPC servers start
2. Migrations are embedded in the binary via SQLx `migrate!` macro
3. Plugin migrations run after core migrations

**No changes needed** - the current implementation is correct.

#### flovyn-app (Needs Update)

The Next.js app needs a startup script that:
1. Runs Better Auth migrations
2. Then starts the Next.js server

Option A: **Entrypoint script** (Recommended)
```bash
#!/bin/sh
# docker-entrypoint.sh
set -e

# Run migrations
node /app/scripts/migrate.js

# Start the server
exec node apps/web/server.js
```

Option B: **Programmatic migration in server.js**

The entrypoint script approach is simpler and follows Docker best practices.

### 3. Graceful Shutdown

#### flovyn-server

Add SIGTERM handler that:
1. Sets health/ready to return 503 (stop receiving new traffic)
2. Stops accepting new gRPC streams
3. Waits for in-flight requests to complete (with timeout)
4. Flushes telemetry traces
5. Closes database connections
6. Exits cleanly

#### flovyn-app

Next.js standalone mode already handles SIGTERM gracefully. Verify and document.

### 4. Environment Variables Reference

Document the complete set of environment variables needed for Kubernetes deployment:

#### flovyn-server

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | Yes | - | PostgreSQL connection string |
| `SERVER_PORT` | No | 8000 | HTTP port |
| `GRPC_SERVER_PORT` | No | 9090 | gRPC port |
| `NATS__ENABLED` | No | false | Enable NATS messaging |
| `NATS__URL` | Conditional | nats://localhost:4222 | NATS server URL |
| `FLOVYN_SECURITY__ENABLED` | No | true | Enable authentication |
| `WORKER_TOKEN_SECRET` | Yes (prod) | - | HMAC secret for worker tokens |
| `OTEL__ENABLED` | No | false | Enable OpenTelemetry tracing |
| `OTEL__OTLP_ENDPOINT` | Conditional | - | OTLP gRPC endpoint |
| `METRICS__ENABLED` | No | false | Enable Prometheus metrics |
| `METRICS__PORT` | No | 9091 | Prometheus metrics port |
| `RUST_LOG` | No | warn | Log level |

#### flovyn-app

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | Yes | - | PostgreSQL connection string |
| `BACKEND_URL` | Yes | - | flovyn-server HTTP endpoint |
| `BETTER_AUTH_SECRET` | Yes | - | Session signing secret (32+ chars) |
| `BETTER_AUTH_TRUST_HOST` | No | false | Trust X-Forwarded-Host header |
| `NEXT_PUBLIC_APP_URL` | Yes | - | Public URL for the app |
| `NODE_ENV` | No | production | Node environment |

## Architecture Decisions

### AD-1: Separate Health Endpoints vs. Single with Query Params

**Decision**: Separate endpoints (`/live`, `/ready`, `/startup`)

**Rationale**:
- Kubernetes probe configuration is simpler (just different paths)
- Each endpoint can have different caching/timeout characteristics
- Clearer semantics and easier debugging
- Industry standard practice (similar to Spring Boot Actuator)

### AD-2: Migration Strategy for flovyn-app

**Decision**: Entrypoint script runs migrations before server starts

**Rationale**:
- Simple and explicit
- Migrations complete before any traffic is accepted
- Startup probe will fail if migrations fail
- Easy to debug (separate step in container logs)

**Alternative considered**: Init container for migrations
- Pro: Separates concerns, can have different resource limits
- Con: More complex Kubernetes config, harder to debug
- Rejected: Over-engineering for our use case

### AD-3: Health Check Timeout Strategy

**Decision**: Database health checks use 5-second timeout

**Rationale**:
- Fast enough to detect connection issues
- Slow enough to handle temporary network hiccups
- Kubernetes probe defaults (initialDelaySeconds, periodSeconds) can be tuned separately

## Implementation Phases

### Phase 1: flovyn-server Health Endpoints
- Add `/_/health/live` endpoint
- Add `/_/health/ready` endpoint with DB check
- Add `/_/health/startup` endpoint
- Add optional NATS connectivity check

### Phase 2: flovyn-app Health Endpoints
- Add `/api/health/live` route
- Add `/api/health/ready` route with DB and backend check
- Add `/api/health/startup` route

### Phase 3: flovyn-app Migrations
- Create migration script (`scripts/migrate.js`)
- Create `docker-entrypoint.sh`
- Update Dockerfile to use entrypoint

### Phase 4: Graceful Shutdown
- Add SIGTERM handler to flovyn-server
- Verify flovyn-app handles SIGTERM correctly
- Test shutdown behavior with in-flight requests

### Phase 5: Documentation and Testing
- Document all environment variables
- Update E2E test harness to use new health endpoints
- Test health endpoints report correct status when dependencies are down

## Decisions

1. **Health checks do not require authentication** - Endpoints are internal-only (not exposed via ingress)

2. **Migration duration is not a concern** - Startup probes use standard timeouts

3. **No `/metrics` endpoint for flovyn-app** - flovyn-server metrics are sufficient

4. **NATS H/A is out of scope** - Infrastructure team responsibility

## References

- [Kubernetes Liveness and Readiness Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [E2E Testing Design](./20260115_e2e_testing_playwright_testcontainers.md) - Shows current container configuration
- flovyn-server health endpoint: `flovyn-server/server/src/api/rest/health.rs`
- flovyn-app Dockerfile: `flovyn-app/Dockerfile`
