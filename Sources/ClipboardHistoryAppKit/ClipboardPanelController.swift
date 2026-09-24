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
    private let clearButton = NSButton()
    private let tableView = ClipboardHistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "暂无剪贴板历史")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let thumbnailLoader = ClipboardThumbnailLoader()

    private var state = ClipboardPanelState()
    private var debounceWorkItem: DispatchWorkItem?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var reloadGate = ClipboardReloadGate()
    private var isContextMenuTracking = false
    private var isClearConfirmationPresented = false

    public init(
        store: ClipboardStore,
        monitor: ClipboardMonitor,
        pasteboard: NSPasteboard = .general
    ) {
        self.store = store
        self.monitor = monitor
        self.pasteboard = pasteboard
        panel = ClipboardHistoryPanel(
            contentRect: NSRect(origin: .zero, size: ClipboardPanelLayout.defaultSize),
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
        if let attachedSheet = panel.attachedSheet {
            panel.endSheet(attachedSheet, returnCode: .alertFirstButtonReturn)
        }
        isClearConfirmationPresented = false
        panel.orderOut(nil)
    }

    public func toggle() {
        panel.isVisible ? close() : show()
    }

    public func reload() {
        performReload(hideErrorOnSuccess: true)
    }

    private func performReload(hideErrorOnSuccess: Bool) {
        debounceWorkItem?.cancel()
        guard let generation = reloadGate.beginReload() else { return }
        let query = ClipboardQuery(
            searchText: searchField.stringValue,
            filter: selectedFilter,
            limit: 500
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await store.query(query)
                let hasAnyHistory = try await !store.query(.init(limit: 1)).isEmpty
                guard reloadGate.accepts(generation) else { return }
                state.apply(
                    items: items,
                    hasAnyHistory: hasAnyHistory,
                    preservingSelection: true
                )
                tableView.reloadData()
                synchronizeSelection()
                if hideErrorOnSuccess {
                    hideError()
                }
            } catch {
                guard reloadGate.accepts(generation) else { return }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !isContextMenuTracking,
                      !isClearConfirmationPresented else { return }
                close()
            }
        }
    }

    private func buildInterface() {
        let root = NSVisualEffectView()
        ClipboardPanelStyling.apply(to: panel, root: root)
        panel.contentView = root

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        ClipboardFilterControlStyling.apply(to: filterControl)
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        ClipboardClearHistoryPresentation.apply(to: clearButton)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [searchField, filterControl, clearButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterControl.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let listContainer = buildListContainer()

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true

        let rootStack = NSStackView(views: [topRow, divider, listContainer, errorLabel])
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
            listContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            listContainer.heightAnchor.constraint(
                greaterThanOrEqualToConstant: ClipboardPanelLayout.minimumListHeight
            ),
            errorLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 26),
            clearButton.heightAnchor.constraint(equalToConstant: 24)
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

    private func installActions() {
        searchField.delegate = self
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        clearButton.target = self
        clearButton.action = #selector(clearHistoryPressed)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
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

        let isEditingSearch = searchField.currentEditor() === panel.firstResponder
        switch ClipboardPanelKeyRouter.command(
            forKeyCode: event.keyCode,
            isEditingSearch: isEditingSearch
        ) {
        case .passThrough:
            return event
        case .moveSelection(let offset):
            state.moveSelection(by: offset)
            synchronizeSelection()
            return nil
        case .restoreSelection:
            restoreSelection()
            return nil
        case .deleteSelection:
            deleteSelection()
            return nil
        case .close:
            close()
            return nil
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
        clearButton.isEnabled = state.hasAnyHistory
        guard let selectedID = state.selectedID,
              let index = state.items.firstIndex(where: { $0.id == selectedID }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    @objc private func filterChanged() {
        scheduleReload()
    }

    @objc private func tableViewDoubleClicked(_ sender: NSTableView) {
        guard state.select(row: sender.clickedRow) else { return }
        synchronizeSelection()
        restoreSelection()
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
                close()
                do {
                    try await store.markRestored(id: item.id)
                } catch {
                    NSLog("[ScreenshotTool] failed to update clipboard restore timestamp: \(error)")
                }
            } catch {
                showError(error)
            }
        }
    }

    @objc private func clearHistoryPressed() {
        guard state.hasAnyHistory, !isClearConfirmationPresented else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "所有记录（包括收藏和图片）都将被删除，此操作无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "全部清空")
        alert.buttons.last?.hasDestructiveAction = true

        isClearConfirmationPresented = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isClearConfirmationPresented = false
                guard ClipboardClearHistoryPresentation.shouldClear(after: response) else {
                    return
                }
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
                reloadGate.beginClear()
                clearButton.isEnabled = false
                do {
                    let result = try await store.clear()
                    state.apply(
                        items: [],
                        hasAnyHistory: false,
                        preservingSelection: false
                    )
                    tableView.reloadData()
                    synchronizeSelection()
                    let shouldReload = reloadGate.finishClear()
                    if result.assetCleanupFailureCount > 0 {
                        showErrorMessage("历史已清空，部分图片文件将在下次启动时继续清理")
                    } else {
                        hideError()
                    }
                    if shouldReload {
                        performReload(hideErrorOnSuccess: result.assetCleanupFailureCount == 0)
                    }
                } catch {
                    let shouldReload = reloadGate.finishClear()
                    clearButton.isEnabled = state.hasAnyHistory
                    showError(error)
                    if shouldReload {
                        performReload(hideErrorOnSuccess: false)
                    }
                }
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

    private func makeContextMenu(for row: Int) -> NSMenu? {
        guard state.items.indices.contains(row) else { return nil }
        state.select(id: state.items[row].id)
        synchronizeSelection()

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

    private func configureThumbnail(
        for item: ClipboardItem,
        presentation: ClipboardHistoryRowPresentation,
        in cell: ClipboardHistoryCellView
    ) {
        cell.thumbnailTask?.cancel()
        cell.thumbnailTask = nil
        cell.thumbnailRequestID = nil
        cell.representedItemID = item.id
        cell.showPlaceholder(
            symbolName: presentation.symbolName,
            accessibilityDescription: presentation.kindTitle
        )
        guard presentation.usesImageThumbnail else { return }

        let requestID = UUID()
        cell.thumbnailRequestID = requestID
        cell.thumbnailTask = Task { @MainActor [weak self, weak cell] in
            guard let self, let cell else { return }
            defer {
                if cell.thumbnailRequestID == requestID {
                    cell.thumbnailTask = nil
                    cell.thumbnailRequestID = nil
                }
            }
            do {
                if let cached = await thumbnailLoader.cachedThumbnail(for: item.id) {
                    guard !Task.isCancelled,
                          cell.thumbnailRequestID == requestID,
                          cell.representedItemID == item.id else { return }
                    cell.showThumbnail(NSImage(
                        cgImage: cached,
                        size: NSSize(width: cached.width, height: cached.height)
                    ))
                    return
                }

                guard let data = try await store.assetData(for: item),
                      !Task.isCancelled,
                      cell.thumbnailRequestID == requestID,
                      cell.representedItemID == item.id,
                      let decoded = await thumbnailLoader.thumbnail(
                        for: item.id,
                        data: data,
                        maximumPixelSize: 84
                      ),
                      !Task.isCancelled,
                      cell.thumbnailRequestID == requestID,
                      cell.representedItemID == item.id else {
                    return
                }
                cell.showThumbnail(NSImage(
                    cgImage: decoded,
                    size: NSSize(width: decoded.width, height: decoded.height)
                ))
            } catch {
                // Keep the photo placeholder when an old image resource is unavailable.
            }
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
        let presentation = ClipboardHistoryRowPresentation(item: item)
        cell.summaryField.stringValue = presentation.summary
        cell.summaryField.fullText = presentation.toolTip
        cell.detailField.stringValue = detail(for: item)
        configureThumbnail(for: item, presentation: presentation, in: cell)
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
    let summaryField = ClipboardHoverTextField()
    let detailField = NSTextField(labelWithString: "")
    let favoriteButton = NSButton()
    var representedItemID: UUID?
    var thumbnailRequestID: UUID?
    var thumbnailTask: Task<Void, Never>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = 7

        kindImage.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        kindImage.contentTintColor = .labelColor
        kindImage.imageScaling = .scaleProportionallyUpOrDown
        kindImage.wantsLayer = true
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
            kindImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            kindImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindImage.widthAnchor.constraint(equalToConstant: 42),
            kindImage.heightAnchor.constraint(equalToConstant: 42),
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

    func showPlaceholder(symbolName: String, accessibilityDescription: String) {
        kindImage.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        kindImage.contentTintColor = .secondaryLabelColor
        kindImage.layer?.cornerRadius = 0
        kindImage.layer?.masksToBounds = false
    }

    func showThumbnail(_ image: NSImage) {
        kindImage.image = image
        kindImage.contentTintColor = nil
        kindImage.layer?.cornerRadius = 7
        kindImage.layer?.cornerCurve = .continuous
        kindImage.layer?.masksToBounds = true
    }

    deinit {
        thumbnailTask?.cancel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
