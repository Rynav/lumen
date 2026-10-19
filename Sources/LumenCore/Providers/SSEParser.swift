import Foundation

/// Incremental UTF-8 SSE framing. Feed bytes rather than URLSession's lines so
/// malformed UTF-8 and a response ending inside an event are detectable.
struct SSEParser {
    struct Event: Equatable, Sendable {
        var event: String?
        var data: String
    }

    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var skipLF = false
    private var firstLine = true

    mutating func consume(_ byte: UInt8) throws -> Event? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else {
            line.append(byte)
            return nil
        }
        skipLF = byte == 13
        guard var text = String(bytes: line, encoding: .utf8) else {
            throw ProviderError.malformedStream
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = nil }
            guard !dataLines.isEmpty else { return nil }
            return Event(event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = pieces[0]
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        default: break
        }
        return nil
    }

    func finish() throws {
        guard String(bytes: line, encoding: .utf8) != nil else {
            throw ProviderError.malformedStream
        }
        guard line.isEmpty, dataLines.isEmpty, eventName == nil else {
            throw ProviderError.incompleteStream
        }
    }
}
