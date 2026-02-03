# Flovyn Forge Implementation Plan

**Design Document**: [Flovyn Forge Design](../design/20251229_flovyn_forge.md)
**Research Document**: [Flovyn Forge Research](../research/20251229_flovyn_forge.md)

## Overview

This plan implements Flovyn Forge as an **independent project** that consumes `flovyn-sdk` as a dependency. Each phase delivers a complete, testable feature. After each phase, the binary is functional and can be used for real work.

## Project Setup

Flovyn Forge is a separate repository/crate. For initial development, it can live as a sibling to `flovyn-server`:

```
/Users/manhha/Developer/manhha/flovyn/
├── flovyn-server/
├── sdk-rust/
└── flovyn-forge/       # New project
```

## Current State

- **Existing**: `flovyn-sdk` with `DynamicTask` trait, `TaskContext`, `FlovynClient` builder
- **Existing**: `FlovynClient::builder().register_task()` pattern
- **Missing**: Flovyn Forge binary and all its components

## Guiding Principles

1. **Test-first**: Write tests before implementing each feature
2. **Unit tests first**: Each module has unit tests (no server required)
3. **Integration tests with testcontainers**: Use flovyn-server Docker image
4. **Incremental delivery**: Each phase produces a working binary

---

## Phase 1: Project Setup and CLI Skeleton ✅ COMPLETED

**Goal**: Create the flovyn-forge project with CLI argument parsing and config loading.

### TODO

- [x] **1.1** Initialize flovyn-forge crate
  - Created `flovyn-forge/` directory
  - Created `Cargo.toml` with dependencies

- [x] **1.2** Create CLI entrypoint (`flovyn-server/src/main.rs`)
  - `Args` struct with clap derive
  - All CLI arguments implemented

- [x] **1.3** Create config module (`flovyn-server/src/config/mod.rs`)
  - Exports all config types

- [x] **1.4** Create config schema (`flovyn-server/src/config/schema.rs`)
  - All structs defined with serde derive

- [x] **1.5** Create config parser (`flovyn-server/src/config/parser.rs`)
  - YAML parsing with `${VAR}` and `${VAR:-default}` substitution

- [x] **1.6** Create config validation (`flovyn-server/src/config/validation.rs`)
  - Validates all required fields and constraints

- [x] **1.7** Unit tests for config module
  - 30+ tests for parsing and validation

- [x] **1.8** Implement `--validate` flag
  - Loads, validates, and displays config summary

**Completed**: Can load and validate configuration files.

---

## Phase 2: Basic Process Execution ✅ COMPLETED

**Goal**: Execute commands without SDK integration. Test process spawning logic.

### TODO

- [x] **2.1** Create executor module (`flovyn-server/src/executor/mod.rs`)
- [x] **2.2** Create process executor (`flovyn-server/src/executor/process.rs`)
- [x] **2.3** Implement input format: `env`
- [x] **2.4** Implement output format: `stdout`
- [x] **2.5** Unit tests for process executor (8+ tests)

**Completed**: Can execute scripts with input and capture output.

---

## Phase 3: Timeout and Signal Handling ✅ COMPLETED

**Goal**: Implement timeout management with graceful shutdown.

### TODO

- [x] **3.1** Create timeout handler (`flovyn-server/src/executor/timeout.rs`)
- [x] **3.2** Implement graceful shutdown (SIGTERM -> grace period -> SIGKILL)
- [x] **3.3** Add `nix` dependency for Unix signals
- [x] **3.4** Unit tests for timeout handling (3 tests)

**Completed**: Scripts are properly killed on timeout.

---

## Phase 4: Exit Code Classification ✅ COMPLETED

**Goal**: Map exit codes to success/retry/failure outcomes.

### TODO

- [x] **4.1** Create exit code types (`flovyn-server/src/executor/exit_codes.rs`)
- [x] **4.2** Integrate exit code classification into `ProcessExecutor`
- [x] **4.3** Unit tests for exit code classification (6 tests)

**Completed**: Exit codes properly classified for SDK retry logic.

---

## Phase 5: Stdout Command Protocol ✅ COMPLETED

**Goal**: Parse `::command params::message` lines from stdout.

### TODO

- [x] **5.1** Create protocol parser (`flovyn-server/src/executor/protocol.rs`)
- [x] **5.2** Implement stdout line parsing
- [x] **5.3** Create protocol handler
- [x] **5.4** Unit tests for protocol parsing (15+ tests)

**Completed**: Scripts can communicate structured data via stdout.

---

## Phase 6: ForgeTask Implementation ✅ COMPLETED

**Goal**: Implement `DynamicTask` trait for SDK integration.

### TODO

- [x] **6.1** Create ForgeTask (`flovyn-server/src/task.rs`)
- [x] **6.2** Wire ProcessExecutor to TaskContext
- [x] **6.3** Provide context environment variables to script
- [x] **6.5** Implement `retry_config()` from `TaskConfig.max_retries`
- [x] **6.6** Implement `timeout_seconds()` from `TaskConfig.timeout_seconds`
- [x] **6.7** Unit tests for ForgeTask (6 tests)

