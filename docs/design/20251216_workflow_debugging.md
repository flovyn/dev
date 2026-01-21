# Workflow Observability with OpenTelemetry

## Problem Statement

When debugging workflow issues in production:
1. Hard to understand what operations executed and in what order
2. No visibility into SDK-side behavior (what did the client do?)
3. No correlation between server events and client events
4. Must grep logs manually to reconstruct timeline

## Solution: End-to-End OpenTelemetry Tracing

Implement distributed tracing across both **server** and **SDK**. Each workflow becomes a single trace that shows:
- Server: workflow start, task scheduling, timer firing, child workflow completion
- SDK: workflow execution, task execution, retry attempts, errors

Reference: `.dev/docs/research/otel-tracing.md`

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SDK (Client)                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ workflow.run │  │ task.execute │  │ workflow.    │          │
│  │              │  │              │  │ schedule_task│          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│         │                 │                 │                   │
│         └────────────┬────┴─────────────────┘                   │
│                      │ traceparent in gRPC metadata              │
└──────────────────────┼──────────────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Server                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ workflow.    │  │ task.        │  │ timer.       │          │
│  │ start        │  │ complete     │  │ fired        │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│         │                 │                 │                   │
│         └────────────┬────┴─────────────────┘                   │
│                      │                                          │
└──────────────────────┼──────────────────────────────────────────┘
                       ▼
              ┌────────────────┐
              │ Jaeger / Tempo │
              │   (Trace UI)   │
              └────────────────┘
```

## Trace Structure

```
Trace: workflow-{workflow_id}
│
├── [SDK] workflow.execute                    # SDK executes workflow logic
│   ├── tenant.id = "acme-corp"
│   ├── workflow.id = "abc-123"
│   ├── workflow.kind = "OrderProcessor"
│   │
│   ├── [SDK] workflow.schedule_task          # SDK schedules task
│   │   └── task.type = "send-email"
│   │
│   └── [Server] workflow.task.scheduled      # Server records task
│       └── task.id = "task-456"
│
├── [SDK] task.execute                        # SDK executes task
│   ├── task.id = "task-456"
│   ├── task.type = "send-email"
│   └── task.duration_ms = 150
│
├── [Server] task.completed                   # Server records completion
│   └── task.output = "{...}"
│
├── [SDK] workflow.execute                    # SDK continues workflow
│   └── (continues after task result)
│
└── [Server] workflow.completed
    └── workflow.output = "{...}"
