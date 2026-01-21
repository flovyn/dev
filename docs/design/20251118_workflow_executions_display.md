# Workflow Executions Display - Design Document

## Overview

This document outlines the design for displaying workflow executions from the server in the Flovyn application. The system provides comprehensive visibility into workflow execution across the platform with real-time updates, filtering, and detailed execution analytics.

**Note:** The terminology has been updated from "workflow run" to "workflow execution" throughout the platform to align with the server API.

## Current State Analysis

### Existing Implementation

The codebase already has a solid foundation for workflow executionvisualization:

**Pages:**
- `/tenant/{slug}/executions` - Executions listing page (apps/web/app/tenant/[tenantSlug]/executions/page.tsx)
- `/tenant/{slug}/executions/{executionId}` - Execution detail page with tabs (apps/web/app/tenant/[tenantSlug]/executions/[executionId]/page.tsx)
- `/tenant/{slug}/workflows` - Workflows listing (apps/web/app/tenant/[tenantSlug]/workflows/page.tsx)
- `/tenant/{slug}/workflows/{workflowId}` - Workflow detail (apps/web/app/tenant/[tenantSlug]/workflows/[workflowId]/page.tsx)

**Components:**
- `ExecutionsTable` (apps/web/components/executions/ExecutionsTable.tsx) - Table display with sorting/filtering
- `ExecutionOverview` (apps/web/components/executions/ExecutionOverview.tsx) - Summary, input/output display
- `ExecutionStatusBadge` (apps/web/components/executions/ExecutionStatusBadge.tsx) - Status visualization
- `ExecutionsFilterBar` (apps/web/components/executions/ExecutionsFilterBar.tsx) - Filter controls
- `GanttTimeline` (apps/web/components/events/GanttTimeline.tsx) - Advanced execution timeline
- `WorkflowsTable` (apps/web/components/workflows/WorkflowsTable.tsx) - Workflow listing

**Data Layer:**
- API Client (apps/web/lib/api/client.ts) - HTTP client using `ky` with auth/retry
- Query Definitions (apps/web/lib/api/queries.ts) - React Query hooks for all endpoints
- Mock Client (apps/web/lib/api/mock-client.ts) - Development mock data
- Type Definitions (apps/web/lib/types/workflow.ts) - TypeScript interfaces

**Key Data Types:**
```typescript
interface WorkflowRunView {
  id: string;
  workflowId: string;
  workflowName: string;
  version: number;
  status: 'PENDING' | 'RUNNING' | 'SUSPENDED' | 'COMPLETED' | 'FAILED' | 'CANCELLED';
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
  triggeredBy: string;
  input: any;
  output: any;
  tags: Record<string, string>;
}

interface EventGroup {
  id: string;
  type: 'WORKFLOW' | 'OPERATION' | 'TASK' | 'STATE_OPERATION' | 'PROMISE' | 'SUB_WORKFLOW';
  name: string;
  startEvent: WorkflowEventView;
  endEvent: WorkflowEventView | null;
  status: 'PENDING' | 'RUNNING' | 'COMPLETED' | 'FAILED';
  duration: number | null;
  events: WorkflowEventView[];
  children?: EventGroup[];
}

interface TaskExecutionView {
  id: string;
  taskName: string;
  workflowRunId: string;
  status: TaskStatus;
  input: any;
  output: any;
  error: any;
  progress?: { current: number; total: number; message: string };
}
```

### What's Missing

1. **Real Server Integration** - Currently using mock client, needs backend API connection
2. **Real-time Updates** - WebSocket/SSE available but not integrated
3. **Cross-tenant Views** - No aggregated view across all organizations
4. **Advanced Analytics** - No metrics/statistics on workflow performance
5. **Bulk Operations** - No multi-select for canceling/retrying executions
6. **Export Functionality** - No CSV/JSON export of execution data
7. **Enhanced Search** - Limited to status/workflow filters only

### Available Server APIs (from OpenAPI Spec)

The server provides comprehensive APIs for workflow and task discovery, as well as execution management:

#### Workflow Discovery APIs
```
GET    /api/v1/tenants/{tenantSlug}/workflows
       - List all workflows (code-first and visual)

GET    /api/v1/tenants/{tenantSlug}/workflows/{kind}
       - Get workflow by kind identifier

PATCH  /api/v1/tenants/{tenantSlug}/workflows/{kind}/configuration
       - Update workflow configuration (timeout, retry policy, tags)

GET    /api/v1/tenants/{tenantSlug}/spaces/{spaceSlug}/workflows
       - List workflows in a specific space

GET    /api/v1/tenants/{tenantSlug}/spaces/{spaceSlug}/workflows/{kind}
       - Get workflow by kind in a specific space
```

