import AppKit
import Carbon.HIToolbox

// Global monitor for the six system media keys (prev / play-pause / next /
// mute / volume-down / volume-up). Any press triggers a re-evaluation of
// audio routing. Uses NSEvent.addGlobalMonitorForEvents with systemDefined
// subtype 8 — no Accessibility entitlement needed on macOS 26, though
// Input Monitoring may be prompted on first run.
final class MediaKeyListener {
    enum Key: String {
        case playPause, next, previous, mute, volumeUp, volumeDown
    }

    var onKey: ((Key) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // NX_KEYTYPE_* constants from <IOKit/hidsystem/ev_keymap.h>.
    private static let volumeUp: Int = 0
    private static let volumeDown: Int = 1
    private static let mute: Int = 7
    private static let play: Int = 16
    private static let next: Int = 17
    private static let previous: Int = 18

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] ev in
            self?.handle(ev)
        }
        // Local monitor catches presses that happen while AudioFollower is
        // (somehow) frontmost; harmless if unused.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] ev in
            self?.handle(ev)
            return ev
        }
        Log.write("MediaKeyListener installed (global=\(globalMonitor != nil), local=\(localMonitor != nil))")
    }

    private func handle(_ event: NSEvent) {
        // NSSystemDefined event for aux media keys uses subtype 8.
        guard event.subtype.rawValue == 8 else { return }
        let data1 = event.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = Int(data1 & 0x0000FFFF)
        let keyState = (keyFlags & 0xFF00) >> 8
        // 0x0A = key-down. (0x0B = key-up.)
        guard keyState == 0x0A else { return }

        let key: Key
        switch keyCode {
        case Self.play: key = .playPause
        case Self.next: key = .next
        case Self.previous: key = .previous
        case Self.mute: key = .mute
        case Self.volumeUp: key = .volumeUp
        case Self.volumeDown: key = .volumeDown
        default: return
        }
        Log.write("media key: \(key.rawValue)")
        onKey?(key)
    }
}
