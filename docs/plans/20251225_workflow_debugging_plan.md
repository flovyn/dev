# OpenTelemetry Workflow Tracing Implementation Plan

**Design Document**: `.dev/docs/design/workflow-debugging.md`
**Goal**: End-to-end distributed tracing for production debugging of workflows

## Repositories

- **Server**: Current repo (`flovyn-server`)
- **SDK**: `../sdk-rust` (sibling directory at `/Users/manhha/Developer/manhha/flovyn/sdk-rust`)

## Overview

Implement OpenTelemetry tracing in both server and SDK so that a single trace shows the complete workflow execution across both components. This enables production debugging by searching traces by workflow_id or tenant_id.

**Key requirement**: All spans must include `tenant.id` attribute for multi-tenant filtering.

## TODO

### Phase 1: Server Infrastructure

#### 1.1 Add Dependencies
- [x] Add to server `Cargo.toml`:
  ```toml
  tracing = "0.1"
  tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
  tracing-opentelemetry = "0.28"
  opentelemetry = "0.27"
  opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
  opentelemetry-otlp = { version = "0.27", features = ["tonic"] }
  ```
- [x] Verify: `cargo check`

#### 1.2 Database Migration
- [x] Create `flovyn-server/migrations/002_traceparent.sql`:
  ```sql
  ALTER TABLE workflow_execution ADD COLUMN traceparent VARCHAR(55);
  ALTER TABLE task_execution ADD COLUMN traceparent VARCHAR(55);
  ```
- [x] Update `WorkflowExecution` in `flovyn-server/src/domain/workflow.rs`: add `traceparent: Option<String>`
- [x] Update `TaskExecution` in `flovyn-server/src/domain/task.rs`: add `traceparent: Option<String>`
- [x] Update repository queries to include traceparent

#### 1.3 Telemetry Module
- [x] Create `flovyn-server/src/telemetry/mod.rs`:
  - [x] `TelemetryConfig` struct
  - [x] `init_telemetry(config: &TelemetryConfig) -> Result<()>`
  - [x] Configure tracing-subscriber with OpenTelemetry layer
  - [x] Support OTLP exporter (production)
  - [x] Support stdout exporter (dev)
  - [x] Graceful shutdown function
- [x] Create `flovyn-server/src/telemetry/context.rs`:
  - [x] `extract_trace_context(traceparent: Option<&str>) -> Context`
  - [x] `inject_traceparent() -> String`
  - [x] `with_workflow_context<F>(traceparent: Option<&str>, f: F)`

#### 1.4 Configuration
- [x] Add `TelemetryConfig` to `flovyn-server/src/config.rs`:
  ```rust
  pub struct TelemetryConfig {
      pub enabled: bool,
      pub otlp_endpoint: Option<String>,
      pub service_name: String,
  }
  ```
- [x] Environment variables:
  - `OTEL__ENABLED` (default: false)
  - `OTEL__OTLP_ENDPOINT`
  - `OTEL__SERVICE_NAME` (default: flovyn-server)

#### 1.5 Main Integration
- [x] Call `init_telemetry()` in `main.rs`
- [x] Add graceful shutdown for telemetry

### Phase 2: Server Instrumentation

#### 2.1 Workflow Lifecycle
- [x] `start_workflow` in `workflow_dispatch.rs`:
  - [x] Create root span `workflow.start`
  - [x] Attributes: tenant.id, workflow.id, workflow.kind, task_queue
  - [x] Store traceparent in database
- [x] `poll_workflow`:
  - [x] Return traceparent in response
