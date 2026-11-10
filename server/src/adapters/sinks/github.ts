import { HollerKitError } from '../../errors.js'
import type {
  FeedbackDetail,
  HollerKitSink,
  HollerKitSinkDeliveryContext,
} from '../../v1/sinks.js'
import type {
  FeedbackRecord,
  HollerKitStore,
  TriageStatus,
} from '../../v1/store.js'

const REPO_SEGMENT_REGEX = /^[A-Za-z0-9_.-]+$/
const FEEDBACK_ID_MARKER_GLOBAL_REGEX =
  /<!--\s*hollerkit-feedback-id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*-->/gi
const SHA256_SIGNATURE_REGEX = /^sha256=([0-9a-f]{64})$/i
const DEFAULT_WEBHOOK_MAX_BYTES = 1_048_576

export interface GitHubIssuesSinkOptions {
  /**
   * Target GitHub repository in `"owner/repo"` format.
   */
  repo: string
  /**
   * GitHub personal access token or GitHub App installation token with `issues:write` permission.
   */
  token: string
  /**
   * Unique sink name registered in `hollerkit.outbox`. Defaults to `"github"`.
   */
  name?: string | undefined
  /**
   * Base URL for the GitHub REST API. Defaults to `"https://api.github.com"`.
   */
  apiBaseUrl?: string | undefined
  /**
   * Static labels applied to every created GitHub issue. Defaults to `["hollerkit"]`.
   */
  labels?: string[] | undefined
  /**
   * Whether to automatically append dynamic labels (`bug`, `quest:fail`, `quest:unsure`, `area:<area>`).
   * Defaults to `true`.
   */
  includeDynamicLabels?: boolean | undefined
  /**
   * Optional GitHub usernames to assign to newly created issues.
   */
  assignees?: string[] | undefined
  /**
   * Optional predicate controlling which feedback items enqueue this sink.
   * Defaults to `defaultSinkWhen` (bug reports and failed/unsure quest runs).
   */
  when?: ((feedback: FeedbackRecord) => boolean) | undefined
  /**
   * Whether retry attempts (`attempts > 0`) should query GitHub Search API for an existing
   * issue with the `hollerkit-feedback-id` marker before creating a new issue. Defaults to `true`.
   */
  deduplicateOnRetry?: boolean | undefined
  /**
   * Custom `fetch` implementation for testing or proxying.
   */
  fetchImpl?: typeof globalThis.fetch | undefined
}

export interface FormattedGitHubIssue {
  title: string
  body: string
  labels: string[]
}

export interface GitHubWebhookOptions {
  /**
   * Store used to look up and triage HollerKit feedback items when linked GitHub issues change state.
   */
  store: HollerKitStore
  /**
   * GitHub webhook secret configured on the repository/app (`X-Hub-Signature-256`).
   */
  secret: string
  /**
   * Default actor recorded in `hollerkit.triage` when the webhook payload does not include `sender.login`.
   * Defaults to `"github-webhook"`.
   */
  actor?: string | undefined
  /**
   * Maximum webhook JSON payload size in bytes. Defaults to 1 MB (`1_048_576`).
   */
  maxBodyBytes?: number | undefined
  /**
   * Optional reconciliation callback invoked when a webhook arrives for a feedback item that does not
   * yet have its GitHub issue link recorded in `feedback.links` (e.g. outbox delivery still pending).
   */
  reconcileFeedbackOutbox?: ((feedbackId: string) => Promise<void>) | undefined
  /**
   * Clock source for deterministic testing.
   */
  now?: (() => Date) | undefined
}

/**
 * Parses and validates a GitHub `"owner/repo"` identifier.
 */
export function parseGitHubRepo(repo: string): { owner: string; repo: string } {
  const trimmed = repo?.trim() ?? ''
  const parts = trimmed.split('/')
  if (parts.length !== 2) {
    throw new HollerKitError(
      400,
      'invalid_github_repo',
      'GitHub repo must be in "owner/repo" format.',
    )
  }
  const [owner, repoName] = parts as [string, string]
  if (
    !owner ||
    !repoName ||
    owner === '.' ||
    owner === '..' ||
    repoName === '.' ||
    repoName === '..' ||
    !REPO_SEGMENT_REGEX.test(owner) ||
    !REPO_SEGMENT_REGEX.test(repoName)
  ) {
    throw new HollerKitError(
      400,
      'invalid_github_repo',
      'GitHub repo owner and name must contain only alphanumeric, hyphen, underscore, or period characters.',
    )
  }
  return { owner, repo: repoName }
}

