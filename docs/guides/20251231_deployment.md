# Deployment Guide: Flovyn Server + Flovyn App

This guide covers deploying Flovyn Server with Flovyn App authentication in different scenarios.

## Overview

Flovyn supports two deployment modes:

| Mode | Orgs | Use Case |
|------|---------|----------|
| **Self-Hosted** | Pre-configured in config file | Single organization, on-premises |
| **SaaS** | Created dynamically | Multi-org platform |

Both modes use the same authentication flow:
- **Users**: JWT tokens from Flovyn App (via browser or device flow)
- **Workers**: API keys created in Flovyn App
- **CLI**: Device flow or API keys

---

## Prerequisites

- PostgreSQL 15+
- Docker (optional, for containerized deployment)
- Flovyn App instance (for authentication)

---

## Mode 1: Self-Hosted Deployment

Best for: Single organization deploying their own Flovyn instance.

### Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Flovyn App    │     │  Flovyn Server  │     │   PostgreSQL    │
│  (your-domain)  │────▶│   (internal)    │────▶│   (internal)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       ▲
        │                       │
        ▼                       │
┌─────────────────┐     ┌───────┴───────┐
│     Users       │     │    Workers    │
│   (browser)     │     │ (SDK clients) │
└─────────────────┘     └───────────────┘
```

### Step 1: Configure Flovyn App

Create an organization in Flovyn App with a slug (e.g., `acme`). This slug will be used to link to the org in Flovyn Server.

Enable the required plugins in `better-auth-server.ts`:
- `jwt` - For issuing JWTs to users
- `organization` - For multi-user organizations
- `apiKey` - For worker tokens and CLI access
- `deviceAuthorization` - For CLI login

### Step 2: Configure Flovyn Server

Create a configuration file (e.g., `config.toml`):

```toml
# Database
[database]
url = "postgres://flovyn:password@localhost:5432/flovyn"

# Server ports
[server]
http_port = 8000
grpc_port = 9090

# Pre-configured org
# The slug MUST match the organization slug in Flovyn App
[[orgs]]
id = "550e8400-e29b-41d4-a716-446655440000"
name = "Acme Corp"
slug = "acme"

# Authentication
[auth]
enabled = true

# JWT validation (tokens from Flovyn App)
[auth.better_auth_jwt]
jwks_uri = "https://app.acme.com/.well-known/jwks.json"
issuer = "https://app.acme.com"
audience = "flovyn-server"

# API key validation (for workers and CLI)
[auth.better_auth]
validation_url = "https://app.acme.com/api/auth/validate-key"
timeout_secs = 5

# HTTP endpoints: JWT for users, API keys for integrations
[auth.endpoints.http]
authenticators = ["better_auth_jwt", "better_auth_api_key", "static_api_key"]
authorizer = "cedar"
exclude_paths = ["/_/health", "/api/docs", "/api/docs/openapi.json"]

# gRPC endpoints: API keys for workers
[auth.endpoints.grpc]
authenticators = ["better_auth_api_key", "worker_token", "static_api_key"]
authorizer = "cedar"
```

### Step 3: Create Worker Tokens

In Flovyn App:
1. Navigate to **Organization Settings > Worker Tokens**
2. Click **Create Worker Token**
3. Copy the token (shown only once)

Use this token in your worker configuration:

```bash
export FLOVYN_API_KEY="flovyn_wk_..."
```

### Step 4: Deploy

**Using Docker:**

```bash
docker run -d \
  --name flovyn-server \
  -p 8000:8000 \
  -p 9090:9090 \
  -v /path/to/config.toml:/app/config.toml \
  -e CONFIG_FILE=/app/config.toml \
  -e DATABASE_URL=postgres://flovyn:password@db:5432/flovyn \
  ghcr.io/flovyn/flovyn-server:latest
```

**Using systemd:**

```ini
[Unit]
Description=Flovyn Server
After=network.target postgresql.service

