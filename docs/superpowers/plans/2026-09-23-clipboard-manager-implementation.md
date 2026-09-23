# Clipboard Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local, persistent clipboard history for text, links, images, and files, opened by `⌘⇧V` or the menu bar and restored to the system clipboard without automatic paste.

**Architecture:** Add a UI-independent `ClipboardHistoryCore` target for models, hashing, privacy and retention policies, and SQLite persistence. Add a `ClipboardHistoryAppKit` target for `NSPasteboard` encoding, monitoring, the floating panel, and the clipboard hotkey; `ScreenshotTool` owns one coordinator that connects these modules to the existing app lifecycle and menu.

**Tech Stack:** Swift 5.9, macOS 14+, AppKit, Carbon hotkeys, CryptoKit SHA-256, system SQLite3 through a SwiftPM system-library shim.

**Spec:** `docs/superpowers/specs/2026-09-23-clipboard-manager-design.md`

## Global Constraints

- Support macOS 14 and later with Swift tools version 5.9.
- Do not add third-party dependencies.
- Keep all clipboard history local; do not use networking or iCloud storage.
- Support text, links, PNG-backed images, and file URLs.
- Default limits are 500 non-favorite items, 30 days, and 1 GB of stored image assets.
- Limit text and links to 1 MB and each encoded image to 40 MB.
- Favorites are exempt from age and count eviction.
- Do not synthesize `⌘V` or request Accessibility permission.
- Preserve all existing screenshot, long screenshot, pin, save, copy, and hotkey behavior.
- Follow red-green-refactor for every production change and commit after each task.

## Review Focus

- A pasteboard containing file URLs, an image, and text at once must use the documented priority and create exactly one history item; Task 4 adds this integration check.
- Concealed or transient password-manager content must never reach the store; Task 2 and Task 4 both pin this behavior.
- Restoring a history item must not immediately capture it as a new clipboard change; Task 4 checks suppression using change counts.
- Missing image assets and moved files must render an unavailable state without crashing or deleting unrelated history; Tasks 3 and 5 add these checks.
- A corrupted or unavailable SQLite database must disable clipboard history while screenshot capture remains usable; Tasks 3 and 6 verify initialization failure isolation.

---

## File Structure

### New core files

- `Sources/CSQLite/module.modulemap` — expose system SQLite3 to SwiftPM.
- `Sources/CSQLite/shim.h` — include the SDK's `sqlite3.h`.
- `Sources/ClipboardHistoryCore/ClipboardItem.swift` — persisted item, payload, filters, and query types.
- `Sources/ClipboardHistoryCore/ClipboardContentNormalizer.swift` — canonical bytes and SHA-256 content hashes.
- `Sources/ClipboardHistoryCore/ClipboardPrivacyPolicy.swift` — sensitive type, source application, and size decisions.
- `Sources/ClipboardHistoryCore/ClipboardRetentionPolicy.swift` — deterministic eviction selection.
- `Sources/ClipboardHistoryCore/ClipboardStore.swift` — SQLite schema, queries, asset writes, mutation, and pruning.
- `Tests/ClipboardHistoryCoreChecks/ClipboardHistoryCoreChecks.swift` — executable checks for all core behavior.

### New AppKit files

- `Sources/ClipboardHistoryAppKit/ClipboardPasteboardCodec.swift` — read and restore supported `NSPasteboard` representations.
- `Sources/ClipboardHistoryAppKit/ClipboardMonitor.swift` — poll change count, filter, normalize, and persist candidates.
- `Sources/ClipboardHistoryAppKit/ClipboardPanelState.swift` — testable filtering and selection state.
- `Sources/ClipboardHistoryAppKit/ClipboardPanelController.swift` — floating panel, list, preview, mouse, and keyboard actions.
- `Sources/ClipboardHistoryAppKit/ClipboardHotkeyManager.swift` — register and unregister `⌘⇧V` through Carbon.
- `Sources/ClipboardHistoryAppKit/ClipboardHistoryStartup.swift` — injectable startup result used to isolate database failures from screenshot behavior.
- `Tests/ClipboardHistoryAppKitChecks/ClipboardHistoryAppKitChecks.swift` — named-pasteboard and panel-state integration checks.

### New application file

- `Sources/ScreenshotTool/ClipboardHistoryCoordinator.swift` — initialize storage, monitor, panel, and hotkey; expose show and shutdown operations.

### Modified files

