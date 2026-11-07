import type {
  FeedbackGetInput,
  FeedbackGetOutput,
  FeedbackInboxInput,
  FeedbackInboxOutput,
  FeedbackTriageInput,
  FeedbackTriageOutput,
  FetchLike,
  HollerKitMcpConfig,
  QuestsPendingInput,
  QuestsPendingOutput,
  QuestsRetirableInput,
  QuestsRetirableOutput,
  TriageStatus,
} from './types.js'

const VALID_TRIAGE_STATUSES = new Set<TriageStatus>([
  'new',
  'triaged',
  'resolved',
  'wontfix',
  'duplicate',
])

export class HollerKitMcpError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'HollerKitMcpError'
    this.status = status
    this.code = code
  }

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
}

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

  // Strip trailing slashes and an optional trailing `/v1` segment so appending `/v1/...` is always canonical.
  const basePath = parsedBase.pathname.replace(/\/+$/, '').replace(/\/v1$/, '')
  const baseUrl = `${parsedBase.origin}${basePath}`
  const protocolVersion = config.protocolVersion ?? '1'

  return {
    baseUrl,
    apiKey,
    fetchFn,
    protocolVersion,
  }
}

export interface HollerKitMcpClient {
  feedbackInbox(input?: FeedbackInboxInput): Promise<FeedbackInboxOutput>
  feedbackGet(input: FeedbackGetInput): Promise<FeedbackGetOutput>
  feedbackTriage(input: FeedbackTriageInput): Promise<FeedbackTriageOutput>
  questsPending(input: QuestsPendingInput): Promise<QuestsPendingOutput>
  questsRetirable(input?: QuestsRetirableInput): Promise<QuestsRetirableOutput>
}

export function createHollerKitMcpClient(config: HollerKitMcpConfig = {}): HollerKitMcpClient {
  async function requestJson<T>(
    method: 'GET' | 'PUT' | 'POST',
    v1Path: string,
    options: {
      query?: Record<string, string | number | undefined>
      body?: Record<string, unknown>
    } = {},
  ): Promise<T> {
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

    const init: RequestInit = {
      method,
      headers,
    }

    if (options.body !== undefined) {
      headers['content-type'] = 'application/json'
      init.body = JSON.stringify(options.body)
    }

    let response: Response
    try {
      response = await resolved.fetchFn(url.toString(), init)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new HollerKitMcpError(502, 'network_error', `Network request failed: ${message}`)
    }

    const text = await response.text()
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

    if (!isPlainObject(parsed)) {
      throw new HollerKitMcpError(502, 'invalid_response', 'Server returned non-JSON object payload.')
    }

    return parsed as T
  }

  return {
    async feedbackInbox(input: FeedbackInboxInput = {}): Promise<FeedbackInboxOutput> {
      const triageFilter =
        input.triage === undefined
          ? 'new'
          : input.triage === 'all' || input.triage === null
            ? undefined
            : input.triage

      return requestJson<FeedbackInboxOutput>('GET', '/v1/feedback', {
        query: {
          kind: input.kind,
          result: input.result,
          triage: triageFilter,
          area: input.area,
          since: input.since,
          build: input.build,
          questId: input.questId,
          limit: input.limit,
          cursor: input.cursor,
        },
      })
    },

    async feedbackGet(input: FeedbackGetInput): Promise<FeedbackGetOutput> {
      const id = requireNonEmptyString(input?.id, 'id')
      const response = await requestJson<FeedbackGetOutput>(
        'GET',
        `/v1/feedback/${encodeURIComponent(id)}`,
      )
      const sortedEvents = Array.isArray(response.events)
        ? [...response.events].sort(
            (a, b) => a.offsetSeconds - b.offsetSeconds || a.id - b.id,
          )
        : []
      return {
        ...response,
        events: sortedEvents,
      }
    },

    async feedbackTriage(input: FeedbackTriageInput): Promise<FeedbackTriageOutput> {
      const id = requireNonEmptyString(input?.id, 'id')
      const status = requireTriageStatus(input?.status, 'status')
      const summary = requireNonEmptyString(input?.summary, 'summary')

      const body: Record<string, unknown> = {
        status,
        summary,
      }
      if (input.links !== undefined) {
        if (!Array.isArray(input.links) || !input.links.every((item) => typeof item === 'string')) {
          throw new HollerKitMcpError(400, 'invalid_arguments', 'links must be an array of strings.')
        }
        body.links = input.links
      }
      if (input.actor !== undefined && input.actor !== null) {
        body.actor = requireNonEmptyString(input.actor, 'actor')
      }

      return requestJson<FeedbackTriageOutput>(
        'PUT',
        `/v1/feedback/${encodeURIComponent(id)}/triage`,
        { body },
      )
    },

    async questsPending(input: QuestsPendingInput): Promise<QuestsPendingOutput> {
      const build = requireNonEmptyString(input?.build, 'build')
      return requestJson<QuestsPendingOutput>(
        'GET',
        `/v1/builds/${encodeURIComponent(build)}/pending`,
      )
    },

    async questsRetirable(input: QuestsRetirableInput = {}): Promise<QuestsRetirableOutput> {
      const area =
        typeof input?.area === 'string' && input.area.trim().length > 0
          ? input.area.trim()
          : undefined
      return requestJson<QuestsRetirableOutput>('GET', '/v1/quests', {
        query: {
          status: 'active',
          passedOnCurrentVersion: 'true',
          area,
        },
      })
    },
  }
}

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new HollerKitMcpError(400, 'invalid_arguments', `${field} must be a non-empty string.`)
  }
  return value.trim()
}

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

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isErrorEnvelope(
  value: unknown,
): value is { ok: false; error: { code: string; message: string } } {
  if (!isPlainObject(value) || !isPlainObject(value.error)) return false
  return typeof value.error.code === 'string' && typeof value.error.message === 'string'
}
