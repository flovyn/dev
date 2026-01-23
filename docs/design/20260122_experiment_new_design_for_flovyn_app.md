# Design: Experiment New Design for Flovyn App

**Date:** 2026-01-22
**Status:** Draft
**GitHub Issue:** https://github.com/flovyn/flovyn-app/issues/2

---

## Problem Statement

The current Flovyn app design is described as "too rigid" and needs modernization. The existing design system uses:

- **Typography:** Inter (sans), Source Serif 4 (serif), JetBrains Mono (mono)
- **Colors:** Blue-purple primary (`oklch(0.6231 0.188 259.8145)`), neutral grays
- **Styling:** Standard shadcn/ui defaults with minimal customization
- **Borders:** 6px radius (`--radius: 0.375rem`)

While functional, the current aesthetic lacks distinctive character and feels generic. The goal is to explore modern design directions without disrupting the production application.

---

## Goals

1. **Experiment safely** - Test new design directions in Storybook without affecting production
2. **Modern aesthetic** - Move away from generic shadcn defaults toward a distinctive visual identity
3. **Preserve functionality** - All existing shadcn components continue to work
4. **Easy comparison** - Toggle between current and experimental themes in Storybook

## Non-Goals

- Modifying production pages or layouts
- Creating new components (only restyle existing ones)
- Changing component APIs or behavior
- Full redesign of the entire app (this is an experiment)

---

## Current State Analysis

### Existing Infrastructure

The codebase has solid foundations for theming:

| Asset | Location | Purpose |
|-------|----------|---------|
| Global CSS | `packages/ui/src/styles/globals.css` | CSS variables, Tailwind config |
| Storybook | `.storybook/` | Theme switching via addon-themes |
| Components | `packages/ui/src/components/` | 35+ shadcn components |
| Stories | `apps/web/components/**/*.stories.tsx` | Component documentation |

### Current Theme Variables

```css
:root {
  --background: oklch(1 0 0);           /* White */
  --foreground: oklch(0.3211 0 0);      /* Dark gray */
  --primary: oklch(0.6231 0.188 259.8145); /* Blue-purple */
  --radius: 0.375rem;                    /* 6px */
  --font-sans: Inter, sans-serif;
}
```

### What Makes It "Rigid"

1. **Generic typography** - Inter is ubiquitous, lacks personality
2. **Safe color palette** - Blue-purple is common in SaaS apps
3. **Uniform border radius** - Everything has the same roundness
4. **Minimal shadows** - Flat appearance, little depth
5. **No motion** - Static interface, no micro-interactions

---

## Proposed Solution

### Approach: Isolated Experimental Theme

Create an experimental theme system that:

1. Lives in a separate CSS file loaded only in Storybook
2. Uses CSS class scoping (`.theme-experiment`) to isolate changes
3. Provides a Storybook decorator to wrap stories with the experimental theme
4. Creates showcase stories demonstrating the new design

### Architecture

```
flovyn-app/
├── .storybook/
│   ├── preview.tsx                    # Add experimental theme toggle
│   └── experimental-theme.css         # NEW: Experimental CSS variables
├── apps/web/components/
│   └── design-experiments/            # NEW: Showcase stories
│       ├── ThemeShowcase.stories.tsx
│       ├── DataGridShowcase.stories.tsx
│       └── ComponentGallery.stories.tsx
```

### Theme Isolation Strategy

The experimental theme will be scoped using a wrapper class:

```css
/* Only affects elements inside .theme-experiment */
.theme-experiment {
  --background: ...;
  --primary: ...;
  /* all overrides here */
}
```

Storybook decorator:

```tsx
// Wraps story in experimental theme container
(Story) => (
  <div className="theme-experiment">
    <Story />
  </div>
)
```

This ensures:
- Production CSS (`globals.css`) remains unchanged
- Experimental styles only load in Storybook
- Easy A/B comparison by toggling decorator

---

## Design Direction Options

Three potential aesthetic directions to explore:

### Option A: Warm Minimalism

