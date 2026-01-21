# E2E Test Fixes: Admin Redirect Race Condition

**Date**: 2026-01-16
**Related Design**: N/A (Bug fix)

## Problem Summary

35 E2E tests are failing because admin-protected pages redirect to the dashboard before the user's member/role data loads. This is a **race condition** where:

1. Page loads and checks `!orgLoading && !isAdmin` or `!isLoading && !isAdmin`
2. But `isAdmin` from `useIsOrgAdmin()` depends on `useActiveMember()` which has its own loading state
3. When the first condition (org/data loading) completes before member data loads, `isAdmin` is false (undefined member → false check)
4. User gets redirected to dashboard even though they ARE an admin

### Evidence

Screenshot from `test-results/settings-worker-tokens-Wor-150f2-orker-tokens-or-empty-state-chromium/test-failed-1.png` shows the org dashboard instead of the Worker Tokens page, confirming the redirect occurred.

### Affected Pages

The following pages use `useIsOrgAdmin()` with redirect logic:

1. `flovyn-app/apps/web/app/org/[orgSlug]/settings/worker-tokens/page.tsx` - checks `!orgLoading && !isAdmin`
2. `flovyn-app/apps/web/app/org/[orgSlug]/settings/metadata-fields/page.tsx` - checks `!isLoading && !isAdmin`
3. `flovyn-app/apps/web/app/org/[orgSlug]/settings/page.tsx` - likely similar pattern
4. Other settings/admin pages

## Solution

Update `useIsOrgAdmin` hook to expose loading state, and update all pages to wait for member data before checking admin status.

### Option A: Enhance useIsOrgAdmin (Recommended)

Return both the admin status AND the loading state:

```typescript
export function useIsOrgAdmin(): { isAdmin: boolean; isPending: boolean } {
  const { data: member, isPending } = useActiveMember();
  return {
    isAdmin: member?.role === "owner" || member?.role === "admin",
    isPending,
  };
}
```

Then update pages:
```typescript
const { isAdmin, isPending: memberPending } = useIsOrgAdmin();

useEffect(() => {
  if (!orgLoading && !memberPending && !isAdmin) {
    router.push(`/org/${orgSlug}`);
  }
}, [orgLoading, memberPending, isAdmin, router, orgSlug]);
```

### Option B: Create useRequireAdmin hook

Create a hook that handles both the check and loading states together:

```typescript
export function useRequireAdmin(): { isAdmin: boolean; isLoading: boolean } {
  const { data: member, isPending: memberPending } = useActiveMember();
  const { isPending: orgPending } = useActiveOrganization();

  return {
    isAdmin: member?.role === "owner" || member?.role === "admin",
    isLoading: orgPending || memberPending,
  };
}
```

## TODO List

### Phase 1: Fix the Hook (Blocking Issue)

- [ ] 1.1 Update `useIsOrgAdmin()` in `flovyn-app//apps/web/lib/auth/organization-hooks.ts` to return `{ isAdmin, isPending }` instead of just `boolean`
- [ ] 1.2 Update `useIsOrgOwner()` similarly for consistency
- [ ] 1.3 Add a `useActiveMemberWithLoading()` helper if needed

### Phase 2: Update Affected Pages

- [ ] 2.1 Update `flovyn-app//apps/web/app/org/[orgSlug]/settings/worker-tokens/page.tsx` to use new hook signature
- [ ] 2.2 Update `flovyn-app//apps/web/app/org/[orgSlug]/settings/metadata-fields/page.tsx`
- [ ] 2.3 Update `flovyn-app//apps/web/app/org/[orgSlug]/settings/page.tsx`
- [ ] 2.4 Update any other pages using `useIsOrgAdmin()` with redirect logic
- [ ] 2.5 Search for similar patterns in other pages (members, workflows, tasks, etc.)

### Phase 3: Verify with E2E Tests

- [ ] 3.1 Run the specific failing tests individually to verify fixes work
- [ ] 3.2 Run full E2E test suite to verify all tests pass
- [ ] 3.3 Verify no regressions in previously passing tests

## Files to Modify

1. `flovyn-app//apps/web/lib/auth/organization-hooks.ts` - core hook changes
2. `flovyn-app//apps/web/app/org/[orgSlug]/settings/worker-tokens/page.tsx`
3. `flovyn-app//apps/web/app/org/[orgSlug]/settings/metadata-fields/page.tsx`
4. `flovyn-app//apps/web/app/org/[orgSlug]/settings/page.tsx`
5. Potentially: members, workflows, tasks pages if they have similar patterns

## Testing

After fixes:
1. Run: `flovyn-app/pnpm exec playwright test tests/e2e/settings/worker-tokens.spec.ts`
2. Run: `flovyn-app/pnpm exec playwright test tests/e2e/settings/metadata-fields.spec.ts`
3. Run: `pnpm exec playwright test` (full suite)
