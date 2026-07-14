import AppKit
import SwiftUI

/// Hosts the SwiftUI settings UI (full-height sidebar + detail) in a window
/// styled like a standard macOS settings pane.
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Rdio Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab) {
        model.selectedTab = tab
        model.reloadStationsFromDisk()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model).frame(width: 200)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

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
                    .fill(isSelected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                }

                Section("Now playing") {
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17))
                    .frame(width: 48, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3)))
                Text(option.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A larger, always-dancing rendition of the icon so style changes are
/// immediately visible even when nothing is playing.
struct IconPreview: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                if model.iconStyle == .off {
                    Image(systemName: model.idleIcon).font(.title2)
                } else {
                    ForEach(0..<model.barCount, id: \.self) { bar in
                        Capsule()
                            .frame(width: 5,
                                   height: 6 + previewLevel(t: t, bar: bar, of: model.barCount) * 26)
                    }
                }
            }
            .frame(height: 36)
        }
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

    /// Swap in your own page.
    private let coffeeURL = URL(string: "https://www.buymeacoffee.com/anvar936")!

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
                    Link(destination: coffeeURL) {
                        Label("Buy me a coffee ☕️", systemImage: "cup.and.saucer")
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
