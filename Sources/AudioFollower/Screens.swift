import AppKit
import CoreAudio
import CoreGraphics

enum Screens {
    // Find the NSScreen containing the given app's frontmost normal-layer window.
    static func frontmostScreen(for pid: pid_t) -> NSScreen? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Window list is front-to-back; first hit is frontmost.
        for info in raw {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(
                x: b["X"] ?? 0, y: b["Y"] ?? 0,
                width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.width < 50 || rect.height < 50 { continue }
            return screen(containingCGRect: rect)
        }
        return nil
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(num) != 0
    }

    // CGWindowBounds: origin top-left of primary display, Y grows down.
    // NSScreen.frame: origin bottom-left of primary display, Y grows up.
    private static func screen(containingCGRect rect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let centerCG = CGPoint(x: rect.midX, y: rect.midY)
        let centerNS = CGPoint(x: centerCG.x, y: primaryHeight - centerCG.y)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(centerNS) }) { return hit }
        return NSScreen.screens.min { sqDistance(centerNS, $0.frame) < sqDistance(centerNS, $1.frame) }
    }

    private static func sqDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

// Hardcoded mapping for this user's setup:
//   Built-in (MacBook Pro) display -> built-in speakers
//   External (Studio Display) -> Studio Display speakers
enum ScreenDeviceMap {
    static func device(for screen: NSScreen, among devices: [AudioRouter.Device]) -> AudioRouter.Device? {
        if Screens.isBuiltIn(screen) {
            return devices.first { isBuiltInSpeakers($0) }
        }
        return devices.first { isStudioDisplaySpeakers($0) }
    }

    // All devices this app considers "managed". If the current default output
    // is NOT one of these (e.g. AirPods), we leave it alone so the user's
    // explicit choice wins over auto-routing.
    static func managedDevices(among devices: [AudioRouter.Device]) -> [AudioRouter.Device] {
        devices.filter { isBuiltInSpeakers($0) || isStudioDisplaySpeakers($0) }
    }

    private static func isBuiltInSpeakers(_ d: AudioRouter.Device) -> Bool {
        d.transportType == kAudioDeviceTransportTypeBuiltIn
            && d.uid.range(of: "Input", options: .caseInsensitive) == nil
    }

    private static func isStudioDisplaySpeakers(_ d: AudioRouter.Device) -> Bool {
        let n = d.name.lowercased()
        return n.contains("studio display")
    }
}
