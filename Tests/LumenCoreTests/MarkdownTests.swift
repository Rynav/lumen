import Testing
@testable import LumenCore

@Suite struct MarkdownTests {
    @Test func blocksPreserveStructureAndCodeDuringStreaming() {
        let source = "# Summary\n\nA **clear** answer.\n\n- First item\n2. Second item\n> A quote\n\n```swift\nlet value = 1\n\n# Not a heading\n```\n\nNext paragraph"
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .listItem("•"), .listItem("2."), .quote, .code("swift"), .paragraph])
        #expect(blocks[5].text == "let value = 1\n\n# Not a heading")
        #expect(MarkdownBlock.parse("```\npartial code").first?.kind == .code(""))
        #expect(MarkdownBlock.parse("```\npartial code").first?.text == "partial code")
        #expect(MarkdownBlock.parse("a\nb").first?.text == "a\nb")
        #expect(MarkdownBlock.parse("#tag").first?.kind == .paragraph)
        #expect(MarkdownBlock.parse("\n\n").isEmpty)
    }
}