```

## Design

### Trace Context Flow

1. **Workflow Start**: Server creates root span, stores `traceparent` in DB
2. **Poll Workflow**: Server returns `traceparent` to SDK in response
3. **SDK Execution**: SDK creates child spans under the workflow trace
4. **SDK → Server Calls**: SDK passes `traceparent` in gRPC metadata
5. **Server Operations**: Server restores context, creates child spans

### Database Schema

```sql
ALTER TABLE workflow_execution ADD COLUMN traceparent VARCHAR(55);
ALTER TABLE task_execution ADD COLUMN traceparent VARCHAR(55);
```

### Instrumentation Points

#### Server

All server spans include `tenant.id` as a standard attribute for multi-tenant filtering.

| Operation | Span Name | Attributes |
|-----------|-----------|------------|
| Workflow started | `workflow.start` | tenant.id, workflow.id, workflow.kind, task_queue |
| Workflow polled | `workflow.poll` | tenant.id, workflow.id, worker.id |
| Task scheduled | `workflow.task.scheduled` | tenant.id, workflow.id, task.id, task.type |
| Task completed | `workflow.task.completed` | tenant.id, workflow.id, task.id, duration_ms, pending_duration_ms, running_duration_ms |
| Timer scheduled | `workflow.timer.scheduled` | tenant.id, workflow.id, timer.id, fire_at |
| Timer fired | `workflow.timer.fired` | tenant.id, workflow.id, timer.id, duration_ms |
| Child started | `workflow.child.started` | tenant.id, workflow.id, child.id, child.kind |
| Child completed | `workflow.child.completed` | tenant.id, workflow.id, child.id, child.output |
| Promise created | `workflow.promise.created` | tenant.id, workflow.id, promise.id |
| Promise resolved | `workflow.promise.resolved` | tenant.id, workflow.id, promise.id |
| Workflow completed | `workflow.completed` | tenant.id, workflow.id, output, total_duration_ms, execution_duration_ms, execution_count, pending_duration_ms |
| Workflow failed | `workflow.failed` | tenant.id, workflow.id, error, total_duration_ms, execution_duration_ms, execution_count, pending_duration_ms |

#### SDK

All SDK spans include `tenant.id` as a standard attribute for multi-tenant filtering.

| Operation | Span Name | Attributes |
|-----------|-----------|------------|
| Workflow execution | `workflow.execute` | tenant.id, workflow.id, workflow.kind |
| Task scheduling | `workflow.schedule_task` | tenant.id, workflow.id, task.type |
| Task execution | `task.execute` | tenant.id, workflow.id, task.id, task.type |
| Task retry | `task.retry` | tenant.id, workflow.id, task.id, attempt, max_attempts |
| Child workflow | `workflow.schedule_child` | tenant.id, workflow.id, child.kind |
| Timer sleep | `workflow.sleep` | tenant.id, workflow.id, duration_ms |
| Promise await | `workflow.await_promise` | tenant.id, workflow.id, promise.id |

### Trace Propagation

#### Server → SDK (in PollWorkflow response)

```protobuf
message PollWorkflowResponse {
  // ... existing fields
  string traceparent = 10;  // W3C trace context
}
```

#### SDK → Server (in gRPC metadata)

```rust
// SDK adds traceparent to every gRPC call
let mut request = tonic::Request::new(req);
request.metadata_mut().insert(
    "traceparent",
    traceparent.parse().unwrap()
);
```

### Configuration

#### Server

```bash
# Enable OpenTelemetry
OTEL_ENABLED=true

# Export destination
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4317

# Service name (appears in traces)
OTEL_SERVICE_NAME=flovyn-server
```

#### SDK

```rust
let client = FlovynClient::builder()
    .enable_tracing(true)
    .otel_endpoint("http://tempo:4317")
    .service_name("my-worker")
    .build()
    .await?;
