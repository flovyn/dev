# E2E Testing with Playwright and Testcontainers

**Date**: 2026-01-15
**Status**: Draft
**Author**: Engineering

## Overview

This document outlines the design for end-to-end (E2E) testing of the Flovyn web application using Playwright for browser automation and Testcontainers for infrastructure orchestration. The goal is to create a comprehensive, reliable, and fast E2E test suite that validates critical user journeys.

## Goals

1. **Full stack testing**: Validate the entire system from UI to database
2. **Test isolation**: Each test runs against clean infrastructure state
3. **Reproducibility**: Tests produce consistent results across environments
4. **Developer experience**: Fast feedback loop with clear failure diagnostics
5. **CI/CD integration**: Tests run reliably in automated pipelines

## Non-Goals

- Visual regression testing (can be added later)
- Performance/load testing
- Mobile device testing (desktop browsers only for now)

## Architecture

### Service Composition

The E2E test environment requires the following services:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Test Process                              │
│  ┌─────────────────┐    ┌─────────────────────────────────────┐ │
│  │    Playwright   │────│         Test Harness                │ │
│  │    Browser      │    │  - Container orchestration          │ │
│  │                 │    │  - Health checks                    │ │
│  └────────┬────────┘    │  - Cleanup management               │ │
│           │             └─────────────────────────────────────┘ │
└───────────┼─────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Next.js App (Web)                            │
│                     localhost:3000                               │
│  - API Proxy to flovyn-server                                   │
│  - Better Auth for authentication                               │
└─────────────────────┬───────────────────────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
    ▼                 ▼                 ▼
┌─────────┐    ┌─────────────┐    ┌─────────────┐
│postgres │    │flovyn-server│────│   NATS      │
│  -app   │    │  :8000/9090 │    │  JetStream  │
│  :5433  │    └──────┬──────┘    │   :4222     │
└─────────┘           │           └──────┬──────┘
                      │                  │
               ┌──────┴──────┐    ┌──────┴──────┐
               │  postgres   │    │   sample    │
               │   -server   │    │   worker    │
               │    :5432    │    │  (patterns) │
               └─────────────┘    └─────────────┘
```

### Key Components

| Component | Source | Image/Binary |
|-----------|--------|--------------|
| PostgreSQL (App) | Docker Hub | `postgres:18-alpine` |
| PostgreSQL (Server) | Docker Hub | `postgres:18-alpine` |
| NATS | Docker Hub | `nats:latest` with `-js` |
| flovyn-server | `../flovyn-server` | Built Docker image |
| Sample Worker | `../sdk-rust/examples/patterns` | Built Docker image |
| Next.js App | `apps/web` | `pnpm dev` or built |

### Testcontainers Strategy

Following the patterns established in `flovyn-server/tests/integration/harness.rs`:

1. **PostgreSQL (App)**: `postgres:18-alpine` for Better Auth session/user storage
2. **PostgreSQL (Server)**: `postgres:18-alpine` for workflow state and events
3. **NATS**: `nats:latest` with JetStream for event messaging
4. **flovyn-server**: Binary spawned as child process (or containerized)
5. **Next.js App**: Started via `pnpm dev` or built and served

### Container Labels

All containers will be labeled for identification and cleanup:

```javascript
const LABELS = {
  'flovyn-e2e-test': 'true',
  'flovyn-e2e-session': sessionId,  // UUID prefix for each test run
};
```

## Docker Images

### Image Naming Convention

| Image | Registry Path |
|-------|--------------|
| Server | `rg.fr-par.scw.cloud/flovyn/flovyn-server:latest` |
| Worker (patterns) | `rg.fr-par.scw.cloud/flovyn/patterns-worker:latest` |
| Worker (hello) | `rg.fr-par.scw.cloud/flovyn/hello-worker:latest` |

For local development and E2E tests, images should be built/tagged locally with these same names.

### flovyn-server Image

The server already has a production-ready Dockerfile at `../flovyn-server/Dockerfile`. Key characteristics:

- **Multi-stage build**: Builder (rust:latest) + Runtime (debian:bookworm-slim)
- **Feature flags**: Supports `FEATURES` build arg (default, all-plugins, none, custom)
- **Migrations included**: Server and plugin migrations bundled
- **Ports**: 8000 (HTTP), 9090 (gRPC)
- **Health check**: `/_/health` endpoint

**Building the server image:**

```bash
# From ../flovyn-server directory
docker build -t rg.fr-par.scw.cloud/flovyn/flovyn-server:latest \
  --build-arg FEATURES=all-plugins \
  -f Dockerfile .
```

### Sample Worker Image (patterns-sample)

We need to create a Dockerfile for the sample worker. The `patterns` example is ideal because it demonstrates:
- Durable timers (ReminderWorkflow, MultiStepTimerWorkflow)
- Promises/external signals (ApprovalWorkflow, MultiApprovalWorkflow)
- Child workflows (BatchProcessingWorkflow, ItemProcessorWorkflow)
- Retry patterns (RetryWorkflow, CircuitBreakerWorkflow)
- Parallel execution (FanOutFanInWorkflow, RacingWorkflow, TimeoutWorkflow)

**Dockerfile location:** `../sdk-rust/examples/patterns/Dockerfile`

```dockerfile
# ../sdk-rust/examples/patterns/Dockerfile
# Build context should be ../sdk-rust (repository root)

# =============================================================================
# Builder Stage
# =============================================================================
FROM rust:1.83-slim-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy workspace Cargo files for dependency caching
COPY Cargo.toml Cargo.lock ./

# Copy the proto files (required for gRPC code generation)
COPY proto ./proto

