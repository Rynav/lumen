import Foundation
import Network
@testable import LumenCore

/// Loopback HTTP server for the stream-cancellation tests. A `URLProtocol` stub
/// cannot stand in here: URLSession withholds a stub's bytes until its load
/// completes, so a partial body never reaches the transport under test. This
/// server streams one SSE event on `/v1/chat/completions` and then holds the
/// connection open, and answers `/v1/models` with a complete JSON body.
final class StreamingFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.lumen.tests.streaming")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var count = 0
    private let ready: AsyncThrowingStream<UInt16, any Error>
    private let readyOutput: AsyncThrowingStream<UInt16, any Error>.Continuation

    init() throws {
        (ready, readyOutput) = AsyncThrowingStream.makeStream()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.readyOutput.yield(port.rawValue); self.readyOutput.finish() }
            case .failed:
                self.readyOutput.finish(throwing: ProviderError.invalidURL)
            case .cancelled:
                self.readyOutput.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    var requestCount: Int { lock.withLock { count } }

    /// Base URL for a provider pointed at this server.
    func baseURL() async throws -> String {
        for try await port in ready { return "http://127.0.0.1:\(port)/v1" }
        throw CancellationError()
    }

    func stop() {
        let pending = lock.withLock {
            defer { connections = [] }
            return connections
        }
        pending.forEach { $0.cancel() }
        listener.cancel()
        readyOutput.finish(throwing: CancellationError())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let received = data + (chunk ?? Data())
            guard received.count <= 8_192, error == nil else { connection.cancel(); return }
            guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, data: received) }
                return
            }
            let requestLine = String(decoding: received[..<headerEnd.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.withLock { self.count += 1 }
            if path.hasSuffix("/models") {
                let body = #"{"data":[{"id":"reused"}]}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                // One event, then the connection stays open until the test cancels.
                let event = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}\n\n"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n\(event)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            }
        }
    }
}
