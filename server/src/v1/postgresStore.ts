import { randomUUID } from 'node:crypto'
import postgres, { type Sql } from 'postgres'
import { HollerKitError } from '../errors.js'
import {
  computeQuestContentHash,
  type ApiKeyRecord,
  type AttachmentKind,
  type BuildManifestQuestStatus,
  type ClaimPendingOutboxInput,
  type CreateApiKeyInput,
  type CreateFeedbackStoreInput,
  type CreateUploadGrantInput,
  type EnqueueOutboxInput,
  type FeedbackAttachmentRecord,
  type FeedbackDetailRecord,
  type FeedbackEventRecord,
  type FeedbackKind,
  type FeedbackRecord,
  type HollerKitStore,
  type ListFeedbackFilter,
  type ListFeedbackResult,
  type ListQuestsFilter,
  type MarkOutboxDeliveredInput,
  type MarkOutboxFailedInput,
  type OutboxRecord,
  type QuestBoardStatus,
  type QuestRecordMode,
  type QuestResult,
  type QuestResultCounts,
  type QuestStatus,
  type QuestVersionRecord,
  type Scope,
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

export interface PostgresStoreOptions {
  url: string
  max?: number | undefined
  prepare?: boolean | undefined
}

export interface PostgresHollerKitStore extends HollerKitStore {
  readonly sql: Sql
  close(): Promise<void>
}

export function postgresStore(options: PostgresStoreOptions): PostgresHollerKitStore {
  const sql = postgres(options.url, {
    max: options.max ?? 10,
    prepare: options.prepare ?? false,
    onnotice: () => {},
  })

  const registeredEmptyBuilds = new Set<string>()

  async function computeCounts(
    db: Sql,
    questId: string,
    questVersion: number,
  ): Promise<QuestResultCounts> {
    const rows = await db<{ result: QuestResult; count: number }[]>`
      SELECT result, COUNT(*)::int AS count
      FROM hollerkit.feedback
      WHERE kind = 'quest_run'
        AND quest_id = ${questId}
        AND quest_version = ${questVersion}
        AND result IS NOT NULL
      GROUP BY result
    `
    const counts: QuestResultCounts = { pass: 0, fail: 0, unsure: 0, abandoned: 0 }
    for (const row of rows) {
      if (row.result in counts) {
        counts[row.result] = Number(row.count)
      }
    }
    return counts
  }

  async function toQuestVersionRecord(db: Sql, row: any): Promise<QuestVersionRecord> {
    const counts = await computeCounts(db, row.id, Number(row.version))
    return {
      id: row.id,
      version: Number(row.version),
      contentHash: row.content_hash,
      title: row.title,
      area: row.area,
      setup: asStringArray(row.setup),
      steps: asStringArray(row.steps),
      expect: asStringArray(row.expect),
      needs: asStringArray(row.needs),
      record: row.record as QuestRecordMode,
      start: row.start ?? null,
      source: {
        pr: row.source_pr !== null && row.source_pr !== undefined ? Number(row.source_pr) : null,
        sha: row.source_sha ?? null,
        added: row.source_added ?? null,
      },
      status: row.status as QuestStatus,
      createdAt: toIso(row.created_at)!,
      retiredAt: toIso(row.retired_at),
      counts,
      passedOnCurrentVersion: counts.pass > 0,
    }
  }

  return {
    sql,

    async syncQuests(input: SyncQuestsInput): Promise<SyncQuestsResult> {
      const nowIso = (input.now ?? new Date()).toISOString()

      return sql.begin(async (tx) => {
        const db = tx as unknown as Sql
        const activeRows = await db<{ id: string }[]>`
          SELECT DISTINCT id FROM hollerkit.quests WHERE status = 'active'
        `
        const previouslyActiveIds = new Set(activeRows.map((r) => r.id))
        const syncedIds = new Set<string>()
        const syncedRecords: QuestVersionRecord[] = []

        for (const def of input.quests) {
          const id = def.id.trim()
          syncedIds.add(id)
          const contentHash = computeQuestContentHash(def)
          const title = def.title.trim()
          const area = def.area.trim()
          const setup = (def.setup ?? []).map((s) => s.trim())
          const steps = def.steps.map((s) => s.trim())
          const expect = def.expect.map((s) => s.trim())
          const needs = (def.needs ?? []).map((s) => s.trim())
          const record: QuestRecordMode = def.record ?? 'optional'
          const start = def.start && def.start.trim().length > 0 ? def.start.trim() : null
          const sourcePr = def.source?.pr ?? input.pr ?? null
          const sourceSha = def.source?.sha ?? input.sha ?? null
          const sourceAdded = def.source?.added ?? null

          const existingRows = await db<any[]>`
            SELECT * FROM hollerkit.quests
            WHERE id = ${id} AND content_hash = ${contentHash}
            LIMIT 1
          `

          if (existingRows.length > 0) {
            const existing = existingRows[0]!
            const targetVersion = Number(existing.version)

            await db`
              UPDATE hollerkit.quests
              SET status = 'superseded'
              WHERE id = ${id} AND version <> ${targetVersion}
            `

            const updatedRows = await db<any[]>`
              UPDATE hollerkit.quests
              SET title = ${title},
                  area = ${area},
                  setup = ${db.json(setup)},
                  steps = ${db.json(steps)},
                  expect = ${db.json(expect)},
                  needs = ${db.json(needs)},
                  record = ${record},
                  start = ${start},
                  source_pr = COALESCE(${sourcePr}, source_pr),
                  source_sha = COALESCE(${sourceSha}, source_sha),
                  source_added = COALESCE(${sourceAdded}, source_added),
                  status = 'active',
                  retired_at = NULL
              WHERE id = ${id} AND version = ${targetVersion}
              RETURNING *
            `
            syncedRecords.push(await toQuestVersionRecord(db, updatedRows[0]!))
          } else {
            const maxRows = await db<{ max_version: number }[]>`
              SELECT COALESCE(MAX(version), 0)::int AS max_version
              FROM hollerkit.quests
              WHERE id = ${id}
            `
            const nextVersion = Number(maxRows[0]?.max_version ?? 0) + 1

            await db`
              UPDATE hollerkit.quests
              SET status = 'superseded'
              WHERE id = ${id}
            `

            const insertedRows = await db<any[]>`
              INSERT INTO hollerkit.quests (
                id, version, content_hash, title, area,
                setup, steps, expect, needs, record, start,
                source_pr, source_sha, source_added,
                status, created_at, retired_at
              ) VALUES (
                ${id}, ${nextVersion}, ${contentHash}, ${title}, ${area},
                ${db.json(setup)}, ${db.json(steps)}, ${db.json(expect)}, ${db.json(needs)},
                ${record}, ${start},
                ${sourcePr}, ${sourceSha}, ${sourceAdded},
                'active', ${nowIso}, NULL
              )
              RETURNING *
            `
            syncedRecords.push(await toQuestVersionRecord(db, insertedRows[0]!))
          }
        }

        const retiredIds: string[] = []
        for (const prevId of previouslyActiveIds) {
          if (!syncedIds.has(prevId)) {
            await db`
              UPDATE hollerkit.quests
              SET status = 'retired', retired_at = ${nowIso}
              WHERE id = ${prevId} AND status = 'active'
            `
            retiredIds.push(prevId)
          }
        }

        return {
          quests: syncedRecords,
          retiredIds,
        }
      })
    },

    async syncBuildManifest(input: SyncBuildManifestInput): Promise<SyncBuildManifestResult> {
      const nowIso = (input.now ?? new Date()).toISOString()
      registeredEmptyBuilds.add(input.build)

      return sql.begin(async (tx) => {
        const db = tx as unknown as Sql
        const statuses: BuildManifestQuestStatus[] = []

        for (const def of input.quests) {
          const id = def.id.trim()
          const contentHash = computeQuestContentHash(def)
          const title = def.title.trim()
          const area = def.area.trim()
          const setup = (def.setup ?? []).map((s) => s.trim())
          const steps = def.steps.map((s) => s.trim())
          const expect = def.expect.map((s) => s.trim())
          const needs = (def.needs ?? []).map((s) => s.trim())
          const record: QuestRecordMode = def.record ?? 'optional'
          const start = def.start && def.start.trim().length > 0 ? def.start.trim() : null

          let rows = await db<any[]>`
            SELECT * FROM hollerkit.quests
            WHERE id = ${id} AND content_hash = ${contentHash}
            LIMIT 1
          `

          let row: any
          if (rows.length > 0) {
            row = rows[0]!
          } else {
            const maxRows = await db<{ max_version: number }[]>`
              SELECT COALESCE(MAX(version), 0)::int AS max_version
              FROM hollerkit.quests
              WHERE id = ${id}
            `
            const nextVersion = Number(maxRows[0]?.max_version ?? 0) + 1
            const inserted = await db<any[]>`
              INSERT INTO hollerkit.quests (
                id, version, content_hash, title, area,
                setup, steps, expect, needs, record, start,
                source_pr, source_sha, source_added,
                status, created_at, retired_at
              ) VALUES (
                ${id}, ${nextVersion}, ${contentHash}, ${title}, ${area},
                ${db.json(setup)}, ${db.json(steps)}, ${db.json(expect)}, ${db.json(needs)},
                ${record}, ${start},
                ${def.source?.pr ?? null}, ${def.source?.sha ?? null}, ${def.source?.added ?? null},
                'draft', ${nowIso}, NULL
              )
              RETURNING *
            `
            row = inserted[0]!
          }

          const version = Number(row.version)
          await db`
            INSERT INTO hollerkit.quest_builds (
              quest_id, quest_version, build, app_version, first_seen_at
            ) VALUES (
              ${row.id}, ${version}, ${input.build}, ${input.appVersion ?? null}, ${nowIso}
            )
            ON CONFLICT (quest_id, quest_version, build) DO NOTHING
          `

          const counts = await computeCounts(db, row.id, version)
          let boardStatus: QuestBoardStatus = 'pending'
          if (counts.pass > 0) {
            boardStatus = 'passed'
          } else if (counts.fail > 0 || counts.unsure > 0) {
            boardStatus = 'failed'
          }

          statuses.push({
            id: row.id,
            version,
            contentHash: row.content_hash,
            questStatus: row.status as QuestStatus,
            boardStatus,
            title: row.title,
            area: row.area,
            setup: asStringArray(row.setup),
            steps: asStringArray(row.steps),
            expect: asStringArray(row.expect),
            needs: asStringArray(row.needs),
            record: row.record as QuestRecordMode,
            start: row.start ?? null,
            source: {
              pr: row.source_pr !== null && row.source_pr !== undefined ? Number(row.source_pr) : null,
              sha: row.source_sha ?? null,
              added: row.source_added ?? null,
            },
            counts,
          })
        }

        const pendingCount = statuses.filter((s) => s.boardStatus === 'pending').length
        return {
          build: input.build,
          pendingCount,
          quests: statuses,
        }
      })
    },

    async getPendingQuestsForBuild(build: string): Promise<QuestVersionRecord[]> {
      const buildCheck = await sql<{ exists: boolean }[]>`
        SELECT EXISTS (
          SELECT 1 FROM hollerkit.quest_builds WHERE build = ${build}
        ) AS exists
      `
      const isBuildRegistered = registeredEmptyBuilds.has(build) || Boolean(buildCheck[0]?.exists)

      const rows = isBuildRegistered
        ? await sql<any[]>`
            SELECT q.*
            FROM hollerkit.quests q
            INNER JOIN hollerkit.quest_builds qb
              ON qb.quest_id = q.id
             AND qb.quest_version = q.version
             AND qb.build = ${build}
            WHERE q.status = 'active'
            ORDER BY q.created_at ASC, q.id ASC
          `
        : await sql<any[]>`
            SELECT q.*
            FROM hollerkit.quests q
            WHERE q.status = 'active'
            ORDER BY q.created_at ASC, q.id ASC
          `

      const pending: QuestVersionRecord[] = []
      for (const row of rows) {
        const record = await toQuestVersionRecord(sql, row)
        if (!record.passedOnCurrentVersion) {
          pending.push(record)
        }
      }
      return pending
    },

    async listQuests(filter: ListQuestsFilter = {}): Promise<QuestVersionRecord[]> {
      const rows = await sql<any[]>`
        SELECT *
        FROM hollerkit.quests
        WHERE (${filter.status ?? null}::text IS NULL OR status = ${filter.status ?? null})
          AND (${filter.area ?? null}::text IS NULL OR area = ${filter.area ?? null})
        ORDER BY created_at ASC, id ASC, version ASC
      `

      const results: QuestVersionRecord[] = []
      for (const row of rows) {
        const record = await toQuestVersionRecord(sql, row)
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
      const rows = await sql<any[]>`
        INSERT INTO hollerkit.upload_grants (
          storage_key, feedback_id, submitter_id, kind, mime_type, size, expires_at, consumed_at, created_at
        ) VALUES (
          ${input.storageKey}, ${input.feedbackId}, ${input.submitterId},
          ${input.kind}, ${input.mimeType}, ${input.size},
          ${input.expiresAt}, NULL, ${nowIso}
        )
        RETURNING *
      `
      return toUploadGrantRecord(rows[0]!)
    },

    async getUploadGrant(storageKey: string): Promise<UploadGrantRecord | null> {
      const rows = await sql<any[]>`
        SELECT * FROM hollerkit.upload_grants WHERE storage_key = ${storageKey} LIMIT 1
      `
      return rows[0] ? toUploadGrantRecord(rows[0]) : null
    },

    async createFeedback(
      input: CreateFeedbackStoreInput,
    ): Promise<{ feedback: FeedbackRecord; idempotent: boolean }> {
      const now = input.now ?? new Date()
      const nowIso = now.toISOString()

      return sql.begin(async (tx) => {
        const db = tx as unknown as Sql

        const existingRows = await db<any[]>`
          SELECT f.*, COALESCE(q.area, f.metadata->>'area') AS resolved_area
          FROM hollerkit.feedback f
          LEFT JOIN hollerkit.quests q
            ON q.id = f.quest_id AND q.version = f.quest_version
          WHERE f.id = ${input.id}
          FOR UPDATE OF f
        `
        if (existingRows.length > 0) {
          const existing = existingRows[0]!
          if (existing.submitter_id !== input.submitterId) {
            throw new HollerKitError(403, 'forbidden', 'Feedback ID belongs to another submitter.')
          }
          return { feedback: toFeedbackRecord(existing), idempotent: true }
        }

        const attachmentsInput = input.attachments ?? []
        const seenKeys = new Set<string>()
        const grantsToConsume: UploadGrantRecord[] = []

        for (const att of attachmentsInput) {
          if (seenKeys.has(att.key)) {
            throw new HollerKitError(400, 'duplicate_attachment_key', `Duplicate attachment key: ${att.key}.`)
          }
          seenKeys.add(att.key)

          const grantRows = await db<any[]>`
            SELECT * FROM hollerkit.upload_grants
            WHERE storage_key = ${att.key}
            FOR UPDATE
          `
          if (grantRows.length === 0) {
            throw new HollerKitError(
              400,
              'invalid_attachment_grant',
              `Upload grant not found for key: ${att.key}.`,
            )
          }
          const grant = toUploadGrantRecord(grantRows[0]!)

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
          let questRows: any[]
          if (resolvedQuestVersion !== null) {
            questRows = await db<any[]>`
              SELECT * FROM hollerkit.quests
              WHERE id = ${resolvedQuestId} AND version = ${resolvedQuestVersion}
              LIMIT 1
            `
          } else {
            questRows = await db<any[]>`
              SELECT * FROM hollerkit.quests
              WHERE id = ${resolvedQuestId}
              ORDER BY (status = 'active') DESC, version DESC
              LIMIT 1
            `
          }
          if (questRows.length === 0) {
            throw new HollerKitError(400, 'invalid_quest', `Unknown quest or version for ${resolvedQuestId}.`)
          }
          resolvedQuestVersion = Number(questRows[0]!.version)
          resolvedArea = questRows[0]!.area
        }

        let triageStatus: TriageStatus | null = null
        if (input.kind === 'report' || input.result === 'fail' || input.result === 'unsure') {
          triageStatus = 'new'
        }

        for (const grant of grantsToConsume) {
          await db`
            UPDATE hollerkit.upload_grants
            SET consumed_at = ${nowIso}
            WHERE storage_key = ${grant.storageKey}
          `
        }

        const metadataObj = input.metadata ? structuredClone(input.metadata) : {}
        const stepsCheckedArr = input.stepsChecked ? [...input.stepsChecked] : []
        const resultVal = input.kind === 'quest_run' ? (input.result ?? null) : null

        const insertedRows = await db<any[]>`
          INSERT INTO hollerkit.feedback (
            id, kind, quest_id, quest_version, result,
            triage_status, triage_summary, links,
            build, app_version, device, os, submitter_id,
            comment, transcript, metadata, steps_checked,
            started_at, ended_at, created_at, updated_at
          ) VALUES (
            ${input.id}, ${input.kind}, ${resolvedQuestId}, ${resolvedQuestVersion}, ${resultVal},
            ${triageStatus}, NULL, ${db.json([])},
            ${input.build}, ${input.appVersion ?? null}, ${input.device ?? null}, ${input.os ?? null}, ${input.submitterId},
            ${input.comment ?? null}, ${input.transcript ?? null}, ${db.json(metadataObj as any)}, ${db.json(stepsCheckedArr)},
            ${input.startedAt ?? null}, ${input.endedAt ?? null}, ${nowIso}, ${nowIso}
          )
          RETURNING *
        `

        for (const ev of input.events ?? []) {
          const offsetSeconds = typeof ev.offsetSeconds === 'number' ? ev.offsetSeconds : 0
          const payload = ev.payload ? structuredClone(ev.payload) : {}
          await db`
            INSERT INTO hollerkit.events (
              feedback_id, offset_seconds, kind, payload
            ) VALUES (
              ${input.id}, ${offsetSeconds}, ${ev.kind}, ${db.json(payload as any)}
            )
          `
        }

        for (let idx = 0; idx < attachmentsInput.length; idx++) {
          const att = attachmentsInput[idx]!
          const grant = grantsToConsume[idx]!
          await db`
            INSERT INTO hollerkit.attachments (
              id, feedback_id, kind, storage_key, mime_type, size,
              offset_seconds, video_start_offset_seconds, expires_at, created_at
            ) VALUES (
              ${randomUUID()}, ${input.id}, ${grant.kind}, ${grant.storageKey},
              ${grant.mimeType}, ${grant.size},
              ${att.offsetSeconds ?? null}, ${att.videoStartOffsetSeconds ?? null},
              NULL, ${nowIso}
            )
          `
        }

        if (input.sinks && input.sinks.length > 0 && triageStatus === 'new') {
          for (const sink of input.sinks) {
            await db`
              INSERT INTO hollerkit.outbox (
                feedback_id, sink, attempts, last_error, next_attempt_at, delivered_at, link, created_at
              ) VALUES (
                ${input.id}, ${sink}, 0, NULL, ${nowIso}, NULL, NULL, ${nowIso}
              )
            `
          }
        }

        const feedbackRow = { ...insertedRows[0]!, resolved_area: resolvedArea }
        return { feedback: toFeedbackRecord(feedbackRow), idempotent: false }
      })
    },

    async listFeedback(filter: ListFeedbackFilter = {}): Promise<ListFeedbackResult> {
      const limit = Math.min(Math.max(filter.limit ?? 50, 1), 200)
      let cursorCreatedAt: string | null = null
      let cursorId: string | null = null

      if (filter.cursor) {
        const cursorRows = await sql<{ id: string; created_at: Date | string }[]>`
          SELECT id::text AS id, created_at FROM hollerkit.feedback WHERE id = ${filter.cursor} LIMIT 1
        `
        if (cursorRows[0]) {
          cursorCreatedAt = toIso(cursorRows[0].created_at)
          cursorId = cursorRows[0].id
        }
      }

      const rows = await sql<any[]>`
        SELECT f.*, COALESCE(q.area, f.metadata->>'area') AS resolved_area
        FROM hollerkit.feedback f
        LEFT JOIN hollerkit.quests q
          ON q.id = f.quest_id AND q.version = f.quest_version
        WHERE (${filter.kind ?? null}::text IS NULL OR f.kind = ${filter.kind ?? null})
          AND (${filter.result ?? null}::text IS NULL OR f.result = ${filter.result ?? null})
          AND (${filter.triage ?? null}::text IS NULL OR f.triage_status = ${filter.triage ?? null})
          AND (${filter.area ?? null}::text IS NULL OR COALESCE(q.area, f.metadata->>'area') = ${filter.area ?? null})
          AND (${filter.build ?? null}::text IS NULL OR f.build = ${filter.build ?? null})
          AND (${filter.questId ?? null}::text IS NULL OR f.quest_id = ${filter.questId ?? null})
          AND (${filter.since ?? null}::timestamptz IS NULL OR f.created_at >= ${filter.since ?? null}::timestamptz)
          AND (
            ${cursorCreatedAt}::timestamptz IS NULL
            OR f.created_at < ${cursorCreatedAt}::timestamptz
            OR (f.created_at = ${cursorCreatedAt}::timestamptz AND f.id::text < ${cursorId})
          )
        ORDER BY f.created_at DESC, f.id::text DESC
        LIMIT ${limit + 1}
      `

      const hasMore = rows.length > limit
      const slice = rows.slice(0, limit).map(toFeedbackRecord)
      const nextCursor = hasMore ? (slice[slice.length - 1]?.id ?? null) : null

      return {
        items: slice,
        nextCursor,
      }
    },

    async getFeedbackById(id: string): Promise<FeedbackDetailRecord | null> {
      const fbRows = await sql<any[]>`
        SELECT f.*, COALESCE(q.area, f.metadata->>'area') AS resolved_area
        FROM hollerkit.feedback f
        LEFT JOIN hollerkit.quests q
          ON q.id = f.quest_id AND q.version = f.quest_version
        WHERE f.id = ${id}
        LIMIT 1
      `
      if (fbRows.length === 0) return null
      const feedback = toFeedbackRecord(fbRows[0]!)

      let quest: QuestVersionRecord | null = null
      if (feedback.questId && feedback.questVersion !== null) {
        const qRows = await sql<any[]>`
          SELECT * FROM hollerkit.quests
          WHERE id = ${feedback.questId} AND version = ${feedback.questVersion}
          LIMIT 1
        `
        if (qRows[0]) {
          quest = await toQuestVersionRecord(sql, qRows[0])
        }
      }

      const eventRows = await sql<any[]>`
        SELECT * FROM hollerkit.events
        WHERE feedback_id = ${id}
        ORDER BY offset_seconds ASC, id ASC
      `
      const triageRows = await sql<any[]>`
        SELECT * FROM hollerkit.triage
        WHERE feedback_id = ${id}
        ORDER BY created_at ASC, id ASC
      `
      const attachmentRows = await sql<any[]>`
        SELECT * FROM hollerkit.attachments
        WHERE feedback_id = ${id}
        ORDER BY created_at ASC
      `

      return {
        feedback,
        quest,
        events: eventRows.map(toEventRecord),
        triage: triageRows.map(toTriageRecord),
        attachments: attachmentRows.map(toAttachmentRecord),
      }
    },

    async triageFeedback(
      input: TriageFeedbackInput,
    ): Promise<{ feedback: FeedbackRecord; triage: TriageRecord }> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const links = input.links ? [...input.links] : []

      return sql.begin(async (tx) => {
        const db = tx as unknown as Sql
        const existing = await db<any[]>`
          SELECT id FROM hollerkit.feedback WHERE id = ${input.feedbackId} FOR UPDATE
        `
        if (existing.length === 0) {
          throw new HollerKitError(404, 'not_found', `Feedback not found: ${input.feedbackId}.`)
        }

        const triageRows = await db<any[]>`
          INSERT INTO hollerkit.triage (
            feedback_id, status, summary, links, actor, created_at
          ) VALUES (
            ${input.feedbackId}, ${input.status}, ${input.summary},
            ${db.json(links)}, ${input.actor ?? null}, ${nowIso}
          )
          RETURNING *
        `

        if (input.links !== undefined) {
          await db`
            UPDATE hollerkit.feedback
            SET triage_status = ${input.status},
                triage_summary = ${input.summary},
                links = ${db.json(links)},
                updated_at = ${nowIso}
            WHERE id = ${input.feedbackId}
          `
        } else {
          await db`
            UPDATE hollerkit.feedback
            SET triage_status = ${input.status},
                triage_summary = ${input.summary},
                updated_at = ${nowIso}
            WHERE id = ${input.feedbackId}
          `
        }

        const updatedFbRows = await db<any[]>`
          SELECT f.*, COALESCE(q.area, f.metadata->>'area') AS resolved_area
          FROM hollerkit.feedback f
          LEFT JOIN hollerkit.quests q
            ON q.id = f.quest_id AND q.version = f.quest_version
          WHERE f.id = ${input.feedbackId}
          LIMIT 1
        `

        return {
          feedback: toFeedbackRecord(updatedFbRows[0]!),
          triage: toTriageRecord(triageRows[0]!),
        }
      })
    },

    async getTester(userId: string): Promise<TesterRecord | null> {
      const rows = await sql<any[]>`
        SELECT * FROM hollerkit.testers WHERE user_id = ${userId} LIMIT 1
      `
      return rows[0] ? toTesterRecord(rows[0]) : null
    },

    async isTester(userId: string): Promise<boolean> {
      const rows = await sql<{ active: boolean }[]>`
        SELECT active FROM hollerkit.testers WHERE user_id = ${userId} AND active = true LIMIT 1
      `
      return rows.length > 0
    },

    async upsertTester(input: UpsertTesterInput): Promise<TesterRecord> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const rows = await sql<any[]>`
        INSERT INTO hollerkit.testers (
          user_id, email, label, active, created_at
        ) VALUES (
          ${input.userId},
          ${input.email ?? null},
          ${input.label ?? null},
          ${input.active ?? true},
          ${nowIso}
        )
        ON CONFLICT (user_id) DO UPDATE
        SET email = CASE WHEN ${input.email !== undefined} THEN ${input.email ?? null} ELSE hollerkit.testers.email END,
            label = CASE WHEN ${input.label !== undefined} THEN ${input.label ?? null} ELSE hollerkit.testers.label END,
            active = CASE WHEN ${input.active !== undefined} THEN ${input.active ?? true} ELSE hollerkit.testers.active END
        RETURNING *
      `
      return toTesterRecord(rows[0]!)
    },

    async getApiKeyByHash(keyHash: string): Promise<ApiKeyRecord | null> {
      const rows = await sql<any[]>`
        SELECT * FROM hollerkit.api_keys
        WHERE key_hash = ${keyHash} AND revoked_at IS NULL
        LIMIT 1
      `
      return rows[0] ? toApiKeyRecord(rows[0]) : null
    },

    async findApiKeyByHash(keyHash: string): Promise<ApiKeyRecord | null> {
      const rows = await sql<any[]>`
        SELECT * FROM hollerkit.api_keys
        WHERE key_hash = ${keyHash} AND revoked_at IS NULL
        LIMIT 1
      `
      return rows[0] ? toApiKeyRecord(rows[0]) : null
    },

    async createApiKey(input: CreateApiKeyInput): Promise<ApiKeyRecord> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const rows = await sql<any[]>`
        INSERT INTO hollerkit.api_keys (
          key_hash, key_prefix, label, scopes, created_at, revoked_at
        ) VALUES (
          ${input.keyHash}, ${input.keyPrefix}, ${input.label ?? null},
          ${sql.array(input.scopes)}, ${nowIso}, NULL
        )
        RETURNING *
      `
      return toApiKeyRecord(rows[0]!)
    },

    async revokeApiKey(prefixOrLabel: string, now?: Date): Promise<boolean> {
      const nowIso = (now ?? new Date()).toISOString()
      const rows = await sql<any[]>`
        UPDATE hollerkit.api_keys
        SET revoked_at = ${nowIso}
        WHERE revoked_at IS NULL
          AND (key_prefix = ${prefixOrLabel} OR label = ${prefixOrLabel} OR key_hash = ${prefixOrLabel})
        RETURNING key_hash
      `
      return rows.length > 0
    },

    async enqueueOutbox(input: EnqueueOutboxInput): Promise<OutboxRecord> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const rows = await sql<any[]>`
        INSERT INTO hollerkit.outbox (
          feedback_id, sink, attempts, last_error, next_attempt_at, delivered_at, link, created_at
        ) VALUES (
          ${input.feedbackId}, ${input.sink}, 0, NULL, ${nowIso}, NULL, NULL, ${nowIso}
        )
        RETURNING *
      `
      return toOutboxRecord(rows[0]!)
    },

    async claimPendingOutbox(input: ClaimPendingOutboxInput = {}): Promise<OutboxRecord[]> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const limit = Math.min(Math.max(input.limit ?? 20, 1), 100)
      const rows = await sql<any[]>`
        SELECT *
        FROM hollerkit.outbox
        WHERE delivered_at IS NULL
          AND next_attempt_at <= ${nowIso}::timestamptz
        ORDER BY next_attempt_at ASC, id ASC
        LIMIT ${limit}
      `
      return rows.map(toOutboxRecord)
    },

    async markOutboxDelivered(input: MarkOutboxDeliveredInput): Promise<OutboxRecord | null> {
      const nowIso = (input.now ?? new Date()).toISOString()
      const link = input.link ?? null

      return sql.begin(async (tx) => {
        const db = tx as unknown as Sql
        const rows = await db<any[]>`
          UPDATE hollerkit.outbox
          SET delivered_at = ${nowIso},
              link = ${link}
          WHERE id = ${input.id}
          RETURNING *
        `
        if (rows.length === 0) return null
        const outboxRow = toOutboxRecord(rows[0]!)

        if (link && link.trim().length > 0) {
          const fbRows = await db<{ links: unknown }[]>`
            SELECT links FROM hollerkit.feedback WHERE id = ${outboxRow.feedbackId} FOR UPDATE
          `
          if (fbRows[0]) {
            const currentLinks = asStringArray(fbRows[0].links)
            if (!currentLinks.includes(link)) {
              currentLinks.push(link)
              await db`
                UPDATE hollerkit.feedback
                SET links = ${db.json(currentLinks)},
                    updated_at = ${nowIso}
                WHERE id = ${outboxRow.feedbackId}
              `
            }
          }
        }

        return outboxRow
      })
    },

    async markOutboxFailed(input: MarkOutboxFailedInput): Promise<OutboxRecord | null> {
      const rows = await sql<any[]>`
        UPDATE hollerkit.outbox
        SET attempts = attempts + 1,
            last_error = ${input.error},
            next_attempt_at = ${input.nextAttemptAt}
        WHERE id = ${input.id}
        RETURNING *
      `
      return rows[0] ? toOutboxRecord(rows[0]) : null
    },

    async close(): Promise<void> {
      await sql.end({ timeout: 5 })
    },
  }
}

