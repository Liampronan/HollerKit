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
  /**
   * Stable outbox row identifier (`hollerkit.outbox.id`) preserved across retries
   * for at-least-once delivery deduplication.
   */
  deliveryId?: number | undefined
  /**
   * Stable string idempotency key (`outbox:<id>`) preserved across retries.
   */
  deliveryKey?: string | undefined
  /**
   * Number of prior failed delivery attempts for this outbox item (`0` on first attempt).
   */
  attempts?: number | undefined
}

export interface HollerKitSinkDeliveryContext {
  signal: AbortSignal
  deliveryId: number
  deliveryKey: string
  attempts?: number | undefined
}

/**
 * Notification sink invoked by `flushOutbox` under an at-least-once delivery contract.
 * Sinks should use `detail.deliveryKey` (or `detail.deliveryId`) to deduplicate retries.
 */
export interface HollerKitSink {
  name: string
  when?: ((feedback: FeedbackRecord) => boolean) | undefined
  deliver(
    feedback: FeedbackDetail,
    context?: HollerKitSinkDeliveryContext,
  ): Promise<{ link?: string | undefined } | void>
}

export interface FlushOutboxOptions {
  store: HollerKitStore
  storage?: HollerKitStorageAdapter | undefined
  sinks: HollerKitSink[]
  feedbackId?: string | undefined
  limit?: number | undefined
  leaseMs?: number | undefined
  deliveryTimeoutMs?: number | undefined
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

/**
 * Default predicate for notification sinks: fires on bug reports and failed/unsure quest runs.
 */
export function defaultSinkWhen(feedback: FeedbackRecord): boolean {
  return (
    feedback.kind === 'report' ||
    feedback.result === 'fail' ||
    feedback.result === 'unsure'
  )
}

/**
 * Evaluates whether a sink should be enqueued for the given feedback item.
 */
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

/**
 * Validates that every configured sink has a non-empty, unique name.
 */
export function validateUniqueSinks<T extends HollerKitSink | string>(
  sinks: ReadonlyArray<T>,
): Map<string, T> {
  const byName = new Map<string, T>()
  for (const sink of sinks) {
    const rawName = typeof sink === 'string' ? sink : sink.name
    const name = rawName?.trim()
    if (!name) {
      throw new Error('Sink name must be a non-empty string.')
    }
    if (byName.has(name)) {
      throw new Error(`Duplicate sink registration: "${name}".`)
    }
    byName.set(name, sink)
  }
  return byName
}

/**
 * Claims pending outbox rows, invokes matching sinks with a bounded deadline,
 * and records delivery links or exponential retry backoff.
 */
export async function flushOutbox(options: FlushOutboxOptions): Promise<FlushOutboxResult> {
  const sinksByName = validateUniqueSinks(options.sinks)

  const resolveNow = (): Date => {
    if (typeof options.now === 'function') return options.now()
    if (options.now instanceof Date) return options.now
    return new Date()
  }

  const now = resolveNow()
  const baseDelayMs = options.baseDelayMs ?? 30_000
  const maxDelayMs = options.maxDelayMs ?? 3_600_000
  const readUrlTtlSeconds = options.readUrlTtlSeconds ?? 3600
  const deliveryTimeoutMs = options.deliveryTimeoutMs ?? 30_000

  const pendingRows = await options.store.claimPendingOutbox({
    feedbackId: options.feedbackId,
    limit: options.limit,
    leaseMs: options.leaseMs,
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

      const deliveryId = row.id
      const deliveryKey = `outbox:${row.id}`
      const payload: FeedbackDetail = {
        ...detail,
        attachments,
        deliveryId,
        deliveryKey,
        attempts: row.attempts,
      }

      const result = await deliverWithDeadline(
        sink,
        payload,
        deliveryId,
        deliveryKey,
        row.attempts,
        deliveryTimeoutMs,
      )

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

/**
 * Invokes `sink.deliver` bounded by a deadline timer and `AbortSignal`.
 */
async function deliverWithDeadline(
  sink: HollerKitSink,
  payload: FeedbackDetail,
  deliveryId: number,
  deliveryKey: string,
  attempts: number,
  timeoutMs: number,
): Promise<{ link?: string | undefined } | void> {
  const controller = new AbortController()
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeoutPromise = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new Error(`Sink "${sink.name}" delivery timed out after ${timeoutMs}ms.`))
    }, timeoutMs)
  })

  try {
    return await Promise.race([
      sink.deliver(payload, {
        signal: controller.signal,
        deliveryId,
        deliveryKey,
        attempts,
      }),
      timeoutPromise,
    ])
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer)
    }
  }
}

/**
 * Computes the next retry timestamp using capped exponential backoff.
 */
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
