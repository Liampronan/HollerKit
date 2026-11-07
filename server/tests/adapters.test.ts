import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import {
  apiKeys,
  createHollerKitServer,
  defaultV1Limits,
  fakeStorage,
  flushOutbox,
  generateApiKey,
  getApiKeyPrefix,
  hashApiKey,
  memoryStore,
  s3Storage,
  supabaseJwt,
  supabaseStorage,
  type FeedbackDetail,
  type HollerKitSink,
} from '../dist/index.js'

function base64UrlEncode(bytes: Uint8Array | string): string {
  const buf = typeof bytes === 'string' ? Buffer.from(bytes, 'utf8') : Buffer.from(bytes)
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

async function signJwtWithHmac(
  payload: Record<string, unknown>,
  secret: string,
): Promise<string> {
  const headerB64 = base64UrlEncode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const payloadB64 = base64UrlEncode(JSON.stringify(payload))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)
  const secretBytes = new TextEncoder().encode(secret)
  const key = await crypto.subtle.importKey(
    'raw',
    secretBytes.buffer.slice(secretBytes.byteOffset, secretBytes.byteOffset + secretBytes.byteLength) as ArrayBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const sig = await crypto.subtle.sign(
    'HMAC',
    key,
    signingInput.buffer.slice(signingInput.byteOffset, signingInput.byteOffset + signingInput.byteLength) as ArrayBuffer,
  )
  return `${headerB64}.${payloadB64}.${base64UrlEncode(new Uint8Array(sig))}`
}

async function signJwtWithEs256(
  payload: Record<string, unknown>,
  privateKey: CryptoKey,
  kid: string,
): Promise<string> {
  const headerB64 = base64UrlEncode(JSON.stringify({ alg: 'ES256', typ: 'JWT', kid }))
  const payloadB64 = base64UrlEncode(JSON.stringify(payload))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)
  const sig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    signingInput.buffer.slice(signingInput.byteOffset, signingInput.byteOffset + signingInput.byteLength) as ArrayBuffer,
  )
  return `${headerB64}.${payloadB64}.${base64UrlEncode(new Uint8Array(sig))}`
}

test('defaultV1Limits matches Stage 2 spec constants', () => {
  assert.equal(defaultV1Limits.maxJsonBytes, 262_144)
  assert.equal(defaultV1Limits.maxTextChars, 20_000)
  assert.equal(defaultV1Limits.maxImages, 12)
  assert.equal(defaultV1Limits.maxImageBytes, 10_485_760)
  assert.equal(defaultV1Limits.maxMarks, 20)
  assert.equal(defaultV1Limits.maxVideoBytes, undefined)
})

test('supabaseStorage presignUpload and signReadUrl hit expected endpoints and return signed URLs', async () => {
  const calls: Array<{ url: string; method: string; headers: Record<string, string>; body: string | null }> = []
  const fixedNow = new Date('2026-11-07T08:00:00.000Z')

  const storage = supabaseStorage({
    url: 'https://project.supabase.co/',
    serviceRoleKey: 'service-role-secret',
    bucket: 'hollerkit-media',
    now: () => fixedNow,
    fetchImpl: async (input, init) => {
      const url = String(input)
      const headersObj: Record<string, string> = {}
      new Headers(init?.headers).forEach((val, key) => {
        headersObj[key.toLowerCase()] = val
      })
      calls.push({
        url,
        method: init?.method ?? 'GET',
        headers: headersObj,
        body: init?.body ? String(init.body) : null,
      })

      if (url.includes('/object/upload/sign/')) {
        return Response.json({
          url: '/object/upload/sign/hollerkit-media/fb-1/img.png?token=upload-tok',
        })
      }

      return Response.json({
        signedURL: '/object/sign/hollerkit-media/fb-1/img.png?token=read-tok',
      })
    },
  })

  const upload = await storage.presignUpload({
    key: 'fb-1/img.png',
    mimeType: 'image/png',
    size: 2048,
  })
  assert.equal(
    upload.url,
    'https://project.supabase.co/storage/v1/object/upload/sign/hollerkit-media/fb-1/img.png?token=upload-tok',
  )
  assert.equal(upload.expiresAt, new Date(fixedNow.getTime() + 600 * 1000).toISOString())
  assert.equal(calls[0]!.method, 'POST')
  assert.equal(
    calls[0]!.url,
    'https://project.supabase.co/storage/v1/object/upload/sign/hollerkit-media/fb-1/img.png',
  )
  assert.equal(calls[0]!.headers['authorization'], 'Bearer service-role-secret')
  assert.equal(calls[0]!.headers['x-upsert'], 'false')

  const read = await storage.signReadUrl({
    key: 'fb-1/img.png',
  })
  assert.equal(
    read.url,
    'https://project.supabase.co/storage/v1/object/sign/hollerkit-media/fb-1/img.png?token=read-tok',
  )
  assert.equal(read.expiresAt, new Date(fixedNow.getTime() + 3600 * 1000).toISOString())
  assert.equal(calls[1]!.method, 'POST')
  assert.deepEqual(JSON.parse(calls[1]!.body!), { expiresIn: 3600 })
})

