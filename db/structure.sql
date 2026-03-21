CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "events" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "session_id" integer NOT NULL, "event_type" varchar NOT NULL, "payload" json DEFAULT '{}' NOT NULL, "timestamp" integer(8) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "token_count" integer DEFAULT 0 NOT NULL, "tool_use_id" varchar, "status" varchar, CONSTRAINT "fk_rails_a5735975a7"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_events_on_session_id" ON "events" ("session_id");
CREATE INDEX "index_events_on_event_type" ON "events" ("event_type");
CREATE INDEX "index_events_on_session_id_and_event_type" ON "events" ("session_id", "event_type");
CREATE INDEX "index_events_on_tool_use_id" ON "events" ("tool_use_id");
CREATE INDEX "index_events_on_session_id_and_status" ON "events" ("session_id", "status");
CREATE TABLE IF NOT EXISTS "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "view_mode" varchar DEFAULT 'basic' NOT NULL, "processing" boolean DEFAULT FALSE NOT NULL, "parent_session_id" integer, "prompt" text, "granted_tools" text, "name" varchar, "viewport_event_ids" json DEFAULT '[]' NOT NULL, "active_skills" json DEFAULT '[]' NOT NULL, "active_workflow" varchar, "interrupt_requested" boolean DEFAULT FALSE NOT NULL, "mneme_boundary_event_id" integer, "mneme_snapshot_first_event_id" integer, "mneme_snapshot_last_event_id" integer, "recalled_event_ids" json DEFAULT '[]' NOT NULL, CONSTRAINT "fk_rails_045409ac27"
FOREIGN KEY ("parent_session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_sessions_on_parent_session_id" ON "sessions" ("parent_session_id");
CREATE TABLE IF NOT EXISTS "goals" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "session_id" integer NOT NULL, "parent_goal_id" integer, "description" text NOT NULL, "status" varchar DEFAULT 'active' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "completed_at" datetime(6), CONSTRAINT "fk_rails_874b7534ae"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
, CONSTRAINT "fk_rails_feeb9df31e"
FOREIGN KEY ("parent_goal_id")
  REFERENCES "goals" ("id")
);
CREATE INDEX "index_goals_on_session_id" ON "goals" ("session_id");
CREATE INDEX "index_goals_on_parent_goal_id" ON "goals" ("parent_goal_id");
CREATE INDEX "index_goals_on_session_id_and_status" ON "goals" ("session_id", "status");
CREATE TABLE IF NOT EXISTS "snapshots" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "session_id" integer NOT NULL, "text" text NOT NULL, "from_event_id" integer NOT NULL, "to_event_id" integer NOT NULL, "level" integer DEFAULT 1 NOT NULL, "token_count" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_eb2ad51db9"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_snapshots_on_session_id" ON "snapshots" ("session_id");
CREATE INDEX "index_snapshots_on_session_id_and_level" ON "snapshots" ("session_id", "level");
CREATE INDEX "index_snapshots_on_session_and_event_range" ON "snapshots" ("session_id", "from_event_id", "to_event_id");
CREATE TABLE IF NOT EXISTS "pinned_events" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "event_id" integer NOT NULL, "session_id" integer NOT NULL, "display_text" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_140a30d5f5"
FOREIGN KEY ("event_id")
  REFERENCES "events" ("id")
, CONSTRAINT "fk_rails_4f1d3c7657"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_pinned_events_on_event_id" ON "pinned_events" ("event_id");
CREATE INDEX "index_pinned_events_on_session_id" ON "pinned_events" ("session_id");
CREATE UNIQUE INDEX "index_pinned_events_on_session_id_and_event_id" ON "pinned_events" ("session_id", "event_id");
CREATE TABLE IF NOT EXISTS "goal_pinned_events" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "goal_id" integer NOT NULL, "pinned_event_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_b9ea7f6964"
FOREIGN KEY ("goal_id")
  REFERENCES "goals" ("id")
, CONSTRAINT "fk_rails_b9f53aae37"
FOREIGN KEY ("pinned_event_id")
  REFERENCES "pinned_events" ("id")
);
CREATE INDEX "index_goal_pinned_events_on_goal_id" ON "goal_pinned_events" ("goal_id");
CREATE INDEX "index_goal_pinned_events_on_pinned_event_id" ON "goal_pinned_events" ("pinned_event_id");
CREATE UNIQUE INDEX "index_goal_pinned_events_on_goal_id_and_pinned_event_id" ON "goal_pinned_events" ("goal_id", "pinned_event_id");
CREATE VIRTUAL TABLE events_fts USING fts5(
  searchable_text,
  content='',
  contentless_delete=1,
  tokenize='porter unicode61'
)
/* events_fts(searchable_text) */;
CREATE TRIGGER events_fts_insert AFTER INSERT ON events
WHEN NEW.event_type IN ('user_message', 'agent_message', 'system_message')
  OR (NEW.event_type = 'tool_call' AND json_extract(NEW.payload, '$.tool_name') = 'think')
BEGIN
  INSERT INTO events_fts(rowid, searchable_text)
  VALUES (
    NEW.id,
    CASE
      WHEN NEW.event_type IN ('user_message', 'agent_message', 'system_message')
        THEN json_extract(NEW.payload, '$.content')
      WHEN NEW.event_type = 'tool_call'
        THEN json_extract(NEW.payload, '$.tool_input.thoughts')
    END
  );
END;
CREATE TRIGGER events_fts_delete AFTER DELETE ON events
WHEN OLD.event_type IN ('user_message', 'agent_message', 'system_message')
  OR (OLD.event_type = 'tool_call' AND json_extract(OLD.payload, '$.tool_name') = 'think')
BEGIN
  DELETE FROM events_fts WHERE rowid = OLD.id;
END;
INSERT INTO "schema_migrations" (version) VALUES
('20260321140100'),
('20260321140000'),
('20260321120000'),
('20260321080000'),
('20260316094817'),
('20260315191105'),
('20260315144837'),
('20260315140843'),
('20260315100000'),
('20260314150000'),
('20260314140000'),
('20260314112417'),
('20260314075248'),
('20260313020000'),
('20260313010000'),
('20260312170000'),
('20260308160000'),
('20260308150000'),
('20260308140000'),
('20260308130000'),
('20260308124203'),
('20260308124202');

