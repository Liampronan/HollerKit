# `hollerkit-mcp` (`mcp/`)

`hollerkit-mcp` is a Model Context Protocol (MCP) server that lets coding agents (Claude Code, Cursor, Codex, etc.) read bug reports, inspect screenshots, triage issues, and retire completed QA quests.

---

## 1. Create an Agent API Key

Use the `hollerkit-server` CLI to create an API key with `agent:read` and `agent:triage` scopes:

```sh
npx hollerkit-server keys create \
  --db "$DATABASE_URL" \
  --scopes agent:read,agent:triage \
  --label "coding-agent"
```

---

## 2. Configure Your MCP Client

Add `hollerkit` to your MCP configuration (e.g. `.mcp.json` or Claude Code / Cursor settings):

```json
{
  "mcpServers": {
    "hollerkit": {
      "command": "npx",
      "args": ["-y", "hollerkit-mcp"],
      "env": {
        "HOLLERKIT_URL": "https://your-project.supabase.co/functions/v1/hollerkit",
        "HOLLERKIT_API_KEY": "hk_your_agent_api_key"
      }
    }
  }
}
```

---

## 3. Available MCP Tools

| Tool | Scope | What it does |
| :--- | :--- | :--- |
| `hollerkit_inbox` | `agent:read` | Lists bug reports and quest runs (filterable by `status`, `kind`, `quest_id`, `result`, `build`, or `since`). |
| `hollerkit_get_feedback` | `agent:read` | Fetches full details for a single report or quest run, including breadcrumbs, step marks, and temporary signed screenshot URLs. |
| `hollerkit_triage` | `agent:triage` | Updates an item's status (`open`, `triaged`, `in_progress`, `resolved`, `wontfix`), resolution notes, commit SHA, or issue link. |
| `hollerkit_quests_status` | `agent:read` | Summarizes pass/fail/unsure counts and tester coverage for each active quest. |
| `hollerkit_quests_retire_candidates` | `agent:read` | Lists quests that have passed testing on their current definition with zero failures, ready to be removed from `hollerkit-quests.json`. |
