#!/usr/bin/env node
/**
 * Automates cutting a HollerKit release across all versioned files (`CHANGELOG.md`,
 * `ios/README.md`, `server/package.json`, `server/package-lock.json`, `mcp/package.json`,
 * `mcp/package-lock.json`, and `mcp/src/server.ts`), and tagging + publishing the GitHub
 * Release once merged to `main`.
 *
 * Usage:
 *   node scripts/release-cut.mjs --dry-run
 *   node scripts/release-cut.mjs [--version 1.0.0-beta.5] [--bump prerelease|patch|minor|major] [--notes "..."]
 *   node scripts/release-cut.mjs --tag-and-publish [--version 1.0.0-beta.5]
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(__dirname, '..')

const ALLOWED_AUTHOR_NAMES = new Set(['liam ronan', 'liampronan', 'agent-liam'])
const ALLOWED_AUTHOR_EMAILS = new Set([
  'liampronan@gmail.com',
  'liampronan@users.noreply.github.com',
  'agent-liam@macbookpro.lan',
])

/**
 * Returns `true` only when a commit's author name and email belong to `liampronan`.
 *
 * @param {string} authorName
 * @param {string} authorEmail
 * @returns {boolean}
 */
export function isAllowedAuthor(authorName, authorEmail) {
  const normName = authorName.trim().toLowerCase()
  const normEmail = authorEmail.trim().toLowerCase()
  const emailAllowed =
    ALLOWED_AUTHOR_EMAILS.has(normEmail) ||
    /^(?:\d+\+)?liampronan@users\.noreply\.github\.com$/i.test(normEmail)
  const nameAllowed = ALLOWED_AUTHOR_NAMES.has(normName)
  return emailAllowed && nameAllowed
}

/**
 * Runs a git command inside the repository root and returns trimmed stdout.
 *
 * @param {string[]} args
 * @param {{ cwd?: string }} [options]
 * @returns {string}
 */
export function runGit(args, options = {}) {
  return execFileSync('git', args, {
    cwd: options.cwd ?? REPO_ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim()
}

/**
 * Computes the next semantic version string from the current version and a bump mode.
 *
 * @param {string} currentVersion
 * @param {'prerelease' | 'patch' | 'minor' | 'major'} [bump='prerelease']
 * @returns {string}
 */
export function bumpVersion(currentVersion, bump = 'prerelease') {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+?)(?:\.(\d+))?)?$/.exec(currentVersion.trim())
  if (!match) {
    throw new Error(`Invalid semantic version: "${currentVersion}"`)
  }
  const major = Number(match[1])
  const minor = Number(match[2])
  const patch = Number(match[3])
  const preTag = match[4]
  const preNum = match[5] !== undefined ? Number(match[5]) : undefined

  switch (bump) {
    case 'prerelease': {
      if (preTag !== undefined && preNum !== undefined) {
        return `${major}.${minor}.${patch}-${preTag}.${preNum + 1}`
      }
      if (preTag !== undefined) {
        return `${major}.${minor}.${patch}-${preTag}.1`
      }
      return `${major}.${minor}.${patch + 1}-beta.1`
    }
    case 'patch':
      if (preTag !== undefined) {
        return `${major}.${minor}.${patch}`
      }
      return `${major}.${minor}.${patch + 1}`
    case 'minor':
      return `${major}.${minor + 1}.0`
    case 'major':
      return `${major + 1}.0.0`
    default:
      throw new Error(`Unsupported bump mode: "${bump}"`)
  }
}

/**
 * Formats raw commit subjects since the previous tag into grouped markdown bullets for `CHANGELOG.md`.
 *
 * @param {string[]} subjects
 * @param {boolean} hasMigrationChanges
 * @returns {string[]}
 */
