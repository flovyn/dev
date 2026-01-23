# Design: Improve Frontend Experience

**Date:** 2026-01-22
**Status:** Approved
**GitHub Issue:** https://github.com/flovyn/flovyn-app/issues/1

## Problem Statement

The frontend UI has several inconsistencies and incomplete features that affect user experience:

1. **Inconsistent pagination across data grids** - Most data grids load all data into memory without pagination, which doesn't scale for larger datasets and creates inconsistent UX
2. **Page hierarchy needs reorganization** - The sidebar navigation structure could be improved for better discoverability and logical grouping
3. **Workflow timeline streaming unverified** - SSE-based streaming for real-time timeline updates exists but hasn't been confirmed to work end-to-end
4. **Webhook source UI improvements** - The webhook fix (per [20260121_fix_webhook_issues.md](../plans/20260121_fix_webhook_issues.md)) added new backend capabilities that need frontend support

## Current State Analysis

### 1. Data Grid Pagination

**Identified Data Grids:**

| Component | Location | Has Pagination |
|-----------|----------|----------------|
| `WebhookEventsDataGrid` | `components/webhooks/events/` | Yes |
| `ApiKeysDataGrid` | `components/account/` | No |
| `WorkerTokensDataGrid` | `components/settings/` | No |
| `MetadataFieldsDataGrid` | `components/settings/` | No |
| `WebhookSourcesDataGrid` | `components/webhooks/sources/` | No |
| `WebhookRoutesDataGrid` | `components/webhooks/routes/` | No (custom drag-and-drop) |

**Available Pagination Components:**

- `packages/ui/src/components/pagination.tsx` - Generic, reusable pagination component with:
  - Page size selector (10, 25, 50, 100)
  - Navigation (first/prev/next/last)
  - Item count display
  - Loading state support
  - Customizable item label

- `components/webhooks/events/webhook-events-pagination.tsx` - Duplicate of the generic component with hardcoded "events" label (should be removed and replaced with generic)

**Problem:** Only WebhookEventsDataGrid implements server-side pagination with URL state persistence. All others load entire datasets into memory.

### 2. Sidebar Navigation Structure

**Current Structure:**
```
Main Section:
├── Workflows (collapsible)
│   ├── Definitions (link to /workflows)
│   └── Executions (link to /workflows/executions)
├── Tasks (collapsible)
│   ├── Definitions (link to /tasks)
│   └── Executions (link to /tasks/executions)
├── Schedules
└── Webhook events

Manage Section:
├── Members
├── Workers
└── Settings (admin only)
    ├── Worker Tokens
    ├── Metadata Fields
    └── Webhooks (sources & routes config)
```

**Issues:**
- Workflows and Tasks have nested navigation with separate pages for Definitions and Executions - adds complexity
- "Webhook events" appears in main nav, but "Webhooks" (sources/routes configuration) is under Settings - confusing separation
- The term "Webhooks" under Settings doesn't clearly indicate it's about configuration vs. viewing events
- Collapsible menus require extra clicks to navigate

### 3. Workflow Timeline Streaming

**Current Implementation:**

1. **Polling-based refresh** (`lib/hooks/useSpanAutoRefresh.ts`):
   - Rebuilds spans every 1 second when execution is in RUNNING state
   - Simple and reliable, but polling introduces unnecessary server load

2. **SSE-based streaming** (`hooks/useWorkflowStream.ts`):
   - Uses Effect library for stream management
   - Supports real-time events: task_state, timer_state, promise_state, child_workflow_state, operation_state, progress
   - Has callbacks for different event types
   - **Not currently integrated into the execution detail page**

**Problem:** The execution detail page (`app/org/[orgSlug]/workflows/executions/[executionId]/page.tsx`) uses `useSpanAutoRefresh` (polling) but not `useWorkflowStream` (SSE). The streaming infrastructure exists but is not wired up.

### 4. Webhook Source UI

**Backend Capabilities (from webhook fix):**
- Event type extraction configuration (`eventTypeConfig` with `headerName` and `jmespath`)
- JMESPath validation endpoint: `POST /validate/jmespath`
- JavaScript validation endpoint: `POST /validate/javascript`

**Current Frontend State:**
- Source create/edit forms don't expose `eventTypeConfig`
- No integration with validation endpoints
- No live preview for JMESPath/JavaScript expressions

## Proposed Solutions

### Solution 1: Standardize Data Grid Pagination

Add pagination to data grids that may have large datasets.

