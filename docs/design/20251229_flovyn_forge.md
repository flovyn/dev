# Flovyn Forge Design Document

## Overview

Flovyn Forge is a configuration-driven task executor that enables running shell scripts, commands, and containers as Flovyn tasks without writing SDK code.

**Background**: See [Research Document](../research/20251229_flovyn_forge.md) for problem statement, use cases, and alternatives considered.

**Key Value Proposition**:
- SDK workers: Write code (Rust, Kotlin)
- Flovyn Forge: Write config (YAML/TOML)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Flovyn Forge                           │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Config       │  │ Task         │  │ Process          │  │
│  │ Parser       │──│ Registry     │──│ Executor         │  │
│  │ (YAML/TOML)  │  │ (ForgeTask)  │  │ (Command/Docker) │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│         │                 │                   │             │
│         └─────────────────┼───────────────────┘             │
│                           │                                 │
│                  ┌────────▼────────┐                        │
│                  │   flovyn-sdk    │                        │
│                  │  (FlovynClient) │                        │
│                  └────────┬────────┘                        │
└───────────────────────────┼─────────────────────────────────┘
                            │ gRPC
                   ┌────────▼────────┐
                   │  Flovyn Server  │
                   └─────────────────┘
```

**Components**:
- **Config Parser**: Loads YAML/TOML, validates schema, substitutes environment variables
- **Task Registry**: Maps task `kind` to execution configuration (`ForgeTask`)
- **Process Executor**: Spawns processes, handles I/O, manages timeouts
- **flovyn-sdk**: Handles registration, polling, heartbeats, completion reporting

## Configuration Schema

### Root Configuration

```yaml
# flovyn-forge.yaml

# Server connection settings
server:
  grpc_address: "localhost:9090"      # Required: Flovyn server gRPC endpoint
  tenant_id: "uuid"                   # Required: Tenant UUID
  worker_token: "${WORKER_TOKEN}"     # Required: Authentication token (env var substitution)

# Worker identity and behavior
worker:
  name: "my-forge-worker"             # Required: Worker name for registration
  version: "1.0.0"                    # Optional: Worker version (default: "0.0.0")
  queue: "default"                    # Optional: Task queue to poll (default: "default")
  concurrency: 4                      # Optional: Max concurrent task executions (default: 1)
  heartbeat_interval_seconds: 30      # Optional: Heartbeat interval (default: 30)

# Logging configuration
logging:
  level: "info"                       # Optional: log level (default: "info")
  format: "json"                      # Optional: "json" or "text" (default: "text")

# Task definitions
tasks:
  - kind: "task-kind-name"
    # ... task configuration (see Task Configuration below)
```

### Task Configuration

```yaml
tasks:
  - kind: "send-notification"         # Required: Task kind (must be unique)

    # Command execution
    command: "/scripts/notify.sh"     # Required: Command or path to script
    args: ["--verbose"]               # Optional: Command arguments
    shell: false                      # Optional: Run via shell (default: false)
    working_directory: "/app"         # Optional: Working directory

    # Input handling
    input_format: "env"               # Optional: How to pass input (default: "env")
                                      # Values: "env", "json_stdin", "json_file", "args"

    # Output handling
    output_format: "stdout"           # Optional: How to capture output (default: "stdout")
                                      # Values: "stdout", "json_stdout", "file", "exit_code_only"
    output_file: "/tmp/output.json"   # Required if output_format: "file"

    # Exit code interpretation
    exit_codes:
      success: [0]                    # Optional: Exit codes meaning success (default: [0])
      retry: [75, 111]                # Optional: Exit codes meaning transient failure

    # Timeouts
    timeout_seconds: 300              # Optional: Max execution time (default: 3600)
    grace_period_seconds: 10          # Optional: Time between SIGTERM and SIGKILL (default: 10)

    # Retry behavior (registered with server)
    max_retries: 3                    # Optional: Max retry attempts (default: 0)

    # Static environment variables
    env:
      API_KEY: "${API_KEY}"           # Supports env var substitution
      ENVIRONMENT: "production"

    # Resource limits (future)
    # limits:
    #   memory_mb: 512
    #   cpu_percent: 50
```

### Environment Variable Substitution

Config values support `${VAR}` syntax for environment variable substitution:

```yaml
server:
  worker_token: "${WORKER_TOKEN}"     # Required - fails if not set
  grpc_address: "${GRPC_ADDR:-localhost:9090}"  # With default value
```

## CLI Interface

```bash
# Run with config file
flovyn-forge --config /etc/flovyn-forge/config.yaml

