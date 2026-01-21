# Pluggable Authentication and Authorization

## Overview

Design a pluggable authentication (authn) and authorization (authz) system for Flovyn Server that:

1. **Default**: Minimal or no access control for development and simple deployments
2. **Pluggable Authentication**: Support multiple authentication mechanisms (JWT, worker tokens, API keys, custom)
3. **Pluggable Authorization**: Support multiple authorization backends (no-op, Cedar policy engine, custom RBAC)

This follows the pattern established in the Kotlin server where security is conditionally enabled via `flovyn.security.enabled`.

### Repository Strategy

**Important**: This design separates concerns across repositories:

| Repository | Responsibility |
|------------|----------------|
| `flovyn-server` | Core traits, NoOp implementations, basic tenant-scope auth |
| `flovyn-auth` (separate) | Advanced implementations: Cedar, JWKS, RBAC, etc. |

The core server remains minimal and dependency-light. Advanced security features are developed in a separate crate that can be optionally integrated. This allows:

- Faster compilation for the core server
- Optional Cedar dependency (large compile time)
- Independent versioning of security features
- Easier testing and auditing of security code

---

## Current State

### Authentication

The server currently supports:

1. **JWT Authentication** (`flovyn-server/src/auth/jwt.rs`)
   - Validates JWT tokens for REST API access
   - Supports skip-signature mode for testing (`jwt_skip_signature_verification`)
   - Production verification not yet implemented

2. **Worker Token Authentication** (`flovyn-server/src/auth/worker_token.rs`)
   - HMAC-SHA256 based token generation and validation
   - Tokens prefixed with `fwt_` for identification
   - Validates against `worker_token` table

### Configuration

```rust
pub struct SecurityConfig {
    pub enabled: bool,                          // Default: true
    pub jwt_skip_signature_verification: bool,  // Default: false
}
```

### Gaps

- No authorization layer (only authentication)
- No trait-based pluggable architecture
- Hard to extend with new auth providers

---

## Goals

1. **Zero-config development**: Out of the box, the server should work without any auth setup
2. **Trait-based abstraction**: Define traits for authentication and authorization that allow swapping implementations
3. **Layered security**: Authentication identifies who, authorization decides what they can do
4. **Cedar integration**: Support Cedar policy engine for fine-grained authorization (matching Kotlin server)
5. **Backward compatible**: Existing worker token and JWT flows continue to work

---

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Request Pipeline                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Request  ──► Authenticator ──► Identity ──► Authorizer ──► Handler    │
│                    │                              │                      │
│                    ▼                              ▼                      │
│           ┌───────────────┐              ┌───────────────┐              │
│           │  NoOpAuth     │              │  NoOpAuthz    │              │
│           │  JwtAuth      │              │  CedarAuthz   │              │
│           │  WorkerToken  │              │  RbacAuthz    │              │
│           │  Composite    │              │  Composite    │              │
│           └───────────────┘              └───────────────┘              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Core Traits

#### Identity

Represents an authenticated principal (user, worker, service):

```rust
/// Represents an authenticated identity
#[derive(Debug, Clone)]
pub struct Identity {
    /// Principal type (User, Worker, Service)
    pub principal_type: PrincipalType,
    /// Unique identifier for the principal
    pub principal_id: String,
    /// Tenant context (if applicable)
    pub tenant_id: Option<Uuid>,
    /// Additional attributes for authorization
    pub attributes: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PrincipalType {
    User,
    Worker,
    Service,
    Anonymous,
}

impl Identity {
    /// Create an anonymous identity (for no-auth mode)
    pub fn anonymous() -> Self {
        Self {
            principal_type: PrincipalType::Anonymous,
            principal_id: "anonymous".to_string(),
            tenant_id: None,
            attributes: HashMap::new(),
        }
    }

    /// Create a worker identity
    pub fn worker(worker_id: String, tenant_id: Uuid) -> Self {
        Self {
            principal_type: PrincipalType::Worker,
            principal_id: worker_id,
            tenant_id: Some(tenant_id),
            attributes: HashMap::new(),
        }
    }
}
```

#### Authenticator Trait

Defines how to extract identity from a request. Uses a protocol-agnostic `AuthRequest` that contains only the data needed for authentication.

```rust
use async_trait::async_trait;

/// Protocol-agnostic authentication request
///
/// Contains only the data needed for authentication, with no dependencies
/// on HTTP or gRPC types. Protocol-specific adapters construct this.
#[derive(Debug, Clone)]
pub struct AuthRequest {
    /// Headers/metadata - normalized to lowercase keys
    pub headers: HashMap<String, String>,
    /// Query parameters (for OAuth callbacks, etc.)
    pub query: HashMap<String, String>,
    /// Client IP for audit logging and rate limiting
    pub client_ip: Option<IpAddr>,
    /// Protocol hint (for protocol-specific behavior if needed)
    pub protocol: Protocol,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum Protocol {
    #[default]
    Unknown,
    Http,
    Grpc,
    GrpcWeb,
}

impl AuthRequest {
    /// Create a new AuthRequest (protocol-agnostic constructor)
    pub fn new(headers: HashMap<String, String>) -> Self {
        Self {
            headers,
            query: HashMap::new(),
            client_ip: None,
            protocol: Protocol::Unknown,
        }
    }

    /// Builder pattern for optional fields
    pub fn with_query(mut self, query: HashMap<String, String>) -> Self {
        self.query = query;
        self
    }

    pub fn with_client_ip(mut self, ip: IpAddr) -> Self {
        self.client_ip = Some(ip);
        self
    }

    pub fn with_protocol(mut self, protocol: Protocol) -> Self {
        self.protocol = protocol;
        self
    }

    /// Get the Authorization header value
    pub fn authorization(&self) -> Option<&str> {
        self.headers.get("authorization").map(|s| s.as_str())
    }

    /// Get bearer token from Authorization header
    pub fn bearer_token(&self) -> Option<&str> {
        self.authorization()
            .and_then(|h| h.strip_prefix("Bearer "))
    }

    /// Get session ID from cookie or explicit header
    pub fn session_id(&self) -> Option<&str> {
        // Try cookie first
        self.headers.get("cookie")
            .and_then(|c| parse_cookie(c, "session"))
            // Then try explicit session header
            .or_else(|| self.headers.get("x-session-id").map(|s| s.as_str()))
    }
}

/// Authentication provider trait - single unified method
#[async_trait]
pub trait Authenticator: Send + Sync {
    /// Authenticate a request and return an identity
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError>;
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("No credentials provided")]
    NoCredentials,

    #[error("Invalid credentials: {0}")]
    InvalidCredentials(String),

    #[error("Token expired")]
    Expired,

    #[error("Authentication required")]
    Unauthenticated,

    #[error("Not supported: {0}")]
    NotSupported(String),
}
```

#### Protocol Adapters

Protocol-specific code lives in separate adapter modules. Each adapter knows how to extract an `AuthRequest` from its protocol's types.

```rust
// src/auth/adapter/mod.rs
pub mod http;
pub mod grpc;

/// Trait for converting protocol-specific requests to AuthRequest
pub trait IntoAuthRequest {
    fn into_auth_request(&self) -> AuthRequest;
}
```

**HTTP Adapter** (`flovyn-server/src/auth/adapter/http.rs`):

```rust
use axum::http::{HeaderMap, Request, Uri};
use super::IntoAuthRequest;
use crate::auth::{AuthRequest, Protocol};

/// Adapter for Axum HTTP requests
pub struct HttpRequestAdapter;

impl HttpRequestAdapter {
    /// Extract AuthRequest from full HTTP request
    pub fn from_request<B>(req: &Request<B>) -> AuthRequest {
        let headers = Self::extract_headers(req.headers());
        let query = Self::extract_query(req.uri());
        let client_ip = Self::extract_client_ip(req);

        AuthRequest::new(headers)
            .with_query(query)
            .with_client_ip_opt(client_ip)
            .with_protocol(Protocol::Http)
    }

    /// Extract AuthRequest from headers only (for middleware)
    pub fn from_headers(headers: &HeaderMap) -> AuthRequest {
        AuthRequest::new(Self::extract_headers(headers))
            .with_protocol(Protocol::Http)
    }

    fn extract_headers(headers: &HeaderMap) -> HashMap<String, String> {
        headers
            .iter()
            .filter_map(|(name, value)| {
                value.to_str().ok().map(|v| {
                    (name.as_str().to_lowercase(), v.to_string())
                })
            })
            .collect()
    }

    fn extract_query(uri: &Uri) -> HashMap<String, String> {
        uri.query()
            .map(|q| {
                url::form_urlencoded::parse(q.as_bytes())
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn extract_client_ip<B>(req: &Request<B>) -> Option<IpAddr> {
        // Try X-Forwarded-For, then X-Real-IP, then connection info
        req.headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .and_then(|v| v.trim().parse().ok())
            .or_else(|| {
                req.headers()
                    .get("x-real-ip")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse().ok())
            })
    }
}

/// Extension trait for Axum requests
impl<B> IntoAuthRequest for Request<B> {
    fn into_auth_request(&self) -> AuthRequest {
        HttpRequestAdapter::from_request(self)
    }
}

impl IntoAuthRequest for HeaderMap {
    fn into_auth_request(&self) -> AuthRequest {
        HttpRequestAdapter::from_headers(self)
    }
}
```

**gRPC Adapter** (`flovyn-server/src/auth/adapter/grpc.rs`):

```rust
use tonic::{Request, metadata::MetadataMap};
use super::IntoAuthRequest;
use crate::auth::{AuthRequest, Protocol};

/// Adapter for Tonic gRPC requests
pub struct GrpcRequestAdapter;

impl GrpcRequestAdapter {
    /// Extract AuthRequest from gRPC request
    pub fn from_request<T>(req: &Request<T>) -> AuthRequest {
        let headers = Self::extract_metadata(req.metadata());
        let client_ip = req.remote_addr().map(|a| a.ip());
        let protocol = Self::detect_protocol(req);

        AuthRequest::new(headers)
            .with_client_ip_opt(client_ip)
            .with_protocol(protocol)
    }

    /// Extract AuthRequest from metadata only
    pub fn from_metadata(metadata: &MetadataMap) -> AuthRequest {
        AuthRequest::new(Self::extract_metadata(metadata))
            .with_protocol(Protocol::Grpc)
    }

    fn extract_metadata(metadata: &MetadataMap) -> HashMap<String, String> {
        metadata
            .iter()
            .filter_map(|kv| match kv {
                tonic::metadata::KeyAndValueRef::Ascii(key, value) => {
                    value.to_str().ok().map(|v| {
                        (key.as_str().to_lowercase(), v.to_string())
                    })
                }
                _ => None, // Skip binary metadata
            })
            .collect()
    }

    fn detect_protocol<T>(req: &Request<T>) -> Protocol {
        // Check for grpc-web indicators
        if req.metadata().get("x-grpc-web").is_some() {
            Protocol::GrpcWeb
        } else {
            Protocol::Grpc
        }
    }
}

/// Extension trait for Tonic requests
impl<T> IntoAuthRequest for Request<T> {
    fn into_auth_request(&self) -> AuthRequest {
        GrpcRequestAdapter::from_request(self)
    }
}

impl IntoAuthRequest for MetadataMap {
    fn into_auth_request(&self) -> AuthRequest {
        GrpcRequestAdapter::from_metadata(self)
    }
}
```

**Usage with extension trait:**

```rust
use crate::auth::adapter::IntoAuthRequest;

// In gRPC handler
async fn poll_workflow(&self, request: Request<PollWorkflowRequest>) -> ... {
    let auth_request = request.into_auth_request();
    let identity = self.authenticator.authenticate(&auth_request).await?;
    // ...
}

// In HTTP handler
async fn create_tenant(headers: HeaderMap, ...) -> ... {
    let auth_request = headers.into_auth_request();
    let identity = self.authenticator.authenticate(&auth_request).await?;
    // ...
}
```

#### Module Structure (Updated)

