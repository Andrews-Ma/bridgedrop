import Foundation
import Network

public enum TransportError: LocalizedError {
    case timeout, closed, invalidFrame, peerUnavailable, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: return "连接超时。请打开接收端应用，检查网络及本地网络权限后重试。"
        case .closed: return "连接已断开，已保存的分块可以继续传输。"
        case .invalidFrame: return "收到无效或过大的网络消息。"
        case .peerUnavailable: return "对方尚未连接，正在等待网络恢复。请保持两端应用打开。"
        case .unavailable(let reason): return reason
        }
    }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        saved?.resume(with: result)
    }
}

private enum FrameIO {
    static let maximum = 2 * 1024 * 1024
    static let queue = DispatchQueue(label: "BridgeDrop.TCP", qos: .userInitiated, attributes: .concurrent)

    static func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(()))
                case .failed(let error): once.finish(.failure(error))
                case .cancelled: once.finish(.failure(TransportError.closed))
                default: break // Permission prompts may leave a connection waiting.
                }
            }
            queue.asyncAfter(deadline: .now() + 20) { once.finish(.failure(TransportError.timeout)) }
            connection.start(queue: queue)
        }
    }

    static func send(_ payload: Data, on connection: NWConnection) async throws {
        guard !payload.isEmpty, payload.count <= maximum else { throw TransportError.invalidFrame }
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }; framed.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { once.finish(.failure(error)) } else { once.finish(.success(())) }
            })
            queue.asyncAfter(deadline: .now() + 20) { once.finish(.failure(TransportError.timeout)) }
        }
    }

    static func readBytes(_ count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once<Data>(continuation)
            // Only one receive is outstanding; timeout never touches this buffer.
            final class Accumulator: @unchecked Sendable { var data = Data() }
            let accumulator = Accumulator()
            func receiveMore() {
                let remaining = count - accumulator.data.count
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let data { accumulator.data.append(data) }
                    if accumulator.data.count == count { once.finish(.success(accumulator.data)); return }
                    if let error { once.finish(.failure(error)); return }
                    if complete { once.finish(.failure(TransportError.closed)); return }
                    receiveMore()
                }
            }
            queue.asyncAfter(deadline: .now() + 20) { once.finish(.failure(TransportError.timeout)) }
            receiveMore()
        }
    }

    static func read(on connection: NWConnection) async throws -> Data {
        let header = try await readBytes(4, on: connection)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= UInt32(maximum) else { throw TransportError.invalidFrame }
        return try await readBytes(Int(count), on: connection)
    }
}

public enum LocalExchange {
    public static func call(_ packet: SecurePacket, endpoint: NWEndpoint) async throws -> SecurePacket {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withTaskCancellationHandler(operation: {
            defer { connection.cancel() }
            try Task.checkCancellation()
            try await FrameIO.ready(connection)
            try Task.checkCancellation()
            try await FrameIO.send(JSONEncoder().encode(packet), on: connection)
            let response = try await FrameIO.read(on: connection)
            try Task.checkCancellation()
            return try JSONDecoder().decode(SecurePacket.self, from: response)
        }, onCancel: { connection.cancel() })
    }
}

public final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]
    public init(port: UInt16 = 47185, deviceID: String,
                onState: @escaping @Sendable (String) -> Void,
                handler: @escaping @Sendable (SecurePacket) async throws -> SecurePacket) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "BridgeDrop-" + deviceID, type: "_bridgedrop._tcp")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState("局域网接收已开启")
            case .waiting: onState("等待本地网络权限或网络连接")
            case .failed(let error): onState("局域网接收失败：" + error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.lock.lock()
            let canAccept = self.connections.count < 24
            if canAccept { self.connections[id] = connection }
            self.lock.unlock()
            guard canAccept else { connection.cancel(); return }
            Task {
                defer { connection.cancel(); self.remove(id) }
                do {
                    try await FrameIO.ready(connection)
                    let data = try await FrameIO.read(on: connection)
                    let packet = try JSONDecoder().decode(SecurePacket.self, from: data)
                    let reply = try await handler(packet)
                    try await FrameIO.send(JSONEncoder().encode(reply), on: connection)
                } catch {
                    // Unauthenticated or malformed requests receive no plaintext diagnostics.
                }
            }
        }
    }
    private func remove(_ id: UUID) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
    public func start() { listener.start(queue: FrameIO.queue) }
    public func stop() {
        listener.cancel()
        lock.lock(); let saved = Array(connections.values); connections.removeAll(); lock.unlock()
        for connection in saved { connection.cancel() }
    }
}

public final class LocalDiscovery: @unchecked Sendable {
    private let browser: NWBrowser
    public init(ownDeviceID: String, onChange: @escaping @Sendable ([NWEndpoint]) -> Void) {
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_bridgedrop._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.compactMap { result -> NWEndpoint? in
                if case .service(let name, _, _, _) = result.endpoint, name == "BridgeDrop-" + ownDeviceID { return nil }
                return result.endpoint
            }
            onChange(endpoints)
        }
    }
    public func start() { browser.start(queue: FrameIO.queue) }
    public func stop() { browser.cancel() }
}
