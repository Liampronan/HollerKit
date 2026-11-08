import { createInterface } from 'node:readline'
import type { Readable, Writable } from 'node:stream'
import {
  createHollerKitMcpClient,
  HollerKitMcpError,
  type HollerKitMcpClient,
} from './client.js'
import { HOLLERKIT_MCP_TOOLS } from './tools.js'
import type {
  FeedbackGetInput,
  FeedbackInboxInput,
  FeedbackTriageInput,
  HollerKitMcpConfig,
  HollerKitToolName,
  JsonRpcErrorResponse,
  JsonRpcId,
  JsonRpcResponse,
  McpCallToolResult,
  McpToolDefinition,
  QuestsPendingInput,
  QuestsRetirableInput,
} from './types.js'

const DEFAULT_PROTOCOL_VERSION = '2024-11-05'
const DEFAULT_MAX_PENDING_REQUESTS = 64
export const HOLLERKIT_MCP_VERSION = '1.0.0-beta.3'
const SUPPORTED_MCP_PROTOCOL_VERSIONS = new Set([
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
])

export interface HollerKitMcpServer {
  readonly tools: readonly McpToolDefinition[]
  readonly client: HollerKitMcpClient
  callTool(
    name: string,
    args?: Record<string, unknown> | undefined,
  ): Promise<McpCallToolResult>
  handleJsonRpc(
    message: unknown,
  ): Promise<JsonRpcResponse | JsonRpcResponse[] | null>
  handleJsonRpcLine(line: string): Promise<string | null>
  connectStdio(
    input?: Readable,
    output?: Writable,
  ): { close: () => void }
}

/**
 * Creates a HollerKit MCP server exposing the 5 `/v1` coding-agent tools over programmatic and JSON-RPC 2.0 stdio interfaces.
 */
