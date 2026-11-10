import { randomUUID } from 'node:crypto'
import {
  createGitHubWebhookHandler,
  type GitHubWebhookOptions,
} from '../adapters/sinks/github.js'
import { HollerKitError } from '../errors.js'
import {
  apiKeys,
  apiKeysAuthenticator,
  extractBearerToken,
  generateApiKey,
  getApiKeyPrefix,
  staticTokens,
  supabaseJwt,
  type ApiKeysAuthOptions,
  type Authenticator,
  type AuthPrincipal,
  type JwtClaims,
  type SupabaseJwtOptions,
} from './auth.js'
import { defaultV1Limits, resolveV1Limits, type V1LimitConfig } from './limits.js'
import {
  flushOutbox,
  shouldEnqueueSink,
  validateUniqueSinks,
  type HollerKitSink,
} from './sinks.js'
import {
  hashApiKey,
  type AttachmentKind,
  type FeedbackAttachmentInput,
  type FeedbackEventInput,
  type FeedbackKind,
  type HollerKitStore,
  type QuestDefinitionInput,
  type QuestRecordMode,
  type QuestResult,
  type QuestStatus,
  type Scope,
  type TriageStatus,
} from './store.js'

export {
  apiKeys,
  apiKeysAuthenticator,
  defaultV1Limits,
  extractBearerToken,
  generateApiKey,
  getApiKeyPrefix,
  resolveV1Limits,
  staticTokens,
  supabaseJwt,
  type ApiKeysAuthOptions,
  type Authenticator,
  type AuthPrincipal,
  type JwtClaims,
  type SupabaseJwtOptions,
  type V1LimitConfig,
}

export interface HollerKitStorageAdapter {
  presignUpload(input: {
    key: string
    mimeType: string
    size: number
    expiresInSeconds?: number | undefined
  }): Promise<{ url: string; expiresAt: string }>
  signReadUrl(input: {
    key: string
    expiresInSeconds?: number | undefined
  }): Promise<{ url: string; expiresAt: string }>
}

export interface CreateHollerKitServerOptions {
  store: HollerKitStore
  storage: HollerKitStorageAdapter
  authenticate: Authenticator | Authenticator[]
  basePath?: string | undefined
  /**
   * Optional notification sinks enrolled in `hollerkit.outbox` when matching feedback is created.
   * Deployments that configure `sinks` can either set `autoFlushOutbox` (`true` / `'sync'` / `'background'`)
   * or invoke `flushOutbox({ store, storage, sinks })` manually.
   */
  sinks?: Array<HollerKitSink | string> | undefined
  /**
   * When enabled (`true` / `'sync'` or `'background'`), automatically invokes `flushOutbox`
   * after `POST /v1/feedback` enqueues matching sinks.
   */
  autoFlushOutbox?: boolean | 'sync' | 'background' | undefined
  /**
   * Optional read URL lifetime in seconds used when signing attachment URLs during `autoFlushOutbox`.
   * Defaults to 7 days (`604_800` seconds).
   */
  sinkReadUrlTtlSeconds?: number | undefined
  /**
   * Optional background task hook (e.g. `EdgeRuntime.waitUntil`) used when `autoFlushOutbox === 'background'`.
   */
  waitUntil?: ((promise: Promise<unknown>) => void) | undefined
  /**
   * Optional GitHub webhook configuration mounted at `POST /v1/webhooks/github` to synchronize
   * issue close/reopen events back to `hollerkit.triage` and `hollerkit.feedback`.
   */
  githubWebhook?: Omit<GitHubWebhookOptions, 'store' | 'now'> | undefined
  limits?: Partial<V1LimitConfig> | undefined
  now?: (() => Date) | undefined
}

/**
 * Creates a deterministic in-memory storage adapter for tests and conformance runs.
 */
export function fakeStorage(options: { baseUrl?: string; now?: () => Date } = {}): HollerKitStorageAdapter {
  const baseUrl = (options.baseUrl ?? 'https://storage.hollerkit.test').replace(/\/$/, '')
  const nowFn = options.now ?? (() => new Date())

  return {
    async presignUpload(input) {
      const ttl = input.expiresInSeconds ?? 600
      const expiresAt = new Date(nowFn().getTime() + ttl * 1000).toISOString()
      return {
        url: `${baseUrl}/upload/${encodeURIComponent(input.key)}?expires=${encodeURIComponent(expiresAt)}`,
        expiresAt,
      }
    },
    async signReadUrl(input) {
      const ttl = input.expiresInSeconds ?? 3600
      const expiresAt = new Date(nowFn().getTime() + ttl * 1000).toISOString()
      return {
        url: `${baseUrl}/read/${encodeURIComponent(input.key)}?expires=${encodeURIComponent(expiresAt)}`,
        expiresAt,
      }
    },
  }
}

const VALID_SCOPES = new Set<Scope>(['tester', 'quests:write', 'agent:read', 'agent:triage'])
const VALID_RECORD_MODES = new Set<QuestRecordMode>(['none', 'optional', 'suggested', 'required'])
const VALID_QUEST_STATUSES = new Set<QuestStatus>(['draft', 'active', 'superseded', 'retired'])
const VALID_FEEDBACK_KINDS = new Set<FeedbackKind>(['report', 'quest_run'])
const VALID_QUEST_RESULTS = new Set<QuestResult>(['pass', 'fail', 'unsure', 'abandoned'])
const VALID_TRIAGE_STATUSES = new Set<TriageStatus>(['new', 'triaged', 'resolved', 'wontfix', 'duplicate'])
const VALID_ATTACHMENT_KINDS = new Set<AttachmentKind>(['image', 'audio', 'video', 'keyframe', 'mark'])
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Creates the HollerKit v1 Web Fetch handler `(request: Request) => Promise<Response>`.
 */
