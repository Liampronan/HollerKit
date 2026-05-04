import { createServer } from 'node:http'
import {
  createBugReportHandler,
  githubIssues,
  s3Storage,
} from 'hollerkit-server'

const maxBodyBytes = 45_000_000
const handler = createBugReportHandler({
  appSecret: process.env.HOLLERKIT_APP_SECRET!,
  issue: githubIssues({
    token: process.env.GITHUB_TOKEN!,
    repo: process.env.GITHUB_REPO!,
    labels: ['user-report'],
  }),
  storage: s3Storage({
    endpoint: process.env.S3_ENDPOINT!,
    bucket: process.env.S3_BUCKET!,
    accessKeyId: process.env.S3_ACCESS_KEY_ID!,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY!,
  }),
})

createServer(async (incoming, outgoing) => {
  const contentLength = Number(incoming.headers['content-length'] ?? 0)
  if (contentLength > maxBodyBytes) {
    outgoing.writeHead(413, { 'content-type': 'application/json' })
    outgoing.end(JSON.stringify({ ok: false, error: { code: 'body_too_large' } }))
    return
  }

  const request = new Request(`http://localhost${incoming.url}`, {
    method: incoming.method,
    headers: incoming.headers as HeadersInit,
    body: incoming,
    duplex: 'half',
  } as RequestInit)
  const response = await handler(request)

  outgoing.writeHead(response.status, Object.fromEntries(response.headers.entries()))
  outgoing.end(Buffer.from(await response.arrayBuffer()))
}).listen(3000)