- [x] `poll_workflow`:
  - [x] Create span `workflow.poll` (via #[tracing::instrument])
  - [x] Attributes: tenant.id, workflow.id, worker.id
- [x] `submit_workflow_commands` (CompleteWorkflow):
  - [x] Restore trace context from traceparent
  - [x] Create span `workflow.completed`
  - [x] Attributes: tenant.id, workflow.id, total_duration_ms, execution_count, pending_duration_ms
  - [x] Calculate `total_duration_ms` from workflow start time (wall-clock, includes suspend)
  - [x] Calculate `execution_count` from event log (count of workflow polls)
  - [x] Calculate `pending_duration_ms` from time before first poll
  - [x] Record workflow metrics with status=completed
- [x] `submit_workflow_commands` (FailWorkflow):
  - [x] Restore trace context
  - [x] Create span `workflow.failed` with error status
  - [x] Attributes: tenant.id, workflow.id, error, total_duration_ms, execution_count, pending_duration_ms
  - [x] Record workflow metrics with status=failed

#### 2.2 Task Operations
- [x] `submit_task` in `task_execution.rs`:
  - [x] Inherit traceparent from workflow
  - [x] Create span via #[tracing::instrument]
  - [x] Attributes: tenant.id, task.id, task.type, task.queue
  - [x] Store traceparent on task
- [x] `poll_task`:
  - [x] Return traceparent in response (via to_proto())
- [x] `complete_task`:
  - [x] Restore trace context
  - [x] Create span `task.completed`
  - [x] Attributes: tenant.id, workflow.id, task.id, task.type, total_duration_ms, pending_duration_ms, running_duration_ms
  - [x] Record task metrics
- [x] `fail_task`:
  - [x] Restore trace context
  - [x] Create span `task.failed`
  - [x] Attributes: tenant.id, workflow.id, task.id, task.type, error, total_duration_ms, pending_duration_ms, running_duration_ms
  - [x] Record task metrics with status=failed

#### 2.3 Timer Operations
- [x] Timer firing (in `scheduler.rs`):
  - [x] Restore trace context from workflow
  - [x] Create span `workflow.timer.fired`
  - [x] Attributes: tenant.id, workflow.id, timer.id

#### 2.4 Child Workflow Operations
- [x] `start_child_workflow`:
  - [x] Restore parent trace context
  - [x] Create span `workflow.child.started`
  - [x] Attributes: tenant.id, workflow.id, child.id, child.kind
  - [x] Inherit traceparent from parent workflow
- [x] Child completion (in `scheduler.rs`):
  - [x] Restore parent trace context
  - [x] Create span `workflow.child.completed`
  - [x] Attributes: tenant.id, workflow.id, child.id

#### 2.5 Promise Operations
- [x] `resolve_promise`:
  - [x] Restore trace context
  - [x] Create span `workflow.promise.resolved`
  - [x] Attributes: tenant.id, workflow.id, promise.id, promise.name
- [x] `reject_promise`:
  - [x] Restore trace context
  - [x] Create span `workflow.promise.rejected`
  - [x] Attributes: tenant.id, workflow.id, promise.id, promise.name, error

### Phase 3: Proto Changes

#### 3.1 Update Proto
- [x] Add to `PollResponse`:
  ```protobuf
  string traceparent = 2;
  ```
- [x] Add to `TaskExecutionInfo`:
  ```protobuf
  string traceparent = 8;
  ```
- [x] Regenerate proto code

### Phase 4: Remove (Merged into Phase 5)

~~Traceparent pass-through is no longer needed.~~ With SDK Span Proxy, the SDK sends `workflow_id` with spans and the server looks up the traceparent from the database.

### Phase 5: SDK Span Proxy (Recommended for Unified Traces)

**Goal**: SDK sends execution spans to server via gRPC. Server creates OTLP spans. Unified traces without SDK OpenTelemetry dependency.

See design doc section "SDK Span Proxy: Unified Traces via Server" for full details.

#### 5.1 Proto Changes
- [x] Add `SdkInfo` message (language, sdk_version, runtime_version, os, arch, hostname)
- [x] Add `ExecutionSpan` message (span_id, span_type, workflow_id, task_id, timing, error, attributes)
- [x] Add `ReportExecutionSpansRequest` / `ReportExecutionSpansResponse`
- [x] Add `ReportExecutionSpans` RPC to `WorkflowDispatch` service
- [x] Regenerate proto code

#### 5.2 Server Implementation
- [x] Add `moka` dependency for caching:
  ```toml
  moka = { version = "0.12", features = ["future"] }
  ```
- [x] Create `flovyn-server/src/telemetry/trace_cache.rs`:
  - [x] `WorkflowTraceInfo` struct (tenant_id, traceparent)
  - [x] `WorkflowTraceCache` with LRU + TTL (10k entries, 5min TTL, 1min idle)
  - [x] `get()` - load from cache or DB
  - [x] `invalidate()` - call on workflow completion
  - [x] `insert()` - pre-warm on workflow create/poll
- [x] Implement span proxy in `flovyn-server/src/api/grpc/workflow_dispatch.rs`:
  - [x] Allowed span types whitelist
  - [x] Allowed attributes whitelist
  - [x] Tenant validation via cached `WorkflowTraceInfo`
  - [x] OTLP span creation from SDK data
  - [x] SDK metadata attributes (sdk.language, sdk.version, etc.)
  - [x] Error message truncation (1KB max)
  - [x] Rate limiting (100 spans/request max)
- [x] Pre-warm cache in existing code paths:
  - [x] `start_workflow` - insert after creating workflow
  - [x] `poll_workflow` - insert/refresh on poll

#### 5.3 SDK Implementation (Rust)
- [x] Create `SpanCollector` struct in SDK (`flovyn-server/sdk/src/telemetry/mod.rs`)
- [x] Auto-populate `SdkInfo` (language, version, OS, arch, hostname)
- [x] Record spans during workflow execution (`workflow.execute`, `workflow.replay`)
- [x] Batch and flush spans (threshold: 50 spans or on workflow complete)
- [x] Fire-and-forget semantics (don't fail workflow if telemetry fails)
- [x] Add `enable_telemetry` config option to WorkflowWorkerConfig and FlovynClientBuilder

#### 5.4 SDK Implementation (Other Languages - Future)
- [ ] Python SDK: same pattern
- [ ] TypeScript SDK: same pattern
- [ ] Go SDK: same pattern

### Phase 6: Validation

#### 6.1 Local Verification
- [ ] Start Jaeger: `docker run -d -p 16686:16686 -p 4317:4317 jaegertracing/all-in-one`
- [ ] Run server with `OTEL_ENABLED=true OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317`
- [ ] Run SDK with span proxy enabled
- [ ] Execute a workflow with task
- [ ] Verify in Jaeger:
  - [ ] Single trace for workflow
  - [ ] Server spans: `workflow.start`, `workflow.poll`, `task.submitted`, `task.completed`, `workflow.completed`
  - [ ] SDK spans (via proxy): `workflow.execute`, `task.execute`
  - [ ] SDK metadata visible: `sdk.language`, `sdk.version`, `sdk.os`, `sdk.arch`
  - [ ] Correct parent-child relationships
  - [ ] `tenant.id` attribute present on all spans

#### 6.2 End-to-End Test
- [ ] Write integration test that:
  - [ ] Starts workflow
  - [ ] Schedules task
  - [ ] Completes workflow
  - [ ] Verifies server + SDK spans in correct trace
  - [ ] Verifies `tenant.id` attribute on all spans
  - [ ] Verifies SDK metadata attributes

#### 6.3 Multi-Tenant Verification
- [ ] Run workflows for two different tenants
- [ ] Verify traces are filterable by `tenant.id` in Jaeger
- [ ] Verify search: `tenant.id = "tenant-a"` shows only tenant-a workflows
- [ ] Verify cross-tenant queries work: `tenant.id = "tenant-a" AND status = "error"`

#### 6.4 Security Verification
- [ ] Verify unknown span types are rejected
- [ ] Verify unknown attributes are filtered
- [ ] Verify spans for other tenant's workflows are rejected
- [ ] Verify error messages are truncated to 1KB
- [ ] Verify rate limiting (>100 spans/request)

#### 6.5 Production Checklist
- [ ] Verify trace context survives workflow suspend/resume
- [ ] Verify child workflows link correctly
- [ ] Verify timer spans show correct duration
- [ ] Test with workflow that has multiple tasks
- [ ] Test error scenarios (task failure, workflow failure)
- [ ] Verify tenant isolation in traces (no cross-tenant data leakage)

### Phase 7: Metrics for Stuck Job Detection

#### 7.1 Add Dependencies
- [x] Add to server `Cargo.toml`:
  ```toml
  metrics = "0.24"
  metrics-exporter-prometheus = "0.16"
  ```

#### 7.2 Metrics Module
- [x] Create `flovyn-server/src/metrics/mod.rs`:
  - [x] `MetricsConfig` struct (enabled, prometheus_port)
  - [x] `init_metrics(config: &MetricsConfig) -> Result<()>`
  - [x] Setup Prometheus exporter on `/_/metrics` endpoint

#### 7.3 Workflow Metrics (Core)
- [x] `flovyn_workflows_started_total` counter
- [x] `flovyn_workflows_completed_total` counter
- [x] `flovyn_workflows_failed_total` counter
- [x] `flovyn_workflow_duration_seconds` histogram
- [x] Labels: tenant_id, workflow_kind, task_queue, status

#### 7.4 Task Metrics (Core)
- [x] `flovyn_tasks_submitted_total` counter
- [x] `flovyn_tasks_completed_total` counter
- [x] `flovyn_tasks_failed_total` counter
- [x] `flovyn_task_duration_seconds` histogram
- [x] Labels: tenant_id, task_type, queue, status

#### Advanced Metrics (Future)
The following are nice-to-have advanced metrics for more detailed monitoring:
- [ ] `flovyn_workflow_pending_duration_seconds` - time from created to first poll
- [ ] `flovyn_workflow_waiting_duration_seconds` - time spent in WAITING state
- [ ] `flovyn_workflows_stuck_total` gauge - periodic DB query for stuck workflows
- [ ] Stuck job detection background task
- [ ] Configuration for stuck detection thresholds

## File Summary

### Server
```
src/
├── main.rs                            # init_telemetry(), init_metrics()
├── config.rs                          # TelemetryConfig, MetricsConfig, StuckDetectionConfig
├── telemetry/
│   ├── mod.rs                         # NEW: init, shutdown
│   └── context.rs                     # NEW: trace context helpers
├── metrics/
│   └── mod.rs                         # NEW: Prometheus metrics
├── domain/
│   ├── workflow.rs                    # +traceparent field
│   └── task.rs                        # +traceparent field
├── repository/
│   ├── workflow_repository.rs         # +traceparent queries, +stuck job queries
│   └── task_repository.rs             # +traceparent queries, +stuck job queries
├── api/grpc/
│   ├── workflow_dispatch.rs           # Instrument all methods, record metrics
│   └── task_execution.rs              # Instrument all methods, record metrics
├── scheduler/
│   ├── mod.rs                         # Instrument timer/child ops
│   └── stuck_detector.rs              # NEW: stuck job detection background task
└── api/rest/
    └── mod.rs                         # /_/metrics and /_/health endpoints

migrations/
└── 002_traceparent.sql                # NEW

proto/
└── flovyn.proto                       # +traceparent in responses
```

### SDK (at `../sdk-rust`)
```
../sdk-rust/sdk/src/
├── lib.rs                             # Re-export telemetry
├── telemetry/
│   └── mod.rs                         # NEW: SDK telemetry init
├── client/
│   ├── builder.rs                     # +tracing config
│   ├── workflow_dispatch.rs           # Propagate traceparent
│   └── task_execution.rs              # Propagate traceparent
└── worker/
    ├── workflow_worker.rs             # Extract/use traceparent, add tenant.id
    └── task_worker.rs                 # Extract/use traceparent, add tenant.id
└── workflow/
    └── context_impl.rs                # Instrument operations, add tenant.id
```

## Dependencies

### Server
```toml
# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
tracing-opentelemetry = "0.28"
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }

# Metrics
metrics = "0.24"
metrics-exporter-prometheus = "0.16"
```

### SDK
```toml
tracing = "0.1"
tracing-opentelemetry = "0.28"
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }
```

## Observability Load Test Infrastructure

Create a dedicated load-test environment for observability validation, similar to the existing load-test setup.

### Directory Structure

```
load-test/
├── docker-compose.yml          # Full infrastructure
├── Cargo.toml                  # Rust workspace for worker
├── Dockerfile                  # Worker Docker image
├── config/
│   ├── prometheus.yml          # Prometheus scrape config
│   └── grafana/
│       ├── datasources/
│       │   └── datasources.yml # Prometheus, Jaeger, Postgres
│       └── dashboards/
│           ├── dashboard.yml
│           └── observability.json
├── scripts/
│   ├── cli.py                  # Python CLI for test orchestration
│   └── requirements.txt
├── src/
│   ├── main.rs                 # Worker entry point
│   ├── workflows/
│   │   ├── mod.rs
│   │   ├── happy_path.rs       # Fast completion workflow
│   │   ├── timer_workflow.rs   # Suspend time testing
│   │   ├── failing_task.rs     # Retry scenarios
│   │   ├── child_workflow.rs   # Parent-child linking
│   │   └── stuck_workflow.rs   # For stuck detection testing
│   └── tasks/
│       ├── mod.rs
│       ├── fast_task.rs
│       ├── slow_task.rs
│       └── failing_task.rs
├── results/                    # Test results output
└── README.md
```

### Docker Compose

```yaml
# load-test/docker-compose.yml
services:
  # PostgreSQL Database
  postgres:
    image: postgres:18-alpine
    container_name: flovyn-otel-postgres
    environment:
      POSTGRES_DB: flovyn
      POSTGRES_USER: flovyn
      POSTGRES_PASSWORD: flovyn
    ports:
      - "5436:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U flovyn"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - flovyn-network

  # Flovyn Server (Rust)
  flovyn-server:
    build:
      context: ..
      dockerfile: Dockerfile
    container_name: flovyn-otel-server
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://flovyn:flovyn@postgres:5432/flovyn
      SERVER_PORT: 8080
      GRPC_SERVER_PORT: 9090

      # OpenTelemetry
      OTEL_ENABLED: "true"
      OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4317
      OTEL_SERVICE_NAME: flovyn-server

      # Metrics
      METRICS_ENABLED: "true"
      METRICS_PORT: 9091

      # Stuck detection
      STUCK_DETECTION_ENABLED: "true"
      STUCK_WORKFLOW_PENDING_THRESHOLD_SECS: 60
      STUCK_TASK_RUNNING_THRESHOLD_SECS: 120
    ports:
      - "8080:8080"   # REST API
      - "9090:9090"   # gRPC
      - "9091:9091"   # Prometheus metrics
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - flovyn-network

  # Load Test Worker (self-contained in load-test/)
  loadtest-worker:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: flovyn-otel-worker
    depends_on:
      flovyn-server:
        condition: service_healthy
    environment:
      FLOVYN_SERVER_URL: http://flovyn-server:9090
      WORKER_NAME: loadtest-worker
      TENANT_ID: ${TENANT_ID:-}
      WORKER_TOKEN: ${WORKER_TOKEN:-}

      # Worker configuration
      TASK_QUEUE: observability-test
      MAX_CONCURRENT_WORKFLOWS: 10
      MAX_CONCURRENT_TASKS: 20

      # OpenTelemetry (SDK side)
      OTEL_ENABLED: "true"
      OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4317
      OTEL_SERVICE_NAME: flovyn-worker
    networks:
      - flovyn-network
    restart: unless-stopped

  # Jaeger for distributed tracing
  jaeger:
    image: jaegertracing/all-in-one:1.54
    container_name: flovyn-otel-jaeger
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16686:16686"  # Jaeger UI
      - "4317:4317"    # OTLP gRPC
      - "4318:4318"    # OTLP HTTP
    networks:
      - flovyn-network

  # Prometheus for metrics
  prometheus:
    image: prom/prometheus:latest
    container_name: flovyn-otel-prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=7d'
    ports:
      - "9092:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    networks:
      - flovyn-network

  # Grafana for visualization
  grafana:
    image: grafana/grafana:latest
    container_name: flovyn-otel-grafana
    depends_on:
      - prometheus
      - jaeger
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_INSTALL_PLUGINS: grafana-postgresql-datasource
    ports:
      - "3010:3000"
    volumes:
      - ./config/grafana/datasources:/etc/grafana/provisioning/datasources:ro
      - ./config/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
      - grafana-data:/var/lib/grafana
    networks:
      - flovyn-network

volumes:
  postgres-data:
  prometheus-data:
  grafana-data:

networks:
  flovyn-network:
    driver: bridge
```

### Prometheus Config

```yaml
# load-test/config/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'flovyn-observability-test'
    environment: 'test'

scrape_configs:
  - job_name: 'flovyn-server'
    static_configs:
      - targets: ['flovyn-server:9091']
        labels:
          service: 'flovyn-server'

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

### Grafana Datasources

```yaml
# load-test/config/grafana/datasources/datasources.yml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false

  - name: Jaeger
    type: jaeger
    uid: jaeger
    access: proxy
    url: http://jaeger:16686
    editable: false

  - name: PostgreSQL
    type: grafana-postgresql-datasource
    uid: postgres
    access: proxy
    url: postgres:5432
    user: flovyn
    secureJsonData:
      password: flovyn
    jsonData:
      database: flovyn
      sslmode: disable
    editable: false
```

### Python CLI for Observability Testing

```python
# load-test/scripts/cli.py
#!/usr/bin/env python3
"""
Flovyn Observability Test CLI

Usage:
    python cli.py start [-b]           # Start infrastructure
    python cli.py stop [-v]            # Stop infrastructure
    python cli.py setup                # Create test tenant/credentials
    python cli.py status               # Check service health

    # Scenario testing
    python cli.py scenario happy       # Run happy path scenario
    python cli.py scenario stuck       # Run stuck workflow scenario
    python cli.py scenario slow        # Run slow workflow scenario
    python cli.py scenario multi-tenant # Run multi-tenant scenario
    python cli.py scenario all         # Run all scenarios

    # Load testing
    python cli.py load --count 1000 --tenants 10 --concurrency 50
    python cli.py load --duration 5m --rate 100

    # Verification
    python cli.py verify traces --workflow-id <id>
    python cli.py verify metrics --check stuck_total
    python cli.py verify all

    # Reports
    python cli.py report               # Generate report
    python cli.py report --json        # JSON output
"""

import argparse
import json
import os
import subprocess
import sys
import time
import requests
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, List
from concurrent.futures import ThreadPoolExecutor, as_completed

# ... (similar structure to existing cli.py)

class ObservabilityTester:
    """Run observability test scenarios."""

    def __init__(self, config):
        self.config = config
        self.jaeger_url = "http://localhost:16686"
        self.prometheus_url = "http://localhost:9092"

    def run_scenario(self, scenario: str, tenant: Optional[str] = None) -> dict:
        """Run a specific test scenario."""
        tenant = tenant or self.config.tenant_id

        scenarios = {
            "happy": self._scenario_happy_path,
            "stuck": self._scenario_stuck_workflow,
            "slow": self._scenario_slow_workflow,
            "timer": self._scenario_timer_workflow,
            "failing": self._scenario_failing_task,
            "child": self._scenario_child_workflow,
            "multi-tenant": self._scenario_multi_tenant,
        }

        if scenario == "all":
            results = {}
            for name, func in scenarios.items():
                results[name] = func(tenant)
            return results

        if scenario not in scenarios:
            return {"error": f"Unknown scenario: {scenario}"}

        return scenarios[scenario](tenant)

    def _scenario_happy_path(self, tenant: str) -> dict:
        """Run happy path workflow and verify trace."""
        workflow_id = self._trigger_workflow(tenant, "happy-path-workflow")
        self._wait_for_completion(tenant, workflow_id)

        # Verify trace
        trace = self._get_trace(workflow_id)
        return {
            "workflow_id": workflow_id,
            "trace_found": trace is not None,
            "spans": len(trace.get("spans", [])) if trace else 0,
            "has_tenant_id": self._all_spans_have_attr(trace, "tenant.id"),
            "has_completion": self._has_span(trace, "workflow.completed"),
        }

    def _scenario_stuck_workflow(self, tenant: str) -> dict:
        """Trigger workflow to unregistered queue, verify stuck metrics."""
        workflow_id = self._trigger_workflow(
            tenant,
            "stuck-workflow",
            task_queue="unregistered-queue"
        )

        # Wait for stuck detector
        time.sleep(65)

        # Check metrics
        stuck_count = self._query_prometheus(
            f'flovyn_workflows_stuck_total{{tenant_id="{tenant}",state="PENDING"}}'
        )

        return {
            "workflow_id": workflow_id,
            "stuck_detected": stuck_count > 0,
            "stuck_count": stuck_count,
        }

    def _scenario_slow_workflow(self, tenant: str) -> dict:
        """Run workflow with timer, verify duration attributes."""
        workflow_id = self._trigger_workflow(
            tenant,
            "timer-workflow",
            input={"timer_seconds": 5}
        )
        self._wait_for_completion(tenant, workflow_id, timeout=60)

        trace = self._get_trace(workflow_id)
        completed_span = self._get_span(trace, "workflow.completed")

        return {
            "workflow_id": workflow_id,
            "total_duration_ms": completed_span.get("total_duration_ms") if completed_span else None,
            "execution_duration_ms": completed_span.get("execution_duration_ms") if completed_span else None,
            "suspend_time_correct": self._verify_suspend_time(completed_span, 5000),
        }

    def _scenario_multi_tenant(self, tenant: str) -> dict:
        """Run workflows for multiple tenants, verify isolation."""
        tenants = [f"tenant-{i}" for i in range(3)]
        workflow_ids = {}

        for t in tenants:
            wf_id = self._trigger_workflow(t, "happy-path-workflow")
            workflow_ids[t] = wf_id

        # Wait for all
        for t, wf_id in workflow_ids.items():
            self._wait_for_completion(t, wf_id)

        # Verify traces are isolated
        isolated = True
        for t in tenants:
            traces = self._search_traces(f'tenant.id = "{t}"')
            for trace in traces:
                for span in trace.get("spans", []):
                    if span.get("tenant.id") != t:
                        isolated = False

        return {
            "tenants": tenants,
            "workflow_ids": workflow_ids,
            "isolated": isolated,
        }

    def verify_traces(self, workflow_id: str) -> dict:
        """Verify trace exists and is complete."""
        trace = self._get_trace(workflow_id)
        if not trace:
            return {"found": False}

        return {
            "found": True,
            "span_count": len(trace.get("spans", [])),
            "spans": [s.get("operationName") for s in trace.get("spans", [])],
            "has_tenant_id": self._all_spans_have_attr(trace, "tenant.id"),
            "has_workflow_id": self._all_spans_have_attr(trace, "workflow.id"),
        }

    def verify_metrics(self, check: str) -> dict:
        """Verify metrics are being recorded."""
        checks = {
            "stuck_total": 'flovyn_workflows_stuck_total',
            "workflow_duration": 'flovyn_workflow_total_duration_seconds_count',
            "task_duration": 'flovyn_task_total_duration_seconds_count',
        }

        query = checks.get(check, check)
        value = self._query_prometheus(query)

        return {
            "metric": query,
            "value": value,
            "exists": value is not None,
        }

    def _get_trace(self, workflow_id: str) -> Optional[dict]:
        """Get trace from Jaeger by workflow_id."""
        try:
            resp = requests.get(
                f"{self.jaeger_url}/api/traces",
                params={"service": "flovyn-server", "tags": f'{{"workflow.id":"{workflow_id}"}}'},
                timeout=10
            )
            if resp.status_code == 200:
                data = resp.json()
                traces = data.get("data", [])
                return traces[0] if traces else None
        except Exception:
            pass
        return None

    def _query_prometheus(self, query: str) -> Optional[float]:
        """Query Prometheus for a metric value."""
        try:
            resp = requests.get(
                f"{self.prometheus_url}/api/v1/query",
                params={"query": query},
                timeout=10
            )
            if resp.status_code == 200:
                data = resp.json()
                result = data.get("data", {}).get("result", [])
                if result:
                    return float(result[0]["value"][1])
        except Exception:
            pass
        return None
```

### Load Test Worker (Self-Contained)

#### Cargo.toml

```toml
# load-test/Cargo.toml
[package]
name = "flovyn-observability-loadtest"
version = "0.1.0"
edition = "2021"

[dependencies]
flovyn-sdk = { path = "../sdk-rust/sdk" }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-opentelemetry = "0.28"
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }
anyhow = "1"
```

#### Dockerfile

```dockerfile
# load-test/Dockerfile
FROM rust:1.75 as builder

WORKDIR /app

# Copy SDK dependency
COPY ../sdk-rust /sdk-rust

# Copy load-test source
COPY load-test/Cargo.toml load-test/Cargo.lock ./
COPY load-test/src ./src

RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/flovyn-observability-loadtest /usr/local/bin/
CMD ["flovyn-observability-loadtest"]
```

#### Worker Entry Point

```rust
// load-test/src/main.rs
use anyhow::Result;
use flovyn_sdk::{Worker, WorkerConfig};
use std::env;

mod workflows;
mod tasks;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing with OpenTelemetry
    init_telemetry()?;

    let config = WorkerConfig {
        server_url: env::var("FLOVYN_SERVER_URL")?,
        tenant_id: env::var("TENANT_ID")?,
        worker_token: env::var("WORKER_TOKEN")?,
        task_queue: env::var("TASK_QUEUE").unwrap_or_else(|_| "observability-test".into()),
        max_concurrent_workflows: env::var("MAX_CONCURRENT_WORKFLOWS")
            .ok().and_then(|s| s.parse().ok()).unwrap_or(10),
        max_concurrent_tasks: env::var("MAX_CONCURRENT_TASKS")
            .ok().and_then(|s| s.parse().ok()).unwrap_or(20),
    };

    let worker = Worker::new(config)
        // Register workflows
        .register_workflow::<workflows::HappyPathWorkflow>()
        .register_workflow::<workflows::TimerWorkflow>()
        .register_workflow::<workflows::FailingTaskWorkflow>()
        .register_workflow::<workflows::ParentWorkflow>()
        .register_workflow::<workflows::ChildWorkflow>()
        .register_workflow::<workflows::StuckWorkflow>()
        // Register tasks
        .register_task::<tasks::FastTask>()
        .register_task::<tasks::SlowTask>()
        .register_task::<tasks::FailingTask>()
        .build()
        .await?;

    tracing::info!("Starting observability load test worker");
    worker.run().await?;

    Ok(())
}