export function createHollerKitServer(
  options: CreateHollerKitServerOptions,
): (request: Request) => Promise<Response> {
  const limits = resolveV1Limits(options.limits)
  const nowFn = options.now ?? (() => new Date())
  const authenticators = Array.isArray(options.authenticate)
    ? options.authenticate
    : [options.authenticate]
  const sinksByName = validateUniqueSinks(options.sinks ?? [])
  const configuredSinkNames = Array.from(sinksByName.keys())
  const executableSinks: HollerKitSink[] = []
  for (const sink of sinksByName.values()) {
    if (typeof sink !== 'string') {
      executableSinks.push(sink)
    }
  }
  const sinkReadUrlTtlSeconds = options.sinkReadUrlTtlSeconds ?? 604_800
  const scheduleBackgroundWork = (promise: Promise<unknown>): void => {
    const globalEdgeRuntime = (
      globalThis as unknown as {
        EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void }
      }
    ).EdgeRuntime
    if (options.waitUntil) {
      options.waitUntil(promise)
    } else if (typeof globalEdgeRuntime?.waitUntil === 'function') {
      globalEdgeRuntime.waitUntil(promise)
    }
  }
  const gitHubWebhookHandler = options.githubWebhook
    ? createGitHubWebhookHandler({
        reconcileFeedbackOutbox:
          executableSinks.length > 0
            ? async (targetFeedbackId: string) => {
                await flushOutbox({
                  store: options.store,
                  storage: options.storage,
                  sinks: executableSinks,
                  feedbackId: targetFeedbackId,
                  limit: executableSinks.length,
                  deliveryTimeoutMs: 10_000,
                  now: nowFn,
                  readUrlTtlSeconds: sinkReadUrlTtlSeconds,
                })
              }
            : undefined,
        ...options.githubWebhook,
        store: options.store,
        now: nowFn,
      })
    : null

  return async function hollerKitV1Handler(request: Request): Promise<Response> {
    try {
      const protocolHeader = request.headers.get('hollerkit-protocol')
      if (protocolHeader !== null && protocolHeader.trim() !== '1') {
        throw new HollerKitError(
          400,
          'unsupported_protocol',
          `Unsupported hollerkit-protocol version: ${protocolHeader}. Expected 1.`,
        )
      }

      const url = new URL(request.url)
      const routePath = normalizeV1Path(url.pathname, options.basePath)
      if (!routePath) {
        throw new HollerKitError(404, 'not_found', `Route not found: ${url.pathname}`)
      }

      const method = request.method.toUpperCase()

      // 1. POST /v1/builds/{build}/manifest
      const buildManifestMatch = routePath.match(/^\/v1\/builds\/([^/]+)\/manifest$/)
      if (buildManifestMatch) {
        if (method !== 'POST') {
          throw new HollerKitError(405, 'method_not_allowed', 'Expected POST.')
        }
        await requireAuth(request, authenticators, ['tester'])
        const build = decodePathSegment(buildManifestMatch[1]!)
        const body = await readJsonObject(request, limits)
        const quests = parseQuestDefinitionArray(body.quests, 'quests')
        const appVersion = parseOptionalNullableString(body.appVersion, 'appVersion')

        const result = await options.store.syncBuildManifest({
          build,
          appVersion,
          quests,
          now: nowFn(),
        })

        return protocolJsonResponse({
          ok: true,
          build: result.build,
          pendingCount: result.pendingCount,
          quests: result.quests,
        })
      }

      // 9. GET /v1/builds/{build}/pending
      const buildPendingMatch = routePath.match(/^\/v1\/builds\/([^/]+)\/pending$/)
      if (buildPendingMatch) {
        if (method !== 'GET') {
          throw new HollerKitError(405, 'method_not_allowed', 'Expected GET.')
        }
        await requireAuth(request, authenticators, ['tester', 'agent:read'])
        const build = decodePathSegment(buildPendingMatch[1]!)
        const quests = await options.store.getPendingQuestsForBuild(build)
        return protocolJsonResponse({
          ok: true,
          build,
          pendingCount: quests.length,
          quests,
        })
      }

      // 2. POST /v1/uploads
      if (routePath === '/v1/uploads') {
        if (method !== 'POST') {
          throw new HollerKitError(405, 'method_not_allowed', 'Expected POST.')
        }
        const principal = await requireAuth(request, authenticators, ['tester'])
        const body = await readJsonObject(request, limits)

        const feedbackId = parseRequiredUuid(body.feedbackId, 'feedbackId')
        const kind = parseAttachmentKind(body.kind, 'kind')
        const mimeType = parseRequiredString(body.mimeType, 'mimeType')
        const size = parsePositiveInteger(body.size, 'size')

        validateUploadAttachmentLimits(kind, mimeType, size, limits)

        const now = nowFn()
        const ext = extensionForMimeType(mimeType, kind)
        const storageKey = `${feedbackId}/${randomUUID()}.${ext}`
        const presigned = await options.storage.presignUpload({
          key: storageKey,
          mimeType,
          size,
          expiresInSeconds: limits.uploadGrantTtlSeconds,
        })

        const maxGrantExpiryMs = now.getTime() + limits.uploadGrantTtlSeconds * 1000
        const presignedExpiryMs = Date.parse(presigned.expiresAt)
        const grantExpiresAt = Number.isNaN(presignedExpiryMs)
          ? new Date(maxGrantExpiryMs).toISOString()
          : new Date(Math.min(presignedExpiryMs, maxGrantExpiryMs)).toISOString()

        await options.store.createUploadGrant({
          storageKey,
          feedbackId,
          submitterId: principal.principalId,
          kind,
          mimeType,
          size,
          expiresAt: grantExpiresAt,
          now,
        })

        return protocolJsonResponse({
          ok: true,
          key: storageKey,
          url: presigned.url,
          expiresAt: grantExpiresAt,
        })
      }

      // 3. POST /v1/feedback & 5. GET /v1/feedback
      if (routePath === '/v1/feedback') {
        if (method === 'POST') {
          const principal = await requireAuth(request, authenticators, ['tester'])
          const body = await readJsonObject(request, limits)
          const parsed = parseFeedbackCreateBody(body, limits)

          // Selected sinks are persisted atomically with feedback creation inside store.createFeedback.
          // Deployments configuring `sinks` must run `flushOutbox({ store, storage, sinks })` to deliver them.
          const now = nowFn()
          const created = await options.store.createFeedback({
            ...parsed,
            submitterId: principal.principalId,
            ...(configuredSinkNames.length > 0
              ? {
                  sinks: configuredSinkNames,
                  shouldEnqueueSink: (sinkName, feedback) => {
                    const registered = sinksByName.get(sinkName) ?? sinkName
                    return shouldEnqueueSink(registered, feedback)
                  },
                }
              : {}),
            now,
          })

          let feedbackResponse = created.feedback
          if (!created.idempotent && options.autoFlushOutbox && executableSinks.length > 0) {
            if (options.autoFlushOutbox === 'background') {
              const backgroundFlush = flushOutbox({
                store: options.store,
                storage: options.storage,
                sinks: executableSinks,
                now: nowFn,
                readUrlTtlSeconds: sinkReadUrlTtlSeconds,
              }).catch((err) => {
                console.error('[hollerkit] autoFlushOutbox failed', err)
              })
              scheduleBackgroundWork(backgroundFlush)
            } else {
              // Scope synchronous request-bound flush strictly to the newly created feedback item
              // with a bounded timeout, then drain any remaining pending backlog asynchronously.
              await flushOutbox({
                store: options.store,
                storage: options.storage,
                sinks: executableSinks,
                feedbackId: created.feedback.id,
                limit: executableSinks.length,
                deliveryTimeoutMs: 10_000,
                now: nowFn,
                readUrlTtlSeconds: sinkReadUrlTtlSeconds,
              }).catch((err) => {
                console.error('[hollerkit] autoFlushOutbox sync failed', err)
              })

              const refreshed = await options.store.getFeedbackById(created.feedback.id)
              if (refreshed) {
                feedbackResponse = refreshed.feedback
              }

              const backlogDrain = flushOutbox({
                store: options.store,
                storage: options.storage,
                sinks: executableSinks,
                limit: 5,
                deliveryTimeoutMs: 10_000,
                now: nowFn,
                readUrlTtlSeconds: sinkReadUrlTtlSeconds,
              }).catch((err) => {
                console.error('[hollerkit] autoFlushOutbox backlog drain failed', err)
              })
              scheduleBackgroundWork(backlogDrain)
            }
          }

          return protocolJsonResponse(
            {
              ok: true,
              idempotent: created.idempotent,
              feedback: feedbackResponse,
            },
            created.idempotent ? 200 : 201,
          )
        }

        if (method === 'GET') {
          await requireAuth(request, authenticators, ['agent:read'])
          const filter = parseListFeedbackQuery(url.searchParams)
          const result = await options.store.listFeedback(filter)
          return protocolJsonResponse({
            ok: true,
            items: result.items,
            nextCursor: result.nextCursor,
          })
        }

        throw new HollerKitError(405, 'method_not_allowed', 'Expected GET or POST.')
      }

      // 6. GET /v1/feedback/{id}
      const feedbackDetailMatch = routePath.match(/^\/v1\/feedback\/([^/]+)$/)
      if (feedbackDetailMatch) {
        if (method !== 'GET') {
          throw new HollerKitError(405, 'method_not_allowed', 'Expected GET.')
        }
        await requireAuth(request, authenticators, ['agent:read'])
        const feedbackId = decodePathSegment(feedbackDetailMatch[1]!).trim().toLowerCase()
        const detail = await options.store.getFeedbackById(feedbackId)
        if (!detail) {
          throw new HollerKitError(404, 'not_found', `Feedback not found: ${feedbackId}.`)
        }

        const signedAttachments = await Promise.all(
          detail.attachments.map(async (att) => {
            const signed = await options.storage.signReadUrl({
              key: att.key,
              expiresInSeconds: limits.readUrlTtlSeconds,
            })
            return {
              id: att.id,
              feedbackId: att.feedbackId,
              kind: att.kind,
              key: att.key,
              mimeType: att.mimeType,
              size: att.size,
              offsetSeconds: att.offsetSeconds,
              videoStartOffsetSeconds: att.videoStartOffsetSeconds,
              url: signed.url,
              expiresAt: signed.expiresAt,
              createdAt: att.createdAt,
            }
          }),
        )

        return protocolJsonResponse({
          ok: true,
          feedback: detail.feedback,
          quest: detail.quest,
          events: detail.events,
          triage: detail.triage,
          attachments: signedAttachments,
        })
      }

      // 7. PUT /v1/feedback/{id}/triage
      const feedbackTriageMatch = routePath.match(/^\/v1\/feedback\/([^/]+)\/triage$/)
      if (feedbackTriageMatch) {
        if (method !== 'PUT') {
          throw new HollerKitError(405, 'method_not_allowed', 'Expected PUT.')
        }
        const principal = await requireAuth(request, authenticators, ['agent:triage'])
        const feedbackId = decodePathSegment(feedbackTriageMatch[1]!).trim().toLowerCase()
        const body = await readJsonObject(request, limits)

        const status = parseTriageStatus(body.status, 'status')
        const summary = parseRequiredString(body.summary, 'summary')
        if (summary.length > limits.maxTextChars) {
          throw new HollerKitError(413, 'text_too_large', 'summary exceeds maximum character limit.')
        }
        const links = parseOptionalStringArray(body.links, 'links')
        const actor = parseOptionalNullableString(body.actor, 'actor') ?? principal.label ?? principal.principalId

        const updated = await options.store.triageFeedback({
          feedbackId,
          status,
          summary,
          links,
          actor,
          now: nowFn(),
        })

        return protocolJsonResponse({
          ok: true,
          feedback: updated.feedback,
          triage: updated.triage,
        })
      }

      // 4. PUT /v1/quests & 8. GET /v1/quests
      if (routePath === '/v1/quests') {
        if (method === 'PUT') {
          await requireAuth(request, authenticators, ['quests:write'])
          const body = await readJsonObject(request, limits)
          if (body.version !== undefined && body.version !== 1) {
            throw new HollerKitError(400, 'invalid_manifest_version', 'Manifest version must be 1.')
          }
          const quests = parseQuestDefinitionArray(body.quests, 'quests')
          const sha = parseOptionalNullableString(body.sha, 'sha')
          const pr = parseOptionalNullableInteger(body.pr, 'pr')

          const synced = await options.store.syncQuests({
            quests,
            sha,
            pr,
            now: nowFn(),
          })

          return protocolJsonResponse({
            ok: true,
            quests: synced.quests,
            activatedIds: synced.activatedIds ?? [],
            reactivatedIds: synced.reactivatedIds ?? [],
            retiredIds: synced.retiredIds,
          })
        }

        if (method === 'GET') {
          await requireAuth(request, authenticators, ['agent:read'])
          const statusParam = url.searchParams.get('status')
          let status: QuestStatus | undefined
          if (statusParam !== null && statusParam !== '') {
            if (!VALID_QUEST_STATUSES.has(statusParam as QuestStatus)) {
              throw new HollerKitError(400, 'invalid_status', `Invalid quest status filter: ${statusParam}.`)
            }
            status = statusParam as QuestStatus
          }

          const areaParam = url.searchParams.get('area')
          const area = areaParam && areaParam.trim().length > 0 ? areaParam.trim() : undefined

          const passedParam = url.searchParams.get('passedOnCurrentVersion')
          let passedOnCurrentVersion: boolean | undefined
          if (passedParam !== null && passedParam !== '') {
            if (passedParam === 'true') passedOnCurrentVersion = true
            else if (passedParam === 'false') passedOnCurrentVersion = false
            else {
              throw new HollerKitError(
                400,
                'invalid_filter',
                'passedOnCurrentVersion must be "true" or "false".',
              )
            }
          }

          const quests = await options.store.listQuests({
            status,
            area,
            passedOnCurrentVersion,
          })

          return protocolJsonResponse({
            ok: true,
            quests,
          })
        }

        throw new HollerKitError(405, 'method_not_allowed', 'Expected GET or PUT.')
      }

      // 10. POST /v1/webhooks/github
      if (routePath === '/v1/webhooks/github') {
        if (!gitHubWebhookHandler) {
          throw new HollerKitError(404, 'not_found', `Route not found: ${routePath}`)
        }
        return gitHubWebhookHandler(request)
      }

      throw new HollerKitError(404, 'not_found', `Route not found: ${routePath}`)
    } catch (error) {
      return protocolErrorResponse(error)
    }
  }
}

