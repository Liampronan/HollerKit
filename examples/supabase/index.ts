import {
  apiKeys,
  createHollerKitServer,
  postgresStore,
  supabaseJwt,
  supabaseStorage,
} from 'npm:hollerkit-server'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const store = postgresStore({
  url: Deno.env.get('SUPABASE_DB_URL')!,
  prepare: false,
})

const storage = supabaseStorage({
  url: supabaseUrl,
  serviceRoleKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  bucket: Deno.env.get('HOLLERKIT_BUCKET') ?? 'hollerkit',
})

Deno.serve(
  createHollerKitServer({
    store,
    storage,
    authenticate: [
      supabaseJwt({
        jwksUrl: `${supabaseUrl}/auth/v1/.well-known/jwks.json`,
        secret: Deno.env.get('SUPABASE_JWT_SECRET'),
        store,
      }),
      apiKeys({ store }),
    ],
  }),
)
