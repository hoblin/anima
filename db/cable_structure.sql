CREATE TABLE "solid_cable_messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "channel" blob(1024) NOT NULL, "channel_hash" integer(8) NOT NULL, "created_at" datetime(6) NOT NULL, "payload" blob(536870912) NOT NULL);
CREATE INDEX "index_solid_cable_messages_on_channel" ON "solid_cable_messages" ("channel");
CREATE INDEX "index_solid_cable_messages_on_channel_hash" ON "solid_cable_messages" ("channel_hash");
CREATE INDEX "index_solid_cable_messages_on_created_at" ON "solid_cable_messages" ("created_at");
CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO "schema_migrations" (version) VALUES
('1');