```

## Production Usage

### Finding Traces

**By tenant** (isolate tenant issues):
```
Search: tenant.id = "acme-corp"
```

**By workflow ID** (most common):
```
Search: workflow.id = "abc-123"
```

**By workflow kind**:
```
Search: workflow.kind = "OrderProcessor" AND status = "error"
```

**By tenant + workflow kind** (tenant-specific debugging):
```
Search: tenant.id = "acme-corp" AND workflow.kind = "OrderProcessor" AND status = "error"
```

**By time range**:
```
Search: service.name = "flovyn-server" AND last 1 hour
```

**By duration** (slow workflows):
```
Search: workflow.completed AND total_duration_ms > 60000
```

**By suspend time** (mostly waiting):
```
Search: total_duration_ms > 60000 AND execution_duration_ms < 1000
```

**By execution time** (expensive logic):
```
Search: execution_duration_ms > 5000
```

### Debugging Scenarios

| Scenario | What to look for in trace |
|----------|--------------------------|
| Workflow never completes | Missing `workflow.completed` span; look for last span |
| Task fails repeatedly | Multiple `task.retry` spans; check error attributes |
| Slow workflow (wall-clock) | High `total_duration_ms`; check timer/task spans for what caused wait |
| Slow workflow (execution) | High `execution_duration_ms`; workflow logic is expensive |
| Long suspend time | High `total_duration_ms` but low `execution_duration_ms`; look at span gaps |
| Excessive polling | High `execution_count`; may indicate retry issues or non-determinism |
| SDK bug | Check SDK spans before/after server spans |
| Timer not firing | `workflow.timer.scheduled` without `workflow.timer.fired` |
| Child workflow hang | `workflow.child.started` without `workflow.child.completed` |
| Tenant-wide issues | Filter by `tenant.id`; look for patterns across workflows |
| Cross-tenant comparison | Compare error rates between tenants using `tenant.id` filter |

### Example: Investigating SDK Bug

1. User reports workflow stuck
2. Get workflow_id from user
3. Search Jaeger: `workflow.id = "<id>"`
4. See trace:
   ```
   [Server] workflow.start          ✓  tenant.id="acme-corp"
   [Server] workflow.poll           ✓
   [SDK] workflow.execute           ✓
   [SDK] workflow.schedule_task     ✓
   [Server] task.scheduled          ✓
   [SDK] task.execute               ✗ ERROR: "connection refused"
   ```
5. Root cause: SDK task execution failed, didn't retry

### Example: Investigating Tenant-Wide Issues

1. Tenant reports multiple workflows failing
2. Search Jaeger: `tenant.id = "acme-corp" AND status = "error"`
3. See pattern: all failures have `task.type = "send-email"`
4. Drill down: `tenant.id = "acme-corp" AND task.type = "send-email"`
5. Root cause: tenant's email provider is rate-limiting

## Metrics for Stuck Job Detection

Traces show what happened; metrics detect what's NOT happening. Use metrics for alerting on stuck jobs.

### Workflow Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `flovyn_workflow_pending_duration_seconds` | Histogram | tenant_id, workflow_kind, task_queue | Time from start to first poll |
| `flovyn_workflow_waiting_duration_seconds` | Histogram | tenant_id, workflow_kind | Time spent suspended (waiting for task/timer/child) |
| `flovyn_workflow_total_duration_seconds` | Histogram | tenant_id, workflow_kind, status | Total wall-clock time |
| `flovyn_workflows_stuck_total` | Gauge | tenant_id, task_queue, state | Count of workflows not progressing |

### Task Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `flovyn_task_pending_duration_seconds` | Histogram | tenant_id, task_type, task_queue | Time from scheduled to first poll |
| `flovyn_task_running_duration_seconds` | Histogram | tenant_id, task_type | Time from poll to completion (detects dead workers) |
| `flovyn_task_total_duration_seconds` | Histogram | tenant_id, task_type, status | Total time including retries |
| `flovyn_tasks_stuck_total` | Gauge | tenant_id, task_queue, state | Count of tasks not progressing |

### Alert Examples

```yaml
# No workers picking up workflows
- alert: WorkflowsStuckPending
  expr: flovyn_workflows_stuck_total{state="PENDING"} > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Workflows stuck in PENDING for {{ $labels.task_queue }}"

# Worker died mid-task
- alert: TasksStuckRunning
  expr: flovyn_tasks_stuck_total{state="RUNNING"} > 0
  for: 10m
  labels:
    severity: critical
  annotations:
    summary: "Tasks stuck in RUNNING - worker may be dead"

# Tenant-specific issues
- alert: TenantWorkflowsStuck
  expr: flovyn_workflows_stuck_total{state="WAITING"} > 10
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "Tenant {{ $labels.tenant_id }} has stuck workflows"
```

### Trace Attributes for Post-Mortem

When stuck jobs eventually complete (or are force-terminated), include wait durations:

| Span | Additional Attributes |
|------|----------------------|
| `workflow.completed` / `workflow.failed` | `pending_duration_ms`, `max_waiting_duration_ms` |
| `task.completed` / `task.failed` | `pending_duration_ms`, `running_duration_ms` |

### Stuck Job Investigation Flow

1. **Alert fires**: `WorkflowsStuckPending` for `task_queue=order-processing`
2. **Check metrics**: Grafana shows 5 workflows stuck for tenant `acme-corp`
3. **Find stuck workflows**: Query DB for `state=PENDING AND task_queue='order-processing'`
4. **Check traces**: Search `tenant.id = "acme-corp" AND workflow.kind = "OrderProcessor"`
5. **Root cause**: Last span is `workflow.start` with no `workflow.poll` → no workers registered

## Recommended Infrastructure

### Development

```bash
# Single container with UI
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 4317:4317 \
  jaegertracing/all-in-one:latest

# View at http://localhost:16686
```

### Production

- **Grafana Tempo** - scalable, integrates with Grafana
- **Jaeger** - battle-tested, good UI
- **Datadog/Honeycomb** - SaaS options

## Implementation Dependencies

### Server

```toml
# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-opentelemetry = "0.28"
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }

# Metrics
metrics = "0.24"
metrics-exporter-prometheus = "0.16"
```

### SDK

**No OpenTelemetry dependencies required.** SDK sends structured span data to server via gRPC. See "SDK Span Proxy" section below.

```toml
# Minimal SDK dependencies for tracing
tracing = "0.1"  # For local logging only
```

---

## Design Update: Server-First Tracing

### Deployment Reality

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────────┐
│       Your Infrastructure           │     │     Customer Data Center            │
│                                     │     │                                     │
│  ┌─────────────┐  ┌──────────────┐  │     │  ┌─────────────┐                    │
│  │   Flovyn    │  │   Jaeger/    │  │     │  │   Worker    │                    │
│  │   Server    │──│   Tempo      │  │     │  │   (SDK)     │                    │
│  └─────────────┘  └──────────────┘  │     │  └─────────────┘                    │
│        │                            │     │        │                            │
│        │         ┌──────────────┐   │     │        │  ❌ No access to your      │
│        └─────────│  Prometheus  │   │     │        │     tracing backend        │
│                  └──────────────┘   │     │        │                            │
└─────────────────────────────────────┘     └─────────────────────────────────────┘
                    ▲                                  │
                    │         gRPC (traceparent)       │
                    └──────────────────────────────────┘
```

**Key constraint**: SDK/Worker runs in customer infrastructure and cannot send traces to your backend.

### Principle

**Server-side tracing is the ONLY reliable way to get unified traces.** The SDK cannot contribute to the same trace backend in typical deployments.

### Why Server-First Works

The server has visibility into all workflow operations because everything flows through it:

| Operation | Server Visibility | What Server Captures |
|-----------|------------------|---------------------|
| Workflow start | ✅ Full | workflow_id, kind, input, tenant_id, task_queue |
| Workflow poll | ✅ Full | worker_id, poll count, time since last poll |
| Task schedule | ✅ Full | task_id, type, queue, input |
| Task poll | ✅ Full | worker_id, time pending |
| Task complete/fail | ✅ Full | output/error, duration breakdown |
| Timer schedule | ✅ Full | timer_id, fire_at |
| Timer fire | ✅ Full | actual fire time, delay |
| Child workflow | ✅ Full | parent/child relationship, completion |
| Promise resolve/reject | ✅ Full | promise_id, result |
| Workflow complete/fail | ✅ Full | output/error, all duration metrics |

### What Server Cannot See (SDK-only)

| Operation | Server Visibility | Notes |
|-----------|------------------|-------|
| Internal workflow logic | ❌ None | What code runs between operations |
| SDK-side retries before reporting | ❌ None | Connection retries, etc. |
| SDK processing time | ❌ None | Deserialization, handler lookup |
| SDK errors before server call | ❌ None | Crashes before complete/fail |

**For production debugging, server-side tracing covers 95%+ of use cases.**

## SDK Span Proxy: Unified Traces via Server

### Problem

SDK runs in customer data centers and cannot send traces directly to Flovyn's tracing backend. But we want unified traces showing both server AND SDK execution.

### Solution: Server as Span Proxy

SDK sends **structured execution data** to server via gRPC. Server creates OTLP spans from that data.

```
┌─────────────────────────────┐     ┌─────────────────────────────┐
│   Customer Data Center      │     │   Flovyn Infrastructure     │
│                             │     │                             │
│  ┌─────────┐                │     │  ┌─────────┐  ┌──────────┐  │
│  │  SDK    │────gRPC────────┼────►│  │ Server  │──│  Jaeger  │  │
│  │         │  (structured)  │     │  │ (proxy) │  │          │  │
│  └─────────┘                │     │  └─────────┘  └──────────┘  │
│                             │     │       │                     │
│  ❌ No direct OTLP access   │     │       ▼                     │
│                             │     │  Server creates spans       │
│                             │     │  from SDK data              │
└─────────────────────────────┘     └─────────────────────────────┘
```

### Why Not OTLP Proxy?

OTLP is too flexible - customers could accidentally (or intentionally) send arbitrary data:
- Authentication logs
- Payment information
- PII from their systems

**Solution**: Structured proto messages with server-side validation.

### Proto Definition

