import assert from 'node:assert/strict'
import test from 'node:test'
import { githubIssues, supabaseStorage } from '../src/index.ts'
import type { NormalizedReport } from '../src/index.ts'

test('GitHub issue titles truncate by grapheme', async () => {
  const originalFetch = globalThis.fetch
  const family = '👨‍👩‍👧‍👦'
  let title: string | undefined

  globalThis.fetch = async (_url, init) => {
    title = JSON.parse(String(init?.body)).title
    return new Response(JSON.stringify({
      html_url: 'https://github.com/acme/app/issues/1',
      number: 1,
    }))
  }

  try {
    await githubIssues({ token: 'token', repo: 'acme/app' }).createIssue({
      report: reportWithComment(family.repeat(100)),
      uploadedFiles: [],
      classify: {},
      body: 'body',
    })
  } finally {
    globalThis.fetch = originalFetch
  }

  assert.equal(title, family.repeat(90))
})

test('Supabase storage errors do not include upstream response bodies', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => new Response('secret/path/details', { status: 500 })

  try {
    const storage = supabaseStorage({
      url: 'https://supabase.example',
      serviceRoleKey: 'service-role-key',
      bucket: 'reports',
      publicUrl: (path) => `https://assets.example/${path}`,
    })

    await assert.rejects(
      storage.upload('report-1', [{
        kind: 'image',
        fieldName: 'image',
        filename: 'screen.png',
        mimeType: 'image/png',
        size: 1,
        data: new Blob(['x'], { type: 'image/png' }),
      }]),
      (error: unknown) => {
        assert.ok(error instanceof Error)
        assert.match(error.message, /Supabase storage upload failed with 500\./)
        assert.doesNotMatch(error.message, /secret\/path\/details/)
        return true
      },
    )
  } finally {
    globalThis.fetch = originalFetch
  }
})

function reportWithComment(comment: string): NormalizedReport {
  return {
    id: 'report-1',
    createdAt: '2026-05-03T20:00:00.000Z',
    inputMode: 'text-only',
    comment,
    metadata: {},
    breadcrumbs: [],
    files: { images: [] },
  }
}
