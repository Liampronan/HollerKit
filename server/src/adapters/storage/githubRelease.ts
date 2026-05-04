import type { ReportFile, StorageAdapter, UploadedFile } from '../../types.ts'

export type GitHubReleaseStorageOptions = {
  token: string
  repo: string
  tagName: string
  releaseName?: string
  apiBaseUrl?: string
  uploadBaseUrl?: string
}

export function githubReleaseStorage(options: GitHubReleaseStorageOptions): StorageAdapter {
  const apiBaseUrl = options.apiBaseUrl ?? 'https://api.github.com'
  const uploadBaseUrl = options.uploadBaseUrl ?? 'https://uploads.github.com'
  let releaseIdPromise: Promise<number> | undefined

  return {
    async upload(reportId: string, files: ReportFile[]): Promise<UploadedFile[]> {
      const releaseId = await (releaseIdPromise ??= ensureRelease(options, apiBaseUrl))
      const uploaded: UploadedFile[] = []

      for (const file of files) {
        const name = `${reportId}-${sanitizeFilename(file.filename)}`
        const response = await fetch(
          `${uploadBaseUrl}/repos/${options.repo}/releases/${releaseId}/assets?name=${encodeURIComponent(name)}`,
          {
            method: 'POST',
            headers: {
              accept: 'application/vnd.github+json',
              authorization: `Bearer ${options.token}`,
              'content-type': file.mimeType,
              'x-github-api-version': '2022-11-28',
            },
            body: file.data,
          },
        )

        if (!response.ok) {
          throw new Error(`GitHub release asset upload failed with ${response.status}: ${await response.text()}`)
        }

        const payload = await response.json() as { browser_download_url: string }
        uploaded.push({
          kind: file.kind,
          filename: file.filename,
          mimeType: file.mimeType,
          size: file.size,
          url: payload.browser_download_url,
        })
      }

      return uploaded
    },
  }
}

async function ensureRelease(options: GitHubReleaseStorageOptions, apiBaseUrl: string): Promise<number> {
  const response = await fetch(`${apiBaseUrl}/repos/${options.repo}/releases/tags/${options.tagName}`, {
    headers: githubHeaders(options.token),
  })

  if (response.ok) {
    return ((await response.json()) as { id: number }).id
  }

  if (response.status !== 404) {
    throw new Error(`GitHub release lookup failed with ${response.status}: ${await response.text()}`)
  }

  const created = await fetch(`${apiBaseUrl}/repos/${options.repo}/releases`, {
    method: 'POST',
    headers: githubHeaders(options.token),
    body: JSON.stringify({
      tag_name: options.tagName,
      name: options.releaseName ?? 'HollerKit report assets',
      draft: false,
      prerelease: true,
    }),
  })

  if (!created.ok) {
    throw new Error(`GitHub release creation failed with ${created.status}: ${await created.text()}`)
  }

  return ((await created.json()) as { id: number }).id
}

function githubHeaders(token: string): Record<string, string> {
  return {
    accept: 'application/vnd.github+json',
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
    'x-github-api-version': '2022-11-28',
  }
}

function sanitizeFilename(filename: string): string {
  return filename.replace(/[^a-zA-Z0-9._-]/g, '_')
}
