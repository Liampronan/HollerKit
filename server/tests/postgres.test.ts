import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { existsSync, readdirSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import postgres from 'postgres'
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
import { parsePostgresTextArrayLiteral } from '../dist/v1/postgresStore.js'

const execFileAsync = promisify(execFile)

interface DisposablePostgresHarness {
  url: string
  cleanup: () => Promise<void>
}

function findPostgresBinDir(): string | null {
  const candidates: string[] = []
  const pathDirs = (process.env.PATH ?? '').split(':').filter(Boolean)
  candidates.push(...pathDirs)
  candidates.push('/opt/homebrew/bin', '/usr/local/bin')

  try {
    const usrLibPg = '/usr/lib/postgresql'
    if (existsSync(usrLibPg)) {
      for (const ver of readdirSync(usrLibPg).sort().reverse()) {
        candidates.push(join(usrLibPg, ver, 'bin'))
      }
    }
  } catch {
    // Ignore directory read errors
  }

  for (const dir of candidates) {
    if (existsSync(join(dir, 'initdb')) && existsSync(join(dir, 'pg_ctl'))) {
      return dir
    }
  }
  return null
}

async function getFreePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const srv = createServer()
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address()
      const port = typeof addr === 'object' && addr ? addr.port : 0
      srv.close((err) => (err ? reject(err) : resolvePort(port)))
    })
    srv.on('error', reject)
  })
}

async function provisionDisposableDatabase(): Promise<DisposablePostgresHarness | null> {
  const configuredUrl = process.env.HOLLERKIT_TEST_DATABASE_URL?.trim()
  if (configuredUrl) {
    const parsed = new URL(configuredUrl)
    const dbName = parsed.pathname.replace(/^\/+/, '')
    if (!dbName || (!dbName.includes('test') && !dbName.includes('disposable'))) {
      throw new Error(
        `Refusing to run destructive test setup against non-test database "${dbName}". ` +
          'HOLLERKIT_TEST_DATABASE_URL must target a database whose name contains "test" or "disposable".',
      )
    }

    const tempDbName = `hollerkit_test_${randomUUID().replace(/-/g, '').slice(0, 12)}`
    const adminSql = postgres(configuredUrl, { max: 1, onnotice: () => {} })
    try {
      await adminSql.unsafe(`CREATE DATABASE "${tempDbName}"`)
      const disposableUrl = new URL(configuredUrl)
      disposableUrl.pathname = `/${tempDbName}`
      return {
        url: disposableUrl.toString(),
        cleanup: async () => {
          try {
            await adminSql.unsafe(`DROP DATABASE IF EXISTS "${tempDbName}" WITH (FORCE)`)
          } finally {
            await adminSql.end({ timeout: 5 })
          }
        },
      }
    } catch {
      // If the user lacks CREATEDB privileges on the test instance, verify the target DB itself
      // is empty or already carries the disposable test marker table before touching `hollerkit`.
      const schemaExists = await adminSql<{ exists: boolean }[]>`
        SELECT EXISTS (
          SELECT 1 FROM information_schema.schemata WHERE schema_name = 'hollerkit'
        ) AS exists
      `
      if (schemaExists[0]?.exists) {
        const markerExists = await adminSql<{ exists: boolean }[]>`
          SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'hollerkit' AND table_name = '_test_disposable_marker'
          ) AS exists
        `
        if (!markerExists[0]?.exists) {
          await adminSql.end({ timeout: 5 })
          throw new Error(
            `Refusing to drop existing "hollerkit" schema in "${dbName}" because it lacks hollerkit._test_disposable_marker.`,
          )
        }
      }
      await adminSql.end({ timeout: 5 })
      return {
        url: configuredUrl,
        cleanup: async () => {},
      }
    }
  }

  // When HOLLERKIT_TEST_DATABASE_URL is not set, spin up an isolated temporary pg_ctl cluster if available
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    return null
  }
  const pgBinDir = findPostgresBinDir()
  if (!pgBinDir) {
    return null
  }

  const tempRoot = await mkdtemp(join(tmpdir(), 'hollerkit-pg-test-'))
  const dataDir = join(tempRoot, 'data')
  const logFile = join(tempRoot, 'postgres.log')
  const port = await getFreePort()
  const initdbBin = join(pgBinDir, 'initdb')
  const pgCtlBin = join(pgBinDir, 'pg_ctl')

  try {
    await execFileAsync(initdbBin, ['-D', dataDir, '-U', 'postgres', '-A', 'trust', '--no-instructions'])
    await execFileAsync(pgCtlBin, [
      '-D',
      dataDir,
      '-l',
      logFile,
      '-o',
      `-F -p ${port} -h 127.0.0.1 -k "${tempRoot}"`,
      '-w',
      'start',
    ])

    const adminUrl = `postgres://postgres@127.0.0.1:${port}/postgres`
    const tempDbName = 'hollerkit_test_disposable'
    const adminSql = postgres(adminUrl, { max: 1, onnotice: () => {} })
    await adminSql.unsafe(`CREATE DATABASE "${tempDbName}"`)
    await adminSql.end({ timeout: 5 })

    return {
      url: `postgres://postgres@127.0.0.1:${port}/${tempDbName}`,
      cleanup: async () => {
        try {
          await execFileAsync(pgCtlBin, ['-D', dataDir, '-m', 'immediate', '-w', 'stop'])
        } catch {
          // Ignore stop errors during cleanup
        }
        await rm(tempRoot, { recursive: true, force: true })
      },
    }
  } catch {
    await rm(tempRoot, { recursive: true, force: true })
    return null
  }
}