```
src/auth/
├── mod.rs                  # Re-exports public API
│
├── core/                   # Protocol-agnostic core (no HTTP/gRPC deps)
│   ├── mod.rs
│   ├── request.rs          # AuthRequest
│   ├── response.rs         # AuthResponse
│   ├── identity.rs         # Identity, PrincipalType
│   ├── session.rs          # Session, FlowState
│   ├── error.rs            # AuthError, AuthzError
│   └── traits.rs           # Authenticator, Authorizer, AuthenticationFlow
│
├── adapter/                # Protocol-specific adapters
│   ├── mod.rs              # Adapter traits (IntoAuthRequest, IntoHttpResponse, etc.)
│   ├── http.rs             # Axum/HTTP adapters (depends on axum)
│   └── grpc.rs             # Tonic/gRPC adapters (depends on tonic)
│
├── authenticator/          # Authenticator implementations (protocol-agnostic)
│   ├── mod.rs
│   ├── noop.rs             # NoOpAuthenticator
│   ├── worker_token.rs     # WorkerTokenAuthenticator
│   ├── jwt.rs              # JwtAuthenticator
│   ├── session.rs          # SessionAuthenticator
│   └── composite.rs        # CompositeAuthenticator
│
├── authorizer/             # Authorizer implementations (protocol-agnostic)
│   ├── mod.rs
│   ├── noop.rs             # NoOpAuthorizer
│   ├── tenant_scope.rs     # TenantScopeAuthorizer
│   └── composite.rs        # CompositeAuthorizer
│
└── store/                  # Storage traits and basic implementations
    ├── mod.rs
    ├── session.rs          # SessionStore trait + InMemorySessionStore
    └── flow_state.rs       # FlowStateStore trait + InMemoryFlowStateStore
```

#### Dependency Isolation

```
┌─────────────────────────────────────────────────────────────────┐
│                         auth/core/                               │
│  AuthRequest, AuthResponse, Identity, Session, Traits            │
│  Dependencies: std, serde, thiserror, uuid, chrono               │
│  NO: axum, tonic, http                                           │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ uses
          ┌───────────────────┼───────────────────┐
          │                   │                   │
┌─────────┴─────────┐ ┌───────┴───────┐ ┌────────┴────────┐
│  auth/adapter/    │ │  auth/        │ │  auth/          │
│  http.rs          │ │  authenticator│ │  authorizer     │
│                   │ │               │ │                 │
│  Deps: axum, http │ │  Deps: core   │ │  Deps: core     │
└───────────────────┘ └───────────────┘ └─────────────────┘
          │
          │
┌─────────┴─────────┐
│  auth/adapter/    │
│  grpc.rs          │
│                   │
│  Deps: tonic      │
└───────────────────┘
```

#### Feature Flags (Optional)

For even finer control, adapters can be feature-gated:

```toml
[features]
default = ["http-adapter", "grpc-adapter"]
http-adapter = ["axum", "http"]
grpc-adapter = ["tonic"]
```

```rust
// src/auth/adapter/mod.rs
#[cfg(feature = "http-adapter")]
pub mod http;

#[cfg(feature = "grpc-adapter")]
pub mod grpc;
```

#### Benefits of This Separation

1. **Testability**: Core auth logic can be unit tested with plain `AuthRequest` structs, no mocking HTTP/gRPC
2. **Modularity**: Add WebSocket adapter without touching core
3. **Compile times**: Protocol crates only compile if needed
4. **Reusability**: Core types can be used in other crates (CLI, SDK) without pulling in server deps
5. **Clear boundaries**: Easy to audit what has protocol-specific logic

---

## Integration Tests

Integration tests demonstrate how all auth components work together. Tests use the core types directly without needing HTTP/gRPC infrastructure.

### Test Utilities

```rust
// tests/auth/test_utils.rs

use flovyn_server::auth::core::{AuthRequest, Identity, Protocol};
use std::collections::HashMap;

/// Builder for creating test AuthRequests
pub struct TestAuthRequest {
    headers: HashMap<String, String>,
    query: HashMap<String, String>,
    protocol: Protocol,
}

impl TestAuthRequest {
    pub fn new() -> Self {
        Self {
            headers: HashMap::new(),
            query: HashMap::new(),
            protocol: Protocol::Unknown,
        }
    }

    pub fn with_bearer_token(mut self, token: &str) -> Self {
        self.headers.insert("authorization".to_string(), format!("Bearer {}", token));
        self
    }

    pub fn with_session_cookie(mut self, session_id: &str) -> Self {
        self.headers.insert("cookie".to_string(), format!("session={}", session_id));
        self
    }

    pub fn with_session_header(mut self, session_id: &str) -> Self {
        self.headers.insert("x-session-id".to_string(), session_id.to_string());
        self
    }

    pub fn with_header(mut self, key: &str, value: &str) -> Self {
        self.headers.insert(key.to_lowercase(), value.to_string());
        self
    }

    pub fn with_query(mut self, key: &str, value: &str) -> Self {
        self.query.insert(key.to_string(), value.to_string());
        self
    }

    pub fn as_http(mut self) -> Self {
        self.protocol = Protocol::Http;
        self
    }

    pub fn as_grpc(mut self) -> Self {
        self.protocol = Protocol::Grpc;
        self
    }

    pub fn build(self) -> AuthRequest {
        AuthRequest::new(self.headers)
            .with_query(self.query)
            .with_protocol(self.protocol)
    }
}

/// Mock session store for testing
pub struct MockSessionStore {
    sessions: std::sync::RwLock<HashMap<String, Session>>,
}

impl MockSessionStore {
    pub fn new() -> Self {
        Self { sessions: std::sync::RwLock::new(HashMap::new()) }
    }

    pub fn add_session(&self, session: Session) {
        self.sessions.write().unwrap().insert(session.id.clone(), session);
    }
}

#[async_trait]
impl SessionStore for MockSessionStore {
    async fn get(&self, session_id: &str) -> Result<Option<Session>, SessionError> {
        Ok(self.sessions.read().unwrap().get(session_id).cloned())
    }

    async fn create(&self, identity: &Identity, ttl: Duration) -> Result<Session, SessionError> {
        let session = Session {
            id: uuid::Uuid::new_v4().to_string(),
            identity: identity.clone(),
            created_at: Utc::now(),
            expires_at: Utc::now() + ttl,
            last_accessed_at: Utc::now(),
            metadata: HashMap::new(),
        };
        self.sessions.write().unwrap().insert(session.id.clone(), session.clone());
        Ok(session)
    }

    async fn refresh(&self, session_id: &str) -> Result<(), SessionError> {
        if let Some(session) = self.sessions.write().unwrap().get_mut(session_id) {
            session.last_accessed_at = Utc::now();
        }
        Ok(())
    }

    async fn invalidate(&self, session_id: &str) -> Result<(), SessionError> {
        self.sessions.write().unwrap().remove(session_id);
        Ok(())
    }
}
```

### Unit Tests for Core Types

```rust
// tests/auth/core_tests.rs

use flovyn_server::auth::core::*;

#[test]
fn test_auth_request_bearer_token_extraction() {
    let request = AuthRequest::new([
        ("authorization".to_string(), "Bearer my-token-123".to_string()),
    ].into());

    assert_eq!(request.bearer_token(), Some("my-token-123"));
}

#[test]
fn test_auth_request_session_from_cookie() {
    let request = AuthRequest::new([
        ("cookie".to_string(), "foo=bar; session=sess-123; other=value".to_string()),
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
    let identity = Identity::anonymous();
    assert_eq!(identity.principal_type, PrincipalType::Anonymous);
    assert!(identity.tenant_id.is_none());
}

#[test]
fn test_identity_worker() {
    let tenant_id = Uuid::new_v4();
    let identity = Identity::worker("worker-1".to_string(), tenant_id);

    assert_eq!(identity.principal_type, PrincipalType::Worker);
    assert_eq!(identity.tenant_id, Some(tenant_id));
}
```

### Authenticator Integration Tests

```rust
// tests/auth/authenticator_integration_tests.rs

use flovyn_server::auth::{
    core::*,
    authenticator::*,
    store::InMemorySessionStore,
};
use super::test_utils::*;

/// Test NoOpAuthenticator always returns anonymous
#[tokio::test]
async fn test_noop_authenticator() {
    let authenticator = NoOpAuthenticator;

    // HTTP request
    let http_request = TestAuthRequest::new().as_http().build();
    let identity = authenticator.authenticate(&http_request).await.unwrap();
    assert_eq!(identity.principal_type, PrincipalType::Anonymous);

    // gRPC request
    let grpc_request = TestAuthRequest::new().as_grpc().build();
    let identity = authenticator.authenticate(&grpc_request).await.unwrap();
    assert_eq!(identity.principal_type, PrincipalType::Anonymous);

    // Request with token (still anonymous - NoOp ignores credentials)
    let request_with_token = TestAuthRequest::new()
        .with_bearer_token("some-token")
        .build();
    let identity = authenticator.authenticate(&request_with_token).await.unwrap();
    assert_eq!(identity.principal_type, PrincipalType::Anonymous);
}

/// Test SessionAuthenticator with valid/invalid sessions
#[tokio::test]
async fn test_session_authenticator() {
    let session_store = Arc::new(MockSessionStore::new());

    // Create a valid session
    let tenant_id = Uuid::new_v4();
    let identity = Identity::user("user-123".to_string(), Some(tenant_id), HashMap::new());
    let session = Session {
        id: "valid-session-id".to_string(),
        identity: identity.clone(),
        created_at: Utc::now(),
        expires_at: Utc::now() + chrono::Duration::hours(1),
        last_accessed_at: Utc::now(),
        metadata: HashMap::new(),
    };
    session_store.add_session(session);

    let authenticator = SessionAuthenticator::new(session_store.clone());

    // Valid session via cookie (HTTP style)
    let request = TestAuthRequest::new()
        .with_session_cookie("valid-session-id")
        .as_http()
        .build();
    let result = authenticator.authenticate(&request).await.unwrap();
    assert_eq!(result.principal_id, "user-123");
    assert_eq!(result.tenant_id, Some(tenant_id));

    // Valid session via header (gRPC style)
    let request = TestAuthRequest::new()
        .with_session_header("valid-session-id")
        .as_grpc()
        .build();
    let result = authenticator.authenticate(&request).await.unwrap();
    assert_eq!(result.principal_id, "user-123");

    // Invalid session
    let request = TestAuthRequest::new()
        .with_session_cookie("invalid-session-id")
        .build();
    let result = authenticator.authenticate(&request).await;
    assert!(matches!(result, Err(AuthError::InvalidCredentials(_))));

    // No session
    let request = TestAuthRequest::new().build();
    let result = authenticator.authenticate(&request).await;
    assert!(matches!(result, Err(AuthError::NoCredentials)));
}

/// Test CompositeAuthenticator chains correctly
#[tokio::test]
async fn test_composite_authenticator_chain() {
    let session_store = Arc::new(MockSessionStore::new());

    // Add a session
    let tenant_id = Uuid::new_v4();
    let session = Session {
        id: "sess-123".to_string(),
        identity: Identity::user("session-user".to_string(), Some(tenant_id), HashMap::new()),
        created_at: Utc::now(),
        expires_at: Utc::now() + chrono::Duration::hours(1),
        last_accessed_at: Utc::now(),
        metadata: HashMap::new(),
    };
    session_store.add_session(session);

    // Create composite: Session -> JWT (mock)
    let authenticator = CompositeAuthenticator::new(vec![
        Arc::new(SessionAuthenticator::new(session_store.clone())),
        Arc::new(MockJwtAuthenticator::new()), // Returns user based on token
    ]);

    // Request with session - should use SessionAuthenticator
    let request = TestAuthRequest::new()
        .with_session_cookie("sess-123")
        .build();
    let identity = authenticator.authenticate(&request).await.unwrap();
    assert_eq!(identity.principal_id, "session-user");

    // Request with JWT only - should fall through to JwtAuthenticator
    let request = TestAuthRequest::new()
        .with_bearer_token("jwt-token-for-jwt-user")
        .build();
    let identity = authenticator.authenticate(&request).await.unwrap();
    assert_eq!(identity.principal_id, "jwt-user");

    // Request with both - session wins (first in chain)
    let request = TestAuthRequest::new()
        .with_session_cookie("sess-123")
        .with_bearer_token("jwt-token-for-jwt-user")
        .build();
    let identity = authenticator.authenticate(&request).await.unwrap();
    assert_eq!(identity.principal_id, "session-user");

    // Request with nothing - should fail
    let request = TestAuthRequest::new().build();
    let result = authenticator.authenticate(&request).await;
    assert!(matches!(result, Err(AuthError::NoCredentials)));
}

/// Mock JWT authenticator for testing
struct MockJwtAuthenticator;

impl MockJwtAuthenticator {
    fn new() -> Self { Self }
}

#[async_trait]
impl Authenticator for MockJwtAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        let token = request.bearer_token().ok_or(AuthError::NoCredentials)?;

        // Skip worker tokens
        if token.starts_with("fwt_") {
            return Err(AuthError::NoCredentials);
        }

        // Mock: extract user from token pattern "jwt-token-for-{user}"
        if let Some(user) = token.strip_prefix("jwt-token-for-") {
            Ok(Identity::user(user.to_string(), None, HashMap::new()))
        } else {
            Err(AuthError::InvalidCredentials("Invalid mock JWT".into()))
        }
    }
}
```

### Authorizer Integration Tests

