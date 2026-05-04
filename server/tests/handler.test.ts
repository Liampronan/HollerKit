import assert from 'node:assert/strict'
import test from 'node:test'
import { createBugReportHandler, renderIssueBody } from '../src/index.ts'
import type { IssueAdapter, StorageAdapter } from '../src/index.ts'

const now = new Date('2026-05-03T20:00:00.000Z')
const secret = 'test-secret'

test('creates a GitHub issue for a signed text-only report', async () => {
  const issueBodies: string[] = []
  const issue: IssueAdapter = {
    async createIssue(input) {
      issueBodies.push(input.body)
      return { url: 'https://github.com/acme/app/issues/123', number: 123 }
    },
  }

  const handler = createBugReportHandler({
    appSecret: secret,
    issue,
    now: () => now,
    idGenerator: () => 'report-1',
  })

  const response = await handler(await signedRequest({
    comment: 'The settings screen flashes white.',
    inputMode: 'text-only',
    metadata: JSON.stringify({ appVersion: '1.0', osVersion: '26.0' }),
  }))

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    ok: true,
    issueUrl: 'https://github.com/acme/app/issues/123',
    reportId: 'report-1',
  })
  assert.match(issueBodies[0], /The settings screen flashes white\./)
  assert.match(issueBodies[0], /appVersion/)
})

test('uploads images before issue creation', async () => {
  const uploadedPaths: string[] = []
  const storage: StorageAdapter = {
    async upload(reportId, files) {
      uploadedPaths.push(`${reportId}/${files[0].filename}`)
      return files.map((file) => ({
        kind: file.kind,
        filename: file.filename,
        mimeType: file.mimeType,
        size: file.size,
        url: `https://assets.example/${reportId}/${file.filename}`,
      }))
    },
  }
  const issue: IssueAdapter = {
    async createIssue(input) {
      assert.match(input.body, /https:\/\/assets\.example\/report-2\/screen\.png/)
      return { url: 'https://github.com/acme/app/issues/124', number: 124 }
    },
  }

  const handler = createBugReportHandler({
    appSecret: secret,
    issue,
    storage,
    now: () => now,
    idGenerator: () => 'report-2',
  })

  const form = {
    comment: 'Image included',
    inputMode: 'text-and-audio',
    metadata: '{}',
    image: new File([new Uint8Array([1, 2, 3])], 'screen.png', { type: 'image/png' }),
  }

  const response = await handler(await signedRequest(form))

  assert.equal(response.status, 200)
  assert.deepEqual(uploadedPaths, ['report-2/screen.png'])
})

test('rejects invalid signatures', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    now: () => now,
  })

  const request = await signedRequest({
    comment: 'Nope',
    inputMode: 'text-only',
    metadata: '{}',
  })
  const badRequest = new Request(request.url, {
    method: request.method,
    headers: {
      ...Object.fromEntries(request.headers.entries()),
      'x-hollerkit-signature': '00',
    },
    body: await request.arrayBuffer(),
  })

  const response = await handler(badRequest)

  assert.equal(response.status, 401)
  assert.equal((await response.json()).error.code, 'invalid_signature')
})

test('rejects stale timestamps even with a valid signature', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    now: () => now,
  })

  const response = await handler(await signedRequest({
    comment: 'Old request',
    inputMode: 'text-only',
    metadata: '{}',
  }, { timestamp: Math.floor(now.getTime() / 1000 - 600).toString() }))

  assert.equal(response.status, 401)
  assert.equal((await response.json()).error.code, 'timestamp_out_of_range')
})

test('rejects oversized requests before reading the body', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    limits: { maxBodyBytes: 10 },
    now: () => now,
  })

  const request = await signedRequest({
    comment: 'This request is too large for the configured cap.',
    inputMode: 'text-only',
    metadata: '{}',
  })

  const response = await handler(request)

  assert.equal(response.status, 413)
  assert.equal((await response.json()).error.code, 'body_too_large')
})

test('rejects decimal content lengths', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    now: () => now,
  })

  const request = await signedRequest({
    comment: 'Fractional length',
    inputMode: 'text-only',
    metadata: '{}',
  })
  const headers = new Headers(request.headers)
  headers.set('content-length', '1.5')
  const fractionalLengthRequest = new Request(request.url, {
    method: request.method,
    headers,
    body: await request.arrayBuffer(),
  })

  const response = await handler(fractionalLengthRequest)

  assert.equal(response.status, 400)
  assert.equal((await response.json()).error.code, 'invalid_content_length')
})

