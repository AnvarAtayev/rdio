import AppKit
import Sparkle

/// Bridges the app to Sparkle, but only self-updates when that's the right
/// thing to do: a directly-downloaded `.app` bundle. Homebrew casks are
/// upgraded with `brew`, and a bare `swift run` binary has no bundle for
/// Sparkle to replace — both skip Sparkle and fall back to a version check.
@MainActor
final class AppUpdater {
    enum Kind {
        case sparkle    // direct download — Sparkle downloads and installs updates
        case homebrew   // installed via `brew install --cask` — defer to brew
        case unsupported  // bare dev binary, no .app bundle to update
    }

    let kind: Kind
    private let controller: SPUStandardUpdaterController?

    init() {
        let bundleURL = Bundle.main.bundleURL
        let resolved = bundleURL.resolvingSymlinksInPath().path
        if bundleURL.pathExtension != "app" {
            kind = .unsupported
        } else if resolved.contains("/Caskroom/") {
            kind = .homebrew
        } else {
            kind = .sparkle
        }
        // Starting the updater kicks off Sparkle's scheduled background checks.
        controller = kind == .sparkle
            ? SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Whether Sparkle checks for updates on its schedule. No-op unless Sparkle
    /// is driving updates.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// User-initiated check. Sparkle presents its own progress and install UI.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
