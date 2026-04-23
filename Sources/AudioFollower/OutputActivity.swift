import AppKit
import CoreAudio
import Foundation

// Polls the public CoreAudio process-object API (macOS 14.4+) every 500ms
// to detect which processes are producing audio output, and fires an event
// when one transitions off->on. This is deliberately not a property-change
// listener: on macOS 26 those listeners appear to be silently gated for
// un-entitled apps. Polling is cheap and reliable.
final class OutputActivityWatcher {
    struct Event {
        let pid: pid_t
        let appName: String?
    }

    var onPlayStart: ((Event) -> Void)?

    private var timer: Timer?
    private var lastRunningOutput: [AudioObjectID: Bool] = [:]

    func start() {
        // Prime state, emit for anything already running.
        tick(fireForExisting: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick(fireForExisting: false)
        }
    }

    // On-demand: find the process currently producing output and emit for
    // it. Used as the media-key response. When multiple processes hold an
    // output stream (e.g. Music + a browser both lingering), prefer one
    // whose responsible app owns a visible window — background helpers or
    // daemons with no UI are almost never what the user pressed a media
    // key about.
    func rerouteExisting() {
        let producers = fetchProcessObjectIDs().compactMap { id -> (AudioObjectID, pid_t)? in
            guard isRunningOutput(id),
                  let pid = pidOf(id),
                  pid > 0, pid != getpid()
            else { return nil }
            return (id, pid)
        }
        guard !producers.isEmpty else {
            Log.write("rerouteExisting: no process is producing output")
            return
        }
        let chosen = producers.first { _, pid in
            Screens.frontmostScreen(for: ProcessTree.responsiblePID(for: pid)) != nil
        } ?? producers[0]
        emit(for: chosen.0, reason: "media-key")
    }

    // MARK: - Poll

    private func tick(fireForExisting: Bool) {
        let ids = fetchProcessObjectIDs()
        let alive = Set(ids)
        lastRunningOutput = lastRunningOutput.filter { alive.contains($0.key) }

        for id in ids {
            let running = isRunningOutput(id)
            let was = lastRunningOutput[id]
            lastRunningOutput[id] = running
            if running && (was != true) {
                let reason = (was == nil && fireForExisting) ? "startup" : "transition"
                emit(for: id, reason: reason)
            }
        }
    }

    // MARK: - CoreAudio property access

    private func fetchProcessObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func pidOf(_ id: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    private func emit(for id: AudioObjectID, reason: String) {
        guard let pid = pidOf(id), pid > 0 else { return }
        if pid == getpid() { return }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        Log.write("emit \(reason): pid=\(pid) (\(appName ?? "?"))")
        onPlayStart?(Event(pid: pid, appName: appName))
    }
}