export function createHollerKitMcpServer(
  config: HollerKitMcpConfig = {},
): HollerKitMcpServer {
  const client = createHollerKitMcpClient(config)
  const maxPendingRequests =
    typeof config.maxPendingRequests === 'number' &&
    Number.isInteger(config.maxPendingRequests) &&
    config.maxPendingRequests > 0
      ? config.maxPendingRequests
      : DEFAULT_MAX_PENDING_REQUESTS

  const canceledRequestIds = new Set<string | number>()

  /**
   * Dispatches a validated MCP tool invocation to the corresponding HollerKit `/v1` client method.
   */
  async function dispatchTool(
    name: HollerKitToolName,
    args: Record<string, unknown>,
  ): Promise<unknown> {
    switch (name) {
      case 'feedback_inbox':
        return client.feedbackInbox(args as FeedbackInboxInput)
      case 'feedback_get':
        return client.feedbackGet(args as unknown as FeedbackGetInput)
      case 'feedback_triage':
        return client.feedbackTriage(args as unknown as FeedbackTriageInput)
      case 'quests_pending':
        return client.questsPending(args as unknown as QuestsPendingInput)
      case 'quests_retirable':
        return client.questsRetirable(args as QuestsRetirableInput)
    }
  }

  /**
   * Executes one of the 5 HollerKit MCP tools by name and formats the response as an MCP CallToolResult.
   */
  async function callTool(
    name: string,
    args?: Record<string, unknown> | undefined,
  ): Promise<McpCallToolResult> {
    const resolvedArgs = arguments.length < 2 || args === undefined ? {} : args
    try {
      const toolDef = HOLLERKIT_MCP_TOOLS.find((tool) => tool.name === name)
      if (!toolDef) {
        throw new HollerKitMcpError(404, 'unknown_tool', `Unknown MCP tool: ${name}.`)
      }

      if (!isPlainObject(resolvedArgs)) {
        throw new HollerKitMcpError(
          400,
          'invalid_arguments',
          `Arguments for tool "${name}" must be a JSON object.`,
        )
      }

      validateToolInputSchema(toolDef, resolvedArgs)

      const result = await dispatchTool(toolDef.name, resolvedArgs)
      const structured = isPlainObject(result)
        ? result
        : ({ ok: true, data: result } as Record<string, unknown>)

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(structured, null, 2),
          },
        ],
        structuredContent: structured,
        isError: false,
      }
    } catch (error) {
      const mcpError =
        error instanceof HollerKitMcpError
          ? error
          : new HollerKitMcpError(
              500,
              'internal_error',
              error instanceof Error ? error.message : String(error),
            )
      const errorPayload = mcpError.toJSON()
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(errorPayload, null, 2),
          },
        ],
        structuredContent: errorPayload,
        isError: true,
      }
    }
  }

  /**
   * Processes a single JSON-RPC 2.0 request or notification object.
   */
  async function handleSingleRpc(
    message: unknown,
  ): Promise<JsonRpcResponse | null> {
    if (!isPlainObject(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string') {
      const id = isPlainObject(message) && isValidRpcId(message.id) ? message.id : null
      return jsonRpcError(id, -32600, 'Invalid Request')
    }

    const hasId = Object.prototype.hasOwnProperty.call(message, 'id')
    if (hasId && !isValidRpcId(message.id)) {
      return jsonRpcError(null, -32600, 'Invalid Request: "id" must be a string, number, or null.')
    }
    const id: JsonRpcId = hasId ? (message.id as JsonRpcId) : null
    const method = message.method
    const params = message.params

    if (params !== undefined && !isPlainObject(params) && !Array.isArray(params)) {
      return jsonRpcError(
        id,
        -32600,
        'Invalid Request: "params" must be an object or array when provided.',
      )
    }

    // Notifications (requests without an `id` member) produce no response.
    if (!hasId) {
      recordCancelFromRpcObject(message, canceledRequestIds)
      return null
    }

    if ((typeof id === 'string' || typeof id === 'number') && canceledRequestIds.has(id)) {
      canceledRequestIds.delete(id)
      return null
    }

    try {
      switch (method) {
        case 'initialize': {
          const requestedVersion =
            isPlainObject(params) && typeof params.protocolVersion === 'string'
              ? params.protocolVersion
              : DEFAULT_PROTOCOL_VERSION
          const negotiatedVersion = SUPPORTED_MCP_PROTOCOL_VERSIONS.has(requestedVersion)
            ? requestedVersion
            : DEFAULT_PROTOCOL_VERSION

          return {
            jsonrpc: '2.0',
            id,
            result: {
              protocolVersion: negotiatedVersion,
              capabilities: {
                tools: {
                  listChanged: false,
                },
              },
              serverInfo: {
                name: 'hollerkit-mcp',
                version: HOLLERKIT_MCP_VERSION,
              },
            },
          }
        }

        case 'ping':
          return {
            jsonrpc: '2.0',
            id,
            result: {},
          }

        case 'tools/list':
          return {
            jsonrpc: '2.0',
            id,
            result: {
              tools: HOLLERKIT_MCP_TOOLS,
            },
          }

        case 'tools/call': {
          if (!isPlainObject(params) || typeof params.name !== 'string' || params.name.trim().length === 0) {
            return jsonRpcError(id, -32602, 'Invalid params: tools/call requires a non-empty string "name".')
          }
          const toolDef = HOLLERKIT_MCP_TOOLS.find((tool) => tool.name === params.name)
          if (!toolDef) {
            return jsonRpcError(id, -32602, `Unknown MCP tool: ${params.name}.`)
          }
          const rawArgs = params.arguments === undefined ? {} : params.arguments
          if (!isPlainObject(rawArgs)) {
            return jsonRpcError(id, -32602, 'Invalid params: tools/call "arguments" must be an object.')
          }
          if ((typeof id === 'string' || typeof id === 'number') && canceledRequestIds.has(id)) {
            canceledRequestIds.delete(id)
            return null
          }
          const toolResult = await callTool(toolDef.name, rawArgs)
          return {
            jsonrpc: '2.0',
            id,
            result: toolResult,
          }
        }

        default:
          return jsonRpcError(id, -32601, `Method not found: ${method}`)
      }
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error)
      return jsonRpcError(id, -32603, `Internal error: ${messageText}`)
    }
  }

  /**
   * Handles a parsed JSON-RPC 2.0 message or batch array.
   */
  async function handleJsonRpc(
    message: unknown,
  ): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
    if (Array.isArray(message)) {
      if (message.length === 0) {
        return jsonRpcError(null, -32600, 'Invalid Request: empty batch')
      }
      for (const item of message) {
        if (isPlainObject(item) && !Object.prototype.hasOwnProperty.call(item, 'id')) {
          recordCancelFromRpcObject(item, canceledRequestIds)
        }
      }
      const responses: (JsonRpcResponse | null)[] = []
      for (const item of message) {
        responses.push(await handleSingleRpc(item))
      }
      const filtered = responses.filter((item): item is JsonRpcResponse => item !== null)
      return filtered.length > 0 ? filtered : null
    }
    return handleSingleRpc(message)
  }

  /**
   * Parses and handles a single newline-delimited JSON-RPC 2.0 line.
   */
  async function handleJsonRpcLine(line: string): Promise<string | null> {
    const trimmed = line.trim()
    if (!trimmed) return null

    let parsed: unknown
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      return JSON.stringify(jsonRpcError(null, -32700, 'Parse error'))
    }

    const response = await handleJsonRpc(parsed)
    if (response === null) return null
    return JSON.stringify(response)
  }

  /**
   * Connects the MCP server to newline-delimited JSON-RPC 2.0 input and output streams with bounded queueing, backpressure, cancellation, and error handling.
   */
  function connectStdio(
    input: Readable = process.stdin,
    output: Writable = process.stdout,
  ): { close: () => void } {
    const rl = createInterface({
      input,
      crlfDelay: Infinity,
    })

    const pendingLines: string[] = []
    let processing = false
    let inputPaused = false
    let closed = false

    /**
     * Pauses the input stream when the bounded queue reaches capacity or output backpressure is active.
     */
    const pauseInput = () => {
      if (!inputPaused && !closed) {
        inputPaused = true
        rl.pause()
        input.pause()
      }
    }

    /**
     * Resumes the input stream once queued requests drop below the high-water mark.
     */
    const maybeResumeInput = () => {
      if (inputPaused && !closed && pendingLines.length < maxPendingRequests) {
        inputPaused = false
        input.resume()
        rl.resume()
      }
    }

    /**
     * Shuts down the stdio transport and detaches stream listeners.
     */
    const shutdown = () => {
      if (closed) return
      closed = true
      pendingLines.length = 0
      output.removeListener('error', onStreamError)
      output.removeListener('close', onStreamClose)
      input.removeListener('error', onStreamError)
      rl.close()
    }

    const onStreamError = () => {
      shutdown()
    }

    const onStreamClose = () => {
      shutdown()
    }

    output.on('error', onStreamError)
    output.on('close', onStreamClose)
    input.on('error', onStreamError)

    /**
     * Sequentially drains queued JSON-RPC lines while respecting output backpressure and stream closure.
     */
    const drainQueue = async () => {
      if (processing || closed) return
      processing = true
      try {
        while (pendingLines.length > 0 && !closed) {
          const nextLine = pendingLines.shift()!
          maybeResumeInput()

          const reply = await handleJsonRpcLine(nextLine)
          if (reply !== null && !closed) {
            const canContinue = writeLineSafely(output, `${reply}\n`, shutdown)
            if (!canContinue && !closed) {
              pauseInput()
              await waitForDrainOrClose(output, () => closed)
              maybeResumeInput()
            }
          }
        }
      } finally {
        processing = false
      }
    }

    rl.on('line', (line) => {
      if (closed) return
      if (recordCancellationFromRawLine(line, canceledRequestIds)) {
        return
      }
      pendingLines.push(line)
      if (pendingLines.length >= maxPendingRequests) {
        pauseInput()
      }
      void drainQueue()
    })

    rl.on('close', () => {
      closed = true
      output.removeListener('error', onStreamError)
      output.removeListener('close', onStreamClose)
      input.removeListener('error', onStreamError)
    })

    return {
      close() {
        shutdown()
      },
    }
  }

  return {
    tools: HOLLERKIT_MCP_TOOLS,
    client,
    callTool,
    handleJsonRpc,
    handleJsonRpcLine,
    connectStdio,
  }
}

