# Migrate AI UI from flovyn-ai to flovyn-app

**Date:** 2026-02-07
**Status:** Draft

## Context

The `flovyn-ai` repository contains a PoC for a new AI-focused UI — agents, workflows, tools, and runs (one-shot executions). This UI was built standalone to iterate quickly on the design. Now that the design is validated, we need to integrate it into the main `flovyn-app` application.

The key challenge is that `flovyn-app` already has its own `/workflows` and `/tasks` routes under the org scope (`/org/[orgSlug]/...`). The AI UI also has `/workflows` and `/runs` pages. To avoid conflicts and allow both UIs to coexist during transition, all AI pages will live under the `/ai` prefix.

## Problem Statement

1. **Duplicate route names**: Both apps define `/workflows`. The AI workflows (visual agent pipelines) are conceptually different from flovyn-app workflows (task orchestration pipelines), so they need separate routes.
2. **Different tech versions**: flovyn-ai uses React 18, Tailwind v3, Next.js 15. flovyn-app uses React 19, Tailwind v4, Next.js 16.
3. **Isolated data layer**: flovyn-ai uses mock data. flovyn-app has a real API proxy to flovyn-server. The AI pages need to connect to real data eventually.
4. **Different component libraries**: flovyn-ai has its own shadcn/ui components (`components/ui/`). flovyn-app has a shared `@workspace/ui` package. We must consolidate to avoid duplication.

## Goals

1. Move all flovyn-ai pages into flovyn-app under `/org/[orgSlug]/ai/...`
2. Integrate with existing authentication, org context, sidebar navigation, and theming
3. Reuse `@workspace/ui` components wherever possible
4. Migrate flovyn-ai workspace packages (`workflow-builder`, `workflow-ir`) into flovyn-app's monorepo
5. Keep mock data initially, then replace with real API calls

## Non-Goals

- Building the backend API for AI features (separate effort)
- Migrating `agent-runtime` or `cli` packages (these are server-side/CLI concerns)
- Dark mode support for AI pages (flovyn-ai only has light mode; can be added later)
- Replacing the existing flovyn-app workflows UI

## Current State

### flovyn-ai routes (standalone, no org scope)

```
/                              → Home with prompt input
/runs                          → Runs list (live + history)
/runs/new?prompt=X             → New run execution
/runs/[runId]                  → Run detail
/agents                        → Agents list
/agents/[agentId]              → Agent detail + sessions
/workflows                     → Workflows list
/workflows/[workflowId]        → Workflow builder + runs
/tools                         → Tools list
/tools/[toolId]                → Tool detail
```

### flovyn-app routes (org-scoped)

```
/org/[orgSlug]/workflows/...   → Workflow definitions + executions
/org/[orgSlug]/tasks/...       → Task definitions + executions
/org/[orgSlug]/schedules/...   → Trigger schedules
/org/[orgSlug]/webhooks/...    → Event sources
/org/[orgSlug]/workers/...     → Worker management
/org/[orgSlug]/members/...     → Team management
/org/[orgSlug]/metadata/...    → Metadata fields
/org/[orgSlug]/settings/...    → Org settings
```

## Proposed Solution

### Route Mapping

All flovyn-ai routes move under `/org/[orgSlug]/ai/`:

| flovyn-ai route | flovyn-app route | Notes |
|-----------------|------------------|-------|
| `/` | `/org/[orgSlug]/ai` | AI dashboard with prompt input |
| `/runs` | `/org/[orgSlug]/ai/runs` | Runs list |
| `/runs/new` | `/org/[orgSlug]/ai/runs/new` | New run |
| `/runs/[runId]` | `/org/[orgSlug]/ai/runs/[runId]` | Run detail |
| `/agents` | `/org/[orgSlug]/ai/agents` | Agents list |
| `/agents/[agentId]` | `/org/[orgSlug]/ai/agents/[agentId]` | Agent detail |
| `/workflows` | `/org/[orgSlug]/ai/workflows` | AI workflows list |
| `/workflows/[workflowId]` | `/org/[orgSlug]/ai/workflows/[workflowId]` | Workflow builder |
| `/tools` | `/org/[orgSlug]/ai/tools` | Tools list |
| `/tools/[toolId]` | `/org/[orgSlug]/ai/tools/[toolId]` | Tool detail |

### File Structure in flovyn-app