**WorkflowDefinition Response:**
```typescript
{
  id: string;              // UUID
  tenantId: string;        // UUID
  spaceId?: string;        // UUID (optional)
  kind: string;            // Workflow identifier
  name: string;
  description?: string;
  workflowType: 'CODE_FIRST' | 'VISUAL';
  discoverySource: 'REGISTRATION' | 'EXECUTION';
  timeoutSeconds?: number;
  retryPolicy?: object;
  tags?: string[];
  definition?: string;     // JSON for visual workflows
  version: number;
  availabilityStatus: 'AVAILABLE' | 'UNAVAILABLE' | 'DEGRADED';
  firstSeenAt: number;     // Unix timestamp
  lastRegisteredAt?: number;
  archivedAt?: number;
  metadata?: object;
}
```

#### Task Discovery APIs
```
GET    /api/v1/tenants/{tenantSlug}/tasks
       - List all tasks registered by workers

GET    /api/v1/tenants/{tenantSlug}/tasks/{kind}
       - Get task by kind identifier

PATCH  /api/v1/tenants/{tenantSlug}/tasks/{kind}/configuration
       - Update task configuration

GET    /api/v1/tenants/{tenantSlug}/spaces/{spaceSlug}/tasks
       - List tasks in a specific space

GET    /api/v1/tenants/{tenantSlug}/spaces/{spaceSlug}/tasks/{kind}
       - Get task by kind in a specific space

GET    /api/v1/tenants/{tenantSlug}/visual-workflow-builder/available-tasks
       - List tasks available for visual workflow builder
```

**TaskDefinition Response:**
```typescript
{
  id: string;              // UUID
  tenantId: string;        // UUID
  spaceId?: string;        // UUID (optional)
  kind: string;            // Task identifier
  name: string;
  description?: string;
  discoverySource: 'REGISTRATION' | 'EXECUTION';
  timeoutSeconds?: number;
  retryPolicy?: object;
  tags?: string[];
  inputSchema?: object;    // JSON Schema
  outputSchema?: object;   // JSON Schema
  availabilityStatus: 'AVAILABLE' | 'UNAVAILABLE' | 'DEGRADED';
  firstSeenAt: number;
  lastRegisteredAt?: number;
  archivedAt?: number;
  metadata?: object;
}
```

#### Worker Discovery APIs
```
GET    /api/v1/tenants/{tenantSlug}/workers
       - List all registered workers

GET    /api/v1/tenants/{tenantSlug}/workers/{workerId}
       - Get worker details with capabilities

GET    /api/v1/tenants/{tenantSlug}/spaces/{spaceSlug}/workers
       - List workers in a specific space
```

**Worker Response:**
```typescript
{
  id: string;              // UUID
  tenantId: string;
  spaceId?: string;
  workerName: string;
  workerVersion?: string;
  workerType: 'WORKFLOW' | 'TASK' | 'UNIFIED';
  status: 'ONLINE' | 'OFFLINE' | 'DEGRADED';
  hostName?: string;
  processId?: string;
  registeredAt: number;
  lastHeartbeatAt: number;
  metadata?: object;
}
```

#### Workflow Execution APIs
```
POST   /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/cancel
       - Cancel a running workflow execution

GET    /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/children
       - Get child workflows of an execution

GET    /api/tenants/{tenantSlug}/stream/workflows/{workflowExecutionId}
       - Stream workflow execution updates (SSE)

GET    /api/tenants/{tenantSlug}/stream/workflows/{workflowExecutionId}/consolidated
       - Stream consolidated execution updates (SSE)
```

#### Promise Management APIs
```
POST   /api/tenants/{tenantSlug}/workflows/{workflowExecutionId}/promises/{promiseName}/resolve
       - Resolve a workflow promise

POST   /api/tenants/{tenantSlug}/workflows/{workflowExecutionId}/promises/{promiseName}/reject
       - Reject a workflow promise
```

#### Trigger & Event APIs
```
GET    /api/tenants/{tenantSlug}/triggers
       - List all triggers

POST   /api/tenants/{tenantSlug}/triggers
       - Create workflow trigger

GET    /api/tenants/{tenantSlug}/triggers/{triggerId}/executions
       - Get execution history for a trigger

POST   /api/tenants/{tenantSlug}/events
       - Ingest CloudEvent to trigger workflows
```

