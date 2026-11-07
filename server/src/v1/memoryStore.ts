import { randomUUID } from 'node:crypto'
import { HollerKitError } from '../errors.js'
import {
  computeQuestContentHash,
  type ApiKeyRecord,
  type BuildManifestQuestStatus,
  type CreateApiKeyInput,
  type CreateFeedbackStoreInput,
  type CreateUploadGrantInput,
  type FeedbackAttachmentRecord,
  type FeedbackDetailRecord,
  type FeedbackEventRecord,
  type FeedbackRecord,
  type HollerKitStore,
  type ListFeedbackFilter,
  type ListFeedbackResult,
  type ListQuestsFilter,
  type QuestBoardStatus,
  type QuestRecordMode,
  type QuestResultCounts,
  type QuestStatus,
  type QuestVersionRecord,
  type SyncBuildManifestInput,
  type SyncBuildManifestResult,
  type SyncQuestsInput,
  type SyncQuestsResult,
  type TesterRecord,
  type TriageFeedbackInput,
  type TriageRecord,
  type TriageStatus,
  type UploadGrantRecord,
  type UpsertTesterInput,
} from './store.js'

interface StoredQuestRow {
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
}

interface StoredQuestBuildRow {
  questId: string
  questVersion: number
  build: string
  appVersion: string | null
  firstSeenAt: string
}

