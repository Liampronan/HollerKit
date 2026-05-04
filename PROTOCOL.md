# HollerKit Wire Protocol

## Request

```text
POST /bug-report
Content-Type: multipart/form-data

x-hollerkit-timestamp: <unix seconds>
x-hollerkit-signature: <hex HMAC-SHA256 of body || timestamp>
```

## Multipart Fields

| Field | Type | Notes |
| --- | --- | --- |
| `inputMode` | string | `text-and-audio`, `text-only`, or `audio-only`; defaults to `text-and-audio`. |
| `comment` | string | Optional depending on input mode. |
| `transcript` | JSON object | Optional transcript payload. |
| `metadata` | JSON object | App, device, OS, and integration metadata. |
| `breadcrumbs` | JSON array | Optional recent app events. |
| `userIdHash` | string | Optional opaque hashed user identifier. |
| `image` | file, repeatable | PNG, JPEG, HEIC, or HEIF. |
| `audio` | file, max 1 | M4A/AAC-style short audio note. |

## Transcript Payload

```ts
type TranscriptPayload = {
  text: string
  locale: string
  engine: 'apple-on-device' | 'apple-network' | 'manual' | 'unavailable'
  confidence?: number
  durationSeconds?: number
}
```

## Response

```json
{ "ok": true, "issueUrl": "https://github.com/owner/repo/issues/1", "reportId": "..." }
```

If a classifier skips issue creation:

```json
{ "ok": true, "reportId": "...", "skipped": true }
```

Errors use:

```json
{ "ok": false, "error": { "code": "invalid_signature", "message": "..." } }
```

## Default Limits

| Limit | Default |
| --- | --- |
| Timestamp drift | plus or minus 5 minutes |
| Images | 5 |
| Image size | 8 MB each |
| Audio files | 1 |
| Audio duration | 60 seconds |
| Audio size | 2 MB |
| Comment length | 10,000 characters |
| Transcript length | 20,000 characters |
| Metadata size | 64 KB |
| Breadcrumb count | 100 |

Accepted image MIME types: `image/png`, `image/jpeg`, `image/heic`, `image/heif`.

Accepted audio MIME types: `audio/mp4`, `audio/aac`, `audio/m4a`, `audio/x-m4a`.
