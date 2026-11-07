import { randomBytes } from 'node:crypto'
import { hashApiKey, type ApiKeyRecord, type HollerKitStore, type Scope } from './store.js'

export { hashApiKey }

export interface AuthPrincipal {
  principalId: string
  subject?: string | undefined
  scopes: Scope[]
  kind?: 'tester' | 'api_key' | undefined
  label?: string | null | undefined
  email?: string | null | undefined
}

export type Authenticator = (
  request: Request,
) => Promise<AuthPrincipal | null> | AuthPrincipal | null

export interface JwtClaims {
  sub: string
  email?: string | undefined
  exp?: number | undefined
  nbf?: number | undefined
  iat?: number | undefined
  iss?: string | undefined
  aud?: string | string[] | undefined
  [key: string]: unknown
}

export interface SupabaseJwtOptions {
  jwksUrl?: string | undefined
  secret?: string | undefined
  issuer?: string | string[] | undefined
  audience?: string | string[] | undefined
  store?: Pick<HollerKitStore, 'isTester'> | undefined
  authorizeTester?: ((claims: JwtClaims) => Promise<boolean> | boolean) | undefined
  fetchImpl?: typeof globalThis.fetch | undefined
  jwksCacheTtlMs?: number | undefined
  jwksRefreshCooldownMs?: number | undefined
  now?: (() => Date) | undefined
}

export interface ApiKeysAuthOptions {
  store: Pick<HollerKitStore, 'getApiKeyByHash'> &
    Partial<Pick<HollerKitStore, 'findApiKeyByHash'>>
}

interface CachedJwks {
  fetchedAt: number
  keys: JsonWebKeyWithKid[]
}

interface JsonWebKeyWithKid extends JsonWebKey {
  kid?: string
}

/**
 * Extracts a trimmed Bearer token from the `Authorization` request header.
 */
export function extractBearerToken(request: Request): string | null {
  const header = request.headers.get('authorization')
  if (!header) return null
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match || !match[1]) return null
  const token = match[1].trim()
  return token.length > 0 ? token : null
}

/**
 * Generates a high-entropy `hk_...` API key with an optional label prefix.
 */
export function generateApiKey(prefix?: string): string {
  const randomPart = randomBytes(24).toString('hex')
  if (!prefix || prefix.trim().length === 0) {
    return `hk_${randomPart}`
  }
  const cleaned = prefix.trim().replace(/^_+|_+$/g, '')
  if (cleaned === 'hk') {
    return `hk_${randomPart}`
  }
  if (cleaned.startsWith('hk_')) {
    return `${cleaned}_${randomPart}`
  }
  return `hk_${cleaned}_${randomPart}`
}

/**
 * Returns the 12-character display prefix for a raw `hk_...` API key.
 */
export function getApiKeyPrefix(rawKey: string): string {
  return rawKey.slice(0, 12)
}

/**
 * Creates an in-memory authenticator backed by a static map of bearer tokens.
 */
export function staticTokens(
  tokens: Record<string, (Omit<AuthPrincipal, 'subject'> & { subject?: string | undefined }) | Scope[]>,
): Authenticator {
  return (request: Request): AuthPrincipal | null => {
    const token = extractBearerToken(request)
    if (!token || !Object.hasOwn(tokens, token)) return null
    const entry = tokens[token]
    if (!entry) return null
    if (Array.isArray(entry)) {
      const id = `token:${hashApiKey(token)}`
      return {
        principalId: id,
        subject: id,
        scopes: [...entry],
      }
    }
    return {
      principalId: entry.principalId,
      subject: entry.subject ?? entry.principalId,
      scopes: [...entry.scopes],
      kind: entry.kind,
      label: entry.label,
      email: entry.email,
    }
  }
}

/**
 * Creates an authenticator that verifies `hk_...` bearer keys against `hollerkit.api_keys`.
 */
export function apiKeys(options: ApiKeysAuthOptions): Authenticator {
  return async (request: Request): Promise<AuthPrincipal | null> => {
    const token = extractBearerToken(request)
    if (!token || !token.startsWith('hk_')) return null
    const keyHash = hashApiKey(token)
    let record: ApiKeyRecord | null = null
    if (typeof options.store.findApiKeyByHash === 'function') {
      record = await options.store.findApiKeyByHash(keyHash)
    } else {
      record = await options.store.getApiKeyByHash(keyHash)
    }
    if (!record || record.revokedAt !== null) return null
    return {
      principalId: `apikey:${record.keyHash}`,
      subject: record.keyPrefix,
      scopes: [...record.scopes],
      kind: 'api_key',
      label: record.label,
    }
  }
}

export const apiKeysAuthenticator = apiKeys

/**
 * Creates a JWT authenticator for Supabase Auth (ES256/RS256 JWKS with HS256 fallback)
 * that verifies tester enrollment before granting the `tester` scope.
 */
