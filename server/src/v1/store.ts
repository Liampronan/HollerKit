import { createHash } from 'node:crypto'

export type Scope = 'tester' | 'quests:write' | 'agent:read' | 'agent:triage'

export type QuestRecordMode = 'none' | 'optional' | 'suggested' | 'required'
export type QuestStatus = 'draft' | 'active' | 'superseded' | 'retired'
export type QuestBoardStatus = 'pending' | 'passed' | 'failed' | 'unsure'

export type FeedbackKind = 'report' | 'quest_run'
export type QuestResult = 'pass' | 'fail' | 'unsure' | 'abandoned'
export type TriageStatus = 'new' | 'triaged' | 'resolved' | 'wontfix' | 'duplicate'
export type AttachmentKind = 'image' | 'audio' | 'video' | 'keyframe' | 'mark'

export type QuestCaptureUnit = 'ms' | 's' | 'bytes' | 'count' | 'percent' | 'none'
export type QuestFieldScalar = string | number | boolean
export type ValueSource = 'capture' | 'answer'
export type ValueGroupBy = 'build' | 'version' | 'appVersion' | 'device' | 'os' | 'label' | 'none'
export type CaptureFlag = 'missing' | 'below_min' | 'above_max' | 'out_of_range'

export interface QuestCapture {
  event: string
  value: string
  unit: QuestCaptureUnit
  label: string
  where?: Record<string, QuestFieldScalar> | null | undefined
  min?: number | null | undefined
  max?: number | null | undefined
}

export interface QuestSource {
  pr?: number | null | undefined
  sha?: string | null | undefined
  added?: string | null | undefined
}

export interface QuestHashInput {
  title: string
  area: string
  setup?: string[] | null | undefined
  steps: string[]
  expect: string[]
  needs?: string[] | null | undefined
  record?: QuestRecordMode | null | undefined
  start?: string | null | undefined
  capture?: QuestCapture[] | null | undefined
}

export interface QuestDefinitionInput extends QuestHashInput {
  id: string
  contentHash?: string | null | undefined
  source?: QuestSource | null | undefined
}

export interface QuestResultCounts {
  pass: number
  fail: number
  unsure: number
  abandoned: number
}

export interface QuestLatestRun {
  id: string
  result: QuestResult
  build: string
  createdAt: string
  comment: string | null
  triageStatus: TriageStatus | null
}

export interface QuestVersionRecord {
  id: string
  version: number
  contentHash: string
  title: string
  area: string
  setup: string[]
  steps: string[]
  expect: string[]
  needs: string[]
  record: QuestRecordMode
  start: string | null
  capture: QuestCapture[]
  source: {
    pr: number | null
    sha: string | null
    added: string | null
  }
  status: QuestStatus
  createdAt: string
  retiredAt: string | null
  counts: QuestResultCounts
  passedOnCurrentVersion: boolean
  boardStatus: QuestBoardStatus
  latestRun: QuestLatestRun | null
}

export interface BuildManifestQuestStatus {
  id: string
  version: number
  contentHash: string
  questStatus: QuestStatus
  boardStatus: QuestBoardStatus
  title: string
  area: string
  setup: string[]
  steps: string[]
  expect: string[]
  needs: string[]
  record: QuestRecordMode
  start: string | null
  capture: QuestCapture[]
  source: {
    pr: number | null
    sha: string | null
    added: string | null
  }
  counts: QuestResultCounts
  latestRun: QuestLatestRun | null
}

export interface SyncQuestsInput {
  quests: QuestDefinitionInput[]
  sha?: string | null | undefined
  pr?: number | null | undefined
  now?: Date | undefined
}

export interface SyncQuestsResult {
  quests: QuestVersionRecord[]
  activatedIds?: string[] | undefined
  reactivatedIds?: string[] | undefined
  retiredIds: string[]
}

export interface SyncBuildManifestInput {
  build: string
  appVersion?: string | null | undefined
  quests: QuestDefinitionInput[]
  now?: Date | undefined
}

export interface SyncBuildManifestResult {
  build: string
  pendingCount: number
  quests: BuildManifestQuestStatus[]
}

export interface ListQuestsFilter {
  status?: QuestStatus | undefined
  area?: string | undefined
  passedOnCurrentVersion?: boolean | undefined
}

export interface UploadGrantRecord {
  storageKey: string
  feedbackId: string
  submitterId: string
  kind: AttachmentKind
  mimeType: string
  size: number
  expiresAt: string
  consumedAt: string | null
  createdAt: string
}

