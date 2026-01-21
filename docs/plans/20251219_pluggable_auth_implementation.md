# Pluggable Auth Implementation Plan

## Overview

Implementation plan for the pluggable authentication and authorization system as designed in [pluggable-auth.md](../design/pluggable-auth.md).

**Approach**: Test-first development. Each phase starts with tests that define expected behavior, then implements to make tests pass.

**Scope**: This plan covers flovyn-server only. The `flovyn-auth` crate (Cedar, OAuth2, etc.) is out of scope.

---

## TODO List

### Phase 1: Core Types and Traits

- [x] 1.1 Create `auth/core` module structure
- [x] 1.2 Write tests for `AuthRequest` (token extraction, session parsing)
- [x] 1.3 Implement `AuthRequest` struct
- [x] 1.4 Write tests for `Identity` (anonymous, worker, user)
- [x] 1.5 Implement `Identity` and `PrincipalType`
- [x] 1.6 Write tests for `AuthResponse` variants
- [x] 1.7 Implement `AuthResponse` enum
- [x] 1.8 Define `Authenticator` trait
- [x] 1.9 Define `Authorizer` trait
- [x] 1.10 Define error types (`AuthError`, `AuthzError`)

### Phase 2: Protocol Adapters

- [x] 2.1 Define `IntoAuthRequest` trait
- [x] 2.2 Write tests for HTTP adapter (headers, cookies, query params)
- [x] 2.3 Implement `HttpRequestAdapter`
- [x] 2.4 Write tests for gRPC adapter (metadata extraction)
- [x] 2.5 Implement `GrpcRequestAdapter`
- [x] 2.6 Write tests for `IntoHttpResponse` trait
- [x] 2.7 Implement HTTP response adapter
- [x] 2.8 Write tests for `IntoGrpcResponse` trait
- [x] 2.9 Implement gRPC response adapter

### Phase 3: NoOp Implementations

- [x] 3.1 Write tests for `NoOpAuthenticator`
- [x] 3.2 Implement `NoOpAuthenticator`
- [x] 3.3 Write tests for `NoOpAuthorizer`
- [x] 3.4 Implement `NoOpAuthorizer`

### Phase 4: Session Authenticator

- [x] 4.1 Define `SessionStore` trait
- [x] 4.2 Write tests for `InMemorySessionStore`
- [x] 4.3 Implement `InMemorySessionStore`
- [x] 4.4 Write tests for `SessionAuthenticator`
- [x] 4.5 Implement `SessionAuthenticator`

### Phase 5: Worker Token Authenticator

- [x] 5.1 Write tests for `WorkerTokenAuthenticator` with new trait interface
- [x] 5.2 Refactor existing `WorkerTokenService` to implement `Authenticator`
- [x] 5.3 Verify backward compatibility with existing worker auth

### Phase 6: JWT Authenticator

- [x] 6.1 Write tests for `JwtAuthenticator` (skip-verification mode)
- [x] 6.2 Refactor existing JWT code to implement `Authenticator`
- [x] 6.3 Write tests for claims extraction into `Identity`

### Phase 7: Composite Authenticator

- [x] 7.1 Write tests for `CompositeAuthenticator` chain behavior
- [x] 7.2 Implement `CompositeAuthenticator`
- [x] 7.3 Write tests for chain priority (first match wins)
- [x] 7.4 Write tests for error handling (NoCredentials vs hard failure)

### Phase 8: Tenant Scope Authorizer

- [x] 8.1 Write tests for `TenantScopeAuthorizer`
- [x] 8.2 Implement `TenantScopeAuthorizer`
- [x] 8.3 Write tests for tenant isolation enforcement
- [x] 8.4 Write tests for anonymous identity handling

### Phase 9: Composite Authorizer

- [x] 9.1 Write tests for `CompositeAuthorizer` (all must allow)
- [x] 9.2 Implement `CompositeAuthorizer`

### Phase 10: Configuration