/**
 * Extracts the embedded HollerKit `feedbackId` UUID from the footer of a GitHub issue body, if present.
 */
export function extractFeedbackIdFromGitHubIssueBody(
  body: string | null | undefined,
): string | null {
  if (typeof body !== 'string' || body.length === 0) return null
  let lastId: string | null = null
  for (const match of body.matchAll(FEEDBACK_ID_MARKER_GLOBAL_REGEX)) {
    if (match[1]) {
      lastId = match[1].toLowerCase()
    }
  }
  return lastId
}

/**
 * Formats a HollerKit `FeedbackDetail` payload into a structured GitHub Issue title, Markdown body, and label set.
 */
export function formatGitHubIssue(
  detail: FeedbackDetail,
  options: {
    staticLabels?: string[] | undefined
    includeDynamicLabels?: boolean | undefined
  } = {},
): FormattedGitHubIssue {
  const { feedback, quest, events, attachments } = detail
  const staticLabels = options.staticLabels ?? ['hollerkit']
  const includeDynamic = options.includeDynamicLabels ?? true

  const labelSet = new Set<string>()
  for (const label of staticLabels) {
    const trimmed = label.trim()
    if (trimmed) labelSet.add(trimmed)
  }

  if (includeDynamic) {
    if (feedback.kind === 'report') {
      labelSet.add('bug')
    } else if (feedback.result) {
      labelSet.add(`quest:${feedback.result}`)
    }
    const resolvedArea = feedback.area ?? quest?.area ?? null
    if (resolvedArea && resolvedArea.trim().length > 0) {
      labelSet.add(`area:${resolvedArea.trim()}`)
    }
  }

  const summarySnippet = extractHeadlineSnippet(feedback.comment ?? feedback.transcript)
  const title = buildIssueTitle(feedback, quest?.title ?? null, summarySnippet)

  const lines: string[] = []

  // 1. Tester Comment / Voice Transcript (HTML comments escaped so user text cannot spoof footer markers)
  if (feedback.comment && feedback.comment.trim().length > 0) {
    lines.push('### Tester Notes', '', escapeUserMarkdown(feedback.comment.trim()), '')
  }

  if (
    feedback.transcript &&
    feedback.transcript.trim().length > 0 &&
    feedback.transcript.trim() !== feedback.comment?.trim()
  ) {
    lines.push(
      '### Voice Transcript',
      '',
      ...escapeUserMarkdown(feedback.transcript.trim())
        .split(/\r?\n/)
        .map((line) => `> ${line}`),
      '',
    )
  }

  // 2. Quest Checklist & Expectations (for quest_run or linked quest)
  if (quest || feedback.questId) {
    const questTitle = escapeUserMarkdown(quest?.title ?? feedback.questId ?? 'Quest')
    const versionBadge =
      feedback.questVersion !== null ? ` (v${feedback.questVersion})` : ''
    lines.push(`### QA Quest: ${questTitle}${versionBadge}`, '')

    if (quest && quest.setup.length > 0) {
      lines.push('**Setup:**')
      for (const item of quest.setup) {
        lines.push(`- ${escapeUserMarkdown(item)}`)
      }
      lines.push('')
    }

    if (quest && quest.steps.length > 0) {
      lines.push('**Steps:**')
      quest.steps.forEach((step, idx) => {
        const checked = feedback.stepsChecked[idx] === true
        lines.push(`- [${checked ? 'x' : ' '}] ${escapeUserMarkdown(step)}`)
      })
      lines.push('')
    }

    if (quest && quest.expect.length > 0) {
      lines.push('**Expected:**')
      for (const exp of quest.expect) {
        lines.push(`- ${escapeUserMarkdown(exp)}`)
      }
      lines.push('')
    }
  }

  // 3. Attachments (Screenshots, Marks, Audio, Video)
  if (attachments.length > 0) {
    lines.push('### Attachments', '')
    attachments.forEach((att, idx) => {
      const offsetSuffix =
        typeof att.offsetSeconds === 'number'
          ? ` (+${att.offsetSeconds.toFixed(1)}s)`
          : ''
      const label = `${att.kind} #${idx + 1}${offsetSuffix}`
      if (att.url) {
        if (att.kind === 'image' || att.kind === 'keyframe' || att.kind === 'mark') {
          lines.push(`- **${label}** (${att.mimeType}):`, '', `  ![${label}](${att.url})`, '')
        } else {
          lines.push(`- **[${label} (${att.mimeType})](${att.url})**`)
        }
      } else {
        lines.push(`- **${label}** (\`${att.key}\`, ${att.mimeType})`)
      }
    })
    lines.push('')
  }

  // 4. Timeline Events / Breadcrumbs
  if (events.length > 0) {
    lines.push('### Timeline Events', '')
    for (const ev of events) {
      const offset = `+${ev.offsetSeconds.toFixed(1)}s`
      const payloadKeys = Object.keys(ev.payload ?? {})
      const payloadSummary =
        payloadKeys.length > 0 ? ` — \`${escapeInlineCode(JSON.stringify(ev.payload))}\`` : ''
      lines.push(`- \`${offset}\` **${escapeUserMarkdown(ev.kind)}**${payloadSummary}`)
    }
    lines.push('')
  }

  // 5. Device & Build Context Table
  lines.push(
    '### Context',
    '',
    '| Field | Value |',
    '| :--- | :--- |',
    `| **Feedback ID** | \`${escapeTableCell(feedback.id)}\` |`,
    `| **Kind** | \`${escapeTableCell(feedback.kind)}\` |`,
  )
  if (feedback.questId) {
    const qVer = feedback.questVersion !== null ? ` (v${feedback.questVersion})` : ''
    lines.push(`| **Quest** | \`${escapeTableCell(feedback.questId)}${escapeTableCell(qVer)}\` |`)
  }
  if (feedback.result) {
    lines.push(`| **Result** | \`${escapeTableCell(feedback.result)}\` |`)
  }
  const area = feedback.area ?? quest?.area ?? null
  if (area) {
    lines.push(`| **Area** | \`${escapeTableCell(area)}\` |`)
  }
  lines.push(`| **Build** | \`${escapeTableCell(feedback.build)}\` |`)
  if (feedback.appVersion) {
    lines.push(`| **App Version** | \`${escapeTableCell(feedback.appVersion)}\` |`)
  }
  if (feedback.device) {
    lines.push(`| **Device** | ${escapeTableCell(feedback.device)} |`)
  }
  if (feedback.os) {
    lines.push(`| **OS** | ${escapeTableCell(feedback.os)} |`)
  }
  lines.push(
    `| **Submitter** | \`${escapeTableCell(feedback.submitterId)}\` |`,
    `| **Submitted At** | \`${escapeTableCell(feedback.createdAt)}\` |`,
    '',
  )

  // 6. Machine-readable metadata markers for agent & webhook correlation
  const metaJson = escapeHtmlCommentJson(
    JSON.stringify({
      feedbackId: feedback.id,
      kind: feedback.kind,
      questId: feedback.questId,
      questVersion: feedback.questVersion,
      result: feedback.result,
      build: feedback.build,
      appVersion: feedback.appVersion,
    }),
  )
  lines.push(
    `<!-- hollerkit-feedback-id: ${feedback.id} -->`,
    `<!-- hollerkit-meta: ${metaJson} -->`,
  )

  return {
    title,
    body: lines.join('\n'),
    labels: Array.from(labelSet),
  }
}

