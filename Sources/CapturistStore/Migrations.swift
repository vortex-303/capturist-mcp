import Foundation

public enum Migrations {
    public static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.userVersion
        if version < 1 {
            try database.executeScript(
                """
                CREATE TABLE IF NOT EXISTS captures (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    state TEXT NOT NULL,
                    original_path TEXT NOT NULL,
                    thumbnail_path TEXT,
                    preview_path TEXT,
                    display_name TEXT NOT NULL,
                    width INTEGER NOT NULL DEFAULT 0,
                    height INTEGER NOT NULL DEFAULT 0,
                    duration_ms INTEGER NOT NULL DEFAULT 0,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    checksum TEXT,
                    source_app TEXT,
                    source_title TEXT,
                    source_url TEXT,
                    remote_page_url TEXT,
                    remote_file_url TEXT,
                    remote_id TEXT,
                    failure_reason TEXT,
                    deleted_at REAL,
                    updated_at REAL NOT NULL,
                    sync_version INTEGER NOT NULL DEFAULT 0
                );

                CREATE INDEX IF NOT EXISTS idx_captures_created_at
                    ON captures (created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_captures_kind
                    ON captures (kind, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_captures_checksum
                    ON captures (checksum);

                PRAGMA user_version = 1;
                """
            )
        }
        if try database.userVersion < 2 {
            try database.executeScript(
                """
                ALTER TABLE captures ADD COLUMN text_content TEXT;
                PRAGMA user_version = 2;
                """
            )
        }
        if try database.userVersion < 3 {
            try database.executeScript(
                """
                ALTER TABLE captures ADD COLUMN remote_delete_token TEXT;
                ALTER TABLE captures ADD COLUMN remote_expires_at REAL;
                PRAGMA user_version = 3;
                """
            )
        }
        if try database.userVersion < 4 {
            try database.executeScript(
                """
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY NOT NULL,
                    created REAL NOT NULL,
                    text TEXT NOT NULL,
                    source_app TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_clips_created ON clips (created DESC);
                PRAGMA user_version = 4;
                """
            )
        }
    }
}