```rust
// tests/auth/authorizer_integration_tests.rs

use flovyn_server::auth::{core::*, authorizer::*};

/// Test NoOpAuthorizer allows everything
#[tokio::test]
async fn test_noop_authorizer() {
    let authorizer = NoOpAuthorizer;

    let identity = Identity::anonymous();
    let context = AuthzContext {
        action: "delete".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-123".to_string(),
        resource_attrs: HashMap::new(),
    };

    let decision = authorizer.authorize(&identity, &context).await.unwrap();
    assert_eq!(decision, Decision::Allow);
}

/// Test TenantScopeAuthorizer enforces tenant isolation
#[tokio::test]
async fn test_tenant_scope_authorizer() {
    let authorizer = TenantScopeAuthorizer;

    let tenant_a = Uuid::new_v4();
    let tenant_b = Uuid::new_v4();

    let user_in_tenant_a = Identity::user("user-1".to_string(), Some(tenant_a), HashMap::new());

    // Access resource in same tenant - allowed
    let context = AuthzContext {
        action: "view".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-123".to_string(),
        resource_attrs: [("tenantId".to_string(), tenant_a.to_string())].into(),
    };
    let decision = authorizer.authorize(&user_in_tenant_a, &context).await.unwrap();
    assert_eq!(decision, Decision::Allow);

    // Access resource in different tenant - denied
    let context = AuthzContext {
        action: "view".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-456".to_string(),
        resource_attrs: [("tenantId".to_string(), tenant_b.to_string())].into(),
    };
    let decision = authorizer.authorize(&user_in_tenant_a, &context).await.unwrap();
    assert!(matches!(decision, Decision::Deny(_)));

    // Anonymous users are allowed (for NoOp auth compatibility)
    let anonymous = Identity::anonymous();
    let context = AuthzContext {
        action: "view".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-789".to_string(),
        resource_attrs: [("tenantId".to_string(), tenant_b.to_string())].into(),
    };
    let decision = authorizer.authorize(&anonymous, &context).await.unwrap();
    assert_eq!(decision, Decision::Allow);
}

/// Test CompositeAuthorizer requires all to allow
#[tokio::test]
async fn test_composite_authorizer() {
    let authorizer = CompositeAuthorizer::new(vec![
        Arc::new(TenantScopeAuthorizer),
        Arc::new(MockRoleAuthorizer::new(vec!["admin", "editor"])), // Only these roles allowed
    ]);

    let tenant_id = Uuid::new_v4();

    // Admin in correct tenant - allowed
    let admin = Identity::user("admin-user".to_string(), Some(tenant_id), HashMap::new())
        .with_attribute("role", "admin");
    let context = AuthzContext {
        action: "delete".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-123".to_string(),
        resource_attrs: [("tenantId".to_string(), tenant_id.to_string())].into(),
    };
    let decision = authorizer.authorize(&admin, &context).await.unwrap();
    assert_eq!(decision, Decision::Allow);

    // Viewer in correct tenant - denied (role check fails)
    let viewer = Identity::user("viewer-user".to_string(), Some(tenant_id), HashMap::new())
        .with_attribute("role", "viewer");
    let decision = authorizer.authorize(&viewer, &context).await.unwrap();
    assert!(matches!(decision, Decision::Deny(_)));

    // Admin in wrong tenant - denied (tenant check fails)
    let other_tenant = Uuid::new_v4();
    let admin_other = Identity::user("admin-other".to_string(), Some(other_tenant), HashMap::new())
        .with_attribute("role", "admin");
    let decision = authorizer.authorize(&admin_other, &context).await.unwrap();
    assert!(matches!(decision, Decision::Deny(_)));
}

/// Mock role-based authorizer for testing
struct MockRoleAuthorizer {
    allowed_roles: Vec<String>,
}

impl MockRoleAuthorizer {
    fn new(roles: Vec<&str>) -> Self {
        Self { allowed_roles: roles.into_iter().map(String::from).collect() }
    }
}

#[async_trait]
impl Authorizer for MockRoleAuthorizer {
    async fn authorize(&self, identity: &Identity, _context: &AuthzContext) -> Result<Decision, AuthzError> {
        if identity.principal_type == PrincipalType::Anonymous {
            return Ok(Decision::Allow);
        }

        let role = identity.attributes.get("role").map(|s| s.as_str()).unwrap_or("");
        if self.allowed_roles.iter().any(|r| r == role) {
            Ok(Decision::Allow)
        } else {
            Ok(Decision::Deny(format!("Role '{}' not in allowed roles", role)))
        }
    }
}
```

### End-to-End Auth Flow Test

```rust
// tests/auth/e2e_auth_flow_tests.rs

use flovyn_server::auth::{core::*, authenticator::*, authorizer::*, store::*};
use super::test_utils::*;

/// Simulates a complete authentication and authorization flow
#[tokio::test]
async fn test_complete_auth_flow() {
    // Setup
    let session_store = Arc::new(InMemorySessionStore::new());
    let tenant_id = Uuid::new_v4();

    // Create authenticator chain
    let authenticator = CompositeAuthenticator::new(vec![
        Arc::new(SessionAuthenticator::new(session_store.clone())),
        Arc::new(MockJwtAuthenticator::new()),
    ]);

    // Create authorizer chain
    let authorizer = CompositeAuthorizer::new(vec![
        Arc::new(TenantScopeAuthorizer),
    ]);

    // Simulate: User logs in via JWT, gets a session
    let login_request = TestAuthRequest::new()
        .with_bearer_token("jwt-token-for-alice")
        .as_http()
        .build();

    let identity = authenticator.authenticate(&login_request).await.unwrap();
    assert_eq!(identity.principal_id, "alice");

    // Create session for the user (simulating what login endpoint would do)
    let identity_with_tenant = Identity::user(
        identity.principal_id.clone(),
        Some(tenant_id),
        identity.attributes.clone(),
    );
    let session = session_store.create(&identity_with_tenant, Duration::hours(24)).await.unwrap();

    // Simulate: Subsequent request uses session (HTTP with cookie)
    let http_request = TestAuthRequest::new()
        .with_session_cookie(&session.id)
        .as_http()
        .build();

    let identity = authenticator.authenticate(&http_request).await.unwrap();
    assert_eq!(identity.principal_id, "alice");
    assert_eq!(identity.tenant_id, Some(tenant_id));

    // Simulate: Same user from gRPC (using session header)
    let grpc_request = TestAuthRequest::new()
        .with_session_header(&session.id)
        .as_grpc()
        .build();

    let identity = authenticator.authenticate(&grpc_request).await.unwrap();
    assert_eq!(identity.principal_id, "alice");

    // Authorize: User can access their tenant's resources
    let authz_context = AuthzContext {
        action: "view".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-in-tenant".to_string(),
        resource_attrs: [("tenantId".to_string(), tenant_id.to_string())].into(),
    };

    let decision = authorizer.authorize(&identity, &authz_context).await.unwrap();
    assert_eq!(decision, Decision::Allow);

    // Authorize: User cannot access other tenant's resources
    let other_tenant = Uuid::new_v4();
    let authz_context = AuthzContext {
        action: "view".to_string(),
        resource_type: "Workflow".to_string(),
        resource_id: "wf-other-tenant".to_string(),
        resource_attrs: [("tenantId".to_string(), other_tenant.to_string())].into(),
    };

    let decision = authorizer.authorize(&identity, &authz_context).await.unwrap();
    assert!(matches!(decision, Decision::Deny(_)));

    // Simulate: Session invalidation (logout)
    session_store.invalidate(&session.id).await.unwrap();

    // Subsequent request with old session fails
    let stale_request = TestAuthRequest::new()
        .with_session_cookie(&session.id)
        .build();

    let result = authenticator.authenticate(&stale_request).await;
    assert!(matches!(result, Err(AuthError::InvalidCredentials(_))));
}

/// Test protocol parity - same auth works for HTTP and gRPC
#[tokio::test]
async fn test_protocol_parity() {
    let session_store = Arc::new(InMemorySessionStore::new());
    let tenant_id = Uuid::new_v4();

    // Create session
    let identity = Identity::worker("worker-1".to_string(), tenant_id);
    let session = session_store.create(&identity, Duration::hours(1)).await.unwrap();

    let authenticator = SessionAuthenticator::new(session_store);

    // HTTP: session via cookie
    let http_request = TestAuthRequest::new()
        .with_session_cookie(&session.id)
        .as_http()
        .build();
    let http_identity = authenticator.authenticate(&http_request).await.unwrap();

    // gRPC: session via metadata header
    let grpc_request = TestAuthRequest::new()
        .with_session_header(&session.id)
        .as_grpc()
        .build();
    let grpc_identity = authenticator.authenticate(&grpc_request).await.unwrap();

    // Both should return the same identity
    assert_eq!(http_identity.principal_id, grpc_identity.principal_id);
    assert_eq!(http_identity.tenant_id, grpc_identity.tenant_id);
    assert_eq!(http_identity.principal_type, grpc_identity.principal_type);
}
```

### Test File Organization

```
tests/
├── auth/
│   ├── mod.rs
│   ├── test_utils.rs           # TestAuthRequest builder, mocks
│   ├── core_tests.rs           # Unit tests for AuthRequest, Identity
│   ├── authenticator_tests.rs  # Individual authenticator tests
│   ├── authorizer_tests.rs     # Individual authorizer tests
│   ├── composite_tests.rs      # Chaining/composition tests
│   └── e2e_flow_tests.rs       # Full auth flow scenarios
└── integration/
    └── auth_with_server.rs     # Tests with actual HTTP/gRPC (uses adapters)
```

### Key Testing Principles

1. **Core tests don't need HTTP/gRPC** - Use `TestAuthRequest` builder
2. **Mock stores for isolation** - `MockSessionStore`, `MockWorkerTokenService`
3. **Test composition** - Verify chains behave correctly
4. **Protocol parity** - Same auth logic works for HTTP and gRPC
5. **Edge cases** - Expired sessions, invalid tokens, missing credentials

---

## Configuration

Each auth implementation needs configuration. We use a single server config file with nested sections, and each implementation extracts only what it needs.

### Design Principles

1. **Single source of truth** - One config file (`config.toml` or env vars)
2. **Type-safe extraction** - Each implementation defines its own config struct
3. **Decoupled** - Implementations don't know about the full server config
4. **Validation at startup** - Fail fast if config is invalid

### Server Config Structure

The server has multiple endpoint groups (HTTP REST, gRPC, etc.), each potentially needing different auth configurations:

```rust
// src/config.rs

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    pub server: ServerSettings,
    pub database: DatabaseConfig,
    pub auth: AuthConfig,  // All auth configuration
    // ... other sections
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AuthConfig {
    /// Master switch - when false, uses NoOp for everything
    #[serde(default)]
    pub enabled: bool,

    /// Endpoint-specific auth configurations
    #[serde(default)]
    pub endpoints: EndpointAuthConfigs,

    /// Shared configurations (referenced by endpoints)
    #[serde(default)]
    pub session: SessionConfig,

    #[serde(default)]
    pub jwt: JwtConfig,

    #[serde(default)]
    pub worker_token: WorkerTokenConfig,

    #[serde(default)]
    pub oauth2: Option<OAuth2Config>,

    #[serde(default)]
    pub cedar: Option<CedarConfig>,
}

/// Auth configuration per endpoint group
#[derive(Debug, Clone, Deserialize, Default)]
pub struct EndpointAuthConfigs {
    /// gRPC endpoints (worker APIs)
    #[serde(default)]
    pub grpc: EndpointAuthConfig,

    /// HTTP REST endpoints (user APIs)
    #[serde(default)]
    pub http: EndpointAuthConfig,

    /// Public endpoints (health, metrics) - typically no auth
    #[serde(default)]
    pub public: EndpointAuthConfig,
}

/// Auth configuration for a single endpoint group
#[derive(Debug, Clone, Deserialize)]
pub struct EndpointAuthConfig {
    /// Whether auth is enabled for this endpoint group
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Authenticator chain for this endpoint group
    #[serde(default)]
    pub authenticators: Vec<String>,

    /// Authorizer for this endpoint group
    #[serde(default = "default_authorizer")]
    pub authorizer: String,

    /// Paths to exclude from auth (e.g., health checks)
    #[serde(default)]
    pub exclude_paths: Vec<String>,
}

impl Default for EndpointAuthConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            authenticators: vec![],  // Will use defaults based on endpoint type
            authorizer: "tenant_scope".into(),
            exclude_paths: vec![],
        }
    }
}

fn default_true() -> bool { true }
fn default_authorizer() -> String { "tenant_scope".into() }

/// Sensible defaults per endpoint type
impl EndpointAuthConfigs {
    pub fn with_defaults() -> Self {
        Self {
            grpc: EndpointAuthConfig {
                enabled: true,
                authenticators: vec!["worker_token".into()],
                authorizer: "tenant_scope".into(),
                exclude_paths: vec![],
            },
            http: EndpointAuthConfig {
                enabled: true,
                authenticators: vec!["session".into(), "jwt".into()],
                authorizer: "tenant_scope".into(),
                exclude_paths: vec!["/health".into(), "/metrics".into()],
            },
            public: EndpointAuthConfig {
                enabled: false,  // No auth for public endpoints
                authenticators: vec![],
                authorizer: "none".into(),
                exclude_paths: vec![],
            },
        }
    }
}
```

