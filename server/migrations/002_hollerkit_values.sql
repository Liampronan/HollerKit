-- HollerKit v1 Quest Captures & Measured Values Migration
-- Adds `capture` definitions to `hollerkit.quests` and creates `hollerkit.values`.

ALTER TABLE hollerkit.quests
  ADD COLUMN IF NOT EXISTS capture jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE TABLE IF NOT EXISTS hollerkit.values (
  id bigserial PRIMARY KEY,
  feedback_id uuid NOT NULL REFERENCES hollerkit.feedback(id) ON DELETE CASCADE,
  quest_id text NOT NULL,
  quest_version integer NOT NULL,
  source text NOT NULL DEFAULT 'capture' CHECK (source IN ('capture', 'answer')),
  label text NOT NULL,
  value double precision,
  text_value text,
  bool_value boolean,
  unit text NOT NULL DEFAULT 'none' CHECK (unit IN ('ms', 's', 'bytes', 'count', 'percent', 'none')),
  event text,
  offset_seconds double precision,
  min double precision,
  max double precision,
  flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  build text NOT NULL,
  app_version text,
  device text,
  os text,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (quest_id, quest_version) REFERENCES hollerkit.quests(id, version) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_values_quest_label_build
  ON hollerkit.values (quest_id, label, build, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_values_feedback
  ON hollerkit.values (feedback_id, id ASC);

ALTER TABLE hollerkit.values ENABLE ROW LEVEL SECURITY;
