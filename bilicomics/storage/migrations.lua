local Migrations = { version = 1 }

Migrations[1] = [[
CREATE TABLE comics (id TEXT PRIMARY KEY, favorite INTEGER NOT NULL DEFAULT 0, last_read_at REAL NOT NULL DEFAULT 0, updated_at REAL NOT NULL, data TEXT NOT NULL);
CREATE INDEX comics_favorite ON comics(favorite, updated_at);
CREATE TABLE episodes (id TEXT PRIMARY KEY, comic_id TEXT NOT NULL, sort_order REAL NOT NULL, data TEXT NOT NULL);
CREATE INDEX episodes_order ON episodes(comic_id, sort_order, id);
CREATE TABLE pages (page_key TEXT PRIMARY KEY, episode_id TEXT NOT NULL, revision TEXT NOT NULL, page_index INTEGER NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL, UNIQUE(episode_id, revision, page_index));
CREATE INDEX pages_episode ON pages(episode_id, revision, page_index);
CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL, priority REAL NOT NULL DEFAULT 0, updated_at REAL NOT NULL, data TEXT NOT NULL);
CREATE INDEX jobs_state ON jobs(state, priority);
CREATE TABLE purchases (id TEXT PRIMARY KEY, state TEXT NOT NULL, updated_at REAL NOT NULL, data TEXT NOT NULL);
CREATE INDEX purchases_state ON purchases(state, updated_at);
CREATE TABLE anchors (episode_id TEXT NOT NULL, revision TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(episode_id, revision));
CREATE TABLE settings (setting_key TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE descriptors (episode_id TEXT NOT NULL, revision TEXT NOT NULL, comic_id TEXT NOT NULL, path TEXT UNIQUE NOT NULL, data TEXT NOT NULL, PRIMARY KEY(episode_id, revision));
CREATE TABLE pins (episode_id TEXT NOT NULL, revision TEXT NOT NULL, pinned INTEGER NOT NULL, PRIMARY KEY(episode_id, revision));
CREATE TABLE page_commits (page_key TEXT PRIMARY KEY, data TEXT NOT NULL);
]]

function Migrations.apply(connection)
    local current = tonumber(connection:rowexec("PRAGMA user_version")) or 0
    assert(current <= Migrations.version, "Storage was created by a newer plugin version")
    for version = current + 1, Migrations.version do
        connection:exec("BEGIN IMMEDIATE")
        local ok, err = pcall(function()
            connection:exec(Migrations[version])
            connection:exec("PRAGMA user_version=" .. version)
            connection:exec("COMMIT")
        end)
        if not ok then
            pcall(connection.exec, connection, "ROLLBACK")
            error(err, 0)
        end
    end
end

return Migrations
