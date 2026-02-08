# Migrate AI UI to flovyn-app — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the flovyn-ai PoC UI (agents, workflows, tools, runs) into flovyn-app under `/org/[orgSlug]/ai/...` with full integration into the existing auth, sidebar, and component library.

**Architecture:** Copy flovyn-ai packages (`workflow-ir`, `workflow-builder`) into flovyn-app's monorepo as `@workspace/*` packages. Port page components into the Next.js App Router under the `/ai` route group. Replace flovyn-ai's local shadcn copies with `@workspace/ui` imports. Keep mock data as the data layer.

**Tech Stack:** Next.js 16, React 19, Tailwind v4, @xyflow/react v12, Zustand, @assistant-ui/react, @workspace/ui (shadcn)

**Design doc:** `dev/docs/design/20260207_migrate_ai_ui_to_flovyn_app.md`

---

## Phase 1: Foundation — Packages and Dependencies

### Task 1: Copy workflow-ir package into flovyn-app monorepo

**Files:**
- Create: `flovyn-app/packages/workflow-ir/` (copy from `flovyn-ai/packages/workflow-ir/`)

**Step 1: Copy the package directory**

```bash
cp -r flovyn-ai/packages/workflow-ir flovyn-app/packages/workflow-ir
```

**Step 2: Rename the package in package.json**

In `flovyn-app/packages/workflow-ir/package.json`, change `"name"` from `"@flovyn/workflow-ir"` to `"@workspace/workflow-ir"`.

**Step 3: Run existing tests to verify the copy works**

```bash
cd flovyn-app && pnpm install && pnpm --filter @workspace/workflow-ir test
```

Expected: All tests pass — this package has zero external dependencies beyond `zod`.

**Step 4: Commit**

```bash
git add packages/workflow-ir
git commit -m "feat: add workflow-ir package from flovyn-ai"
```

---

### Task 2: Copy workflow-builder package into flovyn-app monorepo

**Files:**
- Create: `flovyn-app/packages/workflow-builder/` (copy from `flovyn-ai/packages/workflow-builder/`)

**Step 1: Copy the package directory**

```bash
cp -r flovyn-ai/packages/workflow-builder flovyn-app/packages/workflow-builder
```

**Step 2: Update package.json**

In `flovyn-app/packages/workflow-builder/package.json`:
- Change `"name"` from `"@flovyn/workflow-builder"` to `"@workspace/workflow-builder"`
- Change dependency `"@flovyn/workflow-ir": "workspace:*"` to `"@workspace/workflow-ir": "workspace:*"`
- Update `peerDependencies` to `"react": "^18.0.0 || ^19.0.0"` and `"react-dom": "^18.0.0 || ^19.0.0"`

**Step 3: Install and build**

```bash
cd flovyn-app && pnpm install && pnpm --filter @workspace/workflow-builder build
```

Expected: Build succeeds. There may be React 19 type warnings — note them but they are non-blocking.

**Step 4: Run tests**

```bash
pnpm --filter @workspace/workflow-builder test
```

Expected: Tests pass (they use jsdom environment).

**Step 5: Commit**

```bash
git add packages/workflow-builder
git commit -m "feat: add workflow-builder package from flovyn-ai"
```

---

### Task 3: Update flovyn-app/apps/web dependencies

**Files:**
- Modify: `flovyn-app/apps/web/package.json`

**Step 1: Remove reactflow, add new dependencies**

In `flovyn-app/apps/web/package.json`:

Remove:
```
"reactflow": "^11.11.4",
```

Add to `dependencies`:
```
"@assistant-ui/react": "^0.12.9",
"@workspace/workflow-builder": "workspace:*",
"@workspace/workflow-ir": "workspace:*",
"@xyflow/react": "^12.6.0",
"@xterm/addon-fit": "^0.11.0",
"@xterm/xterm": "^6.0.0",
```

**Step 2: Install dependencies**

```bash
cd flovyn-app && pnpm install
```

Expected: Lock file updates cleanly, no version conflicts.

**Step 3: Verify the existing app still builds**

```bash
pnpm --filter web build
```

Expected: Build succeeds — we only removed an unused dependency and added new ones that aren't imported yet.

**Step 4: Commit**

```bash
git add apps/web/package.json pnpm-lock.yaml
git commit -m "feat: swap reactflow for @xyflow/react, add AI UI dependencies"
```

---

### Task 4: Add step-type CSS variables to @workspace/ui globals

**Files:**
- Modify: `flovyn-app/packages/ui/src/styles/globals.css`

**Step 1: Add AI step-type variables to `:root`**