# Copy the SDK crates
COPY worker-sdk ./worker-sdk
COPY worker-core ./worker-core

# Copy the patterns example
COPY examples/patterns ./examples/patterns

# Build release binary
RUN cargo build --release --package patterns-sample

# =============================================================================
# Runtime Stage
# =============================================================================
FROM debian:bookworm-slim

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from builder
COPY --from=builder /app/target/release/patterns-sample /usr/local/bin/patterns-sample

# Set environment variables (can be overridden at runtime)
ENV RUST_LOG=info,patterns_sample=debug
ENV FLOVYN_GRPC_SERVER_HOST=flovyn-server
ENV FLOVYN_GRPC_SERVER_PORT=9090
ENV FLOVYN_QUEUE=default

# The worker connects to the server, no ports to expose
# It will receive work via gRPC streaming

# Run the worker
CMD ["patterns-sample"]
```

**Building the worker image:**

```bash
# From ../sdk-rust directory
docker build -t rg.fr-par.scw.cloud/flovyn/patterns-worker:latest \
  -f examples/patterns/Dockerfile .
```

### Alternative: Hello World Sample (Minimal)

For simpler tests, use the hello-world example:

**Dockerfile location:** `../sdk-rust/examples/hello-world/Dockerfile`

```dockerfile
# ../sdk-rust/examples/hello-world/Dockerfile
# Build context should be ../sdk-rust (repository root)

FROM rust:1.83-slim-bookworm AS builder

RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY proto ./proto
COPY worker-sdk ./worker-sdk
COPY worker-core ./worker-core
COPY examples/hello-world ./examples/hello-world

RUN cargo build --release --package hello-world-sample

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/hello-world-sample /usr/local/bin/hello-world-sample

ENV RUST_LOG=info,hello_world_sample=debug
ENV FLOVYN_GRPC_SERVER_HOST=flovyn-server
ENV FLOVYN_GRPC_SERVER_PORT=9090
ENV FLOVYN_QUEUE=default

CMD ["hello-world-sample"]
```

### Build Script

Create a build script to build all required images:

**Location:** `flovyn-app/bin/build-e2e-images.sh`

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Image registry prefix (can be overridden)
REGISTRY="${FLOVYN_REGISTRY:-rg.fr-par.scw.cloud/flovyn}"

echo "Building E2E test Docker images..."
echo "Registry: $REGISTRY"

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

# Build hello-world worker (optional, for simpler tests)
echo "Building ${REGISTRY}/hello-worker:latest..."
docker build -t "${REGISTRY}/hello-worker:latest" \
  -f "$ROOT_DIR/../sdk-rust/examples/hello-world/Dockerfile" \
  "$ROOT_DIR/../sdk-rust"

echo ""
echo "All E2E images built successfully!"
echo ""
echo "Images created:"
docker images | grep -E "(flovyn-server|patterns-worker|hello-worker)"
```

### Workflows Provided by Sample Workers

#### patterns-sample Workflows

| Workflow | Kind | Description | Test Use Case |
|----------|------|-------------|---------------|
| ReminderWorkflow | `reminder` | Waits for duration then completes | Timer/schedule tests |
| MultiStepTimerWorkflow | `multi-step-timer` | Multiple sequential timers | Complex timer tests |
| ApprovalWorkflow | `approval` | Waits for external approval signal | Promise/signal tests |
| MultiApprovalWorkflow | `multi-approval` | Waits for multiple approvals | Multi-signal tests |
| BatchProcessingWorkflow | `batch-processing` | Spawns child workflows | Child workflow tests |
| ItemProcessorWorkflow | `item-processor` | Processes single item (child) | Child workflow detail |
| RetryWorkflow | `retry` | Exponential backoff retry | Retry pattern tests |
| CircuitBreakerWorkflow | `circuit-breaker` | Circuit breaker pattern | Fault tolerance tests |
| FanOutFanInWorkflow | `fan-out-fan-in` | Parallel then aggregate | Parallel execution |
| RacingWorkflow | `racing` | Race multiple operations | First-completion tests |
| TimeoutWorkflow | `timeout` | Operation with timeout | Timeout tests |
| BatchWithConcurrencyWorkflow | `batch-concurrency` | Controlled parallelism | Concurrency tests |

#### hello-world-sample Workflows

| Workflow | Kind | Description | Test Use Case |
|----------|------|-------------|---------------|
| GreetingWorkflow | `greeting` | Simple greeting workflow | Basic workflow tests |
| EchoTask | `echo` | Echo task with timestamp | Basic task tests |

### Using Pre-built Images in Tests

The test harness will use `GenericContainer` with images following the naming convention. Image names can be overridden via environment variables (matching the pattern from `sdk-rust/worker-sdk/tests/e2e/harness.rs`):

```typescript
// Default image names (can be overridden via env vars)
const DEFAULT_SERVER_IMAGE = 'rg.fr-par.scw.cloud/flovyn/flovyn-server:latest';
const SERVER_IMAGE = 'rg.fr-par.scw.cloud/flovyn/flovyn-server:latest';
const WORKER_IMAGE = 'rg.fr-par.scw.cloud/flovyn/patterns-worker:latest';

async function startFlovynServer(sessionId: string, config: ServerConfig): Promise<StartedTestContainer> {
  console.log(`[HARNESS] Starting flovyn-server from image: ${SERVER_IMAGE}`);

  return new GenericContainer(SERVER_IMAGE)
    .withExtraHost('host.docker.internal', 'host-gateway')  // Required for Linux
    .withEnvironment({
      DATABASE_URL: `postgres://flovyn:flovyn@host.docker.internal:${config.dbPort}/flovyn`,
      NATS__ENABLED: 'true',
      NATS__URL: `nats://host.docker.internal:${config.natsPort}`,
      SERVER_PORT: '8000',
      GRPC_SERVER_PORT: '9090',
      RUST_LOG: 'warn,flovyn_server=info',
    })
    .withExposedPorts(8000, 9090)
    .withLabels({
      'flovyn-e2e-test': 'true',
      'flovyn-e2e-session': sessionId,
    })
    .withWaitStrategy(Wait.forHttp('/_/health', 8000).withStatusCode(200))
    .withStartupTimeout(120000)  // 2 minutes for server startup
    .start();
}