### Implementation-Specific Config Structs

Each implementation defines its own config struct in `flovyn-server/auth/core/config.rs`:

```rust
// src/auth/core/config.rs - No external deps

use serde::Deserialize;
use std::time::Duration;

/// Session authenticator configuration
#[derive(Debug, Clone, Deserialize)]
pub struct SessionConfig {
    /// Session TTL (default: 24 hours)
    #[serde(default = "default_session_ttl", with = "humantime_serde")]
    pub ttl: Duration,

    /// Cookie name for HTTP sessions
    #[serde(default = "default_cookie_name")]
    pub cookie_name: String,

    /// Header name for gRPC sessions
    #[serde(default = "default_header_name")]
    pub header_name: String,

    /// Storage backend: "memory", "database", "redis"
    #[serde(default = "default_session_store")]
    pub store: String,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            ttl: default_session_ttl(),
            cookie_name: default_cookie_name(),
            header_name: default_header_name(),
            store: default_session_store(),
        }
    }
}

fn default_session_ttl() -> Duration { Duration::from_secs(24 * 60 * 60) }
fn default_cookie_name() -> String { "session".into() }
fn default_header_name() -> String { "x-session-id".into() }
fn default_session_store() -> String { "memory".into() }

/// JWT authenticator configuration
#[derive(Debug, Clone, Deserialize, Default)]
pub struct JwtConfig {
    /// Skip signature verification (ONLY for development)
    #[serde(default)]
    pub skip_verification: bool,

    /// JWKS URI for key discovery
    pub jwks_uri: Option<String>,

    /// Expected issuer
    pub issuer: Option<String>,

    /// Expected audience
    pub audience: Option<String>,

    /// Clock skew tolerance
    #[serde(default = "default_clock_skew", with = "humantime_serde")]
    pub clock_skew: Duration,
}

fn default_clock_skew() -> Duration { Duration::from_secs(60) }

/// Worker token authenticator configuration
#[derive(Debug, Clone, Deserialize, Default)]
pub struct WorkerTokenConfig {
    /// HMAC secret for token validation
    pub secret: Option<String>,

    /// Token prefix (default: "fwt_")
    #[serde(default = "default_token_prefix")]
    pub prefix: String,
}

fn default_token_prefix() -> String { "fwt_".into() }

/// OAuth2 flow configuration (used by flovyn-auth)
#[derive(Debug, Clone, Deserialize)]
pub struct OAuth2Config {
    pub client_id: String,
    pub client_secret: String,
    pub authorization_url: String,
    pub token_url: String,
    pub redirect_uri: String,
    #[serde(default)]
    pub scopes: Vec<String>,
}

/// Cedar authorizer configuration (used by flovyn-auth)
#[derive(Debug, Clone, Deserialize)]
pub struct CedarConfig {
    /// Path to policy files
    pub policy_path: String,

    /// Watch for policy changes
    #[serde(default)]
    pub watch: bool,
}
```

### Config Extraction Pattern

Implementations receive only their config section, not the full server config:

```rust
// src/auth/authenticator/session.rs

use crate::auth::core::config::SessionConfig;

pub struct SessionAuthenticator {
    config: SessionConfig,
    store: Arc<dyn SessionStore>,
}

impl SessionAuthenticator {
    /// Create from config - implementation doesn't know about full server config
    pub fn new(config: SessionConfig, store: Arc<dyn SessionStore>) -> Self {
        Self { config, store }
    }

    /// Convenience: create with default config
    pub fn with_defaults(store: Arc<dyn SessionStore>) -> Self {
        Self::new(SessionConfig::default(), store)
    }
}

#[async_trait]
impl Authenticator for SessionAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        // Use config values
        let session_id = request.session_id_from(&self.config.cookie_name, &self.config.header_name)
            .ok_or(AuthError::NoCredentials)?;

        // ... rest of implementation
    }
}
```

### Builder for Auth Stacks

A builder creates multiple auth stacks - one per endpoint group:

```rust
// src/auth/builder.rs

use crate::auth::{
    core::*,
    authenticator::*,
    authorizer::*,
    store::*,
};
use crate::config::{AuthConfig, EndpointAuthConfig};
use std::collections::HashMap;

/// Builds auth stacks for all endpoint groups
pub struct AuthStackBuilder {
    config: AuthConfig,
    pool: Option<PgPool>,
    session_store: Option<Arc<dyn SessionStore>>,
    /// Custom authenticators registered by extensions
    custom_authenticators: HashMap<String, Arc<dyn Authenticator>>,
    /// Custom authorizers registered by extensions
    custom_authorizers: HashMap<String, Arc<dyn Authorizer>>,
}

impl AuthStackBuilder {
    pub fn new(config: AuthConfig) -> Self {
        Self {
            config,
            pool: None,
            session_store: None,
            custom_authenticators: HashMap::new(),
            custom_authorizers: HashMap::new(),
        }
    }

    pub fn with_database(mut self, pool: PgPool) -> Self {
        self.pool = Some(pool);
        self
    }

    /// Register a custom authenticator (for extensions like flovyn-auth)
    pub fn register_authenticator(mut self, name: &str, auth: Arc<dyn Authenticator>) -> Self {
        self.custom_authenticators.insert(name.to_string(), auth);
        self
    }

    /// Register a custom authorizer (for extensions like flovyn-auth)
    pub fn register_authorizer(mut self, name: &str, authz: Arc<dyn Authorizer>) -> Self {
        self.custom_authorizers.insert(name.to_string(), authz);
        self
    }

    /// Build shared session store (reused across endpoint groups)
    fn get_or_create_session_store(&mut self) -> Arc<dyn SessionStore> {
        if let Some(ref store) = self.session_store {
            return store.clone();
        }

        let store: Arc<dyn SessionStore> = match self.config.session.store.as_str() {
            "database" => {
                let pool = self.pool.clone().expect("Database required for session store");
                Arc::new(DbSessionStore::new(pool))
            }
            "memory" | _ => Arc::new(InMemorySessionStore::new()),
        };

        self.session_store = Some(store.clone());
        store
    }

    /// Build authenticator for a specific endpoint config
    fn build_authenticator_for(&mut self, endpoint_config: &EndpointAuthConfig) -> Arc<dyn Authenticator> {
        if !self.config.enabled || !endpoint_config.enabled {
            return Arc::new(NoOpAuthenticator);
        }

        let mut authenticators: Vec<Arc<dyn Authenticator>> = Vec::new();

        for name in &endpoint_config.authenticators {
            let auth: Option<Arc<dyn Authenticator>> = match name.as_str() {
                "session" => {
                    let store = self.get_or_create_session_store();
                    Some(Arc::new(SessionAuthenticator::new(
                        self.config.session.clone(),
                        store,
                    )))
                }
                "worker_token" => {
                    if self.config.worker_token.secret.is_some() {
                        Some(Arc::new(WorkerTokenAuthenticator::new(
                            self.config.worker_token.clone(),
                        )))
                    } else {
                        tracing::warn!("worker_token authenticator requested but no secret configured");
                        None
                    }
                }
                "jwt" => {
                    Some(Arc::new(JwtAuthenticator::new(self.config.jwt.clone())))
                }
                other => {
                    // Check custom authenticators
                    if let Some(auth) = self.custom_authenticators.get(other) {
                        Some(auth.clone())
                    } else {
                        tracing::warn!("Unknown authenticator: {}", other);
                        None
                    }
                }
            };

            if let Some(a) = auth {
                authenticators.push(a);
            }
        }

        if authenticators.is_empty() {
            Arc::new(NoOpAuthenticator)
        } else if authenticators.len() == 1 {
            authenticators.pop().unwrap()
        } else {
            Arc::new(CompositeAuthenticator::new(authenticators))
        }
    }

    /// Build authorizer for a specific endpoint config
    fn build_authorizer_for(&self, endpoint_config: &EndpointAuthConfig) -> Arc<dyn Authorizer> {
        if !self.config.enabled || !endpoint_config.enabled {
            return Arc::new(NoOpAuthorizer);
        }

        match endpoint_config.authorizer.as_str() {
            "none" => Arc::new(NoOpAuthorizer),
            "tenant_scope" => Arc::new(TenantScopeAuthorizer),
            "cedar" => {
                #[cfg(feature = "cedar")]
                {
                    let cedar_config = self.config.cedar.as_ref()
                        .expect("Cedar config required when authorizer=cedar");
                    Arc::new(flovyn_auth::CedarAuthorizer::new(cedar_config.clone()))
                }
                #[cfg(not(feature = "cedar"))]
                {
                    if let Some(authz) = self.custom_authorizers.get("cedar") {
                        authz.clone()
                    } else {
                        panic!("Cedar authorizer requires 'cedar' feature or custom registration");
                    }
                }
            }
            other => {
                if let Some(authz) = self.custom_authorizers.get(other) {
                    authz.clone()
                } else {
                    tracing::warn!("Unknown authorizer: {}, using tenant_scope", other);
                    Arc::new(TenantScopeAuthorizer)
                }
            }
        }
    }

    /// Build a single auth stack for an endpoint group
    fn build_stack_for(&mut self, endpoint_config: &EndpointAuthConfig) -> AuthStack {
        AuthStack {
            authenticator: self.build_authenticator_for(endpoint_config),
            authorizer: self.build_authorizer_for(endpoint_config),
            exclude_paths: endpoint_config.exclude_paths.clone(),
        }
    }

    /// Build all auth stacks
    pub fn build(mut self) -> AuthStacks {
        AuthStacks {
            grpc: self.build_stack_for(&self.config.endpoints.grpc.clone()),
            http: self.build_stack_for(&self.config.endpoints.http.clone()),
            public: self.build_stack_for(&self.config.endpoints.public.clone()),
        }
    }
}

/// Auth stack for a single endpoint group
#[derive(Clone)]
pub struct AuthStack {
    pub authenticator: Arc<dyn Authenticator>,
    pub authorizer: Arc<dyn Authorizer>,
    pub exclude_paths: Vec<String>,
}

impl AuthStack {
    /// Check if a path should skip authentication
    pub fn should_skip_auth(&self, path: &str) -> bool {
        self.exclude_paths.iter().any(|p| {
            if p.ends_with('*') {
                path.starts_with(p.trim_end_matches('*'))
            } else {
                path == p
            }
        })
    }
}

/// All auth stacks for the server
pub struct AuthStacks {
    pub grpc: AuthStack,
    pub http: AuthStack,
    pub public: AuthStack,
}

impl AuthStacks {
    /// Get the appropriate stack for an endpoint type
    pub fn for_endpoint(&self, endpoint: EndpointType) -> &AuthStack {
        match endpoint {
            EndpointType::Grpc => &self.grpc,
            EndpointType::Http => &self.http,
            EndpointType::Public => &self.public,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum EndpointType {
    Grpc,
    Http,
    Public,
}
```

### Server Startup Integration

```rust
// src/main.rs or src/lib.rs

use crate::config::ServerConfig;
use crate::auth::builder::AuthStackBuilder;

async fn run_server(config: ServerConfig) -> Result<(), Error> {
    let pool = create_database_pool(&config.database).await?;

    // Build all auth stacks from config
    let auth_stacks = AuthStackBuilder::new(config.auth.clone())
        .with_database(pool.clone())
        .build();

    // Create app state with multiple stacks
    let state = AppState {
        pool,
        auth_stacks,
        // ...
    };

    // Start HTTP server with HTTP auth stack
    let http_router = Router::new()
        .route("/api/*", api_routes())
        .layer(auth_middleware(state.auth_stacks.http.clone()));

    // Start gRPC server with gRPC auth stack
    let grpc_server = Server::builder()
        .layer(grpc_auth_layer(state.auth_stacks.grpc.clone()))
        .add_service(workflow_dispatch_service)
        .add_service(task_execution_service);

    // Public endpoints (health, metrics) - no auth
    let public_router = Router::new()
        .route("/health", get(health_check))
        .route("/metrics", get(metrics));

    // ...
}
```

### Example Config File