In `flovyn-app/packages/ui/src/styles/globals.css`, inside the `:root` block, after the existing `--sidebar-ring` line, add:

```css
  /* AI step type colors */
  --step-action: oklch(0.55 0.20 265);
  --step-ai: oklch(0.58 0.20 296);
  --step-control: oklch(0.72 0.19 55);
  --step-wait: oklch(0.62 0.22 235);
  --step-hitl: oklch(0.64 0.22 165);
```

**Step 2: Add React Flow overrides at the end of the file**

Append to the file:

```css
/* React Flow overrides */
.react-flow__node {
  cursor: pointer;
}

.react-flow__edge-path {
  stroke: var(--border);
  stroke-width: 2;
}

.react-flow__edge.selected .react-flow__edge-path {
  stroke: var(--primary);
}

.react-flow__controls {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.react-flow__controls-button {
  background: var(--card);
  border-color: var(--border);
}

.react-flow__minimap {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}
```

**Step 3: Verify the app still builds**

```bash
cd flovyn-app && pnpm --filter web build
```

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add packages/ui/src/styles/globals.css
git commit -m "feat: add AI step-type CSS variables and React Flow overrides"
```

---

## Phase 2: Navigation Integration

### Task 5: Add "AI" item to the sidebar

**Files:**
- Modify: `flovyn-app/apps/web/components/app-sidebar.tsx`

**Step 1: Add the Sparkles icon import**

In `flovyn-app/apps/web/components/app-sidebar.tsx`, add `Sparkles` to the lucide-react import:

```tsx
import {
  Workflow,
  Users,
  Cpu,
  Check,
  Tags,
  Webhook,
  Calendar,
  Sparkles,
} from 'lucide-react';
```

**Step 2: Add AI nav item to mainNavItems**

In the `mainNavItems` array, add as the first item:

```tsx
const mainNavItems: NavItem[] = orgSlug
  ? [
      {
        href: `/org/${orgSlug}/ai`,
        label: 'AI',
        icon: Sparkles,
      },
      {
        href: `/org/${orgSlug}/workflows`,
        label: 'Workflows',
        icon: Workflow,
      },
      {
        href: `/org/${orgSlug}/tasks`,
        label: 'Tasks',
        icon: Check,
      },
    ]
  : [];
