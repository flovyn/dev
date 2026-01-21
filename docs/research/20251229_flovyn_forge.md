# Flovyn Forge Research

## Problem Statement

Currently, to build and run workflows/tasks with Flovyn, users must integrate with a supported language SDK (Rust, Kotlin). For simple use cases—running existing Bash, PowerShell, Python, or JavaScript scripts—this requires:

1. Learning the SDK
2. Writing wrapper code in a supported language
3. Building and deploying a custom worker binary

This overhead is significant for teams that already have scripts/tools they want to orchestrate.

## Use Cases

1. **DevOps Automation**: Run existing deployment scripts, infrastructure provisioning, health checks
2. **Data Pipelines**: Execute ETL scripts (Python/Bash) without building custom workers
3. **CI/CD Integration**: Trigger builds, tests, notifications via shell commands
4. **Legacy Integration**: Wrap existing CLI tools into workflow tasks
5. **Rapid Prototyping**: Quickly test workflow concepts before building production workers

## Proposed Solution

A **Flovyn Forge** binary that:
- Reads task/workflow definitions from a configuration file
- Registers with Flovyn server as a task worker (or unified worker)
- Polls for tasks matching configured kinds
- Executes shell commands/scripts with task input as environment variables or stdin
- Captures stdout/stderr as task output
- Reports completion/failure back to the server

## Configuration Format

Supports both YAML and TOML formats. Example:

```yaml
# flovyn-forge.yaml
server:
  grpc_address: "localhost:9090"
  org_id: "550e8400-e29b-41d4-a716-446655440000"
  worker_token: "${WORKER_TOKEN}"  # env var substitution

worker:
  name: "flovyn-forge"
  version: "1.0.0"
  queue: "default"
  heartbeat_interval_seconds: 30

tasks:
  - kind: "send-slack-notification"
    command: "/scripts/send-slack.sh"
    input_format: "env"  # or "json_stdin", "args"
    timeout_seconds: 30
    env:
      SLACK_WEBHOOK_URL: "${SLACK_WEBHOOK}"

  - kind: "run-backup"
    command: "python3"
    args: ["/scripts/backup.py"]
    input_format: "json_stdin"
    timeout_seconds: 3600
    working_directory: "/data"

  - kind: "health-check"
    command: "curl -sf ${INPUT_URL}"
    shell: true  # interpret as shell command
    timeout_seconds: 10
```

## Input/Output Handling

### Input Formats

| Format | Description | Use Case |
|--------|-------------|----------|
| `env` | JSON input fields become `INPUT_<key>=<value>` env vars | Simple scripts expecting env vars |
| `json_stdin` | Raw JSON input passed to stdin | Scripts that parse JSON input |
| `json_file` | JSON written to temp file, path in `INPUT_FILE` env var | Scripts that read from files |
| `args` | JSON fields become positional arguments | CLI tools with positional args |

### Output Handling

| Mode | Description |
|------|-------------|
| `stdout` | Capture stdout as output (default) |
| `json_stdout` | Parse stdout as JSON for structured output |
| `file` | Read output from file specified in config |
| `exit_code_only` | Only report success/failure based on exit code |

### Exit Code Mapping

```yaml
exit_codes:
  success: [0]           # task completed successfully
  retry: [75, 111]       # transient error, retry the task
  failure: [1-255]       # permanent failure (default for non-success codes)
```

## Architecture

A standalone Rust binary that:
- Reads configuration file (YAML)
- Connects to gRPC server using `flovyn-sdk`
- Manages process pool for executing scripts
- Produces a single static binary with no runtime dependencies

**Deployment options:**
- Run directly on host
- Run as Docker container with scripts mounted as volumes
- Run as sidecar in Kubernetes

## Implementation Approach

The Flovyn Forge extends the existing `flovyn-sdk` by implementing `DynamicTask` for shell execution.

The SDK provides the `DynamicTask` trait:

```rust
#[async_trait]
pub trait DynamicTask {
    fn kind(&self) -> &str;
    async fn execute(
        &self,
        input: Map<String, Value>,
        ctx: &dyn TaskContext,
    ) -> Result<Map<String, Value>>;
}
```

