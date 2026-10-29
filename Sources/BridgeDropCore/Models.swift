import Foundation

public enum TransferKind: String, Codable, Sendable {
    case file, text
}

public enum TransferState: String, Codable, Sendable {
    case awaitingApproval, receiving, completed, rejected, cancelled, failed
}

public struct TransferManifest: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: TransferKind
    public let name: String
    public let byteCount: Int64
    public let sha256: String
    public let senderID: String
    public let senderName: String
    public let createdAt: Date

    public init(id: String, kind: TransferKind, name: String, byteCount: Int64,
                sha256: String, senderID: String, senderName: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.senderID = senderID
        self.senderName = senderName
        self.createdAt = createdAt
    }
}

public struct TransferRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String { manifest.id }
    public let manifest: TransferManifest
    public var state: TransferState
    public var receivedBytes: Int64
    public var localPath: String?
    public var text: String?
    public var error: String?
    public var updatedAt: Date

    public init(manifest: TransferManifest, state: TransferState = .awaitingApproval,
                receivedBytes: Int64 = 0, localPath: String? = nil, text: String? = nil,
                error: String? = nil, updatedAt: Date = Date()) {
        self.manifest = manifest
        self.state = state
        self.receivedBytes = receivedBytes
        self.localPath = localPath
        self.text = text
        self.error = error
        self.updatedAt = updatedAt
    }
}

public enum WireOperation: String, Codable, Sendable {
    case offer, status, chunk, finish, cancel, ping
}

public struct WireRequest: Codable, Sendable {
    public let operation: WireOperation
    public let manifest: TransferManifest?
    public let transferID: String?
    public let offset: Int64?
    public let data: Data?
    public let senderName: String?

    public init(operation: WireOperation, manifest: TransferManifest? = nil,
                transferID: String? = nil, offset: Int64? = nil, data: Data? = nil,
                senderName: String? = nil) {
        self.operation = operation
        self.manifest = manifest
        self.transferID = transferID
        self.offset = offset
        self.data = data
        self.senderName = senderName
    }
}

public struct WireReply: Codable, Sendable {
    public let state: TransferState?
    public let receivedBytes: Int64
    public let message: String?
    public let deviceID: String?
    public let deviceName: String?

    public init(state: TransferState? = nil, receivedBytes: Int64 = 0,
                message: String? = nil, deviceID: String? = nil, deviceName: String? = nil) {
        self.state = state
        self.receivedBytes = receivedBytes
        self.message = message
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public struct SecurePacket: Codable, Sendable {
    public let pairID: String
    public let senderID: String
    public let receiverID: String
    public let requestID: String
    public let ciphertext: Data

    public init(pairID: String, senderID: String, receiverID: String,
                requestID: String, ciphertext: Data) {
        self.pairID = pairID
        self.senderID = senderID
        self.receiverID = receiverID
        self.requestID = requestID
        self.ciphertext = ciphertext
    }
}

enum CoreValidation {
    static func isUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func validDisplayName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 512
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
