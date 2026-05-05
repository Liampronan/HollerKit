import type { ReportFile, StorageAdapter, UploadedFile } from '../../types.js'

export type S3StorageOptions = {
  endpoint: string
  bucket: string
  accessKeyId: string
  secretAccessKey: string
  region?: string
  prefix?: string
  publicBaseUrl?: string
}

export function s3Storage(options: S3StorageOptions): StorageAdapter {
  const endpoint = options.endpoint.replace(/\/$/, '')
  const region = options.region ?? 'auto'

  return {
    async upload(reportId: string, files: ReportFile[]): Promise<UploadedFile[]> {
      return Promise.all(files.map(async (file) => {
        const key = objectPath(options.prefix, reportId, file)
        const url = `${endpoint}/${options.bucket}/${encodePath(key)}`
        const headers = await signS3Put({
          url,
          region,
          accessKeyId: options.accessKeyId,
          secretAccessKey: options.secretAccessKey,
          contentType: file.mimeType,
        })

        const response = await fetch(url, {
          method: 'PUT',
          headers,
          body: file.data,
        })

        if (!response.ok) {
          throw new Error(`S3 storage upload failed with ${response.status}.`)
        }

        return {
          kind: file.kind,
          filename: file.filename,
          mimeType: file.mimeType,
          size: file.size,
          url: `${(options.publicBaseUrl ?? `${endpoint}/${options.bucket}`).replace(/\/$/, '')}/${encodePath(key)}`,
        }
      }))
    },
  }
}

async function signS3Put(input: {
  url: string
  region: string
  accessKeyId: string
  secretAccessKey: string
  contentType: string
}): Promise<Record<string, string>> {
  const now = new Date()
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '')
  const dateStamp = amzDate.slice(0, 8)
  const url = new URL(input.url)
  const credentialScope = `${dateStamp}/${input.region}/s3/aws4_request`
  const signedHeaders = 'content-type;host;x-amz-content-sha256;x-amz-date'
  const payloadHash = 'UNSIGNED-PAYLOAD'

  const canonicalHeaders = [
    `content-type:${input.contentType}`,
    `host:${url.host}`,
    `x-amz-content-sha256:${payloadHash}`,
    `x-amz-date:${amzDate}`,
    '',
  ].join('\n')

  const canonicalRequest = [
    'PUT',
    url.pathname,
    '',
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

  const signingKey = await s3SigningKey(input.secretAccessKey, dateStamp, input.region)
  const signature = bytesToHex(await hmacBytes(signingKey, stringToSign))

  return {
    authorization:
      `AWS4-HMAC-SHA256 Credential=${input.accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    'content-type': input.contentType,
    host: url.host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
  }
}

async function s3SigningKey(secret: string, dateStamp: string, region: string): Promise<Uint8Array> {
  const dateKey = await hmacBytes(new TextEncoder().encode(`AWS4${secret}`), dateStamp)
  const regionKey = await hmacBytes(dateKey, region)
  const serviceKey = await hmacBytes(regionKey, 's3')
  return hmacBytes(serviceKey, 'aws4_request')
}

async function hmacBytes(keyBytes: Uint8Array, value: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', bufferSource(keyBytes), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const signature = await crypto.subtle.sign('HMAC', key, bufferSource(new TextEncoder().encode(value)))
  return new Uint8Array(signature)
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return bytesToHex(new Uint8Array(digest))
}

function objectPath(prefix: string | undefined, reportId: string, file: ReportFile): string {
  return [prefix, reportId, sanitizeFilename(file.filename)].filter(Boolean).join('/')
}

function sanitizeFilename(filename: string): string {
  return filename.replace(/[^a-zA-Z0-9._-]/g, '_')
}

function encodePath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/')
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

function bufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}