/**
 * Strips any configured `basePath` prefix and normalizes `/v1/*` route paths.
 */
function normalizeV1Path(pathname: string, basePath?: string): string | null {
  let cleaned = pathname.replace(/\/+$/, '') || '/'
  if (basePath) {
    const normalizedBase = ('/' + basePath.replace(/^\/+|\/+$/g, '')).replace(/\/+$/, '')
    if (normalizedBase !== '/' && cleaned.startsWith(normalizedBase + '/')) {
      cleaned = cleaned.slice(normalizedBase.length)
    } else if (normalizedBase !== '/' && cleaned === normalizedBase) {
      cleaned = '/'
    }
  }
  const routeMatch = cleaned.match(
    /\/v1(?=\/(?:builds|uploads|feedback|quests|webhooks)(?:\/|$)|$).*$/,
  )
  if (routeMatch) {
    return routeMatch[0]
  }
  if (cleaned === '/v1' || cleaned.startsWith('/v1/')) {
    return cleaned
  }
  return null
}

/**
 * URL-decodes a single path segment or throws `400 invalid_path`.
 */
function decodePathSegment(segment: string): string {
  try {
    return decodeURIComponent(segment)
  } catch {
    throw new HollerKitError(400, 'invalid_path', 'Malformed URL path parameter.')
  }
}