/**
 * Creates a `HollerKitSink` that opens a GitHub Issue for each matching feedback item.
 */
export function githubIssuesSink(options: GitHubIssuesSinkOptions): HollerKitSink {
  const { owner, repo } = parseGitHubRepo(options.repo)
  const token = options.token?.trim()
  if (!token) {
    throw new HollerKitError(400, 'invalid_github_token', 'GitHub token must be a non-empty string.')
  }

  const sinkName = options.name?.trim() || 'github'
  const apiBaseUrl = (options.apiBaseUrl ?? 'https://api.github.com').replace(/\/+$/, '')
  const fetchFn = options.fetchImpl ?? globalThis.fetch
  const deduplicateOnRetry = options.deduplicateOnRetry ?? true
  const assignees = options.assignees
    ?.map((a) => a.trim())
    .filter((a) => a.length > 0)

  const deliveredByFeedbackId = new Map<string, string>()
  const repoIssueUrlPrefix = `https://github.com/${owner}/${repo}/issues/`.toLowerCase()

  return {
    name: sinkName,
    when: options.when,
    async deliver(
      detail: FeedbackDetail,
      context?: HollerKitSinkDeliveryContext,
    ): Promise<{ link?: string | undefined }> {
      const feedbackId = detail.feedback.id

      // 1. Fast path: already recorded in in-memory map or on feedback.links
      const cachedLink = deliveredByFeedbackId.get(feedbackId)
      if (cachedLink) {
        return { link: cachedLink }
      }
      const existingRepoLink = detail.feedback.links.find((link) =>
        link.toLowerCase().startsWith(repoIssueUrlPrefix),
      )
      if (existingRepoLink) {
        deliveredByFeedbackId.set(feedbackId, existingRepoLink)
        return { link: existingRepoLink }
      }

      // 2. Retry deduplication: if this outbox row has failed at least once before,
      // check whether the prior attempt actually created the issue on GitHub before timing out.
      const priorAttempts = context?.attempts ?? detail.attempts ?? 0
      if (deduplicateOnRetry && priorAttempts > 0) {
        const foundUrl = await findExistingIssueByFeedbackId({
          apiBaseUrl,
          owner,
          repo,
          token,
          feedbackId,
          fetchFn,
          signal: context?.signal,
        })
        if (foundUrl) {
          deliveredByFeedbackId.set(feedbackId, foundUrl)
          return { link: foundUrl }
        }
      }

      // 3. Format and create the GitHub Issue
      const formatted = formatGitHubIssue(detail, {
        staticLabels: options.labels,
        includeDynamicLabels: options.includeDynamicLabels,
      })

      const createEndpoint = `${apiBaseUrl}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues`
      const requestPayload: Record<string, unknown> = {
        title: formatted.title,
        body: formatted.body,
        labels: formatted.labels,
      }
      if (assignees && assignees.length > 0) {
        requestPayload.assignees = assignees
      }

      let response: Response
      try {
        response = await fetchFn(createEndpoint, {
          method: 'POST',
          headers: {
            accept: 'application/vnd.github+json',
            authorization: `Bearer ${token}`,
            'content-type': 'application/json',
            'user-agent': 'hollerkit-server/1',
            'x-github-api-version': '2022-11-28',
          },
          body: JSON.stringify(requestPayload),
          signal: context?.signal ?? null,
        })
      } catch (error) {
        const reason = error instanceof Error ? error.message : 'network error'
        throw new HollerKitError(
          502,
          'github_sink_error',
          `GitHub Issues request failed: ${reason}`,
        )
      }

      if (!response.ok) {
        let errorSnippet = ''
        try {
          const text = await response.text()
          errorSnippet = text ? `: ${text.slice(0, 300)}` : ''
        } catch {
          // ignore body read errors
        }
        throw new HollerKitError(
          502,
          'github_sink_error',
          `GitHub Issues API failed with status ${response.status}${errorSnippet}`,
        )
      }

      let createdIssue: { html_url?: unknown; number?: unknown }
      try {
        createdIssue = (await response.json()) as { html_url?: unknown; number?: unknown }
      } catch {
        throw new HollerKitError(
          502,
          'github_sink_error',
          'GitHub Issues API returned invalid JSON.',
        )
      }

      const htmlUrl =
        typeof createdIssue.html_url === 'string' && createdIssue.html_url.trim().length > 0
          ? createdIssue.html_url.trim()
          : typeof createdIssue.number === 'number'
            ? `https://github.com/${owner}/${repo}/issues/${createdIssue.number}`
            : undefined

      if (!htmlUrl) {
        throw new HollerKitError(
          502,
          'github_sink_error',
          'GitHub Issues API response did not include html_url.',
        )
      }

      deliveredByFeedbackId.set(feedbackId, htmlUrl)
      return { link: htmlUrl }
    },
  }
}

