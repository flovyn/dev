# Add Authorization to Entrypoints

## Problem Statement

Currently, the server has **authentication** in place (JWT, Session, Worker Token) but **authorization** is only partially implemented:

- `NoOpAuthorizer` - allows all actions (used when auth is disabled)
- `TenantScopeAuthorizer` - enforces tenant isolation only

This means any authenticated user can perform any action within their tenant, which is insufficient for production security. We need fine-grained access control to:

1. Restrict which principals can access which endpoints
2. Control actions based on resource ownership
3. Support role-based access control (OWNER, ADMIN, MEMBER)

## Reference Implementation

The Kotlin server at `/Users/manhha/Developer/manhha/leanapp/flovyn` already has Cedar-based authorization:
- `CedarAuthorizationService` - Policy evaluation service
- `CedarEntityAdapter` - Converts domain entities to Cedar entities
- `base-policies.cedar` - RBAC policies for tenant/worker authorization

We will port this approach to Rust.

## Current Architecture

### Existing Authorizer Trait

```rust
// crates/core/src/auth/traits.rs
#[async_trait]
pub trait Authorizer: Send + Sync {
    async fn authorize(
        &self,
        principal: &Principal,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError>;
}

// crates/core/src/auth/context.rs
pub struct AuthzContext {
    pub action: String,
    pub resource_type: String,
    pub resource_id: String,
    pub resource_attrs: HashMap<String, String>,
}
```

### Current Implementations

| Implementation | Behavior |
|----------------|----------|
| `NoOpAuthorizer` | Always returns `Allow` |
| `TenantScopeAuthorizer` | Checks `principal.tenant_id == resource.tenant_id` |

## Design

### Fluent Authorization API (Implemented)

To provide a consistent and ergonomic authorization API across REST and gRPC, we implemented a fluent helper pattern:

```rust
// Usage in handlers:
state.authorize(&principal).create("TaskExecution", tenant_id).await?;
state.authorize(&principal).view("Workflow", &id, tenant_id).await?;
state.authorize(&principal).execute(&workflow_kind, tenant_id).await?;
```

#### Core Types

| Type | Purpose |
|------|---------|
| `FromAuthzError` | Trait for converting `AuthzError` to protocol-specific errors |
| `Authorize<'a, E>` | Fluent helper with action methods (`.create()`, `.view()`, etc.) |
| `CanAuthorize` | Trait for state types, provides `.authorize(principal)` method |

#### Protocol Implementations

| Protocol | State Type | Error Type |
|----------|-----------|------------|
| gRPC | `GrpcState`, `Arc<AuthStack>` | `tonic::Status` |
| REST | `AppState` | `(StatusCode, Json<RestErrorResponse>)` |

#### Benefits

1. **Consistent API** - Same pattern works for REST and gRPC
2. **Type-safe errors** - Error type is determined by the state's associated type
3. **Ergonomic** - No need to manually map errors at each call site
4. **Protocol-agnostic** - Authorization logic is shared, only error conversion differs

### Phase 1: Add Authorization Calls to All Endpoints

**Goal:** Add `authorizer.authorize()` calls to all endpoints using the existing trait. This establishes authorization call sites without changing implementations.

### Action Names (Aligned with Kotlin)

| Action | Description |
|--------|-------------|
| `view` | Read/view a resource |
| `create` | Create a new resource |
| `update` | Modify an existing resource |
| `delete` | Delete a resource |
| `execute` | Execute a workflow |
| `poll` | Poll for work (workers) |
| `complete` | Mark work as completed (workers) |
| `fail` | Mark work as failed (workers) |
| `heartbeat` | Send heartbeat (workers) |
| `manage` | Manage settings/configuration |

### Resource Types

| Resource Type | Description |
|---------------|-------------|
| `Tenant` | Tenant organization |
| `Workflow` | Workflow definition |
| `WorkflowExecution` | Running workflow instance |
| `Task` | Task definition |
| `TaskExecution` | Running task instance |
| `Worker` | Registered worker |
| `Space` | Organizational space (future) |

### Endpoint-by-Endpoint Permission Matrix

#### REST API Endpoints