async function startSampleWorker(sessionId: string, config: WorkerConfig): Promise<StartedTestContainer> {
  const imageName = getWorkerImage();
  console.log(`[HARNESS] Starting worker from image: ${imageName}`);

  return new GenericContainer(imageName)
    .withExtraHost('host.docker.internal', 'host-gateway')
    .withEnvironment({
      FLOVYN_GRPC_SERVER_HOST: 'host.docker.internal',
      FLOVYN_GRPC_SERVER_PORT: config.serverGrpcPort.toString(),
      FLOVYN_ORG_ID: config.orgId,
      FLOVYN_WORKER_TOKEN: config.workerToken,
      FLOVYN_QUEUE: 'default',
      RUST_LOG: 'info,patterns_sample=debug',
    })
    .withLabels({
      'flovyn-e2e-test': 'true',
      'flovyn-e2e-session': sessionId,
    })
    // Worker has no health endpoint, wait for log message
    .withWaitStrategy(Wait.forLogMessage('Worker started successfully'))
    .withStartupTimeout(30000)
    .start();
}
```

### Network Configuration

For containers to communicate, use Docker's host networking or a shared network:

```typescript
// Option 1: Use host.docker.internal (simpler for testcontainers)
// Containers access host-exposed ports

// Option 2: Create a shared Docker network
import { Network } from 'testcontainers';

const network = await new Network().start();

const postgres = await new GenericContainer('postgres:18-alpine')
  .withNetwork(network)
  .withNetworkAliases('postgres-server')
  // ...
  .start();

const server = await new GenericContainer(getServerImage())  // 'rg.fr-par.scw.cloud/flovyn/flovyn-server:latest'
  .withNetwork(network)
  .withNetworkAliases('flovyn-server')
  .withEnvironment({
    DATABASE_URL: 'postgres://flovyn:flovyn@postgres-server:5432/flovyn',
    // ...
  })
  .start();

const worker = await new GenericContainer(getWorkerImage())  // 'rg.fr-par.scw.cloud/flovyn/patterns-worker:latest'
  .withNetwork(network)
  .withEnvironment({
    FLOVYN_GRPC_SERVER_HOST: 'flovyn-server',
    FLOVYN_GRPC_SERVER_PORT: '9090',
    // ...
  })
  .start();
```

## Test Harness Design

### TypeScript Implementation

```typescript
// tests/e2e/harness.ts

import { GenericContainer, Wait, StartedTestContainer } from 'testcontainers';
import { ChildProcess, spawn } from 'child_process';
import { chromium, Browser, BrowserContext, Page } from '@playwright/test';

interface TestHarness {
  // Containers
  postgresApp: StartedTestContainer;
  postgresServer: StartedTestContainer;
  nats: StartedTestContainer;

  // Processes
  serverProcess: ChildProcess;
  webProcess: ChildProcess;

  // Ports
  appDbPort: number;
  serverDbPort: number;
  natsPort: number;
  serverHttpPort: number;
  serverGrpcPort: number;
  webPort: number;

  // Test data
  sessionId: string;
  testOrg: { id: string; slug: string; name: string };
  testUser: { email: string; password: string };
  apiKey: string;
}
```

### Harness Lifecycle

```typescript
// Singleton pattern - one harness per test run
let harnessInstance: TestHarness | null = null;

export async function getHarness(): Promise<TestHarness> {
  if (!harnessInstance) {
    harnessInstance = await createHarness();
  }
  return harnessInstance;
}

async function createHarness(): Promise<TestHarness> {
  const sessionId = crypto.randomUUID().substring(0, 8);

  // 1. Start containers in parallel
  const [postgresApp, postgresServer, nats] = await Promise.all([
    startPostgresApp(sessionId),
    startPostgresServer(sessionId),
    startNats(sessionId),
  ]);

  // 2. Run database migrations
  await runAppMigrations(postgresApp.getMappedPort(5432));
  await runServerMigrations(postgresServer.getMappedPort(5432));

  // 3. Seed test data
  const { testOrg, testUser, apiKey } = await seedTestData(postgresApp, postgresServer);

  // 4. Start flovyn-server
  const serverProcess = await startFlovynServer({
    dbPort: postgresServer.getMappedPort(5432),
    natsPort: nats.getMappedPort(4222),
  });

  // 5. Start Next.js app
  const webProcess = await startNextApp({
    appDbPort: postgresApp.getMappedPort(5432),
    serverPort: serverProcess.httpPort,
  });

  // 6. Wait for health checks
  await waitForHealth(`http://localhost:${webProcess.port}`);

  return { /* ... */ };
}
```

### Container Configuration

```typescript
async function startPostgresApp(sessionId: string): Promise<StartedTestContainer> {
  return new GenericContainer('postgres:18-alpine')
    .withEnvironment({
      POSTGRES_USER: 'flovyn-app',
      POSTGRES_PASSWORD: 'flovyn-app',
      POSTGRES_DB: 'flovyn-app',
    })
    .withExposedPorts(5432)
    .withLabels({
      'flovyn-e2e-test': 'true',
      'flovyn-e2e-session': sessionId,
    })
    .withWaitStrategy(Wait.forLogMessage('database system is ready to accept connections'))
    .start();
}

