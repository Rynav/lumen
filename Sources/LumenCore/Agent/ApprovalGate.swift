import Foundation

/// How much the agent may do without asking. The command denylist still runs in every mode.
public enum ApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case reviewEverything
    case autoApproveEdits
    case fullAuto

    public var title: String {
        switch self {
        case .reviewEverything: "Review everything"
        case .autoApproveEdits: "Auto-approve edits"
        case .fullAuto: "Full Auto"
        }
    }

    public var detail: String {
        switch self {
        case .reviewEverything: "Each file edit and command needs your approval."
        case .autoApproveEdits: "File edits apply immediately; commands still need approval."
        case .fullAuto: "Edits and commands run without prompting. Blocked commands stay blocked."
        }
    }
}

/// Each run owns its gate. Only an explicit user decision, or the chosen policy, authorizes an action.
public actor ApprovalGate {
    private var waiting: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var cancelled = false
    private let policy: ApprovalPolicy
    public init(policy: ApprovalPolicy = .reviewEverything) { self.policy = policy }

    public func request(_ proposal: FileEditProposal, notify: @Sendable (FileEditProposal) -> Void) async -> Bool {
        // Auto-approved edits skip the diff prompt; the applied change still appears in Changes.
        if policy != .reviewEverything { return true }
        return await request(id: proposal.id) { notify(proposal) }
    }

    public func request(id: UUID, notify: @Sendable () -> Void) async -> Bool {
        if policy == .fullAuto { return true }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, !cancelled, waiting == nil else { return false }
            return await withCheckedContinuation { continuation in
                waiting = (id, continuation)
                notify()
            }
        } onCancel: { Task { await self.cancel() } }
    }

    public func decide(id: UUID, approved: Bool) {
        guard let pending = waiting, pending.id == id else { return }
        waiting = nil
        pending.continuation.resume(returning: approved && !cancelled)
    }

    public func cancel() {
        cancelled = true
        if let waiting {
            self.waiting = nil
            waiting.continuation.resume(returning: false)
        }
    }
}
