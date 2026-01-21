# IAM Implementation Plan

**Status**: In Progress (Week 1-2 Complete)
**Last Updated**: 2025-11-10
**Timeline**: 5 weeks
**Team Size**: 1-2 developers
**Progress**: ~35% Complete

**📚 Related Documentation**:
- [Implementation Progress](./20251118_iam_implementation_progress.md) - Detailed progress tracking
- [Security Architecture](./20251118_iam_security_architecture.md) - Security design and best practices

**🔒 Security Note**: This implementation uses **enhanced security** with server-side OAuth callback handling, httpOnly cookies, and in-memory token storage. See [Security Architecture](./20251118_iam_security_architecture.md) for details.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Week 1: Foundation](#week-1-foundation)
4. [Week 2: API Integration](#week-2-api-integration)
5. [Week 3: Authentication UI](#week-3-authentication-ui)
6. [Week 4: Multi-Tenant Features](#week-4-multi-tenant-features)
7. [Week 5: IAM Features & Polish](#week-5-iam-features--polish)
8. [Testing Checklist](#testing-checklist)
9. [Deployment Checklist](#deployment-checklist)

---

## Overview

This plan implements authentication and authorization for the Flovyn frontend using:
- OAuth2 Authorization Code Flow with PKCE
- SSO (Google/GitHub) with JIT provisioning
- Multi-tenant access control
- Space and user management

**Supported Features:**
- ✅ Email/Password login via OAuth2
- ✅ Google SSO with auto-registration
- ✅ GitHub SSO with auto-registration
- ✅ Multi-tenant access
- ✅ Space management
- ✅ User invitation (admin only)
- ✅ Worker credential management

**Not Supported (Future):**
- ❌ Self-service user registration
- ❌ Email verification flow
- ❌ Password reset flow
- ❌ User profile editing

---

## Prerequisites

### Backend Requirements
- [ ] Flovyn backend running on `http://localhost:8080`
- [ ] OAuth2 client configured: `client_id = flovyn-web`
- [ ] Google SSO configured
- [ ] GitHub SSO configured
- [ ] Test user account created

### Environment Setup
- [ ] Node.js >= 20 installed
- [ ] pnpm 10.4.1 installed
- [ ] Backend API accessible
- [ ] CORS configured on backend for `http://localhost:3000`

### Tools
- [ ] VS Code or preferred IDE
- [ ] Browser with DevTools
- [ ] Postman or similar (for API testing)

---

## Week 1: Foundation

**Goal**: Set up core authentication infrastructure without breaking existing functionality.

### Day 1: Environment Setup

#### Task 1.1: Install Dependencies
```bash
# Navigate to web app
cd apps/web

# Install required packages
pnpm add @tanstack/react-query@^5.62.8
pnpm add @tanstack/react-query-devtools@^5.62.8
pnpm add jose@^5.9.6

# Verify installation
pnpm list @tanstack/react-query jose zustand
```

**Verification:**
- [ ] All packages installed successfully
- [ ] No version conflicts
- [ ] `package.json` updated

#### Task 1.2: Create Environment Variables
```bash
# Create .env.local in apps/web/
touch apps/web/.env.local
```

Add the following content:
```bash
# API Configuration
NEXT_PUBLIC_API_URL=http://localhost:8080
NEXT_PUBLIC_OAUTH_CLIENT_ID=flovyn-web
NEXT_PUBLIC_OAUTH_REDIRECT_URI=http://localhost:3000/auth/callback

# Optional: Enable debug logging
NEXT_PUBLIC_DEBUG_AUTH=true
```

**Verification:**
- [ ] `.env.local` created
- [ ] File added to `.gitignore`
- [ ] Variables accessible in code: `process.env.NEXT_PUBLIC_API_URL`

---

### Day 2: Type Definitions

#### Task 1.3: Create Auth Types

Create `flovyn-app/apps/web/lib/auth/types.ts`:
```typescript
// JWT Claims from backend
export interface JWTClaims {
  sub: string
  userId: string
  email: string
  name: string
  tenantId: string
  tenantRole: 'OWNER' | 'ADMIN' | 'MEMBER'
  tenants: Array<{
    tenantId: string
    role: 'OWNER' | 'ADMIN' | 'MEMBER'
  }>
  exp: number
  iat: number
}

// OAuth2 Token Response
export interface TokenResponse {
  access_token: string
  refresh_token: string
  token_type: 'Bearer'
  expires_in: number
  scope?: string
}

// OAuth2 Error Response
export interface OAuth2Error {
  error: string
  error_description?: string
  error_uri?: string
}

// Login Options
export interface LoginOptions {
  returnUrl?: string
}

// Auth State
export interface AuthState {
  isAuthenticated: boolean
  isLoading: boolean
  user: JWTClaims | null
  error: string | null
}
```

**Verification:**
- [ ] File created with no TypeScript errors
- [ ] Types match backend JWT structure

---

### Day 3: OAuth2 Client (Part 1 - PKCE)

#### Task 1.4: Implement PKCE Utilities

Create `flovyn-app/apps/web/lib/auth/pkce.ts`:
```typescript
/**
 * Generate a cryptographically random code verifier for PKCE.
 * Returns a base64url-encoded string of 32 random bytes.
 */
export function generateCodeVerifier(): string {
  const array = new Uint8Array(32)
  crypto.getRandomValues(array)
  return base64UrlEncode(array)
}

/**
 * Generate a code challenge from a code verifier using SHA-256.
 */
export async function generateCodeChallenge(
  verifier: string
): Promise<string> {
  const encoder = new TextEncoder()
  const data = encoder.encode(verifier)
  const hash = await crypto.subtle.digest('SHA-256', data)
  return base64UrlEncode(new Uint8Array(hash))
}

/**
 * Base64URL encode (RFC 4648 §5)
 */
function base64UrlEncode(buffer: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...buffer))
  return base64
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
}

/**
 * Generate a random state parameter for CSRF protection.
 */
export function generateState(): string {
  return crypto.randomUUID()
}
```

**Verification:**
- [ ] Run in browser console to test
- [ ] Verify code_verifier is 43 characters
- [ ] Verify code_challenge matches expected SHA-256 hash

#### Task 1.5: Write PKCE Tests

Create `flovyn-app/apps/web/lib/auth/__tests__/pkce.test.ts`:
```typescript
import { describe, test, expect } from '@jest/globals'
import { generateCodeVerifier, generateCodeChallenge, generateState } from '../pkce'

describe('PKCE Utilities', () => {
  test('generateCodeVerifier creates 43-character string', () => {
    const verifier = generateCodeVerifier()
    expect(verifier).toHaveLength(43)
    expect(verifier).toMatch(/^[A-Za-z0-9_-]{43}$/)
  })

  test('generateCodeChallenge produces consistent hash', async () => {
    const verifier = 'test-verifier-string-for-testing'
    const challenge1 = await generateCodeChallenge(verifier)
    const challenge2 = await generateCodeChallenge(verifier)

    expect(challenge1).toBe(challenge2)
    expect(challenge1).toHaveLength(43)
    expect(challenge1).toMatch(/^[A-Za-z0-9_-]{43}$/)
  })

  test('generateState creates valid UUID', () => {
    const state = generateState()
    expect(state).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  })
})
```

**Note**: You'll need to set up Jest or Vitest later. For now, manually test in browser.

---

### Day 4: OAuth2 Client (Part 2 - Core Logic)

#### Task 1.6: Implement OAuth2 Client

Create `flovyn-app/apps/web/lib/auth/client.ts`:
```typescript
import { jwtDecode } from 'jose'
import type { JWTClaims, TokenResponse, LoginOptions } from './types'
import { generateCodeVerifier, generateCodeChallenge, generateState } from './pkce'

const API_URL = process.env.NEXT_PUBLIC_API_URL!
const CLIENT_ID = process.env.NEXT_PUBLIC_OAUTH_CLIENT_ID!
const REDIRECT_URI = process.env.NEXT_PUBLIC_OAUTH_REDIRECT_URI!

export class OAuth2Client {
  /**
   * Initiate OAuth2 login flow with PKCE.
   */
  async initiateLogin(options: LoginOptions = {}): Promise<void> {
    const codeVerifier = generateCodeVerifier()
    const codeChallenge = await generateCodeChallenge(codeVerifier)
    const state = generateState()

    // Store for callback validation
    sessionStorage.setItem('oauth_code_verifier', codeVerifier)
    sessionStorage.setItem('oauth_state', state)
    if (options.returnUrl) {
      sessionStorage.setItem('oauth_return_url', options.returnUrl)
    }

    // Build authorization URL
    const authUrl = new URL('/oauth2/authorize', API_URL)
    authUrl.searchParams.set('response_type', 'code')
    authUrl.searchParams.set('client_id', CLIENT_ID)
    authUrl.searchParams.set('redirect_uri', REDIRECT_URI)
    authUrl.searchParams.set('scope', 'openid profile email')
    authUrl.searchParams.set('state', state)
    authUrl.searchParams.set('code_challenge', codeChallenge)
    authUrl.searchParams.set('code_challenge_method', 'S256')

    // Redirect to authorization server
    window.location.href = authUrl.toString()
  }

  /**
   * Handle OAuth2 callback and exchange code for tokens.
   */
  async handleCallback(): Promise<{
    tokens: TokenResponse
    returnUrl: string | null
  }> {
    const params = new URLSearchParams(window.location.search)
    const code = params.get('code')
    const state = params.get('state')
    const error = params.get('error')

    // Check for OAuth errors
    if (error) {
      const errorDesc = params.get('error_description') || error
      throw new Error(`OAuth error: ${errorDesc}`)
    }

    if (!code) {
      throw new Error('No authorization code received')
    }

    // Validate state (CSRF protection)
    const storedState = sessionStorage.getItem('oauth_state')
    if (state !== storedState) {
      throw new Error('State mismatch - possible CSRF attack')
    }

    // Retrieve code verifier
    const codeVerifier = sessionStorage.getItem('oauth_code_verifier')
    if (!codeVerifier) {
      throw new Error('Code verifier not found')
    }

    // Exchange code for tokens
    const tokens = await this.exchangeCodeForTokens(code, codeVerifier)

    // Get return URL and cleanup
    const returnUrl = sessionStorage.getItem('oauth_return_url')
    sessionStorage.removeItem('oauth_code_verifier')
    sessionStorage.removeItem('oauth_state')
    sessionStorage.removeItem('oauth_return_url')

    return { tokens, returnUrl }
  }

  /**
   * Exchange authorization code for access and refresh tokens.
   */
  async exchangeCodeForTokens(
    code: string,
    codeVerifier: string
  ): Promise<TokenResponse> {
    const response = await fetch(`${API_URL}/oauth2/token`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        client_id: CLIENT_ID,
        code_verifier: codeVerifier,
      }),
    })

    if (!response.ok) {
      const error = await response.json().catch(() => ({}))
      throw new Error(error.error_description || 'Token exchange failed')
    }

    return response.json()
  }

  /**
   * Refresh access token using refresh token.
   */
  async refreshAccessToken(refreshToken: string): Promise<TokenResponse> {
    const response = await fetch(`${API_URL}/oauth2/token`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: CLIENT_ID,
      }),
    })

    if (!response.ok) {
      const error = await response.json().catch(() => ({}))
      throw new Error(error.error_description || 'Token refresh failed')
    }

    return response.json()
  }

  /**
   * Revoke a token (access or refresh).
   */
  async revokeToken(token: string): Promise<void> {
    await fetch(`${API_URL}/oauth2/revoke`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        token,
        client_id: CLIENT_ID,
      }),
    })
  }

  /**
   * Parse JWT and extract claims (no signature verification needed - backend does this).
   */
  parseJWT(token: string): JWTClaims {
    try {
      const decoded = jwtDecode<JWTClaims>(token)
      return decoded
    } catch (error) {
      throw new Error('Invalid JWT token')
    }
  }

  /**
   * Check if token is expired.
   */
  isTokenExpired(token: string): boolean {
    try {
      const claims = this.parseJWT(token)
      const now = Date.now() / 1000
      return claims.exp < now
    } catch {
      return true
    }
  }

  /**
   * Login with Google SSO.
   */
  loginWithGoogle(): void {
    window.location.href = `${API_URL}/auth/google`
  }

  /**
   * Login with GitHub SSO.
   */
  loginWithGitHub(): void {
    window.location.href = `${API_URL}/auth/github`
  }

  /**
   * Schedule automatic token refresh before expiry.
   */
  scheduleTokenRefresh(callback: () => void): NodeJS.Timeout | null {
    const token = sessionStorage.getItem('access_token')
    if (!token) return null

    try {
      const claims = this.parseJWT(token)
      const expiresIn = claims.exp * 1000 - Date.now()
      const refreshAt = expiresIn - 5 * 60 * 1000 // 5 minutes before expiry

      if (refreshAt > 0) {
        return setTimeout(() => {
          callback()
        }, refreshAt)
      }
    } catch (error) {
      console.error('Failed to schedule token refresh:', error)
    }

    return null
  }
}

// Singleton instance
let clientInstance: OAuth2Client | null = null

export function getAuthClient(): OAuth2Client {
  if (!clientInstance) {
    clientInstance = new OAuth2Client()
  }
  return clientInstance
}
```

**Verification:**
- [ ] No TypeScript errors
- [ ] Import `jose` works correctly
- [ ] Environment variables accessible

---

### Day 5: Auth Store with Zustand

#### Task 1.7: Implement Auth Store

Create `flovyn-app/apps/web/lib/auth/store.ts`:
```typescript
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import type { JWTClaims, TokenResponse } from './types'
import { getAuthClient } from './client'

interface AuthState {
  // State
  isAuthenticated: boolean
  isLoading: boolean
  user: JWTClaims | null
  error: string | null

  // Actions
  login: (returnUrl?: string) => Promise<void>
  logout: () => Promise<void>
  handleCallback: () => Promise<void>
  refreshToken: () => Promise<void>
  checkAuth: () => void
  setError: (error: string | null) => void
  clearError: () => void
}

export const useAuthStore = create<AuthState>()(
  devtools(
    (set, get) => ({
      // Initial state
      isAuthenticated: false,
      isLoading: true,
      user: null,
      error: null,

      // Actions
      login: async (returnUrl?: string) => {
        try {
          set({ isLoading: true, error: null })
          const client = getAuthClient()
          await client.initiateLogin({ returnUrl })
        } catch (error) {
          set({
            error: error instanceof Error ? error.message : 'Login failed',
            isLoading: false,
          })
        }
      },

      logout: async () => {
        try {
          set({ isLoading: true })
          const client = getAuthClient()
          const accessToken = sessionStorage.getItem('access_token')

          // Revoke tokens
          if (accessToken) {
            await client.revokeToken(accessToken)
          }

          // Clear storage
          sessionStorage.removeItem('access_token')
          sessionStorage.removeItem('refresh_token')

          // Reset state
          set({
            isAuthenticated: false,
            isLoading: false,
            user: null,
            error: null,
          })

          // Redirect to login
          window.location.href = '/auth/login'
        } catch (error) {
          console.error('Logout error:', error)
          // Clear state anyway
          set({
            isAuthenticated: false,
            isLoading: false,
            user: null,
            error: null,
          })
        }
      },

      handleCallback: async () => {
        try {
          set({ isLoading: true, error: null })
          const client = getAuthClient()

          const { tokens, returnUrl } = await client.handleCallback()

          // Store tokens
          sessionStorage.setItem('access_token', tokens.access_token)
          sessionStorage.setItem('refresh_token', tokens.refresh_token)

          // Parse user info from JWT
          const user = client.parseJWT(tokens.access_token)

          set({
            isAuthenticated: true,
            isLoading: false,
            user,
            error: null,
          })

          // Schedule token refresh
          client.scheduleTokenRefresh(() => {
            get().refreshToken()
          })

          // Redirect to return URL or default
          const destination = returnUrl || '/workflows'
          window.location.href = destination
        } catch (error) {
          set({
            error: error instanceof Error ? error.message : 'Callback failed',
            isLoading: false,
            isAuthenticated: false,
          })
        }
      },

      refreshToken: async () => {
        try {
          const refreshToken = sessionStorage.getItem('refresh_token')
          if (!refreshToken) {
            throw new Error('No refresh token available')
          }

          const client = getAuthClient()
          const tokens = await client.refreshAccessToken(refreshToken)

          // Store new tokens
          sessionStorage.setItem('access_token', tokens.access_token)
          if (tokens.refresh_token) {
            sessionStorage.setItem('refresh_token', tokens.refresh_token)
          }

          // Update user info
          const user = client.parseJWT(tokens.access_token)
          set({ user })

          // Reschedule refresh
          client.scheduleTokenRefresh(() => {
            get().refreshToken()
          })
        } catch (error) {
          console.error('Token refresh failed:', error)
          // Force logout on refresh failure
          get().logout()
        }
      },

      checkAuth: () => {
        const client = getAuthClient()
        const accessToken = sessionStorage.getItem('access_token')

        if (!accessToken) {
          set({ isLoading: false, isAuthenticated: false })
          return
        }

        try {
          // Check if token is expired
          if (client.isTokenExpired(accessToken)) {
            // Try to refresh
            get().refreshToken()
            return
          }

          // Token is valid
          const user = client.parseJWT(accessToken)
          set({
            isAuthenticated: true,
            isLoading: false,
            user,
          })

          // Schedule refresh
          client.scheduleTokenRefresh(() => {
            get().refreshToken()
          })
        } catch (error) {
          console.error('Auth check failed:', error)
          set({ isLoading: false, isAuthenticated: false })
        }
      },

      setError: (error: string | null) => {
        set({ error })
      },

      clearError: () => {
        set({ error: null })
      },
    }),
    { name: 'auth-store' }
  )
)
```

**Verification:**
- [ ] No TypeScript errors
- [ ] Zustand devtools accessible in browser

#### Task 1.8: Create Auth Hooks

Create `flovyn-app/apps/web/lib/auth/hooks.ts`:
```typescript
'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAuthStore } from './store'

/**
 * Main authentication hook.
 */
export function useAuth() {
  const isAuthenticated = useAuthStore((state) => state.isAuthenticated)
  const isLoading = useAuthStore((state) => state.isLoading)
  const user = useAuthStore((state) => state.user)
  const error = useAuthStore((state) => state.error)
  const login = useAuthStore((state) => state.login)
  const logout = useAuthStore((state) => state.logout)

  return {
    isAuthenticated,
    isLoading,
    user,
    error,
    login,
    logout,
  }
}

/**
 * Get current user.
 */
export function useUser() {
  return useAuthStore((state) => state.user)
}

/**
 * Get user's tenants.
 */
export function useTenants() {
  const user = useUser()
  return user?.tenants || []
}

/**
 * Check if user has admin role in current tenant.
 */
export function useIsAdmin() {
  const user = useUser()
  return user?.tenantRole === 'OWNER' || user?.tenantRole === 'ADMIN'
}

/**
 * Check if user has owner role in current tenant.
 */
export function useIsOwner() {
  const user = useUser()
  return user?.tenantRole === 'OWNER'
}

/**
 * Require authentication - redirect to login if not authenticated.
 */
export function useRequireAuth(redirectTo = '/auth/login') {
  const { isAuthenticated, isLoading } = useAuth()
  const router = useRouter()

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      const returnUrl = window.location.pathname + window.location.search
      router.push(`${redirectTo}?returnUrl=${encodeURIComponent(returnUrl)}`)
    }
  }, [isAuthenticated, isLoading, router, redirectTo])

  return { isAuthenticated, isLoading }
}
```

**Verification:**
- [ ] Hooks compile without errors
- [ ] `'use client'` directive present

---

## Week 2: API Integration

**Goal**: Create authenticated API client and TanStack Query integration.

### Day 6: API Client Foundation

#### Task 2.1: Create API Client

Create `flovyn-app/apps/web/lib/api/client.ts`:
```typescript
import type { TokenResponse } from '../auth/types'
import { getAuthClient } from '../auth/client'

const API_URL = process.env.NEXT_PUBLIC_API_URL!

export interface RequestOptions {
  tenantSlug?: string
  skipAuth?: boolean
  headers?: Record<string, string>
}

export class APIClient {
  private isRefreshing = false
  private refreshPromise: Promise<TokenResponse> | null = null

  /**
   * Get access token, refreshing if needed.
   */
  private async getAccessToken(): Promise<string | null> {
    const accessToken = sessionStorage.getItem('access_token')
    if (!accessToken) return null

    const client = getAuthClient()

    // Check if expired
    if (client.isTokenExpired(accessToken)) {
      // Refresh token
      const refreshToken = sessionStorage.getItem('refresh_token')
      if (!refreshToken) return null

      // Prevent multiple simultaneous refreshes
      if (!this.isRefreshing) {
        this.isRefreshing = true
        this.refreshPromise = client.refreshAccessToken(refreshToken)
      }

      try {
        const tokens = await this.refreshPromise!
        sessionStorage.setItem('access_token', tokens.access_token)
        if (tokens.refresh_token) {
          sessionStorage.setItem('refresh_token', tokens.refresh_token)
        }
        this.isRefreshing = false
        this.refreshPromise = null
        return tokens.access_token
      } catch (error) {
        this.isRefreshing = false
        this.refreshPromise = null
        throw error
      }
    }

    return accessToken
  }

  /**
   * Build full URL with tenant scoping if needed.
   */
  private buildUrl(path: string, tenantSlug?: string): string {
    // Remove leading slash
    const cleanPath = path.startsWith('/') ? path.slice(1) : path

    if (tenantSlug) {
      // Tenant-scoped URL
      return `${API_URL}/api/tenants/${tenantSlug}/${cleanPath}`
    }

    // Global URL
    return `${API_URL}/${cleanPath}`
  }

  /**
   * Make HTTP request with automatic auth and retry.
   */
  private async request<T>(
    method: string,
    path: string,
    options: RequestOptions & { body?: unknown } = {}
  ): Promise<T> {
    const { tenantSlug, skipAuth, headers = {}, body } = options

    // Build URL
    const url = this.buildUrl(path, tenantSlug)

    // Prepare headers
    const requestHeaders: HeadersInit = {
      'Content-Type': 'application/json',
      ...headers,
    }

    // Add auth header
    if (!skipAuth) {
      const token = await this.getAccessToken()
      if (token) {
        requestHeaders['Authorization'] = `Bearer ${token}`
      }
    }

    // Make request
    let response = await fetch(url, {
      method,
      headers: requestHeaders,
      body: body ? JSON.stringify(body) : undefined,
    })

    // Handle 401 - try refreshing token once
    if (response.status === 401 && !skipAuth) {
      const refreshToken = sessionStorage.getItem('refresh_token')
      if (refreshToken) {
        try {
          const client = getAuthClient()
          const tokens = await client.refreshAccessToken(refreshToken)
          sessionStorage.setItem('access_token', tokens.access_token)
          if (tokens.refresh_token) {
            sessionStorage.setItem('refresh_token', tokens.refresh_token)
          }

          // Retry request with new token
          requestHeaders['Authorization'] = `Bearer ${tokens.access_token}`
          response = await fetch(url, {
            method,
            headers: requestHeaders,
            body: body ? JSON.stringify(body) : undefined,
          })
        } catch (refreshError) {
          // Refresh failed - redirect to login
          sessionStorage.clear()
          window.location.href = '/auth/login'
          throw new Error('Session expired')
        }
      }
    }

    // Handle non-2xx responses
    if (!response.ok) {
      const error = await response.json().catch(() => ({
        message: `Request failed with status ${response.status}`,
      }))
      throw new Error(error.message || error.error_description || 'Request failed')
    }

    // Return JSON response
    return response.json()
  }

  /**
   * GET request.
   */
  async get<T>(path: string, options?: RequestOptions): Promise<T> {
    return this.request<T>('GET', path, options)
  }

  /**
   * POST request.
   */
  async post<T>(
    path: string,
    data: unknown,
    options?: RequestOptions
  ): Promise<T> {
    return this.request<T>('POST', path, { ...options, body: data })
  }

  /**
   * PUT request.
   */
  async put<T>(
    path: string,
    data: unknown,
    options?: RequestOptions
  ): Promise<T> {
    return this.request<T>('PUT', path, { ...options, body: data })
  }

  /**
   * DELETE request.
   */
  async delete<T>(path: string, options?: RequestOptions): Promise<T> {
    return this.request<T>('DELETE', path, options)
  }
}

// Singleton instance
let apiClientInstance: APIClient | null = null

export function getApiClient(): APIClient {
  if (!apiClientInstance) {
    apiClientInstance = new APIClient()
  }
  return apiClientInstance
}
```

**Verification:**
- [ ] No TypeScript errors
- [ ] Singleton pattern works

---

### Day 7-8: TanStack Query Setup

#### Task 2.2: Create Query Client Provider

Create `flovyn-app/apps/web/lib/api/query-client.tsx`:
```typescript
'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { useState } from 'react'

export function ReactQueryProvider({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000, // 1 minute
            retry: (failureCount, error) => {
              // Don't retry on auth errors
              if (error instanceof Error && error.message.includes('Session expired')) {
                return false
              }
              return failureCount < 3
            },
          },
        },
      })
  )

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  )
}
```

#### Task 2.3: Update Root Layout

Update `flovyn-app/apps/web/app/layout.tsx`:
```typescript
import { ReactQueryProvider } from '@/lib/api/query-client'
import { Providers } from '@/components/providers'
import '@workspace/ui/globals.css'

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body>
        <ReactQueryProvider>
          <Providers>{children}</Providers>
        </ReactQueryProvider>
      </body>
    </html>
  )
}
```

#### Task 2.4: Create Auth Initializer

Create `flovyn-app/apps/web/components/auth/auth-initializer.tsx`:
```typescript
'use client'

import { useEffect } from 'react'
import { useAuthStore } from '@/lib/auth/store'

/**
 * Initialize auth state on app load.
 * Add this to root layout.
 */
export function AuthInitializer() {
  const checkAuth = useAuthStore((state) => state.checkAuth)

  useEffect(() => {
    checkAuth()
  }, [checkAuth])

  return null
}
```

Update layout to include initializer:
```typescript
import { AuthInitializer } from '@/components/auth/auth-initializer'

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <ReactQueryProvider>
          <Providers>
            <AuthInitializer />
            {children}
          </Providers>
        </ReactQueryProvider>
      </body>
    </html>
  )
}
```

---

### Day 9: API Query Hooks

#### Task 2.5: Create Type Definitions

Create `flovyn-app/apps/web/lib/api/types.ts`:
```typescript
// Tenant types
export interface Tenant {
  id: string
  name: string
  slug: string
  settings?: {
    timezone?: string
  }
  quota?: {
    maxWorkflowRuns?: number
    maxConcurrentWorkflows?: number
  }
  createdAt: string
}

export interface TenantCreateRequest {
  name: string
  slug?: string
  settings?: {
    timezone?: string
  }
  quota?: {
    maxWorkflowRuns?: number
    maxConcurrentWorkflows?: number
  }
}

// Space types
export interface Space {
  id: string
  tenantId: string
  name: string
  description?: string
  settings?: {
    defaultVisibility?: 'PUBLIC' | 'PRIVATE'
  }
  memberCount?: number
  createdAt: string
}

export interface SpaceCreateRequest {
  name: string
  description?: string
  settings?: {
    defaultVisibility?: 'PUBLIC' | 'PRIVATE'
  }
}

// Member types
export type TenantRole = 'OWNER' | 'ADMIN' | 'MEMBER'
export type SpaceRole = 'ADMIN' | 'DEVELOPER' | 'EDITOR' | 'VIEWER' | 'AUDITOR'

export interface Member {
  userId: string
  email: string
  name?: string
  tenantRole: TenantRole
  spaceRoles?: Array<{
    spaceId: string
    role: SpaceRole
  }>
  joinedAt: string
  status?: 'ACTIVE' | 'INVITED' | 'SUSPENDED'
}

export interface MemberInviteRequest {
  email: string
  role: TenantRole
  spaces?: Array<{
    spaceId: string
    role: SpaceRole
  }>
}

// Worker types
export interface Worker {
  clientId: string
  displayName: string
  description?: string
  createdAt: string
  lastUsedAt?: string
}

export interface WorkerCreateRequest {
  displayName: string
  description?: string
}

export interface WorkerCreateResponse extends Worker {
  clientSecret: string // Only returned once!
  tokenEndpoint: string
}

// Workflow types (extend existing)
export interface Workflow {
  id: string
  name: string
  description?: string
  status: 'DRAFT' | 'PUBLISHED' | 'ARCHIVED'
  createdAt: string
  updatedAt: string
}

export interface WorkflowCreateRequest {
  name: string
  description?: string
  definition: unknown
}
```

#### Task 2.6: Create Query Hooks

Create `flovyn-app/apps/web/lib/api/queries.ts`:
```typescript
import { useQuery, useMutation, useQueryClient, type UseMutationOptions } from '@tanstack/react-query'
import { getApiClient } from './client'
import type {
  Tenant,
  TenantCreateRequest,
  Space,
  SpaceCreateRequest,
  Member,
  MemberInviteRequest,
  Worker,
  WorkerCreateRequest,
  WorkerCreateResponse,
  Workflow,
  WorkflowCreateRequest,
} from './types'

// ============================================================================
// Tenants
// ============================================================================

export function useTenants() {
  return useQuery({
    queryKey: ['tenants'],
    queryFn: async () => {
      const response = await getApiClient().get<{ tenants: Tenant[] }>('/api/v1/tenants')
      return response.tenants
    },
  })
}

export function useCreateTenant() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (data: TenantCreateRequest) =>
      getApiClient().post<Tenant>('/api/v1/tenants', data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tenants'] })
    },
  })
}

// ============================================================================
// Workflows
// ============================================================================

export function useWorkflows(tenantSlug: string) {
  return useQuery({
    queryKey: ['workflows', tenantSlug],
    queryFn: async () => {
      const response = await getApiClient().get<{ workflows: Workflow[] }>(
        '/workflows',
        { tenantSlug }
      )
      return response.workflows
    },
    enabled: !!tenantSlug,
  })
}

export function useWorkflow(workflowId: string, tenantSlug: string) {
  return useQuery({
    queryKey: ['workflows', tenantSlug, workflowId],
    queryFn: () =>
      getApiClient().get<Workflow>(`/workflows/${workflowId}`, { tenantSlug }),
    enabled: !!workflowId && !!tenantSlug,
  })
}

export function useCreateWorkflow(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (data: WorkflowCreateRequest) =>
      getApiClient().post<Workflow>('/workflows', data, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['workflows', tenantSlug] })
    },
  })
}

// ============================================================================
// Spaces
// ============================================================================

export function useSpaces(tenantSlug: string) {
  return useQuery({
    queryKey: ['spaces', tenantSlug],
    queryFn: async () => {
      const response = await getApiClient().get<{ spaces: Space[] }>(
        '/spaces',
        { tenantSlug }
      )
      return response.spaces
    },
    enabled: !!tenantSlug,
  })
}

export function useCreateSpace(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (data: SpaceCreateRequest) =>
      getApiClient().post<Space>('/spaces', data, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['spaces', tenantSlug] })
    },
  })
}

export function useUpdateSpace(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ spaceId, data }: { spaceId: string; data: Partial<SpaceCreateRequest> }) =>
      getApiClient().put<Space>(`/spaces/${spaceId}`, data, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['spaces', tenantSlug] })
    },
  })
}

export function useDeleteSpace(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (spaceId: string) =>
      getApiClient().delete(`/spaces/${spaceId}`, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['spaces', tenantSlug] })
    },
  })
}

// ============================================================================
// Members
// ============================================================================

export function useMembers(tenantSlug: string) {
  return useQuery({
    queryKey: ['members', tenantSlug],
    queryFn: async () => {
      const response = await getApiClient().get<{ members: Member[] }>(
        '/members',
        { tenantSlug }
      )
      return response.members
    },
    enabled: !!tenantSlug,
  })
}

export function useInviteMember(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (data: MemberInviteRequest) =>
      getApiClient().post<Member>('/members', data, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['members', tenantSlug] })
    },
  })
}

export function useUpdateMemberRole(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ userId, role }: { userId: string; role: string }) =>
      getApiClient().put(`/members/${userId}`, { tenantRole: role }, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['members', tenantSlug] })
    },
  })
}

export function useRemoveMember(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (userId: string) =>
      getApiClient().delete(`/members/${userId}`, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['members', tenantSlug] })
    },
  })
}

// ============================================================================
// Workers
// ============================================================================

export function useWorkers(tenantSlug: string) {
  return useQuery({
    queryKey: ['workers', tenantSlug],
    queryFn: async () => {
      const response = await getApiClient().get<{ workers: Worker[] }>(
        '/workers',
        { tenantSlug }
      )
      return response.workers
    },
    enabled: !!tenantSlug,
  })
}

export function useCreateWorker(
  tenantSlug: string,
  options?: UseMutationOptions<WorkerCreateResponse, Error, WorkerCreateRequest>
) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (data: WorkerCreateRequest) =>
      getApiClient().post<WorkerCreateResponse>('/workers', data, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['workers', tenantSlug] })
    },
    ...options,
  })
}

export function useRevokeWorker(tenantSlug: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (clientId: string) =>
      getApiClient().delete(`/workers/${clientId}`, { tenantSlug }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['workers', tenantSlug] })
    },
  })
}
```

**Verification:**
- [ ] All hooks compile without errors
- [ ] Query keys are consistent
- [ ] Mutations invalidate correct queries

---

## Week 3: Authentication UI

**Goal**: Build login, callback, and protected route components.

### Day 10-11: Login Page

#### Task 3.1: Create Login Page

Create `flovyn-app/apps/web/app/auth/login/page.tsx`:
```typescript
'use client'

import { useEffect } from 'react'
import { useSearchParams } from 'next/navigation'
import { Button } from '@workspace/ui/components/button'
import { Card } from '@workspace/ui/components/card'
import { useAuth } from '@/lib/auth/hooks'

export default function LoginPage() {
  const { login, error, isLoading } = useAuth()
  const searchParams = useSearchParams()
  const returnUrl = searchParams.get('returnUrl') || undefined

  const handleEmailLogin = async () => {
    await login(returnUrl)
  }

  const handleGoogleLogin = () => {
    // Save return URL before redirect
    if (returnUrl) {
      sessionStorage.setItem('oauth_return_url', returnUrl)
    }
    window.location.href = `${process.env.NEXT_PUBLIC_API_URL}/auth/google`
  }

  const handleGitHubLogin = () => {
    // Save return URL before redirect
    if (returnUrl) {
      sessionStorage.setItem('oauth_return_url', returnUrl)
    }
    window.location.href = `${process.env.NEXT_PUBLIC_API_URL}/auth/github`
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-50 px-4">
      <Card className="w-full max-w-md p-8">
        <div className="space-y-6">
          {/* Header */}
          <div className="text-center">
            <h1 className="text-3xl font-bold">Welcome to Flovyn</h1>
            <p className="mt-2 text-gray-600">Sign in to continue</p>
          </div>

          {/* SSO Buttons */}
          <div className="space-y-3">
            <Button
              onClick={handleGoogleLogin}
              disabled={isLoading}
              variant="outline"
              className="w-full"
            >
              <svg className="mr-2 h-5 w-5" viewBox="0 0 24 24">
                <path
                  fill="currentColor"
                  d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                />
                <path
                  fill="currentColor"
                  d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                />
                <path
                  fill="currentColor"
                  d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                />
                <path
                  fill="currentColor"
                  d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                />
              </svg>
              Continue with Google
            </Button>

            <Button
              onClick={handleGitHubLogin}
              disabled={isLoading}
              variant="outline"
              className="w-full"
            >
              <svg className="mr-2 h-5 w-5" fill="currentColor" viewBox="0 0 24 24">
                <path
                  fillRule="evenodd"
                  d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"
                  clipRule="evenodd"
                />
              </svg>
              Continue with GitHub
            </Button>
          </div>

          {/* Divider */}
          <div className="relative">
            <div className="absolute inset-0 flex items-center">
              <div className="w-full border-t border-gray-300" />
            </div>
            <div className="relative flex justify-center text-sm">
              <span className="bg-white px-2 text-gray-500">Or</span>
            </div>
          </div>

          {/* Email/Password */}
          <Button
            onClick={handleEmailLogin}
            disabled={isLoading}
            className="w-full"
          >
            {isLoading ? 'Signing in...' : 'Sign in with Email'}
          </Button>

          {/* Error Display */}
          {error && (
            <div className="rounded-lg bg-red-50 p-4 text-sm text-red-700">
              {error}
            </div>
          )}
        </div>
      </Card>
    </div>
  )
}
```

**Verification:**
- [ ] Page renders without errors
- [ ] Buttons are styled correctly
- [ ] Icons display properly

---

### Day 12: OAuth Callback Handler

#### Task 3.2: Create Callback Page

Create `flovyn-app/apps/web/app/auth/callback/page.tsx`:
```typescript
'use client'

import { useEffect } from 'react'
import { useAuthStore } from '@/lib/auth/store'

export default function AuthCallbackPage() {
  const handleCallback = useAuthStore((state) => state.handleCallback)
  const error = useAuthStore((state) => state.error)

  useEffect(() => {
    handleCallback()
  }, [handleCallback])

  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="max-w-md rounded-lg bg-red-50 p-6 text-center">
          <h2 className="text-xl font-semibold text-red-800">Authentication Error</h2>
          <p className="mt-2 text-red-600">{error}</p>
          <a
            href="/auth/login"
            className="mt-4 inline-block rounded bg-red-600 px-4 py-2 text-white hover:bg-red-700"
          >
            Try Again
          </a>
        </div>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-center">
        <div className="mb-4 h-12 w-12 animate-spin rounded-full border-4 border-blue-600 border-t-transparent" />
        <h2 className="text-xl font-semibold">Signing you in...</h2>
        <p className="mt-2 text-gray-600">Please wait</p>
      </div>
    </div>
  )
}
```

---

### Day 13: Protected Routes

#### Task 3.3: Create Protected Route Component

Create `flovyn-app/apps/web/components/auth/protected-route.tsx`:
```typescript
'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAuth } from '@/lib/auth/hooks'
import type { TenantRole } from '@/lib/api/types'

interface ProtectedRouteProps {
  children: React.ReactNode
  requiredRole?: TenantRole
}

export function ProtectedRoute({ children, requiredRole }: ProtectedRouteProps) {
  const { isAuthenticated, isLoading, user } = useAuth()
  const router = useRouter()

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      const returnUrl = window.location.pathname + window.location.search
      router.push(`/auth/login?returnUrl=${encodeURIComponent(returnUrl)}`)
    }
  }, [isAuthenticated, isLoading, router])

  // Loading state
  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="h-12 w-12 animate-spin rounded-full border-4 border-blue-600 border-t-transparent" />
      </div>
    )
  }

  // Not authenticated
  if (!isAuthenticated) {
    return null
  }

  // Check role if required
  if (requiredRole && user?.tenantRole !== requiredRole) {
    // Only OWNER can access OWNER-required routes
    if (requiredRole === 'OWNER') {
      return (
        <div className="flex min-h-screen items-center justify-center">
          <div className="max-w-md rounded-lg bg-yellow-50 p-6 text-center">
            <h2 className="text-xl font-semibold text-yellow-800">Access Denied</h2>
            <p className="mt-2 text-yellow-600">
              You need owner permissions to access this page.
            </p>
          </div>
        </div>
      )
    }

    // ADMIN can access ADMIN and MEMBER routes
    if (requiredRole === 'ADMIN' && user?.tenantRole === 'MEMBER') {
      return (
        <div className="flex min-h-screen items-center justify-center">
          <div className="max-w-md rounded-lg bg-yellow-50 p-6 text-center">
            <h2 className="text-xl font-semibold text-yellow-800">Access Denied</h2>
            <p className="mt-2 text-yellow-600">
              You need admin permissions to access this page.
            </p>
          </div>
        </div>
      )
    }
  }

  return <>{children}</>
}
```

#### Task 3.4: Add Logout Button to Navigation

Update `flovyn-app/apps/web/components/Navigation.tsx`:
```typescript
'use client'

import Link from 'next/link'
import { useAuth, useUser } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'

export function Navigation() {
  const { isAuthenticated, logout } = useAuth()
  const user = useUser()

  return (
    <nav className="border-b bg-white">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="flex h-16 justify-between">
          <div className="flex">
            <div className="flex flex-shrink-0 items-center">
              <Link href="/" className="text-xl font-bold">
                Flovyn
              </Link>
            </div>
            {isAuthenticated && (
              <div className="ml-6 flex space-x-8">
                <Link
                  href="/workflows"
                  className="inline-flex items-center border-b-2 border-transparent px-1 pt-1 text-sm font-medium text-gray-900 hover:border-gray-300"
                >
                  Workflows
                </Link>
                <Link
                  href="/runs"
                  className="inline-flex items-center border-b-2 border-transparent px-1 pt-1 text-sm font-medium text-gray-500 hover:border-gray-300 hover:text-gray-700"
                >
                  Runs
                </Link>
              </div>
            )}
          </div>
          <div className="flex items-center">
            {isAuthenticated ? (
              <div className="flex items-center space-x-4">
                <span className="text-sm text-gray-700">{user?.name || user?.email}</span>
                <Button onClick={logout} variant="outline" size="sm">
                  Logout
                </Button>
              </div>
            ) : (
              <Link href="/auth/login">
                <Button>Sign In</Button>
              </Link>
            )}
          </div>
        </div>
      </div>
    </nav>
  )
}
```

**Verification:**
- [ ] Navigation shows user info when authenticated
- [ ] Logout button works
- [ ] Login button appears when not authenticated

---

## Week 4: Multi-Tenant Features

**Goal**: Implement tenant-scoped routing and tenant switcher.

### Day 14-15: Tenant Routing

#### Task 4.1: Create Tenant Layout

Create `flovyn-app/apps/web/app/tenants/[slug]/layout.tsx`:
```typescript
import { ProtectedRoute } from '@/components/auth/protected-route'
import { TenantSwitcher } from '@/components/tenants/tenant-switcher'

export default function TenantLayout({
  children,
  params,
}: {
  children: React.ReactNode
  params: { slug: string }
}) {
  return (
    <ProtectedRoute>
      <div className="min-h-screen bg-gray-50">
        <nav className="border-b bg-white">
          <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
            <div className="flex h-16 items-center justify-between">
              <TenantSwitcher currentSlug={params.slug} />
              {/* Add more navigation items */}
            </div>
          </div>
        </nav>
        <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
          {children}
        </main>
      </div>
    </ProtectedRoute>
  )
}
```

#### Task 4.2: Create Tenant Switcher

Create `flovyn-app/apps/web/components/tenants/tenant-switcher.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTenants } from '@/lib/api/queries'
import { Button } from '@workspace/ui/components/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@workspace/ui/components/dropdown-menu'
import { ChevronDown, Plus } from 'lucide-react'

interface TenantSwitcherProps {
  currentSlug: string
}

export function TenantSwitcher({ currentSlug }: TenantSwitcherProps) {
  const router = useRouter()
  const { data: tenants, isLoading } = useTenants()

  const currentTenant = tenants?.find((t) => t.slug === currentSlug)

  const handleSwitch = (slug: string) => {
    router.push(`/tenants/${slug}/workflows`)
  }

  const handleCreateTenant = () => {
    router.push('/tenants/new')
  }

  if (isLoading) {
    return <div className="h-10 w-48 animate-pulse rounded bg-gray-200" />
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" className="w-48 justify-between">
          <span className="truncate">{currentTenant?.name || 'Select Tenant'}</span>
          <ChevronDown className="ml-2 h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-48">
        {tenants?.map((tenant) => (
          <DropdownMenuItem
            key={tenant.id}
            onClick={() => handleSwitch(tenant.slug)}
            className={currentSlug === tenant.slug ? 'bg-gray-100' : ''}
          >
            {currentSlug === tenant.slug && <span className="mr-2">✓</span>}
            {tenant.name}
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={handleCreateTenant}>
          <Plus className="mr-2 h-4 w-4" />
          Create New Tenant
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
```

**Note**: You may need to install shadcn/ui dropdown menu component:
```bash
pnpm dlx shadcn@latest add dropdown-menu -c apps/web
```

#### Task 4.3: Migrate Existing Routes

Move existing routes to tenant-scoped structure:

```bash
# Create new tenant-scoped routes
mkdir -p apps/web/app/tenants/[slug]/workflows
mkdir -p apps/web/app/tenants/[slug]/runs

# Move workflows page
mv apps/web/app/workflows/page.tsx apps/web/app/tenants/[slug]/workflows/page.tsx

# Move runs page
mv apps/web/app/runs/page.tsx apps/web/app/tenants/[slug]/runs/page.tsx
```

Update the pages to use `params.slug` for API calls.

---

### Day 16-17: Tenant Management UI

#### Task 4.4: Create Tenant Creation Form

Create `flovyn-app/apps/web/app/tenants/new/page.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useCreateTenant } from '@/lib/api/queries'
import { Button } from '@workspace/ui/components/button'
import { Input } from '@workspace/ui/components/input'
import { Label } from '@workspace/ui/components/label'
import { Card } from '@workspace/ui/components/card'
import { ProtectedRoute } from '@/components/auth/protected-route'

export default function CreateTenantPage() {
  const router = useRouter()
  const [name, setName] = useState('')
  const [slug, setSlug] = useState('')
  const createTenant = useCreateTenant()

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    try {
      const tenant = await createTenant.mutateAsync({
        name,
        slug: slug || undefined,
      })

      router.push(`/tenants/${tenant.slug}/workflows`)
    } catch (error) {
      console.error('Failed to create tenant:', error)
    }
  }

  const handleNameChange = (value: string) => {
    setName(value)
    // Auto-generate slug if not manually edited
    if (!slug) {
      const autoSlug = value
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
      setSlug(autoSlug)
    }
  }

  return (
    <ProtectedRoute>
      <div className="flex min-h-screen items-center justify-center bg-gray-50 px-4">
        <Card className="w-full max-w-md p-8">
          <h1 className="text-2xl font-bold">Create New Tenant</h1>
          <p className="mt-2 text-gray-600">
            Set up a new workspace for your team.
          </p>

          <form onSubmit={handleSubmit} className="mt-6 space-y-4">
            <div>
              <Label htmlFor="name">Tenant Name</Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => handleNameChange(e.target.value)}
                placeholder="Acme Corporation"
                required
              />
            </div>

            <div>
              <Label htmlFor="slug">Slug (URL-friendly identifier)</Label>
              <Input
                id="slug"
                value={slug}
                onChange={(e) => setSlug(e.target.value)}
                placeholder="acme-corp"
                pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
                required
              />
              <p className="mt-1 text-sm text-gray-500">
                Only lowercase letters, numbers, and hyphens
              </p>
            </div>

            {createTenant.error && (
              <div className="rounded bg-red-50 p-3 text-sm text-red-700">
                {createTenant.error.message}
              </div>
            )}

            <div className="flex space-x-3">
              <Button
                type="button"
                variant="outline"
                onClick={() => router.back()}
                className="flex-1"
              >
                Cancel
              </Button>
              <Button
                type="submit"
                disabled={createTenant.isPending}
                className="flex-1"
              >
                {createTenant.isPending ? 'Creating...' : 'Create Tenant'}
              </Button>
            </div>
          </form>
        </Card>
      </div>
    </ProtectedRoute>
  )
}
```

---

## Week 5: IAM Features & Polish

**Goal**: Implement space/member/worker management and polish the UI.

### Day 18-19: Space Management

#### Task 5.1: Create Space List

Create `flovyn-app/apps/web/app/tenants/[slug]/spaces/page.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useSpaces, useCreateSpace, useDeleteSpace } from '@/lib/api/queries'
import { useIsAdmin } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'
import { Card } from '@workspace/ui/components/card'
import { Plus, Trash2 } from 'lucide-react'
import { SpaceForm } from '@/components/spaces/space-form'

export default function SpacesPage({ params }: { params: { slug: string } }) {
  const { data: spaces, isLoading } = useSpaces(params.slug)
  const isAdmin = useIsAdmin()
  const [showForm, setShowForm] = useState(false)
  const deleteSpace = useDeleteSpace(params.slug)

  const handleDelete = async (spaceId: string) => {
    if (!confirm('Are you sure you want to delete this space?')) return
    await deleteSpace.mutateAsync(spaceId)
  }

  if (isLoading) {
    return <div>Loading spaces...</div>
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold">Spaces</h1>
        {isAdmin && (
          <Button onClick={() => setShowForm(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Create Space
          </Button>
        )}
      </div>

      {showForm && (
        <SpaceForm
          tenantSlug={params.slug}
          onClose={() => setShowForm(false)}
        />
      )}

      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {spaces?.map((space) => (
          <Card key={space.id} className="p-6">
            <div className="flex items-start justify-between">
              <div>
                <h3 className="font-semibold">{space.name}</h3>
                <p className="mt-1 text-sm text-gray-600">{space.description}</p>
                <p className="mt-2 text-xs text-gray-500">
                  {space.memberCount || 0} members
                </p>
              </div>
              {isAdmin && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => handleDelete(space.id)}
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              )}
            </div>
          </Card>
        ))}
      </div>

      {!spaces?.length && (
        <div className="text-center text-gray-500">
          No spaces yet. {isAdmin && 'Create one to get started.'}
        </div>
      )}
    </div>
  )
}
```

#### Task 5.2: Create Space Form Component

Create `flovyn-app/apps/web/components/spaces/space-form.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useCreateSpace } from '@/lib/api/queries'
import { Button } from '@workspace/ui/components/button'
import { Input } from '@workspace/ui/components/input'
import { Label } from '@workspace/ui/components/label'
import { Textarea } from '@workspace/ui/components/textarea'
import { Card } from '@workspace/ui/components/card'

interface SpaceFormProps {
  tenantSlug: string
  onClose: () => void
}

export function SpaceForm({ tenantSlug, onClose }: SpaceFormProps) {
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const createSpace = useCreateSpace(tenantSlug)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    try {
      await createSpace.mutateAsync({ name, description })
      onClose()
    } catch (error) {
      console.error('Failed to create space:', error)
    }
  }

  return (
    <Card className="p-6">
      <h2 className="text-xl font-bold">Create New Space</h2>
      <form onSubmit={handleSubmit} className="mt-4 space-y-4">
        <div>
          <Label htmlFor="name">Name</Label>
          <Input
            id="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
          />
        </div>
        <div>
          <Label htmlFor="description">Description</Label>
          <Textarea
            id="description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={3}
          />
        </div>
        <div className="flex space-x-3">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={createSpace.isPending}>
            {createSpace.isPending ? 'Creating...' : 'Create'}
          </Button>
        </div>
      </form>
    </Card>
  )
}
```

---

### Day 20: Member Management

#### Task 5.3: Create Members Page

Create `flovyn-app/apps/web/app/tenants/[slug]/members/page.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useMembers, useInviteMember, useRemoveMember } from '@/lib/api/queries'
import { useIsAdmin } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'
import { UserPlus, Trash2 } from 'lucide-react'
import { MemberInviteForm } from '@/components/members/invite-form'

export default function MembersPage({ params }: { params: { slug: string } }) {
  const { data: members, isLoading } = useMembers(params.slug)
  const isAdmin = useIsAdmin()
  const [showInviteForm, setShowInviteForm] = useState(false)
  const removeMember = useRemoveMember(params.slug)

  const handleRemove = async (userId: string) => {
    if (!confirm('Are you sure you want to remove this member?')) return
    await removeMember.mutateAsync(userId)
  }

  if (isLoading) {
    return <div>Loading members...</div>
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold">Members</h1>
        {isAdmin && (
          <Button onClick={() => setShowInviteForm(true)}>
            <UserPlus className="mr-2 h-4 w-4" />
            Invite Member
          </Button>
        )}
      </div>

      {showInviteForm && (
        <MemberInviteForm
          tenantSlug={params.slug}
          onClose={() => setShowInviteForm(false)}
        />
      )}

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Member
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Role
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Status
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Joined
              </th>
              {isAdmin && <th className="relative px-6 py-3" />}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-200 bg-white">
            {members?.map((member) => (
              <tr key={member.userId}>
                <td className="whitespace-nowrap px-6 py-4">
                  <div>
                    <div className="font-medium text-gray-900">{member.name}</div>
                    <div className="text-sm text-gray-500">{member.email}</div>
                  </div>
                </td>
                <td className="whitespace-nowrap px-6 py-4 text-sm text-gray-900">
                  <span className="inline-flex rounded-full bg-blue-100 px-2 text-xs font-semibold leading-5 text-blue-800">
                    {member.tenantRole}
                  </span>
                </td>
                <td className="whitespace-nowrap px-6 py-4 text-sm text-gray-500">
                  {member.status || 'ACTIVE'}
                </td>
                <td className="whitespace-nowrap px-6 py-4 text-sm text-gray-500">
                  {new Date(member.joinedAt).toLocaleDateString()}
                </td>
                {isAdmin && (
                  <td className="whitespace-nowrap px-6 py-4 text-right text-sm font-medium">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleRemove(member.userId)}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

#### Task 5.4: Create Member Invite Form

Create `flovyn-app/apps/web/components/members/invite-form.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useInviteMember } from '@/lib/api/queries'
import { Button } from '@workspace/ui/components/button'
import { Input } from '@workspace/ui/components/input'
import { Label } from '@workspace/ui/components/label'
import { Select } from '@workspace/ui/components/select'
import { Card } from '@workspace/ui/components/card'
import type { TenantRole } from '@/lib/api/types'

interface MemberInviteFormProps {
  tenantSlug: string
  onClose: () => void
}

export function MemberInviteForm({ tenantSlug, onClose }: MemberInviteFormProps) {
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<TenantRole>('MEMBER')
  const inviteMember = useInviteMember(tenantSlug)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    try {
      await inviteMember.mutateAsync({ email, role })
      onClose()
    } catch (error) {
      console.error('Failed to invite member:', error)
    }
  }

  return (
    <Card className="p-6">
      <h2 className="text-xl font-bold">Invite Member</h2>
      <form onSubmit={handleSubmit} className="mt-4 space-y-4">
        <div>
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="user@example.com"
            required
          />
        </div>
        <div>
          <Label htmlFor="role">Role</Label>
          <select
            id="role"
            value={role}
            onChange={(e) => setRole(e.target.value as TenantRole)}
            className="w-full rounded border p-2"
          >
            <option value="MEMBER">Member</option>
            <option value="ADMIN">Admin</option>
            <option value="OWNER">Owner</option>
          </select>
        </div>
        {inviteMember.error && (
          <div className="rounded bg-red-50 p-3 text-sm text-red-700">
            {inviteMember.error.message}
          </div>
        )}
        <div className="flex space-x-3">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={inviteMember.isPending}>
            {inviteMember.isPending ? 'Sending...' : 'Send Invitation'}
          </Button>
        </div>
      </form>
    </Card>
  )
}
```

---

### Day 21: Worker Management

#### Task 5.5: Create Workers Page with Secret Modal

Create `flovyn-app/apps/web/app/tenants/[slug]/workers/page.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useWorkers, useCreateWorker, useRevokeWorker } from '@/lib/api/queries'
import { useIsAdmin } from '@/lib/auth/hooks'
import { Button } from '@workspace/ui/components/button'
import { Plus, Trash2 } from 'lucide-react'
import { WorkerForm } from '@/components/workers/worker-form'
import { SecretModal } from '@/components/workers/secret-modal'
import type { WorkerCreateResponse } from '@/lib/api/types'

export default function WorkersPage({ params }: { params: { slug: string } }) {
  const { data: workers, isLoading } = useWorkers(params.slug)
  const isAdmin = useIsAdmin()
  const [showForm, setShowForm] = useState(false)
  const [newWorker, setNewWorker] = useState<WorkerCreateResponse | null>(null)
  const revokeWorker = useRevokeWorker(params.slug)

  const handleWorkerCreated = (worker: WorkerCreateResponse) => {
    setShowForm(false)
    setNewWorker(worker)
  }

  const handleRevoke = async (clientId: string) => {
    if (!confirm('Are you sure? This worker will no longer be able to authenticate.')) return
    await revokeWorker.mutateAsync(clientId)
  }

  if (isLoading) {
    return <div>Loading workers...</div>
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold">Worker Credentials</h1>
        {isAdmin && (
          <Button onClick={() => setShowForm(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Create Worker
          </Button>
        )}
      </div>

      {showForm && (
        <WorkerForm
          tenantSlug={params.slug}
          onSuccess={handleWorkerCreated}
          onClose={() => setShowForm(false)}
        />
      )}

      {newWorker && (
        <SecretModal
          worker={newWorker}
          onClose={() => setNewWorker(null)}
        />
      )}

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Display Name
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Client ID
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Created
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                Last Used
              </th>
              {isAdmin && <th className="relative px-6 py-3" />}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-200 bg-white">
            {workers?.map((worker) => (
              <tr key={worker.clientId}>
                <td className="whitespace-nowrap px-6 py-4">
                  <div className="font-medium text-gray-900">{worker.displayName}</div>
                  {worker.description && (
                    <div className="text-sm text-gray-500">{worker.description}</div>
                  )}
                </td>
                <td className="whitespace-nowrap px-6 py-4 font-mono text-sm text-gray-500">
                  {worker.clientId.slice(0, 8)}...
                </td>
                <td className="whitespace-nowrap px-6 py-4 text-sm text-gray-500">
                  {new Date(worker.createdAt).toLocaleDateString()}
                </td>
                <td className="whitespace-nowrap px-6 py-4 text-sm text-gray-500">
                  {worker.lastUsedAt
                    ? new Date(worker.lastUsedAt).toLocaleDateString()
                    : 'Never'}
                </td>
                {isAdmin && (
                  <td className="whitespace-nowrap px-6 py-4 text-right text-sm font-medium">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleRevoke(worker.clientId)}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

#### Task 5.6: Create Secret Modal

Create `flovyn-app/apps/web/components/workers/secret-modal.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { Button } from '@workspace/ui/components/button'
import { Card } from '@workspace/ui/components/card'
import { Check, Copy } from 'lucide-react'
import type { WorkerCreateResponse } from '@/lib/api/types'

interface SecretModalProps {
  worker: WorkerCreateResponse
  onClose: () => void
}

export function SecretModal({ worker, onClose }: SecretModalProps) {
  const [copiedClientId, setCopiedClientId] = useState(false)
  const [copiedSecret, setCopiedSecret] = useState(false)
  const [acknowledged, setAcknowledged] = useState(false)

  const copyToClipboard = async (text: string, setCopied: (v: boolean) => void) => {
    await navigator.clipboard.writeText(text)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black bg-opacity-50">
      <Card className="w-full max-w-2xl p-8">
        <div className="space-y-6">
          {/* Warning Header */}
          <div className="rounded-lg bg-yellow-50 p-4">
            <div className="flex">
              <div className="flex-shrink-0">
                <svg
                  className="h-5 w-5 text-yellow-400"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                >
                  <path
                    fillRule="evenodd"
                    d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                    clipRule="evenodd"
                  />
                </svg>
              </div>
              <div className="ml-3">
                <h3 className="text-sm font-medium text-yellow-800">
                  Save Your Client Secret
                </h3>
                <p className="mt-2 text-sm text-yellow-700">
                  This secret will only be shown once. Copy it now and store it securely.
                  You won't be able to see it again.
                </p>
              </div>
            </div>
          </div>

          {/* Credentials */}
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-700">
                Display Name
              </label>
              <div className="mt-1 text-lg font-semibold">{worker.displayName}</div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700">
                Client ID
              </label>
              <div className="mt-1 flex items-center space-x-2">
                <code className="flex-1 rounded bg-gray-100 p-3 font-mono text-sm">
                  {worker.clientId}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => copyToClipboard(worker.clientId, setCopiedClientId)}
                >
                  {copiedClientId ? (
                    <Check className="h-4 w-4" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700">
                Client Secret
              </label>
              <div className="mt-1 flex items-center space-x-2">
                <code className="flex-1 rounded bg-gray-100 p-3 font-mono text-sm">
                  {worker.clientSecret}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => copyToClipboard(worker.clientSecret, setCopiedSecret)}
                >
                  {copiedSecret ? (
                    <Check className="h-4 w-4" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700">
                Token Endpoint
              </label>
              <div className="mt-1">
                <code className="block rounded bg-gray-100 p-3 font-mono text-sm">
                  {worker.tokenEndpoint}
                </code>
              </div>
            </div>
          </div>

          {/* Acknowledgment */}
          <div className="flex items-center space-x-2">
            <input
              type="checkbox"
              id="acknowledge"
              checked={acknowledged}
              onChange={(e) => setAcknowledged(e.target.checked)}
              className="h-4 w-4 rounded border-gray-300"
            />
            <label htmlFor="acknowledge" className="text-sm text-gray-700">
              I have saved the client secret in a secure location
            </label>
          </div>

          {/* Close Button */}
          <Button
            onClick={onClose}
            disabled={!acknowledged}
            className="w-full"
          >
            Close
          </Button>
        </div>
      </Card>
    </div>
  )
}
```

#### Task 5.7: Create Worker Form

Create `flovyn-app/apps/web/components/workers/worker-form.tsx`:
```typescript
'use client'

import { useState } from 'react'
import { useCreateWorker } from '@/lib/api/queries'
import { Button } from '@workspace/ui/components/button'
import { Input } from '@workspace/ui/components/input'
import { Label } from '@workspace/ui/components/label'
import { Textarea } from '@workspace/ui/components/textarea'
import { Card } from '@workspace/ui/components/card'
import type { WorkerCreateResponse } from '@/lib/api/types'

interface WorkerFormProps {
  tenantSlug: string
  onSuccess: (worker: WorkerCreateResponse) => void
  onClose: () => void
}

export function WorkerForm({ tenantSlug, onSuccess, onClose }: WorkerFormProps) {
  const [displayName, setDisplayName] = useState('')
  const [description, setDescription] = useState('')
  const createWorker = useCreateWorker(tenantSlug, {
    onSuccess: (data) => {
      onSuccess(data)
    },
  })

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    await createWorker.mutateAsync({
      displayName,
      description: description || undefined,
    })
  }

  return (
    <Card className="p-6">
      <h2 className="text-xl font-bold">Create Worker Credentials</h2>
      <form onSubmit={handleSubmit} className="mt-4 space-y-4">
        <div>
          <Label htmlFor="displayName">Display Name</Label>
          <Input
            id="displayName"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            placeholder="Production Worker 1"
            required
          />
        </div>
        <div>
          <Label htmlFor="description">Description (optional)</Label>
          <Textarea
            id="description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Worker for production workflows"
            rows={3}
          />
        </div>
        {createWorker.error && (
          <div className="rounded bg-red-50 p-3 text-sm text-red-700">
            {createWorker.error.message}
          </div>
        )}
        <div className="flex space-x-3">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={createWorker.isPending}>
            {createWorker.isPending ? 'Creating...' : 'Create Worker'}
          </Button>
        </div>
      </form>
    </Card>
  )
}
```

---

## Testing Checklist

### Manual Testing

#### Authentication Flow
- [ ] Email/password login redirects to OAuth2 authorize
- [ ] Google SSO creates account on first login
- [ ] GitHub SSO creates account on first login
- [ ] OAuth callback exchanges code for tokens
- [ ] Tokens stored in sessionStorage
- [ ] User redirected to returnUrl after login
- [ ] Logout clears tokens and redirects to login
- [ ] Token refresh happens automatically before expiry
- [ ] Expired token triggers refresh on API call
- [ ] 401 response triggers token refresh and retry

#### Protected Routes
- [ ] Unauthenticated users redirected to login
- [ ] Return URL preserved across login flow
- [ ] Loading spinner shown during auth check
- [ ] Authenticated users can access protected routes
- [ ] Role-based access control works (OWNER/ADMIN/MEMBER)

#### Multi-Tenant
- [ ] Tenant switcher shows user's tenants
- [ ] Current tenant highlighted in dropdown
- [ ] Switching tenant navigates to new tenant URL
- [ ] Tenant slug validated (lowercase, hyphens only)
- [ ] Reserved slugs rejected
- [ ] API calls use correct tenant slug
- [ ] 403 error shown for unauthorized tenant access

#### IAM Features
- [ ] Admins can create spaces
- [ ] Admins can delete spaces
- [ ] Admins can invite members
- [ ] Email invitation sent
- [ ] Admins can change member roles
- [ ] Admins can remove members
- [ ] Cannot remove last OWNER
- [ ] Admins can create worker credentials
- [ ] Client secret shown only once
- [ ] Admins can revoke worker credentials

### Unit Tests

Run tests (if configured):
```bash
cd apps/web
pnpm test
```

Check coverage:
- [ ] PKCE utilities (code_verifier, code_challenge)
- [ ] JWT parsing
- [ ] Token expiry check
- [ ] API client request building
- [ ] Auth store actions

---

## Deployment Checklist

### Pre-Deployment

- [ ] All tests passing
- [ ] No console errors
- [ ] No TypeScript errors
- [ ] Environment variables documented
- [ ] Security audit complete (PKCE, CSRF, token storage)
- [ ] Error handling tested
- [ ] Loading states tested

### Environment Configuration

#### Production `.env.production`:
```bash
NEXT_PUBLIC_API_URL=https://api.flovyn.io
NEXT_PUBLIC_OAUTH_CLIENT_ID=flovyn-web
NEXT_PUBLIC_OAUTH_REDIRECT_URI=https://app.flovyn.io/auth/callback
```

#### Backend Configuration

Ensure backend has:
- [ ] CORS enabled for frontend domain
- [ ] OAuth2 client registered with correct redirect URI
- [ ] Google SSO configured
- [ ] GitHub SSO configured
- [ ] Rate limiting configured

### Post-Deployment Verification

- [ ] Login flow works in production
- [ ] SSO providers work
- [ ] Token refresh works
- [ ] API calls authenticated
- [ ] Tenant switching works
- [ ] All IAM features functional

---

## Next Steps (Post-MVP)

### Future Enhancements

1. **User Registration**
   - Self-service email/password registration
   - Email verification flow
   - Password reset flow

2. **User Profile**
   - Edit profile (name, avatar)
   - Change password
   - MFA setup

3. **Advanced IAM**
   - Custom roles and permissions
   - Space-level permissions UI
   - Audit logs

4. **Session Management**
   - Active sessions list
   - Revoke individual sessions
   - Session timeout configuration

5. **Performance**
   - Implement React Suspense for loading states
   - Add skeleton loaders
   - Optimize bundle size

6. **Testing**
   - Add E2E tests with Playwright
   - Add visual regression tests
   - Increase unit test coverage

---

## Support

If you encounter issues during implementation:

1. Check browser console for errors
2. Verify environment variables are set
3. Ensure backend is running and accessible
4. Check network tab for failed API requests
5. Verify tokens are being stored in sessionStorage
6. Check Zustand devtools for state changes

---

## Conclusion

This implementation plan provides a structured approach to integrating IAM into the Flovyn frontend. Follow the tasks sequentially, verify each step, and don't hesitate to iterate on the UI/UX as you build.

Good luck with the implementation!