| Endpoint | Method | Action | Resource Type | Resource ID |
|----------|--------|--------|---------------|-------------|
| `/api/tenants` | POST | `create` | `Tenant` | `new` |
| `/api/tenants/:slug` | GET | `view` | `Tenant` | `{tenant_id}` |
| `/api/tenants/:slug/workflows/:kind/trigger` | POST | `execute` | `Workflow` | `{kind}` |
| `/api/tenants/:slug/stream/workflows/:id` | GET | `view` | `WorkflowExecution` | `{id}` |
| `/api/tenants/:slug/stream/workflows/:id/consolidated` | GET | `view` | `WorkflowExecution` | `{id}` |

#### gRPC WorkflowDispatch Service

| Method | Action | Resource Type | Resource ID |
|--------|--------|---------------|-------------|
| `PollWorkflow` | `poll` | `WorkflowExecution` | `any` |
| `StartWorkflow` | `execute` | `Workflow` | `{kind}` |
| `StartChildWorkflow` | `execute` | `Workflow` | `{kind}` |
| `SubmitWorkflowCommands` | `update` | `WorkflowExecution` | `{execution_id}` |
| `GetEvents` | `view` | `WorkflowExecution` | `{execution_id}` |
| `ResolvePromise` | `update` | `WorkflowExecution` | `{execution_id}` |
| `RejectPromise` | `update` | `WorkflowExecution` | `{execution_id}` |
| `GetVisualWorkflowDefinitionById` | `view` | `Workflow` | `{id}` |
| `ReportExecutionSpans` | `update` | `WorkflowExecution` | `{execution_id}` |
| `SubscribeToNotifications` | `poll` | `Tenant` | `{tenant_id}` |

#### gRPC TaskExecution Service

| Method | Action | Resource Type | Resource ID |
|--------|--------|---------------|-------------|
| `SubmitTask` | `create` | `TaskExecution` | `new` |
| `PollTask` | `poll` | `TaskExecution` | `any` |
| `CompleteTask` | `complete` | `TaskExecution` | `{task_id}` |
| `FailTask` | `fail` | `TaskExecution` | `{task_id}` |
| `CancelTask` | `update` | `TaskExecution` | `{task_id}` |
| `ReportProgress` | `update` | `TaskExecution` | `{task_id}` |
| `Heartbeat` | `heartbeat` | `TaskExecution` | `{task_id}` |
| `LogMessage` | `update` | `TaskExecution` | `{task_id}` |
| `GetState` | `update` | `TaskExecution` | `{task_id}` |
| `SetState` | `update` | `TaskExecution` | `{task_id}` |
| `ClearState` | `update` | `TaskExecution` | `{task_id}` |
| `ClearAllState` | `update` | `TaskExecution` | `{task_id}` |
| `GetStateKeys` | `update` | `TaskExecution` | `{task_id}` |
| `StreamTaskData` | `view` | `TaskExecution` | `{task_id}` |

#### gRPC WorkerLifecycle Service

| Method | Action | Resource Type | Resource ID |
|--------|--------|---------------|-------------|
| `RegisterWorker` | `create` | `Worker` | `new` |
| `SendHeartbeat` | `heartbeat` | `Worker` | `{worker_id}` |

### Enrich the Authorizer with Helper Extension

Add an extension trait for ergonomic authorization in handlers:

```rust
// server/src/auth/authorize.rs

use flovyn_core::auth::{AuthzContext, AuthzError, Authorizer, Decision, Principal};
use uuid::Uuid;

/// Extension trait for ergonomic authorization in handlers.
#[async_trait]
pub trait AuthorizerExt: Authorizer {
    /// Require authorization, returning error if denied.
    async fn require(
        &self,
        principal: &Principal,
        action: &str,
        resource_type: &str,
        resource_id: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        let context = AuthzContext::new(action, resource_type, resource_id)
            .with_attr("tenantId", tenant_id.to_string());

        match self.authorize(principal, &context).await? {
            Decision::Allow => Ok(()),
            Decision::Deny(reason) => Err(AuthzError::PermissionDenied(
                reason.unwrap_or_else(|| format!(
                    "Access denied: {} on {}::{}",
                    action, resource_type, resource_id
                ))
            )),
        }
    }

    /// Convenience: require view permission
    async fn require_view(
        &self,
        principal: &Principal,
        resource_type: &str,
        resource_id: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "view", resource_type, resource_id, tenant_id).await
    }

    /// Convenience: require create permission
    async fn require_create(
        &self,
        principal: &Principal,
        resource_type: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "create", resource_type, "new", tenant_id).await
    }

    /// Convenience: require update permission
    async fn require_update(
        &self,
        principal: &Principal,
        resource_type: &str,
        resource_id: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "update", resource_type, resource_id, tenant_id).await
    }

    /// Convenience: require delete permission
    async fn require_delete(
        &self,
        principal: &Principal,
        resource_type: &str,
        resource_id: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "delete", resource_type, resource_id, tenant_id).await
    }

    /// Convenience: require execute permission (for workflows)
    async fn require_execute(
        &self,
        principal: &Principal,
        workflow_kind: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "execute", "Workflow", workflow_kind, tenant_id).await
    }

    /// Convenience: require poll permission (for workers)
    async fn require_poll(
        &self,
        principal: &Principal,
        resource_type: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        self.require(principal, "poll", resource_type, "any", tenant_id).await
    }
}

// Blanket implementation for all Authorizers
impl<T: Authorizer + ?Sized> AuthorizerExt for T {}
```

