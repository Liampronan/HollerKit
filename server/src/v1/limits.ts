export interface V1LimitConfig {
  maxJsonBytes: number
  maxTextChars: number
  maxImages: number
  maxImageBytes: number
  maxAudioBytes: number
  maxVideoBytes?: number | undefined
  maxMarks: number
  uploadGrantTtlSeconds: number
  readUrlTtlSeconds: number
  acceptedImageMimeTypes: string[]
  acceptedAudioMimeTypes: string[]
  acceptedVideoMimeTypes: string[]
}

export const defaultV1Limits: V1LimitConfig = {
  maxJsonBytes: 256 * 1024, // 256 KB (262,144 bytes)
  maxTextChars: 20_000, // 20,000 characters
  maxImages: 12, // 12 images per item
  maxImageBytes: 10 * 1024 * 1024, // 10 MB (10,485,760 bytes)
  maxAudioBytes: 10 * 1024 * 1024, // 10 MB (10,485,760 bytes)
  maxMarks: 20, // 20 marks
  uploadGrantTtlSeconds: 10 * 60, // 10 minutes
  readUrlTtlSeconds: 60 * 60, // 1 hour
  acceptedImageMimeTypes: ['image/png', 'image/jpeg', 'image/heic', 'image/heif', 'image/webp'],
  acceptedAudioMimeTypes: ['audio/mp4', 'audio/aac', 'audio/m4a', 'audio/x-m4a', 'audio/mpeg', 'audio/wav'],
  acceptedVideoMimeTypes: ['video/mp4', 'video/quicktime'],
}

export function resolveV1Limits(overrides: Partial<V1LimitConfig> = {}): V1LimitConfig {
  return {
    ...defaultV1Limits,
    ...overrides,
    acceptedImageMimeTypes:
      overrides.acceptedImageMimeTypes ?? defaultV1Limits.acceptedImageMimeTypes,
    acceptedAudioMimeTypes:
      overrides.acceptedAudioMimeTypes ?? defaultV1Limits.acceptedAudioMimeTypes,
    acceptedVideoMimeTypes:
      overrides.acceptedVideoMimeTypes ?? defaultV1Limits.acceptedVideoMimeTypes,
  }
}

export type LimitConfig = V1LimitConfig
export const defaultLimits = defaultV1Limits
export const resolveLimits = resolveV1Limits