fn init_telemetry() -> Result<()> {
    use opentelemetry::global;
    use opentelemetry_otlp::WithExportConfig;
    use tracing_subscriber::prelude::*;

    let otel_enabled = env::var("OTEL_ENABLED")
        .map(|v| v == "true")
        .unwrap_or(false);

    if otel_enabled {
        let endpoint = env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
            .unwrap_or_else(|_| "http://localhost:4317".into());

        let tracer = opentelemetry_otlp::new_pipeline()
            .tracing()
            .with_exporter(
                opentelemetry_otlp::new_exporter()
                    .tonic()
                    .with_endpoint(&endpoint)
            )
            .install_batch(opentelemetry_sdk::runtime::Tokio)?;

        let otel_layer = tracing_opentelemetry::layer().with_tracer(tracer);

        tracing_subscriber::registry()
            .with(tracing_subscriber::EnvFilter::from_default_env())
            .with(tracing_subscriber::fmt::layer())
            .with(otel_layer)
            .init();
    } else {
        tracing_subscriber::fmt::init();
    }

    Ok(())
}
```

#### Workflows

```rust
// load-test/src/workflows/mod.rs
mod happy_path;
mod timer_workflow;
mod failing_task;
mod child_workflow;
mod stuck_workflow;

pub use happy_path::HappyPathWorkflow;
pub use timer_workflow::TimerWorkflow;
pub use failing_task::FailingTaskWorkflow;
pub use child_workflow::{ParentWorkflow, ChildWorkflow};
pub use stuck_workflow::StuckWorkflow;
```

```rust
// load-test/src/workflows/happy_path.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};

