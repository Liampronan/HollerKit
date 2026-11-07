import type { HollerKitStorageAdapter } from '../../v1/server.js'

export interface SupabaseStorageOptions {
  url: string
  serviceRoleKey: string
  bucket: string
  fetchImpl?: typeof globalThis.fetch | undefined
  now?: (() => Date) | undefined
}

export function supabaseStorage(options: SupabaseStorageOptions): HollerKitStorageAdapter {
  const baseUrl = options.url.replace(/\/$/, '')
  const fetchFn = options.fetchImpl ?? globalThis.fetch
  const nowFn = options.now ?? (() => new Date())

  return {
    async presignUpload(input) {
      const expiresInSeconds = input.expiresInSeconds ?? 600
      const expiresAt = new Date(nowFn().getTime() + expiresInSeconds * 1000).toISOString()
      const encodedKey = encodeStorageKey(input.key)
      const endpoint = `${baseUrl}/storage/v1/object/upload/sign/${encodeURIComponent(options.bucket)}/${encodedKey}`

      const response = await fetchFn(endpoint, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${options.serviceRoleKey}`,
          apikey: options.serviceRoleKey,
          'x-upsert': 'false',
        },
      })

      if (!response.ok) {
        throw new Error(`Supabase storage presignUpload failed with ${response.status}.`)
      }

      const payload = (await response.json()) as {
        url?: string
        signedURL?: string
        signedUrl?: string
      }
      const rawUrl = payload.url ?? payload.signedURL ?? payload.signedUrl
      if (!rawUrl) {
        throw new Error('Supabase storage presignUpload response did not include a signed URL.')
      }

      return {
        url: normalizeSupabaseSignedUrl(baseUrl, rawUrl),
        expiresAt,
      }
    },

    async signReadUrl(input) {
      const expiresInSeconds = input.expiresInSeconds ?? 3600
      const expiresAt = new Date(nowFn().getTime() + expiresInSeconds * 1000).toISOString()
      const encodedKey = encodeStorageKey(input.key)
      const endpoint = `${baseUrl}/storage/v1/object/sign/${encodeURIComponent(options.bucket)}/${encodedKey}`

      const response = await fetchFn(endpoint, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${options.serviceRoleKey}`,
          apikey: options.serviceRoleKey,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ expiresIn: expiresInSeconds }),
      })

      if (!response.ok) {
        throw new Error(`Supabase storage signReadUrl failed with ${response.status}.`)
      }

      const payload = (await response.json()) as {
        signedURL?: string
        signedUrl?: string
        url?: string
      }
      const rawUrl = payload.signedURL ?? payload.signedUrl ?? payload.url
      if (!rawUrl) {
        throw new Error('Supabase storage signReadUrl response did not include signedURL.')
      }

      return {
        url: normalizeSupabaseSignedUrl(baseUrl, rawUrl),
        expiresAt,
      }
    },
  }
}

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

function encodeStorageKey(key: string): string {
  return key
    .replace(/^\/+/, '')
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/')
}