- `Package.swift` — add system library, core, AppKit, and check targets.
- `Sources/ScreenshotTool/App.swift` — start the coordinator, add the menu item, show the panel, and shut down cleanly.
- `build.sh` — unchanged unless verification shows the new linked library is omitted; SQLite3 is a system dynamic library and should require no bundle copy.

---

### Task 1: Clipboard Models, Normalization, and Stable Hashes

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CSQLite/module.modulemap`
- Create: `Sources/CSQLite/shim.h`
- Create: `Sources/ClipboardHistoryCore/ClipboardItem.swift`
- Create: `Sources/ClipboardHistoryCore/ClipboardContentNormalizer.swift`
- Create: `Tests/ClipboardHistoryCoreChecks/ClipboardHistoryCoreChecks.swift`

**Interfaces:**
- Produces: `ClipboardPayload`, `ClipboardCandidate`, `ClipboardItem`, `ClipboardItemKind`, `ClipboardFilter`, `ClipboardQuery`.
- Produces: `ClipboardContentNormalizer.normalized(candidate:) throws -> NormalizedClipboardContent`.
- Produces: `NormalizedClipboardContent.contentHash`, `plainText`, `imagePNG`, `fileURLs`, `source`, `capturedAt`, and `byteSize`.

- [ ] **Step 1: Add core and check targets, then write failing model and hash checks**

Add these targets to `Package.swift`:

```swift
.systemLibrary(name: "CSQLite"),
.target(name: "ClipboardHistoryCore", dependencies: ["CSQLite"]),
.executableTarget(
    name: "ClipboardHistoryCoreChecks",
    dependencies: ["ClipboardHistoryCore"],
    path: "Tests/ClipboardHistoryCoreChecks"
),
```

Create the SQLite shim:

```c
// Sources/CSQLite/shim.h
#include <sqlite3.h>
```

```text
// Sources/CSQLite/module.modulemap
module CSQLite [system] {
    header "shim.h"
    link "sqlite3"
    export *
}
```

Start `ClipboardHistoryCoreChecks.swift` with real behavior checks:

```swift
import Foundation
import ClipboardHistoryCore

@main
struct ClipboardHistoryCoreChecks {
    static func main() throws {
        let source = ClipboardSource(appName: "Notes", bundleID: "com.apple.Notes")
        let first = ClipboardCandidate(payload: .text("hello\r\nworld"), source: source, capturedAt: Date(timeIntervalSince1970: 1))
        let second = ClipboardCandidate(payload: .text("hello\nworld"), source: source, capturedAt: Date(timeIntervalSince1970: 2))
        let a = try ClipboardContentNormalizer.normalized(candidate: first)
        let b = try ClipboardContentNormalizer.normalized(candidate: second)
        expect(a.contentHash == b.contentHash, "line endings must normalize before hashing")
        expect(a.plainText == "hello\nworld", "normalized text must be stored")

        let link = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .link(URL(string: "HTTPS://Example.COM/path")!), source: source, capturedAt: .now
        ))
        expect(link.kind == .link && link.plainText == "https://example.com/path", "links must have a canonical representation")

        let files = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .files([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]), source: source, capturedAt: .now
        ))
        expect(files.fileURLs.count == 2 && files.kind == .files, "file order and type must survive normalization")
        print("✅ ClipboardHistoryCoreChecks passed")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }
}
```

- [ ] **Step 2: Run the check and verify RED**

Run:

```bash
swift run ClipboardHistoryCoreChecks
```

Expected: compilation fails because `ClipboardCandidate` and `ClipboardContentNormalizer` do not exist.

- [ ] **Step 3: Implement the models and normalizer**

Use these public shapes in `ClipboardItem.swift`:

```swift
import Foundation

public enum ClipboardItemKind: String, Codable, Sendable { case text, link, image, files }
public enum ClipboardFilter: Sendable { case all, text, image, files, favorites }

public struct ClipboardSource: Equatable, Sendable {
    public let appName: String?
    public let bundleID: String?
    public init(appName: String?, bundleID: String?) { self.appName = appName; self.bundleID = bundleID }
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
        self.payload = payload; self.source = source; self.capturedAt = capturedAt
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
    public let byteSize: Int64

