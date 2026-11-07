import type { HollerKitStorageAdapter } from '../../v1/server.js'

export interface S3StorageOptions {
  endpoint: string
  bucket: string
  region?: string | undefined
  accessKeyId: string
  secretAccessKey: string
  forcePathStyle?: boolean | undefined
  now?: (() => Date) | undefined
}

export function s3Storage(options: S3StorageOptions): HollerKitStorageAdapter {
  const endpointUrl = new URL(options.endpoint)
  const region = options.region ?? 'auto'
  const forcePathStyle = options.forcePathStyle ?? true
  const nowFn = options.now ?? (() => new Date())

  async function presign(
    method: 'PUT' | 'GET',
    key: string,
    expiresInSeconds: number,
  ): Promise<{ url: string; expiresAt: string }> {
    const now = nowFn()
    const expiresAt = new Date(now.getTime() + expiresInSeconds * 1000).toISOString()
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '')
    const dateStamp = amzDate.slice(0, 8)
    const credentialScope = `${dateStamp}/${region}/s3/aws4_request`

    const targetUrl = buildTargetUrl(endpointUrl, options.bucket, key, forcePathStyle)
    const signedHeaders = 'host'

    const queryEntries: [string, string][] = [
      ['X-Amz-Algorithm', 'AWS4-HMAC-SHA256'],
      ['X-Amz-Credential', `${options.accessKeyId}/${credentialScope}`],
      ['X-Amz-Date', amzDate],
      ['X-Amz-Expires', String(expiresInSeconds)],
      ['X-Amz-SignedHeaders', signedHeaders],
    ]

    queryEntries.sort(([a], [b]) => a.localeCompare(b))
    const canonicalQueryString = queryEntries
      .map(([k, v]) => `${encodeRfc3986(k)}=${encodeRfc3986(v)}`)
      .join('&')

    const canonicalHeaders = `host:${targetUrl.host}\n`
    const payloadHash = 'UNSIGNED-PAYLOAD'

    const canonicalRequest = [
      method,
      targetUrl.pathname,
      canonicalQueryString,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n')

    const stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      await sha256Hex(canonicalRequest),
    ].join('\n')

    const signingKey = await s3SigningKey(options.secretAccessKey, dateStamp, region)
    const signature = bytesToHex(await hmacBytes(signingKey, stringToSign))

    return {
      url: `${targetUrl.origin}${targetUrl.pathname}?${canonicalQueryString}&X-Amz-Signature=${signature}`,
      expiresAt,
    }
  }

  return {
    async presignUpload(input) {
      return presign('PUT', input.key, input.expiresInSeconds ?? 600)
    },
    async signReadUrl(input) {
      return presign('GET', input.key, input.expiresInSeconds ?? 3600)
    },
  }
}

function buildTargetUrl(
  endpointUrl: URL,
  bucket: string,
  key: string,
  forcePathStyle: boolean,
): URL {
  const basePath = endpointUrl.pathname.replace(/\/+$/, '')
  const encodedKey = key
    .replace(/^\/+/, '')
    .split('/')
    .map((segment) => encodeRfc3986(segment))
    .join('/')

  if (forcePathStyle) {
    const encodedBucket = encodeRfc3986(bucket)
    return new URL(`${endpointUrl.origin}${basePath}/${encodedBucket}/${encodedKey}`)
  }

  return new URL(`${endpointUrl.protocol}//${bucket}.${endpointUrl.host}${basePath}/${encodedKey}`)
}

function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  )
}

async function s3SigningKey(secret: string, dateStamp: string, region: string): Promise<Uint8Array> {
  const dateKey = await hmacBytes(new TextEncoder().encode(`AWS4${secret}`), dateStamp)
  const regionKey = await hmacBytes(dateKey, region)
  const serviceKey = await hmacBytes(regionKey, 's3')
  return hmacBytes(serviceKey, 'aws4_request')
}

async function hmacBytes(keyBytes: Uint8Array, value: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    'raw',
    bufferSource(keyBytes),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', key, bufferSource(new TextEncoder().encode(value)))
  return new Uint8Array(signature)
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return bytesToHex(new Uint8Array(digest))
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

function bufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}