- **Typography:** DM Sans or Outfit (modern geometric) + Lora serif accents
- **Colors:** Warm neutrals (cream backgrounds), terracotta/rust accent
- **Borders:** Mixed radii (sharp cards, pill buttons)
- **Shadows:** Soft, warm-tinted shadows
- **Motion:** Gentle easing, subtle fade-ins
- **Character:** Approachable, editorial, human

### Option B: Technical Precision

- **Typography:** Geist (already in codebase) or Space Grotesk
- **Colors:** Cool grays, vibrant cyan/electric blue accent, high contrast
- **Borders:** Subtle radius (2-4px), some sharp corners
- **Shadows:** Crisp, minimal shadows with subtle color tint
- **Motion:** Snappy transitions, precise timing
- **Character:** Professional, developer-focused, precise

### Option C: Soft Modern

- **Typography:** Plus Jakarta Sans (friendly geometric, open source)
- **Colors:** Soft gradients, teal/emerald primary, muted pastels
- **Borders:** Generous radius (12-16px), glass-morphism cards
- **Shadows:** Layered depth, subtle blur, ambient glow
- **Motion:** Smooth springs, playful hover effects
- **Character:** Modern SaaS, approachable, polished

**Recommendation:** Start with **Option B (Technical Precision)** as it aligns with Flovyn's developer-focused audience while still modernizing the look. Geist is already loaded in the app, reducing implementation complexity.

All fonts listed are open source and available via Google Fonts or Fontsource.

---

## Technical Decisions

### CSS Variable Scoping

Use class-based scoping rather than `:root` overrides:

```css
/* Good - isolated */
.theme-experiment { --primary: ...; }

/* Bad - affects production */
:root { --primary: ...; }
```

### Font Loading in Storybook

Geist is already loaded via `next/font/google` in the app. For Storybook, add via CSS import:

```css
/* Geist is available, but for additional experimental fonts: */
@import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap');

.theme-experiment {
  --font-sans: 'Space Grotesk', system-ui, sans-serif;
}
```

### Dark Mode Support

The experimental theme must define both light and dark variants:

```css
.theme-experiment {
  /* Light mode variables */
  --background: ...;
  --primary: ...;
}

.theme-experiment.dark {
  /* Dark mode overrides */
  --background: ...;
  --primary: ...;
}
```

The existing `withThemeByClassName` decorator in Storybook already handles the `.dark` class toggle.

### Storybook Configuration

Add experimental design toggle to toolbar (alongside existing light/dark toggle):

```ts
// .storybook/preview.tsx
globalTypes: {
  theme: { /* existing light/dark toggle */ },
  design: {
    description: 'Design system variant',
    toolbar: {
      title: 'Design',
      icon: 'paintbrush',
      items: [
        { value: 'current', title: 'Current Design' },
        { value: 'experiment', title: 'Experimental' },
      ],
      dynamicTitle: true,
    },
  },
}
```

### Micro-Interactions

Define CSS transitions for experimental theme:

```css
.theme-experiment {
  /* Base transition for interactive elements */
  --transition-fast: 150ms cubic-bezier(0.4, 0, 0.2, 1);
  --transition-normal: 200ms cubic-bezier(0.4, 0, 0.2, 1);
  --transition-slow: 300ms cubic-bezier(0.4, 0, 0.2, 1);
}

/* Apply to buttons, inputs, cards */
.theme-experiment [data-slot="button"],
.theme-experiment [data-slot="card"] {
  transition: transform var(--transition-fast),
              box-shadow var(--transition-fast),
              background-color var(--transition-fast);
}

.theme-experiment [data-slot="button"]:hover {
  transform: translateY(-1px);
}

.theme-experiment [data-slot="card"]:hover {
  box-shadow: var(--shadow-lg);
}
```

### Story Organization

New stories under `design-experiments/`:

| Story | Purpose |
|-------|---------|
| `ThemeShowcase` | Color palette, typography, spacing demos |
| `DataGridShowcase` | Data grid styling with various data densities |
| `LayoutShowcase` | Sidebar and header with navigation states |
| `ComponentGallery` | Core form components, buttons, cards |

