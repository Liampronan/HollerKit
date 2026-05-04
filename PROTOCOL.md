# HollerKit Wire Protocol

The exact HTTP contract is defined in [`openapi.yaml`](./openapi.yaml). This document explains the signing rules, operational limits, and replay protections that are easier to understand in prose.

## Request

```text
POST /bug-report
Content-Type: multipart/form-data

x-hollerkit-timestamp: <unix seconds>
x-hollerkit-signature: <hex HMAC-SHA256 of body || timestamp>
```

Handlers reject requests with `Content-Length` above `maxBodyBytes` before buffering the body. Deployments should also configure their platform or reverse proxy body limit, especially when accepting chunked requests where `Content-Length` is absent.

## Multipart Contract

See [`openapi.yaml`](./openapi.yaml) for the canonical multipart field list, response shapes, status codes, and error codes.

Important wire detail: JSON values such as `metadata`, `breadcrumbs`, and `transcript` are sent as multipart text fields containing JSON strings. Uploaded `image` and `audio` fields are multipart file parts.

## Default Limits

| Limit | Default |
| --- | --- |
| Timestamp drift | plus or minus 5 minutes |
| Request body | 45 MB |
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

## Replay Window

The timestamped HMAC limits casual replay, but a captured request can be resent within the configured drift window. High-volume or high-trust deployments should add an `x-hollerkit-request-id` header covered by the HMAC and deduplicate request IDs in Redis, KV, or another short-lived cache.