- [x] 10.1 Write tests for config deserialization
- [x] 10.2 Define `AuthConfig` and endpoint configs
- [x] 10.3 Write tests for config validation
- [x] 10.4 Implement config validation
- [x] 10.5 Write tests for default config values

### Phase 11: Auth Stack Builder

- [x] 11.1 Write tests for `AuthStackBuilder` with NoOp (disabled auth)
- [x] 11.2 Write tests for building single authenticator
- [x] 11.3 Write tests for building composite authenticator chain
- [x] 11.4 Write tests for building per-endpoint stacks
- [x] 11.5 Implement `AuthStackBuilder`
- [x] 11.6 Write tests for shared session store across stacks

### Phase 12: Integration with Server

- [x] 12.1 Write integration test: HTTP request with session auth
- [x] 12.2 Write integration test: gRPC request with worker token
- [x] 12.3 Write integration test: different auth per endpoint
- [x] 12.4 Integrate auth stacks into `AppState` and `GrpcState`
- [x] 12.5 Add auth middleware to HTTP routes (active)
- [x] 12.6 Create auth interceptor for gRPC services
- [x] 12.7 Wire gRPC interceptor to server

### Phase 13: End-to-End Tests

- [x] 13.1 E2E test: disabled auth mode
- [x] 13.2 E2E test: worker token authentication flow (via JWT tests)
- [x] 13.3 E2E test: session creation and validation
- [x] 13.4 E2E test: tenant isolation enforcement (via TenantScopeAuthorizer tests)
- [x] 13.5 E2E test: protocol parity (same session works HTTP and gRPC)

---

## Phase Details

### Phase 1: Core Types and Traits

**Goal**: Establish the foundation with protocol-agnostic types.

**Tests first** (`flovyn-server/tests/auth/core_tests.rs`):

```rust
#[test]
fn test_auth_request_bearer_token_extraction() {
    let request = AuthRequest::new([
        ("authorization".to_string(), "Bearer my-token".to_string()),
    ].into());
    assert_eq!(request.bearer_token(), Some("my-token"));
}

#[test]
fn test_auth_request_no_bearer_token() {
    let request = AuthRequest::new(HashMap::new());
    assert_eq!(request.bearer_token(), None);
}

#[test]
fn test_auth_request_session_from_cookie() {
    let request = AuthRequest::new([
        ("cookie".to_string(), "foo=bar; session=sess-123; other=x".to_string()),
    ].into());
    assert_eq!(request.session_id(), Some("sess-123"));
}

#[test]
fn test_auth_request_session_from_header() {
    let request = AuthRequest::new([
        ("x-session-id".to_string(), "sess-456".to_string()),
    ].into());
    assert_eq!(request.session_id(), Some("sess-456"));
}

#[test]
fn test_identity_anonymous() {
    let id = Identity::anonymous();
    assert_eq!(id.principal_type, PrincipalType::Anonymous);
    assert!(id.tenant_id.is_none());
}

#[test]
fn test_identity_worker() {
    let tenant = Uuid::new_v4();
    let id = Identity::worker("w1".into(), tenant);
    assert_eq!(id.principal_type, PrincipalType::Worker);
    assert_eq!(id.tenant_id, Some(tenant));
}
```

**Files to create**:
- `flovyn-server/src/auth/mod.rs` - Module root with re-exports
- `flovyn-server/src/auth/core/mod.rs` - Core module
- `flovyn-server/src/auth/core/request.rs` - `AuthRequest`, `Protocol`
- `flovyn-server/src/auth/core/identity.rs` - `Identity`, `PrincipalType`
- `flovyn-server/src/auth/core/response.rs` - `AuthResponse`
- `flovyn-server/src/auth/core/traits.rs` - `Authenticator`, `Authorizer`
- `flovyn-server/src/auth/core/error.rs` - `AuthError`, `AuthzError`

---

### Phase 2: Protocol Adapters

**Goal**: Bridge HTTP/gRPC types to core types.

**Tests first** (`flovyn-server/tests/auth/adapter_tests.rs`):

