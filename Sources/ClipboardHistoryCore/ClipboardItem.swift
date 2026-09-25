import Foundation

public enum ClipboardItemKind: String, Codable, Sendable {
    case text
    case link
    case image
    case files
}

public enum ClipboardFilter: Sendable {
    case all
    case text
    case image
    case files
    case favorites
}

public struct ClipboardSource: Equatable, Sendable {
    public let appName: String?
    public let bundleID: String?

    public init(appName: String?, bundleID: String?) {
        self.appName = appName
        self.bundleID = bundleID
    }
}

public enum ClipboardPayload: Equatable, Sendable {
    case text(String)
    case link(URL)
    case imagePNG(Data)
    case files([URL])
}

public struct ClipboardCandidate: Equatable, Sendable {
    public let payload: ClipboardPayload
    public let source: ClipboardSource
    public let capturedAt: Date

    public init(payload: ClipboardPayload, source: ClipboardSource, capturedAt: Date) {
        self.payload = payload
        self.source = source
        self.capturedAt = capturedAt
    }
}

public struct NormalizedClipboardContent: Equatable, Sendable {
    public let kind: ClipboardItemKind
    public let contentHash: String
    public let plainText: String
    public let imagePNG: Data?
    public let fileURLs: [URL]
    public let source: ClipboardSource
    public let capturedAt: Date
    public let byteSize: Int64

    public init(
        kind: ClipboardItemKind,
        contentHash: String,
        plainText: String,
        imagePNG: Data?,
        fileURLs: [URL],
        source: ClipboardSource,
        capturedAt: Date,
        byteSize: Int64
    ) {
        self.kind = kind
        self.contentHash = contentHash
        self.plainText = plainText
        self.imagePNG = imagePNG
        self.fileURLs = fileURLs
        self.source = source
        self.capturedAt = capturedAt
        self.byteSize = byteSize
    }
}

public struct ClipboardItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ClipboardItemKind
    public let contentHash: String
    public let plainText: String
    public let assetPath: String?
    public let fileURLs: [URL]
    public let source: ClipboardSource
    public let createdAt: Date
    public let updatedAt: Date
    public let lastRestoredAt: Date?
    public let isFavorite: Bool
    public let isPinned: Bool
    public let byteSize: Int64

    public var isProtectedFromCleanup: Bool {
        isFavorite || isPinned
    }

    public init(
        id: UUID,
        kind: ClipboardItemKind,
        contentHash: String,
        plainText: String,
        assetPath: String?,
        fileURLs: [URL],
        source: ClipboardSource,
        createdAt: Date,
        updatedAt: Date,
        lastRestoredAt: Date?,
        isFavorite: Bool,
        isPinned: Bool = false,
        byteSize: Int64
    ) {
        self.id = id
        self.kind = kind
        self.contentHash = contentHash
        self.plainText = plainText
        self.assetPath = assetPath
        self.fileURLs = fileURLs
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRestoredAt = lastRestoredAt
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.byteSize = byteSize
    }
}

public struct ClipboardQuery: Sendable {
    public var searchText: String
    public var filter: ClipboardFilter
    public var limit: Int

    public init(searchText: String = "", filter: ClipboardFilter = .all, limit: Int = 500) {
        self.searchText = searchText
        self.filter = filter
        self.limit = limit
    }
}