### Data Grid Design (Primary Focus)

The app is data-heavy with RevoGrid tables. The experimental theme must prioritize **scannable, beautiful data grids**:

**Current issues with grids:**
- Generic row styling, hard to scan
- Status indicators lack visual weight
- Hover states are subtle
- Headers blend into content

**Experimental grid improvements:**

```css
.theme-experiment .revogrid-flovyn {
  /* Typography: slightly larger, better line height */
  --rgFontSize: 13.5px;

  /* Row styling: subtle alternating or clean separators */
  --rgRowBg: transparent;
  --rgRowAltBg: oklch(0.98 0.005 250);  /* Very subtle blue tint */

  /* Hover: more visible feedback */
  --rgRowHoverBg: oklch(0.95 0.02 250);

  /* Headers: stronger visual separation */
  --rgHeaderBg: oklch(0.97 0.01 250);
  --rgHeaderFontColor: oklch(0.4 0 0);
}
```

**Key grid design goals:**
1. **Scannability** - Easy to follow rows horizontally
2. **Status clarity** - Badges/indicators pop without being garish
3. **Preserve density** - Grids are intentionally information-dense; do NOT increase row height or font size
4. **Reduced eye strain** - Subtle backgrounds, good contrast for text, avoid heavy visual elements

### Sidebar & Header Design

The sidebar and header frame all content and set the app's visual tone.

**Sidebar considerations:**
- Navigation items should have clear active/hover states
- Collapsible sections need smooth transitions
- Icons should align with the new aesthetic
- Consider subtle background treatment (gradient, texture, or solid)

**Header considerations:**
- Breadcrumbs need clear hierarchy without clutter
- Action buttons (help, account) should be discoverable but not distracting
- Height should feel balanced with content density

**Experimental sidebar/header improvements:**

```css
.theme-experiment {
  /* Sidebar: subtle depth */
  --sidebar: oklch(0.98 0.008 250);
  --sidebar-accent: oklch(0.94 0.03 250);
  --sidebar-border: oklch(0.92 0.01 250);

  /* Active nav item: clear but not heavy */
  --sidebar-primary: oklch(0.55 0.15 250);
}

.theme-experiment.dark {
  --sidebar: oklch(0.15 0.01 250);
  --sidebar-accent: oklch(0.22 0.02 250);
  --sidebar-border: oklch(0.25 0.01 250);
}
```

**Key sidebar/header goals:**
1. **Clear navigation** - Active state is obvious at a glance
2. **Visual grounding** - Sidebar anchors the layout without dominating
3. **Smooth transitions** - Collapse/expand feels polished
4. **Dark mode parity** - Both modes feel intentional, not inverted

---

## Decisions

| Question | Decision |
|----------|----------|
| Font licensing | Open source fonts only (Google Fonts, Fontsource) |
| Dark mode | Support both light and dark modes |
| Micro-interactions | Include hover states, transitions, focus animations |
| Approval | User is the sole decider for production consideration |
| Success criteria | More visually appealing than current "boring" design while remaining practical for production use; will be refined iteratively |

---

## Design Principles

Given the goal of "fancy but practical" for a data-heavy application:

1. **Data first** - Grids and tables must be easy to scan, with clear row separation and status visibility
2. **Refined, not flashy** - Subtle sophistication over loud colors; the data is the star
3. **Comfortable density** - Optimal row height and spacing for extended use without eye strain
4. **Polished interactions** - Smooth hover states and transitions that feel responsive
5. **Consistent hierarchy** - Headers, content, and actions have clear visual weight

---

## Next Steps

1. Write implementation plan with concrete TODO items
2. Set up experimental theme infrastructure in Storybook
3. Implement Option B (Technical Precision) theme variables for:
   - Core colors and typography
   - Sidebar and header styling
   - Data grid (RevoGrid) refinements
4. Create showcase stories:
   - Data grid with realistic workflow/task data
   - Sidebar with navigation states
   - Component gallery for forms and buttons
5. Gather feedback and iterate
