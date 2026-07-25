import Foundation
import LidAwakeCore

let controller = LidAwakeController()
while true {
    do {
        _ = try controller.reconcile()
    } catch {
        fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
    }
    Thread.sleep(forTimeInterval: 30)
}
