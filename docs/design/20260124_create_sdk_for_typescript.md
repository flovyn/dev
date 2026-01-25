# TypeScript SDK Design

## Problem Statement

Flovyn needs a TypeScript SDK to enable Node.js developers to build durable workflows and tasks. TypeScript/JavaScript is one of the most popular languages for backend development, and a first-class SDK is essential for Flovyn's adoption.

**Current State:**
- Rust SDK (`sdk-rust/worker-sdk`) - Reference implementation with full features
- Python SDK (`sdk-python`) - Uses UniFFI bindings from `worker-ffi`
- Kotlin SDK (`sdk-kotlin`) - Uses UniFFI bindings from `worker-ffi`

**Challenge:**
UniFFI (used by Python and Kotlin SDKs) does not generate TypeScript/JavaScript bindings. We need an alternative approach to expose the Rust core to Node.js.

## Goals

1. **Idiomatic TypeScript API** - Modern async/await, full type safety, decorator-like patterns
2. **Feature Parity** - Match Rust and Python SDK capabilities
3. **Type Safety** - Full TypeScript generics, inference, and compile-time checking
4. **Developer Experience** - Simple, intuitive API inspired by best-in-class workflow platforms
5. **E2E Tested** - Same test coverage as Python SDK

## Non-Goals

- Browser support (Node.js only due to native module requirement)
- Workflow sandboxing (relies on context-based determinism like Python SDK)
- Deno/Bun support (initial version targets Node.js only)

## Architecture

### Technology Choice: NAPI-RS