export interface CreateUploadGrantInput {
  storageKey: string
  feedbackId: string
  submitterId: string
  kind: AttachmentKind
  mimeType: string
  size: number
  expiresAt: string
  now?: Date | undefined
}

export interface FeedbackEventInput {
  offsetSeconds?: number | undefined
  kind: string
  payload?: Record<string, unknown> | undefined
}

export interface FeedbackEventRecord {
  id: number
  feedbackId: string
  offsetSeconds: number
  kind: string
  payload: Record<string, unknown>
}

export interface FeedbackAttachmentInput {
  key: string
  kind: AttachmentKind
  mimeType?: string | undefined
  size?: number | undefined
  offsetSeconds?: number | null | undefined
  videoStartOffsetSeconds?: number | null | undefined
}

export interface FeedbackAttachmentRecord {
  id: string
  feedbackId: string
  kind: AttachmentKind
  key: string
  mimeType: string
  size: number
  offsetSeconds: number | null
  videoStartOffsetSeconds: number | null
  expiresAt: string | null
  createdAt: string
}

export interface FeedbackRecord {
  id: string
  kind: FeedbackKind
  questId: string | null
  questVersion: number | null
  area: string | null
  result: QuestResult | null
  triageStatus: TriageStatus | null
  triageSummary: string | null
  links: string[]
  build: string
  appVersion: string | null
  device: string | null
  os: string | null
  submitterId: string
  comment: string | null
  transcript: string | null
  metadata: Record<string, unknown>
  stepsChecked: boolean[]
  startedAt: string | null
  endedAt: string | null
  createdAt: string
  updatedAt: string
}

export interface CreateFeedbackStoreInput {
  id: string
  kind: FeedbackKind
  questId?: string | null | undefined
  questVersion?: number | null | undefined
  result?: QuestResult | null | undefined
  build: string
  appVersion?: string | null | undefined
  device?: string | null | undefined
  os?: string | null | undefined
  submitterId: string
  comment?: string | null | undefined
  transcript?: string | null | undefined
  metadata?: Record<string, unknown> | undefined
  stepsChecked?: boolean[] | undefined
  startedAt?: string | null | undefined
  endedAt?: string | null | undefined
  events?: FeedbackEventInput[] | undefined
  attachments?: FeedbackAttachmentInput[] | undefined
  sinks?: string[] | undefined
  shouldEnqueueSink?: ((sinkName: string, feedback: FeedbackRecord) => boolean) | undefined
  now?: Date | undefined
}

export interface ListFeedbackFilter {
  kind?: FeedbackKind | undefined
  result?: QuestResult | undefined
  triage?: TriageStatus | undefined
  area?: string | undefined
  since?: string | undefined
  build?: string | undefined
  questId?: string | undefined
  limit?: number | undefined
  cursor?: string | undefined
}

export interface ListFeedbackResult {
  items: FeedbackRecord[]
  nextCursor: string | null
}

export interface TriageRecord {
  id: number
  feedbackId: string
  status: TriageStatus
  summary: string
  links: string[]
  actor: string | null
  createdAt: string
}

export interface TriageFeedbackInput {
  feedbackId: string
  status: TriageStatus
  summary: string
  links?: string[] | undefined
  actor?: string | null | undefined
  now?: Date | undefined
}

export interface FeedbackCaptureRecord {
  label: string
  event: string
  value: number | null
  unit: QuestCaptureUnit
  where: Record<string, QuestFieldScalar> | null
  min: number | null
  max: number | null
  matched: boolean
  offsetSeconds: number | null
  flags: CaptureFlag[]
}

export interface FeedbackDetailRecord {
  feedback: FeedbackRecord
  quest: QuestVersionRecord | null
  events: FeedbackEventRecord[]
  triage: TriageRecord[]
  attachments: FeedbackAttachmentRecord[]
  captures: FeedbackCaptureRecord[]
}

export interface ValueRecord {
  id: number
  feedbackId: string
  questId: string
  questVersion: number
  source: ValueSource
  label: string
  value: number | null
  textValue?: string | null | undefined
  boolValue?: boolean | null | undefined
  unit: QuestCaptureUnit
  event: string | null
  offsetSeconds: number | null
  min: number | null
  max: number | null
  flags: CaptureFlag[]
  build: string
  appVersion: string | null
  device: string | null
  os: string | null
  createdAt: string
}

export interface ValueStats {
  n: number
  median: number | null
  p90: number | null
  min: number | null
  max: number | null
  unit: QuestCaptureUnit | null
}

