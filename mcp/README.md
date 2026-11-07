# `hollerkit-mcp` (`mcp/`)

`hollerkit-mcp` is a Model Context Protocol (MCP) server that lets coding agents (Claude Code, Cursor, Codex, etc.) read bug reports, inspect screenshots, triage issues, and retire completed QA quests.

---

## 1. Build & Create an Agent API Key

From a local checkout of `HollerKit`, build the server CLI and MCP server:

```sh
cd server && npm ci && npm run build
cd ../mcp && npm ci && npm run build
```

Then create an API key with `agent:read` and `agent:triage` scopes:

```sh
node ./server/dist/cli.js keys create \
  --db "$DATABASE_URL" \
  --scopes agent:read,agent:triage \
  --label "coding-agent"
```

---

## 2. Configure Your MCP Client

Point your MCP client at the built `mcp/dist/cli.js` entrypoint (or `npx -y hollerkit-mcp` when installed from npm):

```json
{
  "mcpServers": {
    "hollerkit": {
      "command": "node",
      "args": ["/absolute/path/to/HollerKit/mcp/dist/cli.js"],
      "env": {
        "HOLLERKIT_URL": "https://your-project.supabase.co/functions/v1/hollerkit",
        "HOLLERKIT_API_KEY": "${HOLLERKIT_API_KEY}"
      }
    }
  }
}
```

> **Security note:** Never commit a real `hk_...` key into a shared `.mcp.json` file. Store the key in your shell environment (`${HOLLERKIT_API_KEY}`) or your MCP client's local/user-scoped secret settings.

---

## 3. Available MCP Tools

| Tool | Scope | What it does |
| :--- | :--- | :--- |
| `feedback_inbox` | `agent:read` | Lists bug reports and quest runs. Defaults to `triage="new"`; pass `triage="all"` (with `cursor` pagination) to retrieve all items. Supports filtering by `triage`, `kind`, `result`, `area`, `since`, `build`, `questId`, `limit`, and `cursor`. |
| `feedback_get` | `agent:read` | Fetches full details for a single report or quest run (`id`), including timeline events, triage history, and 1-hour signed screenshot URLs. |
| `feedback_triage` | `agent:triage` | Records a triage decision. Every call requires `id`, `status` (`new`, `triaged`, `resolved`, `wontfix`, or `duplicate`), and a non-empty `summary` (plus optional `links` and `actor`). |
| `quests_pending` | `agent:read` | Lists untested active quests for a given `build` (quests without a passing run on their current version). |
| `quests_retirable` | `agent:read` | Lists active quests that have at least one passing run on their current definition (optional `area` filter). Review any failing runs before removing a quest from `hollerkit-quests.json`. |
