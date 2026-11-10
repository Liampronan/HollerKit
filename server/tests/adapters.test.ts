import assert from 'node:assert/strict'
import { createHmac, createHash, randomUUID } from 'node:crypto'
import test from 'node:test'
import {
  apiKeys,
  createGitHubWebhookHandler,
  createHollerKitServer,
  defaultV1Limits,
  extractFeedbackIdFromGitHubIssueBody,
  fakeStorage,
  flushOutbox,
  formatGitHubIssue,
  generateApiKey,
  getApiKeyPrefix,
  githubIssuesSink,
  hashApiKey,
  HollerKitError,
  memoryStore,
  s3Storage,
  SUPABASE_UPLOAD_URL_TTL_SECONDS,
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
  kid?: string,
): Promise<string> {
  const headerObj: Record<string, unknown> = { alg: 'ES256', typ: 'JWT' }
  if (kid !== undefined) {
    headerObj.kid = kid
  }
  const headerB64 = base64UrlEncode(JSON.stringify(headerObj))
  const payloadB64 = base64UrlEncode(JSON.stringify(payload))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)
  const sig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    signingInput.buffer.slice(signingInput.byteOffset, signingInput.byteOffset + signingInput.byteLength) as ArrayBuffer,
  )
  return `${headerB64}.${payloadB64}.${base64UrlEncode(new Uint8Array(sig))}`
}

function nodeSigV4Expected(params: {
  method: 'PUT' | 'GET'
  host: string
  canonicalUri: string
  canonicalQueryString: string
  headers: Record<string, string>
  accessKeyId: string
  secretAccessKey: string
  region: string
  amzDate: string
}): string {
  const dateStamp = params.amzDate.slice(0, 8)
  const scope = `${dateStamp}/${params.region}/s3/aws4_request`
  const sortedHeaders = Object.entries(params.headers).sort(([a], [b]) => a.localeCompare(b))
  const signedHeaders = sortedHeaders.map(([k]) => k).join(';')
  const canonicalHeaders = sortedHeaders.map(([k, v]) => `${k}:${v}\n`).join('')
  const canonicalRequest = [
    params.method,
    params.canonicalUri,
    params.canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    'UNSIGNED-PAYLOAD',
  ].join('\n')
  const hashedCanonical = createHash('sha256').update(canonicalRequest, 'utf8').digest('hex')
  const stringToSign = ['AWS4-HMAC-SHA256', params.amzDate, scope, hashedCanonical].join('\n')
  const kDate = createHmac('sha256', `AWS4${params.secretAccessKey}`).update(dateStamp, 'utf8').digest()
  const kRegion = createHmac('sha256', kDate).update(params.region, 'utf8').digest()
  const kService = createHmac('sha256', kRegion).update('s3', 'utf8').digest()
  const kSigning = createHmac('sha256', kService).update('aws4_request', 'utf8').digest()
  return createHmac('sha256', kSigning).update(stringToSign, 'utf8').digest('hex')
}

test('defaultV1Limits matches Stage 2 spec constants and upload route enforces maxVideoBytes', async () => {
  assert.equal(defaultV1Limits.maxJsonBytes, 262_144)
  assert.equal(defaultV1Limits.maxTextChars, 20_000)
  assert.equal(defaultV1Limits.maxImages, 12)
  assert.equal(defaultV1Limits.maxImageBytes, 10_485_760)
  assert.equal(defaultV1Limits.maxVideoBytes, 52_428_800)
  assert.equal(defaultV1Limits.maxMarks, 20)

  const store = memoryStore()
  await store.upsertTester({ userId: 'tester-video', active: true })
  const now = new Date('2026-11-07T08:00:00.000Z')
  const nowSec = Math.floor(now.getTime() / 1000)
  const token = await signJwtWithHmac(
    { sub: 'tester-video', aud: 'authenticated', exp: nowSec + 3600 },
    'video-secret',
  )
  const handler = createHollerKitServer({
    store,
    storage: fakeStorage({ now: () => now }),
    authenticate: supabaseJwt({ secret: 'video-secret', store, now: () => now }),
  })

  const oversizedVideo = await handler(
    new Request('http://hollerkit.local/v1/uploads', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        feedbackId: randomUUID(),
        kind: 'video',
        mimeType: 'video/mp4',
        size: defaultV1Limits.maxVideoBytes + 1,
      }),
    }),
  )
  assert.equal(oversizedVideo.status, 413)
  const body = (await oversizedVideo.json()) as { error: { code: string } }
  assert.equal(body.error.code, 'video_too_large')
})