```rust
#[test]
fn test_http_adapter_extracts_headers() {
    let mut headers = HeaderMap::new();
    headers.insert(AUTHORIZATION, "Bearer token123".parse().unwrap());

    let auth_request = headers.into_auth_request();

    assert_eq!(auth_request.bearer_token(), Some("token123"));
    assert_eq!(auth_request.protocol, Protocol::Http);
}

#[test]
fn test_http_adapter_extracts_cookies() {
    let mut headers = HeaderMap::new();
    headers.insert(COOKIE, "session=abc123".parse().unwrap());

    let auth_request = headers.into_auth_request();

    assert_eq!(auth_request.session_id(), Some("abc123"));
}

#[test]
fn test_grpc_adapter_extracts_metadata() {
    let mut metadata = MetadataMap::new();
    metadata.insert("authorization", "Bearer grpc-token".parse().unwrap());

    let auth_request = metadata.into_auth_request();

    assert_eq!(auth_request.bearer_token(), Some("grpc-token"));
    assert_eq!(auth_request.protocol, Protocol::Grpc);
}

#[test]
fn test_http_response_redirect() {
    let response = AuthResponse::redirect(
        "https://auth.example.com".into(),
        "state123".into(),
    );

    let http_response = response.into_http_response();

    assert_eq!(http_response.status(), StatusCode::FOUND);
    assert!(http_response.headers().get(LOCATION).is_some());
}
```

**Files to create**:
- `flovyn-server/src/auth/adapter/mod.rs` - `IntoAuthRequest` trait
- `flovyn-server/src/auth/adapter/http.rs` - HTTP adapters
- `flovyn-server/src/auth/adapter/grpc.rs` - gRPC adapters

---

### Phase 3: NoOp Implementations

**Goal**: Provide default implementations for disabled auth.

**Tests first**:

```rust
#[tokio::test]
async fn test_noop_authenticator_returns_anonymous() {
    let auth = NoOpAuthenticator;
    let request = AuthRequest::new(HashMap::new());

    let identity = auth.authenticate(&request).await.unwrap();

    assert_eq!(identity.principal_type, PrincipalType::Anonymous);
}

#[tokio::test]
async fn test_noop_authorizer_allows_everything() {
    let authz = NoOpAuthorizer;
    let identity = Identity::anonymous();
    let context = AuthzContext {
        action: "delete".into(),
        resource_type: "CriticalResource".into(),
        resource_id: "123".into(),
        resource_attrs: HashMap::new(),
    };

    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert_eq!(decision, Decision::Allow);
}
```

**Files to create**:
- `flovyn-server/src/auth/authenticator/mod.rs`
- `flovyn-server/src/auth/authenticator/noop.rs`
- `flovyn-server/src/auth/authorizer/mod.rs`
- `flovyn-server/src/auth/authorizer/noop.rs`

---

### Phase 4: Session Authenticator

**Goal**: Session-based authentication with pluggable storage.

**Tests first**:

```rust
#[tokio::test]
async fn test_in_memory_session_store_create_and_get() {
    let store = InMemorySessionStore::new();
    let identity = Identity::user("user1".into(), Some(Uuid::new_v4()), HashMap::new());

    let session = store.create(&identity, Duration::from_secs(3600)).await.unwrap();
    let retrieved = store.get(&session.id).await.unwrap();

    assert!(retrieved.is_some());
    assert_eq!(retrieved.unwrap().identity.principal_id, "user1");
}

#[tokio::test]
async fn test_session_authenticator_valid_session() {
    let store = Arc::new(InMemorySessionStore::new());
    let identity = Identity::user("alice".into(), Some(Uuid::new_v4()), HashMap::new());
    let session = store.create(&identity, Duration::from_secs(3600)).await.unwrap();

    let auth = SessionAuthenticator::new(SessionConfig::default(), store);
    let request = AuthRequest::new([
        ("cookie".to_string(), format!("session={}", session.id)),
    ].into());

    let result = auth.authenticate(&request).await.unwrap();

    assert_eq!(result.principal_id, "alice");
}

#[tokio::test]
async fn test_session_authenticator_invalid_session() {
    let store = Arc::new(InMemorySessionStore::new());
    let auth = SessionAuthenticator::new(SessionConfig::default(), store);
    let request = AuthRequest::new([
        ("cookie".to_string(), "session=nonexistent".to_string()),
    ].into());

    let result = auth.authenticate(&request).await;

    assert!(matches!(result, Err(AuthError::InvalidCredentials(_))));
}

#[tokio::test]
async fn test_session_authenticator_no_session() {
    let store = Arc::new(InMemorySessionStore::new());
    let auth = SessionAuthenticator::new(SessionConfig::default(), store);
    let request = AuthRequest::new(HashMap::new());

    let result = auth.authenticate(&request).await;

    assert!(matches!(result, Err(AuthError::NoCredentials)));
}
```