export function supabaseJwt(options: SupabaseJwtOptions): Authenticator {
  if (!options.jwksUrl && !options.secret) {
    throw new Error('supabaseJwt requires at least one of jwksUrl or secret.')
  }
  if (!options.store && !options.authorizeTester) {
    throw new Error('supabaseJwt requires at least one of store or authorizeTester.')
  }

  const fetchFn = options.fetchImpl ?? globalThis.fetch
  const cacheTtlMs = options.jwksCacheTtlMs ?? 5 * 60 * 1000
  const refreshCooldownMs = options.jwksRefreshCooldownMs ?? 10_000
  const nowFn = options.now ?? (() => new Date())
  const expectedAudience = normalizeExpectedClaim(options.audience ?? 'authenticated')
  const derivedIssuer = deriveIssuerFromJwksUrl(options.jwksUrl)
  const expectedIssuer = normalizeExpectedClaim(options.issuer ?? derivedIssuer)

  let cachedJwks: CachedJwks | null = null
  let inFlightJwksFetch: Promise<JsonWebKeyWithKid[]> | null = null
  let lastForcedRefreshAt = -Infinity

  /**
   * Fetches and caches JWKS keys, coalescing concurrent in-flight requests.
   */
  async function getJwksKeys(forceRefresh = false): Promise<JsonWebKeyWithKid[]> {
    if (!options.jwksUrl) return []
    const nowMs = nowFn().getTime()
    if (!forceRefresh && cachedJwks && nowMs - cachedJwks.fetchedAt < cacheTtlMs) {
      return cachedJwks.keys
    }
    if (
      forceRefresh &&
      cachedJwks &&
      nowMs - lastForcedRefreshAt < refreshCooldownMs &&
      nowMs - cachedJwks.fetchedAt < cacheTtlMs
    ) {
      return cachedJwks.keys
    }

    if (inFlightJwksFetch) {
      return inFlightJwksFetch
    }

    if (forceRefresh) {
      lastForcedRefreshAt = nowMs
    }

    const fetchUrl = options.jwksUrl
    inFlightJwksFetch = (async () => {
      try {
        const response = await fetchFn(fetchUrl, {
          method: 'GET',
          headers: { accept: 'application/json' },
        })
        if (!response.ok) {
          throw new Error(`Failed to fetch JWKS from ${fetchUrl}: ${response.status}`)
        }
        const body = (await response.json()) as { keys?: JsonWebKeyWithKid[] }
        const keys = Array.isArray(body?.keys) ? body.keys : []
        cachedJwks = {
          fetchedAt: nowFn().getTime(),
          keys,
        }
        return keys
      } finally {
        inFlightJwksFetch = null
      }
    })()

    return inFlightJwksFetch
  }

  /**
   * Looks up a matching JWK by `kid` and `alg`, triggering a bounded refresh on cache miss.
   */
  async function findJwk(kid: string | undefined, alg: string): Promise<JsonWebKeyWithKid | null> {
    let keys = await getJwksKeys(false)
    let match = matchKey(keys, kid, alg)
    if (!match && kid) {
      keys = await getJwksKeys(true)
      match = matchKey(keys, kid, alg)
    }
    return match
  }

  return async (request: Request): Promise<AuthPrincipal | null> => {
    const token = extractBearerToken(request)
    if (!token || token.startsWith('hk_')) return null

    const parts = token.split('.')
    if (parts.length !== 3) return null
    const [headerB64, payloadB64, signatureB64] = parts as [string, string, string]
    if (!headerB64 || !payloadB64 || !signatureB64) return null

    let header: { alg?: unknown; kid?: unknown; typ?: unknown }
    let payload: Record<string, unknown>
    let signatureBytes: Uint8Array
    try {
      header = JSON.parse(new TextDecoder().decode(base64UrlDecode(headerB64)))
      payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(payloadB64)))
      signatureBytes = base64UrlDecode(signatureB64)
    } catch {
      return null
    }

    if (typeof header !== 'object' || header === null || typeof payload !== 'object' || payload === null) {
      return null
    }

    const alg = typeof header.alg === 'string' ? header.alg : ''
    const kid = typeof header.kid === 'string' ? header.kid : undefined
    const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)

    let verified = false
    try {
      if ((alg === 'ES256' || alg === 'RS256') && options.jwksUrl) {
        const jwk = await findJwk(kid, alg)
        if (jwk) {
          verified = await verifyWithJwk(jwk, alg, signingInput, signatureBytes)
        }
      } else if (alg === 'HS256' && options.secret) {
        verified = await verifyWithHmacSecret(options.secret, signingInput, signatureBytes)
      }
    } catch {
      return null
    }

    if (!verified) return null

    const nowSec = Math.floor(nowFn().getTime() / 1000)
    if (typeof payload.exp !== 'number' || !Number.isFinite(payload.exp) || nowSec >= payload.exp) {
      return null
    }
    if (payload.nbf !== undefined) {
      if (typeof payload.nbf !== 'number' || !Number.isFinite(payload.nbf) || nowSec < payload.nbf) {
        return null
      }
    }

    if (expectedAudience.length > 0 && !matchesAudienceClaim(payload.aud, expectedAudience)) {
      return null
    }
    if (expectedIssuer.length > 0 && !matchesIssuerClaim(payload.iss, expectedIssuer)) {
      return null
    }

    const sub = typeof payload.sub === 'string' ? payload.sub.trim() : ''
    if (!sub) return null

    const claims: JwtClaims = {
      ...payload,
      sub,
      email: typeof payload.email === 'string' ? payload.email : undefined,
      exp: payload.exp,
      nbf: typeof payload.nbf === 'number' ? payload.nbf : undefined,
      iat: typeof payload.iat === 'number' ? payload.iat : undefined,
      iss: typeof payload.iss === 'string' ? payload.iss : undefined,
      aud:
        typeof payload.aud === 'string' || Array.isArray(payload.aud)
          ? (payload.aud as string | string[])
          : undefined,
    }

    if (options.authorizeTester) {
      const allowed = await options.authorizeTester(claims)
      if (!allowed) return null
    } else if (options.store) {
      const allowed = await options.store.isTester(sub)
      if (!allowed) return null
    }

    return {
      principalId: sub,
      subject: sub,
      scopes: ['tester'],
      kind: 'tester',
      email: claims.email ?? null,
      label: claims.email ?? null,
    }
  }
}

