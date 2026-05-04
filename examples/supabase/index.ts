import {
  createBugReportHandler,
  dispatchers,
  githubIssues,
  supabaseStorage,
} from 'npm:hollerkit-server'

Deno.serve(createBugReportHandler({
  appSecret: Deno.env.get('HOLLERKIT_APP_SECRET')!,
  issue: githubIssues({
    token: Deno.env.get('GITHUB_TOKEN')!,
    repo: Deno.env.get('GITHUB_REPO')!,
    labels: ['user-report'],
  }),
  storage: supabaseStorage({
    url: Deno.env.get('SUPABASE_URL')!,
    serviceRoleKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    bucket: Deno.env.get('SUPABASE_BUCKET') ?? 'bug-report-assets',
  }),
  dispatch: {
    when: { allowlist: (Deno.env.get('AGENT_ALLOWLIST') ?? '').split(',').filter(Boolean) },
    handler: dispatchers.comment({
      template: (report) => `@codex please investigate this bug. Report ID: ${report.id}`,
    }),
  },
}))
