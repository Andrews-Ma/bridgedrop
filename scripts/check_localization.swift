import Foundation

@main struct LocalizationChecks {
    static func main() throws {
        let tests: [(String, String, String)] = [
            ("轻传", "en", "BridgeDrop"), ("发送到", "en", "Send to"),
            ("确认导入并配对", "en", "Confirm import and pair"),
            ("拒绝", "zh-Hans", "拒绝"), ("正在传输", "en", "Transferring"),
            ("传输已暂停。", "en", "Transfer paused."),
            ("邀请码内容损坏或字段不完整，请重新生成邀请。", "en", "The invitation is damaged or incomplete. Create a new one."),
            ("邀请码无效、已过期或版本不兼容。请在另一台设备重新显示配对二维码。", "en", "The invitation is invalid, expired or incompatible. Show a new QR code on the other device."),
            ("邀请来自：中文设备", "en", "Invitation from: 中文设备"),
            ("邀请来自：文本", "en", "Invitation from: 文本"),
            ("来自 Alice · 1 KB", "en", "From Alice · 1 KB"),
            ("12 字节", "en", "12 bytes"),
            ("正在自动重试（2/4），已保存的数据会从断点继续。", "en", "Retrying automatically (2/4). Saved data will resume from the last offset."),
            ("无法读取本机钥匙串中的配对信息（-25300）。", "en", "Could not read pairing information from Keychain (-25300)."),
            ("用户内容中文", "en", "用户内容中文"), ("发送到", "fr", "Send to")
        ]
        for (input, language, expected) in tests {
            let result = BridgeLocalization.text(input, language: language)
            guard result == expected else { throw NSError(domain: "LocalizationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Translation check failed for \(input)"]) }
        }
        let defaults = UserDefaults.standard
        let key = "BridgeDrop.language"
        let original = defaults.object(forKey: key)
        defer { if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)
        guard BridgeLocalization.current("发送") == "Send" else { throw NSError(domain: "LocalizationCheck", code: 2) }
        defaults.set("zh", forKey: key)
        guard BridgeLocalization.current("发送") == "发送" else { throw NSError(domain: "LocalizationCheck", code: 3) }
        defaults.set("en", forKey: key)
        guard BridgeLocalization.current("发送") == "Send" else { throw NSError(domain: "LocalizationCheck", code: 4) }
        print("PASS: \(tests.count) translation checks, dynamic content preservation and isolated language preference")
    }
}
