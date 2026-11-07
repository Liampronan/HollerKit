import { createHash } from 'node:crypto'

export type Scope = 'tester' | 'quests:write' | 'agent:read' | 'agent:triage'

export type QuestRecordMode = 'none' | 'optional' | 'suggested' | 'required'
export type QuestStatus = 'draft' | 'active' | 'superseded' | 'retired'
export type QuestBoardStatus = 'pending' | 'passed' | 'failed'

export type FeedbackKind = 'report' | 'quest_run'
export type QuestResult = 'pass' | 'fail' | 'unsure' | 'abandoned'
export type TriageStatus = 'new' | 'triaged' | 'resolved' | 'wontfix' | 'duplicate'
export type AttachmentKind = 'image' | 'audio' | 'video' | 'keyframe' | 'mark'

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
  source: {
    pr: number | null
    sha: string | null
    added: string | null
  }
  counts: QuestResultCounts
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

export interface FeedbackDetailRecord {
  feedback: FeedbackRecord
  quest: QuestVersionRecord | null
  events: FeedbackEventRecord[]
  triage: TriageRecord[]
  attachments: FeedbackAttachmentRecord[]
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
 * Computes the canonical SHA-256 hex content hash of a quest's functional definition.
 * Excludes `id` and `source` (`pr`, `sha`, `added`) so provenance tweaks do not
 * invalidate prior test runs unless functional instructions change.
 */
export function computeQuestContentHash(quest: QuestHashInput): string {
  const canonical = {
    area: quest.area.trim(),
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

/**
 * Computes the lowercase SHA-256 hex digest of a raw `hk_...` API key.
 */
export function hashApiKey(rawKey: string): string {
  return createHash('sha256').update(rawKey).digest('hex')
}
