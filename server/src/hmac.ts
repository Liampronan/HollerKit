import { HollerKitError } from './errors.js'

export async function verifyHmac(request: Request, appSecret: string, maxBodyBytes: number): Promise<{
  body: ArrayBuffer
  timestamp: string
}> {
  const signature = request.headers.get('x-hollerkit-signature')
  const timestamp = request.headers.get('x-hollerkit-timestamp')

  if (!signature) {
    throw new HollerKitError(401, 'missing_signature', 'Missing x-hollerkit-signature header.')
  }

  if (!timestamp) {
    throw new HollerKitError(400, 'missing_timestamp', 'Missing x-hollerkit-timestamp header.')
  }

  const body = await readBodyWithLimit(request, maxBodyBytes)
  const expected = await hmacHex(appSecret, concatBodyAndTimestamp(body, timestamp))

  if (!safeCompareHex(signature, expected)) {
    throw new HollerKitError(401, 'invalid_signature', 'Invalid HollerKit request signature.')
  }

  return { body, timestamp }
}

async function readBodyWithLimit(request: Request, maxBodyBytes: number): Promise<ArrayBuffer> {
  if (!request.body) return new ArrayBuffer(0)

  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let receivedBytes = 0

  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      if (!value) continue

      receivedBytes += value.byteLength
      if (receivedBytes > maxBodyBytes) {
        throw new HollerKitError(413, 'body_too_large', 'Request body exceeds the configured byte limit.')
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }

  const body = new Uint8Array(receivedBytes)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  return bufferSource(body)
}

function safeCompareHex(actual: string, expected: string): boolean {
  if (actual.length !== expected.length) return false

  let mismatch = 0
  for (let index = 0; index < expected.length; index += 1) {
    mismatch |= actual.charCodeAt(index) ^ expected.charCodeAt(index)
  }

  return mismatch === 0
}

async function hmacHex(secret: string, data: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    bufferSource(new TextEncoder().encode(secret)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', key, bufferSource(data))
  return bytesToHex(new Uint8Array(signature))
}

function concatBodyAndTimestamp(body: ArrayBuffer, timestamp: string): Uint8Array {
  const bodyBytes = new Uint8Array(body)
  const timestampBytes = new TextEncoder().encode(timestamp)
  const combined = new Uint8Array(bodyBytes.length + timestampBytes.length)
  combined.set(bodyBytes, 0)
  combined.set(timestampBytes, bodyBytes.length)
  return combined
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

function bufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}