/// Happy path workflow - completes quickly with minimal operations
#[derive(Workflow)]
pub struct HappyPathWorkflow;

#[async_trait]
impl WorkflowDefinition for HappyPathWorkflow {
    const KIND: &'static str = "happy-path-workflow";

    async fn execute(&self, ctx: WorkflowContext, input: Value) -> Result<Value> {
        // Simple inline computation
        let result = ctx.run("compute", || async {
            (1..100).sum::<i32>()
        }).await?;

        Ok(json!({
            "result": result,
            "message": "Happy path completed"
        }))
    }
}
```

```rust
// load-test/src/workflows/timer_workflow.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};
use std::time::Duration;

/// Timer workflow - creates suspend time for duration testing
#[derive(Workflow)]
pub struct TimerWorkflow;

#[async_trait]
impl WorkflowDefinition for TimerWorkflow {
    const KIND: &'static str = "timer-workflow";

    async fn execute(&self, ctx: WorkflowContext, input: Value) -> Result<Value> {
        let seconds = input["timer_seconds"].as_u64().unwrap_or(5);

        ctx.sleep(Duration::from_secs(seconds)).await?;

        Ok(json!({
            "slept_seconds": seconds,
            "message": "Timer workflow completed"
        }))
    }
}
```

```rust
// load-test/src/workflows/failing_task.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};
use crate::tasks::FailingTask;

