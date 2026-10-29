import Foundation
#if !CORE_STANDALONE
import XCTest
@testable import BridgeDropCore
#endif

final class PacketCryptoTests: XCTestCase {
    private let pairID = "0123456789abcdef0123456789abcdef"
    private let senderID = "AFA25342-B0E3-4204-BD69-2212E8E58A9D"
    private let receiverID = "F0C8C6A0-2D07-4C8D-9E89-F6CA45074373"
    private let requestID = "7AA59086-7DDB-4B63-9F81-3E9287818C49"
    private let secret = Data(repeating: 0x34, count: 32)

    private func packet() throws -> SecurePacket {
        try PacketCrypto.seal(WireRequest(operation: .ping, senderName: "测试"), secret: secret,
                              pairID: pairID, senderID: senderID, receiverID: receiverID, requestID: requestID)
    }

    func testEncryptedRoundTripAndFreshNonces() throws {
        let first = try packet()
        let second = try packet()
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        let request = try PacketCrypto.open(first, secret: secret, as: WireRequest.self)
        XCTAssertEqual(request.operation, .ping)
        XCTAssertEqual(request.senderName, "测试")
        let json = try JSONEncoder().encode(first)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("测试"))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(secret.base64EncodedString()))
    }

    func testCiphertextAndEveryRoutingFieldAreAuthenticated() throws {
        let original = try packet()
        var tampered = original.ciphertext
        tampered[tampered.count - 1] ^= 1
        let changedPackets = [
            SecurePacket(pairID: pairID, senderID: senderID, receiverID: receiverID, requestID: requestID, ciphertext: tampered),
            SecurePacket(pairID: "ffffffffffffffffffffffffffffffff", senderID: senderID, receiverID: receiverID, requestID: requestID, ciphertext: original.ciphertext),
            SecurePacket(pairID: pairID, senderID: UUID().uuidString, receiverID: receiverID, requestID: requestID, ciphertext: original.ciphertext),
            SecurePacket(pairID: pairID, senderID: senderID, receiverID: UUID().uuidString, requestID: requestID, ciphertext: original.ciphertext),
            SecurePacket(pairID: pairID, senderID: senderID, receiverID: receiverID, requestID: UUID().uuidString, ciphertext: original.ciphertext)
        ]
        for changed in changedPackets {
            XCTAssertThrowsError(try PacketCrypto.open(changed, secret: secret, as: WireRequest.self))
        }
        XCTAssertThrowsError(try PacketCrypto.open(original, secret: Data(repeating: 0x35, count: 32), as: WireRequest.self))
    }

    func testMalformedSecretAndUnboundedMetadataAreRejected() throws {
        XCTAssertThrowsError(try PacketCrypto.seal("x", secret: Data(repeating: 0, count: 31),
                                                  pairID: pairID, senderID: senderID, receiverID: receiverID, requestID: requestID))
        XCTAssertThrowsError(try PacketCrypto.seal("x", secret: secret, pairID: "../room",
                                                  senderID: senderID, receiverID: receiverID, requestID: requestID))
        XCTAssertThrowsError(try PacketCrypto.seal("x", secret: secret, pairID: pairID,
                                                  senderID: String(repeating: "A", count: 50_000), receiverID: receiverID, requestID: requestID))
        let truncated = SecurePacket(pairID: pairID, senderID: senderID, receiverID: receiverID,
                                     requestID: requestID, ciphertext: Data(repeating: 0, count: 27))
        XCTAssertThrowsError(try PacketCrypto.open(truncated, secret: secret, as: WireRequest.self))
        XCTAssertThrowsError(try PacketCrypto.seal(String(repeating: "x", count: 1_048_577), secret: secret,
                                                  pairID: pairID, senderID: senderID, receiverID: receiverID, requestID: requestID))
    }
}
