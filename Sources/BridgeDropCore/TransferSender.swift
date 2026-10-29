import Foundation
import Network

/// Retry transport failures only. Invalid data, permissions and explicit rejection need attention.
public enum TransferRetry {
    public static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? TransportError {
            switch error {
            case .timeout, .closed, .peerUnavailable: return true
            case .invalidFrame, .unavailable: return false
            }
        }
        if let error = error as? NWError, case .posix(let code) = error {
            return [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .ETIMEDOUT,
                    .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EPIPE, .ENOTCONN].contains(code)
        }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed].contains(value.code)
    }

    public static func delay(failure: Int, base: Double = 1, jitter: Double = Double.random(in: 0.8...1.2)) -> Double {
        min(16, max(0, base) * pow(2, Double(max(0, min(failure - 1, 5))))) * min(1.2, max(0.8, jitter))
    }
}

public enum TransferSendError: LocalizedError {
    case newOfferRequired(String), sourceChanged, invalidAcknowledgement, approvalTimeout
    public var errorDescription: String? {
        switch self {
        case .newOfferRequired(let reason): return reason
        case .sourceChanged: return "暂存文件缺失或大小发生变化，请重新选择文件发送。"
        case .invalidAcknowledgement: return "接收端的保存确认与传输内容不一致，已停止传输。"
        case .approvalTimeout: return "对方尚未接受，可以稍后点击继续。"
        }
    }
}

public enum TransferSendProgress: Sendable {
    case awaitingApproval, sending(Int64, Int64), reconnecting(Int), verifying, completed
}

public struct TransferSendPolicy: Sendable {
    public var reconnectAttempts = 4
    public var retryBaseDelay: Double = 1
    public var approvalPollInterval: Double = 1.5
    public var approvalTimeout: Double = 600
    public init() {}
}

/// One worker owns one transfer. Re-offering the SAME manifest obtains the receiver's durable offset.
/// A lost chunk or completion ACK therefore never creates a second receive or bypasses approval.
public enum TransferSender {
    public static func send(manifest: TransferManifest, source: URL, policy: TransferSendPolicy = .init(),
                            exchange: @escaping @Sendable (WireRequest) async throws -> WireReply,
                            progress: @escaping @Sendable (TransferSendProgress) async -> Void = { _ in }) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, policy.approvalTimeout)))
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                try await attempt(manifest: manifest, source: source, policy: policy, approvalDeadline: deadline,
                                  exchange: exchange, progress: progress)
                return
            } catch {
                try Task.checkCancellation()
                guard TransferRetry.isTransient(error), failures < max(0, policy.reconnectAttempts) else { throw error }
                failures += 1
                await progress(.reconnecting(failures))
                try await Task.sleep(nanoseconds: UInt64(TransferRetry.delay(failure: failures, base: policy.retryBaseDelay) * 1_000_000_000))
            }
        }
    }

    private static func attempt(manifest: TransferManifest, source: URL, policy: TransferSendPolicy,
                                approvalDeadline: ContinuousClock.Instant,
                                exchange: @Sendable (WireRequest) async throws -> WireReply,
                                progress: @Sendable (TransferSendProgress) async -> Void) async throws {
        await progress(.awaitingApproval)
        var reply = try await exchange(WireRequest(operation: .offer, manifest: manifest))
        while reply.state == .awaitingApproval {
            try Task.checkCancellation()
            guard ContinuousClock.now < approvalDeadline else { throw TransferSendError.approvalTimeout }
            try await Task.sleep(nanoseconds: UInt64(max(0, policy.approvalPollInterval) * 1_000_000_000))
            reply = try await exchange(WireRequest(operation: .status, transferID: manifest.id))
        }
        try Task.checkCancellation()
        try validateState(reply)
        if reply.state == .completed {
            try validateCompletion(reply, manifest: manifest)
            await progress(.completed)
            return
        }
        guard reply.state == .receiving, reply.receivedBytes >= 0, reply.receivedBytes <= manifest.byteCount else {
            throw TransferSendError.invalidAcknowledgement
        }
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              values?.fileSize.map(Int64.init) == manifest.byteCount else { throw TransferSendError.sourceChanged }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var offset = reply.receivedBytes
        try file.seek(toOffset: UInt64(offset))
        while offset < manifest.byteCount {
            try Task.checkCancellation()
            let count = min(256 * 1024, Int(manifest.byteCount - offset))
            let chunk = try file.read(upToCount: count) ?? Data()
            guard chunk.count == count else { throw TransferSendError.sourceChanged }
            reply = try await exchange(WireRequest(operation: .chunk, transferID: manifest.id, offset: offset, data: chunk))
            try Task.checkCancellation()
            try validateState(reply)
            guard reply.state == .receiving, reply.receivedBytes == offset + Int64(count) else {
                throw TransferSendError.invalidAcknowledgement
            }
            offset = reply.receivedBytes
            await progress(.sending(offset, manifest.byteCount))
        }
        await progress(.verifying)
        reply = try await exchange(WireRequest(operation: .finish, transferID: manifest.id))
        try Task.checkCancellation()
        try validateState(reply)
        try validateCompletion(reply, manifest: manifest)
        await progress(.completed)
    }

    private static func validateState(_ reply: WireReply) throws {
        if let state = reply.state, [.rejected, .cancelled, .failed].contains(state) {
            throw TransferSendError.newOfferRequired(reply.message ?? "对方拒绝、取消或校验失败。重新发送将再次请求接收。")
        }
    }
    private static func validateCompletion(_ reply: WireReply, manifest: TransferManifest) throws {
        guard reply.state == .completed, reply.receivedBytes == manifest.byteCount else {
            throw TransferSendError.invalidAcknowledgement
        }
    }
}