**Note**: State from previous attempts (6.4) deferred - requires SDK enhancement.

**Completed**: ForgeTask can be registered with SDK.

---

## Phase 7: Main Worker Loop ✅ COMPLETED

**Goal**: Connect to server and run as a worker.

### TODO

- [x] **7.1** Implement main run loop (`flovyn-server/src/main.rs`)
- [x] **7.2** Handle CLI argument overrides
- [x] **7.3** Configure logging based on config
- [x] **7.4** Add graceful shutdown on SIGTERM/SIGINT

**Completed**: Full working worker that executes shell tasks.

---

## Phase 8: Integration Tests (IN PROGRESS)

**Goal**: Automated integration tests using testcontainers.

**Status**: Test harness and fixtures created. Tests blocked waiting for updated Docker image with task-executions endpoint.

### TODO

- [x] **8.1** Create test harness (`flovyn-server/tests/integration/harness.rs`)
  - Start PostgreSQL container (testcontainers)
  - Start flovyn-server container (from Docker image)
  - Start flovyn-forge as worker process
  - Provide gRPC and HTTP endpoints

- [x] **8.2** Create test fixtures (`tests/scripts/`)
  - `echo-env.sh` - Tests environment variable input
  - `exit-code.sh` - Tests exit code handling
  - `slow.sh` - Tests timeout handling
  - `protocol-demo.sh` - Tests stdout protocol commands

- [~] **8.3** Integration test: basic execution (BLOCKED - needs updated Docker image)
  - `test_basic_echo_task`
  - Tests written but fail due to missing `/api/tenants/{slug}/task-executions` endpoint in Docker image

- [~] **8.4** Integration test: input formats (BLOCKED)
  - Tests exist but blocked on Docker image

- [~] **8.5** Integration test: exit codes (BLOCKED)
  - `test_exit_code_success`
  - `test_exit_code_failure`
  - `test_exit_code_retry`

- [~] **8.6** Integration test: timeout (BLOCKED)
  - `test_task_timeout`

- [~] **8.7** Integration test: protocol commands (BLOCKED)
  - `test_protocol_commands`

- [ ] **8.8** Add CI workflow (`.github/workflows/test.yml`)
  - Run unit tests
  - Run integration tests with Docker

**Usable after Phase 8**: Automated test coverage for all features.

---

## Phase 9: Additional Input/Output Formats ✅ COMPLETED

**Goal**: Support all input/output formats from design.

### TODO

- [x] **9.1** Implement input format: `json_stdin`
  - Write JSON input to process stdin
  - Close stdin after writing

- [x] **9.2** Implement input format: `json_file`
  - Write JSON to temp file
  - Set `INPUT_FILE` environment variable
  - Clean up temp file after execution (handled by tempfile crate)

- [x] **9.3** Implement input format: `args`
  - Convert JSON fields to positional arguments
  - Order by field name alphabetically

- [x] **9.4** Implement output format: `json_stdout`
  - Parse stdout as JSON
  - Merge with `set-output` key-values

- [x] **9.5** Implement output format: `file`
  - Read output from file specified in config
  - Parse as JSON

- [x] **9.6** Implement output format: `exit_code_only`
  - Return `{ "success": true/false }` based on exit code

- [x] **9.7** Unit tests for all formats
  - `test_execute_with_json_stdin`
  - `test_execute_with_json_file_input`
  - `test_execute_with_args_input`
  - `test_execute_json_stdout`
  - Output file format tested via json_stdout

- [~] **9.8** Integration tests for formats (blocked on Docker image)

**Completed**: 69 unit tests pass. All I/O formats implemented and tested.

---

## Phase 10: Shell Mode and Security ✅ COMPLETED

**Goal**: Support `shell: true` with input sanitization.

### TODO

- [x] **10.1** Implement shell execution mode
  - When `shell: true`, run command via `/bin/sh -c`
  - Concatenate command and args into shell string
  - Shell-escape args to prevent injection

- [x] **10.2** Add `shell-escape` dependency
  ```toml
  shell-escape = "0.1"
  ```

- [x] **10.3** Implement input sanitization for shell mode
  - Created `flovyn-server/src/executor/security.rs` module
  - `shell_escape()` for escaping shell metacharacters
  - Escape arguments when building shell commands

- [x] **10.4** Add output size limits
  - Truncate stdout/stderr beyond `logging.max_output_size_kb`
  - Default: 1024 KB (1 MB)
  - `truncate_output()` finds good break points (newline/space)

- [x] **10.5** Implement secret redaction in logs
  - `is_secret_env_var()` detects patterns: `*_KEY`, `*_SECRET`, `*_TOKEN`, `*_PASSWORD`, `*_CREDENTIAL`
  - `redact_secrets()` replaces secret values with `[REDACTED]`
  - `collect_secrets_from_env()` gathers secrets from environment
  - Integrated into ProcessExecutor to redact stdout/stderr