**Files to create**:
- `flovyn-server/src/auth/store/mod.rs`
- `flovyn-server/src/auth/store/session.rs` - `SessionStore` trait, `InMemorySessionStore`
- `flovyn-server/src/auth/authenticator/session.rs`

---

### Phase 5: Worker Token Authenticator

**Goal**: Refactor existing worker token auth to new trait.

**Tests first**:

```rust
#[tokio::test]
async fn test_worker_token_authenticator_valid_token() {
    let config = WorkerTokenConfig {
        secret: Some("test-secret".into()),
        prefix: "fwt_".into(),
    };
    let auth = WorkerTokenAuthenticator::new(config);

    // Generate a valid token
    let tenant_id = Uuid::new_v4();
    let token = generate_test_worker_token(&tenant_id, "test-secret");

    let request = AuthRequest::new([
        ("authorization".to_string(), format!("Bearer {}", token)),
    ].into());

    let identity = auth.authenticate(&request).await.unwrap();

    assert_eq!(identity.principal_type, PrincipalType::Worker);
    assert_eq!(identity.tenant_id, Some(tenant_id));
}

#[tokio::test]
async fn test_worker_token_authenticator_skips_non_worker_tokens() {
    let config = WorkerTokenConfig {
        secret: Some("test-secret".into()),
        prefix: "fwt_".into(),
    };
    let auth = WorkerTokenAuthenticator::new(config);

    let request = AuthRequest::new([
        ("authorization".to_string(), "Bearer jwt-token-here".to_string()),
    ].into());

    let result = auth.authenticate(&request).await;

    // Should return NoCredentials so composite can try next authenticator
    assert!(matches!(result, Err(AuthError::NoCredentials)));
}
```

**Files to modify**:
- `flovyn-server/src/auth/worker_token.rs` → `flovyn-server/src/auth/authenticator/worker_token.rs`

---

### Phase 6: JWT Authenticator

**Goal**: Refactor existing JWT auth to new trait.

**Tests first**:

```rust
#[tokio::test]
async fn test_jwt_authenticator_skip_verification_mode() {
    let config = JwtConfig {
        skip_verification: true,
        ..Default::default()
    };
    let auth = JwtAuthenticator::new(config);

    // Create a JWT with claims (signature doesn't matter in skip mode)
    let token = create_test_jwt_token("user-123", Some("tenant-abc"));

    let request = AuthRequest::new([
        ("authorization".to_string(), format!("Bearer {}", token)),
    ].into());

    let identity = auth.authenticate(&request).await.unwrap();

    assert_eq!(identity.principal_type, PrincipalType::User);
    assert_eq!(identity.principal_id, "user-123");
}

#[tokio::test]
async fn test_jwt_authenticator_skips_worker_tokens() {
    let config = JwtConfig::default();
    let auth = JwtAuthenticator::new(config);

    let request = AuthRequest::new([
        ("authorization".to_string(), "Bearer fwt_worker_token".to_string()),
    ].into());

    let result = auth.authenticate(&request).await;

    assert!(matches!(result, Err(AuthError::NoCredentials)));
}
```