test('runs full v1 conformance suite and Postgres-specific invariants against postgresStore', async (t) => {
  const harness = await provisionDisposableDatabase()
  if (!harness) {
    t.skip('Neither HOLLERKIT_TEST_DATABASE_URL nor local initdb/pg_ctl is available')
    return
  }

  const store = postgresStore({ url: harness.url, max: 2, prepare: false, fetchTypes: false })
  const secondStore = postgresStore({ url: harness.url })
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
    await store.sql.unsafe(
      'CREATE TABLE IF NOT EXISTS hollerkit._test_disposable_marker (created_at timestamptz DEFAULT now());',
    )

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

    // Verify API key scopes round-trip with both fetchTypes: false (store) and default fetchTypes (secondStore),
    // as well as direct Postgres array literal parsing
    const keyFromFetchTypesFalse = await store.getApiKeyByHash(hashApiKey(agentKey))
    assert.deepEqual(keyFromFetchTypesFalse?.scopes, ['agent:read', 'agent:triage'])
    const keyFromDefaultStore = await secondStore.getApiKeyByHash(hashApiKey(agentKey))
    assert.deepEqual(keyFromDefaultStore?.scopes, ['agent:read', 'agent:triage'])
    assert.deepEqual(parsePostgresTextArrayLiteral('{agent:read,agent:triage}'), ['agent:read', 'agent:triage'])
    assert.deepEqual(parsePostgresTextArrayLiteral('{"quests:write","agent:read"}'), ['quests:write', 'agent:read'])
    assert.deepEqual(parsePostgresTextArrayLiteral('{}'), [])
    assert.equal(parsePostgresTextArrayLiteral('not-an-array'), null)

    // Verify empty build manifest registration persists in PostgreSQL across separate store instances
    await store.syncBuildManifest({
      build: 'empty-build-999',
      appVersion: '2.0.0',
      quests: [],
    })
    const pendingFromSecondInstance = await secondStore.getPendingQuestsForBuild('empty-build-999')
    assert.deepEqual(pendingFromSecondInstance, [])

    // Verify concurrent createFeedback calls with the same ID serialize cleanly and return idempotent=true on retry
    const concurrentFeedbackId = randomUUID()
    const [resA, resB] = await Promise.all([
      store.createFeedback({
        id: concurrentFeedbackId,
        kind: 'report',
        build: 'build-100',
        submitterId: 'tester-alice',
        comment: 'Concurrent submission test',
        metadata: { area: 12345 as unknown as string },
      }),
      secondStore.createFeedback({
        id: concurrentFeedbackId,
        kind: 'report',
        build: 'build-100',
        submitterId: 'tester-alice',
        comment: 'Concurrent submission test',
        metadata: { area: 12345 as unknown as string },
      }),
    ])
    assert.equal(resA.feedback.id, concurrentFeedbackId)
    assert.equal(resB.feedback.id, concurrentFeedbackId)
    assert.notEqual(resA.idempotent, resB.idempotent, 'Exactly one concurrent call creates and the other is idempotent')
    assert.equal(resA.feedback.area, null, 'Non-string metadata.area must resolve to null')
    assert.equal(resB.feedback.area, null, 'Non-string metadata.area must resolve to null')
  } finally {
    await secondStore.close()
    await store.close()
    await harness.cleanup()
  }
})