- [x] **10.6** Unit tests for security (6 tests in security.rs + 5 in process.rs)
  - `test_shell_escape_special_chars`
  - `test_shell_injection_prevented`
  - `test_output_truncation`
  - `test_secret_redaction_from_output`
  - `test_secret_redaction_from_stderr`
  - `test_non_secret_env_not_redacted`

- [x] **10.7** Wire max_output_size from config to ForgeTask
  - `ForgeTask::with_max_output_size()` constructor
  - `main.rs` passes `logging.max_output_size_kb * 1024` to tasks

**Completed**: 85 unit tests pass. Shell mode with security protections.

---

## Phase 11: Documentation and Polish

**Goal**: Documentation, examples, and production readiness.

### TODO

- [ ] **11.1** Write README.md
  - Quick start guide
  - Configuration reference
  - Example configurations
  - Docker usage

- [ ] **11.2** Create example configurations (`examples/configs/`)
  - `minimal.yaml`: Simplest possible config
  - `full.yaml`: All options demonstrated
  - `docker.yaml`: Docker deployment example
  - `kubernetes.yaml`: K8s deployment example

- [ ] **11.3** Create Dockerfile
  - Multi-stage build
  - Minimal runtime image
  - Example in docs

- [ ] **11.4** Add health check support
  - `--health-check` flag for liveness probes
  - Exit 0 if config valid and can connect to server

- [ ] **11.5** Error messages review
  - Ensure all errors are user-friendly
  - Include suggestions for common issues

- [ ] **11.6** Performance testing
  - Benchmark concurrent task execution
  - Verify no resource leaks

**Usable after Phase 11**: Production-ready binary with documentation.

---

## File Structure

```
flovyn-forge/
├── Cargo.toml
├── README.md
├── Dockerfile
├── src/
│   ├── main.rs                 # CLI entrypoint
│   ├── lib.rs                  # Library exports
│   ├── config/
│   │   ├── mod.rs
│   │   ├── schema.rs           # Config structs
│   │   ├── parser.rs           # YAML parsing, env substitution
│   │   └── validation.rs       # Config validation
│   ├── executor/
│   │   ├── mod.rs
│   │   ├── process.rs          # Process spawning, I/O
│   │   ├── timeout.rs          # Timeout and signal handling
│   │   ├── exit_codes.rs       # Exit code classification
│   │   ├── protocol.rs         # Stdout command parsing
│   │   └── security.rs         # Shell escaping, secret redaction, output truncation
│   └── task.rs                 # ForgeTask implementing DynamicTask
├── tests/
│   ├── unit/                   # Unit tests
│   ├── integration/            # Integration tests with testcontainers
│   │   └── harness.rs
│   └── scripts/                # Test shell scripts
│       ├── echo-env.sh
│       ├── echo-json.sh
│       ├── exit-code.sh
│       ├── slow.sh
│       └── protocol-demo.sh
└── examples/
    └── configs/
        ├── minimal.yaml
        ├── full.yaml
        └── docker.yaml
```

---

## Testing Strategy

| Phase | Test Type | What to Test |
|-------|-----------|--------------|
| 1 | Unit | Config parsing, validation, env substitution |
| 2 | Unit | Process spawning, input/output capture |
| 3 | Unit | Timeout handling, signal propagation |
| 4 | Unit | Exit code classification |
| 5 | Unit | Protocol parsing |
| 6 | Unit | ForgeTask trait implementation |
| 7 | Manual | End-to-end with local server |
| 8 | Integration | Full workflow with testcontainers |
| 9 | Unit + Integration | All I/O formats |
| 10 | Unit | Shell mode, security |
| 11 | Manual | Documentation accuracy |

---

## Dependencies Summary

| Phase | New Dependencies |
|-------|------------------|
| 1 | flovyn-sdk, tokio, serde, serde_yaml, clap, tracing, thiserror |
| 3 | nix (Unix only) |
| 8 | testcontainers (dev) |
| 10 | shell-escape |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| SDK doesn't expose state retrieval | Use task input to pass state, or enhance SDK |
| Cross-platform signal handling | Use `nix` for Unix, stub for Windows initially |
| Testcontainers flakiness | Add retries, increase timeouts, clean up properly |
| Process zombie processes | Ensure proper wait/kill in all code paths |

---

## SDK Enhancement Needed

The current `TaskContext` trait doesn't expose:
1. **State retrieval**: Scripts need to access state from previous attempts
2. **Heartbeat refresh**: The SDK auto-heartbeats, but explicit heartbeat support could be useful

**Options**:
1. Pass state in task input (workaround)
2. Add `get_state()` method to `TaskContext` (SDK change)
3. Use environment variables set during task assignment

For MVP, use option 1: include state in task input from server.
