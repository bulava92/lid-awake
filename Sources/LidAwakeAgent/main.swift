import Foundation
import Darwin
import LidAwakeCore

let controller = LidAwakeController()
var previousLidClosed = controller.readLidClosed()

while true {
    do {
        let status = try controller.reconcile()
        let lidClosed = controller.readLidClosed()
        let settings = controller.loadSettings()

        if settings.lockOnLidClose,
           settings.requested,
           status.state == .enabled,
           previousLidClosed == false,
           lidClosed == true {
            _ = controller.lockScreen()
        }

        previousLidClosed = lidClosed ?? previousLidClosed
    } catch {
        fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
    }
    Thread.sleep(forTimeInterval: 5)
}
