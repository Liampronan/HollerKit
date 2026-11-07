# HollerKit Privacy Policy & Requirements

HollerKit is **self-hosted first**. You control the `/v1` server, the Postgres database (`hollerkit` schema), the private object storage bucket, and data retention.

## Core Privacy Guarantees

- **Runtime gating (`isEnabled`)**: When `isEnabled()` returns `false` (for example on public App Store installs when using `HollerKitEnvironment.isDebugOrTestFlight`), the iOS SDK attaches no observers, records no breadcrumbs, stores no files, and makes no network requests.
- **No stored credentials on device**: The iOS `OutboxStore` persists pending feedback JSON and screenshot attachments in Application Support while offline or signed out, but **never** writes JWTs or authentication tokens to disk. It calls your `auth` closure dynamically at flush time.
- **Transcript-first voice notes**: Microphone capture and speech recognition are opt-in and only activate when a tester taps the dictation button. By default, HollerKit submits the text transcript and provenance (`on_device`, `apple_network`, `manual`, or `unavailable`) rather than uploading raw audio files.
- **Required `Info.plist` usage descriptions**: Because TestFlight builds are compiled as Release archives, any target that ships HollerKit with voice dictation enabled must include `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in `Info.plist`.
- **Destructive image redaction**: When a tester redacts or annotates a screenshot or quest mark in the iOS editor, the redacted pixels are flattened into a new bitmap before the image is saved or uploaded.
- **Explicit tester identity**: HollerKit does not scrape emails or device advertising identifiers. Tester submissions are authenticated with your host app's session JWT (`tester` scope), and the server records the verified `submitter_id` from that token.
- **Apple Privacy Manifest (`PrivacyInfo.xcprivacy`)**: The iOS package includes a privacy manifest declaring user-submitted customer support content, images, diagnostics metadata, and product interaction breadcrumbs for app functionality, with tracking disabled.

## Operational Guidance

- **Use private object storage**: Configure Supabase Storage or S3 buckets as private. `hollerkit-server` issues short-lived presigned upload URLs (`PUT`) and short-lived signed read URLs (`GET`, 15-minute TTL) so screenshots are never world-readable.
- **Enforce tester allowlists**: When using `supabaseJwt({ store })` in production, keep `requireTesterAllowlist` enabled (the default) so only active rows in `hollerkit.testers` can fetch quests or submit feedback.
- **Database isolation**: The `0001_v1.sql` migration creates all tables inside the `hollerkit` schema with Row-Level Security (RLS) enabled and zero public policies, preventing direct PostgREST access via `anon` or `authenticated` roles.