function toUploadGrantRecord(row: any): UploadGrantRecord {
  return {
    storageKey: row.storage_key,
    feedbackId: row.feedback_id,
    submitterId: row.submitter_id,
    kind: row.kind as AttachmentKind,
    mimeType: row.mime_type,
    size: Number(row.size),
    expiresAt: toIso(row.expires_at)!,
    consumedAt: toIso(row.consumed_at),
    createdAt: toIso(row.created_at)!,
  }
}

function toFeedbackRecord(row: any): FeedbackRecord {
  const metadata = asPlainObject(row.metadata)
  const area =
    row.resolved_area !== undefined && row.resolved_area !== null
      ? String(row.resolved_area)
      : typeof metadata.area === 'string'
        ? metadata.area
        : null

  return {
    id: row.id,
    kind: row.kind as FeedbackKind,
    questId: row.quest_id ?? null,
    questVersion: row.quest_version !== null && row.quest_version !== undefined ? Number(row.quest_version) : null,
    area,
    result: (row.result as QuestResult | null) ?? null,
    triageStatus: (row.triage_status as TriageStatus | null) ?? null,
    triageSummary: row.triage_summary ?? null,
    links: asStringArray(row.links),
    build: row.build,
    appVersion: row.app_version ?? null,
    device: row.device ?? null,
    os: row.os ?? null,
    submitterId: row.submitter_id,
    comment: row.comment ?? null,
    transcript: row.transcript ?? null,
    metadata,
    stepsChecked: asBooleanArray(row.steps_checked),
    startedAt: toIso(row.started_at),
    endedAt: toIso(row.ended_at),
    createdAt: toIso(row.created_at)!,
    updatedAt: toIso(row.updated_at)!,
  }
}

