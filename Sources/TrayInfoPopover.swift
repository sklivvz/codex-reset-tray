import AppKit

/// The compact information popover's content. It is a plain `NSView`, so tests
/// can build it, feed it models, and inspect or render it without ever creating
/// a popover.
@MainActor
final class TrayInfoView: NSView {
    static let contentWidth: CGFloat = 340
    private static let inset: CGFloat = 20
    private static let forecastSpacing: CGFloat = 12
    static let forecastValueFontSize: CGFloat = 36

    private let iconView = NSImageView()
    private let titleField = TrayInfoView.makeLabel(size: 15, weight: .semibold)
    private let usageValueField = TrayInfoView.makeLabel(
        size: 34,
        weight: .semibold,
        monospacedDigits: true
    )
    private let usageCaptionField = TrayInfoView.makeLabel(size: 12, weight: .regular)
    private let meter = NSProgressIndicator()
    private let forecastHeading = TrayInfoView.makeLabel(size: 12, weight: .semibold)
    private let forecastFiguresStack = NSStackView()
    private let forecastStatusField = TrayInfoView.makeStatusField()
    private var forecastValueFields: [NSTextField] = []
    private var forecastCaptionFields: [NSTextField] = []
    private var forecastColumns: [NSStackView] = []
    private(set) var model: TrayInfoModel?
    private(set) var updateCount = 0

    init(appIcon: NSImage?) {
        super.init(frame: .zero)

        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
        ])

        let titles = NSStackView(views: [titleField])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let header = NSStackView(views: [iconView, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        meter.style = .bar
        meter.isIndeterminate = false
        meter.minValue = 0
        meter.maxValue = 1
        meter.translatesAutoresizingMaskIntoConstraints = false

        let usage = NSStackView(views: [usageValueField, usageCaptionField, meter])
        usage.orientation = .vertical
        usage.alignment = .leading
        usage.spacing = 4
        usage.setCustomSpacing(8, after: usageCaptionField)

        forecastHeading.stringValue = "Reset forecast"
        configureForecastFigures()
        forecastStatusField.isHidden = true

        let forecast = NSStackView(views: [
            forecastHeading,
            forecastFiguresStack,
            forecastStatusField,
        ])
        forecast.orientation = .vertical
        forecast.alignment = .leading
        forecast.spacing = 6
        forecast.setCustomSpacing(10, after: forecastHeading)

        let root = NSStackView(views: [header, usage, forecast])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(
            top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset
        )
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let contentWidth = Self.contentWidth - 2 * Self.inset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Both the meter and the two forecast columns span the content
            // width rather than the width of the short labels above them.
            meter.widthAnchor.constraint(equalToConstant: contentWidth),
            forecastFiguresStack.widthAnchor.constraint(equalToConstant: contentWidth),
            forecastStatusField.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        setAccessibilityLabel("Codex Reset Tray details")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrayInfoView is created in code")
    }

    func update(with model: TrayInfoModel) {
        self.model = model
        updateCount += 1

        titleField.stringValue = model.title
        usageValueField.stringValue = model.usageValue
        usageCaptionField.stringValue = model.usageCaption
        if let fraction = model.usageFraction {
            meter.doubleValue = fraction
            meter.isHidden = false
            meter.setAccessibilityLabel("7-day Codex usage")
            meter.setAccessibilityValueDescription(model.usageValue)
        } else {
            meter.isHidden = true
        }

        for (index, figure) in model.forecastFigures.enumerated() {
            guard index < forecastValueFields.count else { break }
            forecastValueFields[index].stringValue = figure.value
            forecastCaptionFields[index].stringValue = figure.caption
        }
        forecastFiguresStack.toolTip = model.forecastToolTip

        if let status = model.forecastStatus {
            forecastStatusField.stringValue = status.text
            forecastStatusField.textColor = status.tone == .error
                ? TrayPalette.error
                : .labelColor
            forecastStatusField.toolTip = model.forecastToolTip
            forecastStatusField.isHidden = false
        } else {
            forecastStatusField.stringValue = ""
            forecastStatusField.toolTip = nil
            forecastStatusField.isHidden = true
        }
        layoutSubtreeIfNeeded()
    }

    /// The meter's value, or `nil` while it is hidden. Used by offscreen tests.
    var meterFraction: Double? { meter.isHidden ? nil : meter.doubleValue }

    /// Laid-out meter width. Used by offscreen tests to verify it spans the
    /// content area instead of only the usage text stack.
    var meterWidth: CGFloat { meter.frame.width }

    /// Every text currently shown, in reading order. Used by offscreen tests.
    var renderedTexts: [String] {
        var texts: [String] = []
        collectTexts(in: self, into: &texts)
        return texts
    }

    /// The label showing `text`, if any. Used by offscreen tests to check color.
    func field(showing text: String) -> NSTextField? {
        findField(in: self) { $0.stringValue == text }
    }

    /// Laid-out forecast values and captions. Used by offscreen tests to verify
    /// both probabilities and the absence of the old sentence.
    var forecastValues: [String] { forecastValueFields.map(\.stringValue) }
    var forecastCaptions: [String] { forecastCaptionFields.map(\.stringValue) }
    var forecastValueFontSizes: [CGFloat] {
        forecastValueFields.map { $0.font?.pointSize ?? 0 }
    }

    /// Laid-out forecast column frames. Used to prove the figures are actually
    /// side by side and share the content width.
    var forecastColumnFrames: [NSRect] { forecastColumns.map(\.frame) }

    /// The visible loading/stale/error line, if any.
    var forecastStatusText: String? {
        forecastStatusField.isHidden ? nil : forecastStatusField.stringValue
    }

    var forecastStatusColor: NSColor? {
        forecastStatusField.isHidden ? nil : forecastStatusField.textColor
    }

    private func configureForecastFigures() {
        forecastFiguresStack.orientation = .horizontal
        forecastFiguresStack.alignment = .top
        forecastFiguresStack.distribution = .fillEqually
        forecastFiguresStack.spacing = Self.forecastSpacing

        for _ in 0..<2 {
            let value = Self.makeLabel(
                size: Self.forecastValueFontSize,
                weight: .semibold,
                monospacedDigits: true
            )
            value.alignment = .center
            let caption = Self.makeLabel(size: 12, weight: .regular)
            caption.alignment = .center

            let column = NSStackView(views: [value, caption])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 2
            forecastColumns.append(column)
            forecastValueFields.append(value)
            forecastCaptionFields.append(caption)
            forecastFiguresStack.addArrangedSubview(column)
        }
        forecastFiguresStack.setAccessibilityLabel("Reset forecast probabilities")
    }

    private func collectTexts(in view: NSView, into texts: inout [String]) {
        if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty {
            texts.append(field.stringValue)
        }
        for subview in view.subviews {
            collectTexts(in: subview, into: &texts)
        }
    }

    private func findField(in view: NSView, where match: (NSTextField) -> Bool) -> NSTextField? {
        if let field = view as? NSTextField, match(field) { return field }
        for subview in view.subviews {
            if let found = findField(in: subview, where: match) { return found }
        }
        return nil
    }

    /// Single-line label in the normal label color. Nothing here is secondary
    /// or disabled gray: loading, stale, and error state lines use the normal
    /// label color or the readable error color.
    private static func makeLabel(
        size: CGFloat,
        weight: NSFont.Weight,
        monospacedDigits: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func makeStatusField() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = NSFont.systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.preferredMaxLayoutWidth = contentWidth - 2 * inset
        field.isSelectable = true
        return field
    }
}

