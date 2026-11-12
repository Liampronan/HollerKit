import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { PassThrough } from 'node:stream'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import {
  apiKeysAuthenticator,
  createHollerKitServer,
  fakeStorage,
  hashApiKey,
  memoryStore,
  staticTokens,
} from '../../server/dist/index.js'
import {
  createHollerKitMcpServer,
  HOLLERKIT_MCP_TOOLS,
  HOLLERKIT_MCP_VERSION,
  type FeedbackGetOutput,
  type FeedbackInboxOutput,
  type FeedbackTriageOutput,
  type JsonRpcErrorResponse,
  type JsonRpcSuccessResponse,
  type McpCallToolResult,
  type QuestsPendingOutput,
  type QuestsRetirableOutput,
} from '../dist/index.js'

const execFileAsync = promisify(execFile)

const BASE_URL = 'https://example.supabase.co/functions/v1/hollerkit'

/**
 * Creates an in-process HollerKit v1 test server seeded with quests, build manifests, upload grants, and feedback items.
 */
async function createSeededTestHarness() {
  const store = memoryStore()
  const storage = fakeStorage({
    baseUrl: 'https://storage.hollerkit.test',
    now: () => new Date('2026-04-20T12:00:00.000Z'),
  })

  const testerToken = 'jwt-tester-alice'
  const questsWriteKey = 'hk_ci_quests_write_key'
  const agentFullKey = 'hk_agent_full_key'
  const agentReadOnlyKey = 'hk_agent_read_only_key'

  await store.createApiKey({
    keyHash: hashApiKey(questsWriteKey),
    keyPrefix: 'hk_ci_quests',
    label: 'ci-sync',
    scopes: ['quests:write'],
  })

  await store.createApiKey({
    keyHash: hashApiKey(agentFullKey),
    keyPrefix: 'hk_agent_ful',
    label: 'codex-agent',
    scopes: ['agent:read', 'agent:triage'],
  })

  await store.createApiKey({
    keyHash: hashApiKey(agentReadOnlyKey),
    keyPrefix: 'hk_agent_rea',
    label: 'readonly-agent',
    scopes: ['agent:read'],
  })

  const observedRequests: { url: string; method: string; auth: string | null; protocol: string | null }[] = []

  const v1Handler = createHollerKitServer({
    store,
    storage,
    now: () => new Date('2026-04-20T12:00:00.000Z'),
    authenticate: [
      staticTokens({
        [testerToken]: {
          principalId: 'tester-alice',
          scopes: ['tester'],
          kind: 'tester',
          label: 'Alice',
        },
      }),
      apiKeysAuthenticator({ store }),
    ],
  })

  const inProcessFetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    observedRequests.push({
      url: request.url,
      method: request.method,
      auth: request.headers.get('authorization'),
      protocol: request.headers.get('hollerkit-protocol'),
    })
    return v1Handler(request)
  }

  // 1a. Initial sync including `camera-flash-retired-passed` so we can pass it and then retire it
  const initialSyncRes = await inProcessFetch(`${BASE_URL}/v1/quests`, {
    method: 'PUT',
    headers: {
      authorization: `Bearer ${questsWriteKey}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      version: 1,
      sha: '000init',
      pr: 39,
      quests: [
        {
          id: 'camera-flash-retired-passed',
          title: 'Camera flash toggle persists across mode switches',
          area: 'camera',
          setup: [],
          steps: ['Toggle flash on', 'Switch mode'],
          expect: ['Flash remains enabled'],
          needs: [],
          record: 'optional',
          start: 'hollerkit://camera',
        },
      ],
    }),
  })
  assert.equal(initialSyncRes.status, 200)

  const retiredPassRes = await inProcessFetch(`${BASE_URL}/v1/feedback`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      id: '44444444-4444-4444-8444-444444444444',
      kind: 'quest_run',
      questId: 'camera-flash-retired-passed',
      questVersion: 1,
      result: 'pass',
      build: '104',
      stepsChecked: [true, true],
    }),
  })
  assert.equal(retiredPassRes.status, 201)

  // 1b. Sync canonical quests via PUT /v1/quests (retiring `camera-flash-retired-passed` and adding active quests)
  const syncRes = await inProcessFetch(`${BASE_URL}/v1/quests`, {
    method: 'PUT',
    headers: {
      authorization: `Bearer ${questsWriteKey}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      version: 1,
      sha: 'abc1234',
      pr: 42,
      quests: [
        {
          id: 'feed-scroll-restore',
          title: 'Feed scroll position restores after detail back navigation',
          area: 'feed',
          setup: ['Sign in with test account'],
          steps: ['Scroll down 10 items', 'Tap item 10', 'Swipe back'],
          expect: ['Feed remains anchored at item 10'],
          needs: [],
          record: 'suggested',
          start: 'hollerkit://feed',
          source: { pr: 40, sha: '111aaaa', added: '2026-04-18' },
        },
        {
          id: 'camera-flip-latency',
          title: 'Camera flip transition stays smooth while recording',
          area: 'camera',
          setup: ['Grant camera + microphone permissions'],
          steps: ['Start recording', 'Tap flip camera twice', 'Stop recording'],
          expect: ['Preview does not freeze', 'Saved clip has continuous audio'],
          needs: ['physical-device'],
          record: 'required',
          start: 'hollerkit://camera',
          source: { pr: 41, sha: '222bbbb', added: '2026-04-19' },
        },
        {
          id: 'camera-zoom-active-unpassed',
          title: 'Pinch-to-zoom smoothly interpolates up to 3x',
          area: 'camera',
          setup: [],
          steps: ['Pinch out on viewfinder'],
          expect: ['Zoom indicator reaches 3.0x smoothly'],
          needs: [],
          record: 'optional',
          start: 'hollerkit://camera',
        },
      ],
    }),
  })
  assert.equal(syncRes.status, 200)

  // 2. Register build 105 manifest via POST /v1/builds/105/manifest
  const manifestRes = await inProcessFetch(`${BASE_URL}/v1/builds/105/manifest`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      appVersion: '1.2.0',
      quests: [
        {
          id: 'feed-scroll-restore',
          title: 'Feed scroll position restores after detail back navigation',
          area: 'feed',
          setup: ['Sign in with test account'],
          steps: ['Scroll down 10 items', 'Tap item 10', 'Swipe back'],
          expect: ['Feed remains anchored at item 10'],
          needs: [],
          record: 'suggested',
          start: 'hollerkit://feed',
        },
        {
          id: 'camera-flip-latency',
          title: 'Camera flip transition stays smooth while recording',
          area: 'camera',
          setup: ['Grant camera + microphone permissions'],
          steps: ['Start recording', 'Tap flip camera twice', 'Stop recording'],
          expect: ['Preview does not freeze', 'Saved clip has continuous audio'],
          needs: ['physical-device'],
          record: 'required',
          start: 'hollerkit://camera',
        },
      ],
    }),
  })
  assert.equal(manifestRes.status, 200)

  // 3. Reserve an upload grant and submit a failed quest run with attachments + events
  const failedQuestFeedbackId = '11111111-1111-4111-8111-111111111111'
  const grantRes = await inProcessFetch(`${BASE_URL}/v1/uploads`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      feedbackId: failedQuestFeedbackId,
      kind: 'image',
      mimeType: 'image/png',
      size: 4096,
    }),
  })
  assert.equal(grantRes.status, 200)
  const grantBody = (await grantRes.json()) as { ok: true; key: string; url: string; expiresAt: string }

  const failFeedbackRes = await inProcessFetch(`${BASE_URL}/v1/feedback`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      id: failedQuestFeedbackId,
      kind: 'quest_run',
      questId: 'feed-scroll-restore',
      questVersion: 1,
      result: 'fail',
      build: '105',
      appVersion: '1.2.0',
      device: 'iPhone 16 Pro',
      os: 'iOS 18.4',
      comment: 'Jumped back to top of feed on swipe back.',
      transcript: 'I scrolled down to item 10, tapped it, and swiped back, and it jumped to item 1.',
      stepsChecked: [true, true, false],
      events: [
        { offsetSeconds: 5.2, kind: 'mark', payload: { label: 'Jumped to top' } },
        { offsetSeconds: 1.1, kind: 'step_checked', payload: { index: 0 } },
        { offsetSeconds: 3.4, kind: 'navigation', payload: { screen: 'FeedDetail' } },
      ],
      attachments: [
        {
          key: grantBody.key,
          kind: 'image',
          mimeType: 'image/png',
          size: 4096,
          offsetSeconds: 5.2,
        },
      ],
    }),
  })
  assert.equal(failFeedbackRes.status, 201)

  // 4. Submit a classic shake-sheet bug report (`kind: 'report'`)
  const bugReportFeedbackId = '22222222-2222-4222-8222-222222222222'
  const reportRes = await inProcessFetch(`${BASE_URL}/v1/feedback`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      id: bugReportFeedbackId,
      kind: 'report',
      build: '105',
      appVersion: '1.2.0',
      device: 'iPhone 16 Pro',
      os: 'iOS 18.4',
      comment: 'Dark mode badge contrast is too low on settings row.',
    }),
  })
  assert.equal(reportRes.status, 201)

  // 5. Submit a passing quest run for `camera-flip-latency`
  const passQuestFeedbackId = '33333333-3333-4333-8333-333333333333'
  const passRes = await inProcessFetch(`${BASE_URL}/v1/feedback`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${testerToken}`,
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    },
    body: JSON.stringify({
      id: passQuestFeedbackId,
      kind: 'quest_run',
      questId: 'camera-flip-latency',
      questVersion: 1,
      result: 'pass',
      build: '105',
      appVersion: '1.2.0',
      device: 'iPhone 16 Pro',
      os: 'iOS 18.4',
      stepsChecked: [true, true, true],
    }),
  })
  assert.equal(passRes.status, 201)

  observedRequests.length = 0

  return {
    store,
    storage,
    inProcessFetch,
    observedRequests,
    agentFullKey,
    agentReadOnlyKey,
    failedQuestFeedbackId,
    bugReportFeedbackId,
    passQuestFeedbackId,
    grantKey: grantBody.key,
  }
}

test('exercises all 6 MCP tools end-to-end via callTool dispatcher and verifies protocol headers', async () => {
  const harness = await createSeededTestHarness()

  const mcp = createHollerKitMcpServer({
    baseUrl: `${BASE_URL}/`,
    apiKey: harness.agentFullKey,
    fetch: harness.inProcessFetch,
  })

  assert.equal(mcp.tools.length, 6)
  assert.deepEqual(
    mcp.tools.map((t) => t.name),
    [
      'feedback_inbox',
      'feedback_get',
      'feedback_triage',
      'quests_pending',
      'quests_retirable',
      'values_query',
    ],
  )

  // 1. feedback_inbox (defaults to triage='new' -> returns report + failed quest, excludes passing quest)
  const inboxCall = (await mcp.callTool('feedback_inbox', {})) as McpCallToolResult<FeedbackInboxOutput>
  assert.equal(inboxCall.isError, false)
  assert.equal(inboxCall.structuredContent.ok, true)
  assert.equal(inboxCall.structuredContent.items.length, 2)
  const inboxIds = inboxCall.structuredContent.items.map((item) => item.id).sort()
  assert.deepEqual(inboxIds, [harness.failedQuestFeedbackId, harness.bugReportFeedbackId].sort())

  // Filter feedback_inbox by kind='quest_run' and area='feed'
  const filteredInbox = (await mcp.callTool('feedback_inbox', {
    kind: 'quest_run',
    area: 'feed',
  })) as McpCallToolResult<FeedbackInboxOutput>
  assert.equal(filteredInbox.isError, false)
  assert.equal(filteredInbox.structuredContent.items.length, 1)
  assert.equal(filteredInbox.structuredContent.items[0]?.id, harness.failedQuestFeedbackId)

  // 2. feedback_get -> returns feedback, quest version, timeline events sorted by offsetSeconds, triage, and signed 1-hr attachment URL
  const detailCall = (await mcp.callTool('feedback_get', {
    id: harness.failedQuestFeedbackId,
  })) as McpCallToolResult<FeedbackGetOutput>
  assert.equal(detailCall.isError, false)
  assert.equal(detailCall.structuredContent.ok, true)
  assert.equal(detailCall.structuredContent.feedback.id, harness.failedQuestFeedbackId)
  assert.equal(detailCall.structuredContent.quest?.id, 'feed-scroll-restore')
  assert.equal(detailCall.structuredContent.quest?.version, 1)
  assert.deepEqual(
    detailCall.structuredContent.events.map((e) => e.offsetSeconds),
    [1.1, 3.4, 5.2],
  )
  assert.equal(detailCall.structuredContent.attachments.length, 1)
  assert.equal(detailCall.structuredContent.attachments[0]?.key, harness.grantKey)
  assert.match(
    detailCall.structuredContent.attachments[0]?.url ?? '',
    /^https:\/\/storage\.hollerkit\.test\/read\//,
  )
  assert.equal(
    detailCall.structuredContent.attachments[0]?.expiresAt,
    '2026-04-20T13:00:00.000Z',
  )

  // 3. feedback_triage -> updates feedback triage fields and appends triage audit entry
  const triageCall = (await mcp.callTool('feedback_triage', {
    id: harness.failedQuestFeedbackId,
    status: 'resolved',
    summary: 'Preserved scroll anchor in FeedViewController via UICollectionView diffable snapshot.',
    links: ['https://github.com/Liampronan/HollerKit/pull/99'],
    actor: 'claude-code',
  })) as McpCallToolResult<FeedbackTriageOutput>
  assert.equal(triageCall.isError, false)
  assert.equal(triageCall.structuredContent.ok, true)
  assert.equal(triageCall.structuredContent.feedback.triageStatus, 'resolved')
  assert.equal(
    triageCall.structuredContent.feedback.triageSummary,
    'Preserved scroll anchor in FeedViewController via UICollectionView diffable snapshot.',
  )
  assert.deepEqual(triageCall.structuredContent.feedback.links, [
    'https://github.com/Liampronan/HollerKit/pull/99',
  ])
  assert.equal(triageCall.structuredContent.triage.actor, 'claude-code')

  // Verify feedback_inbox with default triage='new' now only has the untriaged bug report
  const inboxAfterTriage = (await mcp.callTool(
    'feedback_inbox',
    {},
  )) as McpCallToolResult<FeedbackInboxOutput>
  assert.equal(inboxAfterTriage.structuredContent.items.length, 1)
  assert.equal(inboxAfterTriage.structuredContent.items[0]?.id, harness.bugReportFeedbackId)

  // 4. quests_pending -> returns only feed-scroll-restore (since camera-flip-latency passed)
  const pendingCall = (await mcp.callTool('quests_pending', {
    build: '105',
  })) as McpCallToolResult<QuestsPendingOutput>
  assert.equal(pendingCall.isError, false)
  assert.equal(pendingCall.structuredContent.ok, true)
  assert.equal(pendingCall.structuredContent.build, '105')
  assert.equal(pendingCall.structuredContent.pendingCount, 1)
  assert.equal(pendingCall.structuredContent.quests.length, 1)
  assert.equal(pendingCall.structuredContent.quests[0]?.id, 'feed-scroll-restore')

  // 5. quests_retirable -> returns camera-flip-latency (active + passedOnCurrentVersion=true),
  // and excludes same-area active-unpassed (`camera-zoom-active-unpassed`) and retired-passed (`camera-flash-retired-passed`) quests.
  const retirableCall = (await mcp.callTool('quests_retirable', {
    area: 'camera',
  })) as McpCallToolResult<QuestsRetirableOutput>
  assert.equal(retirableCall.isError, false)
  assert.equal(retirableCall.structuredContent.ok, true)
  const retirableIds = retirableCall.structuredContent.quests.map((q) => q.id)
  assert.deepEqual(retirableIds, ['camera-flip-latency'])
  assert.ok(!retirableIds.includes('camera-zoom-active-unpassed'))
  assert.ok(!retirableIds.includes('camera-flash-retired-passed'))
  assert.equal(retirableCall.structuredContent.quests[0]?.passedOnCurrentVersion, true)

  // 6. values_query -> queries measurements and captures
  const valuesCall = (await mcp.callTool('values_query', {})) as McpCallToolResult<any>
  assert.equal(valuesCall.isError, false)
  assert.equal(valuesCall.structuredContent.ok, true)

  // Verify every request sent Authorization: Bearer <apiKey> and hollerkit-protocol: 1
  assert.ok(harness.observedRequests.length >= 6)
  for (const req of harness.observedRequests) {
    assert.equal(req.auth, `Bearer ${harness.agentFullKey}`)
    assert.equal(req.protocol, '1')
  }
})

test('exercises full JSON-RPC 2.0 stdio protocol (initialize, notifications/initialized, tools/list, tools/call)', async () => {
  const harness = await createSeededTestHarness()

  const prevUrl = process.env.HOLLERKIT_URL
  const prevKey = process.env.HOLLERKIT_API_KEY
  process.env.HOLLERKIT_URL = `${BASE_URL}/v1`
  process.env.HOLLERKIT_API_KEY = harness.agentFullKey

  try {
    const mcp = createHollerKitMcpServer({
      fetch: harness.inProcessFetch,
    })

    const input = new PassThrough()
    const output = new PassThrough()

    const outputLines: string[] = []
    let buffer = ''
    output.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8')
      let newlineIdx = buffer.indexOf('\n')
      while (newlineIdx >= 0) {
        const line = buffer.slice(0, newlineIdx).trim()
        buffer = buffer.slice(newlineIdx + 1)
        if (line.length > 0) {
          outputLines.push(line)
        }
        newlineIdx = buffer.indexOf('\n')
      }
    })

    const waitForLines = async (count: number) => {
      const deadline = Date.now() + 2000
      while (outputLines.length < count && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 5))
      }
      assert.equal(outputLines.length, count)
    }

    const connection = mcp.connectStdio(input, output)

    // 1. initialize
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2024-11-05',
          capabilities: {},
          clientInfo: { name: 'test-client', version: '1.0.0' },
        },
      })}\n`,
    )
    // 2. notifications/initialized (must not emit a response)
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        method: 'notifications/initialized',
      })}\n`,
    )
    // 3. tools/list
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 2,
        method: 'tools/list',
      })}\n`,
    )
    // 4. tools/call for all 5 tools
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 3,
        method: 'tools/call',
        params: {
          name: 'feedback_inbox',
          arguments: { triage: 'new' },
        },
      })}\n`,
    )
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 4,
        method: 'tools/call',
        params: {
          name: 'feedback_get',
          arguments: { id: harness.failedQuestFeedbackId },
        },
      })}\n`,
    )
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 5,
        method: 'tools/call',
        params: {
          name: 'feedback_triage',
          arguments: {
            id: harness.bugReportFeedbackId,
            status: 'triaged',
            summary: 'Confirmed contrast issue on iOS 18 dark mode.',
          },
        },
      })}\n`,
    )
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 6,
        method: 'tools/call',
        params: {
          name: 'quests_pending',
          arguments: { build: '105' },
        },
      })}\n`,
    )
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 7,
        method: 'tools/call',
        params: {
          name: 'quests_retirable',
          arguments: {},
        },
      })}\n`,
    )
    input.write(
      `${JSON.stringify({
        jsonrpc: '2.0',
        id: 8,
        method: 'tools/call',
        params: {
          name: 'values_query',
          arguments: {},
        },
      })}\n`,
    )

    await waitForLines(8)
    connection.close()

    const responses = outputLines.map((line) => JSON.parse(line) as JsonRpcSuccessResponse)
    assert.deepEqual(
      responses.map((r) => r.id),
      [1, 2, 3, 4, 5, 6, 7, 8],
    )

    const initResult = responses[0]?.result as {
      protocolVersion: string
      serverInfo: { name: string; version: string }
    }
    assert.equal(initResult.protocolVersion, '2024-11-05')
    assert.equal(initResult.serverInfo.name, 'hollerkit-mcp')

    const listResult = responses[1]?.result as { tools: typeof HOLLERKIT_MCP_TOOLS }
    assert.equal(listResult.tools.length, 6)

    for (let i = 2; i <= 7; i++) {
      const callResult = responses[i]?.result as McpCallToolResult
      assert.equal(callResult.isError, false)
      assert.equal(callResult.content[0]?.type, 'text')
      const parsedText = JSON.parse(callResult.content[0]?.text ?? '{}') as { ok: boolean }
      assert.equal(parsedText.ok, true)
    }
  } finally {
    if (prevUrl === undefined) delete process.env.HOLLERKIT_URL
    else process.env.HOLLERKIT_URL = prevUrl
    if (prevKey === undefined) delete process.env.HOLLERKIT_API_KEY
    else process.env.HOLLERKIT_API_KEY = prevKey
  }
})

test('surfaces 401, 403, 404, timeout, validation, and protocol errors clearly', async () => {
  const harness = await createSeededTestHarness()

  // 1. 401 Unauthorized (invalid API key)
  const badAuthServer = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: 'hk_invalid_secret',
    fetch: harness.inProcessFetch,
  })
  const unauthorizedResult = await badAuthServer.callTool('feedback_inbox', {})
  assert.equal(unauthorizedResult.isError, true)
  assert.equal(unauthorizedResult.structuredContent.status, 401)
  assert.deepEqual(unauthorizedResult.structuredContent.error, {
    code: 'unauthorized',
    message: 'Invalid or expired authentication credentials.',
  })

  // 2. 403 Forbidden (read-only agent key attempting feedback_triage)
  const readOnlyServer = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentReadOnlyKey,
    fetch: harness.inProcessFetch,
  })
  const forbiddenResult = await readOnlyServer.callTool('feedback_triage', {
    id: harness.bugReportFeedbackId,
    status: 'triaged',
    summary: 'Should fail with 403 forbidden',
  })
  assert.equal(forbiddenResult.isError, true)
  assert.equal(forbiddenResult.structuredContent.status, 403)
  assert.equal(
    (forbiddenResult.structuredContent.error as { code: string }).code,
    'forbidden',
  )

  // 3. 404 Not Found (non-existent feedback UUID)
  const fullServer = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    fetch: harness.inProcessFetch,
  })
  const notFoundResult = await fullServer.callTool('feedback_get', {
    id: '99999999-9999-4999-8999-999999999999',
  })
  assert.equal(notFoundResult.isError, true)
  assert.equal(notFoundResult.structuredContent.status, 404)
  assert.equal(
    (notFoundResult.structuredContent.error as { code: string }).code,
    'not_found',
  )

  // 4. 400 Unsupported protocol version header
  const badProtocolServer = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    fetch: harness.inProcessFetch,
    protocolVersion: '2',
  })
  const protocolErrorResult = await badProtocolServer.callTool('quests_retirable', {})
  assert.equal(protocolErrorResult.isError, true)
  assert.equal(protocolErrorResult.structuredContent.status, 400)
  assert.equal(
    (protocolErrorResult.structuredContent.error as { code: string }).code,
    'unsupported_protocol',
  )

  // 5. Unknown MCP tool via JSON-RPC tools/call returns JSON-RPC protocol error (-32602)
  const unknownToolRpc = (await fullServer.handleJsonRpc({
    jsonrpc: '2.0',
    id: 99,
    method: 'tools/call',
    params: {
      name: 'nonexistent_tool',
      arguments: {},
    },
  })) as JsonRpcErrorResponse
  assert.ok(unknownToolRpc && !Array.isArray(unknownToolRpc) && 'error' in unknownToolRpc)
  assert.equal(unknownToolRpc.error.code, -32602)
  assert.match(unknownToolRpc.error.message, /Unknown MCP tool: nonexistent_tool/)

  // 6. Unknown tool argument property is rejected before dispatch
  const unknownPropResult = await fullServer.callTool('feedback_inbox', {
    triageStatus: 'all',
  })
  assert.equal(unknownPropResult.isError, true)
  assert.equal(unknownPropResult.structuredContent.status, 400)
  assert.equal(
    (unknownPropResult.structuredContent.error as { code: string }).code,
    'invalid_arguments',
  )

  // 7. Non-string area in quests_retirable is rejected
  const invalidAreaResult = await fullServer.callTool('quests_retirable', {
    area: 123 as unknown as string,
  })
  assert.equal(invalidAreaResult.isError, true)
  assert.equal(invalidAreaResult.structuredContent.status, 400)
  assert.equal(
    (invalidAreaResult.structuredContent.error as { code: string }).code,
    'invalid_arguments',
  )

  // 8. Explicit null arguments, scalar params, and invalid request IDs in JSON-RPC
  const nullArgsRpc = (await fullServer.handleJsonRpc({
    jsonrpc: '2.0',
    id: 100,
    method: 'tools/call',
    params: {
      name: 'feedback_inbox',
      arguments: null,
    },
  })) as JsonRpcErrorResponse
  assert.equal(nullArgsRpc.error.code, -32602)

  const scalarParamsRpc = (await fullServer.handleJsonRpc({
    jsonrpc: '2.0',
    id: 101,
    method: 'tools/list',
    params: false,
  })) as JsonRpcErrorResponse
  assert.equal(scalarParamsRpc.error.code, -32600)

  const invalidIdRpc = (await fullServer.handleJsonRpc({
    jsonrpc: '2.0',
    id: { bad: true },
    method: 'tools/call',
    params: {
      name: 'feedback_triage',
      arguments: {
        id: harness.bugReportFeedbackId,
        status: 'wontfix',
        summary: 'Must not execute',
      },
    },
  })) as JsonRpcErrorResponse
  assert.equal(invalidIdRpc.error.code, -32600)

  // 9. Request timeout during slow response body consumption
  const slowServer = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    timeoutMs: 25,
    fetch: async () =>
      new Response(
        new ReadableStream({
          start() {
            // Never closes stream
          },
        }),
        { status: 200, headers: { 'hollerkit-protocol': '1' } },
      ),
  })
  const timeoutResult = await slowServer.callTool('quests_retirable', {})
  assert.equal(timeoutResult.isError, true)
  assert.equal(timeoutResult.structuredContent.status, 504)
  assert.equal(
    (timeoutResult.structuredContent.error as { code: string }).code,
    'request_timeout',
  )
})

test('CLI --version and HOLLERKIT_MCP_VERSION match mcp/package.json version', async () => {
  const pkgPath = fileURLToPath(new URL('../package.json', import.meta.url))
  const cliPath = fileURLToPath(new URL('../dist/cli.js', import.meta.url))
  const pkg = JSON.parse(await readFile(pkgPath, 'utf8')) as { version: string }

  assert.equal(HOLLERKIT_MCP_VERSION, pkg.version)

  const { stdout, stderr } = await execFileAsync(process.execPath, [cliPath, '--version'])
  assert.equal(stderr, '')
  assert.equal(stdout.trim(), pkg.version)
})

test('validates UUID id, ISO since timestamp, non-empty links, and whitespace actor on client', async () => {
  const harness = await createSeededTestHarness()
  const initialRequestCount = harness.observedRequests.length

  const mcp = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    fetch: harness.inProcessFetch,
  })

  // 1. Invalid UUID in feedback_get
  const badGetId = await mcp.callTool('feedback_get', { id: 'not-a-uuid' })
  assert.equal(badGetId.isError, true)
  assert.equal(badGetId.structuredContent.status, 400)
  assert.equal((badGetId.structuredContent.error as { code: string }).code, 'invalid_arguments')

  // 2. Invalid UUID in feedback_triage
  const badTriageId = await mcp.callTool('feedback_triage', {
    id: '12345',
    status: 'triaged',
    summary: 'Bad UUID',
  })
  assert.equal(badTriageId.isError, true)
  assert.equal(badTriageId.structuredContent.status, 400)
  assert.equal((badTriageId.structuredContent.error as { code: string }).code, 'invalid_arguments')

  // 3. Invalid since timestamp in feedback_inbox
  const badSince = await mcp.callTool('feedback_inbox', { since: 'not-a-date' })
  assert.equal(badSince.isError, true)
  assert.equal(badSince.structuredContent.status, 400)
  assert.equal((badSince.structuredContent.error as { code: string }).code, 'invalid_arguments')

  // 4. Empty string in links array in feedback_triage
  const emptyLink = await mcp.callTool('feedback_triage', {
    id: harness.bugReportFeedbackId,
    status: 'triaged',
    summary: 'Has empty link',
    links: ['https://github.com/Liampronan/HollerKit/pull/1', '   '],
  })
  assert.equal(emptyLink.isError, true)
  assert.equal(emptyLink.structuredContent.status, 400)
  assert.equal((emptyLink.structuredContent.error as { code: string }).code, 'invalid_arguments')

  // None of the invalid calls should have sent an HTTP request
  assert.equal(harness.observedRequests.length, initialRequestCount)

  // 5. Whitespace-only actor is treated as undefined and succeeds
  const whitespaceActor = (await mcp.callTool('feedback_triage', {
    id: harness.bugReportFeedbackId,
    status: 'triaged',
    summary: 'Triaged with whitespace actor',
    actor: '   ',
  })) as McpCallToolResult<FeedbackTriageOutput>
  assert.equal(whitespaceActor.isError, false)
  assert.equal(whitespaceActor.structuredContent.ok, true)
})

test('rejects oversized HTTP response bodies with 502 response_too_large', async () => {
  const harness = await createSeededTestHarness()

  const mcp = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    maxResponseBytes: 64,
    fetch: async () =>
      new Response(JSON.stringify({ ok: true, quests: [{ id: 'a'.repeat(200) }] }), {
        status: 200,
        headers: {
          'content-type': 'application/json',
          'hollerkit-protocol': '1',
        },
      }),
  })

  const res = await mcp.callTool('quests_retirable', {})
  assert.equal(res.isError, true)
  assert.equal(res.structuredContent.status, 502)
  assert.equal((res.structuredContent.error as { code: string }).code, 'response_too_large')
})

test('suppresses response for in-flight cancelled requests and ignores late/unknown cancellations without leaking', async () => {
  const harness = await createSeededTestHarness()

  let resolveSlowFetch!: () => void
  const slowFetchGate = new Promise<void>((resolve) => {
    resolveSlowFetch = resolve
  })

  const mcp = createHollerKitMcpServer({
    baseUrl: BASE_URL,
    apiKey: harness.agentFullKey,
    fetch: async (input, init) => {
      await slowFetchGate
      return harness.inProcessFetch(input, init)
    },
  })

  const input = new PassThrough()
  const output = new PassThrough()
  const outputLines: string[] = []
  let buffer = ''
  output.on('data', (chunk: Buffer) => {
    buffer += chunk.toString('utf8')
    let idx = buffer.indexOf('\n')
    while (idx >= 0) {
      const line = buffer.slice(0, idx).trim()
      buffer = buffer.slice(idx + 1)
      if (line.length > 0) outputLines.push(line)
      idx = buffer.indexOf('\n')
    }
  })

  const conn = mcp.connectStdio(input, output)

  // Send a late/unknown cancellation for requestId 777 that is neither active nor queued
  input.write(
    `${JSON.stringify({
      jsonrpc: '2.0',
      method: 'notifications/cancelled',
      params: { requestId: 777 },
    })}\n`,
  )

  // Send an in-flight tools/call with id=10
  input.write(
    `${JSON.stringify({
      jsonrpc: '2.0',
      id: 10,
      method: 'tools/call',
      params: { name: 'quests_retirable', arguments: {} },
    })}\n`,
  )

  // Give drainQueue a tick to start executing id=10
  await new Promise((resolve) => setTimeout(resolve, 15))

  // Cancel id=10 while in-flight
  input.write(
    `${JSON.stringify({
      jsonrpc: '2.0',
      method: 'notifications/cancelled',
      params: { requestId: 10 },
    })}\n`,
  )

  // Also send a subsequent request with id=777 (which must NOT be suppressed by the earlier unknown cancellation)
  input.write(
    `${JSON.stringify({
      jsonrpc: '2.0',
      id: 777,
      method: 'ping',
    })}\n`,
  )

  // Unblock slow fetch
  resolveSlowFetch()

  const deadline = Date.now() + 2000
  while (outputLines.length < 1 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  conn.close()

  // Only id=777 should have produced a response; id=10 was cancelled while in-flight
  assert.equal(outputLines.length, 1)
  const parsed = JSON.parse(outputLines[0]!) as JsonRpcSuccessResponse
  assert.equal(parsed.id, 777)
})