**Files to modify**:
- `flovyn-server/src/auth/jwt.rs` → `flovyn-server/src/auth/authenticator/jwt.rs`

---

### Phase 7: Composite Authenticator

**Goal**: Chain multiple authenticators.

**Tests first**:

```rust
#[tokio::test]
async fn test_composite_first_match_wins() {
    let store = Arc::new(InMemorySessionStore::new());
    let identity = Identity::user("session-user".into(), None, HashMap::new());
    let session = store.create(&identity, Duration::from_secs(3600)).await.unwrap();

    let composite = CompositeAuthenticator::new(vec![
        Arc::new(SessionAuthenticator::new(SessionConfig::default(), store)),
        Arc::new(MockAuthenticator::always_returns("jwt-user")),
    ]);

    // Request with session - first authenticator wins
    let request = AuthRequest::new([
        ("cookie".to_string(), format!("session={}", session.id)),
    ].into());

    let result = composite.authenticate(&request).await.unwrap();
    assert_eq!(result.principal_id, "session-user");
}

#[tokio::test]
async fn test_composite_falls_through_on_no_credentials() {
    let composite = CompositeAuthenticator::new(vec![
        Arc::new(MockAuthenticator::returns_no_credentials()),
        Arc::new(MockAuthenticator::always_returns("fallback-user")),
    ]);

    let request = AuthRequest::new(HashMap::new());

    let result = composite.authenticate(&request).await.unwrap();
    assert_eq!(result.principal_id, "fallback-user");
}

#[tokio::test]
async fn test_composite_stops_on_hard_error() {
    let composite = CompositeAuthenticator::new(vec![
        Arc::new(MockAuthenticator::returns_invalid_credentials()),
        Arc::new(MockAuthenticator::always_returns("should-not-reach")),
    ]);

    let request = AuthRequest::new([
        ("authorization".to_string(), "Bearer bad-token".to_string()),
    ].into());

    let result = composite.authenticate(&request).await;
    assert!(matches!(result, Err(AuthError::InvalidCredentials(_))));
}

#[tokio::test]
async fn test_composite_all_no_credentials() {
    let composite = CompositeAuthenticator::new(vec![
        Arc::new(MockAuthenticator::returns_no_credentials()),
        Arc::new(MockAuthenticator::returns_no_credentials()),
    ]);

    let request = AuthRequest::new(HashMap::new());

    let result = composite.authenticate(&request).await;
    assert!(matches!(result, Err(AuthError::NoCredentials)));
}
```

**Files to create**:
- `flovyn-server/src/auth/authenticator/composite.rs`

---

### Phase 8: Tenant Scope Authorizer

**Goal**: Basic tenant isolation.

**Tests first**:

```rust
#[tokio::test]
async fn test_tenant_scope_same_tenant_allowed() {
    let authz = TenantScopeAuthorizer;
    let tenant = Uuid::new_v4();
    let identity = Identity::user("user1".into(), Some(tenant), HashMap::new());
    let context = AuthzContext {
        action: "view".into(),
        resource_type: "Workflow".into(),
        resource_id: "wf-1".into(),
        resource_attrs: [("tenantId".into(), tenant.to_string())].into(),
    };

    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert_eq!(decision, Decision::Allow);
}

#[tokio::test]
async fn test_tenant_scope_different_tenant_denied() {
    let authz = TenantScopeAuthorizer;
    let tenant_a = Uuid::new_v4();
    let tenant_b = Uuid::new_v4();
    let identity = Identity::user("user1".into(), Some(tenant_a), HashMap::new());
    let context = AuthzContext {
        action: "view".into(),
        resource_type: "Workflow".into(),
        resource_id: "wf-1".into(),
        resource_attrs: [("tenantId".into(), tenant_b.to_string())].into(),
    };

    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert!(matches!(decision, Decision::Deny(_)));
}

#[tokio::test]
async fn test_tenant_scope_anonymous_allowed() {
    let authz = TenantScopeAuthorizer;
    let identity = Identity::anonymous();
    let context = AuthzContext {
        action: "view".into(),
        resource_type: "Workflow".into(),
        resource_id: "wf-1".into(),
        resource_attrs: [("tenantId".into(), Uuid::new_v4().to_string())].into(),
    };

    // Anonymous allowed for backward compatibility with disabled auth
    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert_eq!(decision, Decision::Allow);
}
```