test('s3Storage presignUpload and signReadUrl generate pure Web Crypto AWS SigV4 presigned URLs', async () => {
  const fixedNow = new Date('2026-11-07T08:00:00.000Z')
  const storage = s3Storage({
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    bucket: 'hollerkit-bucket',
    region: 'us-east-1',
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    forcePathStyle: true,
    now: () => fixedNow,
  })

  const upload = await storage.presignUpload({
    key: 'fb-123/shot.png',
    mimeType: 'image/png',
    size: 4096,
  })
  const uploadUrl = new URL(upload.url)
  assert.equal(uploadUrl.origin, 'https://s3.us-east-1.amazonaws.com')
  assert.equal(uploadUrl.pathname, '/hollerkit-bucket/fb-123/shot.png')
  assert.equal(uploadUrl.searchParams.get('X-Amz-Algorithm'), 'AWS4-HMAC-SHA256')
  assert.equal(
    uploadUrl.searchParams.get('X-Amz-Credential'),
    'AKIAIOSFODNN7EXAMPLE/20261107/us-east-1/s3/aws4_request',
  )
  assert.equal(uploadUrl.searchParams.get('X-Amz-Date'), '20261107T080000Z')
  assert.equal(uploadUrl.searchParams.get('X-Amz-Expires'), '600')
  assert.equal(uploadUrl.searchParams.get('X-Amz-SignedHeaders'), 'host')
  assert.match(uploadUrl.searchParams.get('X-Amz-Signature') ?? '', /^[0-9a-f]{64}$/)
  assert.equal(upload.expiresAt, new Date(fixedNow.getTime() + 600 * 1000).toISOString())

  const read = await storage.signReadUrl({
    key: 'fb-123/shot.png',
  })
  const readUrl = new URL(read.url)
  assert.equal(readUrl.searchParams.get('X-Amz-Expires'), '3600')
  assert.notEqual(
    readUrl.searchParams.get('X-Amz-Signature'),
    uploadUrl.searchParams.get('X-Amz-Signature'),
    'GET and PUT signatures must differ',
  )

  const vhostStorage = s3Storage({
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    bucket: 'hollerkit-bucket',
    region: 'us-east-1',
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    forcePathStyle: false,
    now: () => fixedNow,
  })
  const vhostRead = await vhostStorage.signReadUrl({ key: 'fb-123/shot.png' })
  const vhostUrl = new URL(vhostRead.url)
  assert.equal(vhostUrl.host, 'hollerkit-bucket.s3.us-east-1.amazonaws.com')
  assert.equal(vhostUrl.pathname, '/fb-123/shot.png')
})