async function startNats(sessionId: string): Promise<StartedTestContainer> {
  return new GenericContainer('nats:latest')
    .withCommand(['-js'])  // Enable JetStream
    .withExposedPorts(4222)
    .withLabels({
      'flovyn-e2e-test': 'true',
      'flovyn-e2e-session': sessionId,
    })
    .withWaitStrategy(Wait.forLogMessage('Server is ready'))
    .start();
}
```

### Health Check Polling

```typescript
async function waitForHealth(baseUrl: string, timeout = 30000): Promise<void> {
  const start = Date.now();
  const healthUrl = `${baseUrl}/api/health`;  // Or appropriate endpoint

  while (Date.now() - start < timeout) {
    try {
      const response = await fetch(healthUrl);
      if (response.ok) return;
    } catch {
      // Server not ready yet
    }
    await sleep(1000);
  }

  throw new Error(`Health check failed after ${timeout}ms`);
}
```

### Cleanup Strategy

Multiple layers of cleanup following the Rust harness pattern:

1. **Playwright teardown**: Built-in cleanup via `globalTeardown`
2. **Process signal handlers**: Clean up on SIGINT/SIGTERM
3. **Cleanup script**: Manual cleanup for orphaned containers

```typescript
// globalTeardown.ts
export default async function globalTeardown() {
  const harness = getHarnessIfExists();
  if (harness) {
    // Kill processes
    harness.webProcess?.kill('SIGTERM');
    harness.serverProcess?.kill('SIGTERM');

    // Stop containers
    await Promise.all([
      harness.postgresApp?.stop(),
      harness.postgresServer?.stop(),
      harness.nats?.stop(),
    ]);
  }
}
```

```bash
#!/bin/bash
# bin/cleanup-e2e-containers.sh

# Find and remove containers by label
docker ps -aq --filter "label=flovyn-e2e-test=true" | xargs -r docker rm -f
```

## Test Organization

### Directory Structure

```
tests/
├── e2e/
│   ├── harness.ts              # Test infrastructure
│   ├── fixtures.ts             # Custom Playwright fixtures
│   ├── helpers/
│   │   ├── auth.ts             # Authentication helpers
│   │   ├── api.ts              # Direct API helpers
│   │   └── data.ts             # Test data generators
│   ├── auth/
│   │   ├── login.spec.ts
│   │   ├── register.spec.ts
│   │   ├── logout.spec.ts
│   │   └── device-auth.spec.ts
│   ├── organization/
│   │   ├── create.spec.ts
│   │   ├── members.spec.ts
│   │   ├── invite.spec.ts
│   │   └── settings.spec.ts
│   ├── workflows/
│   │   ├── list.spec.ts
│   │   ├── filter.spec.ts
│   │   └── details.spec.ts
│   ├── executions/
│   │   ├── list.spec.ts
│   │   ├── timeline.spec.ts
│   │   ├── events.spec.ts
│   │   ├── cancel.spec.ts
│   │   └── retry.spec.ts
│   ├── workers/
│   │   └── list.spec.ts
│   └── global-setup.ts
│   └── global-teardown.ts
└── playwright.config.ts
```

### Playwright Configuration

```typescript
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,   // Run tests in parallel
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 4 : undefined,  // 4 workers in CI, auto in local
  reporter: [
    ['html'],
    ['list'],
    process.env.CI ? ['github'] : ['line'],
  ],

  globalSetup: './tests/e2e/global-setup.ts',
  globalTeardown: './tests/e2e/global-teardown.ts',

  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  timeout: 60000,  // 60s per test
  expect: {
    timeout: 10000,
  },
});
```

### Custom Fixtures

```typescript
// fixtures.ts
import { test as base, expect } from '@playwright/test';
import { getHarness, TestHarness } from './harness';

interface TestFixtures {
  harness: TestHarness;
  authenticatedPage: Page;
  adminPage: Page;
}

export const test = base.extend<TestFixtures>({
  harness: async ({}, use) => {
    const harness = await getHarness();
    await use(harness);
  },

  authenticatedPage: async ({ page, harness }, use) => {
    // Log in as test user
    await page.goto('/auth/login');
    await page.fill('[name="email"]', harness.testUser.email);
    await page.fill('[name="password"]', harness.testUser.password);
    await page.click('button[type="submit"]');
    await page.waitForURL('/orgs');
    await use(page);
  },

  adminPage: async ({ page, harness }, use) => {
    // Log in as admin user
    await page.goto('/auth/login');
    await page.fill('[name="email"]', harness.adminUser.email);
    await page.fill('[name="password"]', harness.adminUser.password);
    await page.click('button[type="submit"]');
    await page.waitForURL('/orgs');
    // Navigate to test org
    await page.goto(`/org/${harness.testOrg.slug}`);
    await use(page);
  },
});

export { expect };
```

## Common Test Scenarios

### 1. Authentication Flows

#### Login

```typescript
// auth/login.spec.ts
import { test, expect } from '../fixtures';

