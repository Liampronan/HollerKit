import type {
  FeedbackGetInput,
  FeedbackGetOutput,
  FeedbackInboxInput,
  FeedbackInboxOutput,
  FeedbackKind,
  FeedbackTriageInput,
  FeedbackTriageOutput,
  FetchLike,
  HollerKitMcpConfig,
  QuestResult,
  QuestsPendingInput,
  QuestsPendingOutput,
  QuestsRetirableInput,
  QuestsRetirableOutput,
  TriageStatus,
  ValueGroupBy,
  ValuesQueryInput,
  ValuesQueryResult,
} from './types.js'

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000

const VALID_FEEDBACK_KINDS = new Set<FeedbackKind>(['report', 'quest_run'])
const VALID_QUEST_RESULTS = new Set<QuestResult>(['pass', 'fail', 'unsure', 'abandoned'])
const VALID_TRIAGE_STATUSES = new Set<TriageStatus>([
  'new',
  'triaged',
  'resolved',
  'wontfix',
  'duplicate',
])

const FEEDBACK_INBOX_ALLOWED_KEYS = new Set([
  'kind',
  'result',
  'triage',
  'area',
  'since',
  'build',
  'questId',
  'limit',
  'cursor',
])
const FEEDBACK_GET_ALLOWED_KEYS = new Set(['id'])
const FEEDBACK_TRIAGE_ALLOWED_KEYS = new Set(['id', 'status', 'summary', 'links', 'actor'])
const QUESTS_PENDING_ALLOWED_KEYS = new Set(['build'])
const QUESTS_RETIRABLE_ALLOWED_KEYS = new Set(['area'])
const VALUES_QUERY_ALLOWED_KEYS = new Set([
  'quest',
  'questId',
  'version',
  'label',
  'build',
  'appVersion',
  'device',
  'os',
  'source',
  'since',
  'groupBy',
  'limit',
])
const VALID_VALUE_SOURCES = new Set(['capture', 'answer'])
const VALID_VALUE_GROUP_BY = new Set(['build', 'appVersion', 'device', 'os', 'version', 'label'])

/**
 * Structured error thrown by HollerKit MCP client and tool validation routines.
 */
export class HollerKitMcpError extends Error {
  readonly status: number
  readonly code: string

  /**
   * Creates a new HollerKitMcpError with an HTTP-like status code and machine-readable error code.
   */
  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'HollerKitMcpError'
    this.status = status
    this.code = code
  }

  /**
   * Serializes the error into the structured MCP tool error envelope.
   */
  toJSON(): { ok: false; status: number; error: { code: string; message: string } } {
    return {
      ok: false,
      status: this.status,
      error: {
        code: this.code,
        message: this.message,
      },
    }
  }
}

export interface ResolvedHollerKitMcpConfig {
  baseUrl: string
  apiKey: string
  fetchFn: FetchLike
  protocolVersion: string
  timeoutMs: number
}

/**
 * Resolves and validates HollerKit MCP configuration from explicit options or environment variables.
 */
export function resolveHollerKitMcpConfig(config: HollerKitMcpConfig = {}): ResolvedHollerKitMcpConfig {
  const rawBaseUrl = (config.baseUrl ?? process.env.HOLLERKIT_URL ?? '').trim()
  if (!rawBaseUrl) {
    throw new HollerKitMcpError(
      400,
      'missing_configuration',
      'Missing HollerKit base URL. Set HOLLERKIT_URL or pass baseUrl to createHollerKitMcpServer.',
    )
  }

  const apiKey = (config.apiKey ?? process.env.HOLLERKIT_API_KEY ?? '').trim()
  if (!apiKey) {
    throw new HollerKitMcpError(
      401,
      'missing_configuration',
      'Missing HollerKit API key. Set HOLLERKIT_API_KEY or pass apiKey to createHollerKitMcpServer.',
    )
  }

  const fetchFn = config.fetch ?? globalThis.fetch
  if (typeof fetchFn !== 'function') {
    throw new HollerKitMcpError(
      500,
      'missing_fetch',
      'Global fetch is not available; pass a custom fetch implementation.',
    )
  }

  let parsedBase: URL
  try {
    parsedBase = new URL(rawBaseUrl)
  } catch {
    throw new HollerKitMcpError(
      400,
      'invalid_configuration',
      `Invalid HollerKit base URL: ${rawBaseUrl}. Expected an http:// or https:// URL.`,
    )
  }

  if (parsedBase.protocol !== 'http:' && parsedBase.protocol !== 'https:') {
    throw new HollerKitMcpError(
      400,
      'invalid_configuration',
      `Unsupported HollerKit URL protocol: ${parsedBase.protocol}. Expected http: or https:.`,
    )
  }

  const timeoutMs = config.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS
  if (typeof timeoutMs !== 'number' || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new HollerKitMcpError(
      400,
      'invalid_configuration',
      'timeoutMs must be a positive finite number.',
    )
  }

  // Strip trailing slashes and an optional trailing `/v1` segment so appending `/v1/...` is always canonical.
  const basePath = parsedBase.pathname.replace(/\/+$/, '').replace(/\/v1$/, '')
  const baseUrl = `${parsedBase.origin}${basePath}`
  const protocolVersion = config.protocolVersion ?? '1'

  return {
    baseUrl,
    apiKey,
    fetchFn,
    protocolVersion,
    timeoutMs,
  }
}