**Scope:**
- `ApiKeysDataGrid` - Add pagination (API keys can accumulate)
- `WorkerTokensDataGrid` - Add pagination (tokens can accumulate)
- `WebhookSourcesDataGrid` - Add pagination (sources can grow)

**Skip:**
- `MetadataFieldsDataGrid` - Typically small, bounded dataset
- `WebhookRoutesDataGrid` - Uses drag-and-drop for ordering, pagination would break reordering UX

**Implementation Approach:**
1. Use the generic `Pagination` component from `packages/ui`
2. Add `offset` and `limit` query params to list APIs if not present
3. Persist pagination state in URL for bookmarkability
4. Remove duplicate `WebhookEventsPagination` component

### Solution 2: Reorganize Sidebar Navigation

Simplify navigation by reducing hierarchy depth and consolidating related views.

**Core UX Principle:** Users primarily want to see what's happening (executions), not what's defined. Definitions are a setup/configuration concern, executions are the operational concern.

**Proposed Structure:**
```
Main Section:
├── Workflows      → Single page with tabs: [Executions | Definitions]
├── Tasks          → Single page with tabs: [Executions | Definitions]

Triggers Section:
├── Schedules
└── Webhooks       → Single page with tabs: [Events | Sources]

Manage Section:
├── Members
├── Workers         → Single page with tabs: [Workers | Tokens]
└── Metadata
```

**Key Changes:**

1. **Remove Dashboard, Use Workflows as Landing Page:**
   - Remove the current Dashboard/home page (`/org/[orgSlug]`)
   - Redirect post-login to Workflows page (`/org/[orgSlug]/workflows`)
   - Workflows is the primary view - users want to see what's running

2. **Workflows Page Consolidation:**
   - Merge `/workflows` (definitions) and `/workflows/executions` into a single page
   - Use tabs: `Executions` | `Definitions`
   - **Default tab:** Executions (most common use case)
   - **Smart default:** If no executions exist, show Definitions tab instead (better onboarding)
   - Remove nested sidebar items - just "Workflows" link

3. **Tasks Page Consolidation:**
   - Same pattern as Workflows
   - Tabs: `Executions` | `Definitions`
   - Default to Executions, fallback to Definitions if empty

4. **Webhooks Page Consolidation:**
   - Merge webhook events and webhook sources (currently under Settings) into a single page
   - Use tabs: `Events` | `Sources`
   - **Default tab:** Events (operational view, most common use case)
   - **Smart default:** If no events exist, show Sources tab instead (guides setup)
   - Consistent with Workflows/Tasks pattern

5. **Triggers Section:**
   - New section grouping all execution triggers together
   - **Schedules:** Time-based triggers (cron, intervals)
   - **Webhooks:** Event-based triggers (single page with tabs)

6. **Workers Page Consolidation:**
   - Merge Workers list and Worker Tokens (currently under Settings) into a single page
   - Use tabs: `Workers` | `Tokens`
   - **Default tab:** Workers (view active workers)
   - **Smart default:** If no workers connected, show Tokens tab (guides setup)

7. **Remove Settings, Flatten Metadata:**
   - Remove the Settings collapsible menu entirely
   - Move "Metadata Fields" to Manage section as top-level item
   - Rename to "Metadata" (shorter, cleaner)

**UX Benefits:**
- Flatter navigation = fewer clicks to reach content
- Tabs provide easy switching between related views without leaving context
- Smart defaults guide new users to configuration while serving power users operational views first
- **Consistent pattern across Workflows, Tasks, and Webhooks**
- "Triggers" groups items by function ("things that start my workflows")
- Clear mental model: Main section = what runs, Triggers = what starts them

### Solution 3: Verify and Integrate Timeline Streaming

**Option A: Keep Polling (Recommended for MVP)**
- The current polling approach (1s interval) works and is simpler
- SSE streaming adds complexity (connection management, reconnection, error handling)
- Defer full streaming integration until polling becomes a performance issue

**Option B: Integrate SSE Streaming**
- Wire up `useWorkflowStream` in the execution detail page
- Replace polling with real-time event updates
- Update span tree incrementally on each event

**Recommendation:** Document the current polling behavior as "working as designed" for now. Create a separate ticket for SSE streaming integration as a performance optimization.

### Solution 4: Composable Page Layout Components

Most pages follow the same structure. Create composable components (shadcn-style) that can be combined flexibly.

**Proposed Composable Components:**