### Integration into Endpoints

**REST Handler Example:**
```rust
// In workflows.rs
pub async fn trigger_workflow(
    State(state): State<AppState>,
    Path((tenant_slug, kind)): Path<(String, String)>,
    Extension(principal): Extension<AuthenticatedPrincipal>,
    Json(request): Json<TriggerWorkflowRequest>,
) -> Result<Json<TriggerWorkflowResponse>, AppError> {
    let tenant = get_tenant(&state.pool, &tenant_slug).await?;

    // Authorization check via Authorizer trait
    state.auth_stack.authorizer
        .require_execute(principal.as_ref(), &kind, tenant.id)
        .await
        .map_err(AppError::from)?;

    // ... rest of handler
}
```

**gRPC Handler Example:**
```rust
// In workflow_dispatch.rs
async fn poll_workflow(
    &self,
    request: Request<PollRequest>,
) -> Result<Response<PollResponse>, Status> {
    let principal = extract_principal(&request)?;
    let req = request.into_inner();
    let tenant_id: Uuid = req.tenant_id.parse()
        .map_err(|_| Status::invalid_argument("invalid tenant_id"))?;

    // Authorization check via Authorizer trait
    self.state.auth_stack.authorizer
        .require_poll(&principal, "WorkflowExecution", tenant_id)
        .await
        .map_err(|e| Status::permission_denied(e.to_string()))?;

    // ... rest of handler
}

async fn submit_workflow_commands(
    &self,
    request: Request<SubmitWorkflowCommandsRequest>,
) -> Result<Response<()>, Status> {
    let principal = extract_principal(&request)?;
    let req = request.into_inner();
    let tenant_id: Uuid = req.tenant_id.parse()
        .map_err(|_| Status::invalid_argument("invalid tenant_id"))?;

    // Authorization check via Authorizer trait
    self.state.auth_stack.authorizer
        .require_update(&principal, "WorkflowExecution", &req.workflow_execution_id, tenant_id)
        .await
        .map_err(|e| Status::permission_denied(e.to_string()))?;

    // ... rest of handler
}
```

### Phase 2: Cedar Policy Implementation

**Goal:** Add `CedarAuthorizer` as an implementation of the `Authorizer` trait for fine-grained policy-based access control.

#### Authorizer Implementations

| Implementation | Use Case |
|----------------|----------|
| `NoOpAuthorizer` | Development, auth disabled |
| `TenantScopeAuthorizer` | Basic tenant isolation |
| `CedarAuthorizer` | **NEW** - Fine-grained RBAC/ABAC |

#### CedarAuthorizer Implementation