export interface ValueGroupSummary extends ValueStats {
  key: string
  quest: string | null
  label: string | null
  build?: string | null | undefined
  version?: number | null | undefined
  appVersion?: string | null | undefined
  device?: string | null | undefined
  os?: string | null | undefined
}

export interface QueryValuesFilter {
  quest?: string | undefined
  questId?: string | undefined
  version?: number | undefined
  label?: string | undefined
  build?: string | undefined
  appVersion?: string | undefined
  device?: string | undefined
  os?: string | undefined
  source?: ValueSource | undefined
  since?: string | undefined
  groupBy?: ValueGroupBy | undefined
  limit?: number | undefined
}

export interface QueryValuesResult extends ValueStats {
  quest: string | null
  label: string | null
  groupBy: ValueGroupBy | null
  summary: ValueStats
  groups: ValueGroupSummary[]
  values: ValueRecord[]
}

export interface TesterRecord {
  userId: string
  email: string | null
  label: string | null
  active: boolean
  createdAt: string
}

export interface UpsertTesterInput {
  userId: string
  email?: string | null | undefined
  label?: string | null | undefined
  active?: boolean | undefined
  now?: Date | undefined
}

export interface ApiKeyRecord {
  keyHash: string
  keyPrefix: string
  label: string | null
  scopes: Scope[]
  createdAt: string
  revokedAt: string | null
}

export interface CreateApiKeyInput {
  keyHash: string
  keyPrefix: string
  label?: string | null | undefined
  scopes: Scope[]
  now?: Date | undefined
}

export interface OutboxRecord {
  id: number
  feedbackId: string
  sink: string
  attempts: number
  lastError: string | null
  nextAttemptAt: string
  deliveredAt: string | null
  link: string | null
  createdAt: string
}

export interface EnqueueOutboxInput {
  feedbackId: string
  sink: string
  now?: Date | undefined
}

export interface ClaimPendingOutboxInput {
  feedbackId?: string | undefined
  limit?: number | undefined
  leaseMs?: number | undefined
  now?: Date | undefined
}

export interface MarkOutboxDeliveredInput {
  id: number
  link?: string | null | undefined
  now?: Date | undefined
}

export interface MarkOutboxFailedInput {
  id: number
  error: string
  nextAttemptAt: string
  now?: Date | undefined
}

export interface HollerKitStore {
  syncQuests(input: SyncQuestsInput): Promise<SyncQuestsResult>
  syncBuildManifest(input: SyncBuildManifestInput): Promise<SyncBuildManifestResult>
  getPendingQuestsForBuild(build: string): Promise<QuestVersionRecord[]>
  listQuests(filter?: ListQuestsFilter): Promise<QuestVersionRecord[]>

  createUploadGrant(input: CreateUploadGrantInput): Promise<UploadGrantRecord>
  getUploadGrant(storageKey: string): Promise<UploadGrantRecord | null>

  createFeedback(input: CreateFeedbackStoreInput): Promise<{ feedback: FeedbackRecord; idempotent: boolean }>
  listFeedback(filter?: ListFeedbackFilter): Promise<ListFeedbackResult>
  getFeedbackById(id: string): Promise<FeedbackDetailRecord | null>
  triageFeedback(input: TriageFeedbackInput): Promise<{ feedback: FeedbackRecord; triage: TriageRecord }>
  queryValues(filter?: QueryValuesFilter): Promise<QueryValuesResult>

  getTester(userId: string): Promise<TesterRecord | null>
  isTester(userId: string): Promise<boolean>
  upsertTester(input: UpsertTesterInput): Promise<TesterRecord>
  getApiKeyByHash(keyHash: string): Promise<ApiKeyRecord | null>
  findApiKeyByHash(keyHash: string): Promise<ApiKeyRecord | null>
  createApiKey(input: CreateApiKeyInput): Promise<ApiKeyRecord>
  revokeApiKey(prefixOrLabel: string, now?: Date): Promise<boolean>

  enqueueOutbox(input: EnqueueOutboxInput): Promise<OutboxRecord>
  claimPendingOutbox(input?: ClaimPendingOutboxInput): Promise<OutboxRecord[]>
  markOutboxDelivered(input: MarkOutboxDeliveredInput): Promise<OutboxRecord | null>
  markOutboxFailed(input: MarkOutboxFailedInput): Promise<OutboxRecord | null>

  close?(): Promise<void>
}

/**
 * Normalizes a single `QuestCapture` definition into canonical form with sorted `where` keys.
 */