test('supabaseJwt verifies ES256 JWKS (with caching) and HS256 fallback, and apiKeys authenticates hk_ keys', async () => {
  const store = memoryStore()
  await store.upsertTester({
    userId: 'user-es256',
    email: 'es256@example.com',
    active: true,
  })
  await store.upsertTester({
    userId: 'user-hs256',
    email: 'hs256@example.com',
    active: true,
  })
  await store.upsertTester({
    userId: 'user-inactive',
    email: 'inactive@example.com',
    active: false,
  })

  const { publicKey, privateKey } = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  )
  const publicJwk = await crypto.subtle.exportKey('jwk', publicKey)
  let jwksFetchCount = 0

  const fixedNow = new Date('2026-11-07T08:00:00.000Z')
  const nowSec = Math.floor(fixedNow.getTime() / 1000)

  const jwtAuth = supabaseJwt({
    jwksUrl: 'https://project.supabase.co/auth/v1/.well-known/jwks.json',
    secret: 'super-secret-jwt-hmac-key-for-supabase',
    store,
    now: () => fixedNow,
    fetchImpl: async () => {
      jwksFetchCount += 1
      return Response.json({
        keys: [{ ...publicJwk, kid: 'key-1', alg: 'ES256', use: 'sig' }],
      })
    },
  })

  // 1. Valid ES256 JWT
  const esToken = await signJwtWithEs256(
    { sub: 'user-es256', email: 'es256@example.com', exp: nowSec + 3600 },
    privateKey,
    'key-1',
  )
  const p1 = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${esToken}` },
    }),
  )
  assert.ok(p1)
  assert.equal(p1.subject, 'user-es256')
  assert.deepEqual(p1.scopes, ['tester'])
  assert.equal(jwksFetchCount, 1)

  // Second verification uses cached JWKS without fetching again
  const p2 = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${esToken}` },
    }),
  )
  assert.ok(p2)
  assert.equal(jwksFetchCount, 1)

  // 2. Valid HS256 JWT fallback
  const hsToken = await signJwtWithHmac(
    { sub: 'user-hs256', email: 'hs256@example.com', exp: nowSec + 3600 },
    'super-secret-jwt-hmac-key-for-supabase',
  )
  const pHs = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${hsToken}` },
    }),
  )
  assert.ok(pHs)
  assert.equal(pHs.subject, 'user-hs256')
  assert.deepEqual(pHs.scopes, ['tester'])

  // 3. Expired JWT returns null
  const expiredToken = await signJwtWithHmac(
    { sub: 'user-hs256', exp: nowSec - 10 },
    'super-secret-jwt-hmac-key-for-supabase',
  )
  const pExpired = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${expiredToken}` },
    }),
  )
  assert.equal(pExpired, null)

  // 4. Inactive tester returns null
  const inactiveToken = await signJwtWithHmac(
    { sub: 'user-inactive', exp: nowSec + 3600 },
    'super-secret-jwt-hmac-key-for-supabase',
  )
  const pInactive = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${inactiveToken}` },
    }),
  )
  assert.equal(pInactive, null)

  // 5. hk_ token returns null from supabaseJwt so apiKeys can handle it
  const rawApiKey = generateApiKey('agent')
  assert.ok(rawApiKey.startsWith('hk_agent_'))
  await store.createApiKey({
    keyHash: hashApiKey(rawApiKey),
    keyPrefix: getApiKeyPrefix(rawApiKey),
    label: 'my-agent',
    scopes: ['agent:read', 'agent:triage'],
  })

  const hkReq = new Request('http://hollerkit.local/v1/feedback', {
    headers: { authorization: `Bearer ${rawApiKey}` },
  })
  assert.equal(await jwtAuth(hkReq), null)

  const apiKeyAuth = apiKeys({ store })
  const pKey = await apiKeyAuth(hkReq)
  assert.ok(pKey)
  assert.equal(pKey.subject, getApiKeyPrefix(rawApiKey))
  assert.deepEqual(pKey.scopes, ['agent:read', 'agent:triage'])

  // Revoking key makes apiKeys return null
  await store.revokeApiKey('my-agent')
  assert.equal(await apiKeyAuth(hkReq), null)
})

test('outbox enqueues matching sinks on POST /v1/feedback, delivers with links, and backs off on failure', async () => {
  const store = memoryStore()
  const storage = fakeStorage()
  let currentNow = new Date('2026-11-07T09:00:00.000Z')

  await store.upsertTester({ userId: 'tester-1', active: true })
  const agentRawKey = generateApiKey('agent')
  await store.createApiKey({
    keyHash: hashApiKey(agentRawKey),
    keyPrefix: getApiKeyPrefix(agentRawKey),
    scopes: ['quests:write', 'agent:read', 'agent:triage'],
  })

  const deliveredPayloads: FeedbackDetail[] = []
  let shouldFailWebhook = true

  const githubSink: HollerKitSink = {
    name: 'github',
    async deliver(detail) {
      deliveredPayloads.push(detail)
      return { link: `https://github.com/acme/app/issues/${detail.feedback.id.slice(0, 6)}` }
    },
  }

  const webhookSink: HollerKitSink = {
    name: 'webhook',
    async deliver() {
      if (shouldFailWebhook) {
        throw new Error('Webhook 503 Service Unavailable')
      }
      return { link: 'https://hooks.acme.test/delivered/1' }
    },
  }

  const handler = createHollerKitServer({
    store,
    storage,
    now: () => currentNow,
    sinks: [githubSink, webhookSink],
    authenticate: [
      supabaseJwt({ secret: 'test-secret', store, now: () => currentNow }),
      apiKeys({ store }),
    ],
  })

  const testerJwt = await signJwtWithHmac(
    { sub: 'tester-1', exp: Math.floor(currentNow.getTime() / 1000) + 3600 },
    'test-secret',
  )

  // Sync a quest first
  await handler(
    new Request('http://hollerkit.local/v1/quests', {
      method: 'PUT',
      headers: {
        authorization: `Bearer ${agentRawKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'checkout-pay',
            title: 'Complete Apple Pay checkout',
            area: 'checkout',
            steps: ['Tap Buy', 'Confirm sheet'],
            expect: ['Order confirmation appears'],
          },
        ],
      }),
    }),
  )

  // 1. Passing quest run does NOT enqueue sinks
  const passId = randomUUID()
  const passRes = await handler(
    new Request('http://hollerkit.local/v1/feedback', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${testerJwt}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        id: passId,
        kind: 'quest_run',
        questId: 'checkout-pay',
        result: 'pass',
        build: '200',
      }),
    }),
  )
  assert.equal(passRes.status, 201)
  const pendingAfterPass = await store.claimPendingOutbox({ now: currentNow })
  assert.equal(pendingAfterPass.length, 0)

  // 2. Report feedback enqueues both sinks
  const reportId = randomUUID()
  const reportRes = await handler(
    new Request('http://hollerkit.local/v1/feedback', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${testerJwt}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        id: reportId,
        kind: 'report',
        build: '200',
        comment: 'Crash on checkout button',
      }),
    }),
  )
  assert.equal(reportRes.status, 201)

  const pendingBeforeFlush = await store.claimPendingOutbox({ now: currentNow })
  assert.equal(pendingBeforeFlush.length, 2)

  // Flush #1: github succeeds (adds link to feedback.links), webhook fails (attempts=1, backoff +30s)
  const flush1 = await flushOutbox({
    store,
    storage,
    sinks: [githubSink, webhookSink],
    now: () => currentNow,
    baseDelayMs: 30_000,
  })
  assert.equal(flush1.claimed, 2)
  assert.equal(flush1.delivered.length, 1)
  assert.equal(flush1.delivered[0]!.sink, 'github')
  assert.ok(flush1.delivered[0]!.link?.startsWith('https://github.com/acme/app/issues/'))
  assert.equal(flush1.failed.length, 1)
  assert.equal(flush1.failed[0]!.sink, 'webhook')
  assert.equal(flush1.failed[0]!.attempts, 1)
  assert.equal(flush1.failed[0]!.lastError, 'Webhook 503 Service Unavailable')
  assert.equal(
    flush1.failed[0]!.nextAttemptAt,
    new Date(currentNow.getTime() + 30_000).toISOString(),
  )

  // Immediate flush before backoff expires claims 0 rows
  const flushImmediate = await flushOutbox({
    store,
    storage,
    sinks: [githubSink, webhookSink],
    now: () => currentNow,
  })
  assert.equal(flushImmediate.claimed, 0)

  // Advance clock by 31 seconds and let webhook succeed
  currentNow = new Date(currentNow.getTime() + 31_000)
  shouldFailWebhook = false

  const flush2 = await flushOutbox({
    store,
    storage,
    sinks: [githubSink, webhookSink],
    now: () => currentNow,
  })
  assert.equal(flush2.claimed, 1)
  assert.equal(flush2.delivered.length, 1)
  assert.equal(flush2.delivered[0]!.sink, 'webhook')

  // Verify both sink links are now recorded on the feedback item
  const detail = await store.getFeedbackById(reportId)
  assert.ok(detail)
  assert.equal(detail.feedback.links.length, 2)
  assert.ok(detail.feedback.links.some((l) => l.includes('github.com/acme/app/issues/')))
  assert.ok(detail.feedback.links.includes('https://hooks.acme.test/delivered/1'))
})
