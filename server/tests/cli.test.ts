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
