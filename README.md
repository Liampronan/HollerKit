# HollerKit

[![CI](https://github.com/Liampronan/HollerKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Liampronan/HollerKit/actions/workflows/ci.yml)

<p align="center">
  <img src="./assets/hollerkit-banner.png" alt="HollerKit" width="200">
</p>

HollerKit is a simple user feedback SDK to let you easily collect screenshot-based feedback from users in your iOS app. 

It is a combination of:

- An iOS Swift Package for collecting reports, screenshots, breadcrumbs, metadata, and optional audio notes.
- A small self-hosted server handler that validates reports, uploads attachments, and creates GitHub issues.

Bonus: try optional audio-only bug reports, which transcribe a user's voice note into text for easier capture.

## Status

HollerKit is currently at **v0.5**. The server pipeline is usable, and the iOS package can present a report sheet, attach screenshots, annotate images, transcribe short voice notes when Speech is available, collect metadata and breadcrumbs, and submit reports.

The repo is organized as:

- `ios/`: Swift Package for capture UI, metadata, breadcrumbs, and multipart upload.
- `server/`: npm package for validating signed multipart reports, uploading assets, and creating issues.
- `examples/`: deployment examples for Supabase and Node.

## Demo UI

<p>
  <img src="./examples/ios-demo/Screenshots/hollerkit-report-sheet.png" alt="HollerKit report sheet with attached screenshots" width="260">
  <img src="./examples/ios-demo/Screenshots/hollerkit-annotation-editor.jpg" alt="HollerKit annotation editor with redaction tools" width="260">
</p>

## iOS Quickstart

Add the local Swift package from `ios/` while developing.

In Xcode:

1. Open your app project.
2. Choose **File > Add Package Dependencies**.
3. Choose **Add Local...** and select `HollerKit/ios`.
4. Add `HollerKit` to your app target.

Configure HollerKit when your app starts:

```swift
import HollerKit

HollerKit.configure(
    endpoint: URL(string: "https://example.com/bug-report")!,
    appSecret: "shared-with-server",
    invocation: [.shake, .screenshot],
    inputMode: .textAndAudio,
    userID: { Auth.currentUserId },
    metadata: { ["experiment": Flags.activeExperiment] },
    captureBreadcrumbs: true
)
```

For teams that only want HollerKit in debug, internal, or TestFlight-style builds, gate both configuration and presentation behind a compilation condition:

```swift
#if DEBUG || INTERNAL
import HollerKit
#endif

@main
struct MyApp: App {
    init() {
        #if DEBUG || INTERNAL
        HollerKit.configure(
            endpoint: URL(string: "https://example.com/bug-report")!,
            appSecret: "shared-with-server",
            invocation: [.shake, .screenshot],
            inputMode: .textAndAudio
        )
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG || INTERNAL
            RootView()
                .hollerKitPresenter()
            #else
            RootView()
            #endif
        }
    }
}
```

Add `INTERNAL` as a Swift active compilation condition for any non-release scheme that should include HollerKit.

If HollerKit is only enabled in `DEBUG` or `INTERNAL` builds, you can keep the microphone and speech-recognition usage strings in those non-release app targets only. Release targets that do not link or present HollerKit do not need to request those permissions.

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
  createBugReportHandler,
  githubIssues,
  supabaseStorage,
  dispatchers,
} from 'hollerkit-server'

export const handler = createBugReportHandler({
  appSecret: process.env.HOLLERKIT_APP_SECRET!,
  issue: githubIssues({
    token: process.env.GITHUB_TOKEN!,
    repo: 'owner/repo',
    labels: ['user-report', 'needs-triage'],
  }),

  // Required for screenshots and annotated images.
  // Audio reports are transcript-only by default, so raw audio upload is not required.
  // Text-only reports can omit storage.
  storage: supabaseStorage({
    url: process.env.SUPABASE_URL!,
    serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY!,
    bucket: 'bug-report-assets',
    signedUrlExpiresInSeconds: 60 * 60 * 24 * 7,
  }),

  // Optional. This example comments on every created issue.
  // Change the template if you want to tag Codex or another agent/bot.
  dispatch: {
    when: 'always',
    handler: dispatchers.comment({
      template: (report) => `@your-bot-here please investigate this report: ${report.id}`,
    }),
  },
})
```

The server expects signed `multipart/form-data` requests. GitHub Issues is the default issue destination.

Screenshots and annotated images are uploaded through a `StorageAdapter` before the GitHub issue is created. Supabase Storage is the easiest starting point if you already use Supabase; S3-compatible storage such as S3, R2, or Backblaze is a good production default. Text-only reports and transcript-only audio reports can run without storage.

To use Supabase Storage, create a bucket such as `bug-report-assets` and keep the service role key on the server only. Private buckets need either `signedUrlExpiresInSeconds` for time-limited links or a `publicUrl(path)` callback that points at your own authenticated asset proxy.

Raw audio upload is intentionally opt-in at the protocol level. The default iOS sheet is transcript-first and sends text, not an audio file.

Dispatchers are optional post-issue actions. Use them when you want HollerKit to comment, label, assign, or call a webhook after an issue is created.

## What You Need

- An iOS app that includes the `HollerKit` Swift package.
- A deployed server endpoint using `createBugReportHandler`.
- A shared HollerKit app secret on the client and server.
- A GitHub token with permission to create issues in your target repo.
- Attachment storage for screenshots and annotated images, using Supabase Storage or any S3-compatible provider.

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
swift test
```

To build the demo app:

```sh
xcodebuild \
  -project examples/ios-demo/HollerKitDemo.xcodeproj \
  -scheme HollerKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

The demo app lives in `examples/ios-demo` and uses the local HollerKit Swift package.

## Protocol

See [PROTOCOL.md](./PROTOCOL.md) for the wire format and limits.

## Privacy

See [PRIVACY.md](./PRIVACY.md) for privacy notes around screenshots, audio, identifiers, and storage.
