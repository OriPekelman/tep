-- app_config: single-row k/v store. Holds password_hash (set on
-- first boot via /setup) and any future per-install settings.
CREATE TABLE IF NOT EXISTS app_config (
  k TEXT PRIMARY KEY,
  v TEXT
);

-- conversations + messages: the chat history. Phase A uses one
-- conversation per database (the first row), so the sidebar UI
-- can stay deferred until Phase C without changing the schema.
CREATE TABLE IF NOT EXISTS conversations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  title      TEXT,
  created_at INTEGER
);

CREATE TABLE IF NOT EXISTS messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id INTEGER NOT NULL,
  role            TEXT NOT NULL,    -- "user" | "assistant" | "system"
  content         TEXT NOT NULL,
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS messages_by_conv ON messages (conversation_id, id);
