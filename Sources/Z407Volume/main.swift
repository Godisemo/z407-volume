import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--speed-probe") {
        let probe = SpeedProbe()
        probe.start()
        app.run()
    } else if CommandLine.arguments.contains("--probe") {
        let probe = Probe()
        probe.start()
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