function toEventRecord(row: any): FeedbackEventRecord {
  return {
    id: Number(row.id),
    feedbackId: row.feedback_id,
    offsetSeconds: Number(row.offset_seconds),
    kind: row.kind,
    payload: asPlainObject(row.payload),
  }
}

function toTriageRecord(row: any): TriageRecord {
  return {
    id: Number(row.id),
    feedbackId: row.feedback_id,
    status: row.status as TriageStatus,
    summary: row.summary,
    links: asStringArray(row.links),
    actor: row.actor ?? null,
    createdAt: toIso(row.created_at)!,
  }
}

function toAttachmentRecord(row: any): FeedbackAttachmentRecord {
  return {
    id: row.id,
    feedbackId: row.feedback_id,
    kind: row.kind as AttachmentKind,
    key: row.storage_key,
    mimeType: row.mime_type,
    size: Number(row.size),
    offsetSeconds:
      row.offset_seconds !== null && row.offset_seconds !== undefined ? Number(row.offset_seconds) : null,
    videoStartOffsetSeconds:
      row.video_start_offset_seconds !== null && row.video_start_offset_seconds !== undefined
        ? Number(row.video_start_offset_seconds)
        : null,
    expiresAt: toIso(row.expires_at),
    createdAt: toIso(row.created_at)!,
  }
}