```rust
// server/src/auth/authorizer/cedar.rs

use cedar_policy::{Authorizer as CedarEngine, Context, Entities, PolicySet, Request};
use flovyn_core::auth::{AuthzContext, AuthzError, Authorizer, Decision, Principal};

pub struct CedarAuthorizer {
    engine: CedarEngine,
    policy_set: PolicySet,
    entity_adapter: CedarEntityAdapter,
}

#[async_trait]
impl Authorizer for CedarAuthorizer {
    async fn authorize(
        &self,
        principal: &Principal,
        context: &AuthzContext,
    ) -> Result<Decision, AuthzError> {
        // Build Cedar request from principal and context
        let principal_uid = self.entity_adapter.principal_uid(principal);
        let action = self.entity_adapter.action_uid(&context.action);
        let resource = self.entity_adapter.resource_uid(
            &context.resource_type,
            &context.resource_id,
        );

        // Build entities (principal + resource with their attributes)
        let entities = self.entity_adapter.build_entities(principal, context)?;

        let request = Request::new(
            Some(principal_uid),
            Some(action),
            Some(resource),
            Context::empty(),
            None,
        ).map_err(|e| AuthzError::Internal(e.to_string()))?;

        let response = self.engine.is_authorized(&request, &self.policy_set, &entities);

        match response.decision() {
            cedar_policy::Decision::Allow => Ok(Decision::Allow),
            cedar_policy::Decision::Deny => {
                let reasons: Vec<_> = response.diagnostics().errors().collect();
                Ok(Decision::deny(format!("Policy denied: {:?}", reasons)))
            }
        }
    }

    fn name(&self) -> &'static str {
        "cedar"
    }
}
```

#### Base Policies (Port from Kotlin)

```cedar
// server/policies/base-policies.cedar

// =============================================================================
// TENANT-LEVEL POLICIES
// =============================================================================

// Tenant owners can do everything in their tenant
permit(
    principal,
    action,
    resource
)
when {
    principal.tenantId == resource.tenantId &&
    principal.role == "OWNER"
};

// Tenant admins can manage most resources
permit(
    principal,
    action in [
        Flovyn::Action::"create",
        Flovyn::Action::"update",
        Flovyn::Action::"delete",
        Flovyn::Action::"view",
        Flovyn::Action::"execute",
        Flovyn::Action::"manage"
    ],
    resource
)
when {
    principal.tenantId == resource.tenantId &&
    principal.role == "ADMIN"
};

// Tenant members can view and execute
permit(
    principal,
    action in [
        Flovyn::Action::"view",
        Flovyn::Action::"execute"
    ],
    resource
)
when {
    principal.tenantId == resource.tenantId &&
    principal.role == "MEMBER"
};

// Members can update workflow executions (for cancellation, retry)
permit(
    principal,
    action == Flovyn::Action::"update",
    resource is Flovyn::WorkflowExecution
)
when {
    principal.tenantId == resource.tenantId &&
    principal.role == "MEMBER"
};

// =============================================================================
// WORKER POLICIES
// =============================================================================

// Workers can poll and execute workflows within their tenant
permit(
    principal is Flovyn::Worker,
    action in [
        Flovyn::Action::"poll",
        Flovyn::Action::"execute",
        Flovyn::Action::"complete",
        Flovyn::Action::"fail",
        Flovyn::Action::"heartbeat"
    ],
    resource
)
when {
    principal.tenantId == resource.tenantId
};

// Workers can view workflow definitions
permit(
    principal is Flovyn::Worker,
    action == Flovyn::Action::"view",
    resource is Flovyn::Workflow
)
when {
    principal.tenantId == resource.tenantId
};

// Workers can view and update workflow executions
permit(
    principal is Flovyn::Worker,
    action in [
        Flovyn::Action::"view",
        Flovyn::Action::"update"
    ],
    resource is Flovyn::WorkflowExecution
)
when {
    principal.tenantId == resource.tenantId
};

// Workers can create, view, and update task executions
permit(
    principal is Flovyn::Worker,
    action in [
        Flovyn::Action::"create",
        Flovyn::Action::"view",
        Flovyn::Action::"update"
    ],
    resource is Flovyn::TaskExecution
)
when {
    principal.tenantId == resource.tenantId
};

// =============================================================================
// SAFETY: FORBID CROSS-TENANT ACCESS
// =============================================================================

forbid(
    principal,
    action,
    resource
)
when {
    principal has tenantId &&
    resource has tenantId &&
    principal.tenantId != resource.tenantId
};
```

### Role-Based Access Control Matrix

| Role | Tenant | Workflow | WorkflowExecution | TaskExecution | Worker |
|------|--------|----------|-------------------|---------------|--------|
| **OWNER** | All | All | All | All | All |
| **ADMIN** | view, manage | view, create, update, delete, execute | view, update | view, update | view |
| **MEMBER** | view | view, execute | view, update | view | view |
| **Worker** | - | view | view, update, poll, complete, fail | create, view, update, poll, complete, fail, heartbeat | - |