/**
 * Authenticates the incoming request and verifies it holds at least one required scope.
 */
async function requireAuth(
  request: Request,
  authenticators: Authenticator[],
  anyOfScopes: Scope[],
): Promise<AuthPrincipal> {
  const token = extractBearerToken(request)
  if (!token) {
    throw new HollerKitError(401, 'unauthorized', 'Missing or invalid Authorization Bearer token.')
  }

  let principal: AuthPrincipal | null = null
  for (const auth of authenticators) {
    principal = await auth(request)
    if (principal) break
  }

  if (!principal) {
    throw new HollerKitError(401, 'unauthorized', 'Invalid or expired authentication credentials.')
  }

  const hasScope = anyOfScopes.some(
    (required) => VALID_SCOPES.has(required) && principal.scopes.includes(required),
  )
  if (!hasScope) {
    throw new HollerKitError(
      403,
      'forbidden',
      `Insufficient scope. Required one of: ${anyOfScopes.join(', ')}.`,
    )
  }

  return principal
}

/**
 * Reads and parses a bounded JSON object body from the request.
 */
async function readJsonObject(request: Request, limits: V1LimitConfig): Promise<Record<string, unknown>> {
  const contentLengthHeader = request.headers.get('content-length')
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader)
    if (!Number.isInteger(contentLength) || contentLength < 0) {
      throw new HollerKitError(400, 'invalid_content_length', 'Content-Length must be a non-negative integer.')
    }
    if (contentLength > limits.maxJsonBytes) {
      throw new HollerKitError(413, 'body_too_large', 'JSON payload exceeds maximum byte limit.')
    }
  }

  const buffer = await readBoundedBody(request, limits.maxJsonBytes)
  const text = new TextDecoder().decode(buffer)
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new HollerKitError(400, 'invalid_json', 'Request body must be valid JSON.')
  }

  if (!isPlainObject(parsed)) {
    throw new HollerKitError(400, 'invalid_json', 'Request body must be a JSON object.')
  }

  return parsed
}

