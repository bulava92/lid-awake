import Foundation
import CoreGraphics

public protocol DisplayInfoProvider {
    func isOnline(_ id: CGDirectDisplayID) -> Bool
    func isActive(_ id: CGDirectDisplayID) -> Bool
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool
    func bounds(_ id: CGDirectDisplayID) -> CGRect
    func isInMirrorSet(_ id: CGDirectDisplayID) -> Bool
    func mirrorsDisplay(_ id: CGDirectDisplayID) -> CGDirectDisplayID
    func isVirtual(_ id: CGDirectDisplayID) -> Bool
}

public struct DefaultDisplayInfoProvider: DisplayInfoProvider {
    public init() {}
    public func isOnline(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsOnline(id) != 0 }
    public func isActive(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsActive(id) != 0 }
    public func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }
    public func bounds(_ id: CGDirectDisplayID) -> CGRect { CGDisplayBounds(id) }
    public func isInMirrorSet(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsInMirrorSet(id) != 0 }
    public func mirrorsDisplay(_ id: CGDirectDisplayID) -> CGDirectDisplayID { CGDisplayMirrorsDisplay(id) }
    /// CoreGraphics' public display list does not expose a reliable physical
    /// transport/virtual flag. Keep this conservative and explicit: the
    /// default policy does not claim to filter virtual displays; callers can
    /// supply a provider with verified metadata in tests or integrations.
    public func isVirtual(_ id: CGDirectDisplayID) -> Bool { false }
}

public struct DisplayDetector {
    public static func hasRealExternalDisplay(provider: DisplayInfoProvider = DefaultDisplayInfoProvider(), onlineDisplays: [CGDirectDisplayID]) -> Bool {
        guard !onlineDisplays.isEmpty else { return false }

        let activeList = onlineDisplays.filter { id in
            guard provider.isOnline(id), provider.isActive(id) else { return false }
            let b = provider.bounds(id)
            guard b.width > 0 && b.height > 0 else { return false }
            return true
        }
        // Do not infer from display count. In clamshell mode the only online
        // display can be the real external monitor; mirrored external displays
        // are still physical and must count as external.
        return activeList.contains { !provider.isBuiltin($0) && !provider.isVirtual($0) }
    }

    public static func checkSystem() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success, count > 0 else { return false }
        return hasRealExternalDisplay(onlineDisplays: Array(displays.prefix(Int(count))))
    }

    public static func systemReport() -> String {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return "display-list: unavailable"
        }
        let ids = Array(displays.prefix(Int(count)))
        let provider = DefaultDisplayInfoProvider()
        let rows = ids.map { id in
            let bounds = provider.bounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let modeText = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(String(format: "%.2f", $0.refreshRate))Hz" } ?? "unknown"
            let mirrorTarget = provider.mirrorsDisplay(id)
            return "id=\(id) online=\(provider.isOnline(id)) active=\(provider.isActive(id)) asleep=\(CGDisplayIsAsleep(id) != 0) builtin=\(provider.isBuiltin(id)) virtual=unknown mirror=\(provider.isInMirrorSet(id)) mirrors=\(mirrorTarget) bounds=\(Int(bounds.width))x\(Int(bounds.height)) pixels=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) unit=\(CGDisplayUnitNumber(id)) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) serial=\(CGDisplaySerialNumber(id)) mode=\(modeText)"
        }
        return "display-count=\(ids.count) external=\(hasRealExternalDisplay(provider: provider, onlineDisplays: ids))\n" + rows.joined(separator: "\n")
    }
}