export function formatChangelogBullets(subjects, hasMigrationChanges = false) {
  const bullets = []
  for (const raw of subjects) {
    const trimmed = raw.trim()
    if (!trimmed || /^chore:\s*release\b/i.test(trimmed)) {
      continue
    }
    const conventional = /^([a-z]+)(?:\(([^)]+)\))?!?:\s*(.+)$/i.exec(trimmed)
    if (conventional) {
      const type = conventional[1].toLowerCase()
      const scope = (conventional[2] ?? '').toLowerCase()
      const description = conventional[3].trim()
      const capitalized = description.charAt(0).toUpperCase() + description.slice(1)
      let label = 'General'
      if (scope.includes('ios') || scope.includes('invocation') || scope.includes('quest-board')) {
        label = 'iOS'
      } else if (scope.includes('mcp')) {
        label = 'MCP'
      } else if (scope.includes('server')) {
        label = 'Server'
      } else if (type === 'feat' || type === 'fix') {
        label = 'iOS & Server'
      }
      const sentence = capitalized.endsWith('.') ? capitalized : `${capitalized}.`
      bullets.push(`- **${label}:** ${sentence}`)
    } else {
      const capitalized = trimmed.charAt(0).toUpperCase() + trimmed.slice(1)
      const sentence = capitalized.endsWith('.') ? capitalized : `${capitalized}.`
      bullets.push(`- ${sentence}`)
    }
  }

  if (hasMigrationChanges) {
    bullets.push('- **Database:** Includes SQL schema migration updates under `server/migrations/`.')
  } else {
    bullets.push(
      '- **Database:** No new database migrations are required for this release; the existing `001_hollerkit_v1.sql` schema remains current.',
    )
  }

  return bullets
}

/**
 * Extracts the markdown body for a specific `## <version>` section from `CHANGELOG.md`.
 *
 * @param {string} changelogContent
 * @param {string} version
 * @returns {string}
 */
export function extractChangelogSection(changelogContent, version) {
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const headerRegex = new RegExp(`^##\\s+${escaped}\\s*$`, 'm')
  const match = headerRegex.exec(changelogContent)
  if (!match) {
    throw new Error(`Could not find "## ${version}" section in CHANGELOG.md`)
  }
  const startIdx = match.index + match[0].length
  const rest = changelogContent.slice(startIdx)
  const nextHeader = /^##\s+/m.exec(rest)
  const body = nextHeader ? rest.slice(0, nextHeader.index) : rest
  return body.trim()
}

/**
 * Resolves a GitHub token from `GITHUB_TOKEN` / `GH_TOKEN` or `git credential fill`.
 *
 * @returns {string}
 */
function resolveGitHubToken() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN.trim()
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN.trim()
  const out = execFileSync('git', ['credential', 'fill'], {
    cwd: REPO_ROOT,
    input: 'protocol=https\nhost=github.com\n\n',
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'ignore'],
  })
  for (const line of out.split('\n')) {
    if (line.startsWith('password=')) {
      return line.slice('password='.length).trim()
    }
  }
  throw new Error('Could not resolve GitHub token from environment or git credential helper.')
}

/**
 * Parses CLI flags passed to `scripts/release-cut.mjs`.
 *
 * @param {string[]} argv
 */
function parseArgs(argv) {
  /** @type {{ version?: string; bump: 'prerelease' | 'patch' | 'minor' | 'major'; notes?: string; ref: string; dryRun: boolean; force: boolean; tagAndPublish: boolean; repo: string }} */
  const parsed = {
    bump: 'prerelease',
    ref: 'HEAD',
    dryRun: false,
    force: false,
    tagAndPublish: false,
    repo: 'Liampronan/HollerKit',
  }

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--dry-run' || arg === '--status') {
      parsed.dryRun = true
    } else if (arg === '--force') {
      parsed.force = true
    } else if (arg === '--tag-and-publish') {
      parsed.tagAndPublish = true
    } else if (arg === '--version' && argv[i + 1]) {
      parsed.version = argv[++i]
    } else if (arg === '--ref' && argv[i + 1]) {
      parsed.ref = argv[++i]
    } else if (arg === '--bump' && argv[i + 1]) {
      const b = argv[++i]
      if (b === 'prerelease' || b === 'patch' || b === 'minor' || b === 'major') {
        parsed.bump = b
      } else {
        throw new Error(`Invalid --bump value: "${b}"`)
      }
    } else if (arg === '--notes' && argv[i + 1]) {
      parsed.notes = argv[++i]
    } else if (arg === '--repo' && argv[i + 1]) {
      parsed.repo = argv[++i]
    } else if (arg === '--help' || arg === '-h') {
      console.log(
        [
          'Usage:',
          '  node scripts/release-cut.mjs --dry-run',
          '  node scripts/release-cut.mjs [--version <v>] [--bump prerelease|patch|minor|major] [--notes "..."] [--force]',
          '  node scripts/release-cut.mjs --tag-and-publish [--version <v>]',
        ].join('\n'),
      )
      process.exit(0)
    }
  }
  return parsed
}

/**
 * Updates a JSON file's top-level `version` (and `packages[""].version` if present).
 *
 * @param {string} filePath
 * @param {string} nextVersion
 */