test.describe('Login', () => {
  test('successful login redirects to organization list', async ({ page, harness }) => {
    await page.goto('/auth/login');

    await page.fill('[name="email"]', harness.testUser.email);
    await page.fill('[name="password"]', harness.testUser.password);
    await page.click('button[type="submit"]');

    await expect(page).toHaveURL('/orgs');
    await expect(page.getByText(harness.testOrg.name)).toBeVisible();
  });

  test('invalid credentials show error message', async ({ page }) => {
    await page.goto('/auth/login');

    await page.fill('[name="email"]', 'invalid@example.com');
    await page.fill('[name="password"]', 'wrongpassword');
    await page.click('button[type="submit"]');

    await expect(page.getByText(/invalid credentials/i)).toBeVisible();
    await expect(page).toHaveURL('/auth/login');
  });

  test('login with returnUrl redirects to specified page', async ({ page, harness }) => {
    const returnUrl = `/org/${harness.testOrg.slug}/workflows`;
    await page.goto(`/auth/login?returnUrl=${encodeURIComponent(returnUrl)}`);

    await page.fill('[name="email"]', harness.testUser.email);
    await page.fill('[name="password"]', harness.testUser.password);
    await page.click('button[type="submit"]');

    await expect(page).toHaveURL(returnUrl);
  });
});
```

#### Registration

```typescript
// auth/register.spec.ts
test.describe('Registration', () => {
  test('successful registration creates user and redirects', async ({ page }) => {
    const email = `test-${Date.now()}@example.com`;

    await page.goto('/auth/register');

    await page.fill('[name="name"]', 'Test User');
    await page.fill('[name="email"]', email);
    await page.fill('[name="password"]', 'SecurePassword123!');
    await page.click('button[type="submit"]');

    await expect(page).toHaveURL('/orgs');
  });

  test('shows validation errors for invalid input', async ({ page }) => {
    await page.goto('/auth/register');

    await page.fill('[name="email"]', 'not-an-email');
    await page.fill('[name="password"]', '123');  // Too short
    await page.click('button[type="submit"]');

    await expect(page.getByText(/valid email/i)).toBeVisible();
    await expect(page.getByText(/password/i)).toBeVisible();
  });
});
```

#### Device Authorization

```typescript
// auth/device-auth.spec.ts
test.describe('Device Authorization', () => {
  test('approve device authorization with valid code', async ({ authenticatedPage, harness }) => {
    // Generate a device code via API
    const deviceCode = await harness.api.createDeviceCode();

    await authenticatedPage.goto(`/device?code=${deviceCode.userCode}`);
    await authenticatedPage.click('button:has-text("Approve")');

    await expect(authenticatedPage).toHaveURL('/device/success');
  });

  test('deny device authorization', async ({ authenticatedPage, harness }) => {
    const deviceCode = await harness.api.createDeviceCode();

    await authenticatedPage.goto(`/device?code=${deviceCode.userCode}`);
    await authenticatedPage.click('button:has-text("Deny")');

    await expect(authenticatedPage).toHaveURL('/device/denied');
  });
});
```

### 2. Organization Management

```typescript
// organization/create.spec.ts
test.describe('Organization Creation', () => {
  test('create new organization', async ({ authenticatedPage }) => {
    await authenticatedPage.goto('/orgs/new');

    const orgName = `Test Org ${Date.now()}`;
    await authenticatedPage.fill('[name="name"]', orgName);
    await authenticatedPage.click('button[type="submit"]');

    // Should redirect to new org dashboard
    await expect(authenticatedPage.getByRole('heading', { name: orgName })).toBeVisible();
  });
});

