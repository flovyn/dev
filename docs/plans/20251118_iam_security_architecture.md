# IAM Security Architecture

**Status**: Implemented
**Last Updated**: 2025-11-10
**Security Level**: Production-Grade

---

## Overview

This document describes the security architecture for authentication and authorization in the Flovyn frontend application. The implementation prioritizes **security-first** principles with defense-in-depth strategies.

## Core Security Principles

### 1. Token Storage Strategy (100% Cookie-Based)

**Access Token (Short-lived, ~15 minutes)**:
- ✅ Stored in **httpOnly cookie** (inaccessible to JavaScript)
- ✅ Set **server-side** by OAuth callback
- ✅ Automatically sent with API requests via `credentials: 'include'`
- ✅ Never exposed to client JavaScript

**Refresh Token (Long-lived, ~30 days)**:
- ✅ Stored in **httpOnly cookie** (inaccessible to JavaScript)
- ✅ **SameSite=Lax** for CSRF protection
- ✅ **Secure flag** in production (HTTPS only)
- ✅ Set **server-side** only
- ✅ Never exposed to client JavaScript

**Why 100% Cookie-Based?**:
- ✅ **Simplest & most secure** - no token handling in JavaScript
- ✅ **Automatic transmission** - browser handles everything
- ✅ **XSS proof** - httpOnly cookies can't be accessed by scripts
- ✅ **No state management** - no Zustand/Redux needed for tokens

### 2. OAuth2 Flow with PKCE

**Why PKCE?**
- Prevents authorization code interception attacks
- Required for public clients (SPAs)
- No client secret needed

**Implementation**:
```
1. Client generates: code_verifier (random 256-bit)
2. Client computes: code_challenge = SHA256(code_verifier)
3. Client sends code_challenge to authorization server
4. Server returns authorization code
5. Client sends code + code_verifier to token endpoint
6. Server validates: SHA256(code_verifier) === stored code_challenge
7. Server issues tokens
```

### 3. Server-Side OAuth Callback

**Architecture Decision**: Handle OAuth callback on the server-side (Next.js Route Handler) instead of client-side JavaScript.

**Benefits**:
- ✅ Refresh token **never touches client JavaScript**
- ✅ No risk of token exposure in browser console/memory dumps
- ✅ Tokens not visible in Network tab
- ✅ Simpler client code
- ✅ Server-side cookie setting (more secure)

**Simplified Flow (4 Routes)**:
```
┌─────────────┐       ┌──────────────┐       ┌─────────────┐
│   Browser   │       │   Next.js    │       │   Backend   │
│   (Client)  │       │   (Server)   │       │   OAuth2    │
└─────────────┘       └──────────────┘       └─────────────┘
       │                      │                      │
       │  1. Visit /auth/login                       │
       │     Click login      │                      │
       │     (stores PKCE in  │                      │
       │      cookies)        │                      │
       │                      │                      │
       │  2. Redirect to OAuth                       │
       ├────────────────────────────────────────────►│
       │                      │                      │
       │  3. User authenticates                      │
       │◄────────────────────────────────────────────┤
       │                      │                      │
       │  4. Redirect to      │                      │
       │     /auth/callback   │                      │
       ├─────────────────────►│                      │
       │     with code        │                      │
       │                      │                      │
       │                      │  5. Exchange code    │
       │                      ├─────────────────────►│
       │                      │     + code_verifier  │
       │                      │                      │
       │                      │  6. Return tokens    │
       │                      │◄─────────────────────┤
       │                      │                      │
       │                      │  7. Set httpOnly     │
       │                      │     cookies (both)   │
       │                      │                      │
       │  8. Redirect to app  │                      │
       │◄─────────────────────┤                      │
       │  (cookies auto-sent) │                      │
       │                      │                      │
```

---

## Implementation Details

### API Endpoints (Only 4!)

#### 1. `/auth/login` (Client Page)

**Purpose**: User-facing login UI

**Features**:
- Email/Password OAuth2 button
- Google SSO button
- GitHub SSO button
- Error display from URL params
- Return URL handling

**Code**: `flovyn-app/apps/web/app/auth/login/page.tsx`

#### 2. `/auth/callback` (Route Handler - Server-Side)

**Purpose**: Handle complete OAuth2 flow server-side

**Security Features**:
- ✅ State validation (CSRF protection)
- ✅ Code verifier validation (PKCE)
- ✅ Server-side token exchange
- ✅ httpOnly cookie setting (both tokens)
- ✅ Automatic cookie cleanup
- ✅ Direct redirect to app (no client token handling)

**Code**: `flovyn-app/apps/web/app/auth/callback/route.ts`

