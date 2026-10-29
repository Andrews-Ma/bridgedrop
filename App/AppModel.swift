import Foundation
import SwiftUI
import Network
#if SWIFT_PACKAGE
import BridgeDropCore
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct Peer: Identifiable {
    let id: String
    var name: String
    var detail: String
}
struct OutgoingTransfer: Identifiable {
    let id: String
    var name: String
    var state: String
    var progress: Double
    var error: String?
}
private struct SendJob: Codable {
    let manifest: TransferManifest
    let path: String
    let receiverID: String
    let pairID: String
    var state: String
    var progress: Double
    var error: String?
}
@MainActor final class AppModel: ObservableObject {
    @Published var name: String
    @Published var nearby: [Peer] = []
    @Published var selectedPeerID: String?
    @Published var records: [TransferRecord] = []
    @Published var outgoing: [OutgoingTransfer] = []
    @Published var status = "准备连接"
    @Published var textDraft = ""
    @Published var inviteText = ""
    @Published private(set) var inviteLink = ""
    @Published var pairingMode = 0
    @Published var pairingDraft = ""
    @Published private(set) var pairingPreview: PairInvitation?
    @Published private(set) var pairingValidationMessage: String?
    @Published private(set) var pairingReviewID = UUID()
    @Published private(set) var isReviewPending = false
    @Published var relayURL = ""
    @Published var relayToken = ""
    @Published var manualHost = ""
    @Published var manualPort = "47185"
    @Published var errorMessage: String?
    @Published var scanning = false
    @Published var isRunning = false
    @Published var showInvite = false

    private let deviceID: String
    private let root: URL
    private var configuration: PairConfiguration
    private var store: TransferStore?
    private var server: LocalServer?
    private var discovery: LocalDiscovery?
    private var relay: RelayTransport?
    private var endpoints: [String: NWEndpoint] = [:]
    private var discovered: [NWEndpoint] = []
    private var lastSeen: [String: Date] = [:]
    private var jobs: [SendJob] = []
    private var sendTasks: [String: Task<Void, Never>] = [:]
    private var queuedSends: [String] = []
    private var preparationTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var isProbing = false
    private let activity = TransferActivity()
    private var refreshTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var relayPresenceTask: Task<Void, Never>?
    private var responseCache: [String: (Data, SecurePacket)] = [:]
    private var initializationError: String?
    private let savePairing: (PairConfiguration) throws -> Void
    private let exchangeOverride: (@Sendable (WireRequest, String) async throws -> WireReply)?
    private var pairingNeedsSave = false

