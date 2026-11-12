# HollerKit Protocol v1 (`QUEST_PROTOCOL.md`)

HollerKit `/v1` unifies classic shake-sheet bug reports (`kind = "report"`) and guided QA quest runs (`kind = "quest_run"`) into a single JSON + presigned-upload protocol backed by the `hollerkit` Postgres schema.

For the machine-readable OpenAPI 3.1 contract, see [`quest-protocol.yaml`](./quest-protocol.yaml).

---

## 1. Protocol Versioning & Error Envelope

- Every `/v1/*` response includes the header:
  ```http
  hollerkit-protocol: 1
  ```
- Clients may optionally send `hollerkit-protocol: 1` on requests. If a client sends `hollerkit-protocol` with any value other than `"1"`, the server responds with `400 Bad Request` (`code: "unsupported_protocol"`).
- All error responses use the standard JSON envelope:
  ```json
  {
    "ok": false,
    "error": {
      "code": "error_code",
      "message": "Human-readable explanation."
    }
  }
  ```

---

## 2. Authentication & Scopes

All `/v1/*` endpoints authenticate via `Authorization: Bearer <token>`. Two credential types are supported:

1. **Host-App Tester Session JWT (`tester` scope)**
   - The iOS SDK obtains the current session token from the host app (e.g. a Supabase Auth JWT) and never caches it in Keychain.
   - The server verifies the JWT against the project's JWKS and checks that `sub` exists and is `active = true` in `hollerkit.testers`.
   - Grants scope: `tester`, with `principalId = <user_id>`.

2. **HollerKit API Keys (`hk_...`)**
   - API keys are prefixed with `hk_` (e.g. `hk_live_...`).
   - The server hashes the bearer token with SHA-256 hex and looks up `key_hash` in `hollerkit.api_keys` where `revoked_at IS NULL`.
   - Grants the scopes stored in `hollerkit.api_keys.scopes`:
     - `quests:write`: CI workflow syncing `hollerkit-quests.json` on push to `main` (`PUT /v1/quests`).
     - `agent:read`: Coding agent reading feedback inbox, details, pending quests, and retirable quests, and values (`GET /v1/feedback`, `GET /v1/feedback/{id}`, `GET /v1/quests`, `GET /v1/builds/{build}/pending`, `GET /v1/values`).
     - `agent:triage`: Coding agent recording triage decisions (`PUT /v1/feedback/{id}/triage`).

| Endpoint | Required Scope |
| :--- | :--- |
| `POST /v1/builds/{build}/manifest` | `tester` |
| `POST /v1/uploads` | `tester` |
| `POST /v1/feedback` | `tester` |
| `PUT /v1/quests` | `quests:write` |
| `GET /v1/feedback` | `agent:read` |
| `GET /v1/feedback/{id}` | `agent:read` |
| `PUT /v1/feedback/{id}/triage` | `agent:triage` |
| `GET /v1/quests` | `agent:read` |
| `GET /v1/builds/{build}/pending` | `tester` or `agent:read` |
| `GET /v1/values` | `agent:read` |
| `POST /v1/webhooks/github` | `X-Hub-Signature-256` (HMAC-SHA256) |

Missing or invalid credentials return `401 Unauthorized` (`code: "unauthorized"`). Valid credentials lacking the required scope return `403 Forbidden` (`code: "forbidden"`).

---

## 3. Canonical Quest `content_hash`

A quest's `content_hash` is the lowercase SHA-256 hex digest of the canonical JSON representation of its functional fields—excluding `id` and `source` (`pr`, `sha`, `added`) so non-functional provenance tweaks do not invalidate prior test runs.

### Canonical Payload Structure

Keys are serialized in exact alphabetical order (`area`, `expect`, `needs`, `record`, `setup`, `start`, `steps`, `title`):

```json
{
  "area": "<trimmed string>",
  "capture": [
    {
      "event": "<trimmed string>",
      "label": "<trimmed string>",
      "max": null,
      "min": null,
      "unit": "none",
      "value": "<trimmed string>",
      "where": null
    }
  ],
  "expect": ["<trimmed string>", "..."],
  "needs": ["<trimmed string>", "..."],
  "record": "optional",
  "setup": ["<trimmed string>", "..."],
  "start": null,
  "steps": ["<trimmed string>", "..."],
  "title": "<trimmed string>"
}
```

Normalization rules applied by `computeQuestContentHash(quest)`:
- `area` and `title`: trimmed strings.
- `capture`: optional array of normalized capture definitions. When omitted or empty, the `capture` key is excluded from canonical JSON. When present, each capture definition is normalized:
  - `event`, `label`, `value`: trimmed strings.
  - `unit`: defaults to `"none"` (`"ms" | "s" | "bytes" | "count" | "percent" | "none"`).
  - `min`, `max`: finite number or `null`.
  - `where`: object with scalar values (`string | number | boolean`) with keys sorted alphabetically, or `null` if empty/omitted.
  - Keys within each capture object are serialized in alphabetical order (`event`, `label`, `max`, `min`, `unit`, `value`, `where`).
