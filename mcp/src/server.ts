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
export const HOLLERKIT_MCP_VERSION = '0.1.0'
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

export function createHollerKitMcpServer(
  config: HollerKitMcpConfig = {},
): HollerKitMcpServer {
  const client = createHollerKitMcpClient(config)

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

  async function callTool(
    name: string,
    args: Record<string, unknown> = {},
  ): Promise<McpCallToolResult> {
    try {
      const toolDef = HOLLERKIT_MCP_TOOLS.find((tool) => tool.name === name)
      if (!toolDef) {
        throw new HollerKitMcpError(404, 'unknown_tool', `Unknown MCP tool: ${name}.`)
      }

      if (!isPlainObject(args)) {
        throw new HollerKitMcpError(
          400,
          'invalid_arguments',
          `Arguments for tool "${name}" must be a JSON object.`,
        )
      }

      const result = await dispatchTool(toolDef.name, args)
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

  async function handleSingleRpc(
    message: unknown,
  ): Promise<JsonRpcResponse | null> {
    if (!isPlainObject(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string') {
      const id = isPlainObject(message) && isValidRpcId(message.id) ? message.id : null
      return jsonRpcError(id, -32600, 'Invalid Request')
    }

    const hasId = Object.prototype.hasOwnProperty.call(message, 'id')
    const id: JsonRpcId = hasId && isValidRpcId(message.id) ? message.id : null
    const method = message.method
    const params = message.params

    // Notifications (requests without an `id` member) produce no response.
    if (!hasId) {
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
          const rawArgs = params.arguments ?? {}
          if (!isPlainObject(rawArgs)) {
            return jsonRpcError(id, -32602, 'Invalid params: tools/call "arguments" must be an object.')
          }
          const toolResult = await callTool(params.name, rawArgs)
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

  async function handleJsonRpc(
    message: unknown,
  ): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
    if (Array.isArray(message)) {
      if (message.length === 0) {
        return jsonRpcError(null, -32600, 'Invalid Request: empty batch')
      }
      const responses = await Promise.all(message.map((item) => handleSingleRpc(item)))
      const filtered = responses.filter((item): item is JsonRpcResponse => item !== null)
      return filtered.length > 0 ? filtered : null
    }
    return handleSingleRpc(message)
  }

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

  function connectStdio(
    input: Readable = process.stdin,
    output: Writable = process.stdout,
  ): { close: () => void } {
    const rl = createInterface({
      input,
      crlfDelay: Infinity,
    })

    let chain = Promise.resolve()
    rl.on('line', (line) => {
      chain = chain
        .then(async () => {
          const reply = await handleJsonRpcLine(line)
          if (reply !== null) {
            output.write(`${reply}\n`)
          }
        })
        .catch(() => {
          // Ignore write failures if output stream closed early
        })
    })

    return {
      close() {
        rl.close()
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

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isValidRpcId(value: unknown): value is JsonRpcId {
  return typeof value === 'string' || typeof value === 'number' || value === null
}