Flovyn Forge implements this as a generic executor:

```rust
pub struct ForgeTask {
    kind: String,
    command: String,
    args: Vec<String>,
    input_format: InputFormat,
    // ... other config
}

#[async_trait]
impl DynamicTask for ForgeTask {
    fn kind(&self) -> &str {
        &self.kind
    }

    async fn execute(
        &self,
        input: Map<String, Value>,
        ctx: &dyn TaskContext,
    ) -> Result<Map<String, Value>> {
        // 1. Convert input to env vars / stdin based on input_format
        // 2. Spawn process with Command::new()
        // 3. Capture stdout/stderr
        // 4. Convert output to JSON based on output_format
        // 5. Return result or error based on exit code
    }
}
```

Usage pattern (similar to integration tests):

```rust
let config = ForgeConfig::from_file("flovyn-forge.yaml")?;

let mut builder = FlovynClient::builder()
    .server_address(&config.server.grpc_address)
    .org_id(config.server.org_id)
    .worker_id(&config.worker.name)
    .worker_token(&config.server.worker_token)
    .queue(&config.worker.queue);

// Register each task from config as a DynamicTask
for task_config in config.tasks {
    builder = builder.register_task(ForgeTask::from_config(task_config));
}

let client = builder.build().await?;
let handle = client.start().await?;
handle.await_ready().await;

// Worker now polls and executes tasks automatically
handle.join().await?;
```

This approach reuses all SDK machinery (registration, polling, heartbeats, reconnection) and maintains consistency with other SDK-based workers.

## Script-to-Worker Communication

Scripts run as subprocesses and cannot directly call SDK methods. The Flovyn Forge needs to provide mechanisms for scripts to interact with `TaskContext` features.

### Available Context Features

From `TaskContext`, scripts may want to:
- **Log messages** - Send structured logs (info, warn, error)
- **Report progress** - Update progress percentage and details
- **Get/Set state** - Persist data between retries
- **Send heartbeat** - Keep task alive during long operations

### Option A: Stdout Command Protocol (Recommended)

Scripts emit special-formatted lines to stdout that the worker intercepts and processes. Similar to GitHub Actions workflow commands.

```bash
#!/bin/bash
# Log messages
echo "::log level=info::Starting backup process"
echo "::log level=error::Connection failed"

# Report progress
echo "::progress percent=25::Downloading files"
echo "::progress percent=50::Processing data"

# Set state (persisted between retries)
echo "::set-state key=last_checkpoint::file_042.csv"
echo "::set-state key=processed_count::1542"

# Get state (via environment variable set by worker)
echo "Last checkpoint was: $STATE_LAST_CHECKPOINT"

# Heartbeat (for long operations)
echo "::heartbeat::"

# Set output (structured output fields)
echo "::set-output key=records_processed::1542"
echo "::set-output key=status::success"
```

**Pros**: No dependencies, works with any scripting language, simple to implement
**Cons**: Mixes with regular stdout (need to filter), limited to text-based communication

### Option B: Unix Socket / HTTP API

Worker spawns a local HTTP server or Unix socket, script communicates via curl or socket writes.

```bash
#!/bin/bash
# Worker sets FLOVYN_API_SOCKET=/tmp/flovyn-task-xxx.sock

# Log message
curl --unix-socket $FLOVYN_API_SOCKET \
  -X POST http://localhost/log \
  -d '{"level": "info", "message": "Starting backup"}'

# Report progress
curl --unix-socket $FLOVYN_API_SOCKET \
  -X POST http://localhost/progress \
  -d '{"percent": 50, "details": "Processing..."}'

# Get state
CHECKPOINT=$(curl --unix-socket $FLOVYN_API_SOCKET \
  http://localhost/state/last_checkpoint)

# Set state
curl --unix-socket $FLOVYN_API_SOCKET \
  -X PUT http://localhost/state/last_checkpoint \
  -d '"file_042.csv"'
```

**Pros**: Clean separation, supports binary data, bidirectional communication
**Cons**: Requires curl/socket client, more complex implementation

### Option C: Environment + Files

Worker provides paths via environment variables for script to write commands.

