import Foundation
import Network
import BridgeDropCore

private actor Receiver {
    var store: TransferStore
    let root: URL
    let id: String
    let secret: Data
    let pairID: String
    init(root: URL, id: String, secret: Data, pairID: String) throws {
        self.root = root; self.id = id; self.secret = secret; self.pairID = pairID
        store = try TransferStore(root: root, ownDeviceID: id, ownDeviceName: "测试接收端")
    }
    func process(_ packet: SecurePacket) async throws -> SecurePacket {
        guard packet.receiverID == id, packet.pairID == pairID else { throw TransportError.invalidFrame }
        let request = try PacketCrypto.open(packet, secret: secret, as: WireRequest.self)
        let reply = try await store.handle(request, senderID: packet.senderID)
        return try PacketCrypto.seal(reply, secret: secret, pairID: pairID, senderID: id,
                                     receiverID: packet.senderID, requestID: packet.requestID)
    }
    func approve(_ id: String) async throws { try await store.approve(id) }
    func restart() throws { store = try TransferStore(root: root, ownDeviceID: id, ownDeviceName: "测试接收端") }
    func records() async -> [TransferRecord] { await store.records() }
}

private actor DroppedAcknowledgements {
    var chunk = true
    var finish = true
    func drop(_ operation: WireOperation) -> Bool {
        if operation == .chunk, chunk { chunk = false; return true }
        if operation == .finish, finish { finish = false; return true }
        return false
    }
}

