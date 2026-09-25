import Foundation
import ClipboardHistoryCore
import CSQLite

@main
struct ClipboardHistoryCoreChecks {
    static func main() async throws {
        let source = ClipboardSource(appName: "Notes", bundleID: "com.apple.Notes")
        let first = ClipboardCandidate(
            payload: .text("hello\r\nworld"),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let second = ClipboardCandidate(
            payload: .text("hello\nworld"),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        let a = try ClipboardContentNormalizer.normalized(candidate: first)
        let b = try ClipboardContentNormalizer.normalized(candidate: second)
        expect(a.contentHash == b.contentHash, "line endings must normalize before hashing")
        expect(a.plainText == "hello\nworld", "normalized text must be stored")

        let link = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .link(URL(string: "HTTPS://Example.COM/path")!),
            source: source,
            capturedAt: .now
        ))
        expect(
            link.kind == .link && link.plainText == "https://example.com/path",
            "links must have a canonical representation"
        )

        let files = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .files([
                URL(fileURLWithPath: "/tmp/a"),
                URL(fileURLWithPath: "/tmp/b")
            ]),
            source: source,
            capturedAt: .now
        ))
        expect(
            files.fileURLs.count == 2 && files.kind == .files,
            "file order and type must survive normalization"
        )

        expectThrowsEmptyContent()
        checkPrivacyPolicy()
        checkRetentionPolicy()
        try await checkPinnedColumnMigration()
        try await checkClipboardStore(source: source, first: first, second: second)
        print("✅ ClipboardHistoryCoreChecks passed")
    }

    private static func checkPinnedColumnMigration() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clipboard-pin-migration-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = root.appendingPathComponent("history.sqlite")
        let assetsURL = root.appendingPathComponent("assets", isDirectory: true)
        try createLegacyDatabase(at: databaseURL)
        try await migrateAndPinLegacyRow(databaseURL: databaseURL, assetsURL: assetsURL)

        let reopenedStore = ClipboardStore(
            databaseURL: databaseURL,
            assetsDirectoryURL: assetsURL
        )
        try await reopenedStore.open()
        let reopenedItems = try await reopenedStore.query()
        expect(
            reopenedItems.count == 1 && reopenedItems[0].isPinned,
            "a pin set after legacy schema migration must survive reopening the store"
        )
    }

    private static func createLegacyDatabase(at databaseURL: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(databaseURL.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            fatalError("❌ could not create the legacy migration fixture")
        }

        let sql = """
        CREATE TABLE clipboard_items (
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
        );
        INSERT INTO clipboard_items (
          id, kind, content_hash, plain_text, created_at, updated_at, is_favorite, byte_size
        ) VALUES (
          '11111111-1111-1111-1111-111111111111', 'text', 'legacy-hash',
          'legacy row', 1, 2, 0, 10
        );
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let executeStatus = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) }
        sqlite3_free(errorMessage)
        sqlite3_close(database)
        guard executeStatus == SQLITE_OK else {
            fatalError("❌ could not prepare the legacy migration fixture: \(message ?? "unknown error")")
        }
    }

    private static func migrateAndPinLegacyRow(
        databaseURL: URL,
        assetsURL: URL
    ) async throws {
        let store = ClipboardStore(databaseURL: databaseURL, assetsDirectoryURL: assetsURL)
        try await store.open()
        let migratedItems = try await store.query()
        expect(
            migratedItems.count == 1 && !migratedItems[0].isPinned,
            "legacy rows must migrate with pinning disabled"
        )
        try await store.setPinned(id: migratedItems[0].id, isPinned: true)
    }

    private static func checkClipboardStore(
        source: ClipboardSource,
        first: ClipboardCandidate,
        second: ClipboardCandidate
    ) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clipboard-store-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("history.sqlite")
        let assetsURL = root.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let orphanURL = assetsURL.appendingPathComponent("orphan.png")
        try Data([1, 2, 3]).write(to: orphanURL)

        let store = ClipboardStore(databaseURL: databaseURL, assetsDirectoryURL: assetsURL)
        try await store.open()
        expect(!fileManager.fileExists(atPath: orphanURL.path), "opening the store must remove orphan image assets")

        let outsideAssetURL = root.appendingPathComponent("outside.png")
        try Data([4, 5, 6]).write(to: outsideAssetURL)
        let traversalItem = ClipboardItem(
            id: UUID(),
            kind: .image,
            contentHash: "traversal",
            plainText: "图片",
            assetPath: "../outside.png",
            fileURLs: [],
            source: source,
            createdAt: .now,
            updatedAt: .now,
            lastRestoredAt: nil,
            isFavorite: false,
            byteSize: 3
        )
        let traversalData = try await store.assetData(for: traversalItem)
        expect(traversalData == nil, "asset paths must never escape the image resource directory")
        expect(fileManager.fileExists(atPath: outsideAssetURL.path), "invalid asset paths must not touch outside files")

        let firstStored = try await store.upsert(
            try ClipboardContentNormalizer.normalized(candidate: first)
        )
        let duplicateStored = try await store.upsert(
            try ClipboardContentNormalizer.normalized(candidate: second)
        )
        expect(firstStored.id == duplicateStored.id, "duplicates must update one row")
        expect(
            duplicateStored.createdAt == firstStored.createdAt && duplicateStored.updatedAt == second.capturedAt,
            "duplicate updates must retain creation time and move the item to the new time"
        )
        let textMatches = try await store.query(.init(searchText: "world"))
        expect(textMatches.count == 1, "search must match stored text")

        try await store.setFavorite(id: firstStored.id, isFavorite: true)
        let favoriteMatches = try await store.query(.init(filter: .favorites))
        expect(favoriteMatches.map(\.id) == [firstStored.id], "favorites filter must return the toggled item")

        let link = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
            payload: .link(URL(string: "https://example.com/docs")!),
            source: ClipboardSource(appName: "Browser", bundleID: "com.example.browser"),
            capturedAt: Date(timeIntervalSince1970: 2.5)
        )))
        try await store.setPinned(id: firstStored.id, isPinned: true)
        let pinnedMatches = try await store.query()
        expect(pinnedMatches.first?.id == firstStored.id, "pinned items must sort before newer history")
        expect(pinnedMatches.first?.isPinned == true, "pinned state must persist in the store")
        try await store.setPinned(id: firstStored.id, isPinned: false)
        let unpinnedMatches = try await store.query()
        expect(unpinnedMatches.first?.id == link.id, "unpinning must restore chronological ordering")
        try await store.setPinned(id: firstStored.id, isPinned: true)
        let textFilterMatches = try await store.query(.init(filter: .text))
        expect(
            Set(textFilterMatches.map(\.id)) == Set([firstStored.id, link.id]),
            "text filter must include both plain text and links"
        )
        let sourceMatches = try await store.query(.init(searchText: "Browser"))
        expect(sourceMatches.map(\.id) == [link.id], "search must match the source application name")

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let image = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
            payload: .imagePNG(imageData),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 3)
        )))
        let roundTripImageData = try await store.assetData(for: image)
        expect(roundTripImageData == imageData, "image asset must round-trip")
        try await store.markRestored(id: image.id, at: Date(timeIntervalSince1970: 4))
        let imageMatches = try await store.query(.init(filter: .image))
        expect(imageMatches.first?.lastRestoredAt == Date(timeIntervalSince1970: 4), "restore time must persist")

        try await store.delete(id: image.id)
        let deletedImageData = try await store.assetData(for: image)
        expect(deletedImageData == nil, "deleting an image must remove its asset")

        let missing = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
            payload: .imagePNG(Data([7, 8, 9])),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 5)
        )))
        if let assetPath = missing.assetPath {
            try fileManager.removeItem(at: assetsURL.appendingPathComponent(assetPath))
        }
        let missingImageData = try await store.assetData(for: missing)
        expect(missingImageData == nil, "missing image assets must return nil")
        let rowAfterMissingAsset = try await store.query(.init(filter: .image))
        expect(rowAfterMissingAsset.contains(where: { $0.id == missing.id }), "missing assets must not delete metadata")

        _ = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
            payload: .imagePNG(Data([10, 11, 12])),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 6)
        )))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: assetsURL.path)
        let clearResult: ClipboardClearResult
        do {
            clearResult = try await store.clear()
        } catch {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assetsURL.path)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assetsURL.path)
        expect(
            clearResult.assetCleanupFailureCount == 1,
            "clear must report image cleanup failures after committing history deletion"
        )
        let clearedItems = try await store.query()
        expect(clearedItems.isEmpty, "clear must remove every database row")

        try await checkStoreCapacity(source: source)
        try await checkCorruptedDatabaseIsolation()
    }

    private static func checkStoreCapacity(source: ClipboardSource) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clipboard-capacity-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let policy = ClipboardRetentionPolicy(maxCount: 500, maxAge: 2_592_000, maxAssetBytes: 10)
        let store = ClipboardStore(
            databaseURL: root.appendingPathComponent("history.sqlite"),
            assetsDirectoryURL: root.appendingPathComponent("assets"),
            retentionPolicy: policy
        )
        try await store.open()
        let favorite = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
            payload: .imagePNG(Data(repeating: 1, count: 8)),
            source: source,
            capturedAt: .now
        )))
        try await store.setFavorite(id: favorite.id, isFavorite: true)

        do {
            _ = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
                payload: .imagePNG(Data(repeating: 2, count: 4)),
                source: source,
                capturedAt: .now
            )))
            fatalError("❌ image admission must fail when favorite assets consume capacity")
        } catch ClipboardStoreError.assetCapacityExceeded {
            // Expected.
        }
        let capacityItems = try await store.query()
        expect(capacityItems.count == 1, "capacity rejection must not create a database row")

        try await store.setFavorite(id: favorite.id, isFavorite: false)
        try await store.setPinned(id: favorite.id, isPinned: true)
        do {
            _ = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(
                payload: .imagePNG(Data(repeating: 3, count: 4)),
                source: source,
                capturedAt: .now.addingTimeInterval(1)
            )))
            fatalError("❌ image admission must fail when pinned assets consume capacity")
        } catch ClipboardStoreError.assetCapacityExceeded {
            // Expected.
        }
        let pinnedCapacityItems = try await store.query()
        expect(pinnedCapacityItems.count == 1, "pinned assets must be protected from capacity eviction")
    }

    private static func checkCorruptedDatabaseIsolation() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clipboard-corrupt-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseDirectory = root.appendingPathComponent("history.sqlite", isDirectory: true)
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let store = ClipboardStore(
            databaseURL: databaseDirectory,
            assetsDirectoryURL: root.appendingPathComponent("assets")
        )
        do {
            try await store.open()
            fatalError("❌ a directory database path must fail to open")
        } catch ClipboardStoreError.openFailed {
            // Expected.
        }
    }

    private static func checkPrivacyPolicy() {
        let privacy = ClipboardPrivacyPolicy(excludedBundleIDs: ["com.example.private"])
        expect(
            privacy.decision(
                kind: .text,
                typeNames: ["org.nspasteboard.ConcealedType"],
                sourceBundleID: nil,
                payloadBytes: 10
            ) == .reject(.sensitiveType),
            "concealed content must be rejected"
        )
        expect(
            privacy.decision(
                kind: .text,
                typeNames: ["org.nspasteboard.TransientType"],
                sourceBundleID: nil,
                payloadBytes: 10
            ) == .reject(.sensitiveType),
            "transient content must be rejected"
        )
        expect(
            privacy.decision(
                kind: .text,
                typeNames: ["org.nspasteboard.AutoGeneratedType"],
                sourceBundleID: nil,
                payloadBytes: 10
            ) == .reject(.sensitiveType),
            "auto-generated content must be rejected"
        )
        expect(
            privacy.decision(
                kind: .text,
                typeNames: ["public.utf8-plain-text"],
                sourceBundleID: "com.example.private",
                payloadBytes: 10
            ) == .reject(.excludedApplication),
            "excluded apps must be rejected"
        )
        expect(
            privacy.decision(
                kind: .text,
                typeNames: ["public.utf8-plain-text"],
                sourceBundleID: nil,
                payloadBytes: 1_048_577
            ) == .reject(.tooLarge),
            "oversized text must be rejected"
        )
        expect(
            privacy.decision(
                kind: .image,
                typeNames: ["public.png"],
                sourceBundleID: nil,
                payloadBytes: 40 * 1_024 * 1_024 + 1
            ) == .reject(.tooLarge),
            "oversized images must be rejected"
        )
        expect(
            privacy.decision(
                kind: .files,
                typeNames: ["public.file-url"],
                sourceBundleID: nil,
                payloadBytes: 2_000_000
            ) == .accept,
            "file metadata is not subject to content-size limits"
        )
    }

    private static func checkRetentionPolicy() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let items = makeRetentionFixtures(now: now, normalCount: 502, favoriteCount: 1)
        let evictions = ClipboardRetentionPolicy.default.evictionIDs(
            items: items,
            assetBytes: 0,
            now: now
        )
        expect(evictions.count == 2, "count limit must evict oldest non-favorites")
        expect(
            evictions == [items[0].id, items[1].id],
            "count eviction must be oldest first"
        )
        expect(!evictions.contains(items.last!.id), "favorites must survive count eviction")

        let expired = makeItem(
            index: 10_000,
            kind: .text,
            updatedAt: now.addingTimeInterval(-(31 * 24 * 60 * 60)),
            isFavorite: false,
            byteSize: 10
        )
        let expiredFavorite = makeItem(
            index: 10_001,
            kind: .image,
            updatedAt: now.addingTimeInterval(-(60 * 24 * 60 * 60)),
            isFavorite: true,
            byteSize: 500
        )
        let expiredPinned = makeItem(
            index: 10_002,
            kind: .text,
            updatedAt: now.addingTimeInterval(-(60 * 24 * 60 * 60)),
            isFavorite: false,
            isPinned: true,
            byteSize: 10
        )
        let ageEvictions = ClipboardRetentionPolicy.default.evictionIDs(
            items: [expired, expiredFavorite, expiredPinned],
            assetBytes: 500,
            now: now
        )
        expect(ageEvictions == [expired.id], "age cleanup must preserve favorites and pinned items")

        let oldImage = makeItem(
            index: 20_000,
            kind: .image,
            updatedAt: now.addingTimeInterval(-20),
            isFavorite: false,
            byteSize: 80
        )
        let newImage = makeItem(
            index: 20_001,
            kind: .image,
            updatedAt: now.addingTimeInterval(-10),
            isFavorite: false,
            byteSize: 50
        )
        let tinyPolicy = ClipboardRetentionPolicy(maxCount: 500, maxAge: 30 * 24 * 60 * 60, maxAssetBytes: 100)
        expect(
            tinyPolicy.evictionIDs(items: [newImage, oldImage], assetBytes: 130, now: now) == [oldImage.id],
            "asset cleanup must evict the oldest eligible image until under the limit"
        )
    }

    private static func expectThrowsEmptyContent() {
        let source = ClipboardSource(appName: nil, bundleID: nil)
        do {
            _ = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
                payload: .text(""),
                source: source,
                capturedAt: .now
            ))
            fatalError("❌ empty text must be rejected")
        } catch ClipboardNormalizationError.emptyContent {
            // Expected.
        } catch {
            fatalError("❌ wrong empty-content error: \(error)")
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }

    private static func makeRetentionFixtures(
        now: Date,
        normalCount: Int,
        favoriteCount: Int
    ) -> [ClipboardItem] {
        let normal = (0..<normalCount).map { index in
            makeItem(
                index: index,
                kind: .text,
                updatedAt: now.addingTimeInterval(TimeInterval(-normalCount + index)),
                isFavorite: false,
                byteSize: 10
            )
        }
        let favorites = (0..<favoriteCount).map { index in
            makeItem(
                index: normalCount + index,
                kind: .image,
                updatedAt: now.addingTimeInterval(TimeInterval(index)),
                isFavorite: true,
                byteSize: 1_000
            )
        }
        return normal + favorites
    }

    private static func makeItem(
        index: Int,
        kind: ClipboardItemKind,
        updatedAt: Date,
        isFavorite: Bool,
        isPinned: Bool = false,
        byteSize: Int64
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            kind: kind,
            contentHash: "hash-\(index)",
            plainText: "item \(index)",
            assetPath: kind == .image ? "\(index).png" : nil,
            fileURLs: [],
            source: ClipboardSource(appName: nil, bundleID: nil),
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastRestoredAt: nil,
            isFavorite: isFavorite,
            isPinned: isPinned,
            byteSize: byteSize
        )
    }
}