export function normalizeQuestCapture(capture: QuestCapture): QuestCapture {
  let normalizedWhere: Record<string, QuestFieldScalar> | null = null
  if (capture.where && typeof capture.where === 'object' && !Array.isArray(capture.where)) {
    const keys = Object.keys(capture.where).sort()
    if (keys.length > 0) {
      normalizedWhere = {}
      for (const k of keys) {
        const val = capture.where[k]
        if (typeof val === 'string' || typeof val === 'number' || typeof val === 'boolean') {
          normalizedWhere[k] = val
        }
      }
      if (Object.keys(normalizedWhere).length === 0) {
        normalizedWhere = null
      }
    }
  }

  return {
    event: capture.event.trim(),
    label: capture.label.trim(),
    max: capture.max !== undefined && capture.max !== null ? Number(capture.max) : null,
    min: capture.min !== undefined && capture.min !== null ? Number(capture.min) : null,
    unit: (capture.unit ?? 'none') as QuestCaptureUnit,
    value: capture.value.trim(),
    where: normalizedWhere,
  }
}

/**
 * Normalizes an optional array of `QuestCapture` definitions.
 */
export function normalizeQuestCaptures(
  captures: ReadonlyArray<QuestCapture> | null | undefined,
): QuestCapture[] {
  if (!Array.isArray(captures) || captures.length === 0) {
    return []
  }
  return captures.map(normalizeQuestCapture)
}

/**
 * Computes the canonical SHA-256 hex content hash of a quest's functional definition.
 * Excludes `id` and `source` (`pr`, `sha`, `added`) so provenance tweaks do not
 * invalidate prior test runs unless functional instructions change.
 */
export function computeQuestContentHash(quest: QuestHashInput): string {
  const normalizedCaptures = normalizeQuestCaptures(quest.capture)
  const canonical: Record<string, unknown> = {
    area: quest.area.trim(),
    ...(normalizedCaptures.length > 0
      ? {
          capture: normalizedCaptures.map((c) => ({
            event: c.event,
            label: c.label,
            max: c.max ?? null,
            min: c.min ?? null,
            unit: c.unit,
            value: c.value,
            where: c.where ?? null,
          })),
        }
      : {}),
    expect: (quest.expect ?? []).map((item) => item.trim()),
    needs: (quest.needs ?? []).map((item) => item.trim()),
    record: quest.record ?? 'optional',
    setup: (quest.setup ?? []).map((item) => item.trim()),
    start: quest.start && quest.start.trim().length > 0 ? quest.start.trim() : null,
    steps: (quest.steps ?? []).map((item) => item.trim()),
    title: quest.title.trim(),
  }

  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex')
}

export interface EvaluatedCaptureMatch {
  capture: QuestCapture
  label: string
  value: number
  unit: QuestCaptureUnit
  event: string
  offsetSeconds: number
  min: number | null
  max: number | null
  flags: CaptureFlag[]
}

/**
 * Evaluates a quest's `capture` definitions against a run's breadcrumb events.
 */