```protobuf
// SDK execution metadata - sent once per connection/session
message SdkInfo {
  string language = 1;           // "rust", "python", "typescript", "go", "java"
  string sdk_version = 2;        // "0.1.0"
  optional string runtime_version = 3;  // "1.75.0" (rustc), "3.12" (python), "20.x" (node)
  optional string os = 4;        // "linux", "darwin", "windows"
  optional string arch = 5;      // "x86_64", "aarch64"
  optional string hostname = 6;  // for debugging which worker instance
}

// Individual execution span - only Flovyn-specific data
message ExecutionSpan {
  // Span identification
  string span_id = 1;            // generated by SDK
  optional string parent_span_id = 2;

  // Span type (enum enforced by server)
  string span_type = 3;          // "workflow.execute", "task.execute", "task.retry"

  // Context
  string workflow_id = 4;
  optional string task_id = 5;

  // Timing
  int64 start_time_unix_ns = 6;
  int64 end_time_unix_ns = 7;

  // Status
  bool is_error = 8;
  optional string error_type = 9;     // "timeout", "panic", "user_error"
  optional string error_message = 10; // truncated to 1KB

  // Allowed attributes (server validates keys)
  map<string, string> attributes = 11;
}

message ReportExecutionSpansRequest {
  SdkInfo sdk_info = 1;          // SDK metadata
  repeated ExecutionSpan spans = 2;
}

message ReportExecutionSpansResponse {
  int32 accepted_count = 1;
  int32 rejected_count = 2;
}

// Add to WorkflowDispatch service
service WorkflowDispatch {
  // ... existing RPCs
  rpc ReportExecutionSpans(ReportExecutionSpansRequest) returns (ReportExecutionSpansResponse);
}
```

### Server-Side Caching

To avoid database lookups per span, use an in-memory cache for workflow metadata:

```rust
use moka::future::Cache;
use std::time::Duration;

/// Cached workflow metadata for span proxy
#[derive(Clone)]
struct WorkflowTraceInfo {
    tenant_id: String,
    traceparent: Option<String>,
}

/// LRU cache with TTL for workflow trace context
pub struct WorkflowTraceCache {
    cache: Cache<String, WorkflowTraceInfo>,  // workflow_id -> trace info
}

impl WorkflowTraceCache {
    pub fn new() -> Self {
        Self {
            cache: Cache::builder()
                .max_capacity(10_000)           // Max 10k workflows cached
                .time_to_live(Duration::from_secs(300))  // 5 min TTL
                .time_to_idle(Duration::from_secs(60))   // Evict if unused for 1 min
                .build(),
        }
    }

    /// Get workflow trace info, loading from DB if not cached
    pub async fn get(
        &self,
        workflow_id: &str,
        repo: &WorkflowRepository,
    ) -> Option<WorkflowTraceInfo> {
        self.cache
            .try_get_with(workflow_id.to_string(), async {
                repo.get_workflow(workflow_id)
                    .await
                    .ok()
                    .flatten()
                    .map(|w| WorkflowTraceInfo {
                        tenant_id: w.tenant_id,
                        traceparent: w.traceparent,
                    })
                    .ok_or(())  // Convert None to Err for cache miss
            })
            .await
            .ok()
    }

    /// Invalidate cache entry (call on workflow completion/deletion)
    pub fn invalidate(&self, workflow_id: &str) {
        self.cache.invalidate(workflow_id);
    }

    /// Pre-warm cache when workflow is created/polled
    pub fn insert(&self, workflow_id: &str, info: WorkflowTraceInfo) {
        self.cache.insert(workflow_id.to_string(), info);
    }
}
```

### Server-Side Validation & Span Creation