// organization/members.spec.ts
test.describe('Member Management', () => {
  test('view organization members', async ({ adminPage, harness }) => {
    await adminPage.goto(`/org/${harness.testOrg.slug}/members`);

    // Should see the admin user in the list
    await expect(adminPage.getByText(harness.adminUser.email)).toBeVisible();
  });

  test('invite new member', async ({ adminPage, harness }) => {
    await adminPage.goto(`/org/${harness.testOrg.slug}/members`);

    await adminPage.click('button:has-text("Invite Member")');

    const inviteEmail = `invite-${Date.now()}@example.com`;
    await adminPage.fill('[name="email"]', inviteEmail);
    await adminPage.selectOption('[name="role"]', 'member');
    await adminPage.click('button:has-text("Send Invitation")');

    // Switch to pending tab
    await adminPage.click('button:has-text("Pending")');
    await expect(adminPage.getByText(inviteEmail)).toBeVisible();
  });

  test('cancel pending invitation', async ({ adminPage, harness }) => {
    // First create an invitation
    const inviteEmail = `cancel-${Date.now()}@example.com`;
    await harness.api.inviteMember(harness.testOrg.id, inviteEmail, 'member');

    await adminPage.goto(`/org/${harness.testOrg.slug}/members`);
    await adminPage.click('button:has-text("Pending")');

    // Find and cancel the invitation
    const row = adminPage.getByRole('row').filter({ hasText: inviteEmail });
    await row.getByRole('button', { name: /cancel/i }).click();

    // Confirm cancellation
    await adminPage.click('button:has-text("Confirm")');

    await expect(adminPage.getByText(inviteEmail)).not.toBeVisible();
  });

  test('non-admin cannot access member management', async ({ authenticatedPage, harness }) => {
    // Create a member-role user and log in
    const memberUser = await harness.createUser('member');
    await harness.addToOrg(memberUser, harness.testOrg.id, 'member');

    await authenticatedPage.goto('/auth/login');
    await authenticatedPage.fill('[name="email"]', memberUser.email);
    await authenticatedPage.fill('[name="password"]', memberUser.password);
    await authenticatedPage.click('button[type="submit"]');

    // Try to access members page
    await authenticatedPage.goto(`/org/${harness.testOrg.slug}/members`);

    // Should see access denied or be redirected
    await expect(authenticatedPage.getByText(/access denied|not authorized/i)).toBeVisible();
  });
});
```

### 3. Workflow Management

```typescript
// workflows/list.spec.ts
test.describe('Workflow Definitions', () => {
  test('list workflow definitions', async ({ adminPage, harness }) => {
    // Seed some workflow definitions
    await harness.api.registerWorkflow({
      kind: 'test-workflow',
      name: 'Test Workflow',
      version: '1.0.0',
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows`);

    await expect(adminPage.getByText('test-workflow')).toBeVisible();
    await expect(adminPage.getByText('Test Workflow')).toBeVisible();
  });

  test('filter workflows by FQL query', async ({ adminPage, harness }) => {
    // Seed workflows with different kinds
    await harness.api.registerWorkflow({ kind: 'order-workflow', name: 'Order Processing' });
    await harness.api.registerWorkflow({ kind: 'payment-workflow', name: 'Payment Processing' });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows`);

    // Enter FQL query
    await adminPage.fill('[data-testid="fql-input"]', 'kind = "order-workflow"');
    await adminPage.keyboard.press('Enter');

    await expect(adminPage.getByText('Order Processing')).toBeVisible();
    await expect(adminPage.getByText('Payment Processing')).not.toBeVisible();
  });

  test('save and load FQL query', async ({ adminPage, harness }) => {
    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows`);

    // Enter and save query
    await adminPage.fill('[data-testid="fql-input"]', 'kind = "test"');
    await adminPage.click('button:has-text("Save Query")');
    await adminPage.fill('[name="queryName"]', 'Test Filter');
    await adminPage.click('button:has-text("Save")');

    // Clear and reload from saved
    await adminPage.fill('[data-testid="fql-input"]', '');
    await adminPage.click('button:has-text("Saved Queries")');
    await adminPage.click('text=Test Filter');

    await expect(adminPage.locator('[data-testid="fql-input"]')).toHaveValue('kind = "test"');
  });
});
```

### 4. Workflow Execution Monitoring

```typescript
// executions/list.spec.ts
test.describe('Execution List', () => {
  test('list workflow executions with time range filter', async ({ adminPage, harness }) => {
    // Create a workflow execution
    const execution = await harness.api.startWorkflow({
      kind: 'test-workflow',
      input: { test: true },
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions`);

    await expect(adminPage.getByText(execution.id)).toBeVisible();
  });

  test('group executions by status', async ({ adminPage, harness }) => {
    // Create executions with different statuses
    await harness.api.startWorkflow({ kind: 'test-workflow', input: {} });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions`);

    // Change grouping
    await adminPage.selectOption('[data-testid="group-by"]', 'status');

    await expect(adminPage.getByText('RUNNING')).toBeVisible();
  });
});

// executions/timeline.spec.ts
test.describe('Execution Timeline', () => {
  test('view execution timeline with task details', async ({ adminPage, harness }) => {
    // Create and wait for execution to have some events
    const execution = await harness.api.startWorkflow({
      kind: 'test-workflow',
      input: { test: true },
    });

    // Wait for execution to progress
    await harness.waitForExecutionStatus(execution.id, 'COMPLETED');

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions/${execution.id}`);

    // Should see timeline tab active
    await expect(adminPage.getByRole('tab', { name: 'Timeline', selected: true })).toBeVisible();

    // Click on a task to see details
    await adminPage.click('[data-testid="task-span"]');

    // Task detail panel should open
    await expect(adminPage.getByTestId('task-detail-panel')).toBeVisible();
  });

  test('view execution events in history tab', async ({ adminPage, harness }) => {
    const execution = await harness.api.startWorkflow({ kind: 'test-workflow', input: {} });
    await harness.waitForExecutionStatus(execution.id, 'COMPLETED');

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions/${execution.id}`);

    // Switch to history tab
    await adminPage.click('button:has-text("History")');

    // Should see workflow events
    await expect(adminPage.getByText('WorkflowStarted')).toBeVisible();
    await expect(adminPage.getByText('WorkflowCompleted')).toBeVisible();
  });
});

// executions/cancel.spec.ts
test.describe('Cancel Execution', () => {
  test('cancel running execution', async ({ adminPage, harness }) => {
    // Start a long-running workflow
    const execution = await harness.api.startWorkflow({
      kind: 'long-running-workflow',
      input: { duration: 60000 },
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions/${execution.id}`);

    // Click cancel button
    await adminPage.click('button:has-text("Cancel")');

    // Confirm cancellation
    await adminPage.click('button:has-text("Confirm")');

    // Should show cancelled status
    await expect(adminPage.getByText('CANCELLED')).toBeVisible();
  });
});

