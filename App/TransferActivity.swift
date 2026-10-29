import Foundation
#if os(iOS)
import UIKit
#endif

/// Hold only while an actual send or approved receive is active. Never promises background execution.
@MainActor final class TransferActivity {
    private var token: NSObjectProtocol?
    func setActive(_ active: Bool) {
        #if os(macOS)
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "轻传正在传输文件或文本")
        } else if !active, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = active
        #endif
    }
}
