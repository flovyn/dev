# Implementation Plan: Plugin gRPC Services

**Date:** 2026-01-01
**Design Document:** [Plugin System Design](../design/20251223_plugin_system.md)

## Overview

Add `grpc_services()` method to the Plugin trait, enabling plugins to register gRPC services with the server. This completes the plugin system design which specifies gRPC support but was not implemented in the initial phases.

## Current State

The Plugin trait (`flovyn-server/crates/plugin/src/traits.rs`) has:
- ✅ `rest_routes()` - REST endpoint registration
- ✅ `openapi()` - OpenAPI spec merging
- ✅ `authenticators()` / `authorizers()` - Auth provider registration
- ❌ `grpc_services()` - Not implemented

The design doc specifies gRPC service registration but the implementation was deferred.

## Goal

Enable plugins to register gRPC services following the naming convention:
- Package: `flovyn.plugins.<plugin>.v1`
- Service: `flovyn.plugins.<plugin>.v1.<ServiceName>`

Example: `flovyn.plugins.ai.v1.LlmService`

## Design Considerations

### Option A: Boxed Service Factory (Not Recommended)

```rust
pub type GrpcServiceFactory = Box<dyn FnOnce(GrpcState) -> BoxedGrpcService + Send>;
```

**Cons:** Type erasure complexity, hard to compose with interceptors.

### Option B: Routes-based (Recommended)

Use tonic's `Routes` type which can compose multiple services:

```rust
// crates/plugin/src/grpc.rs
use tonic::service::Routes;

pub struct PluginGrpcRoutes {
    pub routes: Routes,
}

// In Plugin trait:
fn grpc_routes(&self, services: Arc<PluginServices>) -> Option<PluginGrpcRoutes> {
    None
}
```

**Pros:**
- Uses tonic's native composition API
- Services can apply their own interceptors before adding to Routes
- Simple to merge into server's Router

**Cons:**
- Requires tonic dependency in plugin crate
- Plugins must handle their own authentication

### Authentication Strategy

**Current System:** Auth is configured centrally in TOML config:

```toml
[auth.endpoints.http]
authenticators = ["static_api_key", "better_auth_jwt"]
authorizer = "cedar"
exclude_paths = ["/_/health", "/api/docs/*"]  # Paths that skip auth

[auth.endpoints.grpc]
authenticators = ["static_api_key", "better_auth_jwt"]
authorizer = "cedar"
```

**How it works:**
1. All requests go through auth middleware/interceptor
2. `auth_stack.should_skip_auth(path)` checks against `exclude_paths` (supports wildcards)
3. Excluded paths get `Principal::anonymous()` (auth skipped, authz still works)
4. Non-excluded paths must authenticate

**Current Issue:** REST applies auth selectively (only to `authenticated_routes`), not globally:
```rust
// server/src/api/rest/mod.rs - current approach
let authenticated_routes = routes.layer(auth_middleware);  // Only some routes
core_routes.merge(authenticated_routes).merge(plugin_routes)  // Plugins miss auth!
```

**Fix:** Apply auth globally, use `exclude_paths` for exemptions (same pattern for REST & gRPC):

```rust
// REST - global auth layer
Router::new()
    .merge(all_routes)
    .merge(plugin_routes)
    .layer(auth_middleware)  // Applied to ALL, exclude_paths handles exemptions

// gRPC - global auth layer via Server::layer()
Server::builder()
    .layer(GrpcAuthLayer::new(auth_stack))  // Applied to ALL services
    .add_service(CoreService::new(...))
    .add_routes(plugin_routes)
```

**Plugin paths that need to skip auth:** Operator adds to `exclude_paths` in config:
```toml
[auth.endpoints.http]
exclude_paths = [
    "/_/health",
    "/api/docs/*",
    "/api/tenants/*/worker-token/validate",  # Plugin public endpoint
]
```

**Decision:** Server applies auth centrally (config-driven):
- Plugins don't handle auth - server does it
- Operators control auth policy via `exclude_paths`
- Consistent with core routes behavior
- Anonymous principal available for excluded paths (authz still works)

---

## TODO List

### Phase 1: Plugin Trait & Types

- [ ] Add `tonic` dependency to `flovyn-server/crates/plugin/Cargo.toml`
- [ ] Create `flovyn-server/crates/plugin/src/grpc.rs`:
  - Define `PluginGrpcRoutes` struct wrapping `tonic::service::Routes`
  - Add builder/helper methods for route creation
- [ ] Add `grpc_routes()` method to Plugin trait in `flovyn-server/crates/plugin/src/traits.rs`:
  ```rust
  fn grpc_routes(&self, services: Arc<PluginServices>) -> Option<PluginGrpcRoutes> {
      None
  }
  ```
