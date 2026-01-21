# Bug: Webhook Ingest Issues

**Date:** 2026-01-20
**Status:** Open
**Severity:** Medium

## Summary

Multiple issues with the webhook ingest endpoint:

1. **Event type extraction** - Does not support generic `X-Event-Type` header
2. **Wrong domain in ingest URL** - Hardcoded as `api.flovyn.io` but should be `api.flovyn.ai`
3. **Non-configurable base URL** - Ingest URL path is not configurable, breaking localhost development

---

## Issue 1: Event Type Extraction Missing Generic X-Event-Type Header

The webhook ingest endpoint does not extract event type from the generic `X-Event-Type` header, causing events to show "unknown" event type in the UI when this header is used.

## How Event Type is Currently Populated

The `extract_event_type` function in `flovyn-server/plugins/eventhook/src/api/ingest.rs` extracts event type from:

1. **Headers** (checked first):
   - `X-GitHub-Event` - GitHub's webhook event type header

2. **JSON Body fields** (checked if header not found):
   - `type` - Stripe's pattern (e.g., `{"type": "payment_intent.succeeded"}`)
   - `event_type` - snake_case pattern
   - `eventType` - camelCase pattern

If none of these are present, event type is `None` and displays as "unknown" in the UI.

## Reproduction Steps

1. Create a webhook source
2. Send a webhook with the `X-Event-Type` header:
   ```bash
   curl -X POST https://api.flovyn.io/api/orgs/eventhook/in/{source-slug} \
     -H "Content-Type: application/json" \
     -H "X-Event-Type: order.created" \
     -d '{"orderId": "123"}'
   ```
3. View the event in the webhook events page
4. Event type column shows "unknown" instead of "order.created"

## Root Cause

In `flovyn-server/plugins/eventhook/src/api/ingest.rs`, the `extract_event_type` function only checks for:
- `X-GitHub-Event` header (GitHub-specific)
- JSON body fields: `type`, `event_type`, `eventType`

It does not check for the generic `X-Event-Type` header.

```rust
// Current code (line 269-290)
fn extract_event_type(headers: &HeaderMap, body: &[u8]) -> Option<String> {
    // GitHub: X-GitHub-Event
    if let Some(v) = headers.get("x-github-event").and_then(|v| v.to_str().ok()) {
        return Some(v.to_string());
    }

    // Stripe: from payload type field
    if let Ok(json) = serde_json::from_slice::<serde_json::Value>(body) {
        // ... checks body fields only
    }

    None
}
```

## Impact

- E2E tests in `flovyn-app` send webhooks with `X-Event-Type` header (see `tests/e2e/helpers/webhook.ts:303-305`)
- All those events show "unknown" event type
- Users sending webhooks with this common header pattern get no event type displayed

## Proposed Fix

Add support for `X-Event-Type` header in `extract_event_type`:

```rust
fn extract_event_type(headers: &HeaderMap, body: &[u8]) -> Option<String> {
    // GitHub: X-GitHub-Event
    if let Some(v) = headers.get("x-github-event").and_then(|v| v.to_str().ok()) {
        return Some(v.to_string());
    }

    // Generic: X-Event-Type
    if let Some(v) = headers.get("x-event-type").and_then(|v| v.to_str().ok()) {
        return Some(v.to_string());
    }

    // ... rest of function
}
```

## Current Limitations

- Event type extraction is **NOT source-dependent** - same logic applies to all sources
- No way to configure custom header names or JSON paths per source
- Users with non-standard webhook providers cannot specify where event type is located

## Potential Enhancement: Configurable Event Type Extraction

Add optional configuration to `WebhookSource` to allow per-source event type extraction:

```rust
pub struct WebhookSource {
    // ... existing fields ...

    /// Optional configuration for extracting event type
    pub event_type_config: Option<EventTypeConfig>,
}

pub struct EventTypeConfig {
    /// Header name to extract event type from (e.g., "X-My-Event-Type")
    pub header_name: Option<String>,
    /// JSON path to extract event type from (e.g., "$.event.type" or "metadata.eventType")
    pub json_path: Option<String>,
}
```

This would allow users to configure:
- Custom header: `X-Shopify-Topic`, `X-Webhook-Event`, etc.
- Custom JSON path: `event.name`, `metadata.type`, `webhook_type`, etc.

## Related Files

- `flovyn-server/plugins/eventhook/src/api/ingest.rs` - Backend extraction logic
- `flovyn-server/plugins/eventhook/src/domain/source.rs` - Source entity (needs enhancement)
- `flovyn-app/tests/e2e/helpers/webhook.ts` - E2E helper sends X-Event-Type
- `flovyn-app/apps/web/components/webhooks/events/webhook-events-data-grid.tsx` - UI shows "unknown"

---

## Issue 2: Wrong Domain in Ingest URL

### Problem

The webhook ingest URL displayed in the UI uses the wrong domain:
- **Current:** `https://api.flovyn.io/api/orgs/{orgSlug}/eventhook/in/{sourceSlug}`
- **Should be:** `https://api.flovyn.ai/api/orgs/{orgSlug}/eventhook/in/{sourceSlug}`

### Impact

- Users copying the ingest URL from the UI will get a non-working URL
- Webhooks sent to `api.flovyn.io` will fail in production

### Proposed Fix

Update the hardcoded domain from `flovyn.io` to `flovyn.ai` wherever it appears.

---

## Issue 3: Non-Configurable Base URL for Ingest Endpoint

### Problem

The ingest URL base path is hardcoded and cannot be configured. This breaks:
- **Localhost development** - URL shows `https://api.flovyn.ai` but should show `http://localhost:{port}`
- **Staging environments** - May need different base URLs
- **Self-hosted deployments** - Users have their own domains

### Current Behavior

When viewing a webhook source, the ingest URL is always shown with the production domain, regardless of the environment.

### Proposed Fix

Make the base URL configurable via environment variable:

```rust
// Environment variable: WEBHOOK_INGEST_BASE_URL
// Default: https://api.flovyn.ai
// Development: http://localhost:8080
// Staging: https://api.staging.flovyn.ai
```

The frontend should either:
1. Receive the base URL from an API endpoint (e.g., `/api/config`)
2. Or construct it based on `window.location` for same-origin deployments

### Example Configuration

```env
# Production
WEBHOOK_INGEST_BASE_URL=https://api.flovyn.ai

# Development
WEBHOOK_INGEST_BASE_URL=http://localhost:8080

# Staging
WEBHOOK_INGEST_BASE_URL=https://api.staging.flovyn.ai
```

---

## Priority

1. **Issue 2 (Wrong domain)** - High priority, production bug
2. **Issue 3 (Configurable URL)** - Medium priority, blocks local development
3. **Issue 1 (X-Event-Type header)** - Low priority, enhancement
