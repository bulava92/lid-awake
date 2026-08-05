import Foundation
import XCTest
@testable import LidAwakeCore

final class LidActionLogicTests: XCTestCase {
    private struct FailingLocker: ScreenLocker {
        func lockScreen() -> Bool { false }
    }
    private func status(state: LidAwakeState, requested: Bool, sound: Bool = true, bypass: Bool = false) -> LidAwakeStatus {
        LidAwakeStatus(
            state: state,
            reason: "test",
            settings: LidAwakeSettings(requested: requested, acOnly: false, skipLidActionsWithExternalDisplay: bypass, soundOnLidClose: sound),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            remainingSeconds: nil,
            updatedAt: Date()
        )
    }

    func testSharedDecisionFlowForManualEnabled() {
        let plan = LidCloseActionDecider.plan(status: status(state: .enabled, requested: true), externalDisplayDetected: false)
        XCTAssertTrue(plan.shouldPlaySound)
        XCTAssertTrue(plan.shouldDebounce)
    }

    func testSharedDecisionFlowSkipsScheduleOff() {
        let plan = LidCloseActionDecider.plan(status: status(state: .disabled, requested: false), externalDisplayDetected: false)
        XCTAssertFalse(plan.shouldPlaySound)
        XCTAssertFalse(plan.shouldDebounce)
    }

    func testSharedDecisionFlowSkipsExternalDisplay() {
        let plan = LidCloseActionDecider.plan(status: status(state: .enabled, requested: true, bypass: true), externalDisplayDetected: true)
        XCTAssertFalse(plan.shouldPlaySound)
        XCTAssertFalse(plan.shouldDebounce)
    }

    func testFreshStatusWinsOverStaleStatus() {
        let stale = LidCloseActionDecider.plan(status: status(state: .disabled, requested: false), externalDisplayDetected: false)
        let fresh = LidCloseActionDecider.plan(status: status(state: .enabled, requested: true), externalDisplayDetected: false)
        XCTAssertFalse(stale.shouldDebounce)
        XCTAssertTrue(fresh.shouldDebounce)
    }

    func testSoundFailureDoesNotSuppressDebounceDecision() {
        let player = LidAwakeSoundPlayer()
        XCTAssertFalse(player.play(path: "/definitely/missing/sound.aiff", volumePercent: 50))
        let plan = LidCloseActionDecider.plan(status: status(state: .enabled, requested: true, sound: true), externalDisplayDetected: false)
        XCTAssertTrue(plan.shouldDebounce)
    }

    func testRunnerShortCommand() {
        let controller = LidAwakeController()
        let res = controller.runProcess(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2"], timeout: 2.0)
        XCTAssertEqual(res.stdout, "out")
        XCTAssertEqual(res.stderr, "err")
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertFalse(res.timedOut)
        XCTAssertNil(res.launchError)
    }

    func testRunnerSleepTimeout() {
        let controller = LidAwakeController()
        let start = Date()
        let res = controller.runProcess(executable: "/bin/sleep", arguments: ["10"], timeout: 0.2)
        XCTAssertTrue(res.timedOut, "Process should time out when exceeding duration limit")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertLessThan(res.duration, 2.0)
    }

    func testRunnerKillsProcessIgnoringSIGTERM() {
        let controller = LidAwakeController()
        let res = controller.runProcess(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 10"], timeout: 0.2)
        XCTAssertTrue(res.timedOut)
        XCTAssertLessThan(res.duration, 2.0)
    }

    func testRunnerDoesNotWaitForInheritedPipeDescriptor() {
        let controller = LidAwakeController()
        let start = Date()
        let res = controller.runProcess(executable: "/bin/sh", arguments: ["-c", "sleep 10 & printf child; exit 0"], timeout: 2.0)
        XCTAssertFalse(res.timedOut)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertEqual(res.stdout, "child")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testRunnerDrainsLargeStdoutAndStderr() {
        let controller = LidAwakeController()
        let script = "i=0; while [ $i -lt 20000 ]; do printf oooooooooo; printf eeeeeeeeee >&2; i=$((i+1)); done"
        let res = controller.runProcess(executable: "/bin/sh", arguments: ["-c", script], timeout: 3.0)
        XCTAssertFalse(res.timedOut)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertGreaterThan(res.stdout.count, 100_000)
        XCTAssertGreaterThan(res.stderr.count, 100_000)
    }

    func testRunnerReportsMissingExecutable() {
        let controller = LidAwakeController()
        let res = controller.runProcess(executable: "/definitely/not/a/real/executable", arguments: [], timeout: 0.2)
        XCTAssertNotNil(res.launchError)
        XCTAssertFalse(res.timedOut)
        XCTAssertNil(res.exitCode)
    }

    func testDiagnosticsReturnsQuickly() {
        let controller = LidAwakeController()
        let start = Date()
        let output = controller.diagnostics()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 15.0, "Diagnostics must complete in under 15 seconds")
        XCTAssertTrue(output.contains("subprocess.uname:"))
        XCTAssertTrue(output.contains("subprocess.helper.status:"))
    }

    func testScreenLockFallbackRequiresImmediateDelay() {
        XCTAssertTrue(LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is immediate"))
        XCTAssertFalse(LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is 5"))
        XCTAssertFalse(FailingLocker().lockScreen())
    }
}
