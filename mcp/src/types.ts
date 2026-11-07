export type FeedbackKind = 'report' | 'quest_run'
export type QuestResult = 'pass' | 'fail' | 'unsure' | 'abandoned'
export type TriageStatus = 'new' | 'triaged' | 'resolved' | 'wontfix' | 'duplicate'
export type QuestRecordMode = 'none' | 'optional' | 'suggested' | 'required'
export type QuestStatus = 'draft' | 'active' | 'superseded' | 'retired'
export type AttachmentKind = 'image' | 'audio' | 'video' | 'keyframe' | 'mark'

export type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>

export interface HollerKitMcpConfig {
  baseUrl?: string | undefined
  apiKey?: string | undefined
  fetch?: FetchLike | undefined
  protocolVersion?: string | undefined
}

export interface FeedbackItem {
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
  counts: {
    pass: number
    fail: number
    unsure: number
    abandoned: number
  }
  passedOnCurrentVersion: boolean
}

export interface FeedbackEventView {
  id: number
  feedbackId?: string | undefined
  offsetSeconds: number
  kind: string
  payload: Record<string, unknown>
}

export interface TriageEntry {
  id: number
  feedbackId: string
  status: TriageStatus
  summary: string
  links: string[]
  actor: string | null
  createdAt: string
}

export interface FeedbackAttachmentView {
  id: string
  feedbackId: string
  kind: AttachmentKind
  key: string
  mimeType: string
  size: number
  offsetSeconds: number | null
  videoStartOffsetSeconds: number | null
  url: string
  expiresAt: string
  createdAt: string
}

export interface FeedbackInboxInput {
  kind?: FeedbackKind | undefined
  result?: QuestResult | undefined
  triage?: TriageStatus | 'all' | null | undefined
  area?: string | undefined
  since?: string | undefined
  build?: string | undefined
  questId?: string | undefined
  limit?: number | undefined
  cursor?: string | undefined
}

export interface FeedbackInboxOutput {
  ok: true
  items: FeedbackItem[]
  nextCursor: string | null
}

export interface FeedbackGetInput {
  id: string
}

export interface FeedbackGetOutput {
  ok: true
  feedback: FeedbackItem
  quest: QuestVersionRecord | null
  events: FeedbackEventView[]
  triage: TriageEntry[]
  attachments: FeedbackAttachmentView[]
}

export interface FeedbackTriageInput {
  id: string
  status: TriageStatus
  summary: string
  links?: string[] | undefined
  actor?: string | null | undefined
}

export interface FeedbackTriageOutput {
  ok: true
  feedback: FeedbackItem
  triage: TriageEntry
}

export interface QuestsPendingInput {
  build: string
}

export interface QuestsPendingOutput {
  ok: true
  build: string
  pendingCount: number
  quests: QuestVersionRecord[]
}

export interface QuestsRetirableInput {
  area?: string | undefined
}

export interface QuestsRetirableOutput {
  ok: true
  quests: QuestVersionRecord[]
}

export type HollerKitToolName =
  | 'feedback_inbox'
  | 'feedback_get'
  | 'feedback_triage'
  | 'quests_pending'
  | 'quests_retirable'

export interface McpToolDefinition {
  name: HollerKitToolName
  description: string
  inputSchema: {
    type: 'object'
    properties: Record<string, unknown>
    required?: string[]
    additionalProperties?: boolean
  }
}

export interface McpTextContent {
  type: 'text'
  text: string
}

export interface McpCallToolResult<T = Record<string, unknown>> {
  content: McpTextContent[]
  structuredContent: T
  isError: boolean
}

export type JsonRpcId = string | number | null

export interface JsonRpcRequest {
  jsonrpc: '2.0'
  id?: JsonRpcId
  method: string
  params?: unknown
}

export interface JsonRpcSuccessResponse {
  jsonrpc: '2.0'
  id: JsonRpcId
  result: unknown
}

export interface JsonRpcErrorObject {
  code: number
  message: string
  data?: unknown
}

export interface JsonRpcErrorResponse {
  jsonrpc: '2.0'
  id: JsonRpcId
  error: JsonRpcErrorObject
}

export type JsonRpcResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse
