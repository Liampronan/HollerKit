-- HollerKit v1 Postgres Schema Migration
-- Creates the `hollerkit` schema and all 10 tables with Row Level Security enabled.

CREATE SCHEMA IF NOT EXISTS hollerkit;

-- 1. quests: versioned quest definitions synced from main or discovered on builds
CREATE TABLE IF NOT EXISTS hollerkit.quests (
  id text NOT NULL,
  version integer NOT NULL CHECK (version >= 1),
  content_hash text NOT NULL,
  title text NOT NULL,
  area text NOT NULL,
  setup jsonb NOT NULL DEFAULT '[]'::jsonb,
  steps jsonb NOT NULL DEFAULT '[]'::jsonb,
  expect jsonb NOT NULL DEFAULT '[]'::jsonb,
  needs jsonb NOT NULL DEFAULT '[]'::jsonb,
  record text NOT NULL DEFAULT 'optional' CHECK (record IN ('none', 'optional', 'suggested', 'required')),
  start text,
  source_pr integer,
  source_sha text,
  source_added text,
  status text NOT NULL CHECK (status IN ('draft', 'active', 'superseded', 'retired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  PRIMARY KEY (id, version),
  UNIQUE (id, content_hash)
);

-- 2. quest_builds: tracks which quest versions are bundled in which app builds
CREATE TABLE IF NOT EXISTS hollerkit.quest_builds (
  quest_id text NOT NULL,
  quest_version integer NOT NULL,
  build text NOT NULL,
  app_version text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (quest_id, quest_version, build),
  FOREIGN KEY (quest_id, quest_version) REFERENCES hollerkit.quests(id, version) ON DELETE CASCADE
);

-- 3. feedback: unified reports and quest runs
CREATE TABLE IF NOT EXISTS hollerkit.feedback (
  id uuid PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('report', 'quest_run')),
  quest_id text,
  quest_version integer,
  result text CHECK (result IS NULL OR result IN ('pass', 'fail', 'unsure', 'abandoned')),
  triage_status text CHECK (triage_status IS NULL OR triage_status IN ('new', 'triaged', 'resolved', 'wontfix', 'duplicate')),
  triage_summary text,
  links jsonb NOT NULL DEFAULT '[]'::jsonb,
  build text NOT NULL,
  app_version text,
  device text,
  os text,
  submitter_id text NOT NULL,
  comment text,
  transcript text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  steps_checked jsonb NOT NULL DEFAULT '[]'::jsonb,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (quest_id, quest_version) REFERENCES hollerkit.quests(id, version)
);

-- 4. events: chronological breadcrumbs, marks, and lifecycle events for a feedback item
CREATE TABLE IF NOT EXISTS hollerkit.events (
  id bigserial PRIMARY KEY,
  feedback_id uuid NOT NULL REFERENCES hollerkit.feedback(id) ON DELETE CASCADE,
  offset_seconds double precision NOT NULL DEFAULT 0,
  kind text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- 5. upload_grants: pre-authorized storage keys bound to (storage_key, feedback_id, submitter_id)
CREATE TABLE IF NOT EXISTS hollerkit.upload_grants (
  storage_key text PRIMARY KEY,
  feedback_id uuid NOT NULL,
  submitter_id text NOT NULL,
  kind text NOT NULL,
  mime_type text NOT NULL,
  size integer NOT NULL CHECK (size > 0),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 6. attachments: uploaded media consumed by a feedback submission
CREATE TABLE IF NOT EXISTS hollerkit.attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feedback_id uuid NOT NULL REFERENCES hollerkit.feedback(id) ON DELETE CASCADE,
  kind text NOT NULL,
  storage_key text NOT NULL UNIQUE REFERENCES hollerkit.upload_grants(storage_key),
  mime_type text NOT NULL,
  size integer NOT NULL,
  offset_seconds double precision,
  video_start_offset_seconds double precision,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 7. triage: append-only audit log of triage transitions
CREATE TABLE IF NOT EXISTS hollerkit.triage (
  id bigserial PRIMARY KEY,
  feedback_id uuid NOT NULL REFERENCES hollerkit.feedback(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('new', 'triaged', 'resolved', 'wontfix', 'duplicate')),
  summary text NOT NULL,
  links jsonb NOT NULL DEFAULT '[]'::jsonb,
  actor text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 8. outbox: optional notification sink delivery queue
CREATE TABLE IF NOT EXISTS hollerkit.outbox (
  id bigserial PRIMARY KEY,
  feedback_id uuid NOT NULL REFERENCES hollerkit.feedback(id) ON DELETE CASCADE,
  sink text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  link text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 9. testers: authorized tester user IDs
CREATE TABLE IF NOT EXISTS hollerkit.testers (
  user_id text PRIMARY KEY,
  email text,
  label text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 10. api_keys: SHA-256 hashed API keys for CI and coding agents
CREATE TABLE IF NOT EXISTS hollerkit.api_keys (
  key_hash text PRIMARY KEY,
  key_prefix text NOT NULL,
  label text,
  scopes text[] NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

-- Indexes for inbox, pending quests, and build queries
CREATE INDEX IF NOT EXISTS idx_quests_status_area
  ON hollerkit.quests (status, area);

CREATE INDEX IF NOT EXISTS idx_quest_builds_build
  ON hollerkit.quest_builds (build, quest_id, quest_version);

CREATE INDEX IF NOT EXISTS idx_feedback_triage_created
  ON hollerkit.feedback (triage_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_feedback_quest_version_result
  ON hollerkit.feedback (quest_id, quest_version, result);

CREATE INDEX IF NOT EXISTS idx_feedback_build_created
  ON hollerkit.feedback (build, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_feedback_offset
  ON hollerkit.events (feedback_id, offset_seconds ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_attachments_feedback
  ON hollerkit.attachments (feedback_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_triage_feedback_created
  ON hollerkit.triage (feedback_id, created_at ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_upload_grants_feedback_submitter
  ON hollerkit.upload_grants (feedback_id, submitter_id);

CREATE INDEX IF NOT EXISTS idx_outbox_pending
  ON hollerkit.outbox (next_attempt_at ASC)
  WHERE delivered_at IS NULL;

-- Enable Row Level Security on every table in hollerkit (deny-by-default for public/anon roles)
ALTER TABLE hollerkit.quests ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.quest_builds ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.upload_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.triage ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.testers ENABLE ROW LEVEL SECURITY;
ALTER TABLE hollerkit.api_keys ENABLE ROW LEVEL SECURITY;
