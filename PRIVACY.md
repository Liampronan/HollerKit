# HollerKit Privacy Requirements

HollerKit is self-host first. The app owner controls storage, routing, retention, and destination issues.

## Requirements

- Microphone capture is opt-in by SDK configuration.
- Raw audio upload is off by default. If enabled, it is explicit and capped by duration and byte size.
- Speech recognition permission is requested only when transcription is enabled.
- Apps that only enable HollerKit in debug, internal, or TestFlight-style targets can keep microphone and speech-recognition usage strings scoped to those non-release targets.
- Transcript provenance is included in the issue body: on-device, Apple network, manual, or unavailable.
- The default iOS sheet submits transcript text, not raw audio.
- Redacted images must be destructively exported before upload.
- Email and direct user identifiers are never collected automatically.
- Apps may pass an opaque user ID; the SDK hashes it before transmission.
- The iOS package includes an Apple privacy manifest declaring customer-support content, submitted images, diagnostics metadata, and breadcrumb-style product interaction data for app functionality. It does not declare tracking.

## Operational Guidance

- Treat the app secret as low-trust because it ships in the iOS binary.
- Pair HMAC validation with server-side rate limiting, strict size caps, optional auth, and optional App Attest.
- Configure a deployment or reverse-proxy body-size limit. HollerKit rejects oversized `Content-Length` values before buffering, but platform limits are still important for chunked uploads.
- The default timestamp window is five minutes. Add a short-lived request-ID cache if replayed duplicate reports would be painful for your team.
- User comments and transcripts are rendered as code blocks in GitHub issue bodies so untrusted Markdown does not create mentions, HTML, or deceptive links.
- Prefer private object storage for screenshots, annotated images, and any opt-in raw audio upload in production.
- Use GitHub Release storage only for demos and zero-infra experiments.