/// Failing task workflow - tests retry behavior
#[derive(Workflow)]
pub struct FailingTaskWorkflow;

#[async_trait]
impl WorkflowDefinition for FailingTaskWorkflow {
    const KIND: &'static str = "failing-task-workflow";

    async fn execute(&self, ctx: WorkflowContext, input: Value) -> Result<Value> {
        let fail_count = input["fail_count"].as_u64().unwrap_or(2);

        let result = ctx.execute_task::<FailingTask>(json!({
            "fail_count": fail_count
        })).await?;

        Ok(json!({
            "task_result": result,
            "message": "Task eventually succeeded"
        }))
    }
}
```

```rust
// load-test/src/workflows/child_workflow.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};
use std::time::Duration;

/// Parent workflow - spawns child and waits
#[derive(Workflow)]
pub struct ParentWorkflow;

#[async_trait]
impl WorkflowDefinition for ParentWorkflow {
    const KIND: &'static str = "parent-workflow";

    async fn execute(&self, ctx: WorkflowContext, input: Value) -> Result<Value> {
        let child = ctx.start_child_workflow::<ChildWorkflow>(input.clone()).await?;
        let child_result = child.result().await?;

        Ok(json!({
            "child_result": child_result,
            "message": "Parent workflow completed"
        }))
    }
}

