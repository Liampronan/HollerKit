import type { HollerKitStorageAdapter } from './server.js'
import type {
  FeedbackAttachmentRecord,
  FeedbackDetailRecord,
  FeedbackRecord,
  HollerKitStore,
  OutboxRecord,
} from './store.js'

export interface SignedFeedbackAttachmentRecord extends FeedbackAttachmentRecord {
  url?: string | undefined
}

export interface FeedbackDetail extends Omit<FeedbackDetailRecord, 'attachments'> {
  attachments: SignedFeedbackAttachmentRecord[]
}

export interface HollerKitSink {
  name: string
  when?: ((feedback: FeedbackRecord) => boolean) | undefined
  deliver(feedback: FeedbackDetail): Promise<{ link?: string | undefined } | void>
}

export interface FlushOutboxOptions {
  store: HollerKitStore
  storage?: HollerKitStorageAdapter | undefined
  sinks: HollerKitSink[]
  limit?: number | undefined
  now?: Date | (() => Date) | undefined
  baseDelayMs?: number | undefined
  maxDelayMs?: number | undefined
  readUrlTtlSeconds?: number | undefined
}

export interface FlushOutboxResult {
  claimed: number
  delivered: OutboxRecord[]
  failed: OutboxRecord[]
}

export function defaultSinkWhen(feedback: FeedbackRecord): boolean {
  return (
    feedback.kind === 'report' ||
    feedback.result === 'fail' ||
    feedback.result === 'unsure'
  )
}

export function shouldEnqueueSink(
  sink: HollerKitSink | string,
  feedback: FeedbackRecord,
): boolean {
  if (typeof sink === 'string') {
    return defaultSinkWhen(feedback)
  }
  const predicate = sink.when ?? defaultSinkWhen
  return predicate(feedback)
}

export async function flushOutbox(options: FlushOutboxOptions): Promise<FlushOutboxResult> {
  const resolveNow = (): Date => {
    if (typeof options.now === 'function') return options.now()
    if (options.now instanceof Date) return options.now
    return new Date()
  }

  const now = resolveNow()
  const baseDelayMs = options.baseDelayMs ?? 30_000
  const maxDelayMs = options.maxDelayMs ?? 3_600_000
  const readUrlTtlSeconds = options.readUrlTtlSeconds ?? 3600

  const sinksByName = new Map<string, HollerKitSink>()
  for (const sink of options.sinks) {
    sinksByName.set(sink.name, sink)
  }

  const pendingRows = await options.store.claimPendingOutbox({
    limit: options.limit,
    now,
  })

  const delivered: OutboxRecord[] = []
  const failed: OutboxRecord[] = []

  for (const row of pendingRows) {
    const attemptNow = resolveNow()
    const sink = sinksByName.get(row.sink)
    if (!sink) {
      const nextAttemptAt = computeBackoffIso(attemptNow, row.attempts, baseDelayMs, maxDelayMs)
      const updated = await options.store.markOutboxFailed({
        id: row.id,
        error: `Sink not registered: ${row.sink}`,
        nextAttemptAt,
        now: attemptNow,
      })
      if (updated) failed.push(updated)
      continue
    }

    try {
      const detail = await options.store.getFeedbackById(row.feedbackId)
      if (!detail) {
        throw new Error(`Feedback not found: ${row.feedbackId}`)
      }

      const attachments: SignedFeedbackAttachmentRecord[] = options.storage
        ? await Promise.all(
            detail.attachments.map(async (att) => {
              const signed = await options.storage!.signReadUrl({
                key: att.key,
                expiresInSeconds: readUrlTtlSeconds,
              })
              return {
                ...att,
                url: signed.url,
                expiresAt: signed.expiresAt,
              }
            }),
          )
        : detail.attachments.map((att) => ({ ...att }))

      const result = await sink.deliver({
        ...detail,
        attachments,
      })

      const link = result && typeof result.link === 'string' && result.link.trim().length > 0
        ? result.link.trim()
        : null

      const updated = await options.store.markOutboxDelivered({
        id: row.id,
        link,
        now: resolveNow(),
      })
      if (updated) delivered.push(updated)
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error)
      const failNow = resolveNow()
      const nextAttemptAt = computeBackoffIso(failNow, row.attempts, baseDelayMs, maxDelayMs)
      const updated = await options.store.markOutboxFailed({
        id: row.id,
        error: errorMessage,
        nextAttemptAt,
        now: failNow,
      })
      if (updated) failed.push(updated)
    }
  }

  return {
    claimed: pendingRows.length,
    delivered,
    failed,
  }
}

function computeBackoffIso(
  now: Date,
  previousAttempts: number,
  baseDelayMs: number,
  maxDelayMs: number,
): string {
  const exponent = Math.max(0, previousAttempts)
  const delayMs = Math.min(maxDelayMs, baseDelayMs * Math.pow(2, exponent))
  return new Date(now.getTime() + delayMs).toISOString()
}