```toml
# config.toml

[auth]
enabled = true

# ============================================================
# Endpoint-specific authentication and authorization
# ============================================================

[auth.endpoints.grpc]
# gRPC endpoints are primarily for SDK workers
enabled = true
authenticators = ["worker_token"]       # Workers use tokens
authorizer = "tenant_scope"             # Enforce tenant isolation

[auth.endpoints.http]
# HTTP endpoints are for user-facing REST API
enabled = true
authenticators = ["session", "jwt"]     # Users use sessions or JWT
authorizer = "tenant_scope"
exclude_paths = ["/health", "/metrics", "/api/v1/auth/*"]

[auth.endpoints.public]
# Public endpoints have no authentication
enabled = false
authenticators = []
authorizer = "none"

# ============================================================
# Shared authenticator configurations
# ============================================================

[auth.session]
ttl = "24h"
cookie_name = "session"
header_name = "x-session-id"
store = "database"  # "memory" or "database"

[auth.jwt]
skip_verification = false
jwks_uri = "https://auth.example.com/.well-known/jwks.json"
issuer = "https://auth.example.com"
audience = "flovyn-api"
clock_skew = "60s"

[auth.worker_token]
secret = "${WORKER_TOKEN_SECRET}"
prefix = "fwt_"

# ============================================================
# Optional: Advanced auth (requires flovyn-auth crate)
# ============================================================

# OAuth2 flow for user authentication
[auth.oauth2]
client_id = "${OAUTH2_CLIENT_ID}"
client_secret = "${OAUTH2_CLIENT_SECRET}"
authorization_url = "https://auth.example.com/authorize"
token_url = "https://auth.example.com/token"
redirect_uri = "http://localhost:8000/auth/callback"
scopes = ["openid", "profile", "email"]

# Cedar policy engine for fine-grained authorization
[auth.cedar]
policy_path = "/etc/flovyn/policies"
watch = true
```

### Development vs Production Config

**Development** (minimal config):
```toml
[auth]
enabled = false  # Disables all auth
```

**Production with separate concerns**:
```toml
[auth]
enabled = true

[auth.endpoints.grpc]
authenticators = ["worker_token"]
authorizer = "cedar"  # Fine-grained for workers

[auth.endpoints.http]
authenticators = ["session", "jwt"]
authorizer = "cedar"  # Fine-grained for users
exclude_paths = ["/health", "/metrics"]
```

### Accessing Auth in Handlers

```rust
// HTTP handler - uses HTTP auth stack
async fn create_workflow(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,  // Set by middleware
    Json(payload): Json<CreateWorkflowRequest>,
) -> Result<Json<Workflow>, AppError> {
    // Authorize using HTTP stack's authorizer
    let authz_context = AuthzContext {
        action: "create".into(),
        resource_type: "Workflow".into(),
        resource_id: "new".into(),
        resource_attrs: [("tenantId".into(), payload.tenant_id.to_string())].into(),
    };

    state.auth_stacks.http.authorizer
        .require_authorized(&identity, &authz_context)
        .await?;

    // Create workflow...
}

// gRPC handler - uses gRPC auth stack
impl WorkflowDispatch for WorkflowDispatchService {
    async fn poll_workflow(
        &self,
        request: Request<PollWorkflowRequest>,
    ) -> Result<Response<PollWorkflowResponse>, Status> {
        let auth_request = request.into_auth_request();

        // Authenticate using gRPC stack
        let identity = self.auth_stacks.grpc.authenticator
            .authenticate(&auth_request)
            .await
            .map_err(|e| Status::unauthenticated(e.to_string()))?;

        // Authorize using gRPC stack
        let authz_context = AuthzContext { ... };
        self.auth_stacks.grpc.authorizer
            .require_authorized(&identity, &authz_context)
            .await
            .map_err(|e| Status::permission_denied(e.to_string()))?;

        // Poll workflow...
    }
}
```

### Environment Variable Override

```bash
# Disable auth entirely
FLOVYN_AUTH__ENABLED=false

# Change authorizer
FLOVYN_AUTH__AUTHORIZER__BACKEND=cedar

# JWT settings
FLOVYN_AUTH__JWT__SKIP_VERIFICATION=true
FLOVYN_AUTH__JWT__JWKS_URI=https://auth.example.com/.well-known/jwks.json

# Secrets (always use env vars, never in config file)
WORKER_TOKEN_SECRET=your-secret-here
OAUTH2_CLIENT_SECRET=oauth-secret-here
```

### Extension Point for flovyn-auth

External crates can register additional authenticators/authorizers:

```rust
// In flovyn-auth crate

use flovyn_server::auth::{AuthStackBuilder, Authenticator, Authorizer};

/// Extension trait for adding flovyn-auth implementations
pub trait AuthStackBuilderExt {
    fn with_oauth2(self, config: OAuth2Config) -> Self;
    fn with_cedar(self, config: CedarConfig) -> Self;
}

impl AuthStackBuilderExt for AuthStackBuilder {
    fn with_oauth2(mut self, config: OAuth2Config) -> Self {
        // Register OAuth2 flow
        self.register_authenticator("oauth2", Arc::new(OAuth2Authenticator::new(config)));
        self
    }

    fn with_cedar(mut self, config: CedarConfig) -> Self {
        // Register Cedar authorizer
        self.register_authorizer("cedar", Arc::new(CedarAuthorizer::new(config)));
        self
    }
}
```

### Config Validation

```rust
impl AuthConfig {
    /// Validate configuration at startup
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.enabled {
            // JWT requires either skip_verification or jwks_uri
            if !self.jwt.skip_verification && self.jwt.jwks_uri.is_none() {
                return Err(ConfigError::Invalid(
                    "JWT requires either skip_verification=true or jwks_uri".into()
                ));
            }

            // Worker token requires secret
            if self.authenticators.order.contains(&"worker_token".to_string())
                && self.worker_token.secret.is_none()
            {
                return Err(ConfigError::Invalid(
                    "Worker token authenticator requires secret".into()
                ));
            }

            // Cedar requires config
            if self.authorizer.backend == "cedar" && self.cedar.is_none() {
                return Err(ConfigError::Invalid(
                    "Cedar authorizer requires [auth.cedar] config".into()
                ));
            }
        }

        Ok(())
    }
}
```

### Summary

**Config Hierarchy:**

| Layer | Gets Config From | Knows About |
|-------|------------------|-------------|
| Server startup | Full `ServerConfig` | Everything |
| `AuthStackBuilder` | `AuthConfig` section | All auth options |
| `AuthStacks` | Built from `EndpointAuthConfigs` | Per-endpoint stacks |
| `SessionAuthenticator` | `SessionConfig` only | Session settings |
| `JwtAuthenticator` | `JwtConfig` only | JWT settings |
| `CedarAuthorizer` | `CedarConfig` only | Cedar settings |

**Multiple Auth Stacks:**

| Endpoint Group | Default Authenticators | Default Authorizer | Use Case |
|----------------|------------------------|-------------------|----------|
| `grpc` | `["worker_token"]` | `tenant_scope` | SDK workers |
| `http` | `["session", "jwt"]` | `tenant_scope` | REST API users |
| `public` | `[]` (disabled) | `none` | Health, metrics |

This ensures:
1. Single config file for the server
2. Different auth per endpoint group (HTTP vs gRPC)
3. Each implementation only sees its relevant config
4. Shared resources (session store) reused across stacks
5. Type-safe deserialization with sensible defaults
6. Validation at startup
7. Easy to extend with new implementations

#### Authorizer Trait

Defines how to check permissions:

```rust
/// Authorization decision
#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    Allow,
    Deny(String),
}

/// Authorization context for a request
#[derive(Debug, Clone)]
pub struct AuthzContext {
    pub action: String,
    pub resource_type: String,
    pub resource_id: String,
    pub resource_attrs: HashMap<String, String>,
}

/// Authorization provider trait
#[async_trait]
pub trait Authorizer: Send + Sync {
    /// Check if an identity is authorized to perform an action on a resource
    async fn authorize(
        &self,
        identity: &Identity,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError>;

    /// Require authorization, returning error if denied
    async fn require_authorized(
        &self,
        identity: &Identity,
        context: &AuthzContext,
    ) -> Result<(), AuthzError> {
        match self.authorize(identity, context).await? {
            Decision::Allow => Ok(()),
            Decision::Deny(reason) => Err(AuthzError::Denied(reason)),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AuthzError {
    #[error("Access denied: {0}")]
    Denied(String),

    #[error("Authorization check failed: {0}")]
    InternalError(String),
}
```

---

## Implementations

### Authentication Implementations

#### 1. NoOpAuthenticator (Default)

Returns anonymous identity for all requests. Used when security is disabled.

```rust
pub struct NoOpAuthenticator;

#[async_trait]
impl Authenticator for NoOpAuthenticator {
    async fn authenticate(&self, _request: &AuthRequest) -> Result<Identity, AuthError> {
        Ok(Identity::anonymous())
    }
}
```

#### 2. WorkerTokenAuthenticator

Authenticates using worker tokens (`fwt_` prefix):

```rust
pub struct WorkerTokenAuthenticator {
    token_service: Arc<WorkerTokenService>,
}

#[async_trait]
impl Authenticator for WorkerTokenAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        let token = request.bearer_token()
            .ok_or(AuthError::NoCredentials)?;

        if !token.starts_with("fwt_") {
            return Err(AuthError::NoCredentials); // Not a worker token, let next authenticator try
        }

        let tenant_id = self.token_service
            .validate_token(token)
            .await
            .map_err(|e| AuthError::InvalidCredentials(e.to_string()))?
            .ok_or(AuthError::InvalidCredentials("Token not found or invalid".into()))?;

        Ok(Identity::worker(token.to_string(), tenant_id))
    }
}
```

#### 3. JwtAuthenticator

Authenticates using JWT tokens:

```rust
pub struct JwtAuthenticator {
    validator: JwtValidator,
}

#[async_trait]
impl Authenticator for JwtAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        let token = request.bearer_token()
            .ok_or(AuthError::NoCredentials)?;

        // Skip if it's a worker token (let WorkerTokenAuthenticator handle it)
        if token.starts_with("fwt_") {
            return Err(AuthError::NoCredentials);
        }

        let claims = self.validator
            .validate(token)
            .map_err(|e| AuthError::InvalidCredentials(e.to_string()))?;

        Ok(Identity::user(
            claims.sub.clone(),
            claims.tenant_id.map(|t| Uuid::parse_str(&t).ok()).flatten(),
            [
                ("email".to_string(), claims.email),
                ("name".to_string(), claims.name),
            ].into(),
        ))
    }
}
```

#### 4. SessionAuthenticator

Authenticates using session cookies/metadata:

```rust
pub struct SessionAuthenticator {
    session_store: Arc<dyn SessionStore>,
}

#[async_trait]
impl Authenticator for SessionAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        let session_id = request.session_id()
            .ok_or(AuthError::NoCredentials)?;

        let session = self.session_store
            .get(session_id)
            .await
            .map_err(|e| AuthError::InvalidCredentials(e.to_string()))?
            .ok_or(AuthError::InvalidCredentials("Session not found".into()))?;

        if session.is_expired() {
            return Err(AuthError::Expired);
        }

        // Refresh session TTL (fire and forget)
        let _ = self.session_store.refresh(session_id).await;

        Ok(session.identity.clone())
    }
}
```

#### 5. CompositeAuthenticator

Tries multiple authenticators in order (chain of responsibility):

```rust
pub struct CompositeAuthenticator {
    authenticators: Vec<Arc<dyn Authenticator>>,
}

impl CompositeAuthenticator {
    pub fn new(authenticators: Vec<Arc<dyn Authenticator>>) -> Self {
        Self { authenticators }
    }

    /// Builder pattern for common configurations
    pub fn builder() -> CompositeAuthenticatorBuilder {
        CompositeAuthenticatorBuilder::new()
    }
}

#[async_trait]
impl Authenticator for CompositeAuthenticator {
    async fn authenticate(&self, request: &AuthRequest) -> Result<Identity, AuthError> {
        for auth in &self.authenticators {
            match auth.authenticate(request).await {
                Ok(identity) => return Ok(identity),
                Err(AuthError::NoCredentials) => continue, // Try next authenticator
                Err(e) => return Err(e), // Hard failure (invalid token, expired, etc.)
            }
        }
        Err(AuthError::NoCredentials)
    }
}

/// Builder for common authenticator configurations
pub struct CompositeAuthenticatorBuilder { ... }

impl CompositeAuthenticatorBuilder {
    /// Standard configuration: session -> worker token -> JWT
    pub fn standard(
        session_store: Arc<dyn SessionStore>,
        token_service: Arc<WorkerTokenService>,
        jwt_validator: JwtValidator,
    ) -> CompositeAuthenticator {
        CompositeAuthenticator::new(vec![
            Arc::new(SessionAuthenticator { session_store }),
            Arc::new(WorkerTokenAuthenticator { token_service }),
            Arc::new(JwtAuthenticator { validator: jwt_validator }),
        ])
    }

    /// Minimal configuration: worker token only (for SDK workers)
    pub fn worker_only(token_service: Arc<WorkerTokenService>) -> CompositeAuthenticator {
        CompositeAuthenticator::new(vec![
            Arc::new(WorkerTokenAuthenticator { token_service }),
        ])
    }
}
```