```
flovyn-app/apps/web/
├── app/org/[orgSlug]/ai/
│   ├── layout.tsx                    # AI section layout (optional sub-sidebar or tabs)
│   ├── page.tsx                      # AI dashboard (home + prompt input)
│   ├── runs/
│   │   ├── page.tsx                  # Runs list
│   │   ├── new/page.tsx              # New run
│   │   └── [runId]/page.tsx          # Run detail
│   ├── agents/
│   │   ├── page.tsx                  # Agents list
│   │   └── [agentId]/page.tsx        # Agent detail
│   ├── workflows/
│   │   ├── page.tsx                  # AI workflows list
│   │   └── [workflowId]/page.tsx     # Workflow builder
│   └── tools/
│       ├── page.tsx                  # Tools list
│       └── [toolId]/page.tsx         # Tool detail
├── components/ai/                    # AI-specific components (not shared via @workspace/ui)
│   ├── sidebar.tsx                   # AI sub-navigation (runs, agents, workflows, tools)
│   ├── breadcrumb.tsx                # AI breadcrumb with entity context
│   ├── status-dot.tsx
│   ├── status-label.tsx
│   ├── badge-type.tsx
│   ├── icons.tsx                     # AI-specific icon set
│   ├── flovyn-logo.tsx
│   ├── chat/
│   │   ├── chat-view.tsx
│   │   ├── workspace-panel.tsx
│   │   ├── artifact-list.tsx
│   │   ├── artifact-card.tsx
│   │   ├── terminal-view.tsx
│   │   └── tool-execution-ui.tsx
│   └── run/
│       ├── unified-run-view.tsx
│       ├── execution-tree.tsx
│       ├── run-panel-tabs.tsx
│       └── run-panel-content.tsx
└── lib/ai/
    ├── mock-data.ts                  # Temporary mock data (to be replaced)
    └── types.ts                      # AI-specific types
```

### Architecture

#### Layout Hierarchy

The AI pages inherit the existing org layout chain:

```
RootLayout (providers, auth, theme)
  └── OrgLayout (OrgProvider, ProtectedOrgLayout, SidebarProvider)
      └── AppSidebar (existing sidebar — add "AI" nav item)
          └── SidebarInset + SiteHeader
              └── AI Layout (optional: AI-specific sub-nav or context)
                  └── AI Page Content
```

This means AI pages automatically get:
- Authentication enforcement (ProtectedOrgLayout)
- Organization context (OrgProvider, useOrg())
- Sidebar navigation with active state detection
- Site header with breadcrumbs
- Theme support (light/dark)
- React Query provider for data fetching

#### Sidebar Integration

Add an "AI" section to the existing `AppSidebar` (`flovyn-app/apps/web/components/app-sidebar.tsx`):

```tsx
// Option A: Single nav item that expands on click
{ href: `/org/${orgSlug}/ai`, label: 'AI', icon: Sparkles }

// Option B: Section with sub-items (preferred if AI is a major feature area)
// "AI" section group:
//   - Runs    → /org/[orgSlug]/ai/runs
//   - Agents  → /org/[orgSlug]/ai/agents
//   - Workflows → /org/[orgSlug]/ai/workflows
//   - Tools   → /org/[orgSlug]/ai/tools
```

**Recommendation**: Start with Option A (single collapsible item). The AI dashboard page at `/ai` can serve as a hub with navigation to sub-pages. This keeps the sidebar clean and avoids overwhelming users with too many items. Can expand to Option B later as AI features become core.

#### Breadcrumb Integration

Add segment labels in `site-header.tsx`:

```tsx
const segmentLabels: Record<string, string> = {
  // ... existing
  ai: "AI",
  agents: "Agents",
  runs: "Runs",
  tools: "Tools",
  // "workflows" already exists
};
```

### Tech Stack Alignment

| Concern | flovyn-ai | flovyn-app | Migration Action |
|---------|-----------|------------|-----------------|
| React | 18.3 | 19.1 | Upgrade to React 19. Check `use()` hook usage, async component patterns |
| Next.js | 15.1 | 16.1 | Adopt Next.js 16. Minor API changes expected |
| Tailwind | v3 (PostCSS) | v4 (@tailwindcss/postcss) | Rewrite Tailwind config. v4 uses CSS-first config, not JS config |
| Font | DM Sans, JetBrains Mono, Instrument Serif | Geist Sans, Geist Mono | Keep Geist. Drop DM Sans / Instrument Serif font imports |
| Sidebar | Custom Radix-based | @workspace/ui SidebarProvider | Use existing sidebar infrastructure |
| Icons | lucide-react | lucide-react | Compatible, no changes needed |
| State | useState, Zustand | useState, Zustand, React Query | Keep Zustand for editor state, add React Query for API data |
| CSS variables | oklch() in globals.css | oklch() in @workspace/ui | Merge AI-specific variables into @workspace/ui globals |
| shadcn components | Local copies in components/ui/ | @workspace/ui package | Replace local copies with @workspace/ui imports |