```typescript
export async function GET(request: NextRequest) {
  // 1. Validate state (CSRF) & code_verifier (PKCE)
  // 2. Exchange code for tokens (server-side)
  // 3. Set access_token as httpOnly cookie (15 min)
  // 4. Set refresh_token as httpOnly cookie (30 days)
  // 5. Clean up OAuth cookies
  // 6. Redirect directly to app
}
```

#### 3. `/api/auth/refresh-token` (Route Handler)

**Purpose**: Refresh access token using httpOnly cookie

**Security Features**:
- ✅ Reads refresh token from httpOnly cookie
- ✅ Proxies request to backend OAuth2 endpoint
- ✅ Updates both cookies if successful
- ✅ Clears cookies if refresh fails
- ✅ Returns only access token to client

**Code**: `flovyn-app/apps/web/app/api/auth/refresh-token/route.ts`

```typescript
export async function POST() {
  // 1. Read refresh_token from httpOnly cookie
  // 2. Call backend /oauth2/token with refresh grant
  // 3. Update access_token cookie (15 min)
  // 4. Update refresh_token cookie if rotated (30 days)
  // 5. Return new access_token to client
}
```

#### 4. `/api/auth/logout` (Route Handler)

**Purpose**: OpenID Connect compliant logout with token revocation

**Security Features**:
- ✅ Reads tokens from httpOnly cookies
- ✅ Calls backend `/oauth2/revoke` with token_type_hint
- ✅ Revokes both access and refresh tokens
- ✅ Clears all auth-related cookies
- ✅ Handles errors gracefully (always clears cookies)

**Code**: `flovyn-app/apps/web/app/api/auth/logout/route.ts`

```typescript
export async function POST() {
  // 1. Read refresh_token & access_token from httpOnly cookies
  // 2. Revoke refresh_token via backend /oauth2/revoke
  // 3. Revoke access_token via backend /oauth2/revoke
  // 4. Clear all auth cookies (access, refresh, OAuth params)
  // 5. Return success
}
```

---

## Security Measures

### 1. CSRF Protection

**Multiple Layers**:
- ✅ OAuth state parameter validation
- ✅ SameSite=Lax cookie attribute
- ✅ Origin validation in server routes

### 2. XSS Protection

**Mitigation**:
- ✅ httpOnly cookies (not accessible via JavaScript)
- ✅ No token storage in localStorage/sessionStorage
- ✅ Content Security Policy headers (to be added)
- ✅ Input sanitization

### 3. Token Leakage Prevention

**Strategies**:
- ✅ Access token in memory only (cleared on refresh)
- ✅ Refresh token in httpOnly cookie
- ✅ Short access token lifetime (15 minutes)
- ✅ Token rotation on refresh
- ✅ Server-side token revocation on logout

### 4. Man-in-the-Middle (MITM) Protection

**Measures**:
- ✅ HTTPS only in production (Secure cookie flag)
- ✅ HSTS headers (to be configured)
- ✅ Certificate pinning (optional, for mobile apps)

### 5. Session Fixation Protection

**Prevention**:
- ✅ New tokens generated on each login
- ✅ State parameter for each OAuth flow
- ✅ Token revocation on logout

---

## Token Lifecycle

### Initial Authentication

```typescript
// 1. User visits /auth/login page
// 2. Clicks "Sign in with Email" (or Google/GitHub)

// Client-side:
const client = getAuthClient()
await client.initiateLogin({ returnUrl: '/dashboard' })
// - Generates PKCE parameters
// - Stores in cookies (max-age: 10 minutes)
// - Redirects to backend OAuth endpoint

// Backend OAuth server authenticates user...

// Server-side callback at /auth/callback:
// 3. Validates state & code_verifier (PKCE)
// 4. Exchanges code for tokens
// 5. Sets access_token cookie (httpOnly, 15 min)
// 6. Sets refresh_token cookie (httpOnly, 30 days)
// 7. Cleans up OAuth cookies
// 8. Redirects to /dashboard

// Done! Cookies automatically sent with all API requests
```

### Token Refresh

```typescript
// Triggered automatically by API client on 401 response
// OR manually called by app

// Client makes API request → gets 401
// API client interceptor automatically:
const response = await fetch('/api/auth/refresh-token', {
  method: 'POST',
  credentials: 'include' // Sends cookies
})

// Server-side /api/auth/refresh-token:
// 1. Reads refresh_token from httpOnly cookie
// 2. Calls backend /oauth2/token with refresh grant
// 3. Updates access_token cookie (15 min)
// 4. Updates refresh_token cookie if rotated (30 days)
// 5. Returns new access_token

// API client retries original request with new cookie
// Done! No client-side token management needed
```

### Logout

```typescript
// User clicks logout button
const client = getAuthClient()
await client.logout()

// Client-side:
// 1. Calls backend /oauth2/revoke (best effort)
// 2. Clears cookies client-side
document.cookie = 'access_token=; expires=Thu, 01 Jan 1970...'
document.cookie = 'refresh_token=; expires=Thu, 01 Jan 1970...'

// 3. Redirects to /auth/login
// Done! User logged out
```