export function evaluateQuestCaptures(
  captures: ReadonlyArray<QuestCapture> | null | undefined,
  events: ReadonlyArray<{
    id?: number | undefined
    offsetSeconds?: number | undefined
    kind: string
    payload?: Record<string, unknown> | undefined
  }>,
): {
  captures: FeedbackCaptureRecord[]
  matchedValues: EvaluatedCaptureMatch[]
} {
  const normalizedCaptures = normalizeQuestCaptures(captures)
  if (normalizedCaptures.length === 0) {
    return { captures: [], matchedValues: [] }
  }

  const sortedBreadcrumbs = events
    .map((ev, index) => ({
      offsetSeconds: typeof ev.offsetSeconds === 'number' ? ev.offsetSeconds : 0,
      orderKey: typeof ev.id === 'number' ? ev.id : index,
      kind: ev.kind,
      payload: ev.payload ?? {},
    }))
    .filter((ev) => ev.kind === 'breadcrumb')
    .sort((a, b) => {
      if (a.offsetSeconds !== b.offsetSeconds) return a.offsetSeconds - b.offsetSeconds
      return a.orderKey - b.orderKey
    })

  const evaluated: FeedbackCaptureRecord[] = []
  const matchedValues: EvaluatedCaptureMatch[] = []

  for (const cap of normalizedCaptures) {
    let matchedCount = 0

    for (const crumb of sortedBreadcrumbs) {
      const payload = crumb.payload
      const rawMessage =
        typeof payload.message === 'string'
          ? payload.message.trim()
          : typeof payload.event === 'string'
            ? payload.event.trim()
            : null
      if (rawMessage !== cap.event) {
        continue
      }

      const fieldsObj =
        typeof payload.fields === 'object' && payload.fields !== null && !Array.isArray(payload.fields)
          ? (payload.fields as Record<string, unknown>)
          : null

      if (cap.where) {
        let whereMatches = true
        for (const [wKey, wExpected] of Object.entries(cap.where)) {
          const hasFieldKey = Boolean(fieldsObj && Object.prototype.hasOwnProperty.call(fieldsObj, wKey))
          const actual = hasFieldKey ? fieldsObj![wKey] : payload[wKey]
          if (actual === wExpected) {
            continue
          }
          if (!hasFieldKey && typeof actual === 'string') {
            if (typeof wExpected === 'boolean' && (actual === 'true' || actual === 'false')) {
              if ((actual === 'true') === wExpected) continue
            } else if (typeof wExpected === 'number' && actual.trim().length > 0) {
              const parsedNum = Number(actual)
              if (Number.isFinite(parsedNum) && parsedNum === wExpected) continue
            }
          }
          whereMatches = false
          break
        }
        if (!whereMatches) {
          continue
        }
      }

      let rawValue: unknown
      if (cap.value === 'durationMs') {
        rawValue =
          payload.durationMs !== undefined
            ? payload.durationMs
            : fieldsObj && 'durationMs' in fieldsObj
              ? fieldsObj.durationMs
              : undefined
      } else {
        rawValue =
          fieldsObj && Object.prototype.hasOwnProperty.call(fieldsObj, cap.value)
            ? fieldsObj[cap.value]
            : payload[cap.value]
      }

      let numericValue: number | null = null
      if (typeof rawValue === 'number' && Number.isFinite(rawValue)) {
        numericValue = rawValue
      } else if (typeof rawValue === 'string' && rawValue.trim().length > 0) {
        const parsed = Number(rawValue)
        if (Number.isFinite(parsed)) {
          numericValue = parsed
        }
      }

      if (numericValue === null) {
        continue
      }

      matchedCount += 1
      const flags: CaptureFlag[] = []
      if (cap.min !== null && cap.min !== undefined && numericValue < cap.min) {
        flags.push('below_min', 'out_of_range')
      }
      if (cap.max !== null && cap.max !== undefined && numericValue > cap.max) {
        flags.push('above_max', 'out_of_range')
      }

      evaluated.push({
        label: cap.label,
        event: cap.event,
        value: numericValue,
        unit: cap.unit,
        where: cap.where ? { ...cap.where } : null,
        min: cap.min ?? null,
        max: cap.max ?? null,
        matched: true,
        offsetSeconds: crumb.offsetSeconds,
        flags,
      })

      matchedValues.push({
        capture: cap,
        label: cap.label,
        value: numericValue,
        unit: cap.unit,
        event: cap.event,
        offsetSeconds: crumb.offsetSeconds,
        min: cap.min ?? null,
        max: cap.max ?? null,
        flags,
      })
    }

    if (matchedCount === 0) {
      evaluated.push({
        label: cap.label,
        event: cap.event,
        value: null,
        unit: cap.unit,
        where: cap.where ? { ...cap.where } : null,
        min: cap.min ?? null,
        max: cap.max ?? null,
        matched: false,
        offsetSeconds: null,
        flags: ['missing'],
      })
    }
  }

  return { captures: evaluated, matchedValues }
}

/**
 * Computes `n`, `median` (p50), `p90`, `min`, and `max` for a list of numeric measurements.
 */
export function computeValueStats(
  values: ReadonlyArray<number>,
  unit: QuestCaptureUnit | null = null,
): ValueStats {
  const finite = values.filter((v) => typeof v === 'number' && Number.isFinite(v))
  const n = finite.length
  if (n === 0) {
    return {
      n: 0,
      median: null,
      p90: null,
      min: null,
      max: null,
      unit,
    }
  }

  const sorted = [...finite].sort((a, b) => a - b)
  const min = roundStat(sorted[0]!)
  const max = roundStat(sorted[n - 1]!)
  const median = roundStat(percentileCont(sorted, 0.5))
  const p90 = roundStat(percentileCont(sorted, 0.9))

  return {
    n,
    median,
    p90,
    min,
    max,
    unit,
  }
}