    public init(
        id: UUID, kind: ClipboardItemKind, contentHash: String, plainText: String,
        assetPath: String?, fileURLs: [URL], source: ClipboardSource,
        createdAt: Date, updatedAt: Date, lastRestoredAt: Date?,
        isFavorite: Bool, byteSize: Int64
    ) {
        self.id = id; self.kind = kind; self.contentHash = contentHash; self.plainText = plainText
        self.assetPath = assetPath; self.fileURLs = fileURLs; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastRestoredAt = lastRestoredAt
        self.isFavorite = isFavorite; self.byteSize = byteSize
    }
}

public struct ClipboardQuery: Sendable {
    public var searchText: String
    public var filter: ClipboardFilter
    public var limit: Int
    public init(searchText: String = "", filter: ClipboardFilter = .all, limit: Int = 500) {
        self.searchText = searchText; self.filter = filter; self.limit = limit
    }
}
```

Implement `normalized(candidate:)` with `CryptoKit.SHA256`: normalize CRLF/CR to LF, trim no user content, lowercase URL scheme and host through `URLComponents`, preserve file order, and hash a type prefix plus canonical bytes. Reject empty payloads with a typed `ClipboardNormalizationError.emptyContent`.

- [ ] **Step 4: Run the core check and verify GREEN**

Run:

```bash
swift run ClipboardHistoryCoreChecks
```

Expected: `✅ ClipboardHistoryCoreChecks passed`.

- [ ] **Step 5: Commit Task 1**

```bash
git add Package.swift Sources/CSQLite Sources/ClipboardHistoryCore Tests/ClipboardHistoryCoreChecks
git commit -m "feat: add clipboard history core models"
```

---

### Task 2: Privacy and Retention Policies

**Files:**
- Create: `Sources/ClipboardHistoryCore/ClipboardPrivacyPolicy.swift`
- Create: `Sources/ClipboardHistoryCore/ClipboardRetentionPolicy.swift`
- Modify: `Tests/ClipboardHistoryCoreChecks/ClipboardHistoryCoreChecks.swift`

**Interfaces:**
- Consumes: `ClipboardCandidate`, `ClipboardItem` from Task 1.
- Produces: `ClipboardPrivacyPolicy.decision(kind:typeNames:sourceBundleID:payloadBytes:) -> ClipboardCaptureDecision`.
- Produces: `ClipboardRetentionPolicy.evictionIDs(items:assetBytes:now:) -> [UUID]`.

- [ ] **Step 1: Add failing privacy and retention checks**

Append checks that assert exact decisions:

```swift
let privacy = ClipboardPrivacyPolicy(excludedBundleIDs: ["com.example.private"])
expect(privacy.decision(kind: .text, typeNames: ["org.nspasteboard.ConcealedType"], sourceBundleID: nil, payloadBytes: 10) == .reject(.sensitiveType), "concealed content must be rejected")
expect(privacy.decision(kind: .text, typeNames: ["public.utf8-plain-text"], sourceBundleID: "com.example.private", payloadBytes: 10) == .reject(.excludedApplication), "excluded apps must be rejected")
expect(privacy.decision(kind: .text, typeNames: ["public.utf8-plain-text"], sourceBundleID: nil, payloadBytes: 1_048_577) == .reject(.tooLarge), "oversized text must be rejected")
expect(privacy.decision(kind: .image, typeNames: ["public.png"], sourceBundleID: nil, payloadBytes: 40 * 1_024 * 1_024 + 1) == .reject(.tooLarge), "oversized images must be rejected")

let now = Date(timeIntervalSince1970: 4_000_000)
let items = makeRetentionFixtures(now: now, normalCount: 502, favoriteCount: 1)
let evictions = ClipboardRetentionPolicy.default.evictionIDs(items: items, assetBytes: 0, now: now)
expect(evictions.count == 2, "count limit must evict oldest non-favorites")
expect(!evictions.contains(items.last!.id), "favorites must survive count eviction")
```

Add `makeRetentionFixtures` in the check file with fixed dates and one favorite item so the result is deterministic.

- [ ] **Step 2: Run and verify RED**

Run `swift run ClipboardHistoryCoreChecks`.

Expected: compilation fails because both policy types are absent.

- [ ] **Step 3: Implement privacy decisions**

Define:

```swift
public enum ClipboardCaptureRejection: Equatable, Sendable { case sensitiveType, excludedApplication, tooLarge }
public enum ClipboardCaptureDecision: Equatable, Sendable { case accept, reject(ClipboardCaptureRejection) }
```

Treat these type names as sensitive: `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and `org.nspasteboard.AutoGeneratedType`. Apply 1 MB to text/link payloads and 40 MB to image payloads by passing the content kind into the decision method:

```swift
public func decision(
    kind: ClipboardItemKind,
    typeNames: Set<String>,
    sourceBundleID: String?,
    payloadBytes: Int
) -> ClipboardCaptureDecision
```

- [ ] **Step 4: Implement deterministic retention**

Define `ClipboardRetentionPolicy.default` with `maxCount = 500`, `maxAge = 30 * 24 * 60 * 60`, and `maxAssetBytes = 1_073_741_824`. Evict non-favorites older than the age first, then the oldest non-favorites until count and asset limits are satisfied. Never return a favorite ID.

- [ ] **Step 5: Run and verify GREEN**

Run `swift run ClipboardHistoryCoreChecks`.

Expected: all model, privacy, and retention checks pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/ClipboardHistoryCore Tests/ClipboardHistoryCoreChecks
git commit -m "feat: add clipboard privacy and retention policies"
```

---

### Task 3: SQLite Store and Image Asset Lifecycle

**Files:**
- Create: `Sources/ClipboardHistoryCore/ClipboardStore.swift`
- Modify: `Tests/ClipboardHistoryCoreChecks/ClipboardHistoryCoreChecks.swift`

**Interfaces:**
- Consumes: normalized content and retention policy from Tasks 1–2.
- Produces: actor `ClipboardStore` with `open`, `upsert`, `query`, `setFavorite`, `delete`, `clear`, `markRestored`, `assetData`, and `prune`.

- [ ] **Step 1: Write failing temporary-directory store checks**

Change the check entry point to `static func main() async throws`, then use a unique temporary directory and verify insert, deduplication, search, favorites, asset cleanup, missing assets, capacity admission, and corrupted database isolation:

```swift
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = ClipboardStore(
    databaseURL: root.appendingPathComponent("history.sqlite"),
    assetsDirectoryURL: root.appendingPathComponent("assets")
)
try await store.open()

let firstStored = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: first))
let duplicateStored = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: second))
expect(firstStored.id == duplicateStored.id, "duplicates must update one row")
expect(try await store.query(.init(searchText: "world")).count == 1, "search must match stored text")

let imageData = Data([0x89, 0x50, 0x4E, 0x47])
let image = try await store.upsert(try ClipboardContentNormalizer.normalized(candidate: .init(payload: .imagePNG(imageData), source: source, capturedAt: .now)))
expect(try await store.assetData(for: image) == imageData, "image asset must round-trip")
try await store.delete(id: image.id)
expect(try await store.assetData(for: image) == nil, "deleting an image must remove its asset")
```

Create a directory at a would-be database path and assert `open()` throws `ClipboardStoreError.openFailed`; do not reuse the valid store for this failure check.

- [ ] **Step 2: Run and verify RED**

Run `swift run ClipboardHistoryCoreChecks`.

Expected: compilation fails because `ClipboardStore` does not exist.

- [ ] **Step 3: Implement schema and prepared-statement helpers**

Use schema version 1:

```sql
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
);
CREATE INDEX IF NOT EXISTS clipboard_items_updated_idx ON clipboard_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS clipboard_items_kind_idx ON clipboard_items(kind);
```

Set `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`, and `PRAGMA busy_timeout=2000`. Wrap SQLite status failures in `ClipboardStoreError` with the operation and `sqlite3_errmsg` text. Finalize every statement with `defer`.

- [ ] **Step 4: Implement atomic asset and CRUD behavior**

For image upsert, write PNG bytes with `Data.write(options: .atomic)` to `<UUID>.png` before committing the row. On transaction failure, remove the newly written asset. On deduplication, preserve `id`, `createdAt`, and `isFavorite`, update source and `updatedAt`, and remove any superseded asset only after commit. Before accepting a new image, prune eligible non-favorites; if favorite assets alone leave insufficient room under the 1 GB cap, throw `ClipboardStoreError.assetCapacityExceeded` without creating a row or file so the UI can report that history storage is full.

Implement `query` using bound parameters and `LIKE` against `plain_text` and `source_app_name`. Encode file URL arrays with `JSONEncoder` and decode with `JSONDecoder`.

- [ ] **Step 5: Implement prune and orphan cleanup**

Call the retention policy with all item metadata, delete returned rows in one transaction, then delete their assets. On `open`, enumerate the assets directory and remove PNG files not referenced by any database row. Missing asset files return `nil` from `assetData(for:)` without deleting the row.

- [ ] **Step 6: Run and verify GREEN**

Run `swift run ClipboardHistoryCoreChecks`.

Expected: every core check passes, including corrupted database and missing asset cases.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/ClipboardHistoryCore/ClipboardStore.swift Tests/ClipboardHistoryCoreChecks/ClipboardHistoryCoreChecks.swift
git commit -m "feat: persist clipboard history in sqlite"
```

