# HollerKit

<p align="center">
  <img src="./assets/hollerkit-banner.png" alt="HollerKit" width="200">
</p>

HollerKit is an open-source bug reporting toolkit for iOS apps.

It is a combination of:

- An iOS Swift Package for collecting reports, screenshots, breadcrumbs, metadata, and optional audio notes.
- A small self-hosted server handler that validates reports, uploads attachments, and creates GitHub issues.

The goal is simple: add a report button to your app and turn useful in-app feedback into GitHub issues without adopting another SaaS dashboard.

Bonus: try optional audio-only bug reports, which transcribe a user's voice note into text for easier capture.

## Status

HollerKit is currently at **v0.5**. The server pipeline is usable, and the iOS package has the core configuration, payload, metadata, breadcrumb, transcription, and upload pieces in place.

The repo is organized as:

- `ios/`: Swift Package for capture UI, metadata, breadcrumbs, and multipart upload.
- `server/`: npm package for validating signed multipart reports, uploading assets, and creating issues.
- `examples/`: deployment examples for Supabase and Node.

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

Present the report UI from your own button or menu:

```swift
struct SettingsView: View {
    @State private var isReportingBug = false

    var body: some View {
        Button("Report a Bug") {
            isReportingBug = true
        }
        .sheet(isPresented: $isReportingBug) {
            HollerKit.presentationView()
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

## Server Quickstart

```ts
import {
  createBugReportHandler,
  githubIssues,
  s3Storage,
  dispatchers,
} from 'hollerkit-server'

export const handler = createBugReportHandler({
  appSecret: process.env.HOLLERKIT_APP_SECRET!,
  issue: githubIssues({
    token: process.env.GITHUB_TOKEN!,
    repo: 'owner/repo',
    labels: ['user-report', 'needs-triage'],
  }),
  storage: s3Storage({
    endpoint: process.env.S3_ENDPOINT!,
    bucket: process.env.S3_BUCKET!,
    accessKeyId: process.env.S3_ACCESS_KEY_ID!,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY!,
  }),
  dispatch: {
    when: 'always',
    handler: dispatchers.comment({
      template: (report) => `@codex please investigate this report: ${report.id}`,
    }),
  },
})
```

The server expects signed `multipart/form-data` requests. Attachments are uploaded through a storage adapter, and GitHub Issues is the default issue destination.

## What You Need

- An iOS app that includes the `HollerKit` Swift package.
- A deployed server endpoint using `createBugReportHandler`.
- A shared HollerKit app secret on the client and server.
- A GitHub token with permission to create issues in your target repo.
- Storage for screenshots and audio attachments, such as S3-compatible storage or Supabase Storage.

## Development

```sh
cd server
npm test
```

## Protocol

See [PROTOCOL.md](./PROTOCOL.md) for the wire format and limits.

## Privacy

See [PRIVACY.md](./PRIVACY.md) for privacy notes around screenshots, audio, identifiers, and storage.