```rust
const ALLOWED_SPAN_TYPES: &[&str] = &[
    "workflow.execute",
    "workflow.replay",
    "task.execute",
    "task.retry",
    "activity.execute",  // alias for task
];

const ALLOWED_ATTRIBUTES: &[&str] = &[
    "task.type",
    "attempt",
    "max_attempts",
    "retry.delay_ms",
    "workflow.kind",
];

const MAX_ERROR_MESSAGE_LEN: usize = 1024;
const MAX_SPANS_PER_REQUEST: usize = 100;

impl WorkflowDispatch for WorkflowDispatchService {
    async fn report_execution_spans(
        &self,
        request: Request<ReportExecutionSpansRequest>,
    ) -> Result<Response<ReportExecutionSpansResponse>> {
        let tenant_id = self.auth.get_tenant_id(&request)?;
        let req = request.into_inner();
        let sdk_info = req.sdk_info.unwrap_or_default();

        let mut accepted = 0;
        let mut rejected = 0;

        // Rate limit: max spans per request
        let spans = req.spans.into_iter().take(MAX_SPANS_PER_REQUEST);

        for span in spans {
            // 1. Validate span_type is allowed
            if !ALLOWED_SPAN_TYPES.contains(&span.span_type.as_str()) {
                rejected += 1;
                continue;
            }

            // 2. Get workflow info from cache (avoids DB hit per span)
            let workflow_info = match self.trace_cache.get(&span.workflow_id, &self.repo).await {
                Some(info) if info.tenant_id == tenant_id => info,
                _ => {
                    rejected += 1;
                    continue;
                }
            };

            // 3. Restore trace context from cached traceparent
            let parent_ctx = extract_trace_context(workflow_info.traceparent.as_deref());

            // 4. Filter attributes - only allow known keys
            let filtered_attrs: Vec<_> = span.attributes.iter()
                .filter(|(k, _)| ALLOWED_ATTRIBUTES.contains(&k.as_str()))
                .map(|(k, v)| KeyValue::new(k.clone(), v.clone()))
                .collect();

            // 5. Create OTLP span
            let tracer = global::tracer("flovyn-sdk-proxy");
            let otel_span = tracer
                .span_builder(span.span_type.clone())
                .with_start_time(SystemTime::UNIX_EPOCH + Duration::from_nanos(span.start_time_unix_ns as u64))
                .with_kind(SpanKind::Internal)
                .start_with_context(&tracer, &parent_ctx);

            // 6. Add standard attributes
            otel_span.set_attribute(KeyValue::new("tenant.id", tenant_id.clone()));
            otel_span.set_attribute(KeyValue::new("workflow.id", span.workflow_id.clone()));
            otel_span.set_attribute(KeyValue::new("source", "sdk"));

            // SDK metadata
            otel_span.set_attribute(KeyValue::new("sdk.language", sdk_info.language.clone()));
            otel_span.set_attribute(KeyValue::new("sdk.version", sdk_info.sdk_version.clone()));
            if let Some(ref rv) = sdk_info.runtime_version {
                otel_span.set_attribute(KeyValue::new("sdk.runtime_version", rv.clone()));
            }
            if let Some(ref os) = sdk_info.os {
                otel_span.set_attribute(KeyValue::new("sdk.os", os.clone()));
            }
            if let Some(ref arch) = sdk_info.arch {
                otel_span.set_attribute(KeyValue::new("sdk.arch", arch.clone()));
            }
            if let Some(ref hostname) = sdk_info.hostname {
                otel_span.set_attribute(KeyValue::new("sdk.hostname", hostname.clone()));
            }

            // Task-specific
            if let Some(ref task_id) = span.task_id {
                otel_span.set_attribute(KeyValue::new("task.id", task_id.clone()));
            }

            // Filtered custom attributes
            for attr in filtered_attrs {
                otel_span.set_attribute(attr);
            }

            // Error handling
            if span.is_error {
                otel_span.set_status(Status::error(
                    span.error_message
                        .as_deref()
                        .unwrap_or("unknown error")
                        .chars()
                        .take(MAX_ERROR_MESSAGE_LEN)
                        .collect::<String>()
                ));
                if let Some(ref error_type) = span.error_type {
                    otel_span.set_attribute(KeyValue::new("error.type", error_type.clone()));
                }
            }

            // End span with correct timestamp
            otel_span.end_with_timestamp(
                SystemTime::UNIX_EPOCH + Duration::from_nanos(span.end_time_unix_ns as u64)
            );

            accepted += 1;
        }

        Ok(Response::new(ReportExecutionSpansResponse {
            accepted_count: accepted,
            rejected_count: rejected,
        }))
    }
}
```

### SDK Implementation (Rust Example)