@main struct BridgeDropCheck {
    static func main() async {
        do {
            let mode = CommandLine.arguments.dropFirst().first ?? "local"
            try await run(mode: mode)
        } catch {
            fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func run(mode: String) async throws {
        let sender = UUID().uuidString, recipient = UUID().uuidString
        let pairID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDrop-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = try Receiver(root: root, id: recipient, secret: secret, pairID: pairID)
        var server: LocalServer?
        var relaySender: RelayTransport?
        var relayReceiver: RelayTransport?
        var pollTask: Task<Void, Never>?
        defer { server?.stop(); pollTask?.cancel() }
        var endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 49185)
        if mode == "local" {
            let port = UInt16.random(in: 49152...59999)
            endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            server = try LocalServer(port: port, deviceID: recipient, onState: { _ in }, handler: { packet in try await receiver.process(packet) })
            server?.start()
            try await Task.sleep(nanoseconds: 500_000_000)
        } else {
            guard let url = URL(string: mode), let token = ProcessInfo.processInfo.environment["BRIDGEDROP_RELAY_TOKEN"] else {
                throw TransportError.unavailable("Relay check requires URL argument and token in environment.")
            }
            relaySender = try RelayTransport(baseURL: url, pairID: pairID, token: token, allowLoopbackHTTP: true)
            relayReceiver = try RelayTransport(baseURL: url, pairID: pairID, token: token, allowLoopbackHTTP: true)
            let transport = relayReceiver!
            _ = try await transport.presence(deviceID: sender, name: "测试发送端")
            _ = try await transport.presence(deviceID: recipient, name: "测试接收端")
            pollTask = Task {
                while !Task.isCancelled {
                    do {
                        for message in try await transport.poll(deviceID: recipient) {
                            let response = try await receiver.process(message.packet)
                            try await transport.respond(response)
                        }
                    } catch { if !Task.isCancelled { fputs("relay receiver: \(error.localizedDescription)\n", stderr) }; return }
                }
            }
        }
        let activeRelaySender = relaySender
        let activeEndpoint = endpoint
        @Sendable func call(_ request: WireRequest) async throws -> WireReply {
            let packet = try PacketCrypto.seal(request, secret: secret, pairID: pairID, senderID: sender,
                                              receiverID: recipient, requestID: UUID().uuidString)
            let response: SecurePacket
            if let activeRelaySender { response = try await activeRelaySender.call(packet) }
            else { response = try await LocalExchange.call(packet, endpoint: activeEndpoint) }
            guard response.receiverID == sender, response.senderID == recipient, response.requestID == packet.requestID,
                  response.pairID == pairID else { throw TransportError.invalidFrame }
            return try PacketCrypto.open(response, secret: secret, as: WireReply.self)
        }
        let ping = try await call(WireRequest(operation: .ping, senderName: "测试发送端"))
        guard ping.deviceID == recipient else { throw TransportError.invalidFrame }
        let fixtures: [(TransferKind, String, Data)] = [
            (.text, "文本", Data("中文、法语 été、emoji 📱\n第二行\t原样保留".utf8)),
            (.file, "校验文件.bin", Data((0..<(700 * 1024 + 37)).map { UInt8($0 % 251) })),
            (.file, "空文件.txt", Data())
        ]
        for (kind, name, content) in fixtures {
            let id = UUID().uuidString
            let manifest = TransferManifest(id: id, kind: kind, name: name, byteCount: Int64(content.count),
                                            sha256: FileDigest.sha256(data: content), senderID: sender, senderName: "测试发送端")
            let offer = try await call(WireRequest(operation: .offer, manifest: manifest))
            guard offer.state == .awaitingApproval else { throw TransportError.invalidFrame }
            try await receiver.approve(id)
            var offset = 0
            while offset < content.count {
                let chunk = content.subdata(in: offset..<min(content.count, offset + 256 * 1024))
                let reply = try await call(WireRequest(operation: .chunk, transferID: id, offset: Int64(offset), data: chunk))
                guard reply.receivedBytes == Int64(offset + chunk.count) else { throw TransportError.invalidFrame }
                if offset == 0 {
                    try await receiver.restart()
                    let replay = try await call(WireRequest(operation: .chunk, transferID: id, offset: 0, data: chunk))
                    guard replay.receivedBytes == reply.receivedBytes else { throw TransportError.invalidFrame }
                    let recovered = try await call(WireRequest(operation: .status, transferID: id))
                    guard recovered.receivedBytes == reply.receivedBytes else { throw TransportError.invalidFrame }
                }
                offset += chunk.count
            }
            let finish = try await call(WireRequest(operation: .finish, transferID: id))
            guard finish.state == .completed else { throw TransportError.unavailable(finish.message ?? "not completed") }
            let repeatedFinish = try await call(WireRequest(operation: .finish, transferID: id))
            guard repeatedFinish.state == .completed else { throw TransportError.invalidFrame }
            let records = await receiver.records()
            guard let record = records.first(where: { $0.id == id }), let path = record.localPath,
                  try Data(contentsOf: URL(fileURLWithPath: path)) == content else { throw TransportError.invalidFrame }
            print("PASS \(kind.rawValue) \(content.count) bytes · approval, chunk replay, restart, SHA-256, saved acknowledgement")
        }
        let recoveryData = Data((0..<(3 * 1024 * 1024 + 17)).map { UInt8($0 % 239) })
        let recoveryID = UUID().uuidString
        let recoveryManifest = TransferManifest(id: recoveryID, kind: .file, name: "recovery.bin",
            byteCount: Int64(recoveryData.count), sha256: FileDigest.sha256(data: recoveryData), senderID: sender, senderName: "Test sender")
        let recoverySource = root.appendingPathComponent("sender-source.bin")
        try recoveryData.write(to: recoverySource)
        let faults = DroppedAcknowledgements()
        var policy = TransferSendPolicy(); policy.retryBaseDelay = 0.01; policy.approvalPollInterval = 0.01
        try await TransferSender.send(manifest: recoveryManifest, source: recoverySource, policy: policy, exchange: { request in
            let reply = try await call(request)
            if request.operation == .offer, reply.state == .awaitingApproval { try await receiver.approve(recoveryID) }
            if await faults.drop(request.operation) {
                try await receiver.restart()
                throw TransportError.closed
            }
            return reply
        })
        let recoveredRecords = await receiver.records().filter { $0.id == recoveryID }
        guard recoveredRecords.count == 1, recoveredRecords[0].state == .completed,
              let savedPath = recoveredRecords[0].localPath,
              try Data(contentsOf: URL(fileURLWithPath: savedPath)) == recoveryData else { throw TransportError.invalidFrame }
        print("PASS automatic sender recovery · 3 MiB, lost chunk/completion ACKs, receiver restarts, one exact saved file")
        print("PASS \(mode == "local" ? "local TCP" : "HTTP relay") encrypted end-to-end integration")
    }
}
