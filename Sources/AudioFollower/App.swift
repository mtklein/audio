import AppKit

@main
struct AudioFollowerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = OutputActivityWatcher()
    private let mediaKeys = MediaKeyListener()
    private var relocateTimer: Timer?
    private var enabled = true
    private var lastStatusLine = "Idle"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.initialize()
        Log.write("launch pid=\(getpid())")
        logEnvironment()

        setupStatusItem()
        watcher.onPlayStart = { [weak self] event in
            self?.handlePlayStart(event)
        }
        watcher.start()

        mediaKeys.onKey = { [weak self] key in
            // Any media key is a "user just asked for audio" signal. Re-run
            // routing against whatever's currently producing output.
            Log.write("media-key: \(key.rawValue) -> reroute")
            self?.watcher.rerouteExisting()
        }
        mediaKeys.start()

        // Silent drag-follow: if the playing window moved to a different
        // screen, reroute. Runs infrequently so no concern for cost.
        relocateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.relocateIfWindowMoved()
        }

        // Keep the menu's "Output:" line in sync with the real world (user
        // changed output in Control Center, device plugged/unplugged, we
        // routed, macOS auto-routed on wake, etc.) and log each change.
        AudioRouter.addDefaultOutputListener { [weak self] id in
            let name = AudioRouter.deviceName(id) ?? "id=\(id)"
            Log.write("default output → \(name)")
            self?.rebuildMenu()
        }
        AudioRouter.addDeviceListListener { [weak self] devices in
            Log.write("device list changed: \(devices.map(\.name).joined(separator: ", "))")
            self?.rebuildMenu()
        }
    }

    // Snapshot of the audio/display environment at boot, for context when
    // reading the log after the fact.
    private func logEnvironment() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("env: version=\(version) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let devices = AudioRouter.listOutputDevices()
        for d in devices {
            Log.write("  device: \(d.name) (uid=\(d.uid) transport=\(Self.fourCC(d.transportType)))")
        }
        if let id = AudioRouter.currentDefaultOutput(), let name = AudioRouter.deviceName(id) {
            Log.write("  default output: \(name)")
        }
        for screen in NSScreen.screens {
            let tag = Screens.isBuiltIn(screen) ? " [built-in]" : ""
            let mapped = ScreenDeviceMap.device(for: screen, among: devices)?.name ?? "(unmapped)"
            Log.write("  screen: \(screen.localizedName)\(tag) → \(mapped)")
        }
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),  UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hifispeaker.and.homepod", accessibilityDescription: "Audio Follower")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: lastStatusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let id = AudioRouter.currentDefaultOutput(), let name = AudioRouter.deviceName(id) {
            let cur = NSMenuItem(title: "Output: \(name)", action: nil, keyEquivalent: "")
            cur.isEnabled = false
            menu.addItem(cur)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Auto-switch on play", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let devicesHeader = NSMenuItem(title: "Detected output devices", action: nil, keyEquivalent: "")
        devicesHeader.isEnabled = false
        menu.addItem(devicesHeader)
        for d in AudioRouter.listOutputDevices() {
            let item = NSMenuItem(title: "  \(d.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        rebuildMenu()
    }

    // MARK: - Core routing

    private func handlePlayStart(_ event: OutputActivityWatcher.Event) {
        // XPC helpers (Safari Graphics and Media, Chrome renderers, etc.)
        // produce audio but don't own windows — resolve to the responsible
        // app PID so we can find the real window.
        let resolvedPID = ProcessTree.responsiblePID(for: event.pid)
        let resolvedName = NSRunningApplication(processIdentifier: resolvedPID)?.localizedName
        let who = resolvedName ?? event.appName ?? "pid \(resolvedPID)"

        guard enabled else {
            updateStatus("Paused (disabled): \(who)")
            return
        }
        guard let screen = Screens.frontmostScreen(for: resolvedPID) else {
            updateStatus("No window for \(who)")
            return
        }
        let devices = AudioRouter.listOutputDevices()
        let managed = ScreenDeviceMap.managedDevices(among: devices)
        guard let target = ScreenDeviceMap.device(for: screen, among: devices) else {
            updateStatus("No device mapped for \(screen.localizedName)")
            return
        }
        let currentID = AudioRouter.currentDefaultOutput()
        // If user has picked something we don't manage (AirPods, etc.), leave it alone.
        if let currentID, !managed.contains(where: { $0.id == currentID }) {
            let currentName = AudioRouter.deviceName(currentID) ?? "unknown"
            updateStatus("Skipped: \(currentName) not managed")
            return
        }
        if currentID == target.id {
            updateStatus("\(who) on \(target.name)")
            return
        }
        let ok = AudioRouter.setDefaultOutput(target.id)
        updateStatus(ok ? "\(who) → \(target.name)" : "Failed → \(target.name)")
    }

    // Quiet counterpart to handlePlayStart: only touches the system when
    // the producing window has actually moved to a screen that maps to a
    // different device. No log spam, no status-line churn on every tick.
    private func relocateIfWindowMoved() {
        guard enabled,
              let pid = watcher.primaryProducerPID()
        else { return }
        let resolvedPID = ProcessTree.responsiblePID(for: pid)
        guard let screen = Screens.frontmostScreen(for: resolvedPID) else { return }
        let devices = AudioRouter.listOutputDevices()
        let managed = ScreenDeviceMap.managedDevices(among: devices)
        guard let target = ScreenDeviceMap.device(for: screen, among: devices),
              let currentID = AudioRouter.currentDefaultOutput()
        else { return }
        if currentID == target.id { return }
        // Respect user choice of unmanaged outputs (AirPods, etc.).
        if !managed.contains(where: { $0.id == currentID }) { return }
        let who = NSRunningApplication(processIdentifier: resolvedPID)?.localizedName ?? "pid \(resolvedPID)"
        let ok = AudioRouter.setDefaultOutput(target.id)
        updateStatus(ok ? "\(who) moved → \(target.name)" : "Failed → \(target.name)")
    }

    private func updateStatus(_ text: String) {
        lastStatusLine = text
        Log.write(text)
        rebuildMenu()
    }
}