```rust
// SDK collects spans during execution, batches and sends
pub struct SpanCollector {
    sdk_info: SdkInfo,
    spans: Vec<ExecutionSpan>,
    client: WorkflowDispatchClient,
}

impl SpanCollector {
    pub fn new(client: WorkflowDispatchClient) -> Self {
        Self {
            sdk_info: SdkInfo {
                language: "rust".into(),
                sdk_version: env!("CARGO_PKG_VERSION").into(),
                runtime_version: Some(rustc_version()),
                os: Some(std::env::consts::OS.into()),
                arch: Some(std::env::consts::ARCH.into()),
                hostname: hostname::get().ok().map(|h| h.to_string_lossy().into()),
            },
            spans: Vec::new(),
            client,
        }
    }

    pub fn record_span(&mut self, span: ExecutionSpan) {
        self.spans.push(span);

        // Auto-flush at threshold
        if self.spans.len() >= 50 {
            self.flush();
        }
    }

    pub async fn flush(&mut self) {
        if self.spans.is_empty() {
            return;
        }

        let spans = std::mem::take(&mut self.spans);
        let _ = self.client.report_execution_spans(ReportExecutionSpansRequest {
            sdk_info: Some(self.sdk_info.clone()),
            spans,
        }).await;
        // Fire and forget - don't fail workflow if telemetry fails
    }
}

// Usage in workflow worker
async fn execute_workflow(ctx: &WorkflowContext, collector: &mut SpanCollector) {
    let start = Instant::now();
    let span_id = generate_span_id();

    let result = workflow_fn(ctx).await;

    collector.record_span(ExecutionSpan {
        span_id,
        parent_span_id: None,
        span_type: "workflow.execute".into(),
        workflow_id: ctx.workflow_id().into(),
        task_id: None,
        start_time_unix_ns: start.elapsed().as_nanos() as i64,
        end_time_unix_ns: Instant::now().elapsed().as_nanos() as i64,
        is_error: result.is_err(),
        error_type: result.as_ref().err().map(|e| e.error_type()),
        error_message: result.as_ref().err().map(|e| e.to_string()),
        attributes: [("workflow.kind".into(), ctx.workflow_kind().into())].into(),
    });
}
```

### What Gets Through vs Blocked

| Data | Allowed? | Reason |
|------|----------|--------|
| `workflow.execute` with timing | ✅ | Known span type |
| `task.execute` with `task.type` attr | ✅ | Known span + attribute |
| SDK version `rust/0.1.0` | ✅ | SDK metadata always allowed |
| `user.login` span type | ❌ | Unknown span type |
| `payment.amount` attribute | ❌ | Unknown attribute key |
| Span for other tenant's workflow | ❌ | Ownership validation fails |
| Error message > 1KB | ⚠️ | Truncated to 1KB |
| > 100 spans per request | ⚠️ | Excess spans dropped |

### Trace Example in Jaeger

```
Trace: workflow-abc-123
│
├── [server] workflow.start
│   └── tenant.id = "acme-corp"
│
├── [server] workflow.poll
│
├── [sdk] workflow.execute                    ◄── SDK span via proxy
│   ├── tenant.id = "acme-corp"
│   ├── source = "sdk"
│   ├── sdk.language = "rust"
│   ├── sdk.version = "0.1.0"
│   ├── sdk.runtime_version = "1.75.0"
│   ├── sdk.os = "linux"
│   ├── sdk.arch = "x86_64"
│   ├── sdk.hostname = "worker-pod-abc"
│   └── workflow.kind = "OrderProcessor"
│
├── [server] task.submitted
│
├── [server] task.poll
│
├── [sdk] task.execute                        ◄── SDK span via proxy
│   ├── source = "sdk"
│   ├── task.id = "task-456"
│   └── task.type = "send-email"
│
├── [server] task.completed
│
└── [server] workflow.completed
```

### Benefits

| Aspect | Benefit |
|--------|---------|
| **Unified traces** | SDK + server spans in same trace |
| **No OTLP in SDK** | Lighter SDK, no OpenTelemetry deps |
| **Server control** | Only Flovyn data gets through |
| **SDK metadata** | Debug which SDK version, OS, etc. |
| **Tenant isolation** | Server validates workflow ownership |
| **Fire-and-forget** | Telemetry failures don't break workflows |