/// What the controller needs from whatever shows the information panel.
/// Production uses a transient `NSPopover` anchored to the status button; tests
/// inject a recorder so no popover is ever created or shown.
@MainActor
protocol TrayInfoPresenting: AnyObject {
    var isShown: Bool { get }
    func show(_ model: TrayInfoModel, relativeTo statusButton: NSStatusBarButton)
    func update(_ model: TrayInfoModel)
    func hide()
}

/// Shows `TrayInfoView` in a transient popover anchored to the status item's
/// button, so it follows the menu-bar item instead of floating above the app.
@MainActor
final class TrayInfoPopoverPresenter: TrayInfoPresenting {
    /// AppKit anchors the popover below the status item for `.minY`.
    static let preferredEdge: NSRectEdge = .minY

    private let appIconProvider: @MainActor () -> NSImage?
    private(set) var popover: NSPopover?
    private(set) var contentView: TrayInfoView?
    /// The button and rectangle most recently passed to `NSPopover.show`.
    private(set) var anchorButton: NSStatusBarButton?
    private(set) var anchorRect: NSRect?

    init(appIconProvider: @escaping @MainActor () -> NSImage?) {
        self.appIconProvider = appIconProvider
    }

    var isShown: Bool { popover?.isShown ?? false }

    func show(_ model: TrayInfoModel, relativeTo statusButton: NSStatusBarButton) {
        let (popover, contentView) = preparePopover()
        contentView.update(with: model)
        popover.contentSize = contentView.fittingSize
        anchorButton = statusButton
        anchorRect = statusButton.bounds
        NSApp.activate(ignoringOtherApps: true)
        guard !popover.isShown else { return }
        popover.show(
            relativeTo: statusButton.bounds,
            of: statusButton,
            preferredEdge: Self.preferredEdge
        )
    }

    func update(_ model: TrayInfoModel) {
        guard let popover, let contentView, popover.isShown else { return }
        contentView.update(with: model)
        popover.contentSize = contentView.fittingSize
    }

    func hide() {
        guard let popover else { return }
        // `performClose(_:)` only attempts to close and can decline when the
        // popover hosts a nested popover or its window is a child window.
        // `close()` is the force-close path; it starts the close asynchronously,
        // so the controller waits for `isShown` to become false (woken by
        // `NSPopover.didCloseNotification`) before presenting a menu.
        popover.close()
    }

    /// Builds the native popover on first use. Internal so the offscreen tests
    /// can inspect its configuration without displaying it.
    func preparePopover() -> (NSPopover, TrayInfoView) {
        if let popover, let contentView { return (popover, contentView) }

        let contentView = TrayInfoView(appIcon: appIconProvider())
        let controller = NSViewController()
        controller.view = contentView

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = contentView.fittingSize

        self.popover = popover
        self.contentView = contentView
        return (popover, contentView)
    }
}
