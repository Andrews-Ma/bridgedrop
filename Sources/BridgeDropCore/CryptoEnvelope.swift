import Foundation
import CryptoKit
import Darwin

public enum PacketCryptoError: Error, LocalizedError {
    case invalidSecret, invalidMetadata, payloadTooLarge, invalidCiphertext

    public var errorDescription: String? {
        switch self {
        case .invalidSecret: return "配对密钥必须为 32 字节。"
        case .invalidMetadata: return "加密包的设备或请求标识无效。"
        case .payloadTooLarge: return "加密包超过大小限制。"
        case .invalidCiphertext: return "加密包损坏或不完整。"
        }
    }
}

public enum PacketCrypto {
    private static let protocolID = "bridgedrop-packet-v1"
    private static let maximumPlaintextBytes = 1_048_576

    private struct Metadata: Encodable {
        let version: Int
        let protocolID: String
        let pairID: String
        let senderID: String
        let receiverID: String
        let requestID: String
    }

    public static func seal<T: Encodable>(_ value: T, secret: Data, pairID: String,
                                         senderID: String, receiverID: String,
                                         requestID: String) throws -> SecurePacket {
        try validate(secret: secret, pairID: pairID, senderID: senderID,
                     receiverID: receiverID, requestID: requestID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(value)
        guard plaintext.count <= maximumPlaintextBytes else { throw PacketCryptoError.payloadTooLarge }
        let aad = try metadata(pairID: pairID, senderID: senderID,
                               receiverID: receiverID, requestID: requestID)
        // CryptoKit generates a fresh random 96-bit nonce for every sealed packet.
        let box = try AES.GCM.seal(plaintext, using: key(secret: secret, pairID: pairID), authenticating: aad)
        guard let combined = box.combined else { throw PacketCryptoError.invalidCiphertext }
        return SecurePacket(pairID: pairID, senderID: senderID, receiverID: receiverID,
                            requestID: requestID, ciphertext: combined)
    }

    public static func open<T: Decodable>(_ packet: SecurePacket, secret: Data, as: T.Type) throws -> T {
        try validate(secret: secret, pairID: packet.pairID, senderID: packet.senderID,
                     receiverID: packet.receiverID, requestID: packet.requestID)
        guard packet.ciphertext.count >= 28,
              packet.ciphertext.count <= maximumPlaintextBytes + 28 else {
            throw PacketCryptoError.invalidCiphertext
        }
        let aad = try metadata(pairID: packet.pairID, senderID: packet.senderID,
                               receiverID: packet.receiverID, requestID: packet.requestID)
        let box = try AES.GCM.SealedBox(combined: packet.ciphertext)
        let plaintext = try AES.GCM.open(box, using: key(secret: secret, pairID: packet.pairID), authenticating: aad)
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    private static func validate(secret: Data, pairID: String, senderID: String,
                                 receiverID: String, requestID: String) throws {
        guard secret.count == 32 else { throw PacketCryptoError.invalidSecret }
        guard CoreValidation.isLowerHex(pairID, count: 32),
              CoreValidation.isUUID(senderID), CoreValidation.isUUID(receiverID),
              CoreValidation.isUUID(requestID) else { throw PacketCryptoError.invalidMetadata }
    }

    private static func key(secret: Data, pairID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                              salt: Data(protocolID.utf8), info: Data(pairID.utf8),
                              outputByteCount: 32)
    }

    private static func metadata(pairID: String, senderID: String,
                                 receiverID: String, requestID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Metadata(version: 1, protocolID: protocolID, pairID: pairID,
                                           senderID: senderID, receiverID: receiverID, requestID: requestID))
    }
}

public enum FileDigest {
    public static func sha256(data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func sha256(url: URL) throws -> String {
        let handle = try StoreFilesystem.openFile(url, flags: O_RDONLY)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// All receive-store file opens reject symlinks. Each actor owns a private root directory.
enum StoreFilesystem {
    static func openFile(_ url: URL, flags: Int32, permissions: mode_t = 0o600) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, flags | O_NOFOLLOW, permissions) }
        guard descriptor >= 0 else { throw posixError(url) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw TransferStoreError.unsafePath
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func fileSize(_ url: URL) throws -> Int64? {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw posixError(url)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw TransferStoreError.unsafePath }
        return Int64(info.st_size)
    }

    static func ensureDirectory(_ url: URL) throws {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw TransferStoreError.unsafePath
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw posixError(url) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(url) }
    }

    static func writeDurably(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory)
        _ = try fileSize(destination)
        let temporary = directory.appendingPathComponent(".tmp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw posixError(destination) }
        try synchronizeDirectory(directory)
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
    }
}
