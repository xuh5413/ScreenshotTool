import AppKit
import ClipboardHistoryCore
import Foundation

@MainActor
public enum ClipboardPasteboardCodec {
    public static func readCandidate(
        from pasteboard: NSPasteboard,
        source: ClipboardSource,
        capturedAt: Date,
        policy: ClipboardPrivacyPolicy
    ) -> ClipboardCandidate? {
        let typeNames = pasteboardTypeNames(pasteboard)
        let preliminary = policy.decision(
            kind: .text,
            typeNames: typeNames,
            sourceBundleID: source.bundleID,
            payloadBytes: 0
        )
        switch preliminary {
        case .accept:
            break
        case .reject(.tooLarge):
            break
        case .reject:
            return nil
        }

        let payload: ClipboardPayload
        let kind: ClipboardItemKind
        let payloadBytes: Int

        if let fileURLs = readFileURLs(from: pasteboard), !fileURLs.isEmpty {
            payload = .files(fileURLs)
            kind = .files
            payloadBytes = fileURLs.reduce(0) { $0 + $1.absoluteString.utf8.count }
        } else if let png = readPNG(from: pasteboard) {
            payload = .imagePNG(png)
            kind = .image
            payloadBytes = png.count
        } else if let url = readWebURL(from: pasteboard) {
            payload = .link(url)
            kind = .link
            payloadBytes = url.absoluteString.utf8.count
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            payload = .text(string)
            kind = .text
            payloadBytes = string.utf8.count
        } else {
            return nil
        }

        guard policy.decision(
            kind: kind,
            typeNames: typeNames,
            sourceBundleID: source.bundleID,
            payloadBytes: payloadBytes
        ) == .accept else {
            return nil
        }
        return ClipboardCandidate(payload: payload, source: source, capturedAt: capturedAt)
    }

    @discardableResult
    public static func restore(
        item: ClipboardItem,
        assetData: Data?,
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            return pasteboard.setString(item.plainText, forType: .string)

        case .link:
            guard URL(string: item.plainText) != nil else { return false }
            let value = NSPasteboardItem()
            guard value.setString(item.plainText, forType: .URL),
                  value.setString(item.plainText, forType: .string) else {
                return false
            }
            return pasteboard.writeObjects([value])

        case .image:
            guard let assetData, NSImage(data: assetData) != nil else { return false }
            let value = NSPasteboardItem()
            guard value.setData(assetData, forType: .png) else { return false }
            if let tiff = NSImage(data: assetData)?.tiffRepresentation {
                _ = value.setData(tiff, forType: .tiff)
            }
            return pasteboard.writeObjects([value])

        case .files:
            guard !item.fileURLs.isEmpty else { return false }
            return pasteboard.writeObjects(item.fileURLs.map { $0 as NSURL })
        }
    }

    private static func pasteboardTypeNames(_ pasteboard: NSPasteboard) -> Set<String> {
        let itemTypes = pasteboard.pasteboardItems?.flatMap(\.types).map(\.rawValue) ?? []
        if !itemTypes.isEmpty {
            return Set(itemTypes)
        }
        return Set(pasteboard.types?.map(\.rawValue) ?? [])
    }

    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let itemURLs = pasteboard.pasteboardItems?.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else { return nil }
            return url
        } ?? []
        if !itemURLs.isEmpty {
            return itemURLs
        }

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = objects.compactMap { object -> URL? in
            guard let value = object as? NSURL else { return nil }
            let url = value as URL
            return url.isFileURL ? url : nil
        }
        return urls.isEmpty ? nil : urls
    }

    private static func readPNG(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty, NSImage(data: png) != nil {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty else {
            return nil
        }
        return png
    }

    private static func readWebURL(from pasteboard: NSPasteboard) -> URL? {
        guard let value = pasteboard.string(forType: .URL),
              let url = URL(string: value),
              !url.isFileURL else {
            return nil
        }
        return url
    }
}
