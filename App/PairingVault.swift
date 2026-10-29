import Foundation
import Security
#if os(iOS)
import UIKit
#endif

struct PairConfiguration: Codable {
    var pairID: String
    var secret: Data
    var relayURL: String
    var relayToken: String
    var trustedNames: [String: String]
    var preferredHost: String
    var preferredPort: UInt16

    static func fresh() throws -> PairConfiguration {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VaultError.storage("无法生成配对密钥。")
        }
        return PairConfiguration(pairID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                                 secret: Data(bytes), relayURL: "", relayToken: "", trustedNames: [:],
                                 preferredHost: "", preferredPort: 47185)
    }
}

struct PairInvitation: Codable {
    let format: String
    let pairID: String
    let secret: String
    let inviterID: String
    let inviterName: String
    let host: String
    let port: UInt16
    let relayURL: String?
    let relayToken: String?
    let expiresAt: Double
}

enum VaultError: LocalizedError {
    case storage(String), invalidInvitation
    var errorDescription: String? {
        switch self {
        case .storage(let text): return text
        case .invalidInvitation: return "邀请码无效、已过期或版本不兼容。请在另一台设备重新显示配对二维码。"
        }
    }
}

enum PairingVault {
    private static let service = "org.local.bridgedrop.pairing.v1"
    private static let account = "active-pair"
    static func load() throws -> PairConfiguration? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultError.storage("无法读取本机钥匙串中的配对信息（\(status)）。")
        }
        return try JSONDecoder().decode(PairConfiguration.self, from: data)
    }
    static func save(_ configuration: PairConfiguration) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = try JSONEncoder().encode(configuration)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.storage("保存配对信息失败（\(update)）。") }
        var entry = query
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        entry[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(entry as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.storage("保存本机配对密钥失败（\(status)）。") }
    }
    static var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: "BridgeDrop.deviceID"), UUID(uuidString: stored) != nil { return stored }
        let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: "BridgeDrop.deviceID"); return id
    }
    static var defaultName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "我的 Mac"
        #endif
    }
    static func validate(_ invitation: PairInvitation, ownDeviceID: String) throws -> PairConfiguration {
        guard invitation.format == "bridgedrop-invite-v1",
              invitation.pairID.count == 32,
              invitation.pairID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let secret = Data(base64Encoded: invitation.secret), secret.count == 32,
              UUID(uuidString: invitation.inviterID) != nil,
              invitation.inviterID != ownDeviceID, invitation.inviterName.count <= 100,
              !invitation.inviterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !invitation.inviterName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              invitation.port > 0, invitation.host.count <= 255,
              invitation.expiresAt.isFinite,
              invitation.expiresAt > Date().timeIntervalSince1970,
              invitation.expiresAt <= Date().addingTimeInterval(3660).timeIntervalSince1970 else {
            throw VaultError.invalidInvitation
        }
        let relayURL = invitation.relayURL ?? ""
        let relayToken = invitation.relayToken ?? ""
        if !relayURL.isEmpty {
            guard let url = URL(string: relayURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, relayToken.count >= 32, relayToken.count <= 1024 else { throw VaultError.invalidInvitation }
        }
        return PairConfiguration(pairID: invitation.pairID, secret: secret, relayURL: relayURL,
                                 relayToken: relayToken, trustedNames: [invitation.inviterID: invitation.inviterName],
                                 preferredHost: invitation.host, preferredPort: invitation.port)
    }
}