/**
 * Streams a request body up to `maxBytes`, throwing `413 body_too_large` if exceeded.
 */
async function readBoundedBody(request: Request, maxBytes: number): Promise<Uint8Array> {
  if (!request.body) {
    return new Uint8Array(0)
  }

  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let totalBytes = 0

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      totalBytes += value.byteLength
      if (totalBytes > maxBytes) {
        await reader.cancel()
        throw new HollerKitError(413, 'body_too_large', 'JSON payload exceeds maximum byte limit.')
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }

  const merged = new Uint8Array(totalBytes)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return merged
}

/**
 * Validates an upload grant's MIME type and byte size against configured server limits.
 */
function validateUploadAttachmentLimits(
  kind: AttachmentKind,
  mimeType: string,
  size: number,
  limits: V1LimitConfig,
): void {
  const normalizedMime = mimeType.toLowerCase()
  if (kind === 'image' || kind === 'keyframe' || kind === 'mark') {
    if (!limits.acceptedImageMimeTypes.includes(normalizedMime)) {
      throw new HollerKitError(415, 'unsupported_media_type', `Unsupported image MIME type: ${mimeType}.`)
    }
    if (size > limits.maxImageBytes) {
      throw new HollerKitError(413, 'image_too_large', 'Image size exceeds maximum byte limit.')
    }
    return
  }

  if (kind === 'audio') {
    if (!limits.acceptedAudioMimeTypes.includes(normalizedMime)) {
      throw new HollerKitError(415, 'unsupported_media_type', `Unsupported audio MIME type: ${mimeType}.`)
    }
    if (size > limits.maxAudioBytes) {
      throw new HollerKitError(413, 'audio_too_large', 'Audio size exceeds maximum byte limit.')
    }
    return
  }

  if (kind === 'video') {
    if (!limits.acceptedVideoMimeTypes.includes(normalizedMime)) {
      throw new HollerKitError(415, 'unsupported_media_type', `Unsupported video MIME type: ${mimeType}.`)
    }
    if (limits.maxVideoBytes !== undefined && size > limits.maxVideoBytes) {
      throw new HollerKitError(413, 'video_too_large', 'Video size exceeds maximum byte limit.')
    }
  }
}

/**
 * Parses and validates the JSON body of `POST /v1/feedback`.
 */