function updatePackageVersionFile(filePath, nextVersion) {
  const raw = readFileSync(filePath, 'utf8')
  const parsed = JSON.parse(raw)
  parsed.version = nextVersion
  if (parsed.packages && parsed.packages[''] && typeof parsed.packages[''] === 'object') {
    parsed.packages[''].version = nextVersion
  }
  writeFileSync(filePath, `${JSON.stringify(parsed, null, 2)}\n`, 'utf8')
}

/**
 * Verifies that the target git ref was authored by `liampronan`, throwing if not.
 *
 * @param {string} ref
 * @returns {{ sha: string; authorName: string; authorEmail: string }}
 */
export function verifyRefAuthorAllowed(ref) {
  const line = runGit(['log', '-1', '--pretty=format:%H\t%an\t%ae', ref])
  const [sha = '', authorName = '', authorEmail = ''] = line.split('\t')
  if (!isAllowedAuthor(authorName, authorEmail)) {
    throw new Error(
      `Refusing to run release-cut on commit ${sha.slice(0, 7)} authored by "${authorName} <${authorEmail}>" (only liampronan commits are permitted).`,
    )
  }
  return { sha, authorName, authorEmail }
}

/**
 * Tags `ref` and publishes the GitHub Release for `version` after verifying the commit author is `liampronan`.
 *
 * @param {string} version
 * @param {string} repo
 * @param {boolean} dryRun
 * @param {string} ref
 */
async function tagAndPublishRelease(version, repo, dryRun, ref) {
  const { sha: headSha } = verifyRefAuthorAllowed(ref)
  const changelogPath = resolve(REPO_ROOT, 'CHANGELOG.md')
  const changelog = readFileSync(changelogPath, 'utf8')
  const notesBody = extractChangelogSection(changelog, version)
  const existingTags = new Set(
    runGit(['tag', '--list'])
      .split('\n')
      .map((s) => s.trim())
      .filter(Boolean),
  )

  if (dryRun) {
    console.log(
      JSON.stringify(
        {
          action: 'tag-and-publish',
          dryRun: true,
          version,
          headSha,
          tagAlreadyExists: existingTags.has(version),
          releaseNotes: notesBody,
        },
        null,
        2,
      ),
    )
    return
  }

  if (!existingTags.has(version)) {
    runGit(['tag', version, headSha])
  }
  runGit(['push', 'origin', `refs/tags/${version}`])

  const token = resolveGitHubToken()
  const isPrerelease = version.includes('-')
  const response = await fetch(`https://api.github.com/repos/${repo}/releases`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify({
      tag_name: version,
      target_commitish: headSha,
      name: version,
      body: `## ${version}\n\n${notesBody}`,
      draft: false,
      prerelease: isPrerelease,
    }),
  })

  if (response.status === 422) {
    // Release already exists for this tag
    console.log(JSON.stringify({ ok: true, version, headSha, note: 'GitHub Release already exists.' }, null, 2))
    return
  }
  if (!response.ok) {
    const errText = await response.text()
    throw new Error(`Failed to publish GitHub Release (${response.status}): ${errText}`)
  }
  const releaseJson = await response.json()
  console.log(
    JSON.stringify(
      {
        ok: true,
        version,
        headSha,
        htmlUrl: releaseJson.html_url,
      },
      null,
      2,
    ),
  )
}

/**
 * Main CLI entrypoint for `scripts/release-cut.mjs`.
 */
