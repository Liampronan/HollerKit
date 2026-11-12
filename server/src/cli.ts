#!/usr/bin/env node
import { realpathSync } from 'node:fs'
import { constants, copyFile, mkdir, readdir, readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { githubIssuesSink } from './adapters/sinks/github.js'
import { supabaseStorage } from './adapters/storage/supabase.js'
import { generateApiKey, getApiKeyPrefix, hashApiKey } from './v1/auth.js'
import { runConformanceSuite } from './v1/conformance.js'
import { postgresStore } from './v1/postgresStore.js'
import { parseQuestManifest } from './v1/server.js'
import { flushOutbox } from './v1/sinks.js'
import {
  computeQuestContentHash,
  type HollerKitStore,
  type QuestVersionRecord,
  type Scope,
  type ValueGroupBy,
  type ValueSource,
} from './v1/store.js'

const VALID_SCOPES = new Set<Scope>(['tester', 'quests:write', 'agent:read', 'agent:triage'])

export interface CliIo {
  stdout?: ((line: string) => void) | undefined
  stderr?: ((line: string) => void) | undefined
  fetchImpl?: typeof globalThis.fetch | undefined
  cwd?: string | undefined
  storeFactory?: ((dbUrl: string) => HollerKitStore) | undefined
}

/**
 * Executes a `hollerkit` CLI command and returns a POSIX exit code (`0` on success, `1` on error).
 */
export async function runCli(argv: string[], io: CliIo = {}): Promise<number> {
  const stdout = io.stdout ?? ((line: string) => console.log(line))
  const stderr = io.stderr ?? ((line: string) => console.error(line))
  const fetchFn = io.fetchImpl ?? globalThis.fetch
  const cwd = io.cwd ?? process.cwd()
  const createStore = io.storeFactory ?? ((url: string) => postgresStore({ url }))

  try {
    const [group, subcommand, ...rest] = argv

    if (!group || group === '--help' || group === '-h' || group === 'help') {
      printUsage(stdout)
      return 0
    }

    if (group === 'quests') {
      if (subcommand === 'validate') {
        const fileArg = rest[0]
        if (!fileArg) {
          stderr('Error: Missing manifest file path. Usage: hollerkit quests validate <file>')
          return 1
        }
        const filePath = resolve(cwd, fileArg)
        const rawText = await readFile(filePath, 'utf8')
        const parsedJson = JSON.parse(rawText)
        const manifest = parseQuestManifest(parsedJson)

        for (const quest of manifest.quests) {
          const hash = computeQuestContentHash(quest)
          stdout(`${quest.id}\t${hash}`)
        }
        stdout(`Validated ${manifest.quests.length} quest(s) in ${fileArg}.`)
        return 0
      }

      if (subcommand === 'sync') {
        const { positional, flags } = parseFlags(rest)
        const fileArg = positional[0]
        const serverUrl = flags.get('server')
        const apiKey = flags.get('key')
        const sha = flags.get('sha')
        const prRaw = flags.get('pr')

        if (!fileArg || !serverUrl || !apiKey) {
          stderr(
            'Error: Usage: hollerkit quests sync <file> --server <url> --key <key> [--sha <sha>] [--pr <pr>]',
          )
          return 1
        }

        let pr: number | undefined
        if (prRaw !== undefined) {
          const parsedPr = Number(prRaw)
          if (!Number.isInteger(parsedPr) || parsedPr <= 0) {
            stderr('Error: --pr must be a positive integer.')
            return 1
          }
          pr = parsedPr
        }

        const filePath = resolve(cwd, fileArg)
        const rawText = await readFile(filePath, 'utf8')
        const parsedJson = JSON.parse(rawText)
        const manifest = parseQuestManifest(parsedJson)

        const targetUrl = `${serverUrl.replace(/\/+$/, '')}/v1/quests`
        const response = await fetchFn(targetUrl, {
          method: 'PUT',
          headers: {
            authorization: `Bearer ${apiKey}`,
            'content-type': 'application/json',
            'hollerkit-protocol': '1',
          },
          body: JSON.stringify({
            version: 1,
            quests: manifest.quests,
            ...(sha ? { sha } : {}),
            ...(pr !== undefined ? { pr } : {}),
          }),
        })

        const payload = (await response.json()) as {
          ok?: boolean
          quests?: QuestVersionRecord[]
          activatedIds?: string[]
          reactivatedIds?: string[]
          retiredIds?: string[]
          error?: { code?: string; message?: string }
        }

        if (!response.ok || !payload.ok) {
          const errMsg = payload?.error?.message ?? `HTTP ${response.status}`
          stderr(`Error syncing quests: ${errMsg}`)
          return 1
        }

        const quests = payload.quests ?? []
        const retiredIds = payload.retiredIds ?? []
        const activated = Array.isArray(payload.activatedIds)
          ? payload.activatedIds.length
          : quests.length
        const reactivated = Array.isArray(payload.reactivatedIds)
          ? payload.reactivatedIds.length
          : 0

        stdout(
          `Synced ${quests.length} quest(s): activated=${activated}, reactivated=${reactivated}, retired=${retiredIds.length}`,
        )
        return 0
      }

      stderr(`Error: Unknown quests subcommand: ${subcommand ?? ''}`)
      return 1
    }

    if (group === 'keys') {
      if (subcommand === 'create') {
        const { flags } = parseFlags(rest)
        const dbUrl = flags.get('db')
        const scopesRaw = flags.get('scopes')
        const label = flags.get('label') ?? null

        if (!dbUrl || !scopesRaw) {
          stderr(
            'Error: Usage: hollerkit keys create --db <url> --scopes <comma-separated-scopes> [--label <label>]',
          )
          return 1
        }

        const scopes = scopesRaw
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean) as Scope[]
        if (scopes.length === 0 || !scopes.every((s) => VALID_SCOPES.has(s))) {
          stderr(
            `Error: Invalid scopes. Allowed scopes: ${Array.from(VALID_SCOPES).join(', ')}`,
          )
          return 1
        }

        const rawKey = generateApiKey()
        const keyHash = hashApiKey(rawKey)
        const keyPrefix = getApiKeyPrefix(rawKey)

        const store = createStore(dbUrl)
        try {
          await store.createApiKey({
            keyHash,
            keyPrefix,
            label,
            scopes,
          })
        } finally {
          await store.close?.()
        }

        stdout(rawKey)
        stdout(`Prefix: ${keyPrefix} | Scopes: ${scopes.join(', ')}${label ? ` | Label: ${label}` : ''}`)
        return 0
      }

      if (subcommand === 'revoke') {
        const { positional, flags } = parseFlags(rest)
        const dbUrl = flags.get('db')
        const target = positional[0]

        if (!dbUrl || !target) {
          stderr('Error: Usage: hollerkit keys revoke --db <url> <key-prefix-or-hash-or-label>')
          return 1
        }

        const store = createStore(dbUrl)
        let revoked = false
        try {
          revoked = await store.revokeApiKey(target)
        } finally {
          await store.close?.()
        }

        if (!revoked) {
          stderr(`Error: No active API key matched "${target}".`)
          return 1
        }

        stdout(`Revoked API key matching "${target}".`)
        return 0
      }

      stderr(`Error: Unknown keys subcommand: ${subcommand ?? ''}`)
      return 1
    }

    if (group === 'conformance') {
      const allArgs = subcommand ? [subcommand, ...rest] : rest
      const { flags } = parseFlags(allArgs)
      const serverUrl = flags.get('server')
      if (!serverUrl) {
        stderr(
          'Error: Usage: hollerkit conformance --server <url> [--tester-token <tok>] [--quests-key <key>] [--agent-key <key>]',
        )
        return 1
      }

      const testerToken = flags.get('tester-token') ?? process.env.HOLLERKIT_TESTER_TOKEN ?? 'tester-token'
      const questsWriteKey = flags.get('quests-key') ?? process.env.HOLLERKIT_QUESTS_KEY ?? 'quests-key'
      const agentKey = flags.get('agent-key') ?? process.env.HOLLERKIT_AGENT_KEY ?? 'agent-key'

      const result = await runConformanceSuite({
        baseUrl: serverUrl,
        fetch: fetchFn,
        testerToken,
        questsWriteKey,
        agentKey,
      })

      for (const step of result.steps) {
        stdout(`✓ ${step.name} (${step.durationMs}ms)`)
      }
      stdout(`Conformance suite passed (${result.steps.length} steps).`)
      return 0
    }

    if (group === 'migrations') {
      if (subcommand === 'copy') {
        const targetDirArg = rest[0]
        if (!targetDirArg) {
          stderr('Error: Usage: hollerkit migrations copy <dir>')
          return 1
        }

        const targetDir = resolve(cwd, targetDirArg)
        await mkdir(targetDir, { recursive: true })

        const migrationsDir = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'migrations')
        const entries = await readdir(migrationsDir)
        const sqlFiles = entries.filter((f) => f.endsWith('.sql')).sort()

        if (sqlFiles.length === 0) {
          stderr('Error: No SQL migration files found.')
          return 1
        }

        for (const file of sqlFiles) {
          const srcPath = join(migrationsDir, file)
          const destPath = join(targetDir, file)
          try {
            await copyFile(srcPath, destPath, constants.COPYFILE_EXCL)
          } catch (error) {
            if ((error as NodeJS.ErrnoException)?.code === 'EEXIST') {
              stderr(`Error: Migration file already exists at destination: ${destPath}`)
              return 1
            }
            throw error
          }
          stdout(`Copied ${file} -> ${destPath}`)
        }
        return 0
      }

      stderr(`Error: Unknown migrations subcommand: ${subcommand ?? ''}`)
      return 1
    }

    if (group === 'outbox') {
      if (subcommand === 'flush') {
        const { flags } = parseFlags(rest)
        const dbUrl = flags.get('db') ?? process.env.DATABASE_URL ?? process.env.HOLLERKIT_DB_POOLER_URL
        const githubRepo = flags.get('github-repo') ?? process.env.HOLLERKIT_GITHUB_REPO
        const githubToken = flags.get('github-token') ?? process.env.HOLLERKIT_GITHUB_TOKEN

        if (!dbUrl || !githubRepo || !githubToken) {
          stderr(
            'Error: Usage: hollerkit outbox flush [--db <url>] [--github-repo <owner/repo>] [--github-token <token>] [--supabase-url <url> --supabase-service-role-key <key> [--bucket <bucket>]] [--limit <n>] (or set DATABASE_URL/HOLLERKIT_DB_POOLER_URL, HOLLERKIT_GITHUB_REPO, HOLLERKIT_GITHUB_TOKEN, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, HOLLERKIT_BUCKET)',
          )
          return 1
        }

        let limit: number | undefined
        const limitRaw = flags.get('limit')
        if (limitRaw !== undefined) {
          const parsedLimit = Number(limitRaw)
          if (!Number.isInteger(parsedLimit) || parsedLimit <= 0) {
            stderr('Error: --limit must be a positive integer.')
            return 1
          }
          limit = parsedLimit
        }

        const supabaseUrl = flags.get('supabase-url') ?? process.env.SUPABASE_URL
        const supabaseServiceRoleKey =
          flags.get('supabase-service-role-key') ?? process.env.SUPABASE_SERVICE_ROLE_KEY
        const bucket = flags.get('bucket') ?? process.env.HOLLERKIT_BUCKET ?? 'hollerkit'

        const storage =
          supabaseUrl && supabaseServiceRoleKey
            ? supabaseStorage({
                url: supabaseUrl,
                serviceRoleKey: supabaseServiceRoleKey,
                bucket,
                fetchImpl: fetchFn,
              })
            : undefined

        const sink = githubIssuesSink({
          repo: githubRepo,
          token: githubToken,
          fetchImpl: fetchFn,
        })

        const store = createStore(dbUrl)
        try {
          const flushed = await flushOutbox({
            store,
            storage,
            sinks: [sink],
            limit,
            readUrlTtlSeconds: 604_800,
          })
          stdout(
            `Outbox flush complete: claimed=${flushed.claimed}, delivered=${flushed.delivered.length}, failed=${flushed.failed.length}`,
          )
          return flushed.failed.length > 0 ? 1 : 0
        } finally {
          await store.close?.()
        }
      }

      stderr(`Error: Unknown outbox subcommand: ${subcommand ?? ''}`)
      return 1
    }

    if (group === 'values') {
      const allArgs = subcommand ? [subcommand, ...rest] : rest
      const { flags } = parseFlags(allArgs)
      const serverUrl = flags.get('server') ?? process.env.HOLLERKIT_SERVER_URL ?? process.env.HOLLERKIT_SERVER
      const apiKey = flags.get('key') ?? process.env.HOLLERKIT_API_KEY ?? process.env.HOLLERKIT_KEY
      const dbUrl = flags.get('db') ?? process.env.DATABASE_URL ?? process.env.HOLLERKIT_DB_POOLER_URL
      const quest = flags.get('quest') ?? flags.get('questId')
      const label = flags.get('label')
      const rawGroupBy = flags.get('groupBy')
      const allowedGroupBys = new Set<ValueGroupBy>(['build', 'appVersion', 'device', 'os', 'version', 'label'])
      if (rawGroupBy !== undefined && rawGroupBy.trim() !== '') {
        if (!allowedGroupBys.has(rawGroupBy as ValueGroupBy)) {
          stderr(`Error: Invalid --groupBy "${rawGroupBy}". Must be one of: build, appVersion, device, os, version, label.`)
          return 1
        }
      }
      const groupBy = (rawGroupBy && rawGroupBy.trim() !== '' ? rawGroupBy.trim() : undefined) as ValueGroupBy | undefined

      const build = flags.get('build')
      const appVersion = flags.get('appVersion')
      const device = flags.get('device')
      const os = flags.get('os')

      const rawSource = flags.get('source')
      const allowedSources = new Set<ValueSource>(['capture', 'answer'])
      if (rawSource !== undefined && rawSource.trim() !== '') {
        if (!allowedSources.has(rawSource as ValueSource)) {
          stderr(`Error: Invalid --source "${rawSource}". Must be one of: capture, answer.`)
          return 1
        }
      }
      const source = (rawSource && rawSource.trim() !== '' ? rawSource.trim() : undefined) as ValueSource | undefined

      const since = flags.get('since')
      const versionRaw = flags.get('version')
      let version: number | undefined
      if (versionRaw !== undefined) {
        const parsed = Number(versionRaw)
        if (!Number.isInteger(parsed) || parsed < 1) {
          stderr('Error: --version must be an integer >= 1.')
          return 1
        }
        version = parsed
      }

      const limitRaw = flags.get('limit')
      let limit: number | undefined
      if (limitRaw !== undefined) {
        const parsed = Number(limitRaw)
        if (!Number.isInteger(parsed) || parsed < 1 || parsed > 500) {
          stderr('Error: --limit must be an integer between 1 and 500.')
          return 1
        }
        limit = parsed
      }
      const isJson = flags.has('json')

      let queryResult: any
      if (serverUrl) {
        const url = new URL(`${serverUrl.replace(/\/+$/, '')}/v1/values`)
        if (quest) url.searchParams.set('quest', quest)
        if (label) url.searchParams.set('label', label)
        if (groupBy) url.searchParams.set('groupBy', groupBy)
        if (build) url.searchParams.set('build', build)
        if (appVersion) url.searchParams.set('appVersion', appVersion)
        if (device) url.searchParams.set('device', device)
        if (os) url.searchParams.set('os', os)
        if (source) url.searchParams.set('source', source)
        if (since) url.searchParams.set('since', since)
        if (version !== undefined) url.searchParams.set('version', String(version))
        if (limit !== undefined) url.searchParams.set('limit', String(limit))

        const headers: Record<string, string> = {
          'hollerkit-protocol': '1',
        }
        if (apiKey) {
          headers['authorization'] = `Bearer ${apiKey}`
        }
        const resp = await fetchFn(url.toString(), {
          method: 'GET',
          headers,
        })
        if (!resp.ok) {
          const errBody = await resp.text()
          stderr(`Error (${resp.status}): ${errBody}`)
          return 1
        }
        queryResult = await resp.json()
      } else if (dbUrl) {
        const store = createStore(dbUrl)
        try {
          queryResult = await store.queryValues({
            quest,
            version,
            label,
            build,
            appVersion,
            device,
            os,
            source,
            since,
            groupBy,
            limit,
          })
        } finally {
          await store.close?.()
        }
      } else {
        stderr(
          'Error: Usage: hollerkit values [--server <url> --key <key>] or [--db <url>] [--quest <id>] [--label <label>] [--groupBy <group>] [--build <build>] [--json]',
        )
        return 1
      }

      if (isJson) {
        stdout(JSON.stringify(queryResult, null, 2))
        return 0
      }

      const summary = queryResult.summary ?? queryResult
      stdout(
        `Quest: ${queryResult.quest ?? 'all'}\tLabel: ${queryResult.label ?? 'all'}\tUnit: ${summary.unit ?? 'none'}`,
      )
      stdout(
        `n: ${summary.n}\tmedian: ${summary.median ?? '-'}\tp90: ${summary.p90 ?? '-'}\tmin: ${summary.min ?? '-'}\tmax: ${summary.max ?? '-'}`,
      )

      if (queryResult.groups && queryResult.groups.length > 0) {
        stdout(`\nGrouped by ${queryResult.groupBy}:`)
        for (const g of queryResult.groups) {
          stdout(
            `  ${g.key}:\tn=${g.n}\tmedian=${g.median ?? '-'}\tp90=${g.p90 ?? '-'}\tmin=${g.min ?? '-'}\tmax=${g.max ?? '-'}`,
          )
        }
      }
      return 0
    }

    stderr(`Error: Unknown command "${group}". Run "hollerkit --help" for usage.`)
    return 1
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    stderr(`Error: ${message}`)
    return 1
  }
}

