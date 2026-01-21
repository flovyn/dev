# IAM Implementation Quick Reference

Quick reference for common tasks and code patterns.

**🔒 Architecture**: 100% Cookie-Based (4 Routes Only)
- All tokens in httpOnly cookies
- No client-side token management
- Automatic cookie transmission
- OpenID Connect compliant logout

---

## 🔐 Authentication

### Check if User is Authenticated

```tsx
import { useAuth } from '@/lib/auth/hooks'

function MyComponent() {
  const { isAuthenticated, isLoading, user } = useAuth()

  if (isLoading) return <div>Loading...</div>
  if (!isAuthenticated) return <div>Please log in</div>

  return <div>Welcome, {user?.name}!</div>
}
```

### Login

```tsx
import { getAuthClient } from '@/lib/auth/client'

function LoginButton() {
  const handleLogin = async () => {
    const client = getAuthClient()
    await client.initiateLogin({ returnUrl: '/dashboard' })
  }

  return <button onClick={handleLogin}>Login</button>
}

// Or for SSO:
function GoogleLoginButton() {
  const handleLogin = () => {
    const client = getAuthClient()
    client.loginWithGoogle('/dashboard')
  }

  return <button onClick={handleLogin}>Login with Google</button>
}
```

### Logout

```tsx
import { getAuthClient } from '@/lib/auth/client'

function LogoutButton() {
  const handleLogout = async () => {
    const client = getAuthClient()
    await client.logout() // Calls /api/auth/logout which revokes tokens on backend
    window.location.href = '/auth/login'
  }

  return <button onClick={handleLogout}>Logout</button>
}
```

### Protect a Page

```tsx
import { useRequireAuth } from '@/lib/auth/hooks'

function ProtectedPage() {
  const { isAuthenticated, isLoading } = useRequireAuth()

  if (isLoading) return <div>Loading...</div>
  if (!isAuthenticated) return null // Will redirect

  return <div>Protected content</div>
}
```

### Check User Role

```tsx
import { useIsAdmin, useIsOwner } from '@/lib/auth/hooks'

function AdminPanel() {
  const isAdmin = useIsAdmin()
  const isOwner = useIsOwner()

  if (!isAdmin) return <div>Access Denied</div>

  return (
    <div>
      <h1>Admin Panel</h1>
      {isOwner && <button>Owner Settings</button>}
    </div>
  )
}
```

---

## 🌐 API Requests

### Basic API Call

```tsx
import { getApiClient } from '@/lib/api/client'

// GET request
const workflows = await getApiClient().get('/workflows')

// POST request
const newWorkflow = await getApiClient().post('/workflows', {
  name: 'My Workflow',
  description: 'Test workflow'
})

// PUT request
await getApiClient().put('/workflows/123', { name: 'Updated' })

// DELETE request
await getApiClient().delete('/workflows/123')
```

### Tenant-Scoped Request

```tsx
import { getApiClient } from '@/lib/api/client'

const workflows = await getApiClient().get('/workflows', {
  tenantSlug: 'acme-corp'
})
// Calls: /api/tenants/acme-corp/workflows
```

### With TanStack Query (Coming Soon)

```tsx
import { useWorkflows } from '@/lib/api/queries'

function WorkflowList({ tenantSlug }: { tenantSlug: string }) {
  const { data, isLoading, error } = useWorkflows(tenantSlug)

  if (isLoading) return <div>Loading...</div>
  if (error) return <div>Error: {error.message}</div>

  return (
    <ul>
      {data?.map(w => <li key={w.id}>{w.name}</li>)}
    </ul>
  )
}
```

---

## 🎨 UI Components

### Login Page

```tsx
// apps/web/app/auth/login/page.tsx
'use client'

import { useAuth } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'

export default function LoginPage() {
  const { login, error } = useAuth()

  return (
    <div>
      <h1>Login</h1>
      <Button onClick={() => login()}>Sign In</Button>
      {error && <div>{error}</div>}
    </div>
  )
}
```

### Protected Route

```tsx
// apps/web/app/dashboard/page.tsx
'use client'

import { useRequireAuth } from '@/lib/auth/hooks'

export default function DashboardPage() {
  const { isAuthenticated, isLoading } = useRequireAuth()

  if (isLoading) return <div>Loading...</div>
  if (!isAuthenticated) return null

  return <div>Dashboard Content</div>
}
```

### Navigation with Auth

```tsx
import { useAuth } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'

export function Navigation() {
  const { isAuthenticated, user, logout } = useAuth()

  return (
    <nav>
      <div>Flovyn</div>
      {isAuthenticated ? (
        <div>
          <span>{user?.name}</span>
          <Button onClick={logout}>Logout</Button>
        </div>
      ) : (
        <a href="/auth/login">Login</a>
      )}
    </nav>
  )
}
```

---

## 🔧 Configuration

### Environment Variables

```bash
# .env.local
NEXT_PUBLIC_API_URL=http://localhost:8080
NEXT_PUBLIC_OAUTH_CLIENT_ID=flovyn-web
NEXT_PUBLIC_OAUTH_REDIRECT_URI=http://localhost:3000/auth/callback
```

### Root Layout Setup

```tsx
// apps/web/app/layout.tsx
import { ReactQueryProvider } from '@/lib/api/query-client'
import { AuthInitializer } from '@/components/auth/auth-initializer'

export default function RootLayout({ children }) {
  return (
    <html>
      <body>
        <ReactQueryProvider>
          <AuthInitializer />
          {children}
        </ReactQueryProvider>
      </body>
    </html>
  )
}
```

---

## 🐛 Debugging

### Check Auth State