test('enforces image count limits', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    storage: {
      async upload() {
        throw new Error('should not upload')
      },
    },
    limits: { maxImages: 1 },
    now: () => now,
  })

  const response = await handler(await signedRequest({
    comment: 'Too many images',
    inputMode: 'text-and-audio',
    metadata: '{}',
    image: [
      new File([new Uint8Array([1])], 'one.png', { type: 'image/png' }),
      new File([new Uint8Array([2])], 'two.png', { type: 'image/png' }),
    ],
  }))

  assert.equal(response.status, 413)
  assert.equal((await response.json()).error.code, 'too_many_images')
})

test('renders transcript provenance in issue body', () => {
  const body = renderIssueBody({
    report: {
      id: 'report-3',
      createdAt: now.toISOString(),
      inputMode: 'audio-only',
      transcript: {
        text: 'It crashes after I tap save.',
        locale: 'en-US',
        engine: 'apple-on-device',
        durationSeconds: 12,
      },
      metadata: {},
      breadcrumbs: [],
      files: { images: [] },
    },
    uploadedFiles: [],
  })

  assert.match(body, /apple-on-device/)
  assert.match(body, /It crashes after I tap save\./)
})

test('renders user comment and transcript inside fenced code blocks', () => {
  const body = renderIssueBody({
    report: {
      id: 'report-markdown',
      createdAt: now.toISOString(),
      inputMode: 'text-and-audio',
      comment: '@octocat <img src="https://attacker.example/track">',
      transcript: {
        text: '```nested fence```',
        locale: 'en-US',
        engine: 'manual',
      },
      metadata: {},
      breadcrumbs: [],
      files: { images: [] },
    },
    uploadedFiles: [],
  })

  assert.match(body, /## Comment\n\n```\n@octocat/)
  assert.match(body, /````\n```nested fence```\n````/)
})

test('creates transcript-only audio reports without storage', async () => {
  const issueBodies: string[] = []
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: {
      async createIssue(input) {
        issueBodies.push(input.body)
        return { url: 'https://github.com/acme/app/issues/125', number: 125 }
      },
    },
    now: () => now,
    idGenerator: () => 'report-4',
  })

  const response = await handler(await signedRequest({
    inputMode: 'audio-only',
    transcript: JSON.stringify({
      text: 'The profile screen freezes after upload.',
      locale: 'en-US',
      engine: 'apple-on-device',
      durationSeconds: 8,
    }),
    metadata: '{}',
  }))

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    ok: true,
    issueUrl: 'https://github.com/acme/app/issues/125',
    reportId: 'report-4',
  })
  assert.match(issueBodies[0], /The profile screen freezes after upload\./)
})

test('requires storage when image files are submitted', async () => {
  const handler = createBugReportHandler({
    appSecret: secret,
    issue: fakeIssue(),
    now: () => now,
  })

  const response = await handler(await signedRequest({
    comment: 'Screenshot attached',
    inputMode: 'text-and-audio',
    metadata: '{}',
    image: new File([new Uint8Array([1, 2, 3])], 'screen.png', { type: 'image/png' }),
  }))

  assert.equal(response.status, 500)
  assert.equal((await response.json()).error.code, 'missing_storage_adapter')
})

function fakeIssue(): IssueAdapter {
  return {
    async createIssue() {
      return { url: 'https://github.com/acme/app/issues/1', number: 1 }
    },
  }
}

async function signedRequest(
  fields: Record<string, string | File | File[]>,
  options: { timestamp?: string } = {},
): Promise<Request> {
  const form = new FormData()
  for (const [key, value] of Object.entries(fields)) {
    if (Array.isArray(value)) {
      for (const item of value) form.append(key, item)
    } else {
      form.append(key, value)
    }
  }

  const unsigned = new Request('https://example.com/bug-report', {
    method: 'POST',
    body: form,
  })
  const body = await unsigned.clone().arrayBuffer()
  const timestamp = options.timestamp ?? Math.floor(now.getTime() / 1000).toString()
  const signature = await hmacHex(secret, body, timestamp)
  const headers = new Headers(unsigned.headers)
  headers.set('content-length', String(body.byteLength))
  headers.set('x-hollerkit-timestamp', timestamp)
  headers.set('x-hollerkit-signature', signature)

  return new Request(unsigned.url, {
    method: 'POST',
    headers,
    body,
  })
}

async function hmacHex(secretValue: string, body: ArrayBuffer, timestamp: string): Promise<string> {
  const bodyBytes = new Uint8Array(body)
  const timestampBytes = new TextEncoder().encode(timestamp)
  const data = new Uint8Array(bodyBytes.length + timestampBytes.length)
  data.set(bodyBytes, 0)
  data.set(timestampBytes, bodyBytes.length)

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secretValue),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', key, data)
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, '0')).join('')
}
