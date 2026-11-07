# Security Policy

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately through GitHub's security advisory flow for this repository. Do not open a public GitHub issue for security-sensitive reports.

Please include:

- Affected component (`ios/`, `server/`, `mcp/`), version, or commit SHA.
- Steps to reproduce or a minimal proof of concept.
- Potential impact (such as authentication bypass, unauthorized access to feedback or upload grants, or credential exposure).

We will acknowledge valid reports promptly and coordinate a fix before public disclosure.

---

## HollerKit `/v1` Security Model

HollerKit v1 replaces the v0.5 shared client HMAC secret with scoped server-side authentication and bound upload grants:

1. **Scoped Authentication**:
   - **Testers (`tester` scope)**: Authenticate using short-lived JWTs from your app's auth provider (verified via ES256 JWKS or HS256 secret in `supabaseJwt`) and are checked against `hollerkit.testers` (`active = true`).
   - **CI & Coding Agents (`quests:write`, `agent:read`, `agent:triage` scopes)**: Authenticate using `hk_<64-hex>` API keys. Raw API keys are displayed only once at creation time (`hollerkit keys create`); only the SHA-256 `key_hash` and an 11-character `key_prefix` are stored in `hollerkit.api_keys`.
2. **Bound Presigned Upload Grants**:
   - Every attachment upload grant in `POST /v1/feedback` is bound to `(feedback_id, submitter_id, storage_key, mime_type, max_bytes)` with a 15-minute expiration.
   - `POST /v1/feedback/:id/finalize` verifies that the authenticated caller matches the grant's `submitter_id`, that the grant has not expired, and that every finalized `storageKey` belongs to that specific feedback item.
3. **Database & Storage Isolation**:
   - All Postgres tables live in the `hollerkit` schema with Row-Level Security (RLS) enabled and no `anon`/`authenticated` policies, ensuring PostgREST cannot expose feedback or API key hashes.
   - If you deploy on Supabase Edge Functions with `verify_jwt = false` in `supabase/config.toml`, `createHollerKitServer` enforces authentication and scope checks on every `/v1/*` route except `GET /v1/health`.
4. **No Client-Side Token Persistence**:
   - The iOS `OutboxStore` queues offline submissions without writing bearer tokens to disk, requesting a fresh token from the host app's `auth` closure only when flushing over HTTPS.