---

## Multi-Request Authentication Flows

The basic `Authenticator` trait handles stateless per-request authentication (bearer tokens). However, some authentication mechanisms require state across multiple HTTP requests:

- **OAuth2/OIDC**: Redirect to IdP → callback with authorization code → token exchange
- **SAML**: Similar redirect flows with assertions
- **MFA/Step-up**: Password check → OTP verification → session created
- **Session-based**: Login once → use session cookie for subsequent requests

### Authentication Flow Trait

For redirect-based flows, we introduce a separate `AuthenticationFlow` trait:

```rust
/// Result of initiating an authentication flow
pub enum FlowInitiation {
    /// Redirect the user to this URL
    Redirect { url: String, state: String },
    /// Challenge the user (e.g., request OTP)
    Challenge { challenge_type: String, session_id: String },
    /// Flow not applicable, try next authenticator
    NotApplicable,
}

/// Result of completing an authentication flow
pub enum FlowCompletion {
    /// Authentication successful
    Authenticated(Identity),
    /// Need another step (e.g., MFA after password)
    ContinueFlow { next_step: String, session_id: String },
    /// Authentication failed
    Failed(AuthError),
}

/// Multi-step authentication flow handler
#[async_trait]
pub trait AuthenticationFlow: Send + Sync {
    /// Get the flow identifier (e.g., "oauth2", "saml", "mfa")
    fn flow_id(&self) -> &str;

    /// Initiate the authentication flow
    /// Called when user hits login endpoint without existing session
    async fn initiate(
        &self,
        request: &HttpRequest,
        config: &FlowConfig,
    ) -> Result<FlowInitiation, AuthError>;

    /// Handle callback/continuation of the flow
    /// Called when user returns from redirect or submits next step
    async fn handle_callback(
        &self,
        request: &HttpRequest,
        state: &FlowState,
    ) -> Result<FlowCompletion, AuthError>;

    /// Validate an existing session
    /// For session-based auth, check if session is still valid
    async fn validate_session(
        &self,
        session_id: &str,
    ) -> Result<Option<Identity>, AuthError>;
}

/// State persisted across flow steps
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowState {
    pub flow_id: String,
    pub session_id: String,
    pub step: String,
    pub data: HashMap<String, String>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}
```

### Flow State Storage

Authentication flows need state storage:

```rust
/// Storage for authentication flow state
#[async_trait]
pub trait FlowStateStore: Send + Sync {
    /// Store flow state (with TTL)
    async fn store(&self, state: &FlowState) -> Result<(), StoreError>;

    /// Retrieve flow state
    async fn get(&self, session_id: &str) -> Result<Option<FlowState>, StoreError>;

    /// Delete flow state (after completion)
    async fn delete(&self, session_id: &str) -> Result<(), StoreError>;
}

/// In-memory store (for development)
pub struct InMemoryFlowStateStore { ... }

/// Redis-backed store (for production)
pub struct RedisFlowStateStore { ... }

/// Database-backed store
pub struct DbFlowStateStore { ... }
```

### Session Management

For session-based authentication after flow completion:

```rust
/// Session created after successful authentication
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub identity: Identity,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub last_accessed_at: DateTime<Utc>,
    pub metadata: HashMap<String, String>,
}

/// Session store trait
#[async_trait]
pub trait SessionStore: Send + Sync {
    async fn create(&self, identity: &Identity, ttl: Duration) -> Result<Session, SessionError>;
    async fn get(&self, session_id: &str) -> Result<Option<Session>, SessionError>;
    async fn refresh(&self, session_id: &str) -> Result<(), SessionError>;
    async fn invalidate(&self, session_id: &str) -> Result<(), SessionError>;
}
```

### OAuth2 Flow Example

```rust
pub struct OAuth2Flow {
    client_id: String,
    client_secret: String,
    authorization_url: String,
    token_url: String,
    redirect_uri: String,
    scopes: Vec<String>,
    state_store: Arc<dyn FlowStateStore>,
}

#[async_trait]
impl AuthenticationFlow for OAuth2Flow {
    fn flow_id(&self) -> &str {
        "oauth2"
    }

    async fn initiate(
        &self,
        _request: &HttpRequest,
        _config: &FlowConfig,
    ) -> Result<FlowInitiation, AuthError> {
        // Generate state parameter for CSRF protection
        let state = generate_random_state();
        let nonce = generate_nonce();

        // Store state for callback verification
        let flow_state = FlowState {
            flow_id: "oauth2".to_string(),
            session_id: state.clone(),
            step: "authorization".to_string(),
            data: [("nonce".to_string(), nonce.clone())].into(),
            created_at: Utc::now(),
            expires_at: Utc::now() + Duration::minutes(10),
        };
        self.state_store.store(&flow_state).await?;

        // Build authorization URL
        let url = format!(
            "{}?client_id={}&redirect_uri={}&response_type=code&scope={}&state={}&nonce={}",
            self.authorization_url,
            self.client_id,
            urlencoding::encode(&self.redirect_uri),
            self.scopes.join("+"),
            state,
            nonce,
        );

        Ok(FlowInitiation::Redirect { url, state })
    }

    async fn handle_callback(
        &self,
        request: &HttpRequest,
        state: &FlowState,
    ) -> Result<FlowCompletion, AuthError> {
        // Extract authorization code from query params
        let code = request.query("code")
            .ok_or(AuthError::InvalidCredentials("Missing code".into()))?;

        // Exchange code for tokens
        let tokens = self.exchange_code(code).await?;

        // Validate ID token and extract identity
        let identity = self.validate_id_token(&tokens.id_token, &state.data["nonce"]).await?;

        Ok(FlowCompletion::Authenticated(identity))
    }

    async fn validate_session(&self, _session_id: &str) -> Result<Option<Identity>, AuthError> {
        // OAuth2 flow creates sessions separately
        Ok(None)
    }
}
```

### REST Endpoints for Flows

```rust
// Login initiation
async fn login(
    State(auth): State<AuthState>,
    Query(params): Query<LoginParams>,
) -> impl IntoResponse {
    let flow = auth.get_flow(&params.flow.unwrap_or("oauth2".into()))?;

    match flow.initiate(&request, &config).await? {
        FlowInitiation::Redirect { url, state } => {
            // Set state cookie and redirect
            Response::builder()
                .status(302)
                .header("Location", url)
                .header("Set-Cookie", format!("auth_state={}; HttpOnly; Secure; SameSite=Lax", state))
                .body(Body::empty())
        }
        FlowInitiation::Challenge { challenge_type, session_id } => {
            // Return challenge page/JSON
            Json(json!({ "challenge": challenge_type, "session": session_id }))
        }
        FlowInitiation::NotApplicable => {
            StatusCode::BAD_REQUEST
        }
    }
}

// OAuth2 callback
async fn oauth2_callback(
    State(auth): State<AuthState>,
    Query(params): Query<CallbackParams>,
    cookies: Cookies,
) -> impl IntoResponse {
    // Verify state matches cookie
    let state_cookie = cookies.get("auth_state")?;
    if state_cookie != params.state {
        return Err(AuthError::InvalidCredentials("State mismatch".into()));
    }

    // Retrieve flow state
    let flow_state = auth.state_store.get(&params.state).await?
        .ok_or(AuthError::InvalidCredentials("Unknown state".into()))?;

    // Complete the flow
    let flow = auth.get_flow(&flow_state.flow_id)?;
    match flow.handle_callback(&request, &flow_state).await? {
        FlowCompletion::Authenticated(identity) => {
            // Create session
            let session = auth.session_store.create(&identity, Duration::hours(24)).await?;

            // Clear state, set session cookie, redirect to app
            Response::builder()
                .status(302)
                .header("Location", "/")
                .header("Set-Cookie", format!("session={}; HttpOnly; Secure; SameSite=Lax", session.id))
                .header("Set-Cookie", "auth_state=; Max-Age=0")
                .body(Body::empty())
        }
        FlowCompletion::ContinueFlow { next_step, session_id } => {
            // Redirect to next step (e.g., MFA)
            Json(json!({ "next_step": next_step, "session": session_id }))
        }
        FlowCompletion::Failed(err) => {
            Err(err)
        }
    }
}
```

### Protocol-Agnostic Flow Design

Authentication flows should work across both HTTP and gRPC. The key difference is how state is transported:

| Aspect | HTTP | gRPC |
|--------|------|------|
| Session ID | Cookie or `Authorization` header | `authorization` or `x-session-id` metadata |
| Flow state | Cookie + query params | Metadata |
| Redirects | HTTP 302 | Return redirect URL in response, client handles |

#### Unified Request Abstraction

```rust
/// Protocol-agnostic request for authentication flows
pub struct AuthRequest {
    /// Headers/metadata
    pub headers: HashMap<String, String>,
    /// Query parameters (for callbacks)
    pub query: HashMap<String, String>,
    /// Client IP for audit/rate limiting
    pub client_ip: Option<IpAddr>,
    /// Protocol hint
    pub protocol: Protocol,
}

#[derive(Debug, Clone, Copy)]
pub enum Protocol {
    Http,
    Grpc,
    GrpcWeb,
}

impl AuthRequest {
    /// Create from HTTP request
    pub fn from_http(req: &axum::http::Request<Body>) -> Self {
        Self {
            headers: extract_http_headers(req.headers()),
            query: extract_query_params(req.uri()),
            client_ip: extract_client_ip(req),
            protocol: Protocol::Http,
        }
    }

    /// Create from gRPC request
    pub fn from_grpc<T>(req: &tonic::Request<T>) -> Self {
        Self {
            headers: extract_grpc_metadata(req.metadata()),
            query: HashMap::new(), // gRPC doesn't have query params
            client_ip: req.remote_addr().map(|a| a.ip()),
            protocol: Protocol::Grpc,
        }
    }

    /// Get session ID from cookie (HTTP) or metadata (gRPC)
    pub fn session_id(&self) -> Option<&str> {
        // Try cookie first (HTTP)
        self.headers.get("cookie")
            .and_then(|c| parse_cookie(c, "session"))
            // Then try explicit header/metadata
            .or_else(|| self.headers.get("x-session-id").map(|s| s.as_str()))
    }
}
```

#### Protocol-Agnostic Response

The `AuthResponse` is a pure data structure with no protocol dependencies. Protocol-specific rendering is handled by adapters.

```rust
// src/auth/response.rs - No protocol dependencies

/// Protocol-agnostic authentication response
#[derive(Debug, Clone)]
pub enum AuthResponse {
    /// Authentication successful
    Authenticated {
        identity: Identity,
        /// Session to set (if session-based)
        session: Option<Session>,
    },

    /// Redirect required (OAuth2, SAML)
    Redirect {
        url: String,
        /// State to persist
        state: String,
    },

    /// Challenge required (MFA, captcha)
    Challenge {
        challenge_type: String,
        challenge_data: serde_json::Value,
        session_id: String,
    },

    /// Authentication failed
    Failed(AuthError),
}

impl AuthResponse {
    pub fn authenticated(identity: Identity) -> Self {
        Self::Authenticated { identity, session: None }
    }

    pub fn with_session(identity: Identity, session: Session) -> Self {
        Self::Authenticated { identity, session: Some(session) }
    }

    pub fn redirect(url: String, state: String) -> Self {
        Self::Redirect { url, state }
    }

    pub fn challenge(challenge_type: String, data: serde_json::Value, session_id: String) -> Self {
        Self::Challenge { challenge_type, challenge_data: data, session_id }
    }

    pub fn failed(err: AuthError) -> Self {
        Self::Failed(err)
    }

    pub fn is_authenticated(&self) -> bool {
        matches!(self, Self::Authenticated { .. })
    }
}
```

**HTTP Response Adapter** (`flovyn-server/src/auth/adapter/http.rs`):

```rust
use crate::auth::AuthResponse;

/// Trait for converting AuthResponse to HTTP response
pub trait IntoHttpResponse {
    fn into_http_response(self) -> axum::response::Response;
}

impl IntoHttpResponse for AuthResponse {
    fn into_http_response(self) -> axum::response::Response {
        match self {
            AuthResponse::Authenticated { session, .. } => {
                let mut response = StatusCode::OK.into_response();
                if let Some(s) = session {
                    response.headers_mut().insert(
                        SET_COOKIE,
                        format!("session={}; HttpOnly; Secure; SameSite=Lax; Path=/", s.id)
                            .parse().unwrap()
                    );
                }
                response
            }
            AuthResponse::Redirect { url, state } => {
                Response::builder()
                    .status(StatusCode::FOUND)
                    .header(LOCATION, url)
                    .header(SET_COOKIE, format!("auth_state={}; HttpOnly; Secure; SameSite=Lax", state))
                    .body(Body::empty())
                    .unwrap()
            }
            AuthResponse::Challenge { challenge_type, challenge_data, session_id } => {
                Json(json!({
                    "type": "challenge",
                    "challenge_type": challenge_type,
                    "challenge_data": challenge_data,
                    "session_id": session_id,
                })).into_response()
            }
            AuthResponse::Failed(err) => {
                (StatusCode::UNAUTHORIZED, err.to_string()).into_response()
            }
        }
    }
}
```

