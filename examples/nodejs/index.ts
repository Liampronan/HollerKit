import { createServer } from 'node:http'
import {
  createBugReportHandler,
  githubIssues,
  s3Storage,
} from 'hollerkit-server'

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
