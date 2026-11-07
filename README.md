# HollerKit

[![CI](https://github.com/Liampronan/HollerKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Liampronan/HollerKit/actions/workflows/ci.yml)

<p align="center">
  <img src="./assets/hollerkit-banner.png" alt="HollerKit" width="200">
</p>

HollerKit is a simple user feedback SDK to let you easily collect screenshot-based feedback from people using your iOS app. 

It is a combination of:

- An iOS Swift Package for collecting reports, screenshots, breadcrumbs, metadata, and optional audio notes.
- A small self-hosted server handler that validates reports, uploads attachments, and creates GitHub issues.

Bonus: try optional audio-only bug reports, which transcribe a user's voice note into text for easier capture.

## Status

HollerKit is currently at **v0.5**. The server pipeline is usable, and the iOS package can present a report sheet, attach screenshots, annotate images, transcribe short voice notes when Speech is available, collect metadata and breadcrumbs, and submit reports.

HollerKit is currently intended for **internal, debug, QA, and TestFlight-style builds**. It can be used in a production app target when gated appropriately, but it should not be exposed broadly to every public App Store user without the operational safeguards listed below.

The repo is organized as:

- `ios/`: Swift Package for capture UI, metadata, breadcrumbs, and multipart upload.
- `server/`: npm package for validating signed multipart reports, uploading assets, and creating issues.
- `examples/`: deployment examples for Supabase and Node.

## Production App Checklist

Before enabling HollerKit in a production app target:

- Gate the SDK at runtime using `isEnabled` (e.g. `HollerKitEnvironment.isDebugOrTestFlight`, a feature flag, or a staff account check) and enforce tester allowlists on the server (`hollerkit.testers`).
- Deploy the server endpoint behind platform or reverse-proxy body limits.
- Add rate limiting, abuse monitoring, and alerting around the `/v1` endpoints.
- Store Supabase service role keys, S3 credentials, and API keys only on the server; pass the host app's current user session token dynamically via `auth: { await Auth.currentAccessToken() }` without caching tokens in HollerKit.
- Use private attachment storage with presigned upload and read URLs.
- Include `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in `Info.plist` for any target that ships HollerKit with audio dictation—including Release targets when TestFlight testers use it.
- Confirm report contents are acceptable for your privacy policy, retention policy, and support workflow.

## Demo UI

<p>
  <img src="./examples/ios-demo/Screenshots/hollerkit-report-sheet.png" alt="HollerKit report sheet with attached screenshots" width="260">
  <img src="./examples/ios-demo/Screenshots/hollerkit-annotation-editor.jpg" alt="HollerKit annotation editor with redaction tools" width="260">
</p>

## iOS Quickstart

Add the local Swift package from `ios/` while developing (requires **iOS 18+**).

In Xcode:

1. Open your app project.
2. Choose **File > Add Package Dependencies**.
3. Choose **Add Local...** and select `HollerKit/ios`.
4. Add `HollerKit` to your app target.

Configure HollerKit when your app starts:

```swift
import HollerKit

HollerKit.configure(
    server: URL(string: "https://example.supabase.co/functions/v1/hollerkit")!,
    auth: { try await supabase.auth.session.accessToken },
    isEnabled: { HollerKitEnvironment.isDebugOrTestFlight },
    invocation: [.shake, .screenshot],
    inputMode: .textAndAudio,
    metadata: { ["experiment": Flags.activeExperiment] },
    captureBreadcrumbs: true
)
```

### Runtime Gating (`isEnabled`) vs. `#if DEBUG`

**TestFlight builds are Release archives.** Gating HollerKit behind `#if DEBUG` silently strips it from TestFlight builds right when QA and beta testers need it most. Instead, gate HollerKit at runtime with the `isEnabled` closure:

- When `isEnabled()` returns `false` (for example in App Store builds when using `HollerKitEnvironment.isDebugOrTestFlight`), `HollerKit` shows no UI, attaches no shake or screenshot observers, records no breadcrumbs, and turns `presentBugReport()` / `presentQuests()` into no-ops.
- Because TestFlight archives are built with the Release configuration, `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` **must** be present in any target that ships HollerKit, including Release when TestFlight testers use voice notes.
- **Recommended architecture:** Wrap `HollerKit` behind a thin app-side protocol or facade (with a live implementation calling `HollerKit` and a no-op implementation). That keeps call sites decoupled across your app and lets you switch to compile-time exclusion in a single file later if you ever stop using HollerKit in TestFlight.

```swift
protocol FeedbackReporter {
    @MainActor func configure()
    @MainActor func breadcrumb(_ message: String, category: String?)
    @MainActor func presentBugReport()
}
```

Choose how HollerKit can be invoked with the `invocation` option:

```swift
invocation: []                    // manual only
invocation: [.shake]              // shake to report
invocation: [.screenshot]         // prompt after a screenshot
invocation: [.shake, .screenshot] // both
```

When `.screenshot` is enabled, HollerKit opens after `UIApplication.userDidTakeScreenshotNotification` and seeds the report with a current screenshot of the containing app.

Install the presenter once near the root of your SwiftUI app. This is what allows HollerKit to open its sheet from shake and screenshot triggers:

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .hollerKitPresenter()
        }
    }
}
```

You can also present the report UI from your own button or menu:

```swift
struct SettingsView: View {
    var body: some View {
        Button("Report a Bug") {
            HollerKit.present()
        }
    }
}
```

Record breadcrumbs around important app events:

```swift
HollerKit.breadcrumb("Opened checkout", category: "navigation")
HollerKit.breadcrumb("Payment failed", category: "checkout", metadata: [
    "provider": "stripe"
])
```

If you enable audio, add the appropriate privacy strings to your app target:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

Audio in the default iOS sheet is transcript-first. HollerKit uses microphone input for live speech recognition, submits the transcript text, and does not submit a raw audio file.

## Server Quickstart

```ts
import {
  apiKeys,
  createHollerKitServer,
  flushOutbox,
  postgresStore,
  supabaseJwt,
  supabaseStorage,
} from 'hollerkit-server'