# Run with config from stdin
cat config.yaml | flovyn-forge --config -

# Override specific settings
flovyn-forge --config config.yaml \
  --server-address localhost:9090 \
  --queue high-priority \
  --concurrency 8

# Validate configuration without running
flovyn-forge --config config.yaml --validate

# Show version
flovyn-forge --version
```

### CLI Arguments

| Argument | Short | Description |
|----------|-------|-------------|
| `--config` | `-c` | Path to config file (required) |
| `--server-address` | `-s` | Override server gRPC address |
| `--tenant-id` | `-t` | Override tenant ID |
| `--queue` | `-q` | Override queue name |
| `--concurrency` | `-n` | Override concurrency |
| `--validate` | | Validate config and exit |
| `--version` | `-V` | Show version |
| `--help` | `-h` | Show help |

## Script Communication Protocol

Scripts communicate with Forge via stdout command protocol. Commands are lines matching `::command params::message`.

### Command Syntax

```
::command key=value key=value::message content
```

### Available Commands

| Command | Parameters | Example |
|---------|------------|---------|
| `log` | `level` (info/warn/error/debug) | `::log level=info::Starting process` |
| `progress` | `percent` (0-100) | `::progress percent=50::Halfway done` |
| `set-state` | `key` | `::set-state key=checkpoint::file_42.csv` |
| `set-output` | `key` | `::set-output key=result::success` |
| `heartbeat` | (none) | `::heartbeat::` |

### Example Script

```bash
#!/bin/bash
set -e

echo "::log level=info::Starting backup"

# Use state from previous attempt (if retrying)
LAST_FILE="${STATE_CHECKPOINT:-}"
if [ -n "$LAST_FILE" ]; then
    echo "::log level=info::Resuming from $LAST_FILE"
fi