test('supabaseStorage presignUpload and signReadUrl hit expected endpoints, enforce lifetime, and propagate HollerKitError', async () => {
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
  assert.equal(
    upload.expiresAt,
    new Date(fixedNow.getTime() + SUPABASE_UPLOAD_URL_TTL_SECONDS * 1000).toISOString(),
  )
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

  // Dot-segment traversal in storage key is rejected
  await assert.rejects(
    () =>
      storage.presignUpload({
        key: 'fb-1/../secret.png',
        mimeType: 'image/png',
        size: 100,
      }),
    (err: unknown) => err instanceof HollerKitError && err.status === 400 && err.code === 'invalid_storage_key',
  )

  // Upstream failure throws HollerKitError(502, 'storage_error')
  const failingStorage = supabaseStorage({
    url: 'https://project.supabase.co',
    serviceRoleKey: 'service-role-secret',
    bucket: 'hollerkit-media',
    fetchImpl: async () => new Response('Bad Gateway', { status: 502 }),
  })
  await assert.rejects(
    () =>
      failingStorage.presignUpload({
        key: 'fb-1/img.png',
        mimeType: 'image/png',
        size: 100,
      }),
    (err: unknown) => err instanceof HollerKitError && err.status === 502 && err.code === 'storage_error',
  )
})