function toTesterRecord(row: any): TesterRecord {
  return {
    userId: row.user_id,
    email: row.email ?? null,
    label: row.label ?? null,
    active: Boolean(row.active),
    createdAt: toIso(row.created_at)!,
  }
}

function toApiKeyRecord(row: any): ApiKeyRecord {
  return {
    keyHash: row.key_hash,
    keyPrefix: row.key_prefix,
    label: row.label ?? null,
    scopes: Array.isArray(row.scopes) ? (row.scopes as Scope[]) : [],
    createdAt: toIso(row.created_at)!,
    revokedAt: toIso(row.revoked_at),
  }
}

function toOutboxRecord(row: any): OutboxRecord {
  return {
    id: Number(row.id),
    feedbackId: row.feedback_id,
    sink: row.sink,
    attempts: Number(row.attempts),
    lastError: row.last_error ?? null,
    nextAttemptAt: toIso(row.next_attempt_at)!,
    deliveredAt: toIso(row.delivered_at),
    link: row.link ?? null,
    createdAt: toIso(row.created_at)!,
  }
}

function toIso(value: Date | string | null | undefined): string | null {
  if (value === null || value === undefined) return null
  if (value instanceof Date) return value.toISOString()
  return new Date(value).toISOString()
}

function asStringArray(value: unknown): string[] {
  if (typeof value === 'string') {
    try {
      const parsed = JSON.parse(value)
      if (Array.isArray(parsed)) return parsed.map(String)
    } catch {
      return []
    }
  }
  if (Array.isArray(value)) return value.map(String)
  return []
}

function asBooleanArray(value: unknown): boolean[] {
  if (typeof value === 'string') {
    try {
      const parsed = JSON.parse(value)
      if (Array.isArray(parsed)) return parsed.map(Boolean)
    } catch {
      return []
    }
  }
  if (Array.isArray(value)) return value.map(Boolean)
  return []
}

function asPlainObject(value: unknown): Record<string, unknown> {
  if (typeof value === 'string') {
    try {
      const parsed = JSON.parse(value)
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>
      }
    } catch {
      return {}
    }
  }
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    return { ...(value as Record<string, unknown>) }
  }
  return {}
}