---

### Task 4: Pasteboard Codec and Monitor

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ClipboardHistoryAppKit/ClipboardPasteboardCodec.swift`
- Create: `Sources/ClipboardHistoryAppKit/ClipboardMonitor.swift`
- Create: `Tests/ClipboardHistoryAppKitChecks/ClipboardHistoryAppKitChecks.swift`

**Interfaces:**
- Consumes: `ClipboardStore`, `ClipboardCandidate`, and `ClipboardPrivacyPolicy`.
- Produces: `ClipboardPasteboardCodec.readCandidate(from:source:capturedAt:policy:)` and `restore(item:assetData:to:)`.
- Produces: `@MainActor ClipboardMonitor.start()`, `stop()`, `pollNow()`, and `suppress(changeCount:)`.

- [ ] **Step 1: Add the AppKit target and failing named-pasteboard checks**

Add:

```swift
.target(name: "ClipboardHistoryAppKit", dependencies: ["ClipboardHistoryCore"]),
.executableTarget(
    name: "ClipboardHistoryAppKitChecks",
    dependencies: ["ClipboardHistoryCore", "ClipboardHistoryAppKit"],
    path: "Tests/ClipboardHistoryAppKitChecks"
),
```

Write checks using `NSPasteboard(name: NSPasteboard.Name("clipboard-check-\(UUID())"))`:

Declare the check executable as `@main @MainActor` with `static func main() async throws` so it can exercise the main-actor monitor and asynchronous store APIs directly.

```swift
let board = NSPasteboard(name: .init("clipboard-check-\(UUID().uuidString)"))
board.clearContents()
board.writeObjects(["hello" as NSString])
let candidate = ClipboardPasteboardCodec.readCandidate(from: board, source: source, capturedAt: .now, policy: .default)
expect(candidate?.payload == .text("hello"), "plain text must decode")

board.clearContents()
board.writeObjects([NSURL(fileURLWithPath: "/tmp/a"), "fallback" as NSString])
let files = ClipboardPasteboardCodec.readCandidate(from: board, source: source, capturedAt: .now, policy: .default)
expect(files?.payload == .files([URL(fileURLWithPath: "/tmp/a")]), "file URLs must outrank text")