/**
 * Validates that tool arguments only include properties allowed by the tool's JSON schema.
 */
function validateToolInputSchema(
  toolDef: McpToolDefinition,
  args: Record<string, unknown>,
): void {
  const allowedProps = toolDef.inputSchema.properties
  if (toolDef.inputSchema.additionalProperties === false) {
    for (const key of Object.keys(args)) {
      if (!Object.prototype.hasOwnProperty.call(allowedProps, key)) {
        throw new HollerKitMcpError(
          400,
          'invalid_arguments',
          `Unknown argument "${key}" for tool "${toolDef.name}".`,
        )
      }
    }
  }
}

/**
 * Records a cancellation request ID if the given JSON-RPC notification is a cancellation message.
 */
function recordCancelFromRpcObject(
  message: Record<string, unknown>,
  canceledRequestIds: Set<string | number>,
): boolean {
  if (message.jsonrpc !== '2.0') return false
  if (message.method !== 'notifications/cancelled' && message.method !== '$/cancelRequest') {
    return false
  }
  if (!isPlainObject(message.params)) return false
  const reqId = message.params.requestId ?? message.params.id
  if (typeof reqId === 'string' || typeof reqId === 'number') {
    canceledRequestIds.add(reqId)
    return true
  }
  return false
}

/**
 * Inspects a raw JSON-RPC line on arrival and immediately records any cancellation notifications before queueing.
 */