**gRPC Response Adapter** (`flovyn-server/src/auth/adapter/grpc.rs`):

```rust
use crate::auth::AuthResponse;
use crate::generated::flovyn::v1::InitiateFlowResponse;

/// Trait for converting AuthResponse to gRPC response
pub trait IntoGrpcResponse {
    fn into_grpc_response(self) -> Result<InitiateFlowResponse, Status>;
}

impl IntoGrpcResponse for AuthResponse {
    fn into_grpc_response(self) -> Result<InitiateFlowResponse, Status> {
        match self {
            AuthResponse::Authenticated { identity, session } => {
                Ok(InitiateFlowResponse {
                    authenticated: true,
                    session_id: session.map(|s| s.id).unwrap_or_default(),
                    ..Default::default()
                })
            }
            AuthResponse::Redirect { url, state } => {
                Ok(InitiateFlowResponse {
                    authenticated: false,
                    redirect_url: url,
                    state,
                    ..Default::default()
                })
            }
            AuthResponse::Challenge { challenge_type, challenge_data, session_id } => {
                Ok(InitiateFlowResponse {
                    authenticated: false,
                    challenge_type,
                    challenge_data: challenge_data.to_string(),
                    session_id,
                    ..Default::default()
                })
            }
            AuthResponse::Failed(err) => {
                Err(Status::unauthenticated(err.to_string()))
            }
        }
    }
}
```

**Usage:**

```rust
// HTTP handler
use crate::auth::adapter::http::IntoHttpResponse;

async fn login_callback(...) -> impl IntoResponse {
    let response = auth_flow.handle_callback(&auth_request, &state).await?;
    response.into_http_response()
}

// gRPC handler
use crate::auth::adapter::grpc::IntoGrpcResponse;

async fn handle_callback(...) -> Result<Response<HandleCallbackResponse>, Status> {
    let response = auth_flow.handle_callback(&auth_request, &state).await?;
    Ok(Response::new(response.into_grpc_response()?))
}
```

### Updated AuthenticationFlow Trait

```rust
/// Multi-step authentication flow handler (protocol-agnostic)
#[async_trait]
pub trait AuthenticationFlow: Send + Sync {
    /// Get the flow identifier (e.g., "oauth2", "saml", "mfa")
    fn flow_id(&self) -> &str;

    /// Check if this flow supports the given protocol
    fn supports_protocol(&self, protocol: Protocol) -> bool {
        // Default: support all protocols
        true
    }

    /// Initiate the authentication flow
    async fn initiate(
        &self,
        request: &AuthRequest,
        config: &FlowConfig,
    ) -> Result<AuthResponse, AuthError>;

    /// Handle callback/continuation of the flow
    async fn handle_callback(
        &self,
        request: &AuthRequest,
        state: &FlowState,
    ) -> Result<AuthResponse, AuthError>;

    /// Handle challenge response (MFA code, etc.)
    async fn handle_challenge_response(
        &self,
        request: &AuthRequest,
        session_id: &str,
        response_data: &serde_json::Value,
    ) -> Result<AuthResponse, AuthError> {
        // Default: not supported
        Err(AuthError::NotSupported("Challenge response not supported".into()))
    }
}
```

### gRPC Authentication Service

For gRPC, expose authentication as a dedicated service:

```protobuf
// In flovyn.proto or separate auth.proto
service Authentication {
    // Initiate an authentication flow
    rpc InitiateFlow(InitiateFlowRequest) returns (InitiateFlowResponse);

    // Handle OAuth2/SAML callback (client calls after redirect)
    rpc HandleCallback(HandleCallbackRequest) returns (HandleCallbackResponse);

    // Submit challenge response (MFA code, etc.)
    rpc SubmitChallenge(SubmitChallengeRequest) returns (SubmitChallengeResponse);

    // Validate/refresh session
    rpc ValidateSession(ValidateSessionRequest) returns (ValidateSessionResponse);

    // Logout/invalidate session
    rpc Logout(LogoutRequest) returns (LogoutResponse);
}

message InitiateFlowRequest {
    string flow_id = 1;  // "oauth2", "saml", "password", etc.
    map<string, string> params = 2;  // Flow-specific params
}

message InitiateFlowResponse {
    bool authenticated = 1;

    // If redirect needed (OAuth2, SAML)
    string redirect_url = 2;
    string state = 3;

    // If challenge needed (MFA)
    string challenge_type = 4;
    string challenge_data = 5;
    string session_id = 6;

    // If immediately authenticated (API key, etc.)
    string access_token = 7;
}

message HandleCallbackRequest {
    string state = 1;
    string code = 2;  // OAuth2 authorization code
    map<string, string> params = 3;  // Other callback params
}

message SubmitChallengeRequest {
    string session_id = 1;
    string challenge_type = 2;
    string response = 3;  // OTP code, WebAuthn assertion, etc.
}
```

### gRPC Client Flow Example

```rust
// Client-side flow for gRPC (e.g., CLI tool)
async fn grpc_oauth2_login(client: &mut AuthClient) -> Result<String, Error> {
    // 1. Initiate flow
    let init_response = client.initiate_flow(InitiateFlowRequest {
        flow_id: "oauth2".to_string(),
        params: HashMap::new(),
    }).await?;

    // 2. If redirect needed, open browser and wait for callback
    if let Some(redirect_url) = init_response.redirect_url {
        println!("Opening browser for login...");
        open::that(&redirect_url)?;

        // Start local callback server or use device flow
        let callback_params = wait_for_oauth_callback().await?;

        // 3. Send callback to server
        let callback_response = client.handle_callback(HandleCallbackRequest {
            state: init_response.state,
            code: callback_params.code,
            params: callback_params.other,
        }).await?;

        // 4. Handle MFA if required
        if let Some(challenge_type) = callback_response.challenge_type {
            let otp = prompt_user_for_otp()?;

            let challenge_response = client.submit_challenge(SubmitChallengeRequest {
                session_id: callback_response.session_id,
                challenge_type,
                response: otp,
            }).await?;

            return Ok(challenge_response.access_token);
        }

        return Ok(callback_response.access_token);
    }

    // Already authenticated (unlikely for OAuth2)
    Ok(init_response.access_token)
}
```

### Usage in Handlers

With the unified `AuthRequest`, handlers construct it once and pass to the authenticator:

```rust
// gRPC service handler
impl WorkflowDispatchService {
    async fn poll_workflow(
        &self,
        request: Request<PollWorkflowRequest>,
    ) -> Result<Response<PollWorkflowResponse>, Status> {
        // Construct AuthRequest from gRPC request
        let auth_request = AuthRequest::from_grpc(&request);

        // Authenticate (works for session, worker token, or JWT)
        let identity = self.authenticator
            .authenticate(&auth_request)
            .await
            .map_err(|e| Status::unauthenticated(e.to_string()))?;

        let req = request.into_inner();

        // Authorize...
        // Business logic...
    }
}

// HTTP handler (Axum)
async fn create_tenant(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateTenantRequest>,
) -> Result<Json<TenantResponse>, AppError> {
    // Construct AuthRequest from HTTP headers
    let auth_request = AuthRequest::from_http_headers(&headers);

    // Same authenticator, same method
    let identity = state.authenticator
        .authenticate(&auth_request)
        .await
        .map_err(|e| AppError::Unauthorized(e.to_string()))?;

    // Authorize...
    // Business logic...
}
```

### Axum Middleware Integration

For HTTP, use Axum middleware to authenticate all requests:

```rust
/// Authentication middleware layer
pub fn auth_middleware(
    authenticator: Arc<dyn Authenticator>,
) -> impl Layer<...> + Clone {
    middleware::from_fn(move |req: Request, next: Next| {
        let auth = authenticator.clone();
        async move {
            // Skip auth for public endpoints
            if is_public_endpoint(req.uri().path()) {
                return next.run(req).await;
            }

            let auth_request = AuthRequest::from_http(&req);

            match auth.authenticate(&auth_request).await {
                Ok(identity) => {
                    // Store identity in request extensions
                    req.extensions_mut().insert(identity);
                    next.run(req).await
                }
                Err(e) => {
                    (StatusCode::UNAUTHORIZED, e.to_string()).into_response()
                }
            }
        }
    })
}

// Extract identity in handlers
async fn handler(
    Extension(identity): Extension<Identity>,
    // ...
) -> impl IntoResponse {
    // identity is guaranteed to be present
}
```

### gRPC Interceptor Integration

For gRPC, use a Tonic interceptor:

```rust
/// Authentication interceptor for gRPC
#[derive(Clone)]
pub struct AuthInterceptor {
    authenticator: Arc<dyn Authenticator>,
}

impl Interceptor for AuthInterceptor {
    fn call(&mut self, mut request: Request<()>) -> Result<Request<()>, Status> {
        // Note: Interceptors are sync, so we can't do async auth here
        // Instead, store AuthRequest in extensions for async auth in handler
        let auth_request = AuthRequest::from_grpc(&request);
        request.extensions_mut().insert(auth_request);
        Ok(request)
    }
}

// Or use tower layer for async authentication
pub fn grpc_auth_layer(
    authenticator: Arc<dyn Authenticator>,
) -> tower::ServiceBuilder<...> {
    tower::ServiceBuilder::new()
        .layer(tower::service_fn(move |req: Request<BoxBody>| {
            let auth = authenticator.clone();
            async move {
                let auth_request = AuthRequest::from_grpc(&req);
                let identity = auth.authenticate(&auth_request).await?;
                req.extensions_mut().insert(identity);
                Ok(req)
            }
        }))
}
```

### Repository Placement

| Component | Repository | Notes |
|-----------|------------|-------|
| `AuthenticationFlow` trait | flovyn-server | Core abstraction |
| `FlowStateStore` trait | flovyn-server | Core abstraction |
| `SessionStore` trait | flovyn-server | Core abstraction |
| `InMemoryFlowStateStore` | flovyn-server | Development use |
| `OAuth2Flow` | flovyn-auth | Requires OAuth2 libs |
| `SAMLFlow` | flovyn-auth | Requires SAML libs |
| `RedisFlowStateStore` | flovyn-auth | Requires Redis client |
| `MfaFlow` | flovyn-auth | OTP/WebAuthn support |

### Authorization Implementations

#### 1. NoOpAuthorizer (Default)

Allows all actions. Used when security is disabled.

```rust
pub struct NoOpAuthorizer;

#[async_trait]
impl Authorizer for NoOpAuthorizer {
    async fn authorize(
        &self,
        _identity: &Identity,
        _context: &AuthzContext,
    ) -> Result<Decision, AuthzError> {
        Ok(Decision::Allow)
    }
}
```

#### 2. TenantScopeAuthorizer

Simple tenant isolation - ensures principals can only access resources in their tenant:

```rust
pub struct TenantScopeAuthorizer;

#[async_trait]
impl Authorizer for TenantScopeAuthorizer {
    async fn authorize(
        &self,
        identity: &Identity,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError> {
        // Anonymous users allowed (for no-auth mode compatibility)
        if identity.principal_type == PrincipalType::Anonymous {
            return Ok(Decision::Allow);
        }

        // Check tenant matches
        let identity_tenant = identity.tenant_id
            .map(|id| id.to_string())
            .unwrap_or_default();

        let resource_tenant = context.resource_attrs
            .get("tenantId")
            .cloned()
            .unwrap_or_default();

        if identity_tenant == resource_tenant {
            Ok(Decision::Allow)
        } else {
            Ok(Decision::Deny(format!(
                "Tenant mismatch: {} cannot access {}",
                identity_tenant, resource_tenant
            )))
        }
    }
}
```

#### 3. CedarAuthorizer

Fine-grained authorization using Cedar policy engine:

