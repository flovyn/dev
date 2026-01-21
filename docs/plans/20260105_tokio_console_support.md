# Implementation Plan: Tokio Console Support

**Design document**: [20260104_support-console-subcriber-in-development.md](../design/20260104_support_console_subcriber_in_development.md)

## Overview

Add optional tokio-console support behind a feature flag for debugging async runtime behavior during development.

## TODO

### Phase 1: Dependencies and Feature Flag

- [x] Add `console-subscriber` optional dependency to `flovyn-server/server/Cargo.toml`
- [x] Add `tokio-console` feature flag that enables `console-subscriber` and `tokio/tracing`
- [x] Add `.cargo/config.toml` with `tokio_unstable` rustflag (required for instrumentation)
- [x] Verify the feature compiles: `cargo check -p flovyn-server --features tokio-console`

### Phase 2: Conditional Initialization

- [x] Modify `flovyn-server/server/src/main.rs` to conditionally initialize console subscriber
- [x] Use `#[cfg(feature = "tokio-console")]` to replace telemetry init when feature is enabled
- [x] Add startup message indicating tokio-console is enabled

### Phase 3: Developer Scripts

- [x] Add `flovyn-server/bin/dev/run-with-console.sh` script for easy tokio-console debugging
- [x] Update `CLAUDE.md` with tokio-console usage instructions

### Phase 4: Verification

- [x] Build server with feature: `cargo build --features tokio-console`
- [ ] Run server and connect with `tokio-console` CLI (manual verification)
- [ ] Verify tasks are visible in the console UI (manual verification)
- [x] Verify normal build (without feature) still works

## Implementation Details

### `.cargo/config.toml` (Critical)

```toml
[build]
rustflags = ["--cfg", "tokio_unstable"]
```

This enables tokio's unstable instrumentation APIs required by console-subscriber.

### `flovyn-server/server/Cargo.toml` changes

```toml
[dependencies]
console-subscriber = { version = "0.5", optional = true }

[features]
tokio-console = ["console-subscriber", "tokio/tracing"]
```

### `flovyn-server/server/src/main.rs` changes

Insert after config validation, before current telemetry init:

```rust
// Initialize telemetry (or console subscriber for debugging)
#[cfg(feature = "tokio-console")]
{
    console_subscriber::init();
    eprintln!("tokio-console enabled on port 6669 - connect with `tokio-console`");
}

#[cfg(not(feature = "tokio-console"))]
{
    let telemetry_config = telemetry::TelemetryConfig {
        enabled: config.otel.enabled,
        otlp_endpoint: config.otel.otlp_endpoint.clone(),
        service_name: config.otel.service_name.clone(),
    };
    telemetry::init_telemetry(&telemetry_config)?;
}
```

### `flovyn-server/bin/dev/run-with-console.sh`

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/../.."

echo "Building with tokio-console support..."
cargo build --features tokio-console

echo "Starting server with tokio-console enabled..."
echo "Connect with: tokio-console"
echo ""

source .env 2>/dev/null || true
export DATABASE_URL="${DATABASE_URL:-postgres://flovyn:flovyn@localhost:5432/flovyn}"

./target/debug/flovyn-server
```

## Notes

- The `tokio/tracing` feature is required for console-subscriber to receive instrumentation data
- Console subscriber listens on port 6669 by default
- This feature should NOT be enabled in production builds due to overhead