const store = postgresStore({
  url: process.env.DATABASE_URL!,
})

const storage = supabaseStorage({
  url: process.env.SUPABASE_URL!,
  serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY!,
  bucket: 'hollerkit',
})

const sinks = [
  {
    name: 'webhook',
    async deliver(detail) {
      await fetch(process.env.WEBHOOK_URL!, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(detail),
      })
    },
  },
]

export const handler = createHollerKitServer({
  store,
  storage,
  sinks,
  authenticate: [
    supabaseJwt({
      jwksUrl: `${process.env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`,
      secret: process.env.SUPABASE_JWT_SECRET,
      store,
    }),
    apiKeys({ store }),
  ],
})

// Periodically flush pending outbox notifications using the same store and sinks:
// await flushOutbox({ store, storage, sinks })
```

The v1 server exposes the Web Fetch `(request: Request) => Promise<Response>` handler for all `/v1/*` endpoints (`POST /v1/uploads`, `POST /v1/feedback`, `GET /v1/feedback`, `GET /v1/feedback/{id}`, `PUT /v1/feedback/{id}/triage`, `PUT /v1/quests`, `GET /v1/quests`, `POST /v1/builds/{build}/manifest`, and `GET /v1/builds/{build}/pending`).

Media attachments (screenshots, audio, and video clips) are uploaded directly to object storage using short-lived presigned upload grants issued by `POST /v1/uploads` through a `HollerKitStorageAdapter` (`supabaseStorage` or `s3Storage`).

Notification sinks are optional outbox consumers triggered when a report or failed/unsure quest run is created. Schedule `flushOutbox({ store, storage, sinks })` to deliver pending outbox rows with exponential backoff.

## What You Need

- An iOS app that includes the `HollerKit` Swift package.
- A PostgreSQL database initialized with `server/migrations/001_hollerkit_v1.sql` (via `hollerkit migrations copy`).
- A deployed server endpoint using `createHollerKitServer` with `postgresStore` (or `memoryStore` for local testing).
- Tester authentication (`supabaseJwt`) and scoped `hk_...` API keys (`apiKeys`, minted with `hollerkit keys create`).
- Attachment storage using `supabaseStorage` or `s3Storage` (S3, Cloudflare R2, Backblaze B2, MinIO).

## Development

```sh
cd server
npm ci
npm run typecheck
npm test
```

To run the iOS package tests:

```sh
cd ios
DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')"
test -n "${DEVICE_ID}"
xcodebuild test \
  -scheme HollerKit \
  -destination "id=${DEVICE_ID}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

To build the demo app:

```sh
xcodebuild \
  -project examples/ios-demo/HollerKitDemo.xcodeproj \
  -scheme HollerKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

The demo app lives in `examples/ios-demo` and uses the local HollerKit Swift package.

## Protocol

See [openapi.yaml](./openapi.yaml) for the machine-readable HTTP contract and [PROTOCOL.md](./PROTOCOL.md) for signing, replay, and operational notes.

## Privacy

See [PRIVACY.md](./PRIVACY.md) for privacy notes around screenshots, audio, identifiers, and storage.