[Service]
Type=simple
User=flovyn
Environment=CONFIG_FILE=/etc/flovyn/config.toml
Environment=DATABASE_URL=postgres://flovyn:password@localhost:5432/flovyn
ExecStart=/usr/local/bin/flovyn-server
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## Mode 2: SaaS Deployment

Best for: Hosting Flovyn as a service for multiple customers.

### Architecture

```
┌─────────────────┐
│   Flovyn App    │
│ (app.flovyn.ai)│
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Load Balancer  │────▶│  Flovyn Server  │──┐
└─────────────────┘     │    (cluster)    │  │
         │              └─────────────────┘  │
         │                                   ▼
         │              ┌─────────────────────────────┐
         │              │        PostgreSQL           │
         │              │  (shared or per-org)     │
         │              └─────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│              Customer Orgs               │
│  ┌───────┐  ┌───────┐  ┌───────┐           │
│  │ Org A │  │ Org B │  │ Org C │  ...      │
│  └───────┘  └───────┘  └───────┘           │
└─────────────────────────────────────────────┘
```

### Step 1: Configure Flovyn App

Deploy Flovyn App as your central authentication service. Organizations are created dynamically when customers sign up.

### Step 2: Configure Flovyn Server

```toml
# Database
[database]
url = "postgres://flovyn:password@db.internal:5432/flovyn"

# Server ports
[server]
http_port = 8000
grpc_port = 9090

# No pre-configured orgs in SaaS mode
# Orgs are created via API or auto-created on first request

# Authentication
[auth]
enabled = true

# JWT validation
[auth.better_auth_jwt]
jwks_uri = "https://app.flovyn.ai/.well-known/jwks.json"
issuer = "https://app.flovyn.ai"
audience = "flovyn-server"

# API key validation
[auth.better_auth]
validation_url = "https://app.flovyn.ai/api/auth/validate-key"
timeout_secs = 5

# Org resolver settings
[auth.org_resolver]
cache_ttl_secs = 300
# auto_create = true  # Uncomment to auto-create orgs on first request

# HTTP endpoints
[auth.endpoints.http]
authenticators = ["better_auth_jwt", "better_auth_api_key"]
authorizer = "cedar"
exclude_paths = ["/_/health", "/api/docs", "/api/docs/openapi.json"]

# gRPC endpoints
[auth.endpoints.grpc]
authenticators = ["better_auth_api_key", "worker_token"]
authorizer = "cedar"
```

### Step 3: Customer Onboarding

When a new customer signs up:

1. **Create organization** in Flovyn App (via UI or API)
2. **Create org** in Flovyn Server with matching slug:

```bash
curl -X POST https://api.flovyn.ai/api/orgs \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Customer Corp",
    "slug": "customer-corp"
  }'
```

Or enable `auto_create = true` to automatically create orgs on first authenticated request.

### Step 4: Deploy with Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flovyn-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app: flovyn-server
  template:
    metadata:
      labels:
        app: flovyn-server
    spec:
      containers:
      - name: flovyn-server
        image: ghcr.io/flovyn/flovyn-server:latest
        ports:
        - containerPort: 8000
          name: http
        - containerPort: 9090
          name: grpc
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: flovyn-secrets
              key: database-url
        - name: CONFIG_FILE
          value: /app/config.toml
        volumeMounts:
        - name: config
          mountPath: /app/config.toml
          subPath: config.toml
      volumes:
      - name: config
        configMap:
          name: flovyn-config
---
apiVersion: v1
kind: Service
metadata:
  name: flovyn-server
spec:
  selector:
    app: flovyn-server
  ports:
  - name: http
    port: 8000
  - name: grpc
    port: 9090
```

---

## CLI Authentication

The Flovyn CLI supports two authentication methods:

### Device Flow (Interactive)

Best for developers working locally:

```bash
$ flovyn auth login
Visit: https://app.flovyn.ai/device
Enter code: ABCD-1234

