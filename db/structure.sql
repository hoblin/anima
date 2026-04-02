CREATE TABLE IF NOT EXISTS "secrets" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "key" varchar NOT NULL, "namespace" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "value" text NOT NULL);
CREATE UNIQUE INDEX "index_secrets_on_namespace_and_key" ON "secrets" ("namespace", "key");
CREATE TABLE IF NOT EXISTS "goal_pinned_messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "goal_id" integer NOT NULL, "pinned_message_id" integer NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_689fd4bf8a"
FOREIGN KEY ("goal_id")
  REFERENCES "goals" ("id")
, CONSTRAINT "fk_rails_fb51bfeebe"
FOREIGN KEY ("pinned_message_id")
  REFERENCES "pinned_messages" ("id")
);
CREATE UNIQUE INDEX "index_goal_pinned_messages_on_goal_id_and_pinned_message_id" ON "goal_pinned_messages" ("goal_id", "pinned_message_id");
CREATE INDEX "index_goal_pinned_messages_on_goal_id" ON "goal_pinned_messages" ("goal_id");
CREATE INDEX "index_goal_pinned_messages_on_pinned_message_id" ON "goal_pinned_messages" ("pinned_message_id");
CREATE TABLE IF NOT EXISTS "goals" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "completed_at" datetime(6), "created_at" datetime(6) NOT NULL, "description" text NOT NULL, "evicted_at" datetime(6), "parent_goal_id" integer, "session_id" integer NOT NULL, "status" varchar DEFAULT 'active' NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_feeb9df31e"
FOREIGN KEY ("parent_goal_id")
  REFERENCES "goals" ("id")
, CONSTRAINT "fk_rails_874b7534ae"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_goals_on_parent_goal_id" ON "goals" ("parent_goal_id");
CREATE INDEX "index_goals_on_session_id_and_status" ON "goals" ("session_id", "status");
CREATE INDEX "index_goals_on_session_id" ON "goals" ("session_id");
CREATE TABLE IF NOT EXISTS "messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "api_metrics" json, "created_at" datetime(6) NOT NULL, "message_type" varchar NOT NULL, "payload" json DEFAULT '{}' NOT NULL, "session_id" integer NOT NULL, "status" varchar, "timestamp" integer(8) NOT NULL, "token_count" integer DEFAULT 0 NOT NULL, "tool_use_id" varchar, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_1ee2a92df0"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_messages_on_message_type" ON "messages" ("message_type");
CREATE INDEX "index_messages_on_session_id_and_message_type" ON "messages" ("session_id", "message_type");
CREATE INDEX "index_messages_on_session_id_and_status" ON "messages" ("session_id", "status");
CREATE INDEX "index_messages_on_session_id" ON "messages" ("session_id");
CREATE INDEX "index_messages_on_tool_use_id" ON "messages" ("tool_use_id");
CREATE TABLE IF NOT EXISTS "pending_messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "content" text NOT NULL, "created_at" datetime(6) NOT NULL, "session_id" integer NOT NULL, "source_name" varchar, "source_type" varchar DEFAULT 'user' NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_007242365b"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_pending_messages_on_session_id" ON "pending_messages" ("session_id");
CREATE TABLE IF NOT EXISTS "pinned_messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "display_text" text NOT NULL, "message_id" integer NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_4a5f237c43"
FOREIGN KEY ("message_id")
  REFERENCES "messages" ("id")
);
CREATE UNIQUE INDEX "index_pinned_messages_on_message_id" ON "pinned_messages" ("message_id");
CREATE TABLE IF NOT EXISTS "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "active_skills" json DEFAULT '[]' NOT NULL, "active_workflow" varchar, "created_at" datetime(6) NOT NULL, "granted_tools" text, "interrupt_requested" boolean DEFAULT FALSE NOT NULL, "mneme_boundary_message_id" integer, "mneme_snapshot_first_message_id" integer, "mneme_snapshot_last_message_id" integer, "name" varchar, "parent_session_id" integer, "processing" boolean DEFAULT FALSE NOT NULL, "prompt" text, "recalled_message_ids" json DEFAULT '[]' NOT NULL, "updated_at" datetime(6) NOT NULL, "view_mode" varchar DEFAULT 'basic' NOT NULL, "viewport_message_ids" json DEFAULT '[]' NOT NULL, CONSTRAINT "fk_rails_045409ac27"
FOREIGN KEY ("parent_session_id")
  REFERENCES "sessions" ("id")
);
CREATE UNIQUE INDEX "index_sessions_on_parent_and_name_unique" ON "sessions" ("parent_session_id", "name") WHERE name IS NOT NULL;
CREATE INDEX "index_sessions_on_parent_session_id" ON "sessions" ("parent_session_id");
CREATE TABLE IF NOT EXISTS "snapshots" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "from_message_id" integer NOT NULL, "level" integer DEFAULT 1 NOT NULL, "session_id" integer NOT NULL, "text" text NOT NULL, "to_message_id" integer NOT NULL, "token_count" integer DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_eb2ad51db9"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_snapshots_on_session_and_event_range" ON "snapshots" ("session_id", "from_message_id", "to_message_id");
CREATE INDEX "index_snapshots_on_session_id_and_level" ON "snapshots" ("session_id", "level");
CREATE INDEX "index_snapshots_on_session_id" ON "snapshots" ("session_id");
CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO "schema_migrations" (version) VALUES
('20260401210935'),
('20260401180000'),
('20260330120000'),
('20260329120000'),
('20260328152142'),
('20260328100000'),
('20260326180000'),
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