- `setup`, `steps`, `expect`, `needs`: arrays of trimmed strings (`setup` and `needs` default to `[]`).
- `record`: defaults to `"optional"` (`"none" | "optional" | "suggested" | "required"`).
- `start`: trimmed non-empty string, or `null` if omitted/empty.
- JSON is serialized with no whitespace (`JSON.stringify`) with top-level keys in alphabetical order and hashed with SHA-256 hex.

`computeQuestContentHash(quest)` is exported from `hollerkit-server` so the server, CLI, and conformance suite share the exact implementation.

---

## 4. Quest Versioning & Reactivation (`PUT /v1/quests`)

`hollerkit.quests` enforces `PRIMARY KEY (id, version)` and `UNIQUE (id, content_hash)`.

When `PUT /v1/quests` syncs a manifest from `main`:
1. For each quest in `manifest.quests`, the server computes `content_hash = computeQuestContentHash(quest)`:
   - **Existing `(id, content_hash)` match**: If any version row for `id` already has that `content_hash` (whether `active`, `draft`, `superseded`, or `retired`), the server **reactivates** that version row (`status = 'active'`, `retired_at = NULL`, updating metadata/source fields) and marks any other `'active'` or `'draft'` versions of `id` as `'superseded'` while preserving `'retired'` on previously retired versions. No duplicate version is minted.
   - **New `(id, content_hash)`**: The server computes `nextVersion = COALESCE(MAX(version), 0) + 1` across all versions of `id`, marks any prior `active` or `draft` versions of `id` as `superseded`, and inserts `(id, nextVersion, content_hash, ..., status = 'active')`.
2. **Retirement**: Any quest `id` that had an `active` version before the sync and is omitted from `manifest.quests` has its active version marked `status = 'retired'` with `retired_at = now()`.

---

## 5. Build Manifest & Board Status (`POST /v1/builds/{build}/manifest`)

When an iOS Debug or TestFlight build launches, it posts its bundled quests to `POST /v1/builds/{build}/manifest`:
- For each bundled quest:
  - If `(id, content_hash)` already exists in `hollerkit.quests`, that version is used.
  - If `(id, content_hash)` does not yet exist in `hollerkit.quests` (e.g. testing an unmerged branch before CI syncs `main`), the server inserts a new version (`max(version) + 1`) with `status = 'draft'`.
  - The server upserts `(quest_id, quest_version, build)` into `hollerkit.quest_builds`.