Waiting for authorization... ✓
Logged in as john@example.com (org: acme)
Token saved to ~/.flovyn/credentials
```

### API Key (Non-Interactive)

Best for CI/CD and automation:

```bash
# Create a personal API key in Flovyn App (Profile > API Keys)
$ flovyn auth login --api-key
Enter API key: flovyn_sk_...
Logged in as john@example.com (org: acme)

# Or use environment variable
$ export FLOVYN_API_KEY="flovyn_sk_..."
$ flovyn workflow list
```

### Credentials File

Credentials are stored in `~/.flovyn/credentials`:

```toml
[default]
type = "jwt"
token = "eyJhbG..."
expires_at = "2025-12-29T12:00:00Z"
org_slug = "acme"
server_url = "https://api.flovyn.ai"

[profiles.staging]
type = "api_key"
token = "flovyn_sk_..."
org_slug = "acme-staging"
server_url = "https://staging.api.flovyn.ai"
```

Switch profiles:

```bash
$ flovyn --profile staging workflow list
```

---

## Authentication Flow Reference

### JWT Flow (Users)

```
User                    Flovyn App              Flovyn Server
 │                          │                        │
 │──── Login ──────────────▶│                        │
 │◀─── Session + JWT ───────│                        │
 │                          │                        │
 │──── API Request ─────────┼───────────────────────▶│
 │     (Bearer JWT)         │                        │
 │                          │                        │
 │                          │◀─ Fetch JWKS (cached) ─│
 │                          │                        │
 │                          │    Validate JWT        │
 │                          │    Extract org.slug    │
 │                          │    Resolve org_id   │
 │                          │                        │
 │◀─── Response ────────────┼────────────────────────│
```

### API Key Flow (Workers/CLI)

```
Worker/CLI              Flovyn App              Flovyn Server
 │                          │                        │
 │──── API Request ─────────┼───────────────────────▶│
 │     (Bearer flovyn_wk_)  │                        │
 │                          │                        │
 │                          │◀─ Validate API Key ────│
 │                          │   POST /api/auth/      │
 │                          │        validate-key    │
 │                          │                        │
 │                          │── { valid, orgSlug }│
 │                          │                        │
 │                          │    Resolve org_id   │
 │                          │                        │
 │◀─── Response ────────────┼────────────────────────│
```

---

## Troubleshooting

### "Unknown organization" Error

The org slug in the JWT doesn't match any org in Flovyn Server.

**Fix:** Ensure the org exists with the correct slug:

```bash
# Check existing orgs
psql $DATABASE_URL -c "SELECT id, slug, name FROM organization"

# Create org with matching slug
curl -X POST https://api.flovyn.ai/api/orgs \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name": "Acme", "slug": "acme"}'
```

### "Invalid credentials" for API Key

The API key validation endpoint returned an error.

**Fix:**
1. Check the API key is valid in Flovyn App
2. Verify `validation_url` is correct in config
3. Check network connectivity between Flovyn Server and Flovyn App

### JWKS Fetch Errors

Flovyn Server can't fetch the JWKS from Flovyn App.

**Fix:**
1. Verify `jwks_uri` is accessible: `curl https://app.example.com/.well-known/jwks.json`
2. Check TLS certificates if using HTTPS
3. Ensure network allows outbound connections from Flovyn Server

### Cache Issues

Changes to orgs or keys not reflecting immediately.

**Fix:** The default cache TTL is 5 minutes. Wait for cache expiration or restart Flovyn Server.

---

## Security Considerations

1. **Always use HTTPS** in production for JWKS and validation endpoints
2. **Restrict network access** - Flovyn Server should only accept connections from trusted sources
3. **Rotate API keys** regularly, especially for production workers
4. **Monitor authentication failures** for suspicious activity
5. **Use short JWT expiry** (default 5 minutes) to limit exposure if tokens leak
