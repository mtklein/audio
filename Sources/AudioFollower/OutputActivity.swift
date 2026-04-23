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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick(fireForExisting: false)
        }
    }

    // The PID that should be considered the primary audio producer — used
    // both for "user pressed a media key, find the thing that's playing"
    // and for silent drag-follow polling. When multiple processes hold an
    // output stream (e.g. Music + a browser both lingering), prefer one
    // whose responsible app owns a visible window; background helpers or
    // daemons with no UI are almost never what the user cares about.
    func primaryProducerPID() -> pid_t? {
        let pids = fetchProcessObjectIDs().compactMap { id -> pid_t? in
            guard isRunningOutput(id),
                  let pid = pidOf(id),
                  pid > 0, pid != getpid()
            else { return nil }
            return pid
        }
        return pids.first { Screens.frontmostScreen(for: ProcessTree.responsiblePID(for: $0)) != nil }
            ?? pids.first
    }

    // On-demand: reroute for whatever's currently producing output.
    // Used as the media-key response.
    func rerouteExisting() {
        guard let pid = primaryProducerPID() else {
            Log.write("rerouteExisting: no process is producing output")
            return
        }
        emitPID(pid, reason: "media-key")
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
                if let pid = pidOf(id), pid > 0, pid != getpid() {
                    emitPID(pid, reason: reason)
                }
            } else if !running && was == true {
                // Log transition OFF so the log reads as a full narrative.
                if let pid = pidOf(id), pid > 0, pid != getpid() {
                    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
                    Log.write("audio stopped: pid=\(pid) (\(name))")
                }
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

    private func emitPID(_ pid: pid_t, reason: String) {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        Log.write("emit \(reason): pid=\(pid) (\(appName ?? "?"))")
        onPlayStart?(Event(pid: pid, appName: appName))
    }
}