### Package Migration

Two flovyn-ai packages need to move into the flovyn-app monorepo:

#### 1. `@flovyn/workflow-builder` → `@workspace/workflow-builder`

The visual workflow editor (React Flow + Zustand + ELK.js). This is the core of the workflow builder page.

```
flovyn-app/packages/workflow-builder/
├── src/
│   ├── components/
│   │   ├── canvas/          # WorkflowCanvas, auto-layout, connections
│   │   ├── nodes/           # Step type node components
│   │   ├── panels/          # Configuration panels per step type
│   │   └── palette/         # Step palette with drag-and-drop
│   ├── stores/
│   │   └── workflowStore.ts # Zustand store (undo/redo, selection, validation)
│   └── index.ts
├── package.json
└── tsconfig.json
```

**Dependencies to add to flovyn-app**:
- `@xyflow/react` (React Flow v12) — replaces unused `reactflow` v11 dependency
- `elkjs` (automatic layout)

#### 2. `@flovyn/workflow-ir` → `@workspace/workflow-ir`

Zod-validated workflow schema. Used by the workflow builder for step type definitions.

```
flovyn-app/packages/workflow-ir/
├── src/
│   ├── schema/
│   │   ├── step.ts         # Base step schema, StepType enum
│   │   ├── action.ts       # HTTP, Code, Transform steps
│   │   ├── ai.ts           # AI steps (Generate, Extract, Classify, etc.)
│   │   ├── control-flow.ts # Condition, Iterator, Loop, Parallel
│   │   ├── wait.ts         # Wait steps
│   │   ├── hitl.ts         # Human-in-the-loop steps
│   │   ├── trigger.ts      # Trigger definitions
│   │   ├── workflow.ts     # Top-level WorkflowSchema
│   │   └── common.ts       # Shared types, expression helpers
│   └── index.ts
├── package.json
└── tsconfig.json
```

**Dependencies**: Only `zod` (already in flovyn-app).

#### Packages NOT migrated

| Package | Reason |
|---------|--------|
| `@flovyn/agent-sdk` | Agent config types — relevant only when backend API exists |
| `@flovyn/agent-runtime` | Execution engine with OpenRouter — server-side concern |
| `@flovyn/cli` | CLI tool — not relevant to web app |

### Component Migration Strategy

#### Components to replace with @workspace/ui

These flovyn-ai components have equivalents in `@workspace/ui` and should be replaced:

| flovyn-ai component | @workspace/ui replacement |
|---------------------|--------------------------|
| `components/ui/button.tsx` | `@workspace/ui/components/button` |
| `components/ui/input.tsx` | `@workspace/ui/components/input` |
| `components/ui/separator.tsx` | `@workspace/ui/components/separator` |
| `components/ui/sheet.tsx` | `@workspace/ui/components/sheet` |
| `components/ui/tooltip.tsx` | `@workspace/ui/components/tooltip` |
| `components/ui/skeleton.tsx` | `@workspace/ui/components/skeleton` |
| `components/ui/sidebar.tsx` | `@workspace/ui/components/sidebar` |
| `components/ui/resizable.tsx` | `react-resizable-panels` (already in flovyn-app) |

#### Components to migrate as-is (AI-specific)

These have no equivalent in `@workspace/ui` and are specific to the AI feature:

- `status-dot.tsx`, `status-label.tsx`, `badge-type.tsx` — AI entity status indicators
- `icons.tsx` — AI-specific icon compositions
- `chat/chat-view.tsx`, `chat/workspace-panel.tsx` — Run execution chat UI
- `chat/artifact-list.tsx`, `chat/artifact-card.tsx` — Artifact display
- `chat/terminal-view.tsx` — Terminal emulator
- `chat/tool-execution-ui.tsx` — Tool execution visualization
- `run/unified-run-view.tsx` — Core run execution component
- `run/execution-tree.tsx` — Execution step tree
- `run/run-panel-tabs.tsx`, `run/run-panel-content.tsx` — Run side panel

