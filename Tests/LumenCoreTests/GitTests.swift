import Foundation
import Testing
@testable import LumenCore

@Suite struct GitTests {
    @Test func parsesPorcelainStatus() {
        let output = " M Sources/A.swift\u{0}?? New File.txt\u{0}R  new.txt\u{0}old.txt\u{0}"
        let entries = GitService.parseStatus(output)
        #expect(entries.count == 3)
        #expect(entries[0].path == "Sources/A.swift" && entries[0].label == "Modified")
        #expect(entries[1].path == "New File.txt" && entries[1].isUntracked && entries[1].label == "New")
        #expect(entries[2].path == "new.txt" && entries[2].label == "Renamed")
    }

    @Test func approvalPolicyAutoApproves() async {
        let proposal = FileEditProposal(id: UUID(), path: "a.swift", before: nil, after: "let a = 1")
        #expect(await ApprovalGate(policy: .autoApproveEdits).request(proposal, notify: { _ in }) == true)
        #expect(await ApprovalGate(policy: .fullAuto).request(id: UUID(), notify: {}) == true)
    }
}
