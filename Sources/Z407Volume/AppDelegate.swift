import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let link = Z407Link()
    private let keys = MediaKeyTap()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastEventLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    /// Step counts were counted by ear on a Z407.
    private let volume = SteppedLevel(
        name: "Volume", up: .volumeUp, down: .volumeDown, levelKey: "EstimatedLevel", stepsKey: "VolumeSteps",
        defaultSteps: 32, symbols: ("speaker.fill", "speaker.wave.3.fill"))
    private let bass = SteppedLevel(
        name: "Bass", up: .bassUp, down: .bassDown, levelKey: "EstimatedBass", stepsKey: "BassSteps",
        defaultSteps: 16, symbols: ("minus", "plus"))
    private var inputItems: [Z407.Input: NSMenuItem] = [:]
    /// Shown only when the menu is opened with Option held, like the Wi-Fi menu.
    private var advancedItems: [NSMenuItem] = []
    private let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "")
    private let interceptItem = NSMenuItem(title: "Intercept Volume Keys", action: #selector(toggleIntercept), keyEquivalent: "")
    private let syncOnStartItem = NSMenuItem(title: "Sync on Startup", action: #selector(toggleSyncOnStart), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var accessPoll: Timer?

    private let defaults = UserDefaults.standard
    private let interceptKey = "InterceptVolumeKeys"
    private let inputKey = "LastInput"
    private let mutedKey = "Muted"
    private let needsSyncKey = "NeedsSync"
    private let syncOnStartKey = "SyncOnStart"
    private var syncOnStart: Bool { defaults.object(forKey: syncOnStartKey) as? Bool ?? true }
    /// Something other than this app may have changed the speaker (another client held it, it was
    /// off, the Mac slept, a sync was cut short): the next session re-syncs volume and bass.
    private var needsSync: Bool {
        get { defaults.bool(forKey: needsSyncKey) }
        set { defaults.set(newValue, forKey: needsSyncKey) }
    }
    /// Sync writes not yet sent in the current session; any left when it ends means redo.
    private var syncWritesRemaining = 0
    /// Launch and wake connect straight away to sync, once Bluetooth is up.
    private var connectWhenAvailable = false
    private var input: Z407.Input? { defaults.string(forKey: inputKey).flatMap(Z407.Input.init(rawValue:)) }
    /// The speaker never reports mute, so this is toggled on each `playPause` written while the
    /// input isn't Bluetooth. Pressing the dial desyncs it.
    private var muted: Bool {
        get { defaults.bool(forKey: mutedKey) }
        set { defaults.set(newValue, forKey: mutedKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Diagnostics.record("Launched Z407 Volume \(version) as user \(NSUserName()), Accessibility \(AXIsProcessTrusted() ? "granted" : "not granted")")
        Diagnostics.onEvent = { [weak self] message in self?.lastEventLine.title = "Last: \(message.prefix(70))" }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()

        keys.isIntercepting = defaults.object(forKey: interceptKey) as? Bool ?? true
        keys.onPress = { [weak self] key in
            guard let self else { return }
            Diagnostics.record("Key: \(key)")
            switch key {
            case .mute:
                self.toggleMute()
            case .volumeUp, .volumeDown:
                self.sendVolume([key == .volumeUp ? .volumeUp : .volumeDown])
            }
            VolumeHUD.show(level: self.volume.projected(after: self.link.pendingCommands),
                           steps: self.volume.steps, muted: self.projectedMuted)
        }
        link.onStateChange = { [weak self] state in self?.linkStateChanged(state) }
        link.sessionPrologue = { [weak self] in self?.syncCommands() ?? [] }
        link.onWrite = { [weak self] command in
            guard let self else { return }
            self.volume.track(command)
            self.bass.track(command)
            if self.syncWritesRemaining > 0 {
                self.syncWritesRemaining -= 1
                if self.syncWritesRemaining == 0 { Diagnostics.record("Sync complete") }
            }
            if command == .playPause && self.input != .bluetooth {
                self.muted.toggle()
                Diagnostics.record(self.muted ? "Muted" : "Unmuted")
                self.refresh()
            }
        }
        link.onResponse = { [weak self] response in self?.handle(response) }
        volume.view.onSet = { [weak self] target in
            guard let self else { return }
            self.sendVolume(self.volume.commands(toReach: target, pending: self.link.pendingCommands))
        }
        volume.view.onStep = { [weak self] delta in
            self?.sendVolume([delta > 0 ? .volumeUp : .volumeDown])
        }
        bass.view.onStep = { [weak self] delta in
            self?.send([delta > 0 ? .bassUp : .bassDown])
        }
        bass.view.onSet = { [weak self] target in
            guard let self else { return }
            self.send(self.bass.commands(toReach: target, pending: self.link.pendingCommands))
        }
        startKeyTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if syncOnStart { scheduleSync(reason: "app start", connectNow: true) }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        link.release()
    }

    // MARK: - Accessibility

    private func startKeyTap() {
        if AXIsProcessTrusted() && keys.start() {
            Diagnostics.record("Volume key tap active")
            return
        }
        Diagnostics.record("Waiting for Accessibility permission")
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // No notification exists for the grant, so poll until it lands.
        accessPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.keys.start() else { return }
                Diagnostics.record("Accessibility granted; volume key tap active")
                self.accessPoll?.invalidate()
                self.accessPoll = nil
                self.refresh()
            }
        }
    }

    // MARK: - Levels and mute

    private func send(_ commands: [Z407.Command]) {
        commands.forEach(link.send)
    }

    /// Changing the volume unmutes first, as macOS does.
    private func sendVolume(_ commands: [Z407.Command]) {
        if projectedMuted && !commands.isEmpty { link.send(.playPause) }
        send(commands)
    }

    /// Mute state once queued toggles are written (`muted` flips only on write).
    private var projectedMuted: Bool {
        link.pendingCommands.filter { $0 == .playPause }.count % 2 == 1 ? !muted : muted
    }

    @objc private func toggleMute() {
        guard input != .bluetooth else { return }
        link.send(.playPause)
    }

    // MARK: - Sync

    private func scheduleSync(reason: String, connectNow: Bool) {
        if !needsSync { Diagnostics.record("Sync scheduled: \(reason)") }
        needsSync = true
        if connectNow {
            connectWhenAvailable = true
            connectIfWanted()
        }
    }

    private func connectIfWanted() {
        guard connectWhenAvailable, link.state == .idle || link.state == .unreachable else { return }
        connectWhenAvailable = false
        link.open()
    }

    /// Run at the start of each session: dips volume and bass to zero, the only knowable level,
    /// and back to the estimates.
    private func syncCommands() -> [Z407.Command] {
        guard needsSync else { return [] }
        needsSync = false
        let commands = volume.resyncCommands() + bass.resyncCommands()
        syncWritesRemaining = commands.count
        return commands
    }

    private func linkStateChanged(_ state: Z407Link.State) {
        switch state {
        case .unreachable:
            scheduleSync(reason: "speaker was unreachable", connectNow: false)
        case .idle where syncWritesRemaining > 0:
            syncWritesRemaining = 0
            scheduleSync(reason: "previous sync was cut short", connectNow: false)
        default:
            break
        }
        connectIfWanted()
        refresh()
    }

    @objc private func syncNow() {
        scheduleSync(reason: "requested", connectNow: true)
    }

    @objc private func didWake() {
        scheduleSync(reason: "Mac woke", connectNow: true)
    }

    // MARK: - Speaker

    private func handle(_ response: Data) {
        guard let input = Z407.Input(report: response) else { return }
        Diagnostics.record("Input: \(input.title)")
        defaults.set(input.rawValue, forKey: inputKey)
        refresh()
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let input = inputItems.first(where: { $0.value === sender })?.key else { return }
        link.send(input.command)
    }

    @objc private func playPause() { link.send(.playPause) }
    @objc private func nextTrack() { link.send(.nextTrack) }
    @objc private func previousTrack() { link.send(.previousTrack) }
    @objc private func enablePairing() { link.send(.bluetoothPairing) }

    @objc private func factoryReset() {
        let alert = NSAlert()
        alert.messageText = "Factory reset the Z407?"
        alert.informativeText = "This resets the speaker to factory settings, including its Bluetooth pairings."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Factory Reset").hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Diagnostics.record("Factory reset requested")
        link.send(.factoryReset)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        lastEventLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(advanced(lastEventLine))
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        for level in [volume, bass] {
            let item = NSMenuItem()
            item.view = level.view
            menu.addItem(item)
        }
        muteItem.target = self
        menu.addItem(muteItem)
        menu.addItem(advanced(item("Re-sync Now (dip to zero and back)", #selector(syncNow))))
        menu.addItem(.separator())
        menu.addItem(submenu("Input", Z407.Input.allCases.map { input in
            let item = item(input.title, #selector(selectInput))
            inputItems[input] = item
            return item
        }))
        menu.addItem(submenu("Bluetooth Playback", [
            item("Play/Pause", #selector(playPause)),
            item("Next Track", #selector(nextTrack)),
            item("Previous Track", #selector(previousTrack)),
        ]))
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(advanced(.separator()))
        interceptItem.target = self
        menu.addItem(advanced(interceptItem))
        syncOnStartItem.target = self
        menu.addItem(advanced(syncOnStartItem))
        menu.addItem(advanced(item("Enter Bluetooth Pairing Mode", #selector(enablePairing))))
        menu.addItem(advanced(item("Factory Reset Speaker…", #selector(factoryReset))))
        menu.addItem(advanced(item("Copy Diagnostics", #selector(copyDiagnostics))))
        menu.addItem(advanced(item("Open Log", #selector(openLog))))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func advanced(_ item: NSMenuItem) -> NSMenuItem {
        advancedItems.append(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let showAdvanced = NSEvent.modifierFlags.contains(.option)
        for item in advancedItems { item.isHidden = !showAdvanced }
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func refresh() {
        let (symbol, text): (String, String)
        if !keys.isRunning {
            (symbol, text) = ("exclamationmark.triangle", "Needs Accessibility access (System Settings › Privacy & Security)")
        } else {
            switch link.state {
            case .bluetoothUnavailable: (symbol, text) = ("exclamationmark.triangle", "Bluetooth off or not permitted")
            case .idle: (symbol, text) = ("hifispeaker", "Disconnected (speaker released)")
            case .connecting: (symbol, text) = ("antenna.radiowaves.left.and.right", "Connecting…")
            case .ready: (symbol, text) = ("hifispeaker.fill", "Connected")
            case .unreachable: (symbol, text) = ("speaker.slash", "Unreachable (asleep or in use by another remote)")
            }
        }
        statusLine.title = text
        accessibilityItem.isHidden = keys.isRunning
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "Z407"
        }
        statusItem.button?.toolTip = "Z407 Volume: \(text)"
        volume.refreshView()
        bass.refreshView()
        for (candidate, item) in inputItems { item.state = candidate == input ? .on : .off }
        // On Bluetooth, playPause is play/pause, so the mute key goes back to macOS.
        keys.interceptsMute = input != .bluetooth
        muteItem.isEnabled = input != .bluetooth
        muteItem.state = muted ? .on : .off
        interceptItem.state = keys.isIntercepting ? .on : .off
        syncOnStartItem.state = syncOnStart ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func willSleep() { link.release() }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleIntercept() {
        keys.isIntercepting.toggle()
        defaults.set(keys.isIntercepting, forKey: interceptKey)
        Diagnostics.record("Intercept volume keys: \(keys.isIntercepting)")
        refresh()
    }

    @objc private func toggleSyncOnStart() {
        defaults.set(!syncOnStart, forKey: syncOnStartKey)
        Diagnostics.record("Sync on startup: \(syncOnStart)")
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc private func copyDiagnostics() {
        let header = [
            "User: \(NSUserName()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted"), key tap: \(keys.isRunning ? "active" : "inactive"), intercepting: \(keys.isIntercepting)",
            "Link: \(link.state), input: \(input?.title ?? "unknown"), muted: \(muted), sync pending: \(needsSync)",
            "Estimates: volume \(volume.level)/\(volume.steps), bass \(bass.level)/\(bass.steps)",
            "---",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((header + Diagnostics.recent).joined(separator: "\n"), forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Diagnostics.fileURL)
    }
}
