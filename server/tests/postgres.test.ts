import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  apiKeys,
  createHollerKitServer,
  fakeStorage,
  generateApiKey,
  getApiKeyPrefix,
  hashApiKey,
  postgresStore,
  runConformanceSuite,
  staticTokens,
} from '../dist/index.js'

const databaseUrl = process.env.HOLLERKIT_TEST_DATABASE_URL

test(
  'runs full v1 conformance suite against postgresStore when HOLLERKIT_TEST_DATABASE_URL is set',
  { skip: !databaseUrl ? 'HOLLERKIT_TEST_DATABASE_URL is not set' : false },
  async () => {
    const store = postgresStore({ url: databaseUrl! })
    try {
      const migrationPath = resolve(
        dirname(fileURLToPath(import.meta.url)),
        '..',
        'migrations',
        '001_hollerkit_v1.sql',
      )
      const migrationSql = await readFile(migrationPath, 'utf8')
      await store.sql.unsafe('DROP SCHEMA IF EXISTS hollerkit CASCADE;')
      await store.sql.unsafe(migrationSql)

      const testerToken = 'jwt-tester-alice'
      const otherTesterToken = 'jwt-tester-bob'
      const questsWriteKey = generateApiKey('ci')
      const agentKey = generateApiKey('agent')

      await store.upsertTester({
        userId: 'tester-alice',
        email: 'alice@example.com',
        label: 'Alice',
        active: true,
      })
      assert.equal(await store.isTester('tester-alice'), true)

      await store.createApiKey({
        keyHash: hashApiKey(questsWriteKey),
        keyPrefix: getApiKeyPrefix(questsWriteKey),
        label: 'github-actions',
        scopes: ['quests:write'],
      })

      await store.createApiKey({
        keyHash: hashApiKey(agentKey),
        keyPrefix: getApiKeyPrefix(agentKey),
        label: 'codex-mcp',
        scopes: ['agent:read', 'agent:triage'],
      })

      const handler = createHollerKitServer({
        store,
        storage: fakeStorage(),
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
          apiKeys({ store }),
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
    } finally {
      await store.close()
    }
  },
)
