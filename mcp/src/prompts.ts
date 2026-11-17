import { HollerKitMcpError } from './client.js'
import type {
  HollerKitPromptName,
  McpGetPromptResult,
  McpPromptDefinition,
  ValueGroupBy,
} from './types.js'

const VALID_PROMPT_GROUP_BY = new Set<ValueGroupBy>([
  'build',
  'appVersion',
  'device',
  'os',
  'version',
  'label',
])

export const HOLLERKIT_MCP_PROMPTS: readonly McpPromptDefinition[] = [
  {
    name: 'triage-inbox',
    description:
      'Review untriaged bug reports and failed/unsure QA quest runs in HollerKit, inspect attached screenshots, fix valid issues, and record triage decisions.',
    arguments: [
      {
        name: 'area',
        description: 'Optional feature area filter (e.g. "feed", "camera", "checkout").',
        required: false,
      },
      {
        name: 'build',
        description: 'Optional build identifier filter.',
        required: false,
      },
    ],
  },
  {
    name: 'author-quest',
    description:
      'Draft a guided QA quest definition (with optional breadcrumb telemetry captures) for hollerkit-quests.json covering a new feature or bug fix.',
    arguments: [
      {
        name: 'area',
        description: 'Feature area for the quest (e.g. "checkout", "profile").',
        required: true,
      },
      {
        name: 'summary',
        description: 'Short description of the user flow or change to verify on device.',
        required: true,
      },
      {
        name: 'start',
        description: 'Optional deep-link route to jump testers straight to the flow.',
        required: false,
      },
    ],
  },
  {
    name: 'retire-passed-quests',
    description:
      'Find active QA quests that have passed on their current content version and remove them from hollerkit-quests.json.',
    arguments: [
      {
        name: 'area',
        description: 'Optional feature area filter.',
        required: false,
      },
    ],
  },
  {
    name: 'analyze-values',
    description:
      'Query and analyze measured quest telemetry values (n, median, p90, min, max) across builds or devices.',
    arguments: [
      {
        name: 'quest',
        description: 'Quest ID to query measurements for.',
        required: true,
      },
      {
        name: 'label',
        description: 'Capture or answer label to aggregate.',
        required: false,
      },
      {
        name: 'groupBy',
        description: 'Optional grouping dimension ("build", "appVersion", "device", "os", "version", "label").',
        required: false,
      },
    ],
  },
]

/**
 * Resolves a HollerKit MCP prompt by name and validates its string arguments.
 */
export function resolveHollerKitPrompt(
  name: string,
  rawArgs?: Record<string, unknown> | undefined,
): McpGetPromptResult {
  const promptDef = HOLLERKIT_MCP_PROMPTS.find((p) => p.name === name)
  if (!promptDef) {
    throw new HollerKitMcpError(404, 'unknown_prompt', `Unknown MCP prompt: ${name}.`)
  }

  const args: Record<string, string> = {}
  if (rawArgs !== undefined) {
    if (typeof rawArgs !== 'object' || rawArgs === null || Array.isArray(rawArgs)) {
      throw new HollerKitMcpError(
        400,
        'invalid_arguments',
        `Arguments for prompt "${name}" must be a JSON object.`,
      )
    }
    const allowedNames = new Set((promptDef.arguments ?? []).map((a) => a.name))
    for (const [key, value] of Object.entries(rawArgs)) {
      if (!allowedNames.has(key)) {
        throw new HollerKitMcpError(
          400,
          'invalid_arguments',
          `Unknown argument "${key}" for prompt "${name}".`,
        )
      }
      if (value === undefined || value === null) continue
      if (typeof value !== 'string') {
        throw new HollerKitMcpError(
          400,
          'invalid_arguments',
          `Argument "${key}" for prompt "${name}" must be a string.`,
        )
      }
      const trimmed = value.trim()
      if (trimmed.length > 0) {
        args[key] = trimmed
      }
    }
  }

  for (const argDef of promptDef.arguments ?? []) {
    if (argDef.required && !args[argDef.name]) {
      throw new HollerKitMcpError(
        400,
        'invalid_arguments',
        `Missing required argument "${argDef.name}" for prompt "${name}".`,
      )
    }
  }

  return buildPromptMessages(promptDef.name, promptDef.description, args)
}

