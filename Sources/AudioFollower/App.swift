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
    private var enabled = true
    private var lastStatusLine = "Idle"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch pid=\(getpid())")
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

    private func updateStatus(_ text: String) {
        lastStatusLine = text
        Log.write(text)
        rebuildMenu()
    }
}