/**
 * Parses CLI positional arguments and `--flag value` / `--flag=value` options.
 */
function parseFlags(args: string[]): { positional: string[]; flags: Map<string, string> } {
  const positional: string[] = []
  const flags = new Map<string, string>()

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!
    if (arg.startsWith('--')) {
      const eqIdx = arg.indexOf('=')
      if (eqIdx >= 0) {
        const key = arg.slice(2, eqIdx)
        const val = arg.slice(eqIdx + 1)
        flags.set(key, val)
      } else {
        const key = arg.slice(2)
        const next = args[i + 1]
        if (next !== undefined && !next.startsWith('--')) {
          flags.set(key, next)
          i += 1
        } else {
          flags.set(key, 'true')
        }
      }
    } else {
      positional.push(arg)
    }
  }

  return { positional, flags }
}

/**
 * Prints the `hollerkit` CLI usage help message.
 */
function printUsage(stdout: (line: string) => void): void {
  stdout(`HollerKit v1 CLI

Usage:
  hollerkit quests validate <file>
  hollerkit quests sync <file> --server <url> --key <key> [--sha <sha>] [--pr <pr>]
  hollerkit values [--server <url>] [--key <key>] [--db <url>] [--quest <id>] [--label <label>] [--groupBy <group>] [--build <build>] [--json]
  hollerkit keys create --db <url> --scopes <comma-separated-scopes> [--label <label>]
  hollerkit keys revoke --db <url> <key-prefix-or-hash-or-label>
  hollerkit conformance --server <url> [--tester-token <tok>] [--quests-key <key>] [--agent-key <key>]
  hollerkit outbox flush [--db <url>] [--github-repo <owner/repo>] [--github-token <token>] [--supabase-url <url> --supabase-service-role-key <key> [--bucket <bucket>]] [--limit <n>] (or set DATABASE_URL/HOLLERKIT_DB_POOLER_URL, HOLLERKIT_GITHUB_REPO, HOLLERKIT_GITHUB_TOKEN, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, HOLLERKIT_BUCKET)
  hollerkit migrations copy <dir>`)
}

/**
 * Determines whether the current module is being executed as the main CLI entrypoint,
 * resolving symlinks so npm `bin` invocations match `import.meta.url`.
 */
export function isCliEntrypoint(argv1: string | undefined, moduleUrl: string): boolean {
  if (!argv1) return false
  const modulePath = fileURLToPath(moduleUrl)
  try {
    return realpathSync(argv1) === realpathSync(modulePath)
  } catch {
    return resolve(argv1) === resolve(modulePath)
  }
}

const isMain = isCliEntrypoint(process.argv[1], import.meta.url)

if (isMain) {
  runCli(process.argv.slice(2)).then((code) => {
    process.exitCode = code
  })
}
