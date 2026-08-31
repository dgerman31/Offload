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

    /// Every table that holds user data, in lock-step with the migrations below. **When a
    /// migration adds a table, add it here.**
    ///
    /// This list had already drifted once: `routines` and `routine_exceptions` (added by
    /// `v6_routines`) were missing, which made "Erase everything" undo itself. `RoutineService`
    /// materializes routines on every foreground and its idempotency guard is "does today's task
    /// for this routine already exist" — a task the erase had just deleted — so every active
    /// routine re-inserted its task the moment the app came back, on top of a "can't be undone"
    /// confirmation.
    private static let userDataTables = [
        "tasks", "projects", "captures", "patterns", "corrections", "workout_sessions",
        "routines", "routine_exceptions",
    ]

    /// Remove ALL user data — every task, project, capture, routine, detected pattern, and
    /// correction — in one transaction. Irreversible; backs the "Erase all tasks" reset in
    /// Settings. The schema itself is left intact, so the app keeps working on a clean slate.
    ///
    /// Deleting is driven by the explicit list rather than by `sqlite_master` because a future
    /// virtual table (the planned sqlite-vec `task_vectors`) brings shadow tables that must not be
    /// deleted from directly. The trade-off is that the list can drift, so the same transaction
    /// cross-checks it against the real schema and logs any table it didn't touch — the next
    /// omission is loud instead of silent.
    func eraseAllData() async throws {
        try await dbQueue.write { db in
            for table in AppDatabase.userDataTables {
                try db.execute(sql: "DELETE FROM \"\(table)\"")
            }

            let known = Set(AppDatabase.userDataTables)
            let present = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                """)
            let missed = present.filter { !known.contains($0) }
            if !missed.isEmpty {
                // Table names are schema constants, never user content — safe to log in the clear.
                let names = missed.joined(separator: ", ")
                Log.database.error("eraseAllData did not cover \(missed.count, privacy: .public) table(s): \(names, privacy: .public)")
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

        // Nested projects: a project can live inside another, so "Future App Ideas" can hold
        // subfolders. Self-FK, nullable — existing projects simply become top-level.
        migrator.registerMigration("v2_project_subfolders") { db in
            try db.execute(sql: """
                ALTER TABLE projects ADD COLUMN parent_project_id TEXT;
                CREATE INDEX idx_projects_parent ON projects(parent_project_id);
                """)
        }

        // Who a task involves, as a JSON array of names — so "what do I owe Sarah?" is a
        // query rather than a memory exercise (spec §4, relationship tracking).
        migrator.registerMigration("v3_task_people") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN people TEXT;")
        }

        // Separate "when I'll do it" from "when it's actually due", and let a due date mean a
        // *day* rather than a moment. Conflating the two is what produced tasks scheduled for
        // 1 AM: every date had to pretend to be a precise time.
        migrator.registerMigration("v4_due_semantics") { db in
            try db.execute(sql: """
                ALTER TABLE tasks ADD COLUMN deadline TEXT;
                ALTER TABLE tasks ADD COLUMN due_is_all_day INTEGER DEFAULT 0;
                """)
        }

        // Self-healing timeline: distinguish a soft scheduled time (the planner's guess, which
        // may reflow as the day slips) from a pinned commitment (a time a human or a real
        // calendar event fixed, which must never move). Existing timed tasks default to soft.
        migrator.registerMigration("v5_pinned_time") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN pinned INTEGER DEFAULT 0;")
        }

        // Recurring routines — the fixed skeleton of a week (classes) and flexible habits
        // (gym 4–5× a week, days chosen for you). Exceptions record one-off cancellations.
        migrator.registerMigration("v6_routines") { db in
            try db.execute(sql: """
                CREATE TABLE routines (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    category TEXT,
                    kind TEXT DEFAULT 'fixed',
                    weekdays TEXT,
                    start_minute INTEGER,
                    duration_minutes INTEGER DEFAULT 60,
                    times_per_week INTEGER DEFAULT 0,
                    flex INTEGER DEFAULT 0,
                    active INTEGER DEFAULT 1,
                    created_at TEXT DEFAULT (datetime('now'))
                );

                CREATE TABLE routine_exceptions (
                    id TEXT PRIMARY KEY,
                    routine_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    created_at TEXT DEFAULT (datetime('now'))
                );

                CREATE INDEX idx_exceptions_routine ON routine_exceptions(routine_id, date);
                """)
        }

        // Manual drag-to-reorder: a user-set position. Null = never reordered (falls back to
        // capture order). Nullable REAL so we can slot a task between two others without
        // renumbering everything.
        migrator.registerMigration("v7_task_sort_order") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN sort_order REAL;")
        }

        // The Gym tab: a full weekly workout organizer, planned by Gemini. Each session gets a
        // lightweight linked task (`gym_session_id`) that blocks its time on Home/Day — tapping
        // that task opens the Gym tab to the session rather than a normal task detail, so the
        // real workout content (exercises, sets, muscle groups) lives in exactly one place.
        migrator.registerMigration("v8_gym") { db in
            try db.execute(sql: """
                CREATE TABLE workout_sessions (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    date TEXT NOT NULL,
                    start_minute INTEGER,
                    duration_minutes INTEGER DEFAULT 45,
                    workout_type TEXT DEFAULT 'strength',
                    muscle_groups TEXT,
                    exercises TEXT,
                    notes TEXT,
                    status TEXT DEFAULT 'planned',
                    completed_at TEXT,
                    task_id TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    deleted INTEGER DEFAULT 0
                );

                CREATE INDEX idx_gym_date ON workout_sessions(date) WHERE deleted = 0;

                ALTER TABLE tasks ADD COLUMN gym_session_id TEXT;
                """)
        }

        // Retry bookkeeping for captures whose extraction failed. `prepare` has always marked
        // those rows `failed` "so they can be retried later", but nothing read the status and
        // later never came; `CaptureRetrySweep` now re-attempts them on foreground. This column is
        // what keeps that bounded: every failed attempt increments it, and a capture that has used
        // up its attempts is left alone for good instead of being retried on every launch forever.
        // Additive and defaulted, like every migration above.
        migrator.registerMigration("v9_capture_retry_count") { db in
            try db.execute(sql: "ALTER TABLE captures ADD COLUMN retry_count INTEGER DEFAULT 0;")
        }

        // Focus history: what a task was estimated to take against what it actually took. The
        // app has run timers against model estimates since focus sessions existed and kept only a
        // running minute total in `UserDefaults`, so the comparison — the one signal that could
        // make estimates personal — was discarded every time. See `TaskSession`.
        migrator.registerMigration("v10_task_sessions") { db in
            try db.execute(sql: """
                CREATE TABLE task_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL,
                    category TEXT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT NOT NULL,
                    planned_minutes INTEGER NOT NULL,
                    actual_minutes INTEGER NOT NULL,
                    ran_to_completion INTEGER NOT NULL DEFAULT 0
                );
                """)
            // Reads are "this task's history" and "everything, newest first" — one index each.
            try db.execute(sql: "CREATE INDEX idx_task_sessions_task ON task_sessions(task_id);")
            try db.execute(sql: "CREATE INDEX idx_task_sessions_started ON task_sessions(started_at);")
        }

        // Daily habits and the grocery list. Both deliberately avoid `tasks`: a habit shouldn't be
        // scheduled, shouldn't compete for the planner's free time, and shouldn't become overdue
        // clutter when a day is missed, and forty items of shopping shouldn't flood Home. See
        // `Habit` and `GroceryItem`.
        migrator.registerMigration("v11_habits_and_groceries") { db in
            try db.execute(sql: """
                CREATE TABLE habits (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    symbol TEXT NOT NULL DEFAULT 'checkmark.circle',
                    sort_order REAL NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: """
                CREATE TABLE habit_checks (
                    id TEXT PRIMARY KEY NOT NULL,
                    habit_id TEXT NOT NULL,
                    day TEXT NOT NULL,
                    checked_at TEXT NOT NULL
                );
                """)
            // A tick is the row's existence, so the same habit can't be ticked twice on one day —
            // enforced here rather than trusted to the UI, since a double tap is one tap too many.
            try db.execute(sql: "CREATE UNIQUE INDEX idx_habit_checks_day ON habit_checks(habit_id, day);")
            try db.execute(sql: """
                CREATE TABLE grocery_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    bought INTEGER NOT NULL DEFAULT 0,
                    sort_order REAL NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
                """)
        }

        // A ticked grocery item stays on the list for the rest of the day and is swept the next
        // one — see `GroceryStore.sweepBought`. Which day it was ticked on has to be recorded for
        // that to be possible, and `bought` alone can't carry it.
        migrator.registerMigration("v12_grocery_bought_day") { db in
            try db.execute(sql: "ALTER TABLE grocery_items ADD COLUMN bought_day TEXT;")
            // Backfill rather than leaving nulls: an item ticked five minutes before the app
            // updated would otherwise look like it had been bought on no day at all, and the
            // first sweep would take it away mid-shop. Dating them today means the existing
            // ticked items behave exactly like newly ticked ones — they last until tonight.
            try db.execute(sql: "UPDATE grocery_items SET bought_day = ? WHERE bought = 1;",
                           arguments: [HabitProgress.dayKey(Date())])
        }

        // What kind of thing a capture is — see `CaptureKind`. Everything that already exists is
        // a task, because a task was the only thing the app could produce before this.
        migrator.registerMigration("v13_capture_kind") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';")
            try db.execute(sql: "CREATE INDEX idx_tasks_kind ON tasks(kind);")
        }

        // Projects as things you actually finish, rather than folders that accumulate.
        //
        // `hill` is a Basecamp-style hill-chart position, 0…1: the first half is figuring the work
        // out, the second half is executing it. It earns its place over a percentage because a
        // percentage cannot express *stuck* — 40% done and 40% done three weeks running look
        // identical, where a dot that hasn't moved off the uphill is unmistakable. `project_updates`
        // keeps the history that makes that visible, which is the half most implementations miss.
        migrator.registerMigration("v14_project_workspace") { db in
            try db.execute(sql: "ALTER TABLE projects ADD COLUMN hill REAL;")
            try db.execute(sql: "ALTER TABLE projects ADD COLUMN hill_updated_at TEXT;")
            try db.execute(sql: "ALTER TABLE projects ADD COLUMN sort_order REAL;")
            try db.execute(sql: "ALTER TABLE projects ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: """
                CREATE TABLE project_updates (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    hill REAL,
                    note TEXT
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_project_updates_project ON project_updates(project_id, created_at);")
        }

        // Later increments register additional migrations here, e.g. the
        // sqlite-vec `task_vectors` virtual table for embedding search (spec §3.5).
        return migrator
    }()
}
