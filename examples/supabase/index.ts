import {
  apiKeys,
  createHollerKitServer,
  postgresStore,
  supabaseJwt,
  supabaseStorage,
} from 'npm:hollerkit-server'

/**
 * Reads a required Deno environment variable or throws an error naming the missing variable.
 */
function requireEnv(name: string, fallbackName?: string): string {
  const value = (Deno.env.get(name) ?? (fallbackName ? Deno.env.get(fallbackName) : undefined))?.trim()
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value
}

const supabaseUrl = requireEnv('SUPABASE_URL')
const poolerDbUrl = requireEnv('HOLLERKIT_DB_POOLER_URL', 'SUPABASE_DB_POOLER_URL')
const serviceRoleKey = requireEnv('SUPABASE_SERVICE_ROLE_KEY')

const store = postgresStore({
  url: poolerDbUrl,
  max: 2,
  prepare: false,
  idleTimeout: 5,
  maxLifetime: 600,
})

const storage = supabaseStorage({
  url: supabaseUrl,
  serviceRoleKey,
  bucket: Deno.env.get('HOLLERKIT_BUCKET') ?? 'hollerkit',
})

Deno.serve(
  createHollerKitServer({
    store,
    storage,
    authenticate: [
      supabaseJwt({
        jwksUrl: `${supabaseUrl}/auth/v1/.well-known/jwks.json`,
        secret: Deno.env.get('HOLLERKIT_JWT_SECRET') ?? Deno.env.get('SUPABASE_JWT_SECRET'),
        store,
      }),
      apiKeys({ store }),
    ],
  }),
)