```

**Step 3: Verify the sidebar renders**

```bash
cd flovyn-app && pnpm --filter web dev
```

Navigate to an org page. Verify "AI" appears in the sidebar with the Sparkles icon. Click it — should navigate to `/org/{slug}/ai` (will be 404 until we add the page).

**Step 4: Commit**

```bash
git add apps/web/components/app-sidebar.tsx
git commit -m "feat: add AI nav item to sidebar"
```

---

### Task 6: Add breadcrumb segment labels for AI routes

**Files:**
- Modify: `flovyn-app/apps/web/components/site-header.tsx`

**Step 1: Add AI segment labels**

In `flovyn-app/apps/web/components/site-header.tsx`, in the `segmentLabels` object, add:

```tsx
const segmentLabels: Record<string, string> = {
  // ... existing entries ...
  ai: "AI",
  agents: "Agents",
  runs: "Runs",
  tools: "Tools",
  // "workflows" already exists
};
```

**Step 2: Commit**

```bash
git add apps/web/components/site-header.tsx
git commit -m "feat: add AI breadcrumb segment labels"
```

---

## Phase 3: Shared Components — Port AI-specific Components

### Task 7: Port mock data and types

**Files:**
- Create: `flovyn-app/apps/web/lib/ai/mock-data.ts`
- Create: `flovyn-app/apps/web/lib/ai/colors.ts`

**Step 1: Copy mock-data.ts**

Copy `flovyn-ai/apps/web/src/lib/mock-data.ts` to `flovyn-app/apps/web/lib/ai/mock-data.ts`. No changes needed — it has no imports.

**Step 2: Extract COLORS constant**

Create `flovyn-app/apps/web/lib/ai/colors.ts` by extracting the `COLORS` constant used across AI pages (found in `flovyn-ai/apps/web/src/app/page.tsx` and other pages). This is the inline style color map for green=agents, cyan=workflows, etc.

Read the flovyn-ai home page for the exact COLORS object and copy it.

**Step 3: Commit**

```bash
git add apps/web/lib/ai/
git commit -m "feat: add AI mock data and color constants"
```

---

### Task 8: Port utility components (status-dot, status-label, badge-type, icons)

**Files:**
- Create: `flovyn-app/apps/web/components/ai/status-dot.tsx`
- Create: `flovyn-app/apps/web/components/ai/status-label.tsx`
- Create: `flovyn-app/apps/web/components/ai/badge-type.tsx`
- Create: `flovyn-app/apps/web/components/ai/icons.tsx`

**Step 1: Copy each component from flovyn-ai**

Copy these files from `flovyn-ai/apps/web/src/components/` to `flovyn-app/apps/web/components/ai/`:
- `status-dot.tsx`
- `status-label.tsx`
- `badge-type.tsx`
- `icons.tsx`

**Step 2: Update imports in each file**

For each file, replace any `@/components/ui/*` imports with `@workspace/ui/components/*`. For example:
- `import { cn } from '@/lib/utils'` → `import { cn } from '@workspace/ui/lib/utils'`
- `import { Button } from '@/components/ui/button'` → `import { Button } from '@workspace/ui/components/button'`

If `icons.tsx` uses only SVG elements with no external imports, it needs no changes.

**Step 3: Verify files have no import errors**

```bash
cd flovyn-app && pnpm --filter web typecheck
```

Expected: No errors in the new files (or only errors from not-yet-ported files).

**Step 4: Commit**

```bash
git add apps/web/components/ai/
git commit -m "feat: port AI utility components (status-dot, status-label, badge-type, icons)"
```

---

### Task 9: Port breadcrumb component

**Files:**
- Create: `flovyn-app/apps/web/components/ai/breadcrumb.tsx`

**Step 1: Copy breadcrumb.tsx**

Copy `flovyn-ai/apps/web/src/components/breadcrumb.tsx` to `flovyn-app/apps/web/components/ai/breadcrumb.tsx`.

This component has zero external imports beyond React — no changes needed.

**Step 2: Commit**

```bash
git add apps/web/components/ai/breadcrumb.tsx
git commit -m "feat: port AI breadcrumb component"
```

---

### Task 10: Port chat components

**Files:**
- Create: `flovyn-app/apps/web/components/ai/chat/chat-view.tsx`
- Create: `flovyn-app/apps/web/components/ai/chat/workspace-panel.tsx`
- Create: `flovyn-app/apps/web/components/ai/chat/artifact-list.tsx`
- Create: `flovyn-app/apps/web/components/ai/chat/artifact-card.tsx`
- Create: `flovyn-app/apps/web/components/ai/chat/terminal-view.tsx`
- Create: `flovyn-app/apps/web/components/ai/chat/tool-execution-ui.tsx`

**Step 1: Copy all chat components**

Copy from `flovyn-ai/apps/web/src/components/chat/` to `flovyn-app/apps/web/components/ai/chat/`.

**Step 2: Update imports in each file**

For every file:
- Replace `@/components/ui/*` → `@workspace/ui/components/*`
- Replace `@/lib/utils` → `@workspace/ui/lib/utils`
- Replace `@/components/` → `@/components/ai/` (for cross-references between AI components)
- Replace `@/lib/mock-data` → `@/lib/ai/mock-data`

Key import rewrites:
- `terminal-view.tsx`: Uses `@xterm/xterm` and `@xterm/addon-fit` — these are now in `apps/web/package.json` deps.
- `tool-execution-ui.tsx`: Uses only React and local icons — update icon imports to `@/components/ai/icons`.
- `chat-view.tsx`: Imports `UnifiedRunView` — update to `@/components/ai/run/unified-run-view`.

**Step 3: Commit**

```bash
git add apps/web/components/ai/chat/
git commit -m "feat: port AI chat components"
```

---

### Task 11: Port run components

**Files:**
- Create: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx`
- Create: `flovyn-app/apps/web/components/ai/run/execution-tree.tsx`
- Create: `flovyn-app/apps/web/components/ai/run/run-panel-tabs.tsx`
- Create: `flovyn-app/apps/web/components/ai/run/run-panel-content.tsx`

**Step 1: Copy all run components**

Copy from `flovyn-ai/apps/web/src/components/run/` to `flovyn-app/apps/web/components/ai/run/`.

**Step 2: Update imports**

Same pattern as Task 10:
- `@/components/ui/*` → `@workspace/ui/components/*`
- `@/lib/utils` → `@workspace/ui/lib/utils`
- `@/components/` → `@/components/ai/`
- `@/lib/mock-data` → `@/lib/ai/mock-data`

The `unified-run-view.tsx` is the most import-heavy. Key imports to rewrite:
- `@assistant-ui/react` — stays as-is (now in deps)
- `ResizablePanelGroup` from `react-resizable-panels` — stays as-is (already in deps)
- Internal component references → update to `@/components/ai/...`

**Step 3: Commit**

```bash
git add apps/web/components/ai/run/
git commit -m "feat: port AI run components"
```

---

## Phase 4: Pages — Port All Routes

### Task 12: Create AI layout

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/layout.tsx`

**Step 1: Create the layout file**

This is a minimal pass-through layout. The org layout already provides sidebar, header, auth, and providers. The AI layout just wraps children:

```tsx
import { type ReactNode } from 'react';

export default function AILayout({ children }: { children: ReactNode }) {
  return <>{children}</>;
}
```

Keep it simple — no extra wrappers needed. The org layout handles everything.

**Step 2: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/
git commit -m "feat: add AI section layout"
```

---

### Task 13: Port AI dashboard page (home)

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx`

**Step 1: Copy and adapt page.tsx**

Copy `flovyn-ai/apps/web/src/app/page.tsx` to `flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx`.

Rewrites needed:
- Remove font CSS variable references (`var(--font-sans)`, `var(--font-serif)`) — Geist fonts are set at root level
- Update `useRouter` navigation: `router.push('/runs/new?prompt=...')` → `router.push(\`/org/${orgSlug}/ai/runs/new?prompt=...\`)`
- Add `useOrgSlug` hook: `import { useOrgSlug } from '@/hooks/use-org-slug'` and `const { orgSlug } = useOrgSlug()`
- Update imports: `@/components/ai/icons` for custom icons
- Replace `FlovynLogo` import if used, or remove if not needed in the org-scoped context
- Add `'use client'` directive at the top

**Step 2: Verify the page renders**

```bash
cd flovyn-app && pnpm --filter web dev
```

Navigate to `/org/{slug}/ai`. Verify the dashboard renders with prompt input and example cards.

**Step 3: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/page.tsx
git commit -m "feat: port AI dashboard page"
```

---

### Task 14: Port runs pages

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/page.tsx`
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/new/page.tsx`
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx`

**Step 1: Copy and adapt runs/page.tsx**

Copy `flovyn-ai/apps/web/src/app/runs/page.tsx`. Rewrites:
- `@/lib/mock-data` → `@/lib/ai/mock-data`
- `@/components/*` → `@/components/ai/*`
- Navigation links: `/runs/{id}` → `/org/${orgSlug}/ai/runs/{id}`
- "New Run" link: `/` → `/org/${orgSlug}/ai`
- Add `useOrgSlug` hook

**Step 2: Copy and adapt runs/new/page.tsx**

Copy `flovyn-ai/apps/web/src/app/runs/new/page.tsx`. Rewrites:
- `@/components/run/unified-run-view` → `@/components/ai/run/unified-run-view`
- Navigation back: `/` → `/org/${orgSlug}/ai`

**Step 3: Copy and adapt runs/[runId]/page.tsx**

Copy `flovyn-ai/apps/web/src/app/runs/[runId]/page.tsx`. Rewrites:
- Same import pattern as above
- `@/lib/mock-data` → `@/lib/ai/mock-data`

**Step 4: Verify all three pages render**

Navigate to `/org/{slug}/ai/runs`, click into a run, and verify the new run flow works.

**Step 5: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/runs/
git commit -m "feat: port AI runs pages (list, new, detail)"
```

---

### Task 15: Port agents pages

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/agents/page.tsx`
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/agents/[agentId]/page.tsx`

**Step 1: Copy and adapt agents/page.tsx**

Copy `flovyn-ai/apps/web/src/app/agents/page.tsx`. Rewrites:
- All `@/components/*` → `@/components/ai/*`
- `@/lib/mock-data` → `@/lib/ai/mock-data`
- Navigation: `/agents/{id}` → `/org/${orgSlug}/ai/agents/{id}`
- Add `useOrgSlug` hook

**Step 2: Copy and adapt agents/[agentId]/page.tsx**

Copy `flovyn-ai/apps/web/src/app/agents/[agentId]/page.tsx`. Rewrites:
- Same import pattern
- Navigation links to runs: `/runs/{id}` → `/org/${orgSlug}/ai/runs/{id}`
- Breadcrumb "Agents" link: `/agents` → `/org/${orgSlug}/ai/agents`

**Step 3: Verify both pages render**

Navigate to `/org/{slug}/ai/agents` and click into an agent.

**Step 4: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/agents/
git commit -m "feat: port AI agents pages (list, detail)"
```

---

### Task 16: Port workflows pages

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/workflows/page.tsx`
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/workflows/[workflowId]/page.tsx`

**Step 1: Copy and adapt workflows/page.tsx**

Copy `flovyn-ai/apps/web/src/app/workflows/page.tsx`. Rewrites:
- `@/components/*` → `@/components/ai/*`
- `@/lib/mock-data` → `@/lib/ai/mock-data`
- Navigation: `/workflows/{id}` → `/org/${orgSlug}/ai/workflows/{id}`
- Add `useOrgSlug` hook

**Step 2: Copy and adapt workflows/[workflowId]/page.tsx**

Copy `flovyn-ai/apps/web/src/app/workflows/[workflowId]/page.tsx`. Rewrites:
- `WorkflowEditor` import: `@flovyn/workflow-builder` → `@workspace/workflow-builder`
- `useWorkflowStore`: same package rename
- Other component imports follow the standard pattern
- Breadcrumb "Workflows" link → `/org/${orgSlug}/ai/workflows`

**Step 3: Verify both pages render**

Navigate to `/org/{slug}/ai/workflows`. Click into a workflow — verify the canvas editor loads.

**Step 4: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/workflows/
git commit -m "feat: port AI workflows pages (list, builder)"
```

---

### Task 17: Port tools pages

**Files:**
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/tools/page.tsx`
- Create: `flovyn-app/apps/web/app/org/[orgSlug]/ai/tools/[toolId]/page.tsx`

**Step 1: Copy and adapt tools/page.tsx**

Copy `flovyn-ai/apps/web/src/app/tools/page.tsx`. Rewrites:
- Standard import rewrite pattern
- Navigation: `/tools/{id}` → `/org/${orgSlug}/ai/tools/{id}`

**Step 2: Copy and adapt tools/[toolId]/page.tsx**

Copy `flovyn-ai/apps/web/src/app/tools/[toolId]/page.tsx`. Rewrites:
- Standard import rewrite pattern
- Agent link: `/agents/{id}` → `/org/${orgSlug}/ai/agents/{id}`
- Runs link: `/runs` → `/org/${orgSlug}/ai/runs`
- Breadcrumb "Tools" link → `/org/${orgSlug}/ai/tools`

**Step 3: Verify both pages render**

Navigate to `/org/{slug}/ai/tools`. Click into a tool.

**Step 4: Commit**

```bash
git add apps/web/app/org/\[orgSlug\]/ai/tools/
git commit -m "feat: port AI tools pages (list, detail)"
```

---

## Phase 5: Verification

### Task 18: Full build verification

**Step 1: Run typecheck**

```bash
cd flovyn-app && pnpm --filter web typecheck
```

Expected: No type errors. If there are React 19 compatibility issues with `@assistant-ui/react` or `@xyflow/react`, fix the specific type mismatches (usually `React.ReactNode` vs `React.ReactElement`).

**Step 2: Run full build**

```bash
pnpm build
```

Expected: All packages and apps build successfully.

**Step 3: Run existing tests**

```bash
pnpm --filter web test:run
```

Expected: All existing tests still pass — we haven't modified any existing functionality.

**Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: resolve type errors from AI UI migration"
```

---

### Task 19: Manual smoke test all AI pages

**Step 1: Start the dev server**

```bash
cd flovyn-app && pnpm --filter web dev
```

**Step 2: Verify each page loads without errors**

Navigate to each route and verify:
- [ ] `/org/{slug}/ai` — Dashboard with prompt input, example cards, evolution model
- [ ] `/org/{slug}/ai/runs` — Runs list with live and history sections
- [ ] `/org/{slug}/ai/runs/new?prompt=test` — New run view with chat
- [ ] `/org/{slug}/ai/agents` — Agents list with filter tabs
- [ ] `/org/{slug}/ai/agents/a1` — Agent detail with sessions, tools, config tabs
- [ ] `/org/{slug}/ai/workflows` — Workflows list with cards
- [ ] `/org/{slug}/ai/workflows/w1` — Workflow builder with canvas and runs tabs
- [ ] `/org/{slug}/ai/tools` — Tools list in 2-column grid
- [ ] `/org/{slug}/ai/tools/tl1` — Tool detail with parameters

**Step 3: Verify navigation integration**

- [ ] Sidebar shows "AI" item and highlights it when on `/ai` routes
- [ ] Breadcrumbs show correct hierarchy (e.g., "AI > Agents > Customer Support Agent")
- [ ] Links within AI pages navigate correctly (e.g., clicking an agent card goes to agent detail)
- [ ] "New Run" from runs page navigates to AI dashboard

**Step 4: Commit final state**

```bash
git add -A && git commit -m "feat: complete AI UI migration from flovyn-ai"
```