- [ ] Export `PluginGrpcRoutes` and `grpc` module from `flovyn-server/crates/plugin/src/lib.rs`
- [ ] Verify: `cargo check -p flovyn-plugin`

### Phase 2: Apply REST Auth Globally (Refactor)

Current code applies auth selectively to `authenticated_routes` only. Refactor to apply globally - `exclude_paths` handles exemptions:

- [ ] Refactor `create_router()` in `flovyn-server/server/src/api/rest/mod.rs`:
  ```rust
  pub fn create_router(...) -> Router<()> {
      // All API routes (no selective auth layer here)
      let api_routes = Router::new()
          .route("/api/tenants", post(tenants::create_tenant))
          // ... all routes ...

      // Build complete router, apply auth globally at the end
      Router::new()
          .merge(health::routes())           // /_/health, /_/ready
          .route("/_/metrics", get(metrics_handler))
          .merge(SwaggerUi::new("/api/docs").url(...))
          .merge(api_routes)
          .merge(plugin_routes)              // Plugin routes included
          .layer(axum_middleware::from_fn_with_state(
              state.clone(),
              middleware::auth_middleware,   // Applied to ALL routes
          ))
          .with_state(state)
  }
  ```
- [ ] Ensure `exclude_paths` config covers health/docs:
  ```toml
  [auth.endpoints.http]
  exclude_paths = ["/_/health", "/_/ready", "/_/metrics", "/api/docs/*"]
  ```
- [ ] Add integration test: plugin REST routes require auth
- [ ] Verify: `cargo test --test integration_tests`

**Why this is better:**
- Single place for auth (global layer)
- `exclude_paths` in config controls exemptions (operator-configurable)
- Plugin routes automatically get auth
- Matches gRPC approach (`Server::layer()`)

### Phase 2b: Wire Plugin Authenticators into Auth Stack

Complete the plugin authenticator integration (currently dead code):

- [ ] Add `with_plugin_authenticators()` to `AuthStackBuilder`:
  ```rust
  impl AuthStackBuilder {
      /// Register plugin-provided authenticators.
      /// These are referenced by plugin name in config.
      pub fn with_plugin_authenticators(
          mut self,
          authenticators: Vec<(String, Arc<dyn Authenticator>)>,
      ) -> Self {
          self.plugin_authenticators = authenticators.into_iter().collect();
          self
      }
  }
  ```
- [ ] Update `build_authenticator()` to resolve plugin authenticators:
  ```rust
  fn build_authenticator(&self, endpoint_config: &EndpointAuthConfig) -> Arc<dyn Authenticator> {
      for name in &endpoint_config.authenticators {
          match name.as_str() {
              "static_api_key" => { ... }
              "jwt" => { ... }
              // ... built-in authenticators ...
              plugin_name => {
                  // Check plugin authenticators
                  if let Some(auth) = self.plugin_authenticators.get(plugin_name) {
                      authenticators.push(auth.clone());
                  } else {
                      tracing::warn!("Unknown authenticator: {}", plugin_name);
                      skipped.push(format!("unknown: {}", plugin_name));
                  }
              }
          }
      }
  }
  ```
- [ ] Update `main.rs` to wire plugin authenticators:
  ```rust
  // Collect plugin authenticators
  let plugin_authenticators = plugin_registry.collect_authenticators(plugin_services.clone());

  // Build auth stacks with plugin authenticators
  let auth_stacks = AuthStackBuilder::new(config.auth.clone())
      .with_pool(pool.clone())
      .with_plugin_authenticators(plugin_authenticators)
      .build();
  ```
- [ ] Remove manual worker-token wiring (now handled via plugin system)
- [ ] Add integration test: custom plugin authenticator works for gRPC
- [ ] Verify config works:
  ```toml
  [auth.endpoints.grpc]
  authenticators = ["worker-token", "static_api_key"]  # Plugin name in config
  ```

### Phase 3: Plugin Registry Extension

- [ ] Add `collect_grpc_routes()` method to `PluginRegistry`:
  ```rust
  /// Collect gRPC routes from all plugins.
  /// Note: Auth is NOT applied here - server applies it when merging.
  pub fn collect_grpc_routes(&self, services: Arc<PluginServices>) -> Option<Routes> {
      let mut routes: Option<Routes> = None;
      for plugin in &self.plugins {
          if let Some(plugin_routes) = plugin.grpc_routes(services.clone()) {
              info!(plugin = plugin.name(), "Collecting gRPC routes");
              routes = Some(match routes {
                  Some(r) => r.add_routes(plugin_routes.routes),
                  None => plugin_routes.routes,
              });
          }
      }
      routes
  }
  ```