```tsx
// Page - Root container with optional detail panel layout
const Page = {
  Root: ({ children, className }) => (
    <div className={cn("flex h-full max-h-full overflow-hidden", className)}>
      {children}
    </div>
  ),

  Main: ({ children, className }) => (
    <div className={cn("h-full flex flex-col flex-1 min-w-0 container overflow-y-auto", className)}>
      {children}
    </div>
  ),

  Header: ({ children, className }) => (
    <div className={cn("flex justify-between items-center p-3", className)}>
      {children}
    </div>
  ),

  Title: ({ children, count, countLabel = "items" }) => (
    <div className="flex items-center gap-3">
      <h1 className="text-lg font-semibold">{children}</h1>
      {count !== undefined && (
        <span className="text-sm text-muted-foreground">
          {count} {countLabel}
        </span>
      )}
    </div>
  ),

  Actions: ({ children }) => (
    <div className="flex items-center gap-2">{children}</div>
  ),

  Filters: ({ children, className }) => (
    <div className={cn("px-3 pb-4", className)}>{children}</div>
  ),

  Content: ({ children, className }) => (
    <div className={cn("flex-1 min-h-0", className)}>{children}</div>
  ),

  Footer: ({ children, className }) => (
    <div className={className}>{children}</div>
  ),

  DetailPanel: ({ children, open }) => (
    open ? children : null
  ),
};

// Reusable action components
const RefreshButton = ({ onClick, loading }) => (
  <Button size="sm" variant="outline" onClick={onClick} disabled={loading}>
    <RefreshCw className={cn("h-4 w-4", loading && "animate-spin")} />
    Refresh
  </Button>
);

const AutoRefreshSelect = ({ value, onChange }) => (
  <Select value={value} onValueChange={onChange}>
    <SelectTrigger className="w-28 h-8">
      <SelectValue placeholder="Auto" />
    </SelectTrigger>
    <SelectContent>
      <SelectItem value="off">Off</SelectItem>
      <SelectItem value="10s">Every 10s</SelectItem>
      <SelectItem value="30s">Every 30s</SelectItem>
      <SelectItem value="60s">Every 60s</SelectItem>
    </SelectContent>
  </Select>
);
```

**Usage Example:**
```tsx
function WorkersPage() {
  return (
    <Page.Root>
      <Page.Main>
        <Page.Header>
          <Page.Title count={workers.length} countLabel="registered">
            Workers
          </Page.Title>
          <Page.Actions>
            <RefreshButton onClick={refetch} loading={isRefetching} />
          </Page.Actions>
        </Page.Header>

        <Page.Content>
          <WorkersDataGrid data={workers} loading={isLoading} />
        </Page.Content>
      </Page.Main>

      <Page.DetailPanel open={!!selectedId}>
        <WorkerDetailPanel id={selectedId} onClose={handleClose} />
      </Page.DetailPanel>
    </Page.Root>
  );
}
```

**With Filters and Pagination:**
```tsx
function WebhookEventsPage() {
  return (
    <Page.Root>
      <Page.Main>
        <Page.Header>
          <Page.Title count={total} countLabel="events">
            Webhook Events
          </Page.Title>
          <Page.Actions>
            <AutoRefreshSelect value={interval} onChange={setInterval} />
            <RefreshButton onClick={refetch} loading={isRefetching} />
          </Page.Actions>
        </Page.Header>

        <Page.Filters>
          <WebhookEventFilters filters={filters} onChange={setFilters} />
        </Page.Filters>

        <Page.Content>
          <WebhookEventsDataGrid events={events} loading={isLoading} />
        </Page.Content>

        <Page.Footer>
          <Pagination total={total} limit={limit} offset={offset} ... />
        </Page.Footer>
      </Page.Main>

      <Page.DetailPanel open={!!selectedId}>
        <WebhookEventDetailPanel eventId={selectedId} onClose={handleClose} />
      </Page.DetailPanel>
    </Page.Root>
  );
}
```

**Benefits:**
- Composable like shadcn/ui - use only what you need
- Consistent styling without rigid structure
- Easy to extend with custom layouts
- Each component is simple and single-purpose
- TypeScript-friendly with good autocomplete

### Solution 5: Webhook Source UI Enhancements

**Add to Source Create/Edit Forms:**
1. Event Type Config section (collapsible, optional):
   - Header Name input field
   - JMESPath expression input with validation
   - Precedence note: "Header is checked first, then JMESPath expression"

