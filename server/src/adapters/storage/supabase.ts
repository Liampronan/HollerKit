import type { ReportFile, StorageAdapter, UploadedFile } from '../../types.ts'

export type SupabaseStorageOptions = {
  url: string
  serviceRoleKey: string
  bucket: string
  prefix?: string
  publicUrl?: (path: string) => string
}

export function supabaseStorage(options: SupabaseStorageOptions): StorageAdapter {
  const baseUrl = options.url.replace(/\/$/, '')

  return {
    async upload(reportId: string, files: ReportFile[]): Promise<UploadedFile[]> {
      const uploaded: UploadedFile[] = []

      for (const file of files) {
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
          throw new Error(`Supabase storage upload failed with ${response.status}: ${await response.text()}`)
        }

        uploaded.push({
          kind: file.kind,
          filename: file.filename,
          mimeType: file.mimeType,
          size: file.size,
          url: options.publicUrl
            ? options.publicUrl(path)
            : `${baseUrl}/storage/v1/object/public/${options.bucket}/${encodePath(path)}`,
        })
      }

      return uploaded
    },
  }
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