function parseFeedbackCreateBody(body: Record<string, unknown>, limits: V1LimitConfig) {
  const id = parseRequiredUuid(body.id, 'id')
  const kindRaw = body.kind
  if (typeof kindRaw !== 'string' || !VALID_FEEDBACK_KINDS.has(kindRaw as FeedbackKind)) {
    throw new HollerKitError(400, 'invalid_kind', 'kind must be "report" or "quest_run".')
  }
  const kind = kindRaw as FeedbackKind

  const build = parseRequiredString(body.build, 'build')
  const questId = parseOptionalNullableString(body.questId, 'questId')
  const questVersion = parseOptionalNullableInteger(body.questVersion, 'questVersion')

  let result: QuestResult | null = null
  if (body.result !== undefined && body.result !== null) {
    if (typeof body.result !== 'string' || !VALID_QUEST_RESULTS.has(body.result as QuestResult)) {
      throw new HollerKitError(
        400,
        'invalid_result',
        'result must be one of "pass", "fail", "unsure", "abandoned".',
      )
    }
    result = body.result as QuestResult
  }

  if (kind === 'quest_run') {
    if (!questId) {
      throw new HollerKitError(400, 'missing_quest_id', 'quest_run requires questId.')
    }
    if (!result) {
      throw new HollerKitError(400, 'missing_result', 'quest_run requires result.')
    }
  }

  const comment = parseOptionalNullableString(body.comment, 'comment')
  if (comment && comment.length > limits.maxTextChars) {
    throw new HollerKitError(413, 'text_too_large', 'comment exceeds maximum character limit.')
  }

  const transcript = parseOptionalNullableString(body.transcript, 'transcript')
  if (transcript && transcript.length > limits.maxTextChars) {
    throw new HollerKitError(413, 'text_too_large', 'transcript exceeds maximum character limit.')
  }

  const appVersion = parseOptionalNullableString(body.appVersion, 'appVersion')
  const device = parseOptionalNullableString(body.device, 'device')
  const os = parseOptionalNullableString(body.os, 'os')
  const startedAt = parseOptionalIsoTimestamp(body.startedAt, 'startedAt')
  const endedAt = parseOptionalIsoTimestamp(body.endedAt, 'endedAt')

  let metadata: Record<string, unknown> = {}
  if (body.metadata !== undefined && body.metadata !== null) {
    if (!isPlainObject(body.metadata)) {
      throw new HollerKitError(400, 'invalid_metadata', 'metadata must be a JSON object.')
    }
    metadata = body.metadata
  }

  let stepsChecked: boolean[] = []
  if (body.stepsChecked !== undefined && body.stepsChecked !== null) {
    if (!Array.isArray(body.stepsChecked) || !body.stepsChecked.every((v) => typeof v === 'boolean')) {
      throw new HollerKitError(400, 'invalid_steps_checked', 'stepsChecked must be an array of booleans.')
    }
    stepsChecked = body.stepsChecked
  }

  const events: FeedbackEventInput[] = []
  if (body.events !== undefined && body.events !== null) {
    if (!Array.isArray(body.events)) {
      throw new HollerKitError(400, 'invalid_events', 'events must be an array.')
    }
    for (let i = 0; i < body.events.length; i++) {
      const item = body.events[i]
      if (!isPlainObject(item) || typeof item.kind !== 'string' || item.kind.trim().length === 0) {
        throw new HollerKitError(400, 'invalid_events', `events[${i}] requires a non-empty kind string.`)
      }
      const offsetSeconds =
        item.offsetSeconds !== undefined && item.offsetSeconds !== null
          ? parseFiniteNumber(item.offsetSeconds, `events[${i}].offsetSeconds`)
          : 0
      const payload =
        item.payload !== undefined && item.payload !== null
          ? isPlainObject(item.payload)
            ? item.payload
            : (() => {
                throw new HollerKitError(400, 'invalid_events', `events[${i}].payload must be an object.`)
              })()
          : {}
      events.push({
        kind: item.kind.trim(),
        offsetSeconds,
        payload,
      })
    }
  }

  const attachments: FeedbackAttachmentInput[] = []
  if (body.attachments !== undefined && body.attachments !== null) {
    if (!Array.isArray(body.attachments)) {
      throw new HollerKitError(400, 'invalid_attachments', 'attachments must be an array.')
    }
    for (let i = 0; i < body.attachments.length; i++) {
      const item = body.attachments[i]
      if (!isPlainObject(item)) {
        throw new HollerKitError(400, 'invalid_attachments', `attachments[${i}] must be an object.`)
      }
      const key = parseRequiredString(item.key, `attachments[${i}].key`)
      const attKind =
        item.kind !== undefined && item.kind !== null
          ? parseAttachmentKind(item.kind, `attachments[${i}].kind`)
          : 'image'
      const mimeType = parseOptionalNullableString(item.mimeType, `attachments[${i}].mimeType`) ?? undefined
      const size =
        item.size !== undefined && item.size !== null
          ? parsePositiveInteger(item.size, `attachments[${i}].size`)
          : undefined
      if (size !== undefined && (attKind === 'image' || attKind === 'keyframe' || attKind === 'mark')) {
        if (size > limits.maxImageBytes) {
          throw new HollerKitError(413, 'image_too_large', 'Image attachment exceeds maximum byte limit.')
        }
      }
      const offsetSeconds =
        item.offsetSeconds !== undefined && item.offsetSeconds !== null
          ? parseFiniteNumber(item.offsetSeconds, `attachments[${i}].offsetSeconds`)
          : null
      const videoStartOffsetSeconds =
        item.videoStartOffsetSeconds !== undefined && item.videoStartOffsetSeconds !== null
          ? parseFiniteNumber(item.videoStartOffsetSeconds, `attachments[${i}].videoStartOffsetSeconds`)
          : null

      attachments.push({
        key,
        kind: attKind,
        mimeType,
        size,
        offsetSeconds,
        videoStartOffsetSeconds,
      })
    }
  }

  const imageCount = attachments.filter((a) => a.kind === 'image').length
  if (imageCount > limits.maxImages) {
    throw new HollerKitError(413, 'too_many_images', `Image count (${imageCount}) exceeds limit (${limits.maxImages}).`)
  }

  const markEventsCount = events.filter((e) => e.kind === 'mark').length
  const markAttachmentsCount = attachments.filter((a) => a.kind === 'mark').length
  if (markEventsCount > limits.maxMarks || markAttachmentsCount > limits.maxMarks) {
    throw new HollerKitError(413, 'too_many_marks', `Mark count exceeds limit (${limits.maxMarks}).`)
  }

  return {
    id,
    kind,
    questId,
    questVersion,
    result,
    build,
    appVersion,
    device,
    os,
    comment,
    transcript,
    metadata,
    stepsChecked,
    startedAt,
    endedAt,
    events,
    attachments,
  }
}

