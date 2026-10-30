import Foundation

private actor QueuePeer {
    var manifests: [String: TransferManifest] = [:]
    var offered: Set<String> = []
    var active: Set<String> = []
    var maximum = 0
    var held = true
    var gates: [CheckedContinuation<Void, Never>] = []
    func call(_ request: WireRequest) async throws -> WireReply {
        if request.operation == .offer, let item = request.manifest {
            manifests[item.id] = item; offered.insert(item.id); active.insert(item.id)
            maximum = max(maximum, active.count)
            if held { await withCheckedContinuation { gates.append($0) } }
            try Task.checkCancellation()
            return WireReply(state: .receiving)
        }
        guard let id = request.transferID else { throw TransportError.invalidFrame }
        if request.operation == .cancel { active.remove(id); return WireReply(state: .cancelled) }
        guard let item = manifests[id] else { throw TransportError.invalidFrame }
        if request.operation == .chunk {
            return WireReply(state: .receiving, receivedBytes: (request.offset ?? 0) + Int64(request.data?.count ?? 0))
        }
        if request.operation == .finish { active.remove(id); return WireReply(state: .completed, receivedBytes: item.byteCount) }
        return WireReply(state: .receiving)
    }
    func release() { held = false; let saved = gates; gates.removeAll(); for gate in saved { gate.resume() } }
    func snapshot() -> (Int, Set<String>) { (maximum, offered) }
}
@main struct ModelTransferChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDrop-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = QueuePeer()
        let pair = try PairConfiguration.fresh()
        var writes = 0
        let model = AppModel(deviceID: UUID().uuidString, dataRoot: root,
            loadPairing: { pair }, savePairing: { _ in writes += 1 },
            exchangeOverride: { request, _ in try await peer.call(request) })
        model.isRunning = true // Isolated transport; never start a listener or touch Keychain.
        model.selectedPeerID = UUID().uuidString
        for index in 0..<5 { model.textDraft = "Synthetic queue fixture \(index)"; model.sendText() }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw TransportError.timeout }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await waitFor { model.outgoing.filter { $0.state == "排队等待" }.count == 3 }
        let queued = model.outgoing.first { $0.state == "排队等待" }!
        model.cancel(queued)
        await peer.release()
        try await waitFor { model.outgoing.filter { $0.state == "已送达" }.count == 4 }
        let result = await peer.snapshot()
        guard result.0 == 2, result.1.count == 4, !result.1.contains(queued.id), writes == 0,
              model.outgoing.first(where: { $0.id == queued.id })?.state == "已取消" else { throw TransportError.invalidFrame }
        print("PASS real AppModel queue: two workers, queued cancellation never offered, four deliveries, no pairing writes")
        model.stop()
        model.textDraft = "Paused synthetic fixture"; model.sendText()
        guard model.outgoing.first?.state == "可继续" else { throw TransportError.invalidFrame }
        let before = await peer.snapshot().1.count
        model.isRunning = true
        let pending = model.outgoing.first!
        model.retry(pending); model.retry(pending)
        try await waitFor { model.outgoing.first(where: { $0.id == pending.id })?.state == "已送达" }
        let after = await peer.snapshot().1.count
        guard after == before + 1 else { throw TransportError.invalidFrame }
        guard model.textDraft.isEmpty else { throw TransportError.invalidFrame }
        let completed = model.outgoing.first(where: { $0.id == pending.id })!
        model.removeOutgoingHistory(completed)
        guard !model.outgoing.contains(where: { $0.id == completed.id }) else { throw TransportError.invalidFrame }
        let reopened = AppModel(deviceID: UUID().uuidString, dataRoot: root,
            loadPairing: { pair }, savePairing: { _ in writes += 1 })
        guard !reopened.outgoing.contains(where: { $0.id == completed.id }) else { throw TransportError.invalidFrame }
        model.stop()
        print("PASS pause, explicit resume, rapid duplicate retry never starts a second sender")
        print("PASS removing finished outgoing history persists across restart")
        let heldPeer = QueuePeer()
        let draftModel = AppModel(deviceID: UUID().uuidString, dataRoot: root.appendingPathComponent("draft"),
            loadPairing: { pair }, savePairing: { _ in }, exchangeOverride: { request, _ in try await heldPeer.call(request) })
        draftModel.isRunning = true
        draftModel.selectedPeerID = UUID().uuidString
        draftModel.textDraft = "submitted text"
        draftModel.sendText()
        try await waitFor { draftModel.outgoing.first?.state == "准备发送" || draftModel.outgoing.first?.state == "等待对方接收" }
        draftModel.textDraft = "new text"
        await heldPeer.release()
        try await waitFor { draftModel.outgoing.first?.state == "已送达" }
        guard draftModel.textDraft == "new text" else { throw TransportError.invalidFrame }
        draftModel.textDraft = "finished text"
        draftModel.sendText()
        try await waitFor { draftModel.outgoing.first?.state == "已送达" }
        guard draftModel.textDraft.isEmpty else { throw TransportError.invalidFrame }
        draftModel.isRunning = false
        draftModel.textDraft = "pending text"
        draftModel.sendText()
        let unfinishedID = draftModel.outgoing.first!.id
        draftModel.clearOutgoingHistory()
        guard draftModel.outgoing.count == 1, draftModel.outgoing.first?.id == unfinishedID,
              draftModel.textDraft == "pending text" else { throw TransportError.invalidFrame }
        print("PASS delivered draft clearing, edited draft preservation, and bulk outgoing cleanup preserving resumable work")
        let suite = "BridgeDrop-auto-test-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let trusted = UUID().uuidString, unknown = UUID().uuidString, receiver = UUID().uuidString
        var paired = try PairConfiguration.fresh()
        paired.trustedNames[trusted] = "Test peer"
        let autoRoot = root.appendingPathComponent("auto")
        let auto = AppModel(deviceID: receiver, dataRoot: autoRoot,
                            loadPairing: { paired }, savePairing: { _ in }, preferences: prefs)
        func offer(_ sender: String, _ text: String, secret: Data? = nil) throws -> SecurePacket {
            let bytes = Data(text.utf8)
            let manifest = TransferManifest(id: UUID().uuidString, kind: .text, name: "text", byteCount: Int64(bytes.count),
                                            sha256: FileDigest.sha256(data: bytes), senderID: sender, senderName: "Test peer")
            return try PacketCrypto.seal(WireRequest(operation: .offer, manifest: manifest), secret: secret ?? paired.secret,
                                         pairID: paired.pairID, senderID: sender, receiverID: receiver, requestID: UUID().uuidString)
        }
        func state(_ packet: SecurePacket) async throws -> TransferState? {
            try PacketCrypto.open(try await auto.process(packet), secret: paired.secret, as: WireReply.self).state
        }
        let pendingPacket = try offer(trusted, "existing request")
        guard try await state(pendingPacket) == .awaitingApproval else { throw TransportError.invalidFrame }
        auto.autoAcceptEnabled = true
        let trustedPacket = try offer(trusted, "new request")
        let pendingRequest = try PacketCrypto.open(pendingPacket, secret: paired.secret, as: WireRequest.self)
        let repeatedPending = try PacketCrypto.seal(pendingRequest, secret: paired.secret, pairID: paired.pairID,
                                                     senderID: trusted, receiverID: receiver, requestID: UUID().uuidString)
        guard try await state(trustedPacket) == .receiving,
              try await state(try offer(unknown, "unknown")) == .awaitingApproval,
              try await state(repeatedPending) == .awaitingApproval else { throw TransportError.invalidFrame }
        let badPacket = try offer(trusted, "bad key", secret: Data(repeating: 7, count: 32))
        do { _ = try await auto.process(badPacket); throw TransportError.invalidFrame }
        catch is PacketCryptoError { }
        catch { if error is TransportError { throw error } }
        let restoredAuto = AppModel(deviceID: receiver, dataRoot: autoRoot,
                                    loadPairing: { paired }, savePairing: { _ in }, preferences: prefs)
        guard restoredAuto.autoAcceptEnabled else { throw TransportError.invalidFrame }
        let differentPair = try PairConfiguration.fresh()
        let other = AppModel(deviceID: receiver, dataRoot: root.appendingPathComponent("other"),
                             loadPairing: { differentPair }, savePairing: { _ in }, preferences: prefs)
        guard !other.autoAcceptEnabled else { throw TransportError.invalidFrame }
        auto.autoAcceptEnabled = false
        guard try await state(try offer(trusted, "disabled")) == .awaitingApproval else { throw TransportError.invalidFrame }
        print("PASS auto-accept defaults off, authenticates trusted peers, preserves pending requests, persists per pairing, and disables immediately")
        let discoveryModel = AppModel(deviceID: UUID().uuidString, dataRoot: root.appendingPathComponent("discovery"),
                                      loadPairing: { pair }, savePairing: { _ in }, preferences: prefs)
        let peerID = UUID().uuidString
        discoveryModel.remember(peerID, name: "Discovery test", detail: "Local")
        guard discoveryModel.selectedPeerID == peerID else { throw TransportError.invalidFrame }
        discoveryModel.expirePeers(now: Date().addingTimeInterval(101))
        guard discoveryModel.nearby.isEmpty, discoveryModel.selectedPeerID == nil else { throw TransportError.invalidFrame }
        discoveryModel.remember(peerID, name: "Discovery test", detail: "Local")
        guard discoveryModel.selectedPeerID == peerID else { throw TransportError.invalidFrame }
        print("PASS stale peer expiration clears selection and permits rediscovery")
    }
}
