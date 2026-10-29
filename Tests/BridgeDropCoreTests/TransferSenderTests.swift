import Foundation
import XCTest
@testable import BridgeDropCore

private actor SenderHarness {
    var store: TransferStore
    let root: URL
    let receiver: String
    let sender: String
    var offers = 0
    var offsets: [Int64] = []
    var dropChunk = false
    var dropFinish = false
    var rejectOffer = false
    init(root: URL, receiver: String, sender: String, dropChunk: Bool = false, dropFinish: Bool = false, reject: Bool = false) throws {
        self.root = root; self.receiver = receiver; self.sender = sender
        self.dropChunk = dropChunk; self.dropFinish = dropFinish; rejectOffer = reject
        store = try TransferStore(root: root, ownDeviceID: receiver, ownDeviceName: "Receiver")
    }
    func call(_ request: WireRequest) async throws -> WireReply {
        let reply = try await store.handle(request, senderID: sender)
        if request.operation == .offer {
            offers += 1
            if reply.state == .awaitingApproval, let manifest = request.manifest {
                if rejectOffer { try await store.reject(manifest.id) }
                else { try await store.approve(manifest.id) }
            }
        }
        if request.operation == .chunk {
            offsets.append(request.offset ?? -1)
            if dropChunk {
                dropChunk = false
                store = try TransferStore(root: root, ownDeviceID: receiver, ownDeviceName: "Receiver")
                throw TransportError.closed // Stored ACK is lost, receiver also restarts.
            }
        }
        if request.operation == .finish, dropFinish {
            dropFinish = false
            store = try TransferStore(root: root, ownDeviceID: receiver, ownDeviceName: "Receiver")
            throw TransportError.timeout
        }
        return reply
    }
    func result() async -> (Int, [Int64], [TransferRecord]) { (offers, offsets, await store.records()) }
}
private actor CallCounter {
    var value = 0
    func increment() { value += 1 }
}

