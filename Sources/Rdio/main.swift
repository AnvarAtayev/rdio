import AppKit

if CommandLine.arguments.contains("--selftest") {
    runSelfTest(stations: Stations.load())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()  // never returns; `delegate` stays alive for the app's lifetime
}