**Files to create**:
- `flovyn-server/src/auth/authorizer/tenant_scope.rs`

---

### Phase 9: Composite Authorizer

**Goal**: Chain authorizers (all must allow).

**Tests first**:

```rust
#[tokio::test]
async fn test_composite_authorizer_all_allow() {
    let authz = CompositeAuthorizer::new(vec![
        Arc::new(MockAuthorizer::always_allows()),
        Arc::new(MockAuthorizer::always_allows()),
    ]);

    let identity = Identity::anonymous();
    let context = AuthzContext::default();

    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert_eq!(decision, Decision::Allow);
}

#[tokio::test]
async fn test_composite_authorizer_one_denies() {
    let authz = CompositeAuthorizer::new(vec![
        Arc::new(MockAuthorizer::always_allows()),
        Arc::new(MockAuthorizer::always_denies("reason")),
    ]);

    let identity = Identity::anonymous();
    let context = AuthzContext::default();

    let decision = authz.authorize(&identity, &context).await.unwrap();

    assert!(matches!(decision, Decision::Deny(_)));
}
```

**Files to create**:
- `flovyn-server/src/auth/authorizer/composite.rs`

---

### Phase 10: Configuration

**Goal**: Type-safe config with validation.

**Tests first**:

```rust
#[test]
fn test_config_deserialize_minimal() {
    let toml = r#"
        [auth]
        enabled = false
    "#;

    let config: AuthConfig = toml::from_str(toml).unwrap();

    assert!(!config.enabled);
}

#[test]
fn test_config_deserialize_full() {
    let toml = r#"
        [auth]
        enabled = true

        [auth.endpoints.grpc]
        authenticators = ["worker_token"]
        authorizer = "tenant_scope"

        [auth.endpoints.http]
        authenticators = ["session", "jwt"]
        authorizer = "tenant_scope"
        exclude_paths = ["/health"]

        [auth.session]
        ttl = "24h"

        [auth.jwt]
        skip_verification = true
    "#;

    let config: AuthConfig = toml::from_str(toml).unwrap();

    assert!(config.enabled);
    assert_eq!(config.endpoints.grpc.authenticators, vec!["worker_token"]);
    assert_eq!(config.endpoints.http.exclude_paths, vec!["/health"]);
}

#[test]
fn test_config_validation_jwt_requires_jwks_or_skip() {
    let config = AuthConfig {
        enabled: true,
        endpoints: EndpointAuthConfigs {
            http: EndpointAuthConfig {
                authenticators: vec!["jwt".into()],
                ..Default::default()
            },
            ..Default::default()
        },
        jwt: JwtConfig {
            skip_verification: false,
            jwks_uri: None,
            ..Default::default()
        },
        ..Default::default()
    };

    let result = config.validate();

    assert!(result.is_err());
}
```

**Files to create/modify**:
- `flovyn-server/src/auth/core/config.rs` - Individual config structs
- `flovyn-server/src/config.rs` - Add `AuthConfig` to server config

---

### Phase 11: Auth Stack Builder

**Goal**: Build auth stacks from config.

**Tests first**:

```rust
#[test]
fn test_builder_disabled_auth_returns_noop() {
    let config = AuthConfig {
        enabled: false,
        ..Default::default()
    };

    let stacks = AuthStackBuilder::new(config).build();

    // All stacks should be NoOp
    // (verify by checking it allows everything)
}

#[tokio::test]
async fn test_builder_grpc_stack_uses_worker_token() {
    let config = AuthConfig {
        enabled: true,
        endpoints: EndpointAuthConfigs {
            grpc: EndpointAuthConfig {
                authenticators: vec!["worker_token".into()],
                ..Default::default()
            },
            ..Default::default()
        },
        worker_token: WorkerTokenConfig {
            secret: Some("secret".into()),
            ..Default::default()
        },
        ..Default::default()
    };

    let stacks = AuthStackBuilder::new(config).build();

    // Test that gRPC stack accepts worker tokens
    let token = generate_test_worker_token(&Uuid::new_v4(), "secret");
    let request = AuthRequest::new([
        ("authorization".to_string(), format!("Bearer {}", token)),
    ].into());

    let result = stacks.grpc.authenticator.authenticate(&request).await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_builder_http_stack_uses_session_and_jwt() {
    let config = AuthConfig {
        enabled: true,
        endpoints: EndpointAuthConfigs {
            http: EndpointAuthConfig {
                authenticators: vec!["session".into(), "jwt".into()],
                ..Default::default()
            },
            ..Default::default()
        },
        jwt: JwtConfig {
            skip_verification: true,
            ..Default::default()
        },
        ..Default::default()
    };

    let stacks = AuthStackBuilder::new(config).build();

    // Test that HTTP stack accepts JWT
    let token = create_test_jwt_token("user1", None);
    let request = AuthRequest::new([
        ("authorization".to_string(), format!("Bearer {}", token)),
    ].into());

    let result = stacks.http.authenticator.authenticate(&request).await;
    assert!(result.is_ok());
}

#[test]
fn test_builder_exclude_paths() {
    let config = AuthConfig {
        enabled: true,
        endpoints: EndpointAuthConfigs {
            http: EndpointAuthConfig {
                exclude_paths: vec!["/health".into(), "/api/v1/public/*".into()],
                ..Default::default()
            },
            ..Default::default()
        },
        ..Default::default()
    };

    let stacks = AuthStackBuilder::new(config).build();

    assert!(stacks.http.should_skip_auth("/health"));
    assert!(stacks.http.should_skip_auth("/api/v1/public/foo"));
    assert!(!stacks.http.should_skip_auth("/api/v1/workflows"));
}
```

**Files to create**:
- `flovyn-server/src/auth/builder.rs`

---

### Phase 12: Integration with Server

**Goal**: Wire auth into HTTP and gRPC servers.

**Tests first** (integration tests):

```rust
#[tokio::test]
async fn test_http_request_with_session() {
    let app = create_test_app_with_auth().await;

    // Create session via login
    let login_response = app.post("/api/v1/auth/login")
        .json(&json!({"username": "test", "password": "test"}))
        .send()
        .await;
    let session_cookie = login_response.headers().get(SET_COOKIE).unwrap();

    // Use session for authenticated request
    let response = app.get("/api/v1/workflows")
        .header(COOKIE, session_cookie)
        .send()
        .await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_grpc_request_with_worker_token() {
    let (client, _server) = create_test_grpc_server_with_auth().await;

    let token = generate_worker_token();
    let mut request = Request::new(PollWorkflowRequest { ... });
    request.metadata_mut().insert(
        "authorization",
        format!("Bearer {}", token).parse().unwrap(),
    );

    let response = client.poll_workflow(request).await;

    assert!(response.is_ok());
}

#[tokio::test]
async fn test_different_auth_per_endpoint() {
    let app = create_test_app_with_auth().await;

    // HTTP with JWT
    let jwt = create_test_jwt_token("user1", None);
    let http_response = app.get("/api/v1/workflows")
        .header(AUTHORIZATION, format!("Bearer {}", jwt))
        .send()
        .await;
    assert_eq!(http_response.status(), StatusCode::OK);

    // HTTP with worker token should fail (not in HTTP authenticators)
    let worker_token = generate_worker_token();
    let http_response = app.get("/api/v1/workflows")
        .header(AUTHORIZATION, format!("Bearer {}", worker_token))
        .send()
        .await;
    assert_eq!(http_response.status(), StatusCode::UNAUTHORIZED);
}
```

