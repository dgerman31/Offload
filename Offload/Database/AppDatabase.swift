import Foundation
import GRDB

/// Owns the SQLite connection and schema (spec §6). Relies on iOS Data Protection for
/// at-rest encryption (the sandbox file is encrypted, keyed to the passcode). A random
/// Keychain key is provisioned via `KeychainKey` for optional SQLCipher defense-in-depth
/// in a later increment — never derived from user input (spec §6 / §0).
final class AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    /// Shared on-disk instance for the app.
    static let shared: AppDatabase = {
        do { return try AppDatabase.makeShared() }
        catch { fatalError("Failed to open database: \(error)") }
    }()

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Factories

    static func makeShared() throws -> AppDatabase {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let url = folder.appendingPathComponent("offload.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        return try AppDatabase(queue)
    }

    /// In-memory instance for tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // MARK: Data reset

    /// Remove ALL user data — every task, project, capture, detected pattern, and correction —
    /// in one transaction. Irreversible; backs the "Erase all tasks" reset in Settings. The
    /// schema itself is left intact, so the app keeps working on a clean slate.
    func eraseAllData() async throws {
        try await dbQueue.write { db in
            for table in ["tasks", "projects", "captures", "patterns", "corrections"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: Migrations (spec §6 schema)

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core_schema") { db in
            try db.execute(sql: """
                CREATE TABLE tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT,
                    category TEXT,
                    priority TEXT DEFAULT 'medium',
                    status TEXT DEFAULT 'open',
                    parent_task_id TEXT,
                    project_id TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    due_date TEXT,
                    due_date_confidence REAL,
                    recurrence_rule TEXT,
                    completed_at TEXT,
                    deferred_until TEXT,
                    context_tags TEXT,
                    effort_minutes INTEGER,
                    energy_level TEXT,
                    calendar_event_id TEXT,
                    metadata TEXT,
                    deleted INTEGER DEFAULT 0
                );

                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT,
                    status TEXT DEFAULT 'planning',
                    progress_percent INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT (datetime('now')),
                    due_date TEXT,
                    category TEXT,
                    metadata TEXT,
                    deleted INTEGER DEFAULT 0
                );

                CREATE TABLE captures (
                    id TEXT PRIMARY KEY,
                    raw_input TEXT NOT NULL,
                    input_type TEXT,
                    transcript TEXT,
                    processing_status TEXT,
                    extracted_task_ids TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    processed_at TEXT,
                    processing_ms INTEGER,
                    model_source TEXT,
                    metadata TEXT
                );

                CREATE TABLE corrections (
                    id TEXT PRIMARY KEY,
                    task_id TEXT,
                    field TEXT,
                    model_value TEXT,
                    user_value TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                );

                CREATE TABLE patterns (
                    id TEXT PRIMARY KEY,
                    pattern_type TEXT,
                    title TEXT,
                    related_task_ids TEXT,
                    confidence REAL,
                    suggested_action TEXT,
                    user_accepted INTEGER DEFAULT 0,
                    created_at TEXT,
                    dismissed_at TEXT
                );

                CREATE INDEX idx_tasks_status   ON tasks(status) WHERE deleted = 0;
                CREATE INDEX idx_tasks_project  ON tasks(project_id);
                CREATE INDEX idx_tasks_parent   ON tasks(parent_task_id);
                CREATE INDEX idx_tasks_due      ON tasks(due_date);
                """)
        }

        // Later increments register additional migrations here, e.g. the
        // sqlite-vec `task_vectors` virtual table for embedding search (spec §3.5).
        return migrator
    }()
}