/**
 * Creates a Web Fetch handler that verifies GitHub `issues` webhooks (`X-Hub-Signature-256`)
 * and synchronizes issue close/reopen events back to `hollerkit.triage` and `hollerkit.feedback`.
 */
export function createGitHubWebhookHandler(
  options: GitHubWebhookOptions,
): (request: Request) => Promise<Response> {
  const secret = options.secret?.trim()
  if (!secret) {
    throw new HollerKitError(
      400,
      'invalid_webhook_secret',
      'GitHub webhook secret must be a non-empty string.',
    )
  }
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_WEBHOOK_MAX_BYTES
  const defaultActor = options.actor?.trim() || 'github-webhook'
  const nowFn = options.now ?? (() => new Date())

  return async function gitHubWebhookHandler(request: Request): Promise<Response> {
    try {
      if (request.method.toUpperCase() !== 'POST') {
        throw new HollerKitError(405, 'method_not_allowed', 'Expected POST.')
      }

      const signatureHeader = request.headers.get('x-hub-signature-256')
      if (!signatureHeader) {
        throw new HollerKitError(401, 'unauthorized', 'Missing X-Hub-Signature-256 header.')
      }

      const rawBody = await readBoundedBytes(request, maxBodyBytes)
      const validSignature = await verifyGitHubWebhookSignature(secret, rawBody, signatureHeader)
      if (!validSignature) {
        throw new HollerKitError(401, 'unauthorized', 'Invalid X-Hub-Signature-256 signature.')
      }

      const eventName = (request.headers.get('x-github-event') ?? '').trim().toLowerCase()
      if (eventName === 'ping') {
        return webhookJsonResponse({ ok: true, event: 'ping', pong: true })
      }

      if (eventName !== 'issues') {
        return webhookJsonResponse({
          ok: true,
          event: eventName || 'unknown',
          ignored: true,
          reason: 'unsupported_event',
        })
      }

      let payload: Record<string, unknown>
      try {
        payload = JSON.parse(new TextDecoder().decode(rawBody)) as Record<string, unknown>
      } catch {
        throw new HollerKitError(400, 'invalid_json', 'Webhook body must be valid JSON.')
      }

      const action = typeof payload.action === 'string' ? payload.action.toLowerCase() : ''
      if (action !== 'closed' && action !== 'reopened') {
        return webhookJsonResponse({
          ok: true,
          event: 'issues',
          action,
          ignored: true,
          reason: 'unsupported_action',
        })
      }

      const issue =
        typeof payload.issue === 'object' && payload.issue !== null
          ? (payload.issue as Record<string, unknown>)
          : null
      const issueBody = typeof issue?.body === 'string' ? issue.body : null
      const feedbackId = extractFeedbackIdFromGitHubIssueBody(issueBody)
      if (!feedbackId) {
        return webhookJsonResponse({
          ok: true,
          event: 'issues',
          action,
          ignored: true,
          reason: 'no_feedback_id',
        })
      }

      let existing = await options.store.getFeedbackById(feedbackId)
      if (!existing) {
        return webhookJsonResponse({
          ok: true,
          event: 'issues',
          action,
          feedbackId,
          ignored: true,
          reason: 'feedback_not_found',
        })
      }

      const issueNumber = typeof issue?.number === 'number' ? issue.number : null
      const issueUrl =
        typeof issue?.html_url === 'string' && issue.html_url.trim().length > 0
          ? issue.html_url.trim()
          : null

      if (!issueUrl) {
        return webhookJsonResponse({
          ok: true,
          event: 'issues',
          action,
          feedbackId,
          ignored: true,
          reason: 'missing_issue_url',
        })
      }

      // Verify that the webhook's issue `html_url` matches a trusted issue link recorded on `feedback.links`.
      // If `feedback.links` does not yet have a GitHub issue link (e.g. outbox delivery still pending),
      // invoke `reconcileFeedbackOutbox` first so legitimate early events are reconciled rather than lost.
      if (!hasMatchingIssueLink(existing.feedback.links, issueUrl)) {
        if (!hasAnyGitHubIssueLink(existing.feedback.links) && options.reconcileFeedbackOutbox) {
          await options.reconcileFeedbackOutbox(feedbackId)
          existing = await options.store.getFeedbackById(feedbackId)
          if (!existing) {
            return webhookJsonResponse({
              ok: true,
              event: 'issues',
              action,
              feedbackId,
              ignored: true,
              reason: 'feedback_not_found',
            })
          }
        }

        if (!hasMatchingIssueLink(existing.feedback.links, issueUrl)) {
          if (!hasAnyGitHubIssueLink(existing.feedback.links)) {
            throw new HollerKitError(
              409,
              'issue_link_pending',
              'Feedback item does not yet have a recorded GitHub issue link; retry after outbox delivery.',
            )
          }
          return webhookJsonResponse({
            ok: true,
            event: 'issues',
            action,
            feedbackId,
            ignored: true,
            reason: 'untrusted_issue_link',
          })
        }
      }

      const stateReason =
        typeof issue?.state_reason === 'string' ? issue.state_reason.toLowerCase() : null
      const sender =
        typeof payload.sender === 'object' && payload.sender !== null
          ? (payload.sender as Record<string, unknown>)
          : null
      const senderLogin =
        typeof sender?.login === 'string' && sender.login.trim().length > 0
          ? `github:${sender.login.trim()}`
          : defaultActor

      const status: TriageStatus =
        action === 'reopened'
          ? 'triaged'
          : stateReason === 'not_planned'
            ? 'wontfix'
            : stateReason === 'duplicate'
              ? 'duplicate'
              : 'resolved'

      const issueRef = issueNumber !== null ? `GitHub Issue #${issueNumber}` : 'GitHub Issue'
      const summary =
        action === 'reopened'
          ? `Reopened via ${issueRef}.`
          : `Closed (${stateReason ?? 'completed'}) via ${issueRef}.`

      const mergedLinks = [...existing.feedback.links]
      if (!mergedLinks.includes(issueUrl)) {
        mergedLinks.push(issueUrl)
      }

      const updated = await options.store.triageFeedback({
        feedbackId,
        status,
        summary,
        links: mergedLinks,
        actor: senderLogin,
        now: nowFn(),
      })

      return webhookJsonResponse({
        ok: true,
        event: 'issues',
        action,
        feedbackId,
        triageStatus: updated.feedback.triageStatus,
        triage: updated.triage,
      })
    } catch (error) {
      if (error instanceof HollerKitError) {
        return webhookJsonResponse(
          { ok: false, error: { code: error.code, message: error.message } },
          error.status,
        )
      }
      return webhookJsonResponse(
        { ok: false, error: { code: 'internal_error', message: 'Unexpected webhook error.' } },
        500,
      )
    }
  }
}

