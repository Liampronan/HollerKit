import { HollerKitError } from '../../errors.js'
import type { HollerKitStorageAdapter } from '../../v1/server.js'

export interface S3StorageOptions {
  endpoint: string
  bucket: string
  region?: string | undefined
  accessKeyId: string
  secretAccessKey: string
  forcePathStyle?: boolean | undefined
  ifNoneMatch?: boolean | undefined
  now?: (() => Date) | undefined
}

/**
 * Creates a Web Crypto AWS SigV4 storage adapter for S3-compatible object stores.
 */
export function s3Storage(options: S3StorageOptions): HollerKitStorageAdapter {
  const endpointUrl = new URL(options.endpoint)
  const region = options.region ?? 'auto'
  const forcePathStyle = options.forcePathStyle ?? true
  const nowFn = options.now ?? (() => new Date())

  /**
   * Generates a query-string presigned SigV4 URL for PUT or GET requests.
   */
  async function presign(
    method: 'PUT' | 'GET',
    key: string,
    expiresInSeconds: number,
    extraHeaders?: Record<string, string>,
  ): Promise<{ url: string; expiresAt: string }> {
    const now = nowFn()
    const expiresAt = new Date(now.getTime() + expiresInSeconds * 1000).toISOString()
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '')
    const dateStamp = amzDate.slice(0, 8)
    const credentialScope = `${dateStamp}/${region}/s3/aws4_request`

    const targetUrl = buildTargetUrl(endpointUrl, options.bucket, key, forcePathStyle)

    const headersToSign: Record<string, string> = {
      host: targetUrl.host,
    }
    if (extraHeaders) {
      for (const [headerName, headerValue] of Object.entries(extraHeaders)) {
        headersToSign[headerName.toLowerCase().trim()] = headerValue.trim()
      }
    }

    const sortedHeaderEntries = Object.entries(headersToSign).sort(([a], [b]) => a.localeCompare(b))
    const signedHeaders = sortedHeaderEntries.map(([name]) => name).join(';')
    const canonicalHeaders = sortedHeaderEntries
      .map(([name, val]) => `${name}:${val}\n`)
      .join('')

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
      if (!Number.isInteger(input.size) || input.size <= 0) {
        throw new HollerKitError(400, 'invalid_upload_size', 'Upload size must be a positive integer.')
      }
      const mimeType = input.mimeType?.trim()
      if (!mimeType) {
        throw new HollerKitError(400, 'invalid_mime_type', 'Upload mimeType is required.')
      }

      const uploadHeaders: Record<string, string> = {
        'content-length': String(input.size),
        'content-type': mimeType,
      }
      if (options.ifNoneMatch) {
        uploadHeaders['if-none-match'] = '*'
      }

      return presign('PUT', input.key, input.expiresInSeconds ?? 600, uploadHeaders)
    },
    async signReadUrl(input) {
      return presign('GET', input.key, input.expiresInSeconds ?? 3600)
    },
  }
}

/**
 * Validates and constructs the target object URL without allowing dot-segment normalization.
 */
function buildTargetUrl(
  endpointUrl: URL,
  bucket: string,
  key: string,
  forcePathStyle: boolean,
): URL {
  const trimmedBucket = bucket.trim()
  if (!trimmedBucket || trimmedBucket === '.' || trimmedBucket === '..' || trimmedBucket.includes('/')) {
    throw new HollerKitError(400, 'invalid_bucket', 'Invalid S3 bucket name.')
  }

  const normalizedKey = key.replace(/^\/+/, '')
  if (!normalizedKey || normalizedKey.endsWith('/')) {
    throw new HollerKitError(400, 'invalid_storage_key', 'Storage key must be a non-empty object path.')
  }

  const rawSegments = normalizedKey.split('/')
  for (const segment of rawSegments) {
    if (!segment || segment === '.' || segment === '..') {
      throw new HollerKitError(
        400,
        'invalid_storage_key',
        'Storage key must not contain empty or dot path segments.',
      )
    }
  }

  const basePath = endpointUrl.pathname.replace(/\/+$/, '')
  const encodedKey = rawSegments.map((segment) => encodeRfc3986(segment)).join('/')

  if (forcePathStyle) {
    const encodedBucket = encodeRfc3986(trimmedBucket)
    return new URL(`${endpointUrl.origin}${basePath}/${encodedBucket}/${encodedKey}`)
  }

  return new URL(`${endpointUrl.protocol}//${trimmedBucket}.${endpointUrl.host}${basePath}/${encodedKey}`)
}

/**
 * Encodes a URI component according to RFC 3986 for AWS SigV4 canonicalization.
 */
function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  )
}

/**
 * Derives the 4-step HMAC-SHA256 signing key for AWS SigV4.
 */
async function s3SigningKey(secret: string, dateStamp: string, region: string): Promise<Uint8Array> {
  const dateKey = await hmacBytes(new TextEncoder().encode(`AWS4${secret}`), dateStamp)
  const regionKey = await hmacBytes(dateKey, region)
  const serviceKey = await hmacBytes(regionKey, 's3')
  return hmacBytes(serviceKey, 'aws4_request')
}

/**
 * Computes an HMAC-SHA256 digest using Web Crypto.
 */
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

/**
 * Computes a lowercase hex SHA-256 digest of a UTF-8 string.
 */
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return bytesToHex(new Uint8Array(digest))
}

/**
 * Converts a byte array into a lowercase hexadecimal string.
 */
function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/**
 * Extracts a standalone ArrayBuffer slice from a Uint8Array.
 */
function bufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}