test('s3Storage presignUpload and signReadUrl generate independently verified AWS SigV4 signatures and reject dot segments', async () => {
  const fixedNow = new Date('2026-11-07T08:00:00.000Z')
  const accessKeyId = 'AKIAIOSFODNN7EXAMPLE'
  const secretAccessKey = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
  const region = 'us-east-1'

  const storage = s3Storage({
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    bucket: 'hollerkit-bucket',
    region,
    accessKeyId,
    secretAccessKey,
    forcePathStyle: true,
    now: () => fixedNow,
  })

  const specialKey = 'fb-123/shot (1)!.png'
  const upload = await storage.presignUpload({
    key: specialKey,
    mimeType: 'image/png',
    size: 4096,
  })
  const uploadUrl = new URL(upload.url)
  assert.equal(uploadUrl.origin, 'https://s3.us-east-1.amazonaws.com')
  assert.equal(uploadUrl.pathname, '/hollerkit-bucket/fb-123/shot%20%281%29%21.png')
  assert.equal(uploadUrl.searchParams.get('X-Amz-Algorithm'), 'AWS4-HMAC-SHA256')
  assert.equal(
    uploadUrl.searchParams.get('X-Amz-Credential'),
    'AKIAIOSFODNN7EXAMPLE/20261107/us-east-1/s3/aws4_request',
  )
  assert.equal(uploadUrl.searchParams.get('X-Amz-Date'), '20261107T080000Z')
  assert.equal(uploadUrl.searchParams.get('X-Amz-Expires'), '600')
  assert.equal(uploadUrl.searchParams.get('X-Amz-SignedHeaders'), 'content-length;content-type;host')

  const expectedPutSig = nodeSigV4Expected({
    method: 'PUT',
    host: 's3.us-east-1.amazonaws.com',
    canonicalUri: '/hollerkit-bucket/fb-123/shot%20%281%29%21.png',
    canonicalQueryString:
      'X-Amz-Algorithm=AWS4-HMAC-SHA256' +
      '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261107%2Fus-east-1%2Fs3%2Faws4_request' +
      '&X-Amz-Date=20261107T080000Z' +
      '&X-Amz-Expires=600' +
      '&X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost',
    headers: {
      'content-length': '4096',
      'content-type': 'image/png',
      host: 's3.us-east-1.amazonaws.com',
    },
    accessKeyId,
    secretAccessKey,
    region,
    amzDate: '20261107T080000Z',
  })
  assert.equal(uploadUrl.searchParams.get('X-Amz-Signature'), expectedPutSig)
  assert.equal(upload.expiresAt, new Date(fixedNow.getTime() + 600 * 1000).toISOString())

  const read = await storage.signReadUrl({
    key: specialKey,
  })
  const readUrl = new URL(read.url)
  assert.equal(readUrl.searchParams.get('X-Amz-Expires'), '3600')
  assert.equal(readUrl.searchParams.get('X-Amz-SignedHeaders'), 'host')

  const expectedGetSig = nodeSigV4Expected({
    method: 'GET',
    host: 's3.us-east-1.amazonaws.com',
    canonicalUri: '/hollerkit-bucket/fb-123/shot%20%281%29%21.png',
    canonicalQueryString:
      'X-Amz-Algorithm=AWS4-HMAC-SHA256' +
      '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261107%2Fus-east-1%2Fs3%2Faws4_request' +
      '&X-Amz-Date=20261107T080000Z' +
      '&X-Amz-Expires=3600' +
      '&X-Amz-SignedHeaders=host',
    headers: {
      host: 's3.us-east-1.amazonaws.com',
    },
    accessKeyId,
    secretAccessKey,
    region,
    amzDate: '20261107T080000Z',
  })
  assert.equal(readUrl.searchParams.get('X-Amz-Signature'), expectedGetSig)
  assert.notEqual(expectedGetSig, expectedPutSig, 'GET and PUT signatures must differ')

  // Reject dot segments so URL normalization cannot alter signed key
  await assert.rejects(
    () =>
      storage.presignUpload({
        key: 'fb-123/../other/shot.png',
        mimeType: 'image/png',
        size: 1024,
      }),
    (err: unknown) => err instanceof HollerKitError && err.status === 400 && err.code === 'invalid_storage_key',
  )

  const vhostStorage = s3Storage({
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    bucket: 'hollerkit-bucket',
    region,
    accessKeyId,
    secretAccessKey,
    forcePathStyle: false,
    now: () => fixedNow,
  })
  const vhostRead = await vhostStorage.signReadUrl({ key: 'fb-123/shot.png' })
  const vhostUrl = new URL(vhostRead.url)
  assert.equal(vhostUrl.host, 'hollerkit-bucket.s3.us-east-1.amazonaws.com')
  assert.equal(vhostUrl.pathname, '/fb-123/shot.png')
})

