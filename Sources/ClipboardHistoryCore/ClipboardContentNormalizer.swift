import CryptoKit
import Foundation

public enum ClipboardNormalizationError: Error, Equatable, Sendable {
    case emptyContent
    case invalidURL
}

public enum ClipboardContentNormalizer {
    public static func normalized(candidate: ClipboardCandidate) throws -> NormalizedClipboardContent {
        switch candidate.payload {
        case .text(let value):
            guard !value.isEmpty else { throw ClipboardNormalizationError.emptyContent }
            let normalized = normalizeLineEndings(value)
            let bytes = Data(normalized.utf8)
            return makeContent(
                kind: .text,
                canonicalBytes: bytes,
                plainText: normalized,
                candidate: candidate
            )

        case .link(let url):
            let canonical = try canonicalURLString(url)
            guard !canonical.isEmpty else { throw ClipboardNormalizationError.emptyContent }
            let bytes = Data(canonical.utf8)
            return makeContent(
                kind: .link,
                canonicalBytes: bytes,
                plainText: canonical,
                candidate: candidate
            )

        case .imagePNG(let data):
            guard !data.isEmpty else { throw ClipboardNormalizationError.emptyContent }
            return makeContent(
                kind: .image,
                canonicalBytes: data,
                plainText: "图片",
                imagePNG: data,
                candidate: candidate
            )

        case .files(let urls):
            guard !urls.isEmpty else { throw ClipboardNormalizationError.emptyContent }
            let canonicalStrings = urls.map { $0.standardizedFileURL.absoluteString }
            let bytes = lengthPrefixedBytes(canonicalStrings)
            let searchableText = urls
                .map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
                .joined(separator: " ")
            return makeContent(
                kind: .files,
                canonicalBytes: bytes,
                plainText: searchableText,
                fileURLs: urls,
                candidate: candidate
            )
        }
    }

    private static func makeContent(
        kind: ClipboardItemKind,
        canonicalBytes: Data,
        plainText: String,
        imagePNG: Data? = nil,
        fileURLs: [URL] = [],
        candidate: ClipboardCandidate
    ) -> NormalizedClipboardContent {
        var hashInput = Data(kind.rawValue.utf8)
        hashInput.append(0)
        hashInput.append(canonicalBytes)
        let digest = SHA256.hash(data: hashInput)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        return NormalizedClipboardContent(
            kind: kind,
            contentHash: hash,
            plainText: plainText,
            imagePNG: imagePNG,
            fileURLs: fileURLs,
            source: candidate.source,
            capturedAt: candidate.capturedAt,
            byteSize: Int64(canonicalBytes.count)
        )
    }

    private static func normalizeLineEndings(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func canonicalURLString(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil else {
            throw ClipboardNormalizationError.invalidURL
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        guard let canonical = components.url?.absoluteString else {
            throw ClipboardNormalizationError.invalidURL
        }
        return canonical
    }

    private static func lengthPrefixedBytes(_ values: [String]) -> Data {
        var result = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }
}