## Configuration

```bash
# Select authorizer implementation
FLOVYN_SECURITY__AUTHORIZER=cedar  # Options: noop, tenant_scope, cedar

# Cedar-specific config (when authorizer=cedar)
FLOVYN_SECURITY__CEDAR__POLICY_PATH=/etc/flovyn/policies/  # Optional, defaults to embedded
```

## Migration Path

1. **Phase 1**: Add authorization calls to all endpoints using `TenantScopeAuthorizer` (current behavior preserved)
2. **Phase 2**: Switch to `CedarAuthorizer` in staging with permissive policies
3. **Phase 3**: Tune Cedar policies based on real usage, enable in production

### Rename Identity to Principal

The current `Identity` type should be renamed to `Principal` for consistency:
- The type already uses `principal_id` and `principal_type` fields
- Cedar uses "principal" terminology
- Avoids confusion between "identity" (authentication concept) and "principal" (authorization concept)

```rust
// Before: crates/core/src/auth/identity.rs
pub struct Identity {
    principal_type: PrincipalType,
    principal_id: String,
    tenant_id: Option<Uuid>,
    attributes: HashMap<String, String>,
}

// After: crates/core/src/auth/principal.rs
pub struct Principal {
    principal_type: PrincipalType,
    principal_id: String,
    tenant_id: Option<Uuid>,
    attributes: HashMap<String, String>,
}
```

### Principal Attribute Resolution (Implemented)

The `Principal` contains basic info (principal_id, principal_type, tenant_id), but authorization often needs additional context-specific attributes:
- **Roles** (RBAC): `role: "OWNER"`
- **Permissions** (fine-grained): `permissions: ["workflow:execute", "tenant:manage"]`
- **Custom attributes** (ABAC): `department: "engineering"`, `clearance: "secret"`

These attributes may be:
- Tenant-scoped (different roles in different tenants)
- Extracted from token claims
- Looked up from database
- Computed dynamically

We need a generic `PrincipalAttributeResolver` abstraction.

#### PrincipalAttributeResolver Trait

```rust
// crates/core/src/auth/attributes.rs

/// Additional attributes for a principal in a specific context.
/// These are passed to the Authorizer for policy evaluation.
#[derive(Debug, Clone, Default)]
pub struct PrincipalAttributes {
    attrs: HashMap<String, AttributeValue>,
}

#[derive(Debug, Clone)]
pub enum AttributeValue {
    String(String),
    StringList(Vec<String>),
    Bool(bool),
    Number(i64),
}

impl PrincipalAttributes {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_string(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.attrs.insert(key.into(), AttributeValue::String(value.into()));
        self
    }

    pub fn with_string_list(mut self, key: impl Into<String>, values: Vec<String>) -> Self {
        self.attrs.insert(key.into(), AttributeValue::StringList(values));
        self
    }

    /// Get string attribute (e.g., role)
    pub fn get_string(&self, key: &str) -> Option<&str> {
        match self.attrs.get(key) {
            Some(AttributeValue::String(s)) => Some(s),
            _ => None,
        }
    }

    /// Get string list attribute (e.g., permissions)
    pub fn get_string_list(&self, key: &str) -> Option<&[String]> {
        match self.attrs.get(key) {
            Some(AttributeValue::StringList(list)) => Some(list),
            _ => None,
        }
    }
}

/// Resolves additional attributes for a principal in a given context.
#[async_trait]
pub trait PrincipalAttributeResolver: Send + Sync {
    /// Resolve attributes for a principal within a tenant context.
    ///
    /// Returns attributes that should be added to the authorization context.
    /// Examples:
    /// - { "role": "OWNER" } for RBAC
    /// - { "permissions": ["workflow:execute", "tenant:read"] } for permissions
    /// - { "department": "engineering", "team": "platform" } for ABAC
    async fn resolve(
        &self,
        principal: &Principal,
        tenant_id: Uuid,
    ) -> Result<PrincipalAttributes, AttributeResolverError>;
}

#[derive(Debug, thiserror::Error)]
pub enum AttributeResolverError {
    #[error("Database error: {0}")]
    Database(String),
    #[error("Script error: {0}")]
    Script(String),
    #[error("Internal error: {0}")]
    Internal(String),
}
```

#### Implementations

