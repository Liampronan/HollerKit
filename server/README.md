# `hollerkit-server` (`server/`)

`hollerkit-server` is a lightweight HTTP handler and CLI for storing HollerKit bug reports, screenshots, and QA quests. It uses standard Web `Request` / `Response` APIs and runs on **Supabase Edge Functions** or **Node.js 22+**.

---

## 1. Set Up Postgres & Object Storage

### Apply the Database Migration

Copy `001_hollerkit_v1.sql` into your project and run it against your Postgres database to create the `hollerkit` schema:

```sh
# 1. Copy the SQL migration into your repo
# (or from a local checkout: `cd server && npm ci && npm run build && node ./dist/cli.js migrations copy ./supabase/migrations`)
npx hollerkit-server migrations copy ./supabase/migrations

# 2. Apply it to your database
supabase db push
# If your project already has later-timestamped migrations, check `supabase migration list`
# first and run `supabase db push --include-all` (or `psql "$DATABASE_URL" -f ./supabase/migrations/001_hollerkit_v1.sql`).
```

### Create a Private Storage Bucket

Create a **private** bucket named `hollerkit` (or matching `HOLLERKIT_BUCKET`) in Supabase Storage or S3. Screenshots are uploaded and read exclusively through short-lived presigned URLs.

### Add Authorized Testers

By default, `supabaseJwt({ store })` verifies that the tester's JWT `sub` exists as an active row in `hollerkit.testers`:

```sql
INSERT INTO hollerkit.testers (user_id, email, active)
VALUES ('<tester-jwt-sub>', 'tester@example.com', true)
ON CONFLICT (user_id) DO UPDATE SET active = true;
```

---

## 2. Deploy the Server

### Option A: Supabase Edge Functions

Because Supabase reserves the `SUPABASE_` prefix for built-in Edge Function environment variables, configure your Supavisor transaction-pooler connection string as `HOLLERKIT_DB_POOLER_URL` (and if your project uses legacy HS256 JWTs, set `HOLLERKIT_JWT_SECRET`):

```sh
supabase secrets set HOLLERKIT_DB_POOLER_URL="postgresql://..."
# Optional (only needed for projects using legacy HS256 JWT signing):
supabase secrets set HOLLERKIT_JWT_SECRET="your-jwt-secret"
```

See [`examples/supabase/functions/hollerkit/index.ts`](../examples/supabase/functions/hollerkit/index.ts), [`examples/supabase/index.ts`](../examples/supabase/index.ts), and [`examples/supabase/config.toml`](../examples/supabase/config.toml):

```ts
import {
  apiKeys,
  createHollerKitServer,
  postgresStore,
  supabaseJwt,
  supabaseStorage,
} from 'npm:hollerkit-server'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const store = postgresStore({
  url: Deno.env.get('HOLLERKIT_DB_POOLER_URL')!,
  max: 2,
  prepare: false, // Required for Supabase Supavisor transaction pooling
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
        secret: Deno.env.get('HOLLERKIT_JWT_SECRET'),
        store,
      }),
      apiKeys({ store }),
    ],
  }),
)
```

Disable Supabase's built-in gateway JWT verification on the `hollerkit` function in `supabase/config.toml` (or deploy with `--no-verify-jwt`) so both tester JWTs and `hk_...` API keys reach HollerKit's authenticator:

```toml
[functions.hollerkit]
verify_jwt = false
```

### Option B: Node.js + S3

See [`examples/nodejs/index.ts`](../examples/nodejs/index.ts) for a standalone Node.js HTTP server backed by Postgres and S3-compatible object storage.

### Optional: GitHub Issues Sink & Two-Way Webhook Sync

To automatically create a GitHub Issue for every bug report and failed/unsure quest run—and automatically mark the feedback item as `resolved` (or `wontfix` / `duplicate`) when the GitHub Issue closes—set:

```sh
supabase secrets set \
  HOLLERKIT_GITHUB_REPO="owner/repo" \
  HOLLERKIT_GITHUB_TOKEN="ghp_..." \
  HOLLERKIT_GITHUB_WEBHOOK_SECRET="your-webhook-secret"
```

- **Outgoing (`githubIssuesSink`)**: Formats tester notes, voice transcripts, quest checklists, timeline breadcrumbs, and 7-day signed media links into a GitHub Issue and stores the created issue URL on `hollerkit.feedback.links`.
- **Incoming (`POST /v1/webhooks/github`)**: Point a GitHub repository webhook (`Issues` events, `application/json`) at `<your-server>/v1/webhooks/github` with `HOLLERKIT_GITHUB_WEBHOOK_SECRET`. Closing or reopening the GitHub Issue updates `hollerkit.triage` and `hollerkit.feedback.triage_status` automatically so fixed quests return to `pending` on the iOS Quest Board.

---

## 3. CLI Reference

`hollerkit-server` includes a CLI for managing quests, API keys, migrations, and server conformance checks:

```sh
# Validate hollerkit-quests.json in CI
npx hollerkit-server quests validate ./hollerkit-quests.json

# Sync quests to your server on merge to main
npx hollerkit-server quests sync ./hollerkit-quests.json \
  --server https://your-project.supabase.co/functions/v1/hollerkit \
  --key "$HOLLERKIT_QUESTS_WRITE_KEY" \
  --sha "$GITHUB_SHA"

# Create a scoped hk_ API key (scopes: quests:write, agent:read, agent:triage)
npx hollerkit-server keys create \
  --db "$DATABASE_URL" \
  --scopes agent:read,agent:triage \
  --label "cursor-agent"

# Revoke an API key by prefix, SHA-256 hash, or label
npx hollerkit-server keys revoke --db "$DATABASE_URL" hk_a1b2c3d4e

# Run the end-to-end /v1 conformance test suite (use an isolated, disposable test
# server and database — conformance syncs fixture quests and retires active quests)
npx hollerkit-server conformance \
  --server http://127.0.0.1:3000 \
  --tester-token "$TESTER_TOKEN" \
  --quests-key "$QUESTS_KEY" \
  --agent-key "$AGENT_KEY"

# Copy SQL migrations into your project
npx hollerkit-server migrations copy ./migrations

# Manually flush pending outbox deliveries to GitHub Issues
npx hollerkit-server outbox flush \
  --db "$DATABASE_URL" \
  --github-repo "owner/repo" \
  --github-token "$GITHUB_TOKEN"
```
