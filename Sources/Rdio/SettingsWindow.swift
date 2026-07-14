import AppKit
import SwiftUI

/// Hosts the SwiftUI settings UI (full-height sidebar + detail) in a window
/// styled like a standard macOS settings pane.
///
/// The window + hosting controller + SwiftUI tree are rebuilt on each `show`
/// and torn down on `windowWillClose` so the ~1.8 MB places cache and the
/// view tree are reclaimed when the window isn't needed. The `SettingsModel`
/// (small until places load) persists across opens so playback state and
/// editable stations survive a close-reopen.
final class SettingsWindowController: NSObject {
    let model: SettingsModel
    private var windowController: NSWindowController?

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    @MainActor
    func show(tab: SettingsTab) {
        model.selectedTab = tab
        model.reloadStationsFromDisk()
        if windowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Rdio Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.delegate = self
            window.center()
            let controller = NSWindowController(window: window)
            windowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        model.windowIsVisible = true
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.windowIsVisible = false
            model.releaseMapCache()
            windowController = nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(model: model).frame(width: 200)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.nowPlayingStation != nil {
                Divider()
                NowPlayingBar(model: model)
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .ignoresSafeArea()
    }

    @ViewBuilder private var detail: some View {
        switch model.selectedTab {
        case .stations: StationsPage(model: model)
        case .design: DesignPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

/// Bar across the foot of the window whenever a station is loaded: what's on
/// air, transport, and a heart — the only way to keep a station that Surprise Me
/// picked, since it never touched My Stations.
private struct NowPlayingBar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isPlaying ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.system(size: 15))
                .foregroundStyle(model.isPlaying ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.nowPlayingStation?.name ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(model.nowPlayingTrack ?? (model.isPlaying ? "Playing" : "Paused"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            HoverButton(symbol: model.isNowPlayingFavorite ? "heart.fill" : "heart",
                        help: model.isNowPlayingFavorite
                            ? "Remove from My Stations" : "Add to My Stations") {
                model.toggleFavoriteNowPlaying()
            }
            HoverButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", help: "Play/Pause") {
                model.togglePlayPauseHandler?()
            }
            HoverButton(symbol: "forward.fill", help: "Next station") {
                model.nextStationHandler?()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 42)  // clear the traffic lights + match Stats' rhythm
            ForEach(SettingsTab.allCases) { tab in
                SidebarRow(tab: tab, isSelected: model.selectedTab == tab) {
                    model.selectedTab = tab
                }
            }
            Spacer()
            SidebarToolbar()
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

/// Bottom-of-sidebar utility strip: bug/coffee/quit. Playback lives in the
/// now-playing bar across the foot of the window.
private struct SidebarToolbar: View {
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 2) {
            button(symbol: "ladybug", id: "bug", help: "Report a bug") {
                NSWorkspace.shared.open(UpdateChecker.issuesURL)
            }
            button(symbol: "heart.fill", id: "coffee", help: "Buy me a coffee") {
                NSWorkspace.shared.open(AppLinks.coffee)
            }
            button(symbol: "power", id: "quit", help: "Quit Rdio") {
                NSApp.terminate(nil)
            }
            Spacer()
        }
    }

    private func button(symbol: String, id: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .foregroundStyle(hovered == id ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered == id ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
        .help(help)
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(tab.title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor
                          : (hovered ? Color.primary.opacity(0.08) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Shared page scaffold: a large title, then the content, with consistent
/// padding that clears the transparent title bar.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 16)
                .padding(.horizontal, 20)
                .padding(.bottom, 2)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Design page

struct DesignPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(title: "Design") {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Idle icon") {
                    HStack(spacing: 10) {
                        ForEach(IdleIcon.options) { option in
                            IdleIconChip(option: option,
                                         isSelected: model.idleIcon == option.symbol) {
                                model.idleIcon = option.symbol
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("While playing") {
                    Picker("Animation", selection: $model.iconStyle) {
                        Text("Spectrum").tag(IconStyle.spectrum)
                        Text("Ripple").tag(IconStyle.ripple)
                        Text("Pulse").tag(IconStyle.pulse)
                        Text("None").tag(IconStyle.off)
                    }
                    .pickerStyle(.menu)

                    Stepper("Bars: \(model.barCount)", value: $model.barCount, in: 3...8)
                        .disabled(model.iconStyle == .off)

                    LabeledContent("Preview") { IconPreview(model: model) }

                    Toggle("Show track title in the menu bar", isOn: $model.showNowPlayingText)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct IdleIconChip: View {
    let option: IdleIcon.Option
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17))
                    .frame(width: 48, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.22)
                              : (hovered ? Color.primary.opacity(0.08) : Color.clear)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3)))
                Text(option.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // the whole chip, box and caption alike, is the click target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A rendition of the icon, holding a still frame until the pointer is over it,
/// so a style can be previewed in motion without the preview redrawing the whole
/// settings tree the rest of the time.
struct IconPreview: View {
    @ObservedObject var model: SettingsModel
    @State private var isHovering = false

    /// The pattern at its widest — the 3...8 stepper's maximum. Held at all
    /// times so the row doesn't resize as the bar count or style changes.
    private static let width: CGFloat = 8 * 5 + 7 * 3
    /// Matches the height of a stock control, so the preview's row is the same
    /// height as the picker and stepper rows above it.
    private static let height: CGFloat = 22

    var body: some View {
        Group {
            // windowIsVisible also covers closing the window (⌘W) while the
            // pointer sits on the preview, which leaves no hover to exit.
            if isHovering && model.windowIsVisible {
                TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
                    bars(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(at: 0)
            }
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private func bars(at t: Double) -> some View {
        HStack(alignment: .center, spacing: 3) {
            if model.iconStyle == .off {
                Image(systemName: model.idleIcon).font(.system(size: 16))
            } else {
                ForEach(0..<model.barCount, id: \.self) { bar in
                    Capsule()
                        .frame(width: 5,
                               height: 4 + previewLevel(t: t, bar: bar, of: model.barCount) * 16)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
    }

    private func previewLevel(t: Double, bar: Int, of count: Int) -> CGFloat {
        let value: Double
        switch model.iconStyle {
        case .pulse:
            let overall = 0.5 + 0.4 * sin(t * 2.2)
            let center = Double(count - 1) / 2
            value = overall * (1 - 0.45 * abs(Double(bar) - center) / max(center, 1))
        case .ripple:
            value = 0.5 + 0.45 * sin(t * 2.6 - Double(bar) * 0.9)
        default:
            value = 0.5 + 0.4 * sin(t * (1.7 + Double(bar) * 0.9) + Double(bar) * 1.3)
        }
        return CGFloat(min(max(value, 0), 1))
    }
}

// MARK: - About page

struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(title: "About") {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 88, height: 88)
                        Text("Rdio").font(.title2.bold())
                        Text("Version \(UpdateChecker.currentVersion)")
                            .foregroundStyle(.secondary)
                        Button("Check for Update") {
                            Task { await model.checkForUpdates() }
                        }
                        .padding(.top, 4)
                        if !model.updateStatus.isEmpty {
                            Text(model.updateStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle("Check for updates automatically", isOn: $model.autoUpdateCheck)
                    Toggle("Start at login", isOn: $model.launchAtLogin)
                    if let error = model.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Link(destination: AppLinks.coffee) {
                        Label("Buy me a coffee", systemImage: "heart.fill")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task {
            if model.autoUpdateCheck, model.updateStatus.isEmpty {
                await model.checkForUpdates()
            }
        }
    }
}
