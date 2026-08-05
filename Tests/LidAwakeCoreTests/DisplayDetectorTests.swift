import XCTest
import CoreGraphics
@testable import LidAwakeCore

struct MockDisplayProvider: DisplayInfoProvider {
    var online: [CGDirectDisplayID: Bool] = [:]
    var active: [CGDirectDisplayID: Bool] = [:]
    var builtin: [CGDirectDisplayID: Bool] = [:]
    var rects: [CGDirectDisplayID: CGRect] = [:]
    var mirrorSet: [CGDirectDisplayID: Bool] = [:]
    var mirrors: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    var virtual: [CGDirectDisplayID: Bool] = [:]

    func isOnline(_ id: CGDirectDisplayID) -> Bool { online[id] ?? false }
    func isActive(_ id: CGDirectDisplayID) -> Bool { active[id] ?? false }
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool { builtin[id] ?? false }
    func bounds(_ id: CGDirectDisplayID) -> CGRect { rects[id] ?? .zero }
    func isInMirrorSet(_ id: CGDirectDisplayID) -> Bool { mirrorSet[id] ?? false }
    func mirrorsDisplay(_ id: CGDirectDisplayID) -> CGDirectDisplayID { mirrors[id] ?? kCGNullDirectDisplay }
    func isVirtual(_ id: CGDirectDisplayID) -> Bool { virtual[id] ?? false }
}

final class DisplayDetectorTests: XCTestCase {
    func testOpenLidOnlyBuiltin() {
        let provider = MockDisplayProvider(
            online: [1: true], active: [1: true], builtin: [1: true], rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000)]
        )
        XCTAssertFalse(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1]))
    }

    func testClosedLidOneRealExternal() {
        let provider = MockDisplayProvider(
            online: [2: true], active: [2: true], builtin: [2: false], rects: [2: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        XCTAssertTrue(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [2]))
    }

    func testOpenLidBuiltinAndExternal() {
        let provider = MockDisplayProvider(
            online: [1: true, 2: true],
            active: [1: true, 2: true],
            builtin: [1: true, 2: false],
            rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: CGRect(x: 1000, y: 0, width: 1920, height: 1080)]
        )
        XCTAssertTrue(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]))
    }

    func testMirroredDisplay() {
        let provider = MockDisplayProvider(
            online: [1: true, 2: true],
            active: [1: true, 2: true],
            builtin: [1: true, 2: false],
            rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            mirrorSet: [1: true, 2: true],
            mirrors: [1: kCGNullDirectDisplay, 2: 1]
        )
        XCTAssertTrue(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]))
    }

    func testVirtualDisplayDoesNotCount() {
        let provider = MockDisplayProvider(
            online: [1: true, 2: true], active: [1: true, 2: true], builtin: [1: true, 2: false],
            rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: CGRect(x: 1000, y: 0, width: 1920, height: 1080)],
            virtual: [2: true]
        )
        XCTAssertFalse(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]))
    }

    func testInactiveOrZeroBoundsDoNotCount() {
        let provider = MockDisplayProvider(
            online: [1: true, 2: true], active: [1: true, 2: false], builtin: [1: true, 2: false],
            rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: .zero]
        )
        XCTAssertFalse(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]))
    }

    func testOfflineExternalDoesNotCount() {
        let provider = MockDisplayProvider(
            online: [1: true, 2: false], active: [1: true, 2: true], builtin: [1: true, 2: false],
            rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        XCTAssertFalse(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]))
    }

    func testNamedVirtualDisplayPoliciesAreConservative() {
        for label in ["AirPlay", "Sidecar", "DisplayLink"] {
            let provider = MockDisplayProvider(
                online: [1: true, 2: true], active: [1: true, 2: true], builtin: [1: true, 2: false],
                rects: [1: CGRect(x: 0, y: 0, width: 1000, height: 1000), 2: CGRect(x: 1000, y: 0, width: 1920, height: 1080)],
                virtual: [2: true]
            )
            XCTAssertFalse(DisplayDetector.hasRealExternalDisplay(provider: provider, onlineDisplays: [1, 2]), label)
        }
    }
}