2. Live Validation:
   - Call `/validate/jmespath` on blur or debounced input
   - Show validation status (valid/invalid) inline
   - Display error messages from validation response

3. Test Panel (optional, nice-to-have):
   - Textarea for sample webhook JSON
   - "Extract Event Type" button
   - Shows extracted value or error

**UI Location:**
- Source detail page: `app/org/[orgSlug]/settings/webhooks/sources/[sourceSlug]/page.tsx`
- Source creation: Dialog or page (check current implementation)

## Architecture Decisions

### AD1: URL-Based Pagination State
**Decision:** Store pagination state (offset, limit) in URL query parameters for all paginated grids.

**Rationale:**
- Enables bookmarking specific pages
- Back/forward navigation works correctly
- Shareable links to specific pages
- Consistent with WebhookEventsDataGrid implementation

### AD2: Consolidate Related Views into Tabbed Pages
**Decision:** Replace separate pages with single tabbed pages for Workflows, Tasks, Webhooks, and Workers.

**Pattern:**
| Page | Tabs | Default | Fallback |
|------|------|---------|----------|
| Workflows | Executions \| Definitions | Executions | Definitions (if no executions) |
| Tasks | Executions \| Definitions | Executions | Definitions (if no executions) |
| Webhooks | Events \| Sources | Events | Sources (if no events) |
| Workers | Workers \| Tokens | Workers | Tokens (if no workers) |

**Rationale:**
- Reduces navigation depth (one click instead of two)
- Keeps related content together - users can quickly switch between operational and configuration views
- Follows common SaaS patterns (e.g., GitHub Actions shows workflow runs with easy access to workflow definition)
- Smart defaults provide better onboarding without hurting power users
- Consistent pattern across all four domains reduces cognitive load

### AD3: Group Triggers Together
**Decision:** Create a "Triggers" section containing Schedules and Webhooks.

**Rationale:**
- Both schedules and webhooks serve the same purpose: initiating workflow executions
- Users think "what starts my workflows" - this groups answers to that question
- Clear separation between "what runs" (Main) and "what starts them" (Triggers)
- Reduces cognitive load by organizing by function rather than technology

### AD4: Keep Polling for Timeline (MVP)
**Decision:** Keep the 1-second polling approach for timeline updates rather than integrating SSE streaming.

**Rationale:**
- Current implementation works and is well-tested
- SSE streaming adds complexity (reconnection, error handling, state reconciliation)
- Performance impact of polling is acceptable for current user base
- Can optimize later when needed

### AD5: Progressive Enhancement for Webhook Config
**Decision:** Show `eventTypeConfig` fields only in expanded/advanced section of source forms.

**Rationale:**
- Most users using standard providers (GitHub, Stripe) don't need configuration
- Avoids overwhelming new users with options
- Advanced users can expand to access configuration

## Scope

### In Scope
- **Navigation reorganization:**
  - Remove Dashboard page, use Workflows as post-login landing page
  - Consolidate Workflows into single page with Executions/Definitions tabs
  - Consolidate Tasks into single page with Executions/Definitions tabs
  - Consolidate Webhooks into single page with Events/Sources tabs
  - Consolidate Workers into single page with Workers/Tokens tabs
  - Implement smart default tab logic for all four pages
  - Create "Triggers" section grouping Schedules and Webhooks
  - Remove Settings section entirely
  - Rename "Metadata Fields" to "Metadata" and move to Manage section
  - Remove all nested navigation items
- **Page layout components:**
  - Create composable `Page.*` components (Root, Main, Header, Title, Actions, Filters, Content, Footer, DetailPanel)
  - Create reusable `RefreshButton` and `AutoRefreshSelect` components
  - Refactor existing pages to use new composable components
- **Pagination:**
  - Add pagination to ApiKeysDataGrid, WorkerTokensDataGrid, WebhookSourcesDataGrid
  - Remove duplicate WebhookEventsPagination component
- **Webhook source UI:**
  - Add eventTypeConfig fields to webhook source create/edit forms
  - Add JMESPath validation integration to source forms
- Document that timeline uses polling (streaming deferred)

### Out of Scope
- SSE streaming integration for timeline (separate ticket)
- Virtual scrolling for data grids
- Pagination for MetadataFieldsDataGrid (bounded dataset)
- Pagination for WebhookRoutesDataGrid (breaks drag-and-drop reordering)
- JavaScript validation UI (JMESPath covers most use cases)
- Test panel for webhook event type extraction preview

## Pages Affected

