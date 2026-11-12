import type { McpToolDefinition } from './types.js'

export const HOLLERKIT_MCP_TOOLS: readonly McpToolDefinition[] = [
  {
    name: 'feedback_inbox',
    description:
      'List HollerKit feedback items (bug reports and quest runs). Defaults to triage="new" when omitted so coding agents see untriaged reports and failed/unsure quest runs.',
    inputSchema: {
      type: 'object',
      properties: {
        kind: {
          type: 'string',
          enum: ['report', 'quest_run'],
          description: 'Filter by feedback kind ("report" or "quest_run").',
        },
        result: {
          type: 'string',
          enum: ['pass', 'fail', 'unsure', 'abandoned'],
          description: 'Filter quest runs by outcome.',
        },
        triage: {
          type: 'string',
          enum: ['new', 'triaged', 'resolved', 'wontfix', 'duplicate', 'all'],
          description:
            'Filter by triage status. Defaults to "new" when omitted. Pass "all" to include all items regardless of triage status.',
        },
        area: {
          type: 'string',
          description: 'Filter by feature area.',
        },
        since: {
          type: 'string',
          description: 'Filter items created at or after this ISO-8601 timestamp.',
        },
        build: {
          type: 'string',
          description: 'Filter by build identifier.',
        },
        questId: {
          type: 'string',
          description: 'Filter by quest ID.',
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: 200,
          description: 'Maximum number of feedback items to return (1-200, default 50).',
        },
        cursor: {
          type: 'string',
          description: 'Pagination cursor returned by a previous feedback_inbox call.',
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'feedback_get',
    description:
      'Get full details for a single feedback item, including its associated quest version, timeline events sorted by offsetSeconds, triage history, and attachments with freshly signed 1-hour read URLs.',
    inputSchema: {
      type: 'object',
      properties: {
        id: {
          type: 'string',
          description: 'UUID of the feedback item to retrieve.',
        },
      },
      required: ['id'],
      additionalProperties: false,
    },
  },
  {
    name: 'feedback_triage',
    description:
      'Record a triage decision on a feedback item. Appends an immutable audit entry to hollerkit.triage and updates the feedback item triage status, summary, and links in one transaction.',
    inputSchema: {
      type: 'object',
      properties: {
        id: {
          type: 'string',
          description: 'UUID of the feedback item to triage.',
        },
        status: {
          type: 'string',
          enum: ['new', 'triaged', 'resolved', 'wontfix', 'duplicate'],
          description: 'New triage status for the feedback item.',
        },
        summary: {
          type: 'string',
          description: 'Root cause summary, fix explanation, or triage notes.',
        },
        links: {
          type: 'array',
          items: { type: 'string' },
          description: 'Optional list of PR, commit, or issue URLs associated with the triage decision.',
        },
        actor: {
          type: 'string',
          description: 'Optional identifier of the agent or engineer recording the triage decision.',
        },
      },
      required: ['id', 'status', 'summary'],
      additionalProperties: false,
    },
  },
  {
    name: 'quests_pending',
    description:
      'List untested active QA quests for a specific build (quests that do not yet have a passing run on their current version).',
    inputSchema: {
      type: 'object',
      properties: {
        build: {
          type: 'string',
          description: 'Build identifier to check for pending quests.',
        },
      },
      required: ['build'],
      additionalProperties: false,
    },
  },
  {
    name: 'quests_retirable',
    description:
      'List active QA quests that have passed on their current content version and are ready to be retired from hollerkit-quests.json in a cleanup PR.',
    inputSchema: {
      type: 'object',
      properties: {
        area: {
          type: 'string',
          description: 'Optional feature area filter.',
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'values_query',
    description:
      'Query aggregated measurements and quest captures across feedback runs and builds, returning n, median, p90, min, max, and optional grouped breakdowns.',
    inputSchema: {
      type: 'object',
      properties: {
        quest: {
          type: 'string',
          description: 'Filter measurements by quest ID.',
        },
        questId: {
          type: 'string',
          description: 'Alias for quest.',
        },
        version: {
          type: 'integer',
          description: 'Filter by specific quest version number.',
        },
        label: {
          type: 'string',
          description: 'Filter measurements by capture or answer label.',
        },
        build: {
          type: 'string',
          description: 'Filter measurements by app build identifier.',
        },
        appVersion: {
          type: 'string',
          description: 'Filter by semantic app version string.',
        },
        device: {
          type: 'string',
          description: 'Filter by device model string.',
        },
        os: {
          type: 'string',
          description: 'Filter by OS version string.',
        },
        source: {
          type: 'string',
          enum: ['capture', 'answer'],
          description: 'Filter by measurement source ("capture" or "answer").',
        },
        since: {
          type: 'string',
          description: 'Filter values created at or after this ISO-8601 timestamp.',
        },
        groupBy: {
          type: 'string',
          enum: ['build', 'appVersion', 'device', 'os', 'version', 'label'],
          description: 'Dimension to group and aggregate statistics by.',
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: 500,
          description: 'Maximum number of raw value records to include (1-500, default 100).',
        },
      },
      additionalProperties: false,
    },
  },
]