/**
 * Verifies a GitHub `X-Hub-Signature-256` (`sha256=<hex>`) header against the raw request payload.
 */
export async function verifyGitHubWebhookSignature(
  secret: string,
  payloadBytes: Uint8Array,
  signatureHeader: string,
): Promise<boolean> {
  const match = signatureHeader.trim().match(SHA256_SIGNATURE_REGEX)
  if (!match?.[1]) return false

  const signatureBytes = hexToBytes(match[1])
  const secretBytes = new TextEncoder().encode(secret)
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    bufferSource(secretBytes),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )

  return crypto.subtle.verify(
    'HMAC',
    cryptoKey,
    bufferSource(signatureBytes),
    bufferSource(payloadBytes),
  )
}

/**
 * Queries GitHub's issue search endpoint for an existing issue containing the feedback's marker.
 */
async function findExistingIssueByFeedbackId(params: {
  apiBaseUrl: string
  owner: string
  repo: string
  token: string
  feedbackId: string
  fetchFn: typeof globalThis.fetch
  signal?: AbortSignal | undefined
}): Promise<string | null> {
  const query = `repo:${params.owner}/${params.repo} is:issue "hollerkit-feedback-id: ${params.feedbackId}" in:body`
  const searchUrl = `${params.apiBaseUrl}/search/issues?q=${encodeURIComponent(query)}&per_page=1`
  try {
    const response = await params.fetchFn(searchUrl, {
      method: 'GET',
      headers: {
        accept: 'application/vnd.github+json',
        authorization: `Bearer ${params.token}`,
        'user-agent': 'hollerkit-server/1',
        'x-github-api-version': '2022-11-28',
      },
      signal: params.signal ?? null,
    })
    if (!response.ok) return null
    const data = (await response.json()) as {
      items?: Array<{ html_url?: unknown }>
    }
    const firstUrl = data.items?.[0]?.html_url
    return typeof firstUrl === 'string' && firstUrl.trim().length > 0 ? firstUrl.trim() : null
  } catch {
    return null
  }
}

