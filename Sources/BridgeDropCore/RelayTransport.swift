import Foundation

public struct RelayPresence: Codable, Sendable {
    public let deviceID: String
    public let name: String
    public let lastSeen: Double
}
public struct RelayMessage: Codable, Sendable {
    public let requestID: String
    public let senderID: String
    public let packet: SecurePacket
}

public final class RelayTransport: @unchecked Sendable {
    public let baseURL: URL
    public let pairID: String
    private let token: String
    private let session: URLSession
    public init(baseURL: URL, pairID: String, token: String, allowLoopbackHTTP: Bool = false) throws {
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "")
        guard baseURL.scheme == "https" || (allowLoopbackHTTP && isLoopback && baseURL.scheme == "http"),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, (32...256).contains(token.utf8.count),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              pairID.count == 32, pairID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw TransportError.unavailable("互联网连接需要有效 HTTPS 地址和至少 32 位的独立服务器凭据。")
        }
        self.baseURL = baseURL; self.pairID = pairID; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    private func url(_ suffix: String, wait: Bool = false) -> URL {
        var url = baseURL
        for part in (["v1", "rooms", pairID] + suffix.split(separator: "/").map(String.init)) { url.appendPathComponent(part) }
        if wait { var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!; components.queryItems = [URLQueryItem(name: "wait", value: "20")]; return components.url! }
        return url
    }
    private func request(_ suffix: String, method: String = "GET", body: Data? = nil, wait: Bool = false) async throws -> (Data, Int) {
        var request = URLRequest(url: url(suffix, wait: wait))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TransportError.invalidFrame }
        guard (200..<300).contains(response.statusCode) else {
            let label = response.statusCode == 401 ? "服务器凭据无效" : "服务器返回错误 \(response.statusCode)"
            throw TransportError.unavailable(label)
        }
        guard data.count <= 18 * 1024 * 1024 else { throw TransportError.invalidFrame }
        return (data, response.statusCode)
    }
    public func presence(deviceID: String, name: String) async throws -> [RelayPresence] {
        struct Announcement: Encodable { let deviceID: String; let name: String }
        struct Listing: Decodable { let devices: [RelayPresence] }
        _ = try await request("presence", method: "POST", body: JSONEncoder().encode(Announcement(deviceID: deviceID, name: String(name.prefix(60)))))
        let (data, _) = try await request("presence")
        return try JSONDecoder().decode(Listing.self, from: data).devices
    }
    public func poll(deviceID: String) async throws -> [RelayMessage] {
        struct Listing: Decodable { let messages: [RelayMessage] }
        let (data, status) = try await request("messages/" + deviceID, wait: true)
        if status == 204 { return [] }
        return try JSONDecoder().decode(Listing.self, from: data).messages
    }
    public func respond(_ packet: SecurePacket) async throws {
        struct Response: Encodable { let packet: SecurePacket }
        _ = try await request("responses/" + packet.requestID, method: "POST", body: JSONEncoder().encode(Response(packet: packet)))
    }
    public func call(_ packet: SecurePacket) async throws -> SecurePacket {
        struct Submission: Encodable { let requestID: String; let senderID: String; let packet: SecurePacket }
        struct Response: Decodable { let packet: SecurePacket }
        _ = try await request("messages/" + packet.receiverID, method: "POST", body: JSONEncoder().encode(Submission(requestID: packet.requestID, senderID: packet.senderID, packet: packet)))
        let deadline = Date().addingTimeInterval(70)
        while Date() < deadline {
            try Task.checkCancellation()
            let (data, status) = try await request("responses/" + packet.requestID, wait: true)
            if status != 204 { return try JSONDecoder().decode(Response.self, from: data).packet }
        }
        throw TransportError.timeout
    }
}