- [ ] Verify: `cargo check -p flovyn-server`

### Phase 4: Server Integration

- [ ] Update `start_grpc_server()` signature to accept plugin routes:
  ```rust
  pub async fn start_grpc_server(
      addr: SocketAddr,
      state: GrpcState,
      plugin_routes: Option<Routes>,
  ) -> Result<(), tonic::transport::Error>
  ```
- [ ] Refactor to use `Server::layer()` for centralized auth (applies to ALL services):
  ```rust
  pub async fn start_grpc_server(...) {
      // Create auth layer that applies to all services (core + plugins)
      let auth_layer = tower::ServiceBuilder::new()
          .layer(GrpcAuthLayer::new(state.auth_stack.clone()));

      let mut server = Server::builder()
          .layer(auth_layer)  // Applied to ALL services
          .add_service(WorkflowDispatchServer::new(...))
          .add_service(TaskExecutionServer::new(...))
          .add_service(WorkerLifecycleServer::new(...));

      // Add plugin routes (auth already applied via server layer)
      if let Some(routes) = plugin_routes {
          server = server.add_routes(routes);
      }

      server.serve(addr).await
  }
  ```
- [ ] Create `GrpcAuthLayer` in `flovyn-server/server/src/api/grpc/interceptor.rs`:
  ```rust
  /// Tower layer for gRPC auth (applied via Server::layer)
  #[derive(Clone)]
  pub struct GrpcAuthLayer { auth_stack: Arc<AuthStack> }

  impl<S> tower::Layer<S> for GrpcAuthLayer {
      type Service = GrpcAuthService<S>;
      fn layer(&self, inner: S) -> Self::Service { ... }
  }
  ```
- [ ] Update `main.rs`:
  ```rust
  let plugin_grpc_routes = plugin_registry.collect_grpc_routes(plugin_services.clone());
  grpc::start_grpc_server(grpc_addr, grpc_state, plugin_grpc_routes)
  ```
- [ ] Verify: `cargo build -p flovyn-server`

**Note:** This refactors core services too - removes per-service `with_interceptor()` in favor of `Server::layer()`. This is cleaner and ensures consistent auth for all services.

### Phase 5: Unit Tests

- [ ] Add unit test in `flovyn-server/crates/plugin/src/grpc.rs`:
  - Test `PluginGrpcRoutes` creation from a mock service
  - Test routes composition (multiple services)
- [ ] Add unit test in `flovyn-server/server/src/plugin/registry.rs`:
  - Test `collect_grpc_routes()` with plugins returning routes
  - Test with plugins returning `None` (no gRPC services)
- [ ] Verify: `cargo test -p flovyn-plugin && cargo test -p flovyn-server`

### Phase 6: Integration Test - Test Plugin

Create a minimal test plugin for integration testing:

- [ ] Create `flovyn-server/server/tests/integration/test_plugin.rs`:
  ```rust
  // A minimal test gRPC service
  pub mod test_grpc {
      tonic::include_proto!("flovyn.plugins.test.v1");
  }

  pub struct TestPlugin;

  impl Plugin for TestPlugin {
      fn name(&self) -> &'static str { "test" }
      fn version(&self) -> &'static str { "1.0.0" }

      fn grpc_routes(&self, _services: Arc<PluginServices>) -> Option<PluginGrpcRoutes> {
          // No auth handling needed - server applies auth layer automatically
          let svc = TestServiceServer::new(TestServiceImpl);
          Some(PluginGrpcRoutes { routes: Routes::new(svc) })
      }
  }
  ```
- [ ] Create test proto file `server/tests/integration/proto/test_plugin.proto`:
  ```protobuf
  syntax = "proto3";
  package flovyn.plugins.test.v1;

  service TestService {
    rpc Echo(EchoRequest) returns (EchoResponse);
  }

  message EchoRequest { string message = 1; }
  message EchoResponse { string message = 1; }
  ```
- [ ] Update `flovyn-server/server/build.rs` to compile test proto (conditionally for tests)

### Phase 7: Integration Test - gRPC Connectivity