## Design Goals

1. **Real-time Visibility** - Live updates for running workflows without manual refresh
2. **Performance at Scale** - Handle hundreds of concurrent executionsefficiently
3. **Rich Context** - Provide comprehensive execution details and timeline
4. **Multi-tenant Support** - Work seamlessly across organization boundaries
5. **Developer Experience** - Clear error states, logs, and debugging information
6. **Mobile Responsive** - Functional on all screen sizes

## Architecture

### Display Locations

#### 1. Tenant Dashboard (`/tenant/{slug}`)
**Purpose:** Quick overview of recent activity within an organization

**Components:**
- Recent Executions Widget (last 10 runs)
- Execution Status Summary (counts by status)
- Active Workflows Count
- Quick filters (Today, This Week, Failed Only)

**Implementation:**
```typescript
// apps/web/app/tenant/[tenantSlug]/page.tsx
<DashboardWidget title="Recent Workflow Executions">
  <RunStatusSummary />
  <RecentExecutionsList limit={10} />
</DashboardWidget>
```

#### 2. Executions Listing Page (`/tenant/{slug}/runs`)
**Purpose:** Comprehensive list of all workflow executionswith advanced filtering

**Features:**
- Paginated table (50 executionsper page)
- Real-time status updates
- Multi-column sorting
- Advanced filtering:
  - Status (PENDING, RUNNING, COMPLETED, FAILED, CANCELLED, SUSPENDED)
  - Workflow (dropdown of all workflows)
  - Date range picker
  - Triggered by (user filter)
  - Tags (key-value search)
- Bulk actions (Cancel, Retry)
- Export (CSV, JSON)

**Enhanced Implementation:**
```typescript
// Enhanced ExecutionsTable with server integration
const ExecutionsPage = () => {
  const { data, isLoading, refetch } = useQuery(executionQueries.list({
    status,
    workflowId,
    dateFrom,
    dateTo,
    triggeredBy,
    tags,
    page,
    pageSize: 50
  }));

  // WebSocket for real-time updates
  useExecutionsSubscription({
    onUpdate: (executionId) => {
      queryClient.invalidateQueries(['runs', executionId]);
    }
  });

  return (
    <div>
      <ExecutionsFilterBar />
      <ExecutionsTable data={data} />
      <Pagination />
    </div>
  );
};
```

#### 3. Execution Detail Page (`/tenant/{slug}/runs/{executionId}`)
**Purpose:** Deep dive into single executionexecution with full event timeline

**Tabs:**
1. **Overview**
   - Status card with timestamps
   - Input/Output JSON viewers
   - Gantt timeline visualization
   - Quick actions (Cancel, Retry, Export)

2. **Events**
   - Chronological event list
   - Event type filtering
   - Search within events
   - Expandable event details

3. **Tasks**
   - Task execution list
   - Task logs viewer
   - Task progress indicators
   - Error details for failed tasks

4. **Context**
   - Executiontime context/state
   - Environment variables
   - Workflow version info
   - Triggered by details

**Enhanced Features:**
- Auto-refresh for RUNNING status
- Timeline scrubber for large executions
- Event export (JSON, logs format)
- Share link with time position

#### 4. Cross-tenant View (`/runs` - Global)
**Purpose:** Aggregated view across all organizations (admin/power users)

**Features:**
- Organization column in table
- Filter by tenant
- Aggregated statistics
- Performance metrics across tenants

### Data Fetching Strategy

#### API Endpoints

**Current Endpoints (to implement on server):**
```typescript
// Workflows
GET    /api/tenants/{slug}/workflows
GET    /api/tenants/{slug}/workflows/{id}
POST   /api/tenants/{slug}/workflows
PUT    /api/tenants/{slug}/workflows/{id}
DELETE /api/tenants/{slug}/workflows/{id}

// Executions
GET    /api/tenants/{slug}/runs
GET    /api/tenants/{slug}/runs/{id}
POST   /api/tenants/{slug}/executions(trigger new run)
POST   /api/tenants/{slug}/runs/{id}/cancel
POST   /api/tenants/{slug}/runs/{id}/retry

// Events & Timeline
GET    /api/tenants/{slug}/runs/{executionId}/events
GET    /api/tenants/{slug}/runs/{executionId}/event-groups
GET    /api/tenants/{slug}/runs/{executionId}/timeline

// Tasks
GET    /api/tenants/{slug}/runs/{executionId}/tasks
GET    /api/tenants/{slug}/tasks/{taskId}
GET    /api/tenants/{slug}/tasks/{taskId}/logs

// Analytics
GET    /api/tenants/{slug}/runs/stats
GET    /api/tenants/{slug}/workflows/{id}/stats
```

