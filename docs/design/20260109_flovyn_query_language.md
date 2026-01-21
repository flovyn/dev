# Design Document: Flovyn Query Language (FQL)

## Problem Statement

Current filtering capabilities are limited to simple equality filters via query parameters. Users need:
1. Complex queries with AND/OR logic
2. Comparison operators (>, <, >=, <=, !=)
3. Text search and pattern matching
4. Date/time relative queries (e.g., "last 7 days")
5. Metadata field queries
6. Ability to save and reuse common queries

## Goals

1. **Expressive** - Support complex boolean logic, comparisons, and metadata queries
2. **Familiar** - Syntax inspired by JQL (Jira Query Language) for ease of adoption
3. **Safe** - Prevent SQL injection, limit resource usage
4. **Saveable** - Users can save, name, and share queries
5. **Extensible** - Easy to add new fields and operators

## Non-Goals

1. **Full SQL** - Not a general-purpose SQL interface
2. **Joins** - No cross-entity queries (e.g., can't join workflows and tasks)
3. **Aggregations** - No GROUP BY, COUNT, SUM (use dedicated analytics)
4. **Subqueries** - No nested queries

## Query Language Specification

### Basic Syntax

```
<field> <operator> <value> [AND|OR <field> <operator> <value>...]
[ORDER BY <field> [ASC|DESC]]
```

### Supported Fields

#### Workflow Executions

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Workflow execution ID |
| `kind` | string | Workflow type |
| `status` | enum | PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED |
| `queue` | string | Task queue name |
| `version` | string | Workflow version |
| `createdAt` | datetime | Creation timestamp |
| `startedAt` | datetime | Execution start timestamp |
| `completedAt` | datetime | Completion timestamp |
| `updatedAt` | datetime | Last update timestamp |
| `metadata.<key>` | any | Metadata field access |

#### Task Executions

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Task execution ID |
| `kind` | string | Task type |
| `status` | enum | PENDING, RUNNING, COMPLETED, FAILED, CANCELLED |
| `queue` | string | Task queue name |
| `attempt` | number | Current attempt number |
| `maxRetries` | number | Maximum retry count |
| `workflowId` | UUID | Parent workflow ID (null for standalone) |
| `createdAt` | datetime | Creation timestamp |
| `startedAt` | datetime | Execution start timestamp |
| `completedAt` | datetime | Completion timestamp |
| `metadata.<key>` | any | Metadata field access |

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Equals | `status = "COMPLETED"` |
| `!=` | Not equals | `status != "FAILED"` |
| `>` | Greater than | `createdAt > "2024-01-01"` |
| `>=` | Greater than or equal | `attempt >= 2` |
| `<` | Less than | `completedAt < "2024-12-31"` |
| `<=` | Less than or equal | `maxRetries <= 3` |
| `IN` | In list | `status IN ("PENDING", "RUNNING")` |
| `NOT IN` | Not in list | `status NOT IN ("COMPLETED", "CANCELLED")` |
| `~` | Contains (text) | `kind ~ "order"` |
| `!~` | Not contains | `kind !~ "test"` |
| `IS NULL` | Is null | `completedAt IS NULL` |
| `IS NOT NULL` | Is not null | `metadata.customerId IS NOT NULL` |

### Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `AND` | Both conditions must be true | `status = "COMPLETED" AND kind = "order"` |
| `OR` | Either condition must be true | `status = "FAILED" OR status = "CANCELLED"` |
| `NOT` | Negation | `NOT status = "COMPLETED"` |
| `(...)` | Grouping | `(status = "FAILED" OR status = "CANCELLED") AND kind = "order"` |

### Date/Time Functions

| Function | Description | Example |
|----------|-------------|---------|
| `NOW()` | Current timestamp | `createdAt < NOW()` |
| `TODAY()` | Start of today | `createdAt >= TODAY()` |
| `-Nd` | N days ago | `createdAt >= -7d` |
| `-Nh` | N hours ago | `createdAt >= -24h` |
| `-Nm` | N minutes ago | `updatedAt >= -30m` |

### Metadata Queries

Access metadata fields using dot notation:

```fql
metadata.customerId = "CUST-123"
metadata.env IN ("staging", "prod")
metadata.priority = "high" AND metadata.region = "us-east"
```

### Ordering

```fql
status = "COMPLETED" ORDER BY completedAt DESC
kind ~ "order" ORDER BY createdAt ASC
```

### Examples

```fql
# All failed workflows in the last 24 hours
status = "FAILED" AND createdAt >= -24h

# Order workflows for a specific customer in production
kind = "order-workflow" AND metadata.customerId = "CUST-123" AND metadata.env = "prod"

# Tasks with retries, excluding completed
attempt >= 2 AND status NOT IN ("COMPLETED", "CANCELLED")

# Workflows stuck in RUNNING for more than 1 hour
status = "RUNNING" AND startedAt < -1h

# Complex query with grouping
(status = "FAILED" OR status = "CANCELLED") AND createdAt >= -7d AND metadata.priority = "high"
ORDER BY createdAt DESC

# Standalone tasks (no parent workflow)
workflowId IS NULL AND status = "PENDING"
```

## Data Model

### Saved Queries

```sql
CREATE TABLE saved_query (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),

    -- Query metadata
    name TEXT NOT NULL,
    description TEXT,

    -- Target entity
    entity_type TEXT NOT NULL,  -- 'workflow', 'task'

    -- The FQL query string
    query TEXT NOT NULL,

    -- Visibility
    is_shared BOOLEAN NOT NULL DEFAULT false,  -- Visible to all tenant users
    created_by TEXT,  -- User identifier

    -- Usage tracking
    use_count INT NOT NULL DEFAULT 0,
    last_used_at TIMESTAMPTZ,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_saved_query_tenant ON saved_query(tenant_id);
CREATE INDEX idx_saved_query_entity ON saved_query(tenant_id, entity_type);
```

### Domain Model

```rust
pub struct SavedQuery {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub entity_type: QueryEntityType,
    pub query: String,
    pub is_shared: bool,
    pub created_by: Option<String>,
    pub use_count: i32,
    pub last_used_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub enum QueryEntityType {
    Workflow,
    Task,
}
```

## REST API

### Execute Query

```
POST /api/tenants/{tenant_slug}/query
```

Request:
```json
{
  "entity": "workflow",
  "query": "status = \"FAILED\" AND createdAt >= -24h ORDER BY createdAt DESC",
  "limit": 50,
  "offset": 0
}
```

Response:
```json
{
  "results": [
    {
      "id": "...",
      "kind": "order-workflow",
      "status": "FAILED",
      "createdAt": "2024-01-15T10:30:00Z",
      "metadata": {"customerId": "CUST-123"}
    }
  ],
  "total": 127,
  "limit": 50,
  "offset": 0,
  "query": "status = \"FAILED\" AND createdAt >= -24h ORDER BY createdAt DESC"
}
```

### Validate Query (without executing)

```
POST /api/tenants/{tenant_slug}/query/validate
```

Request:
```json
{
  "entity": "workflow",
  "query": "status = \"INVALID\""
}
```

Response (error):
```json
{
  "valid": false,
  "errors": [
    {
      "position": 10,
      "message": "Invalid status value 'INVALID'. Valid values: PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED"
    }
  ]
}
```

### Saved Queries CRUD

```
# List saved queries
GET /api/tenants/{tenant_slug}/saved-queries
GET /api/tenants/{tenant_slug}/saved-queries?entity=workflow

# Get saved query
GET /api/tenants/{tenant_slug}/saved-queries/{query_id}

# Create saved query
POST /api/tenants/{tenant_slug}/saved-queries
{
  "name": "Failed orders last week",
  "description": "Order workflows that failed in the past 7 days",
  "entity": "workflow",
  "query": "kind = \"order-workflow\" AND status = \"FAILED\" AND createdAt >= -7d",
  "isShared": true
}

# Update saved query
PUT /api/tenants/{tenant_slug}/saved-queries/{query_id}

# Delete saved query
DELETE /api/tenants/{tenant_slug}/saved-queries/{query_id}

# Execute saved query
POST /api/tenants/{tenant_slug}/saved-queries/{query_id}/execute
{
  "limit": 50,
  "offset": 0,
  "overrides": {
    "metadata.customerId": "CUST-456"  // Optional: override specific values
  }
}
```

## Parser Implementation

### Architecture

```
FQL Query String
      │
      ▼
┌─────────────┐
│   Lexer     │  Tokenize: keywords, operators, values
└─────────────┘
      │
      ▼
┌─────────────┐
│   Parser    │  Build AST (Abstract Syntax Tree)
└─────────────┘
      │
      ▼
┌─────────────┐
│  Validator  │  Check field names, types, values
└─────────────┘
      │
      ▼
┌─────────────┐
│ SQL Builder │  Generate parameterized SQL
└─────────────┘
      │
      ▼
 Parameterized SQL + Values
```

### AST Structure

```rust
pub enum Expr {
    // Comparison: field op value
    Comparison {
        field: Field,
        op: ComparisonOp,
        value: Value,
    },
    // Binary: expr AND/OR expr
    Binary {
        left: Box<Expr>,
        op: BinaryOp,
        right: Box<Expr>,
    },
    // Unary: NOT expr
    Not(Box<Expr>),
    // Grouping: (expr)
    Group(Box<Expr>),
}

pub enum Field {
    Simple(String),           // e.g., "status"
    Metadata(String),         // e.g., "metadata.customerId"
}

pub enum ComparisonOp {
    Eq, Ne, Gt, Gte, Lt, Lte,
    In, NotIn,
    Contains, NotContains,
    IsNull, IsNotNull,
}

pub enum BinaryOp {
    And,
    Or,
}

pub enum Value {
    String(String),
    Number(f64),
    Boolean(bool),
    List(Vec<Value>),
    DateTime(DateTime<Utc>),
    RelativeTime(RelativeTime),  // -7d, -24h
    Function(String),            // NOW(), TODAY()
    Null,
}

pub struct Query {
    pub filter: Option<Expr>,
    pub order_by: Option<OrderBy>,
}

pub struct OrderBy {
    pub field: Field,
    pub direction: OrderDirection,
}
```

### SQL Generation

```rust
impl Query {
    pub fn to_sql(&self, entity: QueryEntityType) -> (String, Vec<SqlParam>) {
        let table = match entity {
            QueryEntityType::Workflow => "workflow_execution",
            QueryEntityType::Task => "task_execution",
        };

        let mut params = Vec::new();
        let mut sql = format!("SELECT * FROM {} WHERE tenant_id = $1", table);
        params.push(SqlParam::Uuid(tenant_id));

        if let Some(filter) = &self.filter {
            let (where_clause, filter_params) = filter.to_sql(&mut params.len());
            sql.push_str(" AND ");
            sql.push_str(&where_clause);
            params.extend(filter_params);
        }

        if let Some(order) = &self.order_by {
            sql.push_str(&format!(" ORDER BY {} {}",
                order.field.to_column(),
                order.direction.to_sql()
            ));
        }

        (sql, params)
    }
}

impl Expr {
    pub fn to_sql(&self, param_offset: &mut usize) -> (String, Vec<SqlParam>) {
        match self {
            Expr::Comparison { field, op, value } => {
                let column = field.to_column();
                *param_offset += 1;
                let param_num = *param_offset;

                let sql = match op {
                    ComparisonOp::Eq => format!("{} = ${}", column, param_num),
                    ComparisonOp::Ne => format!("{} != ${}", column, param_num),
                    ComparisonOp::Contains => format!("{} ILIKE ${}", column, param_num),
                    ComparisonOp::IsNull => format!("{} IS NULL", column),
                    // ... other operators
                };

                (sql, vec![value.to_param()])
            }
            Expr::Binary { left, op, right } => {
                let (left_sql, left_params) = left.to_sql(param_offset);
                let (right_sql, right_params) = right.to_sql(param_offset);
                let op_str = match op {
                    BinaryOp::And => "AND",
                    BinaryOp::Or => "OR",
                };
                (
                    format!("({} {} {})", left_sql, op_str, right_sql),
                    [left_params, right_params].concat()
                )
            }
            // ... other variants
        }
    }
}

impl Field {
    pub fn to_column(&self) -> String {
        match self {
            Field::Simple(name) => {
                // Map camelCase to snake_case
                match name.as_str() {
                    "createdAt" => "created_at".to_string(),
                    "startedAt" => "started_at".to_string(),
                    "completedAt" => "completed_at".to_string(),
                    "updatedAt" => "updated_at".to_string(),
                    "workflowId" => "workflow_execution_id".to_string(),
                    "maxRetries" => "max_retries".to_string(),
                    _ => name.to_string(),
                }
            }
            Field::Metadata(key) => {
                // JSONB access: metadata->>'key'
                format!("metadata->>'{}'", key)
            }
        }
    }
}
```

## Security Considerations

### SQL Injection Prevention

1. **Parameterized queries** - All values are bound as parameters, never interpolated
2. **Field whitelist** - Only allowed fields can be queried
3. **Operator whitelist** - Only defined operators are valid
4. **Value validation** - Enum fields validate against allowed values

### Resource Limits

```rust
pub struct QueryLimits {
    pub max_query_length: usize,      // 4KB
    pub max_expressions: usize,        // 50 conditions
    pub max_in_list_size: usize,       // 100 values
    pub max_results: usize,            // 1000 rows
    pub query_timeout_seconds: u64,    // 30 seconds
}
```

### Rate Limiting

- Query execution: 100 requests/minute per tenant
- Saved query creation: 10 requests/minute per user

## Frontend Integration

### Query Builder UI

Frontend can provide a visual query builder that generates FQL:

```
┌─────────────────────────────────────────────────────────────┐
│  + Add Filter                                               │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐ ┌────┐ ┌──────────────┐                       │
│  │ status ▼│ │ = ▼│ │ FAILED     ▼│  [×]                   │
│  └─────────┘ └────┘ └──────────────┘                       │
│                                              [AND ▼]        │
│  ┌─────────────────┐ ┌────┐ ┌──────────────┐               │
│  │ metadata.env  ▼ │ │ = ▼│ │ prod       ▼│  [×]           │
│  └─────────────────┘ └────┘ └──────────────┘               │
│                                              [AND ▼]        │
│  ┌─────────────┐ ┌─────┐ ┌──────────────┐                  │
│  │ createdAt ▼ │ │ >= ▼│ │ -7d          │  [×]             │
│  └─────────────┘ └─────┘ └──────────────┘                  │
├─────────────────────────────────────────────────────────────┤
│  FQL: status = "FAILED" AND metadata.env = "prod" AND ...   │
├─────────────────────────────────────────────────────────────┤
│  [Save Query]  [Execute]                                    │
└─────────────────────────────────────────────────────────────┘
```

### Autocomplete Support

```
GET /api/tenants/{tenant_slug}/query/autocomplete
```

Request:
```json
{
  "entity": "workflow",
  "partial": "meta",
  "position": 0
}
```

Response:
```json
{
  "suggestions": [
    {"value": "metadata.", "type": "field", "description": "Access metadata fields"},
    {"value": "metadata.customerId", "type": "field", "description": "Customer ID"},
    {"value": "metadata.env", "type": "field", "description": "Environment"}
  ]
}
```

## Alternatives Considered

### 1. GraphQL

**Pros**: Standard query language, good tooling, type-safe.

**Cons**:
- Overkill for filtering use case
- Requires significant infrastructure
- Steeper learning curve for non-developers

**Decision**: Rejected. FQL is simpler and more focused.

### 2. OData Query Syntax

**Pros**: Industry standard, well-documented.

**Cons**:
- Verbose syntax: `$filter=status eq 'FAILED' and createdAt gt 2024-01-01`
- Less readable than JQL-style

**Decision**: Rejected. JQL syntax is more user-friendly.

### 3. JSON-based Query DSL (like Elasticsearch)

**Pros**: Easy to parse, no custom grammar needed.

**Cons**:
- Not human-readable/writable
- Requires UI to build queries
- Example: `{"and": [{"field": "status", "op": "eq", "value": "FAILED"}]}`

**Decision**: Rejected. Users should be able to type queries directly.

## Implementation Phases

### Phase 1: Core Parser
- [ ] Implement lexer (tokenizer)
- [ ] Implement parser (AST builder)
- [ ] Implement SQL generator
- [ ] Add field/operator validation
- [ ] Unit tests for parser

### Phase 2: Query Execution
- [ ] Add POST /query endpoint
- [ ] Add POST /query/validate endpoint
- [ ] Implement query limits and timeouts
- [ ] Add rate limiting

### Phase 3: Saved Queries
- [ ] Create saved_query table migration
- [ ] Implement saved query CRUD
- [ ] Add execute saved query endpoint
- [ ] Track query usage statistics

### Phase 4: Developer Experience
- [ ] Add autocomplete endpoint
- [ ] Integrate with metadata schema registry
- [ ] Add query examples to API docs
- [ ] Frontend query builder component

## Open Questions

1. **Query parameterization?** Should saved queries support placeholders like `metadata.customerId = {customerId}` that users fill in at execution time?

2. **Query sharing across tenants?** Should there be "template queries" that exist globally?

3. **Query history?** Should we track recently executed queries per user for quick re-execution?

4. **Export results?** Should query results be exportable to CSV/JSON?