    init(deviceID: String = PairingVault.deviceID, dataRoot: URL? = nil,
         loadPairing: () throws -> PairConfiguration? = PairingVault.load,
         savePairing: @escaping (PairConfiguration) throws -> Void = PairingVault.save,
         exchangeOverride: (@Sendable (WireRequest, String) async throws -> WireReply)? = nil) {
        self.deviceID = deviceID
        self.savePairing = savePairing
        self.exchangeOverride = exchangeOverride
        name = UserDefaults.standard.string(forKey: "BridgeDrop.name") ?? PairingVault.defaultName
        let base: URL
        #if os(iOS)
        base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        root = dataRoot ?? base.appendingPathComponent("BridgeDrop", isDirectory: true)
        do {
            let stored = try loadPairing()
            configuration = try stored ?? PairConfiguration.fresh()
            pairingNeedsSave = stored == nil
        } catch {
            // Never silently replace an unreadable stored pairing key.
            configuration = PairConfiguration(pairID: "", secret: Data(), relayURL: "", relayToken: "", trustedNames: [:], preferredHost: "", preferredPort: 47185)
            initializationError = error.localizedDescription
        }
        relayURL = configuration.relayURL; relayToken = configuration.relayToken
        manualHost = configuration.preferredHost; manualPort = String(configuration.preferredPort)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            store = try TransferStore(root: root, ownDeviceID: deviceID, ownDeviceName: name)
            let data = try? Data(contentsOf: root.appendingPathComponent("outgoing.json"))
            if let data { jobs = try JSONDecoder().decode([SendJob].self, from: data) }
            for index in jobs.indices where !["已送达", "已取消"].contains(jobs[index].state) {
                jobs[index].state = "可继续"; jobs[index].error = "应用已重新打开，点击继续从断点传输。"
            }
            syncOutgoing()
        } catch { initializationError = error.localizedDescription }
    }

    func start() {
        guard !isRunning, !isReviewPending else { return }
        if let initializationError { errorMessage = initializationError; status = "初始化失败"; return }
        guard store != nil, configuration.secret.count == 32 else { return }
        do {
            if pairingNeedsSave { try savePairing(configuration); pairingNeedsSave = false }
        } catch { errorMessage = error.localizedDescription; return }
        isRunning = true
        do {
            server = try LocalServer(deviceID: deviceID, onState: { [weak self] value in
                Task { @MainActor in self?.status = value }
            }, handler: { [weak self] packet in
                guard let self else { throw TransportError.closed }
                return try await self.process(packet)
            })
            server?.start()
            discovery = LocalDiscovery(ownDeviceID: deviceID) { [weak self] endpoints in
                Task { @MainActor in self?.discovered = endpoints; await self?.probeDiscovered() }
            }
            discovery?.start()
        } catch { status = "局域网接收未开启：" + error.localizedDescription }
        refreshInvite()
        refreshTask = Task { [weak self] in
            var counter = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshRecords()
                if counter % 5 == 0 { await self.probeDiscovered(); await self.probePreferredHost(); self.expirePeers() }
                counter += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        configureRelay()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.endpoints.removeAll()
                self.refreshInvite()
                await self.probeDiscovered()
                await self.probePreferredHost()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "BridgeDrop.Path"))
        Task { await probePreferredHost() }
    }

    func stop() {
        isRunning = false
        pathMonitor?.cancel(); pathMonitor = nil
        activity.setActive(false)
        let waiting = queuedSends; queuedSends.removeAll()
        for id in waiting { updateJob(id, state: "可继续", error: "传输已暂停，开启连接后可继续。") }
        server?.stop(); server = nil; discovery?.stop(); discovery = nil
        refreshTask?.cancel(); refreshTask = nil
        relayTask?.cancel(); relayTask = nil; relayPresenceTask?.cancel(); relayPresenceTask = nil
        relay = nil
        for (id, task) in sendTasks {
            task.cancel(); updateJob(id, state: "可继续", error: "传输已暂停，返回应用后点击继续。")
        }
        // Keep cancelled tasks registered until their cleanup finishes, so a quick
        // foreground/retry cannot create a second sender for the same transfer.
        status = "接收已暂停，重新打开应用后继续"
    }

    func refreshInvite() {
        let invitation = PairInvitation(format: "bridgedrop-invite-v1", pairID: configuration.pairID,
                                        secret: configuration.secret.base64EncodedString(), inviterID: deviceID,
                                        inviterName: String(name.prefix(100)), host: Self.localAddress(), port: 47185,
                                        relayURL: configuration.relayURL.isEmpty ? nil : configuration.relayURL,
                                        relayToken: configuration.relayToken.isEmpty ? nil : configuration.relayToken,
                                        expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(invitation)
            inviteText = String(data: data, encoding: .utf8) ?? ""
            inviteLink = try PairingInviteCodec.link(for: inviteText).absoluteString
        } catch { inviteText = ""; inviteLink = ""; errorMessage = "无法生成邀请，请检查本机配对配置。" }
    }

    /// All external entry points stage a review; none may save trust or start networking.
    func receivePairingInput(_ text: String) {
        if errorMessage == pairingValidationMessage { errorMessage = nil }
        scanning = false
        pairingMode = 1
        pairingDraft = text.utf8.count <= PairingInviteCodec.maximumInputBytes ? text : ""
        isReviewPending = true
        pairingPreview = nil
        pairingValidationMessage = nil
        pairingReviewID = UUID() // Even an identical second link revokes the previous UI confirmation.
        do {
            let preview = try PairingInviteCodec.preview(text, ownDeviceID: deviceID)
            pairingDraft = preview.rawJSON
            pairingPreview = preview.invitation
        } catch { pairingValidationMessage = error.localizedDescription }
        showInvite = true
    }

    func reviewPairingDraft() {
        pairingPreview = nil
        pairingValidationMessage = nil
        if pairingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isReviewPending = true
        do { pairingPreview = try PairingInviteCodec.preview(pairingDraft, ownDeviceID: deviceID).invitation }
        catch { pairingValidationMessage = error.localizedDescription }
    }

    func dismissPairingReview() { isReviewPending = false }

    @discardableResult func importInvite(_ text: String) -> Bool {
        do {
            // Revalidate at confirmation time, including expiry since the preview was shown.
            let preview = try PairingInviteCodec.preview(text, ownDeviceID: deviceID)
            let invitation = preview.invitation
            let newConfiguration = preview.configuration
            try savePairing(newConfiguration)
            pairingNeedsSave = false
            stop(); configuration = newConfiguration; responseCache.removeAll()
            endpoints.removeAll(); nearby.removeAll(); lastSeen.removeAll(); selectedPeerID = invitation.inviterID
            manualHost = newConfiguration.preferredHost; manualPort = String(newConfiguration.preferredPort)
            relayURL = newConfiguration.relayURL; relayToken = newConfiguration.relayToken
            isReviewPending = false; pairingPreview = nil; pairingDraft = ""
            pairingValidationMessage = nil; errorMessage = nil
            showInvite = false; start(); status = "配对信息已保存，正在连接 " + invitation.inviterName
            return true
        } catch {
            pairingPreview = nil
            pairingValidationMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveRelay() {
        do {
            let address = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty {
                guard let url = URL(string: address) else { throw TransportError.invalidFrame }
                _ = try RelayTransport(baseURL: url, pairID: configuration.pairID, token: token)
            }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VaultError.storage("设备名称请填写 1 到 100 个字符。")
            }
            configuration.relayURL = address; configuration.relayToken = address.isEmpty ? "" : token
            try savePairing(configuration)
            UserDefaults.standard.set(name, forKey: "BridgeDrop.name")
            refreshInvite(); configureRelay(); status = address.isEmpty ? "设置已保存，使用局域网连接" : "设置已保存，正在连接互联网服务"
        } catch { errorMessage = error.localizedDescription }
    }

    func connectManual(silently: Bool = false) {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 255, let port = UInt16(manualPort), port > 0 else {
            errorMessage = "请输入有效设备地址和端口。"; return
        }
        configuration.preferredHost = host; configuration.preferredPort = port
        do { try savePairing(configuration) } catch { errorMessage = error.localizedDescription; return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let expectedID = configuration.trustedNames.keys.first
        Task {
            if let expectedID {
                let connected = await probe(endpoint, expectedID: expectedID)
                if !connected && !silently { errorMessage = "无法连接该设备。请检查地址、两端配对信息、本地网络权限，并保持对方应用打开。" }
            }
            else { errorMessage = "请先扫描或导入对方的邀请码，再使用手动地址连接。" }
        }
    }

    func selectPeer(_ peer: Peer) { selectedPeerID = peer.id }

    private func process(_ packet: SecurePacket) async throws -> SecurePacket {
        guard packet.pairID == configuration.pairID, packet.receiverID == deviceID,
              packet.senderID != deviceID, let store else { throw TransportError.invalidFrame }
        let fingerprintEncoder = JSONEncoder(); fingerprintEncoder.outputFormatting = [.sortedKeys]
        let fingerprint = FileDigest.sha256(data: try fingerprintEncoder.encode(packet))
        if let cached = responseCache[packet.requestID] {
            guard cached.0 == Data(fingerprint.utf8) else { throw TransportError.invalidFrame }
            return cached.1
        }
        let pair = configuration
        let request = try PacketCrypto.open(packet, secret: pair.secret, as: WireRequest.self)
        let savedReply = try await store.handle(request, senderID: packet.senderID)
        let reply = request.operation == .ping ? WireReply(deviceID: deviceID, deviceName: name) : savedReply
        if request.operation == .ping { remember(packet.senderID, name: request.senderName ?? "已配对设备", detail: "已配对 · 连接可用") }
        let encrypted = try PacketCrypto.seal(reply, secret: pair.secret, pairID: pair.pairID,
                                             senderID: deviceID, receiverID: packet.senderID, requestID: packet.requestID)
        if responseCache.count >= 256 { responseCache.removeAll(keepingCapacity: true) }
        responseCache[packet.requestID] = (Data(fingerprint.utf8), encrypted)
        await refreshRecords()
        return encrypted
    }

    private func remember(_ id: String, name: String, detail: String) {
        guard UUID(uuidString: id) != nil, id != deviceID else { return }
        let boundedName = String(name.prefix(100)); lastSeen[id] = Date()
        if let index = nearby.firstIndex(where: { $0.id == id }) { nearby[index].name = boundedName; nearby[index].detail = detail }
        else { nearby.append(Peer(id: id, name: boundedName, detail: detail)) }
        if selectedPeerID == nil { selectedPeerID = id }
        if configuration.trustedNames[id] != boundedName {
            configuration.trustedNames[id] = boundedName
            do { try savePairing(configuration) } catch { errorMessage = error.localizedDescription }
        }
    }
    private func expirePeers() {
        nearby.removeAll { Date().timeIntervalSince(lastSeen[$0.id] ?? .distantPast) > 100 }
    }
    private func probePreferredHost() async {
        guard isRunning, !configuration.preferredHost.isEmpty,
              let expectedID = selectedPeerID ?? configuration.trustedNames.keys.sorted().first,
              endpoints[expectedID] == nil else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(configuration.preferredHost),
                                          port: NWEndpoint.Port(rawValue: configuration.preferredPort)!)
        await probe(endpoint, expectedID: expectedID)
    }
    private func probeDiscovered() async {
        guard !isProbing, isRunning else { return }
        isProbing = true
        defer { isProbing = false }
        for endpoint in discovered.prefix(32) {
            guard !Task.isCancelled, isRunning else { return }
            if case .service(let serviceName, _, _, _) = endpoint,
               serviceName.hasPrefix("BridgeDrop-"), let id = serviceName.split(separator: "-", maxSplits: 1).last.map(String.init),
               UUID(uuidString: id) != nil { await probe(endpoint, expectedID: id) }
        }
    }
    @discardableResult private func probe(_ endpoint: NWEndpoint, expectedID: String) async -> Bool {
        do {
            let packet = try PacketCrypto.seal(WireRequest(operation: .ping, senderName: name), secret: configuration.secret,
                                              pairID: configuration.pairID, senderID: deviceID, receiverID: expectedID, requestID: UUID().uuidString)
            let response = try await LocalExchange.call(packet, endpoint: endpoint)
            try verifyResponse(response, request: packet)
            let reply = try PacketCrypto.open(response, secret: configuration.secret, as: WireReply.self)
            guard isRunning, configuration.pairID == packet.pairID, reply.deviceID == expectedID else { throw TransportError.invalidFrame }
            endpoints[expectedID] = endpoint
            remember(expectedID, name: reply.deviceName ?? "已配对设备", detail: "局域网直连")
            return true
        } catch {
            // Another BridgeDrop instance may belong to a different pair. Never trust Bonjour alone.
            return false
        }
    }
    private func verifyResponse(_ response: SecurePacket, request: SecurePacket) throws {
        guard response.pairID == request.pairID, response.requestID == request.requestID,
              response.senderID == request.receiverID, response.receiverID == deviceID else { throw TransportError.invalidFrame }
    }

    private func configureRelay() {
        relayTask?.cancel(); relayPresenceTask?.cancel(); relay = nil
        guard isRunning, !configuration.relayURL.isEmpty else { return }
        do {
            guard let url = URL(string: configuration.relayURL) else { throw TransportError.invalidFrame }
            let transport = try RelayTransport(baseURL: url, pairID: configuration.pairID, token: configuration.relayToken)
            relay = transport
            relayPresenceTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    do {
                        let devices = try await transport.presence(deviceID: self.deviceID, name: self.name)
                        for device in devices where device.deviceID != self.deviceID {
                            // Relay presence is untrusted until an encrypted ping is authenticated.
                            if self.configuration.trustedNames[device.deviceID] != nil { await self.probeRelay(device, transport: transport) }
                        }
                    } catch { if !Task.isCancelled { self.status = "互联网连接暂不可用，局域网仍可使用" } }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
            relayTask = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    do {
                        let messages = try await transport.poll(deviceID: self.deviceID)
                        for message in messages {
                            try Task.checkCancellation()
                            let response: SecurePacket
                            do {
                                response = try await self.process(message.packet)
                            } catch {
                                // A malformed queued message must not block unrelated transfers.
                                if message.packet.pairID == self.configuration.pairID,
                                   message.packet.receiverID == self.deviceID,
                                   UUID(uuidString: message.packet.senderID) != nil,
                                   UUID(uuidString: message.packet.requestID) != nil {
                                    response = try PacketCrypto.seal(WireReply(message: "接收请求无效，请重新发送。"),
                                                                    secret: self.configuration.secret, pairID: self.configuration.pairID,
                                                                    senderID: self.deviceID, receiverID: message.packet.senderID,
                                                                    requestID: message.packet.requestID)
                                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                                    let fingerprint = FileDigest.sha256(data: try encoder.encode(message.packet))
                                    self.responseCache[message.packet.requestID] = (Data(fingerprint.utf8), response)
                                } else { throw error }
                            }
                            // Network failure here must never replace a valid completion response.
                            try await transport.respond(response)
                        }
                        failures = 0
                    } catch {
                        failures += 1
                        if !Task.isCancelled { self.status = "互联网接收等待恢复连接" }
                        let seconds = min(30, 1 << min(failures, 4))
                        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func probeRelay(_ presence: RelayPresence, transport: RelayTransport) async {
        do {
            let packet = try PacketCrypto.seal(WireRequest(operation: .ping, senderName: name), secret: configuration.secret,
                                              pairID: configuration.pairID, senderID: deviceID, receiverID: presence.deviceID, requestID: UUID().uuidString)
            let response = try await transport.call(packet); try verifyResponse(response, request: packet)
            let reply = try PacketCrypto.open(response, secret: configuration.secret, as: WireReply.self)
            guard reply.deviceID == presence.deviceID else { throw TransportError.invalidFrame }
            remember(presence.deviceID, name: reply.deviceName ?? "已配对设备", detail: endpoints[presence.deviceID] == nil ? "互联网连接" : "局域网直连 · 互联网备用")
        } catch { }
    }

    private func exchange(_ request: WireRequest, receiverID: String) async throws -> WireReply {
        try Task.checkCancellation()
        if let exchangeOverride { return try await exchangeOverride(request, receiverID) }
        let packet = try PacketCrypto.seal(request, secret: configuration.secret, pairID: configuration.pairID,
                                          senderID: deviceID, receiverID: receiverID, requestID: UUID().uuidString)
        var lastError: Error = TransportError.closed
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let response: SecurePacket
                if let endpoint = endpoints[receiverID] {
                    do { response = try await LocalExchange.call(packet, endpoint: endpoint) }
                    catch { if let relay { response = try await relay.call(packet) } else { throw error } }
                } else if let relay { response = try await relay.call(packet) }
                else { throw TransportError.peerUnavailable }
                try verifyResponse(response, request: packet)
                return try PacketCrypto.open(response, secret: configuration.secret, as: WireReply.self)
            } catch {
                lastError = error; try Task.checkCancellation()
                guard TransferRetry.isTransient(error) else { throw error }
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
            }
        }
        throw lastError
    }

    func sendText() {
        guard let recipient = selectedPeerID else { errorMessage = "请先选择已配对设备。"; return }
        let data = Data(textDraft.utf8)
        guard !data.isEmpty, data.count <= 1024 * 1024 else { errorMessage = "文本请保持在 1 MiB 以内。"; return }
        do {
            let id = UUID().uuidString
            let url = try outbox().appendingPathComponent(id + ".txt")
            try data.write(to: url, options: .atomic)
            let manifest = TransferManifest(id: id, kind: .text, name: "文本", byteCount: Int64(data.count),
                                            sha256: FileDigest.sha256(data: data), senderID: deviceID, senderName: name)
            jobs.append(SendJob(manifest: manifest, path: url.path, receiverID: recipient, pairID: configuration.pairID, state: "准备发送", progress: 0, error: nil))
            try persistJobs(); syncOutgoing(); beginSend(id)
        } catch { errorMessage = error.localizedDescription }
    }

    func sendFiles(_ urls: [URL]) {
        guard let recipient = selectedPeerID else { errorMessage = "请先选择已配对设备。"; return }
        guard urls.count <= 20 else { errorMessage = "每次最多选择 20 个文件。文件夹请先压缩为 ZIP。"; return }
        for url in urls {
            let ownsScope = url.startAccessingSecurityScopedResource()
            let id = UUID().uuidString; let pairID = configuration.pairID; let senderID = deviceID; let senderName = name
            do {
                let destination = try outbox().appendingPathComponent(id + ".source")
                outgoing.append(OutgoingTransfer(id: id, name: url.lastPathComponent, state: "准备文件", progress: 0, error: nil))
                let previousPreparation = preparationTask
                preparationTask = Task {
                    await previousPreparation?.value
                    do {
                        let result = try await Task.detached(priority: .userInitiated) { () throws -> (Int64, String) in
                            defer { if ownsScope { url.stopAccessingSecurityScopedResource() } }
                            let coordinator = NSFileCoordinator()
                            var coordinationError: NSError?
                            var copyError: Error?
                            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                                do {
                                    let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                                    guard values.isRegularFile == true, let size = values.fileSize, size <= 10 * 1024 * 1024 * 1024 else {
                                        throw VaultError.storage("请选择不超过 10 GiB 的普通文件；文件夹请先压缩。")
                                    }
                                    try FileManager.default.copyItem(at: readable, to: destination)
                                } catch { copyError = error }
                            }
                            if let coordinationError { throw coordinationError }
                            if let copyError { throw copyError }
                            let copied = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                            guard copied >= 0, copied <= 10 * 1024 * 1024 * 1024 else { throw VaultError.storage("暂存文件大小无效。") }
                            return (Int64(copied), try FileDigest.sha256(url: destination))
                        }.value
                        var safeName = url.lastPathComponent.replacingOccurrences(of: "\\", with: "_")
                        safeName = safeName.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "_" : String($0) }.joined()
                        while safeName.utf8.count > 255 { safeName.removeLast() }
                        let manifest = TransferManifest(id: id, kind: .file, name: safeName, byteCount: result.0,
                                                        sha256: result.1, senderID: senderID, senderName: senderName)
                        jobs.append(SendJob(manifest: manifest, path: destination.path, receiverID: recipient, pairID: pairID, state: "准备发送", progress: 0, error: nil))
                        try persistJobs(); syncOutgoing(); beginSend(id)
                    } catch {
                        if let index = outgoing.firstIndex(where: { $0.id == id }) { outgoing[index].state = "准备失败"; outgoing[index].error = error.localizedDescription }
                        errorMessage = error.localizedDescription
                    }
                }
            } catch { if ownsScope { url.stopAccessingSecurityScopedResource() }; errorMessage = error.localizedDescription }
        }
    }
    private func outbox() throws -> URL {
        let directory = root.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }
    private func beginSend(_ id: String) {
        guard sendTasks[id] == nil, !queuedSends.contains(id), let job = jobs.first(where: { $0.manifest.id == id }) else { return }
        guard isRunning else { updateJob(id, state: "可继续", error: "接收已暂停，请开启连接后继续。"); return }
        guard job.pairID == configuration.pairID else { updateJob(id, state: "发送失败", error: "配对已更换，请重新选择文件发送。"); return }
        guard sendTasks.count < 2 else {
            queuedSends.append(id)
            updateJob(id, state: "排队等待", error: nil)
            return
        }
        sendTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await TransferSender.send(manifest: job.manifest, source: URL(fileURLWithPath: job.path),
                    exchange: { request in try await self.exchange(request, receiverID: job.receiverID) },
                    progress: { value in await self.showSendProgress(value, id: id) })
            } catch let error as TransferSendError {
                let needsNew: Bool
                switch error { case .newOfferRequired, .sourceChanged: needsNew = true; default: needsNew = false }
                self.updateJob(id, state: needsNew ? "需重新发送" : "可继续", error: error.localizedDescription)
            } catch {
                if Task.isCancelled {
                    if self.jobs.first(where: { $0.manifest.id == id })?.state != "已取消" {
                        self.updateJob(id, state: "可继续", error: "传输已暂停。")
                    }
                } else { self.updateJob(id, state: "可继续", error: error.localizedDescription) }
            }
            self.sendTasks.removeValue(forKey: id)
            self.scheduleQueuedSends()
            self.updateActivity()
        }
        updateActivity()
    }
    private func scheduleQueuedSends() {
        while isRunning, sendTasks.count < 2, !queuedSends.isEmpty {
            let id = queuedSends.removeFirst()
            beginSend(id)
        }
    }
    private func showSendProgress(_ value: TransferSendProgress, id: String) {
        // A late callback after a user's cancel must not resurrect the job.
        guard jobs.first(where: { $0.manifest.id == id })?.state != "已取消", isRunning else { return }
        switch value {
        case .awaitingApproval: updateJob(id, state: "等待对方接收", error: nil)
        case .sending(let bytes, let total): updateJob(id, state: "正在传输", progress: Double(bytes) / Double(max(1, total)), error: nil)
        case .reconnecting(let attempt): updateJob(id, state: "等待恢复连接", error: "正在自动重试（\(attempt)/4），已保存的数据会从断点继续。")
        case .verifying: updateJob(id, state: "等待校验与保存", error: nil)
        case .completed: updateJob(id, state: "已送达", progress: 1, error: nil)
        }
    }
    private func updateActivity() {
        activity.setActive(isRunning && (!sendTasks.isEmpty || records.contains { $0.state == .receiving }))
    }
    func retry(_ transfer: OutgoingTransfer) {
        guard let old = jobs.first(where: { $0.manifest.id == transfer.id }), old.state != "已送达" else { return }
        if ["已取消", "需重新发送"].contains(old.state) {
            guard old.pairID == configuration.pairID else { errorMessage = "配对已更换，请重新选择文件发送。"; return }
            let manifest = TransferManifest(id: UUID().uuidString, kind: old.manifest.kind, name: old.manifest.name,
                                            byteCount: old.manifest.byteCount, sha256: old.manifest.sha256,
                                            senderID: deviceID, senderName: name)
            jobs.append(SendJob(manifest: manifest, path: old.path, receiverID: old.receiverID,
                                pairID: old.pairID, state: "准备发送", progress: 0, error: nil))
            do { try persistJobs(); syncOutgoing(); beginSend(manifest.id) } catch { errorMessage = error.localizedDescription }
        } else { beginSend(transfer.id) }
    }
    func cancel(_ transfer: OutgoingTransfer) {
        guard let existing = jobs.first(where: { $0.manifest.id == transfer.id }),
              !["已送达", "已取消"].contains(existing.state) else { return }
        queuedSends.removeAll { $0 == transfer.id }
        sendTasks[transfer.id]?.cancel()
        updateJob(transfer.id, state: "已取消", error: nil)
        if let job = jobs.first(where: { $0.manifest.id == transfer.id }), job.pairID == configuration.pairID {
            Task { _ = try? await exchange(WireRequest(operation: .cancel, transferID: transfer.id), receiverID: job.receiverID) }
        }
    }
    private func updateJob(_ id: String, state: String, progress: Double? = nil, error: String?) {
        guard let index = jobs.firstIndex(where: { $0.manifest.id == id }) else { return }
        jobs[index].state = state; if let progress { jobs[index].progress = progress }; jobs[index].error = error
        do { try persistJobs() } catch { errorMessage = "无法保存发送进度：" + error.localizedDescription }
        syncOutgoing()
    }
    private func persistJobs() throws {
        try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("outgoing.json"), options: .atomic)
    }
    private func syncOutgoing() {
        let preparing = outgoing.filter { entry in !jobs.contains(where: { $0.manifest.id == entry.id }) }
        outgoing = jobs.reversed().map { OutgoingTransfer(id: $0.manifest.id, name: $0.manifest.name, state: $0.state, progress: $0.progress, error: $0.error) } + preparing
    }

    private func refreshRecords() async { if let store { records = await store.records(); updateActivity() } }
    func approve(_ record: TransferRecord) {
        Task { do { try await store?.approve(record.id); await refreshRecords() } catch { errorMessage = error.localizedDescription } }
    }
    func reject(_ record: TransferRecord) {
        Task { do { try await store?.reject(record.id); await refreshRecords() } catch { errorMessage = error.localizedDescription } }
    }
    func copyText(_ record: TransferRecord) {
        guard record.state == .completed, let text = record.text else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
        #endif
        status = "文本已复制，可粘贴到其他应用"
    }
    func reveal(_ record: TransferRecord) {
        guard record.state == .completed, let path = record.localPath else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #else
        status = "请用分享按钮导出，或在“文件 → 我的 iPhone → 轻传”中查找。"
        #endif
    }
    func forgetPairing() {
        do {
            let fresh = try PairConfiguration.fresh(); try savePairing(fresh)
            stop(); configuration = fresh; responseCache.removeAll(); nearby.removeAll(); endpoints.removeAll(); lastSeen.removeAll()
            selectedPeerID = nil; relayURL = ""; relayToken = ""; manualHost = ""; manualPort = "47185"
            start(); status = "旧配对已解除，请重新扫描二维码"
        } catch { errorMessage = error.localizedDescription }
    }

    static func localAddress() -> String {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return "" }
        defer { freeifaddrs(addresses) }
        var found: [(String, String)] = []
        var pointer = addresses
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((String(cString: current.pointee.ifa_name), String(cString: buffer)))
            }
        }
        return (found.first { $0.0 == "en0" } ?? found.first { $0.0.hasPrefix("en") } ?? found.first)?.1 ?? ""
    }
}