board.clearContents()
board.setString("secret", forType: .init("org.nspasteboard.ConcealedType"))
expect(ClipboardPasteboardCodec.readCandidate(from: board, source: source, capturedAt: .now, policy: .default) == nil, "concealed data must never decode")
```

Add restore round trips for text, URL, PNG image, and multiple file URLs.

- [ ] **Step 2: Run and verify RED**

Run `swift run ClipboardHistoryAppKitChecks`.

Expected: compilation fails because codec and monitor types are absent.

- [ ] **Step 3: Implement pasteboard decoding and restore priority**

Read in this order: `.fileURL` objects, TIFF/PNG image representations, URL objects, then `.string`. Convert images to PNG using `NSBitmapImageRep`. Pass type names, selected kind, source bundle ID, and byte size through the supplied `ClipboardPrivacyPolicy` before returning a candidate. Define `ClipboardPrivacyPolicy.default` with no excluded applications; the monitor injects its configured policy.

Restore with these representations:

```swift
switch item.kind {
case .text: pasteboard.setString(item.plainText, forType: .string)
case .link:
    let value = NSPasteboardItem()
    value.setString(item.plainText, forType: .URL)
    value.setString(item.plainText, forType: .string)
    pasteboard.writeObjects([value])
case .image:
    let value = NSPasteboardItem()
    value.setData(assetData, forType: .png)
    if let bitmap = NSBitmapImageRep(data: assetData),
       let tiff = bitmap.representation(using: .tiff, properties: [:]) {
        value.setData(tiff, forType: .tiff)
    }
    pasteboard.writeObjects([value])
case .files:
    pasteboard.writeObjects(item.fileURLs.map { $0 as NSURL })
}
```

Clear the pasteboard immediately before each restore. Return `false` when required data is missing or no representation succeeds. Build mixed-representation fixtures with one `NSPasteboardItem` so file, image, URL, and text representations coexist without one test write clearing another.

- [ ] **Step 4: Implement polling and self-write suppression**

`ClipboardMonitor` owns an `NSPasteboard`, a 0.35-second main-run-loop timer, `lastObservedChangeCount`, and `suppressedChangeCount`. `pollNow()` returns early for an unchanged count or one equal to the suppressed count. Capture `NSWorkspace.shared.frontmostApplication` before decoding, then enqueue normalization and store upsert in a `Task`.

Expose an `onHistoryChanged: @MainActor () -> Void` callback. A single failed item logs and continues; store initialization failure is handled by the coordinator, not the monitor.

- [ ] **Step 5: Add and pass suppression and mixed-representation checks**

Use an in-memory test store path, call `pollNow()` after a user write, assert one item, restore it through the codec, call `suppress(changeCount: board.changeCount)`, poll again, and assert the count stays one. Also place file URL, image, and text representations together and assert exactly one `.files` item.

Run:

```bash
swift run ClipboardHistoryAppKitChecks
swift run ClipboardHistoryCoreChecks
```

Expected: both print their success messages.

- [ ] **Step 6: Commit Task 4**

```bash
git add Package.swift Sources/ClipboardHistoryAppKit Tests/ClipboardHistoryAppKitChecks
git commit -m "feat: monitor and restore macos clipboard content"
```

---

### Task 5: Panel State and Mouse/Keyboard Clipboard UI

**Files:**
- Create: `Sources/ClipboardHistoryAppKit/ClipboardPanelState.swift`
- Create: `Sources/ClipboardHistoryAppKit/ClipboardPanelController.swift`
- Modify: `Tests/ClipboardHistoryAppKitChecks/ClipboardHistoryAppKitChecks.swift`

**Interfaces:**
- Consumes: `ClipboardStore.query`, mutation APIs, and `ClipboardPasteboardCodec.restore`.
- Produces: `ClipboardPanelState` selection and query transformations.
- Produces: `@MainActor ClipboardPanelController.show()`, `close()`, `toggle()`, and `reload()`.

- [ ] **Step 1: Write failing panel-state checks**

Add deterministic state checks without opening a window:

```swift
var state = ClipboardPanelState(items: [textItem, imageItem, fileItem])
expect(state.selectedID == textItem.id, "first item must be selected")
state.moveSelection(by: 1)
expect(state.selectedID == imageItem.id, "down navigation must advance")
state.moveSelection(by: 10)
expect(state.selectedID == fileItem.id, "selection must clamp at the end")
state.apply(items: [fileItem], preservingSelection: true)
expect(state.selectedID == fileItem.id, "reload must select an available item")
```

Add a missing-resource presentation check: `ClipboardPreviewModel(item:imageData:fileExists:)` must return `.unavailable("图片资源不存在")` for a missing image and `.unavailable("文件不存在")` for a stale file URL.

- [ ] **Step 2: Run and verify RED**

Run `swift run ClipboardHistoryAppKitChecks`.

Expected: compilation fails because panel state and preview model do not exist.

- [ ] **Step 3: Implement panel state and preview models**

Keep filtering in the database query; `ClipboardPanelState` only owns current items and selected ID. Preserve selection after reload when possible, otherwise select the first item. Return `nil` selection for an empty result.

Define preview cases:

```swift
public struct ClipboardFilePreviewEntry: Equatable {
    public let url: URL
    public let exists: Bool
}

