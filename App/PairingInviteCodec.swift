import Foundation

enum InviteInputError: LocalizedError {
    case tooLong, invalidLink, unsupportedVersion, invalidPayload, invalidJSON
    var errorDescription: String? {
        switch self {
        case .tooLong: return "邀请内容过长，请重新扫描轻传生成的二维码。"
        case .invalidLink: return "不是有效的轻传配对链接，或链接参数缺失、重复、格式不正确。"
        case .unsupportedVersion: return "不支持此配对链接版本，请更新轻传或重新生成邀请。"
        case .invalidPayload: return "邀请链接的数据编码无效，请重新扫描或完整复制。"
        case .invalidJSON: return "邀请码内容损坏或字段不完整，请重新生成邀请。"
        }
    }
}

/// Pure decoding/validation. This type never accesses Keychain, opens URLs or connects.
enum PairingInviteCodec {
    static let scheme = "org.local.bridgedrop"
    static let maximumJSONBytes = 8192
    static let maximumPayloadBytes = (maximumJSONBytes * 4 + 2) / 3
    static let maximumInputBytes = 12 * 1024

    struct Preview {
        let invitation: PairInvitation
        let rawJSON: String
        let configuration: PairConfiguration
    }

    static func link(for rawJSON: String) throws -> URL {
        let data = Data(rawJSON.utf8)
        guard !data.isEmpty, data.count <= maximumJSONBytes else { throw InviteInputError.tooLong }
        _ = try decodeJSON(data)
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "v", value: "1"),
                                 URLQueryItem(name: "payload", value: base64URL(data))]
        guard let url = components.url else { throw InviteInputError.invalidLink }
        return url
    }

    static func preview(_ input: String, ownDeviceID: String) throws -> Preview {
        guard input.utf8.count <= maximumInputBytes else { throw InviteInputError.tooLong }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if text.hasPrefix("{") {
            data = Data(text.utf8)
            guard data.count <= maximumJSONBytes else { throw InviteInputError.tooLong }
        } else {
            guard let components = URLComponents(string: text),
                  components.scheme == scheme, components.host == "pair",
                  components.percentEncodedHost == "pair", components.path.isEmpty,
                  components.user == nil, components.password == nil, components.port == nil,
                  components.fragment == nil,
                  let items = components.queryItems, items.count == 2,
                  items.filter({ $0.name == "v" }).count == 1,
                  items.filter({ $0.name == "payload" }).count == 1 else { throw InviteInputError.invalidLink }
            guard items.first(where: { $0.name == "v" })?.value == "1" else { throw InviteInputError.unsupportedVersion }
            guard let payload = items.first(where: { $0.name == "payload" })?.value,
                  !payload.isEmpty else { throw InviteInputError.invalidPayload }
            guard payload.utf8.count <= maximumPayloadBytes else { throw InviteInputError.tooLong }
            guard payload.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95 }), payload.utf8.count % 4 != 1 else {
                throw InviteInputError.invalidPayload
            }
            let padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
            guard let decoded = Data(base64Encoded: padded), decoded.count <= maximumJSONBytes,
                  base64URL(decoded) == payload else { throw InviteInputError.invalidPayload }
            data = decoded
        }
        let invitation = try decodeJSON(data)
        // Retain all existing format, key-length, expiry and device-ID checks.
        let configuration = try PairingVault.validate(invitation, ownDeviceID: ownDeviceID)
        guard let rawJSON = String(data: data, encoding: .utf8) else { throw InviteInputError.invalidJSON }
        return Preview(invitation: invitation, rawJSON: rawJSON, configuration: configuration)
    }

    private static func decodeJSON(_ data: Data) throws -> PairInvitation {
        do { return try JSONDecoder().decode(PairInvitation.self, from: data) }
        catch { throw InviteInputError.invalidJSON } // Never include payload or decoder context in errors.
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
