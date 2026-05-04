export type InputMode = 'text-and-audio' | 'text-only' | 'audio-only'

export type TranscriptPayload = {
  text: string
  locale: string
  engine: 'apple-on-device' | 'apple-network' | 'manual' | 'unavailable'
  confidence?: number
  durationSeconds?: number
}

export type Breadcrumb = {
  timestamp: string
  category?: string
  message: string
  metadata?: Record<string, unknown>
}

export type ReportFileKind = 'image' | 'audio'

export type ReportFile = {
  kind: ReportFileKind
  fieldName: string
  filename: string
  mimeType: string
  size: number
  data: Blob
}

export type ImageFile = ReportFile & { kind: 'image' }
export type AudioFile = ReportFile & { kind: 'audio' }

export type UploadedFile = {
  kind: ReportFileKind
  filename: string
  mimeType: string
  size: number
  url: string
}

export type NormalizedReport = {
  id: string
  createdAt: string
  comment?: string
  transcript?: TranscriptPayload
  metadata: Record<string, unknown>
  breadcrumbs: Breadcrumb[]
  files: {
    images: ImageFile[]
    audio?: AudioFile
  }
  userIdHash?: string
  inputMode: InputMode
}

export type IssueResult = {
  url: string
  number?: number
}

export type ClassifyResult = {
  skip?: boolean
  labels?: string[]
  duplicateOf?: number
  severity?: 'low' | 'med' | 'high'
  metadata?: Record<string, unknown>
}

export type StorageAdapter = {
  upload(reportId: string, files: ReportFile[]): Promise<UploadedFile[]>
}

export type IssueAdapter = {
  createIssue(input: {
    report: NormalizedReport
    uploadedFiles: UploadedFile[]
    classify: ClassifyResult
    body: string
  }): Promise<IssueResult>
  commentIssue?: (issue: IssueResult, body: string) => Promise<void>
  addLabels?: (issue: IssueResult, labels: string[]) => Promise<void>
  assign?: (issue: IssueResult, users: string[]) => Promise<void>
}

export type Classifier = (report: NormalizedReport) => Promise<ClassifyResult> | ClassifyResult

export type DispatchContext = {
  report: NormalizedReport
  issue: IssueResult
  issueAdapter: IssueAdapter
  uploadedFiles: UploadedFile[]
  classify: ClassifyResult
}

export type Dispatcher = (ctx: DispatchContext) => Promise<void> | void

export type DispatchWhen =
  | 'always'
  | { allowlist: string[] }
  | ((report: NormalizedReport) => boolean)

export type LimitConfig = {
  timestampDriftSeconds: number
  maxImages: number
  maxImageBytes: number
  maxAudioBytes: number
  maxAudioDurationSeconds: number
  maxCommentLength: number
  maxTranscriptLength: number
  maxMetadataBytes: number
  maxBreadcrumbs: number
  acceptedImageMimeTypes: string[]
  acceptedAudioMimeTypes: string[]
}

export type CreateBugReportHandlerOptions = {
  appSecret: string
  issue: IssueAdapter
  storage?: StorageAdapter
  limits?: Partial<LimitConfig>
  classify?: Classifier
  dispatch?: {
    when: DispatchWhen
    handler: Dispatcher | Dispatcher[]
  }
  onReport?: (input: {
    report: NormalizedReport
    issue?: IssueResult
    uploadedFiles: UploadedFile[]
    classify: ClassifyResult
    skipped: boolean
  }) => Promise<void> | void
  now?: () => Date
  idGenerator?: () => string
}