function percentileCont(sorted: ReadonlyArray<number>, p: number): number {
  const n = sorted.length
  if (n === 0) return 0
  if (n === 1) return sorted[0]!
  const pos = p * (n - 1)
  const lower = Math.floor(pos)
  const upper = Math.ceil(pos)
  const weight = pos - lower
  return sorted[lower]! * (1 - weight) + sorted[upper]! * weight
}

function roundStat(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000
}

/**
 * Aggregates matched `ValueRecord` rows into overall summary statistics and grouped breakdowns.
 */
export function buildQueryValuesResult(
  rows: ReadonlyArray<ValueRecord>,
  filter: QueryValuesFilter = {},
): QueryValuesResult {
  const questFilter = filter.quest ?? filter.questId ?? null
  const labelFilter = filter.label ?? null
  const groupBy = filter.groupBy && filter.groupBy !== 'none' ? filter.groupBy : null
  const limit = Math.min(Math.max(filter.limit ?? 100, 1), 500)

  const numericRows = rows.filter((r) => typeof r.value === 'number' && Number.isFinite(r.value))
  const distinctUnits = Array.from(new Set(rows.map((r) => r.unit)))
  const resolvedUnit: QuestCaptureUnit | null =
    distinctUnits.length === 1 ? distinctUnits[0]! : rows[0]?.unit ?? null

  const summary = computeValueStats(
    numericRows.map((r) => r.value as number),
    resolvedUnit,
  )

  const groups: ValueGroupSummary[] = []
  if (groupBy) {
    const groupedMap = new Map<string, ValueRecord[]>()
    for (const row of rows) {
      let key: string
      switch (groupBy) {
        case 'build':
          key = row.build
          break
        case 'version':
          key = String(row.questVersion)
          break
        case 'appVersion':
          key = row.appVersion ?? 'unknown'
          break
        case 'device':
          key = row.device ?? 'unknown'
          break
        case 'os':
          key = row.os ?? 'unknown'
          break
        case 'label':
          key = row.label
          break
      }
      const list = groupedMap.get(key) ?? []
      list.push(row)
      groupedMap.set(key, list)
    }

    for (const [key, groupRows] of groupedMap.entries()) {
      const groupNumeric = groupRows
        .filter((r) => typeof r.value === 'number' && Number.isFinite(r.value))
        .map((r) => r.value as number)
      const groupUnits = Array.from(new Set(groupRows.map((r) => r.unit)))
      const groupUnit: QuestCaptureUnit | null =
        groupUnits.length === 1 ? groupUnits[0]! : groupRows[0]?.unit ?? resolvedUnit
      const groupQuests = Array.from(new Set(groupRows.map((r) => r.questId)))
      const groupLabels = Array.from(new Set(groupRows.map((r) => r.label)))
      const stats = computeValueStats(groupNumeric, groupUnit)

      const item: ValueGroupSummary = {
        key,
        quest: groupQuests.length === 1 ? groupQuests[0]! : questFilter,
        label: groupLabels.length === 1 ? groupLabels[0]! : labelFilter,
        ...stats,
      }
      if (groupBy === 'build') item.build = key
      else if (groupBy === 'version') item.version = Number(key)
      else if (groupBy === 'appVersion') item.appVersion = groupRows[0]?.appVersion ?? null
      else if (groupBy === 'device') item.device = groupRows[0]?.device ?? null
      else if (groupBy === 'os') item.os = groupRows[0]?.os ?? null

      groups.push(item)
    }
  } else if (rows.length > 0) {
    const groupedMap = new Map<string, ValueRecord[]>()
    for (const row of rows) {
      const key = `${row.questId}:${row.label}`
      const list = groupedMap.get(key) ?? []
      list.push(row)
      groupedMap.set(key, list)
    }
    for (const [, groupRows] of groupedMap.entries()) {
      const first = groupRows[0]!
      const groupNumeric = groupRows
        .filter((r) => typeof r.value === 'number' && Number.isFinite(r.value))
        .map((r) => r.value as number)
      const stats = computeValueStats(groupNumeric, first.unit)
      groups.push({
        key: first.label,
        quest: first.questId,
        label: first.label,
        ...stats,
      })
    }
  }

  return {
    quest: questFilter,
    label: labelFilter,
    groupBy: filter.groupBy ?? null,
    ...summary,
    summary,
    groups,
    values: rows.slice(0, limit).map((r) => ({ ...r, flags: [...r.flags] })),
  }
}

/**
 * Computes the lowercase SHA-256 hex digest of a raw `hk_...` API key.
 */
export function hashApiKey(rawKey: string): string {
  return createHash('sha256').update(rawKey).digest('hex')
}
