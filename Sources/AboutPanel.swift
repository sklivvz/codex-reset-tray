import AppKit

/// What the controller needs to open the native About panel. Tests inject a
/// recorder so they never display a panel or create an application window.
@MainActor
protocol AboutPresenting: AnyObject {
    func show()
}

/// Presents AppKit's standard About panel with the name, icon, version, and
/// build read from the app bundle (and the source fallbacks in command-line
/// tests). `panelOptions()` is internal so tests can verify the configuration
/// without ordering the panel onscreen.
@MainActor
final class AboutPanelPresenter: AboutPresenting {
    private let appIconProvider: @MainActor () -> NSImage?

    init(
        appIconProvider: @escaping @MainActor () -> NSImage? = {
            TrayStatusIcon.bundledAppIcon()
        }
    ) {
        self.appIconProvider = appIconProvider
    }

    func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: panelOptions())
    }

    func panelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSAttributedString(
            string: "\(AppBuildInfo.copyright)\n\(AppBuildInfo.projectURL.absoluteString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppBuildInfo.name,
            .applicationVersion: AppBuildInfo.version,
            .version: AppBuildInfo.build,
            .credits: credits,
        ]
        if let icon = appIconProvider() {
            options[.applicationIcon] = icon
        }
        return options
    }
}