```tsx
import { useAuthStore } from '@/lib/auth/store'

function DebugAuth() {
  const state = useAuthStore()

  return <pre>{JSON.stringify(state, null, 2)}</pre>
}
```

### View Cookies (Limited Access)

```bash
# In browser console
document.cookie
# ⚠️ With httpOnly cookies, you WON'T see tokens here
# This is correct security behavior!
```

### Test Token Refresh

```tsx
// Refresh happens automatically on 401 errors
// Or you can manually trigger it:
const response = await fetch('/api/auth/refresh-token', {
  method: 'POST',
  credentials: 'include'
})

const data = await response.json()
console.log('New access token:', data.access_token)
```

### Check Auth State

```tsx
import { useAuthStore } from '@/lib/auth/store'

function DebugAuth() {
  const state = useAuthStore()

  return <pre>{JSON.stringify(state, null, 2)}</pre>
}
```

---

## 📝 Common Patterns

### Conditional Rendering Based on Auth

```tsx
import { useAuth } from '@/lib/auth/hooks'

function ConditionalContent() {
  const { isAuthenticated, isLoading } = useAuth()

  if (isLoading) {
    return <Spinner />
  }

  return (
    <>
      {isAuthenticated ? (
        <AuthenticatedView />
      ) : (
        <PublicView />
      )}
    </>
  )
}
```

### Loading States

```tsx
import { useAuth } from '@/lib/auth/hooks'

function LoadingExample() {
  const { isLoading } = useAuth()

  return (
    <div>
      {isLoading && <Spinner />}
      <Content />
    </div>
  )
}
```

### Error Handling

```tsx
import { useAuth } from '@/lib/auth/hooks'

function ErrorHandling() {
  const { error, clearError } = useAuth()

  if (error) {
    return (
      <div>
        <p>Error: {error}</p>
        <button onClick={clearError}>Dismiss</button>
      </div>
    )
  }

  return <Content />
}
```

### Redirect After Login

```tsx
import { useAuth } from '@/lib/auth/hooks'
import { useRouter } from 'next/navigation'

function LoginWithRedirect() {
  const { login } = useAuth()
  const router = useRouter()

  const handleLogin = async () => {
    await login('/dashboard')
  }

  return <button onClick={handleLogin}>Login</button>
}
```

---

## 🔒 Security Best Practices

### ✅ DO

```tsx
// ✅ Use hooks for auth state
const { user } = useAuth()

// ✅ Use API client for requests
await getApiClient().get('/data')

// ✅ Protect sensitive routes
useRequireAuth()

// ✅ Check roles before showing admin UI
const isAdmin = useIsAdmin()
```

### ❌ DON'T

```tsx
// ❌ Don't access localStorage for tokens
localStorage.getItem('token') // No!

// ❌ Don't use fetch directly for authenticated requests
fetch('/api/data') // Use getApiClient() instead

// ❌ Don't show admin UI without checking role
<AdminPanel /> // Check role first!

// ❌ Don't store sensitive data in state
const [token, setToken] = useState() // Use secure storage
```

---

## 📚 File Locations

### Auth Files
- Types: `flovyn-app/apps/web/lib/auth/types.ts`
- Client: `flovyn-app/apps/web/lib/auth/client.ts`
- Store: `flovyn-app/apps/web/lib/auth/store.ts`
- Hooks: `flovyn-app/apps/web/lib/auth/hooks.ts`
- PKCE: `flovyn-app/apps/web/lib/auth/pkce.ts`
- Storage: `flovyn-app/apps/web/lib/auth/token-storage.ts`

### API Files
- Client: `flovyn-app/apps/web/lib/api/client.ts`
- Base Client: `flovyn-app/apps/web/lib/api/base-client.ts`
- Types: `flovyn-app/apps/web/lib/api/types.ts` (to be created)
- Queries: `flovyn-app/apps/web/lib/api/queries.ts` (to be created)

### Route Handlers (4 Routes Total)
- OAuth Callback: `flovyn-app/apps/web/app/auth/callback/route.ts`
- Refresh Token: `flovyn-app/apps/web/app/api/auth/refresh-token/route.ts`
- Logout: `flovyn-app/apps/web/app/api/auth/logout/route.ts`

### Pages (1 Page Total)
- Login: `flovyn-app/apps/web/app/auth/login/page.tsx`

---

## 🚀 Quick Commands

### Start Development

```bash
cd apps/web
pnpm dev
```

### Type Check

```bash
pnpm typecheck
```

### Lint

```bash
pnpm lint
```

### Build

```bash
pnpm build
```

---

## 🆘 Troubleshooting

### "No access token" error

**Solution**: Check if user is logged in and session hasn't expired.

```tsx
const { isAuthenticated } = useAuth()
if (!isAuthenticated) {
  // Redirect to login
}
```

### Token refresh fails

**Solution**: Check if refresh token cookie exists and is valid.

```tsx
const hasSession = await hasValidSession()
if (!hasSession) {
  // Session expired, redirect to login
}
```

### CORS errors

**Solution**: Ensure backend has CORS configured for `http://localhost:3000`.

### State mismatch error

**Solution**: Clear cookies and try login again. This happens if OAuth flow is interrupted.

```bash
# In browser console
document.cookie = 'oauth_state=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;'
document.cookie = 'oauth_code_verifier=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;'
```

---

## 📞 Need Help?

1. Check [Implementation Plan](./20251118_iam_implementation_plan.md)
2. Review [Security Architecture](./20251118_iam_security_architecture.md)
3. See [Implementation Progress](./20251118_iam_implementation_progress.md)
4. Ask in team chat

---

**Last Updated**: 2025-11-10
