import Foundation

/// Version and attribution metadata shared by the UI, protocol client, and
/// diagnostic summary. Values come from the built app bundle in production and
/// fall back to the source defaults when the code runs as a command-line test.
enum AppBuildInfo {
    static let fallbackVersion = "0.2.0"
    static let fallbackBuild = "1"
    static let copyright = "Copyright © 2026 sklivvz"
    static let projectURL = URL(string: "https://github.com/sklivvz/codex-reset-tray")!

    static var version: String {
        infoValue(for: "CFBundleShortVersionString") ?? fallbackVersion
    }

    static var build: String {
        infoValue(for: "CFBundleVersion") ?? fallbackBuild
    }

    private static func infoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }
}