[NAPI-RS](https://napi.rs/) is a framework for building pre-compiled Node.js addons in Rust. It provides:
- Safe bindings between Rust and JavaScript via N-API (stable across Node versions)
- **Automatic TypeScript definition generation** from Rust code
- Memory safety guarantees from the Rust compiler
- Cross-platform support (Linux, macOS, Windows) with prebuild tooling
- Built-in async/Promise support with `#[napi]` macro

**Why NAPI-RS over alternatives:**

| Approach | Pros | Cons |
|----------|------|------|
| **NAPI-RS** | Auto-generates `.d.ts`, cleaner macros, pure N-API, active development | Requires native compilation |
| Neon | Mature, Rust-like API | More verbose, no auto TypeScript generation, mixed N-API/V8 |
| Pure TypeScript (HTTP) | No native deps | Performance overhead, no core reuse |
| Pure TypeScript (gRPC) | No native deps | Complex, can't reuse Rust replay logic |
| WebAssembly | Portable | Limited async support, no gRPC from WASM |

**Key NAPI-RS advantages:**
1. **Auto-generated TypeScript definitions** - `#[napi]` macro generates `.d.ts` files automatically
2. **Cleaner API** - Less boilerplate than Neon with attribute macros
3. **Better prebuild tooling** - `@napi-rs/cli` handles cross-compilation and npm publishing
4. **Pure N-API** - Stable across Node.js versions (no V8 dependency)
5. **Community consensus** - Preferred choice for new Rust/Node.js projects

NAPI-RS allows us to reuse `worker-core` for all the complex logic (replay, determinism validation, gRPC communication) while providing a thin TypeScript wrapper with auto-generated types.

### Layer Architecture

```
                     ┌─────────────────────────────────────────────────────┐
                     │                  User Code (TypeScript)              │
                     │   workflow(), task() definitions, async/await        │
                     ├─────────────────────────────────────────────────────┤
                     │                @flovyn/sdk (TypeScript)              │
                     │   WorkflowContext, TaskContext, FlovynClient         │
                     ├─────────────────────────────────────────────────────┤
                     │              @flovyn/native (NAPI-RS)                │
                     │   Auto-generated TS bindings, native library loader  │
                     ├─────────────────────────────────────────────────────┤
                     │            worker-napi (Rust + NAPI-RS)              │
                     │   NapiWorker, NapiClient, NapiWorkflowContext        │
                     ├─────────────────────────────────────────────────────┤
                     │            flovyn-worker-core (Rust)                 │
                     │   gRPC clients, replay engine, determinism           │
                     └─────────────────────────────────────────────────────┘
```

### Component Responsibilities

**worker-napi (Rust crate in sdk-rust):**
- NAPI-RS bindings using `#[napi]` macros
- Exposes `NapiWorker`, `NapiClient`, `NapiWorkflowContext`, `NapiTaskContext`
- Auto-generates TypeScript definitions (`.d.ts`) from Rust types
- Delegates to `worker-core` for all business logic
- Handles Tokio runtime management for async operations

**@flovyn/native (npm package):**
- Pre-built native binaries for all platforms (via `@napi-rs/cli`)
- Auto-generated TypeScript definitions from worker-napi
- Platform-specific binary loading (handled by NAPI-RS runtime)

**@flovyn/sdk (npm package):**
- High-level TypeScript API
- `workflow()` and `task()` definition functions
- `WorkflowContext` and `TaskContext` implementations
- `FlovynClient` for worker management and workflow dispatch
- Serialization layer (JSON by default)

### Package Structure

```
sdk-typescript/
├── packages/
│   ├── native/                      # @flovyn/native
│   │   ├── src/
│   │   │   ├── index.ts             # Re-exports and types
│   │   │   ├── loader.ts            # Native library loader
│   │   │   └── types.ts             # Low-level FFI types
│   │   ├── native/                  # Pre-built binaries (gitignored)
│   │   │   ├── linux-x64-gnu/
│   │   │   ├── linux-arm64-gnu/
│   │   │   ├── darwin-x64/
│   │   │   ├── darwin-arm64/
│   │   │   └── win32-x64-msvc/
│   │   └── package.json
│   │
│   └── sdk/                         # @flovyn/sdk
│       ├── src/
│       │   ├── index.ts             # Public API exports
│       │   ├── workflow.ts          # workflow() and WorkflowContext
│       │   ├── task.ts              # task() and TaskContext
│       │   ├── client.ts            # FlovynClient and builder
│       │   ├── worker.ts            # Internal worker implementation
│       │   ├── types.ts             # Public type definitions
│       │   ├── errors.ts            # Exception classes
│       │   ├── duration.ts          # Duration utilities
│       │   └── testing/             # Test utilities (optional)
│       │       ├── mock-context.ts
│       │       └── test-environment.ts
│       ├── package.json
│       └── tsconfig.json
│
├── examples/
│   ├── hello-world/
│   ├── order-processing/
│   └── data-pipeline/
│
├── tests/
│   ├── unit/
│   └── e2e/
│
├── package.json                     # Workspace root
├── pnpm-workspace.yaml
└── tsconfig.base.json
```

## API Design

### Design Principles

1. **Function-Based Definitions** - Use factory functions (`workflow()`, `task()`) rather than classes
2. **Generic Type Parameters** - Full type inference for inputs and outputs
3. **Context-First** - All non-deterministic operations through context
4. **Async/Await Native** - Leverage JavaScript's native async patterns
5. **Serialization Agnostic** - JSON by default, pluggable for other formats

### Industry Comparison

| Aspect | Temporal | Restate | Hatchet | Trigger.dev | Flovyn |
|--------|----------|---------|---------|-------------|--------|
| Definition Style | Functions | Object + handlers | Factory pattern | task() function | Factory + handlers |
| Type Safety | Good | Good | Excellent (V1) | Good | Excellent |
| Context Access | Imports | Handler param | Handler param | Handler param | Handler param |
| Task Invocation | proxyActivities | serviceClient | task reference | trigger() | ctx.task() |
| Side Effects | Activities only | ctx.run() | N/A | N/A | ctx.run() |

### Best Patterns Adopted

**From Restate:**
- `ctx.run()` for durable side effects with automatic caching
- Handler-based signal/query definitions
- Clean context API

**From Hatchet V1:**
- Factory pattern with generics (`workflow<Input, Output>()`)
- Full type inference from generic parameters
- Wrapper methods on workflow objects (`workflow.run()`, `workflow.schedule()`)

**From Temporal:**
- Separate workflow and task (activity) concepts
- Worker-based execution model
- `sleep()` for durable timers

**From Trigger.dev:**
- Simple `task()` definition pattern
- Lifecycle hooks (`onSuccess`, `onFailure`)
- Clean retry configuration

### Workflow Definition

```typescript
import { workflow, WorkflowContext, Duration } from '@flovyn/sdk';

// Input/output types (plain objects, validated at runtime)
interface OrderInput {
  orderId: string;
  items: string[];
  total: number;
}

interface OrderResult {
  confirmationId: string;
  status: 'completed' | 'cancelled';
}

// Workflow definition with full type inference
export const orderWorkflow = workflow<OrderInput, OrderResult>({
  name: 'order-processing',
  description: 'Process an order through validation, payment, and fulfillment',
  version: '1.0.0',
  timeout: Duration.hours(24),

  // Main workflow logic
  async run(ctx: WorkflowContext, input: OrderInput): Promise<OrderResult> {
    // Execute task (type-safe via task reference)
    const validation = await ctx.task(validateOrderTask, input);

    if (!validation.valid) {
      throw new Error(`Validation failed: ${validation.errors.join(', ')}`);
    }

    // Durable side effect (cached on replay)
    const exchangeRate = await ctx.run('fetch-exchange-rate', async () => {
      return await fetchExchangeRate(input.currency);
    });

    // Execute payment task
    const payment = await ctx.task(processPaymentTask, {
      orderId: input.orderId,
      amount: input.total * exchangeRate,
    });

    // Durable timer
    await ctx.sleep(Duration.seconds(5));

    // Wait for external event
    const approval = await ctx.promise<ApprovalResult>('manager-approval', {
      timeout: Duration.hours(24),
    });

    if (!approval.approved) {
      // Compensating action
      await ctx.task(refundPaymentTask, { transactionId: payment.transactionId });
      return { confirmationId: payment.transactionId, status: 'cancelled' };
    }

    return {
      confirmationId: payment.transactionId,
      status: 'completed',
    };
  },

  // Signal/query handlers
  handlers: {
    // Query handler - read-only access to workflow state
    getStatus: async (ctx: WorkflowContext): Promise<string> => {
      return await ctx.getState<string>('status') ?? 'unknown';
    },

    // Signal handler - can modify workflow state
    cancelOrder: async (ctx: WorkflowContext, reason: string): Promise<void> => {
      await ctx.setState('cancellation_reason', reason);
      ctx.requestCancellation();
    },
  },
});
```

### Task Definition

```typescript
import { task, TaskContext } from '@flovyn/sdk';

interface PaymentInput {
  orderId: string;
  amount: number;
}

interface PaymentResult {
  transactionId: string;
  status: string;
}

export const processPaymentTask = task<PaymentInput, PaymentResult>({
  name: 'process-payment',
  description: 'Process payment via payment gateway',
  timeout: Duration.minutes(5),

  retry: {
    maxAttempts: 3,
    initialInterval: Duration.seconds(1),
    maxInterval: Duration.minutes(1),
    backoffCoefficient: 2.0,
  },

  async run(ctx: TaskContext, input: PaymentInput): Promise<PaymentResult> {
    // Report progress
    await ctx.reportProgress(0.1, 'Connecting to payment gateway');

    // Check for cancellation
    if (ctx.isCancelled) {
      throw ctx.cancellationError();
    }

    // Actual payment processing
    const result = await paymentGateway.charge(input);

    await ctx.reportProgress(1.0, 'Payment completed');

    return {
      transactionId: result.id,
      status: result.status,
    };
  },

  // Lifecycle hooks
  onSuccess: async (ctx, input, output) => {
    console.log(`Payment ${output.transactionId} succeeded for order ${input.orderId}`);
  },

  onFailure: async (ctx, input, error) => {
    console.error(`Payment failed for order ${input.orderId}: ${error.message}`);
  },
});
```

### WorkflowContext API

```typescript
interface WorkflowContext {
  // Identifiers
  readonly workflowExecutionId: string;
  readonly workflowKind: string;
  readonly orgId: string;

  // Deterministic time and randomness
  currentTime(): Date;
  currentTimeMillis(): number;
  randomUUID(): string;
  random(): number;

  // Task execution
  task<I, O>(task: TaskDefinition<I, O>, input: I, options?: TaskOptions): Promise<O>;
  scheduleTask<I, O>(task: TaskDefinition<I, O>, input: I, options?: TaskOptions): TaskHandle<O>;

  // Child workflows
  workflow<I, O>(workflow: WorkflowDefinition<I, O>, input: I, options?: ChildWorkflowOptions): Promise<O>;
  scheduleWorkflow<I, O>(workflow: WorkflowDefinition<I, O>, input: I, options?: ChildWorkflowOptions): WorkflowHandle<O>;

  // Durable timers
  sleep(duration: Duration): Promise<void>;
  sleepUntil(until: Date): Promise<void>;

  // External promises
  promise<T>(name: string, options?: PromiseOptions): Promise<T>;

  // Durable side effects (cached on replay)
  run<T>(name: string, fn: () => T | Promise<T>): Promise<T>;

  // Workflow state
  getState<T>(key: string): Promise<T | null>;
  setState<T>(key: string, value: T): Promise<void>;
  clearState(key: string): Promise<void>;

  // Cancellation
  readonly isCancellationRequested: boolean;
  checkCancellation(): void;
  requestCancellation(): void;

  // Logging
  readonly log: Logger;
}
```

### TaskContext API

```typescript
interface TaskContext {
  // Identifiers
  readonly taskExecutionId: string;
  readonly taskKind: string;
  readonly attempt: number;

  // Progress and heartbeat
  reportProgress(progress: number, message?: string): Promise<void>;
  heartbeat(): Promise<void>;

  // Cancellation
  readonly isCancelled: boolean;
  cancellationError(): TaskCancelled;
  checkCancellation(): void;

  // Streaming (for LLM tokens, etc.)
  streamToken(text: string): Promise<void>;
  streamProgress(progress: number, details?: string): Promise<void>;
  streamData<T>(data: T): Promise<void>;
  streamError(message: string, code?: string): Promise<void>;

  // Logging
  readonly log: Logger;
}
```

### FlovynClient API

```typescript
import { FlovynClient } from '@flovyn/sdk';

// Builder pattern for configuration
const client = new FlovynClient({
  serverAddress: 'localhost:9090',
  orgId: 'my-org-id',
  queue: 'default',

  // Authentication (one of)
  workerToken: 'fwt_...',
  // OR
  oauth2: {
    clientId: '...',
    clientSecret: '...',
    tokenEndpoint: '...',
  },

  // Concurrency limits
  maxConcurrentWorkflows: 100,
  maxConcurrentTasks: 100,
});

// Register workflows and tasks
client.registerWorkflow(orderWorkflow);
client.registerTask(validateOrderTask);
client.registerTask(processPaymentTask);
client.registerTask(refundPaymentTask);

// Add lifecycle hooks
client.addHook({
  onWorkflowStarted: async (event) => {
    metrics.increment('workflow.started', { kind: event.workflowKind });
  },
  onWorkflowCompleted: async (event) => {
    metrics.timing('workflow.duration', event.durationMs);
  },
});

// Start the worker
await client.start();

// Start a workflow
const handle = await client.startWorkflow(orderWorkflow, {
  orderId: 'order-123',
  items: ['item1', 'item2'],
  total: 99.99,
}, {
  workflowId: 'order-123', // Optional custom ID
});

// Wait for result
const result = await handle.result();

// Query workflow
const status = await handle.query('getStatus');

// Signal workflow
await handle.signal('cancelOrder', 'Customer requested');

// Resolve external promise
await client.resolvePromise({
  workflowId: 'order-123',
  promiseName: 'manager-approval',
  value: { approved: true },
});

// Graceful shutdown
await client.stop();
```

### Async Context Manager Pattern

```typescript
// Alternative: use with `using` (TypeScript 5.2+)
await using client = new FlovynClient({ ... });
client.registerWorkflow(orderWorkflow);
await client.start();

// Worker runs until scope exits
await new Promise(resolve => setTimeout(resolve, 3600000));
// Automatic graceful shutdown on scope exit
```

### Error Types

```typescript
// Base error
export class FlovynError extends Error {
  constructor(message: string, public readonly cause?: Error) {
    super(message);
    this.name = 'FlovynError';
  }
}

// Workflow errors
export class WorkflowSuspended extends FlovynError {} // Internal: workflow needs to pause
export class WorkflowCancelled extends FlovynError {} // Workflow was cancelled
export class DeterminismViolation extends FlovynError {} // Replay mismatch

// Task errors
export class TaskFailed extends FlovynError {
  constructor(message: string, public readonly retryable: boolean = true) {
    super(message);
  }
}
export class TaskCancelled extends FlovynError {}
export class TaskTimeout extends FlovynError {}

// Promise errors
export class PromiseTimeout extends FlovynError {}
export class PromiseRejected extends FlovynError {}

// Child workflow errors
export class ChildWorkflowFailed extends FlovynError {}
```

### Duration Utilities

```typescript
// Fluent duration API (inspired by Temporal)
export class Duration {
  private constructor(private readonly ms: number) {}

  static milliseconds(ms: number): Duration { return new Duration(ms); }
  static seconds(s: number): Duration { return new Duration(s * 1000); }
  static minutes(m: number): Duration { return new Duration(m * 60 * 1000); }
  static hours(h: number): Duration { return new Duration(h * 60 * 60 * 1000); }
  static days(d: number): Duration { return new Duration(d * 24 * 60 * 60 * 1000); }

  toMilliseconds(): number { return this.ms; }
  toSeconds(): number { return this.ms / 1000; }
}
```

## Worker-NAPI (Rust Crate)

### Crate Structure

```
sdk-rust/
└── worker-napi/                     # New NAPI-RS-based FFI crate
    ├── Cargo.toml
    ├── src/
    │   ├── lib.rs                   # NAPI-RS module entry point
    │   ├── worker.rs                # NapiWorker implementation
    │   ├── client.rs                # NapiClient implementation
    │   ├── context.rs               # NapiWorkflowContext, NapiTaskContext
    │   ├── activation.rs            # Activation types
    │   ├── config.rs                # Configuration types
    │   └── error.rs                 # Error conversions
    ├── build.rs                     # NAPI-RS build configuration
    ├── npm/                         # Platform-specific npm packages
    │   ├── linux-x64-gnu/
    │   ├── linux-arm64-gnu/
    │   ├── darwin-x64/
    │   ├── darwin-arm64/
    │   └── win32-x64-msvc/
    └── package.json                 # Root npm package (@flovyn/native)
```

### NAPI-RS API Design

NAPI-RS uses `#[napi]` attribute macros for clean, declarative bindings with auto-generated TypeScript definitions:

```rust
// lib.rs
#![deny(clippy::all)]

use napi_derive::napi;

mod activation;
mod client;
mod config;
mod context;
mod error;
mod worker;

pub use activation::*;
pub use client::*;
pub use config::*;
pub use context::*;
pub use error::*;
pub use worker::*;
```

```rust
// worker.rs
use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::sync::Arc;
use tokio::runtime::Runtime;

use crate::activation::{TaskActivation, WorkflowActivation, WorkflowCompletionStatus};
use crate::config::WorkerConfig;
use crate::context::NapiWorkflowContext;

/// The main worker object for polling and processing workflow/task activations.
#[napi]
pub struct NapiWorker {
    inner: Arc<CoreWorkerInner>,
    runtime: Arc<Runtime>,
}

#[napi]
impl NapiWorker {
    /// Create a new worker with the given configuration.
    #[napi(constructor)]
    pub fn new(config: WorkerConfig) -> Result<Self> {
        let runtime = Arc::new(Runtime::new().map_err(|e| {
            Error::from_reason(format!("Failed to create runtime: {}", e))
        })?);

        let inner = CoreWorkerInner::new(&config, runtime.clone())
            .map_err(|e| Error::from_reason(e.to_string()))?;

        Ok(Self {
            inner: Arc::new(inner),
            runtime,
        })
    }

    /// Register the worker with the Flovyn server.
    #[napi]
    pub async fn register(&self) -> Result<String> {
        self.inner
            .register()
            .await
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Poll for the next workflow activation.
    #[napi]
    pub async fn poll_workflow_activation(&self) -> Result<Option<WorkflowActivation>> {
        self.inner
            .poll_workflow_activation()
            .await
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Complete a workflow activation.
    #[napi]
    pub async fn complete_workflow_activation(
        &self,
        context: &NapiWorkflowContext,
        status: WorkflowCompletionStatus,
    ) -> Result<()> {
        self.inner
            .complete_workflow_activation(context, status)
            .await
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Poll for the next task activation.
    #[napi]
    pub async fn poll_task_activation(&self) -> Result<Option<TaskActivation>> {
        self.inner
            .poll_task_activation()
            .await
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Initiate graceful shutdown.
    #[napi]
    pub fn shutdown(&self) {
        self.inner.shutdown();
    }

    /// Check if shutdown has been requested.
    #[napi(getter)]
    pub fn is_shutdown_requested(&self) -> bool {
        self.inner.is_shutdown_requested()
    }

    /// Get the current worker status.
    #[napi(getter)]
    pub fn status(&self) -> String {
        self.inner.status()
    }
}
```

### Context API with NAPI-RS

```rust
// context.rs
use napi::bindgen_prelude::*;
use napi_derive::napi;

/// Result of scheduling a task.
#[napi(object)]
pub struct TaskResult {
    /// "completed", "failed", or "pending"
    pub status: String,
    /// Output bytes (if completed)
    pub output: Option<Buffer>,
    /// Error message (if failed)
    pub error: Option<String>,
    /// Whether error is retryable
    pub retryable: Option<bool>,
    /// Task execution ID (if pending)
    pub task_execution_id: Option<String>,
}

/// Replay-aware workflow context.
#[napi]
pub struct NapiWorkflowContext {
    inner: Arc<FfiWorkflowContext>,
}

#[napi]
impl NapiWorkflowContext {
    /// Get the workflow execution ID.
    #[napi(getter)]
    pub fn workflow_execution_id(&self) -> String {
        self.inner.workflow_execution_id()
    }

    /// Schedule a task for execution.
    #[napi]
    pub fn schedule_task(
        &self,
        kind: String,
        input: Buffer,
        queue: Option<String>,
        timeout_ms: Option<i64>,
    ) -> Result<TaskResult> {
        self.inner
            .schedule_task(kind, input.to_vec(), queue, timeout_ms)
            .map(|r| r.into())
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Create a durable promise.
    #[napi]
    pub fn create_promise(
        &self,
        name: String,
        timeout_ms: Option<i64>,
    ) -> Result<PromiseResult> {
        self.inner
            .create_promise(name, timeout_ms)
            .map(|r| r.into())
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Start a timer.
    #[napi]
    pub fn start_timer(&self, duration_ms: i64) -> Result<TimerResult> {
        self.inner
            .start_timer(duration_ms)
            .map(|r| r.into())
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Get current time (deterministic).
    #[napi]
    pub fn current_time_millis(&self) -> i64 {
        self.inner.current_time_millis()
    }

    /// Generate a deterministic UUID.
    #[napi]
    pub fn random_uuid(&self) -> String {
        self.inner.random_uuid()
    }

    /// Generate a deterministic random number in [0, 1).
    #[napi]
    pub fn random(&self) -> f64 {
        self.inner.random()
    }

    /// Get workflow state.
    #[napi]
    pub fn get_state(&self, key: String) -> Option<Buffer> {
        self.inner.get_state(key).map(Buffer::from)
    }

    /// Set workflow state.
    #[napi]
    pub fn set_state(&self, key: String, value: Buffer) -> Result<()> {
        self.inner
            .set_state(key, value.to_vec())
            .map_err(|e| Error::from_reason(e.to_string()))
    }

    /// Check if cancellation has been requested.
    #[napi(getter)]
    pub fn is_cancellation_requested(&self) -> bool {
        self.inner.is_cancellation_requested()
    }
}
```

### Auto-Generated TypeScript Definitions

NAPI-RS automatically generates TypeScript definitions from the Rust code above:

```typescript
// Generated: index.d.ts
export interface WorkerConfig {
  serverUrl: string;
  orgId: string;
  queue: string;
  workerToken?: string;
  oauth2Credentials?: OAuth2Credentials;
  maxConcurrentWorkflowTasks?: number;
  maxConcurrentTasks?: number;
}

export interface TaskResult {
  status: string;
  output?: Buffer;
  error?: string;
  retryable?: boolean;
  taskExecutionId?: string;
}

export class NapiWorker {
  constructor(config: WorkerConfig);
  register(): Promise<string>;
  pollWorkflowActivation(): Promise<WorkflowActivation | null>;
  completeWorkflowActivation(context: NapiWorkflowContext, status: WorkflowCompletionStatus): Promise<void>;
  pollTaskActivation(): Promise<TaskActivation | null>;
  shutdown(): void;
  get isShutdownRequested(): boolean;
  get status(): string;
}

export class NapiWorkflowContext {
  get workflowExecutionId(): string;
  scheduleTask(kind: string, input: Buffer, queue?: string, timeoutMs?: number): TaskResult;
  createPromise(name: string, timeoutMs?: number): PromiseResult;
  startTimer(durationMs: number): TimerResult;
  currentTimeMillis(): number;
  randomUuid(): string;
  random(): number;
  getState(key: string): Buffer | null;
  setState(key: string, value: Buffer): void;
  get isCancellationRequested(): boolean;
}
```

### Cross-Platform Build with @napi-rs/cli

```bash
# Install CLI
npm install -g @napi-rs/cli

# Build for current platform
napi build --release

# Build for all platforms (CI)
napi build --release --platform linux-x64-gnu
napi build --release --platform linux-arm64-gnu
napi build --release --platform darwin-x64
napi build --release --platform darwin-arm64
napi build --release --platform win32-x64-msvc

# Publish to npm
napi prepublish
npm publish
```

## Testing Strategy

### Unit Tests

```typescript
// tests/unit/workflow.test.ts
import { describe, it, expect } from 'vitest';
import { MockWorkflowContext } from '@flovyn/sdk/testing';
import { orderWorkflow } from '../fixtures/workflows';

describe('orderWorkflow', () => {
  it('should complete order successfully', async () => {
    const ctx = new MockWorkflowContext();

    // Mock task results
    ctx.mockTaskResult(validateOrderTask, { valid: true, errors: [] });
    ctx.mockTaskResult(processPaymentTask, { transactionId: 'txn-123', status: 'success' });

    // Mock promise resolution
    ctx.mockPromiseResolution('manager-approval', { approved: true });

    const result = await orderWorkflow.run(ctx, {
      orderId: 'order-123',
      items: ['item1'],
      total: 99.99,
    });

    expect(result.status).toBe('completed');
    expect(result.confirmationId).toBe('txn-123');
    expect(ctx.executedTasks).toHaveLength(2);
  });

  it('should handle cancellation', async () => {
    const ctx = new MockWorkflowContext();

    ctx.mockTaskResult(validateOrderTask, { valid: true, errors: [] });
    ctx.mockPromiseResolution('manager-approval', { approved: false });
    ctx.mockTaskResult(refundPaymentTask, { success: true });

    const result = await orderWorkflow.run(ctx, { ... });

    expect(result.status).toBe('cancelled');
  });
});
```

### E2E Tests

```typescript
// tests/e2e/workflow.test.ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { FlovynTestEnvironment } from '@flovyn/sdk/testing';
import { orderWorkflow, validateOrderTask, processPaymentTask } from '../fixtures';

describe('Order Workflow E2E', () => {
  let env: FlovynTestEnvironment;

  beforeAll(async () => {
    env = await FlovynTestEnvironment.start();
    env.registerWorkflow(orderWorkflow);
    env.registerTask(validateOrderTask);
    env.registerTask(processPaymentTask);
    await env.ready();
  });

  afterAll(async () => {
    await env.stop();
  });

  it('should process order end-to-end', async () => {
    const handle = await env.startWorkflow(orderWorkflow, {
      orderId: 'test-order',
      items: ['item1'],
      total: 50.00,
    });

    // Resolve external promise
    await env.resolvePromise(handle.workflowId, 'manager-approval', { approved: true });

    const result = await handle.result({ timeout: Duration.seconds(30) });

    expect(result.status).toBe('completed');
  });
});
```

## Platform Support

| Platform | Architecture | Status |
|----------|--------------|--------|
| Linux    | x64 (glibc)  | Target |
| Linux    | arm64 (glibc)| Target |
| macOS    | x64          | Target |
| macOS    | arm64        | Target |
| Windows  | x64          | Target |
| Windows  | arm64        | Stretch |

Node.js versions: 18, 20, 22, 24 (matching Temporal's support policy)

## Dependencies

**@flovyn/native:**
- Node.js >= 18
- Platform-specific native binary (auto-loaded by NAPI-RS)

**@flovyn/sdk:**
- Node.js >= 18
- @flovyn/native

**worker-napi (Rust):**
- napi = "2"
- napi-derive = "2"
- flovyn-worker-core (workspace dependency)
- tokio = { version = "1", features = ["rt-multi-thread"] }
- serde_json = "1.0"

**Development:**
- @napi-rs/cli (build tooling)
- TypeScript >= 5.0
- vitest (testing)
- testcontainers (E2E)
- eslint + prettier (linting)

## Open Questions

1. **Package naming:** `@flovyn/sdk` vs `flovyn` vs `@flovyn/worker`?
   - Recommendation: `@flovyn/sdk` for consistency with Python's `flovyn` package

2. **Monorepo structure:** Should `sdk-typescript` be a separate repo or part of the main Flovyn workspace?
   - Recommendation: Separate repo like `sdk-python`, but `worker-napi` stays in `sdk-rust`

3. **Serialization:** JSON only, or support for msgpack/protobuf?
   - Recommendation: JSON only initially, pluggable interface for future expansion

4. **Zod/validation integration:** Should we integrate with Zod for runtime validation?
   - Recommendation: Optional, document pattern but don't require dependency

5. **ESM vs CommonJS:** ESM-only or dual support?
   - Recommendation: ESM-only (modern Node.js), with tsconfig paths for type resolution

## Summary

The TypeScript SDK will provide a modern, type-safe API for building durable workflows in Node.js. Key differentiators:

1. **Full Type Inference** - Generic parameters on `workflow<I, O>()` and `task<I, O>()` provide compile-time safety
2. **NAPI-RS FFI** - Reuses battle-tested `worker-core` logic with auto-generated TypeScript definitions
3. **Modern Patterns** - Async/await, factory functions, fluent Duration API
4. **Best-of-Breed API** - Combines best patterns from Temporal, Restate, Hatchet, and Trigger.dev

### Public API Surface

```typescript
// Core definitions
import { workflow, task, WorkflowContext, TaskContext } from '@flovyn/sdk';

// Client and handles
import { FlovynClient, WorkflowHandle, TaskHandle } from '@flovyn/sdk';

// Configuration
import { Duration, RetryPolicy, WorkflowHook } from '@flovyn/sdk';

// Errors
import {
  FlovynError,
  WorkflowCancelled,
  DeterminismViolation,
  TaskFailed,
  TaskCancelled,
  PromiseTimeout,
  PromiseRejected,
} from '@flovyn/sdk';

// Testing utilities
import {
  MockWorkflowContext,
  MockTaskContext,
  FlovynTestEnvironment,
} from '@flovyn/sdk/testing';
```

## References

- [Python SDK Design](./20260119_design_sdk_python.md) - Architecture and UniFFI patterns
- [NAPI-RS Documentation](https://napi.rs/) - Node.js native module framework
- [NAPI-RS Examples](https://github.com/napi-rs/napi-rs/tree/main/examples) - Reference implementations
- [Temporal TypeScript SDK](https://docs.temporal.io/develop/typescript) - Industry reference
- [Restate TypeScript SDK](https://docs.restate.dev/develop/ts/overview/) - Context patterns
- [Hatchet TypeScript SDK](https://docs.hatchet.run/home/v1-sdk-improvements) - Factory patterns
- [Trigger.dev](https://trigger.dev/docs/llms-full.txt) - Simple task definitions