final class TransferSenderTests: XCTestCase {
    var root: URL!
    let sender = UUID().uuidString
    let receiver = UUID().uuidString
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDrop-sender-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func fixture(_ data: Data, kind: TransferKind = .file) throws -> (TransferManifest, URL) {
        let url = root.appendingPathComponent("source.bin")
        try data.write(to: url)
        return (TransferManifest(id: UUID().uuidString, kind: kind, name: "sample.bin", byteCount: Int64(data.count),
                                 sha256: FileDigest.sha256(data: data), senderID: sender, senderName: "Sender"), url)
    }
    var policy: TransferSendPolicy {
        var value = TransferSendPolicy(); value.retryBaseDelay = 0; value.approvalPollInterval = 0
        return value
    }
    private func verifySaved(_ harness: SenderHarness, data: Data) async throws -> (Int, [Int64]) {
        let result = await harness.result()
        XCTAssertEqual(result.2.count, 1)
        let record = try XCTUnwrap(result.2.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.receivedBytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(record.localPath))), data)
        return (result.0, result.1)
    }
    func testLostChunkACKAndReceiverRestartResumeFromDurableOffset() async throws {
        let data = Data((0..<800_017).map { UInt8($0 % 251) })
        let (manifest, source) = try fixture(data)
        let harness = try SenderHarness(root: root.appendingPathComponent("receiver"), receiver: receiver, sender: sender, dropChunk: true)
        try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { try await harness.call($0) })
        let result = try await verifySaved(harness, data: data)
        XCTAssertEqual(result.0, 2)
        XCTAssertEqual(result.1, [0, 262_144, 524_288, 786_432])
    }
    func testLostCompletionACKDoesNotDuplicateReceivedText() async throws {
        let data = Data(String(repeating: "原样\r\nété 📱\t", count: 31_000).utf8)
        let (manifest, source) = try fixture(data, kind: .text)
        let harness = try SenderHarness(root: root.appendingPathComponent("receiver"), receiver: receiver, sender: sender, dropFinish: true)
        try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { try await harness.call($0) })
        let result = try await verifySaved(harness, data: data)
        XCTAssertEqual(result.0, 2)
        let snapshot = await harness.result()
        XCTAssertEqual(snapshot.2.first?.text, String(data: data, encoding: .utf8))
    }
    func testZeroByteFileCompletesWithoutChunks() async throws {
        let (manifest, source) = try fixture(Data())
        let harness = try SenderHarness(root: root.appendingPathComponent("receiver"), receiver: receiver, sender: sender)
        try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { try await harness.call($0) })
        let result = try await verifySaved(harness, data: Data())
        XCTAssertTrue(result.1.isEmpty)
    }
    func testExplicitRejectionIsNotAutomaticallyRetried() async throws {
        let (manifest, source) = try fixture(Data("no".utf8))
        let harness = try SenderHarness(root: root.appendingPathComponent("receiver"), receiver: receiver, sender: sender, reject: true)
        do {
            try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { try await harness.call($0) })
            XCTFail("Rejection accepted")
        } catch TransferSendError.newOfferRequired { }
        let result = await harness.result()
        XCTAssertEqual(result.0, 1)
        XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(result.2.first?.state, .rejected)
    }
    func testFalseCompletionACKIsRejectedWithoutRetry() async throws {
        let (manifest, source) = try fixture(Data("must be saved".utf8))
        let calls = CallCounter()
        do {
            try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { _ in
                await calls.increment(); return WireReply(state: .completed, receivedBytes: 0)
            })
            XCTFail("False ACK accepted")
        } catch TransferSendError.invalidAcknowledgement { }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }
    func testSkippedChunkACKIsRejected() async throws {
        let (manifest, source) = try fixture(Data(repeating: 1, count: 600_000))
        do {
            try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { request in
                request.operation == .chunk ? WireReply(state: .receiving, receivedBytes: 600_000) : WireReply(state: .receiving)
            })
            XCTFail("Skipped offset accepted")
        } catch TransferSendError.invalidAcknowledgement { }
    }
    func testSourceSizeChangeStopsBeforeSendingBytes() async throws {
        let (manifest, source) = try fixture(Data("original".utf8))
        try Data("changed size".utf8).write(to: source)
        let calls = CallCounter()
        do {
            try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { _ in
                await calls.increment(); return WireReply(state: .receiving)
            })
            XCTFail("Changed source accepted")
        } catch TransferSendError.sourceChanged { }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }
    func testTransientRecoveryIsBounded() async throws {
        let (manifest, source) = try fixture(Data("retry".utf8))
        let calls = CallCounter()
        do {
            try await TransferSender.send(manifest: manifest, source: source, policy: policy, exchange: { _ in
                await calls.increment(); throw TransportError.closed
            })
            XCTFail("Permanent outage accepted")
        } catch TransportError.closed { }
        let count = await calls.value
        XCTAssertEqual(count, 5)
    }
    func testCancellationStopsDuringApprovalWithoutNewOffers() async throws {
        let (manifest, source) = try fixture(Data("cancel".utf8))
        let calls = CallCounter()
        var slowPolicy = policy; slowPolicy.approvalPollInterval = 30
        let task = Task {
            try await TransferSender.send(manifest: manifest, source: source, policy: slowPolicy, exchange: { _ in
                await calls.increment(); return WireReply(state: .awaitingApproval)
            })
        }
        while await calls.value == 0 { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError { }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }
    func testPermanentErrorsAreNotTransportRetries() {
        XCTAssertFalse(TransferRetry.isTransient(TransportError.invalidFrame))
        XCTAssertFalse(TransferRetry.isTransient(TransportError.unavailable("Invalid credential")))
        XCTAssertFalse(TransferRetry.isTransient(URLError(.cancelled)))
        XCTAssertFalse(TransferRetry.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(TransferRetry.isTransient(URLError(.networkConnectionLost)))
        XCTAssertEqual(TransferRetry.delay(failure: 20, jitter: 1), 16)
    }
}