```bash
#!/bin/bash
# Worker sets:
# FLOVYN_LOG_FILE=/tmp/flovyn-task-xxx/log
# FLOVYN_PROGRESS_FILE=/tmp/flovyn-task-xxx/progress
# FLOVYN_STATE_DIR=/tmp/flovyn-task-xxx/state/

# Log message
echo '{"level": "info", "message": "Starting"}' >> $FLOVYN_LOG_FILE

# Report progress
echo '{"percent": 50, "details": "Processing"}' > $FLOVYN_PROGRESS_FILE

# Get/Set state
cat $FLOVYN_STATE_DIR/last_checkpoint
echo "file_042.csv" > $FLOVYN_STATE_DIR/last_checkpoint
```

**Pros**: Simple file I/O, works everywhere
**Cons**: Polling overhead, no immediate feedback

### Recommendation

**Phase 1 (MVP)**: Start with stdout command protocol - simplest to implement and use.

**Phase 2 (Deferred)**: Add Unix socket API for scripts that need bidirectional communication or binary data.

### Context Information via Environment

Regardless of communication method, worker should expose context info as environment variables:

```bash
# Task metadata
FLOVYN_TASK_ID=550e8400-e29b-41d4-a716-446655440000
FLOVYN_TASK_KIND=run-backup
FLOVYN_EXECUTION_COUNT=1        # Current attempt number
FLOVYN_MAX_RETRIES=3

# Workflow context (if task is part of workflow)
FLOVYN_WORKFLOW_ID=...
FLOVYN_WORKFLOW_KIND=...

# Tracing
FLOVYN_TRACEPARENT=00-abc123-def456-01

# State from previous attempts (pre-loaded)
STATE_LAST_CHECKPOINT=file_041.csv
STATE_PROCESSED_COUNT=1000
```

## Security Considerations

### Sandboxing

The Flovyn Forge should support optional sandboxing:

```yaml
security:
  sandbox: "docker"  # or "nsjail", "bubblewrap", "none"
  allowed_paths:
    - "/scripts"
    - "/data"
  network: false  # disable network access
  max_memory_mb: 512
  max_cpu_percent: 50
```

### Secret Management

- Support environment variable substitution from external sources
- Integration with secret managers (Vault, AWS Secrets Manager)
- Never log sensitive input/output fields marked as secret

```yaml
secrets:
  provider: "vault"
  config:
    address: "https://vault.example.com"
    path: "secret/flovyn-forge"
```

### Input Validation

- Sanitize inputs before passing to shell (prevent injection)
- Validate JSON schema before execution
- Size limits on input/output

## Error Handling

### Timeout Management

```yaml
tasks:
  - kind: "long-running-task"
    timeout_seconds: 3600
    timeout_action: "kill"  # or "signal" (sends SIGTERM first)
    grace_period_seconds: 30  # time between SIGTERM and SIGKILL
```

### Retry Configuration

Leverage server-side retry logic:
```yaml
tasks:
  - kind: "flaky-api-call"
    max_retries: 3  # registered with task capability
```

### Logging

```yaml
logging:
  level: "info"
  capture_stderr: true  # include stderr in task logs
  max_output_size_kb: 1024  # truncate large outputs
```

## Implementation Phases

### Phase 1: MVP
- [ ] Configuration parsing (YAML)
- [ ] Worker registration with task capabilities
- [ ] Polling for tasks
- [ ] Basic command execution (`env` input format, `stdout` output)
- [ ] Completion/failure reporting
- [ ] Heartbeat management

### Phase 2: Enhanced I/O
- [ ] Additional input formats (`json_stdin`, `json_file`, `args`)
- [ ] JSON output parsing
- [ ] Exit code mapping
- [ ] Timeout handling with graceful shutdown

### Phase 3: Production Features
- [ ] Docker/container sandboxing
- [ ] Secret management integration
- [ ] Metrics and observability
- [ ] Health endpoint for container orchestration
- [ ] Configuration hot-reload

### Phase 4: Advanced
- [ ] Workflow worker support (not just tasks)
- [ ] Script dependency management
- [ ] Remote script fetching (git, S3)
- [ ] Web UI for configuration