for file in /data/*.csv; do
    echo "::progress percent=50::Processing $file"
    echo "::set-state key=checkpoint::$file"

    # Long operation - send heartbeat
    echo "::heartbeat::"
    process_file "$file"
done

echo "::set-output key=files_processed::42"
echo "::log level=info::Backup complete"
```

### Environment Variables Provided to Scripts

```bash
# Task context
FLOVYN_TASK_ID="550e8400-e29b-41d4-a716-446655440000"
FLOVYN_TASK_KIND="run-backup"
FLOVYN_EXECUTION_COUNT="1"
FLOVYN_MAX_RETRIES="3"
FLOVYN_QUEUE="default"

# Workflow context (if part of workflow)
FLOVYN_WORKFLOW_ID="..."
FLOVYN_WORKFLOW_KIND="..."

# Tracing
FLOVYN_TRACEPARENT="00-abc123-def456-01"

# Task input (when input_format: "env")
INPUT_FILENAME="data.csv"
INPUT_BUCKET="my-bucket"

# State from previous attempts
STATE_CHECKPOINT="file_41.csv"
STATE_PROCESSED="100"
```

## Core Components

### Module Structure

```
src/
├── main.rs              # CLI entrypoint, argument parsing
├── config/
│   ├── mod.rs           # Config types and loading
│   ├── schema.rs        # ForgeConfig, TaskConfig structs
│   ├── parser.rs        # YAML/TOML parsing
│   └── validation.rs    # Config validation
├── executor/
│   ├── mod.rs           # Process execution
│   ├── process.rs       # Command spawning, I/O handling
│   ├── timeout.rs       # Timeout and signal handling
│   └── protocol.rs      # Stdout command parsing
├── task.rs              # ForgeTask implementing DynamicTask
└── lib.rs               # Library exports
```

### Key Types

```rust
/// Root configuration
#[derive(Debug, Deserialize)]
pub struct ForgeConfig {
    pub server: ServerConfig,
    pub worker: WorkerConfig,
    #[serde(default)]
    pub logging: LoggingConfig,
    pub tasks: Vec<TaskConfig>,
}

/// Task execution configuration
#[derive(Debug, Deserialize)]
pub struct TaskConfig {
    pub kind: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub shell: bool,
    pub working_directory: Option<PathBuf>,
    #[serde(default)]
    pub input_format: InputFormat,
    #[serde(default)]
    pub output_format: OutputFormat,
    pub output_file: Option<PathBuf>,
    #[serde(default)]
    pub exit_codes: ExitCodeConfig,
    #[serde(default = "default_timeout")]
    pub timeout_seconds: u64,
    #[serde(default = "default_grace_period")]
    pub grace_period_seconds: u64,
    #[serde(default)]
    pub max_retries: u32,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputFormat {
    #[default]
    Env,
    JsonStdin,
    JsonFile,
    Args,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputFormat {
    #[default]
    Stdout,
    JsonStdout,
    File,
    ExitCodeOnly,
}

/// ForgeTask implements DynamicTask for SDK integration
pub struct ForgeTask {
    config: TaskConfig,
}

#[async_trait]
impl DynamicTask for ForgeTask {
    fn kind(&self) -> &str {
        &self.config.kind
    }

    async fn execute(
        &self,
        input: Map<String, Value>,
        ctx: &dyn TaskContext,
    ) -> Result<Map<String, Value>> {
        let executor = ProcessExecutor::new(&self.config, ctx);
        executor.run(input).await
    }
}
```

## Error Handling

### Exit Code Classification

```rust
pub enum ExitResult {
    Success,      // Task completed successfully
    Retry,        // Transient error, should retry
    Failure,      // Permanent failure
}

impl ExitCodeConfig {
    pub fn classify(&self, code: i32) -> ExitResult {
        if self.success.contains(&code) {
            ExitResult::Success
        } else if self.retry.contains(&code) {
            ExitResult::Retry
        } else {
            ExitResult::Failure
        }
    }
}
```

### Timeout Handling

1. When `timeout_seconds` expires:
   - Send `SIGTERM` to process
   - Wait `grace_period_seconds`
   - Send `SIGKILL` if still running
2. Report task as failed with timeout error

### Error Reporting

Errors are reported to the server with structured information:

```rust
pub struct TaskError {
    pub message: String,
    pub error_type: ErrorType,  // Timeout, ExitCode, Crashed, etc.
    pub exit_code: Option<i32>,
    pub stderr: Option<String>, // Last N bytes of stderr
}
```

## Security

### Input Sanitization

When `shell: true`, inputs must be sanitized to prevent injection:

```rust
fn sanitize_for_shell(value: &str) -> String {
    // Escape special characters
    shell_escape::escape(Cow::Borrowed(value)).to_string()
}
```

When `shell: false` (default), arguments are passed directly to `execve`, avoiding shell interpretation.

### Output Size Limits

```yaml
logging:
  max_output_size_kb: 1024  # Truncate stdout/stderr beyond this
```

### Secrets in Config

Sensitive values should use environment variable substitution:

```yaml
env:
  API_KEY: "${API_KEY}"  # Never hardcode secrets
```

Forge will redact environment variables matching common secret patterns in logs.

## Deployment

### Docker

```dockerfile
FROM rust:1.75-slim as builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/flovyn-forge /usr/local/bin/
ENTRYPOINT ["flovyn-forge"]
CMD ["--config", "/etc/flovyn-forge/config.yaml"]
```

```yaml
# docker-compose.yml
services:
  forge:
    image: flovyn/flovyn-forge:latest
    volumes:
      - ./config.yaml:/etc/flovyn-forge/config.yaml:ro
      - ./scripts:/scripts:ro
    environment:
      - WORKER_TOKEN=${WORKER_TOKEN}
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flovyn-forge
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: forge
          image: flovyn/flovyn-forge:latest
          args: ["--config", "/config/forge.yaml", "--concurrency", "4"]
          volumeMounts:
            - name: config
              mountPath: /config
            - name: scripts
              mountPath: /scripts
          env:
            - name: WORKER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: flovyn-secrets
                  key: worker-token
      volumes:
        - name: config
          configMap:
            name: forge-config
        - name: scripts
          configMap:
            name: forge-scripts
```

## Dependencies

```toml
[dependencies]
flovyn-sdk = { git = "https://github.com/flovyn/flovyn-server", package = "flovyn-sdk" }

# Async runtime
tokio = { version = "1", features = ["full", "process"] }

# Config parsing
serde = { version = "1", features = ["derive"] }
serde_yaml = "0.9"
toml = "0.8"

# CLI
clap = { version = "4", features = ["derive", "env"] }

# Logging
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["json", "env-filter"] }

# Utilities
thiserror = "1"
shell-escape = "0.1"
```

## Future Considerations

Items explicitly deferred from MVP:

1. **Unix Socket API** - For bidirectional script communication
2. **Container Sandboxing** - Run scripts in isolated containers
3. **Secret Manager Integration** - Vault, AWS Secrets Manager
4. **Configuration Hot-reload** - Detect config changes without restart
5. **Workflow Support** - DAG orchestration of multiple steps
6. **Remote Script Fetching** - Load scripts from git/S3
7. **Metrics Endpoint** - Prometheus metrics for monitoring
