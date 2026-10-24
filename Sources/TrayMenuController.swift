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
    var menu: NSMenu? { get set }
    var statusButton: NSButton? { get }
}

extension NSStatusItem: TrayStatusItemHost {
    var statusButton: NSButton? { button }
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
    private var cancellable: AnyCancellable?
    private var isMenuOpen = false

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
        self.writeToPasteboard = writeToPasteboard
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        menu.setAccessibilityLabel("Codex Reset Tray menu")
        menu.setAccessibilityHelp("Codex usage, forecast, and app actions.")

        statusItem.isVisible = true
        statusItem.menu = menu

        if let button = statusItem.statusButton {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.setAccessibilityLabel("Codex Reset Tray")
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
            }
        }
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
        button.image = StatusItemIcon.image(symbolName: source.menuBarSystemImage)
        button.title = source.menuBarTitle
        if source.menuBarTitle.isEmpty {
            button.toolTip = "Codex Reset Tray — usage text hidden in the menu bar. Click for usage, forecast, and actions."
        } else {
            button.toolTip = "Codex Reset Tray — \(source.menuBarTitle). Click for usage, forecast, and actions."
        }
        button.setAccessibilityLabel(
            TrayMenuModel.accessibilityDescription(for: source.menuState)
        )
        button.setAccessibilityHelp("Open the Codex Reset Tray menu.")
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
                        .foregroundColor: NSColor.systemOrange,
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

    @objc private func quit(_ sender: NSMenuItem) {
        terminate()
    }

    private static var websiteURL: URL {
        TrayMenuModel.websiteURL
    }
}

@MainActor
private final class SystemStatusItemHost: TrayStatusItemHost {
    private let item: NSStatusItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    var menu: NSMenu? {
        get { item.menu }
        set { item.menu = newValue }
    }

    var statusButton: NSButton? {
        item.button
    }
}

@MainActor
private enum StatusItemIcon {
    static func image(symbolName: String) -> NSImage {
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Codex Reset Tray") {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        return fallbackImage()
    }

    /// A menu bar icon must not disappear if SF Symbols is unavailable. This
    /// template image is a small bar chart and is always drawable.
    private static func fallbackImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let barWidth: CGFloat = 3
            let baseline: CGFloat = 3
            let heights: [CGFloat] = [5, 9, 13]
            for (index, height) in heights.enumerated() {
                let x = 3 + CGFloat(index) * 6
                let bar = NSRect(x: x, y: baseline, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
            return !rect.isEmpty
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