/// Child workflow - used by parent workflow
#[derive(Workflow)]
pub struct ChildWorkflow;

#[async_trait]
impl WorkflowDefinition for ChildWorkflow {
    const KIND: &'static str = "child-workflow";

    async fn execute(&self, ctx: WorkflowContext, _input: Value) -> Result<Value> {
        ctx.sleep(Duration::from_secs(1)).await?;

        Ok(json!({
            "child": "completed"
        }))
    }
}
```

```rust
// load-test/src/workflows/stuck_workflow.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};

/// Stuck workflow - registered but uses a task queue with no workers
/// Used to test stuck detection metrics
#[derive(Workflow)]
pub struct StuckWorkflow;

#[async_trait]
impl WorkflowDefinition for StuckWorkflow {
    const KIND: &'static str = "stuck-workflow";

    async fn execute(&self, ctx: WorkflowContext, _input: Value) -> Result<Value> {
        // This workflow should be triggered on a different task queue
        // where no workers are registered, causing it to stay PENDING
        Ok(json!({"message": "Should never reach here if testing stuck detection"}))
    }
}
```

#### Tasks

```rust
// load-test/src/tasks/mod.rs
mod fast_task;
mod slow_task;
mod failing_task;

pub use fast_task::FastTask;
pub use slow_task::SlowTask;
pub use failing_task::FailingTask;
```

```rust
// load-test/src/tasks/fast_task.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};

/// Fast task - completes immediately
#[derive(Task)]
pub struct FastTask;

#[async_trait]
impl TaskDefinition for FastTask {
    const TASK_TYPE: &'static str = "fast-task";

    async fn execute(&self, _ctx: TaskContext, input: Value) -> Result<Value> {
        Ok(json!({
            "input": input,
            "result": "fast task completed"
        }))
    }
}
```

```rust
// load-test/src/tasks/slow_task.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};
use std::time::Duration;

/// Slow task - sleeps for configured duration
#[derive(Task)]
pub struct SlowTask;

#[async_trait]
impl TaskDefinition for SlowTask {
    const TASK_TYPE: &'static str = "slow-task";

    async fn execute(&self, _ctx: TaskContext, input: Value) -> Result<Value> {
        let sleep_ms = input["sleep_ms"].as_u64().unwrap_or(1000);

        tokio::time::sleep(Duration::from_millis(sleep_ms)).await;

        Ok(json!({
            "slept_ms": sleep_ms,
            "result": "slow task completed"
        }))
    }
}
```

```rust
// load-test/src/tasks/failing_task.rs
use flovyn_sdk::prelude::*;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU32, Ordering};

/// Failing task - fails N times before succeeding
/// Uses static counter to track attempts across retries
#[derive(Task)]
pub struct FailingTask;

static ATTEMPT_COUNTER: AtomicU32 = AtomicU32::new(0);

#[async_trait]
impl TaskDefinition for FailingTask {
    const TASK_TYPE: &'static str = "failing-task";

    async fn execute(&self, ctx: TaskContext, input: Value) -> Result<Value> {
        let fail_count = input["fail_count"].as_u64().unwrap_or(2) as u32;
        let attempt = ctx.attempt();

        if attempt <= fail_count {
            anyhow::bail!("Intentional failure, attempt {} of {}", attempt, fail_count + 1);
        }

        Ok(json!({
            "attempts": attempt,
            "result": "finally succeeded"
        }))
    }
}
```

### CLI Quick Reference

```bash
# Start infrastructure
cd load-test
python scripts/cli.py start -b

# Setup tenant
python scripts/cli.py setup

# Run scenarios
python scripts/cli.py scenario happy
python scripts/cli.py scenario stuck
python scripts/cli.py scenario all

# Load test
python scripts/cli.py load --count 1000 --tenants 10

# Verify
python scripts/cli.py verify traces --workflow-id <id>
python scripts/cli.py verify metrics --check stuck_total

# View dashboards
open http://localhost:3000     # Grafana
open http://localhost:16686    # Jaeger

