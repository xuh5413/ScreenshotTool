import AppKit
import ClipboardHistoryCore
import Foundation

@MainActor
public final class ClipboardPanelController: NSObject {
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let pasteboard: NSPasteboard
    private let panel: ClipboardHistoryPanel

    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(
        labels: ["全部", "文字", "图片", "文件", "收藏"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let closeButton = NSButton()
    private let tableView = ClipboardHistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "暂无剪贴板历史")
    private let previewTitle = NSTextField(labelWithString: "预览")
    private let previewTextView = NSTextView()
    private let previewTextScroll = NSScrollView()
    private let previewImageView = NSImageView()
    private let previewPlaceholder = NSTextField(wrappingLabelWithString: "选择一条记录查看内容")
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var state = ClipboardPanelState()
    private var debounceWorkItem: DispatchWorkItem?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var queryGeneration = 0
    private var previewGeneration = 0
    private var isContextMenuTracking = false
    private var isExpanded = false

    public init(
        store: ClipboardStore,
        monitor: ClipboardMonitor,
        pasteboard: NSPasteboard = .general
    ) {
        self.store = store
        self.monitor = monitor
        self.pasteboard = pasteboard
        panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildInterface()
        installActions()

        monitor.onHistoryChanged = { [weak self] in
            guard self?.panel.isVisible == true else { return }
            self?.reload()
        }
        monitor.onError = { [weak self] error in
            self?.showError(error)
        }
    }

    deinit {
        debounceWorkItem?.cancel()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    public func show() {
        if !panel.isVisible {
            panel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEventMonitorIfNeeded()
        reload()
    }

    public func close() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        removeEventMonitor()
        panel.orderOut(nil)
    }

    public func toggle() {
        panel.isVisible ? close() : show()
    }

    public func reload() {
        debounceWorkItem?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        let query = ClipboardQuery(
            searchText: searchField.stringValue,
            filter: selectedFilter,
            limit: 500
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await store.query(query)
                guard generation == queryGeneration else { return }
                state.apply(items: items, preservingSelection: true)
                tableView.reloadData()
                synchronizeSelection()
                updatePreview()
                hideError()
            } catch {
                showError(error)
            }
        }
    }

    private var selectedFilter: ClipboardFilter {
        switch filterControl.selectedSegment {
        case 1: return .text
        case 2: return .image
        case 3: return .files
        case 4: return .favorites
        default: return .all
        }
    }

    private func configurePanel() {
        panel.title = "剪贴板历史"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !isContextMenuTracking else { return }
                close()
            }
        }
    }

    private func buildInterface() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        panel.contentView = root

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        filterControl.selectedSegment = 0
        filterControl.segmentStyle = .rounded
        filterControl.controlSize = .small
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.toolTip = "关闭"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [searchField, filterControl, closeButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterControl.setContentHuggingPriority(.required, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let listContainer = buildListContainer()
        let previewContainer = buildPreviewContainer()
        let verticalDivider = NSBox()
        verticalDivider.boxType = .separator
        verticalDivider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            verticalDivider.widthAnchor.constraint(equalToConstant: 1),
            listContainer.widthAnchor.constraint(equalToConstant: 360)
        ])

        let contentRow = NSStackView(views: [listContainer, verticalDivider, previewContainer])
        contentRow.orientation = .horizontal
        contentRow.alignment = .top
        contentRow.spacing = 10
        contentRow.distribution = .fill
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listContainer.heightAnchor.constraint(equalTo: contentRow.heightAnchor),
            verticalDivider.heightAnchor.constraint(equalTo: contentRow.heightAnchor),
            previewContainer.heightAnchor.constraint(equalTo: contentRow.heightAnchor)
        ])

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true

        let rootStack = NSStackView(views: [topRow, divider, contentRow, errorLabel])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            rootStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            topRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            contentRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            contentRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            errorLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func buildListContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func buildPreviewContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        previewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewTitle)

        let previewBody = NSView()
        previewBody.wantsLayer = true
        previewBody.layer?.cornerRadius = 8
        previewBody.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        previewBody.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewBody)

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.font = .systemFont(ofSize: 13)
        previewTextView.textContainerInset = NSSize(width: 8, height: 8)
        previewTextScroll.documentView = previewTextView
        previewTextScroll.hasVerticalScroller = true
        previewTextScroll.drawsBackground = false
        previewTextScroll.translatesAutoresizingMaskIntoConstraints = false
        previewBody.addSubview(previewTextScroll)

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewBody.addSubview(previewImageView)

        previewPlaceholder.textColor = .secondaryLabelColor
        previewPlaceholder.alignment = .center
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewBody.addSubview(previewPlaceholder)

        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyButton)

        NSLayoutConstraint.activate([
            previewTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewTitle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewTitle.topAnchor.constraint(equalTo: container.topAnchor),
            previewBody.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewBody.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewBody.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8),
            previewBody.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            previewTextScroll.leadingAnchor.constraint(equalTo: previewBody.leadingAnchor),
            previewTextScroll.trailingAnchor.constraint(equalTo: previewBody.trailingAnchor),
            previewTextScroll.topAnchor.constraint(equalTo: previewBody.topAnchor),
            previewTextScroll.bottomAnchor.constraint(equalTo: previewBody.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewBody.leadingAnchor, constant: 8),
            previewImageView.trailingAnchor.constraint(equalTo: previewBody.trailingAnchor, constant: -8),
            previewImageView.topAnchor.constraint(equalTo: previewBody.topAnchor, constant: 8),
            previewImageView.bottomAnchor.constraint(equalTo: previewBody.bottomAnchor, constant: -8),
            previewPlaceholder.leadingAnchor.constraint(equalTo: previewBody.leadingAnchor, constant: 10),
            previewPlaceholder.trailingAnchor.constraint(equalTo: previewBody.trailingAnchor, constant: -10),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewBody.centerYAnchor)
        ])
        renderNoSelection()
        return container
    }

    private func installActions() {
        searchField.delegate = self
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        copyButton.target = self
        copyButton.action = #selector(restoreSelection)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(restoreSelection)
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeContextMenu(for: row)
        }
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return handleKeyDown(event)
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            panel.makeFirstResponder(searchField)
            return nil
        }

        if searchField.currentEditor() === panel.firstResponder,
           (event.keyCode == 51 || event.keyCode == 117) {
            return event
        }

        switch event.keyCode {
        case 126:
            state.moveSelection(by: -1)
            synchronizeSelection()
            updatePreview()
            return nil
        case 125:
            state.moveSelection(by: 1)
            synchronizeSelection()
            updatePreview()
            return nil
        case 36, 76:
            restoreSelection()
            return nil
        case 49:
            expandPreview()
            return nil
        case 51, 117:
            deleteSelection()
            return nil
        case 53:
            close()
            return nil
        default:
            return event
        }
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func synchronizeSelection() {
        emptyLabel.isHidden = !state.items.isEmpty
        guard let selectedID = state.selectedID,
              let index = state.items.firstIndex(where: { $0.id == selectedID }) else {
            tableView.deselectAll(nil)
            copyButton.isEnabled = false
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        copyButton.isEnabled = true
    }

    private func updatePreview() {
        previewGeneration += 1
        let generation = previewGeneration
        guard let item = state.selectedItem else {
            renderNoSelection()
            return
        }

        if item.kind == .image {
            showPreviewPlaceholder("正在加载图片…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let data = try await store.assetData(for: item)
                    guard generation == previewGeneration, state.selectedID == item.id else { return }
                    render(ClipboardPreviewModel(item: item, imageData: data, fileExists: fileExists))
                } catch {
                    guard generation == previewGeneration else { return }
                    showError(error)
                    render(.unavailable("图片资源不存在"))
                }
            }
        } else {
            render(ClipboardPreviewModel(item: item, imageData: nil, fileExists: fileExists))
        }
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func render(_ model: ClipboardPreviewModel) {
        previewTextScroll.isHidden = true
        previewImageView.isHidden = true
        previewPlaceholder.isHidden = true
        previewImageView.image = nil

        switch model {
        case .text(let value):
            previewTitle.stringValue = "文字"
            previewTextView.string = value
            previewTextScroll.isHidden = false
        case .link(let url):
            previewTitle.stringValue = "链接"
            previewTextView.string = url.absoluteString
            previewTextScroll.isHidden = false
        case .image(let data):
            previewTitle.stringValue = "图片"
            if let image = NSImage(data: data) {
                previewImageView.image = image
                previewImageView.isHidden = false
            } else {
                showPreviewPlaceholder("图片无法预览")
            }
        case .files(let entries):
            previewTitle.stringValue = "文件"
            previewTextView.string = entries.map { entry in
                "\(entry.exists ? "✓" : "⚠︎")  \(entry.url.path)"
            }.joined(separator: "\n\n")
            previewTextScroll.isHidden = false
        case .unavailable(let message):
            previewTitle.stringValue = "预览"
            showPreviewPlaceholder(message)
        }
    }

    private func renderNoSelection() {
        copyButton.isEnabled = false
        previewTitle.stringValue = "预览"
        showPreviewPlaceholder("选择一条记录查看内容")
    }

    private func showPreviewPlaceholder(_ message: String) {
        previewTextScroll.isHidden = true
        previewImageView.isHidden = true
        previewPlaceholder.stringValue = message
        previewPlaceholder.isHidden = false
    }

    @objc private func filterChanged() {
        scheduleReload()
    }

    @objc private func closePressed() {
        close()
    }

    @objc private func restoreSelection() {
        guard let item = state.selectedItem else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = item.kind == .image ? try await store.assetData(for: item) : nil
                guard ClipboardPasteboardCodec.restore(item: item, assetData: asset, to: pasteboard) else {
                    showErrorMessage("无法复制此条记录")
                    return
                }
                monitor.suppress(changeCount: pasteboard.changeCount)
                try await store.markRestored(id: item.id)
                close()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func toggleFavoriteFromButton(_ sender: NSButton) {
        guard state.items.indices.contains(sender.tag) else { return }
        toggleFavorite(state.items[sender.tag])
    }

    @objc private func toggleFavoriteFromMenu() {
        guard let item = state.selectedItem else { return }
        toggleFavorite(item)
    }

    private func toggleFavorite(_ item: ClipboardItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.setFavorite(id: item.id, isFavorite: !item.isFavorite)
                reload()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func deleteSelection() {
        guard let item = state.selectedItem else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.delete(id: item.id)
                reload()
            } catch {
                showError(error)
            }
        }
    }

    private func expandPreview() {
        var frame = panel.frame
        let targetHeight: CGFloat = isExpanded ? 440 : 620
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        panel.setFrame(frame, display: true, animate: true)
        isExpanded.toggle()
    }

    private func makeContextMenu(for row: Int) -> NSMenu? {
        guard state.items.indices.contains(row) else { return nil }
        state.select(id: state.items[row].id)
        synchronizeSelection()
        updatePreview()

        let menu = NSMenu(title: "剪贴板记录")
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "复制", action: #selector(restoreSelection), keyEquivalent: ""))
        let favoriteTitle = state.items[row].isFavorite ? "取消收藏" : "收藏"
        menu.addItem(NSMenuItem(title: favoriteTitle, action: #selector(toggleFavoriteFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "删除", action: #selector(deleteSelection), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    private func showError(_ error: Error) {
        if case ClipboardStoreError.assetCapacityExceeded = error {
            showErrorMessage("剪贴板历史空间已满，请删除收藏图片")
        } else {
            showErrorMessage("操作失败：\(error.localizedDescription)")
        }
    }

    private func showErrorMessage(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func hideError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    private func summary(for item: ClipboardItem) -> String {
        let value = item.plainText.replacingOccurrences(of: "\n", with: " ")
        return value.isEmpty ? kindTitle(item.kind) : value
    }

    private func kindTitle(_ kind: ClipboardItemKind) -> String {
        switch kind {
        case .text: return "文字"
        case .link: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    private func symbolName(for kind: ClipboardItemKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    private func detail(for item: ClipboardItem) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: item.updatedAt, relativeTo: Date())
        let source = item.source.appName ?? "未知应用"
        return "\(source) · \(relative)"
    }
}

extension ClipboardPanelController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        scheduleReload()
    }
}

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        state.items.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ClipboardHistoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ClipboardHistoryCellView)
            ?? ClipboardHistoryCellView(identifier: identifier)
        let item = state.items[row]
        cell.kindImage.image = NSImage(systemSymbolName: symbolName(for: item.kind), accessibilityDescription: kindTitle(item.kind))
        cell.summaryField.stringValue = summary(for: item)
        cell.detailField.stringValue = detail(for: item)
        cell.favoriteButton.image = NSImage(
            systemSymbolName: item.isFavorite ? "star.fill" : "star",
            accessibilityDescription: item.isFavorite ? "取消收藏" : "收藏"
        )
        cell.favoriteButton.contentTintColor = item.isFavorite ? .systemYellow : .secondaryLabelColor
        cell.favoriteButton.tag = row
        cell.favoriteButton.target = self
        cell.favoriteButton.action = #selector(toggleFavoriteFromButton(_:))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        state.select(id: state.items.indices.contains(row) ? state.items[row].id : nil)
        updatePreview()
    }
}

