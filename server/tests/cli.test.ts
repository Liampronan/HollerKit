import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, mkdtemp, readdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import {
  apiKeys,
  createHollerKitServer,
  fakeStorage,
  generateApiKey,
  getApiKeyPrefix,
  hashApiKey,
  memoryStore,
  runCli,
  staticTokens,
} from '../dist/index.js'

const execFileAsync = promisify(execFile)

async function startTestHttpServer(handler: (req: Request) => Promise<Response>): Promise<{
  server: Server
  baseUrl: string
  close: () => Promise<void>
}> {
  const server = createServer(async (incoming, outgoing) => {
    const chunks: Buffer[] = []
    for await (const chunk of incoming) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
    }
    const bodyBuffer = Buffer.concat(chunks)

    const headers = new Headers()
    for (const [k, v] of Object.entries(incoming.headers)) {
      if (Array.isArray(v)) {
        headers.set(k, v.join(', '))
      } else if (typeof v === 'string') {
        headers.set(k, v)
      }
    }

    const method = incoming.method ?? 'GET'
    const url = `http://${incoming.headers.host ?? '127.0.0.1'}${incoming.url ?? '/'}`
    const reqInit: RequestInit = {
      method,
      headers,
    }
    if (method !== 'GET' && method !== 'HEAD' && bodyBuffer.byteLength > 0) {
      reqInit.body = bodyBuffer
    }

    const response = await handler(new Request(url, reqInit))
    const respHeaders: Record<string, string> = {}
    response.headers.forEach((val, key) => {
      respHeaders[key] = val
    })
    outgoing.writeHead(response.status, respHeaders)
    outgoing.end(Buffer.from(await response.arrayBuffer()))
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const addr = server.address()
  assert.ok(addr && typeof addr === 'object')
  const baseUrl = `http://127.0.0.1:${addr.port}`

  return {
    server,
    baseUrl,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()))
      }),
  }
}

test('CLI: quests validate succeeds on valid manifest and fails on invalid manifest', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'hollerkit-cli-validate-'))
  try {
    const validPath = join(tempDir, 'hollerkit-quests.json')
    await writeFile(
      validPath,
      JSON.stringify(
        {
          version: 1,
          quests: [
            {
              id: 'feed-zoom',
              title: 'Zoom into feed card',
              area: 'feed',
              steps: ['Tap card', 'Go back'],
              expect: ['Scroll position preserved'],
              record: 'suggested',
            },
          ],
        },
        null,
        2,
      ),
    )

    const out: string[] = []
    const err: string[] = []
    const code = await runCli(['quests', 'validate', validPath], {
      stdout: (l) => out.push(l),
      stderr: (l) => err.push(l),
    })

    assert.equal(code, 0)
    assert.equal(err.length, 0)
    assert.ok(out.some((line) => line.startsWith('feed-zoom\t') && line.length > 20))

    // Also validate the sample manifest in examples/ios-demo/hollerkit-quests.json
    const demoManifestPath = fileURLToPath(
      new URL('../../examples/ios-demo/hollerkit-quests.json', import.meta.url),
    )
    const demoOut: string[] = []
    const demoErr: string[] = []
    const demoCode = await runCli(
      ['quests', 'validate', demoManifestPath],
      {
        stdout: (l) => demoOut.push(l),
        stderr: (l) => demoErr.push(l),
      },
    )
    assert.equal(demoCode, 0)
    assert.equal(demoErr.length, 0)
    assert.ok(demoOut.some((line) => line.startsWith('checkout-promo-math\t')))
    assert.ok(demoOut.some((line) => line.startsWith('profile-avatar-upload\t')))

    // Valid manifest with quest captures
    const capturePath = join(tempDir, 'capture-quests.json')
    await writeFile(
      capturePath,
      JSON.stringify(
        {
          version: 1,
          quests: [
            {
              id: 'share-time-to-send',
              title: 'Measure first video share',
              area: 'share',
              steps: ['Tap share'],
              expect: ['Share sheet ready'],
              capture: [
                {
                  event: 'share.render',
                  value: 'durationMs',
                  unit: 'ms',
                  label: 'First render',
                  where: { cached: false },
                  min: 10,
                  max: 5000,
                },
              ],
            },
          ],
        },
        null,
        2,
      ),
    )
    const captureOut: string[] = []
    const captureCode = await runCli(['quests', 'validate', capturePath], {
      stdout: (l) => captureOut.push(l),
      stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
    })
    assert.equal(captureCode, 0)
    assert.ok(captureOut.some((l) => l.startsWith('share-time-to-send\t')))

    // Invalid manifest (capture min > max)
    const badRangePath = join(tempDir, 'bad-range-quests.json')
    await writeFile(
      badRangePath,
      JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'bad-range-quest',
            title: 'Bad Range',
            area: 'share',
            steps: ['Step 1'],
            expect: ['Expect 1'],
            capture: [
              {
                event: 'render',
                value: 'durationMs',
                unit: 'ms',
                label: 'Bad',
                min: 500,
                max: 100,
              },
            ],
          },
        ],
      }),
    )
    const errBadRange: string[] = []
    const badRangeCode = await runCli(['quests', 'validate', badRangePath], {
      stdout: () => {},
      stderr: (l) => errBadRange.push(l),
    })
    assert.equal(badRangeCode, 1)
    assert.ok(errBadRange.some((l) => l.includes('cannot exceed max')))

    // Invalid manifest (missing expect array)
    const invalidPath = join(tempDir, 'invalid-quests.json')
    await writeFile(
      invalidPath,
      JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'broken-quest',
            title: 'Broken',
            area: 'feed',
            steps: ['Step 1'],
            expect: [],
          },
        ],
      }),
    )

    const errInvalid: string[] = []
    const badCode = await runCli(['quests', 'validate', invalidPath], {
      stdout: () => {},
      stderr: (l) => errInvalid.push(l),
    })
    assert.equal(badCode, 1)
    assert.ok(errInvalid.length > 0)
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
})

