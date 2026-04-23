import CoreAudio
import Foundation

enum AudioRouter {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transportType: UInt32
    }

    static func listOutputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(makeDevice)
    }

    static func currentDefaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr ? id : nil
    }

    @discardableResult
    static func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = deviceID
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return err == noErr
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        listOutputDevices().first(where: { $0.id == id })?.name
    }

    // MARK: - Private

    private static func makeDevice(_ id: AudioDeviceID) -> Device? {
        guard hasOutputChannels(id),
              let uid = getString(id, selector: kAudioDevicePropertyDeviceUID),
              let name = getString(id, selector: kAudioObjectPropertyName)
        else { return nil }
        let transport = getUInt32(id, selector: kAudioDevicePropertyTransportType) ?? 0
        return Device(id: id, uid: uid, name: name, transportType: transport)
    }

    private static func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return false }
        let listPtr = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufs = UnsafeMutableAudioBufferListPointer(listPtr)
        return bufs.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func getString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let err = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func getUInt32(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }
}
