import { createServer } from 'node:http'
import {
  apiKeys,
  createHollerKitServer,
  defaultV1Limits,
  postgresStore,
  s3Storage,
  supabaseJwt,
} from 'hollerkit-server'

const store = postgresStore({
  url: process.env.DATABASE_URL!,
})

const storage = s3Storage({
  endpoint: process.env.S3_ENDPOINT!,
  bucket: process.env.S3_BUCKET!,
  accessKeyId: process.env.S3_ACCESS_KEY_ID!,
  secretAccessKey: process.env.S3_SECRET_ACCESS_KEY!,
})

const handler = createHollerKitServer({
  store,
  storage,
  authenticate: [
    supabaseJwt({
      jwksUrl: process.env.SUPABASE_JWKS_URL,
      secret: process.env.SUPABASE_JWT_SECRET,
      store,
    }),
    apiKeys({ store }),
  ],
})

createServer(async (incoming, outgoing) => {
  const contentLength = Number(incoming.headers['content-length'] ?? 0)
  if (contentLength > defaultV1Limits.maxJsonBytes) {
    outgoing.writeHead(413, {
      'content-type': 'application/json',
      'hollerkit-protocol': '1',
    })
    outgoing.end(JSON.stringify({ ok: false, error: { code: 'body_too_large', message: 'Payload too large.' } }))
    return
  }

  const request = new Request(`http://localhost${incoming.url}`, {
    method: incoming.method,
    headers: incoming.headers as HeadersInit,
    body: incoming.method === 'GET' || incoming.method === 'HEAD' ? undefined : incoming,
    duplex: 'half',
  } as RequestInit)
  const response = await handler(request)

  outgoing.writeHead(response.status, Object.fromEntries(response.headers.entries()))
  outgoing.end(Buffer.from(await response.arrayBuffer()))
}).listen(3000)