test('CLI: quests sync, conformance --server, keys create/revoke, and migrations copy', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'hollerkit-cli-suite-'))
  const store = memoryStore()
  const testerToken = 'jwt-tester-cli'
  const questsWriteKey = generateApiKey('ci')
  const agentKey = generateApiKey('agent')

  await store.createApiKey({
    keyHash: hashApiKey(questsWriteKey),
    keyPrefix: getApiKeyPrefix(questsWriteKey),
    label: 'ci-sync',
    scopes: ['quests:write'],
  })
  await store.createApiKey({
    keyHash: hashApiKey(agentKey),
    keyPrefix: getApiKeyPrefix(agentKey),
    label: 'agent-triage',
    scopes: ['agent:read', 'agent:triage'],
  })

  const handler = createHollerKitServer({
    store,
    storage: fakeStorage(),
    authenticate: [
      staticTokens({
        [testerToken]: {
          principalId: 'tester-cli',
          scopes: ['tester'],
          kind: 'tester',
        },
      }),
      apiKeys({ store }),
    ],
  })

  const httpServer = await startTestHttpServer(handler)

  try {
    // 1. hollerkit conformance --server (against clean server)
    const confOut: string[] = []
    const confCode = await runCli(
      [
        'conformance',
        '--server',
        httpServer.baseUrl,
        '--tester-token',
        testerToken,
        '--quests-key',
        questsWriteKey,
        '--agent-key',
        agentKey,
      ],
      {
        stdout: (l) => confOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
      },
    )
    assert.equal(confCode, 0)
    assert.ok(confOut.some((l) => l.includes('Conformance suite passed')))

    // 2. hollerkit quests sync
    const manifestPath = join(tempDir, 'quests.json')
    await writeFile(
      manifestPath,
      JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'onboarding-welcome',
            title: 'Complete welcome screen',
            area: 'onboarding',
            steps: ['Launch app', 'Tap Continue'],
            expect: ['Home screen appears'],
          },
          {
            id: 'settings-theme',
            title: 'Switch dark mode',
            area: 'settings',
            steps: ['Open Settings', 'Toggle Dark Mode'],
            expect: ['Background turns dark'],
          },
        ],
      }),
    )

    const syncOut: string[] = []
    const syncCode = await runCli(
      [
        'quests',
        'sync',
        manifestPath,
        '--server',
        httpServer.baseUrl,
        '--key',
        questsWriteKey,
        '--sha',
        '1234abcd',
        '--pr',
        '42',
      ],
      {
        stdout: (l) => syncOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
      },
    )
    assert.equal(syncCode, 0)
    assert.ok(syncOut.some((l) => l.includes('Synced 2 quest(s)')))

    // Sync again with 1 quest removed -> retired=1
    await writeFile(
      manifestPath,
      JSON.stringify({
        version: 1,
        quests: [
          {
            id: 'onboarding-welcome',
            title: 'Complete welcome screen',
            area: 'onboarding',
            steps: ['Launch app', 'Tap Continue'],
            expect: ['Home screen appears'],
          },
        ],
      }),
    )

    const syncOut2: string[] = []
    const syncCode2 = await runCli(
      ['quests', 'sync', manifestPath, '--server', httpServer.baseUrl, '--key', questsWriteKey],
      {
        stdout: (l) => syncOut2.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
      },
    )
    assert.equal(syncCode2, 0)
    assert.ok(syncOut2.some((l) => l.includes('retired=1')))

    // 3. hollerkit keys create & revoke
    const keyOut: string[] = []
    const createKeyCode = await runCli(
      [
        'keys',
        'create',
        '--db',
        'postgres://mock/db',
        '--scopes',
        'agent:read,agent:triage',
        '--label',
        'cursor-agent',
      ],
      {
        stdout: (l) => keyOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        storeFactory: () => store,
      },
    )
    assert.equal(createKeyCode, 0)
    const mintedKey = keyOut[0]!
    assert.ok(mintedKey.startsWith('hk_'))
    assert.ok(await store.findApiKeyByHash(hashApiKey(mintedKey)))

    const revokeOut: string[] = []
    const revokeCode = await runCli(
      ['keys', 'revoke', '--db', 'postgres://mock/db', 'cursor-agent'],
      {
        stdout: (l) => revokeOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        storeFactory: () => store,
      },
    )
    assert.equal(revokeCode, 0)
    assert.equal(await store.findApiKeyByHash(hashApiKey(mintedKey)), null)

    // 4. hollerkit migrations copy
    const migrationsTarget = join(tempDir, 'supabase', 'migrations')
    const migOut: string[] = []
    const migCode = await runCli(['migrations', 'copy', migrationsTarget], {
      stdout: (l) => migOut.push(l),
      stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
    })
    assert.equal(migCode, 0)
    const copiedFiles = await readdir(migrationsTarget)
    assert.ok(copiedFiles.includes('001_hollerkit_v1.sql'))
    const copiedSql = await readFile(join(migrationsTarget, '001_hollerkit_v1.sql'), 'utf8')
    assert.ok(copiedSql.includes('CREATE SCHEMA IF NOT EXISTS hollerkit;'))

    // Re-running migrations copy on an existing destination refuses to overwrite and reports collision
    const migErr: string[] = []
    const migDuplicateCode = await runCli(['migrations', 'copy', migrationsTarget], {
      stdout: () => {},
      stderr: (l) => migErr.push(l),
    })
    assert.equal(migDuplicateCode, 1)
    assert.ok(migErr.some((l) => l.includes('already exists at destination')))

    // 5. hollerkit outbox flush (including S3 storage flags and non-JSON error handling on quests sync)
    const nonJsonErr: string[] = []
    const nonJsonSyncCode = await runCli(
      ['quests', 'sync', manifestPath, '--server', 'http://bad-gateway.local', '--key', questsWriteKey],
      {
        stdout: () => {},
        stderr: (l) => nonJsonErr.push(l),
        fetchImpl: async () => new Response('<html>502 Bad Gateway</html>', { status: 502 }),
      },
    )
    assert.equal(nonJsonSyncCode, 1)
    assert.ok(nonJsonErr.some((l) => l.includes('HTTP 502') && l.includes('502 Bad Gateway')))

    const outboxFeedback = await store.createFeedback({
      id: '11111111-2222-4333-8444-555555555555',
      kind: 'report',
      build: '500',
      submitterId: 'tester-cli',
      comment: 'CLI outbox flush report',
      sinks: ['github'],
    })
    assert.equal(outboxFeedback.feedback.links.length, 0)

    const flushOut: string[] = []
    const flushCode = await runCli(
      [
        'outbox',
        'flush',
        '--db',
        'postgres://mock/db',
        '--github-repo',
        'Liampronan/HollerKit',
        '--github-token',
        'ghp_cli_token',
        '--s3-endpoint',
        'https://s3.us-east-1.amazonaws.com',
        '--s3-bucket',
        'hollerkit-bucket',
        '--s3-region',
        'us-east-1',
        '--s3-access-key-id',
        'AKIAIOSFODNN7EXAMPLE',
        '--s3-secret-access-key',
        'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        '--limit',
        '10',
      ],
      {
        stdout: (l) => flushOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        storeFactory: () => store,
        fetchImpl: async () =>
          Response.json(
            {
              number: 88,
              html_url: 'https://github.com/Liampronan/HollerKit/issues/88',
            },
            { status: 201 },
          ),
      },
    )
    assert.equal(flushCode, 0)
    assert.ok(flushOut.some((l) => l.includes('claimed=1, delivered=1, failed=0')))
    const updatedDetail = await store.getFeedbackById(outboxFeedback.feedback.id)
    assert.deepEqual(updatedDetail?.feedback.links, [
      'https://github.com/Liampronan/HollerKit/issues/88',
    ])

    // 6. hollerkit values
    await store.syncQuests({
      version: 1,
      quests: [
        {
          id: 'cli-quest-values',
          title: 'CLI Values Quest',
          area: 'cli',
          steps: ['Run command'],
          expect: ['Output matches'],
          capture: [
            {
              event: 'cli.exec',
              value: 'durationMs',
              unit: 'ms',
              label: 'Execution time',
            },
          ],
        },
      ],
    })
    await store.createFeedback({
      id: '22222222-3333-4444-8555-666666666666',
      kind: 'quest_run',
      questId: 'cli-quest-values',
      questVersion: 1,
      result: 'pass',
      build: 'cli-build-1',
      submitterId: 'tester-cli',
      events: [
        {
          kind: 'breadcrumb',
          offsetSeconds: 0.5,
          payload: { message: 'cli.exec', durationMs: 120 },
        },
      ],
    })

    const valuesJsonOut: string[] = []
    const valuesJsonCode = await runCli(
      [
        'values',
        '--server',
        httpServer.baseUrl,
        '--key',
        agentKey,
        '--quest',
        'cli-quest-values',
        '--label',
        'Execution time',
        '--groupBy',
        'build',
        '--json',
      ],
      {
        stdout: (l) => valuesJsonOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        fetchImpl: fetch,
      },
    )
    assert.equal(valuesJsonCode, 0)
    const valuesParsed = JSON.parse(valuesJsonOut.join('\n'))
    assert.equal(valuesParsed.ok, true)
    assert.equal(valuesParsed.n, 1)
    assert.equal(valuesParsed.median, 120)
    assert.equal(valuesParsed.unit, 'ms')

    const valuesTextOut: string[] = []
    const valuesTextCode = await runCli(
      [
        'values',
        '--server',
        httpServer.baseUrl,
        '--key',
        agentKey,
        '--quest',
        'cli-quest-values',
      ],
      {
        stdout: (l) => valuesTextOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        fetchImpl: fetch,
      },
    )
    assert.equal(valuesTextCode, 0)
    assert.ok(valuesTextOut.some((l) => l.includes('Quest: cli-quest-values')))
    assert.ok(valuesTextOut.some((l) => l.includes('n: 1')))

    const valuesDbOut: string[] = []
    const valuesDbCode = await runCli(
      ['values', '--db', 'postgres://mock/db', '--quest', 'cli-quest-values'],
      {
        stdout: (l) => valuesDbOut.push(l),
        stderr: (l) => assert.fail(`Unexpected stderr: ${l}`),
        storeFactory: () => store,
      },
    )
    assert.equal(valuesDbCode, 0)
    assert.ok(valuesDbOut.some((l) => l.includes('Quest: cli-quest-values')))
  } finally {
    await httpServer.close()
    await rm(tempDir, { recursive: true, force: true })
  }
})

test('CLI: symlinked hollerkit bin executable invokes runCli and prints usage', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'hollerkit-cli-symlink-'))
  try {
    const cliDistPath = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'cli.js')
    await chmod(cliDistPath, 0o755)
    const symlinkBinPath = join(tempDir, 'hollerkit')
    await symlink(cliDistPath, symlinkBinPath)

    const { stdout, stderr } = await execFileAsync(process.execPath, [symlinkBinPath, '--help'])
    assert.equal(stderr, '')
    assert.ok(stdout.includes('HollerKit v1 CLI'))
    assert.ok(stdout.includes('hollerkit quests validate <file>'))
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
})