### Pages to Remove
| Page | Path | Reason |
|------|------|--------|
| Dashboard | `/org/[orgSlug]/page.tsx` | Remove, redirect to Workflows |
| Settings index | `/org/[orgSlug]/settings/page.tsx` | Remove, Settings section eliminated |
| Settings webhooks index | `/org/[orgSlug]/settings/webhooks/page.tsx` | Remove, moved to Triggers |

### Pages to Consolidate (merge into tabbed pages)
| Current Pages | New Page | Tabs |
|---------------|----------|------|
| `/workflows/page.tsx` + `/workflows/executions/page.tsx` | `/workflows/page.tsx` | Executions \| Definitions |
| `/tasks/page.tsx` + `/tasks/executions/page.tsx` | `/tasks/page.tsx` | Executions \| Definitions |
| `/webhook-events/page.tsx` + `/settings/webhooks/sources/page.tsx` | `/webhooks/page.tsx` | Events \| Sources |
| `/workers/page.tsx` + `/settings/worker-tokens/page.tsx` | `/workers/page.tsx` | Workers \| Tokens |

### Pages to Move
| Current Path | New Path | Notes |
|--------------|----------|-------|
| `/settings/metadata-fields/page.tsx` | `/metadata/page.tsx` | Renamed to "Metadata" |
| `/settings/webhooks/sources/[sourceSlug]/page.tsx` | `/webhooks/sources/[sourceSlug]/page.tsx` | Source detail page |

### Pages to Refactor (use Page.* components)
| Page | Changes |
|------|---------|
| `/workflows/page.tsx` | Add tabs, use Page.* components |
| `/workflows/[workflowId]/page.tsx` | Use Page.* components |
| `/workflows/executions/[executionId]/page.tsx` | Use Page.* components |
| `/tasks/page.tsx` | Add tabs, use Page.* components |
| `/tasks/[taskKind]/page.tsx` | Use Page.* components |
| `/schedules/page.tsx` | Use Page.* components |
| `/schedules/[scheduleId]/page.tsx` | Use Page.* components |
| `/webhooks/page.tsx` (new) | Create with tabs, use Page.* components |
| `/webhooks/sources/[sourceSlug]/page.tsx` | Add eventTypeConfig UI, use Page.* components |
| `/workers/page.tsx` | Add tabs, use Page.* components |
| `/workers/[workerId]/page.tsx` | Use Page.* components |
| `/members/page.tsx` | Use Page.* components |
| `/metadata/page.tsx` (renamed) | Use Page.* components |

### Sidebar Component
| File | Changes |
|------|---------|
| `components/app-sidebar.tsx` | Complete rewrite for new structure |

### Summary
- **Remove:** 3 pages
- **Consolidate:** 8 pages → 4 tabbed pages
- **Move:** 2 pages
- **Refactor:** 13 pages
- **Total pages after:** 13 (down from 20)

## Resolved Questions

1. **API Pagination Support:** Verified pagination support:
   - `GET /api/orgs/{org}/eventhook/sources` - ✅ Supports `limit` and `offset` query params
   - `GET /api/orgs/{org}/eventhook/events` - ✅ Already has pagination
   - API keys & Worker tokens - ❌ Use Better Auth client-side (`betterAuthClient.apiKey.list()`), not flovyn-server API. These datasets are typically small per-org, so pagination deferred.

2. **eventTypeConfig Placement:** Add to `EditWebhookSourceDialog` only. The create dialog should remain simple for quick setup; users can configure event type extraction after creation via edit.

3. **Tab URL Structure:** Option A selected - use `?tab=xxx` query param pattern:
   - `/workflows?tab=executions` (default, can omit param)
   - `/workflows?tab=definitions`
   - Consistent with existing `/account?tab=api-keys` pattern
   - Bookmarkable and sharable

## References

- Webhook fix design: `dev/docs/design/20260121_fix_webhook_issues.md`
- Webhook fix plan: `dev/docs/plans/20260121_fix_webhook_issues.md`
- Current sidebar: `flovyn-app/apps/web/components/app-sidebar.tsx`
- Data grid component: `flovyn-app/packages/ui/src/components/data-grid/DataGrid.tsx`
- Pagination component: `flovyn-app/packages/ui/src/components/pagination.tsx`
- Timeline auto-refresh: `flovyn-app/apps/web/lib/hooks/useSpanAutoRefresh.ts`
- Workflow streaming: `flovyn-app/apps/web/hooks/useWorkflowStream.ts`
