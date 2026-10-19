import Foundation
import Network

/// A short-lived listener bound only to IPv4 loopback; never serves credentials.
final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.lumen.oauth.callback")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var stopped = false
    private let ready: AsyncThrowingStream<UInt16, any Error>
    private let readyOutput: AsyncThrowingStream<UInt16, any Error>.Continuation
    private let callbacks: AsyncThrowingStream<URL, any Error>
    private let callbackOutput: AsyncThrowingStream<URL, any Error>.Continuation

    init() throws {
        (ready, readyOutput) = AsyncThrowingStream.makeStream()
        (callbacks, callbackOutput) = AsyncThrowingStream.makeStream()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.readyOutput.yield(port.rawValue); self.readyOutput.finish() }
            case .failed:
                self.readyOutput.finish(throwing: ChatGPTAuthError.callbackUnavailable)
                self.callbackOutput.finish(throwing: ChatGPTAuthError.callbackUnavailable)
            case .cancelled:
                self.readyOutput.finish(throwing: CancellationError())
                self.callbackOutput.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.lock.withLock {
                guard !self.stopped, self.connections.count < 16 else { return false }
                self.connections.append(connection)
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close(connection) }
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    func port() async throws -> UInt16 {
        for try await port in ready { return port }
        throw CancellationError()
    }

    func callback() async throws -> URL {
        for try await url in callbacks { return url }
        throw CancellationError()
    }

    func stop() {
        let pending = lock.withLock {
            stopped = true
            defer { connections = [] }
            return connections
        }
        pending.forEach { $0.cancel() }
        listener.cancel()
        readyOutput.finish(throwing: CancellationError())
        callbackOutput.finish(throwing: CancellationError())
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        lock.withLock { connections.removeAll { $0 === connection } }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let received = data + (chunk ?? Data())
            guard received.count <= 8_192, error == nil else { self.close(connection); return }
            guard received.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.close(connection) } else { self.receive(connection, data: received) }
                return
            }
            let firstLine = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let url = parts.count == 3 && parts[0] == "GET"
                ? URL(string: "http://127.0.0.1\(parts[1])") : nil
            let valid = url?.path == "/auth/callback" && url?.host == "127.0.0.1"
            let body = valid ? "Return to Lumen to finish signing in. You may close this tab." : "Not found."
            let response = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.close(connection)
                if valid, let url { self.callbackOutput.yield(url); self.callbackOutput.finish() }
            })
        }
    }
}