/**
 * Parses and validates query parameters for `GET /v1/feedback`.
 */
function parseListFeedbackQuery(params: URLSearchParams) {
  const kindParam = params.get('kind')
  let kind: FeedbackKind | undefined
  if (kindParam) {
    if (!VALID_FEEDBACK_KINDS.has(kindParam as FeedbackKind)) {
      throw new HollerKitError(400, 'invalid_kind', `Invalid kind filter: ${kindParam}.`)
    }
    kind = kindParam as FeedbackKind
  }

  const resultParam = params.get('result')
  let result: QuestResult | undefined
  if (resultParam) {
    if (!VALID_QUEST_RESULTS.has(resultParam as QuestResult)) {
      throw new HollerKitError(400, 'invalid_result', `Invalid result filter: ${resultParam}.`)
    }
    result = resultParam as QuestResult
  }

  const triageParam = params.get('triage')
  let triage: TriageStatus | undefined
  if (triageParam) {
    if (!VALID_TRIAGE_STATUSES.has(triageParam as TriageStatus)) {
      throw new HollerKitError(400, 'invalid_triage', `Invalid triage filter: ${triageParam}.`)
    }
    triage = triageParam as TriageStatus
  }

  const area = params.get('area') || undefined
  const sinceRaw = params.get('since')
  let since: string | undefined
  if (sinceRaw !== null && sinceRaw !== '') {
    const ms = Date.parse(sinceRaw)
    if (Number.isNaN(ms)) {
      throw new HollerKitError(400, 'invalid_since', 'since must be a valid ISO-8601 timestamp.')
    }
    since = new Date(ms).toISOString()
  }
  const build = params.get('build') || undefined
  const questId = params.get('questId') || undefined
  const cursor = params.get('cursor') || undefined

  const limitParam = params.get('limit')
  let limit: number | undefined
  if (limitParam !== null && limitParam !== '') {
    const parsed = Number(limitParam)
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 200) {
      throw new HollerKitError(400, 'invalid_limit', 'limit must be an integer between 1 and 200.')
    }
    limit = parsed
  }

  return {
    kind,
    result,
    triage,
    area,
    since,
    build,
    questId,
    limit,
    cursor,
  }
}

/**
 * Parses and validates a top-level `hollerkit-quests.json` manifest object.
 */
export function parseQuestManifest(raw: unknown): { version: 1; quests: QuestDefinitionInput[] } {
  if (!isPlainObject(raw)) {
    throw new HollerKitError(400, 'invalid_manifest', 'Quest manifest must be a JSON object.')
  }
  if (raw.version !== 1) {
    throw new HollerKitError(400, 'invalid_manifest_version', 'Manifest version must be 1.')
  }
  const quests = parseQuestDefinitionArray(raw.quests, 'quests')
  return { version: 1, quests }
}

/**
 * Parses and validates an array of quest definition objects.
 */
export function parseQuestDefinitionArray(value: unknown, field: string): QuestDefinitionInput[] {
  if (!Array.isArray(value)) {
    throw new HollerKitError(400, 'invalid_quests', `${field} must be an array of quest definitions.`)
  }

  const seenIds = new Set<string>()
  return value.map((item, idx) => {
    if (!isPlainObject(item)) {
      throw new HollerKitError(400, 'invalid_quest', `${field}[${idx}] must be an object.`)
    }
    const id = parseRequiredString(item.id, `${field}[${idx}].id`)
    if (seenIds.has(id)) {
      throw new HollerKitError(400, 'duplicate_quest_id', `Duplicate quest id in manifest: ${id}.`)
    }
    seenIds.add(id)

    const title = parseRequiredString(item.title, `${field}[${idx}].title`)
    const area = parseRequiredString(item.area, `${field}[${idx}].area`)
    const steps = parseRequiredNonEmptyStringArray(item.steps, `${field}[${idx}].steps`)
    const expect = parseRequiredNonEmptyStringArray(item.expect, `${field}[${idx}].expect`)
    const setup = parseOptionalStringArray(item.setup, `${field}[${idx}].setup`) ?? []
    const needs = parseOptionalStringArray(item.needs, `${field}[${idx}].needs`) ?? []

    let record: QuestRecordMode = 'optional'
    if (item.record !== undefined && item.record !== null) {
      if (typeof item.record !== 'string' || !VALID_RECORD_MODES.has(item.record as QuestRecordMode)) {
        throw new HollerKitError(
          400,
          'invalid_record_mode',
          `${field}[${idx}].record must be one of none, optional, suggested, required.`,
        )
      }
      record = item.record as QuestRecordMode
    }

    const start = parseOptionalNullableString(item.start, `${field}[${idx}].start`)
    const contentHash = parseOptionalNullableString(item.contentHash, `${field}[${idx}].contentHash`)

    let source: QuestDefinitionInput['source']
    if (item.source !== undefined && item.source !== null) {
      if (!isPlainObject(item.source)) {
        throw new HollerKitError(400, 'invalid_source', `${field}[${idx}].source must be an object.`)
      }
      source = {
        pr: parseOptionalNullableInteger(item.source.pr, `${field}[${idx}].source.pr`),
        sha: parseOptionalNullableString(item.source.sha, `${field}[${idx}].source.sha`),
        added: parseOptionalNullableString(item.source.added, `${field}[${idx}].source.added`),
      }
    }

    return {
      id,
      contentHash,
      title,
      area,
      setup,
      steps,
      expect,
      needs,
      record,
      start,
      source,
    }
  })
}

