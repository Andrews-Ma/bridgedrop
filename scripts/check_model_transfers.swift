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
        model.stop()
        print("PASS pause, explicit resume, rapid duplicate retry never starts a second sender")
    }
}
