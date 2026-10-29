import Foundation
import Darwin

public enum TransferStoreError: Error, LocalizedError {
    case invalidManifest, invalidIdentifier, unsafePath, senderMismatch, manifestConflict
    case unknownTransfer, approvalRequired, invalidState, invalidChunk, offsetMismatch
    case changedReplay, destinationConflict, corruptLedger

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "传输信息无效或超过大小限制。"
        case .invalidIdentifier: return "传输或设备标识无效。"
        case .unsafePath: return "文件名称或保存路径不安全。"
        case .senderMismatch: return "发送设备与原传输不一致。"
        case .manifestConflict: return "同一传输标识的内容信息发生变化。"
        case .unknownTransfer: return "找不到这项传输。"
        case .approvalRequired: return "请先在接收设备确认接收。"
        case .invalidState: return "这项传输的当前状态不允许此操作。"
        case .invalidChunk: return "数据块无效或超过大小限制。"
        case .offsetMismatch: return "数据位置不连续，请查询接收进度后重试。"
        case .changedReplay: return "重复发送的数据与已保存内容不同。"
        case .destinationConflict: return "保存位置已有不同内容，已保留原文件。"
        case .corruptLedger: return "接收记录损坏，已停止操作以保护原文件。"
        }
    }
}

public actor TransferStore {
    private let root: URL
    private let partialDirectory: URL
    private let receivedDirectory: URL
    private let ledgerDirectory: URL
    private let ownDeviceID: String
    private let ownDeviceName: String
    private var savedRecords: [String: TransferRecord]

    private static let maximumFileBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    private static let maximumTextBytes: Int64 = 1_024 * 1_024
    private static let maximumChunkBytes = 256 * 1_024

    public init(root: URL, ownDeviceID: String, ownDeviceName: String) throws {
        guard CoreValidation.isUUID(ownDeviceID) else { throw TransferStoreError.invalidIdentifier }
        guard CoreValidation.validDisplayName(ownDeviceName) else { throw TransferStoreError.invalidManifest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        try StoreFilesystem.ensureDirectory(canonicalRoot)
        let partial = canonicalRoot.appendingPathComponent("Partial", isDirectory: true)
        let received = canonicalRoot.appendingPathComponent("Received", isDirectory: true)
        let ledger = canonicalRoot.appendingPathComponent("Ledger", isDirectory: true)
        for directory in [partial, received, ledger] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try StoreFilesystem.ensureDirectory(directory)
        }
        self.root = canonicalRoot
        self.partialDirectory = partial
        self.receivedDirectory = received
        self.ledgerDirectory = ledger
        self.ownDeviceID = ownDeviceID
        self.ownDeviceName = ownDeviceName
        self.savedRecords = try Self.loadRecords(partial: partial, received: received, ledger: ledger)
    }

    public func records() -> [TransferRecord] {
        savedRecords.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    public func approve(_ id: String) throws {
        var record = try existing(id, senderID: nil)
        guard record.state == .awaitingApproval else { throw TransferStoreError.invalidState }
        try ensureDirectories()
        let handle = try StoreFilesystem.openFile(partialURL(id), flags: O_RDWR | O_CREAT)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.synchronize()
        try StoreFilesystem.synchronizeDirectory(partialDirectory)
        record.state = .receiving
        record.receivedBytes = 0
        record.error = nil
        try commit(record)
    }

    public func reject(_ id: String) throws {
        var record = try existing(id, senderID: nil)
        guard record.state == .awaitingApproval || record.state == .receiving else {
            throw TransferStoreError.invalidState
        }
        record.state = .rejected
        record.error = nil
        try commit(record)
    }

    public func handle(_ request: WireRequest, senderID: String) async throws -> WireReply {
        guard CoreValidation.isUUID(senderID) else { throw TransferStoreError.invalidIdentifier }
        try ensureDirectories()
        switch request.operation {
        case .ping:
            return WireReply(deviceID: ownDeviceID, deviceName: ownDeviceName)
        case .offer:
            guard let manifest = request.manifest else { throw TransferStoreError.invalidManifest }
            try Self.validate(manifest)
            guard manifest.senderID == senderID else { throw TransferStoreError.senderMismatch }
            if let requestID = request.transferID, requestID != manifest.id {
                throw TransferStoreError.manifestConflict
            }
            if let record = savedRecords[manifest.id] {
                guard record.manifest == manifest else { throw TransferStoreError.manifestConflict }
                return reply(record)
            }
            let record = TransferRecord(manifest: manifest)
            try commit(record)
            return reply(record)
        case .status:
            let record = try existing(request.transferID, senderID: senderID)
            return reply(record)
        case .chunk:
            return try receiveChunk(request, senderID: senderID)
        case .finish:
            return try finish(request.transferID, senderID: senderID)
        case .cancel:
            var record = try existing(request.transferID, senderID: senderID)
            // Completion is irreversible from the sender's cancel request.
            if record.state == .completed || record.state == .cancelled || record.state == .rejected {
                return reply(record)
            }
            record.state = .cancelled
            record.error = nil
            try commit(record)
            return reply(record)
        }
    }

    private func receiveChunk(_ request: WireRequest, senderID: String) throws -> WireReply {
        var record = try existing(request.transferID, senderID: senderID)
        guard record.state != .awaitingApproval else { throw TransferStoreError.approvalRequired }
        guard record.state == .receiving || record.state == .completed else { throw TransferStoreError.invalidState }
        guard let offset = request.offset, offset >= 0, let data = request.data,
              !data.isEmpty, data.count <= Self.maximumChunkBytes else { throw TransferStoreError.invalidChunk }
        guard offset <= record.manifest.byteCount,
              Int64(data.count) <= record.manifest.byteCount - offset else { throw TransferStoreError.invalidChunk }
        let end = offset + Int64(data.count)
        let storedURL = record.state == .completed ? finalURL(record.manifest) : partialURL(record.id)
        if offset < record.receivedBytes {
            guard end <= record.receivedBytes else { throw TransferStoreError.offsetMismatch }
            let handle = try StoreFilesystem.openFile(storedURL, flags: O_RDONLY)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            guard try handle.read(upToCount: data.count) == data else { throw TransferStoreError.changedReplay }
            return reply(record)
        }
        guard record.state == .receiving, offset == record.receivedBytes else {
            throw TransferStoreError.offsetMismatch
        }
        let handle = try StoreFilesystem.openFile(storedURL, flags: O_RDWR)
        defer { try? handle.close() }
        guard let actualBytes = try StoreFilesystem.fileSize(storedURL), actualBytes >= offset else {
            throw TransferStoreError.offsetMismatch
        }
        // Discard an unacknowledged tail left by a previous failed ledger commit.
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        record.receivedBytes = end
        record.error = nil
        try commit(record)
        return reply(record)
    }

    private func finish(_ id: String?, senderID: String) throws -> WireReply {
        var record = try existing(id, senderID: senderID)
        if record.state == .completed { return reply(record) }
        guard record.state != .awaitingApproval else { throw TransferStoreError.approvalRequired }
        guard record.state == .receiving else { throw TransferStoreError.invalidState }
        guard record.receivedBytes == record.manifest.byteCount else {
            return reply(record, message: "文件尚未接收完整，请从已保存的位置继续。")
        }
        let source = partialURL(record.id)
        let final = finalURL(record.manifest)
        let finalSize = try StoreFilesystem.fileSize(final)
        let validationURL = finalSize != nil ? final : source
        guard try StoreFilesystem.fileSize(validationURL) == record.manifest.byteCount else {
            record.state = .failed
            record.error = "保存的文件长度与发送信息不一致。"
            try commit(record)
            return reply(record)
        }
        guard try FileDigest.sha256(url: validationURL) == record.manifest.sha256 else {
            if finalSize != nil { throw TransferStoreError.destinationConflict }
            record.state = .failed
            record.error = "文件校验失败，已保留未完成文件。"
            try commit(record)
            return reply(record)
        }
        if record.manifest.kind == .text {
            let handle = try StoreFilesystem.openFile(validationURL, flags: O_RDONLY)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                record.state = .failed
                record.error = "收到的文本不是有效 UTF-8，已保留原始数据。"
                try commit(record)
                return reply(record)
            }
            record.text = text
        }
        if finalSize == nil {
            // moveItem refuses an existing destination; a completed file is never overwritten.
            try FileManager.default.moveItem(at: source, to: final)
            try StoreFilesystem.synchronizeDirectory(partialDirectory)
            try StoreFilesystem.synchronizeDirectory(receivedDirectory)
        }
        record.state = .completed
        record.localPath = final.path
        record.error = nil
        try commit(record)
        return reply(record)
    }

    private func reply(_ record: TransferRecord, message: String? = nil) -> WireReply {
        WireReply(state: record.state, receivedBytes: record.receivedBytes,
                  message: message ?? record.error, deviceID: ownDeviceID, deviceName: ownDeviceName)
    }

    private func existing(_ id: String?, senderID: String?) throws -> TransferRecord {
        guard let id = id, CoreValidation.isUUID(id) else { throw TransferStoreError.invalidIdentifier }
        guard let record = savedRecords[id] else { throw TransferStoreError.unknownTransfer }
        if let senderID = senderID, record.manifest.senderID != senderID { throw TransferStoreError.senderMismatch }
        return record
    }

    private func commit(_ value: TransferRecord) throws {
        try ensureDirectories()
        var record = value
        record.updatedAt = Date()
        try Self.persist(record, in: ledgerDirectory)
        savedRecords[record.id] = record
    }

    private func ensureDirectories() throws {
        for directory in [root, partialDirectory, receivedDirectory, ledgerDirectory] {
            try StoreFilesystem.ensureDirectory(directory)
        }
    }

    private func partialURL(_ id: String) -> URL {
        partialDirectory.appendingPathComponent(id + ".part")
    }

    private func finalURL(_ manifest: TransferManifest) -> URL {
        receivedDirectory.appendingPathComponent(Self.safeFinalName(manifest))
    }

    private static func safeFinalName(_ manifest: TransferManifest) -> String {
        var basename = manifest.name.replacingOccurrences(of: ":", with: "_")
        if let dot = basename.lastIndex(of: "."), dot != basename.startIndex {
            let suffix = String(basename[basename.index(after: dot)...])
            let safeExtension = !suffix.isEmpty && suffix.utf8.count <= 24 && suffix.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
            if safeExtension {
                var stem = String(basename[..<dot])
                let maximumStemBytes = 180 - suffix.utf8.count - 1
                while stem.utf8.count > maximumStemBytes { stem.removeLast() }
                basename = stem + "." + suffix
            } else {
                while basename.utf8.count > 180 { basename.removeLast() }
            }
        } else {
            while basename.utf8.count > 180 { basename.removeLast() }
        }
        return manifest.id + "-" + basename
    }

    private static func validate(_ manifest: TransferManifest) throws {
        guard CoreValidation.isUUID(manifest.id), CoreValidation.isUUID(manifest.senderID) else {
            throw TransferStoreError.invalidIdentifier
        }
        guard !manifest.name.isEmpty, manifest.name.utf8.count <= 255,
              manifest.name != ".", manifest.name != "..",
              !manifest.name.contains("/"), !manifest.name.contains("\\"),
              !manifest.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TransferStoreError.unsafePath
        }
        let maximum = manifest.kind == .text ? maximumTextBytes : maximumFileBytes
        guard manifest.byteCount >= 0, manifest.byteCount <= maximum,
              CoreValidation.isLowerHex(manifest.sha256, count: 64),
              CoreValidation.validDisplayName(manifest.senderName),
              manifest.createdAt.timeIntervalSince1970.isFinite else { throw TransferStoreError.invalidManifest }
    }

    private static func persist(_ record: TransferRecord, in ledger: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try StoreFilesystem.writeDurably(encoder.encode(record), to: ledger.appendingPathComponent(record.id + ".json"))
    }

    private static func loadRecords(partial: URL, received: URL, ledger: URL) throws -> [String: TransferRecord] {
        var loaded: [String: TransferRecord] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: ledger, includingPropertiesForKeys: nil)
        for url in files where url.pathExtension == "json" {
            // A 1 MiB UTF-8 text may occupy 6 MiB when JSON escapes control characters.
            guard let ledgerSize = try StoreFilesystem.fileSize(url), ledgerSize <= 8 * 1_024 * 1_024 else {
                throw TransferStoreError.corruptLedger
            }
            let handle = try StoreFilesystem.openFile(url, flags: O_RDONLY)
            let data: Data
            do {
                data = try handle.readToEnd() ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            var record = try JSONDecoder().decode(TransferRecord.self, from: data)
            try validate(record.manifest)
            guard url.lastPathComponent == record.id + ".json", loaded[record.id] == nil,
                  record.receivedBytes >= 0, record.receivedBytes <= record.manifest.byteCount,
                  record.updatedAt.timeIntervalSince1970.isFinite else { throw TransferStoreError.corruptLedger }
            let oldRecord = record
            let partURL = partial.appendingPathComponent(record.id + ".part")
            let finalURL = received.appendingPathComponent(safeFinalName(record.manifest))
            // Persisted paths are untrusted: always reconstruct them from validated metadata.
            record.localPath = record.state == .completed ? finalURL.path : nil
            if record.state == .receiving {
                record.text = nil
                if let size = try StoreFilesystem.fileSize(finalURL) {
                    if size == record.manifest.byteCount,
                       try FileDigest.sha256(url: finalURL) == record.manifest.sha256 {
                        if record.manifest.kind == .text {
                            let finalHandle = try StoreFilesystem.openFile(finalURL, flags: O_RDONLY)
                            defer { try? finalHandle.close() }
                            let finalData = try finalHandle.readToEnd() ?? Data()
                            guard let text = String(data: finalData, encoding: .utf8) else {
                                record.state = .failed
                                record.error = "恢复的文本不是有效 UTF-8。"
                                record.text = nil
                                try persist(record, in: ledger)
                                loaded[record.id] = record
                                continue
                            }
                            record.text = text
                        }
                        record.state = .completed
                        record.receivedBytes = record.manifest.byteCount
                        record.localPath = finalURL.path
                        record.error = nil
                    } else {
                        record.state = .failed
                        record.error = "保存位置的文件与接收记录不同，已保留文件。"
                    }
                } else {
                    let size = try StoreFilesystem.fileSize(partURL) ?? 0
                    if size > record.receivedBytes {
                        let partHandle = try StoreFilesystem.openFile(partURL, flags: O_RDWR)
                        defer { try? partHandle.close() }
                        try partHandle.truncate(atOffset: UInt64(record.receivedBytes))
                        try partHandle.synchronize()
                    } else if size < record.receivedBytes {
                        record.receivedBytes = size
                    }
                    if try StoreFilesystem.fileSize(partURL) == nil {
                        let partHandle = try StoreFilesystem.openFile(partURL, flags: O_WRONLY | O_CREAT | O_EXCL)
                        try partHandle.synchronize()
                        try partHandle.close()
                        try StoreFilesystem.synchronizeDirectory(partial)
                    }
                }
            } else if record.state == .completed {
                record.receivedBytes = record.manifest.byteCount
                if try StoreFilesystem.fileSize(finalURL) != record.manifest.byteCount {
                    record.state = .failed
                    record.error = "已保存文件缺失或长度发生变化。"
                    record.localPath = nil
                    record.text = nil
                } else if record.manifest.kind == .text {
                    let finalHandle = try StoreFilesystem.openFile(finalURL, flags: O_RDONLY)
                    defer { try? finalHandle.close() }
                    let finalData = try finalHandle.readToEnd() ?? Data()
                    if FileDigest.sha256(data: finalData) == record.manifest.sha256,
                       let text = String(data: finalData, encoding: .utf8) {
                        record.text = text
                    } else {
                        record.state = .failed
                        record.error = "已保存文本校验失败。"
                        record.text = nil
                    }
                }
            } else {
                record.text = nil
            }
            if record != oldRecord {
                record.updatedAt = Date()
                try persist(record, in: ledger)
            }
            loaded[record.id] = record
        }
        return loaded
    }
}
