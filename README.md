# HollerKit

<p align="center">
  <img src="./assets/hollerkit-banner.png" alt="HollerKit" width="640">
</p>

HollerKit is an open-source bug reporting toolkit for iOS apps. It pairs a Swift Package with a small self-hosted server handler so in-app reports can become GitHub issues with comments, screenshots, annotations, redaction, optional audio notes, and optional AI agent dispatch.

This repository is intentionally single-repo:

- `ios/`: Swift Package for capture UI, metadata, breadcrumbs, and multipart upload.
- `server/`: npm package for validating signed multipart reports, uploading assets, and creating issues.
- `examples/`: thin deployment examples for Supabase and Node.

## Current Status

This is the initial v0.1 scaffold. The server package has the first functional slice:

- HMAC verification over `body || timestamp`.
- Multipart normalization into `NormalizedReport`.
- Protocol limits for comments, transcripts, metadata, breadcrumbs, images, and audio.
- GitHub Issues adapter.
- S3-compatible, Supabase Storage, and GitHub Release storage adapters.
- Optional classifier and dispatch hooks.
- Issue body rendering with transcript provenance and audio/image links.

The iOS package currently exposes the configuration shape, breadcrumb store, metadata collection, Speech framework transcription helper, and multipart upload client foundation.

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

## Development

```sh
cd server
npm test
```

## Protocol

See [PROTOCOL.md](./PROTOCOL.md) for the wire format and limits.

## Privacy

See [PRIVACY.md](./PRIVACY.md) for the v1 privacy requirements.
