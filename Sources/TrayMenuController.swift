import AppKit
import Combine

/// The menu's data source. `ResetStore` is the production implementation; the
/// runtime harness supplies a deterministic in-memory source.
@MainActor
protocol TrayMenuSource: AnyObject {
    var menuState: TrayMenuState { get }
    var menuBarTitle: String { get }
    var menuBarSystemImage: String { get }
    var showsUsageInMenuBar: Bool { get }
    var changePublisher: AnyPublisher<Void, Never> { get }
    func setShowsUsageInMenuBar(_ visible: Bool)
    func menuDidOpen()
    func refreshAll() async
}

/// The piece of AppKit the controller needs from a status item. Production uses
/// an `NSStatusItem`; tests use an unmounted button so no menu-bar item is ever
/// created.
@MainActor
protocol TrayStatusItemHost: AnyObject {
    var isVisible: Bool { get set }
    var statusButton: NSStatusBarButton? { get }
    /// Shows `menu` under the status item, as a right click does. Production
    /// attaches the menu just long enough to open it; tests only record it.
    func popUp(_ menu: NSMenu)
}

extension ResetStore: TrayMenuSource {
    var changePublisher: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }
}

@MainActor
final class TrayMenuController: NSObject, NSMenuDelegate {
    private let source: any TrayMenuSource
    private let statusItem: any TrayStatusItemHost
    let menu: NSMenu
    private let terminate: @MainActor () -> Void
    private let openURL: @MainActor (URL) -> Void
    private let writeToPasteboard: @MainActor (String) -> Void
    private let appIconProvider: @MainActor () -> NSImage?
    private let currentEvent: @MainActor () -> NSEvent?
    private let infoPresenter: any TrayInfoPresenting
    private var cancellable: AnyCancellable?
    private var statusEventMonitor: Any?
    private var isMenuOpen = false
    /// Whether the transient popover was shown when the current status-button
    /// left-click began. `.transient` can close it before the mouse-up action
    /// runs, so the action must still treat that click as the closing half of
    /// the toggle.
    private var infoPopoverWasShownOnMouseDown = false
    let statusLabelView = TrayStatusLabelView()
    private var statusLabelLeading: NSLayoutConstraint?
    /// Which asset the current status icon was derived from.
    private(set) var statusIconSource: TrayStatusIconSource = .appIcon

    /// Production entry point. The only AppKit objects created here are the
    /// system status item and its menu, exactly as before the injectable
    /// initializer was introduced.
    convenience init(store: ResetStore) {
        self.init(
            source: store,
            statusItem: SystemStatusItemHost(),
            menu: NSMenu()
        )
    }

