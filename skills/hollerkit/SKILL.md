---
name: hollerkit
description: >-
  Author guided QA quests in hollerkit-quests.json, define structured telemetry
  captures, triage iOS bug reports and quest runs via hollerkit-mcp, and retire
  completed quests once verified on device.
---

# HollerKit Coding Agent Skill (`hollerkit`)

Use this skill whenever working on an iOS project integrated with **HollerKit** (`hollerkit-quests.json` and `hollerkit-mcp`).

---

## 1. Authoring QA Quests (`hollerkit-quests.json`)

When shipping a user-facing iOS feature or bug fix that needs real-device verification, add or update a quest in `hollerkit-quests.json`:

```json
{
  "version": 1,
  "quests": [
    {
      "id": "feed-scroll-restore",
      "title": "Feed scroll position restores after detail back navigation",
      "area": "feed",
      "setup": [
        "Sign in with test account"
      ],
      "steps": [
        "Scroll down 10 items",
        "Tap item 10",
        "Swipe back"
      ],
      "expect": [
        "Feed remains anchored at item 10"
      ],
      "needs": [
        "device"
      ],
      "record": "suggested",
      "start": "myapp://feed",
      "capture": [
        {
          "event": "feed.restore",
          "value": "durationMs",
          "unit": "ms",
          "label": "restore_latency",
          "max": 120
        }
      ],
      "source": {
        "pr": 42,
        "added": "2026-11-16"
      }
    }
  ]
}
```

### Quest Field Guidelines
- `id`: Stable kebab-case identifier prefixed by area (`<area>-<slug>`).
- `title`: Action-oriented summary shown on the in-app Quest Board.
- `area`: Feature domain (`"feed"`, `"camera"`, `"checkout"`, `"profile"`, etc.).
- `setup` (optional): Preconditions required before starting the quest.
- `steps`: 2–4 concrete physical actions for the tester to follow in the floating overlay.
- `expect`: Observable pass criteria on device.
- `needs` (optional): Environment requirements (`"device"` warns when running on Simulator; `"backend"` warns when offline).
- `record`: `"none" | "optional" | "suggested" | "required"` (controls whether the overlay prompts for annotated mark screenshots).
- `start` (optional): Deep-link URI passed to the host app's router when the tester taps **Start Quest**.
- `capture` (optional): Automated telemetry extraction rules matched against `HollerKit.begin(...)` spans or `HollerKit.breadcrumb(...)` events at submit time:
  - `event`: Breadcrumb/span message name.
  - `value`: `"durationMs"` or a numeric key in `fields`.
  - `unit`: `"ms" | "s" | "bytes" | "count" | "percent" | "none"`.
  - `label`: Metric identifier for `values_query`.
  - `where` (optional): Key/value filter on breadcrumb `fields` / `metadata`.
  - `min`, `max` (optional): Numeric bounds; violations automatically attach `below_min` / `above_max` / `out_of_range` flags.

Always validate the manifest after editing:

```sh
npx hollerkit quests validate hollerkit-quests.json
```

---

## 2. Triaging Feedback & Failed Quests (`hollerkit-mcp`)

1. **Check the Inbox**:
   - Call `feedback_inbox` (defaults to `triage: "new"`), which returns untriaged bug reports (`kind: "report"`) and failed or unsure quest runs (`kind: "quest_run"`).
2. **Inspect Details & Screenshots**:
   - Call `feedback_get` with `{ "id": "<uuid>" }` (pass `"includeImages": true` when supported to inspect attached screenshots and mark annotations directly).
   - Review `events` (chronological breadcrumbs, step checks, and marks), `captures` (including any `missing` or `out_of_range` flags), `comment`, and `transcript`.
3. **Fix & Record Triage**:
   - Locate and fix the root cause in the codebase, then run unit tests.
   - Call `feedback_triage` with `{ "id": "<uuid>", "status": "resolved", "summary": "<root cause and fix>", "links": ["<PR or commit URL>"] }`.

---

## 3. Retiring Passed Quests

1. Call `quests_retirable` (optionally filtered by `area`) to find active quests where `passedOnCurrentVersion` is `true`.
2. Verify `counts.fail` and `counts.unsure` have been resolved or triaged.
3. Remove the passed quest definitions from `hollerkit-quests.json` in a cleanup commit/PR so testers only see active unverified quests.

---

## 4. Querying Telemetry Measurements (`values_query`)

Call `values_query` with `{ "quest": "<quest-id>", "label": "<capture-label>", "groupBy": "build" }` to inspect `n`, `median`, `p90`, `min`, and `max` across builds or devices and detect performance regressions.
