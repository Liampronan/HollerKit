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
   - **Testers (`tester` scope)**: Authenticate using short-lived JWTs from your app's auth provider (verified via ES256 or RS256 JWKS, or HS256 secret in `supabaseJwt`). When a `store` is configured and no custom `authorizeTester` callback is provided, `supabaseJwt` checks that the token's `sub` has an active row (`active = true`) in `hollerkit.testers`; when `authorizeTester` is supplied, that callback replaces the store check even if `store` is also configured.
   - **CI & Coding Agents (`quests:write`, `agent:read`, `agent:triage` scopes)**: Authenticate using `hk_<48-hex>` API keys minted by `hollerkit keys create` (or `hk_<prefix>_<48-hex>` when an optional prefix is passed to `generateApiKey(prefix)`, which trims leading/trailing underscores and avoids duplicating `hk_`). Raw API keys are displayed only once at creation time; only the SHA-256 `key_hash` and a 12-character `key_prefix` (`rawKey.slice(0, 12)`) are stored in `hollerkit.api_keys`.
2. **Bound Presigned Upload Grants**:
   - `POST /v1/uploads` creates attachment upload grants bound to `(feedback_id, submitter_id, storage_key, mime_type, max_bytes)` with a configurable default maximum lifetime of 10 minutes (`limits.uploadUrlTtlSeconds`). Clients should always use the returned `expiresAt` timestamp because server configuration or the underlying storage adapter may enforce an earlier expiry.
   - `POST /v1/feedback` (for new feedback and quest-run submissions) and `POST /v1/feedback/:id/finalize` verify that the authenticated caller matches each referenced grant's `submitter_id`, that the grant has not expired or already been consumed, and that every attachment `storageKey` belongs to that specific `feedback_id`.
3. **Database & Storage Isolation**:
   - All Postgres tables live in the `hollerkit` schema with Row-Level Security (RLS) enabled and no `anon`/`authenticated` policies, ensuring PostgREST cannot expose feedback or API key hashes.
   - If you deploy on Supabase Edge Functions with `verify_jwt = false` in `supabase/config.toml`, `createHollerKitServer` enforces authentication and scope checks on every `/v1/*` route except `GET /v1/health`.
4. **No Client-Side Token Persistence**:
   - The iOS `OutboxStore` queues offline submissions without writing bearer tokens to disk, requesting a fresh token from the host app's `auth` closure only when flushing over HTTPS.
