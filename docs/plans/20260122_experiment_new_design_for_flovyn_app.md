# Implementation Plan: Experiment New Design for Flovyn App

**Date:** 2026-01-22
**Design:** [20260122_experiment_new_design_for_flovyn_app.md](../design/20260122_experiment_new_design_for_flovyn_app.md)

---

## Pre-Implementation Notes

### Codebase Findings

After reviewing the codebase:

1. **Storybook**: Already configured at `flovyn-app/.storybook/` with `withThemeByClassName` decorator for light/dark toggle
2. **CSS Variables**: Complete set in `packages/ui/src/styles/globals.css` (45+ variables including sidebar, RevoGrid)
3. **Components**: 29 components use `data-slot` attributes, enabling CSS-only targeting
4. **Stories**: 10 existing stories focused on event/timeline components
5. **Font**: Geist is loaded via `next/font/google` in the app (not directly available in Storybook)

### Design Clarifications

- **Font choice**: Use Space Grotesk for the experimental theme (as recommended in design) since Geist requires Next.js font loading. Space Grotesk via Google Fonts works in Storybook.
- **Theme toggle integration**: The new "Design" toggle will be independent of the existing light/dark toggle. Both should work together (design × theme = 4 combinations).
- **Information-dense datagrids**: The app's datagrids are information-dense. The experimental theme must prioritize:
  - Compact but readable typography (no increase in row height)
  - Clear visual separation without heavy borders
  - Status indicators that don't compete for attention
  - Comfortable for extended use (reduced eye strain)

### Implementation Approach

Use the `frontend-design` skill during Phase 6 (Showcase Stories) to ensure the experimental theme achieves high design quality and avoids generic AI aesthetics.

---

## Phase 1: Infrastructure Setup

### Objective
Set up the experimental theme infrastructure in Storybook without affecting production.

- [x] **1.1** Create experimental theme CSS file at `flovyn-app/.storybook/experimental-theme.css`
  - Import Space Grotesk from Google Fonts
  - Define `.theme-experiment` class with all CSS variable overrides
  - Define `.theme-experiment.dark` for dark mode variants
  - Include transition variables (`--transition-fast`, `--transition-normal`, `--transition-slow`)

- [x] **1.2** Update Storybook configuration (`flovyn-app/.storybook/preview.tsx`)
  - Import the experimental CSS file
  - Add `design` globalType to toolbar with "Current" and "Experimental" options
  - Create decorator that conditionally wraps stories in `.theme-experiment` div based on global
  - Ensure the decorator works alongside the existing `withThemeByClassName` decorator

- [x] **1.3** Verify infrastructure works
  - Run Storybook (`pnpm storybook` in flovyn-app)
  - Confirm both toggles appear in toolbar (Theme: light/dark, Design: current/experiment)
  - Verify toggling Design does not affect existing stories when set to "Current"
  - Verify font changes when switching to "Experimental"

---

## Phase 2: Core Theme Implementation (Option B - Technical Precision)

### Objective
Implement the full "Technical Precision" aesthetic as CSS variable overrides.

- [x] **2.1** Define color palette in experimental theme CSS
  - Primary: Vibrant cyan/electric blue (`oklch(0.65 0.18 220)` range)
  - Background: Cool grays with subtle blue undertone
  - Sidebar: Slightly tinted background for visual grounding
  - Chart colors: Updated to match new palette
  - Full light and dark mode definitions

- [x] **2.2** Define typography overrides
  - `--font-sans: 'Space Grotesk', system-ui, sans-serif`
  - Consider slightly tighter letter-spacing for headers
  - Keep monospace as JetBrains Mono (already good)

- [x] **2.3** Define spacing and radius
  - `--radius: 0.25rem` (4px) for subtle radius
  - Some sharp corners (0px) for specific elements via additional selectors

- [x] **2.4** Define enhanced shadow system
  - Crisp shadows with subtle color tint
  - Higher contrast than current soft shadows
  - Define `--shadow-sm` through `--shadow-xl` overrides

---

## Phase 3: Micro-Interactions

### Objective
Add CSS transitions and hover effects to interactive elements.

- [x] **3.1** Add base transitions to experimental theme CSS
  - Target `[data-slot="button"]` for button hover effects
  - Target `[data-slot="card"]` for card hover lift
  - Target `[data-slot="input"]` for focus transitions
  - Use `transform: translateY(-1px)` and shadow changes on hover

- [x] **3.2** Define focus states
  - Enhanced ring visibility
  - Smooth transition from unfocused to focused state

- [x] **3.3** Sidebar navigation transitions
  - Active state transitions
  - Hover feedback on nav items

---

## Phase 4: RevoGrid Theme

### Objective
Refine data grid styling for information-dense grids: scannability without wasted space, reduced eye strain.

- [x] **4.1** Override RevoGrid variables within `.theme-experiment .revogrid-flovyn`
  - Typography: Keep compact (`--rgFontSize: 13px`, current is 13px) - do NOT increase
  - Row height: Maintain current `--rgRowHeight: 40px` - no increase
  - Row backgrounds: Very subtle alternating tint (nearly invisible, just enough for row tracking)
  - Hover: Visible but not distracting (`oklch(0.96 0.015 220)`)
  - Headers: Slightly stronger visual separation, but lightweight
  - Cell padding: Keep current `0 0.75rem` - compact