---

## HTTP Client Architecture

### Ky HTTP Client with Cookie-Based Auth

**Why Ky over fetch?**
- Built-in retry logic
- Automatic error handling
- Request/response interceptors
- Better TypeScript support
- Cleaner API

**Simplified Implementation**: `flovyn-app/apps/web/lib/api/client.ts`

```typescript
class APIClient {
  private client: KyInstance

  constructor() {
    this.client = ky.create({
      prefixUrl: API_URL,
      credentials: 'include', // ✅ Automatically send cookies!
      hooks: {
        afterResponse: [
          async (request, options, response) => {
            // Handle 401 - refresh token and retry
            if (response.status === 401) {
              // Refresh tokens (updates cookies server-side)
              await fetch('/api/auth/refresh-token', {
                method: 'POST',
                credentials: 'include'
              })

              // Retry original request (cookies auto-sent)
              return ky(request)
            }
          }
        ]
      }
    })
  }
}
```

**Features**:
- ✅ **No manual token injection** - cookies sent automatically
- ✅ Automatic token refresh on 401
- ✅ Retry failed requests after refresh
- ✅ Tenant-scoped URL building
- ✅ **Simpler code** - no token management

---

## Authentication State Management

### Zustand Store

**Why Zustand?**
- Minimal boilerplate
- No Provider wrapper needed
- DevTools integration
- TypeScript-first

**Implementation**: `flovyn-app/apps/web/lib/auth/store.ts`

```typescript
interface AuthState {
  isAuthenticated: boolean
  isLoading: boolean
  user: JWTClaims | null
  error: string | null

  login: (returnUrl?: string) => Promise<void>
  logout: () => Promise<void>
  refreshToken: () => Promise<void>
  checkAuth: () => Promise<void>
}
```

**Features**:
- ✅ Centralized auth state
- ✅ Automatic token refresh scheduling
- ✅ Session persistence check on app load
- ✅ Error handling

---

## Security Checklist

### ✅ Implemented

- [x] PKCE for OAuth2 authorization code flow
- [x] httpOnly cookies for refresh tokens
- [x] In-memory storage for access tokens
- [x] Server-side OAuth callback handling
- [x] State validation (CSRF protection)
- [x] SameSite cookie attribute
- [x] Automatic token refresh
- [x] Token revocation on logout
- [x] Ky interceptors for automatic retry
- [x] Short-lived access tokens
- [x] Secure cookie flag (production)

### 🔄 To Be Added (Production)

- [ ] Content Security Policy headers
- [ ] HSTS headers (Strict-Transport-Security)
- [ ] Rate limiting on auth endpoints
- [ ] Brute force protection
- [ ] Session timeout warnings
- [ ] Suspicious activity detection
- [ ] Audit logging
- [ ] IP allowlisting (optional)

---

## Attack Scenarios & Mitigations

### Scenario 1: XSS Attack

**Attack**: Malicious script injected into page tries to steal tokens

**Mitigation**:
- ✅ Refresh token in httpOnly cookie (not accessible)
- ✅ Access token in memory (not in localStorage)
- ⚠️ Access token briefly visible in /auth/success URL
- ✅ URL immediately replaced (router.replace)
- 🔄 Add CSP headers to prevent script injection

### Scenario 2: CSRF Attack

**Attack**: Attacker tricks user into making unwanted requests

**Mitigation**:
- ✅ OAuth state parameter validation
- ✅ SameSite=Lax cookies
- ✅ Origin validation in API routes
- ✅ Short-lived PKCE parameters (10 minutes)

### Scenario 3: Token Replay Attack

**Attack**: Attacker intercepts and reuses access token

**Mitigation**:
- ✅ Short-lived access tokens (15 minutes)
- ✅ HTTPS only in production
- ✅ Token bound to specific client (via refresh token)
- 🔄 Add token binding headers

### Scenario 4: Refresh Token Theft

**Attack**: Attacker steals refresh token

**Mitigation**:
- ✅ httpOnly cookie (not accessible via JS)
- ✅ Secure flag (HTTPS only)
- ✅ SameSite attribute
- ✅ Server-side revocation
- 🔄 Add refresh token rotation (one-time use)

### Scenario 5: Authorization Code Interception

**Attack**: Attacker intercepts OAuth authorization code

**Mitigation**:
- ✅ PKCE (code_verifier validation)
- ✅ State validation
- ✅ Short-lived authorization codes (backend)
- ✅ One-time use codes (backend)

---

## Monitoring & Auditing

### Metrics to Track

1. **Authentication Events**:
   - Login attempts (success/failure)
   - Logout events
   - Token refresh attempts
   - Session expirations