export interface HollerKitMcpClient {
  feedbackInbox(input?: FeedbackInboxInput): Promise<FeedbackInboxOutput>
  feedbackGet(input: FeedbackGetInput): Promise<FeedbackGetOutput>
  feedbackTriage(input: FeedbackTriageInput): Promise<FeedbackTriageOutput>
  questsPending(input: QuestsPendingInput): Promise<QuestsPendingOutput>
  questsRetirable(input?: QuestsRetirableInput): Promise<QuestsRetirableOutput>
  valuesQuery(input?: ValuesQueryInput): Promise<ValuesQueryResult>
}

/**
 * Creates a typed HTTP client for the 5 HollerKit `/v1` coding-agent MCP operations.
 */
export function createHollerKitMcpClient(config: HollerKitMcpConfig = {}): HollerKitMcpClient {
  /**
   * Executes an authenticated `/v1` JSON HTTP request with an end-to-end deadline covering body consumption.
   */
  async function requestJson(
    method: 'GET' | 'PUT' | 'POST',
    v1Path: string,
    options: {
      query?: Record<string, string | number | undefined>
      body?: Record<string, unknown>
    } = {},
  ): Promise<Record<string, unknown>> {
    const resolved = resolveHollerKitMcpConfig(config)
    const url = new URL(`${resolved.baseUrl}${v1Path}`)
    if (options.query) {
      for (const [key, value] of Object.entries(options.query)) {
        if (value !== undefined && value !== '') {
          url.searchParams.set(key, String(value))
        }
      }
    }

    const headers: Record<string, string> = {
      accept: 'application/json',
      authorization: `Bearer ${resolved.apiKey}`,
      'hollerkit-protocol': resolved.protocolVersion,
    }

    const controller = new AbortController()
    const init: RequestInit = {
      method,
      headers,
      signal: controller.signal,
    }

    if (options.body !== undefined) {
      headers['content-type'] = 'application/json'
      init.body = JSON.stringify(options.body)
    }

    let timeoutHandle: ReturnType<typeof setTimeout> | undefined
    let timedOut = false
    let response: Response | undefined

    const timeoutPromise = new Promise<never>((_, reject) => {
      timeoutHandle = setTimeout(() => {
        timedOut = true
        controller.abort()
        if (response?.body) {
          void response.body.cancel().catch(() => {
            // Ignore body cancel errors on timed-out stream.
          })
        }
        reject(
          new HollerKitMcpError(
            504,
            'request_timeout',
            `HollerKit request timed out after ${resolved.timeoutMs}ms.`,
          ),
        )
      }, resolved.timeoutMs)
    })

    let text: string
    try {
      const fetchAndRead = (async () => {
        try {
          response = await resolved.fetchFn(url.toString(), init)
          return await response.text()
        } catch (error) {
          if (timedOut || controller.signal.aborted) {
            throw new HollerKitMcpError(
              504,
              'request_timeout',
              `HollerKit request timed out after ${resolved.timeoutMs}ms.`,
            )
          }
          if (error instanceof HollerKitMcpError) {
            throw error
          }
          const message = error instanceof Error ? error.message : String(error)
          throw new HollerKitMcpError(502, 'network_error', `Network request failed: ${message}`)
        }
      })()

      text = await Promise.race([fetchAndRead, timeoutPromise])
    } finally {
      if (timeoutHandle !== undefined) {
        clearTimeout(timeoutHandle)
      }
    }

    if (!response) {
      throw new HollerKitMcpError(502, 'network_error', 'No HTTP response received.')
    }

    let parsed: unknown = null
    if (text.length > 0) {
      try {
        parsed = JSON.parse(text)
      } catch {
        parsed = null
      }
    }

    if (!response.ok) {
      if (isErrorEnvelope(parsed)) {
        throw new HollerKitMcpError(response.status, parsed.error.code, parsed.error.message)
      }
      throw new HollerKitMcpError(
        response.status,
        `http_${response.status}`,
        `HollerKit server returned HTTP ${response.status}.`,
      )
    }

    const responseProtocol = response.headers.get('hollerkit-protocol')
    if (responseProtocol !== null && responseProtocol.trim() !== '1') {
      throw new HollerKitMcpError(
        502,
        'unsupported_protocol',
        `Server returned unsupported hollerkit-protocol version: ${responseProtocol}.`,
      )
    }

    if (isErrorEnvelope(parsed)) {
      throw new HollerKitMcpError(502, parsed.error.code, parsed.error.message)
    }

    if (!isPlainObject(parsed) || parsed.ok !== true) {
      throw new HollerKitMcpError(
        502,
        'invalid_response',
        'Server returned malformed JSON success envelope.',
      )
    }

    return parsed
  }

  return {
    /**
     * Lists feedback items (`GET /v1/feedback`), defaulting `triage` to `'new'` when omitted.
     */
    async feedbackInbox(input: FeedbackInboxInput = {}): Promise<FeedbackInboxOutput> {
      const normalized = requireArgumentObject(input, 'feedback_inbox', FEEDBACK_INBOX_ALLOWED_KEYS)

      let kind: FeedbackKind | undefined
      if (normalized.kind !== undefined) {
        if (
          typeof normalized.kind !== 'string' ||
          !VALID_FEEDBACK_KINDS.has(normalized.kind as FeedbackKind)
        ) {
          throw new HollerKitMcpError(
            400,
            'invalid_arguments',
            'kind must be "report" or "quest_run".',
          )
        }
        kind = normalized.kind as FeedbackKind
      }

      let result: QuestResult | undefined
      if (normalized.result !== undefined) {
        if (
          typeof normalized.result !== 'string' ||
          !VALID_QUEST_RESULTS.has(normalized.result as QuestResult)
        ) {
          throw new HollerKitMcpError(
            400,
            'invalid_arguments',
            'result must be one of pass, fail, unsure, abandoned.',
          )
        }
        result = normalized.result as QuestResult
      }

      let triageFilter: TriageStatus | undefined
      if (normalized.triage === undefined) {
        triageFilter = 'new'
      } else if (normalized.triage === 'all' || normalized.triage === null) {
        triageFilter = undefined
      } else {
        triageFilter = requireTriageStatus(normalized.triage, 'triage')
      }

      const area = requireOptionalString(normalized.area, 'area')
      const since = requireOptionalString(normalized.since, 'since')
      const build = requireOptionalString(normalized.build, 'build')
      const questId = requireOptionalString(normalized.questId, 'questId')
      const cursor = requireOptionalString(normalized.cursor, 'cursor')

      let limit: number | undefined
      if (normalized.limit !== undefined) {
        if (
          typeof normalized.limit !== 'number' ||
          !Number.isInteger(normalized.limit) ||
          normalized.limit < 1 ||
          normalized.limit > 200
        ) {
          throw new HollerKitMcpError(
            400,
            'invalid_arguments',
            'limit must be an integer between 1 and 200.',
          )
        }
        limit = normalized.limit
      }

      const raw = await requestJson('GET', '/v1/feedback', {
        query: {
          kind,
          result,
          triage: triageFilter,
          area,
          since,
          build,
          questId,
          limit,
          cursor,
        },
      })

      if (
        !Array.isArray(raw.items) ||
        (raw.nextCursor !== null && typeof raw.nextCursor !== 'string')
      ) {
        throw new HollerKitMcpError(
          502,
          'invalid_response',
          'Server returned malformed feedback_inbox payload.',
        )
      }

      return raw as unknown as FeedbackInboxOutput
    },

    /**
     * Fetches full details for a single feedback item (`GET /v1/feedback/{id}`).
     */
    async feedbackGet(input: FeedbackGetInput): Promise<FeedbackGetOutput> {
      const normalized = requireArgumentObject(input, 'feedback_get', FEEDBACK_GET_ALLOWED_KEYS)
      const id = requireNonEmptyString(normalized.id, 'id')
      const raw = await requestJson('GET', `/v1/feedback/${encodeURIComponent(id)}`)

      if (
        !isPlainObject(raw.feedback) ||
        (raw.quest !== null && !isPlainObject(raw.quest)) ||
        !Array.isArray(raw.events) ||
        !Array.isArray(raw.triage) ||
        !Array.isArray(raw.attachments)
      ) {
        throw new HollerKitMcpError(
          502,
          'invalid_response',
          'Server returned malformed feedback_get payload.',
        )
      }

      const response = raw as unknown as FeedbackGetOutput
      const sortedEvents = [...response.events].sort(
        (a, b) => a.offsetSeconds - b.offsetSeconds || a.id - b.id,
      )
      return {
        ...response,
        events: sortedEvents,
      }
    },

    /**
     * Records a triage decision on a feedback item (`PUT /v1/feedback/{id}/triage`).
     */
    async feedbackTriage(input: FeedbackTriageInput): Promise<FeedbackTriageOutput> {
      const normalized = requireArgumentObject(
        input,
        'feedback_triage',
        FEEDBACK_TRIAGE_ALLOWED_KEYS,
      )
      const id = requireNonEmptyString(normalized.id, 'id')
      const status = requireTriageStatus(normalized.status, 'status')
      const summary = requireNonEmptyString(normalized.summary, 'summary')

      const body: Record<string, unknown> = {
        status,
        summary,
      }
      if (normalized.links !== undefined) {
        if (
          !Array.isArray(normalized.links) ||
          !normalized.links.every((item) => typeof item === 'string')
        ) {
          throw new HollerKitMcpError(400, 'invalid_arguments', 'links must be an array of strings.')
        }
        body.links = normalized.links
      }
      if (normalized.actor !== undefined && normalized.actor !== null) {
        body.actor = requireNonEmptyString(normalized.actor, 'actor')
      }

      const raw = await requestJson('PUT', `/v1/feedback/${encodeURIComponent(id)}/triage`, {
        body,
      })

      if (!isPlainObject(raw.feedback) || !isPlainObject(raw.triage)) {
        throw new HollerKitMcpError(
          502,
          'invalid_response',
          'Server returned malformed feedback_triage payload.',
        )
      }

      return raw as unknown as FeedbackTriageOutput
    },

    /**
     * Lists untested active quests for a given build (`GET /v1/builds/{build}/pending`).
     */
    async questsPending(input: QuestsPendingInput): Promise<QuestsPendingOutput> {
      const normalized = requireArgumentObject(
        input,
        'quests_pending',
        QUESTS_PENDING_ALLOWED_KEYS,
      )
      const build = requireNonEmptyString(normalized.build, 'build')
      const raw = await requestJson('GET', `/v1/builds/${encodeURIComponent(build)}/pending`)

      if (
        typeof raw.build !== 'string' ||
        typeof raw.pendingCount !== 'number' ||
        !Array.isArray(raw.quests)
      ) {
        throw new HollerKitMcpError(
          502,
          'invalid_response',
          'Server returned malformed quests_pending payload.',
        )
      }

      return raw as unknown as QuestsPendingOutput
    },

    /**
     * Lists active quests that have passed on their current version (`GET /v1/quests?status=active&passedOnCurrentVersion=true`).
     */
    async questsRetirable(input: QuestsRetirableInput = {}): Promise<QuestsRetirableOutput> {
      const normalized = requireArgumentObject(
        input,
        'quests_retirable',
        QUESTS_RETIRABLE_ALLOWED_KEYS,
      )
      const area = requireOptionalString(normalized.area, 'area')
      const raw = await requestJson('GET', '/v1/quests', {
        query: {
          status: 'active',
          passedOnCurrentVersion: 'true',
          area,
        },
      })

      if (!Array.isArray(raw.quests)) {
        throw new HollerKitMcpError(
          502,
          'invalid_response',
          'Server returned malformed quests_retirable payload.',
        )
      }

      return raw as unknown as QuestsRetirableOutput
    },

    /**
     * Queries aggregated measurements and quest captures across feedback runs and builds (`GET /v1/values`).
     */
    async valuesQuery(input: ValuesQueryInput = {}): Promise<ValuesQueryResult> {
      const normalized = requireArgumentObject(input, 'values_query', VALUES_QUERY_ALLOWED_KEYS)

      const quest = requireOptionalString(normalized.quest ?? normalized.questId, 'quest')
      const label = requireOptionalString(normalized.label, 'label')
      const build = requireOptionalString(normalized.build, 'build')
      const appVersion = requireOptionalString(normalized.appVersion, 'appVersion')
      const device = requireOptionalString(normalized.device, 'device')
      const os = requireOptionalString(normalized.os, 'os')
      const since = requireOptionalString(normalized.since, 'since')

      let source: 'capture' | 'answer' | undefined
      if (normalized.source !== undefined) {
        if (typeof normalized.source !== 'string' || !VALID_VALUE_SOURCES.has(normalized.source)) {
          throw new HollerKitMcpError(400, 'invalid_arguments', 'source must be "capture" or "answer".')
        }
        source = normalized.source as 'capture' | 'answer'
      }

      let groupBy: ValueGroupBy | undefined
      if (normalized.groupBy !== undefined) {
        if (typeof normalized.groupBy !== 'string' || !VALID_VALUE_GROUP_BY.has(normalized.groupBy)) {
          throw new HollerKitMcpError(
            400,
            'invalid_arguments',
            'groupBy must be one of build, appVersion, device, os, version, label.',
          )
        }
        groupBy = normalized.groupBy as ValueGroupBy
      }

      let version: number | undefined
      if (normalized.version !== undefined) {
        if (typeof normalized.version !== 'number' || !Number.isInteger(normalized.version)) {
          throw new HollerKitMcpError(400, 'invalid_arguments', 'version must be an integer.')
        }
        version = normalized.version
      }

      let limit: number | undefined
      if (normalized.limit !== undefined) {
        if (
          typeof normalized.limit !== 'number' ||
          !Number.isInteger(normalized.limit) ||
          normalized.limit < 1 ||
          normalized.limit > 500
        ) {
          throw new HollerKitMcpError(400, 'invalid_arguments', 'limit must be an integer between 1 and 500.')
        }
        limit = normalized.limit
      }

      const raw = await requestJson('GET', '/v1/values', {
        query: {
          quest,
          label,
          build,
          appVersion,
          device,
          os,
          source,
          since,
          groupBy,
          version,
          limit,
        },
      })

      return raw as unknown as ValuesQueryResult
    },
  }
}