function recordCancellationFromRawLine(
  line: string,
  canceledRequestIds: Set<string | number>,
): boolean {
  const trimmed = line.trim()
  if (!trimmed.includes('cancel')) return false
  try {
    const parsed: unknown = JSON.parse(trimmed)
    if (
      isPlainObject(parsed) &&
      !Object.prototype.hasOwnProperty.call(parsed, 'id') &&
      recordCancelFromRpcObject(parsed, canceledRequestIds)
    ) {
      return true
    }
  } catch {
    // Let normal line processing report any JSON parse error.
  }
  return false
}

/**
 * Writes a serialized JSON-RPC line to the output stream, shutting down the transport on synchronous error.
 */
function writeLineSafely(
  output: Writable,
  chunk: string,
  onError: () => void,
): boolean {
  if (output.destroyed || !output.writable) {
    onError()
    return true
  }
  try {
    return output.write(chunk, (err) => {
      if (err) {
        onError()
      }
    })
  } catch {
    onError()
    return true
  }
}

/**
 * Waits for a backpressured writable stream to emit `drain`, `close`, or `error`.
 */
function waitForDrainOrClose(
  output: Writable,
  isClosed: () => boolean,
): Promise<void> {
  if (isClosed() || output.destroyed || !output.writable) {
    return Promise.resolve()
  }
  return new Promise<void>((resolve) => {
    const cleanup = () => {
      output.removeListener('drain', onDone)
      output.removeListener('close', onDone)
      output.removeListener('error', onDone)
    }
    const onDone = () => {
      cleanup()
      resolve()
    }
    output.once('drain', onDone)
    output.once('close', onDone)
    output.once('error', onDone)
  })
}

/**
 * Constructs a standard JSON-RPC 2.0 error response envelope.
 */
function jsonRpcError(
  id: JsonRpcId,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcErrorResponse {
  return {
    jsonrpc: '2.0',
    id,
    error: data !== undefined ? { code, message, data } : { code, message },
  }
}

/**
 * Checks whether a value is a non-null, non-array plain object.
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Checks whether a value is a valid JSON-RPC 2.0 request identifier (string, number, or null).
 */
function isValidRpcId(value: unknown): value is JsonRpcId {
  return typeof value === 'string' || typeof value === 'number' || value === null
}
