import CSQLite
import Foundation

public enum ClipboardStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case operationFailed(String)
    case notOpen
    case assetCapacityExceeded
}

public struct ClipboardClearResult: Equatable, Sendable {
    public let assetCleanupFailureCount: Int

    public init(assetCleanupFailureCount: Int) {
        self.assetCleanupFailureCount = assetCleanupFailureCount
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor ClipboardStore {
    private let databaseURL: URL
    private let assetsDirectoryURL: URL
    private let retentionPolicy: ClipboardRetentionPolicy
    private var database: OpaquePointer?

    public init(
        databaseURL: URL,
        assetsDirectoryURL: URL,
        retentionPolicy: ClipboardRetentionPolicy = .default
    ) {
        self.databaseURL = databaseURL
        self.assetsDirectoryURL = assetsDirectoryURL
        self.retentionPolicy = retentionPolicy
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func open() throws {
        guard database == nil else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw ClipboardStoreError.openFailed(error.localizedDescription)
        }

        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened else {
            let message = opened.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite status \(status)"
            if let opened { sqlite3_close(opened) }
            throw ClipboardStoreError.openFailed(message)
        }

        database = opened
        do {
            try execute("PRAGMA journal_mode=WAL", operation: "enable WAL")
            try execute("PRAGMA foreign_keys=ON", operation: "enable foreign keys")
            try execute("PRAGMA busy_timeout=2000", operation: "set busy timeout")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS clipboard_items (
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  content_hash TEXT NOT NULL UNIQUE,
                  plain_text TEXT NOT NULL,
                  asset_path TEXT,
                  file_urls BLOB,
                  source_app_name TEXT,
                  source_bundle_id TEXT,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  last_restored_at REAL,
                  is_favorite INTEGER NOT NULL DEFAULT 0,
                  byte_size INTEGER NOT NULL
                )
                """,
                operation: "create clipboard table"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS clipboard_items_updated_idx ON clipboard_items(updated_at DESC)",
                operation: "create updated index"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS clipboard_items_kind_idx ON clipboard_items(kind)",
                operation: "create kind index"
            )
            try cleanupOrphanAssets()
        } catch {
            sqlite3_close(opened)
            database = nil
            if let storeError = error as? ClipboardStoreError {
                throw ClipboardStoreError.openFailed(String(describing: storeError))
            }
            throw ClipboardStoreError.openFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func upsert(_ content: NormalizedClipboardContent) throws -> ClipboardItem {
        try ensureOpen()
        let existing = try item(contentHash: content.contentHash)

        if content.kind == .image, let data = content.imagePNG {
            if existing == nil {
                try makeRoomForImage(byteSize: Int64(data.count), now: content.capturedAt)
            }
        }

        let id = existing?.id ?? UUID()
        let createdAt = existing?.createdAt ?? content.capturedAt
        let assetPath: String?
        if content.kind == .image {
            if let existingPath = existing?.assetPath, assetURL(for: existingPath) != nil {
                assetPath = existingPath
            } else {
                assetPath = "\(id.uuidString).png"
            }
        } else {
            assetPath = nil
        }

        var writtenAssetURL: URL?
        if let imageData = content.imagePNG,
           let assetPath,
           let destination = assetURL(for: assetPath) {
            do {
                try imageData.write(to: destination, options: .atomic)
                writtenAssetURL = destination
            } catch {
                throw ClipboardStoreError.operationFailed("write image asset: \(error.localizedDescription)")
            }
        }

        do {
            try beginTransaction()
            if existing == nil {
                try insert(
                    id: id,
                    createdAt: createdAt,
                    assetPath: assetPath,
                    content: content
                )
            } else {
                try update(id: id, assetPath: assetPath, content: content)
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            if existing == nil, let writtenAssetURL {
                try? FileManager.default.removeItem(at: writtenAssetURL)
            }
            throw error
        }

        guard let stored = try item(id: id) else {
            throw ClipboardStoreError.operationFailed("upsert completed without a readable row")
        }
        return stored
    }

    public func query(_ query: ClipboardQuery = ClipboardQuery()) throws -> [ClipboardItem] {
        try ensureOpen()
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        switch query.filter {
        case .all:
            break
        case .text:
            clauses.append("kind IN (?, ?)")
            bindings.append(.text(ClipboardItemKind.text.rawValue))
            bindings.append(.text(ClipboardItemKind.link.rawValue))
        case .image:
            clauses.append("kind = ?")
            bindings.append(.text(ClipboardItemKind.image.rawValue))
        case .files:
            clauses.append("kind = ?")
            bindings.append(.text(ClipboardItemKind.files.rawValue))
        case .favorites:
            clauses.append("is_favorite = 1")
        }

        if !query.searchText.isEmpty {
            clauses.append("(plain_text LIKE ? ESCAPE '\\' OR source_app_name LIKE ? ESCAPE '\\')")
            let pattern = "%\(escapedLikePattern(query.searchText))%"
            bindings.append(.text(pattern))
            bindings.append(.text(pattern))
        }

        var sql = "SELECT \(Self.columns) FROM clipboard_items"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY updated_at DESC, id ASC LIMIT ?"
        bindings.append(.int64(Int64(max(0, query.limit))))
        return try readItems(sql: sql, bindings: bindings)
    }

    public func setFavorite(id: UUID, isFavorite: Bool) throws {
        try executeMutation(
            "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?",
            bindings: [.int64(isFavorite ? 1 : 0), .text(id.uuidString)],
            operation: "set favorite"
        )
    }

    public func delete(id: UUID) throws {
        guard let item = try item(id: id) else { return }
        try beginTransaction()
        do {
            try executeMutation(
                "DELETE FROM clipboard_items WHERE id = ?",
                bindings: [.text(id.uuidString)],
                operation: "delete item"
            )
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
        try removeAsset(for: item)
    }

    @discardableResult
    public func clear() throws -> ClipboardClearResult {
        let items = try allItems()
        try beginTransaction()
        do {
            try executeMutation("DELETE FROM clipboard_items", bindings: [], operation: "clear history")
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
        var assetCleanupFailureCount = 0
        for item in items {
            do {
                try removeAsset(for: item)
            } catch {
                assetCleanupFailureCount += 1
                NSLog("[ScreenshotTool] clipboard asset cleanup deferred: \(error)")
            }
        }
        return ClipboardClearResult(assetCleanupFailureCount: assetCleanupFailureCount)
    }

    public func markRestored(id: UUID, at date: Date = Date()) throws {
        try executeMutation(
            "UPDATE clipboard_items SET last_restored_at = ? WHERE id = ?",
            bindings: [.double(date.timeIntervalSince1970), .text(id.uuidString)],
            operation: "mark restored"
        )
    }

    public func assetData(for item: ClipboardItem) throws -> Data? {
        try ensureOpen()
        guard let assetPath = item.assetPath,
              let url = assetURL(for: assetPath) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ClipboardStoreError.operationFailed("read image asset: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func prune(now: Date = Date()) throws -> [UUID] {
        let items = try allItems()
        let assetBytes = items.reduce(Int64(0)) { total, item in
            item.kind == .image ? total + item.byteSize : total
        }
        let ids = retentionPolicy.evictionIDs(items: items, assetBytes: assetBytes, now: now)
        try delete(ids: ids, from: items)
        return ids
    }

    private func insert(
        id: UUID,
        createdAt: Date,
        assetPath: String?,
        content: NormalizedClipboardContent
    ) throws {
        try executeMutation(
            """
            INSERT INTO clipboard_items (
              id, kind, content_hash, plain_text, asset_path, file_urls,
              source_app_name, source_bundle_id, created_at, updated_at,
              last_restored_at, is_favorite, byte_size
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, ?)
            """,
            bindings: [
                .text(id.uuidString),
                .text(content.kind.rawValue),
                .text(content.contentHash),
                .text(content.plainText),
                assetPath.map(SQLiteBinding.text) ?? .null,
                try encodedFileURLs(content.fileURLs).map(SQLiteBinding.blob) ?? .null,
                content.source.appName.map(SQLiteBinding.text) ?? .null,
                content.source.bundleID.map(SQLiteBinding.text) ?? .null,
                .double(createdAt.timeIntervalSince1970),
                .double(content.capturedAt.timeIntervalSince1970),
                .int64(content.byteSize)
            ],
            operation: "insert item"
        )
    }

    private func update(
        id: UUID,
        assetPath: String?,
        content: NormalizedClipboardContent
    ) throws {
        try executeMutation(
            """
            UPDATE clipboard_items SET
              kind = ?, plain_text = ?, asset_path = ?, file_urls = ?,
              source_app_name = ?, source_bundle_id = ?, updated_at = ?, byte_size = ?
            WHERE id = ?
            """,
            bindings: [
                .text(content.kind.rawValue),
                .text(content.plainText),
                assetPath.map(SQLiteBinding.text) ?? .null,
                try encodedFileURLs(content.fileURLs).map(SQLiteBinding.blob) ?? .null,
                content.source.appName.map(SQLiteBinding.text) ?? .null,
                content.source.bundleID.map(SQLiteBinding.text) ?? .null,
                .double(content.capturedAt.timeIntervalSince1970),
                .int64(content.byteSize),
                .text(id.uuidString)
            ],
            operation: "update item"
        )
    }

    private func item(id: UUID) throws -> ClipboardItem? {
        try readItems(
            sql: "SELECT \(Self.columns) FROM clipboard_items WHERE id = ? LIMIT 1",
            bindings: [.text(id.uuidString)]
        ).first
    }

    private func item(contentHash: String) throws -> ClipboardItem? {
        try readItems(
            sql: "SELECT \(Self.columns) FROM clipboard_items WHERE content_hash = ? LIMIT 1",
            bindings: [.text(contentHash)]
        ).first
    }

    private func allItems() throws -> [ClipboardItem] {
        try readItems(
            sql: "SELECT \(Self.columns) FROM clipboard_items ORDER BY updated_at ASC, id ASC",
            bindings: []
        )
    }

    private func makeRoomForImage(byteSize: Int64, now: Date) throws {
        _ = try prune(now: now)
        let items = try allItems()
        var total = items.reduce(Int64(0)) { total, item in
            item.kind == .image ? total + item.byteSize : total
        }
        guard total + byteSize > retentionPolicy.maxAssetBytes else { return }

        let eligible = items
            .filter { $0.kind == .image && !$0.isFavorite }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        var ids: [UUID] = []
        for item in eligible where total + byteSize > retentionPolicy.maxAssetBytes {
            ids.append(item.id)
            total = max(0, total - item.byteSize)
        }
        try delete(ids: ids, from: items)
        guard total + byteSize <= retentionPolicy.maxAssetBytes else {
            throw ClipboardStoreError.assetCapacityExceeded
        }
    }

    private func delete(ids: [UUID], from items: [ClipboardItem]) throws {
        guard !ids.isEmpty else { return }
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        try beginTransaction()
        do {
            for id in ids {
                try executeMutation(
                    "DELETE FROM clipboard_items WHERE id = ?",
                    bindings: [.text(id.uuidString)],
                    operation: "prune item"
                )
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
        for id in ids {
            if let item = itemByID[id] {
                try removeAsset(for: item)
            }
        }
    }

    private func removeAsset(for item: ClipboardItem) throws {
        guard let assetPath = item.assetPath,
              let url = assetURL(for: assetPath) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ClipboardStoreError.operationFailed("remove image asset: \(error.localizedDescription)")
        }
    }

    private func cleanupOrphanAssets() throws {
        let referenced = Set(try allItems().compactMap { item -> String? in
            guard let path = item.assetPath, assetURL(for: path) != nil else { return nil }
            return path
        })
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: assetsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ClipboardStoreError.operationFailed("list image assets: \(error.localizedDescription)")
        }
        for url in contents where url.pathExtension.lowercased() == "png" && !referenced.contains(url.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ClipboardStoreError.operationFailed("remove orphan image asset: \(error.localizedDescription)")
            }
        }
    }

    private static let columns = """
    id, kind, content_hash, plain_text, asset_path, file_urls,
    source_app_name, source_bundle_id, created_at, updated_at,
    last_restored_at, is_favorite, byte_size
    """

    private func readItems(sql: String, bindings: [SQLiteBinding]) throws -> [ClipboardItem] {
        let statement = try prepare(sql, operation: "prepare query")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, operation: "bind query")
        var result: [ClipboardItem] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw operationError("step query", status: status)
            }
            result.append(try decodeItem(statement))
        }
        return result
    }

    private func decodeItem(_ statement: OpaquePointer) throws -> ClipboardItem {
        guard let idText = columnText(statement, 0),
              let id = UUID(uuidString: idText),
              let kindText = columnText(statement, 1),
              let kind = ClipboardItemKind(rawValue: kindText),
              let contentHash = columnText(statement, 2),
              let plainText = columnText(statement, 3) else {
            throw ClipboardStoreError.operationFailed("decode invalid clipboard row")
        }
        let fileURLs = try decodedFileURLs(columnData(statement, 5))
        let restoredAt: Date?
        if sqlite3_column_type(statement, 10) == SQLITE_NULL {
            restoredAt = nil
        } else {
            restoredAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        }
        return ClipboardItem(
            id: id,
            kind: kind,
            contentHash: contentHash,
            plainText: plainText,
            assetPath: columnText(statement, 4),
            fileURLs: fileURLs,
            source: ClipboardSource(
                appName: columnText(statement, 6),
                bundleID: columnText(statement, 7)
            ),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            lastRestoredAt: restoredAt,
            isFavorite: sqlite3_column_int(statement, 11) != 0,
            byteSize: sqlite3_column_int64(statement, 12)
        )
    }

    private func execute(_ sql: String, operation: String) throws {
        guard let database else { throw ClipboardStoreError.notOpen }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw ClipboardStoreError.operationFailed("\(operation): \(text)")
        }
    }

    private func executeMutation(
        _ sql: String,
        bindings: [SQLiteBinding],
        operation: String
    ) throws {
        let statement = try prepare(sql, operation: operation)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, operation: operation)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw operationError(operation, status: status)
        }
    }

    private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
        guard let database else { throw ClipboardStoreError.notOpen }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw operationError(operation, status: status)
        }
        return statement
    }

    private func bind(
        _ bindings: [SQLiteBinding],
        to statement: OpaquePointer,
        operation: String
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .int64(let value):
                status = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                status = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                status = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
                }
            case .blob(let data):
                status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard status == SQLITE_OK else {
                throw operationError(operation, status: status)
            }
        }
    }

    private func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE", operation: "begin transaction")
    }

    private func commitTransaction() throws {
        try execute("COMMIT", operation: "commit transaction")
    }

    private func rollbackTransaction() throws {
        try execute("ROLLBACK", operation: "rollback transaction")
    }

    private func ensureOpen() throws {
        guard database != nil else { throw ClipboardStoreError.notOpen }
    }

    private func operationError(_ operation: String, status: Int32) -> ClipboardStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite status \(status)"
        return .operationFailed("\(operation): \(message)")
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func encodedFileURLs(_ urls: [URL]) throws -> Data? {
        guard !urls.isEmpty else { return nil }
        do {
            return try JSONEncoder().encode(urls.map(\.absoluteString))
        } catch {
            throw ClipboardStoreError.operationFailed("encode file URLs: \(error.localizedDescription)")
        }
    }

    private func decodedFileURLs(_ data: Data?) throws -> [URL] {
        guard let data else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data).compactMap(URL.init(string:))
        } catch {
            throw ClipboardStoreError.operationFailed("decode file URLs: \(error.localizedDescription)")
        }
    }

    private func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func assetURL(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              relativePath == (relativePath as NSString).lastPathComponent,
              !relativePath.contains("/"),
              !relativePath.contains("\\"),
              (relativePath as NSString).pathExtension.lowercased() == "png" else {
            return nil
        }
        return assetsDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
    }
}

private enum SQLiteBinding {
    case null
    case int64(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}
