import Foundation

/// Each operation owns its session, so cancellation cannot affect a later request.
final class HTTPTransport: @unchecked Sendable {
    final class Operation: @unchecked Sendable {
        let id = UUID()
        let session: URLSession
        private let lock = NSLock()
        private var closed = false
        private var cancelTask: (@Sendable () -> Void)?

        init(configuration: URLSessionConfiguration) {
            session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }

        func installCancellation(_ action: @escaping @Sendable () -> Void) {
            let alreadyClosed = lock.withLock {
                if closed { return true }
                cancelTask = action
                return false
            }
            if alreadyClosed { action() }
        }

        func cancel() {
            let action = lock.withLock {
                closed = true
                defer { cancelTask = nil }
                return cancelTask
            }
            action?()
            session.invalidateAndCancel()
        }

        func finish() {
            lock.withLock { closed = true; cancelTask = nil }
            session.finishTasksAndInvalidate()
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let lock = NSLock()
    private var operations: [UUID: Operation] = [:]
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func begin() -> Operation {
        let operation = Operation(configuration: configuration)
        lock.withLock { operations[operation.id] = operation }
        return operation
    }

    func finish(_ operation: Operation) {
        _ = lock.withLock { operations.removeValue(forKey: operation.id) }
        operation.finish()
    }

    func cancel() {
        let pending = lock.withLock {
            defer { operations.removeAll() }
            return Array(operations.values)
        }
        pending.forEach { $0.cancel() }
    }

    deinit { cancel() }

    static func baseURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    static func validateHeaders(_ headers: [String: String]) throws {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (name, value) in headers {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw ProviderError.unsupported("Invalid HTTP header.")
            }
        }
    }

    /// Only status and recognized error codes escape; response text stays private.
    static func responseError(status: Int, body: Data) -> ProviderError {
        if status == 401 || status == 403 { return .unauthorized }
        if status == 429 { return .rateLimited }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: body),
           let error = value["error"] {
            let code = error["code"]?.string ?? error["type"]?.string
            let message = error["message"]?.string?.lowercased() ?? ""
            if code == "context_length_exceeded" || code == "context_window_exceeded"
                || message.contains("maximum context length") {
                return .contextLength
            }
        }
        return .http(status)
    }

    static func retryDelay(attempt: Int, retryAfter: String?, now: Date = Date()) -> TimeInterval {
        let exponential = pow(2, Double(attempt))
        guard let retryAfter else { return min(60, exponential) }
        let seconds: Double?
        if let value = Double(retryAfter), value.isFinite {
            seconds = value
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            seconds = formatter.date(from: retryAfter)?.timeIntervalSince(now)
        }
        return min(60, max(exponential, seconds ?? 0))
    }

    /// Retries only rejected requests, before returning any response bytes.
    static func bytes(for request: URLRequest, operation: Operation) async throws -> URLSession.AsyncBytes {
        for attempt in 0...3 {
            try Task.checkCancellation()
            let (bytes, response) = try await operation.session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ProviderError.malformedStream
            }
            if (200..<300).contains(response.statusCode) { return bytes }
            if response.statusCode == 429, attempt < 3 {
                bytes.task.cancel()
                let delay = retryDelay(attempt: attempt, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            var body = Data()
            // Error bodies are used only for classification, and never displayed.
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65_536 { break }
            }
            bytes.task.cancel()
            throw responseError(status: response.statusCode, body: body)
        }
        throw ProviderError.rateLimited
    }
}