/**
 * Checks whether a feedback item's `links` array contains the given GitHub issue URL.
 */
function hasMatchingIssueLink(links: ReadonlyArray<string>, candidateIssueUrl: string): boolean {
  const normalizedCandidate = normalizeIssueUrl(candidateIssueUrl)
  return links.some((link) => normalizeIssueUrl(link) === normalizedCandidate)
}

/**
 * Checks whether a feedback item's `links` array already contains at least one GitHub issue link.
 */
function hasAnyGitHubIssueLink(links: ReadonlyArray<string>): boolean {
  return links.some((link) => /\/issues\/\d+(?:$|[/?#])/i.test(link))
}

/**
 * Normalizes a GitHub issue URL for case-insensitive comparison.
 */
function normalizeIssueUrl(url: string): string {
  return url.trim().replace(/\/+$/, '').toLowerCase()
}

/**
 * Constructs a concise GitHub Issue title from a feedback record and optional quest title.
 */
function buildIssueTitle(
  feedback: FeedbackRecord,
  questTitle: string | null,
  summarySnippet: string | null,
): string {
  if (feedback.kind === 'quest_run') {
    const outcomeLabel =
      feedback.result === 'fail'
        ? 'Quest Failed'
        : feedback.result === 'unsure'
          ? 'Quest Unsure'
          : `Quest ${feedback.result ?? 'Run'}`
    const targetName = questTitle ?? feedback.questId ?? 'Quest'
    if (summarySnippet) {
      return `[${outcomeLabel}: ${targetName}] ${summarySnippet}`
    }
    return `[${outcomeLabel}] ${targetName} (build ${feedback.build})`
  }

  const areaPrefix = feedback.area ? `[Bug Report: ${feedback.area}]` : '[Bug Report]'
  if (summarySnippet) {
    return `${areaPrefix} ${summarySnippet}`
  }
  return `${areaPrefix} Feedback on build ${feedback.build}`
}

/**
 * Extracts the first non-empty line of a comment or transcript, truncated to `maxChars`.
 */
function extractHeadlineSnippet(text: string | null | undefined, maxChars = 80): string | null {
  if (!text) return null
  const firstLine = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0)
  if (!firstLine) return null
  if (firstLine.length <= maxChars) return firstLine
  return `${firstLine.slice(0, maxChars - 1).trimEnd()}…`
}

/**
 * Escapes HTML comment delimiters in user-provided markdown text so it cannot spoof HollerKit markers.
 */
function escapeUserMarkdown(value: string): string {
  return value.replace(/<!--/g, '&lt;!--').replace(/-->/g, '--&gt;')
}

/**
 * Escapes newlines, pipes, and HTML comment markers inside a Markdown table cell.
 */
function escapeTableCell(value: string): string {
  return escapeUserMarkdown(value).replace(/\r?\n/g, ' ').replace(/\|/g, '\\|')
}

/**
 * Escapes backticks, newlines, and HTML comment markers inside inline Markdown code spans.
 */
function escapeInlineCode(value: string): string {
  return escapeUserMarkdown(value).replace(/`/g, "'").replace(/\r?\n/g, ' ')
}

/**
 * Escapes `--` and `>` inside JSON embedded in an HTML comment.
 */
function escapeHtmlCommentJson(json: string): string {
  return json.replace(/--/g, '\\u002d\\u002d').replace(/>/g, '\\u003e')
}

/**
 * Reads a request body into a `Uint8Array`, enforcing `maxBytes`.
 */
async function readBoundedBytes(request: Request, maxBytes: number): Promise<Uint8Array> {
  const contentLengthHeader = request.headers.get('content-length')
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader)
    if (!Number.isInteger(contentLength) || contentLength < 0) {
      throw new HollerKitError(400, 'invalid_content_length', 'Content-Length must be a non-negative integer.')
    }
    if (contentLength > maxBytes) {
      throw new HollerKitError(413, 'body_too_large', 'Webhook payload exceeds maximum byte limit.')
    }
  }

  if (!request.body) {
    return new Uint8Array(0)
  }

  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let totalBytes = 0

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      totalBytes += value.byteLength
      if (totalBytes > maxBytes) {
        await reader.cancel()
        throw new HollerKitError(413, 'body_too_large', 'Webhook payload exceeds maximum byte limit.')
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }

  const merged = new Uint8Array(totalBytes)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return merged
}

/**
 * Decodes an even-length hexadecimal string into a `Uint8Array`.
 */
function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16)
  }
  return bytes
}

/**
 * Extracts a standalone `ArrayBuffer` slice from a `Uint8Array` for Web Crypto calls.
 */
function bufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

/**
 * Builds a JSON `Response` with the `hollerkit-protocol: 1` header.
 */
function webhookJsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      'hollerkit-protocol': '1',
    },
  })
}