test('supabaseJwt verifies ES256/HS256, enforces aud/iss/tester checks, rejects forged signatures, and apiKeys sets stable principalId', async () => {
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

  // Configuration without store or authorizeTester must throw
  assert.throws(
    () => supabaseJwt({ secret: 'some-secret' }),
    /supabaseJwt requires at least one of store or authorizeTester/,
  )

  const { publicKey, privateKey } = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  )
  const { privateKey: wrongPrivateKey } = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  )
  const publicJwk = await crypto.subtle.exportKey('jwk', publicKey)
  let jwksFetchCount = 0

  const fixedNow = new Date('2026-11-07T08:00:00.000Z')
  const nowSec = Math.floor(fixedNow.getTime() / 1000)
  const issuer = 'https://project.supabase.co/auth/v1'

  const jwtAuth = supabaseJwt({
    jwksUrl: `${issuer}/.well-known/jwks.json`,
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
    {
      sub: 'user-es256',
      email: 'es256@example.com',
      aud: 'authenticated',
      iss: issuer,
      exp: nowSec + 3600,
    },
    privateKey,
    'key-1',
  )
  const p1 = await jwtAuth(
    new Request('http://hollerkit.local/v1/uploads', {
      headers: { authorization: `Bearer ${esToken}` },
    }),
  )
  assert.ok(p1)
  assert.equal(p1.principalId, 'user-es256')
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

  // Forged ES256 JWT (active tester, valid claims, wrong private key) returns null
  const forgedEsToken = await signJwtWithEs256(
    {
      sub: 'user-es256',
      email: 'es256@example.com',
      aud: 'authenticated',
      iss: issuer,
      exp: nowSec + 3600,
    },
    wrongPrivateKey,
    'key-1',
  )
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${forgedEsToken}` },
      }),
    ),
    null,
  )

  // Unknown kid does not fall back to key-1 and throttles forced JWKS refreshes
  const unknownKidToken = await signJwtWithEs256(
    {
      sub: 'user-es256',
      aud: 'authenticated',
      iss: issuer,
      exp: nowSec + 3600,
    },
    privateKey,
    'unknown-kid-99',
  )
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${unknownKidToken}` },
      }),
    ),
    null,
  )
  assert.equal(jwksFetchCount, 2)
  // Immediate second unknown-kid request is throttled by cooldown
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${unknownKidToken}` },
      }),
    ),
    null,
  )
  assert.equal(jwksFetchCount, 2)

  // 2. Valid HS256 JWT fallback
  const hsToken = await signJwtWithHmac(
    {
      sub: 'user-hs256',
      email: 'hs256@example.com',
      aud: 'authenticated',
      iss: issuer,
      exp: nowSec + 3600,
    },
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

  // Forged HS256 JWT (wrong HMAC secret) returns null
  const forgedHsToken = await signJwtWithHmac(
    {
      sub: 'user-hs256',
      email: 'hs256@example.com',
      aud: 'authenticated',
      iss: issuer,
      exp: nowSec + 3600,
    },
    'wrong-hmac-secret',
  )
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${forgedHsToken}` },
      }),
    ),
    null,
  )

  // Mismatched audience returns null
  const wrongAudToken = await signJwtWithHmac(
    {
      sub: 'user-hs256',
      aud: 'other-service',
      iss: issuer,
      exp: nowSec + 3600,
    },
    'super-secret-jwt-hmac-key-for-supabase',
  )
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${wrongAudToken}` },
      }),
    ),
    null,
  )

  // Mismatched issuer returns null
  const wrongIssToken = await signJwtWithHmac(
    {
      sub: 'user-hs256',
      aud: 'authenticated',
      iss: 'https://evil.supabase.co/auth/v1',
      exp: nowSec + 3600,
    },
    'super-secret-jwt-hmac-key-for-supabase',
  )
  assert.equal(
    await jwtAuth(
      new Request('http://hollerkit.local/v1/uploads', {
        headers: { authorization: `Bearer ${wrongIssToken}` },
      }),
    ),
    null,
  )

  // 3. Expired JWT returns null
  const expiredToken = await signJwtWithHmac(
    { sub: 'user-hs256', aud: 'authenticated', iss: issuer, exp: nowSec - 10 },
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
    { sub: 'user-inactive', aud: 'authenticated', iss: issuer, exp: nowSec + 3600 },
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
  const keyHash = hashApiKey(rawApiKey)
  assert.ok(rawApiKey.startsWith('hk_agent_'))
  await store.createApiKey({
    keyHash,
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
  assert.equal(pKey.principalId, `apikey:${keyHash}`)
  assert.equal(pKey.subject, getApiKeyPrefix(rawApiKey))
  assert.deepEqual(pKey.scopes, ['agent:read', 'agent:triage'])

  // Revoking key makes apiKeys return null
  await store.revokeApiKey('my-agent')
  assert.equal(await apiKeyAuth(hkReq), null)
})

test('outbox enqueues matching sinks atomically, delivers with stable deliveryKey, enforces timeout, and backs off on failure', async () => {
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
  const webhookDeliveryKeys: string[] = []
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
    async deliver(detail) {
      if (detail.deliveryKey) {
        webhookDeliveryKeys.push(detail.deliveryKey)
      }
      if (shouldFailWebhook) {
        throw new Error('Webhook 503 Service Unavailable')
      }
      return { link: 'https://hooks.acme.test/delivered/1' }
    },
  }

  // Duplicate sink names are rejected
  assert.throws(
    () =>
      createHollerKitServer({
        store,
        storage,
        sinks: [githubSink, { name: 'github', async deliver() {} }],
        authenticate: apiKeys({ store }),
      }),
    /Duplicate sink registration: "github"/,
  )

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
    {
      sub: 'tester-1',
      aud: 'authenticated',
      exp: Math.floor(currentNow.getTime() / 1000) + 3600,
    },
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
  const pendingAfterPass = await store.claimPendingOutbox({ now: currentNow, leaseMs: 0 })
  assert.equal(pendingAfterPass.length, 0)

  // 2. Report feedback enqueues both sinks atomically
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

  const pendingBeforeFlush = await store.claimPendingOutbox({ now: currentNow, leaseMs: 0 })
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
  assert.equal(webhookDeliveryKeys.length, 2)
  assert.equal(webhookDeliveryKeys[0], webhookDeliveryKeys[1], 'deliveryKey must remain stable across retries')

  // Verify both sink links are now recorded on the feedback item
  const detail = await store.getFeedbackById(reportId)
  assert.ok(detail)
  assert.equal(detail.feedback.links.length, 2)
  assert.ok(detail.feedback.links.some((l) => l.includes('github.com/acme/app/issues/')))
  assert.ok(detail.feedback.links.includes('https://hooks.acme.test/delivered/1'))

  // 3. Sink timeout deadline aborts hanging sink and records failure
  await store.enqueueOutbox({
    feedbackId: reportId,
    sink: 'slow-sink',
    now: currentNow,
  })
  let signalAborted = false
  const slowSink: HollerKitSink = {
    name: 'slow-sink',
    async deliver(_detail, ctx) {
      await new Promise<void>((_resolve, reject) => {
        ctx?.signal.addEventListener('abort', () => {
          signalAborted = true
          reject(new Error('Aborted'))
        })
      })
    },
  }
  const flushTimeout = await flushOutbox({
    store,
    storage,
    sinks: [slowSink],
    deliveryTimeoutMs: 25,
    now: () => currentNow,
  })
  assert.equal(flushTimeout.claimed, 1)
  assert.equal(flushTimeout.failed.length, 1)
  assert.equal(signalAborted, true)
  assert.match(flushTimeout.failed[0]!.lastError ?? '', /timed out|Aborted/)
})

test('githubIssuesSink formats quest runs & bug reports, deduplicates retries via search, auto-flushes, and syncs webhook closures', async () => {
  // 1. Validate repo & token guards
  assert.throws(
    () => githubIssuesSink({ repo: 'invalid-repo', token: 'ghp_123' }),
    (err: unknown) => err instanceof HollerKitError && err.code === 'invalid_github_repo',
  )
  assert.throws(
    () => githubIssuesSink({ repo: 'owner/..', token: 'ghp_123' }),
    (err: unknown) => err instanceof HollerKitError && err.code === 'invalid_github_repo',
  )
  assert.throws(
    () => githubIssuesSink({ repo: 'owner/repo', token: '   ' }),
    (err: unknown) => err instanceof HollerKitError && err.code === 'invalid_github_token',
  )

  const store = memoryStore()
  const currentNow = new Date('2026-11-09T12:00:00.000Z')
  const storage = fakeStorage({ now: () => currentNow })

  await store.upsertTester({ userId: 'tester-gh', active: true })
  const agentKey = generateApiKey('agent')
  await store.createApiKey({
    keyHash: hashApiKey(agentKey),
    keyPrefix: getApiKeyPrefix(agentKey),
    scopes: ['quests:write', 'agent:read', 'agent:triage'],
  })

  const githubCalls: Array<{
    url: string
    method: string
    headers: Record<string, string>
    body: Record<string, unknown> | null
  }> = []
  let createdIssueCounter = 100

  const ghSink = githubIssuesSink({
    repo: 'Liampronan/HollerKit',
    token: 'ghp_test_token_123',
    assignees: ['liampronan'],
    fetchImpl: async (input, init) => {
      const url = String(input)
      const headers: Record<string, string> = {}
      new Headers(init?.headers).forEach((v, k) => {
        headers[k.toLowerCase()] = v
      })
      const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : null
      githubCalls.push({ url, method: init?.method ?? 'GET', headers, body })

      if (url.includes('/search/issues')) {
        return Response.json({
          total_count: 1,
          items: [
            {
              number: 77,
              html_url: 'https://github.com/Liampronan/HollerKit/issues/77',
            },
          ],
        })
      }

      createdIssueCounter += 1
      return Response.json(
        {
          number: createdIssueCounter,
          html_url: `https://github.com/Liampronan/HollerKit/issues/${createdIssueCounter}`,
        },
        { status: 201 },
      )
    },
  })

  const webhookSecret = 'whsec_github_test_secret'
  const handler = createHollerKitServer({
    store,
    storage,
    now: () => currentNow,
    sinks: [ghSink],
    autoFlushOutbox: 'sync',
    githubWebhook: { secret: webhookSecret },
    authenticate: [
      supabaseJwt({ secret: 'gh-jwt-secret', store, now: () => currentNow }),
      apiKeys({ store }),
    ],
  })

  const testerJwt = await signJwtWithHmac(
    {
      sub: 'tester-gh',
      aud: 'authenticated',
      exp: Math.floor(currentNow.getTime() / 1000) + 3600,
    },
    'gh-jwt-secret',
  )

  // Sync a quest first
  await handler(
    new Request('http://hollerkit.local/v1/quests', {
      method: 'PUT',
      headers: {
        authorization: `Bearer ${agentKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'camera-flip',
            title: 'Flip dual camera preview',
            area: 'camera',
            setup: ['Grant camera & mic permissions'],
            steps: ['Tap Flip button', 'Verify PIP swaps smoothly'],
            expect: ['Front and back feeds swap without stutter'],
          },
        ],
      }),
    }),
  )

  // Reserve an image upload grant for the failed quest run
  const failedFeedbackId = randomUUID()
  const uploadRes = await handler(
    new Request('http://hollerkit.local/v1/uploads', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${testerJwt}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        feedbackId: failedFeedbackId,
        kind: 'image',
        mimeType: 'image/png',
        size: 4096,
      }),
    }),
  )
  assert.equal(uploadRes.status, 200)
  const uploadGrant = (await uploadRes.json()) as { key: string }

  // Submit a failed quest run -> autoFlushOutbox: 'sync' creates the GitHub Issue immediately
  const failRes = await handler(
    new Request('http://hollerkit.local/v1/feedback', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${testerJwt}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        id: failedFeedbackId,
        kind: 'quest_run',
        questId: 'camera-flip',
        result: 'fail',
        build: '420',
        appVersion: '1.2.0',
        device: 'iPhone 16 Pro',
        os: 'iOS 18.2',
        comment: 'PIP freezes for 2 seconds when flipping\nSecond line details',
        transcript: 'Voice note: PIP freezes right after tapping flip.',
        stepsChecked: [true, false],
        events: [{ kind: 'mark', offsetSeconds: 3.4, payload: { note: 'freeze frame' } }],
        attachments: [{ key: uploadGrant.key, kind: 'image', mimeType: 'image/png', size: 4096, offsetSeconds: 3.4 }],
      }),
    }),
  )
  assert.equal(failRes.status, 201)
  const failBody = (await failRes.json()) as { feedback: { links: string[]; triageStatus: string } }
  assert.deepEqual(failBody.feedback.links, ['https://github.com/Liampronan/HollerKit/issues/101'])
  assert.equal(failBody.feedback.triageStatus, 'new')

  // Verify the outgoing GitHub Issues API request
  assert.equal(githubCalls.length, 1)
  const issueCall = githubCalls[0]!
  assert.equal(issueCall.method, 'POST')
  assert.equal(issueCall.url, 'https://api.github.com/repos/Liampronan/HollerKit/issues')
  assert.equal(issueCall.headers['authorization'], 'Bearer ghp_test_token_123')
  assert.equal(
    issueCall.body?.title,
    '[Quest Failed: Flip dual camera preview] PIP freezes for 2 seconds when flipping',
  )
  assert.deepEqual(issueCall.body?.labels, ['hollerkit', 'quest:fail', 'area:camera'])
  assert.deepEqual(issueCall.body?.assignees, ['liampronan'])
  const createdBodyText = String(issueCall.body?.body ?? '')
  assert.ok(createdBodyText.includes('- [x] Tap Flip button'))
  assert.ok(createdBodyText.includes('- [ ] Verify PIP swaps smoothly'))
  assert.ok(createdBodyText.includes('> Voice note: PIP freezes right after tapping flip.'))
  assert.ok(createdBodyText.includes('https://storage.hollerkit.test/read/'))
  // 7-day read URL TTL (604800s) used for autoFlushOutbox
  assert.ok(
    createdBodyText.includes(
      encodeURIComponent(new Date(currentNow.getTime() + 604_800 * 1000).toISOString()),
    ),
  )
  assert.equal(extractFeedbackIdFromGitHubIssueBody(createdBodyText), failedFeedbackId)

  // Verify the failed quest run is in the `triage=new` inbox before closing the GitHub issue
  const inboxBeforeClose = await handler(
    new Request('http://hollerkit.local/v1/feedback?triage=new', {
      method: 'GET',
      headers: {
        authorization: `Bearer ${agentKey}`,
      },
    }),
  )
  const inboxBefore = (await inboxBeforeClose.json()) as {
    items: Array<{ id: string; triageStatus: string }>
  }
  assert.equal(inboxBefore.items.length, 1)
  assert.equal(inboxBefore.items[0]?.id, failedFeedbackId)

  // 2. Send GitHub `issues.closed` webhook -> automatically resolves feedback & removes it from `triage=new` inbox
  const webhookPayload = JSON.stringify({
    action: 'closed',
    issue: {
      number: 101,
      html_url: 'https://github.com/Liampronan/HollerKit/issues/101',
      state_reason: 'completed',
      body: createdBodyText,
    },
    sender: { login: 'liampronan' },
  })
  const validSig =
    'sha256=' + createHmac('sha256', webhookSecret).update(webhookPayload, 'utf8').digest('hex')

  // Forged webhook signature is rejected with 401
  const badWebhookRes = await handler(
    new Request('http://hollerkit.local/v1/webhooks/github', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-github-event': 'issues',
        'x-hub-signature-256': 'sha256=' + '0'.repeat(64),
      },
      body: webhookPayload,
    }),
  )
  assert.equal(badWebhookRes.status, 401)

  // Valid webhook closes & resolves feedback
  const closeWebhookRes = await handler(
    new Request('http://hollerkit.local/v1/webhooks/github', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-github-event': 'issues',
        'x-hub-signature-256': validSig,
      },
      body: webhookPayload,
    }),
  )
  assert.equal(closeWebhookRes.status, 200)
  const closeWebhookBody = (await closeWebhookRes.json()) as {
    ok: boolean
    triageStatus: string
  }
  assert.equal(closeWebhookBody.ok, true)
  assert.equal(closeWebhookBody.triageStatus, 'resolved')

  // Now `GET /v1/feedback?triage=new` is empty and the feedback item has a triage audit entry from github:liampronan
  const inboxAfterClose = await handler(
    new Request('http://hollerkit.local/v1/feedback?triage=new', {
      method: 'GET',
      headers: {
        authorization: `Bearer ${agentKey}`,
      },
    }),
  )
  const inboxAfter = (await inboxAfterClose.json()) as {
    items: Array<{ id: string }>
  }
  assert.equal(inboxAfter.items.length, 0)

  // Reopening the GitHub issue sets triageStatus to "triaged" (and state_reason="not_planned" maps to "wontfix")
  const reopenPayload = JSON.stringify({
    action: 'reopened',
    issue: {
      number: 101,
      html_url: 'https://github.com/Liampronan/HollerKit/issues/101',
      body: createdBodyText,
    },
    sender: { login: 'liampronan' },
  })
  const reopenSig =
    'sha256=' + createHmac('sha256', webhookSecret).update(reopenPayload, 'utf8').digest('hex')
  const reopenRes = await handler(
    new Request('http://hollerkit.local/v1/webhooks/github', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-github-event': 'issues',
        'x-hub-signature-256': reopenSig,
      },
      body: reopenPayload,
    }),
  )
  assert.equal(reopenRes.status, 200)
  const reopenData = (await reopenRes.json()) as { triageStatus: string }
  assert.equal(reopenData.triageStatus, 'triaged')

  const notPlannedPayload = JSON.stringify({
    action: 'closed',
    issue: {
      number: 101,
      html_url: 'https://github.com/Liampronan/HollerKit/issues/101',
      state_reason: 'not_planned',
      body: createdBodyText,
    },
    sender: { login: 'liampronan' },
  })
  const notPlannedSig =
    'sha256=' + createHmac('sha256', webhookSecret).update(notPlannedPayload, 'utf8').digest('hex')
  const notPlannedRes = await createGitHubWebhookHandler({ store, secret: webhookSecret })(
    new Request('http://hollerkit.local/v1/webhooks/github', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-github-event': 'issues',
        'x-hub-signature-256': notPlannedSig,
      },
      body: notPlannedPayload,
    }),
  )
  assert.equal(notPlannedRes.status, 200)
  const notPlannedData = (await notPlannedRes.json()) as { triageStatus: string }
  assert.equal(notPlannedData.triageStatus, 'wontfix')

  // 3. Retry deduplication: when attempts > 0, githubIssuesSink queries /search/issues and returns existing issue #77
  const retryFeedbackId = randomUUID()
  const retryDetail = await store.createFeedback({
    id: retryFeedbackId,
    kind: 'report',
    build: '420',
    submitterId: 'tester-gh',
    comment: 'Retry dedupe report',
    now: currentNow,
  })
  const callsBeforeRetry = githubCalls.length
  const retryDeliver = await ghSink.deliver(
    {
      feedback: retryDetail.feedback,
      quest: null,
      events: [],
      triage: [],
      attachments: [],
      attempts: 1,
    },
    {
      signal: new AbortController().signal,
      deliveryId: 99,
      deliveryKey: 'outbox:99',
      attempts: 1,
    },
  )
  assert.equal(retryDeliver?.link, 'https://github.com/Liampronan/HollerKit/issues/77')
  assert.equal(githubCalls.length, callsBeforeRetry + 1)
  assert.equal(githubCalls[callsBeforeRetry]!.method, 'GET')
  assert.ok(githubCalls[callsBeforeRetry]!.url.includes('/search/issues'))

  // HTML comment escaping prevents breaking out of <!-- hollerkit-meta: ... -->
  const formattedEvil = formatGitHubIssue({
    feedback: {
      ...retryDetail.feedback,
      build: '100 --> <script>alert(1)</script>',
    },
    quest: null,
    events: [],
    triage: [],
    attachments: [],
  })
  const metaLine = formattedEvil.body
    .split('\n')
    .find((line) => line.startsWith('<!-- hollerkit-meta:'))
  assert.ok(metaLine)
  assert.ok(!metaLine.slice(0, -4).includes('-->'))
})