- [x] **4.2** Status/badge visibility in grid context
  - Ensure badge colors work within dense rows
  - Status indicators should be clear but not dominant

- [x] **4.3** Define dark mode RevoGrid overrides
  - Appropriate contrast for dark backgrounds
  - Maintain same density principles

---

## Phase 5: Sidebar & Header Theme

### Objective
Style the sidebar and header to frame content with the new aesthetic.

- [x] **5.1** Override sidebar variables within `.theme-experiment`
  - `--sidebar`: Subtle depth/tint distinct from main background
  - `--sidebar-accent`: Clear active state
  - `--sidebar-border`: Refined separator
  - Apply to both light and dark modes

- [x] **5.2** Test with existing sidebar component
  - Verify active/hover states are clear
  - Verify collapsed/expanded states render correctly

---

## Phase 6: Showcase Stories

### Objective
Create demonstration stories that showcase the experimental design.

- [x] **6.1** Create story directory `flovyn-app/apps/web/components/design-experiments/`

- [x] **6.2** Create `ThemeShowcase.stories.tsx`
  - Display color palette swatches (primary, secondary, accents, charts)
  - Typography samples (headings, body, mono)
  - Shadow examples
  - Transition/animation demos

- [x] **6.3** Create `ComponentGallery.stories.tsx`
  - Buttons (all variants and sizes)
  - Inputs, selects, checkboxes, switches
  - Cards with different content types
  - Badges and alerts
  - Forms with validation states

- [x] **6.4** Create `DataGridShowcase.stories.tsx`
  - Grid with workflow/task data (realistic, information-dense Flovyn data)
  - Multiple columns: ID, name, status, timestamps, metrics
  - Multiple status indicators in single rows
  - Row hover and selection states
  - Show grid with 20+ rows to demonstrate scanability at scale
  - Use `frontend-design` skill to ensure polished, production-quality output

- [x] **6.5** Create `LayoutShowcase.stories.tsx`
  - Sidebar with navigation items (active, hover, disabled states)
  - Header with breadcrumbs
  - Combined sidebar + content layout

---

## Phase 7: Testing & Polish

### Objective
Validate the experimental theme across all conditions.

- [x] **7.1** Cross-mode testing
  - Test all 4 combinations: current×light, current×dark, experiment×light, experiment×dark
  - Document any visual issues

- [x] **7.2** Accessibility check
  - Verify color contrast meets WCAG AA (4.5:1 for text)
  - Test focus indicators are visible
  - Run Storybook a11y addon on showcase stories

- [x] **7.3** Performance check
  - Verify no layout shifts when toggling themes
  - Ensure transitions are smooth (no jank)

- [x] **7.4** Final polish
  - Address any visual inconsistencies found during testing
  - Fine-tune color values if needed
  - Update any CSS that didn't apply correctly

---

## Test Plan

### Manual Testing

1. **Infrastructure verification**
   - Storybook starts without errors
   - Both toolbar toggles work independently
   - Switching to "Current" design shows no changes from production

2. **Theme completeness**
   - Every CSS variable in `globals.css` has an experimental override
   - Light and dark modes are both complete
   - No "flash" of wrong colors when toggling

3. **Component coverage**
   - Run through ComponentGallery story - all components styled
   - Run through DataGridShowcase - grids look correct
   - Run through LayoutShowcase - sidebar/header render correctly

4. **Accessibility**
   - Run Storybook with `@storybook/addon-a11y` (already installed)
   - Check contrast on showcase stories
   - Verify focus states are visible

### Automated Testing

- Storybook interaction tests on showcase stories (if applicable)
- Visual regression optional (not in scope unless requested)

---

## Rollout Considerations

1. **Production isolation**: Experimental CSS only loads in Storybook (import in preview.tsx, not in production entry points)

2. **No component changes**: This experiment changes CSS variables only - component files remain unchanged

3. **Future promotion path**: If the experimental design is approved:
   - Extract final CSS variable values
   - Update `globals.css` with new values
   - Remove `.theme-experiment` scoping
   - Delete Storybook-only infrastructure

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `.storybook/experimental-theme.css` | Create | All experimental CSS variables and overrides |
| `.storybook/preview.tsx` | Modify | Add design toggle, import experimental CSS |
| `apps/web/components/design-experiments/ThemeShowcase.stories.tsx` | Create | Color/typography/shadow demos |
| `apps/web/components/design-experiments/ComponentGallery.stories.tsx` | Create | Form elements and UI components |
| `apps/web/components/design-experiments/DataGridShowcase.stories.tsx` | Create | RevoGrid demonstration |
| `apps/web/components/design-experiments/LayoutShowcase.stories.tsx` | Create | Sidebar and header demonstration |

---

## Progress Tracking

**Phase Status:**
- [x] Phase 1: Infrastructure Setup
- [x] Phase 2: Core Theme Implementation
- [x] Phase 3: Micro-Interactions
- [x] Phase 4: RevoGrid Theme
- [x] Phase 5: Sidebar & Header Theme
- [x] Phase 6: Showcase Stories
- [x] Phase 7: Testing & Polish

**Overall:** Complete
