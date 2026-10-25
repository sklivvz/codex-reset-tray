import AppKit

/// Colors shared by the menu and the information popover. Errors need to stay
/// readable on both light and dark menu/popover backgrounds, which the stock
/// `systemOrange` is not on a light background.
enum TrayPalette {
    static let error = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.18, blue: 0.0, alpha: 1)
    }
}

/// Which asset a status icon was derived from.
enum TrayStatusIconSource: Equatable {
    /// A template mask derived from the packaged `AppIcon.icns` foreground.
    case appIcon
    /// An SF Symbol template, used only when the app icon is unavailable.
    case systemSymbol
    /// The built-in drawn bar chart, used only when SF Symbols is unavailable.
    case drawn
}

struct TrayStatusBaseImage {
    let image: NSImage
    let source: TrayStatusIconSource
}

/// Geometry of the status item: an icon followed by a fixed, compact gap and
/// then the optional usage label.
enum TrayStatusLayout {
    static let iconSide: CGFloat = 18
    /// Space between the icon's right edge and the label's left edge.
    static let labelGap: CGFloat = 4
    static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static func labelWidth(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let size = (text as NSString).size(withAttributes: [.font: labelFont])
        return ceil(size.width)
    }

    /// Canvas the button draws as its image. It reserves room for the label,
    /// which is a sibling view, so the status item sizes itself around both.
    static func canvasSize(labelWidth: CGFloat) -> NSSize {
        let extra = labelWidth > 0 ? labelGap + labelWidth : 0
        return NSSize(width: iconSide + extra, height: iconSide)
    }

    static func iconRect(in canvas: NSSize) -> NSRect {
        NSRect(x: 0, y: (canvas.height - iconSide) / 2, width: iconSide, height: iconSide)
    }
}

enum TrayStatusIcon {
    /// The icon packaged in the app bundle (`Contents/Resources/AppIcon.icns`,
    /// copied from `Resources/AppIcon.icns` by build.sh).
    static func bundledAppIcon(bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.resourceURL?.appendingPathComponent("AppIcon.icns"),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    static func baseImage(appIcon: NSImage?, symbolName: String) -> TrayStatusBaseImage {
        if let appIcon, let glyph = monochromeGlyph(from: appIcon) {
            return TrayStatusBaseImage(image: glyph, source: .appIcon)
        }
        if let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Codex Reset Tray"
        ) {
            return TrayStatusBaseImage(image: symbol, source: .systemSymbol)
        }
        return TrayStatusBaseImage(image: drawnFallback(), source: .drawn)
    }

    /// Draws the glyph at the left of a canvas sized for icon plus label.
    /// AppKit tints the template image for the current menu-bar appearance.
    static func canvasImage(base: TrayStatusBaseImage, canvas: NSSize) -> NSImage {
        let source = base.image
        let target = fit(source.size, in: TrayStatusLayout.iconRect(in: canvas))
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(
                in: target,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The packaged icon has an opaque blue tile. Using its alpha directly as
    /// a template would produce a solid square, hiding the white chart/reset
    /// glyph. The lowest RGB component separates near-white foreground strokes
    /// from the saturated blue tile; a short ramp retains antialiased edges.
    private static func monochromeGlyph(from icon: NSImage) -> NSImage? {
        guard icon.isValid, icon.size.width > 0, icon.size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: 72,
                  pixelsHigh: 72,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 72, height: 72).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
        NSGraphicsContext.restoreGraphicsState()

        guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel == 4 else { return nil }
        var visiblePixels = 0
        for y in 0..<72 {
            for x in 0..<72 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = min(color.redComponent, color.greenComponent, color.blueComponent)
                let strength = max(0, min(1, (brightness - 0.45) / 0.35))
                    * color.alphaComponent
                if strength > 0.01 { visiblePixels += 1 }
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
                bytes[offset + 3] = UInt8((strength * 255).rounded())
            }
        }
        guard visiblePixels > 0 else { return nil }
        bitmap.size = NSSize(width: TrayStatusLayout.iconSide, height: TrayStatusLayout.iconSide)
        let glyph = NSImage(size: bitmap.size)
        glyph.addRepresentation(bitmap)
        glyph.isTemplate = true
        return glyph
    }

    private static func fit(_ size: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: rect.minX + (rect.width - fitted.width) / 2,
            y: rect.minY + (rect.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func drawnFallback() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let heights: [CGFloat] = [5, 9, 13]
            for (index, height) in heights.enumerated() {
                let bar = NSRect(x: 3 + CGFloat(index) * 6, y: 3, width: 3, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
            return !rect.isEmpty
        }
        image.isTemplate = true
        return image
    }
}

/// Draws the usage text beside the icon without NSStatusBarButton's own,
/// wider image-title gap. It never intercepts clicks, so the whole status item
/// remains one click target.
@MainActor
final class TrayStatusLabelView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: TrayStatusLayout.labelWidth(for: text),
            height: ceil(TrayStatusLayout.labelFont.ascender - TrayStatusLayout.labelFont.descender)
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TrayStatusLayout.labelFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: 0, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

/// How a click on the status item is interpreted.
enum TrayStatusClick: Equatable {
    /// Left click: show the anchored information popover.
    case primary
    /// Right click (or control-click): show the actions menu.
    case secondary

    static func classify(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> TrayStatusClick {
        switch type {
        case .rightMouseDown, .rightMouseUp:
            return .secondary
        case .leftMouseDown, .leftMouseUp:
            return modifiers.contains(.control) ? .secondary : .primary
        default:
            return .primary
        }
    }

    static func classify(_ event: NSEvent?) -> TrayStatusClick {
        guard let event else { return .primary }
        return classify(type: event.type, modifiers: event.modifierFlags)
    }
}
