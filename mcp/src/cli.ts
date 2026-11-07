#!/usr/bin/env node
import { createHollerKitMcpServer, HOLLERKIT_MCP_VERSION } from './server.js'

const args = process.argv.slice(2)

if (args.includes('--help') || args.includes('-h')) {
  process.stdout.write(
    [
      'hollerkit-mcp - HollerKit v1 Model Context Protocol (MCP) stdio server',
      '',
      'Environment variables:',
      '  HOLLERKIT_URL       Base URL of the HollerKit server (e.g. https://project.supabase.co/functions/v1/hollerkit)',
      '  HOLLERKIT_API_KEY   HollerKit API key (hk_...) with agent:read and agent:triage scopes',
      '',
      'Tools exposed:',
      '  - feedback_inbox',
      '  - feedback_get',
      '  - feedback_triage',
      '  - quests_pending',
      '  - quests_retirable',
      '',
    ].join('\n'),
  )
  process.exit(0)
}

if (args.includes('--version') || args.includes('-v')) {
  process.stdout.write(`${HOLLERKIT_MCP_VERSION}\n`)
  process.exit(0)
}

const server = createHollerKitMcpServer()
server.connectStdio(process.stdin, process.stdout)