extension ClipboardPanelController: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        isContextMenuTracking = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        isContextMenuTracking = false
        if panel.isVisible {
            panel.makeKey()
        }
    }
}

private final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ClipboardHistoryTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        return contextMenuProvider?(clickedRow)
    }
}

private final class ClipboardHistoryCellView: NSTableCellView {
    let kindImage = NSImageView()
    let summaryField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let favoriteButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = 7

        kindImage.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        kindImage.contentTintColor = .labelColor
        kindImage.translatesAutoresizingMaskIntoConstraints = false

        summaryField.font = .systemFont(ofSize: 13, weight: .medium)
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.maximumNumberOfLines = 1
        summaryField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false

        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .inline
        favoriteButton.toolTip = "收藏"
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(kindImage)
        addSubview(summaryField)
        addSubview(detailField)
        addSubview(favoriteButton)
        NSLayoutConstraint.activate([
            kindImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            kindImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindImage.widthAnchor.constraint(equalToConstant: 23),
            kindImage.heightAnchor.constraint(equalToConstant: 23),
            favoriteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            favoriteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteButton.widthAnchor.constraint(equalToConstant: 26),
            favoriteButton.heightAnchor.constraint(equalToConstant: 26),
            summaryField.leadingAnchor.constraint(equalTo: kindImage.trailingAnchor, constant: 10),
            summaryField.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: -8),
            summaryField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detailField.leadingAnchor.constraint(equalTo: summaryField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: summaryField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
