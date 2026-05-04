# HollerKit Privacy Requirements

HollerKit is self-host first. The app owner controls storage, routing, retention, and destination issues.

## v1 Requirements

- Microphone capture is opt-in by SDK configuration.
- Raw audio upload is off by default. If enabled, it is explicit and capped by duration and byte size.
- Speech recognition permission is requested only when transcription is enabled.
- Transcript provenance is included in the issue body: on-device, Apple network, manual, or unavailable.
- Redacted images must be destructively exported before upload.
- Email and direct user identifiers are never collected automatically.
- Apps may pass an opaque user ID; the SDK hashes it before transmission.
- The iOS package should provide an Apple privacy manifest before release.

## Operational Guidance

- Treat the app secret as low-trust because it ships in the iOS binary.
- Pair HMAC validation with server-side rate limiting, strict size caps, optional auth, and optional App Attest.
- Prefer private object storage for screenshots, annotated images, and any opt-in raw audio upload in production.
- Use GitHub Release storage only for demos and zero-infra experiments.