async function main() {
  const args = parseArgs(process.argv.slice(2))
  const serverPkgPath = resolve(REPO_ROOT, 'server/package.json')
  const serverLockPath = resolve(REPO_ROOT, 'server/package-lock.json')
  const mcpPkgPath = resolve(REPO_ROOT, 'mcp/package.json')
  const mcpLockPath = resolve(REPO_ROOT, 'mcp/package-lock.json')
  const mcpServerTsPath = resolve(REPO_ROOT, 'mcp/src/server.ts')
  const iosReadmePath = resolve(REPO_ROOT, 'ios/README.md')
  const changelogPath = resolve(REPO_ROOT, 'CHANGELOG.md')

  const serverPkg = JSON.parse(readFileSync(serverPkgPath, 'utf8'))
  const currentVersion = String(serverPkg.version)

  if (args.tagAndPublish) {
    const targetVersion = args.version ?? currentVersion
    await tagAndPublishRelease(targetVersion, args.repo, args.dryRun, args.ref)
    return
  }

  verifyRefAuthorAllowed(args.ref)

  const nextVersion = args.version ?? bumpVersion(currentVersion, args.bump)
  const existingTags = new Set(
    runGit(['tag', '--list'])
      .split('\n')
      .map((s) => s.trim())
      .filter(Boolean),
  )
  const baseRef = existingTags.has(currentVersion) ? currentVersion : null
  const logRange = baseRef ? `${baseRef}..${args.ref}` : args.ref

  const logLines = runGit(['log', logRange, '--pretty=format:%H\t%an\t%ae\t%s'])
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)

  const rawCommits = []
  const skippedNonAuthorCommits = []
  for (const line of logLines) {
    const [sha = '', authorName = '', authorEmail = '', ...subjectParts] = line.split('\t')
    const subject = subjectParts.join('\t').trim()
    if (!subject || /^chore:\s*release\b/i.test(subject)) {
      continue
    }
    if (isAllowedAuthor(authorName, authorEmail)) {
      rawCommits.push(subject)
    } else {
      skippedNonAuthorCommits.push(`${sha.slice(0, 7)} (${authorName} <${authorEmail}>): ${subject}`)
    }
  }

  let hasMigrationChanges = false
  if (baseRef) {
    const changedMigrations = runGit(['diff', '--name-only', `${baseRef}..${args.ref}`, '--', 'server/migrations'])
    hasMigrationChanges = changedMigrations.length > 0
  }

  if (rawCommits.length === 0 && !args.force) {
    console.log(
      JSON.stringify(
        {
          ok: true,
          skipped: true,
          currentVersion,
          skippedNonAuthorCommits,
          reason: `No new liampronan commits since ${baseRef ?? args.ref}; skipping release cut.`,
        },
        null,
        2,
      ),
    )
    return
  }

  const bullets = args.notes
    ? args.notes
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
    : formatChangelogBullets(rawCommits, hasMigrationChanges)

  const changelogSection = `## ${nextVersion}\n\n${bullets.join('\n')}`

  if (args.dryRun) {
    console.log(
      JSON.stringify(
        {
          ok: true,
          dryRun: true,
          currentVersion,
          nextVersion,
          commitsSinceLastRelease: rawCommits,
          skippedNonAuthorCommits,
          changelogSection,
          filesToUpdate: [
            'CHANGELOG.md',
            'ios/README.md',
            'server/package.json',
            'server/package-lock.json',
            'mcp/package.json',
            'mcp/package-lock.json',
            'mcp/src/server.ts',
          ],
        },
        null,
        2,
      ),
    )
    return
  }

  // 1. Update server/package.json, server/package-lock.json, mcp/package.json, mcp/package-lock.json
  updatePackageVersionFile(serverPkgPath, nextVersion)
  updatePackageVersionFile(serverLockPath, nextVersion)
  updatePackageVersionFile(mcpPkgPath, nextVersion)
  updatePackageVersionFile(mcpLockPath, nextVersion)

  // 2. Update HOLLERKIT_MCP_VERSION in mcp/src/server.ts
  const mcpServerTs = readFileSync(mcpServerTsPath, 'utf8')
  const updatedMcpServerTs = mcpServerTs.replace(
    /export const HOLLERKIT_MCP_VERSION = '[^']+'/,
    `export const HOLLERKIT_MCP_VERSION = '${nextVersion}'`,
  )
  writeFileSync(mcpServerTsPath, updatedMcpServerTs, 'utf8')

  // 3. Update Exact Version in ios/README.md
  const iosReadme = readFileSync(iosReadmePath, 'utf8')
  const updatedIosReadme = iosReadme.replace(
    /\*\*Exact Version: `[^`]+`\*\*/,
    `**Exact Version: \`${nextVersion}\`**`,
  )
  writeFileSync(iosReadmePath, updatedIosReadme, 'utf8')

  // 4. Prepend section to CHANGELOG.md (unless already present)
  const changelog = readFileSync(changelogPath, 'utf8')
  const escapedVersion = nextVersion.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  if (!new RegExp(`^##\\s+${escapedVersion}\\s*$`, 'm').test(changelog)) {
    const updatedChangelog = changelog.replace(
      /^#\s+Changelog\s*\n+/,
      `# Changelog\n\n${changelogSection}\n\n`,
    )
    writeFileSync(changelogPath, updatedChangelog, 'utf8')
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        currentVersion,
        nextVersion,
        commitsCount: rawCommits.length,
        updatedFiles: [
          'CHANGELOG.md',
          'ios/README.md',
          'server/package.json',
          'server/package-lock.json',
          'mcp/package.json',
          'mcp/package-lock.json',
          'mcp/src/server.ts',
        ],
      },
      null,
      2,
    ),
  )
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err))
    process.exit(1)
  })
}