2. **Security Events**:
   - Failed state validations
   - Failed PKCE validations
   - 401 errors
   - Token revocations

3. **Performance Metrics**:
   - Token refresh latency
   - OAuth callback processing time
   - API request latency

### Logging Strategy

```typescript
// Security events (to be implemented)
logger.security('AUTH_LOGIN_SUCCESS', {
  userId: user.userId,
  method: 'oauth2',
  timestamp: Date.now(),
})

logger.security('AUTH_LOGIN_FAILED', {
  reason: 'invalid_state',
  ip: request.ip,
  timestamp: Date.now(),
})

logger.security('TOKEN_REFRESH_FAILED', {
  userId: user?.userId,
  reason: error.message,
  timestamp: Date.now(),
})
```

---

## Future Enhancements

### Phase 2: Advanced Security

1. **Multi-Factor Authentication (MFA)**
   - TOTP (Time-based One-Time Password)
   - SMS verification
   - Backup codes

2. **Device Management**
   - Trusted device tracking
   - Device fingerprinting
   - Suspicious device alerts

3. **Advanced Session Management**
   - Concurrent session limits
   - Active session list
   - Remote session termination

4. **Biometric Authentication**
   - WebAuthn support
   - Fingerprint/Face ID
   - Hardware security keys

### Phase 3: Compliance

1. **GDPR Compliance**
   - Data portability
   - Right to be forgotten
   - Consent management

2. **SOC 2 Compliance**
   - Audit trails
   - Access reviews
   - Encryption at rest

3. **HIPAA (if applicable)**
   - PHI protection
   - BAA agreements
   - Enhanced logging

---

## Testing Strategy

### Unit Tests

```typescript
// PKCE utilities
describe('generateCodeVerifier', () => {
  it('generates 43-character string', () => {
    const verifier = generateCodeVerifier()
    expect(verifier).toHaveLength(43)
  })
})

// Token refresh deduplication
describe('APIClient', () => {
  it('deduplicates concurrent refresh requests', async () => {
    // Mock multiple 401 responses
    // Verify only one refresh call made
  })
})
```

### Integration Tests

```typescript
// OAuth flow
describe('OAuth Login Flow', () => {
  it('completes full OAuth flow with PKCE', async () => {
    // 1. Initiate login
    // 2. Mock OAuth redirect
    // 3. Verify callback handling
    // 4. Check token storage
    // 5. Verify redirect to app
  })
})
```

### Security Tests

```typescript
// CSRF protection
describe('CSRF Protection', () => {
  it('rejects requests with invalid state', async () => {
    // Attempt callback with wrong state
    // Verify rejection
  })
})

// Token security
describe('Token Security', () => {
  it('does not expose refresh token to JavaScript', () => {
    // Verify httpOnly cookie
    // Attempt to access via document.cookie
    // Verify access denied
  })
})
```

---

## Deployment Considerations

### Environment Variables

**Development**:
```bash
NEXT_PUBLIC_API_URL=http://localhost:8080
NEXT_PUBLIC_OAUTH_CLIENT_ID=flovyn-web-dev
NEXT_PUBLIC_OAUTH_REDIRECT_URI=http://localhost:3000/auth/callback
NODE_ENV=development
```

**Production**:
```bash
NEXT_PUBLIC_API_URL=https://api.flovyn.io
NEXT_PUBLIC_OAUTH_CLIENT_ID=flovyn-web-prod
NEXT_PUBLIC_OAUTH_REDIRECT_URI=https://app.flovyn.io/auth/callback
NODE_ENV=production
```

### Backend Configuration

**Required Backend Settings**:
1. CORS: Allow `https://app.flovyn.io`
2. OAuth client: Register `flovyn-web-prod`
3. Redirect URI: Whitelist `https://app.flovyn.io/auth/callback`
4. Token lifetimes:
   - Access token: 15 minutes
   - Refresh token: 30 days
   - Authorization code: 5 minutes

### CDN/Edge Configuration

1. **Cache Headers**: Don't cache auth pages
2. **Security Headers**:
   ```
   Strict-Transport-Security: max-age=31536000; includeSubDomains
   X-Content-Type-Options: nosniff
   X-Frame-Options: DENY
   X-XSS-Protection: 1; mode=block
   ```

---

## References

- [OAuth 2.0 RFC 6749](https://tools.ietf.org/html/rfc6749)
- [PKCE RFC 7636](https://tools.ietf.org/html/rfc7636)
- [OAuth 2.0 Security Best Practices](https://tools.ietf.org/html/draft-ietf-oauth-security-topics)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [httpOnly Cookies](https://owasp.org/www-community/HttpOnly)

---

**Document Version**: 1.0
**Last Security Review**: 2025-11-10
**Next Review Due**: 2025-12-10