function buildPromptMessages(
  name: HollerKitPromptName,
  description: string,
  args: Record<string, string>,
): McpGetPromptResult {
  switch (name) {
    case 'triage-inbox': {
      const filters: string[] = ['triage="new"']
      if (args.area) filters.push(`area=${JSON.stringify(args.area)}`)
      if (args.build) filters.push(`build=${JSON.stringify(args.build)}`)
      return {
        description,
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text: [
                `Triage the HollerKit feedback inbox (${filters.join(', ')}):`,
                '1. Call `feedback_inbox` with the filter parameters above.',
                '2. For each untriaged report or failed/unsure quest run, call `feedback_get` to inspect the timeline events, measured capture flags, and attached screenshot URLs.',
                '3. Cross-reference the reported symptom against the codebase. If you identify the root cause, implement a minimal fix and verify tests pass.',
                '4. Call `feedback_triage` with `id`, `status` ("resolved", "triaged", "wontfix", or "duplicate"), and a concise `summary` explaining the root cause or fix.',
              ].join('\n'),
            },
          },
        ],
      }
    }

    case 'author-quest': {
      const area = args.area!
      const summary = args.summary!
      const startHint = args.start
        ? `Include \`"start": ${JSON.stringify(args.start)}\` so tapping Start Quest deep-links directly into the screen.`
        : 'If the app supports deep-link routing for this screen, populate `"start"` with the route URI.'
      return {
        description,
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text: [
                `Author a new guided QA quest in \`hollerkit-quests.json\` for area "${area}":`,
                `Flow to verify: ${summary}`,
                '',
                'Guidelines:',
                '- Use a kebab-case `id` prefixed with the area (e.g. `' + `${area}-...` + '`).',
                '- Keep `setup` (optional prerequisites), `steps` (2-4 concrete actions), and `expect` (observable outcomes on device) concise.',
                `- ${startHint}`,
                '- Set `record` to `"optional"`, `"suggested"`, or `"required"` depending on whether visual mark capture is needed.',
                '- If the code emits timed spans (`HollerKit.begin(...)`) or structured breadcrumbs (`HollerKit.breadcrumb(..., fields: ...)`), add a `capture` array with `{ "event", "value", "unit", "label", "min", "max" }` to automatically verify latency or metric thresholds.',
                '- Validate the updated manifest with `npx hollerkit-server quests validate hollerkit-quests.json`.',
              ].join('\n'),
            },
          },
        ],
      }
    }

    case 'retire-passed-quests': {
      const areaFilter = args.area ? ` with \`area: ${JSON.stringify(args.area)}\`` : ''
      return {
        description,
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text: [
                `Retire completed QA quests from \`hollerkit-quests.json\`:`,
                `1. Call \`quests_retirable\`${areaFilter} to list active quests that have at least one passing run on their current content version.`,
                '2. Check `counts.fail` and `counts.unsure` on each returned quest. If a quest has unresolved failures, inspect them via `feedback_inbox` before retiring.',
                '3. Run `npx hollerkit-server quests validate hollerkit-quests.json` to compute the local canonical content hash for each quest in `hollerkit-quests.json`, and remove an entry only if its local canonical content hash matches the returned `contentHash` (preserve any entry whose functional content has changed since verification).',
                '4. Re-run `npx hollerkit-server quests validate hollerkit-quests.json` to confirm the updated manifest is valid.',
              ].join('\n'),
            },
          },
        ],
      }
    }

    case 'analyze-values': {
      const quest = args.quest!
      const queryParts = [`quest: ${JSON.stringify(quest)}`]
      if (args.label) queryParts.push(`label: ${JSON.stringify(args.label)}`)
      if (args.groupBy) {
        if (!VALID_PROMPT_GROUP_BY.has(args.groupBy as ValueGroupBy)) {
          throw new HollerKitMcpError(
            400,
            'invalid_arguments',
            'groupBy must be one of build, appVersion, device, os, version, label.',
          )
        }
        queryParts.push(`groupBy: ${JSON.stringify(args.groupBy)}`)
      }
      return {
        description,
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text: [
                `Analyze measured telemetry captures for quest "${quest}":`,
                `1. Call \`values_query\` with \`{ ${queryParts.join(', ')} }\`.`,
                '2. Inspect `summary` (`n`, `median`, `p90`, `min`, `max`, `unit`), `groups`, and any `out_of_range` / `above_max` / `below_min` flags in `values`.',
                '3. Summarize performance trends or regressions across builds/devices and highlight any runs that violated capture thresholds.',
              ].join('\n'),
            },
          },
        ],
      }
    }
  }
}