- [ ] Add integration test `flovyn-server/server/tests/integration/plugin_grpc_tests.rs`:
  ```rust
  #[tokio::test]
  async fn test_plugin_grpc_service_responds() {
      let harness = get_harness().await;
      // Connect to test plugin's gRPC service
      let mut client = TestServiceClient::connect(
          format!("http://localhost:{}", harness.grpc_port)
      ).await.unwrap();

      let response = client.echo(EchoRequest { message: "hello".into() }).await;
      assert!(response.is_ok());
      assert_eq!(response.unwrap().into_inner().message, "hello");
  }

  #[tokio::test]
  async fn test_plugin_grpc_auth_required() {
      // Test that unauthenticated requests are rejected
      let harness = get_harness().await;
      let channel = Channel::from_static("http://localhost:...")
          .connect().await.unwrap();
      let mut client = TestServiceClient::new(channel); // No auth

      let response = client.echo(EchoRequest { message: "hello".into() }).await;
      assert!(response.is_err());
      let status = response.unwrap_err();
      assert_eq!(status.code(), tonic::Code::Unauthenticated);
  }

  #[tokio::test]
  async fn test_plugin_grpc_with_valid_auth() {
      let harness = get_harness().await;
      // Use harness.worker_token for auth
      // Verify authenticated request succeeds
  }
  ```
- [ ] Verify: `cargo test --test integration_tests plugin_grpc`

### Phase 8: SDK Testability

Consider how SDK clients can connect to plugin gRPC services:

- [ ] Document plugin service discovery pattern:
  - Plugins register under `flovyn.plugins.<name>.v1.*` namespace
  - Clients can use reflection or known service names
- [ ] Add example in integration test showing SDK-style connection

### Phase 9: Documentation

- [ ] Update `.dev/docs/guides/plugin-development.md`:
  - Add section on gRPC service registration
  - Document naming conventions (`flovyn.plugins.<name>.v1.*`)
  - Add example proto file template
  - Explain auth interceptor usage
- [ ] Update this plan to mark gRPC as complete in plugin system plan

---

## Files to Modify

| File | Changes |
|------|---------|
| `flovyn-server/crates/plugin/Cargo.toml` | Add `tonic` dependency |
| `flovyn-server/crates/plugin/src/lib.rs` | Export `grpc` module |
| `flovyn-server/crates/plugin/src/grpc.rs` | **New**: `PluginGrpcRoutes` (no auth - server handles it) |
| `flovyn-server/crates/plugin/src/traits.rs` | Add `grpc_routes()` method |
| `flovyn-server/server/src/api/rest/mod.rs` | **Fix**: Apply auth middleware to plugin routes |
| `flovyn-server/server/src/api/grpc/interceptor.rs` | Add `GrpcAuthLayer` for plugin routes |
| `flovyn-server/server/src/api/grpc/mod.rs` | Refactor to use `Server::layer()`, accept plugin routes |
| `flovyn-server/server/src/auth/builder.rs` | Add `with_plugin_authenticators()`, resolve by name |
| `flovyn-server/server/src/plugin/registry.rs` | Add `collect_grpc_routes()` |
| `flovyn-server/server/src/main.rs` | Wire plugin authenticators + gRPC routes |
| `flovyn-server/server/tests/integration/plugin_grpc_tests.rs` | **New**: Integration tests |
| `.dev/docs/guides/plugin-development.md` | Document gRPC + custom authenticator |

---

## Testing Strategy Summary

| Test Type | Location | Purpose |
|-----------|----------|---------|
| Unit | `flovyn-server/crates/plugin/src/grpc.rs` | Routes creation & composition |
| Unit | `flovyn-server/server/src/plugin/registry.rs` | Registry gRPC route collection |
| Integration | `flovyn-server/server/tests/integration/plugin_grpc_tests.rs` | End-to-end gRPC connectivity |
| Integration | Same file | Authentication enforcement |
| Integration | Same file | Multi-plugin service registration |

**Key Testing Principles:**
1. Write failing tests first (TDD)
2. Test one thing at a time
3. Testcontainers are fast - if tests hang, the issue is our code
4. All integration tests use timeouts

---

## Exit Criteria

- [ ] **REST fix**: Plugin REST routes have auth middleware applied
- [ ] **Auth fix**: Plugin authenticators wired into AuthStackBuilder
- [ ] Config can reference plugin authenticators by name (e.g., `"worker-token"`)
- [ ] Plugin trait has `grpc_routes()` method
- [ ] PluginRegistry can collect gRPC routes from plugins
- [ ] Server merges plugin gRPC routes at startup
- [ ] Auth layer is applied to all services via `Server::layer()` (centralized)
- [ ] Integration tests pass for plugin gRPC connectivity
- [ ] Integration tests pass for auth enforcement (both REST and gRPC)
- [ ] Integration tests pass for plugin-provided authenticator on gRPC
- [ ] Plugins don't need to handle auth (server does it)
- [ ] Documentation updated
- [ ] All existing tests pass
- [ ] No breaking changes to existing plugins

