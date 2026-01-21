# Support Tokio Console Subscriber in Development

## Problem

The flovyn-server often consumes ~50% CPU during operation. To understand and optimize this, we need visibility into:
- Which async tasks are running and for how long
- Task scheduling and wake patterns
- Potential blocking operations on the async runtime
- Resource contention between tasks

## Solution: tokio-console

[tokio-console](https://github.com/tokio-rs/console) is a debugger for async Rust applications. It provides a terminal UI to inspect:
- **Tasks**: All spawned tasks, their state (idle/running/scheduled), poll times
- **Resources**: Sync primitives, I/O resources, and their wakers
- **Async operations**: Where tasks are spending time

This requires the `console-subscriber` crate on the server side and the `tokio-console` CLI tool to view the data.

## Requirements

### 1. tokio_unstable Build Flag (Critical)

Tokio requires the `tokio_unstable` cfg flag at compile time to enable instrumentation. Without this, tokio-console shows an empty screen.

Create `.cargo/config.toml`:
```toml
[build]
rustflags = ["--cfg", "tokio_unstable"]
```

### 2. Tokio Feature Flag

Tokio must be compiled with the `tracing` feature to emit instrumentation data:

```toml
# Cargo.toml (workspace)
tokio = { version = "1.42", features = ["full", "tracing"] }
```

### 3. Console Subscriber Dependency

Add `console-subscriber` as an optional dependency:

```toml
# server/Cargo.toml
[dependencies]
console-subscriber = { version = "0.5", optional = true }

[features]
tokio-console = ["console-subscriber", "tokio/tracing"]
```

### 4. Conditional Initialization

The console subscriber must be initialized **before** any other tracing subscriber because it needs to be the first layer. This conflicts with our current telemetry setup which initializes `tracing-subscriber`.

**Option A: Replace tracing setup entirely (simple, development only)**
```rust
#[cfg(feature = "tokio-console")]
{
    console_subscriber::init();
    // Skip normal telemetry init
}
#[cfg(not(feature = "tokio-console"))]
{
    telemetry::init_telemetry(&telemetry_config)?;
}
```

**Option B: Layer composition (preserves logging)**
```rust
#[cfg(feature = "tokio-console")]
{
    use tracing_subscriber::prelude::*;
    let console_layer = console_subscriber::spawn();
    tracing_subscriber::registry()
        .with(console_layer)
        .with(tracing_subscriber::fmt::layer())
        .with(EnvFilter::from_default_env())
        .init();
}
```

**Recommendation**: Option A for simplicity. When debugging with tokio-console, you typically don't need full logging output.

## Implementation

### Changes to `flovyn-server/server/Cargo.toml`

```toml
[dependencies]
console-subscriber = { version = "0.5", optional = true }

[features]
tokio-console = ["console-subscriber", "tokio/tracing"]
```

### Changes to `flovyn-server/server/src/main.rs`

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let config = ServerConfig::from_env()?;
    config.validate()?;

    // Initialize telemetry (or console subscriber in dev)
    #[cfg(feature = "tokio-console")]
    {
        console_subscriber::init();
        eprintln!("tokio-console enabled - connect with `tokio-console`");
    }
    #[cfg(not(feature = "tokio-console"))]
    {
        let telemetry_config = telemetry::TelemetryConfig { ... };
        telemetry::init_telemetry(&telemetry_config)?;
    }

    // ... rest of main
}
```

### Changes to workspace `Cargo.toml`

```toml
tokio = { version = "1.42", features = ["full"] }  # No change needed here
# The "tracing" feature is added via server's feature flag
```

## Usage

### Running the server with tokio-console

```bash
# Build with tokio-console support
cargo build --features tokio-console

# Run the server
./dev.sh run  # or cargo run --features tokio-console

# In another terminal, connect with tokio-console
tokio-console
```

### Installing tokio-console CLI

```bash
cargo install tokio-console
```

### What to Look For

1. **High poll times**: Tasks taking >1ms per poll may be doing blocking work
2. **Many wakes**: Excessive waking patterns indicate busy-waiting
3. **Idle vs scheduled ratio**: Tasks that are scheduled but rarely run indicate contention
4. **Task counts**: Unexpectedly high task counts may indicate spawn leaks

## Trade-offs

| Aspect | With `tokio-console` | Without |
|--------|---------------------|---------|
| Build time | Slightly longer (extra dep) | Normal |
| Runtime overhead | ~5-10% (instrumentation) | None |
| Binary size | Larger | Normal |
| Observability | Full async runtime visibility | None |

## Out of Scope

- Production usage (this is a development/debugging tool only)
- Automated performance analysis
- Integration with existing OTEL tracing

## References

- [tokio-console GitHub](https://github.com/tokio-rs/console)
- [console-subscriber crate](https://crates.io/crates/console-subscriber)
- [Tokio blog: Announcing Tokio Console](https://tokio.rs/blog/2021-12-announcing-tokio-console)