/**
 * Ensures the provided tool arguments are a plain object and contain no unknown properties.
 */
function requireArgumentObject(
  value: unknown,
  toolName: string,
  allowedKeys: ReadonlySet<string>,
): Record<string, unknown> {
  if (!isPlainObject(value)) {
    throw new HollerKitMcpError(
      400,
      'invalid_arguments',
      `Arguments for tool "${toolName}" must be a JSON object.`,
    )
  }
  for (const key of Object.keys(value)) {
    if (!allowedKeys.has(key)) {
      throw new HollerKitMcpError(
        400,
        'invalid_arguments',
        `Unknown argument "${key}" for tool "${toolName}".`,
      )
    }
  }
  return value
}

/**
 * Validates that a required field is a non-empty string and returns its trimmed value.
 */
function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new HollerKitMcpError(400, 'invalid_arguments', `${field} must be a non-empty string.`)
  }
  return value.trim()
}

/**
 * Validates that an optional field, when provided, is a string and returns its trimmed non-empty value or undefined.
 */
function requireOptionalString(value: unknown, field: string): string | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'string') {
    throw new HollerKitMcpError(400, 'invalid_arguments', `${field} must be a string.`)
  }
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : undefined
}

/**
 * Validates that a field is one of the allowed HollerKit triage status values.
 */
function requireTriageStatus(value: unknown, field: string): TriageStatus {
  if (typeof value !== 'string' || !VALID_TRIAGE_STATUSES.has(value as TriageStatus)) {
    throw new HollerKitMcpError(
      400,
      'invalid_arguments',
      `${field} must be one of new, triaged, resolved, wontfix, duplicate.`,
    )
  }
  return value as TriageStatus
}

/**
 * Checks whether a value is a non-null, non-array plain object.
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Checks whether a parsed JSON payload matches the HollerKit v1 error envelope shape.
 */
function isErrorEnvelope(
  value: unknown,
): value is { ok: false; error: { code: string; message: string } } {
  if (!isPlainObject(value) || !isPlainObject(value.error)) return false
  return typeof value.error.code === 'string' && typeof value.error.message === 'string'
}
