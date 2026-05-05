import type { ReportFile, StorageAdapter, UploadedFile } from '../../types.js'

export type SupabaseStorageOptions = {
  url: string
  serviceRoleKey: string
  bucket: string
  prefix?: string
  publicUrl?: (path: string) => string
  signedUrlExpiresInSeconds?: number
}

export function supabaseStorage(options: SupabaseStorageOptions): StorageAdapter {
  const baseUrl = options.url.replace(/\/$/, '')
  if (!options.publicUrl && options.signedUrlExpiresInSeconds == null) {
    throw new Error('Supabase storage requires publicUrl or signedUrlExpiresInSeconds for GitHub issue links.')
  }

  return {
    async upload(reportId: string, files: ReportFile[]): Promise<UploadedFile[]> {
      return Promise.all(files.map(async (file) => {
        const path = objectPath(options.prefix, reportId, file)
        const response = await fetch(`${baseUrl}/storage/v1/object/${options.bucket}/${encodePath(path)}`, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${options.serviceRoleKey}`,
            apikey: options.serviceRoleKey,
            'content-type': file.mimeType,
            'x-upsert': 'false',
          },
          body: file.data,
        })

        if (!response.ok) {
          throw new Error(`Supabase storage upload failed with ${response.status}.`)
        }

        return {
          kind: file.kind,
          filename: file.filename,
          mimeType: file.mimeType,
          size: file.size,
          url: await resolveUrl(baseUrl, options, path),
        }
      }))
    },
  }
}

async function resolveUrl(baseUrl: string, options: SupabaseStorageOptions, path: string): Promise<string> {
  if (options.publicUrl) return options.publicUrl(path)
  if (options.signedUrlExpiresInSeconds != null) {
    return createSignedUrl(baseUrl, options, path)
  }

  throw new Error('Supabase storage requires publicUrl or signedUrlExpiresInSeconds for GitHub issue links.')
}

async function createSignedUrl(baseUrl: string, options: SupabaseStorageOptions, path: string): Promise<string> {
  const response = await fetch(`${baseUrl}/storage/v1/object/sign/${options.bucket}/${encodePath(path)}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${options.serviceRoleKey}`,
      apikey: options.serviceRoleKey,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ expiresIn: options.signedUrlExpiresInSeconds }),
  })

  if (!response.ok) {
    throw new Error(`Supabase signed URL creation failed with ${response.status}.`)
  }

  const payload = await response.json() as { signedURL?: string; signedUrl?: string }
  const signedPath = payload.signedURL ?? payload.signedUrl
  if (!signedPath) {
    throw new Error('Supabase signed URL response did not include signedURL.')
  }

  return signedPath.startsWith('http') ? signedPath : `${baseUrl}${signedPath}`
}

function objectPath(prefix: string | undefined, reportId: string, file: ReportFile): string {
  return [prefix, reportId, sanitizeFilename(file.filename)].filter(Boolean).join('/')
}

function sanitizeFilename(filename: string): string {
  return filename.replace(/[^a-zA-Z0-9._-]/g, '_')
}

function encodePath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/')
}
