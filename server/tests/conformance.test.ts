import assert from 'node:assert/strict'
import test from 'node:test'
import {
  apiKeysAuthenticator,
  computeQuestContentHash,
  createHollerKitServer,
  fakeStorage,
  hashApiKey,
  memoryStore,
  runConformanceSuite,
  staticTokens,
} from '../dist/index.js'

test('runs full v1 conformance suite in-process against memoryStore', async () => {
  const store = memoryStore()
  const storage = fakeStorage()

  const testerToken = 'jwt-tester-alice'
  const otherTesterToken = 'jwt-tester-bob'
  const questsWriteKey = 'hk_ci_quests_write_secret'
  const agentKey = 'hk_agent_read_triage_secret'

  await store.createApiKey({
    keyHash: hashApiKey(questsWriteKey),
    keyPrefix: 'hk_ci_quests',
    label: 'github-actions',
    scopes: ['quests:write'],
  })

  await store.createApiKey({
    keyHash: hashApiKey(agentKey),
    keyPrefix: 'hk_agent_rea',
    label: 'codex-mcp',
    scopes: ['agent:read', 'agent:triage'],
  })

  const handler = createHollerKitServer({
    store,
    storage,
    authenticate: [
      staticTokens({
        [testerToken]: {
          principalId: 'tester-alice',
          scopes: ['tester'],
          kind: 'tester',
          label: 'Alice',
        },
        [otherTesterToken]: {
          principalId: 'tester-bob',
          scopes: ['tester'],
          kind: 'tester',
          label: 'Bob',
        },
      }),
      apiKeysAuthenticator({ store }),
    ],
  })

  const result = await runConformanceSuite({
    baseUrl: 'https://example.supabase.co/functions/v1/hollerkit',
    fetch: async (input, init) => handler(new Request(input, init)),
    testerToken,
    otherTesterToken,
    questsWriteKey,
    agentKey,
  })

  assert.equal(result.ok, true)
  assert.ok(result.steps.length >= 9)
})

test('computeQuestContentHash is canonical and ignores id and source metadata', () => {
  const hashA = computeQuestContentHash({
    title: '  Open feed card  ',
    area: ' feed ',
    setup: [' Enable feed '],
    steps: [' Tap card ', ' Go back '],
    expect: [' Position preserved '],
    needs: ['device'],
    record: 'suggested',
    start: ' app://feed ',
  })

  const hashB = computeQuestContentHash({
    title: 'Open feed card',
    area: 'feed',
    setup: ['Enable feed'],
    steps: ['Tap card', 'Go back'],
    expect: ['Position preserved'],
    needs: ['device'],
    record: 'suggested',
    start: 'app://feed',
  })

  assert.equal(hashA, hashB)

  const hashChanged = computeQuestContentHash({
    title: 'Open feed card',
    area: 'feed',
    setup: ['Enable feed'],
    steps: ['Tap card', 'Drag slider', 'Go back'],
    expect: ['Position preserved'],
    needs: ['device'],
    record: 'suggested',
    start: 'app://feed',
  })

  assert.notEqual(hashA, hashChanged)
})
