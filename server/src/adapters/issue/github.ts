import type { ClassifyResult, IssueAdapter, NormalizedReport } from '../../types.js'

export type GitHubIssuesOptions = {
  token: string
  repo: string
  labels?: string[]
  title?: (report: NormalizedReport, classify: ClassifyResult) => string
  apiBaseUrl?: string
}

export function githubIssues(options: GitHubIssuesOptions): IssueAdapter {
  const apiBaseUrl = options.apiBaseUrl ?? 'https://api.github.com'
  const issueUrl = `${apiBaseUrl}/repos/${options.repo}/issues`

  return {
    async createIssue(input) {
      const title = options.title
        ? options.title(input.report, input.classify)
        : defaultTitle(input.report, input.classify)

      const labels = [
        ...(options.labels ?? []),
        ...(input.classify.labels ?? []),
        ...(input.classify.severity ? [`severity:${input.classify.severity}`] : []),
      ]

      const response = await githubFetch(issueUrl, options.token, {
        method: 'POST',
        body: JSON.stringify({
          title,
          body: input.body,
          labels: Array.from(new Set(labels)),
        }),
      })
      const payload = await response.json() as { html_url: string; number: number }

      return { url: payload.html_url, number: payload.number }
    },

    async commentIssue(issue, body) {
      requireIssueNumber(issue.number, 'comment')
      await githubFetch(`${issueUrl}/${issue.number}/comments`, options.token, {
        method: 'POST',
        body: JSON.stringify({ body }),
      })
    },

    async addLabels(issue, labels) {
      requireIssueNumber(issue.number, 'label')
      await githubFetch(`${issueUrl}/${issue.number}/labels`, options.token, {
        method: 'POST',
        body: JSON.stringify({ labels }),
      })
    },

    async assign(issue, users) {
      requireIssueNumber(issue.number, 'assign')
      await githubFetch(`${issueUrl}/${issue.number}/assignees`, options.token, {
        method: 'POST',
        body: JSON.stringify({ assignees: users }),
      })
    },
  }
}

async function githubFetch(url: string, token: string, init: RequestInit): Promise<Response> {
  const response = await fetch(url, {
    ...init,
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'x-github-api-version': '2022-11-28',
      ...init.headers,
    },
  })

  if (!response.ok) {
    throw new Error(`GitHub request failed with ${response.status}.`)
  }

  return response
}

function defaultTitle(report: NormalizedReport, classify: ClassifyResult): string {
  const prefix = classify.severity ? `[${classify.severity.toUpperCase()}] ` : ''
  const source = report.comment ?? report.transcript?.text ?? `${report.inputMode} report`
  return `${prefix}${truncateGraphemes(source.replace(/\s+/g, ' '), 90)}`
}

function truncateGraphemes(value: string, maxLength: number): string {
  type SegmenterConstructor = new (
    locales?: string | string[],
    options?: { granularity: 'grapheme' },
  ) => { segment(input: string): Iterable<{ segment: string }> }

  const Segmenter = (Intl as typeof Intl & { Segmenter?: SegmenterConstructor }).Segmenter
  if (!Segmenter) return Array.from(value).slice(0, maxLength).join('')

  let truncated = ''
  let length = 0
  for (const { segment } of new Segmenter(undefined, { granularity: 'grapheme' }).segment(value)) {
    if (length >= maxLength) break
    truncated += segment
    length += 1
  }

  return truncated
}

function requireIssueNumber(number: number | undefined, action: string): asserts number is number {
  if (!number) {
    throw new Error(`Cannot ${action} GitHub issue because the issue number is missing.`)
  }
}
