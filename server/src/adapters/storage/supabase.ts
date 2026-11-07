import { HollerKitError } from '../../errors.js'
import type { HollerKitStorageAdapter } from '../../v1/server.js'

/**
 * Supabase Storage's `/object/upload/sign/` endpoint issues fixed 2-hour (7200s) upload tokens
 * and does not accept a custom `expiresIn` parameter.
 */
export const SUPABASE_UPLOAD_URL_TTL_SECONDS = 2 * 60 * 60

export interface SupabaseStorageOptions {
  url: string
  serviceRoleKey: string
  bucket: string
  fetchImpl?: typeof globalThis.fetch | undefined
  now?: (() => Date) | undefined
}

/**
 * Creates a HollerKit storage adapter backed by Supabase Storage REST APIs.
 */
export function supabaseStorage(options: SupabaseStorageOptions): HollerKitStorageAdapter {
  const baseUrl = options.url.replace(/\/$/, '')
  const fetchFn = options.fetchImpl ?? globalThis.fetch
  const nowFn = options.now ?? (() => new Date())

  return {
    async presignUpload(input) {
      const requestNow = nowFn()
      const encodedKey = encodeStorageKey(input.key)
      const endpoint = `${baseUrl}/storage/v1/object/upload/sign/${encodeURIComponent(options.bucket)}/${encodedKey}`

      let response: Response
      try {
        response = await fetchFn(endpoint, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${options.serviceRoleKey}`,
            apikey: options.serviceRoleKey,
            'x-upsert': 'false',
          },
        })
      } catch (error) {
        const reason = error instanceof Error ? error.message : 'network error'
        throw new HollerKitError(
          502,
          'storage_error',
          `Supabase storage presignUpload request failed: ${reason}`,
        )
      }

      if (!response.ok) {
        throw new HollerKitError(
          502,
          'storage_error',
          `Supabase storage presignUpload failed with status ${response.status}.`,
        )
      }

      let payload: {
        url?: string
        signedURL?: string
        signedUrl?: string
      }
      try {
        payload = (await response.json()) as {
          url?: string
          signedURL?: string
          signedUrl?: string
        }
      } catch {
        throw new HollerKitError(
          502,
          'storage_error',
          'Supabase storage presignUpload returned invalid JSON.',
        )
      }

      const rawUrl = payload.url ?? payload.signedURL ?? payload.signedUrl
      if (!rawUrl || typeof rawUrl !== 'string') {
        throw new HollerKitError(
          502,
          'storage_error',
          'Supabase storage presignUpload response did not include a signed URL.',
        )
      }

      const normalizedUrl = normalizeSupabaseSignedUrl(baseUrl, rawUrl)
      const tokenExpIso = extractSignedUrlTokenExpiry(normalizedUrl)
      const expiresAt =
        tokenExpIso ??
        new Date(requestNow.getTime() + SUPABASE_UPLOAD_URL_TTL_SECONDS * 1000).toISOString()

      return {
        url: normalizedUrl,
        expiresAt,
      }
    },

    async signReadUrl(input) {
      const expiresInSeconds = input.expiresInSeconds ?? 3600
      const expiresAt = new Date(nowFn().getTime() + expiresInSeconds * 1000).toISOString()
      const encodedKey = encodeStorageKey(input.key)
      const endpoint = `${baseUrl}/storage/v1/object/sign/${encodeURIComponent(options.bucket)}/${encodedKey}`

      let response: Response
      try {
        response = await fetchFn(endpoint, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${options.serviceRoleKey}`,
            apikey: options.serviceRoleKey,
            'content-type': 'application/json',
          },
          body: JSON.stringify({ expiresIn: expiresInSeconds }),
        })
      } catch (error) {
        const reason = error instanceof Error ? error.message : 'network error'
        throw new HollerKitError(
          502,
          'storage_error',
          `Supabase storage signReadUrl request failed: ${reason}`,
        )
      }

      if (!response.ok) {
        throw new HollerKitError(
          502,
          'storage_error',
          `Supabase storage signReadUrl failed with status ${response.status}.`,
        )
      }

      let payload: {
        signedURL?: string
        signedUrl?: string
        url?: string
      }
      try {
        payload = (await response.json()) as {
          signedURL?: string
          signedUrl?: string
          url?: string
        }
      } catch {
        throw new HollerKitError(
          502,
          'storage_error',
          'Supabase storage signReadUrl returned invalid JSON.',
        )
      }

      const rawUrl = payload.signedURL ?? payload.signedUrl ?? payload.url
      if (!rawUrl || typeof rawUrl !== 'string') {
        throw new HollerKitError(
          502,
          'storage_error',
          'Supabase storage signReadUrl response did not include signedURL.',
        )
      }

      return {
        url: normalizeSupabaseSignedUrl(baseUrl, rawUrl),
        expiresAt,
      }
    },
  }
}

/**
 * Resolves a relative Supabase storage signed path against the project's base URL.
 */
function normalizeSupabaseSignedUrl(baseUrl: string, rawUrl: string): string {
  if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
    return rawUrl
  }
  if (rawUrl.startsWith('/storage/v1/')) {
    return `${baseUrl}${rawUrl}`
  }
  if (rawUrl.startsWith('/object/')) {
    return `${baseUrl}/storage/v1${rawUrl}`
  }
  return `${baseUrl}/${rawUrl.replace(/^\/+/, '')}`
}

/**
 * Extracts the `exp` timestamp from a Supabase `?token=<jwt>` query parameter when present.
 */
function extractSignedUrlTokenExpiry(signedUrl: string): string | null {
  try {
    const parsedUrl = new URL(signedUrl)
    const token = parsedUrl.searchParams.get('token')
    if (!token) return null
    const parts = token.split('.')
    if (parts.length !== 3 || !parts[1]) return null
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4)
    const claims = JSON.parse(Buffer.from(padded, 'base64').toString('utf8')) as { exp?: unknown }
    if (typeof claims.exp === 'number' && Number.isFinite(claims.exp) && claims.exp > 0) {
      return new Date(claims.exp * 1000).toISOString()
    }
    return null
  } catch {
    return null
  }
}

/**
 * Validates and URL-encodes each path segment of a storage object key.
 */
function encodeStorageKey(key: string): string {
  const normalizedKey = key.replace(/^\/+/, '')
  if (!normalizedKey || normalizedKey.endsWith('/')) {
    throw new HollerKitError(400, 'invalid_storage_key', 'Storage key must be a non-empty object path.')
  }
  const segments = normalizedKey.split('/')
  for (const segment of segments) {
    if (!segment || segment === '.' || segment === '..') {
      throw new HollerKitError(
        400,
        'invalid_storage_key',
        'Storage key must not contain empty or dot path segments.',
      )
    }
  }
  return segments.map((segment) => encodeURIComponent(segment)).join('/')
}