```rust
use cedar_policy::{Authorizer as CedarEngine, Context, Entities, PolicySet, Request};

pub struct CedarAuthorizer {
    engine: CedarEngine,
    policy_store: Arc<dyn PolicyStore>,
    entity_adapter: CedarEntityAdapter,
}

#[async_trait]
impl Authorizer for CedarAuthorizer {
    async fn authorize(
        &self,
        identity: &Identity,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError> {
        let policies = self.policy_store.get_policies().await?;

        // Build Cedar principal entity
        let principal = self.entity_adapter.create_principal(identity);

        // Build Cedar resource entity
        let resource = self.entity_adapter.create_resource(
            &context.resource_type,
            &context.resource_id,
            &context.resource_attrs,
        );

        // Build Cedar action
        let action = self.entity_adapter.create_action(&context.action);

        // Create entities set
        let entities = Entities::from_iter([principal.clone(), resource.clone()]);

        // Build request
        let request = Request::new(
            principal.uid(),
            action.uid(),
            resource.uid(),
            Context::empty(),
        );

        // Evaluate
        let response = self.engine.is_authorized(&request, &policies, &entities);

        match response.decision() {
            cedar_policy::Decision::Allow => Ok(Decision::Allow),
            cedar_policy::Decision::Deny => {
                Ok(Decision::Deny(format!(
                    "{} denied for {} on {}::{}",
                    context.action,
                    identity.principal_id,
                    context.resource_type,
                    context.resource_id,
                )))
            }
        }
    }
}
```

#### 4. CompositeAuthorizer

Chains multiple authorizers (all must allow):

```rust
pub struct CompositeAuthorizer {
    authorizers: Vec<Box<dyn Authorizer>>,
}

#[async_trait]
impl Authorizer for CompositeAuthorizer {
    async fn authorize(
        &self,
        identity: &Identity,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError> {
        for authz in &self.authorizers {
            match authz.authorize(identity, context).await? {
                Decision::Allow => continue,
                Decision::Deny(reason) => return Ok(Decision::Deny(reason)),
            }
        }
        Ok(Decision::Allow)
    }
}
```

---

## Cedar Policy Engine

### Entity Schema

Following the Kotlin server pattern, define Cedar entity types:

```cedar
// Entity types for Flovyn authorization
namespace Flovyn {
    entity User {
        tenantId: String,
        id: String,
        role?: String,  // "OWNER", "ADMIN", "MEMBER"
    }

    entity Worker {
        tenantId: String,
        id: String,
    }

    entity Tenant {
        id: String,
        slug?: String,
    }

    entity Workflow {
        id: String,
        tenantId: String,
        spaceId?: String,
        ownerId?: String,
    }

    entity WorkflowExecution {
        id: String,
        workflowId: String,
        tenantId: String,
    }

    entity Task {
        id: String,
        tenantId: String,
    }

    entity Action {}
}
```

### Base Policies

```cedar
// Workers can access resources in their tenant
permit(
    principal is Flovyn::Worker,
    action,
    resource
) when {
    principal.tenantId == resource.tenantId
};

// Tenant owners have full access
permit(
    principal is Flovyn::User,
    action,
    resource
) when {
    principal.role == "OWNER" &&
    principal.tenantId == resource.tenantId
};

// Tenant admins can manage most resources
permit(
    principal is Flovyn::User,
    action in [
        Flovyn::Action::"view",
        Flovyn::Action::"create",
        Flovyn::Action::"update",
        Flovyn::Action::"execute"
    ],
    resource
) when {
    principal.role == "ADMIN" &&
    principal.tenantId == resource.tenantId
};

// Members can view and execute
permit(
    principal is Flovyn::User,
    action in [
        Flovyn::Action::"view",
        Flovyn::Action::"execute"
    ],
    resource
) when {
    principal.role == "MEMBER" &&
    principal.tenantId == resource.tenantId
};
```

### Policy Store Interface

```rust
#[async_trait]
pub trait PolicyStore: Send + Sync {
    /// Load policies (optionally per-tenant)
    async fn get_policies(&self, tenant_id: Option<Uuid>) -> Result<PolicySet, PolicyError>;

    /// Reload policies from source
    async fn reload(&self) -> Result<(), PolicyError>;
}

/// File-based policy store (for static policies)
pub struct FilePolicyStore {
    path: PathBuf,
    policies: RwLock<PolicySet>,
}

/// Database-backed policy store (for tenant-specific policies)
pub struct DbPolicyStore {
    pool: PgPool,
    base_policies: PolicySet,
    cache: RwLock<HashMap<Uuid, PolicySet>>,
}
```

---

## Configuration

### Extended Security Config

```rust
#[derive(Debug, Clone, Deserialize)]
pub struct SecurityConfig {
    /// Master switch for security
    #[serde(default = "default_false")]
    pub enabled: bool,

    /// Authentication configuration
    #[serde(default)]
    pub authentication: AuthenticationConfig,

    /// Authorization configuration
    #[serde(default)]
    pub authorization: AuthorizationConfig,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AuthenticationConfig {
    /// JWT settings
    #[serde(default)]
    pub jwt: JwtConfig,

    /// Worker token secret
    pub worker_token_secret: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct JwtConfig {
    /// Skip signature verification (for testing)
    #[serde(default)]
    pub skip_signature_verification: bool,

    /// JWKS endpoint for key discovery
    pub jwks_uri: Option<String>,

    /// Expected issuer
    pub issuer: Option<String>,

    /// Expected audience
    pub audience: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthorizationConfig {
    /// Authorization backend
    #[serde(default = "default_authz_backend")]
    pub backend: AuthzBackend,

    /// Cedar policy file path (when backend = "cedar")
    pub cedar_policy_path: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub enum AuthzBackend {
    #[default]
    #[serde(rename = "none")]
    None,

    #[serde(rename = "tenant_scope")]
    TenantScope,

    #[serde(rename = "cedar")]
    Cedar,
}
```

### Environment Variables

```bash
# Disable all security (development mode)
FLOVYN_SECURITY__ENABLED=false

# Enable security with tenant scope only
FLOVYN_SECURITY__ENABLED=true
FLOVYN_SECURITY__AUTHORIZATION__BACKEND=tenant_scope

# Enable security with Cedar policies
FLOVYN_SECURITY__ENABLED=true
FLOVYN_SECURITY__AUTHORIZATION__BACKEND=cedar
FLOVYN_SECURITY__AUTHORIZATION__CEDAR_POLICY_PATH=/etc/flovyn/policies.cedar

# JWT configuration
FLOVYN_SECURITY__AUTHENTICATION__JWT__SKIP_SIGNATURE_VERIFICATION=true
FLOVYN_SECURITY__AUTHENTICATION__JWT__JWKS_URI=https://auth.example.com/.well-known/jwks.json
FLOVYN_SECURITY__AUTHENTICATION__JWT__ISSUER=https://auth.example.com
FLOVYN_SECURITY__AUTHENTICATION__JWT__AUDIENCE=flovyn-api
```

---

## Integration

### gRPC Service Integration

Create a middleware/interceptor that injects authentication and authorization:

```rust
pub struct AuthInterceptor {
    authenticator: Arc<dyn Authenticator>,
    authorizer: Arc<dyn Authorizer>,
}

impl Interceptor for AuthInterceptor {
    fn call(&mut self, request: Request<()>) -> Result<Request<()>, Status> {
        // Authentication happens per-request in the service handlers
        // This interceptor can add extensions for lazy auth
        Ok(request)
    }
}
```

In gRPC service handlers:

```rust
impl WorkflowDispatchService {
    async fn poll_workflow(
        &self,
        request: Request<PollWorkflowRequest>,
    ) -> Result<Response<PollWorkflowResponse>, Status> {
        // Authenticate
        let identity = self.authenticator
            .authenticate_grpc(&request)
            .await
            .map_err(|e| Status::unauthenticated(e.to_string()))?;

        let req = request.into_inner();

        // Authorize
        let authz_context = AuthzContext {
            action: "poll".to_string(),
            resource_type: "WorkflowQueue".to_string(),
            resource_id: req.task_queue.clone(),
            resource_attrs: [("tenantId".to_string(), req.tenant_id.clone())].into(),
        };

        self.authorizer
            .require_authorized(&identity, &authz_context)
            .await
            .map_err(|e| Status::permission_denied(e.to_string()))?;

        // Proceed with business logic...
    }
}
```

### REST API Integration (Axum)

Use Axum middleware layers:

```rust
pub fn auth_layer(
    authenticator: Arc<dyn Authenticator>,
    authorizer: Arc<dyn Authorizer>,
) -> impl Layer<...> {
    from_fn(move |req, next| {
        let auth = authenticator.clone();
        async move {
            // For public endpoints like health check, skip auth
            if is_public_endpoint(&req) {
                return next.run(req).await;
            }

            let identity = auth
                .authenticate_http(req.headers())
                .await
                .map_err(|e| (StatusCode::UNAUTHORIZED, e.to_string()))?;

            // Store identity in request extensions
            req.extensions_mut().insert(identity);

            next.run(req).await
        }
    })
}
```

---

## Module Structure

### flovyn-server (this repository)

Core traits and minimal implementations:

```
src/auth/
├── mod.rs                  # Re-exports, builder functions
├── identity.rs             # Identity, PrincipalType
├── traits.rs               # Authenticator, Authorizer traits
├── error.rs                # AuthError, AuthzError
├── authenticator/
│   ├── mod.rs
│   ├── noop.rs             # NoOpAuthenticator
│   ├── worker_token.rs     # WorkerTokenAuthenticator (existing)
│   ├── jwt.rs              # JwtAuthenticator (basic, skip-sig mode)
│   └── composite.rs        # CompositeAuthenticator
└── authorizer/
    ├── mod.rs
    ├── noop.rs             # NoOpAuthorizer
    ├── tenant_scope.rs     # TenantScopeAuthorizer
    └── composite.rs        # CompositeAuthorizer
```

### flovyn-auth (separate repository)

Advanced security implementations:

```
flovyn-auth/
├── Cargo.toml              # cedar-policy, jsonwebtoken, etc.
├── src/
│   ├── lib.rs
│   ├── jwt/
│   │   ├── mod.rs
│   │   ├── jwks.rs         # JWKS key discovery
│   │   └── validator.rs    # Full JWT validation
│   ├── cedar/
│   │   ├── mod.rs
│   │   ├── authorizer.rs   # CedarAuthorizer
│   │   ├── entity_adapter.rs
│   │   ├── policy_store.rs
│   │   └── file_store.rs
│   └── rbac/
│       ├── mod.rs
│       └── authorizer.rs   # Role-based authorizer
└── policies/
    └── base.cedar          # Default Cedar policies
```

Integration in flovyn-server would be via optional feature flag:

```toml
[dependencies]
flovyn-auth = { version = "0.1", optional = true }

[features]
default = []
advanced-auth = ["flovyn-auth"]
```

---

## Security Modes Summary

| Mode | Config | Authentication | Authorization | Repository |
|------|--------|----------------|---------------|------------|
| **Development** | `enabled=false` | NoOp (anonymous) | NoOp (allow all) | flovyn-server |
| **Minimal** | `enabled=true`, `backend=none` | Worker/JWT | NoOp (allow all) | flovyn-server |
| **Tenant Isolation** | `enabled=true`, `backend=tenant_scope` | Worker/JWT | TenantScope | flovyn-server |
| **Full** | `enabled=true`, `backend=cedar` | Worker/JWT + JWKS | Cedar policies | flovyn-auth |

The first three modes are supported out of the box. "Full" mode requires the `flovyn-auth` crate.

---

## Migration Path

### Phase 1: Trait Abstraction (flovyn-server)
1. Define core traits (`Authenticator`, `Authorizer`, `Identity`)
2. Wrap existing JWT/WorkerToken code in trait implementations
3. Add NoOp implementations
4. Export traits as public API for external implementations

### Phase 2: Integration (flovyn-server)
1. Create builder that selects implementations based on config
2. Add authentication to gRPC services
3. Add authentication to REST endpoints
4. Default to NoOp when `security.enabled=false`

### Phase 3: Tenant Scope Authorizer (flovyn-server)
1. Implement `TenantScopeAuthorizer`
2. Add authorization checks to key operations
3. Test tenant isolation
4. This is the maximum built-in authorization for the core server

### Phase 4: Advanced Auth Repository (flovyn-auth - separate)
1. Create new repository `flovyn-auth`
2. Add cedar-policy dependency
3. Implement `CedarEntityAdapter`
4. Implement `CedarAuthorizer`
5. Create base policy set
6. Implement `FilePolicyStore`
7. Add JWKS-based JWT validation

### Phase 5: Integration Layer (optional)
1. Add `flovyn-auth` as optional dependency in flovyn-server
2. Feature-flag advanced auth: `cargo build --features advanced-auth`
3. Config-driven selection of auth backend

### Future (flovyn-auth)
1. Database-backed policy store for tenant policies
2. JWKS key rotation support
3. Role-based access control (RBAC) helpers
4. Audit logging
5. OAuth2/OIDC integration

---

## References

- [Cedar Policy Language](https://www.cedarpolicy.com/)
- [cedar-policy Rust crate](https://crates.io/crates/cedar-policy)
- Kotlin server Cedar implementation: `/Users/manhha/Developer/manhha/leanapp/flovyn/server/app/src/main/kotlin/ai/flovyn/auth/cedar/`
- Current auth implementation: `src/auth/`
