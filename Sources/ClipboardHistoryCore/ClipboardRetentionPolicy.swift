import Foundation

public struct ClipboardRetentionPolicy: Sendable {
    public static let `default` = ClipboardRetentionPolicy(
        maxCount: 500,
        maxAge: 30 * 24 * 60 * 60,
        maxAssetBytes: 1_073_741_824
    )

    public let maxCount: Int
    public let maxAge: TimeInterval
    public let maxAssetBytes: Int64

    public init(maxCount: Int, maxAge: TimeInterval, maxAssetBytes: Int64) {
        self.maxCount = max(0, maxCount)
        self.maxAge = max(0, maxAge)
        self.maxAssetBytes = max(0, maxAssetBytes)
    }

    public func evictionIDs(
        items: [ClipboardItem],
        assetBytes: Int64,
        now: Date
    ) -> [UUID] {
        let eligible = items
            .filter { !$0.isFavorite }
            .sorted(by: isOlder)
        let expirationDate = now.addingTimeInterval(-maxAge)
        var evicted = Set<UUID>()
        var result: [UUID] = []

        func append(_ item: ClipboardItem) {
            guard evicted.insert(item.id).inserted else { return }
            result.append(item.id)
        }

        for item in eligible where item.updatedAt < expirationDate {
            append(item)
        }

        var remainingCount = eligible.count - evicted.count
        if remainingCount > maxCount {
            for item in eligible where !evicted.contains(item.id) {
                guard remainingCount > maxCount else { break }
                append(item)
                remainingCount -= 1
            }
        }

        var remainingAssetBytes = max(0, assetBytes)
        for item in items where evicted.contains(item.id) && item.kind == .image {
            remainingAssetBytes = max(0, remainingAssetBytes - item.byteSize)
        }
        if remainingAssetBytes > maxAssetBytes {
            for item in eligible where item.kind == .image && !evicted.contains(item.id) {
                guard remainingAssetBytes > maxAssetBytes else { break }
                append(item)
                remainingAssetBytes = max(0, remainingAssetBytes - item.byteSize)
            }
        }

        return result
    }

    private func isOlder(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