    init(
        source: any TrayMenuSource,
        statusItem: any TrayStatusItemHost,
        menu: NSMenu,
        terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        appIconProvider: @escaping @MainActor () -> NSImage? = { TrayStatusIcon.bundledAppIcon() },
        infoPresenter: (any TrayInfoPresenting)? = nil,
        currentEvent: @escaping @MainActor () -> NSEvent? = { NSApp.currentEvent },
        writeToPasteboard: @escaping @MainActor (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.source = source
        self.statusItem = statusItem
        self.menu = menu
        self.terminate = terminate
        self.openURL = openURL
        self.appIconProvider = appIconProvider
        self.currentEvent = currentEvent
        self.infoPresenter = infoPresenter ?? TrayInfoPopoverPresenter(appIconProvider: appIconProvider)
        self.writeToPasteboard = writeToPasteboard
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        menu.setAccessibilityLabel("Codex Reset Tray menu")
        menu.setAccessibilityHelp("Codex usage, forecast, and app actions.")

        statusItem.isVisible = true

        if let button = statusItem.statusButton {
            // NSStatusBarButton's own image+title gap is too wide and not
            // configurable, so the button draws only the icon canvas and the
            // usage text is a sibling view placed a fixed TrayStatusLayout.labelGap
            // after the icon. The button title stays empty to prevent AppKit
            // from silently switching imageOnly back to imageLeading.
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.font = TrayStatusLayout.labelFont
            button.setAccessibilityLabel("Codex Reset Tray")
            // The status item has no attached menu: a left click opens the
            // anchored information popover and a right click opens the actions
            // menu. NSCell action masks track ordinary left clicks. A local
            // event monitor catches secondary mouse-down before
            // NSStatusBarButton's own tracking can discard it.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp])
            statusEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                guard let self, self.handleStatusMouseDown(event) else { return event }
                return nil
            }
            statusLabelView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusLabelView)
            let leading = statusLabelView.leadingAnchor.constraint(equalTo: button.centerXAnchor)
            statusLabelLeading = leading
            NSLayoutConstraint.activate([
                leading,
                statusLabelView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }

        updateStatusButton()
        apply(TrayMenuModel.make(state: source.menuState))

        // @Published emits before the value changes, so render on the next main
        // run-loop turn. The menu is rebuilt while closed and updated in place
        // while open; changing its item list during menu tracking is avoided.
        cancellable = source.changePublisher.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusButton()
                self.apply(TrayMenuModel.make(state: self.source.menuState))
                self.refreshInfoPopover()
            }
        }
    }

    deinit {
        if let statusEventMonitor {
            NSEvent.removeMonitor(statusEventMonitor)
        }
    }

    /// Whether the information popover is currently shown.
    var isInfoPopoverShown: Bool { infoPresenter.isShown }

    /// Left click toggles the information popover; right click (or
    /// control-click) opens the actions menu.
    func handleStatusClick(_ click: TrayStatusClick) {
        switch click {
        case .primary:
            toggleInfoPopover()
        case .secondary:
            showActionsMenu()
        }
    }

    private func toggleInfoPopover() {
        let wasShownBeforeClick = infoPopoverWasShownOnMouseDown
        infoPopoverWasShownOnMouseDown = false
        if infoPresenter.isShown {
            infoPresenter.hide()
            return
        }
        if wasShownBeforeClick {
            // The transient popover already closed itself when this click
            // began; this is the hiding half of the toggle, not a new open.
            return
        }
        guard let statusButton = statusItem.statusButton else { return }
        // Same forecast-on-click behavior as opening the menu (debounced by
        // the store), so the popover never opens with a stale forecast.
        source.menuDidOpen()
        infoPresenter.show(
            TrayInfoModel.make(state: source.menuState),
            relativeTo: statusButton
        )
    }

    private func showActionsMenu() {
        guard !isMenuOpen else { return }
        // Rebuild now: menuNeedsUpdate is not guaranteed to run before the
        // first tracking pass of a menu that is attached on demand.
        apply(TrayMenuModel.make(state: source.menuState))
        statusItem.popUp(menu)
    }

    private func refreshInfoPopover() {
        guard infoPresenter.isShown else { return }
        infoPresenter.update(TrayInfoModel.make(state: source.menuState))
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        handleStatusClick(TrayStatusClick.classify(currentEvent()))
    }

    /// Records whether a primary click began while the transient popover was
    /// visible. `.transient` may close it during the mouse-down, before the
    /// button's mouse-up action runs.
    private func recordInfoPopoverState(before event: NSEvent) {
        guard event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control),
              statusButtonContains(event) else {
            return
        }
        infoPopoverWasShownOnMouseDown = infoPresenter.isShown
    }

    /// Returns true only for secondary clicks inside this status button. The
    /// caller consumes those events so AppKit cannot also dispatch a click.
    func handleStatusMouseDown(_ event: NSEvent) -> Bool {
        recordInfoPopoverState(before: event)
        guard event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              statusButtonContains(event) else {
            return false
        }
        handleStatusClick(.secondary)
        return true
    }

    private func statusButtonContains(_ event: NSEvent) -> Bool {
        guard let button = statusItem.statusButton,
              let window = button.window,
              event.windowNumber == window.windowNumber else {
            return false
        }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // This delegate callback runs while the menu is about to appear, before
        // menu tracking starts, so rebuilding here cannot replace an open menu.
        guard !isMenuOpen else { return }
        apply(TrayMenuModel.make(state: source.menuState))
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Preserve forecast-on-click behavior: the store debounces these fetches.
        source.menuDidOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        apply(TrayMenuModel.make(state: source.menuState))
    }

    private func updateStatusButton() {
        guard let button = statusItem.statusButton else { return }
        // The image assignment is unconditional: hiding the usage text must
        // never hide the menu-bar icon.
        let title = source.menuBarTitle
        let labelWidth = TrayStatusLayout.labelWidth(for: title)
        let base = TrayStatusIcon.baseImage(
            appIcon: appIconProvider(),
            symbolName: source.menuBarSystemImage
        )
        statusIconSource = base.source
        let canvas = TrayStatusLayout.canvasSize(labelWidth: labelWidth)
        button.image = TrayStatusIcon.canvasImage(base: base, canvas: canvas)
        button.title = ""
        button.imagePosition = .imageOnly
        statusLabelView.text = title
        statusLabelView.isHidden = title.isEmpty
        // The button centers the canvas image, so anchor the label relative to
        // the button's center: canvas left edge + icon width + gap.
        statusLabelLeading?.constant = -canvas.width / 2
            + TrayStatusLayout.iconSide + TrayStatusLayout.labelGap
        if source.menuBarTitle.isEmpty {
            button.toolTip = "Codex Reset Tray — usage text hidden in the menu bar. Left-click for details, right-click for actions."
        } else {
            button.toolTip = "Codex Reset Tray — \(source.menuBarTitle). Left-click for details, right-click for actions."
        }
        button.setAccessibilityLabel(
            TrayMenuModel.accessibilityDescription(for: source.menuState)
        )
        button.setAccessibilityHelp(
            "Click to show Codex usage details. Right-click to open the actions menu."
        )
    }

    private func apply(_ model: TrayMenuModel) {
        if isMenuOpen {
            // Never replace an open menu's item list. The model keeps a stable
            // row order, so updating titles in place is enough.
            if menu.items.count == model.items.count {
                updateOpenMenu(with: model)
            }
            return
        }
        rebuildMenu(with: model)
    }

    private func rebuildMenu(with model: TrayMenuModel) {
        menu.removeAllItems()
        for item in model.items {
            menu.addItem(makeMenuItem(for: item))
        }
    }

    private func updateOpenMenu(with model: TrayMenuModel) {
        for (menuItem, item) in zip(menu.items, model.items) {
            guard item.role != .separator else { continue }
            menuItem.isEnabled = item.isEnabled
            menuItem.toolTip = item.toolTip
            menuItem.state = item.isChecked ? .on : .off
            style(menuItem, as: item)
        }
    }

    private func makeMenuItem(for item: TrayMenuItem) -> NSMenuItem {
        if item.role == .separator {
            return .separator()
        }

        let menuItem = NSMenuItem(title: item.title, action: selector(for: item.role), keyEquivalent: "")
        menuItem.target = menuItem.action == nil ? nil : self
        menuItem.isEnabled = item.isEnabled
        menuItem.toolTip = item.toolTip
        menuItem.state = item.isChecked ? .on : .off

        switch item.role {
        case .action(.refresh):
            menuItem.keyEquivalent = "r"
            menuItem.keyEquivalentModifierMask = [.command]
        case .action(.copyStatus):
            menuItem.keyEquivalent = "c"
            menuItem.keyEquivalentModifierMask = [.command]
        case .action(.quit):
            menuItem.keyEquivalent = "q"
            menuItem.keyEquivalentModifierMask = [.command]
        default:
            break
        }

        style(menuItem, as: item)
        return menuItem
    }

    private func style(_ menuItem: NSMenuItem, as item: TrayMenuItem) {
        menuItem.attributedTitle = nil
        switch item.role {
        case .heading:
            menuItem.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        default:
            if item.tone == .error {
                menuItem.attributedTitle = NSAttributedString(
                    string: item.title,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: TrayPalette.error,
                    ]
                )
            } else {
                menuItem.title = item.title
            }
        }
    }

    private func selector(for role: TrayMenuItemRole) -> Selector? {
        switch role {
        case .action(.refresh):
            return #selector(refresh)
        case .action(.copyStatus):
            return #selector(copyStatus)
        case .action(.toggleMenuBarUsage):
            return #selector(toggleMenuBarUsage)
        case .action(.openWebsite):
            return #selector(openWebsite)
        case .action(.donate):
            return #selector(donate)
        case .action(.quit):
            return #selector(quit)
        default:
            return nil
        }
    }

    @objc private func refresh(_ sender: NSMenuItem) {
        Task { await source.refreshAll() }
    }

    @objc private func copyStatus(_ sender: NSMenuItem) {
        writeToPasteboard(TrayMenuModel.statusSummary(for: source.menuState))
    }

    @objc private func toggleMenuBarUsage(_ sender: NSMenuItem) {
        source.setShowsUsageInMenuBar(!source.showsUsageInMenuBar)
        // Apply immediately so the check mark and status item update without
        // waiting for the publisher's next main-run-loop turn.
        updateStatusButton()
        apply(TrayMenuModel.make(state: source.menuState))
    }

    @objc private func openWebsite(_ sender: NSMenuItem) {
        openURL(Self.websiteURL)
    }

    @objc private func donate(_ sender: NSMenuItem) {
        openURL(TrayMenuModel.donationURL)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        terminate()
    }

    private static var websiteURL: URL {
        TrayMenuModel.websiteURL
    }
}

@MainActor
final class SystemStatusItemHost: TrayStatusItemHost {
    private let item: NSStatusItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    var statusButton: NSStatusBarButton? {
        item.button
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func popUp(_ menu: NSMenu) {
        guard let button = item.button else { return }
        // Pop up the menu directly. Attaching it temporarily and calling
        // performClick can end tracking before the menu is displayed.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
    }
}