**Query Parameters for Listing:**
```typescript
interface ExecutionsListParams {
  status?: WorkflowStatus[];
  workflowId?: string;
  dateFrom?: string;
  dateTo?: string;
  triggeredBy?: string;
  tags?: Record<string, string>;
  page?: number;
  pageSize?: number;
  sortBy?: 'createdAt' | 'startedAt' | 'completedAt' | 'duration';
  sortOrder?: 'asc' | 'desc';
}
```

#### React Query Integration

**Existing Query Hooks (apps/web/lib/api/queries.ts):**
```typescript
export const executionQueries = {
  list: (filters?: ExecutionsListParams) => ({
    queryKey: ['runs', 'list', filters],
    queryFn: () => apiClient.listExecutions(filters),
    staleTime: 30000, // 30 seconds
  }),

  detail: (executionId: string) => ({
    queryKey: ['runs', 'detail', executionId],
    queryFn: () => apiClient.getRun(executionId),
  }),

  events: (executionId: string) => ({
    queryKey: ['runs', executionId, 'events'],
    queryFn: () => apiClient.getRunEvents(executionId),
  }),

  eventGroups: (executionId: string) => ({
    queryKey: ['runs', executionId, 'event-groups'],
    queryFn: () => apiClient.getRunEventGroups(executionId),
  }),

  tasks: (executionId: string) => ({
    queryKey: ['runs', executionId, 'tasks'],
    queryFn: () => apiClient.getRunTasks(executionId),
  }),
};
```

**Cache Invalidation Strategy:**
```typescript
// After mutation
queryClient.invalidateQueries(['runs', 'list']);
queryClient.invalidateQueries(['runs', 'detail', executionId]);

// Optimistic updates
queryClient.setQueryData(['runs', 'detail', executionId], (old) => ({
  ...old,
  status: 'CANCELLED',
}));
```

### Real-time Updates

#### WebSocket Implementation

**Connection Management:**
```typescript
// apps/web/lib/api/websocket.ts
export class ExecutionsWebSocket {
  private ws: WebSocket | null = null;
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;

  connect(tenantSlug: string, token: string) {
    const wsUrl = `wss://api.flovyn.com/ws/tenants/${tenantSlug}/runs`;
    this.ws = new WebSocket(wsUrl, ['Bearer', token]);

    this.ws.onmessage = (event) => {
      const update = JSON.parse(event.data);
      this.handleUpdate(update);
    };

    this.ws.onerror = () => this.handleReconnect();
  }

  private handleUpdate(update: ExecutionUpdate) {
    // Invalidate React Query cache
    queryClient.invalidateQueries(['runs', update.executionId]);
  }
}
```

**Hook Usage:**
```typescript
// apps/web/lib/api/hooks/useExecutionsSubscription.ts
export function useExecutionsSubscription() {
  const { tenant } = useTenant();
  const { getAccessToken } = useAuth();

  useEffect(() => {
    const ws = new ExecutionsWebSocket();
    const token = getAccessToken();
    ws.connect(tenant.slug, token);

    return () => ws.disconnect();
  }, [tenant.slug]);
}
```

**Alternative: Server-Sent Events (SSE)**
If WebSocket is too complex, use SSE for one-way updates:

```typescript
// apps/web/lib/api/sse.ts
export function useRunUpdates(executionId: string) {
  useEffect(() => {
    const eventSource = new EventSource(
      `/api/tenants/${tenant.slug}/runs/${executionId}/stream`
    );

    eventSource.onmessage = (event) => {
      const update = JSON.parse(event.data);
      queryClient.setQueryData(['runs', 'detail', executionId], update);
    };

    return () => eventSource.close();
  }, [executionId]);
}
```

### UI Components Enhancement

#### 1. Enhanced ExecutionsTable

**Features to Add:**
- Virtual scrolling for large datasets (react-window)
- Sticky header
- Resizable columns
- Column visibility toggle
- Bulk selection
- Keyboard navigation

**Implementation:**
```typescript
// apps/web/components/runs/ExecutionsTable.tsx
import { useVirtualizer } from '@tanstack/react-virtual';