public enum ClipboardPreviewModel: Equatable {
    case text(String)
    case link(URL)
    case image(Data)
    case files([ClipboardFilePreviewEntry])
    case unavailable(String)
}
```

- [ ] **Step 4: Build the floating panel with exact controls**

Create a 640 × 440 `NSPanel` subclass whose `canBecomeKey` and `canBecomeMain` return true. Build with Auto Layout:

- Top row: `NSSearchField`, five-segment `NSSegmentedControl`, and close button.
- Left 360-point `NSTableView`: type icon, summary, source app, relative time, favorite button.
- Right preview container: selectable text view, image view, or file list, plus primary “复制” button.
- Empty state: “暂无剪贴板历史”.

Set table `target` and `doubleAction` so a double click calls the same restore method as the copy button. Add a contextual `NSMenu` with “复制”, “收藏/取消收藏”, and “删除”. Single click only updates selection and preview. Observe `NSWindow.didResignKeyNotification` and close the panel when it loses focus, except while one of its own menus is tracking.

- [ ] **Step 5: Implement keyboard behavior**

Use a panel-local event monitor while visible:

```swift
switch event.keyCode {
case 126: state.moveSelection(by: -1) // up
case 125: state.moveSelection(by: 1)  // down
case 36, 76: restoreSelection()       // return / keypad enter
case 49: expandPreview()              // space
case 51, 117: deleteSelection()       // delete / forward delete
case 53: close()                      // escape
default: break
}
```

Handle `⌘F` by making the search field first responder. Remove the event monitor every time the panel closes.

- [ ] **Step 6: Wire asynchronous store mutations and error states**

Search and filter changes debounce for 120 ms, then call `store.query`. Favorite, delete, and clear use `Task`, reload on success, and show a non-modal inline error label on failure. Surface `assetCapacityExceeded` as “剪贴板历史空间已满，请删除收藏图片”. Restore fetches asset data when needed, writes with the codec, calls `monitor.suppress(changeCount:)`, marks the item restored, and closes only on success.

- [ ] **Step 7: Run checks and a compile-only UI verification**

Run:

```bash
swift run ClipboardHistoryAppKitChecks
swift build -c release --product ScreenshotTool
```

Expected: AppKit checks pass and the full app compiles without warnings or errors.

- [ ] **Step 8: Commit Task 5**

```bash
git add Sources/ClipboardHistoryAppKit Tests/ClipboardHistoryAppKitChecks
git commit -m "feat: add searchable clipboard history panel"
```

---

### Task 6: Clipboard Hotkey and Application Integration

**Files:**
- Create: `Sources/ClipboardHistoryAppKit/ClipboardHotkeyManager.swift`
- Create: `Sources/ClipboardHistoryAppKit/ClipboardHistoryStartup.swift`
- Create: `Sources/ScreenshotTool/ClipboardHistoryCoordinator.swift`
- Modify: `Sources/ScreenshotTool/App.swift`
- Modify: `Package.swift`
- Modify: `Tests/ClipboardHistoryAppKitChecks/ClipboardHistoryAppKitChecks.swift`

**Interfaces:**
- Consumes: monitor, store, and panel from Tasks 3–5.
- Produces: `ClipboardHotkeyManager.register(action:) -> Bool` and `unregister()`.
- Produces: `ClipboardHistoryStartup.start(storeFactory:)` with an injectable store factory and an explicit unavailable result.
- Produces: `@MainActor ClipboardHistoryCoordinator.start() async throws`, `showPanel()`, and `shutdown()`.

- [ ] **Step 1: Add failing hotkey routing and coordinator failure-isolation checks**

Extract a pure event-ID router so Carbon dispatch can be checked:

```swift
var fired = false
let router = ClipboardHotkeyActionRouter(expectedID: 2) { fired = true }
router.handle(id: 1)
expect(!fired, "screenshot hotkey ID must not trigger clipboard history")
router.handle(id: 2)
expect(fired, "clipboard hotkey ID must trigger clipboard history")
```

Add `ClipboardHistoryStartup` in the AppKit target with a store factory dependency. Pass a closure that throws `ClipboardStoreError.openFailed("fixture")`, then assert startup returns an unavailable result. The application coordinator will consume this result without invoking or changing any screenshot callback; keeping this boundary in the library makes it testable without depending on the executable target.

- [ ] **Step 2: Run and verify RED**

Run `swift run ClipboardHistoryAppKitChecks`.

Expected: compilation fails because hotkey routing and coordinator-facing availability types do not exist.

- [ ] **Step 3: Implement the clipboard hotkey**

Register Carbon key code `0x09` (`V`) with `cmdKey | shiftKey`, signature `0x434C4950`, and hotkey ID `2`. The manager owns its `EventHotKeyRef`, `EventHandlerRef`, and callback closure. Return `false` when registration fails and always unregister/remove the handler in `deinit`.

- [ ] **Step 4: Implement the coordinator**

`ClipboardHistoryStartup` computes:

```swift
let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ScreenshotTool/ClipboardHistory", isDirectory: true)
```

It opens `history.sqlite`, starts `ClipboardMonitor`, creates one `ClipboardPanelController`, and registers the hotkey. `ClipboardHistoryCoordinator` owns the successful startup result and exposes the application-facing methods. If hotkey registration fails, keep monitor and menu entry available and expose `hotkeyAvailable = false`. `shutdown()` stops the monitor, unregisters the hotkey, and closes the panel.

- [ ] **Step 5: Integrate lifecycle and menu without changing screenshot behavior**

Add one optional property to `AppDelegate`:

```swift
private var clipboardHistoryCoordinator: ClipboardHistoryCoordinator?
```

In `applicationDidFinishLaunching`, start it in a `Task { @MainActor in ... }` after `setupMenuBar()`. Insert “剪贴板历史… (⌘⇧V)” after the capture item and point it at:

```swift
@objc private func showClipboardHistory() {
    clipboardHistoryCoordinator?.showPanel()
}
```

If initialization fails, leave screenshot features active, disable the menu item, and set its tooltip to “剪贴板历史初始化失败”. Call `shutdown()` from `applicationWillTerminate` before unregistering existing screenshot resources.

Update the `ScreenshotTool` target dependencies to include `ClipboardHistoryCore` and `ClipboardHistoryAppKit`.

- [ ] **Step 6: Run all checks and verify menu/hotkey compilation**

Run:

```bash
swift run ClipboardHistoryCoreChecks
swift run ClipboardHistoryAppKitChecks
swift run ScreenshotToolbarChecks
swift run LongScreenshotCoreChecks
swift run LongScreenshotImageChecks
swift build -c release --product ScreenshotTool
```

Expected: every executable check prints success and the Release product builds.

- [ ] **Step 7: Commit Task 6**

```bash
git add Package.swift Sources/ClipboardHistoryAppKit/ClipboardHotkeyManager.swift Sources/ClipboardHistoryAppKit/ClipboardHistoryStartup.swift Sources/ScreenshotTool/ClipboardHistoryCoordinator.swift Sources/ScreenshotTool/App.swift Tests/ClipboardHistoryAppKitChecks
git commit -m "feat: integrate clipboard history with app lifecycle"
```

---

### Task 7: Manual Interaction QA, Cleanup, and Release Installation

**Files:**
- Modify only files required by failures found during this task.
- Verify: `build.sh`, `截图工具.app`, `/Applications/截图工具.app`.

**Interfaces:**
- Consumes: the completed feature from Tasks 1–6.
- Produces: a signed installed Release bundle with all automated and manual checks recorded.

- [ ] **Step 1: Run a clean automated verification pass**

Run:

```bash
swift build -c release --product ScreenshotTool
swift run ClipboardHistoryCoreChecks
swift run ClipboardHistoryAppKitChecks
swift run ScreenshotToolbarChecks
swift run LongScreenshotCoreChecks
swift run LongScreenshotImageChecks
git diff --check
```

Expected: every command exits 0, all check executables print success, and `git diff --check` has no output.

- [ ] **Step 2: Launch a development build and verify the primary flow**

With no sensitive information on the clipboard, verify in order:

1. Copy plain text, a URL, a screenshot image, and two Finder files.
2. Press `⌘⇧V`; confirm the same 640 × 440 panel opens each time.
3. Search each type and apply every filter.
4. Single-click to preview; double-click to restore; paste manually into a safe test document.
5. Open from the menu bar and confirm it reuses the same panel.
6. Favorite an item, delete another, and confirm the favorite survives an explicit prune fixture.
7. Move a recorded file and confirm the preview reports “文件不存在”.
8. Copy concealed test data on a named pasteboard integration path and confirm it is absent from the store.

- [ ] **Step 3: Verify regression flows**

Perform one normal screenshot, one annotated screenshot using the tapered arrow, one long screenshot, one pin, one save, and one copy. Confirm the existing screenshot hotkey still triggers only screenshots and `⌘⇧V` triggers only clipboard history.

- [ ] **Step 4: Build and install the Release application**

Run:

```bash
./build.sh release
codesign --verify --deep --strict /Applications/截图工具.app
shasum -a 256 截图工具.app/Contents/MacOS/ScreenshotTool /Applications/截图工具.app/Contents/MacOS/ScreenshotTool
```

Expected: signature verification exits 0 and both executable hashes match.

- [ ] **Step 5: Commit final QA fixes**

If Step 2 or Step 3 required code changes, first add a failing automated check for each discovered defect, then fix it and commit only those files:

```bash
git add Package.swift Sources Tests
git commit -m "fix: address clipboard history qa findings"
```

If no files changed, record the verification results in the final implementation report and do not create an empty commit.