#### New dependency: `@assistant-ui/react`

The `UnifiedRunView` component depends on `@assistant-ui/react` for the chat framework. This needs to be added to flovyn-app's web package dependencies.

### CSS / Design System Integration

flovyn-ai defines custom CSS variables in `globals.css` using oklch(). These need to be merged into `@workspace/ui/src/globals.css`:

**New variables to add**:

```css
/* AI step type colors */
--step-action: oklch(0.55 0.20 265);
--step-ai: oklch(0.58 0.20 296);
--step-control: oklch(0.72 0.19 55);
--step-wait: oklch(0.62 0.22 235);
--step-hitl: oklch(0.64 0.22 165);
```

**Variables already present**: `--success`, `--warning`, `--destructive` — verify values match or consolidate.

**Color convention from flovyn-ai** (used in inline styles throughout pages):
- Green (`#10b981` / emerald) = Agents
- Cyan (`#06b6d4`) = Workflows
- Yellow/Amber (`#f59e0b`) = Tools
- Orange (`#f97316`) = Runs / Triggers
- Purple (`#8b5cf6`) = AI steps

These are used as inline `style={{}}` objects in page components, not as Tailwind classes. Consider defining them as CSS variables for consistency:

```css
--ai-color-agent: oklch(0.62 0.16 175);
--ai-color-workflow: oklch(0.65 0.15 200);
--ai-color-tool: oklch(0.75 0.15 85);
--ai-color-run: oklch(0.70 0.18 45);
```

### Data Layer Migration

#### Phase 1: Mock Data (initial migration)

Keep `lib/ai/mock-data.ts` with the same data structures. This allows validating the UI migration without backend dependencies.

#### Phase 2: API Integration (future)

Replace mock data with React Query hooks calling the API proxy:

```tsx
// lib/ai/hooks/use-agents.ts
export function useAgents() {
  return useQuery({
    queryKey: ['ai', 'agents'],
    queryFn: () => apiClient.get('/api/ai/agents').json(),
  });
}
```

This requires corresponding backend endpoints in flovyn-server, which is out of scope for this design.

### React Flow: Standardize on @xyflow/react v12

flovyn-app lists `reactflow` v11 (legacy package) in `apps/web/package.json`, but it has **zero imports** in the source code — it is an unused dependency. flovyn-ai uses `@xyflow/react` v12 (the current package) for the visual workflow builder.

**Action**: Remove `reactflow` from `flovyn-app/apps/web/package.json` and standardize on `@xyflow/react` v12 across the monorepo. Since there are no existing imports to migrate, this is a clean swap with no code changes required outside of the AI pages.

The `@workspace/workflow-builder` package will declare `@xyflow/react` as a peer dependency. The `apps/web` package installs it as a direct dependency.

## Alternatives Considered

### 1. Embed flovyn-ai as a separate Next.js app behind a reverse proxy

**Pros**: Zero migration effort, full isolation
**Cons**: No shared auth, no shared sidebar, separate build/deploy, inconsistent UX. Users would notice the transition between apps.

### 2. Use Next.js multi-zones to compose the two apps

**Pros**: Each app stays independent, shared routing layer
**Cons**: Complex deployment, hard to share components and state, version mismatches cause subtle bugs.

### 3. Move AI pages to top-level routes (no `/ai` prefix)

**Pros**: Cleaner URLs (`/org/[orgSlug]/agents` instead of `/org/[orgSlug]/ai/agents`)
**Cons**: Direct conflict with existing `/workflows` route. Would require renaming existing routes, which breaks bookmarks and links. The `/ai` prefix is a pragmatic trade-off for a clean migration path.

## Decisions

- **AI dashboard as org home**: Yes — `/org/[orgSlug]/ai` will replace the current org home page long-term. The AI dashboard with prompt input becomes the primary landing experience.
- **Font**: Keep Geist (flovyn-app default). Do not port DM Sans / Instrument Serif from flovyn-ai.
- **COLORS constant**: Keep inline style pattern as-is for now. Revisit CSS variable migration later.

## References

- `flovyn-ai/CLAUDE.md` — flovyn-ai project overview and architecture
- `flovyn-app/CLAUDE.md` — flovyn-app project overview and architecture
- `dev/docs/design/20260122_experiment_new_design_for_flovyn_app.md` — Original experiment design doc
- flovyn-ai source: `flovyn-ai/apps/web/src/`
- flovyn-app source: `flovyn-app/apps/web/`