| Implementation | Output | Use Case |
|----------------|--------|----------|
| `ClaimsAttributeResolver` | Extracts from token claims | Standard JWT with embedded attributes |
| `DatabaseAttributeResolver` | Queries database | Authoritative source for roles/permissions |
| `ScriptAttributeResolver` | Runs JavaScript | Complex extraction logic, custom IdPs |
| `CompositeAttributeResolver` | Merges multiple resolvers | Combine claims + database |
| `CachingAttributeResolver` | Wraps another resolver | Performance optimization |
| `NoOpAttributeResolver` | Returns empty | Workers (no additional attributes) |

##### ClaimsAttributeResolver (Rust)

Extracts attributes from token claims using configurable mappings:

```rust
// server/src/auth/attributes/claims.rs

/// Configuration for extracting a single attribute from claims.
#[derive(Debug, Clone)]
pub struct ClaimMapping {
    /// Target attribute name in PrincipalAttributes
    pub attribute: String,
    /// JSON path pattern in claims. Use `{tenant_id}` as placeholder.
    pub claims_path: String,
    /// How to interpret the extracted value
    pub value_type: ClaimValueType,
}

#[derive(Debug, Clone)]
pub enum ClaimValueType {
    String,
    StringList,  // JSON array -> Vec<String>
    Bool,
}

/// Extracts attributes from token claims using configurable mappings.
pub struct ClaimsAttributeResolver {
    mappings: Vec<ClaimMapping>,
}

impl ClaimsAttributeResolver {
    pub fn new(mappings: Vec<ClaimMapping>) -> Self {
        Self { mappings }
    }

    /// Default: extracts role from `tenant_roles.{tenant_id}`
    pub fn role_only() -> Self {
        Self::new(vec![ClaimMapping {
            attribute: "role".to_string(),
            claims_path: "tenant_roles.{tenant_id}".to_string(),
            value_type: ClaimValueType::String,
        }])
    }

    /// Extract both role and permissions
    pub fn role_and_permissions() -> Self {
        Self::new(vec![
            ClaimMapping {
                attribute: "role".to_string(),
                claims_path: "tenant_roles.{tenant_id}".to_string(),
                value_type: ClaimValueType::String,
            },
            ClaimMapping {
                attribute: "permissions".to_string(),
                claims_path: "tenant_permissions.{tenant_id}".to_string(),
                value_type: ClaimValueType::StringList,
            },
        ])
    }
}

#[async_trait]
impl PrincipalAttributeResolver for ClaimsAttributeResolver {
    async fn resolve(
        &self,
        principal: &Principal,
        tenant_id: Uuid,
    ) -> Result<PrincipalAttributes, AttributeResolverError> {
        let mut attrs = PrincipalAttributes::new();

        for mapping in &self.mappings {
            let path = mapping.claims_path.replace("{tenant_id}", &tenant_id.to_string());

            if let Some(value) = principal.attributes().get(&path) {
                match mapping.value_type {
                    ClaimValueType::String => {
                        attrs = attrs.with_string(&mapping.attribute, value);
                    }
                    ClaimValueType::StringList => {
                        // Parse JSON array from flattened claim
                        if let Ok(list) = serde_json::from_str::<Vec<String>>(value) {
                            attrs = attrs.with_string_list(&mapping.attribute, list);
                        }
                    }
                    ClaimValueType::Bool => {
                        if let Ok(b) = value.parse::<bool>() {
                            attrs.attrs.insert(
                                mapping.attribute.clone(),
                                AttributeValue::Bool(b),
                            );
                        }
                    }
                }
            }
        }

        Ok(attrs)
    }
}
```

##### ScriptAttributeResolver (Future - JavaScript)

For complex token formats or custom business logic:

```rust
// server/src/auth/attributes/script.rs (future)

/// Extracts attributes using embedded JavaScript.
pub struct ScriptAttributeResolver {
    script: String,
    runtime: JsRuntime,
}

#[async_trait]
impl PrincipalAttributeResolver for ScriptAttributeResolver {
    async fn resolve(
        &self,
        principal: &Principal,
        tenant_id: Uuid,
    ) -> Result<PrincipalAttributes, AttributeResolverError> {
        // Execute: extractAttributes(claims, tenantId) -> { role: "OWNER", permissions: [...] }
        let claims_json = serde_json::to_value(principal.attributes())?;
        let result = self.runtime.call(
            "extractAttributes",
            &[claims_json, tenant_id.to_string().into()],
        )?;

        // Convert JS object to PrincipalAttributes
        PrincipalAttributes::from_json(result)
    }
}
```

