# Design Document: Metadata Schema Registry

## Problem Statement

The current metadata implementation allows arbitrary key-value pairs, but frontends have no way to discover:
1. What metadata keys are commonly used
2. What values are valid for each key (e.g., `env` should be `dev`, `staging`, `prod`)
3. Which keys are applicable to specific workflow/task types

This forces frontend developers to hardcode field names and valid values, leading to inconsistencies and poor discoverability.

## Goals

1. **Discoverability** - Frontend can query available metadata fields and their allowed values
2. **Flexibility** - Developers can still use arbitrary keys not in the registry (soft schema)
3. **Scoping** - Schemas can be defined globally or per workflow/task kind
4. **Type hints** - Support enum values, free-text, and basic validation hints

## Non-Goals

1. **Strict validation** - Registry is informational, not enforced (won't reject unknown keys)
2. **Complex types** - No nested objects, arrays, or relationships between fields
3. **Versioning** - No schema versioning for now

## Design

### Data Model

```sql
CREATE TABLE metadata_field_definition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),

    -- Scope: NULL = global, otherwise specific kind
    workflow_kind TEXT,  -- NULL means applies to all workflows
    task_kind TEXT,      -- NULL means applies to all tasks

    -- Field definition
    key TEXT NOT NULL,
    display_name TEXT,           -- Human-readable name for UI
    description TEXT,            -- Help text for users
    field_type TEXT NOT NULL,    -- 'enum', 'text', 'number', 'boolean'

    -- For enum types: allowed values as JSON array
    -- e.g., ["dev", "staging", "prod"]
    allowed_values JSONB,

    -- Ordering for UI display
    display_order INT DEFAULT 0,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT valid_scope CHECK (
        (workflow_kind IS NULL AND task_kind IS NULL) OR  -- global
        (workflow_kind IS NOT NULL AND task_kind IS NULL) OR  -- workflow-specific
        (workflow_kind IS NULL AND task_kind IS NOT NULL)     -- task-specific
    ),
    CONSTRAINT valid_field_type CHECK (
        field_type IN ('enum', 'text', 'number', 'boolean')
    ),
    CONSTRAINT enum_requires_values CHECK (
        field_type != 'enum' OR allowed_values IS NOT NULL
    ),

    UNIQUE (tenant_id, workflow_kind, task_kind, key)
);

CREATE INDEX idx_metadata_field_tenant ON metadata_field_definition(tenant_id);
CREATE INDEX idx_metadata_field_workflow ON metadata_field_definition(tenant_id, workflow_kind)
    WHERE workflow_kind IS NOT NULL;
CREATE INDEX idx_metadata_field_task ON metadata_field_definition(tenant_id, task_kind)
    WHERE task_kind IS NOT NULL;
```

### Domain Model

```rust
pub struct MetadataFieldDefinition {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub workflow_kind: Option<String>,
    pub task_kind: Option<String>,
    pub key: String,
    pub display_name: Option<String>,
    pub description: Option<String>,
    pub field_type: MetadataFieldType,
    pub allowed_values: Option<Vec<String>>,
    pub display_order: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub enum MetadataFieldType {
    Enum,    // Fixed set of values
    Text,    // Free-form string
    Number,  // Numeric value
    Boolean, // true/false
}
```

### REST API

#### List metadata fields

```
GET /api/tenants/{tenant_slug}/metadata-fields
GET /api/tenants/{tenant_slug}/metadata-fields?workflow_kind=order-workflow
GET /api/tenants/{tenant_slug}/metadata-fields?task_kind=send-email
```

Response:
```json
{
  "fields": [
    {
      "key": "env",
      "displayName": "Environment",
      "description": "Deployment environment",
      "fieldType": "enum",
      "allowedValues": ["dev", "staging", "prod"],
      "scope": "global",
      "displayOrder": 1
    },
    {
      "key": "region",
      "displayName": "Region",
      "description": "Geographic region",
      "fieldType": "enum",
      "allowedValues": ["us-east", "us-west", "eu-west", "ap-southeast"],
      "scope": "global",
      "displayOrder": 2
    },
    {
      "key": "customerId",
      "displayName": "Customer ID",
      "description": "Customer identifier for tracking",
      "fieldType": "text",
      "allowedValues": null,
      "scope": "workflow:order-workflow",
      "displayOrder": 3
    },
    {
      "key": "priority",
      "displayName": "Priority",
      "description": "Processing priority",
      "fieldType": "enum",
      "allowedValues": ["low", "normal", "high", "critical"],
      "scope": "global",
      "displayOrder": 4
    }
  ]
}
```

#### Create/Update metadata field

```
POST /api/tenants/{tenant_slug}/metadata-fields
```

Request:
```json
{
  "key": "env",
  "displayName": "Environment",
  "description": "Deployment environment",
  "fieldType": "enum",
  "allowedValues": ["dev", "staging", "prod"],
  "workflowKind": null,
  "taskKind": null,
  "displayOrder": 1
}
```

#### Delete metadata field

```
DELETE /api/tenants/{tenant_slug}/metadata-fields/{field_id}
```

### Resolution Logic

When querying fields for a specific workflow/task kind, merge in priority order:

1. **Kind-specific fields** - Fields defined for that exact workflow/task kind
2. **Global fields** - Fields with `workflow_kind = NULL AND task_kind = NULL`

If same key exists at both levels, kind-specific definition wins.

```rust
pub async fn get_fields_for_workflow(
    &self,
    tenant_id: Uuid,
    workflow_kind: &str,
) -> Result<Vec<MetadataFieldDefinition>, Error> {
    // Query both global and kind-specific, merge with kind-specific priority
    sqlx::query_as(r#"
        SELECT DISTINCT ON (key) *
        FROM metadata_field_definition
        WHERE tenant_id = $1
          AND (workflow_kind IS NULL OR workflow_kind = $2)
          AND task_kind IS NULL
        ORDER BY key, workflow_kind NULLS LAST
    "#)
    .bind(tenant_id)
    .bind(workflow_kind)
    .fetch_all(&self.pool)
    .await
}
```

### Frontend Integration

Frontend filter UI workflow:

1. User selects workflow kind (e.g., "order-workflow")
2. Frontend calls `GET /metadata-fields?workflow_kind=order-workflow`
3. For each field:
   - `enum` type → render dropdown with `allowedValues`
   - `text` type → render text input
   - `number` type → render number input
   - `boolean` type → render checkbox/toggle
4. User selects filters
5. Frontend constructs metadata filter: `{"env": "prod", "customerId": "CUST-123"}`

### Behavior Matrix

| Scenario | Behavior |
|----------|----------|
| Metadata key in registry | Show in filter UI with type hints |
| Metadata key NOT in registry | Still allowed, just not shown in filter UI |
| Enum value not in allowedValues | Still allowed (soft schema), but may show warning |
| Query with unknown key | Works normally via JSONB containment |

### Seeding Common Fields

Provide a default set of common fields that tenants can adopt:

```rust
pub fn default_global_fields() -> Vec<MetadataFieldDefinition> {
    vec![
        MetadataFieldDefinition {
            key: "env".to_string(),
            display_name: Some("Environment".to_string()),
            field_type: MetadataFieldType::Enum,
            allowed_values: Some(vec!["dev", "staging", "prod"]),
            ..Default::default()
        },
        MetadataFieldDefinition {
            key: "region".to_string(),
            display_name: Some("Region".to_string()),
            field_type: MetadataFieldType::Enum,
            allowed_values: Some(vec!["us-east", "us-west", "eu-west", "ap-southeast"]),
            ..Default::default()
        },
        MetadataFieldDefinition {
            key: "priority".to_string(),
            display_name: Some("Priority".to_string()),
            field_type: MetadataFieldType::Enum,
            allowed_values: Some(vec!["low", "normal", "high", "critical"]),
            ..Default::default()
        },
    ]
}
```

Admin can seed these via CLI or API during tenant setup.

## Alternatives Considered

### 1. Materialized View of Distinct Keys

**Approach**: Query existing metadata to discover keys dynamically.

**Pros**: No configuration needed, always up-to-date with actual usage.

**Cons**:
- No type hints or allowed values
- Performance impact on large datasets
- Can't show unused-but-valid values

**Decision**: Rejected. Doesn't solve the enum values problem.

### 2. Strict Schema Validation

**Approach**: Reject metadata with unknown keys or invalid values.

**Pros**: Data consistency guaranteed.

**Cons**:
- Breaking change for existing users
- Reduces flexibility
- Requires schema updates before using new keys

**Decision**: Rejected. Flexibility is more important than strict validation.

### 3. Schema in Configuration File

**Approach**: Define schema in YAML/JSON config file deployed with server.

**Pros**: Version controlled, no database needed.

**Cons**:
- Requires server restart to update
- Can't be tenant-specific
- Harder for non-developers to manage

**Decision**: Rejected. Database-backed registry is more flexible.

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Create migration for `metadata_field_definition` table
- [ ] Add domain model and repository
- [ ] Implement CRUD REST endpoints
- [ ] Add OpenAPI documentation

### Phase 2: Query Integration
- [ ] Add `GET /metadata-fields` with kind filtering
- [ ] Implement field resolution logic (merge global + kind-specific)
- [ ] Add to workflow/task list response as optional field

### Phase 3: Seeding & Management
- [ ] Create default field templates
- [ ] Add CLI command to seed common fields
- [ ] Add admin UI for field management (if applicable)

## Open Questions

1. **Should we track field usage?** Could add `last_used_at` or `usage_count` to help identify stale fields.

2. **Inheritance for child workflows?** Should child workflows inherit parent's metadata field definitions?

3. **Field groups?** Should we support grouping related fields (e.g., "Customer Info", "Environment")?