---

## Example: AI Plugin gRPC Service

Once this infrastructure is in place, the AI plugin can register:

```rust
// plugins/ai/src/lib.rs
impl Plugin for AiPlugin {
    fn grpc_routes(&self, services: Arc<PluginServices>) -> Option<PluginGrpcRoutes> {
        // Create the service implementation - NO auth handling needed!
        // Server applies auth layer automatically (same as REST)
        let llm_impl = LlmServiceImpl::new(self.executor.clone(), services.db_pool.clone());
        let llm_service = LlmServiceServer::new(llm_impl);

        Some(PluginGrpcRoutes {
            routes: Routes::new(llm_service),
        })
    }
}
```

```protobuf
// plugins/ai/proto/flovyn_plugins_ai.proto
syntax = "proto3";
package flovyn.plugins.ai.v1;

service LlmService {
  rpc Execute(ExecuteRequest) returns (ExecuteResponse);
}

message ExecuteRequest {
  string workflow_execution_id = 1;
  bytes input = 2;  // LlmTaskInput JSON
}

message ExecuteResponse {
  bytes output = 1;  // LlmTaskOutput JSON
}
```

---

## Example: Plugin with Custom Authenticator for gRPC

A plugin providing both gRPC services AND a custom authenticator:

```rust
// plugins/my-auth/src/lib.rs
impl Plugin for MyAuthPlugin {
    fn name(&self) -> &'static str { "my-auth" }

    // Provide custom authenticator
    fn authenticators(&self, services: Arc<PluginServices>) -> Vec<Arc<dyn Authenticator>> {
        vec![Arc::new(MyCustomAuthenticator::new(services.db_pool.clone()))]
    }

    // Provide gRPC service (auth handled by server)
    fn grpc_routes(&self, services: Arc<PluginServices>) -> Option<PluginGrpcRoutes> {
        let svc = MyAuthServiceServer::new(MyAuthServiceImpl::new(...));
        Some(PluginGrpcRoutes { routes: Routes::new(svc) })
    }
}
```

**Config to use this plugin's authenticator for gRPC:**
```toml
[auth.endpoints.grpc]
authenticators = ["my-auth", "static_api_key"]  # Plugin authenticator first
authorizer = "cedar"
```

**Flow:**
1. gRPC request arrives
2. `GrpcAuthLayer` runs configured authenticators in order
3. `my-auth` authenticator tries first (plugin-provided)
4. If fails, `static_api_key` tries next
5. Authenticated principal passed to service
6. Plugin's gRPC service handles request

---

## Open Questions

1. **Proto compilation for plugins**: Should plugins compile their own protos, or should there be a shared build process?
   - **Recommendation**: Plugins compile their own protos in their `build.rs`

2. **Service reflection**: Should plugins support gRPC server reflection for discoverability?
   - **Recommendation**: Optional, can be added later

3. **Routes composition order**: Does order matter when adding routes?
   - **Investigation needed**: Verify tonic behavior with overlapping paths

---

## Future Work: Path-based Auth Rules

**Current limitation:** Auth is configured globally per endpoint type. All routes/services use the same authenticators.

**Desired:** Configure auth selectively per path pattern:

```toml
# Default for all HTTP
[auth.endpoints.http]
authenticators = ["jwt", "api_key"]
authorizer = "cedar"

# Override for specific paths
[[auth.endpoints.http.rules]]
path_pattern = "/api/tenants/*/worker-token/validate"
authenticators = []  # Public endpoint

[[auth.endpoints.http.rules]]
path_pattern = "/api/tenants/*/my-plugin/*"
authenticators = ["my-plugin"]
authorizer = "my-plugin-authz"

# For gRPC (uses service/method path format)
[[auth.endpoints.grpc.rules]]
path_pattern = "/flovyn.plugins.ai.v1.LlmService/*"
authenticators = ["ai-plugin-auth"]
```

**Implementation notes:**
- Auth middleware/layer checks rules in order (first match wins)
- gRPC paths use format: `/<package>.<service>/<method>`
- Rules could support wildcards, regex, or glob patterns
- Consider: should plugins declare their auth requirements, or is config-only sufficient?

**Not in scope for this plan** - plugins use global auth configuration for now.

---

## References

- [tonic::service::Routes](https://docs.rs/tonic/0.12.3/tonic/service/struct.Routes.html) - Routes struct documentation
- [tonic::transport::Server](https://docs.rs/tonic/0.12.3/tonic/transport/struct.Server.html) - Server with `add_routes` method
- [tonic GitHub](https://github.com/hyperium/tonic) - Tonic source code