export function memoryStore(): HollerKitStore {
  const quests: StoredQuestRow[] = []
  const questBuilds = new Map<string, StoredQuestBuildRow>()
  const registeredBuilds = new Set<string>()
  const uploadGrants = new Map<string, UploadGrantRecord>()
  const feedbacks = new Map<string, FeedbackRecord>()
  const eventsByFeedback = new Map<string, FeedbackEventRecord[]>()
  const attachmentsByFeedback = new Map<string, FeedbackAttachmentRecord[]>()
  const triageByFeedback = new Map<string, TriageRecord[]>()
  const testers = new Map<string, TesterRecord>()
  const apiKeys = new Map<string, ApiKeyRecord>()

  let nextEventId = 1
  let nextTriageId = 1

  function computeCounts(questId: string, questVersion: number): QuestResultCounts {
    const counts: QuestResultCounts = { pass: 0, fail: 0, unsure: 0, abandoned: 0 }
    for (const fb of feedbacks.values()) {
      if (fb.kind === 'quest_run' && fb.questId === questId && fb.questVersion === questVersion && fb.result) {
        counts[fb.result] += 1
      }
    }
    return counts
  }

  function toQuestVersionRecord(row: StoredQuestRow): QuestVersionRecord {
    const counts = computeCounts(row.id, row.version)
    return {
      id: row.id,
      version: row.version,
      contentHash: row.contentHash,
      title: row.title,
      area: row.area,
      setup: [...row.setup],
      steps: [...row.steps],
      expect: [...row.expect],
      needs: [...row.needs],
      record: row.record,
      start: row.start,
      source: { ...row.source },
      status: row.status,
      createdAt: row.createdAt,
      retiredAt: row.retiredAt,
      counts,
      passedOnCurrentVersion: counts.pass > 0,
    }
  }

  function maxVersionForQuest(questId: string): number {
    let max = 0
    for (const row of quests) {
      if (row.id === questId && row.version > max) {
        max = row.version
      }
    }
    return max
  }

  return {
    async syncQuests(input: SyncQuestsInput): Promise<SyncQuestsResult> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const previouslyActiveIds = new Set<string>()
      for (const row of quests) {
        if (row.status === 'active') {
          previouslyActiveIds.add(row.id)
        }
      }

      const syncedIds = new Set<string>()
      const syncedRows: StoredQuestRow[] = []

      for (const def of input.quests) {
        const id = def.id.trim()
        syncedIds.add(id)
        const contentHash = computeQuestContentHash(def)

        const existingMatch = quests.find((row) => row.id === id && row.contentHash === contentHash)
        if (existingMatch) {
          for (const row of quests) {
            if (
              row.id === id &&
              row.version !== existingMatch.version &&
              (row.status === 'active' || row.status === 'draft')
            ) {
              row.status = 'superseded'
            }
          }
          existingMatch.title = def.title.trim()
          existingMatch.area = def.area.trim()
          existingMatch.setup = (def.setup ?? []).map((s) => s.trim())
          existingMatch.steps = def.steps.map((s) => s.trim())
          existingMatch.expect = def.expect.map((s) => s.trim())
          existingMatch.needs = (def.needs ?? []).map((s) => s.trim())
          existingMatch.record = def.record ?? 'optional'
          existingMatch.start = def.start && def.start.trim().length > 0 ? def.start.trim() : null
          existingMatch.source = {
            pr: def.source?.pr ?? input.pr ?? existingMatch.source.pr,
            sha: def.source?.sha ?? input.sha ?? existingMatch.source.sha,
            added: def.source?.added ?? existingMatch.source.added,
          }
          existingMatch.status = 'active'
          existingMatch.retiredAt = null
          syncedRows.push(existingMatch)
        } else {
          const nextVersion = maxVersionForQuest(id) + 1
          for (const row of quests) {
            if (row.id === id && (row.status === 'active' || row.status === 'draft')) {
              row.status = 'superseded'
            }
          }
          const created: StoredQuestRow = {
            id,
            version: nextVersion,
            contentHash,
            title: def.title.trim(),
            area: def.area.trim(),
            setup: (def.setup ?? []).map((s) => s.trim()),
            steps: def.steps.map((s) => s.trim()),
            expect: def.expect.map((s) => s.trim()),
            needs: (def.needs ?? []).map((s) => s.trim()),
            record: def.record ?? 'optional',
            start: def.start && def.start.trim().length > 0 ? def.start.trim() : null,
            source: {
              pr: def.source?.pr ?? input.pr ?? null,
              sha: def.source?.sha ?? input.sha ?? null,
              added: def.source?.added ?? null,
            },
            status: 'active',
            createdAt: nowIso,
            retiredAt: null,
          }
          quests.push(created)
          syncedRows.push(created)
        }
      }

      const retiredIds: string[] = []
      for (const prevId of previouslyActiveIds) {
        if (!syncedIds.has(prevId)) {
          for (const row of quests) {
            if (row.id === prevId && row.status === 'active') {
              row.status = 'retired'
              row.retiredAt = nowIso
            }
          }
          retiredIds.push(prevId)
        }
      }

      return {
        quests: syncedRows.map(toQuestVersionRecord),
        retiredIds,
      }
    },

    async syncBuildManifest(input: SyncBuildManifestInput): Promise<SyncBuildManifestResult> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const statuses: BuildManifestQuestStatus[] = []
      registeredBuilds.add(input.build)

      for (const def of input.quests) {
        const id = def.id.trim()
        const contentHash = computeQuestContentHash(def)

        let row = quests.find((q) => q.id === id && q.contentHash === contentHash)
        if (!row) {
          const nextVersion = maxVersionForQuest(id) + 1
          row = {
            id,
            version: nextVersion,
            contentHash,
            title: def.title.trim(),
            area: def.area.trim(),
            setup: (def.setup ?? []).map((s) => s.trim()),
            steps: def.steps.map((s) => s.trim()),
            expect: def.expect.map((s) => s.trim()),
            needs: (def.needs ?? []).map((s) => s.trim()),
            record: def.record ?? 'optional',
            start: def.start && def.start.trim().length > 0 ? def.start.trim() : null,
            source: {
              pr: def.source?.pr ?? null,
              sha: def.source?.sha ?? null,
              added: def.source?.added ?? null,
            },
            status: 'draft',
            createdAt: nowIso,
            retiredAt: null,
          }
          quests.push(row)
        }

        const buildKey = `${row.id}:${row.version}:${input.build}`
        if (!questBuilds.has(buildKey)) {
          questBuilds.set(buildKey, {
            questId: row.id,
            questVersion: row.version,
            build: input.build,
            appVersion: input.appVersion ?? null,
            firstSeenAt: nowIso,
          })
        }

        const counts = computeCounts(row.id, row.version)
        let boardStatus: QuestBoardStatus = 'pending'
        if (counts.pass > 0) {
          boardStatus = 'passed'
        } else if (counts.fail > 0 || counts.unsure > 0) {
          boardStatus = 'failed'
        }

        statuses.push({
          id: row.id,
          version: row.version,
          contentHash: row.contentHash,
          questStatus: row.status,
          boardStatus,
          title: row.title,
          area: row.area,
          setup: [...row.setup],
          steps: [...row.steps],
          expect: [...row.expect],
          needs: [...row.needs],
          record: row.record,
          start: row.start,
          source: { ...row.source },
          counts,
        })
      }

      const pendingCount = statuses.filter((s) => s.boardStatus === 'pending').length
      return {
        build: input.build,
        pendingCount,
        quests: statuses,
      }
    },

    async getPendingQuestsForBuild(build: string): Promise<QuestVersionRecord[]> {
      const isBuildRegistered = registeredBuilds.has(build)
      const pending: QuestVersionRecord[] = []
      for (const row of quests) {
        if (row.status !== 'active') continue
        if (isBuildRegistered && !questBuilds.has(`${row.id}:${row.version}:${build}`)) {
          continue
        }
        const record = toQuestVersionRecord(row)
        if (!record.passedOnCurrentVersion) {
          pending.push(record)
        }
      }
      return pending
    },

    async listQuests(filter: ListQuestsFilter = {}): Promise<QuestVersionRecord[]> {
      const results: QuestVersionRecord[] = []
      for (const row of quests) {
        if (filter.status && row.status !== filter.status) continue
        if (filter.area && row.area !== filter.area) continue
        const record = toQuestVersionRecord(row)
        if (
          filter.passedOnCurrentVersion !== undefined &&
          record.passedOnCurrentVersion !== filter.passedOnCurrentVersion
        ) {
          continue
        }
        results.push(record)
      }
      return results
    },

    async createUploadGrant(input: CreateUploadGrantInput): Promise<UploadGrantRecord> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const record: UploadGrantRecord = {
        storageKey: input.storageKey,
        feedbackId: input.feedbackId,
        submitterId: input.submitterId,
        kind: input.kind,
        mimeType: input.mimeType,
        size: input.size,
        expiresAt: input.expiresAt,
        consumedAt: null,
        createdAt: nowIso,
      }
      uploadGrants.set(record.storageKey, record)
      return { ...record }
    },

    async getUploadGrant(storageKey: string): Promise<UploadGrantRecord | null> {
      const grant = uploadGrants.get(storageKey)
      return grant ? { ...grant } : null
    },

    async createFeedback(
      input: CreateFeedbackStoreInput,
    ): Promise<{ feedback: FeedbackRecord; idempotent: boolean }> {
      const now = input.now ?? new Date()
      const nowIso = now.toISOString()

      const existing = feedbacks.get(input.id)
      if (existing) {
        if (existing.submitterId !== input.submitterId) {
          throw new HollerKitError(403, 'forbidden', 'Feedback ID belongs to another submitter.')
        }
        return { feedback: cloneFeedback(existing), idempotent: true }
      }

      const attachmentsInput = input.attachments ?? []
      const seenKeys = new Set<string>()
      const grantsToConsume: UploadGrantRecord[] = []

      for (const att of attachmentsInput) {
        if (seenKeys.has(att.key)) {
          throw new HollerKitError(400, 'duplicate_attachment_key', `Duplicate attachment key: ${att.key}.`)
        }
        seenKeys.add(att.key)

        const grant = uploadGrants.get(att.key)
        if (!grant) {
          throw new HollerKitError(400, 'invalid_attachment_grant', `Upload grant not found for key: ${att.key}.`)
        }
        if (grant.submitterId !== input.submitterId) {
          throw new HollerKitError(403, 'forbidden', 'Attachment grant belongs to another submitter.')
        }
        if (grant.feedbackId !== input.id) {
          throw new HollerKitError(
            400,
            'invalid_attachment_grant',
            'Attachment grant was issued for a different feedbackId.',
          )
        }
        if (att.kind && att.kind !== grant.kind) {
          throw new HollerKitError(
            400,
            'invalid_attachment_grant',
            `Attachment kind (${att.kind}) does not match upload grant kind (${grant.kind}).`,
          )
        }
        if (att.mimeType !== undefined && att.mimeType.toLowerCase() !== grant.mimeType.toLowerCase()) {
          throw new HollerKitError(
            400,
            'invalid_attachment_grant',
            `Attachment mimeType (${att.mimeType}) does not match upload grant mimeType (${grant.mimeType}).`,
          )
        }
        if (att.size !== undefined && att.size !== grant.size) {
          throw new HollerKitError(
            400,
            'invalid_attachment_grant',
            `Attachment size (${att.size}) does not match upload grant size (${grant.size}).`,
          )
        }
        if (grant.consumedAt !== null) {
          throw new HollerKitError(
            400,
            'expired_or_consumed_grant',
            'Attachment grant has already been consumed.',
          )
        }
        if (new Date(grant.expiresAt).getTime() <= now.getTime()) {
          throw new HollerKitError(400, 'expired_or_consumed_grant', 'Attachment grant has expired.')
        }
        grantsToConsume.push(grant)
      }

      let resolvedQuestId: string | null = input.questId ?? null
      let resolvedQuestVersion: number | null = input.questVersion ?? null
      let resolvedArea: string | null =
        typeof input.metadata?.area === 'string' ? (input.metadata.area as string) : null

      if (input.kind === 'quest_run') {
        if (!resolvedQuestId) {
          throw new HollerKitError(400, 'missing_quest_id', 'quest_run requires questId.')
        }
        let questRow: StoredQuestRow | undefined
        if (resolvedQuestVersion !== null) {
          questRow = quests.find((q) => q.id === resolvedQuestId && q.version === resolvedQuestVersion)
        } else {
          questRow =
            quests.find((q) => q.id === resolvedQuestId && q.status === 'active') ??
            quests
              .filter((q) => q.id === resolvedQuestId)
              .sort((a, b) => b.version - a.version)[0]
        }
        if (!questRow) {
          throw new HollerKitError(400, 'invalid_quest', `Unknown quest or version for ${resolvedQuestId}.`)
        }
        resolvedQuestVersion = questRow.version
        resolvedArea = questRow.area
      }

      let triageStatus: TriageStatus | null = null
      if (input.kind === 'report' || input.result === 'fail' || input.result === 'unsure') {
        triageStatus = 'new'
      }

      for (const grant of grantsToConsume) {
        grant.consumedAt = nowIso
      }

      const record: FeedbackRecord = {
        id: input.id,
        kind: input.kind,
        questId: resolvedQuestId,
        questVersion: resolvedQuestVersion,
        area: resolvedArea,
        result: input.kind === 'quest_run' ? (input.result ?? null) : null,
        triageStatus,
        triageSummary: null,
        links: [],
        build: input.build,
        appVersion: input.appVersion ?? null,
        device: input.device ?? null,
        os: input.os ?? null,
        submitterId: input.submitterId,
        comment: input.comment ?? null,
        transcript: input.transcript ?? null,
        metadata: input.metadata ? structuredClone(input.metadata) : {},
        stepsChecked: input.stepsChecked ? [...input.stepsChecked] : [],
        startedAt: input.startedAt ?? null,
        endedAt: input.endedAt ?? null,
        createdAt: nowIso,
        updatedAt: nowIso,
      }

      feedbacks.set(record.id, record)

      const eventRecords: FeedbackEventRecord[] = (input.events ?? []).map((ev) => ({
        id: nextEventId++,
        feedbackId: record.id,
        offsetSeconds: typeof ev.offsetSeconds === 'number' ? ev.offsetSeconds : 0,
        kind: ev.kind,
        payload: ev.payload ? structuredClone(ev.payload) : {},
      }))
      eventsByFeedback.set(record.id, eventRecords)

      const attachmentRecords: FeedbackAttachmentRecord[] = attachmentsInput.map((att, idx) => {
        const grant = grantsToConsume[idx]!
        return {
          id: randomUUID(),
          feedbackId: record.id,
          kind: grant.kind,
          key: grant.storageKey,
          mimeType: grant.mimeType,
          size: grant.size,
          offsetSeconds: att.offsetSeconds ?? null,
          videoStartOffsetSeconds: att.videoStartOffsetSeconds ?? null,
          expiresAt: null,
          createdAt: nowIso,
        }
      })
      attachmentsByFeedback.set(record.id, attachmentRecords)
      triageByFeedback.set(record.id, [])

      return { feedback: cloneFeedback(record), idempotent: false }
    },

    async listFeedback(filter: ListFeedbackFilter = {}): Promise<ListFeedbackResult> {
      const sinceMs = filter.since ? new Date(filter.since).getTime() : null
      const cursorRecord = filter.cursor ? feedbacks.get(filter.cursor) : undefined
      const all = Array.from(feedbacks.values()).filter((fb) => {
        if (cursorRecord && compareFeedbackDesc(fb, cursorRecord) <= 0) return false
        if (filter.kind && fb.kind !== filter.kind) return false
        if (filter.result && fb.result !== filter.result) return false
        if (filter.triage !== undefined && fb.triageStatus !== filter.triage) return false
        if (filter.area && fb.area !== filter.area) return false
        if (filter.build && fb.build !== filter.build) return false
        if (filter.questId && fb.questId !== filter.questId) return false
        if (sinceMs !== null && !Number.isNaN(sinceMs) && new Date(fb.createdAt).getTime() < sinceMs) {
          return false
        }
        return true
      })

      all.sort(compareFeedbackDesc)

      const limit = Math.min(Math.max(filter.limit ?? 50, 1), 200)
      const slice = all.slice(0, limit)
      const nextCursor = limit < all.length ? (slice[slice.length - 1]?.id ?? null) : null

      return {
        items: slice.map(cloneFeedback),
        nextCursor,
      }
    },

    async getFeedbackById(id: string): Promise<FeedbackDetailRecord | null> {
      const fb = feedbacks.get(id)
      if (!fb) return null

      let quest: QuestVersionRecord | null = null
      if (fb.questId && fb.questVersion !== null) {
        const row = quests.find((q) => q.id === fb.questId && q.version === fb.questVersion)
        if (row) {
          quest = toQuestVersionRecord(row)
        }
      }

      const events = [...(eventsByFeedback.get(id) ?? [])].sort((a, b) => {
        if (a.offsetSeconds !== b.offsetSeconds) return a.offsetSeconds - b.offsetSeconds
        return a.id - b.id
      })

      const triage = [...(triageByFeedback.get(id) ?? [])].sort((a, b) => {
        const diff = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
        if (diff !== 0) return diff
        return a.id - b.id
      })

      const attachments = [...(attachmentsByFeedback.get(id) ?? [])]

      return {
        feedback: cloneFeedback(fb),
        quest,
        events: events.map((ev) => ({ ...ev, payload: structuredClone(ev.payload) })),
        triage: triage.map((tr) => ({ ...tr, links: [...tr.links] })),
        attachments: attachments.map((att) => ({ ...att })),
      }
    },

    async triageFeedback(
      input: TriageFeedbackInput,
    ): Promise<{ feedback: FeedbackRecord; triage: TriageRecord }> {
      const fb = feedbacks.get(input.feedbackId)
      if (!fb) {
        throw new HollerKitError(404, 'not_found', `Feedback not found: ${input.feedbackId}.`)
      }

      const nowIso = (input.now ?? new Date()).toISOString()
      const links = input.links ? [...input.links] : []

      const entry: TriageRecord = {
        id: nextTriageId++,
        feedbackId: fb.id,
        status: input.status,
        summary: input.summary,
        links,
        actor: input.actor ?? null,
        createdAt: nowIso,
      }

      const list = triageByFeedback.get(fb.id) ?? []
      list.push(entry)
      triageByFeedback.set(fb.id, list)

      fb.triageStatus = input.status
      fb.triageSummary = input.summary
      if (input.links !== undefined) {
        fb.links = [...input.links]
      }
      fb.updatedAt = nowIso

      return {
        feedback: cloneFeedback(fb),
        triage: { ...entry, links: [...entry.links] },
      }
    },

    async getTester(userId: string): Promise<TesterRecord | null> {
      const tester = testers.get(userId)
      return tester ? { ...tester } : null
    },

    async upsertTester(input: UpsertTesterInput): Promise<TesterRecord> {
      const existing = testers.get(input.userId)
      const nowIso = (input.now ?? new Date()).toISOString()
      const record: TesterRecord = {
        userId: input.userId,
        email: input.email !== undefined ? input.email : (existing?.email ?? null),
        label: input.label !== undefined ? input.label : (existing?.label ?? null),
        active: input.active !== undefined ? input.active : (existing?.active ?? true),
        createdAt: existing?.createdAt ?? nowIso,
      }
      testers.set(record.userId, record)
      return { ...record }
    },

    async getApiKeyByHash(keyHash: string): Promise<ApiKeyRecord | null> {
      const record = apiKeys.get(keyHash)
      if (!record || record.revokedAt !== null) return null
      return { ...record, scopes: [...record.scopes] }
    },

    async createApiKey(input: CreateApiKeyInput): Promise<ApiKeyRecord> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const record: ApiKeyRecord = {
        keyHash: input.keyHash,
        keyPrefix: input.keyPrefix,
        label: input.label ?? null,
        scopes: [...input.scopes],
        createdAt: nowIso,
        revokedAt: null,
      }
      apiKeys.set(record.keyHash, record)
      return { ...record, scopes: [...record.scopes] }
    },

    async revokeApiKey(prefixOrLabel: string, now?: Date): Promise<boolean> {
      const nowIso = (now ?? new Date()).toISOString()
      let revoked = false
      for (const record of apiKeys.values()) {
        if (
          record.revokedAt === null &&
          (record.keyPrefix === prefixOrLabel || record.label === prefixOrLabel || record.keyHash === prefixOrLabel)
        ) {
          record.revokedAt = nowIso
          revoked = true
        }
      }
      return revoked
    },
  }
}

function compareFeedbackDesc(a: FeedbackRecord, b: FeedbackRecord): number {
  const diff = new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
  if (diff !== 0) return diff
  return b.id.localeCompare(a.id)
}

function cloneFeedback(fb: FeedbackRecord): FeedbackRecord {
  return {
    ...fb,
    links: [...fb.links],
    metadata: structuredClone(fb.metadata),
    stepsChecked: [...fb.stepsChecked],
  }
}