# Stop
python scripts/cli.py stop
```

## Test Scenarios

Create sample workflows to validate observability works correctly.

### Test Workflow Definitions

Located in `tests/observability/workflows/`:

| Workflow | Purpose | Expected Outcome |
|----------|---------|------------------|
| `HappyPathWorkflow` | Basic success case | Trace shows full lifecycle, metrics recorded |
| `SlowWorkflow` | Sleeps 5s in execution | High `execution_duration_ms` |
| `LongTimerWorkflow` | Timer for 10s | High `total_duration_ms`, low `execution_duration_ms` |
| `FailingTaskWorkflow` | Task fails 2x then succeeds | `task.retry` spans visible, retry metrics |
| `FailingWorkflow` | Workflow fails | `workflow.failed` span with error |
| `ChildWorkflow` | Parent spawns child | Both traces linked correctly |
| `MultiTenantWorkflow` | Same workflow, 2 tenants | Traces filterable by `tenant.id` |
| `NoWorkerWorkflow` | Workflow for unregistered queue | Stuck in PENDING, gauge increments |
| `DeadWorkerTask` | Task polled, worker killed | Stuck in RUNNING, gauge increments |

### Test Harness

Create `flovyn-server/tests/observability/harness.rs`:

```rust
/// Starts infrastructure (Jaeger, Prometheus) via testcontainers
pub struct ObservabilityTestHarness {
    jaeger: Container<JaegerImage>,
    prometheus: Container<PrometheusImage>,
    server: FlovynServer,
}

impl ObservabilityTestHarness {
    /// Run a scenario and return collected traces/metrics
    pub async fn run_scenario(&self, scenario: Scenario) -> ScenarioResult;

    /// Query Jaeger for traces
    pub async fn get_traces(&self, query: TraceQuery) -> Vec<Trace>;

    /// Query Prometheus for metrics
    pub async fn get_metrics(&self, query: &str) -> Vec<MetricValue>;
}
```

### Scenario Runner CLI

Create `flovyn-server/bin/test-observability.rs` for manual testing:

```bash
# Run all scenarios
cargo run --bin test-observability -- --all

# Run specific scenario
cargo run --bin test-observability -- --scenario stuck-workflow

# Run for specific tenant
cargo run --bin test-observability -- --scenario happy-path --tenant acme-corp

# Verify traces exist
cargo run --bin test-observability -- --verify-traces --workflow-id abc-123

# Verify metrics
cargo run --bin test-observability -- --verify-metrics --check stuck_total
```

### Automated Test Cases

#### Trace Verification Tests

```rust
#[tokio::test]
async fn test_happy_path_trace() {
    let harness = ObservabilityTestHarness::new().await;
    let result = harness.run_scenario(Scenario::HappyPath).await;

    let traces = harness.get_traces(TraceQuery {
        workflow_id: result.workflow_id,
    }).await;

    assert_eq!(traces.len(), 1);
    let trace = &traces[0];

    // Verify span sequence
    assert!(trace.has_span("workflow.start"));
    assert!(trace.has_span("workflow.poll"));
    assert!(trace.has_span("workflow.execute"));  // SDK
    assert!(trace.has_span("workflow.completed"));

    // Verify tenant.id on all spans
    for span in &trace.spans {
        assert_eq!(span.get_attr("tenant.id"), "test-tenant");
    }

    // Verify duration attributes
    let completed = trace.get_span("workflow.completed");
    assert!(completed.get_attr_i64("total_duration_ms") > 0);
    assert!(completed.get_attr_i64("execution_duration_ms") > 0);
}

#[tokio::test]
async fn test_stuck_workflow_metrics() {
    let harness = ObservabilityTestHarness::new().await;

    // Start workflow with no workers
    let result = harness.run_scenario(Scenario::NoWorker).await;

    // Wait for stuck detector to run
    tokio::time::sleep(Duration::from_secs(35)).await;

    // Verify gauge incremented
    let metrics = harness.get_metrics(
        "flovyn_workflows_stuck_total{state=\"PENDING\"}"
    ).await;

    assert!(metrics[0].value >= 1.0);
}

#[tokio::test]
async fn test_multi_tenant_isolation() {
    let harness = ObservabilityTestHarness::new().await;

    // Run same workflow for two tenants
    harness.run_scenario(Scenario::HappyPath { tenant: "tenant-a" }).await;
    harness.run_scenario(Scenario::HappyPath { tenant: "tenant-b" }).await;

    // Query traces for tenant-a
    let traces_a = harness.get_traces(TraceQuery {
        filter: "tenant.id = \"tenant-a\"",
    }).await;

    // Verify no tenant-b data leaked
    for trace in &traces_a {
        for span in &trace.spans {
            assert_eq!(span.get_attr("tenant.id"), "tenant-a");
        }
    }
}

#[tokio::test]
async fn test_duration_attributes() {
    let harness = ObservabilityTestHarness::new().await;

    // Run workflow with 5s timer
    let result = harness.run_scenario(Scenario::LongTimer {
        duration: Duration::from_secs(5)
    }).await;

    let trace = harness.get_trace(result.workflow_id).await;
    let completed = trace.get_span("workflow.completed");

    let total = completed.get_attr_i64("total_duration_ms");
    let execution = completed.get_attr_i64("execution_duration_ms");

    // Total should be ~5s (timer) + execution
    assert!(total >= 5000);
    // Execution should be small (just workflow logic)
    assert!(execution < 1000);
    // Suspend time = total - execution (should be ~5s)
    assert!(total - execution >= 4500);
}
```

#### Metrics Verification Tests

```rust
#[tokio::test]
async fn test_workflow_duration_histogram() {
    let harness = ObservabilityTestHarness::new().await;

    // Run 10 workflows
    for _ in 0..10 {
        harness.run_scenario(Scenario::HappyPath).await;
    }

    // Verify histogram has data
    let metrics = harness.get_metrics(
        "flovyn_workflow_total_duration_seconds_count{status=\"completed\"}"
    ).await;

    assert_eq!(metrics[0].value, 10.0);
}

#[tokio::test]
async fn test_task_metrics_on_failure() {
    let harness = ObservabilityTestHarness::new().await;

    let result = harness.run_scenario(Scenario::FailingTask {
        fail_count: 2,  // Fail 2x, succeed on 3rd
    }).await;

    // Verify task metrics include retries
    let metrics = harness.get_metrics(
        "flovyn_task_total_duration_seconds_count{status=\"completed\"}"
    ).await;

    assert_eq!(metrics[0].value, 1.0);  // 1 successful task
}
```

### Load Testing

Generate high volume to validate observability at scale.

#### Load Test CLI

```bash
# Generate 1000 workflows across 10 tenants
cargo run --bin test-observability -- load \
  --workflows 1000 \
  --tenants 10 \
  --concurrency 50

# Generate mixed scenarios
cargo run --bin test-observability -- load \
  --workflows 500 \
  --mix "happy:70,slow:10,failing:15,timer:5" \
  --tenants 5

# Sustained load for 5 minutes
cargo run --bin test-observability -- load \
  --duration 5m \
  --rate 100  # 100 workflows/sec
  --tenants 20
