import Foundation
import sqlcipher

/// SQLite-хранилище истории удалённых сообщений (как в AyuGram — настоящая БД, а не файл/UserDefaults).
/// Потокобезопасно через сериал-очередь; все операции под одной транзакцией.
final class AntiDeleteStorage {
    private let queue = DispatchQueue(label: "com.ghostgram.antiDelete.storage")
    private var db: OpaquePointer?
    private let dbPath: String

    init?(directory: URL) {
        let dbURL = directory.appendingPathComponent("antidelete.sqlite")
        self.dbPath = dbURL.path

        let result = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, db != nil else {
            print("[AntiDelete] sqlite open failed: \(result)")
            return nil
        }

        // WAL: читатели не блокируют запись, устойчивость к обрывам
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        let createSql = """
        CREATE TABLE IF NOT EXISTS archived_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            global_id INTEGER NOT NULL,
            peer_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,
            deleted_at INTEGER NOT NULL,
            author_id INTEGER,
            text TEXT NOT NULL,
            forward_author_id INTEGER,
            media_description TEXT,
            media_path TEXT,
            media_kind TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_archived_unique ON archived_messages(global_id, peer_id);
        CREATE INDEX IF NOT EXISTS idx_archived_peer ON archived_messages(peer_id, deleted_at);
        CREATE TABLE IF NOT EXISTS deleted_ids (
            key TEXT PRIMARY KEY
        );
        """
        guard sqlite3_exec(db, createSql, nil, nil, nil) == SQLITE_OK else {
            print("[AntiDelete] sqlite schema failed: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Bind/Read helpers

    private static func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func readText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func rowToMessage(_ statement: OpaquePointer?) -> AntiDeleteManager.ArchivedMessage {
        func optionalInt64(_ index: Int32) -> Int64? {
            if sqlite3_column_type(statement, index) == SQLITE_NULL {
                return nil
            }
            return sqlite3_column_int64(statement, index)
        }
        return AntiDeleteManager.ArchivedMessage(
            globalId: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
            peerId: sqlite3_column_int64(statement, 2),
            messageId: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 3)),
            timestamp: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 4)),
            deletedAt: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 5)),
            authorId: optionalInt64(6),
            text: readText(statement, 7) ?? "",
            forwardAuthorId: optionalInt64(8),
            mediaDescription: readText(statement, 9),
            mediaPath: readText(statement, 10),
            mediaKind: readText(statement, 11)
        )
    }

    // MARK: - Operations

    func insertArchived(_ message: AntiDeleteManager.ArchivedMessage) {
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            let sql = """
            INSERT OR IGNORE INTO archived_messages
            (global_id, peer_id, message_id, timestamp, deleted_at, author_id, text, forward_author_id, media_description, media_path, media_kind)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                print("[AntiDelete] insert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(message.globalId))
            sqlite3_bind_int64(statement, 2, message.peerId)
            sqlite3_bind_int64(statement, 3, Int64(message.messageId))
            sqlite3_bind_int64(statement, 4, Int64(message.timestamp))
            sqlite3_bind_int64(statement, 5, Int64(message.deletedAt))
            if let authorId = message.authorId {
                sqlite3_bind_int64(statement, 6, authorId)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            Self.bindText(statement, 7, message.text)
            if let forwardAuthorId = message.forwardAuthorId {
                sqlite3_bind_int64(statement, 8, forwardAuthorId)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            Self.bindText(statement, 9, message.mediaDescription)
            Self.bindText(statement, 10, message.mediaPath)
            Self.bindText(statement, 11, message.mediaKind)
            if sqlite3_step(statement) != SQLITE_DONE {
                print("[AntiDelete] insert step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func updateMedia(globalId: Int32, peerId: Int64, mediaPath: String?, mediaKind: String?) {
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            let sql = "UPDATE archived_messages SET media_path = ?1, media_kind = ?2 WHERE global_id = ?3 AND peer_id = ?4;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            Self.bindText(statement, 1, mediaPath)
            Self.bindText(statement, 2, mediaKind)
            sqlite3_bind_int64(statement, 3, Int64(globalId))
            sqlite3_bind_int64(statement, 4, peerId)
            sqlite3_step(statement)
        }
    }

    func allArchived() -> [AntiDeleteManager.ArchivedMessage] {
        return queue.sync {
            guard let db = db else { return [] }
            var statement: OpaquePointer?
            let sql = "SELECT * FROM archived_messages ORDER BY deleted_at DESC;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [AntiDeleteManager.ArchivedMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Self.rowToMessage(statement))
            }
            return result
        }
    }

    func archived(peerId: Int64) -> [AntiDeleteManager.ArchivedMessage] {
        return queue.sync {
            guard let db = db else { return [] }
            var statement: OpaquePointer?
            let sql = "SELECT * FROM archived_messages WHERE peer_id = ?1 ORDER BY deleted_at DESC;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, peerId)
            var result: [AntiDeleteManager.ArchivedMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Self.rowToMessage(statement))
            }
            return result
        }
    }

    func count() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM archived_messages;", -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func archivedIds() -> [(peerId: Int64, messageId: Int32)] {
        return queue.sync {
            guard let db = db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT peer_id, message_id FROM archived_messages;", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [(peerId: Int64, messageId: Int32)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((sqlite3_column_int64(statement, 0), Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1))))
            }
            return result
        }
    }

    func insertDeletedId(key: String) {
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO deleted_ids (key) VALUES (?1);", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            Self.bindText(statement, 1, key)
            sqlite3_step(statement)
        }
    }

    func deletedIds() -> Set<String> {
        return queue.sync {
            guard let db = db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT key FROM deleted_ids;", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = Self.readText(statement, 0) {
                    result.insert(key)
                }
            }
            return result
        }
    }

    func deleteArchived(globalId: Int32) -> String? {
        return queue.sync {
            guard let db = db else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT media_path FROM archived_messages WHERE global_id = ?1;", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(globalId))
            var mediaPath: String?
            if sqlite3_step(statement) == SQLITE_ROW {
                mediaPath = Self.readText(statement, 0)
            }

            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM archived_messages WHERE global_id = ?1;", -1, &deleteStatement, nil) == SQLITE_OK else { return mediaPath }
            defer { sqlite3_finalize(deleteStatement) }
            sqlite3_bind_int64(deleteStatement, 1, Int64(globalId))
            sqlite3_step(deleteStatement)
            return mediaPath
        }
    }

    func clear() -> [String] {
        return queue.sync {
            guard let db = db else { return [] }
            var mediaPaths: [String] = []
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT media_path FROM archived_messages WHERE media_path IS NOT NULL;", -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let path = Self.readText(statement, 0) {
                        mediaPaths.append(path)
                    }
                }
            }
            sqlite3_finalize(statement)

            sqlite3_exec(db, "DELETE FROM archived_messages; DELETE FROM deleted_ids;", nil, nil, nil)
            return mediaPaths
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
