import { HollerKitError } from './errors.ts'
import type {
  AudioFile,
  Breadcrumb,
  ImageFile,
  InputMode,
  NormalizedReport,
  TranscriptPayload,
} from './types.ts'

const inputModes = new Set<InputMode>(['text-and-audio', 'text-only', 'audio-only'])
const transcriptEngines = new Set<TranscriptPayload['engine']>([
  'apple-on-device',
  'apple-network',
  'manual',
  'unavailable',
])

export async function normalizeReport(input: {
  request: Request
  body: ArrayBuffer
  now: Date
  id: string
}): Promise<NormalizedReport> {
  const contentType = input.request.headers.get('content-type') ?? ''
  if (!contentType.toLowerCase().includes('multipart/form-data')) {
    throw new HollerKitError(415, 'unsupported_content_type', 'Expected multipart/form-data.')
  }

  const requestForFormData = new Request(input.request.url, {
    method: input.request.method,
    headers: input.request.headers,
    body: input.body,
  })

  const formData = await requestForFormData.formData()
  const inputMode = parseInputMode(formData.get('inputMode'))
  const transcript = parseTranscript(formData.get('transcript'))
  const metadata = parseObject(formData.get('metadata'), 'metadata')
  const breadcrumbs = parseBreadcrumbs(formData.get('breadcrumbs'))
  const images = formData.getAll('image').map((value, index) => parseFile(value, 'image', index)) as ImageFile[]
  const audioEntries = formData.getAll('audio')

  if (audioEntries.length > 1) {
    throw new HollerKitError(413, 'too_many_audio_files', 'Only one audio file may be submitted.')
  }

  const audio = audioEntries[0] ? parseFile(audioEntries[0], 'audio', 0) as AudioFile : undefined
  const comment = parseOptionalString(formData.get('comment'), 'comment')
  const userIdHash = parseOptionalString(formData.get('userIdHash'), 'userIdHash')

  if (inputMode === 'text-only' && audio) {
    throw new HollerKitError(400, 'audio_not_allowed', 'Text-only reports cannot include audio.')
  }

  if (inputMode === 'audio-only' && comment) {
    throw new HollerKitError(400, 'comment_not_allowed', 'Audio-only reports should not include a typed comment.')
  }

  if (!comment && !transcript?.text && images.length === 0 && !audio) {
    throw new HollerKitError(400, 'empty_report', 'Report must include a comment, transcript, image, or audio file.')
  }

  const files: NormalizedReport['files'] = { images }
  if (audio) files.audio = audio

  const report: NormalizedReport = {
    id: input.id,
    createdAt: input.now.toISOString(),
    metadata,
    breadcrumbs,
    files,
    inputMode,
  }
  if (comment) report.comment = comment
  if (transcript) report.transcript = transcript
  if (userIdHash) report.userIdHash = userIdHash
  return report
}

function parseInputMode(value: FormDataEntryValue | null): InputMode {
  if (typeof value !== 'string') return 'text-and-audio'
  if (!inputModes.has(value as InputMode)) {
    throw new HollerKitError(400, 'invalid_input_mode', 'Invalid inputMode value.')
  }

  return value as InputMode
}

function parseOptionalString(value: FormDataEntryValue | null, field: string): string | undefined {
  if (value == null || value === '') return undefined
  if (typeof value !== 'string') {
    throw new HollerKitError(400, 'invalid_field', `${field} must be a string.`)
  }
  return value
}

function parseObject(value: FormDataEntryValue | null, field: string): Record<string, unknown> {
  if (value == null || value === '') return {}
  if (typeof value !== 'string') {
    throw new HollerKitError(400, 'invalid_json', `${field} must be a JSON object.`)
  }

  const parsed = parseJson(value, field)
  if (!isPlainObject(parsed)) {
    throw new HollerKitError(400, 'invalid_json', `${field} must be a JSON object.`)
  }

  return parsed
}

function parseTranscript(value: FormDataEntryValue | null): TranscriptPayload | undefined {
  if (value == null || value === '') return undefined
  if (typeof value !== 'string') {
    throw new HollerKitError(400, 'invalid_transcript', 'transcript must be a JSON object.')
  }

  const parsed = parseJson(value, 'transcript')
  if (!isPlainObject(parsed)) {
    throw new HollerKitError(400, 'invalid_transcript', 'transcript must be a JSON object.')
  }

  if (typeof parsed.text !== 'string' || typeof parsed.locale !== 'string') {
    throw new HollerKitError(400, 'invalid_transcript', 'transcript requires text and locale strings.')
  }

  if (!transcriptEngines.has(parsed.engine as TranscriptPayload['engine'])) {
    throw new HollerKitError(400, 'invalid_transcript', 'transcript has an invalid engine.')
  }

  const transcript: TranscriptPayload = {
    text: parsed.text,
    locale: parsed.locale,
    engine: parsed.engine as TranscriptPayload['engine'],
  }
  if (typeof parsed.confidence === 'number') transcript.confidence = parsed.confidence
  if (typeof parsed.durationSeconds === 'number') transcript.durationSeconds = parsed.durationSeconds
  return transcript
}

function parseBreadcrumbs(value: FormDataEntryValue | null): Breadcrumb[] {
  if (value == null || value === '') return []
  if (typeof value !== 'string') {
    throw new HollerKitError(400, 'invalid_breadcrumbs', 'breadcrumbs must be a JSON array.')
  }

  const parsed = parseJson(value, 'breadcrumbs')
  if (!Array.isArray(parsed)) {
    throw new HollerKitError(400, 'invalid_breadcrumbs', 'breadcrumbs must be a JSON array.')
  }

  return parsed.map((item, index) => {
    if (!isPlainObject(item) || typeof item.message !== 'string') {
      throw new HollerKitError(400, 'invalid_breadcrumbs', `breadcrumb ${index} is invalid.`)
    }

    const breadcrumb: Breadcrumb = {
      timestamp: typeof item.timestamp === 'string' ? item.timestamp : new Date(0).toISOString(),
      message: item.message,
    }
    if (typeof item.category === 'string') breadcrumb.category = item.category
    if (isPlainObject(item.metadata)) breadcrumb.metadata = item.metadata
    return breadcrumb
  })
}

function parseFile(value: FormDataEntryValue, kind: 'image' | 'audio', index: number): ImageFile | AudioFile {
  if (!(value instanceof File)) {
    throw new HollerKitError(400, 'invalid_file', `${kind} entry ${index} must be a file.`)
  }

  return {
    kind,
    fieldName: kind,
    filename: value.name || `${kind}-${index}`,
    mimeType: value.type || 'application/octet-stream',
    size: value.size,
    data: value,
  } as ImageFile | AudioFile
}

function parseJson(value: string, field: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    throw new HollerKitError(400, 'invalid_json', `${field} contains invalid JSON.`)
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