Example JavaScript scripts:

```javascript
// RBAC: extract role
function extractAttributes(claims, tenantId) {
    return {
        role: claims.organizations?.[tenantId]?.role || null
    };
}

// Permissions-based: extract fine-grained permissions
function extractAttributes(claims, tenantId) {
    const tenantPerms = claims.permissions
        ?.filter(p => p.tenant === tenantId)
        ?.map(p => p.name) || [];
    return {
        permissions: tenantPerms
    };
}

// Hybrid: both role and permissions
function extractAttributes(claims, tenantId) {
    const org = claims.organizations?.[tenantId] || {};
    return {
        role: org.role,
        permissions: org.permissions || [],
        department: claims.department,
        teams: claims.teams || []
    };
}

// Auth0 with custom namespace
function extractAttributes(claims, tenantId) {
    const ns = 'https://myapp.com/';
    return {
        role: claims[ns + 'roles']?.[tenantId],
        permissions: claims[ns + 'permissions']?.[tenantId] || []
    };
}
```

##### DatabaseAttributeResolver

```rust
// server/src/auth/attributes/database.rs

/// Resolves attributes from database.
pub struct DatabaseAttributeResolver {
    pool: PgPool,
}

#[async_trait]
impl PrincipalAttributeResolver for DatabaseAttributeResolver {
    async fn resolve(
        &self,
        principal: &Principal,
        tenant_id: Uuid,
    ) -> Result<PrincipalAttributes, AttributeResolverError> {
        let user_id = principal.principal_id();

        // Get role from tenant_member
        let member = sqlx::query!(
            "SELECT role FROM tenant_member WHERE tenant_id = $1 AND user_id = $2",
            tenant_id,
            user_id
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| AttributeResolverError::Database(e.to_string()))?;

        let mut attrs = PrincipalAttributes::new();

        if let Some(m) = member {
            attrs = attrs.with_string("role", m.role);
        }

        // Optionally: fetch permissions from a permissions table
        // let permissions = sqlx::query!(...).fetch_all(&self.pool).await?;
        // attrs = attrs.with_string_list("permissions", permissions);

        Ok(attrs)
    }
}
```

##### CompositeAttributeResolver

```rust
// server/src/auth/attributes/composite.rs

/// Combines multiple resolvers, merging their results.
/// Later resolvers override earlier ones for the same attribute.
pub struct CompositeAttributeResolver {
    resolvers: Vec<Arc<dyn PrincipalAttributeResolver>>,
}

#[async_trait]
impl PrincipalAttributeResolver for CompositeAttributeResolver {
    async fn resolve(
        &self,
        principal: &Principal,
        tenant_id: Uuid,
    ) -> Result<PrincipalAttributes, AttributeResolverError> {
        let mut merged = PrincipalAttributes::new();

        for resolver in &self.resolvers {
            let attrs = resolver.resolve(principal, tenant_id).await?;
            merged = merged.merge(attrs);
        }

        Ok(merged)
    }
}
```

#### Integration with AuthorizerExt

```rust
// server/src/auth/authorize.rs

#[async_trait]
pub trait AuthorizerExt: Authorizer {
    /// Require authorization with principal attribute resolution.
    async fn require_with_attrs(
        &self,
        principal: &Principal,
        attr_resolver: &dyn PrincipalAttributeResolver,
        action: &str,
        resource_type: &str,
        resource_id: &str,
        tenant_id: Uuid,
    ) -> Result<(), AuthzError> {
        // Resolve additional attributes for the principal
        let principal_attrs = attr_resolver
            .resolve(principal, tenant_id)
            .await
            .map_err(|e| AuthzError::Internal(e.to_string()))?;

        // Build context with all attributes
        let mut context = AuthzContext::new(action, resource_type, resource_id)
            .with_attr("tenantId", tenant_id.to_string());

        // Add resolved attributes (role, permissions, custom attrs)
        if let Some(role) = principal_attrs.get_string("role") {
            context = context.with_attr("role", role.to_string());
        }
        if let Some(perms) = principal_attrs.get_string_list("permissions") {
            context = context.with_attr("permissions", serde_json::to_string(perms).unwrap());
        }
        // ... add other attributes as needed

        match self.authorize(principal, &context).await? {
            Decision::Allow => Ok(()),
            Decision::Deny(reason) => Err(AuthzError::PermissionDenied(
                reason.unwrap_or_else(|| format!(
                    "Access denied: {} on {}::{}",
                    action, resource_type, resource_id
                ))
            )),
        }
    }
}
```