/**
 * Normalizes a string or string-array claim expectation into a list of non-empty strings.
 */
function normalizeExpectedClaim(value: string | string[] | undefined): string[] {
  if (!value) return []
  const list = Array.isArray(value) ? value : [value]
  return list.map((item) => item.trim()).filter((item) => item.length > 0)
}

/**
 * Derives the standard Supabase Auth issuer URL from a Supabase JWKS endpoint URL when possible.
 */
function deriveIssuerFromJwksUrl(jwksUrl: string | undefined): string | undefined {
  if (!jwksUrl) return undefined
  const trimmed = jwksUrl.trim()
  const suffix = '/.well-known/jwks.json'
  if (trimmed.endsWith(suffix)) {
    return trimmed.slice(0, -suffix.length)
  }
  return undefined
}

/**
 * Checks whether a token's `aud` claim matches at least one expected audience value.
 */
function matchesAudienceClaim(audClaim: unknown, expectedAudiences: string[]): boolean {
  if (typeof audClaim === 'string') {
    return expectedAudiences.includes(audClaim)
  }
  if (Array.isArray(audClaim)) {
    return audClaim.some((item) => typeof item === 'string' && expectedAudiences.includes(item))
  }
  return false
}

/**
 * Checks whether a token's `iss` claim matches at least one expected issuer value.
 */
function matchesIssuerClaim(issClaim: unknown, expectedIssuers: string[]): boolean {
  return typeof issClaim === 'string' && expectedIssuers.includes(issClaim)
}

/**
 * Selects a JWK from a JWKS key set. When `kid` is supplied, requires an exact `kid` match.
 */
function matchKey(
  keys: JsonWebKeyWithKid[],
  kid: string | undefined,
  alg: string,
): JsonWebKeyWithKid | null {
  const expectedKty = alg === 'ES256' ? 'EC' : 'RSA'
  if (kid) {
    const byKid = keys.find(
      (k) => k.kid === kid && (!k.alg || k.alg === alg) && (!k.kty || k.kty === expectedKty),
    )
    return byKid ?? null
  }
  const byType = keys.find((k) => (!k.alg || k.alg === alg) && k.kty === expectedKty)
  return byType ?? null
}

/**
 * Verifies an ES256 or RS256 JWT signature against a JWK using Web Crypto.
 */
async function verifyWithJwk(
  jwk: JsonWebKey,
  alg: 'ES256' | 'RS256',
  signingInput: Uint8Array,
  signatureBytes: Uint8Array,
): Promise<boolean> {
  if (alg === 'ES256') {
    const cryptoKey = await crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify'],
    )
    return crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      cryptoKey,
      toArrayBuffer(signatureBytes),
      toArrayBuffer(signingInput),
    )
  }

  const cryptoKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  return crypto.subtle.verify(
    { name: 'RSASSA-PKCS1-v1_5' },
    cryptoKey,
    toArrayBuffer(signatureBytes),
    toArrayBuffer(signingInput),
  )
}

/**
 * Verifies an HS256 JWT signature against a shared HMAC secret using Web Crypto.
 */
async function verifyWithHmacSecret(
  secret: string,
  signingInput: Uint8Array,
  signatureBytes: Uint8Array,
): Promise<boolean> {
  const secretBytes = new TextEncoder().encode(secret)
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    toArrayBuffer(secretBytes),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  return crypto.subtle.verify(
    'HMAC',
    cryptoKey,
    toArrayBuffer(signatureBytes),
    toArrayBuffer(signingInput),
  )
}

/**
 * Decodes a base64url-encoded string into a Uint8Array.
 */
function base64UrlDecode(input: string): Uint8Array {
  const base64 = input.replace(/-/g, '+').replace(/_/g, '/')
  const padLength = (4 - (base64.length % 4)) % 4
  const padded = base64 + '='.repeat(padLength)
  return new Uint8Array(Buffer.from(padded, 'base64'))
}

/**
 * Extracts a standalone ArrayBuffer slice from a Uint8Array.
 */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}
