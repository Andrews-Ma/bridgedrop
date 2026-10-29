import Foundation
#if !CORE_STANDALONE
import XCTest
@testable import BridgeDropCore
#endif

final class TransferStoreTests: XCTestCase {
    private var root: URL!
    private let senderID = "AFA25342-B0E3-4204-BD69-2212E8E58A9D"
    private let receiverID = "F0C8C6A0-2D07-4C8D-9E89-F6CA45074373"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDropTests-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func store() throws -> TransferStore {
        try TransferStore(root: root, ownDeviceID: receiverID, ownDeviceName: "接收测试设备")
    }

    private func manifest(_ data: Data, kind: TransferKind = .file, name: String = "报告.txt",
                          id: String = UUID().uuidString, hash: String? = nil) -> TransferManifest {
        TransferManifest(id: id, kind: kind, name: name, byteCount: Int64(data.count),
                         sha256: hash ?? FileDigest.sha256(data: data), senderID: senderID,
                         senderName: "发送测试设备", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func offer(_ manifest: TransferManifest, to store: TransferStore) async throws -> WireReply {
        try await store.handle(WireRequest(operation: .offer, manifest: manifest), senderID: senderID)
    }

    private func send(_ data: Data, offset: Int64, id: String, to store: TransferStore) async throws -> WireReply {
        try await store.handle(WireRequest(operation: .chunk, transferID: id, offset: offset, data: data), senderID: senderID)
    }

    private func finish(_ id: String, store: TransferStore) async throws -> WireReply {
        try await store.handle(WireRequest(operation: .finish, transferID: id), senderID: senderID)
    }

    private func expectError(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected rejection", file: file, line: line)
        } catch { }
    }

    func testApprovalRequiredBeforeAnyBytesAreAccepted() async throws {
        let store = try store()
        let bytes = Data("审批保护".utf8)
        let item = manifest(bytes)
        let initial = try await offer(item, to: store)
        XCTAssertEqual(initial.state, .awaitingApproval)
        await expectError { _ = try await self.send(bytes, offset: 0, id: item.id, to: store) }
        await expectError { _ = try await self.finish(item.id, store: store) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Partial/" + item.id + ".part").path))
        let records = await store.records()
        XCTAssertEqual(records.first?.receivedBytes, 0)
        try await store.reject(item.id)
        let repeated = try await offer(item, to: store)
        XCTAssertEqual(repeated.state, .rejected)
        await expectError { try await store.approve(item.id) }
    }

    func testDurableOffsetSurvivesRestartAndIdenticalChunkReplay() async throws {
        let first = try store()
        let data = Data("a persistent transfer with 汉字".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        let prefix = Data(data.prefix(12))
        let ack = try await send(prefix, offset: 0, id: item.id, to: first)
        XCTAssertEqual(ack.receivedBytes, 12)

        let second = try store()
        let recovered = try await second.handle(WireRequest(operation: .status, transferID: item.id), senderID: senderID)
        XCTAssertEqual(recovered.state, .receiving)
        XCTAssertEqual(recovered.receivedBytes, 12)
        let duplicate = try await send(prefix, offset: 0, id: item.id, to: second)
        XCTAssertEqual(duplicate.receivedBytes, 12)
        await expectError { _ = try await self.send(Data(repeating: 0xff, count: 12), offset: 0, id: item.id, to: second) }
        let suffix = Data(data.dropFirst(12))
        _ = try await send(suffix, offset: 12, id: item.id, to: second)
        let complete = try await finish(item.id, store: second)
        XCTAssertEqual(complete.state, .completed)
        let records = await second.records()
        let path = try XCTUnwrap(records.first?.localPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(try FileDigest.sha256(url: URL(fileURLWithPath: path)), item.sha256)
        let third = try store()
        let durable = try await third.handle(WireRequest(operation: .status, transferID: item.id), senderID: senderID)
        XCTAssertEqual(durable.state, .completed)
        XCTAssertEqual(durable.receivedBytes, Int64(data.count))
    }

    func testUncommittedTailIsTruncatedOnRestart() async throws {
        let first = try store()
        let data = Data("committed then uncommitted".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        _ = try await send(Data(data.prefix(9)), offset: 0, id: item.id, to: first)
        let partial = root.appendingPathComponent("Partial/" + item.id + ".part")
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("CRASH TAIL".utf8))
        try handle.close()
        let recovered = try store()
        let records = await recovered.records()
        XCTAssertEqual(records.first?.receivedBytes, 9)
        XCTAssertEqual(try Data(contentsOf: partial), Data(data.prefix(9)))
        _ = try await send(Data(data.dropFirst(9)), offset: 9, id: item.id, to: recovered)
        let result = try await finish(item.id, store: recovered)
        XCTAssertEqual(result.state, .completed)
    }

    func testShortPartialRollsOffsetBackAndResumes() async throws {
        let first = try store()
        let data = Data("recover shorter durable storage".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        _ = try await send(Data(data.prefix(16)), offset: 0, id: item.id, to: first)
        let partial = root.appendingPathComponent("Partial/" + item.id + ".part")
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: 5)
        try handle.close()
        let recovered = try store()
        let records = await recovered.records()
        XCTAssertEqual(records.first?.receivedBytes, 5)
        _ = try await send(Data(data.dropFirst(5)), offset: 5, id: item.id, to: recovered)
        let result = try await finish(item.id, store: recovered)
        XCTAssertEqual(result.state, .completed)
    }

    func testChunkLedgerFailureDoesNotAcknowledgeUnsavedOffset() async throws {
        let first = try store()
        let data = Data("write succeeded but ledger commit failed".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        let ledger = root.appendingPathComponent("Ledger/" + item.id + ".json")
        let savedLedger = try Data(contentsOf: ledger)
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        await expectError { _ = try await self.send(data, offset: 0, id: item.id, to: first) }
        let inMemory = await first.records()
        XCTAssertEqual(inMemory.first?.receivedBytes, 0)
        let partial = root.appendingPathComponent("Partial/" + item.id + ".part")
        XCTAssertEqual(try Data(contentsOf: partial), data)
        try FileManager.default.removeItem(at: ledger)
        try savedLedger.write(to: ledger)
        let recovered = try store()
        XCTAssertEqual(try Data(contentsOf: partial), Data())
        _ = try await send(data, offset: 0, id: item.id, to: recovered)
        let finished = try await finish(item.id, store: recovered)
        XCTAssertEqual(finished.state, .completed)
    }

    func testFinishLedgerFailureDoesNotReturnSuccessAndCanRecover() async throws {
        let first = try store()
        let data = Data("final rename succeeded but final ledger failed".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        _ = try await send(data, offset: 0, id: item.id, to: first)
        let ledger = root.appendingPathComponent("Ledger/" + item.id + ".json")
        let savedLedger = try Data(contentsOf: ledger)
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        await expectError { _ = try await self.finish(item.id, store: first) }
        let inMemory = await first.records()
        XCTAssertEqual(inMemory.first?.state, .receiving)
        XCTAssertNil(inMemory.first?.localPath)
        let final = root.appendingPathComponent("Received/" + item.id + "-" + item.name)
        XCTAssertEqual(try Data(contentsOf: final), data)
        try FileManager.default.removeItem(at: ledger)
        try savedLedger.write(to: ledger)
        let recovered = try store()
        let verified = await recovered.records()
        XCTAssertEqual(verified.first?.state, .completed)
        XCTAssertEqual(verified.first?.localPath, final.path)
    }

    func testRenameBeforeLedgerCommitRecoversVerifiedCompletion() async throws {
        let first = try store()
        let data = Data("rename crash window".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: first)
        try await first.approve(item.id)
        _ = try await send(data, offset: 0, id: item.id, to: first)
        let partial = root.appendingPathComponent("Partial/" + item.id + ".part")
        let target = root.appendingPathComponent("Received/" + item.id + "-" + item.name)
        try FileManager.default.moveItem(at: partial, to: target)
        let recovered = try store()
        let records = await recovered.records()
        XCTAssertEqual(records.first?.state, .completed)
        XCTAssertEqual(records.first?.localPath, target.path)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testBadHashNeverProducesCompletedACK() async throws {
        let store = try store()
        let data = Data("wrong expected hash".utf8)
        let item = manifest(data, hash: String(repeating: "0", count: 64))
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        _ = try await send(data, offset: 0, id: item.id, to: store)
        let result = try await finish(item.id, store: store)
        XCTAssertEqual(result.state, .failed)
        let records = await store.records()
        XCTAssertNil(records.first?.localPath)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Received").path).contains { !$0.hasPrefix(".") })
        let recovered = try self.store()
        let durable = await recovered.records()
        XCTAssertEqual(durable.first?.state, .failed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Partial/" + item.id + ".part")), data)
    }

    func testUTF8TextAndInvalidUTF8() async throws {
        let store = try store()
        let text = "中文\nFrançais\n🙂\0末尾"
        let data = Data(text.utf8)
        let good = manifest(data, kind: .text, name: "文本.txt")
        _ = try await offer(good, to: store)
        try await store.approve(good.id)
        _ = try await send(data, offset: 0, id: good.id, to: store)
        let result = try await finish(good.id, store: store)
        XCTAssertEqual(result.state, .completed)
        let records = await store.records()
        XCTAssertEqual(records.first(where: { $0.id == good.id })?.text, text)
        let restored = try self.store()
        let restoredRecords = await restored.records()
        XCTAssertEqual(restoredRecords.first(where: { $0.id == good.id })?.text, text)

        let invalid = Data([0xc3, 0x28])
        let bad = manifest(invalid, kind: .text)
        _ = try await offer(bad, to: restored)
        try await restored.approve(bad.id)
        _ = try await send(invalid, offset: 0, id: bad.id, to: restored)
        let failed = try await finish(bad.id, store: restored)
        XCTAssertEqual(failed.state, .failed)
        let failedRecords = await restored.records()
        XCTAssertNil(failedRecords.first(where: { $0.id == bad.id })?.text)
    }

    func testZeroByteFileFinishesAndCancelDoesNotDeleteCompletion() async throws {
        let store = try store()
        let item = manifest(Data(), name: "空文件.bin")
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        let complete = try await finish(item.id, store: store)
        XCTAssertEqual(complete.state, .completed)
        let cancelled = try await store.handle(WireRequest(operation: .cancel, transferID: item.id), senderID: senderID)
        XCTAssertEqual(cancelled.state, .completed)
        let repeated = try await finish(item.id, store: store)
        XCTAssertEqual(repeated.state, .completed)
        let records = await store.records()
        let path = try XCTUnwrap(records.first?.localPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data())
    }

    func testEmptyTextCanBeSavedAndRestored() async throws {
        let store = try store()
        let item = manifest(Data(), kind: .text, name: "empty.txt")
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        let result = try await finish(item.id, store: store)
        XCTAssertEqual(result.state, .completed)
        let restored = try self.store()
        let records = await restored.records()
        XCTAssertEqual(records.first?.text, "")
    }

    func testMaximumTextWithJSONEscapesSurvivesRestart() async throws {
        let store = try store()
        let data = Data(repeating: 0, count: 1_048_576)
        let item = manifest(data, kind: .text, name: "boundary.txt")
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        for index in 0..<4 {
            let offset = index * 262_144
            _ = try await send(Data(data[offset..<(offset + 262_144)]), offset: Int64(offset), id: item.id, to: store)
        }
        let complete = try await finish(item.id, store: store)
        XCTAssertEqual(complete.state, .completed)
        let restored = try self.store()
        let records = await restored.records()
        XCTAssertEqual(records.first?.state, .completed)
        XCTAssertEqual(records.first?.text?.utf8.count, data.count)
    }

    func testLongChinesePDFNameKeepsExtensionAfterRealSave() async throws {
        let store = try store()
        let data = Data("%PDF-1.7\nBridgeDrop filename preservation check\n%%EOF".utf8)
        let item = manifest(data, name: String(repeating: "测", count: 80) + ".pdf")
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        _ = try await send(data, offset: 0, id: item.id, to: store)
        let complete = try await finish(item.id, store: store)
        XCTAssertEqual(complete.state, .completed)
        let records = await store.records()
        let savedURL = URL(fileURLWithPath: try XCTUnwrap(records.first?.localPath))
        XCTAssertEqual(savedURL.pathExtension, "pdf")
        let basename = String(savedURL.lastPathComponent.dropFirst(item.id.count + 1))
        XCTAssertEqual(basename.hasSuffix(".pdf"), true)
        XCTAssertEqual(basename.utf8.count <= 180, true)
        XCTAssertEqual(try Data(contentsOf: savedURL), data)
        let restored = try self.store()
        let restoredRecords = await restored.records()
        XCTAssertEqual(restoredRecords.first?.localPath, savedURL.path)
        XCTAssertEqual(restoredRecords.first?.state, .completed)
    }

    func testPathsLimitsOffsetsAndOwnershipAreRejected() async throws {
        let store = try store()
        let data = Data("0123456789".utf8)
        for name in ["../../outside", "/absolute", "folder\\file", "..", "bad\0name"] {
            let item = manifest(data, name: name)
            await expectError { _ = try await self.offer(item, to: store) }
        }
        let invalidID = manifest(data, id: "../outside")
        await expectError { _ = try await self.offer(invalidID, to: store) }
        let oversize = TransferManifest(id: UUID().uuidString, kind: .text, name: "large.txt",
                                        byteCount: 1_048_577, sha256: FileDigest.sha256(data: data),
                                        senderID: senderID, senderName: "sender")
        await expectError { _ = try await self.offer(oversize, to: store) }
        let item = manifest(data)
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        await expectError { _ = try await self.send(Data([0]), offset: 1, id: item.id, to: store) }
        await expectError { _ = try await self.send(Data([0]), offset: -1, id: item.id, to: store) }
        await expectError { _ = try await self.send(Data(repeating: 0, count: 262_145), offset: 0, id: item.id, to: store) }
        await expectError { _ = try await self.send(Data(repeating: 0, count: 11), offset: 0, id: item.id, to: store) }
        await expectError {
            _ = try await store.handle(WireRequest(operation: .status, transferID: item.id), senderID: UUID().uuidString)
        }
        let changed = manifest(data, name: "changed.txt", id: item.id)
        await expectError { _ = try await self.offer(changed, to: store) }
        let records = await store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.receivedBytes, 0)
    }

    func testOverlappingReplayCannotAdvanceOffset() async throws {
        let store = try store()
        let data = Data("0123456789".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        _ = try await send(Data(data.prefix(5)), offset: 0, id: item.id, to: store)
        await expectError { _ = try await self.send(Data(data[3..<8]), offset: 3, id: item.id, to: store) }
        let records = await store.records()
        XCTAssertEqual(records.first?.receivedBytes, 5)
        let incomplete = try await finish(item.id, store: store)
        XCTAssertEqual(incomplete.state, .receiving)
        XCTAssertEqual(incomplete.receivedBytes, 5)
    }

    func testFilesystemSymlinkCannotRedirectWriting() async throws {
        let store = try store()
        let data = Data("safe".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: store)
        let outside = root.appendingPathComponent("outside.bin")
        try Data("unchanged".utf8).write(to: outside)
        let partial = root.appendingPathComponent("Partial/" + item.id + ".part")
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: outside)
        await expectError { try await store.approve(item.id) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
    }

    func testMissingCompletedFileIsNotReportedAsCompletedAfterRestart() async throws {
        let store = try store()
        let data = Data("durable success".utf8)
        let item = manifest(data)
        _ = try await offer(item, to: store)
        try await store.approve(item.id)
        _ = try await send(data, offset: 0, id: item.id, to: store)
        _ = try await finish(item.id, store: store)
        let records = await store.records()
        let file = try XCTUnwrap(records.first?.localPath)
        try FileManager.default.removeItem(atPath: file)
        let recovered = try self.store()
        let restored = await recovered.records()
        XCTAssertEqual(restored.first?.state, .failed)
        XCTAssertNil(restored.first?.localPath)
    }

    func testStreamingDigestMatchesKnownVector() throws {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(FileDigest.sha256(data: Data("abc".utf8)), expected)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("hash.bin")
        let data = Data(repeating: 0xa5, count: 2_500_001)
        try data.write(to: url)
        XCTAssertEqual(try FileDigest.sha256(url: url), FileDigest.sha256(data: data))
    }
}
