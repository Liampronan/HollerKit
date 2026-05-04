import { HollerKitError } from './errors.ts'
import type { LimitConfig, NormalizedReport } from './types.ts'

export const defaultLimits: LimitConfig = {
  timestampDriftSeconds: 5 * 60,
  maxBodyBytes: 45_000_000,
  maxImages: 5,
  maxImageBytes: 8_000_000,
  maxAudioBytes: 2_000_000,
  maxAudioDurationSeconds: 60,
  maxCommentLength: 10_000,
  maxTranscriptLength: 20_000,
  maxMetadataBytes: 64 * 1024,
  maxBreadcrumbs: 100,
  acceptedImageMimeTypes: ['image/png', 'image/jpeg', 'image/heic', 'image/heif'],
  acceptedAudioMimeTypes: ['audio/mp4', 'audio/aac', 'audio/m4a', 'audio/x-m4a'],
}

export function resolveLimits(overrides: Partial<LimitConfig> = {}): LimitConfig {
  return {
    ...defaultLimits,
    ...overrides,
    acceptedImageMimeTypes:
      overrides.acceptedImageMimeTypes ?? defaultLimits.acceptedImageMimeTypes,
    acceptedAudioMimeTypes:
      overrides.acceptedAudioMimeTypes ?? defaultLimits.acceptedAudioMimeTypes,
  }
}

export function validateContentLength(contentLengthHeader: string | null, limits: LimitConfig): void {
  if (!contentLengthHeader) return

  const contentLength = Number(contentLengthHeader)
  if (!Number.isInteger(contentLength) || contentLength < 0) {
    throw new HollerKitError(400, 'invalid_content_length', 'Content-Length must be a non-negative integer.')
  }

  if (contentLength > limits.maxBodyBytes) {
    throw new HollerKitError(413, 'body_too_large', 'Request body exceeds the configured byte limit.')
  }
}

export function validateTimestamp(timestampHeader: string | null, now: Date, limits: LimitConfig): number {
  if (!timestampHeader) {
    throw new HollerKitError(400, 'missing_timestamp', 'Missing x-hollerkit-timestamp header.')
  }

  const timestamp = Number(timestampHeader)
  if (!Number.isInteger(timestamp) || timestamp <= 0) {
    throw new HollerKitError(400, 'invalid_timestamp', 'Timestamp must be a Unix seconds integer.')
  }

  const drift = Math.abs(Math.floor(now.getTime() / 1000) - timestamp)
  if (drift > limits.timestampDriftSeconds) {
    throw new HollerKitError(401, 'timestamp_out_of_range', 'Timestamp is outside the allowed drift window.')
  }

  return timestamp
}

export function validateReportLimits(report: NormalizedReport, limits: LimitConfig): void {
  if (report.comment && report.comment.length > limits.maxCommentLength) {
    throw new HollerKitError(413, 'comment_too_large', 'Comment exceeds the configured length limit.')
  }

  if (report.transcript?.text && report.transcript.text.length > limits.maxTranscriptLength) {
    throw new HollerKitError(413, 'transcript_too_large', 'Transcript exceeds the configured length limit.')
  }

  const metadataBytes = new TextEncoder().encode(JSON.stringify(report.metadata)).byteLength
  if (metadataBytes > limits.maxMetadataBytes) {
    throw new HollerKitError(413, 'metadata_too_large', 'Metadata exceeds the configured byte limit.')
  }

  if (report.breadcrumbs.length > limits.maxBreadcrumbs) {
    throw new HollerKitError(413, 'too_many_breadcrumbs', 'Breadcrumb count exceeds the configured limit.')
  }

  if (report.files.images.length > limits.maxImages) {
    throw new HollerKitError(413, 'too_many_images', 'Image count exceeds the configured limit.')
  }

  for (const image of report.files.images) {
    if (!limits.acceptedImageMimeTypes.includes(image.mimeType)) {
      throw new HollerKitError(415, 'unsupported_image_type', `Unsupported image MIME type: ${image.mimeType}.`)
    }

    if (image.size > limits.maxImageBytes) {
      throw new HollerKitError(413, 'image_too_large', `${image.filename} exceeds the configured byte limit.`)
    }
  }

  if (report.files.audio) {
    const audio = report.files.audio
    if (!limits.acceptedAudioMimeTypes.includes(audio.mimeType)) {
      throw new HollerKitError(415, 'unsupported_audio_type', `Unsupported audio MIME type: ${audio.mimeType}.`)
    }

    if (audio.size > limits.maxAudioBytes) {
      throw new HollerKitError(413, 'audio_too_large', `${audio.filename} exceeds the configured byte limit.`)
    }

    if (report.transcript?.durationSeconds && report.transcript.durationSeconds > limits.maxAudioDurationSeconds) {
      throw new HollerKitError(413, 'audio_too_long', 'Audio duration exceeds the configured limit.')
    }
  }
}