#### Cedar Policies - Different Styles

**RBAC (Role-Based):**
```cedar
permit(principal, action, resource)
when {
    principal.tenantId == resource.tenantId &&
    principal.role == "OWNER"
};
```

**Permissions-Based (Fine-Grained):**
```cedar
permit(principal, action == Flovyn::Action::"execute", resource is Flovyn::Workflow)
when {
    principal.tenantId == resource.tenantId &&
    principal.permissions.contains("workflow:execute")
};

permit(principal, action == Flovyn::Action::"manage", resource is Flovyn::Tenant)
when {
    principal.tenantId == resource.tenantId &&
    principal.permissions.contains("tenant:manage")
};
```

**ABAC (Attribute-Based):**
```cedar
// Only engineering department can execute ML workflows
permit(principal, action == Flovyn::Action::"execute", resource is Flovyn::Workflow)
when {
    principal.tenantId == resource.tenantId &&
    principal.department == "engineering" &&
    resource.category == "ml"
};
```

**Hybrid (Role + Permissions):**
```cedar
// Owners can do everything
permit(principal, action, resource)
when { principal.role == "OWNER" && principal.tenantId == resource.tenantId };

// Others need specific permissions
permit(principal, action == Flovyn::Action::"execute", resource is Flovyn::Workflow)
when {
    principal.tenantId == resource.tenantId &&
    principal.permissions.contains("workflow:execute")
};
```

#### Worker Handling

Workers don't need attribute resolution - their `PrincipalType::Worker` is sufficient:

```rust
async fn require_worker(
    &self,
    principal: &Principal,
    action: &str,
    resource_type: &str,
    resource_id: &str,
    tenant_id: Uuid,
) -> Result<(), AuthzError> {
    // Workers: no attribute resolution, just use principal type
    let context = AuthzContext::new(action, resource_type, resource_id)
        .with_attr("tenantId", tenant_id.to_string());

    match self.authorize(principal, &context).await? {
        Decision::Allow => Ok(()),
        Decision::Deny(reason) => Err(AuthzError::PermissionDenied(
            reason.unwrap_or_else(|| "Worker access denied".to_string())
        )),
    }
}
```

#### Configuration

```bash
# Attribute resolver type
FLOVYN_SECURITY__ATTR_RESOLVER__TYPE=claims  # Options: claims, database, script, composite, noop

# ClaimsAttributeResolver: define mappings
FLOVYN_SECURITY__ATTR_RESOLVER__MAPPINGS='[
  {"attribute": "role", "claims_path": "tenant_roles.{tenant_id}", "value_type": "string"},
  {"attribute": "permissions", "claims_path": "tenant_perms.{tenant_id}", "value_type": "string_list"}
]'

# ScriptAttributeResolver (future)
FLOVYN_SECURITY__ATTR_RESOLVER__SCRIPT_PATH=/etc/flovyn/extract-attrs.js

# CompositeAttributeResolver: chain multiple resolvers
FLOVYN_SECURITY__ATTR_RESOLVER__TYPE=composite
FLOVYN_SECURITY__ATTR_RESOLVER__CHAIN=claims,database  # Claims first, then database

# Cache settings
FLOVYN_SECURITY__ATTR_RESOLVER__CACHE_ENABLED=true
FLOVYN_SECURITY__ATTR_RESOLVER__CACHE_TTL_SECS=300
```

## Non-Goals

- External policy management UI
- Real-time policy hot-reload (future enhancement)
- Per-tenant custom policies (future enhancement)

## Open Questions

1. **Should we support "audit mode"?** Log authorization decisions without enforcing, useful for policy validation before enforcement.

2. **Which JavaScript runtime for ScriptAttributeResolver?** Options:
   - `rquickjs` - Lightweight, good for embedded use
   - `boa_engine` - Pure Rust, no native dependencies
   - `deno_core` - Full-featured, but heavier