```

#### Load Test Scenarios

| Test | Config | Validates |
|------|--------|-----------|
| Burst | 1000 workflows, 100 concurrency | Trace ingestion under load |
| Sustained | 100/sec for 10 min | Metrics stability, no memory leaks |
| Multi-tenant | 1000 workflows, 100 tenants | Label cardinality handling |
| Mixed failures | 30% failure rate | Error tracking at scale |
| Timer heavy | 500 workflows with 1-10s timers | Suspend time distribution |

#### Load Test Verification

```rust
#[tokio::test]
#[ignore]  // Run manually: cargo test load_test -- --ignored
async fn load_test_1000_workflows() {
    let harness = ObservabilityTestHarness::new().await;

    let start = Instant::now();

    // Generate 1000 workflows across 10 tenants
    let futures: Vec<_> = (0..1000).map(|i| {
        let tenant = format!("tenant-{}", i % 10);
        harness.run_scenario(Scenario::HappyPath { tenant })
    }).collect();

    join_all(futures).await;

    let elapsed = start.elapsed();
    println!("Completed 1000 workflows in {:?}", elapsed);

    // Wait for traces/metrics to flush
    tokio::time::sleep(Duration::from_secs(5)).await;

    // Verify all workflows have traces
    for tenant_id in 0..10 {
        let traces = harness.get_traces(TraceQuery {
            filter: format!("tenant.id = \"tenant-{}\"", tenant_id),
            limit: 200,
        }).await;

        assert_eq!(traces.len(), 100, "Expected 100 traces for tenant-{}", tenant_id);
    }

    // Verify metrics count
    let metrics = harness.get_metrics(
        "flovyn_workflow_total_duration_seconds_count"
    ).await;

    let total: f64 = metrics.iter().map(|m| m.value).sum();
    assert_eq!(total, 1000.0);
}

#[tokio::test]
#[ignore]
async fn load_test_histogram_distribution() {
    let harness = ObservabilityTestHarness::new().await;

    // Generate workflows with varying durations
    let scenarios = vec![
        (100, Scenario::HappyPath),           // Fast (~100ms)
        (50, Scenario::SlowWorkflow),          // Medium (~5s)
        (20, Scenario::LongTimer { secs: 10 }), // Slow (~10s)
    ];

    for (count, scenario) in scenarios {
        for _ in 0..count {
            harness.run_scenario(scenario.clone()).await;
        }
    }

    tokio::time::sleep(Duration::from_secs(5)).await;

    // Verify histogram has reasonable bucket distribution
    let buckets = harness.get_metrics(
        "flovyn_workflow_total_duration_seconds_bucket"
    ).await;

    // Should have entries in multiple buckets
    let non_empty_buckets: Vec<_> = buckets.iter()
        .filter(|b| b.value > 0.0)
        .collect();

    assert!(non_empty_buckets.len() >= 3, "Expected data in multiple histogram buckets");
}

#[tokio::test]
#[ignore]
async fn load_test_stuck_detector_under_load() {
    let harness = ObservabilityTestHarness::new().await;

    // Create 50 stuck workflows (no workers)
    for i in 0..50 {
        let tenant = format!("stuck-tenant-{}", i % 5);
        harness.start_workflow_no_worker(Scenario::NoWorker { tenant }).await;
    }

    // Also create 200 normal workflows
    for i in 0..200 {
        let tenant = format!("normal-tenant-{}", i % 10);
        harness.run_scenario(Scenario::HappyPath { tenant }).await;
    }

    // Wait for stuck detector
    tokio::time::sleep(Duration::from_secs(35)).await;

    // Verify stuck gauge is correct
    let stuck = harness.get_metrics(
        "flovyn_workflows_stuck_total{state=\"PENDING\"}"
    ).await;

    let total_stuck: f64 = stuck.iter().map(|m| m.value).sum();
    assert_eq!(total_stuck, 50.0);

    // Verify normal metrics also recorded
    let completed = harness.get_metrics(
        "flovyn_workflow_total_duration_seconds_count{status=\"completed\"}"
    ).await;

    let total_completed: f64 = completed.iter().map(|m| m.value).sum();
    assert_eq!(total_completed, 200.0);
}
```

#### Performance Baselines

After load testing, record baselines:

| Metric | Target | Measured |
|--------|--------|----------|
| Trace ingestion rate | > 500 traces/sec | ___ |
| P99 span export latency | < 100ms | ___ |
| Prometheus scrape time | < 500ms | ___ |
| Stuck detector cycle time | < 1s | ___ |
| Memory growth (1hr sustained) | < 100MB | ___ |

### Manual Verification Checklist

After running test scenarios, manually verify in UIs:

#### Jaeger UI (http://localhost:16686)
- [ ] Search by `workflow.id` returns single trace
- [ ] Search by `tenant.id` filters correctly
- [ ] Span hierarchy shows correct parent-child
- [ ] Span gaps visible during suspend periods
- [ ] All spans have `tenant.id` attribute
- [ ] Duration attributes present on completion spans
- [ ] Error spans show error details

#### Prometheus UI (http://localhost:9090)
- [ ] `flovyn_workflow_total_duration_seconds` histogram has data
- [ ] `flovyn_workflows_stuck_total` gauge shows stuck workflows
- [ ] Metrics have `tenant_id` label
- [ ] Metrics have correct `status` labels (completed/failed)

#### Grafana Dashboard (optional)
- [ ] Workflow duration P50/P95/P99
- [ ] Stuck workflows over time
- [ ] Task failure rate by tenant
- [ ] Execution vs suspend time breakdown

## Quick Start (After Implementation)

```bash
# Start Jaeger (traces)
docker run -d --name jaeger -p 16686:16686 -p 4317:4317 jaegertracing/all-in-one

# Start Prometheus (metrics)
docker run -d --name prometheus -p 9090:9090 \
  -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml \
  prom/prometheus

# Server
OTEL_ENABLED=true \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_SERVICE_NAME=flovyn-server \
METRICS_ENABLED=true \
./dev/run.sh

# SDK (in your app)
let client = FlovynClient::builder()
    .enable_tracing(true)
    .otel_endpoint("http://localhost:4317")
    .service_name("my-worker")
    // ... other config
    .build()
    .await?;

# View traces
open http://localhost:16686
# Search by workflow: workflow.id = "<your-workflow-id>"
# Search by tenant: tenant.id = "<your-tenant-id>"
# Search by tenant + errors: tenant.id = "<your-tenant-id>" AND status = "error"

# View metrics
open http://localhost:9090
# Query: flovyn_workflows_stuck_total
# Query: flovyn_workflow_total_duration_seconds
```