export function ExecutionsTable({ data }: { data: WorkflowRunView[] }) {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: data.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 60,
  });

  return (
    <div ref={parentRef} style={{ height: '600px', overflow: 'auto' }}>
      {virtualizer.getVirtualItems().map((virtualRow) => (
        <RunRow key={virtualRow.key} run={data[virtualRow.index]} />
      ))}
    </div>
  );
}
```

#### 2. Enhanced GanttTimeline

**Current Features (already implemented):**
- Time-scaled horizontal bars
- Color coding by status
- Hover tooltips
- Expandable sub-workflows
- Lane assignment for parallel operations

**Features to Add:**
- Zoom controls (zoom in/out on timeline)
- Export to PNG/SVG
- Critical path highlighting
- Time markers with absolute timestamps
- Minimap for long executions

#### 3. New: ExecutionStatistics Component

**Purpose:** Display aggregated metrics for workflow performance

```typescript
// apps/web/components/runs/RunStatistics.tsx
interface ExecutionStats {
  total: number;
  byStatus: Record<WorkflowStatus, number>;
  avgDuration: number;
  successRate: number;
  mostActiveWorkflow: string;
}

export function ExecutionStatistics({ stats }: { stats: ExecutionStats }) {
  return (
    <div className="grid grid-cols-4 gap-4">
      <StatCard
        title="Total Executions"
        value={stats.total}
        icon={PlayIcon}
      />
      <StatCard
        title="Success Rate"
        value={`${stats.successRate}%`}
        trend={stats.successRate > 95 ? 'up' : 'down'}
      />
      <StatCard
        title="Avg Duration"
        value={formatDuration(stats.avgDuration)}
      />
      <StatCard
        title="Running Now"
        value={stats.byStatus.RUNNING}
        live={true}
      />
    </div>
  );
}
```

#### 4. New: ExecutionFiltersAdvanced Component

**Purpose:** Advanced filtering UI with date range, tags, etc.

```typescript
// apps/web/components/runs/RunFiltersAdvanced.tsx
export function ExecutionFiltersAdvanced({ onFilterChange }) {
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-3 gap-4">
        {/* Status multi-select */}
        <MultiSelect
          label="Status"
          options={statusOptions}
          value={selectedStatuses}
          onChange={(statuses) => onFilterChange({ statuses })}
        />

        {/* Workflow select */}
        <Select
          label="Workflow"
          options={workflows}
          value={selectedWorkflow}
          onChange={(workflow) => onFilterChange({ workflowId: workflow })}
        />

        {/* Date range */}
        <DateRangePicker
          label="Date Range"
          value={dateRange}
          onChange={(range) => onFilterChange({ dateFrom: range.from, dateTo: range.to })}
        />
      </div>

      {/* Tag filters */}
      <TagFilters
        tags={availableTags}
        selected={selectedTags}
        onChange={(tags) => onFilterChange({ tags })}
      />

      {/* Quick filters */}
      <div className="flex gap-2">
        <Button variant="outline" size="sm" onClick={() => applyQuickFilter('today')}>
          Today
        </Button>
        <Button variant="outline" size="sm" onClick={() => applyQuickFilter('failed')}>
          Failed Only
        </Button>
        <Button variant="outline" size="sm" onClick={() => applyQuickFilter('running')}>
          Executionning
        </Button>
      </div>
    </div>
  );
}
```

### Performance Optimization

#### 1. Pagination
- Server-side pagination (50 executionsper page)
- Cursor-based for infinite scroll option
- Prefetch next page on scroll near bottom

#### 2. Caching
- React Query cache (30s stale time for lists, 1min for details)
- Browser IndexedDB for offline viewing
- Service worker for asset caching

#### 3. Code Splitting
```typescript
// Lazy load heavy components
const GanttTimeline = lazy(() => import('@/components/events/GanttTimeline'));
const ExecutionsTable = lazy(() => import('@/components/runs/ExecutionsTable'));
```

#### 4. Data Minimization
- Only fetch event details on demand (not in list view)
- Compress large JSON payloads
- Use pagination for events/logs

### Security Considerations

#### 1. Authorization
- Tenant-scoped queries (enforced by API client)
- Row-level security in database
- Executions only accessible to tenant members

#### 2. Data Privacy
- Sensitive data masking in input/output
- PII redaction in logs
- Audit trail for executionaccess

#### 3. Rate Limiting
- API rate limits per tenant
- WebSocket connection limits
- Export rate limiting

## Implementation Plan

### Phase 1: Server Integration (Week 1-2)
1. Replace mock client with real API calls
2. Implement authentication in API client (already done)
3. Add error handling and retry logic (already done)
4. Test with real server endpoints

### Phase 2: Real-time Updates (Week 2-3)
1. Implement WebSocket connection
2. Add executionstatus subscription
3. Optimize cache invalidation
4. Add reconnection logic

### Phase 3: Enhanced Filtering (Week 3-4)
1. Add date range picker component
2. Implement tag filtering
3. Add multi-select for statuses
4. Create quick filter presets

### Phase 4: Analytics & Metrics (Week 4-5)
1. Create statistics API endpoints
2. Build ExecutionStatistics component
3. Add performance charts
4. Implement success rate tracking

### Phase 5: Bulk Operations (Week 5-6)
1. Add multi-select to table
2. Implement bulk cancel
3. Add bulk retry
4. Create confirmation dialogs

### Phase 6: Export & Sharing (Week 6)
1. CSV export for runs
2. JSON export for debugging
3. Share links with filters
4. Timeline screenshot export

## Testing Strategy

### Unit Tests
- Component rendering (React Testing Library)
- Query hooks (Mock Service Worker)
- Filter logic
- Date/time utilities

### Integration Tests
- API client integration
- WebSocket connection
- Cache invalidation
- Pagination

### E2E Tests (Playwright)
- Create and view workflow run
- Filter executionsby status
- View executiondetails and timeline
- Cancel running workflow
- Export executiondata

### Performance Tests
- Load 1000+ runs
- Measure time to interactive
- Virtual scrolling performance
- Memory usage profiling

## Success Metrics

1. **Performance**
   - Page load < 2s
   - Time to interactive < 3s
   - Virtual scroll FPS > 30

2. **Reliability**
   - WebSocket uptime > 99%
   - API success rate > 99.9%
   - Cache hit rate > 70%

3. **User Experience**
   - Zero-delay filtering (client-side)
   - Real-time updates < 1s latency
   - Mobile responsive (100% features)

## Future Enhancements

1. **AI-powered Insights**
   - Anomaly detection in executionpatterns
   - Failure prediction
   - Performance optimization suggestions

2. **Advanced Visualization**
   - Flame graphs for execution time
   - Dependency graphs for workflows
   - Heatmaps for execution frequency

3. **Collaboration Features**
   - Comments on runs
   - @mentions in discussions
   - Execution bookmarks/favorites

4. **Alerting**
   - Slack/Email notifications
   - Custom alert rules
   - Escalation policies

5. **Comparison Tools**
   - Compare two executionsside-by-side
   - Diff input/output
   - Timeline comparison

## Appendix

### File Structure
```
apps/web/
├── app/
│   ├── tenant/[tenantSlug]/
│   │   ├── page.tsx (dashboard with ExecutionStatistics)
│   │   ├── runs/
│   │   │   ├── page.tsx (enhanced with filters)
│   │   │   └── [executionId]/
│   │   │       └── page.tsx (4 tabs)
│   │   └── workflows/
│   │       ├── page.tsx
│   │       └── [workflowId]/
│   │           └── page.tsx
│   └── runs/
│       └── page.tsx (cross-tenant view)
├── components/
│   ├── runs/
│   │   ├── ExecutionsTable.tsx
│   │   ├── ExecutionOverview.tsx
│   │   ├── ExecutionStatusBadge.tsx
│   │   ├── ExecutionsFilterBar.tsx
│   │   ├── ExecutionFiltersAdvanced.tsx (new)
│   │   ├── ExecutionStatistics.tsx (new)
│   │   └── RecentExecutionsList.tsx (new)
│   ├── events/
│   │   ├── GanttTimeline.tsx
│   │   └── EventsList.tsx
│   └── workflows/
│       └── WorkflowsTable.tsx
└── lib/
    ├── api/
    │   ├── client.ts
    │   ├── queries.ts
    │   ├── websocket.ts (new)
    │   └── hooks/
    │       └── useExecutionsSubscription.ts (new)
    └── types/
        └── workflow.ts
```

### Dependencies
```json
{
  "dependencies": {
    "@tanstack/react-query": "^5.0.0",
    "@tanstack/react-virtual": "^3.0.0",
    "ky": "^1.0.0",
    "date-fns": "^3.0.0",
    "react-day-picker": "^8.0.0"
  }
}
```

### References
- [React Query Documentation](https://tanstack.com/query/latest)
- [WebSocket API](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket)
- [Virtual Scrolling Best Practices](https://tanstack.com/virtual/latest)
- [Next.js App Router](https://nextjs.org/docs/app)