**Files to modify**:
- `flovyn-server/src/main.rs` - Build auth stacks on startup
- `flovyn-server/src/api/rest/mod.rs` - Add auth middleware
- `flovyn-server/src/api/grpc/*.rs` - Use auth in handlers

---

### Phase 13: End-to-End Tests

**Goal**: Full flow tests with real server.

```rust
#[tokio::test]
async fn e2e_disabled_auth_mode() {
    // Start server with auth.enabled = false
    let server = start_test_server(AuthConfig { enabled: false, ..Default::default() }).await;

    // All requests should succeed without auth
    let response = server.http_client()
        .get("/api/v1/workflows")
        .send()
        .await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn e2e_worker_token_flow() {
    let server = start_test_server_with_default_auth().await;

    // Register worker
    let token = server.create_worker_token("test-worker").await;

    // Use token for gRPC calls
    let mut client = server.grpc_client();
    let response = client.poll_workflow(PollWorkflowRequest { ... })
        .with_auth(&token)
        .await;

    assert!(response.is_ok());
}

#[tokio::test]
async fn e2e_tenant_isolation() {
    let server = start_test_server_with_default_auth().await;

    // Create two tenants
    let tenant_a = server.create_tenant("tenant-a").await;
    let tenant_b = server.create_tenant("tenant-b").await;

    // Create workflow in tenant A
    let token_a = server.create_worker_token_for_tenant(tenant_a).await;
    let workflow = server.create_workflow_with_token(&token_a, "test-wf").await;

    // Worker from tenant B cannot access it
    let token_b = server.create_worker_token_for_tenant(tenant_b).await;
    let result = server.get_workflow_with_token(&token_b, &workflow.id).await;

    assert!(result.is_err()); // Permission denied
}
```

---

## File Structure After Implementation

```
src/auth/
├── mod.rs                      # Re-exports
├── builder.rs                  # AuthStackBuilder
│
├── core/
│   ├── mod.rs
│   ├── request.rs              # AuthRequest, Protocol
│   ├── response.rs             # AuthResponse
│   ├── identity.rs             # Identity, PrincipalType
│   ├── context.rs              # AuthzContext, Decision
│   ├── traits.rs               # Authenticator, Authorizer
│   ├── error.rs                # AuthError, AuthzError
│   └── config.rs               # Config structs
│
├── adapter/
│   ├── mod.rs                  # IntoAuthRequest, IntoHttpResponse
│   ├── http.rs                 # HTTP adapters
│   └── grpc.rs                 # gRPC adapters
│
├── authenticator/
│   ├── mod.rs
│   ├── noop.rs
│   ├── session.rs
│   ├── worker_token.rs
│   ├── jwt.rs
│   └── composite.rs
│
├── authorizer/
│   ├── mod.rs
│   ├── noop.rs
│   ├── tenant_scope.rs
│   └── composite.rs
│
└── store/
    ├── mod.rs
    ├── session.rs              # SessionStore trait, InMemorySessionStore
    └── flow_state.rs           # FlowStateStore (for future flows)

tests/
├── auth/
│   ├── mod.rs
│   ├── test_utils.rs           # TestAuthRequest, mocks
│   ├── core_tests.rs
│   ├── adapter_tests.rs
│   ├── authenticator_tests.rs
│   ├── authorizer_tests.rs
│   ├── builder_tests.rs
│   └── e2e_tests.rs
```

---

## Definition of Done

Each phase is complete when:

1. All tests in the phase pass
2. Code compiles with `cargo check`
3. No new clippy warnings (`cargo clippy`)
4. Code is formatted (`cargo fmt`)
5. Existing tests still pass (`./bin/dev/test.sh`)

Final completion criteria:

1. All TODO items checked off
2. Integration tests pass with testcontainers
3. E2E tests pass
4. Existing gRPC handlers use new auth system
5. Config can enable/disable auth
6. Different auth works for HTTP vs gRPC endpoints