## Open Questions

1. **Config location**: Single file vs directory of task definitions?
   ```
   /etc/flovyn-forge/
   ├── config.yaml         # base config
   └── tasks/
       ├── send-slack.yaml
       └── run-backup.yaml
   ```

2. **Hot reload**: Should configuration changes require restart or be detected automatically?

3. **Workflow support**: Should Flovyn Forge support workflow definitions (orchestrating multiple steps), or only atomic tasks?

4. **State management**: How to handle stateful tasks that need to persist data between retries?

5. **Streaming output**: Should we support real-time output streaming for long-running tasks?

## Alternatives Considered

### 1. Generic HTTP Webhook Worker
Instead of shell, call HTTP endpoints.
- **Rejected**: Different use case; doesn't solve the script orchestration problem

### 2. Container-per-Task Model
Spin up a new container for each task execution.
- **Considered for Phase 3**: Good for isolation but adds latency

### 3. Function-as-a-Service Integration
Integrate with Lambda/Cloud Functions.
- **Out of scope**: Different deployment model entirely

## Related Work

- **Temporal**: No built-in script runner. Must write custom Activity in SDK (Go/Python/Java/TypeScript) using subprocess to execute scripts. Every shell task requires SDK wrapper code.
- **Argo Workflows**: Container-based execution. Each step runs in a container, scripts must be containerized.
- **Airflow BashOperator**: Python-based operator that runs bash commands. Requires Airflow runtime (heavy). See [BashOperator docs](https://airflow.apache.org/docs/apache-airflow/stable/howto/operator/bash.html).
- **Rundeck**: Full job scheduler with built-in script execution. More complex, designed for operations teams.

## Testing Strategy

Since the Flovyn Forge is an **independent project**, it needs its own test infrastructure while still being able to test against the Flovyn server.

### Unit Tests (No Server Required)

These test internal logic without network dependencies:

1. **Config parsing**: YAML/TOML parsing, environment variable substitution, validation
2. **Input conversion**: JSON → env vars, stdin, args transformation
3. **Output parsing**: stdout → JSON, exit code mapping
4. **Process management**: Timeout handling, signal propagation (mocked processes)

```rust
#[test]
fn test_input_to_env_vars() {
    let input = json!({"name": "Alice", "count": 42});
    let env = convert_to_env_vars(&input, "INPUT_");
    assert_eq!(env.get("INPUT_NAME"), Some(&"Alice".to_string()));
    assert_eq!(env.get("INPUT_COUNT"), Some(&"42".to_string()));
}

#[test]
fn test_exit_code_mapping() {
    let config = ExitCodeConfig {
        success: vec![0],
        retry: vec![75, 111],
    };
    assert_eq!(config.classify(0), ExitResult::Success);
    assert_eq!(config.classify(75), ExitResult::Retry);
    assert_eq!(config.classify(1), ExitResult::Failure);
}
```

### Integration Tests (Requires Running Server)

Two options for integration testing:

#### Option A: Docker Compose Test Environment

```yaml
# docker-compose.test.yml
services:
  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: flovyn
      POSTGRES_PASSWORD: flovyn
      POSTGRES_DB: flovyn

  flovyn-server:
    image: flovyn/flovyn-server:latest
    depends_on: [postgres]
    environment:
      DATABASE_URL: postgres://flovyn:flovyn@postgres/flovyn
    ports:
      - "8000:8000"
      - "9090:9090"
```

```rust
// tests/integration/mod.rs
#[tokio::test]
async fn test_shell_task_execution() {
    // Assumes docker-compose up -d was run
    let config = ShellWorkerConfig::from_str(r#"
        server:
          grpc_address: "localhost:9090"
          org_id: "..."
        tasks:
          - kind: "echo-task"
            command: "echo"
            args: ["hello"]
    "#).unwrap();

    let worker = ShellWorker::new(config);
    let handle = worker.start().await.unwrap();

    // Create task via REST API
    let client = reqwest::Client::new();
    let task = client.post("http://localhost:8000/api/orgs/test/tasks")
        .json(&json!({"kind": "echo-task", "input": {}, "queue": "default"}))
        .send().await.unwrap();

    // Poll until complete...
}
```

#### Option B: Testcontainers (Self-Contained)

Build a test harness similar to flovyn-server's but for the flovyn-forge project:

```rust
// tests/harness.rs
pub struct TestHarness {
    postgres: ContainerAsync<GenericImage>,
    server: ContainerAsync<GenericImage>,  // Run flovyn-server as container
    pub grpc_port: u16,
    pub http_port: u16,
}

impl TestHarness {
    pub async fn new() -> Self {
        let postgres = /* start postgres container */;
        let server = GenericImage::new("flovyn/flovyn-server", "latest")
            .with_env_var("DATABASE_URL", /* ... */)
            .start().await.unwrap();
        // ...
    }
}
```

### Test Scripts

Create test scripts in `tests/scripts/`:

```bash
# scripts/echo-json.sh - Echoes input as JSON output
#!/bin/bash
echo "{\"received\": \"$INPUT_VALUE\", \"timestamp\": $(date +%s)}"

# scripts/failing.sh - Always fails for retry testing
#!/bin/bash
exit 1

# scripts/retry-exit.sh - Returns retry exit code
#!/bin/bash
exit 75

# scripts/slow.sh - Tests timeout handling
#!/bin/bash
sleep 300
echo "done"
```

### Test Categories

| Category | Tests |
|----------|-------|
| Basic execution | Echo task, environment variable passing |
| Input formats | `env`, `json_stdin`, `json_file`, `args` |
| Output formats | `stdout`, `json_stdout`, `exit_code_only` |
| Exit codes | Success (0), retry (75), failure (1) |
| Timeouts | Process killed after timeout, graceful shutdown |
| Retries | Server-side retry on failure/retry exit codes |
| Error handling | Missing command, permission denied, crash |
| State management | Persist state between retry attempts |
| Concurrency | Multiple tasks executing in parallel |

### CI/CD Testing

```yaml
# .github/workflows/test.yml
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo test --lib

  integration-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:18-alpine
        env:
          POSTGRES_USER: flovyn
          POSTGRES_PASSWORD: flovyn
    steps:
      - uses: actions/checkout@v4
      - name: Start Flovyn Server
        run: |
          docker run -d --network host \
            -e DATABASE_URL=postgres://flovyn:flovyn@localhost/flovyn \
            flovyn/flovyn-server:latest
      - run: cargo test --test integration
```

## Project Structure

The Flovyn Forge is an **independent repository**, consuming `flovyn-sdk` as a crate dependency:

```
flovyn-forge/                 # Separate repository
├── src/
│   ├── main.rs
│   ├── config.rs              # YAML/TOML parsing
│   ├── executor.rs            # Process spawning
│   └── task.rs                # DynamicTask implementation
├── tests/
│   ├── unit/                  # Unit tests (no server needed)
│   └── integration/           # Integration tests (needs running server)
├── examples/
│   └── configs/               # Example configuration files
├── Cargo.toml
├── Dockerfile
└── README.md
```

**Cargo.toml dependencies:**

```toml
[dependencies]
flovyn-sdk = { git = "https://github.com/flovyn/flovyn-server", package = "flovyn-sdk" }
# or from crates.io once published:
# flovyn-sdk = "0.1"

tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_yaml = "0.9"
toml = "0.8"
clap = { version = "4", features = ["derive"] }
tracing = "0.1"
```

## Next Steps

1. **Publish `flovyn-sdk`**: Ensure the Rust SDK is available via crates.io or as a git dependency
2. **Create `flovyn-forge` repository**: Initialize independent project
3. **Create design document**: Detailed configuration schema, CLI interface
4. **Implement MVP**:
   - Config parsing (YAML)
   - `ForgeTask` implementing `DynamicTask`
   - Basic process execution with `env` input format
5. **Add unit tests**: Config parsing, I/O conversion
6. **Set up integration test infrastructure**: Docker Compose or testcontainers
7. **Iterate on features**: Additional I/O formats, timeouts, exit code mapping
8. **Documentation**: README, configuration examples, Docker usage
