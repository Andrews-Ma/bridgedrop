#if CORE_STANDALONE
import Foundation

// Runs the actual XCTest test methods when Command Line Tools lacks XCTest.
// These assertion adapters record failures; this is a standalone check, not an XCTest run.
class XCTestCase {
    func setUpWithError() throws { }
    func tearDownWithError() throws { }
}

private enum CheckAssertions {
    static var failures: [String] = []
    static func fail(_ message: String, file: StaticString, line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }
}

private struct CheckFailure: Error {
    let message: String
}

func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    CheckAssertions.fail(message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                                  _ expected: @autoclosure () throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let left = try actual()
        let right = try expected()
        if left != right { XCTFail("Expected \(right), got \(left)", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                                     _ expected: @autoclosure () throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try actual() == expected() { XCTFail("Values unexpectedly match", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() { XCTFail("Expected false", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?,
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() != nil { XCTFail("Expected nil", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
        XCTFail("Expected error", file: file, line: line)
    } catch { }
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    if let value = try expression() { return value }
    XCTFail("Expected a value", file: file, line: line)
    throw CheckFailure(message: "Unwrap failed")
}

@main
struct CoreCheckRunner {
    static func main() async {
        let storeTests = TransferStoreTests()
        let cryptoTests = PacketCryptoTests()
        let tests: [(String, XCTestCase, () async throws -> Void)] = [
            ("approval gating", storeTests, { try await storeTests.testApprovalRequiredBeforeAnyBytesAreAccepted() }),
            ("durable resume and identical replay", storeTests, { try await storeTests.testDurableOffsetSurvivesRestartAndIdenticalChunkReplay() }),
            ("uncommitted tail recovery", storeTests, { try await storeTests.testUncommittedTailIsTruncatedOnRestart() }),
            ("short partial recovery", storeTests, { try await storeTests.testShortPartialRollsOffsetBackAndResumes() }),
            ("chunk ledger failure never ACKs unsaved offset", storeTests, { try await storeTests.testChunkLedgerFailureDoesNotAcknowledgeUnsavedOffset() }),
            ("finish ledger failure never ACKs completion", storeTests, { try await storeTests.testFinishLedgerFailureDoesNotReturnSuccessAndCanRecover() }),
            ("rename crash window", storeTests, { try await storeTests.testRenameBeforeLedgerCommitRecoversVerifiedCompletion() }),
            ("hash mismatch", storeTests, { try await storeTests.testBadHashNeverProducesCompletedACK() }),
            ("UTF-8 and invalid UTF-8", storeTests, { try await storeTests.testUTF8TextAndInvalidUTF8() }),
            ("zero-byte file and cancel after completion", storeTests, { try await storeTests.testZeroByteFileFinishesAndCancelDoesNotDeleteCompletion() }),
            ("empty text recovery", storeTests, { try await storeTests.testEmptyTextCanBeSavedAndRestored() }),
            ("maximum escaped text recovery", storeTests, { try await storeTests.testMaximumTextWithJSONEscapesSurvivesRestart() }),
            ("long Chinese PDF name preserves extension", storeTests, { try await storeTests.testLongChinesePDFNameKeepsExtensionAfterRealSave() }),
            ("path, limits, offsets and sender ownership", storeTests, { try await storeTests.testPathsLimitsOffsetsAndOwnershipAreRejected() }),
            ("overlapping replay", storeTests, { try await storeTests.testOverlappingReplayCannotAdvanceOffset() }),
            ("symlink safety", storeTests, { try await storeTests.testFilesystemSymlinkCannotRedirectWriting() }),
            ("missing completed file", storeTests, { try await storeTests.testMissingCompletedFileIsNotReportedAsCompletedAfterRestart() }),
            ("streaming hash known vector", storeTests, { try storeTests.testStreamingDigestMatchesKnownVector() }),
            ("encrypted round trip and random nonce", cryptoTests, { try cryptoTests.testEncryptedRoundTripAndFreshNonces() }),
            ("ciphertext and metadata tampering", cryptoTests, { try cryptoTests.testCiphertextAndEveryRoutingFieldAreAuthenticated() }),
            ("malformed encryption inputs", cryptoTests, { try cryptoTests.testMalformedSecretAndUnboundedMetadataAreRejected() })
        ]
        var passed = 0
        for (name, testCase, test) in tests {
            let previousCount = CheckAssertions.failures.count
            do {
                try testCase.setUpWithError()
                try await test()
            } catch {
                XCTFail("\(name): \(error)")
            }
            do { try testCase.tearDownWithError() } catch { XCTFail("Cleanup failed: \(error)") }
            if CheckAssertions.failures.count == previousCount {
                passed += 1
                print("PASS: \(name)")
            } else {
                print("FAIL: \(name)")
            }
        }
        for failure in CheckAssertions.failures { print(failure) }
        print("Standalone core checks: \(passed)/\(tests.count) passed; XCTest framework was not used.")
        if passed != tests.count { exit(1) }
    }
}
#endif