/**
 * Validates and normalizes a required UUID string field.
 */
function parseRequiredUuid(value: unknown, field: string): string {
  if (typeof value !== 'string' || !UUID_REGEX.test(value.trim())) {
    throw new HollerKitError(400, 'invalid_uuid', `${field} must be a valid UUID.`)
  }
  return value.trim().toLowerCase()
}

/**
 * Validates and trims a required non-empty string field.
 */
function parseRequiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a non-empty string.`)
  }
  return value.trim()
}

/**
 * Validates an optional string field, returning `null` when omitted or empty.
 */
function parseOptionalNullableString(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a string.`)
  }
  return value
}

/**
 * Validates an optional ISO-8601 timestamp string field.
 */
function parseOptionalIsoTimestamp(value: unknown, field: string): string | null {
  const str = parseOptionalNullableString(value, field)
  if (str === null) return null
  const ms = Date.parse(str)
  if (Number.isNaN(ms)) {
    throw new HollerKitError(400, 'invalid_timestamp', `${field} must be a valid ISO-8601 timestamp.`)
  }
  return new Date(ms).toISOString()
}

/**
 * Validates an optional integer field, returning `null` when omitted.
 */
function parseOptionalNullableInteger(value: unknown, field: string): number | null {
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be an integer.`)
  }
  return value
}

/**
 * Validates a required positive integer field.
 */
function parsePositiveInteger(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value <= 0) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a positive integer.`)
  }
  return value
}

/**
 * Validates a required finite number field.
 */
function parseFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a finite number.`)
  }
  return value
}

/**
 * Validates a required non-empty array of non-empty strings.
 */
function parseRequiredNonEmptyStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a non-empty array of strings.`)
  }
  return value.map((item, idx) => parseRequiredString(item, `${field}[${idx}]`))
}

/**
 * Validates an optional array of non-empty strings.
 */
function parseOptionalStringArray(value: unknown, field: string): string[] | undefined {
  if (value === undefined || value === null) return undefined
  if (!Array.isArray(value)) {
    throw new HollerKitError(400, 'invalid_field', `${field} must be an array of strings.`)
  }
  return value.map((item, idx) => parseRequiredString(item, `${field}[${idx}]`))
}

/**
 * Validates an `AttachmentKind` value.
 */
function parseAttachmentKind(value: unknown, field: string): AttachmentKind {
  if (typeof value !== 'string' || !VALID_ATTACHMENT_KINDS.has(value as AttachmentKind)) {
    throw new HollerKitError(
      400,
      'invalid_attachment_kind',
      `${field} must be one of image, audio, video, keyframe, mark.`,
    )
  }
  return value as AttachmentKind
}

/**
 * Validates a `TriageStatus` value.
 */
function parseTriageStatus(value: unknown, field: string): TriageStatus {
  if (typeof value !== 'string' || !VALID_TRIAGE_STATUSES.has(value as TriageStatus)) {
    throw new HollerKitError(
      400,
      'invalid_triage_status',
      `${field} must be one of new, triaged, resolved, wontfix, duplicate.`,
    )
  }
  return value as TriageStatus
}

/**
 * Maps a MIME type and attachment kind to a canonical file extension.
 */
function extensionForMimeType(mimeType: string, kind: AttachmentKind): string {
  const lower = mimeType.toLowerCase()
  if (lower.includes('png')) return 'png'
  if (lower.includes('jpeg') || lower.includes('jpg')) return 'jpg'
  if (lower.includes('heic')) return 'heic'
  if (lower.includes('heif')) return 'heif'
  if (lower.includes('webp')) return 'webp'
  if (lower.includes('m4a') || lower.includes('aac')) return 'm4a'
  if (lower.includes('mp4')) return kind === 'audio' ? 'm4a' : 'mp4'
  if (lower.includes('quicktime')) return 'mov'
  return 'bin'
}

/**
 * Checks whether a value is a non-null, non-array plain object.
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Builds a JSON `Response` with the `hollerkit-protocol: 1` header.
 */
function protocolJsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      'hollerkit-protocol': '1',
    },
  })
}

/**
 * Converts an error into a standard `/v1` JSON error response.
 */
function protocolErrorResponse(error: unknown): Response {
  if (error instanceof HollerKitError) {
    return Response.json(
      { ok: false, error: { code: error.code, message: error.message } },
      {
        status: error.status,
        headers: {
          'hollerkit-protocol': '1',
        },
      },
    )
  }

  console.error('[hollerkit] unexpected v1 server error', error)

  return Response.json(
    { ok: false, error: { code: 'internal_error', message: 'Unexpected server error.' } },
    {
      status: 500,
      headers: {
        'hollerkit-protocol': '1',
      },
    },
  )
}