// executions/retry.spec.ts
test.describe('Retry Execution', () => {
  test('retry failed execution', async ({ adminPage, harness }) => {
    // Create a failing workflow
    const execution = await harness.api.startWorkflow({
      kind: 'failing-workflow',
      input: { shouldFail: true },
    });

    await harness.waitForExecutionStatus(execution.id, 'FAILED');

    await adminPage.goto(`/org/${harness.testOrg.slug}/workflows/executions/${execution.id}`);

    // Click retry button
    await adminPage.click('button:has-text("Retry")');

    // Optionally modify input
    await adminPage.fill('[name="input"]', JSON.stringify({ shouldFail: false }));
    await adminPage.click('button:has-text("Start Retry")');

    // Should redirect to new execution
    await expect(adminPage).not.toHaveURL(new RegExp(execution.id));
  });
});
```

### 5. Worker Management

```typescript
// workers/list.spec.ts
test.describe('Worker Management', () => {
  test('list registered workers', async ({ adminPage, harness }) => {
    // Register a worker via API
    await harness.api.registerWorker({
      id: 'test-worker-1',
      capabilities: ['test-workflow'],
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workers`);

    await expect(adminPage.getByText('test-worker-1')).toBeVisible();
  });

  test('view worker details', async ({ adminPage, harness }) => {
    const workerId = 'test-worker-detail';
    await harness.api.registerWorker({ id: workerId });

    await adminPage.goto(`/org/${harness.testOrg.slug}/workers`);

    // Click to open detail panel
    await adminPage.click(`text=${workerId}`);

    await expect(adminPage.getByTestId('worker-detail-panel')).toBeVisible();
  });

  test('non-admin cannot access workers page', async ({ authenticatedPage, harness }) => {
    await authenticatedPage.goto(`/org/${harness.testOrg.slug}/workers`);

    await expect(authenticatedPage.getByText(/access denied|not authorized/i)).toBeVisible();
  });
});
```

### 6. Metadata Fields Management

```typescript
// organization/settings.spec.ts
test.describe('Metadata Fields', () => {
  test('create custom metadata field', async ({ adminPage, harness }) => {
    await adminPage.goto(`/org/${harness.testOrg.slug}/settings/metadata-fields`);

    await adminPage.click('button:has-text("Create Field")');

    await adminPage.fill('[name="name"]', 'priority');
    await adminPage.fill('[name="displayName"]', 'Priority');
    await adminPage.selectOption('[name="type"]', 'string');
    await adminPage.selectOption('[name="scope"]', 'workflow');
    await adminPage.click('button:has-text("Create")');

    await expect(adminPage.getByText('priority')).toBeVisible();
  });

  test('edit metadata field', async ({ adminPage, harness }) => {
    // Create field first
    await harness.api.createMetadataField({
      name: 'test-field',
      displayName: 'Test Field',
      type: 'string',
      scope: 'workflow',
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/settings/metadata-fields`);

    await adminPage.click('text=test-field');
    await adminPage.click('button:has-text("Edit")');

    await adminPage.fill('[name="displayName"]', 'Updated Field');
    await adminPage.click('button:has-text("Save")');

    await expect(adminPage.getByText('Updated Field')).toBeVisible();
  });

  test('delete metadata field', async ({ adminPage, harness }) => {
    await harness.api.createMetadataField({
      name: 'to-delete',
      displayName: 'To Delete',
      type: 'string',
      scope: 'workflow',
    });

    await adminPage.goto(`/org/${harness.testOrg.slug}/settings/metadata-fields`);

    await adminPage.click('text=to-delete');
    await adminPage.click('button:has-text("Delete")');
    await adminPage.click('button:has-text("Confirm")');

    await expect(adminPage.getByText('to-delete')).not.toBeVisible();
  });
});
```

### 7. Worker Token Management

```typescript
// organization/worker-tokens.spec.ts
test.describe('Worker Tokens', () => {
  test('create worker token', async ({ adminPage, harness }) => {
    await adminPage.goto(`/org/${harness.testOrg.slug}/settings/worker-tokens`);

    await adminPage.click('button:has-text("Create Token")');

    await adminPage.fill('[name="name"]', 'CI Token');
    await adminPage.click('button:has-text("Create")');

    // Token should be displayed (one-time view)
    await expect(adminPage.getByTestId('token-value')).toBeVisible();

    // Copy and close
    await adminPage.click('button:has-text("Done")');

    // Token should appear in list
    await expect(adminPage.getByText('CI Token')).toBeVisible();
  });

  test('revoke worker token', async ({ adminPage, harness }) => {
    // Create token via API
    await harness.api.createWorkerToken({ name: 'To Revoke' });

    await adminPage.goto(`/org/${harness.testOrg.slug}/settings/worker-tokens`);

    const row = adminPage.getByRole('row').filter({ hasText: 'To Revoke' });
    await row.getByRole('button', { name: /revoke/i }).click();

    await adminPage.click('button:has-text("Confirm")');

    await expect(adminPage.getByText('To Revoke')).not.toBeVisible();
  });
});
```

## Test Data Management

### Seeding Strategy

```typescript
interface TestSeeds {
  testOrg: Organization;
  adminUser: User;
  memberUser: User;
  workflows: WorkflowDefinition[];
  executions: WorkflowExecution[];
}

async function seedTestData(harness: TestHarness): Promise<TestSeeds> {
  // Create organization
  const testOrg = await createOrganization('e2e-test-org');

  // Create users with different roles
  const adminUser = await createUser('admin@e2e-test.com', 'AdminPass123!');
  const memberUser = await createUser('member@e2e-test.com', 'MemberPass123!');

  // Add to organization
  await addMemberToOrg(testOrg.id, adminUser.id, 'admin');
  await addMemberToOrg(testOrg.id, memberUser.id, 'member');

  // Create workflow definitions
  const workflows = await createWorkflowDefinitions(testOrg.id, [
    { kind: 'test-workflow', name: 'Test Workflow' },
    { kind: 'long-running-workflow', name: 'Long Running' },
    { kind: 'failing-workflow', name: 'Failing Workflow' },
  ]);

  return { testOrg, adminUser, memberUser, workflows, executions: [] };
}
```

### Test Isolation for Parallel Execution

Tests run in parallel with shared infrastructure. Each test uses unique identifiers to avoid conflicts - following the same pattern as `flovyn-server` integration tests and `sdk-rust` E2E tests.

```typescript
// Simple pattern: use randomUUID() for unique identifiers
import { randomUUID } from 'crypto';

// Examples from tests:
const queryName = `failed-workflows-${randomUUID()}`;
const orgName = `Test Org ${randomUUID()}`;
const email = `user-${randomUUID()}@test.local`;
const fieldName = `field-${randomUUID().slice(0, 8)}`;
```

### Example Test Patterns

```typescript
test('create saved query', async ({ adminPage, harness }) => {
  const queryName = `test-query-${randomUUID()}`;

  await adminPage.goto(`/org/${harness.testOrg.slug}/workflows`);
  await adminPage.fill('[data-testid="fql-input"]', 'status = "FAILED"');
  await adminPage.click('button:has-text("Save Query")');
  await adminPage.fill('[name="name"]', queryName);
  await adminPage.click('button:has-text("Save")');

  await expect(adminPage.getByText(queryName)).toBeVisible();
});

test('invite member', async ({ adminPage, harness }) => {
  const inviteEmail = `invite-${randomUUID()}@test.local`;

  await adminPage.goto(`/org/${harness.testOrg.slug}/members`);
  await adminPage.click('button:has-text("Invite Member")');
  await adminPage.fill('[name="email"]', inviteEmail);
  await adminPage.click('button:has-text("Send")');

  await expect(adminPage.getByText(inviteEmail)).toBeVisible();
});

test('create metadata field', async ({ adminPage, harness }) => {
  const fieldName = `field_${randomUUID().slice(0, 8)}`;

  await adminPage.goto(`/org/${harness.testOrg.slug}/settings/metadata-fields`);
  await adminPage.click('button:has-text("Create Field")');
  await adminPage.fill('[name="name"]', fieldName);
  await adminPage.click('button:has-text("Create")');

  await expect(adminPage.getByText(fieldName)).toBeVisible();
});
```

### Key Principle

As long as each test generates unique identifiers for any resources it creates, tests can run in parallel without conflicts. The shared infrastructure (PostgreSQL, NATS, server, worker) handles concurrent requests fine.

## Environment Configuration

### Environment Variables

```bash
# .env.test
DATABASE_URL_APP="postgres://flovyn-app:flovyn-app@localhost:5433/flovyn-app"
DATABASE_URL_SERVER="postgres://flovyn:flovyn@localhost:5432/flovyn"
NATS_URL="nats://localhost:4222"
FLOVYN_SERVER_URL="http://localhost:8080"
NEXT_PUBLIC_APP_URL="http://localhost:3000"

# Optional: Keep containers for debugging
FLOVYN_E2E_KEEP_CONTAINERS=0

# Optional: Skip container startup (use existing)
FLOVYN_E2E_USE_EXISTING=0
```

### CI Configuration

```yaml
# .github/workflows/e2e.yml
name: E2E Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  e2e:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup pnpm
        uses: pnpm/action-setup@v3
        with:
          version: 10.4.1

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'pnpm'

      - name: Install dependencies
        run: pnpm install

      - name: Install Playwright Browsers
        run: pnpm exec playwright install --with-deps chromium

      - name: Build flovyn-server
        run: |
          cd ../flovyn-server
          cargo build --release

      - name: Run E2E tests
        run: pnpm test:e2e

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report
          path: playwright-report/
```

## Implementation Phases

### Phase 1: Infrastructure Setup
- [ ] Install Playwright and Testcontainers dependencies
- [ ] Create test harness with container orchestration
- [ ] Implement global setup/teardown
- [ ] Configure Playwright with custom fixtures
- [ ] Create cleanup script for orphaned containers

### Phase 2: Authentication Tests
- [ ] Login flow tests
- [ ] Registration flow tests
- [ ] Logout tests
- [ ] Device authorization tests
- [ ] Session persistence tests

### Phase 3: Organization Tests
- [ ] Organization creation
- [ ] Member management
- [ ] Invitation flow
- [ ] Role-based access control

### Phase 4: Workflow Tests
- [ ] Workflow definition listing
- [ ] FQL filtering
- [ ] Saved queries

### Phase 5: Execution Tests
- [ ] Execution listing and filtering
- [ ] Timeline visualization
- [ ] Event history
- [ ] Cancel/retry operations

### Phase 6: Admin Features
- [ ] Worker management
- [ ] Metadata fields
- [ ] Worker tokens

## Dependencies

```json
{
  "devDependencies": {
    "@playwright/test": "^1.48.0",
    "testcontainers": "^10.13.0",
    "@testcontainers/postgresql": "^10.13.0"
  }
}
```

## Open Questions

1. **Database cleanup**: Should we periodically clean up test data, or let it accumulate?

## Decisions Made

1. **Parallel test execution**: Tests run in parallel with shared infrastructure. Isolation is achieved through unique identifiers (UUIDs, timestamps) for all created resources. No test should rely on hardcoded names or shared mutable state.

2. **Test data isolation**: Use unique identifiers (not database reset) for test isolation. Each test creates resources with unique names/IDs, avoiding conflicts even when running in parallel.

3. **Browser coverage**: Focus on Chromium only. Cross-browser testing can be added later if needed.

4. **flovyn-server deployment**: Use Docker images from the registry (`rg.fr-par.scw.cloud/flovyn/flovyn-server:latest`). For local development, build and tag images with the same names.

5. **Sample worker**: Use the `patterns` example from sdk-rust as it provides comprehensive workflow patterns for testing. Build as Docker image (`rg.fr-par.scw.cloud/flovyn/patterns-worker:latest`).

## References

- [Playwright Documentation](https://playwright.dev/docs/intro)
- [Testcontainers Node.js](https://node.testcontainers.org/)
- `flovyn-app/flovyn-server/server/tests/integration/harness.rs` - Server test harness (Rust)
- `flovyn-app/sdk-rust/worker-sdk/tests/e2e/harness.rs` - SDK test harness with Docker images
- `flovyn-app/dev/docker-compose.yml` - Service composition reference
- `../flovyn-server/Dockerfile` - Server Dockerfile