- Board status (`boardStatus`) for each quest version is scoped to `(quest_id, quest_version)` (since the last change to the quest's content hash, rather than resetting on every build increment) and is computed from feedback submitted against `(quest_id, quest_version)`:
  - `"passed"`: at least one feedback item for `(quest_id, quest_version)` has `result = 'pass'`.
  - `"failed"`: no `'pass'` exists, and at least one open feedback item (`triage_status` not in `('resolved', 'wontfix', 'duplicate')`) has `result = 'fail'`.
  - `"unsure"`: no `'pass'` and no open `'fail'` exists, and at least one open feedback item (`triage_status` not in `('resolved', 'wontfix', 'duplicate')`) has `result = 'unsure'`.
  - `"pending"`: no `'pass'` and no open `'fail'` or `'unsure'` feedback exists for `(quest_id, quest_version)` (untried, only `'abandoned'`, or all prior `'fail'`/`'unsure'` runs have been cleared in triage via `'resolved'`, `'wontfix'`, or `'duplicate'`).
- Each quest item also includes `latestRun` (`{ id, result, build, createdAt, comment, triageStatus } | null`) for the most recent `'pass'`, `'fail'`, or `'unsure'` run on `(quest_id, quest_version)` so the board card can show the last result, build, relative date, and first line of the tester's note.
- On the client Quest Board, untried (`"pending"`) quests are always ordered ahead of `"unsure"` and `"failed"` quests so prior runs never crowd out untried quests at the top of Pending.

---

## 6. Upload Grants (`POST /v1/uploads` & `POST /v1/feedback`)

Attachments use a two-step grant-and-consume flow to prevent unauthenticated bucket writes and cross-submission attachment spoofing:

1. **Reserve Grant (`POST /v1/uploads`)**:
   - The tester specifies `{ feedbackId, kind, mimeType, size }`.
   - The server validates `kind`, `mimeType`, and `size` against configured limits, generates a unique `storage_key` (`<feedbackId>/<uuid>.<ext>`), inserts a row in `hollerkit.upload_grants` bound to `(storage_key, feedback_id, submitter_id)` with a 10-minute `expires_at`, and returns `{ ok: true, key, url, expiresAt }`.
2. **Consume Grant (`POST /v1/feedback`)**:
   - Each attachment in `feedback.attachments` references `{ key, kind, ... }`.
   - The server verifies that a grant exists in `hollerkit.upload_grants` with `storage_key = key`:
     - If no grant exists or `grant.feedback_id !== feedback.id`: returns `400 invalid_attachment_grant`.
     - If `grant.submitter_id !== principalId`: returns `403 forbidden`.
     - If `grant.consumed_at !== null` (by a different feedback submission) or `grant.expires_at < now()`: returns `400 expired_or_consumed_grant`.
   - On creation, the server sets `grant.consumed_at = now()` and inserts the `hollerkit.attachments` row.

---

## 7. Feedback Idempotency & Triage State Rules

### Idempotency on `feedback.id`
- Clients generate a UUIDv4 `id` before requesting upload grants or submitting feedback (allowing offline `OutboxStore` retries).
- If `POST /v1/feedback` receives a `feedback.id` that already exists:
  - If `existing.submitter_id === principalId`, the server returns `200 OK` with `{ ok: true, idempotent: true, feedback: existing }` without duplicating feedback, events, or attachments, and without failing on upload grants already consumed by that same `feedback.id`.
  - If `existing.submitter_id !== principalId`, the server returns `403 forbidden` (or `409 conflict`).

### Initial `triage_status` Rules
- `triage_status` is initialized automatically when feedback is created:
  - `kind === 'report'` → `triage_status = 'new'`
  - `kind === 'quest_run'` with `result IN ('fail', 'unsure')` → `triage_status = 'new'`
  - `kind === 'quest_run'` with `result IN ('pass', 'abandoned')` → `triage_status = NULL`
- Consequently, `GET /v1/feedback?triage=new` returns only untriaged bug reports, failed quests, and unsure quests—never passing or abandoned quest runs.

### Transactional Triage (`PUT /v1/feedback/{id}/triage`)
- Appends an immutable audit entry to `hollerkit.triage` (`feedback_id`, `status`, `summary`, `links`, `actor`, `created_at`) and updates `hollerkit.feedback` (`triage_status`, `triage_summary`, `links`, `updated_at`) in the same database transaction.

### GitHub Webhook Triage Synchronization (`POST /v1/webhooks/github`)
- Verifies the `X-Hub-Signature-256` HMAC-SHA256 signature against the configured GitHub webhook secret (`githubWebhookSecret`).
- Supports `ping` (returns `{ ok: true, event: 'ping', pong: true }`) and `issues` (`closed`, `reopened`) events; all other GitHub event types return `{ ok: true, event, ignored: true, reason: 'unsupported_event' }`, and other `issues` actions return `{ ok: true, event: 'issues', action, ignored: true, reason: 'unsupported_action' }`.
- Synchronizing an `issues` (`closed` or `reopened`) event requires **both**:
  1. A valid HollerKit `feedbackId` marker embedded in the issue body (`<!-- hollerkit-feedback-id: <uuid> -->` or `<!-- hollerkit:{"feedbackId":"<uuid>"} -->`), and
  2. The webhook issue's `html_url` matching a trusted GitHub issue URL already recorded in `feedback.links` (with on-demand outbox reconciliation if `feedback.links` has not yet recorded an issue link).
- When verified, `closed` transitions `triage_status` to `'resolved'` (or `'wontfix'` for `state_reason = 'not_planned'`, `'duplicate'` for `state_reason = 'duplicate'`) and `reopened` transitions `triage_status` to `'triaged'`, appending an audit entry in `hollerkit.triage`.

---

## 8. Payload Limits

Default `/v1` limits enforced by `createHollerKitServer`:
- **Max JSON request body**: `262,144` bytes (256 KB) → `413 body_too_large`
- **Max text field (`comment`, `transcript`)**: `20,000` characters → `413 text_too_large`
- **Max image attachments per feedback**: `12` images → `413 too_many_images`
- **Max image attachment size**: `10,485,760` bytes (10 MB) → `413 image_too_large`
- **Max mark events / attachments per feedback**: `20` marks → `413 too_many_marks`
- **Max audio attachment size**: `10,485,760` bytes (10 MB) → `413 audio_too_large`
- **Max video attachment size**: `52,428,800` bytes (50 MB) → `413 video_too_large`


---

## 9. Measured Values & Querying (`GET /v1/values`)

When testers run quests that define `capture` rules, the server matches breadcrumbs at submit time and stores rows in `hollerkit.values`.

`GET /v1/values` requires `agent:read` scope and allows querying measured values across runs:
- Query parameters:
  - `quest` (required): quest ID.
  - `label` (required): capture label.
  - `version`: optional quest version number.
  - `build`: optional build string filter.
  - `appVersion`, `device`, `os`: optional device/environment filters.
  - `source`: optional source filter (`capture` | `answer`, defaults to `capture`).
  - `since`: optional ISO-8601 timestamp cutoff.
  - `groupBy`: optional breakdown dimension (`build`, `appVersion`, `device`, `os`, `version`, `label`).
  - `limit`: optional max rows to aggregate (1–500, default 100).
- Response:
  - Summary stats: `n`, `median`, `p90`, `min`, `max`.
  - Group summaries when `groupBy` is specified.

Feedback details (`GET /v1/feedback/{id}`) include a `captures` array listing each expected capture, its measured `value`, and advisory flags (`missing`, `below_min`, `above_max`).
